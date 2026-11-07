//! 裸 AC-3 / E-AC-3（Dolby Digital / Dolby Digital Plus）码流：lofty 不认这种无容器的
//! 基本流，音频属性从同步帧头直接读（ATSC A/52:2018 §5.4.1 / Annex E §E.1.2）。
//!
//! - AC-3（`bsid <= 8`）：恒定码率，`frmsizecod` 查码率表；时长 = 码流字节 × 8 / 码率。
//! - E-AC-3（`bsid` 11..=16）：帧长写在帧头（`frmsiz`），码率可变，只能逐帧数。一个
//!   时刻可能有多条子流（7.1 = 独立子流 0 的 5.1 + 从属子流的两声道；多节目码流还有
//!   独立子流 1..7），只数「独立子流 0」的帧，否则时长会按子流数翻倍。
//!   时长 = 帧数 × 每帧音频块数 × 256 / 采样率。
//!
//! 文件头可能有 ID3v2 标签（少数打标工具会写），跳过后要求紧接着就是同步字，并核对
//! 第二帧也对得上，伪装扩展名的文件（mp3 改名 .ac3）由此返回 `None`。

use std::io::{Read, Seek, SeekFrom};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ac3Kind {
    Ac3,
    Eac3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ac3Info {
    pub kind: Ac3Kind,
    pub sample_rate: u32,
    /// 独立子流 0 的声道数（主声道 + LFE）。7.1 的另外两声道在从属子流里，不计。
    pub channels: u32,
    pub duration_ms: i64,
    pub bitrate_kbps: i64,
}

const SYNC: [u8; 2] = [0x0B, 0x77];

/// AC-3 `frmsizecod >> 1` → 码率（kbps）。
const AC3_BITRATES: [u32; 19] = [
    32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640,
];

/// `acmod` → 主声道数（0 = 1+1 双单声道，算两声道）。
const ACMOD_CHANNELS: [u32; 8] = [2, 1, 2, 3, 3, 4, 4, 5];

/// E-AC-3 `numblkscod` → 每帧音频块数。
const EAC3_BLOCKS: [u32; 4] = [1, 2, 3, 6];

struct Bits<'a> {
    data: &'a [u8],
    pos: usize,
}

impl Bits<'_> {
    fn read(&mut self, n: usize) -> Option<u32> {
        let mut v = 0u32;
        for _ in 0..n {
            let byte = *self.data.get(self.pos / 8)?;
            let bit = (byte >> (7 - (self.pos % 8))) & 1;
            v = (v << 1) | bit as u32;
            self.pos += 1;
        }
        Some(v)
    }
}

/// 一个同步帧的帧头。
#[derive(Debug, Clone, Copy)]
struct Frame {
    kind: Ac3Kind,
    /// 帧字节数。
    size: u64,
    sample_rate: u32,
    channels: u32,
    /// 每帧 PCM 样本数。
    samples: u32,
    /// 只对 E-AC-3 有意义：0 独立、1 从属、2 由 AC-3 转来的独立流。
    strmtyp: u32,
    substreamid: u32,
    /// AC-3 的标称码率（E-AC-3 为 0）。
    ac3_kbps: u32,
}

