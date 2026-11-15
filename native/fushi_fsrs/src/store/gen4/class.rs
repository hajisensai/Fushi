//! 读侧按别名类判定（设计 §5.3「一个寄存器的写入按实体的整个别名类归并」，G9-1）。[Index] 的一部分，**只读**：
//! 索引表（`reg_ix`、`tag_ix`）照旧存操作体里的原值 ID、按原值实体各判各的（`derive.rs` / `weigh.rs`），这里在读的
//! 时候把一个别名类的全部成员并起来，用**同一个**冻结判据（`crate::registers::judge_register`，拼行在
//! [Index::edit_lines_as]）再判一次。没有调用方：缓存层（`cache.rs`）接到这里是 G9-2，写命令按规范 ID 写是 G7-3b。
//!
//! # 并起来的是什么
//!
//! - **寄存器**（[Index::class_winners] / [Index::class_value]）：类内每个成员在 `reg_ix` 里的行，修改键先过
//!   [Index::canonical_key]（键里嵌的 `f/` `fieldDef/` `tmplDef/` `historyFrom/` `fieldDesc/` ID 换成规范 ID），规范键
//!   相同的是同一个寄存器。拼行时三处写入者一起换成规范写入者（[Index::canonical_writer]：dot 的写入者、HLC 的写入者、
//!   旧上下文的键，设计 §5.3「改名的写入者」），换完同一个 dot 的并成一次写入（代表取操作号最小的，与原值判定里
//!   「同一条旧修改被迁了两遍」同一个规则）；实体换成规范 ID，值里嵌的 ID 归一（[Index::canonical_value]）后再比
//!   「值相同」——否则两个成员各写了一个「指向同一个牌组的不同别名」会被判成冲突。
//! - **标签**（[Index::class_tags]）：类内成员的 `tag_ix` 行并起来，按 OR-Set 与顺序提示重判（`weigh.rs`
//!   [Index::tag_states]，同一份规则）：一个成员上的删除见过另一个成员上的添加，就抹掉它。
//! - 只有一个成员（从没并入过的存量集合里的绝大多数实体）**且寄存器里没有归回的改名写入者**时，结果与原值读接口
//!   相同（[Index::value]、[Index::tags_of]）。写入者归回对单成员实体同样生效：旧上下文写的是改名后的名字时，按类判
//!   可以把原值判下的冲突判成支配（样本库 144 处都是这一种）。所以**不能**按「只有一个成员就沿用 `reg_ix` 状态」
//!   走捷径；两种情形各有测试钉住（`a_class_of_one_reads_the_same_as_the_raw_id`、
//!   `a_renamed_writer_on_a_class_of_one_is_not_the_raw_reading`）。
//!
//! # 没有并起来的（按原值实体，留在索引层）
//!
//! 负状态是索引层按原值实体判的，这里原样拿来：已清除（[super::weigh::S_PURGED]：Purge 点名的是原值实体，清的是
//! 「作者没见过它」的、这个原值实体上的操作）、扣住的删除（[super::weigh::S_HELD]）、作者不可信（
//! [super::weigh::S_DISTRUSTED]）。一条 Purge 要不要清掉整个类、一条删除的扣住要不要看全类的并发操作，是 G9-2 /
//! G7 接线时随缓存层一起定的事（设计 §10 第 19 条同源）；在那之前，按类读与按原值读对这三种状态口径相同。
//!
//! # 内嵌的 ID（设计 §5.3「内嵌的 ID 同样过别名表」）
//!
//! 只认规范形状的 UUID 文本（`gen4_ids::alias::strict_id`）；别的写法没有别名，原样。哪些位置嵌着 ID 只在这里写一次：
//!
//! - 修改值（[Index::canonical_value]，按修改键）：值本身是 ID 的键 [ID_VALUED_KEYS]（笔记的 `noteType`、卡的 `deck`、
//!   牌组的 `parent`、笔记类型的 `termField` / `freqField`）；`tmplDef/<模板>` 的值里 `front` / `back` 两段模板文本中的
//!   `{{…fld:<字段>}}`（与 `card_cache.rs` 的 `ids_to_names` 同一个分词：注释、普通文本、`{{…}}` 里不是整段
//!   `fld:<UUID>` 的都不动）。别的值（字段内容等用户文本）一个字节不动。
//! - 整份 JSON（[Index::canonical_json]：身份记录的载荷、日志投影、修改行）：键在 [JSON_ID_KEYS] 里的字符串（或字符串
//!   数组）；`f` 当修改键；`front` / `back` 当模板文本；同一个对象里有 `f` 时 `v` 按那个键过 [Index::canonical_value]；
//!   其余递归。
//!
//! 语义摘要（`digest.rs`）按原值 ID 记、不过别名表（两台设备的别名表可以不同，摘要不能跟着不同），这里不碰。

use std::cell::RefCell;
use std::collections::BTreeMap;

use rusqlite::params;
use rusqlite::types::ValueRef;
use serde_json::{Map, Value};

use super::derive::{Index, R_CONFLICT, R_WINNER, Ref};
use super::schema::sql;
use crate::card_cache::ids_to_names;
use crate::gen4::name::read_edit_key;
use crate::gen4::stamp::StampHlc;
use crate::gen4_ids::alias::strict_id;
use crate::sync2::codec::Reader;
use crate::sync2::dvv::Dvv;
use crate::sync2::op::EntKind;
use crate::sync2::vv::OpId;

/// 值本身是一个 ID 的修改键（[Index::canonical_value]）。
pub const ID_VALUED_KEYS: [&str; 5] = ["noteType", "deck", "parent", "termField", "freqField"];

/// 整份 JSON 里值是 ID（或 ID 数组）的键（[Index::canonical_json]）：实体与日志的 `id`、修改行的 `e`、日志的 `card` /
/// `note` / `revokes`、笔记载荷的 `noteTypeId`、牌组 / 笔记类型 / 父牌组、词条与词频字段（含内置默认定义里的
/// `…FieldId`）。
pub const JSON_ID_KEYS: [&str; 14] = [
    "id",
    "e",
    "card",
    "note",
    "revokes",
    "deck",
    "deckId",
    "noteType",
    "noteTypeId",
    "parent",
    "termField",
    "freqField",
    "termFieldId",
    "freqFieldId",
];

