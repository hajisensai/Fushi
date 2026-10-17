// 服务端封面 dHash（src/cover_hash.js，只做熵解码、不做 IDCT）：与 Dart 引擎 cover_hash.dart 对拍、与 jpeg-js 完整解码
// 的逐像素参照对拍、EXIF 方向、编码变体（4:2:0 / 4:2:2 / 灰度 / DRI / progressive）、畸形输入。

import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import encodeJpeg from 'jpeg-js/lib/encoder.js';
import { coverJpeg, withExifOrientation } from './jpeg.js';
import { flippedBitGaps, referenceDHashOfJpeg } from './jpeg_reference.js';
import { COVER_DECODE_MAX_MP, COVER_MAX_EDGE, coverDHashOfJpeg, jpegExifOrientation, verifiedCoverHash } from '../src/cover_hash.js';
import { COVER_HASH_MAX_DISTANCE, hammingHex } from '../src/cover_votes.js';

const vectors = JSON.parse(readFileSync(new URL('./cover_vectors/cover_hashes.json', import.meta.url), 'utf8'));
const sample = (name) => new Uint8Array(readFileSync(new URL(`./cover_vectors/${name}`, import.meta.url)));
const dcDir = new URL('./cover_vectors/dc/', import.meta.url);
const dcSamples = readdirSync(dcDir).filter((f) => f.endsWith('.jpg')).sort();

/** 服务端哈希与真值允许的最大汉明距离（实测 0–2；归并阈值是 COVER_HASH_MAX_DISTANCE = 10）。 */
const SERVER_MAX_DISTANCE = 2;

/** 确定性伪随机（mulberry32）。 */
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

function rgba(width, height, fn) {
  const data = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const [r, g, b] = fn(x, y);
      const o = (y * width + x) * 4;
      data[o] = Math.max(0, Math.min(255, Math.round(r)));
      data[o + 1] = Math.max(0, Math.min(255, Math.round(g)));
      data[o + 2] = Math.max(0, Math.min(255, Math.round(b)));
      data[o + 3] = 255;
    }
  }
  return { width, height, data };
}

/** jpeg-js 编码的合成图：渐变 / 高频条纹 / 棋盘 / 带结构的随机块 / 自然图，含奇数与非 8 倍数尺寸。 */
function synthetic() {
  const out = [];
  const sizes = [[300, 212], [212, 300], [301, 169], [173, 257], [97, 131], [72, 64], [80, 300], [37, 53], [9, 8], [3, 2], [1, 1]];
  for (const [w, h] of sizes) {
    const r = rng(w * 1000 + h);
    const blobs = Array.from({ length: 5 }, () => ({ x: r() * w, y: r() * h, rad: 4 + r() * w * 0.5, c: [r() * 255, r() * 255, r() * 255] }));
    const cells = Array.from({ length: 64 }, () => [r() * 255, r() * 255, r() * 255]);
    const kinds = {
      gradient: (x, y) => [(x / w) * 255, (y / h) * 200 + 30, ((x + y) / (w + h)) * 255],
      stripes: (x, y) => ((x >> 1) & 1 ? [230, 220, 210] : [20, 30, 40]).map((v) => v * (0.4 + (0.6 * y) / h)),
      checker: (x, y) => (((x ^ y) & 1) ? [255, 255, 255] : [0, 0, 0]).map((v, i) => (i === 0 ? v * (x / w) : v)),
      blocks: (x, y) => cells[Math.floor((y * 8) / h) * 8 + Math.floor((x * 8) / w)],
      natural: (x, y) => {
        let c = [(x / w) * 200, (y / h) * 180, ((x + y) / (w + h)) * 120 + 40];
        for (const b of blobs) {
          const d = Math.hypot(x - b.x, y - b.y);
          if (d < b.rad) {
            const k = 1 - d / b.rad;
            c = c.map((v, i) => v * (1 - k) + b.c[i] * k);
          }
        }
        const n = (r() - 0.5) * 50;
        return c.map((v) => v + n);
      },
    };
    for (const [kind, fn] of Object.entries(kinds)) {
      for (const q of [50, 80, 95]) {
        out.push({ name: `${kind} ${w}x${h} q${q}`, bytes: new Uint8Array(encodeJpeg(rgba(w, h, fn), q).data) });
      }
    }
  }
  return out;
}

