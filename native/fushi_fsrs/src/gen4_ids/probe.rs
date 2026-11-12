//! 真实库上的别名验上率探针（默认不跑；只读）。
//!
//! `SRS_G3_DB=<srs.db 的只读副本> cargo test --release --lib gen4_ids::probe -- --ignored --nocapture`
//!
//! 以 `immutable=1` 只读打开，从旧投影表取证据（`srs_entities`、`srs_field_edits`、`srs_review_logs`、
//! `srs_cards_cache`、`sync2_devices`、`srs_meta`），盐 = 库里出现的 profile uid ∪ `srs_meta.srs_retired_profile_uids`，
//! 内置笔记类型表取自黄金向量文件。按类输出：总数、已是规范、带盐验上、随父派生（规范 ID 变 / 不变）、兜底验上、
//! 验不上（按原因），以及引用处（字段键、卡缓存列、寄存器值里嵌的 ID）的归一情况、别名类里观察到多于一个成员的
//! 类数（归一后会合成一个的）、耗时与堆峰值。同一份证据再按「只认集合里出现过的 ID」跑一遍作对照。
//!
//! 输出不含任何 ID 原文与笔记内容，只有计数。

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::time::Instant;

use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags};
use serde::Deserialize;
use serde_json::Value;
use serde_json::value::RawValue;

use crate::store::sync2::mem_bench::measure;
use crate::sync2::id::Id;

use super::alias::{
    Aliases, BuiltinNoteType, DeckEv, DefEv, Dot, Evidence, How, Limits, LogEv, NoteEv, NoteTypeEv,
    Why, WriterEv, WriterHow, resolve, strict_id,
};
use super::rules;

fn id_of(v: ValueRef<'_>) -> Option<Id> {
    match v {
        ValueRef::Blob(b) if b.len() == 16 => Some(Id(b.try_into().expect("16 bytes"))),
        ValueRef::Text(t) => std::str::from_utf8(t).ok().and_then(strict_id),
        _ => None,
    }
}

/// `jslim` 里的 JSON 部分（瘦形态前面有 `~<缺的键>`，见 store/slim.rs）。
fn slim_json(s: &str) -> &str {
    s.find('{').map_or("{}", |i| &s[i..])
}

#[derive(Deserialize, Default)]
struct EditSlim<'a> {
    #[serde(default)]
    hlc: Option<String>,
    #[serde(default)]
    ctx: Option<EditCtx>,
    #[serde(default, borrow)]
    v: Option<&'a RawValue>,
}

#[derive(Deserialize, Default)]
struct EditCtx {
    #[serde(default)]
    vv: BTreeMap<String, serde::de::IgnoredAny>,
}

#[derive(Deserialize, Default)]
struct LogSlim {
    #[serde(default, rename = "ankiId")]
    anki_id: Option<i64>,
    #[serde(default)]
    hlc: Option<String>,
    #[serde(default)]
    revokes: Option<String>,
}

/// HLC 文本 `<物理>:<计数>:<写入者>`。
fn hlc_parts(hlc: &str) -> Option<(i64, i64, &str)> {
    crate::history::parse_hlc(hlc).ok()
}

fn hlc_writer(hlc: &str) -> Option<&str> {
    hlc_parts(hlc).map(|(_, _, w)| w)
}

/// 探针自己记的清单（按类报数用；证据里不需要的都在这里）。
#[derive(Default)]
struct Census {
    notes: Vec<Id>,
    note_types: Vec<Id>,
    field_defs: Vec<Id>,
    template_defs: Vec<Id>,
    decks: Vec<Id>,
    profile_entities: Vec<Id>,
    live_cards: Vec<Id>,
    lineage_cards: Vec<Id>,
    logs_on_lineage: usize,
    card_edit_entities: Vec<Id>,
    history_from: Vec<Id>,
    /// 日志按（种类 / 来源）分组。
    logs: BTreeMap<String, Vec<Id>>,
    log_digest: HashMap<Id, [u8; 8]>,
    /// 修改记录：(id, 写入者, seq)。
    edits: Vec<(Id, String, u64)>,
    /// 写入者 → seq → HLC 的（物理时刻, 计数）。
    dots: HashMap<String, HashMap<u64, (i64, i64)>>,
    /// 盐（排序后）各自的来源。
    salt_sources: Vec<&'static str>,
    /// 引用处：标签 → ID（可重复）。
    refs: BTreeMap<&'static str, Vec<Id>>,
    non_uuid_ids: usize,
    text_typed: BTreeMap<&'static str, usize>,
}

