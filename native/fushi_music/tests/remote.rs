//! 远程扫描游标（`remote.rs`）经 C ABI 的端到端：把 `tests/fixtures/library` 摊成一份
//! `sftp://nas/lib/…` 文件清单，字节按 NEED 区间从本地 fixture 读出来喂回去。输出与本地
//! 扫描的 golden 逐行一致（只有路径前缀不同）；CUE 是 Shift_JIS 原始字节（不经 UTF-8 转手）。

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use fushi_music::remote::{self, ListedFile, Listing};
use fushi_music::uid::{self, AudioFingerprint};
use fushi_music::wire::{self, Record, TrackRecord, Writer};
use fushi_music::{
    ffm_free_bytes, ffm_remote_scan_close, ffm_remote_scan_feed, ffm_remote_scan_open,
    ffm_remote_scan_set_known, ffm_remote_scan_step, status,
};

const ROOT: &str = "tests/fixtures/library";
const GOLDEN: &str = "tests/fixtures/scan_golden.txt";
const PREFIX: &str = "sftp://nas/lib";

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in fs::read_dir(dir).unwrap().flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, out);
        } else {
            out.push(p);
        }
    }
}

/// 本地目录 → 远程清单（路径 `prefix/<相对路径>`）+ 远程路径 → 本地文件的映射。
fn listing_of(root: &str, prefix: &str) -> (Listing, HashMap<String, PathBuf>) {
    let mut files = Vec::new();
    walk(Path::new(root), &mut files);
    let mut listing = Listing {
        root: prefix.into(),
        ..Default::default()
    };
    let mut map = HashMap::new();
    for f in files {
        let rel = f
            .strip_prefix(root)
            .unwrap()
            .to_string_lossy()
            .replace('\\', "/");
        let remote_path = format!("{prefix}/{rel}");
        let meta = fs::metadata(&f).unwrap();
        let mtime = meta
            .modified()
            .unwrap()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        if rel.to_ascii_lowercase().ends_with(".cue") {
            listing
                .cues
                .insert(remote_path.clone(), fs::read(&f).unwrap());
        }
        listing.files.push(ListedFile {
            path: remote_path.clone(),
            mtime_ms: mtime,
            size: meta.len() as i64,
        });
        map.insert(remote_path, f);
    }
    (listing, map)
}

struct Run {
    records: Vec<Record>,
    /// 每个文件被要了几轮字节。
    rounds: HashMap<String, usize>,
    fetched: HashMap<String, u64>,
}

fn run(
    listing: &Listing,
    fetch: &dyn Fn(&str, u64, u64) -> Vec<u8>,
    known: Option<Vec<u8>>,
    max: u32,
) -> Run {
    let bytes = remote::encode_listing(listing);
    let mut h = std::ptr::null_mut();
    assert_eq!(
        unsafe { ffm_remote_scan_open(bytes.as_ptr(), bytes.len(), &mut h) },
        status::OK
    );
    if let Some(k) = known {
        assert_eq!(
            unsafe { ffm_remote_scan_set_known(h, k.as_ptr(), k.len()) },
            status::OK
        );
    }
    let mut out = Run {
        records: Vec::new(),
        rounds: HashMap::new(),
        fetched: HashMap::new(),
    };
    for _ in 0..10_000 {
        let mut ptr = std::ptr::null_mut();
        let mut len = 0usize;
        assert_eq!(
            unsafe { ffm_remote_scan_step(h, max, &mut ptr, &mut len) },
            status::OK
        );
        let step = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
        ffm_free_bytes(ptr, len);
        let mut r = wire::Reader::new(&step);
        match r.u8().unwrap() {
            0 => {
                let path = r.str().unwrap();
                *out.rounds.entry(path.clone()).or_default() += 1;
                let n = r.u32().unwrap();
                for _ in 0..n {
                    let off = r.i64().unwrap() as u64;
                    let l = r.i64().unwrap() as u64;
                    let data = fetch(&path, off, l);
                    *out.fetched.entry(path.clone()).or_default() += data.len() as u64;
                    assert_eq!(
                        unsafe { ffm_remote_scan_feed(h, off as i64, data.as_ptr(), data.len()) },
                        status::OK
                    );
                }
            }
            1 => {
                let (done, records) = wire::decode_batch(&step[1..]).expect("batch decodes");
                if max > 0 {
                    assert!(records.len() <= max as usize);
                }
                out.records.extend(records);
                if done {
                    unsafe { ffm_remote_scan_close(h) };
                    return out;
                }
            }
            k => panic!("unknown step kind {k}"),
        }
    }
    panic!("remote scan never finished");
}

fn file_fetcher(map: HashMap<String, PathBuf>) -> impl Fn(&str, u64, u64) -> Vec<u8> {
    move |path, off, len| {
        let all = fs::read(&map[path]).unwrap();
        let end = ((off + len) as usize).min(all.len());
        all[off as usize..end].to_vec()
    }
}

