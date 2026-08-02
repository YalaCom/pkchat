-- Выполняется ПОСЛЕ регистрации владельца в PinkChat.
-- Замени email ниже на email аккаунта Томши Евгения.
alter table public.profiles add column if not exists is_admin boolean not null default false;
update public.profiles set is_admin = true, display_name = 'Томша Евгений' where email = 'CHANGE_ME@example.com';
