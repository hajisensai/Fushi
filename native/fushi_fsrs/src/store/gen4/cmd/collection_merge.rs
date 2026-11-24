//! 手动「合并进共享库」（拍板台 design-srs-shared-library 方案 a，组合阶段 5，设计
//! `docs/specs/2026-11-23-combo-settings-tree-design.md` §4.3）：把本机一个**独立复习库**（拆了 `srs.library = own` 的组合
//! 自己那份集合）整个并进**共享复习库**的集合。四条命令：
//!
//! | 命令 | 读 / 写 | 做什么 |
//! |---|---|---|
//! | `collection_merge_preview {from, into}` | 读快照 | 规模与冲突表：两边都有的笔记里笔记类型 / 删除状态 / 字段内容不同的 |
//! | `collection_merge {from, into, now, resolutions}` | 一个写事务 | 并入 + 按用户的选择写回冲突笔记 + 记墓碑 |
//! | `collection_merges` | 读快照 | 本机还没收尾的墓碑（app 侧还没把组合的 `srs.library` 恢复继承） |
//! | `collection_merge_done {from}` | 写本机状态 | 删墓碑 |
//!
//! # 并入怎么做（与 `profile_merge_commit` 同一条路）
//!
//! 新代的「两个集合是同一个库」本来就有表示：`into` 的日志里一条 `Join{from: 被并入的集合}`（种类 14，`identity.rs`
//! 文件头），被并入集合的操作原样归到 `into` 名下（操作号全局唯一）。所以一个事务里：
//!
//! 1. 先在两边都还在的时候算冲突（下一节），按 `resolutions` 定下每条冲突笔记要保留哪一边的内容；
//! 2. 把 `from` 的真相层导出成 `FSRS4EXP`（内存里）、记下它的公钥表，**丢掉** `from` 的集合（`discard.rs`），再方向
//!    固定地并进 `into`（`identity.rs` [absorb_foreign]：`into` 的日志里写 `Join{from}`，`into` 的集合标识与目录名绝不
//!    改变——共享库是别的设备在用的那份）；然后导入公钥与操作（`import.rs`，同 `.fushisrs` 导入同一条路）；
//! 3. 冲突笔记按选择写回（本机身份在 `into` 的日志里的普通修改，`chg` 筛掉值没变的）；
//! 4. 记墓碑 `collection_merged/<from>`、删 `from` 的本机状态行。
//!
//! 任何一步出错整笔回滚：`from` 的集合一行不少、没有 `Join`、没有墓碑。整笔在分发器的一个 `BEGIN IMMEDIATE` 写事务里，
//! `from` 的导出流整份在内存里——拆成多个事务会出现「`from` 已丢、`into` 只导入了一部分」的中间态（取舍同
//! `profile_merge_commit`，`cmd/profile_data.rs` 文件头）。所以没有逐步的进度事件：Dart 侧显示不定进度。
//!
//! **同步**：`Join` 与导入的操作都在 `into` 的集合里，按普通的同步轮次发布到 `into` 的位置；对端收段后按操作重放（并集
//! 收敛、与到达顺序无关），不靠整库覆盖。写回冲突的修改是本机身份在 `into` 里的普通修改，同样随同步走。
//!
//! # 同 guid 的笔记怎么合（设计 §4.3）
//!
//! ID 不加盐、内容寻址（笔记 `v5(NS, note/<guid>)`），两个库里同 guid 的笔记就是同一个实体，并入后合成一份：
//!
//! - **复习状态**：卡的排程只来自日志（`cache.rs`），并集之后两边的复习日志**全部保留**（按操作号去重），按 HLC 排序
//!   重放——结果就是「按最后复习时间取较新」的状态，且不丢任何一次复习。
//! - **标签**：OR-Set，并集 = 两边标签都在，不算冲突。
//! - **字段 / 笔记类型 / 删除状态**：寄存器按 HLC 取较新，可两边是各自改的内容，较新不代表用户要的那份。所以并入**之前**
//!   两边各读一遍现值（[note_side]），不同的列进冲突表让用户逐条选；没选的默认保留共享库那份（设计 §4.3）。并入之后按
//!   选的那一边把这几个键写回（[reassert]）：值已经是选的那份的（并集里它本来就较新）`chg` 筛掉、不写。
//!   选了另一边的笔记类型时只写类型键与那一边的字段，不搬卡：另一个类型的卡与它们的复习日志留在日志里（换回那个类型就回来），
//!   与「更改笔记类型」不带映射时同口径。
//! - 两边都已删除的笔记不算冲突（内容不显示）。
//!
//! # 墓碑（`collection_merged/<from>`，值 `{"into", "at", "collection"}`）
//!
//! 内核提交之后，app 还要在主库里把这个组合的 `srs.library` 恢复继承（组合行在 Drift 里，不在这个事务里）。两步之间
//! 进程被杀时，主库还说「这个组合有独立库」，打开它会按 `identity` 给它的 uid 建一个空集合——数据没丢（都在共享库里），
//! 但看上去独立库空了。墓碑把「内核这一半已经做完」留在库里：app 每次进配置管理页（与无主数据扫描同一处）读
//! `collection_merges`，对还记着的组合补做恢复继承，再 `collection_merge_done` 删墓碑。墓碑只记 uid，没有引用任何集合
//! 数据；`from` 的 profile 之后被删也只是多一行，下次收尾时删掉。
//!
//! # 查询
//!
//! 共有笔记 [SHARED_NOTES_SQL]：`from` 的 `notes` 按主键前缀 `col` 扫、`into` 按主键点查。墓碑 [MERGED_MARKS_SQL]：
//! `srs_meta` 主键区间。执行计划测试 `collection_merge_statements_use_their_keys`。

