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

use rusqlite::{Connection, params_from_iter, types::Value as Sql};
use serde_json::{Value, json};

use crate::projection::Day;
use crate::registers::{self, StoredEdit};
use crate::search::{self, Corpus, DUE_NONE, Needs};
use crate::store::SrsCore;
use crate::store::queue::{Dirty, LEARN_AHEAD_MS};
use crate::store::sync2::sql;

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
    /// 首字段的查重规范形（笔记缓存行 `dupe_norm`，`anki_dupes` 同一判据；老行 NULL = 空串）。
    dupe: String,
    /// 出处寄存器（`SrsSourceRef.toJson()`；[Session::sources] 时有效，没有 = None）。
    source: Option<Value>,
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

const NOTE_COLUMNS: &str = "srs_idt(id), srs_idt(note_type_id), created_at, sort_field, tags_json, pending_decision, anki_id, dupe_norm";

fn note_of(r: &rusqlite::Row<'_>) -> rusqlite::Result<Note> {
    let tags: String = r.get(4)?;
    let tags = match serde_json::from_str::<Value>(&tags) {
        Ok(Value::Array(a)) => a
            .into_iter()
            .filter_map(|t| t.as_str().map(str::to_owned))
            .collect(),
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
        dupe: r.get::<_, Option<String>>(7)?.unwrap_or_default(),
        source: None,
    })
}

// ------------------------------------------------------------------ 出处 / 行详情

/// 出处分组键（spec docs/specs/2026-11-04-srs-browser-redesign.md §2.1）：`<kind>:<作品身份>`，身份按 kind 取
/// （书 `bookKey`、漫画 `mangaKey`、视频 / 有声书 / 音乐 `mediaKey`、在线小说 `sourceId` + 0x1f + `novelUrl`、在线视频
/// `sourceId` + 0x1f + `animeUrl`、游戏 `gameId`、网页 `url`），取不到退回 `title`，再没有就只有 `<kind>`。章节、页码、
/// 时间、偏移不进键。不是带字符串 kind 的对象 = 没有出处（Dart `SrsSourceRef.fromJson`）。返回 (键, kind)。
pub(crate) fn source_key(v: &Value) -> Option<(String, String)> {
    let kind = v.get("kind")?.as_str()?;
    let s = |k: &str| v.get(k).and_then(Value::as_str).filter(|x| !x.is_empty());
    let pair = |a: &str, b: &str| Some(format!("{}\u{1f}{}", s(a)?, s(b)?));
    let identity = match kind {
        "book" => s("bookKey").map(str::to_owned),
        "manga" => s("mangaKey").map(str::to_owned),
        "video" | "audiobook" | "music" => s("mediaKey").map(str::to_owned),
        "onlineNovel" => pair("sourceId", "novelUrl"),
        "onlineVideo" => pair("sourceId", "animeUrl"),
        "game" => s("gameId").map(str::to_owned),
        "web" => s("url").map(str::to_owned),
        _ => None,
    }
    .or_else(|| s("title").map(str::to_owned));
    Some((
        identity.map_or_else(|| kind.to_owned(), |id| format!("{kind}:{id}")),
        kind.to_owned(),
    ))
}

/// 取行时才要的笔记内容（这一页的笔记从修改记录读一次，写入后按笔记失效）。只存 [Session::rows] 用到的派生投影，
/// 不存字段原文：会话常驻（浏览页、AnkiConnect），滚一遍大库时原文会把会话内存再翻一倍；投影每条笔记只占几百字节。
struct Detail {
    /// 字段 id → 该字段的投影（三项都没有的字段不存）。按字段 id 存而不按笔记类型的字段顺序预先挑好：笔记类型的
    /// 字段排布随查询上下文变（改了字段顺序不会让这里失效），取行时按此刻的排布挑。
    fields: HashMap<String, FieldDigest>,
    modified: Option<i64>,
    source: Value,
}

/// 一个字段在行里露出的部分：摘要（[preview_text]，≤120 字符）、首个图片 / 音频文件名。
struct FieldDigest {
    preview: String,
    image: Option<String>,
    audio: Option<String>,
}

impl FieldDigest {
    fn of(raw: &str) -> Option<FieldDigest> {
        let d = FieldDigest {
            preview: preview_text(raw),
            image: first_image(raw),
            audio: first_sound(raw),
        };
        (!d.preview.is_empty() || d.image.is_some() || d.audio.is_some()).then_some(d)
    }
}

impl Detail {
    /// 投影里存下的全部文本（测试用：确认不含字段原文）。
    #[cfg(test)]
    fn texts(&self) -> Vec<&str> {
        self.fields
            .values()
            .flat_map(|f| {
                std::iter::once(f.preview.as_str())
                    .chain(f.image.as_deref())
                    .chain(f.audio.as_deref())
            })
            .collect()
    }
}

fn sound_re() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"\[sound:([^\]]*)\]").expect("static regex"))
}

fn img_re() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| {
        regex::Regex::new(r#"(?i)<img\b[^>]*?\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
            .expect("static regex")
    })
}

/// 字段摘要：去 `[sound:…]`、去 HTML、trim，截到 120 个字符。
fn preview_text(raw: &str) -> String {
    let no_sound = sound_re().replace_all(raw, "");
    let stripped = search::strip_html(&no_sound);
    dart_trim(&stripped).chars().take(120).collect()
}

fn first_image(raw: &str) -> Option<String> {
    img_re().captures_iter(raw).find_map(|c| {
        let m = c.get(1).or_else(|| c.get(2)).or_else(|| c.get(3))?;
        Some(m.as_str().trim().to_owned()).filter(|x| !x.is_empty())
    })
}

fn first_sound(raw: &str) -> Option<String> {
    sound_re()
        .captures_iter(raw)
        .find_map(|c| Some(c.get(1)?.as_str().trim().to_owned()).filter(|x| !x.is_empty()))
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
        let s = |k: &str| {
            v.get(k)
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| format!("browse: type missing {k}"))
        };
        let id = s("id")?;
        let mut fields = Vec::new();
        let mut slot_names: Vec<String> = Vec::new();
        let mut slot_ids: Vec<String> = Vec::new();
        let mut alias: HashMap<String, String> = HashMap::new();
        for f in v
            .get("fields")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let fid = f
                .get(0)
                .and_then(Value::as_str)
                .ok_or("browse: bad field")?
                .to_owned();
            let name = f
                .get(1)
                .and_then(Value::as_str)
                .ok_or("browse: bad field")?
                .to_owned();
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
        for t in v
            .get("tpls")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let tid = t
                .get(0)
                .and_then(Value::as_str)
                .ok_or("browse: bad template")?
                .to_owned();
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
        self.fields
            .iter()
            .find(|(_, n)| dart_lower(n) == lower)
            .map(|(id, _)| id.as_str())
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
    /// 保持率用的 FSRS 模型原文（Dart `srsBrowseModels`）：`[算法, 参数]`、牌组 → 下标、其余牌组的下标。没带
    /// （旧调用方）= 不算保持率。
    models: Vec<(String, Value)>,
    deck_models: HashMap<String, usize>,
    fallback_model: Option<usize>,
}

impl Ctx {
    fn parse(req: &Value) -> Result<Ctx, String> {
        let i = |k: &str| {
            req.get(k)
                .and_then(Value::as_i64)
                .ok_or_else(|| format!("browse: missing {k}"))
        };
        let day = Day {
            utc_offset_min: i("utcOff")?,
            rollover_hour: i("rollover")?,
        };
        let now = i("now")?;
        let mut types = HashMap::new();
        for t in req
            .get("types")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
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
        let instant = req.get("instant").and_then(Value::as_array).map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        });
        let models = req
            .get("models")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|m| {
                (
                    m.get(0).and_then(Value::as_str).unwrap_or("").to_owned(),
                    m.get(1).cloned().unwrap_or(Value::Null),
                )
            })
            .collect();
        let deck_models = req
            .get("deckModels")
            .and_then(Value::as_object)
            .map(|m| {
                m.iter()
                    .filter_map(|(k, v)| Some((k.clone(), v.as_u64()? as usize)))
                    .collect()
            })
            .unwrap_or_default();
        let fallback_model = req
            .get("fallbackModel")
            .and_then(Value::as_u64)
            .map(|v| v as usize);
        Ok(Ctx {
            types,
            decks,
            fallback,
            instant,
            now,
            day,
            today: day.index(now),
            shape: json!([req.get("types"), req.get("decks"), req.get("fallback")]),
            models,
            deck_models,
            fallback_model,
        })
    }

    /// 保持率的算子：按卡所在牌组的 FSRS 模型（建一次）× 距上次复习的小数天（与统计页 `srs_stats_loader.dart` 同
    /// 一个公式：fsrs crate `current_retrievability`，记忆状态取卡片缓存的 stability / difficulty）。新卡、没有记忆
    /// 状态或上次复习时刻、模型建不起来 = None。
    fn retention(&self) -> Retention<'_> {
        let models = self
            .models
            .iter()
            .map(|(alg, params)| {
                crate::Algorithm::parse(alg)
                    .ok()
                    .and_then(|a| crate::build_model(a, Some(params)).ok())
            })
            .collect();
        Retention { ctx: self, models }
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
            _ => c
                .due_at
                .map(|at| (at - self.day_start(self.today + 1)) / DAY_MS),
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

struct Retention<'c> {
    ctx: &'c Ctx,
    models: Vec<Option<fsrs::FSRS>>,
}

impl Retention<'_> {
    fn of(&self, c: &Card) -> Option<f64> {
        if c.queue == Q_NEW {
            return None;
        }
        let (s, d, last) = (c.stab?, c.diff?, c.last_rev?);
        let k = self
            .ctx
            .deck_models
            .get(&c.deck)
            .copied()
            .or(self.ctx.fallback_model)?;
        let model = self.models.get(k)?.as_ref()?;
        let memory = crate::Memory {
            s: s as f32,
            d: d as f32,
            sf: None,
        };
        let elapsed = (self.ctx.now - last).max(0) as f64 / DAY_MS as f64;
        let r = model.current_retrievability(memory.to_fsrs(), elapsed as f32);
        r.is_finite().then_some(f64::from(r))
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
        .then_with(|| {
            ctx.types[&na.ty]
                .ordinal(ca)
                .cmp(&ctx.types[&nb.ty].ordinal(cb))
        })
        .then_with(|| cmp16(&ca.id, &cb.id))
}

