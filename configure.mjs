import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

function readArg(name) {
  const exact = process.argv.find((value) => value.startsWith(`--${name}=`));
  if (exact) return exact.slice(name.length + 3).trim();
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? String(process.argv[index + 1] || "").trim() : "";
}

const fromEnv = process.argv.includes("--from-env");
const supabaseUrl = fromEnv ? process.env.PINKCHAT_SUPABASE_URL || "" : readArg("url");
const supabaseAnonKey = fromEnv ? process.env.PINKCHAT_SUPABASE_ANON_KEY || "" : readArg("anon-key");
const vapidPublicKey = fromEnv ? process.env.PINKCHAT_VAPID_PUBLIC_KEY || "" : readArg("vapid-public-key");
const pushFunctionUrl = fromEnv
  ? process.env.PINKCHAT_PUSH_FUNCTION_URL || ""
  : readArg("push-function-url");

const normalizedUrl = supabaseUrl.replace(/\/+$/, "");
const config = {
  supabaseUrl: normalizedUrl,
  supabaseAnonKey,
  vapidPublicKey,
  pushFunctionUrl: pushFunctionUrl || (normalizedUrl ? `${normalizedUrl}/functions/v1/send-push` : "")
};

if (!fromEnv && (!config.supabaseUrl || !config.supabaseAnonKey)) {
  console.error("Укажите --url и --anon-key. Пример:\nnode scripts/configure.mjs --url https://PROJECT.supabase.co --anon-key KEY");
  process.exit(1);
}

const target = resolve("config.js");
const header = "// Публичные настройки PinkChat. Приватные ключи сюда добавлять нельзя.\n";
await writeFile(target, `${header}window.PINKCHAT_CONFIG = ${JSON.stringify(config, null, 2)};\n`, "utf8");

// Убеждаемся, что файл действительно записался и не пустой.
const saved = await readFile(target, "utf8");
if (!saved.includes("window.PINKCHAT_CONFIG")) throw new Error("config.js не записан");
console.log(config.supabaseUrl ? "config.js настроен для облачного режима" : "config.js оставлен в демо-режиме");
