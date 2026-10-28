//! 操作（设计 §3.3）：信封 + 种类 + 原始载荷字节。
//!
//! - 信封：`OpId`、HLC、因果上下文（作者创建这条操作时已应用的版本向量；本设备分量隐含为 seq − 1）、
//!   `kind`、`schema`。
//! - 载荷原样保存为字节（[Op::payload]）：不认识的 kind 原样保存、原样转发；认识的 kind 若带着更新
//!   版本追加的字段，解码只读已知前缀，转发时仍是原字节（哈希链、签名、去重都不受影响）。
//! - 种类的语义见各 `Body` 变体。卡片的调度状态**不在任何操作里**：复习只是事实，状态由重放推出
//!   （replay.rs）；`Log` 里只有「这次操作想做什么」（[Intent]），导入锚点 / 恢复照抄这类外部给定的
//!   绝对状态才带结果。

use std::sync::Arc;

use super::codec::{DResult, DecodeError, Reader, Writer};
use super::hlc::Hlc;
use super::id::{Id, Key};
use super::vv::{OpId, Vv};

pub const KIND_ENTITY: u16 = 1;
pub const KIND_EDIT: u16 = 2;
pub const KIND_LOG: u16 = 3;
pub const KIND_TAG_ADD: u16 = 4;
pub const KIND_TAG_REMOVE: u16 = 5;
pub const KIND_CHECKPOINT: u16 = 6;
pub const KIND_PURGE: u16 = 7;
pub const KIND_MEDIA: u16 = 8;
pub const KIND_DECK_ALIAS: u16 = 9;
pub const KIND_LEGACY_UNKNOWN: u16 = 10;
pub const KIND_TAG_ORDER: u16 = 11;
pub const KIND_MEDIA_AT: u16 = 12;

/// [Body::MediaAt] 的标志位：这批名字此刻**在**该位置（否则 = 确认不在）。
pub const MEDIA_AT_PRESENT: u8 = 1;
/// [Body::MediaAt] 的标志位：作者刚对该位置做完一次完整列举，这批（及同一作者此前带同一列举的各批）是
/// 当时的全集。见过它的设备不再为这个位置列目录。
pub const MEDIA_AT_SEEDED: u8 = 2;

/// 一条 [Body::MediaAt] 最多带多少个名字（首次列举出几万个媒体时按此切成多条，单条载荷有界）。
pub const MEDIA_AT_MAX_NAMES: usize = 2000;

/// 本版本写出的载荷格式号。
pub const SCHEMA: u16 = 1;

/// 一条操作。克隆是廉价的（载荷与上下文共享）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Op {
    pub id: OpId,
    pub hlc: Hlc,
    /// 作者已应用的**其它设备**的版本向量；作者自己的分量隐含为 `id.seq - 1`。
    pub deps: Arc<Vv>,
    pub kind: u16,
    pub schema: u16,
    /// 载荷原字节；[Op::purged] 时是原载荷的 BLAKE3（32 字节）。
    pub payload: Arc<[u8]>,
    /// 内容已被「彻底清除」（设计 §10.5）：只剩骨架（信封 + 原载荷哈希），链值不变。
    pub purged: bool,
}

impl Op {
    /// 原载荷的 BLAKE3（哈希链按它算，所以清除载荷不影响链与签名的可验证性）。
    pub fn payload_hash(&self) -> [u8; 32] {
        if self.purged {
            self.payload[..].try_into().unwrap_or([0; 32])
        } else {
            *blake3::hash(&self.payload).as_bytes()
        }
    }

    /// 清除后的骨架。
    pub fn purge(&self) -> Op {
        if self.purged {
            return self.clone();
        }
        Op { payload: self.payload_hash().to_vec().into(), purged: true, ..self.clone() }
    }

