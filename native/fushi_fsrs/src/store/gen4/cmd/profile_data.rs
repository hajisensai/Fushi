//! 库级的 profile 数据命令（G9-5，规划 §2.2「删旧并入、收薄 profile 关联」；交接说明 §7 对照表里归 G9-5 的一组）：
//! 协议 3 `store/profile_data.rs` 的同名命令在新代里的去向。逐条：
//!
//! | 命令 | 新代 | 说明 |
//! |---|---|---|
//! | `profile_uids` | 实现 | 新代的「库里出现过数据的 uid」= `collections` 绑定的 profile（每个集合一行）；`orphanSweptAt` 记在新代库自己的 [ORPHAN_SWEEP_KEY] |
//! | `orphan_sweep_done` | 实现 | 收尾：只剩本机状态行（`local_state/<uid>`）、没有绑定的 uid 里不在 `keep` 中的，删掉那一行；`mark` 时记完成标记。新代没有按 profile 分的 `srs_meta` 键族与 `sync2_deps`：`deps` 恒为 0 |
//! | `meta_set_edit` | 实现 | 两个字符串集合（`retiredDevices` / `retiredUids`）照协议 3 的键与语义存在新代库的 `srs_meta`；迁移把协议 3 的两行带过来（`migrate.rs` [carry_library_meta]） |
//! | `profile_purge` | 实现 | 删一个 profile 的集合（`discard.rs`）与它的本机状态行；可带 `collection` 核对「用户确认的就是这个集合」 |
//! | `profile_merge_mark` | **删** | 新代不再起协议 3 式的 uid 并入：关联已有集合是 `collection_adopt` / `collection_join`（规划 §1.6） |
//! | `profile_merge_commit` | **改义** | 迁移带过来的「并入做到一半」的收尾（D23 / 规划 §2.2 G9-5）：见下 |
//!
//! # 半截并入的收尾（`profile_merge_commit {from, to, now}`）
//!
//! 协议 3 的并入（Dart `srs_profile_merge.dart`）把旧 uid 的事件重映射成新 uid 下的副本、改主库 uid、最后核对并删旧 uid；
//! 在核对之前中断的库带着标记 `profile_merge/<旧 uid>` = `{profileId, newUid}`。G7-2b 把这种库判 `mergeHalfDone` 拦下，
//! 用户卡死在「升级不了」。G9-5 改成：迁移照常把两个 uid 各迁成一个集合（旧 uid 的数据完整、新 uid 里是目标集合的数据加
//! 一部分重映射副本），标记原样带进新代库（`migrate.rs` [carry_library_meta]）；之后 Dart（知道主库那一侧：profile 现在
//! 指着哪个 uid）把主库 profile 改到 `to`、再发这条命令，内核**一个事务**里把 `from` 的集合并进 `to`：
//!
//! 1. 核对标记：`profile_merge/<from>` 在、`newUid == to`（不是半截并入的两个 profile 不许经这里合）；
//! 2. `from` 没有集合（迁移时它一条数据都没有）：只删标记；
//! 3. 否则把 `from` 的真相层导出成 `FSRS4EXP`（内存里；`export.rs`）、记下它的公钥表，**丢掉** `from` 的集合
//!    （`discard.rs`），再把它**方向固定地**并进 `to` 的集合（`identity.rs` [absorb_foreign]：在 `to` 的日志里写
//!    `Join{from: from 的集合}`，用户当初已经在关联页确认过并入，不再问）；然后导入公钥与操作（`import.rs`，同
//!    `.fushisrs` 导入同一条路）；
//! 4. 删标记与 `from` 的本机状态行。
//!
//! **方向固定、`to` 绝不改绑**（G9-5 第二轮复核）：`to` 是用户当初选定、别的设备在用的那个集合，收尾只能是 `from` 的
//! 数据进 `to` 的集合。所以不走 `collection_adopt`（它按 D27 比目录名定方向，`to` 的目录名更大时会把 `to` 改绑到
//! `from` 的集合；`to` 是空集合时会换绑到 `from` 的集合），也不在 `to` 没绑定时绑到 `from` 的集合：`to` 在本机还没有
//! 集合时先按打开 profile 的同一口径建（`identity`：集合标识 `collection_of(to)`、目录名 `to`——协议 3 时代采用过
//! `to` 的设备迁移后都在这个集合里），再吸收。三个方向（`to` 目录名比 `from` 大、`to` 没绑定、`to` 是空集合）的测试在
//! `profile_data_tests.rs` `finishing_a_half_done_merge_never_rebinds_the_target`。
//!
//! 已知的取舍：`from` 的集合若曾被别的设备持有（协议 3 时代 `from` 的目录被别的设备采用过），那台设备之后遇到 `to`
//! 时仍按 D27 判方向，可能吸收 `to` 而不是并进 `to`；它不会看到本机这条 `Join`（只在 `to` 的日志里）。`from` 是本机
//! 被并入方的旧 uid，正常只有本机持有，不另做处理。
//!
//! 整笔在分发器的一个 `BEGIN IMMEDIATE` 写事务里，`from` 的导出流（压缩过的 `FSRS4EXP`）整份在内存里：拆成多个事务会
//! 出现「`from` 已丢、`to` 只导入了一部分」的中间态（崩溃后无从续做）；同一事务里分批要么先吸收再边读 `from` 边导入
//! （导入会改 `to` 的派生层，读 `from` 的游标跨着写不安全），要么落临时文件（多一份要清理的用户数据），都不是低成本
//! 改动，记在交接说明 G9-5 节。
//!
//! 重映射副本与原件在新代里是同一个别名类（盐集合含两个 uid：派生 ID 按盐验上；协议 3 并入的兜底 ID 与 `merged-…` 写入者
//! 由别名层认回原件，`alias.rs` 的 `A_FALLBACK` / `alias_writer_ix`），所以不会出现两份。不丢：`from` 的每条操作都进了
//! `to` 的集合（导出不带的只有待投递的槽 `op_pending`——还没被这台设备应用、别的设备那里有原件——与本机状态：信任决定、
//! 暂扣、检查点、媒体记录、位置的加密记忆，按 `to` 的本机状态为准）。任何一步出错整笔回滚、标记留着，下次再来。
//!
//! # 事务与查询
//!
//! 写命令都是分发器的一个 `BEGIN IMMEDIATE` 事务；读命令一个读快照。新语句：[PROFILE_UIDS_SQL]（`collections` 全表，只有
//! 绑定数那么几行）、[LOCAL_STATE_UIDS_SQL]（`srs_meta` 主键区间）、[MERGE_MARKS_SQL]（同）——执行计划测试在
//! `profile_data_tests.rs`，测的是这里执行的同一份常量。

