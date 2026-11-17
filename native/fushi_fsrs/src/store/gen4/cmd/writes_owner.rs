//! 本机写入的实体归属闸（BUG-4836，第五波 G9 身份收尾）：同一个新代库里放着几个集合（app 的多份 profile、无头服务端
//! 一门语言一份），ID 却不再按 uid 加盐（设计 2026-11-11 §2、G9-7）。调用方拿 A 的命令点名 B 的实体（切换配置前留在
//! UI 里的 ID、点名 A 却带 B 的 ID 的远程请求）时，以前这条操作照样落进 A 的日志，成了一条指向「A 里不存在的实体」的
//! 悬空操作；A 当时看不到后果，可 A 的集合之后并进 B（`.fushisrs` 确认导入、关联已有集合，并入 = 操作并集）时它对 B
//! 的同名实体生效——B 的笔记字段、标签、旗标、暂停被 A 改掉（协议 3 BUG-4626 在新代回来了）。
//!
//! # 判据（[Session::foreign]）
//!
//! 一条本机操作指向的实体 E（修改的实体、标签的笔记、清除的实体、日志的笔记——日志没带笔记时是卡）是**别人的**，当且仅当：
//!
//! 1. 库里还有别的集合（一个集合的库——绝大多数用户——一条查询就放行，[Session::others]）；
//! 2. 别的集合里有 E：有 E 的身份记录（`ent_ix.id`）、或 E 是别的集合里某个成员的规范 ID（`alias_ix.canon`，迁移来的
//!    带盐存量）、或别的集合里有 E 这张卡（`cards.id`，缓存层按规范 ID 建）；
//! 3. 本集合里一点痕迹都没有：没有身份记录、不是别名类的规范 ID、没有卡片行、没有修改 / 日志 / 标签索引行，也不是这一批
//!    里前面（或后面）要建的实体（[Born]）；先不收尾查一遍，没查到再把这条命令已写的操作收尾后查第二遍（同批先写后读：
//!    换笔记类型时先改类型、后给新卡写血统，收尾之后新卡已物化）。
//!
//! 只有 2 与 3 同时成立才拒绝：ID 不再加盐，两个集合导入同一份内容会有同一个 ID，那是各自的实体，照常写；「哪里都没有的
//! ID」（同批先后到、给还没生成的卡写血统）也照常写——同协议 3 `ownership.rs` 的口径，别人的 ID 对调用方表现为不存在。
//!
//! # 为什么在写入口、不在并入时丢
//!
//! 闸只决定**本机要不要写下**一条操作；写下之后的操作照常传播、照常并集，收段 / 导入 / 并入的语义一个字不改。所以
//! 几台设备算出的状态仍只由同一份操作集合决定（摘要对拍不受影响），并集照样收敛。反过来「并入时丢悬空操作」要给
//! 「当时不存在」定一个跨设备一致的判据，还会误丢合法的先写后有（同批先后到、血统先于卡），是改并集语义。
//!
//! 挡不住的：闸之前已经写下的悬空操作。新代还没发布（换代在同一次推送），协议 3 有 `ownership.rs` 闸、ID 带盐，迁移来的
//! 日志里没有跨 profile 的悬空操作，所以不存在需要清理的存量。远端操作（收段、导入）不经过这里（同协议 3）。
//!
//! # 接入点
//!
//! 调用方给实体 ID 的写命令：`apply_in`（`apply`、`change`、`import_drafts` 与意图命令拼的输入）——别人的那一项不写、
//! `landed` 为 false、下标进回包 `foreign`；`purge`——别人的实体不写清除；`sched`——别人的卡按「没有这张卡」跳过
//! （撤销计入 `blocked`）。
//!
//! # 查询
//!
//! 第 2 条要按 ID 跨集合查：`ent_ix (id)`（`ent_id`）、`alias_ix (canon) WHERE canon != id`（`alias_canon_any`）、
//! `cards (id)`（`cards_id`）三个部分索引，SCHEMA 40023。三个都带条件 `col > 0`（集合号从 1 起，恒成立），只有
//! [THEIRS_SQL] 写这一项：带 `col = ?` 的既有查询推不出它、用不上这些索引，原有的执行计划一条不变（按规范 ID 查别名类
//! 的 `alias_canon` 等，`dispatch_tests` `s1b_statements_use_their_keys` 钉着）。第 3 条全走以 `col` 打头的主键 / 既有索引。执行计划测试
//! `owner_statements_use_an_index` 用同一份 [THEIRS_SQL] / [OURS_SQL]。

use std::collections::HashSet;

use rusqlite::params;

use super::super::super::derive::Ref;
use super::super::super::schema::sql;
use super::{Body, EntKind, Session, ref_of};

