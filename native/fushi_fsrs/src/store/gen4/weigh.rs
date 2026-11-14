//! 派生层的语义部分（设计 §2.2、§2.5；规则是协议 3 `store/sync2/semantics.rs`、`trust.rs`、`mvr.rs` 的那一套，这里
//! 改成对操作全集判）：标签 OR-Set、媒体名 → 内容、彻底清除、被并发改动扣住的删除、不可信设备被扣住的删除与清除。
//! 都是 [Index] 的一部分：逐条维护时由 [Index::settle] 调，重建时由 [Index::rebuild_all] 调，两条路出来的行逐行相同。
//!
//! 谁见过谁只有一个判据：[Head::saw]（同一台设备按 seq，别的设备看作者的依赖向量；协议 3 `Op::saw` / `mvr::covers`）。
//!
//! # 表
//!
//! - `tag_ix(col, note, k, what, tag, state)`：标签操作。`what`：[T_ADD] 添加点、[T_REMOVE] 观察删除、[T_ORDER] 顺序
//!   提示、[T_INERT] 值不是数组的 `tags` 整列表写入（不起作用，但仍是这条笔记的内容操作）。一条 `tags` 整列表写入
//!   （迁移进来的旧记录）= 给其中每个标签记一个添加点，再记一条顺序提示。`state`：添加点 1 = 活着、0 = 被某条见过它的
//!   删除抹掉了（加胜：并发的添加留着）；顺序提示按 [mvr]；[S_PURGED] = 被清除了。
//! - `media_ix(col, name, k, state)`：媒体名 → 内容的绑定，按 [mvr]。
//! - `purge_ix(col, ekind, ent, k, state)`：Purge 操作。1 = 生效；[S_DISTRUSTED] = 作者还没被本机信任，不执行。
//! - `ent_ops(col, ekind, ent, what, k)`：碰过一个实体、而别的索引按这个实体查不到的操作：[E_LOG] 笔记名下的日志
//!   （`log_ix` 按卡排）、[E_MOVE] 把卡挪进这个牌组的修改（`reg_ix` 里它挂在卡名下）。
//! - `hold_ix(col, ekind, ent, k, edits, reviews, moves)`：被扣住的删除（等用户裁决），与它并发的操作各有几条。
//!
//! # 规则
//!
//! - **彻底清除**：实体 E 上生效的 Purge 记为 P。E 的内容操作 x（E 的修改，`deleted` 除外；笔记的标签操作；把卡挪进
//!   牌组 E 的修改）只要有一条 p ∈ P 是 x 的作者没见过的，x 就是「已清除」（[S_PURGED]）：不参与任何判定。见过全部
//!   清除的是清除之后的写入，照常生效（复活）。日志、身份记录、媒体绑定、`deleted` 不受清除影响。
//!   重建不改真相；把「已清除」的操作落成空洞由 [Index::execute_purges] 做（设计 §3.2：本机的槽只由本机自己应用
//!   Purge 推进）。落不落成空洞，派生出来的胜者都一样。
//! - **扣住的删除**：删除 = `deleted` 上、不带旧戳、值是整数的写入。它没被同一个寄存器上见过它的另一条写入盖掉，
//!   而实体上有与它并发的别的操作（不带旧戳的修改、标签操作、日志、挪进来的卡、生效的清除；已清除的不算）→ 扣住
//!   （[S_HELD]），等用户裁决（裁决 = 再写一条见过它的 `deleted`）。扣住的删除自己不生效（不当胜者、不算活着），
//!   但它见过的写入照样被它盖掉（`derive.rs` `judge`）：扣住是「这条删除等人裁决」，不是「当它没写过」。
//! - **信任**：本机还没信任的设备（`trust` 表，本机状态）写的删除（`deleted` 上值是整数的写入，带不带旧戳都算）与
//!   Purge 不执行（[S_DISTRUSTED]），它写的 Salts / Join 里的盐不算进盐集合（`alias.rs`）。它别的操作照常。
//!   信任状态变了调 [Index::trust_changed]。
//!
//! # 与协议 3 的差别（都在「同一个操作集合，结果要与到达顺序无关」这一条上）
//!
//! - 协议 3 清除时只把日志里的载荷换成骨架、投影里删行，反链（顺序提示）与「把卡挪进被清除牌组的修改」的投影行留着；
//!   这里已清除的操作一律不参与。
//! - 协议 3 判扣住时，已清除操作的骨架仍算「并发的操作」（骨架留着依赖向量）；空洞没有依赖向量，这里不算。
//! - 协议 3 只在有操作碰到实体时重判扣住，标签顺序提示不触发；这里对全集判。
//! - 协议 3 里一条删除 d2 盖不盖掉它见过的写入 d，取决于到达顺序：d2 到的时候已经该扣住 → 不落投影，d 留着；d2 先
//!   落了投影（盖掉 d）、并发的那条操作后到 → d2 被撤出投影，d 不回来。这里一律按后一种（见上）：前一种会让 d——
//!   一条同样与那条操作并发、只因「被 d2 盖过」而不算冲突的删除——绕过扣住直接生效。

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::params;
use serde_json::Value;

use super::derive::{Index, R_DOMINATED, R_LIVE, R_WINNER, Ref, Reg, Settled, body_of};
use super::schema::sql;
use super::truth::Head;
use crate::gen4::op::{Body4, Edit4, KIND_EDIT};
use crate::sync2::id::{Id, Key};
use crate::sync2::op::EntKind;
use crate::sync2::vv::OpId;

/// `state`：被清除了（作者没见过实体上某条生效的 Purge）。
pub const S_PURGED: i64 = -1;
/// `reg_ix.state`：被并发的改动扣住的删除。
pub const S_HELD: i64 = -2;
/// `reg_ix.state` / `purge_ix.state`：作者还没被本机信任。
pub const S_DISTRUSTED: i64 = -3;

/// `tag_ix.what`
pub const T_ADD: i64 = 0;
pub const T_REMOVE: i64 = 1;
pub const T_ORDER: i64 = 2;
pub const T_INERT: i64 = 3;

/// `ent_ops.what`
pub const E_LOG: i64 = 1;
pub const E_MOVE: i64 = 2;

/// 一条被扣住的删除（[Index::holds]）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hold {
    pub kind: EntKind,
    pub entity: Ref,
    pub op: OpId,
    /// 与它并发的操作：修改（含标签、清除）、复习、挪进来的卡。
    pub edits: u64,
    pub reviews: u64,
    pub moves: u64,
}

/// 「因果优先、并发才比 HLC」的寄存器（协议 3 `mvr.rs`）：没被别的写入见过的是反链，反链里 (wall, logical, 设备)
/// 最大的是当前值。返回与 [heads] 对齐的状态：2 当前值 / 1 反链里的别的 / 0 被见过。
fn mvr(heads: &[Head]) -> Vec<i64> {
    let mut out: Vec<i64> = heads
        .iter()
        .map(|y| {
            let covered = heads.iter().any(|x| x.id != y.id && x.saw(&y.id));
            if covered { R_DOMINATED } else { R_LIVE }
        })
        .collect();
    let win = (0..heads.len())
        .filter(|&i| out[i] == R_LIVE)
        .max_by_key(|&i| (heads[i].wall, heads[i].logical, heads[i].id.device.0));
    if let Some(i) = win {
        out[i] = R_WINNER;
    }
    out
}

