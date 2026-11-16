//! 写命令的新代实现（规划 §2.1 G7-3b；设计 §2.2「真相只有操作」、§3.4「新写入不带 v1 形状的数据」、§5.2「新写入按
//! 规范 ID」）。**还没接分发器**：协议 3 的写命令（`store/ffi.rs` `local_write_body` 与 `store/sync2/*` 的 `*_on`）
//! 原地不动，分发器在整批推送里一次切到这里（规划 §2.2 S1）。
//!
//! 本文件是底座与「拼操作」一组：[Session]（一条写命令的事务、写入者、索引与回包）、`apply` / `import_drafts` /
//! `purge` / `checkpoint` / `resolve`。意图命令（`note_fields_if`、`change`、`merge_notes`、`deck_delete`、`sched`）
//! 在 `writes_intent.rs`，本机状态类（`trust`、`device_hint`、`status`、`dedup`、`digest_heal`）在 `writes_local.rs`，
//! 时间线恢复（`restore`，与只读的预览 `plan_restore`）在 `writes_restore.rs`。
//!
//! # 共同约定
//!
//! - **一条命令一个事务**（[write]）：调用方没开事务就由 [Truth::tx] 开一个（开头 [Truth::reset]，规划 §1.2 G-1）；
//!   调用方已在事务里就开 SAVEPOINT。命令本体报错 = 整笔回滚（操作、链尾、`self_.hlc`、派生表一个都不留），会话
//!   reset。读现值与写入在同一个事务里，中间插不进别的写入（协议 3 的「判定与落库同一笔」原样保留）。
//! - **作者是本机身份**：每条操作经 [Native::write]（G7-3a）落原生日志——seq / 链 / 依赖 / HLC 都由它定，HLC 带
//!   `now`（内核不读系统时钟）。一条命令中途本机身份被换掉（G8-6 `rotate_identity`），下一条写入报错、整笔回滚，不会
//!   用旧设备 ID 接着写。集合没有本机身份 = 报错（协议 3 的 `Local::create` 自动建身份；新代的身份由迁移 / 建库
//!   时 `create_self` 建，写命令不偷偷建）。
//! - **只写协议 4 原生能收的形**（设计 §3.4）：修改不带旧戳、日志不带旧 HLC / 旧服务器时刻（[native_body4] 与
//!   `native_allowed` 两道关）。所以：
//!   - 输入项的 `stamped`（带来源身份的外来修改 / 日志，协议 3 并入旧 profile 用）一律拒：换代后外来数据经并入
//!     （G9 `collection_join` / `adopt_foreign`）进来，不在本机日志里冒充；
//!   - 日志事件里的 `hlc` 丢掉（协议 3 存成 `legacy_hlc`）：新代日志的排序键是 (发生时刻, 操作号)（`cache.rs`
//!     `card_logs`），HLC 就是操作自己的；
//!   - 旧版时钟（`legacyDevice` / `recvNow` / `tickNow` / 输入项的 `clk`）不再存在（设计 §2.4 删旧写入者状态），这些
//!     键收到也不看；要旧版时钟戳的 `stamps: true` 明确拒绝；
//!   - 不认识的事件（协议 3 存成 `LegacyUnknown`）明确拒绝：那是协议 1 的残留，新写入不生成。
//! - **按规范 ID 写**（D5，规划 §1.5）：输入里的 ID（实体、修改键与值里嵌的 ID、日志的卡 / 笔记 / `revokes`、标签的
//!   笔记）先按这个集合的别名表归一（`alias.rs` [Index::canonical]，命令开始时已收好的那张表），再写。不做「映射到已
//!   有别名成员」的过渡层。
//! - **没有跨 profile 的归属判定**：协议 3 的 `ownership.rs` 防的是「同一个 srs.db 里别的 profile 的实体」（带盐 ID
//!   撞号）；新代一个集合一个 `col`，所有主键带 `col`，别的集合的实体在这里根本不可见。回包的 `foreign` 恒为空数组。
//! - **回包**：命令自己的键之外，[write] 统一补上 `changed`（`[种类, 规范实体 ID]`，碰过的实体）、`purged`（彻底清除的
//!   实体）、`replayed`（写了日志的卡）、`edits`（`[种类, 实体, 字段键, 设备, 序号, 值]`，撤销据它判断之后有没有
//!   被别人动过，与协议 3 同形）、`nextSeq`（本机身份日志的下一个 seq）与 `settled`（这条命令里派生层收尾的计数，
//!   缓存层重算了多少笔记 / 卡 / 统计行）。协议 3 的 `marks` / `diagnostics` 是投影表的落库细节，新代没有。
//!
//! # 读现值
//!
//! 意图命令与 `chg` / 标签展开要读「此刻的值」：一律经派生层按别名类读（`class.rs` [Index::class_lines] /
//! [Index::class_tags]，缓存层同一份），读之前把这条命令已写的操作收尾（[Session::settled]）——所以「先写后读」读到的
//! 是包含本命令前面写入的状态，与协议 3 逐条投影之后再读相同。批内只为「需要读」收尾，纯日志的作答批不收尾到最后。