fn load(c: &Connection) -> (Evidence, Census) {
    let mut ev = Evidence::default();
    let mut cs = Census::default();

    // 盐与内置表。
    let mut salts: BTreeSet<String> = BTreeSet::new();
    for t in ["sync2_self", "srs_entities"] {
        let mut st = c
            .prepare(&format!("SELECT DISTINCT srs_idt(profile_uid) FROM {t}"))
            .unwrap();
        let mut q = st.query([]).unwrap();
        while let Some(r) = q.next().unwrap() {
            salts.insert(r.get::<_, String>(0).unwrap());
        }
    }
    let present: BTreeSet<String> = salts.clone();
    let meta = |key: &str| -> Vec<String> {
        c.query_row("SELECT value FROM srs_meta WHERE key = ?1", [key], |r| {
            r.get::<_, String>(0)
        })
        .ok()
        .and_then(|s| serde_json::from_str::<Vec<String>>(&s).ok())
        .unwrap_or_default()
    };
    salts.extend(meta("srs_retired_profile_uids"));
    for s in &salts {
        cs.salt_sources.push(if present.contains(s) {
            "profile_uid column of this file"
        } else {
            "only in this device's srs_meta.srs_retired_profile_uids"
        });
    }
    ev.salts = salts.into_iter().collect();
    let golden: Value = serde_json::from_str(super::GOLDEN).unwrap();
    for b in golden["builtins"].as_array().unwrap() {
        ev.builtins.push(BuiltinNoteType {
            key: b["key"].as_str().unwrap().to_owned(),
            field_seeds: b["fields"]
                .as_array()
                .unwrap()
                .iter()
                .map(|f| f["seed"].as_str().unwrap().to_owned())
                .collect(),
            template_keys: b["templates"]
                .as_array()
                .unwrap()
                .iter()
                .map(|f| f["name"].as_str().unwrap().to_owned())
                .collect(),
        });
    }

    // 身份记录。
    let mut note_types: BTreeMap<Id, NoteTypeEv> = BTreeMap::new();
    let mut notes: BTreeMap<Id, NoteEv> = BTreeMap::new();
    let mut decks: BTreeMap<Id, DeckEv> = BTreeMap::new();
    {
        let mut st = c
            .prepare("SELECT id, kind, payload_json FROM srs_entities")
            .unwrap();
        let mut q = st.query([]).unwrap();
        while let Some(r) = q.next().unwrap() {
            if matches!(r.get_ref(0).unwrap(), ValueRef::Text(_)) {
                *cs.text_typed.entry("srs_entities.id").or_default() += 1;
            }
            let Some(id) = id_of(r.get_ref(0).unwrap()) else {
                cs.non_uuid_ids += 1;
                continue;
            };
            let kind: String = r.get(1).unwrap();
            let p: Value = serde_json::from_str(&r.get::<_, String>(2).unwrap()).unwrap();
            match kind.as_str() {
                "note" => {
                    cs.notes.push(id);
                    let nt = p["noteTypeId"].as_str().and_then(strict_id);
                    if let Some(nt) = nt {
                        cs.refs
                            .entry("note record noteTypeId")
                            .or_default()
                            .push(nt);
                    }
                    notes.insert(
                        id,
                        NoteEv {
                            id,
                            guid: p["guid"].as_str().map(str::to_owned),
                            note_types: nt.into_iter().collect(),
                            cloze_ords: Vec::new(),
                        },
                    );
                }
                "notetype" => {
                    cs.note_types.push(id);
                    note_types.insert(
                        id,
                        NoteTypeEv {
                            id,
                            anki_num: p["ankiNum"].as_i64(),
                            cloze: p["ntKind"].as_str() == Some("cloze"),
                            ..NoteTypeEv::default()
                        },
                    );
                }
                "deck" => {
                    cs.decks.push(id);
                    decks.insert(
                        id,
                        DeckEv {
                            id,
                            ..DeckEv::default()
                        },
                    );
                }
                _ => {}
            }
        }
    }

    // 修改记录：一遍扫完（定义史、牌组名字与父牌组、笔记类型史、卡类实体、写入者、引用处）。
    let mut writers: BTreeSet<String> = BTreeSet::new();
    let mut cards: BTreeSet<Id> = BTreeSet::new();
    let mut card_entities: BTreeSet<Id> = BTreeSet::new();
    let mut history_from: BTreeSet<Id> = BTreeSet::new();
    let mut defs: BTreeMap<(Id, bool, Id), DefEv> = BTreeMap::new();
    {
        let mut st = c
            .prepare(
                "SELECT id, entity_kind, entity_id, field_key, writer_id, seq, jslim FROM srs_field_edits",
            )
            .unwrap();
        let mut q = st.query([]).unwrap();
        while let Some(r) = q.next().unwrap() {
            let (Some(id), Some(entity)) =
                (id_of(r.get_ref(0).unwrap()), id_of(r.get_ref(2).unwrap()))
            else {
                cs.non_uuid_ids += 1;
                continue;
            };
            let kind = r.get_ref(1).unwrap().as_str().unwrap();
            let key = r.get_ref(3).unwrap().as_str().unwrap();
            if matches!(r.get_ref(4).unwrap(), ValueRef::Text(_)) {
                *cs.text_typed
                    .entry("srs_field_edits.writer_id")
                    .or_default() += 1;
            }
            let writer = crate::store::ids::text(r.get_ref(4).unwrap()).unwrap();
            let seq: i64 = r.get(5).unwrap();
            let slim = r.get_ref(6).unwrap().as_str().unwrap();
            let e: EditSlim<'_> = serde_json::from_str(slim_json(slim)).unwrap_or_default();
            if let Some(w) = e.hlc.as_deref().and_then(hlc_writer) {
                if !writers.contains(w) {
                    writers.insert(w.to_owned());
                }
            }
            if let Some(ctx) = &e.ctx {
                for w in ctx.vv.keys() {
                    if !writers.contains(w) {
                        writers.insert(w.clone());
                    }
                }
            }
            if !writers.contains(&writer) {
                writers.insert(writer.clone());
            }
            if let Some((physical, counter, _)) = e.hlc.as_deref().and_then(hlc_parts) {
                let dot = (seq as u64, (physical, counter));
                match cs.dots.get_mut(&writer) {
                    Some(d) => {
                        d.insert(dot.0, dot.1);
                    }
                    None => {
                        cs.dots.insert(writer.clone(), HashMap::from([dot]));
                    }
                }
            }
            cs.edits.push((id, writer, seq as u64));
            let value = || -> Value {
                e.v.map(|v| serde_json::from_str(v.get()).unwrap_or(Value::Null))
                    .unwrap_or(Value::Null)
            };
            let ref_id = |cs: &mut Census, label: &'static str, v: &Value| {
                if let Some(x) = v.as_str().and_then(strict_id) {
                    cs.refs.entry(label).or_default().push(x);
                }
            };
            match kind {
                "notetype" => {
                    let (is_field, rest) = if let Some(x) = key.strip_prefix("fieldDef/") {
                        (true, x)
                    } else if let Some(x) = key.strip_prefix("tmplDef/") {
                        (false, x)
                    } else {
                        if let Some(x) = key.strip_prefix("fieldDesc/").and_then(strict_id) {
                            cs.refs.entry("fieldDesc/<field> key").or_default().push(x);
                        }
                        continue;
                    };
                    let Some(def) = strict_id(rest) else {
                        cs.non_uuid_ids += 1;
                        continue;
                    };
                    let v = value();
                    let d = defs
                        .entry((entity, is_field, def))
                        .or_insert_with(|| DefEv {
                            id: def,
                            ..DefEv::default()
                        });
                    if let Some(n) = v["ankiNum"].as_i64() {
                        d.anki_nums.push(n);
                    }
                    if let Some(s) = v["name"].as_str() {
                        d.names.push(s.to_owned());
                    }
                }
                "deck" => {
                    let d = decks.entry(entity).or_insert_with(|| DeckEv {
                        id: entity,
                        ..DeckEv::default()
                    });
                    match key {
                        "name" => {
                            if let Some(s) = value().as_str() {
                                d.names.push(s.to_owned());
                            }
                        }
                        "parent" => {
                            let v = value();
                            if let Some(p) = v.as_str().and_then(strict_id) {
                                d.parents.push(p);
                            }
                            ref_id(&mut cs, "deck parent value", &v);
                        }
                        _ => {}
                    }
                }
                "note" => {
                    if let Some(f) = key.strip_prefix("f/").and_then(strict_id) {
                        cs.refs.entry("f/<field> key").or_default().push(f);
                    } else if key == "noteType" {
                        let v = value();
                        if let Some(nt) = v.as_str().and_then(strict_id) {
                            if let Some(n) = notes.get_mut(&entity) {
                                n.note_types.push(nt);
                            }
                        }
                        ref_id(&mut cs, "note noteType value", &v);
                    } else if key == "deck" {
                        ref_id(&mut cs, "note deck value", &value());
                    }
                }
                "card" => {
                    card_entities.insert(entity);
                    cards.insert(entity);
                    if let Some(x) = key.strip_prefix("historyFrom/").and_then(strict_id) {
                        history_from.insert(x);
                        cards.insert(x);
                    } else if key == "deck" {
                        ref_id(&mut cs, "card deck value", &value());
                    }
                }
                "profile" => {
                    cs.profile_entities.push(entity);
                }
                _ => {}
            }
        }
    }
    cs.profile_entities.sort_unstable();
    cs.profile_entities.dedup();
    ev.other_ids.extend(cs.profile_entities.iter().copied());
    for ((nt, is_field, _), d) in defs {
        if is_field {
            cs.field_defs.push(d.id);
        } else {
            cs.template_defs.push(d.id);
        }
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

    // 卡缓存。
    let mut live: HashSet<Id> = HashSet::new();
    {
        let mut st = c
            .prepare("SELECT id, note_id, template_id, deck_id FROM srs_cards_cache")
            .unwrap();
        let mut q = st.query([]).unwrap();
        while let Some(r) = q.next().unwrap() {
            let Some(id) = id_of(r.get_ref(0).unwrap()) else {
                cs.non_uuid_ids += 1;
                continue;
            };
            live.insert(id);
            cs.live_cards.push(id);
            cards.insert(id);
            for (i, label) in [
                (1, "cards cache note_id"),
                (2, "cards cache template_id"),
                (3, "cards cache deck_id"),
            ] {
                if let Some(x) = id_of(r.get_ref(i).unwrap()) {
                    cs.refs.entry(label).or_default().push(x);
                }
            }
        }
    }

    // 日志。
    let mut lineage: BTreeMap<Id, usize> = BTreeMap::new();
    {
        let mut st = c
            .prepare("SELECT id, card_id, kind, origin, occurred_at, jslim FROM srs_review_logs")
            .unwrap();
        let mut q = st.query([]).unwrap();
        while let Some(r) = q.next().unwrap() {
            let (Some(id), Some(card)) =
                (id_of(r.get_ref(0).unwrap()), id_of(r.get_ref(1).unwrap()))
            else {
                cs.non_uuid_ids += 1;
                continue;
            };
            let kind = r.get_ref(2).unwrap().as_str().unwrap();
            let origin = r.get_ref(3).unwrap().as_str().unwrap();
            let at: i64 = r.get(4).unwrap();
            let slim = r.get_ref(5).unwrap().as_str().unwrap();
            let l: LogSlim = serde_json::from_str(slim_json(slim)).unwrap_or_default();
            if let Some(w) = l.hlc.as_deref().and_then(hlc_writer) {
                if !writers.contains(w) {
                    writers.insert(w.to_owned());
                }
            }
            let revokes = l.revokes.as_deref().and_then(strict_id);
            if let Some(x) = revokes {
                cs.refs.entry("undo revokes target").or_default().push(x);
            }
            if !live.contains(&card) {
                *lineage.entry(card).or_default() += 1;
            }
            let group = if kind == "importAnchor" {
                "import anchor".to_owned()
            } else if l.anki_id.is_some() {
                "imported revlog".to_owned()
            } else {
                format!("native {kind} (origin {origin})")
            };
            cs.logs.entry(group).or_default().push(id);
            let mut d = [0u8; 8];
            d.copy_from_slice(&blake3::hash(slim.as_bytes()).as_bytes()[..8]);
            cs.log_digest.insert(id, d);
            ev.logs.push(LogEv {
                id,
                card,
                anki_revlog_id: l.anki_id,
                anchor_at: (kind == "importAnchor").then_some(at),
                revokes,
            });
        }
    }
    cs.logs_on_lineage = lineage.values().sum();
    cs.lineage_cards = lineage.keys().copied().collect();
    cs.card_edit_entities = card_entities.into_iter().collect();
    cs.history_from = history_from.into_iter().collect();

    // 设备 ID 只当「最初的写入者」的候选（没在操作里出现过的不算观察到）。
    {
        let mut st = c
            .prepare("SELECT DISTINCT device FROM sync2_devices")
            .unwrap();
        let mut q = st.query([]).unwrap();
        while let Some(r) = q.next().unwrap() {
            if let Some(d) = id_of(r.get_ref(0).unwrap()) {
                ev.writer_hints.push(d.text());
            }
        }
    }
    ev.writer_hints.extend(meta("srs_retired_v2_devices"));

    ev.note_types = note_types.into_values().collect();
    ev.notes = notes.into_values().collect();
    ev.decks = decks.into_values().collect();
    ev.cards = cards.into_iter().collect();
    ev.writers = writers
        .into_iter()
        .map(|name| {
            let dots = cs.dots.get(&name).map_or_else(Vec::new, |d| {
                d.iter()
                    .map(|(seq, (physical, counter))| Dot {
                        seq: *seq,
                        physical: *physical,
                        counter: *counter,
                    })
                    .collect()
            });
            WriterEv { name, dots }
        })
        .collect();
    (ev, cs)
}

