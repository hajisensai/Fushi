//! 端到端：每台「设备」一个独立的 srs.db，经一个内存哑存储（只会按路径存取字节）交换段与 head。

use std::collections::BTreeMap;

use serde_json::{json, Value};

use crate::store::SrsCore;

pub(crate) const P: &str = "0193a1b2-0000-7000-8000-00000000beef";

/// 内存哑存储：路径 → 字节。
#[derive(Default, Clone)]
pub(crate) struct Bucket(pub BTreeMap<String, Vec<u8>>);

pub(crate) struct Device {
    pub core: SrsCore,
    pub _dir: tempdir::Dir,
}

pub(crate) mod tempdir {
    pub struct Dir(pub std::path::PathBuf);
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    pub fn new(tag: &str) -> Dir {
        let p = std::env::temp_dir().join(format!("fushi-sync2-{tag}-{}", crate::sync2::id::Id::random().text()));
        std::fs::create_dir_all(&p).unwrap();
        Dir(p)
    }
}

impl Device {
    pub fn new(tag: &str) -> Device {
        let dir = tempdir::new(tag);
        let core = SrsCore::open(&dir.0.join("srs.db")).unwrap();
        Device { core, _dir: dir }
    }

    pub fn copy_of(other: &Device, tag: &str) -> Device {
        let dir = tempdir::new(tag);
        other.core.snapshot_into(&dir.0.join("srs.db"), false).unwrap();
        let core = SrsCore::open(&dir.0.join("srs.db")).unwrap();
        Device { core, _dir: dir }
    }

    pub fn apply(&self, now: i64, events: Vec<Value>) -> Value {
        let input: Vec<Value> = events.into_iter().map(|e| json!({"e": e, "note": "N1"})).collect();
        serde_json::from_str(&self.core.sync2_apply_local(P, now, &Value::Array(input).to_string()).unwrap()).unwrap()
    }

    /// 一轮同步（设计 §6.2）：先读全部 head → 拉缺的段 → 收（分叉在这一步发现并换身份）→ 再发段 → 写 head。
    /// 先读后写：同一身份的另一个安装刚写的 head 不会被自己这一轮的 head 盖掉视线。
    pub fn sync(&self, bucket: &mut Bucket, location: &str, now: i64) -> Value {
        self.core.sync2_identity(P, now).unwrap();
        // 每台设备取 gen 最大的 head；同一 gen 有两份（孪生）就都交给内核。
        let mut by_dev: BTreeMap<String, Vec<(u64, Vec<u8>)>> = BTreeMap::new();
        for (path, bytes) in &bucket.0 {
            let parts: Vec<&str> = path.split('/').collect();
            if parts.len() == 3 {
                if let Some(g) = crate::sync2::segment::parse_head_file_name(parts[2]) {
                    by_dev.entry(parts[1].to_owned()).or_default().push((g, bytes.clone()));
                }
            }
        }
        let mut heads: Vec<Vec<u8>> = Vec::new();
        for (_, hs) in by_dev {
            let top = hs.iter().map(|x| x.0).max().unwrap();
            heads.extend(hs.into_iter().filter(|x| x.0 == top).map(|x| x.1));
        }
        let plan = self.core.sync2_plan(P, &heads).unwrap();
        let mut fetched = Vec::new();
        for f in plan["fetch"].as_array().unwrap() {
            for name in f["files"].as_array().unwrap() {
                if let Some(b) = bucket.0.get(name.as_str().unwrap()) {
                    fetched.push(b.clone());
                }
            }
        }
        let out: Value = serde_json::from_str(&self.core.sync2_ingest(P, &fetched, None, now).unwrap()).unwrap();
        let (segs, upto) = self.core.sync2_outbox(P, location, None).unwrap();
        for (path, bytes) in segs {
            bucket.0.insert(path, bytes);
        }
        let (path, bytes, _) = self.core.sync2_head(P, location, upto, now).unwrap();
        bucket.0.insert(path, bytes);
        self.core.sync2_digest(P).unwrap();
        out
    }

