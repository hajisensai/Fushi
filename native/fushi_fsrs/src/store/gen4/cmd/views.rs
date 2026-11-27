//! `entity_views`（规划 §1.1 缺口 G-7，归 G7-4；§1.8 远程复习 V2 的实体格式 `{id, tag, v}`）：每个实体一份视图 JSON，
//! 本机 `SrsDbStore` 与远程复习的客户端用**同一个解码器**读它，主机算好的东西原样搬过去（D31：新代的胜者与状态由全量
//! 操作、依赖与主机的信任状态决定，客户端算不出来）。
//!
//! # 视图（一个别名类一份，规范 JSON 文本 = `store/sync2` 的 `canonical`，键有序、紧凑）
//!
//! ```text
//! {"id": 规范 ID, "k": 种类,
//!  "d": 身份记录的数据（类的定义，嵌的 ID 已归一；没有 = null）,
//!  "edits": [[修改行 JSON, 服务器时刻 | null], …]   按类判定活着的写入，按 (键, JSON) 排（同 `read` 的 `edits`，含合成 `tags` 行）,
//!  "tags": [标签, …]                                  只有笔记：标签 OR-Set 的当前值（按类并起来判）,
//!  "logs": [[日志行 JSON, 服务器时刻 | null], …]     只有卡：每个规范日志 ID 一条代表，按 (发生时刻, 操作主键),
//!  "row": 缓存行（列名 → 值，ID 列是文本）| null      只有笔记 / 卡：`notes` / `cards` 那一行（没物化 = null）}
//! ```
//!
//! 行 JSON 与 `read` 的 `edits` / `logs` 逐字相同（同一份拼法，`p` = 集合绑定的 profile uid）。
//!
//! # tag
//!
//! `tag` = 视图 JSON 字节的 blake3 前 16 字节（hex）。规划 §1.8 原写「取 `dg_ix`」，没照做：语义摘要按**原值**实体一行，
//! 不覆盖缓存行（配置、笔记类型变了它不变）、不覆盖别名类成员的进出，拿它当「视图没变」的凭据，客户端会留着旧视图——
//! 用户看到的是旧数据。按视图本身算，视图一变 tag 必变；代价是取 tag 也要拼一次视图（远程复习按批取，量小）。
//!
//! 不存在的实体（没有定义、没有活着的写入、没有日志、没有缓存行）不出现在结果里；请求里同一个类的多个成员只出一份，
//! 按请求里第一次出现的顺序。
//!
//! # 线上形状（分发器 `entity_views` 臂，G10-2 定案）
//!
//! ```text
//! 请求 {op: "entity_views", profile, kind: 种类线名（note / notetype / deck / card …）, ids: [ID, …]}
//! 回包 {}，外加一个文件 `t`：列式表（`store/bulk.rs`，与 `read` 同一种），列 `id`（规范 ID）、`tag`、`v`（视图 JSON 文本）
//! ```
//!
//! - 一条命令一个读快照（分发器 `read_col` 把集合号换算与本体放进同一个快照，[entity_views] 自己的快照沿用它）。
//! - `ids` 必给、一次最多 `identity::LOOKUP_MAX` 条（与 `canonical_ids` 同一上限，超了明确报错，调用方分批）：整个集合的
//!   视图一次拼完会长时间占着读连接。
//! - `v` 是视图的规范 JSON **文本**（不是对象）：`tag` 按这串字节算，原样搬给远程复习的客户端，对端可以按同一份字节
//!   核对，不经过任何一侧的再编码。
//! - 视图走列式表的字符串列（原样字节），**不**套进回包 JSON：视图里的修改行本身是 JSON 字符串，字段正文里的每个 `"`
//!   在视图里已转义一层，再当字符串放进回包要再转义一层（一个引号 7 个字节），回包比视图大几倍，宿主还要整个
//!   `jsonDecode` 一遍、跨 isolate 拷一遍——大字段的库（Yomitan 释义 HTML 每个字段几十 KB）一批 4096 条笔记的回包
//!   数百 MB，Dart 侧比拼视图本身慢一个数量级（BUG-5572）。
//! - 种类不认识、`ids` 不是字符串数组一律报错，不回空结果（空结果会被当成「这些实体不存在」）。

use rusqlite::types::ValueRef;
use serde_json::{Map, Value, json};

use super::identity::lookup_cap;
use super::{Cell, Files, Table, canon_ids, edit_rows, profile_of, snapshot, with_profile};
use crate::store::bulk::KIND_STR;
use crate::store::gen4::derive::{Index, Ref};
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::Truth;
use crate::store::sync2::canonical;
use crate::sync2::op::EntKind;

/// 一个实体的视图。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EntityView {
    /// 规范 ID（文本）。
    pub id: String,
    /// 视图 JSON 的 blake3 前 16 字节（hex，模块文件头「tag」）。
    pub tag: String,
    /// 视图（规范 JSON 文本）。
    pub json: String,
}

