//! 各位置媒体「在不在」（设计 §4.5、D18；实现拆分 G8-3）：本机缓存 `media_at` 的读写、媒体清单（[crate::gen4::manifest]）
//! 的收与发、协议 3 `sync2_media_at` 的播种。**没有调用方**：同步一轮（G8-7）接线前，协议 3 的 `media_known` /
//! `media_record` 照旧。
//!
//! # 模型
//!
//! - 位置上的真相是各设备的清单文件 `v4/devices/<dev>/mf-*.bin`；本机 `media_at` 只是它们与本机观察的合并缓存，丢了
//!   重新列一遍（[forget]）。每个 `(位置/媒体目录, 内容哈希)` 一行，取 HLC 最大的那条（[Fact::beats]，D18）。
//! - `loc_key` 与协议 3 同口径：`<位置 ID>/<媒体目录>#sha256`（Dart `srsMediaContentPresenceKey`），迁移直接按原键播种。
//!   [presence_key] / [parse_key] 是这个口径在 Rust 里唯一的一份。
//! - 发什么：`media_at.pend = 1` 的行 = 本机知道、但位置上任何一份清单里都还没有的事实（本机观察、或迁移播种）。
//!   [build] 把它们打成本机的下一份清单；上传成功后 [mark_published] 只清**仍是那一条**的行（期间又被改写的照旧待发）；
//!   收到任何一份清单（含本机自己的）里同一条事实也清（[ingest]）——所以「传上去了但没来得及记」的崩溃下一轮自愈，
//!   最坏是重发一遍（合并幂等）。
//! - 收什么：[ingest] 只收代号大于 `media_seen` 水位的文件，验文件名标签、作者、集合、loc 标记、作者信任与签名，
//!   全部过了才在一个事务里合并并推进水位；任何一项不过都不写、不推进。
//! - 「有人完整列举过」（协议 3 的 SEEDED）记在 `media_listed`：本机列的待随清单发出，收到别人的就不必再发。
//!
//! # 调用方契约（G8-4 / G8-7 接线时照办）
//!
//! - 本机时钟由写入器（G7-3a `Native`）持有：[record] 的 HLC 由调用方 tick 出来；[ingest] 返回清单里最大的 HLC，调用方
//!   拿它 `Clock::absorb`，之后本机记的事实才压得过已见的。
//! - 一台设备的清单按代号升序收（[pending_gens]），某一份下载失败就停在那里、这一轮不收它之后的：水位只升不降，跳过的
//!   文件不会再收。合并出的新文件代号比被合并者都大，所以先合并后删旧的写法不会让读者漏掉内容。
//! - [ingest] 返回 [IngestError::UnknownDevice] / [IngestError::Untrusted] 时不推进水位：等 head 带来公钥、或用户信任了
//!   这台设备，下一轮自然收进来。
//! - 改绑定 / 换根时调 [forget] 从头对账（设计 §5.1：位置进度换了根就从头来）。

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{Connection, OptionalExtension, params};

use super::schema::sql;
use super::truth::Truth;
use crate::gen4::manifest::{
    Fact, Manifest, ManifestError, MediaState, open, tag_of, valid_folder,
};
use crate::sync2::hlc::Hlc;
use crate::sync2::id::Id;
use crate::sync2::keys::DeviceKey;

/// 内容寻址的「在不在」键的后缀（协议 3 同口径）。
pub const CONTENT_SUFFIX: &str = "#sha256";
/// 一份清单最多带多少条（迁移后第一份可能要带几万条；再多就分几轮发）。
pub const MAX_BUILD_ENTRIES: usize = 1 << 18;

/// `<位置 ID>/<媒体目录>#sha256`。位置 ID 为空、目录不合法（[valid_folder]）时报错。
pub fn presence_key(location: &str, folder: &str) -> Result<String, String> {
    if location.is_empty() {
        return Err("media: empty location".into());
    }
    if !valid_folder(folder) {
        return Err(format!("media: bad folder {folder:?}"));
    }
    Ok(format!("{location}/{folder}{CONTENT_SUFFIX}"))
}

