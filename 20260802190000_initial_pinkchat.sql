-- PinkChat: база данных, защита переписок и хранение фото.
-- Запустите весь файл в Supabase Dashboard → SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  display_name text not null,
  avatar_url text,
  created_at timestamptz not null default now()
);

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'direct' check (kind in ('direct', 'group')),
  title text,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text check (body is null or char_length(body) <= 2000),
  image_path text,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint message_has_content check (nullif(btrim(coalesce(body, '')), '') is not null or image_path is not null)
);

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists messages_conversation_created_idx
  on public.messages(conversation_id, created_at);
create index if not exists conversation_members_user_idx
  on public.conversation_members(user_id, conversation_id);
create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions(user_id);

-- Профиль создаётся автоматически при регистрации.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name)
  values (
    new.id,
    lower(new.email),
    coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(new.email, '@', 1))
  )
  on conflict (id) do update set
    email = excluded.email,
    display_name = excluded.display_name;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert or update of email, raw_user_meta_data on auth.users
for each row execute procedure public.handle_new_user();

-- Проверка участия без рекурсии RLS.
create or replace function public.is_conversation_member(check_conversation_id uuid, check_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = check_conversation_id
      and cm.user_id = check_user_id
  );
$$;

-- Создание или открытие личного чата по email.
create or replace function public.pinkchat_start_direct_chat(target_email text)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  target uuid;
  result_id uuid;
begin
  if me is null then raise exception 'Требуется вход'; end if;

  select id into target
  from public.profiles
  where lower(email) = lower(trim(target_email));

  if target is null then raise exception 'Пользователь с такой почтой не найден'; end if;
  if target = me then raise exception 'Нельзя создать чат с собой'; end if;

  -- Не даём двум одновременным запросам создать дубликаты одного личного чата.
  perform pg_advisory_xact_lock(
    hashtextextended(least(me::text, target::text) || ':' || greatest(me::text, target::text), 0)
  );

  select c.id into result_id
  from public.conversations c
  where c.kind = 'direct'
    and exists (select 1 from public.conversation_members a where a.conversation_id = c.id and a.user_id = me)
    and exists (select 1 from public.conversation_members b where b.conversation_id = c.id and b.user_id = target)
    and (select count(*) from public.conversation_members x where x.conversation_id = c.id) = 2
  limit 1;

  if result_id is null then
    insert into public.conversations (kind, created_by)
    values ('direct', me)
    returning id into result_id;

    insert into public.conversation_members (conversation_id, user_id)
    values (result_id, me), (result_id, target);
  end if;

  return result_id;
end;
$$;

-- Список чатов текущего пользователя.
create or replace function public.pinkchat_list_conversations()
returns table (
  conversation_id uuid,
  other_user_id uuid,
  other_name text,
  other_email text,
  avatar_url text,
  last_message text,
  last_message_at timestamptz,
  unread_count bigint
)
language sql
stable
security definer set search_path = public
as $$
  select
    c.id as conversation_id,
    other_profile.id as other_user_id,
    other_profile.display_name as other_name,
    other_profile.email as other_email,
    other_profile.avatar_url,
    coalesce(last_msg.body, case when last_msg.image_path is not null then '📷 Фотография' end) as last_message,
    last_msg.created_at as last_message_at,
    (
      select count(*)
      from public.messages unread
      where unread.conversation_id = c.id
        and unread.sender_id <> auth.uid()
        and unread.read_at is null
    ) as unread_count
  from public.conversation_members mine
  join public.conversations c on c.id = mine.conversation_id
  left join public.conversation_members other_member
    on other_member.conversation_id = c.id and other_member.user_id <> auth.uid()
  left join public.profiles other_profile on other_profile.id = other_member.user_id
  left join lateral (
    select m.body, m.image_path, m.created_at
    from public.messages m
    where m.conversation_id = c.id
    order by m.created_at desc
    limit 1
  ) last_msg on true
  where mine.user_id = auth.uid()
  order by last_msg.created_at desc nulls last, c.created_at desc;
$$;

create or replace function public.pinkchat_mark_read(target_conversation_id uuid)
returns void
language sql
security definer set search_path = public
as $$
  update public.messages
  set read_at = now()
  where conversation_id = target_conversation_id
    and sender_id <> auth.uid()
    and read_at is null
    and public.is_conversation_member(target_conversation_id, auth.uid());