    pub fn rows(&self, sql: &str) -> Vec<Vec<String>> {
        let bytes = self.core.debug_query(sql, &[]).unwrap();
        crate::store::rows::decode_for_tests(&bytes)
    }

    pub fn state(&self, card: &str) -> Value {
        let rows = self.rows(&format!("SELECT json FROM srs_review_logs WHERE card_id = '{card}'"));
        let jsons: Vec<&str> = rows.iter().skip(1).map(|r| r[0].as_str()).collect();
        let st = crate::history::state_from_json(&jsons, &vec![None; jsons.len()]).unwrap();
        json!(format!("{st:?}"))
    }

    pub fn digest(&self) -> String {
        self.core.sync2_digest(P).unwrap()["digest"].as_str().unwrap().to_owned()
    }
}

pub(crate) fn deck_entity(id: &str) -> Value {
    json!({"t": "entity", "x": {"id": id, "p": P, "k": "deck", "d": {"createdAt": 1, "builtin": "default"}}})
}

pub(crate) fn edit(kind: &str, entity: &str, key: &str, v: Value) -> Value {
    json!({"t": "edit", "x": {
        "id": "ignored", "p": P, "k": kind, "e": entity, "f": key, "w": "dart", "s": 1,
        "ctx": {"vv": {}}, "v": v, "hlc": "0:0:dart", "ts": "anchored"
    }})
}

pub(crate) fn review(id: &str, card: &str, at: i64, rating: i64, rtype: &str) -> Value {
    json!({"t": "log", "x": {
        "id": id, "p": P, "card": card, "kind": "review", "rating": rating, "hlc": "0:0:dart", "at": at,
        "ts": "anchored", "origin": "fushi", "rtype": rtype, "utcOff": 0, "rollover": 4, "fv": 1,
        "res": {"queue": "new", "ivl": 0, "step": 0, "reps": 0, "lapses": 0, "scheduler": "fushi"}
    }})
}

const T0: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;

fn projection(d: &Device) -> Vec<Vec<String>> {
    let mut out = d.rows("SELECT id, json FROM srs_field_edits ORDER BY id");
    out.extend(d.rows("SELECT id, json FROM srs_review_logs ORDER BY id"));
    out.extend(d.rows("SELECT id, payload_json FROM srs_entities ORDER BY id"));
    out
}

#[test]
fn two_devices_converge_and_concurrent_reviews_all_count() {
    let a = Device::new("a");
    let b = Device::new("b");
    let mut bucket = Bucket::default();
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("Default"))]);
    a.sync(&mut bucket, "loc", T0);
    b.sync(&mut bucket, "loc", T0);
    assert_eq!(projection(&a), projection(&b), "B received A's ops");

    // 离线各复习同一张卡（设计 §4.1 的例子）。
    a.apply(T0 + 10, vec![review("a1", "C", T0 + 10, 3, "learn")]);
    b.apply(T0 + 2 * 3_600_000, vec![review("b1", "C", T0 + 2 * 3_600_000, 2, "learn")]);
    a.apply(T0 + DAY + 1_800_000, vec![review("a2", "C", T0 + DAY + 1_800_000, 1, "review")]);
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + 2 * DAY);
        b.sync(&mut bucket, "loc", T0 + 2 * DAY);
    }
    assert_eq!(projection(&a), projection(&b), "same op set → same projection, row for row");
    assert_eq!(a.state("C"), b.state("C"));
    assert!(a.state("C").as_str().unwrap().contains("reps: 3"), "{}", a.state("C"));
    assert_eq!(a.digest(), b.digest());

    // 同一顺序在单台设备上依次复习得到的状态与合并结果相同（重放而非覆盖）。
    let solo = Device::new("solo");
    solo.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("Default"))]);
    solo.apply(T0 + 10, vec![review("a1", "C", T0 + 10, 3, "learn")]);
    solo.apply(T0 + 2 * 3_600_000, vec![review("b1", "C", T0 + 2 * 3_600_000, 2, "learn")]);
    solo.apply(T0 + DAY + 1_800_000, vec![review("a2", "C", T0 + DAY + 1_800_000, 1, "review")]);
    let res = |d: &Device| d.rows("SELECT id, json_extract(json, '$.res') FROM srs_review_logs ORDER BY id");
    assert_eq!(res(&a), res(&solo));
}