/// 按类拼行要的换名（[Index::edit_lines_as]）：写入者表（只放规范名与原名不同的）、这个寄存器的规范实体与规范键。
pub(super) struct Canon<'a> {
    writers: &'a BTreeMap<String, String>,
    pub(super) entity: String,
    pub(super) key: String,
}

impl Canon<'_> {
    /// 规范写入者（表里没有 = 它自己）。
    pub(super) fn writer<'w>(&'w self, w: &'w str) -> &'w str {
        self.writers.get(w).map_or(w, String::as_str)
    }

    /// 旧上下文的键换成规范写入者：前缀取大、零散 dot 取并，再按 [Dvv::merge] 的规则收紧。
    pub(super) fn dvv(&self, d: &Dvv) -> Dvv {
        let renamed_any =
            d.vv.keys()
                .chain(d.cloud.keys())
                .any(|w| self.writers.contains_key(w));
        if !renamed_any {
            return d.clone();
        }
        let mut renamed = Dvv::default();
        for (w, &v) in &d.vv {
            let e = renamed.vv.entry(self.writer(w).to_owned()).or_insert(0);
            *e = (*e).max(v);
        }
        for (w, s) in &d.cloud {
            renamed
                .cloud
                .entry(self.writer(w).to_owned())
                .or_default()
                .extend(s.iter().copied());
        }
        let mut out = Dvv::default();
        out.merge(&renamed);
        out
    }

    /// HLC 里的写入者换成规范写入者（解不开的原样）。
    pub(super) fn hlc(&self, h: &StampHlc) -> StampHlc {
        match h {
            StampHlc::Parsed {
                physical,
                counter,
                writer,
            } => StampHlc::Parsed {
                physical: *physical,
                counter: *counter,
                writer: self.writer(writer).to_owned(),
            },
            StampHlc::Raw(_) => h.clone(),
        }
    }
}

/// 一个别名类里一个寄存器的胜者（[Index::class_winners]）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClassWinner {
    /// 规范键（[Index::canonical_key]）。
    pub key: String,
    /// 胜出的那条写入（同一个规范 dot 的取操作号最小的代表）。
    pub op: OpId,
    /// 生效值：规范 JSON 文本，嵌的 ID 已归一（[Index::canonical_value]）。
    pub value: String,
    /// 有值不同的并发写入。
    pub conflict: bool,
}

impl<'t, 'c> Index<'t, 'c> {
    /// 一个别名类全部寄存器的胜者，按规范键升序（文件头「寄存器」）。[canon] 可以是类里任何一个 ID。
    pub fn class_winners(
        &mut self,
        kind: EntKind,
        canon: &Ref,
    ) -> Result<Vec<ClassWinner>, String> {
        self.class_registers(kind, canon, None)
    }

    /// 一个别名类里一个寄存器（[canon_key] 是规范键）的生效值；没有写入 = None。
    pub fn class_value(
        &mut self,
        kind: EntKind,
        canon: &Ref,
        canon_key: &str,
    ) -> Result<Option<String>, String> {
        Ok(self
            .class_registers(kind, canon, Some(canon_key))?
            .into_iter()
            .next()
            .map(|w| w.value))
    }

    /// 一个别名类（笔记）现在的标签：类内成员的标签操作并起来重判（文件头「标签」），顺序规则同 [Index::tags_of]。
    pub fn class_tags(&mut self, canon: &Ref) -> Result<Vec<String>, String> {
        let members = self.members(canon)?;
        let mut rows = Vec::new();
        for m in &members {
            rows.extend(self.tags_rows(m)?);
        }
        if members.len() > 1 {
            rows.sort();
            rows.dedup();
            let want = self.tag_states(&rows)?;
            for (row, want) in rows.iter_mut().zip(want) {
                row.3 = want;
            }
        }
        self.current_tags(&rows)
    }

    /// 修改值里嵌的 ID 归一（文件头「内嵌的 ID」）。[key] 是修改键（原值或规范形都行，只看前缀与名字）。
    pub fn canonical_value(&self, key: &str, v: &Value) -> Result<Value, String> {
        if ID_VALUED_KEYS.contains(&key) {
            return Ok(match v {
                Value::String(s) => Value::String(self.canonical_text(s)?),
                _ => v.clone(),
            });
        }
        if key.starts_with("tmplDef/") {
            if let Value::Object(m) = v {
                let mut out = m.clone();
                for side in ["front", "back"] {
                    if let Some(Value::String(text)) = m.get(side) {
                        out.insert(
                            side.to_owned(),
                            Value::String(self.canonical_template(text)?),
                        );
                    }
                }
                return Ok(Value::Object(out));
            }
        }
        Ok(v.clone())
    }

    /// 整份 JSON 里嵌的 ID 归一（文件头「内嵌的 ID」）。
    pub fn canonical_json(&self, v: &Value) -> Result<Value, String> {
        Ok(match v {
            Value::Object(m) => {
                let edit_key = m.get("f").and_then(Value::as_str);
                let mut out = Map::new();
                for (k, x) in m {
                    let y = match (k.as_str(), x) {
                        (k, Value::String(s)) if JSON_ID_KEYS.contains(&k) => {
                            Value::String(self.canonical_text(s)?)
                        }
                        (k, Value::Array(xs))
                            if JSON_ID_KEYS.contains(&k) && xs.iter().all(Value::is_string) =>
                        {
                            let mut ys = Vec::with_capacity(xs.len());
                            for s in xs.iter().filter_map(Value::as_str) {
                                ys.push(Value::String(self.canonical_text(s)?));
                            }
                            Value::Array(ys)
                        }
                        ("f", Value::String(s)) => Value::String(self.canonical_key(s)?),
                        ("front" | "back", Value::String(s)) => {
                            Value::String(self.canonical_template(s)?)
                        }
                        ("v", x) if edit_key.is_some() => {
                            self.canonical_value(edit_key.unwrap_or_default(), x)?
                        }
                        (_, x) => self.canonical_json(x)?,
                    };
                    out.insert(k.clone(), y);
                }
                Value::Object(out)
            }
            Value::Array(xs) => {
                let mut ys = Vec::with_capacity(xs.len());
                for x in xs {
                    ys.push(self.canonical_json(x)?);
                }
                Value::Array(ys)
            }
            _ => v.clone(),
        })
    }

    // ------------------------------------------------------------ 内部

