//! 把一份协议 3 的库的操作日志灌进新代库的真相层（设计 §6.1 的「转译 + 落库」那一步的存储部分）。
//!
//! 旧库只读（`legacy.rs` 的读入器逐条验链、逐条转译），新库这边：
//!
//! - 已应用的操作 → 承袭日志的槽（[Truth::put_heritage]）；每 [HERITAGE_MARK_EVERY] 条与末尾各记一个完整原链值，
//!   之后切承袭段要用（段头带区间首尾的完整原链值）。
//! - 待投递的操作 → 待投递的槽（[Truth::put_pending]）。能在协议 3 的口径下验出「紧接在上一条之后」的带上前一环的
//!   链指纹（之后可以按链指纹核对着投递），验不出的不带（等同号的槽经承袭段到达再确认）——这是协议 3 「投递时才核对
//!   链值」在过界之后的落点（设计 §10 第 12 条）。
//!
//! 本机状态里只有设备信任跟着过来（`sync2_trust` → `trust`）：哪些删除与清除不执行由它定，丢了它迁移前后的投影就
//! 不一样。
//!
//! 这里只建真相；派生表由 `rebuild_all` 从真相建。整个过程可重放：同一份旧库再灌一遍，每个槽都是「已有」。
//! 迁移流程本身（备份、对拍、切换文件）是 G7 的事。

use rusqlite::Connection;

use super::legacy::{self, Placement};
use super::schema::sql;
use super::truth::{Put, Truth};
use crate::gen4::heritage::{SlotBody, fingerprint};
use crate::gen4::translate::{T_VERSION, translate};
use crate::store::sync2::collection_of;
use crate::sync2::segment::{CHAIN_ZERO, Chain, chain_next};

/// 承袭日志每隔这么多条记一个完整原链值。
pub const HERITAGE_MARK_EVERY: u64 = 4096;

/// 一次灌入的计数。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Imported {
    pub devices: u64,
    /// 旧库里已应用的操作数。
    pub applied: u64,
    /// 旧库里待投递的操作数（不含与已应用同号同链值的残留行）。
    pub pending: u64,
    /// 其中验得出前一环的。
    pub pending_linked: u64,
    /// 转出的槽，按形态。
    pub ops: u64,
    pub raw: u64,
    pub alias: u64,
    pub voids: u64,
    /// 落库的结果，按 [Put]。
    pub inserted: u64,
    pub same: u64,
    pub kept: u64,
    pub replaced: u64,
    pub forks: u64,
    pub parked: u64,
    /// 带过来的「还没信任的设备」。
    pub untrusted: u64,
}

