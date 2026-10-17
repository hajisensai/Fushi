// 生成封面哈希跨语言对拍样本（一次性工具，产物入库）：
//   node test/gen_cover_fixtures.mjs
// 写出 test/cover_vectors/cover_*.jpg。Dart 侧（packages/fushi_engine/test/leaderboard/cover_hash_test.dart
// 「与 Worker 对拍」组）读同一批文件、断言 coverDHash 等于 test/cover_vectors/cover_hashes.json 里记的值；
// cover_hash.test.js 断言 Worker 的 coverDHashOfJpeg 与同一份 JSON 一致。改了样本要两边一起重算。

import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import encodeJpeg from 'jpeg-js/lib/encoder.js';
import { withExifOrientation } from './jpeg.js';

const out = (name) => fileURLToPath(new URL(`./cover_vectors/${name}`, import.meta.url));

/** 确定性伪随机（mulberry32），样本可复现。 */
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** 类封面的自然图：斜向渐变 + 几个彩色圆斑 + 噪点（像缩略图里的纹理）。 */
function natural(width, height, seed) {
  const r = rng(seed);
  const blobs = Array.from({ length: 6 }, () => ({
    x: r() * width, y: r() * height, rad: 10 + r() * width * 0.4, c: [r() * 255, r() * 255, r() * 255],
  }));
  const data = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      let c = [(x / width) * 200, (y / height) * 180, ((x + y) / (width + height)) * 120 + 40];
      for (const b of blobs) {
        const d = Math.hypot(x - b.x, y - b.y);
        if (d < b.rad) {
          const k = 1 - d / b.rad;
          c = c.map((v, i) => v * (1 - k) + b.c[i] * k);
        }
      }
      const n = (r() - 0.5) * 40;
      const o = (y * width + x) * 4;
      for (let i = 0; i < 3; i++) data[o + i] = Math.max(0, Math.min(255, Math.round(c[i] + n)));
      data[o + 3] = 255;
    }
  }
  return { width, height, data };
}

const portrait = new Uint8Array(encodeJpeg(natural(212, 300, 1), 80).data);
writeFileSync(out('cover_portrait.jpg'), portrait);
writeFileSync(out('cover_portrait_exif6.jpg'), withExifOrientation(portrait, 6));
writeFileSync(out('cover_landscape_q50.jpg'), new Uint8Array(encodeJpeg(natural(300, 169, 2), 50).data));
// 比 9×8 还小：走「空格子取同行左侧最近非空」分支。
writeFileSync(out('cover_tiny.jpg'), new Uint8Array(encodeJpeg(natural(5, 4, 3), 90).data));