    /// 文本形式的 ID 的规范形：规范形状的 UUID 过别名表，别的原样。
    fn canonical_text(&self, s: &str) -> Result<String, String> {
        match strict_id(s) {
            Some(id) => Ok(self.canonical(&Ref::Uuid(id.0))?.text()),
            None => Ok(s.to_owned()),
        }
    }

    /// 模板文本里 `{{…fld:<UUID>}}` 的字段 ID 归一：分词与替换都走 `card_cache::ids_to_names`（模板渲染认字段引用的
    /// 那一份），只把规范形状的 UUID 换成规范 ID；注释、普通文本原样。
    fn canonical_template(&self, text: &str) -> Result<String, String> {
        let failed: RefCell<Option<String>> = RefCell::new(None);
        let out = ids_to_names(text, &|id| {
            let uuid = strict_id(id)?;
            match self.canonical(&Ref::Uuid(uuid.0)) {
                Ok(r) => Some(format!("fld:{}", r.text())),
                Err(e) => {
                    failed.borrow_mut().get_or_insert(e);
                    None
                }
            }
        });
        match failed.into_inner() {
            Some(e) => Err(e),
            None => Ok(out),
        }
    }

    /// 旧并入改名、已归回的写入者（`alias_writer_ix`）：原名 → 规范名。
    fn writer_aliases(&self) -> Result<BTreeMap<String, String>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached("SELECT name, origin FROM alias_writer_ix WHERE col = ?1")
            .map_err(sql)?;
        let rows = stmt
            .query_map([self.col], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    /// 类内全部成员的寄存器行按规范键成组再判；[only] = 只要这一个规范键。
    fn class_registers(
        &mut self,
        kind: EntKind,
        canon: &Ref,
        only: Option<&str>,
    ) -> Result<Vec<ClassWinner>, String> {
        let entity = self.canonical(canon)?.text();
        let mut groups: BTreeMap<String, Vec<(i64, i64)>> = BTreeMap::new();
        for m in self.members(canon)? {
            let rows: Vec<(Vec<u8>, i64, i64)> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT key, k, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, kind as i64, m], |r| {
                        let key = match r.get_ref(0)? {
                            ValueRef::Blob(b) => b.to_vec(),
                            _ => Vec::new(),
                        };
                        Ok((key, r.get(1)?, r.get(2)?))
                    })
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            for (key, k, state) in rows {
                let text = read_edit_key(&mut Reader::new(&key))
                    .map_err(|e| format!("gen4 index: bad register key: {e}"))?;
                let ck = self.canonical_key(&text)?;
                if only.is_some_and(|o| o != ck) {
                    continue;
                }
                groups.entry(ck).or_default().push((k, state));
            }
        }
        let writers = self.writer_aliases()?;
        let mut out = Vec::new();
        for (key, mut rows) in groups {
            rows.sort_unstable();
            let c = Canon {
                writers: &writers,
                entity: entity.clone(),
                key,
            };
            let (live, want) = self.judged(&rows, Some(&c))?;
            let Some((&(k, _), &state)) = live.iter().zip(&want).find(|&(_, &s)| s >= R_WINNER)
            else {
                continue;
            };
            let raw = self
                .t
                .edit_value(k)?
                .ok_or_else(|| format!("gen4 index: register row {k} has no edit"))?;
            let parsed: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
            let canonical = self.canonical_value(&c.key, &parsed)?;
            let value = if canonical == parsed {
                raw
            } else {
                canonical.to_string()
            };
            out.push(ClassWinner {
                key: c.key,
                op: self.t.id_of_key(k)?,
                value,
                conflict: state == R_CONFLICT,
            });
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::gen4::op::tests::{id, native_edit};
    use crate::gen4::op::{Body4, Edit4};
    use crate::gen4::stamp::HeritageStamp;
    use crate::gen4_ids::rules::{self, CANONICAL};
    use crate::store::gen4::derive::tests::{
        assert_rebuild_is_identity, heritage, native, op, stamp, with,
    };
    use crate::store::gen4::truth::Truth;
    use crate::sync2::id::{Id, Key};

    const U1: &str = "0192f0aa-0000-7000-8000-00000000000a";
    const U2: &str = "0192f0aa-0000-7000-8000-00000000000b";
    const GUID: &str = "guid-1";
    const ANKI_NT: i64 = 1_700_000_000_001;

    fn r(id: Id) -> Ref {
        Ref::Uuid(id.0)
    }

    fn entity(kind: EntKind, id: Id, data: Value) -> Body4 {
        Body4::Entity {
            kind,
            id: Key::Uuid(id),
            data: data.to_string(),
        }
    }

    fn edit(kind: EntKind, entity: Id, k: &str, value: Value) -> Body4 {
        Body4::Edit(Edit4 {
            kind,
            entity: Key::Uuid(entity),
            key: k.to_owned(),
            value: value.to_string(),
            ..native_edit()
        })
    }

    fn tag_add(note: Id, tag: &str) -> Body4 {
        Body4::TagAdd {
            note: Key::Uuid(note),
            tag: tag.to_owned(),
        }
    }

    fn tag_remove(note: Id, tag: &str) -> Body4 {
        Body4::TagRemove {
            note: Key::Uuid(note),
            tag: tag.to_owned(),
        }
    }

    /// 同一条笔记（同 guid）在两个盐下各一份：笔记类型、字段、模板、笔记都带盐。
    struct Twin {
        nt: [Id; 2],
        field: [Id; 2],
        tmpl: [Id; 2],
        note: [Id; 2],
        c_nt: Id,
        c_field: Id,
        c_tmpl: Id,
        c_note: Id,
    }

    fn twin() -> Twin {
        let nt = [
            rules::note_type(Some(U1), ANKI_NT),
            rules::note_type(Some(U2), ANKI_NT),
        ];
        let c_nt = rules::note_type(CANONICAL, ANKI_NT);
        Twin {
            nt,
            field: [rules::field(&nt[0], 0), rules::field(&nt[1], 0)],
            tmpl: [rules::template(&nt[0], 0), rules::template(&nt[1], 0)],
            note: [rules::note(Some(U1), GUID), rules::note(Some(U2), GUID)],
            c_nt,
            c_field: rules::field(&c_nt, 0),
            c_tmpl: rules::template(&c_nt, 0),
            c_note: rules::note(CANONICAL, GUID),
        }
    }

    /// 两份的身份与定义（盐 + 每份的笔记类型、字段定义、笔记）。
    fn twin_ops(w: &Twin) -> Vec<Body4> {
        let mut out = vec![Body4::salts([U1, U2]).unwrap()];
        for i in 0..2 {
            out.push(entity(
                EntKind::NoteType,
                w.nt[i],
                json!({"ankiNum": ANKI_NT}),
            ));
            out.push(edit(
                EntKind::NoteType,
                w.nt[i],
                &format!("fieldDef/{}", w.field[i].text()),
                json!({"ankiNum": 0, "name": "Front"}),
            ));
            out.push(entity(
                EntKind::Note,
                w.note[i],
                json!({"guid": GUID, "noteTypeId": w.nt[i].text()}),
            ));
        }
        out
    }

    fn feed(t: &Truth<'_>, ix: &mut Index<'_, '_>, col: i64, dev: u8, bodies: &[Body4]) {
        for (i, b) in bodies.iter().enumerate() {
            native(t, ix, col, &op(dev, i as u64 + 1, 100 + i as i64, &[], b));
        }
    }

    fn fkey(f: Id) -> String {
        format!("f/{}", f.text())
    }

    /// 从没并入过的实体：按类读与按原值读相同（寄存器胜者、冲突、标签）。
    #[test]
    fn a_class_of_one_reads_the_same_as_the_raw_id() {
        with(|t, col| {
            let note = id(3);
            let k = fkey(id(4));
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let a = edit(EntKind::Note, note, &k, json!("a"));
                let b = edit(EntKind::Note, note, &k, json!("b"));
                let due = edit(EntKind::Note, note, "due", json!(3));
                native(t, &mut ix, col, &op(0xa1, 1, 10, &[], &a));
                native(t, &mut ix, col, &op(0xa2, 1, 11, &[], &b));
                native(t, &mut ix, col, &op(0xa1, 2, 12, &[], &due));
                native(t, &mut ix, col, &op(0xa1, 3, 13, &[], &tag_add(note, "x")));
                ix.settle()?;
                let got = ix.class_winners(EntKind::Note, &r(note))?;
                assert_eq!(got.len(), 2);
                for w in &got {
                    let rows = ix.register(EntKind::Note, &Key::Uuid(note), &w.key)?;
                    let (op, state) = rows.iter().find(|(_, s)| *s >= R_WINNER).copied().unwrap();
                    assert_eq!(w.op, op);
                    assert_eq!(w.conflict, state == R_CONFLICT);
                    assert_eq!(
                        Some(w.value.clone()),
                        ix.value(EntKind::Note, &Key::Uuid(note), &w.key)?
                    );
                }
                assert!(got.iter().any(|w| w.key == k && w.conflict));
                assert_eq!(ix.class_tags(&r(note))?, ix.tags_of(&Key::Uuid(note))?);
                assert_eq!(ix.class_tags(&r(note))?, vec!["x".to_owned()]);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 同 guid 的两份带盐笔记：同一字段（键里嵌的字段 ID 也是两份）是一个寄存器，只有一个胜者；见过对方的写入
    /// 盖掉对方，互不相见、值不同才是冲突（§3.4 现规则）。按原值读两份各有一个胜者。
    #[test]
    fn two_salted_copies_of_a_note_are_one_register() {
        with(|t, col| {
            let w = twin();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                ix.settle()?;
                assert_eq!(ix.canonical(&r(w.note[0]))?, r(w.c_note));
                assert_eq!(ix.canonical(&r(w.note[1]))?, r(w.c_note));
                assert_eq!(ix.canonical_key(&fkey(w.field[1]))?, fkey(w.c_field));
                // 先后：0xb1 改第一份，0xb2 见过它之后改第二份。
                let old = edit(EntKind::Note, w.note[0], &fkey(w.field[0]), json!("old"));
                let new = edit(EntKind::Note, w.note[1], &fkey(w.field[1]), json!("new"));
                native(t, &mut ix, col, &op(0xb1, 1, 200, &[], &old));
                native(t, &mut ix, col, &op(0xb2, 1, 201, &[(0xb1, 1)], &new));
                ix.settle()?;
                for i in 0..2 {
                    let raw =
                        ix.register(EntKind::Note, &Key::Uuid(w.note[i]), &fkey(w.field[i]))?;
                    assert_eq!(raw.len(), 1);
                    assert_eq!(raw[0].1, R_WINNER);
                }
                let got = ix.class_winners(EntKind::Note, &r(w.note[0]))?;
                assert_eq!(got.len(), 1);
                assert_eq!(got[0].key, fkey(w.c_field));
                assert_eq!(got[0].value, "\"new\"");
                assert!(!got[0].conflict);
                assert_eq!(got, ix.class_winners(EntKind::Note, &r(w.c_note))?);
                assert_eq!(
                    ix.class_value(EntKind::Note, &r(w.note[1]), &fkey(w.c_field))?,
                    Some("\"new\"".to_owned())
                );
                // 并发：0xb3 见过 0xb1、没见过 0xb2，把第一份改成别的值 → 类里冲突。
                let other = edit(EntKind::Note, w.note[0], &fkey(w.field[0]), json!("other"));
                native(t, &mut ix, col, &op(0xb3, 1, 202, &[(0xb1, 1)], &other));
                ix.settle()?;
                let got = ix.class_winners(EntKind::Note, &r(w.note[1]))?;
                assert_eq!(got.len(), 1);
                assert!(got[0].conflict);
                // 原值读：第一份里 0xb3 盖掉 0xb1，没有冲突。
                let raw = ix.register(EntKind::Note, &Key::Uuid(w.note[0]), &fkey(w.field[0]))?;
                assert!(raw.iter().all(|(_, s)| *s != R_CONFLICT));
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 两份各写了一个「指向同一个笔记类型的不同别名」：值归一后相同，不算冲突。
    #[test]
    fn values_naming_one_entity_by_different_aliases_do_not_conflict() {
        with(|t, col| {
            let w = twin();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                let a = edit(EntKind::Note, w.note[0], "noteType", json!(w.nt[0].text()));
                let b = edit(EntKind::Note, w.note[1], "noteType", json!(w.nt[1].text()));
                native(t, &mut ix, col, &op(0xb1, 1, 200, &[], &a));
                native(t, &mut ix, col, &op(0xb2, 1, 201, &[], &b));
                ix.settle()?;
                let got = ix.class_winners(EntKind::Note, &r(w.c_note))?;
                assert_eq!(got.len(), 1);
                assert_eq!(got[0].key, "noteType");
                assert_eq!(got[0].value, json!(w.c_nt.text()).to_string());
                assert!(!got[0].conflict);
                Ok(())
            })
            .unwrap();
        });
    }

    /// 旧并入改名的写入者归回之后三处一起换：(w1, 2) 的旧上下文写的是改名后的名字，归一后它见过 (w1, 1)，没有
    /// 冲突；按原值判，(w1, 1) 与它并发、值不同 = 冲突。实体从没并入过（类里只有它自己）——单成员也不等于原值读。
    #[test]
    fn a_renamed_writer_on_a_class_of_one_is_not_the_raw_reading() {
        with(|t, col| {
            let merged = format!("merged-{}~w1", rules::merged_writer_hash(U1, "w1").text());
            let write = |value: &str, s: HeritageStamp| {
                Body4::Edit(Edit4 {
                    value: format!("\"{value}\""),
                    stamp: Some(s),
                    ..native_edit()
                })
            };
            let ctx = format!(r#"{{"vv":{{"{merged}":1}}}}"#);
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let salts = Body4::salts([U1]).unwrap();
                native(t, &mut ix, col, &op(0xa1, 1, 1, &[], &salts));
                let x1 = write("x", stamp("w1", 1, r#"{"vv":{}}"#, 100));
                let x2 = write("x", stamp(&merged, 1, r#"{"vv":{}}"#, 100));
                let y = write("y", stamp("w1", 2, &ctx, 200));
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &x1));
                heritage(t, &mut ix, col, op(0xd2, 1, 2, &[], &x2));
                heritage(t, &mut ix, col, op(0xd1, 2, 3, &[], &y));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                let e = native_edit();
                assert_eq!(ix.members(&Ref::of(&e.entity))?.len(), 1);
                let raw = ix.register(EntKind::Note, &e.entity, &e.key)?;
                assert!(raw.iter().any(|(_, s)| *s == R_CONFLICT), "{raw:?}");
                let got = ix.class_winners(EntKind::Note, &Ref::of(&e.entity))?;
                assert_eq!(got.len(), 1);
                assert_eq!(got[0].value, "\"y\"");
                assert!(!got[0].conflict);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 改名写入者的名字。
    fn merged_w1() -> String {
        format!("merged-{}~w1", rules::merged_writer_hash(U1, "w1").text())
    }

    /// 带旧戳的一条写入（实体、键取 [native_edit]）。
    fn stamped(value: &str, s: HeritageStamp) -> Body4 {
        Body4::Edit(Edit4 {
            value: format!("\"{value}\""),
            stamp: Some(s),
            ..native_edit()
        })
    }

    /// 改名写入者能归回的证据（「同一套 seq」）：(w1, 1) 与 (merged, 1) 是同一条记录，落在另一个键上，不碰被测的寄存器。
    fn renamed_writer_evidence(t: &Truth<'_>, ix: &mut Index<'_, '_>, col: i64, merged: &str) {
        let salts = Body4::salts([U1]).unwrap();
        native(t, ix, col, &op(0xa1, 1, 1, &[], &salts));
        let proof = |w: &str| {
            Body4::Edit(Edit4 {
                key: "proof".to_owned(),
                value: "\"p\"".to_owned(),
                stamp: Some(stamp(w, 1, r#"{"vv":{}}"#, 50)),
                ..native_edit()
            })
        };
        heritage(t, ix, col, op(0xc1, 1, 1, &[], &proof("w1")));
        heritage(t, ix, col, op(0xc2, 1, 2, &[], &proof(merged)));
    }

    /// HLC 里的写入者也换（设计 §5.3「三处一起换」）：两条并发、物理时刻与计数相同，胜负落到 HLC 写入者上。原名
    /// `merged-…~w1` < `v`，原值判 `v` 胜；归回成 `w1` > `v`，按类判 `w1` 那条胜。两边都是冲突。
    #[test]
    fn the_hlc_writer_is_renamed_too() {
        with(|t, col| {
            let merged = merged_w1();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                renamed_writer_evidence(t, &mut ix, col, &merged);
                let a = stamped("a", stamp(&merged, 2, r#"{"vv":{}}"#, 100));
                let b = stamped("b", stamp("v", 1, r#"{"vv":{}}"#, 100));
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &a));
                heritage(t, &mut ix, col, op(0xd2, 1, 2, &[], &b));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                let e = native_edit();
                let raw = ix.register(EntKind::Note, &e.entity, &e.key)?;
                let winner = raw.iter().find(|(_, s)| *s >= R_WINNER).copied().unwrap();
                assert_eq!(winner, (op(0xd2, 1, 2, &[], &b).id, R_CONFLICT));
                let got: Vec<ClassWinner> = ix
                    .class_winners(EntKind::Note, &Ref::of(&e.entity))?
                    .into_iter()
                    .filter(|w| w.key == e.key)
                    .collect();
                assert_eq!(got.len(), 1);
                assert_eq!(got[0].value, "\"a\"");
                assert!(got[0].conflict);
                Ok(())
            })
            .unwrap();
        });
    }

    /// 不带旧戳的原生写入「见没见过」改名写入者的写入：按原名问闭包（闭包存原名）。原生写入依赖的承袭操作带
    /// `merged-…~w1` 的旧戳，它就见过 (w1, 1)，盖掉它、没有冲突；拿规范名 `w1` 去问会答「没见过」= 误报冲突。
    #[test]
    fn a_native_write_sees_a_renamed_writer_by_its_raw_name() {
        with(|t, col| {
            let merged = merged_w1();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                renamed_writer_evidence(t, &mut ix, col, &merged);
                let x = stamped("x", stamp(&merged, 2, r#"{"vv":{}}"#, 100));
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &x));
                let z = Body4::Edit(Edit4 {
                    value: "\"z\"".to_owned(),
                    ..native_edit()
                });
                native(t, &mut ix, col, &op(0xa2, 1, 300, &[(0xd1, 1)], &z));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                let e = native_edit();
                let raw = ix.register(EntKind::Note, &e.entity, &e.key)?;
                assert!(raw.iter().all(|(_, s)| *s != R_CONFLICT), "{raw:?}");
                let got: Vec<ClassWinner> = ix
                    .class_winners(EntKind::Note, &Ref::of(&e.entity))?
                    .into_iter()
                    .filter(|w| w.key == e.key)
                    .collect();
                assert_eq!(got.len(), 1);
                assert_eq!(got[0].value, "\"z\"");
                assert!(!got[0].conflict);
                Ok(())
            })
            .unwrap();
        });
    }

    /// 标签按类内成员并起来判：第二份上的删除见过第一份上的添加 → 抹掉；与它并发的添加留着。
    #[test]
    fn tags_are_one_observed_remove_set_across_the_class() {
        with(|t, col| {
            let w = twin();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                let (n0, n1) = (w.note[0], w.note[1]);
                native(t, &mut ix, col, &op(0xb1, 1, 200, &[], &tag_add(n0, "a")));
                native(t, &mut ix, col, &op(0xb1, 2, 201, &[], &tag_add(n0, "b")));
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xb2, 1, 202, &[(0xb1, 1)], &tag_remove(n1, "a")),
                );
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xb2, 2, 203, &[(0xb1, 1)], &tag_remove(n1, "b")),
                );
                native(t, &mut ix, col, &op(0xb3, 1, 204, &[], &tag_add(n1, "c")));
                ix.settle()?;
                assert_eq!(
                    ix.tags_of(&Key::Uuid(n0))?,
                    vec!["a".to_owned(), "b".to_owned()]
                );
                assert_eq!(
                    ix.class_tags(&r(w.c_note))?,
                    vec!["b".to_owned(), "c".to_owned()]
                );
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 内嵌的 ID：`fieldDesc/` 键、值本身是 ID 的键、模板文本里的 `{{fld:…}}`、整份 JSON；用户文本不动。
    #[test]
    fn embedded_ids_are_canonicalized_where_they_are_ids_and_nowhere_else() {
        with(|t, col| {
            let w = twin();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                let tmpl = edit(
                    EntKind::NoteType,
                    w.nt[1],
                    &format!("tmplDef/{}", w.tmpl[1].text()),
                    json!({"ankiNum": 0, "name": "Card 1"}),
                );
                native(t, &mut ix, col, &op(0xa1, 8, 300, &[], &tmpl));
                ix.settle()?;
                let f1 = w.field[1].text();
                let cf = w.c_field.text();
                assert_eq!(
                    ix.canonical_key(&format!("fieldDesc/{f1}"))?,
                    format!("fieldDesc/{cf}")
                );
                assert_eq!(
                    ix.canonical_key("fieldDesc/not-an-id")?,
                    "fieldDesc/not-an-id"
                );
                assert_eq!(
                    ix.canonical_key(&format!("tmplDef/{}", w.tmpl[1].text()))?,
                    format!("tmplDef/{}", w.c_tmpl.text())
                );
                assert_eq!(
                    ix.canonical_value("noteType", &json!(w.nt[0].text()))?,
                    json!(w.c_nt.text())
                );
                // 字段内容是用户文本：长得像 ID 也不动。
                assert_eq!(
                    ix.canonical_value(&fkey(w.field[1]), &json!(f1))?,
                    json!(f1)
                );
                let front =
                    format!("{{{{fld:{f1}}}}} fld:{f1} {{{{#fld:{f1}}}}}x{{{{/fld:{f1}}}}}");
                let tpl = json!({"name": "Card 1", "front": front, "back": "{{FrontSide}}"});
                let got = ix.canonical_value(&format!("tmplDef/{}", w.tmpl[1].text()), &tpl)?;
                let want = format!("{{{{fld:{cf}}}}} fld:{f1} {{{{#fld:{cf}}}}}x{{{{/fld:{cf}}}}}");
                assert_eq!(got["front"], json!(want));
                // 注释与 `{{…}}` 里不是整段字段引用的：模板渲染不认，这里也不动（与 `ids_to_names` 同一个分词）。
                let comments = format!(
                    "<!-- {{{{fld:{f1}}}}} --> {{{{!-- 见 fld:{f1} --}}}} {{{{Text:fld:{f1}}}}}"
                );
                let skipped = ix.canonical_value(
                    &format!("tmplDef/{}", w.tmpl[1].text()),
                    &json!({"front": comments}),
                )?;
                let kept = format!(
                    "<!-- {{{{fld:{f1}}}}} --> {{{{!-- 见 fld:{f1} --}}}} {{{{Text:fld:{cf}}}}}"
                );
                assert_eq!(skipped["front"], json!(kept));
                assert_eq!(got["name"], tpl["name"]);
                assert_eq!(got["back"], tpl["back"]);
                let doc = json!({
                    "id": w.note[1].text(),
                    "d": {"guid": GUID, "noteTypeId": w.nt[1].text()},
                    "edits": [
                        {"f": fkey(w.field[1]), "v": f1},
                        {"f": "noteType", "v": w.nt[0].text()},
                    ],
                    "revokes": [w.note[0].text(), "r1"],
                });
                assert_eq!(
                    ix.canonical_json(&doc)?,
                    json!({
                        "id": w.c_note.text(),
                        "d": {"guid": GUID, "noteTypeId": w.c_nt.text()},
                        "edits": [
                            {"f": fkey(w.c_field), "v": f1},
                            {"f": "noteType", "v": w.c_nt.text()},
                        ],
                        "revokes": [w.c_note.text(), "r1"],
                    })
                );
                Ok(())
            })
            .unwrap();
        });
    }

    /// 逐条维护与重建之后，按类读的输出相同。
    #[test]
    fn class_reads_are_the_same_after_a_rebuild() {
        with(|t, col| {
            let w = twin();
            let read = |t: &Truth<'_>| {
                t.tx(|t| {
                    let mut ix = Index::new(t, col);
                    Ok((
                        ix.class_winners(EntKind::Note, &r(w.c_note))?,
                        ix.class_tags(&r(w.c_note))?,
                    ))
                })
                .unwrap()
            };
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 0xa1, &twin_ops(&w));
                for (n, (i, v)) in [(0, "p"), (1, "q"), (0, "r")].into_iter().enumerate() {
                    let dev = 0xb1 + n as u8;
                    let e = edit(EntKind::Note, w.note[i], &fkey(w.field[i]), json!(v));
                    native(t, &mut ix, col, &op(dev, 1, 200 + n as i64, &[], &e));
                    native(
                        t,
                        &mut ix,
                        col,
                        &op(dev, 2, 300 + n as i64, &[], &tag_add(w.note[i], v)),
                    );
                    ix.settle()?;
                }
                Ok(())
            })
            .unwrap();
            let before = read(t);
            assert_eq!(before.0.len(), 1);
            assert!(before.0[0].conflict);
            assert_eq!(before.1.len(), 3);
            assert_rebuild_is_identity(t, col);
            assert_eq!(read(t), before);
        });
    }

    /// 真实样本库：`gen4_sample_index` 重建好的新代文件上量「按类判定」与「按原值判定」差多少（设计 §12：归回去的
    /// 写入者 ctx 归一后判定是否与原件一致没比过；G9-1 要先量，有差异就停下报所有者）。只读（一个回滚掉的读事务）。
    ///
    /// 报三组数：
    /// - `classes`：有不止一个成员的别名类，按种类数类、寄存器（规范键）、其中写入来自不止一个成员的（并起来的）、
    ///   并起来后胜者值与各成员原值胜者归一后的值不全相同的、按类新出现的冲突 / 消失的冲突；笔记类的标签与各成员
    ///   原值标签之并不同的。
    /// - `writers`：归回的改名写入者、它们名下的修改记录条数；写入不止一条的寄存器里只换写入者（实体、键不变）
    ///   重判后状态与原值判定不同的寄存器数（列前 10 个）。
    ///
    /// `FUSHI_GEN4_OUT=<gen4_sample_index 跑过的文件> cargo test --release --lib gen4_sample_class -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn gen4_sample_class() {
        use std::collections::BTreeSet;
        use std::time::Instant;

        use crate::store::gen4::derive::{R_LIVE, body_of};
        use crate::store::gen4::legacy::tests::peak_mem_mb;
        use crate::store::gen4::schema::open;

        let Ok(out) = std::env::var("FUSHI_GEN4_OUT") else {
            println!("FUSHI_GEN4_OUT not set");
            return;
        };
        let dst = open(std::path::Path::new(&out)).unwrap();
        let t = Truth::new(&dst);
        let cols: Vec<i64> = dst
            .prepare("SELECT col FROM collections ORDER BY col")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        for col in cols {
            dst.execute_batch("BEGIN").unwrap();
            let started = Instant::now();
            let mut ix = Index::new(&t, col);
            // ---- 有不止一个成员的类
            let canons: Vec<Ref> = dst
                .prepare(
                    "SELECT DISTINCT canon FROM alias_ix WHERE col = ?1 AND canon != id ORDER BY canon",
                )
                .unwrap()
                .query_map([col], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect();
            let mut by_kind: BTreeMap<i64, [u64; 8]> = BTreeMap::new();
            let (mut tag_classes, mut tag_diff) = (0u64, 0u64);
            let mut samples: Vec<String> = Vec::new();
            let mut gone: BTreeMap<i64, Vec<String>> = BTreeMap::new();
            for canon in &canons {
                let members = ix.members(canon).unwrap();
                let mut kinds: BTreeSet<i64> = BTreeSet::new();
                for m in &members {
                    let mut stmt = dst
                        .prepare_cached(
                            "SELECT DISTINCT ekind FROM reg_ix WHERE col = ?1 AND ent = ?2",
                        )
                        .unwrap();
                    kinds.extend(
                        stmt.query_map(params![col, m], |r| r.get::<_, i64>(0))
                            .unwrap()
                            .map(Result::unwrap),
                    );
                }
                for kind in kinds {
                    let ek = EntKind::ALL[kind as usize];
                    let c = by_kind.entry(kind).or_default();
                    c[0] += 1;
                    // 原值：每个成员各自的胜者，按规范键成组（值归一后）。
                    let mut raw: BTreeMap<String, Vec<(Ref, String, bool)>> = BTreeMap::new();
                    for m in &members {
                        let rows: Vec<(Vec<u8>, i64, i64)> = dst
                            .prepare_cached(
                                "SELECT key, k, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND state >= ?4",
                            )
                            .unwrap()
                            .query_map(params![col, kind, m, R_WINNER], |r| {
                                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                            })
                            .unwrap()
                            .map(Result::unwrap)
                            .collect();
                        for (key, k, state) in rows {
                            let text = read_edit_key(&mut Reader::new(&key)).unwrap();
                            let ck = ix.canonical_key(&text).unwrap();
                            let v: Value = serde_json::from_str(&t.edit_value(k).unwrap().unwrap())
                                .unwrap_or(Value::Null);
                            let v = ix.canonical_value(&ck, &v).unwrap().to_string();
                            raw.entry(ck)
                                .or_default()
                                .push((m.clone(), v, state == R_CONFLICT));
                        }
                    }
                    let class = ix.class_winners(ek, canon).unwrap();
                    c[1] += class.len() as u64;
                    for w in &class {
                        let Some(rs) = raw.get(&w.key) else {
                            c[6] += 1;
                            continue;
                        };
                        let from: BTreeSet<&Ref> = rs.iter().map(|x| &x.0).collect();
                        if from.len() > 1 {
                            c[2] += 1;
                        }
                        let canon_v: Value = serde_json::from_str(&w.value).unwrap();
                        let same = rs.iter().all(|x| {
                            serde_json::from_str::<Value>(&x.1).ok().as_ref() == Some(&canon_v)
                        });
                        if !same {
                            c[3] += 1;
                            if samples.len() < 10 {
                                samples.push(format!(
                                    "kind {kind} canon {} key {} class {} raw {:?}",
                                    canon.text(),
                                    w.key,
                                    w.value,
                                    rs.iter().map(|x| &x.1).collect::<Vec<_>>()
                                ));
                            }
                        }
                        let raw_conflict = rs.iter().any(|x| x.2);
                        if w.conflict && !raw_conflict {
                            c[4] += 1;
                        }
                        if !w.conflict && raw_conflict {
                            c[5] += 1;
                            // 不换写入者（空表）再判一次：冲突回来了 = 是写入者归回让冲突消失的。
                            let mut rows: Vec<(i64, i64)> = Vec::new();
                            for m in &members {
                                let mut stmt = dst
                                    .prepare_cached(
                                        "SELECT key, k, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3",
                                    )
                                    .unwrap();
                                let got: Vec<(Vec<u8>, i64, i64)> = stmt
                                    .query_map(params![col, kind, m], |r| {
                                        Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                                    })
                                    .unwrap()
                                    .map(Result::unwrap)
                                    .collect();
                                for (key, k, state) in got {
                                    let text = read_edit_key(&mut Reader::new(&key)).unwrap();
                                    if ix.canonical_key(&text).unwrap() == w.key {
                                        rows.push((k, state));
                                    }
                                }
                            }
                            rows.sort_unstable();
                            let none = BTreeMap::new();
                            let plain = Canon {
                                writers: &none,
                                entity: canon.text(),
                                key: w.key.clone(),
                            };
                            let (_, want) = ix.judged(&rows, Some(&plain)).unwrap();
                            if want.contains(&R_CONFLICT) {
                                c[7] += 1;
                            }
                            if gone.entry(kind).or_default().len() < 5 {
                                // 原值冲突里各条活着的写入的值（原样与归一后）：看冲突是怎么没的。
                                let mut live: Vec<String> = Vec::new();
                                for m in &members {
                                    let rows: Vec<(Vec<u8>, i64, i64)> = dst
                                        .prepare_cached(
                                            "SELECT key, k, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND state >= ?4",
                                        )
                                        .unwrap()
                                        .query_map(params![col, kind, m, R_LIVE], |r| {
                                            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                                        })
                                        .unwrap()
                                        .map(Result::unwrap)
                                        .collect();
                                    for (key, k, state) in rows {
                                        let text = read_edit_key(&mut Reader::new(&key)).unwrap();
                                        if ix.canonical_key(&text).unwrap() != w.key {
                                            continue;
                                        }
                                        let raw = t.edit_value(k).unwrap().unwrap();
                                        let v: Value =
                                            serde_json::from_str(&raw).unwrap_or(Value::Null);
                                        let cv = ix.canonical_value(&w.key, &v).unwrap();
                                        live.push(format!(
                                            "[member {} state {state} raw {raw} canon {cv}]",
                                            m.text()
                                        ));
                                    }
                                }
                                gone.entry(kind).or_default().push(format!(
                                    "kind {kind} canon {} key {} members_with_writes {} class {} live {}",
                                    canon.text(),
                                    w.key,
                                    from.len(),
                                    w.value,
                                    live.join(" ")
                                ));
                            }
                        }
                    }
                    if ek == EntKind::Note {
                        tag_classes += 1;
                        let mut union: BTreeSet<String> = BTreeSet::new();
                        for m in &members {
                            union.extend(ix.tags_of(&Key::of(&m.text())).unwrap());
                        }
                        let got: BTreeSet<String> =
                            ix.class_tags(canon).unwrap().into_iter().collect();
                        if got != union {
                            tag_diff += 1;
                        }
                    }
                }
            }
            println!(
                "SAMPLE class col {col} multi_member_classes {} s {:.1}",
                canons.len(),
                started.elapsed().as_secs_f64()
            );
            for (kind, c) in &by_kind {
                println!(
                    "SAMPLE class kind {kind} classes {} registers {} merged {} value_differs {} new_conflicts {} gone_conflicts {} (of which back_without_writer_aliases {}) class_only_keys {}",
                    c[0], c[1], c[2], c[3], c[4], c[5], c[7], c[6]
                );
            }
            println!(
                "SAMPLE class tags note_classes {tag_classes} differ_from_member_union {tag_diff}"
            );
            for s in &samples {
                println!("SAMPLE class value_differs {s}");
            }
            for s in gone.values().flatten() {
                println!("SAMPLE class gone_conflict {s}");
            }
            // ---- 归回的写入者
            let started = Instant::now();
            let writers = ix.writer_aliases().unwrap();
            let names: BTreeSet<&str> = writers.keys().map(String::as_str).collect();
            let all: Vec<(i64, Ref, Vec<u8>, i64, i64)> = dst
                .prepare("SELECT ekind, ent, key, k, state FROM reg_ix WHERE col = ?1 ORDER BY ekind, ent, key, k")
                .unwrap()
                .query_map([col], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
                })
                .unwrap()
                .map(Result::unwrap)
                .collect();
            let mut renamed_edits = 0u64;
            let mut ctx_mentions = 0u64;
            let mut regs: BTreeMap<(i64, Ref, Vec<u8>), Vec<(i64, i64)>> = BTreeMap::new();
            let mut touched: BTreeSet<(i64, Ref, Vec<u8>)> = BTreeSet::new();
            for (ekind, ent, key, k, state) in all {
                let reg = (ekind, ent, key);
                if !names.is_empty() {
                    let e = t.entry_by_key(k).unwrap().unwrap();
                    if let Some(Body4::Edit(ed)) = body_of(&e) {
                        if ed
                            .stamp
                            .as_ref()
                            .is_some_and(|s| names.contains(s.writer.as_str()))
                        {
                            renamed_edits += 1;
                            touched.insert(reg.clone());
                        }
                        // 旧上下文的键里提到改名写入者的（换名会改它见过谁）。
                        if ed.stamp.as_ref().is_some_and(|s| {
                            s.ctx
                                .entries()
                                .iter()
                                .any(|e| names.contains(e.writer.as_str()))
                        }) {
                            ctx_mentions += 1;
                            touched.insert(reg.clone());
                        }
                    }
                }
                regs.entry(reg).or_default().push((k, state));
            }
            let (mut judged, mut differ) = (0u64, 0u64);
            let mut wsamples: Vec<String> = Vec::new();
            for (reg, rows) in &regs {
                if rows.len() < 2 || !touched.contains(reg) {
                    continue;
                }
                judged += 1;
                let key = read_edit_key(&mut Reader::new(&reg.2)).unwrap();
                let c = Canon {
                    writers: &writers,
                    entity: reg.1.text(),
                    key: key.clone(),
                };
                let (live, want) = ix.judged(rows, Some(&c)).unwrap();
                let have: Vec<i64> = live.iter().map(|x| x.1).collect();
                if have != want {
                    differ += 1;
                    if wsamples.len() < 10 {
                        wsamples.push(format!(
                            "ent {} key {key} raw {have:?} renamed {want:?}",
                            reg.1.text()
                        ));
                    }
                }
            }
            println!(
                "SAMPLE class writers {} renamed_edits {renamed_edits} ctx_mentions {ctx_mentions} multi_write_registers_touched {judged} state_differs {differ} s {:.1}",
                writers.len(),
                started.elapsed().as_secs_f64()
            );
            for s in &wsamples {
                println!("SAMPLE class writer_differs {s}");
            }
            dst.execute_batch("ROLLBACK").unwrap();
            let (ws, commit) = peak_mem_mb();
            println!("SAMPLE class peak_working_set_mb {ws:.0} peak_commit_mb {commit:.0}");
        }
    }
}
