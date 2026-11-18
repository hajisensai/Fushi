//! 本机写入的实体归属闸（BUG-4843，第五波 G9 身份收尾）：同一个新代库里放着几个集合（app 的多份 profile、无头服务端
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
//! # 身份记录
//!
//! 身份记录（`Body::Entity`）指向它自己要建的实体，同样过闸：以前它不过闸、还直接进 [Born]，A 只要在批里带一条 B 的笔记
//! 的身份记录，那条身份记录与同批对这条笔记的修改就都写下了，并入后 A 的身份记录按「规范 JSON 最小者胜」（`derive.rs`）
//! 可能顶掉 B 的（换了 B 的笔记类型、guid，复核实测）。判法按种类：
//!
//! - **笔记**：ID 由它自己的内容按规范规则派生（`v5(NS, note/<guid>)`，`gen4_ids/rules.rs` `note`）的照常写——两个集合
//!   各自导入同一个包 / 同一份挖词历史（guid 来自内容）就该得到同一个 ID，那是各自的实体（文件头第 3 条后面那段）；对
//!   不上的（随机 guid 新建的笔记、存量带盐 ID、伪造的记录）按上面的判据判。
//! - **牌组、笔记类型**：不判。它们的规范 ID 按全名 / Anki 编号派生，内置的（默认牌组、内置笔记类型）在每个集合里是同一个
//!   常量，用户在两个集合里各建一个同名牌组也是同一个 ID：「别的集合里有」说明不了归属。对它们的修改仍按判据判。
//! - **卡片**：没有合法的卡片身份记录来源（卡由笔记 × 模板派生），按判据判。
//! - **profile 设置实体**：见下一节。
//!
//! 判身份记录时不拿 [Born] 给它自己作保；[Born] 只收过了闸的身份记录。
//!
//! # profile 设置实体
//!
//! 它不在 `ent_ix` / `alias_ix` / `cards` 里留痕迹，上面的判据看不到。存量里它的 ID 就是 profile uid（别名层把每个盐归到
//! 规范值 `v5(NS, profile)`，`gen4_ids/alias.rs` `profile_entities`）：A 拿 B 的 uid 改设置，在 A 的集合里归不到规范值，
//! 写下的是悬空的「B 的 uid」，并入 B（盐取并集）后就成了 B 的设置。判法同协议 3 `ownership.rs`：ID 是别的集合绑定的
//! profile uid 或盐、又不是本集合的（[PROFILE_SQL]），就是别人的；规范值是各自的常量，永远放行。
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
use serde_json::Value;

use super::super::super::derive::Ref;
use super::super::super::schema::sql;
use super::{Body, EntKind, Session, ref_of};
use crate::gen4_ids::rules;

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

/// profile 级设置实体 E 是不是别的集合的（文件头「profile 设置实体」）：?1 = E（文本），?2 = 本集合。E 是别的集合绑定的
/// profile uid 或它的盐、又不是本集合的，才是别人的。`collections` 一个 profile 一行，整表就几行。
pub(crate) const PROFILE_SQL: &str = "SELECT EXISTS(SELECT 1 FROM collections WHERE col != ?2 \
       AND (profile_uid = ?1 OR EXISTS(SELECT 1 FROM json_each(salts) WHERE value = ?1))) \
     AND NOT EXISTS(SELECT 1 FROM collections WHERE col = ?2 \
       AND (profile_uid = ?1 OR EXISTS(SELECT 1 FROM json_each(salts) WHERE value = ?1)))";

/// 这一批输入里要建的实体（规范 ID 文本）：算本集合的（第 3 条）。只收过了闸的身份记录（[Session::foreign_body]）。
pub(in crate::store::gen4::cmd) type Born = HashSet<String>;

/// 一条操作体指向的实体（文件头「判据」）：还原点、并入这类不指向已有实体的为 None。身份记录指向它自己建的实体。
pub(in crate::store::gen4::cmd) fn target(body: &Body) -> Option<(EntKind, String)> {
    match body {
        Body::Entity { kind, id, .. } => Some((*kind, id.text())),
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

/// 身份记录 [data] 的 ID [id] 是不是由它自己的内容按规范规则派生的（文件头「身份记录」）：笔记 = `v5(NS, note/<guid>)`
/// （`gen4_ids/rules.rs` [rules::note]）。别的集合独立导入 / 新建同一份内容就会得到同一个 ID，那是各自的实体。
fn content_derived(kind: EntKind, id: &str, data: &str) -> bool {
    match kind {
        EntKind::Note => serde_json::from_str::<Value>(data)
            .ok()
            .and_then(|d| {
                d["guid"]
                    .as_str()
                    .map(|g| rules::note(rules::CANONICAL, g).text())
            })
            .is_some_and(|derived| derived == id),
        _ => false,
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
        if !self.others()? {
            return Ok(false);
        }
        if kind == EntKind::Profile {
            return self.profile_foreign(id);
        }
        if born.contains(id) {
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

    /// profile 级设置实体 [id] 是不是别的集合的（[PROFILE_SQL]）。规范的 profile 设置实体（[rules::profile_entity]）在
    /// 每个集合里都是同一个常量，是各自的。
    fn profile_foreign(&self, id: &str) -> Result<bool, String> {
        if id == rules::profile_entity().text() {
            return Ok(false);
        }
        self.t
            .conn()
            .prepare_cached(PROFILE_SQL)
            .map_err(sql)?
            .query_row(params![id, self.col], |r| r.get(0))
            .map_err(sql)
    }

    /// [body] 指向别的集合的实体（[target] + [Session::foreign]）。身份记录（文件头「身份记录」）：ID 由自己的内容派生的
    /// 放行（[content_derived]）；牌组与笔记类型的不判；判的时候不拿 [born] 给自己作保。
    pub(in crate::store::gen4::cmd) fn foreign_body(
        &mut self,
        body: &Body,
        born: &Born,
    ) -> Result<bool, String> {
        if let Body::Entity { kind, id, data } = body {
            let id = id.text();
            return match kind {
                EntKind::Deck | EntKind::NoteType => Ok(false),
                _ if content_derived(*kind, &id, data) => Ok(false),
                _ => self.foreign(*kind, &id, &Born::new()),
            };
        }
        match target(body) {
            Some((kind, id)) => self.foreign(kind, &id, born),
            None => Ok(false),
        }
    }
}

#[cfg(test)]
#[path = "writes_owner_tests.rs"]
mod tests;
