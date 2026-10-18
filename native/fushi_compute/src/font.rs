//! `ffc_font_*`：字体容器解码。
//!
//! 目前只有 WOFF2 → sfnt（Flutter 的 `FontLoader` 只吃裸 sfnt）：Brotli 解压 + 逆转
//! glyf / loca / hmtx 变换（WOFF2 规范 §5.1 / §5.2）+ 按标签排序重组表目录、4 字节对齐、
//! 重算 `head.checkSumAdjustment`。
//!
//! 输出与原 Dart 实现（`fushi/lib/src/models/woff2_decoder.dart` + `FontDecoder.buildSfnt`，
//! 已删除）逐字节一致，回归向量见 `packages/fushi_compute/test/font/`。唯一有意的差异：
//! glyf 变换头 `optionFlags` 第 0 位（overlapSimpleBitmap）——Dart 版把它当成多一个 u32
//! 长度字段读，整条流错位、解码失败；这里按规范把位图读在 instructionStream 之后，并给
//! 对应简单字形的首个 flag 置 `OVERLAP_SIMPLE`（0x40）。
//!
//! 不支持字体集合（flavor `ttcf`）：报 [status::BAD_INPUT]（Dart 版同样解不出）。

use std::collections::BTreeMap;
use std::io::Read;

use crate::{guard, hand_over_bytes, status};

const SIGNATURE: u32 = 0x774F_4632; // 'wOF2'
const TTCF: u32 = 0x7474_6366; // 'ttcf'
const GLYF: u32 = 0x676C_7966;
const LOCA: u32 = 0x6C6F_6361;
const HEAD: u32 = 0x6865_6164;
const HHEA: u32 = 0x6868_6561;
const HMTX: u32 = 0x686D_7478;

/// WOFF2 已知表标签（flag 低 6 位 0..62；63 = 显式标签）。
const KNOWN_TAGS: [&[u8; 4]; 63] = [
    b"cmap", b"head", b"hhea", b"hmtx", b"maxp", b"name", b"OS/2", b"post", b"cvt ", b"fpgm",
    b"glyf", b"loca", b"prep", b"CFF ", b"VORG", b"EBDT", b"EBLC", b"gasp", b"hdmx", b"kern",
    b"LTSH", b"PCLT", b"VDMX", b"vhea", b"vmtx", b"BASE", b"GDEF", b"GPOS", b"GSUB", b"EBSC",
    b"JSTF", b"MATH", b"CBDT", b"CBLC", b"COLR", b"CPAL", b"SVG ", b"sbix", b"acnt", b"avar",
    b"bdat", b"bloc", b"bsln", b"cvar", b"fdsc", b"feat", b"fmtx", b"fvar", b"gvar", b"hsty",
    b"just", b"lcar", b"ltag", b"meta", b"mort", b"morx", b"opbd", b"prop", b"trak", b"Zapf",
    b"Silf", b"Glat", b"Gloc",
];

/// 输入无法解析。
#[derive(Debug, PartialEq, Eq)]
pub struct BadInput;

type R<T> = Result<T, BadInput>;

/// 顺序大端读取器（越界一律 [BadInput]）。
struct Reader<'a> {
    d: &'a [u8],
    p: usize,
}

impl<'a> Reader<'a> {
    fn new(d: &'a [u8]) -> Self {
        Reader { d, p: 0 }
    }

