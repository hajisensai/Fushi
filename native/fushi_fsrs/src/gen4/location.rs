//! 协议 4 的位置布局（设计 §4.1、§4.3、§4.5；实现拆分 G8-1，总规划 §1.7 冻结）：位置目录下每个文件叫什么、放在哪、
//! 由纯函数决定内容的那几个文件（新根 `meta.json`、旧根围栏、墓碑 head、跳转提示）逐字节是什么。
//!
//! 纯函数，不碰 SQLite、**没有接进任何同步路径**：协议 3 的读写一个字节不变。这里的名字与字节是持久化契约，黄金向量冻结。
//!
//! 位置目录（`fushi-srs/<位置目录名>/`）下的布局：
//!
//! ```text
//! v4/meta.json                                              新根 meta（[meta4]，纯函数，无时间戳）
//! v4/joined.json                                            跳转提示（[joined4]，不签名，只当提示）
//! v4/loc/<uuidv7>                                           零字节 loc 标记，只增不删
//! v4/devices/<dev>/head-<gen12>-<tag8>.json                 Head4，作者自写
//! v4/devices/<dev>/seg-<first12>-<last12>-<tag8>.bin        原生段 FSG4，作者自写
//! v4/devices/<author>/rly-<first12>-<last12>-<tag8>.bin     协议 4 中继件（转发者写）
//! v4/devices/<author>/rhd-<gen12>-<tag8>.json               被转发的 head（独立前缀，永不覆盖 head-）
//! v4/devices/<uploader>/hrt-<src8>-<olddev>-<first12>-<last12>-<tag8>.bin
//!                                                           承袭段 FSH4，放在上传者自己的目录
//! v4/devices/<dev>/mf-<gen12>-<tag8>.bin                    媒体清单增量
//! v4/devices/<dev>/profile.json                             profile 说明文件（字段沿用 srsPublishProfileInfo）
//! v3/meta.json                                              旧根围栏（[fence3]，minReader 4）
//! v3/devices/<墓碑设备>/head-000000000001-00000000.json     墓碑 head（[tombstone_head]，协议 3 形状、minReader 4）
//! ```
//!
//! 承袭段不用 `seg-` 前缀、也不放在旧设备目录下：互联 host 把 `devices/<设备>/seg-…` 当成那台设备自己写的段
//! （`packages/fushi_engine/lib/srs/sync2/srs_host_directory.dart`），`hrt-` / `rly-` / `rhd-` / `mf-` 都不命中它。
//!
//! 命名区分：这里的「墓碑 head」（`tombstone_head`）是位置上的一个文件；本机的「墓碑库」（`tombstone_db`，G7）是另一样东西。
//!
//! 名字守卫（[top_level_name_allowed] / [guard_location_path]）：`v3/`、`v4/` 的**顶层**不得出现 `cursor`、`batch-*`、
//! `snapshot-*`、`probe`、`profile.json`。旧版本把 `v3` / `v2` 以外的子目录当成写入者目录（v3.3.0
//! `srs_profile_link.dart` 读 `<写入者>/profile.json`；v3.0.1 的旧事件同步在写入者目录里认 `batch-*` / `snapshot-*` /
//! `cursor` / `probe`，`packages/fushi_srs/lib/src/sync/sync_files.dart`），这些名字一旦出现在 `v4/` 顶层，旧版本就会把它
//! 当成自己的格式来读。

use serde_json::{Map, Value};

use super::head::{Head4, canonical};
use super::heritage::HeritageHeader;
use super::segment::NativeHeader;
use super::{MIN_READER, PROTOCOL};
use crate::store::sync2::collection_of;
use crate::store::sync2::config::SRS_NAMESPACE;
use crate::sync2::id::Id;
use crate::sync2::keys::DeviceKey;
use crate::sync2::segment::{
    CHAIN_ZERO, Head, chain_tag, head_file_name, relay_file_name, segment_file_name,
};
use crate::sync2::vv::Vv;

