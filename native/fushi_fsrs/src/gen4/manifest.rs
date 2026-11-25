//! 协议 4 的媒体清单（设计 §4.5、D18；实现拆分 G8-3）：每台设备在每个位置上写自己的清单增量文件
//! `v4/devices/<dev>/mf-<gen12>-<tag8>.bin`（文件名见 [super::location::manifest_file_name]），记「这个内容哈希在这个媒体
//! 目录里 在 / 不在 / 可疑」，每条带 HLC。跨设备、跨文件按内容哈希取 HLC 最大的那条（[Fact::beats]）——**不取并集**：
//! 协议 3 的 MediaAt 有「不在 / 可疑」，取并集会让被外部删掉的媒体永远显示为在、上传方因此跳过上传。
//!
//! 纯编解码，不碰 SQLite、**没有接进任何同步路径**。本机缓存与读写 API 在 `crate::store::gen4::media`。
//!
//! ```text
//! "FMF4" | ver u8 = 1 | flags u8（保留，必须为 0）| collection[16] | device[16] | loc[16] | gen uv（>= 1）
//! | ndev uv | dev[16] × ndev                       HLC 的设备表：严格升序、每个都被至少一条用到
//! | nsec uv | 节 × nsec                             按目录名字节序严格升序
//! | sig[64]                                        Ed25519( SIGN_DOMAIN || 前面全部字节 )，作者（device）的签名钥匙
//!
//! 节    folder str | sflags u8（bit0 listed；其余必须为 0）| n uv | 条 × n（按 sha 严格升序）
//!       没有条目的节只在 listed 时允许（「我把这个目录完整列过了」本身就是事实）
//! 条    sha[32] | state u8（0 不在 / 1 在 / 2 可疑）| wall iv | logical uv | dev_ix uv（设备表下标）
//! ```
//!
//! - 只有一种字节形：varint 最短形、所有集合按键严格升序、设备表无多余项；解码器只收编码器写得出的字节。
//! - `loc` 是这个位置的 loc 标记（D17，`v4/loc/<uuidv7>`）之一，进签名：清单被原样拷到别的位置时读者认得出（loc 不属于
//!   那个位置的标记集合），不会把 A 位置的「在」当成 B 位置的。`collection` 同理防跨集合挪用。
//! - 目录（`folder`）就是位置上的媒体目录：明文 `media`，加密位置 `media-e/<密钥指纹>`（换钥匙 = 换目录 = 全部按新钥匙
//!   重传，所以「在不在」必须按目录分开记）。目录名在加密位置上本来就是明文的文件路径、内容哈希也就是那里的文件名，
//!   清单不比位置上已有的文件名多泄露什么，所以清单不加密。
//! - 一台设备的多个增量可以合并成一个更大代号的文件（[Manifest::absorb]）再删掉旧的；合并的结果是旧的那几份的上界，
//!   读者无论先看到哪几份，按 [Fact::beats] 合起来都相同（交换、结合、幂等）。
//! - 同一 HLC 不同状态（只会来自坏掉的写者）的决胜：不在 > 可疑 > 在——宁可多传一次，也不让「在」把真实的缺失盖住。

use std::collections::{BTreeMap, BTreeSet};

use super::{iv_min, str_min, uv_min};
use crate::sync2::codec::{DResult, DecodeError, Reader, Writer};
use crate::sync2::hlc::Hlc;
use crate::sync2::id::Id;
use crate::sync2::keys::{DeviceKey, verify};

pub const MAGIC: &[u8; 4] = b"FMF4";
pub const VERSION: u8 = 1;
/// 签名原文的域前缀（与 head 的 `fushi-srs-head/4\n`、段的 blake3 摘要都不同形）。
pub const SIGN_DOMAIN: &[u8] = b"fushi-srs-mf/4\n";
/// 目录名的字节上限。
pub const MAX_FOLDER: usize = 256;
/// 明文媒体目录名（与 Dart `kSrsMediaFolder` 相同）。
pub const PLAIN_FOLDER: &str = "media";
/// 加密媒体目录的前缀（与 Dart `kSrsSealedMediaFolder` 相同；完整目录名 = `media-e/<密钥指纹>`）。
pub const SEALED_FOLDER_PREFIX: &str = "media-e/";

