//! 首见设备的信任判定（`truth/trust.rs`，BUG-4306）的端到端测试：经 C ABI，位置是内存表（装置在 `sync_tests.rs`）。
//!
//! - 库非空的设备第一次见到别的设备：待确认；它的删除与彻底清除照收进日志但扣住（不生效、内容还在），用户确认之后
//!   整批放行（删除生效、清除落成空洞），增量 == 重建，两边收敛。
//! - 全新库（只有内置种子）第一轮同时见到两台设备：都可信，删除直接生效。
//! - 只经转发见到的设备同样判。
//! - 换身份（`rotate`）：新 head 带 `prev`、同一把钥匙 → 新身份原样继承旧身份的信任状态（可信 / 已拒绝）与 `since`。
//! - 真相层单测：[Truth::library_fresh] 只认内置种子 / 还原点为空库；[Truth::note_new_peer] 的继承核公钥（不同钥匙
//!   不继承）、名字随身份走、本机已有日志的设备不追溯。
//! - 旧根：库非空时协议 3 head 带来的新作者待确认，它的删除被扣；全新库捡旧根照样首次信任。

use serde_json::{Value, json};

use super::dispatch_tests::T1;
use super::sync_complete_tests::{OLD, old_root_with, take_old_root};
use super::sync_tests::{Dev, Loc, Opts, cmd, heads, round, status_row, sync_all};
use super::tests::{N1, N2, N3};
use crate::gen4::head::PrevIdentity;
use crate::gen4::op::tests::id;
use crate::store::gen4::derive::Index;
use crate::store::gen4::truth::{FirstSeen, Peer, PeerPut, TRUST_PENDING, TRUST_REJECTED};
use crate::store::sync2::tests::{deck_entity, edit};
use crate::sync2::hlc::Hlc;
use crate::sync2::id::{Id, Key};
use crate::sync2::keys::DeviceKey;
use crate::sync2::op::{Body, EditBody, EntKind, KIND_EDIT, Op};
use crate::sync2::segment::CHAIN_ZERO;
use crate::sync2::vv::OpId;

const DEFAULT_DECK: &str = "0193a1b2-0000-7000-8000-0000000000d0";

/// 落一批 `apply` 项（[items] 每项是 `{"e": 事件, ...}`），断言都落下了。
fn apply(d: &Dev, now: i64, items: Vec<Value>) {
    let n = items.len();
    let blob = Value::Array(items).to_string().into_bytes();
    let (v, _) = cmd(d.h, "apply", now, json!({}), &[blob]);
    assert_eq!(v["landed"], json!(vec![true; n]), "{v}");
}

/// [d] 删除笔记 [note]（`deleted` 写成时刻）。
fn delete(d: &Dev, now: i64, note: &str) {
    apply(
        d,
        now,
        vec![json!({"e": edit("note", note, "deleted", json!(now)), "note": note})],
    );
}

/// [d] 彻底清除笔记 [note]。
fn purge(d: &Dev, now: i64, note: &str) {
    cmd(
        d.h,
        "purge",
        now,
        json!({"kind": "note", "entities": [note]}),
        &[],
    );
}

fn trust(d: &Dev, now: i64, device: &str, on: bool) -> Value {
    cmd(
        d.h,
        "trust",
        now,
        json!({"device": device, "trust": on}),
        &[],
    )
    .0
}

/// 笔记 [note] 有没有生效的删除（派生层 `deleted` 寄存器的赢家）。
fn deleted(d: &mut Dev, note: &str) -> bool {
    let key = Key::of(note);
    d.direct(|t, col| Index::new(t, col).value(EntKind::Note, &key, "deleted"))
        .is_some_and(|v| v != "null")
}

/// 本机操作日志里还带着 [text] 的操作条数（按字节子串找）。
fn ops_carrying(d: &mut Dev, text: &str) -> i64 {
    d.direct(|t, _| {
        t.conn()
            .query_row(
                "SELECT COUNT(*) FROM ops WHERE instr(body, CAST(?1 AS BLOB)) > 0",
                [text],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())
    })
}

