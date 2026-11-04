//! 设备可识别：本机的人读名 / 型号 / App 版本 / 平台随 head 发布，别的设备的记下来给同步页与冲突中心显示；
//! 「这台设备不用了」（停用）让因它缺段而卡住的待应用操作不再等它。
//!
//! 全部记账放在 `srs_meta`（键值表，不动 sync2 的表结构）：
//! - `sync2_self_info/<profile>`：本机 `{"nick", "model", "app", "platform"}`。人读名 = 昵称，没设就是型号，
//!   同时写进 `sync2_self.name`（head 主签名里的 `name`，老版本读者直接显示它）；型号 / 版本 / 平台进 head 的
//!   扩展（segment.rs [Head::ext]，单独签名，老读者忽略）。
//! - `sync2_device_ext/<profile>/<设备>`：别的设备最近一个 head 的扩展 + 它的协议版本 `v` + head 时刻 `at`。
//! - `sync2_device_hint/<设备>`：没有自报名字的设备的补充名（互联 host 知道是哪个已配对对端直接写了这台设备的段）。
//!   设备 ID 全局唯一，不分 profile。
//! - `sync2_retired/<profile>/<设备>`：停用标记 `{"at", "applied", "headSeq"}`。
//!
//! 停用的语义（[deps_ready]）：别的设备的操作的因果上下文里对停用设备的要求**不再等**——投递只看其余分量。停用
//! 设备自己的操作照旧按 seq 连续、链接得上才收（它的段之后真到了照样应用，不丢）；已经投递的操作不会因为取消停用
//! 而撤回。停用不删任何数据，标记可以撤销（[SrsCore::sync2_retire] 传 false），停用之后这台设备又写了新 head（它
//! 回来了）自动取消（[record_ext]）。

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value, json};

use super::{Local, applied_vv, in_savepoint, sql};
use crate::store::SrsCore;
use crate::sync2::codec::Reader;
use crate::sync2::id::Id;
use crate::sync2::op::Op;
use crate::sync2::segment::{self, Head};
use crate::sync2::vv::Vv;

/// head 扩展里认的键（其余丢掉，防转发 / 异常 head 往本机库里塞大块数据）。
const EXT_KEYS: [&str; 3] = ["model", "app", "platform"];
/// 名字 / 型号等文本的长度上限（字符）。
const TEXT_MAX: usize = 64;

fn clip(s: &str) -> String {
    s.trim()
        .chars()
        .filter(|c| !c.is_control())
        .take(TEXT_MAX)
        .collect()
}

