//! AVIF 图像序列（动图，`ftyp` 品牌 `avis`）的逐帧解码：`ffc_image_avif_anim_*` 走这里。
//!
//! 动图 AVIF 除了 `meta` 里的静态主图（通常就是首帧，静态路径 [super::decode] 解的那张），还有
//! 一条 ISOBMFF 视频轨（`moov/trak`，处理器 `pict`，样本描述 `av01`）：样本 = AV1 时间单元，
//! 位置来自 `stsz` + `stsc` + `stco`/`co64`，时长来自 `stts` 与 `mdhd` 的 timescale，循环标志来自
//! `edts/elst` 的 flags bit 0（AVIF 规范 §7.4：置位 = 无限重复；ffmpeg `-loop 0` 即写这个）。
//!
//! 内存：只持有文件字节（Rust 自己拷一份）+ 样本表 + 一个 rav1d 上下文 + 当前一帧，**按需逐帧解**，
//! 不把整段动图解进内存（1440 宽 47 帧 RGBA 全解要 ~220 MB）。
//!
//! 输出：每帧 YUV → RGB（同静态路径的 [super::Frame::to_rgb8]）后按 `max_width` 只缩不放
//! （等比，box 平均 = [crate::image::resize_into] 的 `INTERP_AVERAGE`），写成 RGBA8888（alpha 255）。
//!
//! 静态 AVIF（无可用视频轨）也能 open：退化成 1 帧序列，像素来自 [super::decode]（含 grid /
//! alpha / clap / irot / imir），时长 0。
//!
//! 不支持（忽略）：alpha 辅助轨（`tref/auxl` 指向颜色轨的那条）——动图一律按不透明输出；
//! 轨道级变换（`tkhd` 矩阵、样本描述里的 `clap`/`irot`）；`stz2`；编辑表里的空编辑 / 起点偏移。
//! 本仓制卡（ffmpeg `libsvtav1`，`yuv420p`）不产生这些。

use super::{children, Av1Decoder, BoxHeader, Cursor, R};
use crate::image::{resize_into, View, INTERP_AVERAGE};
use crate::status;
use std::panic::{catch_unwind, AssertUnwindSafe};

/// 样本数上限：防恶意 `stsz` 让我们分配海量表项（动图卡片几十帧，正常编码器远低于此）。
const MAX_SAMPLES: usize = 1 << 20;

struct Sample {
    offset: usize,
    len: usize,
    duration_ms: u32,
}

/// 视频轨解析结果。
struct Track {
    samples: Vec<Sample>,
    /// 样本描述里的 `colr`（nclx）：`(matrix_coefficients, full_range)`；没有则用 AV1 序列头。
    colr: Option<(u16, bool)>,
    /// `elst` flags bit 0：无限循环。
    repeat: bool,
}

enum Source {
    /// 视频轨：持有 rav1d 上下文、下一个要送的样本下标。
    Track {
        track: Track,
        decoder: Option<Av1Decoder>,
        next: usize,
    },
    /// 静态图：已解好、已缩放的 RGBA。
    Still(Vec<u8>),
}

/// `ffc_image_avif_anim_open` 交出的句柄指向的对象。
pub(crate) struct AvifAnimation {
    data: Vec<u8>,
    source: Source,
    /// 源（解码）尺寸。
    src_w: usize,
    src_h: usize,
    /// 输出（缩放后）尺寸。
    pub(crate) width: u32,
    pub(crate) height: u32,
    /// open 时解出的首帧，第一次 [Self::next_frame] 直接交出，不重复解码。
    pending: Option<Vec<u8>>,
    /// rav1d 曾 panic：上下文状态不可信，已泄漏（见 [Av1Decoder]），之后一律 BAD_INPUT。
    poisoned: bool,
}

/// 一帧的元数据。
pub(crate) struct FrameInfo {
    pub(crate) index: u32,
    pub(crate) duration_ms: u32,
}