const SEC_LISTED: u8 = 1;
/// 一条最少占的字节（sha 32 + state 1 + wall 1 + logical 1 + dev_ix 1）：按剩余字节先卡住条数，防伪造的大数撑爆内存。
const ENTRY_MIN: usize = 36;
/// 一节最少占的字节（folder 至少 1+5、sflags 1、n 1）。
const SECTION_MIN: usize = 8;

/// 一个内容哈希在一个媒体目录里的状态。编码值与协议 3 `sync2_media_at.present` 相同（迁移播种直接对上）。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum MediaState {
    Absent,
    Present,
    /// 在、但有设备下载到的字节与内容哈希对不上（截断、网盘占位、被改坏）：不删、不落地，持有原文的设备覆盖重传。
    Suspect,
}

impl MediaState {
    pub fn code(self) -> u8 {
        match self {
            MediaState::Absent => 0,
            MediaState::Present => 1,
            MediaState::Suspect => 2,
        }
    }

    pub fn of_code(c: u8) -> Option<MediaState> {
        match c {
            0 => Some(MediaState::Absent),
            1 => Some(MediaState::Present),
            2 => Some(MediaState::Suspect),
            _ => None,
        }
    }

    /// 同一 HLC 时的决胜次序（大者胜）：不在 > 可疑 > 在。
    fn tie_rank(self) -> u8 {
        match self {
            MediaState::Present => 0,
            MediaState::Suspect => 1,
            MediaState::Absent => 2,
        }
    }
}

/// 一条事实：状态 + 记下它时作者的 HLC。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Fact {
    pub state: MediaState,
    pub hlc: Hlc,
}

impl Fact {
    /// D18：HLC 大者胜；HLC 相同按 [MediaState::tie_rank]。是全序，所以合并与到达顺序无关。
    pub fn beats(&self, other: &Fact) -> bool {
        (self.hlc, self.state.tie_rank()) > (other.hlc, other.state.tie_rank())
    }
}

/// 把 [fact] 合进 [map]：没有或胜过现有的才换。返回换没换。
pub fn merge_fact(map: &mut BTreeMap<[u8; 32], Fact>, sha: [u8; 32], fact: Fact) -> bool {
    match map.get(&sha) {
        Some(cur) if !fact.beats(cur) => false,
        _ => {
            map.insert(sha, fact);
            true
        }
    }
}

/// 媒体目录名是否合法：`media`，或 `media-e/<指纹>`（指纹非空、只含字母数字与 `-` / `_`、不超过 128 字节）。
pub fn valid_folder(f: &str) -> bool {
    if f == PLAIN_FOLDER {
        return true;
    }
    f.strip_prefix(SEALED_FOLDER_PREFIX).is_some_and(|fp| {
        !fp.is_empty()
            && fp.len() <= 128
            && fp
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    })
}

/// 清单里一个媒体目录的部分。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Section {
    /// 作者对这个目录做过一次完整列举（协议 3 的 SEEDED）：读者见过它就不必再为这个目录列目录。
    pub listed: bool,
    pub entries: BTreeMap<[u8; 32], Fact>,
}

/// 一份清单文件。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Manifest {
    pub collection: Id,
    /// 作者（签名者，也是文件所在的设备目录）。
    pub device: Id,
    /// 这个位置的 loc 标记之一（D17）。
    pub loc: Id,
    /// 代号（文件名里的 `gen12`）：同一作者在同一位置上严格递增，合并出的文件取比被合并者都大的号。
    pub gen: u64,
    /// 目录名 → 节。
    pub sections: BTreeMap<String, Section>,
}

/// 解码 / 验签失败。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ManifestError {
    Corrupt(String),
    BadSignature,
}

impl std::fmt::Display for ManifestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ManifestError::Corrupt(e) => write!(f, "media manifest corrupt: {e}"),
            ManifestError::BadSignature => f.write_str("media manifest signature mismatch"),
        }
    }
}

impl From<DecodeError> for ManifestError {
    fn from(e: DecodeError) -> Self {
        ManifestError::Corrupt(e.0.to_owned())
    }
}

