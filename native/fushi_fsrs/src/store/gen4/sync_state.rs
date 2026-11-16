//! 同步运行时的本机状态（规划 §1.3 的 G8-4 那几张表；表见 `schema.rs` 的 `SYNC`）：各位置上各设备最新的 head
//! （`loc_heads`）、本机转发到各位置的文件（`relay_out`）、各位置旧根的清单指纹（`oldroot_fp`）。原生操作的等待缓冲
//! `op_wait` 由收段（`receive.rs`）写，这里只给只读的 [Truth::waiting]。
//!
//! 这些都是「从头对账」的东西（D11）：迁移不带过来，丢了下一轮同步重新列一遍位置就回来，不影响集合内容。所以规则
//! 只求「不倒退、不丢待删的文件」，不求跨设备一致。
//!
//! # 规则
//!
//! - **head 只进不退**（[Truth::put_loc_head]）：同一个位置、同一台设备，代号更大且 seq 不倒退才换；代号相同、内容
//!   相同 = 已有；代号相同而内容不同、或代号更大而 seq 倒退 = [LocHeadPut::Conflict]（同一个作者在一个位置上的两份
//!   head 互相矛盾：作者分叉或位置被改过，交给身份分叉的检测 G8-6），什么都不写；代号更小 = 过时，不写。
//! - **转发两段式删除**（[Truth::relay_sent] / [Truth::relay_supersede] / [Truth::relay_deleted]）：被新转发取代的旧件先标成
//!   待删（`gone = 1`），调用方删掉位置上的文件、回报之后才去掉这一行；删到一半失败、崩溃，下一轮
//!   [Truth::relay_gone] 照样列出来再删。只能去掉待删的行：还在用的转发件不会被一次误报的「删好了」抹掉记账。
//!   同名的件又被转发一次（同名重写）就回到在用。
//! - **旧根指纹**（[Truth::set_oldroot_fp]）：只记最近一次核对的结果，调用方拿 [oldroot_fingerprint] 算出本轮的、与记下的
//!   比，不同就去捡漏（设计 §6.2 第 4 步）。指纹是清单的纯函数，与列出来的顺序无关；同名文件（Google Drive 允许）逐条都算。
//!
//! # 事务
//!
//! 写入全经 [Truth] 的写入守卫（必须在事务里、会话没被毒化、缓存与库同一个版本），报错时调用方回滚并 reset，与真相层
//! 同一个口径（`truth.rs`「会话与事务」）。集合号必须是绑着的集合，位置键不能是空文本。

use rusqlite::{OptionalExtension, params};

use super::schema::sql;
use super::truth::Truth;
use crate::gen4::op::Op4;
use crate::sync2::codec::Reader;
use crate::sync2::id::Id;
use crate::sync2::vv::OpId;

/// 一个位置上一台设备最新的 head（只记同步层要的几样）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocHead {
    pub device: Id,
    /// head 的代号（作者每重写一次 head 加一）。
    pub gen: u64,
    /// head 覆盖到的 seq。
    pub seq: u64,
    /// head 引用的段文件名，按 head 里的顺序。
    pub segs: Vec<String>,
}

/// [Truth::put_loc_head] 的结果。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LocHeadPut {
    /// 这台设备在这个位置上第一次有记录。
    Inserted,
    /// 换成了更新的 head。
    Advanced,
    /// 已有一模一样的。
    Same,
    /// 比记下的旧，没写。
    Stale,
    /// 与记下的互相矛盾（同代号不同内容，或代号更大而 seq 倒退），没写。
    Conflict,
}

/// 本机转发到一个位置的一个文件（`relay_out` 的一行）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RelayOut {
    /// 作者。
    pub device: Id,
    /// 位置上 `v4/devices/<作者>/` 下的文件名（`rly-…` 中继件、`rhd-…` 转发 head）。
    pub name: String,
    /// 转发时作者 head 的代号。
    pub gen: u64,
    /// 被更新的转发取代、等删。
    pub gone: bool,
}

/// 一个位置旧根上一次核对的结果。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OldRootFp {
    pub fp: [u8; 32],
    /// 核对的时刻（毫秒）。
    pub at: i64,
}

