//! 本机状态类命令的新代实现（G7-3b）：`trust`、`device_hint`、`device_info`、`status`（同步页的状态读，规划 §2.1 要求
//! 契约里给出 `sync2_status` / `sync2_trust` / `sync2_device_hint` 的形状），以及换代后语义改变的 `dedup` /
//! `digest_heal`。
//!
//! # 形状契约（规划 §1.1 G10 行：JSON 形状不变）
//!
//! - `trust` → `{"trusted": bool, "released": n, …}`，外加 `writes.rs` 的统一项（`changed` / `purged` / …）。协议 3 的
//!   `marks` / `replayed` 是投影表细节，不再给（`replayed` 由统一项给，信任变化不写日志所以恒空）。
//! - `device_hint` → `{"changed": bool}`。
//! - `device_info` → `{"name", "nick", "model", "app", "platform", "changed"}`。
//! - `status` → 没有本机身份 `{"enabled": false}`；否则顶层键与协议 3 逐个相同：`enabled`、`device`、`nextSeq`、
//!   `migrated`、`ops`、`pending`、`unpublished`、`devices`、`selfInfo`、`locations`。`devices` 每行与协议 3
//!   （`transport.rs` `sync2_status` + `devices.rs` `status_extras`）同形：恒有 `device`、`self`、`applied`、`behind`、
//!   `seenAt`、`name`、`frozen`、`warning`、`digestMismatch`、`gap`、`blocking`、`state`（**同步状态** ok / behind /
//!   missing / upgrade / retired，不是信任）；还没信任的设备另带 `trust`（pending / rejected）、`trustSince`、
//!   `heldDeletes`、`heldPurges`；按有没有数据带 `model` / `app` / `platform` / `protocol` / `hint`；有重切件在等它的
//!   带 `relayBlocked`（第六波，`cmd/sync_park.rs`：`[{location, author, reason, pieces}]`，`reason` = `purge` /
//!   `pending` / `rejected`；这样的设备本机还没有日志也补一行，好让用户确认它）。`locations` 每行
//!   `location`、`uploaded`、`headGen`、`lastOk`。测试 `status_keeps_the_protocol_3_shape` 钉顶层键，
//!   `status_device_rows_match_protocol_3_key_for_key` 逐行钉设备行的键（含 Dart `SrsDeviceView.fromStatus` 读的）。
//! - `trust` 的拒绝只对还没信任的设备（协议 3 `reject`）：已可信 / 从没见过的设备报 `trust: device is already trusted`，
//!   什么都不写。
//!
//! # 存在哪
//!
//! - 设备补充名（`device_hint`）：新代库的 `srs_meta`，键 `device_hint/<设备>`。设备 ID 全局唯一、不分集合（协议 3
//!   同）。迁移（G7-2）可以把 `sync2_device_hint/*` 原样搬过来。
//! - 本机的人读名 / 型号 / 版本 / 平台（`device_info`）：`srs_meta`，键 `self_info/<col>`，值同协议 3 的
//!   `sync2_self_info/<profile>`。发 head（G8-7）从这里取 `name` 与扩展。
//! - 都不改表、不动 `SCHEMA`。
//!
//! # 换代后语义变了的
//!
//! - `dedup`：存量重复流收敛作业换代后不再运行（设计 §2.4 末），已有的结论随承袭日志过界。回包 `{"done": true}`、
//!   什么都不写，宿主照常把它当成「做完了」。
//! - `digest_heal`：协议 3 是「摘要不一致时重放改写」；新代的派生层是真相的纯函数，自愈就是把这个集合的派生表整个
//!   重建（`ingest.rs` `Settle::Rebuild`）。回包 `{"healed": 1, "healFailed": 0, "rebuilt": {…计数}}`。

use std::collections::HashMap;

use rusqlite::OptionalExtension;
use serde_json::{Map, Value, json};