fn key_bytes(key: &str) -> Vec<u8> {
    Reg::new(EntKind::Note, &Key::Text(String::new()), key).key
}

fn ent_kind(code: i64) -> Result<EntKind, String> {
    EntKind::ALL
        .get(code as usize)
        .copied()
        .ok_or_else(|| "gen4 index: bad entity kind".to_owned())
}

impl<'t, 'c> Index<'t, 'c> {
    // ------------------------------------------------------------ 逐条维护（`derive.rs` 的 touch 调）

    /// 一条标签操作在 `tag_ix` 里的行：[rows] = (`what`, 标签)。
    pub(super) fn tag_rows(
        &self,
        note: &Ref,
        k: i64,
        rows: &[(i64, &str)],
        add: bool,
    ) -> Result<(), String> {
        let conn = self.t.conn();
        if !add {
            conn.prepare_cached("DELETE FROM tag_ix WHERE col = ?1 AND note = ?2 AND k = ?3")
                .map_err(sql)?
                .execute(params![self.col, note, k])
                .map_err(sql)?;
            return Ok(());
        }
        for &(what, tag) in rows {
            let state = if what == T_ORDER { R_WINNER } else { R_LIVE };
            // 同一条整列表里重复的标签只算一个添加点。
            conn.prepare_cached(
                "INSERT OR IGNORE INTO tag_ix (col, note, k, what, tag, state) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            )
            .map_err(sql)?
            .execute(params![self.col, note, k, what, tag, state])
            .map_err(sql)?;
        }
        Ok(())
    }

    pub(super) fn ent_op(
        &self,
        kind: EntKind,
        ent: &Ref,
        what: i64,
        k: i64,
        add: bool,
    ) -> Result<(), String> {
        let q = if add {
            "INSERT INTO ent_ops (col, ekind, ent, what, k) VALUES (?1, ?2, ?3, ?4, ?5)"
        } else {
            "DELETE FROM ent_ops WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND what = ?4 AND k = ?5"
        };
        self.t
            .conn()
            .prepare_cached(q)
            .map_err(sql)?
            .execute(params![self.col, kind as i64, ent, what, k])
            .map_err(sql)?;
        Ok(())
    }

    /// 本机改了某台设备的信任状态（`Truth::set_trust`）：下一次 [Index::settle] 把被扣住的删除与清除全部重看。
    pub fn trust_changed(&mut self) {
        self.trust_changed = true;
        self.salts_dirty = true;
    }

    // ------------------------------------------------------------ 小工具

    fn head(&mut self, k: i64) -> Result<Head, String> {
        if let Some(h) = self.heads.get(&k) {
            return Ok(h.clone());
        }
        let h = self
            .t
            .head_by_key(k)?
            .ok_or_else(|| format!("gen4 index: row {k} has no op"))?;
        self.heads.insert(k, h.clone());
        Ok(h)
    }

    pub(super) fn distrusts(&mut self, device: &Id) -> Result<bool, String> {
        if self.untrusted.is_none() {
            let set = self.t.untrusted(self.col)?;
            self.untrusted = Some(set.into_iter().map(|(d, _)| d).collect());
        }
        Ok(self
            .untrusted
            .as_ref()
            .expect("just loaded")
            .contains(device))
    }

    fn edit_at(&self, k: i64) -> Result<Edit4, String> {
        let e = self
            .t
            .entry_by_key(k)?
            .ok_or_else(|| format!("gen4 index: row {k} has no op"))?;
        match body_of(&e) {
            Some(Body4::Edit(ed)) => Ok(ed),
            _ => Err(format!("gen4 index: row {k} is not an edit")),
        }
    }

    /// 这条是不是带旧戳的修改（迁移进来的旧记录：没有这一代的因果上下文，不拿它判并发）。
    fn stamped(&self, h: &Head, k: i64) -> Result<bool, String> {
        if h.kind != KIND_EDIT {
            return Ok(false);
        }
        if !h.raw {
            return Ok(h.stamped);
        }
        Ok(self.edit_at(k)?.stamp.is_some())
    }

    /// [k] 的作者有没有哪条 [ps] 没见过。
    fn unseen(&mut self, k: i64, ps: &[OpId]) -> Result<bool, String> {
        if ps.is_empty() {
            return Ok(false);
        }
        let h = self.head(k)?;
        Ok(ps.iter().any(|p| !h.saw(p)))
    }

    pub(super) fn reg_state(&self, r: &Reg, k: i64) -> Result<Option<i64>, String> {
        use rusqlite::OptionalExtension;
        self.t
            .conn()
            .prepare_cached(
                "SELECT state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND key = ?4 AND k = ?5",
            )
            .map_err(sql)?
            .query_row(params![self.col, r.ekind, r.ent, r.key, k], |x| x.get(0))
            .optional()
            .map_err(sql)
    }

    fn set_reg_state(&self, r: &Reg, k: i64, state: i64) -> Result<(), String> {
        self.t
            .conn()
            .prepare_cached(
                "UPDATE reg_ix SET state = ?6 WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND key = ?4 AND k = ?5",
            )
            .map_err(sql)?
            .execute(params![self.col, r.ekind, r.ent, r.key, k, state])
            .map_err(sql)?;
        Ok(())
    }

    fn keys_of(&self, q: &str, ekind: i64, ent: &Ref, what: i64) -> Result<Vec<i64>, String> {
        let mut stmt = self.t.conn().prepare_cached(q).map_err(sql)?;
        let rows = stmt
            .query_map(params![self.col, ekind, ent, what], |r| r.get(0))
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    fn ent_ops_of(&self, ekind: i64, ent: &Ref, what: i64) -> Result<Vec<i64>, String> {
        self.keys_of(
            "SELECT k FROM ent_ops WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND what = ?4 ORDER BY k",
            ekind,
            ent,
            what,
        )
    }

    /// 一个实体名下寄存器的全部写入：(修改键的字节形, 主键, 状态)。
    fn rows_of(&self, ekind: i64, ent: &Ref) -> Result<Vec<(Vec<u8>, i64, i64)>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT key, k, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 ORDER BY key, k",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![self.col, ekind, ent], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    fn tags_rows(&self, note: &Ref) -> Result<Vec<(i64, i64, String, i64)>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT k, what, tag, state FROM tag_ix WHERE col = ?1 AND note = ?2 ORDER BY k, what, tag",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![self.col, note], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
            })
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    // ------------------------------------------------------------ 收尾

    /// 清除、扣住、标签、媒体各自重看该看的（[bulk] = 重建：全部）。动了的寄存器记进 `self.regs`，由调用方接着判。
    pub(super) fn weigh(&mut self, bulk: bool, out: &mut Settled) -> Result<(), String> {
        self.heads.clear();
        let trust = std::mem::take(&mut self.trust_changed);
        if trust {
            self.untrusted = None;
        }
        let purges = std::mem::take(&mut self.purge_changed);
        out.purged += self.weigh_purges(bulk || purges || trust)?;
        let mut ents = std::mem::take(&mut self.touched);
        self.dirt.entities.extend(ents.iter().cloned());
        if bulk || trust {
            ents.extend(self.deleted_entities()?);
        }
        for (ekind, ent) in &ents {
            if self.weigh_holds(*ekind, ent)? {
                out.holds += 1;
            }
        }
        self.touched.clear();
        let mut notes = std::mem::take(&mut self.notes);
        if bulk {
            notes.extend(self.busy_notes()?);
        }
        for n in &notes {
            self.weigh_tags(n)?;
            self.dirt.entity(EntKind::Note as i64, n);
            out.notes += 1;
        }
        let mut names = std::mem::take(&mut self.names);
        if bulk {
            names.extend(self.busy_names()?);
        }
        for n in &names {
            self.weigh_media(n)?;
            out.media += 1;
        }
        Ok(())
    }

