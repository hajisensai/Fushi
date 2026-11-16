//! 旧根捡漏与围栏（设计 §4.3、§6.2 第 3、4 步；D21；规划 §2.1 的 G8-5）。还没有调用方（第一段）：同步轮（G8-7）每轮
//! 先 [check_root] 认位置的代，再列旧根（`v3/`）交给 [Truth::oldroot_scan]，把它要的段读来交给
//! `Receiver::legacy`（`receive.rs`，验签、重算协议 3 的链、逐条转译、按序落进承袭日志），按 [fence_writes] 重立围栏，
//! 最后 [Truth::oldroot_settle] 记下这一轮核对过的清单指纹。
//!
//! # 为什么每轮都要捡
//!
//! 围栏只让旧版本停下并提示升级，挡不住三种情况（§4.3）：云盘先删后传时旧客户端重建 `minReader 3` 的 meta、旧客户端
//! 已经开始的那一轮照样上传与合并、旧客户端的 profile 关联步骤删掉旧根下的目录（连带围栏）。所以升级过的设备每轮核对
//! 旧根清单：指纹（`sync_state.rs` 的 [oldroot_fingerprint]：路径、大小、修改时刻）变了，就把旧根里本机还没有的段转译
//! 并入（之后由承袭上传 `inherit.rs` 传进新根）；围栏不在了、被改了就重立。
//!
//! # 哪些段要读
//!
//! 旧根里 `devices/<作者>/` 下的 `seg-…`（作者自写）与 `rly-…`（协议 3 的转发件，原段由作者签名）。本机这条承袭日志
//! 已经盖到段尾、而且段尾那个 seq 记着完整原链值、它的短标签等于文件名里的标签（`seg-<first>-<last>-<标签>`，协议 3
//! 自己就靠这个标签区分同一区间的不同分支）时不读：段尾链值相同 = 到段尾为止的整条链相同（哈希链）。其余都读，读到
//! 已有的槽按落库规则幂等。墓碑设备的目录、heads、meta 都不读。
//!
//! # 什么时候算「核对过」
//!
//! [Truth::oldroot_settle] 只在本轮要读的段**全部有了结论**（落库、已有、坏段）、没有一段要等（公钥未知、解不开），而且
//! 围栏已经写好时才记下指纹；否则不记，下一轮清单不变也照样重来。坏段不挡：旧客户端传到一半的文件传完之后大小 /
//! 修改时刻会变，指纹跟着变，自然重读。
//!
//! # 只有协议 1 旧根的位置（D21，所有者授权从简）
//!
//! 位置目录下只有 `v2/`（2026-10-30 断代之前的协议 1 旧根），没有 `v3/`、`v4/`：[check_root] 明确拒绝
//! （[RootRefused]，错误码 [ERR_PROTOCOL1_ROOT]），同步轮停下、提示用户「这个同步位置的格式太旧，先用 3.x 版本同步一次
//! 把它升级，或者换一个同步位置」。拒绝发生在碰位置、碰本机库之前：位置上一个字节不写（不建 `v4/`、不写 v3 meta——
//! 旧入口 `srs_location_migration.dart` 写 `minReader 3` 的 v3 meta，在协议 4 下等于拆掉围栏，所以那条路整个不走），
//! 本机的卡片与复习记录也一条不动（它们在本机库里，跟这个位置有没有同步上无关）；用户升级位置之后下一轮照常同步。

use super::receive::Taken;
use super::sync_state::{OldRootEntry, oldroot_fingerprint};
use super::truth::{DEV_HERITAGE, Truth};
use crate::gen4::location::{
    DEVICES_DIR, META_FILE, NEW_ROOT, OLD_ROOT, fence3, tombstone_device, tombstone_head,
};
use crate::store::sync2::collection_of;
use crate::sync2::id::Id;
use crate::sync2::segment::{chain_tag, parse_segment_file_name};

/// 协议 1 旧根目录名。
pub const PROTOCOL1_ROOT: &str = "v2";

/// [RootRefused::code]：只有协议 1 旧根的位置。
pub const ERR_PROTOCOL1_ROOT: &str = "srs_location_protocol1_root";

