//! 旧根捡漏与围栏（设计 §4.3、§6.2 第 3、4 步；D21；规划 §2.1 的 G8-5）。还没有调用方（第一段）：同步轮（G8-7）每轮
//! 先 [check_root] 认位置的代，再列旧根（`v3/`）交给 [Truth::oldroot_scan]，把它要的段读来交给
//! `Receiver::legacy`（`receive.rs`，验签、重算协议 3 的链、逐条转译、按序落进承袭日志），按 [fence_writes] 重立围栏，
//! 最后用 [Receiver::finish_oldroot] 收尾这一批、记下这一轮核对过的清单指纹。
//!
//! # 指纹与落库同一个事务
//!
//! 记了指纹，下一轮清单不变就一个段都不读（[OldRootScan::changed] = false）。所以指纹**只能**在这些段的落库都提交了
//! 之后记：指纹先提交、落库那一笔回滚或崩溃，这批旧操作就一直丢着，直到旧根清单碰巧再变。这条约束钉在签名上——记
//! 指纹的唯一入口是 [Receiver::finish_oldroot]：它消费这一批 `Receiver`（开在调用方的事务里），先 `finish`（投完等待
//! 缓冲、收派生层），再在同一个事务里记结论、写指纹；「这一批每段的结论」用的是这个 `Receiver` 自己记下的 `legacy`
//! 结论，不由调用方另报（测试 `the_fingerprint_commits_with_the_landing_or_not_at_all`）。
//!
//! # 切片与累计（G8-7c）
//!
//! 迁移后第一次捡一个大的旧根可能有几百个协议 3 段，一个事务收完要让作答等很久，所以 `oldroot_ingest` 和收新根的段
//! 一样按 `maxItems` 切成多个事务。指纹因此不能再要求「一批正好是整份待读清单」，改成**跨事务累计**：每一批在自己的
//! 事务里把每段的结论（落库、已有、坏段；要等的不算）记到这一轮名下（`srs_meta` `gen4_oldrun/<col>/<位置>` + 路径，
//! 值 = 这一轮清单指纹），与这些段的落库一起提交或一起回滚；收尾那一批按清单重算待读列表，列表里每一段都在**同一个
//! 指纹**名下有了结论才记指纹、清掉累计（[Receiver::finish_oldroot]）。清单在中途变了（指纹不同）累计的就不算，下一轮
//! 重来；崩溃丢的只是没提交的那一批的结论，已提交的批照样算（测试
//! `slices_of_one_round_add_up_to_a_recorded_fingerprint`）。
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
//! [Receiver::finish_oldroot] 只在本轮要读的段**全部有了结论**（落库、已有、坏段）、没有一段要等（公钥未知、解不开），而且
//! 围栏已经写好时才记下指纹；否则不记，下一轮清单不变也照样重来。坏段不挡：旧客户端传到一半的文件传完之后大小 /
//! 修改时刻会变，指纹跟着变，自然重读。
//!
//! # 只有协议 1 旧根的位置（D21，所有者授权从简）
//!
//! 位置目录下只有 `v2/`（2026-10-30 断代之前的协议 1 旧根），没有 `v3/`、`v4/`：[check_root] 明确拒绝
//! （[RootRefused]，错误码 [ERR_PROTOCOL1_ROOT]），同步轮停下、提示用户「这个同步位置的格式太旧，在另一台装 3.3.0 的
//! 设备上同步一次把它升级，或者换一个同步位置；不要把本机装回 3.x」（G8-7c 核过，交接 §第四波 G8-7c）：
//! - 能把 `v2/` 升成 `v3/` 的只有 v3.3.0（协议 3 的最后一个 3.x 正式版：`kSrsSync2V1Folder = 'v2'` +
//!   v3.3.0 里的 `srs_location_migration.dart`，本仓已删）。v3.0.0 / v3.0.1 还没有 sync2（走 `packages/fushi_srs` 的旧事件同步，不碰 `v2/`），
//!   协议 1 预发布构建本身就只写 `v2/`——在它们上面同步一次什么也不会变。一个位置只剩 `v2/` 本身就说明从来没有
//!   v3.3.0 设备在上面同步过，所以提示必须点名 3.3.0，不能笼统说「3.x」。
//! - 本机库已封存成 `39999`，v3.3.0 打开时报「schema newer than this build」、整个卡片库不可用，什么也同步不了；
//!   Android 降级还得卸载、清空本机数据。所以只能在**另一台**设备上装 3.3.0 做。
//!
//! 拒绝发生在碰位置、碰本机库之前：位置上一个字节不写（不建 `v4/`、不写 v3 meta——
//! v3.3.0 的旧入口 `srs_location_migration.dart` 写 `minReader 3` 的 v3 meta，在协议 4 下等于拆掉围栏，所以那条路整个不走），
//! 本机的卡片与复习记录也一条不动（它们在本机库里，跟这个位置有没有同步上无关）；用户升级位置之后下一轮照常同步。

