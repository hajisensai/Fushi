//! 摘要不一致的自动重建（heal.rs）：端到端，两台设备经内存哑存储同步，人为把一边的派生日志改旧。

use serde_json::{Value, json};

use super::digest;
use super::tests::{Bucket, DAY, Device, P, deck_entity, log_json, review};
use crate::sync2::id::Id;
use crate::sync2::segment::{Head, parse_head_file_name};

const T0: i64 = 1_700_000_000_000;

fn device_id(d: &Device) -> String {
    d.core.sync2_identity(P, T0).unwrap()["device"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn blob(id: &str) -> Vec<u8> {
    Id::parse(id).unwrap().0.to_vec()
}

fn meta(d: &Device, key: &str) -> Option<String> {
    let rows = d.rows(&format!("SELECT value FROM srs_meta WHERE key = '{key}'"));
    rows.get(1).map(|r| r[0].clone())
}

fn set_meta(d: &Device, key: &str, value: Option<&str>) {
    let w = d.core.writer().unwrap();
    match value {
        Some(v) => w
            .execute(
                "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                rusqlite::params![key, v],
            )
            .unwrap(),
        None => w
            .execute("DELETE FROM srs_meta WHERE key = ?1", [key])
            .unwrap(),
    };
}

/// 本机记下的摘要串。
fn own_digest(d: &Device) -> String {
    meta(d, &format!("sync2_digest/{P}")).unwrap()
}

/// [d] 记下的 [peer] 的摘要串（`sync2_devices.digest`）。
fn peer_digest(d: &Device, peer: &str) -> String {
    let w = d.core.writer().unwrap();
    w.query_row(
        "SELECT digest FROM sync2_devices WHERE device = ?1",
        [blob(peer)],
        |r| r.get(0),
    )
    .unwrap()
}

fn set_peer_digest(d: &Device, peer: &str, digest: &str) {
    let w = d.core.writer().unwrap();
    w.execute(
        "UPDATE sync2_devices SET digest = ?1 WHERE device = ?2",
        rusqlite::params![digest, blob(peer)],
    )
    .unwrap();
}

fn split(digest: &str) -> (String, String) {
    let (r, t) = digest.split_once('@').unwrap();
    (r.to_owned(), t.to_owned())
}

/// 把 [id] 这条日志的派生结果改成旧值（模拟漏跑迁移 / 被打断的重放留下的行）。
fn stale(d: &Device, id: &str) {
    stale_to(d, id, 1);
}

fn stale_to(d: &Device, id: &str, due_day: i64) {
    let mut j = log_json(d, id);
    j["res"]["dueDay"] = json!(due_day);
    let w = d.core.writer().unwrap();
    w.execute(
        "UPDATE srs_review_logs SET jslim = srs_log_pack(?2, id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, duration_ms) WHERE id = srs_id(?1)",
        rusqlite::params![id, j.to_string()],
    )
    .unwrap();
}

/// 一次 heal 里真正重放了几次（每次重放要么修好 `healed`，要么改 0 行报 `replayChangedNothing`）。
fn replays(out: &Value) -> usize {
    out["healed"].as_array().unwrap().len()
        + out["healFailed"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|f| f["reason"] == json!("replayChangedNothing"))
            .count()
}

/// 两台设备、同一批带配置快照的复习（日志带 `sc`，重放会真正重算结果），同步到稳定：同一版本向量、同一个根，
/// 互相记下了对方带组指纹的 head。返回下一轮可用的时刻。
fn converged() -> (Device, Device, Bucket, i64) {
    let a = Device::new("heal-a");
    let b = Device::new("heal-b");
    let deck = super::config::default_deck_id(P);
    let mut bucket = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck)]);
    a.apply(T0 + 10, vec![review("r1", "C", T0 + 10, 3, "learn")]);
    a.apply(T0 + DAY, vec![review("r2", "C", T0 + DAY, 3, "review")]);
    a.apply(T0 + DAY, vec![review("s1", "S", T0 + DAY, 3, "learn")]);
    assert!(log_json(&a, "r2")["sc"].is_object());
    let mut now = T0 + 2 * DAY;
    for _ in 0..3 {
        a.sync(&mut bucket, "loc", now);
        b.sync(&mut bucket, "loc", now + 1);
        now += DAY;
    }
    a.sync(&mut bucket, "loc", now);
    now += DAY;
    assert_eq!(own_digest(&a), own_digest(&b), "converged");
    assert_eq!(peer_digest(&a, &device_id(&b)), own_digest(&b));
    (a, b, bucket, now)
}

