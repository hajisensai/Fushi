//! 换身份（设计 §7.3，transport.rs `rotate`）之后，位置上旧身份目录的清理。
//!
//! 换身份后本机再也写不出旧身份的 head（旧私钥随 `sync2_self` 换掉了），旧身份 seq ≤ 冻结点的操作又永远留在旧身份
//! 下——位置上 `devices/<旧身份>/` 里代号最大的 head 与它引用的段，是新设备 / 落后的设备拿到那段历史的唯一入口。
//! 这个目录没有主人了：本机当前身份的收尾（transport.rs `sync2_obsolete`）只管自己的目录（BUG-4324）。
//!
//! 这里只删一类文件：**被盖过的旧 head**，而且只凭当场的证据——调用方把旧目录的列表与其中**每一份** head 的字节
//! 交进来，[SrsCore::sync2_obsolete_former] 验过签之后判。删一份 head 的依据永远是「此刻读到、验过签的另一份代号
//! 更大的 head」；那一份自己要被任何人删掉，同样得先有代号更大的在（写这个目录的安装只删比自己刚写的低两代以上
//! 的，转发者只在转发上去更大代号的之后删自己转发的旧 head）。所以无论多少台设备、以什么交错清，目录里出现过的最大
//! 代号那份 head 都在，读者只读它。
//!
//! **段一个不删**，包括本机还是旧身份时自己合并换下来、没来得及删的旧小段。「位置上没有 head 引用它」证明不了它
//! 以后不被引用：同一身份的另一个安装（换身份的原因就是出现过这样一个安装）切法里可能还有它，它来这个位置时先
//! 自检（`sync2_audit_own`：段在）再写 head（引用它），本机的删除落在这两步之间，位置上最大的 head 就引用了一个
//! 不在的段；那个安装之后也换了身份 / 不再来，就再没有人补——只从这个位置读的设备永久缺那一段。位置是哑存储，没有
//! 能让清理者与写入者互斥的东西，所以不删：留下的量有界且小（换身份那一刻登记着的十几个小段），删错的代价是丢历史。
//!
//! 不记任何「待删」状态：每次都从当下的目录与 head 内容重新推导，清到一半崩溃、几台设备同时清都只是各自重新推导。
//! 唯一持久的是「这个目录多久没变过」的计时（[Watch]，`srs_meta`）。

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{Connection, OptionalExtension, params};

use super::transport::OBSOLETE_GRACE_MS;
use super::{Local, id_of, in_savepoint, sql};
use crate::store::SrsCore;
use crate::sync2::id::Id;
use crate::sync2::segment::{self, Head};

/// 旧身份目录要保持不变多久才动它，也是没事可做 / 证明不了时隔多久再看一次。
///
/// 删被盖过的 head 本身不需要等（依据是另一份 head 在，见文件头）；等是礼让与节流：还有安装在往里写的目录由它按
/// 自己的保留规则清（留两代：读者拿着稍旧的目录列表也读得到），本机不抢；稳定之后每个旧身份每个位置一天只列一次
/// 目录。与本机目录里旧小段的宽限期（[OBSOLETE_GRACE_MS]）取同一个量。
pub(crate) const FORMER_QUIET_MS: i64 = OBSOLETE_GRACE_MS;

fn dir_of(device: &Id) -> String {
    format!("devices/{}/", device.text())
}

/// 待删表（`sync2_obsolete`）里登记在 [device] 目录下的行作废。它们是本机还是这个身份时登记的旧小段与没确认的旧
/// head；换了身份之后段不删（文件头）、head 每次从目录现状重新判，没有任何判据再用得上这些行。留着反而有害：
/// 2026-11 之前的内核不看文件在谁的目录，按**新身份**的代号把它们交出去删（BUG-4324）——在这个版本上换过身份再
/// 降级回去不能重蹈它。
pub(crate) fn drop_rows(c: &Connection, profile: &str, device: &Id) -> Result<(), String> {
    c.prepare_cached(
        "DELETE FROM sync2_obsolete WHERE profile_uid = srs_id(?1) AND substr(name, 1, length(?2)) = ?2",
    )
    .map_err(sql)?
    .execute(params![profile, dir_of(device)])
    .map_err(sql)?;
    Ok(())
}

/// 一个位置上一个旧身份目录的观察记录：上一次看到的目录指纹、这个指纹从什么时候起没变过、下次该看的时刻。
/// `srs_meta` 里存成 `<指纹>|<起始时刻>|<下次时刻>`；指纹为空 = 没有可接着算的观察（刚给过清单 / 上次证明不了）。
struct Watch {
    fingerprint: String,
    since: i64,
    due: i64,
}