/// 库里有没有别的集合：?1 = 本集合。
pub(crate) const OTHERS_SQL: &str = "SELECT EXISTS(SELECT 1 FROM collections WHERE col != ?1)";

/// 别的集合里有没有 E：?1 = E（规范 ID），?2 = 本集合。
pub(crate) const THEIRS_SQL: &str = "SELECT EXISTS(SELECT 1 FROM ent_ix WHERE id = ?1 AND col > 0 AND col != ?2) \
     OR EXISTS(SELECT 1 FROM alias_ix WHERE canon = ?1 AND canon != id AND col > 0 AND col != ?2) \
     OR EXISTS(SELECT 1 FROM cards WHERE id = ?1 AND col > 0 AND col != ?2)";

/// 本集合里有没有 E 的痕迹：?1 = E，?2 = 本集合，?3 = E 的种类（`reg_ix.ekind`）。
pub(crate) const OURS_SQL: &str = "SELECT EXISTS(SELECT 1 FROM ent_ix WHERE col = ?2 AND id = ?1) \
     OR EXISTS(SELECT 1 FROM alias_ix WHERE col = ?2 AND canon = ?1 AND canon != id) \
     OR EXISTS(SELECT 1 FROM cards WHERE col = ?2 AND id = ?1) \
     OR EXISTS(SELECT 1 FROM reg_ix WHERE col = ?2 AND ekind = ?3 AND ent = ?1) \
     OR EXISTS(SELECT 1 FROM log_ix WHERE col = ?2 AND card = ?1) \
     OR EXISTS(SELECT 1 FROM tag_ix WHERE col = ?2 AND note = ?1)";

/// 这一批输入里要建的实体（规范 ID 文本）：算本集合的（第 3 条）。
pub(in crate::store::gen4::cmd) type Born = HashSet<String>;

/// 一条操作体指向的实体（文件头「判据」）：建实体、还原点、并入这类不指向已有实体的为 None。
pub(in crate::store::gen4::cmd) fn target(body: &Body) -> Option<(EntKind, String)> {
    match body {
        Body::Edit(e) => Some((e.kind, e.entity.text())),
        Body::TagAdd { note, .. } | Body::TagRemove { note, .. } | Body::TagOrder { note, .. } => {
            Some((EntKind::Note, note.text()))
        }
        Body::Purge { kind, entity } => Some((*kind, entity.text())),
        Body::Log(l) => Some(match &l.note {
            Some(n) => (EntKind::Note, n.text()),
            None => (EntKind::Card, l.card.text()),
        }),
        _ => None,
    }
}

impl Session<'_, '_> {
    /// 库里有没有别的集合（命令里只问一次：命令在一个写事务里，期间不会多出集合）。
    fn others(&mut self) -> Result<bool, String> {
        if let Some(o) = self.others {
            return Ok(o);
        }
        let o: bool = self
            .t
            .conn()
            .prepare_cached(OTHERS_SQL)
            .map_err(sql)?
            .query_row([self.col], |r| r.get(0))
            .map_err(sql)?;
        self.others = Some(o);
        Ok(o)
    }

    fn ask(&self, q: &str, id: &Ref, kind: Option<EntKind>) -> Result<bool, String> {
        let mut stmt = self.t.conn().prepare_cached(q).map_err(sql)?;
        match kind {
            Some(k) => stmt.query_row(params![id, self.col, k as i64], |r| r.get(0)),
            None => stmt.query_row(params![id, self.col], |r| r.get(0)),
        }
        .map_err(sql)
    }

    /// 实体 [id]（[kind]，规范 ID）是不是别的集合的、本集合碰不得（文件头「判据」）。[born] = 这一批要建的实体。
    pub(in crate::store::gen4::cmd) fn foreign(
        &mut self,
        kind: EntKind,
        id: &str,
        born: &Born,
    ) -> Result<bool, String> {
        if born.contains(id) || !self.others()? {
            return Ok(false);
        }
        let r = ref_of(id);
        if !self.ask(THEIRS_SQL, &r, None)? {
            return Ok(false);
        }
        if self.ask(OURS_SQL, &r, Some(kind))? {
            return Ok(false);
        }
        // 这条命令前面写下的还没收尾：收尾后再看一遍（同批先写后读）。
        self.settled()?;
        Ok(!self.ask(OURS_SQL, &r, Some(kind))?)
    }

    /// [body] 指向别的集合的实体（[target] + [Session::foreign]）。
    pub(in crate::store::gen4::cmd) fn foreign_body(
        &mut self,
        body: &Body,
        born: &Born,
    ) -> Result<bool, String> {
        match target(body) {
            Some((kind, id)) => self.foreign(kind, &id, born),
            None => Ok(false),
        }
    }
}

#[cfg(test)]
#[path = "writes_owner_tests.rs"]
mod tests;
