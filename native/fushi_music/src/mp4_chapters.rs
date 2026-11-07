//! MP4 / M4B 章节（lofty 不读章节）。两种写法都认：
//!
//! 1. **QuickTime 章节轨**（Apple / iTunes / Audible / ffmpeg 都写）：某条轨的
//!    `trak/tref/chap` 指向一条文本轨，文本轨的每个样本是一章——样本起点（`stts`
//!    累加，单位是**这条文本轨** `mdhd` 的 timescale，不是 `mvhd` 的）是章节起点，样本
//!    内容是 `u16 长度 + 文本`（文本可带 UTF-16 BOM；长度之后可能还跟 `encd` 等原子，
//!    按长度截断即自然忽略）。样本在文件里的位置由 `stsc` + `stsz` + `stco` / `co64`
//!    （超过 4 GiB 或 mdat 在前的长有声书用 64 位偏移）算出。
//! 2. **Nero `chpl`**（`moov/udta/chpl`）：起点单位 100 ns，标题 `u8 长度 + UTF-8`。
//!
//! 两者都有时用章节轨（Apple 规范写法，`chpl` 只是 Nero 的私有扩展）。只读 `moov`（通常
//! 几百 KB，封顶 64 MiB）和章节样本本身，不碰音频数据。

use std::io::{Read, Seek, SeekFrom};

use crate::cue::decode_text;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mp4Chapter {
    pub start_ms: i64,
    pub title: Option<String>,
}

const MAX_MOOV: u64 = 64 << 20;
const MAX_CHAPTERS: usize = 10_000;

/// 一个盒子：类型 + 内容在父缓冲区里的范围。
struct Atom<'a> {
    kind: [u8; 4],
    body: &'a [u8],
}

fn be_u32(b: &[u8], o: usize) -> Option<u32> {
    Some(u32::from_be_bytes(b.get(o..o + 4)?.try_into().ok()?))
}

fn be_u64(b: &[u8], o: usize) -> Option<u64> {
    Some(u64::from_be_bytes(b.get(o..o + 8)?.try_into().ok()?))
}

/// 内存里一段盒子序列的子盒子。坏的尺寸到此为止（不越界、不 panic）。
fn children(buf: &[u8]) -> Vec<Atom<'_>> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    while pos + 8 <= buf.len() {
        let Some(size32) = be_u32(buf, pos) else {
            break;
        };
        let kind: [u8; 4] = buf[pos + 4..pos + 8].try_into().unwrap();
        let (header, size) = match size32 {
            0 => (8usize, (buf.len() - pos) as u64),
            1 => match be_u64(buf, pos + 8) {
                Some(s) => (16, s),
                None => break,
            },
            s => (8, s as u64),
        };
        if size < header as u64 || pos as u64 + size > buf.len() as u64 {
            break;
        }
        let end = pos + size as usize;
        out.push(Atom {
            kind,
            body: &buf[pos + header..end],
        });
        pos = end;
    }
    out
}

fn child<'a>(buf: &'a [u8], kind: &[u8; 4]) -> Option<&'a [u8]> {
    children(buf)
        .into_iter()
        .find(|a| &a.kind == kind)
        .map(|a| a.body)
}

fn path<'a>(buf: &'a [u8], kinds: &[&[u8; 4]]) -> Option<&'a [u8]> {
    kinds.iter().try_fold(buf, |b, k| child(b, k))
}

/// 顶层盒子里找 `moov`，读进内存。
fn read_moov<R: Read + Seek>(r: &mut R, len: u64) -> Option<Vec<u8>> {
    let mut pos = 0u64;
    let mut h = [0u8; 16];
    while pos + 8 <= len {
        r.seek(SeekFrom::Start(pos)).ok()?;
        r.read_exact(&mut h[..8]).ok()?;
        let size32 = u32::from_be_bytes(h[0..4].try_into().unwrap());
        let (header, size) = match size32 {
            0 => (8u64, len - pos),
            1 => {
                r.read_exact(&mut h[8..16]).ok()?;
                (16, u64::from_be_bytes(h[8..16].try_into().unwrap()))
            }
            s => (8, s as u64),
        };
        if size < header || pos + size > len {
            return None;
        }
        if &h[4..8] == b"moov" {
            let body = size - header;
            if body > MAX_MOOV {
                return None;
            }
            let mut buf = vec![0u8; body as usize];
            r.read_exact(&mut buf).ok()?;
            return Some(buf);
        }
        pos += size;
    }
    None
}

