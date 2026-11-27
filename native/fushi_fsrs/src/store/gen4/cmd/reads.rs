//! `read` / `read_lib` 的新代实现：查询名、请求参数、结果的列名与类型都与协议 3 的 `store/reads.rs` 相同（Dart 侧
//! `srs_reads.dart` 不用改），数据从新代的派生层与缓存层来（设计 §2.3）：
//!
//! | 查询 | 协议 3 读 | 这里读 |
//! |---|---|---|
//! | `cards` `notes` `note_type_counts` `pending_notes` `media_refs` `term_status` `dup_groups` | 两张缓存表 | `cards` / `notes`（列相同） |
//! | `today_reviews` `review_grid` | `srs_stat_reviews` | `stats`（列 = `history::StatRow`） |
//! | `entities` `entity_count` | `srs_entities` | `ent_ix` → 每个别名类的定义（`cache.rs` `definition`） |
//! | `edits` `conflict_edits` `lapis_backfill` | `srs_field_edits` | `reg_ix` → 按类判定活着的写入（`class.rs` `class_lines`） |
//! | `successors` `source_note_candidates` `style_candidates` | `srs_field_edits` | `reg_ix` + 操作体 |
//! | `logs` `anki_logs_at` `native_logs_near` | `srs_review_logs` | `log_ix` → 每个规范日志 ID 的代表（`cache.rs` `card_logs`），`res` 按血统重放写回（`replayed_card_logs`） |
//! | `server_times` `events` `events_present` `has_user_data` | 四张事件表 + `srs_event_local` | 上面几张索引 + 操作体 |
//!
//! # 与协议 3 有意不同的地方（都出自「派生层是操作集合的函数」与 D24「按规范 ID」）
//!
//! - **ID**：结果里是规范 ID；请求里的 ID 先归一（模块 `cmd` 文件头）。一个别名类只出一份：`entities` 是类的定义，
//!   `edits` 是按类判定活着的写入（实体、键、值里嵌的 ID、三处写入者都是规范形），`logs` 是每个规范日志 ID 的代表。
//! - **回包里的 ID 按什么对回去**（请求给的是别名类的成员时）：
//!   - 按实体出行的（`entities` `edits` `logs` `cards` `notes` `conflict_edits` …）：行里写规范 ID，一个类一份；调用方
//!     要按自己给的 ID 对回去，先用同一份别名表把它归一（远程 / 本机共用的视图解码器就是这么做的）。
//!   - 回答「这些 ID 在不在 / 是多少」的（`events_present` `server_times {ids}`）：**原样回请求里的 ID**（同协议 3 的
//!     `srs_id`：小写带连字符的 UUID 文本才当 UUID，别的写法是另一个文本 ID），每个请求 ID 至多一行，成员与规范 ID 都问了就各回一行；判定按类（成员在 = 类在、时刻取
//!     类的代表）。调用方问什么、对什么，不用知道别名。
//!   - `server_times` 不给 `ids`（取全部）：日志写规范日志 ID、修改记录写原值修改记录 ID（修改记录 ID 没有别名），与
//!     `logs` / `edits` / `events` 读出的 ID 同一口径。
//!   - 请求里的键（`edits` 的 `key` / `prefix`、`conflict_edits` 的规则键）按同一条规则归一成规范键再比
//!     （`Index::canonical_key`：以完整 ID 结尾的换成规范 ID；半截 ID 无从归一）。
//! - **顺序**：协议 3 `edits` 同一实体按落库顺序（rowid），新代没有落库顺序：按 (修改键, 行 JSON) 排。其余没写
//!   `ORDER BY` 的协议 3 查询这里也一律给确定顺序（按 ID 的 SQLite 序，`cmd::sql_order`）。
//! - **`conflict_edits`** 只交回按类判**可能有值不同的并发写入**的寄存器（协议 3 交回全部「还留着两条以上记录」的，
//!   含同值的并发写入）：调用方（Dart `syncConflicts`）本来就只留有可见败者的，结果相同；两台设备各导入同一个包后
//!   每条笔记的「所属牌组」都是两条同值写入，协议 3 的口径会把它们全部交回去再丢掉。键先按规则筛、再读操作体。
//! - **`server_time`**：只有承袭来的那份（`cache.rs` 文件头「取舍」）；原生操作、身份记录没有。
//! - **`style_candidates` 的游标 `rid`** 是操作主键 `k`（协议 3 是修改记录表的 rowid）：同样只增、只当游标用。
//! - **`events` 的 `unknown`** 是 `LegacyUnknown` 操作的原文；`events_present` 认的事件 ID 是：身份记录 / 日志按别名类
//!   （类里任何一个成员在就算在）、修改记录按 `edit_id(写入者, seq)`（带旧戳的取旧戳的）、不认识的事件按 `x.id`。
//!   `events_present` 每个 ID 一行（协议 3 按来源表 `UNION ALL`，同一 ID 在投影表与操作表各命中一次就出两行）。
//! - **笔记的 `tags` 行**与协议 3 投影相同（`cmd::edit_rows`）：碰过标签的笔记恰有一行合成的 `sync2:tags:<笔记>`，
//!   值 = 按类判的 OR-Set 当前值；整列表的 `tags` 修改不单独出。日志行的 `res` 是按 historyFrom 血统重放写回的那份，
//!   与协议 3 落库的相同（不是操作里的原值）。
//! - **`profile_merges`** 是迁移带过来的「并入做到一半」标记（G9-5：迁移不再拦，标记原样进新代库的 `srs_meta`，由
//!   `profile_merge_commit` 收尾后删掉）；新代自己不再起并入。
//! - **`successors`** 只认目标是 UUID 的 `historyFrom/` 键（紧凑键，`gen4::name`）：卡 ID 恒为 UUID（`registers::card_id`
//!   与 apkg 导入），文本形的目标不会出现；按 `reg_card_key` 索引的一段取，不扫全部卡寄存器（协议 3 BUG-3543 的同一个要求）。
//!
//! # 代价
//!
//! 热路径（缓存表、按 ID 取修改 / 日志、`term_status`）与协议 3 同阶：按键的点读或索引的一段。`events` /
//! `events_present` / `server_times` / `style_candidates` / `source_note_candidates` 与协议 3 一样是整集合扫描；其中
//! `events_present` / `server_times` 按修改记录 ID 找要逐条算 ID（协议 3 有按 ID 的表），它们的调用方（备份合并、profile
//! 并入）在整批里被按操作并集的新路径替换（规划 §2.2 G9-5 / G11-4）。

use std::cell::Cell as Flag;
use std::collections::{BTreeMap, BTreeSet, HashSet};

use rusqlite::params;
use serde_json::{Value, json};

use super::{
    Cell, Files, Sel, Table, canon_ids, canon_ids_echo, logs_between, profile_of, ref_of, snapshot,
    sql_order, with_profile,
};
use crate::gen4::name::{read_edit_key, write_edit_key};
use crate::gen4::op::{Body4, KIND_EDIT, KIND_LEGACY_UNKNOWN};
use crate::store::bulk::{self, KIND_I64, KIND_OPT_I64, KIND_OPT_STR, KIND_STR};
use crate::store::gen4::alias::key_ids_by;
use crate::store::gen4::class::builtin_rule_canon;
use crate::store::gen4::derive::{Index, R_CONFLICT, R_LIVE, R_WINNER, Ref, body_of};
use crate::store::gen4::schema::{k_range, sql};
use crate::store::gen4::truth::Truth;
use crate::store::gen4::weigh::S_PURGED;
use crate::store::sync2::canonical;
use crate::sync2::codec::{Reader, Writer};
use crate::sync2::op::EntKind;
use crate::sync2::vv::OpId;

/// 一条修改行：(修改键, 行 JSON, 服务器时刻)（[super::edit_rows]）。
type EditRow = (String, String, Option<i64>);

/// 冲突候选：(种类, 实体的 SQLite 序, 规范实体)。
type Candidate = (i64, (u8, Vec<u8>), Ref);

/// 单表结果在 `files` 里的名字（同协议 3）。
const TABLE: &str = "t";

fn opt_str<'a>(req: &'a Value, k: &str) -> Option<&'a str> {
    req.get(k).and_then(Value::as_str)
}

fn need_str<'a>(req: &'a Value, k: &str) -> Result<&'a str, String> {
    opt_str(req, k).ok_or_else(|| format!("read: missing {k}"))
}

fn opt_int(req: &Value, k: &str) -> Option<i64> {
    req.get(k).and_then(Value::as_i64)
}

fn need_int(req: &Value, k: &str) -> Result<i64, String> {
    opt_int(req, k).ok_or_else(|| format!("read: missing {k}"))
}

fn flag(req: &Value, k: &str) -> bool {
    req.get(k) == Some(&Value::Bool(true))
}

/// 请求里的数组参数（没给 / null = None；给了却不是数组是调用方的 bug）。
fn list<'a>(req: &'a Value, k: &str) -> Result<Option<&'a Value>, String> {
    match req.get(k) {
        None | Some(Value::Null) => Ok(None),
        Some(v @ Value::Array(_)) => Ok(Some(v)),
        Some(_) => Err(format!("read: {k} must be an array")),
    }
}

fn need_list<'a>(req: &'a Value, k: &str) -> Result<&'a Value, String> {
    list(req, k)?.ok_or_else(|| format!("read: missing {k}"))
}

/// 整数数组参数。
fn ints(v: &Value, k: &str) -> Result<Vec<i64>, String> {
    v.as_array()
        .into_iter()
        .flatten()
        .map(|x| {
            x.as_i64()
                .ok_or_else(|| format!("read: {k} must hold integers"))
        })
        .collect()
}

fn need_kind(req: &Value, k: &str) -> Result<EntKind, String> {
    let w = need_str(req, k)?;
    EntKind::parse(w).ok_or_else(|| format!("read: unknown entity kind {w}"))
}

/// `ent_ix.kind` / `reg_ix.ekind` 的整数 → 种类。
fn ent_kind(k: i64) -> Result<EntKind, String> {
    EntKind::ALL
        .get(k as usize)
        .copied()
        .ok_or_else(|| format!("gen4 read: bad entity kind {k}"))
}

/// 按请求的 `fields` 从 [all] 里挑列（缺省全部）。
fn pick<'a>(
    all: &'a [(&'a str, u32)],
    req: &Value,
    what: &str,
) -> Result<Vec<(&'a str, u32)>, String> {
    match list(req, "fields")? {
        None => Ok(all.to_vec()),
        Some(xs) => xs
            .as_array()
            .into_iter()
            .flatten()
            .map(|x| {
                let w = x.as_str().unwrap_or_default();
                all.iter()
                    .find(|(n, _)| *n == w)
                    .copied()
                    .ok_or_else(|| format!("read {what}: unknown column {w}"))
            })
            .collect(),
    }
}

fn single(files: &mut Files, table: Vec<u8>) -> Value {
    files.push((TABLE.to_owned(), table));
    json!({})
}