$$;

-- RLS
alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.push_subscriptions enable row level security;

drop policy if exists "profiles readable by signed users" on public.profiles;
drop policy if exists "users read own profile" on public.profiles;
create policy "users read own profile"
on public.profiles for select to authenticated
using (id = auth.uid());

drop policy if exists "users update own profile" on public.profiles;
create policy "users update own profile"
on public.profiles for update to authenticated
using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "members read conversations" on public.conversations;
create policy "members read conversations"
on public.conversations for select to authenticated
using (public.is_conversation_member(id, auth.uid()));

drop policy if exists "members read membership" on public.conversation_members;
create policy "members read membership"
on public.conversation_members for select to authenticated
using (public.is_conversation_member(conversation_id, auth.uid()));

drop policy if exists "members read messages" on public.messages;
create policy "members read messages"
on public.messages for select to authenticated
using (public.is_conversation_member(conversation_id, auth.uid()));

drop policy if exists "members send messages" on public.messages;
create policy "members send messages"
on public.messages for insert to authenticated
with check (
  sender_id = auth.uid()
  and public.is_conversation_member(conversation_id, auth.uid())
);

drop policy if exists "users read own push subscriptions" on public.push_subscriptions;
create policy "users read own push subscriptions"
on public.push_subscriptions for select to authenticated
using (user_id = auth.uid());

drop policy if exists "users add own push subscriptions" on public.push_subscriptions;
create policy "users add own push subscriptions"
on public.push_subscriptions for insert to authenticated
with check (user_id = auth.uid());

drop policy if exists "users update own push subscriptions" on public.push_subscriptions;
create policy "users update own push subscriptions"
on public.push_subscriptions for update to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "users delete own push subscriptions" on public.push_subscriptions;
create policy "users delete own push subscriptions"
on public.push_subscriptions for delete to authenticated
using (user_id = auth.uid());

-- Закрытая папка для фотографий.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-media', 'chat-media', false, 10485760, array['image/jpeg','image/png','image/webp','image/heic','image/heif'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "chat members view media" on storage.objects;
create policy "chat members view media"
on storage.objects for select to authenticated
using (
  bucket_id = 'chat-media'
  and array_length(storage.foldername(name), 1) >= 2
  and public.is_conversation_member((storage.foldername(name))[2]::uuid, auth.uid())
);

drop policy if exists "chat members upload media" on storage.objects;
create policy "chat members upload media"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'chat-media'
  and (storage.foldername(name))[1] = auth.uid()::text
  and public.is_conversation_member((storage.foldername(name))[2]::uuid, auth.uid())
);

drop policy if exists "owners delete uploaded media" on storage.objects;
create policy "owners delete uploaded media"
on storage.objects for delete to authenticated
using (
  bucket_id = 'chat-media'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- Realtime для новых сообщений.
do $$
begin
  alter publication supabase_realtime add table public.messages;
exception
  when duplicate_object then null;
end $$;

grant usage on schema public to authenticated;
grant select, update on public.profiles to authenticated;
grant select on public.conversations, public.conversation_members to authenticated;
grant select, insert on public.messages to authenticated;
grant select, insert, update, delete on public.push_subscriptions to authenticated;
grant execute on function public.pinkchat_start_direct_chat(text) to authenticated;
grant execute on function public.pinkchat_list_conversations() to authenticated;
grant execute on function public.pinkchat_mark_read(uuid) to authenticated;

-- Security-definer функции недоступны анонимным посетителям.
revoke all on function public.is_conversation_member(uuid, uuid) from public, anon;
grant execute on function public.is_conversation_member(uuid, uuid) to authenticated;
revoke all on function public.pinkchat_start_direct_chat(text) from public, anon;
revoke all on function public.pinkchat_list_conversations() from public, anon;
revoke all on function public.pinkchat_mark_read(uuid) from public, anon;
grant execute on function public.pinkchat_start_direct_chat(text) to authenticated;
grant execute on function public.pinkchat_list_conversations() to authenticated;
grant execute on function public.pinkchat_mark_read(uuid) to authenticated;