    #[inline]
    fn take(&mut self, n: usize) -> R<&'a [u8]> {
        let end = self.p.checked_add(n).ok_or(BadInput)?;
        if end > self.d.len() {
            return Err(BadInput);
        }
        let s = &self.d[self.p..end];
        self.p = end;
        Ok(s)
    }

    #[inline]
    fn u8(&mut self) -> R<u8> {
        let v = *self.d.get(self.p).ok_or(BadInput)?;
        self.p += 1;
        Ok(v)
    }

    #[inline]
    fn u16(&mut self) -> R<u16> {
        let s = self.take(2)?;
        Ok(u16::from_be_bytes([s[0], s[1]]))
    }

    #[inline]
    fn i16(&mut self) -> R<i16> {
        Ok(self.u16()? as i16)
    }

    #[inline]
    fn u32(&mut self) -> R<u32> {
        let s = self.take(4)?;
        Ok(u32::from_be_bytes([s[0], s[1], s[2], s[3]]))
    }

    /// UIntBase128。
    fn base128(&mut self) -> R<u32> {
        let mut result: u32 = 0;
        for i in 0..5 {
            let b = self.u8()?;
            if i == 0 && b == 0x80 {
                return Err(BadInput);
            }
            if result & 0xFE00_0000 != 0 {
                return Err(BadInput);
            }
            result = (result << 7) | (b & 0x7F) as u32;
            if b & 0x80 == 0 {
                return Ok(result);
            }
        }
        Err(BadInput)
    }

    /// 255UInt16。
    #[inline]
    fn read255(&mut self) -> R<u16> {
        let code = self.u8()?;
        Ok(match code {
            253 => self.u16()?,
            255 => self.u8()? as u16 + 253,
            254 => self.u8()? as u16 + 506,
            c => c as u16,
        })
    }
}

struct Entry {
    tag: u32,
    transformed: bool,
    stream_len: usize,
}

/// WOFF2 → sfnt。
pub fn woff2_to_sfnt(bytes: &[u8]) -> R<Vec<u8>> {
    let mut r = Reader::new(bytes);
    if r.u32()? != SIGNATURE {
        return Err(BadInput);
    }
    let flavor = r.u32()?;
    if flavor == TTCF {
        return Err(BadInput);
    }
    r.u32()?; // length
    let num_tables = r.u16()?;
    if num_tables == 0 {
        return Err(BadInput);
    }
    r.u16()?; // reserved
    r.u32()?; // totalSfntSize
    let total_compressed = r.u32()? as usize;
    r.take(2 + 2 + 4 * 5)?; // major, minor, meta*3, priv*2

    let mut entries: Vec<Entry> = Vec::with_capacity(num_tables as usize);
    for _ in 0..num_tables {
        let flags = r.u8()?;
        let tag_index = (flags & 0x3F) as usize;
        let transform = (flags >> 6) & 0x03;
        let tag = if tag_index == 63 {
            r.u32()?
        } else {
            u32::from_be_bytes(*KNOWN_TAGS[tag_index])
        };
        let orig_len = r.base128()?;
        let transformed = match tag {
            GLYF | LOCA => transform == 0,
            HMTX => transform == 1,
            _ => false,
        };
        let stream_len = if transformed { r.base128()? } else { orig_len };
        entries.push(Entry {
            tag,
            transformed,
            stream_len: stream_len as usize,
        });
    }

    let comp = r.take(total_compressed)?;
    let expected: usize = entries.iter().map(|e| e.stream_len).sum();
    let decoded = brotli_decode(comp, expected)?;

    let mut out: BTreeMap<u32, Vec<u8>> = BTreeMap::new();
    let mut glyf: Option<(&[u8], bool)> = None;
    let mut hmtx: Option<&[u8]> = None;
    let mut p = 0usize;
    for e in &entries {
        let end = p.checked_add(e.stream_len).ok_or(BadInput)?;
        if end > decoded.len() {
            return Err(BadInput);
        }
        let data = &decoded[p..end];
        p = end;
        match e.tag {
            GLYF => glyf = Some((data, e.transformed)),
            LOCA => {
                // 变换过的 loca 由 glyf 重建。
                if !e.transformed {
                    out.insert(e.tag, data.to_vec());
                }
            }
            HMTX if e.transformed => hmtx = Some(data), // 等 glyf 出 xMin 再重建
            _ => {
                out.insert(e.tag, data.to_vec());
            }
        }
    }

    let mut x_mins: Vec<i32> = Vec::new();
    if let Some((data, transformed)) = glyf {
        if transformed {
            let g = reconstruct_glyf(data)?;
            out.insert(GLYF, g.glyf);
            out.insert(LOCA, g.loca);
            x_mins = g.x_mins;
            if let Some(head) = out.get_mut(&HEAD) {
                if head.len() >= 52 {
                    // 一律输出长 loca。
                    head[50] = 0;
                    head[51] = 1;
                }
            }
        } else {
            out.insert(GLYF, data.to_vec());
        }
    }

    if let Some(data) = hmtx {
        let hhea = out.get(&HHEA).ok_or(BadInput)?;
        if hhea.len() < 36 {
            return Err(BadInput);
        }
        let n_hmetrics = u16::from_be_bytes([hhea[34], hhea[35]]) as usize;
        let rebuilt = reconstruct_hmtx(data, n_hmetrics, &x_mins)?;
        out.insert(HMTX, rebuilt);
    }

    Ok(build_sfnt(flavor, &out))
}

