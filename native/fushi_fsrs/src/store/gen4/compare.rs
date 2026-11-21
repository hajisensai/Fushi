//! 协议 3 的投影与灌进新存储、重建之后的派生层逐类对拍（设计 §6.1 第 5 步、§8 G4 / G6c）。生产代码：G4 的干跑
//! （`dryrun.rs`）与测试装置（`parity.rs`）共用这一份比法，两边不会各比各的。
//!
//! 协议 3 一侧的缓存行由调用方给（[against_protocol_3] 的 `old_caches`）：测试装置在可写连接的 SAVEPOINT 里先做完
//! 协议 3 自己欠着的收尾再重建、整个回滚；干跑在只读连接上用影子临时表重建（`dryrun.rs`），不写旧库一个字节。
//! 交给它的缓存配置是协议 3 口径的：宿主只给一份规范 ID 的配置（`derive_cfg`），内核按 profile 的 uid 派生出带盐的那份
//! （`class.rs` [legacy_config_for]），宿主不拼盐。
//!
//! # 按规范 ID 比（设计 §6.1 第 6 步、§5.3，G9-2）
//!
//! 新代的缓存层按规范 ID 物化（`cache.rs`），协议 3 的缓存行是原值 ID。缓存三类比之前，协议 3 一侧的行先过 [CanonMap]
//! 改写成规范 ID：ID 列查别名表（加内置实体的规则）；卡 ID 若正是由它的笔记 × 模板 × 序号派生的，按规范的父 ID 重算
//! （新代的应有的卡也是这么来的，从没出现在操作里的卡别名表里没有行）；`anki_id` 列若是由原值 ID 算的，按规范 ID 重算。
//! 两侧口径相同，比的是「同一个规范实体的行」。从没并入过、没有盐的库，规范 ID 就是原值，改写是恒等。
//!
//! 寄存器按别名类判定与协议 3 的原值判定有一类已定案的差异（写入者归回让原值冲突变成支配，设计 §5.3、§10 第 24 条）：
//! [against_protocol_3] 先跑 `class.rs` 的 [Index::class_differences]，佐证得了的列为已知差异（[Known]）；缓存行里只盖
//! 它们真喂得到的列（[known_effect]：胜者变了的盖这个寄存器喂得到的列，只是冲突标志变了的只盖笔记的
//! `pending_decision`），行的其余列与行的有无照比。佐证不了的记成 `classRegisters` 差异（按 bug 处理，结论判失败）。

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use rusqlite::{Connection, OptionalExtension, ToSql, params};

use super::cache::CFG_KEY;
use super::class::{ClassDiff, ClassDiffs, builtin_rule_canon, legacy_config_for};
use super::derive::{Index, R_LIVE, Ref, body_of};
use super::schema::sql;
use super::truth::Truth;
use crate::gen4::op::{Body4, Log4};
use crate::store::sync2::semantics::current_tags;
use crate::sync2::id::{Id, Key};
use crate::sync2::op::EntKind;
use crate::sync2::vv::OpId;

/// 有差异的类别：(类别, 只在旧库, 只在新库)。空 = 完全一致。
pub(crate) type Diff = Vec<(&'static str, Vec<String>, Vec<String>)>;

/// 协议 3 一侧的 ID 改写成规范 ID 用的表（模块文件头「按规范 ID 比」）：别名表的非恒等部分（出现过的 ID → 规范 ID）
/// 与内置实体在每个盐下的规则（`class.rs` [builtin_rule_canon]）。
pub(crate) struct CanonMap {
    map: HashMap<[u8; 16], [u8; 16]>,
    rules: HashMap<[u8; 16], [u8; 16]>,
}

impl CanonMap {
    pub(crate) fn load(t: &Truth<'_>, col: i64) -> Result<CanonMap, String> {
        let mut map = HashMap::new();
        let mut stmt = t
            .conn()
            .prepare("SELECT id, canon FROM alias_ix WHERE col = ?1 AND canon != id")
            .map_err(sql)?;
        let rows = stmt
            .query_map([col], |r| {
                Ok((r.get::<_, [u8; 16]>(0)?, r.get::<_, [u8; 16]>(1)?))
            })
            .map_err(sql)?;
        for row in rows {
            let (id, canon) = row.map_err(sql)?;
            map.insert(id, canon);
        }
        let salts: Vec<String> = t
            .binding(col)?
            .map(|b| b.salts.into_iter().collect())
            .unwrap_or_default();
        Ok(CanonMap {
            map,
            rules: builtin_rule_canon(&salts),
        })
    }

    /// 规范 ID：别名表，表里没有再看内置实体的规则，都没有是它自己。
    pub(crate) fn of(&self, r: &Ref) -> Ref {
        match r {
            Ref::Uuid(b) => Ref::Uuid(*self.map.get(b).or_else(|| self.rules.get(b)).unwrap_or(b)),
            Ref::Text(_) => r.clone(),
        }
    }

    /// 一格文本（[cell] 的形）的规范形：UUID 文本换成规范 ID，别的（`∅`、非 UUID 文本）原样。
    pub(crate) fn text(&self, s: &str) -> String {
        self.of(&Ref::of(&Key::of(s))).text()
    }

    /// 一张卡的规范 ID：[id] 正是 [note] × [template] × [ord] 派生出来的（`registers::card_id`）就按规范的父 ID 重算，
    /// 否则查表。
    pub(crate) fn card(&self, id: &str, note: &str, template: &str, ord: &str) -> String {
        let Ok(ord) = ord.parse::<i64>() else {
            return self.text(id);
        };
        match crate::registers::card_id(note, template, ord) {
            Ok(derived) if derived == id => {
                crate::registers::card_id(&self.text(note), &self.text(template), ord)
                    .unwrap_or_else(|_| self.text(id))
            }
            _ => self.text(id),
        }
    }

    /// 协议 3 的三张缓存表的行（[NOTE_COLS] / [CARD_COLS] / [STAT_COLS] 的协议 3 列序）改写成规范 ID。
    pub(crate) fn rows(&self, old: &CacheRows) -> CacheRows {
        let at = |cols: &[(&str, &str)], name: &str| -> usize {
            cols.iter()
                .position(|c| c.0 == name)
                .expect("column listed in the constant")
        };
        // `anki_id` 是由行的 ID 算的（`schema::anki_numeric_id`）就按规范 ID 重算；别的值原样。
        let anki = |raw_id: &str, canon_id: &str, cell: &str| -> String {
            if cell == crate::store::schema::anki_numeric_id(raw_id).to_string() {
                crate::store::schema::anki_numeric_id(canon_id).to_string()
            } else {
                cell.to_owned()
            }
        };
        let notes = old
            .0
            .iter()
            .map(|r| {
                let mut r = r.clone();
                let raw = r[0].clone();
                for c in ["id", "note_type_id", "deck_id"] {
                    let i = at(NOTE_COLS, c);
                    r[i] = self.text(&r[i]);
                }
                let i = at(NOTE_COLS, "anki_id");
                r[i] = anki(&raw, &r[0], &r[i]);
                r
            })
            .collect();
        let mut card_of: HashMap<String, String> = HashMap::new();
        let cards = old
            .1
            .iter()
            .map(|r| {
                let mut r = r.clone();
                let raw = r[0].clone();
                r[0] = self.card(
                    &raw,
                    &r[at(CARD_COLS, "note_id")],
                    &r[at(CARD_COLS, "template_id")],
                    &r[at(CARD_COLS, "cloze_ord")],
                );
                for c in ["note_id", "template_id", "deck_id", "last_log_id"] {
                    let i = at(CARD_COLS, c);
                    r[i] = self.text(&r[i]);
                }
                let i = at(CARD_COLS, "anki_id");
                r[i] = anki(&raw, &r[0], &r[i]);
                card_of.insert(raw, r[0].clone());
                r
            })
            .collect();
        let stats = old
            .2
            .iter()
            .map(|r| {
                let mut r = r.clone();
                let (l, c) = (at(STAT_COLS, "log"), at(STAT_COLS, "card"));
                r[l] = self.text(&r[l]);
                r[c] = card_of
                    .get(&r[c])
                    .cloned()
                    .unwrap_or_else(|| self.text(&r[c]));
                r
            })
            .collect();
        (notes, cards, stats)
    }

    /// 一组 `种类:ID` 改写成规范 ID。
    pub(crate) fn kinded(&self, xs: &BTreeSet<String>) -> BTreeSet<String> {
        xs.iter()
            .map(|x| match x.split_once(':') {
                Some((k, id)) => format!("{k}:{}", self.text(id)),
                None => x.clone(),
            })
            .collect()
    }
}

/// 按类判定的已知差异（模块文件头「按规范 ID 比」）与它们在缓存层对拍里的豁免。
///
/// 豁免只给佐证得了的差异，而且只盖它真喂得到的列（[known_effect]），行的其余列与行的有无照常比——这些行里别的列上的
/// 真差异照样计入差异、影响结论：
///
/// - 胜者变了：这个寄存器喂得到的那几列（[cache_effect]）；
/// - 胜者没变、只是冲突标志变了（样本库 144 处的绝大多数，「有冲突变没冲突」）：缓存列里唯一看冲突标志的是笔记行的
///   `pending_decision`（`registers.rs` 的 `pending_decision`：任一寄存器有冲突即待裁决），所以笔记寄存器上的这种差异
///   只盖这条笔记的 `pending_decision`；笔记类型（`css` 等）、卡（`newPos` 等）上的什么都不盖、逐列照比。
#[derive(Debug, Default)]
pub(crate) struct Known {
    pub diffs: ClassDiffs,
    /// 规范笔记 / 卡 → 不比的列（值换成 [MASKED]，其余列照比）；统计行按所属的卡。
    pub note_cols: BTreeMap<String, BTreeSet<&'static str>>,
    pub card_cols: BTreeMap<String, BTreeSet<&'static str>>,
    pub stat_cols: BTreeMap<String, BTreeSet<&'static str>>,
    /// 统计行整行不比的卡（血统变了：哪些日志归这张卡本身就跟着变，[Effect::stats_aside]）。
    pub stats_aside: BTreeSet<String>,
    /// 「同一次复习的副本按规范卡成了一个事件」的卡 → 证出的那几条协议 3 多算的副本日志（[event_copies]）：只这几条
    /// 统计行不比，同卡其余统计行盖重放列、卡行盖 `CARD_DERIVED`。
    pub stats_event_copies: BTreeMap<String, BTreeSet<String>>,
    /// 同一事件的副本两边都只算一次、代表换了一份（[representative_swaps]）：协议 3 一侧的（规范）日志 → 新代的代表。
    /// 对拍前协议 3 一侧的统计行日志列与卡的 `last_log_id` 按它换掉，行的其余列照比。
    pub stats_rep_swaps: BTreeMap<String, String>,
    /// 盖了列 / 整行不比的行（两侧合计，按盖之前的原文去重）与其中两侧原文不同的。
    pub rows: u64,
    pub rows_differ: u64,
}

/// 一条已知差异在缓存对拍里盖哪些列（[Known]）：佐证不了的不盖（它已经让结论判失败）。
pub(crate) fn known_effect(d: &ClassDiff) -> Effect {
    if !d.proven {
        NO_EFFECT
    } else if d.winner_changed {
        cache_effect(d.kind, &d.key)
    } else if d.raw_conflict != d.class_conflict && d.kind == EntKind::Note {
        Effect {
            note: &["pending_decision"],
            ..NO_EFFECT
        }
    } else {
        NO_EFFECT
    }
}

/// 缓存行里盖住的格（[Known]）。
pub(crate) const MASKED: &str = "(known)";

/// 一个胜者变了的已知差异在缓存三类里喂得到哪些列（[cache_effect]）：笔记行的列、卡行的列（笔记 / 笔记类型上的差异
/// 是指它们名下的卡）、统计行的列；[stats_aside] = 这张卡的统计行整行不比。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Effect {
    pub note: &'static [&'static str],
    pub cards: &'static [&'static str],
    pub stats: &'static [&'static str],
    pub stats_aside: bool,
}

