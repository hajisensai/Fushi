//! 同步一轮的命令层（规划 §2.2 G8-7、§1.7 位置布局、§1.5 写入与派生；交接说明「G8-7 同步一轮」一节）。存储层全部复用
//! 第一段的积木：位置布局 `gen4/location.rs`（G8-1）、收段 `receive.rs`（G8-4）、同步运行时状态 `sync_state.rs`（G8-4）、
//! 身份分叉 `fork.rs` / `truth/own.rs`（G8-6）、原生段打包 `gen4/segment.rs`、head `gen4/head.rs`、摘要 `digest.rs`。
//!
//! # 一轮（Dart `srs_sync2_round.dart` 按这个顺序调）
//!
//! 1. [location_root]：位置目录下的根（`v4/meta.json`、`v4/loc/`、旧根 `v3/meta.json`）交进来，内核给出要写的文件——
//!    新根 meta（纯函数）、loc 标记（第一次）、旧根围栏（存量集合读到了 `v3/meta.json` 才改写；新集合预先立围栏与墓碑
//!    head，D15）。位置上已有的新根 meta 与本机算出的不一致、或要求更新的读者：停下，什么都不写。
//! 2. [plan]：位置上全部设备的 head（每台取代号最大的）与各设备目录的文件名交进来；记公钥 / 名字 / 位置上的 head，判本机
//!    身份分叉（[fork::judge_own_head]），给出要拉的原生段与承袭段。
//! 3. [ingest]（分批，每批一个写事务）→ [ingest_finish]（有分叉点就换身份，[fork::rotate_on_fork]）。
//! 4. [outbox] / [outbox_ack]（分批）：本机原生日志从「已传到这个位置」的水位起按体积切段、签名、按位置钥匙封装。
//! 5. [head]：已传的段清单 + 已应用的版本向量 + 语义摘要，签成 `Head4`；内容与上次写的相同且没过心跳间隔就不写。
//! 6. [obsolete]：列本机目录交进来，给出该删的旧 head 与不再被引用的旧段。
//!
//! # 已传水位（[Out]）
//!
//! 每个「位置 + 密钥指纹」（Dart 的进度身份 `progress`，换了钥匙 = 换一个，全部按新钥匙重传）一份，记在 `srs_meta`
//! （键 [out_key]，不迁移、从头对账，D11 口径）：本机当前身份已经确认传上去的段（首尾 seq、链尾标签、**传时段里的空洞
//! 条数**）、水位处的链值、上次写的 head（代号、内容指纹、时刻、路径）。规则：
//!
//! - 切段只从水位往后切（[cut]），所以同一段日志每次切出同样的段（名字 = 区间 + 链尾标签）；中途断掉、下一轮从水位续传。
//! - 位置上看不见水位以下的段了（[outbox] 的 `present`：被清掉、同步盘丢文件）：水位退到第一处缺口之前，重传。
//! - 已传的段里后来多了空洞（本机清除了已经发布的操作）：水位退到那一段之前重切重传，新 head 不再引用旧段，[obsolete]
//!   随后删掉它——位置上不留已清除的原文（协议 3 `sync2_rewrites` 的新代版）。比的是「传时的空洞条数」与现在的，
//!   一条语句读本机全部空洞区间（[VOIDS_SQL]）。
//! - 本机换了身份（分叉 / 主动换）：水位按设备记，新身份从 0 起；旧身份的目录留在位置上（旧 head 清理见交接说明未做项）。
//!
//! # 事务
//!
//! 每条命令一个读快照或一个写事务（`dispatch.rs`）。只改本机同步状态（水位、位置上的 head、公钥与名字、加密记忆、
//! 停用记录）的命令走 `G4Core::write_local`，不推进写入代数；会落真相的（[ingest]、[ingest_finish]、[retire]、
//! [rotate]）走 `G4Core::write`，并推进本机修订号（`local.rs` `persist`，Dart 的刷新键随之变）。

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{OptionalExtension, params};
use serde_json::{Map, Value, json};

use super::Files;
use super::sync_relay::keep;
use crate::gen4::head::{Head4, HeadError};
use crate::gen4::heritage::{MAGIC as HERITAGE_MAGIC, peek_heritage_header};
use crate::gen4::location::{
    DEVICES_DIR, LOC_DIR, META_FILE, MediaRoot, NEW_ROOT, OLD_ROOT, V4File, check_meta4,
    device_path, fence3, loc_path, meta4, parse_v4_path, tombstone_head,
};
use crate::gen4::op::chain_next4;
use crate::gen4::recut::{MAGIC as RECUT_MAGIC, peek_recut4};
use crate::gen4::relay::{MAGIC as RELAY_MAGIC, open_any4, peek_relay4};
use crate::gen4::segment::{MAGIC as NATIVE_MAGIC, NativeItem, pack_native, peek_native_header};
use crate::gen4::{MIN_READER, PROTOCOL};
use crate::store::gen4::compact::item_bytes;
use crate::store::gen4::derive::{Index, Settled};
use crate::store::gen4::fork::{self, ForkScan, OwnHead};
use crate::store::gen4::ingest::Settle;
use crate::store::gen4::local;
use crate::store::gen4::receive::{Defer, Received, Receiver, Taken};
use crate::store::gen4::refresh::{TALLY_KEY, Tally};
use crate::store::gen4::schema::{k_range, k_seq, sql};
use crate::store::gen4::sync_state::LocHead;
use crate::store::gen4::truth::{NativeStep, Peer, PeerPut, SelfId, Truth};
use crate::sync2::id::Id;
use crate::sync2::keys::CollectionKey;
use crate::sync2::segment::{
    CHAIN_ZERO, Chain, SEGMENT_TARGET_BYTES, chain_tag, segment_file_name,
};

/// 派生口径版本（head 的 `derive`，设计 §4.1）：新代第一版。派生规则改了、两台设备同一版本向量下摘要会不同时 +1。
pub const HEAD_DERIVE: u32 = 1;

/// 发件一批的字节预算（协议 3 `transport.rs` `OUTBOX_BATCH_BYTES` 同值）：一批全部写成再确认，内存里同一时刻只有一批。
pub const OUTBOX_BATCH_BYTES: u64 = 8 * 1024 * 1024;

/// 每台设备在位置上保留最新的几代 head（协议 3 `HEAD_KEEP_GENS` 同值）。
pub const HEAD_KEEP_GENS: u64 = 2;

/// 切段时每次从本机日志读多少个 seq（只为限住一次读进内存的量，不影响切点）。
const WALK_SEQS: u64 = 4096;

/// [location_seal] 记下的 kdf 序列化后的上限（参数来自不可信的 `meta.json`，协议 3 `sealed.rs` 同值）。
const KDF_MAX_BYTES: usize = 1024;

/// 位置上新根的 meta 与本机不一致等「停下、不写」的结论（[location_root] 的 `state`）。
pub const ROOT_OK: &str = "ok";
pub const ROOT_NEEDS_UPGRADE: &str = "needsUpgrade";
pub const ROOT_REFUSED: &str = "refused";
/// [location_root] 的拒绝码：新根 meta 读不到，而这个集合的新根已经立过（旧根是 [fence3] 围栏——围栏只在新根 meta
/// 写好之后才写——或 Dart 列到新根下已有数据，`v4Data`）。新根原来的 `media` / `kdf` 推不出来（围栏不带 `media`），
/// 重建会把媒体根改错：不写、这一轮停下，等 meta 读得到（Dart `kSrsSync2MetaUnavailable`）。
pub const ERR_META_UNAVAILABLE: &str = "srs_location_meta_unavailable";
/// [location_root] 的拒绝码：旧根是围栏、新根下却什么都列不到（没有 meta、设备 / 媒体数据、loc 标记）——新根多半被
/// 整个删了（用户 / 网盘），也可能是列目录一时为空。同样不重建（媒体根 / `kdf` 推不出来），但这种状态等下去不会自己
/// 好：界面给出恢复办法（Dart `kSrsSync2NewRootMissing`，交接第五波同步收尾）。
pub const ERR_NEW_ROOT_MISSING: &str = "srs_location_new_root_missing";

// ---------------------------------------------------------------------- 小工具

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 || !s.bytes().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, o) in out.iter_mut().enumerate() {
        *o = u8::from_str_radix(&s[2 * i..2 * i + 2], 16).ok()?;
    }
    Some(out)
}

/// 请求里的位置密钥（`key`：64 位十六进制；null / 缺 = 明文位置）。
pub(crate) fn key_of(req: &Value) -> Result<Option<CollectionKey>, String> {
    match req.get("key") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => unhex32(s)
            .map(|k| Some(CollectionKey(k)))
            .ok_or_else(|| "sync: bad key".to_owned()),
        Some(_) => Err("sync: bad key".to_owned()),
    }
}

fn str_req<'a>(req: &'a Value, k: &str) -> Result<&'a str, String> {
    req.get(k)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("sync: missing {k}"))
}

fn now_of(req: &Value) -> Result<i64, String> {
    req.get("now")
        .and_then(Value::as_i64)
        .ok_or_else(|| "sync: missing now".to_owned())
}

fn me_of(t: &Truth<'_>, col: i64) -> Result<SelfId, String> {
    t.self_identity(col)?.ok_or_else(|| {
        format!("sync: collection {col} has no local identity (call identity first)")
    })
}

/// 「这一轮开始时库是空的」（`plan` 每轮按位置写 `1` / `0`，`oldroot_ingest` 读；`truth/trust.rs` 文件头）。
pub(crate) fn round_fresh_key(col: i64, location: &str) -> String {
    format!("gen4_round_fresh/{col}/{location}")
}

