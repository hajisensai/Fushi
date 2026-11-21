//! 读侧按别名类判定（设计 §5.3「一个寄存器的写入按实体的整个别名类归并」，G9-1）。[Index] 的一部分，**只读**：
//! 索引表（`reg_ix`、`tag_ix`）照旧存操作体里的原值 ID、按原值实体各判各的（`derive.rs` / `weigh.rs`），这里在读的
//! 时候把一个别名类的全部成员并起来，用**同一个**冻结判据（`crate::registers::judge_register`，拼行在
//! [Index::edit_lines_as]）再判一次。调用方只有缓存层（`cache.rs`，[Index::class_lines]，G9-2）与迁移报告的已知差异（[Index::class_differences]）；
//! 写命令按规范 ID 写是 G7-3b。
//!
//! # 并起来的是什么
//!
//! - **寄存器**（[Index::class_winners] / [Index::class_value]）：类内每个成员在 `reg_ix` 里的行，修改键先过
//!   [Index::canonical_key]（键里嵌的 `f/` `fieldDef/` `tmplDef/` `historyFrom/` `fieldDesc/` ID 换成规范 ID），规范键
//!   相同的是同一个寄存器。拼行时三处写入者一起换成规范写入者（[Index::canonical_writer]：dot 的写入者、HLC 的写入者、
//!   旧上下文的键，设计 §5.3「改名的写入者」），换完同一个 dot 的并成一次写入（代表取操作号最小的，与原值判定里
//!   「同一条旧修改被迁了两遍」同一个规则）；实体换成规范 ID，值里嵌的 ID 归一（[Index::canonical_value]）后再比
//!   「值相同」——否则两个成员各写了一个「指向同一个牌组的不同别名」会被判成冲突。不带旧戳的原生写入「见没见过」
//!   某个 dot 问的是旧闭包（按原名累积），闭包也过同一个换名（[Canon::closure_contains]，`derive.rs` 的
//!   `Index::seen`）再问规范写入者——带旧戳与不带旧戳两条路径对「见过 merged:n」得出同一个答案。
//! - 别名表没重算（[Index::aliases_stale]）时按类读报错，不拿旧表判。
//! - **标签**（[Index::class_tags]）：类内成员的 `tag_ix` 行并起来，按 OR-Set 与顺序提示重判（`weigh.rs`
//!   [Index::tag_states]，同一份规则）：一个成员上的删除见过另一个成员上的添加，就抹掉它。
//! - 只有一个成员（从没并入过的存量集合里的绝大多数实体）**且寄存器里没有归回的改名写入者**时，结果与原值读接口
//!   相同（[Index::value]、[Index::tags_of]）。写入者归回对单成员实体同样生效：旧上下文写的是改名后的名字时，按类判
//!   可以把原值判下的冲突判成支配（样本库 144 处都是这一种）。所以**不能**按「只有一个成员就沿用 `reg_ix` 状态」
//!   走捷径；两种情形各有测试钉住（`a_class_of_one_reads_the_same_as_the_raw_id`、
//!   `a_renamed_writer_on_a_class_of_one_is_not_the_raw_reading`）。反过来，成员数也不是捷径的条件：一个规范键只来自
//!   一个有行的原值寄存器、又没碰归回写入者时，类里有几个（没有行的）成员都与原值判相同（[Index::class_lines]）。
//!   **定案（2026-11-15，所有者授权协调方定）**：这 144 处（笔记类型 `css` 1、字段 18、卡 `newPos` 125）从「有冲突」
//!   变「没冲突」接受，根因是写入者归回、受 resolver「同 seq 同一条记录」的证明门槛约束；G9-2 在迁移报告里列为已知
//!   差异并逐条佐证（被支配的 `(w1, s)` 在日志里另有 `(merged-…, s)` 副本，或 s 落在已证明的重叠区间），佐证不了的
//!   按 bug 回 resolver 收紧。原生写入问闭包也换名之后（上面「寄存器」一条）新增的同类差异一并计入。设计 §5.3、§10 第 24 条。
//!
//! # 没有并起来的（按原值实体，留在索引层）
//!
//! 负状态记在索引层的原值写入上，这里原样拿来：已清除（[super::weigh::S_PURGED]：Purge 点名的是原值实体，清的是
//! 「作者没见过它」的、这个原值实体上的操作）、扣住的删除（[super::weigh::S_HELD]）、作者不可信（
//! [super::weigh::S_DISTRUSTED]）。清除与不可信按原值实体判；一条 Purge 要不要清掉整个类仍是接线时定的事（设计
//! §10 第 19 条同源），在那之前按类读与按原值读对这两种状态口径相同。**扣住按类判**（G7-4g 定，交接说明 §7.6 方案 1）：
//! 「被见过它的写入盖掉」与「并发的操作」都在全类成员上取（`weigh.rs` 文件头「扣住的删除」），状态仍记在删除落的
//! 原值成员上——与这里按类读寄存器同一个口径，裁决按规范 ID 写也盖得掉落在带盐成员上的删除。
//!
//! # 内嵌的 ID（设计 §5.3「内嵌的 ID 同样过别名表」）
//!
//! 只认规范形状的 UUID 文本（`gen4_ids::alias::strict_id`）；别的写法没有别名，原样。哪些位置嵌着 ID 只在这里写一次：
//!
//! - 修改值（[Index::canonical_value]，按修改键）：值本身是 ID 的键 [ID_VALUED_KEYS]（笔记的 `noteType`、卡的 `deck`、
//!   牌组的 `parent`、笔记类型的 `termField` / `freqField`）；`tmplDef/<模板>` 的值里 `front` / `back` 两段模板文本中的
//!   `{{…fld:<字段>}}`（与 `card_cache.rs` 的 `ids_to_names` 同一个分词：注释、普通文本、`{{…}}` 里不是整段
//!   `fld:<UUID>` 的都不动）。别的值（字段内容等用户文本）一个字节不动。
//! - 整份 JSON（[Index::canonical_json]：身份记录的载荷、日志投影、修改行）：键在 [JSON_ID_KEYS] 里的字符串（或字符串
//!   数组）；`f` 当修改键；`front` / `back` 当模板文本；同一个对象里有 `f` 时 `v` 按那个键过 [Index::canonical_value]；
//!   其余递归。
//!
//! 语义摘要（`digest.rs`）按原值 ID 记、不过别名表（两台设备的别名表可以不同，摘要不能跟着不同），这里不碰。

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::rc::Rc;

use rusqlite::params;
use rusqlite::types::ValueRef;
use serde_json::{Map, Value};

use super::alias::{WRITER_UPTO_KEY, key_ids_by};
use super::derive::{Index, R_CONFLICT, R_DOMINATED, R_LIVE, R_WINNER, Ref, body_of};
use super::schema::sql;
use crate::card_cache::ids_to_names;
use crate::gen4::name::read_edit_key;
use crate::gen4::op::Body4;
use crate::gen4::stamp::StampHlc;
use crate::gen4_ids::alias::WriterBound;
use crate::gen4_ids::alias::strict_id;
use crate::gen4_ids::builtins::BUILTIN_NOTE_TYPES;
use crate::gen4_ids::rules;
use crate::sync2::codec::Reader;
use crate::sync2::dvv::Dvv;
use crate::sync2::id::Id;
use crate::sync2::op::EntKind;
use crate::sync2::vv::OpId;

/// 值本身是一个 ID 的修改键（[Index::canonical_value]）。
pub const ID_VALUED_KEYS: [&str; 5] = ["noteType", "deck", "parent", "termField", "freqField"];

/// 整份 JSON 里值是 ID（或 ID 数组）的键（[Index::canonical_json]）：实体与日志的 `id`、修改行的 `e`、日志的 `card` /
/// `note` / `revokes`、笔记载荷的 `noteTypeId`、牌组 / 笔记类型 / 父牌组、词条与词频字段（含内置默认定义里的
/// `…FieldId`）。
pub const JSON_ID_KEYS: [&str; 14] = [
    "id",
    "e",
    "card",
    "note",
    "revokes",
    "deck",
    "deckId",
    "noteType",
    "noteTypeId",
    "parent",
    "termField",
    "freqField",
    "termFieldId",
    "freqFieldId",
];

/// 旧并入改名、已归回的写入者（[Index::writer_aliases]）：解引用成「原名 → 规范名」的表；另带各原名归回时证据撑得住
/// 的范围（[WriterAliases::bound]）。
#[derive(Clone, Debug, Default)]
pub(crate) struct WriterAliases {
    names: BTreeMap<String, String>,
    bounds: BTreeMap<String, WriterBound>,
}

impl WriterAliases {
    /// 原名 [w] 换成规范名时旧上下文能换的范围（`gen4_ids::alias::WriterBound`）。None = 不是归回的原名（读库时
    /// 有归回的原名就一定有范围，[Index::writer_aliases]；测试直接造的表可以没有，按整段换）。
    pub(crate) fn bound(&self, w: &str) -> Option<&WriterBound> {
        self.bounds.get(w)
    }
}

impl std::ops::Deref for WriterAliases {
    type Target = BTreeMap<String, String>;

    fn deref(&self) -> &BTreeMap<String, String> {
        &self.names
    }
}

/// 按类拼行要的换名（[Index::edit_lines_as]）：写入者表（只放规范名与原名不同的）、这个寄存器的规范实体与规范键，
/// 以及闭包换名的缓存（[Renamed]，同一次读里各寄存器共用）。
pub(super) struct Canon<'a> {
    writers: &'a WriterAliases,
    renamed: &'a Renamed,
    pub(super) entity: String,
    pub(super) key: String,
    /// 一次拼几个寄存器的行时（缓存层，[Index::class_lines]）每条写入（操作主键）各自的规范键；没有的取 `key`。
    keys: Option<&'a HashMap<i64, String>>,
}

/// 按类拼好的一行（[Index::class_lines_keyed]）：(规范键, 行 JSON, 服务器时刻)。
pub(super) type ClassLine = (String, String, Option<i64>);

/// [Index::class_lines_by] 要哪些寄存器的行。
pub(super) enum Pick<'a> {
    /// 全部寄存器活着的写入（缓存层、读命令的 `edits`）。
    All,
    /// 只要 [pre]（原值键文本）与 [tracks]（规范键）都留下、且可能有值不同的并发写入的寄存器
    /// （[Index::class_conflict_lines]）。
    Conflicts {
        pre: &'a dyn Fn(&str) -> bool,
        tracks: &'a dyn Fn(&str) -> bool,
    },
}

/// 一份闭包是哪一段：整份（`closure_ix` 里那台设备的旧闭包，按 `upto` 记）还是只并到某个 seq 的一部分（[Index] 的
/// `partial`，按那个 seq 记）。两种的 seq 含义不同，缓存分开记。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum Span {
    Whole,
    Upto,
}

/// 闭包过 [Canon::dvv] 换名的结果，按 (设备, [Span], seq) 记；None = 闭包里没有改名的写入者，原样用。只在一次读
/// 期间有效（读的时候索引不变）。
pub(super) type Renamed = RefCell<BTreeMap<(Id, Span, u64), Option<Dvv>>>;

impl Canon<'_> {
    /// 操作 [k] 这条写入的规范键。
    pub(super) fn key_of(&self, k: i64) -> &str {
        self.keys
            .and_then(|m| m.get(&k))
            .map_or(self.key.as_str(), String::as_str)
    }

    /// 规范写入者（表里没有 = 它自己）。
    pub(super) fn writer<'w>(&'w self, w: &'w str) -> &'w str {
        self.writers.get(w).map_or(w, String::as_str)
    }

    /// 规范写入者 [w] 自己和归到它的全部原名。
    pub(super) fn names<'w>(&'w self, w: &'w str) -> impl Iterator<Item = &'w str> + 'w {
        std::iter::once(w).chain(
            self.writers
                .iter()
                .filter(move |(_, c)| c.as_str() == w)
                .map(|(n, _)| n.as_str()),
        )
    }

    /// [d] 里有没有要换名的写入者。
    fn renames(&self, d: &Dvv) -> bool {
        d.vv.keys()
            .chain(d.cloud.keys())
            .any(|w| self.writers.contains_key(w))
    }

    /// 闭包 [d]（[at] 是它在缓存里的位置）换成规范写入者之后含不含 dot `(w, q)`，[w] 是规范写入者。与带旧戳写入的
    /// 上下文用同一个 [Canon::dvv] 换名（设计 §5.3「三处一起换」），换名结果按 [at] 缓存、不重复算。
    pub(super) fn closure_contains(&self, at: (Id, Span, u64), d: &Dvv, w: &str, q: i64) -> bool {
        let mut cache = self.renamed.borrow_mut();
        let r = cache
            .entry(at)
            .or_insert_with(|| self.renames(d).then(|| self.dvv(d)));
        r.as_ref().unwrap_or(d).contains(w, q)
    }

    /// 旧上下文 [d] 换成规范写入者之后含不含 dot `(w, q)`（[w] 是规范写入者）：与 `self.dvv(d).contains(w, q)` 相同，
    /// 不物化换名后的上下文（按类判每条带旧戳的写入都要问一次，`derive.rs` 的 `write_sees`）。
    pub(super) fn dvv_contains(&self, d: &Dvv, w: &str, q: i64) -> bool {
        if !self.renames(d) {
            return d.contains(w, q);
        }
        if self.writer(w) != w {
            return self.dvv(d).contains(w, q);
        }
        self.names(w).any(|n| {
            let bound = self.writers.bound(n).filter(|_| n != w);
            let covered = |q: i64| match bound {
                None => true,
                Some(b) => q <= b.upto as i64 || b.own.binary_search(&(q as u64)).is_ok(),
            };
            (q <= d.vv.get(n).copied().unwrap_or(0) && covered(q))
                || d.cloud.get(n).is_some_and(|s| s.contains(&q) && covered(q))
        })
    }

    /// 旧上下文的键换成规范写入者：前缀取大、零散 dot 取并，再按 [Dvv::merge] 的规则收紧。
    ///
    /// 改名的写入者只换证据撑得住的部分（[WriterAliases::bound]，`gen4_ids::alias::WriterBound`）：`{merged-…: n}`
    /// 换成 `{w: min(n, upto)}`，再加上原名自己在 `upto` 以上、n 以内的记录（换名后是 `w` 名下的同号 dot，按零散 dot
    /// 覆盖），整段也留在原名下；零散 dot 落在 `upto` 以内或正是原名自己的记录才换名，其余留在原名下。于是原名下的
    /// 记录照样被覆盖，规范名下没有「是同一条」证据的写入不算见过（照原值判）。
    pub(super) fn dvv(&self, d: &Dvv) -> Dvv {
        if !self.renames(d) {
            return d.clone();
        }
        let mut renamed = Dvv::default();
        let mut put = |w: &str, v: i64| {
            let e = renamed.vv.entry(w.to_owned()).or_insert(0);
            *e = (*e).max(v);
        };
        let mut dots: Vec<(String, i64)> = Vec::new();
        for (w, &v) in &d.vv {
            let to = self.writer(w);
            match self.writers.bound(w).filter(|_| to != w) {
                Some(b) if v > b.upto as i64 => {
                    put(to, b.upto as i64);
                    put(w, v);
                    dots.extend(
                        b.own
                            .iter()
                            .map(|&q| q as i64)
                            .take_while(|&q| q <= v)
                            .map(|q| (to.to_owned(), q)),
                    );
                }
                _ => put(to, v),
            }
        }
        for (w, s) in &d.cloud {
            let to = self.writer(w);
            let bound = self.writers.bound(w).filter(|_| to != w);
            for &q in s {
                let name = match bound {
                    Some(b) if q > b.upto as i64 && b.own.binary_search(&(q as u64)).is_err() => {
                        w.as_str()
                    }
                    _ => to,
                };
                dots.push((name.to_owned(), q));
            }
        }
        for (w, q) in dots {
            renamed.cloud.entry(w).or_default().insert(q);
        }
        let mut out = Dvv::default();
        out.merge(&renamed);
        out
    }

    /// HLC 里的写入者换成规范写入者（解不开的原样）。
    pub(super) fn hlc(&self, h: &StampHlc) -> StampHlc {
        match h {
            StampHlc::Parsed {
                physical,
                counter,
                writer,
            } => StampHlc::Parsed {
                physical: *physical,
                counter: *counter,
                writer: self.writer(writer).to_owned(),
            },
            StampHlc::Raw(_) => h.clone(),
        }
    }
}

/// 一个别名类里一个寄存器的胜者（[Index::class_winners]）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClassWinner {
    /// 规范键（[Index::canonical_key]）。
    pub key: String,
    /// 胜出的那条写入（同一个规范 dot 的取操作号最小的代表）。
    pub op: OpId,
    /// 生效值：规范 JSON 文本，嵌的 ID 已归一（[Index::canonical_value]）。
    pub value: String,
    /// 有值不同的并发写入。
    pub conflict: bool,
}

impl<'t, 'c> Index<'t, 'c> {
    /// 按类读的入口先过这一关：别名表还没重算（[Index::aliases_stale]：[Index::hold_aliases] 攒着、或证据变了还没
    /// [Index::settle]）时报错，不拿旧别名表静默判。
    fn aliases_settled(&self) -> Result<(), String> {
        if self.aliases_stale() {
            return Err(
                "gen4 index: class read while the alias table is stale (settle first)".to_owned(),
            );
        }
        Ok(())
    }

    /// 一个别名类全部寄存器的胜者，按规范键升序（文件头「寄存器」）。[canon] 可以是类里任何一个 ID。别名表没重算时
    /// 报错（[Index::aliases_settled]）。
    pub fn class_winners(
        &mut self,
        kind: EntKind,
        canon: &Ref,
    ) -> Result<Vec<ClassWinner>, String> {
        self.class_registers(kind, canon, None, None)
    }

