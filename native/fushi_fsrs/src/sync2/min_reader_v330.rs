//! 冻结的 v3.3.0 读者：操作载荷解码与日志意图，取自 tag v3.3.0（提交 87f1c4500c3dca11bd4c7fe6ebf2ed39a2d93134）的下列
//! 函数，控制流、校验与码表逐行照抄，只把类型换成本文件里的冻结类型（不引用本仓会演进的 `Body` / `Key` / `Reader`），
//! 解码另外返回读到的字节数。不随本仓演进：
//!
//! - native/fushi_fsrs/src/sync2/codec.rs `Reader`（u8 / uv / iv / raw / bytes / str / bool / opt_iv / opt_str）
//! - native/fushi_fsrs/src/sync2/id.rs `Id::read`、`Key::read`
//! - native/fushi_fsrs/src/sync2/op.rs `EntKind::from_code`、`LegacyStamp::read`、`Body::decode`、`read_log`、
//!   `read_code` 与三张码表、`skeleton_body`
//! - native/fushi_fsrs/src/store/sync2/mod.rs `intent_code`、`intent_of`（v3.3.0 读者把收到的日志意图按码存进
//!   `sync2_log_meta`、重放时再解回来，旧读者看到的意图 = `intent_of(intent_code(解出的意图))`）
//!
//! 用途（min_reader.rs）：凡是本版本声明 ≤ 3 的内容，v3.3.0 读者解出的投影必须与本版本**逐位相同**——读完全部字节
//! （没有被它忽略的追加字段）、解出的每个字段与本版本相同、意图码相同。不同就说明旧读者会静默按旧语义投影，必须声明
//! 更高的 `minReader`。**不要为了让测试变绿去改这份副本**：它代表已经发出去、改不了的旧客户端。

#![cfg(test)]

use super::op::{Body, EditBody, EntKind, Intent, LegacyStamp, LogBody};
use super::vv::OpId;

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub struct DecodeError(pub &'static str);
type DResult<T> = Result<T, DecodeError>;

/// v3.3.0 codec.rs `Reader`。
pub struct Reader<'a> {
    pub buf: &'a [u8],
    pub pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    pub fn u8(&mut self) -> DResult<u8> {
        let b = *self.buf.get(self.pos).ok_or(DecodeError("truncated u8"))?;
        self.pos += 1;
        Ok(b)
    }

    pub fn uv(&mut self) -> DResult<u64> {
        let mut out: u64 = 0;
        let mut shift = 0u32;
        loop {
            let b = self.u8()?;
            if shift == 63 && b > 1 {
                return Err(DecodeError("varint overflow"));
            }
            out |= u64::from(b & 0x7f) << shift;
            if b & 0x80 == 0 {
                return Ok(out);
            }
            shift += 7;
            if shift > 63 {
                return Err(DecodeError("varint overflow"));
            }
        }
    }

    pub fn iv(&mut self) -> DResult<i64> {
        let u = self.uv()?;
        Ok(((u >> 1) as i64) ^ -((u & 1) as i64))
    }

    pub fn raw(&mut self, n: usize) -> DResult<&'a [u8]> {
        let end = self
            .pos
            .checked_add(n)
            .ok_or(DecodeError("length overflow"))?;
        if end > self.buf.len() {
            return Err(DecodeError("truncated bytes"));
        }
        let s = &self.buf[self.pos..end];
        self.pos = end;
        Ok(s)
    }

    pub fn bytes(&mut self) -> DResult<&'a [u8]> {
        let n = self.uv()?;
        let n = usize::try_from(n).map_err(|_| DecodeError("length overflow"))?;
        self.raw(n)
    }

    pub fn str(&mut self) -> DResult<&'a str> {
        std::str::from_utf8(self.bytes()?).map_err(|_| DecodeError("bad utf-8"))
    }

    pub fn bool(&mut self) -> DResult<bool> {
        match self.u8()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(DecodeError("bad bool")),
        }
    }

    pub fn opt_iv(&mut self) -> DResult<Option<i64>> {
        match self.u8()? {
            0 => Ok(None),
            1 => Ok(Some(self.iv()?)),
            _ => Err(DecodeError("bad option tag")),
        }
    }

    pub fn opt_str(&mut self) -> DResult<Option<&'a str>> {
        match self.u8()? {
            0 => Ok(None),
            1 => Ok(Some(self.str()?)),
            _ => Err(DecodeError("bad option tag")),
        }
    }
}