pub(crate) fn meta_get(t: &Truth<'_>, key: &str) -> Result<Option<String>, String> {
    t.conn()
        .prepare_cached("SELECT value FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .query_row([key], |r| r.get(0))
        .optional()
        .map_err(sql)
}

pub(crate) fn meta_set(t: &Truth<'_>, key: &str, value: &str) -> Result<(), String> {
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

pub(crate) fn settled_json(s: &Settled) -> Value {
    json!({"cacheNotes": s.cache_notes, "cacheCards": s.cache_cards, "cacheStats": s.cache_stats})
}

/// 落了真相的同步命令推进本机修订号（`local.rs` `persist` 按回包里数组的条数推进）：[n] 条，回包补 `localRevision` /
/// `localEpoch`。
pub(crate) fn bump_revision(
    t: &Truth<'_>,
    profile: &str,
    n: u64,
    out: &mut Value,
) -> Result<(), String> {
    let mut tmp = json!({"replayed": vec![Value::Null; n as usize]});
    local::persist(t, profile, None, &mut tmp)?;
    out["localRevision"] = tmp["localRevision"].clone();
    out["localEpoch"] = tmp["localEpoch"].clone();
    // 真落了东西：进程内刷新计数整份作废（分发器提交之后取走，`refresh.rs` 文件头「谁推进」）。与修订号同一个判据，
    // Primary 的键与 Secondary 按修订号拼的键一起变。
    if n > 0 {
        out[TALLY_KEY] = Tally::all().json();
    }
    Ok(())
}

/// 本集合与被它并入过的集合（段头 / head 的集合必须是其中之一，同 `receive.rs`）。
pub(crate) fn collections_of(
    t: &Truth<'_>,
    col: i64,
) -> Result<(BTreeSet<Id>, Id, String), String> {
    let binding = t
        .binding(col)?
        .ok_or_else(|| format!("sync: no collection {col}"))?;
    let mut set: BTreeSet<Id> = Index::new(t, col)
        .joins()?
        .into_iter()
        .map(|j| j.from)
        .collect();
    set.insert(binding.collection);
    Ok((set, binding.collection, binding.dir))
}

// ---------------------------------------------------------------------- 已传水位

/// 一个进度身份上本机当前身份的已传水位（模块文件头「已传水位」）。
#[derive(Clone, Debug, PartialEq, Eq)]
struct Out {
    device: Id,
    seq: u64,
    chain: Chain,
    /// 已确认传上去的段：(first, last, 链尾标签, 传时段里的空洞条数)，升序、首尾相接、覆盖 `1..=seq`。
    segs: Vec<(u64, u64, String, u64)>,
    /// 上次写的 head：代号、内容指纹、时刻、路径（相对 `v4/`）。没写过 = 0 / 空。
    gen: u64,
    tag: String,
    at: i64,
    path: String,
}

impl Out {
    fn fresh(device: Id) -> Out {
        Out {
            device,
            seq: 0,
            chain: CHAIN_ZERO,
            segs: Vec::new(),
            gen: 0,
            tag: String::new(),
            at: 0,
            path: String::new(),
        }
    }

    fn json(&self) -> Value {
        json!({
            "device": self.device.text(),
            "seq": self.seq,
            "chain": hex(&self.chain),
            "segs": self.segs.iter().map(|(a, b, t, v)| json!([a, b, t, v])).collect::<Vec<_>>(),
            "gen": self.gen,
            "tag": self.tag,
            "at": self.at,
            "path": self.path,
        })
    }

    fn parse(v: &Value) -> Option<Out> {
        let segs = v["segs"]
            .as_array()?
            .iter()
            .map(|s| {
                Some((
                    s[0].as_u64()?,
                    s[1].as_u64()?,
                    s[2].as_str()?.to_owned(),
                    s[3].as_u64()?,
                ))
            })
            .collect::<Option<Vec<_>>>()?;
        Some(Out {
            device: Id::parse(v["device"].as_str()?)?,
            seq: v["seq"].as_u64()?,
            chain: unhex32(v["chain"].as_str()?)?,
            segs,
            gen: v["gen"].as_u64()?,
            tag: v["tag"].as_str()?.to_owned(),
            at: v["at"].as_i64()?,
            path: v["path"].as_str()?.to_owned(),
        })
    }

    fn names(&self) -> Vec<String> {
        self.segs
            .iter()
            .map(|(a, b, t, _)| segment_file_name(*a, *b, t))
            .collect()
    }

    /// 只留前 [n] 段（水位退到第 n 段之后）。
    fn truncate(&mut self, t: &Truth<'_>, col: i64, n: usize) -> Result<(), String> {
        self.segs.truncate(n);
        self.seq = self.segs.last().map_or(0, |s| s.1);
        self.chain = t.chain_at(col, &self.device, self.seq)?;
        Ok(())
    }
}

/// 已传水位在 `srs_meta` 里的键：`gen4_out/<col>/<进度身份>`。
pub(crate) fn out_key(col: i64, progress: &str) -> String {
    format!("gen4_out/{col}/{progress}")
}

/// 读水位；记的是别的身份（换过身份）或记录坏了 = 从 0 起。
fn load_out(t: &Truth<'_>, col: i64, progress: &str, me: &Id) -> Result<Out, String> {
    let v = meta_get(t, &out_key(col, progress))?
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| Out::parse(&v));
    Ok(match v {
        Some(o) if o.device == *me => o,
        _ => Out::fresh(*me),
    })
}

fn save_out(t: &Truth<'_>, col: i64, progress: &str, out: &Out) -> Result<(), String> {
    meta_set(t, &out_key(col, progress), &out.json().to_string())
}

/// [void_runs] 执行的语句：本机这条日志的全部空洞区间（`op_voids` 的主键区间；查询计划测试用同一份）。
pub(crate) const VOIDS_SQL: &str = "SELECT k, n FROM op_voids WHERE k BETWEEN ?1 AND ?2 ORDER BY k";

/// 本机当前身份原生日志里的空洞区间 `(首 seq, 条数)`，升序。
fn void_runs(t: &Truth<'_>, col: i64, me: &Id) -> Result<Vec<(u64, u64)>, String> {
    let Some(dev) = t
        .devices(col)?
        .into_iter()
        .find(|d| d.id == *me)
        .map(|d| d.dev)
    else {
        return Ok(Vec::new());
    };
    let (lo, hi) = k_range(dev);
    let mut stmt = t.conn().prepare_cached(VOIDS_SQL).map_err(sql)?;
    let rows = stmt
        .query_map(params![lo, hi], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
        })
        .map_err(sql)?;
    rows.map(|r| {
        let (k, n) = r.map_err(sql)?;
        Ok((k_seq(k), n as u64))
    })
    .collect()
}

/// 区间 `[a, b]` 里的空洞条数。
fn voids_in(runs: &[(u64, u64)], a: u64, b: u64) -> u64 {
    runs.iter()
        .map(|&(s, n)| {
            let e = s + n - 1;
            let (lo, hi) = (s.max(a), e.min(b));
            if lo <= hi { hi - lo + 1 } else { 0 }
        })
        .sum()
}

// ---------------------------------------------------------------------- 切段

/// 切出的一段（还没签名）。
struct Piece {
    first: u64,
    last: u64,
    prev_chain: Chain,
    items: Vec<NativeItem>,
    est: u64,
}

/// 从 [from]（链值 [prev]）起把本机当前身份的原生日志切到 [last]：每段估计体积到 [target] 就切（只在链值已知处切：
/// 一条操作之后、或一个空洞区间的末尾），累计到 [budget] 就不再切下一段（这一批到此为止）。同一个起点、同样的日志
/// 切点总是相同（与 [budget] 无关），所以分批续传与一次传完切出同样的段。
fn cut(
    t: &Truth<'_>,
    col: i64,
    me: &Id,
    from: u64,
    prev: Chain,
    last: u64,
    target: u64,
    budget: u64,
) -> Result<Vec<Piece>, String> {
    let fresh = |first: u64, prev_chain: Chain| Piece {
        first,
        last: first - 1,
        prev_chain,
        items: Vec::new(),
        est: 0,
    };
    let mut pieces: Vec<Piece> = Vec::new();
    let mut cur = fresh(from, prev);
    let mut chain = prev;
    let mut total = 0u64;
    let mut done = false;
    let mut a = from;
    while a <= last && !done {
        let b = a.saturating_add(WALK_SEQS - 1).min(last);
        t.native_walk(col, me, a, b, |step| {
            if done {
                return Ok(());
            }
            let (item, end, closed) = match step {
                NativeStep::Op(op) => {
                    chain = chain_next4(&chain, &op);
                    let seq = op.id.seq;
                    (NativeItem::Op(op), seq, true)
                }
                NativeStep::Void {
                    first,
                    last: vl,
                    end,
                    chain_after,
                } => {
                    let closed = vl == end;
                    if closed {
                        chain = chain_after;
                    }
                    (
                        NativeItem::Void {
                            count: vl - first + 1,
                            chain_after,
                        },
                        vl,
                        closed,
                    )
                }
            };
            // 相邻的空洞槽合并（段格式只有一种字节形；也接上被 WALK_SEQS 截开的同一个区间）。
            match (&item, cur.items.last_mut()) {
                (
                    NativeItem::Void { count, chain_after },
                    Some(NativeItem::Void {
                        count: c0,
                        chain_after: a0,
                    }),
                ) => {
                    *c0 += count;
                    *a0 = *chain_after;
                }
                _ => {
                    cur.est += item_bytes(&item);
                    cur.items.push(item);
                }
            }
            cur.last = end;
            if closed && cur.est >= target {
                total += cur.est;
                let next = fresh(end + 1, chain);
                pieces.push(std::mem::replace(&mut cur, next));
                if total >= budget {
                    done = true;
                }
            }
            Ok(())
        })?;
        a = b + 1;
    }
    if !done && !cur.items.is_empty() {
        if cur.last != last {
            return Err(format!(
                "sync: the local log walk stopped at {} before its end {last}",
                cur.last
            ));
        }
        pieces.push(cur);
    }
    Ok(pieces)
}

// ---------------------------------------------------------------------- 1. 位置的根

