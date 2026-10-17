// 封面缩略图的感知哈希（dHash，64 位），服务端自己算。
//
// 为什么服务端必须自己算：候选按哈希归并（cover_votes.js），后到者哈希命中就只投票、不再存图。
// 如果信任客户端上报的哈希，任何人都能上传一张任意图片并声称它是正版封面的哈希，抢先占住
// 那个哈希的候选，之后所有持正版封面的人的票都会投到他的图上。所以：候选的 phash 一律是本文件
// 从上传字节里算出来的；客户端声称的哈希只用来核对（差太多 → 400 cover_hash_mismatch）。
//
// 算法与 App / 无头服务端的 packages/fushi_engine/lib/leaderboard/cover_hash.dart 一致：
//   1. 解码 JPEG，按 EXIF Orientation 摆正（Dart 的 image 包解码时就会烘焙方向）；
//   2. 灰度 = ITU-R BT.601 亮度：0.299·R/255 + 0.587·G/255 + 0.114·B/255；
//   3. 按面积平均缩成 9×8：像素 (x, y) 落进格子 (⌊x·9/w⌋, ⌊y·8/h⌋)，格内求平均；
//      源图比 9×8 还小时有空格子：取同一行左侧最近的非空格子（第一格空就取 0）；
//   4. 每行相邻两格比较，左格比右格亮记 1，共 64 位，行优先、高位在前；
//   5. 输出 16 位小写 hex。
//
// 为什么不做完整解码：线上 Worker 是 Cloudflare 免费档，每请求 10 ms CPU。完整解码（jpeg-js：
// Huffman + 反量化 + IDCT + 上采样 + YCbCr→RGB）一张 ≈300px 缩略图热态 2.5–4 ms，冷 isolate 首次
// 调用约 14 ms，封面上传会报 1102。dHash 只要 9×8 格里亮度的「和」，而它是 DCT 系数的线性函数：
//   - JPEG 的 Y 分量就是 BT.601 亮度（第 2 步的灰度 × 255），只解亮度分量；
//   - 一个 8×8 块的像素和 = 64·128 + 8·F(0,0)：整块落在一个格子里时只用 DC（绝大多数块）；
//   - 块被格子边界 / 图像边缘切开时，每一片的像素和 = 128·n + Σ_v Σ_u F(v,u)·Ay(v)·Ax(u)，
//     Ax / Ay 是 IDCT 基函数在这片的列 / 行上的和（只沿一条轴切开时只用一行 / 一列系数）。
// 所以只做 Huffman 熵解码：色度与不被切开的亮度块的 AC 系数解码后丢弃（多数一次查表跳过），
// 不做 IDCT、不做色彩转换。与逐像素解码的差别只剩解码器对每个像素的取整与 [0,255] 截断：实测与
// Dart 对拍样本距离 0，不同时只在参照里两格差 < 1 个灰度级的近似平局位上（阈值是 10）。
//
// 支持：baseline / extended Huffman（SOF0 / SOF1）、progressive Huffman（SOF2：只解 DC 扫描，
// AC 扫描整段跳过，被切开的块只能按 DC 近似）、8 位精度、灰度单分量或 YCbCr 三分量、亮度全分辨率
// 的采样因子（4:4:4 / 4:2:2 / 4:2:0 / 4:1:1…，交织与非交织扫描）、DRI + RSTn、EXIF Orientation。
// 拒绝（400 bad_cover_image）：算术编码、lossless / 层次式、12 位、CMYK / Adobe RGB、亮度被下采样、
// DNL、任何越界 / 截断 / 非法 Huffman 表 / 非法码字。App 与无头服务端上传的缩略图是 Dart image 的
// encodeJpg（baseline 4:4:4）；但 App 在本地封面本就是 ≤300px 的 JPEG 时原样上传（不重编码），
// 那类第三方 JPEG 可能是 progressive / 4:2:0，所以这些也支持。
//
// CPU 上界：所有循环都受输入字节数约束——每次 Huffman 解码至少消耗 1 个真实比特（读到标记 /
// 数据末尾后的比特只许预读、一旦被消耗就判截断），每块最多 64 个系数，段解析与标记扫描单调前进。
//
// 只收 JPEG：不是 JPEG 魔数 → 415 cover_not_jpeg（App 与无头服务端只传 JPEG）。

import { HttpError } from './util.js';
import { COVER_HASH_MAX_DISTANCE, hammingHex, normalizeCoverHash } from './cover_votes.js';

const COLS = 9;
const ROWS = 8;

/**
 * 尺寸上限（SOF 声称的宽高，读到帧头就判、任何分配之前）。依据是全部两条生产上传路径都把封面缩到
 * 长边 ≤ 300：App 的 leaderboardCoverThumb → downsampleCardScreenshotAsync(maxLongEdge: 300)（≤ 300
 * 原样透传、否则缩到 300），无头服务端的 encodeLeaderboardCoverThumb（长边 ≤ 300）。留 20px 余量。
 * 不设这条时，96KB 的 500×500 高频图冷调用 p90 会超过 Workers Free 的 10 ms。
 */
export const COVER_MAX_EDGE = 320;
/** 像素数上限：320×320 ≈ 0.1 MP。 */
export const COVER_DECODE_MAX_MP = 0.1024;