fn label(how: How, changed: bool) -> String {
    match how {
        How::Canonical => "canonical".to_owned(),
        How::Salted { salt } => format!("salted[{salt}]"),
        How::Derived if changed => "derived(id changes)".to_owned(),
        How::Derived => "derived(id same)".to_owned(),
        How::Fallback { salt } => format!("fallback[{salt}]"),
        How::Unverified(Why::NoNaturalKey) => "UNVERIFIED:no-natural-key".to_owned(),
        How::Unverified(Why::NoMatch) => "UNVERIFIED:no-match".to_owned(),
        How::Unverified(Why::TooManyCandidates) => "UNVERIFIED:too-many-candidates".to_owned(),
        How::Unverified(Why::NotDerived) => "random-id(not derived)".to_owned(),
        How::Unverified(Why::Conflict) => "UNVERIFIED:conflict".to_owned(),
        How::Unknown => "UNKNOWN(not in evidence)".to_owned(),
    }
}

/// 一类 ID 的报数：总数（去重）、各归类的个数、归一后与别的观察到的成员落在同一个规范 ID 上的类数。
fn row(al: &Aliases, name: &str, ids: &[Id]) {
    let distinct: BTreeSet<Id> = ids.iter().copied().collect();
    let mut by: BTreeMap<String, usize> = BTreeMap::new();
    let mut classes: HashMap<Id, usize> = HashMap::new();
    for id in &distinct {
        let canonical = al.canonical(id);
        *by.entry(label(al.how(id), canonical != *id)).or_default() += 1;
        *classes.entry(canonical).or_default() += 1;
    }
    let shared = classes.values().filter(|n| **n > 1).count();
    let shared_members: usize = classes.values().filter(|n| **n > 1).sum();
    let parts: Vec<String> = by.iter().map(|(k, v)| format!("{k}={v}")).collect();
    println!(
        "  {name:<34} total={:<7} {}  | classes with >1 observed member: {shared} ({shared_members} ids)",
        distinct.len(),
        parts.join(" ")
    );
}

