//! 同步 v2 在 srs.db 上的持久化（设计 §3、§6、§7；计划 P3 / P4 的 Rust 侧）。
//!
//! - `sync2_ops` 是唯一事实表；`srs_entities` / `srs_field_edits` / `srs_review_logs` /
//!   `srs_unknown_events` 是它的投影（读侧——字段寄存器、缓存刷新、统计、优化器、RWKV——一行不改）。
//! - 本机写入（[SrsCore::sync2_apply_local]）：Dart 照旧组好事件，这里分配 OpId / HLC / 因果上下文，
//!   改写修改记录的 dot 为 (设备, seq)、日志的 HLC 为本设备，落 ops、落投影、重放受影响的卡。
//! - 远端操作（transport.rs）走同一条投影与重放路径；按设备连续前缀、因果满足才应用。
//! - 卡片调度状态由重放推出（sync2::replay），写回投影行的 `res`。
//!
//! 所有命令在写连接上的一个 SAVEPOINT 里做：Dart 的 Drift 事务开着时嵌在里面，没开时自成事务。

pub mod config;
pub mod media;
pub(crate) mod mvr;
pub mod relay;
pub mod schema;
pub(crate) mod semantics;
pub mod timeline;
pub mod transport;

use std::collections::BTreeSet;
use std::sync::Arc;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Map, Value};

use crate::sync2::dvv::Dvv;
use crate::sync2::hlc::{Clock, Hlc};
use crate::sync2::id::{Id, Key};
use crate::sync2::keys::DeviceKey;
use crate::sync2::op::{self, Body, EditBody, EntKind, Intent, LegacyStamp, LogBody, Op};
use crate::sync2::replay::{self, infer_intent, Row};
use crate::sync2::segment::{chain_next, Chain, CHAIN_ZERO};
use crate::sync2::vv::{OpId, Vv};

use super::SrsCore;

pub(crate) fn sql<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

/// 在 SAVEPOINT 里跑（外面有 Drift 事务就嵌套，没有就自成事务）。
pub(crate) fn in_savepoint<T>(conn: &Connection, f: impl FnOnce(&Connection) -> Result<T, String>) -> Result<T, String> {
    conn.execute_batch("SAVEPOINT sync2").map_err(sql)?;
    match f(conn) {
        Ok(v) => {
            conn.execute_batch("RELEASE sync2").map_err(sql)?;
            Ok(v)
        }
        Err(e) => {
            let _ = conn.execute_batch("ROLLBACK TO sync2; RELEASE sync2");
            Err(e)
        }
    }
}

/// 一个 profile 的集合 ID：由 profile uid 确定性派生（各设备不用协调就是同一个集合）。
pub fn collection_of(profile: &str) -> Id {
    Id::v5(&Id::parse(config::SRS_NAMESPACE).expect("ns"), &format!("sync2/collection/{profile}"))
}

/// 本机在某 profile 集合里的身份与写入状态。
pub(crate) struct Local {
    pub profile: String,
    pub collection: Id,
    pub device: Id,
    pub key: DeviceKey,
    pub next_seq: u64,
    pub chain: Chain,
    pub clock: Clock,
    pub head_gen: u64,
    pub migrated: bool,
    pub name: String,
}

fn id_of(b: Vec<u8>) -> Result<Id, String> {
    let a: [u8; 16] = b.try_into().map_err(|_| "bad id blob".to_string())?;
    Ok(Id(a))
}

fn chain_of(b: Vec<u8>) -> Result<Chain, String> {
    b.try_into().map_err(|_| "bad chain blob".to_string())
}

impl Local {
    pub fn load(conn: &Connection, profile: &str) -> Result<Option<Local>, String> {
        conn.query_row(
            "SELECT collection, device, key_seed, next_seq, chain, hlc_wall, hlc_logical, head_gen, migrated_at, name \
             FROM sync2_self WHERE profile_uid = ?1",
            [profile],
            |r| {
                Ok((
                    r.get::<_, Vec<u8>>(0)?,
                    r.get::<_, Vec<u8>>(1)?,
                    r.get::<_, Vec<u8>>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, Vec<u8>>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, i64>(7)?,
                    r.get::<_, Option<i64>>(8)?,
                    r.get::<_, String>(9)?,
                ))
            },
        )
        .optional()
        .map_err(sql)?
        .map(|(c, d, k, n, ch, w, l, g, m, name)| {
            let device = id_of(d)?;
            let seed: [u8; 32] = k.try_into().map_err(|_| "bad key".to_string())?;
            let mut clock = Clock::new(device);
            clock.last = Hlc { wall: w, logical: l as u32, device };
            Ok(Local {
                profile: profile.to_owned(),
                collection: id_of(c)?,
                device,
                key: DeviceKey::from_seed(&seed),
                next_seq: n as u64,
                chain: chain_of(ch)?,
                clock,
                head_gen: g as u64,
                migrated: m.is_some(),
                name,
            })
        })
        .transpose()
    }

    /// 新身份（首次启用 v2，或分叉后换身份，设计 §7.3）。
    pub fn create(conn: &Connection, profile: &str, now: i64) -> Result<Local, String> {
        let device = Id::new_v7(now.max(0) as u64);
        let key = DeviceKey::generate();
        let local = Local {
            profile: profile.to_owned(),
            collection: collection_of(profile),
            device,
            key,
            next_seq: 1,
            chain: CHAIN_ZERO,
            clock: Clock::new(device),
            head_gen: 0,
            migrated: false,
            name: String::new(),
        };
        conn.execute(
            "INSERT INTO sync2_self (profile_uid, collection, device, key_seed, next_seq, chain) VALUES (?1, ?2, ?3, ?4, 1, ?5) \
             ON CONFLICT(profile_uid) DO UPDATE SET collection = excluded.collection, device = excluded.device, \
             key_seed = excluded.key_seed, next_seq = 1, chain = excluded.chain, hlc_wall = 0, hlc_logical = 0, head_gen = 0",
            params![profile, local.collection.0.to_vec(), device.0.to_vec(), local.key.seed().to_vec(), CHAIN_ZERO.to_vec()],
        )
        .map_err(sql)?;
        conn.execute(
            "INSERT OR REPLACE INTO sync2_devices (profile_uid, device, public, applied, chain) VALUES (?1, ?2, ?3, 0, ?4)",
            params![profile, device.0.to_vec(), local.key.public().to_vec(), CHAIN_ZERO.to_vec()],
        )
        .map_err(sql)?;
        Ok(local)
    }

    pub fn save(&self, conn: &Connection) -> Result<(), String> {
        conn.execute(
            "UPDATE sync2_self SET next_seq = ?2, chain = ?3, hlc_wall = ?4, hlc_logical = ?5, head_gen = ?6 WHERE profile_uid = ?1",
            params![
                self.profile,
                self.next_seq as i64,
                self.chain.to_vec(),
                self.clock.last.wall,
                i64::from(self.clock.last.logical),
                self.head_gen as i64
            ],
        )
        .map_err(sql)?;
        conn.execute(
            "UPDATE sync2_devices SET applied = ?3, chain = ?4 WHERE profile_uid = ?1 AND device = ?2",
            params![self.profile, self.device.0.to_vec(), (self.next_seq - 1) as i64, self.chain.to_vec()],
        )
        .map_err(sql)?;
        Ok(())
    }
}

/// 本机已应用的版本向量（含本设备）。
pub(crate) fn applied_vv(conn: &Connection, profile: &str) -> Result<Vv, String> {
    let mut stmt = conn.prepare_cached("SELECT device, applied FROM sync2_devices WHERE profile_uid = ?1").map_err(sql)?;
    let mut q = stmt.query([profile]).map_err(sql)?;
    let mut vv = Vv::new();
    while let Some(r) = q.next().map_err(sql)? {
        vv.set(id_of(r.get(0).map_err(sql)?)?, r.get::<_, i64>(1).map_err(sql)? as u64);
    }
    Ok(vv)
}

fn intern_deps(conn: &Connection, deps: &Vv) -> Result<i64, String> {
    let bytes = deps.encode();
    conn.prepare_cached("INSERT OR IGNORE INTO sync2_deps (vv) VALUES (?1)").map_err(sql)?.execute([&bytes]).map_err(sql)?;
    conn.prepare_cached("SELECT id FROM sync2_deps WHERE vv = ?1").map_err(sql)?.query_row([&bytes], |r| r.get(0)).map_err(sql)
}

pub(crate) fn insert_op(conn: &Connection, profile: &str, op: &Op, chain: &Chain, now: i64) -> Result<(), String> {
    let deps = intern_deps(conn, &op.deps)?;
    conn.prepare_cached(
        "INSERT INTO sync2_ops (profile_uid, device, seq, wall, logical, deps, kind, schema, payload, purged, chain, received_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
    )
    .map_err(sql)?
    .execute(params![
        profile,
        op.id.device.0.to_vec(),
        op.id.seq as i64,
        op.hlc.wall,
        i64::from(op.hlc.logical),
        deps,
        i64::from(op.kind),
        i64::from(op.schema),
        &op.payload[..],
        i64::from(op.purged),
        chain.to_vec(),
        now
    ])
    .map_err(sql)?;
    Ok(())
}

