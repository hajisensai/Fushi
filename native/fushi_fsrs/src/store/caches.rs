//! 本机缓存行（`srs_notes_cache` / `srs_cards_cache` / `srs_stat_reviews`）的刷新：原 Dart
//! `SrsDbStore._flushCachesNow` 整段（笔记类型 → 成员笔记的展开、笔记缓存行与应有的卡、前身 → 后继闭包上的
//! 卡片缓存行、有效复习投影的归属分组）。缓存只在本机、可随时由事件重建，不同步。
//!
//! 投影命令（apply / ingest / import / 冲突解决 / 清除 / 恢复…）在同一次 FFI 调用里接着刷新（ffi.rs
//! `sync2_dispatch`），Dart 只收写过哪些笔记 / 卡（变更日志与数字索引用）。规则与删除前的 Dart 实现逐条
//! 对应；固定向量 packages/fushi_engine/test/srs/fixtures/cache_vectors.json.gz 由删除前的 Dart 实现生成。
//!
//! 每条笔记 / 每张卡的缓存行只由它自己的事件（加笔记类型、血统）决定，所以分块读写与逐条重算同结果；分块只是
//! 把 SQL 参数控制在上限以内。

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use rusqlite::{params_from_iter, Connection};
use serde_json::Value;

use crate::card_cache;
use crate::history;
use crate::ordering::cmp_utf16;
use crate::registers::{self, StoredEdit};
use crate::store::logs_of;
use crate::store::sync2::sql;

/// 一块笔记 / 卡的数量（SQL 参数上限以内）。
const CHUNK: usize = 200;

const HISTORY_FROM: &str = "historyFrom/";

/// 缓存刷新要的、只有 Dart 知道的配置（随投影命令一起传：`"caches": {...}`）。
pub(crate) struct CacheConfig {
    /// 本 profile 的内置默认牌组（卡没有牌组、笔记也没有首选牌组时的归属）。
    default_deck: String,
    /// 内置笔记类型 key → (代码默认值，交给 registers.rs `note_type_view` 的 `b`——含词条字段 `termFieldId` 与
    /// 词频序字段 `freqFieldId`；读音字段 ID)。
    builtins: HashMap<String, (Value, Option<String>)>,
}

impl CacheConfig {
    /// `{"defaultDeck": "...", "builtins": {"<key>": {"b": {...}, "reading": "<fieldId>"|null}}}`。
    pub(crate) fn parse(v: &Value) -> Result<CacheConfig, String> {
        let default_deck = v["defaultDeck"].as_str().ok_or("caches: missing defaultDeck")?.to_owned();
        let mut builtins = HashMap::new();
        if let Some(m) = v["builtins"].as_object() {
            for (k, b) in m {
                builtins.insert(k.clone(), (b["b"].clone(), b["reading"].as_str().map(str::to_owned)));
            }
        }
        Ok(CacheConfig { default_deck, builtins })
    }
}

/// 要刷新什么。
#[derive(Default, Debug)]
pub(crate) struct Dirty {
    pub notes: BTreeSet<String>,
    pub cards: BTreeSet<String>,
    pub note_types: BTreeSet<String>,
    /// 本 profile 的全部笔记（重建 / 推导规则升级）。
    pub all_notes: bool,
    /// 有效复习投影按本 profile 全部有日志的卡重算（重建 / 升级）。
    pub all_stats: bool,
}

impl Dirty {
    /// 一次投影命令的结果（`marks` / `replayed` / `changed`）里要刷新的实体：与 Dart 旧 `_absorbProjection`
    /// 的标脏规则相同（被冲突扣住 / 解除改变了可见性的笔记类型不看字段键，一律算影响缓存）。
    pub(crate) fn of_projection(r: &Value) -> Dirty {
        let mut d = Dirty::default();
        let ids = |v: &Value, into: &mut BTreeSet<String>| {
            for x in v.as_array().into_iter().flatten() {
                if let Some(s) = x.as_str() {
                    into.insert(s.to_owned());
                }
            }
        };
        ids(&r["marks"]["notes"], &mut d.notes);
        ids(&r["marks"]["cards"], &mut d.cards);
        ids(&r["marks"]["noteTypes"], &mut d.note_types);
        ids(&r["replayed"], &mut d.cards);
        for c in r["changed"].as_array().into_iter().flatten() {
            let (Some(kind), Some(id)) = (c[0].as_str(), c[1].as_str()) else { continue };
            match kind {
                "note" => d.notes.insert(id.to_owned()),
                "card" => d.cards.insert(id.to_owned()),
                "notetype" => d.note_types.insert(id.to_owned()),
                _ => false,
            };
        }
        d
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.notes.is_empty() && self.cards.is_empty() && self.note_types.is_empty() && !self.all_notes && !self.all_stats
    }
}

/// 这次写过缓存行的笔记 / 卡（Dart 的变更日志与 AnkiConnect 数字索引用）。
#[derive(Default, Debug)]
pub(crate) struct Written {
    pub notes: Vec<String>,
    /// 写了整行的卡。
    pub cards: Vec<String>,
    /// 删掉的卡缓存行（笔记不再生成的卡：删掉的模板 / cloze 序号、更改笔记类型的前身卡）。它的日志与修改记录
    /// 都还在，再生成时（同一卡 ID）按血统原样重算。
    pub removed: Vec<String>,
}

impl Written {
    pub(crate) fn to_json(&self) -> Value {
        serde_json::json!({"notes": self.notes, "cards": self.cards, "removed": self.removed})
    }
}

/// 丢掉本 profile 的全部缓存行，由事件重建（Dart `rebuildCaches`）。
pub(crate) fn rebuild(c: &Connection, profile: &str, cfg: &CacheConfig) -> Result<Written, String> {
    for t in ["srs_cards_cache", "srs_notes_cache", "srs_stat_reviews"] {
        c.execute(&format!("DELETE FROM {t} WHERE profile_uid = srs_id(?1)"), [profile]).map_err(sql)?;
    }
    refresh(c, profile, cfg, Dirty { all_notes: true, all_stats: true, ..Dirty::default() })
}

/// 按影响面刷新缓存行。调用方在写连接的事务 / savepoint 里。
pub(crate) fn refresh(c: &Connection, profile: &str, cfg: &CacheConfig, dirty: Dirty) -> Result<Written, String> {
    let mut out = Written::default();
    if dirty.is_empty() {
        return Ok(out);
    }
    let mut notes = dirty.notes;
    if !dirty.note_types.is_empty() {
        // 成员按笔记缓存的**当前**类型找：本批新落的笔记已经因自己的事件标脏，不必解析全部身份记录。
        let types: Vec<&String> = dirty.note_types.iter().collect();
        for chunk in types.chunks(500) {
            let q = format!(
                "SELECT srs_idt(id) AS id FROM srs_notes_cache WHERE profile_uid = srs_id(?) AND note_type_id IN ({})",
                marks(chunk.len())
            );
            let mut args: Vec<&str> = vec![profile];
            args.extend(chunk.iter().map(|s| s.as_str()));
            notes.extend(strings(c, &q, &args)?);
        }
    }
    if dirty.all_notes {
        notes.extend(strings(c, "SELECT srs_idt(id) AS id FROM srs_entities WHERE profile_uid = srs_id(?1) AND kind = 'note'", &[profile])?);
    }
    let now = wall_now();
    let mut stat_seeds: BTreeSet<String> = BTreeSet::new();
    // 本次刷新里已经按最新事件重算过的卡（笔记刷新会重算它全部的卡）。
    let mut refreshed: HashSet<String> = HashSet::new();
    // 一次刷新内同一笔记类型只物化一次。
    let mut types: HashMap<String, Option<TypeInfo>> = HashMap::new();
    let notes: Vec<String> = notes.into_iter().collect();
    for chunk in notes.chunks(CHUNK) {
        flush_notes(c, profile, cfg, chunk, &mut types, &mut refreshed, now, &mut out)?;
    }
    // 卡片的历史 / 标志沿「前身」继承：前身变了，后继卡也要重算。链接从种子卡按需查（[Links]）：一次作答只碰
    // 这张卡的血统，不再把全库的前身链接读进内存；全量重建投影（`all_stats`）本来就要走遍全库，一次读完。
    let mut links = if dirty.all_stats { Links::load_all(c)? } else { Links::default() };
    let closure = successor_closure(c, &mut links, dirty.cards)?;
    let rest: Vec<String> = closure.iter().filter(|c| !refreshed.contains(*c)).cloned().collect();
    for chunk in rest.chunks(CHUNK) {
        flush_cards(c, profile, cfg, chunk, &mut out)?;
    }
    // 投影在全部缓存行（可见性）写完之后再算：归属看的是这一轮之后的可见性。还没有缓存行的卡也算。
    stat_seeds.extend(closure);
    stat_seeds.extend(out.cards.iter().cloned());
    stat_seeds.extend(out.removed.iter().cloned());
    if dirty.all_stats {
        stat_seeds.extend(strings(c, "SELECT DISTINCT srs_idt(card_id) AS card_id FROM srs_review_logs WHERE profile_uid = srs_id(?1)", &[profile])?);
    }
    if !stat_seeds.is_empty() {
        refresh_stats(c, profile, cfg, &mut links, &stat_seeds)?;
    }
    Ok(out)
}