/// 文件名里的标签：整个文件（含签名）的 blake3 前 4 字节，小写十六进制。读者核对它，改名 / 换内容的文件认得出。
pub fn tag_of(bytes: &[u8]) -> String {
    blake3::hash(bytes).as_bytes()[..4]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

impl Manifest {
    pub fn new(collection: Id, device: Id, loc: Id, gen: u64) -> Manifest {
        Manifest {
            collection,
            device,
            loc,
            gen,
            sections: BTreeMap::new(),
        }
    }

    /// 一条都没有、也没有 listed 的节。
    pub fn is_empty(&self) -> bool {
        self.sections
            .values()
            .all(|s| !s.listed && s.entries.is_empty())
    }

    /// 条目总数。
    pub fn len(&self) -> usize {
        self.sections.values().map(|s| s.entries.len()).sum()
    }

    /// 把 [other] 的内容合进来（listed 取或，条目按 [Fact::beats]）。头部（作者、代号、loc）不动，由调用方定。
    /// 用于把同一作者的几份增量合并成一份（合并结果是它们的上界，读者看到哪几份都一样）。
    pub fn absorb(&mut self, other: &Manifest) {
        for (folder, sec) in &other.sections {
            let mine = self.sections.entry(folder.clone()).or_default();
            mine.listed |= sec.listed;
            for (sha, fact) in &sec.entries {
                merge_fact(&mut mine.entries, *sha, *fact);
            }
        }
    }

    fn check(&self) -> Result<(), String> {
        if self.gen == 0 {
            return Err("media manifest: gen must be >= 1".into());
        }
        for (folder, sec) in &self.sections {
            if folder.len() > MAX_FOLDER || !valid_folder(folder) {
                return Err(format!("media manifest: bad folder {folder:?}"));
            }
            if !sec.listed && sec.entries.is_empty() {
                return Err(format!("media manifest: empty section {folder:?}"));
            }
        }
        Ok(())
    }

    /// 签名并编码。[signer] 必须是 [Manifest::device] 的签名钥匙（否则读者验不过）。返回 (文件字节, 文件名)。
    pub fn encode(&self, signer: &DeviceKey) -> Result<(Vec<u8>, String), String> {
        self.check()?;
        let devs: Vec<Id> = self
            .sections
            .values()
            .flat_map(|s| s.entries.values().map(|f| f.hlc.device))
            .collect::<BTreeSet<Id>>()
            .into_iter()
            .collect();
        let ix: BTreeMap<Id, u64> = devs
            .iter()
            .enumerate()
            .map(|(i, d)| (*d, i as u64))
            .collect();
        let mut w = Writer::with_capacity(64 + devs.len() * 16 + self.len() * 44);
        w.raw(MAGIC);
        w.u8(VERSION);
        w.u8(0);
        self.collection.write(&mut w);
        self.device.write(&mut w);
        self.loc.write(&mut w);
        w.uv(self.gen);
        w.uv(devs.len() as u64);
        for d in &devs {
            d.write(&mut w);
        }
        w.uv(self.sections.len() as u64);
        for (folder, sec) in &self.sections {
            w.str(folder);
            w.u8(if sec.listed { SEC_LISTED } else { 0 });
            w.uv(sec.entries.len() as u64);
            for (sha, fact) in &sec.entries {
                w.raw(sha);
                w.u8(fact.state.code());
                w.iv(fact.hlc.wall);
                w.uv(u64::from(fact.hlc.logical));
                w.uv(ix[&fact.hlc.device]);
            }
        }
        let mut msg = SIGN_DOMAIN.to_vec();
        let body = w.into_vec();
        msg.extend_from_slice(&body);
        let sig = signer.sign(&msg);
        let mut out = body;
        out.extend_from_slice(&sig);
        let name = super::location::manifest_file_name(self.gen, &tag_of(&out));
        Ok((out, name))
    }
}

/// 解开、还没验签的清单：先拿作者去查公钥，再 [Opened::verify]。
pub struct Opened<'a> {
    pub manifest: Manifest,
    body: &'a [u8],
    sig: [u8; 64],
}

impl Opened<'_> {
    /// 用作者的公钥验签，过了才交出清单。
    pub fn verify(self, public: &[u8; 32]) -> Result<Manifest, ManifestError> {
        let mut msg = SIGN_DOMAIN.to_vec();
        msg.extend_from_slice(self.body);
        if !verify(public, &msg, &self.sig) {
            return Err(ManifestError::BadSignature);
        }
        Ok(self.manifest)
    }
}