/// v3.3.0 id.rs `Id`（16 字节）。
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub struct V330Id(pub [u8; 16]);

fn read_id(r: &mut Reader<'_>) -> DResult<V330Id> {
    let b = r.raw(16)?;
    Ok(V330Id(b.try_into().map_err(|_| DecodeError("id"))?))
}

/// v3.3.0 id.rs `Key`。
#[derive(Debug, PartialEq, Eq, Clone)]
pub enum V330Key {
    Uuid(V330Id),
    Text(String),
}

fn read_key(r: &mut Reader<'_>) -> DResult<V330Key> {
    match r.u8()? {
        0 => Ok(V330Key::Uuid(read_id(r)?)),
        1 => Ok(V330Key::Text(r.str()?.to_owned())),
        _ => Err(DecodeError("bad key tag")),
    }
}

/// v3.3.0 op.rs `EntKind` 的码（0..=4）。
fn ent_kind_from_code(c: u8) -> DResult<u8> {
    if c <= 4 {
        Ok(c)
    } else {
        Err(DecodeError("entity kind"))
    }
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub struct V330Legacy {
    pub writer: String,
    pub seq: i64,
    pub ctx_json: String,
    pub hlc: String,
    pub server_time: Option<i64>,
}

fn read_legacy(r: &mut Reader<'_>) -> DResult<V330Legacy> {
    Ok(V330Legacy {
        writer: r.str()?.to_owned(),
        seq: r.iv()?,
        ctx_json: r.str()?.to_owned(),
        hlc: r.str()?.to_owned(),
        server_time: r.opt_iv()?,
    })
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum V330Intent {
    Absolute,
    Answer,
    SetDue { due_day: i64 },
    Reset,
    Reschedule,
    HandOff { to_anki: bool },
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub struct V330Log {
    pub id: V330Key,
    pub card: V330Key,
    pub note: Option<V330Key>,
    pub kind: String,
    pub rating: Option<i64>,
    pub revokes: Option<V330Key>,
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
    pub intent: V330Intent,
    pub res: Option<String>,
    pub extra: String,
    pub legacy_hlc: Option<String>,
    pub legacy_server_time: Option<i64>,
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum V330Body {
    Entity {
        kind: u8,
        id: V330Key,
        data: String,
    },
    Edit {
        kind: u8,
        entity: V330Key,
        key: String,
        value: String,
        machine: bool,
        ts: u8,
        legacy: Option<V330Legacy>,
    },
    Log(Box<V330Log>),
    TagAdd {
        note: V330Key,
        tag: String,
    },
    TagRemove {
        note: V330Key,
        tag: String,
    },
    TagOrder {
        note: V330Key,
        tags: Vec<String>,
    },
    Checkpoint {
        name: String,
        reason: String,
    },
    Purge {
        kind: u8,
        entity: V330Key,
    },
    Media {
        name: String,
        sha256: [u8; 32],
        size: u64,
    },
    MediaAt {
        location: String,
        flags: u8,
        names: Vec<String>,
    },
    DeckAlias {
        from: V330Key,
        to: V330Key,
    },
    LegacyUnknown {
        json: String,
    },
    Dedup {
        pairs: Vec<(u64, V330Id, u64)>,
    },
    Unknown,
    Purged,
    Duplicate {
        of: (V330Id, u64),
        legacy: Option<V330Legacy>,
    },
}

const KIND_ENTITY: u16 = 1;
const KIND_EDIT: u16 = 2;
const KIND_LOG: u16 = 3;
const KIND_TAG_ADD: u16 = 4;
const KIND_TAG_REMOVE: u16 = 5;
const KIND_CHECKPOINT: u16 = 6;
const KIND_PURGE: u16 = 7;
const KIND_MEDIA: u16 = 8;
const KIND_DECK_ALIAS: u16 = 9;
const KIND_LEGACY_UNKNOWN: u16 = 10;
const KIND_TAG_ORDER: u16 = 11;
const KIND_MEDIA_AT: u16 = 12;
const KIND_DEDUP: u16 = 13;
const DEDUP_MAX_PAIRS: usize = 20_000;
const MEDIA_AT_MAX_NAMES: usize = 2000;

const LOG_KINDS: [&str; 6] = [
    "review",
    "manual",
    "reschedule",
    "importAnchor",
    "handOff",
    "undo",
];
const RTYPES: [&str; 6] = [
    "learn",
    "review",
    "relearn",
    "filtered",
    "manual",
    "rescheduled",
];
const ORIGINS: [&str; 2] = ["fushi", "anki"];

fn read_code(r: &mut Reader<'_>, table: &[&str]) -> DResult<String> {
    let c = r.u8()?;
    if c == 255 {
        return Ok(r.str()?.to_owned());
    }
    table
        .get(c as usize)
        .map(|s| (*s).to_owned())
        .ok_or(DecodeError("log code"))
}

fn read_log(r: &mut Reader<'_>) -> DResult<V330Log> {
    let id = read_key(r)?;
    let card = read_key(r)?;
    let note = match r.u8()? {
        0 => None,
        1 => Some(read_key(r)?),
        _ => return Err(DecodeError("log note tag")),
    };
    let kind = read_code(r, &LOG_KINDS)?;
    let rating = match r.u8()? {
        0 => None,
        n => Some(i64::from(n) - 1),
    };
    let revokes = match r.u8()? {
        0 => None,
        1 => Some(read_key(r)?),
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
        0 => V330Intent::Absolute,
        1 => V330Intent::Answer,
        2 => V330Intent::SetDue { due_day: r.iv()? },
        3 => V330Intent::Reset,
        4 => V330Intent::Reschedule,
        5 => V330Intent::HandOff { to_anki: r.bool()? },
        _ => return Err(DecodeError("log intent")),
    };
    Ok(V330Log {
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

/// v3.3.0 `Body::decode`。返回解出的内容与读到的字节数（读者忽略的追加字段 = 读到的少于载荷长度）。
pub fn decode(kind: u16, payload: &[u8]) -> DResult<(V330Body, usize)> {
    let mut r = Reader::new(payload);
    let r = &mut r;
    let body = match kind {
        KIND_ENTITY => V330Body::Entity {
            kind: ent_kind_from_code(r.u8()?)?,
            id: read_key(r)?,
            data: r.str()?.to_owned(),
        },
        KIND_EDIT => {
            let kind = ent_kind_from_code(r.u8()?)?;
            let entity = read_key(r)?;
            let key = r.str()?.to_owned();
            let value = r.str()?.to_owned();
            let flags = r.u8()?;
            let legacy = match r.u8()? {
                0 => None,
                1 => Some(read_legacy(r)?),
                _ => return Err(DecodeError("edit legacy tag")),
            };
            V330Body::Edit {
                kind,
                entity,
                key,
                value,
                machine: flags & 1 != 0,
                ts: (flags >> 1) & 1,
                legacy,
            }
        }
        KIND_LOG => V330Body::Log(Box::new(read_log(r)?)),
        KIND_TAG_ADD => V330Body::TagAdd {
            note: read_key(r)?,
            tag: r.str()?.to_owned(),
        },
        KIND_TAG_REMOVE => V330Body::TagRemove {
            note: read_key(r)?,
            tag: r.str()?.to_owned(),
        },
        KIND_TAG_ORDER => {
            let note = read_key(r)?;
            let n = r.uv()?;
            if n > 1 << 16 {
                return Err(DecodeError("too many tags"));
            }
            let mut tags = Vec::with_capacity(n as usize);
            for _ in 0..n {
                tags.push(r.str()?.to_owned());
            }
            V330Body::TagOrder { note, tags }
        }
        KIND_CHECKPOINT => V330Body::Checkpoint {
            name: r.str()?.to_owned(),
            reason: r.str()?.to_owned(),
        },
        KIND_PURGE => V330Body::Purge {
            kind: ent_kind_from_code(r.u8()?)?,
            entity: read_key(r)?,
        },
        KIND_MEDIA => V330Body::Media {
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
            V330Body::MediaAt {
                location,
                flags,
                names,
            }
        }
        KIND_DECK_ALIAS => V330Body::DeckAlias {
            from: read_key(r)?,
            to: read_key(r)?,
        },
        KIND_LEGACY_UNKNOWN => V330Body::LegacyUnknown {
            json: r.str()?.to_owned(),
        },
        KIND_DEDUP => {
            let nd = r.uv()?;
            if nd > 1 << 16 {
                return Err(DecodeError("too many dedup devices"));
            }
            let mut devices = Vec::with_capacity(nd as usize);
            for _ in 0..nd {
                devices.push(read_id(r)?);
            }
            let n = r.uv()?;
            if n > DEDUP_MAX_PAIRS as u64 {
                return Err(DecodeError("too many dedup pairs"));
            }
            let mut pairs = Vec::with_capacity(n as usize);
            let mut own = 0u64;
            for _ in 0..n {
                own = own.checked_add(r.uv()?).ok_or(DecodeError("dedup seq"))?;
                let d = *devices
                    .get(r.uv()? as usize)
                    .ok_or(DecodeError("dedup device"))?;
                pairs.push((own, d, r.uv()?));
            }
            V330Body::Dedup { pairs }
        }
        _ => V330Body::Unknown,
    };
    Ok((body, r.pos))
}

/// v3.3.0 op.rs `skeleton_body`（骨架载荷）。返回内容与读到的字节数。
pub fn skeleton(payload: &[u8]) -> DResult<(V330Body, usize)> {
    if payload.len() == 32 {
        return Ok((V330Body::Purged, 32));
    }
    let mut r = Reader::new(
        payload
            .get(32..)
            .ok_or(DecodeError("purged op without payload hash"))?,
    );
    if r.u8()? != 1 {
        return Err(DecodeError("duplicate skeleton version"));
    }
    let device = read_id(&mut r)?;
    let seq = r.uv()?;
    let legacy = match r.u8()? {
        0 => None,
        1 => Some(read_legacy(&mut r)?),
        _ => return Err(DecodeError("duplicate legacy tag")),
    };
    Ok((
        V330Body::Duplicate {
            of: (device, seq),
            legacy,
        },
        32 + r.pos,
    ))
}

/// v3.3.0 store/sync2/mod.rs `intent_code`。
pub fn intent_code(i: &V330Intent) -> (i64, Option<i64>) {
    match i {
        V330Intent::Absolute => (0, None),
        V330Intent::Answer => (1, None),
        V330Intent::SetDue { due_day } => (2, Some(*due_day)),
        V330Intent::Reset => (3, None),
        V330Intent::Reschedule => (4, None),
        V330Intent::HandOff { to_anki } => (5, Some(i64::from(*to_anki))),
    }
}

/// v3.3.0 store/sync2/mod.rs `intent_of`。
pub fn intent_of(code: i64, arg: Option<i64>) -> V330Intent {
    match code {
        1 => V330Intent::Answer,
        2 => V330Intent::SetDue {
            due_day: arg.unwrap_or(0),
        },
        3 => V330Intent::Reset,
        4 => V330Intent::Reschedule,
        5 => V330Intent::HandOff {
            to_anki: arg == Some(1),
        },
        _ => V330Intent::Absolute,
    }
}

// ---------------------------------------------------------------- 与本版本对拍（不是冻结部分）

fn key_of(k: &super::id::Key) -> V330Key {
    match k {
        super::id::Key::Uuid(id) => V330Key::Uuid(V330Id(id.0)),
        super::id::Key::Text(s) => V330Key::Text(s.clone()),
    }
}

fn legacy_of(l: &LegacyStamp) -> V330Legacy {
    V330Legacy {
        writer: l.writer.clone(),
        seq: l.seq,
        ctx_json: l.ctx_json.clone(),
        hlc: l.hlc.clone(),
        server_time: l.server_time,
    }
}

fn intent_as_v330(i: &Intent) -> V330Intent {
    match i {
        Intent::Absolute => V330Intent::Absolute,
        Intent::Answer => V330Intent::Answer,
        Intent::SetDue { due_day } => V330Intent::SetDue { due_day: *due_day },
        Intent::Reset => V330Intent::Reset,
        Intent::Reschedule => V330Intent::Reschedule,
        Intent::HandOff { to_anki } => V330Intent::HandOff { to_anki: *to_anki },
    }
}

fn ent(k: EntKind) -> u8 {
    k as u8
}

/// 本版本解出的内容按 v3.3.0 读者的视角写出来：v3.3.0 读者必须解出完全相同的东西。本版本有、v3.3.0 读者没有的
/// 字段 / 变体在这里无处安放（只能丢掉），对拍就会红——那正是要声明更高 `minReader` 的信号。
pub fn as_v330(b: &Body) -> V330Body {
    match b {
        Body::Entity { kind, id, data } => V330Body::Entity {
            kind: ent(*kind),
            id: key_of(id),
            data: data.clone(),
        },
        Body::Edit(EditBody {
            kind,
            entity,
            key,
            value,
            machine,
            ts,
            legacy,
        }) => V330Body::Edit {
            kind: ent(*kind),
            entity: key_of(entity),
            key: key.clone(),
            value: value.clone(),
            machine: *machine,
            ts: *ts,
            legacy: legacy.as_ref().map(legacy_of),
        },
        Body::Log(l) => {
            let LogBody {
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
            } = l;
            V330Body::Log(Box::new(V330Log {
                id: key_of(id),
                card: key_of(card),
                note: note.as_ref().map(key_of),
                kind: kind.clone(),
                rating: *rating,
                revokes: revokes.as_ref().map(key_of),
                at: *at,
                ts: *ts,
                origin: origin.clone(),
                rtype: rtype.clone(),
                dur: *dur,
                params: params.clone(),
                alg: alg.clone(),
                utc_off: *utc_off,
                rollover: *rollover,
                anki_id: *anki_id,
                fv: *fv,
                intent: intent_as_v330(intent),
                res: res.clone(),
                extra: extra.clone(),
                legacy_hlc: legacy_hlc.clone(),
                legacy_server_time: *legacy_server_time,
            }))
        }
        Body::TagAdd { note, tag } => V330Body::TagAdd {
            note: key_of(note),
            tag: tag.clone(),
        },
        Body::TagRemove { note, tag } => V330Body::TagRemove {
            note: key_of(note),
            tag: tag.clone(),
        },
        Body::TagOrder { note, tags } => V330Body::TagOrder {
            note: key_of(note),
            tags: tags.clone(),
        },
        Body::Checkpoint { name, reason } => V330Body::Checkpoint {
            name: name.clone(),
            reason: reason.clone(),
        },
        Body::Purge { kind, entity } => V330Body::Purge {
            kind: ent(*kind),
            entity: key_of(entity),
        },
        Body::Media { name, sha256, size } => V330Body::Media {
            name: name.clone(),
            sha256: *sha256,
            size: *size,
        },
        Body::MediaAt {
            location,
            flags,
            names,
        } => V330Body::MediaAt {
            location: location.clone(),
            flags: *flags,
            names: names.clone(),
        },
        Body::DeckAlias { from, to } => V330Body::DeckAlias {
            from: key_of(from),
            to: key_of(to),
        },
        Body::LegacyUnknown { json } => V330Body::LegacyUnknown { json: json.clone() },
        Body::Dedup { pairs } => V330Body::Dedup {
            pairs: pairs
                .iter()
                .map(|(own, OpId { device, seq })| (*own, V330Id(device.0), *seq))
                .collect(),
        },
        Body::Unknown => V330Body::Unknown,
        Body::Purged => V330Body::Purged,
        Body::Duplicate { of, legacy } => V330Body::Duplicate {
            of: (V330Id(of.device.0), of.seq),
            legacy: legacy.as_ref().map(legacy_of),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::super::min_reader::{self, NEWER_THAN_ME};
    use super::super::op::{Body, KIND_TAG_ADD, Op};
    use super::super::segment::CONTENT_FLOOR;
    use super::*;

    /// v3.3.0 读者眼里的这条操作：内容、读到的字节数、（日志的）意图码往返后的意图。
    fn v330_view(o: &Op) -> DResult<(V330Body, usize)> {
        if o.purged {
            skeleton(&o.payload)
        } else {
            decode(o.kind, &o.payload)
        }
    }

    #[test]
    fn content_declared_readable_by_three_projects_identically_on_v330() {
        let samples = min_reader::tests::feature_samples();
        assert!(samples.len() > 80, "{}", samples.len());
        for o in samples {
            assert!(min_reader::min_reader_of(&o) <= CONTENT_FLOOR);
            let ours = o.body().unwrap();
            let (theirs, read) =
                v330_view(&o).unwrap_or_else(|e| panic!("v3.3.0 rejects {ours:?}: {e:?}"));
            // 读完全部字节：没有被旧读者忽略的追加字段。
            assert_eq!(
                read,
                o.payload.len(),
                "v3.3.0 ignores trailing bytes of {ours:?}"
            );
            assert_eq!(
                theirs,
                as_v330(&ours),
                "v3.3.0 decodes {ours:?} differently"
            );
            if let (Body::Log(l), V330Body::Log(t)) = (&ours, &theirs) {
                let (code, arg) = crate::store::sync2::intent_code(&l.intent);
                let (tc, ta) = intent_code(&t.intent);
                assert_eq!((code, arg), (tc, ta), "intent code of {ours:?}");
                assert_eq!(
                    intent_of(tc, ta),
                    intent_as_v330(&crate::store::sync2::intent_of(code, arg)),
                    "intent of {ours:?}"
                );
            }
        }
    }

    #[test]
    fn the_v330_copy_does_catch_content_old_readers_would_misread() {
        // 自检：对拍真能抓到「旧读者照收但看漏」的内容（追加字段），且本版本把它声明成更高。
        let mut bytes = Body::TagAdd {
            note: super::super::id::Key::of("n"),
            tag: "t".into(),
        }
        .encode();
        let len = bytes.len();
        bytes.push(7);
        let (_, read) = decode(KIND_TAG_ADD, &bytes).unwrap();
        assert_eq!(read, len);
        let o = Op {
            payload: bytes.into(),
            ..min_reader::tests::op_of_body(&Body::Checkpoint {
                name: "x".into(),
                reason: "y".into(),
            })
        };
        let o = Op {
            kind: KIND_TAG_ADD,
            ..o
        };
        assert_eq!(min_reader::min_reader_of(&o), NEWER_THAN_ME);
        // 新种类码：v3.3.0 读者当作不认识的种类，保存但不投影。
        assert_eq!(decode(99, b"x").unwrap().0, V330Body::Unknown);
    }
}
