//! 只读查询命令：`read`（一个 profile 的数据）与 `read_lib`（不针对单个 profile）。
//!
//! 以前这些读经 Drift 执行器：Dart 拼 SQL 文本交给内核执行（`ffsrs_store_exec` mode 2 / 3），srs.db 的表结构、索引
//! 选择与 ID 列的编码因此有两处在写。现在 SQL 只在这里：Dart 发 `{op: "read", q: <查询名>, …参数}`，内核在查询道的
//! 只读连接上（[super::SrsCore::read_query]：一条命令一个读事务，不排写锁）跑完，按列编码（store/bulk.rs 的 `FCL1`）
//! 放进结果的 `files` 交回；只有一两个数的结果直接放回包 JSON。
//!
//! 约定：
//!
//! - **profile 归属**：`read` 的每条查询都带 `profile_uid = srs_id(profile)`。按 ID 取时别的 profile 名下的 ID 读出来
//!   就是「不存在」（空结果），不会把另一个 profile 的行交出去。按 ID / 外键定位的查询把条件写成 `+profile_uid`
//!   （一元加号）：只当过滤条件，不让规划器因为它改挑 profile 前缀的索引去扫整个 profile。
//! - **ID 列表**：请求里是 JSON 数组，SQL 里 `IN (SELECT srs_id(value) FROM json_each(?))`，不分块、不受变量数上限
//!   限制。
//! - **不收通道**：`read` 登记在 `CHANNEL_TRANSPARENT`（store/ffi.rs）。新设备收段途中读到的投影不全，与以前 Drift
//!   读到的一样，收尾后一致。
//! - 结果表的列名就是下面各函数里写的名字；Dart 侧的读法在 packages/fushi_engine/lib/srs/srs_reads.dart。
use rusqlite::Connection;
use rusqlite::types::Value as Sv;
use serde_json::{Value, json};

use super::bulk::{self, KIND_I64, KIND_OPT_I64, KIND_OPT_STR, KIND_STR};
use super::sync2::sql;

type Files = Vec<(String, Vec<u8>)>;

/// 单表结果在 `files` 里的名字。
const TABLE: &str = "t";

/// 一条查询：SQL 文本 + 按序号绑定的参数（`?1` 起）。
struct Sel {
    sql: String,
    args: Vec<Sv>,
}

impl Sel {
    /// `?1` = profile uid。
    fn of(profile: &str) -> Sel {
        Sel {
            sql: String::new(),
            args: vec![Sv::Text(profile.to_owned())],
        }
    }

    fn lib() -> Sel {
        Sel {
            sql: String::new(),
            args: Vec::new(),
        }
    }

    /// 绑一个参数，返回它的占位符（`?N`）。
    fn bind(&mut self, v: Sv) -> String {
        self.args.push(v);
        format!("?{}", self.args.len())
    }

    fn text(&mut self, s: &str) -> String {
        self.bind(Sv::Text(s.to_owned()))
    }

    fn int(&mut self, n: i64) -> String {
        self.bind(Sv::Integer(n))
    }

    fn push(&mut self, s: &str) {
        self.sql.push_str(s);
    }

    /// 追加 ` AND <col> IN (<ids>)`（[ids] 是 ID 文本的 JSON 数组）。
    fn and_id_in(&mut self, col: &str, ids: &Value) {
        let p = self.text(&ids.to_string());
        self.sql.push_str(&format!(
            " AND {col} IN (SELECT srs_id(value) FROM json_each({p}))"
        ));
    }

    fn params(&self) -> Vec<&dyn rusqlite::ToSql> {
        self.args
            .iter()
            .map(|a| a as &dyn rusqlite::ToSql)
            .collect()
    }

    /// 跑完编码成一张列式表。[cols]：(结果列名, 类型)，与 SELECT 的列一一对应。
    fn table(&self, c: &Connection, cols: &[(&str, u32)]) -> Result<Vec<u8>, String> {
        let names: Vec<&str> = cols.iter().map(|(n, _)| *n).collect();
        let kinds: Vec<u32> = cols.iter().map(|(_, k)| *k).collect();
        let (rows, data) = bulk::read_cols(c, &self.sql, &self.params(), &kinds)?;
        Ok(bulk::encode(rows, &names, &data))
    }

    /// 只有一行一列整数的查询。
    fn scalar(&self, c: &Connection) -> Result<i64, String> {
        c.prepare_cached(&self.sql)
            .map_err(sql)?
            .query_row(self.params().as_slice(), |r| r.get(0))
            .map_err(sql)
    }
}

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

