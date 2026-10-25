//! 字段寄存器内核（铁律 H）：修改记录 → 多值寄存器 → 笔记 / 卡片标志 / 笔记类型 / 牌组的物化视图。
//!
//! 设计见 docs/specs/2026-10-23-srs-rust-core.md「第二阶段」。合并规则只在这里写一份，Dart 的
//! `SrsEntityEdits` / `SrsRegister`（packages/fushi_srs/lib/src/field_edit.dart、entities.dart）只是
//! 它的结果视图。一个批量入口 [materialize]，一次 FFI 调用处理一整批实体（一块缓存刷新 / 一次批量读）：
//!
//! - 修改记录是落库形态（canonical JSON 原文 + 服务器时刻 S(e)），解析与校验和 Dart
//!   `SrsFieldEdit.fromJson` 逐条对齐（必填键缺失 / 类型不对、ID 与 dot 不符都判坏数据）；
//! - 寄存器：同 ID 留最后一条 → 去掉被支配的（b 支配 a ⇔ b.ctx 含 a.dot）→ 按排序键（ordering.rs，
//!   与卡片历史共用）从大到小；并发且值不同 = 冲突；被覆盖的候选里值不同、且不全是机器产出的进冲突记录；
//! - 「值相同」的唯一口径 [same_value]：字段文本按「释义样式去重」的规范形比较（内联 `<style>` 与它的
//!   共享样式引用行是同一内容），其它值按规范 JSON 比较（int 与 double 不同、-0.0 与 0.0 不同）；
//! - 删除优先：删除寄存器里有没被支配的整数值 = 已删；与删除并发的内容修改另列出来（待裁决）；
//! - 卡片标志沿「前身」血统继承（广度优先、前身按 UTF-16 序、最多 256 张、防环）；
//! - 落库前的支配裁剪（[land]）与读路径同一个支配判据。
//!
//! 固定向量 packages/fushi_srs/test/registers/fixtures/ 由删除前的 Dart 实现生成，逐条一致。

use std::borrow::Cow;
use std::collections::HashMap;

use serde::Deserialize;
use serde_json::value::RawValue;
use serde_json::{json, Map, Value};
use sha1::{Digest, Sha1};

use crate::history::{parse_hlc, NONE_I64};
use crate::ordering::{cmp_utf16, SortKey};
use crate::style_dedup::same_field_text;


/// 修改记录 ID 的 UUIDv5 命名空间（Dart `srsNamespace`，冻结）。
const SRS_NAMESPACE: &str = "6f1c8a2e-4b7d-5e3f-9a10-2d4c6e8f0b13";

const KINDS: [&str; 5] = ["profile", "deck", "notetype", "note", "card"];

const KEY_DELETED: &str = "deleted";

/// 同步 v2 投影出的**合成**修改记录的写入者前缀（标签 OR-Set 每条笔记一行的 `sync2:tags:<笔记>`，见
/// store/sync2/semantics.rs `tags_writer`）。合成行不是某个作者的一次写入，没有因果 dot（`s` 恒为 1、`ctx` 空）：
/// 拿它和删除比「谁看见过谁」永远是「并发」。它与删除的并发由同步 v2 的扣住机制按底层 `#tag` 操作判定
/// （semantics.rs `evaluate_holds`：并发就扣住删除进冲突中心，删除根本不落进投影），这里不再判它。
pub(crate) const SYNTHETIC_WRITER_PREFIX: &str = "sync2:";
const HISTORY_FROM: &str = "historyFrom/";

// ---------------------------------------------------------------- 因果上下文

/// dotted version vector（causal_context.dart）：连续前缀 vv + 额外 dot 集合 cloud。只读：这里只判
/// 「含不含某个 dot」；本机写入者的上下文维护（合并 / 闭包）仍在 Dart 的 `SrsEditWriter`。
#[derive(Debug, Default)]
struct Ctx {
    vv: HashMap<String, i64>,
    cloud: HashMap<String, Vec<i64>>,
}

impl Ctx {
    /// Dart `SrsCausalContext.fromJson`：不是对象当空；vv 只认整数且 > 0；cloud 只认整数列表。
    fn parse(v: Option<&Value>) -> Ctx {
        let mut ctx = Ctx::default();
        let Some(Value::Object(m)) = v else {
            return ctx;
        };
        if let Some(Value::Object(vv)) = m.get("vv") {
            for (k, x) in vv {
                if let Some(n) = x.as_i64() {
                    if n > 0 {
                        ctx.vv.insert(k.clone(), n);
                    }
                }
            }
        }
        if let Some(Value::Object(cloud)) = m.get("cloud") {
            for (k, x) in cloud {
                if let Value::Array(xs) = x {
                    let set: Vec<i64> = xs.iter().filter_map(Value::as_i64).collect();
                    if !set.is_empty() {
                        ctx.cloud.insert(k.clone(), set);
                    }
                }
            }
        }
        ctx
    }

    fn contains(&self, writer: &str, seq: i64) -> bool {
        if seq <= self.vv.get(writer).copied().unwrap_or(0) {
            return true;
        }
        self.cloud.get(writer).is_some_and(|s| s.contains(&seq))
    }
}

// ---------------------------------------------------------------- 修改记录

#[derive(Deserialize)]
struct WireEdit<'a> {
    #[serde(default, borrow)]
    id: Option<&'a RawValue>,
    #[serde(borrow)]
    p: Cow<'a, str>,
    #[serde(default, borrow)]
    k: Option<Cow<'a, str>>,
    #[serde(borrow)]
    e: Cow<'a, str>,
    #[serde(borrow)]
    f: Cow<'a, str>,
    #[serde(borrow)]
    w: Cow<'a, str>,
    s: i64,
    #[serde(default)]
    ctx: Option<Value>,
    #[serde(default)]
    v: Option<Value>,
    #[serde(borrow)]
    hlc: Cow<'a, str>,
    #[serde(default, borrow)]
    #[serde(rename = "ts")]
    _ts: Option<Cow<'a, str>>,
    #[serde(default)]
    m: Option<Value>,
}