/// [presence_key] 的逆：`(位置 ID, 媒体目录)`。不是这个口径的（协议 3 按名字存的旧键、目录不合法的）给 None。
/// 位置 ID 里可以有 `/`：目录只能是 `media` 或 `media-e/<不含 / 的指纹>`，从右边切是唯一的。
pub fn parse_key(key: &str) -> Option<(&str, &str)> {
    let rest = key.strip_suffix(CONTENT_SUFFIX)?;
    let (head, last) = rest.rsplit_once('/')?;
    let (location, folder) = if last == "media" {
        (head, &rest[head.len() + 1..])
    } else {
        let (location, me) = head.rsplit_once('/')?;
        if me != "media-e" {
            return None;
        }
        (location, &rest[location.len() + 1..])
    };
    (!location.is_empty() && valid_folder(folder)).then_some((location, folder))
}

/// `media_at.hlc` 的文本形：`<wall>:<logical>:<设备 UUID 规范文本>`。
pub fn hlc_text(h: &Hlc) -> String {
    format!("{}:{}:{}", h.wall, h.logical, h.device.text())
}

/// [hlc_text] 的逆。只收 [hlc_text] 写得出的形（回写不等就拒）。
pub fn parse_hlc_text(s: &str) -> Result<Hlc, String> {
    let bad = || format!("media: bad hlc text {s:?}");
    let mut it = s.splitn(3, ':');
    let wall: i64 = it.next().and_then(|x| x.parse().ok()).ok_or_else(bad)?;
    let logical: u32 = it.next().and_then(|x| x.parse().ok()).ok_or_else(bad)?;
    let device = it.next().and_then(Id::parse).ok_or_else(bad)?;
    let h = Hlc {
        wall,
        logical,
        device,
    };
    if hlc_text(&h) != s {
        return Err(bad());
    }
    Ok(h)
}

fn sha_of(b: Vec<u8>) -> Result<[u8; 32], String> {
    b.try_into()
        .map_err(|_| "media: content hash is not 32 bytes".to_owned())
}

fn state_of(code: i64) -> Result<MediaState, String> {
    u8::try_from(code)
        .ok()
        .and_then(MediaState::of_code)
        .ok_or_else(|| format!("media: bad state {code}"))
}

/// 读一行：(事实, 待发)。
fn row(
    c: &Connection,
    col: i64,
    key: &str,
    sha: &[u8; 32],
) -> Result<Option<(Fact, bool)>, String> {
    let r: Option<(i64, String, i64)> = c
        .prepare_cached(
            "SELECT state, hlc, pend FROM media_at WHERE col = ?1 AND loc_key = ?2 AND sha = ?3",
        )
        .map_err(sql)?
        .query_row(params![col, key, &sha[..]], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })
        .optional()
        .map_err(sql)?;
    r.map(|(s, h, p)| {
        Ok((
            Fact {
                state: state_of(s)?,
                hlc: parse_hlc_text(&h)?,
            },
            p != 0,
        ))
    })
    .transpose()
}