/// 全盒子（version + flags）的 version 与正文。
fn full_box(body: &[u8]) -> Option<(u8, &[u8])> {
    Some((*body.first()?, body.get(4..)?))
}

fn track_id(trak: &[u8]) -> Option<u32> {
    let (version, b) = full_box(path(trak, &[b"tkhd"])?)?;
    // v0: creation(4) modification(4) track_id(4)；v1: creation(8) modification(8) track_id(4)
    be_u32(b, if version == 1 { 16 } else { 8 })
}

fn mdhd_timescale(trak: &[u8]) -> Option<u32> {
    let (version, b) = full_box(path(trak, &[b"mdia", b"mdhd"])?)?;
    be_u32(b, if version == 1 { 16 } else { 8 }).filter(|t| *t > 0)
}

/// `stts` 展开成每个样本的起点（timescale 单位）。
fn sample_starts(stbl: &[u8]) -> Option<Vec<u64>> {
    let (_, b) = full_box(child(stbl, b"stts")?)?;
    let n = be_u32(b, 0)? as usize;
    let mut out = Vec::new();
    let mut t = 0u64;
    for i in 0..n {
        let count = be_u32(b, 4 + i * 8)? as usize;
        let delta = be_u32(b, 8 + i * 8)? as u64;
        for _ in 0..count {
            if out.len() >= MAX_CHAPTERS {
                return Some(out);
            }
            out.push(t);
            t += delta;
        }
    }
    Some(out)
}

/// 每个样本在文件里的（偏移, 字节数）。
fn sample_locations(stbl: &[u8], count: usize) -> Option<Vec<(u64, u32)>> {
    let (_, stsz) = full_box(child(stbl, b"stsz")?)?;
    let fixed = be_u32(stsz, 0)?;
    let sizes: Vec<u32> = if fixed != 0 {
        vec![fixed; count]
    } else {
        let n = (be_u32(stsz, 4)? as usize).min(count);
        (0..n)
            .map(|i| be_u32(stsz, 8 + i * 4))
            .collect::<Option<_>>()?
    };
    let offsets: Vec<u64> = if let Some(stco) = child(stbl, b"stco") {
        let (_, b) = full_box(stco)?;
        let n = be_u32(b, 0)? as usize;
        (0..n.min(MAX_CHAPTERS))
            .map(|i| be_u32(b, 4 + i * 4).map(u64::from))
            .collect::<Option<_>>()?
    } else {
        let (_, b) = full_box(child(stbl, b"co64")?)?;
        let n = be_u32(b, 0)? as usize;
        (0..n.min(MAX_CHAPTERS))
            .map(|i| be_u64(b, 4 + i * 8))
            .collect::<Option<_>>()?
    };
    // stsc：(first_chunk 1 起, samples_per_chunk, desc)，适用到下一条的 first_chunk 之前。
    let (_, stsc) = full_box(child(stbl, b"stsc")?)?;
    let runs = be_u32(stsc, 0)? as usize;
    let mut table: Vec<(usize, usize)> = Vec::new();
    for i in 0..runs {
        let first = be_u32(stsc, 4 + i * 12)? as usize;
        let per = be_u32(stsc, 8 + i * 12)? as usize;
        if first == 0 {
            return None;
        }
        table.push((first, per));
    }
    let mut out = Vec::with_capacity(sizes.len());
    let mut sample = 0usize;
    for (chunk_idx, &chunk_off) in offsets.iter().enumerate() {
        let chunk_no = chunk_idx + 1;
        let per = table
            .iter()
            .rev()
            .find(|(first, _)| *first <= chunk_no)
            .map(|(_, per)| *per)?;
        let mut off = chunk_off;
        for _ in 0..per {
            let Some(&size) = sizes.get(sample) else {
                return Some(out);
            };
            out.push((off, size));
            off += size as u64;
            sample += 1;
        }
    }
    Some(out)
}

