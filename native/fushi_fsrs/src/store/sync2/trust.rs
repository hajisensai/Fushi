//! 设备信任（设计 §9「不认识的设备公钥需要已有设备确认」，BUG 文档见 docs/bugs 里的 srs-sync2-device-trust）。
//!
//! 以前第一次见到的设备直接记下公钥、当作可信（transport.rs `trust_head`，首次信任）：随便一台能往同步位置写文件的
//! 设备，它的删除与彻底清除一到就落进本机投影，清除还会把本机日志里的内容换成哈希、重写本机的段。现在：
//!
//! - **可信**（`sync2_trust` 里没有行）：本机自己；升级到 v29 那一刻已经认识的设备（存量不追溯扣住）；本机库里还没有
//!   用户自己的东西（[library_fresh]：只有内置牌组 / 笔记类型）时第一次见到的设备——新设备第一次同步时对谁都不认识，
//!   库里也没有可丢的东西，不能把整个库的删除都扣住；从本机自己导出的 `.fushisrs` 并入的设备（集合 ID 由
//!   profile 决定，包只能出自同一个 profile 的设备）。
//! - **待确认**（`state = 1`）：本机库非空时第一次见到的设备。它的普通操作（新建、修改、复习、移动、标签……）照常
//!   投影；**删除**（`deleted` 写成时刻）与**彻底清除**（`Purge`）照常进操作日志（链、因果、版本向量、转发、段回收都
//!   不受影响：投递只看日志），但不投影、不进实体 → 操作索引（冲突中心、还原点、修改记录都看不见它们），只记进
//!   `sync2_trust_held`。
//! - **已拒绝**（`state = 2`）：同上，扣着的永不投影（日志里留着，链与因果要它们），之后再来的删除 / 清除同样扣住。
//!   可以改为信任（之前扣着的全部放行）。
//!
//! 放行（[release]）= 按 seq 把扣着的操作交给生产投影（[super::project_edit_noted] / [super::project_body]）：投影是
//! 操作集合的确定性函数（寄存器按因果支配、冲突扣住按并发关系判、清除只看 `saw`），晚投与一开始就投逐表相同。
//!
//! 信任是纯本机状态，不发布给别的设备：协议里没有能表达它的操作种类，新增会让旧版本设备停止同步（不能断代）。
//! 局限：每台设备各自确认；别的设备若信任了它，它们的投影里删除已生效，本机扣着期间两边投影不同——摘要的版本向量
//! 部分因此带上扣住集合的指纹（[digest_vv_tag]），双方都不会把这种「有意的不同」当成确定性 bug 上报。

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;

use super::{Touched, load_op, sql};
use crate::sync2::id::Id;
use crate::sync2::op::{Body, EditBody, EntKind, Op};
use crate::sync2::vv::{OpId, Vv};

/// `sync2_trust.state`：待本机确认。
pub(crate) const PENDING: i64 = 1;
/// `sync2_trust.state`：本机拒绝了。
pub(crate) const REJECTED: i64 = 2;

/// `sync2_trust_held.what`。
const WHAT_DELETE: &str = "delete";
const WHAT_PURGE: &str = "purge";

/// 本机的这个 profile 里还没有用户自己的东西：没有复习日志、没有修改记录，身份记录全是内置的（默认牌组、内置笔记
/// 类型——Dart 开库就写，`SrsDbStore.ensureBuiltins`，所以不能要求操作日志为空）。新装的设备第一次同步时就是这样：
/// 库里没有可丢的东西，这时认识的设备不扣。
pub(crate) fn library_fresh(c: &Connection, profile: &str) -> Result<bool, String> {
    c.prepare_cached(
        "SELECT NOT EXISTS (SELECT 1 FROM srs_review_logs WHERE profile_uid = srs_id(?1))            AND NOT EXISTS (SELECT 1 FROM srs_field_edits WHERE profile_uid = srs_id(?1))            AND NOT EXISTS (SELECT 1 FROM srs_entities WHERE profile_uid = srs_id(?1)                              AND json_extract(payload_json, '$.builtin') IS NULL)",
    )
    .map_err(sql)?
    .query_row([profile], |r| r.get(0))
    .map_err(sql)
}