#[test]
fn delivery_order_and_duplicates_do_not_matter() {
    let a = Device::new("a");
    let b = Device::new("b");
    let c = Device::new("c");
    let deck = super::config::default_deck_id(P);
    let mut bucket = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck)]);
    for i in 0..30 {
        a.apply(T0 + i * 1000, vec![edit("note", "N1", "f/x", json!(format!("a{i}")))]);
        b.apply(T0 + i * 1000 + 500, vec![edit("note", "N1", "f/x", json!(format!("b{i}")))]);
        a.apply(T0 + i * 7_200_000, vec![review(&format!("ra{i}"), "C", T0 + i * 7_200_000, 1 + i % 4, "learn")]);
        b.apply(T0 + i * 7_200_000 + 60_000, vec![review(&format!("rb{i}"), "C", T0 + i * 7_200_000 + 60_000, 1 + (i + 1) % 4, "learn")]);
    }
    // C 先收 B 再收 A（顺序与 A、B 各自不同），而且收两遍。
    b.sync(&mut bucket, "loc", T0 + 99 * DAY);
    c.sync(&mut bucket, "loc", T0 + 99 * DAY);
    a.sync(&mut bucket, "loc", T0 + 99 * DAY);
    for _ in 0..2 {
        c.sync(&mut bucket, "loc", T0 + 99 * DAY);
        b.sync(&mut bucket, "loc", T0 + 99 * DAY);
        a.sync(&mut bucket, "loc", T0 + 99 * DAY);
    }
    assert_eq!(projection(&a), projection(&b));
    assert_eq!(projection(&b), projection(&c));
    assert_eq!(a.digest(), c.digest());
    // 两边并发写同一字段：多值寄存器保留两个现存值（不静默丢），三端一致。
    let live = a.rows("SELECT COUNT(*) FROM srs_field_edits WHERE field_key = 'f/x'");
    assert_eq!(live[1][0], "2");
}

#[test]
fn cloned_data_directory_forks_and_rotates_without_losing_anything() {
    let a = Device::new("a");
    let deck = super::config::default_deck_id(P);
    let mut bucket = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("Default"))]);
    a.sync(&mut bucket, "loc", T0);
    // 把数据目录整个拷到「新手机」：同一个 DeviceId、同一个 seq，开始各写各的。
    let twin = Device::copy_of(&a, "twin");
    a.apply(T0 + 1000, vec![review("ra", "C", T0 + 1000, 3, "learn"), edit("note", "N1", "f/x", json!("from-a"))]);
    twin.apply(T0 + 2000, vec![review("rt", "C", T0 + 2000, 4, "learn"), edit("note", "N1", "f/x", json!("from-twin"))]);
    let observer = Device::new("obs");
    a.sync(&mut bucket, "loc", T0 + DAY);
    let t = twin.sync(&mut bucket, "loc", T0 + DAY);
    let s = a.sync(&mut bucket, "loc", T0 + DAY);
    assert!(t["fork"] == json!(true) || s["fork"] == json!(true), "a fork must be detected: {t} / {s}");
    for _ in 0..3 {
        a.sync(&mut bucket, "loc", T0 + DAY);
        twin.sync(&mut bucket, "loc", T0 + DAY);
        observer.sync(&mut bucket, "loc", T0 + DAY);
    }
    let ids = |d: &Device| d.rows("SELECT id FROM srs_review_logs ORDER BY id");
    for d in [&a, &twin, &observer] {
        let logs = ids(d);
        assert!(logs.iter().any(|r| r[0] == "ra") && logs.iter().any(|r| r[0] == "rt"), "both branches' reviews survive");
        let vals = d.rows("SELECT json_extract(json, '$.v') FROM srs_field_edits WHERE field_key = 'f/x' ORDER BY 1");
        let vals: Vec<&str> = vals.iter().skip(1).map(|r| r[0].as_str()).collect();
        assert!(vals.contains(&"from-a") && vals.contains(&"from-twin"), "both branches' edits survive: {vals:?}");
    }
    assert_eq!(ids(&a), ids(&observer));
    assert_eq!(a.state("C"), observer.state("C"));
    let devs = |d: &Device| d.core.sync2_status(P).unwrap()["device"].as_str().unwrap().to_owned();
    assert_ne!(devs(&a), devs(&twin), "at least one side took a new identity");
}