/// 本机这一侧的派生行是旧的：heal 比出不同的组、重放那些卡、在同一命令里重算摘要，根与对端相同；再调一次什么都
/// 不做。摘要键一直在（不删键）。
#[test]
fn heal_replays_the_stale_local_cards_and_the_roots_converge() {
    let (a, b, _bucket, now) = converged();
    let want = log_json(&a, "r2");
    let good = own_digest(&a);
    stale(&a, "r2");
    a.digest();
    let (bad_root, tag) = split(&own_digest(&a));
    let (b_root, b_tag) = split(&peer_digest(&a, &device_id(&b)));
    assert_eq!(tag, b_tag, "same rules and version vector");
    assert_ne!(bad_root, b_root, "the stale row moved the root");

    let out = a.core.sync2_digest_heal(P, now).unwrap();
    assert_eq!(out["replayed"], json!(["C"]), "{out}");
    assert_eq!(out["healFailed"], json!([]), "{out}");
    let healed = out["healed"].as_array().unwrap();
    assert_eq!(healed.len(), 1, "{out}");
    assert_eq!(healed[0]["device"], json!(device_id(&b)));
    assert_eq!(log_json(&a, "r2"), want, "the row is derived again");
    assert_eq!(
        own_digest(&a),
        good,
        "the digest is recomputed in the same command"
    );
    assert_eq!(
        meta(&a, &format!("sync2_digest_at/{P}")),
        Some(now.to_string())
    );

    let again = a.core.sync2_digest_heal(P, now + 1).unwrap();
    assert_eq!(
        again,
        json!({"replayed": [], "healed": [], "healFailed": []}),
        "roots match: nothing to compare"
    );
}

/// 对端永远修不好（它自己不跑 heal、或修不了）：本机对同一组集合总共只重放一次（改 0 行 → 已核实，只报一次）；
/// 之后版本向量前进、本机别的卡有新复习，都不再重放、不再报。
#[test]
fn a_peer_that_never_heals_costs_exactly_one_replay() {
    let (a, b, mut bucket, mut now) = converged();
    let db = device_id(&b);
    stale(&b, "r2");
    b.digest();
    b.sync(&mut bucket, "loc", now);
    a.sync(&mut bucket, "loc", now + 1);
    now += DAY;

    let mut total_replays = 0;
    let mut reports: Vec<Value> = Vec::new();
    for i in 0..4 {
        let (mine, tag) = split(&own_digest(&a));
        let (theirs, their_tag) = split(&peer_digest(&a, &db));
        assert_eq!(
            tag, their_tag,
            "round {i}: compared on the same version vector"
        );
        assert_ne!(mine, theirs, "round {i}: the peer still differs");
        let out = a.core.sync2_digest_heal(P, now).unwrap();
        assert_eq!(out["replayed"], json!([]), "round {i}: {out}");
        total_replays += replays(&out);
        reports.extend(out["healFailed"].as_array().unwrap().iter().cloned());
        // 新的复习（别的卡）：两边都收下，版本向量前进，对端的旧行还在。
        let card = format!("N{i}");
        a.apply(now, vec![review(&format!("n{i}"), &card, now, 3, "learn")]);
        for _ in 0..2 {
            a.sync(&mut bucket, "loc", now + 1);
            b.sync(&mut bucket, "loc", now + 2);
            now += DAY;
        }
        a.sync(&mut bucket, "loc", now);
        now += DAY;
    }
    assert_eq!(total_replays, 1, "one replay in total: {reports:?}");
    assert_eq!(reports.len(), 1, "reported once: {reports:?}");
    assert_eq!(reports[0]["reason"], json!("replayChangedNothing"));
    assert_eq!(reports[0]["device"], json!(db));
    assert!(
        reports[0]["groups"]
            .as_array()
            .is_some_and(|g| !g.is_empty())
    );
    assert_eq!(
        log_json(&b, "r2")["res"]["dueDay"],
        json!(1),
        "the peer is still stale"
    );
}