use std::collections::{BTreeSet, HashMap, HashSet};

use rusqlite::params;
use serde_json::{Map, Value, json};

use super::super::cache::CFG_KEY;
use super::super::derive::{Index, Ref, Settled};
use super::super::native::Native;
use super::super::schema::sql;
use super::super::truth::Truth;
use super::{profile_of, ref_of, with_profile};
use crate::gen4::translate::native_body4;
use crate::registers::{self, StoredEdit};
use crate::store::caches::NoteInfo;
use crate::store::sync2::config::{self, DeckTree};
use crate::store::sync2::{body_of_event, canonical};
use crate::sync2::id::{Id, Key};
use crate::sync2::op::{Body, EditBody, EntKind, Intent, LogBody};
use crate::sync2::replay::SNAPSHOT_KEY;
use crate::sync2::vv::OpId;

/// 一个实体的修改行（寄存器内核的落库行 JSON + server_time），`registers` 的输入。
pub(super) type Lines = Vec<(String, Option<i64>)>;

pub(super) fn stored(v: &[(String, Option<i64>)]) -> Vec<StoredEdit<'_>> {
    config::stored(v)
}

/// 一条写命令的会话：本机身份的写入者、这个集合的索引、回包里统一的那几项（见文件头「回包」）。
pub struct Session<'t, 'c> {
    pub(super) t: &'t Truth<'c>,
    pub(super) col: i64,
    /// 这个集合绑定的 profile uid：行 JSON 的分区键 `p`（与读命令同口径，`cmd/mod.rs`）。
    pub(super) profile: String,
    ix: Index<'t, 'c>,
    native: Native<'t, 'c>,
    /// 上次收尾之后写过操作。
    dirty: bool,
    /// 牌组树（日志的配置快照用）；落过非日志操作就作废重读（协议 3 `stamp_local_config` 同口径）。
    tree: Option<DeckTree>,
    edits: Vec<Value>,
    changed: BTreeSet<(String, String)>,
    purged: BTreeSet<(String, String)>,
    replayed: BTreeSet<String>,
    settled: Settled,
    written: u64,
}

/// 一条写命令（见文件头「一条命令一个事务」）：[f] 在 [Session] 里做命令本体，返回命令自己的回包（JSON 对象）；
/// 这里补上统一的那几项。回包带 `stale: true` 的（`apply` 的前置条件不成立）原样返回、什么都没写。
pub fn write<'c>(
    t: &Truth<'c>,
    col: i64,
    f: impl FnOnce(&mut Session<'_, 'c>) -> Result<Value, String>,
) -> Result<Value, String> {
    t.tx(|t| {
        let mut s = Session::open(t, col)?;
        let mut v = f(&mut s)?;
        if v.get("stale") == Some(&Value::Bool(true)) {
            if s.written > 0 {
                return Err("gen4 write: a stale command wrote ops".to_owned());
            }
            return Ok(v);
        }
        s.finish(&mut v)?;
        Ok(v)
    })
}

impl<'t, 'c> Session<'t, 'c> {
    fn open(t: &'t Truth<'c>, col: i64) -> Result<Session<'t, 'c>, String> {
        let profile = profile_of(t, col)?;
        let native = Native::open(t, col)?;
        Ok(Session {
            t,
            col,
            profile,
            ix: Index::new(t, col),
            native,
            dirty: false,
            tree: None,
            edits: Vec::new(),
            changed: BTreeSet::new(),
            purged: BTreeSet::new(),
            replayed: BTreeSet::new(),
            settled: Settled::default(),
            written: 0,
        })
    }

    /// 本机身份（作者）的设备 ID。
    pub(super) fn device(&self) -> Id {
        self.native.device()
    }

    /// 只查别名表的读（规范 ID）：不要求收尾，读的是命令开始时（或上次收尾时）的别名表。
    pub(super) fn ix(&self) -> &Index<'t, 'c> {
        &self.ix
    }

    /// 先把这条命令已写的操作收尾，再交出索引（按类读、读缓存表之前都走这里）。
    pub(super) fn settled(&mut self) -> Result<&mut Index<'t, 'c>, String> {
        if self.dirty {
            let st = self.ix.settle()?;
            absorb(&mut self.settled, &st);
            self.dirty = false;
        }
        Ok(&mut self.ix)
    }

    /// 派生层整个重建（`digest_heal`）：之后的读与收尾都基于重建结果。
    pub(super) fn rebuild(&mut self) -> Result<Settled, String> {
        let st =
            super::super::ingest::ingest_settle(self.t, &mut self.ix, self.col, ingest_mode())?;
        absorb(&mut self.settled, &st);
        self.dirty = false;
        self.tree = None;
        Ok(st)
    }

    /// 本机改了某台设备的信任状态：告诉派生层，收尾时重判扣住的删除与清除（`weigh.rs` [Index::trust_changed]）。
    pub(super) fn trust_changed(&mut self) {
        self.ix.trust_changed();
        self.dirty = true;
        self.tree = None;
    }

    // ------------------------------------------------------------ 写