/// 一个文本样本 → 标题。`u16` 长度后的文本：带 BOM 按 UTF-16，否则 UTF-8（容错退回
/// CUE 同款的多编码探测）。
fn sample_title(data: &[u8]) -> Option<String> {
    let n = u16::from_be_bytes(data.get(0..2)?.try_into().ok()?) as usize;
    let text = data.get(2..2 + n)?;
    let s = decode_text(text);
    let t = s.trim().trim_matches('\0').trim();
    (!t.is_empty()).then(|| t.to_owned())
}

/// QuickTime 章节轨。
fn chapter_track<R: Read + Seek>(r: &mut R, moov: &[u8], len: u64) -> Option<Vec<Mp4Chapter>> {
    let traks: Vec<&[u8]> = children(moov)
        .into_iter()
        .filter(|a| &a.kind == b"trak")
        .map(|a| a.body)
        .collect();
    let chap_id = traks.iter().find_map(|t| {
        let chap = path(t, &[b"tref", b"chap"])?;
        be_u32(chap, 0).filter(|id| *id != 0)
    })?;
    let trak = traks.iter().find(|t| track_id(t) == Some(chap_id))?;
    let timescale = mdhd_timescale(trak)? as u64;
    let stbl = path(trak, &[b"mdia", b"minf", b"stbl"])?;
    let starts = sample_starts(stbl)?;
    let locs = sample_locations(stbl, starts.len())?;
    let mut out = Vec::new();
    for (i, &start) in starts.iter().enumerate() {
        let title = match locs.get(i) {
            Some(&(off, size)) if size >= 2 && off + size as u64 <= len => {
                let mut buf = vec![0u8; size.min(64 << 10) as usize];
                r.seek(SeekFrom::Start(off)).ok()?;
                r.read_exact(&mut buf).ok()?;
                sample_title(&buf)
            }
            _ => None,
        };
        out.push(Mp4Chapter {
            start_ms: (start as u128 * 1000 / timescale as u128) as i64,
            title,
        });
    }
    Some(out)
}

/// Nero `chpl`。
fn chpl(moov: &[u8]) -> Option<Vec<Mp4Chapter>> {
    let (version, b) = full_box(path(moov, &[b"udta", b"chpl"])?)?;
    // version 1 在章节数前多 4 字节保留字（ffmpeg mov_read_chpl 同款）。
    let mut pos = if version == 1 { 4 } else { 0 };
    let n = *b.get(pos)? as usize;
    pos += 1;
    let mut out = Vec::new();
    for _ in 0..n {
        let start = be_u64(b, pos)?;
        let tlen = *b.get(pos + 8)? as usize;
        let text = b.get(pos + 9..pos + 9 + tlen)?;
        pos += 9 + tlen;
        let s = decode_text(text);
        let t = s.trim();
        out.push(Mp4Chapter {
            start_ms: (start / 10_000) as i64,
            title: (!t.is_empty()).then(|| t.to_owned()),
        });
    }
    Some(out)
}