const NO_EFFECT: Effect = Effect {
    note: &[],
    cards: &[],
    stats: &[],
    stats_aside: false,
};

/// 笔记行里由寄存器算出来的列（`id` / `guid` / `created_at` / `anki_id` 来自身份记录，不在内）。
const NOTE_DERIVED: &[&str] = &[
    "note_type_id",
    "deck_id",
    "deleted_at",
    "term_key",
    "reading_key",
    "sort_field",
    "tags_json",
    "pending_decision",
    "media_refs",
    "source_kind",
    "source_title",
    "dupe_norm",
    "source_key",
];

/// 卡行里由寄存器 / 重放算出来的列（`id` / `note_id` / `template_id` / `cloze_ord` / `anki_id` 是身份，不在内）。
const CARD_DERIVED: &[&str] = &[
    "deck_id",
    "suspended",
    "buried_until_day",
    "flag",
    "hidden",
    "queue",
    "due_day",
    "due_at",
    "scheduled_days",
    "reps",
    "lapses",
    "stability",
    "difficulty",
    "last_reviewed_at",
    "last_log_id",
    "scheduler",
    "note_created_at",
    "new_position",
    "freq_rank",
];

/// 一个寄存器（实体种类 + 规范键）的胜者变了，缓存行里哪些列可能跟着变（`registers.rs` 的视图 → `caches.rs` 的
/// `note_row` / `card_row` / `TypeInfo`）。宁窄勿宽：漏了列 = 多报一条差异、结论判失败（看得见，回来补表）；多盖了列
/// = 把真差异藏起来（看不见）。认不出的键按「这个实体全部派生列」盖，但行的有无照比。
///
/// - 笔记类型：`name` / `css` / `fieldDesc/…` 不进 `TypeInfo`，不牵动任何缓存行；其余（字段 / 模板定义、词条 / 词频字段、
///   删除……）牵动这个类型下全部笔记的取字段列与它们的卡的 `hidden` / `freq_rank` / `queue`。
/// - 笔记：`f/…` → 取字段算的列与卡的 `hidden`（填空）/ `freq_rank`；`deck` → `deck_id`（卡没设牌组时跟笔记）；
///   `deleted` → 删除两列与卡的 `hidden`；`tags` / `source` → 标签 / 出处几列。`pending_decision` 看删除与内容修改的
///   并发，内容键都带上它。
/// - 卡：`deck` / `suspended` / `buried` / `flag` / `newPos` 各自那一列（停用 / 搁置连带 `queue`）；`historyFrom/…`
///   改血统 → 整张卡的派生列、统计行整行不比；其余 → 整张卡的派生列与统计行的重放列。
pub(crate) fn cache_effect(kind: EntKind, key: &str) -> Effect {
    let head = key.split('/').next().unwrap_or(key);
    let content: &[&str] = &[
        "term_key",
        "reading_key",
        "sort_field",
        "media_refs",
        "dupe_norm",
        "pending_decision",
    ];
    match (kind, head) {
        // `browseFields` 只给浏览页挑副字段，不进任何缓存列。
        (EntKind::NoteType, "name" | "css" | "fieldDesc" | "browseFields") => NO_EFFECT,
        (EntKind::NoteType, _) => Effect {
            note: &[
                "term_key",
                "reading_key",
                "sort_field",
                "media_refs",
                "dupe_norm",
                "deleted_at",
                "pending_decision",
            ],
            cards: &["hidden", "freq_rank", "queue"],
            ..NO_EFFECT
        },
        (EntKind::Note, "f") => Effect {
            note: content,
            cards: &["hidden", "freq_rank"],
            ..NO_EFFECT
        },
        (EntKind::Note, "deck") => Effect {
            note: &["deck_id", "pending_decision"],
            cards: &["deck_id"],
            ..NO_EFFECT
        },
        (EntKind::Note, "deleted") => Effect {
            note: &["deleted_at", "pending_decision"],
            cards: &["hidden"],
            ..NO_EFFECT
        },
        (EntKind::Note, "tags" | "source") => Effect {
            note: &[
                "tags_json",
                "source_kind",
                "source_title",
                "source_key",
                "pending_decision",
            ],
            ..NO_EFFECT
        },
        (EntKind::Note, _) => Effect {
            note: NOTE_DERIVED,
            cards: &["deck_id", "hidden", "freq_rank", "queue"],
            ..NO_EFFECT
        },
        (EntKind::Card, "deck") => Effect {
            cards: &["deck_id"],
            ..NO_EFFECT
        },
        (EntKind::Card, "suspended") => Effect {
            cards: &["suspended", "queue"],
            ..NO_EFFECT
        },
        (EntKind::Card, "buried") => Effect {
            cards: &["buried_until_day", "queue"],
            ..NO_EFFECT
        },
        (EntKind::Card, "flag") => Effect {
            cards: &["flag"],
            ..NO_EFFECT
        },
        (EntKind::Card, "newPos") => Effect {
            cards: &["new_position"],
            ..NO_EFFECT
        },
        (EntKind::Card, "historyFrom") => Effect {
            cards: CARD_DERIVED,
            stats_aside: true,
            ..NO_EFFECT
        },
        (EntKind::Card, _) => Effect {
            cards: CARD_DERIVED,
            stats: &["prev_due_day", "maturity_delta"],
            ..NO_EFFECT
        },
        // 牌组、profile 的寄存器不进这三张表的行。
        _ => NO_EFFECT,
    }
}

/// 把 [mask] 里的列（[cols] 的列名）换成 [MASKED]。
pub(crate) fn mask_row(row: &mut [String], cols: &[(&str, &str)], mask: &BTreeSet<&'static str>) {
    for (i, c) in cols.iter().enumerate() {
        if mask.contains(c.0) {
            row[i] = MASKED.to_owned();
        }
    }
}

pub(crate) fn op_text(id: &OpId) -> String {
    format!("{}:{}", id.device.text(), id.seq)
}

/// 索引里没被支配、也没被扣住 / 清除的写入的修改记录 ID（协议 3 的 `srs_field_edits.id`：由 dot 决定）。[skip] 里的
/// 实体（`种类:ID`）的 `deleted` 寄存器不算。
fn live_edit_ids(
    t: &Truth<'_>,
    col: i64,
    skip: &BTreeSet<String>,
) -> Result<BTreeSet<Ref>, String> {
    let mut out = BTreeSet::new();
    for k in live_keys(t, col)? {
        let e = t
            .entry_by_key(k)?
            .ok_or_else(|| format!("gen4 compare: register row {k} has no op"))?;
        let Some(Body4::Edit(ed)) = body_of(&e) else {
            return Err(format!("gen4 compare: register row {k} is not an edit"));
        };
        if ed.key == "deleted"
            && skip.contains(&format!(
                "{}:{}",
                ed.kind.wire(),
                Ref::of(&ed.entity).text()
            ))
        {
            continue;
        }
        let id = match &ed.stamp {
            Some(s) => crate::registers::edit_id(&s.writer, s.seq),
            None => crate::registers::edit_id(&e.id.device.text(), e.id.seq as i64),
        };
        out.insert(Ref::of(&Key::of(&id)));
    }
    Ok(out)
}

