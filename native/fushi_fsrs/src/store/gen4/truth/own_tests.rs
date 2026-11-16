//! [super]（本机身份与换身份）的测试。装置在 `store/gen4/fork_tests.rs`。

use super::*;
use crate::gen4::op::Body4;
use crate::store::gen4::derive::tests::dump;
use crate::store::gen4::fork::tests::{OWN, SEED, T0, body, idn, op, rebuild, setup, write_own};
use crate::store::gen4::schema::open;
use crate::sync2::id::Key;
use crate::sync2::keys::DeviceKey;
use crate::sync2::op::EntKind;

fn me(t: &Truth<'_>, col: i64) -> SelfId {
    t.self_identity(col).unwrap().unwrap()
}

fn oid(device: Id, seq: u64) -> OpId {
    OpId { device, seq }
}

fn count(conn: &Connection, sql_: &str) -> i64 {
    conn.query_row(sql_, [], |r| r.get(0)).unwrap()
}

#[test]
fn the_hlc_text_has_exactly_one_shape() {
    let h = Hlc {
        wall: 1_800_000_000_123,
        logical: 7,
        device: idn(1, 1),
    };
    assert_eq!(hlc_text(&h), "1800000000123:7");
    assert_eq!(hlc_parse("1800000000123:7", h.device), Ok(h));
    assert_eq!(
        hlc_parse("-5:0", h.device).map(|h| h.wall),
        Ok(-5),
        "negative walls are written with a sign"
    );
    for bad in [
        "",
        "1",
        "1:",
        ":1",
        "01:2",
        "1:02",
        "+1:2",
        "1:2:3",
        "1:-1",
        " 1:2",
        "1:4294967296",
    ] {
        assert!(hlc_parse(bad, h.device).is_err(), "{bad:?}");
    }
}

#[test]
fn the_local_identity_reads_back_and_never_prints_its_seed() {
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    let m = me(&t, col);
    assert_eq!(
        (m.device, m.sk, m.prev.clone(), m.created),
        (OWN, SEED, None, T0)
    );
    assert_eq!((m.hlc.wall, m.hlc.logical, m.hlc.device), (0, 0, OWN));
    assert_eq!(m.public(), DeviceKey::from_seed(&SEED).public());
    assert_eq!(m.key().public(), m.public());
    // 本机的公钥进了 peers。
    assert_eq!(t.device_key(col, &m.device), Ok(Some(m.public())));
    // Debug 不打印钥匙种子。
    let shown = format!("{m:?}");
    assert!(!shown.contains("sk"), "{shown}");
    assert!(!shown.contains(&format!("{SEED:?}")), "{shown}");
    // 时钟：下一次发出的时刻严格大于存着的。
    t.tx(|t| {
        t.set_self_hlc(
            col,
            &Hlc {
                wall: T0 + 1,
                logical: 0,
                device: OWN,
            },
        )
    })
    .unwrap();
    let m = me(&t, col);
    assert!(m.clock().tick(T0) > m.hlc);
}

#[test]
fn the_previous_identity_columns_take_one_shape() {
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    let set = |d: Option<Vec<u8>>, s: Option<i64>, c: Option<Vec<u8>>| {
        t.tx(|t| {
            t.conn()
                .execute(
                    "UPDATE self_ SET prev_device = ?2, prev_seq = ?3, prev_chain = ?4 WHERE col = ?1",
                    params![col, d, s, c],
                )
                .map_err(sql)
        })
        .unwrap();
    };
    let dev = Some(idn(6, 6).0.to_vec());
    // 写入与读回同一组编码函数（换身份写的就是 prev_cols 的输出）。
    for prev in [
        PrevIdentity {
            device: idn(6, 6),
            seq: 41,
            chain: [3; 32],
        },
        PrevIdentity {
            device: idn(6, 6),
            seq: 0,
            chain: CHAIN_ZERO,
        },
    ] {
        let (d, s, c) = prev_cols(Some(&prev));
        set(d, s, c);
        assert_eq!(me(&t, col).prev, Some(prev));
    }
    assert_eq!(prev_cols(None), (None, None, None));
    // 只存了一半、负的 seq、seq 0 却不是链的起点：坏数据，读身份报错。
    for (d, s, c) in [
        (dev.clone(), None, Some(vec![3u8; 32])),
        (None, Some(4), Some(vec![3u8; 32])),
        (dev.clone(), Some(-1), Some(vec![3u8; 32])),
        (dev.clone(), Some(0), Some(vec![3u8; 32])),
    ] {
        set(d, s, c);
        let e = t.self_identity(col).unwrap_err();
        assert!(e.contains("torn prev identity"), "{e}");
    }
}