/// 两边都旧（本机修得好、对端修不好）：本机重放一次修好自己；对端在同一组上仍不一致、本机这些组没再变，下一轮
/// 只报一次 `peerStillDiffers`，不再重放。
#[test]
fn both_sides_stale_replays_once_then_reports_the_peer() {
    let (a, b, mut bucket, mut now) = converged();
    let db = device_id(&b);
    let want = log_json(&a, "r2");
    stale_to(&b, "r2", 2);
    b.digest();
    b.sync(&mut bucket, "loc", now);
    a.sync(&mut bucket, "loc", now + 1);
    now += DAY;
    stale_to(&a, "r2", 1);
    a.digest();
    let out = a.core.sync2_digest_heal(P, now).unwrap();
    assert_eq!(out["replayed"], json!(["C"]), "{out}");
    assert_eq!(out["healed"].as_array().unwrap().len(), 1, "{out}");
    assert_eq!(log_json(&a, "r2"), want);
    assert_ne!(split(&own_digest(&a)).0, split(&peer_digest(&a, &db)).0);
    let out = a.core.sync2_digest_heal(P, now + 1).unwrap();
    assert_eq!(replays(&out), 0, "{out}");
    assert_eq!(
        out["healFailed"][0]["reason"],
        json!("peerStillDiffers"),
        "{out}"
    );
    let out = a.core.sync2_digest_heal(P, now + 2).unwrap();
    assert_eq!(out, json!({"replayed": [], "healed": [], "healFailed": []}));
}

/// 只比派生规则 + 版本向量逐字相同、组指纹版本相同的：前缀不同、`dgv` 不同都不比、不报。条件都满足才修
/// （对照，免得这条测试在 heal 永远什么都不做时也绿）。
#[test]
fn heal_compares_only_on_the_same_prefix_and_group_version() {
    let (a, b, _bucket, now) = converged();
    let db = device_id(&b);
    stale(&a, "r2");
    a.digest();
    let original = peer_digest(&a, &db);
    let (root, tag) = split(&original);
    let none = json!({"replayed": [], "healed": [], "healFailed": []});

    // 对端是旧派生规则（v3.3.0 的前缀 `4:`）。
    let old_rules = format!("{root}@4:{}", tag.split_once(':').unwrap().1);
    set_peer_digest(&a, &db, &old_rules);
    assert_eq!(a.core.sync2_digest_heal(P, now).unwrap(), none);
    // 同规则、版本向量不同。
    set_peer_digest(&a, &db, &format!("{root}@{}0000", digest::VV_PREFIX));
    assert_eq!(a.core.sync2_digest_heal(P, now).unwrap(), none);
    set_peer_digest(&a, &db, &original);

    // 组指纹版本不同。
    let key = format!("sync2_dg_peer/{db}/{P}");
    let dg = meta(&a, &key).unwrap();
    let mut other: Value = serde_json::from_str(&dg).unwrap();
    assert_eq!(
        other["digest"],
        json!(original),
        "paired with the head's digest"
    );
    other["dgv"] = json!(digest::DG_VERSION + 1);
    set_meta(&a, &key, Some(&other.to_string()));
    assert_eq!(a.core.sync2_digest_heal(P, now).unwrap(), none);

    // 组指纹与 `sync2_devices.digest` 不是同一份 head 的：不用。
    let mut unpaired: Value = serde_json::from_str(&dg).unwrap();
    unpaired["digest"] = json!("x@y");
    set_meta(&a, &key, Some(&unpaired.to_string()));
    let out = a.core.sync2_digest_heal(P, now).unwrap();
    assert_eq!(out["replayed"], json!([]), "{out}");
    assert_eq!(out["healFailed"][0]["reason"], json!("noGroups"), "{out}");

    // 对照：都对上了就修。
    set_meta(&a, &key, Some(&dg));
    set_meta(&a, &format!("sync2_heal/{db}/{P}"), None);
    let out = a.core.sync2_digest_heal(P, now).unwrap();
    assert_eq!(out["replayed"], json!(["C"]), "{out}");
}