/// 新根目录名。
pub const NEW_ROOT: &str = "v4";
/// 旧根（协议 2 / 3）目录名。
pub const OLD_ROOT: &str = "v3";
/// 根下的 meta 文件名（新旧根同名）。
pub const META_FILE: &str = "meta.json";
/// 新根下的跳转提示文件名。
pub const JOINED_FILE: &str = "joined.json";
/// 设备目录下的 profile 说明文件名。
pub const PROFILE_FILE: &str = "profile.json";
/// 新根下的 loc 标记目录。
pub const LOC_DIR: &str = "loc";
/// 根下的设备目录。
pub const DEVICES_DIR: &str = "devices";
/// 新根 meta 外形的标记（与协议号无关；以后的协议抬高 `minReader`、保留 `fmt`）。
pub const META_FMT: &str = "fushi-srs-meta/4";
/// 旧根围栏里指向新根的提示字段值。
pub const FENCE_MOVED: &str = NEW_ROOT;
/// 墓碑 head 的人读名（协议 3 的读者在报需要升级前不会显示它；写给翻目录的人看）。
pub const TOMBSTONE_NAME: &str = "fushi-srs tombstone (upgrade required)";
/// 墓碑 head 的代号（文件名里的 `gen`）。
pub const TOMBSTONE_GEN: u64 = 1;

/// 墓碑 head 签名钥匙的种子派生上下文。钥匙是**公开**的：墓碑只是围栏，谁都能写出同一个文件，签名只为让协议 3 的
/// `Head::decode` 验得过、走到 `minReader` 检查。
const TOMBSTONE_KEY_CONTEXT: &str = "fushi-srs 2026-11-15 tombstone head signing key v4";

// ---------------------------------------------------------------- 新根 meta

/// 媒体目录所在的根（存量集合继续用 `v3/media`、`v3/media-e/<指纹>/`，不重传）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaRoot {
    V3,
    V4,
}

impl MediaRoot {
    pub fn as_str(self) -> &'static str {
        match self {
            MediaRoot::V3 => "v3",
            MediaRoot::V4 => "v4",
        }
    }
}

/// 新根 `v4/meta.json`：规范 JSON（键按字节序、无空白），只有
/// `{"collection":<集合标识>,"fmt":"fushi-srs-meta/4","kdf":<原样抄的对象>?,"media":"v3"|"v4","minReader":4,"v":4}`。
///
/// 没有时间戳：两台设备同时建新根时写出的字节相同，谁覆盖谁都一样（设计 §4.1）。`kdf` 从旧根原样抄来，只当参数载体；
/// 不是对象、或含非整数数值时出错（规范 JSON 只许整数）。
pub fn meta4(collection: &Id, kdf: Option<&Value>, media: MediaRoot) -> Result<Vec<u8>, String> {
    let mut m = Map::new();
    m.insert("collection".into(), Value::from(collection.text()));
    m.insert("fmt".into(), Value::from(META_FMT));
    if let Some(k) = kdf {
        if !k.is_object() {
            return Err("meta4: kdf is not an object".into());
        }
        m.insert("kdf".into(), k.clone());
    }
    m.insert("media".into(), Value::from(media.as_str()));
    m.insert("minReader".into(), Value::from(MIN_READER));
    m.insert("v".into(), Value::from(PROTOCOL));
    canonical(&Value::Object(m))
}

/// [check_meta4] 不通过的原因。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MetaMismatch {
    /// 不是本版本认得的新根 meta（不是 JSON 对象、缺 `fmt` 或 `fmt` 不对——旧根围栏也在这里）。
    ///
    /// 调用方只能停下报错，**不得**当成「可以覆盖重建」：位置上已有的东西可能是更新的版本以本版本不认得的外形写的。
    NotMeta(String),
    /// 是更新的版本写的，要求更高的读者。
    NeedsUpgrade { min_reader: u32 },
    /// 外形对，这些字段与本机算出的不一致（键名升序）。
    Fields(Vec<String>),
}

