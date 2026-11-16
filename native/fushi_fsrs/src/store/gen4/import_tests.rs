//! G11-2 的测试：导出 → 导入往返逐字节 / 逐行等价、并入有自己数据的库、中断重来不重复、坏文件与另一个集合整个拒绝、
//! 原生日志分叉与公钥冒名拒绝、协议 3 的 `.fushisrs` 与旧备份读入后与直接迁移逐字节相同。

use std::collections::BTreeSet;
use std::path::Path;

use rusqlite::Connection;
use serde_json::json;

use super::*;
use crate::gen4::heritage::HeritageSlot;
use crate::gen4::op::tests::id;
use crate::gen4::op::{Body4, Op4};
use crate::store::gen4::derive::tests::{assert_rebuild_is_identity, dump, op};
use crate::store::gen4::export::export_ops;
use crate::store::gen4::legacy::tests::{T0, pair};
use crate::store::gen4::native::Native;
use crate::store::gen4::native::tests::edit;
use crate::store::gen4::schema::{open, open_in_memory};
use crate::store::sync2::tests::{DAY, Device, P, tempdir};
use crate::sync2::id::Key;
use crate::sync2::op::EntKind;

const NOW: i64 = 1_800_000_000_000;
const ME_A: u8 = 0xa1;
const ME_B: u8 = 0xb2;
/// 另一台协议 4 设备：原生日志里有两段清除过的区间（其中一段是分两次收到的相邻空洞）。
const PEER: u8 = 0x31;
const PEER_KEY: [u8; 32] = [0x31; 32];
/// 一条手工的承袭日志：带分叉的另一支与链值记号。
const OLD: u8 = 0xd1;
const OLD_SRC: u8 = 0x5c;

fn sk(me: u8) -> [u8; 32] {
    [me; 32]
}

/// 绑到 P 的协议 3 集合（迁移出来的集合都是这样）、建本机身份。
fn fresh(t: &Truth<'_>, me: u8) -> i64 {
    let col = t.tx(|t| t.bind(P, &collection_of(P), P)).unwrap();
    assert_eq!(
        t.tx(|t| t.create_self(col, &id(me), &sk(me), None, NOW)),
        Ok(true)
    );
    col
}

fn peer_ops() -> Vec<Op4> {
    (1..=7)
        .map(|s| op(PEER, s, NOW + s as i64, &[], &edit(&format!("p{s}"))))
        .collect()
}

/// PEER 的原生日志在每格的链值（照完整的操作算；空洞处的链值就是这里的）。
fn peer_chains() -> Vec<Chain> {
    let mut c = CHAIN_ZERO;
    peer_ops()
        .iter()
        .map(|o| {
            c = chain_next4(&c, o);
            c
        })
        .collect()
}

fn chain_with_fp(fp: u8) -> Chain {
    let mut c = [0x77; 32];
    c[..8].copy_from_slice(&[fp; 8]);
    c
}

fn old_slot(seq: u64, fp: u8, value: &str) -> HeritageSlot {
    HeritageSlot::op(
        [fp; 8],
        op(OLD, seq, NOW - 1000 + seq as i64, &[], &edit(value)),
    )
}

fn note_entity() -> Body4 {
    let note = Id::parse("3f2b8c1e-5d4a-4f6b-9c2d-1a2b3c4d5e6f").unwrap();
    let note_type = Id::parse("7a1c2e3f-4b5d-4c6e-8f70-819203a4b5c6").unwrap();
    Body4::Entity {
        kind: EntKind::Note,
        id: Key::Uuid(note),
        data: format!(
            r#"{{"createdAt":1700000000000,"guid":"g-import-1","noteTypeId":"{}"}}"#,
            note_type.text()
        ),
    }
}

/// 一个什么都有的库：协议 3 灌进来的承袭日志（真实数据）、带空洞的别的原生日志、本机原生日志、带分叉与记号的承袭日志。
fn library(t: &Truth<'_>, me: u8, legacy: &Device) -> i64 {
    let col = fresh(t, me);
    {
        let w = legacy.core.writer().unwrap();
        import_legacy(&w, P, t, col, 1000).unwrap();
    }
    let ops = peer_ops();
    let chains = peer_chains();
    t.tx(|t| {
        t.set_peer(
            col,
            &Peer {
                device: id(PEER),
                public: PEER_KEY,
                name: Some("peer".into()),
                ext: None,
                head_gen: None,
                first_seen: None,
            },
        )?;
        t.append_native(col, &ops[0])?;
        t.append_native_void(col, &id(PEER), 2, &chains[2])?;
        t.append_native(col, &ops[3])?;
        // 相邻的两段空洞（分两次收到）：导出时合成一段。
        t.append_native_void(col, &id(PEER), 1, &chains[4])?;
        t.append_native_void(col, &id(PEER), 1, &chains[5])?;
        t.append_native(col, &ops[6])?;
        let src = id(OLD_SRC);
        for (seq, fp, v) in [(1, 0x10, "o1"), (2, 0x20, "o2"), (3, 0x30, "o3")] {
            assert_eq!(
                t.put_heritage(col, &src, &old_slot(seq, fp, v), T_VERSION)?,
                Put::Inserted
            );
        }
        // 分叉的另一支：一支链指纹更大（进 op_forks），一支更小（与日志里的对调）。
        assert_eq!(
            t.put_heritage(col, &src, &old_slot(2, 0xe0, "o2-other"), T_VERSION)?,
            Put::Fork
        );
        assert_eq!(
            t.put_heritage(col, &src, &old_slot(3, 0x03, "o3-other"), T_VERSION)?,
            Put::Replaced
        );
        t.set_mark(col, &id(OLD), 2, &chain_with_fp(0x20))?;
        t.set_mark(col, &id(OLD), 3, &chain_with_fp(0x03))?;
        let mut ix = Index::new(t, col);
        let mut n = Native::open(t, col)?;
        n.write(&mut ix, note_entity(), NOW + 100)?;
        n.write(&mut ix, edit("mine"), NOW + 101)?;
        ingest_settle(t, &mut ix, col, Settle::Rebuild)?;
        Ok(())
    })
    .unwrap();
    col
}