/// 对端是没有组指纹的旧版本：定位不了，不重放，只报一次 `noGroups`。
#[test]
fn a_peer_without_group_fingerprints_is_reported_once() {
    let (a, b, _bucket, now) = converged();
    let db = device_id(&b);
    stale(&a, "r2");
    a.digest();
    set_meta(&a, &format!("sync2_dg_peer/{db}/{P}"), None);
    let out = a.core.sync2_digest_heal(P, now).unwrap();
    assert_eq!(out["replayed"], json!([]), "{out}");
    assert_eq!(replays(&out), 0);
    let failed = out["healFailed"].as_array().unwrap();
    assert_eq!(failed.len(), 1, "{out}");
    assert_eq!(failed[0]["reason"], json!("noGroups"));
    assert_eq!(failed[0]["device"], json!(db));
    let again = a.core.sync2_digest_heal(P, now + 1).unwrap();
    assert_eq!(again["healFailed"], json!([]), "{again}");
    assert_eq!(again["replayed"], json!([]));
}

/// 投影没收齐（有待重放的卡）：不算摘要也不比。
#[test]
fn heal_waits_while_the_projection_is_unsettled() {
    let (a, _b, _bucket, now) = converged();
    stale(&a, "r2");
    a.digest();
    let w = a.core.writer().unwrap();
    w.execute(
        "INSERT INTO sync2_replay_pending (profile_uid, card_id) VALUES (srs_id(?1), srs_id('S'))",
        [P],
    )
    .unwrap();
    assert!(super::transport::replay_is_pending(&w, P).unwrap());
    drop(w);
    let out = a.core.sync2_digest_heal(P, now).unwrap();
    assert_eq!(out, json!({"replayed": [], "healed": [], "healFailed": []}));
}

/// head 里的 `ext.dg`：组指纹与 head 的摘要串出自同一次计算；它在主签名之外（只去掉 `ext` / `extSig` 的老读者
/// 视图照样验签通过），与 head 的其余字段（含 `minReader`）一字不变。
#[test]
fn head_carries_group_fingerprints_outside_the_main_signature() {
    let (a, _b, bucket, _now) = converged();
    let da = device_id(&a);
    let (gen, bytes) = bucket
        .0
        .iter()
        .filter(|(k, _)| k.split('/').nth(1) == Some(da.as_str()))
        .filter_map(|(k, v)| Some((parse_head_file_name(k.rsplit('/').next()?)?, v.clone())))
        .max_by_key(|x| x.0)
        .unwrap();
    assert!(gen > 0);
    let head = Head::decode(&bytes).unwrap();
    let dg = &head.ext.as_ref().unwrap()["dg"];
    assert_eq!(dg["dgv"], json!(digest::DG_VERSION));
    let g = dg["g"].as_str().unwrap();
    assert_eq!(g.len(), digest::GROUPS * digest::GROUP_HEX);
    let w = a.core.writer().unwrap();
    let (root, groups) = digest::root_and_groups(&w, P).unwrap();
    drop(w);
    assert_eq!(head.digest.split_once('@').unwrap().0, root);
    assert_eq!(g, groups);
    assert_eq!(head.min_reader, crate::sync2::segment::CONTENT_FLOOR);
    // 老读者：不认识 ext / extSig，只验主签名。
    let mut v: Value = serde_json::from_slice(&bytes).unwrap();
    let obj = v.as_object_mut().unwrap();
    obj.remove("ext");
    obj.remove("extSig");
    let old = Head::decode(&serde_json::to_vec(&v).unwrap()).unwrap();
    assert_eq!(old.ext, None);
    assert_eq!(
        Head {
            ext: head.ext.clone(),
            ..old
        },
        head
    );
}

fn heal_record(d: &Device, peer: &str) -> Option<Value> {
    meta(d, &format!("sync2_heal/{peer}/{P}")).map(|s| serde_json::from_str(&s).unwrap())
}