/// `read`：本 profile 的一条只读查询（请求的 `q` 是查询名）。
pub(crate) fn run(
    c: &Connection,
    profile: &str,
    req: &Value,
    files: &mut Files,
) -> Result<Value, String> {
    let q = need_str(req, "q")?;
    Ok(match q {
        "entities" => single(files, entities(c, profile, req)?),
        "entity_count" => json!({"n": entity_count(c, profile, req)?}),
        "has_user_data" => json!({"any": has_user_data(c, profile, req)?}),
        "edits" => single(files, edits(c, profile, req)?),
        "successors" => single(files, successors(c, profile)?),
        "conflict_edits" => single(files, conflict_edits(c, profile, req)?),
        "style_candidates" => single(files, style_candidates(c, profile, req)?),
        "source_note_candidates" => single(files, source_note_candidates(c, profile, req)?),
        "lapis_backfill" => single(files, lapis_backfill(c, profile, req)?),
        "logs" => single(files, logs(c, profile, req)?),
        "anki_logs_at" => single(files, anki_logs_at(c, profile, req)?),
        "today_reviews" => today_reviews(c, profile, req)?,
        "review_grid" => single(files, review_grid(c, profile, req)?),
        "server_times" => single(files, server_times(c, profile, req)?),
        "cards" => single(files, cards(c, profile, req)?),
        "notes" => single(files, notes(c, profile, req)?),
        "note_type_counts" => single(files, note_type_counts(c, profile)?),
        "pending_notes" => json!({"n": pending_notes(c, profile)?}),
        "media_refs" => single(files, media_refs(c, profile, req)?),
        "term_status" => single(files, term_status(c, profile, req)?),
        "dup_groups" => single(files, dup_groups(c, profile)?),
        "events" => events(c, profile, req, files)?,
        "events_present" => single(files, events_present(c, profile, req)?),
        other => return Err(format!("read: unknown query {other}")),
    })
}

/// `read_lib`：不针对单个 profile 的只读查询。
pub(crate) fn run_lib(c: &Connection, req: &Value, files: &mut Files) -> Result<Value, String> {
    let q = need_str(req, "q")?;
    Ok(match q {
        "profile_merges" => single(files, profile_merges(c)?),
        "user_note_count" => json!({"n": user_note_count(c)?}),
        "entity_owners" => single(files, entity_owners(c)?),
        other => return Err(format!("read_lib: unknown query {other}")),
    })
}

// ------------------------------------------------------------------ 身份记录

/// `entities {kind?, ids?, bare?, ordered?}`：身份记录（`id`, `kind`, `payload_json`；`bare` = 只要 `id`）。
/// `ids` 给了按 ID 取（不存在 / 不属于本 profile 的不出现）；`ordered` = 按 ID 升序。
fn entities(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let ids = list(req, "ids")?;
    let cols: &[(&str, u32)] = if flag(req, "bare") {
        &[("id", KIND_STR)]
    } else {
        &[
            ("id", KIND_STR),
            ("kind", KIND_STR),
            ("payload_json", KIND_STR),
        ]
    };
    let mut q = Sel::of(profile);
    q.push(&format!(
        "SELECT {} FROM srs_entities WHERE {}profile_uid = srs_id(?1)",
        cols.iter().map(|(n, _)| *n).collect::<Vec<_>>().join(", "),
        if ids.is_some() { "+" } else { "" }
    ));
    if let Some(kind) = opt_str(req, "kind") {
        let p = q.text(kind);
        q.push(&format!(" AND kind = {p}"));
    }
    if let Some(ids) = ids {
        q.and_id_in("id", ids);
    }
    if flag(req, "ordered") {
        q.push(" ORDER BY id");
    }
    q.table(c, cols)
}

/// `entity_count {kind?, limit?}`：身份记录条数（`limit` 给了最多数到它：只问「有没有」时传 1）。
fn entity_count(c: &Connection, profile: &str, req: &Value) -> Result<i64, String> {
    let mut q = Sel::of(profile);
    q.push("SELECT COUNT(*) FROM (SELECT 1 FROM srs_entities WHERE profile_uid = srs_id(?1)");
    if let Some(kind) = opt_str(req, "kind") {
        let p = q.text(kind);
        q.push(&format!(" AND kind = {p}"));
    }
    if let Some(limit) = opt_int(req, "limit") {
        let p = q.int(limit);
        q.push(&format!(" LIMIT {p}"));
    }
    q.push(")");
    q.scalar(c)
}

/// `has_user_data {builtins}`：本 profile 有没有 `builtins`（内置实体的 ID）之外的数据——别的身份记录，或任何
/// 修改记录 / 复习日志 / 不认识的事件。
fn has_user_data(c: &Connection, profile: &str, req: &Value) -> Result<bool, String> {
    let mut q = Sel::of(profile);
    let builtins = q.text(&need_list(req, "builtins")?.to_string());
    q.push(&format!(
        "SELECT EXISTS (SELECT 1 FROM srs_entities WHERE profile_uid = srs_id(?1) \
         AND id NOT IN (SELECT srs_id(value) FROM json_each({builtins}))) \
         OR EXISTS (SELECT 1 FROM srs_field_edits WHERE profile_uid = srs_id(?1)) \
         OR EXISTS (SELECT 1 FROM srs_review_logs WHERE profile_uid = srs_id(?1)) \
         OR EXISTS (SELECT 1 FROM srs_unknown_events WHERE profile_uid = srs_id(?1))"
    ));
    Ok(q.scalar(c)? != 0)
}