use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

use super::identity::{Emitting, identity_ensure, outcome_json};
use super::snapshot;
use crate::store::gen4::discard::{Discarded, discard_collection};
use crate::store::gen4::export::export_ops;
use crate::store::gen4::identity::{BindingChanged, Foreign, absorb_foreign};
use crate::store::gen4::import::{import_ops, import_peers};
use crate::store::gen4::local::KEY_PREFIX as LOCAL_STATE_PREFIX;
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::{Peer, Truth};
use crate::sync2::id::Id;

/// 新代库里一次性存量无主数据扫描的完成标记（值 = 完成时刻毫秒）。协议 3 的 `profile_orphan_sweep_v3` 不带过来：
/// 迁移把协议 3 库里的无主 uid 各迁成一个集合，新代库要再扫一次（同协议 3 换键重扫的口径）。
pub const ORPHAN_SWEEP_KEY: &str = "profile_orphan_sweep_g4";

/// 并入标记的键前缀（协议 3 `profile_data.rs` `MERGE_MARKER_PREFIX`，Dart `kSrsProfileMergeMarkerPrefix`）。
pub const MERGE_MARKER_PREFIX: &str = "profile_merge/";

/// `meta_set_edit` 认得的集合 → `srs_meta` 的键（与协议 3 相同）。
pub(crate) const META_SETS: [(&str, &str); 2] = [
    ("retiredDevices", "srs_retired_v2_devices"),
    ("retiredUids", "srs_retired_profile_uids"),
];

/// `profile_uids`：全部绑定的 profile（`collections` 全表；行数 = 绑定数）。
pub(crate) const PROFILE_UIDS_SQL: &str =
    "SELECT profile_uid FROM collections ORDER BY profile_uid";

/// 本机状态行的键（`local_state/` 开头，主键区间：`/` 的下一个字符是 `0`）。
pub(crate) const LOCAL_STATE_UIDS_SQL: &str =
    "SELECT key FROM srs_meta WHERE key >= 'local_state/' AND key < 'local_state0' ORDER BY key";

/// 并入标记（`profile_merge/` 开头，主键区间）。
pub(crate) const MERGE_MARKS_SQL: &str = "SELECT key, value FROM srs_meta WHERE key >= 'profile_merge/' AND key < 'profile_merge0' ORDER BY key";

