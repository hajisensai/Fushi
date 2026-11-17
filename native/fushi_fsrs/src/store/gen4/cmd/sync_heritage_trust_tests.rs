//! 承袭段与首次信任（G10-4 第三轮复核）：上传者只担保自己信任的作者（`inherit.rs` 文件头「只替本机信任的作者上传」），
//! 收方经受信上传者拿到日志的作者在旧根上再见到时不追溯（`truth/trust.rs` 第 1 条）。一律经 C ABI，装置沿用
//! `sync_tests.rs` / `sync_complete_tests.rs`。另有两条真相层的身份承接边界（第三轮复核 minor 3）：本机迁移前的
//! 协议 3 旧身份在旧根上再见到不判待确认；与在册设备同钥匙、却不带（或带错）`prev` 的新身份不承接、更不偏向可信。

use serde_json::{Value, json};

use super::dispatch_tests::T1;
use super::sync_complete_tests::{OLD, d_old_len, old_root_with, take_old_root, upload_heritage};
use super::sync_tests::{Dev, Loc, Opts, cmd, round, status_row};
use super::sync_trust_tests::{legacy_library, migrate_to};
use super::tests::{N1, N2};
use crate::gen4::head::PrevIdentity;
use crate::gen4::op::tests::id;
use crate::store::gen4::truth::{FirstSeen, Peer, PeerPut, TRUST_PENDING, TRUST_REJECTED};
use crate::sync2::id::{Id, Key};
use crate::sync2::keys::DeviceKey;
use crate::sync2::op::{Body, EntKind, KIND_PURGE, Op};
use crate::sync2::segment::CHAIN_ZERO;

/// OLD 的 [n] 条操作，最后一条改成彻底清除（随便一个笔记键；扣不扣看 `status` 的 `heldPurges`）。
fn ops_ending_in_a_purge(n: u64) -> Vec<Op> {
    let mut ops = crate::sync2::segment::tests::ops_for(id(OLD), n);
    let last = ops.last_mut().unwrap();
    last.kind = KIND_PURGE;
    last.payload = Body::Purge {
        kind: EntKind::Note,
        entity: Key::of("n"),
    }
    .encode()
    .into();
    ops
}

fn trust(d: &Dev, now: i64, device: &str) -> Value {
    let (v, _) = cmd(
        d.h,
        "trust",
        now,
        json!({"device": device, "trust": true}),
        &[],
    );
    assert_eq!(v["trusted"], json!(true), "{v}");
    v
}

/// 位置上承袭段（`v4/devices/*/hrt-*`）的个数。
fn heritage_files(loc: &Loc) -> usize {
    loc.keys()
        .filter(|k| k.starts_with("v4/devices/") && k.contains("/hrt-"))
        .count()
}