#[test]
fn migration_wraps_legacy_rows_and_keeps_projection() {
    let a = Device::new("a");
    // 旧库：直接写投影表（模拟 v2 之前的数据），再迁移。
    let deck = super::config::default_deck_id(P);
    let w = a.core.writer().unwrap();
    w.execute_batch(&format!(
        "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES ('{deck}', '{P}', 'deck', '{{\"createdAt\":1}}', 1);
         INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json) VALUES
           ('{e1}', '{P}', 'note', 'N1', 'f/x', 'old', 1, '{{\"ctx\":{{\"vv\":{{}}}},\"e\":\"N1\",\"f\":\"f/x\",\"hlc\":\"5:0:old\",\"id\":\"{e1}\",\"k\":\"note\",\"p\":\"{P}\",\"s\":1,\"ts\":\"wall\",\"v\":\"legacy\",\"w\":\"old\"}}');",
        e1 = crate::registers::edit_id("old", 1)
    ))
    .unwrap();
    drop(w);
    let before = projection(&a);
    let m = a.core.sync2_migrate(P, T0).unwrap();
    assert_eq!(m["ops"], json!(2));
    assert_eq!(projection(&a), before, "migration does not rewrite projection rows");
    // 迁移后的本机新写入因果覆盖旧记录（旧 dot 在新写入的上下文闭包里）。
    a.apply(T0 + 1, vec![edit("note", "N1", "f/x", json!("v2"))]);
    let vals = a.rows("SELECT json_extract(json, '$.v') FROM srs_field_edits WHERE field_key = 'f/x'");
    assert_eq!(vals.len(), 2, "{vals:?}");
    assert_eq!(vals[1][0], "v2");
    // 另一台设备从位置上收到全部操作（含迁移的旧记录），投影与 A 相同。
    let b = Device::new("b");
    let mut bucket = Bucket::default();
    a.sync(&mut bucket, "loc", T0 + 2);
    b.sync(&mut bucket, "loc", T0 + 2);
    assert_eq!(projection(&a), projection(&b));
}

/// 从备份快照恢复（快照剥掉了本机同步身份）= 一台新设备：拿新身份，原设备之后的操作照常续收（设计 §7.3）。
#[test]
fn restoring_a_backup_snapshot_is_a_new_device_not_a_fork() {
    let a = Device::new("a");
    let deck = super::config::default_deck_id(P);
    let mut bucket = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck), review("r1", "C", T0, 3, "learn")]);
    a.sync(&mut bucket, "loc", T0);
    let dir = tempdir::new("restore");
    a.core.snapshot_into(&dir.0.join("srs.db"), true).unwrap();
    a.apply(T0 + 1000, vec![review("r2", "C", T0 + 1000, 3, "learn")]);
    a.sync(&mut bucket, "loc", T0 + 1000);
    let restored = Device { core: SrsCore::open(&dir.0.join("srs.db")).unwrap(), _dir: dir };
    let out = restored.sync(&mut bucket, "loc", T0 + 2000);
    assert_eq!(out["fork"], json!(false));
    let me = |d: &Device| d.core.sync2_status(P).unwrap()["device"].as_str().unwrap().to_owned();
    assert_ne!(me(&a), me(&restored));
    restored.apply(T0 + 3000, vec![review("r3", "C", T0 + 3000, 1, "learn")]);
    for _ in 0..2 {
        restored.sync(&mut bucket, "loc", T0 + 4000);
        a.sync(&mut bucket, "loc", T0 + 4000);
    }
    assert_eq!(projection(&a), projection(&restored));
    assert_eq!(a.rows("SELECT COUNT(*) FROM srs_review_logs")[1][0], "3");
}

