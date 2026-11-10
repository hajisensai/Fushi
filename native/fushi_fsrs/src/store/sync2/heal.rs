//! 摘要不一致时自动重建（设计 §4.5；兼容项 ③）。
//!
//! 两台设备在同一版本向量下派生状态摘要的根不同 = 有一边的派生行是旧的（漏跑了迁移、重放被打断过……）或者确定性
//! bug。以前只能在同步页显示「数据不一致，请反馈」。现在：
//!
//! - 每台设备算摘要时同时算 256 个分组指纹（16 个相邻桶一组，digest.rs [super::digest::root_and_groups]），和根、
//!   版本向量出自同一个读事务、写在同一个 savepoint 里（`sync2_digest_dg/<profile>`），写 head 时放进 `ext.dg`
//!   （`{"dgv", "g"}`）。`ext` 不进主签名、旧读者忽略未知键（segment.rs [crate::sync2::segment::Head::ext]），head 的
//!   内容签名不算它（摘要变了不急着写 head）。
//! - 收下别的设备的 head 时记下它的组指纹（`sync2_dg_peer/<设备>/<profile>`，连同那份 head 的摘要串，配对用）。
//! - [SrsCore::sync2_digest_heal]（每轮在 `digest` 之后调）：摘要串 `@` 之后的部分（派生规则前缀 + 版本向量 + 扣留
//!   指纹）与本机**逐字相同**、根不同、两边都有同一 `dgv` 的组指纹时，比出不同的组集合 G，把本机日志落在 G 里的卡
//!   重放一遍（重放是全部操作的纯函数，做第二次写不出不同的行），**在同一命令里**重算摘要（不删键）。前缀、`dgv`、
//!   版本向量任一不同都不比。
//!
//! 防止反复重放（审查 H3）：去重键 `sync2_heal/<对端>/<profile>` = (派生规则, `dgv`, G, 本机这些组的指纹, 是否已核实)。
//! - 同一 (规则, `dgv`, G)、本机这些组的指纹没变：不重放。
//! - 重放改了 0 行：本机这些组是对的（不一致在对端，或在实体 / 修改记录投影、扣留差异这类重放修不了的地方），标成
//!   「已核实」，只报一次 `healFailed`，此后同一 G 只看不动。
//! - 重放改了行：重算摘要、记下修复后的指纹。下一轮对端还在同一 G 上不一致、本机指纹没变：报一次 `healFailed` 并标成
//!   已核实。
//!
//! 所以对端永远修不好时，本机对同一组集合最多重放一次（本机本来就对：改 0 行即核实）；本机确实修好了一部分而对端
//! 仍不一致时，之后本机这些组又被新的复习改动、指纹变了，最多再重放一次（改 0 行即核实）。版本向量前进本身不触发
//! 重放：键里没有版本向量。
//!
//! 对端是没有组指纹的旧版本：定位不了，不重放，按 (规则, 无组) 只报一次。

use std::collections::BTreeSet;

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use super::digest::{self, DG_VERSION};
use super::{Local, applied_vv, in_savepoint, replay_cards, sql};
use crate::store::SrsCore;
use crate::sync2::id::Id;
use crate::sync2::segment::Head;

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

fn own_dg_key(profile: &str) -> String {
    format!("sync2_digest_dg/{profile}")
}

fn peer_dg_key(profile: &str, device: &Id) -> String {
    format!("sync2_dg_peer/{}/{profile}", device.text())
}

fn heal_key(profile: &str, device: &Id) -> String {
    format!("sync2_heal/{}/{profile}", device.text())
}

/// 投影还没收齐：有待重放的卡、等因果的缓冲或待刷新的缓存。这时不算摘要、也不比（会比出假的不一致）。
pub(crate) fn unsettled(c: &Connection, profile: &str) -> Result<bool, String> {
    if super::transport::replay_is_pending(c, profile)?
        || super::transport::cache_is_pending(c, profile)?
    {
        return Ok(true);
    }
    c.query_row(
        "SELECT EXISTS(SELECT 1 FROM sync2_pending WHERE profile_uid = srs_id(?1))",
        [profile],
        |r| r.get(0),
    )
    .map_err(sql)
}