#[test]
fn rotating_an_identity_that_wrote_nothing_freezes_it_at_the_chain_start() {
    // 上一个身份一条操作都没写过（keep = 0）：prev 仍然记下（head 的 prev 收 seq 0，别的设备据此把信任带到新身份），
    // seq = 0、链值 = 链的起点；读回来一致。
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    let old = me(&t, col);
    let r = t.rotate_identity_report(col, 0, T0 + 5).unwrap();
    assert_eq!((r.keep, r.moved.len(), r.dropped_voids), (0, 0, 0));
    let new = me(&t, col);
    assert_eq!(
        new.prev,
        Some(PrevIdentity {
            device: old.device,
            seq: 0,
            chain: CHAIN_ZERO,
        })
    );
    assert_eq!(new.sk, old.sk);
    // 全部操作都搬走（分叉点 0）也是同一个形状。
    write_own(&t, col, 3);
    let r = t.rotate_identity_report(col, 0, T0 + 6).unwrap();
    assert_eq!((r.keep, r.moved.len()), (0, 3));
    assert_eq!(
        me(&t, col).prev,
        Some(PrevIdentity {
            device: new.device,
            seq: 0,
            chain: CHAIN_ZERO,
        })
    );
    // 换过身份之后原生写入者照常接着写（set_self_hlc 只认新身份）。
    let cur = me(&t, col);
    let next = Hlc {
        wall: cur.hlc.wall + 1,
        ..cur.hlc
    };
    assert_eq!(t.tx(|t| t.set_self_hlc(col, &next)), Ok(()));
}

#[test]
fn rotating_at_the_end_moves_nothing_and_links_the_new_identity_to_the_old() {
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    let chains = write_own(&t, col, 5);
    let old = me(&t, col);
    let r = t.rotate_identity_report(col, 5, T0 + 100).unwrap();
    assert_eq!(
        (r.previous, r.keep, r.moved.len(), r.dropped_voids),
        (old.device, 5, 0, 0)
    );
    let new = me(&t, col);
    assert_eq!(new.device, r.device);
    assert_ne!(new.device, old.device);
    assert_eq!(new.sk, old.sk, "the signing key carries over");
    assert_eq!(
        new.prev,
        Some(PrevIdentity {
            device: old.device,
            seq: 5,
            chain: chains[4],
        })
    );
    assert_eq!(new.created, T0 + 100);
    // 旧日志原样留着；两个身份都用本机的公钥登记。
    assert_eq!(t.last_of(col, &old.device), Ok(5));
    assert_eq!(t.chain_at(col, &old.device, 5), Ok(chains[4]));
    assert_eq!(t.device_key(col, &old.device), Ok(Some(old.public())));
    assert_eq!(t.device_key(col, &new.device), Ok(Some(old.public())));
    // 新身份从 seq 1 写起。
    t.tx(|t| t.append_native(col, &op(new.device, 1, &body(1, 3), Vv::new())))
        .unwrap();
    // 再换一次：prev 接到上一个新身份。
    let id3 = t.rotate_identity(col, 1, T0 + 200).unwrap();
    let third = me(&t, col);
    assert_eq!(third.device, id3);
    assert_eq!(
        third.prev.as_ref().map(|p| (p.device, p.seq)),
        Some((new.device, 1))
    );
    // 本机末尾之后不是本机写过的前缀。
    let e = t.rotate_identity(col, 1, T0 + 300).unwrap_err();
    assert!(e.contains("log ends at 0"), "{e}");
    assert_eq!(me(&t, col), third);
}