fn export(t: &Truth<'_>, col: i64) -> Vec<u8> {
    export_ops(t, col, Vec::new()).unwrap().0
}

/// 真相层逐条（不含 `local` 标记）、分叉、记号、公钥：导入方应与导出方相同的部分。
/// 派生表逐行（[dump] 的口径），只是把操作主键 `k`（设备下标是本库的落库顺序，两个库里不同）换成「设备:seq」、
/// 去掉 `col`：两个库里同一份真相的派生表在这个口径下逐行相同。
fn rows(t: &Truth<'_>, col: i64) -> Vec<String> {
    let conn = t.conn();
    let mut out = Vec::new();
    for table in crate::store::gen4::schema::DERIVED_TABLES {
        let mut stmt = conn
            .prepare(&format!("SELECT * FROM {table} WHERE col = ?1"))
            .unwrap();
        let names: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
        let mut lines = Vec::new();
        let mut q = stmt.query([col]).unwrap();
        while let Some(r) = q.next().unwrap() {
            let mut cells = Vec::new();
            for (i, name) in names.iter().enumerate() {
                let v = r.get::<_, rusqlite::types::Value>(i).unwrap();
                match (name.as_str(), v) {
                    ("col", _) => {}
                    ("k", rusqlite::types::Value::Integer(k)) => {
                        let o = t.id_of_key(k).unwrap();
                        cells.push(format!("k={}:{}", o.device, o.seq));
                    }
                    (_, v) => cells.push(format!("{v:?}")),
                }
            }
            lines.push(format!("{table} {}", cells.join(" | ")));
        }
        lines.sort();
        out.extend(lines);
    }
    out
}

/// 按设备 ID 排（本机的设备下标是落库顺序，两个库里不同）。
fn truth_lines(t: &Truth<'_>, col: i64) -> Vec<String> {
    let mut logs: Vec<(Id, Vec<String>)> = Vec::new();
    for d in t.devices(col).unwrap() {
        if d.last == 0 {
            continue;
        }
        let mut out = vec![format!("dev {} {:?} {:?} {}", d.id, d.kind, d.src, d.last)];
        t.for_each(col, &d.id, 1, |e| {
            out.push(format!("  {} {:?} {} {:?}", e.id.seq, e.fp, e.tv, e.body));
            Ok(())
        })
        .unwrap();
        for (seq, c) in t.marks(col, &d.id).unwrap() {
            out.push(format!("  mark {seq} {c:?}"));
        }
        logs.push((d.id, out));
    }
    logs.sort_by(|a, b| a.0.0.cmp(&b.0.0));
    let mut out: Vec<String> = logs.into_iter().flat_map(|(_, l)| l).collect();
    let mut forks: Vec<String> = t
        .forks(col)
        .unwrap()
        .into_iter()
        .map(|p| format!("fork {:?} {}", p.slot, p.tv))
        .collect();
    forks.sort();
    out.extend(forks);
    out
}

fn ops_rows(conn: &Connection) -> i64 {
    conn.query_row(
        "SELECT (SELECT COUNT(*) FROM ops) + (SELECT COUNT(*) FROM op_alias) + (SELECT COUNT(*) FROM op_voids) + (SELECT COUNT(*) FROM peers)",
        [],
        |r| r.get(0),
    )
    .unwrap()
}

// ------------------------------------------------------------ 往返

/// 导出 → 导入空库 → 再导出：逐字节相同；派生表逐行相同；真相层逐条相同。同一份再导一遍、导回导出方自己，都什么
/// 都不改。
#[test]
fn export_then_import_round_trips_byte_for_byte_and_row_for_row() {
    let (a_dev, _, _) = pair();
    let ca = open_in_memory().unwrap();
    let ta = Truth::new(&ca);
    let col_a = library(&ta, ME_A, &a_dev);
    let (bytes, stats) = export_ops(&ta, col_a, Vec::new()).unwrap();
    // 合并之后：PEER 两段空洞（2..=3、5..=6）。
    assert_eq!((stats.void_runs, stats.voided), (2, 4));
    // 分叉：seq 2 的另一支（链指纹更大），seq 3 被对调出去的原日志槽。
    assert_eq!((stats.forks, stats.native_logs), (2, 2));
    assert!(stats.slots > 3 && stats.marks >= 2, "{stats:?}");
    // 同一份真相导出两次逐字节相同。
    assert_eq!(export(&ta, col_a), bytes);

    let cb = open_in_memory().unwrap();
    let tb = Truth::new(&cb);
    let col_b = fresh(&tb, ME_B);
    let got = import_ops(&tb, col_b, &bytes).unwrap();
    assert_eq!(got.native_logs, 2);
    assert_eq!(got.native_landed, stats.ops);
    assert_eq!(
        got.slots_inserted + got.slots_forked,
        stats.slots + stats.forks
    );
    assert_eq!(got.slots_forked, 2);
    // 公钥：PEER 的、A 本机的（从签名钥匙算出来写进流）。
    assert_eq!(got.peers, 2);
    assert_eq!(tb.device_key(col_b, &id(PEER)).unwrap(), Some(PEER_KEY));
    assert_eq!(
        tb.device_key(col_b, &id(ME_A)).unwrap(),
        Some(ta.self_identity(col_a).unwrap().unwrap().public())
    );
    assert_eq!(export(&tb, col_b), bytes);
    assert_eq!(rows(&tb, col_b), rows(&ta, col_a));
    assert!(!rows(&tb, col_b).is_empty());
    assert_eq!(truth_lines(&tb, col_b), truth_lines(&ta, col_a));
    assert_rebuild_is_identity(&tb, col_b);

    // 再导一遍：什么都不改。
    let before = dump(&cb, col_b);
    let again = import_ops(&tb, col_b, &bytes).unwrap();
    assert!(again.unchanged(), "{again:?}");
    assert_eq!(again.native_known, got.native_landed + stats.voided);
    assert_eq!(dump(&cb, col_b), before);
    assert_eq!(export(&tb, col_b), bytes);
    // 导回导出方自己：本机自己的原生日志、空洞都对得上，什么都不改。
    let own = import_ops(&ta, col_a, &bytes).unwrap();
    assert!(own.unchanged(), "{own:?}");
    assert_eq!(export(&ta, col_a), bytes);
}