impl View {
    fn build(s: &Session, ctx: &Ctx) -> Result<View, String> {
        // 可见卡：笔记在（未删除）、笔记类型在且没删。
        let mut order: Vec<u32> = Vec::new();
        for (slot, c) in s.cards.iter().enumerate() {
            let Some(c) = c else { continue };
            let Some(&ns) = s.note_at.get(&c.note) else {
                continue;
            };
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
        let mut type_ids: Vec<&String> = ctx
            .types
            .iter()
            .filter(|(_, t)| !t.deleted)
            .map(|(id, _)| id)
            .collect();
        type_ids.sort();
        let mut schema_of: HashMap<String, u32> = HashMap::new();
        let mut schema_names: Vec<Vec<u32>> = Vec::new();
        let mut schema_alias: Vec<Vec<u32>> = Vec::new();
        for id in type_ids {
            let ty = &ctx.types[id];
            schema_of.insert(id.clone(), schema_names.len() as u32);
            schema_names.push(ty.slot_names.iter().map(|x| it.id(x)).collect());
            schema_alias.push(
                ty.slot_alias
                    .iter()
                    .map(|a| a.as_deref().map_or(search::NO_ALIAS, |a| it.id(a)))
                    .collect(),
            );
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
            fields: if s.full {
                HashSet::new()
            } else {
                s.fields.clone()
            },
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
    fn upload(
        &mut self,
        s: &Session,
        ctx: &Ctx,
        notes: &[u32],
        only: Option<&HashSet<String>>,
    ) -> Result<(), String> {
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
            let Some(vn) = self.note_of.remove(id) else {
                continue;
            };
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
                    cards_of
                        .entry(c.note.as_str())
                        .or_default()
                        .push(slot as u32);
                }
            }
        }
        let mut added: Vec<u32> = Vec::new();
        let mut ids: Vec<&String> = dirty.iter().collect();
        ids.sort();
        for id in ids {
            let Some(&ns) = s.note_at.get(id) else {
                continue;
            };
            let n = s.note(ns);
            let Some(ty) = ctx.types.get(&n.ty).filter(|t| !t.deleted) else {
                continue;
            };
            let Some(mut cards) = cards_of.remove(id.as_str()) else {
                continue;
            };
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
                let at = self.natural.partition_point(|&y| {
                    natural_cmp(s, ctx, self.order[y as usize], slot) == Ordering::Less
                });
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
    Retention,
    Reps,
    Lapses,
    Deck,
    NoteType,
    /// 出处键（[source_key]；没有出处的排最后）：表格按出处分组用。
    Source,
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
            "retention" => Column::Retention,
            "reps" => Column::Reps,
            "lapses" => Column::Lapses,
            "deck" => Column::Deck,
            "noteType" => Column::NoteType,
            "source" => Column::Source,
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
    if asc { c } else { c.reverse() }
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
    /// 全部笔记的出处寄存器已装（`src:` / `browse_sources` 第一次用到时整列读一次，之后随写入按笔记重读）。
    sources: bool,
    /// 取过行的笔记的内容（[Detail]）：笔记 id → 详情；写过的笔记丢掉，下次取行重读。
    detail: HashMap<String, Detail>,
}

/// 按笔记读修改记录（[notes] = None：本 profile 全部笔记；[keys] 非空 = 只读这几个原样的字段键），每条笔记的记录
/// 交给 [sink] 一次（按笔记 id 排；没有记录的笔记不调用）。
fn read_edits(
    c: &Connection,
    profile: &str,
    notes: Option<&[String]>,
    keys: &[String],
    sink: &mut dyn FnMut(&str, &[StoredEdit<'_>]) -> Result<(), String>,
) -> Result<(), String> {
    let key_filter = |first: usize| {
        if keys.is_empty() {
            String::new()
        } else {
            format!(
                " AND f.field_key IN ({})",
                (first..first + keys.len())
                    .map(|i| format!("?{i}"))
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        }
    };
    let mut run = |q: &str, args: Vec<Sql>| -> Result<(), String> {
        let mut stmt = c.prepare_cached(q).map_err(sql)?;
        let mut rows = stmt.query(params_from_iter(args)).map_err(sql)?;
        let mut cur: Option<String> = None;
        let mut edits: Vec<(String, Option<i64>, Option<registers::EditCols>)> = Vec::new();
        let mut flush = |id: Option<String>,
                         edits: &mut Vec<(String, Option<i64>, Option<registers::EditCols>)>|
         -> Result<(), String> {
            let Some(id) = id else { return Ok(()) };
            let stored: Vec<StoredEdit<'_>> = edits
                .iter()
                .map(|(j, t, c)| (j.as_str(), *t, c.as_ref()))
                .collect();
            sink(&id, &stored)?;
            edits.clear();
            Ok(())
        };
        while let Some(r) = rows.next().map_err(sql)? {
            let id: String = r.get(0).map_err(sql)?;
            if cur.as_deref() != Some(id.as_str()) {
                flush(cur.take(), &mut edits)?;
                cur = Some(id);
            }
            let (j, cols) = super::slim::edit_row(r, 2).map_err(sql)?;
            edits.push((j, r.get(1).map_err(sql)?, cols));
        }
        flush(cur.take(), &mut edits)
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
            let q = format!(
                "{SELECT} AND +f.profile_uid = srs_id(?1){} ORDER BY f.entity_id",
                key_filter(2)
            );
            let args: Vec<Sql> = std::iter::once(Sql::Text(profile.to_owned()))
                .chain(keys.iter().map(|k| Sql::Text(k.clone())))
                .collect();
            run(&q, args)?;
        }
        Some(ids) => {
            for chunk in ids.chunks(CHUNK) {
                let q = format!(
                    "{SELECT} AND f.entity_id IN ({}) AND +f.profile_uid = srs_id(?1){} ORDER BY f.entity_id",
                    (2..chunk.len() + 2)
                        .map(|i| format!("srs_id(?{i})"))
                        .collect::<Vec<_>>()
                        .join(", "),
                    key_filter(chunk.len() + 2)
                );
                let args: Vec<Sql> = std::iter::once(Sql::Text(profile.to_owned()))
                    .chain(chunk.iter().map(|k| Sql::Text(k.clone())))
                    .chain(keys.iter().map(|k| Sql::Text(k.clone())))
                    .collect();
                run(&q, args)?;
            }
        }
    }
    Ok(())
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
            sources: false,
            detail: HashMap::new(),
        };
        {
            let q = format!(
                "SELECT {NOTE_COLUMNS} FROM srs_notes_cache WHERE profile_uid = srs_id(?1) AND deleted_at IS NULL"
            );
            let mut stmt = c.prepare_cached(&q).map_err(sql)?;
            let mut rows = stmt.query([profile]).map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                let n = note_of(r).map_err(sql)?;
                s.note_at.insert(n.id.clone(), s.notes.len() as u32);
                s.notes.push(Some(n));
            }
        }
        let q = format!(
            "SELECT {CARD_COLUMNS} FROM srs_cards_cache WHERE profile_uid = srs_id(?1) AND hidden = 0"
        );
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
                (2..chunk.len() + 2)
                    .map(|i| format!("srs_id(?{i})"))
                    .collect::<Vec<_>>()
                    .join(", ")
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
        for id in &ids {
            self.detail.remove(*id);
        }
        let mut present: Vec<String> = Vec::new();
        for chunk in ids.chunks(CHUNK) {
            let q = format!(
                "SELECT {NOTE_COLUMNS} FROM srs_notes_cache WHERE id IN ({}) AND +profile_uid = srs_id(?1) AND deleted_at IS NULL",
                (2..chunk.len() + 2)
                    .map(|i| format!("srs_id(?{i})"))
                    .collect::<Vec<_>>()
                    .join(", ")
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
            let keys: Option<Vec<String>> = if self.full {
                None
            } else {
                Some(self.fields.iter().cloned().collect())
            };
            self.load_values(c, profile, Some(&present), keys.as_deref())?;
            self.view_dirty.extend(present.iter().cloned());
        }
        if self.sources && !present.is_empty() {
            self.load_sources(c, profile, Some(&present))?;
        }
        Ok(())
    }

    /// 从修改记录读字段原文（[notes] = None：全部笔记；[keys] = None：全部字段 + 最后改动时刻）。
    fn load_values(
        &mut self,
        c: &Connection,
        profile: &str,
        notes: Option<&[String]>,
        keys: Option<&[String]>,
    ) -> Result<(), String> {
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
        self.for_notes(notes, reset);
        let raw: Vec<String> = keys
            .map(|ks| ks.iter().map(|k| format!("f/{k}")).collect())
            .unwrap_or_default();
        read_edits(c, profile, notes, &raw, &mut |id, stored| {
            let (values, modified) = registers::note_browse_values(stored)?;
            let Some(&slot) = self.note_at.get(id) else {
                return Ok(());
            };
            let n = self.notes[slot as usize].as_mut().expect("indexed note");
            if keys.is_none() {
                n.modified = modified;
            }
            for (k, v) in values {
                n.values.insert(k, v);
            }
            Ok(())
        })
    }

    fn for_notes(&mut self, notes: Option<&[String]>, mut f: impl FnMut(&mut Note)) {
        match notes {
            None => self.notes.iter_mut().flatten().for_each(f),
            Some(ids) => {
                for id in ids {
                    if let Some(&slot) = self.note_at.get(id) {
                        f(self.notes[slot as usize].as_mut().expect("indexed note"));
                    }
                }
            }
        }
    }

    /// 从修改记录读出处寄存器（[notes] = None：全部笔记）。
    fn load_sources(
        &mut self,
        c: &Connection,
        profile: &str,
        notes: Option<&[String]>,
    ) -> Result<(), String> {
        self.for_notes(notes, |n| n.source = None);
        read_edits(
            c,
            profile,
            notes,
            &["source".to_owned()],
            &mut |id, stored| {
                let (_, _, source) = registers::note_browse_detail(stored)?;
                let Some(&slot) = self.note_at.get(id) else {
                    return Ok(());
                };
                self.notes[slot as usize]
                    .as_mut()
                    .expect("indexed note")
                    .source = (!source.is_null()).then_some(source);
                Ok(())
            },
        )
    }

    fn ensure_sources(&mut self, c: &Connection, profile: &str) -> Result<(), String> {
        if !self.sources {
            self.load_sources(c, profile, None)?;
            self.sources = true;
        }
        Ok(())
    }

    /// 补齐 [notes] 里还没有 [Detail] 的那几条（一次读它们的全部修改记录）。
    fn ensure_detail(
        &mut self,
        c: &Connection,
        profile: &str,
        notes: &[String],
    ) -> Result<(), String> {
        let missing: Vec<String> = notes
            .iter()
            .filter(|id| !self.detail.contains_key(*id))
            .cloned()
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();
        if missing.is_empty() {
            return Ok(());
        }
        for id in &missing {
            self.detail.insert(
                id.clone(),
                Detail {
                    fields: HashMap::new(),
                    modified: None,
                    source: Value::Null,
                },
            );
        }
        let detail = &mut self.detail;
        read_edits(c, profile, Some(&missing), &[], &mut |id, stored| {
            let (values, modified, source) = registers::note_browse_detail(stored)?;
            if let Some(d) = detail.get_mut(id) {
                *d = Detail {
                    // [values] 的键已是去掉 `f/` 的字段 id；原文就地算成投影后丢掉。
                    fields: values
                        .into_iter()
                        .filter_map(|(id, raw)| Some((id, FieldDigest::of(&raw)?)))
                        .collect(),
                    modified,
                    source,
                };
            }
            Ok(())
        })
    }

    /// 装好 [want] 要的字段列（None = 全部字段 + 最后改动时刻）。装了新列结构就变了。
    fn ensure_fields(
        &mut self,
        c: &Connection,
        profile: &str,
        want: Option<&HashSet<String>>,
    ) -> Result<(), String> {
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
                let missing: Vec<String> = ids
                    .iter()
                    .filter(|f| !self.fields.contains(*f))
                    .cloned()
                    .collect();
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
        let reusable = self
            .view
            .as_ref()
            .is_some_and(|v| v.shape == self.shape && v.ctx == ctx.shape);
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
        let node = req
            .get("node")
            .filter(|n| !n.is_null() && n.get("t").and_then(Value::as_str) != Some("all"));
        let sort = req.get("sort").cloned().unwrap_or(Value::Null);
        let column = Column::parse(sort.get("col").and_then(Value::as_str).unwrap_or("created"))?;
        let asc = sort.get("asc").and_then(Value::as_bool).unwrap_or(false);
        let field = sort.get("field").and_then(Value::as_str).map(dart_lower);
        let cards_mode = req.get("mode").and_then(Value::as_str) != Some("notes");
        let params = json!([
            req.get("node"),
            sort,
            cards_mode,
            req.get("types"),
            req.get("decks"),
            req.get("fallback"),
            req.get("instant"),
            ctx.today,
            ctx.now
        ]);

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
        if column == Column::Source {
            self.ensure_sources(c, profile)?;
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
        let retention = (column == Column::Retention).then(|| ctx.retention());
        let keys: Vec<Key> = rows
            .iter()
            .map(|(p, cs)| {
                self.sort_key(
                    view,
                    &ctx,
                    retention.as_ref(),
                    column,
                    field.as_deref(),
                    *p,
                    cs,
                )
            })
            .collect();
        drop(retention);
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
        let rewritten = match node {
            Some(n) if SESSION_LEAVES.iter().any(|t| uses(n, t)) => {
                Some(self.rewrite(c, profile, ctx, n)?)
            }
            _ => None,
        };
        let node = rewritten.as_ref().or(node);
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
                    let names: HashSet<&str> = ids
                        .iter()
                        .map(|&i| view.strings[i as usize].as_str())
                        .collect();
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
                    Ok(_) => Ok(view
                        .natural
                        .iter()
                        .copied()
                        .filter(|&i| out[i as usize] != 0)
                        .collect()),
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
        let mut cols: Vec<Vec<i64>> = (0..search::INT_COLUMNS)
            .map(|k| {
                if want(k) {
                    Vec::with_capacity(n)
                } else {
                    Vec::new()
                }
            })
            .collect();
        let (want_stab, want_diff, want_r) = (floats & 1 != 0, floats & 2 != 0, floats & 4 != 0);
        let mut stab = Vec::with_capacity(if want_stab { n } else { 0 });
        let mut diff = Vec::with_capacity(if want_diff { n } else { 0 });
        let mut recall = Vec::with_capacity(if want_r { n } else { 0 });
        let retention = if want_r { Some(ctx.retention()) } else { None };
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
                if want_r {
                    recall.push(f64::NAN);
                }
                continue;
            }
            let c = self.cards[slot as usize].as_ref().expect("visible card");
            let note = self.notes[view.note_slot[view.card_note[i] as usize] as usize]
                .as_ref()
                .expect("visible note");
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
            if let Some(r) = &retention {
                recall.push(r.of(c).unwrap_or(f64::NAN));
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
        if want_r {
            view.corpus.set_floats(2, &recall)?;
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn sort_key(
        &self,
        view: &View,
        ctx: &Ctx,
        retention: Option<&Retention<'_>>,
        column: Column,
        field: Option<&str>,
        primary: u32,
        cs: &[u32],
    ) -> Key {
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
                    Some(id) => {
                        Key::Str(dart_lower(dart_trim(&search::strip_html(note.value(id)))))
                    }
                    None => Key::None,
                }
            }
            Column::Due => Key::Num(
                cards()
                    .map(|c| ctx.due_sort_key(c))
                    .fold(f64::INFINITY, |a, b| if b < a { b } else { a }),
            ),
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
            Column::Retention => {
                let Some(r) = retention else { return Key::None };
                if notes {
                    avg(cards().filter_map(|c| r.of(c)).collect())
                } else {
                    r.of(p).map_or(Key::None, Key::Num)
                }
            }
            Column::Reps => Key::Num(cards().map(|c| c.reps).sum::<i64>() as f64),
            Column::Lapses => Key::Num(cards().map(|c| c.lapses).sum::<i64>() as f64),
            Column::Deck => Key::Str(dart_lower(&ctx.deck(&p.deck).0)),
            Column::NoteType => Key::Str(dart_lower(&ctx.types[&note.ty].name)),
            Column::Source => note
                .source
                .as_ref()
                .and_then(source_key)
                .map_or(Key::None, |k| Key::Str(k.0)),
        }
    }

    fn result(&self, req: &Value) -> Result<&Res, String> {
        let gen = req
            .get("gen")
            .and_then(Value::as_u64)
            .ok_or("browse: missing gen")?;
        self.results
            .iter()
            .find(|r| r.gen == gen)
            .ok_or_else(|| format!("browse: result {gen} is gone"))
    }

    /// 结果的一段行（`from..to`）：字符串列走 JSON（`[卡 id, 笔记 id, 排序字段, 牌组名, 笔记类型名, 牌组 id, 模板名, 标签,
    /// 字段摘要, 图片, 音频, 出处键, 出处 kind, 出处 JSON, 字段摘要各自的字段名, 笔记类型的模板数]`；模板数 > 1 时浏览页在卡片行上标出模板名），整数列每行 11 个 i64（小端）放进 `rows.i64`：`[队列 (0 新 /
    /// 1 学习 / 2 复习 / 3 重学；-1 = 卡已不在), 到期天数 (i64::MIN = 没有), 旗标, 位 (1 暂停 / 2 搁置 / 4 待裁决), 该行
    /// 卡数, 复习次数, 遗忘次数, 间隔 (新卡 i64::MIN), 添加时刻, 修改时刻, 上次复习时刻 (i64::MIN = 没有)]`，小数列每行
    /// 2 个 f64 放进 `rows.f64`：`[难度, 保持率]`（NaN = 没有）。行的数据取会话里**此刻**的值（结果之后的写入已重读
    /// 进来）；字段原文 / 修改时刻 / 出处只为这一页的笔记读一次（[Session::ensure_detail]）。
    fn rows(
        &mut self,
        c: &Connection,
        profile: &str,
        req: &Value,
        files: &mut Vec<(String, Vec<u8>)>,
    ) -> Result<Value, String> {
        let page: Vec<String> = {
            let r = self.result(req)?;
            let (from, to) = page_range(req, r.rows.len());
            r.rows[from..to]
                .iter()
                .filter_map(|row| self.notes[row.note as usize].as_ref().map(|n| n.id.clone()))
                .collect()
        };
        self.ensure_detail(c, profile, &page)?;
        let r = self.result(req)?;
        let (from, to) = page_range(req, r.rows.len());
        let retention = r.ctx.retention();
        let mut strings: Vec<Value> = Vec::with_capacity(to - from);
        let mut ints: Vec<u8> = Vec::with_capacity((to - from) * 88);
        let mut floats: Vec<u8> = Vec::with_capacity((to - from) * 16);
        for row in &r.rows[from..to] {
            let c = self.cards[row.primary as usize].as_ref();
            let n = self.notes[row.note as usize].as_ref();
            let (Some(c), Some(n)) = (c, n) else {
                strings.push(json!([
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    [],
                    [],
                    null,
                    null,
                    null,
                    null,
                    null,
                    [],
                    0
                ]));
                for v in [-1i64, DUE_NONE, 0, 0, 0, 0, 0, DUE_NONE, 0, 0, DUE_NONE] {
                    ints.extend_from_slice(&v.to_le_bytes());
                }
                for v in [f64::NAN, f64::NAN] {
                    floats.extend_from_slice(&v.to_le_bytes());
                }
                continue;
            };
            let ty = r.ctx.types.get(&n.ty);
            let detail = self.detail.get(&n.id);
            let digest = |id: &str| detail.and_then(|d| d.fields.get(id));
            let fields: &[(String, String)] = ty.map_or(&[], |t| t.fields.as_slice());
            // 摘要与它来自的字段名（表格原地改这两列时按名字写回）。
            let (preview, preview_fields): (Vec<&str>, Vec<&str>) = fields
                .iter()
                .skip(1)
                .filter_map(|(id, name)| digest(id).map(|f| (f.preview.as_str(), name.as_str())))
                .filter(|(t, _)| !t.is_empty())
                .take(2)
                .unzip();
            let image = fields
                .iter()
                .find_map(|(id, _)| digest(id).and_then(|f| f.image.as_deref()));
            let audio = fields
                .iter()
                .find_map(|(id, _)| digest(id).and_then(|f| f.audio.as_deref()));
            let source = detail.map(|d| &d.source).filter(|v| !v.is_null());
            let key = source.and_then(source_key);
            strings.push(json!([
                c.id,
                n.id,
                n.sort,
                r.ctx.deck(&c.deck).0,
                ty.map_or("", |t| t.name.as_str()),
                c.deck,
                ty.map_or("", |t| t.template_name(c)),
                n.tags,
                preview,
                image,
                audio,
                key.as_ref().map(|k| &k.0),
                key.as_ref().map(|k| &k.1),
                key.as_ref().and(source).map(Value::to_string),
                preview_fields,
                ty.map_or(0, |t| t.tpls.len()),
            ]));
            let bits = i64::from(c.suspended)
                | (i64::from(r.ctx.is_buried(c)) << 1)
                | (i64::from(n.pending) << 2);
            let modified = detail
                .and_then(|d| d.modified)
                .map_or(n.created, |m| m.max(n.created));
            for v in [
                i64::from(c.queue),
                r.ctx.due_in_days(c).unwrap_or(DUE_NONE),
                c.flag,
                bits,
                row.cards.len() as i64,
                c.reps,
                c.lapses,
                if c.queue == Q_NEW {
                    DUE_NONE
                } else {
                    interval_days(c)
                },
                n.created,
                modified,
                c.last_rev.unwrap_or(DUE_NONE),
            ] {
                ints.extend_from_slice(&v.to_le_bytes());
            }
            for v in [
                c.diff.unwrap_or(f64::NAN),
                retention.of(c).unwrap_or(f64::NAN),
            ] {
                floats.extend_from_slice(&v.to_le_bytes());
            }
        }
        files.push(("rows.i64".to_owned(), ints));
        files.push(("rows.f64".to_owned(), floats));
        Ok(json!({"s": strings}))
    }

    /// `browse_sources`：结果按出处键分组（出处视图）。组 `{key, kind, data, count, due, preview, latestAddedAt, decks}`：
    /// `decks` = 组里各行的卡所在的牌组 id（去重，首次出现的顺序；「只复习这一作」据此定复习的牌组范围）；`data`
    /// 是组里最近添加那条笔记的出处 JSON，`due` = 有卡今天到期的行数，`preview` = 组内按结果顺序的前 8 个行号；按
    /// `latestAddedAt` 降序（同值按键），没有出处的一组（`key` = null）放最后。
    fn sources(&mut self, c: &Connection, profile: &str, req: &Value) -> Result<Value, String> {
        self.result(req)?;
        self.ensure_sources(c, profile)?;
        let r = self.result(req)?;
        struct Group<'a> {
            kind: Option<String>,
            data: Option<&'a Value>,
            count: usize,
            due: usize,
            preview: Vec<usize>,
            latest: i64,
            decks: Vec<&'a str>,
        }
        let mut order: Vec<Option<String>> = Vec::new();
        let mut groups: HashMap<Option<String>, Group<'_>> = HashMap::new();
        for (i, row) in r.rows.iter().enumerate() {
            let Some(n) = self.notes[row.note as usize].as_ref() else {
                continue;
            };
            let source = n.source.as_ref();
            let key = source.and_then(source_key);
            let (k, kind) = match key {
                Some((k, kind)) => (Some(k), Some(kind)),
                None => (None, None),
            };
            let g = groups.entry(k.clone()).or_insert_with(|| {
                order.push(k.clone());
                Group {
                    kind,
                    data: None,
                    count: 0,
                    due: 0,
                    preview: Vec::new(),
                    latest: i64::MIN,
                    decks: Vec::new(),
                }
            });
            g.count += 1;
            for &slot in &row.cards {
                if let Some(card) = self.cards[slot as usize].as_ref() {
                    if !g.decks.contains(&card.deck.as_str()) {
                        g.decks.push(card.deck.as_str());
                    }
                }
            }
            if row.cards.iter().any(|&slot| {
                self.cards[slot as usize]
                    .as_ref()
                    .is_some_and(|c| r.ctx.is_due(c))
            }) {
                g.due += 1;
            }
            if g.preview.len() < 8 {
                g.preview.push(i);
            }
            if n.created > g.latest {
                g.latest = n.created;
                g.data = source.filter(|_| k.is_some());
            }
        }
        order.sort_by(|a, b| match (a, b) {
            (None, None) => Ordering::Equal,
            (None, _) => Ordering::Greater,
            (_, None) => Ordering::Less,
            (Some(x), Some(y)) => groups[b]
                .latest
                .cmp(&groups[a].latest)
                .then_with(|| cmp16(x, y)),
        });
        let out: Vec<Value> = order
            .iter()
            .map(|k| {
                let g = &groups[k];
                json!({
                    "key": k,
                    "kind": g.kind,
                    "data": g.data.map(Value::to_string),
                    "count": g.count,
                    "due": g.due,
                    "preview": g.preview,
                    "latestAddedAt": g.latest,
                    "decks": g.decks,
                })
            })
            .collect();
        Ok(json!({"groups": out}))
    }

    /// `browse_counts`：几条查询各自的命中数（同 `browse_query` 的口径与上下文；`mode = notes` 数笔记）。`nodes` 每项是
    /// 语法树 JSON、null（空查询 = 全部）或 false（Dart 侧解析不了，回 -1）；求值出错的那一条回 -1。不留查询结果。
    fn counts(&mut self, c: &Connection, profile: &str, req: &Value) -> Result<Value, String> {
        let ctx = Ctx::parse(req)?;
        let notes_mode = req.get("mode").and_then(Value::as_str) == Some("notes");
        let nodes = req
            .get("nodes")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let mut out: Vec<i64> = Vec::with_capacity(nodes.len());
        for node in &nodes {
            if *node == Value::Bool(false) {
                out.push(-1);
                continue;
            }
            let node = Some(node)
                .filter(|n| !n.is_null() && n.get("t").and_then(Value::as_str) != Some("all"));
            let hits = match self.hits(c, profile, &ctx, node, false, HashSet::new())? {
                Ok(h) => h,
                Err(_) => {
                    out.push(-1);
                    continue;
                }
            };
            let view = self.view.as_ref().expect("view");
            out.push(if notes_mode {
                // 命中按自然顺序：同一条笔记的卡挨着。
                let mut last: Option<u32> = None;
                hits.iter()
                    .filter(|&&h| {
                        let vn = view.card_note[h as usize];
                        let new = last != Some(vn);
                        last = Some(vn);
                        new
                    })
                    .count() as i64
            } else {
                hits.len() as i64
            });
        }
        Ok(json!({"counts": out}))
    }

    /// 把只有会话才求得了值的叶子（`rated` / `src` / `dupe` / `emptyfield`）换成等价的 id 集合（`cid` / `nid`，按
    /// AnkiConnect 数字 id），其余原样。
    fn rewrite(
        &mut self,
        c: &Connection,
        profile: &str,
        ctx: &Ctx,
        node: &Value,
    ) -> Result<Value, String> {
        if uses(node, "src") {
            self.ensure_sources(c, profile)?;
        }
        let mut dupes: Option<Vec<i64>> = None;
        self.rewrite_node(c, profile, ctx, node, &mut dupes)
    }

    fn rewrite_node(
        &self,
        c: &Connection,
        profile: &str,
        ctx: &Ctx,
        node: &Value,
        dupes: &mut Option<Vec<i64>>,
    ) -> Result<Value, String> {
        let t = node.get("t").and_then(Value::as_str).unwrap_or("");
        let notes_where = |pred: &dyn Fn(&Note) -> bool| -> Value {
            let ids: Vec<i64> = self
                .notes
                .iter()
                .flatten()
                .filter(|n| pred(n))
                .map(|n| n.num)
                .collect();
            json!({"t": "nid", "v": ids})
        };
        Ok(match t {
            "and" | "or" => {
                let kids = node
                    .get("c")
                    .and_then(Value::as_array)
                    .map(Vec::as_slice)
                    .unwrap_or_default();
                let kids: Vec<Value> = kids
                    .iter()
                    .map(|k| self.rewrite_node(c, profile, ctx, k, dupes))
                    .collect::<Result<_, _>>()?;
                json!({"t": t, "c": kids})
            }
            "not" => match node.get("c") {
                Some(k) => json!({"t": "not", "c": self.rewrite_node(c, profile, ctx, k, dupes)?}),
                None => node.clone(),
            },
            "emptyfield" => notes_where(&|n| dart_trim(&n.sort).is_empty()),
            "dupe" => {
                let ids = dupes.get_or_insert_with(|| {
                    let mut count: HashMap<(&str, &str), usize> = HashMap::new();
                    let live = |n: &&Note| {
                        !n.dupe.is_empty() && ctx.types.get(&n.ty).is_some_and(|t| !t.deleted)
                    };
                    for n in self.notes.iter().flatten().filter(live) {
                        *count.entry((n.ty.as_str(), n.dupe.as_str())).or_default() += 1;
                    }
                    self.notes
                        .iter()
                        .flatten()
                        .filter(live)
                        .filter(|n| count[&(n.ty.as_str(), n.dupe.as_str())] > 1)
                        .map(|n| n.num)
                        .collect()
                });
                json!({"t": "nid", "v": ids})
            }
            "src" => {
                let v = node.get("v").and_then(Value::as_str).unwrap_or("");
                match v {
                    "none" => notes_where(&|n| n.source.as_ref().and_then(source_key).is_none()),
                    _ if v.contains(':') => notes_where(&|n| {
                        n.source
                            .as_ref()
                            .and_then(source_key)
                            .is_some_and(|k| k.0 == v)
                    }),
                    _ => notes_where(&|n| {
                        n.source
                            .as_ref()
                            .and_then(source_key)
                            .is_some_and(|k| k.1 == v)
                    }),
                }
            }
            "rated" => {
                let days = node.get("d").and_then(Value::as_i64).unwrap_or(1).max(1);
                let since = ctx.day_start(ctx.today - days + 1);
                let rating = node.get("e").and_then(Value::as_i64);
                let q = format!(
                    "SELECT DISTINCT srs_idt(card_id) FROM srs_stat_reviews WHERE profile_uid = srs_id(?1) AND occurred_at >= ?2 \
                     AND rating IS NOT NULL{}",
                    if rating.is_some() {
                        " AND rating = ?3"
                    } else {
                        ""
                    }
                );
                let mut args: Vec<Sql> = vec![Sql::Text(profile.to_owned()), Sql::Integer(since)];
                if let Some(e) = rating {
                    args.push(Sql::Integer(e));
                }
                let mut stmt = c.prepare_cached(&q).map_err(sql)?;
                let mut rows = stmt.query(params_from_iter(args)).map_err(sql)?;
                let mut ids: Vec<i64> = Vec::new();
                while let Some(r) = rows.next().map_err(sql)? {
                    let id: String = r.get(0).map_err(sql)?;
                    if let Some(card) = self
                        .card_at
                        .get(&id)
                        .and_then(|&slot| self.cards[slot as usize].as_ref())
                    {
                        ids.push(card.num);
                    }
                }
                json!({"t": "cid", "v": ids})
            }
            _ => node.clone(),
        })
    }

    fn row_id(&self, r: &Res, row: &Row) -> Option<&str> {
        if r.cards_mode {
            self.cards[row.primary as usize]
                .as_ref()
                .map(|c| c.id.as_str())
        } else {
            self.notes[row.note as usize]
                .as_ref()
                .map(|n| n.id.as_str())
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
            let out: Vec<i64> = find
                .iter()
                .map(|v| v.as_str().and_then(|s| at.get(s)).map_or(-1, |&i| i as i64))
                .collect();
            return Ok(json!({"at": out}));
        }
        let from =
            (req.get("from").and_then(Value::as_u64).unwrap_or(0) as usize).min(r.rows.len());
        let to = (req
            .get("to")
            .and_then(Value::as_u64)
            .map_or(r.rows.len(), |t| t as usize))
        .clamp(from, r.rows.len());
        let ids: Vec<&str> = r.rows[from..to]
            .iter()
            .map(|row| self.row_id(r, row).unwrap_or(""))
            .collect();
        Ok(json!({"ids": ids}))
    }

    /// 批量操作的目标：`ids`（行 id）对应的行按结果顺序展开成卡 / 笔记 id，连同这些卡是否全暂停 / 全搁置、
    /// 出现过的旗标与牌组。
    fn targets(&self, req: &Value) -> Result<Value, String> {
        let r = self.result(req)?;
        let want: HashSet<&str> = req
            .get("ids")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
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
            let Some(n) = self.notes[row.note as usize].as_ref() else {
                continue;
            };
            if seen_notes.insert(n.id.as_str()) {
                notes.push(n.id.as_str());
            }
            for &slot in &row.cards {
                let Some(c) = self.cards[slot as usize].as_ref() else {
                    continue;
                };
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
    fn anki_find(
        &mut self,
        c: &Connection,
        profile: &str,
        req: &Value,
        files: &mut Vec<(String, Vec<u8>)>,
    ) -> Result<Value, String> {
        let ctx = Ctx::parse(req)?;
        let node = req
            .get("node")
            .filter(|n| !n.is_null() && n.get("t").and_then(Value::as_str) != Some("all"));
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
        Ok(if want_uuids {
            json!({"count": count, "cards": uuids})
        } else {
            json!({"count": count})
        })
    }

    /// `anki_tags`：全部未删除笔记的标签，去重、按 Dart `String.compareTo`（UTF-16 码元）排。
    fn anki_tags(&self) -> Value {
        let mut tags: Vec<&str> = self
            .notes
            .iter()
            .flatten()
            .flat_map(|n| n.tags.iter().map(String::as_str))
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();
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
    let types: HashSet<&str> = req
        .get("first")
        .and_then(Value::as_object)
        .map(|m| m.keys().map(String::as_str).collect())
        .unwrap_or_default();
    let cands = req
        .get("cands")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    if cands.is_empty() {
        return Ok(json!({"dup": []}));
    }
    let norm_of = |cand: &Value| {
        cand.get("norm")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned()
    };
    // 规范形 → 库里的 (笔记 id, 笔记类型)。空规范形不查（调用方已判空；库里首字段为空的笔记存空串）。
    let wanted: Vec<String> = cands
        .iter()
        .map(norm_of)
        .filter(|n| !n.is_empty())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    let mut by: HashMap<String, Vec<(String, String)>> = HashMap::new();
    for chunk in wanted.chunks(CHUNK) {
        let q = format!(
            "SELECT srs_idt(id) AS id, srs_idt(note_type_id) AS note_type_id, dupe_norm FROM srs_notes_cache \
             WHERE profile_uid = srs_id(?1) AND deleted_at IS NULL AND dupe_norm IN ({})",
            (2..chunk.len() + 2)
                .map(|i| format!("?{i}"))
                .collect::<Vec<_>>()
                .join(", ")
        );
        let mut stmt = c.prepare_cached(&q).map_err(sql)?;
        let args = std::iter::once(profile).chain(chunk.iter().map(String::as_str));
        let mut rows = stmt.query(params_from_iter(args)).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            let (id, ty, norm): (String, String, String) = (
                r.get(0).map_err(sql)?,
                r.get(1).map_err(sql)?,
                r.get(2).map_err(sql)?,
            );
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
            (2..chunk.len() + 2)
                .map(|i| format!("srs_id(?{i})"))
                .collect::<Vec<_>>()
                .join(", ")
        );
        let mut stmt = c.prepare_cached(&q).map_err(sql)?;
        let args = std::iter::once(profile).chain(chunk.iter().copied());
        let mut rows = stmt.query(params_from_iter(args)).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            decks_of
                .entry(r.get(0).map_err(sql)?)
                .or_default()
                .insert(r.get(1).map_err(sql)?);
        }
    }
    let out: Vec<bool> = cands
        .iter()
        .zip(&matched)
        .map(
            |(cand, hit)| match cand.get("decks").and_then(Value::as_array) {
                None => !hit.is_empty(),
                Some(ds) => {
                    let scope: HashSet<&str> = ds.iter().filter_map(Value::as_str).collect();
                    hit.iter().any(|id| {
                        decks_of
                            .get(*id)
                            .is_some_and(|d| d.iter().any(|x| scope.contains(x.as_str())))
                    })
                }
            },
        )
        .collect();
    Ok(json!({"dup": out}))
}

/// 只在浏览会话里求得了值的叶子（[Session::rewrite] 换成 id 集合）。
const SESSION_LEAVES: [&str; 4] = ["rated", "src", "dupe", "emptyfield"];

/// 请求里的 `from..to`（夹进 `0..len`）。
fn page_range(req: &Value, len: usize) -> (usize, usize) {
    let from = (req.get("from").and_then(Value::as_u64).unwrap_or(0) as usize).min(len);
    let to = (req
        .get("to")
        .and_then(Value::as_u64)
        .map_or(len, |t| t as usize))
    .clamp(from, len);
    (from, to)
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
    pub(crate) fn browse(
        &self,
        op: &str,
        profile: &str,
        req: &Value,
        files: &mut Vec<(String, Vec<u8>)>,
    ) -> Result<Value, String> {
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
                b.owners
                    .entry(profile.to_owned())
                    .or_default()
                    .insert(o.to_owned());
            }
            let Sessions {
                live: sessions,
                built,
                ..
            } = &mut *b;
            // 先取待重读的 id 再开快照（这条连接这次读事务里第一条读在后面）。
            let dirty = self.study_hub.take_browse(profile, uncommitted);
            let fresh = dirty.overflow || !sessions.contains_key(profile);
            let ready = if fresh {
                sessions.remove(profile);
                if op != "browse_query" && op != "browse_counts" && !op.starts_with("anki_") {
                    return Err("browse: no session (query first)".into());
                }
                *built += 1;
                Session::build(c, profile).map(|s| {
                    sessions.insert(profile.to_owned(), s);
                })
            } else {
                sessions
                    .get_mut(profile)
                    .expect("checked above")
                    .apply(c, profile, &dirty)
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
                        let prev = r
                            .params
                            .as_array()
                            .map(|a| Value::Array(a[..a.len() - 1].to_vec()));
                        if !r.stale && prev.as_ref() == Some(&same) {
                            return Ok(json!({"gen": r.gen, "count": r.rows.len(), "same": true}));
                        }
                    }
                    s.query(c, profile, req)
                }
                "browse_rows" => s.rows(c, profile, req, files),
                "browse_counts" => s.counts(c, profile, req),
                "browse_sources" => s.sources(c, profile, req),
                "browse_ids" => s.ids(req),
                "browse_targets" => s.targets(req),
                "anki_find" => s.anki_find(c, profile, req, files),
                "anki_tags" => Ok(s.anki_tags()),
                _ => Err(format!("browse: unknown op {op}")),
            };
            if out.is_err()
                && (op == "browse_query" || op == "browse_counts" || op.starts_with("anki_"))
            {
                // 求值 / 装载出错：会话可能只装了一半，丢掉，下次整份重建。
                sessions.remove(profile);
            }
            out
        })
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use crate::store::caches::{CacheConfig, Dirty, refresh};
    use crate::store::sync2::in_savepoint;
    use crate::store::sync2::tests::{Device, P, deck_entity, edit};

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
        let r = call(
            d,
            "anki_dupes",
            json!({"owner": "ankiconnect", "first": {"A": "fa", "B": "x"}, "cands": cands}),
        );
        r["dup"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_bool().unwrap())
            .collect()
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
        assert_eq!(
            probe(&d),
            [true, true, false, true, false, true, true, false, false]
        );
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
        assert_eq!(
            probe(&d),
            [true, true, false, true, false, true, true, false, true]
        );
        write(
            &d,
            &cfg,
            T0 + 2000,
            vec![edit("note", N2, "deleted", json!(T0 + 2000))],
        );
        let incremental = probe(&d);
        assert_eq!(
            incremental,
            [false, true, false, true, false, true, false, false, true]
        );
        // 释放会话后重建：与增量结果一致。
        assert_eq!(
            call(&d, "browse_close", json!({"owner": "ankiconnect"}))["released"],
            json!(true)
        );
        assert_eq!(probe(&d), incremental);
    }

    /// 每条缓存行的 `dupe_norm`。
    fn dupe_norms(d: &Device) -> Vec<(String, Option<String>)> {
        let w = d.core.writer().unwrap();
        let mut stmt = w
            .prepare("SELECT srs_idt(id), dupe_norm FROM srs_notes_cache ORDER BY srs_idt(id)")
            .unwrap();
        stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    /// `anki_dupes` 不建浏览会话：冷查（从没浏览过）就直接查缓存行，查完也没有常驻会话、没有登记持有者。
    #[test]
    fn anki_dupes_needs_no_browse_session() {
        let (d, _, _) = library();
        assert_eq!(
            dupes(&d, json!([cand("cat", "A", false, Value::Null)])),
            [true]
        );
        let stats = call(&d, "browse_stats", json!({}));
        assert_eq!(stats["live"], json!(false), "{stats}");
        assert_eq!(stats["sessions"], json!(0), "{stats}");
        assert_eq!(stats["owners"], json!([]), "{stats}");
    }

    /// 笔记类型调换字段顺序：首字段换了，成员笔记的缓存行（含 `dupe_norm`）随笔记类型重算，查重跟着换。
    #[test]
    fn anki_dupes_follow_a_first_field_reorder() {
        let (d, cfg, _) = library();
        assert_eq!(
            dupes(
                &d,
                json!([
                    cand("cat", "A", false, Value::Null),
                    cand("dog", "A", false, Value::Null)
                ])
            ),
            [true, false]
        );
        let fdef = |name: &str, ord: i64| json!({"name": name, "ord": ord});
        write(
            &d,
            &cfg,
            T0 + 1000,
            vec![
                edit("notetype", "A", "fieldDef/fa", fdef("Front", 1)),
                edit("notetype", "A", "fieldDef/fb", fdef("Back", 0)),
            ],
        );
        // N1 的首字段现在是 fb = "dog"；N2 / N4 的 fb 为空。
        assert_eq!(
            dupes(
                &d,
                json!([
                    cand("cat", "A", false, Value::Null),
                    cand("dog", "A", false, Value::Null)
                ])
            ),
            [false, true]
        );
    }

    /// v15 老行（`dupe_norm` 为 NULL）的补算与写缓存行时算的逐行相同；补完再跑一遍什么也不做；补完查重结果相同。
    #[test]
    fn backfill_dupe_norms_matches_the_cache_write_and_is_idempotent() {
        let (d, cfg, deck) = library();
        let written = dupe_norms(&d);
        assert!(written.iter().all(|(_, n)| n.is_some()), "{written:?}");
        assert!(
            written.contains(&(N1.to_owned(), Some("cat".to_owned()))),
            "{written:?}"
        );
        let probe = json!([
            cand("cat", "A", false, Value::Null),
            cand("owl", "C", true, Value::Null),
            cand("cat", "A", false, json!([deck]))
        ]);
        let before = dupes(&d, probe.clone());
        let backfill = |d: &Device| {
            let w = d.core.writer().unwrap();
            in_savepoint(&w, |c| {
                crate::store::caches::backfill_dupe_norms(c, P, &cfg)
            })
            .unwrap()
        };
        {
            let w = d.core.writer().unwrap();
            w.execute_batch("UPDATE srs_notes_cache SET dupe_norm = NULL")
                .unwrap();
            // 缓存孤行（身份记录已不在）：补成空串。
            w.execute(
                "INSERT INTO srs_notes_cache (id, profile_uid, note_type_id, guid, created_at) VALUES ('orphan', srs_id(?1), 'A', 'g', 1)",
                [P],
            )
            .unwrap();
        }
        assert_eq!(
            dupes(&d, probe.clone()),
            [false, false, false],
            "NULL rows never match"
        );
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
        let tags =
            |d: &Device| call(d, "anki_tags", json!({"owner": "ankiconnect"}))["tags"].clone();
        assert_eq!(tags(&d), json!(["B", "b", "t1"]));
        {
            // 写连接上自动提交一条改动：COMMIT 已对读连接可见，守卫还没释放（没 settle）。浏览命令不在写连接上读
            // （没有挂着的 Drift 事务），所以持着守卫也照样走读连接。
            let w = d.core.writer().unwrap();
            w.execute(
                "UPDATE srs_notes_cache SET tags_json = '[\"zz\"]' WHERE id = srs_id(?1)",
                [N1],
            )
            .unwrap();
            assert!(w.is_autocommit());
            assert_eq!(
                tags(&d),
                json!(["B", "t1", "zz"]),
                "the committed write is visible and must be reread"
            );
            // 未提交的改动：读快照重读到的是旧值。
            w.execute_batch(&format!("BEGIN; UPDATE srs_notes_cache SET tags_json = '[\"yy\"]' WHERE id = srs_id('{N2}');")).unwrap();
            assert_eq!(tags(&d), json!(["B", "t1", "zz"]));
            w.execute_batch("COMMIT;").unwrap();
            assert_eq!(
                tags(&d),
                json!(["yy", "zz"]),
                "rows committed after an earlier reread are reread again"
            );
        }
        assert_eq!(tags(&d), json!(["yy", "zz"]));
        let stats = call(&d, "browse_stats", json!({}));
        assert_eq!(
            stats["sessions"],
            json!(1),
            "rereads, not rebuilds: {stats}"
        );
    }

    /// `anki_notes_info`（store/bulk.rs）：按数字 id 一批交回笔记类型、标签、字段（寄存器视图原序、落库表示）与可见卡；
    /// 查不到 / 已删除的为 null，与请求等长、同序（重复的 id 各回一份）。
    #[test]
    fn anki_notes_info_reads_fields_tags_and_visible_cards_by_numeric_id() {
        let (d, cfg, _) = library();
        write(
            &d,
            &cfg,
            T0 + 1000,
            vec![edit("note", N2, "deleted", json!(T0 + 1000))],
        );
        let num = crate::store::schema::anki_numeric_id;
        let card = crate::registers::card_id(N1, "t1", 0).unwrap();
        let req = json!({"notes": [num(N1), num(N2), 7, num(N3), num(N1)]});
        let got = d
            .core
            .read_visible(|c| crate::store::bulk::anki_notes_info(c, P, &req))
            .unwrap();
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
        assert!(
            plan.iter().any(|l| l.contains("idx_srs_notes_cache_dupe")),
            "{plan:?}"
        );
    }

    /// `anki_tags`：全部未删除笔记的标签去重，按 UTF-16 码元排（大写在前）；删了笔记它独有的标签就没了。
    #[test]
    fn anki_tags_dedupes_sorts_and_follows_deletes() {
        let (d, cfg, _) = library();
        let tags =
            |d: &Device| call(d, "anki_tags", json!({"owner": "ankiconnect"}))["tags"].clone();
        assert_eq!(tags(&d), json!(["B", "b", "t1"]));
        write(
            &d,
            &cfg,
            T0 + 1000,
            vec![
                edit("note", N1, "deleted", json!(T0 + 1000)),
                edit("note", N3, "tags", json!(["Ä", "a"])),
            ],
        );
        assert_eq!(tags(&d), json!(["B", "a", "t1", "Ä"]));
        let stats = call(&d, "browse_stats", json!({}));
        assert_eq!(stats["owners"], json!(["ankiconnect"]));
        assert_eq!(
            stats["sessions"],
            json!(1),
            "writes must not rebuild the session"
        );
    }

    // ------------------------------------------------------------------ 浏览器重设计（2026-11-04 spec §2）

    const DAY: i64 = 86_400_000;
    const NOW: i64 = T0 + 5 * DAY;

    fn call_files(d: &Device, op: &str, req: Value) -> (Value, Vec<(String, Vec<u8>)>) {
        let mut files = Vec::new();
        let v = d.core.browse(op, P, &req, &mut files).unwrap();
        (v, files)
    }

    /// 浏览查询的上下文（Dart `srsBrowseContext` 的形状），合进 [extra]。
    fn browse_req(deck: &str, extra: Value) -> Value {
        let mut req = json!({
            "owner": "page:test",
            "now": NOW,
            "utcOff": 0,
            "rollover": 4,
            "types": [
                {"id": "A", "name": "Basic", "fields": [["fa", "Front"], ["fb", "Back"]], "tpls": [["t1", "C", 0]]},
                {"id": "B", "name": "Word", "fields": [["x", "Word"]], "tpls": [["t2", "C", 0]]},
                {"id": "C", "name": "Reverse", "fields": [["c1", "Front"], ["c2", "Back"]], "tpls": [["t3", "C", 0]]},
            ],
            "decks": {deck: ["Default", false]},
            "fallback": ["Default", false],
            "models": [["fsrs6", []]],
            "deckModels": {deck: 0},
            "fallbackModel": 0,
        });
        for (k, v) in extra.as_object().unwrap() {
            req[k] = v.clone();
        }
        req
    }

    /// library() 再加：出处（N1 / N2 同一本书不同章、N3 漫画）、N1 背面带音频与图片、N5 第一个字段为空（类型 C 的模板
    /// 用第二个字段，卡照样生成）。
    fn rich_library() -> (Device, CacheConfig, String) {
        let (d, cfg, deck) = library();
        let fdef = |name: &str, ord: i64| json!({"name": name, "ord": ord});
        write(
            &d,
            &cfg,
            T0 + 10,
            vec![
                note_type("C"),
                edit("notetype", "C", "fieldDef/c1", fdef("Front", 0)),
                edit("notetype", "C", "fieldDef/c2", fdef("Back", 1)),
                edit(
                    "notetype",
                    "C",
                    "tmplDef/t3",
                    json!({"name": "C", "ord": 0, "front": "{{Back}}"}),
                ),
                note(N5, "C"),
                edit("note", N5, "f/c1", json!("<br>")),
                edit("note", N5, "f/c2", json!("back side")),
                edit(
                    "note",
                    N1,
                    "f/fb",
                    json!("<i>dog</i> [sound:cat.mp3]<img class=x src=\"cat.png\">"),
                ),
                edit(
                    "note",
                    N1,
                    "source",
                    json!({"kind": "book", "bookKey": "bk1", "section": 2, "start": 5, "title": "Book"}),
                ),
                edit(
                    "note",
                    N2,
                    "source",
                    json!({"kind": "book", "bookKey": "bk1", "section": 7, "start": 0}),
                ),
                edit(
                    "note",
                    N3,
                    "source",
                    json!({"kind": "manga", "mangaKey": "m1", "chapterKey": "c1", "page": 3}),
                ),
            ],
        );
        (d, cfg, deck)
    }

    struct Rows {
        s: Vec<Value>,
        ints: Vec<i64>,
        floats: Vec<f64>,
    }

    impl Rows {
        fn by_note(&self, note: &str) -> usize {
            self.s
                .iter()
                .position(|r| r[1] == json!(note))
                .unwrap_or_else(|| panic!("no row for {note}"))
        }
        fn int(&self, row: usize, k: usize) -> i64 {
            self.ints[row * 11 + k]
        }
        fn float(&self, row: usize, k: usize) -> f64 {
            self.floats[row * 2 + k]
        }
    }

    fn query_rows(d: &Device, deck: &str, extra: Value) -> (u64, Rows) {
        let q = call(d, "browse_query", browse_req(deck, extra));
        assert!(q.get("error").is_none(), "{q}");
        let gen = q["gen"].as_u64().unwrap();
        let (r, files) = call_files(d, "browse_rows", json!({"owner": "page:test", "gen": gen}));
        let file = |name: &str| {
            files
                .iter()
                .find(|f| f.0 == name)
                .unwrap_or_else(|| panic!("no {name}"))
                .1
                .clone()
        };
        let ints = file("rows.i64")
            .chunks(8)
            .map(|b| i64::from_le_bytes(b.try_into().unwrap()))
            .collect();
        let floats = file("rows.f64")
            .chunks(8)
            .map(|b| f64::from_le_bytes(b.try_into().unwrap()))
            .collect();
        let s = r["s"].as_array().unwrap().clone();
        assert_eq!(s.len() as u64, q["count"].as_u64().unwrap());
        (gen, Rows { s, ints, floats })
    }

    fn card_of_note(d: &Device, note: &str) -> String {
        d.core
            .writer()
            .unwrap()
            .query_row(
                "SELECT srs_idt(id) FROM srs_cards_cache WHERE note_id = srs_id(?1)",
                [note],
                |r| r.get(0),
            )
            .unwrap()
    }

    /// 让 N1 的卡变成复习卡：稳定度 10 天、10 天前复习过（FSRS-6 在 t = S 时可提取度正好 0.9）、早已到期。
    fn review_n1(d: &Device) -> String {
        let card = card_of_note(d, N1);
        d.core
            .writer()
            .unwrap()
            .execute(
                "UPDATE srs_cards_cache SET queue = 'review', stability = 10.0, difficulty = 5.5, scheduled_days = 10, \
                 due_day = 0, reps = 3, last_reviewed_at = ?1 WHERE id = srs_id(?2)",
                rusqlite::params![NOW - 10 * DAY, card],
            )
            .unwrap();
        card
    }

    /// 笔记类型有多个模板（卡片类型）时，每张卡一行：行带模板名（`s[6]`）与该笔记类型的模板数（`s[15]`），浏览页据此
    /// 在卡片行上标出是哪个卡片类型（Discord 反馈：给 Fushi 卡片加了第二个卡片类型，浏览里每个词两张卡、看不出区别）。
    /// 笔记模式一条笔记一行、卡数 2；`card:` 按序号 / 模板名筛。
    #[test]
    fn browse_rows_carry_template_count_for_multi_card_note_types() {
        let (d, cfg, deck) = rich_library();
        write(
            &d,
            &cfg,
            T0 + 20,
            vec![edit(
                "notetype",
                "C",
                "tmplDef/t4",
                json!({"name": "Reverse 2", "ord": 1, "front": "{{Back}}"}),
            )],
        );
        let types = json!({"types": [
            {"id": "A", "name": "Basic", "fields": [["fa", "Front"], ["fb", "Back"]], "tpls": [["t1", "C", 0]]},
            {"id": "B", "name": "Word", "fields": [["x", "Word"]], "tpls": [["t2", "C", 0]]},
            {"id": "C", "name": "Reverse", "fields": [["c1", "Front"], ["c2", "Back"]],
             "tpls": [["t3", "C", 0], ["t4", "Reverse 2", 1]]},
        ]});
        let with = |extra: Value| {
            let mut v = types.clone();
            for (k, x) in extra.as_object().unwrap() {
                v[k] = x.clone();
            }
            v
        };
        let (_, rows) = query_rows(
            &d,
            &deck,
            with(json!({"sort": {"col": "created", "asc": true}})),
        );
        assert_eq!(rows.s.len(), 6, "N5 now has one card per template");
        let mut n5: Vec<(Value, Value)> = rows
            .s
            .iter()
            .filter(|r| r[1] == json!(N5))
            .map(|r| (r[6].clone(), r[15].clone()))
            .collect();
        n5.sort_by_key(|x| x.0.to_string());
        assert_eq!(
            n5,
            vec![(json!("C"), json!(2)), (json!("Reverse 2"), json!(2))]
        );
        assert_eq!(
            rows.s[rows.by_note(N1)][15],
            json!(1),
            "single-template type"
        );

        let (_, notes) = query_rows(&d, &deck, with(json!({"mode": "notes"})));
        let n = notes.by_note(N5);
        assert_eq!(notes.int(n, 4), 2, "notes mode: one row, two cards");

        let (_, second) = query_rows(&d, &deck, with(json!({"node": {"t": "cardord", "v": 2}})));
        assert_eq!(second.s.len(), 1);
        assert_eq!(second.s[0][6], json!("Reverse 2"));
        let (_, named) = query_rows(
            &d,
            &deck,
            with(json!({"node": {"t": "cardname", "v": "reverse 2"}})),
        );
        assert_eq!(named.s.len(), 1);
        assert_eq!(named.s[0][1], json!(N5));
    }

    /// `browse_rows` 的新列：字段摘要、首个图片 / 音频、出处键 / kind / 原文、间隔、添加 / 修改 / 上次复习时刻、难度、
    /// 保持率（按牌组模型的 FSRS 可提取度）。
    #[test]
    fn browse_rows_carry_previews_media_sources_and_retention() {
        let (d, cfg, deck) = rich_library();
        review_n1(&d);
        let (_, rows) = query_rows(&d, &deck, json!({"sort": {"col": "created", "asc": true}}));
        assert_eq!(rows.s.len(), 5);

        let a = rows.by_note(N1);
        let r = &rows.s[a];
        assert_eq!(
            r[8],
            json!(["dog"]),
            "preview skips the sort field, strips html and [sound:]"
        );
        assert_eq!(r[9], json!("cat.png"));
        assert_eq!(r[10], json!("cat.mp3"));
        assert_eq!(r[11], json!("book:bk1"));
        assert_eq!(r[12], json!("book"));
        let data: Value = serde_json::from_str(r[13].as_str().unwrap()).unwrap();
        assert_eq!(data["section"], json!(2));
        assert_eq!(rows.int(a, 0), 2, "review queue");
        assert_eq!(rows.int(a, 5), 3, "reps");
        assert_eq!(rows.int(a, 7), 10, "interval");
        assert_eq!(rows.int(a, 8), 1, "addedAt = note createdAt");
        assert!(
            rows.int(a, 9) >= rows.int(a, 8),
            "modifiedAt is never before addedAt"
        );
        assert_eq!(rows.int(a, 10), NOW - 10 * DAY, "lastReviewAt");
        assert_eq!(rows.float(a, 0), 5.5, "difficulty");
        assert!(
            (rows.float(a, 1) - 0.9).abs() < 1e-4,
            "retention at t = S is 0.9: {}",
            rows.float(a, 1)
        );

        let b = rows.by_note(N2);
        assert_eq!(
            rows.s[b][11],
            json!("book:bk1"),
            "chapter / position are not part of the key"
        );
        assert_eq!(rows.s[b][8], json!([]));
        assert_eq!(
            rows.s[b][14],
            json!([]),
            "no preview, no preview field names"
        );
        assert_eq!(rows.s[b][9], Value::Null);
        assert_eq!(rows.int(b, 7), i64::MIN, "new card: no interval");
        assert_eq!(rows.int(b, 10), i64::MIN);
        assert!(
            rows.float(b, 0).is_nan() && rows.float(b, 1).is_nan(),
            "new card: no difficulty / retention"
        );
        assert_eq!(rows.s[rows.by_note(N3)][11], json!("manga:m1"));
        let n4 = rows.by_note(N4);
        assert_eq!(
            (&rows.s[n4][11], &rows.s[n4][12], &rows.s[n4][13]),
            (&Value::Null, &Value::Null, &Value::Null)
        );
        assert_eq!(rows.s[rows.by_note(N5)][8], json!(["back side"]));
        // 摘要各自来自哪个字段（表格原地改字段摘要列按名字写回）。
        assert_eq!(rows.s[rows.by_note(N5)][14], json!(["Back"]));
        assert_eq!(rows.s[a][14], json!(["Back"]));

        // 写入后行详情按笔记失效：改了 N4 的背面，下一次取行就看得到。
        write(
            &d,
            &cfg,
            T0 + 20,
            vec![edit("note", N4, "f/fb", json!("[sound:owl.ogg] hoot"))],
        );
        let (_, rows) = query_rows(&d, &deck, json!({"sort": {"col": "created", "asc": true}}));
        let n4 = rows.by_note(N4);
        assert_eq!(rows.s[n4][8], json!(["hoot"]));
        assert_eq!(rows.s[n4][10], json!("owl.ogg"));
        assert!(rows.int(n4, 9) > 1, "modifiedAt follows the new edit");

        // 没带模型（旧调用方）：保持率一律没有。
        let mut req = browse_req(&deck, json!({"sort": {"col": "created", "asc": true}}));
        req.as_object_mut().unwrap().remove("models");
        let gen = call(&d, "browse_query", req)["gen"].as_u64().unwrap();
        let (_, files) = call_files(&d, "browse_rows", json!({"owner": "page:test", "gen": gen}));
        let f64s = &files.iter().find(|f| f.0 == "rows.f64").unwrap().1;
        assert!(
            f64s.chunks(8)
                .skip(1)
                .step_by(2)
                .all(|b| f64::from_le_bytes(b.try_into().unwrap()).is_nan())
        );
    }

    /// 行详情缓存只存取行要的投影：字段原文再长，会话里留下的也只是摘要（≤120 字符）和媒体文件名。
    #[test]
    fn browse_row_detail_keeps_projections_not_field_text() {
        let (d, cfg, deck) = rich_library();
        let long = format!("<div>{}</div> [sound:long.mp3]", "x".repeat(20_000));
        write(
            &d,
            &cfg,
            T0 + 20,
            vec![edit("note", N4, "f/fb", json!(long))],
        );
        let (_, rows) = query_rows(&d, &deck, json!({"sort": {"col": "created", "asc": true}}));
        let n4 = rows.by_note(N4);
        assert_eq!(
            rows.s[n4][8].as_array().unwrap()[0]
                .as_str()
                .unwrap()
                .chars()
                .count(),
            120
        );
        assert_eq!(rows.s[n4][10], json!("long.mp3"));
        let b = super::lock(&d.core.browse);
        let s = b.live.get(P).expect("live session");
        for id in [N1, N4] {
            let texts = s.detail.get(id).expect("detail cached after rows").texts();
            assert!(!texts.is_empty());
            for t in &texts {
                assert!(t.chars().count() <= 120, "{id}: {t}");
                assert!(
                    !t.contains('<') && !t.contains("[sound:"),
                    "{id} keeps raw text: {t}"
                );
            }
        }
        let total: usize = s
            .detail
            .values()
            .flat_map(|d| d.texts())
            .map(str::len)
            .sum();
        assert!(total < 1_000, "detail keeps {total} bytes");
    }

    /// 排序列 `retention`：有值的按值，没有的不论升降序都排最后。
    #[test]
    fn retention_sort_puts_cards_without_retention_last() {
        let (d, _, deck) = rich_library();
        review_n1(&d);
        for asc in [true, false] {
            let (_, rows) =
                query_rows(&d, &deck, json!({"sort": {"col": "retention", "asc": asc}}));
            assert_eq!(rows.s[0][1], json!(N1), "asc = {asc}");
        }
    }

    /// 新搜索词：`prop:r`、`rated:N[:E]`、`is:emptyfield`、`is:dupe`、`has:audio` / `has:image`、`src:none` / `src:<kind>` /
    /// `src:<键>`；一条 `browse_counts` 算完，解析失败（false）/ 求值报错的那一条回 -1、不影响其它。
    #[test]
    fn browse_counts_cover_the_new_search_terms() {
        let (d, _, deck) = rich_library();
        let card = review_n1(&d);
        let w = d.core.writer().unwrap();
        for (log, at, rating) in [
            ("0193a1b2-0000-7000-8000-0000000000f1", NOW - DAY, 3),
            ("0193a1b2-0000-7000-8000-0000000000f2", NOW - 30 * DAY, 1),
        ] {
            w.execute(
                "INSERT INTO srs_stat_reviews (log_id, profile_uid, card_id, occurred_at, rating) VALUES (srs_id(?1), srs_id(?2), srs_id(?3), ?4, ?5)",
                rusqlite::params![log, P, card, at, rating],
            )
            .unwrap();
        }
        drop(w);
        let prop = |op: &str, v: f64| json!({"t": "prop", "p": "r", "op": op, "v": v});
        let nodes = json!([
            null,
            {"t": "dupe"},
            {"t": "emptyfield"},
            false,
            {"t": "re", "v": "(", "at": "re:("},
            {"t": "src", "v": "book"},
            {"t": "src", "v": "none"},
            {"t": "src", "v": "book:bk1"},
            {"t": "src", "v": "manga:nope"},
            {"t": "has", "v": "audio"},
            {"t": "has", "v": "image"},
            {"t": "not", "c": {"t": "has", "v": "audio"}},
            prop("lt", 0.95),
            prop("gt", 0.95),
            {"t": "rated", "d": 7},
            {"t": "rated", "d": 7, "e": 3},
            {"t": "rated", "d": 7, "e": 1},
            {"t": "rated", "d": 60, "e": 1},
            {"t": "and", "c": [{"t": "src", "v": "book"}, {"t": "not", "c": {"t": "dupe"}}]},
        ]);
        let counts = |mode: &str| {
            call(
                &d,
                "browse_counts",
                browse_req(&deck, json!({"nodes": nodes, "mode": mode})),
            )["counts"]
                .clone()
        };
        let want = json!([5, 2, 1, -1, -1, 2, 2, 2, 0, 1, 1, 4, 1, 0, 1, 1, 0, 1, 0]);
        assert_eq!(counts("cards"), want);
        assert_eq!(counts("notes"), want, "one card per note");
        // browse_query 走同一条改写：`src:` 的结果就是那两张。
        let q = call(
            &d,
            "browse_query",
            browse_req(&deck, json!({"node": {"t": "src", "v": "book:bk1"}})),
        );
        assert_eq!(q["count"], json!(2));
        // 不走会话的语料求值不认这几个词（明确报错，不静默当空集）。
        assert!(crate::search::Corpus::columns_used(&json!({"t": "dupe"}).to_string()).is_err());
    }

    /// `browse_sources`：按出处键分组，组里的行数 / 到期数 / 前几行行号 / 代表出处，没有出处的一组放最后；同一本书
    /// 不同章合成一组。
    #[test]
    fn browse_sources_group_results_by_work() {
        let (d, cfg, deck) = rich_library();
        review_n1(&d);
        // N4 晚一些添加的同一部漫画：漫画组的最近添加时刻更晚，排到书前面。
        write(
            &d,
            &cfg,
            T0 + 30,
            vec![edit(
                "note",
                N4,
                "source",
                json!({"kind": "manga", "mangaKey": "m1", "chapterKey": "c9", "page": 0, "title": "M"}),
            )],
        );
        let (gen, rows) = query_rows(&d, &deck, json!({"sort": {"col": "created", "asc": true}}));
        let g = call(
            &d,
            "browse_sources",
            json!({"owner": "page:test", "gen": gen}),
        )["groups"]
            .clone();
        let keys: Vec<Value> = g
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x["key"].clone())
            .collect();
        // 全部笔记 createdAt 相同：同值按键排，没有出处的最后。
        assert_eq!(
            keys,
            vec![json!("book:bk1"), json!("manga:m1"), Value::Null]
        );
        assert_eq!(g[0]["count"], json!(2));
        assert_eq!(g[0]["due"], json!(1), "N1's card is due");
        assert_eq!(g[0]["kind"], json!("book"));
        assert_eq!(g[1]["count"], json!(2));
        assert_eq!(g[1]["due"], json!(0));
        assert_eq!(g[2]["count"], json!(1));
        assert_eq!(g[2]["kind"], Value::Null);
        assert_eq!(g[2]["data"], Value::Null);
        let preview: Vec<usize> = g[0]["preview"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_u64().unwrap() as usize)
            .collect();
        let mut notes: Vec<&Value> = preview.iter().map(|&i| &rows.s[i][1]).collect();
        notes.sort_by_key(|v| v.as_str().unwrap().to_owned());
        assert_eq!(notes, vec![&json!(N1), &json!(N2)]);
        assert_eq!(g[0]["latestAddedAt"], json!(1));
        assert!(g[0]["data"].as_str().unwrap().contains("bk1"));
        // 组里各行的卡所在的牌组（去重）：「只复习这一作」据此定牌组范围。
        assert_eq!(g[0]["decks"], json!([deck]));
        assert_eq!(g[2]["decks"], json!([deck]));
        // 空结果 = 空表。
        let q = call(
            &d,
            "browse_query",
            browse_req(&deck, json!({"node": {"t": "src", "v": "web"}})),
        );
        let g = call(
            &d,
            "browse_sources",
            json!({"owner": "page:test", "gen": q["gen"]}),
        )["groups"]
            .clone();
        assert_eq!(g, json!([]));
    }

    /// 排序列 `source`（表格按出处分组）：按出处键排，同一作品的行挨着，没有出处的不论升降序都在最后；第一次用到时
    /// 才装出处寄存器。
    #[test]
    fn source_sort_groups_rows_by_work_and_puts_unsourced_last() {
        let (d, _, deck) = rich_library();
        for asc in [true, false] {
            let (_, rows) = query_rows(&d, &deck, json!({"sort": {"col": "source", "asc": asc}}));
            let keys: Vec<Value> = rows.s.iter().map(|r| r[11].clone()).collect();
            let mut want = vec![json!("book:bk1"), json!("book:bk1"), json!("manga:m1")];
            if !asc {
                want.reverse();
            }
            want.extend([Value::Null, Value::Null]);
            assert_eq!(keys, want, "asc = {asc}");
        }
    }

    /// 出处键：各 kind 的作品身份字段，取不到退回 title，再没有就只有 kind；不是带 kind 的对象 = 没有出处。
    #[test]
    fn source_keys_follow_the_work_identity() {
        let k = |v: Value| super::source_key(&v).map(|x| x.0);
        assert_eq!(
            k(json!({"kind": "video", "mediaKey": "sha", "startMs": 5})),
            Some("video:sha".into())
        );
        assert_eq!(
            k(json!({"kind": "audiobook", "mediaKey": "ab"})),
            Some("audiobook:ab".into())
        );
        assert_eq!(
            k(
                json!({"kind": "onlineNovel", "sourceId": "s", "novelUrl": "/n", "chapterUrl": "/c"})
            ),
            Some("onlineNovel:s\u{1f}/n".into())
        );
        assert_eq!(
            k(
                json!({"kind": "onlineVideo", "sourceId": "s", "animeUrl": "/a", "episodeUrl": "/e"})
            ),
            Some("onlineVideo:s\u{1f}/a".into())
        );
        assert_eq!(
            k(json!({"kind": "game", "gameId": "g1"})),
            Some("game:g1".into())
        );
        assert_eq!(
            k(json!({"kind": "web", "url": "https://x/y"})),
            Some("web:https://x/y".into())
        );
        assert_eq!(
            k(json!({"kind": "manual", "title": "Notebook"})),
            Some("manual:Notebook".into())
        );
        assert_eq!(
            k(json!({"kind": "game", "title": "Gal"})),
            Some("game:Gal".into()),
            "missing gameId falls back to title"
        );
        assert_eq!(k(json!({"kind": "anki"})), Some("anki".into()));
        assert_eq!(k(json!({"kind": 3})), None);
        assert_eq!(k(json!("book")), None);
    }
}