fn meta_get(c: &Connection, key: &str) -> Result<Option<String>, String> {
    c.prepare_cached("SELECT value FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .query_row([key], |r| r.get(0))
        .optional()
        .map_err(sql)
}

fn meta_set(c: &Connection, key: &str, value: &str) -> Result<(), String> {
    c.prepare_cached("INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        .map_err(sql)?
        .execute(params![key, value])
        .map_err(sql)?;
    Ok(())
}

fn meta_del(c: &Connection, key: &str) -> Result<(), String> {
    c.prepare_cached("DELETE FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .execute([key])
        .map_err(sql)?;
    Ok(())
}

/// 前缀下的全部键值（[prefix] 按字面比较，profile 里的 `%` / `_` 不当通配符）。
fn meta_prefixed(c: &Connection, prefix: &str) -> Result<Vec<(String, String)>, String> {
    c.prepare_cached("SELECT key, value FROM srs_meta WHERE substr(key, 1, length(?1)) = ?1")
        .map_err(sql)?
        .query_map([prefix], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)
}

fn self_key(profile: &str) -> String {
    format!("sync2_self_info/{profile}")
}

fn ext_prefix(profile: &str) -> String {
    format!("sync2_device_ext/{profile}/")
}

fn retired_prefix(profile: &str) -> String {
    format!("sync2_retired/{profile}/")
}

fn hint_key(device: &Id) -> String {
    format!("sync2_device_hint/{}", device.text())
}

fn parse_obj(s: Option<String>) -> Map<String, Value> {
    s.and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default()
}

fn str_of<'a>(m: &'a Map<String, Value>, k: &str) -> &'a str {
    m.get(k).and_then(Value::as_str).unwrap_or("")
}

/// 本机写 head 时带的扩展（型号 / 版本 / 平台；都没有 = None，head 不带 `ext`）。
pub(crate) fn self_ext(c: &Connection, profile: &str) -> Result<Option<Value>, String> {
    let info = parse_obj(meta_get(c, &self_key(profile))?);
    let ext: Map<String, Value> = EXT_KEYS
        .iter()
        .filter_map(|k| {
            Some((*k).to_owned()).zip(
                Some(str_of(&info, k))
                    .filter(|v| !v.is_empty())
                    .map(|v| json!(v)),
            )
        })
        .collect();
    Ok(if ext.is_empty() {
        None
    } else {
        Some(Value::Object(ext))
    })
}

/// 记下别的设备刚收下的（更新的）head 的扩展与协议版本。停用之后它又写了 head：取消停用。
pub(crate) fn record_ext(c: &Connection, profile: &str, h: &Head) -> Result<(), String> {
    let mut out = Map::new();
    if let Some(ext) = h.ext.as_ref().and_then(Value::as_object) {
        for k in EXT_KEYS {
            if let Some(v) = ext
                .get(k)
                .and_then(Value::as_str)
                .map(clip)
                .filter(|v| !v.is_empty())
            {
                out.insert(k.to_owned(), json!(v));
            }
        }
    }
    out.insert("v".to_owned(), json!(h.protocol));
    out.insert("at".to_owned(), json!(h.at_ms));
    meta_set(
        c,
        &format!("{}{}", ext_prefix(profile), h.device.text()),
        &Value::Object(out).to_string(),
    )?;
    let rkey = format!("{}{}", retired_prefix(profile), h.device.text());
    if let Some(r) = meta_get(c, &rkey)? {
        let at = parse_obj(Some(r))
            .get("at")
            .and_then(Value::as_i64)
            .unwrap_or(i64::MAX);
        if h.at_ms > at {
            meta_del(c, &rkey)?;
        }
    }
    Ok(())
}

/// 停用了的设备。
pub(crate) fn retired_set(c: &Connection, profile: &str) -> Result<BTreeSet<Id>, String> {
    let prefix = retired_prefix(profile);
    Ok(meta_prefixed(c, &prefix)?
        .into_iter()
        .filter_map(|(k, _)| Id::parse(&k[prefix.len()..]))
        .collect())
}

/// 因果投递的「依赖都已应用」：[deps] 的每一分量都已应用，停用了的设备的分量不再等。
pub(crate) fn deps_ready(deps: &Vv, vv: &Vv, retired: &BTreeSet<Id>) -> bool {
    deps.0
        .iter()
        .all(|(d, &s)| s <= vv.get(d) || retired.contains(d))
}

/// 缓冲表里卡住的操作按「卡在谁身上」归账：`(gap, blocking)`。
/// - `gap[X]`：X 自己的操作缺了更早的 seq（X 的段没到 / 缺了一截），X 在缓冲里的条数；
/// - `blocking[D]`：别的设备排在队首的操作在等 D 还没收到的操作，那台设备在缓冲里的条数（D 是「缺段」的那台）。
///
/// 只解码每台设备队首那一条（设备数次读），不扫整张缓冲表。
fn stuck(
    c: &Connection,
    profile: &str,
    vv: &Vv,
    retired: &BTreeSet<Id>,
) -> Result<(BTreeMap<Id, i64>, BTreeMap<Id, i64>), String> {
    let heads: Vec<(Vec<u8>, i64, i64)> = c
        .prepare_cached("SELECT device, MIN(seq), COUNT(*) FROM sync2_pending WHERE profile_uid = srs_id(?1) GROUP BY device")
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut gap = BTreeMap::new();
    let mut blocking: BTreeMap<Id, i64> = BTreeMap::new();
    for (dev, first, n) in heads {
        let Ok(arr) = <[u8; 16]>::try_from(dev.as_slice()) else {
            continue;
        };
        let x = Id(arr);
        if first as u64 > vv.get(&x) + 1 {
            gap.insert(x, n);
            continue;
        }
        let raw: Option<Vec<u8>> = c
            .prepare_cached("SELECT op FROM sync2_pending WHERE profile_uid = srs_id(?1) AND device = ?2 AND seq = ?3")
            .map_err(sql)?
            .query_row(params![profile, dev, first], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        let Some(op) = raw.and_then(|raw| Op::read(&mut Reader::new(&raw)).ok()) else {
            continue;
        };
        for (d, &s) in &op.deps.0 {
            if *d != x && s > vv.get(d) && !retired.contains(d) {
                *blocking.entry(*d).or_default() += n;
            }
        }
    }
    Ok((gap, blocking))
}

/// [SrsCore::sync2_status] 每台设备的补充字段（按设备 ID 文本）：`model` / `app` / `platform` / `protocol` /
/// `hint` / `retiredAt` / `gap` / `blocking` / `state`（`ok` / `behind` / `missing` / `upgrade` / `retired`），
/// 以及本机信息 `selfInfo`。
pub(crate) fn status_extras(
    c: &Connection,
    profile: &str,
    local: &Local,
) -> Result<(BTreeMap<String, Value>, Value), String> {
    let vv = applied_vv(c, profile)?;
    let retired_rows: BTreeMap<String, Map<String, Value>> = {
        let prefix = retired_prefix(profile);
        meta_prefixed(c, &prefix)?
            .into_iter()
            .map(|(k, v)| (k[prefix.len()..].to_owned(), parse_obj(Some(v))))
            .collect()
    };
    let retired: BTreeSet<Id> = retired_rows.keys().filter_map(|k| Id::parse(k)).collect();
    let (gap, blocking) = stuck(c, profile, &vv, &retired)?;
    let exts: BTreeMap<String, Map<String, Value>> = {
        let prefix = ext_prefix(profile);
        meta_prefixed(c, &prefix)?
            .into_iter()
            .map(|(k, v)| (k[prefix.len()..].to_owned(), parse_obj(Some(v))))
            .collect()
    };
    let rows: Vec<(Vec<u8>, i64, i64)> = c
        .prepare_cached(
            "SELECT device, applied, head_seq FROM sync2_devices WHERE profile_uid = srs_id(?1)",
        )
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut out = BTreeMap::new();
    let self_info = parse_obj(meta_get(c, &self_key(profile))?);
    for (dev, applied, head_seq) in rows {
        let Ok(arr) = <[u8; 16]>::try_from(dev.as_slice()) else {
            continue;
        };
        let id = Id(arr);
        let text = id.text();
        let is_self = id == local.device;
        let mut m = Map::new();
        let ext = if is_self {
            self_info.clone()
        } else {
            exts.get(&text).cloned().unwrap_or_default()
        };
        for k in EXT_KEYS {
            let v = str_of(&ext, k);
            if !v.is_empty() {
                m.insert(k.to_owned(), json!(v));
            }
        }
        let protocol = if is_self {
            Some(segment::PROTOCOL as i64)
        } else {
            ext.get("v").and_then(Value::as_i64)
        };
        if let Some(p) = protocol {
            m.insert("protocol".to_owned(), json!(p));
        }
        if let Some(h) = meta_get(c, &hint_key(&id))? {
            m.insert("hint".to_owned(), json!(h));
        }
        let retired_at = retired_rows
            .get(&text)
            .and_then(|r| r.get("at"))
            .and_then(Value::as_i64);
        if let Some(at) = retired_at {
            m.insert("retiredAt".to_owned(), json!(at));
        }
        let g = gap.get(&id).copied().unwrap_or(0);
        let b = blocking.get(&id).copied().unwrap_or(0);
        m.insert("gap".to_owned(), json!(g));
        m.insert("blocking".to_owned(), json!(b));
        let state = if is_self {
            "ok"
        } else if retired_at.is_some() {
            "retired"
        } else if protocol.is_some_and(|p| p < segment::MIN_READER as i64) {
            // 它的协议比本机写出的数据要求的最低读者还旧：它读不了本机（以及同代设备）的数据，要升级。
            "upgrade"
        } else if g > 0 || b > 0 {
            "missing"
        } else if head_seq > applied {
            "behind"
        } else {
            "ok"
        };
        m.insert("state".to_owned(), json!(state));
        out.insert(text, Value::Object(m));
    }
    let self_json = json!({
        "name": local.name,
        "nick": str_of(&self_info, "nick"),
        "model": str_of(&self_info, "model"),
        "app": str_of(&self_info, "app"),
        "platform": str_of(&self_info, "platform"),
    });
    Ok((out, self_json))
}

impl SrsCore {
    /// 本机设备信息（[req] 里给了哪个键就改哪个：`model` / `app` / `platform` / `nick`；`nick` 给空串 = 清掉昵称、
    /// 回到型号）。人读名 = 昵称或型号，写进 `sync2_self.name`。没变就不进写锁（每轮同步前都会调）。返回
    /// `{"name", "nick", "model", "app", "platform", "changed"}`。
    pub fn sync2_device_info(&self, profile: &str, req: &Value, now: i64) -> Result<Value, String> {
        let merge = |cur: &Map<String, Value>| -> Map<String, Value> {
            let mut next = cur.clone();
            for k in ["nick", "model", "app", "platform"] {
                if let Some(v) = req.get(k).and_then(Value::as_str) {
                    next.insert(k.to_owned(), json!(clip(v)));
                }
            }
            next
        };
        let label = |m: &Map<String, Value>| -> String {
            let nick = str_of(m, "nick");
            if nick.is_empty() {
                str_of(m, "model").to_owned()
            } else {
                nick.to_owned()
            }
        };
        let view = |m: &Map<String, Value>, changed: bool| {
            json!({
                "name": label(m),
                "nick": str_of(m, "nick"),
                "model": str_of(m, "model"),
                "app": str_of(m, "app"),
                "platform": str_of(m, "platform"),
                "changed": changed,
            })
        };
        let unchanged = self.read_visible(|c| {
            let Some(l) = Local::load(c, profile)? else {
                return Ok(None);
            };
            let cur = parse_obj(meta_get(c, &self_key(profile))?);
            let next = merge(&cur);
            Ok((next == cur && l.name == label(&next)).then(|| view(&next, false)))
        })?;
        if let Some(v) = unchanged {
            return Ok(v);
        }
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            if Local::load(c, profile)?.is_none() {
                Local::create(c, profile, now)?;
            }
            let next = merge(&parse_obj(meta_get(c, &self_key(profile))?));
            meta_set(
                c,
                &self_key(profile),
                &Value::Object(next.clone()).to_string(),
            )?;
            c.execute(
                "UPDATE sync2_self SET name = ?2 WHERE profile_uid = srs_id(?1)",
                params![profile, label(&next)],
            )
            .map_err(sql)?;
            Ok(view(&next, true))
        })
    }

    /// 停用 / 取消停用一台（别的）设备。停用：它缺段而卡住的别的设备的操作不再等它（下一次投递起；调用方紧接着
    /// 跑一次投递，见 ffi.rs `retire`）。返回 `{"retired": bool}`。
    pub fn sync2_retire(
        &self,
        profile: &str,
        device: &str,
        retire: bool,
        now: i64,
    ) -> Result<Value, String> {
        let id = Id::parse(device).ok_or("retire: bad device")?;
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            if id == local.device {
                return Err("retire: cannot retire this device".into());
            }
            let row: Option<(i64, i64)> = c
                .query_row(
                    "SELECT applied, head_seq FROM sync2_devices WHERE profile_uid = srs_id(?1) AND device = ?2",
                    params![profile, id.0.to_vec()],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()
                .map_err(sql)?;
            let Some((applied, head_seq)) = row else {
                return Err("retire: unknown device".into());
            };
            let key = format!("{}{}", retired_prefix(profile), id.text());
            if retire {
                meta_set(
                    c,
                    &key,
                    &json!({"at": now, "applied": applied, "headSeq": head_seq}).to_string(),
                )?;
            } else {
                meta_del(c, &key)?;
            }
            Ok(json!({"retired": retire}))
        })
    }

    /// 给没有自报名字的设备记一个补充名（互联 host：已配对对端直接写了这台设备的段）。同名不写。
    pub fn sync2_device_hint(&self, device: &str, hint: &str) -> Result<Value, String> {
        let id = Id::parse(device).ok_or("device_hint: bad device")?;
        let hint = clip(hint);
        if hint.is_empty() {
            return Ok(json!({"changed": false}));
        }
        let key = hint_key(&id);
        if self.read_visible(|c| meta_get(c, &key))?.as_deref() == Some(hint.as_str()) {
            return Ok(json!({"changed": false}));
        }
        let w = self.writer()?;
        in_savepoint(&w, |c| meta_set(c, &key, &hint))?;
        Ok(json!({"changed": true}))
    }
}