/** 一个文件里 DQT + DHT 表定义的总数上限（正常 2–6 张）。 */
const MAX_TABLES = 32;
/** 扫描数上限（baseline 1–3 个，libjpeg 默认 progressive 脚本 10 个）。 */
const MAX_SCANS = 64;
/** 被格子边界 / 图像边缘切开、需要存 AC 的亮度块数上限（= 320×320 的全部亮度块数，尺寸上限内不会超）。 */
const MAX_CUT_BLOCKS = (COVER_MAX_EDGE / 8) * (COVER_MAX_EDGE / 8);

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
    // 值按类型读：SHORT（3，规范写法）取低 16 位，LONG（4，少数写入器）取 32 位（Dart image 两种都认）。
    if (u16(e) === 0x0112) return u16(e + 2) === 4 ? u32(e + 8) : u16(e + 8);
  }
  return 0;
}

/** 解析失败的统一出口（越界 / 截断 / 非法表 / 不支持的编码）。 */
const BAD = new Error('bad_jpeg');
function bad() {
  throw BAD;
}

// ---------------------------------------------------------------------------------------------
// Huffman 表

/** 快查表位宽：≤ LOOK 位的码字一次查表，更长的逐位走规范码 maxcode。 */
const LOOK = 9;
const LOOK_MASK = (1 << LOOK) - 1;
/** 跳过表里 EOB 的「前进格数」。 */
const SKIP_EOB = 127;

/**
 * DHT 的 16 个码长计数 + 符号表 → 解码表。规范 Huffman 码溢出（某码长分配的码字数超过该长度能
 * 表示的数）即非法。
 *   look[p]：(码长 << 8) | 符号；0 = 不在快查表。
 *   skip[p]（只对 AC 表有意义）：码字 + 其后的幅值比特一共 ≤ LOOK 位时一次查表跳过整个系数：
 *     (总比特数 << 8) | 前进格数（游程 + 1；ZRL = 16；EOB = SKIP_EOB）；0 = 走慢路径。
 */
function buildHuffman(b, countsAt, symAt, total) {
  const look = new Uint16Array(1 << LOOK);
  const skip = new Uint16Array(1 << LOOK);
  const maxcode = new Int32Array(17).fill(-1);
  const valptr = new Int32Array(17);
  const syms = b.slice(symAt, symAt + total);
  let code = 0;
  let k = 0;
  for (let len = 1; len <= 16; len++) {
    const n = b[countsAt + len - 1];
    valptr[len] = k - code;
    if (n > 0) {
      if (code + n > (1 << len)) bad();
      for (let i = 0; i < n; i++) {
        if (len <= LOOK) {
          const from = code << (LOOK - len);
          const to = from + (1 << (LOOK - len));
          const sym = syms[k];
          const sz = sym & 15;
          const r = sym >> 4;
          look.fill((len << 8) | sym, from, to);
          if (sz === 0) skip.fill((len << 8) | (r === 15 ? 16 : SKIP_EOB), from, to);
          else if (len + sz <= LOOK) skip.fill(((len + sz) << 8) | (r + 1), from, to);
        }
        code++;
        k++;
      }
      maxcode[len] = code - 1;
    }
    code <<= 1;
  }
  return { look, skip, maxcode, valptr, syms };
}

/**
 * 长于 LOOK 位的码字：buf 低 cnt 位是待读比特（cnt ≥ 16）。返回 (码长 << 8) | 符号，非法码字 bad()。
 * 不改读取器状态，由调用方核对截断并消耗码长。
 */
function slowHuff(t, buf, cnt) {
  let code = (buf >>> (cnt - LOOK)) & LOOK_MASK;
  for (let l = LOOK + 1; l <= 16; l++) {
    code = (code << 1) | ((buf >>> (cnt - l)) & 1);
    if (code <= t.maxcode[l]) return (l << 8) | t.syms[t.valptr[l] + code];
  }
  return bad();
}

// ---------------------------------------------------------------------------------------------
// 熵数据：一段扫描先「去填充」拷成连续字节（FF00 → FF、丢掉标记前的 FF 填充字节、RSTn 处记下
// 偏移；找 0xFF 用原生 indexOf、拷贝用 set，几乎不花解释器时间），解码时每次补 16 位、不再判 0xFF。

/**
 * 从 pos（SOS 段之后）起把本扫描的熵数据去填充写进 data（调用方每次解析只分配一块 len + 8 的缓冲，
 * 各扫描复用）。返回 { data, length, rstAt, rstNum, end }：有效数据之后补 8 个 0 字节供预读；rstAt / rstNum = 每个 RSTn 在 data 里的偏移与序号；end = 结束本扫描的
 * 标记位置。找不到结束标记 = 截断。
 */
function unstuffScan(bytes, pos, data) {
  const len = bytes.length;
  const rstAt = [];
  const rstNum = [];
  let o = 0;
  let i = pos;
  for (;;) {
    const f = bytes.indexOf(0xff, i);
    if (f < 0 || f + 1 >= len) bad();
    data.set(bytes.subarray(i, f), o);
    o += f - i;
    const nx = bytes[f + 1];
    if (nx === 0) {
      data[o++] = 0xff;
      i = f + 2;
    } else if (nx === 0xff) {
      i = f + 1; // 标记前的填充字节
    } else if (nx >= 0xd0 && nx <= 0xd7) {
      rstAt.push(o);
      rstNum.push(nx & 7);
      i = f + 2;
    } else {
      data.fill(0, o, o + 8);
      return { data, length: o, rstAt, rstNum, end: f };
    }
  }
}