    /// 信封（不含载荷）的规范编码：链值 = blake3(前一环 || 信封 || 载荷哈希)。
    pub fn envelope(&self) -> Vec<u8> {
        let mut w = Writer::new();
        self.id.device.write(&mut w);
        w.uv(self.id.seq);
        self.hlc.write_time(&mut w);
        self.deps.write(&mut w);
        w.uv(u64::from(self.kind));
        w.uv(u64::from(self.schema));
        w.into_vec()
    }

    /// 作者创建这条操作时见过 [other]（因果上在它之后）。
    pub fn saw(&self, other: &OpId) -> bool {
        if other.device == self.id.device {
            other.seq < self.id.seq
        } else {
            self.deps.contains(other)
        }
    }

    /// 完整上下文（含本设备分量）。
    pub fn ctx(&self) -> Vv {
        let mut v = (*self.deps).clone();
        v.set(self.id.device, self.id.seq - 1);
        v
    }

    pub fn body(&self) -> DResult<Body> {
        if self.purged {
            return Ok(Body::Purged);
        }
        Body::decode(self.kind, &self.payload)
    }

    /// 独立编码（快照、FFI、测试用；段里用 [super::segment] 的增量编码）。
    pub fn write(&self, w: &mut Writer) {
        self.id.device.write(w);
        w.uv(self.id.seq);
        self.hlc.write_time(w);
        self.deps.write(w);
        w.uv(u64::from(self.kind));
        w.uv(u64::from(self.schema));
        w.bool(self.purged);
        w.bytes(&self.payload);
    }

    pub fn read(r: &mut Reader<'_>) -> DResult<Op> {
        let device = Id::read(r)?;
        let seq = r.uv()?;
        if seq == 0 {
            return Err(DecodeError("op seq 0"));
        }
        let hlc = Hlc::read_time(r, device)?;
        let deps = Vv::read(r)?;
        if deps.get(&device) != 0 {
            return Err(DecodeError("op deps name its own device"));
        }
        let kind = u16::try_from(r.uv()?).map_err(|_| DecodeError("op kind"))?;
        let schema = u16::try_from(r.uv()?).map_err(|_| DecodeError("op schema"))?;
        let purged = r.bool()?;
        let payload: Arc<[u8]> = r.bytes()?.into();
        if purged && payload.len() != 32 {
            return Err(DecodeError("purged op without payload hash"));
        }
        Ok(Op { id: OpId { device, seq }, hlc, deps: Arc::new(deps), kind, schema, payload, purged })
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        self.write(&mut w);
        w.into_vec()
    }
}

/// 实体种类（持久化名冻结，与 Dart `SrsEntityKind.wire` 一一对应）。
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub enum EntKind {
    Profile = 0,
    Deck = 1,
    NoteType = 2,
    Note = 3,
    Card = 4,
}

impl EntKind {
    pub const ALL: [EntKind; 5] = [EntKind::Profile, EntKind::Deck, EntKind::NoteType, EntKind::Note, EntKind::Card];

    pub fn wire(self) -> &'static str {
        match self {
            EntKind::Profile => "profile",
            EntKind::Deck => "deck",
            EntKind::NoteType => "notetype",
            EntKind::Note => "note",
            EntKind::Card => "card",
        }
    }

    pub fn parse(s: &str) -> Option<EntKind> {
        EntKind::ALL.into_iter().find(|k| k.wire() == s)
    }

    fn from_code(c: u8) -> DResult<EntKind> {
        EntKind::ALL.get(c as usize).copied().ok_or(DecodeError("entity kind"))
    }
}

/// 时间来源（Dart `SrsTimeSource`）。
pub fn ts_code(wire: &str) -> u8 {
    u8::from(wire == "anchored")
}

pub fn ts_wire(code: u8) -> &'static str {
    if code == 1 { "anchored" } else { "wall" }
}

/// 迁移进来的旧修改记录的原始戳（旧协议的 dot / 因果上下文 / HLC），因果判定与投影都要用。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LegacyStamp {
    pub writer: String,
    pub seq: i64,
    /// 旧 dotted version vector 的 JSON 原文（`{"vv":{..},"cloud":{..}}`）。
    pub ctx_json: String,
    /// 旧 HLC 文本（`physical:counter:writer`）。
    pub hlc: String,
    /// 旧协议的服务器时刻 S(e)（排序钳位用；未知 = None）。
    pub server_time: Option<i64>,
}

