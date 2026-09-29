// 跨语言签名向量：vectors/ 下每个文件（JS 生成的、以及 Dart 客户端生成的）都必须
// ① 签名串按本服务的拼法逐字节一致 ② 账户 id 推导一致 ③ 签名能被 Worker 验过。
import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { accountIdFromSpki, importPublicKey, signingString, verifySignature } from '../src/auth.js';
import { b64urlDecode } from '../src/util.js';

const DIR = fileURLToPath(new URL('./vectors/', import.meta.url));
const files = readdirSync(DIR).filter((f) => f.endsWith('.json'));

describe('跨语言签名向量', () => {
  it('至少有一条向量', () => expect(files.length).toBeGreaterThan(0));

  for (const f of files) {
    it(f, async () => {
      const v = JSON.parse(readFileSync(DIR + f, 'utf8'));
      const msg = await signingString(v.method, v.path, v.time, new TextEncoder().encode(v.body));
      expect(msg).toBe(v.message);
      const spki = b64urlDecode(v.spki);
      expect(await accountIdFromSpki(spki)).toBe(v.accountId);
      expect(await verifySignature(await importPublicKey(spki), v.signature, msg)).toBe(true);
      // 负向：改一个字节就不过。
      expect(await verifySignature(await importPublicKey(spki), v.signature, msg + ' ')).toBe(false);
    });
  }
});