use std::collections::{BTreeMap, BTreeSet, HashMap};

use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

use super::identity::{Emitting, identity_ensure, outcome_json};
use super::snapshot;
use super::writes::{ApplyOpts, Origin, apply_in, draft, write};
use crate::store::gen4::derive::{Index, Ref};
use crate::store::gen4::discard::discard_collection;
use crate::store::gen4::export::export_ops;
use crate::store::gen4::identity::{BindingChanged, Foreign, absorb_foreign};
use crate::store::gen4::import::{import_ops, import_peers};
use crate::store::gen4::local::KEY_PREFIX as LOCAL_STATE_PREFIX;
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::{Binding, Truth};
use crate::sync2::op::EntKind;

/// 墓碑的键前缀（模块文件头「墓碑」）。
pub const MERGED_PREFIX: &str = "collection_merged/";

/// 本机还没收尾的墓碑（主键区间：`/` 的下一个字符是 `0`）。
pub(crate) const MERGED_MARKS_SQL: &str = "SELECT key, value FROM srs_meta \
     WHERE key >= 'collection_merged/' AND key < 'collection_merged0' ORDER BY key";

/// 两个集合都有的笔记（缓存层）：?1 = `from`，?2 = `into`。
pub(crate) const SHARED_NOTES_SQL: &str = "SELECT a.id, a.guid, a.note_type_id, a.deleted_at, a.sort_field, a.updated_at, \
     b.note_type_id, b.deleted_at, b.sort_field, b.updated_at \
     FROM notes a JOIN notes b ON b.col = ?2 AND b.id = a.id WHERE a.col = ?1 ORDER BY a.id";

/// 冲突表里一个字段值最多带多少个字符（确认框只要认得出是哪份，不用整段正文）。
const PREVIEW_CHARS: usize = 300;

/// 笔记寄存器的键。
const KEY_NOTE_TYPE: &str = "noteType";
const KEY_DELETED: &str = "deleted";
const FIELD_PREFIX: &str = "f/";

/// 「没写过的字段」的值（规范 JSON 文本）：与写成空串同义。
const EMPTY_FIELD: &str = "\"\"";

/// 冲突的一边：并入之前这个集合里这条笔记的现值。
#[derive(Clone, Debug)]
struct Side {
    /// 当前笔记类型（缓存层：有 `noteType` 修改取它，否则身份记录里的创建类型）。
    note_type: String,
    deleted: bool,
    /// `deleted` 寄存器的胜者（规范 JSON 文本）；没写过 = None。
    deleted_value: Option<String>,
    sort: String,
    updated: i64,
    /// 字段寄存器的胜者：规范键（`f/<字段>`）→ 规范 JSON 文本。
    fields: BTreeMap<String, String>,
}

/// 一条冲突笔记。
#[derive(Clone, Debug)]
struct Conflict {
    note: String,
    guid: String,
    into: Side,
    from: Side,
    type_differs: bool,
    deleted_differs: bool,
    /// 值不同的字段键（升序）。
    fields: Vec<String>,
}

/// 两个集合的规模与冲突（[scan]）。
struct Scan {
    shared: i64,
    conflicts: Vec<Conflict>,
}