/// 被扣住的删除 / 清除条数。
fn distrusted(d: &mut Dev) -> usize {
    d.direct(|t, col| Index::new(t, col).distrusted().map(|v| v.len()))
}

/// 库非空的 b 第一次见到 a：待确认。a 删掉 b 的一条笔记、清除另一条，b 收进日志但都扣住；b 确认 a 之后整批放行：
/// 删除生效、清除把 b 自己写的内容落成空洞。之后两边收敛、增量 == 重建。
#[test]
fn a_device_first_seen_by_a_nonempty_library_waits_for_confirmation() {
    let mut a = Dev::new("c2pa");
    let mut b = Dev::new("c2pb");
    b.write(T1, N2, "保留");
    b.write(T1 + 1, N3, "secret-c2");
    let mut loc = Loc::new();
    sync_all(&[&b, &a], &mut loc, T1 + 2, Opts::default());
    let (da, db) = (a.device(), b.device());
    // a 第一次同步时只有空库：b 可信；b 见到 a 时库已非空：a 待确认。
    assert!(status_row(&a, &db).get("trust").is_none());
    let row = status_row(&b, &da);
    assert_eq!(row["trust"], json!("pending"), "{row}");
    assert!(row["trustSince"].as_i64().is_some_and(|s| s > 0), "{row}");
    assert_eq!(a.field(N3), Some(json!("secret-c2")));

    delete(&a, T1 + 3, N2);
    purge(&a, T1 + 4, N3);
    sync_all(&[&a, &b], &mut loc, T1 + 5, Opts::default());
    // a 自己：删除与清除生效。
    assert!(deleted(&mut a, N2));
    assert_eq!(ops_carrying(&mut a, "secret-c2"), 0);
    // b：扣住，内容还在。
    let row = status_row(&b, &da);
    assert_eq!(row["heldDeletes"], json!(2), "{row}");
    assert_eq!(row["heldPurges"], json!(1), "{row}");
    assert!(!deleted(&mut b, N2), "an untrusted device's delete waits");
    assert!(
        ops_carrying(&mut b, "secret-c2") > 0,
        "an untrusted device's purge waits"
    );
    assert_eq!(distrusted(&mut b), 3);
    b.derived();

    let v = trust(&b, T1 + 6, &da, true);
    assert_eq!(v["released"], json!(3), "{v}");
    assert!(status_row(&b, &da).get("trust").is_none());
    assert!(deleted(&mut b, N2));
    assert_eq!(
        ops_carrying(&mut b, "secret-c2"),
        0,
        "the released purge voids b's own op"
    );
    assert_eq!(distrusted(&mut b), 0);
    sync_all(&[&a, &b], &mut loc, T1 + 7, Opts::default());
    assert_eq!(a.derived(), b.derived());
}

/// 全新库（只有内置种子）第一轮同时见到两台设备：都可信，它们的删除直接生效；之后再见到的新设备待确认。
#[test]
fn a_fresh_library_trusts_every_device_of_its_first_round() {
    let a = Dev::new("c2fa");
    let b = Dev::new("c2fb");
    let mut c = Dev::new("c2fc");
    let d = Dev::new("c2fd");
    a.write(T1, N1, "鯨");
    b.write(T1 + 1, N2, "猫");
    delete(&b, T1 + 2, N2);
    apply(&c, T1 + 3, vec![json!({"e": deck_entity(DEFAULT_DECK)})]);
    let mut loc = Loc::new();
    round(&a, &mut loc, "loc", T1 + 4, Opts::default());
    round(&b, &mut loc, "loc", T1 + 4, Opts::default());
    round(&c, &mut loc, "loc", T1 + 5, Opts::default());
    for dev in [a.device(), b.device()] {
        assert!(status_row(&c, &dev).get("trust").is_none(), "{dev}");
    }
    assert!(deleted(&mut c, N2));
    assert_eq!(distrusted(&mut c), 0);
    // c 收下之后库非空：之后第一次见到的 d 待确认。
    round(&d, &mut loc, "loc", T1 + 6, Opts::default());
    round(&c, &mut loc, "loc", T1 + 7, Opts::default());
    assert_eq!(status_row(&c, &d.device())["trust"], json!("pending"));
}