/// 读一条操作（因果判定、前缀闭包、重签发用）。
pub(crate) fn load_op(conn: &Connection, profile: &str, id: &OpId) -> Result<Option<Op>, String> {
    conn.prepare_cached(
        "SELECT o.wall, o.logical, d.vv, o.kind, o.schema, o.payload, o.purged FROM sync2_ops o JOIN sync2_deps d ON d.id = o.deps \
         WHERE o.profile_uid = ?1 AND o.device = ?2 AND o.seq = ?3",
    )
    .map_err(sql)?
    .query_row(params![profile, id.device.0.to_vec(), id.seq as i64], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, Vec<u8>>(2)?,
            r.get::<_, i64>(3)?,
            r.get::<_, i64>(4)?,
            r.get::<_, Vec<u8>>(5)?,
            r.get::<_, i64>(6)? != 0,
        ))
    })
    .optional()
    .map_err(sql)?
    .map(|(w, l, vv, k, s, p, purged)| {
        let deps = Vv::read(&mut crate::sync2::codec::Reader::new(&vv)).map_err(|e| e.to_string())?;
        Ok(Op {
            id: *id,
            hlc: Hlc { wall: w, logical: l as u32, device: id.device },
            deps: Arc::new(deps),
            kind: k as u16,
            schema: s as u16,
            payload: p.into(),
            purged,
        })
    })
    .transpose()
}

// ---------------------------------------------------------------- 旧修改记录的因果闭包

