//! 卡片浏览的常驻会话（按 profile）：浏览页的搜索语料与列数据留在 Rust 里，筛选、排序都在这里做，Dart 只取
//! 命中行的分页（列式）与批量操作要的 id。
//!
//! 以前（L4 之前）浏览页每次打开、每次写操作之后都整份重读：Dart 侧装全部笔记缓存行 + 卡片缓存行、建 Dart 求值
//! 对象、把结构与字段文本整份编码进一个新的原生搜索语料，再在 Dart 里排序；换快照时新旧两份语料同时在内存里。
//! 现在：
//!
//! - **建**：一个 profile 第一次浏览（或攒的改动太多）时整份读一遍缓存行（[Session::build]）；字段原文与笔记最后
//!   改动时刻不常驻，查询 / 按字段排序真用到时整列从修改记录读一次（[Session::ensure_fields]），之后常驻。
//! - **增量**：写连接上的临时触发器（store/queue.rs）把写过的卡缓存行、笔记缓存行、笔记修改记录（含它们的服务器
//!   时刻）的 id 记进浏览的「待重读」（与复习队列各取各的）；每条浏览命令先按 id 重读那几行（[Session::apply]），
//!   永远以库里的行为准（回滚 / `ROLLBACK TO` 不会让内存与库分叉），事务边界的判据与复习队列相同。
//! - **整份重建**：没有会话、攒的待重读超过 `DIRTY_CAP`、重读出错（丢掉会话，下次重建）。
//! - **搜索语料**：由会话里的数据在 Rust 里直接建（[View]），只在「结构」变了时重建：卡 / 笔记增删、卡换牌组 /
//!   模板、笔记换类型 / 标签 / 创建时刻、装进了新的字段列、或 Dart 传来的笔记类型 / 牌组名变了。改旗标、暂停、
//!   作答这类只动排程列的写入不重建语料——数值列每次查询按此刻现算。
//! - 笔记类型（字段、模板、别名）、牌组全名、RWKV 此刻会出的卡由 Dart 每次查询传入（只与类型 / 牌组数有关），
//!   语义与旧的 Dart 快照（`SrsBrowseSnapshot`）逐项相同：回归向量见
//!   packages/fushi_engine/test/srs/srs_browse_vectors_test.dart。
//! - **AnkiConnect**（L-5）：兼容层的 findNotes / findCards（`anki_find`）、canAddNotes 的库内查重（`anki_dupes`）、
//!   getTags（`anki_tags`）用同一个会话、同一份语料，不再在 Dart 里常驻一份全库笔记镜像。canAddNotes 的库内查重
//!   不用会话：首字段的查重规范形写在笔记缓存行上（srs.db v15 `dupe_norm`，写缓存行时算），直接按索引查
//!   （[anki_dupes]）。回归向量见 packages/fushi_engine/test/srs/ankiconnect/srs_ankiconnect_vectors_test.dart。

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, MutexGuard};

use rusqlite::{params_from_iter, types::Value as Sql, Connection};
use serde_json::{json, Value};

use crate::projection::Day;
use crate::registers::{self, StoredEdit};
use crate::search::{self, Corpus, Needs, DUE_NONE};
use crate::store::queue::{Dirty, LEARN_AHEAD_MS};
use crate::store::sync2::sql;
use crate::store::SrsCore;

const DAY_MS: i64 = 86_400_000;
/// SQLite 变量上限内的 IN 列表分块。
const CHUNK: usize = 400;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

// ------------------------------------------------------------------ 与 Dart 同口径的小工具

/// Dart `String.compareTo`：按 UTF-16 码元比较（代理对与 U+E000..U+FFFF 的先后与码点序不同）。
fn cmp16(a: &str, b: &str) -> Ordering {
    if a.is_ascii() && b.is_ascii() {
        return a.cmp(b);
    }
    a.encode_utf16().cmp(b.encode_utf16())
}

/// Dart VM `String.toLowerCase`：逐码点的简单小写映射（没有希腊文词尾 σ 的上下文规则；`İ` → `i`）。
fn dart_lower(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c == '\u{130}' {
            out.push('i');
        } else {
            out.extend(c.to_lowercase());
        }
    }
    out
}

/// Dart `String.trim`。
fn dart_trim(s: &str) -> &str {
    s.trim_matches(search::is_dart_trim_space)
}

/// 缓存行的 AnkiConnect 数字 id（v13 的 `anki_id` 列，写缓存行时算好）；万一还是 0（没回填的老行）就现算。
fn anki_id_of(stored: i64, uuid: &str) -> i64 {
    if stored != 0 {
        stored
    } else {
        crate::store::schema::anki_numeric_id(uuid)
    }
}

// ------------------------------------------------------------------ 会话里的行

const Q_NEW: u8 = 0;
const Q_LEARNING: u8 = 1;
const Q_REVIEW: u8 = 2;
const Q_RELEARNING: u8 = 3;

/// Dart `SrsQueue.parse`：不认识的当新卡。
fn queue_of(wire: &str) -> u8 {
    match wire {
        "learning" => Q_LEARNING,
        "review" => Q_REVIEW,
        "relearning" => Q_RELEARNING,
        _ => Q_NEW,
    }
}

#[derive(Clone, Debug, PartialEq)]
struct Card {
    id: String,
    note: String,
    tpl: String,
    cloze: i64,
    deck: String,
    suspended: bool,
    buried: Option<i64>,
    flag: i64,
    queue: u8,
    due_day: Option<i64>,
    due_at: Option<i64>,
    sched: i64,
    reps: i64,
    lapses: i64,
    stab: Option<f64>,
    diff: Option<f64>,
    last_rev: Option<i64>,
    /// AnkiConnect 数字 id。
    num: i64,
}

impl Card {
    /// 改了会动搜索语料结构（归属笔记、模板、牌组）。
    fn same_shape(&self, o: &Card) -> bool {
        self.note == o.note && self.tpl == o.tpl && self.cloze == o.cloze && self.deck == o.deck
    }
}

const CARD_COLUMNS: &str = "srs_idt(id), srs_idt(note_id), srs_idt(template_id), cloze_ord, srs_idt(deck_id), suspended, buried_until_day, flag, queue, \
     due_day, due_at, scheduled_days, reps, lapses, stability, difficulty, last_reviewed_at, anki_id";

fn card_of(r: &rusqlite::Row<'_>) -> rusqlite::Result<Card> {
    let queue: String = r.get(8)?;
    let id: String = r.get(0)?;
    Ok(Card {
        num: anki_id_of(r.get(17)?, &id),
        id,
        note: r.get(1)?,
        tpl: r.get(2)?,
        cloze: r.get(3)?,
        deck: r.get(4)?,
        suspended: r.get::<_, i64>(5)? != 0,
        buried: r.get(6)?,
        flag: r.get(7)?,
        queue: queue_of(&queue),
        due_day: r.get(9)?,
        due_at: r.get(10)?,
        sched: r.get(11)?,
        reps: r.get(12)?,
        lapses: r.get(13)?,
        stab: r.get(14)?,
        diff: r.get(15)?,
        last_rev: r.get(16)?,
    })
}

#[derive(Clone, Debug)]
struct Note {
    id: String,
    ty: String,
    created: i64,
    /// 排序字段（笔记缓存里去 HTML、trim 后的文本）。
    sort: String,
    tags: Vec<String>,
    pending: bool,
    /// 已装的字段原文：字段 id → 原文（没有记录的字段不在里面，读出时当空串）。
    values: HashMap<String, String>,
    /// 各寄存器生效记录的最大 HLC 物理时刻（[Session::full] 时有效；没有记录 = None）。
    modified: Option<i64>,
    /// AnkiConnect 数字 id。
    num: i64,
}

impl Note {
    fn same_shape(&self, o: &Note) -> bool {
        self.ty == o.ty && self.created == o.created && self.tags == o.tags
    }

    fn value(&self, field: &str) -> &str {
        self.values.get(field).map_or("", String::as_str)
    }

    /// Dart `srsEditsModifiedAt`：没有比创建时刻更晚的记录 = 创建时刻。
    fn modified_at(&self) -> i64 {
        self.modified.map_or(self.created, |m| m.max(self.created))
    }
}

const NOTE_COLUMNS: &str = "srs_idt(id), srs_idt(note_type_id), created_at, sort_field, tags_json, pending_decision, anki_id";

fn note_of(r: &rusqlite::Row<'_>) -> rusqlite::Result<Note> {
    let tags: String = r.get(4)?;
    let tags = match serde_json::from_str::<Value>(&tags) {
        Ok(Value::Array(a)) => a.into_iter().filter_map(|t| t.as_str().map(str::to_owned)).collect(),
        _ => Vec::new(),
    };
    let id: String = r.get(0)?;
    Ok(Note {
        num: anki_id_of(r.get(6)?, &id),
        id,
        ty: r.get(1)?,
        created: r.get(2)?,
        sort: r.get(3)?,
        tags,
        pending: r.get::<_, i64>(5)? != 0,
        values: HashMap::new(),
        modified: None,
    })
}

// ------------------------------------------------------------------ Dart 传来的上下文

/// 一个笔记类型（Dart `SrsNoteTypeView` 里浏览要的部分）。
#[derive(Debug)]
struct Type {
    name: String,
    cloze: bool,
    deleted: bool,
    /// 全部字段定义 (id, 名字)，按字段顺序。
    fields: Vec<(String, String)>,
    /// 搜索语料的字段排布：名字去重（首次出现的位置）、值取同名的最后一个字段（Dart `{名字: id}` 字面量的语义）。
    slot_names: Vec<String>,
    slot_ids: Vec<String>,
    slot_alias: Vec<Option<String>>,
    /// 模板 id → (名字, 序号)。
    tpls: HashMap<String, (String, i64)>,
}

impl Type {
    fn parse(v: &Value) -> Result<(String, Type), String> {
        let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned).ok_or_else(|| format!("browse: type missing {k}"));
        let id = s("id")?;
        let mut fields = Vec::new();
        let mut slot_names: Vec<String> = Vec::new();
        let mut slot_ids: Vec<String> = Vec::new();
        let mut alias: HashMap<String, String> = HashMap::new();
        for f in v.get("fields").and_then(Value::as_array).into_iter().flatten() {
            let fid = f.get(0).and_then(Value::as_str).ok_or("browse: bad field")?.to_owned();
            let name = f.get(1).and_then(Value::as_str).ok_or("browse: bad field")?.to_owned();
            if let Some(a) = f.get(2).and_then(Value::as_str) {
                alias.insert(name.clone(), a.to_owned());
            }
            match slot_names.iter().position(|n| *n == name) {
                Some(k) => slot_ids[k] = fid.clone(),
                None => {
                    slot_names.push(name.clone());
                    slot_ids.push(fid.clone());
                }
            }
            fields.push((fid, name));
        }
        let slot_alias = slot_names.iter().map(|n| alias.get(n).cloned()).collect();
        let mut tpls = HashMap::new();
        for t in v.get("tpls").and_then(Value::as_array).into_iter().flatten() {
            let tid = t.get(0).and_then(Value::as_str).ok_or("browse: bad template")?.to_owned();
            let name = t.get(1).and_then(Value::as_str).unwrap_or("").to_owned();
            let ord = t.get(2).and_then(Value::as_i64).unwrap_or(0);
            // 同一 id 出现两次时取第一个（Dart `where(...).firstOrNull`）。
            tpls.entry(tid).or_insert((name, ord));
        }
        Ok((
            id,
            Type {
                name: s("name")?,
                cloze: v.get("cloze").and_then(Value::as_bool).unwrap_or(false),
                deleted: v.get("deleted").and_then(Value::as_bool).unwrap_or(false),
                fields,
                slot_names,
                slot_ids,
                slot_alias,
                tpls,
            },
        ))
    }

    /// Dart `SrsCardSearchSubject.cardOrdinal`。
    fn ordinal(&self, c: &Card) -> i64 {
        if self.cloze {
            c.cloze
        } else {
            self.tpls.get(&c.tpl).map_or(0, |t| t.1) + 1
        }
    }

    fn template_name(&self, c: &Card) -> &str {
        self.tpls.get(&c.tpl).map_or("", |t| t.0.as_str())
    }

    /// 名字（不区分大小写）为 [lower] 的第一个字段的 id。
    fn field_named(&self, lower: &str) -> Option<&str> {
        self.fields.iter().find(|(_, n)| dart_lower(n) == lower).map(|(id, _)| id.as_str())
    }
}