impl std::fmt::Display for MetaMismatch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MetaMismatch::NotMeta(m) => write!(f, "not a protocol 4 meta: {m}"),
            MetaMismatch::NeedsUpgrade { min_reader } => {
                write!(f, "meta needs reader version {min_reader}")
            }
            MetaMismatch::Fields(k) => write!(f, "meta fields differ: {}", k.join(",")),
        }
    }
}

fn object_of(bytes: &[u8]) -> Result<Map<String, Value>, String> {
    match serde_json::from_slice::<Value>(bytes) {
        Ok(Value::Object(m)) => Ok(m),
        Ok(_) => Err("not an object".into()),
        Err(_) => Err("not json".into()),
    }
}

/// 读到位置上已有的新根 meta 时，与本机算出的 [want]（[meta4] 的输出）按字段比（设计 §4.1）。
///
/// 先看 `minReader`（任何 JSON 数值——整数、`5.0`、`4.5` 都算——比本版本新 = [MetaMismatch::NeedsUpgrade]，不论 `fmt`），
/// 再看 `fmt`，最后逐字段比（两边键的并集，多一个、少一个、值不同都算）。按解析后的值比，不要求位置上的字节是规范形——
/// 不一致就停下报错由调用方做；三种错误都只能停下，见 [MetaMismatch::NotMeta]。
pub fn check_meta4(bytes: &[u8], want: &[u8]) -> Result<(), MetaMismatch> {
    let got = object_of(bytes).map_err(MetaMismatch::NotMeta)?;
    if let Some(mr) = got
        .get("minReader")
        .and_then(Value::as_f64)
        .filter(|&mr| mr > f64::from(MIN_READER))
    {
        // 非整数向上取；`as` 对超界与非有限值饱和到 u32::MAX。
        return Err(MetaMismatch::NeedsUpgrade {
            min_reader: mr.ceil() as u32,
        });
    }
    if got.get("fmt").and_then(Value::as_str) != Some(META_FMT) {
        return Err(MetaMismatch::NotMeta("missing fmt".into()));
    }
    let want = object_of(want).map_err(|m| MetaMismatch::NotMeta(format!("want: {m}")))?;
    let mut keys: Vec<&String> = got.keys().chain(want.keys()).collect();
    keys.sort();
    keys.dedup();
    let differ: Vec<String> = keys
        .into_iter()
        .filter(|k| got.get(*k) != want.get(*k))
        .cloned()
        .collect();
    if differ.is_empty() {
        Ok(())
    } else {
        Err(MetaMismatch::Fields(differ))
    }
}

// ---------------------------------------------------------------- 旧根围栏与墓碑 head

/// 旧根围栏 `v3/meta.json`：`{"collection":<协议 3 集合标识>,"kdf":<同新根>?,"minReader":4,"moved":"v4","v":3}`，
/// 规范 JSON，是 ([dir], 新根 meta) 的纯函数（设计 §4.3；新集合同样预先写，D15）。
///
/// `collection` 是协议 3 的集合标识 `v5(NS, "sync2/collection/<dir>")`（存量集合的现值，设计 §5.1）。协议 2 / 3 的握手
/// 读到 `minReader` 大于自己就整位置不碰、报需要升级。[v4_meta] 必须是新根 meta（`fmt` 对），`kdf` 原样抄过来。
pub fn fence3(dir: &str, v4_meta: &[u8]) -> Result<Vec<u8>, String> {
    let meta = object_of(v4_meta).map_err(|m| format!("fence3: v4 meta {m}"))?;
    if meta.get("fmt").and_then(Value::as_str) != Some(META_FMT) {
        return Err("fence3: not a protocol 4 meta".into());
    }
    let mut m = Map::new();
    m.insert("collection".into(), Value::from(collection_of(dir).text()));
    if let Some(k) = meta.get("kdf") {
        m.insert("kdf".into(), k.clone());
    }
    m.insert("minReader".into(), Value::from(MIN_READER));
    m.insert("moved".into(), Value::from(FENCE_MOVED));
    m.insert("v".into(), Value::from(3u32));
    canonical(&Value::Object(m))
}