    /// 落一条本机操作（协议 3 形的操作体：命令层的拼法与协议 3 共用）。先归一 ID（文件头「按规范 ID 写」），再转成
    /// 协议 4 原生操作体（[native_body4]：带旧戳 / 旧 HLC 的拒），经 [Native::write] 写。
    pub(super) fn land(&mut self, body: Body, now: i64) -> Result<OpId, String> {
        let body = self.canon_body(body)?;
        let note = |kind: EntKind, e: &Key| (kind.wire().to_owned(), e.text());
        match &body {
            Body::Entity { kind, id, .. } => {
                self.changed.insert(note(*kind, id));
            }
            Body::Edit(e) => {
                self.changed.insert(note(e.kind, &e.entity));
            }
            Body::TagAdd { note: n, .. }
            | Body::TagRemove { note: n, .. }
            | Body::TagOrder { note: n, .. } => {
                self.changed.insert(note(EntKind::Note, n));
            }
            Body::Purge { kind, entity } => {
                self.changed.insert(note(*kind, entity));
                self.purged.insert(note(*kind, entity));
            }
            Body::Log(l) => {
                self.replayed.insert(l.card.text());
            }
            _ => {}
        }
        if !matches!(body, Body::Log(_)) {
            self.tree = None;
        }
        let edit = match &body {
            Body::Edit(e) => Some((e.kind, e.entity.text(), e.key.clone(), e.value.clone())),
            _ => None,
        };
        let b4 = native_body4(body)?;
        let (id, _) = self.native.write(&mut self.ix, b4, now)?;
        self.dirty = true;
        self.written += 1;
        if let Some((kind, entity, key, value)) = edit {
            self.edits.push(json!([
                kind.wire(),
                entity,
                key,
                id.device.text(),
                id.seq,
                serde_json::from_str::<Value>(&value).unwrap_or(Value::Null),
            ]));
        }
        Ok(id)
    }

    /// 收尾，补上统一的回包项（文件头「回包」）。
    fn finish(&mut self, v: &mut Value) -> Result<(), String> {
        let st = self.native.finish(&mut self.ix)?;
        absorb(&mut self.settled, &st);
        self.dirty = false;
        let next = self.t.last_of(self.col, &self.native.device())? + 1;
        if !v.is_object() {
            *v = json!({});
        }
        let pairs = |s: &BTreeSet<(String, String)>| -> Value {
            Value::Array(s.iter().map(|(k, e)| json!([k, e])).collect())
        };
        let m = v.as_object_mut().expect("object");
        m.insert("changed".into(), pairs(&self.changed));
        m.insert("purged".into(), pairs(&self.purged));
        m.insert("replayed".into(), json!(self.replayed));
        m.insert(
            "edits".into(),
            Value::Array(std::mem::take(&mut self.edits)),
        );
        m.insert("nextSeq".into(), json!(next));
        m.insert(
            "settled".into(),
            json!({
                "cacheNotes": self.settled.cache_notes,
                "cacheCards": self.settled.cache_cards,
                "cacheStats": self.settled.cache_stats,
            }),
        );
        Ok(())
    }

    // ------------------------------------------------------------ 归一

    pub(super) fn canon(&self, k: &Key) -> Result<Key, String> {
        Ok(key_of(&self.ix.canonical(&Ref::of(k))?))
    }

    /// 文本 ID 的规范形。
    pub(super) fn canon_text(&self, s: &str) -> Result<String, String> {
        Ok(self.ix.canonical(&ref_of(s))?.text())
    }

    fn canon_body(&self, body: Body) -> Result<Body, String> {
        let ix = &self.ix;
        Ok(match body {
            Body::Entity { kind, id, data } => {
                let d: Value =
                    serde_json::from_str(&data).map_err(|e| format!("gen4 write: {e}"))?;
                Body::Entity {
                    kind,
                    id: self.canon(&id)?,
                    data: canonical(&ix.canonical_json(&d)?),
                }
            }
            Body::Edit(e) => {
                let key = ix.canonical_key(&e.key)?;
                let v: Value =
                    serde_json::from_str(&e.value).map_err(|x| format!("gen4 write: {x}"))?;
                Body::Edit(EditBody {
                    entity: self.canon(&e.entity)?,
                    value: canonical(&ix.canonical_value(&key, &v)?),
                    key,
                    ..e
                })
            }
            Body::Log(mut l) => {
                l.id = self.canon(&l.id)?;
                l.card = self.canon(&l.card)?;
                l.note = l.note.as_ref().map(|n| self.canon(n)).transpose()?;
                l.revokes = l.revokes.as_ref().map(|r| self.canon(r)).transpose()?;
                Body::Log(l)
            }
            Body::TagAdd { note, tag } => Body::TagAdd {
                note: self.canon(&note)?,
                tag,
            },
            Body::TagRemove { note, tag } => Body::TagRemove {
                note: self.canon(&note)?,
                tag,
            },
            Body::TagOrder { note, tags } => Body::TagOrder {
                note: self.canon(&note)?,
                tags,
            },
            Body::Purge { kind, entity } => Body::Purge {
                kind,
                entity: self.canon(&entity)?,
            },
            other => other,
        })
    }

    // ------------------------------------------------------------ 读现值

