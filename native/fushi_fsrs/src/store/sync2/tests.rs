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

thread_local! {
    /// 测试开关：为真时同步助手里的「删位置上的文件」一律失败（模拟 `location.delete` 抛错 / head 上传失败后
    /// 没走到删除）——不删也不发 `obsolete_ack`，与生产 Dart 只确认删成功的那些同一语义。
    pub(crate) static FAIL_DELETES: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// 按生产（srs_sync2_round.dart）的两段式删除：删成功的才 `obsolete_ack`。[FAIL_DELETES] 打开时一个都不删。
fn delete_and_ack(core: &SrsCore, bucket: &mut Bucket, location: &str, paths: &[String]) {
    if FAIL_DELETES.with(|f| f.get()) {
        return;
    }
    for p in paths {
        bucket.0.remove(p);
    }
    core.sync2_obsolete_ack(P, location, paths).unwrap();
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
        self.sync_keyed(bucket, location, now, None)
    }

    /// 同 [Self::sync]，位置开了加密（[key] = 该位置的集合密钥）。
    pub fn sync_keyed(&self, bucket: &mut Bucket, location: &str, now: i64, key: Option<[u8; 32]>) -> Value {
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
        let plan = self.core.sync2_plan_at(P, &heads, Some(location)).unwrap();
        let mut fetched = Vec::new();
        for f in plan["fetch"].as_array().unwrap() {
            for name in f["files"].as_array().unwrap() {
                // 与生产同样：段名列不到就找同名转发件（`rly-`，store/sync2/relay.rs）。
                let name = name.as_str().unwrap();
                let (dir, file) = name.rsplit_once('/').unwrap();
                let relayed = format!("{dir}/{}", crate::sync2::segment::relay_file_name(file));
                if let Some(b) = bucket.0.get(name).or_else(|| bucket.0.get(&relayed)) {
                    fetched.push(b.clone());
                }
            }
        }
        let out: Value = serde_json::from_str(&self.core.sync2_ingest(P, &fetched, key, now).unwrap()).unwrap();
        let upto = self.upload_all_keyed(bucket, location, key);
        let (path, bytes, gen, obsolete) = self.core.sync2_head(P, location, upto, now).unwrap();
        let dir = path.rsplit_once('/').unwrap().0.to_owned();
        bucket.0.insert(path, bytes);
        delete_and_ack(&self.core, bucket, location, &obsolete);
        // 与生产（srs_sync2_round.dart 第 4 步）同样：删本机两代以前的 head。
        bucket.0.retain(|k, _| {
            !(k.starts_with(&format!("{dir}/"))
                && k.rsplit('/').next().and_then(crate::sync2::segment::parse_head_file_name).is_some_and(|g| g + 2 < gen))
        });
        self.relay_all(bucket, location, key);
        // 与生产同一节奏：版本向量变了且到期才重算（测试里间隔为 0 = 变了就算）。
        self.core.sync2_digest_due(P, now, Some(0)).unwrap();
        out
    }

    /// 与生产同一节奏的转发：取一批 → 写进 [bucket] → 确认（删掉被取代的旧转发件）→ 还有就再取。返回写的文件数。
    pub fn relay_all(&self, bucket: &mut Bucket, location: &str, key: Option<[u8; 32]>) -> usize {
        let mut n = 0;
        for _ in 0..1000 {
            let batch = self.core.sync2_relay_outbox(P, location, key, super::transport::OUTBOX_BATCH_BYTES).unwrap();
            if batch.files.is_empty() {
                return n;
            }
            let paths: Vec<String> = batch.files.iter().map(|f| f.0.clone()).collect();
            n += paths.len();
            for (path, bytes) in batch.files {
                bucket.0.insert(path, bytes);
            }
            let ack = self.core.sync2_relay_ack(P, location, &paths).unwrap();
            let gone: Vec<String> = ack["delete"].as_array().unwrap().iter().map(|p| p.as_str().unwrap().to_owned()).collect();
            delete_and_ack(&self.core, bucket, location, &gone);
            if !batch.more {
                return n;
            }
        }
        panic!("relay did not settle");
    }

    /// 与生产同一节奏的分批发件：取一批 → 全部写进 [bucket] → 确认 → 还有就再取。返回写 head 用的水位。
    pub fn upload_all(&self, bucket: &mut Bucket, location: &str) -> u64 {
        self.upload_all_keyed(bucket, location, None)
    }

    pub fn upload_all_keyed(&self, bucket: &mut Bucket, location: &str, key: Option<[u8; 32]>) -> u64 {
        use super::transport::{OUTBOX_BATCH_BYTES, OUTBOX_BATCH_SEGMENTS};
        loop {
            let batch = self.core.sync2_outbox(P, location, key, OUTBOX_BATCH_BYTES, OUTBOX_BATCH_SEGMENTS).unwrap();
            if batch.files.is_empty() {
                return batch.upto;
            }
            for (path, bytes) in batch.files {
                bucket.0.insert(path, bytes);
            }
            let (accepted, mark) = self.core.sync2_outbox_ack(P, location, &batch.segments).unwrap();
            assert!(accepted);
            assert_eq!(mark, batch.upto);
            if !batch.more {
                return mark;
            }
        }
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
        "id": id, "p": P, "card": card, "kind": "review", "rating": rating, "hlc": format!("{at}:0:dart"), "at": at,
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
    let m = a.core.sync2_migrate(P, T0, None).unwrap();
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
                                "hlc": format!("{}:0:dart", clock[*dev]), "at": clock[*dev], "ts": "anchored", "origin": "fushi", "rtype": "manual",
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
        // 按字节找（载荷是二进制，开头就有 0x00：CAST 成 TEXT 后 LIKE 永远匹配不到，断言会恒成立）。
        let raw = d.rows("SELECT COUNT(*) FROM sync2_ops WHERE instr(payload, CAST('secret' AS BLOB)) > 0 OR instr(payload, CAST('private' AS BLOB)) > 0");
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

/// 笔记 N1 现在投影里的（字段键 → 值），`deleted` 的 NULL 也列出来。
fn note_fields(d: &Device) -> BTreeMap<String, String> {
    d.rows("SELECT field_key, json_extract(json, '$.v') FROM srs_field_edits WHERE entity_id = 'N1' ORDER BY field_key")
        .into_iter()
        .skip(1)
        .map(|r| (r[0].clone(), r[1].clone()))
        .collect()
}

/// 清除之后又把同一条笔记导回来（BUG：删牌组选「永久删除」→ 重导 apkg，笔记 ID 由来源 guid 派生、仍是被清除
/// 的那个 ID）：作者见过清除的新内容是复活，照常落投影并传到别的设备；与清除并发的迟到旧内容照样清掉；
/// 再清除一次照样清干净。以前「实体清除过 → 之后到的内容操作一律清除」，导回来的笔记只剩空壳，每次再导入都
/// 计「已更新」却什么也看不见。
#[test]
fn content_written_after_seeing_a_purge_revives_the_entity_everywhere() {
    let a = Device::new("a");
    let b = Device::new("b");
    let mut bucket = Bucket::default();
    a.apply(T0, vec![edit("note", "N1", "f/x", json!("old text")), edit("note", "N1", "tags", json!(["old"]))]);
    a.sync(&mut bucket, "loc", T0);
    b.sync(&mut bucket, "loc", T0);
    // b 离线改了一下（与 a 的清除并发、清除之后才到）。
    b.apply(T0 + 1, vec![edit("note", "N1", "f/y", json!("stale concurrent"))]);
    a.core.sync2_purge(P, "note", "N1", T0 + 2).unwrap();
    // a 在清除之后把它导回来：清删除标记、写回内容与标签。
    a.apply(
        T0 + 3,
        vec![
            edit("note", "N1", "deleted", Value::Null),
            edit("note", "N1", "f/x", json!("imported again")),
            edit("note", "N1", "tags", json!(["back"])),
        ],
    );
    let want: BTreeMap<String, String> = [("deleted", "NULL"), ("f/x", "imported again"), ("tags", "[\"back\"]")]
        .into_iter()
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect();
    assert_eq!(note_fields(&a), want, "revived locally");
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + 4);
        b.sync(&mut bucket, "loc", T0 + 4);
    }
    for d in [&a, &b] {
        assert_eq!(note_fields(d), want, "revived content reached every device; the stale concurrent edit is gone");
        let raw = d.rows(
            "SELECT COUNT(*) FROM sync2_ops WHERE instr(payload, CAST('old text' AS BLOB)) > 0 \
             OR instr(payload, CAST('stale concurrent' AS BLOB)) > 0",
        );
        assert_eq!(raw[1][0], "0", "content the purge saw (or raced with) stays erased");
        assert!(d.core.sync2_conflicts(P).unwrap().as_array().unwrap().is_empty());
    }
    assert_eq!(projection(&a), projection(&b));
    // 第三台新设备从位置上完整收下：结论一样（判据只看因果，与收到的顺序无关）。
    let c = Device::new("c");
    c.sync(&mut bucket, "loc", T0 + 5);
    assert_eq!(projection(&c), projection(&a));

    // 再清除一次：复活的内容同样清掉。
    b.core.sync2_purge(P, "note", "N1", T0 + 6).unwrap();
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + 7);
        b.sync(&mut bucket, "loc", T0 + 7);
    }
    for d in [&a, &b] {
        let left: Vec<String> = note_fields(d).into_keys().collect();
        assert_eq!(left, vec!["deleted".to_owned()]);
        let raw = d.rows("SELECT COUNT(*) FROM sync2_ops WHERE instr(payload, CAST('imported again' AS BLOB)) > 0");
        assert_eq!(raw[1][0], "0");
    }
}

/// 修复之前执行过的清除只在 `sync2_purged` 里有标记、索引里没有清除操作：第一次碰到时从日志补索引，之后
/// 照样按因果判（老库里被清除过的笔记重导也能复活）。
#[test]
fn purge_recorded_before_the_index_existed_is_backfilled_from_the_log() {
    let a = Device::new("a");
    a.apply(T0, vec![edit("note", "N1", "f/x", json!("old text"))]);
    a.core.sync2_purge(P, "note", "N1", T0 + 1).unwrap();
    {
        let w = a.core.writer().unwrap();
        let n = w.execute("DELETE FROM sync2_ent_ops WHERE what = '#purge'", []).unwrap();
        assert_eq!(n, 1, "the purge op is indexed");
    }
    a.apply(T0 + 2, vec![edit("note", "N1", "deleted", Value::Null), edit("note", "N1", "f/x", json!("imported again"))]);
    let want: BTreeMap<String, String> =
        [("deleted", "NULL"), ("f/x", "imported again")].into_iter().map(|(k, v)| (k.to_owned(), v.to_owned())).collect();
    assert_eq!(note_fields(&a), want);
    let idx = a.rows("SELECT COUNT(*) FROM sync2_ent_ops WHERE what = '#purge' AND entity = 'N1'");
    assert_eq!(idx[1][0], "1", "backfilled");
}