impl LegacyStamp {
    fn write(&self, w: &mut Writer) {
        w.str(&self.writer);
        w.iv(self.seq);
        w.str(&self.ctx_json);
        w.str(&self.hlc);
        w.opt_iv(self.server_time);
    }

    fn read(r: &mut Reader<'_>) -> DResult<LegacyStamp> {
        Ok(LegacyStamp {
            writer: r.str()?.to_owned(),
            seq: r.iv()?,
            ctx_json: r.str()?.to_owned(),
            hlc: r.str()?.to_owned(),
            server_time: r.opt_iv()?,
        })
    }
}

/// 一次可编辑字段的写入（笔记字段、标志、牌组设置……与 Dart `SrsFieldEdit` 同一套键）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditBody {
    pub kind: EntKind,
    pub entity: Key,
    pub key: String,
    /// 规范 JSON 文本（`null` 合法，例如 `deleted = null` 表示恢复）。
    pub value: String,
    pub machine: bool,
    pub ts: u8,
    pub legacy: Option<LegacyStamp>,
}

/// 复习日志在重放里要做的事。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Intent {
    /// 结果由操作给定、不重算（导入锚点、恢复照抄、不认识的种类、undo 没有结果）。
    Absolute,
    /// 评分：按重放到这里时的状态与当前牌组配置算。
    Answer,
    /// 手动改到期日。
    SetDue { due_day: i64 },
    /// 设为新卡。
    Reset,
    /// 按当前参数重算到期（「立即重排」）。
    Reschedule,
    /// 排程归属改到 anki（true）或收回 fushi（false）。
    HandOff { to_anki: bool },
}