/// 解析从同步字开始的帧头（至少 8 字节）。
fn parse_frame(h: &[u8]) -> Option<Frame> {
    if h.len() < 8 || h[0..2] != SYNC {
        return None;
    }
    let bsid = (h[5] >> 3) as u32;
    if bsid <= 8 {
        let fscod = (h[4] >> 6) as u32;
        let frmsizecod = (h[4] & 0x3F) as u32;
        if fscod == 3 || frmsizecod >= 38 {
            return None;
        }
        let kbps = AC3_BITRATES[(frmsizecod >> 1) as usize];
        let sample_rate = [48_000u32, 44_100, 32_000][fscod as usize];
        // 帧长（16 bit 字）= 1536 样本的时长 × 码率 / 16：
        //   1536 / fs × kbps·1000 / 16 = 96_000·kbps / fs
        // 48k = 2·kbps、32k = 3·kbps 整除；44.1k = 96_000/44_100 = 320/147，取整后由
        // frmsizecod 的奇数位补一个字（A/52 表 5.18：32 kbps 69 / 70 字，192 kbps
        // 417 / 418 字，640 kbps 1393 / 1394 字）。
        let words = match fscod {
            0 => 2 * kbps,
            2 => 3 * kbps,
            _ => 320 * kbps / 147 + (frmsizecod & 1),
        };
        let mut b = Bits {
            data: h,
            pos: 5 * 8,
        };
        b.read(5)?; // bsid
        b.read(3)?; // bsmod
        let acmod = b.read(3)?;
        if acmod & 1 != 0 && acmod != 1 {
            b.read(2)?; // cmixlev
        }
        if acmod & 4 != 0 {
            b.read(2)?; // surmixlev
        }
        if acmod == 2 {
            b.read(2)?; // dsurmod
        }
        let lfeon = b.read(1)?;
        return Some(Frame {
            kind: Ac3Kind::Ac3,
            size: words as u64 * 2,
            sample_rate,
            channels: ACMOD_CHANNELS[acmod as usize] + lfeon,
            samples: 1536,
            strmtyp: 0,
            substreamid: 0,
            ac3_kbps: kbps,
        });
    }
    if !(11..=16).contains(&bsid) {
        return None;
    }
    let mut b = Bits {
        data: h,
        pos: 2 * 8,
    };
    let strmtyp = b.read(2)?;
    let substreamid = b.read(3)?;
    let frmsiz = b.read(11)?;
    let fscod = b.read(2)?;
    let (sample_rate, blocks) = if fscod == 3 {
        let fscod2 = b.read(2)?;
        if fscod2 == 3 {
            return None;
        }
        ([24_000u32, 22_050, 16_000][fscod2 as usize], 6)
    } else {
        let numblkscod = b.read(2)?;
        (
            [48_000u32, 44_100, 32_000][fscod as usize],
            EAC3_BLOCKS[numblkscod as usize],
        )
    };
    let acmod = b.read(3)?;
    let lfeon = b.read(1)?;
    if strmtyp == 3 {
        return None;
    }
    Some(Frame {
        kind: Ac3Kind::Eac3,
        size: (frmsiz as u64 + 1) * 2,
        sample_rate,
        channels: ACMOD_CHANNELS[acmod as usize] + lfeon,
        samples: blocks * 256,
        strmtyp,
        substreamid,
        ac3_kbps: 0,
    })
}

/// ID3v2 标签长度（含 10 字节头；有 footer 再加 10）。没有标签返回 0。
fn id3v2_len(h: &[u8]) -> u64 {
    if h.len() < 10 || &h[0..3] != b"ID3" {
        return 0;
    }
    let syncsafe = h[6..10]
        .iter()
        .fold(0u64, |acc, &b| (acc << 7) | (b & 0x7F) as u64);
    let footer = if h[5] & 0x10 != 0 { 10 } else { 0 };
    10 + syncsafe + footer
}

/// E-AC-3 逐帧数时的顺序读游标：开头 seek 一次，之后只做 [`SeqHeaders::CHUNK`] 大小的
/// 顺序读，从缓冲区里取每帧的 8 字节帧头。
///
/// 不能每帧 `seek(Start(pos))` 再读 8 字节：std `BufReader` 每次绝对 seek 都会丢弃缓冲、
/// 下一次读重新填 8 KiB，2 小时 640 kbps 的 5.1 码流约 22.5 万帧，就是 22.5 万次 seek +
/// read 系统调用、读入约 3 倍文件大小，NAS / SMB 来源首次扫描会明显变慢。这里每个字节
/// 只读一次，系统调用数 ≈ 文件大小 / CHUNK。
struct SeqHeaders<'a, R> {
    r: &'a mut R,
    buf: Vec<u8>,
    /// `buf[0]` 在文件里的偏移。
    base: u64,
    eof: bool,
}

impl<'a, R: Read + Seek> SeqHeaders<'a, R> {
    const CHUNK: usize = 256 * 1024;

    fn new(r: &'a mut R, start: u64) -> std::io::Result<Self> {
        r.seek(SeekFrom::Start(start))?;
        Ok(Self {
            r,
            buf: Vec::with_capacity(Self::CHUNK + 8),
            base: start,
            eof: false,
        })
    }