impl AvifAnimation {
    /// 解析容器、解出首帧（顺带验证码流与真实尺寸）。`max_width` = 0 表示不缩放。
    pub(crate) fn open(bytes: &[u8], max_width: u32) -> R<Self> {
        if !super::is_avif(bytes) {
            return Err(status::BAD_INPUT);
        }
        let data = bytes.to_vec();
        match parse_track(&data) {
            Some(Ok(track)) => Self::open_track(data, track, max_width),
            Some(Err(code)) => Err(code),
            None => Self::open_still(data, max_width),
        }
    }

    fn open_still(data: Vec<u8>, max_width: u32) -> R<Self> {
        let (px, w, h, ch) = super::decode(&data)?;
        let (w, h) = (w as usize, h as usize);
        let (ow, oh) = target_size(w, h, max_width);
        let rgba = scale_to_rgba(&px, w, h, ch as usize, ow, oh)?;
        Ok(Self {
            // 静态图只用解好的像素，不留文件字节。
            data: Vec::new(),
            source: Source::Still(rgba),
            src_w: w,
            src_h: h,
            width: ow as u32,
            height: oh as u32,
            pending: None,
            poisoned: false,
        })
    }

    fn open_track(data: Vec<u8>, track: Track, max_width: u32) -> R<Self> {
        let mut anim = Self {
            data,
            source: Source::Track {
                track,
                decoder: None,
                next: 0,
            },
            src_w: 0,
            src_h: 0,
            width: 0,
            height: 0,
            pending: None,
            poisoned: false,
        };
        let (_, rgb, w, h) = anim.decode_next()?;
        let (ow, oh) = target_size(w, h, max_width);
        anim.src_w = w;
        anim.src_h = h;
        anim.width = ow as u32;
        anim.height = oh as u32;
        anim.pending = Some(scale_to_rgba(&rgb, w, h, 3, ow, oh)?);
        Ok(anim)
    }

    pub(crate) fn frame_count(&self) -> u32 {
        match &self.source {
            Source::Track { track, .. } => track.samples.len() as u32,
            Source::Still(_) => 1,
        }
    }

    pub(crate) fn source_size(&self) -> (u32, u32) {
        (self.src_w as u32, self.src_h as u32)
    }

    /// 无限循环（`elst` 置了 repeat）；静态图为 false。
    pub(crate) fn repeats(&self) -> bool {
        match &self.source {
            Source::Track { track, .. } => track.repeat,
            Source::Still(_) => false,
        }
    }

    /// 解下一帧写进 `out`（`width * height * 4` 字节 RGBA）；末帧之后回到第 0 帧。
    pub(crate) fn next_frame(&mut self, out: &mut [u8]) -> R<FrameInfo> {
        let need = self.width as usize * self.height as usize * 4;
        if out.len() < need {
            return Err(status::BUFFER_TOO_SMALL);
        }
        if let Source::Still(px) = &self.source {
            out[..need].copy_from_slice(px);
            return Ok(FrameInfo {
                index: 0,
                duration_ms: 0,
            });
        }
        let (index, rgba) = match self.pending.take() {
            // open 解出的第 0 帧。
            Some(p) => (0, p),
            None => {
                let (index, rgb, w, h) = self.decode_next()?;
                if (w, h) != (self.src_w, self.src_h) {
                    // 中途变分辨率：输出缓冲按首帧定的尺寸分配，不接受。
                    return Err(status::BAD_INPUT);
                }
                let (ow, oh) = (self.width as usize, self.height as usize);
                (index, scale_to_rgba(&rgb, w, h, 3, ow, oh)?)
            }
        };
        out[..need].copy_from_slice(&rgba);
        let duration_ms = match &self.source {
            Source::Track { track, .. } => track.samples[index].duration_ms,
            Source::Still(_) => 0,
        };
        Ok(FrameInfo {
            index: index as u32,
            duration_ms,
        })
    }

