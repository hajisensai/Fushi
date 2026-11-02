//! 分批收段会话的缓存刷新推迟到收尾（transport.rs `defer_cache_refresh` / `take_cache_pending`，ffi.rs 分发器）：
//! 经生产的分发器（带缓存配置、`ingest_commit` 按条数切片、收尾按块刷新），新设备收齐后的三张缓存表与「一次
//! 收完再全量重建缓存」逐行相同；切片期间只记待刷新、不写缓存行；收尾前被打断（会话丢掉）时，下一轮 `plan`
//! 报 `finishPending`，再开会话收尾就把剩下的刷完。

use serde_json::{json, Value};

use super::tests::{deck_entity, edit, review, Bucket, Device, P};

const T0: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;

fn heads(b: &Bucket) -> Vec<Vec<u8>> {
    b.0.iter()
        .filter(|(k, _)| k.rsplit('/').next().and_then(crate::sync2::segment::parse_head_file_name).is_some())
        .map(|(_, v)| v.clone())
        .collect()
}

fn segs(b: &Bucket) -> Vec<Vec<u8>> {
    b.0.iter().filter(|(k, _)| k.contains("/seg-")).map(|(_, v)| v.clone()).collect()
}

/// 第 [n] 条笔记的 ID（卡 ID 由它派生，要是 UUID）。
fn note_id(n: usize) -> String {
    format!("0193a1b2-0000-7000-8000-{n:012x}")
}