fn tracks(records: &[Record]) -> Vec<TrackRecord> {
    records
        .iter()
        .filter_map(|r| match r {
            Record::Track(t) => Some((**t).clone()),
            _ => None,
        })
        .collect()
}

fn rel(p: &str) -> String {
    p.strip_prefix(&format!("{PREFIX}/"))
        .unwrap_or(p)
        .to_owned()
}

fn opt<T: ToString>(v: &Option<T>) -> String {
    v.as_ref()
        .map(|x| x.to_string())
        .unwrap_or_else(|| "-".into())
}

/// 与 tests/scan.rs 的 golden 行同一格式。
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

#[test]
fn remote_listing_scan_matches_the_local_golden() {
    let (listing, map) = listing_of(ROOT, PREFIX);
    let fetch = file_fetcher(map);
    let r = run(&listing, &fetch, None, 0);
    for rec in &r.records {
        if let Record::Error { path, message } = rec {
            panic!("unexpected error record {path}: {message}");
        }
    }
    let ts = tracks(&r.records);
    let actual: String = ts.iter().map(|t| line(t) + "\n").collect();
    let expected = fs::read_to_string(GOLDEN).unwrap().replace("\r\n", "\n");
    // 同一棵树、同一份解析：逐行一致（含 Shift_JIS CUE 的日文标题、内嵌 CUESHEET 拆轨、
    // 目录封面、隐藏文件跳过）。
    assert_eq!(actual, expected);

    // uid 规则与本地相同：路径原文 + CUE 起点 + 音频属性指纹。
    for t in ts.iter().filter(|t| t.cue_start_ms.is_none()) {
        let fp = AudioFingerprint {
            duration_ms: t.duration_ms,
            sample_rate: t.sample_rate,
            channels: t.channels,
        };
        assert_eq!(t.track_uid, uid::track_uid(&t.path, None, fp), "{}", t.path);
    }
    // fixture 都很小：一轮（头 + 尾预取）就收敛。
    for (path, n) in &r.rounds {
        assert!(*n <= 3, "{path} took {n} rounds");
    }
    // 非音频（cover.png / notes.txt / .cue）不取字节。
    assert!(
        r.rounds
            .keys()
            .all(|p| !p.ends_with(".png") && !p.ends_with(".txt"))
    );
}

#[test]
fn batch_limit_does_not_change_content_or_order() {
    let (listing, map) = listing_of(ROOT, PREFIX);
    let fetch = file_fetcher(map);
    let all = tracks(&run(&listing, &fetch, None, 0).records);
    let small = tracks(&run(&listing, &fetch, None, 2).records);
    let a: Vec<&str> = all.iter().map(|t| t.track_uid.as_str()).collect();
    let b: Vec<&str> = small.iter().map(|t| t.track_uid.as_str()).collect();
    assert_eq!(a, b);
}

#[test]
fn known_unchanged_files_are_not_fetched_again() {
    let (listing, map) = listing_of(ROOT, PREFIX);
    let fetch = file_fetcher(map);
    let first = tracks(&run(&listing, &fetch, None, 0).records);
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
    for t in [flac, cue] {
        w.str(&t.path);
        w.i64(t.file_mtime_ms);
        w.i64(t.file_size);
    }
    let second = run(&listing, &fetch, Some(w.into_bytes()), 0);
    let unchanged: Vec<String> = second
        .records
        .iter()
        .filter_map(|r| match r {
            Record::Unchanged(p) => Some(rel(p)),
            _ => None,
        })
        .collect();
    assert_eq!(
        unchanged,
        vec!["Album A/01 First Song.flac", "Cue Album/full.flac"]
    );
    assert!(!second.rounds.contains_key(&flac.path));
    assert!(!second.rounds.contains_key(&cue.path));
    assert_eq!(tracks(&second.records).len(), first.len() - 1 - 3);
}

#[test]
fn unknown_mtime_is_never_treated_as_unchanged() {
    let (mut listing, map) = listing_of(ROOT, PREFIX);
    for f in &mut listing.files {
        f.mtime_ms = -1;
    }
    let fetch = file_fetcher(map);
    let first = tracks(&run(&listing, &fetch, None, 0).records);
    let mut w = Writer::new();
    w.u32(first.len() as u32);
    for t in &first {
        w.str(&t.path);
        w.i64(t.file_mtime_ms);
        w.i64(t.file_size);
    }
    let again = run(&listing, &fetch, Some(w.into_bytes()), 0);
    assert!(
        again
            .records
            .iter()
            .all(|r| !matches!(r, Record::Unchanged(_)))
    );
    assert_eq!(tracks(&again.records).len(), first.len());
}