// ---------------------------------------------------------------- 笔记

/// 笔记类型里缓存行用得到的部分。
struct TypeInfo {
    cloze: bool,
    /// (字段 ID, 字段名)，按 ord。
    fields: Vec<(String, String)>,
    /// (模板 ID, ord, 正面)，按 ord。
    templates: Vec<(String, i64, String)>,
    term_field: Option<String>,
    reading_field: Option<String>,
    /// 词频序字段（卡片缓存行的 `freq_rank` 从它解析），即视图的 `qe`（registers.rs `effective_frequency_field`）。
    freq_field: Option<String>,
    deleted: bool,
}

impl TypeInfo {
    fn of(view: &Value, cfg: &CacheConfig) -> TypeInfo {
        let s = |v: &Value| v.as_str().unwrap_or("").to_owned();
        let fields: Vec<(String, String)> =
            view["fs"].as_array().into_iter().flatten().map(|f| (s(&f["id"]), s(&f["name"]))).collect();
        TypeInfo {
            cloze: view["nk"].as_str() == Some("cloze"),
            freq_field: view["qe"].as_str().map(str::to_owned),
            fields,
            templates: view["ts"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|t| (s(&t["id"]), t["ord"].as_i64().unwrap_or(0), s(&t["front"])))
                .collect(),
            term_field: view["tf"].as_str().map(str::to_owned),
            reading_field: view["bk"].as_str().and_then(|k| cfg.builtins.get(k)).and_then(|b| b.1.clone()),
            deleted: !view["da"].is_null(),
        }
    }
}


/// 物化好的笔记里缓存行用得到的部分。
pub(crate) struct NoteInfo {
    pub(crate) id: String,
    pub(crate) note_type: String,
    guid: String,
    created_at: i64,
    /// (字段 ID, 值)，寄存器视图 `f` 的原序（同一 ID 后者为准，见 [NoteInfo::field]）。
    pub(crate) fields: Vec<(String, String)>,
    pub(crate) tags: Vec<String>,
    deck: Option<String>,
    pub(crate) deleted_at: Option<i64>,
    pending: bool,
    /// 出处（`SrsSourceRef`）：kind 与原样 title；没有出处（或不是带 kind 的对象）= 两个空串。
    source_kind: String,
    source_title: String,
}

impl NoteInfo {
    fn of(id: &str, v: &Value) -> NoteInfo {
        let s = |v: &Value| v.as_str().unwrap_or("").to_owned();
        NoteInfo {
            id: id.to_owned(),
            note_type: s(&v["nt"]),
            guid: s(&v["g"]),
            created_at: v["ca"].as_i64().unwrap_or(0),
            fields: v["f"].as_array().into_iter().flatten().map(|f| (s(&f[0]), s(&f[1]))).collect(),
            tags: v["t"].as_array().into_iter().flatten().filter_map(|t| t.as_str().map(str::to_owned)).collect(),
            deck: v["dk"].as_str().map(str::to_owned),
            deleted_at: v["da"].as_i64(),
            pending: v["pd"] == Value::Bool(true),
            // Dart `SrsSourceRef.fromJson`：不是对象或 kind 不是字符串 = 没有出处；title 不是字符串 = 没有标题。
            source_kind: v["s"]["kind"].as_str().map(str::to_owned).unwrap_or_default(),
            source_title: match v["s"]["kind"].as_str() {
                Some(_) => v["s"]["title"].as_str().map(str::to_owned).unwrap_or_default(),
                None => String::new(),
            },
        }
    }

    /// Dart `SrsNoteView.field`：没有 = 空串。
    fn field(&self, id: &str) -> &str {
        self.fields.iter().rev().find(|(k, _)| k == id).map_or("", |(_, v)| v.as_str())
    }
}

/// 一条笔记应有的卡：(卡 ID, 模板 ID, cloze 序号, 判空)。
fn expected_cards(n: &NoteInfo, t: &TypeInfo) -> Result<Vec<(String, String, i64, bool)>, String> {
    // 按名字的字段表（Dart `Map`：同名后者覆盖、位置不变）。
    let mut by_name: Vec<(String, String)> = Vec::with_capacity(t.fields.len());
    for (id, name) in &t.fields {
        let v = n.field(id).to_owned();
        match by_name.iter_mut().find(|(k, _)| k == name) {
            Some(slot) => slot.1 = v,
            None => by_name.push((name.clone(), v)),
        }
    }
    let mut out: Vec<(String, String, i64, bool)> = Vec::new();
    let mut put = |card: String, tpl: &str, ord: i64, empty: bool| match out.iter_mut().find(|x| x.0 == card) {
        Some(slot) => *slot = (card, tpl.to_owned(), ord, empty),
        None => out.push((card, tpl.to_owned(), ord, empty)),
    };
    if t.cloze && !t.templates.is_empty() {
        let tpl = &t.templates[0].0;
        let joined = by_name.iter().map(|(_, v)| v.as_str()).collect::<Vec<_>>().join("\n");
        for ord in card_cache::cloze_ordinals(&joined) {
            put(registers::card_id(&n.id, tpl, ord as i64)?, tpl, ord as i64, false);
        }
    } else if !t.cloze {
        let id_to_name = |id: &str| t.fields.iter().rev().find(|(k, _)| k == id).map(|(_, name)| name.clone());
        for (tpl, ord, front) in &t.templates {
            // 模板语法错误：Dart 侧 catch 成「不空」。
            let empty = card_cache::card_front_is_empty(front, &id_to_name, &by_name, *ord).unwrap_or(false);
            put(registers::card_id(&n.id, tpl, 0)?, tpl, 0, empty);
        }
    }
    Ok(out)
}

/// 一组笔记物化好的视图（不存在的跳过）：身份记录与修改记录分块一次读、整块一次寄存器内核。
pub(crate) fn note_infos(c: &Connection, chunk: &[String]) -> Result<Vec<NoteInfo>, String> {
    let rows = entity_rows(c, chunk)?;
    let edits = edits_of(c, "note", chunk)?;
    let mut views: Vec<NoteInfo> = Vec::new();
    for id in chunk {
        let Some(payload) = rows.get(id) else { continue };
        let es: Vec<StoredEdit<'_>> = edits.get(id).map(|v| v.iter().map(|e| (e.1.as_str(), e.2)).collect()).unwrap_or_default();
        views.push(NoteInfo::of(id, &registers::note_view_of(payload, &es)?));
    }
    Ok(views)
}

/// 把 [ids] 里还没物化过的笔记类型物化进 [types]（不存在的记 None）。一次刷新内同一笔记类型只物化一次。
fn load_types<'a>(
    c: &Connection,
    cfg: &CacheConfig,
    ids: impl Iterator<Item = &'a String>,
    types: &mut HashMap<String, Option<TypeInfo>>,
) -> Result<(), String> {
    let missing: Vec<String> =
        ids.filter(|t| !types.contains_key(*t)).cloned().collect::<BTreeSet<_>>().into_iter().collect();
    if missing.is_empty() {
        return Ok(());
    }
    let trows = entity_rows(c, &missing)?;
    let tedits = edits_of(c, "notetype", &missing)?;
    for id in &missing {
        let info = match trows.get(id) {
            None => None,
            Some(payload) => {
                let es: Vec<StoredEdit<'_>> =
                    tedits.get(id).map(|v| v.iter().map(|e| (e.1.as_str(), e.2)).collect()).unwrap_or_default();
                let builtin =
                    payload["builtin"].as_str().and_then(|k| cfg.builtins.get(k)).map_or(Value::Null, |b| b.0.clone());
                Some(TypeInfo::of(&registers::note_type_view_of(payload, &es, &builtin)?, cfg))
            }
        };
        types.insert(id.clone(), info);
    }
    Ok(())
}

/// 笔记缓存行的 `dupe_norm`（srs.db v15）：首字段（笔记类型字段顺序第一个）的 AnkiConnect 查重规范形
/// （`search::dupe_norm`，与 canAddNotes 给候选首字段算的同一个函数）。笔记类型不在 / 没有字段 = 空串
/// （查重只拿非空规范形去比，空串永远不命中）。
fn dupe_norm_of(n: &NoteInfo, t: Option<&TypeInfo>) -> String {
    match t.and_then(|t| t.fields.first()) {
        Some((f, _)) => crate::search::dupe_norm(n.field(f)),
        None => String::new(),
    }
}

