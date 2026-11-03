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
                    // 每四条笔记里一张卡继承前一条笔记（另一台设备的）那张卡的历史：前身有新日志时后继也要刷。
                    if n % 4 == 3 {
                        let card = crate::registers::card_id(&note, "t1", 0).unwrap();
                        let from = crate::registers::card_id(&note_id(n - 1), "t1", 0).unwrap();
                        input.push(json!({"e": edit("card", &card, &format!("historyFrom/{from}"), json!(true)), "note": note}));
                    }
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
    // 逐条投递：各片记下待刷新；新设备收段通道：各片只追加，待刷新在收尾折叠时才记。
    assert!(count(d, "SELECT COUNT(*) FROM sync2_cache_pending") > 0 || count(d, "SELECT COUNT(*) FROM sync2_boot") == 1);
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

/// [sequential] = 关掉新设备收段通道（channel.rs），按逐条投递收。
fn in_mode<T>(sequential: bool, f: impl FnOnce() -> T) -> T {
    if sequential {
        super::channel::sequential(f)
    } else {
        f()
    }
}

fn hold(d: &Device) -> bool {
    d.core.ingest_holds_cache.load(std::sync::atomic::Ordering::Relaxed)
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
    // 新设备收段通道与逐条投递两种收法都要刷到与全量重建相同。
    for sequential in [false, true] {
        for (batch, slice) in [(1, 3), (2, 7), (3, 1)] {
            let d = Device::new("cp-join");
            // 测试里一块 [CACHE_PENDING_CHUNK] = 5 个实体：收尾要分好几块（「还有剩 → `more` → `replay_pending` 接着刷」）。
            let calls = in_mode(sequential, || {
                join_sliced(&d, &deck, &bucket, batch, slice, false);
                finish_session(&d, &deck, T0 + 50 * DAY)
            });
            assert!(calls > 1, "the drain must span several chunks (calls={calls} sequential={sequential})");
            assert_eq!(caches(&d), caches(&reference), "batch={batch} slice={slice} sequential={sequential}");
        }
    }
}

/// 收尾前会话丢了（进程被杀 / 关库）：待刷新集合留在库里，`plan` 报 `finishPending`；下一轮没有新段也开会话
/// 收尾，就把缓存刷到与全量重建相同。
#[test]
fn interrupted_session_refreshes_pending_caches_on_the_next_finish() {
    interrupted_session_refreshes(true);
    interrupted_session_refreshes(false);
}

fn interrupted_session_refreshes(sequential: bool) {
    let (bucket, deck) = world(8, 4);
    let reference = join_rebuilt(&deck, &bucket);
    let d = Device::new("cp-int");
    in_mode(sequential, || join_sliced(&d, &deck, &bucket, 2, 5, false));
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
    // 逐条投递的各片才记待刷新（新设备收段通道在收尾折叠时才记）。
    super::channel::sequential(|| join_sliced(&d, &deck, &bucket, 1, 4, false));
    assert!(count(&d, "SELECT COUNT(*) FROM sync2_cache_pending") > 0);
    cmd(&d, &deck, json!({"op": "rebuild_caches"}), vec![]);
    assert_eq!(count(&d, "SELECT COUNT(*) FROM sync2_cache_pending"), 0);
}

/// 每台设备 gen 最大的 head（同 tests.rs `Device::sync`）。
fn top_heads(b: &Bucket) -> Vec<Vec<u8>> {
    let mut by_dev: std::collections::BTreeMap<String, Vec<(u64, Vec<u8>)>> = std::collections::BTreeMap::new();
    for (path, bytes) in &b.0 {
        let parts: Vec<&str> = path.split('/').collect();
        if let Some(g) = parts.last().and_then(|p| crate::sync2::segment::parse_head_file_name(p)) {
            by_dev.entry(parts[parts.len() - 2].to_owned()).or_default().push((g, bytes.clone()));
        }
    }
    let mut out = Vec::new();
    for (_, hs) in by_dev {
        let top = hs.iter().map(|x| x.0).max().unwrap();
        out.extend(hs.into_iter().filter(|x| x.0 == top).map(|x| x.1));
    }
    out
}