fn uid_of<'r>(req: &'r Value, key: &str, op: &str) -> Result<&'r str, String> {
    req.get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| format!("{op}: missing {key}"))
}

/// 请求里的 `from` / `into`：两个不同的 uid。
fn endpoints<'r>(req: &'r Value, op: &str) -> Result<(&'r str, &'r str), String> {
    let (from, into) = (uid_of(req, "from", op)?, uid_of(req, "into", op)?);
    if from == into {
        return Err(format!("{op}: from and into are the same uid"));
    }
    Ok((from, into))
}

/// 一条笔记在 [ix] 那个集合里的寄存器现值（类读，别名归一）：`deleted` 与字段。
fn registers(
    ix: &mut Index<'_, '_>,
    note: &Ref,
) -> Result<(Option<String>, BTreeMap<String, String>), String> {
    let mut deleted = None;
    let mut fields = BTreeMap::new();
    for w in ix.class_winners(EntKind::Note, note)? {
        if w.key == KEY_DELETED {
            deleted = Some(w.value);
        } else if w.key.starts_with(FIELD_PREFIX) {
            fields.insert(w.key, w.value);
        }
    }
    Ok((deleted, fields))
}

fn field_or_empty<'a>(m: &'a BTreeMap<String, String>, k: &str) -> &'a str {
    m.get(k).map_or(EMPTY_FIELD, String::as_str)
}

/// 两个集合（`from` 的集合号 [a]、`into` 的 [b]）都有的笔记里，内容不同的（模块文件头「同 guid 的笔记怎么合」）。读，
/// 调用方给快照或事务。
fn scan(t: &Truth<'_>, a: i64, b: i64) -> Result<Scan, String> {
    struct Row {
        id: Ref,
        guid: String,
        a: (Ref, Option<i64>, String, i64),
        b: (Ref, Option<i64>, String, i64),
    }
    let rows: Vec<Row> = {
        let mut stmt = t.conn().prepare_cached(SHARED_NOTES_SQL).map_err(sql)?;
        let it = stmt
            .query_map(params![a, b], |r| {
                Ok(Row {
                    id: r.get(0)?,
                    guid: r.get(1)?,
                    a: (r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?),
                    b: (r.get(6)?, r.get(7)?, r.get(8)?, r.get(9)?),
                })
            })
            .map_err(sql)?;
        it.collect::<Result<_, _>>().map_err(sql)?
    };
    let shared = rows.len() as i64;
    let mut ia = Index::new(t, a);
    let mut ib = Index::new(t, b);
    let mut conflicts = Vec::new();
    for row in rows {
        let (a_del, b_del) = (row.a.1.is_some(), row.b.1.is_some());
        if a_del && b_del {
            continue;
        }
        let type_differs = row.a.0 != row.b.0;
        let deleted_differs = a_del != b_del;
        let (a_dv, a_fields) = registers(&mut ia, &row.id)?;
        let (b_dv, b_fields) = registers(&mut ib, &row.id)?;
        let keys: BTreeSet<&String> = a_fields.keys().chain(b_fields.keys()).collect();
        let fields: Vec<String> = keys
            .into_iter()
            .filter(|k| field_or_empty(&a_fields, k) != field_or_empty(&b_fields, k))
            .cloned()
            .collect();
        if !type_differs && !deleted_differs && fields.is_empty() {
            continue;
        }
        let side = |c: (Ref, Option<i64>, String, i64),
                    dv: Option<String>,
                    fs: BTreeMap<String, String>| Side {
            note_type: c.0.text(),
            deleted: c.1.is_some(),
            deleted_value: dv,
            sort: c.2,
            updated: c.3,
            fields: fs,
        };
        conflicts.push(Conflict {
            note: row.id.text(),
            guid: row.guid,
            from: side(row.a, a_dv, a_fields),
            into: side(row.b, b_dv, b_fields),
            type_differs,
            deleted_differs,
            fields,
        });
    }
    Ok(Scan { shared, conflicts })
}

/// JSON 文本 → 给人看的短文本：字符串取它本身，其余原样；截到 [PREVIEW_CHARS] 个字符。
fn shown(text: &str) -> String {
    let s = match serde_json::from_str::<Value>(text) {
        Ok(Value::String(s)) => s,
        _ => text.to_owned(),
    };
    match s.char_indices().nth(PREVIEW_CHARS) {
        Some((at, _)) => format!("{}…", &s[..at]),
        None => s,
    }
}