    /// 文件偏移 `pos` 处的 8 字节。`pos` 只能单调不减（且不小于起点）；不足 8 字节
    /// （到文件尾）返回 `Ok(None)`。
    fn header(&mut self, pos: u64) -> std::io::Result<Option<[u8; 8]>> {
        debug_assert!(pos >= self.base);
        loop {
            let idx = usize::try_from(pos - self.base).unwrap_or(usize::MAX);
            if let Some(h) = self.buf.get(idx..idx.saturating_add(8)) {
                let mut out = [0u8; 8];
                out.copy_from_slice(h);
                return Ok(Some(out));
            }
            // 缓冲里不够：丢掉 pos 之前已走过的字节，再顺序读一块。只在补块时搬移，
            // 不是每帧一次。
            let consumed = idx.min(self.buf.len());
            self.buf.drain(..consumed);
            self.base += consumed as u64;
            if self.eof {
                return Ok(None);
            }
            let old = self.buf.len();
            self.buf.resize(old + Self::CHUNK, 0);
            let n = loop {
                match self.r.read(&mut self.buf[old..]) {
                    Ok(n) => break n,
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                }
            };
            self.buf.truncate(old + n);
            if n == 0 {
                self.eof = true;
            }
        }
    }
}

fn read_at<R: Read + Seek>(r: &mut R, pos: u64, buf: &mut [u8]) -> Option<usize> {
    r.seek(SeekFrom::Start(pos)).ok()?;
    let mut n = 0;
    while n < buf.len() {
        match r.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(_) => return None,
        }
    }
    Some(n)
}