/// 时间线（设计 §10.2）：恢复到某时刻 = 追加补偿操作；恢复后各端一致；恢复本身可以再恢复回去。
#[test]
fn timeline_restore_compensates_and_can_itself_be_undone() {
    let a = Device::new("a");
    let b = Device::new("b");
    let deck = super::config::default_deck_id(P);
    let mut bucket = Bucket::default();
    let note = |id: &str| json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": "NT"}}});
    a.apply(T0, vec![deck_entity(&deck), note("N1"), edit("note", "N1", "f/x", json!("original")), edit("note", "N1", "tags", json!(["keep"]))]);
    a.apply(T0 + 1000, vec![review("r1", "C1", T0 + 1000, 3, "learn")]);
    let t1 = T0 + 1500;
    // 「误操作」：改坏字段、删笔记、改标签、新建一条笔记、又复习一次。
    a.apply(T0 + 2000, vec![edit("note", "N1", "f/x", json!("broken")), edit("note", "N1", "deleted", json!(T0 + 2000))]);
    a.apply(T0 + 2100, vec![edit("note", "N1", "tags", json!(["oops"])), note("N2"), review("r2", "C1", T0 + 2100, 1, "review")]);
    use super::timeline::RestoreTarget;
    let preview = a.core.sync2_plan_restore(P, &RestoreTarget::At(t1), true, T0 + 3000).unwrap();
    assert_eq!(preview["fields"], json!(1), "{preview}");
    assert_eq!(preview["revived"], json!(1), "{preview}");
    assert_eq!(preview["removed"], json!(1), "N2 is removed: {preview}");
    assert_eq!(preview["reviews"], json!(1), "{preview}");
    let before_restore = projection(&a);
    a.core.sync2_restore(P, &RestoreTarget::At(t1), true, T0 + 3000).unwrap();
    let v = |d: &Device, key: &str, e: &str| {
        d.rows(&format!("SELECT json_extract(json, '$.v') FROM srs_field_edits WHERE entity_id = '{e}' AND field_key = '{key}'"))
            .get(1)
            .map(|r| r[0].clone())
            .unwrap_or_default()
    };
    assert_eq!(v(&a, "f/x", "N1"), "original");
    assert_eq!(v(&a, "deleted", "N1"), "NULL");
    assert_eq!(tags_of(&a, "N1"), r#"["keep"]"#);
    assert_ne!(v(&a, "deleted", "N2"), "", "N2 created after t1 is deleted");
    assert!(a.state("C1").as_str().unwrap().contains("reps: 1"), "the later review is retracted: {}", a.state("C1"));
    // 恢复是普通操作：同步到 B，两端一致。
    a.sync(&mut bucket, "loc", T0 + 3100);
    b.sync(&mut bucket, "loc", T0 + 3100);
    assert_eq!(projection(&a), projection(&b));
    // 恢复之前自动打了还原点；恢复到那一刻 = 撤销这次恢复（内容回到恢复前；复习撤回不再撤回由另一次恢复的勾选决定）。
    let cps = a.core.sync2_checkpoints(P).unwrap();
    assert_eq!(cps[0]["reason"], json!("restore"));
    a.core.sync2_restore(P, &RestoreTarget::At(T0 + 2999), false, T0 + 4000).unwrap();
    assert_eq!(v(&a, "f/x", "N1"), "broken");
    assert_ne!(v(&a, "deleted", "N1"), "NULL");
    let _ = before_restore;
}

/// 还原点与随后的批量删除落在同一毫秒：按还原点的因果截断，「恢复到这个还原点」照样把删除撤回。
#[test]
fn restoring_to_a_checkpoint_uses_its_causality_not_its_wall_clock() {
    use super::timeline::RestoreTarget;
    let a = Device::new("cp");
    let note = |id: &str| json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": "NT"}}});
    a.apply(T0, vec![note("N1"), edit("note", "N1", "f/x", json!("keep me"))]);
    a.core.sync2_checkpoint(P, "deck", "bulk_delete", T0 + 1000).unwrap();
    a.apply(T0 + 1000, vec![edit("note", "N1", "deleted", json!(T0 + 1000))]);
    let cp = a.core.sync2_checkpoints(P).unwrap()[0].clone();
    // 按墙钟（同一毫秒）恢复：删除也被算进「那一刻」。
    let by_wall = a.core.sync2_plan_restore(P, &RestoreTarget::At(cp["at"].as_i64().unwrap()), false, T0 + 2000).unwrap();
    assert_eq!(by_wall["revived"], json!(0), "{by_wall}");
    let id = crate::sync2::vv::OpId {
        device: crate::sync2::id::Id::parse(cp["device"].as_str().unwrap()).unwrap(),
        seq: cp["seq"].as_u64().unwrap(),
    };
    let by_cp = a.core.sync2_plan_restore(P, &RestoreTarget::Checkpoint(id), false, T0 + 2000).unwrap();
    assert_eq!(by_cp["revived"], json!(1), "{by_cp}");
    a.core.sync2_restore(P, &RestoreTarget::Checkpoint(id), false, T0 + 2000).unwrap();
    let deleted = a.rows("SELECT json_extract(json, '$.v') FROM srs_field_edits WHERE entity_id = 'N1' AND field_key = 'deleted'");
    assert_eq!(deleted[1][0], "NULL");
}

/// 外来、已盖戳的事件（备份合并）并入时保留原 dot / 上下文：被现值支配的旧值不会被盖回来，并发的仍并发。
#[test]
fn stamped_foreign_edits_keep_their_causality() {
    let a = Device::new("a");
    a.apply(T0, vec![edit("note", "N1", "f/x", json!("v1"))]);
    // 拿到 v1 落库的那一行（备份里存的就是这种行），然后本机改成 v2。
    let old: Value = serde_json::from_str(&a.rows("SELECT json FROM srs_field_edits WHERE field_key = 'f/x'")[1][0]).unwrap();
    a.apply(T0 + 1, vec![edit("note", "N1", "f/x", json!("v2"))]);
    let input = json!([{"e": {"t": "edit", "x": old}, "stamped": true}]);
    let r: Value = serde_json::from_str(&a.core.sync2_apply_local(P, T0 + 2, &input.to_string()).unwrap()).unwrap();
    assert_eq!(r["landed"], json!([false]), "the backup's v1 is dominated by the newer v2");
    let vals = a.rows("SELECT json_extract(json, '$.v') FROM srs_field_edits WHERE field_key = 'f/x'");
    assert_eq!(vals.len(), 2);
    assert_eq!(vals[1][0], "v2");
}

/// 从 v2 之后的备份恢复（快照剥掉了本机身份与迁移标记）：打开时不得把投影行再迁移一遍。
#[test]
fn restoring_a_v2_backup_does_not_migrate_twice() {
    let a = Device::new("a");
    a.core.sync2_migrate(P, T0, None).unwrap();
    a.apply(T0 + 1, vec![edit("note", "N1", "f/x", json!("v"))]);
    let dir = tempdir::new("restore2");
    a.core.snapshot_into(&dir.0.join("srs.db"), true).unwrap();
    let r = Device { core: SrsCore::open(&dir.0.join("srs.db")).unwrap(), _dir: dir };
    let before = r.rows("SELECT COUNT(*) FROM sync2_ops")[1][0].clone();
    let m = r.core.sync2_migrate(P, T0 + 2, None).unwrap();
    assert_eq!(m["ops"], json!(0));
    assert_eq!(r.rows("SELECT COUNT(*) FROM sync2_ops")[1][0], before);
}

/// 手动导出 / 导入（设计 §10.4）：并入不覆盖；导入自己更早的导出不换身份；导入克隆体的导出会换身份、不丢任何一边。
#[test]
fn fushisrs_export_import_merges_without_overwriting() {
    let a = Device::new("a");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck), edit("note", "N1", "f/x", json!("a1")), review("r1", "C", T0, 3, "learn")]);
    let early = a.core.sync2_export(P).unwrap();
    a.apply(T0 + 1, vec![edit("note", "N1", "f/x", json!("a2"))]);
    // 新设备导入：与 A 当时的投影一致。
    let c = Device::new("c");
    c.core.sync2_identity(P, T0).unwrap();
    c.core.sync2_import(P, &a.core.sync2_export(P).unwrap(), T0 + 2).unwrap();
    assert_eq!(projection(&c), projection(&a));
    // A 导入自己更早的导出：什么都不变、不换身份。
    let me = a.core.sync2_status(P).unwrap()["device"].clone();
    let before = projection(&a);
    a.core.sync2_import(P, &early, T0 + 3).unwrap();
    assert_eq!(a.core.sync2_status(P).unwrap()["device"], me);
    assert_eq!(projection(&a), before);
    // 克隆体（拷了数据目录）写了别的东西再导出；A 导入它：A 换身份，两边的写入都在。
    let twin = Device::copy_of(&a, "twin");
    twin.apply(T0 + 4, vec![review("rt", "C", T0 + 4, 4, "learn")]);
    a.apply(T0 + 5, vec![review("ra", "C", T0 + 5, 2, "learn")]);
    a.core.sync2_import(P, &twin.core.sync2_export(P).unwrap(), T0 + 6).unwrap();
    assert_ne!(a.core.sync2_status(P).unwrap()["device"], me);
    let ids = a.rows("SELECT id FROM srs_review_logs ORDER BY id");
    assert!(ids.iter().any(|r| r[0] == "ra") && ids.iter().any(|r| r[0] == "rt"));
}

/// 流式导出的明文与旧实现（整份攒好再压缩）逐字节相同，旧方式压出的包照样能导入；大包（解压后几十 MB）
/// 导入后与作者一致；截断的包报错且什么都不改。
#[test]
fn fushisrs_streaming_export_import_is_format_compatible_and_handles_large_packages() {
    use crate::sync2::id::Id;
    use crate::sync2::vv::OpId;
    let a = Device::new("xa");
    let b = Device::new("xb");
    let deck = super::config::default_deck_id(P);
    let mut bucket = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck)]);
    let filler = "日本語の例文。".repeat(1000);
    for batch in 0..4 {
        let events: Vec<Value> =
            (0..250).map(|i| edit("note", &format!("N{batch}-{i}"), "f/s", json!(format!("{filler}{i}")))).collect();
        a.apply(T0 + batch, events);
    }
    a.sync(&mut bucket, "loc", T0 + 10);
    b.sync(&mut bucket, "loc", T0 + 11);
    b.apply(T0 + 12, vec![review("rb", "C", T0 + 12, 3, "learn")]);
    b.sync(&mut bucket, "loc", T0 + 13);
    a.sync(&mut bucket, "loc", T0 + 14);

    let exported = a.core.sync2_export(P).unwrap();
    // 旧实现的明文：整份按同一格式写出。
    let legacy_plain = {
        let w = a.core.writer().unwrap();
        let local = super::Local::load(&w, P).unwrap().unwrap();
        let mut out = crate::sync2::codec::Writer::new();
        out.raw(b"FSRS2EXP");
        out.u8(1);
        local.collection.write(&mut out);
        let devices: Vec<(Vec<u8>, Option<Vec<u8>>, i64)> = w
            .prepare("SELECT device, public, applied FROM sync2_devices WHERE profile_uid = ?1 ORDER BY device")
            .unwrap()
            .query_map([P], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        out.uv(devices.len() as u64);
        for (dev, public, applied) in devices {
            let device = Id(dev.try_into().unwrap());
            device.write(&mut out);
            out.bytes(&public.unwrap_or_default());
            out.uv(applied as u64);
            for seq in 1..=applied as u64 {
                out.bytes(&super::load_op(&w, P, &OpId { device, seq }).unwrap().unwrap().encode());
            }
        }
        out.into_vec()
    };
    assert!(legacy_plain.len() > 20 * 1024 * 1024, "{}", legacy_plain.len());
    assert_eq!(crate::zstd_decompress(&exported).unwrap(), legacy_plain);

    let c = Device::new("xc");
    c.core.sync2_identity(P, T0).unwrap();
    let before = projection(&c);
    assert!(c.core.sync2_import(P, &exported[..exported.len() / 2], T0 + 20).is_err());
    assert_eq!(projection(&c), before);
    let legacy = ruzstd::encoding::compress_to_vec(&legacy_plain[..], ruzstd::encoding::CompressionLevel::Fastest);
    let r: Value = serde_json::from_str(&c.core.sync2_import(P, &legacy, T0 + 20).unwrap()).unwrap();
    assert_eq!(r["pending"], json!(0), "{r}");
    assert_eq!(projection(&c), projection(&a));
    let d = Device::new("xd");
    d.core.sync2_identity(P, T0).unwrap();
    d.core.sync2_import(P, &exported, T0 + 20).unwrap();
    assert_eq!(projection(&d), projection(&a));
}

fn segment_files(bucket: &Bucket, d: &Device) -> usize {
    let dev = d.core.sync2_identity(P, T0).unwrap()["device"].as_str().unwrap().to_owned();
    bucket.0.keys().filter(|k| k.starts_with(&format!("devices/{dev}/seg-"))).count()
}

/// 小段分层合并后，旧小段在不再被任何留着的 head 引用、且过了宽限期后删掉——不等别的设备 ack（审查 S-5：对端
/// 重装 / 换身份 / 长期休眠时它的 ack 永远不动，以前旧小段因此永远删不掉）。B 在这里收过一次之后就再也不同步。
#[test]
fn small_own_segments_are_compacted_and_old_files_deleted_without_waiting_for_acks() {
    let a = Device::new("ca");
    let b = Device::new("cb");
    let mut bucket = Bucket::default();
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("Default"))]);
    a.sync(&mut bucket, "loc", T0);
    b.sync(&mut bucket, "loc", T0);
    // 每轮同步只带一条改动：一轮一个小段。
    for i in 0..40 {
        a.apply(T0 + i, vec![review(&format!("r{i}"), "C", T0 + 1000 * i, 3, "review")]);
        a.sync(&mut bucket, "loc", T0 + 1000 * i);
    }
    let before = segment_files(&bucket, &a);
    // 宽限期内：A 已合并并上传大段，旧小段还留着（读到旧 head 的读者照样拿得到它引用的段）。
    assert!(before > 16, "{before}");
    let pending = a.rows("SELECT COUNT(*) FROM sync2_obsolete")[1][0].parse::<usize>().unwrap();
    assert!(pending > 0, "merged-away segments are waiting");
    // 写 head 的代号够了但时间不够：仍不删。
    a.apply(T0 + 50_000, vec![review("x1", "C", T0 + 50_000, 3, "review")]);
    a.sync(&mut bucket, "loc", T0 + 50_000);
    a.apply(T0 + 51_000, vec![review("x2", "C", T0 + 51_000, 3, "review")]);
    a.sync(&mut bucket, "loc", T0 + 51_000);
    assert!(segment_files(&bucket, &a) >= before - 2, "nothing deleted inside the grace period");
    // 过了宽限期，再写两代 head：B 从没再同步（ack 一直停在开头），旧小段照样删光。
    a.apply(T0 + DAY + 60_000, vec![review("x3", "C", T0 + DAY + 60_000, 3, "review")]);
    a.sync(&mut bucket, "loc", T0 + DAY + 60_000);
    a.sync(&mut bucket, "loc", T0 + DAY + 61_000);
    a.sync(&mut bucket, "loc", T0 + DAY + 62_000);
    let after = segment_files(&bucket, &a);
    let rows = a.rows("SELECT COUNT(*) FROM sync2_segments")[1][0].parse::<usize>().unwrap();
    // 位置上只剩当前切法下的段（合并掉的旧小段全删了）；尾部不足一组的小段留到下次合并。
    assert_eq!(after, rows, "no stale segment files left, although B never acked them");
    assert!(after * 2 < before && after <= 16, "{before} -> {after}");
    assert_eq!(a.rows("SELECT COUNT(*) FROM sync2_obsolete")[1][0], "0");
    // 留着的 head 没有一份引用已删的段（读者只认 head 列出的段）。
    for (k, v) in bucket.0.iter().filter(|(k, _)| k.contains("/head-")) {
        let h = crate::sync2::segment::Head::decode(v).unwrap();
        let dir = k.rsplit_once('/').unwrap().0;
        for f in h.segment_files() {
            assert!(bucket.0.contains_key(&format!("{dir}/{f}")), "{k} references deleted {f}");
        }
    }
    // 休眠的 B 回来：读到的 head 只引用合并后的段，照样收齐。
    b.sync(&mut bucket, "loc", T0 + 2 * DAY);
    assert_eq!(projection(&a), projection(&b));
    // 新设备只看得到合并后的段，也能完整收齐。
    let c = Device::new("cc");
    c.sync(&mut bucket, "loc", T0 + DAY);
    c.sync(&mut bucket, "loc", T0 + DAY);
    assert_eq!(projection(&a), projection(&c));
    assert_eq!(a.digest(), c.digest());
}

/// 首次提交（迁移了一大批旧数据 / 攒了很久没同步）：按压缩后体积切段，几万条操作只是一个文件，新设备一轮收齐。
#[test]
fn a_large_first_commit_uploads_a_handful_of_files() {
    let a = Device::new("big");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck)]);
    for batch in 0..6 {
        let events: Vec<Value> = (0..1000)
            .map(|i| {
                let n = batch * 1000 + i;
                review(&format!("r{n}"), &format!("C{}", n % 400), T0 + n * 60_000, 1 + n % 4, "review")
            })
            .collect();
        a.apply(T0 + batch, events);
    }
    let mut bucket = Bucket::default();
    a.sync(&mut bucket, "loc", T0 + DAY);
    // 这 6000 条未压缩约 1.5 MB：旧上限（64 KB 未压缩 / 2000 条）下是二十多个段；现在是一个。
    assert_eq!(segment_files(&bucket, &a), 1);
    let c = Device::new("bigc");
    c.sync(&mut bucket, "loc", T0 + DAY);
    assert_eq!(projection(&a), projection(&c));
    assert_eq!(a.digest(), c.digest());
}