/// [device] 的信任状态：None = 可信。
pub(crate) fn state(c: &Connection, profile: &str, device: &Id) -> Result<Option<i64>, String> {
    c.prepare_cached("SELECT state FROM sync2_trust WHERE profile_uid = srs_id(?1) AND device = ?2")
        .map_err(sql)?
        .query_row(params![profile, device.0.to_vec()], |r| r.get(0))
        .optional()
        .map_err(sql)
}

/// 第一次见到 [device]（transport.rs `trust_head` 刚插入它的设备行）：本机库非空就记成待确认。[seen_at] = 它那份 head
/// 的写出时刻（界面显示「首次出现」）。
///
/// 「库非空」读的是投影。新设备收段通道（channel.rs）没做完时投影里还缺已收下的操作（追加阶段一条都没投）：同一批
/// 操作逐条投递到这一刻库已非空，通道路径却读到空库、把这台设备当成可信，它的删除与清除就不扣了（BUG-4478）。所以
/// 先把通道做完再判。[c] 在调用方的事务里，这里只能在那笔事务里一次做完：`sync2_plan_at` 进事务之前已按片做过
/// （[sees_new_device]），正常走不到，这是兜底。做完的片落进投影的变化交给 [settled]（同
/// [super::channel::settle]：调用方攒着、随下一条命令的回包带回 Dart）。
pub(crate) fn note_new_device(
    c: &Connection,
    profile: &str,
    device: &Id,
    seen_at: i64,
    settled: &mut dyn FnMut(&Touched),
) -> Result<(), String> {
    super::channel::settle(c, profile, settled)?;
    if library_fresh(c, profile)? {
        return Ok(());
    }
    c.prepare_cached(
        "INSERT OR IGNORE INTO sync2_trust (profile_uid, device, state, since) VALUES (srs_id(?1), ?2, ?3, ?4)",
    )
    .map_err(sql)?
    .execute(params![profile, device.0.to_vec(), PENDING, seen_at])
    .map_err(sql)?;
    Ok(())
}

/// [heads] 里有没有本机还不认识的设备（`plan` 会为它调 [note_new_device] 的那种；只多不少：别的集合的、要更新
/// 版本才读得了的 head 也算）。`sync2_plan_at` 据此在进写事务之前先把没做完的收段通道按片做完。
pub(crate) fn sees_new_device(
    c: &Connection,
    profile: &str,
    heads: &[Vec<u8>],
) -> Result<bool, String> {
    let mut known = c
        .prepare_cached(
            "SELECT EXISTS (SELECT 1 FROM sync2_devices WHERE profile_uid = srs_id(?1) AND device = ?2) \
                 OR EXISTS (SELECT 1 FROM sync2_self WHERE profile_uid = srs_id(?1) AND device = ?2)",
        )
        .map_err(sql)?;
    for bytes in heads {
        let Ok(h) = crate::sync2::segment::Head::decode(bytes) else {
            continue;
        };
        if !known
            .query_row(params![profile, h.device.0.to_vec()], |r| {
                r.get::<_, bool>(0)
            })
            .map_err(sql)?
        {
            return Ok(true);
        }
    }
    Ok(false)
}

/// 一条修改是不是删除（`deleted` 写成时刻；写成 null 是恢复，不算）。迁移进来的旧删除同样算。
fn is_delete(e: &EditBody) -> bool {
    e.key == "deleted"
        && serde_json::from_str::<Value>(&e.value)
            .ok()
            .is_some_and(|v| v.is_i64())
}

fn hold(
    c: &Connection,
    profile: &str,
    op: &Op,
    what: &str,
    kind: EntKind,
    entity: &str,
) -> Result<bool, String> {
    if state(c, profile, &op.id.device)?.is_none() {
        return Ok(false);
    }
    c.prepare_cached(
        "INSERT OR IGNORE INTO sync2_trust_held (profile_uid, device, seq, what, kind, entity) VALUES (srs_id(?1), ?2, ?3, ?4, ?5, srs_id(?6))",
    )
    .map_err(sql)?
    .execute(params![profile, op.id.device.0.to_vec(), op.id.seq as i64, what, kind.wire(), entity])
    .map_err(sql)?;
    Ok(true)
}