/// 旧根清单里的一个文件（[oldroot_fingerprint] 的输入）。
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct OldRootEntry {
    /// 相对旧根（`v3/`）的路径，`/` 分隔。
    pub path: String,
    pub size: u64,
    /// 传输给得出的修改时刻（毫秒）；给不出 = None。同名重写在大小不变时只能靠它看出来。
    pub modified: Option<i64>,
}

const FP_DOMAIN: &[u8] = b"fushi-srs-oldroot-fp/4\n";

/// 旧根清单的指纹：按 (路径, 大小, 修改时刻) 排序后逐条哈希，与列出来的顺序无关；新文件、删掉的、同名重写（大小或
/// 修改时刻变了）、被删又重建（修改时刻变了）都会让它变。
pub fn oldroot_fingerprint(entries: &[OldRootEntry]) -> [u8; 32] {
    let mut sorted: Vec<&OldRootEntry> = entries.iter().collect();
    sorted.sort();
    let mut h = blake3::Hasher::new();
    h.update(FP_DOMAIN);
    h.update(&(sorted.len() as u64).to_le_bytes());
    for e in sorted {
        h.update(&(e.path.len() as u64).to_le_bytes());
        h.update(e.path.as_bytes());
        h.update(&e.size.to_le_bytes());
        match e.modified {
            Some(m) => {
                h.update(&[1]);
                h.update(&m.to_le_bytes());
            }
            None => {
                h.update(&[0]);
            }
        };
    }
    *h.finalize().as_bytes()
}

/// 等待缓冲里的一项（[Truth::waiting]）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Waiting {
    /// 这一项的第一个操作号。
    pub id: OpId,
    /// 占几个 seq（操作 = 1）。
    pub span: u64,
    /// 这一项之前、之后的链值。
    pub prev: [u8; 32],
    pub chain: [u8; 32],
    /// 操作；空洞 = None。
    pub op: Option<Op4>,
}

/// `op_wait` 的一行：(k, prev, chain, span, op)。
pub(super) type WaitRow = (i64, Vec<u8>, Vec<u8>, i64, Option<Vec<u8>>);

fn u64_of(v: i64, what: &str) -> Result<u64, String> {
    u64::try_from(v).map_err(|_| format!("gen4 store: negative {what}"))
}

fn i64_of(v: u64, what: &str) -> Result<i64, String> {
    i64::try_from(v).map_err(|_| format!("gen4 store: {what} out of range"))
}

pub(super) fn chain32(b: &[u8]) -> Result<[u8; 32], String> {
    b.try_into()
        .map_err(|_| "gen4 store: bad chain value".to_owned())
}

pub(super) fn op_of_bytes(b: &[u8]) -> Result<Op4, String> {
    let mut r = Reader::new(b);
    let op = Op4::read(&mut r).map_err(|e| format!("gen4 store: bad waiting op: {}", e.0))?;
    if !r.is_empty() {
        return Err("gen4 store: trailing bytes after a waiting op".to_owned());
    }
    Ok(op)
}

impl<'c> Truth<'c> {
    fn sync_target(&self, col: i64, loc: &str) -> Result<(), String> {
        if loc.is_empty() {
            return Err("gen4 store: empty location key".to_owned());
        }
        if self.binding(col)?.is_none() {
            return Err(format!("gen4 store: no collection {col}"));
        }
        Ok(())
    }

    // ------------------------------------------------------------ loc_heads