/// 两边各有自己的数据：互相导入之后真相相同、派生表逐行相同、导出逐字节相同（并入 = 操作并集）。
#[test]
fn importing_into_a_library_with_its_own_data_is_a_union() {
    let (a_dev, b_dev, _) = pair();
    let ca = open_in_memory().unwrap();
    let ta = Truth::new(&ca);
    let col_a = library(&ta, ME_A, &a_dev);
    let cb = open_in_memory().unwrap();
    let tb = Truth::new(&cb);
    let col_b = fresh(&tb, ME_B);
    {
        // B 先灌了另一台协议 3 设备（同一个集合、收全了的）的库，再自己写两条。
        let w = b_dev.core.writer().unwrap();
        import_legacy(&w, P, &tb, col_b, 1000).unwrap();
    }
    tb.tx(|t| {
        let mut ix = Index::new(t, col_b);
        let mut n = Native::open(t, col_b)?;
        n.write(&mut ix, edit("b1"), NOW + 200)?;
        n.write(&mut ix, edit("b2"), NOW + 201)?;
        ingest_settle(t, &mut ix, col_b, Settle::Rebuild).map(|_| ())
    })
    .unwrap();
    let from_a = export(&ta, col_a);
    let from_b = export(&tb, col_b);
    let into_b = import_ops(&tb, col_b, &from_a).unwrap();
    assert!(
        into_b.native_landed > 0 && into_b.slots_same > 0,
        "{into_b:?}"
    );
    let into_a = import_ops(&ta, col_a, &from_b).unwrap();
    assert_eq!(into_a.native_landed, 2);
    assert_eq!(truth_lines(&ta, col_a), truth_lines(&tb, col_b));
    assert_eq!(rows(&ta, col_a), rows(&tb, col_b));
    assert_eq!(export(&ta, col_a), export(&tb, col_b));
    // 并入之后本机照常往下写（本机身份的日志末尾、链都接得上）。
    tb.tx(|t| {
        let mut ix = Index::new(t, col_b);
        Native::open(t, col_b)?.write(&mut ix, edit("b3"), NOW + 300)?;
        ingest_settle(t, &mut ix, col_b, Settle::Incremental).map(|_| ())
    })
    .unwrap();
    assert_rebuild_is_identity(&tb, col_b);
}

/// 流里是空洞、本机是完整操作：本机的不动（本机的槽只由本机自己的清除推进），链照样核对得上。
#[test]
fn voids_in_the_file_never_take_local_ops_away() {
    let (a_dev, _, _) = pair();
    let ca = open_in_memory().unwrap();
    let ta = Truth::new(&ca);
    let col_a = library(&ta, ME_A, &a_dev);
    let bytes = export(&ta, col_a);
    let cb = open_in_memory().unwrap();
    let tb = Truth::new(&cb);
    let col_b = fresh(&tb, ME_B);
    // B 收全了 PEER 的 1..=5（没清除）。
    tb.tx(|t| {
        for o in &peer_ops()[..5] {
            t.append_native(col_b, o)?;
        }
        Ok(())
    })
    .unwrap();
    let got = import_ops(&tb, col_b, &bytes).unwrap();
    assert_eq!(got.native_known, 5);
    let mut bodies = Vec::new();
    tb.for_each(col_b, &id(PEER), 1, |e| {
        bodies.push(matches!(e.body, SlotBody::Op(_)));
        Ok(())
    })
    .unwrap();
    // 1..=5 是本机的完整操作；6 是流里多出来的那一截空洞，7 是操作。
    assert_eq!(bodies, vec![true, true, true, true, true, false, true]);
    assert_eq!(tb.chain_at(col_b, &id(PEER), 7).unwrap(), peer_chains()[6]);
    assert_rebuild_is_identity(&tb, col_b);
}

/// 本机库回到了更早的副本（恢复了旧库）、导出包里本机身份的日志更长：接回来，之后照常往下写；旧副本在那之后自己又写过
/// （同一个身份写出了两支）：整个导入拒绝，交给身份分叉处理。
#[test]
fn the_own_log_comes_back_from_an_export_but_a_second_branch_is_refused() {
    let (a_dev, _, _) = pair();
    let dir = tempdir::new("gen4-import-own");
    let ca = open_in_memory().unwrap();
    let ta = Truth::new(&ca);
    let col_a = library(&ta, ME_A, &a_dev);
    let copy = |name: &str| -> std::path::PathBuf {
        let p = dir.0.join(name);
        ca.execute("VACUUM INTO ?1", [p.to_str().unwrap()]).unwrap();
        p
    };
    let (old, branch) = (copy("old.db"), copy("branch.db"));
    ta.tx(|t| {
        let mut ix = Index::new(t, col_a);
        let mut n = Native::open(t, col_a)?;
        n.write(&mut ix, edit("later 1"), NOW + 400)?;
        n.write(&mut ix, edit("later 2"), NOW + 401)?;
        ingest_settle(t, &mut ix, col_a, Settle::Incremental).map(|_| ())
    })
    .unwrap();
    let bytes = export(&ta, col_a);

    let co = open(&old).unwrap();
    let to = Truth::new(&co);
    assert_eq!(to.last_of(col_a, &id(ME_A)).unwrap(), 2);
    let got = import_ops(&to, col_a, &bytes).unwrap();
    assert_eq!((got.native_landed, got.peers), (2, 0));
    assert_eq!(to.last_of(col_a, &id(ME_A)).unwrap(), 4);
    assert_eq!(export(&to, col_a), bytes);
    assert_eq!(rows(&to, col_a), rows(&ta, col_a));
    let (next, _) = to
        .tx(|t| {
            let mut ix = Index::new(t, col_a);
            let w = Native::open(t, col_a)?.write(&mut ix, edit("after"), NOW + 500)?;
            ingest_settle(t, &mut ix, col_a, Settle::Incremental)?;
            Ok(w)
        })
        .unwrap();
    assert_eq!(next.seq, 5);

    let cb = open(&branch).unwrap();
    let tb = Truth::new(&cb);
    tb.tx(|t| {
        let mut ix = Index::new(t, col_a);
        Native::open(t, col_a)?.write(&mut ix, edit("other branch"), NOW + 450)?;
        ingest_settle(t, &mut ix, col_a, Settle::Incremental).map(|_| ())
    })
    .unwrap();
    let before = ops_rows(&cb);
    let e = import_ops(&tb, col_a, &bytes).unwrap_err();
    assert!(e.contains("diverges") && e.contains("seq 3"), "{e}");
    assert_eq!(ops_rows(&cb), before);
}