/// 按实体出行、请求带 `ids` 的读（`entities` / `edits`）：表照 [single] 交出去，JSON 里放 `canon`（请求里是别名类
/// 成员的那几个 ID → 规范 ID，[canon_ids_echo]）；没有这样的 ID 时不带这个键。
fn single_echo(
    files: &mut Files,
    (table, canon): (Vec<u8>, serde_json::Map<String, Value>),
) -> Value {
    files.push((TABLE.to_owned(), table));
    if canon.is_empty() {
        json!({})
    } else {
        json!({ "canon": canon })
    }
}

fn key_bytes(key: &str) -> Vec<u8> {
    let mut w = Writer::new();
    write_edit_key(&mut w, key);
    w.into_vec()
}

fn key_text(b: &[u8]) -> Result<String, String> {
    read_edit_key(&mut Reader::new(b)).map_err(|e| format!("gen4 read: bad register key: {e}"))
}

/// 协议 3 `LIKE '%needle%'` 的判法：ASCII 字母不分大小写的子串（SQLite 的 LIKE 默认如此）。
fn like_contains(hay: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return true;
    }
    let (h, n) = (hay.as_bytes(), needle.as_bytes());
    h.windows(n.len()).any(|w| w.eq_ignore_ascii_case(n))
}

/// 一条行 JSON（修改 / 日志）：分区键填上 profile，顺手取出 [field]（字符串，没有 = 空串）。
fn row_json(json: &str, profile: &str, field: &str) -> (String, String) {
    let out = with_profile(json, profile);
    let f = serde_json::from_str::<Value>(&out)
        .ok()
        .and_then(|v| v.get(field).and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_default();
    (out, f)
}

/// 修改记录 ID（协议 3 `registers::edit_id`）：带旧戳的按旧写入者与旧 seq，不带的按 (设备, seq)。
fn edit_id_of(stamp: &Option<crate::gen4::stamp::HeritageStamp>, op: &OpId) -> String {
    match stamp {
        Some(s) => crate::registers::edit_id(&s.writer, s.seq),
        None => crate::registers::edit_id(&op.device.text(), op.seq as i64),
    }
}

/// 一个读命令的上下文。
struct Reads<'t, 'c> {
    t: &'t Truth<'c>,
    col: i64,
    ix: Index<'t, 'c>,
    profile: String,
}

/// `read`：集合 [col] 的一条只读查询（请求的 `q` 是查询名，参数与结果同协议 3 `store/reads.rs`）。在一个读快照里
/// （[snapshot]）。
pub fn run(t: &Truth<'_>, col: i64, req: &Value, files: &mut Files) -> Result<Value, String> {
    snapshot(t, |t| {
        let q = need_str(req, "q")?;
        let mut r = Reads {
            t,
            col,
            ix: Index::new(t, col),
            profile: profile_of(t, col)?,
        };
        Ok(match q {
            // 成批按类读的查询（每个实体都要归一 ID、按类拼行）在一趟里跑（[Reads::read_pass]）。
            "entities" => single_echo(files, r.read_pass(|r| r.entities(req))?),
            "entity_count" => json!({"n": r.entity_count(req)?}),
            "has_user_data" => json!({"any": r.has_user_data(req)?}),
            "edits" => {
                let (table, canon, key_canon) = r.read_pass(|r| r.edits(req))?;
                let mut v = single_echo(files, (table, canon));
                if !key_canon.is_empty() {
                    v["keyCanon"] = Value::Object(key_canon);
                }
                v
            }
            "successors" => single(files, r.successors()?),
            "conflict_edits" => single(files, r.conflict_edits(req)?),
            "style_candidates" => single(files, r.style_candidates(req)?),
            "source_note_candidates" => single(files, r.source_note_candidates(req)?),
            "lapis_backfill" => single(files, r.lapis_backfill(req)?),
            "logs" => single(files, r.read_pass(|r| r.logs(req))?),
            "anki_logs_at" => single(files, r.anki_logs_at(req)?),
            "native_logs_near" => single(files, r.native_logs_near(req)?),
            "today_reviews" => r.today_reviews(req)?,
            "reviewed_decks" => json!({"decks": r.reviewed_decks(req)?}),
            "review_grid" => single(files, r.review_grid(req)?),
            "server_times" => single(files, r.server_times(req)?),
            "cards" => single(files, r.cards(req)?),
            "notes" => single(files, r.notes(req)?),
            "note_type_counts" => single(files, r.note_type_counts()?),
            "pending_notes" => json!({"n": r.pending_notes()?}),
            "media_refs" => single(files, r.media_refs(req)?),
            "term_status" => single(files, r.term_status(req)?),
            "dup_groups" => single(files, r.dup_groups()?),
            "events" => r.events(req, files)?,
            "events_present" => single(files, r.events_present(req)?),
            other => return Err(format!("read: unknown query {other}")),
        })
    })
}

/// `profile_merges`：迁移带过来的「并入做到一半」标记（`profile_merge/<旧 uid>` 的键与原值，键升序；G9-5，
/// `cmd/profile_data.rs` 文件头「半截并入的收尾」）。语句同 `profile_merge_commit` 认的那份
/// （[super::profile_data::MERGE_MARKS_SQL]，`srs_meta` 主键区间）。
fn profile_merges(t: &Truth<'_>) -> Result<Vec<u8>, String> {
    let mut out = Table::new(&[("key", KIND_STR), ("value", KIND_STR)]);
    let mut stmt = t
        .conn()
        .prepare_cached(super::profile_data::MERGE_MARKS_SQL)
        .map_err(sql)?;
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
        .map_err(sql)?;
    for row in rows {
        let (k, v) = row.map_err(sql)?;
        out.push(vec![Cell::S(k), Cell::S(v)])?;
    }
    Ok(out.encode())
}

/// `read_lib`：不针对单个集合的只读查询（整个新代库）。
pub fn run_lib(t: &Truth<'_>, req: &Value, files: &mut Files) -> Result<Value, String> {
    snapshot(t, |t| {
        let q = need_str(req, "q")?;
        Ok(match q {
            "profile_merges" => single(files, profile_merges(t)?),
            "user_note_count" => json!({"n": user_note_count(t)?}),
            "entity_owners" => single(files, entity_owners(t)?),
            other => return Err(format!("read_lib: unknown query {other}")),
        })
    })
}

// ------------------------------------------------------------------ 不针对单个集合

/// 全部集合的规范笔记数（协议 3 数全部 profile 的笔记身份记录；这里一个别名类算一条）。
fn user_note_count(t: &Truth<'_>) -> Result<i64, String> {
    let cols: Vec<i64> = t
        .conn()
        .prepare("SELECT col FROM collections ORDER BY col")
        .map_err(sql)?
        .query_map([], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut n = 0i64;
    for col in cols {
        let ix = Index::new(t, col);
        let mut q = Sel::of(col);
        q.push(&format!(
            "SELECT DISTINCT id FROM ent_ix WHERE col = ?1 AND win = 1 AND kind = {}",
            EntKind::Note as i64
        ));
        let mut seen: HashSet<Ref> = HashSet::new();
        q.each(t, |r| {
            seen.insert(ix.canonical(&r.get::<_, Ref>(0).map_err(sql)?)?);
            Ok(())
        })?;
        n += seen.len() as i64;
    }
    Ok(n)
}

/// 有身份记录的集合绑定的 profile uid（`uid`，升序）。
fn entity_owners(t: &Truth<'_>) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(0);
    q.push(
        "SELECT profile_uid FROM collections c WHERE ?1 = ?1 \
         AND EXISTS (SELECT 1 FROM ent_ix e WHERE e.col = c.col) ORDER BY profile_uid",
    );
    q.table(t, &[("uid", KIND_STR)])
}

impl<'t, 'c> Reads<'t, 'c> {
    fn canon(&self, r: &Ref) -> Result<Ref, String> {
        self.ix.canonical(r)
    }

    // -------------------------------------------------------------- 身份记录

    /// 集合里有身份记录的全部规范 ID（升序去重）。
    fn all_entities(&self, kind: Option<EntKind>) -> Result<BTreeSet<Ref>, String> {
        let mut q = Sel::of(self.col);
        q.push("SELECT DISTINCT id FROM ent_ix WHERE col = ?1 AND win = 1");
        if let Some(k) = kind {
            let p = q.int(k as i64);
            q.push(&format!(" AND kind = {p}"));
        }
        let mut out = BTreeSet::new();
        q.each(self.t, |r| {
            out.insert(self.canon(&r.get::<_, Ref>(0).map_err(sql)?)?);
            Ok(())
        })?;
        Ok(out)
    }

    /// 规范 ID 的定义：(种类, 数据的规范 JSON 文本 = 协议 3 的 `payload_json`)。
    /// [f] 在一趟按类读里跑（[Index::in_read_pass]：归回的写入者表、内置规则表这一条命令只读一次）。
    fn read_pass<T>(
        &mut self,
        f: impl FnOnce(&mut Self) -> Result<T, String>,
    ) -> Result<T, String> {
        self.ix.pass_writers = Some(std::rc::Rc::new(self.ix.writer_aliases()?));
        let done = self.ix.pass_rules_begin().and_then(|()| f(self));
        self.ix.pass_writers = None;
        self.ix.pass_rules = None;
        done
    }

    fn definition(&self, c: &Ref) -> Result<Option<(EntKind, String)>, String> {
        Ok(match self.ix.definition(c)? {
            Some((k, _, d)) => Some((ent_kind(k)?, canonical(&d))),
            None => None,
        })
    }

    /// `entities {kind?, ids?, bare?, ordered?}`：每个别名类一行（`id`, `kind`, `payload_json`）。一律按 ID 的 SQLite
    /// 序（`ordered` 因此总成立）。`kind` 不认识 = 没有行（协议 3 同：没有这种行）。
    fn entities(
        &mut self,
        req: &Value,
    ) -> Result<(Vec<u8>, serde_json::Map<String, Value>), String> {
        let kind = opt_str(req, "kind");
        let want = kind.and_then(EntKind::parse);
        let mut canon = serde_json::Map::new();
        let mut targets: Vec<Ref> = match list(req, "ids")? {
            Some(ids) => {
                let (targets, echo) = canon_ids_echo(&self.ix, ids)?;
                canon = echo;
                targets
            }
            None if kind.is_some() && want.is_none() => Vec::new(),
            None => self.all_entities(want)?.into_iter().collect(),
        };
        targets.sort_by(|a, b| sql_order(a).cmp(&sql_order(b)));
        let bare = flag(req, "bare");
        let mut out = Table::new(if bare {
            &[("id", KIND_STR)]
        } else {
            &[
                ("id", KIND_STR),
                ("kind", KIND_STR),
                ("payload_json", KIND_STR),
            ]
        });
        for c in targets {
            let Some((k, payload)) = self.definition(&c)? else {
                continue;
            };
            if kind.is_some_and(|w| w != k.wire()) {
                continue;
            }
            out.push(if bare {
                vec![Cell::S(c.text())]
            } else {
                vec![
                    Cell::S(c.text()),
                    Cell::S(k.wire().to_owned()),
                    Cell::S(payload),
                ]
            })?;
        }
        Ok((out.encode(), canon))
    }

    /// 集合里有身份记录的别名类，按成员 ID 的 SQLite 序**逐行**交给 [f]（每个类一次：第一次遇到它的成员时），[f] 回
    /// `false` 就停。语句不排序不物化，停下时只读过前面那几行：不给种类时沿 `ent_ix` 主键 `(col, id, k)` 顺序走，给了
    /// 种类时沿部分索引 `ent_kind (col, kind, id) WHERE win = 1` 只走这一种（不先走过别的种类的身份记录）——`entity_count
    /// {kind?, limit}` 与 `has_user_data` 因此与协议 3 的 `LIMIT` / `EXISTS` 同阶（O(limit) / 碰到第一个就停），不随集合
    /// 大小涨（`cmd/tests.rs` `keyed_reads_never_walk_the_whole_collection` 钉住给了种类的那条）。去重用的集合只装已经交
    /// 出去的类。
    fn each_class(
        &self,
        kind: Option<EntKind>,
        mut f: impl FnMut(&Self, Ref) -> Result<bool, String>,
    ) -> Result<(), String> {
        let mut q = Sel::of(self.col);
        q.push("SELECT DISTINCT id FROM ent_ix WHERE col = ?1 AND win = 1");
        if let Some(k) = kind {
            let p = q.int(k as i64);
            q.push(&format!(" AND kind = {p}"));
        }
        // 顺序写明：两条索引（主键 / `ent_kind`）在各自的条件下都按 `id` 交出，不用排序；不写的话不给种类时规划器也
        // 可以挑 `ent_kind`（覆盖了 `win = 1`），那就成了按 (种类, ID) 交出。
        q.push(" ORDER BY id");
        let mut stmt = self.t.conn().prepare_cached(&q.sql).map_err(sql)?;
        let mut rows = stmt.query(q.params().as_slice()).map_err(sql)?;
        let mut seen: HashSet<Ref> = HashSet::new();
        while let Some(r) = rows.next().map_err(sql)? {
            let c = self.canon(&r.get::<_, Ref>(0).map_err(sql)?)?;
            if seen.insert(c.clone()) && !f(self, c)? {
                break;
            }
        }
        Ok(())
    }

    /// `entity_count {kind?, limit?}`：别名类的个数（`limit` 给了最多数到它：逐行数，到 `limit` 就停，[each_class]）。
    fn entity_count(&mut self, req: &Value) -> Result<i64, String> {
        let kind = opt_str(req, "kind");
        let want = kind.and_then(EntKind::parse);
        if kind.is_some() && want.is_none() {
            return Ok(0);
        }
        // 协议 3 是 SQL 的 `LIMIT`：负数 = 不限，0 = 一个都不数。
        let limit = opt_int(req, "limit").filter(|l| *l >= 0);
        if limit == Some(0) {
            return Ok(0);
        }
        let mut n = 0i64;
        self.each_class(want, |r, c| {
            if matches!(r.definition(&c)?, Some((k, _)) if want.is_none_or(|w| w == k)) {
                n += 1;
            }
            Ok(limit.is_none_or(|l| n < l))
        })?;
        Ok(n)
    }

    /// `has_user_data {builtins}`：集合里有没有 `builtins`（内置实体的 ID，可以是任何一个盐下的存量 ID 或规范 ID）之外
    /// 的数据——别的身份记录，或任何修改（含标签操作）/ 日志 / 不认识的事件。
    ///
    /// **口径**（调用方 `SrsDbStore.hasUserData`：判成「没有」= profile 关联会直接改用对方 uid、不并入本机数据，所以只许
    /// 往「有」那边偏）：
    ///
    /// - 已清除的写入（[S_PURGED]）不算：用户自己要求抹掉的内容，协议 3 的投影里也没有它们。
    /// - 被支配的写入（`R_DOMINATED`）算：盖掉它的写入同在一个寄存器里，有它就有活着的写入，结论与协议 3 相同。
    /// - 扣住的删除（[crate::store::gen4::weigh::S_HELD]）算：扣住的前提是实体上有与它并发、没被清除的操作，那条操作本身已让结果为「有」，
    ///   与协议 3（扣住的删除不进投影、并发的那条进）结论相同。
    /// - 不可信作者的删除 / 清除（[crate::store::gen4::weigh::S_DISTRUSTED]）算：协议 3 把它们放在投影外的扣住表里、不算；这里有意更保守——它们是
    ///   真实存在、等用户确认信任的操作，判成「有」只会让关联走并入而不是改用，不会丢任何东西。唯一结论不同的情形是
    ///   「除内置实体外只有一条不可信设备的删除」。
    ///
    /// 代价：身份记录逐行看、碰到第一个非内置的类就停（[Reads::each_class]），之后三个 `EXISTS` 各自碰到第一行就停。
    fn has_user_data(&mut self, req: &Value) -> Result<bool, String> {
        let rules = builtin_rule_canon(
            &self
                .t
                .binding(self.col)?
                .map(|b| b.salts.into_iter().collect::<Vec<_>>())
                .unwrap_or_default(),
        );
        let mut builtins: HashSet<Ref> = HashSet::new();
        for c in canon_ids(&self.ix, need_list(req, "builtins")?)? {
            if let Some(r) = match &c {
                Ref::Uuid(b) => rules.get(b),
                Ref::Text(_) => None,
            } {
                builtins.insert(Ref::Uuid(*r));
            }
            builtins.insert(c);
        }
        let mut user = false;
        self.each_class(None, |_, c| {
            user = !builtins.contains(&c);
            Ok(!user)
        })?;
        if user {
            return Ok(true);
        }
        let mut q = Sel::of(self.col);
        let purged = q.int(S_PURGED);
        q.push(&format!(
            "SELECT EXISTS (SELECT 1 FROM reg_ix WHERE col = ?1 AND state != {purged}) \
             OR EXISTS (SELECT 1 FROM tag_ix WHERE col = ?1 AND state != {purged}) \
             OR EXISTS (SELECT 1 FROM log_ix WHERE col = ?1)"
        ));
        if q.scalar(self.t)? != 0 {
            return Ok(true);
        }
        Ok(!self.unknown_ops(Some(1))?.is_empty())
    }

    /// 集合里 `LegacyUnknown` 操作的原文（[limit] 条为止），按操作主键。
    fn unknown_ops(&self, limit: Option<usize>) -> Result<Vec<String>, String> {
        let devs: Vec<i64> = self
            .t
            .conn()
            .prepare_cached("SELECT dev FROM devs WHERE col = ?1 ORDER BY dev")
            .map_err(sql)?
            .query_map([self.col], |r| r.get(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        let mut out = Vec::new();
        for dev in devs {
            let (lo, hi) = k_range(dev);
            let ks: Vec<i64> = self
                .t
                .conn()
                .prepare_cached(
                    "SELECT k FROM ops WHERE k BETWEEN ?1 AND ?2 AND kind = ?3 ORDER BY k",
                )
                .map_err(sql)?
                .query_map(params![lo, hi, i64::from(KIND_LEGACY_UNKNOWN)], |r| {
                    r.get(0)
                })
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for k in ks {
                if let Some(Body4::LegacyUnknown { json }) =
                    self.t.entry_by_key(k)?.as_ref().and_then(body_of)
                {
                    out.push(json);
                    if limit.is_some_and(|l| out.len() >= l) {
                        return Ok(out);
                    }
                }
            }
        }
        Ok(out)
    }

    // -------------------------------------------------------------- 修改记录

    /// 一个别名类按类判定活着的修改行：(修改键, 行 JSON, 服务器时刻)，按 (键, JSON) 排（模块文件头「顺序」；笔记的
    /// `tags` 是合成的那一行，[super::edit_rows]）。
    fn class_rows(
        &mut self,
        kind: EntKind,
        c: &Ref,
    ) -> Result<Vec<(String, String, Option<i64>)>, String> {
        super::edit_rows(self.t, &mut self.ix, kind, c, &self.profile)
    }

    /// `edits {kind, ids, key? | prefix?}`：一组实体（每个别名类一份）活着的修改记录（`e` 规范实体 ID, `j`, `st`）。
    /// `key` = 只要这一个字段键；`prefix` = 只要以它开头的。实体按 ID 的 SQLite 序，同一实体内按 (键, JSON)。
    ///
    /// 行里的键是规范键（`f/<字段>` 等嵌着的 ID 换成规范 ID），所以 `key` 与 `prefix` 先按同一条规则归一
    /// （[Index::canonical_key]）再比：以一个完整 ID 结尾的前缀（`historyFrom/<卡>`、`f/<字段>`）换成规范 ID，请求给别名
    /// 成员的形也命中；不含 ID 的前缀（`notDup/`、`f/`）不变。停在 ID 中间的前缀（半截 UUID）无从归一，只按规范键的
    /// 文本比——调用方（`noteFieldKeyPrefixValues` 的 `notDup/`）没有这种用法。
    ///
    /// `keys`（可选，G9-7）：调用方接下来要按哪些字段键取值（Dart `_currentValues` 记撤销的改前值）。回包 `keyCanon` 给
    /// 其中归一后不同的那些「请求键 → 规范键」（键里嵌着别名类的非规范成员，如持久化的带盐字段 ID），与 `canon` 同一
    /// 口径、只列不同的；调用方按它换成规范键取，不再为键另发 `canonical_ids`。
    #[allow(clippy::type_complexity)]
    fn edits(
        &mut self,
        req: &Value,
    ) -> Result<
        (
            Vec<u8>,
            serde_json::Map<String, Value>,
            serde_json::Map<String, Value>,
        ),
        String,
    > {
        let kind = need_kind(req, "kind")?;
        let mut key_canon = serde_json::Map::new();
        if let Some(keys) = req.get("keys").filter(|v| !v.is_null()) {
            for k in keys.as_array().ok_or("read edits: keys must be an array")? {
                let k = k.as_str().ok_or("read edits: keys must be strings")?;
                let c = self.ix.canonical_key(k)?;
                if c != k {
                    key_canon.insert(k.to_owned(), Value::String(c));
                }
            }
        }
        let (mut ids, canon) = canon_ids_echo(&self.ix, need_list(req, "ids")?)?;
        ids.sort_by(|a, b| sql_order(a).cmp(&sql_order(b)));
        let key = match opt_str(req, "key") {
            Some(k) => Some(self.ix.canonical_key(k)?),
            None => None,
        };
        let prefix = match opt_str(req, "prefix") {
            Some("") => return Err("read edits: empty prefix".to_owned()),
            Some(p) => Some(self.ix.canonical_key(p)?),
            None => None,
        };
        let mut out = Table::new(&[("e", KIND_STR), ("j", KIND_STR), ("st", KIND_OPT_I64)]);
        for c in ids {
            for (f, j, st) in self.class_rows(kind, &c)? {
                if key.as_ref().is_some_and(|k| *k != f)
                    || prefix.as_ref().is_some_and(|p| !f.starts_with(p.as_str()))
                {
                    continue;
                }
                out.push(vec![Cell::S(c.text()), Cell::S(j), Cell::OptI(st)])?;
            }
        }
        Ok((out.encode(), canon, key_canon))
    }

    /// `successors`：全部「前身卡 → 后继卡」链接（`entity_id` 规范后继卡, `field_key` = `historyFrom/<规范前身卡>`），
    /// 去重、按 (后继, 键) 排。只看活着的写入（协议 3 投影里的行）。
    fn successors(&mut self) -> Result<Vec<u8>, String> {
        // 紧凑键 `historyFrom/<UUID>` 的首字节（`gen4::name` 的前缀表）：这一段就是全部 UUID 目标的链接。
        let tag = key_bytes("historyFrom/00000000-0000-0000-0000-000000000000")[0];
        if tag == 0 {
            return Err("gen4 read: historyFrom keys have no compact form".to_owned());
        }
        let mut q = Sel::of(self.col);
        let lo = q.bind_blob(vec![tag]);
        let hi = q.bind_blob(vec![tag + 1]);
        let live = q.int(R_LIVE);
        q.push(&format!(
            "SELECT DISTINCT ent, key FROM reg_ix WHERE col = ?1 AND ekind = {} \
             AND key >= {lo} AND key < {hi} AND state >= {live}",
            EntKind::Card as i64
        ));
        let mut raw: Vec<(Ref, Vec<u8>)> = Vec::new();
        q.each(self.t, |r| {
            raw.push((r.get(0).map_err(sql)?, r.get(1).map_err(sql)?));
            Ok(())
        })?;
        let mut links: BTreeSet<((u8, Vec<u8>), String, Ref)> = BTreeSet::new();
        for (ent, key) in raw {
            let c = self.canon(&ent)?;
            let k = self.ix.canonical_key(&key_text(&key)?)?;
            let (o, b) = sql_order(&c);
            links.insert(((o, b.to_vec()), k, c));
        }
        let mut out = Table::new(&[("entity_id", KIND_STR), ("field_key", KIND_STR)]);
        for (_, k, c) in links {
            out.push(vec![Cell::S(c.text()), Cell::S(k)])?;
        }
        Ok(out.encode())
    }

    /// `conflict_edits {rules, kind?, id?}`：按类判定后**可能有值不同的并发写入**的寄存器上活着的全部写入（`k` 种类,
    /// `i` 规范实体, `f` 规范键, `j`, `st`），只看 `rules` 圈定的类别（[Rules]，键按规范形比）；`kind` + `id` 给了只看
    /// 这一个实体。调用方（Dart `syncConflicts`）拿这些行交给寄存器内核再判、只留有可见败者的：这里保证不漏任何一个
    /// 按类判有冲突的寄存器（[Index::class_conflict_lines]），同值的并发写入（两台设备各导入同一个包后每条笔记的
    /// 「所属牌组」）不再交回去（协议 3 交回全部「还留着两条以上记录」的，Dart 判完丢掉）。行里不带旧戳的写入的
    /// 上下文只回答「见没见过别的交回的行」（同一个寄存器内的支配判定只看这些）。
    ///
    /// 先按 `rules` 筛键再读操作体：不追踪的键（笔记字段正文、笔记的合成 `tags` 行）不读（BUG-3947，协议 3 在 SQL 里
    /// 用 `class_filter` 先筛）。候选实体见 [Reads::conflict_candidates]。
    fn conflict_edits(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        // 归回的写入者表与内置规则表在这一条命令里不变（同一个读快照）：每个候选实体都要，读一次（同 `browse.rs`）。
        self.read_pass(|r| r.conflict_edits_with(req))
    }

    fn conflict_edits_with(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        let rules = Rules::parse(&self.ix, req.get("rules").ok_or("read: missing rules")?)?;
        let only = match (opt_str(req, "kind"), opt_str(req, "id")) {
            (Some(kind), Some(id)) => Some((
                EntKind::parse(kind).ok_or_else(|| format!("read: unknown entity kind {kind}"))?,
                self.canon(&ref_of(id))?,
            )),
            (None, None) => None,
            _ => return Err("read conflict_edits: kind and id go together".into()),
        };
        let candidates: BTreeSet<Candidate> = match only {
            Some((k, c)) => {
                let (o, b) = sql_order(&c);
                BTreeSet::from([(k as i64, (o, b.to_vec()), c.clone())])
            }
            None => self.conflict_candidates(&rules)?,
        };
        let mut out = Table::new(&[
            ("k", KIND_STR),
            ("i", KIND_STR),
            ("f", KIND_STR),
            ("j", KIND_STR),
            ("st", KIND_OPT_I64),
        ]);
        for (k, _, c) in candidates {
            let kind = ent_kind(k)?;
            if !rules.touches(kind) {
                continue;
            }
            // 笔记的 `tags` 寄存器不出（读命令只出那一行合成行，`super::edit_rows`；它只有一行，不会成冲突）。
            let tracks = |f: &str| !(kind == EntKind::Note && f == "tags") && rules.tracks(kind, f);
            let pre = |raw: &str| rules.may_track(kind, raw);
            let mut rows: Vec<EditRow> =
                self.ix
                    .class_conflict_lines(kind, &c, &pre, &tracks, &self.profile)?;
            rows.sort();
            let mut by_key: BTreeMap<&str, Vec<&EditRow>> = BTreeMap::new();
            for row in &rows {
                by_key.entry(row.0.as_str()).or_default().push(row);
            }
            for (_, group) in by_key {
                if group.len() < 2 {
                    continue;
                }
                for (f, j, st) in group {
                    out.push(vec![
                        Cell::S(kind.wire().to_owned()),
                        Cell::S(c.text()),
                        Cell::S(f.clone()),
                        Cell::S(j.clone()),
                        Cell::OptI(*st),
                    ])?;
                }
            }
        }
        Ok(out.encode())
    }

    /// [Reads::conflict_edits] 的候选 (种类, 排序键, 规范实体)：按类判可能有冲突的寄存器所在的全部别名类，不多拉。
    /// 一个寄存器按类判有冲突只有这几种来路（[Index::class_conflict_lines]）：
    ///
    /// 1. 单一原值寄存器、没碰归回写入者：原值判下就有 [R_CONFLICT] 的写入；
    /// 2. 别名类里不止一个成员在这种实体下有寄存器行（跨成员并起来）——只数**有行的**成员：迁移来的库里每个实体都
    ///    带一条旧 ID 的别名、规范 ID 自己没有行，按「类里有别名」取会把整库每个实体都拉进来；
    /// 3. 同一个实体的两个原值键归一成同一个规范键（键里嵌的 ID 有别名，[Reads::merged_key_candidates]）；
    /// 4. 有归回的写入者时：碰到它的寄存器按类重判，换名可能改变支配——参与判定的不止一条写入（或有扣住的删除）的
    ///    寄存器才判得出冲突，它一定有一条不是 [R_WINNER] 的行；没有归回写入者时这一种不存在。
    fn conflict_candidates(&mut self, rules: &Rules) -> Result<BTreeSet<Candidate>, String> {
        let renamed = self.ix.pass_writers.as_ref().is_some_and(|w| !w.is_empty());
        let mut raw: Vec<(i64, Ref)> = Vec::new();
        // 一趟按 (种类, 实体) 汇总：有没有冲突的写入、有没有不是胜者的写入，连同实体的规范 ID（别名表的主键点查）。
        let mut q = Sel::of(self.col);
        let conflict = q.int(R_CONFLICT);
        let winner = q.int(R_WINNER);
        q.push(&format!(
            "SELECT g.ekind, g.ent, a.canon, g.c, g.n FROM \
             (SELECT ekind, ent, MAX(state = {conflict}) AS c, MAX(state != {winner}) AS n \
              FROM reg_ix WHERE col = ?1 GROUP BY ekind, ent) g \
             LEFT JOIN alias_ix a ON a.col = ?1 AND a.id = g.ent"
        ));
        let mut members: BTreeMap<(i64, Ref), usize> = BTreeMap::new();
        q.each(self.t, |r| {
            let ekind: i64 = r.get(0).map_err(sql)?;
            let ent: Ref = r.get(1).map_err(sql)?;
            let canon: Option<Ref> = r.get(2).map_err(sql)?;
            let (c, n): (bool, bool) = (r.get(3).map_err(sql)?, r.get(4).map_err(sql)?);
            if !ent_kind(ekind).is_ok_and(|k| rules.touches(k)) {
                return Ok(());
            }
            // 与 [Index::canonical] 同一个口径：只有 UUID 查别名表。
            let canon = match (&ent, canon) {
                (Ref::Uuid(_), Some(c)) => c,
                _ => ent,
            };
            if c || (renamed && n) {
                raw.push((ekind, canon.clone()));
            }
            *members.entry((ekind, canon)).or_default() += 1;
            Ok(())
        })?;
        raw.extend(
            members
                .into_iter()
                .filter(|&(_, n)| n > 1)
                .map(|(key, _)| key),
        );
        raw.extend(self.merged_key_candidates(rules)?);
        let mut out = BTreeSet::new();
        for (k, c) in raw {
            let (o, b) = sql_order(&c);
            out.insert((k, (o, b.to_vec()), c));
        }
        Ok(out)
    }

    /// [Reads::conflict_candidates] 第 3 种：同一个原值实体下两个原值键归一成同一个规范键的 (种类, 规范实体)。只扫
    /// `rules` 可能追踪嵌 ID 键族的种类，只取嵌着 ID 的键（紧凑形 tag 不是 0 的，或文本形的 `fieldDesc/`；哪些键嵌
    /// ID 只认 `alias.rs` 的 `key_ids_by`）。
    fn merged_key_candidates(&mut self, rules: &Rules) -> Result<Vec<(i64, Ref)>, String> {
        let mut out = Vec::new();
        for kind in EntKind::ALL {
            if !rules.may_track_embedded(kind) {
                continue;
            }
            let mut q = Sel::of(self.col);
            let ekind = q.int(kind as i64);
            let desc = q.bind_blob(b"fieldDesc/".to_vec());
            q.push(&format!(
                "SELECT ent, key FROM reg_ix WHERE col = ?1 AND ekind = {ekind} \
                 AND (key >= x'01' OR instr(key, {desc}) > 0) GROUP BY ent, key"
            ));
            let mut keys: Vec<(Ref, Vec<u8>)> = Vec::new();
            q.each(self.t, |r| {
                keys.push((r.get(0).map_err(sql)?, r.get(1).map_err(sql)?));
                Ok(())
            })?;
            // (原值实体, 规范键) → 有几个原值键。
            let mut seen: BTreeMap<(Ref, String), usize> = BTreeMap::new();
            for (ent, key) in keys {
                let text = key_text(&key)?;
                if !embeds_id(&text) || !rules.may_track(kind, &text) {
                    continue;
                }
                *seen
                    .entry((ent, self.ix.canonical_key(&text)?))
                    .or_default() += 1;
            }
            for ((ent, _), n) in seen {
                if n > 1 {
                    out.push((kind as i64, self.canon(&ent)?));
                }
            }
        }
        Ok(out)
    }

    /// `style_candidates {after, limit}`：笔记字段（`f/` 键）活着的写入里值带内联 `<style>` 块的，按操作主键游标取下一批
    /// （`rid` = 操作主键, `id` = 修改记录 ID, `json` = 这条写入的原值修改行）。存量样式去重的取数步。
    fn style_candidates(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        let (after, limit) = (need_int(req, "after")?, need_int(req, "limit")?);
        let limit = usize::try_from(limit.max(0)).unwrap_or(usize::MAX);
        let mut out = Table::new(&[("rid", KIND_I64), ("id", KIND_STR), ("json", KIND_STR)]);
        let mut n = 0usize;
        for k in self.edit_keys_after(after)? {
            if n >= limit {
                break;
            }
            // 先只解值（便宜），命中了再解整条。
            let Some(v) = self.t.edit_value(k)? else {
                continue;
            };
            if !v.contains("<style>") {
                continue;
            }
            let Some(e) = self.t.edit_read(k, false)? else {
                continue;
            };
            let ed = &e.head;
            if ed.kind != EntKind::Note || !ed.key.starts_with("f/") {
                continue;
            }
            if !self.is_live(EntKind::Note, &ref_of(&ed.entity.text()), &ed.key, k)? {
                continue;
            }
            let line = self
                .ix
                .edit_lines_as(&[k], &|_| true, None, &self.profile)?
                .into_iter()
                .next()
                .ok_or("gen4 read: an edit gave no line")?;
            out.push(vec![
                Cell::I(k),
                Cell::S(edit_id_of(&ed.stamp, &e.id)),
                Cell::S(line.json),
            ])?;
            n += 1;
        }
        Ok(out.encode())
    }

    /// 集合里主键大于 [after] 的修改操作的主键，升序（逐台设备按主键段取）。
    fn edit_keys_after(&self, after: i64) -> Result<Vec<i64>, String> {
        let devs: Vec<i64> = self
            .t
            .conn()
            .prepare_cached("SELECT dev FROM devs WHERE col = ?1 ORDER BY dev")
            .map_err(sql)?
            .query_map([self.col], |r| r.get(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        let mut out = Vec::new();
        for dev in devs {
            let (lo, hi) = k_range(dev);
            if hi <= after {
                continue;
            }
            let rows = self
                .t
                .conn()
                .prepare_cached(
                    "SELECT k FROM ops WHERE k > ?1 AND k <= ?2 AND kind = ?3 ORDER BY k",
                )
                .map_err(sql)?
                .query_map(params![after.max(lo - 1), hi, i64::from(KIND_EDIT)], |r| {
                    r.get::<_, i64>(0)
                })
                .map_err(sql)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(sql)?;
            out.extend(rows);
        }
        Ok(out)
    }

    /// 这条写入（主键 [k]）在它原值寄存器里活着（`reg_ix.state >= R_LIVE`）。
    fn is_live(&self, kind: EntKind, ent: &Ref, key: &str, k: i64) -> Result<bool, String> {
        let state: Option<i64> = self
            .t
            .conn()
            .prepare_cached(
                "SELECT state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND key = ?4 AND k = ?5",
            )
            .map_err(sql)?
            .query_row(
                params![self.col, kind as i64, ent, key_bytes(key), k],
                |r| r.get(0),
            )
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                e => Err(e),
            })
            .map_err(sql)?;
        Ok(state.is_some_and(|s| s >= R_LIVE))
    }

    /// 笔记字段（`f/` 键）活着的写入：(原值实体, 值的规范 JSON 文本) 交给 [f]。
    fn each_live_note_field(
        &self,
        mut f: impl FnMut(&Ref, &str) -> Result<(), String>,
    ) -> Result<(), String> {
        let mut q = Sel::of(self.col);
        let live = q.int(R_LIVE);
        q.push(&format!(
            "SELECT ent, key, k FROM reg_ix WHERE col = ?1 AND ekind = {} AND state >= {live}",
            EntKind::Note as i64
        ));
        let mut rows: Vec<(Ref, Vec<u8>, i64)> = Vec::new();
        q.each(self.t, |r| {
            rows.push((
                r.get(0).map_err(sql)?,
                r.get(1).map_err(sql)?,
                r.get(2).map_err(sql)?,
            ));
            Ok(())
        })?;
        for (ent, key, k) in rows {
            if !key_text(&key)?.starts_with("f/") {
                continue;
            }
            if let Some(v) = self.t.edit_value(k)? {
                f(&ent, &v)?;
            }
        }
        Ok(())
    }

    /// `source_note_candidates {needle}`：活着的字段（`f/` 键）写入的值里出现 `needle`（ASCII 不分大小写，同协议 3 的
    /// `LIKE`）的规范笔记 ID（去重、按 ID 排；只是候选）。
    fn source_note_candidates(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        let needle = need_str(req, "needle")?;
        let mut hits: BTreeSet<Ref> = BTreeSet::new();
        self.each_live_note_field(|ent, v| {
            if like_contains(v, needle) {
                hits.insert(ent.clone());
            }
            Ok(())
        })?;
        let mut ids: Vec<Ref> = Vec::new();
        for h in hits {
            let c = self.canon(&h)?;
            if !ids.contains(&c) {
                ids.push(c);
            }
        }
        ids.sort_by(|a, b| sql_order(a).cmp(&sql_order(b)));
        let mut out = Table::new(&[("id", KIND_STR)]);
        for c in ids {
            out.push(vec![Cell::S(c.text())])?;
        }
        Ok(out.encode())
    }

    /// `lapis_backfill {pairs, to? | notes?}`：来源键上有非空文本（两端只去空格，同 SQLite `trim`）、目标键上没有任何
    /// 活着写入的笔记（规范 ID，去重、按 ID 排）。`to` = 当前类型是它的未删除笔记（笔记缓存）；`notes` = 只在这些里找。
    /// 键按规范形比（按类判定的修改行里键是规范形）。
    fn lapis_backfill(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        let mut pairs: Vec<(String, String)> = Vec::new();
        for p in need_list(req, "pairs")?.as_array().into_iter().flatten() {
            let (Some(src), Some(dst)) = (
                p.get(0).and_then(Value::as_str),
                p.get(1).and_then(Value::as_str),
            ) else {
                continue;
            };
            pairs.push((self.ix.canonical_key(src)?, self.ix.canonical_key(dst)?));
        }
        let notes: Vec<Ref> = match list(req, "notes")? {
            Some(ids) => canon_ids(&self.ix, ids)?,
            None => {
                let to = self.canon(&ref_of(need_str(req, "to")?))?;
                let mut q = Sel::of(self.col);
                let p = q.id(&to);
                q.push(&format!(
                    "SELECT id FROM notes WHERE col = ?1 AND note_type_id = {p} AND deleted_at IS NULL"
                ));
                let mut ids = Vec::new();
                q.each(self.t, |r| {
                    ids.push(r.get::<_, Ref>(0).map_err(sql)?);
                    Ok(())
                })?;
                ids
            }
        };
        let mut hits: Vec<Ref> = Vec::new();
        for n in notes {
            let rows = self.class_rows(EntKind::Note, &n)?;
            let keys: HashSet<&str> = rows.iter().map(|r| r.0.as_str()).collect();
            let hit = pairs.iter().any(|(src, dst)| {
                !keys.contains(dst.as_str())
                    && rows.iter().filter(|r| r.0 == *src).any(|r| {
                        serde_json::from_str::<Value>(&r.1)
                            .ok()
                            .and_then(|v| v.get("v").and_then(Value::as_str).map(str::to_owned))
                            .is_some_and(|s| !s.trim_matches(' ').is_empty())
                    })
            });
            if hit && !hits.contains(&n) {
                hits.push(n);
            }
        }
        hits.sort_by(|a, b| sql_order(a).cmp(&sql_order(b)));
        let mut out = Table::new(&[("id", KIND_STR)]);
        for n in hits {
            out.push(vec![Cell::S(n.text())])?;
        }
        Ok(out.encode())
    }

    // -------------------------------------------------------------- 复习日志

    /// `logs {cards}`：一组卡（每个别名类一份）的日志（`id` 规范日志 ID, `card_id` 规范卡, `json`, `st`, `oid`）：每个规范
    /// 日志 ID 一条代表（`cache.rs` `card_logs`）。卡按 ID 序，卡内按 (发生时刻, 操作主键)。`oid` = 别名归一前的原值日志 ID
    /// （与 `id` 相同时为空，`cache.rs` `LogIn::order_id`）：同一事件的几份副本按它排序、选代表（BUG-5476），Dart 的
    /// `SrsCardHistory` 把它交给列模式选取（history.rs `select_columns`），与内核的排程、统计选同一份。
    fn logs(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        let mut cards = canon_ids(&self.ix, need_list(req, "cards")?)?;
        cards.sort_by(|a, b| sql_order(a).cmp(&sql_order(b)));
        let mut out = Table::new(&[
            ("id", KIND_STR),
            ("card_id", KIND_STR),
            ("json", KIND_STR),
            ("st", KIND_OPT_I64),
            ("oid", KIND_OPT_STR),
        ]);
        for c in cards {
            for l in self.ix.replayed_card_logs(&c)? {
                let (json, id) = row_json(&l.json, &self.profile, "id");
                out.push(vec![
                    Cell::S(id),
                    Cell::S(c.text()),
                    Cell::S(json),
                    Cell::OptI(l.server_time),
                    Cell::OptS(l.order_id),
                ])?;
            }
        }
        Ok(out.encode())
    }

    /// `anki_logs_at {at}`：Anki 导入的评分类日志里发生时刻（= Anki revlog id）落在 `at` 的那些，连同日志所在卡（规范）
    /// 此刻的笔记与可见性（卡没有缓存行时两列为空）。走 `log_at (col, at)` 索引。按 (时刻, 卡, 日志 ID) 排。
    fn anki_logs_at(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        let mut at = ints(need_list(req, "at")?, "at")?;
        at.sort_unstable();
        at.dedup();
        let mut reps = BTreeMap::new();
        for a in at {
            logs_between(self.t, &self.ix, self.col, a, Some(a), &mut reps)?;
        }
        let mut rows = Vec::new();
        for (id, (_, _, l)) in reps {
            if l.origin != "anki" || !(l.kind == "review" || l.kind == "manual") {
                continue;
            }
            let card = self.canon(&ref_of(&l.card.text()))?;
            let row: Option<(Ref, i64)> = self
                .t
                .conn()
                .prepare_cached("SELECT note_id, hidden FROM cards WHERE col = ?1 AND id = ?2")
                .map_err(sql)?
                .query_row(params![self.col, card], |r| Ok((r.get(0)?, r.get(1)?)))
                .map(Some)
                .or_else(|e| match e {
                    rusqlite::Error::QueryReturnedNoRows => Ok(None),
                    e => Err(e),
                })
                .map_err(sql)?;
            rows.push((l.at, card, id, l.rating, l.rtype, l.dur, row));
        }
        rows.sort_by(|a, b| {
            (a.0, sql_order(&a.1), sql_order(&a.2)).cmp(&(b.0, sql_order(&b.1), sql_order(&b.2)))
        });
        let mut out = Table::new(&[
            ("card_id", KIND_STR),
            ("at", KIND_I64),
            ("rating", KIND_OPT_I64),
            ("rtype", KIND_STR),
            ("dur", KIND_I64),
            ("note_id", KIND_OPT_STR),
            ("hidden", KIND_OPT_I64),
        ]);
        for (at, card, _, rating, rtype, dur, row) in rows {
            out.push(vec![
                Cell::S(card.text()),
                Cell::I(at),
                Cell::OptI(rating),
                Cell::S(rtype),
                Cell::I(dur),
                Cell::OptS(row.as_ref().map(|r| r.0.text())),
                Cell::OptI(row.map(|r| r.1)),
            ])?;
        }
        Ok(out.encode())
    }

    /// `native_logs_near {at, win}`：非 Anki 导入的评分类日志里发生时刻落在 `at` 任一值 ±`win` 毫秒内的（`id` 规范日志
    /// ID, `json`），每个规范日志 ID 一条，按 ID 排。
    fn native_logs_near(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        let at = ints(need_list(req, "at")?, "at")?;
        let win = need_int(req, "win")?;
        let mut reps = BTreeMap::new();
        for a in at {
            logs_between(
                self.t,
                &self.ix,
                self.col,
                a.saturating_sub(win),
                Some(a.saturating_add(win)),
                &mut reps,
            )?;
        }
        let mut rows: Vec<(Ref, String)> = Vec::new();
        // 日志行要的是重放写回 `res` 的那份（协议 3 落库的就是它）：按卡整段重放一次，同一张卡只算一次。
        let mut replayed: BTreeMap<Ref, Vec<(String, String)>> = BTreeMap::new();
        for (id, (_, k, l)) in reps {
            if l.origin == "anki" || !(l.kind == "review" || l.kind == "manual") {
                continue;
            }
            let card = self.canon(&ref_of(&l.card.text()))?;
            if !replayed.contains_key(&card) {
                let ls = self.ix.replayed_card_logs(&card)?;
                let ls = ls
                    .into_iter()
                    .map(|x| row_json(&x.json, &self.profile, "id"))
                    .map(|(j, i)| (i, j))
                    .collect();
                replayed.insert(card.clone(), ls);
            }
            let json = match replayed[&card].iter().find(|(i, _)| *i == id.text()) {
                Some((_, j)) => j.clone(),
                None => with_profile(&self.ix.log_at(k)?.json, &self.profile),
            };
            rows.push((id, json));
        }
        rows.sort_by(|a, b| sql_order(&a.0).cmp(&sql_order(&b.0)));
        let mut out = Table::new(&[("id", KIND_STR), ("json", KIND_STR)]);
        for (id, json) in rows {
            out.push(vec![Cell::S(id.text()), Cell::S(json)])?;
        }
        Ok(out.encode())
    }

    /// `today_reviews {from, to}`：有效复习投影里落在 `[from, to)` 的评分复习：`{n, ms, again}`。
    fn today_reviews(&mut self, req: &Value) -> Result<Value, String> {
        let (from, to) = (need_int(req, "from")?, need_int(req, "to")?);
        self.t
            .conn()
            .prepare_cached(
                "SELECT COUNT(*), COALESCE(SUM(duration_ms), 0), \
                 COALESCE(SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END), 0) \
                 FROM stats WHERE col = ?1 AND rating IS NOT NULL AND at >= ?2 AND at < ?3",
            )
            .map_err(sql)?
            .query_row(params![self.col, from, to], |r| {
                Ok(json!({
                    "n": r.get::<_, i64>(0)?,
                    "ms": r.get::<_, i64>(1)?,
                    "again": r.get::<_, i64>(2)?,
                }))
            })
            .map_err(sql)
    }

    /// `reviewed_decks {before}`：有效复习投影里在 `before` 之前评过分的卡**现在**所在的牌组（去重、升序；同协议 3
    /// `store/reads.rs`，「每日上限单位」存量牌组提醒用）。只算在 Fushi 里做的复习：从 Anki 导入的复习
    /// （[crate::store::reads::native_log_sql]）从没受过 Fushi 的每日上限，不算。
    fn reviewed_decks(&mut self, req: &Value) -> Result<Vec<String>, String> {
        let before = need_int(req, "before")?;
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(&format!(
                "SELECT DISTINCT c.deck_id FROM stats s \
                 JOIN cards c ON c.col = s.col AND c.id = s.card \
                 WHERE s.col = ?1 AND s.rating IS NOT NULL AND s.at < ?2 AND {}",
                crate::store::reads::native_log_sql("s.log")
            ))
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![self.col, before], |r| r.get::<_, Ref>(0))
            .map_err(sql)?;
        let mut decks = rows
            .map(|r| r.map(|d| d.text()))
            .collect::<Result<Vec<String>, _>>()
            .map_err(sql)?;
        decks.sort();
        decks.dedup();
        Ok(decks)
    }

    /// `review_grid {resetMs}`：评分复习按（统计日, 小时）聚合的时长（同协议 3），按 (日, 时) 排。
    fn review_grid(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        const LOCAL: &str = "(at + utc_offset_min * 60000)";
        let mut q = Sel::of(self.col);
        let reset = q.int(need_int(req, "resetMs")?);
        q.push(&format!(
            "SELECT ({LOCAL} - {reset}) / 86400000 AS d, \
             {LOCAL} / 3600000 - {LOCAL} / 86400000 * 24 AS h, \
             SUM(duration_ms), MAX(at) FROM stats \
             WHERE col = ?1 AND rating IS NOT NULL \
             GROUP BY d, h HAVING SUM(duration_ms) > 0 ORDER BY d, h"
        ));
        q.table(
            self.t,
            &[
                ("day", KIND_I64),
                ("hour", KIND_I64),
                ("ms", KIND_I64),
                ("last", KIND_I64),
            ],
        )
    }

    /// 修改操作的 (修改记录 ID, 服务器时刻) 交给 [f]：`reg_ix` 里 [min_state] 及以上的写入（含按类不再活着的；修改记录
    /// ID 是原值的）。不带旧戳的只看信封、不解操作体。
    fn each_edit_id(
        &self,
        min_state: i64,
        mut f: impl FnMut(String, Option<i64>) -> Result<(), String>,
    ) -> Result<(), String> {
        let mut q = Sel::of(self.col);
        let s = q.int(min_state);
        q.push(&format!(
            "SELECT DISTINCT k FROM reg_ix WHERE col = ?1 AND state >= {s} ORDER BY k"
        ));
        let mut ks: Vec<i64> = Vec::new();
        q.each(self.t, |r| {
            ks.push(r.get(0).map_err(sql)?);
            Ok(())
        })?;
        for k in ks {
            let Some(h) = self.t.head_by_key(k)? else {
                continue;
            };
            if !h.stamped && !h.raw {
                f(
                    crate::registers::edit_id(&h.id.device.text(), h.id.seq as i64),
                    None,
                )?;
                continue;
            }
            if let Some(e) = self.t.edit_read(k, false)? {
                let st = e.head.stamp.as_ref().and_then(|s| s.server_time);
                f(edit_id_of(&e.head.stamp, &e.id), st)?;
            }
        }
        Ok(())
    }

    /// `server_times {ids?}`：事件的服务器时刻（`id`, `st`；没有时刻的不出现），按 ID 的 SQLite 序。只有承袭来的事件有
    /// 时刻（模块文件头）。日志的时刻是规范日志 ID 的代表那份的；修改记录按原值修改记录 ID（修改记录 ID 没有别名）。
    ///
    /// **回包里的 ID**（调用方按它对回去）：
    ///
    /// - 没给 `ids`（profile 并入一次取全部）：日志是规范日志 ID、修改记录是原值修改记录 ID——与同一集合的 `logs` /
    ///   `edits` / `events` 读出来的 ID 同一个口径，调用方拿那几条读出的 ID 直接查这张表。
    /// - 给了 `ids`：**原样回请求里的那个 ID**（小写带连字符的 UUID 文本才当 UUID，同协议 3），每个请求 ID 至多一行。请求给的
    ///   是日志别名类里的某个成员时，按它的规范日志 ID 取时刻、回包仍写成员本身；同一个类的几个成员都问了，就各回一行。
    ///   调用方因此不用知道别名：问什么、对什么。
    fn server_times(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        // 请求的 ID（规整后的文本 → (原值, 规范)）。
        let asked: Option<Vec<(Ref, Ref)>> = match list(req, "ids")? {
            None => None,
            Some(ids) => {
                let mut seen: HashSet<Ref> = HashSet::new();
                let mut out = Vec::new();
                for x in ids.as_array().into_iter().flatten() {
                    let s = x.as_str().ok_or("read server_times: ids must be strings")?;
                    let r = ref_of(s);
                    if seen.insert(r.clone()) {
                        let c = self.canon(&r)?;
                        out.push((r, c));
                    }
                }
                Some(out)
            }
        };
        let canon_wanted: Option<HashSet<Ref>> = asked
            .as_ref()
            .map(|a| a.iter().map(|(_, c)| c.clone()).collect());
        let raw_wanted: Option<HashSet<Ref>> = asked
            .as_ref()
            .map(|a| a.iter().map(|(r, _)| r.clone()).collect());
        // 日志：每个规范日志 ID 的代表（操作号最小的那份）。
        let mut reps: BTreeMap<Ref, (OpId, Option<i64>)> = BTreeMap::new();
        {
            let mut q = Sel::of(self.col);
            q.push("SELECT k, id FROM log_ix WHERE col = ?1 AND win = 1");
            let mut rows: Vec<(i64, Ref)> = Vec::new();
            q.each(self.t, |r| {
                rows.push((r.get(0).map_err(sql)?, r.get(1).map_err(sql)?));
                Ok(())
            })?;
            for (k, id) in rows {
                let c = self.canon(&id)?;
                if canon_wanted.as_ref().is_some_and(|w| !w.contains(&c)) {
                    continue;
                }
                let op = self.t.id_of_key(k)?;
                if reps.get(&c).is_some_and(|(o, _)| *o <= op) {
                    continue;
                }
                let st = match self.t.entry_by_key(k)?.as_ref().and_then(body_of) {
                    Some(Body4::Log(l)) => l.server_time,
                    _ => None,
                };
                reps.insert(c, (op, st));
            }
        }
        let logs: BTreeMap<Ref, i64> = reps
            .into_iter()
            .filter_map(|(c, (_, st))| st.map(|st| (c, st)))
            .collect();
        // 修改记录（原值 ID）。
        let mut edits: BTreeMap<Ref, i64> = BTreeMap::new();
        self.each_edit_id(0, |id, st| {
            let r = ref_of(&id);
            if let Some(st) = st {
                if raw_wanted.as_ref().is_none_or(|w| w.contains(&r)) {
                    edits.entry(r).or_insert(st);
                }
            }
            Ok(())
        })?;
        let mut times: BTreeMap<(u8, Vec<u8>), (Ref, i64)> = BTreeMap::new();
        let mut put = |id: Ref, st: i64| {
            let (o, b) = sql_order(&id);
            times.entry((o, b.to_vec())).or_insert((id, st));
        };
        match asked {
            None => {
                for (c, st) in logs {
                    put(c, st);
                }
                for (r, st) in edits {
                    put(r, st);
                }
            }
            Some(asked) => {
                for (r, c) in asked {
                    if let Some(st) = logs.get(&c).or_else(|| edits.get(&r)) {
                        put(r, *st);
                    }
                }
            }
        }
        let mut out = Table::new(&[("id", KIND_STR), ("st", KIND_I64)]);
        for (_, (id, st)) in times {
            out.push(vec![Cell::S(id.text()), Cell::I(st)])?;
        }
        Ok(out.encode())
    }

    // -------------------------------------------------------------- 缓存行

    /// `cards {fields?, ids?, notes?, decks?, templates?, visibleOnly?, queue?, studyableOn?, ordered?}`：卡片缓存行（列见
    /// `bulk::CARD_COLUMNS`）。筛选同协议 3；ID 参数先归一。按 ID 排（`ordered` 因此总成立）。
    ///
    /// **计划**：给了的 ID 列表里按 `ids` > `notes` > `decks` > `templates` 取第一个当外层（`CROSS JOIN` 定死连接顺序：
    /// 先展开列表、再按 `cards` / `cards_note` / `cards_deck` / `cards_template` 逐个按键取），其余列表只当过滤条件。
    /// 以前四个列表都写成 `col IN (SELECT … FROM json_each(?))`：规划器把 `json_each` 估成 25 行，`cards_deck` /
    /// `cards_template` 的统计又是「一个牌组 / 模板约 5000 张」，25 × 5000 大于整集合的 10 万行，于是 `cards {decks}`
    /// / `cards {templates}` 选了整集合扫描。按列表逐个按键取的代价只与命中的行数有关（再加一次按 ID 排序），所以
    /// 连接顺序直接写死，不交给按统计的估算（统计只表达形状，估不出这次请求的列表有多长、命中多少）。
    fn cards(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        let cols = pick(&bulk::CARD_COLUMNS, req, "cards")?;
        let mut q = Sel::of(self.col);
        let names = cols
            .iter()
            .map(|(n, _)| format!("c.{n}"))
            .collect::<Vec<_>>()
            .join(", ");
        let mut filters: Vec<(&str, Vec<Ref>)> = Vec::new();
        for (k, col) in [
            ("ids", "id"),
            ("notes", "note_id"),
            ("decks", "deck_id"),
            ("templates", "template_id"),
        ] {
            if let Some(v) = list(req, k)? {
                filters.push((col, canon_ids(&self.ix, v)?));
            }
        }
        let mut filters = filters.into_iter();
        match filters.next() {
            Some((col, ids)) => {
                let sub = q.ids(&ids);
                q.push(&format!(
                    "SELECT {names} FROM {sub} AS want CROSS JOIN cards c \
                     ON c.col = ?1 AND c.{col} = want.v WHERE 1"
                ));
            }
            None => q.push(&format!("SELECT {names} FROM cards c WHERE c.col = ?1")),
        }
        for (col, ids) in filters {
            let sub = q.ids(&ids);
            q.push(&format!(" AND c.{col} IN {sub}"));
        }
        if flag(req, "visibleOnly") {
            q.push(" AND c.hidden = 0");
        }
        if let Some(queue) = opt_str(req, "queue") {
            let p = q.text(queue);
            q.push(&format!(" AND c.queue = {p}"));
        }
        if let Some(today) = opt_int(req, "studyableOn") {
            let p = q.int(today);
            q.push(&format!(
                " AND c.suspended = 0 AND c.scheduler = 'fushi' \
                 AND (c.buried_until_day IS NULL OR c.buried_until_day <= {p})"
            ));
        }
        q.push(" ORDER BY c.id");
        q.table(self.t, &cols)
    }

    /// `notes {fields?, ids?, typeId?, termKey?, alive?, pending?, order?, limit?, offset?}`：笔记缓存行（列同协议 3）。
    /// 没给 `order` 时按 ID 排；给了按创建时刻，平局再按 ID（协议 3 平局无序）。
    fn notes(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        let cols = pick(&NOTE_COLUMNS, req, "notes")?;
        let mut q = Sel::of(self.col);
        q.push(&format!(
            "SELECT {} FROM notes WHERE col = ?1",
            cols.iter().map(|(n, _)| *n).collect::<Vec<_>>().join(", ")
        ));
        if let Some(v) = list(req, "ids")? {
            let ids = canon_ids(&self.ix, v)?;
            let sub = q.ids(&ids);
            q.push(&format!(" AND id IN {sub}"));
        }
        if let Some(t) = opt_str(req, "typeId") {
            let c = self.canon(&ref_of(t))?;
            let p = q.id(&c);
            q.push(&format!(" AND note_type_id = {p}"));
        }
        if let Some(k) = opt_str(req, "termKey") {
            let p = q.text(k);
            q.push(&format!(" AND term_key = {p}"));
        }
        if flag(req, "alive") {
            q.push(" AND deleted_at IS NULL");
        }
        if flag(req, "pending") {
            q.push(" AND pending_decision = 1");
        }
        match opt_str(req, "order") {
            None => q.push(" ORDER BY id"),
            Some("created_asc") => q.push(" ORDER BY created_at, id"),
            Some("created_desc") => q.push(" ORDER BY created_at DESC, id"),
            Some(other) => return Err(format!("read notes: unknown order {other}")),
        }
        if let Some(limit) = opt_int(req, "limit") {
            let (l, o) = (q.int(limit), q.int(opt_int(req, "offset").unwrap_or(0)));
            q.push(&format!(" LIMIT {l} OFFSET {o}"));
        }
        q.table(self.t, &cols)
    }

    /// `note_type_counts`：每个笔记类型的未删除笔记数（`t`, `c`），按类型 ID 排。
    fn note_type_counts(&mut self) -> Result<Vec<u8>, String> {
        let mut q = Sel::of(self.col);
        q.push(
            "SELECT note_type_id, COUNT(*) FROM notes WHERE col = ?1 AND deleted_at IS NULL \
             GROUP BY note_type_id ORDER BY note_type_id",
        );
        q.table(self.t, &[("t", KIND_STR), ("c", KIND_I64)])
    }

    /// `pending_notes`：待裁决笔记数。
    fn pending_notes(&mut self) -> Result<i64, String> {
        let mut q = Sel::of(self.col);
        q.push("SELECT COUNT(*) FROM notes WHERE col = ?1 AND pending_decision = 1");
        q.scalar(self.t)
    }

    /// `media_refs {deletedBefore? | deletedAfter?}`：非空的媒体引用列（`refs`），口径同协议 3，按笔记 ID 排。
    fn media_refs(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        let mut q = Sel::of(self.col);
        q.push("SELECT media_refs FROM notes WHERE col = ?1 AND ");
        match (opt_int(req, "deletedBefore"), opt_int(req, "deletedAfter")) {
            (Some(before), None) => {
                let p = q.int(before);
                q.push(&format!("deleted_at <= {p}"));
            }
            (None, Some(after)) => {
                let p = q.int(after);
                q.push(&format!("(deleted_at IS NULL OR deleted_at > {p})"));
            }
            (None, None) => q.push("deleted_at IS NULL"),
            _ => {
                return Err("read media_refs: deletedBefore and deletedAfter are exclusive".into());
            }
        }
        q.push(" AND media_refs <> '' ORDER BY id");
        q.table(self.t, &[("refs", KIND_STR)])
    }

    /// `term_status {terms}`：词条键在 `terms` 里的未删除笔记的可见卡（查词热路径：走 `notes_term (col, term_key)`，
    /// 卡走 `cards_note`），按 (词条键, 读音键, 卡 ID) 排。
    fn term_status(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        let mut q = Sel::of(self.col);
        let terms = q.text(&need_list(req, "terms")?.to_string());
        q.push(&format!(
            "SELECT n.term_key, n.reading_key, c.id, c.note_id, c.queue, c.suspended, \
             c.deck_id, c.due_day, c.due_at \
             FROM notes n CROSS JOIN cards c ON c.col = n.col AND c.note_id = n.id \
             WHERE n.col = ?1 AND n.term_key IN (SELECT value FROM json_each({terms})) \
             AND n.deleted_at IS NULL AND c.hidden = 0 \
             ORDER BY n.term_key, n.reading_key, c.id"
        ));
        q.table(
            self.t,
            &[
                ("term_key", KIND_STR),
                ("reading_key", KIND_STR),
                ("id", KIND_STR),
                ("note_id", KIND_STR),
                ("queue", KIND_STR),
                ("suspended", KIND_I64),
                ("deck_id", KIND_STR),
                ("due_day", KIND_OPT_I64),
                ("due_at", KIND_OPT_I64),
            ],
        )
    }

    /// `dup_groups`：同类型、同词条键、同读音键的未删除笔记有两条以上的那些笔记（列同协议 3），按笔记 ID 排。
    fn dup_groups(&mut self) -> Result<Vec<u8>, String> {
        let mut q = Sel::of(self.col);
        q.push(
            "SELECT n.id, n.note_type_id, n.term_key, n.reading_key, n.created_at, n.sort_field, \
             (SELECT COALESCE(SUM(x.reps), 0) FROM cards x WHERE x.col = ?1 AND x.note_id = n.id) \
             FROM notes n JOIN (\
             SELECT note_type_id, term_key, reading_key FROM notes \
             WHERE col = ?1 AND deleted_at IS NULL AND term_key != '' \
             GROUP BY note_type_id, term_key, reading_key HAVING COUNT(*) > 1\
             ) g ON g.note_type_id = n.note_type_id AND g.term_key = n.term_key \
             AND g.reading_key = n.reading_key \
             WHERE n.col = ?1 AND n.deleted_at IS NULL ORDER BY n.id",
        );
        q.table(
            self.t,
            &[
                ("id", KIND_STR),
                ("t", KIND_STR),
                ("k", KIND_STR),
                ("r", KIND_STR),
                ("c", KIND_I64),
                ("s", KIND_STR),
                ("reps", KIND_I64),
            ],
        )
    }

    // -------------------------------------------------------------- 整份事件

    /// `events {parts?, ordered?}`：集合的全部事件原文，四张表：`entities`（`id`, `kind`, `payload_json`）、`edits` /
    /// `logs` / `unknown`（各一列 `json`）。`parts` 限定要哪几张。一律确定顺序：身份记录与日志按 ID，修改按 (实体, 键,
    /// JSON)，不认识的按操作主键。
    fn events(&mut self, req: &Value, files: &mut Files) -> Result<Value, String> {
        let parts = list(req, "parts")?;
        let wanted = |name: &str| match parts {
            None => true,
            Some(p) => p
                .as_array()
                .is_some_and(|xs| xs.iter().any(|x| x.as_str() == Some(name))),
        };
        if wanted("entities") {
            files.push((
                "entities".to_owned(),
                self.entities(&json!({"ordered": true}))?.0,
            ));
        }
        if wanted("edits") {
            let mut out = Table::new(&[("json", KIND_STR)]);
            for (kind, c) in self.edited_classes()? {
                for (_, j, _) in self.class_rows(kind, &c)? {
                    out.push(vec![Cell::S(j)])?;
                }
            }
            files.push(("edits".to_owned(), out.encode()));
        }
        if wanted("logs") {
            let mut rows: Vec<(Ref, String)> = Vec::new();
            for c in self.logged_cards()? {
                for l in self.ix.replayed_card_logs(&c)? {
                    let (json, id) = row_json(&l.json, &self.profile, "id");
                    rows.push((ref_of(&id), json));
                }
            }
            rows.sort_by(|a, b| sql_order(&a.0).cmp(&sql_order(&b.0)));
            let mut out = Table::new(&[("json", KIND_STR)]);
            for (_, json) in rows {
                out.push(vec![Cell::S(json)])?;
            }
            files.push(("logs".to_owned(), out.encode()));
        }
        if wanted("unknown") {
            let mut out = Table::new(&[("json", KIND_STR)]);
            for json in self.unknown_ops(None)? {
                out.push(vec![Cell::S(json)])?;
            }
            files.push(("unknown".to_owned(), out.encode()));
        }
        Ok(json!({}))
    }

    /// 有写入的 (种类, 规范实体)，按 (实体的 SQLite 序, 种类)。
    fn edited_classes(&self) -> Result<Vec<(EntKind, Ref)>, String> {
        let mut q = Sel::of(self.col);
        q.push("SELECT DISTINCT ekind, ent FROM reg_ix WHERE col = ?1");
        let mut raw: Vec<(i64, Ref)> = Vec::new();
        q.each(self.t, |r| {
            raw.push((r.get(0).map_err(sql)?, r.get(1).map_err(sql)?));
            Ok(())
        })?;
        let mut set: BTreeSet<((u8, Vec<u8>), i64, Ref)> = BTreeSet::new();
        for (k, ent) in raw {
            let c = self.canon(&ent)?;
            let (o, b) = sql_order(&c);
            set.insert(((o, b.to_vec()), k, c));
        }
        set.into_iter()
            .map(|(_, k, c)| Ok((ent_kind(k)?, c)))
            .collect()
    }

    /// 有日志的规范卡。
    fn logged_cards(&self) -> Result<BTreeSet<Ref>, String> {
        let mut q = Sel::of(self.col);
        q.push("SELECT DISTINCT card FROM log_ix WHERE col = ?1");
        let mut out = BTreeSet::new();
        q.each(self.t, |r| {
            out.insert(self.canon(&r.get::<_, Ref>(0).map_err(sql)?)?);
            Ok(())
        })?;
        Ok(out)
    }

    /// `events_present {ids, ops?}`：`ids` 里已在这个集合里的事件 ID（按请求的顺序，每个一次）。身份记录与日志按别名类
    /// 认；修改记录按原值修改记录 ID 认——不带 `ops` 只认活着的写入（协议 3 投影里的行），带 `ops` 连被支配、被清除的
    /// 也认（协议 3 连操作索引一起看）；不认识的事件按 `x.id`。
    fn events_present(&mut self, req: &Value) -> Result<Vec<u8>, String> {
        let asked: Vec<String> = need_list(req, "ids")?
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect();
        let mut present: HashSet<String> = HashSet::new();
        let mut rest: HashSet<Ref> = HashSet::new();
        for a in &asked {
            let r = ref_of(a);
            if self.class_in(&r, "SELECT 1 FROM ent_ix WHERE col = ?1 AND id = ?2")?
                || self.class_in(&r, "SELECT 1 FROM log_ix WHERE col = ?1 AND id = ?2")?
            {
                present.insert(a.clone());
            } else {
                rest.insert(r);
            }
        }
        if !rest.is_empty() {
            let min = if flag(req, "ops") { S_PURGED } else { R_LIVE };
            let mut found: Vec<Ref> = Vec::new();
            self.each_edit_id(min, |id, _| {
                let r = ref_of(&id);
                if rest.contains(&r) {
                    found.push(r);
                }
                Ok(())
            })?;
            for json in self.unknown_ops(None)? {
                let v: Value = serde_json::from_str(&json).unwrap_or(Value::Null);
                let id = v["x"]["id"]
                    .as_str()
                    .map_or_else(|| json.clone(), str::to_owned);
                let r = ref_of(&id);
                if rest.contains(&r) {
                    found.push(r);
                }
            }
            for r in found {
                present.insert(r.text());
            }
        }
        let mut out = Table::new(&[("id", KIND_STR)]);
        let mut done: HashSet<&str> = HashSet::new();
        for a in &asked {
            let t = ref_of(a).text();
            if (present.contains(a) || present.contains(&t)) && done.insert(a.as_str()) {
                out.push(vec![Cell::S(t)])?;
            }
        }
        Ok(out.encode())
    }

    /// [r] 的别名类里有没有成员命中 [q]（`?1` 集合号, `?2` 成员）。
    fn class_in(&self, r: &Ref, q: &str) -> Result<bool, String> {
        let mut stmt = self.t.conn().prepare_cached(q).map_err(sql)?;
        for m in self.ix.members(r)?.into_iter().chain([r.clone()]) {
            if stmt.exists(params![self.col, m]).map_err(sql)? {
                return Ok(true);
            }
        }
        Ok(false)
    }
}

/// 笔记缓存的列（`notes` 默认交回全部；同协议 3 `store/reads.rs`）。
const NOTE_COLUMNS: [(&str, u32); 13] = [
    ("id", KIND_STR),
    ("note_type_id", KIND_STR),
    ("guid", KIND_STR),
    ("created_at", KIND_I64),
    ("deck_id", KIND_OPT_STR),
    ("deleted_at", KIND_OPT_I64),
    ("term_key", KIND_STR),
    ("reading_key", KIND_STR),
    ("sort_field", KIND_STR),
    ("tags_json", KIND_STR),
    ("pending_decision", KIND_I64),
    ("updated_at", KIND_I64),
    ("media_refs", KIND_STR),
];

/// `conflict_edits` 的字段类别规则（协议 3 `class_filter` 的同一份语义）：每项 `{kind, keep: [键…]}`（只要这些键）或
/// `{kind, drop: [键…]}`（除这些键以外都要）。键先归一，与按类判定的修改行里的规范键比。
pub(super) struct Rules(Vec<(String, bool, HashSet<String>)>);

impl Rules {
    pub(super) fn parse(ix: &Index<'_, '_>, rules: &Value) -> Result<Rules, String> {
        let mut out = Vec::new();
        for rule in rules.as_array().ok_or("read: rules must be an array")? {
            let kind = need_str(rule, "kind").map_err(|_| "read: rule without kind")?;
            let keys = |v: &Value| -> Result<HashSet<String>, String> {
                v.as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .map(|k| ix.canonical_key(k))
                    .collect()
            };
            match (rule.get("keep"), rule.get("drop")) {
                (Some(keep), None) => out.push((kind.to_owned(), true, keys(keep)?)),
                (None, Some(drop)) => out.push((kind.to_owned(), false, keys(drop)?)),
                _ => return Err("read: rule needs exactly one of keep / drop".into()),
            }
        }
        Ok(Rules(out))
    }

    fn touches(&self, kind: EntKind) -> bool {
        self.0.iter().any(|(k, _, _)| k == kind.wire())
    }

    /// 原值键 [raw]（还没归一）归一之后可能被 [Rules::tracks] 留下吗：键里不嵌 ID 时归一不变，照规范键判；嵌着 ID
    /// 的按键族（ID 之前那段）判——`keep` 里有同族的键才可能，`drop` 一律可能（归一后才知道是不是被丢的那个）。
    /// 只用来在归一（查别名表）与读操作体之前粗筛，结论不能比 [Rules::tracks] 严。
    fn may_track(&self, kind: EntKind, raw: &str) -> bool {
        let family = embedded_family(raw);
        self.0.iter().any(|(k, keep, keys)| {
            k == kind.wire()
                && match (family, *keep) {
                    (None, true) => keys.contains(raw),
                    (None, false) => !keys.contains(raw),
                    (Some(f), true) => keys.iter().any(|x| embedded_family(x) == Some(f)),
                    (Some(_), false) => true,
                }
        })
    }

    /// 这种实体有没有可能追踪嵌 ID 的键（[Reads::merged_key_candidates] 要不要扫它）。
    fn may_track_embedded(&self, kind: EntKind) -> bool {
        self.0.iter().any(|(k, keep, keys)| {
            k == kind.wire() && (!*keep || keys.iter().any(|x| embeds_id(x)))
        })
    }

    pub(super) fn tracks(&self, kind: EntKind, key: &str) -> bool {
        self.0.iter().any(|(k, keep, keys)| {
            k == kind.wire()
                && if *keep {
                    keys.contains(key)
                } else {
                    !keys.contains(key)
                }
        })
    }
}

/// 修改键里嵌着 ID 吗（`alias.rs` `key_ids_by` 会换掉它的那些键）。
fn embeds_id(key: &str) -> bool {
    let hit = Flag::new(false);
    let _ = key_ids_by(key, &|s| {
        hit.set(true);
        Ok(s.to_owned())
    });
    hit.get()
}

/// 嵌着 ID 的修改键的键族：ID 之前那段（`f/`、`historyFrom/`、`fieldDesc/` …，ID 恒在末尾、36 个字符）；不嵌 ID = None。
fn embedded_family(key: &str) -> Option<&str> {
    if !embeds_id(key) {
        return None;
    }
    key.get(..key.len().checked_sub(36)?)
}