/// 一个位置目录（`fushi-srs/<位置目录名>/`）现在是哪一代。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RootKind {
    /// 空位置（新建集合）。
    Empty,
    /// 只有协议 1 旧根 `v2/`。
    Protocol1Only,
    /// 有协议 3 旧根 `v3/`、还没有新根（第一台升级的设备：先把旧根拉进承袭日志，再建新根，§6.2 第 1 步）。
    Protocol3,
    /// 有新根 `v4/`（旧根可能也在，照样捡漏）。
    Protocol4,
}

/// [check_root] 拒绝的位置。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RootRefused {
    /// 机读码（给 Dart 侧本地化提示）。
    pub code: &'static str,
    pub message: String,
}

/// 按位置目录顶层的名字（[top]：目录名，不带斜杠）认代。
pub fn root_kind(top: &[&str]) -> RootKind {
    let has = |n: &str| top.contains(&n);
    if has(NEW_ROOT) {
        RootKind::Protocol4
    } else if has(OLD_ROOT) {
        RootKind::Protocol3
    } else if has(PROTOCOL1_ROOT) {
        RootKind::Protocol1Only
    } else {
        RootKind::Empty
    }
}

/// 认代；只有协议 1 旧根的位置明确拒绝（D21，文件头）。
pub fn check_root(top: &[&str]) -> Result<RootKind, RootRefused> {
    match root_kind(top) {
        RootKind::Protocol1Only => Err(RootRefused {
            code: ERR_PROTOCOL1_ROOT,
            message:
                "this sync location still uses the protocol 1 layout (v2/ only); sync it once \
                      with a 3.x version to upgrade it, or use another location. Local cards and \
                      review history are not affected"
                    .to_owned(),
        }),
        k => Ok(k),
    }
}

/// [Truth::oldroot_scan] 的结果。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OldRootScan {
    /// 这一轮清单的指纹。
    pub fp: [u8; 32],
    /// 与上一次核对过的不同（或从没核对过）。
    pub changed: bool,
    /// 要读的段（相对旧根 `v3/` 的路径），按 (作者, first) 升序。清单没变时为空。
    pub fetch: Vec<String>,
    /// 清单变了、但本机已有、不用读的段数。
    pub skipped: u64,
    /// 要读 `v3/meta.json` 核对围栏（清单变了、而且它在清单里）。
    pub read_meta: bool,
}

/// 旧根清单里的一个段文件：`devices/<作者>/seg-…` 或 `rly-…` → (作者, first, last, 标签)。
fn old_segment(path: &str) -> Option<(Id, u64, u64, String)> {
    let rest = path.strip_prefix(DEVICES_DIR)?.strip_prefix('/')?;
    let (dev, name) = rest.split_once('/')?;
    let author = Id::parse(dev).filter(|id| id.text() == dev)?;
    let seg_name = match name.strip_prefix("rly-") {
        Some(r) => format!("seg-{r}"),
        None => name.to_owned(),
    };
    let (first, last, tag) = parse_segment_file_name(&seg_name)?;
    Some((author, first, last, tag))
}

