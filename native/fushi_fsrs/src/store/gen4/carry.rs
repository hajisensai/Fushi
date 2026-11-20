//! 迁移时带过去的本机状态（设计 §2.2 末、§6.1 第 3 步，D11；规划 §1.4 第 5–7 步、缺口 G-2）。预演（`dryrun.rs`）与
//! 真迁移（`migrate.rs`）走同一份：[carry_local] / [carry_cut_points] 由两边共用的阶段代码调。
//!
//! 旧库只读（协议 3 的 `srs.db`，连接上注册过 `srs_id` / `srs_idt`），写进新代库同一个集合 `col`：
//!
//! | 协议 3 | 新代 | 说明 |
//! |---|---|---|
//! | `sync2_devices`（公钥、名字）+ `srs_meta` 的 `sync2_device_ext/<profile>/<设备>`（扩展信息）+ `sync2_device_hint/<设备>`（补充名） | `peers` | 没有公钥的行不带（新代的公钥先到先得，空的公钥没有意义），计数。名字取设备自报的，没有就取补充名（显示口径相同）。协议 3 的 head 代号不带（新代 head 另起编号） |
//! | `sync2_held` / `sync2_checkpoints` / `sync2_media_local` | `held` / `checkpoints` / `media_local` | 照搬，`profile_uid` 换成 `col`；`held.entity` 存 ID 文本（协议 3 存 `srs_id` 的存储值） |
//! | `sync2_media_at` / `sync2_media_seeded` | `media_at` / `media_listed` | `media::seed_legacy`（G8-3） |
//! | `srs_meta` 的 `sync2_sealed/<位置>/<profile>` + `sync2_locations` 里带 `#e<指纹>` 的上传进度 | `loc_state`（`sealed = 1`） | BUG-4299：本机一旦见过「这个位置是加密的」就永不往那里写明文；漏带就回到那个 bug。记录坏了也按见过算（协议 3 同口径） |
//! | `srs_meta` 的 `srs_collection_bound/<profile>` | `collections.state / via / at` | 认不出的值当没有记录（协议 3 `binding.rs` 同一份解析） |
//! | `sync2_trust` | `trust` | 在灌入那一步（`import.rs`）已经带了 |
//! | `sync2_self`（签名钥匙、设备 ID、日志末尾、HLC） | `self_` | [legacy_self]：钥匙沿用，新身份的 `prev` 指向旧设备的日志末尾（设计 §3.3），时钟接着旧身份走 |
//! | `sync2_segments`（本机协议 3 已切的段） | `log_marks` | [carry_cut_points]：在承袭日志上多记这几处完整原链值，做切点（G8-5 只在记了链值的 seq 上切承袭段）。灌入已记每 4096 条与末尾 |
//!
//! 从头对账、不带的：位置进度、段清单、中继、旧根清单（D11）；停用标记 `sync2_retired/` 与 head 扩展里的协议版本只在协议 3
//! 的投递 / 显示里用，新代由 G8 重建。
//!
//! 都写在调用方的同一个事务里（`Truth::tx` 可嵌套）；新代库是迁移的临时文件，每次迁移都从空文件开始，所以这里只写不比。

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;

use super::media;
use super::schema::sql;
use super::truth::{BindStage, Peer, PeerPut, Truth};
use crate::gen4::head::PrevIdentity;
use crate::gen4::heritage::fingerprint;
use crate::store::sync2::devices::{ext_prefix, hint_key};
use crate::store::sync2::sealed::SEALED_PREFIX;
use crate::sync2::hlc::Hlc;
use crate::sync2::id::Id;
use crate::sync2::segment::{CHAIN_ZERO, Chain};
use crate::sync2::vv::OpId;