#[derive(Debug)]
struct Ctx {
    types: HashMap<String, Type>,
    /// 牌组 id → (有效全名, 是否按 RWKV 此刻回忆率排队)；不在里面的牌组用 [fallback]（归默认牌组）。
    decks: HashMap<String, (String, bool)>,
    fallback: (String, bool),
    /// RWKV-Instant 此刻会出的卡；None = RWKV 不可用（照旧按存下的到期日）。
    instant: Option<HashSet<String>>,
    now: i64,
    day: Day,
    today: i64,
    /// 影响搜索语料结构的那部分原文（笔记类型、牌组名）：与 [View::ctx] 比较决定要不要重建语料。
    shape: Value,
}

impl Ctx {
    fn parse(req: &Value) -> Result<Ctx, String> {
        let i = |k: &str| req.get(k).and_then(Value::as_i64).ok_or_else(|| format!("browse: missing {k}"));
        let day = Day {
            utc_offset_min: i("utcOff")?,
            rollover_hour: i("rollover")?,
        };
        let now = i("now")?;
        let mut types = HashMap::new();
        for t in req.get("types").and_then(Value::as_array).into_iter().flatten() {
            let (id, ty) = Type::parse(t)?;
            types.entry(id).or_insert(ty);
        }
        let deck = |v: &Value| -> (String, bool) {
            (
                v.get(0).and_then(Value::as_str).unwrap_or("").to_owned(),
                v.get(1).and_then(Value::as_bool).unwrap_or(false),
            )
        };
        let decks = req
            .get("decks")
            .and_then(Value::as_object)
            .map(|m| m.iter().map(|(k, v)| (k.clone(), deck(v))).collect())
            .unwrap_or_default();
        let fallback = req.get("fallback").map(deck).unwrap_or_default();
        let instant = req
            .get("instant")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect());
        Ok(Ctx {
            types,
            decks,
            fallback,
            instant,
            now,
            day,
            today: day.index(now),
            shape: json!([req.get("types"), req.get("decks"), req.get("fallback")]),
        })
    }

    fn deck(&self, id: &str) -> &(String, bool) {
        self.decks.get(id).unwrap_or(&self.fallback)
    }

    fn day_start(&self, day: i64) -> i64 {
        day * DAY_MS + self.day.rollover_hour * 3_600_000 - self.day.utc_offset_min * 60_000
    }

    /// 复习卡按此刻回忆率排队（没有有意义的到期日）。
    fn by_recall(&self, c: &Card) -> bool {
        self.instant.is_some() && c.queue == Q_REVIEW && self.deck(&c.deck).1
    }

    fn instant_due(&self, c: &Card) -> bool {
        self.instant.as_ref().is_some_and(|s| s.contains(&c.id))
    }

    fn is_due(&self, c: &Card) -> bool {
        match c.queue {
            Q_NEW => false,
            Q_REVIEW if self.by_recall(c) => self.instant_due(c),
            Q_REVIEW => c.due_day.unwrap_or(0) <= self.today,
            _ => c.due_at.unwrap_or(0) <= self.now + LEARN_AHEAD_MS,
        }
    }

    fn is_buried(&self, c: &Card) -> bool {
        c.buried.is_some_and(|b| b > self.today)
    }

    /// Dart `dueInDays`（None = 没有到期日）。
    fn due_in_days(&self, c: &Card) -> Option<i64> {
        match c.queue {
            Q_NEW => None,
            Q_REVIEW if self.by_recall(c) => None,
            Q_REVIEW => c.due_day.map(|d| d - self.today),
            // rslib：(due - 明天日界) / 86400，整数除法向零截断。
            _ => c.due_at.map(|at| (at - self.day_start(self.today + 1)) / DAY_MS),
        }
    }

    /// Dart `dueSortKey`。
    fn due_sort_key(&self, c: &Card) -> f64 {
        match c.queue {
            Q_NEW => f64::INFINITY,
            Q_REVIEW if self.by_recall(c) => {
                if self.instant_due(c) {
                    self.today as f64
                } else {
                    f64::MAX
                }
            }
            Q_REVIEW => c.due_day.unwrap_or(self.today) as f64,
            _ => self.day.index(c.due_at.unwrap_or(self.now)) as f64 - 0.5,
        }
    }
}

fn interval_days(c: &Card) -> i64 {
    match c.queue {
        Q_NEW | Q_LEARNING => 0,
        _ => c.sched,
    }
}

// ------------------------------------------------------------------ 搜索语料

/// 由会话数据建的搜索语料与卡的自然顺序（笔记创建时刻、笔记 id、卡片序号、卡 id）。
///
/// **按笔记增量**：写过的笔记（字段、标签、换类型、增删卡、卡换牌组 / 模板、删除）只重做这几条笔记的语料条目
/// （旧条目移出、新条目追加，[View::refresh]）；会话新装的字段列补传进现有语料（[View::upload_columns]）。整份
/// 重建只在 Dart 传来的笔记类型结构 / 牌组名变了、或移出的条目攒得比活的还多时（[View::sparse]）。
struct View {
    shape: u64,
    ctx: Value,
    /// 语料卡 → 会话卡槽（[DEAD] = 已移出）。
    order: Vec<u32>,
    /// 语料卡 → 语料笔记；语料笔记 → 会话笔记槽。
    card_note: Vec<u32>,
    note_slot: Vec<u32>,
    /// 语料笔记 → 它的全部可见卡（语料卡下标，自然顺序；已移出的笔记为空）。
    note_cards: Vec<Vec<u32>>,
    /// 活的语料卡，按自然顺序。
    natural: Vec<u32>,
    /// 笔记 id → 它此刻的语料笔记。
    note_of: HashMap<String, u32>,
    corpus: Corpus,
    /// 语料的名字表（字符串 id → 原文）：把 [Needs::Names] 换回字段名；[at] 是反查。
    strings: Vec<String>,
    at: HashMap<String, u32>,
    /// 笔记类型 id → 字段排布下标（建时为每个未删除的笔记类型各排一份）。
    schema_of: HashMap<String, u32>,
    /// 已传进语料的字段值：全部字段（0x1f 紧挨着）/ 这几列。
    full: bool,
    fields: HashSet<String>,
}

/// [View::order] 里已移出的卡。
const DEAD: u32 = u32::MAX;

struct Interner {
    text: String,
    off: Vec<u32>,
    at: HashMap<String, u32>,
    strings: Vec<String>,
}

impl Interner {
    fn id(&mut self, s: &str) -> u32 {
        if let Some(&i) = self.at.get(s) {
            return i;
        }
        let i = self.strings.len() as u32;
        self.text.push_str(s);
        self.off.push(self.text.len() as u32);
        self.at.insert(s.to_owned(), i);
        self.strings.push(s.to_owned());
        i
    }
}

/// 自然顺序：笔记创建时刻、笔记 id、卡片序号、卡 id。
fn natural_cmp(s: &Session, ctx: &Ctx, a: u32, b: u32) -> Ordering {
    let (ca, cb) = (s.card(a), s.card(b));
    let (na, nb) = (s.note(s.note_at[&ca.note]), s.note(s.note_at[&cb.note]));
    na.created
        .cmp(&nb.created)
        .then_with(|| cmp16(&na.id, &nb.id))
        .then_with(|| ctx.types[&na.ty].ordinal(ca).cmp(&ctx.types[&nb.ty].ordinal(cb)))
        .then_with(|| cmp16(&ca.id, &cb.id))
}

impl View {
    fn build(s: &Session, ctx: &Ctx) -> Result<View, String> {
        // 可见卡：笔记在（未删除）、笔记类型在且没删。
        let mut order: Vec<u32> = Vec::new();
        for (slot, c) in s.cards.iter().enumerate() {
            let Some(c) = c else { continue };
            let Some(&ns) = s.note_at.get(&c.note) else { continue };
            if ctx.types.get(&s.note(ns).ty).is_some_and(|t| !t.deleted) {
                order.push(slot as u32);
            }
        }
        let ords: HashMap<u32, i64> = order
            .iter()
            .map(|&x| {
                let c = s.card(x);
                (x, ctx.types[&s.note(s.note_at[&c.note]).ty].ordinal(c))
            })
            .collect();
        order.sort_by(|&a, &b| {
            let (ca, cb) = (s.card(a), s.card(b));
            let (na, nb) = (s.note(s.note_at[&ca.note]), s.note(s.note_at[&cb.note]));
            na.created
                .cmp(&nb.created)
                .then_with(|| cmp16(&na.id, &nb.id))
                .then_with(|| ords[&a].cmp(&ords[&b]))
                .then_with(|| cmp16(&ca.id, &cb.id))
        });

        let mut it = Interner {
            text: String::new(),
            off: vec![0],
            at: HashMap::new(),
            strings: Vec::new(),
        };
        // 每个未删除的笔记类型都排一份字段（不只现有笔记用到的）：后来新增的笔记直接用，字段名表也不随笔记变。
        let mut type_ids: Vec<&String> = ctx.types.iter().filter(|(_, t)| !t.deleted).map(|(id, _)| id).collect();
        type_ids.sort();
        let mut schema_of: HashMap<String, u32> = HashMap::new();
        let mut schema_names: Vec<Vec<u32>> = Vec::new();
        let mut schema_alias: Vec<Vec<u32>> = Vec::new();
        for id in type_ids {
            let ty = &ctx.types[id];
            schema_of.insert(id.clone(), schema_names.len() as u32);
            schema_names.push(ty.slot_names.iter().map(|x| it.id(x)).collect());
            schema_alias.push(ty.slot_alias.iter().map(|a| a.as_deref().map_or(search::NO_ALIAS, |a| it.id(a))).collect());
        }
        let mut note_index: HashMap<u32, u32> = HashMap::new();
        let mut note_slot: Vec<u32> = Vec::new();
        let mut note_type: Vec<u32> = Vec::new();
        let mut note_schema: Vec<u32> = Vec::new();
        let mut note_tag_off: Vec<u32> = vec![0];
        let mut tag: Vec<u32> = Vec::new();
        let mut card_note: Vec<u32> = Vec::with_capacity(order.len());
        let mut card_deck: Vec<u32> = Vec::with_capacity(order.len());
        let mut card_tpl: Vec<u32> = Vec::with_capacity(order.len());
        let mut note_cards: Vec<Vec<u32>> = Vec::new();
        let mut note_of: HashMap<String, u32> = HashMap::new();
        for (vi, &slot) in order.iter().enumerate() {
            let c = s.card(slot);
            let ns = s.note_at[&c.note];
            let n = s.note(ns);
            let ty = &ctx.types[&n.ty];
            let vn = match note_index.get(&ns) {
                Some(&v) => v,
                None => {
                    let v = note_slot.len() as u32;
                    note_index.insert(ns, v);
                    note_of.insert(n.id.clone(), v);
                    note_slot.push(ns);
                    note_type.push(it.id(&ty.name));
                    note_schema.push(schema_of[&n.ty]);
                    for t in &n.tags {
                        tag.push(it.id(t));
                    }
                    note_tag_off.push(tag.len() as u32);
                    note_cards.push(Vec::new());
                    v
                }
            };
            note_cards[vn as usize].push(vi as u32);
            card_note.push(vn);
            card_deck.push(it.id(&ctx.deck(&c.deck).0));
            card_tpl.push(it.id(ty.template_name(c)));
        }
        let mut schema_off = vec![0u32];
        for names in &schema_names {
            schema_off.push(schema_off.last().unwrap() + names.len() as u32);
        }
        if it.text.len() > u32::MAX as usize {
            return Err("browse: corpus too large".into());
        }
        let mut words: Vec<u32> = vec![
            it.strings.len() as u32,
            schema_names.len() as u32,
            *schema_off.last().unwrap(),
            note_slot.len() as u32,
            tag.len() as u32,
            order.len() as u32,
        ];
        words.extend_from_slice(&it.off);
        words.extend_from_slice(&schema_off);
        for n in &schema_names {
            words.extend_from_slice(n);
        }
        for a in &schema_alias {
            words.extend_from_slice(a);
        }
        words.extend_from_slice(&note_type);
        words.extend_from_slice(&note_schema);
        words.extend_from_slice(&note_tag_off);
        words.extend_from_slice(&tag);
        words.extend_from_slice(&card_note);
        words.extend_from_slice(&card_deck);
        words.extend_from_slice(&card_tpl);
        let corpus = Corpus::new(it.text.as_bytes(), &words)?;
        let natural: Vec<u32> = (0..order.len() as u32).collect();
        let mut view = View {
            shape: s.shape,
            ctx: ctx.shape.clone(),
            order,
            card_note,
            note_slot,
            note_cards,
            natural,
            note_of,
            corpus,
            strings: it.strings,
            at: it.at,
            schema_of,
            full: s.full,
            fields: if s.full { HashSet::new() } else { s.fields.clone() },
        };
        let all: Vec<u32> = (0..view.note_slot.len() as u32).collect();
        let only = if s.full { None } else { Some(&s.fields) };
        if only.is_none_or(|f| !f.is_empty()) {
            view.upload(s, ctx, &all, only)?;
        }
        Ok(view)
    }