/// 解压后切满的段（压缩后很小）在分层合并眼里是满段：不会每轮被挑出来重新加载、重新压缩估算（重切后段数
/// 不减，合并最后会作罢，但白做一遍）。
#[test]
fn raw_full_segments_are_never_compaction_candidates() {
    use crate::sync2::id::Id;
    use crate::sync2::op::{Op, SCHEMA};
    use crate::sync2::segment::split_ranges;
    use crate::sync2::hlc::Hlc;
    use crate::sync2::vv::{OpId, Vv};
    let dev = Id([4; 16]);
    let deps = std::sync::Arc::new(Vv::new());
    let ops: Vec<Op> = (1..=800u64)
        .map(|seq| Op {
            id: OpId { device: dev, seq },
            hlc: Hlc { wall: seq as i64, logical: 0, device: dev },
            deps: deps.clone(),
            kind: 9999,
            schema: SCHEMA,
            payload: vec![0u8; 100_000].into(),
            purged: false,
        })
        .collect();
    let segs = split_ranges(&ops);
    assert!(segs.len() >= 5, "{segs:?}");
    let plan = super::transport::compaction_plan(&segs);
    assert!(plan.is_empty(), "{:?}", plan.iter().map(|g| g.segs.clone()).collect::<Vec<_>>());
}

/// 重复度高的大正文：按解压后体积切成几段（读端一次只解一段），解压后过半的段不再被分层合并重切 / 重传；
/// 新设备逐段收、结果与发件端一致。
#[test]
fn highly_compressible_content_is_cut_by_uncompressed_size_and_not_recompacted() {
    let a = Device::new("raw");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck)]);
    let filler = "日本語の例文。".repeat(1000);
    for batch in 0..8 {
        let events: Vec<Value> =
            (0..250).map(|i| edit("note", &format!("N{batch}-{i}"), "f/s", json!(format!("{filler}{i}")))).collect();
        a.apply(T0 + batch, events);
    }
    let mut bucket = Bucket::default();
    a.sync(&mut bucket, "loc", T0 + DAY);
    // 2000 × ~21 KB ≈ 42 MB 明文，压缩后不到 1 MB：按解压后 16 MB 上限至少三段。
    let files: Vec<String> = bucket.0.keys().filter(|k| k.contains("/seg-")).cloned().collect();
    assert!(files.len() >= 3, "{files:?}");
    // 分层合并每轮都会看一遍切段点：这些段压缩后很小，若按真实压缩体积记，每轮都会被挑出来重新加载、重新压缩
    // 估算（再因段数不减而作罢）。
    let segs: Vec<(u64, u64, u64)> = a
        .rows("SELECT first, last, bytes FROM sync2_segments ORDER BY first")
        .iter()
        .skip(1)
        .map(|r| (r[0].parse().unwrap(), r[1].parse().unwrap(), r[2].parse().unwrap()))
        .collect();
    assert!(segs.len() >= 3, "{segs:?}");
    let plan = super::transport::compaction_plan(&segs);
    assert!(plan.is_empty(), "{:?}", plan.iter().map(|g| g.segs.clone()).collect::<Vec<_>>());
    for _ in 0..3 {
        a.sync(&mut bucket, "loc", T0 + 2 * DAY);
    }
    let again: Vec<String> = bucket.0.keys().filter(|k| k.contains("/seg-")).cloned().collect();
    assert_eq!(again, files);
    let c = Device::new("rawc");
    c.sync(&mut bucket, "loc", T0 + 2 * DAY);
    assert_eq!(projection(&a), projection(&c));
    assert_eq!(a.digest(), c.digest());
}

/// 旧版本只按压缩后体积切段，位置上可能躺着一个解压后几十 MB 的段（不会重切，§7.1 段不可变）。收段端照样收：
/// 校验走流式（不留操作），再流式按块投递，结果与逐段收的一样。
#[test]
fn legacy_oversized_segment_is_streamed_in_and_matches_the_author() {
    use crate::sync2::segment::{self, Verified, CHAIN_ZERO, SEGMENT_MAX_RAW_BYTES};
    let a = Device::new("legacy");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck)]);
    let filler = "日本語の例文。".repeat(1000);
    for batch in 0..8 {
        let events: Vec<Value> =
            (0..250).map(|i| edit("note", &format!("N{batch}-{i}"), "f/s", json!(format!("{filler}{i}")))).collect();
        a.apply(T0 + batch, events);
    }
    let mut bucket = Bucket::default();
    a.sync(&mut bucket, "loc", T0 + DAY);
    // 把 A 发出的全部段并成旧版本会切出的那种一整段（同一把设备钥匙签，链与原段一致）。
    let (collection, signer, public) = {
        let w = a.core.writer().unwrap();
        let local = super::Local::load(&w, P).unwrap().unwrap();
        let public = local.key.public();
        (local.collection, local.key, public)
    };
    let mut paths: Vec<&String> = bucket.0.keys().filter(|k| k.contains("/seg-")).collect();
    paths.sort();
    let mut ops = Vec::new();
    for p in paths {
        ops.extend(segment::open(&bucket.0[p], &public, None).unwrap().ops);
    }
    let raw: u64 = ops.iter().map(|o| o.payload.len() as u64 + 24).sum();
    assert!(raw > 2 * SEGMENT_MAX_RAW_BYTES, "{raw}");
    let (_, big) = segment::pack(collection, &ops, CHAIN_ZERO, &signer, None).unwrap();
    assert!((big.len() as u64) < SEGMENT_MAX_RAW_BYTES / 8, "compressed {}", big.len());
    let opened = segment::open_verified(&big, &public, None).unwrap();
    assert!(matches!(opened.verify().unwrap(), Verified::Stream(_)), "an oversized segment must not be kept whole");

    let c = Device::new("legacyc");
    c.core.sync2_identity(P, T0 + 2 * DAY).unwrap();
    let heads: Vec<Vec<u8>> = bucket.0.iter().filter(|(k, _)| k.contains("/head-")).map(|(_, v)| v.clone()).collect();
    c.core.sync2_plan(P, &heads).unwrap();
    let out: Value = serde_json::from_str(&c.core.sync2_ingest(P, &[big], None, T0 + 2 * DAY).unwrap()).unwrap();
    assert_eq!(out["errors"], json!([]), "{out}");
    assert_eq!(out["applied"].as_u64().unwrap(), ops.len() as u64);
    assert_eq!(projection(&a), projection(&c));
    c.core.sync2_digest_due(P, T0 + 2 * DAY, Some(0)).unwrap();
    assert_eq!(a.digest(), c.digest());
}

/// 升级前切的老段（体积未知，记 0）：下一轮补算体积、按层合并，位置上换成少数几个大段，新设备照样收齐。
#[test]
fn pre_upgrade_small_segments_are_sized_and_compacted() {
    let a = Device::new("old");
    let b = Device::new("oldb");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck)]);
    let events: Vec<Value> = (0..300).map(|n| review(&format!("r{n}"), &format!("C{}", n % 30), T0 + n * 60_000, 1 + n % 4, "learn")).collect();
    a.apply(T0 + 1, events);
    // 模拟老版本：每条操作切成一段、体积未知；已经全部传到位置上，B 也收过了。
    let top: i64 = a.core.sync2_status(P).unwrap()["nextSeq"].as_i64().unwrap() - 1;
    let dev = a.core.sync2_identity(P, T0).unwrap()["device"].as_str().unwrap().to_owned();
    {
        let w = a.core.writer().unwrap();
        w.execute("DELETE FROM sync2_segments", []).unwrap();
        for seq in 1..=top {
            w.execute(
                "INSERT INTO sync2_segments (profile_uid, device, first, last, bytes) \
                 SELECT ?1, device, ?2, ?2, 0 FROM sync2_self WHERE profile_uid = ?1",
                rusqlite::params![P, seq],
            )
            .unwrap();
        }
    }
    let mut bucket = Bucket::default();
    // 第一轮：这些老段照原样上传（合并只动已经切好的段，传过的才登记重传 / 待删）。
    a.sync(&mut bucket, "loc", T0 + DAY);
    b.sync(&mut bucket, "loc", T0 + DAY);
    let rows = |d: &Device| d.rows("SELECT COUNT(*) FROM sync2_segments")[1][0].parse::<usize>().unwrap();
    assert!(rows(&a) < 10, "{} segments after compaction", rows(&a));
    assert!(a.rows("SELECT COUNT(*) FROM sync2_segments WHERE bytes = 0")[1][0] == "0");
    // 被替换的段在不再被引用后又过了两代 head、满 24 小时才删（不等任何设备 ack，审查 S-5）：之后位置上只剩合并后的段。
    // 第二轮还会再合并一层，那批被替换的段从第二轮的 head 起算。
    a.sync(&mut bucket, "loc", T0 + 2 * DAY);
    b.sync(&mut bucket, "loc", T0 + 2 * DAY);
    a.sync(&mut bucket, "loc", T0 + 3 * DAY);
    assert!(segment_files(&bucket, &a) > rows(&a), "still inside the grace window: nothing deleted yet");
    a.sync(&mut bucket, "loc", T0 + 4 * DAY);
    assert_eq!(segment_files(&bucket, &a), rows(&a), "{dev}");
    let c = Device::new("oldc");
    c.sync(&mut bucket, "loc", T0 + 4 * DAY);
    assert_eq!(projection(&a), projection(&c));
    assert_eq!(projection(&a), projection(&b));
}

/// 新设备追赶两台互相同步过很多轮的设备：两台的操作因果上交错（每轮都依赖对方上一轮），一次收齐、顺序正确。
#[test]
fn a_new_device_catches_up_a_long_causally_interleaved_history_in_one_round() {
    let a = Device::new("pa");
    let b = Device::new("pb");
    let deck = super::config::default_deck_id(P);
    let mut bucket = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck)]);
    for i in 0..120 {
        let at = T0 + i * 600_000;
        a.apply(at, vec![edit("note", "N1", "f/x", json!(format!("a{i}"))), review(&format!("ra{i}"), "C", at, 3, "review")]);
        a.sync(&mut bucket, "loc", at);
        b.sync(&mut bucket, "loc", at);
        b.apply(at + 1, vec![edit("note", "N1", "f/x", json!(format!("b{i}"))), review(&format!("rb{i}"), "C", at + 1, 2, "review")]);
        b.sync(&mut bucket, "loc", at + 1);
        a.sync(&mut bucket, "loc", at + 1);
    }
    let c = Device::new("pc");
    let started = std::time::Instant::now();
    let r = c.sync(&mut bucket, "loc", T0 + 99 * DAY);
    assert_eq!(r["pending"], json!(0), "everything delivered in one round: {r}");
    assert_eq!(projection(&a), projection(&c));
    assert_eq!(a.state("C"), c.state("C"));
    assert_eq!(a.digest(), c.digest());
    assert!(started.elapsed().as_secs() < 60, "{:?}", started.elapsed());
}

/// 先只收到依赖别的设备的那一支：等着的操作写进缓冲表（测试里内存预算极小，必然落表），内存里只留链值；
/// 另一台设备的段下一次调用才到，缓冲表里的按主键读出投递，结果与一次收齐相同。
#[test]
fn ops_waiting_on_another_device_spill_to_the_buffer_and_land_later() {
    let a = Device::new("wa");
    let b = Device::new("wb");
    let deck = super::config::default_deck_id(P);
    let mut bucket = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck)]);
    for i in 0..40 {
        let at = T0 + i * 600_000;
        a.apply(at, vec![edit("note", "N1", "f/x", json!(format!("a{i}"))), review(&format!("ra{i}"), "C", at, 3, "review")]);
        a.sync(&mut bucket, "loc", at);
        b.sync(&mut bucket, "loc", at);
        b.apply(at + 1, vec![edit("note", "N1", "f/x", json!(format!("b{i}"))), review(&format!("rb{i}"), "C", at + 1, 2, "review")]);
        b.sync(&mut bucket, "loc", at + 1);
        a.sync(&mut bucket, "loc", at + 1);
    }
    let now = T0 + 99 * DAY;
    let c = Device::new("wc");
    c.core.sync2_identity(P, now).unwrap();
    let heads: Vec<Vec<u8>> = bucket.0.iter().filter(|(k, _)| k.contains("/head-")).map(|(_, v)| v.clone()).collect();
    let plan = c.core.sync2_plan(P, &heads).unwrap();
    let dev_of = |d: &Device| -> String {
        let w = d.core.writer().unwrap();
        super::Local::load(&w, P).unwrap().unwrap().device.text()
    };
    let (a_dev, b_dev) = (dev_of(&a), dev_of(&b));
    let files_of = |dev: &str| -> Vec<Vec<u8>> {
        plan["fetch"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|f| f["files"].as_array().unwrap().iter())
            .map(|n| n.as_str().unwrap())
            .filter(|n| n.contains(dev))
            .map(|n| bucket.0[n].clone())
            .collect()
    };
    let first: Value = serde_json::from_str(&c.core.sync2_ingest(P, &files_of(&b_dev), None, now).unwrap()).unwrap();
    assert!(first["pending"].as_i64().unwrap() > 40, "B's ops wait on A: {first}");
    let second: Value = serde_json::from_str(&c.core.sync2_ingest(P, &files_of(&a_dev), None, now).unwrap()).unwrap();
    assert_eq!(second["pending"], json!(0), "{second}");
    assert_eq!(second["errors"], json!([]), "{second}");
    assert_eq!(projection(&a), projection(&c));
    assert_eq!(a.state("C"), c.state("C"));
    c.core.sync2_digest_due(P, now, Some(0)).unwrap();
    assert_eq!(a.digest(), c.digest());
}

#[test]
fn backup_snapshot_keeps_server_times_of_legacy_edits() {
    let a = Device::new("st");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck)]);
    a.core
        .writer()
        .unwrap()
        .execute(
            "INSERT INTO srs_event_local (event_id, profile_uid, outbox_seq, server_time, received_at) VALUES ('legacy-1', ?1, 7, 123, 1)",
            [P],
        )
        .unwrap();
    let dir = tempdir::new("st-snap");
    a.core.snapshot_into(&dir.0.join("srs.db"), true).unwrap();
    let restored = Device { core: SrsCore::open(&dir.0.join("srs.db")).unwrap(), _dir: dir };
    assert_eq!(
        restored.rows("SELECT server_time, outbox_seq IS NULL FROM srs_event_local WHERE event_id = 'legacy-1'")[1..],
        [vec!["123".to_owned(), "1".to_owned()]]
    );
}

