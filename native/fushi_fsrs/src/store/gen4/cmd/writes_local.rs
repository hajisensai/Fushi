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
//!   `heldDeletes`、`heldPurges`；按有没有数据带 `model` / `app` / `platform` / `protocol` / `hint`。`locations` 每行
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
///   `applied`（不小于 0）；`name` = 对端自报名（`peers`），没有就是空串；`seenAt` / `warning` 为 null、`frozen` /
///   `digestMismatch` 为 false（协议 3 的这几项来自旧 head 与旧摘要，新代的对应物由 G8-7 接）；`gap` / `blocking`
///   恒 0（G8-4 `op_wait` 接）；`state` = 同步状态（本机 ok，落后 = behind，其余 ok；retired / upgrade / missing 随
///   G8-4 / G8-7 接）。没信任的设备带 `trust`（`pending` / `rejected`）/ `trustSince` / `heldDeletes` / `heldPurges`
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
        let pending = t.waiting(col)?.len() as i64;
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
        // 扣着的删除 / 清除，按作者分开计数（冲突中心「待确认的设备」卡片的条数）。
        let (held_dels, held_purges) = {
            let ix = super::super::derive::Index::new(t, col);
            ix.distrusted_split()?
        };
        let count_of = |ops: &[crate::sync2::vv::OpId], d: &Id| -> i64 {
            ops.iter().filter(|o| o.device == *d).count() as i64
        };
        let info = parse_obj(meta_get(t, &self_info_key(col))?);
        let mut devices = Vec::with_capacity(rows.len());
        for (id, last) in &rows {
            let d = DevRow {
                id: *id,
                last: *last,
            };
            let is_self = d.id == me.device;
            let peer = t.peer(col, &d.id)?;
            let applied = d.last as i64;
            let behind = head_seq
                .get(&d.id.0.to_vec())
                .map_or(0, |s| (s - applied).max(0));
            let mut row = json!({
                "device": d.id.text(),
                "self": is_self,
                "applied": applied,
                "behind": behind,
                "seenAt": Value::Null,
                "name": peer.as_ref().and_then(|p| p.name.clone()).unwrap_or_default(),
                "frozen": false,
                "warning": Value::Null,
                "digestMismatch": false,
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
            // 卡住的依赖（协议 3 的 `gap` / `blocking`）由 G8-4 的 `op_wait` 接；接上之前恒 0，`missing` 不出现。
            m.insert("gap".into(), json!(0));
            m.insert("blocking".into(), json!(0));
            // `state` 只是同步状态（协议 3 同）：本机恒 ok；落后 = 位置上它的 head 比本机已应用的新。`retired` /
            // `upgrade`（停用、最低读者）随 G8-4 / G8-7 接。
            let state = if !is_self && behind > 0 {
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