// ------------------------------------------------------------ 中断与重入

/// 子进程那一半：开最外层事务、整份导入（成功）、不提交就退出（等于导入到一半被杀）。
#[test]
fn import_child_process_half() {
    let (Ok(db), Ok(src)) = (
        std::env::var("FUSHI_IMPORT_CHILD_DB"),
        std::env::var("FUSHI_IMPORT_CHILD_SRC"),
    ) else {
        return;
    };
    let bytes = std::fs::read(&src).unwrap();
    let conn = open(Path::new(&db)).unwrap();
    let col: i64 = conn
        .query_row("SELECT col FROM self_", [], |r| r.get(0))
        .unwrap();
    let t = Truth::new(&conn);
    conn.execute_batch("BEGIN IMMEDIATE").unwrap();
    t.reset();
    let got = import_ops(&t, col, &bytes).unwrap();
    println!(
        "IMPORT_CHILD landed {} slots {}, exiting without commit",
        got.native_landed, got.slots_inserted
    );
    std::process::exit(0);
}

/// 导入中途进程没了：库里一条都没落（真相、派生、公钥）；重来一次落全，再来一次什么都不改——不会重复。
#[test]
fn an_import_killed_midway_lands_nothing_and_the_retry_lands_once() {
    let (a_dev, _, _) = pair();
    let ca = open_in_memory().unwrap();
    let ta = Truth::new(&ca);
    let col_a = library(&ta, ME_A, &a_dev);
    let bytes = export(&ta, col_a);
    let dir = tempdir::new("gen4-import-crash");
    let db = dir.0.join("srs4.db");
    let src = dir.0.join("ops.bin");
    std::fs::write(&src, &bytes).unwrap();
    let col_b = {
        let conn = open(&db).unwrap();
        fresh(&Truth::new(&conn), ME_B)
    };
    let before = {
        let conn = open(&db).unwrap();
        (ops_rows(&conn), dump(&conn, col_b))
    };
    let out = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "store::gen4::import::import_tests::import_child_process_half",
            "--nocapture",
            "--test-threads=1",
        ])
        .env("FUSHI_IMPORT_CHILD_DB", &db)
        .env("FUSHI_IMPORT_CHILD_SRC", &src)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "{stdout}");
    // PEER 的 1、4、7 与 A 本机的两条。
    assert!(stdout.contains("IMPORT_CHILD landed 5 slots"), "{stdout}");
    let conn = open(&db).unwrap();
    let t = Truth::new(&conn);
    assert_eq!((ops_rows(&conn), dump(&conn, col_b)), before);
    assert_eq!(t.tx(|t| t.audit(col_b)), Ok(0));
    let got = import_ops(&t, col_b, &bytes).unwrap();
    assert_eq!(got.native_landed, 5);
    let landed = (ops_rows(&conn), dump(&conn, col_b));
    let again = import_ops(&t, col_b, &bytes).unwrap();
    assert!(again.unchanged(), "{again:?}");
    assert_eq!((ops_rows(&conn), dump(&conn, col_b)), landed);
    assert_eq!(rows(&t, col_b), rows(&ta, col_a));
    assert_eq!(export(&t, col_b), bytes);
}

/// 在调用方的事务里导入、调用方回滚：同样一条都不落（导入嵌进去是一个保存点，不自己提交）。
#[test]
fn an_import_inside_a_rolled_back_transaction_leaves_nothing() {
    let (a_dev, _, _) = pair();
    let ca = open_in_memory().unwrap();
    let ta = Truth::new(&ca);
    let col_a = library(&ta, ME_A, &a_dev);
    let bytes = export(&ta, col_a);
    let cb = open_in_memory().unwrap();
    let tb = Truth::new(&cb);
    let col_b = fresh(&tb, ME_B);
    let before = ops_rows(&cb);
    let e = tb
        .tx(|t| {
            import_ops(t, col_b, &bytes)?;
            Err::<(), String>("caller gave up".into())
        })
        .unwrap_err();
    assert_eq!(e, "caller gave up");
    assert_eq!(ops_rows(&cb), before);
    assert_eq!(tb.tx(|t| t.audit(col_b)), Ok(0));
}

// ------------------------------------------------------------ 拒绝

