//! 语料库端到端：写入 → 查询 → 重开（持久化）→ 替换 / 删除 / 坏文件 / 并发。

use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

use fushi_corpus::corpus::Corpus;
use fushi_corpus::wire::Writer;

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("fushi_corpus_test_{name}_{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir
}

struct S<'a> {
    section: i32,
    pos: i64,
    len: i64,
    text: &'a str,
    /// (start16, len16, lemma)
    tokens: Vec<(u32, u32, &'a str)>,
}

fn doc_bytes(kind: u8, key: &str, part: i32, title: &str, fingerprint: &str, updated_at: i64, s: &[S]) -> Vec<u8> {
    let mut w = Writer::default();
    w.u8(kind);
    w.str(key);
    w.i32(part);
    w.str(title);
    w.str(fingerprint);
    w.str("norm-1");
    w.i64(updated_at);
    w.u32(s.len() as u32);
    for x in s {
        w.i32(x.section);
        w.i64(x.pos);
        w.i64(x.len);
        w.str(x.text);
    }
    w.buf
}

fn terms_bytes(s: &[S]) -> Vec<u8> {
    let mut w = Writer::default();
    for x in s {
        w.u32(x.tokens.len() as u32);
        for &(start, len, lemma) in &x.tokens {
            w.u32(start);
            w.u32(len);
            w.str(lemma);
        }
    }
    w.buf
}

fn query_bytes(keys: &[&str], per_kind: u32, per_doc: u32, mask: u32) -> Vec<u8> {
    let mut w = Writer::default();
    w.u32(keys.len() as u32);
    for k in keys {
        w.str(k);
    }
    w.u32(per_kind);
    w.u32(per_doc);
    w.u32(mask);
    w.buf
}

fn put(c: &Corpus, kind: u8, key: &str, part: i32, fingerprint: &str, updated_at: i64, s: &[S]) {
    c.put(&doc_bytes(kind, key, part, "Title", fingerprint, updated_at, s), &terms_bytes(s)).unwrap();
}

fn book_sentences() -> Vec<S<'static>> {
    vec![
        S { section: 0, pos: 0, len: 7, text: "猫が魚を食べた。", tokens: vec![(0, 1, "猫"), (1, 1, "が"), (2, 1, "魚"), (4, 3, "食べる")] },
        S { section: 2, pos: 40, len: 9, text: "犬もご飯を食べている。", tokens: vec![(0, 1, "犬"), (5, 3, "食べる")] },
        S { section: 3, pos: 5, len: 2, text: "食べ", tokens: vec![(0, 2, "食べる")] },
    ]
}