/// 规模基准（计划 P8，默认不跑）：`SRS_BENCH_CARDS` 张卡（缺省 5000）× 每张 20 次复习。量本机写入、全量重放、
/// 首次发件（切段 + 打包签名）、新设备收齐全部段（校验 + 投影 + 重放）的端到端耗时。
/// `SRS_BENCH_CARDS=50000 cargo test --release --lib bench_scale -- --ignored --nocapture`
#[test]
#[ignore]
fn bench_scale() {
    use std::time::Instant;
    let cards: i64 = std::env::var("SRS_BENCH_CARDS").ok().and_then(|v| v.parse().ok()).unwrap_or(5000);
    let a = Device::new("bench-a");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("Default"))]);
    let t = Instant::now();
    for chunk in 0..(cards + 99) / 100 {
        // 每张卡一条笔记（真实库的形状；全挂在一条笔记上会把「每条写入看一眼实体」放大成平方级）。
        let mut input = Vec::new();
        for c in chunk * 100..((chunk + 1) * 100).min(cards) {
            for r in 0..20 {
                let at = T0 + r * DAY + c;
                let e = review(&format!("r{c}-{r}"), &format!("C{c}"), at, 3, if r == 0 { "learn" } else { "review" });
                input.push(json!({"e": e, "note": format!("N{c}")}));
            }
        }
        a.core.sync2_apply_local(P, T0 + chunk, &Value::Array(input).to_string()).unwrap();
    }
    let apply_ms = t.elapsed().as_millis();
    let t = Instant::now();
    a.core.sync2_replay_all(P).unwrap();
    let replay_ms = t.elapsed().as_millis();
    let mut bucket = Bucket::default();
    let t = Instant::now();
    a.sync(&mut bucket, "loc", T0 + 30 * DAY);
    let publish_ms = t.elapsed().as_millis();
    let bytes: usize = bucket.0.values().map(Vec::len).sum();
    let b = Device::new("bench-b");
    let t = Instant::now();
    b.sync(&mut bucket, "loc", T0 + 30 * DAY);
    let join_ms = t.elapsed().as_millis();
    let t = Instant::now();
    a.apply(T0 + 31 * DAY, vec![review("inc", "C0", T0 + 31 * DAY, 3, "review")]);
    let inc_apply = t.elapsed().as_millis();
    let t2 = Instant::now();
    a.sync(&mut bucket, "loc", T0 + 31 * DAY);
    let inc_push = t2.elapsed().as_millis();
    let t3 = Instant::now();
    b.sync(&mut bucket, "loc", T0 + 31 * DAY);
    let inc_pull = t3.elapsed().as_millis();
    let t4 = Instant::now();
    a.core.sync2_digest(P).unwrap();
    let digest_ms = t4.elapsed().as_millis();
    println!("bench_scale incremental apply={inc_apply}ms push_round={inc_push}ms pull_round={inc_pull}ms (each incl. digest={digest_ms}ms)");
    let incremental_ms = t.elapsed().as_millis();
    assert_eq!(a.digest(), b.digest());
    println!(
        "bench_scale cards={cards} reviews={} apply={apply_ms}ms replay_all={replay_ms}ms publish={publish_ms}ms \
         files={} bytes={bytes} join={join_ms}ms incremental_round_trip={incremental_ms}ms",
        cards * 20,
        bucket.0.len()
    );
}

/// 新设备按生产节奏追赶（审查 S-4，默认不跑）：`SRS_BENCH_CARDS` 张卡（缺省 5000）× 每张 20 次复习，新设备
/// 走分批收段会话——按 8 MiB 字节预算切批，每批 `ingest_prepare` + 按时间切片的 `ingest_commit`（150 ms 一片）直到
/// 投完，最后 `ingest_finish`。与一次收完 / 全量重放对拍逐卡日志。
/// `SRS_BENCH_CARDS=50000 cargo test --release --lib bench_join_sliced -- --ignored --nocapture`
#[test]
#[ignore]
fn bench_join_sliced() {
    use std::time::Instant;
    let cards: i64 = std::env::var("SRS_BENCH_CARDS").ok().and_then(|v| v.parse().ok()).unwrap_or(5000);
    let a = Device::new("bench-js-a");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("Default"))]);
    // 按天写：每天一批里含当天全部卡的那一次复习（真实形状：同一张卡的复习散在整个历史里，追赶时每片都碰到它）。
    for r in 0..20i64 {
        for chunk in 0..(cards + 4999) / 5000 {
            let mut input = Vec::new();
            for c in chunk * 5000..((chunk + 1) * 5000).min(cards) {
                let at = T0 + r * DAY + c;
                let e = review(&format!("r{c}-{r}"), &format!("C{c}"), at, 3, if r == 0 { "learn" } else { "review" });
                input.push(json!({"e": e, "note": format!("N{c}")}));
            }
            a.core.sync2_apply_local(P, T0 + r * DAY + chunk, &Value::Array(input).to_string()).unwrap();
        }
    }
    let mut bucket = Bucket::default();
    a.sync(&mut bucket, "loc", T0 + 30 * DAY);
    let heads: Vec<Vec<u8>> = bucket.0.iter().filter(|(k, _)| k.contains("/head-")).map(|(_, v)| v.clone()).collect();
    let segs: Vec<Vec<u8>> = bucket.0.iter().filter(|(k, _)| k.contains("/seg-")).map(|(_, v)| v.clone()).collect();
    let b = Device::new("bench-js-b");
    b.core.sync2_identity(P, T0 + 30 * DAY).unwrap();
    b.core.sync2_plan(P, &heads).unwrap();
    let t = Instant::now();
    b.core.sync2_ingest_begin(P).unwrap();
    let (mut slices, mut batch, mut bytes) = (0usize, Vec::new(), 0usize);
    let flush = |batch: &mut Vec<Vec<u8>>, slices: &mut usize| {
        b.core.sync2_ingest_prepare(P, batch.to_vec(), None).unwrap();
        loop {
            let r: Value = serde_json::from_str(
                &b.core.sync2_ingest_commit(P, T0 + 30 * DAY, super::transport::CommitBudget::slice(b.core.ingest_yield_flag())).unwrap(),
            )
            .unwrap();
            *slices += 1;
            if r["more"] != json!(true) {
                break;
            }
        }
        batch.clear();
    };
    for s in segs {
        bytes += s.len();
        batch.push(s);
        if bytes >= 8 * 1024 * 1024 {
            flush(&mut batch, &mut slices);
            bytes = 0;
        }
    }
    if !batch.is_empty() {
        flush(&mut batch, &mut slices);
    }
    let commit_ms = t.elapsed().as_millis();
    loop {
        let r: Value = serde_json::from_str(&b.core.sync2_ingest_finish(P, T0 + 30 * DAY).unwrap()).unwrap();
        if r["more"] != json!(true) {
            break;
        }
    }
    let join_ms = t.elapsed().as_millis();
    let t = Instant::now();
    let changed = a.core.sync2_replay_all(P).unwrap();
    let replay_ms = t.elapsed().as_millis();
    assert!(changed.is_empty(), "the author's results are already the replayed ones");
    let logs = |d: &Device| d.rows("SELECT id, json FROM srs_review_logs ORDER BY id");
    assert_eq!(logs(&a), logs(&b), "every card's replayed rows match the author's full replay");
    println!(
        "bench_join_sliced cards={cards} reviews={} slices={slices} commits={commit_ms}ms join_total={join_ms}ms replay_all={replay_ms}ms",
        cards * 20
    );
}

#[test]
fn history_lists_every_edit_including_overwritten_ones() {
    let a = Device::new("hist");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("One"))]);
    a.apply(T0 + 1000, vec![edit("deck", &deck, "name", json!("Two"))]);
    // 投影里只剩生效的那条；历史里两条都在，新的在前。
    assert_eq!(a.rows(&format!("SELECT COUNT(*) FROM srs_field_edits WHERE entity_id = '{deck}' AND field_key = 'name'"))[1][0], "1");
    let h = a.core.sync2_history(P, "deck", &deck).unwrap();
    let names: Vec<&Value> = h.as_array().unwrap().iter().filter(|e| e["key"] == "name").map(|e| &e["value"]).collect();
    assert_eq!(names, vec![&json!("Two"), &json!("One")]);
}

#[test]
fn digest_is_recomputed_only_when_due() {
    let a = Device::new("dg");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck)]);
    let ten_min = 600_000;
    assert!(a.core.sync2_digest_due(P, T0, Some(ten_min)).unwrap().get("digest").is_some(), "first one always runs");
    assert_eq!(a.core.sync2_digest_due(P, T0 + 1, Some(ten_min)).unwrap()["skipped"], json!(true), "same vv");
    a.apply(T0 + 2, vec![edit("deck", &deck, "name", json!("X"))]);
    assert_eq!(a.core.sync2_digest_due(P, T0 + 3, Some(ten_min)).unwrap()["skipped"], json!(true), "vv changed but too soon");
    assert!(a.core.sync2_digest_due(P, T0 + ten_min + 3, Some(ten_min)).unwrap().get("digest").is_some());
}

fn log_json(d: &Device, id: &str) -> Value {
    serde_json::from_str(&d.rows(&format!("SELECT json FROM srs_review_logs WHERE id = '{id}'"))[1][0]).unwrap()
}

/// 改牌组配置只影响之后的复习（设计 §4.6）：已发生的复习按它自己记下的配置快照重放，结果一字不变，也不触发
/// 重放；之后的复习记下新配置。两台设备各在自己的配置下复习同一张卡，合并后仍逐行一致。
#[test]
fn deck_config_change_does_not_rewrite_past_reviews() {
    let a = Device::new("cfg-a");
    let b = Device::new("cfg-b");
    let deck = super::config::default_deck_id(P);
    let mut bucket = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "retention", json!(0.8))]);
    a.sync(&mut bucket, "loc", T0);
    b.sync(&mut bucket, "loc", T0);
    a.apply(T0 + 10, vec![review("r1", "C", T0 + 10, 3, "learn")]);
    a.apply(T0 + DAY, vec![review("r2", "C", T0 + DAY, 3, "review")]);
    let r2 = log_json(&a, "r2");
    assert_eq!(r2["sc"]["ret"], json!(0.8), "the review records the config it was answered under: {r2}");
    let out = a.apply(T0 + DAY + 1, vec![edit("deck", &deck, "retention", json!(0.95))]);
    assert_eq!(out["replayed"], json!([]), "a config change replays nothing");
    assert_eq!(log_json(&a, "r2"), r2, "past results are not rewritten");
    a.apply(T0 + 5 * DAY, vec![review("r3", "C", T0 + 5 * DAY, 3, "review")]);
    assert_eq!(log_json(&a, "r3")["sc"]["ret"], json!(0.95));
    assert_eq!(log_json(&a, "r2"), r2);
    // B 还在旧配置上离线复习同一张卡；合并后两边重放出同样的结果。
    b.apply(T0 + 2 * DAY, vec![review("b1", "C", T0 + 2 * DAY, 2, "review")]);
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + 6 * DAY);
        b.sync(&mut bucket, "loc", T0 + 6 * DAY);
    }
    assert_eq!(projection(&a), projection(&b));
    assert_eq!(log_json(&a, "b1")["sc"]["ret"], json!(0.8));
}

/// 旧库：一张卡两条旧日志，作者结果故意与「按当前配置重放」会算出的不同；牌组配置也改过。
fn legacy_library(d: &Device) {
    let deck = super::config::default_deck_id(P);
    let w = d.core.writer().unwrap();
    let log = |id: &str, at: i64, due: i64| {
        json!({
            "id": id, "p": P, "card": "C", "kind": "review", "rating": 3, "hlc": format!("{at}:0:old"), "at": at,
            "ts": "anchored", "origin": "fushi", "rtype": "review", "utcOff": 0, "rollover": 4, "fv": 1,
            "res": {"queue": "review", "dueDay": due, "ivl": 40, "step": 0, "reps": 2, "lapses": 0, "scheduler": "fushi",
                    "memory": {"s": 41.5, "d": 5.25, "sf": 0.0}, "lastReviewedAt": at}
        })
        .to_string()
    };
    let e1 = crate::registers::edit_id("old", 1);
    let e2 = crate::registers::edit_id("old", 2);
    let edit_json = |id: &str, s: i64, f: &str, v: Value| {
        json!({"ctx": {"vv": {}}, "e": deck, "f": f, "hlc": format!("{s}:0:old"), "id": id, "k": "deck", "p": P, "s": s, "ts": "wall", "v": v, "w": "old"})
            .to_string()
    };
    for (id, at, due) in [("L1", T0, 19_700), ("L2", T0 + 3 * DAY, 19_800)] {
        w.execute(
            "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, json) \
             VALUES (?1, ?2, 'C', 'review', 3, ?3, 'review', 'fushi', ?4)",
            rusqlite::params![id, P, at, log(id, at, due)],
        )
        .unwrap();
    }
    w.execute(
        "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES (?1, ?2, 'deck', '{\"createdAt\":1}', 1)",
        rusqlite::params![deck, P],
    )
    .unwrap();
    for (id, s, f, v) in [(&e1, 1, "retention", json!(0.97)), (&e2, 2, "name", json!("Deck"))] {
        w.execute(
            "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json) \
             VALUES (?1, ?2, 'deck', ?3, ?4, 'old', ?5, ?6)",
            rusqlite::params![id, P, deck, f, s, edit_json(id, s, f, v)],
        )
        .unwrap();
    }
    for k in 0..5i64 {
        w.execute(
            "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES (?1, ?2, 'note', '{\"createdAt\":2}', ?3)",
            rusqlite::params![format!("N{k}"), P, 2 + k],
        )
        .unwrap();
    }
}

fn legacy_rows(d: &Device) -> Vec<Vec<String>> {
    let mut out = d.rows("SELECT id, json FROM srs_review_logs ORDER BY id");
    out.extend(d.rows("SELECT id, json FROM srs_field_edits ORDER BY id"));
    out.extend(d.rows("SELECT id, payload_json, created_at FROM srs_entities ORDER BY id"));
    out
}

