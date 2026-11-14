//! `apply` / `change` 输入项的 `chg` 标记：「这条修改记录只有会改变现值时才落」。
//!
//! 宿主改字段的几个入口（Dart `editFields` / `writeEdits` / `writeChange` / `editFieldsBatch` / `createNote`）以前在发
//! 命令之前先把这些实体的全部修改记录原文读回 Dart，交字段寄存器算出现值，筛掉值没变的，剩下的才发命令：大块数据
//! 跨了两次边界，而且读与写不在一笔里——同一个库上的另一个副本对象、收段通道的片都能插在中间，判定可能基于旧值。
//! 现在宿主把草稿全发、标上 `chg`，由这里在命令的写连接、命令的 SAVEPOINT 里读现值并筛（[drop_noops]），判定与落库
//! 之间插不进别的写入。判据是 [registers::write_is_noop]（Dart 旧 `srsEditIsNoop`）：这个键有生效记录、没有冲突，且
//! 生效值与要写的值「相同」。`deck_delete` / `merge_notes` / `note_fields_if` 自己拼输入时用的是同一个判据。
//!
//! 同一批里同一个（类别, 实体, 字段键）出现多次时按顺序判：后一项比的是前一项写下的值，不是批前的库——现值 A、
//! 一批 `[B, A]` 两条都落（最后是 A）；`[B, B]` 只落第一条。前一项的生效与否这里判断不了的（带着来源身份的
//! `stamped` 项，可能被现值支配）后一项一律落。
//!
//! 标了 `chg` 的项全被筛掉时命令什么都不落：不占序号、旧版时钟不走（调用方见到空结果就不调 `apply_local_on`，与
//! `note_fields_if` 的同类情形相同）。

use std::collections::{BTreeMap, BTreeSet, HashMap};

use rusqlite::Connection;
use serde_json::Value;

use super::config;
use crate::registers;

fn is_chg(it: &Value) -> bool {
    it["chg"] == Value::Bool(true)
}

/// 输入里有没有 `chg` 项（不认它的命令据此报错，不静默忽略）。
pub(crate) fn any(items: &[Value]) -> bool {
    items.iter().any(is_chg)
}

/// [drop_noops] 筛过之后：留下的项各自在原输入里的位置。
pub(crate) struct Kept {
    /// 留下的项（原顺序）在原输入里的下标。
    index: Vec<usize>,
    /// 原输入的项数。
    total: usize,
}

impl Kept {
    /// 把 `apply` 回包里按留下的项排的 `landed`（与 [stamps] 为真时的 `stamps`）展开回原输入的长度：筛掉的项
    /// `landed = false`、`stamps = null`。宿主按草稿下标取戳，不知道哪些被筛掉了。[v] 可以是空对象（一项不剩、没调
    /// `apply_local_on`）。
    pub(crate) fn widen(&self, v: &mut Value, stamps: bool) {
        let spread = |got: &Value, fill: Value| -> Value {
            let mut out = vec![fill; self.total];
            if let Some(got) = got.as_array() {
                for (at, x) in self.index.iter().zip(got) {
                    out[*at] = x.clone();
                }
            }
            Value::Array(out)
        };
        v["landed"] = spread(&v["landed"], Value::Bool(false));
        if stamps {
            v["stamps"] = spread(&v["stamps"], Value::Null);
        }
    }
}

/// 就地筛掉 [items] 里标了 `chg`、写了也不改变现值的修改记录项（见文件头）。没有 `chg` 项时返回 None（不读库、
/// [items] 不动）。在调用方的写连接、调用方开的 SAVEPOINT 里读现值。
///
/// `chg` 只能标在本机修改记录草稿上：不是修改记录、带 `init`（`import_drafts` 的「初值」，另一套判据）或 `stamped`
/// （带着来源身份，落不落不由值决定）的项标了它就报错。
pub(crate) fn drop_noops(c: &Connection, items: &mut Vec<Value>) -> Result<Option<Kept>, String> {
    if !any(items) {
        return Ok(None);
    }
    // 标了 `chg` 的项涉及的实体，按类别分组，各读一次全部修改记录。
    let mut by_kind: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
    for it in items.iter().filter(|it| is_chg(it)) {
        if it["e"]["t"].as_str() != Some("edit") {
            return Err("apply: chg on an item that is not an edit".into());
        }
        if it["init"] == Value::Bool(true) || it["stamped"] == Value::Bool(true) {
            return Err("apply: chg cannot be combined with init / stamped".into());
        }
        let x = &it["e"]["x"];
        let (Some(k), Some(e), Some(_)) = (x["k"].as_str(), x["e"].as_str(), x["f"].as_str())
        else {
            return Err("apply: chg edit without k / e / f".into());
        };
        by_kind.entry(k).or_default().insert(e);
    }
    let mut current: HashMap<&str, HashMap<String, Vec<(String, Option<i64>)>>> = HashMap::new();
    for (kind, entities) in &by_kind {
        let ids: Vec<String> = entities.iter().map(|e| (*e).to_owned()).collect();
        current.insert(*kind, config::edits_of(c, kind, &ids)?);
    }
    // 这一批里前面的项给（类别, 实体, 字段键）写下的值；None = 前一项生效与否判断不了（见文件头）。
    let mut written: HashMap<(&str, &str, &str), Option<&Value>> = HashMap::new();
    let none = Vec::new();
    let mut keep: Vec<bool> = Vec::with_capacity(items.len());
    for it in items.iter() {
        let x = &it["e"]["x"];
        let slot = match (
            it["e"]["t"].as_str(),
            x["k"].as_str(),
            x["e"].as_str(),
            x["f"].as_str(),
        ) {
            (Some("edit"), Some(k), Some(e), Some(f)) => Some((k, e, f)),
            _ => None,
        };
        let value = &x["v"];
        let noop = match slot {
            Some((k, e, f)) if is_chg(it) => match written.get(&(k, e, f)) {
                Some(Some(prev)) => *prev == value,
                Some(None) => false,
                None => {
                    let stored = current.get(k).and_then(|m| m.get(e)).unwrap_or(&none);
                    registers::write_is_noop(&config::stored(stored), f, value)?
                }
            },
            _ => false,
        };
        if let Some(slot) = slot {
            // 筛掉的项：现值与它「相同」，后面的项照样拿它的值比。
            let known = it["stamped"] != Value::Bool(true);
            written.insert(slot, known.then_some(value));
        }
        keep.push(!noop);
    }
    drop(written);
    drop(current);
    drop(by_kind);
    let kept = Kept {
        index: (0..keep.len()).filter(|i| keep[*i]).collect(),
        total: keep.len(),
    };
    let mut at = 0;
    items.retain(|_| {
        at += 1;
        keep[at - 1]
    });
    Ok(Some(kept))
}