/** 跳过整段熵数据（不含亮度的扫描 / progressive AC 扫描），返回下一个非 RST 标记的位置。 */
function skipScan(bytes, pos) {
  const len = bytes.length;
  let i = pos;
  for (;;) {
    const f = bytes.indexOf(0xff, i);
    if (f < 0 || f + 1 >= len) bad();
    const nx = bytes[f + 1];
    if (nx === 0 || nx === 0xff || (nx >= 0xd0 && nx <= 0xd7)) {
      i = f + 1;
      continue;
    }
    return f;
  }
}

// 熵解码读取器状态：模块级 var（不是闭包 / 对象属性，解释器里读写最便宜；var 也没有 let 的
// TDZ 检查）。同一时刻只有一个 decodeScan 在跑（同步、不重入）。
// eslint-disable-next-line no-var
var rData = null;
// eslint-disable-next-line no-var
var rBuf = 0;
// eslint-disable-next-line no-var
var rCnt = 0;
// eslint-disable-next-line no-var
var rPos = 0;

/** 补到 > 16 位（每次 16 位）。读到数组外是 undefined → 0，只会进入被截断判定拒掉的区域。 */
function refill() {
  do {
    rBuf = (rBuf << 16) | (rData[rPos] << 8) | rData[rPos + 1];
    rPos += 2;
    rCnt += 16;
  } while (rCnt <= 16);
}

/** 解一个 Huffman 符号（调用前 rCnt ≥ 16）。 */
function huff(t) {
  let e = t.look[(rBuf >>> (rCnt - LOOK)) & LOOK_MASK];
  if (e === 0) e = slowHuff(t, rBuf, rCnt);
  rCnt -= e >> 8;
  return e & 0xff;
}

/** 读 n（1–16）位并按 JPEG 规则扩展成有符号数。 */
function receiveExtend(n) {
  if (rCnt < n) refill();
  rCnt -= n;
  const bits = (rBuf >>> rCnt) & ((1 << n) - 1);
  return bits < (1 << (n - 1)) ? bits - (1 << n) + 1 : bits;
}

/** 跳过一块的系数：dcT 非 null 时先跳过 DC（色度块），再跳过整块 AC（色度块、没被切开的亮度块）。 */
function skipCoefficients(dcT, acT) {
  if (rCnt < 16) refill();
  if (dcT !== null) {
    let e = dcT.skip[(rBuf >>> (rCnt - LOOK)) & LOOK_MASK];
    if (e !== 0) {
      rCnt -= e >> 8;
    } else {
      const n = huff(dcT);
      if (rCnt < n) refill();
      rCnt -= n;
    }
  }
  const skip = acT.skip;
  let k = 1;
  for (;;) {
    if (rCnt < 16) refill();
    let e = skip[(rBuf >>> (rCnt - LOOK)) & LOOK_MASK];
    if (e !== 0) {
      rCnt -= e >> 8;
      e &= 0xff;
      if (e === SKIP_EOB) return;
      k += e;
    } else {
      e = huff(acT);
      const n = e & 15;
      if (n === 0) {
        if ((e & 0xf0) !== 0xf0) return; // EOB
        k += 16; // ZRL
      } else {
        k += (e >> 4) + 1;
        if (rCnt < n) refill();
        rCnt -= n;
      }
    }
    if (k >= 64) {
      if (k > 64) bad();
      return;
    }
  }
}

/**
 * 解 AC，反量化后按自然顺序存进 ac[base…]（被切开的亮度块用）。qn = 自然序量化表。
 * 返回最后一个非零系数的之字形下标（0 = 没有 AC），哈希时据此只算用得到的行 / 列。
 */
function readCoefficients(acT, ac, base, qn) {
  let last = 0;
  for (let k = 1; k < 64;) {
    if (rCnt < 16) refill();
    const e = huff(acT);
    const n = e & 15;
    if (n === 0) {
      if ((e & 0xf0) !== 0xf0) break; // EOB
      k += 16; // ZRL
      if (k > 64) bad();
      continue;
    }
    k += e >> 4;
    if (k > 63) bad();
    const z = ZIGZAG[k];
    ac[base + z] = receiveExtend(n) * qn[z];
    last = k;
    k++;
  }
  return last;
}

/**
 * 解一个扫描的全部 MCU。
 *
 * 截断判定：已消耗到的比特位置 = rPos·8 − rCnt，只增不减；它一旦越过 lim·8（本重启区间 / 本扫描的
 * 数据末尾）就是截断。所以不必每次消耗都查，每块解完查一次等价（越界后多读的只是同一块里的
 * 有界垃圾：每块最多 64 个系数，读到数组外是 undefined → 0）。
 *
 * scan = { units, unitsX, interleaved, comps: [{ c, dcT, acT, isY }] }；f = 帧与输出（见 parseJpeg）。
 * mode：0 = baseline（DC + AC），1 = progressive DC 首扫（左移 al），2 = progressive DC 细化。
 */