/// 迁移不改任何一张卡的排程（旧日志没有配置快照 = 按作者结果照抄），旧行一字不动；迁移后新复习接着旧的
/// 最后状态算，旧日志的结果仍不被追溯改写。
#[test]
fn migration_keeps_every_schedule_and_every_legacy_row() {
    let a = Device::new("mig");
    legacy_library(&a);
    let before = legacy_rows(&a);
    let m = a.core.sync2_migrate(P, T0 + 10 * DAY, None).unwrap();
    assert_eq!(m["done"], json!(true));
    assert_eq!(m["ops"], json!(10), "2 logs + 2 edits + 6 entities: {m}");
    assert_eq!(legacy_rows(&a), before, "migration rewrites no legacy row");
    assert_eq!(a.core.sync2_replay_all(P).unwrap(), Vec::<String>::new(), "replaying migrated logs changes nothing");
    a.apply(T0 + 40 * DAY, vec![review("new", "C", T0 + 40 * DAY, 3, "review")]);
    assert_eq!(legacy_rows(&a)[1..3], before[1..3], "legacy log results stay as authored");
    let new = log_json(&a, "new");
    assert_eq!(new["res"]["reps"], json!(3), "the new review continues from the legacy state: {new}");
    assert_eq!(new["sc"]["ret"], json!(0.97));
}

/// 分批迁移：三条一批、中途「被杀」（换一个连接重开）接着做，结果与一次做完逐行相同；队列与标记清干净。
/// 从迁移到一半的备份快照（剥掉本机身份）恢复出来的新设备也接着做完，不被「已经有操作了」误判为已迁移。
#[test]
fn migration_runs_in_resumable_batches() {
    let one = Device::new("mig-one");
    legacy_library(&one);
    one.core.sync2_migrate(P, T0, None).unwrap();

    let dir = tempdir::new("mig-batched");
    let path = dir.0.join("srs.db");
    {
        let d = Device { core: SrsCore::open(&path).unwrap(), _dir: tempdir::new("unused") };
        legacy_library(&d);
        let m = d.core.sync2_migrate(P, T0, Some(3)).unwrap();
        assert_eq!(m["done"], json!(false));
        assert_eq!(m["ops"], json!(3));
        assert_eq!(m["remaining"], json!(7));
    }
    // 「进程被杀」：重开，从剩下的接着做。
    let d = Device { core: SrsCore::open(&path).unwrap(), _dir: dir };
    assert_eq!(d.core.sync2_identity(P, T0).unwrap()["migrated"], json!(false));
    let mut batches = 1;
    loop {
        let m = d.core.sync2_migrate(P, T0, Some(3)).unwrap();
        batches += 1;
        if m["done"] == json!(true) {
            break;
        }
    }
    assert_eq!(batches, 4);
    assert_eq!(legacy_rows(&d), legacy_rows(&one));
    let ops = |x: &Device| x.rows("SELECT COUNT(*), SUM(LENGTH(payload)) FROM sync2_ops");
    assert_eq!(ops(&d), ops(&one));
    assert_eq!(d.rows("SELECT COUNT(*) FROM sync2_migrate_queue")[1][0], "0");
    assert_eq!(d.rows("SELECT COUNT(*) FROM srs_meta WHERE key LIKE 'sync2_migrating/%'")[1][0], "0");

    // 迁移到一半的备份快照。
    let half = Device::new("mig-half");
    legacy_library(&half);
    half.core.sync2_migrate(P, T0, Some(4)).unwrap();
    let snap = tempdir::new("mig-snap");
    half.core.snapshot_into(&snap.0.join("srs.db"), true).unwrap();
    let r = Device { core: SrsCore::open(&snap.0.join("srs.db")).unwrap(), _dir: snap };
    let m = r.core.sync2_migrate(P, T0 + 1, None).unwrap();
    assert_eq!(m["done"], json!(true));
    assert_eq!(m["ops"], json!(6), "the restored device wraps the rows the snapshot had not reached yet");
    assert_eq!(r.rows("SELECT COUNT(*) FROM sync2_ops")[1][0], "10");
}

/// 迁移耗时（P2-6）：`SRS_BENCH_CARDS` 张卡 × 20 条旧日志 + 每卡一条笔记三条旧修改记录（旧写入者 = 3 台设备，
/// 与真实旧库同形：writer 是设备安装，不是每条笔记一个）。
/// `cargo test --release --lib bench_migrate -- --ignored --nocapture`
#[test]
#[ignore]
fn bench_migrate() {
    use std::time::Instant;
    let cards: i64 = std::env::var("SRS_BENCH_CARDS").ok().and_then(|v| v.parse().ok()).unwrap_or(5000);
    let batch: u64 = std::env::var("SRS_BENCH_BATCH").ok().and_then(|v| v.parse().ok()).unwrap_or(20_000);
    let a = Device::new("bench-mig");
    let w = a.core.writer().unwrap();
    w.execute_batch("BEGIN").unwrap();
    for c in 0..cards {
        w.execute(
            "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES (?1, ?2, 'note', '{\"createdAt\":2}', ?3)",
            rusqlite::params![format!("N{c}"), P, c],
        )
        .unwrap();
        for f in 1..=3i64 {
            let writer = format!("dev{}", c % 3);
            let s = c / 3 * 3 + f;
            let id = crate::registers::edit_id(&writer, s);
            let x = json!({"ctx": {"vv": {}}, "e": format!("N{c}"), "f": format!("f/{f}"), "hlc": format!("{s}:0:{writer}"), "id": id,
                "k": "note", "p": P, "s": s, "ts": "wall", "v": format!("value {c} {f}"), "w": writer});
            w.execute(
                "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json) \
                 VALUES (?1, ?2, 'note', ?3, ?4, ?5, ?6, ?7)",
                rusqlite::params![id, P, format!("N{c}"), format!("f/{f}"), writer, s, x.to_string()],
            )
            .unwrap();
        }
        for r in 0..20i64 {
            let at = T0 + r * DAY + c;
            let id = format!("r{c}-{r}");
            let x = json!({"id": id, "p": P, "card": format!("C{c}"), "kind": "review", "rating": 3, "hlc": format!("{at}:0:old"),
                "at": at, "ts": "anchored", "origin": "fushi", "rtype": "review", "utcOff": 0, "rollover": 4, "fv": 1,
                "res": {"queue": "review", "dueDay": 19_700 + r, "ivl": r, "step": 0, "reps": r + 1, "lapses": 0, "scheduler": "fushi"}});
            w.execute(
                "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, json) \
                 VALUES (?1, ?2, ?3, 'review', 3, ?4, 'review', 'fushi', ?5)",
                rusqlite::params![id, P, format!("C{c}"), at, x.to_string()],
            )
            .unwrap();
        }
    }
    w.execute_batch("COMMIT").unwrap();
    drop(w);
    let t = Instant::now();
    let mut longest = 0u128;
    let mut n = 0;
    loop {
        let b = Instant::now();
        let m = a.core.sync2_migrate(P, T0, Some(batch)).unwrap();
        longest = longest.max(b.elapsed().as_millis());
        n += 1;
        if m["done"] == json!(true) {
            break;
        }
    }
    println!(
        "bench_migrate cards={cards} reviews={} edits={} batch={batch} batches={n} total={}ms longest_batch={longest}ms",
        cards * 20,
        cards * 3,
        t.elapsed().as_millis()
    );
}

/// 投影里一条笔记的物化视图（Dart `srsMaterializeNotes` 同一个内核入口）：读 `srs_field_edits` 的落库行。
fn materialized_note(d: &Device, note: &str) -> Value {
    let rows = d.rows(&format!("SELECT json FROM srs_field_edits WHERE entity_kind = 'note' AND entity_id = '{note}' ORDER BY id"));
    let items: Vec<&str> = rows.iter().skip(1).map(|r| r[0].as_str()).collect();
    let header = json!([{"t": "note", "n": items.len(), "rec": {"noteTypeId": "T", "guid": "g", "createdAt": 1}}]).to_string();
    let mut text = String::new();
    let mut offs = vec![0u32];
    for i in &items {
        text.push_str(i);
        offs.push(text.len() as u32);
    }
    let servers = vec![crate::history::NONE_I64; items.len()];
    let out = crate::registers::materialize(header.as_bytes(), text.as_bytes(), &offs, &servers).unwrap();
    serde_json::from_slice::<Value>(&out).unwrap()[0].clone()
}

/// BUG：带标签的笔记删掉后一直挂在「等你决定的笔记」里，再点「确认删除」也消不掉。标签 OR-Set 投影出的
/// 合成 `tags` 行没有因果 dot（写入者 `sync2:tags:<笔记>`、ctx 空），寄存器内核把它当成「与删除并发的修改」，
/// 任何删除都看不见它 → `pd` 恒真。合成行与删除的并发由 sync2 扣住机制（按 `#tag` 操作）判定，内核不再判它。
#[test]
fn deleting_a_tagged_note_is_not_a_pending_decision() {
    let a = Device::new("a");
    let b = Device::new("b");
    let mut bucket = Bucket::default();
    a.apply(T0, vec![edit("note", "N1", "f/x", json!("v1")), edit("note", "N1", "tags", json!(["vocab"]))]);
    a.apply(T0 + 1, vec![edit("note", "N1", "deleted", json!(T0 + 1))]);
    let v = materialized_note(&a, "N1");
    assert_eq!(v["v"]["da"], json!(T0 + 1), "{v}");
    assert_eq!(v["v"]["pd"], json!(false), "a plain delete of a tagged note is not a conflict: {v}");
    assert_eq!(v["x"], json!([]), "{v}");
    // 「确认删除」= 再写一次删除：仍是已删、不待裁决；同步到另一台设备、再收一遍同样的段也不冒出来。
    a.apply(T0 + 2, vec![edit("note", "N1", "deleted", json!(T0 + 2))]);
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + 3);
        b.sync(&mut bucket, "loc", T0 + 3);
    }
    for d in [&a, &b] {
        let v = materialized_note(d, "N1");
        assert!(v["v"]["da"].is_i64(), "{v}");
        assert_eq!(v["v"]["pd"], json!(false), "{v}");
        assert!(d.core.sync2_conflicts(P).unwrap().as_array().unwrap().is_empty());
    }
    assert_eq!(projection(&a), projection(&b));
}

/// 删除 ⟂ 另一台设备上改标签：sync2 照样扣住删除进冲突中心（合成行不被内核判，不等于不判）；选「删除」后
/// 笔记已删、不待裁决、冲突清空，再收同样的段不重新冒出；选「保留」后笔记照旧在、标签是加胜的结果。
#[test]
fn delete_concurrent_with_tag_change_resolves_either_way() {
    for delete in [true, false] {
        let a = Device::new("a");
        let b = Device::new("b");
        let mut bucket = Bucket::default();
        a.apply(T0, vec![edit("note", "N1", "f/x", json!("v1")), edit("note", "N1", "tags", json!(["vocab"]))]);
        a.sync(&mut bucket, "loc", T0);
        b.sync(&mut bucket, "loc", T0);
        a.apply(T0 + 1, vec![edit("note", "N1", "deleted", json!(T0 + 1))]);
        b.apply(T0 + 2, vec![edit("note", "N1", "tags", json!(["vocab", "new"]))]);
        for _ in 0..2 {
            a.sync(&mut bucket, "loc", T0 + 3);
            b.sync(&mut bucket, "loc", T0 + 3);
        }
        let c = a.core.sync2_conflicts(P).unwrap();
        assert_eq!(c.as_array().unwrap().len(), 1, "{c}");
        assert_eq!(materialized_note(&a, "N1")["v"]["da"], Value::Null, "held: still visible");
        a.core.sync2_resolve(P, c[0]["id"].as_str().unwrap(), delete, T0 + 4).unwrap();
        for _ in 0..2 {
            a.sync(&mut bucket, "loc", T0 + 5);
            b.sync(&mut bucket, "loc", T0 + 5);
        }
        // 再收一遍全部段（重复投递）：结论不变。
        let all: Vec<Vec<u8>> = bucket.0.values().cloned().collect();
        for d in [&a, &b] {
            d.core.sync2_ingest(P, &all, None, T0 + 6).unwrap();
        }
        for d in [&a, &b] {
            let v = materialized_note(d, "N1");
            assert_eq!(v["v"]["da"].is_i64(), delete, "{v}");
            assert_eq!(v["v"]["pd"], json!(false), "{v}");
            assert!(d.core.sync2_conflicts(P).unwrap().as_array().unwrap().is_empty());
            if !delete {
                assert_eq!(v["v"]["t"], json!(["vocab", "new"]), "{v}");
            }
        }
        assert_eq!(projection(&a), projection(&b));
    }
}