    /// 一个实体（任何别名）按类判定活着的修改行（规范形）。读之前收尾（文件头「读现值」）。
    pub(super) fn lines(&mut self, kind: EntKind, id: &str) -> Result<Lines, String> {
        let ix = self.settled()?;
        Ok(ix.class_lines(kind, &ref_of(id))?.0)
    }

    /// 一条笔记此刻的视图（协议 3 `caches::note_infos` 的新代版：身份记录的胜者 + 按类判定的修改 + 标签 OR-Set）。
    /// 不存在 / 不是笔记 / 身份记录不成形 = None（缓存层同口径，`cache.rs` 文件头「与协议 3 的差别」）。`id` 字段是
    /// 规范 ID。
    pub(super) fn note_info(&mut self, id: &str) -> Result<Option<NoteInfo>, String> {
        let r = ref_of(id);
        let ix = self.settled()?;
        let Some((kind, _, payload)) = ix.definition(&r)? else {
            return Ok(None);
        };
        if kind != EntKind::Note as i64 {
            return Ok(None);
        }
        let canon = ix.canon(&r)?;
        let (lines, _) = ix.class_lines(EntKind::Note, &canon)?;
        let Ok(mut view) = registers::note_view_of(&payload, &stored(&lines)) else {
            return Ok(None);
        };
        view["t"] = json!(ix.class_tags(&canon)?);
        Ok(Some(NoteInfo::of(&canon.text(), &view)))
    }

    /// 一条笔记（任何别名）的卡片缓存行，按卡 ID：(卡, 模板, cloze 序号, 隐藏, 牌组)。缓存层没配置（宿主没给缓存
    /// 配置、`cards` 不物化）时报错——这些命令要的「此刻有哪些卡」只有缓存层知道，静默当成没有卡会写错。
    pub(super) fn note_cards(&mut self, note: &str) -> Result<Vec<CardRow>, String> {
        self.require_caches()?;
        let n = ref_of(note);
        let (col, canon) = {
            let ix = self.settled()?;
            (ix.col, ix.canon(&n)?)
        };
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT id, template_id, cloze_ord, hidden, deck_id FROM cards \
                 WHERE col = ?1 AND note_id = ?2 ORDER BY id",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![col, canon], |r| {
                Ok(CardRow {
                    card: r.get::<_, Ref>(0)?.text(),
                    template: r.get::<_, Ref>(1)?.text(),
                    ord: r.get(2)?,
                    hidden: r.get::<_, i64>(3)? != 0,
                    deck: r.get::<_, Ref>(4)?.text(),
                })
            })
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    /// 缓存层没配置就报错（见 [Session::note_cards]）。
    pub(super) fn require_caches(&self) -> Result<(), String> {
        if self.t.derive_cfg(self.col, CFG_KEY)?.is_none() {
            return Err("gen4 write: the caches are not configured for this collection".to_owned());
        }
        Ok(())
    }

    /// 默认牌组（规范 ID）：缓存配置给了就用它（归一后，与缓存层同一个），否则是规范规则的内置默认牌组（常量）。
    pub(super) fn default_deck(&self) -> Result<String, String> {
        super::default_deck(self.t, &self.ix, self.col)
    }

    /// 此刻的牌组树（未删除的牌组，ID 是规范 ID；[super::deck_tree]）。命令里落过非日志操作就重读。
    pub(super) fn deck_tree(&mut self) -> Result<&DeckTree, String> {
        if self.tree.is_none() {
            let default = self.default_deck()?;
            let ix = self.settled()?;
            self.tree = Some(super::deck_tree(ix, default)?);
        }
        Ok(self.tree.as_ref().expect("tree just loaded"))
    }

    /// 卡（规范 ID）的有效牌组（只读规则 [super::card_deck]；读之前先收尾，同 [Session::lines]）。
    pub(super) fn card_deck(&mut self, card: &str, note: Option<&str>) -> Result<String, String> {
        self.deck_tree()?;
        let tree = self.tree.take().expect("tree just loaded");
        let r = self
            .settled()
            .and_then(|ix| super::card_deck(ix, &tree, card, note));
        self.tree = Some(tree);
        r
    }

    /// 本机新写的派生日志记下此刻的生效配置（协议 3 `stamp_config`；重放按它算，改配置不追溯）。`Absolute` 意图的
    /// 日志（结果照抄）不盖。
    pub(super) fn stamp_config(&mut self, l: &mut LogBody) -> Result<(), String> {
        if matches!(l.intent, Intent::Absolute) {
            return Ok(());
        }
        let card = self.canon_text(&l.card.text())?;
        let note = l
            .note
            .as_ref()
            .map(|n| self.canon_text(&n.text()))
            .transpose()?;
        let deck = self.card_deck(&card, note.as_deref())?;
        let cfg = self.deck_tree()?.config(&deck).to_json();
        let mut extra: Map<String, Value> = match serde_json::from_str::<Value>(&l.extra) {
            Ok(Value::Object(m)) => m,
            _ => Map::new(),
        };
        extra.insert(SNAPSHOT_KEY.into(), cfg);
        l.extra = canonical(&Value::Object(extra));
        Ok(())
    }
}

