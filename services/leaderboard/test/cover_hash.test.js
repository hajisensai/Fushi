// 服务端封面 dHash（src/cover_hash.js）：与 Dart 引擎 cover_hash.dart 对拍、EXIF 方向、解码上限。

import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { coverJpeg, withExifOrientation } from './jpeg.js';
import { coverDHashOfJpeg, jpegExifOrientation, verifiedCoverHash } from '../src/cover_hash.js';
import { COVER_HASH_MAX_DISTANCE, hammingHex } from '../src/cover_votes.js';

const vectors = JSON.parse(readFileSync(new URL('./cover_vectors/cover_hashes.json', import.meta.url), 'utf8'));
const sample = (name) => new Uint8Array(readFileSync(new URL(`./cover_vectors/${name}`, import.meta.url)));

describe('与 Dart coverDHash 对拍（test/cover_vectors/cover_hashes.json）', () => {
  it('jpeg-js 编码的样本：逐位一致（含 EXIF Orientation=6 与比 9×8 还小的图）', () => {
    expect(Object.keys(vectors.exact).length).toBeGreaterThanOrEqual(4);
    for (const [name, dart] of Object.entries(vectors.exact)) {
      expect([name, coverDHashOfJpeg(sample(name))]).toEqual([name, dart]);
    }
  });

  it('Dart image 编码的缩略图（App 实际上传的那种）：两边解码器舍入不同，实测差 1 位，远在阈值内', () => {
    for (const [name, dart] of Object.entries(vectors.dartEncoded)) {
      const d = hammingHex(coverDHashOfJpeg(sample(name)), dart);
      expect(d).toBeLessThanOrEqual(2);
      expect(d).toBeLessThan(COVER_HASH_MAX_DISTANCE);
    }
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
    // 水平镜像（2）：每行左右颠倒，与原图不同。
    expect(coverDHashOfJpeg(withExifOrientation(base, 2))).not.toBe('0123456789abcdef');
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
});
