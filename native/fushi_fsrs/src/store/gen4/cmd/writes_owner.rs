//! 本机写入的实体归属闸（BUG-4907，第五波 G9 身份收尾）：同一个新代库里放着几个集合（app 的多份 profile、无头服务端
//! 一门语言一份），ID 却不再按 uid 加盐（设计 2026-11-11 §2、G9-7）。调用方拿 A 的命令点名 B 的实体（切换配置前留在
//! UI 里的 ID、点名 A 却带 B 的 ID 的远程请求）时，以前这条操作照样落进 A 的日志，成了一条指向「A 里不存在的实体」的
//! 悬空操作；A 当时看不到后果，可 A 的集合之后并进 B（`.fushisrs` 确认导入、关联已有集合，并入 = 操作并集）时它对 B
//! 的同名实体生效——B 的笔记字段、标签、旗标、暂停被 A 改掉（协议 3 BUG-4626 在新代回来了）。
//!
//! # 判据（[Session::foreign]）
//!
//! 一条本机操作指向的实体 E（修改的实体、标签的笔记、清除的实体、日志的笔记——日志没带笔记时是卡；带笔记的卡片修改另见
//! 下文）是**别人的**，当且仅当：
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
//! **卡片修改带笔记**（输入项的 `note`，调用方声明「这张卡是这条笔记的」，同日志带笔记）时，除了卡自己过闸，还要它的笔记
//! 也过闸：笔记是别人的（含同批身份记录被拒的那条笔记——它没进 [Born]，别的集合有、本集合没有）就一并不写（第六波
//! BUG-4907 复核）。没有这一条时，`.apkg` 不合并笔记模板、新笔记落到副本类型、因与别的集合同 guid 异类型被拒的那条笔记，
//! 它的卡片修改（新卡位置、牌组、暂停）目标是由副本类型的模板派生的卡 ID——哪里都没有——按上一段照常写，成了没有缓存行、
//! 不进任何视图的悬空修改。只加严、不放宽：笔记是本集合的 / 同批要建的 / 哪里都没有的，结果与不带笔记相同。
//!
//! 没选「内核按被拒笔记 × 模板推出卡 ID 一并拒」：填空题的卡序号来自笔记字段（`{{cN}}`，上不封顶，`alias.rs` 按字段史
//! 补上限外的序号），副本笔记类型的模板又常在同一批里才建，内核要在写入口重做一遍 Dart 的出卡规则才推得全；推不全的序号
//! 照样漏成悬空修改。调用方本来就知道每张卡是哪条笔记的（它刚按笔记 × 模板派生出卡 ID），声明给内核即可精确闭合。
//!
//! # 身份记录：内容寻址的归属（[Session::foreign_record]，第六波 BUG-4907 收口）
//!
//! 身份记录（`Body::Entity`）指向它自己要建的实体。它是一个集合「有」某个实体的**唯一来源**：修改、标签、日志的闸都看
//! 本集合有没有痕迹，而痕迹的源头是身份记录（[Born] 只收过了闸的身份记录，`ent_ix` 只收落下的）。所以身份记录的判据
//! 就是归属判据本身，必须对每一种实体都成立：
//!
//! > ID 不加盐以后，实体是**内容寻址**的：ID 由身份内容按规范规则派生（笔记 `v5(NS, note/<guid>)`、笔记类型
//! > `v5(NS, notetype/<Anki 编号>)`、牌组 `v5(NS, deck/<全名>)` 及备选、内置默认牌组常量，`gen4_ids/rules.rs`），两个集合
//! > 各自拿同一份内容建出来的就是**同一个实体**，并入后合成一份（设计 2026-11-11 §2）。所以集合 C 可以为别的集合已有的
//! > ID X 写身份记录，当且仅当 C 自己拿得出 X 的身份内容、且这份内容与别的集合的一致——即 C 是「独立建了同一个实体」，
//! > 不是「拿着 X 这个号」。
//!
//! 具体是三条（库里有别的集合、别的集合里有 X 的痕迹时；否则照常写）：
//!
//! 1. **重发本集合已有的定义**（与本集合此刻的定义逐字相同）照常写：它不带任何新内容，并入后什么都改不了。
//! 2. **自证**：ID 必须能由这条记录（牌组还要同批的名字 / 父牌组）按规范规则重算出来（[Session::derived]）。拿着别人的号
//!    的记录（切换 profile 前留在 UI 里的 ID、远程请求里带的 ID）重算不出来：随机 / 存量带盐 ID 的笔记、对不上 Anki 编号的
//!    笔记类型、名字对不上的牌组、任何卡片身份记录（卡由笔记 × 模板派生，没有合法的卡片身份记录来源）。
//! 3. **与别的集合一致**：身份里决定结构的部分（笔记：guid + 笔记类型；笔记类型：Anki 编号 + 种类，缺省 `standard` 同
//!    `registers.rs`）与库里每个有 X 定义的集合的定义（各自按自己的别名表归一）相同（[identity_key]）。身份记录不可变、
//!    同 ID 异内容只可能是 bug（Dart `SrsEntityRecord` 注释）：一条用 B 的真实 guid、只换了笔记类型的记录能自证，却与 B 的
//!    定义冲突，并入时「规范 JSON 最小者胜」可能拿它顶掉 B 的笔记类型——不写（同 Anki 导入「同 guid 异笔记类型」跳过）。
//!    `createdAt` 不算结构：同一份内容的合法导入在不同版本里算法不同（存量），并入时它按规则二选一，只影响新卡次序。
//!    牌组的身份内容只有 `createdAt` / `builtin`，ID 就是它的全部结构（第 2 条已核）。
//!
//! 判身份记录时不拿 [Born] 给它自己作保。字段、模板没有自己的实体种类：它们是笔记类型上的 `fieldDef/` / `tmplDef/` 修改，
//! 跟着笔记类型的归属走（[target] 指向笔记类型）。profile 设置实体见下一节。
//!
//! 这条判据与并集收敛的关系见「为什么在写入口、不在并入时丢」。分不出来的只剩一种，而且按定义它不是「别人的」：C 拿出的
//! 身份内容与 B 的**完全一致**（同一个 guid + 同一个笔记类型、同一个 Anki 编号、同一个全名）——内容寻址下这就是同一个
//! 实体，与「C 独立导入了同一份内容」逐字节相同，C 之后对它的修改并入后作用到合成的那一份，是设计里的并集语义。
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
//! 也考虑过「实体归属 = 首个身份记录的作者集合，随操作落库；并入时作者集合 ≠ 归属集合的修改不生效」（第六波任务书的
//! 例子）。没选：① 合法的「两个集合各自导入同一份内容」里后建的一方不是首个作者，它在并入前对自己那份写的修改与复习
//! 并入后全部失效——丢复习记录，违背「不丢用户数据」的底线；把归属放宽成「所有内容一致的身份记录的作者」又回到上面的
//! 内容判据，只是挪到并入时做。② 「作者集合」要进操作格式（线上形状、摘要对拍、协议 3 投影对拍全变），并入后还要按
//! 因果过去判「这条修改写的时候作者并没并过」，`derive.rs` 的冻结判定与重建恒等都要重做。③ 它同样分不出「内容完全一致」
//! 的那一种（操作逐字节相同）。所以判据定在身份记录上（上一节），用的是只有写入口才有的信息：此刻库里别的集合的定义。
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