/// `location_root {profile, location, now, has4, has3, has2?, v4Data?, locs, enableKdf?}`，字节块依次是位置上的 `v4/meta.json`（`has4`）、
/// `v3/meta.json`（`has3`）。`locs` = `v4/loc/` 下的文件名。回包 `{state, error?, loc, kdf, media, fresh, ensure}`，要写的
/// 文件在 [files]（路径相对位置目录，`v4/…` / `v3/…`，按顺序写：先新根、后围栏）；`ensure` 里的路径「不存在才写」
/// （墓碑 head：内容是目录名的纯函数，每轮覆盖写没有意义）。
///
/// - 新根 meta 读不到、而新根下已有数据（`v4Data`）或 loc 标记：报 [ERR_META_UNAVAILABLE]；新根下什么都没有、旧根是
///   围栏：报 [ERR_NEW_ROOT_MISSING]。都什么都不写。
/// - 新根 meta（设计 §4.1）：没有就写 [meta4]（`kdf` 从旧根原样抄；新集合没有旧根时取本机要开的 `enableKdf`）；有就按
///   字段核对（[check_meta4]）：要求更新的读者 → `needsUpgrade`，外形不认得 / 集合或媒体根不同 → `refused`，什么都
///   不写（不能当成可覆盖重建）。唯一允许的改写：位置上的 meta 没有 `kdf`、本机这一轮要开加密（`enableKdf`）。
/// - loc 标记（D17）：一个都没有就建一个（UUIDv7），`loc` 取全部标记里最小的；见过的标记记进 `loc_state.loc_ids`。
/// - 旧根围栏（设计 §4.3、D15）：读到了 `v3/meta.json`（存量集合）且它还不是围栏 → 改写成 [fence3]；没有 `v3/meta.json`
///   （新集合，判据只看它，不看目录名形状——规划 §4 实现补记）→ 预先写围栏，墓碑 head 进 `ensure`。
pub fn location_root(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    blobs: &[Vec<u8>],
    files: &mut Files,
) -> Result<Value, String> {
    let location = str_req(req, "location")?;
    let now = now_of(req)?;
    let (_, collection, dir) = collections_of(t, col)?;
    let has4 = req.get("has4") == Some(&Value::Bool(true));
    let has3 = req.get("has3") == Some(&Value::Bool(true));
    let mut it = blobs.iter();
    let v4 = if has4 {
        Some(
            it.next()
                .ok_or("location_root: missing v4 meta")?
                .as_slice(),
        )
    } else {
        None
    };
    let v3 = if has3 {
        Some(
            it.next()
                .ok_or("location_root: missing v3 meta")?
                .as_slice(),
        )
    } else {
        None
    };
    let enable = req.get("enableKdf").filter(|k| !k.is_null());
    if let Some(k) = enable {
        if !k.is_object() || k.to_string().len() > KDF_MAX_BYTES {
            return Err("location_root: bad enableKdf".into());
        }
    }
    let refuse = |state: &str, error: String| -> Value { json!({"state": state, "error": error}) };
    // 只有协议 1 旧根 `v2/`（`has2`）的位置：明确拒绝、一个字节不写（D21，`oldroot.rs` [check_root]；本机卡片与复习
    // 记录不受影响）。新集合的判据仍只看 `v3/meta.json`：`v2/` 在而 `v3/` 不在的位置不能当成空位置立围栏。
    let has2 = req.get("has2") == Some(&Value::Bool(true));
    let top: Vec<&str> = [
        (has4, NEW_ROOT),
        (has3, OLD_ROOT),
        (has2, crate::store::gen4::oldroot::PROTOCOL1_ROOT),
    ]
    .into_iter()
    .filter_map(|(h, n)| h.then_some(n))
    .collect();
    if let Err(r) = crate::store::gen4::oldroot::check_root(&top) {
        let mut v = refuse(ROOT_REFUSED, r.message);
        v["code"] = json!(r.code);
        return Ok(v);
    }
    // 旧根 meta：存量集合的 kdf 来源；集合标识必须是这个目录的。
    let v3_obj: Option<Map<String, Value>> = match v3 {
        None => None,
        Some(b) => match serde_json::from_slice::<Value>(b) {
            Ok(Value::Object(m)) => Some(m),
            _ => {
                return Ok(refuse(
                    ROOT_REFUSED,
                    "v3/meta.json is not a JSON object".into(),
                ));
            }
        },
    };
    let fenced3 = v3_obj
        .as_ref()
        .is_some_and(|m| m.get("moved").and_then(Value::as_str) == Some(NEW_ROOT));
    if let Some(m) = &v3_obj {
        let want = crate::store::sync2::collection_of(&dir).text();
        if m.get("collection").and_then(Value::as_str) != Some(want.as_str()) {
            return Ok(refuse(
                ROOT_REFUSED,
                format!("v3/meta.json belongs to another collection (expected {want})"),
            ));
        }
        // 协议 3 的读者版本比本版本还新（不是我们写的围栏）：停下。
        if !fenced3
            && m.get("minReader")
                .and_then(Value::as_f64)
                .is_some_and(|mr| mr > f64::from(MIN_READER))
        {
            return Ok(refuse(
                ROOT_NEEDS_UPGRADE,
                "v3/meta.json needs a newer reader".into(),
            ));
        }
    }
    // loc 标记（新根的一部分：总在新根 meta 之后写）。
    let mut locs: BTreeSet<Id> = req
        .get("locs")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter_map(|n| match parse_v4_path(&format!("{LOC_DIR}/{n}")) {
            Some(V4File::Loc(id)) => Some(id),
            _ => None,
        })
        .collect();
    // 新根 meta 读不到而新根已经立过：不按围栏 / 旧根重建（会把新集合的媒体根从 v4 改成 v3、把加密位置的 `kdf` 丢掉）。
    // 新根立过的证据三样，任一即可：旧根是围栏、Dart 列到新根下有设备 / 媒体数据（`v4Data`）、新根下有 loc 标记（内核
    // 自己看得到，不全靠 Dart 的判断）。新根下还有东西 → 多半是 meta 一时读不到；新根下什么都列不到、只剩围栏 → 新根
    // 多半被整个删掉了（也可能是列目录一时为空），这时等下去不会自己好，另给一个码让界面说清楚怎么恢复（交接第五波）。
    let v4_data = req.get("v4Data") == Some(&Value::Bool(true));
    let v4_listed = v4_data || !locs.is_empty();
    if v4.is_none() && (fenced3 || v4_listed) {
        let mut v = refuse(
            ROOT_REFUSED,
            if v4_listed {
                "v4/meta.json is unavailable but the new root already exists"
            } else {
                "v4/ is empty but v3/meta.json is the fence of a new root"
            }
            .into(),
        );
        v["code"] = json!(if v4_listed {
            ERR_META_UNAVAILABLE
        } else {
            ERR_NEW_ROOT_MISSING
        });
        return Ok(v);
    }
    let media = if v3.is_some() {
        MediaRoot::V3
    } else {
        MediaRoot::V4
    };
    let mut out_files: Files = Vec::new();
    let mut fresh = false;
    let (meta_bytes, kdf) = match v4 {
        Some(b) => {
            let got: Map<String, Value> = match serde_json::from_slice::<Value>(b) {
                Ok(Value::Object(m)) => m,
                _ => Map::new(),
            };
            let got_kdf = got.get("kdf").cloned();
            let got_media = match got.get("media").and_then(Value::as_str) {
                Some("v3") => MediaRoot::V3,
                _ => MediaRoot::V4,
            };
            let want = meta4(&collection, got_kdf.as_ref(), got_media)?;
            match check_meta4(b, &want) {
                Ok(()) => {}
                Err(crate::gen4::location::MetaMismatch::NeedsUpgrade { min_reader }) => {
                    return Ok(refuse(
                        ROOT_NEEDS_UPGRADE,
                        format!("v4/meta.json needs reader {min_reader}"),
                    ));
                }
                Err(e) => return Ok(refuse(ROOT_REFUSED, format!("v4/meta.json: {e}"))),
            }
            match (got_kdf, enable) {
                (None, Some(k)) => {
                    let b = meta4(&collection, Some(k), got_media)?;
                    out_files.push((format!("{NEW_ROOT}/{META_FILE}"), b.clone()));
                    (b, Some(k.clone()))
                }
                (k, _) => (b.to_vec(), k),
            }
        }
        None => {
            fresh = true;
            let kdf = v3_obj
                .as_ref()
                .and_then(|m| m.get("kdf").cloned())
                .or_else(|| enable.cloned());
            let b = meta4(&collection, kdf.as_ref(), media)?;
            out_files.push((format!("{NEW_ROOT}/{META_FILE}"), b.clone()));
            (b, kdf)
        }
    };
    if locs.is_empty() {
        let id = Id::new_v7(now.max(0) as u64);
        out_files.push((format!("{NEW_ROOT}/{}", loc_path(&id)), Vec::new()));
        locs.insert(id);
    }
    let loc = *locs.iter().next().expect("one loc marker");
    record_locs(t, col, location, &locs)?;
    // 旧根围栏：新根就绪之后。
    let mut ensure: Vec<String> = Vec::new();
    let fence = fence3(&dir, &meta_bytes)?;
    // 不是这份围栏（存量的协议 3 meta、或新根 meta 变了——开了加密——之后的旧围栏）就改写；已经是就不动。
    if v3 != Some(fence.as_slice()) {
        out_files.push((format!("{OLD_ROOT}/{META_FILE}"), fence));
    }
    if v3.is_none() {
        let (path, bytes) = tombstone_head(&dir);
        ensure.push(path.clone());
        out_files.push((path, bytes));
    }
    files.extend(out_files);
    Ok(json!({
        "state": ROOT_OK,
        "loc": loc.text(),
        "kdf": kdf.unwrap_or(Value::Null),
        "media": media_of_meta(&meta_bytes),
        "fresh": fresh,
        "ensure": ensure,
    }))
}