/// 墓碑 head 的设备 ID：`v5(NS, "fushi-srs/tombstone/4/<dir>")`。
pub fn tombstone_device(dir: &str) -> Id {
    Id::v5(
        &Id::parse(SRS_NAMESPACE).expect("ns"),
        &format!("fushi-srs/tombstone/4/{dir}"),
    )
}

/// 墓碑 head 的签名钥匙（固定、公开）。
pub fn tombstone_key() -> DeviceKey {
    DeviceKey::from_seed(&blake3::derive_key(TOMBSTONE_KEY_CONTEXT, b""))
}

/// 墓碑 head：(相对位置目录的路径, 文件字节)，整个文件逐字节是 [dir] 的纯函数（设计 §4.3，所有者 2026-11-12 定为必需）。
///
/// 用协议 3 的 `Head::encode` 写：gen 1、seq 0、无段、链 0、`at` 0、`minReader 4`、`collection` = 协议 3 集合标识
/// （协议 3 的 `plan` 先按集合过滤、再看 `minReader`，集合不对就走不到升级判断），固定公开钥匙签名（Ed25519 签名是确定性的）。
/// 放在 `v3/devices/<墓碑设备>/` 下：旧根 `devices/` 因此永不为空，`meta.json` 暂时读不到时旧版本不会重建明文 meta。
/// 协议 4 的 `Head4::decode` 读它是 `NotProtocol4`。
pub fn tombstone_head(dir: &str) -> (String, Vec<u8>) {
    let key = tombstone_key();
    let head = Head {
        gen: TOMBSTONE_GEN,
        protocol: PROTOCOL,
        min_reader: MIN_READER,
        collection: collection_of(dir),
        device: tombstone_device(dir),
        public: key.public(),
        seq: 0,
        chain: CHAIN_ZERO,
        segments: Vec::new(),
        ack: Vv::new(),
        digest: String::new(),
        at_ms: 0,
        name: TOMBSTONE_NAME.to_owned(),
        ext: None,
    };
    let path = format!(
        "{OLD_ROOT}/{DEVICES_DIR}/{}/{}",
        head.device.text(),
        head.file_name()
    );
    (path, head.encode(&key))
}

// ---------------------------------------------------------------- 跳转提示

/// 跳转提示 `v4/joined.json`：`{"dir":<目标位置目录名>,"into":<目标集合标识>}`，规范 JSON，**不签名**——谁能写这个位置
/// 谁就能伪造它，读者只拿它当「去哪找」的提示，跟随的依据是目标根里受信设备签名的 `Join`（设计 §5.4）。
pub fn joined4(into: &Id, dir: &str) -> Result<Vec<u8>, String> {
    if !dir_name_ok(dir) {
        return Err("joined4: bad dir".into());
    }
    let mut m = Map::new();
    m.insert("dir".into(), Value::from(dir));
    m.insert("into".into(), Value::from(into.text()));
    canonical(&Value::Object(m))
}

/// 解跳转提示：只收 [joined4] 写得出的字节（规范 JSON、恰好两个键、规范 UUID 文本），否则 None。
pub fn parse_joined4(bytes: &[u8]) -> Option<(Id, String)> {
    let m = object_of(bytes).ok()?;
    if m.len() != 2 {
        return None;
    }
    let into = canonical_id(m.get("into")?.as_str()?)?;
    let dir = m.get("dir")?.as_str()?.to_owned();
    (joined4(&into, &dir).ok()? == bytes).then_some((into, dir))
}