/// 老设备追赶：前身卡所在的笔记被改、前身卡有新复习，后继卡（继承前身历史，属于另一条笔记）自己没有新事件。收尾
/// 先在笔记块里刷前身卡（transport.rs `settle_refreshed_cards` 把它从之后的卡块里去掉），后继卡缓存行里继承的历史
/// 仍要跟着刷新——与全量重建逐行相同。
#[test]
fn catch_up_refreshes_successors_of_cards_refreshed_through_their_notes() {
    let (mut bucket, deck) = world(8, 3);
    let d = Device::new("cp-catch");
    join_sliced(&d, &deck, &bucket, 2, 5, true);
    // 另一台设备加入后改笔记 0、1、2、4、5、6，暂停笔记 2 的卡（不触发重放：重放改写的卡会进第一块）；笔记 3 的卡
    // 继承笔记 2 那张卡的历史与标志（[world]）。待刷新集合按 (种类, ID) 取：第一块是笔记 0–5（刷笔记 2 时重算前身卡），
    // 第二块是笔记 6 与前身卡。
    let w = Device::new("cp-writer");
    let now = T0 + 60 * DAY;
    w.sync(&mut bucket, "loc", now);
    let note = note_id(2);
    let pred = crate::registers::card_id(&note, "t1", 0).unwrap();
    let mut input: Vec<Value> =
        [0, 1, 2, 4, 5, 6].iter().map(|&n| json!({"e": edit("note", &note_id(n), "f/fa", json!(format!("改{n}"))), "note": note_id(n)})).collect();
    input.push(json!({"e": edit("card", &pred, "suspended", json!(true)), "note": note}));
    w.core.sync2_apply_local(P, now, &Value::Array(input).to_string()).unwrap();
    w.sync(&mut bucket, "loc", now + 1);
    let succ = crate::registers::card_id(&note_id(3), "t1", 0).unwrap();
    let row = |x: &Device| x.rows(&format!("SELECT * FROM srs_cards_cache WHERE id = srs_id('{succ}')"))[1][1..].to_vec();
    let before = row(&d);

    let later = now + DAY;
    cmd(&d, &deck, json!({"op": "plan"}), top_heads(&bucket));
    cmd(&d, &deck, json!({"op": "ingest_begin"}), vec![]);
    cmd(&d, &deck, json!({"op": "ingest_prepare"}), segs(&bucket));
    while cmd(&d, &deck, json!({"op": "ingest_commit", "now": later, "sliceOps": 2}), vec![])["more"] == json!(true) {}
    finish_session(&d, &deck, later);

    let reference = join_rebuilt(&deck, &bucket);
    assert_ne!(
        row(&reference),
        before,
        "the successor inherits the predecessor's flags"
    );
    assert_eq!(caches(&d), caches(&reference));
}

/// 丢弃 profile 时连同收段会话一起放掉留着的页缓存。
#[test]
fn purging_the_profile_releases_the_held_cache() {
    let (bucket, deck) = world(2, 1);
    let d = Device::new("cp-purge");
    join_sliced(&d, &deck, &bucket, 1, 4, false);
    d.core.profile_purge(P).unwrap();
    assert!(!hold(&d));
    assert_eq!(count(&d, "SELECT COUNT(*) FROM sync2_boot") + count(&d, "SELECT COUNT(*) FROM sync2_boot_order"), 0, "the channel goes with the profile");
}

/// 会话怎么结束，留着的页缓存就怎么放掉（不靠下一轮碰巧收尾）：Dart 中途收手 / 出错发的 `ingest_end` 放掉会话
/// 与页缓存，之后的片明确失败；待刷新集合还在，下一轮照样收尾。
#[test]
fn ending_an_unfinished_session_releases_the_held_cache() {
    let (bucket, deck) = world(4, 2);
    let reference = join_rebuilt(&deck, &bucket);
    let d = Device::new("cp-end");
    join_sliced(&d, &deck, &bucket, 1, 4, false);
    cmd(&d, &deck, json!({"op": "ingest_end"}), vec![]);
    assert!(!hold(&d), "ingest_end releases the held page cache");
    let err = d.core.sync2_ingest_batch(P, Vec::new(), None, T0).unwrap_err();
    assert!(err.contains("no ingest session"), "{err}");
    // 再发一次（已经没有会话）是空操作。
    cmd(&d, &deck, json!({"op": "ingest_end"}), vec![]);
    assert!(!hold(&d));
    let plan = cmd(&d, &deck, json!({"op": "plan"}), heads(&bucket));
    assert_eq!(plan["finishPending"], json!(true), "{plan}");
    cmd(&d, &deck, json!({"op": "ingest_begin"}), vec![]);
    finish_session(&d, &deck, T0 + 51 * DAY);
    assert_eq!(caches(&d), caches(&reference));
}