/// 分批收段（`ingest_begin` / `ingest_batch` / `ingest_finish`，Dart 侧按字节预算切批）与一次收完对拍：同一份
/// 初始库、同一组段字节，分叉点、冻结点、重签发的操作与最终投影都一样。本机身份的段散在不同批里、且后到的那批
/// 才含更早的分叉点——批内各自换身份会挑错分叉点（4 而不是 2），换身份也会早于其它设备的操作投递。
#[test]
fn batched_ingest_session_matches_one_shot_ingest() {
    let deck = super::config::default_deck_id(P);
    let a = Device::new("a");
    let mut home = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("Default"))]);
    a.sync(&mut home, "loc", T0);
    // twin1 在 a 的 seq 2 处拷走，twin2 在 seq 4 处拷走；各自往只有自己看得见的位置发旧身份的段。
    let twin1 = Device::copy_of(&a, "twin1");
    a.apply(T0 + 10, vec![review("ra1", "C", T0 + 10, 3, "learn"), edit("note", "N1", "f/x", json!("a1"))]);
    let twin2 = Device::copy_of(&a, "twin2");
    a.apply(T0 + 20, vec![review("ra2", "C", T0 + 20, 3, "review"), edit("note", "N1", "f/y", json!("a2"))]);
    twin1.apply(T0 + 30, vec![review("rt1", "C", T0 + 30, 4, "learn")]);
    twin2.apply(T0 + 40, vec![review("rt2", "C", T0 + 40, 2, "review")]);
    let mut b1 = Bucket::default();
    let mut b2 = Bucket::default();
    twin1.sync(&mut b1, "loc1", T0 + 50);
    twin2.sync(&mut b2, "loc2", T0 + 50);
    // 两台普通设备，看过 a 的早期操作后各写一些。
    let mut others = home.clone();
    let o1 = Device::new("o1");
    let o2 = Device::new("o2");
    o1.sync(&mut others, "loc", T0 + 60);
    o1.apply(T0 + 61, vec![review("r-o1", "C", T0 + 61, 3, "review"), edit("note", "N1", "f/z", json!("o1"))]);
    o1.sync(&mut others, "loc", T0 + 62);
    o2.apply(T0 + 63, vec![edit("note", "N2", "f/x", json!("o2"))]);
    o2.sync(&mut others, "loc", T0 + 64);

    let segs = |b: &Bucket| -> Vec<Vec<u8>> {
        b.0.iter().filter(|(k, _)| k.contains("/seg-")).map(|(_, v)| v.clone()).collect()
    };
    let heads: Vec<Vec<u8>> = others
        .0
        .iter()
        .filter(|(k, _)| k.rsplit('/').next().and_then(crate::sync2::segment::parse_head_file_name).is_some())
        .map(|(_, v)| v.clone())
        .collect();
    let own1 = segs(&b1);
    let own2 = segs(&b2);
    let remote = segs(&others);
    assert!(!own1.is_empty() && !own2.is_empty() && remote.len() >= 2);

    let one = Device::copy_of(&a, "one");
    let many = Device::copy_of(&a, "many");
    for d in [&one, &many] {
        d.core.sync2_identity(P, T0 + 70).unwrap();
        d.core.sync2_plan(P, &heads).unwrap();
    }
    let all: Vec<Vec<u8>> = own1.iter().chain(&own2).chain(&remote).cloned().collect();
    let r1: Value = serde_json::from_str(&one.core.sync2_ingest(P, &all, None, T0 + 80).unwrap()).unwrap();
    assert_eq!(r1["fork"], json!(true), "{r1}");

    // 批次：twin2 的段（分叉点 4）→ 各远端段各一批 → twin1 的段（分叉点 2）。
    let mut batches: Vec<Vec<Vec<u8>>> = vec![own2.clone()];
    batches.extend(remote.iter().map(|s| vec![s.clone()]));
    batches.push(own1.clone());
    many.core.sync2_ingest_begin(P).unwrap();
    let mut applied = 0;
    for b in &batches {
        let r: Value = serde_json::from_str(&many.core.sync2_ingest_batch(P, b.to_vec(), None, T0 + 80).unwrap()).unwrap();
        assert_eq!(r["fork"], json!(false), "rotation is deferred to finish: {r}");
        assert_eq!(r["errors"], json!([]), "{r}");
        applied += r["applied"].as_u64().unwrap();
    }
    let rn: Value = serde_json::from_str(&many.core.sync2_ingest_finish(P, T0 + 80).unwrap()).unwrap();
    assert_eq!(rn["fork"], json!(true), "{rn}");
    assert_eq!(applied, r1["applied"].as_u64().unwrap());
    assert!(many.core.sync2_ingest_finish(P, T0 + 80).is_err(), "the session is consumed");

    // 旧身份冻结在同一个分叉点（2 = twin1 拷走时的 seq）。
    let old = a.core.sync2_status(P).unwrap()["device"].as_str().unwrap().to_owned();
    let frozen = |d: &Device| {
        d.rows(&format!(
            "SELECT lower(hex(device)), applied FROM sync2_devices WHERE profile_uid = '{P}' AND frozen = 1"
        ))
    };
    assert_eq!(frozen(&one), frozen(&many));
    assert_eq!(frozen(&one).len(), 2, "exactly the old identity is frozen: {:?}", frozen(&one));
    assert_eq!(frozen(&one)[1][1], "2", "frozen at twin1's copy point: {:?}", frozen(&one));
    // 投影与重签发的操作（新身份是随机的，换成占位后比）。
    let norm = |d: &Device| {
        let new = d.core.sync2_status(P).unwrap()["device"].as_str().unwrap().to_owned();
        assert_ne!(new, old);
        let mut rows = projection(d);
        rows.extend(d.rows(&format!(
            "SELECT o.seq, o.kind, lower(hex(o.payload)) FROM sync2_ops o JOIN sync2_self s ON s.profile_uid = o.profile_uid AND s.device = o.device              WHERE o.profile_uid = '{P}' ORDER BY o.seq"
        )));
        // 重签发的修改记录 ID 由写入者（新身份）派生：换成占位后去掉 ID、排序再比。
        let mut out: Vec<String> = rows
            .into_iter()
            .map(|r| {
                let r: Vec<String> = r.into_iter().map(|c| c.replace(&new, "NEW")).collect();
                match serde_json::from_str::<Value>(r.last().unwrap()) {
                    Ok(Value::Object(mut m)) if m.get("w") == Some(&json!("NEW")) => {
                        m.remove("id");
                        Value::Object(m).to_string()
                    }
                    _ => format!("{r:?}"),
                }
            })
            .collect();
        out.sort();
        out
    };
    assert_eq!(norm(&one), norm(&many));
    // 反例：每批各自一次收完（批内就换身份）会挑错分叉点——对拍确实区分得出。
    let naive = Device::copy_of(&a, "naive");
    naive.core.sync2_identity(P, T0 + 70).unwrap();
    naive.core.sync2_plan(P, &heads).unwrap();
    for b in &batches {
        naive.core.sync2_ingest(P, b, None, T0 + 80).unwrap();
    }
    assert_ne!(frozen(&naive), frozen(&one), "per-batch rotation freezes at the wrong point");

    // 投递切片（`ingest_commit` 每次只投 k 条，切点落在段中间、本机段比链中途、因果缓冲里）：报错、分叉点、
    // 冻结点与投影都与一次收完相同。混进一段读不出段头的字节，报错的顺序也要一样。
    let garbage = vec![0x42u8; 7];
    let mut with_garbage = all.clone();
    with_garbage.insert(3, garbage);
    let oneg = Device::copy_of(&a, "oneg");
    oneg.core.sync2_identity(P, T0 + 70).unwrap();
    oneg.core.sync2_plan(P, &heads).unwrap();
    let rg: Value = serde_json::from_str(&oneg.core.sync2_ingest(P, &with_garbage, None, T0 + 80).unwrap()).unwrap();
    assert!(!rg["errors"].as_array().unwrap().is_empty(), "{rg}");
    for k in [1usize, 3] {
        let sliced = Device::copy_of(&a, &format!("sliced{k}"));
        sliced.core.sync2_identity(P, T0 + 70).unwrap();
        sliced.core.sync2_plan(P, &heads).unwrap();
        sliced.core.sync2_ingest_begin(P).unwrap();
        sliced.core.sync2_ingest_prepare(P, with_garbage.clone(), None).unwrap();
        let (mut applied, mut errors, mut commits) = (0, Vec::new(), 0);
        loop {
            let r: Value = serde_json::from_str(
                &sliced.core.sync2_ingest_commit(P, T0 + 80, super::transport::CommitBudget::ops(k)).unwrap(),
            )
            .unwrap();
            commits += 1;
            applied += r["applied"].as_u64().unwrap();
            errors.extend(r["errors"].as_array().unwrap().iter().cloned());
            if r["more"] != json!(true) {
                break;
            }
        }
        assert!(commits as u64 > rg["applied"].as_u64().unwrap() / k as u64, "k={k}: {commits} commits");
        assert_eq!(applied, rg["applied"].as_u64().unwrap(), "k={k}");
        assert_eq!(Value::Array(errors), rg["errors"], "k={k}");
        let rn: Value = serde_json::from_str(&sliced.core.sync2_ingest_finish(P, T0 + 80).unwrap()).unwrap();
        assert_eq!(rn["fork"], json!(true), "k={k}: {rn}");
        assert_eq!(frozen(&sliced), frozen(&oneg), "k={k}");
        assert_eq!(norm(&sliced), norm(&oneg), "k={k}");
    }
    assert_eq!(norm(&oneg), norm(&one), "the unreadable segment changes nothing else");
}

/// 切片之间留在因果缓冲里的操作：y 的操作依赖 x 的，先收 y（全进缓冲），再按每片 1 条收 x——每片收尾把设备进度
/// 与没投上的写进缓冲表、下一片重新读，x 投完后 y 的随之投上。投影与一次收完全部相同，缓冲最后清空。
#[test]
fn sliced_ingest_carries_waiting_ops_across_slices() {
    let x = Device::new("x");
    let y = Device::new("y");
    let mut bucket = Bucket::default();
    x.apply(T0, (0..5).map(|i| review(&format!("x{i}"), "C", T0 + i, 3, "review")).collect());
    x.sync(&mut bucket, "loc", T0 + 10);
    y.sync(&mut bucket, "loc", T0 + 11);
    y.apply(T0 + 20, (0..4).map(|i| review(&format!("y{i}"), "C", T0 + 20 + i, 2, "review")).collect());
    y.sync(&mut bucket, "loc", T0 + 30);
    let dev = |d: &Device| d.core.sync2_status(P).unwrap()["device"].as_str().unwrap().to_owned();
    let segs_of = |id: &str| -> Vec<Vec<u8>> {
        bucket.0.iter().filter(|(k, _)| k.contains("/seg-") && k.contains(id)).map(|(_, v)| v.clone()).collect()
    };
    let (xs, ys) = (segs_of(&dev(&x)), segs_of(&dev(&y)));
    assert!(!xs.is_empty() && !ys.is_empty());
    let heads: Vec<Vec<u8>> = bucket
        .0
        .iter()
        .filter(|(k, _)| k.rsplit('/').next().and_then(crate::sync2::segment::parse_head_file_name).is_some())
        .map(|(_, v)| v.clone())
        .collect();

    let whole = Device::new("whole");
    whole.core.sync2_identity(P, T0 + 40).unwrap();
    whole.core.sync2_plan(P, &heads).unwrap();
    let all: Vec<Vec<u8>> = ys.iter().chain(&xs).cloned().collect();
    let rw: Value = serde_json::from_str(&whole.core.sync2_ingest(P, &all, None, T0 + 50).unwrap()).unwrap();
    assert_eq!(rw["pending"], json!(0), "{rw}");

    let z = Device::new("z");
    z.core.sync2_identity(P, T0 + 40).unwrap();
    z.core.sync2_plan(P, &heads).unwrap();
    z.core.sync2_ingest_begin(P).unwrap();
    let commit_all = |segs: &[Vec<u8>], k: usize| -> (u64, i64, usize) {
        z.core.sync2_ingest_prepare(P, segs.to_vec(), None).unwrap();
        let (mut applied, mut commits) = (0, 0);
        loop {
            let r: Value =
                serde_json::from_str(&z.core.sync2_ingest_commit(P, T0 + 50, super::transport::CommitBudget::ops(k)).unwrap())
                    .unwrap();
            commits += 1;
            applied += r["applied"].as_u64().unwrap();
            assert_eq!(r["errors"], json!([]), "{r}");
            if r["more"] != json!(true) {
                return (applied, r["pending"].as_i64().unwrap(), commits);
            }
        }
    };
    let (applied_y, pending_y, _) = commit_all(&ys, 2);
    assert_eq!(applied_y, 0, "y waits for x");
    assert_eq!(pending_y, 4);
    let (applied_x, pending, commits) = commit_all(&xs, 1);
    assert_eq!(applied_x, rw["applied"].as_u64().unwrap());
    assert_eq!(pending, 0);
    assert!(commits >= 9, "one op per slice: {commits}");
    z.core.sync2_ingest_finish(P, T0 + 51).unwrap();
    assert_eq!(projection(&z), projection(&whole));
}

/// 有写入在等写锁（[SrsCore::sync2_ingest_yield]）：正在投的那一片做满保底条数就收，返回 `more`；收片后请求
/// 清掉，下一片照常投，全部投完的条数不变。
#[test]
fn ingest_yield_cuts_the_running_slice_short() {
    use super::transport::CommitBudget;
    let a = Device::new("a");
    let mut bucket = Bucket::default();
    a.apply(T0, (0..300).map(|i| review(&format!("r{i}"), "C", T0 + i, 3, "review")).collect());
    a.sync(&mut bucket, "loc", T0 + 400);
    let b = Device::new("b");
    b.sync(&mut Bucket::default(), "loc", T0 + 401);
    let heads: Vec<Vec<u8>> = bucket
        .0
        .iter()
        .filter(|(k, _)| k.rsplit('/').next().and_then(crate::sync2::segment::parse_head_file_name).is_some())
        .map(|(_, v)| v.clone())
        .collect();
    b.core.sync2_plan(P, &heads).unwrap();
    let segs: Vec<Vec<u8>> = bucket.0.iter().filter(|(k, _)| k.contains("/seg-")).map(|(_, v)| v.clone()).collect();
    b.core.sync2_ingest_begin(P).unwrap();
    b.core.sync2_ingest_prepare(P, segs.clone(), None).unwrap();
    b.core.sync2_ingest_yield();
    let first: Value =
        serde_json::from_str(&b.core.sync2_ingest_commit(P, T0 + 402, CommitBudget::slice(b.core.ingest_yield_flag())).unwrap())
            .unwrap();
    assert_eq!(first["applied"], json!(64), "{first}");
    assert_eq!(first["more"], json!(true), "{first}");
    assert!(!b.core.ingest_yield_flag().load(std::sync::atomic::Ordering::Relaxed), "the request is cleared");
    let mut applied = 64;
    loop {
        let r: Value =
            serde_json::from_str(&b.core.sync2_ingest_commit(P, T0 + 402, CommitBudget::slice(b.core.ingest_yield_flag())).unwrap())
                .unwrap();
        applied += r["applied"].as_u64().unwrap();
        if r["more"] != json!(true) {
            break;
        }
    }
    assert_eq!(applied, 300);
    b.core.sync2_ingest_finish(P, T0 + 403).unwrap();
}

/// 会话边界：没开会话就收批 / 收尾报错；会话期间本机换了身份，收批报错且会话作废。
#[test]
fn ingest_session_requires_begin_and_a_stable_identity() {
    let a = Device::new("a");
    a.core.sync2_identity(P, T0).unwrap();
    assert!(a.core.sync2_ingest_batch(P, Vec::new(), None, T0).is_err());
    assert!(a.core.sync2_ingest_finish(P, T0).is_err());
    a.core.sync2_ingest_begin(P).unwrap();
    a.core.sync2_rotate(P, T0 + 1).unwrap();
    assert!(a.core.sync2_ingest_batch(P, Vec::new(), None, T0 + 2).is_err());
    assert!(a.core.sync2_ingest_finish(P, T0 + 2).is_err(), "a failed batch drops the session");
}