/// `reg_ix` 里没被支配的写入（`state >= R_LIVE`）的操作键。
fn live_keys(t: &Truth<'_>, col: i64) -> Result<Vec<i64>, String> {
    t.conn()
        .prepare("SELECT k FROM reg_ix WHERE col = ?1 AND state >= ?2")
        .map_err(sql)?
        .query_map(params![col, R_LIVE], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)
}

pub(crate) fn texts(
    conn: &Connection,
    q: &str,
    args: &[&dyn ToSql],
) -> Result<BTreeSet<String>, String> {
    conn.prepare(q)
        .map_err(sql)?
        .query_map(args, |r| r.get::<_, String>(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)
}

fn ops(conn: &Connection, table: &str, profile: &str) -> Result<BTreeSet<String>, String> {
    // 这张表比库新（真实样本是加这个功能之前的 schema）：那时没有这类行。
    let exists = conn
        .prepare("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?1")
        .map_err(sql)?
        .exists([table])
        .map_err(sql)?;
    if !exists {
        return Ok(BTreeSet::new());
    }
    let rows: Vec<([u8; 16], i64)> = conn
        .prepare(&format!(
            "SELECT device, seq FROM {table} WHERE profile_uid = srs_id(?1)"
        ))
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    Ok(rows
        .into_iter()
        .map(|(d, s)| {
            op_text(&OpId {
                device: Id(d),
                seq: s as u64,
            })
        })
        .collect())
}

pub(crate) fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02X}")).collect()
}

/// 缓存层对拍的列：(新代列, 协议 3 列)。笔记的 `updated_at` 不比（协议 3 是写行那一刻的本机时钟，新代是内容最后
/// 被改的 HLC 物理时刻——`cache.rs` 文件头「取舍」）。第一列是行的身份（只用来让差异好读，整行都比）。
pub(crate) const NOTE_COLS: &[(&str, &str)] = &[
    ("id", "id"),
    ("note_type_id", "note_type_id"),
    ("guid", "guid"),
    ("created_at", "created_at"),
    ("deck_id", "deck_id"),
    ("deleted_at", "deleted_at"),
    ("term_key", "term_key"),
    ("reading_key", "reading_key"),
    ("sort_field", "sort_field"),
    ("tags_json", "tags_json"),
    ("pending_decision", "pending_decision"),
    ("media_refs", "media_refs"),
    ("source_kind", "source_kind"),
    ("source_title", "source_title"),
    ("anki_id", "anki_id"),
    ("dupe_norm", "dupe_norm"),
    ("source_key", "source_key"),
];
pub(crate) const CARD_COLS: &[(&str, &str)] = &[
    ("id", "id"),
    ("note_id", "note_id"),
    ("template_id", "template_id"),
    ("cloze_ord", "cloze_ord"),
    ("deck_id", "deck_id"),
    ("suspended", "suspended"),
    ("buried_until_day", "buried_until_day"),
    ("flag", "flag"),
    ("hidden", "hidden"),
    ("queue", "queue"),
    ("due_day", "due_day"),
    ("due_at", "due_at"),
    ("scheduled_days", "scheduled_days"),
    ("reps", "reps"),
    ("lapses", "lapses"),
    ("stability", "stability"),
    ("difficulty", "difficulty"),
    ("last_reviewed_at", "last_reviewed_at"),
    ("last_log_id", "last_log_id"),
    ("scheduler", "scheduler"),
    ("note_created_at", "note_created_at"),
    ("new_position", "new_position"),
    ("freq_rank", "freq_rank"),
    ("anki_id", "anki_id"),
];
pub(crate) const STAT_COLS: &[(&str, &str)] = &[
    ("log", "log_id"),
    ("card", "card_id"),
    ("at", "occurred_at"),
    ("utc_offset_min", "utc_offset_min"),
    ("rating", "rating"),
    ("kind", "kind"),
    ("duration_ms", "duration_ms"),
    ("prev_due_day", "prev_due_day"),
    ("maturity_delta", "maturity_delta"),
];

/// 一格的文本形：16 字节的 ID 写成 UUID 文本（新代存 [Ref]，协议 3 存 `srs_id`），其余按值。
pub(crate) fn cell(v: rusqlite::types::ValueRef<'_>) -> String {
    use rusqlite::types::ValueRef;
    match v {
        ValueRef::Null => "∅".to_owned(),
        ValueRef::Integer(i) => i.to_string(),
        ValueRef::Real(f) => format!("{f:?}"),
        ValueRef::Text(t) => String::from_utf8_lossy(t).into_owned(),
        ValueRef::Blob(b) => match <[u8; 16]>::try_from(b) {
            Ok(u) => Ref::Uuid(u).text(),
            Err(_) => hex(b),
        },
    }
}

/// 一张表的行（每行各列的文本形）。
pub(crate) fn rows_of(
    conn: &Connection,
    table: &str,
    cols: &[&str],
    filter: &str,
    arg: &dyn ToSql,
) -> Result<Vec<Vec<String>>, String> {
    let mut stmt = conn
        .prepare(&format!(
            "SELECT {} FROM {table} WHERE {filter}",
            cols.join(", ")
        ))
        .map_err(|e| e.to_string())?;
    let mut rows = stmt.query([arg]).map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    while let Some(r) = rows.next().map_err(|e| e.to_string())? {
        out.push(
            (0..cols.len())
                .map(|i| r.get_ref(i).map(cell))
                .collect::<Result<_, _>>()
                .map_err(sql)?,
        );
    }
    Ok(out)
}

/// 三张缓存表的行：(笔记, 卡, 统计)。
pub(crate) type CacheRows = (Vec<Vec<String>>, Vec<Vec<String>>, Vec<Vec<String>>);

/// 协议 3 一侧的缓存行为什么拿不到（[OldCaches] 的错误）。按失败发生在哪段代码里分，不按错误文本猜。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum OldCachesError {
    /// 协议 3 自己的代码（冻结的缓存重建 `store::caches::rebuild`，测试口径下还有它之前的收尾）失败了。已知的一类是身份
    /// 记录不成形时整次失败（`cache.rs` 文件头「与协议 3 的差别」：缺字段 / 字段类型不对 / 笔记 ID 不是 UUID）。协议 3
    /// 一侧没有基准，缓存层这三类对拍做不成（[CacheBaseline::Unavailable]）。
    Protocol3(String),
    /// 给协议 3 搭重建环境、读回它写的行时失败（调用方这边的问题）：照报成差异。
    Setup(String),
}

impl OldCachesError {
    pub(crate) fn text(&self) -> &str {
        match self {
            Self::Protocol3(e) | Self::Setup(e) => e,
        }
    }
}

/// 缓存层对拍的协议 3 基准（[cache_pairs] 的结果）。
#[derive(Debug)]
pub(crate) enum CacheBaseline {
    /// 新代没设缓存配置：不物化，缓存层本来就不比。
    NotConfigured,
    /// 设了缓存配置，但协议 3 一侧的缓存行拿不到（[OldCachesError]）：缓存层没比成。调用方不能把这当成「比过了没差异」。
    Unavailable(String),
    /// 协议 3 重建出来的缓存行，已逐列比过。
    Rows(CacheRows),
}

impl CacheBaseline {
    pub(crate) fn rows(&self) -> Option<&CacheRows> {
        match self {
            Self::Rows(r) => Some(r),
            Self::NotConfigured | Self::Unavailable(_) => None,
        }
    }
}

/// 同一个旧修改记录 ID（旧戳的写入者 + seq）下有两条以上不同修改（不同实体或字段键）：复制出来的两份旧库各自又以
/// 同一个写入者写了同一个 seq（`tests_channel` 的 `ch-l1` / `ch-l2`）。新代两条都是独立的操作、各自进自己的寄存器；
/// 协议 3 的投影表按修改记录 ID 只存一行，留哪条看这台设备先收到哪份（设计 §2.5 差别表第 15 条）。
#[derive(Clone, Debug, Default)]
pub(crate) struct Collisions {
    /// 撞车的修改记录 ID：`edits` 两边都不比。不看状态——撞车的另一条在新代里被支配了也一样（协议 3 可能留的正是那条）。
    pub edit_ids: BTreeSet<Ref>,
    /// 撞车、且在新代里活着的修改落在的笔记（`note:ID`）：这些笔记的内容（与由内容决定的卡）对不上协议 3 是到达顺序
    /// 造成的，缓存层不比它们与它们的卡。
    pub notes: BTreeSet<String>,
    /// 撞车的修改落在的寄存器（`种类:ID`, 键），两条都算：协议 3 只存了其中一条，另一个寄存器的胜者随之不同（干跑的
    /// `registerWinners` 不比这些寄存器）。
    pub registers: BTreeSet<(String, String)>,
}