function decodeScan(sd, scan, f, restartInterval, mode, al) {
  const { dcs, ac, slot, stride, last, qn } = f;
  const comps = scan.comps;
  const nc = comps.length;
  const unitsX = scan.unitsX;
  const total = scan.units;
  const interleaved = scan.interleaved;
  if (restartInterval === 0 && sd.rstAt.length > 0) bad(); // 没有 DRI 却有 RSTn
  rData = sd.data;
  rBuf = 0;
  rCnt = 0;
  rPos = 0;
  let lim = sd.rstAt.length > 0 ? sd.rstAt[0] : sd.length;
  let rst = 0;
  let left = restartInterval;
  try {
    for (let u = 0; u < total; u++) {
      if (restartInterval > 0) {
        if (left === 0) {
          if (rst >= sd.rstAt.length || sd.rstNum[rst] !== (rst & 7)) bad();
          rPos = sd.rstAt[rst];
          rst++;
          lim = rst < sd.rstAt.length ? sd.rstAt[rst] : sd.length;
          rBuf = 0;
          rCnt = 0;
          left = restartInterval;
          for (let i = 0; i < nc; i++) comps[i].c.pred = 0;
        }
        left--;
      }
      const ux = u % unitsX;
      const uy = (u - ux) / unitsX;
      for (let ci = 0; ci < nc; ci++) {
        const sc = comps[ci];
        const c = sc.c;
        const hh = interleaved ? c.h : 1;
        const vv = interleaved ? c.v : 1;
        for (let v = 0; v < vv; v++) {
          for (let h = 0; h < hh; h++) {
            if (!sc.isY) {
              if (mode === 0) {
                skipCoefficients(sc.dcT, sc.acT);
              } else {
                if (rCnt < 16) refill();
                if (mode === 2) rCnt--;
                else { const n = huff(sc.dcT); if (n !== 0) receiveExtend(n); }
              }
            } else {
              const bi = (uy * vv + v) * stride + ux * hh + h;
              if (rCnt < 16) refill();
              if (mode === 2) {
                rCnt--;
                if (((rBuf >>> rCnt) & 1) === 1) dcs[bi] |= 1 << al;
              } else {
                const n = huff(sc.dcT);
                if (n !== 0) c.pred += receiveExtend(n);
                if (mode === 1) {
                  dcs[bi] = c.pred * (1 << al);
                } else {
                  dcs[bi] = c.pred;
                  const sb = slot[bi];
                  if (sb < 0) skipCoefficients(null, sc.acT);
                  else last[sb] = readCoefficients(sc.acT, ac, sb * 64, qn);
                }
              }
            }
            // 截断：已消耗位置越过 lim
            if (rPos > lim && rCnt < (rPos - lim) << 3) bad();
          }
        }
      }
    }
  } finally {
    rData = null;
  }
}

// ---------------------------------------------------------------------------------------------
// 解析

/**
 * 解析 JPEG（只做熵解码），返回亮度分量的块系数与几何：
 * { width, height, bw, bh, stride, dcs, ac, slot, q, xs, ys }。块 (bx, by) 覆盖像素
 * [8bx, 8bx+8) × [8by, 8by+8)（与图像边界取交集）；dcs[by·stride + bx] = 它的 DC（未反量化）；
 * 被格子边界 / 图像边缘切开的块另有 AC 槽 slot[…] ≥ 0，系数在 ac[槽·64 + 自然序下标]（槽里第 0 个
 * 也填上 DC）。q = 自然序的亮度量化表。任何不合法 / 不支持的输入抛 BAD。
 */
