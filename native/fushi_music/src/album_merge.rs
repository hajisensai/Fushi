//! 专辑对齐：同一目录里标签不一致的曲目归回同一张专辑。
//!
//! [uid::album_uid] 按**每首曲目自己的标签**派生（有专辑艺人走（艺人, 专辑名），没有走
//! （目录, 专辑名））。同一张碟里只有一首写了专辑艺人、或专辑名标点写法不同（`.` 与 `・`），
//! 逐首派生就会把一张碟拆成两张专辑。扫描器做不了这件事：增量扫描里没变的文件只报
//! 「没变」、不带标签，扫描器看不到同目录的其余曲目；存量库什么都没变，也就没有记录。
//! 所以对齐放在**扫描落库之后、对整个来源的在库曲目**做（Dart 读库 → 这里出合并方案 →
//! Dart 落库），首扫、增量扫、整库重扫看到的都是同一份「库里这一目录的全部曲目」，结论
//! 一致；落库后再跑一遍没有可合并的组（幂等）。
//!
//! 判据（[plan]）：同一目录内、专辑名按 [title_key]（去标点 / 符号 / 空白，全角 ASCII
//! 折半角，大小写折叠）相同的曲目为一组：
//! - 组里非空专辑艺人（按 [uid::normalize_name] 比）至多一种：整组是同一张专辑；
//! - 两种以上：艺人确实不同，按艺人分开，各自内部（标点差异）合并，没写专辑艺人的
//!   曲目归属不明，只在它们之间合并，不并进任何一位艺人；
//! - 合辑（无专辑艺人、每首艺人不同）本来就是同一个（目录, 专辑名）uid，一组只有一个
//!   uid，不出方案——现有行为不变。
//!
//! 合并后的 uid 用 [uid::album_uid] 按「组的规范标签」派生——等于标签全部改一致之后
//! 扫描器本来会给的 uid，所以用户之后把标签修齐，专辑 uid 不再变。派生算法本身不动。

use std::collections::{BTreeMap, BTreeSet};

use crate::uid;
use crate::wire::{Reader, Writer};

/// 一首在库曲目的专辑归属证据。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Member {
    pub track_uid: String,
    /// 当前所属专辑 uid。
    pub album_uid: String,
    /// 曲目路径（扫描器产出的原文；本地 / 远程同 [crate::scan] 的拼法）。
    pub path: String,
    /// 当前所属专辑行的标题。
    pub album_title: String,
    /// 这首曲目**自己的**专辑艺人标签（署名表 `album_artist`）；没有为 None。
    pub album_artist: Option<String>,
}

/// 一组要并成一张专辑的曲目。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Merge {
    pub album_uid: String,
    pub title: String,
    pub album_artist: Option<String>,
    /// 组内全部曲目（含已经挂在 [Merge::album_uid] 上的），按 uid 排序。
    pub track_uids: Vec<String>,
}

/// 曲目所在目录：与扫描器派生专辑 uid 时用的目录同一拼法（本地按平台路径取父目录，
/// 远程 URL 串按最后一个 `/` 切）。
pub fn track_dir(path: &str) -> String {
    if path.contains("://") {
        return crate::remote::split_dir(path).0.to_owned();
    }
    std::path::Path::new(path)
        .parent()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// 专辑名比较键：全角 ASCII 折半角，只留字母 / 数字（含假名、汉字），小写。去掉的是
/// 标点、符号与空白——`オリジナル.サウンドトラック` 与 `オリジナル・サウンドトラック`
/// 是同一个键。整串都是符号的（`...`）退回 [uid::normalize_name]，不让纯符号标题全撞在
/// 空键上。
pub fn title_key(title: &str) -> String {
    let mut out = String::with_capacity(title.len());
    for ch in title.chars() {
        let ch = match ch {
            '\u{FF01}'..='\u{FF5E}' => char::from_u32(ch as u32 - 0xFEE0).unwrap_or(ch),
            _ => ch,
        };
        if ch.is_alphanumeric() {
            out.extend(ch.to_lowercase());
        }
    }
    if out.is_empty() {
        return uid::normalize_name(title);
    }
    out
}

fn artist_of(m: &Member) -> Option<&str> {
    m.album_artist.as_deref().filter(|a| !a.trim().is_empty())
}

/// 一串候选里出现最多的原文；并列取字典序最小（结论与输入顺序无关）。
fn most_common<'a>(items: impl Iterator<Item = &'a str>) -> Option<&'a str> {
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    for s in items {
        *counts.entry(s).or_default() += 1;
    }
    let mut best: Option<(&str, usize)> = None;
    for (s, n) in counts {
        if best.is_none_or(|(_, bn)| n > bn) {
            best = Some((s, n));
        }
    }
    best.map(|(s, _)| s)
}