fn watch_key(profile: &str, location: &str, device: &Id) -> String {
    format!("sync2_former/{profile}/{location}/{}", device.text())
}

fn load_watch(c: &Connection, key: &str) -> Result<Option<Watch>, String> {
    let v: Option<String> = c
        .prepare_cached("SELECT value FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .query_row([key], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    Ok(v.and_then(|v| {
        let mut parts = v.splitn(3, '|');
        Some(Watch {
            fingerprint: parts.next()?.to_owned(),
            since: parts.next()?.parse().ok()?,
            due: parts.next()?.parse().ok()?,
        })
    }))
}

fn save_watch(c: &Connection, key: &str, w: &Watch) -> Result<(), String> {
    c.prepare_cached(
        "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    )
    .map_err(sql)?
    .execute(params![
        key,
        format!("{}|{}|{}", w.fingerprint, w.since, w.due)
    ])
    .map_err(sql)?;
    Ok(())
}

/// 本机的旧身份里 [location] 上此刻该看一眼的（[super::transport::Obsolete::former]）。旧身份 = 设备表里冻结的行
/// （只有 `rotate` 会冻结；从一台换过身份的设备的备份恢复出来的库也带着这些行——它同样记得这个目录没有主人了）。
/// 没看过的、到期的、以及记录的时刻比现在晚得不合理的（时钟被拨回过）都算该看。归档位置（[archive]，只写不删）不看。
///
/// 顺带把这些身份目录下的待删行作废（[drop_rows]）：换身份时已经做过，这里收的是以前的版本换身份留下的。
pub(crate) fn due(
    c: &Connection,
    local: &Local,
    location: &str,
    archive: bool,
    now: i64,
) -> Result<Vec<String>, String> {
    let frozen: Vec<Vec<u8>> = c
        .prepare_cached(
            "SELECT device FROM sync2_devices WHERE profile_uid = srs_id(?1) AND frozen = 1 AND device <> ?2 ORDER BY device",
        )
        .map_err(sql)?
        .query_map(params![local.profile, local.device.0.to_vec()], |r| {
            r.get(0)
        })
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut out = Vec::new();
    for d in frozen {
        let device = id_of(d)?;
        drop_rows(c, &local.profile, &device)?;
        if archive {
            continue;
        }
        let seen = load_watch(c, &watch_key(&local.profile, location, &device))?;
        if seen.is_none_or(|w| w.due <= now || w.due > now.saturating_add(FORMER_QUIET_MS)) {
            out.push(device.text());
        }
    }
    Ok(out)
}

/// 旧目录的现状经得起推敲时的结论。
struct Proven {
    /// 目录列表的指纹。
    fingerprint: String,
    /// 被盖过的 head（位置上的相对路径）。
    covered: Vec<String>,
}

/// 判据的前四条（见 [SrsCore::sync2_obsolete_former]）；None = 证明不了。
fn examine(
    local: &Local,
    device: &Id,
    public: &[u8],
    present: &[String],
    heads: &[Vec<u8>],
) -> Option<Proven> {
    let names: BTreeSet<&str> = present.iter().map(String::as_str).collect();
    // 全部 head 可验：列表里凡是 `head-` 开头的都得有一份对得上名字、验得过签名的字节；交来的字节也不能有列表里
    // 没有的。文件名只由代号与链值定：同名而内容不同的两份（两个安装在同一代号、同一 seq 上各写各的）无从分辨
    // 位置上此刻是哪一份。
    let listed: BTreeSet<&str> = names
        .iter()
        .copied()
        .filter(|n| n.starts_with("head-"))
        .collect();
    let mut verified: BTreeMap<String, Head> = BTreeMap::new();
    for bytes in heads {
        let h = Head::decode(bytes).ok()?;
        if h.device != *device
            || h.public.as_slice() != public
            || h.collection != local.collection
            || h.min_reader > segment::PROTOCOL
        {
            return None;
        }
        let name = h.file_name();
        if verified.get(&name).is_some_and(|other| *other != h) {
            return None;
        }
        verified.insert(name, h);
    }
    if verified.is_empty()
        || verified.len() != listed.len()
        || !verified.keys().all(|n| listed.contains(n.as_str()))
    {
        return None;
    }
    let dir = dir_of(device);
    let mut covered = Vec::new();
    for (name, h) in &verified {
        if verified.values().any(|k| k.gen > h.gen && k.seq >= h.seq) {
            covered.push(format!("{dir}{name}"));
        } else if !h.segment_files().iter().all(|f| {
            names.contains(f.as_str()) || names.contains(segment::relay_file_name(f).as_str())
        }) {
            // 留下的 head 引用的段在列表里没有文件（作者写的或转发来的都没有）：目录本身不完整，不碰。
            return None;
        }
    }
    let mut hasher = blake3::Hasher::new();
    for n in &names {
        hasher.update(n.as_bytes());
        hasher.update(b"\n");
    }
    Some(Proven {
        fingerprint: hasher.finalize().to_hex().to_string(),
        covered,
    })
}

impl SrsCore {
    /// [location] 上本机旧身份 [device] 的目录里此刻可以删的文件（位置上的相对路径）——只会是被盖过的旧 head
    /// （段一个不给，见文件头）。[present] = 调用方**这一次**列 `devices/<device>/` 得到的文件名，[heads] = 其中每一
    /// 份 head 文件的字节（读不到的不补、不猜，少交一份这里就判证明不了）。删不删得成不必回执：没有待删记录，下次
    /// 照样从目录现状重新推导。
    ///
    /// 下面任何一条不成立就是证明不了：什么都不给，[FORMER_QUIET_MS] 之后再看。
    /// 1. [device] 是本机的旧身份（设备表里冻结、不是当前身份），位置不是归档（[archive]，只写不删）。
    /// 2. 全部 head 可验：列表里每一份 head 都交来了，都是这个身份用设备表里记的那把钥匙签的、属于本集合、本机读得
    ///    懂的；至少有一份。
    /// 3. 被盖过 = 列表里另有一份代号更大、发布的 seq 不比它小的 head。代号最大的永远不算（读者只读它）；同代号的
    ///    互不盖；代号小但 seq 更大的也不算——head 代号是每个安装自己的计数器（[Local::head_gen]），同一身份的另一
    ///    个安装写的 head 可以代号小而发布得更多，那是位置上唯一记着「这个身份还有更多操作」的东西。
    /// 4. 没被盖过的每一份 head 引用的段，列表里都有文件（`seg-` 或转发来的 `rly-`）：不完整的目录不碰。
    /// 5. 目录列表与上一次看时完全相同，而且已经这样 [FORMER_QUIET_MS] 以上。目录有任何变化（有人写了 head / 段 /
    ///    转发件，或删了东西）都从头计时。
    pub fn sync2_obsolete_former(
        &self,
        profile: &str,
        location: &str,
        device: &str,
        present: &[String],
        heads: &[Vec<u8>],
        archive: bool,
        now: i64,
    ) -> Result<Vec<String>, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let Some(local) = Local::load(c, profile)? else {
                return Ok(Vec::new());
            };
            let device = Id::parse(device).ok_or("sync2: bad device")?;
            let public: Option<Vec<u8>> = c
                .prepare_cached(
                    "SELECT public FROM sync2_devices WHERE profile_uid = srs_id(?1) AND device = ?2 AND frozen = 1",
                )
                .map_err(sql)?
                .query_row(params![profile, device.0.to_vec()], |r| r.get(0))
                .optional()
                .map_err(sql)?
                .flatten();
            let Some(public) = public.filter(|_| device != local.device && !archive) else {
                return Ok(Vec::new());
            };
            let key = watch_key(profile, location, &device);
            let later = now.saturating_add(FORMER_QUIET_MS);
            let Some(proven) = examine(&local, &device, &public, present, heads) else {
                let unproven = Watch {
                    fingerprint: String::new(),
                    since: now,
                    due: later,
                };
                save_watch(c, &key, &unproven)?;
                return Ok(Vec::new());
            };
            let since = load_watch(c, &key)?
                .filter(|w| w.fingerprint == proven.fingerprint && w.since <= now)
                .map_or(now, |w| w.since);
            let quiet = now - since >= FORMER_QUIET_MS;
            let next = if !quiet {
                // 还没静止够：到时候再看。
                Watch {
                    fingerprint: proven.fingerprint,
                    since,
                    due: since.saturating_add(FORMER_QUIET_MS),
                }
            } else if proven.covered.is_empty() {
                // 没事可做：指纹与起始时刻留着，过一个周期再看。
                Watch {
                    fingerprint: proven.fingerprint,
                    since,
                    due: later,
                }
            } else {
                // 给了清单：目录马上要变，下一轮重新起算（没删成的也是一个周期之后再试，不是每轮试）。
                Watch {
                    fingerprint: String::new(),
                    since: now,
                    due: now,
                }
            };
            save_watch(c, &key, &next)?;
            Ok(if quiet { proven.covered } else { Vec::new() })
        })
    }
}