/// 读码流属性。不是 AC-3 / E-AC-3（同步字 / 帧头不对、第二帧对不上）返回 `None`。
/// `len` 是整个文件的字节数。
pub fn probe<R: Read + Seek>(r: &mut R, len: u64) -> Option<Ac3Info> {
    let mut head = [0u8; 10];
    read_at(r, 0, &mut head)?;
    let start = id3v2_len(&head);
    let mut h = [0u8; 8];
    if read_at(r, start, &mut h)? < 8 {
        return None;
    }
    let first = parse_frame(&h)?;
    // 第二帧也得是同一种码流（文件只有一帧时不强求）。
    let second_at = start + first.size;
    if second_at + 8 <= len {
        read_at(r, second_at, &mut h)?;
        if parse_frame(&h).map(|f| f.kind) != Some(first.kind) {
            return None;
        }
    }
    let stream_bytes = len.saturating_sub(start);
    match first.kind {
        Ac3Kind::Ac3 => {
            let kbps = first.ac3_kbps as u64;
            Some(Ac3Info {
                kind: Ac3Kind::Ac3,
                sample_rate: first.sample_rate,
                channels: first.channels,
                duration_ms: (stream_bytes * 8 / kbps) as i64,
                bitrate_kbps: kbps as i64,
            })
        }
        Ac3Kind::Eac3 => {
            let mut pos = start;
            let mut samples: u64 = 0;
            let mut main: Option<Frame> = None;
            let mut frames = SeqHeaders::new(r, start).ok()?;
            while pos + 8 <= len {
                let Some(h) = frames.header(pos).ok()? else {
                    break;
                };
                // 截断 / 坏帧：到此为止，按已数到的完整帧算。
                let Some(f) = parse_frame(&h).filter(|f| f.kind == Ac3Kind::Eac3) else {
                    break;
                };
                if pos + f.size > len {
                    break;
                }
                if f.strmtyp != 1 && f.substreamid == 0 {
                    samples += f.samples as u64;
                    main.get_or_insert(f);
                }
                pos += f.size;
            }
            let main = main?;
            let duration_ms = (samples * 1000 / main.sample_rate as u64) as i64;
            if duration_ms <= 0 {
                return None;
            }
            Some(Ac3Info {
                kind: Ac3Kind::Eac3,
                sample_rate: main.sample_rate,
                channels: main.channels,
                duration_ms,
                bitrate_kbps: ((pos - start) * 8 / duration_ms as u64) as i64,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// 一个 AC-3 帧（48 kHz、frmsizecod 给定），帧体填零。
    fn ac3_frame(frmsizecod: u8, acmod: u8, lfeon: bool) -> Vec<u8> {
        let kbps = AC3_BITRATES[(frmsizecod >> 1) as usize];
        let mut f = vec![0u8; (kbps * 4) as usize];
        f[0] = 0x0B;
        f[1] = 0x77;
        f[4] = frmsizecod; // fscod = 0
        f[5] = 8 << 3; // bsid 8, bsmod 0
        // 第 6 字节起：acmod(3) [cmixlev(2)] [surmixlev(2)] [dsurmod(2)] lfeon(1)
        let mut bits: Vec<u8> = (0..3).rev().map(|i| (acmod >> i) & 1).collect();
        if acmod & 1 != 0 && acmod != 1 {
            bits.extend([0, 0]);
        }
        if acmod & 4 != 0 {
            bits.extend([0, 0]);
        }
        if acmod == 2 {
            bits.extend([1, 0]);
        }
        bits.push(lfeon as u8);
        for (i, bit) in bits.iter().enumerate() {
            f[6 + i / 8] |= bit << (7 - i % 8);
        }
        f
    }

    /// 一个 E-AC-3 帧（48 kHz、6 块 = 1536 样本），帧长 `bytes`（偶数）。
    fn eac3_frame(strmtyp: u8, substreamid: u8, bytes: usize, acmod: u8, lfeon: bool) -> Vec<u8> {
        let mut f = vec![0u8; bytes];
        let frmsiz = (bytes / 2 - 1) as u16;
        f[0] = 0x0B;
        f[1] = 0x77;
        let w: u16 = ((strmtyp as u16) << 14) | ((substreamid as u16) << 11) | frmsiz;
        f[2..4].copy_from_slice(&w.to_be_bytes());
        // fscod 0, numblkscod 3, acmod, lfeon
        f[4] = (3 << 4) | (acmod << 1) | lfeon as u8;
        f[5] = 16 << 3;
        f
    }

    #[test]
    fn ac3_cbr_duration_from_bitrate_table() {
        // 192 kbps 48 kHz：每帧 768 字节 = 32 ms。100 帧 = 3.2 s。
        let frame = ac3_frame(20, 7, true);
        assert_eq!(frame.len(), 768);
        let data: Vec<u8> = frame.repeat(100);
        let info = probe(&mut Cursor::new(&data), data.len() as u64).unwrap();
        assert_eq!(info.kind, Ac3Kind::Ac3);
        assert_eq!(info.sample_rate, 48_000);
        assert_eq!(info.channels, 6);
        assert_eq!(info.bitrate_kbps, 192);
        assert_eq!(info.duration_ms, 3200);
    }

    #[test]
    fn ac3_stereo_reads_dsurmod_before_lfeon() {
        // dsurmod = 0b10：读错位置会把那个 1 当成 lfeon，报 3 声道。
        let data = ac3_frame(20, 2, false).repeat(2);
        let info = probe(&mut Cursor::new(&data), data.len() as u64).unwrap();
        assert_eq!(info.channels, 2);
    }

    /// 一个 44.1 kHz AC-3 帧，帧长 `words` 由调用方按 A/52 表 5.18 给（不从实现的公式推）。
    fn ac3_44k_frame(frmsizecod: u8, words: usize) -> Vec<u8> {
        let mut f = ac3_frame(frmsizecod, 2, false);
        f.resize(words * 2, 0);
        f[4] = (1 << 6) | frmsizecod;
        f
    }

    #[test]
    fn ac3_44k_frame_size_matches_a52_table() {
        // A/52 表 5.18 的 44.1 kHz 一栏（偶 / 奇 frmsizecod），全部 19 档码率。
        const WORDS_44K: [u32; 19] = [
            69, 87, 104, 121, 139, 174, 208, 243, 278, 348, 417, 487, 557, 696, 835, 975, 1114,
            1253, 1393,
        ];
        for (i, &words) in WORDS_44K.iter().enumerate() {
            for odd in 0..2u8 {
                let code = (i as u8) * 2 + odd;
                let f = parse_frame(&ac3_44k_frame(code, 8)).unwrap();
                assert_eq!(f.size, (words + odd as u32) as u64 * 2, "frmsizecod {code}");
                assert_eq!(f.sample_rate, 44_100);
            }
        }
    }

    #[test]
    fn ac3_44k_stream_with_padding_frames_probes() {
        // 32 kbps：69 字的帧与补字的 70 字帧交替（编码器按 44.1k 的余数插补字帧）。
        // probe 按帧长找第二帧的同步字，帧长算错就整个文件被拒（两库都进不去）。
        let mut data = Vec::new();
        for i in 0..40 {
            data.extend(if i % 2 == 0 {
                ac3_44k_frame(0, 69)
            } else {
                ac3_44k_frame(1, 70)
            });
        }
        let info = probe(&mut Cursor::new(&data), data.len() as u64).unwrap();
        assert_eq!(info.kind, Ac3Kind::Ac3);
        assert_eq!(info.sample_rate, 44_100);
        assert_eq!(info.bitrate_kbps, 32);
        // 20·(138 + 140) = 5560 字节 × 8 / 32 kbps = 1390 ms（40 帧 × 1536 / 44.1k ≈ 1393 ms）。
        assert_eq!(info.duration_ms, 1390);
    }

    /// 统计 seek 次数与读入字节数的读者。
    struct Counting<R> {
        inner: R,
        seeks: usize,
        bytes_read: u64,
    }

    impl<R: Read> Read for Counting<R> {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            let n = self.inner.read(buf)?;
            self.bytes_read += n as u64;
            Ok(n)
        }
    }

    impl<R: Seek> Seek for Counting<R> {
        fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
            self.seeks += 1;
            self.inner.seek(pos)
        }
    }

    #[test]
    fn eac3_frame_walk_reads_sequentially() {
        // 5000 帧 ≈ 2.5 MB：逐帧数时长不能每帧 seek 一次（BufReader 每次绝对 seek 都丢
        // 缓冲重填），整段只该顺序读一遍。
        let data = eac3_frame(0, 0, 512, 2, false).repeat(5000);
        let mut r = Counting {
            inner: Cursor::new(&data),
            seeks: 0,
            bytes_read: 0,
        };
        let info = probe(&mut r, data.len() as u64).unwrap();
        assert_eq!(info.duration_ms, 5000 * 32);
        // probe 头部：读文件头 + 第一帧 + 第二帧 3 次，逐帧扫描起点 1 次。
        assert!(r.seeks <= 4, "seeks = {}", r.seeks);
        // 每个字节只读一次（加上帧头探测的几十字节）。
        assert!(
            r.bytes_read <= data.len() as u64 + 64,
            "bytes_read = {} for {} byte file",
            r.bytes_read,
            data.len()
        );
    }

    #[test]
    fn ac3_skips_leading_id3v2() {
        let mut data = b"ID3\x04\x00\x00\x00\x00\x00\x05".to_vec();
        data.extend([0u8; 5]);
        data.extend(ac3_frame(20, 7, true).repeat(10));
        let info = probe(&mut Cursor::new(&data), data.len() as u64).unwrap();
        assert_eq!(info.duration_ms, 320);
    }

    #[test]
    fn eac3_counts_only_independent_substream_zero() {
        // 7.1：每个时刻 = 独立子流 0（5.1）+ 从属子流 0（另两声道）。50 个时刻 = 1.6 s。
        let mut data = Vec::new();
        for _ in 0..50 {
            data.extend(eac3_frame(0, 0, 1000, 7, true));
            data.extend(eac3_frame(1, 0, 400, 2, false));
        }
        let info = probe(&mut Cursor::new(&data), data.len() as u64).unwrap();
        assert_eq!(info.kind, Ac3Kind::Eac3);
        assert_eq!(info.sample_rate, 48_000);
        assert_eq!(info.channels, 6);
        assert_eq!(info.duration_ms, 1600);
        // 1400 字节 / 32 ms = 350 kbps。
        assert_eq!(info.bitrate_kbps, 350);
    }

    #[test]
    fn eac3_truncated_tail_counts_complete_frames_only() {
        let mut data = eac3_frame(0, 0, 1000, 2, false).repeat(10);
        // 半个帧：帧头完整、帧体不全。
        data.extend(&eac3_frame(0, 0, 1000, 2, false)[..500]);
        let info = probe(&mut Cursor::new(&data), data.len() as u64).unwrap();
        assert_eq!(info.duration_ms, 320);
    }

    #[test]
    fn rejects_non_ac3_without_panicking() {
        for data in [
            Vec::new(),
            b"\x0B\x77".to_vec(),
            b"fLaC\0\0\0\0\0\0\0\0".to_vec(),
            // MP3 帧头改名 .ac3。
            vec![0xFF, 0xFB, 0x90, 0x64, 0, 0, 0, 0, 0, 0],
            // 第一帧对、第二帧不是同步字。
            [ac3_frame(20, 7, true), vec![0xAA; 800]].concat(),
            // bsid 10 不是任何一种。
            {
                let mut f = ac3_frame(20, 7, true);
                f[5] = 10 << 3;
                f.repeat(2)
            },
            // ID3 长度指到文件外。
            b"ID3\x04\x00\x00\x7F\x7F\x7F\x7F".to_vec(),
        ] {
            assert_eq!(probe(&mut Cursor::new(&data), data.len() as u64), None);
        }
    }
}