describe('与 Dart coverDHash 对拍（test/cover_vectors/cover_hashes.json）', () => {
  it('全部样本（jpeg-js 编码、EXIF 6、比 9×8 还小、Dart encodeJpg q80）：服务端哈希与 Dart 值汉明距离 ≤ 2', () => {
    const all = { ...vectors.exact, ...vectors.dartEncoded };
    expect(Object.keys(all).length).toBeGreaterThanOrEqual(5);
    const distances = {};
    for (const [name, dart] of Object.entries(all)) distances[name] = hammingHex(coverDHashOfJpeg(sample(name)), dart);
    console.log('server vs Dart:', JSON.stringify(distances));
    for (const [name, d] of Object.entries(distances)) expect([name, d <= SERVER_MAX_DISTANCE]).toEqual([name, true]);
  });

  it('小图（宽 < 72 或高 < 64：一个块横跨好几格，靠切片系数而不是块均值）：5×4 的样本与 Dart 逐位一致', () => {
    expect(coverDHashOfJpeg(sample('cover_tiny.jpg'))).toBe(vectors.exact['cover_tiny.jpg']);
  });
});

describe('与 jpeg-js 完整解码的逐像素参照对拍', () => {
  it('libjpeg 编码变体（4:2:0 / 4:2:2 奇数尺寸 / 灰度 / DRI+RSTn / progressive / 小图）：距离 ≤ 2', () => {
    expect(dcSamples.length).toBeGreaterThanOrEqual(10);
    const distances = {};
    for (const name of dcSamples) {
      const bytes = new Uint8Array(readFileSync(new URL(name, dcDir)));
      const dc = coverDHashOfJpeg(bytes);
      expect([name, dc === null]).toEqual([name, false]);
      distances[name] = hammingHex(dc, referenceDHashOfJpeg(bytes));
      for (const g of flippedBitGaps(bytes, dc)) expect([name, g < 1]).toEqual([name, true]);
    }
    console.log('server vs jpeg-js (libjpeg variants):', JSON.stringify(distances));
    for (const [name, d] of Object.entries(distances)) expect([name, d <= SERVER_MAX_DISTANCE]).toEqual([name, true]);
  });

  it('上述变体 × 8 种 EXIF 方向：每个分歧位都是参照里差不到 1 个灰度级的近似平局', () => {
    // 300×40 转置成 40×300 后每格只有 4–5 像素宽，平滑图上相邻格几乎等亮：实测 80 个组合里 1 个距离 3
    // （三位的参照差 0.017 / 0.029 / 0.080 灰度级），其余 ≤ 2。距离只记录，钉的是「分歧只在平局位」。
    const hist = {};
    for (const name of dcSamples) {
      const base = new Uint8Array(readFileSync(new URL(name, dcDir)));
      for (let o = 1; o <= 8; o++) {
        const bytes = withExifOrientation(base, o);
        const hash = coverDHashOfJpeg(bytes);
        const d = hammingHex(hash, referenceDHashOfJpeg(bytes));
        hist[d] = (hist[d] || 0) + 1;
        for (const g of flippedBitGaps(bytes, hash)) expect([name, o, g < 1]).toEqual([name, o, true]);
      }
    }
    console.log('server vs jpeg-js (variants x EXIF 1-8) distance histogram:', JSON.stringify(hist));
  });

  it('jpeg-js 编码的合成图（渐变 / 高频棋盘 / 随机块 / 自然图，奇数与非 8 倍数尺寸，q50–95）：距离 ≤ 2', () => {
    const hist = {};
    for (const { name, bytes } of synthetic().filter((s) => !s.name.startsWith('stripes'))) {
      const d = hammingHex(coverDHashOfJpeg(bytes), referenceDHashOfJpeg(bytes));
      hist[d] = (hist[d] || 0) + 1;
      expect([name, d <= SERVER_MAX_DISTANCE]).toEqual([name, true]);
    }
    console.log('server vs jpeg-js (synthetic) distance histogram:', JSON.stringify(hist));
  });

  it('构造的平局图（每行各格本应等亮的竖条纹）：分歧位全是参照里差不到 1 个灰度级的近似平局', () => {
    // 竖条纹整行各格源图等亮，哪一位是 1 取决于解码器逐像素取整的噪声：实测 Dart image 与 jpeg-js
    // 在这批图上本身就差到 24 位，服务端哈希与 Dart 的距离反而更小。这里不比距离，只钉「分歧不来自
    // 算法错位」：每个翻转位在参照里的两格差都 < 1 个灰度级。
    const gaps = [];
    for (const { name, bytes } of synthetic().filter((s) => s.name.startsWith('stripes'))) {
      for (const g of flippedBitGaps(bytes, coverDHashOfJpeg(bytes))) {
        gaps.push(g);
        expect([name, g < 1]).toEqual([name, true]);
      }
    }
    console.log('stripes: flipped bits', gaps.length, 'max gap (gray levels)', Math.max(0, ...gaps).toFixed(3));
  });
});