fn brotli_decode(comp: &[u8], expected: usize) -> R<Vec<u8>> {
    // 常规路径：表流总长已知，直接解进预分配缓冲区（比流式 Read 少一层 64 KiB 中转，
    // CJK 字体实测快 10%～15%）。
    let mut out = vec![0u8; expected];
    let info = brotli_decompressor::brotli_decode(comp, &mut out);
    match info.result {
        brotli_decompressor::BrotliResult::ResultSuccess => {
            out.truncate(info.decoded_size);
            return Ok(out);
        }
        brotli_decompressor::BrotliResult::NeedsMoreOutput => {} // 流比表目录声明的长：走流式
        _ => return Err(BadInput),
    }
    drop(out);
    let mut decoded = Vec::with_capacity(expected);
    brotli_decompressor::Decompressor::new(comp, 1 << 16)
        .read_to_end(&mut decoded)
        .map_err(|_| BadInput)?;
    Ok(decoded)
}

struct GlyfResult {
    glyf: Vec<u8>,
    loca: Vec<u8>,
    x_mins: Vec<i32>,
}

#[inline]
fn put_i16(out: &mut Vec<u8>, v: i32) {
    out.extend_from_slice(&(v as i16).to_be_bytes());
}

#[inline]
fn put_u16(out: &mut Vec<u8>, v: i32) {
    out.extend_from_slice(&(v as u16).to_be_bytes());
}

fn reconstruct_glyf(data: &[u8]) -> R<GlyfResult> {
    let mut h = Reader::new(data);
    h.u16()?; // reserved
    let option_flags = h.u16()?;
    let num_glyphs = h.u16()? as usize;
    h.u16()?; // indexFormat：一律输出长 loca
    let mut sizes = [0usize; 7];
    for s in &mut sizes {
        *s = h.u32()? as usize;
    }
    let mut n_contour = Reader::new(h.take(sizes[0])?);
    let mut n_points = Reader::new(h.take(sizes[1])?);
    let mut flag_stream = Reader::new(h.take(sizes[2])?);
    let mut glyph_stream = Reader::new(h.take(sizes[3])?);
    let mut composite_stream = Reader::new(h.take(sizes[4])?);
    let mut bbox_stream = Reader::new(h.take(sizes[5])?);
    let mut instruction_stream = Reader::new(h.take(sizes[6])?);
    let overlap_bitmap: Option<&[u8]> = if option_flags & 0x0001 != 0 {
        Some(h.take((num_glyphs + 7) >> 3)?)
    } else {
        None
    };

    let bitmap_len = ((num_glyphs + 31) >> 5) << 2;
    let bbox_bitmap = bbox_stream.take(bitmap_len)?;

    let mut glyf: Vec<u8> = Vec::with_capacity(data.len() + data.len() / 2);
    let mut loca: Vec<u8> = Vec::with_capacity((num_glyphs + 1) * 4);
    loca.extend_from_slice(&0u32.to_be_bytes());
    let mut x_mins: Vec<i32> = Vec::with_capacity(num_glyphs);
    let mut scratch = Scratch::default();

    for i in 0..num_glyphs {
        let nc = n_contour.i16()?;
        let has_bbox = bbox_bitmap[i >> 3] & (0x80 >> (i & 7)) != 0;
        let start = glyf.len();
        let x_min = if nc == 0 {
            0
        } else if nc > 0 {
            let overlap = overlap_bitmap.is_some_and(|b| b[i >> 3] & (0x80 >> (i & 7)) != 0);
            simple_glyph(
                nc as i32,
                has_bbox,
                overlap,
                &mut n_points,
                &mut flag_stream,
                &mut glyph_stream,
                &mut instruction_stream,
                &mut bbox_stream,
                &mut scratch,
                &mut glyf,
            )?
        } else {
            composite_glyph(
                has_bbox,
                &mut composite_stream,
                &mut glyph_stream,
                &mut instruction_stream,
                &mut bbox_stream,
                &mut glyf,
            )?
        };
        x_mins.push(x_min);
        if (glyf.len() - start) % 2 == 1 {
            glyf.push(0); // 2 字节对齐
        }
        let off = u32::try_from(glyf.len()).map_err(|_| BadInput)?;
        loca.extend_from_slice(&off.to_be_bytes());
    }
    Ok(GlyfResult { glyf, loca, x_mins })
}

