// 封面缩略图的感知哈希（dHash，64 位），服务端自己算。
//
// 为什么服务端必须自己算：候选按哈希归并（cover_votes.js），后到者哈希命中就只投票、不再存图。
// 如果信任客户端上报的哈希，任何人都能上传一张任意图片并声称它是正版封面的哈希，抢先占住
// 那个哈希的候选，之后所有持正版封面的人的票都会投到他的图上。所以：候选的 phash 一律是本文件
// 从上传字节里算出来的；客户端声称的哈希只用来核对（差太多 → 400 cover_hash_mismatch）。
//
// 算法与 App / 无头服务端的 packages/fushi_engine/lib/leaderboard/cover_hash.dart 逐步一致：
//   1. 解码 JPEG，按 EXIF Orientation 摆正（Dart 的 image 包解码时就会烘焙方向）；
//   2. 灰度 = ITU-R BT.601 亮度：0.299·R/255 + 0.587·G/255 + 0.114·B/255；
//   3. 按面积平均缩成 9×8：像素 (x, y) 落进格子 (⌊x·9/w⌋, ⌊y·8/h⌋)，按行优先顺序累加、格内求平均；
//      源图比 9×8 还小时有空格子：取同一行左侧最近的非空格子（第一格空就取 0）；
//   4. 每行相邻两格比较，左格比右格亮记 1，共 64 位，行优先、高位在前；
//   5. 输出 16 位小写 hex。
// 两边 JPEG 解码器（jpeg-js / Dart image）的 IDCT 与色彩转换舍入可能有极小差异，所以核对用的是
// 汉明距离阈值而不是逐位相等。
//
// 只收 JPEG：App（downsampleCardScreenshot，encoding = jpeg，且产物不是 JPEG 就不传）与无头服务端
// （encodeLeaderboardCoverThumb → encodeJpg）上传的封面缩略图一律是 JPEG。

import decodeJpeg from 'jpeg-js/lib/decoder.js';
import { HttpError } from './util.js';
import { COVER_HASH_MAX_DISTANCE, hammingHex, normalizeCoverHash } from './cover_votes.js';

const COLS = 9;
const ROWS = 8;

/**
 * 解码像素上限。客户端缩略图长边 ≤ 300（≤ 0.09 MP）；这里留余量但防解压炸弹——96KB 的 JPEG
 * 可以在帧头里声称 65535×65535，jpeg-js 在读到帧头时就按这个上限拒绝，不会先分配内存。
 */
export const COVER_DECODE_MAX_MP = 0.25;
/** jpeg-js 解码过程的内存上限（0.25 MP 的 RGBA 约 1MB，系数块与中间缓冲另计）。 */
export const COVER_DECODE_MAX_MEMORY_MB = 16;

function isJpeg(bytes) {
  return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
}

/**
 * 从 JPEG 的 Exif APP1 段读 IFD0 的 Orientation（0x0112）。没有 / 读不出返回 0（= 不旋转，
 * 与 Dart image 包 `hasOrientation ? orientation : 0` 一致）。多个 Exif 段取最后一个。
 */
export function jpegExifOrientation(bytes) {
  let orientation = 0;
  let p = 2; // 跳过 SOI
  while (p + 4 <= bytes.length) {
    if (bytes[p] !== 0xff) break;
    const marker = bytes[p + 1];
    if (marker === 0xff) { p++; continue; } // 填充字节
    if (marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) { p += 2; continue; }
    if (marker === 0xda || marker === 0xd9) break; // SOS / EOI：之后是熵编码数据
    const len = (bytes[p + 2] << 8) | bytes[p + 3];
    if (len < 2 || p + 2 + len > bytes.length) break;
    if (marker === 0xe1) {
      const o = readTiffOrientation(bytes, p + 4, p + 2 + len);
      if (o !== null) orientation = o;
    }
    p += 2 + len;
  }
  return orientation;
}

/** APP1 段体 [start, end)：'Exif\0\0' + TIFF。不是 Exif 段返回 null；是但没有方向标签返回 0。 */
function readTiffOrientation(b, start, end) {
  if (end - start < 14) return null;
  if (b[start] !== 0x45 || b[start + 1] !== 0x78 || b[start + 2] !== 0x69 || b[start + 3] !== 0x66
    || b[start + 4] !== 0 || b[start + 5] !== 0) return null;
  const t = start + 6;
  let le;
  if (b[t] === 0x49 && b[t + 1] === 0x49) le = true;
  else if (b[t] === 0x4d && b[t + 1] === 0x4d) le = false;
  else return 0;
  const u16 = (o) => (le ? b[o] | (b[o + 1] << 8) : (b[o] << 8) | b[o + 1]);
  const u32 = (o) => (le
    ? (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0
    : ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0);
  const ifd = t + u32(t + 4);
  if (ifd + 2 > end) return 0;
  const n = u16(ifd);
  for (let i = 0; i < n; i++) {
    const e = ifd + 2 + i * 12;
    if (e + 12 > end) break;
    if (u16(e) === 0x0112) return u16(e + 8);
  }
  return 0;
}

/**
 * RGBA 像素（jpeg-js 输出）按 orientation 摆正后的 dHash。与 Dart `getImageFromJpeg` 的
 * setPixel 映射一一对应：源 (x, y) 写到目标坐标，目标图按行优先遍历累加。
 * @param {{width: number, height: number, data: Uint8Array}} image
 */
export function dHashOfRgba(image, orientation = 0) {
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

/** JPEG 字节的 dHash；不是 JPEG、解不开、超过像素 / 内存上限返回 null。 */
export function coverDHashOfJpeg(bytes) {
  if (!isJpeg(bytes)) return null;
  let image;
  try {
    image = decodeJpeg(bytes, {
      useTArray: true, // Workers 没有 Buffer
      formatAsRGBA: true,
      maxResolutionInMP: COVER_DECODE_MAX_MP,
      maxMemoryUsageInMB: COVER_DECODE_MAX_MEMORY_MB,
    });
  } catch {
    return null;
  }
  if (!image || image.width < 1 || image.height < 1) return null;
  return dHashOfRgba(image, jpegExifOrientation(bytes));
}

/**
 * 上传封面的服务端哈希：不是 JPEG → 415 cover_not_jpeg；解不开 → 400 bad_cover_image；
 * 客户端声称了哈希（rawHash 非 null）但格式不对 → 400 bad_cover_hash，与服务端结果距离超过
 * COVER_HASH_MAX_DISTANCE → 400 cover_hash_mismatch。返回服务端算的哈希（存库、归并都用它）。
 */
export function verifiedCoverHash(bytes, rawHash) {
  const claimed = rawHash === null || rawHash === undefined ? null : normalizeCoverHash(rawHash);
  if (rawHash !== null && rawHash !== undefined && !claimed) throw new HttpError(400, 'bad_cover_hash');
  if (!isJpeg(bytes)) throw new HttpError(415, 'cover_not_jpeg');
  const hash = coverDHashOfJpeg(bytes);
  if (!hash) throw new HttpError(400, 'bad_cover_image');
  if (claimed && hammingHex(claimed, hash) > COVER_HASH_MAX_DISTANCE) {
    throw new HttpError(400, 'cover_hash_mismatch');
  }
  return hash;
}