// ------------------------------------------------------------------ 修改记录

const EDIT_COLS: [(&str, u32); 3] = [("e", KIND_STR), ("j", KIND_STR), ("st", KIND_OPT_I64)];

/// `edits {kind, ids, key? | prefix?}`：一组实体的修改记录原文（canonical JSON）+ 服务器时刻（`e` 实体 ID, `j`, `st`）。
/// `key` = 只要这一个字段键；`prefix` = 只要以它开头的字段键（落在
/// `idx_srs_field_edits_profile_register (profile_uid, entity_kind, entity_id, field_key)` 的一段上，BUG-4187）。
///
/// 没给 `prefix` 时同一实体的记录按落库顺序（rowid）回来：物化按记录的先后建字段表，字段的顺序就是它（以前 Drift 那句
/// 不带 profile 条件、走 `idx_srs_field_edits_entity (entity_kind, entity_id)`，顺序是这个索引的顺序）。归属条件写成
/// `+f.profile_uid`，规划器仍走那个索引，`ORDER BY` 不另排序。
fn edits(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(profile);
    let kind = q.text(need_str(req, "kind")?);
    let prefix = opt_str(req, "prefix");
    q.push(&format!(
        "SELECT f.entity_id, f.json, s.server_time FROM srs_field_edits f \
         LEFT JOIN srs_event_local s ON s.event_id = f.id \
         WHERE {}f.profile_uid = srs_id(?1) AND f.entity_kind = {kind}",
        if prefix.is_none() { "+" } else { "" }
    ));
    q.and_id_in("f.entity_id", need_list(req, "ids")?);
    if let Some(key) = opt_str(req, "key") {
        let p = q.text(key);
        q.push(&format!(" AND f.field_key = {p}"));
    }
    if let Some(prefix) = prefix {
        // 前缀区间的上界：最后一个字符加一（`notDup/` → `notDup0`）。
        let mut chars: Vec<char> = prefix.chars().collect();
        let last = chars.pop().ok_or("read edits: empty prefix")?;
        chars.push(char::from_u32(last as u32 + 1).ok_or("read edits: bad prefix")?);
        let upper: String = chars.into_iter().collect();
        let (lo, hi) = (q.text(prefix), q.text(&upper));
        q.push(&format!(" AND f.field_key >= {lo} AND f.field_key < {hi}"));
    } else {
        q.push(" ORDER BY f.entity_id, f.rowid");
    }
    q.table(c, &EDIT_COLS)
}

/// `successors`：全部「前身卡 → 后继卡」链接（卡的 `historyFrom/<前身>` 修改记录：`entity_id`, `field_key`）。
///
/// 条件用部分覆盖索引 `idx_srs_field_edits_history_from` 的同一句 WHERE；`+entity_kind` 不让规划器改挑
/// `(entity_kind, entity_id)` 索引去扫全部卡片修改记录（BUG-3543）。命中的只有前身链接那几行，再逐行核对归属。
fn successors(c: &Connection, profile: &str) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(profile);
    q.push(&format!(
        "SELECT entity_id, field_key FROM srs_field_edits WHERE {} \
         AND +entity_kind = 'card' AND +profile_uid = srs_id(?1)",
        super::schema::HISTORY_FROM_CONDITION
    ));
    q.table(c, &[("entity_id", KIND_STR), ("field_key", KIND_STR)])
}

/// 字段类别的筛选条件（SQL 布尔表达式）。类别表的唯一真相在 Dart（packages/fushi_srs `srsFieldClassRules`）：
/// 它把「要哪几类」换算成每种实体的字段键清单交过来，这里只拼成条件。[rules] 每项 `{kind, keep: [键…]}`（只要
/// 这些键）或 `{kind, drop: [键…]}`（除这些键以外都要）。
fn class_filter(rules: &Value) -> Result<String, String> {
    let quote = |s: &str| format!("'{}'", s.replace('\'', "''"));
    let keys = |v: &Value| -> String {
        v.as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(quote)
            .collect::<Vec<_>>()
            .join(", ")
    };
    let mut terms: Vec<String> = Vec::new();
    for rule in rules.as_array().ok_or("read: rules must be an array")? {
        let is_kind = format!(
            "entity_kind = {}",
            quote(need_str(rule, "kind").map_err(|_| "read: rule without kind")?)
        );
        match (rule.get("keep"), rule.get("drop")) {
            (Some(keep), None) => {
                terms.push(format!("({is_kind} AND field_key IN ({}))", keys(keep)));
            }
            (None, Some(drop)) => {
                let drop = keys(drop);
                terms.push(if drop.is_empty() {
                    format!("({is_kind})")
                } else {
                    format!("({is_kind} AND field_key NOT IN ({drop}))")
                });
            }
            _ => return Err("read: rule needs exactly one of keep / drop".into()),
        }
    }
    Ok(if terms.is_empty() {
        "(0)".to_owned()
    } else {
        format!("({})", terms.join(" OR "))
    })
}