/// 不认识 / 截断 / 坏 / 带尾巴 / 另一代 / 另一个集合的文件：可读的错误，一条都不落。
#[test]
fn unreadable_or_foreign_files_are_refused_and_nothing_lands() {
    let (a_dev, _, _) = pair();
    let ca = open_in_memory().unwrap();
    let ta = Truth::new(&ca);
    let col_a = library(&ta, ME_A, &a_dev);
    let bytes = export(&ta, col_a);
    let v1 = a_dev.core.sync2_export(P).unwrap();
    let cb = open_in_memory().unwrap();
    let tb = Truth::new(&cb);
    let col_b = fresh(&tb, ME_B);
    let before = ops_rows(&cb);
    let mut trailing = bytes.clone();
    trailing.extend_from_slice(&zstd::encode_all(&b"more"[..], 3).unwrap());
    let mut flipped = zstd::decode_all(&bytes[..]).unwrap();
    let last = flipped.len() - 1;
    flipped[last] ^= 0xff;
    let flipped = zstd::encode_all(&flipped[..], 3).unwrap();
    let cases: Vec<(&str, Vec<u8>, &str)> = vec![
        (
            "garbage",
            b"definitely not zstd".to_vec(),
            "not a Fushi SRS export",
        ),
        ("empty", Vec::new(), "not a Fushi SRS export"),
        (
            "other magic",
            zstd::encode_all(&b"SQLite format 3\0"[..], 3).unwrap(),
            "not a Fushi SRS export",
        ),
        (
            "truncated",
            bytes[..bytes.len() / 2].to_vec(),
            "gen4 import:",
        ),
        ("trailing frame", trailing, "corrupt export"),
        ("tail chain flipped", flipped, "corrupt export"),
        ("version 1 stream", v1.clone(), "version 1"),
    ];
    for (what, data, want) in cases {
        let e = import_ops(&tb, col_b, &data).unwrap_err();
        assert!(e.contains(want), "{what}: {e}");
        assert_eq!(ops_rows(&cb), before, "{what}");
    }
    // 第 1 版的读入口收到第 2 版的流 / 垃圾。
    let e = import_v1(&tb, col_b, &bytes).unwrap_err();
    assert!(e.contains("version 2"), "{e}");
    let e = import_v1(&tb, col_b, b"junk").unwrap_err();
    assert!(e.contains("not a Fushi SRS export"), "{e}");
    let mut cut = v1.clone();
    cut.truncate(v1.len() * 2 / 3);
    let e = import_v1(&tb, col_b, &cut).unwrap_err();
    assert!(e.starts_with("gen4 import:"), "{e}");
    assert_eq!(ops_rows(&cb), before);

    // 另一个集合：两种流都拒。
    let cc = open_in_memory().unwrap();
    let tc = Truth::new(&cc);
    let col_c = tc.tx(|t| t.bind(P, &id(0x99), "elsewhere")).unwrap();
    let e = import_ops(&tc, col_c, &bytes).unwrap_err();
    assert!(e.contains("another collection"), "{e}");
    let e = import_v1(&tc, col_c, &v1).unwrap_err();
    assert!(e.contains("another collection"), "{e}");
    assert_eq!(ops_rows(&cc), 0);
    // 没绑过的集合。
    let e = import_ops(&tc, col_c + 1, &bytes).unwrap_err();
    assert!(e.contains("no collection"), "{e}");
}

/// 文件里某台设备的原生日志与本机记的分叉了（克隆 / 回滚过的设备）：整个导入拒绝，一条都不落。
#[test]
fn a_native_log_that_diverges_from_the_library_refuses_the_whole_import() {
    let (a_dev, _, _) = pair();
    let ca = open_in_memory().unwrap();
    let ta = Truth::new(&ca);
    let col_a = library(&ta, ME_A, &a_dev);
    let bytes = export(&ta, col_a);
    let cb = open_in_memory().unwrap();
    let tb = Truth::new(&cb);
    let col_b = fresh(&tb, ME_B);
    // B 收到的 PEER 第 1 条与 A 的不同。
    tb.tx(|t| {
        t.append_native(col_b, &op(PEER, 1, NOW + 1, &[], &edit("another branch")))
            .map(|_| ())
    })
    .unwrap();
    let before = ops_rows(&cb);
    let e = import_ops(&tb, col_b, &bytes).unwrap_err();
    assert!(e.contains("diverges") && e.contains("seq 1"), "{e}");
    assert_eq!(ops_rows(&cb), before);
    assert_eq!(tb.tx(|t| t.audit(col_b)), Ok(1));
    // 会话没有毒化：之后照常写。
    tb.tx(|t| {
        let mut ix = Index::new(t, col_b);
        Native::open(t, col_b)?.write(&mut ix, edit("still fine"), NOW + 5)?;
        ingest_settle(t, &mut ix, col_b, Settle::Incremental).map(|_| ())
    })
    .unwrap();
}

/// 文件说某台设备是另一个公钥（本机已记过别的 / 冒充本机身份）：整个导入拒绝。
#[test]
fn a_device_key_that_contradicts_the_library_refuses_the_whole_import() {
    let (a_dev, _, _) = pair();
    let ca = open_in_memory().unwrap();
    let ta = Truth::new(&ca);
    let col_a = library(&ta, ME_A, &a_dev);
    let bytes = export(&ta, col_a);
    let cb = open_in_memory().unwrap();
    let tb = Truth::new(&cb);
    let col_b = fresh(&tb, ME_B);
    tb.tx(|t| {
        t.set_peer(
            col_b,
            &Peer {
                device: id(PEER),
                public: [0x55; 32],
                name: None,
                ext: None,
                head_gen: None,
                first_seen: None,
            },
        )
        .map(|_| ())
    })
    .unwrap();
    let before = ops_rows(&cb);
    let e = import_ops(&tb, col_b, &bytes).unwrap_err();
    assert!(e.contains("another public key"), "{e}");
    assert_eq!(ops_rows(&cb), before);
    // 本机身份就是 A（同一个设备 ID、另一把钥匙）：同样拒绝。
    let cc = open_in_memory().unwrap();
    let tc = Truth::new(&cc);
    let col_c = tc.tx(|t| t.bind(P, &collection_of(P), P)).unwrap();
    tc.tx(|t| t.create_self(col_c, &id(ME_A), &[0x42; 32], None, NOW))
        .unwrap();
    let e = import_ops(&tc, col_c, &bytes).unwrap_err();
    assert!(e.contains("another public key for this device"), "{e}");
}

// ------------------------------------------------------------ 协议 3 的输入

/// 迁移灌入同一台协议 3 设备的库、带上设备公钥与名字（迁移 `carry.rs` 的那一步）、再收好派生层（对照组）。
fn migrated(d: &Device, me: u8) -> (Connection, i64) {
    let conn = open_in_memory().unwrap();
    let col = {
        let t = Truth::new(&conn);
        let col = fresh(&t, me);
        let w = d.core.writer().unwrap();
        import_legacy(&w, P, &t, col, 1000).unwrap();
        t.tx(|t| {
            let mut carried = crate::store::gen4::carry::Carried::default();
            crate::store::gen4::carry::peers(&w, t, col, P, &mut carried)?;
            assert!(carried.peers >= 2, "{carried:?}");
            ingest_settle(t, &mut Index::new(t, col), col, Settle::Rebuild).map(|_| ())
        })
        .unwrap();
        col
    };
    (conn, col)
}