    /// 送下一个样本、取出 `(样本下标, RGB（源尺寸）, 宽, 高)`。到末尾时 flush 上下文并从第 0 个样本重来
    /// （首样本必是关键帧）。rav1d panic → 上下文作废（泄漏）、本对象 poisoned。
    fn decode_next(&mut self) -> R<(usize, Vec<u8>, usize, usize)> {
        if self.poisoned {
            return Err(status::BAD_INPUT);
        }
        let data = &self.data;
        let Source::Track {
            track,
            decoder,
            next,
        } = &mut self.source
        else {
            return Err(status::BAD_INPUT);
        };
        if *next >= track.samples.len() {
            *next = 0;
            if let Some(d) = decoder.as_mut() {
                let flushed = catch_unwind(AssertUnwindSafe(|| d.flush()));
                if flushed.is_err() {
                    if let Some(d) = decoder.take() {
                        d.leak();
                    }
                    self.poisoned = true;
                    return Err(status::BAD_INPUT);
                }
            }
        }
        if decoder.is_none() {
            *decoder = Some(Av1Decoder::new()?);
        }
        let index = *next;
        let sample = &track.samples[index];
        let bytes = &data[sample.offset..sample.offset + sample.len];
        let colr = track.colr;
        let dec = decoder.as_mut().unwrap();
        let result = catch_unwind(AssertUnwindSafe(|| -> R<(Vec<u8>, usize, usize)> {
            let frame = dec.decode(bytes)?;
            let (matrix, full) = colr
                .map(|(m, f)| (m as u32, f))
                .unwrap_or((frame.matrix, frame.full_range));
            Ok((frame.to_rgb8(matrix, full), frame.w, frame.h))
        }));
        match result {
            Ok(Ok((rgb, w, h))) => {
                *next += 1;
                Ok((index, rgb, w, h))
            }
            Ok(Err(code)) => {
                // 坏样本：正常关闭上下文（下次从这个样本重建也会再撞上它，交给调用方停播）。
                if let Some(d) = decoder.take() {
                    d.close();
                }
                Err(code)
            }
            Err(_) => {
                if let Some(d) = decoder.take() {
                    d.leak();
                }
                self.poisoned = true;
                Err(status::BAD_INPUT)
            }
        }
    }
}

impl Drop for AvifAnimation {
    fn drop(&mut self) {
        if let Source::Track { decoder, .. } = &mut self.source {
            if let Some(d) = decoder.take() {
                if !self.poisoned {
                    d.close();
                }
            }
        }
    }
}

/// 只缩不放、按宽等比；高至少 1。
fn target_size(w: usize, h: usize, max_width: u32) -> (usize, usize) {
    let max = max_width as usize;
    if max == 0 || w <= max {
        return (w, h);
    }
    let oh = ((h as u64 * max as u64 + w as u64 / 2) / w as u64).max(1) as usize;
    (max, oh)
}

/// 行紧排 `ch`（3 / 4）通道 → 缩到 `ow × oh` 的 RGBA8888。
fn scale_to_rgba(px: &[u8], w: usize, h: usize, ch: usize, ow: usize, oh: usize) -> R<Vec<u8>> {
    let scaled;
    let src: &[u8] = if (ow, oh) == (w, h) {
        px
    } else {
        let view = View::new(px, w * ch, ch as u32, 0, 0, w as u32, h as u32)?;
        let mut dst = vec![0u8; ow * oh * ch];
        resize_into(&view, &mut dst, ow, oh, INTERP_AVERAGE);
        scaled = dst;
        &scaled
    };
    if ch == 4 {
        return Ok(src.to_vec());
    }
    let mut out = vec![255u8; ow * oh * 4];
    for (o, i) in out.chunks_exact_mut(4).zip(src.chunks_exact(3)) {
        o[..3].copy_from_slice(i);
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// moov / trak / stbl
// ---------------------------------------------------------------------------

fn find<'b>(boxes: &'b [BoxHeader], kind: &[u8; 4]) -> Option<&'b BoxHeader> {
    boxes.iter().find(|b| &b.kind == kind)
}