/// `conflict_edits {rules, kind?, id?}`：还留着两条以上记录的字段键上的全部记录（`k` 实体种类, `i` 实体 ID,
/// `f` 字段键, `j`, `st`），只看 `rules` 圈定的类别（[class_filter]）；`kind` + `id` 给了只看这一个实体。
///
/// 被支配的记录落库时就删了，所以一个字段键上还留着 ≥ 2 条的才可能有冲突：先 GROUP BY 挑出这些字段键（m），
/// 再按完整索引键逐个取记录。CROSS JOIN 钉死连接顺序——写成普通 JOIN 时 SQLite 把 e 放外层、按 profile_uid 扫
/// 本 profile 全部修改记录再去探 m，只筛一个实体也付整表的代价（BUG-3548 / BUG-3947）。
fn conflict_edits(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let tracked = class_filter(req.get("rules").ok_or("read: missing rules")?)?;
    let mut q = Sel::of(profile);
    let only = match (opt_str(req, "kind"), opt_str(req, "id")) {
        (Some(kind), Some(id)) => {
            let (k, i) = (q.text(kind), q.text(id));
            format!("AND entity_kind = {k} AND entity_id = srs_id({i}) ")
        }
        (None, None) => String::new(),
        _ => return Err("read conflict_edits: kind and id go together".into()),
    };
    q.push(&format!(
        "SELECT e.entity_kind, e.entity_id, e.field_key, e.json, s.server_time \
         FROM (SELECT entity_kind AS k, entity_id AS i, field_key AS f \
         FROM srs_field_edits WHERE profile_uid = srs_id(?1) AND {tracked} {only}\
         GROUP BY entity_kind, entity_id, field_key HAVING COUNT(*) > 1) m \
         CROSS JOIN srs_field_edits e ON e.profile_uid = srs_id(?1) \
         AND e.entity_kind = m.k AND e.entity_id = m.i AND e.field_key = m.f \
         LEFT JOIN srs_event_local s ON s.event_id = e.id"
    ));
    q.table(
        c,
        &[
            ("k", KIND_STR),
            ("i", KIND_STR),
            ("f", KIND_STR),
            ("j", KIND_STR),
            ("st", KIND_OPT_I64),
        ],
    )
}

/// `style_candidates {after, limit}`：笔记字段（`f/` 键）的修改记录里原文带内联 `<style>` 块的，按 rowid 游标取下
/// 一批（`rid`, `id`, `json`）。存量样式去重的取数步（Dart `compactStoredStyles`）。
fn style_candidates(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(profile);
    let (after, limit) = (
        q.int(need_int(req, "after")?),
        q.int(need_int(req, "limit")?),
    );
    q.push(&format!(
        "SELECT rowid, id, json FROM srs_field_edits \
         WHERE profile_uid = srs_id(?1) AND entity_kind = 'note' AND rowid > {after} \
         AND field_key LIKE 'f/%' AND instr(json, '<style>') > 0 \
         ORDER BY rowid LIMIT {limit}"
    ));
    q.table(
        c,
        &[("rid", KIND_I64), ("id", KIND_STR), ("json", KIND_STR)],
    )
}

/// `source_note_candidates {needle}`：字段（`f/` 键）的修改记录原文里出现 `needle` 的笔记 ID（去重；只是候选，
/// 调用方再解析确认）。
fn source_note_candidates(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(profile);
    let like = q.text(&format!("%{}%", need_str(req, "needle")?));
    q.push(&format!(
        "SELECT DISTINCT entity_id FROM srs_field_edits \
         WHERE profile_uid = srs_id(?1) AND entity_kind = 'note' \
         AND field_key LIKE 'f/%' AND json LIKE {like}"
    ));
    q.table(c, &[("id", KIND_STR)])
}