/// 解码（严格：只收 [Manifest::encode] 写得出的字节）。不验签。
pub fn open(bytes: &[u8]) -> Result<Opened<'_>, ManifestError> {
    if bytes.len() < 64 {
        return Err(ManifestError::Corrupt("too short".into()));
    }
    let (body, sig) = bytes.split_at(bytes.len() - 64);
    let manifest = read_body(body)?;
    manifest.check().map_err(ManifestError::Corrupt)?;
    Ok(Opened {
        manifest,
        body,
        sig: sig.try_into().expect("64 bytes"),
    })
}

fn read_body(body: &[u8]) -> DResult<Manifest> {
    let mut r = Reader::new(body);
    if r.raw(4)? != MAGIC {
        return Err(DecodeError("manifest magic"));
    }
    if r.u8()? != VERSION {
        return Err(DecodeError("manifest version"));
    }
    if r.u8()? != 0 {
        return Err(DecodeError("manifest flags"));
    }
    let collection = Id::read(&mut r)?;
    let device = Id::read(&mut r)?;
    let loc = Id::read(&mut r)?;
    let gen = uv_min(&mut r)?;
    let ndev = count(&mut r, 16)?;
    let mut devs = Vec::with_capacity(ndev);
    for _ in 0..ndev {
        let d = Id::read(&mut r)?;
        if devs.last().is_some_and(|p: &Id| *p >= d) {
            return Err(DecodeError("manifest device table not canonical"));
        }
        devs.push(d);
    }
    let mut used = vec![false; ndev];
    let nsec = count(&mut r, SECTION_MIN)?;
    let mut sections: BTreeMap<String, Section> = BTreeMap::new();
    for _ in 0..nsec {
        let folder = str_min(&mut r)?;
        if sections
            .last_key_value()
            .is_some_and(|(p, _)| p.as_bytes() >= folder.as_bytes())
        {
            return Err(DecodeError("manifest sections not canonical"));
        }
        let sflags = r.u8()?;
        if sflags & !SEC_LISTED != 0 {
            return Err(DecodeError("manifest section flags"));
        }
        let n = count(&mut r, ENTRY_MIN)?;
        let mut entries = BTreeMap::new();
        let mut prev: Option<[u8; 32]> = None;
        for _ in 0..n {
            let sha: [u8; 32] = r.raw(32)?.try_into().map_err(|_| DecodeError("sha"))?;
            if prev.is_some_and(|p| p >= sha) {
                return Err(DecodeError("manifest entries not canonical"));
            }
            prev = Some(sha);
            let state = MediaState::of_code(r.u8()?).ok_or(DecodeError("manifest state"))?;
            let wall = iv_min(&mut r)?;
            let logical =
                u32::try_from(uv_min(&mut r)?).map_err(|_| DecodeError("manifest logical"))?;
            let i = usize::try_from(uv_min(&mut r)?).map_err(|_| DecodeError("dev_ix"))?;
            let device = *devs.get(i).ok_or(DecodeError("manifest dev_ix"))?;
            used[i] = true;
            entries.insert(
                sha,
                Fact {
                    state,
                    hlc: Hlc {
                        wall,
                        logical,
                        device,
                    },
                },
            );
        }
        sections.insert(
            folder.to_owned(),
            Section {
                listed: sflags & SEC_LISTED != 0,
                entries,
            },
        );
    }
    if !r.is_empty() {
        return Err(DecodeError("manifest trailing bytes"));
    }
    if used.iter().any(|u| !u) {
        return Err(DecodeError("manifest device table has an unused entry"));
    }
    Ok(Manifest {
        collection,
        device,
        loc,
        gen,
        sections,
    })
}