    /// 一个别名类里一个寄存器（[canon_key] 是规范键）的生效值；没有写入 = None。
    pub fn class_value(
        &mut self,
        kind: EntKind,
        canon: &Ref,
        canon_key: &str,
    ) -> Result<Option<String>, String> {
        Ok(self
            .class_registers(kind, canon, Some(canon_key), None)?
            .into_iter()
            .next()
            .map(|w| w.value))
    }

    /// [Index::class_value]，但只看 [keep] 留下的写入（按操作主键）：这些写入单独重判一遍取胜者——「只有这些操作时
    /// 这个寄存器的值」。时间线恢复（`cmd/writes_restore.rs`）求「那一刻的值」用；判定规则与 [Index::class_value]
    /// 同一份（[Index::judged] 按类）。[keep] 一条都不留 = None。
    pub(super) fn class_value_in(
        &mut self,
        kind: EntKind,
        canon: &Ref,
        canon_key: &str,
        keep: &dyn Fn(i64) -> bool,
    ) -> Result<Option<String>, String> {
        Ok(self
            .class_registers(kind, canon, Some(canon_key), Some(keep))?
            .into_iter()
            .next()
            .map(|w| w.value))
    }

    /// [Index::class_tags]，但只看 [keep] 留下的标签操作（按操作主键），OR-Set 与顺序提示在这些操作上重判。用途同
    /// [Index::class_value_in]。
    pub(super) fn class_tags_in(
        &mut self,
        canon: &Ref,
        keep: &dyn Fn(i64) -> bool,
    ) -> Result<Vec<String>, String> {
        self.aliases_settled()?;
        let mut rows = Vec::new();
        for m in &self.members(canon)? {
            rows.extend(self.tags_rows(m)?.into_iter().filter(|r| keep(r.0)));
        }
        rows.sort();
        rows.dedup();
        let want = self.tag_states(&rows)?;
        for (row, want) in rows.iter_mut().zip(want) {
            row.3 = want;
        }
        self.current_tags(&rows)
    }

    /// 一个别名类（笔记）现在的标签：类内成员的标签操作并起来重判（文件头「标签」），顺序规则同 [Index::tags_of]。
    pub fn class_tags(&mut self, canon: &Ref) -> Result<Vec<String>, String> {
        self.aliases_settled()?;
        // 只有一个成员有标签操作时，并起来的行就是这个成员自己的行，重判与索引层（`weigh.rs` `weigh_tags`，同一个
        // [Index::tag_states]、同一组行）得出同一份状态，直接用；按成员数判会让迁移来的库（每个实体都带一条旧 ID 的
        // 别名，规范 ID 自己没有行）每条笔记都白重判一遍。
        let mut rows = Vec::new();
        let mut with_rows = 0usize;
        for m in &self.members(canon)? {
            let mine = self.tags_rows(m)?;
            with_rows += usize::from(!mine.is_empty());
            rows.extend(mine);
        }
        if with_rows > 1 {
            rows.sort();
            rows.dedup();
            let want = self.tag_states(&rows)?;
            for (row, want) in rows.iter_mut().zip(want) {
                row.3 = want;
            }
        }
        self.current_tags(&rows)
    }

    /// 修改值里嵌的 ID 归一（文件头「内嵌的 ID」）。[key] 是修改键（原值或规范形都行，只看前缀与名字）。
    pub fn canonical_value(&self, key: &str, v: &Value) -> Result<Value, String> {
        value_ids_by(key, v, &|s| self.canonical_text(s))
    }

    /// 整份 JSON 里嵌的 ID 归一（文件头「内嵌的 ID」）。
    pub fn canonical_json(&self, v: &Value) -> Result<Value, String> {
        json_ids_by(v, &|s| self.canonical_text(s), &|k| self.canonical_key(k))
    }

    /// 缓存配置（`cache.rs` 的 `derive_cfg("caches")`，宿主给的）归一：默认牌组、内置笔记类型的代码默认定义（字段 /
    /// 模板 ID、模板文本里的字段引用）、读音字段。配置里的 ID 不一定在操作里出现过（别名表只收出现过的），归一与键、
    /// 值、整份 JSON 走同一个 [Index::canonical_embedded]（先查表、查不到再按规则认内置实体在每个盐下的存量 ID）——
    /// 配置与笔记的 `f/<字段>` 键对同一个带盐字段得出同一个规范 ID。别的值原样。
    pub fn canonical_config(&self, v: &Value) -> Result<Value, String> {
        config_ids_by(v, &|s| self.canonical_text(s), &|k| self.canonical_key(k))
    }

    // ------------------------------------------------------------ 内部

    /// 文本形式的 ID 的规范形：规范形状的 UUID 过别名表，别的原样。
    pub(super) fn canonical_text(&self, s: &str) -> Result<String, String> {
        match strict_id(s) {
            Some(id) => Ok(self.canonical_embedded(&id)?.text()),
            None => Ok(s.to_owned()),
        }
    }

    /// 嵌着的 ID（修改键、修改值、整份 JSON、宿主的缓存配置里的）的规范 ID：先查别名表，表里没有的再按规则认内置实体
    /// 在每个盐下的存量 ID（[builtin_rule_canon]）。别名表只收在操作里作为实体出现过的 ID，内置笔记类型的字段 ID
    /// 通常只嵌在笔记的 `f/<字段>` 键里、从不作为实体出现；缓存配置里内置笔记类型的代码默认定义按规则归一，键里的
    /// 字段 ID 也必须按同一份规则归一，否则带盐的内置笔记（如 Lapis）在缓存层对不上自己的字段、字段值全空。
    pub(super) fn canonical_embedded(&self, id: &Id) -> Result<Ref, String> {
        let canon = self.canonical(&Ref::Uuid(id.0))?;
        if canon == Ref::Uuid(id.0) {
            if let Some(r) = self.rule_canon()?.get(&id.0) {
                return Ok(Ref::Uuid(*r));
            }
        }
        Ok(canon)
    }

    /// 当前盐集合下的内置实体规则表（[builtin_rule_canon]）：物化期间用那一趟缓存的（[Index::pass_rules]），否则按
    /// 盐集合记住，盐集合变了重算。
    fn rule_canon(&self) -> Result<Rc<RuleCanon>, String> {
        if let Some(r) = &self.pass_rules {
            return Ok(r.clone());
        }
        let salts = self.salts()?;
        let mut memo = self.rule_memo.borrow_mut();
        if let Some((s, r)) = memo.as_ref() {
            if *s == salts {
                return Ok(r.clone());
            }
        }
        let r = Rc::new(builtin_rule_canon(&salts));
        *memo = Some((salts, r.clone()));
        Ok(r)
    }

    /// 一次物化（缓存层一趟、浏览一条命令）开始时把规则表算好记下，结束时清掉（同 [Index::pass_writers]）。
    pub(super) fn pass_rules_begin(&mut self) -> Result<(), String> {
        self.pass_rules = None;
        self.pass_rules = Some(self.rule_canon()?);
        Ok(())
    }

    /// 旧并入改名、已归回的写入者（`alias_writer_ix`）：原名 → 规范名，与各原名证据撑得住的范围（`derive_cfg` 的
    /// [WRITER_UPTO_KEY]，[WriterAliases::bound]）。
    pub(super) fn writer_aliases(&self) -> Result<WriterAliases, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached("SELECT name, origin FROM alias_writer_ix WHERE col = ?1")
            .map_err(sql)?;
        let rows = stmt
            .query_map([self.col], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?;
        let names: BTreeMap<String, String> = rows.collect::<Result<_, _>>().map_err(sql)?;
        if names.is_empty() {
            return Ok(WriterAliases::default());
        }
        // 有归回的写入者却没记范围：派生层是 `CACHE_RULES` 4 之前建的、还没重建（宿主打开时的 `cache_config_set`
        // 会重建）。不按已知有错的「整段换」静默判，同别名表没重算一样拒绝按类读。
        let Some(text) = self.t.derive_cfg(self.col, WRITER_UPTO_KEY)? else {
            return Err(format!(
                "gen4 index: renamed writers without {WRITER_UPTO_KEY} (derived layer predates cache rules 4; rebuild first)"
            ));
        };
        let bounds: BTreeMap<String, WriterBound> = serde_json::from_str(&text)
            .map_err(|e| format!("gen4 index: bad {WRITER_UPTO_KEY}: {e}"))?;
        Ok(WriterAliases { names, bounds })
    }