fn put(
    c: &Connection,
    col: i64,
    key: &str,
    sha: &[u8; 32],
    f: &Fact,
    pend: bool,
) -> Result<(), String> {
    c.prepare_cached(
        "INSERT OR REPLACE INTO media_at (col, loc_key, sha, state, hlc, pend) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .map_err(sql)?
    .execute(params![
        col,
        key,
        &sha[..],
        i64::from(f.state.code()),
        hlc_text(&f.hlc),
        i64::from(pend)
    ])
    .map_err(sql)?;
    Ok(())
}

fn set_listed(c: &Connection, col: i64, key: &str, pend: bool) -> Result<(), String> {
    // 已经有人列过（pend = 0）的保持 0：位置上已有证据，不必再发。
    c.prepare_cached(
        "INSERT INTO media_listed (col, loc_key, pend) VALUES (?1, ?2, ?3) \
         ON CONFLICT(col, loc_key) DO UPDATE SET pend = MIN(pend, excluded.pend)",
    )
    .map_err(sql)?
    .execute(params![col, key, i64::from(pend)])
    .map_err(sql)?;
    Ok(())
}

fn raise_seen(
    c: &Connection,
    col: i64,
    location: &str,
    device: &Id,
    gen: u64,
) -> Result<(), String> {
    let gen = i64::try_from(gen).map_err(|_| "media: gen overflow".to_owned())?;
    c.prepare_cached(
        "INSERT INTO media_seen (col, loc, device, gen) VALUES (?1, ?2, ?3, ?4) \
         ON CONFLICT(col, loc, device) DO UPDATE SET gen = MAX(gen, excluded.gen)",
    )
    .map_err(sql)?
    .execute(params![col, location, &device.0[..], gen])
    .map_err(sql)?;
    Ok(())
}

/// 某位置上某作者的清单已收到（本机自己 = 已发出）的最大代号；没有 = 0。
pub fn watermark(t: &Truth<'_>, col: i64, location: &str, device: &Id) -> Result<u64, String> {
    let g: Option<i64> = t
        .conn()
        .prepare_cached("SELECT gen FROM media_seen WHERE col = ?1 AND loc = ?2 AND device = ?3")
        .map_err(sql)?
        .query_row(params![col, location, &device.0[..]], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    Ok(g.map_or(0, |g| g.max(0) as u64))
}

/// 位置上列出的某作者的清单代号里，还要收的那些（大于水位，升序去重）。
pub fn pending_gens(
    t: &Truth<'_>,
    col: i64,
    location: &str,
    device: &Id,
    listed: &[u64],
) -> Result<Vec<u64>, String> {
    let w = watermark(t, col, location, device)?;
    Ok(listed
        .iter()
        .copied()
        .filter(|g| *g > w)
        .collect::<BTreeSet<u64>>()
        .into_iter()
        .collect())
}

// ------------------------------------------------------------------------------------------------ 读

/// 一个媒体目录的已知内容（协议 3 `media_known` 的新代形）。哈希都按字节序升序。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MediaKnown {
    /// 有人对这个目录完整列举过：调用方不必再列，只对不认识的逐个查。
    pub seeded: bool,
    pub present: Vec<[u8; 32]>,
    pub absent: Vec<[u8; 32]>,
    pub suspect: Vec<[u8; 32]>,
}

/// 两次查询放在同一个读事务里：「列举过」与条目来自同一个已提交的快照。
pub fn known(t: &Truth<'_>, col: i64, location: &str, folder: &str) -> Result<MediaKnown, String> {
    let key = presence_key(location, folder)?;
    t.tx(|t| known_in(t.conn(), col, &key))
}

fn known_in(c: &Connection, col: i64, key: &str) -> Result<MediaKnown, String> {
    let mut out = MediaKnown {
        seeded: c
            .prepare_cached("SELECT 1 FROM media_listed WHERE col = ?1 AND loc_key = ?2")
            .map_err(sql)?
            .query_row(params![col, key], |_| Ok(()))
            .optional()
            .map_err(sql)?
            .is_some(),
        ..MediaKnown::default()
    };
    let mut stmt = c
        .prepare_cached(
            "SELECT sha, state FROM media_at WHERE col = ?1 AND loc_key = ?2 ORDER BY sha",
        )
        .map_err(sql)?;
    let rows = stmt
        .query_map(params![col, key], |r| {
            Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?))
        })
        .map_err(sql)?;
    for r in rows {
        let (sha, s) = r.map_err(sql)?;
        let sha = sha_of(sha)?;
        match state_of(s)? {
            MediaState::Present => out.present.push(sha),
            MediaState::Absent => out.absent.push(sha),
            MediaState::Suspect => out.suspect.push(sha),
        }
    }
    Ok(out)
}