/// 只经转发见到的设备（`plan` 末尾 `relayed` 份）同样判：库非空 = 待确认。
#[test]
fn a_device_seen_only_through_a_relayed_head_is_judged_too() {
    let a = Dev::new("c2ra");
    let mut b = Dev::new("c2rb");
    a.write(T1, N1, "鯨");
    b.write(T1, N2, "猫");
    let mut loc = Loc::new();
    round(&a, &mut loc, "loc", T1 + 1, Opts::default());
    let hs = heads(&loc);
    assert_eq!(hs.len(), 1);
    let (plan, _) = cmd(
        b.h,
        "plan",
        T1 + 2,
        json!({"location": "elsewhere", "relayed": 1}),
        &hs,
    );
    assert_eq!(plan["errors"], json!([]), "{plan}");
    let da = Id::parse(&a.device()).unwrap();
    assert_eq!(b.direct(|t, col| t.trust_of(col, &da)), Some(TRUST_PENDING));
}

/// 换身份：b 信任 a、拒绝 c；a、c 各自 `rotate` 之后以新身份写删除。新 head 带 `prev`、同一把钥匙：b 上 a 的新身份
/// 可信（删除生效、不进待确认），c 的新身份照旧是已拒绝（`since` 原样），删除扣住。
#[test]
fn a_rotated_identity_inherits_the_trust_of_its_previous_one() {
    let a = Dev::new("c2ia");
    let mut b = Dev::new("c2ib");
    let mut c = Dev::new("c2ic");
    b.write(T1, N1, "鯨");
    b.write(T1, N2, "猫");
    a.write(T1, N3, "犬");
    c.write(T1, N3, "犬");
    let mut loc = Loc::new();
    sync_all(&[&a, &c, &b], &mut loc, T1 + 1, Opts::default());
    let (old_a, old_c) = (a.device(), c.device());
    assert_eq!(status_row(&b, &old_a)["trust"], json!("pending"));
    trust(&b, T1 + 2, &old_a, true);
    trust(&b, T1 + 2, &old_c, false);
    let since = status_row(&b, &old_c)["trustSince"].clone();
    assert_eq!(status_row(&b, &old_c)["trust"], json!("rejected"));

    for d in [&a, &c] {
        let (v, _) = cmd(d.h, "rotate", T1 + 3, json!({}), &[]);
        assert_ne!(v["device"], v["previous"], "{v}");
    }
    let (new_a, new_c) = (a.device(), c.device());
    delete(&a, T1 + 4, N1);
    delete(&c, T1 + 4, N2);
    sync_all(&[&a, &c, &b], &mut loc, T1 + 5, Opts::default());
    assert!(
        status_row(&b, &new_a).get("trust").is_none(),
        "trusted carries over"
    );
    assert!(deleted(&mut b, N1));
    let row = status_row(&b, &new_c);
    assert_eq!(row["trust"], json!("rejected"), "{row}");
    assert_eq!(row["trustSince"], since, "{row}");
    assert!(!deleted(&mut b, N2));
    assert_eq!(distrusted(&mut b), 1);
    b.derived();
    c.derived();
}