#[test]
fn put_query_and_reopen() {
    let dir = temp_dir("reopen");
    {
        let c = Corpus::open(&dir).unwrap();
        put(&c, 1, "book-a", -1, "fp1", 10, &book_sentences());
        put(
            &c,
            2,
            "video-x",
            3,
            "fp2",
            20,
            &[S { section: 3, pos: 61000, len: 2500, text: "早く食べなさい", tokens: vec![(2, 3, "食べる")] }],
        );
        let json = c.query_json(&query_bytes(&["食べる"], 5, 2, u32::MAX)).unwrap();
        // 书组：每文档至多 2 条，长度合适的两条先出（「食べ」太短排最后被 per_doc 截掉）。
        assert!(json.starts_with("{\"total\":4,\"groups\":[{\"kind\":1,\"total\":3,\"items\":["), "{json}");
        assert!(json.contains("\"text\":\"猫が魚を食べた。\",\"hl\":[[4,3]]"), "{json}");
        assert!(json.contains("\"section\":2,\"pos\":40,\"len\":9"), "{json}");
        assert!(!json.contains("\"text\":\"食べ\""), "{json}");
        assert!(json.contains("{\"kind\":2,\"total\":1,\"items\":[{\"key\":\"video-x\",\"part\":3"), "{json}");
        // kind 过滤：只要视频。
        let only_video = c.query_json(&query_bytes(&["食べる"], 5, 2, 1 << 2)).unwrap();
        assert!(only_video.starts_with("{\"total\":1,"), "{only_video}");
        // 不存在的词。
        assert_eq!(c.query_json(&query_bytes(&["走る"], 5, 2, u32::MAX)).unwrap(), "{\"total\":0,\"groups\":[]}");
    }
    let c = Corpus::open(&dir).unwrap();
    assert!(c.stats_json().starts_with("{\"docs\":2,\"sentences\":4,"), "{}", c.stats_json());
    let docs = c.docs_json(Some(1), None);
    assert_eq!(
        docs,
        "[{\"kind\":1,\"key\":\"book-a\",\"part\":-1,\"title\":\"Title\",\"fingerprint\":\"fp1\",\"normalizer\":\"norm-1\",\"updatedAt\":10,\"sentences\":3}]"
    );
    let json = c.query_json(&query_bytes(&["猫"], 5, 2, u32::MAX)).unwrap();
    assert!(json.contains("\"hl\":[[0,1]]"), "{json}");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn replace_and_remove() {
    let dir = temp_dir("replace");
    let c = Corpus::open(&dir).unwrap();
    put(&c, 1, "book-a", -1, "fp1", 10, &book_sentences());
    put(
        &c,
        1,
        "book-a",
        -1,
        "fp2",
        11,
        &[S { section: 0, pos: 0, len: 4, text: "雨が降る。", tokens: vec![(0, 1, "雨"), (2, 2, "降る")] }],
    );
    assert_eq!(c.query_json(&query_bytes(&["食べる"], 5, 2, u32::MAX)).unwrap(), "{\"total\":0,\"groups\":[]}");
    assert!(c.query_json(&query_bytes(&["降る"], 5, 2, u32::MAX)).unwrap().contains("雨が降る。"));
    assert_eq!(fs::read_dir(&dir).unwrap().count(), 1, "old generation file must be deleted");
    // 多 part：删一个 part / 删全部。
    for part in 0..3 {
        put(&c, 2, "video-x", part, "fp", 1, &[S { section: part, pos: 0, len: 1, text: "雨だね", tokens: vec![(0, 1, "雨")] }]);
    }
    assert_eq!(c.remove(2, "video-x", Some(1)), 1);
    assert!(c.query_json(&query_bytes(&["雨"], 10, 0, 1 << 2)).unwrap().starts_with("{\"total\":2,"));
    assert_eq!(c.remove(2, "video-x", None), 2);
    assert_eq!(c.remove_kinds(1 << 1), 1);
    assert!(c.stats_json().starts_with("{\"docs\":0,\"sentences\":0,"));
    assert_eq!(fs::read_dir(&dir).unwrap().count(), 0);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn duplicate_texts_and_per_doc_cap() {
    let dir = temp_dir("dedupe");
    let c = Corpus::open(&dir).unwrap();
    // 同一句 OP 歌词出现在 5 集里：只出一次。
    for ep in 0..5 {
        put(&c, 2, "anime", ep, "fp", 1, &[S { section: ep, pos: 1000, len: 3000, text: "夜明けの窓", tokens: vec![(0, 3, "夜明け")] }]);
    }
    let json = c.query_json(&query_bytes(&["夜明け"], 5, 0, u32::MAX)).unwrap();
    assert_eq!(json.matches("夜明けの窓").count(), 1, "{json}");
    assert!(json.contains("\"total\":5"), "{json}");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn bad_input_and_corrupt_files() {
    let dir = temp_dir("corrupt");
    let c = Corpus::open(&dir).unwrap();
    let s = book_sentences();
    // 词元少一句：拒绝。
    let mut short = terms_bytes(&s);
    short.truncate(short.len() - 4);
    assert!(c.put(&doc_bytes(1, "b", -1, "T", "f", 1, &s), &short).is_err());
    put(&c, 1, "b", -1, "f", 1, &s);
    drop(c);
    fs::write(dir.join("garbage.fcd"), b"FCRP\x01\x00\x00\x00\xff").unwrap();
    fs::write(dir.join("leftover.tmp"), b"x").unwrap();
    let c = Corpus::open(&dir).unwrap();
    assert!(c.stats_json().contains("\"docs\":1,"), "{}", c.stats_json());
    assert!(c.stats_json().contains("\"droppedOnOpen\":1"), "{}", c.stats_json());
    assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn concurrent_put_and_query() {
    let dir = temp_dir("concurrent");
    let c = Arc::new(Corpus::open(&dir).unwrap());
    let writer = {
        let c = Arc::clone(&c);
        std::thread::spawn(move || {
            for i in 0..200 {
                let text = format!("食べる練習{i}");
                let s = [S { section: 0, pos: i, len: 1, text: &text, tokens: vec![(0, 3, "食べる")] }];
                put(&c, 1, &format!("k{}", i % 7), -1, "fp", i, &s);
            }
        })
    };
    for _ in 0..200 {
        let json = c.query_json(&query_bytes(&["食べる"], 3, 1, u32::MAX)).unwrap();
        assert!(json.starts_with("{\"total\":"));
    }
    writer.join().unwrap();
    assert!(c.stats_json().starts_with("{\"docs\":7,\"sentences\":7,"), "{}", c.stats_json());
    let _ = fs::remove_dir_all(&dir);
}
