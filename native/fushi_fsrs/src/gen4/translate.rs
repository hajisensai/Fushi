//! 转译 T（设计 §3.1、§3.2）：一条协议 3 的旧操作 → 承袭日志里的一个槽。
//!
//! T 是纯函数：只看这条操作自己与它在原协议 3 链上的链值，不读库、不看别的操作、不看时钟、不看是哪台设备在转。
//! 所以同一条旧操作谁转出来字节都相同（[HeritageSlot::encode]），承袭日志才能按操作号幂等、由任何升级过的设备上传。
//! **T 错了是永久的**——转出的字节进冻结的承袭日志；规则带版本号 [T_VERSION]，由黄金向量钉死，改规则必须升版本。
//!
//! # 规则（[T_VERSION] = 1，冻结；自上而下取第一条命中的）
//!
//! | 旧操作 | 槽 |
//! |---|---|
//! | 种类 12（MediaAt），不论是不是骨架 | 空洞（协议 4 里「位置上有没有媒体」不再是操作，设计 §4.5） |
//! | 副本骨架（`Op::duplicate` 的产物） | 副本记录：种类、HLC、原件的操作号、旧修改记录的旧戳（紧凑形） |
//! | 其余骨架（彻底清除的；解不开的也算） | 空洞 |
//! | `schema == 1`、协议 3 解得开、种类认识、**解码再编码等于原字节**、转出的操作体过得了协议 4 的严格解码 | 操作（信封原值，`fmt = 4`，操作体见下） |
//! | 其余（不认识的种类、解不开的载荷、`schema != 1`、带尾字节 / 非最短 varint / 未知标志位的载荷……） | 原样件（整条原样带过来） |
//!
//! 每个槽带 `fp` = 原链值的前 8 字节（分叉判据）。信封（操作号、HLC、依赖向量、种类）一律原值：不改任何 ID、不重排、
//! 不合并、不做任何「谁赢」的判断。
//!
//! 操作体逐字段对应：
//!
//! - Entity、标签增删与顺序、Checkpoint、Purge、Media、DeckAlias、LegacyUnknown、Dedup：字段原值（两代布局相同）。
//! - Edit：`kind / entity / key / value / machine` 原值，`anchored` = 协议 3 的 `ts`（它只有 0 / 1），旧戳换成紧凑形 [stamp_of]。
//! - Log：字段一一对应，`legacy_hlc` / `legacy_server_time` 保留；`res` / `extra` 的 JSON 原文不动（含拼回的配置快照）。
//! - 旧戳：写入者、序号、HLC 文本、`server_time` 逐字保留；上下文只留**语义**（归一后的前缀 + 零散 dot，去掉合成写入者
//!   `sync2:`，与现有投影路径 store/sync2/mod.rs `strip_synthetic_ctx` 相同）。判定（registers.rs）只用「上下文含不含某个 dot」，
//!   归一不改这个关系，所以判定结果逐条不变；上下文 JSON 原文的写法（多余的键、<= 0 的分量、能并进前缀的 dot）不过界。
//!
//! # 原样件与「应用与否跟协议 3 相同」
//!
//! 协议 3 的解码器是宽松的：只读已知前缀、不看 `schema`、收非最短 varint。它**照常应用**那些「解得开但字节不规范」的操作。
//! T 不把这类操作变形成规范操作（那会丢掉没人交代过的字节，而 T 丢的东西必须是有限的一张表），而是原样带过来；
//! 派生层用 [applied_body] 取「协议 3 会怎么读它」——解得开、种类认识的照常应用，其余不应用。这样两头都不丢：
//! 字节原样在，语义与协议 3 相同。协议 3 自己的写者从不产生这类字节，真实库里应当是 0 条（读入器的统计单列）。
//!
//! # 槽的并（设计 §3.2）
//!
//! 同一个 `(旧设备, seq)` 会被多台升级过的设备各上传一次，各自可能处于不同状态（完整 / 已按 Dedup 成了副本记录 /
//! 已按 Purge 成了空洞）。[join_slots] 是这些状态上的并：
//!
//! - `fp` 不同 = 那台旧设备的日志分叉过 → [Joined::Fork]，两支都留，绝不取其一。
//! - 完整（操作 / 原样件）< 空洞 < 副本记录，取靠后的。协议 3 里 `Op::purge` / `Op::duplicate` 对已是骨架的都原样返回，
//!   「先清除后认副本」留清除骨架、反过来留副本骨架，两台设备可能各持一种；取副本记录（它带旧戳，闭包要用）。
//! - 同秩而内容不同 → [Joined::Conflict]：同一个 T 版本下诚实的设备造不出来（链值绑住了信封与载荷哈希；同一条操作
//!   只会被作者的第一条 Dedup 认成副本），出现就是数据坏了或有人作伪，调用方报出来、不落库。
//!
//! **只在同一个 T 版本内有定义**：不同版本转出的同一条操作字节本来就不同，会被判成冲突；跨版本怎么取（取高版本）
//! 是收段一侧的事，要在调用这里之前裁掉。
//!
//! # 本机的槽谁来推进（已定，2026-11-12 所有者拍板；取代设计 §3.2 第 1 条的「以来的为准」）
//!
//! **槽的状态只由本机自己应用 Purge / Dedup 推进**（[purge_slot] / [dedup_slot]）。收到别人的空洞 / 副本记录、而本机手里
//! 是完整操作时，**不动本机的槽**。原因：清除与认副本在协议 3 里都是「本机应用到那条操作时才生效」，而且受本机的信任状态管
//! ——不可信 / 已拒绝的设备发来的 Purge 进日志但不执行（store/sync2/trust.rs）。无条件「以来的为准」会让本机拒绝过的清除
//! 经别人上传的承袭段生效，而且不可逆。
//!
//! [join_slots] 的「完整 < 空洞 < 副本记录」只用在两处：**本机还没有这个槽**（收什么留什么），以及**同一个位置上同一个
//! 操作号留哪一份**（留靠后的）。收段一侧具体怎么接这三个函数是 G6 的事，这里只给纯函数。

use std::cmp::Ordering;
use std::collections::BTreeMap;

use super::heritage::{Alias, Fp, HeritageSlot, Raw3, SlotBody, fingerprint};
use super::op::{BODY_FMT, Body4, Edit4, Log4, Op4};
use super::stamp::{HeritageStamp, StampCtx, StampHlc};
use crate::sync2::codec::{DResult, DecodeError};
use crate::sync2::keys::CollectionKey;
use crate::sync2::op as v3;
use crate::sync2::segment::{Chain, SegmentError, SegmentHeader, chain_next, open_verified};
use crate::sync2::vv::OpId;

/// 转译规则的版本。承袭段头里带着它（heritage.rs `t_version`）；规则有任何变化都必须加一，并更新黄金向量。
pub const T_VERSION: u32 = 1;

/// 一条旧操作满足协议 3 自己的不变量（`Op::read` 与段解码器拒收不满足的）。从库行拼出来的操作先过这一关。
pub fn check_legacy(op: &v3::Op) -> Result<(), &'static str> {
    if op.id.seq == 0 {
        return Err("op seq 0");
    }
    if op.hlc.device != op.id.device {
        return Err("op hlc names another device");
    }
    if op.deps.get(&op.id.device) != 0 {
        return Err("op deps name its own device");
    }
    if op.deps.0.values().any(|&s| s == 0) {
        return Err("op deps carry a zero entry");
    }
    Ok(())
}

/// 旧戳 → 紧凑旧戳。全函数（任何文本都有输出）。
pub fn stamp_of(l: &v3::LegacyStamp) -> HeritageStamp {
    HeritageStamp {
        writer: l.writer.clone(),
        seq: l.seq,
        ctx: StampCtx::parse(&l.ctx_json),
        hlc: StampHlc::of(&l.hlc),
        server_time: l.server_time,
    }
}

