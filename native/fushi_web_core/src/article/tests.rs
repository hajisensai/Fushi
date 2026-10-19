//! 正文提取 / 连载会话的回归测试（真实页面快照与期望值见 tests/vectors/article/）。

use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::session::{IngestStatus, NovelSession, SNAPSHOT_TYPE};
use super::*;
use crate::ffi_util::fwc_bytes_free;

fn vectors() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/vectors/article")
}

fn input(file: &str) -> Vec<u8> {
    std::fs::read(vectors().join("inputs").join(file)).unwrap()
}

fn expected_cases() -> Vec<Value> {
    let raw = std::fs::read_to_string(vectors().join("expected.json")).unwrap();
    let v: Value = serde_json::from_str(&raw).unwrap();
    v["cases"].as_array().unwrap().clone()
}

#[test]
fn regression_vectors() {
    let cases = expected_cases();
    assert!(cases.len() >= 9, "vector set shrank: {}", cases.len());
    let mut failures = Vec::new();
    for case in &cases {
        let file = case["file"].as_str().unwrap();
        let url = case["url"].as_str().unwrap();
        let article = extract(&input(file), url).unwrap();
        let header = serde_json::to_value(&article).unwrap();
        let expect = case["expect"].as_object().unwrap();
        for (key, want) in expect {
            let ok = match key.as_str() {
                "minChars" => article.chars as u64 >= want.as_u64().unwrap(),
                "excerptPrefix" => article.excerpt.starts_with(want.as_str().unwrap()),
                "xhtmlContains" => want
                    .as_array()
                    .unwrap()
                    .iter()
                    .all(|s| article.xhtml.contains(s.as_str().unwrap())),
                "xhtmlNotContains" => want
                    .as_array()
                    .unwrap()
                    .iter()
                    .all(|s| !article.xhtml.contains(s.as_str().unwrap())),
                field => header.get(field) == Some(want),
            };
            if !ok {
                failures.push(format!(
                    "{file} @ {url}: {key} want {want}, got {}",
                    match key.as_str() {
                        "minChars" => article.chars.to_string(),
                        "excerptPrefix" => article.excerpt.clone(),
                        "xhtmlContains" | "xhtmlNotContains" =>
                            article.xhtml.chars().take(400).collect(),
                        field => header.get(field).map(|v| v.to_string()).unwrap_or_default(),
                    }
                ));
            }
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn every_site_rule_selector_compiles() {
    for rule in sites::SITE_RULES {
        for (name, sel) in [
            ("title", rule.title),
            ("work_title", rule.work_title),
            ("author", rule.author),
            ("body", rule.body),
            ("remove", rule.remove),
            ("next", rule.next),
            ("prev", rule.prev),
            ("toc", rule.toc),
        ] {
            if !sel.is_empty() {
                assert!(
                    Matcher::new(sel).is_ok(),
                    "rule {} selector {name} does not compile: {sel}",
                    rule.id
                );
            }
        }
    }
}

#[test]
fn xhtml_output_is_well_formed_xml_fragment() {
    // 每个向量的正文都要能当 XML 片段解析（EPUB 章节是 XHTML，坏了阅读器整章空白）。
    for case in expected_cases() {
        let article = extract(
            &input(case["file"].as_str().unwrap()),
            case["url"].as_str().unwrap(),
        )
        .unwrap();
        assert_well_formed(&article.xhtml);
    }
}

/// 极简 XML 片段校验：标签配对、自闭合、实体只有 &amp; &lt; &gt; &quot;。
fn assert_well_formed(xhtml: &str) {
    let mut stack: Vec<String> = Vec::new();
    let mut rest = xhtml;
    while let Some(pos) = rest.find(['<', '&']) {
        let tail = &rest[pos..];
        if tail.starts_with('&') {
            assert!(
                ["&amp;", "&lt;", "&gt;", "&quot;"]
                    .iter()
                    .any(|e| tail.starts_with(e)),
                "bare entity near {:?}",
                &tail[..tail.len().min(20)]
            );
            rest = tail.strip_prefix('&').unwrap();
            continue;
        }
        let end = tail.find('>').expect("unterminated tag");
        let tag = &tail[1..end];
        if let Some(name) = tag.strip_prefix('/') {
            assert_eq!(stack.pop().as_deref(), Some(name), "mismatched </{name}>");
        } else if !tag.ends_with('/') {
            let name = tag.split_whitespace().next().unwrap().to_owned();
            stack.push(name);
        }
        rest = &tail[end + 1..];
    }
    assert!(stack.is_empty(), "unclosed: {stack:?}");
}

#[test]
fn work_key_from_url_matches_extraction() {
    for case in expected_cases() {
        let url = case["url"].as_str().unwrap();
        let article = extract(&input(case["file"].as_str().unwrap()), url).unwrap();
        assert_eq!(
            work_key_for_url(url).as_deref(),
            Some(article.work_key.as_str()),
            "{url}"
        );
    }
    assert!(work_key_for_url("ftp://x/y").is_none());
    assert!(work_key_for_url("not a url").is_none());
}

#[test]
fn bad_input_is_an_error_or_empty_not_a_panic() {
    assert!(extract(b"<p>x</p>", "file:///etc/passwd").is_err());
    let a = extract(b"", "https://a.example/1").unwrap();
    assert!(a.is_empty());
    let a = extract(&[0xff, 0xfe, 0x00, 0x01, 0x80, 0x81], "https://a.example/1").unwrap();
    assert!(a.is_empty());
    let a = extract(
        b"<html><body><a href='/'>home</a></body></html>",
        "https://a.example/1",
    )
    .unwrap();
    assert!(a.is_empty());
}

// ── 连载会话 ──────────────────────────────────────────────────────────────

fn syosetu(n: u32) -> Article {
    // 用第 10 话的快照当任意一话：只改 URL 与上下章（会话只看元数据与指纹）。
    let mut a = extract(
        &input("syosetu_n9669bk_10.html"),
        &format!("https://ncode.syosetu.com/n9669bk/{n}/"),
    )
    .unwrap();
    a.next = Some(format!("https://ncode.syosetu.com/n9669bk/{}/", n + 1));
    a.prev = (n > 1).then(|| format!("https://ncode.syosetu.com/n9669bk/{}/", n - 1));
    a.title = format!("第{n}話");
    a.content_hash = format!("hash-{n}");
    a
}

#[test]
fn session_orders_dedupes_and_queues() {
    let mut s = NovelSession::new();
    let o = s.ingest(&syosetu(2));
    assert_eq!((o.status, o.index), (IngestStatus::Added, Some(0)));
    assert_eq!(
        o.tail_next.as_deref(),
        Some("https://ncode.syosetu.com/n9669bk/3/")
    );
    // 第 3 话接在 2 后面，第 1 话插到最前（靠 next / prev 链）。
    assert_eq!(s.ingest(&syosetu(3)).index, Some(1));
    assert_eq!(s.ingest(&syosetu(1)).index, Some(0));
    let titles: Vec<&str> = s
        .state()
        .chapters
        .iter()
        .map(|c| c.title.as_str())
        .collect();
    assert_eq!(titles, ["第1話", "第2話", "第3話"]);
    // 同一章再喂一次：更新，不重复（URL 形式不同：http + www + 无末尾斜杠也认）。
    let mut again = syosetu(2);
    again.url = "http://www.ncode.syosetu.com/n9669bk/2".into();
    again.title = "第2話（改稿）".into();
    let o = s.ingest(&again);
    assert_eq!(
        (o.status, o.index, o.chapter_count),
        (IngestStatus::Updated, Some(1), 3)
    );
    assert_eq!(s.state().chapters[1].title, "第2話（改稿）");
    assert_eq!(
        s.state().tail_next.as_deref(),
        Some("https://ncode.syosetu.com/n9669bk/4/")
    );
    assert_eq!(
        s.state().queue,
        vec!["https://ncode.syosetu.com/n9669bk/4/".to_owned()]
    );
}

#[test]
fn session_rejects_other_work_and_empty_pages() {
    let mut s = NovelSession::new();
    s.ingest(&syosetu(1));
    let other = extract(
        &input("kakuyomu_1177354054881165840_ep.html"),
        "https://kakuyomu.jp/works/1177354054881165840/episodes/1177354054881168184",
    )
    .unwrap();
    assert_eq!(s.ingest(&other).status, IngestStatus::OtherWork);
    let empty = extract(
        b"<html><body>Just a moment...</body></html>",
        "https://ncode.syosetu.com/n9669bk/5/",
    )
    .unwrap();
    assert_eq!(s.ingest(&empty).status, IngestStatus::Empty);
    assert_eq!(s.state().chapters.len(), 1);
}

#[test]
fn session_dedupes_by_content_hash() {
    let mut s = NovelSession::new();
    s.ingest(&syosetu(1));
    let mut same = syosetu(1);
    same.url = "https://ncode.syosetu.com/n9669bk/1/?p=2".into();
    assert_eq!(s.ingest(&same).status, IngestStatus::Updated);
    assert_eq!(s.state().chapters.len(), 1);
}

#[test]
fn session_tail_next_skips_toc_and_known_chapters() {
    let mut s = NovelSession::new();
    let mut last = syosetu(9);
    last.toc = Some("https://ncode.syosetu.com/n9669bk/".into());
    last.next = Some("https://ncode.syosetu.com/n9669bk/".into());
    s.ingest(&last);
    assert!(s.state().tail_next.is_none());
    assert!(s.state().queue.is_empty());
}

#[test]
fn snapshot_round_trips_and_rejects_garbage() {
    let mut s = NovelSession::new();
    s.ingest(&syosetu(1));
    s.ingest(&syosetu(2));
    let json = s.snapshot_json().unwrap();
    let v: Value = serde_json::from_slice(&json).unwrap();
    assert_eq!(v["type"], SNAPSHOT_TYPE);
    assert_eq!(v["workKey"], "ncode.syosetu.com/n9669bk");
    assert_eq!(v["workTitle"], "無職転生　- 異世界行ったら本気だす -");
    assert_eq!(v["chapters"].as_array().unwrap().len(), 2);
    let restored = NovelSession::restore(&json).unwrap();
    assert_eq!(restored.state().chapters, s.state().chapters);
    assert_eq!(restored.state().tail_next, s.state().tail_next);
    assert!(NovelSession::restore(b"{\"type\":\"other\",\"version\":1}").is_err());
    assert!(NovelSession::restore(b"{nope").is_err());
    assert!(NovelSession::restore(b"")
        .unwrap()
        .state()
        .chapters
        .is_empty());
}

// ── C ABI ────────────────────────────────────────────────────────────────

fn take(ptr: *mut u8, len: usize) -> Vec<u8> {
    assert!(!ptr.is_null(), "NULL from FFI");
    let v = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
    unsafe { fwc_bytes_free(ptr, len) };
    v
}

fn split_frame(frame: &[u8]) -> (Value, String) {
    let n = u32::from_le_bytes(frame[..4].try_into().unwrap()) as usize;
    let header: Value = serde_json::from_slice(&frame[4..4 + n]).unwrap();
    (header, String::from_utf8(frame[4 + n..].to_vec()).unwrap())
}

#[test]
fn ffi_session_round_trip() {
    use super::ffi::*;
    let html = input("syosetu_n9669bk_1.html");
    let url = "https://ncode.syosetu.com/n9669bk/1/";
    unsafe {
        let session = fwc_novel_session_open(std::ptr::null(), 0);
        assert!(!session.is_null());
        let mut len = 0usize;
        let p = fwc_novel_session_ingest(
            session,
            html.as_ptr(),
            html.len(),
            url.as_ptr(),
            url.len(),
            &mut len,
        );
        let (header, body) = split_frame(&take(p, len));
        assert_eq!(header["ingest"]["status"], "added");
        assert_eq!(header["ingest"]["chapterCount"], 1);
        assert_eq!(header["article"]["title"], "プロローグ");
        assert!(body.starts_with("<p>　俺は34歳"));
        let p = fwc_novel_session_snapshot(session, &mut len);
        let snapshot = take(p, len);
        fwc_novel_session_close(session);

        let restored = fwc_novel_session_open(snapshot.as_ptr(), snapshot.len());
        assert!(!restored.is_null());
        let p = fwc_novel_session_ingest(
            restored,
            html.as_ptr(),
            html.len(),
            url.as_ptr(),
            url.len(),
            &mut len,
        );
        let (header, _) = split_frame(&take(p, len));
        assert_eq!(header["ingest"]["status"], "updated");
        fwc_novel_session_close(restored);

        let bad = b"{oops";
        assert!(fwc_novel_session_open(bad.as_ptr(), bad.len()).is_null());
        let p = fwc_article_work_key(url.as_ptr(), url.len(), &mut len);
        assert_eq!(take(p, len), b"ncode.syosetu.com/n9669bk");
        let bad_url = "nope";
        assert!(fwc_article_extract(
            html.as_ptr(),
            html.len(),
            bad_url.as_ptr(),
            bad_url.len(),
            &mut len
        )
        .is_null());
    }
}

// ── 耗时 ─────────────────────────────────────────────────────────────────

/// 用真实快照的段落重复拼一页 ~200 KB 的典型小说页（不入库全文）。
pub(crate) fn synthetic_200k_page() -> Vec<u8> {
    let html = String::from_utf8(input("syosetu_n9669bk_10.html")).unwrap();
    let start = html.find("<p id=\"L1\">").unwrap();
    let end = html[start..].find("</div>").unwrap() + start;
    let paragraphs = &html[start..end];
    let mut body = String::new();
    while body.len() < 170_000 {
        body.push_str(paragraphs);
    }
    let mut out = String::with_capacity(html.len() + body.len());
    out.push_str(&html[..start]);
    out.push_str(&body);
    out.push_str(&html[end..]);
    out.into_bytes()
}

#[test]
fn extract_200k_page_timing() {
    let page = synthetic_200k_page();
    assert!(page.len() > 190_000, "{}", page.len());
    let mut times: Vec<Duration> = Vec::new();
    for (url, label) in [
        ("https://ncode.syosetu.com/n9669bk/10/", "site"),
        ("https://mirror.example/n9669bk/10/", "generic"),
    ] {
        times.clear();
        let mut article = None;
        for _ in 0..7 {
            let t = Instant::now();
            article = Some(extract(&page, url).unwrap());
            times.push(t.elapsed());
        }
        times.sort();
        let a = article.unwrap();
        println!(
            "[article timing] {label}: {} KB page → {} chars / {} paragraphs, median {:?} (min {:?}, max {:?}, method {})",
            page.len() / 1024,
            a.chars,
            a.paragraphs,
            times[times.len() / 2],
            times[0],
            times[times.len() - 1],
            a.method,
        );
        assert!(a.chars > 20_000);
        // 宽松上界（CI 机器慢、debug 构建更慢）：只防数量级回退。
        assert!(times[times.len() / 2] < Duration::from_secs(2));
    }
}
