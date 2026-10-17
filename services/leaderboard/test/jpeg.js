// 测试用真 JPEG 构造器（jpeg-js 编码器）。

import encodeJpeg from 'jpeg-js/lib/encoder.js';

/**
 * 真 JPEG，服务端算出的 dHash 恰为 hash（16 位 hex）。9×8 个 cell 像素见方的色块：每行从中灰起，
 * 该位为 1（左比右亮）就往下走一档、为 0 就往上走一档，面积平均后每对相邻格的大小关系与 hash 的位一致。
 * tint = 每个像素额外的 RGB 偏移（换颜色 / 换内容而不改哈希，用来造「同哈希不同字节」的图）。
 */
export function coverJpeg(hash, { cell = 10, quality = 90, tint = [0, 0, 0] } = {}) {
  const width = 9 * cell;
  const height = 8 * cell;
  const data = new Uint8Array(width * height * 4);
  for (let row = 0; row < 8; row++) {
    const bits = parseInt(hash.slice(row * 2, row * 2 + 2), 16);
    const levels = [128];
    for (let i = 0; i < 8; i++) levels.push(levels[i] + ((bits >> (7 - i)) & 1 ? -14 : 14));
    for (let y = row * cell; y < (row + 1) * cell; y++) {
      for (let x = 0; x < width; x++) {
        const v = levels[Math.floor(x / cell)];
        const o = (y * width + x) * 4;
        data[o] = Math.max(0, Math.min(255, v + tint[0]));
        data[o + 1] = Math.max(0, Math.min(255, v + tint[1]));
        data[o + 2] = Math.max(0, Math.min(255, v + tint[2]));
        data[o + 3] = 255;
      }
    }
  }
  return new Uint8Array(encodeJpeg({ width, height, data }, quality).data);
}

/** 在 JPEG 的 SOI 之后插一个只含 IFD0 Orientation 的 Exif APP1 段（小端 TIFF）。 */
export function withExifOrientation(jpeg, orientation) {
  const tiff = [
    0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00, // "II*" 头 + IFD0 偏移 8
    0x01, 0x00, // 1 个条目
    0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, orientation & 0xff, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, // 下一个 IFD：无
  ];
  const body = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00, ...tiff];
  const seg = [0xff, 0xe1, ((body.length + 2) >> 8) & 0xff, (body.length + 2) & 0xff, ...body];
  const out = new Uint8Array(jpeg.length + seg.length);
  out.set(jpeg.subarray(0, 2));
  out.set(seg, 2);
  out.set(jpeg.subarray(2), 2 + seg.length);
  return out;
}