/// 一轮什么都没变时不再写 head（反馈：每写一次 head 互联 host 就唤醒全部设备，空 head 让同步一轮接一轮不停）。
#[test]
fn unchanged_head_is_not_rewritten_until_content_changes_or_heartbeat() {
    use super::transport::HeadWrite;
    const HOUR: i64 = 3_600_000;
    let a = Device::new("a");
    let b = Device::new("b");
    let mut bucket = Bucket::default();
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck)]);
    a.sync(&mut bucket, "loc", T0);
    // 与生产（srs_sync2_round.dart）同序：发件 → 摘要 → head。
    fn write_head(d: &Device, bucket: &mut Bucket, now: i64) -> HeadWrite {
        let upto = d.upload_all(bucket, "loc");
        d.core.sync2_digest_due(P, now, Some(0)).unwrap();
        d.core.sync2_head_if_changed(P, "loc", upto, now, Some(6 * HOUR)).unwrap()
    }
    // 测试辅助的 sync 在 head 之后才算摘要：第一次按生产顺序写会带上新摘要。
    if let HeadWrite::Written { path, bytes, .. } = write_head(&a, &mut bucket, T0 + 500) {
        bucket.0.insert(path, bytes);
    }
    // 内容没变 → 不写，指回上次的 head。
    let last = match write_head(&a, &mut bucket, T0 + 1000) {
        HeadWrite::Unchanged { path, .. } => path,
        HeadWrite::Written { .. } => panic!("an unchanged head must not be rewritten"),
    };
    assert!(bucket.0.contains_key(&last), "points at the head already on the location: {last}");
    // 本机有新操作 → 写。
    a.apply(T0 + 2000, vec![edit("deck", &deck, "name", json!("Renamed"))]);
    assert!(matches!(write_head(&a, &mut bucket, T0 + 3000), HeadWrite::Written { .. }));
    assert!(matches!(write_head(&a, &mut bucket, T0 + 4000), HeadWrite::Unchanged { .. }));
    // 收到别的设备的操作（只有 ack / 摘要变了）→ 不急着写（审查 S-8：ack 变化不再立刻唤醒对端，旧段删除也不等 ack），
    // 过了 ACK_ONLY_HEAD_MS 才发布。
    let ack_only = super::transport::ACK_ONLY_HEAD_MS;
    b.apply(T0 + 5000, vec![edit("note", "N1", "f/x", json!("b"))]);
    b.sync(&mut bucket, "loc", T0 + 5000);
    a.core.sync2_identity(P, T0 + 6000).unwrap();
    let heads: Vec<Vec<u8>> = bucket.0.iter().filter(|(k, _)| k.contains("/head-")).map(|(_, v)| v.clone()).collect();
    let segs: Vec<Vec<u8>> = bucket.0.iter().filter(|(k, _)| k.contains("/seg-")).map(|(_, v)| v.clone()).collect();
    a.core.sync2_plan_at(P, &heads, Some("loc")).unwrap();
    let r: Value = serde_json::from_str(&a.core.sync2_ingest(P, &segs, None, T0 + 6000).unwrap()).unwrap();
    assert!(r["applied"].as_u64().unwrap() > 0, "{r}");
    assert!(matches!(write_head(&a, &mut bucket, T0 + 6500), HeadWrite::Unchanged { .. }), "an ack-only change waits");
    assert!(matches!(write_head(&a, &mut bucket, T0 + 1000 + ack_only - 1), HeadWrite::Unchanged { .. }));
    assert!(
        matches!(write_head(&a, &mut bucket, T0 + 3000 + ack_only), HeadWrite::Written { .. }),
        "the new ack (and its digest) is published after ACK_ONLY_HEAD_MS"
    );
    assert!(matches!(write_head(&a, &mut bucket, T0 + 4000 + ack_only), HeadWrite::Unchanged { .. }));
    // ack 变了的同时本机也有新段 → 照常立刻写。
    b.apply(T0 + 8000 + ack_only, vec![edit("note", "N1", "f/y", json!("b2"))]);
    b.sync(&mut bucket, "loc", T0 + 8000 + ack_only);
    a.sync(&mut bucket, "loc", T0 + 9000 + ack_only);
    a.apply(T0 + 9500 + ack_only, vec![edit("deck", &deck, "name", json!("Again"))]);
    assert!(matches!(write_head(&a, &mut bucket, T0 + 9600 + ack_only), HeadWrite::Written { .. }));
    // 到了心跳期限照写（seenAt / 校时靠它刷新）。
    assert!(matches!(write_head(&a, &mut bucket, T0 + 9600 + ack_only + 6 * HOUR), HeadWrite::Written { .. }));
}

/// 反馈 8TaOy2i-lL / BUG-3809：一个库文件里的多个 profile 共用 `srs_field_edits`（主键只有 `id`），
/// 修改记录 ID 由 dot `(writer, seq)` 派生、不含 profile。v2 之前 Dart 的写入者每台设备一个
/// （`<deviceId>#<incarnation>`）、序号却按 profile 各记各的，新 profile 从 seq 1 起写就撞上老 profile 的
/// 同 ID 行（导入 APKG 整批回滚）。v2 起本机写入的 dot 由 Rust 按「该 profile 的本机身份」重新分配（每个
/// profile 一个随机 v7 设备 ID），Dart 给的 w / s / id 一律不读。这里钉住：老 profile 留着旧写入者 1..N 的
/// 行（已迁移成操作），新 profile 带同一组旧 dot 的草稿写入照样全部落库、ID 与老 profile 不相交，老 profile 不动。
#[test]
fn second_profile_writes_never_reuse_another_profiles_edit_ids() {
    const Q: &str = "0193a1b2-0000-7000-8000-00000000cafe";
    let a = Device::new("profiles");
    let legacy_writer = "11111111-2222-4333-8444-555555555555#1";
    let legacy_row = |profile: &str, entity: &str, s: i64| {
        let id = crate::registers::edit_id(legacy_writer, s);
        let x = json!({
            "ctx": {"vv": {}}, "e": entity, "f": format!("f/{s}"), "hlc": format!("{s}:0:{legacy_writer}"),
            "id": id, "k": "note", "p": profile, "s": s, "ts": "wall", "v": "old", "w": legacy_writer,
        });
        (id, x)
    };
    {
        let w = a.core.writer().unwrap();
        for s in 1..=3 {
            let (id, x) = legacy_row(P, "NA", s);
            w.execute(
                "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json) \
                 VALUES (?1, ?2, 'note', 'NA', ?3, ?4, ?5, ?6)",
                rusqlite::params![id, P, format!("f/{s}"), legacy_writer, s, x.to_string()],
            )
            .unwrap();
        }
        // 前提：主键跨 profile 全局唯一——v2 之前的写法（照搬 Dart 给的 ID 落库）在这里就是用户看到的 UNIQUE 失败。
        let (id, x) = legacy_row(Q, "NQ", 1);
        let err = w
            .execute(
                "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json) \
                 VALUES (?1, ?2, 'note', 'NQ', 'f/1', ?3, 1, ?4)",
                rusqlite::params![id, Q, legacy_writer, x.to_string()],
            )
            .unwrap_err();
        assert!(err.to_string().contains("UNIQUE constraint failed: srs_field_edits.id"), "{err}");
    }
    a.core.sync2_migrate(P, T0, None).unwrap();
    let ids_of = |profile: &str| a.rows(&format!("SELECT id, writer_id FROM srs_field_edits WHERE profile_uid = '{profile}' ORDER BY id"));
    let p_rows = ids_of(P);
    assert_eq!(p_rows.len(), 4, "header + 3 legacy rows: {p_rows:?}");

    // 新 profile：草稿带的就是 v2 之前 Dart 会给的那组 dot（同一旧写入者、序号从 1 起）——ID 与老 profile 的完全相同。
    let input: Vec<Value> = (1..=3)
        .map(|s| {
            let (_, mut x) = legacy_row(Q, "NQ", s);
            x["v"] = json!("new");
            json!({"e": {"t": "edit", "x": x}, "note": "NQ"})
        })
        .collect();
    let r: Value = serde_json::from_str(&a.core.sync2_apply_local(Q, T0 + 1, &Value::Array(input).to_string()).unwrap()).unwrap();
    assert_eq!(r["landed"], json!([true, true, true]), "{r}");

    let q_rows = ids_of(Q);
    assert_eq!(q_rows.len(), 4, "header + 3 rows: {q_rows:?}");
    let device = |profile: &str| a.core.sync2_status(profile).unwrap()["device"].as_str().unwrap().to_owned();
    let q_device = device(Q);
    assert_ne!(q_device, device(P), "each profile has its own local identity");
    for row in q_rows.iter().skip(1) {
        assert_eq!(row[1], q_device, "dot reassigned to the profile's own device: {row:?}");
        assert!(!p_rows.iter().skip(1).any(|x| x[0] == row[0]), "edit id {} reused across profiles", row[0]);
    }
    assert_eq!(ids_of(P), p_rows, "old profile untouched");
}

/// 分批发件（反馈 XDV7Mzc2gw / kB2ltk0u9F / U37Aku3oeL）：20 万条小操作的积压——每批字节 / 段数有上限（峰值与积压
/// 总量无关），每批确认后水位前进；上传中途断掉的那一轮之后，下一轮从水位接着发，不重发已确认的批。
#[test]
fn a_huge_backlog_is_sent_in_bounded_batches_and_resumes_from_the_watermark() {
    use super::transport::{OUTBOX_BATCH_BYTES, OUTBOX_BATCH_SEGMENTS};
    use crate::sync2::segment::SEGMENT_TARGET_BYTES;
    const N: i64 = 200_000;
    let a = Device::new("backlog");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck)]);
    for chunk in 0..(N / 2000) {
        let events: Vec<Value> = (0..2000)
            .map(|i| {
                let n = chunk * 2000 + i;
                // 一条小编辑（复习的回放代价与本测试无关，只要操作条数）；散列值不让整批压成几个字节。
                edit("note", &format!("N{n}"), "f/x", json!(blake3::hash(&n.to_le_bytes()).to_hex().to_string()))
            })
            .collect();
        a.apply(T0 + chunk, events);
    }

    // 1) 默认预算把整份积压发到一个位置：每批都在上限内，段不重不漏。
    let mut probe = Bucket::default();
    let (mut batches, mut seen) = (0usize, BTreeMap::<u64, u64>::new());
    loop {
        let b = a.core.sync2_outbox(P, "probe", None, OUTBOX_BATCH_BYTES, OUTBOX_BATCH_SEGMENTS).unwrap();
        if b.files.is_empty() {
            break;
        }
        batches += 1;
        let bytes: u64 = b.files.iter().map(|f| f.1.len() as u64).sum();
        assert!(b.files.len() <= OUTBOX_BATCH_SEGMENTS);
        // 段体积估计（各小块分别压缩之和）对不可压缩的内容不是严格上界，实测超出 < 0.3%：每段留 1/64 余量。
        let slack = SEGMENT_TARGET_BYTES / 64;
        assert!(b.files.iter().all(|f| (f.1.len() as u64) < SEGMENT_TARGET_BYTES + slack));
        assert!(b.files.len() == 1 || bytes <= OUTBOX_BATCH_BYTES + slack * b.files.len() as u64, "batch of {bytes} bytes");
        for &(f, l) in &b.segments {
            assert!(seen.insert(f, l).is_none(), "segment {f}-{l} sent twice");
        }
        for (p, x) in b.files {
            probe.0.insert(p, x);
        }
        let (ok, mark) = a.core.sync2_outbox_ack(P, "probe", &b.segments).unwrap();
        assert!(ok);
        assert_eq!(mark, b.upto);
        if !b.more {
            break;
        }
    }
    let segs: Vec<(u64, u64)> = a.rows("SELECT first, last FROM sync2_segments ORDER BY first")[1..]
        .iter()
        .map(|r| (r[0].parse().unwrap(), r[1].parse().unwrap()))
        .collect();
    assert!(segs.len() >= 3, "{} segments", segs.len());
    assert_eq!(seen.into_iter().collect::<Vec<_>>(), segs);
    eprintln!("{} segments in {batches} default-budget batches", segs.len());

    // 2) 另一个位置一段一批：第一批确认，第二批上传失败（没确认）——下一轮从第二批接着发，第一批不再发。
    let mut bucket = Bucket::default();
    let mut puts: BTreeMap<String, usize> = BTreeMap::new();
    let first = a.core.sync2_outbox(P, "loc", None, OUTBOX_BATCH_BYTES, 1).unwrap();
    assert!(first.more);
    for (p, x) in first.files {
        *puts.entry(p.clone()).or_default() += 1;
        bucket.0.insert(p, x);
    }
    assert_eq!(a.core.sync2_outbox_ack(P, "loc", &first.segments).unwrap(), (true, first.upto));
    let failed = a.core.sync2_outbox(P, "loc", None, OUTBOX_BATCH_BYTES, 1).unwrap();
    assert_ne!(failed.segments, first.segments, "watermark advanced after the first ack");
    drop(failed.files); // 上传中途断网：这一批没写成，也没确认。
    let resumed = a.core.sync2_outbox(P, "loc", None, OUTBOX_BATCH_BYTES, 1).unwrap();
    assert_eq!(resumed.segments, failed.segments, "resume from the watermark, not from scratch");
    assert!(resumed.segments[0].0 > first.segments[0].1);
    // 认不出的段（切法已变）不算数：水位不动。
    assert_eq!(a.core.sync2_outbox_ack(P, "loc", &[(999_999_999, 999_999_999)]).unwrap(), (false, first.upto));
    loop {
        let b = a.core.sync2_outbox(P, "loc", None, OUTBOX_BATCH_BYTES, 1).unwrap();
        if b.files.is_empty() {
            break;
        }
        for (p, x) in b.files {
            *puts.entry(p.clone()).or_default() += 1;
            bucket.0.insert(p, x);
        }
        a.core.sync2_outbox_ack(P, "loc", &b.segments).unwrap();
        if !b.more {
            break;
        }
    }
    assert!(puts.values().all(|n| *n == 1), "no confirmed segment uploaded twice: {puts:?}");
    // 收尾：写 head，新设备从这个位置收齐全部 20 万条。
    a.sync(&mut bucket, "loc", T0 + DAY);
    let c = Device::new("backlogc");
    c.sync(&mut bucket, "loc", T0 + DAY);
    let count = |d: &Device| d.rows("SELECT COUNT(*) FROM srs_field_edits")[1][0].parse::<i64>().unwrap();
    assert!(count(&a) >= N);
    assert_eq!(count(&c), count(&a));
    assert_eq!(a.digest(), c.digest());
}