/// 简单字形复用的临时缓冲区（CJK 字体几万个字形，别每个字形重新分配）。
#[derive(Default)]
struct Scratch {
    end_pts: Vec<i32>,
    pts: Vec<(i32, i32, bool)>,
    flags: Vec<u8>,
    xs: Vec<u8>,
    ys: Vec<u8>,
}

#[allow(clippy::too_many_arguments)]
fn simple_glyph(
    nc: i32,
    has_bbox: bool,
    overlap: bool,
    n_points: &mut Reader,
    flag_stream: &mut Reader,
    glyph_stream: &mut Reader,
    instruction_stream: &mut Reader,
    bbox_stream: &mut Reader,
    s: &mut Scratch,
    out: &mut Vec<u8>,
) -> R<i32> {
    s.end_pts.clear();
    let mut total: i32 = 0;
    for _ in 0..nc {
        total += n_points.read255()? as i32;
        s.end_pts.push(total - 1);
    }

    let flags = flag_stream.take(total as usize)?;
    triplet_decode(flags, glyph_stream, &mut s.pts)?;

    let instr_len = glyph_stream.read255()?;
    let instr = instruction_stream.take(instr_len as usize)?;

    let (x_min, y_min, x_max, y_max) = if has_bbox {
        (
            bbox_stream.i16()? as i32,
            bbox_stream.i16()? as i32,
            bbox_stream.i16()? as i32,
            bbox_stream.i16()? as i32,
        )
    } else if s.pts.is_empty() {
        (0, 0, 0, 0)
    } else {
        let (mut x0, mut y0) = (s.pts[0].0, s.pts[0].1);
        let (mut x1, mut y1) = (x0, y0);
        for &(x, y, _) in &s.pts {
            x0 = x0.min(x);
            x1 = x1.max(x);
            y0 = y0.min(y);
            y1 = y1.max(y);
        }
        (x0, y0, x1, y1)
    };

    put_i16(out, nc);
    put_i16(out, x_min);
    put_i16(out, y_min);
    put_i16(out, x_max);
    put_i16(out, y_max);
    for &e in &s.end_pts {
        put_u16(out, e);
    }
    put_u16(out, instr_len as i32);
    out.extend_from_slice(instr);

    // 按标准 TrueType 形式重编 flag + 坐标（带 REPEAT）。
    s.flags.clear();
    s.xs.clear();
    s.ys.clear();
    let (mut prev_x, mut prev_y) = (0i32, 0i32);
    for &(x, y, on_curve) in &s.pts {
        let dx = x - prev_x;
        let dy = y - prev_y;
        prev_x = x;
        prev_y = y;
        let mut flag: u8 = if on_curve { 0x01 } else { 0x00 };
        if dx == 0 {
            flag |= 0x10; // X_IS_SAME
        } else if (-255..=255).contains(&dx) {
            flag |= 0x02; // X_SHORT
            if dx > 0 {
                flag |= 0x10;
            }
            s.xs.push(dx.unsigned_abs() as u8);
        } else {
            s.xs.extend_from_slice(&(dx as i16).to_be_bytes());
        }
        if dy == 0 {
            flag |= 0x20; // Y_IS_SAME
        } else if (-255..=255).contains(&dy) {
            flag |= 0x04; // Y_SHORT
            if dy > 0 {
                flag |= 0x20;
            }
            s.ys.push(dy.unsigned_abs() as u8);
        } else {
            s.ys.extend_from_slice(&(dy as i16).to_be_bytes());
        }
        s.flags.push(flag);
    }
    if overlap {
        if let Some(first) = s.flags.first_mut() {
            *first |= 0x40; // OVERLAP_SIMPLE
        }
    }
    run_length_flags(&s.flags, out);
    out.extend_from_slice(&s.xs);
    out.extend_from_slice(&s.ys);
    Ok(x_min)
}