/// 协议 3 的操作体 → 协议 4 的操作体，逐字段照搬（不归一、不检查）。协议 4 没有的（MediaAt、骨架、不认识的种类）= None。
fn carry(body: v3::Body) -> Option<Body4> {
    Some(match body {
        v3::Body::Entity { kind, id, data } => Body4::Entity { kind, id, data },
        v3::Body::Edit(e) => Body4::Edit(Edit4 {
            kind: e.kind,
            entity: e.entity,
            key: e.key,
            value: e.value,
            machine: e.machine,
            anchored: e.ts & 1 != 0,
            stamp: e.legacy.as_ref().map(stamp_of),
        }),
        v3::Body::Log(l) => Body4::Log(Log4 {
            id: l.id,
            card: l.card,
            note: l.note,
            kind: l.kind,
            rating: l.rating,
            revokes: l.revokes,
            at: l.at,
            ts: l.ts,
            origin: l.origin,
            rtype: l.rtype,
            dur: l.dur,
            params: l.params,
            alg: l.alg,
            utc_off: l.utc_off,
            rollover: l.rollover,
            anki_id: l.anki_id,
            fv: l.fv,
            intent: l.intent,
            res: l.res,
            extra: l.extra,
            hlc: l.legacy_hlc.as_deref().map(StampHlc::of),
            server_time: l.legacy_server_time,
        }),
        v3::Body::TagAdd { note, tag } => Body4::TagAdd { note, tag },
        v3::Body::TagRemove { note, tag } => Body4::TagRemove { note, tag },
        v3::Body::TagOrder { note, tags } => Body4::TagOrder { note, tags },
        v3::Body::Checkpoint { name, reason } => Body4::Checkpoint { name, reason },
        v3::Body::Purge { kind, entity } => Body4::Purge { kind, entity },
        v3::Body::Media { name, sha256, size } => Body4::Media { name, sha256, size },
        v3::Body::DeckAlias { from, to } => Body4::DeckAlias { from, to },
        v3::Body::LegacyUnknown { json } => Body4::LegacyUnknown { json },
        v3::Body::Dedup { pairs } => Body4::Dedup { pairs },
        v3::Body::MediaAt { .. }
        | v3::Body::Unknown
        | v3::Body::Purged
        | v3::Body::Duplicate { .. } => return None,
    })
}

/// 一条未清除的旧操作为什么成了原样件。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum RawReason {
    /// 协议 3 不认识的种类（它也不应用）。
    UnknownKind,
    /// 协议 3 解不开载荷（它也不应用；投递时就会报错）。
    Undecodable,
    /// `schema != 1`（协议 3 不看这个字段，照常应用）。
    Schema,
    /// 协议 3 解码再编码不等于原字节：尾字节、非最短 varint、未知标志位……（协议 3 照常应用）。
    NotCanonical3,
    /// 转出的操作体过不了协议 4 的严格解码：内容是规范 UUID 文本的文本引用、同一个 seq 出现两次的 Dedup……（协议 3 照常应用）。
    NotCanonical4,
}

impl RawReason {
    /// 协议 3 会不会应用这条操作（[applied_body] 给不给得出操作体）。
    pub fn applied_by_protocol_3(self) -> bool {
        !matches!(self, RawReason::UnknownKind | RawReason::Undecodable)
    }
}

/// 未清除、种类不是 12 的旧操作：转得出规范操作体就给操作体的字节，否则给成为原样件的原因。
fn body4_bytes(op: &v3::Op) -> Result<Vec<u8>, RawReason> {
    let body = v3::Body::decode(op.kind, &op.payload).map_err(|_| RawReason::Undecodable)?;
    if matches!(body, v3::Body::Unknown) {
        return Err(RawReason::UnknownKind);
    }
    if op.schema != v3::SCHEMA {
        return Err(RawReason::Schema);
    }
    if body.encode()[..] != op.payload[..] {
        return Err(RawReason::NotCanonical3);
    }
    let body = carry(body).ok_or(RawReason::UnknownKind)?;
    let bytes = body.encode();
    match Body4::decode(op.kind, BODY_FMT, &bytes) {
        Ok(back) if back == body => Ok(bytes),
        _ => Err(RawReason::NotCanonical4),
    }
}

/// 一条旧操作会被转成原样件的原因（转成别的 = None）。统计与验收用。
pub fn raw_reason(op: &v3::Op) -> Option<RawReason> {
    if op.purged || op.kind == v3::KIND_MEDIA_AT {
        return None;
    }
    body4_bytes(op).err()
}

/// T：一条旧操作 + 它处的原协议 3 链值 → 一个槽。规则见文件头。
///
/// 只有不满足协议 3 自身不变量的输入（[check_legacy]）才报错；满足的一律有输出。
pub fn translate(op: &v3::Op, chain: &Chain) -> Result<HeritageSlot, &'static str> {
    check_legacy(op)?;
    let fp = fingerprint(chain);
    if op.kind == v3::KIND_MEDIA_AT {
        return Ok(HeritageSlot::void(op.id, fp));
    }
    if op.purged {
        return Ok(match v3::skeleton_body(&op.payload) {
            Ok(v3::Body::Duplicate { of, legacy }) => HeritageSlot::alias(
                op.id,
                fp,
                Alias {
                    kind: op.kind,
                    wall: op.hlc.wall,
                    logical: op.hlc.logical,
                    of,
                    stamp: legacy.as_ref().map(stamp_of),
                },
            ),
            _ => HeritageSlot::void(op.id, fp),
        });
    }
    Ok(match body4_bytes(op) {
        Ok(bytes) => HeritageSlot::op(
            fp,
            Op4 {
                id: op.id,
                hlc: op.hlc,
                deps: op.deps.clone(),
                kind: op.kind,
                fmt: BODY_FMT,
                payload: bytes.into(),
            },
        ),
        Err(_) => HeritageSlot::raw3(fp, Raw3::of_v3(op)),
    })
}

/// 转译一个协议 3 的段文件（或它的转发件）：验签、解密、重算链（`sync2::segment::open_verified` + `verify`），
/// 链对上了才逐条交出槽。[public] 是作者的公钥，[key] 是段所在位置的集合密钥。
pub fn translate_segment(
    bytes: &[u8],
    public: &[u8; 32],
    key: Option<&CollectionKey>,
    mut f: impl FnMut(HeritageSlot) -> Result<(), String>,
) -> Result<SegmentHeader, SegmentError> {
    let seg = open_verified(bytes, public, key)?;
    let mut chain = seg.header.prev_chain;
    for op in seg.verify()? {
        let op = op?;
        chain = chain_next(&chain, &op);
        let slot = translate(&op, &chain).map_err(|m| SegmentError::Corrupt(m.to_owned()))?;
        f(slot).map_err(SegmentError::Corrupt)?;
    }
    Ok(seg.header)
}

/// 派生层该按什么应用这个槽：操作 → 它的操作体；原样件 → 协议 3 的解码器解出的值（解不开 / 不认识 = 不应用）；
/// 副本记录、空洞 → 不应用。
///
/// 原样件给出的操作体是协议 3 的值逐字段照搬，**不保证能规范编码**（文本引用可能是 UUID 文本形、Dedup 的 seq 可能重复）；
/// 只用来应用，不要拿去编码。
pub fn applied_body(slot: &HeritageSlot) -> Option<Body4> {
    match &slot.body {
        SlotBody::Op(op) => op.body().ok().filter(|b| !matches!(b, Body4::Unknown)),
        SlotBody::Raw3(raw) => v3::Body::decode(raw.kind(), raw.payload())
            .ok()
            .and_then(carry),
        SlotBody::Alias(_) | SlotBody::Void => None,
    }
}

/// [join_slots] 的结果。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Joined {
    One(HeritageSlot),
    /// 链指纹不同：那台旧设备的日志分叉过，两支都要留。
    Fork,
    /// 链指纹相同、同秩而内容不同：诚实的设备造不出来。
    Conflict,
}

/// 状态的先后：完整 < 空洞 < 副本记录。
fn rank(body: &SlotBody) -> u8 {
    match body {
        SlotBody::Op(_) | SlotBody::Raw3(_) => 0,
        SlotBody::Void => 1,
        SlotBody::Alias(_) => 2,
    }
}

/// 同一个操作号的两个槽的并（同一个 T 版本内；规则见文件头）。操作号不同的两个槽没有并，按冲突报。
///
/// 用在：本机没有这个槽时收哪一份、同一个位置上同号留哪一份。**不用来**拿收到的空洞 / 副本记录改本机已有的完整槽
/// ——本机的槽只由 [purge_slot] / [dedup_slot] 推进（文件头「本机的槽谁来推进」，已定）。
pub fn join_slots(a: &HeritageSlot, b: &HeritageSlot) -> Joined {
    if a.id != b.id {
        return Joined::Conflict;
    }
    if a.fp != b.fp {
        return Joined::Fork;
    }
    match rank(&a.body).cmp(&rank(&b.body)) {
        Ordering::Less => Joined::One(b.clone()),
        Ordering::Greater => Joined::One(a.clone()),
        Ordering::Equal if a == b => Joined::One(a.clone()),
        Ordering::Equal => Joined::Conflict,
    }
}