/// 一条解析好的修改记录。
struct Edit<'a> {
    id: String,
    kind: &'static str,
    entity: Cow<'a, str>,
    key: Cow<'a, str>,
    writer: Cow<'a, str>,
    seq: i64,
    ctx: Ctx,
    value: Value,
    physical: i64,
    counter: i64,
    hlc_writer: String,
    server_time: Option<i64>,
    machine: bool,
}

impl Edit<'_> {
    fn sort_key(&self) -> SortKey<'_> {
        SortKey::new(
            self.physical,
            self.counter,
            &self.hlc_writer,
            &self.id,
            self.server_time,
        )
    }

    /// b 支配 a ⇔ b 的作者修改时已经看见了 a（dot 不同且 b.ctx 含 a.dot）。
    fn dominates(&self, other: &Edit<'_>) -> bool {
        !(self.writer == other.writer && self.seq == other.seq)
            && self.ctx.contains(&other.writer, other.seq)
    }

    /// 谁也没看见谁。
    fn concurrent(&self, other: &Edit<'_>) -> bool {
        !self.ctx.contains(&other.writer, other.seq) && !other.ctx.contains(&self.writer, self.seq)
    }
}

fn uuid_bytes(uuid: &str) -> [u8; 16] {
    let hex: Vec<u8> = uuid.bytes().filter(|b| *b != b'-').collect();
    let mut out = [0u8; 16];
    for i in 0..16 {
        let s = std::str::from_utf8(&hex[2 * i..2 * i + 2]).expect("ascii");
        out[i] = u8::from_str_radix(s, 16).expect("namespace is a uuid");
    }
    out
}

fn hex(bytes: &[u8]) -> String {
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(H[(b >> 4) as usize] as char);
        s.push(H[(b & 15) as usize] as char);
    }
    s
}

/// RFC 9562 UUIDv5（Dart `uuidV5`，native/fushi_compute 同一算法）。
fn uuid_v5(namespace: &[u8; 16], name: &str) -> String {
    let mut h = Sha1::new();
    h.update(namespace);
    h.update(name.as_bytes());
    let d = h.finalize();
    let mut b = [0u8; 16];
    b.copy_from_slice(&d[..16]);
    b[6] = (b[6] & 0x0f) | 0x50;
    b[8] = (b[8] & 0x3f) | 0x80;
    let x = hex(&b);
    format!(
        "{}-{}-{}-{}-{}",
        &x[0..8],
        &x[8..12],
        &x[12..16],
        &x[16..20],
        &x[20..32]
    )
}

/// 修改记录 ID（Dart `SrsIds.fieldEdit`）：由 dot 决定。同步 v2 的投影行（sync2）与这里同一个函数。
pub fn edit_id(writer: &str, seq: i64) -> String {
    uuid_v5(&uuid_bytes(SRS_NAMESPACE), &format!("edit/{writer}/{seq}"))
}

/// Dart `SrsFieldEdit.fromJson`：kind 不认识 / 必填键缺失或类型不对 / ID 与 dot 不符 → 坏数据。
fn parse_edit<'a>(
    json: &'a str,
    server_time: Option<i64>,
    ns: &[u8; 16],
) -> Result<Edit<'a>, String> {
    let w: WireEdit<'a> = serde_json::from_str(json).map_err(|e| format!("bad field edit: {e}"))?;
    let _ = &w.p;
    let kind = match w.k.as_deref() {
        Some(k) => KINDS
            .iter()
            .copied()
            .find(|x| *x == k)
            .ok_or_else(|| format!("unknown entity kind {k}"))?,
        None => return Err("unknown entity kind null".to_owned()),
    };
    let (physical, counter, hlc_writer) = {
        let (p, c, wr) = parse_hlc(&w.hlc)?;
        (p, c, wr.to_owned())
    };
    let id = uuid_v5(ns, &format!("edit/{}/{}", w.w, w.s));
    if let Some(raw) = w.id {
        if raw.get().starts_with('"') {
            let given: String =
                serde_json::from_str(raw.get()).map_err(|e| format!("bad field edit id: {e}"))?;
            if given != id {
                return Err(format!("field edit id mismatch: {given} vs {id}"));
            }
        }
    }
    Ok(Edit {
        id,
        kind,
        entity: w.e,
        key: w.f,
        writer: w.w,
        seq: w.s,
        ctx: Ctx::parse(w.ctx.as_ref()),
        value: w.v.unwrap_or(Value::Null),
        physical,
        counter,
        hlc_writer,
        server_time,
        machine: w.m == Some(Value::Bool(true)),
    })
}

// ---------------------------------------------------------------- 「值相同」

/// 规范 JSON 相等（Dart `srsCanonicalJson(a) == srsCanonicalJson(b)`）：对象键序无关；
/// 整数与浮点不同（`1` ≠ `1.0`），浮点按位比较（`-0.0` ≠ `0.0`）。
fn canonical_eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Null, Value::Null) => true,
        (Value::Bool(x), Value::Bool(y)) => x == y,
        (Value::String(x), Value::String(y)) => x == y,
        (Value::Number(x), Value::Number(y)) => {
            if x.is_f64() || y.is_f64() {
                x.is_f64()
                    && y.is_f64()
                    && x.as_f64().map(f64::to_bits) == y.as_f64().map(f64::to_bits)
            } else {
                x == y
            }
        }
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| canonical_eq(p, q))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, v)| y.get(k).is_some_and(|w| canonical_eq(v, w)))
        }
        _ => false,
    }
}

