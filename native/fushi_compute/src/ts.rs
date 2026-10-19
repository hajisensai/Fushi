//! `ffc_ts_*`：从 ffmpeg `-c copy -f mpegts` 抽出的单轨 TS 里取回字幕 PES（位图字幕抽轨产物，
//! Dart 侧 `fushi_engine/lib/media/video/bitmap_subtitle/mpegts_subtitle_demuxer.dart`）。
//!
//! 逐位复刻旧 Dart 实现：PAT → PMT → 第一条基本流 PID → 按 `payload_unit_start` 拼 PES，
//! 坏同步字节按「连续两个包都以 0x47 开头」重新找同步，33 位 PTS 环绕折回。
//!
//! **可增量**：解复用器是一个句柄，文件还在增长时每次只喂新写出的字节（从
//! [ffc_ts_demux_need_offset] 报的位置起），交出的包与「每次从头重解整个文件」逐包相同。
//! 依据：`complete = false` 的收尾在旧实现里从不改动状态（没收满的定长 PES 不交出也不丢，
//! 不定长 PES 留到下一个 PES 开始），重同步扫描对某个位置的判定只取决于该位置与其后第
//! 188 字节——都与文件后来长出的部分无关；只需记住「主循环停在哪」或「重同步扫到哪」。

use crate::{guard, status};

const TS_PACKET: usize = 188;
const TS_SYNC: u8 = 0x47;

/// 输出游标：写进调用方的缓冲区（测试里写进自有的 Vec）。容量由
/// [ffc_ts_demux_output_bound] 保证够用。
#[derive(Default)]
struct Sink {
    ptr: usize,
    cap: usize,
    len: usize,
    #[cfg(test)]
    owned: Vec<u8>,
}

impl Sink {
    fn push(&mut self, bytes: &[u8]) {
        #[cfg(test)]
        if self.ptr == 0 {
            self.owned.extend_from_slice(bytes);
            return;
        }
        assert!(
            self.len + bytes.len() <= self.cap,
            "ts output bound violated"
        );
        unsafe {
            std::ptr::copy_nonoverlapping(
                bytes.as_ptr(),
                (self.ptr as *mut u8).add(self.len),
                bytes.len(),
            );
        }
        self.len += bytes.len();
    }
}

#[derive(Default)]
pub struct TsDemuxer {
    pmt_pid: Option<u32>,
    es_pid: Option<u32>,
    /// 在拼的 PES（`pes_active` 为假时无；缓冲区复用，不逐 PES 分配）。
    pes: Vec<u8>,
    pes_active: bool,
    pes_expected: usize,
    last_pts: Option<i64>,
    pts_wrap: i64,
    /// 下一个待解析 TS 包的绝对偏移（主循环停在这里）。
    offset: u64,
    /// 正在重同步时，下一个待检查位置的绝对偏移。
    resync_from: Option<u64>,
    /// 已按 `complete = true` 收尾：之后不再接受输入。
    finished: bool,
    /// 本次 feed 交出的包，按 [ffc_ts_demux_feed] 的格式序列化进调用方给的缓冲区。
    out: Sink,
}

impl TsDemuxer {
    /// 下次 feed 的数据必须从这个绝对偏移开始。
    fn need_offset(&self) -> u64 {
        self.resync_from.unwrap_or(self.offset)
    }

    /// 喂 [data]（绝对偏移 `base` 起、到当前文件尾）；`complete` 时按文件已写完收尾。
    fn feed(&mut self, data: &[u8], base: u64, complete: bool) {
        let len = data.len() as u64;
        let end = base + len;
        let at = |abs: u64| data[(abs - base) as usize];
        loop {
            if let Some(from) = self.resync_from {
                // `_resync`：从 from 起找下一个「此处与 188 字节后都是 0x47」的位置。
                let mut i = from;
                let mut found = None;
                while i + (TS_PACKET as u64) < end {
                    if at(i) == TS_SYNC && at(i + TS_PACKET as u64) == TS_SYNC {
                        found = Some(i);
                        break;
                    }
                    i += 1;
                }
                match found {
                    Some(i) => {
                        self.resync_from = None;
                        self.offset = i;
                    }
                    None => {
                        // 没扫完的位置留到文件长出来再看（i 是第一个还判定不了的位置）。
                        self.resync_from = Some(i);
                        break;
                    }
                }
            }
            if self.offset + TS_PACKET as u64 > end {
                break;
            }
            if at(self.offset) != TS_SYNC {
                self.resync_from = Some(self.offset + 1);
                continue;
            }
            let s = (self.offset - base) as usize;
            self.feed_packet(&data[s..s + TS_PACKET]);
            self.offset += TS_PACKET as u64;
        }
        if complete {
            self.flush(true);
            self.finished = true;
        }
        // complete == false：旧实现的收尾只对定长 PES 调 `_flush(force: false)`，而收满的
        // 定长 PES 在 feed 里已经交出，所以这里无事可做，状态原样留给下次。
    }