describe('coverDHashOfJpeg', () => {
  it('coverJpeg(h) 构造的图在各种质量 / 色调下都算回 h（测试装置自身的正确性）', () => {
    for (const h of ['0000000000000000', 'ffffffffffffffff', '0123456789abcdef', 'a5a55a5a0ff0f00f']) {
      for (const quality of [50, 80, 95]) {
        expect(coverDHashOfJpeg(coverJpeg(h, { quality, tint: [30, -20, 10] }))).toBe(h);
      }
    }
  });

  it('EXIF 方向：读 IFD0 Orientation，按 Dart image 的烘焙方式摆正后再算', () => {
    const base = coverJpeg('0123456789abcdef');
    expect(jpegExifOrientation(base)).toBe(0);
    for (let o = 1; o <= 8; o++) expect(jpegExifOrientation(withExifOrientation(base, o))).toBe(o);
    expect(coverDHashOfJpeg(withExifOrientation(base, 1))).toBe('0123456789abcdef');
    // Orientation 写成 LONG（类型 4）的少数写入器：值照读（Dart image 也认）。
    const long = withExifOrientation(base, 6);
    const tag = long.findIndex((v, i) => v === 0x12 && long[i + 1] === 0x01 && long[i + 2] === 0x03);
    long[tag + 2] = 0x04;
    expect(jpegExifOrientation(long)).toBe(6);
    expect(coverDHashOfJpeg(long)).toBe(coverDHashOfJpeg(withExifOrientation(base, 6)));
    // 水平镜像（2）：每行左右颠倒，与原图不同。
    expect(coverDHashOfJpeg(withExifOrientation(base, 2))).not.toBe('0123456789abcdef');
    for (let o = 2; o <= 8; o++) {
      const bytes = withExifOrientation(sample('cover_portrait.jpg'), o);
      expect([o, hammingHex(coverDHashOfJpeg(bytes), referenceDHashOfJpeg(bytes)) <= SERVER_MAX_DISTANCE]).toEqual([o, true]);
    }
  });

  it('不是 JPEG / 截断 / 解压炸弹 → null', () => {
    expect(coverDHashOfJpeg(new Uint8Array([0x89, 0x50, 0x4e, 0x47]))).toBeNull();
    expect(coverDHashOfJpeg(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0x10]))).toBeNull();
    const bomb = coverJpeg('0123456789abcdef');
    const sof = bomb.findIndex((b, i) => b === 0xff && bomb[i + 1] === 0xc0);
    bomb.set([0xea, 0x60, 0xea, 0x60], sof + 5);
    expect(coverDHashOfJpeg(bomb)).toBeNull();
  });
});