/// 「值相同」的唯一口径（冲突判定、no-op 判定都用它）。
pub fn same_value(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::String(x), Value::String(y)) => same_field_text(x, y),
        _ => canonical_eq(a, b),
    }
}

// ---------------------------------------------------------------- 寄存器

/// 一个字段键的合并结果。下标都指向该实体的输入切片。
struct Register {
    key: String,
    /// 没被支配的记录，按排序键从大到小；第一条是当前生效值。
    live: Vec<usize>,
    conflicted: bool,
    visible_losers: Vec<usize>,
}

/// 一个实体的全部寄存器（键按首次出现的顺序，与 Dart `Map` 同序）。
struct Entity<'e, 'a> {
    edits: &'e [Edit<'a>],
    regs: Vec<Register>,
}

impl<'e, 'a> Entity<'e, 'a> {
    fn build(edits: &'e [Edit<'a>]) -> Self {
        let mut order: Vec<(&str, Vec<usize>)> = Vec::new();
        let mut at: HashMap<&str, usize> = HashMap::new();
        for (i, e) in edits.iter().enumerate() {
            let k: &str = &e.key;
            match at.get(k) {
                Some(&p) => order[p].1.push(i),
                None => {
                    at.insert(k, order.len());
                    order.push((k, vec![i]));
                }
            }
        }
        let regs = order
            .into_iter()
            .map(|(k, idx)| resolve(k, edits, &idx))
            .collect();
        Entity { edits, regs }
    }

    fn reg(&self, key: &str) -> Option<&Register> {
        self.regs.iter().find(|r| r.key == key)
    }

    /// 生效值（没有记录 / 寄存器空 = null）。
    fn value(&self, key: &str) -> &Value {
        static NULL: Value = Value::Null;
        match self.reg(key).and_then(|r| r.live.first()) {
            Some(&i) => &self.edits[i].value,
            None => &NULL,
        }
    }

    /// 删除优先：删除寄存器里第一条值为整数的候选的值。
    fn deleted_at(&self) -> Option<i64> {
        let r = self.reg(KEY_DELETED)?;
        r.live.iter().find_map(|&i| self.edits[i].value.as_i64())
    }

    /// 与删除记录并发（谁也没看见谁）的内容修改（原 Dart `srsEditsConcurrentWithDelete`）。
    fn concurrent_with_delete(&self) -> Vec<usize> {
        let Some(del) = self.reg(KEY_DELETED) else {
            return Vec::new();
        };
        let deletes: Vec<&Edit<'_>> = del
            .live
            .iter()
            .map(|&i| &self.edits[i])
            .filter(|e| e.value.as_i64().is_some())
            .collect();
        if deletes.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        for r in &self.regs {
            if r.key == KEY_DELETED {
                continue;
            }
            for &c in &r.live {
                // 合成行没有因果 dot，不参与（[SYNTHETIC_WRITER_PREFIX]）。
                if self.edits[c].writer.starts_with(SYNTHETIC_WRITER_PREFIX) {
                    continue;
                }
                if deletes.iter().any(|d| d.concurrent(&self.edits[c])) {
                    out.push(c);
                }
            }
        }
        out
    }

    /// 内容类待裁决（Dart `SrsNoteView.hasPendingDecision`）。
    fn pending_decision(&self, concurrent: &[usize]) -> bool {
        self.regs.iter().any(|r| r.conflicted)
            || (self.deleted_at().is_some() && !concurrent.is_empty())
    }

    fn registers_json(&self) -> Value {
        Value::Array(
            self.regs
                .iter()
                .map(|r| json!([r.key, r.live, u8::from(r.conflicted), r.visible_losers]))
                .collect(),
        )
    }
}

/// 合并一个字段键上的全部记录（原 Dart `srsResolveRegister`；顺序无关、幂等）。
fn resolve(key: &str, edits: &[Edit<'_>], idx: &[usize]) -> Register {
    // 同 ID 留最后一条。
    let mut all: Vec<usize> = Vec::with_capacity(idx.len());
    for (p, &i) in idx.iter().enumerate() {
        if !idx[p + 1..].iter().any(|&j| edits[j].id == edits[i].id) {
            all.push(i);
        }
    }
    let mut live: Vec<usize> = all
        .iter()
        .copied()
        .filter(|&a| !all.iter().any(|&b| edits[b].dominates(&edits[a])))
        .collect();
    live.sort_by(|&a, &b| edits[b].sort_key().cmp(&edits[a].sort_key()));
    let (conflicted, visible_losers) = match live.first() {
        None => (false, Vec::new()),
        Some(&w) => {
            let winner = &edits[w];
            let losers: Vec<usize> = live[1..]
                .iter()
                .copied()
                .filter(|&i| !same_value(&edits[i].value, &winner.value))
                .collect();
            let conflicted = !losers.is_empty();
            let visible = if winner.machine && losers.iter().all(|&i| edits[i].machine) {
                Vec::new()
            } else {
                losers
            };
            (conflicted, visible)
        }
    };
    Register {
        key: key.to_owned(),
        live,
        conflicted,
        visible_losers,
    }
}

// ---------------------------------------------------------------- 物化：强转（与 Dart `as T?` 同语义）

fn as_str<'v>(v: &'v Value, what: &str) -> Result<Option<&'v str>, String> {
    match v {
        Value::Null => Ok(None),
        Value::String(s) => Ok(Some(s)),
        _ => Err(format!("{what}: expected String?, got {v}")),
    }
}

fn as_int(v: &Value, what: &str) -> Result<Option<i64>, String> {
    match v {
        Value::Null => Ok(None),
        Value::Number(n) if n.is_i64() => Ok(n.as_i64()),
        _ => Err(format!("{what}: expected int?, got {v}")),
    }
}