/// 读章节，按起点升序、同起点去重。没有章节（或不是 MP4）返回空。
pub fn read_chapters<R: Read + Seek>(r: &mut R, len: u64) -> Vec<Mp4Chapter> {
    let Some(moov) = read_moov(r, len) else {
        return Vec::new();
    };
    let mut chapters = chapter_track(r, &moov, len)
        .filter(|c| !c.is_empty())
        .or_else(|| chpl(&moov))
        .unwrap_or_default();
    chapters.sort_by_key(|c| c.start_ms);
    chapters.dedup_by_key(|c| c.start_ms);
    chapters
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn atom(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut v = ((body.len() + 8) as u32).to_be_bytes().to_vec();
        v.extend_from_slice(kind);
        v.extend_from_slice(body);
        v
    }

    fn full(kind: &[u8; 4], version: u8, body: &[u8]) -> Vec<u8> {
        let mut b = vec![version, 0, 0, 0];
        b.extend_from_slice(body);
        atom(kind, &b)
    }

    fn tkhd(id: u32) -> Vec<u8> {
        let mut b = vec![0u8; 8];
        b.extend(id.to_be_bytes());
        b.extend([0u8; 72]);
        full(b"tkhd", 0, &b)
    }

    fn mdhd_v1(timescale: u32) -> Vec<u8> {
        let mut b = vec![0u8; 16];
        b.extend(timescale.to_be_bytes());
        b.extend([0u8; 12]);
        full(b"mdhd", 1, &b)
    }

    /// 文本样本：u16 长度 + 文本 + 尾随 encd 原子。
    fn text_sample(text: &[u8]) -> Vec<u8> {
        let mut s = (text.len() as u16).to_be_bytes().to_vec();
        s.extend_from_slice(text);
        s.extend(atom(b"encd", &256u32.to_be_bytes()));
        s
    }

    /// 拼一个带章节轨的 MP4：mdat 在前（样本偏移 > 0），moov 在后。
    /// `durations` 按 `timescale` 计；`co64` 选 64 位块偏移。
    fn build(titles: &[Vec<u8>], durations: &[u32], timescale: u32, co64: bool) -> Vec<u8> {
        let samples: Vec<Vec<u8>> = titles.iter().map(|t| text_sample(t)).collect();
        let mut mdat_body = Vec::new();
        let mut offsets = Vec::new();
        let ftyp = atom(b"ftyp", b"M4B \0\0\0\0");
        for s in &samples {
            offsets.push((ftyp.len() + 8 + mdat_body.len()) as u64);
            mdat_body.extend(s);
        }
        let mut stts = (durations.len() as u32).to_be_bytes().to_vec();
        for d in durations {
            stts.extend(1u32.to_be_bytes());
            stts.extend(d.to_be_bytes());
        }
        let mut stsz = 0u32.to_be_bytes().to_vec();
        stsz.extend((samples.len() as u32).to_be_bytes());
        for s in &samples {
            stsz.extend((s.len() as u32).to_be_bytes());
        }
        // 每块一个样本。
        let mut stsc = 1u32.to_be_bytes().to_vec();
        stsc.extend([1u32, 1, 1].iter().flat_map(|v| v.to_be_bytes()));
        let chunk_box = if co64 {
            let mut b = (offsets.len() as u32).to_be_bytes().to_vec();
            for o in &offsets {
                b.extend(o.to_be_bytes());
            }
            full(b"co64", 0, &b)
        } else {
            let mut b = (offsets.len() as u32).to_be_bytes().to_vec();
            for o in &offsets {
                b.extend((*o as u32).to_be_bytes());
            }
            full(b"stco", 0, &b)
        };
        let stbl = atom(
            b"stbl",
            &[
                full(b"stts", 0, &stts),
                full(b"stsc", 0, &stsc),
                full(b"stsz", 0, &stsz),
                chunk_box,
            ]
            .concat(),
        );
        let text_trak = atom(
            b"trak",
            &[
                tkhd(2),
                atom(
                    b"mdia",
                    &[mdhd_v1(timescale), atom(b"minf", &stbl)].concat(),
                ),
            ]
            .concat(),
        );
        let audio_trak = atom(
            b"trak",
            &[tkhd(1), atom(b"tref", &atom(b"chap", &2u32.to_be_bytes()))].concat(),
        );
        // mvhd timescale 故意与文本轨不同：用错 timescale 章节会错位。
        let mut mvhd = vec![0u8; 8];
        mvhd.extend(1000u32.to_be_bytes());
        mvhd.extend([0u8; 84]);
        let moov = atom(
            b"moov",
            &[full(b"mvhd", 0, &mvhd), audio_trak, text_trak].concat(),
        );
        [ftyp, atom(b"mdat", &mdat_body), moov].concat()
    }

    fn read(data: &[u8]) -> Vec<Mp4Chapter> {
        read_chapters(&mut Cursor::new(data), data.len() as u64)
    }

    #[test]
    fn chapter_track_uses_text_track_timescale_and_ignores_encd() {
        let data = build(
            &[
                b"Prologue".to_vec(),
                b"Part One".to_vec(),
                b"Part Two".to_vec(),
            ],
            &[44_100 * 2, 44_100 * 3, 44_100],
            44_100,
            false,
        );
        assert_eq!(
            read(&data),
            vec![
                Mp4Chapter {
                    start_ms: 0,
                    title: Some("Prologue".into())
                },
                Mp4Chapter {
                    start_ms: 2000,
                    title: Some("Part One".into())
                },
                Mp4Chapter {
                    start_ms: 5000,
                    title: Some("Part Two".into())
                },
            ]
        );
    }

    #[test]
    fn chapter_track_with_co64_and_utf16_bom_titles() {
        let utf16 = |s: &str| -> Vec<u8> {
            let mut v = vec![0xFE, 0xFF];
            for u in s.encode_utf16() {
                v.extend(u.to_be_bytes());
            }
            v
        };
        let data = build(&[utf16("第一章"), utf16("第二章")], &[600, 600], 600, true);
        let c = read(&data);
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].title.as_deref(), Some("第一章"));
        assert_eq!(c[1].start_ms, 1000);
        assert_eq!(c[1].title.as_deref(), Some("第二章"));
    }

    fn chpl_file(version: u8, chapters: &[(u64, &str)]) -> Vec<u8> {
        let mut b = Vec::new();
        if version == 1 {
            b.extend([0u8; 4]);
        }
        b.push(chapters.len() as u8);
        for (start, title) in chapters {
            b.extend(start.to_be_bytes());
            b.push(title.len() as u8);
            b.extend(title.as_bytes());
        }
        let moov = atom(b"moov", &atom(b"udta", &full(b"chpl", version, &b)));
        [atom(b"ftyp", b"M4A \0\0\0\0"), moov].concat()
    }

    #[test]
    fn nero_chpl_in_100ns_units() {
        let data = chpl_file(1, &[(0, "A"), (15_000_000, "B"), (40_000_000, "")]);
        assert_eq!(
            read(&data),
            vec![
                Mp4Chapter {
                    start_ms: 0,
                    title: Some("A".into())
                },
                Mp4Chapter {
                    start_ms: 1500,
                    title: Some("B".into())
                },
                Mp4Chapter {
                    start_ms: 4000,
                    title: None
                },
            ]
        );
        assert_eq!(read(&chpl_file(0, &[(0, "X"), (10_000_000, "Y")])).len(), 2);
    }

    /// 真实产物（generate.sh 用 ffmpeg ipod muxer 生成，两种写法都有）：两条路径各自读出
    /// 同样的三章。
    #[test]
    fn ffmpeg_m4b_fixture_has_both_chapter_forms() {
        let data = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/library/Formats/chapters.m4b"
        ))
        .unwrap();
        let len = data.len() as u64;
        let moov = read_moov(&mut Cursor::new(&data), len).unwrap();
        let expected = vec![
            Mp4Chapter {
                start_ms: 0,
                title: Some("Opening".into()),
            },
            Mp4Chapter {
                start_ms: 1000,
                title: Some("第二章".into()),
            },
            Mp4Chapter {
                start_ms: 2500,
                title: Some("Ending".into()),
            },
        ];
        assert_eq!(
            chapter_track(&mut Cursor::new(&data), &moov, len).unwrap(),
            expected
        );
        assert_eq!(chpl(&moov).unwrap(), expected);
    }

    #[test]
    fn no_chapters_and_garbage_yield_empty() {
        assert!(read(&atom(b"moov", &atom(b"udta", b""))).is_empty());
        assert!(read(b"").is_empty());
        assert!(read(b"fLaC\0\0\0\x22").is_empty());
        // 尺寸越界的盒子。
        let mut bad = atom(b"moov", &atom(b"trak", b"xxxx"));
        bad[3] = 0xFF;
        assert!(read(&bad).is_empty());
        // chpl 声明 5 章、只有 1 章的数据：整表丢弃，不给半截。
        let mut b = vec![0u8; 4];
        b.push(5);
        b.extend(0u64.to_be_bytes());
        b.push(0);
        let moov = atom(b"moov", &atom(b"udta", &full(b"chpl", 1, &b)));
        assert!(read(&moov).is_empty());
    }
}