    /// 有过 `deleted` 写入的实体。
    fn deleted_entities(&self) -> Result<Vec<(i64, Ref)>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached("SELECT DISTINCT ekind, ent FROM reg_ix WHERE col = ?1 AND key = ?2")
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![self.col, key_bytes("deleted")], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    /// 标签状态不是插入时的默认值就能定的笔记：有删除，或顺序提示不止一条。
    fn busy_notes(&self) -> Result<Vec<Ref>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT note FROM tag_ix WHERE col = ?1 GROUP BY note \
                 HAVING SUM(what = 1) > 0 OR SUM(what = 2) > 1 OR SUM(state < 0) > 0",
            )
            .map_err(sql)?;
        let rows = stmt.query_map([self.col], |r| r.get(0)).map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    fn busy_names(&self) -> Result<Vec<String>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT name FROM media_ix WHERE col = ?1 GROUP BY name HAVING COUNT(*) > 1",
            )
            .map_err(sql)?;
        let rows = stmt.query_map([self.col], |r| r.get(0)).map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    // ------------------------------------------------------------ 彻底清除

    /// 重看清除：先按信任状态定每条 Purge 生不生效，再给受影响实体的内容操作定「已清除」。[all] = 有 Purge 进出、
    /// 信任变了、或重建：每个有 Purge 的实体都看；否则只看这一批碰过的。返回看了几个实体。
    fn weigh_purges(&mut self, all: bool) -> Result<u64, String> {
        let rows: Vec<(i64, Ref, i64, i64)> = {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached(
                    "SELECT ekind, ent, k, state FROM purge_ix WHERE col = ?1 ORDER BY ekind, ent, k",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map([self.col], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                })
                .map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)?
        };
        if rows.is_empty() && !all {
            return Ok(0);
        }
        let mut eff: BTreeMap<(i64, Ref), Vec<OpId>> = BTreeMap::new();
        let mut known: BTreeSet<(i64, Ref)> = BTreeSet::new();
        for (ekind, ent, k, state) in rows {
            let id = self.t.id_of_key(k)?;
            let want = if self.distrusts(&id.device)? {
                S_DISTRUSTED
            } else {
                R_LIVE
            };
            if want != state {
                self.t
                    .conn()
                    .prepare_cached(
                        "UPDATE purge_ix SET state = ?5 WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND k = ?4",
                    )
                    .map_err(sql)?
                    .execute(params![self.col, ekind, ent, k, want])
                    .map_err(sql)?;
            }
            known.insert((ekind, ent.clone()));
            if want == R_LIVE {
                eff.entry((ekind, ent)).or_default().push(id);
            }
        }
        let ents: BTreeSet<(i64, Ref)> = if all {
            known.union(&self.touched).cloned().collect()
        } else {
            known.intersection(&self.touched).cloned().collect()
        };
        let (deck, card) = (EntKind::Deck as i64, EntKind::Card as i64);
        let any_deck = eff.keys().any(|(k, _)| *k == deck);
        let (deleted, deck_key) = (key_bytes("deleted"), key_bytes("deck"));
        let none: Vec<OpId> = Vec::new();
        for (ekind, ent) in &ents {
            let own = eff.get(&(*ekind, ent.clone())).unwrap_or(&none);
            for (key, k, state) in self.rows_of(*ekind, ent)? {
                if key == deleted {
                    continue;
                }
                let mut purged = self.unseen(k, own)?;
                if !purged && any_deck && *ekind == card && key == deck_key {
                    // 挪进被清除牌组的修改，牌组那边的清除也管它。
                    if let Some(d) = self.move_target(k)? {
                        let theirs = eff.get(&(deck, d)).unwrap_or(&none);
                        purged = self.unseen(k, theirs)?;
                    }
                }
                let reg = Reg {
                    ekind: *ekind,
                    ent: ent.clone(),
                    key,
                };
                self.mark_purged(reg, k, state, purged)?;
            }
            if *ekind == EntKind::Note as i64 {
                let mut changed = false;
                for (k, what, tag, state) in self.tags_rows(ent)? {
                    let want = if self.unseen(k, own)? {
                        S_PURGED
                    } else if state != S_PURGED {
                        state
                    } else if what == T_ORDER {
                        R_DOMINATED
                    } else {
                        R_LIVE
                    };
                    if want != state {
                        self.set_tag_state(ent, k, what, &tag, want)?;
                        changed = true;
                    }
                }
                if changed {
                    self.notes.insert(ent.clone());
                    self.touched.insert((*ekind, ent.clone()));
                }
            }
            if *ekind == deck {
                for k in self.ent_ops_of(deck, ent, E_MOVE)? {
                    let ed = self.edit_at(k)?;
                    let reg = Reg::new(ed.kind, &ed.entity, &ed.key);
                    let theirs = eff.get(&(reg.ekind, reg.ent.clone())).unwrap_or(&none);
                    let purged = self.unseen(k, own)? || self.unseen(k, theirs)?;
                    if let Some(state) = self.reg_state(&reg, k)? {
                        self.mark_purged(reg, k, state, purged)?;
                    }
                }
            }
        }
        Ok(ents.len() as u64)
    }

    fn mark_purged(&mut self, reg: Reg, k: i64, state: i64, purged: bool) -> Result<(), String> {
        let want = match (purged, state == S_PURGED) {
            (true, false) => S_PURGED,
            (false, true) => R_DOMINATED,
            _ => return Ok(()),
        };
        self.set_reg_state(&reg, k, want)?;
        self.alias_purge_flipped();
        // 挪卡修改清除与否，决定它算不算目标牌组上与删除并发的改动（`others_of` 的 [E_MOVE]）：
        // 牌组的扣住也得重看，和写入挪卡修改时（`derive.rs`）一样把牌组记进这一批。
        if reg.ekind == EntKind::Card as i64 && reg.key == key_bytes("deck") {
            if let Some(d) = self.move_target(k)? {
                self.touched.insert((EntKind::Deck as i64, d));
            }
        }
        self.touched.insert((reg.ekind, reg.ent.clone()));
        self.regs.insert(reg);
        Ok(())
    }

    /// 卡的 `deck` 写入 [k] 挪进了哪个牌组；值不是字符串就不算挪卡（与 `derive.rs` 记 [E_MOVE] 时同一种解析）。
    fn move_target(&self, k: i64) -> Result<Option<Ref>, String> {
        Ok(
            match self
                .t
                .edit_value(k)?
                .and_then(|v| serde_json::from_str::<Value>(&v).ok())
            {
                Some(Value::String(d)) => Some(Ref::of(&Key::of(&d))),
                _ => None,
            },
        )
    }

    fn set_tag_state(
        &self,
        note: &Ref,
        k: i64,
        what: i64,
        tag: &str,
        state: i64,
    ) -> Result<(), String> {
        self.t
            .conn()
            .prepare_cached(
                "UPDATE tag_ix SET state = ?6 WHERE col = ?1 AND note = ?2 AND k = ?3 AND what = ?4 AND tag = ?5",
            )
            .map_err(sql)?
            .execute(params![self.col, note, k, what, tag, state])
            .map_err(sql)?;
        Ok(())
    }

    /// 标成「已清除」、真相层里还是完整内容的操作，按操作号升序。
    pub fn purge_due(&self) -> Result<Vec<OpId>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT k FROM reg_ix WHERE col = ?1 AND state = ?2 \
                 UNION SELECT k FROM tag_ix WHERE col = ?1 AND state = ?2",
            )
            .map_err(sql)?;
        let ks: Vec<i64> = stmt
            .query_map(params![self.col, S_PURGED], |r| r.get(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        let mut out = Vec::with_capacity(ks.len());
        for k in ks {
            out.push(self.t.id_of_key(k)?);
        }
        out.sort();
        Ok(out)
    }

    /// 把「已清除」的操作在真相层落成空洞（本机执行 Purge；设计 §3.2）。先收尾、落完再收尾。返回落了几条。
    pub fn execute_purges(&mut self) -> Result<u64, String> {
        self.settle()?;
        let due = self.purge_due()?;
        for id in &due {
            let Some(e) = self.t.entry(self.col, id)? else {
                continue;
            };
            self.remove(&e)?;
            self.t.advance_purge(self.col, id)?;
        }
        if !due.is_empty() {
            self.settle()?;
        }
        Ok(due.len() as u64)
    }

    /// 有生效的清除的实体。
    pub fn purged_entities(&self) -> Result<Vec<(EntKind, Ref)>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT DISTINCT ekind, ent FROM purge_ix WHERE col = ?1 AND state = 1 ORDER BY ekind, ent",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map([self.col], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, Ref>(1)?))
            })
            .map_err(sql)?;
        let mut out = Vec::new();
        for row in rows {
            let (kind, ent) = row.map_err(sql)?;
            out.push((ent_kind(kind)?, ent));
        }
        Ok(out)
    }

    // ------------------------------------------------------------ 扣住的删除

    /// 实体上除 `deleted` 之外、能与删除并发的操作：(信封, 0 修改 / 1 复习 / 2 挪进来的卡)。
    fn others_of(&mut self, ekind: i64, ent: &Ref) -> Result<Vec<(Head, usize)>, String> {
        let mut out = Vec::new();
        let deleted = key_bytes("deleted");
        for (key, k, state) in self.rows_of(ekind, ent)? {
            if key == deleted || state == S_PURGED {
                continue;
            }
            let h = self.head(k)?;
            if !self.stamped(&h, k)? {
                out.push((h, 0));
            }
        }
        if ekind == EntKind::Note as i64 {
            let ks: BTreeSet<i64> = self
                .tags_rows(ent)?
                .into_iter()
                .filter(|r| r.3 != S_PURGED)
                .map(|r| r.0)
                .collect();
            for k in ks {
                let h = self.head(k)?;
                if !self.stamped(&h, k)? {
                    out.push((h, 0));
                }
            }
            for k in self.ent_ops_of(ekind, ent, E_LOG)? {
                out.push((self.head(k)?, 1));
            }
        }
        if ekind == EntKind::Card as i64 {
            let ks: Vec<i64> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached("SELECT k FROM log_ix WHERE col = ?1 AND card = ?2 ORDER BY k")
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, ent], |r| r.get(0))
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            for k in ks {
                out.push((self.head(k)?, 1));
            }
        }
        if ekind == EntKind::Deck as i64 {
            for k in self.ent_ops_of(ekind, ent, E_MOVE)? {
                let ed = self.edit_at(k)?;
                if ed.stamp.is_some() {
                    continue;
                }
                let reg = Reg::new(ed.kind, &ed.entity, &ed.key);
                if self.reg_state(&reg, k)? == Some(S_PURGED) {
                    continue;
                }
                out.push((self.head(k)?, 2));
            }
        }
        let purges = self.keys_of(
            "SELECT k FROM purge_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND state = ?4 ORDER BY k",
            ekind,
            ent,
            R_LIVE,
        )?;
        for k in purges {
            out.push((self.head(k)?, 0));
        }
        Ok(out)
    }

    /// 重看一个实体上的删除：哪些因作者不可信而不执行，哪些被并发的改动扣住。返回它有没有 `deleted` 写入。
    fn weigh_holds(&mut self, ekind: i64, ent: &Ref) -> Result<bool, String> {
        struct Write {
            k: i64,
            state: i64,
            head: Head,
            /// 能被扣住的删除：不带旧戳、值是整数、作者可信。
            delete: bool,
            distrusted: bool,
        }
        let reg = Reg {
            ekind,
            ent: ent.clone(),
            key: key_bytes("deleted"),
        };
        let rows = self.reg_rows(&reg)?;
        let conn = self.t.conn();
        conn.prepare_cached("DELETE FROM hold_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3")
            .map_err(sql)?
            .execute(params![self.col, ekind, ent])
            .map_err(sql)?;
        if rows.is_empty() {
            return Ok(false);
        }
        let mut writes = Vec::with_capacity(rows.len());
        for &(k, state) in &rows {
            let ed = self.edit_at(k)?;
            let head = self.head(k)?;
            let number = serde_json::from_str::<Value>(&ed.value).is_ok_and(|v| v.is_i64());
            let distrusted = number && self.distrusts(&head.id.device)?;
            writes.push(Write {
                k,
                state,
                head,
                delete: number && ed.stamp.is_none() && !distrusted,
                distrusted,
            });
        }
        let others = if writes.iter().any(|w| w.delete) {
            self.others_of(ekind, ent)?
        } else {
            Vec::new()
        };
        let mut changed = false;
        for d in &writes {
            let mut want = if d.state < R_DOMINATED {
                R_DOMINATED
            } else {
                d.state
            };
            if d.distrusted {
                want = S_DISTRUSTED;
            } else if d.delete {
                // 被同一个寄存器上见过它的写入（恢复 / 再删）盖掉了：不是冲突——裁决之后就是这样。
                let settled = writes
                    .iter()
                    .any(|w| !w.distrusted && w.k != d.k && w.head.saw(&d.head.id));
                let mut counts = [0i64; 3];
                if !settled {
                    for (x, class) in &others {
                        if !d.head.saw(&x.id) && !x.saw(&d.head.id) {
                            counts[*class] += 1;
                        }
                    }
                }
                if counts.iter().any(|&n| n > 0) {
                    want = S_HELD;
                    conn.prepare_cached(
                        "INSERT INTO hold_ix (col, ekind, ent, k, edits, reviews, moves) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    )
                    .map_err(sql)?
                    .execute(params![self.col, ekind, ent, d.k, counts[0], counts[1], counts[2]])
                    .map_err(sql)?;
                }
            }
            if want != d.state {
                self.set_reg_state(&reg, d.k, want)?;
                changed = true;
            }
        }
        if changed {
            self.regs.insert(reg);
        }
        Ok(true)
    }

    /// 被扣住、等用户裁决的删除，按 (实体种类, 实体, 操作) 序。
    pub fn holds(&self) -> Result<Vec<Hold>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT ekind, ent, k, edits, reviews, moves FROM hold_ix WHERE col = ?1 ORDER BY ekind, ent, k",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map([self.col], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, Ref>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, i64>(5)?,
                ))
            })
            .map_err(sql)?;
        let mut out = Vec::new();
        for row in rows {
            let (kind, entity, k, edits, reviews, moves) = row.map_err(sql)?;
            out.push(Hold {
                kind: ent_kind(kind)?,
                entity,
                op: self.t.id_of_key(k)?,
                edits: edits as u64,
                reviews: reviews as u64,
                moves: moves as u64,
            });
        }
        Ok(out)
    }

    /// 因作者还没被信任而不执行的删除与清除，按操作号升序。
    pub fn distrusted(&self) -> Result<Vec<OpId>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT k FROM reg_ix WHERE col = ?1 AND state = ?2 \
                 UNION SELECT k FROM purge_ix WHERE col = ?1 AND state = ?2",
            )
            .map_err(sql)?;
        let ks: Vec<i64> = stmt
            .query_map(params![self.col, S_DISTRUSTED], |r| r.get(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        let mut out = Vec::with_capacity(ks.len());
        for k in ks {
            out.push(self.t.id_of_key(k)?);
        }
        out.sort();
        Ok(out)
    }

    // ------------------------------------------------------------ 标签

    fn weigh_tags(&mut self, note: &Ref) -> Result<(), String> {
        let rows = self.tags_rows(note)?;
        let mut removes: Vec<(&str, Head)> = Vec::new();
        let mut orders: Vec<(usize, Head)> = Vec::new();
        for (i, (k, what, tag, state)) in rows.iter().enumerate() {
            if *state == S_PURGED {
                continue;
            }
            match *what {
                T_REMOVE => removes.push((tag.as_str(), self.head(*k)?)),
                T_ORDER => orders.push((i, self.head(*k)?)),
                _ => {}
            }
        }
        let heads: Vec<Head> = orders.iter().map(|(_, h)| h.clone()).collect();
        let ranks = mvr(&heads);
        for (i, (k, what, tag, state)) in rows.iter().enumerate() {
            if *state == S_PURGED {
                continue;
            }
            let want = match *what {
                T_ADD if removes.iter().any(|(t, _)| *t == tag.as_str()) => {
                    let id = self.head(*k)?.id;
                    let gone = removes
                        .iter()
                        .any(|(t, r)| *t == tag.as_str() && r.saw(&id));
                    if gone { R_DOMINATED } else { R_LIVE }
                }
                T_ORDER => {
                    let at = orders
                        .iter()
                        .position(|(j, _)| *j == i)
                        .expect("collected above");
                    ranks[at]
                }
                _ => R_LIVE,
            };
            if want != *state {
                self.set_tag_state(note, *k, *what, tag, want)?;
            }
        }
        Ok(())
    }

    /// 顺序提示带的标签：`TagOrder` 的列表，或 `tags` 整列表写入的那个数组。
    fn order_at(&self, k: i64) -> Result<Vec<String>, String> {
        let e = self
            .t
            .entry_by_key(k)?
            .ok_or_else(|| format!("gen4 index: row {k} has no op"))?;
        Ok(match body_of(&e) {
            Some(Body4::TagOrder { tags, .. }) => tags,
            Some(Body4::Edit(ed)) => match serde_json::from_str::<Value>(&ed.value) {
                Ok(Value::Array(xs)) => xs
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect(),
                _ => Vec::new(),
            },
            _ => Vec::new(),
        })
    }

    /// 笔记现在的标签（协议 3 `current_tags`）：活着的添加点按标签取最早的一个；顺序先按生效的顺序提示，不在提示里的
    /// 按最早添加的 (wall, logical, 设备)、再按标签。
    pub fn tags_of(&self, note: &Key) -> Result<Vec<String>, String> {
        let rows = self.tags_rows(&Ref::of(note))?;
        let mut first: BTreeMap<&str, (i64, i64, [u8; 16])> = BTreeMap::new();
        let mut hint: Vec<String> = Vec::new();
        for (k, what, tag, state) in &rows {
            if *what == T_ADD && *state == R_LIVE {
                let h = self
                    .t
                    .head_by_key(*k)?
                    .ok_or_else(|| format!("gen4 index: row {k} has no op"))?;
                let at = (h.wall, h.logical, h.id.device.0);
                match first.get(tag.as_str()) {
                    Some(old) if *old <= at => {}
                    _ => {
                        first.insert(tag.as_str(), at);
                    }
                }
            } else if *what == T_ORDER && *state == R_WINNER {
                hint = self.order_at(*k)?;
            }
        }
        let mut out: Vec<String> = hint
            .into_iter()
            .filter(|t| first.contains_key(t.as_str()))
            .collect();
        let mut rest: Vec<(&(i64, i64, [u8; 16]), &str)> = first
            .iter()
            .filter(|(t, _)| !out.iter().any(|o| o.as_str() == **t))
            .map(|(t, at)| (at, *t))
            .collect();
        rest.sort();
        out.extend(rest.into_iter().map(|(_, t)| t.to_owned()));
        out.dedup();
        Ok(out)
    }

    /// 有标签操作的笔记（含标签已经全删掉的）。
    pub fn tagged_notes(&self) -> Result<Vec<Ref>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached("SELECT DISTINCT note FROM tag_ix WHERE col = ?1 ORDER BY note")
            .map_err(sql)?;
        let rows = stmt.query_map([self.col], |r| r.get(0)).map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    // ------------------------------------------------------------ 媒体

    fn weigh_media(&mut self, name: &str) -> Result<(), String> {
        let rows: Vec<(i64, i64)> = {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached(
                    "SELECT k, state FROM media_ix WHERE col = ?1 AND name = ?2 ORDER BY k",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![self.col, name], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)?
        };
        let mut heads = Vec::with_capacity(rows.len());
        for &(k, _) in &rows {
            heads.push(self.head(k)?);
        }
        for (&(k, state), want) in rows.iter().zip(mvr(&heads)) {
            if want != state {
                self.t
                    .conn()
                    .prepare_cached(
                        "UPDATE media_ix SET state = ?4 WHERE col = ?1 AND name = ?2 AND k = ?3",
                    )
                    .map_err(sql)?
                    .execute(params![self.col, name, k, want])
                    .map_err(sql)?;
            }
        }
        Ok(())
    }

    /// 全部媒体名现在绑定的内容：(名字, sha256, 字节数)，按名字升序。
    pub fn media(&self) -> Result<Vec<(String, [u8; 32], u64)>, String> {
        let rows: Vec<(String, i64)> = {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached(
                    "SELECT name, k FROM media_ix WHERE col = ?1 AND state = ?2 ORDER BY name",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![self.col, R_WINNER], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)?
        };
        let mut out = Vec::with_capacity(rows.len());
        for (name, k) in rows {
            let e = self
                .t
                .entry_by_key(k)?
                .ok_or_else(|| format!("gen4 index: row {k} has no op"))?;
            match body_of(&e) {
                Some(Body4::Media { sha256, size, .. }) => out.push((name, sha256, size)),
                _ => return Err(format!("gen4 index: row {k} is not a media binding")),
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};

    use proptest::prelude::*;

    use super::*;
    use crate::gen4::op::tests::{id, native_edit, sample_log};
    use crate::gen4::op::{Log4, Op4};
    use crate::store::gen4::derive::tests::{
        assert_rebuild_is_identity, canon, heritage, native, note, op, stamp, with,
    };
    use crate::store::gen4::truth::{TRUST_PENDING, Truth};

    const CARD: u8 = 8;

    fn edit(key: &str, value: &str) -> Body4 {
        Body4::Edit(Edit4 {
            key: key.to_owned(),
            value: value.to_owned(),
            ..native_edit()
        })
    }

    fn card_edit(key: &str, value: &str) -> Body4 {
        Body4::Edit(Edit4 {
            kind: EntKind::Card,
            entity: Key::Uuid(id(CARD)),
            key: key.to_owned(),
            value: value.to_owned(),
            ..native_edit()
        })
    }

    fn add(tag: &str) -> Body4 {
        Body4::TagAdd {
            note: note(),
            tag: tag.to_owned(),
        }
    }

    fn remove(tag: &str) -> Body4 {
        Body4::TagRemove {
            note: note(),
            tag: tag.to_owned(),
        }
    }

    fn order(tags: &[&str]) -> Body4 {
        Body4::TagOrder {
            note: note(),
            tags: tags.iter().map(|t| t.to_string()).collect(),
        }
    }

    fn purge(kind: EntKind, entity: Key) -> Body4 {
        Body4::Purge { kind, entity }
    }

    fn review(name: &str) -> Body4 {
        Body4::Log(Log4 {
            id: Key::Text(name.to_owned()),
            card: Key::Uuid(id(CARD)),
            note: Some(note()),
            ..sample_log()
        })
    }

    fn oid(dev: u8, seq: u64) -> OpId {
        OpId {
            device: id(dev),
            seq,
        }
    }

    fn tags(ix: &Index<'_, '_>) -> Vec<String> {
        ix.tags_of(&note()).unwrap()
    }

    #[test]
    fn tags_are_an_observed_remove_set_and_a_concurrent_add_wins() {
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                native(t, &mut ix, col, &op(0xa1, 1, 100, &[], &add("x")));
                native(t, &mut ix, col, &op(0xa2, 1, 90, &[], &add("x")));
                // a1 删掉 x：它只见过自己的那个添加点，a2 并发加的留着。
                native(t, &mut ix, col, &op(0xa1, 2, 110, &[], &remove("x")));
                ix.settle()?;
                assert_eq!(tags(&ix), ["x"]);
                // 见过 a2 的添加之后再删：没了。
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 3, 120, &[(0xa2, 1)], &remove("x")),
                );
                ix.settle()?;
                assert!(tags(&ix).is_empty());
                // 没有顺序提示：按最早添加的时刻。
                native(t, &mut ix, col, &op(0xa2, 2, 300, &[], &add("y")));
                native(t, &mut ix, col, &op(0xa1, 4, 200, &[], &add("z")));
                ix.settle()?;
                assert_eq!(tags(&ix), ["z", "y"]);
                // 顺序提示里已经不在的标签不出现；不在提示里的排后面。
                native(t, &mut ix, col, &op(0xa2, 3, 310, &[], &add("w")));
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 5, 210, &[], &order(&["y", "gone", "z"])),
                );
                ix.settle()?;
                assert_eq!(tags(&ix), ["y", "z", "w"]);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    #[test]
    fn a_whole_list_write_adds_each_tag_and_is_not_a_register() {
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let whole = Body4::Edit(Edit4 {
                    key: "tags".into(),
                    value: r#"["b","a"]"#.into(),
                    stamp: Some(stamp("w1", 1, r#"{"vv":{}}"#, 50)),
                    ..native_edit()
                });
                heritage(t, &mut ix, col, op(0xd1, 1, 50, &[], &whole));
                ix.settle()?;
                assert_eq!(tags(&ix), ["b", "a"]);
                assert!(ix.register(EntKind::Note, &note(), "tags")?.is_empty());
                // 旧戳照样进闭包。
                assert_eq!(ix.closure(&id(0xd1))?.map(|c| c.0), Some(1));
                // 见过它的删除抹掉它带来的添加点。
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 1, 60, &[(0xd1, 1)], &remove("b")),
                );
                ix.settle()?;
                assert_eq!(tags(&ix), ["a"]);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    #[test]
    fn order_hints_and_media_bindings_are_causal_first_then_by_clock() {
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let media = |n: u8| Body4::Media {
                    name: "a.png".into(),
                    sha256: [n; 32],
                    size: u64::from(n),
                };
                native(t, &mut ix, col, &op(0xa3, 1, 1, &[], &add("p")));
                native(t, &mut ix, col, &op(0xa3, 2, 2, &[], &add("q")));
                // 并发：钟大的赢。
                native(t, &mut ix, col, &op(0xa1, 1, 100, &[], &order(&["p", "q"])));
                native(t, &mut ix, col, &op(0xa2, 1, 200, &[], &order(&["q", "p"])));
                native(t, &mut ix, col, &op(0xa1, 2, 100, &[], &media(1)));
                native(t, &mut ix, col, &op(0xa2, 2, 200, &[], &media(2)));
                ix.settle()?;
                assert_eq!(tags(&ix), ["q", "p"]);
                assert_eq!(ix.media()?, [("a.png".to_owned(), [2; 32], 2)]);
                // 见过对方之后再写：钟再小也赢。
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 3, 101, &[(0xa2, 2)], &order(&["p", "q"])),
                );
                native(t, &mut ix, col, &op(0xa1, 4, 102, &[(0xa2, 2)], &media(3)));
                ix.settle()?;
                assert_eq!(tags(&ix), ["p", "q"]);
                assert_eq!(ix.media()?, [("a.png".to_owned(), [3; 32], 3)]);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    #[test]
    fn a_purge_clears_what_did_not_see_it_and_later_writes_revive() {
        with(|t, col| {
            let f = native_edit().key;
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                native(t, &mut ix, col, &op(0xa1, 1, 100, &[], &edit(&f, "\"x\"")));
                native(t, &mut ix, col, &op(0xa1, 2, 101, &[], &add("t")));
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 3, 102, &[], &edit("deleted", "5")),
                );
                native(t, &mut ix, col, &op(0xa2, 1, 100, &[], &edit(&f, "\"y\"")));
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa3, 1, 200, &[(0xa1, 3)], &purge(EntKind::Note, note())),
                );
                // 清除之后的写入：见过它，留着。
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 4, 300, &[(0xa3, 1)], &edit(&f, "\"z\"")),
                );
                // 迟到的、没见过清除的写入：也清。
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa2, 2, 400, &[], &edit(&f, "\"late\"")),
                );
                ix.settle()?;
                assert_eq!(ix.value(EntKind::Note, &note(), &f)?, Some("\"z\"".into()));
                assert!(tags(&ix).is_empty());
                // `deleted` 不是内容：清除不动它。
                assert_eq!(
                    ix.value(EntKind::Note, &note(), "deleted")?,
                    Some("5".into())
                );
                assert_eq!(ix.purged_entities()?, [(EntKind::Note, Ref::of(&note()))]);
                let due = [oid(0xa1, 1), oid(0xa1, 2), oid(0xa2, 1), oid(0xa2, 2)];
                assert_eq!(ix.purge_due()?, due);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
            // 落成空洞：结果不变，待清的没了。
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                assert_eq!(ix.execute_purges()?, 4);
                assert!(ix.purge_due()?.is_empty());
                assert!(!t.entry(col, &oid(0xa1, 1))?.unwrap().is_whole());
                assert!(t.entry(col, &oid(0xa1, 4))?.unwrap().is_whole());
                assert_eq!(ix.value(EntKind::Note, &note(), &f)?, Some("\"z\"".into()));
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    #[test]
    fn purging_a_deck_clears_the_moves_into_it() {
        with(|t, col| {
            let card = Key::Uuid(id(CARD));
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 1, 100, &[], &card_edit("deck", "\"D1\"")),
                );
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 2, 110, &[], &card_edit("deck", "\"D2\"")),
                );
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa2, 1, 200, &[], &purge(EntKind::Deck, Key::of("D2"))),
                );
                ix.settle()?;
                // 挪进 D2 的那条清掉了，卡回到之前的牌组。
                assert_eq!(
                    ix.value(EntKind::Card, &card, "deck")?,
                    Some("\"D1\"".into())
                );
                assert_eq!(ix.purge_due()?, [oid(0xa1, 2)]);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    fn deck_edit(deck: &str, key: &str, value: &str) -> Body4 {
        Body4::Edit(Edit4 {
            kind: EntKind::Deck,
            entity: Key::of(deck),
            key: key.to_owned(),
            value: value.to_owned(),
            ..native_edit()
        })
    }

    fn deck_hold_moves(ix: &Index<'_, '_>) -> Vec<(EntKind, OpId, u64)> {
        ix.holds()
            .unwrap()
            .iter()
            .map(|h| (h.kind, h.op, h.moves))
            .collect()
    }

    /// 牌组的删除被并发的挪卡扣住；之后那张卡被清除、挪卡修改跟着清掉：牌组上不再有并发的改动，删除生效。
    /// 逐条维护要和重建一样重看牌组的扣住（清除只碰了卡，牌组上没有 Purge）。
    #[test]
    fn purging_a_card_releases_the_deck_delete_its_move_held() {
        with(|t, col| {
            let card = Key::Uuid(id(CARD));
            let d = Key::of("D");
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 1, 100, &[], &deck_edit("D", "deleted", "100")),
                );
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa2, 1, 110, &[], &card_edit("deck", "\"D\"")),
                );
                ix.settle()?;
                assert_eq!(deck_hold_moves(&ix), [(EntKind::Deck, oid(0xa1, 1), 1)]);
                assert_eq!(ix.value(EntKind::Deck, &d, "deleted")?, None);
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa3, 1, 120, &[], &purge(EntKind::Card, card.clone())),
                );
                ix.settle()?;
                assert!(deck_hold_moves(&ix).is_empty());
                assert_eq!(ix.value(EntKind::Deck, &d, "deleted")?, Some("100".into()));
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 反方向：清除卡的那条被分叉对调换掉，挪卡修改恢复，牌组的删除要重新被扣住。
    #[test]
    fn a_fork_swapping_out_a_card_purge_holds_the_deck_delete_again() {
        use crate::gen4::heritage::HeritageSlot;
        use crate::gen4::translate::T_VERSION;
        use crate::store::gen4::truth::Put;
        let card = Key::Uuid(id(CARD));
        let slot = |fp: u8, body: &Body4| HeritageSlot::op([fp; 8], op(0xd1, 1, 120, &[], body));
        let purge_slot = slot(9, &purge(EntKind::Card, card.clone()));
        let other_slot = slot(1, &edit(&native_edit().key, "\"x\""));
        let mut replaced = 0;
        let mut outcomes = Vec::new();
        for order in [[&purge_slot, &other_slot], [&other_slot, &purge_slot]] {
            outcomes.push(with(|t, col| {
                let got = t
                    .tx(|t| {
                        let mut ix = Index::new(t, col);
                        native(
                            t,
                            &mut ix,
                            col,
                            &op(0xa1, 1, 100, &[], &deck_edit("D", "deleted", "100")),
                        );
                        native(
                            t,
                            &mut ix,
                            col,
                            &op(0xa2, 1, 110, &[], &card_edit("deck", "\"D\"")),
                        );
                        ix.settle()?;
                        for s in order {
                            let before = t.entry(col, &s.id)?;
                            match t.put_heritage(col, &id(0xc0), s, T_VERSION)? {
                                Put::Inserted | Put::Yielded => {
                                    ix.add(&t.entry(col, &s.id)?.expect("put"))?
                                }
                                Put::Replaced => {
                                    replaced += 1;
                                    ix.remove(&before.expect("replaced"))?;
                                    ix.add(&t.entry(col, &s.id)?.expect("put"))?;
                                }
                                _ => {}
                            }
                            ix.settle()?;
                        }
                        Ok((
                            deck_hold_moves(&ix),
                            ix.value(EntKind::Deck, &Key::of("D"), "deleted")?,
                        ))
                    })
                    .unwrap();
                assert_rebuild_is_identity(t, col);
                (canon(t, col), got)
            }));
        }
        assert!(replaced > 0, "neither order swapped the slot");
        assert_eq!(outcomes[0], outcomes[1]);
    }

    #[test]
    fn a_delete_concurrent_with_other_work_is_held_until_someone_settles_it() {
        with(|t, col| {
            let f = native_edit().key;
            let card = Key::Uuid(id(CARD));
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                native(t, &mut ix, col, &op(0xa1, 1, 100, &[], &edit(&f, "\"x\"")));
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 2, 110, &[], &edit("deleted", "110")),
                );
                ix.settle()?;
                assert_eq!(
                    ix.value(EntKind::Note, &note(), "deleted")?,
                    Some("110".into())
                );
                // 另一台设备并发改了这条笔记：删除扣住。
                native(t, &mut ix, col, &op(0xa2, 1, 120, &[], &edit(&f, "\"y\"")));
                // 卡：删除与一次并发的复习。
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 3, 130, &[], &card_edit("deleted", "130")),
                );
                native(t, &mut ix, col, &op(0xa2, 2, 140, &[], &review("L1")));
                ix.settle()?;
                assert_eq!(ix.value(EntKind::Note, &note(), "deleted")?, None);
                assert_eq!(ix.value(EntKind::Card, &card, "deleted")?, None);
                // 笔记的删除：并发的修改 1 条、名下并发的复习 1 条；卡的删除：并发的复习 1 条。
                assert_eq!(
                    ix.holds()?
                        .iter()
                        .map(|h| (h.kind, h.op, h.edits, h.reviews, h.moves))
                        .collect::<Vec<_>>(),
                    [
                        (EntKind::Note, oid(0xa1, 2), 1, 1, 0),
                        (EntKind::Card, oid(0xa1, 3), 0, 1, 0),
                    ]
                );
                // 裁决：见过双方之后再删一次。旧的那条被它盖掉，新的没有并发的改动。
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 4, 150, &[(0xa2, 2)], &edit("deleted", "150")),
                );
                ix.settle()?;
                assert_eq!(
                    ix.value(EntKind::Note, &note(), "deleted")?,
                    Some("150".into())
                );
                assert_eq!(ix.holds()?.len(), 1);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    #[test]
    fn deletes_and_purges_from_an_untrusted_device_wait_for_the_local_decision() {
        with(|t, col| {
            let f = native_edit().key;
            t.tx(|t| {
                t.set_trust(col, &id(0xa2), Some(TRUST_PENDING), 7)?;
                let mut ix = Index::new(t, col);
                native(t, &mut ix, col, &op(0xa1, 1, 100, &[], &edit(&f, "\"x\"")));
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa2, 1, 200, &[(0xa1, 1)], &edit("deleted", "200")),
                );
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa2, 2, 210, &[(0xa1, 1)], &purge(EntKind::Note, note())),
                );
                // 它别的操作照常。
                native(t, &mut ix, col, &op(0xa2, 3, 220, &[(0xa1, 1)], &add("t")));
                ix.settle()?;
                assert_eq!(ix.value(EntKind::Note, &note(), "deleted")?, None);
                assert_eq!(ix.value(EntKind::Note, &note(), &f)?, Some("\"x\"".into()));
                assert_eq!(tags(&ix), ["t"]);
                assert_eq!(ix.distrusted()?, [oid(0xa2, 1), oid(0xa2, 2)]);
                assert!(ix.purged_entities()?.is_empty());
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
            // 本机确认了这台设备：删除落下，清除生效（清掉没见过它的内容）。
            t.tx(|t| {
                t.set_trust(col, &id(0xa2), None, 0)?;
                let mut ix = Index::new(t, col);
                ix.trust_changed();
                ix.settle()?;
                assert_eq!(
                    ix.value(EntKind::Note, &note(), "deleted")?,
                    Some("200".into())
                );
                assert_eq!(ix.value(EntKind::Note, &note(), &f)?, None);
                assert!(ix.distrusted()?.is_empty());
                assert_eq!(ix.purge_due()?, [oid(0xa1, 1)]);
                // a2 自己的标签在它的清除之后写（同一台设备、seq 更大）：留着。
                assert_eq!(tags(&ix), ["t"]);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 一条随机操作：(设备, 种类, 依赖见过谁, 时刻, 参数)。
    type Step = (u8, u8, Vec<(u8, u8)>, u16, u8);

    fn arb_steps() -> impl Strategy<Value = Vec<Step>> {
        proptest::collection::vec(
            (
                0u8..3,
                0u8..14,
                proptest::collection::vec((0u8..3, 0u8..5), 0..3),
                0u16..40,
                0u8..2,
            ),
            1..18,
        )
    }

    fn logs_of(steps: &[Step]) -> Vec<Vec<Op4>> {
        let f = native_edit().key;
        let mut logs: BTreeMap<u8, Vec<Op4>> = BTreeMap::new();
        for (dev, kind, deps, wall, arg) in steps {
            let seen: Vec<(u8, u64)> = deps
                .iter()
                .filter(|(d, s)| d != dev && *s > 0)
                .map(|(d, s)| (0xa0 + d, u64::from(*s)))
                .collect();
            let log = logs.entry(0xa0 + dev).or_default();
            let seq = log.len() as u64 + 1;
            let body = match kind {
                0 => edit(&f, &format!("\"v{arg}\"")),
                1 => edit("deleted", &wall.to_string()),
                2 => edit("deleted", "null"),
                3 => add(&format!("t{arg}")),
                4 => remove(&format!("t{arg}")),
                5 => order(&[&format!("t{arg}"), "t0"]),
                6 => purge(EntKind::Note, note()),
                7 => review(&format!("L{dev}-{seq}")),
                8 => Body4::Media {
                    name: format!("m{arg}"),
                    sha256: [seq as u8; 32],
                    size: seq,
                },
                9 => card_edit("deck", &format!("\"D{arg}\"")),
                10 => purge(EntKind::Deck, Key::of(&format!("D{arg}"))),
                11 => deck_edit(&format!("D{arg}"), "deleted", &wall.to_string()),
                12 => purge(EntKind::Card, Key::Uuid(id(CARD))),
                _ => card_edit("deleted", &wall.to_string()),
            };
            log.push(op(0xa0 + dev, seq, i64::from(*wall), &seen, &body));
        }
        logs.into_values().collect()
    }

    /// 按 [order] 交错着落各条日志。[trust_first]：不可信的设备一开始就标，否则全部落完才标。返回派生表。
    fn build(
        logs: &[Vec<Op4>],
        order: &[usize],
        settle_each: bool,
        untrusted: Option<u8>,
        trust_first: bool,
    ) -> BTreeSet<String> {
        with(|t, col| {
            let mark = |t: &Truth<'_>| -> Result<(), String> {
                if let Some(d) = untrusted {
                    t.set_trust(col, &id(0xa0 + d), Some(TRUST_PENDING), 1)?;
                }
                Ok(())
            };
            t.tx(|t| {
                if trust_first {
                    mark(t)?;
                }
                let mut ix = Index::new(t, col);
                let mut next = vec![0usize; logs.len()];
                let mut turn = 0;
                loop {
                    let open: Vec<usize> = (0..logs.len())
                        .filter(|&i| next[i] < logs[i].len())
                        .collect();
                    if open.is_empty() {
                        break;
                    }
                    let pick = open[order[turn % order.len()] % open.len()];
                    turn += 1;
                    native(t, &mut ix, col, &logs[pick][next[pick]]);
                    next[pick] += 1;
                    if settle_each {
                        ix.settle()?;
                    }
                }
                ix.settle()?;
                if !trust_first {
                    mark(t)?;
                    ix.trust_changed();
                    ix.settle()?;
                }
                Ok(())
            })
            .unwrap();
            let incremental = canon(t, col);
            assert_rebuild_is_identity(t, col);
            // 把已清除的落成空洞：没被清除的行一条不变，重建仍然逐行相同。
            let kept = |rows: &BTreeSet<String>| -> BTreeSet<String> {
                rows.iter()
                    .filter(|r| !r.starts_with("ent_ops ") && !r.ends_with("Integer(-1)"))
                    .cloned()
                    .collect()
            };
            t.tx(|t| Index::new(t, col).execute_purges()).unwrap();
            assert_eq!(kept(&incremental), kept(&canon(t, col)));
            assert_rebuild_is_identity(t, col);
            incremental
        })
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(64))]

        /// 同一批日志，不管各条之间怎么交错着到、中途收不收尾、信任状态先给还是后给，派生表都一样，重建也一样；
        /// 已清除的操作落不落成空洞，剩下的行不变。
        #[test]
        fn the_semantic_layer_is_a_function_of_the_log_and_the_trust_state(
            steps in arb_steps(),
            order_a in proptest::collection::vec(0usize..6, 1..12),
            order_b in proptest::collection::vec(0usize..6, 1..12),
            untrusted in proptest::option::of(0u8..3),
        ) {
            let logs = logs_of(&steps);
            let a = build(&logs, &order_a, true, untrusted, true);
            let b = build(&logs, &order_b, false, untrusted, false);
            prop_assert_eq!(a, b);
        }
    }
}
