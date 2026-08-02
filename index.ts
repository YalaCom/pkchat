import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authorization = req.headers.get("Authorization");
    if (!authorization) return json({ error: "Unauthorized" }, 401);

    const url = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const vapidPublic = Deno.env.get("VAPID_PUBLIC_KEY")!;
    const vapidPrivate = Deno.env.get("VAPID_PRIVATE_KEY")!;
    const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "mailto:admin@example.com";

    const userClient = createClient(url, anonKey, {
      global: { headers: { Authorization: authorization } },
    });
    const admin = createClient(url, serviceRole);

    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) return json({ error: "Unauthorized" }, 401);

    const { messageId } = await req.json();
    if (!messageId) return json({ error: "messageId is required" }, 400);

    const { data: message, error: messageError } = await admin
      .from("messages")
      .select("id, conversation_id, sender_id, body, image_path")
      .eq("id", messageId)
      .single();
    if (messageError || !message) return json({ error: "Message not found" }, 404);
    if (message.sender_id !== userData.user.id) return json({ error: "Forbidden" }, 403);

    const { data: sender } = await admin
      .from("profiles")
      .select("display_name")
      .eq("id", message.sender_id)
      .single();

    const { data: members, error: membersError } = await admin
      .from("conversation_members")
      .select("user_id")
      .eq("conversation_id", message.conversation_id)
      .neq("user_id", message.sender_id);
    if (membersError) throw membersError;

    const recipientIds = (members || []).map((member) => member.user_id);
    if (!recipientIds.length) return json({ sent: 0 });

    const { data: subscriptions, error: subscriptionError } = await admin
      .from("push_subscriptions")
      .select("id, endpoint, p256dh, auth")
      .in("user_id", recipientIds);
    if (subscriptionError) throw subscriptionError;

    webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);
    const payload = JSON.stringify({
      title: sender?.display_name || "PinkChat",
      body: message.body || (message.image_path ? "📷 Фотография" : "Новое сообщение"),
      tag: `conversation-${message.conversation_id}`,
      conversationId: message.conversation_id,
      url: `./?conversation=${message.conversation_id}`,
    });

    let sent = 0;
    const expiredIds: string[] = [];
    await Promise.allSettled((subscriptions || []).map(async (subscription) => {
      try {
        await webpush.sendNotification({
          endpoint: subscription.endpoint,
          keys: { p256dh: subscription.p256dh, auth: subscription.auth },
        }, payload, { TTL: 60 * 60 });
        sent += 1;
      } catch (error) {
        const statusCode = (error as { statusCode?: number }).statusCode;
        if (statusCode === 404 || statusCode === 410) expiredIds.push(subscription.id);
        else console.error("Push failed", error);
      }
    }));

    if (expiredIds.length) await admin.from("push_subscriptions").delete().in("id", expiredIds);
    return json({ sent, expiredRemoved: expiredIds.length });
  } catch (error) {
    console.error(error);
    return json({ error: error instanceof Error ? error.message : "Unknown error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