/// 记下本机摘要（`<根>@<tag>`）、算的时刻与同一次算出的组指纹。
pub(crate) fn store_digest(
    c: &Connection,
    profile: &str,
    now: i64,
    root: &str,
    groups: &str,
    tag: &str,
) -> Result<(), String> {
    meta_set(
        c,
        &format!("sync2_digest/{profile}"),
        &format!("{root}@{tag}"),
    )?;
    meta_set(c, &format!("sync2_digest_at/{profile}"), &now.to_string())?;
    meta_set(
        c,
        &own_dg_key(profile),
        &json!({"dgv": DG_VERSION, "r": root, "g": groups}).to_string(),
    )
}

/// 写 head 时的扩展：本机的组指纹与 head 里的摘要串 [digest] 出自同一次计算时才带上 `dg`。
pub(crate) fn with_dg(
    ext: Option<Value>,
    c: &Connection,
    profile: &str,
    digest: &str,
) -> Result<Option<Value>, String> {
    let root = digest.split_once('@').map_or("", |(r, _)| r);
    let Some(own) = meta_get(c, &own_dg_key(profile))?
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .filter(|v| !root.is_empty() && v["r"].as_str() == Some(root))
    else {
        return Ok(ext);
    };
    let mut m = match ext {
        Some(Value::Object(m)) => m,
        _ => serde_json::Map::new(),
    };
    m.insert("dg".to_owned(), json!({"dgv": own["dgv"], "g": own["g"]}));
    Ok(Some(Value::Object(m)))
}

/// 记下别的设备刚收下的 head 里的组指纹（连同它的摘要串：比对时只用与 `sync2_devices.digest` 配对的那份）。
pub(crate) fn record_peer_dg(c: &Connection, profile: &str, h: &Head) -> Result<(), String> {
    let key = peer_dg_key(profile, &h.device);
    let dg = h.ext.as_ref().and_then(|e| e.get("dg"));
    match dg.and_then(|d| Some((d["dgv"].as_u64()?, d["g"].as_str()?))) {
        Some((dgv, g)) if g.len() == digest::GROUPS * digest::GROUP_HEX => meta_set(
            c,
            &key,
            &json!({"dgv": dgv, "g": g, "digest": h.digest}).to_string(),
        ),
        _ => {
            c.prepare_cached("DELETE FROM srs_meta WHERE key = ?1")
                .map_err(sql)?
                .execute([&key])
                .map_err(sql)?;
            Ok(())
        }
    }
}

/// 本机这些组的指纹（去重键的一部分）。
fn fp_of(groups: &str, g: &[usize]) -> String {
    let mut h = blake3::Hasher::new();
    for i in g {
        h.update(&groups.as_bytes()[i * digest::GROUP_HEX..(i + 1) * digest::GROUP_HEX]);
    }
    h.finalize().to_hex()[..16].to_owned()
}

/// 本机三张被摘要的表里落在 [g] 组的行数（`e` / `f` / `l`）：上报用。
fn rows_in(c: &Connection, profile: &str, g: &[usize]) -> Result<Value, String> {
    let gs = json!(g).to_string();
    let mut out = serde_json::Map::new();
    for (table, tag) in [
        ("srs_entities", "e"),
        ("srs_field_edits", "f"),
        ("srs_review_logs", "l"),
    ] {
        let n: i64 = c
            .query_row(
                &format!(
                    "SELECT COUNT(*) FROM {table} WHERE profile_uid = srs_id(?1) \
                     AND sync2_dg_bucket(id) / {} IN (SELECT value FROM json_each(?2))",
                    digest::GROUP_BUCKETS
                ),
                params![profile, gs],
                |r| r.get(0),
            )
            .map_err(sql)?;
        out.insert(tag.to_owned(), json!(n));
    }
    Ok(Value::Object(out))
}