/// 复习日志（Dart `SrsReviewLog` 的字段，去掉了可推导的结果）。
#[derive(Clone, Debug, PartialEq)]
pub struct LogBody {
    pub id: Key,
    pub card: Key,
    /// 卡所属的笔记（重放要按它找牌组配置；卡片行是派生的，收到的设备可能还没物化出这张卡）。
    pub note: Option<Key>,
    pub kind: String,
    pub rating: Option<i64>,
    pub revokes: Option<Key>,
    pub at: i64,
    pub ts: u8,
    pub origin: String,
    pub rtype: String,
    pub dur: i64,
    pub params: Option<String>,
    pub alg: Option<String>,
    pub utc_off: i64,
    pub rollover: i64,
    pub anki_id: Option<i64>,
    pub fv: i64,
    pub intent: Intent,
    /// [Intent::Absolute] 的结果 JSON 原文（没有 = 不带结果）。
    pub res: Option<String>,
    /// 不认识的键（JSON 对象原文，`{}` = 没有）。
    pub extra: String,
    /// 作者给日志的 HLC 文本（排序键；投影行原样带回）与迁移进来的旧日志的 S(e)。
    pub legacy_hlc: Option<String>,
    pub legacy_server_time: Option<i64>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Body {
    /// 身份记录：创建即不可变（Dart `SrsEntityRecord`，`data` 是 `d` 的规范 JSON）。
    Entity { kind: EntKind, id: Key, data: String },
    Edit(EditBody),
    Log(LogBody),
    /// 标签 OR-Set（加胜）：移除只抹掉移除者见过的那些添加。
    TagAdd { note: Key, tag: String },
    TagRemove { note: Key, tag: String },
    /// 标签的显示顺序提示（作者那一刻的整列表；HLC 大者胜）。OR-Set 本身无序，投影按它排，不在其中的按添加时刻。
    TagOrder { note: Key, tags: Vec<String> },
    /// 时间线还原点（设计 §10.2）。
    Checkpoint { name: String, reason: String },
    /// 彻底清除某实体的内容载荷（设计 §10.5），唯一改写历史的操作。
    Purge { kind: EntKind, entity: Key },
    /// 媒体文件名 → 内容（内容寻址，设计 §6.4）。
    Media { name: String, sha256: [u8; 32], size: u64 },
    /// 某个存储位置的媒体目录里有 / 没有这些文件（设计 §6.4）：作者上传 / 下载成功、列举到，或读取时确认
    /// 不在之后写下的事实。[location] 是位置身份 + 媒体目录（加密媒体的目录按密钥指纹分），对内核不透明。
    /// 每个（位置, 名字）按 HLC 大者胜；各设备据此知道远端有什么，媒体对账不再列目录。
    MediaAt { location: String, flags: u8, names: Vec<String> },
    /// 两个存活牌组全名相同：[from] 并入 [to]（ID 较小者），之后指向 from 的按 to 处理（设计 §3.1）。
    DeckAlias { from: Key, to: Key },
    /// 旧协议里本机不认识的事件，原样保存（JSON 原文）。
    LegacyUnknown { json: String },
    /// 本版本不认识的种类：原样保存、原样转发、不应用。
    Unknown,
    /// 载荷已被彻底清除，只剩骨架。
    Purged,
}

impl Body {
    pub fn kind(&self) -> u16 {
        match self {
            Body::Entity { .. } => KIND_ENTITY,
            Body::Edit(_) => KIND_EDIT,
            Body::Log(_) => KIND_LOG,
            Body::TagAdd { .. } => KIND_TAG_ADD,
            Body::TagRemove { .. } => KIND_TAG_REMOVE,
            Body::TagOrder { .. } => KIND_TAG_ORDER,
            Body::Checkpoint { .. } => KIND_CHECKPOINT,
            Body::Purge { .. } => KIND_PURGE,
            Body::Media { .. } => KIND_MEDIA,
            Body::MediaAt { .. } => KIND_MEDIA_AT,
            Body::DeckAlias { .. } => KIND_DECK_ALIAS,
            Body::LegacyUnknown { .. } => KIND_LEGACY_UNKNOWN,
            Body::Unknown | Body::Purged => u16::MAX,
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        match self {
            Body::Entity { kind, id, data } => {
                w.u8(*kind as u8);
                id.write(&mut w);
                w.str(data);
            }
            Body::Edit(e) => {
                w.u8(e.kind as u8);
                e.entity.write(&mut w);
                w.str(&e.key);
                w.str(&e.value);
                w.u8(u8::from(e.machine) | (e.ts << 1));
                match &e.legacy {
                    None => w.u8(0),
                    Some(l) => {
                        w.u8(1);
                        l.write(&mut w);
                    }
                }
            }
            Body::Log(l) => write_log(&mut w, l),
            Body::TagAdd { note, tag } | Body::TagRemove { note, tag } => {
                note.write(&mut w);
                w.str(tag);
            }
            Body::TagOrder { note, tags } => {
                note.write(&mut w);
                w.uv(tags.len() as u64);
                for t in tags {
                    w.str(t);
                }
            }
            Body::Checkpoint { name, reason } => {
                w.str(name);
                w.str(reason);
            }
            Body::Purge { kind, entity } => {
                w.u8(*kind as u8);
                entity.write(&mut w);
            }
            Body::Media { name, sha256, size } => {
                w.str(name);
                w.raw(sha256);
                w.uv(*size);
            }
            Body::MediaAt { location, flags, names } => {
                w.str(location);
                w.u8(*flags);
                w.uv(names.len() as u64);
                for n in names {
                    w.str(n);
                }
            }
            Body::DeckAlias { from, to } => {
                from.write(&mut w);
                to.write(&mut w);
            }
            Body::LegacyUnknown { json } => w.str(json),
            Body::Unknown | Body::Purged => {}
        }
        w.into_vec()
    }

    pub fn decode(kind: u16, payload: &[u8]) -> DResult<Body> {
        let mut r = Reader::new(payload);
        let r = &mut r;
        Ok(match kind {
            KIND_ENTITY => Body::Entity {
                kind: EntKind::from_code(r.u8()?)?,
                id: Key::read(r)?,
                data: r.str()?.to_owned(),
            },
            KIND_EDIT => {
                let kind = EntKind::from_code(r.u8()?)?;
                let entity = Key::read(r)?;
                let key = r.str()?.to_owned();
                let value = r.str()?.to_owned();
                let flags = r.u8()?;
                let legacy = match r.u8()? {
                    0 => None,
                    1 => Some(LegacyStamp::read(r)?),
                    _ => return Err(DecodeError("edit legacy tag")),
                };
                Body::Edit(EditBody { kind, entity, key, value, machine: flags & 1 != 0, ts: (flags >> 1) & 1, legacy })
            }
            KIND_LOG => Body::Log(read_log(r)?),
            KIND_TAG_ADD => Body::TagAdd { note: Key::read(r)?, tag: r.str()?.to_owned() },
            KIND_TAG_REMOVE => Body::TagRemove { note: Key::read(r)?, tag: r.str()?.to_owned() },
            KIND_TAG_ORDER => {
                let note = Key::read(r)?;
                let n = r.uv()?;
                if n > 1 << 16 {
                    return Err(DecodeError("too many tags"));
                }
                let mut tags = Vec::with_capacity(n as usize);
                for _ in 0..n {
                    tags.push(r.str()?.to_owned());
                }
                Body::TagOrder { note, tags }
            }
            KIND_CHECKPOINT => Body::Checkpoint { name: r.str()?.to_owned(), reason: r.str()?.to_owned() },
            KIND_PURGE => Body::Purge { kind: EntKind::from_code(r.u8()?)?, entity: Key::read(r)? },
            KIND_MEDIA => Body::Media {
                name: r.str()?.to_owned(),
                sha256: r.raw(32)?.try_into().map_err(|_| DecodeError("sha256"))?,
                size: r.uv()?,
            },
            KIND_MEDIA_AT => {
                let location = r.str()?.to_owned();
                let flags = r.u8()?;
                let n = r.uv()?;
                if n > MEDIA_AT_MAX_NAMES as u64 {
                    return Err(DecodeError("too many media names"));
                }
                let mut names = Vec::with_capacity(n as usize);
                for _ in 0..n {
                    names.push(r.str()?.to_owned());
                }
                Body::MediaAt { location, flags, names }
            }
            KIND_DECK_ALIAS => Body::DeckAlias { from: Key::read(r)?, to: Key::read(r)? },
            KIND_LEGACY_UNKNOWN => Body::LegacyUnknown { json: r.str()?.to_owned() },
            _ => Body::Unknown,
        })
    }
}

/// 日志种类的紧凑码（持久化名冻结）；不认识的写字符串。
const LOG_KINDS: [&str; 6] = ["review", "manual", "reschedule", "importAnchor", "handOff", "undo"];
const RTYPES: [&str; 6] = ["learn", "review", "relearn", "filtered", "manual", "rescheduled"];
const ORIGINS: [&str; 2] = ["fushi", "anki"];

fn write_code(w: &mut Writer, table: &[&str], s: &str) {
    match table.iter().position(|x| *x == s) {
        Some(i) => w.u8(i as u8),
        None => {
            w.u8(255);
            w.str(s);
        }
    }
}

fn read_code(r: &mut Reader<'_>, table: &[&str]) -> DResult<String> {
    let c = r.u8()?;
    if c == 255 {
        return Ok(r.str()?.to_owned());
    }
    table.get(c as usize).map(|s| (*s).to_owned()).ok_or(DecodeError("log code"))
}

fn write_log(w: &mut Writer, l: &LogBody) {
    l.id.write(w);
    l.card.write(w);
    match &l.note {
        None => w.u8(0),
        Some(k) => {
            w.u8(1);
            k.write(w);
        }
    }
    write_code(w, &LOG_KINDS, &l.kind);
    w.u8(l.rating.map_or(0, |r| (r.clamp(0, 254) + 1) as u8));
    match &l.revokes {
        None => w.u8(0),
        Some(k) => {
            w.u8(1);
            k.write(w);
        }
    }
    w.iv(l.at);
    w.u8(l.ts);
    write_code(w, &ORIGINS, &l.origin);
    write_code(w, &RTYPES, &l.rtype);
    w.iv(l.dur);
    w.opt_str(l.params.as_deref());
    w.opt_str(l.alg.as_deref());
    w.iv(l.utc_off);
    w.iv(l.rollover);
    w.opt_iv(l.anki_id);
    w.iv(l.fv);
    match l.intent {
        Intent::Absolute => w.u8(0),
        Intent::Answer => w.u8(1),
        Intent::SetDue { due_day } => {
            w.u8(2);
            w.iv(due_day);
        }
        Intent::Reset => w.u8(3),
        Intent::Reschedule => w.u8(4),
        Intent::HandOff { to_anki } => {
            w.u8(5);
            w.bool(to_anki);
        }
    }
    w.opt_str(l.res.as_deref());
    w.str(&l.extra);
    w.opt_str(l.legacy_hlc.as_deref());
    w.opt_iv(l.legacy_server_time);
}

fn read_log(r: &mut Reader<'_>) -> DResult<LogBody> {
    let id = Key::read(r)?;
    let card = Key::read(r)?;
    let note = match r.u8()? {
        0 => None,
        1 => Some(Key::read(r)?),
        _ => return Err(DecodeError("log note tag")),
    };
    let kind = read_code(r, &LOG_KINDS)?;
    let rating = match r.u8()? {
        0 => None,
        n => Some(i64::from(n) - 1),
    };
    let revokes = match r.u8()? {
        0 => None,
        1 => Some(Key::read(r)?),
        _ => return Err(DecodeError("log revokes tag")),
    };
    let at = r.iv()?;
    let ts = r.u8()?;
    let origin = read_code(r, &ORIGINS)?;
    let rtype = read_code(r, &RTYPES)?;
    let dur = r.iv()?;
    let params = r.opt_str()?.map(str::to_owned);
    let alg = r.opt_str()?.map(str::to_owned);
    let utc_off = r.iv()?;
    let rollover = r.iv()?;
    let anki_id = r.opt_iv()?;
    let fv = r.iv()?;
    let intent = match r.u8()? {
        0 => Intent::Absolute,
        1 => Intent::Answer,
        2 => Intent::SetDue { due_day: r.iv()? },
        3 => Intent::Reset,
        4 => Intent::Reschedule,
        5 => Intent::HandOff { to_anki: r.bool()? },
        _ => return Err(DecodeError("log intent")),
    };
    Ok(LogBody {
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
        res: r.opt_str()?.map(str::to_owned),
        extra: r.str()?.to_owned(),
        legacy_hlc: r.opt_str()?.map(str::to_owned),
        legacy_server_time: r.opt_iv()?,
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub fn sample_log() -> LogBody {
        LogBody {
            id: Key::Uuid(Id([7; 16])),
            card: Key::Uuid(Id([8; 16])),
            note: Some(Key::Uuid(Id([9; 16]))),
            kind: "review".into(),
            rating: Some(3),
            revokes: None,
            at: 1_700_000_000_000,
            ts: 1,
            origin: "fushi".into(),
            rtype: "review".into(),
            dur: 4200,
            params: Some("fsrs7:abc".into()),
            alg: Some("fsrs7".into()),
            utc_off: 480,
            rollover: 4,
            anki_id: None,
            fv: 1,
            intent: Intent::Answer,
            res: None,
            extra: "{}".into(),
            legacy_hlc: None,
            legacy_server_time: None,
        }
    }

    #[test]
    fn bodies_round_trip() {
        let bodies = vec![
            Body::Entity { kind: EntKind::Note, id: Key::of("n"), data: r#"{"a":1}"#.into() },
            Body::Edit(EditBody {
                kind: EntKind::Card,
                entity: Key::Uuid(Id([3; 16])),
                key: "suspended".into(),
                value: "true".into(),
                machine: true,
                ts: 1,
                legacy: Some(LegacyStamp {
                    writer: "w".into(),
                    seq: 4,
                    ctx_json: "{}".into(),
                    hlc: "1:0:w".into(),
                    server_time: Some(9),
                }),
            }),
            Body::Log(sample_log()),
            Body::Log(LogBody { kind: "weird".into(), rtype: "odd".into(), origin: "x".into(), intent: Intent::SetDue { due_day: -3 }, ..sample_log() }),
            Body::TagAdd { note: Key::of("n"), tag: "t".into() },
            Body::TagRemove { note: Key::of("n"), tag: "t".into() },
            Body::TagOrder { note: Key::of("n"), tags: vec!["b".into(), "a".into()] },
            Body::Checkpoint { name: "a".into(), reason: "import".into() },
            Body::Purge { kind: EntKind::Note, entity: Key::of("n") },
            Body::Media { name: "a.mp3".into(), sha256: [9; 32], size: 77 },
            Body::MediaAt { location: "drive:x/media".into(), flags: MEDIA_AT_PRESENT | MEDIA_AT_SEEDED, names: vec!["a.mp3".into(), "b.png".into()] },
            Body::MediaAt { location: "drive:x/media".into(), flags: 0, names: vec![] },
            Body::DeckAlias { from: Key::of("b"), to: Key::of("a") },
            Body::LegacyUnknown { json: "{}".into() },
        ];
        for b in bodies {
            let bytes = b.encode();
            assert_eq!(Body::decode(b.kind(), &bytes).unwrap(), b);
        }
        assert_eq!(Body::decode(999, b"anything").unwrap(), Body::Unknown);
    }

    #[test]
    fn media_at_rejects_an_oversized_name_list() {
        let names: Vec<String> = (0..=MEDIA_AT_MAX_NAMES).map(|i| format!("{i}.mp3")).collect();
        let bytes = Body::MediaAt { location: "l".into(), flags: MEDIA_AT_PRESENT, names }.encode();
        assert!(Body::decode(KIND_MEDIA_AT, &bytes).is_err());
    }

    #[test]
    fn a_review_is_compact() {
        // 未压缩约 80 字节（两个 16 字节 ID 占大头）；段里 zstd 之后见 segment.rs 的体积测试。
        let n = Body::Log(sample_log()).encode().len();
        assert!(n <= 112, "review payload {n} bytes");
    }

    #[test]
    fn known_kind_with_trailing_new_fields_still_decodes() {
        let mut bytes = Body::TagAdd { note: Key::of("n"), tag: "t".into() }.encode();
        bytes.extend_from_slice(&[1, 2, 3]);
        assert_eq!(Body::decode(KIND_TAG_ADD, &bytes).unwrap(), Body::TagAdd { note: Key::of("n"), tag: "t".into() });
    }

    #[test]
    fn op_envelope_round_trip_and_causality() {
        let mut deps = Vv::new();
        deps.set(Id([2; 16]), 5);
        let op = Op {
            id: OpId { device: Id([1; 16]), seq: 3 },
            hlc: Hlc { wall: 10, logical: 2, device: Id([1; 16]) },
            deps: Arc::new(deps),
            kind: KIND_TAG_ADD,
            schema: SCHEMA,
            payload: Body::TagAdd { note: Key::of("n"), tag: "t".into() }.encode().into(),
            purged: false,
        };
        let bytes = op.encode();
        assert_eq!(Op::read(&mut Reader::new(&bytes)).unwrap(), op);
        assert!(op.saw(&OpId { device: Id([1; 16]), seq: 2 }));
        assert!(!op.saw(&OpId { device: Id([1; 16]), seq: 3 }));
        assert!(op.saw(&OpId { device: Id([2; 16]), seq: 5 }));
        assert!(!op.saw(&OpId { device: Id([2; 16]), seq: 6 }));
    }
}