/// 找第一条可用的颜色视频轨。`None` = 文件里没有（静态 AVIF）；`Some(Err)` = 有轨但表坏了。
fn parse_track(data: &[u8]) -> Option<R<Track>> {
    let top = children(data, 0, data.len()).ok()?;
    let moov = find(&top, b"moov")?;
    let traks = match children(data, moov.body, moov.end) {
        Ok(v) => v,
        Err(e) => return Some(Err(e)),
    };
    for trak in traks.iter().filter(|b| &b.kind == b"trak") {
        match parse_trak(data, trak) {
            Ok(Some(t)) => return Some(Ok(t)),
            Ok(None) => continue,
            Err(e) => return Some(Err(e)),
        }
    }
    None
}

/// `Ok(None)` = 不是我们要的轨（非图像处理器 / alpha 辅助轨 / 非 av01）。
fn parse_trak(data: &[u8], trak: &BoxHeader) -> R<Option<Track>> {
    let boxes = children(data, trak.body, trak.end)?;
    if let Some(tref) = find(&boxes, b"tref") {
        // alpha 等辅助轨用 `auxl` 指向颜色轨。
        if children(data, tref.body, tref.end)?
            .iter()
            .any(|r| &r.kind == b"auxl")
        {
            return Ok(None);
        }
    }
    let repeat = match find(&boxes, b"edts") {
        Some(edts) => match find(&children(data, edts.body, edts.end)?, b"elst") {
            Some(elst) => {
                let (_, flags) = Cursor::new(&data[elst.body..elst.end]).full_box()?;
                flags & 1 != 0
            }
            None => false,
        },
        None => false,
    };
    let Some(mdia) = find(&boxes, b"mdia") else {
        return Ok(None);
    };
    let mdia_boxes = children(data, mdia.body, mdia.end)?;
    let Some(hdlr) = find(&mdia_boxes, b"hdlr") else {
        return Ok(None);
    };
    let mut c = Cursor::new(&data[hdlr.body..hdlr.end]);
    c.full_box()?;
    c.u32()?; // pre_defined
    let handler = c.bytes(4)?;
    if handler != b"pict" && handler != b"vide" {
        return Ok(None);
    }
    let mdhd = find(&mdia_boxes, b"mdhd").ok_or(status::BAD_INPUT)?;
    let mut c = Cursor::new(&data[mdhd.body..mdhd.end]);
    let (v, _) = c.full_box()?;
    c.bytes(if v == 1 { 16 } else { 8 })?; // creation / modification time
    let timescale = c.u32()?;
    if timescale == 0 {
        return Err(status::BAD_INPUT);
    }
    let minf = find(&mdia_boxes, b"minf").ok_or(status::BAD_INPUT)?;
    let minf_boxes = children(data, minf.body, minf.end)?;
    let stbl = find(&minf_boxes, b"stbl").ok_or(status::BAD_INPUT)?;
    let stbl_boxes = children(data, stbl.body, stbl.end)?;

    let stsd = find(&stbl_boxes, b"stsd").ok_or(status::BAD_INPUT)?;
    let entries = children(data, stsd.body + 8, stsd.end)?; // FullBox + entry_count
    let entry = entries.first().ok_or(status::BAD_INPUT)?;
    if &entry.kind != b"av01" {
        return Ok(None);
    }
    // VisualSampleEntry 固定头 78 字节之后是子盒子（av1C / colr / pasp …）。
    let colr = if entry.body + 78 <= entry.end {
        children(data, entry.body + 78, entry.end)?
            .iter()
            .filter(|b| &b.kind == b"colr")
            .find_map(
                |b| match super::parse_property(b"colr", &data[b.body..b.end]) {
                    Ok(super::Property::Colr(m, f)) => Some((m, f)),
                    _ => None,
                },
            )
    } else {
        None
    };

    let sizes = parse_stsz(data, find(&stbl_boxes, b"stsz").ok_or(status::BAD_INPUT)?)?;
    let count = sizes.len();
    if count == 0 {
        return Err(status::BAD_INPUT);
    }
    let chunks = match (find(&stbl_boxes, b"stco"), find(&stbl_boxes, b"co64")) {
        (Some(b), _) => parse_chunk_offsets(data, b, false)?,
        (None, Some(b)) => parse_chunk_offsets(data, b, true)?,
        _ => return Err(status::BAD_INPUT),
    };
    let stsc = parse_stsc(data, find(&stbl_boxes, b"stsc").ok_or(status::BAD_INPUT)?)?;
    let offsets = sample_offsets(&sizes, &chunks, &stsc)?;
    let deltas = parse_stts(
        data,
        find(&stbl_boxes, b"stts").ok_or(status::BAD_INPUT)?,
        count,
    )?;

    // 时长按累计时刻取整再相减：每帧单独取整会累积漂移（24 fps / timescale 12800 时每帧 41.67 ms）。
    let mut samples = Vec::with_capacity(count);
    let mut t: u64 = 0;
    let to_ms = |ticks: u64| -> u64 { (ticks * 1000 + timescale as u64 / 2) / timescale as u64 };
    for i in 0..count {
        let (offset, len) = (offsets[i], sizes[i] as usize);
        let end = offset.checked_add(len).ok_or(status::BAD_INPUT)?;
        if len == 0 || end > data.len() {
            return Err(status::BAD_INPUT);
        }
        let start_ms = to_ms(t);
        t += deltas[i] as u64;
        let duration_ms = (to_ms(t) - start_ms).min(u32::MAX as u64) as u32;
        samples.push(Sample {
            offset,
            len,
            duration_ms,
        });
    }
    Ok(Some(Track {
        samples,
        colr,
        repeat,
    }))
}

