//! 别名表（设计 §5.3）：把 `gen4_ids::alias` 的判定落成派生表，读侧按规范 ID 归并。[Index] 的一部分——逐条维护时
//! [Index::settle] 在证据变了的时候重算，[Index::rebuild_all] 总是重算，两条路出来的行逐行相同。
//!
//! # 表
//!
//! - `alias_ix(col, id, canon, how)`：一个在操作里出现过的 ID 的规范 ID。只存两种行：规范 ID 不是它自己的
//!   （[A_SALTED] 带盐的根规则验上、[A_DERIVED] 由父 ID 派生验上、[A_FALLBACK] 旧并入的兜底 ID），与「按规则该验得上、
//!   却没验上」的（[A_UNVERIFIED]，`canon = id`；随机 ID 本来就不是派生的，不记）。表里没有的 ID，规范 ID 就是它自己。
//!   索引 `alias_canon(col, canon, id)` 只盖前一种：由规范 ID 找它的全部别名。
//! - `alias_writer_ix(col, name, origin)`：旧并入改了名的写入者（`merged-…`）里，验得上、且有「是同一套 seq」的
//!   正面证据的，归回最初的写入者。
//!
//! # 证据
//!
//! 别名表是「操作集合 + 盐集合 + 内置笔记类型表」的函数（判定规则只有 `gen4_ids` 那一份）。这里只负责把索引里的
//! 东西装成它要的证据：
//!
//! - 盐：集合的盐集合 = **本机信任的作者**写的带盐操作（Salts、Join；读入点在 `derive.rs` 的 `salts_of`，记在
//!   `salt_ix(col, k, salt)`）的盐之并。它是「操作集合 + 本机信任状态」的函数：重建与逐条维护算的是同一个并，
//!   `collections.salts` 只是它的缓存。操作集合只增，所以信任状态不变时盐只增不减；作者被本机拒绝（或还没确认）时
//!   它带来的盐不算，放行后算回来。信任状态不同的两台设备盐集合可以不同（与下面的清除同源：可检测，
//!   [Index::withheld_salts]）。
//! - 内置笔记类型表：内核持有（`gen4_ids::builtins`，只能追加）。不是宿主输入：别名表因此不随宿主版本、也不随哪台
//!   设备先给了哪一版而变。
//! - 笔记类型 / 笔记 / 牌组 / 卡 / profile 级实体：身份记录（`ent_ix`），并上修改记录里出现过的同种类实体（`reg_ix`）。
//!   定义史（`fieldDef/` `tmplDef/` 的 `ankiNum` / `name`）、笔记的 `noteType` 史、牌组的 `name` / `parent` 史取寄存器的
//!   **全部**写入（被支配的也算：证据是历史值）。卡再加 `historyFrom/<id>` 键里的 ID。
//! - 日志：`log_ix` 里 ID 与卡都是规范 UUID 的；`ankiId`、导入锚点的时刻、undo 点名的日志读操作体。
//! - 写入者：旧戳的 dot（写入者、seq、HLC 的物理时刻与计数）。只在闭包里出现过 `merged-…` 形状的名字时才扫
//!   （没有这种名字就没有东西可归）。
//!
//! 「已清除」的修改记录（`reg_ix.state` = [S_PURGED]）不算证据——按逻辑标记，不看它落没落成空洞，所以同一个操作集合
//! 加同一个信任状态，别名表逐行相同。信任状态不同的两台设备（一台不执行另一台信任的 Purge）证据不同、别名表可以
//! 不同（设计 §10 第 18 条；按答法 A：接受，但可检测）：[Index::hollowed] 列出本机有生效清除的、带自然键的那几种
//! 实体，[Index::key_evidence] 回答「这个实体在本机还剩几条自然键证据」，上层拿一台设备的清单去另一台问就得到会
//! 分叉的集合。
//!
//! 身份记录不受清除影响（`weigh.rs`），所以笔记的 `guid`、笔记类型的 `ankiNum` 清除后还在；丢的是定义史、
//! `noteType` 史、牌组的名字与父牌组史（设计 §10 第 19 条：证据变少时规范 ID 退回它自己）。
//!
//! # 重算与增量（设计 §10 第 13 条）
//!
//! 判定只有一份（`gen4_ids::alias::resolve`，纯函数）。逐条维护分三档：
//!
//! 1. **不改证据**（复习日志落在出现过的卡上、对出现过的实体改非证据键、标签、媒体……）：什么都不做。
//! 2. **只添了笔记 / 牌组 / 卡 / 日志的证据**（新建笔记、新卡的第一条复习、牌组改名……，记在 [AliasDelta]）：
//!    收尾时先试**增量证明**（[Index::alias_probe]），证得出只写这一批自己的行，证不出退回第 3 档。
//! 3. 其余（拿走任何东西、清除状态或盐集合变了、写入者证据变了、笔记类型 / 字段 / 模板定义变了、别的种类的实体）：
//!    整表重算一次。大批灌入时用 [Index::hold_aliases] 攒到最后。
//!
//! 增量证明不另写一套判定：拿同一个 `resolve` 在一小份证据 P 上跑——P = 盐 + 内置表 + **全部**笔记类型与牌组 +
//! 这一批的笔记与「新卡的提示笔记」的全部证据 + 新卡 + 这一批的日志 + 表里全部「候选行」（[A_UNVERIFIED] 与
//! [A_FALLBACK]，既当卡又当叶子）。证得出的条件（任何一条不成立就整表重算）：
//!
//! - a. 候选行在 P 里一行不变（兜底行可以验不上：它归到的那个类不在 P 里）；
//! - b. 这一批自己的 ID 在 P 里都验上了（随机 ID 除外：它验不上，也不会是谁的别名）；
//! - c. P 里每条笔记的别名类是全的：表里归到同一个规范 ID 的笔记都在 P 里，规范 ID 本身若是出现过的笔记也在 P 里；
//! - d. 借来的上下文（提示笔记、日志落的已出现过的卡、undo 点名的日志）在 P 里的规范 ID 与表里的相同。
//!
//! 为什么这样就与整表重算逐行相同：表里一行的值只取决于它自己的自然键 + 盐（根规则）、它的父类（派生：字段 /
//! 模板看笔记类型，卡看笔记与模板，导入日志看卡，补的 undo 看被点名的日志）、或「它是哪个别名的兜底 ID」。
//! 这一批只添了笔记 / 牌组 / 卡 / 日志的证据，笔记类型没变，所以①根规则验上的旧行不变（哈希相等是逐个 ID 的事）；
//! ②牌组的证据全在 P 里，牌组的结果就是整表重算的结果；③派生行只可能因为父类变了而变——变了父类的只有这一批的笔记，
//! 它们的类按 c 在 P 里是全的，由它们派生出来的、此前出现过的 ID 此前都验不上（父类不全）、都在候选行里，a 看着；
//! ④一个 ID 成了新的兜底 ID，它此前必是「出现过、验不上」的，也在候选行里，a 看着；⑤这一批自己的 ID 的结果在 P 里
//! 算得全（b、c、d 保证它用到的父类与上下文在 P 里与整表相同）。哈希碰撞（两个不同的规则输入得到同一个 ID）不在论证里，
//! 与整表重算本身对它的处理（记冲突、按验不上算）一样不追求。逐条维护 == 整表重算由 `parity.rs` 的到达方式重排
//! 与本文件的性质测试对所有场景钉住。

use std::collections::{BTreeMap, BTreeSet, HashSet};

use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

use super::derive::{Index, Ref, Reg, body_of};
use super::schema::sql;
use super::weigh::S_PURGED;
use crate::gen4::name::write_edit_key;
use crate::gen4::op::{Body4, Log4};
use crate::gen4::stamp::{HeritageStamp, StampHlc};
use crate::gen4_ids::alias::{
    DeckEv, DefEv, Dot, Evidence, How, Limits, LogEv, NoteEv, NoteTypeEv, WriterEv, resolve,
    strict_id,
};
use crate::gen4_ids::rules;
use crate::sync2::codec::Writer;
use crate::sync2::id::{Id, Key};
use crate::sync2::op::EntKind;
use crate::sync2::vv::OpId;

/// `alias_ix.how`：带盐的根规则验上。
pub const A_SALTED: i64 = 1;
/// `alias_ix.how`：由父 ID 按公式派生验上，规范 ID 按规范的父 ID 重算。
pub const A_DERIVED: i64 = 2;
/// `alias_ix.how`：旧并入的兜底 ID。
pub const A_FALLBACK: i64 = 3;
/// `alias_ix.how`：出现过、不是随机 ID、却没有一条规则验得上（`canon = id`）。
pub const A_UNVERIFIED: i64 = 4;

/// 旧并入改名的写入者的前缀（`gen4_ids::alias`；这里只用来问「有没有这种形状的名字」，判定不在这里）。
const MERGED_PREFIX: &str = "merged-";

const DECK: i64 = EntKind::Deck as i64;
const NOTE_TYPE: i64 = EntKind::NoteType as i64;
const NOTE: i64 = EntKind::Note as i64;
const CARD: i64 = EntKind::Card as i64;

/// 修改键紧凑字节形的 tag（`gen4::name::write_edit_key`）。
const K_FIELD_DEF: u8 = 2;
const K_TMPL_DEF: u8 = 3;
const K_HISTORY_FROM: u8 = 4;

/// 随机 ID（UUIDv7）：不是任何规则派生出来的。
fn random(id: &[u8; 16]) -> bool {
    id[6] >> 4 == 7
}

fn key_bytes(key: &str) -> Vec<u8> {
    let mut w = Writer::new();
    write_edit_key(&mut w, key);
    w.into_vec()
}

/// 这个键上的写入是不是别名证据（文件头「证据」）。
fn evidence_key(ekind: i64, key: &[u8]) -> bool {
    match ekind {
        NOTE_TYPE => matches!(key.first(), Some(&K_FIELD_DEF | &K_TMPL_DEF)),
        NOTE => key == key_bytes("noteType"),
        DECK => key == key_bytes("name") || key == key_bytes("parent"),
        CARD => key.first() == Some(&K_HISTORY_FROM),
        _ => false,
    }
}

/// 紧凑键里嵌的那个 ID（tag 不是 0 的键）。
fn key_id(key: &[u8]) -> Option<Id> {
    <[u8; 16]>::try_from(key.get(1..17)?).ok().map(Id)
}

/// 同一个日志（规范卡 + 规范日志 ID）的一份：操作里写的原值，与它在哪条操作里。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LogCopy {
    pub op: OpId,
    pub id: Ref,
    pub card: Ref,
    pub at: i64,
}