/// 读一个条数，并按「每项至少 [min] 字节」用剩余字节卡住上限。
fn count(r: &mut Reader<'_>, min: usize) -> DResult<usize> {
    let n = usize::try_from(uv_min(r)?).map_err(|_| DecodeError("count overflow"))?;
    if n > r.remaining().len() / min {
        return Err(DecodeError("manifest count exceeds the file"));
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gen4::{golden, unhex};

    fn id(b: u8) -> Id {
        Id([b; 16])
    }

    fn signer() -> DeviceKey {
        DeviceKey::from_seed(&[7; 32])
    }

    fn fact(state: MediaState, wall: i64, logical: u32, dev: u8) -> Fact {
        Fact {
            state,
            hlc: Hlc {
                wall,
                logical,
                device: id(dev),
            },
        }
    }

    pub(crate) fn sample() -> Manifest {
        let mut m = Manifest::new(id(0xc0), id(0xa1), id(0x10), 3);
        let plain = m.sections.entry(PLAIN_FOLDER.into()).or_default();
        plain.listed = true;
        plain.entries.insert(
            [1; 32],
            fact(MediaState::Present, 1_741_061_849_001, 0, 0xa1),
        );
        plain.entries.insert(
            [2; 32],
            fact(MediaState::Absent, 1_741_061_849_002, 3, 0x0d),
        );
        let sealed = m.sections.entry("media-e/ab12cd".into()).or_default();
        sealed
            .entries
            .insert([3; 32], fact(MediaState::Suspect, -5, 0, 0xa1));
        m.sections.insert(
            "media-e/ff".into(),
            Section {
                listed: true,
                entries: BTreeMap::new(),
            },
        );
        m
    }

    const GOLDEN: &str = "464d46340100c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a11010101010101010101010101010101003020d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0da1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a103056d656469610102010101010101010101010101010101010101010101010101010101010101010101d2fefbf5ab650001020202020202020202020202020202020202020202020202020202020202020200d4fefbf5ab6503000e6d656469612d652f61623132636400010303030303030303030303030303030303030303030303030303030303030303020900010a6d656469612d652f66660100607f1b8890f11c0c535706114827976021e41de67f7605496596f551b26a7377c19a6639a851d17e15334b087d31e9ed63ef935e5e70d13af5ca2e302490b102";

    /// 黄金向量：字节布局冻结。改动任何一位都是格式变更（要升 VERSION）。
    #[test]
    fn golden_vector() {
        let (bytes, name) = sample().encode(&signer()).unwrap();
        golden("manifest", &bytes, GOLDEN);
        assert_eq!(name, format!("mf-000000000003-{}.bin", tag_of(&bytes)));
        let back = open(&bytes).unwrap().verify(&signer().public()).unwrap();
        assert_eq!(back, sample());
        assert_eq!(back.encode(&signer()).unwrap().0, bytes);
        // 冻结的字节本身也解得开（不依赖编码器）。
        assert_eq!(open(&unhex(GOLDEN)).unwrap().manifest, sample());
    }

    #[test]
    fn the_signature_covers_every_byte_and_needs_the_author_key() {
        let (bytes, _) = sample().encode(&signer()).unwrap();
        let public = signer().public();
        for i in 0..bytes.len() {
            let mut b = bytes.clone();
            b[i] ^= 0x01;
            match open(&b) {
                Err(_) => {}
                Ok(o) => assert!(o.verify(&public).is_err(), "flip at {i} accepted"),
            }
        }
        let other = DeviceKey::from_seed(&[8; 32]).public();
        assert_eq!(
            open(&bytes).unwrap().verify(&other).unwrap_err(),
            ManifestError::BadSignature
        );
        // 去掉签名域前缀签出来的字节（别的协议的签名形态）验不过。
        let body = &bytes[..bytes.len() - 64];
        let mut forged = body.to_vec();
        forged.extend_from_slice(&signer().sign(body));
        assert_eq!(
            open(&forged).unwrap().verify(&public).unwrap_err(),
            ManifestError::BadSignature
        );
    }

    /// 只有一种字节形：非规范的写法（乱序、重复、多余设备、空节、未知位、尾巴）一律拒。
    #[test]
    fn non_canonical_forms_are_refused() {
        let s = signer();
        // 手工拼一个 body，再签上（签名正确也要拒：拒在解码，不靠签名）。
        let build = |f: &dyn Fn(&mut Writer)| -> Vec<u8> {
            let mut w = Writer::new();
            w.raw(MAGIC);
            w.u8(VERSION);
            f(&mut w);
            let body = w.into_vec();
            let mut msg = SIGN_DOMAIN.to_vec();
            msg.extend_from_slice(&body);
            let mut out = body;
            out.extend_from_slice(&s.sign(&msg));
            out
        };
        let head = |w: &mut Writer, flags: u8, gen: u64| {
            w.u8(flags);
            id(0xc0).write(w);
            id(0xa1).write(w);
            id(0x10).write(w);
            w.uv(gen);
        };
        let entry = |w: &mut Writer, sha: u8, state: u8, dev_ix: u64| {
            w.raw(&[sha; 32]);
            w.u8(state);
            w.iv(5);
            w.uv(0);
            w.uv(dev_ix);
        };
        let ok = build(&|w| {
            head(w, 0, 1);
            w.uv(1);
            id(1).write(w);
            w.uv(1);
            w.str("media");
            w.u8(0);
            w.uv(2);
            entry(w, 1, 1, 0);
            entry(w, 2, 0, 0);
        });
        assert!(open(&ok).unwrap().verify(&s.public()).is_ok());
        let bad: Vec<(&str, Vec<u8>)> = vec![
            (
                "header flags",
                build(&|w| {
                    head(w, 1, 1);
                    w.uv(0);
                    w.uv(0);
                }),
            ),
            (
                "gen 0",
                build(&|w| {
                    head(w, 0, 0);
                    w.uv(0);
                    w.uv(0);
                }),
            ),
            (
                "unused device",
                build(&|w| {
                    head(w, 0, 1);
                    w.uv(1);
                    id(1).write(w);
                    w.uv(0);
                }),
            ),
            (
                "device order",
                build(&|w| {
                    head(w, 0, 1);
                    w.uv(2);
                    id(2).write(w);
                    id(1).write(w);
                    w.uv(1);
                    w.str("media");
                    w.u8(0);
                    w.uv(2);
                    entry(w, 1, 1, 0);
                    entry(w, 2, 1, 1);
                }),
            ),
            (
                "entry order",
                build(&|w| {
                    head(w, 0, 1);
                    w.uv(1);
                    id(1).write(w);
                    w.uv(1);
                    w.str("media");
                    w.u8(0);
                    w.uv(2);
                    entry(w, 2, 1, 0);
                    entry(w, 1, 1, 0);
                }),
            ),
            (
                "duplicate sha",
                build(&|w| {
                    head(w, 0, 1);
                    w.uv(1);
                    id(1).write(w);
                    w.uv(1);
                    w.str("media");
                    w.u8(0);
                    w.uv(2);
                    entry(w, 1, 1, 0);
                    entry(w, 1, 0, 0);
                }),
            ),
            (
                "bad state",
                build(&|w| {
                    head(w, 0, 1);
                    w.uv(1);
                    id(1).write(w);
                    w.uv(1);
                    w.str("media");
                    w.u8(0);
                    w.uv(1);
                    entry(w, 1, 3, 0);
                }),
            ),
            (
                "dev_ix out of range",
                build(&|w| {
                    head(w, 0, 1);
                    w.uv(1);
                    id(1).write(w);
                    w.uv(1);
                    w.str("media");
                    w.u8(0);
                    w.uv(1);
                    entry(w, 1, 1, 1);
                }),
            ),
            (
                "empty section",
                build(&|w| {
                    head(w, 0, 1);
                    w.uv(0);
                    w.uv(1);
                    w.str("media");
                    w.u8(0);
                    w.uv(0);
                }),
            ),
            (
                "section flags",
                build(&|w| {
                    head(w, 0, 1);
                    w.uv(0);
                    w.uv(1);
                    w.str("media");
                    w.u8(2);
                    w.uv(0);
                }),
            ),
            (
                "section order",
                build(&|w| {
                    head(w, 0, 1);
                    w.uv(0);
                    w.uv(2);
                    w.str("media-e/x");
                    w.u8(1);
                    w.uv(0);
                    w.str("media");
                    w.u8(1);
                    w.uv(0);
                }),
            ),
            (
                "bad folder",
                build(&|w| {
                    head(w, 0, 1);
                    w.uv(0);
                    w.uv(1);
                    w.str("../media");
                    w.u8(1);
                    w.uv(0);
                }),
            ),
            (
                "huge count",
                build(&|w| {
                    head(w, 0, 1);
                    w.uv(u64::from(u32::MAX));
                }),
            ),
            ("trailing", {
                let mut b = ok.clone();
                b.insert(b.len() - 64, 0);
                b
            }),
            (
                "non-minimal gen",
                build(&|w| {
                    w.u8(0);
                    id(0xc0).write(w);
                    id(0xa1).write(w);
                    id(0x10).write(w);
                    w.raw(&[0x81, 0x00]);
                    w.uv(0);
                    w.uv(0);
                }),
            ),
        ];
        for (what, b) in bad {
            assert!(open(&b).is_err(), "{what} accepted");
        }
        // 版本 / 魔数不对。
        let mut v2 = ok.clone();
        v2[4] = 2;
        assert!(open(&v2).is_err());
        assert!(open(b"FSG4").is_err());
        assert!(open(&[]).is_err());
    }

    fn sec(m: &mut Manifest) -> &mut Section {
        m.sections.entry(PLAIN_FOLDER.into()).or_default()
    }

    /// D18：合并与到达顺序无关（交换、结合、幂等），「不在」不会被并集吃掉。
    #[test]
    fn merging_takes_the_largest_hlc_in_any_order() {
        let mut a = Manifest::new(id(0xc0), id(0xa1), id(0x10), 1);
        let mut b = Manifest::new(id(0xc0), id(0xb2), id(0x10), 1);
        let mut c = Manifest::new(id(0xc0), id(0xc3), id(0x10), 1);
        // sha 1：a 说在（早），b 说不在（晚）→ 不在。
        sec(&mut a)
            .entries
            .insert([1; 32], fact(MediaState::Present, 10, 0, 0xa1));
        sec(&mut b)
            .entries
            .insert([1; 32], fact(MediaState::Absent, 20, 0, 0xb2));
        // sha 2：同 wall，logical 大者胜。
        sec(&mut b)
            .entries
            .insert([2; 32], fact(MediaState::Present, 30, 1, 0xb2));
        sec(&mut c)
            .entries
            .insert([2; 32], fact(MediaState::Suspect, 30, 0, 0xc3));
        // sha 3：同 HLC（坏写者）不同状态 → 不在。
        sec(&mut a)
            .entries
            .insert([3; 32], fact(MediaState::Present, 40, 0, 0xa1));
        sec(&mut c)
            .entries
            .insert([3; 32], fact(MediaState::Absent, 40, 0, 0xa1));
        c.sections.entry("media-e/k".into()).or_default().listed = true;
        let all = [a.clone(), b.clone(), c.clone()];
        let orders: [[usize; 3]; 6] = [
            [0, 1, 2],
            [0, 2, 1],
            [1, 0, 2],
            [1, 2, 0],
            [2, 0, 1],
            [2, 1, 0],
        ];
        let mut results = Vec::new();
        for o in orders {
            let mut m = Manifest::new(id(0xc0), id(0xee), id(0x10), 9);
            for i in o {
                m.absorb(&all[i]);
                m.absorb(&all[i]);
            }
            results.push(m);
        }
        assert!(results.windows(2).all(|w| w[0] == w[1]));
        let m = &results[0];
        let p = &m.sections[PLAIN_FOLDER].entries;
        assert_eq!(p[&[1; 32]].state, MediaState::Absent);
        assert_eq!(p[&[2; 32]].state, MediaState::Present);
        assert_eq!(p[&[3; 32]].state, MediaState::Absent);
        assert!(m.sections["media-e/k"].listed);
        assert!(!m.sections[PLAIN_FOLDER].listed);
    }

    #[test]
    fn writer_refuses_what_readers_would_refuse() {
        let mut m = sample();
        m.gen = 0;
        assert!(m.encode(&signer()).is_err());
        let mut m = sample();
        m.sections.insert(
            "media-e/".into(),
            Section {
                listed: true,
                entries: BTreeMap::new(),
            },
        );
        assert!(m.encode(&signer()).is_err());
        let mut m = sample();
        m.sections.insert("media-e/zz".into(), Section::default());
        assert!(m.encode(&signer()).is_err());
        assert!(Manifest::new(id(1), id(2), id(3), 1).is_empty());
        assert!(!sample().is_empty());
        for f in ["media", "media-e/0a1b", "media-e/A_b-9"] {
            assert!(valid_folder(f), "{f}");
        }
        for f in [
            "",
            "Media",
            "media/",
            "media-e",
            "media-e/",
            "media-e/a/b",
            "media-e/a#b",
            "media2",
        ] {
            assert!(!valid_folder(f), "{f}");
        }
    }
}
