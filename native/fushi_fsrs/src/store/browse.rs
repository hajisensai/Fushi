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

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, MutexGuard};

use rusqlite::{params_from_iter, types::Value as Sql, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

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

/// Anki 数字 id（Dart `SrsIds.ankiNumericId` = `hash53('anki-id/<uuid>')`）。
fn anki_numeric_id(uuid: &str) -> i64 {
    let mut h = Sha256::new();
    h.update(b"anki-id/");
    h.update(uuid.as_bytes());
    let d = h.finalize();
    let mut v = 0u64;
    for &b in &d[..7] {
        v = (v << 8) | b as u64;
    }
    v &= (1u64 << 53) - 1;
    if v == 0 {
        1
    } else {
        v as i64
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
}

impl Card {
    /// 改了会动搜索语料结构（归属笔记、模板、牌组）。
    fn same_shape(&self, o: &Card) -> bool {
        self.note == o.note && self.tpl == o.tpl && self.cloze == o.cloze && self.deck == o.deck
    }
}

const CARD_COLUMNS: &str = "id, note_id, template_id, cloze_ord, deck_id, suspended, buried_until_day, flag, queue, \
     due_day, due_at, scheduled_days, reps, lapses, stability, difficulty, last_reviewed_at";

fn card_of(r: &rusqlite::Row<'_>) -> rusqlite::Result<Card> {
    let queue: String = r.get(8)?;
    Ok(Card {
        id: r.get(0)?,
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

const NOTE_COLUMNS: &str = "id, note_type_id, created_at, sort_field, tags_json, pending_decision";

fn note_of(r: &rusqlite::Row<'_>) -> rusqlite::Result<Note> {
    let tags: String = r.get(4)?;
    let tags = match serde_json::from_str::<Value>(&tags) {
        Ok(Value::Array(a)) => a.into_iter().filter_map(|t| t.as_str().map(str::to_owned)).collect(),
        _ => Vec::new(),
    };
    Ok(Note {
        id: r.get(0)?,
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
struct View {
    shape: u64,
    ctx: Value,
    /// 语料里的第 i 张卡 = 会话卡槽 `order[i]`。
    order: Vec<u32>,
    /// 语料里的第 i 张卡属于语料笔记 `card_note[i]`；语料笔记 → 会话笔记槽。
    card_note: Vec<u32>,
    note_slot: Vec<u32>,
    /// 语料笔记 → 它的全部可见卡（语料卡下标，自然顺序）。
    note_cards: Vec<Vec<u32>>,
    corpus: Corpus,
    /// 语料的名字表（字符串 id → 原文）：把 [Needs::Names] 换回字段名。
    strings: Vec<String>,
    /// `nid:` / `cid:` 的数字 id 列（SHA-256，用到才算）。
    nid: Option<Vec<i64>>,
    cid: Option<Vec<i64>>,
}

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

impl View {
    fn build(s: &Session, ctx: &Ctx) -> Result<View, String> {
        // 可见卡：笔记在（未删除）、笔记类型在且没删。
        let mut order: Vec<u32> = Vec::new();
        for (slot, c) in s.cards.iter().enumerate() {
            let Some(c) = c else { continue };
            let Some(&ns) = s.note_at.get(&c.note) else { continue };
            let n = s.notes[ns as usize].as_ref().expect("indexed note");
            if ctx.types.get(&n.ty).is_some_and(|t| !t.deleted) {
                order.push(slot as u32);
            }
        }
        let note_of = |slot: u32| -> (u32, &Note) {
            let c = s.cards[slot as usize].as_ref().expect("visible card");
            let ns = s.note_at[&c.note];
            (ns, s.notes[ns as usize].as_ref().expect("indexed note"))
        };
        let ordinal = |slot: u32| -> i64 {
            let c = s.cards[slot as usize].as_ref().expect("visible card");
            ctx.types[&note_of(slot).1.ty].ordinal(c)
        };
        let ords: HashMap<u32, i64> = order.iter().map(|&x| (x, ordinal(x))).collect();
        order.sort_by(|&a, &b| {
            let (na, nb) = (note_of(a).1, note_of(b).1);
            na.created
                .cmp(&nb.created)
                .then_with(|| cmp16(&na.id, &nb.id))
                .then_with(|| ords[&a].cmp(&ords[&b]))
                .then_with(|| {
                    cmp16(&s.cards[a as usize].as_ref().unwrap().id, &s.cards[b as usize].as_ref().unwrap().id)
                })
        });

        let mut it = Interner {
            text: String::new(),
            off: vec![0],
            at: HashMap::new(),
            strings: Vec::new(),
        };
        let mut schema_of: HashMap<&str, u32> = HashMap::new();
        let mut schema_names: Vec<Vec<u32>> = Vec::new();
        let mut schema_alias: Vec<Vec<u32>> = Vec::new();
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
        for (vi, &slot) in order.iter().enumerate() {
            let c = s.cards[slot as usize].as_ref().expect("visible card");
            let (ns, n) = note_of(slot);
            let ty = &ctx.types[&n.ty];
            let vn = match note_index.get(&ns) {
                Some(&v) => v,
                None => {
                    let v = note_slot.len() as u32;
                    note_index.insert(ns, v);
                    note_slot.push(ns);
                    note_type.push(it.id(&ty.name));
                    let schema = match schema_of.get(n.ty.as_str()) {
                        Some(&k) => k,
                        None => {
                            let k = schema_names.len() as u32;
                            schema_names.push(ty.slot_names.iter().map(|x| it.id(x)).collect());
                            schema_alias.push(
                                ty.slot_alias.iter().map(|a| a.as_deref().map_or(search::NO_ALIAS, |a| it.id(a))).collect(),
                            );
                            schema_of.insert(n.ty.as_str(), k);
                            k
                        }
                    };
                    note_schema.push(schema);
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
        let mut corpus = Corpus::new(it.text.as_bytes(), &words)?;

        // 已装的字段原文挂进语料：全部字段都装了时同一条笔记的字段紧挨着、隔 0x1f（`n.flds` 直接切片）。
        if s.full || !s.fields.is_empty() {
            let mut text = String::new();
            let mut fields: Vec<u32> = Vec::new();
            let mut spans: Vec<u32> = Vec::new();
            let mut base = 0usize;
            for (vn, &ns) in note_slot.iter().enumerate() {
                let n = s.notes[ns as usize].as_ref().expect("indexed note");
                let ty = &ctx.types[&n.ty];
                let schema = note_schema[vn] as usize;
                let width = (schema_off[schema + 1] - schema_off[schema]) as usize;
                for (k, fid) in ty.slot_ids.iter().enumerate().take(width) {
                    if !s.full && !s.fields.contains(fid) {
                        continue;
                    }
                    if s.full && k > 0 {
                        text.push('\x1f');
                    }
                    let start = text.len();
                    text.push_str(n.value(fid));
                    if text.len() > u32::MAX as usize {
                        return Err("browse: field text too large".into());
                    }
                    fields.push((base + k) as u32);
                    spans.push(start as u32);
                    spans.push(text.len() as u32);
                }
                base += width;
            }
            corpus.attach(text, &fields, &spans)?;
        }
        Ok(View {
            shape: s.shape,
            ctx: ctx.shape.clone(),
            order,
            card_note,
            note_slot,
            note_cards,
            corpus,
            strings: it.strings,
            nid: None,
            cid: None,
        })
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
    /// 结构版本：变了搜索语料就要重建。
    shape: u64,
    view: Option<View>,
    /// 最近几次查询的结果（新的在后；浏览页与控制通道可以同时各持一份）。
    results: Vec<Res>,
}

/// 一个会话留几份查询结果。
const KEEP_RESULTS: usize = 4;

static GEN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

const NOTES_SQL: &str = "SELECT id, note_type_id, created_at, sort_field, tags_json, pending_decision \
     FROM srs_notes_cache WHERE profile_uid = ?1 AND deleted_at IS NULL";

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
            results: Vec::new(),
        };
        {
            let mut stmt = c.prepare_cached(NOTES_SQL).map_err(sql)?;
            let mut rows = stmt.query([profile]).map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                let n = note_of(r).map_err(sql)?;
                s.note_at.insert(n.id.clone(), s.notes.len() as u32);
                s.notes.push(Some(n));
            }
        }
        let q = format!("SELECT {CARD_COLUMNS} FROM srs_cards_cache WHERE profile_uid = ?1 AND hidden = 0");
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
                "SELECT {CARD_COLUMNS} FROM srs_cards_cache WHERE id IN ({}) AND +profile_uid = ?1 AND +hidden = 0",
                (2..chunk.len() + 2).map(|i| format!("?{i}")).collect::<Vec<_>>().join(", ")
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
                            self.shape += 1;
                        }
                        self.cards[slot as usize] = Some(card);
                    }
                    (Some(card), None) => {
                        self.card_at.insert(id.clone(), self.cards.len() as u32);
                        self.cards.push(Some(card));
                        self.shape += 1;
                    }
                    (None, Some(slot)) => {
                        self.card_at.remove(id);
                        self.cards[slot as usize] = None;
                        self.shape += 1;
                    }
                    (None, None) => {}
                }
            }
        }
        let ids: Vec<&String> = d.notes.iter().collect();
        let mut present: Vec<String> = Vec::new();
        for chunk in ids.chunks(CHUNK) {
            let q = format!(
                "SELECT {NOTE_COLUMNS} FROM srs_notes_cache WHERE id IN ({}) AND +profile_uid = ?1 AND deleted_at IS NULL",
                (2..chunk.len() + 2).map(|i| format!("?{i}")).collect::<Vec<_>>().join(", ")
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
                            self.shape += 1;
                        }
                        self.notes[slot as usize] = Some(n);
                        present.push(id.clone());
                    }
                    (Some(n), None) => {
                        self.note_at.insert(id.clone(), self.notes.len() as u32);
                        self.notes.push(Some(n));
                        self.shape += 1;
                        present.push(id.clone());
                    }
                    (None, Some(slot)) => {
                        self.note_at.remove(id);
                        self.notes[slot as usize] = None;
                        self.shape += 1;
                    }
                    (None, None) => {}
                }
            }
        }
        // 写过的笔记：已装的字段列 / 最后改动时刻按库里的修改记录重读（字段值进语料：结构变了）。
        if !present.is_empty() && (self.full || !self.fields.is_empty()) {
            let keys: Option<Vec<String>> = if self.full { None } else { Some(self.fields.iter().cloned().collect()) };
            self.load_values(c, profile, Some(&present), keys.as_deref())?;
            self.shape += 1;
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
            let mut edits: Vec<(String, Option<i64>)> = Vec::new();
            let flush = |id: Option<String>, edits: &mut Vec<(String, Option<i64>)>, s: &mut Session| -> Result<(), String> {
                let Some(id) = id else { return Ok(()) };
                let stored: Vec<StoredEdit<'_>> = edits.iter().map(|(j, t)| (j.as_str(), *t)).collect();
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
                edits.push((r.get(1).map_err(sql)?, r.get(2).map_err(sql)?));
            }
            flush(cur.take(), &mut edits, s)
        };
        const SELECT: &str = "SELECT f.entity_id, f.json, s.server_time FROM srs_field_edits f \
             LEFT JOIN srs_event_local s ON s.event_id = f.id WHERE f.entity_kind = 'note'";
        match notes {
            None => {
                let q = format!("{SELECT} AND +f.profile_uid = ?1{} ORDER BY f.entity_id", key_filter(2, key_args.len()));
                let args: Vec<Sql> =
                    std::iter::once(Sql::Text(profile.to_owned())).chain(key_args.iter().map(|k| Sql::Text(k.clone()))).collect();
                run(c, &q, args, self)?;
            }
            Some(ids) => {
                for chunk in ids.chunks(CHUNK) {
                    let q = format!(
                        "{SELECT} AND f.entity_id IN ({}) AND +f.profile_uid = ?1{} ORDER BY f.entity_id",
                        (2..chunk.len() + 2).map(|i| format!("?{i}")).collect::<Vec<_>>().join(", "),
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
                self.shape += 1;
            }
            Some(ids) => {
                let missing: Vec<String> = ids.iter().filter(|f| !self.fields.contains(*f)).cloned().collect();
                if missing.is_empty() {
                    return Ok(());
                }
                self.load_values(c, profile, None, Some(&missing))?;
                self.fields.extend(missing);
                self.shape += 1;
            }
        }
        Ok(())
    }

    fn ensure_view(&mut self, ctx: &Ctx) -> Result<(), String> {
        let fresh = self.view.as_ref().is_some_and(|v| v.shape == self.shape && v.ctx == ctx.shape);
        if !fresh {
            self.view = None;
            self.view = Some(View::build(self, ctx)?);
        }
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

        self.ensure_view(&ctx)?;
        let query = node.map(|n| n.to_string());
        // 查询要的字段列、`edited:` / 按修改时间排序要的最后改动时刻、按字段排序要的那一列：先装齐再求值。
        let mut full = column == Column::Modified;
        let mut want: HashSet<String> = HashSet::new();
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
                Err(e) => return Ok(search_error(e)),
            }
        }
        if column == Column::Field {
            if let Some(f) = &field {
                for t in ctx.types.values() {
                    if let Some(id) = t.field_named(f) {
                        want.insert(id.to_owned());
                    }
                }
            }
        }
        if full {
            self.ensure_fields(c, profile, None)?;
        } else if !want.is_empty() {
            self.ensure_fields(c, profile, Some(&want))?;
        }
        self.ensure_view(&ctx)?;

        let hits: Vec<u32> = match &query {
            None => (0..self.view.as_ref().expect("view").order.len() as u32).collect(),
            Some(q) => {
                let node = node.expect("query has a node");
                self.set_columns(&ctx, node)?;
                let view = self.view.as_ref().expect("view");
                let mut out = vec![0u8; view.order.len()];
                if let Err(e) = view.corpus.search(q, &mut out) {
                    return Ok(search_error(e));
                }
                (0..out.len() as u32).filter(|&i| out[i as usize] != 0).collect()
            }
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
        // 值相同按自然顺序（主卡在语料里的位置就是自然顺序）。
        idx.sort_by(|&a, &b| cmp_keys(&keys[a], &keys[b], asc).then_with(|| rows[a].0.cmp(&rows[b].0)));
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
        let total = view.order.len();
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

    /// 每次查询按此刻现算的数值列（语料的 [search::IntColumn] / [search::FloatColumn]）。
    fn set_columns(&mut self, ctx: &Ctx, node: &Value) -> Result<(), String> {
        let full = self.full;
        let ids = uses(node, "nid") || uses(node, "cid");
        let view = self.view.as_mut().expect("view");
        if ids && view.nid.is_none() {
            let mut nid = Vec::with_capacity(view.order.len());
            let mut cid = Vec::with_capacity(view.order.len());
            for (i, &slot) in view.order.iter().enumerate() {
                let c = self.cards[slot as usize].as_ref().expect("visible card");
                let n = self.notes[view.note_slot[view.card_note[i] as usize] as usize].as_ref().expect("visible note");
                nid.push(anki_numeric_id(&n.id));
                cid.push(anki_numeric_id(&c.id));
            }
            view.nid = Some(nid);
            view.cid = Some(cid);
        }
        let n = view.order.len();
        let mut cols: Vec<Vec<i64>> = (0..search::INT_COLUMNS).map(|_| Vec::with_capacity(n)).collect();
        let mut stab = Vec::with_capacity(n);
        let mut diff = Vec::with_capacity(n);
        for (i, &slot) in view.order.iter().enumerate() {
            let c = self.cards[slot as usize].as_ref().expect("visible card");
            let note = self.notes[view.note_slot[view.card_note[i] as usize] as usize].as_ref().expect("visible note");
            let ty = &ctx.types[&note.ty];
            let learn = c.queue == Q_LEARNING || c.queue == Q_RELEARNING;
            let review = c.queue == Q_REVIEW || c.queue == Q_RELEARNING;
            let state = i64::from(c.queue == Q_NEW)
                | (i64::from(learn) << 1)
                | (i64::from(review) << 2)
                | (i64::from(ctx.is_due(c)) << 3)
                | (i64::from(c.suspended) << 4)
                | (i64::from(ctx.is_buried(c)) << 5);
            cols[0].push(state);
            cols[1].push(view.nid.as_ref().map_or(0, |v| v[i]));
            cols[2].push(view.cid.as_ref().map_or(0, |v| v[i]));
            cols[3].push(ctx.day.index(note.created));
            cols[4].push(if full { ctx.day.index(note.modified_at()) } else { 0 });
            cols[5].push(ctx.today);
            cols[6].push(c.flag);
            cols[7].push(ty.ordinal(c));
            cols[8].push(interval_days(c));
            cols[9].push(ctx.due_in_days(c).unwrap_or(DUE_NONE));
            cols[10].push(c.reps);
            cols[11].push(c.lapses);
            stab.push(c.stab.unwrap_or(f64::NAN));
            diff.push(c.diff.unwrap_or(f64::NAN));
        }
        for (k, col) in cols.iter().enumerate() {
            // 没装最后改动时刻时不给 `edited:` 列（查询用到它之前一定先装好）；数字 id 同理。
            if (k == 4 && !full) || ((k == 1 || k == 2) && view.nid.is_none()) {
                continue;
            }
            view.corpus.set_ints(k, col)?;
        }
        view.corpus.set_floats(0, &stab)?;
        view.corpus.set_floats(1, &diff)?;
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
    /// `browse_close`。读快照（写连接上事务里则在 SAVEPOINT 里，看得见未提交的行）。
    pub(crate) fn browse(&self, op: &str, profile: &str, req: &Value, files: &mut Vec<(String, Vec<u8>)>) -> Result<Value, String> {
        if op == "browse_close" {
            lock(&self.browse).remove(profile);
            return Ok(json!(true));
        }
        self.read_visible_tx(|c, uncommitted| {
            let mut sessions = lock(&self.browse);
            // 先取待重读的 id 再开快照（这条连接这次读事务里第一条读在后面）。
            let dirty = self.study_hub.take_browse(profile, uncommitted);
            let fresh = dirty.overflow || !sessions.contains_key(profile);
            let ready = if fresh {
                sessions.remove(profile);
                if op != "browse_query" {
                    return Err("browse: no session (query first)".into());
                }
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
                _ => Err(format!("browse: unknown op {op}")),
            };
            if out.is_err() && op == "browse_query" {
                // 求值 / 装载出错：会话可能只装了一半，丢掉，下次整份重建。
                sessions.remove(profile);
            }
            out
        })
    }
}