/// `srs_meta` 的一个键（主键点读）。
const META_GET_SQL: &str = "SELECT value FROM srs_meta WHERE key = ?1";

fn meta_get(t: &Truth<'_>, key: &str) -> Result<Option<String>, String> {
    t.conn()
        .prepare_cached(META_GET_SQL)
        .map_err(sql)?
        .query_row([key], |r| r.get(0))
        .optional()
        .map_err(sql)
}

fn meta_put(t: &Truth<'_>, key: &str, value: &str) -> Result<(), String> {
    t.conn()
        .prepare_cached(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        )
        .map_err(sql)?
        .execute(params![key, value])
        .map_err(sql)?;
    Ok(())
}

fn meta_delete(t: &Truth<'_>, key: &str) -> Result<i64, String> {
    Ok(t.conn()
        .prepare_cached("DELETE FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .execute([key])
        .map_err(sql)? as i64)
}

fn strings(t: &Truth<'_>, q: &str) -> Result<Vec<String>, String> {
    let mut stmt = t.conn().prepare_cached(q).map_err(sql)?;
    let rows = stmt.query_map([], |r| r.get(0)).map_err(sql)?;
    rows.collect::<Result<_, _>>().map_err(sql)
}

// ---------------------------------------------------------------------- profile_uids / orphan_sweep_done

/// `profile_uids` → `{uids, orphanSweptAt}`：绑定的全部 profile（升序）与扫描完成时刻。一个读快照。
pub fn profile_uids(t: &Truth<'_>) -> Result<Value, String> {
    snapshot(t, |t| {
        let uids = strings(t, PROFILE_UIDS_SQL)?;
        let swept: Option<i64> = meta_get(t, ORPHAN_SWEEP_KEY)?.and_then(|v| v.parse().ok());
        Ok(json!({"uids": uids, "orphanSweptAt": swept}))
    })
}

/// 只剩本机状态行、没有绑定的 uid（升序）。
fn state_only_uids(t: &Truth<'_>) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for key in strings(t, LOCAL_STATE_UIDS_SQL)? {
        let uid = &key[LOCAL_STATE_PREFIX.len()..];
        if !uid.is_empty() && t.binding_of(uid)?.is_none() {
            out.push(uid.to_owned());
        }
    }
    Ok(out)
}

/// `orphan_sweep_done {now, keep, mark}` → `{metaUids, meta, deps}`（模块文件头对照表）。在分发器的写事务里：判
/// 「没有绑定」与删除同一个事务（Dart 算 `keep` 之后才开始的 profile 一打开就有了绑定，这里就不再动它）。幂等。
pub fn orphan_sweep_done(t: &Truth<'_>, req: &Value) -> Result<Value, String> {
    let now = req
        .get("now")
        .and_then(Value::as_i64)
        .ok_or("orphan_sweep_done: missing now")?;
    let keep: Vec<&str> = req
        .get("keep")
        .and_then(Value::as_array)
        .ok_or("orphan_sweep_done: missing keep")?
        .iter()
        .filter_map(Value::as_str)
        .collect();
    let mark = req.get("mark") == Some(&Value::Bool(true));
    let mut cleared = Vec::new();
    let mut meta = 0i64;
    for uid in state_only_uids(t)? {
        if keep.contains(&uid.as_str()) {
            continue;
        }
        meta += meta_delete(t, &[LOCAL_STATE_PREFIX, uid.as_str()].concat())?;
        cleared.push(uid);
    }
    if mark {
        meta_put(t, ORPHAN_SWEEP_KEY, &now.to_string())?;
    }
    Ok(json!({"metaUids": cleared, "meta": meta, "deps": 0}))
}

// ---------------------------------------------------------------------- meta_set_edit

fn meta_set_key(set: &str) -> Result<&'static str, String> {
    META_SETS
        .iter()
        .find(|(name, _)| *name == set)
        .map(|(_, key)| *key)
        .ok_or_else(|| format!("meta_set_edit: unknown set {set}"))
}

/// 字符串集合（JSON 数组；没有 / 坏了 / 不是数组 = 空；保留顺序、去重、非字符串元素不认）——协议 3 同一个读法。
fn read_meta_set(t: &Truth<'_>, key: &str) -> Result<Vec<String>, String> {
    let mut out: Vec<String> = Vec::new();
    if let Some(Ok(Value::Array(items))) =
        meta_get(t, key)?.map(|r| serde_json::from_str::<Value>(&r))
    {
        for x in items {
            if let Value::String(s) = x {
                if !out.contains(&s) {
                    out.push(s);
                }
            }
        }
    }
    Ok(out)
}