/// 拒绝路径（复核 major）：库里有数据的 a 捡旧根时第一次见到陌生的 OLD（它带一条彻底清除），记成待确认、清除扣住。
/// a 照常承袭上传，但**不替 OLD 上传**：位置上没有 OLD 的承袭段。另一台库里有数据、信任 a 的 c 收新根拿不到 OLD 的
/// 任何操作，捡旧根时自己读到 OLD 的 head、自己判待确认，那条清除在 c 上同样扣住。a 确认 OLD 之后的下一轮才补传。
#[test]
fn a_purge_held_on_the_uploader_stays_held_on_other_devices() {
    let mut loc = Loc::new();
    old_root_with(&mut loc, &ops_ending_in_a_purge(4), &[(1, 4)]);
    let old = id(OLD).text();

    let a = Dev::new("g104hpa");
    a.write(T1 + 1, N1, "鯨");
    round(&a, &mut loc, "loc", T1 + 10, Opts::default());
    let (_, ing) = take_old_root(&a, &loc, T1 + 10);
    assert_eq!(ing.expect("a scans")["errors"], json!([]));
    let row = status_row(&a, &old);
    assert_eq!(row["trust"], json!("pending"), "{row}");
    assert_eq!(row["heldPurges"], json!(1), "{row}");
    assert_eq!(d_old_len(&a), 4, "a holds OLD's log");
    assert_eq!(
        upload_heritage(&a, &mut loc, T1 + 10),
        0,
        "a does not vouch for a device it has not confirmed"
    );
    assert_eq!(heritage_files(&loc), 0);
    round(&a, &mut loc, "loc", T1 + 11, Opts::default());

    let c = Dev::new("g104hpc");
    c.write(T1 + 2, N2, "猫");
    round(&c, &mut loc, "loc", T1 + 20, Opts::default());
    trust(&c, T1 + 20, &a.device());
    round(&c, &mut loc, "loc", T1 + 21, Opts::default());
    assert_eq!(c.field(N1), Some(json!("鯨")), "c has a's own writes");
    assert_eq!(d_old_len(&c), 0, "nothing of OLD reaches c through a");

    let (scan, ing) = take_old_root(&c, &loc, T1 + 22);
    assert_eq!(scan["skipped"], json!(0), "{scan}");
    let ing = ing.expect("c scans the old root itself");
    assert_eq!(ing["errors"], json!([]), "{ing}");
    assert_eq!(d_old_len(&c), 4);
    let row = status_row(&c, &old);
    assert_eq!(row["trust"], json!("pending"), "{row}");
    assert_eq!(
        row["heldPurges"],
        json!(1),
        "the purge is held on c as well: {row}"
    );

    // a 确认 OLD：信任变了、承袭指纹跟着变，下一轮补传。
    trust(&a, T1 + 30, &old);
    assert!(upload_heritage(&a, &mut loc, T1 + 30) > 0);
    assert!(heritage_files(&loc) > 0);
}

/// 混合版本家庭（复核 minor）：用户自己还没升级的 OLD 在 a 上可信（a 捡旧根时库还是空的），a 替它承袭上传。库里有
/// 数据的 c 信任 a、经承袭段收下 OLD 的日志；OLD 之后又在旧根上写了新段（含一条清除），c 捡旧根时第一次见到它的
/// head——本机已有它的日志（受信的 a 担保过），按可信接上，不记待确认、清除不扣，与 a 上的结果一致（协议 3 口径）。
#[test]
fn an_old_device_vouched_for_through_heritage_is_not_pending_later() {
    let mut loc = Loc::new();
    let more = ops_ending_in_a_purge(6);
    old_root_with(&mut loc, &more[..3], &[(1, 3)]);
    let old = id(OLD).text();

    let a = Dev::new("g104hva");
    round(&a, &mut loc, "loc", T1 + 10, Opts::default());
    let (_, ing) = take_old_root(&a, &loc, T1 + 10);
    assert_eq!(ing.expect("a scans")["errors"], json!([]));
    assert!(
        status_row(&a, &old).get("trust").is_none(),
        "an empty library trusts OLD"
    );
    assert!(upload_heritage(&a, &mut loc, T1 + 10) > 0);
    a.write(T1 + 11, N1, "鯨");
    round(&a, &mut loc, "loc", T1 + 11, Opts::default());

    let c = Dev::new("g104hvc");
    c.write(T1 + 2, N2, "猫");
    round(&c, &mut loc, "loc", T1 + 20, Opts::default());
    trust(&c, T1 + 20, &a.device());
    round(&c, &mut loc, "loc", T1 + 21, Opts::default());
    assert_eq!(d_old_len(&c), 3, "OLD's log arrives through a's heritage");

    // OLD（还在协议 3）接着写：前 3 条与之前相同，4..=6 是新段，最后一条是清除。
    old_root_with(&mut loc, &more, &[(1, 3), (4, 6)]);
    let (scan, ing) = take_old_root(&c, &loc, T1 + 22);
    assert_eq!(scan["heads"].as_array().map(Vec::len), Some(1), "{scan}");
    let ing = ing.expect("c scans the old root");
    assert_eq!(ing["errors"], json!([]), "{ing}");
    assert_eq!(d_old_len(&c), 6);
    let row = status_row(&c, &old);
    assert!(row.get("trust").is_none(), "{row}");
    assert!(row.get("heldPurges").is_none(), "{row}");
}