use super::super::schema::sql;
use super::super::truth::{TRUST_PENDING, TRUST_REJECTED, Truth};
use super::snapshot;
use super::writes::{now_of, write};
use crate::sync2::id::Id;

/// 名字 / 型号等文本的长度上限（字符；协议 3 `devices.rs` 同值）。
const TEXT_MAX: usize = 64;

/// 设备行里照抄的扩展键（协议 3 `devices.rs` `EXT_KEYS` 同一组）。
const EXT_KEYS: [&str; 3] = ["model", "app", "platform"];

/// 设备行 `warning`：对端与本机在同一个版本向量下摘要不同（`digestMismatch`）。
pub(crate) const DIGEST_MISMATCH_WARNING: &str = "digest mismatch at the same version vector";

fn clip(s: &str) -> String {
    s.trim()
        .chars()
        .filter(|c| !c.is_control())
        .take(TEXT_MAX)
        .collect()
}

/// `status` 设备表的一行来源：设备与它日志末尾的 seq。
struct DevRow {
    id: Id,
    last: u64,
}

fn hint_key(device: &Id) -> String {
    format!("device_hint/{}", device.text())
}

fn self_info_key(col: i64) -> String {
    format!("self_info/{col}")
}

fn meta_get(t: &Truth<'_>, key: &str) -> Result<Option<String>, String> {
    t.conn()
        .prepare_cached("SELECT value FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .query_row([key], |r| r.get(0))
        .optional()
        .map_err(sql)
}

fn meta_set(t: &Truth<'_>, key: &str, value: &str) -> Result<(), String> {
    t.write(|| {
        t.conn()
            .prepare_cached(
                "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            )
            .map_err(sql)?
            .execute([key, value])
            .map_err(sql)?;
        Ok(())
    })
}

fn parse_obj(s: Option<String>) -> Map<String, Value> {
    s.and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default()
}

fn str_of<'a>(m: &'a Map<String, Value>, k: &str) -> &'a str {
    m.get(k).and_then(Value::as_str).unwrap_or("")
}

// ---------------------------------------------------------------------- trust

/// `trust`（信任 / 拒绝一台待确认的设备；协议 3 `trust.rs` `trust_on`）。[req]：`{"now", "device", "trust"?}`
/// （`trust` 缺省为真）。信任 = 删掉它的待确认 / 拒绝标记，扣着的删除与清除在收尾时放行（派生层重判，
/// `weigh.rs`）；拒绝 = 记成拒绝。本机身份自己 = 报错。`released` = 因它不被信任而扣着、这次放行的删除与清除条数。
pub fn trust(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let device = Id::parse(req["device"].as_str().ok_or("trust: missing device")?)
        .ok_or("trust: bad device")?;
    let trusted = req["trust"] != Value::Bool(false);
    write(t, col, |s| {
        if device == s.device() {
            return Err("trust: this device is always trusted".into());
        }
        // 拒绝只对还没信任的设备（协议 3 `trust.rs` `reject`：改到 0 行就报错）。可信设备的删除与清除早已生效，
        // 拒绝改变不了它们——这里要是照写一条拒绝，派生层会回溯扣住它已生效的删除（已删的实体重新可见）；从没见过的
        // 设备也不能预先记成拒绝（它以后一同步进来就是被拒状态）。宿主据这句报错显示「已信任 / 不认识的设备」。
        if !trusted && s.t.trust_of(col, &device)?.is_none() {
            return Err("trust: device is already trusted".into());
        }
        let held = s
            .settled()?
            .distrusted()?
            .into_iter()
            .filter(|op| op.device == device)
            .count();
        let state = if trusted { None } else { Some(TRUST_REJECTED) };
        if s.t.set_trust(col, &device, state, now)? {
            s.trust_changed();
        }
        Ok(json!({
            "trusted": trusted,
            "released": if trusted { held } else { 0 },
        }))
    })
}