/// `entity_views {kind, ids}` 的命令外壳（模块文件头「线上形状」）：视图放进 [files] 的列式表 `t`，回包 JSON 是空对象。
pub fn entity_views_cmd(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    files: &mut Files,
) -> Result<Value, String> {
    let kind = req
        .get("kind")
        .and_then(Value::as_str)
        .ok_or("entity_views: missing kind")?;
    let kind = EntKind::parse(kind).ok_or_else(|| format!("entity_views: unknown kind {kind}"))?;
    let ids = req
        .get("ids")
        .and_then(Value::as_array)
        .ok_or("entity_views: ids must be an array")?;
    lookup_cap(ids.len(), "entity_views")?;
    let ids = ids
        .iter()
        .map(|x| {
            x.as_str()
                .map(str::to_owned)
                .ok_or("entity_views: ids must be strings")
        })
        .collect::<Result<Vec<_>, _>>()?;
    let views = entity_views(t, col, kind, &ids)?;
    let mut out = Table::new(&[("id", KIND_STR), ("tag", KIND_STR), ("v", KIND_STR)]);
    for v in views {
        out.push(vec![Cell::S(v.id), Cell::S(v.tag), Cell::S(v.json)])?;
    }
    files.push((VIEWS_TABLE.to_owned(), out.encode()));
    Ok(json!({}))
}

/// [entity_views_cmd] 交出的列式表的文件名（与 `read` 的同名）。
pub(crate) const VIEWS_TABLE: &str = "t";

/// 集合 [col] 里 [kind] 种实体 [ids]（任何别名成员的号都行）的视图。在一个读快照里（[snapshot]）。一次最多
/// `identity::LOOKUP_MAX` 条由命令外壳（[entity_views_cmd]）卡住。
pub fn entity_views(
    t: &Truth<'_>,
    col: i64,
    kind: EntKind,
    ids: &[String],
) -> Result<Vec<EntityView>, String> {
    snapshot(t, |t| {
        let profile = profile_of(t, col)?;
        let mut ix = Index::new(t, col);
        let ids = canon_ids(
            &ix,
            &Value::Array(ids.iter().cloned().map(Value::String).collect()),
        )?;
        let mut out = Vec::with_capacity(ids.len());
        ix.in_read_pass(|ix| {
            for c in ids {
                if let Some(v) = view(t, ix, col, kind, &c, &profile)? {
                    let json = canonical(&v);
                    let tag = super::hex(&blake3::hash(json.as_bytes()).as_bytes()[..16]);
                    out.push(EntityView {
                        id: c.text(),
                        tag,
                        json,
                    });
                }
            }
            Ok(())
        })?;
        Ok(out)
    })
}

/// 一个规范实体的视图；不存在 = None。
fn view(
    t: &Truth<'_>,
    ix: &mut Index<'_, '_>,
    col: i64,
    kind: EntKind,
    c: &Ref,
    profile: &str,
) -> Result<Option<Value>, String> {
    let d = match ix.definition(c)? {
        Some((k, _, d)) if k == kind as i64 => Some(d),
        _ => None,
    };
    let edits = edit_rows(t, ix, kind, c, profile)?;
    let mut m = Map::new();
    m.insert("id".into(), json!(c.text()));
    m.insert("k".into(), json!(kind.wire()));
    let mut any = d.is_some() || !edits.is_empty();
    m.insert("d".into(), d.unwrap_or(Value::Null));
    m.insert(
        "edits".into(),
        Value::Array(edits.into_iter().map(|(_, j, st)| json!([j, st])).collect()),
    );
    match kind {
        EntKind::Note => {
            let tags = ix.class_tags(c)?;
            any |= !tags.is_empty();
            m.insert("tags".into(), json!(tags));
            let row = cache_row(t, NOTE_ROW_SQL, col, c)?;
            any |= row.is_some();
            m.insert("row".into(), row.unwrap_or(Value::Null));
        }
        EntKind::Card => {
            let logs: Vec<Value> = ix
                .replayed_card_logs(c)?
                .into_iter()
                .map(|l| json!([with_profile(&l.json, profile), l.server_time]))
                .collect();
            any |= !logs.is_empty();
            m.insert("logs".into(), Value::Array(logs));
            let row = cache_row(t, CARD_ROW_SQL, col, c)?;
            any |= row.is_some();
            m.insert("row".into(), row.unwrap_or(Value::Null));
        }
        _ => {}
    }
    Ok(any.then_some(Value::Object(m)))
}

/// 笔记的缓存行（主键 `(col, id)` 点查；查询计划测试测的就是这一份，`cmd/views_tests.rs`）。
pub(crate) const NOTE_ROW_SQL: &str = "SELECT * FROM notes WHERE col = ?1 AND id = ?2";
/// 卡的缓存行（同 [NOTE_ROW_SQL]）。
pub(crate) const CARD_ROW_SQL: &str = "SELECT * FROM cards WHERE col = ?1 AND id = ?2";

/// 缓存表（[NOTE_ROW_SQL] / [CARD_ROW_SQL]）里 [c] 那一行：列名 → 值（`col` 不要；16 字节 ID 解回文本）。
fn cache_row(t: &Truth<'_>, q: &str, col: i64, c: &Ref) -> Result<Option<Value>, String> {
    let mut stmt = t.conn().prepare_cached(q).map_err(sql)?;
    let names: Vec<String> = stmt.column_names().into_iter().map(str::to_owned).collect();
    let mut rows = stmt.query(rusqlite::params![col, c]).map_err(sql)?;
    let Some(r) = rows.next().map_err(sql)? else {
        return Ok(None);
    };
    let mut m = Map::new();
    for (i, name) in names.iter().enumerate() {
        if name == "col" {
            continue;
        }
        let v = match r.get_ref(i).map_err(sql)? {
            ValueRef::Null => Value::Null,
            ValueRef::Integer(x) => json!(x),
            ValueRef::Real(x) => json!(x),
            v @ (ValueRef::Text(_) | ValueRef::Blob(_)) => {
                crate::store::ids::text(v).map_or(Value::Null, Value::String)
            }
        };
        m.insert(name.clone(), v);
    }
    Ok(Some(Value::Object(m)))
}