/// `lapis_backfill {pairs, to? | notes?}`：旧 Lapis 迁移的补迁候选（笔记 ID）——来源字段键（`pairs` 每项
/// `[来源键, 目标键]`）上有非空文本、目标键上却没有任何记录的笔记。`to` = 当前类型是它的未删除笔记里找；
/// `notes` = 只在这些笔记里找。
fn lapis_backfill(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    const HIT: &str = "e.field_key IN (SELECT src FROM pairs) \
         AND json_type(e.json, '$.v') = 'text' \
         AND trim(json_extract(e.json, '$.v')) <> '' \
         AND NOT EXISTS (SELECT 1 FROM srs_field_edits d \
         WHERE d.entity_kind = 'note' AND d.entity_id = e.entity_id \
         AND d.field_key = p.dst)";
    let mut q = Sel::of(profile);
    let pairs = q.text(&need_list(req, "pairs")?.to_string());
    q.push(&format!(
        "WITH pairs(src, dst) AS MATERIALIZED (\
         SELECT json_extract(value, '$[0]'), json_extract(value, '$[1]') \
         FROM json_each({pairs})) "
    ));
    match list(req, "notes")? {
        None => {
            let to = q.text(need_str(req, "to")?);
            q.push(&format!(
                "SELECT DISTINCT n.id FROM srs_notes_cache n \
                 CROSS JOIN srs_field_edits e ON e.entity_kind = 'note' \
                 AND e.entity_id = n.id \
                 CROSS JOIN pairs p ON p.src = e.field_key \
                 WHERE n.profile_uid = srs_id(?1) AND n.note_type_id = srs_id({to}) \
                 AND n.deleted_at IS NULL AND {HIT}"
            ));
        }
        Some(notes) => {
            let ids = q.text(&notes.to_string());
            q.push(&format!(
                "SELECT DISTINCT e.entity_id FROM json_each({ids}) ids \
                 CROSS JOIN srs_field_edits e ON e.entity_kind = 'note' \
                 AND e.entity_id = srs_id(ids.value) \
                 CROSS JOIN pairs p ON p.src = e.field_key \
                 WHERE +e.profile_uid = srs_id(?1) AND {HIT}"
            ));
        }
    }
    q.table(c, &[("id", KIND_STR)])
}

// ------------------------------------------------------------------ 复习日志与服务器时刻

/// `logs {cards}`：一组卡的全部复习日志原文 + 服务器时刻（`id`, `card_id`, `json`, `st`）。
fn logs(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(profile);
    q.push(
        "SELECT l.id, l.card_id, l.json, e.server_time FROM srs_review_logs l \
         LEFT JOIN srs_event_local e ON e.event_id = l.id \
         WHERE +l.profile_uid = srs_id(?1)",
    );
    q.and_id_in("l.card_id", need_list(req, "cards")?);
    q.table(
        c,
        &[
            ("id", KIND_STR),
            ("card_id", KIND_STR),
            ("json", KIND_STR),
            ("st", KIND_OPT_I64),
        ],
    )
}

/// `anki_logs_at {at}`：Anki 导入的复习日志里发生时刻（= Anki revlog id）落在 `at` 的那些，连同日志所在卡此刻的
/// 笔记与可见性（卡没有缓存行时两列为空）。走 `idx_srs_review_logs_profile_kind_time`（BUG-4254）。
fn anki_logs_at(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(profile);
    let at = q.text(&need_list(req, "at")?.to_string());
    q.push(&format!(
        "SELECT l.card_id, l.occurred_at, l.rating, l.review_type, l.duration_ms, \
         c.note_id, c.hidden FROM srs_review_logs l \
         LEFT JOIN srs_cards_cache c ON c.id = l.card_id \
         WHERE l.profile_uid = srs_id(?1) AND l.kind IN ('review', 'manual') \
         AND l.occurred_at IN (SELECT value FROM json_each({at})) \
         AND l.origin = 'anki'"
    ));
    q.table(
        c,
        &[
            ("card_id", KIND_STR),
            ("at", KIND_I64),
            ("rating", KIND_OPT_I64),
            ("rtype", KIND_STR),
            ("dur", KIND_I64),
            ("note_id", KIND_OPT_STR),
            ("hidden", KIND_OPT_I64),
        ],
    )
}

/// `today_reviews {from, to}`：有效复习投影里落在 `[from, to)` 的评分复习：`{n, ms, again}`。
fn today_reviews(c: &Connection, profile: &str, req: &Value) -> Result<Value, String> {
    let (from, to) = (need_int(req, "from")?, need_int(req, "to")?);
    c.prepare_cached(
        "SELECT COUNT(*), COALESCE(SUM(duration_ms), 0), \
         COALESCE(SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END), 0) \
         FROM srs_stat_reviews WHERE profile_uid = srs_id(?1) AND rating IS NOT NULL \
         AND occurred_at >= ?2 AND occurred_at < ?3",
    )
    .map_err(sql)?
    .query_row(rusqlite::params![profile, from, to], |r| {
        Ok(json!({
            "n": r.get::<_, i64>(0)?,
            "ms": r.get::<_, i64>(1)?,
            "again": r.get::<_, i64>(2)?,
        }))
    })
    .map_err(sql)
}