/// `meta_set_edit {set, add?, remove?}` 是不是只读（两样都没给）。
pub fn meta_set_read_only(req: &Value) -> bool {
    req.get("add").and_then(Value::as_str).is_none()
        && req.get("remove").and_then(Value::as_str).is_none()
}

/// `meta_set_edit {set, add?, remove?}` → `{values}`：读、改、写在调用方的一个事务里（只读时调用方给读快照）。已有元素
/// 的顺序不动、新值追加、没变化不写（协议 3 同语义）。
pub fn meta_set_edit(t: &Truth<'_>, req: &Value) -> Result<Value, String> {
    let set = req
        .get("set")
        .and_then(Value::as_str)
        .ok_or("meta_set_edit: missing set")?;
    let key = meta_set_key(set)?;
    let before = read_meta_set(t, key)?;
    let mut values = before.clone();
    if let Some(v) = req.get("remove").and_then(Value::as_str) {
        values.retain(|x| x != v);
    }
    if let Some(v) = req.get("add").and_then(Value::as_str) {
        if !values.iter().any(|x| x == v) {
            values.push(v.to_owned());
        }
    }
    if values != before {
        meta_put(t, key, &json!(values).to_string())?;
    }
    Ok(json!({"values": values}))
}

// ---------------------------------------------------------------------- profile_purge

fn discarded_json(d: &Discarded) -> Value {
    let tables: serde_json::Map<String, Value> = d
        .tables
        .iter()
        .map(|(t, n)| (t.clone(), json!(n)))
        .collect();
    json!({"deleted": d.rows, "tables": tables})
}

/// `profile_purge {profile, collection?}`（删 profile 时清它的集合数据）。回包同协议 3：删之前的规模
/// （`profile_footprint` 的 `{notes, cards, reviews, rows}`）+ `deleted`（总行数）+ `tables`（逐表，只列非零）。
///
/// - 只删这个 profile 绑定的那一个集合（`discard.rs`：每条语句都带它的集合号 / 设备区间）与它的本机状态行
///   `local_state/<profile>`；别的 profile 的集合、共用的内容表一行不碰。
/// - **确认**：`collection` = 调用方给用户看过、用户确认要删的集合标识（`collection_info` / `identity` 回的）。给了就核对：
///   profile 此刻绑的不是它（确认之后改绑 / 并入过）→ 报错、什么都不删。
/// - 没绑定的 profile：只删本机状态行，规模全 0（同协议 3：删一个没有数据的 uid 不报错）。
pub fn profile_purge(t: &Truth<'_>, profile: &str, req: &Value) -> Result<Value, String> {
    if profile.is_empty() {
        return Err("profile_purge: empty profile uid".to_owned());
    }
    let confirmed = match req.get("collection") {
        None | Some(Value::Null) => None,
        Some(v) => Some(
            v.as_str()
                .and_then(Id::parse)
                .ok_or_else(|| format!("profile_purge: bad collection {v}"))?,
        ),
    };
    let binding = t.binding_of(profile)?;
    let mut out = match &binding {
        Some(b) => {
            if let Some(c) = confirmed {
                if c != b.collection {
                    return Err(format!(
                        "profile_purge: profile {profile} is bound to collection {}, not the confirmed {c}; \
                         nothing was deleted",
                        b.collection
                    ));
                }
            }
            super::profile::profile_footprint(t, b.col)?
        }
        None => json!({"notes": 0, "cards": 0, "reviews": 0, "rows": 0}),
    };
    let mut gone = match &binding {
        Some(b) => discard_collection(t, b.col)?,
        None => Discarded::default(),
    };
    let state = meta_delete(t, &[LOCAL_STATE_PREFIX, profile].concat())?;
    if state > 0 {
        gone.rows += state;
        match gone.tables.iter_mut().find(|(t, _)| t == "srs_meta") {
            Some((_, n)) => *n += state,
            None => gone.tables.push(("srs_meta".to_owned(), state)),
        }
    }
    let d = discarded_json(&gone);
    out["deleted"] = d["deleted"].clone();
    out["tables"] = d["tables"].clone();
    Ok(out)
}

// ---------------------------------------------------------------------- 半截并入的收尾