    fn intern(&mut self, s: &str) -> Result<u32, String> {
        if let Some(&i) = self.at.get(s) {
            return Ok(i);
        }
        let i = self.corpus.push_str(s)?;
        debug_assert_eq!(i as usize, self.strings.len());
        self.strings.push(s.to_owned());
        self.at.insert(s.to_owned(), i);
        Ok(i)
    }

    /// 把语料笔记 [notes] 的字段原文传进语料：[only] = None 传全部字段（同一条笔记的字段紧挨着、隔 0x1f，
    /// `n.flds` 直接切片），否则只传这几列。
    fn upload(&mut self, s: &Session, ctx: &Ctx, notes: &[u32], only: Option<&HashSet<String>>) -> Result<(), String> {
        let mut text = String::new();
        let mut fields: Vec<u32> = Vec::new();
        let mut spans: Vec<u32> = Vec::new();
        for &vn in notes {
            let n = s.note(self.note_slot[vn as usize]);
            let ty = &ctx.types[&n.ty];
            let range = self.corpus.note_fields(vn);
            for (k, fid) in ty.slot_ids.iter().enumerate().take(range.len()) {
                if only.is_some_and(|o| !o.contains(fid)) {
                    continue;
                }
                if only.is_none() && k > 0 {
                    text.push('\x1f');
                }
                let start = text.len();
                text.push_str(n.value(fid));
                if text.len() > u32::MAX as usize {
                    return Err("browse: field text too large".into());
                }
                fields.push((range.start + k) as u32);
                spans.push(start as u32);
                spans.push(text.len() as u32);
            }
        }
        if fields.is_empty() {
            return Ok(());
        }
        self.corpus.attach(text, &fields, &spans)
    }

    /// 活的语料笔记。
    fn live_notes(&self) -> Vec<u32> {
        let mut v: Vec<u32> = self.note_of.values().copied().collect();
        v.sort_unstable();
        v
    }

    /// 会话新装的字段列补传进语料（全部字段装了 = 整份重传，紧挨着排）。
    fn upload_columns(&mut self, s: &Session, ctx: &Ctx) -> Result<(), String> {
        if self.full {
            return Ok(());
        }
        if s.full {
            let live = self.live_notes();
            self.upload(s, ctx, &live, None)?;
            self.full = true;
            self.fields.clear();
            return Ok(());
        }
        let missing: HashSet<String> = s.fields.difference(&self.fields).cloned().collect();
        if missing.is_empty() {
            return Ok(());
        }
        let live = self.live_notes();
        self.upload(s, ctx, &live, Some(&missing))?;
        self.fields.extend(missing);
        Ok(())
    }

    /// 重做写过的笔记 [dirty]（笔记 id）的语料条目：旧条目连同它的卡移出，笔记还在、类型可见、有可见卡就追加
    /// 新条目，卡按自然顺序插进 [natural]。
    fn refresh(&mut self, s: &Session, ctx: &Ctx, dirty: &HashSet<String>) -> Result<(), String> {
        if dirty.is_empty() {
            return Ok(());
        }
        let mut killed: HashSet<u32> = HashSet::new();
        for id in dirty {
            let Some(vn) = self.note_of.remove(id) else { continue };
            for x in std::mem::take(&mut self.note_cards[vn as usize]) {
                self.order[x as usize] = DEAD;
                self.corpus.kill_card(x);
                killed.insert(x);
            }
            self.corpus.kill_note(vn);
        }
        if !killed.is_empty() {
            self.natural.retain(|x| !killed.contains(x));
        }
        // 写过的笔记此刻的可见卡（扫一遍会话卡）。
        let mut cards_of: HashMap<&str, Vec<u32>> = HashMap::new();
        for (slot, c) in s.cards.iter().enumerate() {
            if let Some(c) = c {
                if dirty.contains(&c.note) {
                    cards_of.entry(c.note.as_str()).or_default().push(slot as u32);
                }
            }
        }
        let mut added: Vec<u32> = Vec::new();
        let mut ids: Vec<&String> = dirty.iter().collect();
        ids.sort();
        for id in ids {
            let Some(&ns) = s.note_at.get(id) else { continue };
            let n = s.note(ns);
            let Some(ty) = ctx.types.get(&n.ty).filter(|t| !t.deleted) else { continue };
            let Some(mut cards) = cards_of.remove(id.as_str()) else { continue };
            let Some(&schema) = self.schema_of.get(&n.ty) else {
                return Err("browse: note type missing from the corpus layout".into());
            };
            cards.sort_by(|&a, &b| natural_cmp(s, ctx, a, b));
            let type_name = self.intern(&ty.name)?;
            let mut tags: Vec<u32> = Vec::with_capacity(n.tags.len());
            for t in &n.tags {
                tags.push(self.intern(t)?);
            }
            let vn = self.corpus.push_note(type_name, schema, &tags)?;
            debug_assert_eq!(vn as usize, self.note_slot.len());
            self.note_slot.push(ns);
            self.note_of.insert(id.clone(), vn);
            let mut mine: Vec<u32> = Vec::with_capacity(cards.len());
            for slot in cards {
                let c = s.card(slot);
                let deck = self.intern(&ctx.deck(&c.deck).0)?;
                let tpl = self.intern(ty.template_name(c))?;
                let x = self.corpus.push_card(vn, deck, tpl)?;
                debug_assert_eq!(x as usize, self.order.len());
                self.order.push(slot);
                self.card_note.push(vn);
                mine.push(x);
                // 插进自然顺序（二分：活的卡按自然顺序排着）。
                let at = self.natural.partition_point(|&y| natural_cmp(s, ctx, self.order[y as usize], slot) == Ordering::Less);
                self.natural.insert(at, x);
            }
            self.note_cards.push(mine);
            added.push(vn);
        }
        if !added.is_empty() {
            let fields = self.fields.clone();
            let only = if self.full { None } else { Some(&fields) };
            if only.is_none_or(|f| !f.is_empty()) {
                self.upload(s, ctx, &added, only)?;
            }
        }
        Ok(())
    }

    /// 移出的卡比活的还多：整份重建更省（下标、数值列都按语料卡数算）。
    fn sparse(&self) -> bool {
        self.corpus.dead_cards() > 1024 && self.corpus.dead_cards() > self.natural.len()
    }
}

// ------------------------------------------------------------------ 排序

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Column {
    SortField,
    Field,
    Due,
    Created,
    Modified,
    Interval,
    Difficulty,
    Reps,
    Lapses,
    Deck,
    NoteType,
}

impl Column {
    fn parse(s: &str) -> Result<Column, String> {
        Ok(match s {
            "sortField" => Column::SortField,
            "field" => Column::Field,
            "due" => Column::Due,
            "created" => Column::Created,
            "modified" => Column::Modified,
            "interval" => Column::Interval,
            "difficulty" => Column::Difficulty,
            "reps" => Column::Reps,
            "lapses" => Column::Lapses,
            "deck" => Column::Deck,
            "noteType" => Column::NoteType,
            _ => return Err(format!("browse: unknown sort column {s}")),
        })
    }
}

/// 一行在排序列上的值（Dart `Comparable`；None = 没有值，不论升降序都排最后）。
enum Key {
    None,
    Num(f64),
    Str(String),
}

fn cmp_keys(a: &Key, b: &Key, asc: bool) -> Ordering {
    let c = match (a, b) {
        (Key::None, Key::None) => return Ordering::Equal,
        (Key::None, _) => return Ordering::Greater,
        (_, Key::None) => return Ordering::Less,
        (Key::Num(x), Key::Num(y)) => x.total_cmp(y),
        (Key::Str(x), Key::Str(y)) => cmp16(x, y),
        // 同一列的值类型一致；万一不一致按 Dart 的报错前的样子随便定个序。
        (Key::Num(_), Key::Str(_)) => Ordering::Less,
        (Key::Str(_), Key::Num(_)) => Ordering::Greater,
    };
    if asc {
        c
    } else {
        c.reverse()
    }
}

// ------------------------------------------------------------------ 会话

/// 查询结果的一行：主卡（命中的第一张）与该行的全部卡（会话卡槽；卡片模式只有主卡）。
struct Row {
    primary: u32,
    note: u32,
    cards: Vec<u32>,
}

struct Res {
    gen: u64,
    cards_mode: bool,
    rows: Vec<Row>,
    ctx: Ctx,
    /// 结果之后会话又变过（重读到改动）：同一条查询要重算。
    stale: bool,
    /// 这次查询的参数原文（与下一次比较：没变、会话也没变就直接复用）。
    params: Value,
}

/// 各 profile 的浏览会话与它们的持有者。
///
/// 会话由浏览页（每个页面实例一个持有者）与 AnkiConnect 兼容层（一个持有者）共用：带 `owner` 的命令把它登记为
/// 持有者，`browse_close` 只注销发命令的那一个，**最后一个持有者注销才释放会话**（字段原文可达几百 MB）。
/// 选引用登记而不是「语料随内核常驻、按空闲 / 内存压力释放」：释放时机确定（页面关了、端点停了就还内存），
/// 不需要计时器，也不会在有人还在用时被回收。持有者表与会话分开存：会话出错丢掉、整份重建时持有者照旧。
#[derive(Default)]
pub(crate) struct Sessions {
    live: HashMap<String, Session>,
    owners: HashMap<String, HashSet<String>>,
    /// 整份建会话的次数（`browse_stats`）。
    built: u64,
}