fn media_of_meta(meta: &[u8]) -> String {
    serde_json::from_slice::<Value>(meta)
        .ok()
        .and_then(|v| v.get("media").and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_else(|| MediaRoot::V4.as_str().to_owned())
}

/// 把见过的 loc 标记并进 `loc_state.loc_ids`（JSON 文本数组，升序）。
fn record_locs(t: &Truth<'_>, col: i64, location: &str, locs: &BTreeSet<Id>) -> Result<(), String> {
    let cur: Option<Option<String>> = t
        .conn()
        .prepare_cached(LOC_STATE_SQL)
        .map_err(sql)?
        .query_row(params![col, location], |r| r.get::<_, Option<String>>(0))
        .optional()
        .map_err(sql)?;
    let existed = cur.is_some();
    let mut all: BTreeSet<String> = cur
        .flatten()
        .and_then(|s| serde_json::from_str::<Vec<String>>(&s).ok())
        .unwrap_or_default()
        .into_iter()
        .collect();
    let before = all.len();
    all.extend(locs.iter().map(Id::text));
    if existed && all.len() == before {
        return Ok(());
    }
    let text = serde_json::to_string(&all.into_iter().collect::<Vec<_>>()).map_err(sql)?;
    t.write(|| {
        t.conn()
            .prepare_cached(
                "INSERT INTO loc_state (col, loc_key, loc_ids, sealed) VALUES (?1, ?2, ?3, 0) \
                 ON CONFLICT (col, loc_key) DO UPDATE SET loc_ids = excluded.loc_ids",
            )
            .map_err(sql)?
            .execute(params![col, location, text])
            .map_err(sql)?;
        Ok(())
    })
}

/// 一个位置的 `loc_state` 行（主键点查；查询计划测试用同一份）。
pub(crate) const LOC_STATE_SQL: &str =
    "SELECT loc_ids, sealed, kdf, check_ FROM loc_state WHERE col = ?1 AND loc_key = ?2";

// ---------------------------------------------------------------------- 2. 读 head、定要拉的段

/// `plan {profile, location, loc?, now, listing?}`，字节块 = 位置上各设备代号最大的 head。回包
/// `{fetch: [{device, own, files}], needsUpgrade, minReader?, sealed, finishPending, errors}`。
///
/// - 每份 head 先验（[Head4::decode]：规范 JSON、签名、`minReader`）；要求更新的读者 = `needsUpgrade`，这一轮整个停下
///   （Dart 不收、不发、不写 head）。集合不是本集合（或被它并入的）的 head 不认。
/// - 别的设备：记公钥（先到先得，`Truth::set_peer`；对不上 = 冒名，不认）、名字与扩展信息、位置上的 head（只进不退，
///   `Truth::put_loc_head`）；它的段里本机日志末尾之后的都要拉。停用过的设备写了更新的 head = 取消停用（协议 3 同口径）。
/// - 本机当前身份的 head：[fork::judge_own_head]——冒名不认；是本机日志的前缀没事；要比的段一并拉（本机身份的段在收段
///   时先按普通段收、再逐条比链，[ingest]）；之前已找到分叉点 = `finishPending`（Dart 没段可拉也调 [ingest_finish]）。
/// - 承袭段（`listing` = 各设备目录的文件名）：区间末尾在本机那条承袭日志末尾之后的都要拉（上传者不受信的收段时
///   留在位置上不收，D20）。
/// - 本位置自写的 head（`loc` 是本位置的 loc 标记）带 `seal` = 位置是加密的证据（设计 §4.4）：`sealed`。
pub fn plan(t: &Truth<'_>, col: i64, req: &Value, heads: &[Vec<u8>]) -> Result<Value, String> {
    // 协议 3 的 `plan` 有只读预演（`readOnly` → `needsWrite`）；新代的 `plan` 一律在写事务里记对端 / 位置 head /
    // 取消停用，没有只读形态。明确拒绝，不静默照写（调用方以为在读连接上、实际在 Dart 写锁外写库）。
    if req.get("readOnly").is_some_and(|v| !v.is_null()) {
        return Err(
            "plan: readOnly is not supported (plan always writes; run it under the write lock)"
                .into(),
        );
    }
    let location = str_req(req, "location")?;
    let now = now_of(req)?;
    let loc = req.get("loc").and_then(Value::as_str);
    // 这一轮开始时（收任何段之前）库是不是空的：同一轮稍后的旧根接手按它判首次信任（`truth/trust.rs` 文件头）。
    let fresh = t.library_fresh(col)?;
    meta_set(
        t,
        &round_fresh_key(col, location),
        if fresh { "1" } else { "0" },
    )?;
    let me = me_of(t, col)?;
    let (collections, _, _) = collections_of(t, col)?;
    let retired = t.retired(col)?;
    let mut errors: Vec<String> = Vec::new();
    let mut needs: Option<u32> = None;
    let mut sealed = false;
    let mut finish_pending = fork::recorded_fork(t, col)?.is_some();
    let mut fetch: BTreeMap<Id, (bool, BTreeSet<String>)> = BTreeMap::new();
    // 末尾 `relayed` 份是别的设备转发来的 head（`rhd-`，`cmd/sync_relay.rs`）：认公钥、定要拉的段，但不是这个位置的
    // 证据（不记 `loc_heads`、不取消停用、本机身份的不比）。
    let relayed = req
        .get("relayed")
        .and_then(Value::as_u64)
        .map_or(0, |n| usize::try_from(n).unwrap_or(usize::MAX))
        .min(heads.len());
    let first_relayed = heads.len() - relayed;
    // 本机旧身份（被转发来的 head 里有它们就跳过）：整轮取一次。
    let formers = if relayed > 0 {
        super::sync_oldroot::former_identities(t, col)?
    } else {
        BTreeSet::new()
    };
    for (i, bytes) in heads.iter().enumerate() {
        let is_relayed = i >= first_relayed;
        let h = match Head4::decode(bytes) {
            Ok(h) => h,
            Err(HeadError::NeedsUpgrade { min_reader }) => {
                needs = Some(needs.map_or(min_reader, |m| m.max(min_reader)));
                continue;
            }
            Err(e) => {
                errors.push(format!("head: {e}"));
                continue;
            }
        };
        if !collections.contains(&h.collection) {
            errors.push(format!("head of {}: another collection", h.device));
            continue;
        }
        if loc.is_some_and(|l| l == h.loc) && !h.seal.is_empty() {
            sealed = true;
        }
        if is_relayed && (h.device == me.device || formers.contains(&h.device)) {
            continue;
        }
        if h.device == me.device {
            match fork::judge_own_head(t, col, &h)? {
                OwnHead::Impostor => errors.push(format!(
                    "head of {}: signed by another key (impostor)",
                    h.device
                )),
                OwnHead::Fetch { segs } => {
                    let e = fetch.entry(h.device).or_insert((true, BTreeSet::new()));
                    for (a, b, tag) in segs {
                        e.1.insert(device_path(&h.device, &segment_file_name(a, b, &tag)));
                    }
                }
                OwnHead::Known { .. } => finish_pending = true,
                OwnHead::Prefix | OwnHead::Foreign => {}
            }
            continue;
        }
        let mut ext = h.ext.clone().unwrap_or_default();
        ext.insert("v".into(), Value::from(h.protocol));
        // 同步页的「最后见到」与摘要核对（`status` 的 `seenAt` / `digestMismatch`，[SEEN_AT_KEY] 一组）：本机按 head
        // 写，盖过对端自报扩展信息里的同名键。
        ext.insert(SEEN_AT_KEY.into(), Value::from(h.at_ms));
        ext.insert(SEEN_ACK_KEY.into(), Value::from(ack_fp(&h.ack)));
        ext.insert(SEEN_DIGEST_KEY.into(), Value::from(h.digest.clone()));
        // 本机已有它的日志、却从没记过它的公钥：只能是承袭日志的作者（协议 3 设备，原生日志收段前必先有公钥），段头
        // 没带它的公钥（`receive.rs` `vouched_author_key`）。换代迁移给每台设备换新 ID，协议 4 的 head 不会用协议 3 的
        // 设备 ID；拿它的 ID 写新根 head 的只能是冒充者，不登记（否则冒充者成了本机认识钥匙的设备，还能当承袭段上传者
        // 过 D20）。这样 `plan` 登记的新设备在本机一条操作都没有，写下待确认也不必让派生层重判（`plan` 不动派生层）。
        if t.device_key(col, &h.device)?.is_none() && t.last_of(col, &h.device)? > 0 {
            errors.push(format!(
                "head of {}: claims a protocol 3 device whose log is here without its key (impostor)",
                h.device
            ));
            continue;
        }
        let peer = Peer {
            device: h.device,
            public: h.public,
            name: (!h.name.is_empty()).then(|| h.name.clone()),
            ext: Some(Value::Object(ext).to_string()),
            head_gen: i64::try_from(h.gen).ok(),
            first_seen: Some(now),
        };
        match t.set_peer(col, &peer)? {
            PeerPut::KeyMismatch => {
                errors.push(format!(
                    "head of {}: signed by another key than the one on record (impostor)",
                    h.device
                ));
                continue;
            }
            // 第一次见到它（含只经转发见到的）：首见信任判定（`truth/trust.rs`：换身份继承 / 首次信任 / 待确认）。
            // 只给本机还没有它任何操作的设备写信任行（原生段要用这里记下的公钥验；已有日志而没公钥的上面已拒），派生层
            // 不必重判（`plan` 是本机状态写命令，不动派生层）；之后收段时派生层按这里写下的状态判它的删除与清除。
            PeerPut::Inserted => {
                t.note_new_peer(col, &h.device, &h.public, h.prev.as_ref(), h.at_ms)?;
            }
            PeerPut::Updated | PeerPut::Same => {}
        }
        // 转发用：记下这台设备最新的 head（只进不退）。
        super::sync_relay::note_head(t, col, &h, bytes)?;
        if !is_relayed {
            let lh = LocHead {
                device: h.device,
                gen: h.gen,
                seq: h.seq,
                segs: h.segment_files(),
            };
            if t.put_loc_head(col, location, &lh)?
                == crate::store::gen4::sync_state::LocHeadPut::Conflict
            {
                errors.push(format!(
                    "head of {}: contradicts the head seen before at this location",
                    h.device
                ));
            }
            if let Some(r) = retired.get(&h.device) {
                if r["headSeq"].as_u64().is_some_and(|s| h.seq > s) {
                    t.set_retired(col, &h.device, None)?;
                }
            }
            // 这个位置上作者自己有了的段，不必再替它转发（`cmd/sync_relay.rs` [prune]）。
            super::sync_relay::prune(t, col, &h.device)?;
        }
        let last = t.last_of(col, &h.device)?;
        for (a, b, tag) in &h.segs {
            if *b > last {
                fetch
                    .entry(h.device)
                    .or_insert((false, BTreeSet::new()))
                    .1
                    .insert(device_path(&h.device, &segment_file_name(*a, *b, tag)));
            }
        }
        // 早就收过、当时没留原文、而别的位置缺的段：只为转发再拉一次（收段时按本机已有跳过，只留原文）。
        for name in super::sync_relay::wanted_for_relay(t, col, location, &h, last)? {
            fetch
                .entry(h.device)
                .or_insert((false, BTreeSet::new()))
                .1
                .insert(device_path(&h.device, &name));
        }
    }
    // 承袭段：按文件名判区间。
    if let Some(listing) = req.get("listing").and_then(Value::as_object) {
        for (dev, names) in listing {
            for name in names
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                let path = format!("{DEVICES_DIR}/{dev}/{name}");
                if let Some(V4File::Heritage {
                    uploader,
                    old_device,
                    last,
                    ..
                }) = parse_v4_path(&path)
                {
                    if t.last_of(col, &old_device)? < last {
                        fetch
                            .entry(uploader)
                            .or_insert((uploader == me.device, BTreeSet::new()))
                            .1
                            .insert(path);
                    }
                }
            }
        }
    }
    let fetch: Vec<Value> = fetch
        .into_iter()
        .map(|(d, (own, files))| json!({"device": d.text(), "own": own, "files": files}))
        .collect();
    let mut out = json!({
        "fetch": fetch,
        "needsUpgrade": needs.is_some(),
        "sealed": sealed,
        "finishPending": finish_pending,
        "errors": errors,
    });
    if let Some(m) = needs {
        out["minReader"] = json!(m);
    }
    Ok(out)
}