/// 本机迁移前的协议 3 旧身份（复核 minor 3 第二条）：迁移换了新设备 ID、沿用签名钥匙，旧身份由迁移记进 `peers`
/// （公钥同一把）。之后捡旧根时再读到旧身份的 v3 head，`oldroot_ingest` 的登记不是「第一次见到」，不走首次信任，
/// 不会把自己记成待确认——库里显然有数据，走首次信任就一定是待确认。
#[test]
fn the_own_protocol3_identity_seen_on_the_old_root_is_not_pending() {
    let (dir, old_self, seed) = legacy_library("g104own");
    migrate_to(&dir.0, Id([0x5a; 16]));
    let h = super::dispatch_tests::open(&dir.0, 0).unwrap();
    let mut d = Dev { dir, h };
    assert_ne!(
        d.device(),
        old_self.text(),
        "migration gives a new identity"
    );
    let public = DeviceKey::from_seed(&seed).public();
    let (put, seen, entry) = d.direct(|t, col| {
        // 与 `oldroot_ingest` 登记 v3 head 相同的两步。
        let put = t.set_peer(
            col,
            &Peer {
                device: old_self,
                public,
                name: Some("old self".into()),
                ext: None,
                head_gen: None,
                first_seen: Some(T1),
            },
        )?;
        let seen = if put == PeerPut::Inserted {
            Some(t.note_new_peer(col, &old_self, &public, None, T1)?)
        } else {
            None
        };
        Ok((put, seen, t.trust_entry(col, &old_self)?))
    });
    assert_ne!(
        put,
        PeerPut::Inserted,
        "migration already knows the old self"
    );
    assert_eq!(seen, None);
    assert_eq!(entry, None, "the old self stays trusted");
}

/// 同钥匙但不带 `prev`（或 `prev` 指向别的钥匙的设备）的新身份（复核 minor 3 第一条）：只按 `prev` + 同钥匙承接
/// （`truth/trust.rs` 第 2 条），这里两样都不满足，当新设备判——库非空就待确认。重点是**不偏向可信**：前身已拒绝 / 待确认
/// 时换个 ID 不能洗成可信；前身可信时也不凭钥匙自动承接（`prev` 指向的受信设备钥匙不同 = 冒充）。
#[test]
fn a_same_key_identity_without_a_matching_prev_is_judged_as_new() {
    let mut d = Dev::new("g104sk");
    d.write(T1, N1, "鯨");
    d.direct(|t, col| {
        let peer = |dev: u8, seed: u8| Peer {
            device: id(dev),
            public: DeviceKey::from_seed(&[seed; 32]).public(),
            name: None,
            ext: None,
            head_gen: None,
            first_seen: None,
        };
        // 同一把钥匙 0x31 下在册两台：0xa1 已拒绝、0xa2 待确认；另一把钥匙 0x32 下 0xa3 可信。
        t.set_peer(col, &peer(0xa1, 0x31))?;
        t.set_trust(col, &id(0xa1), Some(TRUST_REJECTED), 5)?;
        t.set_peer(col, &peer(0xa2, 0x31))?;
        t.set_trust(col, &id(0xa2), Some(TRUST_PENDING), 6)?;
        t.set_peer(col, &peer(0xa3, 0x32))?;
        let trusted_prev = PrevIdentity {
            device: id(0xa3),
            seq: 1,
            chain: CHAIN_ZERO,
        };
        for (new, prev) in [(0xb1u8, None), (0xb2, Some(&trusted_prev))] {
            let p = peer(new, 0x31);
            assert_eq!(t.set_peer(col, &p)?, PeerPut::Inserted);
            let got = t.note_new_peer(col, &id(new), &p.public, prev, T1 + 7)?;
            assert_eq!(got, FirstSeen::Pending, "{new:#x}");
            assert_eq!(
                t.trust_entry(col, &id(new))?,
                Some((TRUST_PENDING, T1 + 7)),
                "{new:#x}"
            );
        }
        Ok(())
    });
}