describe('畸形 / 不支持的输入：拒绝且不超时', () => {
  const real = sample('cover_dart_q80.jpg');
  const sofAt = (b) => b.findIndex((v, i) => v === 0xff && (b[i + 1] === 0xc0 || b[i + 1] === 0xc2));

  it('任意位置截断 → null（没有 EOI 或熵数据读到填充比特都判截断）', () => {
    for (let n = 3; n < real.length; n += 37) expect([n, coverDHashOfJpeg(real.subarray(0, n))]).toEqual([n, null]);
    // 熵数据中段截断后补上 EOI：读到标记后的填充比特被消耗 → 截断。
    for (const cut of [800, 3000, 9000]) {
      const b = new Uint8Array(cut + 2);
      b.set(real.subarray(0, cut));
      b.set([0xff, 0xd9], cut);
      expect([cut, coverDHashOfJpeg(b)]).toEqual([cut, null]);
    }
  });

  it('SOI 后随机字节 → null', () => {
    const r = rng(7);
    for (let i = 0; i < 200; i++) {
      const b = new Uint8Array(64 + Math.floor(r() * 4000));
      for (let j = 0; j < b.length; j++) b[j] = Math.floor(r() * 256);
      b.set([0xff, 0xd8, 0xff]);
      expect(coverDHashOfJpeg(b)).toBeNull();
    }
  });

  it('随机篡改字节（含表、帧头、熵数据）：要么算出哈希要么 null，绝不抛异常', () => {
    const r = rng(11);
    const bases = [real, sample('cover_tiny.jpg'), ...dcSamples.map((n) => new Uint8Array(readFileSync(new URL(n, dcDir))))];
    for (let i = 0; i < 600; i++) {
      const b = bases[i % bases.length].slice();
      const edits = 1 + Math.floor(r() * 8);
      // 一半篡改落在头部（段结构 / 表），一半随机落在任意位置。
      for (let k = 0; k < edits; k++) b[Math.floor(r() * (i & 1 ? b.length : Math.min(b.length, 700)))] = Math.floor(r() * 256);
      const h = coverDHashOfJpeg(b);
      expect(h === null || /^[0-9a-f]{16}$/.test(h)).toBe(true);
    }
  });

  it('尺寸上限：合法编码的 320×320 照算（8 种方向），长边 321 拒绝（400 bad_cover_image）', () => {
    const img = (w, h) => new Uint8Array(encodeJpeg(rgba(w, h, (x, y) => [x % 256, y % 256, 160]), 50).data);
    expect(COVER_MAX_EDGE).toBe(320);
    const ok = img(320, 320);
    for (let o = 1; o <= 8; o++) expect(coverDHashOfJpeg(withExifOrientation(ok, o))).toMatch(/^[0-9a-f]{16}$/);
    for (const [w, h] of [[321, 100], [100, 321], [321, 321]]) {
      expect(() => verifiedCoverHash(img(w, h), null)).toThrow(expect.objectContaining({ status: 400, code: 'bad_cover_image' }));
    }
  });

  it('超大 SOF（超过尺寸上限）/ 宽或高为 0 → null', () => {
    for (const [w, h] of [[65535, 65535], [600, 500], [0, 300], [300, 0]]) {
      expect(w > COVER_MAX_EDGE || h > COVER_MAX_EDGE || w * h > COVER_DECODE_MAX_MP * 1e6 || w * h === 0).toBe(true);
      const b = real.slice();
      const s = sofAt(b);
      b.set([h >> 8, h & 255, w >> 8, w & 255], s + 5);
      expect([w, h, coverDHashOfJpeg(b)]).toEqual([w, h, null]);
    }
  });

  it('不支持的编码：算术编码（SOF9）/ lossless（SOF3）/ 12 位精度 / 4 分量（CMYK）/ 亮度被下采样 → null', () => {
    const s = sofAt(real);
    const withByte = (off, v) => { const b = real.slice(); b[off] = v; return b; };
    expect(coverDHashOfJpeg(withByte(s + 1, 0xc9))).toBeNull();
    expect(coverDHashOfJpeg(withByte(s + 1, 0xc3))).toBeNull();
    expect(coverDHashOfJpeg(withByte(s + 4, 12))).toBeNull();
    expect(coverDHashOfJpeg(withByte(s + 9, 4))).toBeNull();
    // Y 1×1、Cb 2×2：亮度不是最大采样因子。
    expect(coverDHashOfJpeg(withByte(s + 14, 0x22))).toBeNull();
  });

  it('非法 Huffman 表：码长计数溢出 → null（即使多出的码字在数据里从没出现）', () => {
    // Dart encodeJpg 用标准表：亮度 AC 表 16 位码长用掉 65535/65536 个码字。往 16 位码长再塞 2 个符号
    // 就溢出；多出的码字数据里不会出现，所以不做溢出检查的解码器照样能解出哈希——这里必须拒绝。
    const dhtAt = real.findIndex((v, i) => v === 0xff && real[i + 1] === 0xc4);
    const segEnd = dhtAt + 2 + ((real[dhtAt + 2] << 8) | real[dhtAt + 3]);
    const body = [];
    for (let q = dhtAt + 4; q < segEnd;) {
      const counts = Array.from(real.subarray(q + 1, q + 17));
      const total = counts.reduce((x, y) => x + y, 0);
      const syms = Array.from(real.subarray(q + 17, q + 17 + total));
      if (real[q] === 0x10) {
        counts[15] += 2;
        syms.push(0x01, 0x02);
      }
      body.push(real[q], ...counts, ...syms);
      q += 17 + total;
    }
    const seg = [0xff, 0xc4, (body.length + 2) >> 8, (body.length + 2) & 255, ...body];
    const b = new Uint8Array([...real.subarray(0, dhtAt), ...seg, ...real.subarray(segEnd)]);
    expect(b.length).toBe(real.length + 2);
    expect(coverDHashOfJpeg(b)).toBeNull();
  });

  it('构造的最坏输入（320×320 帧头 + 全 0 熵数据 ≈ 96KB）在毫秒级结束', () => {
    const b = real.slice();
    const s = sofAt(b);
    b.set([0x01, 0x40, 0x01, 0x40], s + 5); // 320×320 = 尺寸上限
    const sos = b.findIndex((v, i) => v === 0xff && b[i + 1] === 0xda);
    const hdr = sos + 2 + ((b[sos + 2] << 8) | b[sos + 3]);
    const evil = new Uint8Array(96 * 1024);
    evil.set(b.subarray(0, hdr));
    evil.set([0xff, 0xd9], evil.length - 2);
    const t0 = performance.now();
    const h = coverDHashOfJpeg(evil);
    const ms = performance.now() - t0;
    expect(h === null || /^[0-9a-f]{16}$/.test(h)).toBe(true);
    expect(ms).toBeLessThan(500);
  });

  it('构造的最密符号输入（1 位 Huffman 码 + 320×320 三分量 + 96KB 全 0 熵数据：每个比特都在解系数）有界', () => {
    // DC 表：'0' → 差分 0；AC 表：'0' → (游程 0, 幅值 1 位)、'1' → EOB。全 0 数据 = 每块 63 个系数、每个 2 位，
    // 是每比特解码工作量最大的形态。320×320 三分量要 4800 块 × 127 位 ≈ 74KB，96KB 内解得完，算出的是
    // 一张平图的哈希；要的只是有界。
    const seg = (m, body) => [0xff, m, (body.length + 2) >> 8, (body.length + 2) & 255, ...body];
    const head = [
      0xff, 0xd8,
      ...seg(0xdb, [0x00, ...new Array(64).fill(1)]),
      ...seg(0xc0, [8, 0x01, 0x40, 0x01, 0x40, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0]),
      ...seg(0xc4, [0x00, 2, ...new Array(15).fill(0), 0x00, 0x01]),
      ...seg(0xc4, [0x10, 2, ...new Array(15).fill(0), 0x01, 0x00]),
      ...seg(0xda, [3, 1, 0x00, 2, 0x00, 3, 0x00, 0, 63, 0]),
    ];
    const evil = new Uint8Array(96 * 1024);
    evil.set(head);
    evil.set([0xff, 0xd9], evil.length - 2);
    const t0 = performance.now();
    const h = coverDHashOfJpeg(evil);
    const ms = performance.now() - t0;
    console.log('densest-symbol worst case:', ms.toFixed(1), 'ms');
    expect(h === null || /^[0-9a-f]{16}$/.test(h)).toBe(true);
    expect(ms).toBeLessThan(500);
  });
});