fn as_num(v: &Value, what: &str) -> Result<Option<f64>, String> {
    match v {
        Value::Null => Ok(None),
        Value::Number(n) => Ok(n.as_f64()),
        _ => Err(format!("{what}: expected num?, got {v}")),
    }
}

fn get<'v>(m: &'v Value, key: &str) -> &'v Value {
    static NULL: Value = Value::Null;
    match m {
        Value::Object(o) => o.get(key).unwrap_or(&NULL),
        _ => &NULL,
    }
}

/// `SrsEntityRecord.createdAt`：`(payload['createdAt'] as int?) ?? 0`。
fn created_at(payload: &Value) -> Result<i64, String> {
    Ok(as_int(get(payload, "createdAt"), "createdAt")?.unwrap_or(0))
}

// ---------------------------------------------------------------- 物化：笔记

fn note_view(ent: &Entity<'_, '_>, payload: &Value, concurrent: &[usize]) -> Result<Value, String> {
    let mut fields: Vec<Value> = Vec::new();
    for r in &ent.regs {
        if let Some(id) = r.key.strip_prefix("f/") {
            let v = match ent.value(&r.key) {
                Value::String(s) => s.clone(),
                _ => String::new(),
            };
            fields.push(json!([id, v]));
        }
    }
    let tags: Vec<Value> = match ent.value("tags") {
        Value::Array(xs) => xs.iter().filter(|x| x.is_string()).cloned().collect(),
        _ => Vec::new(),
    };
    let note_type = match as_str(ent.value("noteType"), "noteType")? {
        Some(s) => s.to_owned(),
        None => as_str(get(payload, "noteTypeId"), "noteTypeId")?
            .ok_or("noteTypeId missing")?
            .to_owned(),
    };
    let guid = as_str(get(payload, "guid"), "guid")?
        .ok_or("guid missing")?
        .to_owned();
    let created = created_at(payload)?;
    let deck = as_str(ent.value("deck"), "deck")?.map(str::to_owned);
    Ok(json!({
        "nt": note_type,
        "g": guid,
        "ca": created,
        "f": fields,
        "t": tags,
        "s": ent.value("source"),
        "dk": deck,
        "da": ent.deleted_at(),
        "pd": ent.pending_decision(concurrent),
    }))
}

// ---------------------------------------------------------------- 物化：卡片标志

fn card_flags(
    inherited: &HashMap<&str, &Value>,
    note_deck: Option<&str>,
    fallback: &str,
) -> Result<Value, String> {
    static NULL: Value = Value::Null;
    let val = |k: &str| -> &Value { inherited.get(k).copied().unwrap_or(&NULL) };
    let deck = match as_str(val("deck"), "deck")? {
        Some(d) => d.to_owned(),
        None => note_deck.unwrap_or(fallback).to_owned(),
    };
    let new_pos = match val("newPos") {
        Value::Number(n) => match n.as_i64() {
            Some(i) if n.is_i64() => Some(i),
            // Dart `num.toInt()`：向零截断。
            _ => n.as_f64().map(|f| f as i64),
        },
        _ => None,
    };
    Ok(json!({
        "dk": deck,
        "su": *val("suspended") == Value::Bool(true),
        "bu": as_int(val("buried"), "buried")?,
        "fl": as_int(val("flag"), "flag")?.unwrap_or(0),
        "np": new_pos,
    }))
}

// ---------------------------------------------------------------- 物化：笔记类型

#[derive(Clone)]
struct FieldDef {
    id: String,
    name: String,
    ord: i64,
    anki_num: Option<i64>,
    description: String,
    deleted: bool,
}

#[derive(Clone)]
struct TemplateDef {
    id: String,
    name: String,
    ord: i64,
    front: String,
    back: String,
    anki_num: Option<i64>,
    deleted: bool,
}

/// Dart `SrsFieldDef.fromValue`：不是对象当空对象；name / ord / ankiNum 强转。
fn field_def(id: &str, v: &Value) -> Result<FieldDef, String> {
    Ok(FieldDef {
        id: id.to_owned(),
        name: as_str(get(v, "name"), "fieldDef.name")?
            .unwrap_or("")
            .to_owned(),
        ord: as_int(get(v, "ord"), "fieldDef.ord")?.unwrap_or(0),
        anki_num: as_int(get(v, "ankiNum"), "fieldDef.ankiNum")?,
        description: String::new(),
        deleted: *get(v, "deleted") == Value::Bool(true),
    })
}

fn template_def(id: &str, v: &Value) -> Result<TemplateDef, String> {
    Ok(TemplateDef {
        id: id.to_owned(),
        name: as_str(get(v, "name"), "tmplDef.name")?
            .unwrap_or("")
            .to_owned(),
        ord: as_int(get(v, "ord"), "tmplDef.ord")?.unwrap_or(0),
        front: as_str(get(v, "front"), "tmplDef.front")?
            .unwrap_or("")
            .to_owned(),
        back: as_str(get(v, "back"), "tmplDef.back")?
            .unwrap_or("")
            .to_owned(),
        anki_num: as_int(get(v, "ankiNum"), "tmplDef.ankiNum")?,
        deleted: *get(v, "deleted") == Value::Bool(true),
    })
}

fn field_json(f: &FieldDef) -> Value {
    json!({"id": f.id, "name": f.name, "ord": f.ord, "ankiNum": f.anki_num, "description": f.description, "deleted": f.deleted})
}

fn template_json(t: &TemplateDef) -> Value {
    json!({"id": t.id, "name": t.name, "ord": t.ord, "front": t.front, "back": t.back, "ankiNum": t.anki_num, "deleted": t.deleted})
}