/// 一台设备此刻的信任状态文本（`status` 的 `state` 里用）。
fn trust_text(state: Option<i64>) -> Option<&'static str> {
    match state {
        Some(TRUST_PENDING) => Some("pending"),
        Some(TRUST_REJECTED) => Some("rejected"),
        _ => None,
    }
}

// ---------------------------------------------------------------------- device_hint / device_info

/// `device_hint`（没有自报名字的设备的补充名；协议 3 `sync2_device_hint`）。[req]：`{"device", "hint"}`。空串 / 与现值
/// 相同 = `{"changed": false}`、不写。不需要本机身份（不写操作）。
pub fn device_hint(t: &Truth<'_>, req: &Value) -> Result<Value, String> {
    let device = Id::parse(
        req["device"]
            .as_str()
            .ok_or("device_hint: missing device")?,
    )
    .ok_or("device_hint: bad device")?;
    let hint = clip(req["hint"].as_str().ok_or("device_hint: missing hint")?);
    if hint.is_empty() {
        return Ok(json!({"changed": false}));
    }
    let key = hint_key(&device);
    t.tx(|t| {
        if meta_get(t, &key)?.as_deref() == Some(hint.as_str()) {
            return Ok(json!({"changed": false}));
        }
        meta_set(t, &key, &hint)?;
        Ok(json!({"changed": true}))
    })
}

/// `device_info`（本机的昵称 / 型号 / 版本 / 平台；协议 3 `sync2_device_info`）。[req] 里给了的键换成新值（裁剪），
/// 没给的不动。回包是合并后的视图（`name` = 昵称，没设就是型号）与 `changed`。集合没有本机身份 = 报错。
pub fn device_info(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let key = self_info_key(col);
    t.tx(|t| {
        if t.self_identity(col)?.is_none() {
            return Err(format!(
                "device_info: collection {col} has no local identity"
            ));
        }
        let cur = parse_obj(meta_get(t, &key)?);
        let mut next = cur.clone();
        for k in ["nick", "model", "app", "platform"] {
            if let Some(v) = req.get(k).and_then(Value::as_str) {
                next.insert(k.to_owned(), json!(clip(v)));
            }
        }
        let changed = next != cur;
        if changed {
            meta_set(t, &key, &Value::Object(next.clone()).to_string())?;
        }
        Ok(self_view(&next, changed))
    })
}

/// 本机在集合 [col] 里的人读名（昵称，没有就是型号；都没设过 = 空串）：`identity` 回包的 `name`（`cmd/identity.rs`），
/// 与 `device_info` 回包的 `name` 同一个取法。
pub(super) fn self_name(t: &Truth<'_>, col: i64) -> Result<String, String> {
    let m = parse_obj(meta_get(t, &self_info_key(col))?);
    Ok(self_view(&m, false)["name"]
        .as_str()
        .unwrap_or_default()
        .to_owned())
}

fn self_view(m: &Map<String, Value>, changed: bool) -> Value {
    let nick = str_of(m, "nick");
    json!({
        "name": if nick.is_empty() { str_of(m, "model") } else { nick },
        "nick": nick,
        "model": str_of(m, "model"),
        "app": str_of(m, "app"),
        "platform": str_of(m, "platform"),
        "changed": changed,
    })
}

// ---------------------------------------------------------------------- status