/// 两台设备各自加笔记、交错复习（第二台的复习插在第一台的历史中间），各同步两轮。
fn world(notes: usize, reviews: usize) -> (Bucket, String) {
    let deck = super::config::default_deck_id(P);
    let devs = [Device::new("cp-a"), Device::new("cp-b")];
    let mut bucket = Bucket::default();
    devs[0].apply(
        T0,
        vec![
            deck_entity(&deck),
            edit("deck", &deck, "name", json!("D")),
            json!({"t": "entity", "x": {"id": "NT", "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            edit("notetype", "NT", "fieldDef/fa", json!({"name": "Expression", "ord": 0})),
            edit("notetype", "NT", "tmplDef/t1", json!({"name": "C", "ord": 0, "front": "{{Expression}}"})),
        ],
    );
    devs[0].sync(&mut bucket, "loc", T0);
    devs[1].sync(&mut bucket, "loc", T0);
    for wave in 0..2i64 {
        for (i, d) in devs.iter().enumerate() {
            let mut input = Vec::new();
            for n in (0..notes).filter(|n| n % 2 == i) {
                let note = note_id(n);
                if wave == 0 {
                    input.push(json!({"e": json!({"t": "entity", "x": {"id": note, "p": P, "k": "note", "d": {"createdAt": 1, "guid": note, "noteTypeId": "NT"}}}), "note": note}));
                    input.push(json!({"e": edit("note", &note, "f/fa", json!(format!("語{n}"))), "note": note}));
                }
                for r in 0..reviews as i64 {
                    let at = T0 + (wave * reviews as i64 + r) * DAY + i as i64 * 3_600_000;
                    let rtype = if wave == 0 && r == 0 { "learn" } else { "review" };
                    let card = crate::registers::card_id(&note, "t1", 0).unwrap();
                    let e = review(&format!("w{wave}d{i}n{n}r{r}"), &card, at, 1 + (r % 4), rtype);
                    input.push(json!({"e": e, "note": note}));
                }
            }
            d.core.sync2_apply_local(P, T0 + 40 * DAY + wave * DAY, &Value::Array(input).to_string()).unwrap();
        }
        for (i, d) in devs.iter().enumerate() {
            d.sync(&mut bucket, "loc", T0 + 41 * DAY + wave * DAY + i as i64);
        }
    }
    (bucket, deck)
}

/// 经分发器跑一条命令（生产 Dart `_sync2` 的形状：带 profile、缓存配置）。
fn cmd(d: &Device, deck: &str, mut req: Value, blobs: Vec<Vec<u8>>) -> Value {
    req["profile"] = json!(P);
    req["caches"] = json!({"defaultDeck": deck});
    let mut blobs = blobs;
    let mut files = Vec::new();
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files).unwrap()
}

/// 三张缓存表的全部行（去掉刷新时刻 `updated_at`，两条路径各自取墙钟）。
fn caches(d: &Device) -> Vec<Vec<Vec<String>>> {
    ["srs_notes_cache", "srs_cards_cache", "srs_stat_reviews"]
        .iter()
        .map(|t| {
            let cols: Vec<String> = d.rows(&format!("SELECT name FROM pragma_table_info('{t}') WHERE name != 'updated_at' ORDER BY cid"))
                [1..]
                .iter()
                .map(|r| r[0].clone())
                .collect();
            let sel: Vec<String> = cols.iter().map(|c| format!("quote({c})")).collect();
            d.rows(&format!("SELECT {} FROM {t} ORDER BY 1, 2, 3", sel.join(", ")))
        })
        .collect()
}

fn count(d: &Device, sql: &str) -> i64 {
    d.rows(sql)[1][0].parse().unwrap()
}

/// 新设备经分发器按分批会话收 [bucket]：段按 [batch] 个一批，投递每片 [slice] 条；收尾到 [finish] 为止
/// （`false` = 只投完各片、不收尾，模拟会话被打断）。
fn join_sliced(d: &Device, deck: &str, bucket: &Bucket, batch: usize, slice: usize, finish: bool) {
    let now = T0 + 50 * DAY;
    cmd(d, deck, json!({"op": "identity", "now": now}), vec![]);
    cmd(d, deck, json!({"op": "plan"}), heads(bucket));
    cmd(d, deck, json!({"op": "ingest_begin"}), vec![]);
    for chunk in segs(bucket).chunks(batch.max(1)) {
        cmd(d, deck, json!({"op": "ingest_prepare"}), chunk.to_vec());
        loop {
            let r = cmd(d, deck, json!({"op": "ingest_commit", "now": now, "sliceOps": slice}), vec![]);
            assert_eq!(r["cache"], json!({"notes": [], "cards": [], "removed": []}), "a slice must not refresh caches: {r}");
            if r["more"] != json!(true) {
                break;
            }
        }
    }
    assert_eq!(count(d, "SELECT COUNT(*) FROM srs_cards_cache"), 0, "no cache rows before the session finishes");
    assert!(count(d, "SELECT COUNT(*) FROM sync2_cache_pending") > 0);
    assert!(hold(d), "a session keeps the writer page cache between slices");
    if finish {
        finish_session(d, deck, now);
    }
}

/// 收尾：`ingest_finish`，`more` 就接着 `replay_pending`（生产 Dart `sync2IngestFinish`），每块 [CACHE_PENDING_CHUNK]。
fn finish_session(d: &Device, deck: &str, now: i64) -> usize {
    let mut r = cmd(d, deck, json!({"op": "ingest_finish", "now": now, "sliceOps": 1}), vec![]);
    let mut calls = 1;
    while r["more"] == json!(true) {
        r = cmd(d, deck, json!({"op": "replay_pending", "sliceOps": 1}), vec![]);
        calls += 1;
        assert!(calls < 10_000, "finish never converges");
    }
    assert_eq!(count(d, "SELECT COUNT(*) FROM sync2_cache_pending"), 0);
    assert_eq!(count(d, "SELECT COUNT(*) FROM sync2_replay_pending"), 0);
    assert!(!hold(d), "a finished session trims the writer page cache again");
    calls
}

fn hold(d: &Device) -> bool {
    d.core.ingest_hold_cache.load(std::sync::atomic::Ordering::Relaxed)
}

/// 参照：一次收完（不切片），再从事件全量重建缓存。
fn join_rebuilt(deck: &str, bucket: &Bucket) -> Device {
    let d = Device::new("cp-ref");
    let now = T0 + 50 * DAY;
    d.core.sync2_identity(P, now).unwrap();
    d.core.sync2_plan(P, &heads(bucket)).unwrap();
    d.core.sync2_ingest(P, &segs(bucket), None, now).unwrap();
    cmd(&d, deck, json!({"op": "rebuild_caches"}), vec![]);
    d
}

#[test]
fn deferred_cache_refresh_matches_a_full_rebuild() {
    let (bucket, deck) = world(12, 5);
    let reference = join_rebuilt(&deck, &bucket);
    assert!(count(&reference, "SELECT COUNT(*) FROM srs_cards_cache") > 0);
    assert!(count(&reference, "SELECT COUNT(*) FROM srs_stat_reviews") > 0);
    for (batch, slice) in [(1, 3), (2, 7), (3, 1)] {
        let d = Device::new("cp-join");
        join_sliced(&d, &deck, &bucket, batch, slice, true);
        assert_eq!(caches(&d), caches(&reference), "batch={batch} slice={slice}");
    }
}

/// 收尾前会话丢了（进程被杀 / 关库）：待刷新集合留在库里，`plan` 报 `finishPending`；下一轮没有新段也开会话
/// 收尾，就把缓存刷到与全量重建相同。
#[test]
fn interrupted_session_refreshes_pending_caches_on_the_next_finish() {
    let (bucket, deck) = world(8, 4);
    let reference = join_rebuilt(&deck, &bucket);
    let d = Device::new("cp-int");
    join_sliced(&d, &deck, &bucket, 2, 5, false);
    // 会话丢掉：重开一个会话（旧会话里的分叉点 / 预处理批次都没了），库里只剩各片已提交的部分。
    let plan = cmd(&d, &deck, json!({"op": "plan"}), heads(&bucket));
    assert_eq!(plan["finishPending"], json!(true), "{plan}");
    cmd(&d, &deck, json!({"op": "ingest_begin"}), vec![]);
    finish_session(&d, &deck, T0 + 51 * DAY);
    assert_eq!(caches(&d), caches(&reference));
    let plan = cmd(&d, &deck, json!({"op": "plan"}), heads(&bucket));
    assert_eq!(plan["finishPending"], json!(false), "{plan}");
}

/// 全量重建缓存会清掉待刷新集合（重建已覆盖它们）。
#[test]
fn rebuild_clears_the_pending_set() {
    let (bucket, deck) = world(4, 2);
    let d = Device::new("cp-rb");
    join_sliced(&d, &deck, &bucket, 1, 4, false);
    cmd(&d, &deck, json!({"op": "rebuild_caches"}), vec![]);
    assert_eq!(count(&d, "SELECT COUNT(*) FROM sync2_cache_pending"), 0);
}

/// 丢弃 profile 时连同收段会话一起放掉留着的页缓存。
#[test]
fn purging_the_profile_releases_the_held_cache() {
    let (bucket, deck) = world(2, 1);
    let d = Device::new("cp-purge");
    join_sliced(&d, &deck, &bucket, 1, 4, false);
    d.core.profile_purge(P).unwrap();
    assert!(!hold(&d));
}