    fn feed_packet(&mut self, ts: &[u8]) {
        let unit_start = ts[1] & 0x40 != 0;
        let pid = (((ts[1] & 0x1F) as u32) << 8) | ts[2] as u32;
        let afc = (ts[3] >> 4) & 0x3;
        let mut o = 4usize;
        if afc == 0 || afc == 2 {
            return;
        }
        if afc == 3 {
            o += 1 + ts[4] as usize;
            if o >= TS_PACKET {
                return;
            }
        }
        let payload = &ts[o..];
        if pid == 0 {
            if unit_start {
                self.read_pat(payload);
            }
            return;
        }
        if Some(pid) == self.pmt_pid {
            if unit_start {
                self.read_pmt(payload);
            }
            return;
        }
        if Some(pid) != self.es_pid {
            return;
        }
        if unit_start {
            self.flush(true);
            self.pes.clear();
            self.pes.extend_from_slice(payload);
            self.pes_active = true;
            self.pes_expected = if payload.len() >= 6 {
                ((payload[4] as usize) << 8) | payload[5] as usize
            } else {
                0
            };
        } else if self.pes_active {
            self.pes.extend_from_slice(payload);
        }
        if self.pes_expected > 0 && self.pes_active && self.pes.len() >= self.pes_expected + 6 {
            self.flush(true);
        }
    }

    fn read_pat(&mut self, p: &[u8]) {
        let Some(section) = psi_section(p) else {
            return;
        };
        let n = section.len() as i64;
        let mut i = 8i64;
        while i + 4 <= n - 4 {
            let k = i as usize;
            let program = ((section[k] as u32) << 8) | section[k + 1] as u32;
            let pid = (((section[k + 2] & 0x1F) as u32) << 8) | section[k + 3] as u32;
            if program != 0 {
                self.pmt_pid = Some(pid);
                return;
            }
            i += 4;
        }
    }

    fn read_pmt(&mut self, p: &[u8]) {
        let Some(section) = psi_section(p) else {
            return;
        };
        if section.len() < 12 {
            return;
        }
        let n = section.len() as i64;
        let program_info = ((((section[10] & 0x0F) as usize) << 8) | section[11] as usize) as i64;
        let mut i = 12 + program_info;
        while i + 5 <= n - 4 {
            let k = i as usize;
            let pid = (((section[k + 1] & 0x1F) as u32) << 8) | section[k + 2] as u32;
            let es_info =
                ((((section[k + 3] & 0x0F) as usize) << 8) | section[k + 4] as usize) as i64;
            if self.es_pid.is_none() {
                self.es_pid = Some(pid);
            }
            i += 5 + es_info;
        }
    }

    /// `_flush`：交出在拼的 PES；[force] 为假时只交长度已收满的。
    fn flush(&mut self, force: bool) {
        if !self.pes_active {
            return;
        }
        let sized = self.pes_expected > 0;
        if sized && self.pes.len() < self.pes_expected + 6 {
            if !force {
                return;
            }
            self.pes_active = false;
            return;
        }
        self.pes_active = false;
        let pes = std::mem::take(&mut self.pes);
        let body = if sized {
            &pes[..self.pes_expected + 6]
        } else {
            &pes[..]
        };
        if let Some((pts, payload)) = self.read_pes(body) {
            self.out.push(&pts.to_ne_bytes());
            self.out.push(&(payload.len() as u32).to_ne_bytes());
            self.out.push(payload);
        }
        self.pes = pes;
    }

