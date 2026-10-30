//! 大结果集的列式读取：内核直接读缓存表，按列编码成一块字节交回 Dart（`SrsColumns`，
//! packages/fushi_srs/lib/src/store/srs_columns.dart），worker isolate 用 `TransferableTypedData` 原样交给调用方。
//!
//! 以前这些读走 Drift：Rust 把行编码成页 → Drift isolate 解码成行对象 → SendPort 深拷贝到 UI isolate → 映射成数据类，
//! 十万张卡几轮拷贝；统计页另外为了笔记出处把整库笔记连同全部修改记录物化一遍（`allNoteViews`）。
//!
//! 编码（小端，每段 8 字节对齐，Dart 侧直接在同一块缓冲上建 `Int64List` / `Float64List` 视图，不拷贝）：
//!
//! ```text
//! "FCL1" u32 行数 u32 列数 u32 0
//! 每列：u32 名字字节数 + 名字（补齐到 8）；u32 类型 u32 0；数据（补齐到 8）
//!   1 i64      行数 × 8
//!   2 f64      行数 × 8
//!   3 i64?     行数个有值标志（1 字节，补齐）+ 行数 × 8（空 = 0）
//!   4 f64?     同上
//!   5 str      u64 字节数；(行数 + 1) 个 u32 偏移（补齐）；UTF-8 字节（补齐）
//!   6 str?     行数个有值标志（补齐）+ 同 5
//! ```
//!
//! 一个结果可以有几张表（统计：卡 / 复习 / 出处），各自一块，放在 sync2 命令结果的 `files` 里。
use rusqlite::types::ValueRef;
use rusqlite::Connection;
use serde_json::{json, Value};
use std::collections::HashMap;

use super::sync2::sql;

const KIND_I64: u32 = 1;
const KIND_F64: u32 = 2;
const KIND_OPT_I64: u32 = 3;
const KIND_OPT_F64: u32 = 4;
const KIND_STR: u32 = 5;
const KIND_OPT_STR: u32 = 6;

/// 一张列式表的编码器。
pub struct Columns {
    rows: usize,
    cols: u32,
    buf: Vec<u8>,
}

impl Columns {
    pub fn new(rows: usize) -> Columns {
        let mut buf = Vec::with_capacity(16 + rows * 64);
        buf.extend_from_slice(b"FCL1");
        buf.extend_from_slice(&(rows as u32).to_le_bytes());
        buf.extend_from_slice(&0u32.to_le_bytes());
        buf.extend_from_slice(&0u32.to_le_bytes());
        Columns { rows, cols: 0, buf }
    }

    fn pad(&mut self) {
        while !self.buf.len().is_multiple_of(8) {
            self.buf.push(0);
        }
    }

    fn head(&mut self, name: &str, kind: u32, len: usize) {
        assert_eq!(len, self.rows, "column {name}: {len} values for {} rows", self.rows);
        self.cols += 1;
        self.buf.extend_from_slice(&(name.len() as u32).to_le_bytes());
        self.buf.extend_from_slice(name.as_bytes());
        self.pad();
        self.buf.extend_from_slice(&kind.to_le_bytes());
        self.buf.extend_from_slice(&0u32.to_le_bytes());
    }

    fn flags<T>(&mut self, v: &[Option<T>]) {
        self.buf.extend(v.iter().map(|x| u8::from(x.is_some())));
        self.pad();
    }

    pub fn i64s(&mut self, name: &str, v: &[i64]) {
        self.head(name, KIND_I64, v.len());
        for x in v {
            self.buf.extend_from_slice(&x.to_le_bytes());
        }
    }

    pub fn f64s(&mut self, name: &str, v: &[f64]) {
        self.head(name, KIND_F64, v.len());
        for x in v {
            self.buf.extend_from_slice(&x.to_le_bytes());
        }
    }

    pub fn opt_i64s(&mut self, name: &str, v: &[Option<i64>]) {
        self.head(name, KIND_OPT_I64, v.len());
        self.flags(v);
        for x in v {
            self.buf.extend_from_slice(&x.unwrap_or(0).to_le_bytes());
        }
    }