function parseJpeg(bytes, orientation) {
  const len = bytes.length;
  const qts = [null, null, null, null]; // 量化表（之字形顺序）
  const dcTables = [null, null, null, null];
  const acTables = [null, null, null, null];
  let frame = null;
  let progressive = false;
  let restartInterval = 0;
  let adobeTransform = -1;
  let qY = null; // 亮度量化表（首个含亮度的扫描开始时锁定）
  let yDecoded = false;
  let sawSos = false;
  // 构造输入的「风暴」上限：正常 JPEG 只有几张表、baseline 1–3 个扫描、progressive 约 10 个扫描。
  // 不设上限时 96KB 能塞几千个 11 字节的扫描 / 几千张表，每个都要走一遍全帧或建表（实测 64–230 ms）。
  let scratch = null; // 熵数据去填充缓冲（各扫描复用）
  let scans = 0;
  let tables = 0;

  function readFrame(s, e, marker) {
    if (frame) bad(); // 只允许一个帧头
    if (e - s < 6) bad();
    const precision = bytes[s];
    const height = (bytes[s + 1] << 8) | bytes[s + 2];
    const width = (bytes[s + 3] << 8) | bytes[s + 4];
    const nf = bytes[s + 5];
    if (precision !== 8) bad();
    if (width < 1 || height < 1) bad(); // 高 0 = DNL 定义高度，不支持
    if (width > COVER_MAX_EDGE || height > COVER_MAX_EDGE) bad();
    if (width * height > COVER_DECODE_MAX_MP * 1e6) bad();
    if (nf !== 1 && nf !== 3) bad(); // 灰度或 YCbCr；CMYK / 其它拒绝
    if (e - s !== 6 + 3 * nf) bad();
    const comps = [];
    let hmax = 1;
    let vmax = 1;
    for (let i = 0; i < nf; i++) {
      const o = s + 6 + 3 * i;
      const id = bytes[o];
      const h = bytes[o + 1] >> 4;
      const v = bytes[o + 1] & 15;
      const tq = bytes[o + 2];
      if (h < 1 || h > 4 || v < 1 || v > 4 || tq > 3) bad();
      for (const c of comps) if (c.id === id) bad();
      comps.push({ id, h, v, tq, pred: 0 });
      if (h > hmax) hmax = h;
      if (v > vmax) vmax = v;
    }
    // 亮度分量必须是全分辨率（采样因子最大）：4:4:4 / 4:2:2 / 4:2:0 / 4:1:1 都是；亮度被下采样的
    // 怪异 JPEG 实际不存在，拒绝而不是留一条测不到的代码路径。
    const y = comps[0];
    if (y.h !== hmax || y.v !== vmax) bad();
    const mcusX = Math.ceil(width / (8 * hmax));
    const mcusY = Math.ceil(height / (8 * vmax));
    const stride = mcusX * y.h;
    const bw = Math.ceil(width / 8);
    const bh = Math.ceil(height / 8);
    const nBlocks = stride * mcusY * y.v;
    const flip = orientation >= 5;
    // 被切开的块要存 64 个系数、哈希时逐片算：细长图（如 1×250000）每块都被切开，限住数量。
    // 尺寸上限内不会超（≈300px 缩略图约 400 个）；这条是尺寸上限之外的第二道保险。在建切片表（每片要算基函数和）
    // 之前用整块计数先判，构造的细长图不必走完整条轴。
    const wx = wholeBlockCount(bw, width, REVERSE_X[orientation], flip ? ROWS : COLS);
    const wy = wholeBlockCount(bh, height, REVERSE_Y[orientation], flip ? COLS : ROWS);
    if (bw * bh - wx * wy > MAX_CUT_BLOCKS) bad();
    const xs = axisSpans(bw, width, REVERSE_X[orientation], flip ? ROWS : COLS);
    const ys = axisSpans(bh, height, REVERSE_Y[orientation], flip ? COLS : ROWS);
    // 被切开的块分配 AC 槽（MCU 对齐多出来的填充块不参与哈希，不分配）。
    const slot = new Int32Array(nBlocks).fill(-1);
    let slots = 0;
    for (let by = 0; by < bh; by++) {
      const yCut = !spanIsWhole(ys, by);
      for (let bx = 0; bx < bw; bx++) {
        if (yCut || !spanIsWhole(xs, bx)) slot[by * stride + bx] = slots++;
      }
    }
    if (slots !== bw * bh - wx * wy) throw new Error('cut-block count mismatch'); // 两套判据必须一致
    frame = {
      width, height, comps, hmax, vmax, mcusX, mcusY, stride, bw, bh, xs, ys, slot,
      dcs: new Int16Array(nBlocks),
      ac: new Float64Array(slots * 64), // 已反量化的 DCT 系数 F(v,u)，自然顺序
      last: new Uint8Array(slots), // 每槽最后一个非零 AC 的之字形下标
      qn: null, // 亮度量化表（自然顺序），首个含亮度的扫描开始时锁定
    };
    progressive = marker === 0xc2;
  }

  function readQuant(s, e) {
    let q = s;
    while (q < e) {
      const pq = bytes[q] >> 4;
      const tq = bytes[q] & 15;
      if (pq > 1 || tq > 3) bad();
      const size = pq ? 128 : 64;
      if (q + 1 + size > e) bad();
      const t = new Uint16Array(64);
      for (let i = 0; i < 64; i++) t[i] = pq ? (bytes[q + 1 + 2 * i] << 8) | bytes[q + 2 + 2 * i] : bytes[q + 1 + i];
      if (++tables > MAX_TABLES) bad();
      qts[tq] = t;
      q += 1 + size;
    }
  }

  function readHuffman(s, e) {
    let q = s;
    while (q < e) {
      const tc = bytes[q] >> 4;
      const th = bytes[q] & 15;
      if (tc > 1 || th > 3) bad();
      if (q + 17 > e) bad();
      let total = 0;
      for (let i = 1; i <= 16; i++) total += bytes[q + i];
      if (total > 256 || q + 17 + total > e) bad();
      if (tc === 0) {
        for (let i = 0; i < total; i++) if (bytes[q + 17 + i] > 11) bad(); // 8 位精度 DC 差分 ≤ 11 位
      } else {
        for (let i = 0; i < total; i++) if ((bytes[q + 17 + i] & 15) > 10) bad(); // AC 幅值 ≤ 10 位
      }
      if (++tables > MAX_TABLES) bad();
      const t = buildHuffman(bytes, q + 1, q + 17, total);
      if (tc === 0) dcTables[th] = t;
      else acTables[th] = t;
      q += 17 + total;
    }
  }

  /** 解析 SOS 段 [s, e) 并解 / 跳过其后的熵数据，返回下一个标记的位置。 */
  function readScan(s, e) {
    if (!frame) bad();
    if (++scans > MAX_SCANS) bad();
    const ns = bytes[s];
    if (ns < 1 || ns > frame.comps.length || e - s !== 4 + 2 * ns) bad();
    const y = frame.comps[0];
    const comps = [];
    for (let i = 0; i < ns; i++) {
      const id = bytes[s + 1 + 2 * i];
      const c = frame.comps.find((x) => x.id === id);
      if (!c || comps.some((x) => x.c === c)) bad();
      const td = bytes[s + 2 + 2 * i] >> 4;
      const ta = bytes[s + 2 + 2 * i] & 15;
      if (td > 3 || ta > 3) bad();
      comps.push({ c, dcT: dcTables[td], acT: acTables[ta], isY: c === y });
    }
    const o = s + 1 + 2 * ns;
    const ss = bytes[o];
    const se = bytes[o + 1];
    const ah = bytes[o + 2] >> 4;
    const al = bytes[o + 2] & 15;
    const hasY = comps.some((x) => x.isY);
    if (progressive) {
      if (ss > se || se > 63 || ah > 13 || al > 13 || (ss === 0 && se !== 0) || (ss > 0 && ns !== 1)) bad();
      if (ss > 0 || !hasY) return skipScan(bytes, e); // AC 扫描 / 不含亮度的 DC 扫描：整段跳过
    } else {
      if (ss !== 0 || se !== 63 || ah !== 0 || al !== 0) bad();
      if (!hasY) return skipScan(bytes, e);
    }
    const mode = !progressive ? 0 : ah === 0 ? 1 : 2;
    for (const x of comps) {
      if (mode !== 2 && !x.dcT) bad();
      if (mode === 0 && !x.acT) bad();
      x.c.pred = 0;
    }
    if (qY === null) {
      qY = qts[y.tq];
      if (qY === null) bad();
      frame.qn = new Float64Array(64);
      for (let i = 0; i < 64; i++) frame.qn[ZIGZAG[i]] = qY[i];
    }
    // 非交织（单分量）扫描按分量自己的块网格走，交织扫描按 MCU 走。
    let unitsX;
    let unitsY;
    if (ns === 1) {
      const c = comps[0].c;
      unitsX = Math.ceil(Math.ceil((frame.width * c.h) / frame.hmax) / 8);
      unitsY = Math.ceil(Math.ceil((frame.height * c.v) / frame.vmax) / 8);
    } else {
      unitsX = frame.mcusX;
      unitsY = frame.mcusY;
      let perMcu = 0;
      for (const x of comps) perMcu += x.c.h * x.c.v;
      if (perMcu > 10) bad();
    }
    if (scratch === null) scratch = new Uint8Array(len + 8);
    const sd = unstuffScan(bytes, e, scratch);
    decodeScan(sd, { units: unitsX * unitsY, unitsX, interleaved: ns > 1, comps }, frame, restartInterval, mode, al);
    if (mode !== 2) yDecoded = true;
    return sd.end;
  }

  // ---- 段解析 ----
  if (!isJpeg(bytes)) bad();
  let p = 2;
  for (;;) {
    if (p + 2 > len) bad(); // 没有 EOI = 截断
    if (bytes[p] !== 0xff) bad();
    const marker = bytes[p + 1];
    if (marker === 0xff) { p++; continue; }
    p += 2;
    if (marker === 0xd9) break; // EOI
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) bad();
    if (p + 2 > len) bad();
    const segLen = (bytes[p] << 8) | bytes[p + 1];
    if (segLen < 2 || p + segLen > len) bad();
    const s = p + 2;
    const e = p + segLen;
    p = e;
    if (marker === 0xc0 || marker === 0xc1 || marker === 0xc2) {
      readFrame(s, e, marker);
    } else if (marker === 0xc4) {
      readHuffman(s, e);
    } else if (marker === 0xdb) {
      readQuant(s, e);
    } else if (marker === 0xdd) {
      if (e - s !== 2) bad();
      restartInterval = (bytes[s] << 8) | bytes[s + 1];
    } else if (marker === 0xda) {
      if (!sawSos && frame && frame.comps.length === 3) {
        // Adobe transform=0 或分量 ID 为 'R','G','B' 的三分量 JPEG 是 RGB，第 1 分量不是亮度。
        const ids = frame.comps.map((c) => c.id);
        if (adobeTransform === 0 || (ids[0] === 0x52 && ids[1] === 0x47 && ids[2] === 0x42)) bad();
      }
      sawSos = true;
      p = readScan(s, e);
    } else if (marker === 0xee) {
      if (e - s >= 12 && bytes[s] === 0x41 && bytes[s + 1] === 0x64 && bytes[s + 2] === 0x6f
        && bytes[s + 3] === 0x62 && bytes[s + 4] === 0x65) {
        adobeTransform = bytes[s + 11];
      }
    } else if ((marker >= 0xe0 && marker <= 0xef) || marker === 0xfe || (marker >= 0xf0 && marker <= 0xfd)) {
      // APPn / COM / JPGn：跳过（Exif Orientation 由 jpegExifOrientation 单独读）
    } else {
      // SOF3/5–7/9–11/13–15（lossless、层次式、算术编码）、DAC、DNL、DHP、EXP 及保留标记：不支持
      bad();
    }
  }
  if (!frame || !yDecoded) bad();

  // 被切开块的 AC 槽里补上反量化的 DC（哈希按槽里的 F(v,u) 算切片和）。
  const { dcs, ac, slot, stride, bw, bh } = frame;
  for (let by = 0; by < bh; by++) {
    for (let bx = 0; bx < bw; bx++) {
      const sb = slot[by * stride + bx];
      if (sb >= 0) ac[sb * 64] = dcs[by * stride + bx] * frame.qn[0];
    }
  }
  return {
    width: frame.width, height: frame.height, bw, bh, stride, dcs, ac, slot,
    last: frame.last, q0: frame.qn[0], xs: frame.xs, ys: frame.ys,
  };
}