/// 会话因出错作废（这里是投递时发现本机身份在会话期间被换过）时同样回到没有会话，不留页缓存。
#[test]
fn a_session_voided_by_an_error_releases_the_held_cache() {
    let (bucket, deck) = world(2, 1);
    let d = Device::new("cp-fail");
    let now = T0 + 50 * DAY;
    cmd(&d, &deck, json!({"op": "identity", "now": now}), vec![]);
    cmd(&d, &deck, json!({"op": "plan"}), heads(&bucket));
    cmd(&d, &deck, json!({"op": "ingest_begin"}), vec![]);
    cmd(&d, &deck, json!({"op": "ingest_prepare"}), segs(&bucket));
    assert!(hold(&d));
    d.core.sync2_rotate(P, now).unwrap();
    let req = json!({"op": "ingest_commit", "profile": P, "caches": {"defaultDeck": deck}, "now": now});
    let err = crate::store::ffi::sync2_dispatch(&d.core, &req, &mut Vec::new(), &mut Vec::new()).unwrap_err();
    assert!(err.contains("local identity changed"), "{err}");
    assert!(!hold(&d), "a session voided by an error releases the held page cache");
}

/// 老设备追积压：本机已有缓存行的卡在投递的那一片里当场刷新（复习队列直接读缓存行，不能按旧的 due 排队到收尾），
/// 新笔记 / 新卡才推迟到收尾；收尾后与全量重建逐行相同。
#[test]
fn catch_up_refreshes_existing_cache_rows_in_the_slice() {
    let (mut bucket, deck) = world(4, 2);
    let d = Device::new("cp-old");
    join_sliced(&d, &deck, &bucket, 2, 5, true);
    // 另一台设备加入，在已有的卡上接着复习，再加一条新笔记。
    let w = Device::new("cp-other");
    let now = T0 + 60 * DAY;
    w.sync(&mut bucket, "loc", now);
    let old_card = crate::registers::card_id(&note_id(1), "t1", 0).unwrap();
    let fresh = note_id(99);
    let fresh_card = crate::registers::card_id(&fresh, "t1", 0).unwrap();
    let input = vec![
        json!({"e": review("late-r1", &old_card, now - DAY, 3, "review"), "note": note_id(1)}),
        json!({"e": json!({"t": "entity", "x": {"id": fresh, "p": P, "k": "note", "d": {"createdAt": 1, "guid": fresh, "noteTypeId": "NT"}}}), "note": fresh}),
        json!({"e": edit("note", &fresh, "f/fa", json!("新")), "note": fresh}),
        json!({"e": review("late-r2", &fresh_card, now - DAY, 3, "learn"), "note": fresh}),
    ];
    w.core.sync2_apply_local(P, now, &Value::Array(input).to_string()).unwrap();
    w.sync(&mut bucket, "loc", now + 1);
    let reference = join_rebuilt(&deck, &bucket);
    // 这张卡的缓存行（去掉刷新时刻 `updated_at`）；没有行 = None。
    let row = |x: &Device, id: &str| -> Option<Vec<String>> {
        let cols: Vec<String> = x.rows("SELECT name FROM pragma_table_info('srs_cards_cache') WHERE name != 'updated_at' ORDER BY cid")[1..]
            .iter()
            .map(|r| format!("quote({})", r[0]))
            .collect();
        x.rows(&format!("SELECT {} FROM srs_cards_cache WHERE id = srs_id('{id}')", cols.join(", "))).get(1).cloned()
    };
    let before = row(&d, &old_card).expect("the old device has a cache row for the card");
    assert!(!before.contains(&"'late-r1'".to_owned()));

    let later = now + DAY;
    cmd(&d, &deck, json!({"op": "plan"}), top_heads(&bucket));
    cmd(&d, &deck, json!({"op": "ingest_begin"}), vec![]);
    cmd(&d, &deck, json!({"op": "ingest_prepare"}), segs(&bucket));
    let mut refreshed = Vec::new();
    loop {
        let r = cmd(&d, &deck, json!({"op": "ingest_commit", "now": later, "sliceOps": 2}), vec![]);
        refreshed.extend(r["cache"]["cards"].as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_owned));
        if r["more"] != json!(true) {
            break;
        }
    }
    // 收尾之前：已有的卡在投递它的那一片里就刷过，缓存行已经带上新收的那条复习（重放改写的派生状态照旧在收尾时
    // 定下：这里的测试日志没带真实的调度结果）；新卡还没有缓存行、在待刷新集合里。
    assert!(refreshed.contains(&old_card), "{refreshed:?}");
    let mid = row(&d, &old_card).unwrap();
    assert!(mid.contains(&"'late-r1'".to_owned()), "an existing cache row is refreshed in the slice: {mid:?}");
    assert_eq!(row(&d, &fresh_card), None, "a new card waits for the finish");
    assert!(count(&d, "SELECT COUNT(*) FROM sync2_cache_pending") > 0);
    finish_session(&d, &deck, later);
    assert_eq!(caches(&d), caches(&reference));
}