/// 按插入顺序的小映射（Dart `Map` 语义：覆盖保留原位置，新键追加）。
struct Ordered<T> {
    items: Vec<T>,
}

impl<T> Ordered<T> {
    fn put(&mut self, id: &str, item: T, id_of: impl Fn(&T) -> &str) {
        match self.items.iter().position(|x| id_of(x) == id) {
            Some(p) => self.items[p] = item,
            None => self.items.push(item),
        }
    }
}

fn by_ord(a_ord: i64, a_id: &str, b_ord: i64, b_id: &str) -> std::cmp::Ordering {
    a_ord.cmp(&b_ord).then_with(|| cmp_utf16(a_id, b_id))
}

fn note_type_view(ent: &Entity<'_, '_>, payload: &Value, builtin: &Value) -> Result<Value, String> {
    let has_builtin = !builtin.is_null();
    let mut fields = Ordered::<FieldDef> { items: Vec::new() };
    let mut templates = Ordered::<TemplateDef> { items: Vec::new() };
    if let Value::Array(bf) = get(builtin, "fields") {
        for f in bf {
            let id = as_str(get(f, "id"), "builtin field id")?.unwrap_or("");
            let mut d = field_def(id, f)?;
            d.description = as_str(get(f, "description"), "builtin description")?
                .unwrap_or("")
                .to_owned();
            fields.put(id, d, |x| &x.id);
        }
    }
    if let Value::Array(bt) = get(builtin, "templates") {
        for t in bt {
            let id = as_str(get(t, "id"), "builtin template id")?.unwrap_or("");
            templates.put(id, template_def(id, t)?, |x| &x.id);
        }
    }
    // 每条字段 / 模板定义修改记录本身（含已删除的）：Anki 导入按它解析字段 ID（definedFields）。
    let mut edited_fields: Vec<FieldDef> = Vec::new();
    let mut edited_templates: Vec<TemplateDef> = Vec::new();
    for r in &ent.regs {
        if let Some(id) = r.key.strip_prefix("fieldDef/") {
            let d = field_def(id, ent.value(&r.key))?;
            edited_fields.push(d.clone());
            fields.put(id, d, |x| &x.id);
        } else if let Some(id) = r.key.strip_prefix("tmplDef/") {
            let t = template_def(id, ent.value(&r.key))?;
            edited_templates.push(t.clone());
            templates.put(id, t, |x| &x.id);
        }
    }
    // 字段说明是独立键，定义都物化完再并进去。
    for r in &ent.regs {
        let Some(id) = r.key.strip_prefix("fieldDesc/") else {
            continue;
        };
        let desc = match ent.value(&r.key) {
            Value::String(s) => s.clone(),
            _ => String::new(),
        };
        if let Some(f) = fields.items.iter_mut().find(|f| f.id == id) {
            f.description = desc;
        }
    }
    let mut live_fields: Vec<FieldDef> = fields
        .items
        .iter()
        .filter(|f| !f.deleted)
        .cloned()
        .collect();
    live_fields.sort_by(|a, b| by_ord(a.ord, &a.id, b.ord, &b.id));
    let mut live_templates: Vec<TemplateDef> = templates
        .items
        .iter()
        .filter(|t| !t.deleted)
        .cloned()
        .collect();
    live_templates.sort_by(|a, b| by_ord(a.ord, &a.id, b.ord, &b.id));

    // Dart 旧实现 `_haveDefs`（apkg 导入）：未删除的物化结果在前，再按记录顺序用定义记录本身覆盖。
    let mut defined_fields = Ordered::<FieldDef> {
        items: live_fields.clone(),
    };
    for d in edited_fields {
        let id = d.id.clone();
        defined_fields.put(&id, d, |x| &x.id);
    }
    let mut defined_templates = Ordered::<TemplateDef> {
        items: live_templates.clone(),
    };
    for t in edited_templates {
        let id = t.id.clone();
        defined_templates.put(&id, t, |x| &x.id);
    }

    let pick = |key: &str, fallback: &str, what: &str| -> Result<String, String> {
        Ok(match as_str(ent.value(key), what)? {
            Some(s) => s.to_owned(),
            None if has_builtin => as_str(get(builtin, key), what)?
                .unwrap_or(fallback)
                .to_owned(),
            None => fallback.to_owned(),
        })
    };
    let name = pick("name", "", "name")?;
    let css = pick("css", "", "css")?;
    let term = match as_str(ent.value("termField"), "termField")? {
        Some(s) => Some(s.to_owned()),
        None => as_str(get(builtin, "termFieldId"), "termFieldId")?.map(str::to_owned),
    };
    Ok(json!({
        "ak": as_int(get(payload, "ankiNum"), "ankiNum")?.unwrap_or(0),
        "nk": as_str(get(payload, "ntKind"), "ntKind")?.unwrap_or("standard"),
        "nm": name,
        "fs": live_fields.iter().map(field_json).collect::<Vec<_>>(),
        "ts": live_templates.iter().map(template_json).collect::<Vec<_>>(),
        "df": defined_fields.items.iter().map(field_json).collect::<Vec<_>>(),
        "dt": defined_templates.items.iter().map(template_json).collect::<Vec<_>>(),
        "css": css,
        "tf": term,
        "da": ent.deleted_at(),
        "bk": as_str(get(payload, "builtin"), "builtin")?,
    }))
}

// ---------------------------------------------------------------- 物化：牌组