/// 一个内容哈希在一个媒体目录里的当前事实（没有 = 未知）。
pub fn fact(
    t: &Truth<'_>,
    col: i64,
    location: &str,
    folder: &str,
    sha: &[u8; 32],
) -> Result<Option<Fact>, String> {
    Ok(row(t.conn(), col, &presence_key(location, folder)?, sha)?.map(|(f, _)| f))
}

// ------------------------------------------------------------------------------------------------ 本机观察

/// [record] 的结果。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Recorded {
    /// 写下（待发）的条数。
    pub written: usize,
    /// 与当前状态相同、没写的（不往清单里灌重复事实）。
    pub unchanged: usize,
    /// 当前那条的 HLC 不小于本次的：按 D18 本次在任何设备上都会输，本机也不写（否则本机缓存与别人分叉）。
    /// 调用方的时钟没吸收已见的 HLC 才会出现；或那条来自超前 `MAX_AHEAD_MS` 以上的设备。
    pub stale: usize,
}

/// 记下本机对一个媒体目录的观察（传上 / 拉下 / 确认在、确认不在、下载到的内容对不上）。[hlc] 是这次观察的本机 HLC
/// （调用方 tick）。[listed] = 这是一次完整列举的结果。同一个哈希在 [facts] 里出现两次且状态不同 = 调用方的错，整批拒。
pub fn record(
    t: &Truth<'_>,
    col: i64,
    location: &str,
    folder: &str,
    facts: &[([u8; 32], MediaState)],
    listed: bool,
    hlc: Hlc,
) -> Result<Recorded, String> {
    let key = presence_key(location, folder)?;
    let mut want: BTreeMap<[u8; 32], MediaState> = BTreeMap::new();
    for (sha, s) in facts {
        if want.insert(*sha, *s).is_some_and(|prev| prev != *s) {
            return Err("media record: one content hash with two states".into());
        }
    }
    t.tx(|t| {
        let c = t.conn();
        let mut out = Recorded::default();
        for (sha, state) in want {
            let f = Fact { state, hlc };
            match row(c, col, &key, &sha)? {
                Some((cur, _)) if cur.state == state => out.unchanged += 1,
                Some((cur, _)) if cur.hlc >= hlc => out.stale += 1,
                _ => {
                    put(c, col, &key, &sha, &f, true)?;
                    out.written += 1;
                }
            }
        }
        if listed {
            set_listed(c, col, &key, true)?;
        }
        Ok(out)
    })
}

// ------------------------------------------------------------------------------------------------ 发

/// [build] 打出的一份待传清单。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Built {
    pub manifest: Manifest,
    pub bytes: Vec<u8>,
    /// 文件名（`mf-<gen12>-<tag8>.bin`，放在 `v4/devices/<本机>/` 下）。
    pub name: String,
}

