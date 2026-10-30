//! 重放用的排程配置（Dart `SrsDeckTree.schedulingConfig` 的同一套规则，读 srs.db 的投影行）。
//!
//! - 卡的牌组：血统继承的卡片标志（registers.rs `cards_group`）→ 笔记首选牌组 → 默认牌组；不在树里
//!   （已删 / 还没同步到）的归默认牌组（`effectiveDeckOf`）。
//! - 步长 / 最大间隔取卡所在牌组自己的；算法 / 参数 / 记忆率取最近一个 own 祖先（顶层恒为 own）。
//! - 成环的父子关系：环上 ID 字典序最小的那个视为顶层。

use std::collections::{BTreeMap, HashMap, HashSet};

use rusqlite::Connection;
use serde_json::Value;

use crate::registers::{card_lineage_flags, deck_view_of, register_value};
use crate::sync2::id::Id;
use crate::sync2::sched::{Config, MemAlg};

/// Dart `srsNamespace`（冻结）。
pub const SRS_NAMESPACE: &str = "6f1c8a2e-4b7d-5e3f-9a10-2d4c6e8f0b13";

pub fn default_deck_id(profile: &str) -> String {
    Id::v5(&Id::parse(SRS_NAMESPACE).expect("ns"), &format!("{profile}/builtin-deck/default")).text()
}

const DEFAULT_LEARN: [f64; 2] = [1.0, 10.0];
const DEFAULT_RELEARN: [f64; 1] = [10.0];

#[derive(Clone, Debug)]
pub struct DeckNode {
    pub parent: Option<String>,
    pub own: bool,
    pub view: Value,
}

/// 一个 profile 的（未删除的）牌组树。
pub struct DeckTree {
    pub decks: HashMap<String, DeckNode>,
    pub default_deck: String,
}

/// 某实体的全部落库修改记录（JSON 原文 + S(e)）。
pub fn edits_of(conn: &Connection, kind: &str, ids: &[String]) -> Result<HashMap<String, Vec<(String, Option<i64>)>>, String> {
    let mut out: HashMap<String, Vec<(String, Option<i64>)>> = HashMap::new();
    for chunk in ids.chunks(400) {
        let marks = vec!["srs_id(?)"; chunk.len()].join(",");
        let sql = format!(
            "SELECT srs_idt(f.entity_id) AS entity_id, f.json, e.server_time FROM srs_field_edits f \
             LEFT JOIN srs_event_local e ON e.event_id = f.id \
             WHERE f.entity_kind = ? AND f.entity_id IN ({marks})"
        );
        let mut stmt = conn.prepare_cached(&sql).map_err(|e| e.to_string())?;
        let mut params: Vec<&dyn rusqlite::ToSql> = vec![&kind];
        for id in chunk {
            params.push(id);
        }
        let mut q = stmt.query(params.as_slice()).map_err(|e| e.to_string())?;
        while let Some(r) = q.next().map_err(|e| e.to_string())? {
            let id: String = r.get(0).map_err(|e| e.to_string())?;
            out.entry(id).or_default().push((r.get(1).map_err(|e| e.to_string())?, r.get(2).map_err(|e| e.to_string())?));
        }
    }
    Ok(out)
}

fn stored(v: &[(String, Option<i64>)]) -> Vec<(&str, Option<i64>)> {
    v.iter().map(|(j, s)| (j.as_str(), *s)).collect()
}

impl DeckTree {
    pub fn load(conn: &Connection, profile: &str) -> Result<DeckTree, String> {
        let mut payloads: BTreeMap<String, Value> = BTreeMap::new();
        {
            let mut stmt = conn
                .prepare_cached("SELECT srs_idt(id) AS id, payload_json FROM srs_entities WHERE profile_uid = srs_id(?1) AND kind = 'deck'")
                .map_err(|e| e.to_string())?;
            let mut q = stmt.query([profile]).map_err(|e| e.to_string())?;
            while let Some(r) = q.next().map_err(|e| e.to_string())? {
                let id: String = r.get(0).map_err(|e| e.to_string())?;
                let p: String = r.get(1).map_err(|e| e.to_string())?;
                payloads.insert(id, serde_json::from_str(&p).unwrap_or(Value::Null));
            }
        }
        let ids: Vec<String> = payloads.keys().cloned().collect();
        let edits = edits_of(conn, "deck", &ids)?;
        let empty = Vec::new();
        let mut decks = HashMap::new();
        for (id, payload) in &payloads {
            let view = deck_view_of(payload, &stored(edits.get(id).unwrap_or(&empty)))?;
            if !view["da"].is_null() {
                continue;
            }
            let parent = view["pa"].as_str().map(str::to_owned);
            let own = view["own"] == Value::Bool(true);
            decks.insert(id.clone(), DeckNode { parent, own, view });
        }
        let mut tree = DeckTree { decks, default_deck: default_deck_id(profile) };
        tree.resolve_parents();
        Ok(tree)
    }