    pub fn opt_f64s(&mut self, name: &str, v: &[Option<f64>]) {
        self.head(name, KIND_OPT_F64, v.len());
        self.flags(v);
        for x in v {
            self.buf.extend_from_slice(&x.unwrap_or(0.0).to_le_bytes());
        }
    }

    fn text<S: AsRef<str>>(&mut self, v: impl Iterator<Item = S> + Clone) {
        let total: usize = v.clone().map(|s| s.as_ref().len()).sum();
        self.buf.extend_from_slice(&(total as u64).to_le_bytes());
        let mut at = 0u32;
        self.buf.extend_from_slice(&at.to_le_bytes());
        for s in v.clone() {
            at += s.as_ref().len() as u32;
            self.buf.extend_from_slice(&at.to_le_bytes());
        }
        self.pad();
        for s in v {
            self.buf.extend_from_slice(s.as_ref().as_bytes());
        }
        self.pad();
    }

    pub fn strs<S: AsRef<str>>(&mut self, name: &str, v: &[S]) {
        self.head(name, KIND_STR, v.len());
        self.text(v.iter().map(AsRef::as_ref));
    }

    pub fn opt_strs<S: AsRef<str>>(&mut self, name: &str, v: &[Option<S>]) {
        self.head(name, KIND_OPT_STR, v.len());
        self.flags(v);
        self.text(v.iter().map(|x| x.as_ref().map_or("", AsRef::as_ref)));
    }

    pub fn finish(mut self) -> Vec<u8> {
        self.buf[8..12].copy_from_slice(&self.cols.to_le_bytes());
        self.buf
    }
}

/// 一列从 SQL 读出的值（按声明类型收集）。
enum Col {
    I64(Vec<i64>),
    F64(Vec<f64>),
    OptI64(Vec<Option<i64>>),
    OptF64(Vec<Option<f64>>),
    Str(Vec<String>),
    OptStr(Vec<Option<String>>),
}

/// 卡片缓存的列：(列名, 类型)。`card_columns` 默认交回全部（`SrsCardCacheRow` 的每个字段，`profile_uid` 除外）。
const CARD_COLUMNS: [(&str, u32); 23] = [
    ("id", KIND_STR),
    ("note_id", KIND_STR),
    ("template_id", KIND_STR),
    ("cloze_ord", KIND_I64),
    ("deck_id", KIND_STR),
    ("suspended", KIND_I64),
    ("buried_until_day", KIND_OPT_I64),
    ("flag", KIND_I64),
    ("hidden", KIND_I64),
    ("queue", KIND_STR),
    ("due_day", KIND_OPT_I64),
    ("due_at", KIND_OPT_I64),
    ("scheduled_days", KIND_I64),
    ("reps", KIND_I64),
    ("lapses", KIND_I64),
    ("stability", KIND_OPT_F64),
    ("difficulty", KIND_OPT_F64),
    ("last_reviewed_at", KIND_OPT_I64),
    ("last_log_id", KIND_OPT_STR),
    ("scheduler", KIND_STR),
    ("note_created_at", KIND_I64),
    ("new_position", KIND_OPT_I64),
    ("freq_rank", KIND_OPT_I64),
];