/// 位置目录名可用：非空、不含路径分隔符、不是 `.` / `..`。
pub(crate) fn dir_name_ok(dir: &str) -> bool {
    !dir.is_empty() && dir != "." && dir != ".." && !dir.contains(['/', '\\'])
}

// ---------------------------------------------------------------- 新根里的文件名

/// 承袭段文件名：`hrt-<来源集合前 4 字节 hex>-<旧设备>-<first12>-<last12>-<链尾标签>.bin`，放在上传者目录
/// （`devices/<uploader>/`）。同一区间不论谁转译、谁上传，名字都相同（链尾标签取区间末尾的原链值）。
pub fn heritage_file_name(h: &HeritageHeader) -> String {
    heritage_name(
        &src8(&h.source),
        &h.device,
        h.first,
        h.last,
        &chain_tag(&h.last_chain),
    )
}

fn heritage_name(src8: &str, old: &Id, first: u64, last: u64, tag: &str) -> String {
    format!("hrt-{src8}-{}-{first:012}-{last:012}-{tag}.bin", old.text())
}

fn src8(source: &Id) -> String {
    source.0[..4].iter().map(|b| format!("{b:02x}")).collect()
}

/// 协议 4 中继件文件名：`rly-<first12>-<last12>-<链尾标签>.bin`，放在作者目录（与协议 3 同形，内容魔数不同）。
pub fn relay_name(h: &NativeHeader) -> String {
    relay_file_name(&h.file_name())
}

/// 被转发的 head 文件名：`rhd-<gen12>-<链尾标签>.json`（独立前缀：转发者永不覆盖作者自写的 `head-`，
/// 被转发的 head 也不当作位置证据，设计 §4.4）。
pub fn relay_head_name(h: &Head4) -> String {
    format!("rhd-{:012}-{}.json", h.gen, chain_tag(&h.chain))
}

/// 媒体清单增量文件名：`mf-<gen12>-<tag8>.bin`（[tag] 是 8 位小写十六进制，由清单的写入方定，G8-3）。
pub fn manifest_file_name(gen: u64, tag: &str) -> String {
    format!("mf-{gen:012}-{tag}.bin")
}

/// loc 标记的路径（相对新根）：`loc/<uuidv7>`。
pub fn loc_path(loc: &Id) -> String {
    format!("{LOC_DIR}/{}", loc.text())
}

/// 设备目录下某个文件的路径（相对新根）：`devices/<dev>/<name>`。
pub fn device_path(device: &Id, name: &str) -> String {
    format!("{DEVICES_DIR}/{}/{name}", device.text())
}

/// 新根里的一个文件（路径相对 `v4/`，与 Dart `SrsLocationStore` 的 folder 口径一致）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V4File {
    Meta,
    Joined,
    Loc(Id),
    Head {
        device: Id,
        gen: u64,
        tag: String,
    },
    Seg {
        device: Id,
        first: u64,
        last: u64,
        tag: String,
    },
    Relay {
        author: Id,
        first: u64,
        last: u64,
        tag: String,
    },
    RelayHead {
        author: Id,
        gen: u64,
        tag: String,
    },
    Heritage {
        uploader: Id,
        /// 来源集合的前 4 字节（8 位小写十六进制）。
        src8: String,
        old_device: Id,
        first: u64,
        last: u64,
        tag: String,
    },
    Manifest {
        device: Id,
        gen: u64,
        tag: String,
    },
    Profile {
        device: Id,
    },
}