    /// Dart `_resolveParents`：父不在树里 = 顶层；成环时环上最小 ID 视为顶层。
    fn resolve_parents(&mut self) {
        let ids: Vec<String> = {
            let mut v: Vec<String> = self.decks.keys().cloned().collect();
            v.sort();
            v
        };
        for id in &ids {
            let p = self.decks[id].parent.clone();
            if p.as_ref().is_some_and(|p| !self.decks.contains_key(p)) {
                self.decks.get_mut(id).expect("deck").parent = None;
            }
        }
        for start in &ids {
            let mut path: Vec<String> = Vec::new();
            let mut seen: HashSet<String> = HashSet::new();
            let mut cur = Some(start.clone());
            while let Some(c) = cur.clone() {
                if seen.contains(&c) {
                    break;
                }
                seen.insert(c.clone());
                path.push(c.clone());
                cur = self.decks.get(&c).and_then(|d| d.parent.clone());
            }
            if let Some(c) = cur {
                let at = path.iter().position(|x| *x == c).expect("cycle start");
                let mut cycle: Vec<String> = path[at..].to_vec();
                cycle.sort();
                self.decks.get_mut(&cycle[0]).expect("deck").parent = None;
            }
        }
    }

    pub fn effective(&self, deck: &str) -> String {
        if self.decks.contains_key(deck) { deck.to_owned() } else { self.default_deck.clone() }
    }

    /// 最近一个 own 祖先（顶层恒为 own）。
    pub fn params_owner(&self, id: &str) -> Option<&DeckNode> {
        let mut cur = Some(id.to_owned());
        let mut guard = 0;
        while let Some(c) = cur {
            let d = self.decks.get(&c)?;
            if d.own || d.parent.is_none() || guard > 64 {
                return Some(d);
            }
            guard += 1;
            cur = d.parent.clone();
        }
        None
    }

    /// 子树（含自己）。
    pub fn subtree(&self, id: &str) -> Vec<String> {
        let mut out = vec![id.to_owned()];
        let mut i = 0;
        while i < out.len() {
            let parent = out[i].clone();
            let mut kids: Vec<String> =
                self.decks.iter().filter(|(_, d)| d.parent.as_deref() == Some(parent.as_str())).map(|(k, _)| k.clone()).collect();
            kids.sort();
            out.extend(kids);
            i += 1;
        }
        out
    }

    /// 某牌组复习时实际用的排程配置（`SrsDeckTree.schedulingConfig`）。
    pub fn config(&self, deck: &str) -> Config {
        let id = self.effective(deck);
        let Some(me) = self.decks.get(&id) else { return Config::default() };
        let owner = self.params_owner(&id).unwrap_or(me);
        let alg_wire = owner.view["alg"].as_str().unwrap_or("rwkv");
        let alg = MemAlg::of_wire(alg_wire);
        let set = match alg {
            MemAlg::Fsrs6 => &owner.view["f6"],
            MemAlg::Fsrs7 => &owner.view["f7"],
        };
        let params: Vec<f32> = set
            .get("params")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_f64).map(|x| x as f32).collect())
            .unwrap_or_default();
        let params = if params.len() == alg.param_count() { params } else { Vec::new() };
        Config {
            learn_steps: steps(&me.view["ls"], &DEFAULT_LEARN),
            relearn_steps: steps(&me.view["rs"], &DEFAULT_RELEARN),
            desired_retention: owner.view["ret"].as_f64().unwrap_or(0.8),
            max_interval: me.view["mi"].as_i64().unwrap_or(36500),
            alg,
            params,
            fuzz: true,
        }
    }
}