fn report(ev: &Evidence, cs: &Census, al: &Aliases) {
    println!(
        "  rounds={} uuid-v5-computed={} table-entries={} conflicts={}",
        al.rounds(),
        al.hashes(),
        al.len(),
        al.conflicts()
    );
    println!(" entities");
    row(al, "note", &cs.notes);
    row(al, "note type", &cs.note_types);
    row(al, "field def (fieldDef/<id>)", &cs.field_defs);
    row(al, "template def (tmplDef/<id>)", &cs.template_defs);
    row(al, "deck", &cs.decks);
    row(al, "profile-level entity", &cs.profile_entities);
    println!(" cards");
    row(al, "live card (cards cache)", &cs.live_cards);
    row(al, "lineage card (logs, not cached)", &cs.lineage_cards);
    row(al, "card-kind edit entity", &cs.card_edit_entities);
    row(al, "historyFrom/<card> key", &cs.history_from);
    row(
        al,
        "all observed card ids",
        &ev.cards
            .iter()
            .chain(cs.lineage_cards.iter())
            .copied()
            .collect::<Vec<_>>(),
    );
    println!(" logs ({} on lineage cards)", cs.logs_on_lineage);
    let mut all_logs: Vec<Id> = Vec::new();
    for (group, ids) in &cs.logs {
        row(al, group, ids);
        all_logs.extend(ids.iter().copied());
    }
    row(al, "all logs", &all_logs);
    // 归一后落在同一个规范日志 ID 上的：内容是否逐字节相同。
    let mut groups: HashMap<Id, Vec<Id>> = HashMap::new();
    for id in &all_logs {
        groups.entry(al.canonical(id)).or_default().push(*id);
    }
    let (mut same, mut differ, mut members) = (0usize, 0usize, 0usize);
    for g in groups.values().filter(|g| g.len() > 1) {
        members += g.len();
        let first = cs.log_digest[&g[0]];
        if g.iter().all(|x| cs.log_digest[x] == first) {
            same += 1;
        } else {
            differ += 1;
        }
    }
    println!(
        "  log classes that collapse: {} ({} logs): stored jslim identical in {same}, different in {differ}",
        same + differ,
        members
    );
    println!(" references (embedded ids; distinct values)");
    for (name, ids) in &cs.refs {
        row(al, name, ids);
    }
    println!(" writers");
    let merged: Vec<&WriterEv> = ev
        .writers
        .iter()
        .filter(|w| w.name.starts_with("merged-"))
        .collect();
    let none: HashMap<u64, (i64, i64)> = HashMap::new();
    let mut by_how: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for (i, w) in merged.iter().enumerate() {
        let how = al.writer_how(&w.name);
        let e = by_how.entry(format!("{how:?}")).or_default();
        e.0 += 1;
        e.1 += w.dots.len();
        let mine = cs.dots.get(&w.name).unwrap_or(&none);
        let (origin_records, shared, same) = match al.writer_origin(&w.name) {
            Some(o) => {
                let theirs = cs.dots.get(o).unwrap_or(&none);
                let shared = mine.keys().filter(|s| theirs.contains_key(*s)).count();
                let same = mine
                    .iter()
                    .filter(|(s, x)| theirs.get(*s) == Some(*x))
                    .count();
                (theirs.len(), shared, same)
            }
            None => (0, 0, 0),
        };
        println!(
            "  merged writer #{i}: format={} records={} verdict={how:?} | origin: records here={origin_records}, seqs shared={shared}, of which same record={same}",
            if w.name.contains('~') {
                "tagged"
            } else {
                "old"
            },
            w.dots.len(),
        );
    }
    println!(
        "  writer names in ops={} (hints only: {}) merged-*={} by verdict (names, records): {by_how:?}",
        ev.writers.len(),
        ev.writer_hints.len(),
        merged.len()
    );
    let mut formula_ok = 0usize;
    let mut edits_by_merged = 0usize;
    let mut edits_resolved = 0usize;
    let mut lands_on_existing = 0usize;
    let mut would_land_if_hash_only = 0usize;
    let mut edit_ids: HashSet<Id> = HashSet::with_capacity(cs.edits.len());
    for (id, _, _) in &cs.edits {
        edit_ids.insert(*id);
    }
    for (id, w, seq) in &cs.edits {
        if rules::field_edit(w, *seq) == *id {
            formula_ok += 1;
        }
        if w.starts_with("merged-") {
            edits_by_merged += 1;
            let c = al.canonical_edit(id, w, *seq);
            if c != *id {
                edits_resolved += 1;
                if edit_ids.contains(&c) {
                    lands_on_existing += 1;
                }
            }
            // 对照：只按哈希归（不看是不是同一套 seq）会落到多少条已有的别的记录上。
            if al.writer_how(w) != WriterHow::Resolved {
                if let Some(o) = al.writer_origin(w) {
                    if edit_ids.contains(&rules::field_edit(o, *seq)) {
                        would_land_if_hash_only += 1;
                    }
                }
            }
        }
    }
    println!(
        "  edit records={} id == v5(edit/<writer>/<seq>): {formula_ok}; by merged-* writers: {edits_by_merged}, of which canonical id changes: {edits_resolved} (lands on another stored edit: {lands_on_existing}); hash-only would put {would_land_if_hash_only} edits of unresolved writers on an existing different edit",
        cs.edits.len()
    );
    println!(
        " storage shape: non-UUID ids skipped={} text-typed values: {:?}",
        cs.non_uuid_ids, cs.text_typed
    );
}