fn composite_glyph(
    has_bbox: bool,
    composite_stream: &mut Reader,
    glyph_stream: &mut Reader,
    instruction_stream: &mut Reader,
    bbox_stream: &mut Reader,
    out: &mut Vec<u8>,
) -> R<i32> {
    let start = composite_stream.p;
    let mut have_instr = false;
    loop {
        let flags = composite_stream.u16()?;
        composite_stream.u16()?; // glyphIndex
        let mut skip = if flags & 0x0001 != 0 { 4 } else { 2 }; // ARG_1_AND_2_ARE_WORDS
        if flags & 0x0008 != 0 {
            skip += 2; // WE_HAVE_A_SCALE
        } else if flags & 0x0040 != 0 {
            skip += 4; // WE_HAVE_AN_X_AND_Y_SCALE
        } else if flags & 0x0080 != 0 {
            skip += 8; // WE_HAVE_A_TWO_BY_TWO
        }
        composite_stream.take(skip)?;
        if flags & 0x0100 != 0 {
            have_instr = true; // WE_HAVE_INSTRUCTIONS
        }
        if flags & 0x0020 == 0 {
            break; // MORE_COMPONENTS
        }
    }
    let comp = &composite_stream.d[start..composite_stream.p];

    let mut instr: &[u8] = &[];
    let mut instr_len = 0u16;
    if have_instr {
        instr_len = glyph_stream.read255()?;
        instr = instruction_stream.take(instr_len as usize)?;
    }

    let (x_min, y_min, x_max, y_max) = if has_bbox {
        (
            bbox_stream.i16()? as i32,
            bbox_stream.i16()? as i32,
            bbox_stream.i16()? as i32,
            bbox_stream.i16()? as i32,
        )
    } else {
        (0, 0, 0, 0)
    };

    put_i16(out, -1);
    put_i16(out, x_min);
    put_i16(out, y_min);
    put_i16(out, x_max);
    put_i16(out, y_max);
    out.extend_from_slice(comp);
    if have_instr {
        put_u16(out, instr_len as i32);
        out.extend_from_slice(instr);
    }
    Ok(x_min)
}

#[inline]
fn sign(flag: u8, base: i32) -> i32 {
    if flag & 1 != 0 {
        base
    } else {
        -base
    }
}

fn triplet_decode(flags: &[u8], g: &mut Reader, pts: &mut Vec<(i32, i32, bool)>) -> R<()> {
    pts.clear();
    let (mut x, mut y) = (0i32, 0i32);
    for &flag in flags {
        let on_curve = flag & 0x80 == 0;
        let f = flag & 0x7F;
        let fi = f as i32;
        let (dx, dy) = if f < 10 {
            (0, sign(f, ((fi & 14) << 7) + g.u8()? as i32))
        } else if f < 20 {
            (sign(f, (((fi - 10) & 14) << 7) + g.u8()? as i32), 0)
        } else if f < 84 {
            let b0 = fi - 20;
            let b1 = g.u8()? as i32;
            (
                sign(f, 1 + (b0 & 0x30) + (b1 >> 4)),
                sign(f >> 1, 1 + ((b0 & 0x0C) << 2) + (b1 & 0x0F)),
            )
        } else if f < 120 {
            let b0 = fi - 84;
            let b1 = g.u8()? as i32;
            let b2 = g.u8()? as i32;
            (
                sign(f, 1 + ((b0 / 12) << 8) + b1),
                sign(f >> 1, 1 + (((b0 % 12) >> 2) << 8) + b2),
            )
        } else if f < 124 {
            let b1 = g.u8()? as i32;
            let b2 = g.u8()? as i32;
            let b3 = g.u8()? as i32;
            (
                sign(f, (b1 << 4) + (b2 >> 4)),
                sign(f >> 1, ((b2 & 0x0F) << 8) + b3),
            )
        } else {
            let b1 = g.u8()? as i32;
            let b2 = g.u8()? as i32;
            let b3 = g.u8()? as i32;
            let b4 = g.u8()? as i32;
            (sign(f, (b1 << 8) + b2), sign(f >> 1, (b3 << 8) + b4))
        };
        x += dx;
        y += dy;
        pts.push((x, y, on_curve));
    }
    Ok(())
}