/// 一个 profile 的浏览会话。
pub(crate) struct Session {
    cards: Vec<Option<Card>>,
    card_at: HashMap<String, u32>,
    notes: Vec<Option<Note>>,
    note_at: HashMap<String, u32>,
    /// 全部字段原文与最后改动时刻都已装。
    full: bool,
    /// 已为全部笔记装好的字段（[full] 时不用看）。
    fields: HashSet<String>,
    /// 结构版本：变了搜索语料就要整份重建（现在只有出错重建时用；写入走 [view_dirty] 按笔记增量）。
    shape: u64,
    view: Option<View>,
    /// 语料建好之后写过的笔记（含增删卡、卡换牌组 / 模板的那几条笔记）：下次用语料前重做它们的条目。
    view_dirty: HashSet<String>,
    /// 整份建语料的次数（`browse_stats`：测试据此确认写入走的是增量）。
    builds: u64,
    /// 最近几次查询的结果（新的在后；浏览页与控制通道可以同时各持一份）。
    results: Vec<Res>,
}

/// 一个会话留几份查询结果。
const KEEP_RESULTS: usize = 4;

static GEN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);


impl Session {
    fn build(c: &Connection, profile: &str) -> Result<Session, String> {
        let mut s = Session {
            cards: Vec::new(),
            card_at: HashMap::new(),
            notes: Vec::new(),
            note_at: HashMap::new(),
            full: false,
            fields: HashSet::new(),
            shape: 0,
            view: None,
            view_dirty: HashSet::new(),
            builds: 0,
            results: Vec::new(),
        };
        {
            let q = format!("SELECT {NOTE_COLUMNS} FROM srs_notes_cache WHERE profile_uid = srs_id(?1) AND deleted_at IS NULL");
            let mut stmt = c.prepare_cached(&q).map_err(sql)?;
            let mut rows = stmt.query([profile]).map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                let n = note_of(r).map_err(sql)?;
                s.note_at.insert(n.id.clone(), s.notes.len() as u32);
                s.notes.push(Some(n));
            }
        }
        let q = format!("SELECT {CARD_COLUMNS} FROM srs_cards_cache WHERE profile_uid = srs_id(?1) AND hidden = 0");
        let mut stmt = c.prepare_cached(&q).map_err(sql)?;
        let mut rows = stmt.query([profile]).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            let card = card_of(r).map_err(sql)?;
            s.card_at.insert(card.id.clone(), s.cards.len() as u32);
            s.cards.push(Some(card));
        }
        Ok(s)
    }

    /// 按 id 重读写过的卡 / 笔记（以库里的行为准；行没了或不再可见就移出会话）。
    fn apply(&mut self, c: &Connection, profile: &str, d: &Dirty) -> Result<(), String> {
        if d.cards.is_empty() && d.notes.is_empty() {
            return Ok(());
        }
        for r in &mut self.results {
            r.stale = true;
        }
        let ids: Vec<&String> = d.cards.iter().collect();
        for chunk in ids.chunks(CHUNK) {
            let q = format!(
                "SELECT {CARD_COLUMNS} FROM srs_cards_cache WHERE id IN ({}) AND +profile_uid = srs_id(?1) AND +hidden = 0",
                (2..chunk.len() + 2).map(|i| format!("srs_id(?{i})")).collect::<Vec<_>>().join(", ")
            );
            let mut stmt = c.prepare_cached(&q).map_err(sql)?;
            let args = std::iter::once(profile).chain(chunk.iter().map(|s| s.as_str()));
            let mut found: HashMap<String, Card> = HashMap::new();
            let mut rows = stmt.query(params_from_iter(args)).map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                let card = card_of(r).map_err(sql)?;
                found.insert(card.id.clone(), card);
            }
            for &id in chunk {
                match (found.remove(id), self.card_at.get(id).copied()) {
                    (Some(card), Some(slot)) => {
                        let old = self.cards[slot as usize].as_ref().expect("indexed card");
                        if !old.same_shape(&card) {
                            self.view_dirty.insert(old.note.clone());
                            self.view_dirty.insert(card.note.clone());
                        }
                        self.cards[slot as usize] = Some(card);
                    }
                    (Some(card), None) => {
                        self.card_at.insert(id.clone(), self.cards.len() as u32);
                        self.view_dirty.insert(card.note.clone());
                        self.cards.push(Some(card));
                    }
                    (None, Some(slot)) => {
                        self.card_at.remove(id);
                        if let Some(old) = self.cards[slot as usize].take() {
                            self.view_dirty.insert(old.note);
                        }
                    }
                    (None, None) => {}
                }
            }
        }
        let ids: Vec<&String> = d.notes.iter().collect();
        let mut present: Vec<String> = Vec::new();
        for chunk in ids.chunks(CHUNK) {
            let q = format!(
                "SELECT {NOTE_COLUMNS} FROM srs_notes_cache WHERE id IN ({}) AND +profile_uid = srs_id(?1) AND deleted_at IS NULL",
                (2..chunk.len() + 2).map(|i| format!("srs_id(?{i})")).collect::<Vec<_>>().join(", ")
            );
            let mut stmt = c.prepare_cached(&q).map_err(sql)?;
            let args = std::iter::once(profile).chain(chunk.iter().map(|s| s.as_str()));
            let mut found: HashMap<String, Note> = HashMap::new();
            let mut rows = stmt.query(params_from_iter(args)).map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                let n = note_of(r).map_err(sql)?;
                found.insert(n.id.clone(), n);
            }
            for &id in chunk {
                match (found.remove(id), self.note_at.get(id).copied()) {
                    (Some(n), Some(slot)) => {
                        let old = self.notes[slot as usize].as_ref().expect("indexed note");
                        if !old.same_shape(&n) {
                            self.view_dirty.insert(id.clone());
                        }
                        self.notes[slot as usize] = Some(n);
                        present.push(id.clone());
                    }
                    (Some(n), None) => {
                        self.note_at.insert(id.clone(), self.notes.len() as u32);
                        self.notes.push(Some(n));
                        self.view_dirty.insert(id.clone());
                        present.push(id.clone());
                    }
                    (None, Some(slot)) => {
                        self.note_at.remove(id);
                        self.notes[slot as usize] = None;
                        self.view_dirty.insert(id.clone());
                    }
                    (None, None) => {}
                }
            }
        }
        // 写过的笔记：已装的字段列 / 最后改动时刻按库里的修改记录重读（字段值在语料里：这几条笔记的条目重做）。
        if !present.is_empty() && (self.full || !self.fields.is_empty()) {
            let keys: Option<Vec<String>> = if self.full { None } else { Some(self.fields.iter().cloned().collect()) };
            self.load_values(c, profile, Some(&present), keys.as_deref())?;
            self.view_dirty.extend(present);
        }
        Ok(())
    }

    /// 从修改记录读字段原文（[notes] = None：全部笔记；[keys] = None：全部字段 + 最后改动时刻）。
    fn load_values(&mut self, c: &Connection, profile: &str, notes: Option<&[String]>, keys: Option<&[String]>) -> Result<(), String> {
        // 先清掉要重读的那部分：没有记录的字段读出时当空串。
        let reset = |n: &mut Note| match keys {
            None => {
                n.values.clear();
                n.modified = None;
            }
            Some(ks) => {
                for k in ks {
                    n.values.remove(k);
                }
            }
        };
        match notes {
            None => self.notes.iter_mut().flatten().for_each(reset),
            Some(ids) => {
                for id in ids {
                    if let Some(&slot) = self.note_at.get(id) {
                        reset(self.notes[slot as usize].as_mut().expect("indexed note"));
                    }
                }
            }
        }
        let key_filter = |first: usize, n: usize| {
            if n == 0 {
                String::new()
            } else {
                format!(" AND f.field_key IN ({})", (first..first + n).map(|i| format!("?{i}")).collect::<Vec<_>>().join(", "))
            }
        };
        let key_args: Vec<String> = keys.map(|ks| ks.iter().map(|k| format!("f/{k}")).collect()).unwrap_or_default();
        let run = |c: &Connection, q: &str, args: Vec<Sql>, s: &mut Session| -> Result<(), String> {
            let mut stmt = c.prepare_cached(q).map_err(sql)?;
            let mut rows = stmt.query(params_from_iter(args)).map_err(sql)?;
            let mut cur: Option<String> = None;
            let mut edits: Vec<(String, Option<i64>, Option<registers::EditCols>)> = Vec::new();
            let flush = |id: Option<String>, edits: &mut Vec<(String, Option<i64>, Option<registers::EditCols>)>, s: &mut Session| -> Result<(), String> {
                let Some(id) = id else { return Ok(()) };
                let stored: Vec<StoredEdit<'_>> = edits.iter().map(|(j, t, c)| (j.as_str(), *t, c.as_ref())).collect();
                let (values, modified) = registers::note_browse_values(&stored)?;
                edits.clear();
                let Some(&slot) = s.note_at.get(&id) else { return Ok(()) };
                let n = s.notes[slot as usize].as_mut().expect("indexed note");
                if keys.is_none() {
                    n.modified = modified;
                }
                for (k, v) in values {
                    n.values.insert(k, v);
                }
                Ok(())
            };
            while let Some(r) = rows.next().map_err(sql)? {
                let id: String = r.get(0).map_err(sql)?;
                if cur.as_deref() != Some(id.as_str()) {
                    flush(cur.take(), &mut edits, s)?;
                    cur = Some(id);
                }
                let (j, cols) = super::slim::edit_row(r, 2).map_err(sql)?;
                edits.push((j, r.get(1).map_err(sql)?, cols));
            }
            flush(cur.take(), &mut edits, s)
        };
        // 修改记录读 `jslim` + 列（store/slim.rs `EDIT_READ`），不经逐行拼回的 `json`。
        const SELECT: &str = "SELECT srs_idt(f.entity_id) AS entity_id, s.server_time, \
             f.jslim, f.id, f.profile_uid, f.entity_kind, f.entity_id, f.field_key, f.writer_id, f.seq FROM srs_field_edits f \
             LEFT JOIN srs_event_local s ON s.event_id = f.id WHERE f.entity_kind = 'note'";
        match notes {
            None => {
                // 整列：按 (entity_kind, entity_id) 顺序读（实测 5 万笔记库比走 (profile_uid, entity_kind, entity_id,
                // field_key) 索引快一倍多：那条按笔记顺序逐行回表是随机读；两种走法摸到的表页一样多——一列的记录
                // 散在全部笔记的记录之间）。
                let q = format!("{SELECT} AND +f.profile_uid = srs_id(?1){} ORDER BY f.entity_id", key_filter(2, key_args.len()));
                let args: Vec<Sql> =
                    std::iter::once(Sql::Text(profile.to_owned())).chain(key_args.iter().map(|k| Sql::Text(k.clone()))).collect();
                run(c, &q, args, self)?;
            }
            Some(ids) => {
                for chunk in ids.chunks(CHUNK) {
                    let q = format!(
                        "{SELECT} AND f.entity_id IN ({}) AND +f.profile_uid = srs_id(?1){} ORDER BY f.entity_id",
                        (2..chunk.len() + 2).map(|i| format!("srs_id(?{i})")).collect::<Vec<_>>().join(", "),
                        key_filter(chunk.len() + 2, key_args.len())
                    );
                    let args: Vec<Sql> = std::iter::once(Sql::Text(profile.to_owned()))
                        .chain(chunk.iter().map(|k| Sql::Text(k.clone())))
                        .chain(key_args.iter().map(|k| Sql::Text(k.clone())))
                        .collect();
                    run(c, &q, args, self)?;
                }
            }
        }
        Ok(())
    }

    /// 装好 [want] 要的字段列（None = 全部字段 + 最后改动时刻）。装了新列结构就变了。
    fn ensure_fields(&mut self, c: &Connection, profile: &str, want: Option<&HashSet<String>>) -> Result<(), String> {
        if self.full {
            return Ok(());
        }
        match want {
            None => {
                self.load_values(c, profile, None, None)?;
                self.full = true;
                self.fields.clear();
            }
            Some(ids) => {
                let missing: Vec<String> = ids.iter().filter(|f| !self.fields.contains(*f)).cloned().collect();
                if missing.is_empty() {
                    return Ok(());
                }
                self.load_values(c, profile, None, Some(&missing))?;
                self.fields.extend(missing);
            }
        }
        Ok(())
    }

    /// 语料对上会话此刻：结构 / 上下文没变就按笔记增量补（写过的笔记、新装的字段列），否则（或移出的条目太多）
    /// 整份重建。
    fn ensure_view(&mut self, ctx: &Ctx) -> Result<(), String> {
        let reusable = self.view.as_ref().is_some_and(|v| v.shape == self.shape && v.ctx == ctx.shape);
        if reusable {
            let mut v = self.view.take().expect("checked above");
            let dirty = std::mem::take(&mut self.view_dirty);
            v.upload_columns(self, ctx)?;
            v.refresh(self, ctx, &dirty)?;
            if !v.sparse() {
                self.view = Some(v);
                return Ok(());
            }
        }
        self.view = None;
        self.view_dirty.clear();
        self.view = Some(View::build(self, ctx)?);
        self.builds += 1;
        Ok(())
    }

    fn card(&self, slot: u32) -> &Card {
        self.cards[slot as usize].as_ref().expect("visible card")
    }

    fn note(&self, slot: u32) -> &Note {
        self.notes[slot as usize].as_ref().expect("visible note")
    }

    /// 一条查询：筛选（`node` = 搜索语法树 JSON，没有 = 全部）、排序、按模式成行。
    fn query(&mut self, c: &Connection, profile: &str, req: &Value) -> Result<Value, String> {
        let ctx = Ctx::parse(req)?;
        let node = req.get("node").filter(|n| !n.is_null() && n.get("t").and_then(Value::as_str) != Some("all"));
        let sort = req.get("sort").cloned().unwrap_or(Value::Null);
        let column = Column::parse(sort.get("col").and_then(Value::as_str).unwrap_or("created"))?;
        let asc = sort.get("asc").and_then(Value::as_bool).unwrap_or(false);
        let field = sort.get("field").and_then(Value::as_str).map(dart_lower);
        let cards_mode = req.get("mode").and_then(Value::as_str) != Some("notes");
        let params = json!([req.get("node"), sort, cards_mode, req.get("types"), req.get("decks"), req.get("fallback"), req.get("instant"), ctx.today, ctx.now]);

        // 按修改时间排序要的最后改动时刻、按字段排序要的那一列：与查询要的列一起先装齐再求值。
        let full = column == Column::Modified;
        let mut want: HashSet<String> = HashSet::new();
        if column == Column::Field {
            if let Some(f) = &field {
                for t in ctx.types.values() {
                    if let Some(id) = t.field_named(f) {
                        want.insert(id.to_owned());
                    }
                }
            }
        }
        let hits = match self.hits(c, profile, &ctx, node, full, want)? {
            Ok(h) => h,
            Err(e) => return Ok(search_error(e)),
        };
        let view = self.view.as_ref().expect("view");
        // 行：卡片模式一张卡一行；笔记模式每条笔记命中的第一张卡为主卡，该行是笔记的全部可见卡。
        let mut rows: Vec<(u32, Vec<u32>)> = Vec::with_capacity(hits.len());
        if cards_mode {
            rows.extend(hits.iter().map(|&h| (h, vec![h])));
        } else {
            let mut seen = vec![false; view.note_slot.len()];
            for &h in &hits {
                let vn = view.card_note[h as usize] as usize;
                if !seen[vn] {
                    seen[vn] = true;
                    rows.push((h, view.note_cards[vn].clone()));
                }
            }
        }
        let keys: Vec<Key> = rows.iter().map(|(p, cs)| self.sort_key(view, &ctx, column, field.as_deref(), *p, cs)).collect();
        let mut idx: Vec<usize> = (0..rows.len()).collect();
        // 值相同按自然顺序（行本身按命中的自然顺序排着）。
        idx.sort_by(|&a, &b| cmp_keys(&keys[a], &keys[b], asc).then_with(|| a.cmp(&b)));
        let out_rows: Vec<Row> = idx
            .into_iter()
            .map(|i| {
                let (p, cs) = &rows[i];
                Row {
                    primary: view.order[*p as usize],
                    note: view.note_slot[view.card_note[*p as usize] as usize],
                    cards: cs.iter().map(|&x| view.order[x as usize]).collect(),
                }
            })
            .collect();
        let gen = GEN.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let count = out_rows.len();
        let total = view.natural.len();
        if self.results.len() >= KEEP_RESULTS {
            self.results.remove(0);
        }
        self.results.push(Res {
            gen,
            cards_mode,
            rows: out_rows,
            ctx,
            stale: false,
            params,
        });
        Ok(json!({"gen": gen, "count": count, "cards": total}))
    }

    /// 筛选：装齐查询要的数据（[full] / [want] 是调用方另外要装的：全部字段 + 最后改动时刻 / 这几个字段列），
    /// 求值，交回命中的语料卡下标（自然顺序）。查询本身不合法 / 内核不可用时交回 `Ok(Err(..))`。
    fn hits(
        &mut self,
        c: &Connection,
        profile: &str,
        ctx: &Ctx,
        node: Option<&Value>,
        mut full: bool,
        mut want: HashSet<String>,
    ) -> Result<Result<Vec<u32>, search::SearchError>, String> {
        self.ensure_view(ctx)?;
        let query = node.map(|n| n.to_string());
        if let Some(n) = node {
            if uses(n, "edited") {
                full = true;
            }
            let q = query.as_deref().unwrap_or_default();
            let view = self.view.as_ref().expect("view");
            match view.corpus.needs(q) {
                Ok(Needs::All) => full = true,
                Ok(Needs::Names(ids)) => {
                    let names: HashSet<&str> = ids.iter().map(|&i| view.strings[i as usize].as_str()).collect();
                    for t in ctx.types.values() {
                        for (k, name) in t.slot_names.iter().enumerate() {
                            if names.contains(name.as_str()) {
                                want.insert(t.slot_ids[k].clone());
                            }
                        }
                    }
                }
                Err(e) => return Ok(Err(e)),
            }
        }
        if full {
            self.ensure_fields(c, profile, None)?;
        } else if !want.is_empty() {
            self.ensure_fields(c, profile, Some(&want))?;
        }
        self.ensure_view(ctx)?;
        Ok(match &query {
            None => Ok(self.view.as_ref().expect("view").natural.clone()),
            Some(q) => {
                self.set_columns(ctx, q)?;
                let view = self.view.as_ref().expect("view");
                let mut out = vec![0u8; view.order.len()];
                match view.corpus.search(q, &mut out) {
                    Err(e) => Err(e),
                    Ok(_) => Ok(view.natural.iter().copied().filter(|&i| out[i as usize] != 0).collect()),
                }
            }
        })
    }

    /// 每次查询按此刻现算的数值列（语料的 [search::IntColumn] / [search::FloatColumn]）：只算查询 [q] 真用到的
    /// 那几列（`deck:*`、`tag:` 这类只看结构的查询一列都不用算）。
    fn set_columns(&mut self, ctx: &Ctx, q: &str) -> Result<(), String> {
        let (ints, floats) = match Corpus::columns_used(q) {
            Ok(m) => m,
            // 查询本身不合法：留给求值报出同一个错误。
            Err(_) => return Ok(()),
        };
        if ints == 0 && floats == 0 {
            return Ok(());
        }
        let full = self.full;
        let view = self.view.as_mut().expect("view");
        let n = view.order.len();
        let want = |k: usize| ints & (1 << k) != 0;
        let mut cols: Vec<Vec<i64>> =
            (0..search::INT_COLUMNS).map(|k| if want(k) { Vec::with_capacity(n) } else { Vec::new() }).collect();
        let (want_stab, want_diff) = (floats & 1 != 0, floats & 2 != 0);
        let mut stab = Vec::with_capacity(if want_stab { n } else { 0 });
        let mut diff = Vec::with_capacity(if want_diff { n } else { 0 });
        for (i, &slot) in view.order.iter().enumerate() {
            if slot == DEAD {
                for (k, col) in cols.iter_mut().enumerate() {
                    if want(k) {
                        col.push(0);
                    }
                }
                if want_stab {
                    stab.push(f64::NAN);
                }
                if want_diff {
                    diff.push(f64::NAN);
                }
                continue;
            }
            let c = self.cards[slot as usize].as_ref().expect("visible card");
            let note = self.notes[view.note_slot[view.card_note[i] as usize] as usize].as_ref().expect("visible note");
            let ty = &ctx.types[&note.ty];
            for (k, col) in cols.iter_mut().enumerate() {
                if !want(k) {
                    continue;
                }
                col.push(match k {
                    0 => {
                        let learn = c.queue == Q_LEARNING || c.queue == Q_RELEARNING;
                        let review = c.queue == Q_REVIEW || c.queue == Q_RELEARNING;
                        i64::from(c.queue == Q_NEW)
                            | (i64::from(learn) << 1)
                            | (i64::from(review) << 2)
                            | (i64::from(ctx.is_due(c)) << 3)
                            | (i64::from(c.suspended) << 4)
                            | (i64::from(ctx.is_buried(c)) << 5)
                    }
                    1 => note.num,
                    2 => c.num,
                    3 => ctx.day.index(note.created),
                    // 没装最后改动时刻时不会走到这里（`edited:` 查询先装好全部字段）。
                    4 => {
                        if full {
                            ctx.day.index(note.modified_at())
                        } else {
                            0
                        }
                    }
                    5 => ctx.today,
                    6 => c.flag,
                    7 => ty.ordinal(c),
                    8 => interval_days(c),
                    9 => ctx.due_in_days(c).unwrap_or(DUE_NONE),
                    10 => c.reps,
                    _ => c.lapses,
                });
            }
            if want_stab {
                stab.push(c.stab.unwrap_or(f64::NAN));
            }
            if want_diff {
                diff.push(c.diff.unwrap_or(f64::NAN));
            }
        }
        for (k, col) in cols.iter().enumerate() {
            if want(k) {
                view.corpus.set_ints(k, col)?;
            }
        }
        if want_stab {
            view.corpus.set_floats(0, &stab)?;
        }
        if want_diff {
            view.corpus.set_floats(1, &diff)?;
        }
        Ok(())
    }

    fn sort_key(&self, view: &View, ctx: &Ctx, column: Column, field: Option<&str>, primary: u32, cs: &[u32]) -> Key {
        let p = self.card(view.order[primary as usize]);
        let note = self.note(view.note_slot[view.card_note[primary as usize] as usize]);
        let cards = || cs.iter().map(|&x| self.card(view.order[x as usize]));
        let notes = cs.len() > 1;
        let avg = |vals: Vec<f64>| -> Key {
            if vals.is_empty() {
                Key::None
            } else {
                let mut sum = vals[0];
                for v in &vals[1..] {
                    sum += v;
                }
                Key::Num(sum / vals.len() as f64)
            }
        };
        match column {
            Column::SortField => Key::Str(dart_lower(&note.sort)),
            Column::Field => {
                let Some(f) = field else { return Key::None };
                match ctx.types[&note.ty].field_named(f) {
                    Some(id) => Key::Str(dart_lower(dart_trim(&search::strip_html(note.value(id))))),
                    None => Key::None,
                }
            }
            Column::Due => Key::Num(cards().map(|c| ctx.due_sort_key(c)).fold(f64::INFINITY, |a, b| if b < a { b } else { a })),
            Column::Created => Key::Num(note.created as f64),
            Column::Modified => {
                let mut m = note.modified_at();
                for c in cards() {
                    if let Some(r) = c.last_rev {
                        if r > m {
                            m = r;
                        }
                    }
                }
                Key::Num(m as f64)
            }
            Column::Interval => {
                if notes {
                    avg(cards().map(|c| interval_days(c) as f64).collect())
                } else {
                    Key::Num(interval_days(p) as f64)
                }
            }
            Column::Difficulty => {
                if notes {
                    avg(cards().filter_map(|c| c.diff).collect())
                } else {
                    p.diff.map_or(Key::None, Key::Num)
                }
            }
            Column::Reps => Key::Num(cards().map(|c| c.reps).sum::<i64>() as f64),
            Column::Lapses => Key::Num(cards().map(|c| c.lapses).sum::<i64>() as f64),
            Column::Deck => Key::Str(dart_lower(&ctx.deck(&p.deck).0)),
            Column::NoteType => Key::Str(dart_lower(&ctx.types[&note.ty].name)),
        }
    }

    fn result(&self, req: &Value) -> Result<&Res, String> {
        let gen = req.get("gen").and_then(Value::as_u64).ok_or("browse: missing gen")?;
        self.results.iter().find(|r| r.gen == gen).ok_or_else(|| format!("browse: result {gen} is gone"))
    }

    /// 结果的一段行（`from..to`）：字符串列走 JSON（`[卡 id, 笔记 id, 排序字段, 牌组名, 笔记类型名, 牌组 id, 模板名, 标签]`），数值列每行 7 个 i64（小端）放进
    /// `rows.i64`：`[队列 (0 新 / 1 学习 / 2 复习 / 3 重学；-1 = 卡已不在), 到期天数 (i64::MIN = 没有), 旗标,
    /// 位 (1 暂停 / 2 搁置 / 4 待裁决), 该行卡数, 复习次数, 遗忘次数]`。行的数据取会话里**此刻**的值（结果之后的写入已重读进来）。
    fn rows(&self, req: &Value, files: &mut Vec<(String, Vec<u8>)>) -> Result<Value, String> {
        let r = self.result(req)?;
        let from = (req.get("from").and_then(Value::as_u64).unwrap_or(0) as usize).min(r.rows.len());
        let to = (req.get("to").and_then(Value::as_u64).map_or(r.rows.len(), |t| t as usize)).clamp(from, r.rows.len());
        let mut strings: Vec<Value> = Vec::with_capacity(to - from);
        let mut ints: Vec<u8> = Vec::with_capacity((to - from) * 56);
        for row in &r.rows[from..to] {
            let c = self.cards[row.primary as usize].as_ref();
            let n = self.notes[row.note as usize].as_ref();
            let (Some(c), Some(n)) = (c, n) else {
                strings.push(json!(["", "", "", "", "", "", "", []]));
                for v in [-1i64, DUE_NONE, 0, 0, 0, 0, 0] {
                    ints.extend_from_slice(&v.to_le_bytes());
                }
                continue;
            };
            let ty = r.ctx.types.get(&n.ty);
            strings.push(json!([
                c.id,
                n.id,
                n.sort,
                r.ctx.deck(&c.deck).0,
                ty.map_or("", |t| t.name.as_str()),
                c.deck,
                ty.map_or("", |t| t.template_name(c)),
                n.tags,
            ]));
            let bits = i64::from(c.suspended) | (i64::from(r.ctx.is_buried(c)) << 1) | (i64::from(n.pending) << 2);
            for v in [
                i64::from(c.queue),
                r.ctx.due_in_days(c).unwrap_or(DUE_NONE),
                c.flag,
                bits,
                row.cards.len() as i64,
                c.reps,
                c.lapses,
            ] {
                ints.extend_from_slice(&v.to_le_bytes());
            }
        }
        files.push(("rows.i64".to_owned(), ints));
        Ok(json!({"s": strings}))
    }

    fn row_id(&self, r: &Res, row: &Row) -> Option<&str> {
        if r.cards_mode {
            self.cards[row.primary as usize].as_ref().map(|c| c.id.as_str())
        } else {
            self.notes[row.note as usize].as_ref().map(|n| n.id.as_str())
        }
    }

    /// 行 id（卡片模式 = 主卡 id，笔记模式 = 笔记 id）：`from..to`，或 `find` 给的那几个 id 各在第几行（没有 = -1）。
    fn ids(&self, req: &Value) -> Result<Value, String> {
        let r = self.result(req)?;
        if let Some(find) = req.get("find").and_then(Value::as_array) {
            let mut at: HashMap<&str, usize> = HashMap::with_capacity(r.rows.len());
            for (i, row) in r.rows.iter().enumerate() {
                if let Some(id) = self.row_id(r, row) {
                    at.entry(id).or_insert(i);
                }
            }
            let out: Vec<i64> = find.iter().map(|v| v.as_str().and_then(|s| at.get(s)).map_or(-1, |&i| i as i64)).collect();
            return Ok(json!({"at": out}));
        }
        let from = (req.get("from").and_then(Value::as_u64).unwrap_or(0) as usize).min(r.rows.len());
        let to = (req.get("to").and_then(Value::as_u64).map_or(r.rows.len(), |t| t as usize)).clamp(from, r.rows.len());
        let ids: Vec<&str> = r.rows[from..to].iter().map(|row| self.row_id(r, row).unwrap_or("")).collect();
        Ok(json!({"ids": ids}))
    }

    /// 批量操作的目标：`ids`（行 id）对应的行按结果顺序展开成卡 / 笔记 id，连同这些卡是否全暂停 / 全搁置、
    /// 出现过的旗标与牌组。
    fn targets(&self, req: &Value) -> Result<Value, String> {
        let r = self.result(req)?;
        let want: HashSet<&str> = req.get("ids").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).collect();
        let mut cards: Vec<&str> = Vec::new();
        let mut notes: Vec<&str> = Vec::new();
        let mut seen_notes: HashSet<&str> = HashSet::new();
        let (mut all_suspended, mut all_buried) = (true, true);
        let mut flags: Vec<i64> = Vec::new();
        let mut decks: Vec<&str> = Vec::new();
        for row in &r.rows {
            if !self.row_id(r, row).is_some_and(|id| want.contains(id)) {
                continue;
            }
            let Some(n) = self.notes[row.note as usize].as_ref() else { continue };
            if seen_notes.insert(n.id.as_str()) {
                notes.push(n.id.as_str());
            }
            for &slot in &row.cards {
                let Some(c) = self.cards[slot as usize].as_ref() else { continue };
                cards.push(c.id.as_str());
                all_suspended &= c.suspended;
                all_buried &= r.ctx.is_buried(c);
                if !flags.contains(&c.flag) {
                    flags.push(c.flag);
                }
                if !decks.contains(&c.deck.as_str()) {
                    decks.push(c.deck.as_str());
                }
            }
        }
        Ok(json!({
            "cards": cards,
            "notes": notes,
            "allSuspended": all_suspended,
            "allBuried": all_buried,
            "flags": flags,
            "decks": decks,
        }))
    }

    // ------------------------------------------------------------------ AnkiConnect

    /// `anki_find`：findNotes / findCards。`node` = 搜索语法树（没有 = 全部），`mode` = `notes` / `cards`；上下文
    /// （笔记类型、牌组名、此刻、日界）同浏览查询，不带 `instant`（AnkiConnect 的 `is:due` 照存下的到期日）。
    /// 命中按自然顺序（笔记创建时刻、笔记 id、卡片序号）：卡片模式每张命中的卡一个，笔记模式每条命中的笔记一个
    /// （第一次出现的位置）。数字 id 放进 `ids.i64`（小端 i64）；`uuids` 为真时另回卡 id 原文（guiBrowse 用）。
    /// 不留查询结果（不挤掉浏览页的结果）。
    fn anki_find(&mut self, c: &Connection, profile: &str, req: &Value, files: &mut Vec<(String, Vec<u8>)>) -> Result<Value, String> {
        let ctx = Ctx::parse(req)?;
        let node = req.get("node").filter(|n| !n.is_null() && n.get("t").and_then(Value::as_str) != Some("all"));
        let notes = req.get("mode").and_then(Value::as_str) == Some("notes");
        let hits = match self.hits(c, profile, &ctx, node, false, HashSet::new())? {
            Ok(h) => h,
            Err(e) => return Ok(search_error(e)),
        };
        let view = self.view.as_ref().expect("view");
        let mut bytes: Vec<u8> = Vec::with_capacity(hits.len() * 8);
        let mut uuids: Vec<&str> = Vec::new();
        let want_uuids = req.get("uuids").and_then(Value::as_bool).unwrap_or(false);
        let mut last: Option<u32> = None;
        for &h in &hits {
            let card = self.card(view.order[h as usize]);
            let vn = view.card_note[h as usize];
            let num = if notes {
                // 同一条笔记的卡在自然顺序里挨着。
                if last == Some(vn) {
                    continue;
                }
                last = Some(vn);
                self.note(view.note_slot[vn as usize]).num
            } else {
                card.num
            };
            bytes.extend_from_slice(&num.to_le_bytes());
            if want_uuids {
                uuids.push(card.id.as_str());
            }
        }
        let count = bytes.len() / 8;
        files.push(("ids.i64".to_owned(), bytes));
        Ok(if want_uuids { json!({"count": count, "cards": uuids}) } else { json!({"count": count}) })
    }

    /// `anki_tags`：全部未删除笔记的标签，去重、按 Dart `String.compareTo`（UTF-16 码元）排。
    fn anki_tags(&self) -> Value {
        let mut tags: Vec<&str> = self.notes.iter().flatten().flat_map(|n| n.tags.iter().map(String::as_str)).collect::<HashSet<_>>().into_iter().collect();
        tags.sort_by(|a, b| cmp16(a, b));
        json!({"tags": tags})
    }
}