/// 本机有生效清除的、带自然键的实体（[Index::hollowed]）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hollow {
    pub kind: EntKind,
    pub entity: Ref,
    /// 生效的 Purge。
    pub purges: Vec<OpId>,
    /// 已清除、还没落成空洞的自然键证据有几条（落成空洞之后就数不出来了：0 不代表它没带过）。
    pub pending: u64,
}

/// 别名表里各种行的条数（[Index::alias_counts]）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AliasCounts {
    pub salted: u64,
    pub derived: u64,
    pub fallback: u64,
    pub unverified: u64,
    pub writers: u64,
}

fn ent_kind(code: i64) -> Result<EntKind, String> {
    EntKind::ALL
        .get(code as usize)
        .copied()
        .ok_or_else(|| format!("gen4 alias: bad entity kind {code}"))
}

fn uuid(k: &Key) -> Option<[u8; 16]> {
    match Ref::of(k) {
        Ref::Uuid(b) => Some(b),
        Ref::Text(_) => None,
    }
}

/// 别名证据的半成品。整个集合（[Index::alias_evidence]）与证明增量的那一小份（[Index::alias_probe]）共用这一套
/// 「索引的一行 → 证据」的拼法，两边不会各拼各的。
struct EvBuild {
    seen: HashSet<Id>,
    note_types: BTreeMap<Id, NoteTypeEv>,
    notes: BTreeMap<(Id, Option<String>), Vec<Id>>,
    note_ids: BTreeSet<Id>,
    note_history: BTreeMap<Id, Vec<Id>>,
    decks: BTreeMap<Id, DeckEv>,
    cards: BTreeSet<Id>,
    other: BTreeSet<Id>,
    defs: BTreeMap<(Id, bool, Id), DefEv>,
    k_name: Vec<u8>,
    k_parent: Vec<u8>,
    k_note_type: Vec<u8>,
}

impl EvBuild {
    fn new() -> Self {
        EvBuild {
            seen: HashSet::new(),
            note_types: BTreeMap::new(),
            notes: BTreeMap::new(),
            note_ids: BTreeSet::new(),
            note_history: BTreeMap::new(),
            decks: BTreeMap::new(),
            cards: BTreeSet::new(),
            other: BTreeSet::new(),
            defs: BTreeMap::new(),
            k_name: key_bytes("name"),
            k_parent: key_bytes("parent"),
            k_note_type: key_bytes("noteType"),
        }
    }

    fn note_type(&mut self, id: Id) -> &mut NoteTypeEv {
        self.note_types.entry(id).or_insert_with(|| NoteTypeEv {
            id,
            ..NoteTypeEv::default()
        })
    }

    fn deck(&mut self, id: Id) -> &mut DeckEv {
        self.decks.entry(id).or_insert_with(|| DeckEv {
            id,
            ..DeckEv::default()
        })
    }

    /// `ent_ix` 的一行（身份记录）。
    fn entity(&mut self, ix: &Index<'_, '_>, id: Id, kind: i64, k: i64) -> Result<(), String> {
        self.seen.insert(id);
        match kind {
            NOTE => {
                let p = ix.entity_data(k)?;
                self.note_ids.insert(id);
                let of = self
                    .notes
                    .entry((id, p["guid"].as_str().map(str::to_owned)))
                    .or_default();
                of.extend(p["noteTypeId"].as_str().and_then(strict_id));
            }
            NOTE_TYPE => {
                let p = ix.entity_data(k)?;
                let nt = self.note_type(id);
                nt.anki_num = nt.anki_num.or(p["ankiNum"].as_i64());
                nt.cloze |= p["ntKind"].as_str() == Some("cloze");
            }
            DECK => {
                self.deck(id);
            }
            CARD => {
                self.cards.insert(id);
            }
            _ => {
                self.other.insert(id);
            }
        }
        Ok(())
    }

    /// `reg_ix` 的一行（没被清除的修改记录；被支配的也是历史值）。
    fn register(
        &mut self,
        ix: &Index<'_, '_>,
        ekind: i64,
        ent: Id,
        key: &[u8],
        k: i64,
    ) -> Result<(), String> {
        self.seen.insert(ent);
        match ekind {
            DECK => {
                if key == self.k_name.as_slice() {
                    let name = ix.value_at(k)?;
                    self.deck(ent)
                        .names
                        .extend(name.as_str().map(str::to_owned));
                } else if key == self.k_parent.as_slice() {
                    let parent = ix.value_at(k)?;
                    self.deck(ent)
                        .parents
                        .extend(parent.as_str().and_then(strict_id));
                } else {
                    self.deck(ent);
                }
            }
            NOTE_TYPE => {
                self.note_type(ent);
                let is_field = match key.first() {
                    Some(&K_FIELD_DEF) => true,
                    Some(&K_TMPL_DEF) => false,
                    _ => return Ok(()),
                };
                let Some(def) = key_id(key) else {
                    return Ok(());
                };
                let v = ix.value_at(k)?;
                let d = self
                    .defs
                    .entry((ent, is_field, def))
                    .or_insert_with(|| DefEv {
                        id: def,
                        ..DefEv::default()
                    });
                d.anki_nums.extend(v["ankiNum"].as_i64());
                d.names.extend(v["name"].as_str().map(str::to_owned));
                self.seen.insert(def);
            }
            NOTE => {
                self.note_ids.insert(ent);
                if key == self.k_note_type.as_slice() {
                    let v = ix.value_at(k)?;
                    self.note_history
                        .entry(ent)
                        .or_default()
                        .extend(v.as_str().and_then(strict_id));
                }
            }
            CARD => {
                self.cards.insert(ent);
                if key.first() == Some(&K_HISTORY_FROM) {
                    if let Some(from) = key_id(key) {
                        self.cards.insert(from);
                        self.seen.insert(from);
                    }
                }
            }
            _ => {
                self.other.insert(ent);
            }
        }
        Ok(())
    }

    /// 一条日志操作（`log_ix` 里 ID 与卡都是 UUID 的那种）。
    fn log(&mut self, id: Id, card: Id, l: &Log4) -> LogEv {
        let revokes = l.revokes.as_ref().and_then(uuid).map(Id);
        if !random(&id.0) {
            self.seen.insert(id);
        }
        self.seen.insert(card);
        self.seen.extend(revokes.filter(|x| !random(&x.0)));
        LogEv {
            id,
            card,
            anki_revlog_id: l.anki_id,
            anchor_at: (l.kind == "importAnchor").then_some(l.at),
            revokes,
        }
    }

    /// 收尾：[ev] 带着盐、内置表、日志、写入者，这里补上实体那几类。
    fn finish(self, mut ev: Evidence) -> (Evidence, HashSet<Id>) {
        let EvBuild {
            mut seen,
            mut note_types,
            mut notes,
            note_ids,
            note_history,
            decks,
            cards,
            other,
            defs,
            ..
        } = self;
        for ((nt, is_field, _), d) in defs {
            let t = note_types.entry(nt).or_insert_with(|| NoteTypeEv {
                id: nt,
                ..NoteTypeEv::default()
            });
            if is_field {
                t.fields.push(d);
            } else {
                t.templates.push(d);
            }
        }
        let recorded: BTreeSet<Id> = notes.keys().map(|(id, _)| *id).collect();
        for id in note_ids {
            if !recorded.contains(&id) {
                notes.insert((id, None), Vec::new());
            }
        }
        ev.notes = notes
            .into_iter()
            .map(|((id, guid), mut note_types)| {
                note_types.extend(note_history.get(&id).into_iter().flatten().copied());
                NoteEv {
                    id,
                    guid,
                    note_types,
                    cloze_ords: Vec::new(),
                }
            })
            .collect();
        ev.note_types = note_types.into_values().collect();
        ev.decks = decks.into_values().collect();
        ev.cards = cards.into_iter().collect();
        ev.other_ids = other.into_iter().collect();
        seen.extend(ev.cards.iter().copied());
        (ev, seen)
    }
}

/// 别名表里一个 ID 的那一行（`how` 码）；None = 不存（规范 ID 是它自己且验上了 / 随机 ID / 没在操作里出现过）。
/// 整表重算与增量写回共用。
fn alias_row(id: &Id, canon: &Id, how: How, seen: &HashSet<Id>) -> Option<i64> {
    let code = match how {
        How::Salted { .. } => A_SALTED,
        How::Derived => A_DERIVED,
        How::Fallback { .. } => A_FALLBACK,
        How::Unverified(_) if !random(&id.0) => A_UNVERIFIED,
        How::Unverified(_) | How::Canonical | How::Unknown => return None,
    };
    // 规范 ID 是它自己的验上了也不用记；算得出、却没在操作里出现过的（别的盐下的值）没有人会来查。
    if (canon == id && code != A_UNVERIFIED) || !seen.contains(id) {
        return None;
    }
    Some(code)
}

/// 这一批里改了别名证据、但未必要整表重算的东西（[Index::alias_probe] 来证明）。只收「添」：拿走任何东西、清除
/// 状态或盐集合变了、写入者的证据变了、笔记类型（字段 / 模板定义）变了、别的种类的实体，一律整表重算。
#[derive(Default)]
pub(crate) struct AliasDelta {
    /// 身份记录或 `noteType` 史变了的笔记。
    notes: BTreeSet<Id>,
    /// 身份记录或名字 / 父牌组史变了的牌组。
    decks: BTreeSet<Id>,
    /// 新出现的卡 → 它可能属于的笔记（日志里写的 `note`；只是提示：猜错了证明不过、退回整表重算）。
    cards: BTreeMap<Id, BTreeSet<Id>>,
    /// 改了证据的日志（落在没出现过的卡上，或 ID 是派生形状的）。
    logs: Vec<LogEv>,
}

impl AliasDelta {
    pub(crate) fn is_empty(&self) -> bool {
        self.notes.is_empty()
            && self.decks.is_empty()
            && self.cards.is_empty()
            && self.logs.is_empty()
    }
}

impl Index<'_, '_> {
    // ------------------------------------------------------------ 宿主输入

    /// 大批灌入时把别名表的重算攒到最后：打开期间 [Index::settle] 不重算，关掉后的下一次 [Index::settle] 补上。
    /// 攒着的时候别名表是旧的（[Index::aliases_stale]）；只在同一个 [Index] 活着的期间有效。
    pub fn hold_aliases(&mut self, on: bool) {
        self.alias_held = on;
    }