// ---------------------------------------------------------------------- 3. 收段

/// `ingest {profile, key?, maxItems?}`，字节块 = 这一批从位置上读到的段（原生段 `FSG4`、中继件 `FRL4`、重切中继件 `FRX4`、
/// 承袭段 `FSH4`）。
/// `maxItems`（收段让路）：这一个事务最多做多少项新工作（[Receiver::with_budget]）；用完就停，回包 `rest` = 交完了的段数、
/// `spent` = 这一片做的新工作数（落库 + 新进等待缓冲 + 收尾投出的等待项；调用方判「这一片有没有进展」只认它，不拿
/// `landed` 当代理——依赖方的段排在前面时，一片可能全停进等待缓冲、一项都不落）；`drainMore` = 收尾投递等待缓冲时预算
/// 用完、还有接得上的项，段都交完了也要再不带段地收一次接着投，
/// Dart 把剩下的（含中途停下的那一段）放到下一个事务里交，两个事务之间放开写锁让作答插进来。一批一个
/// 写事务（[Receiver]：先全部核对再落、按因果投递、终点收派生层）；本机当前身份的段收完再逐条与本机日志比链
/// （[ForkScan]），找到分叉点就记下（[fork::record_fork]），换身份推到 [ingest_finish]。回包是这一批的计数、逐段没收的
/// 原因（`errors`）、派生层的收尾与本机修订号。
pub fn ingest(
    t: &Truth<'_>,
    col: i64,
    profile: &str,
    req: &Value,
    blobs: &[Vec<u8>],
    key: Option<&CollectionKey>,
) -> Result<Value, String> {
    let me = me_of(t, col)?;
    let public = me.public();
    let max_items = req.get("maxItems").and_then(Value::as_u64);
    let mut rx = Receiver::open(t, col, Settle::Incremental)?.with_budget(max_items);
    let mut scan: Option<ForkScan> = None;
    let mut errors: Vec<String> = Vec::new();
    let mut kept = 0u64;
    // 这一批交完了几段（后面的 Dart 下一个事务再交；中途停下的那一段算没交完）。
    let mut rest = blobs.len();
    // 等 Purge 的重切件（下标、作者、延后的结论）：这一批交完之后再收一次（见循环之后）。
    let mut purge_wait: Vec<(usize, Option<Id>, Taken)> = Vec::new();
    let who = |author: Option<Id>| author.map_or_else(|| "?".to_owned(), |d| d.text());
    for (i, b) in blobs.iter().enumerate() {
        if rx.exhausted() {
            rest = i;
            break;
        }
        let heritage = b.starts_with(HERITAGE_MAGIC);
        let recut = b.starts_with(RECUT_MAGIC);
        let author = if heritage {
            peek_heritage_header(b).ok().map(|h| h.uploader)
        } else if recut {
            peek_recut4(b).ok().map(|p| p.header.device)
        } else if b.starts_with(RELAY_MAGIC) {
            peek_relay4(b).ok().map(|p| p.header.device)
        } else {
            peek_native_header(b).ok().map(|h| h.device)
        };
        let taken = if heritage {
            rx.heritage(b, key)?
        } else {
            rx.native(b, key)?
        };
        let cut = rx.cut();
        match &taken {
            Taken::Landed { .. } => {
                // 别的设备的原生段：本机同步着多个位置时留一份原文给转发（`cmd/sync_relay.rs`）。
                if !heritage && author.is_some_and(|a| a != me.device) && keep(t, col, b, key)? {
                    kept += 1;
                }
            }
            Taken::Deferred(Defer::PurgePending(_)) if recut => {
                purge_wait.push((i, author, taken.clone()));
            }
            other => errors.push(format!("{}: {other:?}", who(author))),
        }
        if cut {
            // 预算在这一段中途用完：这一段下一批原样再交（已落的部分按本机已有跳过）；比链等它整段收完再做。
            rest = i;
            break;
        }
        // 本机当前身份的原生段：比链找分叉点（收过的部分与本机日志相同，接得上的已经接回来了）。别人重切的本机的段
        // （`FRX4`）不是本机签的、空洞处没有链可比，不拿来找分叉点。
        if !heritage && !recut && author == Some(me.device) {
            let items = open_any4(b, &public, key).and_then(|o| {
                let header = o.header.clone();
                let items = o.verify()?.collect::<Result<Vec<_>, _>>()?;
                Ok((header, items))
            });
            match items {
                Ok((header, items)) => {
                    let s = match scan.as_mut() {
                        Some(s) => s,
                        None => scan.insert(ForkScan::new(t, col)?),
                    };
                    s.feed(t, col, &header, &items)?;
                }
                Err(e) => errors.push(format!("own segment: {e:?}")),
            }
        }
    }
    // 重切件点名的 Purge 可能在同一批后面的段里：整批交完（没被预算截断）之后，这些件再收一次，收段的结论与一批之内
    // 的先后无关。还缺（Purge 不在这一批）就照常延后，下一轮再拉。这一步里预算用完 / 截断：从这一件起 Dart 下一个
    // 事务重交（下标递增，剩下的都在它后面），不报错。
    if rest == blobs.len() {
        for (i, author, _) in purge_wait {
            if rx.exhausted() {
                rest = i;
                break;
            }
            let b = &blobs[i];
            let taken = rx.native_again(b, key)?;
            match &taken {
                Taken::Landed { .. } => {
                    if author.is_some_and(|a| a != me.device) && keep(t, col, b, key)? {
                        kept += 1;
                    }
                }
                other => errors.push(format!("{}: {other:?}", who(author))),
            }
            if rx.cut() {
                rest = i;
                break;
            }
        }
    } else {
        for (_, author, taken) in purge_wait {
            errors.push(format!("{}: {taken:?}", who(author)));
        }
    }
    let r: Received = rx.finish()?;
    let fork_at = match scan.as_ref().and_then(ForkScan::fork_point) {
        Some(keep) => Some(fork::record_fork(t, col, keep)?),
        None => None,
    };
    let applied = r.landed + r.delivered;
    let mut out = json!({
        "segments": r.segments,
        "landed": r.landed,
        "delivered": r.delivered,
        "applied": applied,
        "waiting": r.waiting,
        "pending": r.pending + r.waiting,
        "deferred": r.deferred,
        "rejected": r.rejected,
        "diverged": r.diverged,
        "conflicts": r.conflicts,
        "forked": r.forked.iter().map(Id::text).collect::<Vec<_>>(),
        "divergedWaiting": r.diverged_waiting.iter().map(|(d, s)| json!([d.text(), s])).collect::<Vec<_>>(),
        "fork": fork_at.is_some(),
        "errors": errors,
        "settled": settled_json(&r.settled),
        "voided": r.voided,
        "rest": rest,
        "spent": r.spent,
        "drainMore": r.drain_more,
        "kept": kept,
    });
    bump_revision(t, profile, applied + r.voided, &mut out)?;
    Ok(out)
}

/// `ingest_finish {profile, now}`：收段记下过分叉点就换身份（[fork::rotate_on_fork]：分叉点之后的本机操作以新身份按原
/// 顺序重签发，旧身份冻结在分叉点）。回包 `{fork, device?, previous?, moved?}`；换了身份推进本机修订号（重签发的操作
/// 换了操作号）。
pub fn ingest_finish(t: &Truth<'_>, col: i64, profile: &str, now: i64) -> Result<Value, String> {
    let Some(r) = fork::rotate_on_fork(t, col, now)? else {
        // 没分叉也照样带上本机修订号与纪元：Dart 把 `ingest_finish` 当改投影的命令（`kSrsSync2ProjectingOps`），
        // 回包缺这两项按契约错误报（每一轮收了段都会调它）。什么都没变，修订号不推进。
        let mut out = json!({"fork": false});
        bump_revision(t, profile, 0, &mut out)?;
        return Ok(out);
    };
    let mut out = json!({
        "fork": true,
        "device": r.device.text(),
        "previous": r.previous.text(),
        "keep": r.keep,
        "moved": r.moved.len(),
    });
    bump_revision(t, profile, r.moved.len() as u64 + 1, &mut out)?;
    Ok(out)
}

// ---------------------------------------------------------------------- 4. 发件