/// `anki_dupes`：canAddNotes / addNote 的库内查重。`first` = 笔记类型 → 首字段 id（未删除、有字段的笔记类型；只用
/// 键：不在里面的笔记类型的笔记不参与查重）；`cands` = `[{norm, type, all, decks}]`（`norm` 是候选首字段的查重规范形，
/// 调用方已判过空；`all` = 跨笔记类型比较；`decks` = 范围牌组 id，null = 整个集合）。回 `{dup: [bool]}`，与 `cands`
/// 等长：库里有规范形相同、笔记类型相符（`all` 时不看）、在范围内（有一张可见卡在范围牌组里）的未删除笔记。
///
/// 库内笔记的规范形是笔记缓存行的 `dupe_norm`（写缓存行时用同一个 [search::dupe_norm] 算好，srs.db v15），按
/// `idx_srs_notes_cache_dupe` 查候选的规范形：不读修改记录、不建内存索引、不要浏览会话——冷启动与热查同价，开销
/// 只与候选数和命中数有关。读快照与浏览命令相同（写连接上事务里则看得见未提交的行）。
fn anki_dupes(c: &Connection, profile: &str, req: &Value) -> Result<Value, String> {
    let types: HashSet<&str> =
        req.get("first").and_then(Value::as_object).map(|m| m.keys().map(String::as_str).collect()).unwrap_or_default();
    let cands = req.get("cands").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    if cands.is_empty() {
        return Ok(json!({"dup": []}));
    }
    let norm_of = |cand: &Value| cand.get("norm").and_then(Value::as_str).unwrap_or("").to_owned();
    // 规范形 → 库里的 (笔记 id, 笔记类型)。空规范形不查（调用方已判空；库里首字段为空的笔记存空串）。
    let wanted: Vec<String> =
        cands.iter().map(norm_of).filter(|n| !n.is_empty()).collect::<HashSet<_>>().into_iter().collect();
    let mut by: HashMap<String, Vec<(String, String)>> = HashMap::new();
    for chunk in wanted.chunks(CHUNK) {
        let q = format!(
            "SELECT srs_idt(id) AS id, srs_idt(note_type_id) AS note_type_id, dupe_norm FROM srs_notes_cache \
             WHERE profile_uid = srs_id(?1) AND deleted_at IS NULL AND dupe_norm IN ({})",
            (2..chunk.len() + 2).map(|i| format!("?{i}")).collect::<Vec<_>>().join(", ")
        );
        let mut stmt = c.prepare_cached(&q).map_err(sql)?;
        let args = std::iter::once(profile).chain(chunk.iter().map(String::as_str));
        let mut rows = stmt.query(params_from_iter(args)).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            let (id, ty, norm): (String, String, String) =
                (r.get(0).map_err(sql)?, r.get(1).map_err(sql)?, r.get(2).map_err(sql)?);
            if types.contains(ty.as_str()) {
                by.entry(norm).or_default().push((id, ty));
            }
        }
    }
    // 每个候选命中的库内笔记（笔记类型已按 `all` 过滤）；要看牌组的收齐，一条查询读它们的可见卡。
    let mut matched: Vec<Vec<&str>> = Vec::with_capacity(cands.len());
    let mut deck_notes: HashSet<&str> = HashSet::new();
    for cand in cands {
        let ty = cand.get("type").and_then(Value::as_str).unwrap_or("");
        let all = cand.get("all").and_then(Value::as_bool).unwrap_or(false);
        let scoped = cand.get("decks").is_some_and(Value::is_array);
        let hit: Vec<&str> = by
            .get(&norm_of(cand))
            .into_iter()
            .flatten()
            .filter(|(_, t)| all || t == ty)
            .map(|(id, _)| id.as_str())
            .collect();
        if scoped {
            deck_notes.extend(hit.iter().copied());
        }
        matched.push(hit);
    }
    let mut decks_of: HashMap<String, HashSet<String>> = HashMap::new();
    let deck_notes: Vec<&str> = deck_notes.into_iter().collect();
    for chunk in deck_notes.chunks(CHUNK) {
        let q = format!(
            "SELECT srs_idt(note_id) AS note_id, srs_idt(deck_id) AS deck_id FROM srs_cards_cache WHERE note_id IN ({}) AND +profile_uid = srs_id(?1) AND +hidden = 0",
            (2..chunk.len() + 2).map(|i| format!("srs_id(?{i})")).collect::<Vec<_>>().join(", ")
        );
        let mut stmt = c.prepare_cached(&q).map_err(sql)?;
        let args = std::iter::once(profile).chain(chunk.iter().copied());
        let mut rows = stmt.query(params_from_iter(args)).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            decks_of.entry(r.get(0).map_err(sql)?).or_default().insert(r.get(1).map_err(sql)?);
        }
    }
    let out: Vec<bool> = cands
        .iter()
        .zip(&matched)
        .map(|(cand, hit)| match cand.get("decks").and_then(Value::as_array) {
            None => !hit.is_empty(),
            Some(ds) => {
                let scope: HashSet<&str> = ds.iter().filter_map(Value::as_str).collect();
                hit.iter().any(|id| decks_of.get(*id).is_some_and(|d| d.iter().any(|x| scope.contains(x.as_str()))))
            }
        })
        .collect();
    Ok(json!({"dup": out}))
}