/// 不一致 → 核实（重放 0 行、报一次）→ 两边恢复一致（去重记录作废）→ 本机同一组集合又出现旧行：这次照样重放修好，
/// 不因为早先核实过而静默。
#[test]
fn a_verified_group_set_is_forgotten_once_the_peer_agrees_again() {
    let (a, b, mut bucket, mut now) = converged();
    let db = device_id(&b);
    let want = log_json(&b, "r2");
    stale(&b, "r2");
    b.digest();
    b.sync(&mut bucket, "loc", now);
    a.sync(&mut bucket, "loc", now + 1);
    now += DAY;
    let out = a.core.sync2_digest_heal(P, now).unwrap();
    assert_eq!(replays(&out), 1, "{out}");
    assert_eq!(
        out["healFailed"][0]["reason"],
        json!("replayChangedNothing")
    );
    assert_eq!(heal_record(&a, &db).unwrap()["verified"], json!(true));

    // 对端修好了（比如升级后跑了迁移）：同一进度下两边的根相同。
    let w = b.core.writer().unwrap();
    w.execute(
        "UPDATE srs_review_logs SET jslim = srs_log_pack(?2, id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, duration_ms) WHERE id = srs_id(?1)",
        rusqlite::params!["r2", want.to_string()],
    )
    .unwrap();
    drop(w);
    b.digest();
    b.sync(&mut bucket, "loc", now);
    a.sync(&mut bucket, "loc", now + 1);
    now += DAY;
    assert_eq!(peer_digest(&a, &db), own_digest(&a), "agreed again");
    let out = a.core.sync2_digest_heal(P, now).unwrap();
    assert_eq!(out, json!({"replayed": [], "healed": [], "healFailed": []}));
    assert_eq!(heal_record(&a, &db), None, "the verified record is dropped");

    // 本机同一组集合里又出现旧行：重放并修好。
    stale(&a, "r2");
    a.digest();
    let out = a.core.sync2_digest_heal(P, now + 1).unwrap();
    assert_eq!(out["replayed"], json!(["C"]), "{out}");
    assert_eq!(out["healFailed"], json!([]), "{out}");
    assert_eq!(log_json(&a, "r2"), want);
    assert_eq!(own_digest(&a), peer_digest(&a, &db));
}

/// 摘要串 `@` 之后不同（版本向量 / 规则 / 扣留集合不同）不算「一致」：即便根碰巧相同也不删去重记录。
#[test]
fn a_different_tag_never_counts_as_agreement() {
    let (a, b, mut bucket, mut now) = converged();
    let db = device_id(&b);
    stale(&b, "r2");
    b.digest();
    b.sync(&mut bucket, "loc", now);
    a.sync(&mut bucket, "loc", now + 1);
    now += DAY;
    a.core.sync2_digest_heal(P, now).unwrap();
    let rec = heal_record(&a, &db).unwrap();
    let (root, tag) = split(&own_digest(&a));
    let other_vv = format!("{root}@{}{}", digest::VV_PREFIX, "0".repeat(tag.len() - 2));
    assert_ne!(split(&other_vv).1, tag);
    set_peer_digest(&a, &db, &other_vv);
    assert_eq!(
        a.core.sync2_digest_heal(P, now + 1).unwrap(),
        json!({"replayed": [], "healed": [], "healFailed": []})
    );
    assert_eq!(heal_record(&a, &db), Some(rec), "kept");
}

/// 停用一台设备：它的组指纹与去重记录删掉，之后不再与它比。
#[test]
fn retiring_a_device_forgets_its_heal_state() {
    let (a, b, mut bucket, mut now) = converged();
    let db = device_id(&b);
    stale(&b, "r2");
    b.digest();
    b.sync(&mut bucket, "loc", now);
    a.sync(&mut bucket, "loc", now + 1);
    now += DAY;
    a.core.sync2_digest_heal(P, now).unwrap();
    assert!(heal_record(&a, &db).is_some());
    assert!(meta(&a, &format!("sync2_dg_peer/{db}/{P}")).is_some());
    a.core.sync2_retire(P, &db, true, now).unwrap();
    assert_eq!(heal_record(&a, &db), None);
    assert_eq!(meta(&a, &format!("sync2_dg_peer/{db}/{P}")), None);
    stale(&a, "r2");
    a.digest();
    assert_eq!(
        a.core.sync2_digest_heal(P, now + 1).unwrap(),
        json!({"replayed": [], "healed": [], "healFailed": []}),
        "a retired device is not compared"
    );
}