/// 把本机在这个位置上待发的事实打成下一份清单（没有待发的 = None）。[loc] = 这个位置的 loc 标记之一（D17）；
/// [own_gens] = 位置上本机设备目录里现有的清单代号（新代号比它们与水位都大，不会撞名）。[signer] 必须是 [device]
/// 的签名钥匙：`peers` 里记了本机公钥而对不上时拒绝（签出去的文件谁都验不过）。只读，不改任何行；传成功后调
/// [mark_published]。
#[allow(clippy::too_many_arguments)]
pub fn build(
    t: &Truth<'_>,
    col: i64,
    location: &str,
    loc: Id,
    device: Id,
    signer: &DeviceKey,
    own_gens: &[u64],
) -> Result<Option<Built>, String> {
    if location.is_empty() {
        return Err("media: empty location".into());
    }
    let binding = t
        .binding(col)?
        .ok_or_else(|| format!("media: collection {col} is not bound"))?;
    if t.device_key(col, &device)?
        .is_some_and(|k| k != signer.public())
    {
        return Err("media: the signing key is not this device's recorded key".into());
    }
    t.tx(|t| {
        let c = t.conn();
        let gen = watermark(t, col, location, &device)?
            .max(own_gens.iter().copied().max().unwrap_or(0))
            .checked_add(1)
            .ok_or_else(|| "media: gen overflow".to_owned())?;
        let mut m = Manifest::new(binding.collection, device, loc, gen);
        // 键按位置 ID 加 `/` 起头的区间：`/` 之后的下一个字符是 `0`。
        let lo = format!("{location}/");
        let hi = format!("{location}0");
        let mut n = 0usize;
        {
            let mut stmt = c
                .prepare_cached(
                    "SELECT loc_key, sha, state, hlc FROM media_at \
                     WHERE col = ?1 AND loc_key >= ?2 AND loc_key < ?3 AND pend = 1 ORDER BY loc_key, sha",
                )
                .map_err(sql)?;
            let mut rows = stmt.query(params![col, &lo, &hi]).map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                if n >= MAX_BUILD_ENTRIES {
                    break;
                }
                let key: String = r.get(0).map_err(sql)?;
                let Some((l, folder)) = parse_key(&key) else {
                    continue;
                };
                if l != location {
                    continue;
                }
                let sha = sha_of(r.get(1).map_err(sql)?)?;
                let f = Fact {
                    state: state_of(r.get(2).map_err(sql)?)?,
                    hlc: parse_hlc_text(&r.get::<_, String>(3).map_err(sql)?)?,
                };
                m.sections
                    .entry(folder.to_owned())
                    .or_default()
                    .entries
                    .insert(sha, f);
                n += 1;
            }
        }
        {
            let mut stmt = c
                .prepare_cached(
                    "SELECT loc_key FROM media_listed WHERE col = ?1 AND loc_key >= ?2 AND loc_key < ?3 AND pend = 1",
                )
                .map_err(sql)?;
            let keys = stmt
                .query_map(params![col, &lo, &hi], |r| r.get::<_, String>(0))
                .map_err(sql)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(sql)?;
            for key in keys {
                if let Some((l, folder)) = parse_key(&key) {
                    if l == location {
                        m.sections.entry(folder.to_owned()).or_default().listed = true;
                    }
                }
            }
        }
        if m.is_empty() {
            return Ok(None);
        }
        let (bytes, name) = m.encode(signer)?;
        Ok(Some(Built {
            manifest: m,
            bytes,
            name,
        }))
    })
}

/// [build] 的那份清单已经写到位置上：清掉**仍是那一条事实**的待发标记（打包之后又被改写的照旧待发），推进本机水位。
/// 返回清掉的条数。可重放。
pub fn mark_published(
    t: &Truth<'_>,
    col: i64,
    location: &str,
    m: &Manifest,
) -> Result<usize, String> {
    t.tx(|t| {
        let c = t.conn();
        let mut n = 0;
        for (folder, sec) in &m.sections {
            let key = presence_key(location, folder)?;
            for (sha, f) in &sec.entries {
                n += c
                    .prepare_cached(
                        "UPDATE media_at SET pend = 0 \
                         WHERE col = ?1 AND loc_key = ?2 AND sha = ?3 AND state = ?4 AND hlc = ?5 AND pend = 1",
                    )
                    .map_err(sql)?
                    .execute(params![col, &key, &sha[..], i64::from(f.state.code()), hlc_text(&f.hlc)])
                    .map_err(sql)?;
            }
            if sec.listed {
                set_listed(c, col, &key, false)?;
            }
        }
        raise_seen(c, col, location, &m.device, m.gen)?;
        Ok(n)
    })
}

// ------------------------------------------------------------------------------------------------ 收

