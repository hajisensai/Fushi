//! `lineages` 的新代实现：一组卡各自的血统（自己在前、再按广度优先列出全部前身，防环、最多 256 层），与输入同序
//! （协议 3 `store/caches.rs` `lineage_ids`；优化器 / RWKV 取数、卡片历史按卡调）。
//!
//! 规则只有一份：血统由 `registers::card_lineage_flags` 判（与缓存层逐卡重放、协议 3 同一个函数），这里只负责交给它
//! 每张卡活着的 `historyFrom/<前身>` 修改行。行按类判定（`Index::class_lines`，D24）：请求给的卡先归一，一张卡的前身
//! 链接看整个别名类（类里任何成员上写的链接都算），链接里的前身是规范 ID；结果里的卡全是规范 ID。

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use super::{ref_of, snapshot};
use crate::registers::{self, StoredEdit};
use crate::store::gen4::derive::Index;
use crate::store::gen4::truth::Truth;
use crate::sync2::op::EntKind;

const HISTORY_FROM: &str = "historyFrom/";

/// 前身链最多走这么多层（同协议 3）。
const MAX_DEPTH: usize = 256;

/// `lineages {cards}`：每张卡的血统（规范 ID），与输入同序（请求里同一张卡的不同成员各占一项、结果相同）。
pub fn lineages(t: &Truth<'_>, col: i64, cards: &[String]) -> Result<Vec<Vec<String>>, String> {
    if cards.is_empty() {
        return Ok(Vec::new());
    }
    snapshot(t, |t| {
        let mut ix = Index::new(t, col);
        let want: Vec<String> = cards
            .iter()
            .map(|c| Ok(ix.canonical(&ref_of(c))?.text()))
            .collect::<Result<_, String>>()?;
        // 卡（规范 ID 文本）→ 它活着的 `historyFrom/` 修改行（行 JSON, 服务器时刻）。
        let mut edits: BTreeMap<String, Vec<(String, Option<i64>)>> = BTreeMap::new();
        let mut next: BTreeSet<String> = want.iter().cloned().collect();
        for _ in 0..MAX_DEPTH {
            if next.is_empty() {
                break;
            }
            let mut preds: BTreeSet<String> = BTreeSet::new();
            for id in std::mem::take(&mut next) {
                let (lines, _) = ix.class_lines(EntKind::Card, &ref_of(&id))?;
                let mut mine = Vec::new();
                for (json, st) in lines {
                    let key = serde_json::from_str::<Value>(&json)
                        .ok()
                        .and_then(|v| v.get("f").and_then(Value::as_str).map(str::to_owned))
                        .unwrap_or_default();
                    let Some(p) = key.strip_prefix(HISTORY_FROM) else {
                        continue;
                    };
                    if !edits.contains_key(p) && p != id {
                        preds.insert(p.to_owned());
                    }
                    mine.push((json, st));
                }
                edits.insert(id, mine);
            }
            next = preds
                .into_iter()
                .filter(|p| !edits.contains_key(p))
                .collect();
        }
        let all: Vec<(String, Vec<StoredEdit<'_>>)> = edits
            .iter()
            .map(|(id, es)| {
                (
                    id.clone(),
                    es.iter().map(|(j, s)| (j.as_str(), *s, None)).collect(),
                )
            })
            .collect();
        let want3: Vec<(String, Option<String>, String)> = want
            .iter()
            .map(|id| (id.clone(), None, String::new()))
            .collect();
        Ok(registers::card_lineage_flags(&all, &want3)?
            .into_iter()
            .map(|(l, _)| l)
            .collect())
    })
}