/// 协议 3 里本机在一个 profile 下的身份（`sync2_self` 的一行）。`Debug` 不打印钥匙种子。
#[derive(Clone, PartialEq, Eq)]
pub struct LegacySelf {
    pub device: Id,
    /// 签名钥匙种子（换代后沿用，设计 §3.3）。
    pub key_seed: [u8; 32],
    /// 本机日志末尾的 seq（`next_seq - 1`；0 = 一条都没写过）。
    pub last: u64,
    /// 末尾处的完整链值（0 条时是 [CHAIN_ZERO]）。
    pub chain: Chain,
    /// 本机时钟发出过 / 吸收过的最大 HLC（`hlc_wall`, `hlc_logical`）。
    pub wall: i64,
    pub logical: u32,
    /// 设备自报的名字（head 主签名里的 `name`）。
    pub name: String,
}

impl std::fmt::Debug for LegacySelf {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LegacySelf")
            .field("device", &self.device)
            .field("last", &self.last)
            .field("wall", &self.wall)
            .field("logical", &self.logical)
            .finish_non_exhaustive()
    }
}

impl LegacySelf {
    /// 新身份的 `prev`：旧设备、日志末尾、该处的完整链值（设计 §3.3）。
    pub fn prev(&self) -> PrevIdentity {
        PrevIdentity {
            device: self.device,
            seq: self.last,
            chain: self.chain,
        }
    }

    /// 旧身份时钟的 HLC，挂到新设备 [device] 名下（新身份的时钟从这里接着走）。从没走过（0:0）= None。
    pub fn clock_for(&self, device: Id) -> Option<Hlc> {
        (self.wall > 0 || self.logical > 0).then_some(Hlc {
            wall: self.wall,
            logical: self.logical,
            device,
        })
    }
}

fn blob<const N: usize>(b: Vec<u8>, what: &str) -> Result<[u8; N], String> {
    b.try_into()
        .map_err(|_| format!("gen4 carry: legacy {what} is not {N} bytes"))
}

/// [profile] 在协议 3 库里的本机身份；没有 `sync2_self` 行 = None（这样的 profile `legacy::preflight` 不让迁移）。形状不对
/// （ID / 钥匙 / 链值长度、`next_seq` < 1、0 条却不在链起点）报错：迁移不在坏身份上接着建新身份。
pub fn legacy_self(src: &Connection, profile: &str) -> Result<Option<LegacySelf>, String> {
    let row = src
        .prepare_cached(
            "SELECT device, key_seed, next_seq, chain, hlc_wall, hlc_logical, name FROM sync2_self \
             WHERE profile_uid = srs_id(?1)",
        )
        .map_err(sql)?
        .query_row([profile], |r| {
            Ok((
                r.get::<_, Vec<u8>>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, Vec<u8>>(3)?,
                r.get::<_, i64>(4)?,
                r.get::<_, i64>(5)?,
                r.get::<_, String>(6)?,
            ))
        })
        .optional()
        .map_err(sql)?;
    let Some((device, seed, next, chain, wall, logical, name)) = row else {
        return Ok(None);
    };
    if next < 1 {
        return Err(format!(
            "gen4 carry: profile {profile} has a bad next_seq {next}"
        ));
    }
    let chain: Chain = blob(chain, "chain")?;
    let last = (next - 1) as u64;
    if last == 0 && chain != CHAIN_ZERO {
        return Err(format!(
            "gen4 carry: profile {profile} has no ops but its chain is not at the start"
        ));
    }
    Ok(Some(LegacySelf {
        device: Id(blob(device, "device id")?),
        key_seed: blob(seed, "key seed")?,
        last,
        chain,
        wall,
        logical: u32::try_from(logical).map_err(|_| {
            format!("gen4 carry: profile {profile} has a bad hlc logical {logical}")
        })?,
        name,
    }))
}

/// [carry_local] 带过来了什么（报告用）。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Carried {
    pub peers: u64,
    /// 协议 3 里没有公钥的设备行（不带）。
    pub peers_without_key: u64,
    pub held: u64,
    pub checkpoints: u64,
    pub media_local: u64,
    /// `media::seed_legacy` 的结果。
    pub media_at: u64,
    pub media_skipped: u64,
    pub media_listed: u64,
    /// 媒体事实里不超前的最大 HLC（新身份的时钟要吸收它，同 `media::ingest` 的口径）。
    pub media_hlc: Option<Hlc>,
    /// 带了超前 HLC 的媒体事实作者（只报，不吸收）。
    pub media_ahead: u64,
    /// 记成「见过加密」的位置。
    pub sealed_locations: u64,
    /// 带过来的绑定状态（`provisional` / `settled`；没有记录 = None）。
    pub binding: Option<&'static str>,
}