fn read_cols(c: &Connection, q: &str, params: &[&dyn rusqlite::ToSql], kinds: &[u32]) -> Result<(usize, Vec<Col>), String> {
    let mut cols: Vec<Col> = kinds
        .iter()
        .map(|k| match *k {
            KIND_I64 => Col::I64(Vec::new()),
            KIND_F64 => Col::F64(Vec::new()),
            KIND_OPT_I64 => Col::OptI64(Vec::new()),
            KIND_OPT_F64 => Col::OptF64(Vec::new()),
            KIND_STR => Col::Str(Vec::new()),
            _ => Col::OptStr(Vec::new()),
        })
        .collect();
    let mut stmt = c.prepare_cached(q).map_err(sql)?;
    let mut it = stmt.query(params).map_err(sql)?;
    let mut n = 0usize;
    while let Some(r) = it.next().map_err(sql)? {
        for (i, col) in cols.iter_mut().enumerate() {
            let v = r.get_ref(i).map_err(sql)?;
            let int = |v: ValueRef<'_>| -> Option<i64> {
                match v {
                    ValueRef::Integer(x) => Some(x),
                    ValueRef::Real(x) => Some(x as i64),
                    _ => None,
                }
            };
            let real = |v: ValueRef<'_>| -> Option<f64> {
                match v {
                    ValueRef::Integer(x) => Some(x as f64),
                    ValueRef::Real(x) => Some(x),
                    _ => None,
                }
            };
            let text = |v: ValueRef<'_>| -> Option<String> {
                match v {
                    ValueRef::Text(t) => Some(String::from_utf8_lossy(t).into_owned()),
                    ValueRef::Integer(x) => Some(x.to_string()),
                    _ => None,
                }
            };
            match col {
                Col::I64(x) => x.push(int(v).unwrap_or(0)),
                Col::F64(x) => x.push(real(v).unwrap_or(0.0)),
                Col::OptI64(x) => x.push(int(v)),
                Col::OptF64(x) => x.push(real(v)),
                Col::Str(x) => x.push(text(v).unwrap_or_default()),
                Col::OptStr(x) => x.push(text(v)),
            }
        }
        n += 1;
    }
    Ok((n, cols))
}

fn encode(rows: usize, names: &[&str], cols: &[Col]) -> Vec<u8> {
    let mut out = Columns::new(rows);
    for (name, col) in names.iter().zip(cols) {
        match col {
            Col::I64(x) => out.i64s(name, x),
            Col::F64(x) => out.f64s(name, x),
            Col::OptI64(x) => out.opt_i64s(name, x),
            Col::OptF64(x) => out.opt_f64s(name, x),
            Col::Str(x) => out.strs(name, x),
            Col::OptStr(x) => out.opt_strs(name, x),
        }
    }
    out.finish()
}

/// `card_columns`：本 profile 的卡片缓存行（含隐藏；`visibleOnly` 为真只要可见的）按列交回。`fields` 限定要哪几列
/// （缺省全部，见 [CARD_COLUMNS]）。行序与 Drift 以前发的 `SELECT * FROM srs_cards_cache WHERE profile_uid = srs_id(?)`
/// 相同（同一条件、同一张表的同一查询计划）。
pub fn card_columns(c: &Connection, profile: &str, req: &Value) -> Result<Vec<u8>, String> {
    let wanted: Vec<&str> = match req.get("fields").and_then(Value::as_array) {
        Some(xs) => xs.iter().filter_map(Value::as_str).collect(),
        None => CARD_COLUMNS.iter().map(|(n, _)| *n).collect(),
    };
    let mut names = Vec::with_capacity(wanted.len());
    let mut kinds = Vec::with_capacity(wanted.len());
    for w in &wanted {
        let (n, k) = CARD_COLUMNS.iter().find(|(n, _)| n == w).ok_or_else(|| format!("card_columns: unknown column {w}"))?;
        names.push(*n);
        kinds.push(*k);
    }
    let visible = req["visibleOnly"] == Value::Bool(true);
    let q = format!(
        "SELECT {} FROM srs_cards_cache WHERE profile_uid = srs_id(?1){}",
        names.join(", "),
        if visible { " AND hidden = 0" } else { "" }
    );
    let (rows, cols) = read_cols(c, &q, &[&profile], &kinds)?;
    Ok(encode(rows, &names, &cols))
}