/// 把 [profile] 在旧库 [src] 里的全部操作灌进 [truth] 的集合 [col]。[batch] 条提交一次（不能在事务里调）。
///
/// 出错时当前这一批回滚、已提交的批留着（重跑会接着来，已有的槽幂等）。
pub fn import_legacy(
    src: &Connection,
    profile: &str,
    truth: &Truth<'_>,
    col: i64,
    batch: u64,
) -> Result<Imported, String> {
    let dst = truth.conn();
    if !dst.is_autocommit() {
        return Err("gen4 import: must not run inside a transaction".to_owned());
    }
    let blockers = legacy::preflight(src, profile)?;
    if !blockers.is_empty() {
        return Err(format!(
            "gen4 import: the legacy library is not ready: {}",
            blockers.join("; ")
        ));
    }
    let source = collection_of(profile);
    let mut out = Imported::default();
    dst.execute_batch("BEGIN IMMEDIATE").map_err(sql)?;
    let done = (|| -> Result<(), String> {
        let mut in_batch = 0u64;
        for d in legacy::devices(src, profile)? {
            out.devices += 1;
            // 上一条读到的操作与它的链值（验「紧接在上一条之后」用）；链的起点是 seq 0、全零。
            let mut prev: (u64, Chain) = (0, CHAIN_ZERO);
            let mut tail: Option<(u64, Chain)> = None;
            legacy::for_each_op(src, profile, &d.device, |op, chain, placement| {
                let slot = translate(op, chain)
                    .map_err(|m| format!("gen4 import: {}:{} {m}", op.id.device, op.id.seq))?;
                match &slot.body {
                    SlotBody::Op(_) => out.ops += 1,
                    SlotBody::Raw3(_) => out.raw += 1,
                    SlotBody::Alias(_) => out.alias += 1,
                    SlotBody::Void => out.voids += 1,
                }
                let put = match placement {
                    Placement::Applied => {
                        out.applied += 1;
                        let put = truth.put_heritage(col, &source, &slot, T_VERSION)?;
                        if !matches!(put, Put::Fork | Put::Yielded) {
                            if op.id.seq % HERITAGE_MARK_EVERY == 0 {
                                truth.set_mark(col, &d.device, op.id.seq, chain)?;
                            }
                            tail = Some((op.id.seq, *chain));
                        }
                        put
                    }
                    Placement::Pending => {
                        out.pending += 1;
                        let linked = (prev.0 + 1 == op.id.seq && chain_next(&prev.1, op) == *chain)
                            .then(|| fingerprint(&prev.1));
                        if linked.is_some() {
                            out.pending_linked += 1;
                        }
                        truth.put_pending(col, &source, &slot, T_VERSION, linked)?
                    }
                };
                prev = (op.id.seq, *chain);
                match put {
                    Put::Inserted => out.inserted += 1,
                    Put::Same => out.same += 1,
                    Put::Kept => out.kept += 1,
                    Put::Replaced => out.replaced += 1,
                    Put::Fork | Put::Yielded => out.forks += 1,
                    Put::Pending => out.parked += 1,
                }
                in_batch += 1;
                if in_batch >= batch.max(1) {
                    dst.execute_batch("COMMIT; BEGIN IMMEDIATE").map_err(sql)?;
                    in_batch = 0;
                }
                Ok(())
            })?;
            if let Some((seq, chain)) = tail {
                // 末尾那一条若让位给了分叉的另一支（同号、链指纹更小的待投递槽），这个链值就不是日志里那一条的：不记。
                let id = crate::sync2::vv::OpId {
                    device: d.device,
                    seq,
                };
                let fp = truth.entry(col, &id)?.and_then(|e| e.fp);
                if fp == Some(fingerprint(&chain)) {
                    truth.set_mark(col, &d.device, seq, &chain)?;
                }
            }
        }
        for (device, state, since) in legacy::untrusted(src, profile)? {
            truth.set_trust(col, &device, Some(state), since)?;
            out.untrusted += 1;
        }
        Ok(())
    })();
    match done {
        Ok(()) => {
            dst.execute_batch("COMMIT").map_err(sql)?;
            Ok(out)
        }
        Err(e) => {
            let _ = dst.execute_batch("ROLLBACK");
            truth.reset();
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use serde_json::{Value, json};

    use super::*;
    use crate::gen4::heritage::HeritageSlot;
    use crate::gen4::translate::SlotSet;
    use crate::store::gen4::legacy::tests::{
        T0, device, device_id, migrate, pair, peak_mem_mb, read_all, sample,
    };
    use crate::store::gen4::schema::{open, open_in_memory, table_bytes};
    use crate::store::sync2::tests::{Bucket, DAY, Device, P, edit, legacy_library, tempdir};
    use crate::sync2::id::Id;

    fn bind(t: &Truth<'_>) -> i64 {
        t.tx(|t| t.bind(P, &collection_of(P), P)).unwrap()
    }

    fn import(d: &Device, t: &Truth<'_>, col: i64, batch: u64) -> Result<Imported, String> {
        let w = d.core.writer().unwrap();
        import_legacy(&w, P, t, col, batch)
    }

    /// 新库里的全部槽（主支），并成集合。
    fn stored(t: &Truth<'_>, col: i64) -> SlotSet {
        let mut set = SlotSet::new();
        for d in t.devices(col).unwrap() {
            t.for_each(col, &d.id, 1, |e| {
                set.insert(e.slot().expect("heritage slot"))
                    .map_err(|e| e.to_string())
            })
            .unwrap();
        }
        set
    }

    #[test]
    fn a_legacy_library_lands_slot_for_slot_and_twice_is_once() {
        let (a, b, _) = pair();
        let (want, pending, _) = read_all(&a);
        assert!(pending.is_empty());
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bind(&t);
        // 批很小：中途提交过很多次。
        let got = import(&a, &t, col, 3).unwrap();
        assert_eq!(got.applied as usize, want.len());
        assert_eq!((got.inserted, got.same, got.pending), (got.applied, 0, 0));
        assert_eq!(got.ops + got.raw + got.alias + got.voids, got.applied);
        assert_eq!(stored(&t, col), want);
        assert_eq!(t.audit(col).unwrap(), got.applied);
        // 每条日志的末尾记了完整原链值，且与末尾那个槽的链指纹相符（set_mark 自己核对）。
        for d in t.devices(col).unwrap().iter().filter(|d| d.last > 0) {
            assert_eq!(d.src, Some(collection_of(P)));
            let marks = t.marks(col, &d.id).unwrap();
            assert_eq!(marks.last().map(|m| m.0), Some(d.last));
        }
        // 再灌一遍、把另一台收全了的设备的库也灌进来：全是「已有」。
        for d in [&a, &b] {
            let again = import(d, &Truth::new(&conn), col, 1000).unwrap();
            assert_eq!((again.inserted, again.same), (0, got.applied));
        }
        assert_eq!(stored(&Truth::new(&conn), col), want);
    }

    #[test]
    fn a_library_that_purged_does_not_take_content_away_from_one_that_has_not() {
        let (a, b, mut bucket) = pair();
        let (whole, _, _) = read_all(&b);
        a.core.sync2_purge(P, "note", "N1", T0 + 2 * DAY).unwrap();
        a.sync(&mut bucket, "loc", T0 + 2 * DAY);
        let (purged, _, _) = read_all(&a);
        assert_ne!(whole, purged);
        // 先灌没清除的（b），再灌清除过的（a）：b 有的操作号本机不动；a 多出来的（Purge 操作本身）接上。
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bind(&t);
        import(&b, &t, col, 1000).unwrap();
        let again = import(&a, &t, col, 1000).unwrap();
        assert!(again.kept > 0 && again.inserted > 0, "{again:?}");
        let got = stored(&t, col);
        for s in whole.iter() {
            assert!(got.iter().any(|x| x == s), "{:?} changed", s.id);
        }
        assert_eq!(got.len(), purged.len());
        // 反过来（本机还没有这些槽）：收什么留什么。
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bind(&t);
        import(&a, &t, col, 1000).unwrap();
        let again = import(&b, &t, col, 1000).unwrap();
        assert!(again.kept > 0 && again.inserted == 0, "{again:?}");
        assert_eq!(stored(&t, col), purged);
    }

    #[test]
    fn pending_ops_stay_pending_and_deliver_in_chain_order() {
        let (a, b) = (device(), device());
        let mut bucket = Bucket::default();
        for i in 0..6 {
            let at = T0 + i * 600_000;
            a.apply(at, vec![edit("note", "N1", "f/x", json!(format!("a{i}")))]);
            a.sync(&mut bucket, "loc", at);
            b.sync(&mut bucket, "loc", at);
            b.apply(
                at + 1,
                vec![edit("note", "N1", "f/x", json!(format!("b{i}")))],
            );
            b.sync(&mut bucket, "loc", at + 1);
            a.sync(&mut bucket, "loc", at + 1);
        }
        // 新设备只拿到 b 的段：b 的操作依赖 a 的，投不了，进待投递（与 legacy.rs 的同名情形相同）。
        let now = T0 + 9 * DAY;
        let c = device();
        c.core.sync2_identity(P, now).unwrap();
        let heads: Vec<Vec<u8>> = bucket
            .0
            .iter()
            .filter(|(k, _)| k.contains("/head-"))
            .map(|(_, v)| v.clone())
            .collect();
        let plan = c.core.sync2_plan(P, &heads).unwrap();
        let b_dev = device_id(&b);
        let files: Vec<Vec<u8>> = plan["fetch"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|f| f["files"].as_array().unwrap().iter())
            .map(|n| n.as_str().unwrap())
            .filter(|n| n.contains(&b_dev.text()))
            .map(|n| bucket.0[n].clone())
            .collect();
        let out: Value =
            serde_json::from_str(&c.core.sync2_ingest(P, &files, None, now).unwrap()).unwrap();
        let (_, pending, _) = read_all(&c);
        assert!(!pending.is_empty(), "{out}");

        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bind(&t);
        let got = import(&c, &t, col, 1000).unwrap();
        assert_eq!(got.pending as usize, pending.len());
        assert_eq!(got.parked, got.pending);
        // 它们从 b 的第一条起一条接一条，协议 3 的链逐条验得出。
        assert_eq!(got.pending_linked, got.pending);
        let parked = t.pending(col).unwrap();
        assert_eq!(
            parked
                .iter()
                .map(|p| p.slot.clone())
                .collect::<Vec<HeritageSlot>>(),
            pending
        );
        // 待投递的不在日志里；逐条按链指纹核对着投（因果上该不该投是同步轮的事，这里只验存储一侧接得上）。
        let mut delivered = 0;
        while let Some(p) = t.pending_ready(col, &b_dev).unwrap() {
            assert_eq!(
                t.tx(|t| t.put_heritage(col, &collection_of(P), &p.slot, p.tv)),
                Ok(Put::Inserted)
            );
            delivered += 1;
        }
        assert_eq!(delivered, pending.len());
        assert_eq!(t.pending(col).unwrap(), Vec::new());
        // 投完之后 b 的日志与 b 自己库里转出来的那一段逐槽相同。
        let (author, _, _) = read_all(&b);
        let mut mine = Vec::new();
        t.for_each(col, &b_dev, 1, |e| {
            mine.push(e.slot().unwrap());
            Ok(())
        })
        .unwrap();
        let theirs: Vec<HeritageSlot> = author
            .iter()
            .filter(|s| s.id.device == b_dev)
            .take(mine.len())
            .cloned()
            .collect();
        assert_eq!(mine, theirs);
        assert_eq!(t.audit(col).unwrap() as usize, mine.len());
    }

    #[test]
    fn a_library_that_is_not_fully_on_protocol_3_is_refused_and_nothing_lands() {
        // 还有旧事件没包成操作的库过不了 preflight。
        let d = Device::new("g6raw");
        legacy_library(&d);
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bind(&t);
        {
            let w = d.core.writer().unwrap();
            let e = import_legacy(&w, P, &t, col, 100).unwrap_err();
            assert!(e.contains("not ready"), "{e}");
            assert_eq!(t.devices(col).unwrap(), Vec::new());
            // 在事务里调也拒绝。
            let e = t.tx(|t| import_legacy(&w, P, t, col, 100)).unwrap_err();
            assert!(e.contains("inside a transaction"), "{e}");
        }
        // 在旧代码上把迁移与去重作业做完之后就能灌：迁移出来的旧修改带旧戳，旧戳摘出来另存、读回逐字节相同。
        migrate(&d);
        for _ in 0..1000 {
            if d.core.sync2_dedup(P, T0).unwrap()["done"] == json!(true) {
                break;
            }
        }
        let (want, _, stats) = read_all(&d);
        assert!(stats.stamps >= 2, "{stats:?}");
        let got = import(&d, &t, col, 100).unwrap();
        assert_eq!(got.inserted as usize, want.len());
        assert_eq!(stored(&t, col), want);
        let stamped: i64 = conn
            .query_row(
                "SELECT (SELECT COUNT(*) FROM ops WHERE flags & 4) + (SELECT COUNT(*) FROM op_alias WHERE stamp IS NOT NULL)",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(stamped as u64, stats.stamps);
        assert!(
            conn.query_row("SELECT COUNT(*) FROM writers", [], |r| r.get::<_, i64>(0))
                .unwrap()
                > 0
        );
    }

    #[test]
    fn the_two_generations_refuse_each_others_files() {
        // 新代文件被协议 3 的内核当成自己的库打开：报「比本版本新」，文件里的表不变。
        let dir = tempdir::new("g6file");
        let path = dir.0.join("srs4.db");
        {
            let conn = open(&path).unwrap();
            let t = Truth::new(&conn);
            let col = bind(&t);
            let (a, _, _) = pair();
            import(&a, &t, col, 1000).unwrap();
        }
        let tables = |p: &std::path::Path| -> Vec<String> {
            let c = Connection::open(p).unwrap();
            let mut stmt = c
                .prepare("SELECT name FROM sqlite_schema ORDER BY name")
                .unwrap();
            let rows = stmt.query_map([], |r| r.get(0)).unwrap();
            rows.map(Result::unwrap).collect()
        };
        let before = tables(&path);
        let e = match crate::store::SrsCore::open(&path) {
            Ok(_) => panic!("the protocol 3 kernel opened a generation 4 file"),
            Err(e) => e,
        };
        assert!(e.contains("newer than this build"), "{e}");
        assert_eq!(tables(&path), before);
        let conn = open(&path).unwrap();
        let t = Truth::new(&conn);
        let col = t.binding_of(P).unwrap().unwrap().col;
        assert!(t.audit(col).unwrap() > 0);
        // 协议 3 的库被当成新代文件打开：拒绝，什么都不建。
        let old = Device::new("g6old");
        let old_path = old._dir.0.join("srs.db");
        let before = tables(&old_path);
        let e = open(&old_path).unwrap_err();
        assert!(e.contains("not a generation 4 library"), "{e}");
        assert_eq!(tables(&old_path), before);
    }

    /// 在真实库的私有拷贝上把全部旧操作灌进一个新代文件：体积（分表）、耗时、峰值内存，然后逐槽读回与转译结果比。
    ///
    /// `FUSHI_GEN4_SAMPLE_DB=<srs.db 的私有拷贝> [FUSHI_GEN4_OUT=<新文件放哪>] cargo test --release --lib gen4_sample_import -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn gen4_sample_import() {
        let Some(src) = sample() else {
            println!("FUSHI_GEN4_SAMPLE_DB not set");
            return;
        };
        let keep = std::env::var("FUSHI_GEN4_OUT").ok();
        let dir = tempdir::new("g6sample");
        let path = match &keep {
            Some(p) => std::path::PathBuf::from(p),
            None => dir.0.join("srs4.db"),
        };
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
        }
        let (ws0, commit0) = peak_mem_mb();
        println!("SAMPLE import start peak_working_set_mb {ws0:.0} peak_commit_mb {commit0:.0}");
        let dst = open(&path).unwrap();
        let t = Truth::new(&dst);
        let started = Instant::now();
        let mut cols = Vec::new();
        for profile in legacy::profiles(&src).unwrap() {
            let col = t
                .tx(|t| t.bind(&profile, &collection_of(&profile), &profile))
                .unwrap();
            let got = import_legacy(&src, &profile, &t, col, 20_000).unwrap();
            println!("SAMPLE import profile {profile} {got:?}");
            cols.push((profile, col, got));
        }
        let import_s = started.elapsed().as_secs_f64();
        let (ws1, commit1) = peak_mem_mb();
        dst.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
            .unwrap();
        let checkpoint_s = started.elapsed().as_secs_f64() - import_s;
        let file = std::fs::metadata(&path).unwrap().len();
        println!(
            "SAMPLE import elapsed_s {import_s:.1} checkpoint_s {checkpoint_s:.1} file_bytes {file} peak_working_set_mb {ws1:.0} peak_commit_mb {commit1:.0}"
        );
        for (name, bytes) in table_bytes(&dst) {
            println!("SAMPLE table {name} {bytes}");
        }
        for table in [
            "ops",
            "op_alias",
            "op_voids",
            "op_deps",
            "writers",
            "snapshots",
            "log_marks",
            "op_pending",
            "op_forks",
            "devs",
        ] {
            let n: i64 = dst
                .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
                .unwrap();
            println!("SAMPLE rows {table} {n}");
        }
        for (what, q) in [
            (
                "ops_zstd",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(body)), 0) FROM ops WHERE flags & 2",
            ),
            (
                "ops_stamp",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(aux)), 0) FROM ops WHERE flags & 4",
            ),
            (
                "ops_snap",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(aux)), 0) FROM ops WHERE flags & 8",
            ),
            (
                "ops_body",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(body)), 0) FROM ops",
            ),
            (
                "alias_stamp",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(stamp)), 0) FROM op_alias WHERE stamp IS NOT NULL",
            ),
            (
                "alias_stamp_wire",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(stamp)), 0) FROM op_alias WHERE flags & 2",
            ),
            (
                "writers",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(name)), 0) FROM writers",
            ),
            (
                "snapshots",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(body)), 0) FROM snapshots",
            ),
            (
                "deps",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(bytes)), 0) FROM op_deps",
            ),
        ] {
            let (n, bytes): (i64, i64) = dst
                .query_row(q, [], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap();
            println!("SAMPLE {what} rows {n} bytes {bytes}");
        }
        // 以下是探针自己的开销（核对），不是灌入的一部分：重新转译一遍，逐槽与新库里读出来的比。
        let started = Instant::now();
        let t = Truth::new(&dst);
        let (mut same, mut diff, mut parked_same) = (0u64, 0u64, 0u64);
        for (profile, col, got) in &cols {
            assert_eq!(t.audit(*col).unwrap(), got.applied);
            let parked = t.pending(*col).unwrap();
            for d in legacy::devices(&src, profile).unwrap() {
                let device: Id = d.device;
                legacy::for_each_op(&src, profile, &device, |op, chain, placement| {
                    let want = translate(op, chain).map_err(str::to_owned)?;
                    match placement {
                        Placement::Applied => {
                            let have = t.entry(*col, &want.id)?.and_then(|e| e.slot());
                            if have.as_ref().map(HeritageSlot::encode) == Some(want.encode()) {
                                same += 1;
                            } else {
                                diff += 1;
                            }
                        }
                        Placement::Pending => {
                            if parked.iter().any(|p| p.slot == want) {
                                parked_same += 1;
                            } else {
                                diff += 1;
                            }
                        }
                    }
                    Ok(())
                })
                .unwrap();
            }
        }
        let (ws2, commit2) = peak_mem_mb();
        println!(
            "SAMPLE verify slots_same {same} pending_same {parked_same} different {diff} elapsed_s {:.1} peak_working_set_mb {ws2:.0} peak_commit_mb {commit2:.0}",
            started.elapsed().as_secs_f64()
        );
        assert_eq!(diff, 0);
        if keep.is_some() {
            println!("SAMPLE kept {}", path.display());
        }
    }
}