/// `review_grid {resetMs}`：评分复习按（统计日, 小时）聚合的时长（`day` 纪元起的天数, `hour`, `ms`, `last` 最后
/// 一次的时刻），时长为 0 的格子不出。本地时刻按日志自己记下的 UTC 偏移算，统计日在 `resetMs`（「今日」重置整点
/// 的毫秒数）翻日；SQLite 整数除法向零取整，时刻都在纪元之后。
fn review_grid(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    const LOCAL: &str = "(occurred_at + utc_offset_min * 60000)";
    let mut q = Sel::of(profile);
    let reset = q.int(need_int(req, "resetMs")?);
    q.push(&format!(
        "SELECT ({LOCAL} - {reset}) / 86400000 AS d, \
         {LOCAL} / 3600000 - {LOCAL} / 86400000 * 24 AS h, \
         SUM(duration_ms), MAX(occurred_at) FROM srs_stat_reviews \
         WHERE profile_uid = srs_id(?1) AND rating IS NOT NULL \
         GROUP BY d, h HAVING SUM(duration_ms) > 0"
    ));
    q.table(
        c,
        &[
            ("day", KIND_I64),
            ("hour", KIND_I64),
            ("ms", KIND_I64),
            ("last", KIND_I64),
        ],
    )
}

/// `server_times {ids?}`：事件的服务器时刻（`id`, `st`；没有时刻的不出现）。`ids` 没给 = 本 profile 的全部。
fn server_times(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(profile);
    match list(req, "ids")? {
        Some(ids) => {
            q.push(
                "SELECT event_id, server_time FROM srs_event_local \
                 WHERE +profile_uid = srs_id(?1) AND server_time IS NOT NULL",
            );
            q.and_id_in("event_id", ids);
        }
        None => q.push(
            "SELECT event_id, server_time FROM srs_event_local \
             WHERE profile_uid = srs_id(?1) AND server_time IS NOT NULL",
        ),
    }
    q.table(c, &[("id", KIND_STR), ("st", KIND_I64)])
}

// ------------------------------------------------------------------ 缓存行

/// `cards {fields?, ids?, notes?, decks?, templates?, visibleOnly?, queue?, studyableOn?, ordered?}`：卡片缓存行
/// （列见 store/bulk.rs `CARD_COLUMNS`，`fields` 限定要哪几列）。
///
/// - `ids` / `notes` / `decks` / `templates`：按卡 ID / 笔记 / 牌组 / 模板筛（给了几个就都要满足）；
/// - `visibleOnly`：只要可见的；`queue`：只要这个队列的；
/// - `studyableOn`（今天的日序号）：只要此刻可出的——没暂停、本机调度、没搁置到今天之后；
/// - `ordered`：按 ID 升序。
///
/// 整个 profile 全部卡的读用 `card_columns`（同一份列表）。
fn cards(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let cols = pick(&bulk::CARD_COLUMNS, req, "cards")?;
    let (ids, of_notes) = (list(req, "ids")?, list(req, "notes")?);
    let mut q = Sel::of(profile);
    q.push(&format!(
        "SELECT {} FROM srs_cards_cache WHERE {}profile_uid = srs_id(?1)",
        cols.iter().map(|(n, _)| *n).collect::<Vec<_>>().join(", "),
        if ids.is_some() || of_notes.is_some() {
            "+"
        } else {
            ""
        }
    ));
    if let Some(v) = ids {
        q.and_id_in("id", v);
    }
    if let Some(v) = of_notes {
        q.and_id_in("note_id", v);
    }
    if let Some(v) = list(req, "decks")? {
        q.and_id_in("deck_id", v);
    }
    if let Some(v) = list(req, "templates")? {
        q.and_id_in("template_id", v);
    }
    if flag(req, "visibleOnly") {
        q.push(" AND hidden = 0");
    }
    if let Some(queue) = opt_str(req, "queue") {
        let p = q.text(queue);
        q.push(&format!(" AND queue = {p}"));
    }
    if let Some(today) = opt_int(req, "studyableOn") {
        let p = q.int(today);
        q.push(&format!(
            " AND suspended = 0 AND scheduler = 'fushi' \
             AND (buried_until_day IS NULL OR buried_until_day <= {p})"
        ));
    }
    if flag(req, "ordered") {
        q.push(" ORDER BY id");
    }
    q.table(c, &cols)
}

/// 笔记缓存的列（`notes` 默认交回全部）。
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