/// 笔记类型 [nt] 在 [ix] 那个集合里的名字；字段 [key]（`f/<字段>`）在它里面的名字。读不到 = None。
fn type_name(ix: &mut Index<'_, '_>, nt: &str) -> Result<Option<String>, String> {
    Ok(ix
        .class_value(EntKind::NoteType, &super::ref_of(nt), "name")?
        .map(|v| shown(&v)))
}

fn field_name(ix: &mut Index<'_, '_>, nt: &str, key: &str) -> Result<Option<String>, String> {
    let Some(field) = key.strip_prefix(FIELD_PREFIX) else {
        return Ok(None);
    };
    let def = ix.class_value(
        EntKind::NoteType,
        &super::ref_of(nt),
        &format!("fieldDef/{field}"),
    )?;
    Ok(def
        .and_then(|v| serde_json::from_str::<Value>(&v).ok())
        .and_then(|v| v.get("name").and_then(Value::as_str).map(str::to_owned)))
}

fn side_json(ix: &mut Index<'_, '_>, s: &Side) -> Result<Value, String> {
    Ok(json!({
        "type": s.note_type,
        "typeName": type_name(ix, &s.note_type)?,
        "deleted": s.deleted,
        "sort": shown(&serde_json::to_string(&s.sort).map_err(|e| e.to_string())?),
        "updated": s.updated,
    }))
}

/// 冲突表（回包 `conflicts`）。名字按各自集合读：并入之前两边的笔记类型定义可以不同。
fn conflicts_json(t: &Truth<'_>, a: i64, b: i64, cs: &[Conflict]) -> Result<Value, String> {
    let mut ia = Index::new(t, a);
    let mut ib = Index::new(t, b);
    let mut out = Vec::with_capacity(cs.len());
    for c in cs {
        let mut fields = Vec::with_capacity(c.fields.len());
        for k in &c.fields {
            let name = match field_name(&mut ib, &c.into.note_type, k)? {
                Some(n) => Some(n),
                None => field_name(&mut ia, &c.from.note_type, k)?,
            };
            fields.push(json!({
                "field": &k[FIELD_PREFIX.len()..],
                "name": name,
                "into": shown(field_or_empty(&c.into.fields, k)),
                "from": shown(field_or_empty(&c.from.fields, k)),
            }));
        }
        out.push(json!({
            "note": c.note,
            "guid": c.guid,
            "newer": if c.from.updated > c.into.updated { "from" } else { "into" },
            "typeDiffers": c.type_differs,
            "deletedDiffers": c.deleted_differs,
            "into": side_json(&mut ib, &c.into)?,
            "from": side_json(&mut ia, &c.from)?,
            "fields": fields,
        }));
    }
    Ok(Value::Array(out))
}

fn bound(t: &Truth<'_>, uid: &str, op: &str) -> Result<Binding, String> {
    t.binding_of(uid)?
        .ok_or_else(|| format!("{op}: profile {uid} has no collection on this device"))
}

// ---------------------------------------------------------------------- 预览

/// `collection_merge_preview {from, into}` → `{bound, from: {notes, cards, reviews}, shared, added, conflicts}`。一个读
/// 快照。`from` 在本机没有集合 = `bound: false`、全 0（没有可并的东西，app 直接把组合恢复继承）。`into` 没有集合时冲突为空
/// （并入时按打开 profile 的口径建）。
pub fn collection_merge_preview(t: &Truth<'_>, req: &Value) -> Result<Value, String> {
    let (from, into) = endpoints(req, "collection_merge_preview")?;
    snapshot(t, |t| {
        let Some(src) = t.binding_of(from)? else {
            return Ok(json!({
                "bound": false,
                "from": {"notes": 0, "cards": 0, "reviews": 0},
                "shared": 0, "added": 0, "conflicts": [],
            }));
        };
        let size = super::profile::profile_footprint(t, src.col)?;
        let (shared, conflicts) = match t.binding_of(into)? {
            Some(dst) => {
                let s = scan(t, src.col, dst.col)?;
                (s.shared, conflicts_json(t, src.col, dst.col, &s.conflicts)?)
            }
            None => (0, json!([])),
        };
        let notes: i64 = t
            .conn()
            .prepare_cached("SELECT COUNT(*) FROM notes WHERE col = ?1")
            .map_err(sql)?
            .query_row([src.col], |r| r.get(0))
            .map_err(sql)?;
        Ok(json!({
            "bound": true,
            "from": {"notes": size["notes"], "cards": size["cards"], "reviews": size["reviews"]},
            "shared": shared,
            "added": notes - shared,
            "conflicts": conflicts,
        }))
    })
}