/// 卡片缓存的一行（[Session::note_cards]）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct CardRow {
    pub(super) card: String,
    pub(super) template: String,
    pub(super) ord: i64,
    pub(super) hidden: bool,
    pub(super) deck: String,
}

fn ingest_mode() -> super::super::ingest::Settle {
    super::super::ingest::Settle::Rebuild
}

pub(super) fn key_of(r: &Ref) -> Key {
    match r {
        Ref::Uuid(b) => Key::Uuid(Id(*b)),
        Ref::Text(s) => Key::Text(s.clone()),
    }
}

/// 把一次收尾的计数加进总数。
fn absorb(total: &mut Settled, s: &Settled) {
    total.registers += s.registers;
    total.judged += s.judged;
    total.entities += s.entities;
    total.logs += s.logs;
    total.closures += s.closures;
    total.purged += s.purged;
    total.holds += s.holds;
    total.notes += s.notes;
    total.media += s.media;
    total.scanned += s.scanned;
    total.aliases += s.aliases;
    total.aliases_proven += s.aliases_proven;
    total.digests += s.digests;
    total.cache_notes += s.cache_notes;
    total.cache_cards += s.cache_cards;
    total.cache_stats += s.cache_stats;
}

pub(super) fn now_of(req: &Value) -> Result<i64, String> {
    req.get("now")
        .and_then(Value::as_i64)
        .ok_or_else(|| "gen4 write: missing now".to_owned())
}

/// 测试注入：请求带 `failAfter: <段>` 时在做完那一段之后报错（验证整笔回滚；生产调用方不带）。协议 3 的意图命令
/// 同一个约定。
pub(super) fn fail_after(req: &Value, stage: &str) -> Result<(), String> {
    if req["failAfter"].as_str() == Some(stage) {
        return Err(format!("gen4 write: injected failure after {stage}"));
    }
    Ok(())
}

// ---------------------------------------------------------------------- apply

/// [apply_in] 的选项。
#[derive(Clone, Copy, Debug, Default)]
pub(super) struct ApplyOpts {
    /// 收不收 `chg` 项（`import_drafts` 不收）。
    pub(super) chg: bool,
    /// `chg` 筛掉的项不进 `landed`（协议 3 `change_on` 先就地筛掉输入项再走 `apply`，`landed` 只对留下的项）。
    pub(super) compact: bool,
}

/// 一项输入解析出的操作体，与它带的标记。
struct Item {
    body: Body,
    chg: bool,
}

/// 协议 3 的修改记录草稿（Dart `_applyInput` 为一条草稿发的那一项，意图命令拼输入用）。
pub(super) fn draft(
    profile: &str,
    kind: &str,
    entity: &str,
    key: &str,
    v: &Value,
    ts: &str,
) -> Value {
    json!({
        "e": {"t": "edit", "x": {"p": profile, "k": kind, "e": entity, "f": key, "v": v, "ts": ts}},
        "note": Value::Null,
    })
}

/// 一项输入 → 协议 3 形的操作体（文件头「只写协议 4 原生能收的形」）。
fn parse_item(it: &Value) -> Result<Item, String> {
    if it["stamped"] == Value::Bool(true) {
        return Err(
            "apply: stamped items carry a foreign identity; in gen4 they come in through a collection join"
                .to_owned(),
        );
    }
    let ev = &it["e"];
    if !matches!(ev["t"].as_str(), Some("entity" | "edit" | "log")) {
        return Err(format!(
            "apply: event type {:?} is not written by gen4",
            ev["t"]
        ));
    }
    let body = body_of_event(ev, it["note"].as_str(), false, None)?;
    let body = match (body, it["intent"].as_str()) {
        (Body::Log(mut l), Some("answer")) => {
            l.intent = Intent::Answer;
            Body::Log(l)
        }
        (_, Some(other)) => return Err(format!("apply: unknown intent {other}")),
        (b, None) => b,
    };
    let body = match body {
        Body::Log(mut l) => {
            l.legacy_hlc = None;
            l.legacy_server_time = None;
            Body::Log(l)
        }
        b => b,
    };
    let chg = it["chg"] == Value::Bool(true);
    if chg {
        if !matches!(body, Body::Edit(_)) {
            return Err("apply: chg on an item that is not an edit".into());
        }
        if it["init"] == Value::Bool(true) {
            return Err("apply: chg cannot be combined with init / stamped".into());
        }
    }
    Ok(Item { body, chg })
}

