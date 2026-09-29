// 生成一条跨语言签名测试向量（JWK 私钥 + 签名串 + P1363 签名）。一次性工具：
//   node test/gen_vector.mjs > test/vectors/js-webcrypto.json
// Dart 客户端（P2）用同一文件验证「JS 签的 Dart 能验、签名串拼法一致」，
// 并另外生成 dart-*.json 放进 vectors/，由 vectors.test.js 验证「Dart 签的 Worker 能验」。

import { signingString, accountIdFromSpki } from '../src/auth.js';
import { b64urlEncode } from '../src/util.js';

const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
const jwk = await crypto.subtle.exportKey('jwk', pair.privateKey);
const spki = new Uint8Array(await crypto.subtle.exportKey('spki', pair.publicKey));
const method = 'POST';
const path = '/v1/shelf?x=1';
const time = 1790000000000;
const body = JSON.stringify({ entries: [{ kind: 'book', refs: ['isbn:9784040000011'], title: '冴えない彼女の育てかた 11' }] });
const message = await signingString(method, path, time, new TextEncoder().encode(body));
const sig = new Uint8Array(
  await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, new TextEncoder().encode(message)),
);
console.log(JSON.stringify({
  producer: 'js-webcrypto',
  jwk: { kty: jwk.kty, crv: jwk.crv, d: jwk.d, x: jwk.x, y: jwk.y },
  spki: b64urlEncode(spki),
  accountId: await accountIdFromSpki(spki),
  method,
  path,
  time,
  body,
  message,
  signature: b64urlEncode(sig),
}, null, 2));