/// 扫一遍 `reg_ix` 的全部写入，找出 [Collisions]。同时在内存里的只有每个旧 dot 的第一条修改（大库三十多万个）。
pub(crate) fn collisions(t: &Truth<'_>, col: i64) -> Result<Collisions, String> {
    type Edit = (String, String, bool);
    let mut first: BTreeMap<(String, i64), Edit> = BTreeMap::new();
    let mut more: BTreeMap<(String, i64), Vec<Edit>> = BTreeMap::new();
    let rows: Vec<(i64, i64)> = t
        .conn()
        .prepare("SELECT k, state FROM reg_ix WHERE col = ?1")
        .map_err(sql)?
        .query_map([col], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for (k, state) in rows {
        let e = t
            .entry_by_key(k)?
            .ok_or_else(|| format!("gen4 compare: register row {k} has no op"))?;
        let Some(Body4::Edit(ed)) = body_of(&e) else {
            continue;
        };
        let Some(st) = &ed.stamp else {
            continue;
        };
        let edit = (
            format!("{}:{}", ed.kind.wire(), Ref::of(&ed.entity).text()),
            ed.key.clone(),
            state >= R_LIVE,
        );
        let dot = (st.writer.clone(), st.seq);
        match first.get(&dot) {
            None => {
                first.insert(dot, edit);
            }
            Some(f) if (&f.0, &f.1) == (&edit.0, &edit.1) => {}
            Some(_) => more.entry(dot).or_default().push(edit),
        }
    }
    let mut out = Collisions::default();
    for (dot, rest) in more {
        out.edit_ids
            .insert(Ref::of(&Key::of(&crate::registers::edit_id(&dot.0, dot.1))));
        let f = first.remove(&dot).expect("a collision has a first edit");
        for (ent, key, live) in std::iter::once(f).chain(rest) {
            if live && ent.starts_with("note:") {
                out.notes.insert(ent.clone());
            }
            out.registers.insert((ent, key));
        }
    }
    Ok(out)
}

/// 缓存层三类（`notes` / `cards` / `stats`）的对拍对：新代没设缓存配置时没有（不物化），协议 3 一侧拿不到缓存行时也
/// 没有（结果分别是 [CacheBaseline::NotConfigured] / [CacheBaseline::Unavailable]）。两种口径：
///
/// - [held] 是有删除被扣住的实体（`种类:ID`，任一边）：协议 3 的 `deleted` 寄存器里留着哪几条取决于被扣住的那条删除
///   到的时候落没落过投影（[against_protocol_3] 的 `edits` 口径），所以这些笔记行的 `deleted_at` / `pending_decision`
///   与它们的卡的 `hidden` 不比，其余列照比。
/// - [collided_notes]：这些笔记的行与它们的卡行两边都不比（统计行的归属随卡的可见性变，归属卡是这些卡的也不比）。
///
/// [skip] 是调用方另外不比的笔记与卡（干跑：协议 3 自己还欠着收尾、只读连接上做不了的，见 `dryrun.rs`）。
#[allow(clippy::too_many_arguments)]
pub(crate) fn cache_pairs(
    src: &Connection,
    profile: &str,
    t: &Truth<'_>,
    col: i64,
    held: &BTreeSet<String>,
    collided: &BTreeSet<String>,
    old_caches: &mut OldCaches<'_>,
    skip: &Skip,
    known: &mut Known,
    diff: &mut Diff,
) -> Result<CacheBaseline, String> {
    let Some(cfg) = t.derive_cfg(col, CFG_KEY)? else {
        return Ok(CacheBaseline::NotConfigured);
    };
    // 宿主交给新代的是规范 ID 的配置；冻结的协议 3 重建要的是这个 profile 带盐的那份（`class.rs` [legacy_config_for]）。
    // 换不出来（配置不是 JSON）与解析配置失败同一类：搭环境失败，照报成差异。
    let legacy = match legacy_config_for(profile, &cfg) {
        Ok(v) => v,
        Err(e) => {
            push_pair(
                diff,
                ("caches", BTreeSet::from([e.clone()]), BTreeSet::new()),
            );
            return Ok(CacheBaseline::Unavailable(e));
        }
    };
    let old = match old_caches(src, profile, &legacy) {
        Ok(v) => v,
        // 协议 3 那边没有行可比（新代那边身份记录不成形的实体没有行、其余照常，单元测试钉）：缓存层没比成，交给调用方
        // 记成基准缺失。
        Err(OldCachesError::Protocol3(e)) => return Ok(CacheBaseline::Unavailable(e)),
        // 搭环境 / 读行失败：照报成差异。
        Err(e @ OldCachesError::Setup(_)) => {
            let text = e.text().to_owned();
            push_pair(
                diff,
                ("caches", BTreeSet::from([text.clone()]), BTreeSet::new()),
            );
            return Ok(CacheBaseline::Unavailable(text));
        }
    };
    // 协议 3 一侧改写成规范 ID（模块文件头「按规范 ID 比」）；跳过 / 扣住的集合同样改写。
    let canon = CanonMap::load(t, col)?;
    let mut canonical = canon.rows(&old);
    let news = |cols: &[(&'static str, &'static str)]| -> Vec<&'static str> {
        cols.iter().map(|c| c.0).collect()
    };
    let new =
        |table: &str, cols: &[(&'static str, &'static str)]| -> Result<Vec<Vec<String>>, String> {
            rows_of(t.conn(), table, &news(cols), "col = ?1", &col)
        };
    // 同一次复习的副本按规范卡成了一个事件（[event_copies]）：这张卡的历史少了证出的那几条。只剔掉这几条统计行，
    // 同卡其余统计行照比、只盖由历史重放的列（同卡寄存器的已知差异同一口径，[cache_effect]），卡行盖重放列。
    let new_stats = new("stats", STAT_COLS)?;
    known.stats_event_copies = event_copies(t, col, &canon, &canonical.2, &new_stats)?;
    // 同一事件的副本两边都只算一次、但代表不是同一份（[representative_swaps]）：协议 3 一侧的统计行与卡的
    // `last_log_id` 换成新代的代表再比，行的其余列照比。
    known.stats_rep_swaps = {
        let copies: HashSet<&str> = known
            .stats_event_copies
            .values()
            .flatten()
            .map(String::as_str)
            .collect();
        representative_swaps(t, col, &canon, &canonical.2, &new_stats, &copies)?
    };
    apply_swaps(&mut canonical, &known.stats_rep_swaps);
    let (old_notes, old_cards, old_stats) = (&canonical.0, &canonical.1, &canonical.2);
    let held = &canon.kinded(held);
    let collided = &canon.kinded(collided);
    let skip = &Skip {
        notes: skip.notes.iter().map(|n| canon.text(n)).collect(),
        cards: skip.cards.iter().map(|c| canon.text(c)).collect(),
    };
    let at = |cols: &[(&str, &str)], name: &str| -> usize {
        cols.iter()
            .position(|c| c.0 == name)
            .expect("column listed in the constant")
    };
    let held_note = |id: &str| held.contains(&format!("note:{id}"));
    let skip_note = |id: &str| collided.contains(&format!("note:{id}")) || skip.notes.contains(id);
    // 已知差异喂得到的列（[Known]、[known_effect]）：笔记类型上的落到这个类型的全部笔记，笔记上的落到它的卡（卡列
    // 另记），卡上的落到它的统计行。
    for c in known.stats_event_copies.keys() {
        known
            .stat_cols
            .entry(c.clone())
            .or_default()
            .extend(["prev_due_day", "maturity_delta"]);
        known
            .card_cols
            .entry(c.clone())
            .or_default()
            .extend(CARD_DERIVED.iter().copied());
    }
    let mut new_notes = new("notes", NOTE_COLS)?;
    let mut note_card: BTreeMap<String, BTreeSet<&'static str>> = BTreeMap::new();
    {
        let mut types: BTreeMap<String, (BTreeSet<&'static str>, BTreeSet<&'static str>)> =
            BTreeMap::new();
        let add = |m: &mut BTreeMap<String, BTreeSet<&'static str>>,
                   id: String,
                   cols: &[&'static str]| {
            if !cols.is_empty() {
                m.entry(id).or_default().extend(cols.iter().copied());
            }
        };
        let masking: Vec<(EntKind, String, Effect)> = known
            .diffs
            .diffs
            .iter()
            .map(|d| (d.kind, d.entity.text(), known_effect(d)))
            .filter(|(_, _, e)| *e != NO_EFFECT)
            .collect();
        for (kind, id, e) in masking {
            match kind {
                EntKind::NoteType => {
                    let t = types.entry(id).or_default();
                    t.0.extend(e.note.iter().copied());
                    t.1.extend(e.cards.iter().copied());
                }
                EntKind::Note => {
                    add(&mut known.note_cols, id.clone(), e.note);
                    add(&mut note_card, id, e.cards);
                }
                EntKind::Card => {
                    add(&mut known.card_cols, id.clone(), e.cards);
                    add(&mut known.stat_cols, id.clone(), e.stats);
                    if e.stats_aside {
                        known.stats_aside.insert(id);
                    }
                }
                _ => {}
            }
        }
        let ty = at(NOTE_COLS, "note_type_id");
        for r in old_notes.iter().chain(&new_notes) {
            if let Some((n, c)) = types.get(&r[ty]) {
                let n: Vec<&'static str> = n.iter().copied().collect();
                let c: Vec<&'static str> = c.iter().copied().collect();
                add(&mut known.note_cols, r[0].clone(), &n);
                add(&mut note_card, r[0].clone(), &c);
            }
        }
    }
    let note_cols = known.note_cols.clone();
    // 盖了列 / 整行不比的行的原文：(旧一侧, 新一侧)。
    let mut aside: (BTreeSet<String>, BTreeSet<String>) = Default::default();
    // 三张表一张一张比：同时在内存里的只有一张表两侧的行。
    let notes = |rows: &[Vec<String>], aside: &mut BTreeSet<String>| -> BTreeSet<String> {
        rows.iter()
            .filter(|r| !skip_note(&r[0]))
            .map(|r| {
                let mut r = r.clone();
                if held_note(&r[0]) {
                    r[at(NOTE_COLS, "deleted_at")] = "(held)".to_owned();
                    r[at(NOTE_COLS, "pending_decision")] = "(held)".to_owned();
                }
                if let Some(m) = note_cols.get(&r[0]) {
                    aside.insert(r.join(" | "));
                    mask_row(&mut r, NOTE_COLS, m);
                }
                r.join(" | ")
            })
            .collect()
    };
    let old_side = notes(old_notes, &mut aside.0);
    let new_side = notes(&new_notes, &mut aside.1);
    push_pair(diff, ("notes", old_side, new_side));
    let new_cards = new("cards", CARD_COLS)?;
    // 笔记类型的删除被扣住时同理：卡的 `hidden` 跟着笔记类型删没删（`caches.rs` 笔记行的 `gone`），协议 3 的
    // `deleted` 寄存器里留着哪几条同样取决于到达顺序，这些笔记的卡不比 `hidden`。
    let held_types: BTreeSet<&str> = held
        .iter()
        .filter_map(|e| e.strip_prefix("notetype:"))
        .collect();
    let type_held: BTreeSet<String> = if held_types.is_empty() {
        BTreeSet::new()
    } else {
        old_notes
            .iter()
            .chain(&new_notes)
            .filter(|r| held_types.contains(r[at(NOTE_COLS, "note_type_id")].as_str()))
            .map(|r| r[0].clone())
            .collect()
    };
    new_notes.clear();
    let held_card = |note: &str| held_note(note) || type_held.contains(note);
    let skipped_cards: BTreeSet<String> = old_cards
        .iter()
        .chain(&new_cards)
        .filter(|r| skip_note(&r[at(CARD_COLS, "note_id")]))
        .map(|r| r[0].clone())
        .chain(skip.cards.iter().cloned())
        .collect();
    for r in old_cards.iter().chain(&new_cards) {
        if let Some(c) = note_card.get(&r[at(CARD_COLS, "note_id")]) {
            known
                .card_cols
                .entry(r[0].clone())
                .or_default()
                .extend(c.iter().copied());
        }
    }
    let card_cols = known.card_cols.clone();
    let cards = |rows: &[Vec<String>], aside: &mut BTreeSet<String>| -> BTreeSet<String> {
        rows.iter()
            .filter(|r| !skipped_cards.contains(&r[0]))
            .map(|r| {
                let mut r = r.clone();
                if held_card(&r[at(CARD_COLS, "note_id")]) {
                    r[at(CARD_COLS, "hidden")] = "(held)".to_owned();
                }
                if let Some(m) = card_cols.get(&r[0]) {
                    aside.insert(r.join(" | "));
                    mask_row(&mut r, CARD_COLS, m);
                }
                r.join(" | ")
            })
            .collect()
    };
    let old_side = cards(old_cards, &mut aside.0);
    let new_side = cards(&new_cards, &mut aside.1);
    push_pair(diff, ("cards", old_side, new_side));
    drop(new_cards);
    let (stat_cols, stats_aside) = (&known.stat_cols, &known.stats_aside);
    let copy_logs: HashSet<&str> = known
        .stats_event_copies
        .values()
        .flatten()
        .map(String::as_str)
        .collect();
    let stats = |rows: &[Vec<String>], aside: &mut BTreeSet<String>| -> BTreeSet<String> {
        let card = at(STAT_COLS, "card");
        let log = at(STAT_COLS, "log");
        rows.iter()
            .filter(|r| !skipped_cards.contains(&r[card]))
            .filter_map(|r| {
                if stats_aside.contains(&r[card]) || copy_logs.contains(r[log].as_str()) {
                    aside.insert(r.join(" | "));
                    return None;
                }
                let mut r = r.clone();
                if let Some(m) = stat_cols.get(&r[card]) {
                    aside.insert(r.join(" | "));
                    mask_row(&mut r, STAT_COLS, m);
                }
                Some(r.join(" | "))
            })
            .collect()
    };
    let old_side = stats(old_stats, &mut aside.0);
    let new_side = stats(&new_stats, &mut aside.1);
    push_pair(diff, ("stats", old_side, new_side));
    known.rows = aside.0.union(&aside.1).count() as u64;
    known.rows_differ = aside.0.symmetric_difference(&aside.1).count() as u64;
    Ok(CacheBaseline::Rows(old))
}