/// 规范专辑名：**多数曲目的写法**（按 [uid::normalize_name] 计票）。理由：零星不一致的
/// 往往是单独一首被另一个工具 / 来源写过标签（本例只有带专辑艺人的第 1 首写成了 `.`），
/// 一张碟大多数曲目的写法才是这张碟的写法；拿「带专辑艺人的那首」的写法会让一首的笔误
/// 覆盖整张碟。票数并列时取带专辑艺人曲目多的写法，再并列取归一化后字典序最小的。
fn canonical_title(cluster: &[&Member]) -> String {
    // 归一化键 → （票数, 带专辑艺人的票数）
    let mut votes: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for m in cluster {
        let v = votes
            .entry(uid::normalize_name(&m.album_title))
            .or_default();
        v.0 += 1;
        if artist_of(m).is_some() {
            v.1 += 1;
        }
    }
    let mut best: Option<(&String, (usize, usize))> = None;
    for (k, v) in &votes {
        if best.is_none_or(|(_, bv)| *v > bv) {
            best = Some((k, *v));
        }
    }
    let key = best.map(|(k, _)| k.clone()).unwrap_or_default();
    most_common(
        cluster
            .iter()
            .filter(|m| uid::normalize_name(&m.album_title) == key)
            .map(|m| m.album_title.as_str()),
    )
    .unwrap_or_default()
    .to_owned()
}

fn merge_of(dir: &str, cluster: &[&Member]) -> Option<Merge> {
    let uids: BTreeSet<&str> = cluster.iter().map(|m| m.album_uid.as_str()).collect();
    if uids.len() < 2 {
        return None;
    }
    let title = canonical_title(cluster);
    let artist = most_common(cluster.iter().filter_map(|m| artist_of(m))).map(str::to_owned);
    let album_uid = uid::album_uid(&title, artist.as_deref(), dir);
    let mut track_uids: Vec<String> = cluster.iter().map(|m| m.track_uid.clone()).collect();
    track_uids.sort();
    track_uids.dedup();
    Some(Merge {
        album_uid,
        title,
        album_artist: artist,
        track_uids,
    })
}

/// 合并方案（见模块文档）。只给出含两个以上专辑 uid 的组；结论只取决于输入集合，与
/// 输入顺序无关。
pub fn plan(members: &[Member]) -> Vec<Merge> {
    // （目录, 专辑名键）→ 组内曲目
    let mut groups: BTreeMap<(String, String), Vec<&Member>> = BTreeMap::new();
    for m in members {
        groups
            .entry((track_dir(&m.path), title_key(&m.album_title)))
            .or_default()
            .push(m);
    }
    let mut out: Vec<Merge> = Vec::new();
    for ((dir, _), group) in groups {
        let mut by_artist: BTreeMap<String, Vec<&Member>> = BTreeMap::new();
        let mut no_artist: Vec<&Member> = Vec::new();
        for m in &group {
            match artist_of(m) {
                Some(a) => by_artist.entry(uid::normalize_name(a)).or_default().push(m),
                None => no_artist.push(m),
            }
        }
        if by_artist.len() <= 1 {
            out.extend(merge_of(&dir, &group));
            continue;
        }
        for cluster in by_artist.values() {
            out.extend(merge_of(&dir, cluster));
        }
        out.extend(merge_of(&dir, &no_artist));
    }
    out
}

