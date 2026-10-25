//! 固定输入 → 输出向量：经 C ABI 扫 `tests/fixtures/library`（generate.sh 生成、入库），
//! 把每条记录摊成一行与 `tests/fixtures/scan_golden.txt` 逐字比对。uid 不进 golden（含绝对 /
//! 平台相关路径），由 `uid.rs` 的固定向量单测冻结派生规则；这里只核 uid 的形状与唯一性。
//!
//! 改了解析行为、确认新输出正确后，用 `FUSHI_MUSIC_UPDATE_GOLDEN=1 cargo test --test scan`
//! 重写 golden。

use std::collections::{HashMap, HashSet};
use std::path::Path;

use fushi_music::wire::{self, Record, TrackRecord, Writer};
use fushi_music::{
    ffm_abi_version, ffm_free_bytes, ffm_scan_close, ffm_scan_next, ffm_scan_open,
    ffm_scan_set_known, ffm_tags_embedded_cover, status,
};

const ROOT: &str = "tests/fixtures/library";
const GOLDEN: &str = "tests/fixtures/scan_golden.txt";

fn scan_all(max: u32, known: Option<Vec<u8>>) -> Vec<(bool, Vec<Record>)> {
    let mut handle = std::ptr::null_mut();
    let rc = unsafe { ffm_scan_open(ROOT.as_ptr(), ROOT.len(), 1, &mut handle) };
    assert_eq!(rc, status::OK);
    if let Some(k) = known {
        assert_eq!(
            unsafe { ffm_scan_set_known(handle, k.as_ptr(), k.len()) },
            status::OK
        );
    }
    let mut batches = Vec::new();
    loop {
        let mut ptr = std::ptr::null_mut();
        let mut len = 0usize;
        assert_eq!(
            unsafe { ffm_scan_next(handle, max, &mut ptr, &mut len) },
            status::OK
        );
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
        ffm_free_bytes(ptr, len);
        let (done, records) = wire::decode_batch(&bytes).expect("batch decodes");
        batches.push((done, records));
        if done {
            break;
        }
        assert!(batches.len() < 1000, "scan never finished");
    }
    unsafe { ffm_scan_close(handle) };
    batches
}

fn rel(p: &str) -> String {
    let p = p.replace('\\', "/");
    p.strip_prefix(&format!("{ROOT}/")).unwrap_or(&p).to_owned()
}

fn opt<T: ToString>(v: &Option<T>) -> String {
    v.as_ref()
        .map(|x| x.to_string())
        .unwrap_or_else(|| "-".into())
}

fn line(t: &TrackRecord) -> String {
    let credits: Vec<String> = t
        .credits
        .iter()
        .map(|c| format!("{}:{}", c.role, c.name))
        .collect();
    format!(
        "{} | cue={}..{} | dur={} | {} {}Hz {}bit {}ch lossless={} | title={} | artist={} | \
         album={} | albumArtist={} | disc={} track={} | year={} date={} genre={} | \
         rg={}/{}/{}/{} | embeddedCover={} | folderCover={} | cueSheet={} | credits=[{}]",
        rel(&t.path),
        opt(&t.cue_start_ms),
        opt(&t.cue_end_ms),
        opt(&t.duration_ms),
        opt(&t.codec),
        opt(&t.sample_rate),
        opt(&t.bit_depth),
        opt(&t.channels),
        t.is_lossless,
        t.title,
        opt(&t.artist_credit),
        opt(&t.album_title),
        opt(&t.album_artist),
        opt(&t.disc_no),
        opt(&t.track_no),
        opt(&t.year),
        opt(&t.release_date),
        opt(&t.genre),
        opt(&t.rg_track_gain),
        opt(&t.rg_track_peak),
        opt(&t.rg_album_gain),
        opt(&t.rg_album_peak),
        t.has_embedded_cover,
        t.folder_cover_path
            .as_deref()
            .map(rel)
            .unwrap_or_else(|| "-".into()),
        t.cue_sheet_path
            .as_deref()
            .map(rel)
            .unwrap_or_else(|| "-".into()),
        credits.join(", "),
    )
}