/// `peers` 逐行（设备、公钥、名字、扩展信息），按设备排。
fn peer_lines(conn: &Connection, col: i64) -> Vec<String> {
    conn.prepare(
        "SELECT hex(device), hex(public), name, ext FROM peers WHERE col = ?1 ORDER BY device",
    )
    .unwrap()
    .query_map([col], |r| {
        Ok(format!(
            "{} {} {:?} {:?}",
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, Option<String>>(2)?,
            r.get::<_, Option<String>>(3)?
        ))
    })
    .unwrap()
    .collect::<Result<_, _>>()
    .unwrap()
}

/// `.fushisrs` 第 1 版：读入后与直接迁移同一台设备的库逐字节相同（导出流相同、派生表逐行相同）；再导一遍什么都不改。
#[test]
fn a_protocol_3_export_lands_exactly_like_the_migration() {
    let (a_dev, _, mut bucket) = pair();
    // 再写一点、清除一条：第 1 版包里有已清除内容的骨架。
    a_dev
        .core
        .sync2_purge(P, "note", "N1", T0 + 2 * DAY)
        .unwrap();
    a_dev.sync(&mut bucket, "loc", T0 + 2 * DAY);
    let v1 = a_dev.core.sync2_export(P).unwrap();
    let (cx, col_x) = migrated(&a_dev, ME_A);
    let tx = Truth::new(&cx);

    let cy = open_in_memory().unwrap();
    let ty = Truth::new(&cy);
    let col_y = fresh(&ty, ME_A);
    let got = import_v1(&ty, col_y, &v1).unwrap();
    assert!(got.slots_inserted > 0 && got.heritage_logs >= 2, "{got:?}");
    assert_eq!(export(&ty, col_y), export(&tx, col_x));
    assert_eq!(rows(&ty, col_y), rows(&tx, col_x));
    assert_eq!(truth_lines(&ty, col_y), truth_lines(&tx, col_x));
    let again = import_v1(&ty, col_y, &v1).unwrap();
    assert!(again.unchanged(), "{again:?}");
    assert_eq!(rows(&ty, col_y), rows(&tx, col_x));
    // 第 1 版包带的公钥与迁移带的相同（名字第 1 版包里没有）。
    let keys = |c: &Connection, col: i64| -> Vec<String> {
        peer_lines(c, col)
            .into_iter()
            .map(|l| l.split(' ').take(2).collect::<Vec<_>>().join(" "))
            .collect()
    };
    assert_eq!(keys(&cy, col_y), keys(&cx, col_x));
    // 进迁移出来的库（已经有这些槽、这些公钥）：全是已有，什么都不改。
    let peers_x = peer_lines(&cx, col_x);
    let into_x = import_v1(&tx, col_x, &v1).unwrap();
    assert!(into_x.unchanged() && into_x.slots_same > 0, "{into_x:?}");
    assert_eq!(peer_lines(&cx, col_x), peers_x);
    assert_eq!(rows(&tx, col_x), rows(&ty, col_y));

    // 同一个集合在另一个旧 uid 下：先把那个 uid 写成盐（adopt_foreign 的 SaltsAdded 一路），才收。
    let cz = open_in_memory().unwrap();
    let tz = Truth::new(&cz);
    let col_z = tz.tx(|t| t.bind("p-new", &id(0x77), "dir-new")).unwrap();
    let e = import_v1(&tz, col_z, &v1).unwrap_err();
    assert!(e.contains("another collection"), "{e}");
    tz.tx(|t| t.set_salts(col_z, &BTreeSet::from([P.to_owned()])))
        .unwrap();
    let got = import_v1(&tz, col_z, &v1).unwrap();
    assert!(got.slots_inserted > 0, "{got:?}");
}

/// 旧备份（协议 3 的快照：剥掉了 `sync2_self` 与待投递）：没备好的明确拒绝、一条不落；用冻结代码在临时副本上备好之后，
/// 读入结果与直接迁移原库逐字节相同，卡片与复习记录一条不少；再读一遍什么都不改。
#[test]
fn an_old_backup_lands_exactly_like_the_migration_once_prepared() {
    let (a_dev, _, _) = pair();
    let dir = tempdir::new("gen4-import-backup");
    let snap = dir.0.join("srs.db");
    a_dev.core.snapshot_into(&snap, true).unwrap();
    let (cx, col_x) = migrated(&a_dev, ME_A);
    let tx = Truth::new(&cx);

    let cy = open_in_memory().unwrap();
    let ty = Truth::new(&cy);
    // 与对照组同一个本机身份（本机身份自己也在 `peers` 里），`peers` 才能逐行比。
    let col_y = fresh(&ty, ME_A);
    let empty = ops_rows(&cy);
    {
        let raw = crate::store::gen4::dryrun::open_legacy(&snap).unwrap();
        let e = import_backup(&raw, P, &ty, col_y).unwrap_err();
        assert!(e.contains("not ready") && e.contains("sync2_self"), "{e}");
        assert_eq!(ops_rows(&cy), empty);
    }
    // 冻结代码在临时副本上备好（G7-6 的 open_legacy_scratch 做的事）：开库（schema 阶梯）、补本机身份、旧事件包成操作。
    let core = crate::store::SrsCore::open(&snap).unwrap();
    core.sync2_identity(P, T0 + 5 * DAY).unwrap();
    while core.sync2_migrate(P, T0 + 5 * DAY, None).unwrap()["done"] != json!(true) {}
    let w = core.writer().unwrap();
    let got = import_backup(&w, P, &ty, col_y).unwrap();
    assert!(got.inserted > 0, "{got:?}");
    // 备好的副本只多了一个没有操作的新身份：读入的就是原库的全部操作。
    assert_eq!(truth_lines(&ty, col_y), truth_lines(&tx, col_x));
    assert_eq!(rows(&ty, col_y), rows(&tx, col_x));
    // 设备公钥与名字：与迁移带过去的逐行相同（协议 3 段收段要用公钥）；备副本时现补的临时身份不带。
    let peers = peer_lines(&cy, col_y);
    assert_eq!(peers, peer_lines(&cx, col_x));
    // 本机身份那一行是建身份时记的，其余都是这次读入记下的。
    assert_eq!(got.peers, peers.len() as u64 - 1);
    let again = import_backup(&w, P, &ty, col_y).unwrap();
    assert_eq!((again.inserted, again.same), (0, got.inserted));
    assert_eq!(again.peers, 0);
    assert_eq!(rows(&ty, col_y), rows(&tx, col_x));
    assert_eq!(peer_lines(&cy, col_y), peers);
    // 另一个集合的备份：拒。
    let cz = open_in_memory().unwrap();
    let tz = Truth::new(&cz);
    let col_z = tz.tx(|t| t.bind("p-new", &id(0x77), "dir-new")).unwrap();
    let e = import_backup(&w, P, &tz, col_z).unwrap_err();
    assert!(e.contains("another collection"), "{e}");
    assert_eq!(ops_rows(&cz), 0);
}