/// `apply` 的本体（协议 3 `apply_local_on` 的新代版），在 [s] 里做；意图命令拼好输入也走这里。回包
/// `{"landed": [每项落没落], "foreign": []}`，`landed` 与 [items] 等长：`chg` 筛掉的、标签写入展开为空的是 false。
///
/// - `chg`（store/sync2/changing.rs 的判据，[registers::write_is_noop]）：值没变的修改不写；同一批里同一个
///   (种类, 实体, 字段键) 按顺序判，后一项比前一项写下的值。
/// - 标签是 OR-Set：整列表 `tags` 按与此刻的值的差拆成添加 / 观察删除 + 一条显示顺序（协议 3 `expand_tags`）；此刻
///   的值含这一批前面写下的标签。
/// - 非 `Absolute` 的日志盖此刻的配置快照（[Session::stamp_config]）。
pub(super) fn apply_in(
    s: &mut Session<'_, '_>,
    now: i64,
    items: &[Value],
    opts: ApplyOpts,
) -> Result<Value, String> {
    let mut parsed = Vec::with_capacity(items.len());
    for it in items {
        let item = parse_item(it)?;
        if item.chg && !opts.chg {
            return Err("import_drafts: chg items are not accepted".into());
        }
        // 归一提前做：`chg` 与标签的判定按规范的 (种类, 实体, 键) 比。
        let body = s.canon_body(item.body)?;
        parsed.push(Item { body, ..item });
    }
    let keep = drop_noops(s, &parsed)?;
    // 标签：这一批要碰的笔记此刻的标签（批内写过的按批内的算，见 [expand_tags]）。
    let mut tags_now: HashMap<String, Vec<String>> = HashMap::new();
    let mut landed = vec![false; parsed.len()];
    for (at, item) in parsed.into_iter().enumerate() {
        if !keep[at] {
            continue;
        }
        // 已有的实体再发一遍身份记录：照样追加（同协议 3），但不算「落了」——协议 3 的 `landed` 是「投影里有东西
        // 变了」，身份记录只在实体第一次出现时投影（`Marks::entity`）。批内前面刚建的同一个实体也算已有。
        if let Body::Entity { id, .. } = &item.body {
            let existed = s.settled()?.definition(&Ref::of(id))?.is_some();
            s.land(item.body, now)?;
            landed[at] = !existed;
            continue;
        }
        let bodies = match item.body {
            Body::Edit(e) if e.kind == EntKind::Note && e.key == "tags" => {
                expand_tags(s, &mut tags_now, e)?
            }
            Body::Log(mut l) => {
                s.stamp_config(&mut l)?;
                vec![Body::Log(l)]
            }
            b => vec![b],
        };
        for b in bodies {
            s.land(b, now)?;
            landed[at] = true;
        }
    }
    if opts.compact {
        let landed: Vec<bool> = landed
            .into_iter()
            .zip(&keep)
            .filter(|(_, k)| **k)
            .map(|(l, _)| l)
            .collect();
        return Ok(json!({"landed": landed, "foreign": []}));
    }
    Ok(json!({"landed": landed, "foreign": []}))
}

/// `chg` 筛选（见 [apply_in]）：每项留不留。
fn drop_noops(s: &mut Session<'_, '_>, items: &[Item]) -> Result<Vec<bool>, String> {
    let mut keep = vec![true; items.len()];
    if !items.iter().any(|i| i.chg) {
        return Ok(keep);
    }
    // 这一批前面的项给 (种类, 实体, 键) 写下的值。
    let mut written: HashMap<(EntKind, String, String), Value> = HashMap::new();
    let mut current: HashMap<(EntKind, String), Lines> = HashMap::new();
    for (at, it) in items.iter().enumerate() {
        let Body::Edit(e) = &it.body else { continue };
        let slot = (e.kind, e.entity.text(), e.key.clone());
        let value: Value = serde_json::from_str(&e.value).unwrap_or(Value::Null);
        if it.chg {
            let noop = match written.get(&slot) {
                Some(prev) => *prev == value,
                None if e.kind == EntKind::Note && e.key == "tags" => {
                    tags_unchanged(s, &e.entity.text(), &value)?
                }
                None => {
                    let ent = (e.kind, e.entity.text());
                    if !current.contains_key(&ent) {
                        let l = s.lines(e.kind, &ent.1)?;
                        current.insert(ent.clone(), l);
                    }
                    registers::write_is_noop(&stored(&current[&ent]), &e.key, &value)?
                }
            };
            keep[at] = !noop;
        }
        written.insert(slot, value);
    }
    Ok(keep)
}

/// `chg` 的整列表 `tags` 项「没变」（[drop_noops]）。协议 3 的投影给碰过标签的每条笔记写一行合成的 `tags` 修改行，值
/// 是此刻的标签（`semantics.rs` `tags_row`），`write_is_noop` 拿它逐值比；新代的修改行里没有这行（标签是 `tag_ix`
/// 的 OR-Set，缓存层直接给结果），所以照协议 3 的口径单独判：这条笔记（别名类）有过标签操作（= 协议 3 有那行合成
/// 行），且此刻的标签（[Index::class_tags]）与 [value] 逐值相同。从没碰过标签的笔记没有那行，协议 3 判「变了」，这里同。
fn tags_unchanged(s: &mut Session<'_, '_>, note: &str, value: &Value) -> Result<bool, String> {
    let ix = s.settled()?;
    let canon = ix.canon(&ref_of(note))?;
    let mut touched = false;
    for m in ix.members(&canon)? {
        if !ix.tags_rows(&m)?.is_empty() {
            touched = true;
            break;
        }
    }
    if !touched {
        return Ok(false);
    }
    let now = Value::from(ix.class_tags(&canon)?);
    Ok(registers::same_value(&now, value))
}