/// [ingest] 不收一份清单的原因。除 [IngestError::Store] 外都没写任何东西、没推进水位。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IngestError {
    /// 集合没绑定。
    Unbound,
    /// 作者的公钥还没见过（等 head）。
    UnknownDevice(Id),
    /// 作者待确认 / 已拒绝（`trust` 表）：它说的「在」可能是要让别人别传。
    Untrusted(Id, i64),
    /// 文件与它所在的路径或这个位置对不上（作者、代号、标签、集合、loc 标记）。
    Mismatch(String),
    /// 解不开 / 签名不对。
    Manifest(ManifestError),
    Store(String),
}

impl std::fmt::Display for IngestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            IngestError::Unbound => f.write_str("media ingest: collection not bound"),
            IngestError::UnknownDevice(d) => write!(f, "media ingest: no public key for {d}"),
            IngestError::Untrusted(d, s) => {
                write!(f, "media ingest: device {d} is untrusted ({s})")
            }
            IngestError::Mismatch(e) => write!(f, "media ingest: {e}"),
            IngestError::Manifest(e) => write!(f, "media ingest: {e}"),
            IngestError::Store(e) => f.write_str(e),
        }
    }
}

impl From<String> for IngestError {
    fn from(e: String) -> Self {
        IngestError::Store(e)
    }
}

/// [ingest] 的结果。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Ingested {
    /// 代号不大于水位：整份跳过（什么都没读进来）。
    pub already: bool,
    /// 胜过本机当前那条、写进来的。
    pub applied: usize,
    /// 与本机当前那条相同（本机待发的就此不必再发）。
    pub covered: usize,
    /// 输给本机当前那条的。
    pub older: usize,
    /// 带 listed 的节数。
    pub listed: usize,
    /// 清单里最大的 HLC（调用方拿去 `Clock::absorb`）。
    pub max_hlc: Option<Hlc>,
}

/// 收一份清单。[device] / [gen] / [tag] 是从它的路径解出来的（`parse_v4_path` 的 `V4File::Manifest`）；[locs] 是这个
/// 位置的 loc 标记集合。
#[allow(clippy::too_many_arguments)]
pub fn ingest(
    t: &Truth<'_>,
    col: i64,
    location: &str,
    locs: &BTreeSet<Id>,
    device: &Id,
    gen: u64,
    tag: &str,
    bytes: &[u8],
) -> Result<Ingested, IngestError> {
    if location.is_empty() {
        return Err(IngestError::Store("media: empty location".into()));
    }
    let binding = t.binding(col)?.ok_or(IngestError::Unbound)?;
    if tag_of(bytes) != tag {
        return Err(IngestError::Mismatch(
            "file name tag does not match the content".into(),
        ));
    }
    let opened = open(bytes).map_err(IngestError::Manifest)?;
    let h = &opened.manifest;
    if h.device != *device {
        return Err(IngestError::Mismatch(format!(
            "manifest author {} sits in the folder of {device}",
            h.device
        )));
    }
    if h.gen != gen {
        return Err(IngestError::Mismatch(format!(
            "manifest gen {} named {gen}",
            h.gen
        )));
    }
    if h.collection != binding.collection {
        return Err(IngestError::Mismatch(
            "manifest of another collection".into(),
        ));
    }
    if !locs.contains(&h.loc) {
        return Err(IngestError::Mismatch(
            "manifest of another location (loc marker)".into(),
        ));
    }
    if let Some(s) = t.trust_of(col, device)? {
        return Err(IngestError::Untrusted(*device, s));
    }
    let public = t
        .device_key(col, device)?
        .ok_or(IngestError::UnknownDevice(*device))?;
    let m = opened.verify(&public).map_err(IngestError::Manifest)?;
    let out = t.tx(|t| {
        let c = t.conn();
        let mut out = Ingested::default();
        if gen <= watermark(t, col, location, device)? {
            out.already = true;
            return Ok(out);
        }
        for (folder, sec) in &m.sections {
            let key = presence_key(location, folder)?;
            for (sha, f) in &sec.entries {
                out.max_hlc = out.max_hlc.max(Some(f.hlc));
                match row(c, col, &key, sha)? {
                    Some((cur, pend)) if cur == *f => {
                        if pend {
                            put(c, col, &key, sha, f, false)?;
                        }
                        out.covered += 1;
                    }
                    Some((cur, _)) if !f.beats(&cur) => out.older += 1,
                    _ => {
                        put(c, col, &key, sha, f, false)?;
                        out.applied += 1;
                    }
                }
            }
            if sec.listed {
                set_listed(c, col, &key, false)?;
                out.listed += 1;
            }
        }
        raise_seen(c, col, location, device, gen)?;
        Ok(out)
    })?;
    Ok(out)
}