use std::collections::{HashMap, HashSet};

use rusqlite::params;
use serde_json::{Value, json};

use super::super::super::derive::{Index, Ref};
use super::super::super::schema::sql;
use super::super::writes_intent::full_name;
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

/// 这一批输入里要建的实体（规范 ID 文本）：算本集合的（第 3 条）。只收过了闸的身份记录（[Session::foreign_record]）。
pub(in crate::store::gen4::cmd) type Born = HashSet<String>;

/// 库里别的集合的集合号：?1 = 本集合。
const OTHER_COLS_SQL: &str = "SELECT col FROM collections WHERE col != ?1 ORDER BY col";

/// 这一批输入里牌组的名字与父牌组（规范 ID 文本 → 值；同一个牌组写了几次取最后一次），判牌组身份记录能不能自证用
/// （文件头「身份记录」第 2 条：牌组的 ID 按建的时候的全名派生，名字在同批的修改里，Dart `createDeck` / `.apkg` 导入
/// 都是身份记录与名字 / 父牌组同一批落）。
#[derive(Debug, Default)]
pub(in crate::store::gen4::cmd) struct Batch {
    deck_names: HashMap<String, String>,
    deck_parents: HashMap<String, String>,
}

impl Batch {
    /// 从这一批（已归一的）操作体里收牌组的 `name` / `parent`。
    pub(in crate::store::gen4::cmd) fn of<'a>(bodies: impl Iterator<Item = &'a Body>) -> Batch {
        let mut b = Batch::default();
        for body in bodies {
            let Body::Edit(e) = body else { continue };
            if e.kind != EntKind::Deck {
                continue;
            }
            let into = match e.key.as_str() {
                "name" => &mut b.deck_names,
                "parent" => &mut b.deck_parents,
                _ => continue,
            };
            let v = serde_json::from_str::<Value>(&e.value).ok();
            match v.as_ref().and_then(Value::as_str) {
                Some(s) => {
                    into.insert(e.entity.text(), s.to_owned());
                }
                None => {
                    into.remove(&e.entity.text());
                }
            }
        }
        b
    }
}

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