fn run_length_flags(flags: &[u8], out: &mut Vec<u8>) {
    let mut i = 0usize;
    while i < flags.len() {
        let f = flags[i];
        let mut repeat = 0usize;
        while i + repeat + 1 < flags.len() && flags[i + repeat + 1] == f && repeat < 255 {
            repeat += 1;
        }
        if repeat > 0 {
            out.push(f | 0x08); // REPEAT_FLAG
            out.push(repeat as u8);
            i += repeat + 1;
        } else {
            out.push(f);
            i += 1;
        }
    }
}

/// 逆转 hmtx 变换（§5.2）：省掉的 lsb 由 glyf 的 xMin 补。
fn reconstruct_hmtx(data: &[u8], n_hmetrics: usize, x_mins: &[i32]) -> R<Vec<u8>> {
    let num_glyphs = x_mins.len();
    if n_hmetrics == 0 || n_hmetrics > num_glyphs {
        return Err(BadInput);
    }
    let mut r = Reader::new(data);
    let flags = r.u8()?;
    if flags & 0xFC != 0 {
        return Err(BadInput); // 保留位必须为 0
    }
    let no_lsb = flags & 0x01 != 0;
    let no_mono_lsb = flags & 0x02 != 0;

    let mut advances = Vec::with_capacity(n_hmetrics);
    for _ in 0..n_hmetrics {
        advances.push(r.u16()?);
    }
    let mut lsbs = Vec::with_capacity(n_hmetrics);
    for &x_min in x_mins.iter().take(n_hmetrics) {
        lsbs.push(if no_lsb { x_min } else { r.i16()? as i32 });
    }
    let mono = num_glyphs - n_hmetrics;
    let mut mono_lsbs = Vec::with_capacity(mono);
    for &x_min in &x_mins[n_hmetrics..] {
        mono_lsbs.push(if no_mono_lsb { x_min } else { r.i16()? as i32 });
    }

    let mut out = Vec::with_capacity(n_hmetrics * 4 + mono * 2);
    for i in 0..n_hmetrics {
        out.extend_from_slice(&advances[i].to_be_bytes());
        put_i16(&mut out, lsbs[i]);
    }
    for &v in &mono_lsbs {
        put_i16(&mut out, v);
    }
    Ok(out)
}

/// 表校验和：大端 u32 求和，尾部不足 4 字节补零。
fn checksum(data: &[u8]) -> u32 {
    let mut chunks = data.chunks_exact(4);
    let mut sum = 0u32;
    for c in &mut chunks {
        sum = sum.wrapping_add(u32::from_be_bytes([c[0], c[1], c[2], c[3]]));
    }
    let rem = chunks.remainder();
    if !rem.is_empty() {
        let mut b = [0u8; 4];
        b[..rem.len()].copy_from_slice(rem);
        sum = sum.wrapping_add(u32::from_be_bytes(b));
    }
    sum
}