/// 本机日志落在 [g] 组的卡。
fn cards_in(c: &Connection, profile: &str, g: &[usize]) -> Result<BTreeSet<String>, String> {
    c.prepare(&format!(
        "SELECT DISTINCT srs_idt(card_id) AS card_id FROM srs_review_logs WHERE profile_uid = srs_id(?1) \
         AND sync2_dg_bucket(id) / {} IN (SELECT value FROM json_each(?2))",
        digest::GROUP_BUCKETS
    ))
    .map_err(sql)?
    .query_map(params![profile, json!(g).to_string()], |r| r.get(0))
    .map_err(sql)?
    .collect::<Result<_, _>>()
    .map_err(sql)
}

/// 去重记录。
#[derive(Debug, Clone, PartialEq)]
struct Rec {
    rules: Option<u32>,
    dgv: Option<u64>,
    groups: Option<Vec<usize>>,
    fp: String,
    verified: bool,
}

impl Rec {
    fn parse(s: &str) -> Option<Rec> {
        let v: Value = serde_json::from_str(s).ok()?;
        Some(Rec {
            rules: v["rules"].as_u64().map(|x| x as u32),
            dgv: v["dgv"].as_u64(),
            groups: v["groups"].as_array().map(|a| {
                a.iter()
                    .filter_map(Value::as_u64)
                    .map(|x| x as usize)
                    .collect()
            }),
            fp: v["fp"].as_str().unwrap_or("").to_owned(),
            verified: v["verified"] == json!(true),
        })
    }

    fn to_json(&self) -> String {
        json!({
            "rules": self.rules,
            "dgv": self.dgv,
            "groups": self.groups,
            "fp": self.fp,
            "verified": self.verified,
        })
        .to_string()
    }
}

/// 本机记下的摘要：(根, `@` 之后的 tag, 组指纹)。组指纹与根不配对（不该发生）时为 None。
fn own_digest(
    c: &Connection,
    profile: &str,
) -> Result<Option<(String, String, Option<String>)>, String> {
    let Some(d) = meta_get(c, &format!("sync2_digest/{profile}"))? else {
        return Ok(None);
    };
    let Some((root, tag)) = d.split_once('@') else {
        return Ok(None);
    };
    let groups = meta_get(c, &own_dg_key(profile))?
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .filter(|v| v["r"].as_str() == Some(root) && v["dgv"].as_u64() == Some(DG_VERSION.into()))
        .and_then(|v| v["g"].as_str().map(str::to_owned));
    Ok(Some((root.to_owned(), tag.to_owned(), groups)))
}

