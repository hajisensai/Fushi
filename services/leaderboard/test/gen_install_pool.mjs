// 生成 installs.test.js 用的固定安装池（P-256 JWK 私钥 + 指纹 id + 已求好的 PoW nonce）。
//   node test/gen_install_pool.mjs > test/install_pool.json
// 为什么要固定池：每次现场生成随机钥匙再解 INSTALL_POW_BITS 位 PoW，求解次数服从几何分布、长尾很重，
// 一条测试里造 2~3 个安装就会随机超过 vitest 的 5 秒超时（CI 上不同用例轮流超时）。
// 调高 INSTALL_POW_BITS 后池会失效，installs.test.js 的池校验用例会变红，重新跑本脚本即可。

import { createHash } from 'node:crypto';
import { INSTALL_POW_BITS, installIdFromSpki } from '../src/installs.js';

const SIZE = 32;

function zeroBits(buf, bits) {
  for (let i = 0; i < bits; i += 1) {
    if ((buf[i >> 3] >> (7 - (i & 7))) & 1) return false;
  }
  return true;
}

const installs = [];
for (let i = 0; i < SIZE; i += 1) {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const jwk = await crypto.subtle.exportKey('jwk', pair.privateKey);
  const spki = new Uint8Array(await crypto.subtle.exportKey('spki', pair.publicKey));
  const installId = await installIdFromSpki(spki);
  let n = 0;
  while (!zeroBits(createHash('sha256').update(`fip1|${installId}|${n}`).digest(), INSTALL_POW_BITS)) n += 1;
  installs.push({ jwk: { kty: jwk.kty, crv: jwk.crv, d: jwk.d, x: jwk.x, y: jwk.y }, installId, pow: String(n) });
}
console.log(JSON.stringify({ powBits: INSTALL_POW_BITS, installs }, null, 2));