describe('构造的 CPU 炸弹（test/cover_vectors/adversarial/，对抗审查产出）', () => {
  const advDir = new URL('./cover_vectors/adversarial/', import.meta.url);
  const adv = (name) => new Uint8Array(readFileSync(new URL(name, advDir)));
  // 格式本身合法、只是结构夸张的（几千个 Exif 段 / 每块一个 RST / 全 16 位码字）：照算，只要求有界。
  // 原样本 adv_rst_storm / adv_slow_huff_16bit 是 500×500，尺寸上限收到 320 后被拒；*_320 是同一构造的 320×320 版。
  const ACCEPTED = new Set(['adv_exif_storm.jpg', 'adv_rst_storm_320.jpg', 'adv_slow_huff_16bit_320.jpg']);
  const timed = (b) => {
    const t0 = performance.now();
    let r;
    try {
      r = verifiedCoverHash(b, null);
    } catch (e) {
      r = e;
    }
    return { r, ms: performance.now() - t0 };
  };

  it('扫描风暴 / 表风暴 / 细长图 / 填充风暴 / fuzz 最坏样本：400 bad_cover_image，单次 < 20 ms', () => {
    const names = readdirSync(advDir).filter((f) => f.endsWith('.jpg') && !ACCEPTED.has(f)).sort();
    expect(names).toEqual(expect.arrayContaining([
      'adv_baseline_scan_storm.jpg', 'adv_prog_dc_refine_storm.jpg', 'adv_prog_dc_first_storm.jpg',
      'adv_prog_ac_skip_storm.jpg', 'adv_dht_storm.jpg', 'adv_dqt_storm.jpg', 'adv_tall_1x250000.jpg',
      'adv_tall_full_coeffs.jpg', 'adv_fuzz_worst.jpg',
    ]));
    for (const name of names) {
      const { r, ms } = timed(adv(name));
      expect([name, r.status, r.code]).toEqual([name, 400, 'bad_cover_image']);
      expect([name, ms < 20]).toEqual([name, true]);
    }
  });

  it('结构夸张但合法的（Exif 段风暴 / RST 风暴 / 全 16 位码字）：算出哈希，单次 < 20 ms', () => {
    for (const name of ACCEPTED) {
      const { r, ms } = timed(adv(name));
      expect([name, typeof r === 'string' && /^[0-9a-f]{16}$/.test(r)]).toEqual([name, true]);
      expect([name, ms < 20]).toEqual([name, true]);
    }
  });

  it('上限不误伤：正常 progressive（10 个扫描）、300×40 细条（每块都被切开）照算', () => {
    expect(coverDHashOfJpeg(new Uint8Array(readFileSync(new URL('progressive_444_dri.jpg', dcDir))))).toMatch(/^[0-9a-f]{16}$/);
    expect(coverDHashOfJpeg(new Uint8Array(readFileSync(new URL('small_strip_420.jpg', dcDir))))).toMatch(/^[0-9a-f]{16}$/);
  });
});