use std::collections::BTreeMap;
use std::collections::btree_map::Entry;

use rusqlite::{OptionalExtension, params};

use super::receive::{Received, Receiver, Taken};
use super::schema::sql;
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
                "this sync location still uses the protocol 1 layout (v2/ only); to upgrade it, sync it \
                      once on another device running Fushi 3.3.0 (3.0.x and protocol 1 pre-release builds \
                      cannot upgrade it), or use another location (do not downgrade this device: 3.x cannot \
                      open its upgraded database). Local cards and review history are not affected"
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
        let mut marks: BTreeMap<Id, BTreeMap<u64, String>> = BTreeMap::new();
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
                    if let Entry::Vacant(v) = marks.entry(author) {
                        v.insert(
                            self.marks(col, &author)?
                                .into_iter()
                                .map(|(s, c)| (s, chain_tag(&c)))
                                .collect(),
                        );
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

    /// 这一轮（位置 [loc]、清单指纹 [fp]）里段 [path] 已经有了结论（落库、已有、坏段），记在更早提交的某一批里
    /// （[Truth::oldroot_note]）。
    fn oldroot_concluded(
        &self,
        col: i64,
        loc: &str,
        fp: &[u8; 32],
        path: &str,
    ) -> Result<bool, String> {
        let v: Option<String> = self
            .conn()
            .prepare_cached(OLDRUN_GET_SQL)
            .map_err(sql)?
            .query_row([run_key(col, loc, path)], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        Ok(v.as_deref() == Some(hex32(fp).as_str()))
    }

    /// 把这一批每段的结论记到这一轮（[fp]）名下：有结论的记、要等的（[Taken::Deferred]）去掉。与这一批的落库同一个
    /// 事务（只由 [Receiver::finish_oldroot] 调）。
    fn oldroot_note(
        &self,
        col: i64,
        loc: &str,
        fp: &[u8; 32],
        batch: &[(&str, &Taken)],
    ) -> Result<(), String> {
        let fp = hex32(fp);
        self.write(|| {
            for (path, taken) in batch {
                let key = run_key(col, loc, path);
                if matches!(taken, Taken::Deferred(_)) {
                    self.conn()
                        .prepare_cached("DELETE FROM srs_meta WHERE key = ?1")
                        .map_err(sql)?
                        .execute([key])
                        .map_err(sql)?;
                } else {
                    self.conn()
                        .prepare_cached(
                            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
                             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                        )
                        .map_err(sql)?
                        .execute(params![key, fp])
                        .map_err(sql)?;
                }
            }
            Ok(())
        })
    }

    /// 忘掉位置 [loc] 名下累计的段结论（这一轮核对完了，或位置被移除）。
    /// 集合 [col] 在**全部**位置上的旧根段结论（并入改绑换了根：旧目录 `v3/` 上的结论不适用于新目录，`identity.rs`
    /// `join_into`）。
    pub(crate) fn oldroot_forget_all(&self, col: i64) -> Result<(), String> {
        let (lo, hi) = (format!("gen4_oldrun/{col}/"), format!("gen4_oldrun/{col}0"));
        self.write(|| {
            self.conn()
                .prepare_cached(OLDRUN_DROP_SQL)
                .map_err(sql)?
                .execute(params![lo, hi])
                .map_err(sql)
                .map(|_| ())
        })
    }

    pub(crate) fn oldroot_forget_run(&self, col: i64, loc: &str) -> Result<(), String> {
        let (lo, hi) = run_range(col, loc);
        self.write(|| {
            self.conn()
                .prepare_cached(OLDRUN_DROP_SQL)
                .map_err(sql)?
                .execute(params![lo, hi])
                .map_err(sql)
                .map(|_| ())
        })
    }
}

/// 一轮旧根捡漏里各段结论的键：`gen4_oldrun/<col>/<位置>` + 换行 + 相对 `v3/` 的路径（位置与路径里都不会有换行）。
fn run_key(col: i64, loc: &str, path: &str) -> String {
    format!("gen4_oldrun/{col}/{loc}\n{path}")
}

/// 位置 [loc] 名下全部段结论的键区间 `[lo, hi)`（换行的下一个字符是 `\x0b`）。
fn run_range(col: i64, loc: &str) -> (String, String) {
    (
        format!("gen4_oldrun/{col}/{loc}\n"),
        format!("gen4_oldrun/{col}/{loc}\u{b}"),
    )
}

fn hex32(b: &[u8; 32]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// 一段的结论（[Truth::oldroot_concluded]）：`srs_meta` 主键点查。
pub(crate) const OLDRUN_GET_SQL: &str = "SELECT value FROM srs_meta WHERE key = ?1";

/// 一个位置名下的全部段结论（[Truth::oldroot_forget_run]）：`srs_meta` 主键区间。
pub(crate) const OLDRUN_DROP_SQL: &str = "DELETE FROM srs_meta WHERE key >= ?1 AND key < ?2";

/// 收尾时要不要、能不能记下这一轮的指纹（[Receiver::finish_oldroot] 的 `settle`）。
pub struct OldRootSettle<'a> {
    /// 这个旧根所在的位置目录名（[Truth::oldroot_scan] 的 `dir`）。
    pub dir: &'a str,
    /// 这一轮的旧根清单（路径相对 `v3/`），指纹必须等于这一轮的 [OldRootScan::fp]。
    pub listing: &'a [OldRootEntry],
    /// 本轮该写的围栏都写好了。
    pub fenced: bool,
    /// 记下的核对时刻。
    pub at: i64,
}

impl Receiver<'_, '_> {
    /// 收尾一批旧根捡漏（文件头「切片与累计」）：先 [Receiver::finish]；再在**同一个事务里**把这一批每段的结论记到
    /// 这一轮（位置 [loc]、清单指纹 [fp]）名下；[settle] 给了、这一批的收尾投递也做完了（没有 `drain_more`），就按
    /// 清单重算待读列表，列表里每一段都在这一轮名下有了结论（这一批的或更早提交的批的）、围栏也写好了，才记下
    /// 指纹、清掉累计的结论。[paths] 是这一批按顺序交给 [Receiver::legacy] 的段（一一对应，一个不多一个不少），
    /// 否则报错、整笔回滚。返回 (这一批的计数, 记了指纹没有)。
    pub fn finish_oldroot(
        self,
        loc: &str,
        fp: &[u8; 32],
        paths: &[String],
        settle: Option<OldRootSettle<'_>>,
    ) -> Result<(Received, bool), String> {
        let (t, col) = self.scope();
        let taken = self.legacy_taken().to_vec();
        if taken.len() != paths.len() {
            return Err(format!(
                "gen4 oldroot: {} results for {} fetched files",
                taken.len(),
                paths.len()
            ));
        }
        let received = self.finish()?;
        let batch: Vec<(&str, &Taken)> = paths.iter().map(String::as_str).zip(&taken).collect();
        t.oldroot_note(col, loc, fp, &batch)?;
        let Some(s) = settle else {
            return Ok((received, false));
        };
        if received.drain_more || !s.fenced {
            return Ok((received, false));
        }
        let scan = t.oldroot_scan(col, loc, s.dir, s.listing)?;
        if scan.fp != *fp {
            // 清单在这一轮里变了：累计的结论属于上一份清单，下一轮按新清单重来。
            return Ok((received, false));
        }
        for p in &scan.fetch {
            if !t.oldroot_concluded(col, loc, fp, p)? {
                return Ok((received, false));
            }
        }
        t.set_oldroot_fp(col, loc, fp, s.at)?;
        t.oldroot_forget_run(col, loc)?;
        Ok((received, true))
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