#[test]
fn a_fork_reissues_the_later_ops_under_the_new_identity_and_keeps_state_in_step() {
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    let other = idn(0x77, 1);
    // 别的设备写了 3 条。
    t.tx(|t| {
        for seq in 1..=3 {
            t.append_native(col, &op(other, seq, &body(seq, 5), Vv::new()))?;
        }
        Ok(())
    })
    .unwrap();
    let old = me(&t, col);
    let mut x = Vv::new();
    x.set(other, 2);
    let mut beyond = Vv::new();
    beyond.set(other, 5);
    let bodies: Vec<(Body4, Vv)> = vec![
        (body(0, 0), Vv::new()),
        (body(1, 0), x.clone()),
        (body(2, 0), Vv::new()),
        (body(3, 0), x.clone()),
        (Body4::salts(["u-old"]).unwrap(), Vv::new()),
        (body(4, 0), beyond.clone()),
        (
            Body4::Purge {
                kind: EntKind::Note,
                entity: Key::Uuid(idn(0x55, 1)),
            },
            Vv::new(),
        ),
        (body(5, 0), x.clone()),
    ];
    let originals: Vec<Op4> = t
        .tx(|t| {
            let mut out = Vec::new();
            for (i, (b, deps)) in bodies.iter().enumerate() {
                let o = op(old.device, i as u64 + 1, b, deps.clone());
                t.append_native(col, &o)?;
                out.push(o);
            }
            Ok(out)
        })
        .unwrap();
    // 暂扣 / 检查点按操作号记的行。
    t.tx(|t| {
        for seq in [2i64, 5, 7] {
            t.conn()
                .execute(
                    "INSERT INTO held (col, device, seq, kind, entity) VALUES (?1, ?2, ?3, 'note', 'e')",
                    params![col, &old.device.0[..], seq],
                )
                .map_err(sql)?;
            t.conn()
                .execute(
                    "INSERT INTO checkpoints (col, device, seq, wall, name, reason) VALUES (?1, ?2, ?3, 0, 'n', 'r')",
                    params![col, &old.device.0[..], seq],
                )
                .map_err(sql)?;
        }
        Ok(())
    })
    .unwrap();
    rebuild(&t, col);
    let r = t.rotate_identity_report(col, 3, T0 + 500).unwrap();
    let new = me(&t, col);
    assert_eq!((r.keep, r.device, r.dropped_voids), (3, new.device, 0));
    assert_eq!(
        r.moved,
        (4..=8)
            .map(|s| (oid(old.device, s), oid(new.device, s - 3)))
            .collect::<Vec<_>>()
    );
    // 旧身份截到 3，链值接得上；新身份 1..=5 是重签发：载荷逐字节不变，HLC 严格递增且不早于原来的墙钟，依赖向量
    // 把旧身份压到 3、其它设备不超过本机已应用的。
    assert_eq!(t.last_of(col, &old.device), Ok(3));
    assert_eq!(t.last_of(col, &new.device), Ok(5));
    let mut prev_hlc = old.hlc;
    for (from, to) in &r.moved {
        let orig = &originals[from.seq as usize - 1];
        let e = t.entry(col, to).unwrap().unwrap();
        let re = e.op().unwrap();
        assert_eq!(
            (re.kind, re.fmt, &re.payload),
            (orig.kind, orig.fmt, &orig.payload)
        );
        assert!(re.hlc > prev_hlc && re.hlc > orig.hlc);
        prev_hlc = re.hlc;
        assert_eq!(re.deps.get(&old.device), (from.seq - 1).min(3));
        assert_eq!(re.deps.get(&new.device), 0);
        assert!(re.deps.get(&other) <= 3);
        assert_eq!(re.deps.get(&other), orig.deps.get(&other).min(3));
    }
    assert_eq!(
        me(&t, col).hlc,
        prev_hlc,
        "the clock is saved past the re-issued ops"
    );
    // 带盐的操作搬过来了，没有被清成空洞。
    let salts = t.entry(col, &oid(new.device, 2)).unwrap().unwrap();
    assert_eq!(salts.op().unwrap().kind, crate::gen4::op::KIND_SALTS);
    // 本机状态改键：搬走的 5、7 → 新身份的 2、4；2 留在旧身份。
    let keys = |table: &str| -> Vec<(Vec<u8>, i64)> {
        let mut s = conn
            .prepare(&format!(
                "SELECT device, seq FROM {table} ORDER BY device, seq"
            ))
            .unwrap();
        s.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    let mut want = vec![
        (old.device.0.to_vec(), 2),
        (new.device.0.to_vec(), 2),
        (new.device.0.to_vec(), 4),
    ];
    want.sort();
    assert_eq!(keys("held"), want);
    assert_eq!(keys("checkpoints"), want);
    // 派生索引在换身份里逐条维护，与重建逐行相同；真相层自洽。
    let inc = dump(&conn, col);
    rebuild(&t, col);
    assert_eq!(inc, dump(&conn, col));
    assert_eq!(t.audit(col), Ok(3 + 3 + 5));
    // 链值记号只留在冻结点之前。
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM log_marks"),
        0,
        "short logs carry no marks"
    );
}