describe('verifiedCoverHash', () => {
  const real = coverJpeg('0123456789abcdef');
  it('返回服务端哈希；声称值在阈值内照收，超过阈值 400 cover_hash_mismatch', () => {
    expect(verifiedCoverHash(real, null)).toBe('0123456789abcdef');
    expect(verifiedCoverHash(real, '0123456789ABCDEF')).toBe('0123456789abcdef');
    expect(verifiedCoverHash(real, '0123456789abcde0')).toBe('0123456789abcdef'); // 差 4 位
    expect(() => verifiedCoverHash(real, 'fedcba9876543210')).toThrow(
      expect.objectContaining({ status: 400, code: 'cover_hash_mismatch' }),
    );
    expect(() => verifiedCoverHash(real, 'nothex')).toThrow(expect.objectContaining({ status: 400, code: 'bad_cover_hash' }));
  });

  it('不是 JPEG → 415 cover_not_jpeg；JPEG 但解不开 / 不支持（如算术编码）→ 400 bad_cover_image', () => {
    expect(() => verifiedCoverHash(new Uint8Array([0x89, 0x50, 0x4e, 0x47]), null)).toThrow(
      expect.objectContaining({ status: 415, code: 'cover_not_jpeg' }),
    );
    const arith = real.slice();
    arith[arith.findIndex((v, i) => v === 0xff && arith[i + 1] === 0xc0) + 1] = 0xc9;
    expect(() => verifiedCoverHash(arith, null)).toThrow(expect.objectContaining({ status: 400, code: 'bad_cover_image' }));
  });

  it('客户端 Dart 哈希 vs 服务端哈希：所有对拍样本都远在 COVER_HASH_MAX_DISTANCE 内（不会误判 mismatch）', () => {
    for (const [name, dart] of Object.entries({ ...vectors.exact, ...vectors.dartEncoded })) {
      expect(verifiedCoverHash(sample(name), dart)).toMatch(/^[0-9a-f]{16}$/);
      expect(hammingHex(verifiedCoverHash(sample(name), null), dart)).toBeLessThan(COVER_HASH_MAX_DISTANCE);
    }
  });
});
