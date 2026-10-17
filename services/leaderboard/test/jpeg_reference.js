// 测试用参照实现：jpeg-js 完整解码（IDCT + 上采样 + YCbCr→RGB）后逐像素算 dHash。
// 这是 DC-only 实现（src/cover_hash.js）替换掉的旧算法，与 Dart coverDHashOfImage 逐步一致；
// 测试拿它当「真值」对拍 DC-only 结果的汉明距离。只在测试里用，jpeg-js 是 devDependency。

import decodeJpeg from 'jpeg-js/lib/decoder.js';
import { jpegExifOrientation } from '../src/cover_hash.js';

/**
 * RGBA 像素按 orientation 摆正后的 dHash。与 Dart `getImageFromJpeg` 的 setPixel 映射一一对应：
 * 源 (x, y) 写到目标坐标，目标图按行优先遍历累加。
 * @param {{width: number, height: number, data: Uint8Array}} image
 */
export function dHashOfRgba(image, orientation = 0) {
  return dHashOfMeans(cellMeansOfRgba(image, orientation));
}

const COLS = 9;
const ROWS = 8;

/** 摆正后 9×8 格的平均灰度（0–1，行优先 72 个；空格子已按 Dart 规则填充）。 */
export function cellMeansOfRgba(image, orientation = 0) {
  const w = image.width;
  const h = image.height;
  const flip = orientation >= 5 && orientation <= 8;
  const W = flip ? h : w;
  const H = flip ? w : h;
  const gray = new Float64Array(W * H);
  const src = image.data;
  const w1 = w - 1;
  const h1 = h - 1;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const s = (y * w + x) * 4;
      let dx;
      let dy;
      switch (orientation) {
        case 2: dx = w1 - x; dy = y; break;
        case 3: dx = w1 - x; dy = h1 - y; break;
        case 4: dx = x; dy = h1 - y; break;
        case 5: dx = y; dy = x; break;
        case 6: dx = h1 - y; dy = x; break;
        case 7: dx = h1 - y; dy = w1 - x; break;
        case 8: dx = y; dy = w1 - x; break;
        default: dx = x; dy = y;
      }
      gray[dy * W + dx] = 0.299 * (src[s] / 255) + 0.587 * (src[s + 1] / 255) + 0.114 * (src[s + 2] / 255);
    }
  }
  const sum = new Float64Array(COLS * ROWS);
  const count = new Uint32Array(COLS * ROWS);
  for (let y = 0; y < H; y++) {
    const cy = Math.floor((y * ROWS) / H);
    for (let x = 0; x < W; x++) {
      const cell = cy * COLS + Math.floor((x * COLS) / W);
      sum[cell] += gray[y * W + x];
      count[cell]++;
    }
  }
  const mean = new Float64Array(COLS * ROWS);
  for (let y = 0; y < ROWS; y++) {
    let last = 0;
    for (let x = 0; x < COLS; x++) {
      const i = y * COLS + x;
      if (count[i] > 0) last = sum[i] / count[i];
      mean[i] = last;
    }
  }
  return mean;
}

function dHashOfMeans(mean) {
  let out = '';
  let nibble = 0;
  let bits = 0;
  for (let y = 0; y < ROWS; y++) {
    for (let x = 0; x < COLS - 1; x++) {
      nibble = (nibble << 1) | (mean[y * COLS + x] > mean[y * COLS + x + 1] ? 1 : 0);
      if (++bits === 4) {
        out += nibble.toString(16);
        nibble = 0;
        bits = 0;
      }
    }
  }
  return out;
}

function decode(bytes) {
  return decodeJpeg(bytes, { useTArray: true, formatAsRGBA: true, maxResolutionInMP: 1 });
}

/** jpeg-js 完整解码后的参照 dHash（按 EXIF 方向摆正）。 */
export function referenceDHashOfJpeg(bytes) {
  return dHashOfRgba(decode(bytes), jpegExifOrientation(bytes));
}

/**
 * hash 与参照结果不同的每一位，参照里那两个相邻格的平均灰度差（0–255 刻度）。全是「近似平局」
 * （差不到 1 个灰度级）说明分歧只来自解码器逐像素取整 / 截断的噪声，而不是算法错位——这种位
 * 换一个解码器（Dart image vs jpeg-js）一样会翻。
 */
export function flippedBitGaps(bytes, hash) {
  const mean = cellMeansOfRgba(decode(bytes), jpegExifOrientation(bytes));
  const ref = dHashOfMeans(mean);
  const gaps = [];
  for (let bit = 0; bit < 64; bit++) {
    const nib = bit >> 2;
    const mask = 8 >> (bit & 3);
    if ((parseInt(hash[nib], 16) & mask) === (parseInt(ref[nib], 16) & mask)) continue;
    const y = bit >> 3;
    const x = bit & 7;
    gaps.push(Math.abs(mean[y * COLS + x] - mean[y * COLS + x + 1]) * 255);
  }
  return gaps;
}