impl SrsCore {
    /// 摘要不一致的自动重建（文件头）。返回 `{"replayed": [重放改写了日志的卡], "healed": [{device, groups, cards}],
    /// "healFailed": [{device, groups, rows: {e, f, l}, app, reason}]}`；改投影（`replayed`），分发器在同一次调用里
    /// 刷新缓存。`healFailed` 每个 (对端, 组集合) 只出现一次，调用方照报即可。
    pub fn sync2_digest_heal(&self, profile: &str, now: i64) -> Result<Value, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let mut replayed: BTreeSet<String> = BTreeSet::new();
            let mut healed: Vec<Value> = Vec::new();
            let mut failed: Vec<Value> = Vec::new();
            let out = |replayed: BTreeSet<String>, healed, failed| {
                Ok(json!({"replayed": replayed, "healed": healed, "healFailed": failed}))
            };
            let Some(local) = Local::load(c, profile)? else {
                return out(replayed, healed, failed);
            };
            if unsettled(c, profile)? {
                return out(replayed, healed, failed);
            }
            let Some((mut root, tag, mut groups)) = own_digest(c, profile)? else {
                return out(replayed, healed, failed);
            };
            let rules = digest::derive_rules_of(&format!("@{tag}"));
            let peers: Vec<(Vec<u8>, String)> = c
                .prepare_cached(
                    "SELECT device, digest FROM sync2_devices WHERE profile_uid = srs_id(?1) AND digest IS NOT NULL AND digest != ''",
                )
                .map_err(sql)?
                .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for (dev, peer_digest) in peers {
                let Ok(arr) = <[u8; 16]>::try_from(dev.as_slice()) else {
                    continue;
                };
                let device = Id(arr);
                if device == local.device {
                    continue;
                }
                let Some((peer_root, peer_tag)) = peer_digest.split_once('@') else {
                    continue;
                };
                // 只比派生规则、版本向量（与扣留指纹）逐字相同的。
                if peer_tag != tag || peer_root == root {
                    continue;
                }
                let peer_dg = meta_get(c, &peer_dg_key(profile, &device))?
                    .and_then(|s| serde_json::from_str::<Value>(&s).ok())
                    .filter(|v| v["digest"].as_str() == Some(peer_digest.as_str()));
                let app = super::devices::peer_app(c, profile, &device)?;
                let key = heal_key(profile, &device);
                let rec = meta_get(c, &key)?.and_then(|s| Rec::parse(&s));
                let (Some(mine), Some(peer)) = (groups.as_deref(), peer_dg.as_ref()) else {
                    // 对端没有组指纹（旧版本）/ 本机组指纹缺：定位不了，不重放，按规则只报一次。
                    let r = Rec {
                        rules,
                        dgv: None,
                        groups: None,
                        fp: String::new(),
                        verified: true,
                    };
                    if rec.as_ref() != Some(&r) {
                        failed.push(json!({"device": device.text(), "groups": Value::Null, "app": app, "reason": "noGroups"}));
                        meta_set(c, &key, &r.to_json())?;
                    }
                    continue;
                };
                // 组指纹版本不同：分组方式不同，比出来的「不同组」不可信，不比。
                if peer["dgv"].as_u64() != Some(DG_VERSION.into()) {
                    continue;
                }
                let Some(g) = peer["g"]
                    .as_str()
                    .and_then(|pg| digest::differing_groups(mine, pg))
                    .filter(|g| !g.is_empty())
                else {
                    continue;
                };
                let fp = fp_of(mine, &g);
                let same_set = rec.as_ref().is_some_and(|r| {
                    r.rules == rules
                        && r.dgv == Some(DG_VERSION.into())
                        && r.groups.as_ref() == Some(&g)
                });
                if same_set {
                    let r = rec.as_ref().expect("same set");
                    if r.verified {
                        continue;
                    }
                    if r.fp == fp {
                        // 上次重放修好了本机这一侧、对端在同一组上仍不一致：报一次，之后只看不动。
                        failed.push(json!({"device": device.text(), "groups": g, "rows": rows_in(c, profile, &g)?, "app": app, "reason": "peerStillDiffers"}));
                        meta_set(
                            c,
                            &key,
                            &Rec {
                                verified: true,
                                ..r.clone()
                            }
                            .to_json(),
                        )?;
                        continue;
                    }
                }
                let cards = cards_in(c, profile, &g)?;
                let changed = replay_cards(c, &cards)?;
                if changed.is_empty() {
                    // 本机这些组重放不出任何变化：不一致不在本机日志的派生上，只报一次。
                    failed.push(json!({"device": device.text(), "groups": g, "rows": rows_in(c, profile, &g)?, "app": app, "reason": "replayChangedNothing"}));
                    meta_set(
                        c,
                        &key,
                        &Rec {
                            rules,
                            dgv: Some(DG_VERSION.into()),
                            groups: Some(g),
                            fp,
                            verified: true,
                        }
                        .to_json(),
                    )?;
                    continue;
                }
                // 修了：同一命令里重算摘要（版本向量没变，tag 不变；不删键），记下修复后的指纹。
                let (r2, g2) = digest::root_and_groups(c, profile)?;
                let vv = applied_vv(c, profile)?;
                let tag2 = super::trust::digest_vv_tag(c, profile, &vv)?;
                store_digest(c, profile, now, &r2, &g2, &tag2)?;
                healed.push(json!({"device": device.text(), "groups": g, "cards": changed.len()}));
                meta_set(
                    c,
                    &key,
                    &Rec {
                        rules,
                        dgv: Some(DG_VERSION.into()),
                        groups: Some(g.clone()),
                        fp: fp_of(&g2, &g),
                        verified: false,
                    }
                    .to_json(),
                )?;
                replayed.extend(changed);
                root = r2;
                groups = Some(g2);
                if tag2 != tag {
                    break;
                }
            }
            out(replayed, healed, failed)
        })
    }
}