/// 迁移带过来的并入标记（`{from, to, profileId}`；值读不懂的 `to` 为 None）。
pub fn merge_marks(t: &Truth<'_>) -> Result<Vec<(String, Option<String>, Option<i64>)>, String> {
    let mut stmt = t.conn().prepare_cached(MERGE_MARKS_SQL).map_err(sql)?;
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
        .map_err(sql)?;
    let mut out = Vec::new();
    for row in rows {
        let (key, value) = row.map_err(sql)?;
        let v: Value = serde_json::from_str(&value).unwrap_or(Value::Null);
        out.push((
            key[MERGE_MARKER_PREFIX.len()..].to_owned(),
            v.get("newUid").and_then(Value::as_str).map(str::to_owned),
            v.get("profileId").and_then(Value::as_i64),
        ));
    }
    Ok(out)
}

/// 集合 [col] 的公钥表（全部设备，含本机身份：导入方按公钥验原生日志）。
pub(super) fn peers_of(t: &Truth<'_>, col: i64) -> Result<Vec<Peer>, String> {
    let mut stmt = t
        .conn()
        .prepare_cached(super::fushisrs::PEERS_SQL)
        .map_err(sql)?;
    let rows = stmt
        .query_map([col], |r| {
            Ok((
                r.get::<_, Vec<u8>>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, Option<String>>(2)?,
            ))
        })
        .map_err(sql)?;
    let mut out = Vec::new();
    for row in rows {
        let (device, public, name) = row.map_err(sql)?;
        out.push(Peer {
            device: Id(device
                .try_into()
                .map_err(|_| "profile_merge_commit: bad device id in peers".to_owned())?),
            public: public
                .try_into()
                .map_err(|_| "profile_merge_commit: bad public key in peers".to_owned())?,
            name,
            ext: None,
            head_gen: None,
            first_seen: None,
        });
    }
    Ok(out)
}

/// `profile_merge_commit {from, to, now}`（模块文件头「半截并入的收尾」）。回包 `{done: true, folded, outcome?,
/// applied?}` + 绑定变了时分发器加的 `bindingChanged`（`to` 的绑定；`from` 的集合已经没了）。
pub fn profile_merge_commit(t: &Truth<'_>, req: &Value) -> Result<Emitting, String> {
    let s = |k: &str| {
        req.get(k)
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
            .ok_or_else(|| format!("profile_merge_commit: missing {k}"))
    };
    let (from, to) = (s("from")?, s("to")?);
    if from == to {
        return Err("profile_merge_commit: from and to are the same uid".to_owned());
    }
    let now = req
        .get("now")
        .and_then(Value::as_i64)
        .ok_or("profile_merge_commit: missing now")?;
    let marker = format!("{MERGE_MARKER_PREFIX}{from}");
    let recorded = meta_get(t, &marker)?
        .and_then(|v| serde_json::from_str::<Value>(&v).ok())
        .and_then(|v| v.get("newUid").and_then(Value::as_str).map(str::to_owned));
    if recorded.as_deref() != Some(to) {
        return Err(format!(
            "profile_merge_commit: no half-done merge of {from} into {to} on this device \
             (linking another collection is collection_adopt / collection_join)"
        ));
    }
    let mut v = json!({"done": true, "folded": false});
    let mut changed: Option<BindingChanged> = None;
    if let Some(src) = t.binding_of(from)? {
        let (bytes, _) = export_ops(t, src.col, Vec::new())?;
        let peers = peers_of(t, src.col)?;
        discard_collection(t, src.col)?;
        // `to` 没绑定 / 没有本机身份就按打开 profile 的口径建（模块文件头「方向固定、`to` 绝不改绑」），已有的不动。
        identity_ensure(t, to, now)?;
        let foreign = Foreign {
            collection: src.collection,
            dir: src.dir.clone(),
            salts: src.salts.clone(),
        };
        let out = absorb_foreign(t, to, &foreign, now)?;
        let col = t
            .binding_of(to)?
            .ok_or_else(|| format!("profile_merge_commit: {to} has no collection"))?
            .col;
        import_peers(t, col, peers)?;
        let got = import_ops(t, col, &bytes)?;
        changed = Some(BindingChanged {
            profile: to.to_owned(),
            col,
        });
        v["folded"] = json!(true);
        v["outcome"] = outcome_json(&out)["outcome"].clone();
        v["applied"] = json!(got.native_landed + got.voids_landed + got.slots_inserted);
    }
    meta_delete(t, &marker)?;
    meta_delete(t, &[LOCAL_STATE_PREFIX, from].concat())?;
    Ok((v, changed))
}

#[cfg(test)]
#[path = "profile_data_tests.rs"]
mod tests;