/// 输入线格式：`u32 count | (str track_uid | str album_uid | str path | str album_title |
/// opt_str album_artist)*count`。
pub fn decode_members(bytes: &[u8]) -> Option<Vec<Member>> {
    let mut r = Reader::new(bytes);
    let count = r.u32()? as usize;
    let mut out = Vec::with_capacity(count.min(1 << 16));
    for _ in 0..count {
        out.push(Member {
            track_uid: r.str()?,
            album_uid: r.str()?,
            path: r.str()?,
            album_title: r.str()?,
            album_artist: r.opt_str()?,
        });
    }
    r.at_end().then_some(out)
}

/// 输出线格式：`u32 count | (str album_uid | str title | opt_str album_artist | u32 n |
/// str track_uid*n)*count`。
pub fn encode_merges(merges: &[Merge]) -> Vec<u8> {
    let mut w = Writer::new();
    w.u32(merges.len() as u32);
    for m in merges {
        w.str(&m.album_uid);
        w.str(&m.title);
        w.opt_str(m.album_artist.as_deref());
        w.u32(m.track_uids.len() as u32);
        for t in &m.track_uids {
            w.str(t);
        }
    }
    w.into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    const DOT: &str = "TVアニメ「BanG Dream! Ave Mujica」オリジナル.サウンドトラック 上";
    const MID: &str = "TVアニメ「BanG Dream! Ave Mujica」オリジナル・サウンドトラック 上";

    fn dir() -> String {
        track_dir(&path("01.flac"))
    }

    fn path(name: &str) -> String {
        std::path::Path::new("/m/CDs/01")
            .join(name)
            .to_string_lossy()
            .into_owned()
    }

    /// 按扫描器的逐首规则造一首：专辑 uid 用曲目自己的标签派生。
    fn raw(track: &str, title: &str, artist: Option<&str>) -> Member {
        let p = path(&format!("{track}.flac"));
        Member {
            track_uid: track.into(),
            album_uid: uid::album_uid(title, artist, &track_dir(&p)),
            path: p,
            album_title: title.into(),
            album_artist: artist.map(str::to_owned),
        }
    }

    /// 把方案落到成员上（模拟 Dart 落库：曲目改挂、专辑行标题 / 艺人改成规范值）。
    fn apply(members: &mut [Member], merges: &[Merge]) {
        for mg in merges {
            for m in members.iter_mut() {
                if mg.track_uids.contains(&m.track_uid) {
                    m.album_uid = mg.album_uid.clone();
                    m.album_title = mg.title.clone();
                }
            }
        }
    }

    fn albums(members: &[Member]) -> BTreeSet<String> {
        members.iter().map(|m| m.album_uid.clone()).collect()
    }

    #[test]
    fn missing_album_artist_merges_into_the_tagged_one() {
        let ms = vec![
            raw("01", "Here, the world!", Some("sumimi")),
            raw("02", "Here, the world!", None),
            raw("03", "Here, the world!", None),
            raw("04", "Here, the world!", None),
        ];
        let plan = plan(&ms);
        assert_eq!(plan.len(), 1);
        let m = &plan[0];
        assert_eq!(m.album_artist.as_deref(), Some("sumimi"));
        assert_eq!(m.title, "Here, the world!");
        assert_eq!(m.track_uids, vec!["01", "02", "03", "04"]);
        // 规范 uid = 标签修齐后扫描器本来会给的 uid（这里就是第 1 首的 uid）。
        assert_eq!(m.album_uid, ms[0].album_uid);
    }

    #[test]
    fn punctuation_variant_merges_and_takes_the_majority_title() {
        let mut ms = vec![raw("01", DOT, Some("藤田淳平、藤間仁 (Elements Garden)"))];
        for i in 2..=14 {
            ms.push(raw(&format!("{i:02}"), MID, None));
        }
        let plan = plan(&ms);
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].title, MID);
        assert_eq!(
            plan[0].album_artist.as_deref(),
            Some("藤田淳平、藤間仁 (Elements Garden)")
        );
        assert_eq!(plan[0].track_uids.len(), 14);
        assert_eq!(
            plan[0].album_uid,
            uid::album_uid(MID, Some("藤田淳平、藤間仁 (Elements Garden)"), &dir())
        );
    }

    #[test]
    fn different_album_artists_stay_apart() {
        let ms = vec![
            raw("01", "Best", Some("Artist A")),
            raw("02", "Best", Some("Artist A")),
            raw("03", "Best", Some("Artist B")),
            raw("04", "Best", None),
        ];
        // 两位艺人各自只有一个 uid；没写艺人的那首归属不明，不并进任何一位。
        assert!(plan(&ms).is_empty());
        // 同一艺人内部的标点差异照样合并。
        let ms = vec![
            raw("01", "Best・Of", Some("Artist A")),
            raw("02", "Best.Of", Some("ARTIST A")),
            raw("03", "Best", Some("Artist B")),
        ];
        let p = plan(&ms);
        assert_eq!(p.len(), 1);
        assert_eq!(p[0].track_uids, vec!["01", "02"]);
    }

    #[test]
    fn compilation_and_other_directories_are_untouched() {
        // 合辑：无专辑艺人，每首艺人不同 → 本来就是一个（目录, 专辑名）uid。
        let ms = vec![raw("01", "Anime Hits", None), raw("02", "Anime Hits", None)];
        assert!(plan(&ms).is_empty());
        // 不同目录的同名专辑不合并（没有专辑艺人时目录就是身份）。
        let mut other = raw("01", "Anime Hits", None);
        other.path = "/m/CDs/02/01.flac".into();
        other.track_uid = "x".into();
        other.album_uid = uid::album_uid("Anime Hits", None, &track_dir(&other.path));
        let mut ms = ms;
        ms.push(other);
        assert!(plan(&ms).is_empty());
        // 名字真不同的不合并。
        let ms = vec![raw("01", "上", Some("A")), raw("02", "下", None)];
        assert!(plan(&ms).is_empty());
    }

    /// 首扫、增量扫（只有一首变了：它按逐首规则重新拿到原始 uid，其余仍挂在合并后的
    /// uid 上）、整库重扫三条路收敛到同一个 uid，再跑一遍没有方案（幂等）。
    #[test]
    fn first_incremental_and_full_rescan_converge() {
        let fresh = || {
            let mut ms = vec![raw("01", DOT, Some("X"))];
            for i in 2..=5 {
                ms.push(raw(&format!("{i:02}"), MID, None));
            }
            ms
        };
        let mut first = fresh();
        let p = plan(&first);
        apply(&mut first, &p);
        assert_eq!(albums(&first).len(), 1);
        let canonical = first[0].album_uid.clone();
        assert!(plan(&first).is_empty());

        for changed in 0..5 {
            let mut inc = first.clone();
            inc[changed] = fresh()[changed].clone();
            let p = plan(&inc);
            apply(&mut inc, &p);
            assert_eq!(
                albums(&inc),
                BTreeSet::from([canonical.clone()]),
                "{changed}"
            );
            assert!(plan(&inc).is_empty());
        }

        let mut full = fresh();
        full.reverse(); // 与输入顺序无关
        let p = plan(&full);
        apply(&mut full, &p);
        assert_eq!(albums(&full), BTreeSet::from([canonical]));
    }

    #[test]
    fn title_key_folds_symbols_width_and_case() {
        assert_eq!(title_key(DOT), title_key(MID));
        assert_eq!(title_key("ＡＢＣ！"), title_key("abc"));
        assert_ne!(title_key("上"), title_key("下"));
        assert_eq!(title_key("..."), "...");
    }

    #[test]
    fn wire_round_trip() {
        let ms = vec![raw("01", "A", Some("X")), raw("02", "A", None)];
        let mut w = Writer::new();
        w.u32(ms.len() as u32);
        for m in &ms {
            w.str(&m.track_uid);
            w.str(&m.album_uid);
            w.str(&m.path);
            w.str(&m.album_title);
            w.opt_str(m.album_artist.as_deref());
        }
        assert_eq!(decode_members(&w.into_bytes()), Some(ms.clone()));
        assert_eq!(decode_members(&[1, 0, 0]), None);
        let bytes = encode_merges(&plan(&ms));
        let mut r = Reader::new(&bytes);
        assert_eq!(r.u32(), Some(1));
    }
}