const ZIGZAG = new Uint8Array([
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21,
  28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54,
  47, 55, 62, 63,
]);
/** 之字形前 k+1 个系数涉及的行数 / 列数（= 最大行 / 列下标 + 1）。 */
const ZZ_ROWS = new Uint8Array(64);
const ZZ_COLS = new Uint8Array(64);
for (let k = 0, r = 0, c = 0; k < 64; k++) {
  r = Math.max(r, ZIGZAG[k] >> 3);
  c = Math.max(c, ZIGZAG[k] & 7);
  ZZ_ROWS[k] = r + 1;
  ZZ_COLS[k] = c + 1;
}

// ---------------------------------------------------------------------------------------------
// 几何：块 → 9×8 格

/** IDCT 基：COS[x * 8 + u] = C(u)/2 · cos((2x+1)uπ/16)，C(0) = 1/√2。像素 f(x,y) = 128 + Σ COS[y][v]·COS[x][u]·F(v,u)。 */
const COS = (() => {
  const t = new Float64Array(64);
  for (let x = 0; x < 8; x++) {
    for (let u = 0; u < 8; u++) t[x * 8 + u] = (u === 0 ? Math.SQRT1_2 : 1) * 0.5 * Math.cos(((2 * x + 1) * u * Math.PI) / 16);
  }
  return t;
})();
/** 整块 8 个像素的基函数和：只有 u = 0 非零（= 2√2），其余精确为 0。 */
const FULL_SUM0 = 8 * COS[0];

