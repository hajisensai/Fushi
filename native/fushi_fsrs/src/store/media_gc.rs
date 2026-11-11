//! 媒体回收（设计 §10.5；策略见 Dart `srs_purge.dart`）：待回收集合、存活引用、「核对存活引用 → 删文件 → 移出集合」。
//!
//! 「扫存活引用 → 删文件」必须对写入原子：中间插进来的编辑 / 恢复 / 撤销 / 对端事件会重新引用某个刚判为无引用的
//! 文件，按过期的结论删掉它就无从找回（HBK-AUDIT-014）。以前靠 Dart 的独占区把「Drift 读 + Dart 删文件 + 写本机状态
//! 行」包起来；现在整段在内核的写锁里、一个 SAVEPOINT 里做（[collect]），文件也在这里删。
//!
//! - 待回收集合是本机状态行里内核持有的键 [KEY]（store/local_state.rs `KERNEL_HELD_KEYS`）：排序的字符串数组，空集合
//!   时没有这个键（与以前 Dart 写下的形态相同）。持久化是为了被跳过（宽限期内）、被叫停或中途崩溃的名字下次接着
//!   处理——笔记已清、候选只在那一轮内存里的话，文件就永远没人回收了。
//! - 存活引用（[live_refs]）= 存活笔记与删除未满保留期的笔记的 `media_refs`（笔记缓存，与缓存行同一次刷新算出）∪
//!   全部笔记类型（含已删除的：可能被恢复）的模板与 CSS 里的引用（含下划线开头的静态文件）。口径原在 Dart
//!   `srsLiveMediaReferences`，现在只在这里；Dart 经只读命令 `media_live_refs` 取同一份。
//! - 媒体文件先于引用它的笔记落盘（Dart `SrsMediaStore.store`，在锁外），所以只删修改时间不晚于 `freshAfter` 的
//!   文件：刚写 / 刚复用、引用可能还没提交的留到下一轮。
//!
//! 事务提交失败时文件已删、名字还在集合里：下一轮读不到文件就移出，幂等。

use std::collections::{BTreeSet, HashSet};
use std::ops::Bound;
use std::path::Path;
use std::time::UNIX_EPOCH;

use rusqlite::{Connection, params};
use serde_json::{Value, json};

use super::caches::{self, CacheConfig};
use super::sync2::transport;
use crate::card_cache;

/// 本机状态行里的键（内核持有）。
pub(crate) const KEY: &str = "mediaGc";

fn sql(e: rusqlite::Error) -> String {
    e.to_string()
}

/// Dart `srsIsBareMediaName`：只认裸文件名（不含路径分隔、不是 `.` / `..`）。
fn is_bare_ref(n: &str) -> bool {
    !n.is_empty() && !n.contains('/') && !n.contains('\\') && n != "." && n != ".."
}

/// 回收只碰媒体目录下的裸文件名（Dart `srs_purge.dart` `_isBareName`：比 [is_bare_ref] 多挡盘符 / 流的冒号）。
fn is_bare_file(n: &str) -> bool {
    is_bare_ref(n) && !n.contains(':')
}

/// 待回收集合（没有本机状态行、没有这个键、行损坏 = 空）。
pub(crate) fn pending(c: &Connection, profile: &str) -> Result<BTreeSet<String>, String> {
    let row: Option<String> = c
        .prepare_cached("SELECT json FROM srs_local_state WHERE profile_uid = srs_id(?1)")
        .map_err(sql)?
        .query_row(params![profile], |r| r.get(0))
        .map(Some)
        .or_else(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            e => Err(sql(e)),
        })?;
    let Some(Ok(Value::Object(m))) = row.map(|j| serde_json::from_str::<Value>(&j)) else {
        return Ok(BTreeSet::new());
    };
    Ok(m.get(KEY)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|n| n.as_str().map(str::to_owned))
        .collect())
}