/// 协议 3 一侧多出来、新代按规范卡归成同一事件的复习副本：（规范）卡 → 证出的副本日志（[Known::stats_event_copies]）。
///
/// 卡片历史按 [`EventKey`](crate::history) 把同一次复习的副本归成一个事件、只算代表那一份；新代的成组键用规范卡 ID
/// （设计 §5.3「别名表怎么用」），协议 3 用原值卡 ID。资料库并入留下的两张卡副本（同一张卡的两个带盐 ID）各带一份同一次
/// 复习、日志 ID 又没归到一起时，协议 3 在后继卡的统计里算两次，新代算一次——之后的统计行（`maturity_delta` 等按前一次
/// 复习算的列）也跟着不同。
///
/// 只认佐证得了的：协议 3 一侧有一行的日志 L 不在新代的统计里，同一张规范卡、同一发生时刻上另有一行的日志 L' 在新代的
/// 统计里，且新代存的两条日志体 HLC（含写入者）、发生时刻、种类、来源、评分类型、评分、Anki id 逐个相同，原值卡不同、
/// 规范卡相同——正是成组键只差在卡 ID 归一上的情形。别的统计行差异照比。
fn event_copies(
    t: &Truth<'_>,
    col: i64,
    canon: &CanonMap,
    old_stats: &[Vec<String>],
    new_stats: &[Vec<String>],
) -> Result<BTreeMap<String, BTreeSet<String>>, String> {
    let pos = |name: &str| -> usize {
        STAT_COLS
            .iter()
            .position(|c| c.0 == name)
            .expect("column listed in the constant")
    };
    let (log, card, at) = (pos("log"), pos("card"), pos("at"));
    let counted: HashSet<&str> = new_stats.iter().map(|r| r[log].as_str()).collect();
    let mut by_card: BTreeMap<&str, Vec<&Vec<String>>> = BTreeMap::new();
    for r in old_stats {
        by_card.entry(r[card].as_str()).or_default().push(r);
    }
    let body = |id: &str| log_body(t, col, id);
    let same_event = |a: &Log4, b: &Log4| -> bool {
        a.hlc.is_some()
            && a.hlc == b.hlc
            && a.at == b.at
            && a.kind == b.kind
            && a.origin == b.origin
            && a.rtype == b.rtype
            && a.rating == b.rating
            && a.anki_id == b.anki_id
            && a.card != b.card
            && canon.of(&Ref::of(&a.card)) == canon.of(&Ref::of(&b.card))
    };
    let mut out: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for (c, rows) in by_card {
        'row: for r in rows.iter().filter(|r| !counted.contains(r[log].as_str())) {
            for o in rows
                .iter()
                .filter(|o| o[at] == r[at] && counted.contains(o[log].as_str()))
            {
                if let (Some(a), Some(b)) = (body(&r[log])?, body(&o[log])?) {
                    if same_event(&a, &b) {
                        out.entry(c.to_owned()).or_default().insert(r[log].clone());
                        continue 'row;
                    }
                }
            }
        }
    }
    Ok(out)
}