/// 身份内容里决定结构的部分（文件头「身份记录」第 3 条）：两个集合各自建的同一个实体这部分必须相同。[d] 已按所在集合的
/// 别名表归一。牌组的结构就是它的 ID（第 2 条已核），卡片与 profile 走不到这里（第 2 条不放行）。
pub(in crate::store::gen4::cmd) fn identity_key(kind: EntKind, d: &Value) -> Value {
    match kind {
        EntKind::Note => json!([d["guid"], d["noteTypeId"]]),
        EntKind::NoteType => json!([d["ankiNum"], d["ntKind"].as_str().unwrap_or("standard")]),
        EntKind::Deck | EntKind::Card | EntKind::Profile => Value::Null,
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

    /// [body] 指向别的集合的实体（[target] + [Session::foreign]）。身份记录走 [Session::foreign_record]（没有同批内容）。
    pub(in crate::store::gen4::cmd) fn foreign_body(
        &mut self,
        body: &Body,
        born: &Born,
    ) -> Result<bool, String> {
        if let Body::Entity { kind, id, data } = body {
            return self.foreign_record(*kind, &id.text(), data, &Batch::default());
        }
        match target(body) {
            Some((kind, id)) => self.foreign(kind, &id, born),
            None => Ok(false),
        }
    }

    /// 身份记录 ([kind], [id], [data]，已归一) 是不是在替别的集合的实体立户（文件头「身份记录」三条）。[batch] = 同批的
    /// 牌组名字 / 父牌组。不拿 [Born] 给自己作保。
    pub(in crate::store::gen4::cmd) fn foreign_record(
        &mut self,
        kind: EntKind,
        id: &str,
        data: &str,
        batch: &Batch,
    ) -> Result<bool, String> {
        if !self.others()? {
            return Ok(false);
        }
        if kind == EntKind::Profile {
            return self.profile_foreign(id);
        }
        let r = ref_of(id);
        if !self.ask(THEIRS_SQL, &r, None)? {
            return Ok(false);
        }
        let d: Value = serde_json::from_str(data).map_err(|e| format!("gen4 write: {e}"))?;
        // 1. 重发本集合已有的定义。
        if let Some((k, _, ours)) = self.settled()?.definition(&r)? {
            if k == kind as i64 && ours == d {
                return Ok(false);
            }
        }
        // 2. 自证。
        if !self.derived(kind, id, &d, batch)? {
            return Ok(true);
        }
        // 3. 与别的集合的定义一致。
        self.conflicts(kind, &r, &d)
    }

    /// 身份记录的 ID [id] 能不能由它自己的内容 [d]（牌组再加同批的 [batch]）按规范规则重算出来（文件头「身份记录」第 2
    /// 条）。
    fn derived(
        &mut self,
        kind: EntKind,
        id: &str,
        d: &Value,
        batch: &Batch,
    ) -> Result<bool, String> {
        Ok(match kind {
            EntKind::Note => d["guid"]
                .as_str()
                .is_some_and(|g| rules::note(rules::CANONICAL, g).text() == id),
            EntKind::NoteType => d["ankiNum"]
                .as_i64()
                .is_some_and(|n| rules::note_type(rules::CANONICAL, n).text() == id),
            EntKind::Deck => self.deck_derived(id, d, batch)?,
            EntKind::Card | EntKind::Profile => false,
        })
    }

    /// 牌组 [id] 能不能由同批内容重算出来：内置默认牌组（`builtin`）是规范常量；别的按同批的名字（与父牌组的全名，父牌组
    /// 在本集合的牌组树里或同批里有名字）得出全名，ID 是 `deck(全名)`，或第 n 个备选 `deck_alternate(全名, n)`——备选只在
    /// 前一个已被本集合占着时才轮得到（Dart `SrsDbStore.deckIdForNew` 的同一条规则），所以逐个往后试到本集合没痕迹的那个
    /// 为止。带父牌组时「只按叶子名」也认（Dart 父牌组不在牌组树里时按叶子名派生）：两种都是由这批内容算出来的。
    fn deck_derived(&mut self, id: &str, d: &Value, batch: &Batch) -> Result<bool, String> {
        if d.get("builtin").is_some_and(|b| !b.is_null()) {
            return Ok(id == rules::builtin_default_deck(rules::CANONICAL).text());
        }
        let Some(name) = batch.deck_names.get(id) else {
            return Ok(false);
        };
        let mut paths = vec![name.clone()];
        if let Some(parent) = batch.deck_parents.get(id) {
            let tree = self.deck_tree()?;
            if tree.decks.contains_key(parent) {
                paths.push(format!("{}::{name}", full_name(tree, parent)));
            } else if let Some(pn) = batch.deck_names.get(parent) {
                paths.push(format!("{pn}::{name}"));
            }
        }
        for path in &paths {
            let mut cand = rules::deck(rules::CANONICAL, path).text();
            let mut n: u32 = 0;
            loop {
                if cand == id {
                    return Ok(true);
                }
                if !self.ask(OURS_SQL, &ref_of(&cand), Some(EntKind::Deck))? {
                    break;
                }
                n = n
                    .checked_add(1)
                    .ok_or("gen4 write: deck alternates overflow")?;
                cand = rules::deck_alternate(rules::CANONICAL, path, n).text();
            }
        }
        Ok(false)
    }

    /// 库里有没有别的集合对 [r] 的定义与 [d] 在结构上不同（[identity_key]；文件头「身份记录」第 3 条）。别的集合的定义按
    /// 它自己的别名表归一（`Index::definition`，类上同一个挑选规则），[d] 已按本集合的归一：规范 ID 在两边是同一个号。
    /// 别的集合把 [r] 当成另一种实体也算不同。
    fn conflicts(&self, kind: EntKind, r: &Ref, d: &Value) -> Result<bool, String> {
        let want = identity_key(kind, d);
        let cols: Vec<i64> = self
            .t
            .conn()
            .prepare_cached(OTHER_COLS_SQL)
            .map_err(sql)?
            .query_map([self.col], |row| row.get(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        for y in cols {
            let ix = Index::new(self.t, y);
            if let Some((k, _, theirs)) = ix.definition(r)? {
                if k != kind as i64 || identity_key(kind, &theirs) != want {
                    return Ok(true);
                }
            }
        }
        Ok(false)
    }
}

#[cfg(test)]
#[path = "writes_owner_tests.rs"]
mod tests;