impl V4File {
    /// 规范路径（相对 `v4/`）。[parse_v4_path] 只收这个函数写得出的路径。
    pub fn path(&self) -> String {
        match self {
            V4File::Meta => META_FILE.to_owned(),
            V4File::Joined => JOINED_FILE.to_owned(),
            V4File::Loc(id) => loc_path(id),
            V4File::Head { device, gen, tag } => device_path(device, &head_file_name(*gen, tag)),
            V4File::Seg {
                device,
                first,
                last,
                tag,
            } => device_path(device, &segment_file_name(*first, *last, tag)),
            V4File::Relay {
                author,
                first,
                last,
                tag,
            } => device_path(
                author,
                &relay_file_name(&segment_file_name(*first, *last, tag)),
            ),
            V4File::RelayHead { author, gen, tag } => {
                device_path(author, &format!("rhd-{gen:012}-{tag}.json"))
            }
            V4File::Heritage {
                uploader,
                src8,
                old_device,
                first,
                last,
                tag,
            } => device_path(
                uploader,
                &heritage_name(src8, old_device, *first, *last, tag),
            ),
            V4File::Manifest { device, gen, tag } => {
                device_path(device, &manifest_file_name(*gen, tag))
            }
            V4File::Profile { device } => device_path(device, PROFILE_FILE),
        }
    }

    /// 写这个文件的设备目录（顶层文件为 None）。
    pub fn device(&self) -> Option<Id> {
        match self {
            V4File::Meta | V4File::Joined | V4File::Loc(_) => None,
            V4File::Head { device, .. }
            | V4File::Seg { device, .. }
            | V4File::Manifest { device, .. }
            | V4File::Profile { device } => Some(*device),
            V4File::Relay { author, .. } | V4File::RelayHead { author, .. } => Some(*author),
            V4File::Heritage { uploader, .. } => Some(*uploader),
        }
    }
}

/// 规范 UUID 文本（小写、带连字符）→ Id；别的写法 None。
fn canonical_id(s: &str) -> Option<Id> {
    Id::parse(s).filter(|id| id.text() == s)
}