mod convergence {
    //! 性质测试（设计 §12.1 / §12.2）：随机 2–4 台设备、随机写入（同一批字段的并发写、同几张卡的复习、
    //! 牌组配置改动、撤销、改期）、随机同步日程（谁先谁后、重复、部分设备长期离线）——最后全体互通
    //! 之后，投影逐行相同、摘要相同、每张卡的重放状态相同。

    use super::*;
    use proptest::prelude::*;

    #[derive(Debug, Clone)]
    enum Act {
        Edit { dev: usize, field: u8, val: u16 },
        Review { dev: usize, card: u8, rating: u8, dt_min: u16 },
        SetDue { dev: usize, card: u8, due: u8 },
        Steps { dev: usize, first: u8 },
        Undo { dev: usize, card: u8 },
        /// C3 继承某张卡的历史（更改笔记类型的血统，historyFrom）。
        Lineage { dev: usize, from: u8 },
        Retention { dev: usize, pct: u8 },
        Sync { dev: usize },
    }

    fn act(n: usize) -> impl Strategy<Value = Act> {
        prop_oneof![
            (0..n, 0..3u8, any::<u16>()).prop_map(|(dev, field, val)| Act::Edit { dev, field, val }),
            (0..n, 0..3u8, 1..5u8, 0..3000u16).prop_map(|(dev, card, rating, dt_min)| Act::Review { dev, card, rating, dt_min }),
            (0..n, 0..3u8, 0..60u8).prop_map(|(dev, card, due)| Act::SetDue { dev, card, due }),
            (0..n, 1..30u8).prop_map(|(dev, first)| Act::Steps { dev, first }),
            (0..n, 0..3u8).prop_map(|(dev, card)| Act::Undo { dev, card }),
            (0..n, 0..3u8).prop_map(|(dev, from)| Act::Lineage { dev, from }),
            (0..n, 70..97u8).prop_map(|(dev, pct)| Act::Retention { dev, pct }),
            (0..n).prop_map(|dev| Act::Sync { dev }),
            (0..n).prop_map(|dev| Act::Sync { dev }),
        ]
    }

    fn scenario() -> impl Strategy<Value = (usize, Vec<Act>)> {
        (2..5usize).prop_flat_map(|n| (Just(n), prop::collection::vec(act(n), 1..40)))
    }