fn tracks(batches: &[(bool, Vec<Record>)]) -> Vec<TrackRecord> {
    batches
        .iter()
        .flat_map(|(_, r)| r.iter())
        .filter_map(|r| match r {
            Record::Track(t) => Some((**t).clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn abi_version_is_one() {
    assert_eq!(ffm_abi_version(), 1);
}

#[test]
fn scan_matches_golden_vector() {
    let batches = scan_all(0, None);
    let all: Vec<&Record> = batches.iter().flat_map(|(_, r)| r.iter()).collect();
    for r in &all {
        if let Record::Error { path, message } = r {
            panic!("unexpected error record {path}: {message}");
        }
    }
    let ts = tracks(&batches);
    let actual: String = ts.iter().map(|t| line(t) + "\n").collect();
    if std::env::var("FUSHI_MUSIC_UPDATE_GOLDEN").is_ok() {
        std::fs::write(GOLDEN, &actual).unwrap();
    }
    let expected = std::fs::read_to_string(GOLDEN)
        .expect("golden missing: run with FUSHI_MUSIC_UPDATE_GOLDEN=1")
        .replace("\r\n", "\n");
    assert_eq!(actual, expected);

    // uid：32 位十六进制、全库唯一；同一专辑的曲目共享专辑 uid。
    let mut seen = HashSet::new();
    for t in &ts {
        assert_eq!(t.track_uid.len(), 32);
        assert!(t.track_uid.chars().all(|c| c.is_ascii_hexdigit()));
        assert!(seen.insert(t.track_uid.clone()), "duplicate uid {}", t.path);
    }
    let albums: HashMap<String, HashSet<String>> = ts.iter().fold(HashMap::new(), |mut m, t| {
        if let (Some(a), Some(u)) = (&t.album_title, &t.album_uid) {
            m.entry(a.clone()).or_default().insert(u.clone());
        }
        m
    });
    for (album, uids) in &albums {
        assert_eq!(uids.len(), 1, "album {album} split into {uids:?}");
    }
}

#[test]
fn batches_respect_the_limit_and_are_order_stable() {
    let small = scan_all(2, None);
    assert!(small.iter().all(|(_, r)| r.len() <= 2));
    assert!(small.len() > 2, "limit 2 must take several batches");
    let a: Vec<String> = tracks(&small).iter().map(|t| t.track_uid.clone()).collect();
    let b: Vec<String> = tracks(&scan_all(0, None))
        .iter()
        .map(|t| t.track_uid.clone())
        .collect();
    assert_eq!(a, b, "batch size must not change content or order");
}

#[test]
fn known_unchanged_files_skip_tag_parsing() {
    let first = tracks(&scan_all(0, None));
    let flac = first
        .iter()
        .find(|t| rel(&t.path) == "Album A/01 First Song.flac")
        .unwrap();
    let cue = first
        .iter()
        .find(|t| rel(&t.path) == "Cue Album/full.flac")
        .unwrap();
    let mut w = Writer::new();
    w.u32(2);
    w.str(&flac.path);
    w.i64(flac.file_mtime_ms);
    w.i64(flac.file_size);
    w.str(&cue.path);
    w.i64(cue.file_mtime_ms);
    w.i64(cue.file_size);
    let second = scan_all(0, Some(w.into_bytes()));
    let unchanged: Vec<String> = second
        .iter()
        .flat_map(|(_, r)| r.iter())
        .filter_map(|r| match r {
            Record::Unchanged(p) => Some(rel(p)),
            _ => None,
        })
        .collect();
    assert_eq!(
        unchanged,
        vec!["Album A/01 First Song.flac", "Cue Album/full.flac"],
        "one unchanged record per file (the CUE file covers all its virtual tracks)"
    );
    assert_eq!(tracks(&second).len(), first.len() - 1 - 3);
}

#[test]
fn bad_inputs_are_rejected_not_panicking() {
    let mut handle = std::ptr::null_mut();
    let missing = "tests/fixtures/no-such-dir";
    assert_eq!(
        unsafe { ffm_scan_open(missing.as_ptr(), missing.len(), 1, &mut handle) },
        status::NOT_FOUND
    );
    let bad = [0xFFu8, 0xFE];
    assert_eq!(
        unsafe { ffm_scan_open(bad.as_ptr(), bad.len(), 1, &mut handle) },
        status::INVALID_ARGUMENT
    );
    let mut h = std::ptr::null_mut();
    assert_eq!(
        unsafe { ffm_scan_open(ROOT.as_ptr(), ROOT.len(), 1, &mut h) },
        status::OK
    );
    let garbage = [1u8, 0, 0, 0, 9];
    assert_eq!(
        unsafe { ffm_scan_set_known(h, garbage.as_ptr(), garbage.len()) },
        status::BAD_INPUT
    );
    unsafe { ffm_scan_close(h) };
}

#[test]
fn embedded_cover_absent_returns_empty() {
    let p = format!("{ROOT}/Album A/01 First Song.flac");
    assert!(Path::new(&p).is_file());
    let mut ptr = std::ptr::null_mut();
    let mut len = 7usize;
    assert_eq!(
        unsafe { ffm_tags_embedded_cover(p.as_ptr(), p.len(), &mut ptr, &mut len) },
        status::OK
    );
    assert_eq!(len, 0);
    assert!(ptr.is_null());
}