/// 日志 ID（文本）在新代存的日志体：`log_ix` 里这个 ID 操作号最小的那份；没有 / 不是日志 = None。
fn log_body(t: &Truth<'_>, col: i64, id: &str) -> Result<Option<Log4>, String> {
    let k: Option<i64> = t
        .conn()
        .prepare_cached("SELECT k FROM log_ix WHERE col = ?1 AND id = ?2 ORDER BY k LIMIT 1")
        .map_err(sql)?
        .query_row(params![col, Ref::of(&Key::of(id))], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    let Some(k) = k else { return Ok(None) };
    Ok(t.entry_by_key(k)?.and_then(|e| match body_of(&e) {
        Some(Body4::Log(l)) => Some(l),
        _ => None,
    }))
}

/// 同一事件的副本两边都只算一次、但当代表的不是同一份：协议 3 一侧统计行的（规范）日志 → 新代当代表的日志
/// （[Known::stats_rep_swaps]）。
///
/// 卡片历史把同一次复习的副本归成一个事件（`history.rs` 的 `EventKey`），组里日志 ID（UTF-16 序）最小的那份当代表、
/// 只有它进统计、当卡的 `last_log_id`。协议 3 比的是原值日志 ID，新代比的是规范日志 ID（设计 §5.3「别名表怎么用」）；
/// 带盐 / 派生的日志 ID 归一后先后次序会变，资料库并入留下的副本组里大约一半换了代表（BUG-5063：16 万条统计行、
/// 2387 张卡的 `last_log_id` 因此对不上）。
///
/// 只认佐证得了的：协议 3 一侧有一行的日志 X 不在新代统计里、新代有一行的日志 Y 不在协议 3 一侧，两条日志体的 HLC
/// （含写入者）、发生时刻、种类、来源、评分类型、评分、Anki id 逐个相同（非 Anki 来源另要规范卡相同，与 `EventKey`
/// 同一口径），这个事件在两边各只剩这一条没对上的，且 Y 按 UTF-16 序小于 X——正是新代按规范 ID 取最小的结果。
/// [copies] 是 [event_copies] 已证出的协议 3 多算的副本，不参与。
fn representative_swaps(
    t: &Truth<'_>,
    col: i64,
    canon: &CanonMap,
    old_stats: &[Vec<String>],
    new_stats: &[Vec<String>],
    copies: &HashSet<&str>,
) -> Result<BTreeMap<String, String>, String> {
    let log = STAT_COLS
        .iter()
        .position(|c| c.0 == "log")
        .expect("column listed in the constant");
    let old_logs: HashSet<&str> = old_stats.iter().map(|r| r[log].as_str()).collect();
    let new_logs: HashSet<&str> = new_stats.iter().map(|r| r[log].as_str()).collect();
    // 事件签名 → 这一侧没对上的日志。
    let sign = |id: &str| -> Result<Option<String>, String> {
        let Some(l) = log_body(t, col, id)? else {
            return Ok(None);
        };
        let Some(hlc) = &l.hlc else { return Ok(None) };
        let card = if l.origin == "anki" {
            String::new()
        } else {
            canon.of(&Ref::of(&l.card)).text()
        };
        Ok(Some(format!(
            "{hlc:?}|{}|{}|{}|{}|{:?}|{:?}|{card}",
            l.at, l.kind, l.origin, l.rtype, l.rating, l.anki_id
        )))
    };
    let mut groups: HashMap<String, (Vec<&str>, Vec<&str>)> = HashMap::new();
    for r in old_stats {
        let id = r[log].as_str();
        if new_logs.contains(id) || copies.contains(id) {
            continue;
        }
        if let Some(s) = sign(id)? {
            groups.entry(s).or_default().0.push(id);
        }
    }
    if groups.is_empty() {
        return Ok(BTreeMap::new());
    }
    for r in new_stats {
        let id = r[log].as_str();
        if old_logs.contains(id) {
            continue;
        }
        if let Some(s) = sign(id)? {
            if let Some(g) = groups.get_mut(&s) {
                g.1.push(id);
            }
        }
    }
    Ok(groups
        .into_values()
        .filter_map(|(o, n)| match (o.as_slice(), n.as_slice()) {
            ([x], [y]) if crate::ordering::cmp_utf16(y, x) == std::cmp::Ordering::Less => {
                Some(((*x).to_owned(), (*y).to_owned()))
            }
            _ => None,
        })
        .collect())
}

/// 把 [representative_swaps] 证出的代表换到协议 3 一侧（已改写成规范 ID 的缓存行）：统计行的日志列、卡行的
/// `last_log_id`。
fn apply_swaps(rows: &mut CacheRows, swaps: &BTreeMap<String, String>) {
    if swaps.is_empty() {
        return;
    }
    let at = |cols: &[(&str, &str)], name: &str| -> usize {
        cols.iter()
            .position(|c| c.0 == name)
            .expect("column listed in the constant")
    };
    let last = at(CARD_COLS, "last_log_id");
    for r in &mut rows.1 {
        if let Some(y) = swaps.get(&r[last]) {
            r[last] = y.clone();
        }
    }
    let log = at(STAT_COLS, "log");
    for r in &mut rows.2 {
        if let Some(y) = swaps.get(&r[log]) {
            r[log] = y.clone();
        }
    }
}

/// 一类对拍：(类别, 旧库一侧, 新库一侧)。
pub(crate) type Pair = (&'static str, BTreeSet<String>, BTreeSet<String>);

/// 协议 3 一侧的缓存行从哪来：(旧库连接, profile, 协议 3 口径的缓存配置 JSON) → (笔记, 卡, 统计)。配置是新代那份经
/// `class.rs` [legacy_config_for] 换回这个 profile 带盐内置 ID 的（[cache_pairs]）。
pub(crate) type OldCaches<'a> =
    dyn FnMut(&Connection, &str, &str) -> Result<CacheRows, OldCachesError> + 'a;

/// 调用方另外不比的笔记与卡（ID 文本）。
#[derive(Clone, Debug, Default)]
pub(crate) struct Skip {
    pub notes: BTreeSet<String>,
    pub cards: BTreeSet<String>,
}

/// 协议 3 的投影，与同一份库灌进新存储、重建之后的派生层比。类别：活着的修改记录 ID（`edits`，不算合成的标签行）、
/// 日志 ID（`logs`）、实体 ID（`entities`）、每条笔记现在的标签与顺序（`tags`）、媒体名绑定的内容（`media`）、
/// 被并发改动扣住的删除（`held`）、因设备不可信没执行的删除与清除（`distrusted`）、清除过的实体（`purged`）；新代设了
/// 缓存配置时再加缓存层的笔记行（`notes`）、卡行（`cards`）、有效复习投影（`stats`），按规范 ID 逐列比（[cache_pairs]）。
/// 按类判定相对原值判定的差异先算（[Known]）：佐证不了的记成 `classRegisters`。
pub(crate) fn against_protocol_3(
    src: &Connection,
    profile: &str,
    t: &Truth<'_>,
    col: i64,
    old_caches: &mut OldCaches<'_>,
    skip: &Skip,
) -> Result<(Diff, CacheBaseline, Collisions, Known), String> {
    // 每一类算出来马上化成差异、放掉两侧的集合：同时在内存里的只有一类（大库的修改记录 ID 一类就有上百万条）。
    let mut diff = Diff::new();
    let mut known = Known {
        diffs: Index::new(t, col).class_differences()?,
        ..Known::default()
    };
    let unproven: BTreeSet<String> = known
        .diffs
        .unproven()
        .map(|d| format!("{}:{}:{}", d.kind.wire(), d.entity.text(), d.key))
        .collect();
    push_pair(&mut diff, ("classRegisters", unproven, BTreeSet::new()));
    let ix = Index::new(t, col);
    // ID 类（修改记录、日志、实体）两侧都按 [Ref] 收：UUID 只占 16 字节，大库这几类各有几十万到上百万条。
    let refs = |q: &str| -> Result<BTreeSet<Ref>, String> {
        t.conn()
            .prepare(q)
            .map_err(sql)?
            .query_map([col], |r| r.get::<_, Ref>(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)
    };
    let mut old_tags: BTreeSet<String> = BTreeSet::new();
    for n in texts(
        src,
        "SELECT DISTINCT srs_idt(note) FROM sync2_tag_adds WHERE profile_uid = srs_id(?1)",
        &[&profile],
    )? {
        let tags = current_tags(src, profile, &n)?;
        if !tags.is_empty() {
            old_tags.insert(format!("{n}={tags:?}"));
        }
    }
    let mut new_tags: BTreeSet<String> = BTreeSet::new();
    for n in ix.tagged_notes()? {
        let tags = ix.tags_of(&crate::sync2::id::Key::of(&n.text()))?;
        if !tags.is_empty() {
            new_tags.insert(format!("{}={tags:?}", n.text()));
        }
    }
    // 协议 3 在两处依赖到达顺序 / 留着骨架（`weigh.rs` 文件头「与协议 3 的差别」），这两处按下面的口径比：
    // - 有删除被扣住的实体（任一边）：`deleted` 寄存器里留着哪几条修改记录不比（协议 3 取决于被扣住的那条删除
    //   到的时候落没落过投影），只比扣住的集合；
    // - 清除过的实体：扣住的集合不比（协议 3 把已清除操作的骨架也算作「并发的操作」）。
    let new_holds = ix.holds()?;
    let old_held_ents: Vec<(String, String)> = src
        .prepare(
            "SELECT srs_idt(device) || ':' || seq, kind || ':' || srs_idt(entity) FROM sync2_held \
             WHERE profile_uid = srs_id(?1)",
        )
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let new_held_ents: Vec<(String, String)> = new_holds
        .iter()
        .map(|h| {
            (
                op_text(&h.op),
                format!("{}:{}", h.kind.wire(), h.entity.text()),
            )
        })
        .collect();
    let held_ents: BTreeSet<String> = old_held_ents
        .iter()
        .chain(&new_held_ents)
        .map(|(_, ent)| ent.clone())
        .collect();
    let old_purged = texts(
        src,
        "SELECT kind || ':' || srs_idt(entity) FROM sync2_purged WHERE profile_uid = srs_id(?1)",
        &[&profile],
    )?;
    let new_purged: BTreeSet<String> = ix
        .purged_entities()?
        .into_iter()
        .map(|(k, e)| format!("{}:{}", k.wire(), e.text()))
        .collect();
    let on_unpurged = |held: &[(String, String)]| -> BTreeSet<String> {
        held.iter()
            .filter(|(_, ent)| !old_purged.contains(ent) && !new_purged.contains(ent))
            .map(|(op, _)| op.clone())
            .collect()
    };
    // 撞车的旧修改记录 ID 两边都不比（[Collisions]）。
    let collided = collisions(t, col)?;
    let mut old_edits = protocol_3_live_edits(src, profile, &held_ents)?;
    let mut new_edits = live_edit_ids(t, col, &held_ents)?;
    old_edits.retain(|id| !collided.edit_ids.contains(id));
    new_edits.retain(|id| !collided.edit_ids.contains(id));
    push_refs(&mut diff, "edits", old_edits, new_edits);
    let logs = old_refs(
        src,
        "SELECT id FROM srs_review_logs WHERE profile_uid = srs_id(?1)",
        profile,
    )?;
    push_refs(
        &mut diff,
        "logs",
        logs,
        refs("SELECT DISTINCT id FROM log_ix WHERE col = ?1")?,
    );
    let entities = old_refs(
        src,
        "SELECT id FROM srs_entities WHERE profile_uid = srs_id(?1)",
        profile,
    )?;
    push_refs(
        &mut diff,
        "entities",
        entities,
        refs("SELECT DISTINCT id FROM ent_ix WHERE col = ?1")?,
    );
    push_pair(&mut diff, ("tags", old_tags, new_tags));
    let media = texts(
        src,
        "SELECT name || '=' || hex(sha256) || ':' || size FROM sync2_media WHERE profile_uid = srs_id(?1)",
        &[&profile],
    )?;
    push_pair(
        &mut diff,
        (
            "media",
            media,
            ix.media()?
                .into_iter()
                .map(|(name, sha, size)| format!("{name}={}:{size}", hex(&sha)))
                .collect(),
        ),
    );
    push_pair(
        &mut diff,
        (
            "held",
            on_unpurged(&old_held_ents),
            on_unpurged(&new_held_ents),
        ),
    );
    push_pair(
        &mut diff,
        (
            "distrusted",
            ops(src, "sync2_trust_held", profile)?,
            ix.distrusted()?.iter().map(op_text).collect(),
        ),
    );
    push_pair(
        &mut diff,
        ("purged", old_purged.clone(), new_purged.clone()),
    );
    let rows = cache_pairs(
        src,
        profile,
        t,
        col,
        &held_ents,
        &collided.notes,
        old_caches,
        skip,
        &mut known,
        &mut diff,
    )?;
    Ok((diff, rows, collided, known))
}

/// 协议 3 投影里活着的修改记录 ID（不算合成写入者的标签行）：按协议 3 自己的寄存器判据（`registers::judge_register`）
/// 判过的。协议 3 落库时就裁掉被支配的（`land_stored`），自己写出来的投影里每个寄存器本来就只有活着的；测试直接往
/// `srs_field_edits` 插旧行造出来的旧库（例如 `tests_channel` 的 `legacy_library`：同一个旧写入者先后两条、后一条的
/// 上下文含前一条）会留着被支配的那条，它对协议 3 自己的读路径也不生效。[held] 里的实体的 `deleted` 寄存器不算。
///
/// 按寄存器顺序流式读：同时在内存里的只有一个寄存器的写入（大库的修改记录正文合计几百 MB）。
fn protocol_3_live_edits(
    src: &Connection,
    profile: &str,
    held: &BTreeSet<String>,
) -> Result<BTreeSet<Ref>, String> {
    type Row = (Ref, String, Option<i64>);
    fn flush(
        reg: &Option<(String, String)>,
        group: &mut Vec<Row>,
        held: &BTreeSet<String>,
        out: &mut BTreeSet<Ref>,
    ) -> Result<(), String> {
        let Some((ent, key)) = reg else {
            return Ok(());
        };
        if key == "deleted" && held.contains(ent) {
            // 不比（[against_protocol_3] 的 `edits` 口径）。
        } else if group.len() == 1 {
            out.insert(group[0].0.clone());
        } else {
            let items: Vec<crate::registers::StoredEdit<'_>> =
                group.iter().map(|g| (g.1.as_str(), g.2, None)).collect();
            for i in crate::registers::judge_register(&items)?.0 {
                out.insert(group[i].0.clone());
            }
        }
        group.clear();
        Ok(())
    }
    let mut out = BTreeSet::new();
    let mut stmt = src
        .prepare(
            "SELECT f.id, f.entity_kind || ':' || srs_idt(f.entity_id), f.field_key, f.json, l.server_time \
             FROM srs_field_edits f LEFT JOIN srs_event_local l ON l.event_id = f.id \
             WHERE f.profile_uid = srs_id(?1) AND f.writer_id NOT LIKE 'sync2:%' \
             ORDER BY f.entity_kind, f.entity_id, f.field_key",
        )
        .map_err(sql)?;
    let mut rows = stmt.query([profile]).map_err(sql)?;
    let mut reg: Option<(String, String)> = None;
    let mut group: Vec<Row> = Vec::new();
    while let Some(r) = rows.next().map_err(sql)? {
        let ent: String = r.get(1).map_err(sql)?;
        let key: String = r.get(2).map_err(sql)?;
        if reg.as_ref().is_none_or(|(e, k)| *e != ent || *k != key) {
            flush(&reg, &mut group, held, &mut out)?;
            reg = Some((ent, key));
        }
        group.push((
            r.get(0).map_err(sql)?,
            r.get(3).map_err(sql)?,
            r.get(4).map_err(sql)?,
        ));
    }
    flush(&reg, &mut group, held, &mut out)?;
    Ok(out)
}

/// 协议 3 一侧的一列 ID（存的是 `srs_id` 的形：规范 UUID 为 16 字节，其余为文本），按 [Ref] 收。
fn old_refs(src: &Connection, q: &str, profile: &str) -> Result<BTreeSet<Ref>, String> {
    src.prepare(q)
        .map_err(sql)?
        .query_map([profile], |r| r.get::<_, Ref>(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)
}

/// ID 类的一类对拍化成差异：只有不同的那几条转成文本。
fn push_refs(diff: &mut Diff, what: &'static str, a: BTreeSet<Ref>, b: BTreeSet<Ref>) {
    push_set(diff, what, a, b, Ref::text);
}

/// 一类对拍（两侧是紧凑形的集合）化成差异：两侧相同就没有；不同的那几条按 [text] 转成文本。
pub(crate) fn push_set<T: Ord>(
    diff: &mut Diff,
    what: &'static str,
    a: BTreeSet<T>,
    b: BTreeSet<T>,
    text: impl Fn(&T) -> String,
) {
    if a != b {
        diff.push((
            what,
            a.difference(&b).map(&text).collect(),
            b.difference(&a).map(&text).collect(),
        ));
    }
}

/// 一类对拍化成差异（两侧相同就没有），追加到 [diff]。
pub(crate) fn push_pair(diff: &mut Diff, pair: Pair) {
    diff.extend(differences([pair]));
}

/// 只留两侧不同的类别：(类别, 只在旧库, 只在新库)。
pub(crate) fn differences(pairs: impl IntoIterator<Item = Pair>) -> Diff {
    pairs
        .into_iter()
        .filter(|(_, a, b)| a != b)
        .map(|(what, a, b)| {
            (
                what,
                a.difference(&b).cloned().collect(),
                b.difference(&a).cloned().collect(),
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gen4::stamp::StampHlc;
    use crate::store::gen4::class::ClassDiff;
    use crate::store::gen4::cmd::tests_class::land;
    use crate::store::gen4::derive::tests::{heritage, op, with};
    use crate::sync2::op::Intent;

    /// 一条带旧 HLC 的原生复习日志（[event_copies] 比的那几项之外照抄）。
    fn review(id: Id, card: Id, at: i64, hlc: (i64, i64, &str)) -> Body4 {
        Body4::Log(Log4 {
            id: Key::Uuid(id),
            card: Key::Uuid(card),
            note: None,
            kind: "review".into(),
            rating: Some(1),
            revokes: None,
            at,
            ts: 1,
            origin: "fushi".into(),
            rtype: "review".into(),
            dur: 10_000,
            params: None,
            alg: Some("fsrs7".into()),
            utc_off: 480,
            rollover: 4,
            anki_id: None,
            fv: 1,
            intent: Intent::Absolute,
            res: None,
            extra: "{}".into(),
            hlc: Some(StampHlc::Parsed {
                physical: hlc.0,
                counter: hlc.1,
                writer: hlc.2.to_owned(),
            }),
            server_time: None,
        })
    }

    /// 统计行（[STAT_COLS] 列序；[event_copies] 只看日志、卡、时刻）。
    fn stat(log: Id, card: Id, at: i64) -> Vec<String> {
        let mut r = vec!["0".to_owned(); STAT_COLS.len()];
        r[0] = log.text();
        r[1] = card.text();
        r[2] = at.to_string();
        r
    }

    /// 同一次复习在两份带盐的卡上各留一条日志、日志 ID 没归到一起（真实库：资料库并入后又被并入）：协议 3 按原值卡
    /// 成组算两次，新代按规范卡算一次。HLC、时刻、内容逐个相同、原值卡不同、规范卡相同才认（规范卡与多算的那条日志记进结果）；
    /// HLC 不同（两次真复习撞同一毫秒）、或两条落在同一张原值卡上（协议 3 也会归成一个事件）都不认。
    #[test]
    fn event_copies_are_known_only_when_the_canonical_card_is_all_that_differs() {
        const AT: i64 = 1_792_431_298_815;
        for (case, b_card, b_hlc, want) in [
            (
                "same event on the two salted copies",
                1,
                (AT, 0, "w1"),
                true,
            ),
            (
                "another review in the same millisecond",
                1,
                (AT, 1, "w1"),
                false,
            ),
            ("both on one raw card", 0, (AT, 0, "w1"), false),
        ] {
            with(|t, col| {
                let w = land(t, col);
                let (a, b) = (Id::new_v7(AT as u64), Id::new_v7(AT as u64 + 1));
                t.tx(|t| {
                    let mut ix = Index::new(t, col);
                    let la = review(a, w.card[0], AT, (AT, 0, "w1"));
                    let lb = review(b, w.card[b_card], AT, b_hlc);
                    heritage(t, &mut ix, col, op(0xf1, 1, AT, &[], &la));
                    heritage(t, &mut ix, col, op(0xf2, 1, AT, &[], &lb));
                    ix.settle()?;
                    Ok(())
                })
                .unwrap();
                let canon = CanonMap::load(t, col).unwrap();
                let old = [stat(a, w.c_card, AT), stat(b, w.c_card, AT)];
                let new = [stat(a, w.c_card, AT)];
                let got = event_copies(t, col, &canon, &old, &new).unwrap();
                let expect: BTreeMap<String, BTreeSet<String>> = if want {
                    BTreeMap::from([(w.c_card.text(), BTreeSet::from([old[1][0].clone()]))])
                } else {
                    BTreeMap::new()
                };
                assert_eq!(got, expect, "{case}");
                // 两边一致（新代也算了两次）：不是差异，什么都不认。
                let got = event_copies(t, col, &canon, &old, &old).unwrap();
                assert!(got.is_empty(), "{case}: {got:?}");
            });
        }
    }

    /// 同一事件的两份副本两边都只算一次、代表不是同一份（BUG-5063：协议 3 按原值日志 ID 取最小、新代按规范日志 ID
    /// 取最小）：内容逐个相同、各只剩这一条没对上、新代那条按 UTF-16 序更小才认，认了之后协议 3 一侧的统计行日志列与
    /// 卡的 `last_log_id` 换成新代的代表；HLC 不同（两次真复习）、新代那条反而更大（不是「取最小」换出来的）、
    /// 一边有两条候选（配不成一对一）、已证出是多算副本的都不认。
    #[test]
    fn representative_swaps_are_known_only_for_one_to_one_smaller_copies() {
        const AT: i64 = 1_792_431_298_815;
        for (case, b_hlc, swap_sides, extra_old, as_copy, want) in [
            (
                "copies with the smaller one kept by gen4",
                (AT, 0, "w1"),
                false,
                false,
                false,
                true,
            ),
            (
                "another review in the same millisecond",
                (AT, 1, "w1"),
                false,
                false,
                false,
                false,
            ),
            (
                "gen4 kept the larger one",
                (AT, 0, "w1"),
                true,
                false,
                false,
                false,
            ),
            (
                "two unmatched old rows for one event",
                (AT, 0, "w1"),
                false,
                true,
                false,
                false,
            ),
            (
                "already proven as an event copy",
                (AT, 0, "w1"),
                false,
                false,
                true,
                false,
            ),
        ] {
            with(|t, col| {
                let w = land(t, col);
                let ids = [
                    Id::new_v7(AT as u64),
                    Id::new_v7(AT as u64 + 1),
                    Id::new_v7(AT as u64 + 2),
                ];
                t.tx(|t| {
                    let mut ix = Index::new(t, col);
                    let la = review(ids[0], w.card[0], AT, (AT, 0, "w1"));
                    let lb = review(ids[1], w.card[0], AT, b_hlc);
                    let lc = review(ids[2], w.card[0], AT, b_hlc);
                    heritage(t, &mut ix, col, op(0xf1, 1, AT, &[], &la));
                    heritage(t, &mut ix, col, op(0xf2, 1, AT, &[], &lb));
                    heritage(t, &mut ix, col, op(0xf3, 1, AT, &[], &lc));
                    ix.settle()?;
                    Ok(())
                })
                .unwrap();
                let canon = CanonMap::load(t, col).unwrap();
                let (small, large) = (ids[0].text(), ids[1].text());
                assert!(cmp_utf16_less(&small, &large));
                // 协议 3 留了较大的那份、新代留了较小的那份（swap_sides 反过来）。
                let (old_id, new_id) = if swap_sides {
                    (ids[0], ids[1])
                } else {
                    (ids[1], ids[0])
                };
                let mut old = vec![stat(old_id, w.c_card, AT)];
                if extra_old {
                    old.push(stat(ids[2], w.c_card, AT));
                }
                let new = [stat(new_id, w.c_card, AT)];
                let copies: HashSet<&str> = if as_copy {
                    HashSet::from([old[0][0].as_str()])
                } else {
                    HashSet::new()
                };
                let got = representative_swaps(t, col, &canon, &old, &new, &copies).unwrap();
                let expect: BTreeMap<String, String> = if want {
                    BTreeMap::from([(old_id.text(), new_id.text())])
                } else {
                    BTreeMap::new()
                };
                assert_eq!(got, expect, "{case}");
                // 两边一致：不是差异，什么都不认。
                let got =
                    representative_swaps(t, col, &canon, &old, &old, &HashSet::new()).unwrap();
                assert!(got.is_empty(), "{case}: {got:?}");
                if want {
                    let last = CARD_COLS.iter().position(|c| c.0 == "last_log_id").unwrap();
                    let mut card = vec!["0".to_owned(); CARD_COLS.len()];
                    card[last] = old_id.text();
                    let mut rows: CacheRows = (Vec::new(), vec![card], old.clone());
                    apply_swaps(&mut rows, &expect);
                    assert_eq!(rows.1[0][last], new_id.text(), "{case}: last_log_id");
                    assert_eq!(rows.2, new.to_vec(), "{case}: stat rows");
                }
            });
        }
    }

    fn cmp_utf16_less(a: &str, b: &str) -> bool {
        crate::ordering::cmp_utf16(a, b) == std::cmp::Ordering::Less
    }

    fn diff(
        kind: EntKind,
        key: &str,
        proven: bool,
        conflicts: (bool, bool),
        winner: bool,
    ) -> ClassDiff {
        ClassDiff {
            kind,
            entity: Ref::of(&Key::of("0193a1b2-0000-7000-8000-0000000000c1")),
            key: key.to_owned(),
            raw_conflict: conflicts.0,
            class_conflict: conflicts.1,
            winner_changed: winner,
            hlc_tie: false,
            dominated: Vec::new(),
            revived: Vec::new(),
            proven,
        }
    }

    /// [cache_effect] 里写的列名都真在对应的列表里（写错一个字 = 那一列静悄悄地没盖、或者该盖的没盖）。
    #[test]
    fn every_masked_column_exists() {
        let has = |cols: &[(&str, &str)], c: &str| cols.iter().any(|x| x.0 == c);
        let keys = [
            "name",
            "css",
            "fieldDesc/x",
            "fieldDef/x",
            "tmplDef/x",
            "termField",
            "freqField",
            "sortField",
            "browseFields",
            "deleted",
            "f/x",
            "deck",
            "tags",
            "source",
            "noteType",
            "suspended",
            "buried",
            "flag",
            "newPos",
            "historyFrom/x",
            "other",
        ];
        for kind in EntKind::ALL {
            for key in keys {
                let e = cache_effect(kind, key);
                for c in e.note {
                    assert!(has(NOTE_COLS, c), "{kind:?} {key}: note column {c}");
                }
                for c in e.cards {
                    assert!(has(CARD_COLS, c), "{kind:?} {key}: card column {c}");
                }
                for c in e.stats {
                    assert!(has(STAT_COLS, c), "{kind:?} {key}: stat column {c}");
                }
            }
        }
    }

    /// 盖什么只看差异真喂得到什么：佐证不了的不盖；胜者没变时只有笔记寄存器的冲突标志变化盖 `pending_decision`，
    /// 笔记类型 `css`、卡 `newPos` 上的冲突变化什么都不盖；胜者变了时笔记类型的 `css` / `name` 不盖、字段定义盖取字段
    /// 的列，笔记字段不盖 `deck_id` 等无关列。
    #[test]
    fn known_differences_mask_only_what_they_feed() {
        let no_conflict = (true, false);
        assert_eq!(
            known_effect(&diff(EntKind::Note, "f/x", false, no_conflict, true)),
            NO_EFFECT
        );
        assert_eq!(
            known_effect(&diff(EntKind::NoteType, "css", true, no_conflict, false)),
            NO_EFFECT
        );
        assert_eq!(
            known_effect(&diff(EntKind::Card, "newPos", true, no_conflict, false)),
            NO_EFFECT
        );
        let e = known_effect(&diff(EntKind::Note, "f/x", true, no_conflict, false));
        assert_eq!(
            (e.note, e.cards, e.stats),
            (&["pending_decision"][..], &[][..], &[][..])
        );
        assert_eq!(
            known_effect(&diff(EntKind::Note, "f/x", true, (true, true), false)),
            NO_EFFECT
        );
        for key in ["css", "name", "fieldDesc/x"] {
            assert_eq!(
                known_effect(&diff(EntKind::NoteType, key, true, (true, true), true)),
                NO_EFFECT,
                "{key}"
            );
        }
        let e = known_effect(&diff(
            EntKind::NoteType,
            "fieldDef/x",
            true,
            (true, true),
            true,
        ));
        assert!(e.note.contains(&"sort_field") && e.cards.contains(&"hidden"));
        let e = known_effect(&diff(EntKind::Note, "f/x", true, (true, true), true));
        assert!(e.note.contains(&"sort_field") && !e.note.contains(&"deck_id"));
        assert!(!e.note.contains(&"note_type_id") && !e.note.contains(&"tags_json"));
        let e = known_effect(&diff(EntKind::Card, "newPos", true, (true, true), true));
        assert_eq!(e.cards, &["new_position"][..]);
    }

    /// [mask_row] 只换列在表里的格，别的格原样。
    #[test]
    fn masking_a_row_leaves_other_cells_alone() {
        let mut row: Vec<String> = NOTE_COLS.iter().map(|c| format!("v-{}", c.0)).collect();
        mask_row(
            &mut row,
            NOTE_COLS,
            &BTreeSet::from(["sort_field", "term_key"]),
        );
        for (i, c) in NOTE_COLS.iter().enumerate() {
            if c.0 == "sort_field" || c.0 == "term_key" {
                assert_eq!(row[i], MASKED);
            } else {
                assert_eq!(row[i], format!("v-{}", c.0));
            }
        }
    }
}