/// `L(vv)`：这个版本向量覆盖的操作里，迁移进来的旧修改记录的旧 dot 与旧上下文之并（见 dvv.rs）。
pub(crate) fn legacy_closure(conn: &Connection, profile: &str, vv: &Vv) -> Result<Dvv, String> {
    let mut out = Dvv::default();
    for (d, &s) in &vv.0 {
        let row: Option<(i64, String)> = conn
            .prepare_cached("SELECT upto, ctx FROM sync2_legacy WHERE profile_uid = ?1 AND device = ?2")
            .map_err(sql)?
            .query_row(params![profile, d.0.to_vec()], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()
            .map_err(sql)?;
        let Some((upto, ctx)) = row else { continue };
        if s as i64 >= upto {
            out.merge(&Dvv::parse(&ctx));
            continue;
        }
        // 只覆盖了这台设备迁移操作的一部分（少见）：逐条并到 s 为止。
        let mut stmt = conn
            .prepare_cached("SELECT payload FROM sync2_ops WHERE profile_uid = ?1 AND device = ?2 AND seq <= ?3 AND kind = ?4")
            .map_err(sql)?;
        let mut q = stmt.query(params![profile, d.0.to_vec(), s as i64, i64::from(op::KIND_EDIT)]).map_err(sql)?;
        while let Some(r) = q.next().map_err(sql)? {
            let p: Vec<u8> = r.get(0).map_err(sql)?;
            if let Ok(Body::Edit(EditBody { legacy: Some(l), .. })) = Body::decode(op::KIND_EDIT, &p) {
                out.merge(&Dvv::parse(&l.ctx_json));
                out.add(&l.writer, l.seq);
            }
        }
    }
    Ok(out)
}

fn note_legacy(conn: &Connection, profile: &str, device: &Id, seq: u64, l: &LegacyStamp) -> Result<(), String> {
    let cur: Option<String> = conn
        .prepare_cached("SELECT ctx FROM sync2_legacy WHERE profile_uid = ?1 AND device = ?2")
        .map_err(sql)?
        .query_row(params![profile, device.0.to_vec()], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    let mut d = cur.map(|c| Dvv::parse(&c)).unwrap_or_default();
    d.merge(&Dvv::parse(&l.ctx_json));
    d.add(&l.writer, l.seq);
    conn.prepare_cached("INSERT OR REPLACE INTO sync2_legacy (profile_uid, device, upto, ctx) VALUES (?1, ?2, ?3, ?4)")
        .map_err(sql)?
        .execute(params![profile, device.0.to_vec(), seq as i64, d.to_json().to_string()])
        .map_err(sql)?;
    Ok(())
}

// ---------------------------------------------------------------- 投影

/// 一次投影涉及的东西（交回 Dart 刷新缓存 / 做标记用）。
#[derive(Default, Debug)]
pub(crate) struct Touched {
    /// 真正落进投影的事件的粗粒度摘要（受影响实体 + 修订号增量）。以前这里存每条事件的全文 JSON 原样交回
    /// Dart，一批 8 MiB 的压缩段解开后是几百 MB，跨 isolate 拷一份再在 UI 线程逐条解析，大同步直接卡死 /
    /// OOM；Dart 只拿它做标记和计数，所以内核在这里就把标记算完，只回实体 ID 与几个计数。
    pub marks: Marks,
    /// 被新落的修改记录支配、从投影删掉的修改记录 ID。
    pub dominated: Vec<String>,
    /// 需要重放的卡（新落的日志、血统变化）。牌组配置 / 归属的变化不在这里：派生日志按自己记下的配置快照
    /// 重放（replay.rs 文件头），改配置不追溯改写历史。
    pub cards: BTreeSet<String>,
    /// 可见性 / 内容被冲突扣住、解除、清除改变了的实体 (kind, id)：Dart 侧要刷新它们的缓存。
    pub entities_changed: BTreeSet<(String, String)>,
    /// 这一次被彻底清除的实体 (kind, id)：Dart 侧要通知依赖它们的派生表（RWKV 分数表）。
    pub purged: BTreeSet<(String, String)>,
    pub diagnostics: Vec<String>,
}

/// 落进投影的事件对 Dart 缓存 / 修订号的影响（规则与 Dart `SrsDbStore` 旧 `_absorbProjection` 逐条解析时
/// 相同：`_markEntity` / `_touchesContent` / `_touchesRwkvScores` / `_noteTypeKeyAffectsCaches`）。
#[derive(Default, Debug)]
pub(crate) struct Marks {
    /// 缓存要刷新的笔记 / 卡 / 笔记类型（类型只记影响缓存行的字段键，见 [note_type_key_affects_caches]）。
    pub notes: BTreeSet<String>,
    pub cards: BTreeSet<String>,
    pub note_types: BTreeSet<String>,
    /// 落进投影的事件数（Dart 修订号的增量）。
    pub landed: u64,
    /// 其中推进内容修订号的（日志与界面状态类修改记录以外）。
    pub content: u64,
    /// 界面状态类修改记录（牌组收起 / 展开、排序位、新卡位置）。
    pub view: u64,
    /// 推进 RWKV 分数表全量刷新的（牌组 / profile 的身份记录与非界面状态修改记录）。
    pub rwkv: u64,
}

impl Marks {
    fn mark(&mut self, kind: EntKind, id: &str, key: Option<&str>) {
        match kind {
            EntKind::Note => {
                self.notes.insert(id.to_owned());
            }
            EntKind::Card => {
                self.cards.insert(id.to_owned());
            }
            EntKind::NoteType => {
                if key.is_none_or(note_type_key_affects_caches) {
                    self.note_types.insert(id.to_owned());
                }
            }
            EntKind::Deck | EntKind::Profile => {}
        }
    }

    /// 一条身份记录落进投影。
    pub(crate) fn entity(&mut self, kind: EntKind, id: &str) {
        self.mark(kind, id, None);
        self.landed += 1;
        self.content += 1;
        if matches!(kind, EntKind::Deck | EntKind::Profile) {
            self.rwkv += 1;
        }
    }

    /// 一条修改记录落进投影。
    pub(crate) fn edit(&mut self, kind: EntKind, id: &str, key: &str) {
        self.mark(kind, id, Some(key));
        self.landed += 1;
        let view = is_view_state(kind, key);
        if view {
            self.view += 1;
        } else {
            self.content += 1;
            if matches!(kind, EntKind::Deck | EntKind::Profile) {
                self.rwkv += 1;
            }
        }
    }

    /// 一条复习日志落进投影。
    pub(crate) fn log(&mut self, card: &str) {
        self.cards.insert(card.to_owned());
        self.landed += 1;
    }

    /// 交回 Dart 的形态：`{"notes":[..],"cards":[..],"noteTypes":[..],"landed":n,"content":n,"view":n,"rwkv":n}`。
    pub(crate) fn to_json(&self) -> Value {
        json!({
            "notes": self.notes,
            "cards": self.cards,
            "noteTypes": self.note_types,
            "landed": self.landed,
            "content": self.content,
            "view": self.view,
            "rwkv": self.rwkv,
        })
    }
}

/// 字段类别是不是界面状态（Dart `srsFieldClassOf` 的 viewState 分支，packages/fushi_srs/lib/src/field_edit.dart）。
pub(crate) fn is_view_state(kind: EntKind, key: &str) -> bool {
    match kind {
        EntKind::Card => key == "newPos",
        EntKind::Deck => key == "collapsed" || key == "position",
        _ => false,
    }
}

/// 笔记类型的这个字段键是否影响笔记 / 卡片缓存行（Dart `SrsDbStore._noteTypeKeyAffectsCaches`：名字、CSS、
/// 字段说明只在渲染 / 编辑时读）。
pub(crate) fn note_type_key_affects_caches(key: &str) -> bool {
    key != "name" && key != "css" && !key.starts_with("fieldDesc/")
}

pub(crate) fn canonical(v: &Value) -> String {
    serde_json::to_string(v).expect("json")
}

/// 日志投影行（Dart `SrsReviewLog.toJson` 的线格式）。结果先放作者原值，重放再改写。
pub(crate) fn log_row(profile: &str, op: &Op, l: &LogBody) -> Value {
    let mut m: Map<String, Value> = match serde_json::from_str::<Value>(&l.extra) {
        Ok(Value::Object(m)) => m,
        _ => Map::new(),
    };
    m.insert("id".into(), json!(l.id.text()));
    m.insert("p".into(), json!(profile));
    m.insert("card".into(), json!(l.card.text()));
    m.insert("kind".into(), json!(l.kind));
    if let Some(r) = l.rating {
        m.insert("rating".into(), json!(r));
    }
    if let Some(r) = &l.revokes {
        m.insert("revokes".into(), json!(r.text()));
    }
    let hlc = l.legacy_hlc.clone().unwrap_or_else(|| format!("{}:{}:{}", op.hlc.wall, op.hlc.logical, op.id.device.text()));
    m.insert("hlc".into(), json!(hlc));
    m.insert("at".into(), json!(l.at));
    m.insert("ts".into(), json!(op::ts_wire(l.ts)));
    m.insert("origin".into(), json!(l.origin));
    m.insert("rtype".into(), json!(l.rtype));
    if l.dur != 0 {
        m.insert("dur".into(), json!(l.dur));
    }
    if let Some(p) = &l.params {
        m.insert("params".into(), json!(p));
    }
    if let Some(a) = &l.alg {
        m.insert("alg".into(), json!(a));
    }
    m.insert("utcOff".into(), json!(l.utc_off));
    m.insert("rollover".into(), json!(l.rollover));
    if let Some(r) = &l.res {
        if let Ok(v) = serde_json::from_str::<Value>(r) {
            m.insert("res".into(), v);
        }
    }
    if let Some(a) = l.anki_id {
        m.insert("ankiId".into(), json!(a));
    }
    m.insert("fv".into(), json!(l.fv));
    Value::Object(m)
}

/// 修改记录投影行（Dart `SrsFieldEdit.toJson`）。v2 写入：dot = (设备, seq)、ctx = 作者已应用的版本向量
/// 并上旧修改记录闭包；迁移进来的旧记录：原样的旧 dot / 旧 ctx / 旧 HLC。
pub(crate) fn edit_row(conn: &Connection, profile: &str, op: &Op, e: &EditBody) -> Result<(String, Value), String> {
    let (writer, seq, ctx, hlc) = match &e.legacy {
        Some(l) => (l.writer.clone(), l.seq, serde_json::from_str::<Value>(&l.ctx_json).unwrap_or(json!({"vv": {}})), l.hlc.clone()),
        None => {
            let full = op.ctx();
            let mut d = legacy_closure(conn, profile, &full)?;
            for (dev, &s) in &full.0 {
                d.raise(&dev.text(), s as i64);
            }
            (
                op.id.device.text(),
                op.id.seq as i64,
                d.to_json(),
                format!("{}:{}:{}", op.hlc.wall, op.hlc.logical, op.id.device.text()),
            )
        }
    };
    let id = crate::registers::edit_id(&writer, seq);
    let mut m = Map::new();
    m.insert("id".into(), json!(id));
    m.insert("p".into(), json!(profile));
    m.insert("k".into(), json!(e.kind.wire()));
    m.insert("e".into(), json!(e.entity.text()));
    m.insert("f".into(), json!(e.key));
    m.insert("w".into(), json!(writer));
    m.insert("s".into(), json!(seq));
    m.insert("ctx".into(), ctx);
    m.insert("v".into(), serde_json::from_str::<Value>(&e.value).unwrap_or(Value::Null));
    m.insert("hlc".into(), json!(hlc));
    m.insert("ts".into(), json!(op::ts_wire(e.ts)));
    if e.machine {
        m.insert("m".into(), json!(true));
    }
    Ok((id, Value::Object(m)))
}

fn upsert_server_time(conn: &Connection, profile: &str, id: &str, s: Option<i64>, now: i64) -> Result<(), String> {
    let Some(s) = s else { return Ok(()) };
    conn.prepare_cached(
        "INSERT INTO srs_event_local (event_id, profile_uid, outbox_seq, server_time, received_at) VALUES (?1, ?2, NULL, ?3, ?4) \
         ON CONFLICT(event_id) DO UPDATE SET server_time = MIN(COALESCE(server_time, excluded.server_time), excluded.server_time)",
    )
    .map_err(sql)?
    .execute(params![id, profile, s, now])
    .map_err(sql)?;
    Ok(())
}

/// 牌组配置相关的键（改了要重放该牌组子树里的卡）。
/// 把一条操作落进投影。[project] = false 时只记意图 / 索引 / 闭包（迁移：投影行本来就在）。
pub(crate) fn project(conn: &Connection, profile: &str, op: &Op, now: i64, project: bool, t: &mut Touched) -> Result<(), String> {
    let body = op.body().map_err(|e| e.to_string())?;
    match body {
        Body::Entity { kind, id, data } => {
            if project {
                project_entity(conn, profile, kind, &id.text(), &data, t)?;
            }
        }
        Body::Edit(e) => project_edit(conn, profile, op, &e, now, project, t)?,
        Body::Log(l) => project_log(conn, profile, op, &l, now, project, t)?,
        Body::TagOrder { note, tags } => {
            let n = note.text();
            semantics::index(conn, profile, "note", &n, &op.id, "#tag")?;
            if semantics::purged_for(conn, profile, "note", &n, op)? {
                semantics::purge_op(conn, profile, &op.id, Some(&self_device(conn, profile)?))?;
                return Ok(());
            }
            semantics::tag_order(conn, profile, &n, &tags, op)?;
            semantics::refresh_tags_row(conn, profile, &n, t)?;
        }
        Body::TagAdd { note, tag } | Body::TagRemove { note, tag } => {
            let n = note.text();
            semantics::index(conn, profile, "note", &n, &op.id, "#tag")?;
            if semantics::purged_for(conn, profile, "note", &n, op)? {
                semantics::purge_op(conn, profile, &op.id, Some(&self_device(conn, profile)?))?;
                return Ok(());
            }
            if op.kind == op::KIND_TAG_ADD {
                semantics::tag_add(conn, profile, &n, &tag, op)?;
            } else {
                semantics::tag_remove(conn, profile, &n, &tag, op)?;
            }
            semantics::refresh_tags_row(conn, profile, &n, t)?;
            semantics::evaluate_holds(conn, profile, "note", &n, now, t)?;
        }
        Body::Purge { kind, entity } => {
            let own = self_device(conn, profile)?;
            semantics::purge_entity(conn, profile, kind, &entity.text(), op, &own, t)?;
        }
        Body::Checkpoint { name, reason } => {
            conn.prepare_cached(
                "INSERT OR IGNORE INTO sync2_checkpoints (profile_uid, device, seq, wall, name, reason) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            )
            .map_err(sql)?
            .execute(params![profile, op.id.device.0.to_vec(), op.id.seq as i64, op.hlc.wall, name, reason])
            .map_err(sql)?;
        }
        Body::Media { name, .. } => {
            // 文件名 → 内容：因果优先，真并发才 HLC 大者胜（同一文件名并发绑了两份内容 = 低价值标量，设计 §5.2）。
            let win = mvr::write(conn, profile, &mvr::reg("m", &[&name]), op)?;
            land_media_binding(conn, profile, &name, &win)?;
        }
        Body::MediaAt { location, flags, names } => media::project_media_at(conn, profile, op, &location, flags, &names)?,
        Body::LegacyUnknown { json } => {
            if project {
                let v: Value = serde_json::from_str(&json).unwrap_or(Value::Null);
                let id = v["x"]["id"].as_str().map(str::to_owned).unwrap_or_else(|| json.clone());
                conn.prepare_cached("INSERT OR IGNORE INTO srs_unknown_events (id, profile_uid, json) VALUES (?1, ?2, ?3)")
                    .map_err(sql)?
                    .execute(params![id, profile, json])
                    .map_err(sql)?;
            }
        }
        // 不认识的种类 / 已清除的骨架 / 牌组别名：只保存事实，不投影。
        Body::Unknown | Body::Purged | Body::DeckAlias { .. } => {}
    }
    Ok(())
}

/// 媒体绑定投影 `sync2_media` 落到寄存器的当前值 [win]（与投影已有的相同就不写）。
pub(crate) fn land_media_binding(conn: &Connection, profile: &str, name: &str, win: &mvr::Write) -> Result<(), String> {
    let cur: Option<(i64, i64, Vec<u8>)> = conn
        .prepare_cached("SELECT wall, logical, device FROM sync2_media WHERE profile_uid = ?1 AND name = ?2")
        .map_err(sql)?
        .query_row(params![profile, name], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()
        .map_err(sql)?;
    if cur.as_ref().is_some_and(|(w, l, d)| (*w, *l, d.as_slice()) == (win.wall, win.logical, &win.id.device.0[..])) {
        return Ok(());
    }
    let Some(Body::Media { sha256, size, .. }) = load_op(conn, profile, &win.id)?.and_then(|o| o.body().ok()) else {
        return Ok(());
    };
    conn.prepare_cached(
        "INSERT OR REPLACE INTO sync2_media (profile_uid, name, sha256, size, wall, logical, device) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    )
    .map_err(sql)?
    .execute(params![profile, name, sha256.to_vec(), size as i64, win.wall, win.logical, win.id.device.0.to_vec()])
    .map_err(sql)?;
    Ok(())
}

/// 收到（已应用的）远端操作后推进本机 HLC 并持久化（设计 §3.2：`hlc = max(local, remote) + 1`，+1 在下一次发出时）。[seen] = 这批
/// 远端操作里不超前的最大 HLC；超前（远端 wall 超出本机墙钟 [crate::sync2::hlc::MAX_AHEAD_MS]）的作者在
/// [ahead] 里：照收，`sync2_devices.warning` 打 `clock_ahead`（已有分叉告警的不覆盖），不把本机时钟拽过去。
pub(crate) fn observe_remote(conn: &Connection, profile: &str, seen: Option<Hlc>, ahead: &BTreeSet<Id>, now: i64) -> Result<(), String> {
    for d in ahead {
        conn.prepare_cached(
            "UPDATE sync2_devices SET warning = 'clock_ahead' WHERE profile_uid = ?1 AND device = ?2 AND warning IS NULL",
        )
        .map_err(sql)?
        .execute(params![profile, d.0.to_vec()])
        .map_err(sql)?;
    }
    let Some(remote) = seen else { return Ok(()) };
    let row: Option<(Vec<u8>, i64, i64)> = conn
        .prepare_cached("SELECT device, hlc_wall, hlc_logical FROM sync2_self WHERE profile_uid = ?1")
        .map_err(sql)?
        .query_row([profile], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()
        .map_err(sql)?;
    let Some((d, w, l)) = row else { return Ok(()) };
    let device = id_of(d)?;
    let mut clock = Clock::new(device);
    clock.last = Hlc { wall: w, logical: l as u32, device };
    // 吸收（取最大）而不是 `observe` 的 +1：收段按任意边界切批时结果相同（下一次 tick 自然更大）。
    clock.absorb(remote, now);
    if (clock.last.wall, i64::from(clock.last.logical)) != (w, l) {
        conn.prepare_cached("UPDATE sync2_self SET hlc_wall = ?2, hlc_logical = ?3 WHERE profile_uid = ?1")
            .map_err(sql)?
            .execute(params![profile, clock.last.wall, i64::from(clock.last.logical)])
            .map_err(sql)?;
    }
    Ok(())
}

fn self_device(conn: &Connection, profile: &str) -> Result<Id, String> {
    conn.prepare_cached("SELECT device FROM sync2_self WHERE profile_uid = ?1")
        .map_err(sql)?
        .query_row([profile], |r| r.get::<_, Vec<u8>>(0))
        .map_err(sql)
        .and_then(id_of)
}

fn project_entity(conn: &Connection, profile: &str, kind: EntKind, idt: &str, data: &str, t: &mut Touched) -> Result<(), String> {
    let d: Value = serde_json::from_str(data).unwrap_or(Value::Null);
    let rec = json!({"id": idt, "p": profile, "k": kind.wire(), "d": d});
    let existing: Option<(String, String)> = conn
        .prepare_cached("SELECT payload_json, kind FROM srs_entities WHERE id = ?1")
        .map_err(sql)?
        .query_row([idt], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
        .map_err(sql)?;
    let write = match existing {
        None => true,
        Some((pj, k)) => {
            let old = json!({"id": idt, "p": profile, "k": k, "d": serde_json::from_str::<Value>(&pj).unwrap_or(Value::Null)});
            if canonical(&old) == canonical(&rec) {
                false
            } else {
                t.diagnostics.push(format!("entity {idt}: same id, different content"));
                canonical(&rec) < canonical(&old)
            }
        }
    };
    if write {
        conn.prepare_cached(
            "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES (?1, ?2, ?3, ?4, ?5) \
             ON CONFLICT(id) DO UPDATE SET profile_uid = excluded.profile_uid, kind = excluded.kind, \
             payload_json = excluded.payload_json, created_at = excluded.created_at",
        )
        .map_err(sql)?
        .execute(params![idt, profile, kind.wire(), canonical(&d), d["createdAt"].as_i64().unwrap_or(0)])
        .map_err(sql)?;
        t.marks.entity(kind, idt);
    }
    Ok(())
}

fn project_edit(conn: &Connection, profile: &str, op: &Op, e: &EditBody, now: i64, project: bool, t: &mut Touched) -> Result<(), String> {
    if let Some(l) = &e.legacy {
        note_legacy(conn, profile, &op.id.device, op.id.seq, l)?;
    }
    let (eid, _) = edit_row(conn, profile, op, e)?;
    conn.prepare_cached("INSERT OR REPLACE INTO sync2_edit_ops (edit_id, profile_uid, device, seq) VALUES (?1, ?2, ?3, ?4)")
        .map_err(sql)?
        .execute(params![eid, profile, op.id.device.0.to_vec(), op.id.seq as i64])
        .map_err(sql)?;
    let ent = e.entity.text();
    semantics::index(conn, profile, e.kind.wire(), &ent, &op.id, &e.key)?;
    if e.kind == EntKind::Card && e.key == "deck" {
        if let Ok(Value::String(d)) = serde_json::from_str::<Value>(&e.value) {
            semantics::index(conn, profile, "deck", &d, &op.id, "#move")?;
        }
    }
    // 标签是 OR-Set：整列表的 `tags` 写入（迁移进来的旧记录）按「添加其中每个标签」并入。迁移时也要做：
    // 合成行替换掉旧的 `tags` 行，各设备收到同一批操作后结果相同。
    if e.kind == EntKind::Note && e.key == "tags" {
        // 整列表标签同样是内容：没见过清除的迟到写入当场清除（以前这条分支在清除判断之前，被清除笔记的
        // 标签照样并回来）。
        if project && semantics::purged_for(conn, profile, "note", &ent, op)? {
            semantics::purge_op(conn, profile, &op.id, Some(&self_device(conn, profile)?))?;
            return Ok(());
        }
        if let Ok(Value::Array(xs)) = serde_json::from_str::<Value>(&e.value) {
            let tags: Vec<String> = xs.iter().filter_map(Value::as_str).map(str::to_owned).collect();
            for x in &tags {
                semantics::tag_add(conn, profile, &ent, x, op)?;
            }
            semantics::tag_order(conn, profile, &ent, &tags, op)?;
        }
        semantics::refresh_tags_row(conn, profile, &ent, t)?;
        semantics::evaluate_holds(conn, profile, "note", &ent, now, t)?;
        return Ok(());
    }
    if !project {
        return Ok(());
    }
    if e.key != "deleted" && semantics::purged_for(conn, profile, e.kind.wire(), &ent, op)? {
        semantics::purge_op(conn, profile, &op.id, Some(&self_device(conn, profile)?))?;
        return Ok(());
    }
    if semantics::should_hold(conn, profile, e.kind.wire(), &ent, op)? {
        semantics::evaluate_holds(conn, profile, e.kind.wire(), &ent, now, t)?;
        return Ok(());
    }
    land_edit(conn, profile, op, e, e.legacy.as_ref().and_then(|l| l.server_time), now, t)?;
    semantics::evaluate_holds(conn, profile, e.kind.wire(), &ent, now, t)
}

/// 一条修改记录落进投影（与 Dart 旧 `_storeLocalBatch` 同语义：同 ID 已在或被同字段键上现存的记录支配
/// → 不落；落了就删掉被它支配的）。
pub(crate) fn land_edit(conn: &Connection, profile: &str, op: &Op, e: &EditBody, server: Option<i64>, now: i64, t: &mut Touched) -> Result<(), String> {
    let (eid, row) = edit_row(conn, profile, op, e)?;
    let ent = e.entity.text();
    let existing: Vec<(String, String, Option<i64>)> = conn
        .prepare_cached(
            "SELECT f.id, f.json, l.server_time FROM srs_field_edits f LEFT JOIN srs_event_local l ON l.event_id = f.id \
             WHERE f.entity_kind = ?1 AND f.entity_id = ?2",
        )
        .map_err(sql)?
        .query_map(params![e.kind.wire(), ent], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let row_text = canonical(&row);
    let mut items: Vec<(&str, Option<i64>)> = existing.iter().map(|(_, j, s)| (j.as_str(), *s)).collect();
    items.push((&row_text, server));
    let (landed, deleted) = crate::registers::land_stored(&items, existing.len())?;
    if landed.first().copied() != Some(true) {
        return Ok(());
    }
    for &d in &deleted[0] {
        let id = &existing[d].0;
        conn.prepare_cached("DELETE FROM srs_field_edits WHERE id = ?1").map_err(sql)?.execute([id]).map_err(sql)?;
        t.dominated.push(id.clone());
    }
    conn.prepare_cached(
        "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
    )
    .map_err(sql)?
    .execute(params![eid, profile, e.kind.wire(), ent, e.key, row["w"].as_str().unwrap_or_default(), row["s"].as_i64().unwrap_or(0), row_text])
    .map_err(sql)?;
    upsert_server_time(conn, profile, &eid, server, now)?;
    match e.kind {
        // 血统变了：归属组变了，链尾与前身都要重放。
        EntKind::Card if e.key.starts_with("historyFrom/") => {
            t.cards.insert(ent.clone());
            if let Some(p) = e.key.strip_prefix("historyFrom/") {
                t.cards.insert(p.to_owned());
            }
        }
        _ => {}
    }
    t.marks.edit(e.kind, &ent, &e.key);
    Ok(())
}

fn project_log(conn: &Connection, profile: &str, op: &Op, l: &LogBody, now: i64, project: bool, t: &mut Touched) -> Result<(), String> {
    let (intent, arg) = intent_code(&l.intent);
    let lid = l.id.text();
    let card = l.card.text();
    conn.prepare_cached(
        "INSERT OR IGNORE INTO sync2_log_meta (log_id, profile_uid, card_id, note_id, intent, arg, device, seq) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
    )
    .map_err(sql)?
    .execute(params![lid, profile, card, l.note.as_ref().map(Key::text), intent, arg, op.id.device.0.to_vec(), op.id.seq as i64])
    .map_err(sql)?;
    semantics::index(conn, profile, "card", &card, &op.id, "#log")?;
    if let Some(n) = &l.note {
        semantics::index(conn, profile, "note", &n.text(), &op.id, "#log")?;
    }
    if !project {
        return Ok(());
    }
    let exists: bool = conn
        .prepare_cached("SELECT 1 FROM srs_review_logs WHERE id = ?1")
        .map_err(sql)?
        .exists([&lid])
        .map_err(sql)?;
    if !exists {
        let row = log_row(profile, op, l);
        conn.prepare_cached(
            "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, duration_ms, json) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        )
        .map_err(sql)?
        .execute(params![lid, profile, card, l.kind, l.rating, l.at, l.rtype, l.origin, l.dur, canonical(&row)])
        .map_err(sql)?;
        upsert_server_time(conn, profile, &lid, l.legacy_server_time, now)?;
        t.cards.insert(card.clone());
        t.marks.log(&card);
    }
    semantics::evaluate_holds(conn, profile, "card", &card, now, t)?;
    if let Some(n) = &l.note {
        semantics::evaluate_holds(conn, profile, "note", &n.text(), now, t)?;
    }
    Ok(())
}

fn intent_code(i: &Intent) -> (i64, Option<i64>) {
    match i {
        Intent::Absolute => (0, None),
        Intent::Answer => (1, None),
        Intent::SetDue { due_day } => (2, Some(*due_day)),
        Intent::Reset => (3, None),
        Intent::Reschedule => (4, None),
        Intent::HandOff { to_anki } => (5, Some(i64::from(*to_anki))),
    }
}

fn intent_of(code: i64, arg: Option<i64>) -> Intent {
    match code {
        1 => Intent::Answer,
        2 => Intent::SetDue { due_day: arg.unwrap_or(0) },
        3 => Intent::Reset,
        4 => Intent::Reschedule,
        5 => Intent::HandOff { to_anki: arg == Some(1) },
        _ => Intent::Absolute,
    }
}

// ---------------------------------------------------------------- 重放写回

/// 重放受影响的卡：每张卡找到血统的链尾（继承它历史的、没有后继的卡），在链尾的归属组里重放
/// （链尾 + 全部前身的日志一起排），派生日志按各自记下的配置快照算，结果写回投影行。返回日志行被改写的卡。
pub(crate) fn replay_touched(conn: &Connection, t: &Touched) -> Result<BTreeSet<String>, String> {
    replay_cards(conn, &t.cards)
}

/// [cards] 的链尾。
fn tails(conn: &Connection, card: &str) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    let mut seen = BTreeSet::new();
    let mut stack = vec![card.to_owned()];
    while let Some(c) = stack.pop() {
        if !seen.insert(c.clone()) || seen.len() > 256 {
            continue;
        }
        let s = config::successors(conn, &c)?;
        if s.is_empty() {
            out.push(c);
        } else {
            stack.extend(s);
        }
    }
    out.sort();
    out.dedup();
    Ok(out)
}

/// 一个归属组（链尾 + 广度优先的全部前身）的日志行与链尾所属的笔记（日志上记的，没有则取调用方给的）。
struct Group {
    rows: Vec<(String, String, Option<i64>, Intent, String)>,
    note: Option<String>,
}

fn group_of(conn: &Connection, tail: &str, note_hint: Option<&str>) -> Result<Group, String> {
    let tail = &tail.to_owned();
    // 归属组：链尾 + 广度优先的全部前身。
    let mut lineage = vec![tail.clone()];
    let mut i = 0;
    while i < lineage.len() && lineage.len() < 256 {
        let c = lineage[i].clone();
        let es = config::edits_of(conn, "card", std::slice::from_ref(&c))?.remove(&c).unwrap_or_default();
        for p in config::predecessors(&es) {
            if !lineage.contains(&p) {
                lineage.push(p);
            }
        }
        i += 1;
    }
    let mut rows: Vec<(String, String, Option<i64>, Intent, String)> = Vec::new();
    let mut note: Option<String> = None;
    for c in &lineage {
        let mut stmt = conn
            .prepare_cached(
                "SELECT l.id, l.json, e.server_time, m.intent, m.arg, m.note_id FROM srs_review_logs l \
                 LEFT JOIN srs_event_local e ON e.event_id = l.id LEFT JOIN sync2_log_meta m ON m.log_id = l.id \
                 WHERE l.card_id = ?1",
            )
            .map_err(sql)?;
        let mut q = stmt.query([c]).map_err(sql)?;
        while let Some(r) = q.next().map_err(sql)? {
            let id: String = r.get(0).map_err(sql)?;
            let json: String = r.get(1).map_err(sql)?;
            let st: Option<i64> = r.get(2).map_err(sql)?;
            let code: Option<i64> = r.get(3).map_err(sql)?;
            let arg: Option<i64> = r.get(4).map_err(sql)?;
            let n: Option<String> = r.get(5).map_err(sql)?;
            // 笔记取链尾自己日志上记的；链尾还没有日志就取前身的（换笔记类型不换笔记）。
            if n.is_some() && (note.is_none() || c == tail) {
                note = n;
            }
            let intent = match code {
                Some(k) => intent_of(k, arg),
                None => infer_intent(&serde_json::from_str(&json).unwrap_or(Value::Null)),
            };
            rows.push((id, json, st, intent, c.clone()));
        }
    }
    if note.is_none() {
        note = note_hint.map(str::to_owned);
    }
    Ok(Group { rows, note })
}

pub(crate) fn replay_cards(conn: &Connection, cards: &BTreeSet<String>) -> Result<BTreeSet<String>, String> {
    let mut groups: BTreeSet<String> = BTreeSet::new();
    for c in cards {
        groups.extend(tails(conn, c)?);
    }
    let mut changed = BTreeSet::new();
    if groups.is_empty() {
        return Ok(changed);
    }
    for tail in &groups {
        let Group { rows, .. } = group_of(conn, tail, None)?;
        if rows.is_empty() {
            continue;
        }
        let input: Vec<Row<'_>> = rows.iter().map(|(_, j, s, i, _)| Row { json: j, server_time: *s, intent: i.clone() }).collect();
        let out = replay::replay(&input)?;
        for (k, new) in out.rows.iter().enumerate() {
            if let Some(json) = new {
                conn.prepare_cached("UPDATE srs_review_logs SET json = ?2 WHERE id = ?1")
                    .map_err(sql)?
                    .execute(params![rows[k].0, json])
                    .map_err(sql)?;
                changed.insert(rows[k].4.clone());
            }
        }
    }
    Ok(changed)
}

// ---------------------------------------------------------------- 本机写入

/// Dart 事件（`SrsEvent.toJson`）→ 操作载荷。修改记录的 dot / ctx / hlc / id 由这里重新分配（不读 Dart 给的）；
/// 日志按作者结果推出意图，结果作为作者原值留在操作里。[note] 是日志卡片所属的笔记（Dart 知道）。
///
/// [stamped]：外来的、已经盖过戳的事件（备份合并、按时间点恢复并入的备份事件）——修改记录**保留**原 dot /
/// 因果上下文 / HLC / S(e)（与迁移同一机制），支配关系照旧成立；当本机新写入并入会把旧值盖在现值上。
pub(crate) fn body_of_event(ev: &Value, note: Option<&str>, stamped: bool, server: Option<i64>) -> Result<Body, String> {
    if stamped {
        let x = &ev["x"];
        if ev["t"].as_str() == Some("edit") {
            let s = |k: &str| x.get(k).and_then(Value::as_str);
            return Ok(Body::Edit(EditBody {
                kind: EntKind::parse(s("k").unwrap_or_default()).ok_or("unknown entity kind")?,
                entity: Key::of(s("e").ok_or("edit entity")?),
                key: s("f").ok_or("edit key")?.to_owned(),
                value: canonical(x.get("v").unwrap_or(&Value::Null)),
                machine: x.get("m") == Some(&Value::Bool(true)),
                ts: op::ts_code(s("ts").unwrap_or("wall")),
                legacy: Some(LegacyStamp {
                    writer: s("w").ok_or("edit writer")?.to_owned(),
                    seq: x["s"].as_i64().ok_or("edit seq")?,
                    ctx_json: canonical(x.get("ctx").unwrap_or(&json!({"vv": {}}))),
                    hlc: s("hlc").ok_or("edit hlc")?.to_owned(),
                    server_time: server,
                }),
            }));
        }
        if ev["t"].as_str() == Some("log") {
            return Ok(Body::Log(log_body_of(x, note, x.get("hlc").and_then(Value::as_str).map(str::to_owned), server)?));
        }
    }
    let x = &ev["x"];
    let s = |k: &str| x.get(k).and_then(Value::as_str);
    Ok(match ev["t"].as_str() {
        Some("entity") => Body::Entity {
            kind: EntKind::parse(s("k").unwrap_or_default()).ok_or("unknown entity kind")?,
            id: Key::of(s("id").ok_or("entity id")?),
            data: canonical(&x["d"]),
        },
        Some("edit") => Body::Edit(EditBody {
            kind: EntKind::parse(s("k").unwrap_or_default()).ok_or("unknown entity kind")?,
            entity: Key::of(s("e").ok_or("edit entity")?),
            key: s("f").ok_or("edit key")?.to_owned(),
            value: canonical(x.get("v").unwrap_or(&Value::Null)),
            machine: x.get("m") == Some(&Value::Bool(true)),
            ts: op::ts_code(s("ts").unwrap_or("wall")),
            legacy: None,
        }),
        // 日志的排序键是它自带的 HLC（导入的 Anki 复习按原始复习时刻排、撤销排在被撤者之后），原样保留。
        Some("log") => Body::Log(log_body_of(x, note, x.get("hlc").and_then(Value::as_str).map(str::to_owned), None)?),
        _ => Body::LegacyUnknown { json: canonical(ev) },
    })
}

/// 迁移队列：要包成操作的旧行（phase 0 身份记录 / 1 修改记录 / 2 日志 / 3 不认识的事件），`pos` 是确定的包装顺序。
const MIGRATE_QUEUE_SCHEMA: &str = "CREATE TABLE IF NOT EXISTS sync2_migrate_queue (\
     profile_uid TEXT NOT NULL, pos INTEGER NOT NULL, phase INTEGER NOT NULL, src TEXT NOT NULL, \
     PRIMARY KEY (profile_uid, pos)) WITHOUT ROWID;";

/// `srs_meta` 里「这个 profile 的迁移已开始、队列已排好」的标记键前缀（值 = 开始时刻）。
const MIGRATING_KEY: &str = "sync2_migrating/";

/// 把这一刻已有的旧行按迁移顺序排进队列：身份记录按创建时刻再按 ID；修改记录按旧 writer 再按旧 seq（同一旧
/// 写入者的记录保持原先后，闭包按序累积）；日志按发生时刻再按 ID；不认识的事件按 ID。
fn enqueue_legacy_rows(c: &Connection, profile: &str) -> Result<(), String> {
    let phases: [(i64, &str, &str); 4] = [
        (0, "srs_entities", "created_at, id"),
        (1, "srs_field_edits", "writer_id, seq"),
        (2, "srs_review_logs", "occurred_at, id"),
        (3, "srs_unknown_events", "id"),
    ];
    let mut base: i64 = 0;
    for (phase, table, order) in phases {
        let added = c
            .execute(
                &format!(
                    "INSERT INTO sync2_migrate_queue (profile_uid, pos, phase, src) \
                     SELECT ?1, ?2 + ROW_NUMBER() OVER (ORDER BY {order}), ?3, id FROM {table} WHERE profile_uid = ?1"
                ),
                params![profile, base, phase],
            )
            .map_err(sql)?;
        base += added as i64;
    }
    Ok(())
}

/// 一条排队的旧行 → 操作载荷；行已经不在了（不会发生：迁移期间独占写）返回 `None`。
fn legacy_body(c: &Connection, phase: i64, src: &str) -> Result<Option<Body>, String> {
    Ok(match phase {
        0 => {
            let row: Option<(String, String)> = c
                .prepare_cached("SELECT kind, payload_json FROM srs_entities WHERE id = ?1")
                .map_err(sql)?
                .query_row([src], |r| Ok((r.get(0)?, r.get(1)?)))
                .optional()
                .map_err(sql)?;
            row.and_then(|(kind, payload)| {
                let kind = EntKind::parse(&kind)?;
                let data = canonical(&serde_json::from_str::<Value>(&payload).unwrap_or(Value::Null));
                Some(Body::Entity { kind, id: Key::of(src), data })
            })
        }
        1 => {
            let row: Option<(String, Option<i64>)> = c
                .prepare_cached(
                    "SELECT f.json, e.server_time FROM srs_field_edits f LEFT JOIN srs_event_local e ON e.event_id = f.id \
                     WHERE f.id = ?1",
                )
                .map_err(sql)?
                .query_row([src], |r| Ok((r.get(0)?, r.get(1)?)))
                .optional()
                .map_err(sql)?;
            let Some((json, st)) = row else { return Ok(None) };
            let x: Value = serde_json::from_str(&json).map_err(|e| format!("bad field edit: {e}"))?;
            let s = |k: &str| x.get(k).and_then(Value::as_str);
            let Some(kind) = EntKind::parse(s("k").unwrap_or_default()) else { return Ok(None) };
            Some(Body::Edit(EditBody {
                kind,
                entity: Key::of(s("e").ok_or("edit entity")?),
                key: s("f").ok_or("edit key")?.to_owned(),
                value: canonical(x.get("v").unwrap_or(&Value::Null)),
                machine: x.get("m") == Some(&Value::Bool(true)),
                ts: op::ts_code(s("ts").unwrap_or("wall")),
                legacy: Some(LegacyStamp {
                    writer: s("w").ok_or("edit writer")?.to_owned(),
                    seq: x["s"].as_i64().ok_or("edit seq")?,
                    ctx_json: canonical(x.get("ctx").unwrap_or(&json!({"vv": {}}))),
                    hlc: s("hlc").ok_or("edit hlc")?.to_owned(),
                    server_time: st,
                }),
            }))
        }
        2 => {
            // 笔记 ID 取缓存行（迁移时卡都已物化过）。
            let row: Option<(String, Option<i64>, Option<String>)> = c
                .prepare_cached(
                    "SELECT l.json, e.server_time, cc.note_id FROM srs_review_logs l \
                     LEFT JOIN srs_event_local e ON e.event_id = l.id LEFT JOIN srs_cards_cache cc ON cc.id = l.card_id \
                     WHERE l.id = ?1",
                )
                .map_err(sql)?
                .query_row([src], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .optional()
                .map_err(sql)?;
            let Some((json, st, note)) = row else { return Ok(None) };
            let x: Value = serde_json::from_str(&json).map_err(|e| format!("bad review log: {e}"))?;
            let hlc = x["hlc"].as_str().map(str::to_owned);
            // 旧日志不带配置快照（`sc`）：重放按作者结果照抄，迁移不改任何卡的到期日。
            Some(Body::Log(log_body_of(&x, note.as_deref(), hlc, st)?))
        }
        _ => c
            .prepare_cached("SELECT json FROM srs_unknown_events WHERE id = ?1")
            .map_err(sql)?
            .query_row([src], |r| r.get::<_, String>(0))
            .optional()
            .map_err(sql)?
            .map(|json| Body::LegacyUnknown { json }),
    })
}

/// 迁移收尾：本机标成已迁移。
fn finish_migration(c: &Connection, local: &mut Local, profile: &str, now: i64, ops: u64) -> Result<Value, String> {
    local.migrated = true;
    local.save(c)?;
    c.execute("UPDATE sync2_self SET migrated_at = ?2 WHERE profile_uid = ?1", params![profile, now]).map_err(sql)?;
    Ok(json!({"done": true, "ops": ops, "remaining": 0}))
}

/// 把 [l] 所属卡此刻的生效排程配置写进日志的 `sc`（[replay::SNAPSHOT_KEY]）。
fn stamp_config(conn: &Connection, tree: &config::DeckTree, l: &mut LogBody) -> Result<(), String> {
    let note = l.note.as_ref().map(Key::text);
    let deck = config::card_deck(conn, tree, &l.card.text(), note.as_deref())?;
    let mut extra: Map<String, Value> = match serde_json::from_str::<Value>(&l.extra) {
        Ok(Value::Object(m)) => m,
        _ => Map::new(),
    };
    extra.insert(replay::SNAPSHOT_KEY.into(), tree.config(&deck).to_json());
    l.extra = canonical(&Value::Object(extra));
    Ok(())
}

const LOG_KNOWN_KEYS: [&str; 19] = [
    "id", "p", "card", "kind", "rating", "revokes", "hlc", "at", "ts", "origin", "rtype", "dur", "params", "alg", "utcOff", "rollover", "res",
    "ankiId", "fv",
];

pub(crate) fn log_body_of(x: &Value, note: Option<&str>, legacy_hlc: Option<String>, server: Option<i64>) -> Result<LogBody, String> {
    let s = |k: &str| x.get(k).and_then(Value::as_str);
    let i = |k: &str| x.get(k).and_then(Value::as_i64);
    let extra: Map<String, Value> =
        x.as_object().map(|m| m.iter().filter(|(k, _)| !LOG_KNOWN_KEYS.contains(&k.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect()).unwrap_or_default();
    Ok(LogBody {
        id: Key::of(s("id").ok_or("log id")?),
        card: Key::of(s("card").ok_or("log card")?),
        note: note.map(Key::of),
        kind: s("kind").ok_or("log kind")?.to_owned(),
        rating: i("rating"),
        revokes: s("revokes").map(Key::of),
        at: i("at").ok_or("log at")?,
        ts: op::ts_code(s("ts").unwrap_or("wall")),
        origin: s("origin").unwrap_or("fushi").to_owned(),
        rtype: s("rtype").unwrap_or("manual").to_owned(),
        dur: i("dur").unwrap_or(0),
        params: s("params").map(str::to_owned),
        alg: s("alg").map(str::to_owned),
        utc_off: i("utcOff").unwrap_or(0),
        rollover: i("rollover").unwrap_or(4),
        anki_id: i("ankiId"),
        fv: i("fv").unwrap_or(1),
        intent: infer_intent(x),
        res: x.get("res").filter(|v| v.is_object()).map(canonical),
        extra: canonical(&Value::Object(extra)),
        legacy_hlc,
        legacy_server_time: server,
    })
}

/// 追加一条本机操作（分配 seq / HLC / 上下文，推进链），返回操作。
pub(crate) fn append_local(conn: &Connection, local: &mut Local, applied: &mut Vv, body: &Body, now: i64) -> Result<Op, String> {
    let seq = local.next_seq;
    let mut deps = applied.clone();
    deps.set(local.device, 0);
    let op = Op {
        id: OpId { device: local.device, seq },
        hlc: local.clock.tick(now),
        deps: Arc::new(deps),
        kind: body.kind(),
        schema: op::SCHEMA,
        payload: body.encode().into(),
        purged: false,
    };
    let chain = chain_next(&local.chain, &op);
    insert_op(conn, &local.profile, &op, &chain, now)?;
    local.chain = chain;
    local.next_seq += 1;
    applied.set(local.device, seq);
    Ok(op)
}

impl SrsCore {
    /// 本机身份（没有就建）。返回 `{device, collection, nextSeq, migrated, name}`。
    pub fn sync2_identity(&self, profile: &str, now: i64) -> Result<Value, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let l = match Local::load(c, profile)? {
                Some(l) => l,
                None => Local::create(c, profile, now)?,
            };
            Ok(json!({
                "device": l.device.text(),
                "collection": l.collection.text(),
                "nextSeq": l.next_seq,
                "migrated": l.migrated,
                "name": l.name,
                "public": l.key.public().iter().map(|b| format!("{b:02x}")).collect::<String>(),
            }))
        })
    }

    /// 本机写入（设计 §6.2 第 1 步之前：复习立即本地落盘）。[input] 是 JSON 数组，每项
    /// `{"e": <SrsEvent JSON>, "note": <日志卡片的笔记 ID | null>}`。返回
    /// `{"marks":{..见 [Marks::to_json]}, "landed":[每项是否落了], "replayed":[...]}`。
    pub fn sync2_apply_local(&self, profile: &str, now: i64, input: &str) -> Result<String, String> {
        let items: Vec<Value> = serde_json::from_str(input).map_err(|e| format!("bad apply input: {e}"))?;
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let mut local = match Local::load(c, profile)? {
                Some(l) => l,
                None => Local::create(c, profile, now)?,
            };
            let mut applied = applied_vv(c, profile)?;
            let mut t = Touched::default();
            let mut landed = Vec::with_capacity(items.len());
            // 牌组树（配置快照用）：这一批里落过非日志操作（可能改了配置 / 归属）就重读。
            let mut tree: Option<config::DeckTree> = None;
            for it in &items {
                let stamped = it["stamped"] == Value::Bool(true);
                let body = body_of_event(&it["e"], it["note"].as_str(), stamped, it["server"].as_i64())?;
                let body = match body {
                    // 本机新写的派生日志记下此刻的生效配置（重放按它算，改配置不追溯；replay.rs 文件头）。外来、已盖戳
                    // 的日志保留它原有的（旧日志没有 = 按作者结果照抄）。
                    Body::Log(mut l) if !stamped && !matches!(l.intent, Intent::Absolute) => {
                        if tree.is_none() {
                            tree = Some(config::DeckTree::load(c, profile)?);
                        }
                        stamp_config(c, tree.as_ref().expect("tree just loaded"), &mut l)?;
                        Body::Log(l)
                    }
                    other => {
                        if !matches!(other, Body::Log(_)) {
                            tree = None;
                        }
                        other
                    }
                };
                let before = t.marks.landed;
                // 标签是 OR-Set：Dart 写的整列表 `tags` 按与当前值的差拆成添加 / 观察删除。
                let bodies = match &body {
                    Body::Edit(e) if e.kind == EntKind::Note && e.key == "tags" && e.legacy.is_none() => {
                        let note = e.entity.text();
                        let cur = semantics::current_tags(c, profile, &note)?;
                        let want: Vec<String> = match serde_json::from_str::<Value>(&e.value) {
                            Ok(Value::Array(xs)) => xs.iter().filter_map(Value::as_str).map(str::to_owned).collect(),
                            _ => Vec::new(),
                        };
                        let mut out: Vec<Body> = Vec::new();
                        for tag in want.iter().filter(|x| !cur.contains(x)) {
                            out.push(Body::TagAdd { note: e.entity.clone(), tag: tag.clone() });
                        }
                        for tag in cur.iter().filter(|x| !want.contains(x)) {
                            out.push(Body::TagRemove { note: e.entity.clone(), tag: tag.clone() });
                        }
                        // 显示顺序跟作者这一刻的列表走（只是提示，集合本身由上面的添加 / 观察删除决定）。
                        let mut seen = std::collections::BTreeSet::new();
                        let order: Vec<String> = want.iter().filter(|t| seen.insert((*t).clone())).cloned().collect();
                        if order != cur || !out.is_empty() {
                            out.push(Body::TagOrder { note: e.entity.clone(), tags: order });
                        }
                        out
                    }
                    _ => vec![body],
                };
                for b in &bodies {
                    let op = append_local(c, &mut local, &mut applied, b, now)?;
                    project(c, profile, &op, now, true, &mut t)?;
                }
                landed.push(t.marks.landed > before);
            }
            local.save(c)?;
            let replayed = replay_touched(c, &t)?;
            Ok(json!({
                "marks": t.marks.to_json(),
                "landed": landed,
                "replayed": replayed,
                "diagnostics": t.diagnostics,
                "changed": t.entities_changed.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
                "purged": t.purged.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
                "nextSeq": local.next_seq,
            })
            .to_string())
        })
    }

    /// 旧库并入（计划 P3.2；拍板 5）：把本 profile 现有的身份记录、修改记录、日志、不认识的事件逐条包成
    /// **本机新身份**的操作（旧修改记录带上旧 dot / 旧上下文 / 旧 HLC / S(e)，因果判定照旧成立）。投影行
    /// 本来就在，只补 ops 与元数据。
    ///
    /// **不改任何一张卡的排程**：迁移来的日志没有配置快照，重放按作者结果照抄（replay.rs 文件头），迁移后也不
    /// 重放。旧投影行（身份记录 / 日志 / 修改记录）原样留着——唯一的改写是旧的整列表 `tags` 行换成等值的
    /// OR-Set 合成行——所以迁移随时中断都不丢旧数据（设计 §13「迁移」）。
    ///
    /// **分批、可续跑**（[limit] 条一批，`None` = 一次做完）：第一批把要包的旧行按确定顺序排进
    /// `sync2_migrate_queue`（只排这一刻已有的行，之后的本机写入本来就是操作），每批在自己的 savepoint 里包一段、
    /// 从队列里删掉、提交；进程被杀 / 关库只丢正在做的那一批，下次打开从队列剩下的接着做。备份快照里带着队列与
    /// 进行中标记：从迁移到一半的快照恢复出来的新身份也接着做完，而不是被「已经有操作了」误判为迁移完成。
    /// 返回 `{"done": bool, "ops": 这一批包的条数, "remaining": 队列剩余}`。
    pub fn sync2_migrate(&self, profile: &str, now: i64, limit: Option<u64>) -> Result<Value, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let mut local = match Local::load(c, profile)? {
                Some(l) => l,
                None => Local::create(c, profile, now)?,
            };
            if local.migrated {
                return Ok(json!({"done": true, "ops": 0, "remaining": 0}));
            }
            c.execute_batch(MIGRATE_QUEUE_SCHEMA).map_err(sql)?;
            let marker = format!("{MIGRATING_KEY}{profile}");
            let started: bool = c
                .prepare_cached("SELECT 1 FROM srs_meta WHERE key = ?1")
                .map_err(sql)?
                .exists([&marker])
                .map_err(sql)?;
            if !started {
                // 已经有操作了（v2 之后的备份恢复出来的库：本机身份被快照剥掉、迁移标记随之没了，但投影行全是操作
                // 投影出来的）：只补标记，绝不再把投影行包一遍（那会造出一条重复的操作流）。
                let has_ops: bool = c
                    .prepare("SELECT 1 FROM sync2_ops WHERE profile_uid = ?1 AND device != ?2 LIMIT 1")
                    .map_err(sql)?
                    .exists(params![profile, local.device.0.to_vec()])
                    .map_err(sql)?;
                if has_ops {
                    return finish_migration(c, &mut local, profile, now, 0);
                }
                enqueue_legacy_rows(c, profile)?;
                c.execute("INSERT INTO srs_meta (key, value) VALUES (?1, ?2)", params![marker, now.to_string()]).map_err(sql)?;
            }
            let mut applied = applied_vv(c, profile)?;
            let mut t = Touched::default();
            let mut n = 0u64;
            let batch: Vec<(i64, i64, String)> = c
                .prepare_cached("SELECT pos, phase, src FROM sync2_migrate_queue WHERE profile_uid = ?1 ORDER BY pos LIMIT ?2")
                .map_err(sql)?
                .query_map(params![profile, limit.map_or(-1, |l| l.max(1) as i64)], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for (_, phase, src) in &batch {
                let Some(body) = legacy_body(c, *phase, src)? else { continue };
                let op = append_local(c, &mut local, &mut applied, &body, now)?;
                if !matches!(body, Body::LegacyUnknown { .. }) {
                    project(c, profile, &op, now, false, &mut t)?;
                }
                n += 1;
            }
            if let Some((last, _, _)) = batch.last() {
                c.prepare_cached("DELETE FROM sync2_migrate_queue WHERE profile_uid = ?1 AND pos <= ?2")
                    .map_err(sql)?
                    .execute(params![profile, last])
                    .map_err(sql)?;
            }
            let remaining: i64 = c
                .prepare_cached("SELECT COUNT(*) FROM sync2_migrate_queue WHERE profile_uid = ?1")
                .map_err(sql)?
                .query_row([profile], |r| r.get(0))
                .map_err(sql)?;
            if remaining > 0 {
                local.save(c)?;
                return Ok(json!({"done": false, "ops": n, "remaining": remaining}));
            }
            c.execute("DELETE FROM srs_meta WHERE key = ?1", [&marker]).map_err(sql)?;
            finish_migration(c, &mut local, profile, now, n)
        })
    }

    /// 追加一批本机内部操作（冲突解决、清除、还原点）：与 [SrsCore::sync2_apply_local] 同一条落库 / 投影 / 重放路径。
    pub(crate) fn sync2_append(&self, profile: &str, now: i64, bodies: Vec<Body>) -> Result<Value, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let mut local = match Local::load(c, profile)? {
                Some(l) => l,
                None => Local::create(c, profile, now)?,
            };
            let mut applied = applied_vv(c, profile)?;
            let mut t = Touched::default();
            for b in &bodies {
                let op = append_local(c, &mut local, &mut applied, b, now)?;
                project(c, profile, &op, now, true, &mut t)?;
            }
            local.save(c)?;
            let replayed = replay_touched(c, &t)?;
            Ok(json!({
                "marks": t.marks.to_json(),
                "replayed": replayed,
                "changed": t.entities_changed.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
                "purged": t.purged.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
            }))
        })
    }

    /// 冲突中心（设计 §5.3）：待用户定的破坏性并发。每项
    /// `{"id","kind":"delete_edit|delete_review|delete_move","entityKind","entity","by","others","at"}`。
    pub fn sync2_conflicts(&self, profile: &str) -> Result<Value, String> {
        let r = self.reader()?;
        let mut stmt = r
            .prepare(
                "SELECT id, kind, entity_kind, entity, device, other_count, at FROM sync2_conflicts \
                 WHERE profile_uid = ?1 ORDER BY at, id",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map([profile], |x| {
                Ok(json!({
                    "id": x.get::<_, String>(0)?,
                    "kind": x.get::<_, String>(1)?,
                    "entityKind": x.get::<_, String>(2)?,
                    "entity": x.get::<_, String>(3)?,
                    "by": <[u8; 16]>::try_from(x.get::<_, Vec<u8>>(4)?).map(|a| Id(a).text()).unwrap_or_default(),
                    "others": x.get::<_, i64>(5)?,
                    "at": x.get::<_, i64>(6)?,
                }))
            })
            .map_err(sql)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql)?;
        Ok(Value::Array(rows))
    }

    /// 解决一项冲突：`delete` = 以删除为准（一条因果覆盖并发方的新删除）；`keep` = 保留（一条覆盖删除的恢复）。
    /// 结论是普通操作，同步到各设备后同一冲突不会在别处再冒出来。
    pub fn sync2_resolve(&self, profile: &str, conflict: &str, delete: bool, now: i64) -> Result<Value, String> {
        let (kind, entity): (String, String) = {
            let r = self.reader()?;
            r.query_row(
                "SELECT entity_kind, entity FROM sync2_conflicts WHERE profile_uid = ?1 AND id = ?2",
                params![profile, conflict],
                |x| Ok((x.get(0)?, x.get(1)?)),
            )
            .map_err(|e| format!("no such conflict {conflict}: {e}"))?
        };
        let kind = EntKind::parse(&kind).ok_or("bad conflict entity kind")?;
        let value = if delete { json!(now) } else { Value::Null };
        self.sync2_append(
            profile,
            now,
            vec![Body::Edit(EditBody {
                kind,
                entity: Key::of(&entity),
                key: "deleted".into(),
                value: canonical(&value),
                machine: false,
                ts: 0,
                legacy: None,
            })],
        )
    }

    /// 彻底清除（设计 §10.5）：二次确认由界面做。先删除（保证实体不可见），再追加清除操作。
    pub fn sync2_purge(&self, profile: &str, kind: &str, entity: &str, now: i64) -> Result<Value, String> {
        let k = EntKind::parse(kind).ok_or("bad entity kind")?;
        self.sync2_append(
            profile,
            now,
            vec![
                Body::Edit(EditBody {
                    kind: k,
                    entity: Key::of(entity),
                    key: "deleted".into(),
                    value: canonical(&json!(now)),
                    machine: false,
                    ts: 0,
                    legacy: None,
                }),
                Body::Purge { kind: k, entity: Key::of(entity) },
            ],
        )
    }

    /// 自动 / 手动还原点（设计 §10.2）。
    pub fn sync2_checkpoint(&self, profile: &str, name: &str, reason: &str, now: i64) -> Result<Value, String> {
        self.sync2_append(profile, now, vec![Body::Checkpoint { name: name.to_owned(), reason: reason.to_owned() }])
    }

    /// 全量重放一个 profile 的全部卡（参数整体变更、自检用；设计 §3.4 `rebuild_all` 的调度部分）。
    pub fn sync2_replay_all(&self, profile: &str) -> Result<Vec<String>, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let cards: BTreeSet<String> = c
                .prepare("SELECT DISTINCT card_id FROM srs_review_logs WHERE profile_uid = ?1")
                .map_err(sql)?
                .query_map([profile], |r| r.get(0))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            Ok(replay_cards(c, &cards)?.into_iter().collect())
        })
    }
}