/// `stats_bundle`：统计页要的三张表（store 层只读快照里一次读完）。
///
/// - `cards`：可见卡（`hidden = 0`）的统计列；`added_at` = 笔记缓存的创建时刻（没有笔记缓存行时用卡片行上记的），
///   `src` = 这张卡所属笔记的出处在 `sources` 里的下标（-1 = 没有笔记缓存行）。
/// - `sources`：出处字典（kind, 原样 title；没有出处 = 两个空串），按首次出现的顺序。
/// - `reviews`：有效复习投影（`srs_stat_reviews`）按时刻升序；`card` 是归属卡在「卡 ID 表」里的下标——可见卡就是
///   它在 `cards` 里的行号，不可见的归属卡在 `cards` 行数之后、按 `extra_ids` 的顺序编号。
/// - `extra_ids`：复习归属到的、不在 `cards` 里的卡 ID。
pub fn stats_bundle(c: &Connection, profile: &str, files: &mut Vec<(String, Vec<u8>)>) -> Result<Value, String> {
    const CARD_NAMES: [&str; 17] = [
        "id", "note_id", "deck_id", "queue", "scheduled_days", "suspended", "buried_until_day", "scheduler", "due_day",
        "due_at", "stability", "difficulty", "last_reviewed_at", "lapses", "reps", "added_at", "last_log_id",
    ];
    const CARD_KINDS: [u32; 19] = [
        KIND_STR, KIND_STR, KIND_STR, KIND_STR, KIND_I64, KIND_I64, KIND_OPT_I64, KIND_STR, KIND_OPT_I64, KIND_OPT_I64,
        KIND_OPT_F64, KIND_OPT_F64, KIND_OPT_I64, KIND_I64, KIND_I64, KIND_I64, KIND_OPT_STR, KIND_OPT_STR, KIND_OPT_STR,
    ];
    let (rows, mut cols) = read_cols(
        c,
        "SELECT c.id, c.note_id, c.deck_id, c.queue, c.scheduled_days, c.suspended, c.buried_until_day, c.scheduler, \
         c.due_day, c.due_at, c.stability, c.difficulty, c.last_reviewed_at, c.lapses, c.reps, \
         COALESCE(n.created_at, c.note_created_at), c.last_log_id, n.source_kind, n.source_title \
         FROM srs_cards_cache c LEFT JOIN srs_notes_cache n ON n.id = c.note_id \
         WHERE c.profile_uid = srs_id(?1) AND c.hidden = 0",
        &[&profile],
        &CARD_KINDS,
    )?;
    // 出处字典。
    let (Some(Col::OptStr(titles)), Some(Col::OptStr(kinds))) = (cols.pop(), cols.pop()) else {
        return Err("stats_bundle: source columns".into());
    };
    let mut dict: HashMap<(String, String), i64> = HashMap::new();
    let mut src_kind: Vec<String> = Vec::new();
    let mut src_title: Vec<String> = Vec::new();
    let mut src: Vec<i64> = Vec::with_capacity(rows);
    for (k, t) in kinds.into_iter().zip(titles) {
        match k {
            None => src.push(-1),
            Some(k) => {
                let t = t.unwrap_or_default();
                let next = src_kind.len() as i64;
                let i = *dict.entry((k.clone(), t.clone())).or_insert_with(|| {
                    src_kind.push(k);
                    src_title.push(t);
                    next
                });
                src.push(i);
            }
        }
    }
    let mut cards = Columns::new(rows);
    let mut index: HashMap<String, i64> = HashMap::with_capacity(rows);
    if let Col::Str(ids) = &cols[0] {
        for (i, id) in ids.iter().enumerate() {
            index.insert(id.clone(), i as i64);
        }
    }
    for (name, col) in CARD_NAMES.iter().zip(&cols) {
        match col {
            Col::I64(x) => cards.i64s(name, x),
            Col::F64(x) => cards.f64s(name, x),
            Col::OptI64(x) => cards.opt_i64s(name, x),
            Col::OptF64(x) => cards.opt_f64s(name, x),
            Col::Str(x) => cards.strs(name, x),
            Col::OptStr(x) => cards.opt_strs(name, x),
        }
    }
    cards.i64s("src", &src);
    let mut sources = Columns::new(src_kind.len());
    sources.strs("kind", &src_kind);
    sources.strs("title", &src_title);

    // 复习投影。
    let mut stmt = c
        .prepare_cached(
            "SELECT card_id, occurred_at, utc_offset_min, rating, kind, duration_ms, prev_due_day, maturity_delta \
             FROM srs_stat_reviews WHERE profile_uid = srs_id(?1) ORDER BY occurred_at",
        )
        .map_err(sql)?;
    let mut it = stmt.query([profile]).map_err(sql)?;
    let (mut card, mut at, mut off, mut rating, mut kind, mut dur, mut prev, mut mat) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
    let mut extra: Vec<String> = Vec::new();
    while let Some(r) = it.next().map_err(sql)? {
        let id: String = r.get(0).map_err(sql)?;
        let next = rows as i64 + extra.len() as i64;
        let i = match index.get(&id) {
            Some(i) => *i,
            None => {
                index.insert(id.clone(), next);
                extra.push(id);
                next
            }
        };
        card.push(i);
        at.push(r.get::<_, i64>(1).map_err(sql)?);
        off.push(r.get::<_, i64>(2).map_err(sql)?);
        rating.push(r.get::<_, Option<i64>>(3).map_err(sql)?);
        kind.push(r.get::<_, i64>(4).map_err(sql)?);
        dur.push(r.get::<_, i64>(5).map_err(sql)?);
        prev.push(r.get::<_, Option<i64>>(6).map_err(sql)?);
        mat.push(r.get::<_, i64>(7).map_err(sql)?);
    }
    let mut reviews = Columns::new(card.len());
    reviews.i64s("card", &card);
    reviews.i64s("occurred_at", &at);
    reviews.i64s("utc_offset_min", &off);
    reviews.opt_i64s("rating", &rating);
    reviews.i64s("kind", &kind);
    reviews.i64s("duration_ms", &dur);
    reviews.opt_i64s("prev_due_day", &prev);
    reviews.i64s("maturity_delta", &mat);
    let mut extras = Columns::new(extra.len());
    extras.strs("id", &extra);
    files.push(("cards".to_owned(), cards.finish()));
    files.push(("sources".to_owned(), sources.finish()));
    files.push(("reviews".to_owned(), reviews.finish()));
    files.push(("extra_ids".to_owned(), extras.finish()));
    Ok(json!({"cards": rows, "reviews": card.len()}))
}