/// 按标签升序写表目录、每张表 4 字节对齐，重算 `head.checkSumAdjustment`。
/// 目录里的表校验和取自写入前的表数据（含原 checkSumAdjustment），与 Dart 版一致。
fn build_sfnt(flavor: u32, tables: &BTreeMap<u32, Vec<u8>>) -> Vec<u8> {
    let n = tables.len();
    let mut offset = 12 + 16 * n;
    let mut offsets = Vec::with_capacity(n);
    for data in tables.values() {
        offsets.push(offset);
        offset = (offset + data.len() + 3) & !3;
    }
    let total = offset;
    let mut out = vec![0u8; total];

    let mut max_pow2 = 1usize;
    while max_pow2 * 2 <= n {
        max_pow2 *= 2;
    }
    let log2 = max_pow2.trailing_zeros() as u16;
    out[0..4].copy_from_slice(&flavor.to_be_bytes());
    out[4..6].copy_from_slice(&(n as u16).to_be_bytes());
    out[6..8].copy_from_slice(&((max_pow2 * 16) as u16).to_be_bytes());
    out[8..10].copy_from_slice(&log2.to_be_bytes());
    out[10..12].copy_from_slice(&((n * 16 - max_pow2 * 16) as u16).to_be_bytes());

    let mut rec = 12;
    let mut head_off: Option<usize> = None;
    for ((&tag, data), &d_off) in tables.iter().zip(&offsets) {
        out[rec..rec + 4].copy_from_slice(&tag.to_be_bytes());
        out[rec + 4..rec + 8].copy_from_slice(&checksum(data).to_be_bytes());
        out[rec + 8..rec + 12].copy_from_slice(&(d_off as u32).to_be_bytes());
        out[rec + 12..rec + 16].copy_from_slice(&(data.len() as u32).to_be_bytes());
        out[d_off..d_off + data.len()].copy_from_slice(data);
        if tag == HEAD {
            head_off = Some(d_off);
        }
        rec += 16;
    }

    if let Some(h) = head_off {
        if h + 12 <= total {
            out[h + 8..h + 12].copy_from_slice(&[0; 4]);
            let sum = checksum(&out);
            out[h + 8..h + 12].copy_from_slice(&0xB1B0_AFBAu32.wrapping_sub(sum).to_be_bytes());
        }
    }
    out
}

/// WOFF2 → sfnt。成功时 `*out_ptr` / `*out_len` 指向本库分配的 sfnt，调用方用
/// `ffc_free_bytes` 释放；输入不是可解码的 WOFF2 时返回 `BAD_INPUT`。
///
/// # Safety
/// `input` 指向至少 `input_len` 个可读字节；`out_ptr` / `out_len` 非空且可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_font_woff2_to_sfnt(
    input: *const u8,
    input_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if input.is_null() || out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let bytes = std::slice::from_raw_parts(input, input_len);
        match woff2_to_sfnt(bytes) {
            Ok(sfnt) => {
                hand_over_bytes(sfnt, out_ptr, out_len);
                status::OK
            }
            Err(BadInput) => status::BAD_INPUT,
        }
    })
}