/// 补算 `dupe_norm IS NULL` 的笔记缓存行（v15 加列后的老行；Dart 缓存修订号 8 的升级步调用）：只物化这些笔记与
/// 它们的笔记类型、只改这一列，不重算整行与卡片（整行重算要读每张卡的血统与日志，十万卡库慢一个量级）。与
/// [flush_notes] 写的值同一个函数（[dupe_norm_of]）。身份记录已不在的行（缓存孤行）写空串。幂等。返回补了几行。
pub(crate) fn backfill_dupe_norms(c: &Connection, profile: &str, cfg: &CacheConfig) -> Result<usize, String> {
    let ids = strings(c, "SELECT srs_idt(id) AS id FROM srs_notes_cache WHERE profile_uid = srs_id(?1) AND dupe_norm IS NULL", &[profile])?;
    let mut types: HashMap<String, Option<TypeInfo>> = HashMap::new();
    let mut up = c.prepare_cached("UPDATE srs_notes_cache SET dupe_norm = ?1 WHERE id = ?2").map_err(sql)?;
    for chunk in ids.chunks(CHUNK) {
        let views = note_infos(c, chunk)?;
        load_types(c, cfg, views.iter().map(|v| &v.note_type), &mut types)?;
        let mut done: HashSet<&str> = HashSet::with_capacity(chunk.len());
        for n in &views {
            let norm = dupe_norm_of(n, types.get(&n.note_type).and_then(Option::as_ref));
            up.execute(rusqlite::params![norm, n.id]).map_err(sql)?;
            done.insert(n.id.as_str());
        }
        for id in chunk.iter().filter(|id| !done.contains(id.as_str())) {
            up.execute(rusqlite::params!["", id]).map_err(sql)?;
        }
    }
    Ok(ids.len())
}

#[allow(clippy::too_many_arguments)]
fn flush_notes(
    c: &Connection,
    profile: &str,
    cfg: &CacheConfig,
    chunk: &[String],
    types: &mut HashMap<String, Option<TypeInfo>>,
    refreshed: &mut HashSet<String>,
    now: i64,
    out: &mut Written,
) -> Result<(), String> {
    let views = note_infos(c, chunk)?;
    let existing = cards_of_notes(c, chunk)?;
    load_types(c, cfg, views.iter().map(|v| &v.note_type), types)?;
    // 笔记缓存行与应有的卡。
    // (笔记下标, 应有的卡, 笔记已不在, 词频名次)。
    let mut plans: Vec<(usize, Vec<(String, String, i64, bool)>, bool, Option<i64>)> = Vec::with_capacity(views.len());
    let mut want: Vec<(String, Option<String>)> = Vec::new();
    let mut note_stmt = c.prepare_cached(NOTE_UPSERT).map_err(sql)?;
    for (k, n) in views.iter().enumerate() {
        let t = types.get(&n.note_type).and_then(Option::as_ref);
        let term = match t.and_then(|t| t.term_field.as_deref()) {
            Some(f) => card_cache::normalize_term(n.field(f)),
            None => String::new(),
        };
        let reading = match t.and_then(|t| t.reading_field.as_deref()) {
            Some(f) => card_cache::normalize_term(n.field(f)),
            None => String::new(),
        };
        let sort = match t.and_then(|t| t.fields.first()) {
            Some((f, _)) => card_cache::sort_field(n.field(f)),
            None => String::new(),
        };
        let dupe = dupe_norm_of(n, t);
        // 名次是笔记上的值：写进这条笔记的每张卡。
        let freq = t.and_then(|t| t.freq_field.as_deref()).and_then(|f| card_cache::freq_rank(n.field(f)));
        let expected = match t {
            Some(t) => expected_cards(n, t)?,
            None => Vec::new(),
        };
        let gone = n.deleted_at.is_some() || t.is_none_or(|t| t.deleted);
        let tags = serde_json::to_string(&n.tags).map_err(|e| e.to_string())?;
        let media = card_cache::media_refs(n.fields.iter().map(|(_, v)| v.as_str()));
        note_stmt
            .execute(rusqlite::params![
                n.id,
                profile,
                n.note_type,
                n.guid,
                n.created_at,
                n.deck,
                n.deleted_at,
                term,
                reading,
                sort,
                tags,
                n.pending,
                now,
                media,
                n.source_kind,
                n.source_title,
                crate::store::schema::anki_numeric_id(&n.id),
                dupe,
            ])
            .map_err(sql)?;
        out.notes.push(n.id.clone());
        for e in &expected {
            want.push((e.0.clone(), n.deck.clone()));
        }
        plans.push((k, expected, gone, freq));
    }
    // 不再应有的旧卡删行：缓存是事件的纯函数，增量刷新与 [rebuild] 必须得到同一张表（删除前的 Dart 增量路径
    // 把它们留成 hidden=1、重建又不写，两条路径的结果取决于这台机器重建过没有，更改笔记类型的预演会因此
    // 多 / 少继承一张旧卡的历史）。
    let mut gone_cards: Vec<String> = Vec::new();
    for (k, expected, _, _) in &plans {
        for card in existing.get(&views[*k].id).into_iter().flatten() {
            if !expected.iter().any(|e| &e.0 == card) {
                gone_cards.push(card.clone());
            }
        }
    }
    delete_cards(c, &gone_cards)?;
    out.removed.extend(gone_cards);
    let materials = card_materials(c, cfg, &want)?;
    let mut card_stmt = c.prepare_cached(CARD_UPSERT).map_err(sql)?;
    for (k, expected, gone, freq) in &plans {
        let n = &views[*k];
        for (card, tpl, ord, empty) in expected {
            let m = materials.get(card).ok_or("card material missing")?;
            write_card(&mut card_stmt, profile, card, &n.id, tpl, *ord, n.created_at, *gone || *empty, *freq, m)?;
            out.cards.push(card.clone());
            refreshed.insert(card.clone());
        }
    }
    Ok(())
}

// ---------------------------------------------------------------- 卡

/// 一张卡的缓存行原料：继承后的标志与卡片历史内核算出的当前状态。
struct Material {
    flags: Value,
    state: history::State,
}

/// 一组卡（卡 ID, 笔记首选牌组）的血统、标志与当前状态：血统的修改记录按轮读（每轮把新发现的前身一起读，
/// 只看前身键、不看值，多读不少读），血统与标志整组一次寄存器内核，日志在写连接上直读。
fn card_materials(c: &Connection, cfg: &CacheConfig, want: &[(String, Option<String>)]) -> Result<HashMap<String, Material>, String> {
    let lineages = lineages(c, cfg, want)?;
    let groups: Vec<Vec<String>> = lineages.iter().map(|l| l.0.clone()).collect();
    let logs = logs_of(c, &groups)?;
    let empty: Vec<(String, Option<i64>)> = Vec::new();
    let mut out = HashMap::with_capacity(want.len());
    for ((card, _), (lineage, flags)) in want.iter().zip(lineages) {
        let mut jsons: Vec<&str> = Vec::new();
        let mut servers: Vec<Option<i64>> = Vec::new();
        for id in &lineage {
            for (j, s) in logs.get(id).unwrap_or(&empty) {
                jsons.push(j);
                servers.push(*s);
            }
        }
        let state = history::state_from_json(&jsons, &servers)?;
        out.insert(card.clone(), Material { flags, state });
    }
    Ok(out)
}