    /// 证据变了（或者带盐的操作进出过、还没看盐集合变没变），别名表还没重算。
    pub fn aliases_stale(&self) -> bool {
        self.alias_dirty || self.salts_dirty || !self.alias_delta.is_empty()
    }

    // ------------------------------------------------------------ 盐集合

    /// `salt_ix` 里的全部行：(盐, 带它的操作)。
    fn salt_rows(&self) -> Result<Vec<(String, OpId)>, String> {
        let rows: Vec<(String, i64)> = {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached("SELECT salt, k FROM salt_ix WHERE col = ?1 ORDER BY salt, k")
                .map_err(sql)?;
            let rows = stmt
                .query_map([self.col], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)?
        };
        rows.into_iter()
            .map(|(salt, k)| Ok((salt, self.t.id_of_key(k)?)))
            .collect()
    }

    /// 盐集合 = 受信作者的带盐操作之并。变了就改缓存、标记别名表要重算。
    pub(super) fn settle_salts(&mut self) -> Result<bool, String> {
        let mut salts: BTreeSet<String> = BTreeSet::new();
        for (salt, op) in self.salt_rows()? {
            if !self.distrusts(&op.device)? {
                salts.insert(salt);
            }
        }
        let changed = self.t.set_salts(self.col, &salts)?;
        self.alias_dirty |= changed;
        Ok(changed)
    }

    /// 只有本机不信任的作者带来的盐：(盐, 带它的操作)。这些盐在信任它们的设备上算数——两边的别名表可以因此不同
    /// （设计 §10 第 17 / 18 条：接受，但上层要看得见）。
    pub fn withheld_salts(&mut self) -> Result<Vec<(String, Vec<OpId>)>, String> {
        let held: BTreeSet<String> = self.salts()?.into_iter().collect();
        let mut out: BTreeMap<String, Vec<OpId>> = BTreeMap::new();
        for (salt, op) in self.salt_rows()? {
            if !held.contains(&salt) {
                out.entry(salt).or_default().push(op);
            }
        }
        Ok(out.into_iter().collect())
    }

    // ------------------------------------------------------------ 逐条维护：这条操作改不改证据

    /// `touch` 在动索引之前调（[add] = 进日志，否则是拿走）。
    pub(super) fn alias_touch(&mut self, k: i64, body: &Body4, add: bool) -> Result<(), String> {
        if self.alias_dirty || self.alias_neutral(k, body, add)? {
            return Ok(());
        }
        if !(add && self.alias_delta_take(body)?) {
            self.alias_dirty = true;
        }
        Ok(())
    }

    /// 一条带旧戳的记录进出日志（修改，或副本记录）：它的 dot 会不会改写入者的判定。
    pub(super) fn alias_stamp(&mut self, s: &HeritageStamp) -> Result<(), String> {
        if !self.alias_dirty {
            self.alias_dirty = self.writer_sensitive(s)?;
        }
        Ok(())
    }

    /// 清除状态变了的修改记录：证据多了或少了一条。
    pub(super) fn alias_purge_flipped(&mut self) {
        self.alias_dirty = true;
    }

    fn alias_neutral(&mut self, k: i64, body: &Body4, add: bool) -> Result<bool, String> {
        match body {
            // 身份记录是根证据。
            Body4::Entity { id, .. } => Ok(uuid(id).is_none()),
            Body4::Edit(ed) => {
                if let Some(s) = &ed.stamp {
                    if self.writer_sensitive(s)? {
                        return Ok(false);
                    }
                }
                let reg = Reg::new(ed.kind, &ed.entity, &ed.key);
                let Ref::Uuid(_) = reg.ent else {
                    return Ok(true);
                };
                if !add {
                    // 拿走的是已清除的：它本来就不算证据。
                    return Ok(self.reg_state(&reg, k)? == Some(S_PURGED));
                }
                if evidence_key(reg.ekind, &reg.key) {
                    return Ok(false);
                }
                self.entity_observed(reg.ekind, &reg.ent)
            }
            Body4::Log(l) => {
                if !add {
                    return Ok(uuid(&l.id).is_none() || uuid(&l.card).is_none());
                }
                self.log_neutral(l)
            }
            // 带盐的操作由读入点（`touch`）按盐集合变没变来标；标签、媒体、Purge、Checkpoint……不带别名证据
            // （Purge 的作用经清除状态的变化进来）。
            _ => Ok(true),
        }
    }

    /// 一条新日志只在这些都成立时不改证据：它的 ID 是随机的（不会被任何派生规则验上）、它的卡已经是出现过的卡、
    /// undo 点名的日志已经出现过、它自己在任何盐下的兜底 ID 都不是一个「出现过却没验上」的 ID。
    fn log_neutral(&mut self, l: &Log4) -> Result<bool, String> {
        let (Some(id), Some(card)) = (uuid(&l.id), uuid(&l.card)) else {
            return Ok(true);
        };
        if !random(&id) || !self.card_observed(&Ref::Uuid(card))? {
            return Ok(false);
        }
        if let Some(r) = l.revokes.as_ref().and_then(uuid) {
            if !self.log_observed(&Ref::Uuid(r))? {
                return Ok(false);
            }
        }
        if self.log_observed(&Ref::Uuid(id))? {
            return Ok(true);
        }
        let text = Id(id).text();
        let salts = self.salts()?;
        for s in &salts {
            if *s == text {
                return Ok(false);
            }
            let f = rules::merge_fallback(s, &text);
            if self.alias_how(&f)? == Some(A_UNVERIFIED) {
                return Ok(false);
            }
        }
        Ok(true)
    }

    fn salts(&self) -> Result<Vec<String>, String> {
        Ok(self
            .t
            .binding(self.col)?
            .map(|b| b.salts.into_iter().collect())
            .unwrap_or_default())
    }

    /// 这个实体是不是已经在同种类的证据里（身份记录，或一条没被清除的修改记录）。
    fn entity_observed(&self, ekind: i64, ent: &Ref) -> Result<bool, String> {
        self.t
            .conn()
            .prepare_cached(
                "SELECT EXISTS(SELECT 1 FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND state != ?4) \
                 OR EXISTS(SELECT 1 FROM ent_ix WHERE col = ?1 AND id = ?3 AND kind = ?2)",
            )
            .map_err(sql)?
            .query_row(params![self.col, ekind, ent, S_PURGED], |r| r.get(0))
            .map_err(sql)
    }

    fn card_observed(&self, card: &Ref) -> Result<bool, String> {
        if self.entity_observed(CARD, card)? {
            return Ok(true);
        }
        self.t
            .conn()
            .prepare_cached(
                "SELECT EXISTS(SELECT 1 FROM log_ix WHERE col = ?1 AND card = ?2 AND typeof(id) = 'blob')",
            )
            .map_err(sql)?
            .query_row(params![self.col, card], |r| r.get(0))
            .map_err(sql)
    }

    fn log_observed(&self, id: &Ref) -> Result<bool, String> {
        self.t
            .conn()
            .prepare_cached(
                "SELECT EXISTS(SELECT 1 FROM log_ix WHERE col = ?1 AND id = ?2 AND typeof(card) = 'blob')",
            )
            .map_err(sql)?
            .query_row(params![self.col, id], |r| r.get(0))
            .map_err(sql)
    }

    fn alias_how(&self, id: &Id) -> Result<Option<i64>, String> {
        self.t
            .conn()
            .prepare_cached("SELECT how FROM alias_ix WHERE col = ?1 AND id = ?2")
            .map_err(sql)?
            .query_row(params![self.col, id.0.as_slice()], |r| r.get(0))
            .optional()
            .map_err(sql)
    }

    /// 闭包里（= 现有旧戳的 dot 与上下文里）有没有 `merged-…` 形状的写入者。没有就没有写入者可归，旧戳的 dot
    /// 不是证据。
    fn merged_known(&mut self) -> Result<bool, String> {
        Ok(self.closures()?.values().any(|(_, d)| {
            d.vv.keys()
                .chain(d.cloud.keys())
                .any(|w| w.starts_with(MERGED_PREFIX))
        }))
    }

    fn writer_sensitive(&mut self, s: &HeritageStamp) -> Result<bool, String> {
        if s.writer.starts_with(MERGED_PREFIX)
            || s.ctx
                .entries()
                .iter()
                .any(|e| e.writer.starts_with(MERGED_PREFIX))
        {
            return Ok(true);
        }
        self.merged_known()
    }

    // ------------------------------------------------------------ 重算

    fn entity_data(&self, k: i64) -> Result<Value, String> {
        Ok(self
            .t
            .entry_by_key(k)?
            .and_then(|e| body_of(&e))
            .and_then(|b| match b {
                Body4::Entity { data, .. } => serde_json::from_str(&data).ok(),
                _ => None,
            })
            .unwrap_or(Value::Null))
    }

    fn value_at(&self, k: i64) -> Result<Value, String> {
        Ok(self
            .t
            .edit_value(k)?
            .and_then(|v| serde_json::from_str(&v).ok())
            .unwrap_or(Value::Null))
    }

    /// 装证据（整个集合）。第二项是「出现过的 ID」里可能有别名行的那些（日志的随机 ID 不收：它们不会是别名）。
    fn alias_evidence(&mut self) -> Result<(Evidence, HashSet<Id>), String> {
        let (t, col) = (self.t, self.col);
        let conn = t.conn();
        let mut b = EvBuild::new();

        // 身份记录（清除不碰它们）。
        {
            let mut stmt = conn
                .prepare_cached(
                    "SELECT id, kind, k FROM ent_ix WHERE col = ?1 AND typeof(id) = 'blob' ORDER BY id, k",
                )
                .map_err(sql)?;
            let mut rows = stmt.query([col]).map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                let id = Id(r.get::<_, [u8; 16]>(0).map_err(sql)?);
                let (kind, k): (i64, i64) = (r.get(1).map_err(sql)?, r.get(2).map_err(sql)?);
                b.entity(self, id, kind, k)?;
            }
        }

