import { generateKeyPairSync } from "node:crypto";

function base64UrlToBuffer(value) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padding = "=".repeat((4 - (normalized.length % 4)) % 4);
  return Buffer.from(normalized + padding, "base64");
}

const { publicKey, privateKey } = generateKeyPairSync("ec", {
  namedCurve: "prime256v1",
  publicKeyEncoding: { format: "jwk" },
  privateKeyEncoding: { format: "jwk" }
});

if (!publicKey.x || !publicKey.y || !privateKey.d) {
  throw new Error("Не удалось экспортировать VAPID-ключи");
}

const uncompressedPublicKey = Buffer.concat([
  Buffer.from([0x04]),
  base64UrlToBuffer(publicKey.x),
  base64UrlToBuffer(publicKey.y)
]);

console.log("VAPID_PUBLIC_KEY=" + uncompressedPublicKey.toString("base64url"));
console.log("VAPID_PRIVATE_KEY=" + privateKey.d);
console.log("\nПриватный ключ нельзя добавлять в config.js или публиковать на GitHub.");