// EXIF Orientation → 源 x / 源 y 轴在摆正后的图里是否反向（与 Dart image 烘焙方向的 setPixel 映射
// 一致：2 dx=w1-x；3 dx=w1-x, dy=h1-y；4 dy=h1-y；5 dx=y, dy=x；6 dx=h1-y, dy=x；7 dx=h1-y,
// dy=w1-x；8 dx=y, dy=w1-x）。5–8 交换宽高。其它值（0、1、非法值）不变换。
const REVERSE_X = [false, false, true, true, false, false, false, true, true];
const REVERSE_Y = [false, false, false, true, true, false, true, true, false];

/** 格 c 的第一个像素：⌈c·total/nCells⌉。 */
function cellLow(c, total, nCells) {
  return Math.floor((c * total + nCells - 1) / nCells);
}

/**
 * 一条源轴上每个 8 像素块覆盖的真实像素（不含块对齐填充），映射到目标轴（可能反向）后切给各格子：
 * 返回 { start, cell, full, basis }，块 b 的切片在 [start[b], start[b+1])。切片 i 落在格 cell[i]；
 * full[i] = 1 表示整块 8 个像素都在这一格；basis[8i + u] = Σ_{块内切片像素 x} COS[x][u]。
 * 像素 p 落进格 ⌊p·nCells/total⌋（与 Dart 的 `x * 9 ~/ w` 一致），格 c 覆盖像素
 * [⌈c·total/nCells⌉, ⌈(c+1)·total/nCells⌉)。
 */
function axisSpans(nBlocks, total, reversed, nCells) {
  const start = new Int32Array(nBlocks + 1);
  const cell = [];
  const full = [];
  const basis = [];
  for (let b = 0; b < nBlocks; b++) {
    start[b] = cell.length;
    const s0 = b * 8;
    const s1 = Math.min(s0 + 8, total);
    // 目标轴上的区间
    const a = reversed ? total - s1 : s0;
    const e = reversed ? total - s0 : s1;
    const c0 = Math.floor((a * nCells) / total);
    const c1 = Math.floor(((e - 1) * nCells) / total);
    for (let c = c0; c <= c1; c++) {
      const lo = Math.max(a, cellLow(c, total, nCells));
      const hi = Math.min(e, cellLow(c + 1, total, nCells));
      if (hi <= lo) continue;
      // 切回源轴、块内偏移
      const from = (reversed ? total - hi : lo) - s0;
      const to = (reversed ? total - lo : hi) - s0;
      cell.push(c);
      full.push(hi - lo === 8 ? 1 : 0);
      for (let u = 0; u < 8; u++) {
        let acc = 0;
        for (let x = from; x < to; x++) acc += COS[x * 8 + u];
        basis.push(acc);
      }
    }
  }
  start[nBlocks] = cell.length;
  return { start, cell, full, basis };
}

/** 一条轴上没被切开的块数（与 axisSpans + spanIsWhole 的判据一致，但不建切片表）。 */
function wholeBlockCount(nBlocks, total, reversed, nCells) {
  let n = 0;
  for (let b = 0; b < nBlocks; b++) {
    const s0 = b * 8;
    if (s0 + 8 > total) continue; // 末块不满 8 像素
    const a = reversed ? total - s0 - 8 : s0; // 目标轴上的区间 [a, a+8)
    if (Math.floor((a * nCells) / total) === Math.floor(((a + 7) * nCells) / total)) n++;
  }
  return n;
}