/// 整列表 `tags` → OR-Set 操作（协议 3 `expand_tags` 同一份拼法）。[tags_now] 记这一批里每条笔记写到哪了。
fn expand_tags(
    s: &mut Session<'_, '_>,
    tags_now: &mut HashMap<String, Vec<String>>,
    e: EditBody,
) -> Result<Vec<Body>, String> {
    let note = e.entity.text();
    let cur = match tags_now.get(&note) {
        Some(t) => t.clone(),
        None => {
            let ix = s.settled()?;
            ix.class_tags(&ref_of(&note))?
        }
    };
    let want: Vec<String> = match serde_json::from_str::<Value>(&e.value) {
        Ok(Value::Array(xs)) => xs
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect(),
        _ => Vec::new(),
    };
    let mut out: Vec<Body> = Vec::new();
    for tag in want.iter().filter(|x| !cur.contains(x)) {
        out.push(Body::TagAdd {
            note: e.entity.clone(),
            tag: tag.clone(),
        });
    }
    for tag in cur.iter().filter(|x| !want.contains(x)) {
        out.push(Body::TagRemove {
            note: e.entity.clone(),
            tag: tag.clone(),
        });
    }
    let mut seen = BTreeSet::new();
    let order: Vec<String> = want
        .iter()
        .filter(|t| seen.insert((*t).clone()))
        .cloned()
        .collect();
    if order != cur || !out.is_empty() {
        out.push(Body::TagOrder {
            note: e.entity.clone(),
            tags: order.clone(),
        });
    }
    tags_now.insert(note, order);
    Ok(out)
}

/// `apply` 的前置条件 `expectLast: {card, log}`（远程作答核对基准，协议 3 `store/ffi.rs` `expect_last_holds`）：这张卡
/// 的缓存行还在、且它最后一条生效日志就是 `log`（null = 还没有日志）。不带 = 成立。按规范 ID 比。
fn expect_last_holds(s: &mut Session<'_, '_>, req: &Value) -> Result<bool, String> {
    let Some(expect) = req.get("expectLast").filter(|e| e.is_object()) else {
        return Ok(true);
    };
    let card = expect["card"]
        .as_str()
        .ok_or("apply: missing expectLast.card")?;
    let card = ref_of(&s.canon_text(card)?);
    let col = s.col;
    let last: Option<Option<Ref>> = {
        let ix = s.settled()?;
        let mut stmt =
            ix.t.conn()
                .prepare_cached("SELECT last_log_id FROM cards WHERE col = ?1 AND id = ?2")
                .map_err(sql)?;
        let mut rows = stmt.query(params![col, card]).map_err(sql)?;
        match rows.next().map_err(sql)? {
            Some(r) => Some(r.get::<_, Option<Ref>>(0).map_err(sql)?),
            None => None,
        }
    };
    let want = expect["log"]
        .as_str()
        .map(|l| s.canon_text(l))
        .transpose()?;
    Ok(last.is_some_and(|l| l.map(|r| r.text()) == want))
}

/// `apply`（协议 3 `local_write_body` 的 `apply` 分支 + `expectLast`）。[req]：`{"now", "expectLast"?}`；[items]：输入
/// 项（JSON 数组，同协议 3）。前置条件不成立 = `{"stale": true}`、什么都不写。
pub fn apply(t: &Truth<'_>, col: i64, req: &Value, items: &[Value]) -> Result<Value, String> {
    let now = now_of(req)?;
    if req.get("stamps") == Some(&Value::Bool(true)) {
        return Err(
            "apply: stamps belong to the protocol 3 legacy clock, which gen4 does not keep"
                .to_owned(),
        );
    }
    write(t, col, |s| {
        if !expect_last_holds(s, req)? {
            return Ok(json!({"stale": true}));
        }
        apply_in(
            s,
            now,
            items,
            ApplyOpts {
                chg: true,
                compact: false,
            },
        )
    })
}