    fn read_pes<'p>(&mut self, pes: &'p [u8]) -> Option<(i64, &'p [u8])> {
        if pes.len() < 9 || pes[0] != 0 || pes[1] != 0 || pes[2] != 1 {
            return None;
        }
        let header_length = pes[8] as usize;
        let payload_start = 9 + header_length;
        if payload_start > pes.len() {
            return None;
        }
        let flags = pes[7];
        if flags & 0x80 == 0 || header_length < 5 {
            return None;
        }
        let raw = ((((pes[9] >> 1) & 0x07) as i64) << 30)
            | ((pes[10] as i64) << 22)
            | (((pes[11] >> 1) as i64) << 15)
            | ((pes[12] as i64) << 7)
            | ((pes[13] >> 1) as i64);
        Some((self.unwrap_pts(raw), &pes[payload_start..]))
    }

    fn unwrap_pts(&mut self, raw: i64) -> i64 {
        const PERIOD: i64 = 1 << 33;
        let mut pts = raw + self.pts_wrap;
        if let Some(last) = self.last_pts {
            if last - pts > PERIOD / 2 {
                self.pts_wrap += PERIOD;
                pts += PERIOD;
            }
        }
        self.last_pts = Some(pts);
        pts
    }
}

/// PSI：pointer_field 后的一整节（只看首个 TS 包里的部分）。
fn psi_section(p: &[u8]) -> Option<&[u8]> {
    if p.is_empty() {
        return None;
    }
    let start = 1 + p[0] as usize;
    if start + 3 > p.len() {
        return None;
    }
    let length = (((p[start + 1] & 0x0F) as usize) << 8) | p[start + 2] as usize;
    let end = start + 3 + length;
    if end > p.len() {
        return None;
    }
    Some(&p[start..end])
}

/// 新建解复用器句柄（[ffc_ts_demux_free] 释放）。
#[no_mangle]
pub extern "C" fn ffc_ts_demux_new() -> *mut TsDemuxer {
    match std::panic::catch_unwind(|| Box::into_raw(Box::<TsDemuxer>::default())) {
        Ok(p) => p,
        Err(_) => std::ptr::null_mut(),
    }
}

/// 释放 [ffc_ts_demux_new] 的句柄（空指针无操作）。
///
/// # Safety
/// [handle] 是本库给出、尚未释放的句柄。
#[no_mangle]
pub unsafe extern "C" fn ffc_ts_demux_free(handle: *mut TsDemuxer) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// 下次 feed 的数据必须从这个绝对偏移开始。
///
/// # Safety
/// [handle] 是有效句柄。
#[no_mangle]
pub unsafe extern "C" fn ffc_ts_demux_need_offset(handle: *const TsDemuxer) -> u64 {
    if handle.is_null() {
        0
    } else {
        (*handle).need_offset()
    }
}

/// 喂 [len] 字节时输出缓冲区至少要多大：已拼的尾 PES + 本段字节 + 每个可能的 PES 12 字节头。
///
/// # Safety
/// [handle] 是有效句柄。
#[no_mangle]
pub unsafe extern "C" fn ffc_ts_demux_output_bound(handle: *const TsDemuxer, len: usize) -> usize {
    if handle.is_null() {
        return 0;
    }
    let d = &*handle;
    let pending = if d.pes_active { d.pes.len() } else { 0 };
    pending + len + 12 * (len / TS_PACKET + 2)
}

