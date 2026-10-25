//! 歌词 C ABI 的样本 golden 测试：`tests/fixtures/lyrics/samples/` 每种格式至少一个样本（由同目录
//! `generate.py` 生成并入库），经 `ffm_lyrics_parse` 解析、按线格式解码后转成稳定文本，与
//! `golden/<样本>.golden` 逐行比对。`FUSHI_MUSIC_UPDATE_GOLDEN=1` 时重写 golden。
//!
//! 另有：编码探测回归向量（旧 Dart 实现生成）、内嵌歌词（lofty 写进样本音频副本再经 FFI 读回）、
//! 合并 / 注音 / 导出三个 FFI 的往返。

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use fushi_music::lyrics::model::*;
use fushi_music::lyrics::{ffi, text, wire};
use fushi_music::{ffm_free_bytes, status};

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/lyrics")
}

fn take(ptr: *mut u8, len: usize) -> Vec<u8> {
    if ptr.is_null() {
        return Vec::new();
    }
    let v = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
    ffm_free_bytes(ptr, len);
    v
}

fn ffi_parse(bytes: &[u8], hint: &str, duration: i64) -> Result<Timeline, String> {
    let mut out: *mut u8 = std::ptr::null_mut();
    let mut len = 0usize;
    let code = unsafe {
        ffi::ffm_lyrics_parse(bytes.as_ptr(), bytes.len(), hint.as_ptr(), hint.len(), duration, &mut out, &mut len)
    };
    let buf = take(out, len);
    if code != status::OK {
        return Err(format!("code {code}: {}", String::from_utf8_lossy(&buf)));
    }
    Ok(wire::decode(&buf).expect("wire decodes"))
}

fn dump(t: &Timeline) -> String {
    let mut o = String::new();
    let agents: Vec<String> = t
        .agents
        .iter()
        .map(|a| format!("{}:{:?}:{}", a.id, a.kind, a.name))
        .collect();
    writeln!(
        o,
        "format={} quality={} effects={} lang={} title={} artist={} agents=[{}]",
        t.meta.format,
        t.timing_quality.db_name(),
        t.meta.has_effects,
        t.meta.language.as_deref().unwrap_or("-"),
        t.meta.title.as_deref().unwrap_or("-"),
        t.meta.artist.as_deref().unwrap_or("-"),
        agents.join(", ")
    )
    .unwrap();
    for l in &t.lines {
        writeln!(
            o,
            "L {}-{} agent={} role={:?} style={}",
            l.start_ms,
            l.end_ms,
            l.agent.map(|a| t.agents[a].id.clone()).unwrap_or_else(|| "-".into()),
            l.role,
            l.style.as_deref().unwrap_or("-")
        )
        .unwrap();
        for s in &l.syllables {
            writeln!(
                o,
                "  S {}-{} {:?} {:?}{}",
                s.start_ms,
                s.end_ms,
                s.fill,
                s.text,
                s.ruby.as_ref().map(|r| format!(" ruby={r:?}")).unwrap_or_default()
            )
            .unwrap();
        }
        for (lang, tr) in &l.translations {
            writeln!(o, "  T {lang} {tr:?}").unwrap();
        }
        if let Some(r) = &l.romanization {
            writeln!(o, "  R {r:?}").unwrap();
        }
    }
    o
}

/// 样本文件名 → 解析提示（扩展名；UltraStar 的 `.txt` 靠嗅探）。
fn hint_for(name: &str) -> String {
    Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_owned()
}