    /// 类内全部成员的寄存器行按规范键成组再判；[only] = 只要这一个规范键；[keep] = 只要这些写入（按操作主键）。
    fn class_registers(
        &mut self,
        kind: EntKind,
        canon: &Ref,
        only: Option<&str>,
        keep: Option<&dyn Fn(i64) -> bool>,
    ) -> Result<Vec<ClassWinner>, String> {
        self.aliases_settled()?;
        let entity = self.canonical(canon)?.text();
        let mut groups: BTreeMap<String, Vec<(i64, i64)>> = BTreeMap::new();
        for m in self.members(canon)? {
            let rows: Vec<(Vec<u8>, i64, i64)> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT key, k, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, kind as i64, m], |r| {
                        let key = match r.get_ref(0)? {
                            ValueRef::Blob(b) => b.to_vec(),
                            _ => Vec::new(),
                        };
                        Ok((key, r.get(1)?, r.get(2)?))
                    })
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            for (key, k, state) in rows {
                let text = read_edit_key(&mut Reader::new(&key))
                    .map_err(|e| format!("gen4 index: bad register key: {e}"))?;
                let ck = self.canonical_key(&text)?;
                if only.is_some_and(|o| o != ck) || keep.is_some_and(|f| !f(k)) {
                    continue;
                }
                groups.entry(ck).or_default().push((k, state));
            }
        }
        let writers = self.writer_aliases()?;
        let renamed = Renamed::default();
        let mut out = Vec::new();
        for (key, mut rows) in groups {
            rows.sort_unstable();
            let c = Canon {
                writers: &writers,
                renamed: &renamed,
                entity: entity.clone(),
                key,
                keys: None,
            };
            let (live, want) = self.judged(&rows, Some(&c))?;
            let Some((&(k, _), &state)) = live.iter().zip(&want).find(|&(_, &s)| s >= R_WINNER)
            else {
                continue;
            };
            let raw = self
                .t
                .edit_value(k)?
                .ok_or_else(|| format!("gen4 index: register row {k} has no edit"))?;
            let parsed: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
            let canonical = self.canonical_value(&c.key, &parsed)?;
            let value = if canonical == parsed {
                raw
            } else {
                canonical.to_string()
            };
            out.push(ClassWinner {
                key: c.key,
                op: self.t.id_of_key(k)?,
                value,
                conflict: state == R_CONFLICT,
            });
        }
        Ok(out)
    }

    /// 缓存层（`cache.rs`）要的：一个别名类（[canon] 可以是类里任何一个 ID）全部寄存器里**按类判定**活着的写入，拼成
    /// 寄存器内核的落库行（实体、键、值、三处写入者都是规范形，[Index::edit_lines_as]），与其中最大的 HLC 物理时刻
    /// （没有 = 0）。别名表没重算时报错。
    ///
    /// 捷径只在「按类判与按原值判一定相同」时走：这个规范键只来自一个 (成员, 原值键)（`reg_ix` 里只有一个原值寄存器
    /// 有行）、寄存器里没有归回涉及的名字（改名后的名字或它的规范名）写的写入（dot 与 HLC 的写入者都看；集合里别处有
    /// 归回写入者不影响这个寄存器）——这时参与判定的行与原值寄存器的行逐条相同，支配关系也逐条相同（dot 不换名、闭包
    /// 不换名、不并寄存器），活着的集合直接取 `reg_ix` 的状态，只把行拼成规范形。类里有几个成员不影响这一点：没有行
    /// 的成员什么也没并进来（迁移来的库里每个实体都带一条旧 ID 的别名，规范 ID 自己却没有行，按成员数判会让捷径全部
    /// 落空、每个寄存器都重判一遍）。值归一只会让「值不同」变少，不影响谁活着（文件头「只有一个成员」一条说的是冲突
    /// 标志，缓存层取的是活着的写入，由寄存器内核在视图里再判）。测试 `the_class_lines_shortcut_is_the_class_judgement`。
    pub(super) fn class_lines(
        &mut self,
        kind: EntKind,
        canon: &Ref,
    ) -> Result<(Vec<(String, Option<i64>)>, i64), String> {
        let (lines, top) = self.class_lines_keyed(kind, canon)?;
        Ok((lines.into_iter().map(|(_, j, st)| (j, st)).collect(), top))
    }

    /// [Index::class_lines]，每行另带它的规范键（行 JSON 的 `f`），调用方不必为取键再解一遍 JSON。
    pub(super) fn class_lines_keyed(
        &mut self,
        kind: EntKind,
        canon: &Ref,
    ) -> Result<(Vec<ClassLine>, i64), String> {
        self.class_lines_by(kind, canon, &Pick::All, true)
    }

    /// 同步冲突（`cmd/reads.rs` 的 `conflict_edits`）要的：别名类 [canon] 里 [tracks] 圈定的规范键上**可能有值不同的
    /// 并发写入**的寄存器，各自按类判定活着的全部写入（行同 [Index::class_lines_keyed]）。只判这些键：别的键（笔记
    /// 字段正文等）不读操作体（BUG-3947 的教训，协议 3 在 SQL 里先按类别筛）。
    ///
    /// 哪些寄存器算「可能有」：走 [Index::class_lines] 捷径的（单一原值寄存器、没有归回写入者）按 `reg_ix` 已落的状态
    /// ——按类判与原值判活着的集合逐条相同，值归一只会让「值不同」变少，所以按类判有冲突的一定在原值判下就是
    /// [R_CONFLICT]（反过来不一定：两个别名写法归一后可以相同，留给调用方的寄存器内核再判）；其余（跨成员、跨原值键
    /// 并起来的，或碰到归回写入者的）按类重判，判出 [R_CONFLICT] 的才要。[pre] 先按原值键文本粗筛（归一前就能断定
    /// 不要的键不去查别名表），[tracks] 按规范键定夺。测试 `conflict_lines_are_the_conflicted_class_registers`。
    pub(super) fn class_conflict_lines(
        &mut self,
        kind: EntKind,
        canon: &Ref,
        pre: &dyn Fn(&str) -> bool,
        tracks: &dyn Fn(&str) -> bool,
    ) -> Result<Vec<ClassLine>, String> {
        Ok(self
            .class_lines_by(kind, canon, &Pick::Conflicts { pre, tracks }, true)?
            .0)
    }

    /// [Index::class_lines_keyed] 与 [Index::class_conflict_lines] 的共同实现。[shortcut] = false 时每个寄存器都按类
    /// 重判（测试拿它对拍捷径）。
    pub(super) fn class_lines_by(
        &mut self,
        kind: EntKind,
        canon: &Ref,
        pick: &Pick<'_>,
        shortcut: bool,
    ) -> Result<(Vec<ClassLine>, i64), String> {
        self.aliases_settled()?;
        let entity = self.canonical(canon)?.text();
        let members = self.members(canon)?;
        let writers = match &self.pass_writers {
            Some(w) => std::rc::Rc::clone(w),
            None => std::rc::Rc::new(self.writer_aliases()?),
        };
        // 规范键 → (写入 (k, state), 来自哪几个 (成员, 原值键))。
        type Group = (Vec<(i64, i64)>, BTreeSet<(Ref, Vec<u8>)>);
        let mut groups: BTreeMap<String, Group> = BTreeMap::new();
        for m in &members {
            for (key, k, state) in self.member_registers(kind, m)? {
                let text = read_edit_key(&mut Reader::new(&key))
                    .map_err(|e| format!("gen4 index: bad register key: {e}"))?;
                if let Pick::Conflicts { pre, .. } = pick {
                    if !pre(&text) {
                        continue;
                    }
                }
                let ck = self.canonical_key(&text)?;
                if let Pick::Conflicts { tracks, .. } = pick {
                    if !tracks(&ck) {
                        continue;
                    }
                }
                let g = groups.entry(ck).or_default();
                g.0.push((k, state));
                g.1.insert((m.clone(), key));
            }
        }
        let conflicts_only = matches!(pick, Pick::Conflicts { .. });
        // 归回涉及的名字（改名后的名字与它的规范名）：寄存器里没有这些名字写的写入时，换名不改变谁见过谁（支配只问
        // 「上下文里这条写入的写入者那一格 ≥ 它的 seq」，那一格的写入者不在换名表里就不变），按类判与按原值判相同。
        let renamed_names: BTreeSet<&str> = writers
            .iter()
            .flat_map(|(n, o)| [n.as_str(), o.as_str()])
            .collect();
        let renamed = Renamed::default();
        // 每个规范键各自判活着的，行最后一次拼：不带旧戳的写入的上下文回答的是「见没见过别的要的行」，要的行跨键算
        // （笔记的「待裁决」看删除见没见过别的键上的内容修改，原值拼法也是整个实体一次拼）。
        let (mut ks, mut emit) = (Vec::new(), Vec::new());
        let mut keys: HashMap<i64, String> = HashMap::new();
        for (key, (mut rows, raw)) in groups {
            rows.sort_unstable();
            if shortcut && raw.len() == 1 && !self.touches_renamed(&rows, &renamed_names)? {
                if conflicts_only && !rows.iter().any(|&(_, s)| s == R_CONFLICT) {
                    continue;
                }
                for &(k, s) in rows.iter().filter(|&&(_, s)| s >= R_DOMINATED) {
                    ks.push(k);
                    emit.push(s >= R_LIVE);
                    keys.insert(k, key.clone());
                }
                continue;
            }
            let c = Canon {
                writers: &writers,
                renamed: &renamed,
                entity: entity.clone(),
                key: key.clone(),
                keys: None,
            };
            self.class_judged += 1;
            let (live, want) = self.judged(&rows, Some(&c))?;
            if conflicts_only && !want.contains(&R_CONFLICT) {
                continue;
            }
            for (&(k, _), &w) in live.iter().zip(&want) {
                ks.push(k);
                emit.push(w >= R_LIVE);
                keys.insert(k, key.clone());
            }
        }
        if !emit.iter().any(|&e| e) {
            return Ok((Vec::new(), 0));
        }
        let c = Canon {
            writers: &writers,
            renamed: &renamed,
            entity,
            key: String::new(),
            keys: Some(&keys),
        };
        let (mut out, mut top) = (Vec::new(), 0i64);
        for l in self.edit_lines_as(&ks, &|i| emit[i], Some(&c))? {
            top = top.max(l.physical);
            out.push((c.key_of(ks[l.rep]).to_owned(), l.json, l.server_time));
        }
        Ok((out, top))
    }

    /// 这组写入（(操作主键, 状态)）里有没有 [names] 里的名字写的（dot 的写入者：带旧戳的取旧戳的写入者，不带的取设备）。
    /// [names] 空时不读操作。
    fn touches_renamed(&self, rows: &[(i64, i64)], names: &BTreeSet<&str>) -> Result<bool, String> {
        if names.is_empty() {
            return Ok(false);
        }
        for &(k, _) in rows {
            let d = self.dot_of(k)?;
            // HLC 的写入者也换（胜负平手时落到它上），一并看。
            let hlc_writer = d.hlc.as_ref().map(|h| h.2.as_str());
            if names.contains(d.writer.as_str()) || hlc_writer.is_some_and(|w| names.contains(w)) {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// 撤销校验（`cmd/center.rs`）的「见没见过」：别名类 [canon]（种类 [kind]）在规范键 [ckey] 上按类拼行时 dot 是
    /// [live]（规范写入者, seq）的那次写入，作者见没见过 dot [ours]（规范写入者, seq）。按 [live] 在这个类的寄存器里找回
    /// 操作（同一个规范 dot 有几条时取操作号最小的代表，与 [Index::edit_lines_as] 并行相同），再从真相层答
    /// （[Index::write_sees]，闭包过同一个换名）。[writers] 是这一次读的归回写入者表（[Index::writer_aliases]）。
    ///
    /// 找不到这个 dot 的写入 = false：只有笔记 `tags` 的合成行（写入者 `sync2:tags:<笔记>`，`cmd/mod.rs` `tags_line`）
    /// 这样，它不是谁写的，没有因果过去（协议 3 那一行也是空上下文）。
    pub(super) fn class_write_sees(
        &mut self,
        kind: EntKind,
        canon: &Ref,
        ckey: &str,
        writers: &WriterAliases,
        live: (&str, i64),
        ours: (&str, i64),
    ) -> Result<bool, String> {
        let canonical_writer = |w: &str| writers.get(w).cloned().unwrap_or_else(|| w.to_owned());
        let mut rep: Option<(OpId, i64)> = None;
        for m in &self.members(canon)? {
            for (key, k, state) in self.member_registers(kind, m)? {
                if state < R_DOMINATED {
                    continue;
                }
                let text = read_edit_key(&mut Reader::new(&key))
                    .map_err(|e| format!("gen4 index: bad register key: {e}"))?;
                if self.canonical_key(&text)? != ckey {
                    continue;
                }
                let d = self.dot_of(k)?;
                if d.seq != live.1 || canonical_writer(&d.writer) != live.0 {
                    continue;
                }
                if rep.is_none_or(|(id, _)| d.op < id) {
                    rep = Some((d.op, k));
                }
            }
        }
        let Some((_, k)) = rep else {
            return Ok(false);
        };
        let renamed = Renamed::default();
        let c = Canon {
            writers,
            renamed: &renamed,
            entity: self.canonical(canon)?.text(),
            key: ckey.to_owned(),
            keys: None,
        };
        self.write_sees(k, ours.0, ours.1, Some(&c))
    }

    /// 一条修改的 dot 与旧 HLC 的物理时刻、计数（带旧戳且 HLC 解得开时才有）。
    fn dot_of(&self, k: i64) -> Result<DotOf, String> {
        let e = self
            .t
            .entry_by_key(k)?
            .ok_or_else(|| format!("gen4 index: register row {k} has no op"))?;
        let Some(Body4::Edit(ed)) = body_of(&e) else {
            return Err(format!("gen4 index: register row {k} is not an edit"));
        };
        Ok(match &ed.stamp {
            Some(s) => DotOf {
                writer: s.writer.clone(),
                seq: s.seq,
                hlc: match &s.hlc {
                    StampHlc::Parsed {
                        physical,
                        counter,
                        writer,
                    } => Some((*physical, *counter, writer.clone())),
                    StampHlc::Raw(_) => None,
                },
                op: e.id,
            },
            None => DotOf {
                writer: e.id.device.text(),
                seq: e.id.seq as i64,
                hlc: None,
                op: e.id,
            },
        })
    }

    /// 一个原值实体在 `reg_ix` 里的全部写入：(修改键的紧凑形, 操作主键, 状态)。
    fn member_registers(
        &self,
        kind: EntKind,
        member: &Ref,
    ) -> Result<Vec<(Vec<u8>, i64, i64)>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT key, k, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![self.col, kind as i64, member], |r| {
                let key = match r.get_ref(0)? {
                    ValueRef::Blob(b) => b.to_vec(),
                    _ => Vec::new(),
                };
                Ok((key, r.get(1)?, r.get(2)?))
            })
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    /// 按类判定相对原值判定的差异（设计 §5.3「按类判定的已知差异」、§10 第 24 条）：迁移报告里逐条列出、逐条佐证的那份。
    /// 只读，别名表没重算时报错。
    ///
    /// 看哪些寄存器：有不止一个成员的类的全部寄存器；有归回的改名写入者时再加全部写入不止一条的寄存器（换名可能
    /// 改变支配，只有一条写入的寄存器怎么判都是它自己胜）。每个寄存器按规范键成组，与原值判定（`reg_ix.state`，干跑的
    /// `registerWinners` 已逐个核对过它与协议 3 相同）逐条比活着的集合与冲突标志：
    ///
    /// - 规范键来自不止一个原值寄存器（两个成员各有一份）：协议 3 里是两个寄存器，没有一对一的基准，只计数
    ///   （[ClassDiffs::merged]）；
    /// - 其余逐条比：原值判下活着、按类判被支配的写入（[Dominated]）要佐证——被支配的 `(w, s)` 在这个集合里另有归到
    ///   同一个规范写入者的名字下的同 seq 记录（[DiffEvidence::Copy]），或 s 不超过那两个名字已证明的重叠区间的上端
    ///   （两个名字下同 seq、同 HLC 物理时刻与计数的记录的最大 seq：同一个写入者的计数器走到那一号时，之前的每一号都
    ///   出自同一段历史，[DiffEvidence::Overlap]）；原值判下被支配、
    ///   按类判反而活着的（[ClassDiff::revived]）与按类判多出来的冲突没有这种佐证，一律算佐证不了。佐证不了的按 bug
    ///   处理（回 resolver 收紧），干跑据此判失败。
    pub fn class_differences(&mut self) -> Result<ClassDiffs, String> {
        self.aliases_settled()?;
        let writers = self.writer_aliases()?;
        let mut cands: BTreeSet<(i64, Ref)> = BTreeSet::new();
        let canons: Vec<Ref> = {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached(
                    "SELECT DISTINCT canon FROM alias_ix WHERE col = ?1 AND canon != id",
                )
                .map_err(sql)?;
            let rows = stmt.query_map([self.col], |r| r.get(0)).map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)?
        };
        for canon in &canons {
            for m in self.members(canon)? {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached("SELECT DISTINCT ekind FROM reg_ix WHERE col = ?1 AND ent = ?2")
                    .map_err(sql)?;
                let kinds = stmt
                    .query_map(params![self.col, m], |r| r.get::<_, i64>(0))
                    .map_err(sql)?;
                for k in kinds {
                    cands.insert((k.map_err(sql)?, canon.clone()));
                }
            }
        }
        if !writers.is_empty() {
            let rows: Vec<(i64, Ref)> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT DISTINCT ekind, ent FROM (SELECT ekind, ent FROM reg_ix WHERE col = ?1 \
                         GROUP BY ekind, ent, key HAVING COUNT(*) > 1)",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map([self.col], |r| Ok((r.get(0)?, r.get(1)?)))
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            for (k, ent) in rows {
                cands.insert((k, self.canonical(&ent)?));
            }
        }
        let renamed = Renamed::default();
        let mut out = ClassDiffs::default();
        let mut dots: Option<WriterDots> = None;
        for (kind, canon) in cands {
            let ek = EntKind::ALL[kind as usize];
            let entity = canon.text();
            let mut groups: BTreeMap<String, Vec<(Ref, Vec<u8>, i64, i64)>> = BTreeMap::new();
            for m in self.members(&canon)? {
                for (key, k, state) in self.member_registers(ek, &m)? {
                    let text = read_edit_key(&mut Reader::new(&key))
                        .map_err(|e| format!("gen4 index: bad register key: {e}"))?;
                    groups.entry(self.canonical_key(&text)?).or_default().push((
                        m.clone(),
                        key,
                        k,
                        state,
                    ));
                }
            }
            for (key, items) in groups {
                let raw: BTreeSet<(&Ref, &Vec<u8>)> = items.iter().map(|x| (&x.0, &x.1)).collect();
                let mut rows: Vec<(i64, i64)> = items.iter().map(|x| (x.2, x.3)).collect();
                rows.sort_unstable();
                let c = Canon {
                    writers: &writers,
                    renamed: &renamed,
                    entity: entity.clone(),
                    key: key.clone(),
                    keys: None,
                };
                let (live, want) = self.judged(&rows, Some(&c))?;
                let class_conflict = want.contains(&R_CONFLICT);
                if raw.len() > 1 {
                    out.merged += 1;
                    if class_conflict {
                        out.merged_conflicts += 1;
                    }
                    continue;
                }
                out.examined += 1;
                let raw_conflict = live.iter().any(|&(_, s)| s == R_CONFLICT);
                let same = live
                    .iter()
                    .zip(&want)
                    .all(|(&(_, have), &w)| (have >= R_LIVE) == (w >= R_LIVE));
                let raw_winner = live.iter().find(|r| r.1 >= R_WINNER).map(|r| r.0);
                let class_winner = live
                    .iter()
                    .zip(&want)
                    .find(|(_, w)| **w >= R_WINNER)
                    .map(|(r, _)| r.0);
                let winner_changed = match (raw_winner, class_winner) {
                    (Some(a), Some(b)) if a == b => false,
                    (Some(a), Some(b)) => {
                        self.winner_value(a, &key)? != self.winner_value(b, &key)?
                    }
                    (a, b) => a.is_some() != b.is_some(),
                };
                // 活着的集合与冲突标志都相同、胜者也没变：没有差异。活着的集合相同而胜者变了的（HLC 平手落到改名的
                // HLC 写入者上，「三处一起换」）照样列出来。
                if same && raw_conflict == class_conflict && !winner_changed {
                    continue;
                }
                let mut dominated = Vec::new();
                let mut revived = Vec::new();
                for (&(k, have), &w) in live.iter().zip(&want) {
                    match (have >= R_LIVE, w >= R_LIVE) {
                        (true, false) => {
                            if dots.is_none() {
                                dots = Some(self.writer_dots(&writers)?);
                            }
                            let d = dots.as_ref().expect("filled above");
                            dominated.push(self.dominated(k, &writers, d)?);
                        }
                        (false, true) => revived.push(self.t.id_of_key(k)?),
                        _ => {}
                    }
                }
                // 胜者变了、却没有哪条写入的死活变了：只可能是 HLC 平手落到了换名的 HLC 写入者上，要佐证这一点。
                let hlc_tie = match (raw_winner, class_winner) {
                    (Some(a), Some(b)) if winner_changed && dominated.is_empty() => {
                        self.hlc_tie_on_renamed(a, b, &writers)?
                    }
                    _ => false,
                };
                let proven = proven_of(
                    &revived,
                    raw_conflict,
                    class_conflict,
                    &dominated,
                    winner_changed,
                    hlc_tie,
                );
                out.diffs.push(ClassDiff {
                    kind: ek,
                    entity: canon.clone(),
                    key,
                    raw_conflict,
                    class_conflict,
                    winner_changed,
                    hlc_tie,
                    dominated,
                    revived,
                    proven,
                });
            }
        }
        Ok(out)
    }

    /// 一条写入的生效值（规范形，嵌的 ID 归一）。
    fn winner_value(&self, k: i64, key: &str) -> Result<Value, String> {
        let raw = self
            .t
            .edit_value(k)?
            .ok_or_else(|| format!("gen4 index: register row {k} has no edit"))?;
        let parsed: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
        self.canonical_value(key, &parsed)
    }

    /// 一条按类判被支配的写入与它的佐证（[Index::class_differences]）。
    fn dominated(
        &self,
        k: i64,
        writers: &BTreeMap<String, String>,
        dots: &WriterDots,
    ) -> Result<Dominated, String> {
        let DotOf {
            writer,
            seq,
            hlc,
            op,
        } = self.dot_of(k)?;
        let own = hlc.map(|(p, c, _)| (p, c));
        let canonical = writers
            .get(&writer)
            .cloned()
            .unwrap_or_else(|| writer.clone());
        // 归到同一个规范写入者的其它名字（规范名自己与它的每个原名，去掉这条写入自己的名字）。
        let others: Vec<&str> = std::iter::once(canonical.as_str())
            .chain(
                writers
                    .iter()
                    .filter(|(_, o)| **o == canonical)
                    .map(|(n, _)| n.as_str()),
            )
            .filter(|n| *n != writer)
            .collect();
        // 「副本」= 另一个名字下同 seq、同 HLC 物理时刻与计数的**同一条**记录（resolver 归回写入者用的同一个判据）。
        // 只看 seq 在不在等于直接假定 resolver 的不变量成立：同 seq 不同 HLC 的记录被放行归回正是要抓的 bug，判
        // [DiffEvidence::Mismatch]，不再拿区间佐证兜（区间内的那一个 seq 已被直接证伪）。这条写入自己的 HLC 不是规范
        // 文本、或另一个名字下那条的解不开时比不了：不给副本佐证，也不判 Mismatch，退到区间佐证。
        let same_seq: Vec<(&str, &Vec<(i64, i64)>)> = others
            .iter()
            .filter_map(|n| dots.get(*n).and_then(|m| m.get(&seq)).map(|hs| (*n, hs)))
            .collect();
        let mut evidence = DiffEvidence::None;
        if let Some((n, _)) = same_seq
            .iter()
            .find(|(_, hs)| own.is_some_and(|h| hs.contains(&h)))
        {
            evidence = DiffEvidence::Copy {
                name: (*n).to_owned(),
            };
        } else if let Some((n, _)) = same_seq
            .iter()
            .find(|(_, hs)| own.is_some() && !hs.is_empty())
        {
            evidence = DiffEvidence::Mismatch {
                name: (*n).to_owned(),
            };
        } else {
            for n in &others {
                if let Some((lo, hi)) = overlap(dots, &writer, n) {
                    if seq <= hi {
                        evidence = DiffEvidence::Overlap {
                            name: (*n).to_owned(),
                            lo,
                            hi,
                        };
                        break;
                    }
                }
            }
        }
        Ok(Dominated {
            op,
            writer,
            seq,
            canonical_writer: canonical,
            evidence,
        })
    }

    /// 原值判的胜者 [raw] 与按类判的胜者 [class] 是不是「HLC 平手、按类判换了 HLC 写入者才翻过来」：两条都带解得开的旧
    /// HLC、物理时刻与计数相同，且至少一条的 HLC 写入者是改名后的名字（[writers] 的键）。
    fn hlc_tie_on_renamed(
        &self,
        raw: i64,
        class: i64,
        writers: &BTreeMap<String, String>,
    ) -> Result<bool, String> {
        let (a, b) = (self.dot_of(raw)?, self.dot_of(class)?);
        Ok(match (a.hlc, b.hlc) {
            (Some((pa, ca, wa)), Some((pb, cb, wb))) => {
                (pa, ca) == (pb, cb) && (writers.contains_key(&wa) || writers.contains_key(&wb))
            }
            _ => false,
        })
    }

    /// 改名写入者与它们的最初写入者名下的全部带旧戳记录：名字 → seq → [(HLC 物理时刻, 计数)]（解不开的 HLC 不记）。
    ///
    /// 与 resolver 归回写入者用同一份证据（`alias.rs` 的 `alias_evidence`：[Truth::for_each_stamp]）：承袭的修改**与
    /// 副本记录**（`op_alias`，协议 3 去重留下的同一条记录的另一份）各自带的旧戳。只扫修改的操作体会漏掉副本记录上的
    /// 旧戳，佐证用的重叠区间比 resolver 认定的窄，resolver 有证据归回的支配在这里反而判成佐证不了。
    fn writer_dots(&self, writers: &BTreeMap<String, String>) -> Result<WriterDots, String> {
        let names: BTreeSet<&str> = writers
            .iter()
            .flat_map(|(n, o)| [n.as_str(), o.as_str()])
            .collect();
        let mut out = WriterDots::new();
        for d in self.t.devices(self.col)? {
            self.t.for_each_stamp(self.col, &d.id, u64::MAX, |_, s| {
                if !names.contains(s.writer.as_str()) {
                    return Ok(());
                }
                let at = out
                    .entry(s.writer.clone())
                    .or_default()
                    .entry(s.seq)
                    .or_default();
                if let StampHlc::Parsed {
                    physical, counter, ..
                } = &s.hlc
                {
                    at.push((*physical, *counter));
                }
                Ok(())
            })?;
        }
        Ok(out)
    }
}