/// 本机应用了一条 Purge、目标是这个槽的操作：完整内容 → 空洞；已经是副本记录 / 空洞的不动
/// （协议 3 的 `Op::purge` 对骨架原样返回）。对任何未清除的旧操作 `purge_slot(T(op)) == T(op.purge())`。
///
/// 本机的槽只由这个函数与 [dedup_slot] 按本机自己应用 Purge / Dedup 的顺序推进（文件头「本机的槽谁来推进」，已定）：
/// 本机按自己的信任状态决定执行不执行一条 Purge，执行了才调这里。什么时候调、怎么落库是 G6 的事。
pub fn purge_slot(slot: &HeritageSlot) -> HeritageSlot {
    match &slot.body {
        SlotBody::Op(_) | SlotBody::Raw3(_) => HeritageSlot::void(slot.id, slot.fp),
        SlotBody::Alias(_) | SlotBody::Void => slot.clone(),
    }
}

/// 本机应用了作者的一条 Dedup、其中一对说这个槽的操作是 [of] 的副本：完整内容 → 副本记录（留种类、HLC、旧修改记录的旧戳）；
/// 已经是副本记录 / 空洞的不动（协议 3 的 `Op::duplicate` 对骨架原样返回——同一条操作只认第一次）。
/// 对任何未清除、种类不是 12 的旧操作 `dedup_slot(T(op), of) == op.duplicate(of).map(T)`，包括协议 3 自己报错的情形
/// （载荷解不开的原样件：协议 3 的 `Op::duplicate` 在这里报错，应用那条 Dedup 的一轮整个失败）。
///
/// 与 [purge_slot] 一样只在本机应用到那条 Dedup 时调；收到别人的副本记录不改本机已有的完整槽。
pub fn dedup_slot(slot: &HeritageSlot, of: OpId) -> DResult<HeritageSlot> {
    let (hlc, kind, stamp) = match &slot.body {
        SlotBody::Alias(_) | SlotBody::Void => return Ok(slot.clone()),
        SlotBody::Op(op) => {
            let stamp = match op.body()? {
                Body4::Edit(e) => e.stamp,
                _ => None,
            };
            (op.hlc, op.kind, stamp)
        }
        SlotBody::Raw3(raw) => {
            let stamp = match v3::Body::decode(raw.kind(), raw.payload())? {
                v3::Body::Edit(e) => e.legacy.as_ref().map(stamp_of),
                _ => None,
            };
            (raw.hlc(), raw.kind(), stamp)
        }
    };
    Ok(HeritageSlot::alias(
        slot.id,
        slot.fp,
        Alias {
            kind,
            wall: hlc.wall,
            logical: hlc.logical,
            of,
            stamp,
        },
    ))
}

/// 槽的集合，按 `(操作号, 链指纹)` 存，插入走 [join_slots]。它是「多台设备各上传一份」的参考语义：
/// 插入的顺序与分组不影响结果（交换、结合、幂等——测试钉），于是 `T(S1) ∪ T(S2) = T(S1 ∪ S2)`。
///
/// 一个集合只装同一个 T 版本转出的槽。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SlotSet {
    slots: BTreeMap<(OpId, Fp), HeritageSlot>,
}

impl SlotSet {
    pub fn new() -> SlotSet {
        SlotSet::default()
    }

    /// 并进一个槽。冲突时报错、集合不变。
    pub fn insert(&mut self, slot: HeritageSlot) -> Result<(), DecodeError> {
        let key = (slot.id, slot.fp);
        let joined = match self.slots.get(&key) {
            None => slot,
            Some(have) => match join_slots(have, &slot) {
                Joined::One(s) => s,
                // 键里带着链指纹，同键不会分叉。
                Joined::Fork | Joined::Conflict => {
                    return Err(DecodeError("heritage slots conflict"));
                }
            },
        };
        self.slots.insert(key, joined);
        Ok(())
    }

    pub fn merge(&mut self, other: &SlotSet) -> Result<(), DecodeError> {
        for s in other.slots.values() {
            self.insert(s.clone())?;
        }
        Ok(())
    }

    /// 按（操作号, 链指纹）升序。
    pub fn iter(&self) -> impl Iterator<Item = &HeritageSlot> {
        self.slots.values()
    }