/// `srsSanitizeSteps`：每项 > 0 且 < 1 天；全被剔除用默认。不是列表 = 默认。
fn steps(v: &Value, fallback: &[f64]) -> Vec<f64> {
    let Some(xs) = v.as_array() else { return fallback.to_vec() };
    let ok: Vec<f64> = xs.iter().filter_map(Value::as_f64).filter(|&s| s > 0.0 && s < 1440.0).collect();
    if ok.is_empty() { fallback.to_vec() } else { ok }
}

/// 卡的有效牌组（血统继承的 deck 标志 → 笔记首选牌组 → 默认牌组；不在树里归默认）。
pub fn card_deck(conn: &Connection, tree: &DeckTree, card: &str, note: Option<&str>) -> Result<String, String> {
    // 血统：沿 historyFrom 前身（广度优先，最多 256 张）。先一次取全血统的记录。
    let mut lineage = vec![card.to_owned()];
    let mut i = 0;
    let mut by_card: HashMap<String, Vec<(String, Option<i64>)>> = HashMap::new();
    while i < lineage.len() && lineage.len() < 256 {
        let c = lineage[i].clone();
        let es = edits_of(conn, "card", std::slice::from_ref(&c))?.remove(&c).unwrap_or_default();
        for p in predecessors(&es) {
            if !lineage.contains(&p) {
                lineage.push(p);
            }
        }
        by_card.insert(c, es);
        i += 1;
    }
    let note_deck = match note {
        Some(n) => {
            let es = edits_of(conn, "note", &[n.to_owned()])?.remove(n).unwrap_or_default();
            register_value(&stored(&es), "deck")?.as_str().map(str::to_owned)
        }
        None => None,
    };
    let cards: Vec<(String, Vec<(&str, Option<i64>)>)> =
        lineage.iter().map(|c| (c.clone(), stored(by_card.get(c).map(Vec::as_slice).unwrap_or(&[])))).collect();
    let flags = card_lineage_flags(&cards, &[(card.to_owned(), note_deck, tree.default_deck.clone())])?;
    let dk = flags.first().and_then(|(_, f)| f["dk"].as_str().map(str::to_owned)).unwrap_or_else(|| tree.default_deck.clone());
    Ok(tree.effective(&dk))
}

/// 一张卡的修改记录里列出的前身（`historyFrom/<前身>` 的生效值为 true；按 UTF-16 序）。
pub fn predecessors(edits: &[(String, Option<i64>)]) -> Vec<String> {
    let mut keys: Vec<String> = Vec::new();
    for (j, _) in edits {
        if let Ok(v) = serde_json::from_str::<Value>(j) {
            if let Some(k) = v["f"].as_str().and_then(|f| f.strip_prefix("historyFrom/")) {
                if !keys.iter().any(|x| x == k) {
                    keys.push(k.to_owned());
                }
            }
        }
    }
    let st = stored(edits);
    let mut out: Vec<String> = keys
        .into_iter()
        .filter(|k| register_value(&st, &format!("historyFrom/{k}")).is_ok_and(|v| v == Value::Bool(true)))
        .collect();
    out.sort_by(|a, b| crate::ordering::cmp_utf16(a, b));
    out
}

/// 继承了 [card] 历史的卡（`historyFrom/<card>` 生效为 true 的卡），按 ID 升序。
pub fn successors(conn: &Connection, card: &str) -> Result<Vec<String>, String> {
    let key = format!("historyFrom/{card}");
    let mut stmt = conn
        .prepare_cached(&format!(
            "SELECT DISTINCT srs_idt(entity_id) AS entity_id FROM srs_field_edits WHERE field_key = ?1 AND entity_kind = 'card' AND {}",
            crate::store::schema::HISTORY_FROM_CONDITION
        ))
        .map_err(|e| e.to_string())?;
    let ids: Vec<String> = stmt
        .query_map([&key], |r| r.get(0))
        .map_err(|e| e.to_string())?
        .collect::<Result<_, _>>()
        .map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for id in ids {
        let es = edits_of(conn, "card", std::slice::from_ref(&id))?.remove(&id).unwrap_or_default();
        if register_value(&stored(&es), &key)? == Value::Bool(true) {
            out.push(id);
        }
    }
    out.sort();
    Ok(out)
}