/// 一个按类判与原值判不同的寄存器佐证不佐证得了（[ClassDiff::proven]）：没有复活的写入、没有多出来的冲突、每条被
/// 支配的写入都有佐证；胜者变了而没有被支配的写入时（死活一条没变、只有胜者翻了），只认 HLC 平手落到改名的 HLC 写入者
/// 上（[hlc_tie]）——冻结判据下别的情形翻不过来，翻了就是 bug。
fn proven_of(
    revived: &[OpId],
    raw_conflict: bool,
    class_conflict: bool,
    dominated: &[Dominated],
    winner_changed: bool,
    hlc_tie: bool,
) -> bool {
    revived.is_empty()
        && !(class_conflict && !raw_conflict)
        && dominated.iter().all(|d| d.evidence.is_proof())
        && (!winner_changed || !dominated.is_empty() || hlc_tie)
}

/// 一条修改的 dot（带旧戳的取旧戳，不带的取 (设备, seq)）与旧 HLC（物理时刻, 计数, 写入者；带旧戳且解得开时才有）。
struct DotOf {
    writer: String,
    seq: i64,
    hlc: Option<(i64, i64, String)>,
    op: OpId,
}

/// 改名写入者相关名字下的带旧戳记录（[Index::writer_dots]）。
type WriterDots = BTreeMap<String, BTreeMap<i64, Vec<(i64, i64)>>>;

/// 两个名字已证明的重叠区间：两个名字下同 seq、同 HLC 物理时刻与计数的记录（resolver 归回写入者用的同一个判据）的
/// 最小到最大 seq；一条都没有 = None。
fn overlap(dots: &WriterDots, a: &str, b: &str) -> Option<(i64, i64)> {
    let (xa, xb) = (dots.get(a)?, dots.get(b)?);
    let mut shared = xa.iter().filter(|(seq, hs)| {
        xb.get(seq)
            .is_some_and(|other| hs.iter().any(|h| other.contains(h)))
    });
    let first = *shared.next()?.0;
    let last = shared.last().map_or(first, |(s, _)| *s);
    Some((first, last))
}

/// 一条按类判被支配的写入的佐证（[Index::class_differences]）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DiffEvidence {
    /// 同一个规范写入者的另一个名字下有同 seq、同 HLC 物理时刻与计数的同一条记录（被支配的 `(w, s)` 另有
    /// `(merged-…, s)` 副本，或反过来）。
    Copy { name: String },
    /// s 不超过这条写入的名字与 [name] 已证明的重叠区间 `[lo, hi]` 的上端 `hi`（同 seq 同记录证明到 `hi` 为止是同一段
    /// 历史，`gen4_ids::alias::WriterBound` 同一个口径）。
    Overlap { name: String, lo: i64, hi: i64 },
    /// [name] 下有同 seq 的记录、HLC 却不同：不是同一条记录，归回本身可疑（resolver bug），佐证不了。
    Mismatch { name: String },
    /// 佐证不了：按 bug 处理。
    None,
}

impl DiffEvidence {
    /// 佐证得了（[Copy](DiffEvidence::Copy) 或 [Overlap](DiffEvidence::Overlap)）。
    pub fn is_proof(&self) -> bool {
        matches!(
            self,
            DiffEvidence::Copy { .. } | DiffEvidence::Overlap { .. }
        )
    }
}

/// 一条原值判下活着、按类判被支配的写入。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Dominated {
    pub op: OpId,
    /// 这条写入的 dot：(原名, seq)。不带旧戳的是 (设备, seq)。
    pub writer: String,
    pub seq: i64,
    pub canonical_writer: String,
    pub evidence: DiffEvidence,
}

/// 一个按类判与原值判不同的寄存器（[Index::class_differences]）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClassDiff {
    pub kind: EntKind,
    /// 规范实体、规范键。
    pub entity: Ref,
    pub key: String,
    /// 原值判 / 按类判有没有冲突。
    pub raw_conflict: bool,
    pub class_conflict: bool,
    /// 生效值（规范形）变了。
    pub winner_changed: bool,
    /// 胜者变了、没有哪条写入的死活变：两边胜者 HLC 物理时刻与计数相同、至少一边的 HLC 写入者是改名后的名字
    /// （平手落到换过名的 HLC 写入者上，[Index::hlc_tie_on_renamed]）。这种差异的佐证就是它。
    pub hlc_tie: bool,
    pub dominated: Vec<Dominated>,
    /// 原值判下被支配、按类判反而活着的写入（没有佐证的形态）。
    pub revived: Vec<OpId>,
    /// 每条被支配的写入都有佐证、没有复活的写入、没有多出来的冲突；胜者变了而没有被支配的写入时还要 [hlc_tie]。
    pub proven: bool,
}

/// [Index::class_differences] 的结果。
#[derive(Clone, Debug, Default)]
pub struct ClassDiffs {
    /// 逐条比过的寄存器（规范键只来自一个原值寄存器的）。
    pub examined: u64,
    /// 规范键来自不止一个原值寄存器的（只计数），与其中按类判有冲突的。
    pub merged: u64,
    pub merged_conflicts: u64,
    pub diffs: Vec<ClassDiff>,
}

impl ClassDiffs {
    /// 佐证不了的那几个。
    pub fn unproven(&self) -> impl Iterator<Item = &ClassDiff> {
        self.diffs.iter().filter(|d| !d.proven)
    }
}

/// 文本形式的 ID 换成什么（[Index::canonical_text] 归一；[legacy_config_for] 换回带盐 ID）。不是 ID 的文本原样返回。
pub(super) type IdText<'a> = &'a dyn Fn(&str) -> Result<String, String>;

/// 修改值里嵌的 ID（文件头「内嵌的 ID」）逐个换成 [text] 给的。[key] 是修改键（只看前缀与名字）。
fn value_ids_by(key: &str, v: &Value, text: IdText<'_>) -> Result<Value, String> {
    if ID_VALUED_KEYS.contains(&key) {
        return Ok(match v {
            Value::String(s) => Value::String(text(s)?),
            _ => v.clone(),
        });
    }
    if key.starts_with("tmplDef/") {
        if let Value::Object(m) = v {
            let mut out = m.clone();
            for side in ["front", "back"] {
                if let Some(Value::String(t)) = m.get(side) {
                    out.insert(side.to_owned(), Value::String(template_ids_by(t, text)?));
                }
            }
            return Ok(Value::Object(out));
        }
    }
    Ok(v.clone())
}

/// 整份 JSON 里嵌的 ID（文件头「内嵌的 ID」）逐个换成 [text] 给的；`f` 当修改键交给 [key]。
fn json_ids_by(v: &Value, text: IdText<'_>, key: IdText<'_>) -> Result<Value, String> {
    Ok(match v {
        Value::Object(m) => {
            let edit_key = m.get("f").and_then(Value::as_str);
            let mut out = Map::new();
            for (k, x) in m {
                let y = match (k.as_str(), x) {
                    (k, Value::String(s)) if JSON_ID_KEYS.contains(&k) => Value::String(text(s)?),
                    (k, Value::Array(xs))
                        if JSON_ID_KEYS.contains(&k) && xs.iter().all(Value::is_string) =>
                    {
                        let mut ys = Vec::with_capacity(xs.len());
                        for s in xs.iter().filter_map(Value::as_str) {
                            ys.push(Value::String(text(s)?));
                        }
                        Value::Array(ys)
                    }
                    ("f", Value::String(s)) => Value::String(key(s)?),
                    ("front" | "back", Value::String(s)) => {
                        Value::String(template_ids_by(s, text)?)
                    }
                    ("v", x) if edit_key.is_some() => {
                        value_ids_by(edit_key.unwrap_or_default(), x, text)?
                    }
                    (_, x) => json_ids_by(x, text, key)?,
                };
                out.insert(k.clone(), y);
            }
            Value::Object(out)
        }
        Value::Array(xs) => {
            let mut ys = Vec::with_capacity(xs.len());
            for x in xs {
                ys.push(json_ids_by(x, text, key)?);
            }
            Value::Array(ys)
        }
        _ => v.clone(),
    })
}

/// 宿主缓存配置（`CacheConfig` 的 JSON）里嵌的 ID 逐个换成 [text] 给的：默认牌组、内置笔记类型的代码默认定义（字段 /
/// 模板 ID、模板文本里的字段引用，按 [json_ids_by]）、读音字段。别的值原样。
fn config_ids_by(v: &Value, text: IdText<'_>, key: IdText<'_>) -> Result<Value, String> {
    let Value::Object(m) = v else {
        return Ok(v.clone());
    };
    let mut out = m.clone();
    if let Some(Value::String(d)) = m.get("defaultDeck") {
        out.insert("defaultDeck".to_owned(), Value::String(text(d)?));
    }
    if let Some(Value::Object(bs)) = m.get("builtins") {
        let mut mapped = Map::new();
        for (k, b) in bs {
            let mut b2 = match b {
                Value::Object(x) => x.clone(),
                _ => {
                    mapped.insert(k.clone(), b.clone());
                    continue;
                }
            };
            if let Some(def) = b2.get("b").cloned() {
                b2.insert("b".to_owned(), json_ids_by(&def, text, key)?);
            }
            if let Some(Value::String(r)) = b2.get("reading").cloned() {
                b2.insert("reading".to_owned(), Value::String(text(&r)?));
            }
            mapped.insert(k.clone(), Value::Object(b2));
        }
        out.insert("builtins".to_owned(), Value::Object(mapped));
    }
    Ok(Value::Object(out))
}

/// 模板文本里 `{{…fld:<UUID>}}` 的字段 ID 换成 [text] 给的：分词与替换都走 `card_cache::ids_to_names`（模板渲染认字段
/// 引用的那一份），只换规范形状的 UUID；注释、普通文本原样。
fn template_ids_by(source: &str, text: IdText<'_>) -> Result<String, String> {
    let failed: RefCell<Option<String>> = RefCell::new(None);
    let out = ids_to_names(source, &|id| {
        strict_id(id)?;
        match text(id) {
            Ok(c) => Some(format!("fld:{c}")),
            Err(e) => {
                failed.borrow_mut().get_or_insert(e);
                None
            }
        }
    });
    match failed.into_inner() {
        Some(e) => Err(e),
        None => Ok(out),
    }
}

/// 协议 3 一侧（冻结的旧缓存重建，`compare.rs` [cache_pairs](super::compare::cache_pairs)）要的缓存配置：宿主交给新代
/// 的是规范 ID 的那一份（`derive_cfg`，Dart `srsCacheConfigFor`；G9-7 起不再加盐），协议 3 的库里内置笔记类型、字段、
/// 模板、默认牌组却是按 profile [uid] 加盐的存量 ID。这里按 [builtin_rule_canon] 的反向表（只取 [uid] 这一个盐）把配置里
/// 嵌的规范内置 ID 换回带盐的那个：默认牌组、内置笔记类型的代码默认定义（字段 / 模板 ID、模板文本里的字段引用）、
/// 读音字段，遍历与归一同一份（[config_ids_by]）。本来就是带盐的输入、不是内置实体的 ID 原样。
///
/// 以前迁移把规范配置原样交给协议 3 重建：旧侧算出的内置模板 ID 与库里带盐的对不上，卡 ID 整批换掉，带内置笔记类型
/// 笔记的真实库对拍全部判 aborted（交接 §26 C1）。
pub(crate) fn legacy_config_for(uid: &str, cfg: &str) -> Result<String, String> {
    let back: HashMap<[u8; 16], [u8; 16]> = builtin_rule_canon(&[uid.to_owned()])
        .into_iter()
        .map(|(salted, canon)| (canon, salted))
        .collect();
    let text = |s: &str| -> Result<String, String> {
        Ok(match strict_id(s).and_then(|id| back.get(&id.0)) {
            Some(salted) => Id(*salted).text(),
            None => s.to_owned(),
        })
    };
    let key = |k: &str| key_ids_by(k, &text);
    let v: Value =
        serde_json::from_str(cfg).map_err(|e| format!("gen4 legacy cache config: {e}"))?;
    Ok(config_ids_by(&v, &text, &key)?.to_string())
}

/// 内置实体规则表：存量 ID → 规范 ID（[builtin_rule_canon]）。
pub(crate) type RuleCanon = HashMap<[u8; 16], [u8; 16]>;

/// 内置实体在每个盐下的存量 ID → 规范 ID：内置笔记类型、它们的字段与模板、内置默认牌组。由规则直接算（规则只在
/// `gen4_ids::rules` 一处，表在 `gen4_ids::builtins`），与别名表对出现过的那些 ID 的判定相同（resolver 用的是同两份），
/// 对没在操作里出现过的（别名表不收）也给得出。宿主给的缓存配置（[Index::canonical_config]）与对拍时协议 3 一侧的行
/// （`compare.rs`）用它。
pub(crate) fn builtin_rule_canon(salts: &[String]) -> RuleCanon {
    let mut out = HashMap::new();
    let deck = rules::builtin_default_deck(rules::CANONICAL);
    for salt in salts {
        out.insert(rules::builtin_default_deck(Some(salt)).0, deck.0);
        for b in BUILTIN_NOTE_TYPES {
            let num = rules::builtin_note_type_anki_num(b.key);
            let salted = rules::note_type(Some(salt), num);
            let canon = rules::note_type(rules::CANONICAL, num);
            out.insert(salted.0, canon.0);
            for seed in b.field_seeds {
                let n = rules::builtin_field_anki_num(b.key, seed);
                out.insert(rules::field(&salted, n).0, rules::field(&canon, n).0);
            }
            for t in b.template_keys {
                let n = rules::builtin_template_anki_num(b.key, t);
                out.insert(rules::template(&salted, n).0, rules::template(&canon, n).0);
            }
        }
    }
    out
}