        // 修改记录：没被清除的全部写入（被支配的也是历史值）。
        {
            let mut stmt = conn
                .prepare_cached(
                    "SELECT ekind, ent, key, k FROM reg_ix \
                     WHERE col = ?1 AND state != ?2 AND typeof(ent) = 'blob' ORDER BY ekind, ent, key, k",
                )
                .map_err(sql)?;
            let mut rows = stmt.query(params![col, S_PURGED]).map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                let ekind: i64 = r.get(0).map_err(sql)?;
                let ent = Id(r.get::<_, [u8; 16]>(1).map_err(sql)?);
                let key = r
                    .get_ref(2)
                    .map_err(sql)?
                    .as_blob()
                    .map_err(|e| e.to_string())?;
                let k: i64 = r.get(3).map_err(sql)?;
                b.register(self, ekind, ent, key, k)?;
            }
        }

        // 日志。
        let mut logs: Vec<LogEv> = Vec::new();
        {
            let mut stmt = conn
                .prepare_cached(
                    "SELECT id, card, k FROM log_ix \
                     WHERE col = ?1 AND typeof(id) = 'blob' AND typeof(card) = 'blob' ORDER BY card, at, k",
                )
                .map_err(sql)?;
            let mut rows = stmt.query([col]).map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                let id = Id(r.get::<_, [u8; 16]>(0).map_err(sql)?);
                let card = Id(r.get::<_, [u8; 16]>(1).map_err(sql)?);
                let k: i64 = r.get(2).map_err(sql)?;
                let Some(Body4::Log(l)) = t.entry_by_key(k)?.and_then(|e| body_of(&e)) else {
                    return Err(format!("gen4 alias: log_ix row {k} is not a log"));
                };
                logs.push(b.log(id, card, &l));
            }
        }

        // 写入者：有 `merged-…` 形状的名字才值得扫旧戳。
        let mut writers: BTreeMap<String, Vec<Dot>> = BTreeMap::new();
        let devices = t.devices(col)?;
        if self.merged_known()? {
            for d in &devices {
                t.for_each_stamp(col, &d.id, u64::MAX, |_, s| {
                    if s.seq <= 0 {
                        return Ok(());
                    }
                    let dots = match writers.get_mut(&s.writer) {
                        Some(d) => d,
                        None => writers.entry(s.writer.clone()).or_default(),
                    };
                    if let StampHlc::Parsed {
                        physical, counter, ..
                    } = &s.hlc
                    {
                        dots.push(Dot {
                            seq: s.seq as u64,
                            physical: *physical,
                            counter: *counter,
                        });
                    }
                    Ok(())
                })?;
            }
        }

        let ev = Evidence {
            salts: self.salts()?,
            builtins: crate::gen4_ids::builtins::builtin_note_types(),
            writer_hints: devices.iter().map(|d| d.id.text()).collect(),
            logs,
            writers: writers
                .into_iter()
                .map(|(name, dots)| WriterEv { name, dots })
                .collect(),
            ..Evidence::default()
        };
        Ok(b.finish(ev))
    }

    /// 一条改了证据的「添」能不能记进 [AliasDelta]（false = 这一批整表重算）。
    fn alias_delta_take(&mut self, body: &Body4) -> Result<bool, String> {
        match body {
            Body4::Entity { kind, id, .. } => {
                let Some(id) = uuid(id).map(Id) else {
                    return Ok(true);
                };
                match kind {
                    EntKind::Note => {
                        self.alias_delta.notes.insert(id);
                    }
                    EntKind::Deck => {
                        self.alias_delta.decks.insert(id);
                    }
                    EntKind::Card => {
                        self.alias_delta.cards.entry(id).or_default();
                    }
                    _ => return Ok(false),
                }
                Ok(true)
            }
            Body4::Edit(ed) => {
                if let Some(s) = &ed.stamp {
                    if self.writer_sensitive(s)? {
                        return Ok(false);
                    }
                }
                let Some(ent) = uuid(&ed.entity).map(Id) else {
                    return Ok(true);
                };
                match ed.kind {
                    EntKind::Note => {
                        self.alias_delta.notes.insert(ent);
                    }
                    EntKind::Deck => {
                        self.alias_delta.decks.insert(ent);
                    }
                    EntKind::Card => {
                        self.alias_delta.cards.entry(ent).or_default();
                        let reg = Reg::new(ed.kind, &ed.entity, &ed.key);
                        if reg.key.first() == Some(&K_HISTORY_FROM) {
                            if let Some(from) = key_id(&reg.key) {
                                self.alias_delta.cards.entry(from).or_default();
                            }
                        }
                    }
                    _ => return Ok(false),
                }
                Ok(true)
            }
            Body4::Log(l) => {
                let (Some(id), Some(card)) = (uuid(&l.id), uuid(&l.card)) else {
                    return Ok(true);
                };
                let revokes = l.revokes.as_ref().and_then(uuid);
                if let Some(r) = revokes {
                    // undo 点名一条还没出现过的派生日志：那条日志的规范 ID 证明里拿不到。
                    if !random(&r) && !self.log_observed(&Ref::Uuid(r))? {
                        return Ok(false);
                    }
                }
                if !self.card_observed(&Ref::Uuid(card))? {
                    let hints = self.alias_delta.cards.entry(Id(card)).or_default();
                    hints.extend(l.note.as_ref().and_then(uuid).map(Id));
                }
                self.alias_delta.logs.push(LogEv {
                    id: Id(id),
                    card: Id(card),
                    anki_revlog_id: l.anki_id,
                    anchor_at: (l.kind == "importAnchor").then_some(l.at),
                    revokes: revokes.map(Id),
                });
                Ok(true)
            }
            _ => Ok(false),
        }
    }

    /// 收尾时的别名表：证据「只添了 [AliasDelta] 里那些」就先试着证明不必整表重算（[Index::alias_probe]），证不出、
    /// 或有别的变化就整表重算。返回 (写了几行, 是不是证出来的)。
    pub(super) fn settle_aliases(&mut self) -> Result<(u64, bool), String> {
        if self.alias_held {
            return Ok((0, false));
        }
        if !self.alias_dirty && !self.alias_delta.is_empty() {
            let delta = std::mem::take(&mut self.alias_delta);
            if let Some(n) = self.alias_probe(&delta)? {
                return Ok((n, true));
            }
            self.alias_dirty = true;
        }
        if self.alias_dirty {
            return Ok((self.rebuild_aliases()?, false));
        }
        Ok((0, false))
    }

    fn stored_canon(&self, id: &Id) -> Result<Option<Id>, String> {
        self.t
            .conn()
            .prepare_cached("SELECT canon FROM alias_ix WHERE col = ?1 AND id = ?2")
            .map_err(sql)?
            .query_row(params![self.col, id.0.as_slice()], |r| {
                r.get::<_, [u8; 16]>(0)
            })
            .optional()
            .map_err(sql)
            .map(|c| c.map(Id))
    }

    /// 增量的证明（设计 §10 第 13 条；论证见文件头「增量」一节）。证得出就写这一批自己的行、返回写了几行；
    /// 证不出返回 None，表一行没动。
    fn alias_probe(&mut self, d: &AliasDelta) -> Result<Option<u64>, String> {
        let (t, col) = (self.t, self.col);
        let conn = t.conn();
        // 1. 唯一可能被新证据牵动的那些现存行：出现过却没验上的、旧并入的兜底 ID。
        let pool: Vec<(Id, Id, i64)> = {
            let mut stmt = conn
                .prepare_cached("SELECT id, canon, how FROM alias_ix WHERE col = ?1 AND how >= 3")
                .map_err(sql)?;
            let rows = stmt
                .query_map([col], |r| {
                    Ok((
                        Id(r.get::<_, [u8; 16]>(0)?),
                        Id(r.get::<_, [u8; 16]>(1)?),
                        r.get::<_, i64>(2)?,
                    ))
                })
                .map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)?
        };
        let mut b = EvBuild::new();
        // 2. 全部笔记类型与牌组（量小；它们的判定只看彼此与盐）。
        for kind in [NOTE_TYPE, DECK] {
            {
                let mut stmt = conn
                    .prepare_cached(
                        "SELECT id, k FROM ent_ix WHERE col = ?1 AND kind = ?2 AND typeof(id) = 'blob' ORDER BY id, k",
                    )
                    .map_err(sql)?;
                let mut rows = stmt.query(params![col, kind]).map_err(sql)?;
                while let Some(r) = rows.next().map_err(sql)? {
                    let id = Id(r.get::<_, [u8; 16]>(0).map_err(sql)?);
                    let k: i64 = r.get(1).map_err(sql)?;
                    b.entity(self, id, kind, k)?;
                }
            }
            let mut stmt = conn
                .prepare_cached(
                    "SELECT ent, key, k FROM reg_ix \
                     WHERE col = ?1 AND ekind = ?2 AND state != ?3 AND typeof(ent) = 'blob' ORDER BY ent, key, k",
                )
                .map_err(sql)?;
            let mut rows = stmt.query(params![col, kind, S_PURGED]).map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                let ent = Id(r.get::<_, [u8; 16]>(0).map_err(sql)?);
                let key = r
                    .get_ref(1)
                    .map_err(sql)?
                    .as_blob()
                    .map_err(|e| e.to_string())?;
                let k: i64 = r.get(2).map_err(sql)?;
                b.register(self, kind, ent, key, k)?;
            }
        }
        // 3. 这一批的笔记，加上新卡的提示里的笔记（全部证据）。
        let mut notes: BTreeSet<Id> = d.notes.clone();
        for hints in d.cards.values() {
            notes.extend(hints.iter().copied());
        }
        for n in &notes {
            {
                let mut stmt = conn
                    .prepare_cached(
                        "SELECT kind, k FROM ent_ix WHERE col = ?1 AND id = ?2 ORDER BY k",
                    )
                    .map_err(sql)?;
                let mut rows = stmt.query(params![col, n.0.as_slice()]).map_err(sql)?;
                while let Some(r) = rows.next().map_err(sql)? {
                    let (kind, k): (i64, i64) = (r.get(0).map_err(sql)?, r.get(1).map_err(sql)?);
                    b.entity(self, *n, kind, k)?;
                }
            }
            let mut stmt = conn
                .prepare_cached(
                    "SELECT key, k FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND state != ?4 ORDER BY key, k",
                )
                .map_err(sql)?;
            let mut rows = stmt
                .query(params![col, NOTE, n.0.as_slice(), S_PURGED])
                .map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                let key = r
                    .get_ref(0)
                    .map_err(sql)?
                    .as_blob()
                    .map_err(|e| e.to_string())?;
                let k: i64 = r.get(1).map_err(sql)?;
                b.register(self, NOTE, *n, key, k)?;
            }
        }
        // 4. 新卡、这一批的日志；候选行既当卡也当叶子（它们可能是新笔记的卡，也可能是新别名的兜底 ID）。
        for c in d.cards.keys() {
            b.cards.insert(*c);
        }
        for l in &d.logs {
            if !random(&l.id.0) {
                b.seen.insert(l.id);
            }
            b.seen.insert(l.card);
            b.seen.extend(l.revokes.filter(|x| !random(&x.0)));
        }
        for (p, _, _) in &pool {
            b.cards.insert(*p);
            b.other.insert(*p);
            b.seen.insert(*p);
        }
        let ev = Evidence {
            salts: self.salts()?,
            builtins: crate::gen4_ids::builtins::builtin_note_types(),
            logs: d.logs.clone(),
            ..Evidence::default()
        };
        let (ev, seen) = b.finish(ev);
        let aliases = resolve(&ev, &Limits::default());
        drop(ev);

        // 5a. 候选行一行不变（兜底行在这一小份里可以验不上：它归到的那个类不在这里）。
        for (p, canon, how) in &pool {
            let same = match aliases.how(p) {
                How::Unverified(_) => true,
                How::Fallback { .. } => *how == A_FALLBACK && aliases.canonical(p) == *canon,
                _ => false,
            };
            if !same {
                return Ok(None);
            }
        }
        // 5b. 这一批自己的 ID 都验上了（随机 ID 本来就验不上，也不会是谁的别名）。
        let mut own: BTreeSet<Id> = d.notes.clone();
        own.extend(d.decks.iter().copied());
        own.extend(d.cards.keys().copied());
        own.extend(d.logs.iter().map(|l| l.id).filter(|x| !random(&x.0)));
        for x in &own {
            if matches!(aliases.how(x), How::Unverified(_) | How::Unknown) && !random(&x.0) {
                return Ok(None);
            }
        }
        // 5c. 这一小份里每条笔记的别名类是全的：表里归到同一个规范 ID 的都在这一小份里。
        for x in &notes {
            let c = aliases.canonical(x);
            {
                let mut stmt = conn
                    .prepare_cached(
                        "SELECT id FROM alias_ix WHERE col = ?1 AND canon = ?2 AND canon != id ORDER BY id",
                    )
                    .map_err(sql)?;
                let mut rows = stmt.query(params![col, c.0.as_slice()]).map_err(sql)?;
                while let Some(r) = rows.next().map_err(sql)? {
                    let m = Id(r.get::<_, [u8; 16]>(0).map_err(sql)?);
                    if !notes.contains(&m) {
                        return Ok(None);
                    }
                }
            }
            if c != *x && !notes.contains(&c) && self.entity_observed(NOTE, &Ref::Uuid(c.0))? {
                return Ok(None);
            }
        }
        // 5d. 借来的上下文（提示里的笔记、日志落的已出现过的卡、undo 点名的日志）的规范 ID 与表里的相同。
        let mut ctx: BTreeSet<Id> = notes.difference(&d.notes).copied().collect();
        for l in &d.logs {
            if !d.cards.contains_key(&l.card) {
                ctx.insert(l.card);
            }
            ctx.extend(l.revokes);
        }
        for x in &ctx {
            let have = self.stored_canon(x)?.unwrap_or(*x);
            let want = match aliases.how(x) {
                How::Unknown => *x,
                _ => aliases.canonical(x),
            };
            if have != want {
                return Ok(None);
            }
        }

        // 6. 写这一批自己的行。
        let mut n = 0;
        for x in &own {
            conn.prepare_cached("DELETE FROM alias_ix WHERE col = ?1 AND id = ?2")
                .map_err(sql)?
                .execute(params![col, x.0.as_slice()])
                .map_err(sql)?;
            let canon = aliases.canonical(x);
            if let Some(code) = alias_row(x, &canon, aliases.how(x), &seen) {
                conn.prepare_cached(
                    "INSERT INTO alias_ix (col, id, canon, how) VALUES (?1, ?2, ?3, ?4)",
                )
                .map_err(sql)?
                .execute(params![col, x.0.as_slice(), canon.0.as_slice(), code])
                .map_err(sql)?;
                n += 1;
            }
        }
        Ok(Some(n))
    }

    /// 整表重算。返回写了几行。
    pub(super) fn rebuild_aliases(&mut self) -> Result<u64, String> {
        self.writing()?;
        let (ev, seen) = self.alias_evidence()?;
        let aliases = resolve(&ev, &Limits::default());
        drop(ev);
        let conn = self.t.conn();
        conn.prepare_cached("DELETE FROM alias_ix WHERE col = ?1")
            .map_err(sql)?
            .execute([self.col])
            .map_err(sql)?;
        conn.prepare_cached("DELETE FROM alias_writer_ix WHERE col = ?1")
            .map_err(sql)?
            .execute([self.col])
            .map_err(sql)?;
        let mut n = 0;
        {
            let mut put = conn
                .prepare_cached(
                    "INSERT INTO alias_ix (col, id, canon, how) VALUES (?1, ?2, ?3, ?4)",
                )
                .map_err(sql)?;
            for (id, canon, how) in aliases.entries() {
                let Some(code) = alias_row(&id, &canon, how, &seen) else {
                    continue;
                };
                put.execute(params![self.col, id.0.as_slice(), canon.0.as_slice(), code])
                    .map_err(sql)?;
                n += 1;
            }
            let mut put = conn
                .prepare_cached(
                    "INSERT INTO alias_writer_ix (col, name, origin) VALUES (?1, ?2, ?3)",
                )
                .map_err(sql)?;
            for (name, origin) in aliases.merged_writers() {
                put.execute(params![self.col, name, origin]).map_err(sql)?;
                n += 1;
            }
        }
        self.alias_dirty = false;
        self.alias_delta = AliasDelta::default();
        Ok(n)
    }

    // ------------------------------------------------------------ 读

    /// 规范 ID。不是 UUID 的引用、表里没有的 ID 就是它自己。
    pub fn canonical(&self, r: &Ref) -> Result<Ref, String> {
        let Ref::Uuid(b) = r else {
            return Ok(r.clone());
        };
        let canon: Option<[u8; 16]> = self
            .t
            .conn()
            .prepare_cached("SELECT canon FROM alias_ix WHERE col = ?1 AND id = ?2")
            .map_err(sql)?
            .query_row(params![self.col, b.as_slice()], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        Ok(canon.map_or_else(|| r.clone(), Ref::Uuid))
    }

    /// [r] 所在的别名类：规范 ID 与出现过的、归到它的全部 ID，升序。
    pub fn members(&self, r: &Ref) -> Result<Vec<Ref>, String> {
        let canon = self.canonical(r)?;
        let mut out = vec![canon.clone()];
        if let Ref::Uuid(b) = &canon {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached(
                    "SELECT id FROM alias_ix WHERE col = ?1 AND canon = ?2 AND canon != id ORDER BY id",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![self.col, b.as_slice()], |r| r.get::<_, Ref>(0))
                .map_err(sql)?;
            for row in rows {
                out.push(row.map_err(sql)?);
            }
        }
        out.sort();
        Ok(out)
    }

    /// 修改键的规范形：键里嵌着 ID 的（`f/<字段>`、`fieldDef/<…>`……）把那个 ID 换成规范 ID。
    pub fn canonical_key(&self, key: &str) -> Result<String, String> {
        let bytes = key_bytes(key);
        let (Some(id), true) = (key_id(&bytes), bytes.first() != Some(&0)) else {
            return Ok(key.to_owned());
        };
        let canon = self.canonical(&Ref::Uuid(id.0))?;
        Ok(format!("{}{}", &key[..key.len() - 36], canon.text()))
    }

    /// 写入者的规范名字（归回最初的写入者的 `merged-…`；其余是它自己）。用它的人要把一条旧修改里的三处一起换：
    /// dot 的写入者、HLC 的写入者、旧上下文的键。
    pub fn canonical_writer(&self, w: &str) -> Result<String, String> {
        let origin: Option<String> = self
            .t
            .conn()
            .prepare_cached("SELECT origin FROM alias_writer_ix WHERE col = ?1 AND name = ?2")
            .map_err(sql)?
            .query_row(params![self.col, w], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        Ok(origin.unwrap_or_else(|| w.to_owned()))
    }

    /// 一张卡（连同它的全部别名）名下的日志，按「规范卡 + 规范日志 ID」成组（设计 §2.4 / §5.3）：每组是同一条日志的
    /// 各份，按操作号升序（第一份是代表）。组按代表的发生时刻、再按规范日志 ID 排。
    pub fn logs_of_class(&self, card: &Ref) -> Result<Vec<(Ref, Vec<LogCopy>)>, String> {
        let mut groups: BTreeMap<Ref, Vec<LogCopy>> = BTreeMap::new();
        let mut canon: BTreeMap<Ref, Ref> = BTreeMap::new();
        for member in self.members(card)? {
            let rows: Vec<(Ref, i64, i64)> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT id, at, k FROM log_ix WHERE col = ?1 AND card = ?2 ORDER BY at, k",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, member], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                    })
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            for (id, at, k) in rows {
                let c = match canon.get(&id) {
                    Some(c) => c.clone(),
                    None => {
                        let c = self.canonical(&id)?;
                        canon.insert(id.clone(), c.clone());
                        c
                    }
                };
                groups.entry(c).or_default().push(LogCopy {
                    op: self.t.id_of_key(k)?,
                    id,
                    card: member.clone(),
                    at,
                });
            }
        }
        let mut out: Vec<(Ref, Vec<LogCopy>)> = groups
            .into_iter()
            .map(|(id, mut copies)| {
                copies.sort_by(|a, b| a.op.cmp(&b.op));
                (id, copies)
            })
            .collect();
        out.sort_by(|a, b| (a.1[0].at, &a.0).cmp(&(b.1[0].at, &b.0)));
        Ok(out)
    }

    pub fn alias_counts(&self) -> Result<AliasCounts, String> {
        let conn = self.t.conn();
        let mut out = AliasCounts::default();
        let mut stmt = conn
            .prepare_cached("SELECT how, COUNT(*) FROM alias_ix WHERE col = ?1 GROUP BY how")
            .map_err(sql)?;
        let rows = stmt
            .query_map([self.col], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
            })
            .map_err(sql)?;
        for row in rows {
            let (how, n) = row.map_err(sql)?;
            match how {
                A_SALTED => out.salted = n as u64,
                A_DERIVED => out.derived = n as u64,
                A_FALLBACK => out.fallback = n as u64,
                _ => out.unverified = n as u64,
            }
        }
        out.writers = conn
            .prepare_cached("SELECT COUNT(*) FROM alias_writer_ix WHERE col = ?1")
            .map_err(sql)?
            .query_row([self.col], |r| r.get::<_, i64>(0))
            .map_err(sql)? as u64;
        Ok(out)
    }

    // ------------------------------------------------------------ 信任状态不同的设备（设计 §10 第 18 条，答法 A）

    /// [entity] 在本机的自然键证据：(算数的, 已清除还没落成空洞的) 各几条。
    fn evidence_rows(&self, ekind: i64, ent: &Ref) -> Result<(u64, u64), String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT key, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3",
            )
            .map_err(sql)?;
        let mut rows = stmt.query(params![self.col, ekind, ent]).map_err(sql)?;
        let (mut live, mut purged) = (0, 0);
        while let Some(r) = rows.next().map_err(sql)? {
            let key = r
                .get_ref(0)
                .map_err(sql)?
                .as_blob()
                .map_err(|e| e.to_string())?;
            if !evidence_key(ekind, key) {
                continue;
            }
            if r.get::<_, i64>(1).map_err(sql)? == S_PURGED {
                purged += 1;
            } else {
                live += 1;
            }
        }
        Ok((live, purged))
    }

    /// 本机有生效清除的、带自然键的实体（笔记类型、笔记、牌组）。它们的定义史 / `noteType` 史 / 名字史在本机不算
    /// 证据了；一台不执行这些清除的设备（没信任清除的作者）证据还在，两边对它们以及由它们派生的 ID 的规范 ID
    /// 可以不同。上层拿这张清单去另一台设备问 [Index::key_evidence]：答案不是 0 的就是会分叉的。
    pub fn hollowed(&self) -> Result<Vec<Hollow>, String> {
        let rows: Vec<(i64, Ref, i64)> = {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached(
                    "SELECT ekind, ent, k FROM purge_ix \
                     WHERE col = ?1 AND state = 1 AND ekind IN (?2, ?3, ?4) AND typeof(ent) = 'blob' \
                     ORDER BY ekind, ent, k",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![self.col, DECK, NOTE_TYPE, NOTE], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                })
                .map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)?
        };
        let mut out: Vec<Hollow> = Vec::new();
        for (ekind, ent, k) in rows {
            let op = self.t.id_of_key(k)?;
            let kind = ent_kind(ekind)?;
            match out.last_mut() {
                Some(h) if h.kind == kind && h.entity == ent => h.purges.push(op),
                _ => {
                    let (_, pending) = self.evidence_rows(ekind, &ent)?;
                    out.push(Hollow {
                        kind,
                        entity: ent,
                        purges: vec![op],
                        pending,
                    });
                }
            }
        }
        for h in &mut out {
            h.purges.sort();
        }
        Ok(out)
    }

    /// [entity] 在本机还算数的自然键证据有几条（见 [Index::hollowed]）。
    pub fn key_evidence(&self, kind: EntKind, entity: &Ref) -> Result<u64, String> {
        Ok(self.evidence_rows(kind as i64, entity)?.0)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use proptest::prelude::*;

    use super::*;
    use crate::gen4::op::tests::{id, native_edit, sample_log};
    use crate::gen4::op::{Edit4, Join4};
    use crate::gen4_ids::rules::CANONICAL;
    use crate::store::gen4::derive::Settled;
    use crate::store::gen4::derive::tests::{
        assert_rebuild_is_identity, dump, heritage, native, op, stamp, with,
    };
    use crate::store::gen4::truth::{TRUST_PENDING, Truth};

    /// 旧 profile uid（盐）。
    const U1: &str = "0192f0aa-0000-7000-8000-00000000000a";
    const U2: &str = "0192f0aa-0000-7000-8000-00000000000b";
    const GUID: &str = "guid-1";
    const ANKI_NT: i64 = 1_700_000_000_001;

    /// 样本探针：把 [notes] 当「这一批的笔记」证一次。
    pub(crate) fn probe_notes(ix: &mut Index<'_, '_>, notes: &[Id]) -> Result<Option<u64>, String> {
        let d = AliasDelta {
            notes: notes.iter().copied().collect(),
            ..AliasDelta::default()
        };
        ix.alias_probe(&d)
    }

    pub(crate) fn key(id: Id) -> Key {
        Key::Uuid(id)
    }

    /// 样本库里一个 profile 的盐：它自己的 uid，加上这台设备记着的已退役 uid（G3 探针的同一个口径；迁移时由 G4
    /// 写成一条 Salts 操作）。
    pub(crate) fn sample_salts(src: &rusqlite::Connection, profile: &str) -> Vec<String> {
        crate::store::gen4::legacy::salts(src, profile).unwrap()
    }

    fn r(id: Id) -> Ref {
        Ref::Uuid(id.0)
    }

    fn entity(kind: EntKind, id: Id, data: Value) -> Body4 {
        Body4::Entity {
            kind,
            id: key(id),
            data: data.to_string(),
        }
    }

    fn edit(kind: EntKind, entity: Id, k: &str, value: Value) -> Body4 {
        Body4::Edit(Edit4 {
            kind,
            entity: key(entity),
            key: k.to_owned(),
            value: value.to_string(),
            ..native_edit()
        })
    }

    fn log(id: Id, card: Id, at: i64) -> Body4 {
        Body4::Log(Log4 {
            id: key(id),
            card: key(card),
            note: None,
            revokes: None,
            at,
            anki_id: None,
            hlc: None,
            ..sample_log()
        })
    }

    /// 一个存量库的一小块：盐 U1 下建的笔记类型（一个模板）、一条笔记、它的卡、一条导入日志、一条本机复习。
    struct World {
        nt: Id,
        tmpl: Id,
        note: Id,
        card: Id,
        imported: Id,
        review: Id,
        /// 规范规则下的值。
        c_note: Id,
        c_card: Id,
        c_imported: Id,
    }

    fn world() -> World {
        let salt = Some(U1);
        let nt = rules::note_type(salt, ANKI_NT);
        let tmpl = rules::template(&nt, 0);
        let note = rules::note(salt, GUID);
        let card = rules::card(&note, &tmpl, 0);
        let c_nt = rules::note_type(CANONICAL, ANKI_NT);
        let c_note = rules::note(CANONICAL, GUID);
        let c_card = rules::card(&c_note, &rules::template(&c_nt, 0), 0);
        World {
            nt,
            tmpl,
            note,
            card,
            imported: rules::imported_revlog(&card, 42),
            review: Id::new_v7(1_700_000_000_000),
            c_note,
            c_card,
            c_imported: rules::imported_revlog(&c_card, 42),
        }
    }

    /// 那一小块的操作，按「自然」的顺序（设备 0xa1）。
    fn ops_of(w: &World) -> Vec<Body4> {
        vec![
            Body4::salts([U1]).unwrap(),
            entity(EntKind::NoteType, w.nt, json!({"ankiNum": ANKI_NT})),
            edit(
                EntKind::NoteType,
                w.nt,
                &format!("tmplDef/{}", w.tmpl.text()),
                json!({"ankiNum": 0, "name": "Card 1"}),
            ),
            entity(
                EntKind::Note,
                w.note,
                json!({"guid": GUID, "noteTypeId": w.nt.text()}),
            ),
            edit(EntKind::Card, w.card, "due", json!(1)),
            Body4::Log(Log4 {
                anki_id: Some(42),
                ..match log(w.imported, w.card, 1000) {
                    Body4::Log(l) => l,
                    _ => unreachable!(),
                }
            }),
            log(w.review, w.card, 2000),
        ]
    }

    fn feed(t: &Truth<'_>, ix: &mut Index<'_, '_>, col: i64, dev: u8, bodies: &[Body4]) {
        for (i, b) in bodies.iter().enumerate() {
            native(t, ix, col, &op(dev, i as u64 + 1, 100 + i as i64, &[], b));
        }
    }

    /// 内置笔记类型表由内核持有（`gen4_ids::builtins`）：不给任何宿主输入，存量库里内置类型的带盐 ID、
    /// 只留了名字没留 `ankiNum` 的字段定义，也都按表里的种子归到规范 ID。
    #[test]
    fn builtin_note_types_resolve_without_any_host_input() {
        with(|t, col| {
            let n = rules::builtin_note_type_anki_num("lapis");
            let salted = rules::note_type(Some(U1), n);
            let field = rules::field(
                &salted,
                rules::builtin_field_anki_num("lapis", "Expression"),
            );
            let c_nt = rules::note_type(CANONICAL, n);
            let c_field = rules::field(&c_nt, rules::builtin_field_anki_num("lapis", "Expression"));
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(
                    t,
                    &mut ix,
                    col,
                    0xa1,
                    &[
                        Body4::salts([U1]).unwrap(),
                        entity(
                            EntKind::NoteType,
                            salted,
                            json!({"ankiNum": n, "builtin": "lapis"}),
                        ),
                        edit(
                            EntKind::NoteType,
                            salted,
                            &format!("fieldDef/{}", field.text()),
                            json!({"name": "Expression"}),
                        ),
                    ],
                );
                ix.settle()?;
                assert!(t.derive_cfg(col, "builtins")?.is_none());
                assert_eq!(ix.canonical(&r(salted))?, r(c_nt));
                assert_eq!(
                    ix.canonical_key(&format!("fieldDef/{}", field.text()))?,
                    format!("fieldDef/{}", c_field.text())
                );
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    #[test]
    fn salted_ids_resolve_to_the_canonical_ones_and_logs_group_by_canonical_card_and_log() {
        with(|t, col| {
            let w = world();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &ops_of(&w));
                ix.settle()?;
                assert!(!ix.aliases_stale());
                assert_eq!(ix.canonical(&r(w.note))?, r(w.c_note));
                assert_eq!(ix.canonical(&r(w.card))?, r(w.c_card));
                assert_eq!(ix.canonical(&r(w.imported))?, r(w.c_imported));
                // 随机 ID、不是 UUID 的引用：它自己。
                assert_eq!(ix.canonical(&r(w.review))?, r(w.review));
                assert_eq!(ix.canonical(&Ref::Text("x".into()))?, Ref::Text("x".into()));
                assert_eq!(
                    ix.canonical_key(&format!("tmplDef/{}", w.tmpl.text()))?,
                    format!(
                        "tmplDef/{}",
                        rules::template(&rules::note_type(CANONICAL, ANKI_NT), 0).text()
                    )
                );
                assert_eq!(ix.canonical_key("due")?, "due");
                let mut class = vec![r(w.c_card), r(w.card)];
                class.sort();
                assert_eq!(ix.members(&r(w.card))?, class);
                assert_eq!(ix.members(&r(w.c_card))?, class);

                // 另一台设备按规范 ID 写：同一张卡上同一条导入日志的另一份，再加一条它自己的复习。
                let other = Id::new_v7(1_700_000_000_500);
                feed(
                    t,
                    &mut ix,
                    col,
                    0xa2,
                    &[
                        edit(EntKind::Card, w.c_card, "due", json!(2)),
                        Body4::Log(Log4 {
                            anki_id: Some(42),
                            ..match log(w.c_imported, w.c_card, 1000) {
                                Body4::Log(l) => l,
                                _ => unreachable!(),
                            }
                        }),
                        log(other, w.c_card, 3000),
                    ],
                );
                ix.settle()?;
                for card in [w.card, w.c_card] {
                    let groups = ix.logs_of_class(&r(card))?;
                    let ids: Vec<Ref> = groups.iter().map(|g| g.0.clone()).collect();
                    assert_eq!(ids, [r(w.c_imported), r(w.review), r(other)]);
                    // 导入日志有两份（两个原值 ID、两张原值卡），代表是操作号小的那份。
                    let copies: Vec<(u8, Ref, Ref)> = groups[0]
                        .1
                        .iter()
                        .map(|c| (c.op.device.0[15], c.id.clone(), c.card.clone()))
                        .collect();
                    assert_eq!(
                        copies,
                        [
                            (0xa1, r(w.imported), r(w.card)),
                            (0xa2, r(w.c_imported), r(w.c_card))
                        ]
                    );
                    assert_eq!(groups[1].1.len(), 1);
                }
                let n = ix.alias_counts()?;
                assert!(n.salted >= 2 && n.derived >= 3, "{n:?}");
                assert_eq!((n.fallback, n.unverified, n.writers), (0, 0, 0));
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 盐经 Join 进来也一样（被并入集合带来的盐表）；没有盐时带盐的 ID 验不上，记成「没验上」。
    #[test]
    fn salts_come_from_salts_and_join_ops_and_without_them_ids_stay_unverified() {
        with(|t, col| {
            let w = world();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let bodies = ops_of(&w);
                feed(t, &mut ix, col, 0xa1, &bodies[1..]);
                ix.settle()?;
                assert_eq!(ix.canonical(&r(w.note))?, r(w.note));
                assert_eq!(ix.alias_how(&w.note)?, Some(A_UNVERIFIED));
                assert_eq!(ix.alias_how(&w.review)?, None);
                // 别的盐不管用。
                let join = |salt: &str| {
                    Body4::Join(Join4 {
                        from: id(0xb0),
                        dir: "b".into(),
                        salts: vec![salt.to_owned()],
                    })
                };
                native(t, &mut ix, col, &op(0xa2, 1, 500, &[], &join(U2)));
                ix.settle()?;
                assert_eq!(ix.canonical(&r(w.note))?, r(w.note));
                native(t, &mut ix, col, &op(0xa2, 2, 501, &[], &join(U1)));
                assert!(ix.aliases_stale());
                assert!(ix.settle()?.aliases > 0);
                assert_eq!(ix.canonical(&r(w.note))?, r(w.c_note));
                assert_eq!(ix.canonical(&r(w.card))?, r(w.c_card));
                // 同一个盐再来一遍：盐集合没变，不重算。
                native(t, &mut ix, col, &op(0xa2, 3, 502, &[], &join(U1)));
                assert_eq!(ix.settle()?.aliases, 0);
                assert!(!ix.aliases_stale());
                assert_eq!(ix.withheld_salts()?, []);

                // 本机不信任写盐的那台设备：它带来的盐不算，别名退回去；清单里看得见。放行后回来。
                t.set_trust(col, &id(0xa2), Some(TRUST_PENDING), 1)?;
                ix.trust_changed();
                ix.settle()?;
                assert_eq!(ix.canonical(&r(w.note))?, r(w.note));
                let withheld = ix.withheld_salts()?;
                let names: Vec<&str> = withheld.iter().map(|(s, _)| s.as_str()).collect();
                assert_eq!(names, [U1, U2]);
                assert_eq!(withheld[0].1.len(), 2);
                // 另一台受信的设备也带了同一个盐：算数。
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa3, 1, 600, &[], &Body4::salts([U1]).unwrap()),
                );
                ix.settle()?;
                assert_eq!(ix.canonical(&r(w.note))?, r(w.c_note));
                let withheld = ix.withheld_salts()?;
                assert_eq!(withheld.len(), 1);
                assert_eq!(withheld[0].0, U2);
                t.set_trust(col, &id(0xa2), None, 0)?;
                ix.trust_changed();
                ix.settle()?;
                assert_eq!(ix.withheld_salts()?, []);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 旧并入的兜底 ID：`v5(NS, profile-merge/<盐>/<X>)` 归到 X 的规范 ID；日志先到、它的兜底副本后到，或者反过来，
    /// 结果一样。
    #[test]
    fn merge_fallback_ids_join_the_class_of_what_they_were_made_from() {
        for flip in [false, true] {
            with(|t, col| {
                let w = world();
                let fallback = rules::merge_fallback(U1, &w.review.text());
                t.tx(|t| {
                    let mut ix = Index::new(t, col);
                    let mut bodies = ops_of(&w);
                    let review = bodies.pop().unwrap();
                    feed(t, &mut ix, col, 0xa1, &bodies);
                    ix.settle()?;
                    let copy = log(fallback, w.card, 2000);
                    let pair = if flip { [copy, review] } else { [review, copy] };
                    native(t, &mut ix, col, &op(0xa2, 1, 900, &[], &pair[0]));
                    ix.settle()?;
                    native(t, &mut ix, col, &op(0xa2, 2, 901, &[], &pair[1]));
                    ix.settle()?;
                    assert_eq!(ix.canonical(&r(fallback))?, r(w.review));
                    assert_eq!(ix.alias_how(&fallback)?, Some(A_FALLBACK));
                    let groups = ix.logs_of_class(&r(w.c_card))?;
                    let review_group = groups.iter().find(|g| g.0 == r(w.review)).unwrap();
                    assert_eq!(review_group.1.len(), 2);
                    Ok(())
                })
                .unwrap();
                assert_rebuild_is_identity(t, col);
            });
        }
    }

    /// 不改证据的操作不触发重算；改证据的触发。
    #[test]
    fn only_evidence_bearing_ops_mark_the_table_stale() {
        with(|t, col| {
            let w = world();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &ops_of(&w));
                ix.settle()?;
                let mut seq = 0;
                let mut put = |ix: &mut Index<'_, '_>, b: Body4| {
                    seq += 1;
                    native(t, ix, col, &op(0xa3, seq, 5000 + seq as i64, &[], &b));
                    let stale = ix.aliases_stale();
                    ix.settle().unwrap();
                    stale
                };
                // 复习、对出现过的卡 / 笔记改非证据键、标签、媒体：不动。
                let v7 = |n: u64| Id::new_v7(1_700_000_100_000 + n);
                assert!(!put(&mut ix, log(v7(1), w.card, 6000)));
                assert!(!put(&mut ix, edit(EntKind::Card, w.card, "due", json!(9))));
                assert!(!put(
                    &mut ix,
                    edit(
                        EntKind::Note,
                        w.note,
                        &format!("f/{}", id(9).text()),
                        json!("x")
                    )
                ));
                assert!(!put(
                    &mut ix,
                    Body4::TagAdd {
                        note: key(w.note),
                        tag: "t".into()
                    }
                ));
                // 不是 UUID 的实体不在证据里。
                assert!(!put(
                    &mut ix,
                    Body4::Edit(Edit4 {
                        kind: EntKind::Deck,
                        entity: Key::Text("legacy-deck".into()),
                        key: "name".into(),
                        value: "\"x\"".into(),
                        ..native_edit()
                    })
                ));
                // 没见过的卡上的日志、派生形状的日志 ID、没见过的实体、证据键、身份记录：重算。
                assert!(put(&mut ix, log(v7(2), v7(3), 6100)));
                assert!(put(
                    &mut ix,
                    log(rules::imported_revlog(&w.card, 7), w.card, 6200)
                ));
                assert!(put(&mut ix, edit(EntKind::Card, v7(4), "due", json!(1))));
                assert!(put(
                    &mut ix,
                    edit(EntKind::Note, w.note, "noteType", json!(w.nt.text()))
                ));
                assert!(put(&mut ix, edit(EntKind::Deck, v7(5), "name", json!("d"))));
                assert!(put(&mut ix, entity(EntKind::Note, v7(6), json!({}))));
                // undo 点名一条没见过的日志。
                let undo = |target: Id| {
                    Body4::Log(Log4 {
                        revokes: Some(key(target)),
                        ..match log(v7(7), w.card, 6300) {
                            Body4::Log(l) => l,
                            _ => unreachable!(),
                        }
                    })
                };
                assert!(put(&mut ix, undo(v7(8))));
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 证据只添了笔记 / 牌组 / 卡 / 日志时，别名表靠增量证明维护（不整表重算）；证不出的情形退回整表重算。两条路
    /// 出来的表都与从空重建逐行相同（[assert_rebuild_is_identity]）。
    #[test]
    fn new_native_entities_are_proven_without_a_full_recompute() {
        with(|t, col| {
            let w = world();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &ops_of(&w));
                ix.settle()?;
                let c_nt = rules::note_type(CANONICAL, ANKI_NT);
                let c_tmpl = rules::template(&c_nt, 0);
                let mut seq = 0;
                let mut put = |ix: &mut Index<'_, '_>, bodies: &[Body4]| -> Settled {
                    for b in bodies {
                        seq += 1;
                        native(t, ix, col, &op(0xa3, seq, 5000 + seq as i64, &[], b));
                    }
                    ix.settle().unwrap()
                };
                let first_review = |id: u64, card: Id, note: Option<Id>| -> Body4 {
                    match log(Id::new_v7(1_700_000_200_000 + id), card, 7000 + id as i64) {
                        Body4::Log(l) => Body4::Log(Log4 {
                            note: note.map(key),
                            ..l
                        }),
                        _ => unreachable!(),
                    }
                };
                // 新建笔记（规范 ID）、它的卡的第一条复习（日志里带着笔记）：证得出，表里不多一行。
                let x = rules::note(CANONICAL, "guid-new");
                let xc = rules::card(&x, &c_tmpl, 0);
                let s = put(
                    &mut ix,
                    &[entity(
                        EntKind::Note,
                        x,
                        json!({"guid": "guid-new", "noteTypeId": c_nt.text()}),
                    )],
                );
                assert_eq!((s.aliases_proven, s.aliases), (1, 0));
                let s = put(&mut ix, &[first_review(1, xc, Some(x))]);
                assert_eq!((s.aliases_proven, s.aliases), (1, 0));
                assert_eq!(ix.canonical(&r(xc))?, r(xc));
                // 新建牌组、改名：证得出。
                let d = rules::deck(CANONICAL, "Deck A");
                let s = put(
                    &mut ix,
                    &[
                        entity(EntKind::Deck, d, json!({})),
                        edit(EntKind::Deck, d, "name", json!("Deck A")),
                    ],
                );
                assert_eq!(s.aliases_proven, 1);
                let s = put(&mut ix, &[edit(EntKind::Deck, d, "name", json!("Deck B"))]);
                assert_eq!(s.aliases_proven, 1);
                // 同 guid 的笔记已经有带盐的成员：这一小份里类不全，整表重算。
                let s = put(
                    &mut ix,
                    &[entity(
                        EntKind::Note,
                        w.c_note,
                        json!({"guid": GUID, "noteTypeId": c_nt.text()}),
                    )],
                );
                assert_eq!(s.aliases_proven, 0);
                assert!(s.aliases > 0);
                // 卡先到（日志里没写笔记）：证不出，整表重算，卡成了「出现过、验不上」的候选行。
                let y = rules::note(CANONICAL, "guid-late");
                let yc = rules::card(&y, &c_tmpl, 0);
                let s = put(&mut ix, &[first_review(2, yc, None)]);
                assert_eq!(s.aliases_proven, 0);
                assert_eq!(ix.alias_how(&yc)?, Some(A_UNVERIFIED));
                // 笔记后到：候选行在这一小份里验上了——不能只写这一批，整表重算。
                let s = put(
                    &mut ix,
                    &[entity(
                        EntKind::Note,
                        y,
                        json!({"guid": "guid-late", "noteTypeId": c_nt.text()}),
                    )],
                );
                assert_eq!(s.aliases_proven, 0);
                assert_eq!(ix.alias_how(&yc)?, None);
                // 新笔记在另一个盐下的值，它的兜底 ID 早就作为卡出现过（验不上）：新笔记一到它就成了兜底别名，
                // 这一小份里的候选行变了，整表重算。
                let f = rules::merge_fallback(U1, &rules::note(Some(U1), "guid-fb").text());
                put(&mut ix, &[first_review(4, f, None)]);
                assert_eq!(ix.alias_how(&f)?, Some(A_UNVERIFIED));
                let z = rules::note(CANONICAL, "guid-fb");
                let s = put(
                    &mut ix,
                    &[entity(
                        EntKind::Note,
                        z,
                        json!({"guid": "guid-fb", "noteTypeId": c_nt.text()}),
                    )],
                );
                assert_eq!(s.aliases_proven, 0);
                assert_eq!(ix.alias_how(&f)?, Some(A_FALLBACK));
                // 不改证据的照旧什么都不做。
                let s = put(&mut ix, &[first_review(3, xc, Some(x))]);
                assert_eq!((s.aliases_proven, s.aliases), (0, 0));
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 攒着的时候不重算，放开后的下一次收尾补上。
    #[test]
    fn held_recomputation_catches_up_on_the_next_settle() {
        with(|t, col| {
            let w = world();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                ix.hold_aliases(true);
                feed(t, &mut ix, col, 0xa1, &ops_of(&w));
                ix.settle()?;
                assert!(ix.aliases_stale());
                assert_eq!(ix.canonical(&r(w.note))?, r(w.note));
                ix.hold_aliases(false);
                ix.settle()?;
                assert!(!ix.aliases_stale());
                assert_eq!(ix.canonical(&r(w.note))?, r(w.c_note));
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 清除掉定义史之后，由它派生的卡验不上了（设计 §10 第 19 条），本机把这个实体列进「有生效清除、带自然键」的
    /// 清单；落不落成空洞别名表都一样。不信任清除作者的设备证据还在。
    #[test]
    fn a_purge_takes_the_evidence_away_and_the_entity_is_listed() {
        with(|t, col| {
            let w = world();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &ops_of(&w));
                ix.settle()?;
                assert_eq!(ix.key_evidence(EntKind::NoteType, &r(w.nt))?, 1);
                assert_eq!(ix.hollowed()?, []);
                let purge = Body4::Purge {
                    kind: EntKind::NoteType,
                    entity: key(w.nt),
                };
                native(t, &mut ix, col, &op(0xa2, 1, 9000, &[], &purge));
                ix.settle()?;
                // 笔记的 guid 在身份记录里，还验得上；卡要靠模板定义，验不上了。
                assert_eq!(ix.canonical(&r(w.note))?, r(w.c_note));
                assert_eq!(ix.canonical(&r(w.card))?, r(w.card));
                assert_eq!(ix.key_evidence(EntKind::NoteType, &r(w.nt))?, 0);
                let listed = ix.hollowed()?;
                assert_eq!(listed.len(), 1);
                assert_eq!(
                    (listed[0].kind, &listed[0].entity, listed[0].pending),
                    (EntKind::NoteType, &r(w.nt), 1)
                );
                assert_eq!(listed[0].purges.len(), 1);
                let before = dump(t.conn(), col);
                assert_eq!(ix.execute_purges()?, 1);
                let after = dump(t.conn(), col);
                let alias = |d: &[String]| -> Vec<String> {
                    d.iter()
                        .filter(|l| l.starts_with("alias_"))
                        .cloned()
                        .collect()
                };
                assert_eq!(alias(&before), alias(&after));
                assert_eq!(ix.hollowed()?[0].pending, 0);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
        // 同样的操作，本机不信任清除的作者：清除不执行，别名照旧。
        with(|t, col| {
            let w = world();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &ops_of(&w));
                let purge = Body4::Purge {
                    kind: EntKind::NoteType,
                    entity: key(w.nt),
                };
                native(t, &mut ix, col, &op(0xa2, 1, 9000, &[], &purge));
                t.set_trust(col, &id(0xa2), Some(TRUST_PENDING), 1)?;
                ix.trust_changed();
                ix.settle()?;
                assert_eq!(ix.canonical(&r(w.card))?, r(w.c_card));
                assert_eq!(ix.hollowed()?, []);
                assert_eq!(ix.key_evidence(EntKind::NoteType, &r(w.nt))?, 1);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 旧并入改名的写入者：两边有同 seq 的同一条记录才归回去。
    #[test]
    fn a_renamed_writer_goes_back_to_the_original_when_the_dots_agree() {
        with(|t, col| {
            let merged = format!("merged-{}~w1", rules::merged_writer_hash(U1, "w1").text());
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 1, 1, &[], &Body4::salts([U1]).unwrap()),
                );
                let write = |s: HeritageStamp| {
                    Body4::Edit(Edit4 {
                        stamp: Some(s),
                        ..native_edit()
                    })
                };
                heritage(
                    t,
                    &mut ix,
                    col,
                    op(0xd1, 1, 1, &[], &write(stamp("w1", 1, r#"{"vv":{}}"#, 100))),
                );
                ix.settle()?;
                assert!(!ix.aliases_stale());
                heritage(
                    t,
                    &mut ix,
                    col,
                    op(
                        0xd2,
                        1,
                        2,
                        &[],
                        &write(stamp(&merged, 1, r#"{"vv":{}}"#, 100)),
                    ),
                );
                assert!(ix.aliases_stale());
                ix.settle()?;
                // HLC 里的写入者名字不同、物理时刻与计数相同 = 同一条记录。
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                assert_eq!(ix.canonical_writer("w1")?, "w1");
                assert_eq!(ix.alias_counts()?.writers, 1);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    // ------------------------------------------------------------ 性质：到达顺序

    /// 两台设备的日志（设备内保序），任意交错、任意分批收尾，别名表与重建的相同。
    fn interleave(seed: &[bool], a: usize, b: usize) -> Vec<bool> {
        let (mut i, mut j) = (0, 0);
        let mut out = Vec::new();
        let mut it = seed.iter().cycle();
        while i < a || j < b {
            let first = *it.next().unwrap_or(&true);
            if (first && i < a) || j >= b {
                i += 1;
                out.push(true);
            } else {
                j += 1;
                out.push(false);
            }
        }
        out
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(48))]
        #[test]
        fn the_alias_table_does_not_depend_on_arrival_order(
            seed in proptest::collection::vec(any::<bool>(), 1..12),
            cuts in proptest::collection::vec(any::<bool>(), 24),
            purge in any::<bool>(),
        ) {
            let w = world();
            let fallback = rules::merge_fallback(U1, &w.review.text());
            let first = ops_of(&w);
            let mut second = vec![
                edit(EntKind::Card, w.c_card, "due", json!(2)),
                log(fallback, w.card, 2000),
                log(Id::new_v7(1_700_000_000_900), w.c_card, 3000),
                edit(EntKind::Deck, rules::deck(Some(U1), "D"), "name", json!("D")),
                edit(EntKind::Card, w.card, "deck", json!(rules::deck(Some(U1), "D").text())),
            ];
            if purge {
                second.push(Body4::Purge { kind: EntKind::NoteType, entity: key(w.nt) });
            }
            let order = interleave(&seed, first.len(), second.len());
            let run = |order: &[bool], cuts: &[bool]| -> Vec<String> {
                with(|t, col| {
                    t.tx(|t| {
                        let mut ix = Index::new(t, col);
                        let (mut i, mut j) = (0, 0);
                        for (n, from_first) in order.iter().enumerate() {
                            if *from_first {
                                native(t, &mut ix, col, &op(0xa1, i as u64 + 1, 100 + i as i64, &[], &first[i]));
                                i += 1;
                            } else {
                                native(t, &mut ix, col, &op(0xa2, j as u64 + 1, 900 + j as i64, &[], &second[j]));
                                j += 1;
                            }
                            if cuts[n % cuts.len()] {
                                ix.settle()?;
                            }
                        }
                        ix.settle()?;
                        Ok(())
                    })
                    .unwrap();
                    let incremental = dump(t.conn(), col);
                    t.tx(|t| Index::new(t, col).rebuild_all()).unwrap();
                    let rebuilt = dump(t.conn(), col);
                    assert_eq!(incremental, rebuilt);
                    rebuilt.into_iter().filter(|l| l.starts_with("alias_")).collect()
                })
            };
            let got = run(&order, &cuts);
            let straight: Vec<bool> = (0..first.len()).map(|_| true).chain((0..second.len()).map(|_| false)).collect();
            // 操作主键含本机设备号（按设备第一次出现的顺序发），别名表里没有它：换一种到达顺序逐行相同。
            prop_assert_eq!(got, run(&straight, &[false]));
        }
    }
}