/// 一组卡各自的血统（自己在前、再按广度优先列出全部前身，防环、最多 256 张），与输入同序。与 [lineages]
/// 同一条规则（`registers::card_lineage_flags`），但只读前身链接那几条修改记录（血统只看 `historyFrom/<前身>`
/// 寄存器，每个键的值与别的键无关）：优化器 / RWKV 取数、卡片历史按卡 id 调，血统在内核里解析
/// （以前 Dart 先把整条血统的全部修改记录预读回 UI isolate 再交给内核，十万张卡上百次往返）。
pub(crate) fn lineage_ids(c: &Connection, cards: &[String]) -> Result<Vec<Vec<String>>, String> {
    if cards.is_empty() {
        return Ok(Vec::new());
    }
    let mut edits: BTreeMap<String, Vec<(String, Option<i64>)>> = BTreeMap::new();
    let mut next: BTreeSet<String> = cards.iter().cloned().collect();
    for _ in 0..256 {
        if next.is_empty() {
            break;
        }
        let ids: Vec<String> = next.iter().cloned().collect();
        let mut preds: BTreeSet<String> = BTreeSet::new();
        for id in &ids {
            edits.entry(id.clone()).or_default();
        }
        for chunk in ids.chunks(400) {
            let q = format!(
                "SELECT srs_idt(f.entity_id) AS entity_id, f.field_key, f.json, e.server_time FROM srs_field_edits f \
                 LEFT JOIN srs_event_local e ON e.event_id = f.id \
                 WHERE f.entity_kind = 'card' AND f.entity_id IN ({}) AND substr(f.field_key, 1, 12) = 'historyFrom/'",
                marks(chunk.len())
            );
            let mut stmt = c.prepare_cached(&q).map_err(sql)?;
            let mut it = stmt.query(params_from_iter(chunk.iter())).map_err(sql)?;
            while let Some(r) = it.next().map_err(sql)? {
                let id: String = r.get(0).map_err(sql)?;
                let key: String = r.get(1).map_err(sql)?;
                if let Some(p) = key.strip_prefix(HISTORY_FROM) {
                    if !edits.contains_key(p) {
                        preds.insert(p.to_owned());
                    }
                }
                edits.entry(id).or_default().push((r.get(2).map_err(sql)?, r.get(3).map_err(sql)?));
            }
        }
        next = preds;
    }
    let all: Vec<(String, Vec<StoredEdit<'_>>)> =
        edits.iter().map(|(id, es)| (id.clone(), es.iter().map(|(j, s)| (j.as_str(), *s)).collect())).collect();
    let want: Vec<(String, Option<String>, String)> = cards.iter().map(|id| (id.clone(), None, String::new())).collect();
    Ok(registers::card_lineage_flags(&all, &want)?.into_iter().map(|(l, _)| l).collect())
}

/// 每个要的卡的 (血统：自己在前、再按广度优先列出全部前身, 继承后的标志 JSON)，与输入同序。
fn lineages(c: &Connection, cfg: &CacheConfig, want: &[(String, Option<String>)]) -> Result<Vec<(Vec<String>, Value)>, String> {
    if want.is_empty() {
        return Ok(Vec::new());
    }
    let mut edits: BTreeMap<String, Vec<(String, String, Option<i64>)>> = BTreeMap::new();
    let mut next: BTreeSet<String> = want.iter().map(|w| w.0.clone()).collect();
    for _ in 0..256 {
        if next.is_empty() {
            break;
        }
        let ids: Vec<String> = next.iter().cloned().collect();
        let mut got = edits_of(c, "card", &ids)?;
        let mut preds: BTreeSet<String> = BTreeSet::new();
        for id in &ids {
            let es = got.remove(id).unwrap_or_default();
            for (key, _, _) in &es {
                if let Some(p) = key.strip_prefix(HISTORY_FROM) {
                    if !edits.contains_key(p) && !ids.iter().any(|x| x == p) {
                        preds.insert(p.to_owned());
                    }
                }
            }
            edits.insert(id.clone(), es);
        }
        next = preds;
    }
    let cards: Vec<(String, Vec<StoredEdit<'_>>)> =
        edits.iter().map(|(id, es)| (id.clone(), es.iter().map(|e| (e.1.as_str(), e.2)).collect())).collect();
    let want3: Vec<(String, Option<String>, String)> =
        want.iter().map(|(id, deck)| (id.clone(), deck.clone(), cfg.default_deck.clone())).collect();
    registers::card_lineage_flags(&cards, &want3)
}

/// 「只有卡片事件变了」的一块卡：已有缓存行的模板 / 序号 / 可见性不变，标志与状态按血统重算。还没有缓存行的
/// 卡跳过（日志先于笔记到达：笔记到时一起生成）。
fn flush_cards(c: &Connection, profile: &str, cfg: &CacheConfig, chunk: &[String], out: &mut Written) -> Result<(), String> {
    struct Row {
        id: String,
        note: String,
        template: String,
        ord: i64,
        hidden: bool,
        note_created: i64,
        freq: Option<i64>,
    }
    let q = format!(
        "SELECT srs_idt(id) AS id, srs_idt(note_id) AS note_id, srs_idt(template_id) AS template_id, cloze_ord, hidden, note_created_at, freq_rank FROM srs_cards_cache \
         WHERE id IN ({})",
        marks(chunk.len())
    );
    let mut stmt = c.prepare_cached(&q).map_err(sql)?;
    let mut rows: HashMap<String, Row> = HashMap::new();
    let mut it = stmt.query(params_from_iter(chunk.iter())).map_err(sql)?;
    while let Some(r) = it.next().map_err(sql)? {
        let id: String = r.get(0).map_err(sql)?;
        rows.insert(
            id.clone(),
            Row {
                id,
                note: r.get(1).map_err(sql)?,
                template: r.get(2).map_err(sql)?,
                ord: r.get(3).map_err(sql)?,
                hidden: r.get::<_, i64>(4).map_err(sql)? != 0,
                note_created: r.get(5).map_err(sql)?,
                freq: r.get(6).map_err(sql)?,
            },
        );
    }
    drop(it);
    if rows.is_empty() {
        return Ok(());
    }
    let note_ids: Vec<String> = rows.values().map(|r| r.note.clone()).collect::<BTreeSet<_>>().into_iter().collect();
    let mut notes: HashMap<String, (Option<String>, i64)> = HashMap::new();
    for ids in note_ids.chunks(500) {
        let q = format!("SELECT srs_idt(id) AS id, srs_idt(deck_id) AS deck_id, created_at FROM srs_notes_cache WHERE id IN ({})", marks(ids.len()));
        let mut stmt = c.prepare_cached(&q).map_err(sql)?;
        let mut it = stmt.query(params_from_iter(ids.iter())).map_err(sql)?;
        while let Some(r) = it.next().map_err(sql)? {
            notes.insert(r.get(0).map_err(sql)?, (r.get(1).map_err(sql)?, r.get(2).map_err(sql)?));
        }
    }
    let ordered: Vec<&Row> = chunk.iter().filter_map(|id| rows.get(id)).collect();
    let want: Vec<(String, Option<String>)> =
        ordered.iter().map(|r| (r.id.clone(), notes.get(&r.note).and_then(|n| n.0.clone()))).collect();
    let materials = card_materials(c, cfg, &want)?;
    let mut card_stmt = c.prepare_cached(CARD_UPSERT).map_err(sql)?;
    for r in ordered {
        let created = notes.get(&r.note).map_or(r.note_created, |n| n.1);
        let m = materials.get(&r.id).ok_or("card material missing")?;
        // 名次由笔记派生：只有卡片事件变了时沿用缓存里的值（笔记变了走 [flush_notes] 重算）。
        write_card(&mut card_stmt, profile, &r.id, &r.note, &r.template, r.ord, created, r.hidden, r.freq, m)?;
        out.cards.push(r.id.clone());
    }
    Ok(())
}

const QUEUES: [&str; 4] = ["new", "learning", "review", "relearning"];

#[allow(clippy::too_many_arguments)]
fn write_card(
    stmt: &mut rusqlite::CachedStatement<'_>,
    profile: &str,
    card: &str,
    note: &str,
    template: &str,
    ord: i64,
    note_created: i64,
    hidden: bool,
    freq_rank: Option<i64>,
    m: &Material,
) -> Result<(), String> {
    let f = &m.flags;
    let s = &m.state;
    let queue = QUEUES.get(s.queue as usize).ok_or("bad queue")?;
    stmt.execute(rusqlite::params![
        card,
        profile,
        note,
        template,
        ord,
        f["dk"].as_str().ok_or("flags: deck missing")?,
        f["su"] == Value::Bool(true),
        f["bu"].as_i64(),
        f["fl"].as_i64().unwrap_or(0),
        hidden,
        queue,
        s.due_day,
        s.due_at,
        s.scheduled_days,
        s.reps,
        s.lapses,
        s.memory.map(|m| m.0),
        s.memory.map(|m| m.1),
        s.last_reviewed_at,
        s.last_log_id,
        s.scheduler,
        note_created,
        f["np"].as_i64(),
        freq_rank,
        crate::store::schema::anki_numeric_id(card),
    ])
    .map_err(sql)?;
    Ok(())
}

fn delete_cards(c: &Connection, ids: &[String]) -> Result<(), String> {
    for chunk in ids.chunks(500) {
        let q = format!("DELETE FROM srs_cards_cache WHERE id IN ({})", marks(chunk.len()));
        c.prepare_cached(&q).map_err(sql)?.execute(params_from_iter(chunk.iter())).map_err(sql)?;
    }
    Ok(())
}

const NOTE_UPSERT: &str = "INSERT INTO srs_notes_cache (id, profile_uid, note_type_id, guid, created_at, deck_id, \
     deleted_at, term_key, reading_key, sort_field, tags_json, pending_decision, updated_at, media_refs, source_kind, \
     source_title, anki_id, dupe_norm) \
     VALUES (srs_id(?1), srs_id(?2), srs_id(?3), ?4, ?5, srs_id(?6), ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18) ON CONFLICT(id) DO UPDATE SET \
     profile_uid = excluded.profile_uid, note_type_id = excluded.note_type_id, guid = excluded.guid, \
     created_at = excluded.created_at, deck_id = excluded.deck_id, deleted_at = excluded.deleted_at, \
     term_key = excluded.term_key, reading_key = excluded.reading_key, sort_field = excluded.sort_field, \
     tags_json = excluded.tags_json, pending_decision = excluded.pending_decision, \
     updated_at = excluded.updated_at, media_refs = excluded.media_refs, source_kind = excluded.source_kind, \
     source_title = excluded.source_title, anki_id = excluded.anki_id, dupe_norm = excluded.dupe_norm";

const CARD_UPSERT: &str = "INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, cloze_ord, deck_id, \
     suspended, buried_until_day, flag, hidden, queue, due_day, due_at, scheduled_days, reps, lapses, stability, \
     difficulty, last_reviewed_at, last_log_id, scheduler, note_created_at, new_position, freq_rank, anki_id) \
     VALUES (srs_id(?1), srs_id(?2), srs_id(?3), srs_id(?4), ?5, srs_id(?6), ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, srs_id(?20), ?21, ?22, ?23, \
     ?24, ?25) \
     ON CONFLICT(id) DO UPDATE SET profile_uid = excluded.profile_uid, note_id = excluded.note_id, \
     template_id = excluded.template_id, cloze_ord = excluded.cloze_ord, deck_id = excluded.deck_id, \
     suspended = excluded.suspended, buried_until_day = excluded.buried_until_day, flag = excluded.flag, \
     hidden = excluded.hidden, queue = excluded.queue, due_day = excluded.due_day, due_at = excluded.due_at, \
     scheduled_days = excluded.scheduled_days, reps = excluded.reps, lapses = excluded.lapses, \
     stability = excluded.stability, difficulty = excluded.difficulty, last_reviewed_at = excluded.last_reviewed_at, \
     last_log_id = excluded.last_log_id, scheduler = excluded.scheduler, note_created_at = excluded.note_created_at, \
     new_position = excluded.new_position, freq_rank = excluded.freq_rank, anki_id = excluded.anki_id";

// ---------------------------------------------------------------- 有效复习投影

/// 「前身卡 → 后继卡」链接：卡的 `historyFrom/<前身>` 修改记录（不看值：链接是超集，真正的血统按修改记录的
/// 生效值另算）。从种子卡按需查——后继按 `field_key`（v119 的部分覆盖索引 `idx_srs_field_edits_history_from`）、
/// 前身按 `entity_id`（`idx_srs_field_edits_entity`）——只查走到的卡；查过的卡记下，一次刷新里卡片闭包与投影
/// 连通分量共用。[Links::load_all] 一次读完全库（全量重建投影用，结果与逐卡查相同）。
#[derive(Default)]
pub(crate) struct Links {
    /// 查过后继的卡 → 它的后继（可为空；同一链接有几条修改记录就出现几次）。
    succ: HashMap<String, Vec<String>>,
    /// 查过前身的卡 → 它的前身。
    pred: HashMap<String, Vec<String>>,
    /// 全库已读完：没记下的卡就是没有链接。
    complete: bool,
}

impl Links {
    pub(crate) fn load_all(c: &Connection) -> Result<Links, String> {
        let mut stmt = c
            .prepare_cached(
                "SELECT srs_idt(entity_id) AS entity_id, field_key FROM srs_field_edits \
                 WHERE substr(field_key, 1, 12) = 'historyFrom/' AND +entity_kind = 'card'",
            )
            .map_err(sql)?;
        let mut out = Links { complete: true, ..Links::default() };
        let mut it = stmt.query([]).map_err(sql)?;
        while let Some(r) = it.next().map_err(sql)? {
            let succ: String = r.get(0).map_err(sql)?;
            let key: String = r.get(1).map_err(sql)?;
            out.add(key[HISTORY_FROM.len()..].to_owned(), succ);
        }
        Ok(out)
    }

    fn add(&mut self, pred: String, succ: String) {
        self.pred.entry(succ.clone()).or_default().push(pred.clone());
        self.succ.entry(pred).or_default().push(succ);
    }

    /// 补查 [ids] 里还没查过后继的卡。
    fn load_successors(&mut self, c: &Connection, ids: &[&String]) -> Result<(), String> {
        if self.complete {
            return Ok(());
        }
        let want: Vec<String> = ids.iter().filter(|id| !self.succ.contains_key(**id)).map(|id| format!("{HISTORY_FROM}{id}")).collect();
        for chunk in want.chunks(500) {
            let q = format!(
                "SELECT srs_idt(entity_id) AS entity_id, field_key FROM srs_field_edits WHERE field_key IN ({}) \
                 AND substr(field_key, 1, 12) = 'historyFrom/' AND +entity_kind = 'card'",
                marks(chunk.len())
            );
            let mut stmt = c.prepare_cached(&q).map_err(sql)?;
            let mut it = stmt.query(params_from_iter(chunk.iter())).map_err(sql)?;
            while let Some(r) = it.next().map_err(sql)? {
                let succ: String = r.get(0).map_err(sql)?;
                let key: String = r.get(1).map_err(sql)?;
                self.succ.entry(key[HISTORY_FROM.len()..].to_owned()).or_default().push(succ);
            }
            for k in chunk {
                self.succ.entry(k[HISTORY_FROM.len()..].to_owned()).or_default();
            }
        }
        Ok(())
    }

    /// 补查 [ids] 里还没查过前身的卡。
    fn load_predecessors(&mut self, c: &Connection, ids: &[&String]) -> Result<(), String> {
        if self.complete {
            return Ok(());
        }
        let want: Vec<&String> = ids.iter().copied().filter(|id| !self.pred.contains_key(*id)).collect();
        for chunk in want.chunks(500) {
            let q = format!(
                "SELECT srs_idt(entity_id) AS entity_id, field_key FROM srs_field_edits WHERE entity_kind = 'card' AND entity_id IN ({}) \
                 AND substr(field_key, 1, 12) = 'historyFrom/'",
                marks(chunk.len())
            );
            let mut stmt = c.prepare_cached(&q).map_err(sql)?;
            let mut it = stmt.query(params_from_iter(chunk.iter())).map_err(sql)?;
            while let Some(r) = it.next().map_err(sql)? {
                let succ: String = r.get(0).map_err(sql)?;
                let key: String = r.get(1).map_err(sql)?;
                self.pred.entry(succ).or_default().push(key[HISTORY_FROM.len()..].to_owned());
            }
            for id in chunk {
                self.pred.entry((*id).clone()).or_default();
            }
        }
        Ok(())
    }

    fn successors(&self, id: &str) -> &[String] {
        self.succ.get(id).map_or(&[], Vec::as_slice)
    }

    fn predecessors(&self, id: &str) -> &[String] {
        self.pred.get(id).map_or(&[], Vec::as_slice)
    }
}

/// [seeds] 与沿后继链接能走到的全部卡（广度优先，每一层一次批量查询）。
fn successor_closure(c: &Connection, links: &mut Links, seeds: impl IntoIterator<Item = String>) -> Result<BTreeSet<String>, String> {
    let mut closure: BTreeSet<String> = BTreeSet::new();
    let mut frontier: Vec<String> = seeds.into_iter().filter(|s| closure.insert(s.clone())).collect();
    while !frontier.is_empty() {
        links.load_successors(c, &frontier.iter().collect::<Vec<_>>())?;
        let mut next = Vec::new();
        for id in &frontier {
            for s in links.successors(id) {
                if closure.insert(s.clone()) {
                    next.push(s.clone());
                }
            }
        }
        frontier = next;
    }
    Ok(closure)
}

/// [seeds] 所在的「前身 ↔ 后继」连通分量（沿链接双向扩，广度优先、每一层两次批量查询）；返回里的每张卡前身 /
/// 后继都已查过（[Links::successors] / [Links::predecessors] 可直接用）。
fn link_family(c: &Connection, links: &mut Links, seeds: &BTreeSet<String>) -> Result<HashSet<String>, String> {
    let mut family: HashSet<String> = seeds.iter().cloned().collect();
    let mut frontier: Vec<String> = seeds.iter().cloned().collect();
    while !frontier.is_empty() {
        let refs: Vec<&String> = frontier.iter().collect();
        links.load_successors(c, &refs)?;
        links.load_predecessors(c, &refs)?;
        let mut next = Vec::new();
        for id in &frontier {
            for n in links.successors(id).iter().chain(links.predecessors(id)) {
                if family.insert(n.clone()) {
                    next.push(n.clone());
                }
            }
        }
        frontier = next;
    }
    Ok(family)
}

/// 有效复习投影（`srs_stat_reviews`）：[seeds] 所在的「前身 ↔ 后继」连通分量整份重算。归属：卡自己可见 → 归
/// 自己；否则归继承它历史的可见卡中 id 最小的；都不可见 → 归后代里的链尾中 id 最小的；没有后代 → 归自己。
fn refresh_stats(
    c: &Connection,
    profile: &str,
    cfg: &CacheConfig,
    links: &mut Links,
    seeds: &BTreeSet<String>,
) -> Result<(), String> {
    // 连通分量：沿链接双向扩（链接表是超集；真正的血统下面按修改记录的生效值算）。
    let family = link_family(c, links, seeds)?;
    let mut ids: Vec<String> = family.iter().cloned().collect();
    ids.sort_by(|a, b| cmp_utf16(a, b));
    let mut visible: HashSet<String> = HashSet::new();
    for chunk in ids.chunks(500) {
        let q = format!("SELECT srs_idt(id) AS id FROM srs_cards_cache WHERE hidden = 0 AND id IN ({})", marks(chunk.len()));
        let mut stmt = c.prepare_cached(&q).map_err(sql)?;
        let mut it = stmt.query(params_from_iter(chunk.iter())).map_err(sql)?;
        while let Some(r) = it.next().map_err(sql)? {
            visible.insert(r.get(0).map_err(sql)?);
        }
    }
    // 真后代：p 在 X 的血统里（X ≠ p）。只有带链接的卡才可能有前身 / 后代。
    let linked: Vec<String> =
        ids.iter().filter(|c| !links.successors(c).is_empty() || !links.predecessors(c).is_empty()).cloned().collect();
    let mut descendants: HashMap<String, BTreeSet<String>> = HashMap::new();
    for chunk in linked.chunks(CHUNK) {
        let want: Vec<(String, Option<String>)> = chunk.iter().map(|id| (id.clone(), None)).collect();
        for (k, (lineage, _)) in lineages(c, cfg, &want)?.into_iter().enumerate() {
            for p in lineage.into_iter().skip(1) {
                descendants.entry(p).or_default().insert(chunk[k].clone());
            }
        }
    }
    let sorted = |xs: Vec<&String>| -> Option<String> { xs.into_iter().min_by(|a, b| cmp_utf16(a, b)).cloned() };
    let owner_of = |id: &String| -> String {
        if visible.contains(id) {
            return id.clone();
        }
        let Some(d) = descendants.get(id).filter(|d| !d.is_empty()) else { return id.clone() };
        if let Some(o) = sorted(d.iter().filter(|x| visible.contains(*x)).collect()) {
            return o;
        }
        if let Some(o) = sorted(d.iter().filter(|x| descendants.get(*x).is_none_or(BTreeSet::is_empty)).collect()) {
            return o;
        }
        sorted(d.iter().collect()).expect("non-empty")
    };
    // 归属组（归属卡在前，再按 id 序列出归它的卡），组按首次出现的顺序。
    let mut order: Vec<String> = Vec::new();
    let mut groups: HashMap<String, Vec<String>> = HashMap::new();
    for id in &ids {
        let o = owner_of(id);
        let g = groups.entry(o.clone()).or_insert_with(|| {
            order.push(o.clone());
            vec![o.clone()]
        });
        if *id != o {
            g.push(id.clone());
        }
    }
    let family: Vec<&String> = family.iter().collect();
    for chunk in family.chunks(500) {
        let q = format!("DELETE FROM srs_stat_reviews WHERE card_id IN ({})", marks(chunk.len()));
        c.prepare_cached(&q).map_err(sql)?.execute(params_from_iter(chunk.iter())).map_err(sql)?;
    }
    let mut ins = c
        .prepare_cached(
            "INSERT INTO srs_stat_reviews (log_id, profile_uid, card_id, occurred_at, utc_offset_min, rating, kind, \
             duration_ms, prev_due_day, maturity_delta) VALUES (srs_id(?1), srs_id(?2), srs_id(?3), ?4, ?5, ?6, ?7, ?8, ?9, ?10) \
             ON CONFLICT(log_id) DO UPDATE SET profile_uid = excluded.profile_uid, card_id = excluded.card_id, \
             occurred_at = excluded.occurred_at, utc_offset_min = excluded.utc_offset_min, rating = excluded.rating, \
             kind = excluded.kind, duration_ms = excluded.duration_ms, prev_due_day = excluded.prev_due_day, \
             maturity_delta = excluded.maturity_delta",
        )
        .map_err(sql)?;
    let empty: Vec<(String, Option<i64>)> = Vec::new();
    for owners in order.chunks(500) {
        let batch: Vec<Vec<String>> = owners.iter().map(|o| groups[o].clone()).collect();
        let logs = logs_of(c, &batch)?;
        for (o, g) in owners.iter().zip(&batch) {
            let mut jsons: Vec<&str> = Vec::new();
            let mut servers: Vec<Option<i64>> = Vec::new();
            for id in g {
                for (j, s) in logs.get(id).unwrap_or(&empty) {
                    jsons.push(j);
                    servers.push(*s);
                }
            }
            for r in history::stats_from_json(&jsons, &servers)? {
                ins.execute(rusqlite::params![
                    r.log_id,
                    profile,
                    o,
                    r.occurred_at,
                    r.utc_off,
                    r.rating,
                    r.kind,
                    r.dur,
                    r.prev_due_day,
                    r.maturity_delta,
                ])
                .map_err(sql)?;
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------- 读

fn marks(n: usize) -> String {
    vec!["?"; n].join(",")
}

fn wall_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64)
}

fn strings(c: &Connection, q: &str, args: &[&str]) -> Result<Vec<String>, String> {
    let mut stmt = c.prepare_cached(q).map_err(sql)?;
    let rows = stmt
        .query_map(params_from_iter(args.iter()), |r| r.get::<_, String>(0))
        .map_err(sql)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(sql)?;
    Ok(rows)
}

/// 身份记录的 payload（按 ID，不分类型）。
fn entity_rows(c: &Connection, ids: &[String]) -> Result<HashMap<String, Value>, String> {
    let mut out = HashMap::new();
    for chunk in ids.chunks(500) {
        let q = format!("SELECT srs_idt(id) AS id, payload_json FROM srs_entities WHERE id IN ({})", marks(chunk.len()));
        let mut stmt = c.prepare_cached(&q).map_err(sql)?;
        let mut it = stmt.query(params_from_iter(chunk.iter())).map_err(sql)?;
        while let Some(r) = it.next().map_err(sql)? {
            let id: String = r.get(0).map_err(sql)?;
            let json: String = r.get(1).map_err(sql)?;
            out.insert(id, serde_json::from_str(&json).map_err(|e| format!("bad entity payload: {e}"))?);
        }
    }
    Ok(out)
}

/// 一组实体的全部修改记录：实体 ID → [(字段键, 落库 JSON, 服务器时刻)]，与 Dart 旧预读同一条 JOIN。
fn edits_of(c: &Connection, kind: &str, ids: &[String]) -> Result<HashMap<String, Vec<(String, String, Option<i64>)>>, String> {
    let mut out: HashMap<String, Vec<(String, String, Option<i64>)>> = HashMap::new();
    for chunk in ids.chunks(500) {
        let q = format!(
            "SELECT srs_idt(f.entity_id) AS entity_id, f.field_key, f.json, s.server_time FROM srs_field_edits f \
             LEFT JOIN srs_event_local s ON s.event_id = f.id WHERE f.entity_kind = ? AND f.entity_id IN ({})",
            marks(chunk.len())
        );
        let mut stmt = c.prepare_cached(&q).map_err(sql)?;
        let args = std::iter::once(kind).chain(chunk.iter().map(String::as_str));
        let mut it = stmt.query(params_from_iter(args)).map_err(sql)?;
        while let Some(r) = it.next().map_err(sql)? {
            let id: String = r.get(0).map_err(sql)?;
            out.entry(id).or_default().push((r.get(1).map_err(sql)?, r.get(2).map_err(sql)?, r.get(3).map_err(sql)?));
        }
    }
    Ok(out)
}

/// 一组笔记现有的卡缓存行 ID。
fn cards_of_notes(c: &Connection, notes: &[String]) -> Result<HashMap<String, Vec<String>>, String> {
    let mut out: HashMap<String, Vec<String>> = HashMap::new();
    for chunk in notes.chunks(500) {
        let q = format!("SELECT srs_idt(id) AS id, srs_idt(note_id) AS note_id FROM srs_cards_cache WHERE note_id IN ({})", marks(chunk.len()));
        let mut stmt = c.prepare_cached(&q).map_err(sql)?;
        let mut it = stmt.query(params_from_iter(chunk.iter())).map_err(sql)?;
        while let Some(r) = it.next().map_err(sql)? {
            let id: String = r.get(0).map_err(sql)?;
            out.entry(r.get(1).map_err(sql)?).or_default().push(id);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod link_tests {
    use std::collections::{BTreeSet, HashMap, HashSet};

    use rusqlite::Connection;

    use super::{lineage_ids, lineages, link_family, successor_closure, CacheConfig, Links, HISTORY_FROM};
    use serde_json::Value;
    use crate::store::SrsCore;

    /// 改写前的实现（全库前身链接读进内存，再在内存里扩）：对拍用，逐字保留原逻辑。
    fn old_successor_index(c: &Connection) -> HashMap<String, Vec<String>> {
        let mut stmt = c
            .prepare(
                "SELECT srs_idt(entity_id) AS entity_id, field_key FROM srs_field_edits \
                 WHERE substr(field_key, 1, 12) = 'historyFrom/' AND +entity_kind = 'card'",
            )
            .unwrap();
        let mut out: HashMap<String, Vec<String>> = HashMap::new();
        let mut it = stmt.query([]).unwrap();
        while let Some(r) = it.next().unwrap() {
            let succ: String = r.get(0).unwrap();
            let key: String = r.get(1).unwrap();
            out.entry(key[HISTORY_FROM.len()..].to_owned()).or_default().push(succ);
        }
        out
    }

    fn old_closure(succ: &HashMap<String, Vec<String>>, seeds: &[&str]) -> BTreeSet<String> {
        let mut closure: BTreeSet<String> = BTreeSet::new();
        let mut queue: Vec<String> = seeds.iter().map(|s| (*s).to_owned()).collect();
        while let Some(id) = queue.pop() {
            if closure.contains(&id) {
                continue;
            }
            if let Some(s) = succ.get(&id) {
                queue.extend(s.iter().cloned());
            }
            closure.insert(id);
        }
        closure
    }

    /// 旧 `refresh_stats` 的连通分量与「带链接的卡」。
    fn old_family(succ: &HashMap<String, Vec<String>>, seeds: &BTreeSet<String>) -> (BTreeSet<String>, BTreeSet<String>) {
        let mut pred: HashMap<&str, Vec<&str>> = HashMap::new();
        for (p, ss) in succ {
            for s in ss {
                pred.entry(s.as_str()).or_default().push(p.as_str());
            }
        }
        let mut family: HashSet<String> = HashSet::new();
        let mut queue: Vec<String> = seeds.iter().cloned().collect();
        while let Some(id) = queue.pop() {
            if family.contains(&id) {
                continue;
            }
            for s in succ.get(&id).into_iter().flatten() {
                queue.push(s.clone());
            }
            for p in pred.get(id.as_str()).into_iter().flatten() {
                queue.push((*p).to_owned());
            }
            family.insert(id);
        }
        let linked = family.iter().filter(|c| succ.contains_key(*c) || pred.contains_key(c.as_str())).cloned().collect();
        (family.into_iter().collect(), linked)
    }

    fn new_family(c: &Connection, links: &mut Links, seeds: &BTreeSet<String>) -> (BTreeSet<String>, BTreeSet<String>) {
        let family = link_family(c, links, seeds).unwrap();
        let linked =
            family.iter().filter(|x| !links.successors(x).is_empty() || !links.predecessors(x).is_empty()).cloned().collect();
        (family.into_iter().collect(), linked)
    }

    fn edit(c: &Connection, n: &mut i64, kind: &str, entity: &str, key: &str) {
        *n += 1;
        c.execute(
            "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json) \
             VALUES (srs_id(?1), 'p', ?2, srs_id(?3), ?4, 'w', ?5, '{}')",
            rusqlite::params![format!("e{n}"), kind, entity, key, *n],
        )
        .unwrap();
    }

    /// 多分叉链：分叉（A→B、A→C）、汇合成菱形（B→D、C→D）、两条链并入一张（D→E、F→E）、同一链接两条记录
    /// （不同写入者）、环（H→I→H）、跨链（E→J，K→J）、孤立卡、以及不该算进来的噪声（笔记上的 historyFrom/、
    /// 卡的别的字段）。每个种子、几组多种子、全部卡逐一对拍：按需 BFS 与旧的全库读入结果完全一致。
    #[test]
    fn on_demand_link_walks_match_the_full_index() {
        let dir = std::env::temp_dir().join(format!("ffsrs_links_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        let w = core.writer().unwrap();
        let mut n = 0;
        let links: &[(&str, &str)] = &[
            ("A", "B"), ("A", "C"), ("B", "D"), ("C", "D"), ("D", "E"), ("F", "E"), ("D", "E"),
            ("H", "I"), ("I", "H"), ("E", "J"), ("K", "J"), ("L", "M"), ("M", "N"), ("L", "N"),
        ];
        for (pred, succ) in links {
            edit(&w, &mut n, "card", succ, &format!("{HISTORY_FROM}{pred}"));
        }
        for card in ["A", "B", "G", "J", "Z"] {
            edit(&w, &mut n, "card", card, "deck");
            edit(&w, &mut n, "card", card, "flag");
        }
        edit(&w, &mut n, "note", "A", &format!("{HISTORY_FROM}Q"));
        edit(&w, &mut n, "note", "Q", &format!("{HISTORY_FROM}G"));
        let all = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "Q", "Z", "none"];
        let mut seed_sets: Vec<Vec<&str>> = all.iter().map(|s| vec![*s]).collect();
        seed_sets.extend([vec!["A", "F"], vec!["G", "H"], vec!["N", "K", "Z"], vec!["E", "M", "I"], all.to_vec(), vec![]]);
        let index = old_successor_index(&w);
        for seeds in &seed_sets {
            let set: BTreeSet<String> = seeds.iter().map(|s| (*s).to_owned()).collect();
            let expect_closure = old_closure(&index, seeds);
            let expect_family = old_family(&index, &set);
            // 每组种子用一份新的按需链接（与一次刷新相同），再用全库读入的 Links 各跑一遍。
            let mut lazy = Links::default();
            assert_eq!(successor_closure(&w, &mut lazy, set.iter().cloned()).unwrap(), expect_closure, "closure {seeds:?}");
            assert_eq!(new_family(&w, &mut lazy, &set), expect_family, "family after closure {seeds:?}");
            let mut fresh = Links::default();
            assert_eq!(new_family(&w, &mut fresh, &set), expect_family, "family {seeds:?}");
            let mut full = Links::load_all(&w).unwrap();
            assert_eq!(successor_closure(&w, &mut full, set.iter().cloned()).unwrap(), expect_closure, "full closure {seeds:?}");
            assert_eq!(new_family(&w, &mut full, &set), expect_family, "full family {seeds:?}");
        }
        // 抽查：菱形 + 汇合的闭包、环的分量。
        assert_eq!(
            old_closure(&index, &["A"]).into_iter().collect::<Vec<_>>(),
            ["A", "B", "C", "D", "E", "J"].map(String::from).to_vec()
        );
        let (fam, linked) = old_family(&index, &BTreeSet::from(["H".to_owned()]));
        assert_eq!(fam.into_iter().collect::<Vec<_>>(), ["H", "I"].map(String::from).to_vec());
        assert_eq!(linked.len(), 2);
        drop(w);
        core.close();
    }

    /// 只读前身链接的 [lineage_ids] 与读全部修改记录的 [lineages]（缓存刷新用的那条）逐卡同血统：分叉、菱形、环、
    /// 被同一写入者后来改成 false 的链接（不再算前身）、卡的别的字段与笔记上的同名键（噪声）。
    #[test]
    fn lineage_ids_match_full_edit_lineages() {
        let dir = std::env::temp_dir().join(format!("ffsrs_lineage_ids_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        let w = core.writer().unwrap();
        let mut n = 0i64;
        let mut put = |kind: &str, entity: &str, key: &str, v: Value| {
            n += 1;
            let json = serde_json::json!({
                "p": "p", "k": kind, "e": entity, "f": key, "w": "w", "s": n, "v": v,
                "hlc": format!("{}:0:w", 1_700_000_000_000i64 + n),
            })
            .to_string();
            w.execute(
                "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json)                  VALUES (srs_id(?1), 'p', ?2, srs_id(?3), ?4, 'w', ?5, ?6)",
                rusqlite::params![format!("e{n}"), kind, entity, key, n, json],
            )
            .unwrap();
        };
        for (pred, succ) in [("A", "B"), ("A", "C"), ("B", "D"), ("C", "D"), ("D", "E"), ("H", "I"), ("I", "H"), ("X", "E")] {
            put("card", succ, &format!("{HISTORY_FROM}{pred}"), Value::Bool(true));
        }
        // E 后来撤掉了 X 这个前身（同一写入者更新的记录支配旧的）。
        put("card", "E", &format!("{HISTORY_FROM}X"), Value::Bool(false));
        put("card", "B", "deck", Value::String("d".into()));
        put("card", "D", "flag", serde_json::json!(2));
        put("note", "A", &format!("{HISTORY_FROM}Q"), Value::Bool(true));
        let cfg = CacheConfig::parse(&serde_json::json!({"defaultDeck": "d"})).unwrap();
        let cards: Vec<String> = ["A", "B", "C", "D", "E", "H", "I", "X", "Q", "none"].map(String::from).to_vec();
        let want: Vec<(String, Option<String>)> = cards.iter().map(|c| (c.clone(), None)).collect();
        let full: Vec<Vec<String>> = lineages(&w, &cfg, &want).unwrap().into_iter().map(|(l, _)| l).collect();
        assert_eq!(lineage_ids(&w, &cards).unwrap(), full);
        assert_eq!(full[4], ["E", "D", "B", "C", "A"].map(String::from).to_vec(), "E without the retracted X");
        assert!(lineage_ids(&w, &[]).unwrap().is_empty());
        drop(w);
        core.close();
    }

    /// 按需查只碰种子所在的链：库里别的链再多，一次刷新的查询行数只与这条链有关（不再全表读入）。
    #[test]
    fn on_demand_walk_reads_only_the_seed_lineage() {
        let dir = std::env::temp_dir().join(format!("ffsrs_links_scope_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        let w = core.writer().unwrap();
        let mut n = 0;
        for i in 0..2000 {
            edit(&w, &mut n, "card", &format!("s{i}"), &format!("{HISTORY_FROM}p{i}"));
        }
        edit(&w, &mut n, "card", "y", &format!("{HISTORY_FROM}x"));
        let mut links = Links::default();
        let fam = link_family(&w, &mut links, &BTreeSet::from(["y".to_owned()])).unwrap();
        assert_eq!(fam, HashSet::from(["x".to_owned(), "y".to_owned()]));
        assert_eq!(links.succ.len() + links.pred.len(), 4, "walked beyond the seed lineage");
        drop(w);
        core.close();
    }

    /// 一次作答的缓存刷新里，前身链接这一步的耗时：旧（全库链接读进内存再扩）vs 新（从种子按需查）。库里
    /// [n] 条链（每条 3 张卡），种子是其中一条的头。手动跑：
    /// `cargo test --release --lib link_walk_bench -- --ignored --nocapture`。
    #[test]
    #[ignore]
    fn link_walk_bench() {
        let dir = std::env::temp_dir().join(format!("ffsrs_links_bench_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        let w = core.writer().unwrap();
        let n = 50_000;
        let mut k = 0;
        w.execute_batch("BEGIN").unwrap();
        for i in 0..n {
            edit(&w, &mut k, "card", &format!("b{i}"), &format!("{HISTORY_FROM}a{i}"));
            edit(&w, &mut k, "card", &format!("c{i}"), &format!("{HISTORY_FROM}b{i}"));
        }
        w.execute_batch("COMMIT").unwrap();
        let seeds = BTreeSet::from(["a7".to_owned()]);
        let runs = 20;
        let t0 = std::time::Instant::now();
        for _ in 0..runs {
            let index = old_successor_index(&w);
            let closure = old_closure(&index, &["a7"]);
            let fam = old_family(&index, &closure);
            assert_eq!(fam.0.len(), 3);
        }
        let old_ms = t0.elapsed().as_secs_f64() * 1000.0 / runs as f64;
        let t0 = std::time::Instant::now();
        for _ in 0..runs {
            let mut links = Links::default();
            let closure = successor_closure(&w, &mut links, seeds.iter().cloned()).unwrap();
            let fam = new_family(&w, &mut links, &closure);
            assert_eq!(fam.0.len(), 3);
        }
        let new_ms = t0.elapsed().as_secs_f64() * 1000.0 / runs as f64;
        println!("{} 条前身链接：旧 全库读入 {old_ms:.3} ms -> 新 按需 BFS {new_ms:.3} ms（闭包 + 连通分量，{runs} 次平均）", 2 * n);
        drop(w);
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    use super::{refresh, CacheConfig, Dirty};
    use crate::store::sync2::in_savepoint;
    use crate::store::sync2::tests::{deck_entity, edit, review, Device, P};

    const T0: i64 = 1_700_000_000_000;
    const N1: &str = "0193a1b2-0000-7000-8000-000000000001";
    const N2: &str = "0193a1b2-0000-7000-8000-000000000002";
    const N3: &str = "0193a1b2-0000-7000-8000-000000000003";

    fn note(id: &str, nt: &str) -> Value {
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": nt}}})
    }

    fn note_type(id: &str, payload: Value) -> Value {
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "notetype", "d": payload}})
    }

    fn run(d: &Device, cfg: &CacheConfig, dirty: Dirty) {
        let w = d.core.writer().unwrap();
        in_savepoint(&w, |c| refresh(c, P, cfg, dirty)).unwrap();
    }

    /// 每条笔记的卡的 freq_rank（NULL 记成 "null"）。
    fn ranks(d: &Device) -> Vec<(String, String)> {
        d.rows("SELECT srs_idt(note_id) AS note_id, IFNULL(freq_rank, 'null') FROM srs_cards_cache ORDER BY note_id")
            .into_iter()
            .skip(1)
            .map(|r| (r[0].clone(), r[1].clone()))
            .collect()
    }

    fn pairs(xs: &[(&str, &str)]) -> Vec<(String, String)> {
        xs.iter()
            .map(|(a, b)| ((*a).to_owned(), (*b).to_owned()))
            .collect()
    }

    /// freq_rank 由缓存刷新从笔记的词频序字段写出（原 Dart `_planNote` + `freqRankOf`）：没显式设时按字段名
    /// `FreqSort`（去空白、不分大小写）认；显式设 `freqField` 后改读那个字段（笔记类型标脏 → 成员笔记重算）；
    /// 只有卡片事件变了时沿用缓存里的名次；内置类型的代码默认 `freqFieldId` 经 [CacheConfig] 生效。
    #[test]
    fn freq_rank_follows_the_note_types_frequency_field() {
        let d = Device::new("freq-rank");
        let deck = crate::store::sync2::config::default_deck_id(P);
        let fdef = |name: &str, ord: i64| json!({"name": name, "ord": ord});
        d.apply(
            T0,
            vec![
                deck_entity(&deck),
                note_type("NT", json!({"createdAt": 1, "ntKind": "standard"})),
                edit("notetype", "NT", "fieldDef/fa", fdef("Expression", 0)),
                edit("notetype", "NT", "fieldDef/fb", fdef(" freqSORT ", 1)),
                edit("notetype", "NT", "fieldDef/fc", fdef("Other", 2)),
                edit(
                    "notetype",
                    "NT",
                    "tmplDef/t1",
                    json!({"name": "C", "ord": 0, "front": "{{Expression}}"}),
                ),
                note(N1, "NT"),
                edit("note", N1, "f/fa", json!("猫")),
                edit("note", N1, "f/fb", json!("<b>1,234</b>")),
                edit("note", N1, "f/fc", json!("rank 77")),
                note(N2, "NT"),
                edit("note", N2, "f/fa", json!("犬")),
                edit("note", N2, "f/fb", json!("0")),
                note_type(
                    "NB",
                    json!({"createdAt": 1, "ntKind": "standard", "builtin": "bk"}),
                ),
                note(N3, "NB"),
                edit("note", N3, "f/x", json!("鳥")),
                edit("note", N3, "f/y", json!("&#53;")),
            ],
        );
        let builtin = json!({
            "name": "B", "css": "", "termFieldId": "x", "freqFieldId": "y",
            "fields": [{"id": "x", "name": "Word", "ord": 0}, {"id": "y", "name": "Rank", "ord": 1}],
            "templates": [{"id": "t", "name": "C", "ord": 0, "front": "{{Word}}", "back": ""}],
        });
        let cfg = CacheConfig::parse(
            &json!({"defaultDeck": deck, "builtins": {"bk": {"b": builtin, "reading": null}}}),
        )
        .unwrap();
        run(
            &d,
            &cfg,
            Dirty {
                all_notes: true,
                ..Dirty::default()
            },
        );
        assert_eq!(ranks(&d), pairs(&[(N1, "1"), (N2, "null"), (N3, "5")]));

        // 显式指定词频序字段：类型标脏，成员笔记重算。
        let r = d.apply(
            T0 + 1,
            vec![edit("notetype", "NT", "freqField", json!("fc"))],
        );
        let dirty = Dirty::of_projection(&r);
        assert!(dirty.note_types.contains("NT"), "{r}");
        run(&d, &cfg, dirty);
        assert_eq!(ranks(&d), pairs(&[(N1, "77"), (N2, "null"), (N3, "5")]));

        // 只有卡片事件变了：名次沿用。
        let card = d.rows(&format!(
            "SELECT srs_idt(id) AS id FROM srs_cards_cache WHERE note_id = '{N1}'"
        ))[1][0]
            .clone();
        let r = d.apply(T0 + 2, vec![review("r1", &card, T0 + 2, 3, "learn")]);
        let dirty = Dirty::of_projection(&r);
        assert!(dirty.cards.contains(&card), "{r}");
        run(&d, &cfg, dirty);
        assert_eq!(ranks(&d), pairs(&[(N1, "77"), (N2, "null"), (N3, "5")]));

        // 显式字段指向不存在的字段：退回按名字认。
        let r = d.apply(
            T0 + 3,
            vec![edit("notetype", "NT", "freqField", json!("gone"))],
        );
        run(&d, &cfg, Dirty::of_projection(&r));
        assert_eq!(ranks(&d), pairs(&[(N1, "1"), (N2, "null"), (N3, "5")]));
    }
}