fn parse_stsz(data: &[u8], b: &BoxHeader) -> R<Vec<u32>> {
    let mut c = Cursor::new(&data[b.body..b.end]);
    c.full_box()?;
    let size = c.u32()?;
    let count = c.u32()? as usize;
    if count > MAX_SAMPLES {
        return Err(status::BAD_INPUT);
    }
    if size != 0 {
        // 定长样本：总字节不可能超过文件。
        if (size as u64) * (count as u64) > data.len() as u64 {
            return Err(status::BAD_INPUT);
        }
        return Ok(vec![size; count]);
    }
    let mut out = Vec::with_capacity(count.min((b.end - b.body) / 4));
    for _ in 0..count {
        out.push(c.u32()?);
    }
    Ok(out)
}

fn parse_chunk_offsets(data: &[u8], b: &BoxHeader, wide: bool) -> R<Vec<u64>> {
    let mut c = Cursor::new(&data[b.body..b.end]);
    c.full_box()?;
    let count = c.u32()? as usize;
    let mut out = Vec::with_capacity(count.min((b.end - b.body) / 4));
    for _ in 0..count {
        out.push(if wide { c.uint(8)? } else { c.u32()? as u64 });
    }
    Ok(out)
}

/// `(first_chunk（1 起）, samples_per_chunk)`。
fn parse_stsc(data: &[u8], b: &BoxHeader) -> R<Vec<(u32, u32)>> {
    let mut c = Cursor::new(&data[b.body..b.end]);
    c.full_box()?;
    let count = c.u32()? as usize;
    let mut out = Vec::with_capacity(count.min((b.end - b.body) / 12));
    for _ in 0..count {
        let first = c.u32()?;
        let per = c.u32()?;
        c.u32()?; // sample_description_index
        if first == 0 || out.last().is_some_and(|&(f, _)| first <= f) {
            return Err(status::BAD_INPUT);
        }
        out.push((first, per));
    }
    Ok(out)
}

/// 逐样本时长（ticks），`stts` 展开后必须正好覆盖 `count` 个样本。
fn parse_stts(data: &[u8], b: &BoxHeader, count: usize) -> R<Vec<u32>> {
    let mut c = Cursor::new(&data[b.body..b.end]);
    c.full_box()?;
    let entries = c.u32()?;
    let mut out = Vec::with_capacity(count);
    for _ in 0..entries {
        let n = c.u32()? as usize;
        let delta = c.u32()?;
        if out.len() + n > count {
            return Err(status::BAD_INPUT);
        }
        out.extend(std::iter::repeat_n(delta, n));
    }
    if out.len() != count {
        return Err(status::BAD_INPUT);
    }
    Ok(out)
}