/// 喂一段数据：[data] 是文件从绝对偏移 [base]（必须等于 [ffc_ts_demux_need_offset]）到当前
/// 文件尾的字节。本次新交出的 PES 序列化成 `[i64 pts90k][u32 len][len 字节]…`（本机字节序）
/// 写进调用方的 [out]（容量至少 [ffc_ts_demux_output_bound]；不由 Rust 分配——整轨一次解时
/// 输出与输入同量级，新分配的缺页比解析本身还贵），`out_len` 写字节数。`complete != 0` 时按
/// 文件已写完收尾，之后句柄不再接受输入。
///
/// # Safety
/// [handle] 有效；指针按给定长度可读 / 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_ts_demux_feed(
    handle: *mut TsDemuxer,
    data: *const u8,
    len: usize,
    base: u64,
    complete: i32,
    out: *mut u8,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if handle.is_null() || out.is_null() || out_len.is_null() || (len > 0 && data.is_null()) {
            return status::NULL_ARGUMENT;
        }
        if out_cap < ffc_ts_demux_output_bound(handle, len) {
            return status::BUFFER_TOO_SMALL;
        }
        let demux = &mut *handle;
        if demux.finished || base != demux.need_offset() {
            return status::INVALID_ARGUMENT;
        }
        let bytes = if len == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(data, len)
        };
        demux.out = Sink {
            ptr: out as usize,
            cap: out_cap,
            ..Sink::default()
        };
        demux.feed(bytes, base, complete != 0);
        *out_len = demux.out.len;
        demux.out = Sink::default();
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn psi(pid: u32, section: &[u8]) -> Vec<u8> {
        let mut p = vec![0xFFu8; TS_PACKET];
        p[0] = TS_SYNC;
        p[1] = 0x40 | (pid >> 8) as u8;
        p[2] = pid as u8;
        p[3] = 0x10;
        p[4] = 0;
        p[5..5 + section.len()].copy_from_slice(section);
        p
    }

    fn stream() -> Vec<u8> {
        let pat = [
            0x00, 0xB0, 13, 0, 1, 0xC1, 0, 0, 0, 1, 0xF0, 0x00, 0, 0, 0, 0,
        ];
        let pmt = [
            0x02, 0xB0, 18, 0, 1, 0xC1, 0, 0, 0xE1, 0x00, 0xF0, 0x00, 0x06, 0xE1, 0x00, 0xF0, 0x00,
            0, 0, 0, 0,
        ];
        let mut out = psi(0, &pat);
        out.extend(psi(0x1000, &pmt));
        for k in 0..3u8 {
            let pts: i64 = 90000 * (k as i64 + 1);
            let data: Vec<u8> = (0..300u32).map(|i| (i as u8).wrapping_add(k)).collect();
            let header = [
                0x80u8,
                0x80,
                5,
                0x21 | ((pts >> 29) & 0x0E) as u8,
                (pts >> 22) as u8,
                0x01 | ((pts >> 14) & 0xFE) as u8,
                (pts >> 7) as u8,
                0x01 | ((pts << 1) & 0xFE) as u8,
            ];
            let length = header.len() + data.len();
            let mut pes = vec![0, 0, 1, 0xBD, (length >> 8) as u8, length as u8];
            pes.extend_from_slice(&header);
            pes.extend_from_slice(&data);
            let mut o = 0;
            let mut first = true;
            while o < pes.len() {
                let n = (pes.len() - o).min(184);
                let mut p = vec![0u8; TS_PACKET];
                p[0] = TS_SYNC;
                p[1] = if first { 0x41 } else { 0x01 };
                p[2] = 0x00;
                if n == 184 {
                    p[3] = 0x10;
                    p[4..].copy_from_slice(&pes[o..o + n]);
                } else {
                    let stuffing = 184 - n;
                    p[3] = 0x30;
                    p[4] = (stuffing - 1) as u8;
                    for b in &mut p[5..4 + stuffing] {
                        *b = 0xFF;
                    }
                    if stuffing > 1 {
                        p[5] = 0;
                    }
                    p[4 + stuffing..].copy_from_slice(&pes[o..o + n]);
                }
                out.extend(p);
                o += n;
                first = false;
            }
            out.extend_from_slice(&[1, 2, 3]); // 垃圾：触发重同步
        }
        out
    }

    fn parse(blob: &[u8]) -> Vec<(i64, Vec<u8>)> {
        let mut out = Vec::new();
        let mut o = 0;
        while o + 12 <= blob.len() {
            let pts = i64::from_ne_bytes(blob[o..o + 8].try_into().unwrap());
            let len = u32::from_ne_bytes(blob[o + 8..o + 12].try_into().unwrap()) as usize;
            out.push((pts, blob[o + 12..o + 12 + len].to_vec()));
            o += 12 + len;
        }
        out
    }

    fn run_full(data: &[u8], complete: bool) -> Vec<(i64, Vec<u8>)> {
        let mut d = TsDemuxer::default();
        d.feed(data, 0, complete);
        parse(&d.out.owned)
    }

    #[test]
    fn incremental_equals_full_at_every_cut() {
        let ts = stream();
        assert_eq!(run_full(&ts, true).len(), 3);
        for step in [1usize, 7, 188, 189, 500] {
            let mut d = TsDemuxer::default();
            let mut got = Vec::new();
            let mut end = 0usize;
            while end < ts.len() {
                end = (end + step).min(ts.len());
                let from = d.need_offset() as usize;
                d.feed(&ts[from..end], from as u64, false);
                got.extend(parse(&std::mem::take(&mut d.out.owned)));
                assert_eq!(got, run_full(&ts[..end], false), "step {step} end {end}");
            }
            let from = d.need_offset() as usize;
            d.feed(&ts[from..], from as u64, true);
            got.extend(parse(&std::mem::take(&mut d.out.owned)));
            assert_eq!(got, run_full(&ts, true));
        }
    }
}