/// 真相层：[Truth::library_fresh] 的判据。新库、只有内置种子、还原点 = 空库；任何一条用户写入就不是。
#[test]
fn library_fresh_counts_only_builtin_seeds_and_checkpoints_as_empty() {
    let mut d = Dev::new("c2lf");
    let fresh = |d: &mut Dev| d.direct(|t, col| t.library_fresh(col));
    assert!(fresh(&mut d));
    apply(&d, T1, vec![json!({"e": deck_entity(DEFAULT_DECK)})]);
    let (v, _) = cmd(
        d.h,
        "checkpoint",
        T1 + 1,
        json!({"name": "c", "reason": "manual"}),
        &[],
    );
    assert!(v.get("error").is_none(), "{v}");
    assert!(
        fresh(&mut d),
        "builtin seeds and checkpoints are not user data"
    );
    let mut user = d.copy("c2lf2");
    // 非内置的身份记录。
    apply(
        &user,
        T1 + 2,
        vec![
            json!({"e": {"t": "entity", "x": {"id": N1, "p": crate::store::sync2::tests::P, "k": "deck", "d": {"createdAt": 1}}}}),
        ],
    );
    assert!(!fresh(&mut user));
    // 修改。
    d.write(T1 + 3, N1, "鯨");
    assert!(!fresh(&mut d));
}

fn key_of(b: u8) -> DeviceKey {
    DeviceKey::from_seed(&[b; 32])
}

fn peer(d: u8, name: Option<&str>) -> Peer {
    Peer {
        device: id(d),
        public: key_of(d).public(),
        name: name.map(str::to_owned),
        ext: None,
        head_gen: None,
        first_seen: None,
    }
}

/// 真相层：[Truth::note_new_peer]。库非空。
/// - 旧身份待确认 / 已拒绝 / 可信，新身份带 `prev`、同一把钥匙：原样继承（`since` 不变），名字随身份走；
/// - 公钥不同（冒充别人的旧身份）：不继承，按首见判待确认；
/// - 本机已有它的日志：不追溯。
#[test]
fn note_new_peer_inherits_only_under_the_same_key() {
    let mut d = Dev::new("c2np");
    d.write(T1, N1, "鯨");
    d.direct(|t, col| {
        let prev = |dev: u8| PrevIdentity {
            device: id(dev),
            seq: 1,
            chain: CHAIN_ZERO,
        };
        // 0xa1 待确认、0xa2 已拒绝、0xa3 可信。新身份用旧身份的钥匙（Peer 的公钥按旧身份的种子算）。
        for (old, state) in [
            (0xa1, Some(TRUST_PENDING)),
            (0xa2, Some(TRUST_REJECTED)),
            (0xa3, None),
        ] {
            assert_eq!(
                t.set_peer(col, &peer(old, Some("old phone")))?,
                PeerPut::Inserted
            );
            if let Some(s) = state {
                t.set_trust(col, &id(old), Some(s), 77)?;
            }
            let new = id(old ^ 0x40);
            let mut p = peer(old, None);
            p.device = new;
            assert_eq!(t.set_peer(col, &p)?, PeerPut::Inserted);
            let got = t.note_new_peer(col, &new, &p.public, Some(&prev(old)), T1 + 9)?;
            assert_eq!(
                got,
                FirstSeen::Inherited {
                    from: id(old),
                    state
                }
            );
            assert_eq!(t.trust_entry(col, &new)?, state.map(|s| (s, 77)));
            assert_eq!(
                t.peer(col, &new)?.unwrap().name.as_deref(),
                Some("old phone")
            );
        }
        // 公钥不同：prev 指向可信的 0xa3，签名的却是另一把钥匙。
        let impostor = peer(0xb1, None);
        t.set_peer(col, &impostor)?;
        let got = t.note_new_peer(col, &id(0xb1), &impostor.public, Some(&prev(0xa3)), T1 + 9)?;
        assert_eq!(got, FirstSeen::Pending);
        assert_eq!(
            t.trust_entry(col, &id(0xb1))?,
            Some((TRUST_PENDING, T1 + 9))
        );
        assert_eq!(t.peer(col, &id(0xb1))?.unwrap().name, None);
        Ok(())
    });
}