/// 按 `stsc` 把样本分进各块、块内顺排，得出每个样本的文件偏移。
fn sample_offsets(sizes: &[u32], chunks: &[u64], stsc: &[(u32, u32)]) -> R<Vec<usize>> {
    if stsc.is_empty() || stsc[0].0 != 1 {
        return Err(status::BAD_INPUT);
    }
    let mut out = Vec::with_capacity(sizes.len());
    let mut run = 0usize;
    for (ci, &chunk_offset) in chunks.iter().enumerate() {
        let chunk_no = ci as u32 + 1;
        while run + 1 < stsc.len() && stsc[run + 1].0 <= chunk_no {
            run += 1;
        }
        let mut at = chunk_offset;
        for _ in 0..stsc[run].1 {
            let i = out.len();
            if i == sizes.len() {
                break;
            }
            out.push(usize::try_from(at).map_err(|_| status::BAD_INPUT)?);
            at = at.checked_add(sizes[i] as u64).ok_or(status::BAD_INPUT)?;
        }
    }
    if out.len() != sizes.len() {
        return Err(status::BAD_INPUT);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture(name: &str) -> Vec<u8> {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../packages/fushi_engine/test/media/image_kernels/fixtures/avif");
        std::fs::read(dir.join(name)).unwrap_or_else(|e| panic!("{name}: {e}"))
    }

    /// 解一帧，返回 (帧信息, RGBA)。
    fn next(anim: &mut AvifAnimation) -> (FrameInfo, Vec<u8>) {
        let mut out = vec![0u8; anim.width as usize * anim.height as usize * 4];
        let info = anim.next_frame(&mut out).unwrap();
        (info, out)
    }

    /// 帧中心像素。
    fn center(px: &[u8], w: u32, h: u32) -> [u8; 4] {
        let i = ((h / 2) * w + w / 2) as usize * 4;
        px[i..i + 4].try_into().unwrap()
    }

    fn close_to(got: [u8; 4], want: [u8; 3]) -> bool {
        got[3] == 255 && (0..3).all(|c| got[c].abs_diff(want[c]) <= 12)
    }

    /// sequence.avif：ffmpeg（libsvtav1）编的 64×36 四帧纯色动图，红 / 绿 / 蓝 / 白，
    /// 时长 80 / 160 / 240 / 40 ms（生成：fixtures/avif/gen_avif_fixtures.py 的 `sequence_fixture`），`-loop 0`。
    const COLORS: [[u8; 3]; 4] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]];
    const DURATIONS: [u32; 4] = [80, 160, 240, 40];

    #[test]
    fn sequence_metadata_from_sample_table() {
        let anim = AvifAnimation::open(&fixture("sequence.avif"), 0).unwrap();
        assert_eq!(anim.frame_count(), 4);
        assert_eq!((anim.width, anim.height), (64, 36));
        assert_eq!(anim.source_size(), (64, 36));
        assert!(anim.repeats());
    }

    #[test]
    fn sequence_frames_decode_in_order_with_durations_and_loop() {
        let mut anim = AvifAnimation::open(&fixture("sequence.avif"), 0).unwrap();
        // 两圈：第二圈验证末帧之后 flush 回到关键帧、颜色与时长照旧。
        for round in 0..2 {
            for (i, (color, duration)) in COLORS.iter().zip(DURATIONS).enumerate() {
                let (info, px) = next(&mut anim);
                assert_eq!(info.index, i as u32, "round {round}");
                assert_eq!(info.duration_ms, duration, "round {round} frame {i}");
                let got = center(&px, anim.width, anim.height);
                assert!(close_to(got, *color), "round {round} frame {i}: {got:?}");
            }
        }
    }

    #[test]
    fn sequence_downscales_preserving_aspect() {
        let mut anim = AvifAnimation::open(&fixture("sequence.avif"), 32).unwrap();
        assert_eq!((anim.width, anim.height), (32, 18));
        assert_eq!(anim.source_size(), (64, 36));
        let (_, px) = next(&mut anim);
        assert_eq!(px.len(), 32 * 18 * 4);
        assert!(close_to(center(&px, 32, 18), COLORS[0]));
        // 只缩不放。
        let anim = AvifAnimation::open(&fixture("sequence.avif"), 1000).unwrap();
        assert_eq!((anim.width, anim.height), (64, 36));
    }

    #[test]
    fn still_avif_opens_as_single_frame() {
        let mut anim = AvifAnimation::open(&fixture("rgba.avif"), 0).unwrap();
        assert_eq!(anim.frame_count(), 1);
        assert!(!anim.repeats());
        let (w, h, _) = {
            let (px, w, h, ch) = super::super::decode(&fixture("rgba.avif")).unwrap();
            assert_eq!(ch, 4);
            (w, h, px)
        };
        assert_eq!((anim.width, anim.height), (w, h));
        let (a, pa) = next(&mut anim);
        let (b, pb) = next(&mut anim);
        assert_eq!((a.index, a.duration_ms, b.index), (0, 0, 0));
        assert_eq!(pa, pb);
    }

    #[test]
    fn small_output_buffer_is_rejected() {
        let mut anim = AvifAnimation::open(&fixture("sequence.avif"), 0).unwrap();
        let mut out = vec![0u8; 10];
        assert_eq!(
            anim.next_frame(&mut out).err(),
            Some(status::BUFFER_TOO_SMALL)
        );
    }

    #[test]
    fn non_avif_and_truncated_sequences_fail_cleanly() {
        assert!(AvifAnimation::open(b"", 0).is_err());
        let data = fixture("sequence.avif");
        for len in 0..data.len() {
            let r = catch_unwind(|| {
                if let Ok(mut a) = AvifAnimation::open(&data[..len], 0) {
                    let mut out = vec![0u8; a.width as usize * a.height as usize * 4];
                    for _ in 0..6 {
                        let _ = a.next_frame(&mut out);
                    }
                }
            });
            assert!(r.is_ok(), "截到 {len} 字节时 panic");
        }
    }

    /// 样本字节逐个翻转：rav1d 走 Rust API，坏码流只能得到错误，不得 abort 进程。
    #[test]
    fn corrupt_samples_do_not_abort() {
        let data = fixture("sequence.avif");
        let mdat = data.windows(4).rposition(|w| w == b"mdat").unwrap() + 4;
        for at in mdat..data.len() {
            for flip in [0xa5u8, 0xff, 0x01] {
                let mut bad = data.clone();
                bad[at] ^= flip;
                if let Ok(mut a) = AvifAnimation::open(&bad, 0) {
                    let mut out = vec![0u8; a.width as usize * a.height as usize * 4];
                    for _ in 0..8 {
                        let _ = a.next_frame(&mut out);
                    }
                }
            }
        }
    }

    /// 手动基准：`FUSHI_AVIF_BENCH=<动图> cargo test --release --lib bench_avif_animation -- --ignored --nocapture`。
    #[test]
    #[ignore]
    fn bench_avif_animation() {
        let data = std::fs::read(std::env::var("FUSHI_AVIF_BENCH").unwrap()).unwrap();
        let max_width: u32 = std::env::var("FUSHI_AVIF_BENCH_WIDTH")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let t = std::time::Instant::now();
        let mut anim = AvifAnimation::open(&data, max_width).unwrap();
        println!(
            "open {}x{} -> {}x{} ({} frames): {:?}",
            anim.src_w,
            anim.src_h,
            anim.width,
            anim.height,
            anim.frame_count(),
            t.elapsed()
        );
        let mut out = vec![0u8; anim.width as usize * anim.height as usize * 4];
        let n = anim.frame_count() as usize * 2;
        let t = std::time::Instant::now();
        for _ in 0..n {
            anim.next_frame(&mut out).unwrap();
        }
        println!("{n} frames: {:?} / frame", t.elapsed() / n as u32);
    }
}