/// `outbox {profile, progress, key?, maxBytes?, segBytes?, present?}`：本机当前身份从已传水位起切出的下一批段（文件在
/// [files]，路径相对 `v4/`）。回包 `{segments: [[first, last, tag, voids]], upto, more}`。
///
/// `present`（一轮第一次发件时给：这一轮列到的本机目录文件名）：水位以下的段在位置上看不见了就退水位重传（模块文件头）。
/// 水位以下的段里后来多了空洞（本机清除了已发布的操作）同样退水位重切。两种退水位都写进库（只改本机同步状态）。
pub fn outbox(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    key: Option<&CollectionKey>,
    files: &mut Files,
) -> Result<Value, String> {
    let progress = str_req(req, "progress")?;
    let me = me_of(t, col)?;
    let (_, collection, _) = collections_of(t, col)?;
    let budget = req
        .get("maxBytes")
        .and_then(Value::as_u64)
        .unwrap_or(OUTBOX_BATCH_BYTES)
        .max(1);
    let target = req
        .get("segBytes")
        .and_then(Value::as_u64)
        .unwrap_or(SEGMENT_TARGET_BYTES)
        // 不超过默认目标：读侧按 [crate::gen4::segment::MAX_BODY_RAW] 拒解压后过大的段，切段目标不能往上放。
        .clamp(1, SEGMENT_TARGET_BYTES);
    let mut out = load_out(t, col, progress, &me.device)?;
    let before = out.clone();
    let last = t.last_of(col, &me.device)?;
    // 水位越过了本机日志、或水位处的链值与本机对不上（不该发生）：从 0 起。
    if out.seq > last || t.chain_known(col, &me.device, out.seq)? != Some(out.chain) {
        out = Out::fresh(me.device);
    }
    if let Some(present) = req.get("present").and_then(Value::as_array) {
        let present: BTreeSet<&str> = present.iter().filter_map(Value::as_str).collect();
        if let Some(i) = out
            .names()
            .iter()
            .position(|n| !present.contains(n.as_str()))
        {
            out.truncate(t, col, i)?;
        }
    }
    let runs = void_runs(t, col, &me.device)?;
    if let Some(i) = out
        .segs
        .iter()
        .position(|(a, b, _, v)| voids_in(&runs, *a, *b) != *v)
    {
        // 退到这一段之前；那一处落在空洞内部（链值不可比）就再往前退一段。
        let mut i = i;
        while i > 0 && t.chain_known(col, &me.device, out.segs[i - 1].1)?.is_none() {
            i -= 1;
        }
        out.truncate(t, col, i)?;
    }
    if out != before {
        save_out(t, col, progress, &out)?;
    }
    if out.seq >= last {
        return Ok(json!({"segments": [], "upto": out.seq, "more": false}));
    }
    let pieces = cut(
        t,
        col,
        &me.device,
        out.seq + 1,
        out.chain,
        last,
        target,
        budget,
    )?;
    let signer = me.key();
    let mut segments = Vec::with_capacity(pieces.len());
    let mut upto = out.seq;
    for p in &pieces {
        let (header, bytes) = pack_native(
            collection,
            me.device,
            p.first,
            &p.items,
            p.prev_chain,
            &signer,
            key,
        )?;
        let tag = chain_tag(&header.last_chain);
        segments.push(json!([
            p.first,
            p.last,
            tag,
            voids_in(&runs, p.first, p.last)
        ]));
        files.push((device_path(&me.device, &header.file_name()), bytes));
        upto = p.last;
    }
    Ok(json!({"segments": segments, "upto": upto, "more": upto < last}))
}

/// `outbox_ack {profile, progress, segments}`：这一批（[outbox] 回包的 `segments` 原样）都写上了。必须正好接在水位上、
/// 链尾标签与本机日志相符（发件与确认之间本机日志变了——清除了这一段里的操作——就对不上）；对不上回
/// `{accepted: false}`、什么都不记，Dart 不写 head、下一轮按当前日志重切。回包 `{accepted, uploaded}`。
pub fn outbox_ack(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let progress = str_req(req, "progress")?;
    let me = me_of(t, col)?;
    let mut out = load_out(t, col, progress, &me.device)?;
    let segs = req
        .get("segments")
        .and_then(Value::as_array)
        .ok_or("outbox_ack: missing segments")?;
    let mut next = out.clone();
    for s in segs {
        let (Some(a), Some(b), Some(tag), Some(v)) =
            (s[0].as_u64(), s[1].as_u64(), s[2].as_str(), s[3].as_u64())
        else {
            return Err("outbox_ack: bad segment".into());
        };
        let chain = if b >= a && a == next.seq + 1 && b <= t.last_of(col, &me.device)? {
            t.chain_known(col, &me.device, b)?
        } else {
            None
        };
        match chain {
            Some(c) if chain_tag(&c) == tag => {
                next.segs.push((a, b, tag.to_owned(), v));
                next.seq = b;
                next.chain = c;
            }
            _ => return Ok(json!({"accepted": false, "uploaded": out.seq})),
        }
    }
    out = next;
    save_out(t, col, progress, &out)?;
    Ok(json!({"accepted": true, "uploaded": out.seq}))
}

// ---------------------------------------------------------------------- 5. head

/// `head` 这一轮要签的内容（[head] 与只读的 [head_unchanged] 共用一份算法）。
struct HeadDraft {
    me: SelfId,
    out: Out,
    ack: crate::sync2::vv::Vv,
    digest: String,
    /// 本机此刻的 (版本向量指纹, 摘要)：`status` 拿对端 head 上同一个版本向量下的摘要与它比（[SEEN_ACK_KEY]）。
    mine: String,
    name: String,
    ext: Map<String, Value>,
    loc: String,
    seal: String,
    segs: Vec<(u64, u64, String)>,
    /// 内容指纹：与水位里记的相同 = 内容没变。
    tag: String,
}

fn head_draft(t: &Truth<'_>, col: i64, req: &Value) -> Result<HeadDraft, String> {
    let progress = str_req(req, "progress")?;
    let me = me_of(t, col)?;
    let out = load_out(t, col, progress, &me.device)?;
    let ack = t.applied(col)?;
    let digest = Index::new(t, col).digest()?;
    let mine = json!({"ack": ack_fp(&ack), "digest": digest}).to_string();
    let name = super::writes_local::self_name(t, col)?;
    let ext = self_ext(t, col)?;
    let loc = req
        .get("loc")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let seal = req
        .get("seal")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let segs: Vec<(u64, u64, String)> = out
        .segs
        .iter()
        .map(|(a, b, tg, _)| (*a, *b, tg.clone()))
        .collect();
    let tag = {
        let content = json!({
            "seq": out.seq, "chain": hex(&out.chain), "segs": segs, "ack": ack.0.iter().map(|(d, s)| (d.text(), *s)).collect::<BTreeMap<_, _>>(),
            "digest": digest, "name": name, "ext": ext, "loc": loc, "seal": seal,
            "prev": me.prev.as_ref().map(|p| json!([p.device.text(), p.seq, hex(&p.chain)])),
        });
        hex(&blake3::hash(content.to_string().as_bytes()).as_bytes()[..16])
    };
    Ok(HeadDraft {
        me,
        out,
        ack,
        digest,
        mine,
        name,
        ext,
        loc,
        seal,
        segs,
        tag,
    })
}

/// 内容没变、离上次写没满 `skipUnchangedMs`：不写 head，回上次那份。
fn skip_unchanged(d: &HeadDraft, req: &Value, now: i64) -> Option<Value> {
    let skip = req.get("skipUnchangedMs").and_then(Value::as_i64)?;
    let out = &d.out;
    (out.gen > 0 && out.tag == d.tag && !out.path.is_empty() && now - out.at < skip)
        .then(|| json!({"unchanged": true, "path": out.path, "gen": out.gen}))
}

/// 位置 [location] 记下的 `last_ok`（`loc_state` 主键点查；没有行 / 空 = None）。
pub(crate) const LOC_LAST_OK_SQL: &str =
    "SELECT last_ok FROM loc_state WHERE col = ?1 AND loc_key = ?2";

fn last_ok_of(t: &Truth<'_>, col: i64, location: &str) -> Result<Option<i64>, String> {
    Ok(t.conn()
        .prepare_cached(LOC_LAST_OK_SQL)
        .map_err(sql)?
        .query_row(params![col, location], |r| r.get::<_, Option<i64>>(0))
        .optional()
        .map_err(sql)?
        .flatten())
}

/// `last_ok` 的粒度：离上次记不到这么久时不为了它开写事务（[head_unchanged]）。转发的活跃窗口是 30 天
/// （`cmd/sync_relay.rs` `ACTIVE_WINDOW_MS`），滞后最多一天无碍。
pub(crate) const LAST_OK_REFRESH_MS: i64 = 86_400_000;

/// `head` 的只读前半（读快照，调用方不开写事务）：这一轮什么都不用写——内容没变、离上次写没满 `skipUnchangedMs`（[head]
/// 的不变跳过）、本机摘要记录（[self_digest_key]）也没变、这个位置的 `last_ok` 不满 [LAST_OK_REFRESH_MS]——就回
/// [head] 同样的 `{unchanged: true, path, gen}`；否则 None，调用方开写事务跑 [head]（它会重算一遍，读快照与写事务之间
/// 别的写入改了什么都以写事务里的为准）。每轮同步每个位置都调一次 head，没有变化时不再每轮占一次写锁、写一次 WAL。
pub fn head_unchanged(t: &Truth<'_>, col: i64, req: &Value) -> Result<Option<Value>, String> {
    let location = str_req(req, "location")?;
    let now = now_of(req)?;
    let d = head_draft(t, col, req)?;
    let Some(reply) = skip_unchanged(&d, req, now) else {
        return Ok(None);
    };
    if meta_get(t, &self_digest_key(col))?.as_deref() != Some(d.mine.as_str()) {
        return Ok(None);
    }
    match last_ok_of(t, col, location)? {
        Some(at) if at <= now && now - at < LAST_OK_REFRESH_MS => Ok(Some(reply)),
        _ => Ok(None),
    }
}