/// 写下待回收集合（只动 [KEY] 这一个键）。还没有本机状态行且集合非空时先建行（合并协议给内核持有的键补初值）。
fn save(c: &Connection, profile: &str, names: &BTreeSet<String>) -> Result<(), String> {
    if names.is_empty() {
        c.prepare_cached(
            "UPDATE srs_local_state SET json = json_remove(json, '$.mediaGc') \
             WHERE profile_uid = srs_id(?1)",
        )
        .map_err(sql)?
        .execute(params![profile])
        .map_err(sql)?;
        return Ok(());
    }
    c.prepare_cached(
        "INSERT OR IGNORE INTO srs_local_state (profile_uid, json) \
         VALUES (srs_id(?1), srs_local_state_merge(NULL, '{}'))",
    )
    .map_err(sql)?
    .execute(params![profile])
    .map_err(sql)?;
    c.prepare_cached(
        "UPDATE srs_local_state SET json = json_set(json, '$.mediaGc', json(?2)) \
         WHERE profile_uid = srs_id(?1)",
    )
    .map_err(sql)?
    .execute(params![profile, json!(names).to_string()])
    .map_err(sql)?;
    Ok(())
}

fn add_refs(out: &mut BTreeSet<String>, media_refs: &str) {
    out.extend(
        media_refs
            .split('\n')
            .filter(|n| !n.is_empty())
            .map(str::to_owned),
    );
}

/// `media_gc_queue`：把候选并进待回收集合。[req]（都可省）：
/// - `names`：文件名；
/// - `notes`：这些笔记此刻的字段引用的媒体（彻底清除之前调：清除会抹掉字段，之后就读不到它们引用过什么了）；
/// - `expiredBefore`：删除时刻不晚于它的已删笔记的 `media_refs`（过了保留期的候选）。
///
/// 是否真删由 [collect] 再扣掉存活引用。回包 `{"pending": [...]}`（三个都不给 = 只读集合）。
pub(crate) fn queue(c: &Connection, profile: &str, req: &Value) -> Result<Value, String> {
    let mut set = pending(c, profile)?;
    let before = set.len();
    for n in req["names"].as_array().into_iter().flatten() {
        if let Some(n) = n.as_str() {
            set.insert(n.to_owned());
        }
    }
    // 这些笔记的引用从字段现值算（不读缓存列：缓存行可能还没刷到），口径与缓存列相同（[card_cache::media_refs]）。
    let notes: Vec<String> = req["notes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|n| n.as_str().map(str::to_owned))
        .collect();
    for chunk in notes.chunks(500) {
        for n in caches::note_infos(c, chunk)? {
            add_refs(
                &mut set,
                &card_cache::media_refs(n.fields.iter().map(|(_, v)| v.as_str())),
            );
        }
    }
    if let Some(cutoff) = req["expiredBefore"].as_i64() {
        let mut stmt = c
            .prepare_cached(
                "SELECT media_refs FROM srs_notes_cache WHERE profile_uid = srs_id(?1) \
                 AND deleted_at <= ?2 AND media_refs <> ''",
            )
            .map_err(sql)?;
        let mut rows = stmt.query(params![profile, cutoff]).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            add_refs(&mut set, &r.get::<_, String>(0).map_err(sql)?);
        }
    }
    if set.len() != before {
        save(c, profile, &set)?;
    }
    Ok(json!({"pending": set}))
}

/// 存活引用（见模块文档）：[alive_after] = 删除时刻晚于它的已删笔记也算（保留期内恢复笔记媒体还在）。只留裸文件名。
pub(crate) fn live_refs(
    c: &Connection,
    profile: &str,
    cfg: &CacheConfig,
    alive_after: i64,
) -> Result<BTreeSet<String>, String> {
    let mut out: BTreeSet<String> = BTreeSet::new();
    {
        let mut stmt = c
            .prepare_cached(
                "SELECT media_refs FROM srs_notes_cache WHERE profile_uid = srs_id(?1) \
                 AND (deleted_at IS NULL OR deleted_at > ?2) AND media_refs <> ''",
            )
            .map_err(sql)?;
        let mut rows = stmt.query(params![profile, alive_after]).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            add_refs(&mut out, &r.get::<_, String>(0).map_err(sql)?);
        }
    }
    let mut refs: Vec<String> = Vec::new();
    for text in caches::note_type_texts(c, profile, cfg)? {
        card_cache::media_refs_with_static(&text, &mut refs);
    }
    out.extend(refs);
    out.retain(|n| is_bare_ref(n));
    Ok(out)
}