/// 牌组的标量设置。参数组 / 步长 / RWKV 排队设置是值对象，原值交给 Dart 的值对象解析
/// （`SrsParamSet.fromValue` / `srsSanitizeSteps` / `SrsRwkvQueueSettings.fromValue`，别处也在用）；
/// 算法缺省值（`srsDefaultAlgorithm`）同样由 Dart 填。
fn deck_view(ent: &Entity<'_, '_>, payload: &Value) -> Result<Value, String> {
    let limits = ent.value("limits");
    let steps = ent.value("steps");
    let alg = ent.value("algorithm");
    let baseline = ent.value("optimizeBaseline");
    let parent = as_str(ent.value("parent"), "parent")?;
    let limit = |k: &str, d: i64| -> Result<i64, String> {
        if limits.is_object() {
            Ok(as_int(get(limits, k), "limits")?.unwrap_or(d))
        } else {
            Ok(d)
        }
    };
    let (alg_wire, alg_auto) = if alg.is_object() {
        (
            as_str(get(alg, "alg"), "alg")?.map(str::to_owned),
            *get(alg, "auto") != Value::Bool(false),
        )
    } else {
        (None, true)
    };
    let (baseline_at, baseline_n) = if baseline.is_object() {
        (
            as_int(get(baseline, "at"), "baseline.at")?,
            as_int(get(baseline, "n"), "baseline.n")?,
        )
    } else {
        (None, None)
    };
    let position = match ent.value("position") {
        Value::Number(n) => n.as_f64().filter(|f| f.is_finite()),
        _ => None,
    };
    let (learn, relearn) = if steps.is_object() {
        (get(steps, "learn").clone(), get(steps, "relearn").clone())
    } else {
        (Value::Null, Value::Null)
    };
    Ok(json!({
        "nm": as_str(ent.value("name"), "name")?.unwrap_or("Default"),
        "pa": parent,
        "own": parent.is_none() || *ent.value("paramsMode") == Value::String("own".to_owned()),
        "np": limit("new", 20)?,
        "rp": limit("review", 200)?,
        "ls": learn,
        "rs": relearn,
        "ret": as_num(ent.value("retention"), "retention")?.unwrap_or(0.8),
        "alg": alg_wire,
        "aa": alg_auto,
        "f6": ent.value("fsrs6Params"),
        "f7": ent.value("fsrs7Params"),
        "ao": *ent.value("autoOptimize") != Value::Bool(false),
        "mi": as_int(ent.value("maxInterval"), "maxInterval")?.unwrap_or(36500),
        "co": *ent.value("collapsed") == Value::Bool(true),
        "po": position,
        "ap": *ent.value("autoplay") != Value::Bool(false),
        "rq": *ent.value("replayQuestion") != Value::Bool(false),
        "rw": ent.value("rwkvQueue"),
        "ba": baseline_at,
        "bn": baseline_n,
        "da": ent.deleted_at(),
        "bk": as_str(get(payload, "builtin"), "builtin")?,
        "ca": created_at(payload)?,
    }))
}

// ---------------------------------------------------------------- 卡片血统