/// OpenType 表校验和（大端 u32 回绕求和，尾部不足 4 字节补零）。`head_table != 0` 时
/// 偏移 8 的字（`checkSumAdjustment`）按 0 算。整字体校验和就是对整份 sfnt 调一次。
/// 结果写进 `*out`。
///
/// # Safety
/// `data` 指向至少 `len` 个可读字节（`len == 0` 时可为任意非空指针）；`out` 非空且可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_font_table_checksum(
    data: *const u8,
    len: usize,
    head_table: i32,
    out: *mut u32,
) -> i32 {
    guard(|| {
        if data.is_null() || out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let bytes = std::slice::from_raw_parts(data, len);
        let mut sum = checksum(bytes);
        if head_table != 0 && len > 8 {
            // 减掉偏移 8 那个字（可能是补零的尾字）。
            let mut w = [0u8; 4];
            let end = len.min(12);
            w[..end - 8].copy_from_slice(&bytes[8..end]);
            sum = sum.wrapping_sub(u32::from_be_bytes(w));
        }
        *out = sum;
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hmtx_omitted_lsbs_come_from_xmin() {
        // flags=0x03（两组 lsb 都省）；advance 500、600。
        let out = reconstruct_hmtx(&[0x03, 0x01, 0xF4, 0x02, 0x58], 2, &[10, 20, 30]).unwrap();
        assert_eq!(out, vec![0x01, 0xF4, 0, 10, 0x02, 0x58, 0, 20, 0, 30]);
    }

    #[test]
    fn hmtx_present_lsbs_are_read() {
        let tx = [
            0x00, 0x01, 0xF4, 0x02, 0x58, 0x00, 0x05, 0xFF, 0xFB, 0x00, 0x09,
        ];
        let out = reconstruct_hmtx(&tx, 2, &[0, 0, 0]).unwrap();
        assert_eq!(out, vec![0x01, 0xF4, 0, 5, 0x02, 0x58, 0xFF, 0xFB, 0, 9]);
    }

    #[test]
    fn hmtx_rejects_bad_metric_counts_and_reserved_bits() {
        assert_eq!(reconstruct_hmtx(&[0x03, 0, 0], 5, &[0, 0]), Err(BadInput));
        assert_eq!(reconstruct_hmtx(&[0x03, 0, 0], 0, &[0, 0]), Err(BadInput));
        assert_eq!(reconstruct_hmtx(&[0x04, 0, 0], 1, &[0]), Err(BadInput));
    }

    #[test]
    fn run_length_caps_repeat_at_255() {
        let mut out = Vec::new();
        run_length_flags(&[1u8; 300], &mut out);
        assert_eq!(out, vec![0x09, 255, 0x09, 43]);
        out.clear();
        run_length_flags(&[1, 2, 2], &mut out);
        assert_eq!(out, vec![1, 0x0A, 1]);
    }

    #[test]
    fn base128_rejects_leading_zero_and_overflow() {
        assert_eq!(Reader::new(&[0x80, 0x01]).base128(), Err(BadInput));
        assert_eq!(
            Reader::new(&[0x90, 0x80, 0x80, 0x80, 0x00]).base128(),
            Err(BadInput)
        );
        assert_eq!(Reader::new(&[0x81, 0x00]).base128(), Ok(128));
    }

    #[test]
    fn rejects_non_woff2_and_truncated_input() {
        assert_eq!(woff2_to_sfnt(b"OTTO\0\0\0\0"), Err(BadInput));
        assert_eq!(woff2_to_sfnt(b"wOF2"), Err(BadInput));
        assert_eq!(woff2_to_sfnt(&[]), Err(BadInput));
    }

    #[test]
    fn checksum_pads_tail_with_zeros() {
        assert_eq!(checksum(&[0, 0, 0, 1, 0x80]), 1 + 0x8000_0000);
    }

    #[test]
    fn table_checksum_zeroes_head_adjustment_word() {
        let data: Vec<u8> = (0u8..54).map(|b| b.wrapping_mul(37)).collect();
        let mut plain = 0u32;
        let mut head = 0u32;
        unsafe {
            assert_eq!(ffc_font_table_checksum(data.as_ptr(), data.len(), 0, &mut plain), 0);
            assert_eq!(ffc_font_table_checksum(data.as_ptr(), data.len(), 1, &mut head), 0);
        }
        assert_eq!(plain, checksum(&data));
        let mut zeroed = data.clone();
        zeroed[8..12].copy_from_slice(&[0; 4]);
        assert_eq!(head, checksum(&zeroed));
        // 偏移 8 是补零的尾字（长度 10）。
        let short = &data[..10];
        let mut s = 0u32;
        unsafe { ffc_font_table_checksum(short.as_ptr(), short.len(), 1, &mut s) };
        assert_eq!(s, checksum(&short[..8]));
        let mut e = 7u32;
        unsafe { ffc_font_table_checksum(data.as_ptr(), 0, 1, &mut e) };
        assert_eq!(e, 0);
    }

    #[test]
    fn ffi_rejects_null_arguments() {
        let mut p = std::ptr::null_mut();
        let mut n = 0usize;
        let st = unsafe { ffc_font_woff2_to_sfnt(std::ptr::null(), 0, &mut p, &mut n) };
        assert_eq!(st, status::NULL_ARGUMENT);
        let st = unsafe { ffc_font_woff2_to_sfnt(b"x".as_ptr(), 1, &mut p, &mut n) };
        assert_eq!(st, status::BAD_INPUT);
    }
}