// ---------------------------------------------------------------------- 合并

/// 一条冲突笔记选了哪一边：`resolutions` 里写 `"from"` 的取被并入的库，其余（没写、`"into"`）保留共享库。
fn keeps_from(resolutions: &Value, note: &str) -> Result<bool, String> {
    match resolutions.get(note) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::String(s)) if s == "into" => Ok(false),
        Some(Value::String(s)) if s == "from" => Ok(true),
        Some(v) => Err(format!(
            "collection_merge: resolution for {note} must be \"from\" or \"into\", got {v}"
        )),
    }
}

/// 并入之后把冲突笔记写回选定的那一边（模块文件头「同 guid 的笔记怎么合」）：只写两边不同的键，`chg` 筛掉并集里已经是
/// 那个值的。回包 `(写回的笔记数, 取了被并入库的笔记数)`。
fn reassert(
    t: &Truth<'_>,
    col: i64,
    now: i64,
    chosen: &[(Conflict, bool)],
) -> Result<(i64, i64), String> {
    let mut written = 0i64;
    let from_count = chosen.iter().filter(|(_, f)| *f).count() as i64;
    if chosen.is_empty() {
        return Ok((0, 0));
    }
    write(t, col, |s| {
        let profile = s.profile.clone();
        let mut landed_notes = 0i64;
        for (c, from) in chosen {
            let pick = if *from { &c.from } else { &c.into };
            let mut items: Vec<Value> = Vec::new();
            let mut push = |key: &str, v: Value| {
                let mut d = draft(&profile, "note", &c.note, key, &v, "wall");
                d["chg"] = Value::Bool(true);
                items.push(d);
            };
            if c.type_differs {
                push(KEY_NOTE_TYPE, json!(pick.note_type));
            }
            if c.deleted_differs {
                let v = match (&pick.deleted_value, pick.deleted) {
                    (Some(text), true) => serde_json::from_str(text).map_err(|e| e.to_string())?,
                    // 缓存说删了却没有 `deleted` 胜者（不该出现）：按「现在删除」写。
                    (None, true) => json!(now),
                    (_, false) => Value::Null,
                };
                push(KEY_DELETED, v);
            }
            for k in &c.fields {
                let v: Value = serde_json::from_str(field_or_empty(&pick.fields, k))
                    .map_err(|e| e.to_string())?;
                push(k, v);
            }
            if items.is_empty() {
                continue;
            }
            let v = apply_in(
                s,
                now,
                &items,
                ApplyOpts {
                    chg: true,
                    compact: true,
                    origin: Origin::Synthesized,
                },
            )?;
            if v["landed"]
                .as_array()
                .is_some_and(|l| l.iter().any(|x| x == &Value::Bool(true)))
            {
                landed_notes += 1;
            }
            if !v["foreign"].as_array().is_none_or(Vec::is_empty) {
                return Err(format!(
                    "collection_merge: writing back note {} was refused by the ownership gate",
                    c.note
                ));
            }
        }
        written = landed_notes;
        Ok(json!({}))
    })?;
    Ok((written, from_count))
}