/// `status`（同步页的状态；协议 3 `sync2_status`，形状见文件头）。只读，一个读快照。
///
/// 取值（新代没有的东西给协议 3 的「没有」值，键照样在）：
/// - `ops`：这个集合全部设备日志的条数（真相层的操作 + 副本记录 + 空洞不算）；`pending`：收到了、因果还没齐的
///   （`op_wait`，G8-4）；`migrated` 恒为 true（新代库本来就是迁移之后的）。
/// - `devices`：真相层登记过的每台设备；`applied` = 本机日志末尾；`behind` = 各位置上它最新 head 的 seq 减
///   `applied`（不小于 0）；`name` = 对端自报名（`peers`），没有就是空串；`seenAt` = 本机见过的它最新 head 的写出时刻
///   （`plan` 记进 `peers.ext`，没见过 = null）；`frozen` = 本机换身份留下的旧身份（`sync_oldroot.rs`
///   `former_identities`）；`digestMismatch` = 它最近的 head 与本机上次写的 head 是同一个版本向量、摘要却不同（不自动
///   重建，见交接说明「G8-7b 同步补全」），此时 `warning` = [DIGEST_MISMATCH_WARNING]，否则 null；`gap` / `blocking`
///   = 原生等待缓冲 `op_wait` 里卡住的操作按「卡在谁身上」归账（[stuck]，协议 3 `devices.rs` `stuck` 同一个判据）；
///   `state` = 同步状态，判定顺序同协议 3 `status_extras`：本机 ok；对端自报的协议（`peers.ext` 的 `v`）低于本版本
///   head 声明的最低读者 [crate::gen4::MIN_READER] = upgrade；有 `gap` / `blocking` = missing；落后 = behind；其余 ok。
///   本机停用了的设备（G8-7 `retire`，`Truth::retired`）= `retired`，另带 `retiredAt`；协议 3 的 `sync2_retired/` 标记
///   不迁移（`carry.rs` 文件头）。没信任的设备带 `trust`（`pending` / `rejected`）/ `trustSince` / `heldDeletes` / `heldPurges`
///   （`weigh.rs` `distrusted_split` 按作者计）；有补充名的带 `hint`；扩展键与 `protocol` 本机取 `device_info`、对端取
///   `peers.ext`。
/// - `locations`：位置的加密记忆（`loc_state`）与位置上的 head（`loc_heads`）里出现过的位置；`uploaded` /
///   `headGen` = 本机身份在那个位置上最新 head 的 seq / 代号（没有 = 0）；`lastOk` = 上次核对通过的时刻。
/// - `unpublished` = 本机日志末尾 − 各位置 `uploaded` 的最小值（没有位置 = 末尾）。
pub fn status(t: &Truth<'_>, col: i64) -> Result<Value, String> {
    snapshot(t, |t| {
        let Some(me) = t.self_identity(col)? else {
            return Ok(json!({"enabled": false}));
        };
        let conn = t.conn();
        let last = t.last_of(col, &me.device)?;
        let devs = t.devices(col)?;
        let mut ops: i64 = 0;
        for d in &devs {
            let (lo, hi) = super::super::schema::k_range(d.dev);
            for q in [
                "SELECT COUNT(*) FROM ops WHERE k BETWEEN ?1 AND ?2",
                "SELECT COUNT(*) FROM op_alias WHERE k BETWEEN ?1 AND ?2",
            ] {
                let n: i64 = conn
                    .prepare_cached(q)
                    .map_err(sql)?
                    .query_row(rusqlite::params![lo, hi], |r| r.get(0))
                    .map_err(sql)?;
                ops += n;
            }
        }
        let pending = t.waiting_count(col)? as i64;
        // 位置：加密记忆与 head 里出现过的。
        let mut locs: std::collections::BTreeMap<String, (i64, i64, Option<i64>)> =
            std::collections::BTreeMap::new();
        {
            let mut stmt = conn
                .prepare_cached("SELECT loc_key, last_ok FROM loc_state WHERE col = ?1")
                .map_err(sql)?;
            let rows = stmt
                .query_map([col], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, Option<i64>>(1)?))
                })
                .map_err(sql)?;
            for row in rows {
                let (k, ok) = row.map_err(sql)?;
                locs.entry(k).or_insert((0, 0, None)).2 = ok;
            }
        }
        // 每台设备在各位置上最新 head 的 seq（`behind` 用）。
        let mut head_seq: std::collections::HashMap<Vec<u8>, i64> =
            std::collections::HashMap::new();
        {
            let mut stmt = conn
                .prepare_cached("SELECT loc_key, device, gen, seq FROM loc_heads WHERE col = ?1")
                .map_err(sql)?;
            let rows = stmt
                .query_map([col], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, Vec<u8>>(1)?,
                        r.get::<_, i64>(2)?,
                        r.get::<_, i64>(3)?,
                    ))
                })
                .map_err(sql)?;
            for row in rows {
                let (k, dev, gen_, seq) = row.map_err(sql)?;
                let e = head_seq.entry(dev.clone()).or_insert(0);
                *e = (*e).max(seq);
                let slot = locs.entry(k).or_insert((0, 0, None));
                if dev == me.device.0 {
                    slot.0 = slot.0.max(seq);
                    slot.1 = slot.1.max(gen_);
                }
            }
        }
        // 刚建、还没写过操作的本机身份不在 `devs` 里（设备表按日志登记），协议 3 的设备表恒有本机一行：补上。
        let mut rows: Vec<(Id, u64)> = devs.iter().map(|d| (d.id, d.last)).collect();
        if !rows.iter().any(|(id, _)| *id == me.device) {
            rows.push((me.device, 0));
        }
        // 停着的重切件（`cmd/sync_park.rs`）挂在等的那台设备一行上：它本机还没有日志（只读过 head 的重切者）也补一行，
        // 不然用户在同步页上找不到要确认的设备。
        let blocked = super::sync_park::blocked(t, col)?;
        for b in &blocked {
            if !rows.iter().any(|(id, _)| *id == b.wait) {
                rows.push((b.wait, 0));
            }
        }
        // 扣着的删除 / 清除，按作者分开计数（冲突中心「待确认的设备」卡片的条数）。
        let (held_dels, held_purges) = {
            let ix = super::super::derive::Index::new(t, col);
            ix.distrusted_split()?
        };
        let retired = t.retired(col)?;
        let (gap, blocking) = stuck(t, &devs, &retired)?;
        let count_of = |ops: &[crate::sync2::vv::OpId], d: &Id| -> i64 {
            ops.iter().filter(|o| o.device == *d).count() as i64
        };
        let info = parse_obj(meta_get(t, &self_info_key(col))?);
        let mine_digest = parse_obj(meta_get(t, &super::sync::self_digest_key(col))?);
        // 本机换身份留下的旧身份（不再写新操作，同步页标「已冻结」）。
        let former = super::sync_oldroot::former_identities(t, col)?;
        let mut devices = Vec::with_capacity(rows.len());
        for (id, last) in &rows {
            let d = DevRow {
                id: *id,
                last: *last,
            };
            let is_self = d.id == me.device;
            let peer = t.peer(col, &d.id)?;
            let applied = d.last as i64;
            let seen = parse_obj(peer.as_ref().and_then(|p| p.ext.clone()));
            // 摘要核对（交接说明「G8-7b 同步补全」摘要一节）：对端最近一份 head 与本机上次写 head 时是同一个版本向量、
            // 摘要却不同 = 两边见过同一组操作却算出了不同的状态。新代不自动重建（重建会掩盖派生层的缺陷），只报出来。
            let mismatch = !is_self
                && seen
                    .get(super::sync::SEEN_ACK_KEY)
                    .and_then(Value::as_str)
                    .is_some_and(|a| str_of(&mine_digest, "ack") == a)
                && seen
                    .get(super::sync::SEEN_DIGEST_KEY)
                    .and_then(Value::as_str)
                    .is_some_and(|g| str_of(&mine_digest, "digest") != g);
            let behind = head_seq
                .get(&d.id.0.to_vec())
                .map_or(0, |s| (s - applied).max(0));
            let mut row = json!({
                "device": d.id.text(),
                "self": is_self,
                "applied": applied,
                "behind": behind,
                "seenAt": seen.get(super::sync::SEEN_AT_KEY).cloned().unwrap_or(Value::Null),
                "name": peer.as_ref().and_then(|p| p.name.clone()).unwrap_or_default(),
                "frozen": former.contains(&d.id),
                "warning": if mismatch { json!(DIGEST_MISMATCH_WARNING) } else { Value::Null },
                "digestMismatch": mismatch,
            });
            let m = row.as_object_mut().expect("object");
            // 扩展信息：本机取 `device_info` 存的，对端取它自报的（`peers.ext`，G8-7 收 head 时写）。协议 3
            // `devices.rs` `status_extras` 同一组键。
            let ext = if is_self {
                info.clone()
            } else {
                parse_obj(peer.as_ref().and_then(|p| p.ext.clone()))
            };
            for k in EXT_KEYS {
                let v = str_of(&ext, k);
                if !v.is_empty() {
                    m.insert(k.into(), json!(v));
                }
            }
            let protocol = if is_self {
                Some(i64::from(crate::gen4::PROTOCOL))
            } else {
                ext.get("v").and_then(Value::as_i64)
            };
            if let Some(p) = protocol {
                m.insert("protocol".into(), json!(p));
            }
            if let Some(h) = meta_get(t, &hint_key(&d.id))? {
                m.insert("hint".into(), json!(h));
            }
            // 卡住的依赖（协议 3 的 `gap` / `blocking`）：等待缓冲按设备归账（[stuck]）。
            let g = gap.get(&d.id).copied().unwrap_or(0);
            let b = blocking.get(&d.id).copied().unwrap_or(0);
            m.insert("gap".into(), json!(g));
            m.insert("blocking".into(), json!(b));
            // `state` 只是同步状态（协议 3 `status_extras` 同一个判定顺序，函数注释）：停用（G8-7 `retire`）排在本机之后。
            let state = if is_self {
                "ok"
            } else if let Some(r) = retired.get(&d.id) {
                m.insert(
                    "retiredAt".into(),
                    r.get("at").cloned().unwrap_or(Value::Null),
                );
                if r.is_null() {
                    m.insert(
                        "warning".into(),
                        json!(super::super::sync_state::RETIRED_RECORD_UNREADABLE),
                    );
                }
                "retired"
            } else if protocol.is_some_and(|p| p < i64::from(crate::gen4::MIN_READER)) {
                "upgrade"
            } else if g > 0 || b > 0 {
                "missing"
            } else if behind > 0 {
                "behind"
            } else {
                "ok"
            };
            m.insert("state".into(), json!(state));
            // 信任单独放（协议 3 `trust.rs` `untrusted`）：只有还没信任的设备带。
            if let Some((trust, since)) = t.trust_entry(col, &d.id)? {
                m.insert(
                    "trust".into(),
                    json!(trust_text(Some(trust)).unwrap_or("pending")),
                );
                m.insert("trustSince".into(), json!(since));
                m.insert("heldDeletes".into(), json!(count_of(&held_dels, &d.id)));
                m.insert("heldPurges".into(), json!(count_of(&held_purges, &d.id)));
            }
            let waits: Vec<Value> = blocked
                .iter()
                .filter(|b| b.wait == d.id)
                .map(|b| {
                    json!({
                        "location": b.loc,
                        "author": b.author.text(),
                        "reason": b.reason,
                        "pieces": b.pieces,
                    })
                })
                .collect();
            if !waits.is_empty() {
                m.insert("relayBlocked".into(), Value::Array(waits));
            }
            devices.push(row);
        }
        let locations: Vec<Value> = locs
            .iter()
            .map(|(k, (up, gen_, ok))| {
                json!({"location": k, "uploaded": up, "headGen": gen_, "lastOk": ok})
            })
            .collect();
        let min_up = locs.values().map(|l| l.0).min().unwrap_or(0);
        let mut self_info = self_view(&info, false);
        if let Some(m) = self_info.as_object_mut() {
            m.remove("changed");
        }
        Ok(json!({
            "enabled": true,
            "device": me.device.text(),
            "nextSeq": last + 1,
            "migrated": true,
            "ops": ops,
            "pending": pending,
            "unpublished": last as i64 - min_up,
            "devices": devices,
            "selfInfo": self_info,
            "locations": locations,
        }))
    })
}