/// 语法树里有没有某种叶子（`t` 键）。
fn uses(node: &Value, t: &str) -> bool {
    if node.get("t").and_then(Value::as_str) == Some(t) {
        return true;
    }
    match node.get("c") {
        Some(Value::Array(a)) => a.iter().any(|c| uses(c, t)),
        Some(c @ Value::Object(_)) => uses(c, t),
        _ => false,
    }
}

fn search_error(e: search::SearchError) -> Value {
    json!({"error": e.reason, "kind": e.kind, "at": e.at})
}

impl SrsCore {
    /// 浏览命令（ffi.rs 的 v2 分发器转来）：`browse_query` / `browse_rows` / `browse_ids` / `browse_targets` /
    /// `browse_close`，以及 AnkiConnect 兼容层的 `anki_find` / `anki_dupes` / `anki_tags`（同一个会话）。读快照（写连接上事务里则在 SAVEPOINT 里，看得见未提交的行）。
    pub(crate) fn browse(&self, op: &str, profile: &str, req: &Value, files: &mut Vec<(String, Vec<u8>)>) -> Result<Value, String> {
        let owner = req.get("owner").and_then(Value::as_str);
        if op == "browse_close" {
            // 注销 [owner]（没带 = 旧调用方：按唯一持有者算）；没有持有者了才释放会话。
            let mut b = lock(&self.browse);
            let last = match owner {
                Some(o) => {
                    let set = b.owners.entry(profile.to_owned()).or_default();
                    set.remove(o);
                    set.is_empty()
                }
                None => true,
            };
            if last {
                b.owners.remove(profile);
                b.live.remove(profile);
            }
            return Ok(json!({"released": last}));
        }
        if op == "browse_stats" {
            let b = lock(&self.browse);
            let mut owners: Vec<&String> = b.owners.get(profile).into_iter().flatten().collect();
            owners.sort();
            let s = b.live.get(profile);
            return Ok(json!({
                "live": s.is_some(),
                "sessions": b.built,
                "builds": s.map_or(0, |s| s.builds),
                "owners": owners,
            }));
        }
        if op == "anki_dupes" {
            // 不碰会话（也不登记持有者）：查的是笔记缓存行上的规范形列。
            return self.read_visible_tx(|c, _| anki_dupes(c, profile, req));
        }
        self.read_visible_tx(|c, uncommitted| {
            let mut b = lock(&self.browse);
            if let Some(o) = owner {
                b.owners.entry(profile.to_owned()).or_default().insert(o.to_owned());
            }
            let Sessions { live: sessions, built, .. } = &mut *b;
            // 先取待重读的 id 再开快照（这条连接这次读事务里第一条读在后面）。
            let dirty = self.study_hub.take_browse(profile, uncommitted);
            let fresh = dirty.overflow || !sessions.contains_key(profile);
            let ready = if fresh {
                sessions.remove(profile);
                if op != "browse_query" && !op.starts_with("anki_") {
                    return Err("browse: no session (query first)".into());
                }
                *built += 1;
                Session::build(c, profile).map(|s| {
                    sessions.insert(profile.to_owned(), s);
                })
            } else {
                sessions.get_mut(profile).expect("checked above").apply(c, profile, &dirty)
            };
            if let Err(e) = ready {
                sessions.remove(profile);
                return Err(e);
            }
            let s = sessions.get_mut(profile).expect("session");
            let out = match op {
                "browse_query" => {
                    // 同一条查询、会话也没变（预览返回之类没有写入的刷新）：直接给回上次的结果。
                    let since = req.get("since").and_then(Value::as_u64);
                    if let Some(r) = since.and_then(|g| s.results.iter().find(|r| r.gen == g)) {
                        let ctx = Ctx::parse(req)?;
                        let same = json!([
                            req.get("node"),
                            req.get("sort").cloned().unwrap_or(Value::Null),
                            req.get("mode").and_then(Value::as_str) != Some("notes"),
                            req.get("types"),
                            req.get("decks"),
                            req.get("fallback"),
                            req.get("instant"),
                            ctx.today,
                        ]);
                        let prev = r.params.as_array().map(|a| Value::Array(a[..a.len() - 1].to_vec()));
                        if !r.stale && prev.as_ref() == Some(&same) {
                            return Ok(json!({"gen": r.gen, "count": r.rows.len(), "same": true}));
                        }
                    }
                    s.query(c, profile, req)
                }
                "browse_rows" => s.rows(req, files),
                "browse_ids" => s.ids(req),
                "browse_targets" => s.targets(req),
                "anki_find" => s.anki_find(c, profile, req, files),
                "anki_tags" => Ok(s.anki_tags()),
                _ => Err(format!("browse: unknown op {op}")),
            };
            if out.is_err() && (op == "browse_query" || op.starts_with("anki_")) {
                // 求值 / 装载出错：会话可能只装了一半，丢掉，下次整份重建。
                sessions.remove(profile);
            }
            out
        })
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    use crate::store::caches::{refresh, CacheConfig, Dirty};
    use crate::store::sync2::in_savepoint;
    use crate::store::sync2::tests::{deck_entity, edit, Device, P};

    const T0: i64 = 1_700_000_000_000;
    const N1: &str = "0193a1b2-0000-7000-8000-0000000000a1";
    const N2: &str = "0193a1b2-0000-7000-8000-0000000000a2";
    const N3: &str = "0193a1b2-0000-7000-8000-0000000000a3";
    const N4: &str = "0193a1b2-0000-7000-8000-0000000000a4";
    const N5: &str = "0193a1b2-0000-7000-8000-0000000000a5";

    fn note(id: &str, nt: &str) -> Value {
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": nt}}})
    }

    fn note_type(id: &str) -> Value {
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}})
    }

    /// 写入一批事件并刷新缓存（与 Dart 落库同一条路径：缓存行的改动经临时触发器记进浏览的待重读）。
    fn write(d: &Device, cfg: &CacheConfig, now: i64, events: Vec<Value>) {
        let r = d.apply(now, events);
        let w = d.core.writer().unwrap();
        in_savepoint(&w, |c| refresh(c, P, cfg, Dirty::of_projection(&r))).unwrap();
    }

    fn call(d: &Device, op: &str, req: Value) -> Value {
        let mut files = Vec::new();
        d.core.browse(op, P, &req, &mut files).unwrap()
    }

    fn dupes(d: &Device, cands: Value) -> Vec<bool> {
        let r = call(d, "anki_dupes", json!({"owner": "ankiconnect", "first": {"A": "fa", "B": "x"}, "cands": cands}));
        r["dup"].as_array().unwrap().iter().map(|v| v.as_bool().unwrap()).collect()
    }

    fn cand(norm: &str, ty: &str, all: bool, decks: Value) -> Value {
        json!({"norm": norm, "type": ty, "all": all, "decks": decks})
    }

    fn library() -> (Device, CacheConfig, String) {
        let d = Device::new("browse-anki");
        let deck = crate::store::sync2::config::default_deck_id(P);
        let fdef = |name: &str, ord: i64| json!({"name": name, "ord": ord});
        let tdef = |front: &str| json!({"name": "C", "ord": 0, "front": front});
        let cfg = CacheConfig::parse(&json!({"defaultDeck": deck})).unwrap();
        write(
            &d,
            &cfg,
            T0,
            vec![
                deck_entity(&deck),
                note_type("A"),
                edit("notetype", "A", "fieldDef/fa", fdef("Front", 0)),
                edit("notetype", "A", "fieldDef/fb", fdef("Back", 1)),
                edit("notetype", "A", "tmplDef/t1", tdef("{{Front}}")),
                note_type("B"),
                edit("notetype", "B", "fieldDef/x", fdef("Word", 0)),
                edit("notetype", "B", "tmplDef/t2", tdef("{{Word}}")),
                note(N1, "A"),
                edit("note", N1, "f/fa", json!("<b>cat</b>")),
                edit("note", N1, "f/fb", json!("dog")),
                edit("note", N1, "tags", json!(["t1", "b"])),
                note(N2, "A"),
                edit("note", N2, "f/fa", json!("  cat\u{a0}")),
                edit("note", N2, "tags", json!(["B", "t1"])),
                note(N3, "B"),
                edit("note", N3, "f/x", json!("cat")),
                note(N4, "A"),
                edit("note", N4, "f/fa", json!("<i>owl</i> ")),
            ],
        );
        (d, cfg, deck)
    }

    /// `anki_dupes`：首字段查重规范形（去 HTML、trim）相同、笔记类型相符（`all` 不看类型）、范围牌组里有它的卡；
    /// 写入（新笔记、删笔记）之后查的是缓存行上刚写好的规范形，释放浏览会话不影响结果（查重不用会话）。
    #[test]
    fn anki_dupes_match_first_field_norms_types_and_decks() {
        let (d, cfg, deck) = library();
        let probe = |d: &Device| {
            dupes(
                d,
                json!([
                    cand("cat", "A", false, Value::Null),
                    cand("cat", "B", false, Value::Null),
                    cand("dog", "A", false, Value::Null),
                    cand("owl", "A", false, Value::Null),
                    cand("owl", "B", false, Value::Null),
                    cand("owl", "C", true, Value::Null),
                    cand("cat", "A", false, json!([deck])),
                    cand("cat", "A", false, json!(["no-such-deck"])),
                    cand("bird", "A", false, Value::Null),
                ]),
            )
        };
        assert_eq!(probe(&d), [true, true, false, true, false, true, true, false, false]);
        assert!(dupes(&d, json!([])).is_empty());

        write(
            &d,
            &cfg,
            T0 + 1000,
            vec![
                note(N5, "A"),
                edit("note", N5, "f/fa", json!("bird")),
                edit("note", N1, "deleted", json!(T0 + 1000)),
            ],
        );
        // N1 删了但 N2 也是 cat：仍是重复；bird 新加进来。
        assert_eq!(probe(&d), [true, true, false, true, false, true, true, false, true]);
        write(&d, &cfg, T0 + 2000, vec![edit("note", N2, "deleted", json!(T0 + 2000))]);
        let incremental = probe(&d);
        assert_eq!(incremental, [false, true, false, true, false, true, false, false, true]);
        // 释放会话后重建：与增量结果一致。
        assert_eq!(call(&d, "browse_close", json!({"owner": "ankiconnect"}))["released"], json!(true));
        assert_eq!(probe(&d), incremental);
    }

    /// 每条缓存行的 `dupe_norm`。
    fn dupe_norms(d: &Device) -> Vec<(String, Option<String>)> {
        let w = d.core.writer().unwrap();
        let mut stmt = w.prepare("SELECT srs_idt(id), dupe_norm FROM srs_notes_cache ORDER BY srs_idt(id)").unwrap();
        stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().collect::<Result<_, _>>().unwrap()
    }

    /// `anki_dupes` 不建浏览会话：冷查（从没浏览过）就直接查缓存行，查完也没有常驻会话、没有登记持有者。
    #[test]
    fn anki_dupes_needs_no_browse_session() {
        let (d, _, _) = library();
        assert_eq!(dupes(&d, json!([cand("cat", "A", false, Value::Null)])), [true]);
        let stats = call(&d, "browse_stats", json!({}));
        assert_eq!(stats["live"], json!(false), "{stats}");
        assert_eq!(stats["sessions"], json!(0), "{stats}");
        assert_eq!(stats["owners"], json!([]), "{stats}");
    }

    /// 笔记类型调换字段顺序：首字段换了，成员笔记的缓存行（含 `dupe_norm`）随笔记类型重算，查重跟着换。
    #[test]
    fn anki_dupes_follow_a_first_field_reorder() {
        let (d, cfg, _) = library();
        assert_eq!(dupes(&d, json!([cand("cat", "A", false, Value::Null), cand("dog", "A", false, Value::Null)])), [true, false]);
        let fdef = |name: &str, ord: i64| json!({"name": name, "ord": ord});
        write(
            &d,
            &cfg,
            T0 + 1000,
            vec![edit("notetype", "A", "fieldDef/fa", fdef("Front", 1)), edit("notetype", "A", "fieldDef/fb", fdef("Back", 0))],
        );
        // N1 的首字段现在是 fb = "dog"；N2 / N4 的 fb 为空。
        assert_eq!(dupes(&d, json!([cand("cat", "A", false, Value::Null), cand("dog", "A", false, Value::Null)])), [false, true]);
    }

    /// v15 老行（`dupe_norm` 为 NULL）的补算与写缓存行时算的逐行相同；补完再跑一遍什么也不做；补完查重结果相同。
    #[test]
    fn backfill_dupe_norms_matches_the_cache_write_and_is_idempotent() {
        let (d, cfg, deck) = library();
        let written = dupe_norms(&d);
        assert!(written.iter().all(|(_, n)| n.is_some()), "{written:?}");
        assert!(written.contains(&(N1.to_owned(), Some("cat".to_owned()))), "{written:?}");
        let probe = json!([cand("cat", "A", false, Value::Null), cand("owl", "C", true, Value::Null), cand("cat", "A", false, json!([deck]))]);
        let before = dupes(&d, probe.clone());
        let backfill = |d: &Device| {
            let w = d.core.writer().unwrap();
            in_savepoint(&w, |c| crate::store::caches::backfill_dupe_norms(c, P, &cfg)).unwrap()
        };
        {
            let w = d.core.writer().unwrap();
            w.execute_batch("UPDATE srs_notes_cache SET dupe_norm = NULL").unwrap();
            // 缓存孤行（身份记录已不在）：补成空串。
            w.execute(
                "INSERT INTO srs_notes_cache (id, profile_uid, note_type_id, guid, created_at) VALUES ('orphan', srs_id(?1), 'A', 'g', 1)",
                [P],
            )
            .unwrap();
        }
        assert_eq!(dupes(&d, probe.clone()), [false, false, false], "NULL rows never match");
        assert_eq!(backfill(&d), written.len() + 1);
        let mut expect = written.clone();
        expect.push(("orphan".to_owned(), Some(String::new())));
        expect.sort();
        assert_eq!(dupe_norms(&d), expect);
        assert_eq!(backfill(&d), 0);
        assert_eq!(dupes(&d, probe), before);
    }

    /// 同 study.rs `a_snapshot_read_between_commit_and_settle_rereads_the_touched_rows`，浏览会话这一侧：写锁守卫释放
    /// （settle）晚于 COMMIT 可见。COMMIT 之后、守卫还持着时在读连接上发浏览命令：快照看得见新行，触发器记下的 id
    /// 还在「未提交」里——只重读已提交的会按旧会话作答（漏读一次）。未提交的改动读到旧值（与快照一致），也不清掉，
    /// 提交后再按终态重读。
    #[test]
    fn a_browse_read_between_commit_and_settle_rereads_the_touched_rows() {
        let (d, _, _) = library();
        let tags = |d: &Device| call(d, "anki_tags", json!({"owner": "ankiconnect"}))["tags"].clone();
        assert_eq!(tags(&d), json!(["B", "b", "t1"]));
        {
            // 写连接上自动提交一条改动：COMMIT 已对读连接可见，守卫还没释放（没 settle）。浏览命令不在写连接上读
            // （没有挂着的 Drift 事务），所以持着守卫也照样走读连接。
            let w = d.core.writer().unwrap();
            w.execute("UPDATE srs_notes_cache SET tags_json = '[\"zz\"]' WHERE id = srs_id(?1)", [N1]).unwrap();
            assert!(w.is_autocommit());
            assert_eq!(tags(&d), json!(["B", "t1", "zz"]), "the committed write is visible and must be reread");
            // 未提交的改动：读快照重读到的是旧值。
            w.execute_batch(&format!("BEGIN; UPDATE srs_notes_cache SET tags_json = '[\"yy\"]' WHERE id = srs_id('{N2}');")).unwrap();
            assert_eq!(tags(&d), json!(["B", "t1", "zz"]));
            w.execute_batch("COMMIT;").unwrap();
            assert_eq!(tags(&d), json!(["yy", "zz"]), "rows committed after an earlier reread are reread again");
        }
        assert_eq!(tags(&d), json!(["yy", "zz"]));
        let stats = call(&d, "browse_stats", json!({}));
        assert_eq!(stats["sessions"], json!(1), "rereads, not rebuilds: {stats}");
    }

    /// `anki_notes_info`（store/bulk.rs）：按数字 id 一批交回笔记类型、标签、字段（寄存器视图原序、落库表示）与可见卡；
    /// 查不到 / 已删除的为 null，与请求等长、同序（重复的 id 各回一份）。
    #[test]
    fn anki_notes_info_reads_fields_tags_and_visible_cards_by_numeric_id() {
        let (d, cfg, _) = library();
        write(&d, &cfg, T0 + 1000, vec![edit("note", N2, "deleted", json!(T0 + 1000))]);
        let num = crate::store::schema::anki_numeric_id;
        let card = crate::registers::card_id(N1, "t1", 0).unwrap();
        let req = json!({"notes": [num(N1), num(N2), 7, num(N3), num(N1)]});
        let got = d.core.read_visible(|c| crate::store::bulk::anki_notes_info(c, P, &req)).unwrap();
        let n1 = json!({
            "id": N1, "nt": "A", "t": ["t1", "b"],
            "f": [["fa", "<b>cat</b>"], ["fb", "dog"]],
            "c": [[num(&card), "t1", 0]],
        });
        assert_eq!(got["notes"][0], n1);
        assert_eq!(got["notes"][1], Value::Null, "deleted");
        assert_eq!(got["notes"][2], Value::Null, "unknown");
        assert_eq!(got["notes"][3]["nt"], json!("B"));
        assert_eq!(got["notes"][3]["f"], json!([["x", "cat"]]));
        assert_eq!(got["notes"][4], n1);
    }

    /// 查重用得上 v15 的部分索引（候选规范形 IN (...) 不扫全表）。
    #[test]
    fn anki_dupes_query_uses_the_dupe_index() {
        let (d, _, _) = library();
        let w = d.core.writer().unwrap();
        let plan: Vec<String> = w
            .prepare(
                "EXPLAIN QUERY PLAN SELECT srs_idt(id) AS id, srs_idt(note_type_id) AS note_type_id, dupe_norm FROM srs_notes_cache \
                 WHERE profile_uid = srs_id(?1) AND deleted_at IS NULL AND dupe_norm IN (?2, ?3)",
            )
            .unwrap()
            .query_map(rusqlite::params![P, "a", "b"], |r| r.get::<_, String>(3))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(plan.iter().any(|l| l.contains("idx_srs_notes_cache_dupe")), "{plan:?}");
    }

    /// `anki_tags`：全部未删除笔记的标签去重，按 UTF-16 码元排（大写在前）；删了笔记它独有的标签就没了。
    #[test]
    fn anki_tags_dedupes_sorts_and_follows_deletes() {
        let (d, cfg, _) = library();
        let tags = |d: &Device| call(d, "anki_tags", json!({"owner": "ankiconnect"}))["tags"].clone();
        assert_eq!(tags(&d), json!(["B", "b", "t1"]));
        write(
            &d,
            &cfg,
            T0 + 1000,
            vec![edit("note", N1, "deleted", json!(T0 + 1000)), edit("note", N3, "tags", json!(["Ä", "a"]))],
        );
        assert_eq!(tags(&d), json!(["B", "a", "t1", "Ä"]));
        let stats = call(&d, "browse_stats", json!({}));
        assert_eq!(stats["owners"], json!(["ankiconnect"]));
        assert_eq!(stats["sessions"], json!(1), "writes must not rebuild the session");
    }
}