/// `notes {fields?, ids?, typeId?, termKey?, alive?, pending?, order?, limit?, offset?}`：笔记缓存行。
///
/// - `ids`：按笔记 ID 筛；`typeId`：当前类型是它的；`termKey`：词条键等于它的；
/// - `alive`：只要未删除的；`pending`：只要有待裁决的；
/// - `order`：`created_asc` / `created_desc`；`limit`（+ `offset`）：只取这一段。
fn notes(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let cols = pick(&NOTE_COLUMNS, req, "notes")?;
    let ids = list(req, "ids")?;
    let mut q = Sel::of(profile);
    q.push(&format!(
        "SELECT {} FROM srs_notes_cache WHERE {}profile_uid = srs_id(?1)",
        cols.iter().map(|(n, _)| *n).collect::<Vec<_>>().join(", "),
        if ids.is_some() { "+" } else { "" }
    ));
    if let Some(v) = ids {
        q.and_id_in("id", v);
    }
    if let Some(t) = opt_str(req, "typeId") {
        let p = q.text(t);
        q.push(&format!(" AND note_type_id = srs_id({p})"));
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
        None => {}
        Some("created_asc") => q.push(" ORDER BY created_at"),
        Some("created_desc") => q.push(" ORDER BY created_at DESC"),
        Some(other) => return Err(format!("read notes: unknown order {other}")),
    }
    if let Some(limit) = opt_int(req, "limit") {
        let (l, o) = (q.int(limit), q.int(opt_int(req, "offset").unwrap_or(0)));
        q.push(&format!(" LIMIT {l} OFFSET {o}"));
    }
    q.table(c, &cols)
}

/// `note_type_counts`：每个笔记类型的未删除笔记数（`t` 类型 ID, `c`；按笔记当前类型计，走
/// `idx_srs_notes_cache_type`）。
fn note_type_counts(c: &Connection, profile: &str) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(profile);
    q.push(
        "SELECT note_type_id, COUNT(*) FROM srs_notes_cache \
         WHERE profile_uid = srs_id(?1) AND deleted_at IS NULL GROUP BY note_type_id",
    );
    q.table(c, &[("t", KIND_STR), ("c", KIND_I64)])
}

/// `pending_notes`：待裁决笔记数（走部分索引 `idx_srs_notes_cache_pending`，不读回行）。
fn pending_notes(c: &Connection, profile: &str) -> Result<i64, String> {
    let mut q = Sel::of(profile);
    q.push(
        "SELECT COUNT(*) FROM srs_notes_cache \
         WHERE profile_uid = srs_id(?1) AND pending_decision = 1",
    );
    q.scalar(c)
}

/// `media_refs {deletedBefore? | deletedAfter?}`：笔记缓存里非空的媒体引用列（`refs`：一条笔记一行，换行分隔的
/// 文件名）。`deletedBefore` = 删除时刻不晚于它的已删笔记（过了保留期的回收候选）；否则是未删除的笔记，
/// `deletedAfter` 给了再加上删除时刻晚于它的已删笔记（保留期内的）。
fn media_refs(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(profile);
    q.push("SELECT media_refs FROM srs_notes_cache WHERE profile_uid = srs_id(?1) AND ");
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
        _ => return Err("read media_refs: deletedBefore and deletedAfter are exclusive".into()),
    }
    q.push(" AND media_refs <> ''");
    q.table(c, &[("refs", KIND_STR)])
}