#[test]
fn every_sample_matches_its_golden() {
    let samples = fixtures().join("samples");
    let golden_dir = fixtures().join("golden");
    let update = std::env::var("FUSHI_MUSIC_UPDATE_GOLDEN").is_ok_and(|v| v == "1");
    let mut names: Vec<String> = std::fs::read_dir(&samples)
        .expect("samples dir")
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    let required = [
        "line.lrc", "enhanced.lrc", "eslyric.lrc", "lines.srt", "cues.vtt", "lyrics.smi", "plain.txt",
        "amll.ttml", "song.lys", "song.qrc", "song.yrc", "song.krc", "karaoke.ass", "ultrastar.txt", "song.kar",
    ];
    for r in required {
        assert!(names.iter().any(|n| n == r), "missing sample {r}");
    }
    let mut failures = Vec::new();
    for name in &names {
        let bytes = std::fs::read(samples.join(name)).unwrap();
        let t = ffi_parse(&bytes, &hint_for(name), 30_000).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert!(!t.lines.is_empty(), "{name}: no lines");
        let got = dump(&t);
        let golden_path = golden_dir.join(format!("{name}.golden"));
        if update {
            std::fs::create_dir_all(&golden_dir).unwrap();
            std::fs::write(&golden_path, &got).unwrap();
            continue;
        }
        let want = std::fs::read_to_string(&golden_path).unwrap_or_else(|_| panic!("missing golden for {name}"));
        if want != got {
            failures.push(format!("--- {name}\nwant:\n{want}\ngot:\n{got}"));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn text_decoding_matches_the_dart_reference_vectors() {
    let vectors = std::fs::read_to_string(fixtures().join("text_decode_vectors.txt")).unwrap();
    let hex = |s: &str| -> Vec<u8> { (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect() };
    let mut n = 0;
    for line in vectors.lines().filter(|l| !l.starts_with('#') && !l.trim().is_empty()) {
        let parts: Vec<&str> = line.split(' ').collect();
        let input = hex(parts[1]);
        let got = text::decode_unicode(&input);
        let want = match parts[2] {
            "null" => None,
            "-" => Some(String::new()),
            h => Some(String::from_utf8(hex(h)).unwrap()),
        };
        assert_eq!(got, want, "vector {}", parts[0]);
        n += 1;
    }
    assert!(n >= 15, "only {n} vectors");
    // 传统多字节编码：Dart 侧交给平台插件（桌面端缺失），Rust 侧必须解对。
    assert_eq!(text::decode_text(&encoding_rs::SHIFT_JIS.encode("[00:01.00]夜に駆ける").0), "[00:01.00]夜に駆ける");
    assert_eq!(text::decode_text(&encoding_rs::GBK.encode("[00:01.00]你好世界").0), "[00:01.00]你好世界");
}

#[test]
fn unsupported_inputs_report_errors() {
    assert!(ffi_parse(b"\x98\x25\x00\x11garbage", "qrc", -1).unwrap_err().contains("encrypted QRC"));
    assert!(ffi_parse(b"not midi", "kar", -1).is_err());
    assert!(ffi_parse(b"<tt><body><p>", "ttml", -1).is_err());
}

fn copy_fixture(src: &str, dir: &Path, name: &str) -> PathBuf {
    let from = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/library").join(src);
    let to = dir.join(name);
    std::fs::copy(from, &to).unwrap();
    to
}

fn ffi_embedded(path: &Path) -> Vec<(String, String, Vec<u8>, Timeline)> {
    let p = path.to_str().unwrap();
    let mut out: *mut u8 = std::ptr::null_mut();
    let mut len = 0usize;
    let code = unsafe { ffi::ffm_lyrics_embedded(p.as_ptr(), p.len(), 60_000, &mut out, &mut len) };
    let buf = take(out, len);
    assert_eq!(code, status::OK, "{}", String::from_utf8_lossy(&buf));
    let mut r = wire::Reader::new(&buf);
    let n = r.u32().unwrap();
    let mut v = Vec::new();
    for _ in 0..n {
        let key = r.str().unwrap();
        let format = r.str().unwrap();
        let raw_len = r.u32().unwrap() as usize;
        let mut raw = Vec::new();
        for _ in 0..raw_len {
            raw.push(r.u8().unwrap());
        }
        let tl_len = r.u32().unwrap() as usize;
        let mut tl = Vec::new();
        for _ in 0..tl_len {
            tl.push(r.u8().unwrap());
        }
        v.push((key, format, raw, wire::decode(&tl).unwrap()));
    }
    assert!(r.at_end());
    v
}

#[test]
fn embedded_lyrics_from_vorbis_id3_and_mp4() {
    use lofty::config::WriteOptions;
    use lofty::file::TaggedFileExt;
    use lofty::id3::v2::{Frame, Id3v2Tag, SyncTextContentType, SynchronizedTextFrame, TimestampFormat};
    use lofty::prelude::*;
    use lofty::TextEncoding;

    let dir = std::env::temp_dir().join(format!("fushi_music_lyrics_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();

    // FLAC：Vorbis LYRICS 里是一整份 LRC。
    let flac = copy_fixture("Album A/01 First Song.flac", &dir, "a.flac");
    let mut tagged = lofty::read_from_path(&flac).unwrap();
    let tag = tagged.primary_tag_mut().unwrap();
    tag.insert_text(ItemKey::Lyrics, "[00:01.00]沈むように\n[00:03.00]溶けてゆくように".into());
    tagged.save_to_path(&flac, WriteOptions::default()).unwrap();
    let got = ffi_embedded(&flac);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].0, "lyrics");
    assert_eq!(got[0].1, "lrc");
    assert_eq!(got[0].3.lines.len(), 2);
    assert_eq!(got[0].3.lines[1].end_ms, 60_000);

    // MP3：USLT（纯文本）+ SYLT（毫秒制逐字）。
    let mp3 = copy_fixture("Album A/02 Second Song.mp3", &dir, "b.mp3");
    let mut id3 = Id3v2Tag::default();
    id3.insert_text_lyrics_compat("plain line one\nplain line two");
    let sylt = SynchronizedTextFrame::new(
        TextEncoding::UTF8,
        *b"jpn",
        TimestampFormat::MS,
        SyncTextContentType::Lyrics,
        None,
        vec![(1000, "沈".into()), (1400, "む".into()), (2000, "\nよう".into())],
    );
    let bytes = sylt.as_bytes().unwrap();
    id3.insert(Frame::Binary(lofty::id3::v2::BinaryFrame::new(lofty::id3::v2::FrameId::Valid("SYLT".into()), bytes)));
    id3.save_to_path(&mp3, WriteOptions::default()).unwrap();
    let got = ffi_embedded(&mp3);
    let uslt = got.iter().find(|e| e.0 == "lyrics").expect("USLT");
    assert_eq!(uslt.3.timing_quality, TimingQuality::Unsynced);
    assert_eq!(uslt.3.lines.len(), 2);
    let sy = got.iter().find(|e| e.0 == "sylt").expect("SYLT");
    assert_eq!(sy.3.lines.len(), 2);
    assert_eq!(sy.3.lines[0].text(), "沈む");
    assert_eq!(sy.3.meta.language.as_deref(), Some("jpn"));
    assert!(String::from_utf8_lossy(&sy.2).starts_with("[00:01.00]<00:01.00>沈"));

    // MP4（ALAC）：©lyr。
    let m4a = copy_fixture("Formats/alac.m4a", &dir, "c.m4a");
    let mut tagged = lofty::read_from_path(&m4a).unwrap();
    if tagged.primary_tag().is_none() {
        tagged.insert_tag(lofty::tag::Tag::new(tagged.primary_tag_type()));
    }
    tagged.primary_tag_mut().unwrap().insert_text(ItemKey::Lyrics, "[00:02.00]夜に駆ける".into());
    tagged.save_to_path(&m4a, WriteOptions::default()).unwrap();
    let got = ffi_embedded(&m4a);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].3.lines[0].text(), "夜に駆ける");

    let _ = std::fs::remove_dir_all(&dir);
}

trait UsltCompat {
    fn insert_text_lyrics_compat(&mut self, text: &str);
}

impl UsltCompat for lofty::id3::v2::Id3v2Tag {
    fn insert_text_lyrics_compat(&mut self, text: &str) {
        use lofty::prelude::*;
        let mut generic = lofty::tag::Tag::new(lofty::tag::TagType::Id3v2);
        generic.insert_text(ItemKey::Lyrics, text.into());
        let converted: lofty::id3::v2::Id3v2Tag = generic.into();
        for f in converted {
            self.insert(f);
        }
    }
}

#[test]
fn merge_ruby_and_export_round_trip_through_ffi() {
    let call2 = |f: unsafe extern "C" fn(*const u8, usize, *const u8, usize, *mut *mut u8, *mut usize) -> i32,
                 a: &[u8],
                 b: &[u8]|
     -> Vec<u8> {
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut len = 0usize;
        let code = unsafe { f(a.as_ptr(), a.len(), b.as_ptr(), b.len(), &mut out, &mut len) };
        assert_eq!(code, status::OK);
        take(out, len)
    };
    let primary = wire::encode(&ffi_parse(b"[00:01.00]sinking\n[00:05.00]melting", "lrc", 9000).unwrap());
    let secondary = wire::encode(&ffi_parse(b"[00:01.20]\xe6\xb2\x89\n[00:05.00]\xe8\x9e\x8d", "lrc", 9000).unwrap());
    let mut out: *mut u8 = std::ptr::null_mut();
    let mut len = 0usize;
    let lang = "zh";
    let code = unsafe {
        ffi::ffm_lyrics_merge(primary.as_ptr(), primary.len(), secondary.as_ptr(), secondary.len(), lang.as_ptr(), lang.len(), &mut out, &mut len)
    };
    assert_eq!(code, status::OK);
    let merged = wire::decode(&take(out, len)).unwrap();
    assert_eq!(merged.lines[0].translations, vec![("zh".to_string(), "沉".to_string())]);
    assert_eq!(merged.lines[1].translations, vec![("zh".to_string(), "融".to_string())]);

    // 导出 TTML 再解析回来，时间轴不变。
    let ttml = call2(ffi::ffm_lyrics_export, &wire::encode(&merged), b"ttml");
    let back = ffi_parse(&ttml, "ttml", 5000).unwrap();
    assert_eq!(back.lines, merged.lines);
    let lrc = String::from_utf8(call2(ffi::ffm_lyrics_export, &wire::encode(&merged), b"lrc")).unwrap();
    assert!(lrc.contains("[00:01.00]sinking\n[00:01.00]沉\n"), "{lrc}");
}