impl Carried {
    pub fn json(&self) -> Value {
        serde_json::json!({
            "peers": self.peers, "peersWithoutKey": self.peers_without_key, "held": self.held,
            "checkpoints": self.checkpoints, "mediaLocal": self.media_local, "mediaAt": self.media_at,
            "mediaSkipped": self.media_skipped, "mediaListed": self.media_listed,
            "mediaAhead": self.media_ahead, "sealedLocations": self.sealed_locations,
            "binding": self.binding,
        })
    }
}

fn meta(src: &Connection, key: &str) -> Result<Option<String>, String> {
    src.prepare_cached("SELECT value FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .query_row([key], |r| r.get(0))
        .optional()
        .map_err(sql)
}

/// 把 [profile] 的本机状态（文件头的表）从协议 3 库 [src] 带进新代集合 [col]。在一个事务里（可以是调用方的）。
pub fn carry_local(
    src: &Connection,
    t: &Truth<'_>,
    col: i64,
    profile: &str,
    now_ms: i64,
) -> Result<Carried, String> {
    t.tx(|t| {
        let mut out = Carried::default();
        peers(src, t, col, profile, &mut out)?;
        copy_rows(src, t, col, profile, &mut out)?;
        sealed_locations(src, t, col, profile, &mut out)?;
        if let Some(raw) = meta(src, &crate::store::binding::key(profile))? {
            if let Some(v) = crate::store::binding::parse(&raw) {
                let stage = v["state"].as_str().and_then(BindStage::of_text);
                if let Some(stage) = stage {
                    let via = v["via"].as_str().unwrap_or_default();
                    let at = v["at"].as_i64().unwrap_or(0);
                    t.settle_binding(col, stage, via, at)?;
                    out.binding = Some(stage.text());
                }
            }
        }
        let seeded = media::seed_legacy(t, col, src, profile, now_ms)?;
        out.media_at = seeded.rows as u64;
        out.media_skipped = seeded.skipped as u64;
        out.media_listed = seeded.listed as u64;
        out.media_hlc = seeded.seen.max_hlc;
        out.media_ahead = seeded.seen.ahead.len() as u64;
        Ok(out)
    })
}

/// `sync2_devices` → `peers`（迁移：新代库是空的临时文件，只写不比）。
pub(super) fn peers(
    src: &Connection,
    t: &Truth<'_>,
    col: i64,
    profile: &str,
    out: &mut Carried,
) -> Result<(), String> {
    let (peers, without_key) = legacy_peers(src, profile)?;
    out.peers_without_key += without_key;
    for peer in peers {
        if t.set_peer(col, &peer)? == PeerPut::KeyMismatch {
            return Err(format!(
                "gen4 carry: device {} is already known with another public key",
                peer.device
            ));
        }
        out.peers += 1;
    }
    Ok(())
}

/// 协议 3 库 [src] 里 [profile] 的设备行（`sync2_devices` + 扩展信息 + 补充名），按新代 `peers` 的口径整理好：没有
/// 公钥的行不带（第二项是它们的个数），名字取设备自报的、没有就取补充名，`head_gen` / `first_seen` 不带。
/// 迁移（[carry_local]）与旧备份读入（`import.rs` 的 `import_backup`）共用这一份，两边带过去的公钥与名字逐行相同。
pub(super) fn legacy_peers(src: &Connection, profile: &str) -> Result<(Vec<Peer>, u64), String> {
    let rows: Vec<(Vec<u8>, Option<Vec<u8>>, String)> = src
        .prepare(
            "SELECT device, public, name FROM sync2_devices WHERE profile_uid = srs_id(?1) ORDER BY device",
        )
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let ext_at = ext_prefix(profile);
    let mut peers = Vec::with_capacity(rows.len());
    let mut without_key = 0u64;
    for (device, public, name) in rows {
        let device = Id(blob(device, "device id")?);
        let Some(public) = public else {
            without_key += 1;
            continue;
        };
        let public: [u8; 32] = blob(public, "public key")?;
        let name = match name.trim() {
            "" => meta(src, &hint_key(&device))?.filter(|h| !h.trim().is_empty()),
            _ => Some(name),
        };
        let ext = meta(src, &format!("{ext_at}{}", device.text()))?;
        peers.push(Peer {
            device,
            public,
            name,
            ext,
            head_gen: None,
            first_seen: None,
        });
    }
    Ok((peers, without_key))
}

/// `sync2_held` / `sync2_checkpoints` / `sync2_media_local` 照搬（列同名，`profile_uid` 换成 `col`）。
fn copy_rows(
    src: &Connection,
    t: &Truth<'_>,
    col: i64,
    profile: &str,
    out: &mut Carried,
) -> Result<(), String> {
    type Row = Vec<rusqlite::types::Value>;
    let read = |q: &str, n: usize| -> Result<Vec<Row>, String> {
        let mut stmt = src.prepare(q).map_err(sql)?;
        let rows = stmt
            .query_map([profile], |r| {
                (0..n).map(|i| r.get(i)).collect::<Result<Row, _>>()
            })
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    };
    let tables: [(&str, &str, &str, usize, &mut u64); 3] = [
        (
            "SELECT device, seq, kind, srs_idt(entity) FROM sync2_held WHERE profile_uid = srs_id(?1) ORDER BY device, seq",
            "INSERT OR REPLACE INTO held (col, device, seq, kind, entity) VALUES (?1, ?2, ?3, ?4, ?5)",
            "held",
            4,
            &mut out.held,
        ),
        (
            "SELECT device, seq, wall, name, reason FROM sync2_checkpoints WHERE profile_uid = srs_id(?1) \
             ORDER BY device, seq",
            "INSERT OR REPLACE INTO checkpoints (col, device, seq, wall, name, reason) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            "checkpoints",
            5,
            &mut out.checkpoints,
        ),
        (
            "SELECT name, size, mtime, sha256, synced FROM sync2_media_local WHERE profile_uid = srs_id(?1) \
             ORDER BY name",
            "INSERT OR REPLACE INTO media_local (col, name, size, mtime, sha256, synced) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            "media_local",
            5,
            &mut out.media_local,
        ),
    ];
    for (select, insert, what, n, count) in tables {
        let rows = read(select, n)?;
        t.write(|| {
            let mut stmt = t.conn().prepare_cached(insert).map_err(sql)?;
            for row in &rows {
                let mut args: Vec<&dyn rusqlite::ToSql> = Vec::with_capacity(n + 1);
                args.push(&col);
                for v in row {
                    args.push(v);
                }
                stmt.execute(args.as_slice())
                    .map_err(|e| format!("gen4 carry: {what}: {e}"))?;
            }
            Ok(())
        })?;
        *count += rows.len() as u64;
    }
    Ok(())
}

/// 本机见过加密的位置（BUG-4299，`store/sync2/sealed.rs` 文件头）：记账键与带 `#e<指纹>` 的上传进度两个来源，口径同
/// 协议 3 的 `sync2_location_sealed`。
fn sealed_locations(
    src: &Connection,
    t: &Truth<'_>,
    col: i64,
    profile: &str,
    out: &mut Carried,
) -> Result<(), String> {
    // 记账键 `sync2_sealed/<位置>/<profile>`（前缀已在 profile_data.rs 登记）的尾段，只用来筛选读，不是新键。
    let suffix = ["/", profile].concat();
    let records: Vec<(String, String)> = src
        .prepare(
            "SELECT key, value FROM srs_meta WHERE substr(key, 1, length(?1)) = ?1 \
             AND substr(key, -length(?2)) = ?2 ORDER BY key",
        )
        .map_err(sql)?
        .query_map(params![SEALED_PREFIX, suffix], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    // (位置, kdf JSON, 口令校验串)
    let mut sealed: std::collections::BTreeMap<String, (Option<String>, Option<String>)> =
        Default::default();
    for (key, value) in records {
        let loc = &key[SEALED_PREFIX.len()..key.len() - suffix.len()];
        if loc.is_empty() {
            continue;
        }
        // 记录坏了也按见过算（宁可多拦一次，不放明文出去）。
        let kdf = serde_json::from_str::<Value>(&value)
            .ok()
            .and_then(|v| v.get("kdf").cloned())
            .filter(Value::is_object);
        let check = kdf
            .as_ref()
            .and_then(|k| k.get("check"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        sealed.insert(loc.to_owned(), (kdf.map(|k| k.to_string()), check));
    }
    let progressed: Vec<String> = src
        .prepare(
            "SELECT location FROM sync2_locations WHERE profile_uid = srs_id(?1) ORDER BY location",
        )
        .map_err(sql)?
        .query_map([profile], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for location in progressed {
        if let Some(at) = location.rfind("#e") {
            let (loc, fp) = (&location[..at], &location[at + 2..]);
            if !loc.is_empty() && !fp.is_empty() {
                sealed.entry(loc.to_owned()).or_insert((None, None));
            }
        }
    }
    t.write(|| {
        let mut stmt = t
            .conn()
            .prepare_cached(
                "INSERT INTO loc_state (col, loc_key, loc_ids, sealed, kdf, check_, last_ok) \
                 VALUES (?1, ?2, NULL, 1, ?3, ?4, NULL) \
                 ON CONFLICT (col, loc_key) DO UPDATE SET sealed = 1, \
                 kdf = COALESCE(excluded.kdf, kdf), check_ = COALESCE(excluded.check_, check_)",
            )
            .map_err(sql)?;
        for (loc, (kdf, check)) in &sealed {
            stmt.execute(params![col, loc, kdf, check]).map_err(sql)?;
        }
        Ok(())
    })?;
    out.sealed_locations = sealed.len() as u64;
    Ok(())
}

/// 在承袭日志上把协议 3 本机已切的段（`sync2_segments`）两端的完整原链值记成切点（文件头）。只记链指纹对得上日志里那一
/// 槽的（同一处另一支在日志里时不记，同 `import.rs` 的末尾记号）。返回记了几处。在一个事务里（可以是调用方的）。
pub fn carry_cut_points(
    src: &Connection,
    t: &Truth<'_>,
    col: i64,
    profile: &str,
) -> Result<u64, String> {
    let segs: Vec<(Vec<u8>, i64, i64)> = src
        .prepare(
            "SELECT device, first, last FROM sync2_segments WHERE profile_uid = srs_id(?1) ORDER BY device, first",
        )
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    t.tx(|t| {
        let mut marked = 0u64;
        let mut chain_at = src
            .prepare_cached(
                "SELECT chain FROM sync2_ops WHERE profile_uid = srs_id(?1) AND device = ?2 AND seq = ?3",
            )
            .map_err(sql)?;
        for (device, first, last) in segs {
            let id = Id(blob(device, "device id")?);
            for seq in [first - 1, last] {
                if seq < 1 {
                    continue;
                }
                let Some(chain) = chain_at
                    .query_row(params![profile, &id.0[..], seq], |r| r.get::<_, Vec<u8>>(0))
                    .optional()
                    .map_err(sql)?
                else {
                    continue;
                };
                let chain: Chain = blob(chain, "chain")?;
                let at = OpId {
                    device: id,
                    seq: seq as u64,
                };
                let fp = t.entry(col, &at)?.and_then(|e| e.fp);
                if fp == Some(fingerprint(&chain)) {
                    t.set_mark(col, &id, seq as u64, &chain)?;
                    marked += 1;
                }
            }
        }
        Ok(marked)
    })
}