/// `collection_merge {from, into, now, resolutions}`（模块文件头「并入怎么做」）。回包 `{merged, outcome?, applied?,
/// conflicts, rewritten, keptFrom}` + 分发器加的 `bindingChanged`（`into` 的绑定）。`from` 在本机没有集合：`merged: false`，
/// 什么都不写（没有墓碑：app 直接恢复继承）。
pub fn collection_merge(t: &Truth<'_>, req: &Value) -> Result<Emitting, String> {
    const OP: &str = "collection_merge";
    let (from, into) = endpoints(req, OP)?;
    let now = req
        .get("now")
        .and_then(Value::as_i64)
        .ok_or("collection_merge: missing now")?;
    let resolutions = match req.get("resolutions") {
        None | Some(Value::Null) => json!({}),
        Some(v @ Value::Object(_)) => v.clone(),
        Some(v) => return Err(format!("{OP}: resolutions must be an object, got {v}")),
    };
    let Some(src) = t.binding_of(from)? else {
        return Ok((json!({"merged": false}), None));
    };
    // `into` 没绑定 / 没有本机身份就按打开 profile 的口径建（同 `profile_merge_commit`），已有的不动。
    identity_ensure(t, into, now)?;
    let dst = bound(t, into, OP)?;
    let chosen: Vec<(Conflict, bool)> = scan(t, src.col, dst.col)?
        .conflicts
        .into_iter()
        .map(|c| {
            let f = keeps_from(&resolutions, &c.note)?;
            Ok((c, f))
        })
        .collect::<Result<_, String>>()?;
    // 用户选的笔记必须是此刻的冲突之一（预览之后两边又变了：多出来的冲突按默认保留共享库，消失的选不到——但拿着一个
    // 根本不在两边的笔记 ID 来选是调用方的 bug）。
    if let Value::Object(m) = &resolutions {
        let known: HashMap<&str, ()> = chosen.iter().map(|(c, _)| (c.note.as_str(), ())).collect();
        for note in m.keys() {
            if !known.contains_key(note.as_str()) && !note_in(t, src.col, note)? {
                return Err(format!("{OP}: resolution for unknown note {note}"));
            }
        }
    }
    let (bytes, _) = export_ops(t, src.col, Vec::new())?;
    let peers = super::profile_data::peers_of(t, src.col)?;
    discard_collection(t, src.col)?;
    let foreign = Foreign {
        collection: src.collection,
        dir: src.dir.clone(),
        salts: src.salts.clone(),
    };
    let out = absorb_foreign(t, into, &foreign, now)?;
    import_peers(t, dst.col, peers)?;
    let got = import_ops(t, dst.col, &bytes)?;
    let (rewritten, kept_from) = reassert(t, dst.col, now, &chosen)?;
    let mark = json!({"into": into, "at": now, "collection": src.collection.text()});
    t.conn()
        .prepare_cached(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        )
        .map_err(sql)?
        .execute(params![format!("{MERGED_PREFIX}{from}"), mark.to_string()])
        .map_err(sql)?;
    t.conn()
        .prepare_cached("DELETE FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .execute([[LOCAL_STATE_PREFIX, from].concat()])
        .map_err(sql)?;
    let v = json!({
        "merged": true,
        "outcome": outcome_json(&out)["outcome"].clone(),
        "applied": got.native_landed + got.voids_landed + got.slots_inserted,
        "conflicts": chosen.len(),
        "rewritten": rewritten,
        "keptFrom": kept_from,
    });
    Ok((
        v,
        Some(BindingChanged {
            profile: into.to_owned(),
            col: dst.col,
        }),
    ))
}

/// 笔记 [note] 在集合 [col] 的缓存层里有没有（[collection_merge] 核对 `resolutions` 用）。
fn note_in(t: &Truth<'_>, col: i64, note: &str) -> Result<bool, String> {
    Ok(t.conn()
        .prepare_cached("SELECT 1 FROM notes WHERE col = ?1 AND id = ?2")
        .map_err(sql)?
        .query_row(params![col, super::ref_of(note)], |_| Ok(()))
        .optional()
        .map_err(sql)?
        .is_some())
}

// ---------------------------------------------------------------------- 墓碑

/// `collection_merges` → `{merges: [{from, into, at, collection}]}`（按 `from` 升序）。一个读快照。值读不懂的照样列出
/// （`into` 为 null），app 照样能收尾删掉它。
pub fn collection_merges(t: &Truth<'_>) -> Result<Value, String> {
    snapshot(t, |t| {
        let mut stmt = t.conn().prepare_cached(MERGED_MARKS_SQL).map_err(sql)?;
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
            .map_err(sql)?;
        let mut out = Vec::new();
        for row in rows {
            let (key, value) = row.map_err(sql)?;
            let v: Value = serde_json::from_str(&value).unwrap_or(Value::Null);
            out.push(json!({
                "from": &key[MERGED_PREFIX.len()..],
                "into": v.get("into").cloned().unwrap_or(Value::Null),
                "at": v.get("at").cloned().unwrap_or(Value::Null),
                "collection": v.get("collection").cloned().unwrap_or(Value::Null),
            }));
        }
        Ok(json!({"merges": out}))
    })
}

/// `collection_merge_done {from}` → `{cleared}`：删墓碑（app 已把组合恢复继承）。没有也不报错。
pub fn collection_merge_done(t: &Truth<'_>, req: &Value) -> Result<Value, String> {
    let from = uid_of(req, "from", "collection_merge_done")?;
    let n = t
        .conn()
        .prepare_cached("DELETE FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .execute([format!("{MERGED_PREFIX}{from}")])
        .map_err(sql)?;
    Ok(json!({"cleared": n}))
}

#[cfg(test)]
#[path = "collection_merge_tests.rs"]
mod tests;