fn is_tag(s: &str) -> bool {
    s.len() == 8 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn is_v7(id: &Id) -> bool {
    id.0[6] >> 4 == 7 && id.0[8] & 0xc0 == 0x80
}

/// 十进制、只含数字（`parse::<u64>` 收 `+1`，这里不收）。
fn num(s: &str) -> Option<u64> {
    (!s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
        .then(|| s.parse().ok())
        .flatten()
}

/// `<a>-<b>-<tag>`：两个数 + 标签。
fn range_tag(rest: &str) -> Option<(u64, u64, String)> {
    let mut it = rest.splitn(3, '-');
    let (a, b, t) = (num(it.next()?)?, num(it.next()?)?, it.next()?);
    (a >= 1 && b >= a && is_tag(t)).then(|| (a, b, t.to_owned()))
}

/// `<gen>-<tag>`。
fn gen_tag(rest: &str) -> Option<(u64, String)> {
    let (g, t) = rest.split_once('-')?;
    let g = num(g)?;
    is_tag(t).then(|| (g, t.to_owned()))
}

/// 解新根里的一个路径（相对 `v4/`）。只收规范形（[V4File::path] 写得出的）：大写十六进制、不带连字符的 UUID、
/// 位数不对的数、`+` 号、多余的目录层都拒；loc 标记只收 UUIDv7。认不出的名字（包括协议 3 的旧名字、临时文件）给 None。
pub fn parse_v4_path(path: &str) -> Option<V4File> {
    if !path.is_ascii() {
        return None;
    }
    let file = parse_loose(path)?;
    (file.path() == path).then_some(file)
}

fn parse_loose(path: &str) -> Option<V4File> {
    match path {
        META_FILE => return Some(V4File::Meta),
        JOINED_FILE => return Some(V4File::Joined),
        _ => {}
    }
    if let Some(rest) = path.strip_prefix("loc/") {
        let id = canonical_id(rest)?;
        return is_v7(&id).then_some(V4File::Loc(id));
    }
    let rest = path.strip_prefix("devices/")?;
    let (dev, name) = rest.split_once('/')?;
    let device = canonical_id(dev)?;
    if name.contains('/') {
        return None;
    }
    if name == PROFILE_FILE {
        return Some(V4File::Profile { device });
    }
    if let Some(r) = name
        .strip_prefix("head-")
        .and_then(|r| r.strip_suffix(".json"))
    {
        let (gen, tag) = gen_tag(r)?;
        return Some(V4File::Head { device, gen, tag });
    }
    if let Some(r) = name
        .strip_prefix("rhd-")
        .and_then(|r| r.strip_suffix(".json"))
    {
        let (gen, tag) = gen_tag(r)?;
        return Some(V4File::RelayHead {
            author: device,
            gen,
            tag,
        });
    }
    if let Some(r) = name
        .strip_prefix("mf-")
        .and_then(|r| r.strip_suffix(".bin"))
    {
        let (gen, tag) = gen_tag(r)?;
        return Some(V4File::Manifest { device, gen, tag });
    }
    if let Some(r) = name
        .strip_prefix("seg-")
        .and_then(|r| r.strip_suffix(".bin"))
    {
        let (first, last, tag) = range_tag(r)?;
        return Some(V4File::Seg {
            device,
            first,
            last,
            tag,
        });
    }
    if let Some(r) = name
        .strip_prefix("rly-")
        .and_then(|r| r.strip_suffix(".bin"))
    {
        let (first, last, tag) = range_tag(r)?;
        return Some(V4File::Relay {
            author: device,
            first,
            last,
            tag,
        });
    }
    if let Some(r) = name
        .strip_prefix("hrt-")
        .and_then(|r| r.strip_suffix(".bin"))
    {
        // <src8>-<36 位 UUID>-<first>-<last>-<tag>：UUID 自带连字符，按位置切。
        let src8 = r.get(..8)?;
        if !is_tag(src8) || r.get(8..9)? != "-" || r.get(45..46)? != "-" {
            return None;
        }
        let old_device = canonical_id(r.get(9..45)?)?;
        let (first, last, tag) = range_tag(r.get(46..)?)?;
        return Some(V4File::Heritage {
            uploader: device,
            src8: src8.to_owned(),
            old_device,
            first,
            last,
            tag,
        });
    }
    None
}

// ---------------------------------------------------------------- 名字守卫

/// 新旧根**顶层**的名字是否可用：`cursor`、`probe`、`profile.json` 与 `batch-*`、`snapshot-*` 不可用（ASCII 不分大小写：
/// 网盘与 Windows / macOS 的文件系统多数不分大小写）。
pub fn top_level_name_allowed(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    !(matches!(n.as_str(), "cursor" | "probe" | "profile.json")
        || n.starts_with("batch-")
        || n.starts_with("snapshot-"))
}

/// [guard_location_path] 拒绝的路径。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForbiddenName(pub String);

impl std::fmt::Display for ForbiddenName {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "forbidden name at generation root: {}", self.0)
    }
}

/// 写位置之前的守卫：[path] 相对位置目录（`fushi-srs/<目录名>/`）；落在 `v3/` 或 `v4/` 下时，紧跟着的那一级名字必须
/// 通过 [top_level_name_allowed]。别的根（`v2/` 等）不归这里管。
///
/// 与 [top_level_name_allowed] 同一口径：根名也按 ASCII 不分大小写（`V4/` 在不分大小写的盘上就是 `v4/`），`/` 与 `\`
/// 都当分隔符、空段跳过（`v4//cursor`、`v4\cursor` 落到的都是 `v4/cursor`）。
pub fn guard_location_path(path: &str) -> Result<(), ForbiddenName> {
    let mut it = path.split(['/', '\\']).filter(|s| !s.is_empty());
    let root = it.next().unwrap_or_default();
    if !root.eq_ignore_ascii_case(NEW_ROOT) && !root.eq_ignore_ascii_case(OLD_ROOT) {
        return Ok(());
    }
    match it.next() {
        Some(top) if !top_level_name_allowed(top) => Err(ForbiddenName(path.to_owned())),
        _ => Ok(()),
    }
}

#[cfg(test)]
#[path = "location_tests.rs"]
mod tests;