    proptest! {
        #![proptest_config(ProptestConfig {
            cases: std::env::var("PROPTEST_CASES").ok().and_then(|v| v.parse().ok()).unwrap_or(24),
            .. ProptestConfig::default()
        })]
        #[test]
        fn all_replicas_converge((n, acts) in scenario()) {
            let deck = super::super::config::default_deck_id(P);
            let devs: Vec<Device> = (0..n).map(|i| Device::new(&format!("p{i}"))).collect();
            let mut bucket = Bucket::default();
            devs[0].apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("Default"))]);
            let mut clock = vec![T0; n];
            let mut k = 0u32;
            // 每台设备每张卡最后一条自己写的评分（撤销只撤它，Dart 侧的 canUndo 同一约束由界面保证）。
            let mut last_review: std::collections::HashMap<(usize, u8), String> = std::collections::HashMap::new();
            for a in &acts {
                k += 1;
                match a {
                    Act::Edit { dev, field, val } => {
                        clock[*dev] += 1000;
                        devs[*dev].apply(clock[*dev], vec![edit("note", "N1", &format!("f/{field}"), json!(format!("{val}")))]);
                    }
                    Act::Review { dev, card, rating, dt_min } => {
                        clock[*dev] += i64::from(*dt_min) * 60_000 + 1;
                        let rtype = if *rating == 1 { "relearn" } else { "learn" };
                        let id = format!("r{dev}-{k}");
                        devs[*dev].apply(clock[*dev], vec![review(&id, &format!("C{card}"), clock[*dev], i64::from(*rating), rtype)]);
                        last_review.insert((*dev, *card), id);
                    }
                    Act::SetDue { dev, card, due } => {
                        clock[*dev] += 5000;
                        let mut m = review(&format!("m{dev}-{k}"), &format!("C{card}"), clock[*dev], 0, "manual");
                        m["x"]["kind"] = json!("manual");
                        m["x"].as_object_mut().unwrap().remove("rating");
                        m["x"]["res"] = json!({"queue": "review", "dueDay": 19_700 + i64::from(*due), "ivl": 3, "step": 0, "reps": 1, "lapses": 0, "scheduler": "fushi"});
                        devs[*dev].apply(clock[*dev], vec![m]);
                    }
                    Act::Steps { dev, first } => {
                        clock[*dev] += 1000;
                        devs[*dev].apply(clock[*dev], vec![edit("deck", &deck, "steps", json!({"learn": [f64::from(*first), 60.0], "relearn": [10.0]}))]);
                    }
                    Act::Undo { dev, card } => {
                        if let Some(target) = last_review.remove(&(*dev, *card)) {
                            clock[*dev] += 1000;
                            let u = json!({"t": "log", "x": {
                                "id": format!("u{dev}-{k}"), "p": P, "card": format!("C{card}"), "kind": "undo", "revokes": target,
                                "hlc": "0:0:dart", "at": clock[*dev], "ts": "anchored", "origin": "fushi", "rtype": "manual",
                                "utcOff": 0, "rollover": 4, "fv": 1
                            }});
                            devs[*dev].apply(clock[*dev], vec![u]);
                        }
                    }
                    Act::Lineage { dev, from } => {
                        clock[*dev] += 1000;
                        devs[*dev].apply(clock[*dev], vec![edit("card", "C3", &format!("historyFrom/C{from}"), json!(true))]);
                    }
                    Act::Retention { dev, pct } => {
                        clock[*dev] += 1000;
                        devs[*dev].apply(clock[*dev], vec![edit("deck", &deck, "retention", json!(f64::from(*pct) / 100.0))]);
                    }
                    Act::Sync { dev } => {
                        devs[*dev].sync(&mut bucket, "loc", clock[*dev]);
                    }
                }
            }
            let end = *clock.iter().max().unwrap() + 1;
            for _ in 0..3 {
                for d in &devs {
                    d.sync(&mut bucket, "loc", end);
                }
            }
            let p0 = projection(&devs[0]);
            for d in &devs[1..] {
                prop_assert_eq!(&projection(d), &p0);
            }
            let d0 = devs[0].digest();
            for d in &devs[1..] {
                prop_assert_eq!(d.digest(), d0.clone());
            }
            for card in ["C0", "C1", "C2", "C3"] {
                let s0 = devs[0].state(card);
                for d in &devs[1..] {
                    prop_assert_eq!(d.state(card), s0.clone());
                }
            }
        }
    }
}

fn tags_of(d: &Device, note: &str) -> String {
    let r = d.rows(&format!("SELECT json_extract(json, '$.v') FROM srs_field_edits WHERE entity_id = '{note}' AND field_key = 'tags'"));
    assert!(r.len() <= 2, "exactly one tags row: {r:?}");
    r.get(1).map(|x| x[0].clone()).unwrap_or_default()
}