/// 原生等待缓冲（`op_wait`）里卡住的操作按「卡在谁身上」归账：`(gap, blocking)`，判据与协议 3 `devices.rs` `stuck`
/// 相同（协议 3 的缓冲是 `sync2_pending`）：
/// - `gap[X]`：X 自己的日志缺了更早的 seq（缓冲里 X 最早的一项越过了本机 X 日志末尾的下一格），X 在缓冲里的项数；
/// - `blocking[D]`：别的设备排在队首的那一项在等 D 还没到的操作（依赖里 D 的分量大于本机 D 日志的末尾），记到 D 头上，
///   条数是那台设备在缓冲里的项数。空洞（作者签出的已清除区间）没有依赖。
///
/// 停用了的设备上的分量不算卡住（协议 3 同口径，收段也不再等它们，`receive.rs` `deps_ready`）。每台设备一次主键区间
/// 计数、只解码队首一项（设备数次读），不扫整张缓冲表的操作体。
fn stuck(
    t: &Truth<'_>,
    devs: &[super::super::truth::DevInfo],
    retired: &std::collections::BTreeMap<Id, Value>,
) -> Result<(HashMap<Id, i64>, HashMap<Id, i64>), String> {
    let conn = t.conn();
    let applied: HashMap<Id, u64> = devs.iter().map(|d| (d.id, d.last)).collect();
    let mut gap: HashMap<Id, i64> = HashMap::new();
    let mut blocking: HashMap<Id, i64> = HashMap::new();
    for d in devs {
        let (lo, hi) = super::super::schema::k_range(d.dev);
        let (first, n): (Option<i64>, i64) = conn
            .prepare_cached("SELECT MIN(k), COUNT(*) FROM op_wait WHERE k BETWEEN ?1 AND ?2")
            .map_err(sql)?
            .query_row(rusqlite::params![lo, hi], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?;
        let Some(first) = first else {
            continue;
        };
        if super::super::schema::k_seq(first) > d.last + 1 {
            gap.insert(d.id, n);
            continue;
        }
        let raw: Option<Option<Vec<u8>>> = conn
            .prepare_cached("SELECT op FROM op_wait WHERE k = ?1 ORDER BY prev, chain LIMIT 1")
            .map_err(sql)?
            .query_row([first], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        let Some(Some(raw)) = raw else {
            continue;
        };
        let op = super::super::sync_state::op_of_bytes(&raw)?;
        for (dep, &s) in &op.deps.0 {
            if *dep != d.id
                && !retired.contains_key(dep)
                && s > applied.get(dep).copied().unwrap_or(0)
            {
                *blocking.entry(*dep).or_default() += n;
            }
        }
    }
    Ok((gap, blocking))
}

// ---------------------------------------------------------------------- dedup / digest_heal

/// `dedup`：换代后不再运行（文件头），回包 `{"done": true}`、什么都不写。
pub fn dedup(_t: &Truth<'_>, _col: i64) -> Result<Value, String> {
    Ok(json!({"done": true}))
}

/// `digest_heal`：把这个集合的派生表整个重建（文件头）。要本机身份（与别的写命令同一个前提）。
pub fn digest_heal(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    now_of(req)?;
    write(t, col, |s| {
        let st = s.rebuild()?;
        Ok(json!({
            "healed": 1,
            "healFailed": 0,
            "rebuilt": {
                "scanned": st.scanned,
                "cacheNotes": st.cache_notes,
                "cacheCards": st.cache_cards,
                "cacheStats": st.cache_stats,
            },
        }))
    })
}