/// 旧根：库非空的 a 捡旧根，协议 3 head 带来的新作者 OLD 待确认，它的删除扣住（笔记照样在）；确认之后放行。全新
/// 库的 b 捡同一个旧根：OLD 首次信任。
#[test]
fn an_old_root_author_first_seen_by_a_nonempty_library_waits() {
    let mut a = Dev::new("c2oa");
    let b = Dev::new("c2ob");
    a.write(T1, N1, "鯨");
    let mut ops = crate::sync2::segment::tests::ops_for(id(OLD), 3);
    let body = Body::Edit(EditBody {
        kind: EntKind::Note,
        entity: Key::Uuid(Id::parse(N1).unwrap()),
        key: "deleted".to_owned(),
        value: "1700000000000".to_owned(),
        machine: false,
        ts: 1,
        legacy: None,
    });
    ops.push(Op {
        id: OpId {
            device: id(OLD),
            seq: 4,
        },
        hlc: Hlc {
            wall: 1_004,
            logical: 0,
            device: id(OLD),
        },
        kind: KIND_EDIT,
        payload: body.encode().into(),
        ..ops[2].clone()
    });
    let mut loc = Loc::new();
    old_root_with(&mut loc, &ops, &[(1, 4)]);
    let old = id(OLD).text();
    // 全新的 b 先捡（它还谁都不认识）；a 再来，这时它见到 b 的 head、库也非空。
    for d in [&b, &a] {
        round(d, &mut loc, "loc", T1 + 1, Opts::default());
        let (_, ing) = take_old_root(d, &loc, T1 + 2);
        let ing = ing.expect("scans the old root");
        assert_eq!(ing["errors"], json!([]), "{ing}");
        assert_eq!(ing["landed"], json!(4), "{ing}");
    }
    assert_eq!(status_row(&a, &old)["trust"], json!("pending"));
    assert_eq!(status_row(&a, &old)["heldDeletes"], json!(1));
    assert!(!deleted(&mut a, N1));
    assert!(status_row(&b, &old).get("trust").is_none());
    a.derived();
    assert_eq!(distrusted(&mut a), 1);
    // 确认之后不再按「不受信」扣（这条旧删除与 a 的写入并发，之后按冲突扣住处理，与信任无关）。
    let v = trust(&a, T1 + 3, &old, true);
    assert_eq!(v["released"], json!(1), "{v}");
    assert_eq!(distrusted(&mut a), 0);
    assert!(status_row(&a, &old).get("trust").is_none());
    a.derived();
}

// ---------------------------------------------------------------------- 换代迁移端到端