    /// 位置 [loc] 上设备 [device] 最新的 head（没记过 = None）。
    pub fn loc_head(&self, col: i64, loc: &str, device: &Id) -> Result<Option<LocHead>, String> {
        let row: Option<(i64, i64, String)> = self
            .conn()
            .prepare_cached(
                "SELECT gen, seq, segs FROM loc_heads WHERE col = ?1 AND loc_key = ?2 AND device = ?3",
            )
            .map_err(sql)?
            .query_row(params![col, loc, &device.0[..]], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .optional()
            .map_err(sql)?;
        row.map(|(gen, seq, segs)| {
            Ok(LocHead {
                device: *device,
                gen: u64_of(gen, "head gen")?,
                seq: u64_of(seq, "head seq")?,
                segs: serde_json::from_str(&segs)
                    .map_err(|e| format!("gen4 store: bad segment list: {e}"))?,
            })
        })
        .transpose()
    }

    /// 位置 [loc] 上记下的全部 head，按设备 ID 字节序。
    pub fn loc_heads(&self, col: i64, loc: &str) -> Result<Vec<LocHead>, String> {
        let rows: Vec<(Vec<u8>, i64, i64, String)> = {
            let mut stmt = self
                .conn()
                .prepare_cached(
                    "SELECT device, gen, seq, segs FROM loc_heads WHERE col = ?1 AND loc_key = ?2 ORDER BY device",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![col, loc], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                })
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        rows.into_iter()
            .map(|(device, gen, seq, segs)| {
                Ok(LocHead {
                    device: Id(device
                        .try_into()
                        .map_err(|_| "gen4 store: bad device id".to_owned())?),
                    gen: u64_of(gen, "head gen")?,
                    seq: u64_of(seq, "head seq")?,
                    segs: serde_json::from_str(&segs)
                        .map_err(|e| format!("gen4 store: bad segment list: {e}"))?,
                })
            })
            .collect()
    }

    /// 记下这一轮在位置 [loc] 上读到的 [head]（文件头「head 只进不退」）。
    pub fn put_loc_head(&self, col: i64, loc: &str, head: &LocHead) -> Result<LocHeadPut, String> {
        self.write(|| {
            self.sync_target(col, loc)?;
            let gen = i64_of(head.gen, "head gen")?;
            let seq = i64_of(head.seq, "head seq")?;
            let segs = serde_json::to_string(&head.segs).map_err(sql)?;
            let put = match self.loc_head(col, loc, &head.device)? {
                None => LocHeadPut::Inserted,
                Some(cur) if cur == *head => return Ok(LocHeadPut::Same),
                Some(cur) if head.gen < cur.gen => return Ok(LocHeadPut::Stale),
                Some(cur) if head.gen == cur.gen || head.seq < cur.seq => {
                    return Ok(LocHeadPut::Conflict);
                }
                Some(_) => LocHeadPut::Advanced,
            };
            self.conn()
                .prepare_cached(
                    "INSERT OR REPLACE INTO loc_heads (col, loc_key, device, gen, seq, segs) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                )
                .map_err(sql)?
                .execute(params![col, loc, &head.device.0[..], gen, seq, segs])
                .map_err(sql)?;
            Ok(put)
        })
    }

    /// 本机不再同步到位置 [loc]（用户移除了它）：去掉这个位置的 head 记录、转发记账、旧根指纹。返回去掉的行数。
    /// 待删的转发件随之忘掉——位置已经不用了，上面的文件不归本机管。`media_at` / `loc_state` 不归这里（G8-3 / G7-2）。
    pub fn forget_location(&self, col: i64, loc: &str) -> Result<u64, String> {
        self.write(|| {
            self.sync_target(col, loc)?;
            let mut n = 0u64;
            for table in ["loc_heads", "relay_out", "oldroot_fp"] {
                n += self
                    .conn()
                    .prepare_cached(&format!(
                        "DELETE FROM {table} WHERE col = ?1 AND loc_key = ?2"
                    ))
                    .map_err(sql)?
                    .execute(params![col, loc])
                    .map_err(sql)? as u64;
            }
            Ok(n)
        })
    }

    // ------------------------------------------------------------ relay_out

    /// 本机把作者 [device] 的文件 [name] 转发到了位置 [loc]（当时作者 head 的代号 [gen]）。已记过的换成新代号；
    /// 待删的同名件回到在用（同名重写）。返回是否改了库。
    pub fn relay_sent(
        &self,
        col: i64,
        loc: &str,
        device: &Id,
        name: &str,
        gen: u64,
    ) -> Result<bool, String> {
        self.write(|| {
            self.sync_target(col, loc)?;
            if name.is_empty() {
                return Err("gen4 store: empty relay file name".to_owned());
            }
            let gen = i64_of(gen, "relay gen")?;
            let n = self
                .conn()
                .prepare_cached(
                    "INSERT INTO relay_out (col, loc_key, device, name, gen, gone) VALUES (?1, ?2, ?3, ?4, ?5, 0) \
                     ON CONFLICT (col, loc_key, device, name) DO UPDATE SET gen = excluded.gen, gone = 0 \
                     WHERE relay_out.gen != excluded.gen OR relay_out.gone != 0",
                )
                .map_err(sql)?
                .execute(params![col, loc, &device.0[..], name, gen])
                .map_err(sql)?;
            Ok(n > 0)
        })
    }

    /// 作者 [device] 在位置 [loc] 上的转发已经换成代号 [gen] 的了：代号更小、还在用的件改成待删，返回它们的文件名
    /// （按名字升序）。调用方删掉位置上的文件后逐个 [Truth::relay_deleted]。
    pub fn relay_supersede(
        &self,
        col: i64,
        loc: &str,
        device: &Id,
        gen: u64,
    ) -> Result<Vec<String>, String> {
        self.write(|| {
            self.sync_target(col, loc)?;
            let gen = i64_of(gen, "relay gen")?;
            let names: Vec<String> = {
                let mut stmt = self
                    .conn()
                    .prepare_cached(
                        "SELECT name FROM relay_out WHERE col = ?1 AND loc_key = ?2 AND device = ?3 \
                         AND gen < ?4 AND gone = 0 ORDER BY name",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![col, loc, &device.0[..], gen], |r| r.get(0))
                    .map_err(sql)?;
                rows.collect::<rusqlite::Result<_>>().map_err(sql)?
            };
            self.conn()
                .prepare_cached(
                    "UPDATE relay_out SET gone = 1 WHERE col = ?1 AND loc_key = ?2 AND device = ?3 \
                     AND gen < ?4 AND gone = 0",
                )
                .map_err(sql)?
                .execute(params![col, loc, &device.0[..], gen])
                .map_err(sql)?;
            Ok(names)
        })
    }

    /// 位置 [loc] 上本机转发过的全部文件（含待删的），按 (作者, 文件名) 升序。
    pub fn relay_out(&self, col: i64, loc: &str) -> Result<Vec<RelayOut>, String> {
        let rows: Vec<(Vec<u8>, String, i64, i64)> = {
            let mut stmt = self
                .conn()
                .prepare_cached(
                    "SELECT device, name, gen, gone FROM relay_out WHERE col = ?1 AND loc_key = ?2 \
                     ORDER BY device, name",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![col, loc], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                })
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        rows.into_iter()
            .map(|(device, name, gen, gone)| {
                Ok(RelayOut {
                    device: Id(device
                        .try_into()
                        .map_err(|_| "gen4 store: bad device id".to_owned())?),
                    name,
                    gen: u64_of(gen, "relay gen")?,
                    gone: gone != 0,
                })
            })
            .collect()
    }

    /// 位置 [loc] 上待删的转发件。
    pub fn relay_gone(&self, col: i64, loc: &str) -> Result<Vec<RelayOut>, String> {
        Ok(self
            .relay_out(col, loc)?
            .into_iter()
            .filter(|r| r.gone)
            .collect())
    }

    /// 调用方删掉了位置 [loc] 上的待删件 [name]：去掉这一行。只认待删的行（还在用的、没记过的 = false，什么都不改）。
    pub fn relay_deleted(
        &self,
        col: i64,
        loc: &str,
        device: &Id,
        name: &str,
    ) -> Result<bool, String> {
        self.write(|| {
            self.sync_target(col, loc)?;
            let n = self
                .conn()
                .prepare_cached(
                    "DELETE FROM relay_out WHERE col = ?1 AND loc_key = ?2 AND device = ?3 AND name = ?4 \
                     AND gone = 1",
                )
                .map_err(sql)?
                .execute(params![col, loc, &device.0[..], name])
                .map_err(sql)?;
            Ok(n > 0)
        })
    }

    // ------------------------------------------------------------ oldroot_fp

    /// 位置 [loc] 旧根上一次核对的结果。
    pub fn oldroot_fp(&self, col: i64, loc: &str) -> Result<Option<OldRootFp>, String> {
        let row: Option<(Vec<u8>, i64)> = self
            .conn()
            .prepare_cached("SELECT fp, at FROM oldroot_fp WHERE col = ?1 AND loc_key = ?2")
            .map_err(sql)?
            .query_row(params![col, loc], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()
            .map_err(sql)?;
        row.map(|(fp, at)| {
            Ok(OldRootFp {
                fp: fp
                    .try_into()
                    .map_err(|_| "gen4 store: bad old-root fingerprint".to_owned())?,
                at,
            })
        })
        .transpose()
    }

    /// 记下这一轮核对位置 [loc] 旧根的结果。返回指纹是否变了（第一次记 = 变了）；没变只更新时刻。
    pub fn set_oldroot_fp(
        &self,
        col: i64,
        loc: &str,
        fp: &[u8; 32],
        at: i64,
    ) -> Result<bool, String> {
        self.write(|| {
            self.sync_target(col, loc)?;
            let changed = self.oldroot_fp(col, loc)?.is_none_or(|cur| cur.fp != *fp);
            self.conn()
                .prepare_cached(
                    "INSERT OR REPLACE INTO oldroot_fp (col, loc_key, fp, at) VALUES (?1, ?2, ?3, ?4)",
                )
                .map_err(sql)?
                .execute(params![col, loc, &fp[..], at])
                .map_err(sql)?;
            Ok(changed)
        })
    }

    // ------------------------------------------------------------ op_wait（只读）

    /// 集合 [col] 的原生等待缓冲，按操作主键升序。
    pub fn waiting(&self, col: i64) -> Result<Vec<Waiting>, String> {
        let rows: Vec<WaitRow> = {
            let mut stmt = self
                .conn()
                .prepare_cached(
                    "SELECT w.k, w.prev, w.chain, w.span, w.op FROM op_wait w JOIN devs d ON d.dev = w.k >> 40 \
                     WHERE d.col = ?1 ORDER BY w.k, w.prev, w.chain",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map([col], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
                })
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        rows.into_iter()
            .map(|(k, prev, chain, span, op)| {
                Ok(Waiting {
                    id: self.id_of_key(k)?,
                    span: u64_of(span, "span")?,
                    prev: chain32(&prev)?,
                    chain: chain32(&chain)?,
                    op: op.as_deref().map(op_of_bytes).transpose()?,
                })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gen4::op::tests::id;
    use crate::store::gen4::schema::open_in_memory;
    use crate::store::gen4::truth::tests::bound;

    const LOC: &str = "folder:/srs";

    fn head(gen: u64, seq: u64, segs: &[&str]) -> LocHead {
        LocHead {
            device: id(0x21),
            gen,
            seq,
            segs: segs.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn a_location_head_only_moves_forward() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let put = |h: &LocHead| t.tx(|t| t.put_loc_head(col, LOC, h)).unwrap();
        assert_eq!(put(&head(2, 10, &["seg-1-10-a"])), LocHeadPut::Inserted);
        assert_eq!(put(&head(2, 10, &["seg-1-10-a"])), LocHeadPut::Same);
        assert_eq!(put(&head(1, 12, &["x"])), LocHeadPut::Stale);
        // 同代号不同内容、代号更大而 seq 倒退：矛盾，不写。
        assert_eq!(put(&head(2, 11, &["seg-1-11-b"])), LocHeadPut::Conflict);
        assert_eq!(put(&head(3, 9, &["seg-1-9-c"])), LocHeadPut::Conflict);
        assert_eq!(
            t.loc_head(col, LOC, &id(0x21)).unwrap(),
            Some(head(2, 10, &["seg-1-10-a"]))
        );
        // 代号更大、seq 不变（合并小段改了清单）：换。
        assert_eq!(put(&head(3, 10, &["seg-1-10-a2"])), LocHeadPut::Advanced);
        assert_eq!(
            put(&head(4, 14, &["seg-1-10-a2", "seg-11-14-d"])),
            LocHeadPut::Advanced
        );
        // 别的位置、别的设备互不相干。
        let other = LocHead {
            device: id(0x22),
            ..head(1, 1, &[])
        };
        assert_eq!(
            t.tx(|t| t.put_loc_head(col, "webdav:x", &other)),
            Ok(LocHeadPut::Inserted)
        );
        assert_eq!(
            t.tx(|t| t.put_loc_head(col, LOC, &other)),
            Ok(LocHeadPut::Inserted)
        );
        assert_eq!(
            t.loc_heads(col, LOC).unwrap(),
            vec![head(4, 14, &["seg-1-10-a2", "seg-11-14-d"]), other.clone()]
        );
        assert_eq!(t.loc_heads(col, "webdav:x").unwrap(), vec![other]);
    }

    #[test]
    fn misuse_is_refused_and_writes_need_a_transaction() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let e = t.put_loc_head(col, LOC, &head(1, 1, &[])).unwrap_err();
        assert!(e.contains("outside a transaction"), "{e}");
        let e = t
            .tx(|t| t.put_loc_head(col + 1, LOC, &head(1, 1, &[])))
            .unwrap_err();
        assert!(e.contains("no collection"), "{e}");
        let e = t
            .tx(|t| t.put_loc_head(col, "", &head(1, 1, &[])))
            .unwrap_err();
        assert!(e.contains("empty location"), "{e}");
        let e = t.tx(|t| t.relay_sent(col, LOC, &id(1), "", 1)).unwrap_err();
        assert!(e.contains("empty relay"), "{e}");
        let e = t
            .tx(|t| t.put_loc_head(col, LOC, &head(u64::MAX, 1, &[])))
            .unwrap_err();
        assert!(e.contains("out of range"), "{e}");
        // 报过错的写入回滚了，什么都没留下。
        assert_eq!(t.loc_heads(col, LOC).unwrap(), vec![]);
    }

    #[test]
    fn a_superseded_relay_stays_until_its_deletion_is_reported() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let a = id(0x31);
        assert_eq!(
            t.tx(|t| t.relay_sent(col, LOC, &a, "rly-1-4-aa", 1)),
            Ok(true)
        );
        assert_eq!(t.tx(|t| t.relay_sent(col, LOC, &a, "rhd-a-1", 1)), Ok(true));
        assert_eq!(
            t.tx(|t| t.relay_sent(col, LOC, &a, "rhd-a-1", 1)),
            Ok(false)
        );
        assert_eq!(
            t.tx(|t| t.relay_sent(col, LOC, &a, "rly-5-9-bb", 2)),
            Ok(true)
        );
        // 还在用的件不能被一次「删好了」抹掉。
        assert_eq!(
            t.tx(|t| t.relay_deleted(col, LOC, &a, "rly-1-4-aa")),
            Ok(false)
        );
        assert_eq!(
            t.tx(|t| t.relay_supersede(col, LOC, &a, 2)),
            Ok(vec!["rhd-a-1".to_owned(), "rly-1-4-aa".to_owned()])
        );
        // 再取代一次不重复列。
        assert_eq!(t.tx(|t| t.relay_supersede(col, LOC, &a, 2)), Ok(vec![]));
        let gone: Vec<String> = t
            .relay_gone(col, LOC)
            .unwrap()
            .into_iter()
            .map(|r| r.name)
            .collect();
        assert_eq!(gone, vec!["rhd-a-1", "rly-1-4-aa"]);
        // 删了一个、另一个删到一半失败：下一轮照样列出来。
        assert_eq!(t.tx(|t| t.relay_deleted(col, LOC, &a, "rhd-a-1")), Ok(true));
        let gone: Vec<String> = t
            .relay_gone(col, LOC)
            .unwrap()
            .into_iter()
            .map(|r| r.name)
            .collect();
        assert_eq!(gone, vec!["rly-1-4-aa"]);
        // 同名重写：回到在用。
        assert_eq!(
            t.tx(|t| t.relay_sent(col, LOC, &a, "rly-1-4-aa", 3)),
            Ok(true)
        );
        assert_eq!(t.relay_gone(col, LOC).unwrap(), vec![]);
        assert_eq!(
            t.relay_out(col, LOC).unwrap(),
            vec![
                RelayOut {
                    device: a,
                    name: "rly-1-4-aa".into(),
                    gen: 3,
                    gone: false
                },
                RelayOut {
                    device: a,
                    name: "rly-5-9-bb".into(),
                    gen: 2,
                    gone: false
                },
            ]
        );
    }

    /// 待删记账跨崩溃：标成待删的事务提交之后，调用方没来得及回报就挂了，重开的会话照样列出来。
    #[test]
    fn pending_deletions_survive_a_restart() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-relay-gone");
        let path = dir.0.join("srs4.db");
        let col = {
            let conn = crate::store::gen4::schema::open(&path).unwrap();
            let t = Truth::new(&conn);
            let col = bound(&t);
            t.tx(|t| {
                t.relay_sent(col, LOC, &id(1), "rly-1-2-x", 1)?;
                t.relay_supersede(col, LOC, &id(1), 2)
            })
            .unwrap();
            // 下一笔写到一半没提交（回滚）：待删的行不受影响。
            let r: Result<(), String> = t.tx(|t| {
                t.relay_deleted(col, LOC, &id(1), "rly-1-2-x")?;
                Err("crash".to_owned())
            });
            assert!(r.is_err());
            col
        };
        let conn = crate::store::gen4::schema::open(&path).unwrap();
        let t = Truth::new(&conn);
        let gone: Vec<String> = t
            .relay_gone(col, LOC)
            .unwrap()
            .into_iter()
            .map(|r| r.name)
            .collect();
        assert_eq!(gone, vec!["rly-1-2-x"]);
    }

    #[test]
    fn the_old_root_fingerprint_is_a_function_of_the_listing() {
        let e = |p: &str, size: u64, m: Option<i64>| OldRootEntry {
            path: p.to_owned(),
            size,
            modified: m,
        };
        let base = vec![
            e("meta.json", 120, Some(5)),
            e("devices/a/head-1.json", 300, Some(7)),
            e("devices/a/seg-1-4-x.bin", 9000, None),
        ];
        let fp = oldroot_fingerprint(&base);
        let mut shuffled = base.clone();
        shuffled.reverse();
        assert_eq!(oldroot_fingerprint(&shuffled), fp);
        let mut variants = Vec::new();
        // 新文件、删掉一个、同名重写（大小 / 时刻）、同名文件出现两份（Google Drive）、围栏被删。
        let mut v = base.clone();
        v.push(e("devices/b/seg-1-1-y.bin", 10, None));
        variants.push(v);
        variants.push(base[1..].to_vec());
        let mut v = base.clone();
        v[2].size = 9001;
        variants.push(v);
        let mut v = base.clone();
        v[1].modified = Some(8);
        variants.push(v);
        let mut v = base.clone();
        v[1].modified = None;
        variants.push(v);
        let mut v = base.clone();
        v.push(base[0].clone());
        variants.push(v);
        variants.push(vec![]);
        for v in &variants {
            assert_ne!(oldroot_fingerprint(v), fp, "{v:?}");
        }
        // 路径拼接不会互相冒充（长度前缀）。
        assert_ne!(
            oldroot_fingerprint(&[e("ab", 1, None), e("c", 1, None)]),
            oldroot_fingerprint(&[e("a", 1, None), e("bc", 1, None)])
        );
    }

    #[test]
    fn the_old_root_check_and_forgetting_a_location() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        assert_eq!(t.oldroot_fp(col, LOC).unwrap(), None);
        assert_eq!(t.tx(|t| t.set_oldroot_fp(col, LOC, &[1; 32], 10)), Ok(true));
        assert_eq!(
            t.tx(|t| t.set_oldroot_fp(col, LOC, &[1; 32], 20)),
            Ok(false)
        );
        assert_eq!(
            t.oldroot_fp(col, LOC).unwrap(),
            Some(OldRootFp {
                fp: [1; 32],
                at: 20
            })
        );
        assert_eq!(t.tx(|t| t.set_oldroot_fp(col, LOC, &[2; 32], 30)), Ok(true));
        t.tx(|t| {
            t.put_loc_head(col, LOC, &head(1, 1, &[]))?;
            t.put_loc_head(col, "other", &head(1, 1, &[]))?;
            t.relay_sent(col, LOC, &id(1), "rly-1-1-z", 1)
        })
        .unwrap();
        assert_eq!(t.tx(|t| t.forget_location(col, LOC)), Ok(3));
        assert_eq!(t.loc_heads(col, LOC).unwrap(), vec![]);
        assert_eq!(t.relay_out(col, LOC).unwrap(), vec![]);
        assert_eq!(t.oldroot_fp(col, LOC).unwrap(), None);
        assert_eq!(t.loc_heads(col, "other").unwrap().len(), 1);
    }
}