/// 标签 OR-Set（设计 §5.2）：一边加标签、一边并发删同一标签 → 保留；各自加不同标签 → 都在；删除只抹掉见过的。
#[test]
fn tags_are_an_add_wins_or_set() {
    let a = Device::new("a");
    let b = Device::new("b");
    let mut bucket = Bucket::default();
    let tag = |v: Value| edit("note", "N1", "tags", v);
    a.apply(T0, vec![tag(json!(["x", "y"]))]);
    a.sync(&mut bucket, "loc", T0);
    b.sync(&mut bucket, "loc", T0);
    assert_eq!(tags_of(&b, "N1"), r#"["x","y"]"#);
    // A 删掉 y、加 z；B 并发地「重新加」y 并加 w。
    a.apply(T0 + 1, vec![tag(json!(["x", "z"]))]);
    b.apply(T0 + 2, vec![tag(json!(["x", "y", "w"]))]);
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + 3);
        b.sync(&mut bucket, "loc", T0 + 3);
    }
    let ta = tags_of(&a, "N1");
    assert_eq!(ta, tags_of(&b, "N1"));
    for t in ["x", "z", "w"] {
        assert!(ta.contains(&format!("\"{t}\"")), "{t} in {ta}");
    }
    // B 「重新加 y」只是没变（y 已在）→ 没有新的添加点；A 的删除见过唯一的添加点 → y 没了。
    assert!(!ta.contains("\"y\""), "{ta}");
    // 之后 A 删掉 w（见过 B 的添加）→ 两边都没了。
    a.apply(T0 + 4, vec![tag(json!(["x", "z"]))]);
    a.sync(&mut bucket, "loc", T0 + 5);
    b.sync(&mut bucket, "loc", T0 + 5);
    assert!(!tags_of(&b, "N1").contains("\"w\""));
}

/// 删除 ⟂ 编辑（设计 §5.3）：不自动判输赢——删除被扣住、笔记保持可见，冲突进冲突中心；用户选了之后各端一致。
#[test]
fn delete_concurrent_with_edit_is_held_until_the_user_decides() {
    let a = Device::new("a");
    let b = Device::new("b");
    let mut bucket = Bucket::default();
    a.apply(T0, vec![edit("note", "N1", "f/x", json!("v1"))]);
    a.sync(&mut bucket, "loc", T0);
    b.sync(&mut bucket, "loc", T0);
    a.apply(T0 + 1, vec![edit("note", "N1", "deleted", json!(T0 + 1))]);
    b.apply(T0 + 2, vec![edit("note", "N1", "f/x", json!("edited on B"))]);
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + 3);
        b.sync(&mut bucket, "loc", T0 + 3);
    }
    let deleted = |d: &Device| d.rows("SELECT COUNT(*) FROM srs_field_edits WHERE entity_id = 'N1' AND field_key = 'deleted'")[1][0].clone();
    for d in [&a, &b] {
        assert_eq!(deleted(d), "0", "the delete is held: the note stays visible");
        let c = d.core.sync2_conflicts(P).unwrap();
        assert_eq!(c.as_array().unwrap().len(), 1, "{c}");
        assert_eq!(c[0]["kind"], json!("delete_edit"));
    }
    assert_eq!(projection(&a), projection(&b));
    // B 上选「删除」：一条覆盖双方的新删除。
    let id = b.core.sync2_conflicts(P).unwrap()[0]["id"].as_str().unwrap().to_owned();
    b.core.sync2_resolve(P, &id, true, T0 + 10).unwrap();
    for _ in 0..2 {
        b.sync(&mut bucket, "loc", T0 + 11);
        a.sync(&mut bucket, "loc", T0 + 11);
    }
    for d in [&a, &b] {
        assert_eq!(deleted(d), "1");
        assert!(d.core.sync2_conflicts(P).unwrap().as_array().unwrap().is_empty());
    }
    assert_eq!(projection(&a), projection(&b));
}