impl Truth<'_> {
    /// 核对位置 [loc]（目录名 [dir]，本集合或被它并入过的集合的）的旧根清单 [listing]（路径相对 `v3/`）：指纹变了就列出
    /// 要读的段（文件头「哪些段要读」）。只读。
    pub fn oldroot_scan(
        &self,
        col: i64,
        loc: &str,
        dir: &str,
        listing: &[OldRootEntry],
    ) -> Result<OldRootScan, String> {
        let fp = oldroot_fingerprint(listing);
        let changed = self.oldroot_fp(col, loc)?.is_none_or(|r| r.fp != fp);
        let mut scan = OldRootScan {
            fp,
            changed,
            fetch: Vec::new(),
            skipped: 0,
            read_meta: false,
        };
        if !changed {
            return Ok(scan);
        }
        scan.read_meta = listing.iter().any(|e| e.path == META_FILE);
        let source = collection_of(dir);
        let tomb = tombstone_device(dir);
        let devices = self.devices(col)?;
        let mut found: Vec<(Id, u64, String)> = Vec::new();
        let mut marks: std::collections::BTreeMap<Id, std::collections::BTreeMap<u64, String>> =
            std::collections::BTreeMap::new();
        for e in listing {
            let Some((author, first, last, tag)) = old_segment(&e.path) else {
                continue;
            };
            if author == tomb {
                continue;
            }
            let known = match devices.iter().find(|d| d.id == author) {
                Some(d)
                    if d.kind == Some(DEV_HERITAGE) && d.src == Some(source) && d.last >= last =>
                {
                    if !marks.contains_key(&author) {
                        let m = self
                            .marks(col, &author)?
                            .into_iter()
                            .map(|(s, c)| (s, chain_tag(&c)))
                            .collect();
                        marks.insert(author, m);
                    }
                    marks[&author].get(&last) == Some(&tag)
                }
                _ => false,
            };
            if known {
                scan.skipped += 1;
            } else {
                found.push((author, first, e.path.clone()));
            }
        }
        found.sort();
        found.dedup();
        scan.fetch = found.into_iter().map(|(_, _, p)| p).collect();
        Ok(scan)
    }

    /// 记下这一轮核对过的旧根指纹（文件头「什么时候算核对过」）。[taken] 是 [OldRootScan::fetch] 里每个文件交给
    /// `Receiver::legacy` 的结论（顺序一致、一个不少）；[fenced] = 本轮该写的围栏都写好了。记了返回 true。
    pub fn oldroot_settle(
        &self,
        col: i64,
        loc: &str,
        scan: &OldRootScan,
        taken: &[Taken],
        fenced: bool,
        at: i64,
    ) -> Result<bool, String> {
        if taken.len() != scan.fetch.len() {
            return Err(format!(
                "gen4 oldroot: {} results for {} fetched files",
                taken.len(),
                scan.fetch.len()
            ));
        }
        if !fenced || taken.iter().any(|t| matches!(t, Taken::Deferred(_))) {
            return Ok(false);
        }
        self.set_oldroot_fp(col, loc, &scan.fp, at)?;
        Ok(true)
    }
}

/// 旧根 `v3/meta.json` 这一轮读到了什么。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Meta3<'a> {
    /// 清单里没有它。
    Absent,
    /// 读到的字节。
    Read(&'a [u8]),
    /// 清单里有、但这一轮没去读（清单没变）或读失败：不动它。
    Unread,
}

/// 这一轮要写的围栏文件：(相对位置目录的路径, 字节)。[v4_meta] 是新根 `v4/meta.json` 的字节（`kdf` 从它照抄，所以
/// 新根就绪之后才立围栏）；[listing] 是旧根清单（路径相对 `v3/`）。
///
/// - `v3/meta.json`（[fence3]）：清单里没有、或读到的与该有的不同（旧客户端重建的 `minReader 3` meta、被改过的）就写；
///   这一轮没读它（[Meta3::Unread]）就不动——读失败时写会盖掉没看过的内容，清单没变时它就是上一轮核对过的样子。
/// - 墓碑 head（[tombstone_head]）：清单里没有、或大小不对就写（内容是目录名的纯函数，大小不同就一定不同）。
pub fn fence_writes(
    dir: &str,
    v4_meta: &[u8],
    meta3: Meta3<'_>,
    listing: &[OldRootEntry],
) -> Result<Vec<(String, Vec<u8>)>, String> {
    let mut out = Vec::new();
    let fence = fence3(dir, v4_meta)?;
    let rewrite = match meta3 {
        Meta3::Absent => true,
        Meta3::Read(have) => have != fence.as_slice(),
        Meta3::Unread => false,
    };
    if rewrite {
        out.push((format!("{OLD_ROOT}/{META_FILE}"), fence));
    }
    let (path, bytes) = tombstone_head(dir);
    let rel = path
        .strip_prefix(OLD_ROOT)
        .and_then(|p| p.strip_prefix('/'))
        .ok_or("gen4 oldroot: tombstone head is not under the old root")?;
    let present = listing
        .iter()
        .any(|e| e.path == rel && e.size == bytes.len() as u64);
    if !present {
        out.push((path, bytes));
    }
    Ok(out)
}

#[cfg(test)]
#[path = "oldroot_tests.rs"]
mod tests;