/// `anki_resolve`：AnkiConnect 数字 id → UUID（`notes` / `cards` 两组，查 v13 的 `anki_id` 索引）。结果与请求等长，
/// 查不到 = null（同一个数字撞上两行时取 ID 最小的一行，与以前 Dart 整表映射「后写的覆盖」不同但都确定；53 位下
/// 实际不会撞）。
pub fn anki_resolve(c: &Connection, profile: &str, req: &Value) -> Result<Value, String> {
    let mut out = serde_json::Map::new();
    for (key, table) in [("notes", "srs_notes_cache"), ("cards", "srs_cards_cache")] {
        let Some(xs) = req.get(key).and_then(Value::as_array) else { continue };
        let mut stmt = c
            .prepare_cached(&format!(
                "SELECT MIN(id) FROM {table} WHERE profile_uid = srs_id(?1) AND anki_id = ?2"
            ))
            .map_err(sql)?;
        let mut ids = Vec::with_capacity(xs.len());
        for x in xs {
            let id: Option<String> = match x.as_i64() {
                Some(n) => stmt.query_row(rusqlite::params![profile, n], |r| r.get(0)).map_err(sql)?,
                None => None,
            };
            ids.push(id.map_or(Value::Null, Value::String));
        }
        out.insert(key.to_owned(), Value::Array(ids));
    }
    Ok(Value::Object(out))
}

