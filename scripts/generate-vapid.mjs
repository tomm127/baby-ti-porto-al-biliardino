import { generateKeyPairSync } from 'node:crypto';

const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const pub = publicKey.export({ format: 'jwk' });
const priv = privateKey.export({ format: 'jwk' });

function decodeBase64Url(value) {
  return Buffer.from(value.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

function encodeBase64Url(buffer) {
  return Buffer.from(buffer).toString('base64url');
}

const x = decodeBase64Url(pub.x);
const y = decodeBase64Url(pub.y);
const d = decodeBase64Url(priv.d);
const uncompressedPublic = Buffer.concat([Buffer.from([0x04]), x, y]);

console.log('VAPID_PUBLIC_KEY=' + encodeBase64Url(uncompressedPublic));
console.log('VAPID_PRIVATE_KEY=' + encodeBase64Url(d));
console.log('\nPUBLIC può stare in .env.local. PRIVATE va SOLO nei secrets di Supabase.');