    pub fn len(&self) -> usize {
        self.slots.len()
    }

    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }

    /// 分叉了的操作号（同一个号有不止一个链指纹），升序、不重复。
    pub fn forks(&self) -> Vec<OpId> {
        let mut out: Vec<OpId> = Vec::new();
        let mut prev: Option<OpId> = None;
        for (id, _) in self.slots.keys() {
            if prev == Some(*id) && out.last() != Some(id) {
                out.push(*id);
            }
            prev = Some(*id);
        }
        out
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::sync::Arc;

    use proptest::prelude::*;

    use super::*;
    use crate::gen4::heritage::{HeritageMeta, open_heritage, pack_heritage};
    use crate::gen4::op::tests::id;
    use crate::gen4::{hex, unhex};
    use crate::sync2::codec::Reader;
    use crate::sync2::dvv::Dvv;
    use crate::sync2::hlc::Hlc;
    use crate::sync2::id::{Id, Key};
    use crate::sync2::keys::DeviceKey;
    use crate::sync2::op::{EditBody, EntKind, Intent, LegacyStamp, LogBody};
    use crate::sync2::segment::{CHAIN_ZERO, chain_next};
    use crate::sync2::vv::Vv;

    /// 旧设备。
    const OLD: u8 = 0x0d;
    const K1: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=#1";
    const TAGS: &str = "sync2:tags:8f28cfa8-6dd3-592d-8e4a-2bf5aec4060d";

    fn oid(seq: u64) -> OpId {
        OpId {
            device: id(OLD),
            seq,
        }
    }

    /// 一条协议 3 的操作（信封固定：依赖向量一项、HLC 跟着 seq 走）。
    pub fn op3(seq: u64, kind: u16, payload: Vec<u8>) -> v3::Op {
        let mut deps = Vv::new();
        deps.set(id(0xd2), 5);
        v3::Op {
            id: oid(seq),
            hlc: Hlc {
                wall: 1_800_000_000_000 + seq as i64,
                logical: 2,
                device: id(OLD),
            },
            deps: Arc::new(deps),
            kind,
            schema: v3::SCHEMA,
            payload: payload.into(),
            purged: false,
        }
    }

    fn of_body(seq: u64, b: &v3::Body) -> v3::Op {
        op3(seq, b.kind(), b.encode())
    }

    fn stamp3() -> LegacyStamp {
        LegacyStamp {
            writer: K1.into(),
            seq: 4821,
            // 上下文原文带着合成写入者、能并进前缀的 dot、多余的键：都不过界。
            ctx_json: format!(
                r#"{{"x":1,"vv":{{"{K1}":4819,"{TAGS}":7}},"cloud":{{"{K1}":[4820,4825]}}}}"#
            ),
            hlc: format!("1792055806043:0:{K1}"),
            server_time: Some(1_792_055_809_512),
        }
    }

    fn edit3(legacy: Option<LegacyStamp>) -> EditBody {
        EditBody {
            kind: EntKind::Note,
            entity: Key::Uuid(id(3)),
            key: format!("f/{}", id(4).text()),
            value: r#""単語""#.into(),
            machine: false,
            ts: 1,
            legacy,
        }
    }

    fn log3() -> LogBody {
        LogBody {
            id: Key::Uuid(id(0x21)),
            card: Key::Uuid(id(0x22)),
            note: None,
            kind: "review".into(),
            rating: Some(3),
            revokes: None,
            at: 1_741_061_848_001,
            ts: 0,
            origin: "anki".into(),
            rtype: "review".into(),
            dur: 6021,
            params: None,
            alg: Some("anki".into()),
            utc_off: 0,
            rollover: 4,
            anki_id: Some(1_741_061_848_001),
            fv: 1,
            intent: Intent::Absolute,
            res: Some(r#"{"dueDay":20155,"queue":"review"}"#.into()),
            extra: r#"{"sc":{"h":"abc","at":5}}"#.into(),
            legacy_hlc: Some("1741061848001:0:anki".into()),
            legacy_server_time: Some(1_741_061_900_000),
        }
    }

    fn twin() -> OpId {
        OpId {
            device: id(0xee),
            seq: 40,
        }
    }

    /// 黄金向量的输入：每种规则各一条，seq 1 起连续。
    fn golden_ops() -> Vec<v3::Op> {
        let entity = v3::Body::Entity {
            kind: EntKind::Note,
            id: Key::Uuid(id(1)),
            data: r#"{"createdAt":1}"#.into(),
        };
        let mut trailing = v3::Body::Edit(edit3(None)).encode();
        trailing.push(0x2a);
        let mut out = vec![
            of_body(1, &entity),
            of_body(2, &v3::Body::Edit(edit3(Some(stamp3())))),
            of_body(3, &v3::Body::Edit(edit3(None))),
            of_body(4, &v3::Body::Log(log3())),
            of_body(
                5,
                &v3::Body::TagAdd {
                    note: Key::Uuid(id(1)),
                    tag: "t".into(),
                },
            ),
            of_body(
                6,
                &v3::Body::Dedup {
                    pairs: vec![(2, twin())],
                },
            ),
            of_body(
                7,
                &v3::Body::MediaAt {
                    location: "loc".into(),
                    flags: v3::MEDIA_AT_PRESENT,
                    names: vec!["a.mp3".into()],
                },
            ),
            // 不认识的种类。
            op3(8, 77, vec![1, 2, 3]),
            // 带尾字节的修改（协议 3 照常应用）。
            op3(9, v3::KIND_EDIT, trailing),
            // 彻底清除的骨架。
            of_body(10, &entity).purge(),
            // 副本骨架：带旧戳的修改。
            of_body(11, &v3::Body::Edit(edit3(Some(stamp3()))))
                .duplicate(twin())
                .unwrap(),
            // 副本骨架：日志（没有旧戳）。
            of_body(12, &v3::Body::Log(log3()))
                .duplicate(twin())
                .unwrap(),
        ];
        // schema 不是 1。
        let mut odd = of_body(13, &entity);
        odd.schema = 2;
        out.push(odd);
        out
    }

    fn chains(ops: &[v3::Op]) -> Vec<Chain> {
        let mut c = CHAIN_ZERO;
        ops.iter()
            .map(|op| {
                c = chain_next(&c, op);
                c
            })
            .collect()
    }

    fn golden_slots() -> Vec<HeritageSlot> {
        let ops = golden_ops();
        ops.iter()
            .zip(chains(&ops))
            .map(|(op, c)| translate(op, &c).unwrap())
            .collect()
    }

    fn tag(s: &HeritageSlot) -> &'static str {
        match s.body {
            SlotBody::Op(_) => "op",
            SlotBody::Raw3(_) => "raw3",
            SlotBody::Alias(_) => "alias",
            SlotBody::Void => "void",
        }
    }

    #[test]
    fn every_rule_lands_in_its_slot_kind() {
        let slots = golden_slots();
        assert_eq!(
            slots.iter().map(tag).collect::<Vec<_>>(),
            [
                "op", "op", "op", "op", "op", "op", "void", "raw3", "raw3", "void", "alias",
                "alias", "raw3"
            ]
        );
        let ops = golden_ops();
        assert_eq!(
            ops.iter().map(raw_reason).collect::<Vec<_>>(),
            [
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                Some(RawReason::UnknownKind),
                Some(RawReason::NotCanonical3),
                None,
                None,
                None,
                Some(RawReason::Schema),
            ]
        );
        // 信封原值、链指纹是原链值的前 8 字节。
        for ((op, c), s) in ops.iter().zip(chains(&ops)).zip(&slots) {
            assert_eq!(s.id, op.id);
            assert_eq!(s.fp[..], c[..8]);
            s.check().unwrap();
            if let SlotBody::Op(o) = &s.body {
                assert_eq!(
                    (o.hlc, &o.deps, o.kind, o.fmt),
                    (op.hlc, &op.deps, op.kind, 4)
                );
            }
        }
        // 带戳的修改：旧戳逐字保留，上下文归一、合成写入者去掉。
        let Some(Body4::Edit(e)) = applied_body(&slots[1]) else {
            panic!()
        };
        let s = e.stamp.unwrap();
        assert_eq!((s.writer.as_str(), s.seq), (K1, 4821));
        assert_eq!(s.hlc.text(), format!("1792055806043:0:{K1}"));
        assert_eq!(s.server_time, Some(1_792_055_809_512));
        assert_eq!(
            s.ctx.to_dvv().to_json().to_string(),
            format!(r#"{{"cloud":{{"{K1}":[4825]}},"vv":{{"{K1}":4820}}}}"#)
        );
        assert!(e.anchored && !e.machine);
        // 日志：配置快照所在的 extra 原文不动，旧 HLC 与服务器时刻保留。
        let Some(Body4::Log(l)) = applied_body(&slots[3]) else {
            panic!()
        };
        assert_eq!(l.extra, r#"{"sc":{"h":"abc","at":5}}"#);
        assert_eq!(l.hlc.unwrap().text(), "1741061848001:0:anki");
        assert_eq!(l.server_time, Some(1_741_061_900_000));
        // 副本记录：原件、种类、HLC、旧戳。
        let SlotBody::Alias(a) = &slots[10].body else {
            panic!()
        };
        assert_eq!(
            (a.kind, a.of, a.wall, a.logical),
            (v3::KIND_EDIT, twin(), 1_800_000_000_011, 2)
        );
        assert_eq!(a.stamp.as_ref(), Some(&s));
        let SlotBody::Alias(a) = &slots[11].body else {
            panic!()
        };
        assert_eq!((a.kind, a.stamp.as_ref()), (v3::KIND_LOG, None));
        // 原样件：整条原样，回得到原操作；协议 3 会应用的给得出操作体，不认识的给不出。
        for i in [7, 8, 12] {
            let SlotBody::Raw3(raw) = &slots[i].body else {
                panic!()
            };
            assert_eq!(raw.to_v3(), ops[i]);
        }
        assert_eq!(applied_body(&slots[7]), None);
        assert_eq!(applied_body(&slots[8]), applied_body(&slots[2]));
        assert!(matches!(
            applied_body(&slots[12]),
            Some(Body4::Entity { .. })
        ));
        // 空洞、副本记录不应用。
        for i in [6, 9, 10, 11] {
            assert_eq!(applied_body(&slots[i]), None);
        }
    }

    /// 转译规则冻结：这些旧操作转出的槽（规范编码）一个字节都不能变。变了 = 改了 [T_VERSION] 1 的含义。
    #[test]
    fn golden_translation() {
        assert_eq!(T_VERSION, 1);
        let slots = golden_slots();
        for (i, s) in slots.iter().enumerate() {
            println!("GOLDEN t_slot_{i} {}", hex(&s.encode()));
        }
        assert_eq!(slots.len(), GOLDEN.len());
        for (s, want) in slots.iter().zip(GOLDEN) {
            assert_eq!(hex(&s.encode()), want);
            assert_eq!(
                &HeritageSlot::read(&mut Reader::new(&unhex(want))).unwrap(),
                s
            );
        }
    }

    const GOLDEN: [&str; 13] = [
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d015636e1033219194c0082c0e285e3680201d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2050104220300010101010101010101010101010101010f7b22637265617465644174223a317d",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d02e4398db58e6e48f30084c0e285e3680201d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2050204610300030303030303030303030303030303030104040404040404040404040404040404060822e58d98e8aa9e220b04000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f01aa4b010fd4250105b6a1cceda768009a36",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d03350806fb5a30ffcd0086c0e285e3680201d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d20502042d0300030303030303030303030303030303030104040404040404040404040404040404020822e58d98e8aa9e22",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d04cc782065afad97460088c0e285e3680201d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2050304830100212121212121212121212121212121210022222222222222222222222222222222f28f04000682effbf5ab6501018a5e04616e6b6982effbf5ab6500217b22647565446179223a32303135352c227175657565223a22726576696577227d197b227363223a7b2268223a22616263222c226174223a357d7d82effbf5ab6500beac06",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d05aec5563ff8067a08008ac0e285e3680201d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d20504041300010101010101010101010101010101010174",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0681db68caad688da3008cc0e285e3680201d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2050d041501eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee01020028",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d077e2d8e5ab721bae103",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d08fb4c5d0065c2a7650190c0e285e3680201d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2054d0103010203",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d091cce0c37bc16822c0192c0e285e3680201d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d20502014503000303030303030303030303030303030326662f30343034303430342d303430342d303430342d303430342d3034303430343034303430340822e58d98e8aa9e2202002a",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0a4277b7144c12a74703",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0b8b49a7f6da2400b90296c0e285e3680202eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee28010b04000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f01aa4b010fd4250105b6a1cceda768009a36",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0c9c5c96993163b5760298c0e285e3680203eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee2800",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d92022db9bc82243e019ac0e285e3680201d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2050102220300010101010101010101010101010101010f7b22637265617465644174223a317d",
    ];

    #[test]
    fn inputs_that_break_protocol_3_invariants_are_refused() {
        let good = of_body(
            1,
            &v3::Body::TagAdd {
                note: Key::of("n"),
                tag: "t".into(),
            },
        );
        assert!(translate(&good, &[1; 32]).is_ok());
        let mut bad = good.clone();
        bad.id.seq = 0;
        assert!(translate(&bad, &[1; 32]).is_err());
        let mut bad = good.clone();
        bad.hlc.device = id(9);
        assert!(translate(&bad, &[1; 32]).is_err());
        let mut bad = good.clone();
        let mut deps = (*bad.deps).clone();
        deps.set(id(OLD), 3);
        bad.deps = Arc::new(deps);
        assert!(translate(&bad, &[1; 32]).is_err());
        let mut bad = good.clone();
        let mut deps = (*bad.deps).clone();
        deps.0.insert(id(7), 0);
        bad.deps = Arc::new(deps);
        assert!(translate(&bad, &[1; 32]).is_err());
    }

    #[test]
    fn media_at_is_a_void_in_every_state() {
        let op = golden_ops()[6].clone();
        let c = [5; 32];
        let void = HeritageSlot::void(op.id, fingerprint(&c));
        assert_eq!(translate(&op, &c).unwrap(), void);
        assert_eq!(translate(&op.purge(), &c).unwrap(), void);
        assert_eq!(translate(&op.duplicate(twin()).unwrap(), &c).unwrap(), void);
        // 载荷解不开的也一样。
        assert_eq!(
            translate(&op3(7, v3::KIND_MEDIA_AT, vec![0xff]), &c).unwrap(),
            void
        );
    }

    #[test]
    fn bodies_protocol_4_cannot_spell_stay_raw_but_still_apply() {
        // 文本引用的内容是规范 UUID 文本：协议 3 当文本读，协议 4 只有 16 字节一种写法。
        let u = "0192f0aa-0000-7000-8000-00000000000b";
        let b = v3::Body::TagAdd {
            note: Key::Text(u.into()),
            tag: "t".into(),
        };
        let op = of_body(1, &b);
        assert_eq!(raw_reason(&op), Some(RawReason::NotCanonical4));
        let slot = translate(&op, &[1; 32]).unwrap();
        assert_eq!(tag(&slot), "raw3");
        assert_eq!(
            applied_body(&slot),
            Some(Body4::TagAdd {
                note: Key::Text(u.into()),
                tag: "t".into()
            })
        );
        // 同一个 seq 出现两次的 Dedup（协议 3 只认第一次）。
        let b = v3::Body::Dedup {
            pairs: vec![(3, twin()), (3, oid(9))],
        };
        let op = of_body(2, &b);
        assert_eq!(raw_reason(&op), Some(RawReason::NotCanonical4));
        assert!(matches!(
            applied_body(&translate(&op, &[1; 32]).unwrap()),
            Some(Body4::Dedup { pairs }) if pairs.len() == 2
        ));
        // 解不开的载荷：协议 3 也不应用。
        let op = op3(3, v3::KIND_EDIT, vec![9, 9]);
        assert_eq!(raw_reason(&op), Some(RawReason::Undecodable));
        assert_eq!(applied_body(&translate(&op, &[1; 32]).unwrap()), None);
        for r in [
            RawReason::Schema,
            RawReason::NotCanonical3,
            RawReason::NotCanonical4,
        ] {
            assert!(r.applied_by_protocol_3());
        }
        assert!(!RawReason::UnknownKind.applied_by_protocol_3());
        assert!(!RawReason::Undecodable.applied_by_protocol_3());
    }

    #[test]
    fn a_complete_slot_and_a_skeleton_converge() {
        let op = of_body(2, &v3::Body::Edit(edit3(Some(stamp3()))));
        let c = [7; 32];
        let full = translate(&op, &c).unwrap();
        let void = translate(&op.purge(), &c).unwrap();
        let alias = translate(&op.duplicate(twin()).unwrap(), &c).unwrap();
        assert_eq!(
            (tag(&full), tag(&void), tag(&alias)),
            ("op", "void", "alias")
        );
        for (a, b, want) in [
            (&full, &void, &void),
            (&full, &alias, &alias),
            (&void, &alias, &alias),
            (&full, &full, &full),
            (&void, &void, &void),
            (&alias, &alias, &alias),
        ] {
            assert_eq!(join_slots(a, b), Joined::One(want.clone()));
            assert_eq!(join_slots(b, a), Joined::One(want.clone()));
        }
        // 两台设备各上传一种，谁先谁后都一样。
        for order in [
            [&full, &void, &alias],
            [&alias, &void, &full],
            [&void, &alias, &full],
        ] {
            let mut set = SlotSet::new();
            for s in order {
                set.insert(s.clone()).unwrap();
            }
            assert_eq!(set.iter().collect::<Vec<_>>(), [&alias]);
        }
    }

    #[test]
    fn a_fork_is_never_swallowed() {
        let op = of_body(2, &v3::Body::Edit(edit3(None)));
        let other = of_body(
            2,
            &v3::Body::TagAdd {
                note: Key::of("n"),
                tag: "t".into(),
            },
        );
        // 同一个操作号、两条不同的链：内容不同的两支，或内容相同但前面的历史不同。
        let a = translate(&op, &[1; 32]).unwrap();
        let b = translate(&other, &[2; 32]).unwrap();
        let c = translate(&op, &[3; 32]).unwrap();
        assert_eq!(join_slots(&a, &b), Joined::Fork);
        assert_eq!(join_slots(&a, &c), Joined::Fork);
        // 一支已经成了空洞也不吞另一支。
        assert_eq!(
            join_slots(&a, &translate(&other.purge(), &[2; 32]).unwrap()),
            Joined::Fork
        );
        let mut set = SlotSet::new();
        for s in [&a, &b, &c, &a] {
            set.insert(s.clone()).unwrap();
        }
        assert_eq!(set.len(), 3);
        assert_eq!(set.forks(), [oid(2)]);
        // 打成两个承袭段再读回，仍是两支。
        let signer = DeviceKey::from_seed(&[7; 32]);
        let mut back = SlotSet::new();
        for s in [&a, &b] {
            let mut last_chain = [0; 32];
            last_chain[..8].copy_from_slice(&s.fp);
            let meta = HeritageMeta {
                collection: id(0xc0),
                source: id(0x5c),
                device: id(OLD),
                uploader: id(0xa1),
                t_version: T_VERSION,
                prev_chain: [0x11; 32],
                last_chain,
            };
            let (_, bytes) = pack_heritage(&meta, std::slice::from_ref(s), &signer, None).unwrap();
            for slot in open_heritage(&bytes, &signer.public(), None).unwrap().1 {
                back.insert(slot).unwrap();
            }
        }
        assert_eq!(back.iter().collect::<Vec<_>>(), [&a, &b]);
        assert_eq!(back.forks(), [oid(2)]);
    }

    #[test]
    fn same_rank_different_content_is_a_conflict() {
        let op = of_body(2, &v3::Body::Edit(edit3(None)));
        let other = of_body(
            2,
            &v3::Body::TagAdd {
                note: Key::of("n"),
                tag: "t".into(),
            },
        );
        let c = [1; 32];
        // 链指纹相同而内容不同的两条完整操作（诚实的设备造不出来）。
        let a = translate(&op, &c).unwrap();
        let b = translate(&other, &c).unwrap();
        assert_eq!(join_slots(&a, &b), Joined::Conflict);
        // 同一条操作被认成两个不同原件的副本。
        let x = translate(&op.duplicate(twin()).unwrap(), &c).unwrap();
        let y = translate(&op.duplicate(oid(9)).unwrap(), &c).unwrap();
        assert_eq!(join_slots(&x, &y), Joined::Conflict);
        let mut set = SlotSet::new();
        set.insert(a.clone()).unwrap();
        assert!(set.insert(b).is_err());
        assert_eq!(set.iter().collect::<Vec<_>>(), [&a], "冲突不改集合");
        // 操作号不同的两个槽没有并。
        assert_eq!(
            join_slots(
                &a,
                &translate(&of_body(3, &v3::Body::Edit(edit3(None))), &c).unwrap()
            ),
            Joined::Conflict
        );
    }

    #[test]
    fn translated_slots_pack_into_a_heritage_segment() {
        let ops = golden_ops();
        let cs = chains(&ops);
        let slots = golden_slots();
        let signer = DeviceKey::from_seed(&[7; 32]);
        let meta = HeritageMeta {
            collection: id(0xc0),
            source: id(0x5c),
            device: id(OLD),
            uploader: id(0xa1),
            t_version: T_VERSION,
            prev_chain: CHAIN_ZERO,
            last_chain: *cs.last().unwrap(),
        };
        let (header, bytes) = pack_heritage(&meta, &slots, &signer, None).unwrap();
        assert_eq!((header.first, header.last, header.t_version), (1, 13, 1));
        assert_eq!(
            open_heritage(&bytes, &signer.public(), None).unwrap().1,
            slots
        );
    }

    // ------------------------------------------------------------ 协议 3 的段

    #[test]
    fn a_protocol_3_segment_translates_like_its_ops() {
        use crate::sync2::segment as seg3;
        let ops: Vec<v3::Op> = golden_ops();
        let cs = chains(&ops);
        let signer = DeviceKey::from_seed(&[7; 32]);
        let (_, bytes) = seg3::pack(id(0xc0), &ops, CHAIN_ZERO, &signer, None).unwrap();
        let mut got = Vec::new();
        let header = translate_segment(&bytes, &signer.public(), None, |s| {
            got.push(s);
            Ok(())
        })
        .unwrap();
        assert_eq!((header.first, header.last), (1, 13));
        assert_eq!(got, golden_slots());
        assert_eq!(got.last().unwrap().fp[..], cs.last().unwrap()[..8]);
        // 签名不对的段不转。
        let other = DeviceKey::from_seed(&[8; 32]);
        assert!(translate_segment(&bytes, &other.public(), None, |_| Ok(())).is_err());
    }

    // ------------------------------------------------------------ 性质

    fn arb_key() -> impl Strategy<Value = Key> {
        prop_oneof![
            proptest::array::uniform16(any::<u8>()).prop_map(|b| Key::Uuid(Id(b))),
            "[a-z/]{0,8}".prop_map(|s| Key::of(&s)),
            // 协议 4 写不出的形：内容是规范 UUID 文本的文本引用。
            proptest::array::uniform16(any::<u8>()).prop_map(|b| Key::Text(Id(b).text())),
        ]
    }

    fn arb_writer() -> impl Strategy<Value = String> {
        prop_oneof![
            Just(K1.to_owned()),
            Just("anki".to_owned()),
            Just(TAGS.to_owned()),
            Just("merged-862ab679-9805-548b-9454-d3ec51c44e9c".to_owned()),
            "[a-c:#~-]{0,5}",
        ]
    }

    /// 旧上下文的 JSON **文本**：正常的、带浮点 / 超界 / 负数 / 重复键 / 类型不对的、根本不是 JSON 的。
    pub fn arb_ctx_text() -> impl Strategy<Value = String> {
        let num = prop_oneof![
            (-3i64..60).prop_map(|n| n.to_string()),
            Just("1.5".to_owned()),
            Just("3.0".to_owned()),
            Just("9223372036854775808".to_owned()),
            Just("\"4\"".to_owned()),
            Just("null".to_owned()),
        ];
        let entry =
            (arb_writer(), num.clone()).prop_map(|(w, n)| format!("{}:{n}", serde_json::json!(w)));
        let cloud = (
            arb_writer(),
            proptest::collection::vec(num, 0..4),
            any::<bool>(),
        )
            .prop_map(|(w, xs, arr)| {
                if arr {
                    format!("{}:[{}]", serde_json::json!(w), xs.join(","))
                } else {
                    format!("{}:7", serde_json::json!(w))
                }
            });
        prop_oneof![
            8 => (proptest::collection::vec(entry, 0..4), proptest::collection::vec(cloud, 0..3), any::<bool>())
                .prop_map(|(vv, cloud, extra)| format!(
                    r#"{{"vv":{{{}}},"cloud":{{{}}}{}}}"#,
                    vv.join(","),
                    cloud.join(","),
                    if extra { r#","x":[1]"# } else { "" }
                )),
            1 => Just("{}".to_owned()),
            1 => Just(r#"{"vv":[1],"cloud":3}"#.to_owned()),
            1 => Just("[]".to_owned()),
            1 => "[a-z{\\[\"]{0,6}",
        ]
    }

    fn arb_hlc_text() -> impl Strategy<Value = String> {
        prop_oneof![
            4 => (any::<i64>(), 0i64..9, arb_writer()).prop_map(|(p, c, w)| format!("{p}:{c}:{w}")),
            1 => Just("+5:0:w".to_owned()),
            1 => Just("05:00:w".to_owned()),
            1 => "[a-z0-9:]{0,8}",
        ]
    }

    fn arb_legacy() -> impl Strategy<Value = LegacyStamp> {
        (
            arb_writer(),
            any::<i64>(),
            arb_ctx_text(),
            arb_hlc_text(),
            proptest::option::of(any::<i64>()),
        )
            .prop_map(|(writer, seq, ctx_json, hlc, server_time)| LegacyStamp {
                writer,
                seq,
                ctx_json,
                hlc,
                server_time,
            })
    }

    fn arb_log3() -> impl Strategy<Value = LogBody> {
        (
            (
                arb_key(),
                arb_key(),
                proptest::option::of(arb_key()),
                proptest::option::of(arb_key()),
            ),
            (
                prop_oneof![
                    Just("review".to_owned()),
                    Just("undo".to_owned()),
                    "[a-z]{0,5}"
                ],
                proptest::option::of(0i64..255),
                any::<i64>(),
                any::<u8>(),
                prop_oneof![
                    Just("fushi".to_owned()),
                    Just("anki".to_owned()),
                    "[a-z]{0,3}"
                ],
                prop_oneof![Just("review".to_owned()), "[a-z]{0,4}"],
            ),
            (
                prop_oneof![Just(0i64), any::<i64>()],
                proptest::option::of("[a-z0-9:]{0,8}"),
                proptest::option::of("[a-z0-9]{0,5}"),
                prop_oneof![Just(0i64), any::<i64>()],
                prop_oneof![Just(4i64), any::<i64>()],
                proptest::option::of(any::<i64>()),
                prop_oneof![Just(1i64), any::<i64>()],
            ),
            (
                prop_oneof![
                    Just(Intent::Absolute),
                    Just(Intent::Answer),
                    any::<i64>().prop_map(|due_day| Intent::SetDue { due_day }),
                    Just(Intent::Reset),
                    Just(Intent::Reschedule),
                    any::<bool>().prop_map(|to_anki| Intent::HandOff { to_anki }),
                ],
                proptest::option::of("\\{[a-z\":0-9,]{0,12}\\}"),
                prop_oneof![Just("{}".to_owned()), "\\{[a-z\":0-9,]{1,12}\\}"],
                proptest::option::of(arb_hlc_text()),
                proptest::option::of(any::<i64>()),
            ),
        )
            .prop_map(
                |(
                    (id, card, note, revokes),
                    (kind, rating, at, ts, origin, rtype),
                    (dur, params, alg, utc_off, rollover, anki_id, fv),
                    (intent, res, extra, legacy_hlc, legacy_server_time),
                )| LogBody {
                    id,
                    card,
                    note,
                    kind,
                    rating,
                    revokes,
                    at,
                    ts,
                    origin,
                    rtype,
                    dur,
                    params,
                    alg,
                    utc_off,
                    rollover,
                    anki_id,
                    fv,
                    intent,
                    res,
                    extra,
                    legacy_hlc,
                    legacy_server_time,
                },
            )
    }

    fn arb_body3() -> impl Strategy<Value = v3::Body> {
        let ent = proptest::sample::select(&EntKind::ALL[..]);
        prop_oneof![
            1 => (ent.clone(), arb_key(), ".{0,12}").prop_map(|(kind, id, data)| v3::Body::Entity { kind, id, data }),
            4 => (
                ent.clone(),
                arb_key(),
                prop_oneof![
                    "[a-zA-Z/]{0,10}",
                    proptest::array::uniform16(any::<u8>()).prop_map(|b| format!("f/{}", Id(b).text())),
                ],
                ".{0,12}",
                any::<bool>(),
                0u8..2,
                proptest::option::of(arb_legacy()),
            )
                .prop_map(|(kind, entity, key, value, machine, ts, legacy)| {
                    v3::Body::Edit(EditBody { kind, entity, key, value, machine, ts, legacy })
                }),
            4 => arb_log3().prop_map(v3::Body::Log),
            1 => (arb_key(), "[a-z]{0,4}").prop_map(|(note, tag)| v3::Body::TagAdd { note, tag }),
            1 => (arb_key(), "[a-z]{0,4}").prop_map(|(note, tag)| v3::Body::TagRemove { note, tag }),
            1 => (arb_key(), proptest::collection::vec("[a-z]{0,3}", 0..4))
                .prop_map(|(note, tags)| v3::Body::TagOrder { note, tags }),
            1 => ("[a-z]{0,4}", "[a-z]{0,4}").prop_map(|(name, reason)| v3::Body::Checkpoint { name, reason }),
            1 => (ent, arb_key()).prop_map(|(kind, entity)| v3::Body::Purge { kind, entity }),
            1 => ("[a-z.]{0,6}", any::<[u8; 32]>(), any::<u64>())
                .prop_map(|(name, sha256, size)| v3::Body::Media { name, sha256, size }),
            1 => ("[a-z]{0,4}", 0u8..8, proptest::collection::vec("[a-z.]{0,5}", 0..3))
                .prop_map(|(location, flags, names)| v3::Body::MediaAt { location, flags, names }),
            1 => (arb_key(), arb_key()).prop_map(|(from, to)| v3::Body::DeckAlias { from, to }),
            1 => ".{0,10}".prop_map(|json| v3::Body::LegacyUnknown { json }),
            // 作者 seq 不降（协议 3 的编码是增量）；可以重复、可以从 0 起。
            1 => proptest::collection::vec((0u64..3, 0u8..3, 0u64..50), 0..5).prop_map(|xs| {
                let mut own = 0;
                v3::Body::Dedup {
                    pairs: xs
                        .into_iter()
                        .map(|(d, dev, seq)| {
                            own += d;
                            (own, OpId { device: id(0xe0 + dev), seq })
                        })
                        .collect(),
                }
            }),
        ]
    }

    /// 任意一条未清除的旧操作：正常的、`schema` 不是 1 的、带尾字节的、不认识种类的、载荷是乱字节的。
    pub fn arb_op3() -> impl Strategy<Value = v3::Op> {
        prop_oneof![
            6 => (1u64..50, arb_body3()).prop_map(|(seq, b)| of_body(seq, &b)),
            1 => (1u64..50, arb_body3(), 2u16..6).prop_map(|(seq, b, schema)| v3::Op {
                schema,
                ..of_body(seq, &b)
            }),
            1 => (1u64..50, arb_body3(), proptest::collection::vec(any::<u8>(), 1..4)).prop_map(|(seq, b, tail)| {
                let mut p = b.encode();
                p.extend(tail);
                op3(seq, b.kind(), p)
            }),
            1 => (1u64..50, 14u16..300, proptest::collection::vec(any::<u8>(), 0..12))
                .prop_map(|(seq, kind, p)| op3(seq, kind, p)),
            1 => (1u64..50, 1u16..14, proptest::collection::vec(any::<u8>(), 0..24))
                .prop_map(|(seq, kind, p)| op3(seq, kind, p)),
        ]
    }

    /// 旧上下文的参照读法：现有的 `Dvv` 解析 + 去掉合成写入者（投影路径做的就是这个）。
    fn ctx_reference(text: &str) -> Dvv {
        let mut d = Dvv::parse(text);
        d.drop_writers(crate::gen4::stamp::SYNTHETIC_PREFIX);
        d
    }

    /// 把上下文原文换成参照读法的规范 JSON（比较语义用）。
    fn canon_legacy(l: &LegacyStamp) -> LegacyStamp {
        LegacyStamp {
            ctx_json: ctx_reference(&l.ctx_json).to_json().to_string(),
            ..l.clone()
        }
    }

    fn legacy_of(s: &HeritageStamp) -> LegacyStamp {
        LegacyStamp {
            writer: s.writer.clone(),
            seq: s.seq,
            ctx_json: s.ctx.to_dvv().to_json().to_string(),
            hlc: s.hlc.text(),
            server_time: s.server_time,
        }
    }

    /// 协议 4 的操作体 → 协议 3 的值（转译的逆；旧戳的上下文给规范 JSON）。
    fn back(b: Body4) -> v3::Body {
        match b {
            Body4::Entity { kind, id, data } => v3::Body::Entity { kind, id, data },
            Body4::Edit(e) => v3::Body::Edit(EditBody {
                kind: e.kind,
                entity: e.entity,
                key: e.key,
                value: e.value,
                machine: e.machine,
                ts: u8::from(e.anchored),
                legacy: e.stamp.as_ref().map(legacy_of),
            }),
            Body4::Log(l) => v3::Body::Log(LogBody {
                id: l.id,
                card: l.card,
                note: l.note,
                kind: l.kind,
                rating: l.rating,
                revokes: l.revokes,
                at: l.at,
                ts: l.ts,
                origin: l.origin,
                rtype: l.rtype,
                dur: l.dur,
                params: l.params,
                alg: l.alg,
                utc_off: l.utc_off,
                rollover: l.rollover,
                anki_id: l.anki_id,
                fv: l.fv,
                intent: l.intent,
                res: l.res,
                extra: l.extra,
                legacy_hlc: l.hlc.as_ref().map(StampHlc::text),
                legacy_server_time: l.server_time,
            }),
            Body4::TagAdd { note, tag } => v3::Body::TagAdd { note, tag },
            Body4::TagRemove { note, tag } => v3::Body::TagRemove { note, tag },
            Body4::TagOrder { note, tags } => v3::Body::TagOrder { note, tags },
            Body4::Checkpoint { name, reason } => v3::Body::Checkpoint { name, reason },
            Body4::Purge { kind, entity } => v3::Body::Purge { kind, entity },
            Body4::Media { name, sha256, size } => v3::Body::Media { name, sha256, size },
            Body4::DeckAlias { from, to } => v3::Body::DeckAlias { from, to },
            Body4::LegacyUnknown { json } => v3::Body::LegacyUnknown { json },
            Body4::Dedup { pairs } => v3::Body::Dedup { pairs },
            Body4::Join(_) | Body4::Unknown => v3::Body::Unknown,
        }
    }

    /// 协议 3 会怎么读一条未清除的操作（参照）：解得开、种类认识、不是 MediaAt 的才应用；旧戳的上下文取参照读法。
    fn applied_by_3(op: &v3::Op) -> Option<v3::Body> {
        match v3::Body::decode(op.kind, &op.payload).ok()? {
            v3::Body::Unknown | v3::Body::MediaAt { .. } => None,
            v3::Body::Edit(e) => Some(v3::Body::Edit(EditBody {
                legacy: e.legacy.as_ref().map(canon_legacy),
                ..e
            })),
            b => Some(b),
        }
    }

    proptest! {
        /// 逐条确定、有输出、输出是规范字节。
        #[test]
        fn translation_is_total_deterministic_and_canonical(op in arb_op3(), chain in any::<[u8; 32]>(), state in 0u8..3) {
            let op = match state {
                1 => op.purge(),
                2 => op.duplicate(twin()).unwrap_or(op),
                _ => op,
            };
            let slot = translate(&op, &chain).unwrap();
            prop_assert_eq!(&translate(&op.clone(), &chain).unwrap(), &slot);
            slot.check().unwrap();
            let bytes = slot.encode();
            let mut r = Reader::new(&bytes);
            prop_assert_eq!(&HeritageSlot::read(&mut r).unwrap(), &slot);
            prop_assert!(r.is_empty());
            prop_assert_eq!((slot.id, &slot.fp[..]), (op.id, &chain[..8]));
        }

        /// 判定不变的根据：派生层从槽里读到的值，与协议 3 从原操作里读到的值相同——每个字段逐字相同，旧戳的上下文
        /// 与现有读法（`Dvv` 解析 + 去合成写入者）给出同一个 dotted version vector（于是对一切 dot「含不含」都相同）。
        #[test]
        fn a_slot_applies_exactly_what_protocol_3_applied(op in arb_op3(), chain in any::<[u8; 32]>()) {
            let slot = translate(&op, &chain).unwrap();
            prop_assert_eq!(applied_body(&slot).map(back), applied_by_3(&op));
            // 转成了操作的：载荷是协议 4 的规范字节；成了原样件的：整条回得到原操作。
            match &slot.body {
                SlotBody::Op(o) => {
                    prop_assert_eq!(o.fmt, BODY_FMT);
                    let b = o.body().unwrap();
                    prop_assert_eq!(&b.encode()[..], &o.payload[..]);
                    prop_assert_eq!(raw_reason(&op), None);
                }
                SlotBody::Raw3(raw) => {
                    prop_assert_eq!(&raw.to_v3(), &op);
                    prop_assert!(raw_reason(&op).is_some());
                    prop_assert_eq!(raw_reason(&op).unwrap().applied_by_protocol_3(), applied_by_3(&op).is_some());
                }
                SlotBody::Void => prop_assert_eq!(op.kind, v3::KIND_MEDIA_AT),
                SlotBody::Alias(_) => prop_assert!(false, "an unpurged op became an alias"),
            }
        }

        /// 规范的旧操作（协议 3 自己的写者写得出的）一律转成操作，不落进原样件。
        #[test]
        fn canonical_protocol_3_ops_become_ops(seq in 1u64..50, b in arb_body3()) {
            let op = of_body(seq, &b);
            // 协议 3 的写者一律经 `Key::of` 造引用、Dedup 的作者 seq 严格升序：只留这样的输入。
            let canonical4 = Body4::decode(op.kind, BODY_FMT, &carry(b.clone()).map(|x| x.encode()).unwrap_or_default())
                .ok()
                .zip(carry(b.clone()))
                .is_some_and(|(x, y)| x == y);
            prop_assume!(canonical4);
            let slot = translate(&op, &[3; 32]).unwrap();
            prop_assert!(matches!(slot.body, SlotBody::Op(_)));
        }

        /// 本机施加清除 / 认副本，与协议 3 对那条操作做的事逐条对应。
        #[test]
        fn local_purge_and_dedup_match_protocol_3(op in arb_op3(), chain in any::<[u8; 32]>(), of_seq in 0u64..9) {
            let of = OpId { device: id(0xee), seq: of_seq };
            let slot = translate(&op, &chain).unwrap();
            prop_assert_eq!(purge_slot(&slot), translate(&op.purge(), &chain).unwrap());
            if op.kind != v3::KIND_MEDIA_AT {
                let want = op.duplicate(of).ok().map(|d| translate(&d, &chain).unwrap());
                prop_assert_eq!(dedup_slot(&slot, of).ok(), want);
            }
            // 已经是骨架的：两边都不动（协议 3 的 `purge` / `duplicate` 对骨架原样返回）。
            for sk in [Some(op.purge()), op.duplicate(of).ok()].into_iter().flatten() {
                let s = translate(&sk, &chain).unwrap();
                prop_assert_eq!(&purge_slot(&s), &translate(&sk.purge(), &chain).unwrap());
                prop_assert_eq!(&purge_slot(&s), &s);
                prop_assert_eq!(&dedup_slot(&s, twin()).unwrap(), &translate(&sk.duplicate(twin()).unwrap(), &chain).unwrap());
                prop_assert_eq!(&dedup_slot(&s, twin()).unwrap(), &s);
            }
        }

        /// 槽的并：交换、结合、幂等；取的是靠后的状态。两台设备各持同一段历史的一部分、各处于不同状态，
        /// 各自转译再并 == 先把状态并起来再转译。
        #[test]
        fn the_union_of_translations_is_the_translation_of_the_union(
            ops in proptest::collection::vec(arb_op3(), 1..6),
            // 每台设备对每条操作：0 没有、1 完整、2 清除骨架、3 副本骨架。
            states in proptest::collection::vec(proptest::collection::vec(0u8..4, 6), 3),
        ) {
            // 同一台旧设备的一段日志：seq 1 起连续。
            let ops: Vec<v3::Op> = ops.into_iter().enumerate().map(|(i, mut op)| { op.id.seq = i as u64 + 1; op }).collect();
            let cs = chains(&ops);
            let in_state = |op: &v3::Op, st: u8| -> Option<v3::Op> {
                match st {
                    0 => None,
                    1 => Some(op.clone()),
                    2 => Some(op.purge()),
                    // 认不了副本的（载荷解不开）留完整。
                    _ => Some(op.duplicate(twin()).unwrap_or_else(|_| op.clone())),
                }
            };
            // 协议 3 一侧的并：每条操作取靠后的状态（完整 < 清除骨架 < 副本骨架）。
            let later = |a: Option<v3::Op>, b: Option<v3::Op>| -> Option<v3::Op> {
                let rank = |o: &v3::Op| match (o.purged, o.payload.len()) { (false, _) => 0, (true, 32) => 1, (true, _) => 2 };
                match (a, b) {
                    (Some(a), Some(b)) => Some(if rank(&b) > rank(&a) { b } else { a }),
                    (a, b) => a.or(b),
                }
            };
            let device = |d: usize| -> Vec<Option<v3::Op>> {
                ops.iter().enumerate().map(|(i, op)| in_state(op, states[d][i])).collect()
            };
            let set_of = |held: &[Option<v3::Op>]| -> SlotSet {
                let mut set = SlotSet::new();
                for (o, c) in held.iter().zip(&cs) {
                    if let Some(o) = o {
                        set.insert(translate(o, c).unwrap()).unwrap();
                    }
                }
                set
            };
            let (a, b, c) = (device(0), device(1), device(2));
            let (sa, sb, sc) = (set_of(&a), set_of(&b), set_of(&c));
            let union = |x: &SlotSet, y: &SlotSet| { let mut out = x.clone(); out.merge(y).unwrap(); out };
            // T(S1) ∪ T(S2) = T(S1 ∪ S2)
            let ab: Vec<Option<v3::Op>> = a.iter().cloned().zip(b.iter().cloned()).map(|(x, y)| later(x, y)).collect();
            prop_assert_eq!(&union(&sa, &sb), &set_of(&ab));
            // 交换、结合、幂等。
            prop_assert_eq!(&union(&sa, &sb), &union(&sb, &sa));
            prop_assert_eq!(&union(&union(&sa, &sb), &sc), &union(&sa, &union(&sb, &sc)));
            prop_assert_eq!(&union(&sa, &sa), &sa);
        }

        /// 旧上下文：从 JSON 原文直接读出的规范形，与现有读法逐项相同（任何文本，包括坏的）。
        #[test]
        fn stamp_ctx_reads_any_text_like_the_existing_reader(text in arb_ctx_text()) {
            let c = StampCtx::parse(&text);
            prop_assert_eq!(c.to_dvv(), ctx_reference(&text));
            // 规范形能进紧凑旧戳并原样读回。
            let s = HeritageStamp { writer: "w".into(), seq: 1, ctx: c, hlc: StampHlc::of("1:0:w"), server_time: None };
            let bytes = s.encode();
            prop_assert_eq!(HeritageStamp::read(&mut Reader::new(&bytes)).unwrap(), s);
        }

        /// 判定与现在逐条相同：同一批旧修改，分别用原旧戳、和「旧戳转成紧凑形再还原」的旧戳落成投影行，
        /// 现有的寄存器裁决（未被支配者、胜者、是否冲突、可见败者、与删除并发的修改）逐项相同。
        #[test]
        fn registers_judge_translated_stamps_the_same(
            edits in proptest::collection::vec(
                (0usize..3, 1i64..9, arb_ctx_text(), 0i64..5, 0i64..3, 0usize..3, proptest::option::of(0i64..6), 0usize..3, any::<bool>()),
                1..7,
            ),
        ) {
            const WRITERS: [&str; 3] = [K1, "anki", "merged-862ab679-9805-548b-9454-d3ec51c44e9c"];
            const KEYS: [&str; 3] = ["f/a", "deleted", "f/b"];
            let mut seen = std::collections::BTreeSet::new();
            let mut original = Vec::new();
            let mut restored = Vec::new();
            let mut times = Vec::new();
            for (w, seq, ctx_text, physical, counter, hw, server_time, key, del) in edits {
                if !seen.insert((w, seq)) {
                    continue;
                }
                let l = LegacyStamp {
                    writer: WRITERS[w].into(),
                    seq,
                    ctx_json: ctx_text,
                    hlc: format!("{physical}:{counter}:{}", WRITERS[hw]),
                    server_time,
                };
                let l2 = legacy_of(&stamp_of(&l));
                prop_assert_eq!((&l2.writer, l2.seq, &l2.hlc, l2.server_time), (&l.writer, l.seq, &l.hlc, l.server_time));
                // 投影行的形状与 store/sync2/mod.rs `edit_row_with` 相同：上下文解不开当 {"vv":{}}，合成写入者去掉。
                let row = |l: &LegacyStamp| {
                    let ctx = serde_json::from_str::<serde_json::Value>(&l.ctx_json).unwrap_or(serde_json::json!({"vv": {}}));
                    let ctx = crate::store::sync2::strip_synthetic_ctx(&ctx).unwrap_or(ctx);
                    let v = if KEYS[key] == "deleted" { serde_json::json!(del) } else { serde_json::json!("x") };
                    serde_json::json!({"p": "p", "k": "note", "e": "n1", "f": KEYS[key], "w": l.writer, "s": l.seq,
                                       "ctx": ctx, "hlc": l.hlc, "v": v, "ts": "wall"}).to_string()
                };
                original.push(row(&l));
                restored.push(row(&l2));
                times.push(server_time);
            }
            let stored = |rows: &[String]| -> Vec<(String, Option<i64>)> {
                rows.iter().cloned().zip(times.iter().copied()).collect()
            };
            let report = |rows: &[(String, Option<i64>)]| {
                let refs: Vec<crate::registers::StoredEdit<'_>> = rows.iter().map(|(j, t)| (j.as_str(), *t, None)).collect();
                crate::registers::registers_report(&refs).unwrap()
            };
            prop_assert_eq!(report(&stored(&original)), report(&stored(&restored)));
        }
    }
}