/// 把同一作者的几份清单合成一份新代号的（压缩回收用：传上去之后再删旧的几份）。各份必须是同一集合、同一作者；
/// [gen] 必须比它们都大。结果是它们的上界（[Manifest::absorb]），读者看到哪几份都合出同一张表。
pub fn compact(parts: &[Manifest], loc: Id, gen: u64) -> Result<Manifest, String> {
    let first = parts.first().ok_or("media compact: nothing to merge")?;
    let mut out = Manifest::new(first.collection, first.device, loc, gen);
    for p in parts {
        if p.collection != first.collection || p.device != first.device {
            return Err("media compact: manifests of different authors or collections".into());
        }
        if p.gen >= gen {
            return Err(format!(
                "media compact: gen {gen} is not above part {}",
                p.gen
            ));
        }
        out.absorb(p);
    }
    Ok(out)
}

// ------------------------------------------------------------------------------------------------ 迁移与对账

/// [seed_legacy] 的结果。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Seeded {
    /// 写进来（待发）的行。
    pub rows: usize,
    /// 不是内容寻址口径的旧行（按名字存的旧格式），不带：缓存，下次对账再列。
    pub skipped: usize,
    /// 带过来的「完整列举过」标记。
    pub listed: usize,
}

/// 迁移播种（规划 §1.4 第 5 步、D11）：把协议 3 库里 [profile] 的 `sync2_media_at` / `sync2_media_seeded` 灌进新代
/// 集合 [col] 的 `media_at` / `media_listed`。旧 HLC 原样保留（只是合并时的次序，不重新盖章：重新盖章会让较晚迁移、
/// 视图较旧的设备压过别人较新的事实）。灌进来的行与列举标记都待发：第一台迁移的设备把它们发到位置上，之后迁移的
/// 设备收到同一条事实就不再发（[ingest]）；全新加入的设备从清单里拿到，不必自己列目录。可重放（按 [Fact::beats] 合并）。
/// [legacy] 上要注册过 `srs_id`（`store::ids::register`，与 `legacy.rs` 相同）。
pub fn seed_legacy(
    t: &Truth<'_>,
    col: i64,
    legacy: &Connection,
    profile: &str,
) -> Result<Seeded, String> {
    let mut rows: Vec<(String, [u8; 32], Fact)> = Vec::new();
    let mut out = Seeded::default();
    {
        let mut stmt = legacy
            .prepare(
                "SELECT location, name, present, wall, logical, device FROM sync2_media_at \
                 WHERE profile_uid = srs_id(?1) ORDER BY location, name",
            )
            .map_err(sql)?;
        let mut q = stmt.query([profile]).map_err(sql)?;
        while let Some(r) = q.next().map_err(sql)? {
            let key: String = r.get(0).map_err(sql)?;
            let name: String = r.get(1).map_err(sql)?;
            let (Some(_), Some(sha)) = (parse_key(&key), unhex_sha(&name)) else {
                out.skipped += 1;
                continue;
            };
            let device: Vec<u8> = r.get(5).map_err(sql)?;
            let device = Id(device
                .try_into()
                .map_err(|_| "media seed: legacy device id is not 16 bytes".to_owned())?);
            let logical: i64 = r.get(4).map_err(sql)?;
            let fact = Fact {
                state: state_of(r.get(2).map_err(sql)?)?,
                hlc: Hlc {
                    wall: r.get(3).map_err(sql)?,
                    logical: u32::try_from(logical)
                        .map_err(|_| format!("media seed: bad legacy logical {logical}"))?,
                    device,
                },
            };
            rows.push((key, sha, fact));
        }
    }
    let seeded: Vec<String> = legacy
        .prepare("SELECT location FROM sync2_media_seeded WHERE profile_uid = srs_id(?1) ORDER BY location")
        .map_err(sql)?
        .query_map([profile], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    t.tx(|t| {
        let c = t.conn();
        for (key, sha, f) in &rows {
            match row(c, col, key, sha)? {
                Some((cur, _)) if !f.beats(&cur) => {}
                _ => {
                    put(c, col, key, sha, f, true)?;
                    out.rows += 1;
                }
            }
        }
        for key in &seeded {
            if parse_key(key).is_some() {
                set_listed(c, col, key, true)?;
                out.listed += 1;
            }
        }
        Ok(out)
    })
}

/// 64 位小写十六进制 → 32 字节（协议 3 内容寻址的名字就是它）。
fn unhex_sha(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 || !s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, o) in out.iter_mut().enumerate() {
        *o = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

/// 丢掉这个位置的全部缓存与进度（改绑定 / 换根时从头对账）。本机还没发出的观察也一起丢：下一轮对账会重新观察到。
/// 返回删掉的 `media_at` 行数。
pub fn forget(t: &Truth<'_>, col: i64, location: &str) -> Result<usize, String> {
    if location.is_empty() {
        return Err("media: empty location".into());
    }
    let lo = format!("{location}/");
    let hi = format!("{location}0");
    t.tx(|t| {
        let c = t.conn();
        let mut doomed: Vec<(String, Vec<u8>)> = Vec::new();
        {
            let mut stmt = c
                .prepare_cached("SELECT loc_key, sha FROM media_at WHERE col = ?1 AND loc_key >= ?2 AND loc_key < ?3")
                .map_err(sql)?;
            let mut q = stmt.query(params![col, &lo, &hi]).map_err(sql)?;
            while let Some(r) = q.next().map_err(sql)? {
                let key: String = r.get(0).map_err(sql)?;
                if parse_key(&key).is_some_and(|(l, _)| l == location) {
                    doomed.push((key, r.get(1).map_err(sql)?));
                }
            }
        }
        for (key, sha) in &doomed {
            c.prepare_cached("DELETE FROM media_at WHERE col = ?1 AND loc_key = ?2 AND sha = ?3")
                .map_err(sql)?
                .execute(params![col, key, sha])
                .map_err(sql)?;
        }
        let listed: Vec<String> = c
            .prepare_cached("SELECT loc_key FROM media_listed WHERE col = ?1 AND loc_key >= ?2 AND loc_key < ?3")
            .map_err(sql)?
            .query_map(params![col, &lo, &hi], |r| r.get(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        for key in listed {
            if parse_key(&key).is_some_and(|(l, _)| l == location) {
                c.prepare_cached("DELETE FROM media_listed WHERE col = ?1 AND loc_key = ?2")
                    .map_err(sql)?
                    .execute(params![col, key])
                    .map_err(sql)?;
            }
        }
        c.prepare_cached("DELETE FROM media_seen WHERE col = ?1 AND loc = ?2")
            .map_err(sql)?
            .execute(params![col, location])
            .map_err(sql)?;
        Ok(doomed.len())
    })
}

/// 本机待发的条数（诊断 / 测试）。
pub fn pending_count(t: &Truth<'_>, col: i64) -> Result<i64, String> {
    t.conn()
        .prepare_cached("SELECT COUNT(*) FROM media_at WHERE col = ?1 AND pend = 1")
        .map_err(sql)?
        .query_row([col], |r| r.get(0))
        .map_err(sql)
}

#[cfg(test)]
#[path = "media_tests.rs"]
mod tests;