#[test]
fn a_keep_point_inside_a_void_moves_back_to_where_the_chain_is_known() {
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    let chains = write_own(&t, col, 12);
    let old = me(&t, col);
    t.tx(|t| {
        for seq in 5..=8 {
            t.advance_purge(col, &oid(old.device, seq))?;
        }
        Ok(())
    })
    .unwrap();
    rebuild(&t, col);
    // 6 在空洞 5..=8 内部：退到 4；5..=8 四条空洞丢掉，9..=12 重签发。
    let r = t.rotate_identity_report(col, 6, T0 + 10).unwrap();
    assert_eq!((r.keep, r.dropped_voids, r.moved.len()), (4, 4, 4));
    assert_eq!(
        me(&t, col).prev.map(|p| (p.seq, p.chain)),
        Some((4, chains[3]))
    );
    assert_eq!(t.last_of(col, &old.device), Ok(4));
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM op_voids"), 0);
    // 冻结点落在空洞区间末尾（链值已知）就不退。
    let (conn2, col2) = setup();
    let t2 = Truth::new(&conn2);
    let c2 = write_own(&t2, col2, 6);
    let old2 = me(&t2, col2);
    t2.tx(|t| t.advance_purge(col2, &oid(old2.device, 3)))
        .unwrap();
    let r2 = t2.rotate_identity_report(col2, 3, T0 + 10).unwrap();
    assert_eq!((r2.keep, r2.moved.len()), (3, 3));
    // 旧身份末尾是那个空洞，之后的同号操作照常接上。
    assert_eq!(t2.chain_at(col2, &old2.device, 3), Ok(c2[2]));
    let next = op(old2.device, 4, &body(4, 9), Vv::new());
    t2.tx(|t| t.append_native(col2, &next)).unwrap();
    assert_eq!(t2.last_of(col2, &old2.device), Ok(4));
    let inc = dump(&conn, col);
    rebuild(&t, col);
    assert_eq!(inc, dump(&conn, col));
}

#[test]
fn a_failure_halfway_leaves_nothing_behind() {
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    write_own(&t, col, 9);
    let old = me(&t, col);
    rebuild(&t, col);
    // 旧身份在 peers 里登记的是另一把钥匙：换身份走到登记公钥那一步才失败，此前已经截了日志、重签发了操作。
    t.tx(|t| {
        t.conn()
            .execute(
                "UPDATE peers SET public = ?2 WHERE col = ?1",
                params![col, &[1u8; 32][..]],
            )
            .map_err(sql)
    })
    .unwrap();
    let before = (
        dump(&conn, col),
        count(&conn, "SELECT COUNT(*) FROM ops"),
        count(&conn, "SELECT COUNT(*) FROM devs"),
    );
    let e = t.rotate_identity(col, 4, T0 + 1).unwrap_err();
    assert!(e.contains("another public key"), "{e}");
    assert_eq!(
        (
            dump(&conn, col),
            count(&conn, "SELECT COUNT(*) FROM ops"),
            count(&conn, "SELECT COUNT(*) FROM devs"),
        ),
        before
    );
    assert_eq!(me(&t, col), old);
    assert_eq!(t.last_of(col, &old.device), Ok(9));
    // 会话照常可用（出错的那一笔自动 reset）。
    t.tx(|t| {
        t.conn()
            .execute(
                "UPDATE peers SET public = ?2 WHERE col = ?1",
                params![col, &old.public()[..]],
            )
            .map_err(sql)
    })
    .unwrap();
    let r = t.rotate_identity_report(col, 4, T0 + 2).unwrap();
    assert_eq!(r.moved.len(), 5);
    let inc = dump(&conn, col);
    rebuild(&t, col);
    assert_eq!(inc, dump(&conn, col));
}