/// `anki_notes_info`：AnkiConnect `notesInfo` 要的笔记内容，一批一次读（L-final）。`notes` = 数字笔记 id；回
/// `{notes: [...]}` 与请求等长，每项是 null（查不到 / 已删除）或 `{id, nt, t, f, c}`：笔记 UUID、笔记类型、标签、
/// 字段（`[[字段 ID, 值]]`，寄存器视图的原序，值是落库表示——样式引用由 Dart 一批展开）、可见卡
/// （`[[卡的数字 id, 模板 ID, cloze 序号]]`，排序要笔记类型的模板序，由 Dart 排）。
///
/// 以前 Dart 侧为这一个动作把每条笔记的身份记录与**全部**修改记录读成 Drift 行对象、组装成 `SrsEntitySource`、
/// 物化后再连同修改记录列表建 `SrsNoteView`，另读一遍卡片缓存行；这里在只读快照上直接读、物化（与缓存行刷新
/// 同一个寄存器内核与同一套 SQL，store/caches.rs [super::caches::note_infos]），只交回要用的值。
pub fn anki_notes_info(c: &Connection, profile: &str, req: &Value) -> Result<Value, String> {
    let nums: Vec<Option<i64>> =
        req.get("notes").and_then(Value::as_array).map(|a| a.iter().map(Value::as_i64).collect()).unwrap_or_default();
    let mut resolve =
        c.prepare_cached("SELECT MIN(id) FROM srs_notes_cache WHERE profile_uid = srs_id(?1) AND anki_id = ?2").map_err(sql)?;
    let mut ids: Vec<Option<String>> = Vec::with_capacity(nums.len());
    for n in &nums {
        ids.push(match n {
            Some(n) => resolve.query_row(rusqlite::params![profile, n], |r| r.get(0)).map_err(sql)?,
            None => None,
        });
    }
    let known: Vec<String> = ids.iter().flatten().cloned().collect::<std::collections::BTreeSet<_>>().into_iter().collect();
    let mut views: HashMap<String, super::caches::NoteInfo> = HashMap::with_capacity(known.len());
    let mut cards: HashMap<String, Vec<Value>> = HashMap::new();
    for chunk in known.chunks(200) {
        for v in super::caches::note_infos(c, chunk)? {
            views.insert(v.id.clone(), v);
        }
        let q = format!(
            "SELECT note_id, anki_id, template_id, cloze_ord FROM srs_cards_cache              WHERE note_id IN ({}) AND +profile_uid = srs_id(?1) AND +hidden = 0",
            (2..chunk.len() + 2).map(|i| format!("?{i}")).collect::<Vec<_>>().join(", ")
        );
        let mut stmt = c.prepare_cached(&q).map_err(sql)?;
        let args = std::iter::once(profile).chain(chunk.iter().map(String::as_str));
        let mut rows = stmt.query(rusqlite::params_from_iter(args)).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            let note: String = r.get(0).map_err(sql)?;
            let (num, tpl, ord): (i64, String, i64) = (r.get(1).map_err(sql)?, r.get(2).map_err(sql)?, r.get(3).map_err(sql)?);
            cards.entry(note).or_default().push(json!([num, tpl, ord]));
        }
    }
    let out: Vec<Value> = ids
        .iter()
        .map(|id| match id.as_ref().and_then(|id| views.get(id)) {
            Some(n) if n.deleted_at.is_none() => json!({
                "id": n.id,
                "nt": n.note_type,
                "t": n.tags,
                "f": n.fields.iter().map(|(k, v)| json!([k, v])).collect::<Vec<_>>(),
                "c": cards.get(&n.id).cloned().unwrap_or_default(),
            }),
            _ => Value::Null,
        })
        .collect();
    Ok(json!({"notes": out}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> Connection {
        let mut c = Connection::open_in_memory().unwrap();
        crate::store::schema::migrate(&mut c).unwrap();
        c
    }

    /// `hash53("anki-id/" + UUID)` 与 Dart `SrsIds.ankiNumericId` / fushi_compute 同值（向量来自 Dart：
    /// packages/fushi_srs/test 的 ankiNumericId 用例与 fushi_engine test/srs/srs_stats_columns_test.dart）。
    #[test]
    fn anki_numeric_id_is_hash53_of_the_prefixed_uuid() {
        use sha2::{Digest, Sha256};
        let id = "01928c3e-0000-7000-8000-0000000000c3";
        let d = Sha256::digest(format!("anki-id/{id}").as_bytes());
        let mut v = 0u64;
        for &b in &d[..7] {
            v = (v << 8) | u64::from(b);
        }
        assert_eq!(crate::store::schema::anki_numeric_id(id) as u64, v & ((1 << 53) - 1));
        assert!(crate::store::schema::anki_numeric_id(id) > 0);
    }

    #[test]
    fn columns_layout_is_aligned_and_round_trips() {
        let mut t = Columns::new(3);
        t.i64s("a", &[1, -2, 3]);
        t.opt_f64s("b", &[Some(0.5), None, Some(2.0)]);
        t.opt_strs("c", &[Some("x"), None, Some("日本")]);
        let b = t.finish();
        assert_eq!(&b[0..4], b"FCL1");
        assert_eq!(u32::from_le_bytes(b[4..8].try_into().unwrap()), 3);
        assert_eq!(u32::from_le_bytes(b[8..12].try_into().unwrap()), 3);
        assert_eq!(b.len() % 8, 0);
        // a：名字 1 字节补到 8，类型 8 字节，3 × 8 数据。
        assert_eq!(i64::from_le_bytes(b[16 + 4 + 4 + 8 + 8..16 + 4 + 4 + 8 + 16].try_into().unwrap()), -2);
    }

    #[test]
    fn stats_bundle_dictionary_encodes_sources_and_indexes_review_cards() {
        let c = store();
        c.execute_batch(
            "INSERT INTO srs_notes_cache (id, profile_uid, note_type_id, guid, created_at, source_kind, source_title) VALUES
               ('n1', 'p', 'T', 'g1', 100, 'book', ' A '), ('n2', 'p', 'T', 'g2', 200, '', ''),
               ('n3', 'p', 'T', 'g3', 300, 'book', ' A ');
             INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, hidden, note_created_at) VALUES
               ('c1', 'p', 'n1', 't', 'd', 0, 1), ('c2', 'p', 'n2', 't', 'd', 0, 2), ('c3', 'p', 'n3', 't', 'd', 0, 3),
               ('c4', 'p', 'nx', 't', 'd', 0, 4), ('h', 'p', 'n1', 't', 'd', 1, 5);
             INSERT INTO srs_stat_reviews (log_id, profile_uid, card_id, occurred_at, rating) VALUES
               ('l1', 'p', 'c2', 10, 3), ('l2', 'p', 'gone', 20, 1), ('l3', 'p', 'c1', 30, NULL);",
        )
        .unwrap();
        let mut files = Vec::new();
        let v = stats_bundle(&c, "p", &mut files).unwrap();
        assert_eq!(v, json!({"cards": 4, "reviews": 3}));
        let names: Vec<&str> = files.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, ["cards", "sources", "reviews", "extra_ids"]);
        // 两个出处（book " A " 与无出处），c4 没有笔记缓存行。
        assert_eq!(u32::from_le_bytes(files[1].1[4..8].try_into().unwrap()), 2);
        assert_eq!(u32::from_le_bytes(files[3].1[4..8].try_into().unwrap()), 1);
    }

    #[test]
    fn anki_resolve_finds_rows_by_numeric_id() {
        let c = store();
        let n = crate::store::schema::anki_numeric_id("n1");
        c.execute(
            "INSERT INTO srs_notes_cache (id, profile_uid, note_type_id, guid, created_at, anki_id) VALUES ('n1', 'p', 'T', 'g', 1, ?1)",
            [n],
        )
        .unwrap();
        let v = anki_resolve(&c, "p", &json!({"notes": [n, 5], "cards": [n]})).unwrap();
        assert_eq!(v, json!({"notes": ["n1", null], "cards": [null]}));
    }

    /// v13 升级：老行回填 anki_id，重放一遍不出错。
    #[test]
    fn v13_backfills_anki_ids_idempotently() {
        let mut c = store();
        c.execute_batch(
            "INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id) VALUES ('c1', 'p', 'n', 't', 'd');
             UPDATE srs_cards_cache SET anki_id = 0; UPDATE srs_meta SET value = '9' WHERE key = 'schema';",
        )
        .unwrap();
        crate::store::schema::migrate(&mut c).unwrap();
        let got: i64 = c.query_row("SELECT anki_id FROM srs_cards_cache WHERE id = 'c1'", [], |r| r.get(0)).unwrap();
        assert_eq!(got, crate::store::schema::anki_numeric_id("c1"));
        c.execute("UPDATE srs_meta SET value = '12' WHERE key = 'schema'", []).unwrap();
        crate::store::schema::migrate(&mut c).unwrap();
        let v: String = c.query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| r.get(0)).unwrap();
        assert_eq!(v, crate::store::schema::SCHEMA_VERSION.to_string());
    }
}