/// 投影一条修改之前问：它是不可信设备的删除就扣住（记下、返回 true，调用方不投影、不进索引）。
pub(crate) fn hold_edit(
    c: &Connection,
    profile: &str,
    op: &Op,
    e: &EditBody,
) -> Result<bool, String> {
    if !is_delete(e) {
        return Ok(false);
    }
    hold(c, profile, op, WHAT_DELETE, e.kind, &e.entity.text())
}

/// 执行一条 `Purge` 之前问：出自不可信设备就扣住。
pub(crate) fn hold_purge(
    c: &Connection,
    profile: &str,
    op: &Op,
    kind: EntKind,
    entity: &str,
) -> Result<bool, String> {
    hold(c, profile, op, WHAT_PURGE, kind, entity)
}

/// 信任 [device]：信任记录删掉，扣着的删除 / 清除按 seq 交给生产投影。返回放行的条数。
pub(crate) fn release(
    c: &Connection,
    profile: &str,
    device: &Id,
    now: i64,
    t: &mut Touched,
) -> Result<usize, String> {
    let seqs: Vec<i64> = c
        .prepare_cached(
            "SELECT seq FROM sync2_trust_held WHERE profile_uid = srs_id(?1) AND device = ?2 ORDER BY seq",
        )
        .map_err(sql)?
        .query_map(params![profile, device.0.to_vec()], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    // 先撤信任记录与扣住登记：下面的投影再问 [hold_edit] / [hold_purge] 时它已经可信。
    for table in ["sync2_trust_held", "sync2_trust"] {
        c.execute(
            &format!("DELETE FROM {table} WHERE profile_uid = srs_id(?1) AND device = ?2"),
            params![profile, device.0.to_vec()],
        )
        .map_err(sql)?;
    }
    let mut n = 0;
    for seq in seqs {
        let id = OpId {
            device: *device,
            seq: seq as u64,
        };
        let Some(op) = load_op(c, profile, &id)? else {
            continue;
        };
        match op.body().map_err(|e| e.to_string())? {
            // 旧修改记录闭包在第一次投递时已记（[super::project_edit]），这里不再记（`upto` 会倒退）。
            Body::Edit(e) => super::project_edit_noted(c, profile, &op, &e, now, true, t)?,
            body @ Body::Purge { .. } => super::project_body(c, profile, &op, body, now, true, t)?,
            // 扣着期间作者自己把它收成了副本骨架（dedup.rs）等：没有可投的了。
            _ => continue,
        }
        n += 1;
    }
    Ok(n)
}

/// 拒绝 [device]（只对还没信任的设备：可信设备的删除早已投影，拒绝改变不了它们，停用见 devices.rs）。
pub(crate) fn reject(c: &Connection, profile: &str, device: &Id) -> Result<(), String> {
    let n = c
        .execute(
            "UPDATE sync2_trust SET state = ?3 WHERE profile_uid = srs_id(?1) AND device = ?2",
            params![profile, device.0.to_vec(), REJECTED],
        )
        .map_err(sql)?;
    if n == 0 {
        return Err("trust: device is already trusted".into());
    }
    Ok(())
}

/// 摘要串里版本向量的部分（digest.rs `VV_PREFIX` + 版本向量哈希）；本机扣着不可信设备的操作时再接上扣住集合的
/// 指纹。别的设备（含老版本）只在这部分逐字相同时才比根：信任了它的设备与扣着它的本机不比（两边投影本来就该
/// 不同），扣着同一批的设备照样互相比较。放行之后指纹消失，回到与别的设备逐位可比。
pub(crate) fn digest_vv_tag(c: &Connection, profile: &str, vv: &Vv) -> Result<String, String> {
    let base = format!("{}{}", super::digest::VV_PREFIX, vv.hash_hex());
    let held: Vec<(Vec<u8>, i64)> = c
        .prepare_cached(
            "SELECT device, seq FROM sync2_trust_held WHERE profile_uid = srs_id(?1) ORDER BY device, seq",
        )
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    if held.is_empty() {
        return Ok(base);
    }
    let mut h = blake3::Hasher::new();
    for (d, s) in &held {
        h.update(d);
        h.update(&s.to_le_bytes());
    }
    Ok(format!("{base}~{}", &h.finalize().to_hex()[..16]))
}

/// 设备状态补充（devices.rs `status_extras`）：设备 ID 文本 → (`pending` / `rejected`, 首次出现, 扣着的删除数, 扣着的清除数)。
pub(crate) fn untrusted(
    c: &Connection,
    profile: &str,
) -> Result<Vec<(Id, &'static str, i64, i64, i64)>, String> {
    let rows: Vec<(Vec<u8>, i64, i64)> = c
        .prepare_cached(
            "SELECT device, state, since FROM sync2_trust WHERE profile_uid = srs_id(?1)",
        )
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut out = Vec::new();
    for (d, st, since) in rows {
        let Ok(arr) = <[u8; 16]>::try_from(d.as_slice()) else {
            continue;
        };
        let count = |what: &str| -> Result<i64, String> {
            c.prepare_cached(
                "SELECT COUNT(*) FROM sync2_trust_held WHERE profile_uid = srs_id(?1) AND device = ?2 AND what = ?3",
            )
            .map_err(sql)?
            .query_row(params![profile, d, what], |r| r.get(0))
            .map_err(sql)
        };
        let label = if st == REJECTED {
            "rejected"
        } else {
            "pending"
        };
        out.push((
            Id(arr),
            label,
            since,
            count(WHAT_DELETE)?,
            count(WHAT_PURGE)?,
        ));
    }
    Ok(out)
}

impl crate::store::SrsCore {
    /// 信任 / 拒绝一台还没确认的设备（冲突中心「待确认的设备」）。信任：扣着的删除 / 清除按生产投影放行，返回与
    /// [crate::store::SrsCore::sync2_append] 同形的投影变化（`marks` / `replayed` / `changed` / `purged`）外加 `released`；
    /// 已经可信的设备再信任一次什么也不做。拒绝：只对待确认 / 已拒绝的设备，扣着的继续扣着。
    pub fn sync2_trust(
        &self,
        profile: &str,
        device: &str,
        trust: bool,
        now: i64,
    ) -> Result<Value, String> {
        let id = Id::parse(device).ok_or("trust: bad device")?;
        let w = self.writer()?;
        super::in_savepoint(&w, |c| trust_on(c, profile, &id, trust, now))
    }
}

/// [crate::store::SrsCore::sync2_trust] 的本体：在调用方持着的写连接、开好的 SAVEPOINT 里做（不自己取锁）。本机写命令
/// 分发（store/ffi.rs `local_write_body`）把它与缓存刷新、本机状态行放进同一个 SAVEPOINT。
pub(crate) fn trust_on(
    c: &Connection,
    profile: &str,
    id: &Id,
    trust: bool,
    now: i64,
) -> Result<Value, String> {
    let local = super::Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
    if *id == local.device {
        return Err("trust: this device is always trusted".into());
    }
    let mut t = Touched::default();
    let released = if trust {
        release(c, profile, id, now, &mut t)?
    } else {
        reject(c, profile, id)?;
        0
    };
    let replayed = super::replay_touched(c, &t)?;
    Ok(serde_json::json!({
        "trusted": trust,
        "released": released,
        "marks": t.marks.to_json(),
        "replayed": replayed,
        "changed": t.entities_changed.iter().map(|(k, e)| serde_json::json!([k, e])).collect::<Vec<_>>(),
        "purged": t.purged.iter().map(|(k, e)| serde_json::json!([k, e])).collect::<Vec<_>>(),
    }))
}

/// 测试：信任此刻全部待确认的设备（端到端助手模拟「用户每次都点了信任」，见 tests.rs `AUTO_TRUST`）。
#[cfg(test)]
pub(crate) fn trust_all_pending(core: &crate::store::SrsCore, profile: &str, now: i64) {
    let pending: Vec<Id> = core
        .read_visible(|c| {
            Ok(untrusted(c, profile)?
                .into_iter()
                .filter(|x| x.1 == "pending")
                .map(|x| x.0)
                .collect())
        })
        .unwrap();
    for d in pending {
        core.sync2_trust(profile, &d.text(), true, now).unwrap();
    }
}