/// 内置笔记类型的规范模板 [tpl]（所属笔记类型的规范 ID 是 [nt]）在 [nt] 的各成员 [nt_members] 下的存量模板 ID
/// （`rules::template(成员, 模板号)`）；[nt] 不是内置笔记类型的规范 ID、[tpl] 不是它的内置模板 = 空。
///
/// 内置模板只嵌在宿主缓存配置的代码默认定义里、从不作为实体出现，别名表里没有它的带盐 ID（同带盐的内置字段，
/// [Index::canonical_embedded]）。缓存层的数字 id 反查表（`cache.rs` `member_numbers`）要拿它配出协议 3 那张卡的 ID：
/// 由笔记类型的成员（作为实体出现过、都在别名表里）按规则算，与盐集合无关，跟着笔记类型的别名类一起变。
pub(crate) fn builtin_template_members(nt: &Ref, nt_members: &[Ref], tpl: &Ref) -> Vec<Ref> {
    let Ref::Uuid(nt_b) = nt else {
        return Vec::new();
    };
    let canon_nt = Id(*nt_b);
    for b in BUILTIN_NOTE_TYPES {
        if rules::note_type(rules::CANONICAL, rules::builtin_note_type_anki_num(b.key)) != canon_nt
        {
            continue;
        }
        for t in b.template_keys {
            let n = rules::builtin_template_anki_num(b.key, t);
            if Ref::Uuid(rules::template(&canon_nt, n).0) != *tpl {
                continue;
            }
            return nt_members
                .iter()
                .filter_map(|m| match m {
                    Ref::Uuid(b) => Some(Ref::Uuid(rules::template(&Id(*b), n).0)),
                    Ref::Text(_) => None,
                })
                .collect();
        }
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::gen4::op::tests::{id, native_edit};
    use crate::gen4::op::{Body4, Edit4};
    use crate::gen4::stamp::HeritageStamp;
    use crate::gen4_ids::rules::{self, CANONICAL};
    use crate::store::gen4::derive::tests::{
        assert_rebuild_is_identity, heritage, native, op, stamp, with,
    };
    use crate::store::gen4::truth::Truth;
    use crate::sync2::id::{Id, Key};

    const U1: &str = "0192f0aa-0000-7000-8000-00000000000a";
    const U2: &str = "0192f0aa-0000-7000-8000-00000000000b";
    const GUID: &str = "guid-1";
    const ANKI_NT: i64 = 1_700_000_000_001;

    fn r(id: Id) -> Ref {
        Ref::Uuid(id.0)
    }

    fn entity(kind: EntKind, id: Id, data: Value) -> Body4 {
        Body4::Entity {
            kind,
            id: Key::Uuid(id),
            data: data.to_string(),
        }
    }

    fn edit(kind: EntKind, entity: Id, k: &str, value: Value) -> Body4 {
        Body4::Edit(Edit4 {
            kind,
            entity: Key::Uuid(entity),
            key: k.to_owned(),
            value: value.to_string(),
            ..native_edit()
        })
    }

    fn tag_add(note: Id, tag: &str) -> Body4 {
        Body4::TagAdd {
            note: Key::Uuid(note),
            tag: tag.to_owned(),
        }
    }

    fn tag_remove(note: Id, tag: &str) -> Body4 {
        Body4::TagRemove {
            note: Key::Uuid(note),
            tag: tag.to_owned(),
        }
    }

    /// 同一条笔记（同 guid）在两个盐下各一份：笔记类型、字段、模板、笔记都带盐。
    struct Twin {
        nt: [Id; 2],
        field: [Id; 2],
        tmpl: [Id; 2],
        note: [Id; 2],
        c_nt: Id,
        c_field: Id,
        c_tmpl: Id,
        c_note: Id,
    }

    fn twin() -> Twin {
        let nt = [
            rules::note_type(Some(U1), ANKI_NT),
            rules::note_type(Some(U2), ANKI_NT),
        ];
        let c_nt = rules::note_type(CANONICAL, ANKI_NT);
        Twin {
            nt,
            field: [rules::field(&nt[0], 0), rules::field(&nt[1], 0)],
            tmpl: [rules::template(&nt[0], 0), rules::template(&nt[1], 0)],
            note: [rules::note(Some(U1), GUID), rules::note(Some(U2), GUID)],
            c_nt,
            c_field: rules::field(&c_nt, 0),
            c_tmpl: rules::template(&c_nt, 0),
            c_note: rules::note(CANONICAL, GUID),
        }
    }

    /// 两份的身份与定义（盐 + 每份的笔记类型、字段定义、笔记）。
    fn twin_ops(w: &Twin) -> Vec<Body4> {
        let mut out = vec![Body4::salts([U1, U2]).unwrap()];
        for i in 0..2 {
            out.push(entity(
                EntKind::NoteType,
                w.nt[i],
                json!({"ankiNum": ANKI_NT}),
            ));
            out.push(edit(
                EntKind::NoteType,
                w.nt[i],
                &format!("fieldDef/{}", w.field[i].text()),
                json!({"ankiNum": 0, "name": "Front"}),
            ));
            out.push(entity(
                EntKind::Note,
                w.note[i],
                json!({"guid": GUID, "noteTypeId": w.nt[i].text()}),
            ));
        }
        out
    }

    fn feed(t: &Truth<'_>, ix: &mut Index<'_, '_>, col: i64, dev: u8, bodies: &[Body4]) {
        for (i, b) in bodies.iter().enumerate() {
            native(t, ix, col, &op(dev, i as u64 + 1, 100 + i as i64, &[], b));
        }
    }

    fn fkey(f: Id) -> String {
        format!("f/{}", f.text())
    }

    /// 按类拼行的四种来路（[Index::class_lines_by]）：(场景名, 0xa1 之后写的修改, 这个规范键上要不要按类重判)。
    /// 每种都是两台设备互不相见地写同一个规范键、值不同（冲突）。
    fn class_line_cases(w: &Twin) -> Vec<(&'static str, Vec<(Id, String, &'static str)>, bool)> {
        let (old, canon) = (w.note[0], w.c_note);
        vec![
            // 迁移来的库：旧 ID 有行、规范 ID 没有行（类里两个成员）。单一原值寄存器，走捷径。
            (
                "only the old member has rows",
                vec![(old, fkey(w.field[0]), "a"), (old, fkey(w.field[0]), "b")],
                false,
            ),
            // 只有规范 ID 有行：同样单一原值寄存器。
            (
                "only the canonical id has rows",
                vec![(canon, fkey(w.c_field), "a"), (canon, fkey(w.c_field), "b")],
                false,
            ),
            // 旧成员与规范 ID 各有一条：跨成员并起来，必须按类重判。
            (
                "both members have rows",
                vec![(old, fkey(w.field[0]), "a"), (canon, fkey(w.c_field), "b")],
                true,
            ),
            // 同一个成员上两个原值键（键里嵌的字段 ID 一个带盐、一个规范）归一成同一个规范键：必须按类重判。
            (
                "two raw keys of one member merge",
                vec![(old, fkey(w.field[0]), "a"), (old, fkey(w.c_field), "b")],
                true,
            ),
        ]
    }

    /// 捷径（单一原值寄存器、没有归回写入者时直接取 `reg_ix` 状态）与逐个按类重判拼出的行逐字节相同，与类里有几个
    /// 成员无关；跨成员、跨原值键并起来的照样重判（[Index::class_judged] 涨）。
    #[test]
    fn the_class_lines_shortcut_is_the_class_judgement() {
        let w = twin();
        for (name, writes, rejudged) in class_line_cases(&w) {
            with(|t, col| {
                t.tx(|t| {
                    let mut ix = Index::new(t, col);
                    feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                    for (i, (e, k, v)) in writes.iter().enumerate() {
                        let b = edit(EntKind::Note, *e, k, json!(v));
                        native(
                            t,
                            &mut ix,
                            col,
                            &op(0xb1 + i as u8, 1, 200 + i as i64, &[], &b),
                        );
                    }
                    ix.settle()?;
                    assert!(ix.members(&r(w.c_note))?.len() > 1, "{name}");
                    for id in [w.note[0], w.c_note] {
                        let before = ix.class_judged;
                        let fast = ix.class_lines_by(EntKind::Note, &r(id), &Pick::All, true)?;
                        assert_eq!(ix.class_judged - before, u64::from(rejudged), "{name}");
                        let slow = ix.class_lines_by(EntKind::Note, &r(id), &Pick::All, false)?;
                        assert_eq!(fast, slow, "{name}");
                        assert_eq!(fast.0.len(), 2, "{name}: both writes live");
                        assert!(fast.0.iter().all(|l| l.0 == fkey(w.c_field)), "{name}");
                    }
                    Ok(())
                })
                .unwrap();
            });
        }
    }

    /// 同步冲突要的行（[Index::class_conflict_lines]）= 按类判有冲突的寄存器的活着的写入：四种来路的冲突都在、与全部
    /// 按类重判得出的行相同；同值的并发写入（两台设备各导入同一个包的「所属牌组」）与不追踪的键不出。
    #[test]
    fn conflict_lines_are_the_conflicted_class_registers() {
        let w = twin();
        for (name, writes, _) in class_line_cases(&w) {
            with(|t, col| {
                t.tx(|t| {
                    let mut ix = Index::new(t, col);
                    feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                    let n = writes.len();
                    for (i, (e, k, v)) in writes.iter().enumerate() {
                        let b = edit(EntKind::Note, *e, k, json!(v));
                        native(
                            t,
                            &mut ix,
                            col,
                            &op(0xb1 + i as u8, 1, 200 + i as i64, &[], &b),
                        );
                        // 同一对设备各写一次同值的所属牌组：两条都活着，不是冲突。
                        let d = edit(EntKind::Note, w.note[0], "deck", json!("d"));
                        native(
                            t,
                            &mut ix,
                            col,
                            &op(0xb1 + i as u8, 2, 300 + i as i64, &[], &d),
                        );
                    }
                    ix.settle()?;
                    let all = |_: &str| true;
                    let slow = ix
                        .class_lines_by(EntKind::Note, &r(w.c_note), &Pick::All, false)?
                        .0;
                    assert_eq!(slow.iter().filter(|l| l.0 == "deck").count(), n, "{name}");
                    let want: Vec<ClassLine> = slow.into_iter().filter(|l| l.0 != "deck").collect();
                    for id in [w.note[0], w.c_note] {
                        let got = ix.class_conflict_lines(EntKind::Note, &r(id), &all, &all)?;
                        assert_eq!(got, want, "{name}");
                        let got =
                            ix.class_conflict_lines(EntKind::Note, &r(id), &all, &|k: &str| {
                                k == "deck"
                            })?;
                        assert!(got.is_empty(), "{name}: untracked or not conflicted");
                    }
                    Ok(())
                })
                .unwrap();
            });
        }
    }

    /// 别名类里只有一个成员有标签操作时，按类读标签不重判也与原值读相同（[Index::class_tags]）。
    #[test]
    fn class_tags_of_a_class_with_one_member_holding_tags_are_the_raw_tags() {
        with(|t, col| {
            let w = twin();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xb1, 1, 200, &[], &tag_add(w.note[0], "x")),
                );
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xb2, 1, 201, &[], &tag_add(w.note[0], "y")),
                );
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xb2, 2, 202, &[(0xb1, 1)], &tag_remove(w.note[0], "x")),
                );
                ix.settle()?;
                assert!(ix.members(&r(w.c_note))?.len() > 1);
                let raw = ix.tags_of(&Key::Uuid(w.note[0]))?;
                assert_eq!(raw, vec!["y".to_owned()]);
                assert_eq!(ix.class_tags(&r(w.c_note))?, raw);
                Ok(())
            })
            .unwrap();
        });
    }

    /// 从没并入过的实体：按类读与按原值读相同（寄存器胜者、冲突、标签）。
    #[test]
    fn a_class_of_one_reads_the_same_as_the_raw_id() {
        with(|t, col| {
            let note = id(3);
            let k = fkey(id(4));
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let a = edit(EntKind::Note, note, &k, json!("a"));
                let b = edit(EntKind::Note, note, &k, json!("b"));
                let due = edit(EntKind::Note, note, "due", json!(3));
                native(t, &mut ix, col, &op(0xa1, 1, 10, &[], &a));
                native(t, &mut ix, col, &op(0xa2, 1, 11, &[], &b));
                native(t, &mut ix, col, &op(0xa1, 2, 12, &[], &due));
                native(t, &mut ix, col, &op(0xa1, 3, 13, &[], &tag_add(note, "x")));
                ix.settle()?;
                let got = ix.class_winners(EntKind::Note, &r(note))?;
                assert_eq!(got.len(), 2);
                for w in &got {
                    let rows = ix.register(EntKind::Note, &Key::Uuid(note), &w.key)?;
                    let (op, state) = rows.iter().find(|(_, s)| *s >= R_WINNER).copied().unwrap();
                    assert_eq!(w.op, op);
                    assert_eq!(w.conflict, state == R_CONFLICT);
                    assert_eq!(
                        Some(w.value.clone()),
                        ix.value(EntKind::Note, &Key::Uuid(note), &w.key)?
                    );
                }
                assert!(got.iter().any(|w| w.key == k && w.conflict));
                assert_eq!(ix.class_tags(&r(note))?, ix.tags_of(&Key::Uuid(note))?);
                assert_eq!(ix.class_tags(&r(note))?, vec!["x".to_owned()]);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 同 guid 的两份带盐笔记：同一字段（键里嵌的字段 ID 也是两份）是一个寄存器，只有一个胜者；见过对方的写入
    /// 盖掉对方，互不相见、值不同才是冲突（§3.4 现规则）。按原值读两份各有一个胜者。
    #[test]
    fn two_salted_copies_of_a_note_are_one_register() {
        with(|t, col| {
            let w = twin();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                ix.settle()?;
                assert_eq!(ix.canonical(&r(w.note[0]))?, r(w.c_note));
                assert_eq!(ix.canonical(&r(w.note[1]))?, r(w.c_note));
                assert_eq!(ix.canonical_key(&fkey(w.field[1]))?, fkey(w.c_field));
                // 先后：0xb1 改第一份，0xb2 见过它之后改第二份。
                let old = edit(EntKind::Note, w.note[0], &fkey(w.field[0]), json!("old"));
                let new = edit(EntKind::Note, w.note[1], &fkey(w.field[1]), json!("new"));
                native(t, &mut ix, col, &op(0xb1, 1, 200, &[], &old));
                native(t, &mut ix, col, &op(0xb2, 1, 201, &[(0xb1, 1)], &new));
                ix.settle()?;
                for i in 0..2 {
                    let raw =
                        ix.register(EntKind::Note, &Key::Uuid(w.note[i]), &fkey(w.field[i]))?;
                    assert_eq!(raw.len(), 1);
                    assert_eq!(raw[0].1, R_WINNER);
                }
                let got = ix.class_winners(EntKind::Note, &r(w.note[0]))?;
                assert_eq!(got.len(), 1);
                assert_eq!(got[0].key, fkey(w.c_field));
                assert_eq!(got[0].value, "\"new\"");
                assert!(!got[0].conflict);
                assert_eq!(got, ix.class_winners(EntKind::Note, &r(w.c_note))?);
                assert_eq!(
                    ix.class_value(EntKind::Note, &r(w.note[1]), &fkey(w.c_field))?,
                    Some("\"new\"".to_owned())
                );
                // 并发：0xb3 见过 0xb1、没见过 0xb2，把第一份改成别的值 → 类里冲突。
                let other = edit(EntKind::Note, w.note[0], &fkey(w.field[0]), json!("other"));
                native(t, &mut ix, col, &op(0xb3, 1, 202, &[(0xb1, 1)], &other));
                ix.settle()?;
                let got = ix.class_winners(EntKind::Note, &r(w.note[1]))?;
                assert_eq!(got.len(), 1);
                assert!(got[0].conflict);
                // 原值读：第一份里 0xb3 盖掉 0xb1，没有冲突。
                let raw = ix.register(EntKind::Note, &Key::Uuid(w.note[0]), &fkey(w.field[0]))?;
                assert!(raw.iter().all(|(_, s)| *s != R_CONFLICT));
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 两份各写了一个「指向同一个笔记类型的不同别名」：值归一后相同，不算冲突。
    #[test]
    fn values_naming_one_entity_by_different_aliases_do_not_conflict() {
        with(|t, col| {
            let w = twin();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                let a = edit(EntKind::Note, w.note[0], "noteType", json!(w.nt[0].text()));
                let b = edit(EntKind::Note, w.note[1], "noteType", json!(w.nt[1].text()));
                native(t, &mut ix, col, &op(0xb1, 1, 200, &[], &a));
                native(t, &mut ix, col, &op(0xb2, 1, 201, &[], &b));
                ix.settle()?;
                let got = ix.class_winners(EntKind::Note, &r(w.c_note))?;
                assert_eq!(got.len(), 1);
                assert_eq!(got[0].key, "noteType");
                assert_eq!(got[0].value, json!(w.c_nt.text()).to_string());
                assert!(!got[0].conflict);
                Ok(())
            })
            .unwrap();
        });
    }

    /// 旧并入改名的写入者归回之后三处一起换：(w1, 2) 的旧上下文写的是改名后的名字，归一后它见过 (w1, 1)，没有
    /// 冲突；按原值判，(w1, 1) 与它并发、值不同 = 冲突。实体从没并入过（类里只有它自己）——单成员也不等于原值读。
    #[test]
    fn a_renamed_writer_on_a_class_of_one_is_not_the_raw_reading() {
        with(|t, col| {
            let merged = format!("merged-{}~w1", rules::merged_writer_hash(U1, "w1").text());
            let write = |value: &str, s: HeritageStamp| {
                Body4::Edit(Edit4 {
                    value: format!("\"{value}\""),
                    stamp: Some(s),
                    ..native_edit()
                })
            };
            let ctx = format!(r#"{{"vv":{{"{merged}":1}}}}"#);
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let salts = Body4::salts([U1]).unwrap();
                native(t, &mut ix, col, &op(0xa1, 1, 1, &[], &salts));
                let x1 = write("x", stamp("w1", 1, r#"{"vv":{}}"#, 100));
                let x2 = write("x", stamp(&merged, 1, r#"{"vv":{}}"#, 100));
                let y = write("y", stamp("w1", 2, &ctx, 200));
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &x1));
                heritage(t, &mut ix, col, op(0xd2, 1, 2, &[], &x2));
                heritage(t, &mut ix, col, op(0xd1, 2, 3, &[], &y));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                let e = native_edit();
                assert_eq!(ix.members(&Ref::of(&e.entity))?.len(), 1);
                let raw = ix.register(EntKind::Note, &e.entity, &e.key)?;
                assert!(raw.iter().any(|(_, s)| *s == R_CONFLICT), "{raw:?}");
                let got = ix.class_winners(EntKind::Note, &Ref::of(&e.entity))?;
                assert_eq!(got.len(), 1);
                assert_eq!(got[0].value, "\"y\"");
                assert!(!got[0].conflict);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 撤销校验的「见没见过」按类问带旧戳的写入（[Index::class_write_sees] → [Index::write_sees] 的旧戳分支）：(w1, 2)
    /// 的旧上下文写的是改名后的 `merged:1`，按类过同一个换名（`Canon::dvv`）后它见过规范 dot (w1, 1)；没写进去的
    /// (w1, 5) 没见过；类里没有的 dot（找不到那次写入）= false。
    ///
    /// 撤销路径上被问的那次写入是不带旧戳的原生写入，旧戳上下文里只有旧写入者名，实际走到这条分支答 true 的情形罕见；
    /// 这里钉住换名本身，不让它退回按原名查。
    #[test]
    fn class_write_sees_renames_a_heritage_context() {
        with(|t, col| {
            let merged = merged_w1();
            let ctx = format!(r#"{{"vv":{{"{merged}":1}}}}"#);
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let salts = Body4::salts([U1]).unwrap();
                native(t, &mut ix, col, &op(0xa1, 1, 1, &[], &salts));
                let x1 = stamped("x", stamp("w1", 1, r#"{"vv":{}}"#, 100));
                let x2 = stamped("x", stamp(&merged, 1, r#"{"vv":{}}"#, 100));
                let y = stamped("y", stamp("w1", 2, &ctx, 200));
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &x1));
                heritage(t, &mut ix, col, op(0xd2, 1, 2, &[], &x2));
                heritage(t, &mut ix, col, op(0xd1, 2, 3, &[], &y));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                let e = native_edit();
                let canon = Ref::of(&e.entity);
                let ckey = ix.canonical_key(&e.key)?;
                let writers = ix.writer_aliases()?;
                let mut sees = |live: (&str, i64), ours: (&str, i64)| {
                    ix.class_write_sees(EntKind::Note, &canon, &ckey, &writers, live, ours)
                };
                assert!(sees(("w1", 2), ("w1", 1))?);
                assert!(!sees(("w1", 2), ("w1", 5))?);
                assert!(!sees(("w1", 9), ("w1", 1))?);
                Ok(())
            })
            .unwrap();
        });
    }

    /// 改名写入者的另一对同一套 seq 的证据：`(w1, seq)` 与 `(merged, seq)` 同一个 HLC，落在 `proof` 键上。
    fn proof_pair(
        t: &Truth<'_>,
        ix: &mut Index<'_, '_>,
        col: i64,
        merged: &str,
        seq: i64,
        slot: u64,
    ) {
        let proof = |w: &str| {
            Body4::Edit(Edit4 {
                key: "proof".to_owned(),
                value: "\"p\"".to_owned(),
                stamp: Some(stamp(w, seq, r#"{"vv":{}}"#, 50 + seq)),
                ..native_edit()
            })
        };
        heritage(t, ix, col, op(0xc1, slot, seq, &[], &proof("w1")));
        heritage(t, ix, col, op(0xc2, slot, seq, &[], &proof(merged)));
    }

    /// 被测寄存器上的已知差异（`proof` 键上的证据不算）。
    fn diffs_on_test_key(ix: &mut Index<'_, '_>) -> Vec<ClassDiff> {
        let e = native_edit();
        ix.class_differences()
            .unwrap()
            .diffs
            .into_iter()
            .filter(|d| d.key == e.key)
            .collect()
    }

    /// 已知差异的「同 seq 副本」佐证：`(w1, 1)` 原值判与 `(w1, 2)` 并发（`(w1, 2)` 的上下文只写了改名后的
    /// `merged:1`），按类判被盖掉；同一个规范写入者另一个名字下有 `(merged, 1)` = 同一条记录，佐证得了。胜者没变。
    #[test]
    fn a_dominated_write_with_a_copy_under_the_other_name_is_proven() {
        with(|t, col| {
            let merged = merged_w1();
            let ctx = format!(r#"{{"vv":{{"{merged}":1}}}}"#);
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let salts = Body4::salts([U1]).unwrap();
                native(t, &mut ix, col, &op(0xa1, 1, 1, &[], &salts));
                let x1 = stamped("x", stamp("w1", 1, r#"{"vv":{}}"#, 100));
                let x2 = stamped("x", stamp(&merged, 1, r#"{"vv":{}}"#, 100));
                let y = stamped("y", stamp("w1", 2, &ctx, 200));
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &x1));
                heritage(t, &mut ix, col, op(0xd2, 1, 2, &[], &x2));
                heritage(t, &mut ix, col, op(0xd1, 2, 3, &[], &y));
                ix.settle()?;
                let got = diffs_on_test_key(&mut ix);
                assert_eq!(got.len(), 1, "{got:?}");
                let d = &got[0];
                assert!(
                    d.raw_conflict && !d.class_conflict && !d.winner_changed,
                    "{d:?}"
                );
                assert_eq!(d.dominated.len(), 1);
                assert_eq!(d.dominated[0].op, op(0xd1, 1, 1, &[], &x1).id);
                assert_eq!(
                    (d.dominated[0].writer.as_str(), d.dominated[0].seq),
                    ("w1", 1)
                );
                assert_eq!(
                    d.dominated[0].evidence,
                    DiffEvidence::Copy {
                        name: merged.clone()
                    }
                );
                assert!(d.proven && d.revived.is_empty());
                assert_eq!(ix.class_differences()?.unproven().count(), 0);
                Ok(())
            })
            .unwrap();
        });
    }

    /// `(merged, 5)` 原值判与 `(v, 1)` 并发（`(v, 1)` 的上下文写的是原名 `w1:5`），按类判被盖掉。另一个名字下没有
    /// seq 5 的副本：两个名字已证明重叠的区间是 `[1, 9]` 时佐证得了（区间佐证）；只到 `[1, 1]` 时 5 落在区间外，
    /// 佐证不了，按 bug 计（`unproven`）。
    #[test]
    fn a_dominated_write_is_proven_only_inside_the_shared_seq_range() {
        for (top, want) in [(9, true), (1, false)] {
            with(|t, col| {
                let merged = merged_w1();
                t.tx(|t| {
                    let mut ix = Index::new(t, col);
                    let salts = Body4::salts([U1]).unwrap();
                    native(t, &mut ix, col, &op(0xa1, 1, 1, &[], &salts));
                    proof_pair(t, &mut ix, col, &merged, 1, 1);
                    if top > 1 {
                        proof_pair(t, &mut ix, col, &merged, top, 2);
                    }
                    let x = stamped("x", stamp(&merged, 5, r#"{"vv":{}}"#, 100));
                    let y = stamped("y", stamp("v", 1, r#"{"vv":{"w1":5}}"#, 200));
                    heritage(t, &mut ix, col, op(0xd1, 1, 20, &[], &x));
                    heritage(t, &mut ix, col, op(0xd2, 1, 21, &[], &y));
                    ix.settle()?;
                    assert_eq!(ix.canonical_writer(&merged)?, "w1");
                    let got = diffs_on_test_key(&mut ix);
                    assert_eq!(got.len(), 1, "{got:?}");
                    let d = &got[0];
                    assert!(d.raw_conflict && !d.class_conflict, "{d:?}");
                    assert_eq!(d.dominated.len(), 1);
                    assert_eq!(
                        (d.dominated[0].writer.as_str(), d.dominated[0].seq),
                        (merged.as_str(), 5)
                    );
                    let evidence = &d.dominated[0].evidence;
                    if want {
                        assert_eq!(
                            *evidence,
                            DiffEvidence::Overlap {
                                name: "w1".to_owned(),
                                lo: 1,
                                hi: top
                            }
                        );
                    } else {
                        assert_eq!(*evidence, DiffEvidence::None);
                    }
                    assert_eq!(d.proven, want);
                    assert_eq!(
                        ix.class_differences()?.unproven().count(),
                        usize::from(!want)
                    );
                    Ok(())
                })
                .unwrap();
            });
        }
    }

    /// 嵌套并入（真实库的形状：w1 的库先并进一份库、w1 在那里改名成 merged，那份库再并进来）：那份库的写入 `(v, 1)`
    /// 上下文写着 `merged:9`，可 merged 名下在这个集合里的记录只到 seq 1（更高的副本被那份库自己裁掉了），w1 名下的
    /// `(w1, 5)` 没有任何「是同一条」的证据。原值判 `(w1, 5)` 与 `(v, 1)` 并发；按类判只把 `merged:9` 换到归回上界
    /// `w1:1`，照样并发——不再凭空判成被支配（修复前这里是一条佐证不了的已知差异，迁移核对因此失败）。
    #[test]
    fn bounded_writer_rename_keeps_writes_above_the_proven_bound_concurrent() {
        with(|t, col| {
            let merged = merged_w1();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let salts = Body4::salts([U1]).unwrap();
                native(t, &mut ix, col, &op(0xa1, 1, 1, &[], &salts));
                proof_pair(t, &mut ix, col, &merged, 1, 1);
                let x = stamped("x", stamp("w1", 5, r#"{"vv":{}}"#, 100));
                let ctx = format!(r#"{{"vv":{{"{merged}":9}}}}"#);
                let y = stamped("y", stamp("v", 1, &ctx, 200));
                heritage(t, &mut ix, col, op(0xd1, 1, 20, &[], &x));
                heritage(t, &mut ix, col, op(0xd2, 1, 21, &[], &y));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                assert_eq!(
                    ix.writer_aliases()?.bound(&merged),
                    Some(&WriterBound {
                        upto: 1,
                        own: vec![]
                    })
                );
                let got = diffs_on_test_key(&mut ix);
                assert!(got.is_empty(), "{got:?}");
                assert_eq!(ix.class_differences()?.unproven().count(), 0);
                let e = native_edit();
                let w: Vec<ClassWinner> = ix
                    .class_winners(EntKind::Note, &Ref::of(&e.entity))?
                    .into_iter()
                    .filter(|w| w.key == e.key)
                    .collect();
                assert_eq!(w.len(), 1, "{w:?}");
                assert!(w[0].conflict, "{w:?}");
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 佐证与 resolver 用同一份证据：副本记录（`op_alias`，协议 3 去重留下的同一条记录的另一份）上的旧戳也算。
    /// merged 名下 seq 5 的那条只以副本记录的形式在（原件是 `(w1, 5)`），`(v, 1)` 的上下文写着 `merged:5`：resolver
    /// 凭 seq 5 上的同一条记录把上界定到 5，按类判 `(w1, 5)` 被支配；佐证也要认出这份副本（[DiffEvidence::Copy]）。
    /// 只扫修改的操作体时 merged 名下只看得到 seq 1，区间 `[1, 1]` 罩不住 5，判成佐证不了（真实库里 102 条这样的寄存器）。
    #[test]
    fn a_copy_record_is_evidence_as_it_is_for_the_resolver() {
        use crate::gen4::heritage::{Alias, HeritageSlot};
        use crate::gen4::translate::T_VERSION;
        with(|t, col| {
            let merged = merged_w1();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let salts = Body4::salts([U1]).unwrap();
                native(t, &mut ix, col, &op(0xa1, 1, 1, &[], &salts));
                proof_pair(t, &mut ix, col, &merged, 1, 1);
                let x = op(
                    0xd1,
                    1,
                    20,
                    &[],
                    &stamped("x", stamp("w1", 5, r#"{"vv":{}}"#, 100)),
                );
                let xid = x.id;
                heritage(t, &mut ix, col, x);
                let copy = OpId {
                    device: id(0xc2),
                    seq: 2,
                };
                let slot = HeritageSlot::alias(
                    copy,
                    [0x77; 8],
                    Alias {
                        kind: crate::gen4::op::KIND_EDIT,
                        wall: 20,
                        logical: 0,
                        of: xid,
                        stamp: Some(stamp(&merged, 5, r#"{"vv":{}}"#, 100)),
                    },
                );
                t.put_heritage(col, &id(0xc0), &slot, T_VERSION)?;
                ix.add(&t.entry(col, &copy)?.expect("copy record landed"))?;
                let ctx = format!(r#"{{"vv":{{"{merged}":5}}}}"#);
                let y = stamped("y", stamp("v", 1, &ctx, 200));
                heritage(t, &mut ix, col, op(0xd2, 1, 21, &[], &y));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                assert_eq!(ix.writer_aliases()?.bound(&merged).map(|b| b.upto), Some(5));
                let got = diffs_on_test_key(&mut ix);
                assert_eq!(got.len(), 1, "{got:?}");
                let d = &got[0];
                assert!(d.raw_conflict && !d.class_conflict, "{d:?}");
                assert_eq!(d.dominated.len(), 1, "{d:?}");
                assert_eq!(
                    d.dominated[0].evidence,
                    DiffEvidence::Copy {
                        name: merged.clone()
                    }
                );
                assert!(d.proven, "{d:?}");
                Ok(())
            })
            .unwrap();
        });
    }

    /// [Canon::dvv] 对改名写入者只换证据撑得住的部分：前缀截到 `upto`，原名自己在 `upto` 以上、前缀以内的记录（5）换成
    /// 规范名的零散 dot，超出的整段留在原名下；零散 dot 落在 `upto` 以内或是原名自己的记录（13）才换名；没有记范围
    /// （[WriterAliases::bound] = None，记范围之前建的派生层）时整段换。
    #[test]
    fn bounded_writer_rename_splits_a_context_at_the_bound() {
        let writers = |bound: Option<WriterBound>| WriterAliases {
            names: BTreeMap::from([("m".to_owned(), "w1".to_owned())]),
            bounds: bound
                .map(|b| BTreeMap::from([("m".to_owned(), b)]))
                .unwrap_or_default(),
        };
        let renamed = Renamed::default();
        let mut d = Dvv::default();
        d.vv.insert("m".to_owned(), 9);
        d.vv.insert("w1".to_owned(), 2);
        d.cloud.insert("m".to_owned(), BTreeSet::from([12, 13]));
        d.cloud.insert("w1".to_owned(), BTreeSet::from([20]));
        let w = writers(Some(WriterBound {
            upto: 3,
            own: vec![5, 11, 13],
        }));
        let c = Canon {
            writers: &w,
            renamed: &renamed,
            entity: String::new(),
            key: String::new(),
            keys: None,
        };
        let got = c.dvv(&d);
        assert!(got.contains("w1", 3) && !got.contains("w1", 4), "{got:?}");
        assert!(got.contains("w1", 5) && !got.contains("w1", 6), "{got:?}");
        // 11 是原名的记录但超出了 m:9 那段前缀：不算见过；13 是零散 dot 里的原名记录：算见过。
        assert!(!got.contains("w1", 11) && got.contains("w1", 13), "{got:?}");
        assert!(got.contains("w1", 20) && !got.contains("w1", 12), "{got:?}");
        assert!(got.contains("m", 9) && got.contains("m", 12), "{got:?}");
        let w = writers(None);
        let c = Canon {
            writers: &w,
            renamed: &renamed,
            entity: String::new(),
            key: String::new(),
            keys: None,
        };
        let got = c.dvv(&d);
        assert!(got.contains("w1", 9) && got.contains("w1", 12), "{got:?}");
    }

    /// 「副本」要是同一条记录（resolver 归回写入者的判据：同 seq、同 HLC 物理时刻与计数）。端到端造不出来——resolver
    /// 见到同 seq 不同 HLC 就不归回（下面先钉住这一点）——佐证正是为了在 resolver 放错时把它抓出来，所以直接喂
    /// [Index::dominated] 一份「已归回」的写入者表与记录表：
    ///
    /// - 另一个名字下同 seq、同 HLC：[DiffEvidence::Copy]；
    /// - 同 seq、HLC 不同：[DiffEvidence::Mismatch]，哪怕 seq 落在两个名字已证明的重叠区间里也不拿区间兜；
    /// - 另一个名字下同 seq 的记录 HLC 解不开（记录表里是空的）：比不了，退到区间佐证；
    /// - 被支配的写入自己的 HLC 不是规范文本（`0100:0:w1` 这种前导零的，[StampHlc::Raw]）：不给副本佐证。
    #[test]
    fn a_same_seq_record_with_another_hlc_is_not_a_copy() {
        with(|t, col| {
            let merged = merged_w1();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let salts = Body4::salts([U1]).unwrap();
                native(t, &mut ix, col, &op(0xa1, 1, 1, &[], &salts));
                let x1 = stamped("x", stamp("w1", 1, r#"{"vv":{}}"#, 100));
                let other = Body4::Edit(Edit4 {
                    key: "other".to_owned(),
                    value: "\"o\"".to_owned(),
                    stamp: Some(stamp(&merged, 1, r#"{"vv":{}}"#, 999)),
                    ..native_edit()
                });
                let raw_hlc = stamped(
                    "z",
                    HeritageStamp {
                        hlc: StampHlc::of("0100:0:w1"),
                        ..stamp("w1", 3, r#"{"vv":{}}"#, 0)
                    },
                );
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &x1));
                heritage(t, &mut ix, col, op(0xd2, 1, 2, &[], &other));
                heritage(t, &mut ix, col, op(0xd1, 2, 3, &[], &raw_hlc));
                ix.settle()?;
                // resolver 自己不放行：seq 1 两个名字下 HLC 不同，不归回。
                assert_eq!(ix.canonical_writer(&merged)?, merged);
                let k1 = t.key_of(col, &op(0xd1, 1, 1, &[], &x1).id)?.unwrap();
                let k3 = t.key_of(col, &op(0xd1, 2, 3, &[], &raw_hlc).id)?.unwrap();
                let writers = BTreeMap::from([(merged.clone(), "w1".to_owned())]);
                let dots = |entries: &[(&str, i64, &[(i64, i64)])]| -> WriterDots {
                    let mut d = WriterDots::new();
                    for (n, s, hs) in entries {
                        d.entry((*n).to_owned())
                            .or_default()
                            .insert(*s, hs.to_vec());
                    }
                    d
                };
                let ev = |ix: &Index<'_, '_>, k: i64, d: &WriterDots| {
                    ix.dominated(k, &writers, d).unwrap().evidence
                };
                let copy = DiffEvidence::Copy {
                    name: merged.clone(),
                };
                assert_eq!(ev(&ix, k1, &dots(&[(&merged, 1, &[(100, 0)])])), copy);
                // 重叠区间 [0, 5]（两个名字下 seq 0、5 各有一对同 HLC 的）里，seq 1 却另有一条 HLC 不同的。
                let overlap_but_mismatch = dots(&[
                    ("w1", 0, &[(10, 0)]),
                    (&merged, 0, &[(10, 0)]),
                    ("w1", 1, &[(100, 0)]),
                    ("w1", 5, &[(500, 0)]),
                    (&merged, 1, &[(999, 0)]),
                    (&merged, 5, &[(500, 0)]),
                ]);
                assert_eq!(
                    ev(&ix, k1, &overlap_but_mismatch),
                    DiffEvidence::Mismatch {
                        name: merged.clone()
                    }
                );
                let unparsed_copy = dots(&[
                    ("w1", 0, &[(10, 0)]),
                    (&merged, 0, &[(10, 0)]),
                    ("w1", 1, &[(100, 0)]),
                    ("w1", 5, &[(500, 0)]),
                    (&merged, 1, &[]),
                    (&merged, 5, &[(500, 0)]),
                ]);
                assert_eq!(
                    ev(&ix, k1, &unparsed_copy),
                    DiffEvidence::Overlap {
                        name: merged.clone(),
                        lo: 0,
                        hi: 5
                    }
                );
                assert_eq!(
                    ev(&ix, k3, &dots(&[(&merged, 3, &[(0, 0)])])),
                    DiffEvidence::None
                );
                assert!(copy.is_proof());
                assert!(
                    !DiffEvidence::Mismatch {
                        name: merged.clone()
                    }
                    .is_proof()
                );
                Ok(())
            })
            .unwrap();
        });
    }

    /// 活着的集合与冲突标志都没变、胜者却变了（HLC 平手落到换过名的 HLC 写入者上，[ClassDiff::hlc_tie]）：照样列为
    /// 已知差异，佐证是平手本身；HLC 不平手时同样的「胜者变了」没有这种佐证。
    #[test]
    fn a_winner_flipped_by_a_renamed_hlc_writer_is_listed_and_proven() {
        with(|t, col| {
            let merged = merged_w1();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                renamed_writer_evidence(t, &mut ix, col, &merged);
                let a = stamped("a", stamp(&merged, 2, r#"{"vv":{}}"#, 100));
                let b = stamped("b", stamp("v", 1, r#"{"vv":{}}"#, 100));
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &a));
                heritage(t, &mut ix, col, op(0xd2, 1, 2, &[], &b));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                let got = diffs_on_test_key(&mut ix);
                assert_eq!(got.len(), 1, "{got:?}");
                let d = &got[0];
                assert!(d.raw_conflict && d.class_conflict, "{d:?}");
                assert!(d.winner_changed && d.hlc_tie, "{d:?}");
                assert!(d.dominated.is_empty() && d.revived.is_empty());
                assert!(d.proven, "{d:?}");
                Ok(())
            })
            .unwrap();
        });
    }

    /// 佐证门槛逐条：复活的写入、多出来的冲突、没佐证的被支配写入都判佐证不了；胜者变了、死活一条没变时只认 HLC 平手。
    #[test]
    fn the_proof_gate_needs_every_piece() {
        let dom = |evidence: DiffEvidence| Dominated {
            op: OpId {
                device: id(1),
                seq: 1,
            },
            writer: "w1".to_owned(),
            seq: 1,
            canonical_writer: "w1".to_owned(),
            evidence,
        };
        let copy = dom(DiffEvidence::Copy {
            name: "m".to_owned(),
        });
        let none = dom(DiffEvidence::None);
        let revived = [OpId {
            device: id(2),
            seq: 1,
        }];
        // (复活, 原值冲突, 按类冲突, 被支配, 胜者变, 平手) → 佐证得了。
        assert!(proven_of(&[], true, false, &[copy.clone()], false, false));
        assert!(proven_of(&[], true, false, &[copy.clone()], true, false));
        assert!(!proven_of(
            &revived,
            true,
            false,
            &[copy.clone()],
            false,
            false
        ));
        assert!(!proven_of(&[], false, true, &[copy.clone()], false, false));
        assert!(!proven_of(
            &[],
            true,
            false,
            &[copy.clone(), none],
            false,
            false
        ));
        assert!(proven_of(&[], true, true, &[], true, true));
        assert!(!proven_of(&[], true, true, &[], true, false));
    }

    /// 按类拼行的捷径看的是**这个寄存器**里有没有改名相关名字的写入，不是整个集合有没有归回写入者：集合里有归回的
    /// 写入者时，只由别的写入者写的寄存器照样直接取 `reg_ix` 的状态（[Index::class_judged] 不涨，两条并发写入都活着）；
    /// 有改名相关名字写入的寄存器才重判。
    #[test]
    fn only_registers_touched_by_a_renamed_writer_are_rejudged() {
        with(|t, col| {
            let merged = merged_w1();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                renamed_writer_evidence(t, &mut ix, col, &merged);
                // 另一条笔记上只有原生写入者的两条并发写入（有冲突）。
                let other = Key::Uuid(id(9));
                let plain = |v: &str| {
                    Body4::Edit(Edit4 {
                        entity: other.clone(),
                        value: format!("\"{v}\""),
                        ..native_edit()
                    })
                };
                native(t, &mut ix, col, &op(0xa2, 1, 10, &[], &plain("p")));
                native(t, &mut ix, col, &op(0xa3, 1, 11, &[], &plain("q")));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                let before = ix.class_judged;
                let (lines, _) = ix.class_lines(EntKind::Note, &Ref::of(&other))?;
                assert_eq!(
                    ix.class_judged, before,
                    "a register without renamed writes takes the shortcut"
                );
                assert_eq!(lines.len(), 2, "{lines:?}");
                let e = native_edit();
                let (proof_lines, _) = ix.class_lines(EntKind::Note, &Ref::of(&e.entity))?;
                assert!(
                    ix.class_judged > before,
                    "the register written by w1 / merged is rejudged"
                );
                assert!(!proof_lines.is_empty());
                Ok(())
            })
            .unwrap();
        });
    }

    /// 改名写入者的名字。
    fn merged_w1() -> String {
        format!("merged-{}~w1", rules::merged_writer_hash(U1, "w1").text())
    }

    /// 带旧戳的一条写入（实体、键取 [native_edit]）。
    fn stamped(value: &str, s: HeritageStamp) -> Body4 {
        Body4::Edit(Edit4 {
            value: format!("\"{value}\""),
            stamp: Some(s),
            ..native_edit()
        })
    }

    /// 改名写入者能归回的证据（「同一套 seq」）：(w1, 1) 与 (merged, 1) 是同一条记录，落在另一个键上，不碰被测的寄存器。
    fn renamed_writer_evidence(t: &Truth<'_>, ix: &mut Index<'_, '_>, col: i64, merged: &str) {
        let salts = Body4::salts([U1]).unwrap();
        native(t, ix, col, &op(0xa1, 1, 1, &[], &salts));
        let proof = |w: &str| {
            Body4::Edit(Edit4 {
                key: "proof".to_owned(),
                value: "\"p\"".to_owned(),
                stamp: Some(stamp(w, 1, r#"{"vv":{}}"#, 50)),
                ..native_edit()
            })
        };
        heritage(t, ix, col, op(0xc1, 1, 1, &[], &proof("w1")));
        heritage(t, ix, col, op(0xc2, 1, 2, &[], &proof(merged)));
    }

    /// HLC 里的写入者也换（设计 §5.3「三处一起换」）：两条并发、物理时刻与计数相同，胜负落到 HLC 写入者上。原名
    /// `merged-…~w1` < `v`，原值判 `v` 胜；归回成 `w1` > `v`，按类判 `w1` 那条胜。两边都是冲突。
    #[test]
    fn the_hlc_writer_is_renamed_too() {
        with(|t, col| {
            let merged = merged_w1();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                renamed_writer_evidence(t, &mut ix, col, &merged);
                let a = stamped("a", stamp(&merged, 2, r#"{"vv":{}}"#, 100));
                let b = stamped("b", stamp("v", 1, r#"{"vv":{}}"#, 100));
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &a));
                heritage(t, &mut ix, col, op(0xd2, 1, 2, &[], &b));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                let e = native_edit();
                let raw = ix.register(EntKind::Note, &e.entity, &e.key)?;
                let winner = raw.iter().find(|(_, s)| *s >= R_WINNER).copied().unwrap();
                assert_eq!(winner, (op(0xd2, 1, 2, &[], &b).id, R_CONFLICT));
                let got: Vec<ClassWinner> = ix
                    .class_winners(EntKind::Note, &Ref::of(&e.entity))?
                    .into_iter()
                    .filter(|w| w.key == e.key)
                    .collect();
                assert_eq!(got.len(), 1);
                assert_eq!(got[0].value, "\"a\"");
                assert!(got[0].conflict);
                Ok(())
            })
            .unwrap();
        });
    }

    /// 不带旧戳的原生写入「见没见过」改名写入者的写入：原生写入依赖的承袭操作带 `merged-…~w1` 的旧戳（闭包里记的
    /// 是原名），按类拼时 dot 是 (w1, 2)，闭包过同一个换名后也是 w1，见过、盖掉它、没有冲突；拿规范名 `w1` 去问没
    /// 换名的闭包会答「没见过」= 误报冲突。
    #[test]
    fn a_native_write_sees_a_renamed_writer_by_its_raw_name() {
        with(|t, col| {
            let merged = merged_w1();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                renamed_writer_evidence(t, &mut ix, col, &merged);
                let x = stamped("x", stamp(&merged, 2, r#"{"vv":{}}"#, 100));
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &x));
                let z = Body4::Edit(Edit4 {
                    value: "\"z\"".to_owned(),
                    ..native_edit()
                });
                native(t, &mut ix, col, &op(0xa2, 1, 300, &[(0xd1, 1)], &z));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                let e = native_edit();
                let raw = ix.register(EntKind::Note, &e.entity, &e.key)?;
                assert!(raw.iter().all(|(_, s)| *s != R_CONFLICT), "{raw:?}");
                let got: Vec<ClassWinner> = ix
                    .class_winners(EntKind::Note, &Ref::of(&e.entity))?
                    .into_iter()
                    .filter(|w| w.key == e.key)
                    .collect();
                assert_eq!(got.len(), 1);
                assert_eq!(got[0].value, "\"z\"");
                assert!(!got[0].conflict);
                Ok(())
            })
            .unwrap();
        });
    }

    /// 原生写入问闭包与带旧戳写入的上下文用同一个换名（设计 §5.3「三处一起换」）。寄存器里只有一条带旧戳的
    /// (`[reg_writer]`, 2)；原生写入依赖的另一条承袭记录落在别的键上，它的旧上下文是 {`[ctx_writer]`: 2}。两个名字
    /// 一个是 `w1`、一个是归回到 `w1` 的 `merged-…~w1`：按类读，原生写入见过那条、盖掉它、没有冲突；按原值读，名字
    /// 不同 = 没见过 = 冲突。两个名字在 seq 3 上另有同一条记录，证明到 seq 3 为止是同一段历史（`WriterBound`）——
    /// 只有 seq 1 的证据时 `merged:2` 换不到 `w1:2`，见 `bounded_writer_rename_*`。
    fn native_write_sees_through_the_renamed_closure(renamed_in_register: bool) {
        with(|t, col| {
            let merged = merged_w1();
            let (reg_writer, ctx_writer) = if renamed_in_register {
                (merged.clone(), "w1".to_owned())
            } else {
                ("w1".to_owned(), merged.clone())
            };
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                renamed_writer_evidence(t, &mut ix, col, &merged);
                proof_pair(t, &mut ix, col, &merged, 3, 2);
                let x = stamped("x", stamp(&reg_writer, 2, r#"{"vv":{}}"#, 100));
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &x));
                let ctx = format!(r#"{{"vv":{{"{ctx_writer}":2}}}}"#);
                let other = Body4::Edit(Edit4 {
                    key: "other".to_owned(),
                    value: "\"o\"".to_owned(),
                    stamp: Some(stamp("v", 1, &ctx, 150)),
                    ..native_edit()
                });
                heritage(t, &mut ix, col, op(0xd3, 1, 2, &[], &other));
                let z = Body4::Edit(Edit4 {
                    value: "\"z\"".to_owned(),
                    ..native_edit()
                });
                native(t, &mut ix, col, &op(0xa2, 1, 300, &[(0xd3, 1)], &z));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                let e = native_edit();
                let raw = ix.register(EntKind::Note, &e.entity, &e.key)?;
                assert!(raw.iter().any(|(_, s)| *s == R_CONFLICT), "{raw:?}");
                let got: Vec<ClassWinner> = ix
                    .class_winners(EntKind::Note, &Ref::of(&e.entity))?
                    .into_iter()
                    .filter(|w| w.key == e.key)
                    .collect();
                assert_eq!(got.len(), 1);
                assert_eq!(got[0].value, "\"z\"");
                assert!(!got[0].conflict, "{got:?}");
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 寄存器里是原名 (w1, 2)，闭包记的是改名后的 merged:2。
    #[test]
    fn a_native_write_sees_a_raw_writer_through_a_renamed_closure() {
        native_write_sees_through_the_renamed_closure(false);
    }

    /// 寄存器里是改名后的 (merged, 2)，闭包记的是原名 w1:2。
    #[test]
    fn a_native_write_sees_a_renamed_writer_through_a_raw_closure() {
        native_write_sees_through_the_renamed_closure(true);
    }

    /// 别名表没重算（还没 settle、或 [Index::hold_aliases] 攒着）时按类读报错，不拿旧别名表静默判；重算之后照常。
    #[test]
    fn class_reads_refuse_a_stale_alias_table() {
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let e = native_edit();
                let at = Ref::of(&e.entity);
                ix.hold_aliases(true);
                renamed_writer_evidence(t, &mut ix, col, &merged_w1());
                let refused = |ix: &mut Index<'_, '_>| {
                    assert!(ix.aliases_stale());
                    assert!(ix.class_winners(EntKind::Note, &at).is_err());
                    assert!(ix.class_value(EntKind::Note, &at, "proof").is_err());
                    assert!(ix.class_tags(&at).is_err());
                };
                refused(&mut ix);
                ix.settle()?;
                refused(&mut ix);
                ix.hold_aliases(false);
                ix.settle()?;
                assert!(!ix.aliases_stale());
                assert_eq!(
                    ix.class_value(EntKind::Note, &at, "proof")?,
                    Some("\"p\"".to_owned())
                );
                assert!(ix.class_tags(&at)?.is_empty());
                Ok(())
            })
            .unwrap();
        });
    }

    /// 标签按类内成员并起来判：第二份上的删除见过第一份上的添加 → 抹掉；与它并发的添加留着。
    #[test]
    fn tags_are_one_observed_remove_set_across_the_class() {
        with(|t, col| {
            let w = twin();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                let (n0, n1) = (w.note[0], w.note[1]);
                native(t, &mut ix, col, &op(0xb1, 1, 200, &[], &tag_add(n0, "a")));
                native(t, &mut ix, col, &op(0xb1, 2, 201, &[], &tag_add(n0, "b")));
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xb2, 1, 202, &[(0xb1, 1)], &tag_remove(n1, "a")),
                );
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xb2, 2, 203, &[(0xb1, 1)], &tag_remove(n1, "b")),
                );
                native(t, &mut ix, col, &op(0xb3, 1, 204, &[], &tag_add(n1, "c")));
                ix.settle()?;
                assert_eq!(
                    ix.tags_of(&Key::Uuid(n0))?,
                    vec!["a".to_owned(), "b".to_owned()]
                );
                assert_eq!(
                    ix.class_tags(&r(w.c_note))?,
                    vec!["b".to_owned(), "c".to_owned()]
                );
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 内嵌的 ID：`fieldDesc/` 键、值本身是 ID 的键、模板文本里的 `{{fld:…}}`、整份 JSON；用户文本不动。
    #[test]
    fn embedded_ids_are_canonicalized_where_they_are_ids_and_nowhere_else() {
        with(|t, col| {
            let w = twin();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                let tmpl = edit(
                    EntKind::NoteType,
                    w.nt[1],
                    &format!("tmplDef/{}", w.tmpl[1].text()),
                    json!({"ankiNum": 0, "name": "Card 1"}),
                );
                native(t, &mut ix, col, &op(0xa1, 8, 300, &[], &tmpl));
                ix.settle()?;
                let f1 = w.field[1].text();
                let cf = w.c_field.text();
                assert_eq!(
                    ix.canonical_key(&format!("fieldDesc/{f1}"))?,
                    format!("fieldDesc/{cf}")
                );
                assert_eq!(
                    ix.canonical_key("fieldDesc/not-an-id")?,
                    "fieldDesc/not-an-id"
                );
                assert_eq!(
                    ix.canonical_key(&format!("tmplDef/{}", w.tmpl[1].text()))?,
                    format!("tmplDef/{}", w.c_tmpl.text())
                );
                assert_eq!(
                    ix.canonical_value("noteType", &json!(w.nt[0].text()))?,
                    json!(w.c_nt.text())
                );
                // 字段内容是用户文本：长得像 ID 也不动。
                assert_eq!(
                    ix.canonical_value(&fkey(w.field[1]), &json!(f1))?,
                    json!(f1)
                );
                let front =
                    format!("{{{{fld:{f1}}}}} fld:{f1} {{{{#fld:{f1}}}}}x{{{{/fld:{f1}}}}}");
                let tpl = json!({"name": "Card 1", "front": front, "back": "{{FrontSide}}"});
                let got = ix.canonical_value(&format!("tmplDef/{}", w.tmpl[1].text()), &tpl)?;
                let want = format!("{{{{fld:{cf}}}}} fld:{f1} {{{{#fld:{cf}}}}}x{{{{/fld:{cf}}}}}");
                assert_eq!(got["front"], json!(want));
                // 注释与 `{{…}}` 里不是整段字段引用的：模板渲染不认，这里也不动（与 `ids_to_names` 同一个分词）。
                let comments = format!(
                    "<!-- {{{{fld:{f1}}}}} --> {{{{!-- 见 fld:{f1} --}}}} {{{{Text:fld:{f1}}}}}"
                );
                let skipped = ix.canonical_value(
                    &format!("tmplDef/{}", w.tmpl[1].text()),
                    &json!({"front": comments}),
                )?;
                let kept = format!(
                    "<!-- {{{{fld:{f1}}}}} --> {{{{!-- 见 fld:{f1} --}}}} {{{{Text:fld:{cf}}}}}"
                );
                assert_eq!(skipped["front"], json!(kept));
                assert_eq!(got["name"], tpl["name"]);
                assert_eq!(got["back"], tpl["back"]);
                let doc = json!({
                    "id": w.note[1].text(),
                    "d": {"guid": GUID, "noteTypeId": w.nt[1].text()},
                    "edits": [
                        {"f": fkey(w.field[1]), "v": f1},
                        {"f": "noteType", "v": w.nt[0].text()},
                    ],
                    "revokes": [w.note[0].text(), "r1"],
                });
                assert_eq!(
                    ix.canonical_json(&doc)?,
                    json!({
                        "id": w.c_note.text(),
                        "d": {"guid": GUID, "noteTypeId": w.c_nt.text()},
                        "edits": [
                            {"f": fkey(w.c_field), "v": f1},
                            {"f": "noteType", "v": w.c_nt.text()},
                        ],
                        "revokes": [w.c_note.text(), "r1"],
                    })
                );
                Ok(())
            })
            .unwrap();
        });
    }

    /// 逐条维护与重建之后，按类读的输出相同。
    #[test]
    fn class_reads_are_the_same_after_a_rebuild() {
        with(|t, col| {
            let w = twin();
            let read = |t: &Truth<'_>| {
                t.tx(|t| {
                    let mut ix = Index::new(t, col);
                    Ok((
                        ix.class_winners(EntKind::Note, &r(w.c_note))?,
                        ix.class_tags(&r(w.c_note))?,
                    ))
                })
                .unwrap()
            };
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                for (n, (i, v)) in [(0, "p"), (1, "q"), (0, "r")].into_iter().enumerate() {
                    let dev = 0xb1 + n as u8;
                    let e = edit(EntKind::Note, w.note[i], &fkey(w.field[i]), json!(v));
                    native(t, &mut ix, col, &op(dev, 1, 200 + n as i64, &[], &e));
                    native(
                        t,
                        &mut ix,
                        col,
                        &op(dev, 2, 300 + n as i64, &[], &tag_add(w.note[i], v)),
                    );
                    ix.settle()?;
                }
                Ok(())
            })
            .unwrap();
            let before = read(t);
            assert_eq!(before.0.len(), 1);
            assert!(before.0[0].conflict);
            assert_eq!(before.1.len(), 3);
            assert_rebuild_is_identity(t, col);
            assert_eq!(read(t), before);
        });
    }

    /// 真实样本库：`gen4_sample_index` 重建好的新代文件上量「按类判定」与「按原值判定」差多少（设计 §12：归回去的
    /// 写入者 ctx 归一后判定是否与原件一致没比过；G9-1 要先量，有差异就停下报所有者）。只读（一个回滚掉的读事务）。
    ///
    /// 报三组数：
    /// - `classes`：有不止一个成员的别名类，按种类数类、寄存器（规范键）、其中写入来自不止一个成员的（并起来的）、
    ///   并起来后胜者值与各成员原值胜者归一后的值不全相同的、按类新出现的冲突 / 消失的冲突；笔记类的标签与各成员
    ///   原值标签之并不同的。
    /// - `writers`：归回的改名写入者、它们名下的修改记录条数；写入不止一条的寄存器里只换写入者（实体、键不变）
    ///   重判后状态与原值判定不同的寄存器数（列前 10 个）。
    ///
    /// `FUSHI_GEN4_OUT=<gen4_sample_index 跑过的文件> cargo test --release --lib gen4_sample_class -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn gen4_sample_class() {
        use std::collections::BTreeSet;
        use std::time::Instant;

        use crate::store::gen4::derive::{R_LIVE, body_of};
        use crate::store::gen4::legacy::tests::peak_mem_mb;
        use crate::store::gen4::schema::open;

        let Ok(out) = std::env::var("FUSHI_GEN4_OUT") else {
            println!("FUSHI_GEN4_OUT not set");
            return;
        };
        let dst = open(std::path::Path::new(&out)).unwrap();
        let t = Truth::new(&dst);
        let cols: Vec<i64> = dst
            .prepare("SELECT col FROM collections ORDER BY col")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        for col in cols {
            dst.execute_batch("BEGIN").unwrap();
            let started = Instant::now();
            let mut ix = Index::new(&t, col);
            // ---- 有不止一个成员的类
            let canons: Vec<Ref> = dst
                .prepare(
                    "SELECT DISTINCT canon FROM alias_ix WHERE col = ?1 AND canon != id ORDER BY canon",
                )
                .unwrap()
                .query_map([col], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect();
            let mut by_kind: BTreeMap<i64, [u64; 8]> = BTreeMap::new();
            let (mut tag_classes, mut tag_diff) = (0u64, 0u64);
            let mut samples: Vec<String> = Vec::new();
            let mut gone: BTreeMap<i64, Vec<String>> = BTreeMap::new();
            for canon in &canons {
                let members = ix.members(canon).unwrap();
                let mut kinds: BTreeSet<i64> = BTreeSet::new();
                for m in &members {
                    let mut stmt = dst
                        .prepare_cached(
                            "SELECT DISTINCT ekind FROM reg_ix WHERE col = ?1 AND ent = ?2",
                        )
                        .unwrap();
                    kinds.extend(
                        stmt.query_map(params![col, m], |r| r.get::<_, i64>(0))
                            .unwrap()
                            .map(Result::unwrap),
                    );
                }
                for kind in kinds {
                    let ek = EntKind::ALL[kind as usize];
                    let c = by_kind.entry(kind).or_default();
                    c[0] += 1;
                    // 原值：每个成员各自的胜者，按规范键成组（值归一后）。
                    let mut raw: BTreeMap<String, Vec<(Ref, String, bool)>> = BTreeMap::new();
                    for m in &members {
                        let rows: Vec<(Vec<u8>, i64, i64)> = dst
                            .prepare_cached(
                                "SELECT key, k, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND state >= ?4",
                            )
                            .unwrap()
                            .query_map(params![col, kind, m, R_WINNER], |r| {
                                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                            })
                            .unwrap()
                            .map(Result::unwrap)
                            .collect();
                        for (key, k, state) in rows {
                            let text = read_edit_key(&mut Reader::new(&key)).unwrap();
                            let ck = ix.canonical_key(&text).unwrap();
                            let v: Value = serde_json::from_str(&t.edit_value(k).unwrap().unwrap())
                                .unwrap_or(Value::Null);
                            let v = ix.canonical_value(&ck, &v).unwrap().to_string();
                            raw.entry(ck)
                                .or_default()
                                .push((m.clone(), v, state == R_CONFLICT));
                        }
                    }
                    let class = ix.class_winners(ek, canon).unwrap();
                    c[1] += class.len() as u64;
                    for w in &class {
                        let Some(rs) = raw.get(&w.key) else {
                            c[6] += 1;
                            continue;
                        };
                        let from: BTreeSet<&Ref> = rs.iter().map(|x| &x.0).collect();
                        if from.len() > 1 {
                            c[2] += 1;
                        }
                        let canon_v: Value = serde_json::from_str(&w.value).unwrap();
                        let same = rs.iter().all(|x| {
                            serde_json::from_str::<Value>(&x.1).ok().as_ref() == Some(&canon_v)
                        });
                        if !same {
                            c[3] += 1;
                            if samples.len() < 10 {
                                samples.push(format!(
                                    "kind {kind} canon {} key {} class {} raw {:?}",
                                    canon.text(),
                                    w.key,
                                    w.value,
                                    rs.iter().map(|x| &x.1).collect::<Vec<_>>()
                                ));
                            }
                        }
                        let raw_conflict = rs.iter().any(|x| x.2);
                        if w.conflict && !raw_conflict {
                            c[4] += 1;
                        }
                        if !w.conflict && raw_conflict {
                            c[5] += 1;
                            // 不换写入者（空表）再判一次：冲突回来了 = 是写入者归回让冲突消失的。
                            let mut rows: Vec<(i64, i64)> = Vec::new();
                            for m in &members {
                                let mut stmt = dst
                                    .prepare_cached(
                                        "SELECT key, k, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3",
                                    )
                                    .unwrap();
                                let got: Vec<(Vec<u8>, i64, i64)> = stmt
                                    .query_map(params![col, kind, m], |r| {
                                        Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                                    })
                                    .unwrap()
                                    .map(Result::unwrap)
                                    .collect();
                                for (key, k, state) in got {
                                    let text = read_edit_key(&mut Reader::new(&key)).unwrap();
                                    if ix.canonical_key(&text).unwrap() == w.key {
                                        rows.push((k, state));
                                    }
                                }
                            }
                            rows.sort_unstable();
                            let none = WriterAliases::default();
                            let fresh = Renamed::default();
                            let plain = Canon {
                                writers: &none,
                                renamed: &fresh,
                                entity: canon.text(),
                                key: w.key.clone(),
                                keys: None,
                            };
                            let (_, want) = ix.judged(&rows, Some(&plain)).unwrap();
                            if want.contains(&R_CONFLICT) {
                                c[7] += 1;
                            }
                            if gone.entry(kind).or_default().len() < 5 {
                                // 原值冲突里各条活着的写入的值（原样与归一后）：看冲突是怎么没的。
                                let mut live: Vec<String> = Vec::new();
                                for m in &members {
                                    let rows: Vec<(Vec<u8>, i64, i64)> = dst
                                        .prepare_cached(
                                            "SELECT key, k, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND state >= ?4",
                                        )
                                        .unwrap()
                                        .query_map(params![col, kind, m, R_LIVE], |r| {
                                            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                                        })
                                        .unwrap()
                                        .map(Result::unwrap)
                                        .collect();
                                    for (key, k, state) in rows {
                                        let text = read_edit_key(&mut Reader::new(&key)).unwrap();
                                        if ix.canonical_key(&text).unwrap() != w.key {
                                            continue;
                                        }
                                        let raw = t.edit_value(k).unwrap().unwrap();
                                        let v: Value =
                                            serde_json::from_str(&raw).unwrap_or(Value::Null);
                                        let cv = ix.canonical_value(&w.key, &v).unwrap();
                                        live.push(format!(
                                            "[member {} state {state} raw {raw} canon {cv}]",
                                            m.text()
                                        ));
                                    }
                                }
                                gone.entry(kind).or_default().push(format!(
                                    "kind {kind} canon {} key {} members_with_writes {} class {} live {}",
                                    canon.text(),
                                    w.key,
                                    from.len(),
                                    w.value,
                                    live.join(" ")
                                ));
                            }
                        }
                    }
                    if ek == EntKind::Note {
                        tag_classes += 1;
                        let mut union: BTreeSet<String> = BTreeSet::new();
                        for m in &members {
                            union.extend(ix.tags_of(&Key::of(&m.text())).unwrap());
                        }
                        let got: BTreeSet<String> =
                            ix.class_tags(canon).unwrap().into_iter().collect();
                        if got != union {
                            tag_diff += 1;
                        }
                    }
                }
            }
            println!(
                "SAMPLE class col {col} multi_member_classes {} s {:.1}",
                canons.len(),
                started.elapsed().as_secs_f64()
            );
            for (kind, c) in &by_kind {
                println!(
                    "SAMPLE class kind {kind} classes {} registers {} merged {} value_differs {} new_conflicts {} gone_conflicts {} (of which back_without_writer_aliases {}) class_only_keys {}",
                    c[0], c[1], c[2], c[3], c[4], c[5], c[7], c[6]
                );
            }
            println!(
                "SAMPLE class tags note_classes {tag_classes} differ_from_member_union {tag_diff}"
            );
            for s in &samples {
                println!("SAMPLE class value_differs {s}");
            }
            for s in gone.values().flatten() {
                println!("SAMPLE class gone_conflict {s}");
            }
            // ---- 归回的写入者
            let started = Instant::now();
            let writers = ix.writer_aliases().unwrap();
            let renamed = Renamed::default();
            let names: BTreeSet<&str> = writers.keys().map(String::as_str).collect();
            let all: Vec<(i64, Ref, Vec<u8>, i64, i64)> = dst
                .prepare("SELECT ekind, ent, key, k, state FROM reg_ix WHERE col = ?1 ORDER BY ekind, ent, key, k")
                .unwrap()
                .query_map([col], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
                })
                .unwrap()
                .map(Result::unwrap)
                .collect();
            let mut renamed_edits = 0u64;
            let mut ctx_mentions = 0u64;
            let mut regs: BTreeMap<(i64, Ref, Vec<u8>), Vec<(i64, i64)>> = BTreeMap::new();
            let mut touched: BTreeSet<(i64, Ref, Vec<u8>)> = BTreeSet::new();
            for (ekind, ent, key, k, state) in all {
                let reg = (ekind, ent, key);
                if !names.is_empty() {
                    let e = t.entry_by_key(k).unwrap().unwrap();
                    if let Some(Body4::Edit(ed)) = body_of(&e) {
                        if ed
                            .stamp
                            .as_ref()
                            .is_some_and(|s| names.contains(s.writer.as_str()))
                        {
                            renamed_edits += 1;
                            touched.insert(reg.clone());
                        }
                        // 旧上下文的键里提到改名写入者的（换名会改它见过谁）。
                        if ed.stamp.as_ref().is_some_and(|s| {
                            s.ctx
                                .entries()
                                .iter()
                                .any(|e| names.contains(e.writer.as_str()))
                        }) {
                            ctx_mentions += 1;
                            touched.insert(reg.clone());
                        }
                    }
                }
                regs.entry(reg).or_default().push((k, state));
            }
            let (mut judged, mut differ) = (0u64, 0u64);
            let mut wsamples: Vec<String> = Vec::new();
            for (reg, rows) in &regs {
                if rows.len() < 2 || !touched.contains(reg) {
                    continue;
                }
                judged += 1;
                let key = read_edit_key(&mut Reader::new(&reg.2)).unwrap();
                let c = Canon {
                    writers: &writers,
                    renamed: &renamed,
                    entity: reg.1.text(),
                    key: key.clone(),
                    keys: None,
                };
                let (live, want) = ix.judged(rows, Some(&c)).unwrap();
                let have: Vec<i64> = live.iter().map(|x| x.1).collect();
                if have != want {
                    differ += 1;
                    if wsamples.len() < 10 {
                        wsamples.push(format!(
                            "ent {} key {key} raw {have:?} renamed {want:?}",
                            reg.1.text()
                        ));
                    }
                }
            }
            println!(
                "SAMPLE class writers {} renamed_edits {renamed_edits} ctx_mentions {ctx_mentions} multi_write_registers_touched {judged} state_differs {differ} s {:.1}",
                writers.len(),
                started.elapsed().as_secs_f64()
            );
            for s in &wsamples {
                println!("SAMPLE class writer_differs {s}");
            }
            dst.execute_batch("ROLLBACK").unwrap();
            let (ws, commit) = peak_mem_mb();
            println!("SAMPLE class peak_working_set_mb {ws:.0} peak_commit_mb {commit:.0}");
        }
    }

    /// 一份内置 Lapis 的缓存配置（宿主 `srsCacheConfigFor` 的形状），内置 ID 按 [salt] 的规则派生（`None` = 规范）。
    fn lapis_cfg(salt: Option<&str>) -> Value {
        let num = rules::builtin_note_type_anki_num("lapis");
        let nt = rules::note_type(salt, num);
        let f = rules::field(&nt, rules::builtin_field_anki_num("lapis", "Expression")).text();
        let tpl = rules::template(&nt, rules::builtin_template_anki_num("lapis", "Card 1")).text();
        json!({
            "defaultDeck": rules::builtin_default_deck(salt).text(),
            "builtins": {"lapis": {"b": {
                "name": "Lapis", "css": "", "termFieldId": f,
                "fields": [{"id": f, "name": "Expression", "ord": 0}],
                "templates": [{
                    "id": tpl, "name": "Card 1", "ord": 0,
                    "front": format!("{{{{fld:{f}}}}}"), "back": "{{FrontSide}}",
                }],
            }, "reading": f}},
        })
    }

    /// 协议 3 一侧的配置由内核从规范配置派生（[legacy_config_for]）：默认牌组、内置类型的字段 / 模板 ID、模板里的字段
    /// 引用、词条与读音字段全部换回这个 uid 的带盐 ID，与按带盐规则直接算的那份逐值相同；本来就带盐的输入原样；
    /// 换回来的再归一（同一个盐）回到规范配置。
    #[test]
    fn the_protocol_3_config_is_derived_from_the_canonical_one() {
        let canon = lapis_cfg(CANONICAL);
        let salted = lapis_cfg(Some(U1));
        assert_ne!(canon, salted);
        let legacy: Value =
            serde_json::from_str(&legacy_config_for(U1, &canon.to_string()).unwrap()).unwrap();
        assert_eq!(legacy, salted);
        let again: Value =
            serde_json::from_str(&legacy_config_for(U1, &salted.to_string()).unwrap()).unwrap();
        assert_eq!(again, salted, "a salted config must pass through");
        assert!(legacy_config_for(U1, "not json").is_err());
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &[Body4::salts([U1]).unwrap()]);
                ix.settle()?;
                assert_eq!(ix.canonical_config(&legacy)?, canon);
                Ok(())
            })
            .unwrap();
        });
    }

    /// 只嵌在键里、从不作为实体出现的带盐内置字段（没改过的内置笔记类型）：笔记的 `f/<字段>` 键、修改值、整份 JSON 与
    /// 宿主缓存配置对它得出同一个规范 ID（都经 [Index::canonical_embedded]）。实体口径的 [Index::canonical] 只查表：
    /// 它不在别名表里，别名类就是它自己，[Index::members] 不会给出一个不含它自己的类。
    #[test]
    fn an_embedded_builtin_field_has_one_canonical_id_everywhere() {
        let num = rules::builtin_note_type_anki_num("lapis");
        let s_nt = rules::note_type(Some(U1), num);
        let c_nt = rules::note_type(CANONICAL, num);
        let n = rules::builtin_field_anki_num("lapis", "Expression");
        let (s_f, c_f) = (rules::field(&s_nt, n), rules::field(&c_nt, n));
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &[Body4::salts([U1]).unwrap()]);
                ix.settle()?;
                assert_eq!(ix.canonical_key(&fkey(s_f))?, fkey(c_f));
                assert_eq!(
                    ix.canonical_key(&format!("fieldDesc/{}", s_f.text()))?,
                    format!("fieldDesc/{}", c_f.text())
                );
                assert_eq!(
                    ix.canonical_value("termField", &json!(s_f.text()))?,
                    json!(c_f.text())
                );
                assert_eq!(
                    ix.canonical_json(&json!({"f": fkey(s_f), "termFieldId": s_f.text()}))?,
                    json!({"f": fkey(c_f), "termFieldId": c_f.text()})
                );
                let cfg = ix.canonical_config(&lapis_cfg(Some(U1)))?;
                assert_eq!(
                    cfg["builtins"]["lapis"]["b"]["fields"][0]["id"],
                    json!(c_f.text())
                );
                assert_eq!(cfg["builtins"]["lapis"]["reading"], json!(c_f.text()));
                // 对外命令 `canonical_ids` 与键 / 值 / 配置同一个结论（偏好里存的带盐内置字段 ID 发进来要换成视图里的那个）。
                let req = json!({"ids": [s_f.text(), c_f.text(), "plain"]});
                assert_eq!(
                    super::super::cmd::identity::canonical_ids(t, col, &req)?,
                    json!({"ids": [c_f.text(), c_f.text(), "plain"]})
                );
                // 实体口径（别名类成员）只来自表：表外的 ID 自成一类，`members` 不会给出不含它自己的类。
                assert_eq!(ix.canonical(&r(s_f))?, r(s_f));
                assert_eq!(ix.members(&r(s_f))?, vec![r(s_f)]);
                Ok(())
            })
            .unwrap();
        });
    }
}