/// `media_gc_collect`：回收待回收集合里此刻没有任何存活引用、且过了宽限期的文件（只删 [root] 下的裸文件名）。[req]：
/// `{"root": 媒体目录, "aliveAfter": ms, "freshAfter": ms, "after"?: 名字, "limit"?: n}`。比较不区分大小写：Windows /
/// macOS 默认卷上大小写不同的两个名字是同一个文件。回包 `{"deleted": n, "next": 名字 | null, "deferred"?: true}`。
///
/// 一条命令只处理集合里排在 `after` 之后的至多 `limit` 个名字（按字节序），还有剩的回 `next`（下一条命令的 `after`）：
/// 命令全程持着写锁做文件 IO，首次回收可能有上千个文件，分成几条让作答等写入插得进来。每条命令各自重算存活引用，
/// 「核对 → 删」的原子性不因分批而变。
///
/// 待刷新的缓存行还没刷完时（`deferred`）什么都不删：存活引用读的是笔记缓存的 `media_refs`，刚收下、缓存行还没刷的
/// 笔记引用的文件在里面看不到（它引用的可以是本机早就有的旧文件，宽限期挡不住）。
///
/// 逐个名字：
/// - 不是裸文件名、或仍被引用：不是垃圾，移出集合（以后引用它的笔记删除满保留期时会重新成为候选）；
/// - 读不到文件信息（不存在等）：移出；
/// - 修改时间晚于 `freshAfter`（刚写 / 刚复用，引用它的笔记可能还没提交）：留到下一轮；
/// - 删掉了：计数、移出；删不掉（Windows 上正在播放 / 预览）：留在集合里，下一轮再试。
pub(crate) fn collect(
    c: &Connection,
    profile: &str,
    cfg: &CacheConfig,
    req: &Value,
) -> Result<Value, String> {
    let root = req["root"]
        .as_str()
        .ok_or("media_gc_collect: missing root")?;
    let alive_after = req["aliveAfter"]
        .as_i64()
        .ok_or("media_gc_collect: missing aliveAfter")?;
    let fresh_after = req["freshAfter"]
        .as_i64()
        .ok_or("media_gc_collect: missing freshAfter")?;
    let limit = req["limit"]
        .as_u64()
        .map_or(usize::MAX, |n| (n as usize).max(1));
    let mut set = pending(c, profile)?;
    if set.is_empty() {
        return Ok(json!({"deleted": 0, "next": Value::Null}));
    }
    // 缓存行还没刷完（收段收尾被打断 / 正在按块刷）：存活引用不全，这一轮不删，名字留着下一轮。
    if transport::cache_is_pending(c, profile)? {
        return Ok(json!({"deleted": 0, "next": Value::Null, "deferred": true}));
    }
    let alive: HashSet<String> = live_refs(c, profile, cfg, alive_after)?
        .iter()
        .map(|n| n.to_lowercase())
        .collect();
    let from = match req["after"].as_str() {
        Some(a) => Bound::Excluded(a),
        None => Bound::Unbounded,
    };
    let mut batch: Vec<String> = set
        .range::<str, _>((from, Bound::Unbounded))
        .take(limit.saturating_add(1))
        .cloned()
        .collect();
    let next = if batch.len() > limit {
        batch.truncate(limit);
        batch.last().cloned()
    } else {
        None
    };
    let mut deleted = 0i64;
    let mut settled: Vec<&String> = Vec::new();
    for name in &batch {
        if !is_bare_file(name) || alive.contains(&name.to_lowercase()) {
            settled.push(name);
            continue;
        }
        let path = Path::new(root).join(name);
        let Ok(meta) = std::fs::metadata(&path) else {
            settled.push(name);
            continue;
        };
        // 读不到修改时间：判不了是不是刚写的，留着。
        let Some(modified_ms) = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as i64)
        else {
            continue;
        };
        if modified_ms > fresh_after {
            continue;
        }
        if std::fs::remove_file(&path).is_ok() {
            deleted += 1;
            settled.push(name);
        }
    }
    if !settled.is_empty() {
        for n in settled {
            set.remove(n);
        }
        save(c, profile, &set)?;
    }
    Ok(json!({"deleted": deleted, "next": next}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::sync2::tests::{Device, P, deck_entity, edit, tempdir};

    const T0: i64 = 1_700_000_000_000;
    const DAY: i64 = 86_400_000;
    const NT: &str = "0193a1b2-0000-7000-8000-00000000f0a1";
    const NT_DEAD: &str = "0193a1b2-0000-7000-8000-00000000f0a2";
    const LIVE: &str = "0193a1b2-0000-7000-8000-00000000f0b1";
    const RECENT: &str = "0193a1b2-0000-7000-8000-00000000f0b2";
    const OLD: &str = "0193a1b2-0000-7000-8000-00000000f0b3";

    fn default_deck() -> String {
        crate::store::sync2::config::default_deck_id(P)
    }

    fn dispatch(d: &Device, mut req: Value) -> Value {
        req["profile"] = json!(P);
        req["caches"] = json!({"defaultDeck": default_deck()});
        crate::store::ffi::sync2_dispatch(&d.core, &req, &mut Vec::new(), &mut Vec::new()).unwrap()
    }

    fn apply(d: &Device, now: i64, events: Vec<Value>) -> Value {
        let items: Vec<Value> = events
            .into_iter()
            .map(|e| json!({"e": e, "note": null}))
            .collect();
        let mut blobs = vec![Value::Array(items).to_string().into_bytes()];
        crate::store::ffi::sync2_dispatch(
            &d.core,
            &json!({
                "op": "apply", "profile": P, "now": now, "caches": {"defaultDeck": default_deck()},
                "legacyDevice": "dev", "tickNow": now, "localState": "{}",
            }),
            &mut blobs,
            &mut Vec::new(),
        )
        .unwrap()
    }

    fn note(id: &str, front: &str) -> Vec<Value> {
        vec![
            json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": NT}}}),
            edit("note", id, "f/a", json!(front)),
        ]
    }

    fn note_type(id: &str, front: &str, css: &str) -> Vec<Value> {
        vec![
            json!({"t": "entity", "x": {"id": id, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            edit("notetype", id, "fieldDef/a", json!({"name": "A", "ord": 0})),
            edit(
                "notetype",
                id,
                "tmplDef/t1",
                json!({"name": "t1", "ord": 0, "front": front}),
            ),
            edit(
                "notetype",
                id,
                "tmplDef/t2",
                json!({"name": "t2", "ord": 1, "front": "{{A}}<img src=\"gone-template.png\">", "deleted": true}),
            ),
            edit("notetype", id, "css", json!(css)),
        ]
    }

    /// 一条存活笔记、一条删除 1 天的、一条删除 100 天的；一个存活的笔记类型、一个已删除的笔记类型。
    fn library(tag: &str) -> Device {
        let d = Device::new(tag);
        let mut events = vec![deck_entity(&default_deck())];
        events.extend(note_type(
            NT,
            "{{A}}<img src=\"tpl.png\">[sound:tpl.mp3]",
            // 纯 CSS：没有 `<`，只有静态引用。
            ".card { font-family: f; } @font-face { src: url(\"_font.woff\"); } .x { background: url( '_bg one.png' ) }",
        ));
        events.extend(note_type(
            NT_DEAD,
            "{{A}}<script src=\"_dead.js\"></script>",
            "",
        ));
        events.push(edit("notetype", NT_DEAD, "deleted", json!(T0)));
        events.extend(note(
            LIVE,
            "<img src=\"live.png\"><img src=\"c:colon.png\"><img src=\"sub/dir.png\">",
        ));
        events.extend(note(RECENT, "[sound:recent.mp3]<img src=\"Shared.PNG\">"));
        events.extend(note(OLD, "<img src=\"old.png\"><img src=\"shared.png\">"));
        events.push(edit("note", RECENT, "deleted", json!(T0 - DAY)));
        events.push(edit("note", OLD, "deleted", json!(T0 - 100 * DAY)));
        apply(&d, T0, events);
        d
    }

    fn names(v: &Value) -> Vec<&str> {
        v.as_array()
            .unwrap()
            .iter()
            .map(|n| n.as_str().unwrap())
            .collect()
    }

    fn state_row(d: &Device) -> Option<Value> {
        d.rows(&format!(
            "SELECT json FROM srs_local_state WHERE profile_uid = srs_id('{P}')"
        ))
        .get(1)
        .map(|r| serde_json::from_str(&r[0]).unwrap())
    }

    fn touch(dir: &tempdir::Dir, name: &str) {
        std::fs::write(dir.0.join(name), b"x").unwrap();
    }

    fn collect(d: &Device, dir: &tempdir::Dir, fresh_after: i64, extra: Value) -> Value {
        let mut req = json!({
            "op": "media_gc_collect", "root": dir.0.to_str().unwrap(),
            "aliveAfter": T0 - 90 * DAY, "freshAfter": fresh_after,
        });
        for (k, v) in extra.as_object().into_iter().flatten() {
            req[k] = v.clone();
        }
        dispatch(d, req)
    }

    /// 远在将来：所有文件都过了宽限期。
    const SETTLED: i64 = i64::MAX;

    #[test]
    fn live_refs_cover_notes_within_retention_and_every_note_type() {
        let d = library("mgc-live");
        let r = dispatch(
            &d,
            json!({"op": "media_live_refs", "aliveAfter": T0 - 90 * DAY}),
        );
        // 存活笔记 + 删除未满保留期的；全部笔记类型（含已删除的）未删模板与 CSS，含下划线开头的静态文件；带冒号的
        // 名字是合法引用（只有回收删文件时不碰它）；带路径的不算；已删模板（t2）与删除满保留期的笔记不算。
        assert_eq!(
            names(&r["refs"]),
            [
                "Shared.PNG",
                "_bg",
                "_dead.js",
                "_font.woff",
                "c:colon.png",
                "live.png",
                "recent.mp3",
                "tpl.mp3",
                "tpl.png",
            ],
            "{r}"
        );
        // 保留期往前挪到 200 天：删除 100 天的笔记也算。
        let r = dispatch(
            &d,
            json!({"op": "media_live_refs", "aliveAfter": T0 - 200 * DAY}),
        );
        assert!(names(&r["refs"]).contains(&"old.png"), "{r}");
    }

    #[test]
    fn the_static_scan_matches_the_dart_pattern() {
        let refs = |text: &str| {
            let mut out = Vec::new();
            card_cache::media_refs_with_static(text, &mut out);
            out
        };
        // 没有 `<` 也没有 `[sound:` 的文本（CSS）照样扫静态引用。
        assert_eq!(refs("a { src: url(_a.woff) }"), ["_a.woff"]);
        assert_eq!(refs("url( \"_b c.png\" )"), ["_b"]);
        assert_eq!(refs("url('_d.png')url(\"_e.png\")"), ["_d.png", "_e.png"]);
        // 单独一个下划线、不在引号 / 括号后面的不算；百分号编码与实体照常反转义。
        assert_eq!(refs("(_) x_y.png \"_\" '_f%20g.png'"), ["_f g.png"]);
        assert_eq!(refs("(\u{feff}_bom.png)"), ["_bom.png"]);
        assert_eq!(
            refs("<img src=\"_s.png\">[sound:t.mp3]"),
            ["_s.png", "t.mp3", "_s.png"]
        );
    }

    #[test]
    fn candidates_are_queued_into_the_kernel_held_key() {
        let d = library("mgc-queue");
        assert_eq!(
            dispatch(&d, json!({"op": "media_gc_queue"}))["pending"],
            json!([])
        );
        // 过了保留期的已删笔记引用的。
        let r = dispatch(
            &d,
            json!({"op": "media_gc_queue", "expiredBefore": T0 - 90 * DAY}),
        );
        assert_eq!(names(&r["pending"]), ["old.png", "shared.png"], "{r}");
        // 这些笔记此刻引用的（从字段现值算）、直接给的名字；不存在的笔记跳过。
        let r = dispatch(
            &d,
            json!({"op": "media_gc_queue", "notes": [LIVE, "0193a1b2-0000-7000-8000-00000000f0bf"], "names": ["x.png"]}),
        );
        assert_eq!(
            names(&r["pending"]),
            [
                "c:colon.png",
                "live.png",
                "old.png",
                "shared.png",
                "sub/dir.png",
                "x.png"
            ],
            "{r}"
        );
        let row = state_row(&d).unwrap();
        assert_eq!(row["mediaGc"], r["pending"]);
        // Dart 交来的本机状态行不带这个键（它不持有）：合并协议保留库里的值。
        apply(
            &d,
            T0 + 1,
            note("0193a1b2-0000-7000-8000-00000000f0b9", "plain"),
        );
        assert_eq!(state_row(&d).unwrap()["mediaGc"], r["pending"]);
        assert_eq!(
            dispatch(&d, json!({"op": "media_gc_queue"}))["pending"],
            r["pending"]
        );
    }

    #[test]
    fn collect_deletes_only_unreferenced_settled_files() {
        let d = library("mgc-collect");
        let dir = tempdir::new("mgc-collect-media");
        for n in [
            "old.png",
            "shared.png",
            "live.png",
            "tpl.png",
            "_font.woff",
            "fresh.png",
        ] {
            touch(&dir, n);
        }
        std::fs::create_dir(dir.0.join("a-dir")).unwrap();
        dispatch(
            &d,
            json!({"op": "media_gc_queue", "names": [
                "old.png", "shared.png", "live.png", "tpl.png", "_font.woff", "missing.png",
                "a-dir", "../escape.png", "c:colon.png",
            ]}),
        );
        let r = collect(&d, &dir, SETTLED, json!({}));
        // 只有 old.png 没人引用：shared.png 被删除未满保留期的笔记引用着（大小写不同算同一个文件）。
        assert_eq!(r, json!({"deleted": 1, "next": null}), "{r}");
        assert!(!dir.0.join("old.png").exists());
        for kept in [
            "shared.png",
            "live.png",
            "tpl.png",
            "_font.woff",
            "fresh.png",
        ] {
            assert!(dir.0.join(kept).exists(), "{kept}");
        }
        // 仍被引用的、不存在的、不是裸文件名的都移出集合；删不掉的（目录）留着下一轮再试。
        assert_eq!(
            names(&dispatch(&d, json!({"op": "media_gc_queue"}))["pending"]),
            ["a-dir"]
        );
        // 宽限期内的文件（修改时间晚于 freshAfter）不删、留在集合里。
        dispatch(&d, json!({"op": "media_gc_queue", "names": ["fresh.png"]}));
        let r = collect(&d, &dir, 0, json!({}));
        assert_eq!(r["deleted"], json!(0), "{r}");
        assert!(dir.0.join("fresh.png").exists());
        assert_eq!(
            names(&dispatch(&d, json!({"op": "media_gc_queue"}))["pending"]),
            ["a-dir", "fresh.png"]
        );
        // 集合清空之后本机状态行里没有这个键（与以前 Dart 写下的形态相同）。
        std::fs::remove_dir(dir.0.join("a-dir")).unwrap();
        assert_eq!(collect(&d, &dir, SETTLED, json!({}))["deleted"], json!(1));
        assert!(state_row(&d).unwrap().get("mediaGc").is_none());
    }

    #[test]
    fn collect_works_in_batches_and_resumes_after_the_cursor() {
        let d = library("mgc-batch");
        let dir = tempdir::new("mgc-batch-media");
        let all = ["g1.png", "g2.png", "g3.png", "g4.png", "g5.png"];
        for n in all {
            touch(&dir, n);
        }
        dispatch(&d, json!({"op": "media_gc_queue", "names": all}));
        let r = collect(&d, &dir, SETTLED, json!({"limit": 2}));
        assert_eq!(r, json!({"deleted": 2, "next": "g2.png"}), "{r}");
        let r = collect(&d, &dir, SETTLED, json!({"limit": 2, "after": "g2.png"}));
        assert_eq!(r, json!({"deleted": 2, "next": "g4.png"}), "{r}");
        let r = collect(&d, &dir, SETTLED, json!({"limit": 2, "after": "g4.png"}));
        assert_eq!(r, json!({"deleted": 1, "next": null}), "{r}");
        assert!(all.iter().all(|n| !dir.0.join(n).exists()));
        assert_eq!(
            dispatch(&d, json!({"op": "media_gc_queue"}))["pending"],
            json!([])
        );
    }

    #[test]
    fn collect_waits_while_cache_rows_are_pending() {
        let d = library("mgc-pending");
        let dir = tempdir::new("mgc-pending-media");
        touch(&dir, "old.png");
        dispatch(&d, json!({"op": "media_gc_queue", "names": ["old.png"]}));
        // 有待刷新的缓存行：存活引用不全，这一轮不删。
        d.core
            .writer()
            .unwrap()
            .execute(
                "INSERT INTO sync2_cache_pending (profile_uid, kind, entity_id) \
                 VALUES (srs_id(?1), 0, srs_id(?2))",
                rusqlite::params![P, LIVE],
            )
            .unwrap();
        let r = collect(&d, &dir, SETTLED, json!({}));
        assert_eq!(
            r,
            json!({"deleted": 0, "next": null, "deferred": true}),
            "{r}"
        );
        assert!(dir.0.join("old.png").exists());
        d.core
            .writer()
            .unwrap()
            .execute("DELETE FROM sync2_cache_pending", [])
            .unwrap();
        assert_eq!(collect(&d, &dir, SETTLED, json!({}))["deleted"], json!(1));
    }

    /// 被别的进程 / 播放器占着（没给删除共享）的文件删不掉：留在集合里，下一轮再试。
    #[cfg(windows)]
    #[test]
    fn a_file_in_use_stays_queued() {
        use std::os::windows::fs::OpenOptionsExt;
        let d = library("mgc-locked");
        let dir = tempdir::new("mgc-locked-media");
        touch(&dir, "busy.mp3");
        dispatch(&d, json!({"op": "media_gc_queue", "names": ["busy.mp3"]}));
        let held = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(1) // FILE_SHARE_READ：不给删除共享
            .open(dir.0.join("busy.mp3"))
            .unwrap();
        assert_eq!(collect(&d, &dir, SETTLED, json!({}))["deleted"], json!(0));
        assert_eq!(
            names(&dispatch(&d, json!({"op": "media_gc_queue"}))["pending"]),
            ["busy.mp3"]
        );
        drop(held);
        assert_eq!(collect(&d, &dir, SETTLED, json!({}))["deleted"], json!(1));
    }

    #[test]
    fn bare_names_only() {
        for ok in ["a.png", "_font.woff", "名前.mp3", "a b.png"] {
            assert!(is_bare_ref(ok) && is_bare_file(ok), "{ok}");
        }
        for bad in ["", ".", "..", "a/b.png", "a\\b.png"] {
            assert!(!is_bare_ref(bad) && !is_bare_file(bad), "{bad}");
        }
        // 冒号（盘符 / NTFS 流）：引用口径不挡，回收时不碰。
        assert!(is_bare_ref("c:x.png") && !is_bare_file("c:x.png"));
    }
}