/// 一组卡（缓存刷新的一块：要的卡 + 预读到的全部前身）各自的寄存器、每张要的卡的血统与继承后的标志。
fn cards_group(
    edits: &[Edit<'_>],
    cards: &[(String, usize)],
    want: &[(String, Option<String>, String)],
) -> Result<Value, String> {
    let mut entities: Vec<Entity<'_, '_>> = Vec::with_capacity(cards.len());
    let mut by_id: HashMap<&str, usize> = HashMap::with_capacity(cards.len());
    let mut at = 0;
    for (k, (id, n)) in cards.iter().enumerate() {
        entities.push(Entity::build(&edits[at..at + n]));
        by_id.insert(id, k);
        at += n;
    }
    let mut wants = Vec::with_capacity(want.len());
    for (card, note_deck, fallback) in want {
        // 血统：自己在前，再按广度优先列出全部前身（防环，最多 256 张）。
        let mut lineage: Vec<&str> = Vec::new();
        let mut seen: Vec<&str> = vec![card];
        let mut queue: std::collections::VecDeque<&str> =
            std::collections::VecDeque::from([card.as_str()]);
        while let Some(id) = queue.pop_front() {
            if lineage.len() >= 256 {
                break;
            }
            lineage.push(id);
            let Some(&k) = by_id.get(id) else { continue };
            let ent = &entities[k];
            let mut preds: Vec<&str> = ent
                .regs
                .iter()
                .filter_map(|r| {
                    r.key
                        .strip_prefix(HISTORY_FROM)
                        .filter(|_| *ent.value(&r.key) == Value::Bool(true))
                })
                .collect();
            preds.sort_by(|a, b| cmp_utf16(a, b));
            for p in preds {
                if !seen.contains(&p) {
                    seen.push(p);
                    queue.push_back(p);
                }
            }
        }
        // 标志按血统继承：自己有记录的键用自己的，没有的取最近的前身的。
        let mut inherited: HashMap<&str, &Value> = HashMap::new();
        for id in lineage.iter().rev() {
            let Some(&k) = by_id.get(id) else { continue };
            let ent = &entities[k];
            for r in &ent.regs {
                if r.key.starts_with(HISTORY_FROM) {
                    continue;
                }
                inherited.insert(&r.key, ent.value(&r.key));
            }
        }
        let flags = card_flags(&inherited, note_deck.as_deref(), fallback)?;
        wants.push(json!({"l": lineage, "f": flags}));
    }
    Ok(json!({
        "r": entities.iter().map(|e| entity_json(e, None)).collect::<Vec<_>>(),
        "w": wants,
    }))
}

// ---------------------------------------------------------------- 落库前的支配裁剪

/// 已有的记录（前 [existing] 条）+ 依次到达的记录：每条到达的落不落库，以及它支配了哪些（已有的或
/// 先到的）、要从库里删掉（下标指向全部项，与到达顺序对齐）。与 Dart 旧 `_storeLocalBatch` / `SrsEventStore._applyEdit` 同语义：同 ID 已在（不论哪个
/// 字段键）或被同字段键上现存的记录支配 → 不落；落了就删掉同字段键上被它支配的。
fn land(edits: &[Edit<'_>], existing: usize) -> Value {
    let mut regs: HashMap<(&str, &str, &str), Vec<usize>> = HashMap::new();
    let mut ids: HashMap<&str, ()> = HashMap::new();
    for (i, e) in edits[..existing].iter().enumerate() {
        regs.entry((e.kind, &e.entity, &e.key)).or_default().push(i);
        ids.insert(&e.id, ());
    }
    let mut landed = Vec::with_capacity(edits.len() - existing);
    // 每条到达的记录删掉了谁（没落库的是空列表），与到达顺序对齐。
    let mut deleted: Vec<Vec<usize>> = Vec::with_capacity(edits.len() - existing);
    for (i, e) in edits.iter().enumerate().skip(existing) {
        let reg = regs.entry((e.kind, &e.entity, &e.key)).or_default();
        let ok = !ids.contains_key(e.id.as_str()) && !reg.iter().any(|&b| edits[b].dominates(e));
        landed.push(u8::from(ok));
        if !ok {
            deleted.push(Vec::new());
            continue;
        }
        let dominated: Vec<usize> = reg
            .iter()
            .copied()
            .filter(|&a| e.dominates(&edits[a]))
            .collect();
        reg.retain(|a| !dominated.contains(a));
        for &a in &dominated {
            ids.remove(edits[a].id.as_str());
        }
        deleted.push(dominated);
        reg.push(i);
        ids.insert(&e.id, ());
    }
    json!({"l": landed, "d": deleted})
}

// ---------------------------------------------------------------- 批量入口

#[derive(Deserialize)]
#[serde(tag = "t")]
enum Group {
    /// 只要寄存器。
    #[serde(rename = "edits")]
    Edits { n: usize },
    #[serde(rename = "note")]
    Note { n: usize, rec: Value },
    #[serde(rename = "notetype")]
    NoteType {
        n: usize,
        rec: Value,
        #[serde(default)]
        b: Value,
    },
    #[serde(rename = "deck")]
    Deck { n: usize, rec: Value },
    /// 一组卡：`cards` = [卡 ID, 记录条数]，`want` = [卡 ID, 笔记首选牌组, 默认牌组]。
    #[serde(rename = "cards")]
    Cards {
        cards: Vec<(String, usize)>,
        want: Vec<(String, Option<String>, String)>,
    },
    /// 落库裁剪：前 `e` 条是已有的，其余依次到达。
    #[serde(rename = "land")]
    Land { n: usize, e: usize },
    /// 两个原始 JSON 值是否相同（no-op 判定）：两项不是修改记录，是值本身。
    #[serde(rename = "same")]
    Same,
}

/// 批量物化。`header` 是组描述的 JSON 数组；第 i 项 = `text[offs[i]..offs[i+1]]`（修改记录的落库 JSON，
/// `same` 组是值本身），服务器时刻 `servers[i]`（[NONE_I64] = 未知）；各组按顺序依次消费项。
///
/// 输出是与组同序的 JSON 数组（UTF-8）。寄存器 = `[键, [生效顺序的项下标…], 冲突 0/1, [被覆盖的可见候选…]]`，
/// 下标相对该实体自己的项。
pub fn materialize(
    header: &[u8],
    text: &[u8],
    offs: &[u32],
    servers: &[i64],
) -> Result<Vec<u8>, String> {
    let n_items = servers.len();
    if offs.len() != n_items + 1 {
        return Err("bad register batch layout".to_owned());
    }
    let header =
        std::str::from_utf8(header).map_err(|_| "register header is not UTF-8".to_owned())?;
    let groups: Vec<Group> =
        serde_json::from_str(header).map_err(|e| format!("bad register header: {e}"))?;
    let text = std::str::from_utf8(text).map_err(|_| "register batch is not UTF-8".to_owned())?;
    let item = |i: usize| -> Result<&str, String> {
        let (a, b) = (offs[i] as usize, offs[i + 1] as usize);
        if a > b || b > text.len() || !text.is_char_boundary(a) || !text.is_char_boundary(b) {
            return Err("bad register batch offsets".to_owned());
        }
        Ok(&text[a..b])
    };
    let ns = uuid_bytes(SRS_NAMESPACE);
    let at = std::cell::Cell::new(0usize);
    let take = |n: usize| -> Result<Vec<Edit<'_>>, String> {
        let from = at.get();
        if from + n > n_items {
            return Err("register batch is shorter than its header".to_owned());
        }
        let mut out = Vec::with_capacity(n);
        for i in from..from + n {
            let s = servers[i];
            out.push(parse_edit(item(i)?, (s != NONE_I64).then_some(s), &ns)?);
        }
        at.set(from + n);
        Ok(out)
    };
    let mut out: Vec<Value> = Vec::with_capacity(groups.len());
    for g in &groups {
        let v = match g {
            Group::Edits { n } => {
                let edits = take(*n)?;
                entity_json(&Entity::build(&edits), None)
            }
            Group::Note { n, rec } => {
                let edits = take(*n)?;
                let ent = Entity::build(&edits);
                let payload = rec;
                let concurrent = ent.concurrent_with_delete();
                let view = note_view(&ent, &payload, &concurrent)?;
                entity_json(&ent, Some(view))
            }
            Group::NoteType { n, rec, b } => {
                let edits = take(*n)?;
                let ent = Entity::build(&edits);
                let payload = rec;
                let view = note_type_view(&ent, &payload, b)?;
                entity_json(&ent, Some(view))
            }
            Group::Deck { n, rec } => {
                let edits = take(*n)?;
                let ent = Entity::build(&edits);
                let payload = rec;
                let view = deck_view(&ent, &payload)?;
                entity_json(&ent, Some(view))
            }
            Group::Cards { cards, want } => {
                let total: usize = cards.iter().map(|(_, n)| n).sum();
                let edits = take(total)?;
                cards_group(&edits, cards, want)?
            }
            Group::Land { n, e } => {
                if e > n {
                    return Err("bad land group".to_owned());
                }
                let edits = take(*n)?;
                land(&edits, *e)
            }
            Group::Same => {
                // `same` 组的两项是值本身，不走修改记录解析。
                let from = at.get();
                if from + 2 > n_items {
                    return Err("register batch is shorter than its header".to_owned());
                }
                let a: Value =
                    serde_json::from_str(item(from)?).map_err(|e| format!("bad value: {e}"))?;
                let b: Value =
                    serde_json::from_str(item(from + 1)?).map_err(|e| format!("bad value: {e}"))?;
                at.set(from + 2);
                Value::Bool(same_value(&a, &b))
            }
        };
        out.push(v);
    }
    if at.get() != n_items {
        return Err("register batch is longer than its header".to_owned());
    }
    serde_json::to_vec(&Value::Array(out)).map_err(|e| e.to_string())
}

fn entity_json(ent: &Entity<'_, '_>, view: Option<Value>) -> Value {
    let mut m = Map::new();
    m.insert("r".to_owned(), ent.registers_json());
    m.insert("d".to_owned(), json!(ent.deleted_at()));
    m.insert("x".to_owned(), json!(ent.concurrent_with_delete()));
    if let Some(v) = view {
        m.insert("v".to_owned(), v);
    }
    Value::Object(m)
}

// ---------------------------------------------------------------- crate 内部入口（同步 v2，sync2）

/// 一条落库修改记录（JSON 原文 + S(e)）。
pub(crate) type StoredEdit<'a> = (&'a str, Option<i64>);