/** 块 b 在这条轴上整块落在一个格子里（没被格子边界或图像边缘切开）。 */
function spanIsWhole(spans, b) {
  const i = spans.start[b];
  return spans.start[b + 1] - i === 1 && spans.full[i] === 1;
}

/** 9×8 格的和 / 像素数 → 16 位 hex dHash（空格子规则与 Dart 一致）。 */
function dHashOfCells(sum, count) {
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

/**
 * 亮度块系数 + EXIF 方向 → dHash。整块落在一个格子里的块只累加 DC；被切开的块按切片算像素和
 * （Σ 像素 − 128·n = Σ_v Ay(v)·Σ_u F(v,u)·Ax(u)，整块方向只剩第 0 项）。块对齐填充像素不计。
 */
function dHashOfBlocks(img, orientation) {
  const flip = orientation >= 5;
  const { dcs, ac, slot, last, stride, xs, ys, bw, bh } = img;
  // 格子 (cx, cy) 的像素数 = 目标 x 轴上落进 cx 的像素数 × 目标 y 轴上落进 cy 的像素数。
  const dw = flip ? img.height : img.width;
  const dh = flip ? img.width : img.height;
  const count = new Float64Array(COLS * ROWS);
  for (let cy = 0; cy < ROWS; cy++) {
    const ny = cellLow(cy + 1, dh, ROWS) - cellLow(cy, dh, ROWS);
    for (let cx = 0; cx < COLS; cx++) count[cy * COLS + cx] = ny * (cellLow(cx + 1, dw, COLS) - cellLow(cx, dw, COLS));
  }
  const dcSum = new Float64Array(COLS * ROWS); // 整块：未反量化 DC 之和
  const sum = new Float64Array(COLS * ROWS); // 切片：不含 +128 的像素和
  const row = new Float64Array(8);
  // 一条轴上整块一片的块给出格子偏移（目标格下标 = 行偏移 + 列偏移），否则 -1。
  const xOff = new Int32Array(bw);
  for (let bx = 0; bx < bw; bx++) {
    const c = xs.cell[xs.start[bx]];
    xOff[bx] = spanIsWhole(xs, bx) ? (flip ? c * COLS : c) : -1;
  }
  const xBasis = xs.basis;
  const yBasis = ys.basis;
  for (let by = 0; by < bh; by++) {
    const j0 = ys.start[by];
    const j1 = ys.start[by + 1];
    const yOff = spanIsWhole(ys, by) ? (flip ? ys.cell[j0] : ys.cell[j0] * COLS) : -1;
    const rowBase = by * stride;
    for (let bx = 0; bx < bw; bx++) {
      const xo = xOff[bx];
      if (xo >= 0 && yOff >= 0) {
        dcSum[xo + yOff] += dcs[rowBase + bx];
        continue;
      }
      const sb = slot[rowBase + bx];
      const base = sb * 64;
      // 只算有非零系数的行 / 列；y 方向整块时只用到 r(0)。
      const lk = last[sb];
      const nv = yOff >= 0 ? 1 : ZZ_ROWS[lk];
      const nu = ZZ_COLS[lk];
      for (let i = xs.start[bx]; i < xs.start[bx + 1]; i++) {
        const xc = xs.cell[i];
        // r(v) = Σ_u F(v,u)·Ax(u)
        if (xs.full[i] === 1) {
          for (let v = 0; v < nv; v++) row[v] = ac[base + v * 8] * FULL_SUM0;
        } else {
          const xb = i * 8;
          for (let v = 0; v < nv; v++) {
            const rb = base + v * 8;
            let acc = 0;
            for (let u = 0; u < nu; u++) acc += ac[rb + u] * xBasis[xb + u];
            row[v] = acc;
          }
        }
        for (let j = j0; j < j1; j++) {
          let acc;
          if (ys.full[j] === 1) {
            acc = row[0] * FULL_SUM0;
          } else {
            const yb = j * 8;
            acc = 0;
            for (let v = 0; v < nv; v++) acc += row[v] * yBasis[yb + v];
          }
          sum[flip ? xc * COLS + ys.cell[j] : ys.cell[j] * COLS + xc] += acc;
        }
      }
    }
  }
  // 整块：Σ 像素 − 128·64 = F(0,0)·(2√2)² = 8·Q_dc·DC。
  const q0 = img.q0 * FULL_SUM0 * FULL_SUM0;
  const total = new Float64Array(COLS * ROWS);
  for (let i = 0; i < COLS * ROWS; i++) total[i] = dcSum[i] * q0 + sum[i] + 128 * count[i];
  return dHashOfCells(total, count);
}

/** JPEG 字节的 dHash；不是 JPEG、不支持的编码、任何越界 / 截断 / 非法数据、超过像素上限返回 null。 */
export function coverDHashOfJpeg(bytes) {
  if (!isJpeg(bytes)) return null;
  const o = jpegExifOrientation(bytes);
  const orientation = o >= 1 && o <= 8 ? o : 0;
  let img;
  try {
    img = parseJpeg(bytes, orientation);
  } catch (e) {
    if (e === BAD) return null;
    throw e;
  }
  return dHashOfBlocks(img, orientation);
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