/// `term_status {terms}`：词条键在 `terms` 里的未删除笔记的可见卡（查词时标词状态用，热路径：走
/// `idx_srs_notes_cache_term`）。
fn term_status(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(profile);
    let terms = q.text(&need_list(req, "terms")?.to_string());
    q.push(&format!(
        "SELECT n.term_key, n.reading_key, c.id, c.note_id, c.queue, c.suspended, \
         c.deck_id, c.due_day, c.due_at \
         FROM srs_notes_cache n JOIN srs_cards_cache c ON c.note_id = n.id \
         WHERE n.profile_uid = srs_id(?1) \
         AND n.term_key IN (SELECT value FROM json_each({terms})) \
         AND n.deleted_at IS NULL AND c.hidden = 0"
    ));
    q.table(
        c,
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

/// `dup_groups`：同类型、同词条键、同读音键的未删除笔记有两条以上的那些笔记（`id`, `t` 类型, `k` 词条键,
/// `r` 读音键, `c` 创建时刻, `s` 排序字段, `reps` 名下各卡复习次数之和）。分组与排除标过「不是重复」的在 Dart。
fn dup_groups(c: &Connection, profile: &str) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(profile);
    q.push(
        "SELECT n.id, n.note_type_id, n.term_key, n.reading_key, n.created_at, n.sort_field, \
         (SELECT COALESCE(SUM(x.reps), 0) FROM srs_cards_cache x WHERE x.note_id = n.id) \
         FROM srs_notes_cache n JOIN (\
         SELECT note_type_id, term_key, reading_key FROM srs_notes_cache \
         WHERE profile_uid = srs_id(?1) AND deleted_at IS NULL AND term_key != '' \
         GROUP BY note_type_id, term_key, reading_key HAVING COUNT(*) > 1\
         ) g ON g.note_type_id = n.note_type_id AND g.term_key = n.term_key \
         AND g.reading_key = n.reading_key \
         WHERE n.profile_uid = srs_id(?1) AND n.deleted_at IS NULL",
    );
    q.table(
        c,
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

// ------------------------------------------------------------------ 整份事件

/// `events {parts?, ordered?}`：本 profile 的全部事件原文，四张表：`entities`（`id`, `kind`, `payload_json`）、
/// `edits` / `logs` / `unknown`（各一列 `json`）。`parts` 限定要哪几张（缺省全部）；`ordered` = 各按 ID 升序
/// （备份合并 / profile 并入要确定的顺序）。
fn events(c: &Connection, profile: &str, req: &Value, files: &mut Files) -> Result<Value, String> {
    let order = if flag(req, "ordered") {
        " ORDER BY id"
    } else {
        ""
    };
    let parts = list(req, "parts")?;
    let wanted = |name: &str| match parts {
        None => true,
        Some(p) => p
            .as_array()
            .is_some_and(|xs| xs.iter().any(|x| x.as_str() == Some(name))),
    };
    if wanted("entities") {
        let mut q = Sel::of(profile);
        q.push(&format!(
            "SELECT id, kind, payload_json FROM srs_entities WHERE profile_uid = srs_id(?1){order}"
        ));
        files.push((
            "entities".to_owned(),
            q.table(
                c,
                &[
                    ("id", KIND_STR),
                    ("kind", KIND_STR),
                    ("payload_json", KIND_STR),
                ],
            )?,
        ));
    }
    for (name, table) in [
        ("edits", "srs_field_edits"),
        ("logs", "srs_review_logs"),
        ("unknown", "srs_unknown_events"),
    ] {
        if !wanted(name) {
            continue;
        }
        let mut q = Sel::of(profile);
        q.push(&format!(
            "SELECT json FROM {table} WHERE profile_uid = srs_id(?1){order}"
        ));
        files.push((name.to_owned(), q.table(c, &[("json", KIND_STR)])?));
    }
    Ok(json!({}))
}

/// `events_present {ids, ops?}`：`ids` 里已在本 profile 名下的事件 ID（四张事件表；可能重复）。`ops` = 连同步
/// v2 的操作索引一起看（被支配而不在投影里的修改记录、被清除内容的日志也算在）。
fn events_present(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let mut q = Sel::of(profile);
    let ids = q.text(&need_list(req, "ids")?.to_string());
    q.push(&format!(
        "WITH want(id) AS MATERIALIZED (SELECT srs_id(value) FROM json_each({ids}))"
    ));
    let mut sources: Vec<(&str, &str)> = vec![
        ("srs_entities", "id"),
        ("srs_field_edits", "id"),
        ("srs_review_logs", "id"),
        ("srs_unknown_events", "id"),
    ];
    if flag(req, "ops") {
        sources.push(("sync2_edit_ops", "edit_id"));
        sources.push(("sync2_log_meta", "log_id"));
    }
    for (n, (table, col)) in sources.iter().enumerate() {
        q.push(&format!(
            "{} SELECT {col} FROM {table} WHERE +profile_uid = srs_id(?1) \
             AND {col} IN (SELECT id FROM want)",
            if n == 0 { "" } else { " UNION ALL" }
        ));
    }
    q.table(c, &[("id", KIND_STR)])
}

// ------------------------------------------------------------------ 不针对单个 profile

/// `profile_merges`：记着、还没做完的 profile 并入标记（`key`, `value`；键 = 前缀 + 旧 uid，见
/// store/profile_data.rs `MERGE_MARKER_PREFIX`）。
fn profile_merges(c: &Connection) -> Result<Vec<u8>, String> {
    let mut q = Sel::lib();
    let like = q.text(&format!("{}%", super::profile_data::MERGE_MARKER_PREFIX));
    q.push(&format!(
        "SELECT key, value FROM srs_meta WHERE key LIKE {like}"
    ));
    q.table(c, &[("key", KIND_STR), ("value", KIND_STR)])
}

/// `user_note_count`：整个库（全部 profile）的用户笔记数（内置行——profile / 牌组 / 笔记类型——不算用户数据）。
fn user_note_count(c: &Connection) -> Result<i64, String> {
    let mut q = Sel::lib();
    q.push("SELECT COUNT(*) FROM srs_entities WHERE kind = 'note'");
    q.scalar(c)
}

/// `entity_owners`：有身份记录的 profile uid（`uid`）。
fn entity_owners(c: &Connection) -> Result<Vec<u8>, String> {
    let mut q = Sel::lib();
    q.push("SELECT DISTINCT profile_uid FROM srs_entities");
    q.table(c, &[("uid", KIND_STR)])
}

#[cfg(test)]
#[path = "reads_tests.rs"]
mod tests;