fn parse_stored<'a>(edits: &[StoredEdit<'a>]) -> Result<Vec<Edit<'a>>, String> {
    let ns = uuid_bytes(SRS_NAMESPACE);
    edits.iter().map(|(j, s)| parse_edit(j, *s, &ns)).collect()
}

/// 落库裁剪（[land]，与 `materialize` 的 `land` 组同一个判据）：前 [existing] 条是已有的，其余依次到达。
/// 返回每条到达的落不落、以及删掉了谁（下标指向全部项）。
pub(crate) fn land_stored(edits: &[StoredEdit<'_>], existing: usize) -> Result<(Vec<bool>, Vec<Vec<usize>>), String> {
    let parsed = parse_stored(edits)?;
    let v = land(&parsed, existing);
    let landed = v["l"].as_array().map(|a| a.iter().map(|x| x.as_u64() == Some(1)).collect()).unwrap_or_default();
    let deleted = v["d"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|d| d.as_array().map(|x| x.iter().filter_map(|i| i.as_u64().map(|i| i as usize)).collect()).unwrap_or_default())
                .collect()
        })
        .unwrap_or_default();
    Ok((landed, deleted))
}

/// 牌组的物化视图（与 `materialize` 的 `deck` 组同一份，键见 [deck_view]）。
pub(crate) fn deck_view_of(payload: &Value, edits: &[StoredEdit<'_>]) -> Result<Value, String> {
    let parsed = parse_stored(edits)?;
    let ent = Entity::build(&parsed);
    deck_view(&ent, payload)
}

/// 某实体某字段键的生效值（多值寄存器按读路径的规则取胜者；没有记录 = null）。
pub(crate) fn register_value(edits: &[StoredEdit<'_>], key: &str) -> Result<Value, String> {
    let parsed = parse_stored(edits)?;
    let ent = Entity::build(&parsed);
    Ok(ent.value(key).clone())
}

/// 一组卡的血统与标志（与 `materialize` 的 `cards` 组同一份）：[cards] 是 (卡 ID, 它的修改记录)，
/// [want] 是 (卡 ID, 笔记首选牌组, 默认牌组)。返回每个 want 的 (血统, 标志 JSON)。
pub(crate) fn card_lineage_flags(
    cards: &[(String, Vec<StoredEdit<'_>>)],
    want: &[(String, Option<String>, String)],
) -> Result<Vec<(Vec<String>, Value)>, String> {
    let mut all: Vec<StoredEdit<'_>> = Vec::new();
    let mut counts: Vec<(String, usize)> = Vec::with_capacity(cards.len());
    for (id, es) in cards {
        all.extend_from_slice(es);
        counts.push((id.clone(), es.len()));
    }
    let parsed = parse_stored(&all)?;
    let v = cards_group(&parsed, &counts, want)?;
    let mut out = Vec::with_capacity(want.len());
    for w in v["w"].as_array().cloned().unwrap_or_default() {
        let lineage = w["l"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_owned)).collect()).unwrap_or_default();
        out.push((lineage, w["f"].clone()));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_v5_matches_dart_field_edit_id() {
        // Dart: SrsIds.fieldEdit('A', 1)。
        let ns = uuid_bytes(SRS_NAMESPACE);
        let id = uuid_v5(&ns, "edit/A/1");
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "5");
    }

    #[test]
    fn canonical_eq_distinguishes_int_float_and_signed_zero() {
        let v = |s: &str| serde_json::from_str::<Value>(s).unwrap();
        assert!(!same_value(&v("1"), &v("1.0")));
        assert!(!same_value(&v("-0.0"), &v("0.0")));
        assert!(same_value(&v(r#"{"a":1,"b":2}"#), &v(r#"{"b":2,"a":1}"#)));
        assert!(same_value(&v("0.1"), &v("0.10")));
    }
}