fn media_known(d: &Device, loc: &str) -> (bool, Vec<String>) {
    let v = d.core.sync2_media_known(P, loc).unwrap();
    let names = v["present"].as_array().unwrap().iter().map(|x| x.as_str().unwrap().to_owned()).collect();
    (v["seeded"] == json!(true), names)
}

fn strs(xs: &[&str]) -> Vec<String> {
    xs.iter().map(|s| (*s).to_owned()).collect()
}

/// 设计 §6.4：位置的媒体目录内容记在日志里。A 对位置列举一次（带 seeded），B 只靠同步收到的操作就知道
/// 该位置已列举过、里面有什么；之后的增删按 HLC 大者胜，各设备收敛到同一张表；与投影一致的事实不重复记。
#[test]
fn media_presence_travels_in_the_log_and_converges() {
    let a = Device::new("ma");
    let b = Device::new("mb");
    let mut bucket = Bucket::default();
    const L: &str = "drive:acct/media";

    assert_eq!(media_known(&a, L), (false, vec![]));
    let many: Vec<String> = (0..(crate::sync2::op::MEDIA_AT_MAX_NAMES + 5)).map(|i| format!("m{i:05}.mp3")).collect();
    let r = a.core.sync2_media_record(P, L, &many, &[], true, T0).unwrap();
    // 超过单条上限的名字切成两条，外加一条列举标记。
    assert_eq!(r["appended"], json!(3));
    assert_eq!(media_known(&a, L), (true, many.clone()));

    // 同样的事实再记一遍：一条都不追加。
    assert_eq!(a.core.sync2_media_record(P, L, &many[..10], &[], true, T0 + 1).unwrap()["appended"], json!(0));

    a.sync(&mut bucket, "loc", T0 + 2);
    b.sync(&mut bucket, "loc", T0 + 2);
    assert_eq!(media_known(&b, L), (true, many.clone()), "B learns the listing from A's ops, without listing");
    // 别的位置互不相干。
    assert_eq!(media_known(&b, "other/media"), (false, vec![]));

    // B 读不到 m00000（被外部删了）→ 记不在；A 之后补传 → 记在。HLC 大者胜。
    b.core.sync2_media_record(P, L, &[], &strs(&["m00000.mp3"]), false, T0 + 10).unwrap();
    b.sync(&mut bucket, "loc", T0 + 11);
    a.sync(&mut bucket, "loc", T0 + 11);
    assert!(!media_known(&a, L).1.contains(&"m00000.mp3".to_owned()));
    a.core.sync2_media_record(P, L, &strs(&["m00000.mp3", "new.png"]), &[], false, T0 + 20).unwrap();
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + 21);
        b.sync(&mut bucket, "loc", T0 + 21);
    }
    assert_eq!(media_known(&a, L), media_known(&b, L));
    let (_, now) = media_known(&b, L);
    assert!(now.contains(&"m00000.mp3".to_owned()) && now.contains(&"new.png".to_owned()));
    assert_eq!(a.digest(), b.digest());
}

#[test]
fn media_known_reports_absent_names_separately() {
    let a = Device::new("mk");
    a.core.sync2_media_record(P, "l/media", &strs(&["x.mp3"]), &strs(&["gone.png"]), true, T0).unwrap();
    let v = a.core.sync2_media_known(P, "l/media").unwrap();
    assert_eq!(v, json!({"seeded": true, "present": ["x.mp3"], "absent": ["gone.png"]}));
}

/// 投影改动只以粗粒度摘要交回 Dart（`marks`）：受影响的笔记 / 卡 / 笔记类型 + 修订号增量，不带事件全文。
/// 规则与 Dart 旧 `_absorbProjection` 逐条解析一致：界面状态类修改记录只推进界面修订号；笔记类型只有影响缓存行
/// 的键才标脏；牌组 / profile 的非界面状态改动推进 RWKV 修订号；日志只标卡。本机写入与收段同一套。
#[test]
fn projection_changes_come_back_as_coarse_marks_not_event_bodies() {
    let a = Device::new("a");
    let b = Device::new("b");
    let mut bucket = Bucket::default();
    let deck = super::config::default_deck_id(P);
    let batch = vec![
        deck_entity(&deck),
        edit("deck", &deck, "collapsed", json!(true)),
        edit("deck", &deck, "name", json!("Default")),
        edit("notetype", "T1", "css", json!(".x{}")),
        edit("notetype", "T1", "fieldDesc/f1", json!("d")),
        edit("notetype", "T2", "templates", json!([])),
        edit("note", "N1", "f/f1", json!("hello")),
        edit("card", "C1", "newPos", json!(3)),
        edit("card", "C2", "flag", json!(1)),
        review("r1", "C3", T0 + 1, 3, "learn"),
    ];
    let expect = json!({
        "notes": ["N1"], "cards": ["C1", "C2", "C3"], "noteTypes": ["T2"],
        "landed": 10, "content": 7, "view": 2, "rwkv": 2,
    });
    let out = a.apply(T0 + 1, batch);
    assert_eq!(out["marks"], expect, "{out}");
    assert!(out.get("events").is_none(), "no event bodies cross FFI: {out}");
    assert_eq!(out["landed"].as_array().unwrap().len(), 10);

    a.sync(&mut bucket, "loc", T0 + 2);
    let got = b.sync(&mut bucket, "loc", T0 + 2);
    assert_eq!(got["marks"], expect, "ingest reports the same marks: {got}");
    assert!(got.get("events").is_none(), "{got}");

    // 什么都没落（重复收同一批）：摘要为空。
    let again = b.sync(&mut bucket, "loc", T0 + 3);
    assert_eq!(again["marks"]["landed"], json!(0), "{again}");
    assert_eq!(again["marks"]["notes"], json!([]), "{again}");
}

/// 收段的解码 / 验签在写锁外（[SrsCore::sync2_ingest_prepare]）：一批正在解码时，另一线程的本机作答
/// （`apply`）不用等它，只会等锁内的投递。钩子把预处理卡在「公钥已取、解码未开始」处，作答必须在放行之前完成；
/// 放行之后这一批照常投递。
#[test]
fn local_apply_does_not_wait_for_ingest_decoding() {
    use std::sync::mpsc;
    use std::time::Duration;
    let a = Device::new("a");
    let mut bucket = Bucket::default();
    a.apply(T0, (0..200).map(|i| review(&format!("r{i}"), "C", T0 + i, 3, "review")).collect());
    a.sync(&mut bucket, "loc", T0 + 300);
    let b = Device::new("b");
    b.sync(&mut Bucket::default(), "loc", T0 + 301);
    let heads: Vec<Vec<u8>> = bucket
        .0
        .iter()
        .filter(|(k, _)| k.rsplit('/').next().and_then(crate::sync2::segment::parse_head_file_name).is_some())
        .map(|(_, v)| v.clone())
        .collect();
    b.core.sync2_plan(P, &heads).unwrap();
    let segs: Vec<Vec<u8>> = bucket.0.iter().filter(|(k, _)| k.contains("/seg-")).map(|(_, v)| v.clone()).collect();
    assert!(!segs.is_empty());

    let (entered_tx, entered_rx) = mpsc::channel::<()>();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let release_rx = std::sync::Mutex::new(release_rx);
    *b.core.ingest_prepare_hook.lock().unwrap() = Some(Box::new(move || {
        entered_tx.send(()).unwrap();
        release_rx.lock().unwrap().recv_timeout(Duration::from_secs(30)).unwrap();
    }));
    b.core.sync2_ingest_begin(P).unwrap();
    std::thread::scope(|s| {
        let ingest = s.spawn(|| b.core.sync2_ingest_batch(P, segs.clone(), None, T0 + 400));
        entered_rx.recv_timeout(Duration::from_secs(30)).expect("prepare reached the hook");
        // 预处理卡着：作答在另一线程上必须照常完成（写锁、读锁都没被占着）。
        let (done_tx, done_rx) = mpsc::channel::<Value>();
        let bref = &b;
        s.spawn(move || done_tx.send(bref.apply(T0 + 350, vec![review("local", "L", T0 + 350, 4, "review")])).unwrap());
        let applied = done_rx.recv_timeout(Duration::from_secs(10)).expect("apply must not wait for ingest decoding");
        assert!(applied.is_object(), "{applied}");
        assert!(b.core.sync2_status(P).is_ok(), "status reads do not wait either");
        release_tx.send(()).unwrap();
        let r: Value = serde_json::from_str(&ingest.join().unwrap().unwrap()).unwrap();
        assert_eq!(r["errors"], json!([]), "{r}");
        assert_eq!(r["applied"], json!(200), "{r}");
    });
    *b.core.ingest_prepare_hook.lock().unwrap() = None;
    let r: Value = serde_json::from_str(&b.core.sync2_ingest_finish(P, T0 + 401).unwrap()).unwrap();
    assert_eq!(r["fork"], json!(false), "{r}");
    assert_eq!(b.rows(&format!("SELECT COUNT(*) FROM sync2_ops WHERE profile_uid = '{P}'")).last().unwrap()[0], "201");
}

/// 预处理与投递之间设备公钥变了：投递在锁内按当时的公钥重验那一段，结果与在锁内从头处理相同。这里预处理时
/// 还不认识 a（报「未知设备」的那种），投递前看过 a 的 head 登记了公钥：照常投上，不报错。
#[test]
fn ingest_commit_rechecks_device_keys_that_changed_after_prepare() {
    let a = Device::new("a");
    let mut bucket = Bucket::default();
    a.apply(T0, vec![review("r1", "C", T0, 3, "review"), review("r2", "C", T0 + 1, 3, "review")]);
    a.sync(&mut bucket, "loc", T0 + 10);
    let segs: Vec<Vec<u8>> = bucket.0.iter().filter(|(k, _)| k.contains("/seg-")).map(|(_, v)| v.clone()).collect();
    let heads: Vec<Vec<u8>> = bucket
        .0
        .iter()
        .filter(|(k, _)| k.rsplit('/').next().and_then(crate::sync2::segment::parse_head_file_name).is_some())
        .map(|(_, v)| v.clone())
        .collect();

    // 对照：不认识 a 时收，报未知设备。
    let blind = Device::new("blind");
    blind.core.sync2_identity(P, T0 + 20).unwrap();
    let r: Value = serde_json::from_str(&blind.core.sync2_ingest(P, &segs, None, T0 + 30).unwrap()).unwrap();
    assert_eq!(r["applied"], json!(0), "{r}");
    assert!(r["errors"][0].as_str().unwrap().contains("unknown device"), "{r}");

    let b = Device::new("b");
    b.core.sync2_identity(P, T0 + 20).unwrap();
    b.core.sync2_ingest_begin(P).unwrap();
    b.core.sync2_ingest_prepare(P, segs.clone(), None).unwrap();
    b.core.sync2_plan(P, &heads).unwrap();
    let r: Value = serde_json::from_str(&b.core.sync2_ingest_commit(P, T0 + 30, super::transport::CommitBudget::unlimited()).unwrap()).unwrap();
    assert_eq!(r["errors"], json!([]), "{r}");
    assert_eq!(r["applied"], json!(2), "{r}");
    assert!(b.core.sync2_ingest_commit(P, T0 + 30, super::transport::CommitBudget::unlimited()).is_err(), "the prepared batch is consumed");
    b.core.sync2_ingest_finish(P, T0 + 31).unwrap();
}

/// 集成审查【中】：旧小段删除两段式。过了宽限期该删的旧小段这一轮删除失败（head 上传 / `location.delete` 抛错），
/// 记录留在 `sync2_obsolete`；下一轮（写 head 时，以及 head 没变、不写的那一轮）照样再给，删成功并 ack 后才移除。
/// 以前 `take_obsolete` 取出即删记录，失败的这批旧段永远留在位置上。
#[test]
fn failed_obsolete_deletes_are_retried_next_round() {
    let a = Device::new("oa");
    let mut bucket = Bucket::default();
    for i in 0..40 {
        a.apply(T0 + i, vec![review(&format!("r{i}"), "C", T0 + 1000 * i, 3, "review")]);
        a.sync(&mut bucket, "loc", T0 + 1000 * i);
    }
    let before = segment_files(&bucket, &a);
    let rows_pending = |a: &Device| a.rows("SELECT COUNT(*) FROM sync2_obsolete")[1][0].parse::<usize>().unwrap();
    assert!(rows_pending(&a) > 0);
    // 过了宽限期、代号也够了的几轮，删除全部失败。
    FAIL_DELETES.with(|f| f.set(true));
    for k in 0..3 {
        a.sync(&mut bucket, "loc", T0 + DAY + 60_000 + k);
    }
    FAIL_DELETES.with(|f| f.set(false));
    assert_eq!(segment_files(&bucket, &a), before, "nothing was deleted");
    let pending = rows_pending(&a);
    assert!(pending > 0, "the failed deletes are still on record");
    // head 没变、不写的一轮也把待删清单交出来。
    let w = a.core.sync2_head_if_changed(P, "loc", u64::MAX, T0 + DAY + 70_000, Some(DAY)).unwrap();
    match w {
        super::transport::HeadWrite::Unchanged { obsolete, .. } => assert_eq!(obsolete.len(), pending),
        super::transport::HeadWrite::Written { .. } => panic!("head content did not change"),
    }
    // 下一轮正常：删光并确认。
    a.sync(&mut bucket, "loc", T0 + DAY + 80_000);
    assert_eq!(rows_pending(&a), 0);
    let rows = a.rows("SELECT COUNT(*) FROM sync2_segments")[1][0].parse::<usize>().unwrap();
    assert_eq!(segment_files(&bucket, &a), rows, "the stale segments were deleted on the retry");
    // ack 幂等：确认不在记录里的文件不报错、不误删别的记录。
    assert_eq!(a.core.sync2_obsolete_ack(P, "loc", &["devices/x/seg-nope".to_owned()]).unwrap(), 0);
}