/// 设备 ID 文本 → 字节（FFI 入参）。
pub fn parse_device(s: &str) -> Result<Id, String> {
    Id::parse(s).ok_or_else(|| format!("bad device id {s}"))
}

#[cfg(test)]
mod mem_bench;
#[cfg(test)]
pub(crate) mod tests;
#[cfg(test)]
mod tests_causal;

impl SrsCore {
    /// 评分预览（Dart `SrsCardOps.preview` 的 v2 实现）：在这张卡的归属组重放到此刻的状态上，用当前牌组配置与
    /// 确定性 FSRS 算四个按钮的结果。[note] = 卡所属笔记（新卡没有日志时据它找牌组）。日界用调用方此刻的口径
    /// （与写进日志的 utcOff / rollover 相同）。
    pub fn sync2_preview(&self, profile: &str, card: &str, note: Option<&str>, now: i64, utc_off: i64, rollover: i64) -> Result<Value, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let tree = config::DeckTree::load(c, profile)?;
            let Group { rows, note: group_note } = group_of(c, card, note)?;
            // 此刻的生效配置：预览的是「现在作答」，作答落库时 `sc` 记下的也是这一份（[stamp_config]）。
            let cfg = if rows.is_empty() && note.is_none() {
                crate::sync2::sched::Config::default()
            } else {
                tree.config(&config::card_deck(c, &tree, card, group_note.as_deref())?)
            };
            let input: Vec<Row<'_>> = rows.iter().map(|(_, j, s, i, _)| Row { json: j, server_time: *s, intent: i.clone() }).collect();
            let day = crate::projection::Day { utc_offset_min: utc_off, rollover_hour: rollover };
            let (cur, mem, plan) = replay::preview(&input, &cfg, card, now, &day)?;
            let f = crate::sync2::sched::f32_json;
            Ok(json!({
                "current": cur.to_json(),
                "memoryBefore": mem.map(|m| json!({"s": f(m.s), "d": f(m.d), "sf": f(m.sf)})),
                "plan": plan.iter().map(|s| s.to_json()).collect::<Vec<_>>(),
                // 实际生效的参数（牌组没定参数 = 该算法默认参数；与旧 Dart `schedulingConfig(defaultsOf:)` 同口径，
                // 日志的 `params` 出处哈希按它算）。
                "params": if cfg.params.is_empty() {
                    crate::sync2::fsrs_det::Model::defaults(cfg.alg.version()).to_vec()
                } else {
                    cfg.params.clone()
                }
                .iter()
                .map(|p| f(*p))
                .collect::<Vec<_>>(),
                "memoryAlgorithm": match cfg.alg {
                    crate::sync2::sched::MemAlg::Fsrs6 => "fsrs6",
                    crate::sync2::sched::MemAlg::Fsrs7 => "fsrs7",
                },
            }))
        })
    }
}