/// `import_drafts`（导入攒的一批草稿，协议 3 `import_drafts_on`）：[apply_in] 的本体，外加
///
/// - 输入项 `init: true` 是「新建实体的初值」：这个 (种类, 实体, 字段键) 落库这一刻已经有活着的修改（攒批期间同步
///   把对端的同一实体应用进来了）就不落——判据是这一批写之前的库；
/// - 回包 `existed`：这批身份记录里落库前就已存在的实体 ID（按调用方给的 ID，升序去重）。
///
/// 不收 `chg` 项。`landed` 按去掉不落的项之后的顺序（同协议 3）。
pub fn import_drafts(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    items: &[Value],
) -> Result<Value, String> {
    let now = now_of(req)?;
    write(t, col, |s| {
        let mut existed: BTreeSet<String> = BTreeSet::new();
        for it in items {
            if it["e"]["t"].as_str() != Some("entity") {
                continue;
            }
            let Some(id) = it["e"]["x"]["id"].as_str() else {
                continue;
            };
            let ix = s.settled()?;
            if ix.definition(&ref_of(id))?.is_some() {
                existed.insert(id.to_owned());
            }
        }
        let is_init =
            |it: &Value| it["init"] == Value::Bool(true) && it["e"]["t"].as_str() == Some("edit");
        let mut authored: HashSet<(String, String, String)> = HashSet::new();
        let mut seen: HashSet<(String, String)> = HashSet::new();
        for it in items.iter().filter(|it| is_init(it)) {
            let x = &it["e"]["x"];
            let (Some(k), Some(e)) = (x["k"].as_str(), x["e"].as_str()) else {
                continue;
            };
            if !seen.insert((k.to_owned(), e.to_owned())) {
                continue;
            }
            let kind = EntKind::parse(k).ok_or("import_drafts: unknown entity kind")?;
            for (json, _) in s.lines(kind, e)? {
                let v: Value = serde_json::from_str(&json).unwrap_or(Value::Null);
                if let Some(f) = v["f"].as_str() {
                    authored.insert((k.to_owned(), e.to_owned(), f.to_owned()));
                }
            }
        }
        let mut kept: Vec<Value> = Vec::with_capacity(items.len());
        for it in items {
            if is_init(it) {
                let x = &it["e"]["x"];
                if let (Some(k), Some(e), Some(f)) =
                    (x["k"].as_str(), x["e"].as_str(), x["f"].as_str())
                {
                    // 活着的修改行的键是规范形；输入的键归一了再比。
                    let f = s.ix().canonical_key(f)?;
                    if authored.contains(&(k.to_owned(), e.to_owned(), f)) {
                        continue;
                    }
                }
            }
            kept.push(it.clone());
        }
        let mut v = apply_in(
            s,
            now,
            &kept,
            ApplyOpts {
                chg: false,
                compact: false,
            },
        )?;
        v["existed"] = json!(existed);
        Ok(v)
    })
}

/// `purge`（彻底清除一批同类实体，协议 3 `local_write_body` 的 `purge` 分支）：每个实体「删除 + 清除」两条操作，按
/// 输入顺序，一笔落下。[req]：`{"now", "kind", "entities": [...]}`（非空）。不存在 / 已清除过的照常追加（清除幂等）。
pub fn purge(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let kind = req["kind"].as_str().ok_or("purge: missing kind")?;
    let entities = req
        .get("entities")
        .and_then(Value::as_array)
        .filter(|e| !e.is_empty())
        .ok_or("purge: missing entities")?;
    let mut bodies = Vec::with_capacity(entities.len() * 2);
    for e in entities {
        let e = e.as_str().ok_or("purge: entity is not a string")?;
        bodies.extend(crate::store::sync2::purge_bodies(kind, e, now)?);
    }
    write(t, col, |s| {
        for b in bodies {
            s.land(b, now)?;
        }
        Ok(json!({}))
    })
}

/// `checkpoint`（还原点）。[req]：`{"now", "name", "reason"}`。
pub fn checkpoint(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let name = req["name"].as_str().ok_or("checkpoint: missing name")?;
    let reason = req["reason"].as_str().ok_or("checkpoint: missing reason")?;
    write(t, col, |s| {
        for b in crate::store::sync2::checkpoint_bodies(name, reason) {
            s.land(b, now)?;
        }
        Ok(json!({}))
    })
}

/// 冲突 ID（协议 3 `semantics.rs` 写 `sync2_conflicts` 的同一个公式）：被扣住的删除的 (设备, seq) 与冲突类别。
pub(super) fn conflict_id(op: &OpId, kind: &str) -> String {
    blake3::hash(format!("{}:{}:{kind}", op.device.text(), op.seq).as_bytes()).to_hex()[..32]
        .to_owned()
}

/// `resolve`（裁决一个删除冲突，协议 3 `resolve_bodies`）：`delete` = 一条因果覆盖并发方的新删除；否则一条覆盖删除
/// 的恢复。[req]：`{"now", "conflict", "delete"?}`。冲突按 ID 在此刻被扣住的删除里找（新代的冲突就是
/// `hold_ix`，`weigh.rs` [Index::holds]；ID 与协议 3 同一个公式，[conflict_id]）；找不到 = 报错（协议 3 同）。
pub fn resolve(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let conflict = req["conflict"]
        .as_str()
        .ok_or("resolve: missing conflict")?;
    let delete = req["delete"] == Value::Bool(true);
    write(t, col, |s| {
        let ix = s.settled()?;
        let mut target: Option<(EntKind, String)> = None;
        for h in ix.holds()? {
            let kinds = [
                (h.edits, "delete_edit"),
                (h.reviews, "delete_review"),
                (h.moves, "delete_move"),
            ];
            if kinds
                .iter()
                .any(|(n, k)| *n > 0 && conflict_id(&h.op, k) == conflict)
            {
                target = Some((h.kind, h.entity.text()));
                break;
            }
        }
        let (kind, entity) = target.ok_or_else(|| format!("no such conflict {conflict}"))?;
        for b in crate::store::sync2::resolve_bodies(kind, &entity, delete, now) {
            s.land(b, now)?;
        }
        Ok(json!({}))
    })
}

/// 行 JSON 换上这个集合的 profile（读命令同一个约定）。
pub(super) fn row_with_profile(json: &str, profile: &str) -> Value {
    serde_json::from_str(&with_profile(json, profile)).unwrap_or(Value::Null)
}