/// 删除笔记 ⟂ 另一台设备上复习它的卡：同样扣住（多留一张卡不丢任何东西）；选「保留」后笔记照旧在。
#[test]
fn delete_concurrent_with_review_is_held_and_keep_restores() {
    let a = Device::new("a");
    let b = Device::new("b");
    let deck = super::config::default_deck_id(P);
    let mut bucket = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck), edit("note", "N1", "f/x", json!("v1"))]);
    a.sync(&mut bucket, "loc", T0);
    b.sync(&mut bucket, "loc", T0);
    a.apply(T0 + 1, vec![edit("note", "N1", "deleted", json!(T0 + 1))]);
    b.apply(T0 + 2, vec![review("rb", "C1", T0 + 2, 3, "learn")]);
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + 3);
        b.sync(&mut bucket, "loc", T0 + 3);
    }
    let c = a.core.sync2_conflicts(P).unwrap();
    assert_eq!(c[0]["kind"], json!("delete_review"), "{c}");
    a.core.sync2_resolve(P, c[0]["id"].as_str().unwrap(), false, T0 + 4).unwrap();
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + 5);
        b.sync(&mut bucket, "loc", T0 + 5);
    }
    for d in [&a, &b] {
        let v = d.rows("SELECT json_extract(json, '$.v') FROM srs_field_edits WHERE entity_id = 'N1' AND field_key = 'deleted'");
        assert_eq!(v[1][0], "NULL", "restored (deleted = null)");
        assert!(d.core.sync2_conflicts(P).unwrap().as_array().unwrap().is_empty());
    }
    assert_eq!(projection(&a), projection(&b));
}

/// 彻底清除（设计 §10.5）：各设备本机日志里只剩骨架，投影里的内容没了，段被重写，链与签名照样可验证。
#[test]
fn purge_erases_content_everywhere_and_keeps_the_chain_valid() {
    let a = Device::new("a");
    let b = Device::new("b");
    let mut bucket = Bucket::default();
    a.apply(T0, vec![edit("note", "N1", "f/x", json!("secret text")), edit("note", "N1", "tags", json!(["private"]))]);
    a.sync(&mut bucket, "loc", T0);
    b.sync(&mut bucket, "loc", T0);
    b.apply(T0 + 1, vec![edit("note", "N1", "f/y", json!("more secret"))]);
    b.sync(&mut bucket, "loc", T0 + 1);
    a.sync(&mut bucket, "loc", T0 + 1);
    a.core.sync2_purge(P, "note", "N1", T0 + 2).unwrap();
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + 3);
        b.sync(&mut bucket, "loc", T0 + 3);
    }
    for d in [&a, &b] {
        let left = d.rows("SELECT field_key FROM srs_field_edits WHERE entity_id = 'N1'");
        assert_eq!(left.iter().skip(1).map(|r| r[0].as_str()).collect::<Vec<_>>(), vec!["deleted"]);
        let raw = d.rows("SELECT COUNT(*) FROM sync2_ops WHERE CAST(payload AS TEXT) LIKE '%secret%' OR CAST(payload AS TEXT) LIKE '%private%'");
        assert_eq!(raw[1][0], "0", "no content left in the local op log");
    }
    // 第三台新设备从位置上完整收下（被清除的骨架链照样接得上）。
    let c = Device::new("c");
    c.sync(&mut bucket, "loc", T0 + 4);
    assert_eq!(projection(&c), projection(&a));
    // 位置上的每个段都解开逐条看：内容已被各自的作者重写成骨架（不是只在本机抹掉）。
    let mut checked = 0;
    for (path, bytes) in &bucket.0 {
        if !path.contains("/seg-") {
            continue;
        }
        let dev = path.split('/').nth(1).unwrap();
        let public = c.rows(&format!("SELECT hex(public) FROM sync2_devices WHERE hex(device) = upper(replace('{dev}', '-', ''))"));
        let hexkey = &public[1][0];
        let key: [u8; 32] = (0..32).map(|i| u8::from_str_radix(&hexkey[2 * i..2 * i + 2], 16).unwrap()).collect::<Vec<_>>().try_into().unwrap();
        let seg = crate::sync2::segment::open(bytes, &key, None).unwrap();
        for op in &seg.ops {
            let text = String::from_utf8_lossy(&op.payload);
            assert!(!text.contains("secret") && !text.contains("private"), "segment {path} still carries content");
        }
        checked += 1;
    }
    assert!(checked >= 2);
}