fn temp_dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("fushi_music_{name}_{}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

#[test]
fn embedded_cover_bytes_come_back_before_the_track() {
    use lofty::config::WriteOptions;
    use lofty::file::{AudioFile, TaggedFileExt};
    use lofty::picture::{MimeType, Picture, PictureType};

    let dir = temp_dir("remote_cover");
    let p = dir.join("song.flac");
    fs::copy(format!("{ROOT}/Album A/01 First Song.flac"), &p).unwrap();
    // 600 KiB 的封面：比首轮头部预取大，要多取一轮。
    let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
    png.extend((0..600 * 1024).map(|i| (i % 251) as u8));
    let mut tagged = lofty::read_from_path(&p).unwrap();
    tagged
        .primary_tag_mut()
        .unwrap()
        .push_picture(Picture::new_unchecked(
            PictureType::CoverFront,
            Some(MimeType::Png),
            None,
            png.clone(),
        ));
    tagged.save_to_path(&p, WriteOptions::default()).unwrap();

    let (listing, map) = listing_of(dir.to_str().unwrap(), "https://dav/m");
    let fetch = file_fetcher(map);
    let r = run(&listing, &fetch, None, 0);
    match &r.records[..] {
        [Record::Cover { path, data }, Record::Track(t)] => {
            assert_eq!(path, "https://dav/m/song.flac");
            assert_eq!(data, &png);
            assert!(t.has_embedded_cover);
            assert_eq!(t.title, "First Song");
        }
        other => panic!("unexpected records {other:?}"),
    }
    let rounds = r.rounds["https://dav/m/song.flac"];
    assert!((2..=3).contains(&rounds), "took {rounds} rounds");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn runaway_metadata_stops_at_the_fetch_cap() {
    // 声称 16 MiB PICTURE 块、之后全是 0 的 40 MiB「FLAC」：lofty 会一直要字节，取数封顶后
    // 按扩展名收尾，不 panic、不无限取。
    let size: u64 = 40 << 20;
    let mut head = b"fLaC".to_vec();
    head.extend_from_slice(&[0x00, 0x00, 0x00, 34]); // STREAMINFO
    let mut si = vec![0u8; 34];
    si[10] = 0x01;
    si[11] = 0xF4; // 8000 Hz
    si[12] = 0x00;
    head.extend_from_slice(&si);
    head.extend_from_slice(&[0x86, 0xFF, 0xFF, 0xFF]); // last PICTURE, 16 MiB - 1
    let listing = Listing {
        root: "https://dav/m".into(),
        files: vec![ListedFile {
            path: "https://dav/m/huge.flac".into(),
            mtime_ms: 1,
            size: size as i64,
        }],
        cues: HashMap::new(),
    };
    let fetch = move |_: &str, off: u64, len: u64| -> Vec<u8> {
        (off..(off + len).min(size))
            .map(|i| head.get(i as usize).copied().unwrap_or(0))
            .collect()
    };
    let r = run(&listing, &fetch, None, 0);
    let ts = tracks(&r.records);
    let errors = r
        .records
        .iter()
        .filter(|r| matches!(r, Record::Error { .. }))
        .count();
    assert_eq!(ts.len() + errors, 1, "{:?}", r.records);
    let fetched = r.fetched["https://dav/m/huge.flac"];
    assert!(
        fetched <= remote::FETCH_CAP + (8 << 20),
        "fetched {fetched}"
    );
}

#[test]
fn a_file_that_gets_no_bytes_becomes_an_error_record() {
    let (listing, map) = listing_of(ROOT, PREFIX);
    let real = file_fetcher(map);
    let fetch = move |path: &str, off: u64, len: u64| -> Vec<u8> {
        if path.ends_with("02 Second Song.mp3") {
            Vec::new()
        } else {
            real(path, off, len)
        }
    };
    let r = run(&listing, &fetch, None, 0);
    let errors: Vec<String> = r
        .records
        .iter()
        .filter_map(|r| match r {
            Record::Error { path, .. } => Some(rel(path)),
            _ => None,
        })
        .collect();
    assert_eq!(errors, vec!["Album A/02 Second Song.mp3"]);
    assert_eq!(r.rounds[&format!("{PREFIX}/Album A/02 Second Song.mp3")], 1);
    // 其余曲目照常出：本地 golden 的全部曲目少这一首（不写死条数，fixture 增减格式不改这里）。
    let golden = fs::read_to_string(GOLDEN).unwrap();
    assert_eq!(tracks(&r.records).len(), golden.lines().count() - 1);
}

#[test]
fn bad_listing_is_rejected() {
    let mut h = std::ptr::null_mut();
    let garbage = [9u8, 0, 0, 0, 1];
    assert_eq!(
        unsafe { ffm_remote_scan_open(garbage.as_ptr(), garbage.len(), &mut h) },
        status::BAD_INPUT
    );
    // 没有进行中的文件时喂数据：拒绝。
    let empty = remote::encode_listing(&Listing::default());
    assert_eq!(
        unsafe { ffm_remote_scan_open(empty.as_ptr(), empty.len(), &mut h) },
        status::OK
    );
    let b = [1u8];
    assert_eq!(
        unsafe { ffm_remote_scan_feed(h, 0, b.as_ptr(), 1) },
        status::INVALID_ARGUMENT
    );
    unsafe { ffm_remote_scan_close(h) };
}