/// `head {profile, location, progress, loc?, seal?, now, skipUnchangedMs?}`：把已传水位签成本机在这个位置上的 head
/// （文件在 [files]，路径 `devices/<本机>/head-…json` 相对 `v4/`）。回包 `{path, gen, unchanged}`。
///
/// 内容（段清单、版本向量、摘要、名字与扩展信息、`loc` / `seal`、`prev`）与上次写的相同、离上次没满 `skipUnchangedMs`
/// 时不写，回 `{unchanged: true, path: 上次的路径}`（每写一次 head 都会唤醒连着这个位置的设备）；Dart 发现那个文件不在
/// 位置上就不带 `skipUnchangedMs` 再要一次。代号 = 位置上本机最新 head 与水位里记的取大 + 1。写下后记进水位与位置
/// 上的 head 记录（`status` 的 `uploaded` / `headGen` 读它）。分发器先在读快照上跑 [head_unchanged]，什么都不用写时
/// 不开写事务。
pub fn head(t: &Truth<'_>, col: i64, req: &Value, files: &mut Files) -> Result<Value, String> {
    let location = str_req(req, "location")?;
    let progress = str_req(req, "progress")?;
    let now = now_of(req)?;
    let (_, collection, _) = collections_of(t, col)?;
    let HeadDraft {
        me,
        mut out,
        ack,
        digest,
        mine,
        name,
        ext,
        loc,
        seal,
        segs,
        tag,
    } = head_draft(t, col, req)?;
    if meta_get(t, &self_digest_key(col))?.as_deref() != Some(mine.as_str()) {
        meta_set(t, &self_digest_key(col), &mine)?;
    }
    // 走到写 head 就是这一轮在这个位置上成功了（不变跳过也算）：记 `last_ok`，转发只认最近成功过的位置
    // （`cmd/sync_relay.rs` 的活跃窗口）。
    touch_location(t, col, location, now)?;
    // 新代第一次同步成功：保留副本从这一刻起再留 14 天（`retained.rs`，D32）。
    t.write(|| crate::store::gen4::retained::note_first_sync(t.conn(), now))?;
    if out.gen > 0
        && out.tag == tag
        && !out.path.is_empty()
        && req
            .get("skipUnchangedMs")
            .and_then(Value::as_i64)
            .is_some_and(|skip| now - out.at < skip)
    {
        return Ok(json!({"unchanged": true, "path": out.path, "gen": out.gen}));
    }
    let published = t.loc_head(col, location, &me.device)?.map_or(0, |h| h.gen);
    let gen = published.max(out.gen) + 1;
    let h = Head4 {
        gen,
        protocol: PROTOCOL,
        min_reader: MIN_READER,
        collection,
        device: me.device,
        public: me.public(),
        seq: out.seq,
        chain: out.chain,
        segs,
        ack,
        digest,
        at_ms: now,
        name,
        loc,
        seal,
        derive: HEAD_DERIVE,
        prev: me.prev.clone(),
        ext: (!ext.is_empty()).then_some(ext),
        extra: BTreeMap::new(),
    };
    let bytes = h.encode(&me.key())?;
    let path = device_path(&me.device, &h.file_name());
    files.push((path.clone(), bytes));
    out.gen = gen;
    out.tag = tag;
    out.at = now;
    out.path = path.clone();
    save_out(t, col, progress, &out)?;
    t.put_loc_head(
        col,
        location,
        &LocHead {
            device: me.device,
            gen,
            seq: out.seq,
            segs: h.segment_files(),
        },
    )?;
    Ok(json!({"unchanged": false, "path": path, "gen": gen}))
}

/// 记一个位置这一轮成功的时刻（`loc_state.last_ok`，主键点写）。
pub(crate) const LOC_TOUCH_SQL: &str = "INSERT INTO loc_state (col, loc_key, sealed, last_ok) VALUES (?1, ?2, 0, ?3)      ON CONFLICT (col, loc_key) DO UPDATE SET last_ok = excluded.last_ok";

fn touch_location(t: &Truth<'_>, col: i64, location: &str, now: i64) -> Result<(), String> {
    t.write(|| {
        t.conn()
            .prepare_cached(LOC_TOUCH_SQL)
            .map_err(sql)?
            .execute(params![col, location, now])
            .map_err(sql)?;
        Ok(())
    })
}

/// 对端 head 的写出时刻、版本向量指纹、摘要在 `peers.ext` 里的键（[plan] 写、`status` 读；下划线开头，不与对端自报的
/// 扩展信息键冲突，`status` 只按白名单转发扩展信息）。
pub(crate) const SEEN_AT_KEY: &str = "_seenAt";
pub(crate) const SEEN_ACK_KEY: &str = "_ack";
pub(crate) const SEEN_DIGEST_KEY: &str = "_digest";

/// 版本向量的指纹（摘要核对只比「同一个版本向量」，[SEEN_ACK_KEY]）。
pub(crate) fn ack_fp(ack: &crate::sync2::vv::Vv) -> String {
    hex(&blake3::hash(&ack.encode()).as_bytes()[..16])
}

/// 本机上次写 head 时的 `{"ack": 版本向量指纹, "digest": 摘要}` 在 `srs_meta` 里的键。
pub(crate) fn self_digest_key(col: i64) -> String {
    format!("gen4_self_digest/{col}")
}

/// 本机的扩展信息（`device_info` 存的型号 / App 版本 / 平台 / 昵称，非空的才带）。
fn self_ext(t: &Truth<'_>, col: i64) -> Result<Map<String, Value>, String> {
    // `device_info` 存的本机扩展信息（`writes_local.rs` `self_info_key` 同一个键）。
    let info: Map<String, Value> = meta_get(t, &format!("self_info/{col}"))?
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default();
    Ok(["model", "app", "platform", "nick"]
        .into_iter()
        .filter_map(|k| {
            info.get(k)
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(|s| (k.to_owned(), Value::from(s)))
        })
        .collect())
}

// ---------------------------------------------------------------------- 6. 收尾

/// `obsolete {profile, progress, present, archive?}`：列本机目录（**head 已经写上之后**列的）交进来，回 `{delete: [路径
/// 相对 v4/]}`——比最新 [HEAD_KEEP_GENS] 代旧的本机 head、不在已传段清单里的本机 `seg-`（中途断掉切出的、清除之后重切
/// 换下的）。归档位置（`archive`）什么都不删；还没写过 head 也不删段。只看这一次的列表、不记待删清单：删失败的下一轮
/// 照样再给，所以不需要回执（`obsolete_ack` 已删）。别的前缀（承袭段、清单、转发件、profile 说明）一律不碰。
pub fn obsolete(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let progress = str_req(req, "progress")?;
    let me = me_of(t, col)?;
    let former: Vec<String> = super::sync_oldroot::former_identities(t, col)?
        .iter()
        .map(Id::text)
        .collect();
    if req.get("archive") == Some(&Value::Bool(true)) {
        return Ok(json!({"delete": [], "again": false, "former": []}));
    }
    let out = load_out(t, col, progress, &me.device)?;
    let keep: BTreeSet<String> = out.names().into_iter().collect();
    let mut delete = Vec::new();
    for name in req
        .get("present")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        let path = device_path(&me.device, name);
        match parse_v4_path(&path) {
            Some(V4File::Head { gen, .. }) => {
                if out.gen > 0 && gen + HEAD_KEEP_GENS <= out.gen && path != out.path {
                    delete.push(path);
                }
            }
            Some(V4File::Seg { .. }) => {
                if out.gen > 0 && !keep.contains(name) {
                    delete.push(path);
                }
            }
            _ => {}
        }
    }
    Ok(json!({"delete": delete, "again": false, "former": former}))
}

/// `obsolete_former {device, present, archive?}`：本机的一个旧身份（[obsolete] 回包的 `former`：换身份前的、同一把签名
/// 钥匙签的别的设备 ID）在这个位置上的目录（`present` = 列出来的文件名）里该删什么。只删比目录里最新的 head 旧
/// [HEAD_KEEP_GENS] 代以上的 head；段一个不删——别的设备（含还没连过这个位置的新设备）要从这些段拿到旧身份的全部操作，
/// 旧身份的 head 是它们认公钥、找段的入口，所以最新的几代也留着。不是本机旧身份的设备、归档位置：什么都不删。回包
/// `{"delete": [路径相对 v4/]}`。
pub fn obsolete_former(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let device = Id::parse(str_req(req, "device")?).ok_or("obsolete_former: bad device")?;
    if req.get("archive") == Some(&Value::Bool(true))
        || !super::sync_oldroot::former_identities(t, col)?.contains(&device)
    {
        return Ok(json!({"delete": []}));
    }
    let mut heads: Vec<(u64, String)> = Vec::new();
    for name in req
        .get("present")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        let path = device_path(&device, name);
        if let Some(V4File::Head { gen, .. }) = parse_v4_path(&path) {
            heads.push((gen, path));
        }
    }
    let top = heads.iter().map(|(g, _)| *g).max().unwrap_or(0);
    let delete: Vec<String> = heads
        .into_iter()
        .filter(|(g, _)| g + HEAD_KEEP_GENS <= top)
        .map(|(_, p)| p)
        .collect();
    Ok(json!({"delete": delete}))
}

// ---------------------------------------------------------------------- 移除位置

/// 可转发原文里出现过的作者（`relay_segs` 唯一约束的前缀 `(col, device)` 上去重）。
pub(crate) const RELAY_AUTHORS_SQL: &str =
    "SELECT DISTINCT device FROM relay_segs WHERE col = ?1 ORDER BY device";

/// 删掉一个位置的加密记忆 / loc 标记 / `last_ok`（`loc_state` 主键点删）。
pub(crate) const LOC_STATE_DROP_SQL: &str = "DELETE FROM loc_state WHERE col = ?1 AND loc_key = ?2";

/// `location_forget {profile, location}`（`write_local`）：用户移除了同步位置 [location]（位置管理入口：本机文件夹位置的
/// 「移除」，以后 G10 的 host 目录 / 通道位置的移除也走这一条）。本机不再记这个位置的任何同步状态：
///
/// - `loc_state` 那一行（加密记忆、loc 标记、`last_ok`）——转发目标只从这里取（`cmd/sync_relay.rs` `locations`），行没了
///   就**不再向它转发**；
/// - [Truth::forget_location]：位置上各设备的 head 记录、转发记账与待删的转发件、旧根指纹；
/// - 旧根接手累计的段结论（`oldroot.rs` [Truth::oldroot_forget_run]）；
/// - 为它留着的可转发原文：按剩下的位置逐个作者重判（[super::sync_relay::prune]；只剩一个位置时全删）。
///
/// 不动：已传水位与承袭上传指纹（键带位置与密钥指纹，里面记着本机在那里写过的最大 head 代号——同一个位置再加回来时
/// 代号必须接着往上，不能回到 1 让别的设备当成旧 head）；媒体的「在不在」记录与清单代号（`media_*`：代号只升不降，
/// 一个代号只对应一个文件，G8-3）。位置上的文件一个不碰（位置已经不用了，上面的东西不归本机管），本机的卡片与复习
/// 记录一条不动。没记过这个位置也照常回包（幂等）。回包 `{forgotten, relayDropped}`：删掉的状态行数、删掉的原文份数。
pub fn location_forget(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let location = str_req(req, "location")?;
    let mut forgotten = t.forget_location(col, location)?;
    forgotten += t.write(|| {
        t.conn()
            .prepare_cached(LOC_STATE_DROP_SQL)
            .map_err(sql)?
            .execute(params![col, location])
            .map_err(sql)
            .map(|n| n as u64)
    })?;
    t.oldroot_forget_run(col, location)?;
    let authors: Vec<Vec<u8>> = {
        let mut stmt = t.conn().prepare_cached(RELAY_AUTHORS_SQL).map_err(sql)?;
        let rows = stmt.query_map([col], |r| r.get(0)).map_err(sql)?;
        rows.collect::<rusqlite::Result<_>>().map_err(sql)?
    };
    let mut dropped = 0u64;
    for a in authors {
        let device = Id(a
            .as_slice()
            .try_into()
            .map_err(|_| "location_forget: bad device in relay_segs")?);
        dropped += super::sync_relay::prune(t, col, &device)?;
    }
    Ok(json!({"forgotten": forgotten, "relayDropped": dropped}))
}