#[test]
#[ignore]
fn canonical_id_probe_real_db() {
    let path = std::env::var("SRS_G3_DB").expect("SRS_G3_DB");
    let uri = format!("file:///{}?immutable=1", path.replace('\\', "/"));
    let c = Connection::open_with_flags(
        &uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )
    .unwrap();
    crate::store::ids::register(&c).unwrap();
    c.execute_batch("PRAGMA mmap_size = 0; PRAGMA cache_size = -65536;")
        .unwrap();
    let t = Instant::now();
    let ((ev, cs), m) = measure(|| load(&c));
    println!(
        "evidence: loaded in {} ms (rust heap peak {:.1} MiB, kept {:.1} MiB; sqlite heap peak {:.1} MiB)",
        t.elapsed().as_millis(),
        m.rust_peak,
        m.rust_kept,
        m.sqlite_peak
    );
    for (i, src) in cs.salt_sources.iter().enumerate() {
        println!("salt[{i}]: {src}");
    }
    println!(
        "evidence: notes={} noteTypes={} decks={} cardIds={} logs={} writers={} builtins={}",
        ev.notes.len(),
        ev.note_types.len(),
        ev.decks.len(),
        ev.cards.len(),
        ev.logs.len(),
        ev.writers.len(),
        ev.builtins.len()
    );
    for virtual_aliases in [true, false] {
        let limits = Limits {
            virtual_aliases,
            ..Limits::default()
        };
        let (al, m) = measure(|| resolve(&ev, &limits));
        println!(
            "\n=== resolve (virtual aliases: {virtual_aliases}): {} ms, rust heap peak {:.1} MiB, kept {:.1} MiB",
            m.ms, m.rust_peak, m.rust_kept
        );
        report(&ev, &cs, &al);
    }
}