/// 旧备份里的「待确认 / 已拒绝」只带给本机从没见过的设备；本机已有决定的不改。
#[test]
fn backup_trust_only_reaches_devices_this_library_has_never_seen() {
    let (a_dev, _, _) = pair();
    let devices = {
        let w = a_dev.core.writer().unwrap();
        crate::store::gen4::legacy::devices(&w, P).unwrap()
    };
    assert!(devices.len() >= 2);
    let (seen, unseen) = (devices[0].device, devices[1].device);
    {
        let w = a_dev.core.writer().unwrap();
        for d in [seen, unseen] {
            w.execute(
                "INSERT OR REPLACE INTO sync2_trust (profile_uid, device, state, since) VALUES (srs_id(?1), ?2, 2, 5)",
                rusqlite::params![P, d.0.to_vec()],
            )
            .unwrap();
        }
    }
    let cy = open_in_memory().unwrap();
    let ty = Truth::new(&cy);
    let col_y = fresh(&ty, ME_B);
    // 本机已经见过 [seen]（有它的承袭日志、信任它）。
    {
        let w = a_dev.core.writer().unwrap();
        import_legacy(&w, P, &ty, col_y, 1000).unwrap();
    }
    ty.tx(|t| t.set_trust(col_y, &seen, None, 0)).unwrap();
    ty.tx(|t| t.set_trust(col_y, &unseen, None, 0)).unwrap();
    let cz = open_in_memory().unwrap();
    let tz = Truth::new(&cz);
    let col_z = fresh(&tz, ME_B);
    // 只见过 [seen] 的信任决定（待确认），没有它的日志。
    tz.tx(|t| {
        t.set_trust(
            col_z,
            &seen,
            Some(crate::store::gen4::truth::TRUST_PENDING),
            1,
        )
    })
    .unwrap();
    let w = a_dev.core.writer().unwrap();
    let got = import_backup(&w, P, &tz, col_z).unwrap();
    assert_eq!(got.untrusted, 1);
    assert_eq!(
        tz.trust_of(col_z, &seen).unwrap(),
        Some(crate::store::gen4::truth::TRUST_PENDING)
    );
    assert_eq!(
        tz.trust_of(col_z, &unseen).unwrap(),
        Some(crate::store::gen4::truth::TRUST_REJECTED)
    );
    // 已有日志的设备（col_y 里两台都有）：备份里的拒绝一条都不带。
    let got = import_backup(&w, P, &ty, col_y).unwrap();
    assert_eq!(got.untrusted, 0);
    assert_eq!(ty.trust_of(col_y, &unseen).unwrap(), None);
}

/// 旧备份里的设备公钥：本机已记过另一个公钥、或文件说本机当前身份是另一个公钥——整个读入拒绝、一条不落；本机已有的
/// 名字不拿备份里的旧名字盖，空缺的才补。
#[test]
fn backup_device_keys_refuse_contradictions_and_keep_local_names() {
    let (a_dev, _, _) = pair();
    let w = a_dev.core.writer().unwrap();
    let (legacy, _) = crate::store::gen4::carry::legacy_peers(&w, P).unwrap();
    assert!(legacy.len() >= 2, "{legacy:?}");
    let (first, second) = (&legacy[0], &legacy[1]);
    let with_key = |device: Id, public: [u8; 32], name: Option<&str>| Peer {
        device,
        public,
        name: name.map(str::to_owned),
        ext: None,
        head_gen: None,
        first_seen: None,
    };

    // 本机已记过 [first] 的另一个公钥。
    let cz = open_in_memory().unwrap();
    let tz = Truth::new(&cz);
    let col_z = fresh(&tz, ME_B);
    tz.tx(|t| t.set_peer(col_z, &with_key(first.device, [0x55; 32], None)))
        .unwrap();
    let before = (ops_rows(&cz), peer_lines(&cz, col_z));
    let e = import_backup(&w, P, &tz, col_z).unwrap_err();
    assert!(e.contains("another public key"), "{e}");
    assert_eq!((ops_rows(&cz), peer_lines(&cz, col_z)), before);

    // 本机当前身份就是 [first] 的设备 ID、另一把钥匙。
    let cs = open_in_memory().unwrap();
    let ts = Truth::new(&cs);
    let col_s = ts.tx(|t| t.bind(P, &collection_of(P), P)).unwrap();
    ts.tx(|t| t.create_self(col_s, &first.device, &[0x42; 32], None, NOW))
        .unwrap();
    let before = ops_rows(&cs);
    let e = import_backup(&w, P, &ts, col_s).unwrap_err();
    assert!(e.contains("another public key for this device"), "{e}");
    assert_eq!(ops_rows(&cs), before);

    // 本机已知 [first]（同一个公钥、本机后来学到的名字）：名字留本机的；[second] 照备份补上。
    let cn = open_in_memory().unwrap();
    let tn = Truth::new(&cn);
    let col_n = fresh(&tn, ME_B);
    tn.tx(|t| {
        t.set_peer(
            col_n,
            &with_key(first.device, first.public, Some("renamed here")),
        )
    })
    .unwrap();
    let got = import_backup(&w, P, &tn, col_n).unwrap();
    assert_eq!(got.peers, legacy.len() as u64 - 1);
    let kept = tn.peer(col_n, &first.device).unwrap().unwrap();
    assert_eq!(kept.name.as_deref(), Some("renamed here"));
    assert_eq!(
        tn.peer(col_n, &second.device).unwrap().as_ref(),
        Some(second)
    );
}