#[test]
fn another_connection_sees_the_new_identity_and_a_stale_session_cannot_write() {
    let dir = std::env::temp_dir().join(format!("fushi-g8-6-{}", Id::random().text()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("srs4.db");
    let a = open(&path).unwrap();
    let b = open(&path).unwrap();
    let ta = Truth::new(&a);
    let col = crate::store::gen4::truth::tests::bound(&ta);
    ta.tx(|t| t.create_self(col, &OWN, &SEED, None, T0))
        .unwrap();
    write_own(&ta, col, 6);
    let old = me(&ta, col);
    // B 的会话先把缓存填上（日志末尾 6）。
    let tb = Truth::new(&b);
    assert_eq!(tb.last_of(col, &old.device), Ok(6));
    // A 换身份并提交。
    let new = ta.rotate_identity(col, 2, T0 + 1).unwrap();
    // B 自己开事务却没 reset：缓存是旧的（末尾 6），写入被拒，不会接着旧末尾写。
    b.execute_batch("BEGIN IMMEDIATE").unwrap();
    let e = tb
        .append_native(col, &op(old.device, 7, &body(7, 0), Vv::new()))
        .unwrap_err();
    assert!(e.contains("another connection committed"), "{e}");
    b.execute_batch("ROLLBACK").unwrap();
    // 经 tx 的会话看到的是 A 提交后的状态：身份已换，旧身份冻结在 2，新身份接着 4 条之后写。
    let got = tb
        .tx(|t| {
            let m = t.self_identity(col)?.unwrap();
            let last = t.last_of(col, &m.device)?;
            t.append_native(col, &op(m.device, last + 1, &body(99, 4), Vv::new()))?;
            Ok((m.device, t.last_of(col, &old.device)?, last))
        })
        .unwrap();
    assert_eq!(got, (new, 2, 4));
    drop((ta, tb));
    drop((a, b));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn reissued_ops_come_after_the_originals_even_when_the_local_clock_lags() {
    // self_.hlc 没人推进过（create_self 写的 0:0），原操作的 HLC 是 (W, 5)、(W, 6)、(W+1, 0)，换身份时墙钟 now < W。
    // 只接着 self_.hlc tick 会发出 (W, 0)，比原操作还小。
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    let old = me(&t, col);
    assert_eq!((old.hlc.wall, old.hlc.logical), (0, 0));
    let w = T0 + 50_000;
    let at = |wall: i64, logical: u32| Hlc {
        wall,
        logical,
        device: old.device,
    };
    let hlcs = [at(T0, 0), at(w, 5), at(w, 6), at(w + 1, 0)];
    let originals: Vec<Op4> = t
        .tx(|t| {
            let mut out = Vec::new();
            for (i, h) in hlcs.iter().enumerate() {
                let seq = i as u64 + 1;
                let o = Op4::of(oid(old.device, seq), *h, Arc::new(Vv::new()), &body(seq, 0));
                t.append_native(col, &o)?;
                out.push(o);
            }
            Ok(out)
        })
        .unwrap();
    let r = t.rotate_identity_report(col, 1, T0 + 10).unwrap();
    assert_eq!(r.moved.len(), 3);
    let top = originals.iter().map(|o| o.hlc).max().unwrap();
    let mut prev: Option<Hlc> = None;
    for (from, to) in &r.moved {
        let orig = &originals[from.seq as usize - 1];
        let re = t.entry(col, to).unwrap().unwrap().op().unwrap().clone();
        assert!(
            (re.hlc.wall, re.hlc.logical) > (top.wall, top.logical),
            "{:?} must come after every moved original (max {:?})",
            re.hlc,
            top
        );
        assert!(re.hlc > orig.hlc);
        if let Some(p) = prev {
            assert!(re.hlc > p);
        }
        prev = Some(re.hlc);
    }
    // 新身份的时钟记到了最后一条重签发的时刻。
    assert_eq!(me(&t, col).hlc, prev.unwrap());
}