/// 一份协议 3 小库（`dryrun::tests::library`），关掉内核只留目录。回 (目录, 旧设备, 签名钥匙种子)。
pub(super) fn legacy_library(
    tag: &str,
) -> (crate::store::sync2::tests::tempdir::Dir, Id, [u8; 32]) {
    let crate::store::sync2::tests::Device { core, _dir } =
        crate::store::gen4::dryrun::tests::library(tag);
    core.close();
    drop(core);
    let c = legacy_conn(&_dir.0);
    let (dev, seed): (Vec<u8>, Vec<u8>) = c
        .query_row(
            "SELECT device, key_seed FROM sync2_self WHERE profile_uid = srs_id(?1)",
            [crate::store::sync2::tests::P],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    (_dir, Id(dev.try_into().unwrap()), seed.try_into().unwrap())
}

fn legacy_conn(dir: &std::path::Path) -> rusqlite::Connection {
    let c = rusqlite::Connection::open(dir.join(crate::store::gen4::files::LEGACY_FILE)).unwrap();
    crate::store::ids::register(&c).unwrap();
    c
}

/// 跑一次真迁移（新身份 [new]），断言提交。
pub(super) fn migrate_to(dir: &std::path::Path, new: Id) {
    use crate::store::gen4::dryrun::Stop;
    use crate::store::gen4::migrate::{Options, Outcome, run};
    let caches = std::collections::BTreeMap::from([(
        crate::store::sync2::tests::P.to_owned(),
        crate::store::gen4::dryrun::tests::cfg(),
    )]);
    let pick = move |_: &str, _: i64| new;
    let out = run(
        dir,
        Options {
            caches: &caches,
            batch: 64,
            now_ms: T1,
            stop: &Stop::new(),
            progress: &mut |_, _, _| {},
            new_device: &pick,
        },
    )
    .unwrap();
    assert!(matches!(out, Outcome::Committed { .. }), "{out:?}");
}

/// 换代迁移端到端：协议 3 时代 b 认识 a（`sync2_devices` 记着 a 的公钥）、a 在 b 上是 [state]（None = 可信）。两台各自
/// 迁移、各自换了新身份（沿用签名钥匙、`prev` 指向旧设备），再经新代位置同步：b 上 a 的新身份原样继承旧身份的信任
/// 状态、`since` 与名字，不出现整批待确认。
fn migrated_peer_keeps_its_trust(tag: &str, state: Option<i64>) {
    let (da, old_a, seed_a) = legacy_library(&format!("{tag}a"));
    let (db, _, _) = legacy_library(&format!("{tag}b"));
    {
        let c = legacy_conn(&db.0);
        c.execute(
            "INSERT INTO sync2_devices (profile_uid, device, public, applied, name) VALUES (srs_id(?1), ?2, ?3, 0, 'phone a')",
            rusqlite::params![
                crate::store::sync2::tests::P,
                &old_a.0[..],
                &DeviceKey::from_seed(&seed_a).public()[..]
            ],
        )
        .unwrap();
        if let Some(s) = state {
            c.execute(
                "INSERT INTO sync2_trust (profile_uid, device, state, since) VALUES (srs_id(?1), ?2, ?3, 4242)",
                rusqlite::params![crate::store::sync2::tests::P, &old_a.0[..], s],
            )
            .unwrap();
        }
    }
    let new_a = Id([0x6a; 16]);
    migrate_to(&da.0, new_a);
    migrate_to(&db.0, Id([0x6b; 16]));
    let open = |dir: crate::store::sync2::tests::tempdir::Dir| {
        let h = super::dispatch_tests::open(&dir.0, 0).unwrap();
        Dev { dir, h }
    };
    let a = open(da);
    let mut b = open(db);
    assert_eq!(a.device(), new_a.text());
    // 迁移搬过来的：旧身份的公钥与信任行。
    assert_eq!(
        b.direct(|t, col| Ok((t.device_key(col, &old_a)?, t.trust_entry(col, &old_a)?))),
        (
            Some(DeviceKey::from_seed(&seed_a).public()),
            state.map(|s| (s, 4242))
        )
    );
    let mut loc = Loc::new();
    sync_all(&[&a, &b], &mut loc, T1 + 10, Opts::default());
    let (key, entry, name) = b.direct(|t, col| {
        Ok((
            t.device_key(col, &new_a)?,
            t.trust_entry(col, &new_a)?,
            t.peer(col, &new_a)?.and_then(|p| p.name),
        ))
    });
    assert_eq!(
        key,
        Some(DeviceKey::from_seed(&seed_a).public()),
        "same key after migration"
    );
    assert_eq!(entry, state.map(|s| (s, 4242)), "the new identity inherits");
    assert_eq!(name.as_deref(), Some("phone a"));
    b.derived();
}

#[test]
fn a_migrated_trusted_peer_stays_trusted() {
    migrated_peer_keeps_its_trust("c2mt", None);
}

#[test]
fn a_migrated_pending_peer_stays_pending() {
    migrated_peer_keeps_its_trust("c2mp", Some(TRUST_PENDING));
}