/// PEER 的完整原生日志 1..=7，其中第 [diverge_at] 条（有的话）换成另一份内容，落进 [col]。
fn full_peer_log(t: &Truth<'_>, col: i64, diverge_at: Option<u64>) {
    t.tx(|t| {
        for (i, o) in peer_ops().iter().enumerate() {
            let seq = i as u64 + 1;
            if Some(seq) == diverge_at {
                t.append_native(
                    col,
                    &op(PEER, seq, NOW + seq as i64, &[], &edit("another branch")),
                )?;
            } else {
                t.append_native(col, o)?;
            }
        }
        Ok(())
    })
    .unwrap();
}

/// 文件里的原生日志不比本机长、在中间分叉了（本机收全了 1..=7，第 3 条与文件的不同）：逐格比链值拦下，一条不落。
#[test]
fn a_native_log_diverging_in_the_middle_of_what_is_already_here_is_refused() {
    let cs = open_in_memory().unwrap();
    let ts = Truth::new(&cs);
    let col_s = fresh(&ts, ME_A);
    full_peer_log(&ts, col_s, None);
    let bytes = export(&ts, col_s);
    let cb = open_in_memory().unwrap();
    let tb = Truth::new(&cb);
    let col_b = fresh(&tb, ME_B);
    full_peer_log(&tb, col_b, Some(3));
    let before = (ops_rows(&cb), dump(&cb, col_b));
    let e = import_ops(&tb, col_b, &bytes).unwrap_err();
    assert!(e.contains("diverges") && e.contains("seq 3"), "{e}");
    assert_eq!((ops_rows(&cb), dump(&cb, col_b)), before);
    // 同一条日志没分叉时：全是已有，什么都不改。
    let cc = open_in_memory().unwrap();
    let tc = Truth::new(&cc);
    let col_c = fresh(&tc, ME_B);
    full_peer_log(&tc, col_c, None);
    let got = import_ops(&tc, col_c, &bytes).unwrap();
    assert_eq!(got.native_known, 7);
    assert_eq!(got.native_landed, 0);
}

/// 文件里的空洞（PEER 的 2..=3）末尾落在本机日志之内、区间末的链值与本机的不等（本机第 3 条不同）：在空洞那一格就拦下
/// （报 seq 3，不是等到下一条操作才发现），一条不落。
#[test]
fn a_void_whose_end_disagrees_with_the_local_log_is_refused_at_that_seq() {
    let (a_dev, _, _) = pair();
    let ca = open_in_memory().unwrap();
    let ta = Truth::new(&ca);
    let col_a = library(&ta, ME_A, &a_dev);
    let bytes = export(&ta, col_a);
    let cb = open_in_memory().unwrap();
    let tb = Truth::new(&cb);
    let col_b = fresh(&tb, ME_B);
    full_peer_log(&tb, col_b, Some(3));
    let before = (ops_rows(&cb), dump(&cb, col_b));
    let e = import_ops(&tb, col_b, &bytes).unwrap_err();
    assert!(e.contains("diverges") && e.contains("seq 3"), "{e}");
    assert_eq!((ops_rows(&cb), dump(&cb, col_b)), before);
}

/// 别的连接正拿着写锁、写完之后才提交：在事务外调的导入一开始就排队拿写锁，等它提交完再读、再写，成功；不会读完本机
/// 状态再升级成写时撞上 `SQLITE_BUSY_SNAPSHOT` 整笔失败。两边写的都在。
#[test]
fn an_import_waits_for_a_concurrent_writer_instead_of_failing_busy() {
    let (a_dev, _, _) = pair();
    let ca = open_in_memory().unwrap();
    let ta = Truth::new(&ca);
    let col_a = library(&ta, ME_A, &a_dev);
    let bytes = export(&ta, col_a);
    let dir = tempdir::new("gen4-import-busy");
    let db = dir.0.join("srs4.db");
    let col_b = {
        let conn = open(&db).unwrap();
        fresh(&Truth::new(&conn), ME_B)
    };
    // 先开好（打开本身也要拿写锁）。
    let conn = open(&db).unwrap();
    let t = Truth::new(&conn);
    let stranger = id(0x99);
    let (locked_tx, locked_rx) = std::sync::mpsc::channel::<()>();
    let holder = {
        let db = db.clone();
        std::thread::spawn(move || {
            let conn = open(&db).unwrap();
            conn.execute_batch("BEGIN IMMEDIATE").unwrap();
            let t = Truth::new(&conn);
            t.reset();
            t.set_trust(
                col_b,
                &stranger,
                Some(crate::store::gen4::truth::TRUST_PENDING),
                7,
            )
            .unwrap();
            locked_tx.send(()).unwrap();
            std::thread::sleep(std::time::Duration::from_millis(400));
            conn.execute_batch("COMMIT").unwrap();
        })
    };
    locked_rx.recv().unwrap();
    let got = import_ops(&t, col_b, &bytes);
    holder.join().unwrap();
    let got = got.unwrap();
    assert_eq!(got.native_landed, 5);
    assert_eq!(
        t.trust_of(col_b, &stranger).unwrap(),
        Some(crate::store::gen4::truth::TRUST_PENDING)
    );
    assert_eq!(rows(&t, col_b), rows(&ta, col_a));
}