/// `location_forget` 的分发入口：在这个文件的**每一个**集合里各忘一次 [location_forget]，回包两项各自相加。
///
/// 同步位置的配置是设备级的（文件夹位置、通道都存在设备本地偏好里，所有 profile 共用），每个 profile 的集合各自记着
/// 它在这个位置上的状态。只忘发命令的 profile 的集合，别的 profile 以前同步过这个位置的状态行与为它留着的转发原文就
/// 再也没人清（第六波复核）。所以不按发命令的 profile 取集合：发命令的 profile 没有集合（删掉了 / 新代里从没打开过）
/// 也照常忘别的集合，不报 `has no collection`。
pub fn location_forget_everywhere(t: &Truth<'_>, req: &Value) -> Result<Value, String> {
    let cols: Vec<i64> = {
        let mut stmt = t
            .conn()
            .prepare_cached(crate::store::gen4::dispatch::COLLECTIONS_SQL)
            .map_err(sql)?;
        let rows = stmt.query_map([], |r| r.get(0)).map_err(sql)?;
        rows.collect::<rusqlite::Result<_>>().map_err(sql)?
    };
    let (mut forgotten, mut dropped) = (0u64, 0u64);
    for col in cols {
        let v = location_forget(t, col, req)?;
        forgotten += v["forgotten"].as_u64().unwrap_or(0);
        dropped += v["relayDropped"].as_u64().unwrap_or(0);
    }
    Ok(json!({"forgotten": forgotten, "relayDropped": dropped}))
}

// ---------------------------------------------------------------------- 设备：停用、换身份

/// `retire {profile, device, retire, now}`：停用 / 取消停用一台别的设备（协议 3 `devices.rs` `retire` 同语义）：停用后
/// 因等它的数据而卡在等待缓冲里的操作同一个事务里投递（[Receiver] 把停用设备上的依赖当成已满足）。不删任何数据；它
/// 之后写了更新的 head 自动取消停用（[plan]）。回包 `{retired, delivered, settled}` + 本机修订号。
pub fn retire(t: &Truth<'_>, col: i64, profile: &str, req: &Value) -> Result<Value, String> {
    let device = Id::parse(str_req(req, "device")?).ok_or("retire: bad device")?;
    let on = req.get("retire") != Some(&Value::Bool(false));
    let me = me_of(t, col)?;
    if device == me.device {
        return Err("retire: cannot retire this device".into());
    }
    if on {
        let now = now_of(req)?;
        let head_seq = t
            .conn()
            .prepare_cached(LOC_HEAD_SEQ_SQL)
            .map_err(sql)?
            .query_row(params![col, &device.0[..]], |r| r.get::<_, Option<i64>>(0))
            .map_err(sql)?
            .unwrap_or(0);
        let rec = json!({"at": now, "applied": t.last_of(col, &device)?, "headSeq": head_seq});
        t.set_retired(col, &device, Some(&rec))?;
    } else {
        t.set_retired(col, &device, None)?;
    }
    let r = Receiver::open(t, col, Settle::Incremental)?.finish()?;
    let mut out =
        json!({"retired": on, "delivered": r.delivered, "settled": settled_json(&r.settled)});
    bump_revision(t, profile, r.delivered + 1, &mut out)?;
    Ok(out)
}

/// 一台设备在各位置上见过的最大 head seq（`loc_heads` 主键前缀 `col` 之后按设备过滤；行数 = 位置数 × 设备数，很少）。
pub(crate) const LOC_HEAD_SEQ_SQL: &str =
    "SELECT MAX(seq) FROM loc_heads WHERE col = ?1 AND device = ?2";

/// `rotate {profile, now}`：主动换身份（导入 / 恢复 / 拷目录之后预防，设计 §3.3）：`keep` = 本机日志末尾，什么都不搬，
/// 只换身份（[Truth::rotate_identity]）。回包 `{device, previous}`。
pub fn rotate(t: &Truth<'_>, col: i64, profile: &str, now: i64) -> Result<Value, String> {
    let me = me_of(t, col)?;
    let keep = t.last_of(col, &me.device)?;
    let device = t.rotate_identity(col, keep, now)?;
    let mut out = json!({"device": device.text(), "previous": me.device.text()});
    bump_revision(t, profile, 1, &mut out)?;
    Ok(out)
}

// ---------------------------------------------------------------------- 加密记忆（BUG-4299）

fn sealed_answer(
    row: Option<(Option<String>, Option<i64>, Option<String>, Option<String>)>,
) -> Value {
    match row {
        Some((_, Some(1), kdf, _)) => json!({
            "sealed": true,
            "kdf": kdf.and_then(|k| serde_json::from_str::<Value>(&k).ok()).unwrap_or(Value::Null),
        }),
        _ => json!({"sealed": false, "kdf": Value::Null}),
    }
}

fn loc_state_row(
    t: &Truth<'_>,
    col: i64,
    location: &str,
) -> Result<Option<(Option<String>, Option<i64>, Option<String>, Option<String>)>, String> {
    t.conn()
        .prepare_cached(LOC_STATE_SQL)
        .map_err(sql)?
        .query_row(params![col, location], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .optional()
        .map_err(sql)
}

/// `location_sealed {profile, location}`：本机是否见过这个位置是加密的（`{"sealed", "kdf"}`，协议 3 `sealed.rs` 同形）。
/// 迁移把协议 3 的记忆灌进了 `loc_state`（`carry.rs`）。
pub fn location_sealed(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let location = str_req(req, "location")?;
    Ok(sealed_answer(loc_state_row(t, col, location)?))
}

/// 段文件 / 中继件 / 重切中继件 / 承袭段对**它所在的位置**而言是不是密封的：四种协议 4 的件都是
/// `魔数[4] | 版本 | flags（bit0）` 开头。
pub fn sealed_at_location(prefix: &[u8]) -> bool {
    (prefix.starts_with(NATIVE_MAGIC)
        || prefix.starts_with(RELAY_MAGIC)
        || prefix.starts_with(RECUT_MAGIC)
        || prefix.starts_with(HERITAGE_MAGIC))
        && prefix.get(5).is_some_and(|f| f & 1 != 0)
}

/// `location_seal {profile, location, kdf?, seen?, now}`，字节块 = 读到的段的开头字节：记下「这个位置是加密的」（协议 3
/// `sealed.rs` `sync2_location_seal` 同语义）。没有任何证据什么都不写；记下就不撤；`kdf` 只在见到不同的时更新、只从
/// 旁证看到时不抹掉已记的。回包同 [location_sealed]。
pub fn location_seal(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    prefixes: &[Vec<u8>],
) -> Result<Value, String> {
    let location = str_req(req, "location")?;
    let kdf = req.get("kdf").filter(|k| !k.is_null());
    if let Some(k) = kdf {
        if !k.is_object() || k.to_string().len() > KDF_MAX_BYTES {
            return Err("location_seal: bad kdf".into());
        }
    }
    let seen = req.get("seen") == Some(&Value::Bool(true));
    let cur = loc_state_row(t, col, location)?;
    if kdf.is_none() && !seen && !prefixes.iter().any(|p| sealed_at_location(p)) {
        return Ok(sealed_answer(cur));
    }
    let was_sealed = cur.as_ref().is_some_and(|r| r.1 == Some(1));
    let cur_kdf = cur.as_ref().and_then(|r| r.2.clone());
    let next_kdf = kdf.map(Value::to_string).or(cur_kdf.clone());
    if was_sealed && next_kdf == cur_kdf {
        return Ok(sealed_answer(cur));
    }
    let check = kdf
        .and_then(|k| k.get("check"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    t.write(|| {
        t.conn()
            .prepare_cached(
                "INSERT INTO loc_state (col, loc_key, sealed, kdf, check_) VALUES (?1, ?2, 1, ?3, ?4) \
                 ON CONFLICT (col, loc_key) DO UPDATE SET sealed = 1, kdf = excluded.kdf, \
                 check_ = COALESCE(excluded.check_, check_)",
            )
            .map_err(sql)?
            .execute(params![col, location, next_kdf, check])
            .map_err(sql)?;
        Ok(())
    })?;
    Ok(sealed_answer(loc_state_row(t, col, location)?))
}

#[cfg(test)]
pub(crate) mod unit {
    use super::*;

    #[test]
    fn voids_in_counts_overlaps() {
        let runs = [(3, 2), (10, 5)];
        assert_eq!(voids_in(&runs, 1, 2), 0);
        assert_eq!(voids_in(&runs, 1, 3), 1);
        assert_eq!(voids_in(&runs, 4, 12), 4);
        assert_eq!(voids_in(&runs, 1, 100), 7);
    }

    #[test]
    fn prefixes_decide_sealed_for_the_location() {
        assert!(sealed_at_location(b"FSG4\x01\x01rest"));
        assert!(!sealed_at_location(b"FSG4\x01\x00rest"));
        assert!(sealed_at_location(b"FRL4\x01\x01"));
        assert!(sealed_at_location(b"FRX4\x01\x01"));
        assert!(!sealed_at_location(b"FRX4\x01\x00"));
        assert!(sealed_at_location(b"FSH4\x01\x01"));
        assert!(!sealed_at_location(b"FSG2\x01\x01"));
        assert!(!sealed_at_location(b"FSG4\x01"));
    }
}
