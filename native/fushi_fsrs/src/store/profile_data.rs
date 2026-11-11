//! 一个 profile 在 `srs.db` 里的全部本机数据：统计、整体删除、找无主数据（反馈 8TaOy2i-lL 现象 3）。
//!
//! `srs.db` 是所有 profile 共用的一个文件，每张按 profile 分的表都有 `profile_uid` 列。删 profile 以前只删主库
//! `profiles` 行，这里的行全部留下成了无主副本。这里给 Dart 三条粗粒度命令（经 `ffsrs_store_sync2` 分派）：
//!
//! - [SrsCore::profile_footprint]：确认框要显示的笔记 / 卡 / 复习记录数（读连接上一次读完）；
//! - [SrsCore::profile_purge]：一个事务里删掉该 uid 在**每一张**带 `profile_uid` 列的 `srs_*` / `sync2_*` 表里的
//!   行、`srs_meta` 里按 profile 记的键（`…/<uid>` 与 `…/<uid>/…`），再回收没人引用的 `sync2_deps`。删本机一个
//!   uid 的唯一实现：删 profile、并入（srs_profile_merge.dart）、采用别的 uid（srs_backup_merge.dart）都经它；
//! - [SrsCore::profile_uids]：库里出现过的全部 uid（Dart 与主库现存 profile 比对得出无主 uid）+ 一次性存量扫描的
//!   完成标记；
//! - [SrsCore::orphan_sweep_done]：存量扫描的收尾——表里已经没有任何行、只剩 `srs_meta` 键的无主 uid 的键，和没有
//!   任何操作引用的 `sync2_deps`，清完写完成标记。
//!
//! 表清单按 `sqlite_master` + `pragma_table_info` 现查，不手抄：以后加的按 profile 分的表自动落进删除面
//! （回归测试 `every_profile_table_is_purged` 钉住「除 `srs_meta` / `sync2_deps` 外每张表都有 `profile_uid`」）。
//! 只动本机：远端存储位置上已同步的集合一个字节也不碰（`sync2_locations` 只是本机记的上传进度）。

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value, json};

use super::SrsCore;
use super::sync2::{in_savepoint, sql};
use std::sync::atomic::Ordering;

/// `srs_meta` 里一次性存量无主数据扫描的完成标记（值 = 完成时刻毫秒）。
///
/// v2（BUG-4387）：v1 记下之后，并入（srs_profile_merge.dart）与采用 uid（srs_backup_merge.dart）还各有一份手抄的
/// 删除实现，直到 BUG-4292 才收成本文件的 [SrsCore::profile_purge]：采用只删 10 张 `srs_*` 表、`sync2_*` 一张不删，
/// 并入按 `sqlite_master` 原序删、按 profile 的 `srs_meta` 键只删两个。v1 扫过的库里这些残留永远不会再被扫到，所以
/// 换一个键让扫描（同一套判定、同一个 [SrsCore::profile_purge]）再跑一次。旧键留着不删（没人再读）。
///
/// v3：v2 的扫描只认「表里还有行」的 uid，表里已经没有行、只剩 `srs_meta` 键的 uid（[meta_only_uids]）与没人引用的
/// `sync2_deps` 不在它的清理面里；收尾（[SrsCore::orphan_sweep_done]）补上这两类之后再换一次键，v2 扫过的库再扫一次。
pub(crate) const ORPHAN_SWEEP_KEY: &str = "profile_orphan_sweep_v3";

/// 按 profile 记的 `srs_meta` 键里，profile uid 是**最后一段**的前缀（`<前缀><uid>`；`sync2_sealed/` 中间还有一段
/// 位置 ID，位置 ID 里可以有 `/`，uid 仍是最后一个 `/` 之后那段）。写的地方：sync2/devices.rs `self_key`，
/// transport.rs `fork_key` / 状态摘要，sync2/mod.rs `MIGRATING_KEY`，sealed.rs `key`。
const META_PROFILE_LAST: [&str; 6] = [
    "sync2_self_info/",
    "sync2_fork_at/",
    "sync2_digest/",
    "sync2_digest_at/",
    "sync2_migrating/",
    "sync2_sealed/",
];

/// 同上，profile uid 是前缀之后**第一段**的（`<前缀><uid>/<设备或位置>`；devices.rs `ext_prefix` /
/// `retired_prefix`，transport.rs 的 head 签名）。
const META_PROFILE_FIRST: [&str; 3] = ["sync2_device_ext/", "sync2_retired/", "sync2_head_sig/"];

/// 带 UUID 但 [meta_only_uids] **不取** uid 的键前缀：
/// - `sync2_device_hint/<设备>`（devices.rs `hint_key`）：设备 ID 全局唯一、不分 profile。把设备 ID 当成无主 profile
///   去删，会连带删掉活 profile 名下 `sync2_device_ext/<profile>/<设备>`、`sync2_retired/<profile>/<设备>`
///   （[delete_profile_meta] 按 `…/<uid>` 结尾匹配）；
/// - 并入标记 `profile_merge/<旧 uid>`（Dart srs_profile_merge.dart）：没做完的并入从来不是这里要清的残留。
#[cfg(test)]
const META_NOT_PROFILE: [&str; 2] = ["sync2_device_hint/", "profile_merge/"];

/// 带 `profile_uid` 列的 `srs_*` / `sync2_*` 表（按名字排序）。删除按这个顺序：投影表（`srs_entities` /
/// `srs_field_edits` / `srs_review_logs`）的删除触发器往 `sync2_digest_buckets` 记负项（sync2/digest.rs），按名字它排在
/// 三张投影表之后，删到它时触发器写下的行一并删掉。
fn profile_tables(c: &Connection) -> Result<Vec<String>, String> {
    let mut stmt = c
        .prepare(
            "SELECT m.name FROM sqlite_master m \
             WHERE m.type = 'table' \
               AND (m.name LIKE 'srs\\_%' ESCAPE '\\' OR m.name LIKE 'sync2\\_%' ESCAPE '\\') \
               AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) WHERE name = 'profile_uid') \
             ORDER BY m.name",
        )
        .map_err(sql)?;
    let names = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(sql)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(sql)?;
    Ok(names)
}

/// [profile] 在各张按 profile 分的表里的总行数。
fn table_rows(c: &Connection, profile: &str) -> Result<i64, String> {
    let mut rows = 0i64;
    for t in profile_tables(c)? {
        rows += c
            .query_row(
                &format!("SELECT COUNT(*) FROM \"{t}\" WHERE profile_uid = srs_id(?1)"),
                [profile],
                |r| r.get::<_, i64>(0),
            )
            .map_err(sql)?;
    }
    Ok(rows)
}

/// 删掉按 [profile] 记的元数据键：`<前缀>/<uid>`（迁移进度、状态摘要、并入标记…）或 `<前缀>/<uid>/<下级>`（别的
/// 设备的扩展 / 停用标记、各位置的 head 签名，sync2/devices.rs、transport.rs）；uid 是 UUID，不会误伤别的键。
/// 返回删掉的键数。
fn delete_profile_meta(c: &Connection, profile: &str) -> Result<i64, String> {
    c.execute(
        "DELETE FROM srs_meta WHERE substr(key, -length(?1) - 1) = '/' || ?1 \
         OR instr(key, '/' || ?1 || '/') > 0",
        [profile],
    )
    .map(|n| n as i64)
    .map_err(sql)
}

/// 回收没有任何操作引用的因果上下文（`sync2_deps` 跨 profile 共用，按引用回收）。返回删掉的行数。
///
/// 为什么随时可以删：一行 `sync2_deps` 只经 `sync2_ops.deps` 被读到（sync2/mod.rs `load_op`、mvr.rs、channel.rs
/// `read_ops` 都是从操作连过来），没有操作引用的行谁也读不到；之后再有操作带同样的版本向量，`intern_deps` 重新
/// 插一行。内存里记着行号的只有收段会话的 `Append::deps`（channel.rs）：它记下的每个行号都是本会话刚插的操作引用
/// 着的，那些操作只会被 [SrsCore::profile_purge]（同时作废该会话）删掉，所以这里删不到它记着的行。
fn gc_deps(c: &Connection) -> Result<i64, String> {
    c.execute(
        "DELETE FROM sync2_deps WHERE id NOT IN (SELECT deps FROM sync2_ops)",
        [],
    )
    .map(|n| n as i64)
    .map_err(sql)
}

/// [key] 是按 profile 记的键时，取出其中的 profile uid（只认 [META_PROFILE_LAST] / [META_PROFILE_FIRST] 里登记过
/// 写法的键，且那一段是规范 UUID 文本）；别的键 None。
fn meta_profile_of(key: &str) -> Option<&str> {
    let uid = META_PROFILE_FIRST
        .iter()
        .find_map(|p| key.strip_prefix(p)?.split_once('/').map(|(uid, _)| uid))
        .or_else(|| {
            META_PROFILE_LAST
                .iter()
                .find_map(|p| key.strip_prefix(p)?.rsplit('/').next())
        })?;
    super::ids::pack(uid).map(|_| uid)
}

/// 表里已经没有任何行、只剩按 profile 记的 `srs_meta` 键的 uid（排序、去重）。
///
/// 怎么来的：BUG-4292 之前删 profile 的 Rust 实现只删 `…/<uid>` 结尾的键，uid 在中间的
/// （`sync2_device_ext/<uid>/…`、`sync2_retired/<uid>/…`、`sync2_head_sig/<uid>/…`）留下；同期并入的手抄删除按
/// profile 的键只删两个。表行删光之后这些 uid 不再出现在 [SrsCore::profile_uids] 里，没有任何清理路径看得到它们。
fn meta_only_uids(c: &Connection) -> Result<Vec<String>, String> {
    let keys: Vec<String> = c
        .prepare("SELECT key FROM srs_meta")
        .map_err(sql)?
        .query_map([], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut uids: Vec<String> = keys
        .iter()
        .filter_map(|k| meta_profile_of(k))
        .map(str::to_owned)
        .collect();
    uids.sort();
    uids.dedup();
    let mut out = Vec::new();
    for uid in uids {
        if table_rows(c, &uid)? == 0 {
            out.push(uid);
        }
    }
    Ok(out)
}

/// 用户看得见的规模：未删除的笔记、它们的卡、全部复习记录；外加该 uid 在各表里的总行数。
fn footprint(c: &Connection, profile: &str) -> Result<Value, String> {
    let count =
        |q: &str| -> Result<i64, String> { c.query_row(q, [profile], |r| r.get(0)).map_err(sql) };
    let notes = count(
        "SELECT COUNT(*) FROM srs_notes_cache WHERE profile_uid = srs_id(?1) AND deleted_at IS NULL",
    )?;
    let cards = count(
        "SELECT COUNT(*) FROM srs_cards_cache c WHERE c.profile_uid = srs_id(?1) AND EXISTS \
         (SELECT 1 FROM srs_notes_cache n WHERE n.id = c.note_id AND n.deleted_at IS NULL)",
    )?;
    let reviews = count("SELECT COUNT(*) FROM srs_review_logs WHERE profile_uid = srs_id(?1)")?;
    let rows = table_rows(c, profile)?;
    Ok(json!({"notes": notes, "cards": cards, "reviews": reviews, "rows": rows}))
}

impl SrsCore {
    /// [profile] 的规模（`{notes, cards, reviews, rows}`）。读连接上一个读事务：几个数出自同一快照。
    pub fn profile_footprint(&self, profile: &str) -> Result<Value, String> {
        let r = self.reader()?;
        r.execute_batch("BEGIN").map_err(sql)?;
        let out = footprint(&r, profile);
        r.execute_batch("COMMIT").map_err(sql)?;
        out
    }

    /// 删掉 [profile] 在本机 srs.db 里的全部数据（一个 savepoint：要么全删，要么一行不动）。返回删之前的
    /// 规模（同 [Self::profile_footprint]）加 `deleted`（实际删掉的总行数）与 `tables`（逐表行数，只列非零的）。
    /// 这个 uid 正在分批收段的会话一并作废。旧库搬迁事务开着时拒绝（搬迁会整表重写）。
    pub fn profile_purge(&self, profile: &str) -> Result<Value, String> {
        if profile.is_empty() {
            return Err("profile_purge: empty profile uid".into());
        }
        // 先取写锁再看 `legacy_open`（同 [SrsCore::exec]）。
        let w = self.writer()?;
        if self.legacy_open.load(Ordering::SeqCst) {
            return Err("legacy import in progress".into());
        }
        let out = in_savepoint(&w, |c| {
            let mut out = footprint(c, profile)?;
            let mut tables = Map::new();
            let mut deleted = 0i64;
            for t in profile_tables(c)? {
                let n = c
                    .execute(
                        &format!("DELETE FROM \"{t}\" WHERE profile_uid = srs_id(?1)"),
                        [profile],
                    )
                    .map_err(sql)? as i64;
                if n > 0 {
                    tables.insert(t, json!(n));
                }
                deleted += n;
            }
            let meta = delete_profile_meta(c, profile)?;
            if meta > 0 {
                tables.insert("srs_meta".into(), json!(meta));
            }
            // 迁移队列是按需建的表（没迁移过的库里没有它），表清单查询已经把它算进去了；因果上下文跨 profile 共用，
            // 只回收已经没有任何操作引用的。
            let deps = gc_deps(c)?;
            if deps > 0 {
                tables.insert("sync2_deps".into(), json!(deps));
            }
            out["deleted"] = json!(deleted + meta + deps);
            out["tables"] = Value::Object(tables);
            Ok(out)
        })?;
        // 正在收这个 profile 的会话（或它的收尾）一起放掉，连同留着的页缓存。
        self.sync2_ingest_end(profile)?;
        Ok(out)
    }

    /// srs.db 里出现过数据的全部 uid（`{uids: [...], orphanSweptAt: 毫秒 | null}`）。
    pub fn profile_uids(&self) -> Result<Value, String> {
        let r = self.reader()?;
        r.execute_batch("BEGIN").map_err(sql)?;
        let out = (|| {
            let tables = profile_tables(&r)?;
            let mut uids: Vec<String> = Vec::new();
            if !tables.is_empty() {
                let union = tables
                    .iter()
                    .map(|t| format!("SELECT srs_idt(profile_uid) AS profile_uid FROM \"{t}\""))
                    .collect::<Vec<_>>()
                    .join(" UNION ");
                let mut stmt = r.prepare(&format!("SELECT srs_idt(profile_uid) AS profile_uid FROM ({union}) ORDER BY profile_uid")).map_err(sql)?;
                uids = stmt
                    .query_map([], |x| x.get::<_, String>(0))
                    .map_err(sql)?
                    .collect::<Result<_, _>>()
                    .map_err(sql)?;
            }
            let swept: Option<i64> = r
                .query_row(
                    "SELECT value FROM srs_meta WHERE key = ?1",
                    [ORPHAN_SWEEP_KEY],
                    |x| x.get::<_, String>(0),
                )
                .optional()
                .map_err(sql)?
                .and_then(|v| v.parse().ok());
            Ok::<_, String>(json!({"uids": uids, "orphanSweptAt": swept}))
        })();
        r.execute_batch("COMMIT").map_err(sql)?;
        out
    }

    /// 存量扫描的收尾（Dart 逐个清完表里还有行的无主 uid 之后调；一个 savepoint）：
    ///
    /// 1. 表里已经没有任何行、只剩 `srs_meta` 键的 uid（[meta_only_uids]）里，不在 [keep] 中的，删掉它名下的键
    ///    （与 [Self::profile_purge] 同一条删除，[delete_profile_meta]）。[keep] = 主库现存 profile 的 uid 加进行中
    ///    并入涉及的 uid（Dart 给：并入标记的格式归 srs_profile_merge.dart）。「表里没有行」与删除在同一个 savepoint
    ///    里判：Dart 算 [keep] 之后才开始的并入，目标 uid 一开副本就有了行，这里就不再动它；
    /// 2. 回收没有任何操作引用的 `sync2_deps`（[gc_deps]）；
    /// 3. [mark] 为真时写完成标记（[ORPHAN_SWEEP_KEY]，之后不再扫）；有进行中的并入时 Dart 传 false，下次再扫。
    ///
    /// 返回 `{metaUids: [清掉键的 uid…], meta: 删掉的键数, deps: 回收的行数}`。旧库搬迁事务开着时拒绝（同
    /// [Self::profile_purge]）。重复调用幂等：第二次没有可清的。
    pub fn orphan_sweep_done(
        &self,
        now: i64,
        keep: &[String],
        mark: bool,
    ) -> Result<Value, String> {
        // 先取写锁再看 `legacy_open`（同 [SrsCore::profile_purge]）。
        let w = self.writer()?;
        if self.legacy_open.load(Ordering::SeqCst) {
            return Err("legacy import in progress".into());
        }
        in_savepoint(&w, |c| {
            let mut cleared: Vec<String> = Vec::new();
            let mut meta = 0i64;
            for uid in meta_only_uids(c)? {
                if keep.contains(&uid) {
                    continue;
                }
                meta += delete_profile_meta(c, &uid)?;
                cleared.push(uid);
            }
            let deps = gc_deps(c)?;
            if mark {
                c.execute(
                    "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    params![ORPHAN_SWEEP_KEY, now.to_string()],
                )
                .map_err(sql)?;
            }
            Ok(json!({"metaUids": cleared, "meta": meta, "deps": deps}))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::sync2::tests::{P, deck_entity, review, tempdir};
    use serde_json::json;
    use std::collections::BTreeSet;

    const Q: &str = "0193a1b2-0000-7000-8000-00000000cafe";

    /// 不按 profile 分、删除时不按 uid 删的表：库级元数据（按 profile 的键单独按后缀删）、跨 profile 去重存的
    /// 因果上下文（按引用回收）。
    // sync2_snapshots：配置快照原文按内容共用、只增（store/sync2/snapshots.rs），删 profile 后剩下的几行无害。
    const SHARED_TABLES: [&str; 3] = ["srs_meta", "sync2_deps", "sync2_snapshots"];

    fn open(tag: &str) -> (SrsCore, tempdir::Dir) {
        let dir = tempdir::new(tag);
        let core = SrsCore::open(&dir.0.join("srs.db")).unwrap();
        (core, dir)
    }

    fn count(core: &SrsCore, q: &str) -> i64 {
        let w = core.writer().unwrap();
        w.query_row(q, [], |r| r.get(0)).unwrap()
    }

    /// 给 [profile] 落一套真实数据：经同步 v2 的本机写入（ops + 投影 + 设备 / 身份），再补缓存行、迁移队列、
    /// 按 profile 记的元数据键。
    fn seed(core: &SrsCore, profile: &str, notes: usize, logs: usize) {
        let mut events = vec![deck_entity(&format!("D-{profile}"))];
        for i in 0..logs {
            events.push(review(
                &format!("L-{profile}-{i}"),
                &format!("C-{profile}-0"),
                1_700_000_000_000 + i as i64,
                3,
                "learn",
            ));
        }
        let events: Vec<Value> = events
            .into_iter()
            .map(|mut e| {
                e["x"]["p"] = json!(profile);
                json!({"e": e, "note": format!("N-{profile}-0")})
            })
            .collect();
        core.sync2_identity(profile, 1).unwrap();
        core.sync2_apply_local(profile, 2, &Value::Array(events).to_string())
            .unwrap();
        core.sync2_digest(profile).unwrap();
        let w = core.writer().unwrap();
        for i in 0..notes {
            let deleted: Option<i64> = if i == 0 && notes > 1 { Some(5) } else { None };
            w.execute(
                "INSERT INTO srs_notes_cache (id, profile_uid, note_type_id, guid, created_at, deleted_at) VALUES (srs_id(?1), srs_id(?2), 'NT', ?1, 1, ?3)",
                params![format!("N-{profile}-{i}"), profile, deleted],
            )
            .unwrap();
            w.execute(
                "INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id) VALUES (srs_id(?1), srs_id(?2), srs_id(?3), 'T', 'D')",
                params![format!("C-{profile}-{i}"), profile, format!("N-{profile}-{i}")],
            )
            .unwrap();
        }
        w.execute(
            "INSERT INTO srs_local_state (profile_uid, json) VALUES (srs_id(?1), '{}')",
            [profile],
        )
        .unwrap();
        w.execute_batch(
            "CREATE TABLE IF NOT EXISTS sync2_migrate_queue (profile_uid UUIDTEXT NOT NULL, pos INTEGER NOT NULL, \
             phase INTEGER NOT NULL, src TEXT NOT NULL, PRIMARY KEY (profile_uid, pos)) WITHOUT ROWID;",
        )
        .unwrap();
        w.execute("INSERT INTO sync2_migrate_queue (profile_uid, pos, phase, src) VALUES (srs_id(?1), 1, 0, 'x')", [profile]).unwrap();
        w.execute(
            "INSERT INTO srs_meta (key, value) VALUES ('sync2_migrating/' || ?1, '1')",
            [profile],
        )
        .unwrap();
        // uid 在中间的按 profile 记的键（sync2/devices.rs 的设备扩展 / 停用标记，transport.rs 的 head 签名）。
        for prefix in ["sync2_device_ext", "sync2_retired", "sync2_head_sig"] {
            w.execute(
                "INSERT INTO srs_meta (key, value) VALUES (?1 || '/' || ?2 || '/x', '{}')",
                params![prefix, profile],
            )
            .unwrap();
        }
    }

    /// [profile] 名下按 profile 记的 `srs_meta` 键数（`…/<uid>` 或 `…/<uid>/…`）。
    fn meta_of(core: &SrsCore, profile: &str) -> i64 {
        let w = core.writer().unwrap();
        w.query_row(
            "SELECT COUNT(*) FROM srs_meta WHERE key LIKE '%/' || ?1 OR key LIKE '%/' || ?1 || '/%'",
            [profile],
            |r| r.get(0),
        )
        .unwrap()
    }

    fn rows_of(core: &SrsCore, profile: &str) -> i64 {
        core.profile_footprint(profile).unwrap()["rows"]
            .as_i64()
            .unwrap()
    }

    /// 回归（8TaOy2i-lL 现象 3）：删一个 profile 后它在每张按 profile 分的表、按 profile 记的元数据里一行不剩；
    /// 另一个 profile 原样不动（含它仍在用的因果上下文）。
    #[test]
    fn purge_removes_every_row_of_the_profile_and_keeps_the_other() {
        let (core, _d) = open("purge");
        seed(&core, P, 3, 4);
        seed(&core, Q, 2, 2);
        let q_before = core.profile_footprint(Q).unwrap();
        let deps_before = count(&core, "SELECT COUNT(*) FROM sync2_deps");
        assert!(
            count(
                &core,
                &format!("SELECT COUNT(*) FROM sync2_ops WHERE profile_uid = srs_id('{P}')")
            ) > 0
        );
        assert!(
            count(
                &core,
                &format!("SELECT COUNT(*) FROM sync2_self WHERE profile_uid = srs_id('{P}')")
            ) == 1
        );
        assert!(
            count(
                &core,
                &format!("SELECT COUNT(*) FROM srs_meta WHERE key LIKE '%/{P}'")
            ) >= 2
        );
        assert!(meta_of(&core, P) >= 5);
        let q_meta = meta_of(&core, Q);

        let out = core.profile_purge(P).unwrap();
        // 删之前的规模：一条笔记已删 → 2 条笔记、2 张卡；4 条复习。
        assert_eq!(out["notes"], json!(2));
        assert_eq!(out["cards"], json!(2));
        assert_eq!(out["reviews"], json!(4));
        assert!(out["deleted"].as_i64().unwrap() >= out["rows"].as_i64().unwrap());

        let w = core.writer().unwrap();
        // 独立于被测的表清单：库里任何带 profile_uid 列的表。
        let every: Vec<String> = w
            .prepare(
                "SELECT m.name FROM sqlite_master m WHERE m.type = 'table' \
                 AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) WHERE name = 'profile_uid')",
            )
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(every.len() > 25, "{every:?}");
        for t in every {
            let n: i64 = w
                .query_row(
                    &format!("SELECT COUNT(*) FROM \"{t}\" WHERE profile_uid = srs_id(?1)"),
                    [P],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(n, 0, "{t} still has rows of the purged profile");
        }
        let schema: i64 = w
            .query_row(
                "SELECT COUNT(*) FROM srs_meta WHERE key = 'schema'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(schema, 1, "library-level meta must survive");
        // 另一个 profile 还在用的因果上下文一个都没少（GC 只回收没人引用的）。
        let dangling: i64 = w
            .query_row(
                "SELECT COUNT(*) FROM sync2_ops WHERE deps NOT IN (SELECT id FROM sync2_deps)",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(dangling, 0);
        drop(w);
        assert_eq!(meta_of(&core, P), 0);
        assert_eq!(meta_of(&core, Q), q_meta, "the other profile's keys stay");
        assert!(count(&core, "SELECT COUNT(*) FROM sync2_deps") <= deps_before);
        assert_eq!(core.profile_footprint(Q).unwrap(), q_before);
        assert_eq!(rows_of(&core, P), 0);
        // 另一个 profile 照常能写（身份、链值没被动过）。
        core.sync2_apply_local(Q, 3, &json!([{"e": {"t": "entity", "x": {"id": "D2", "p": Q, "k": "deck", "d": {"createdAt": 1}}}}]).to_string())
            .unwrap();
        // 再删一次是空操作。
        assert_eq!(core.profile_purge(P).unwrap()["deleted"], json!(0));
    }

    /// 表清单是现查的：除库级共用表外，每张 `srs_*` / `sync2_*` 表都带 `profile_uid`，所以都在删除面里。
    /// 以后加了一张不带 `profile_uid` 的表，这里会红——要么给它加列，要么明确登记成共用表。
    #[test]
    fn every_profile_table_is_purged() {
        let (core, _d) = open("tables");
        let w = core.writer().unwrap();
        let all: Vec<String> = w
            .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND (name LIKE 'srs\\_%' ESCAPE '\\' OR name LIKE 'sync2\\_%' ESCAPE '\\') ORDER BY name")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        let purged = profile_tables(&w).unwrap();
        let missing: Vec<&String> = all
            .iter()
            .filter(|t| !purged.contains(t) && !SHARED_TABLES.contains(&t.as_str()))
            .collect();
        assert!(
            missing.is_empty(),
            "tables outside the purge set: {missing:?}"
        );
        for t in [
            "srs_entities",
            "srs_review_logs",
            "srs_cards_cache",
            "srs_notes_cache",
            "srs_stat_reviews",
            "sync2_ops",
            "sync2_self",
            "sync2_media",
        ] {
            assert!(purged.iter().any(|x| x == t), "{t} not in purge set");
        }
    }

    /// 存量扫描的输入：库里出现过的全部 uid；完成标记写后读得回。
    #[test]
    fn profile_uids_lists_every_owner_and_the_sweep_marker() {
        let (core, _d) = open("uids");
        assert_eq!(
            core.profile_uids().unwrap(),
            json!({"uids": [], "orphanSweptAt": null})
        );
        // v1 / v2 的完成标记（清理面还不全时扫的）不算：残留要再扫一次（BUG-4387）。
        for old in ["profile_orphan_sweep_v1", "profile_orphan_sweep_v2"] {
            core.writer()
                .unwrap()
                .execute("INSERT INTO srs_meta (key, value) VALUES (?1, '7')", [old])
                .unwrap();
        }
        assert_eq!(core.profile_uids().unwrap()["orphanSweptAt"], Value::Null);
        seed(&core, P, 1, 1);
        seed(&core, Q, 1, 0);
        let mut want = vec![P, Q];
        want.sort();
        assert_eq!(core.profile_uids().unwrap()["uids"], json!(want));
        core.orphan_sweep_done(42, &[P.to_owned(), Q.to_owned()], true)
            .unwrap();
        assert_eq!(core.profile_uids().unwrap()["orphanSweptAt"], json!(42));
        core.profile_purge(P).unwrap();
        assert_eq!(core.profile_uids().unwrap()["uids"], json!([Q]));
        // 完成标记是库级键，删 profile 不动它。
        assert_eq!(core.profile_uids().unwrap()["orphanSweptAt"], json!(42));
    }

    /// 正在收段的会话属于被删的 profile 时随之作废（之后的批次明确失败，不会把段写回一个已删的 uid）。
    #[test]
    fn purge_drops_the_ingest_session_of_that_profile() {
        let (core, _d) = open("ingest");
        seed(&core, P, 1, 0);
        core.sync2_ingest_begin(P).unwrap();
        core.profile_purge(P).unwrap();
        let err = core.sync2_ingest_batch(P, Vec::new(), None, 9).unwrap_err();
        assert!(err.contains("no ingest session"), "{err}");
    }

    /// 另一个无主 uid。
    const R: &str = "0193a1b2-0000-7000-8000-00000000f00d";
    /// 一台别的设备的 ID：UUID 形状，不是任何 profile 的 uid。
    const DEV: &str = "0193a1b2-0000-7000-8000-0000000d0001";

    fn put_meta(core: &SrsCore, key: &str) {
        core.writer()
            .unwrap()
            .execute("INSERT INTO srs_meta (key, value) VALUES (?1, '{}')", [key])
            .unwrap();
    }

    fn has_meta(core: &SrsCore, key: &str) -> bool {
        let w = core.writer().unwrap();
        w.query_row("SELECT COUNT(*) FROM srs_meta WHERE key = ?1", [key], |r| {
            r.get::<_, i64>(0)
        })
        .unwrap()
            == 1
    }

    /// 旧版删除实现删过的 uid：表行一行不剩，按 profile 记的键留下四个（三个 uid 在中间的 + 一个并入旧实现没删的
    /// 状态摘要）。
    fn leave_meta_only(core: &SrsCore, profile: &str) {
        seed(core, profile, 1, 1);
        core.profile_purge(profile).unwrap();
        for key in [
            format!("sync2_device_ext/{profile}/{DEV}"),
            format!("sync2_retired/{profile}/{DEV}"),
            format!("sync2_head_sig/{profile}/local:/srv/sync"),
            format!("sync2_digest/{profile}"),
        ] {
            put_meta(core, &key);
        }
        assert_eq!(rows_of(core, profile), 0);
        assert_eq!(meta_of(core, profile), 4);
    }

    fn sweep_marker(core: &SrsCore) -> Value {
        core.profile_uids().unwrap()["orphanSweptAt"].clone()
    }

    /// 键里 profile 的位置只按登记过的写法取：设备 ID、位置 ID 里的 UUID、并入标记、非规范 UUID 都不是 profile。
    #[test]
    fn meta_profile_of_reads_only_registered_positions() {
        for key in [
            format!("sync2_self_info/{P}"),
            format!("sync2_fork_at/{P}"),
            format!("sync2_digest/{P}"),
            format!("sync2_digest_at/{P}"),
            format!("sync2_migrating/{P}"),
            format!("sync2_sealed/local:/a/b/{P}"),
            format!("sync2_sealed/folder:{DEV}/x/{P}"),
            format!("sync2_device_ext/{P}/{DEV}"),
            format!("sync2_retired/{P}/{DEV}"),
            format!("sync2_head_sig/{P}/local:/x/{DEV}/y"),
        ] {
            assert_eq!(meta_profile_of(&key), Some(P), "{key}");
        }
        for key in [
            format!("sync2_device_hint/{DEV}"),
            format!("profile_merge/{P}"),
            format!("sync2_digest/{}", P.to_uppercase()),
            "sync2_digest/not-a-uuid".to_owned(),
            format!("sync2_device_ext/{P}"),
            format!("unknown_prefix/{P}"),
            "schema".to_owned(),
            ORPHAN_SWEEP_KEY.to_owned(),
        ] {
            assert_eq!(meta_profile_of(&key), None, "{key}");
        }
    }

    /// 内核里每个往 `srs_meta` 写按 profile 记的键的地方，前缀都登记在 [META_PROFILE_LAST] / [META_PROFILE_FIRST]
    /// 里（[meta_only_uids] 只认登记过的）。键都是 `format!("<前缀>/…{profile}…")` 拼的：扫 `src/store` 下的源码，
    /// 字符串字面量里出现 `/{profile}` 的，开头那段前缀必须登记过。新加一种按 profile 记的键而没登记，这里红。
    #[test]
    fn every_profile_meta_key_prefix_is_classified() {
        // 不是 `srs_meta` 键的 `…/{profile}` 字面量：集合 ID 的派生名（sync2/mod.rs `collection_of`）。
        const NOT_META: [&str; 1] = ["sync2/"];
        fn walk(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
            for e in std::fs::read_dir(dir).unwrap() {
                let path = e.unwrap().path();
                if path.is_dir() {
                    walk(&path, out);
                } else if path.extension().is_some_and(|x| x == "rs") {
                    out.push(path);
                }
            }
        }
        let mut files = Vec::new();
        walk(
            &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/store"),
            &mut files,
        );
        assert!(files.len() > 20, "{}", files.len());
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let needle = concat!("/{", "profile}");
        for f in files {
            let src = std::fs::read_to_string(&f).unwrap();
            for (at, _) in src.match_indices(needle) {
                // 注释里举的例子不是代码。
                let line = src[..at].rfind('\n').map_or(0, |n| n + 1);
                if src[line..at].trim_start().starts_with("//") {
                    continue;
                }
                // 字面量开头：往回找最近的引号；前缀 = 引号后到第一个 `/`（含）。
                let start = src[..at].rfind('"').map_or(0, |q| q + 1);
                let literal = &src[start..at + 1];
                let prefix = &literal[..literal.find('/').unwrap() + 1];
                seen.insert(prefix.to_owned());
                assert!(
                    META_PROFILE_LAST.contains(&prefix)
                        || META_PROFILE_FIRST.contains(&prefix)
                        || META_NOT_PROFILE.contains(&prefix)
                        || NOT_META.contains(&prefix),
                    "{}: per-profile key prefix {prefix:?} is not classified in profile_data.rs",
                    f.display()
                );
            }
            // `{MIGRATING_KEY}{profile}` 这种经常量拼的：常量只能是登记过的那一个。
            for (at, _) in src.match_indices(concat!("}{", "profile}")) {
                let open = src[..at].rfind('{').unwrap();
                assert_eq!(&src[open + 1..at], "MIGRATING_KEY", "{}", f.display());
            }
        }
        // 扫描确实扫到了东西（键的拼法整体换掉时，这条测试不能悄悄变成空转）。
        for p in META_PROFILE_FIRST {
            assert!(seen.contains(p), "{p} is registered but no longer written");
        }
        for p in [
            "sync2_self_info/",
            "sync2_fork_at/",
            "sync2_digest/",
            "sync2_digest_at/",
            "sync2_sealed/",
        ] {
            assert!(seen.contains(p), "{p} is registered but no longer written");
        }
        let mod_rs = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/store/sync2/mod.rs"),
        )
        .unwrap();
        assert!(mod_rs.contains("const MIGRATING_KEY: &str = \"sync2_migrating/\";"));
        assert!(META_PROFILE_LAST.contains(&"sync2_migrating/"));
    }

    /// 收尾清两类残留：只剩 meta 键的无主 uid 的键、没有任何操作引用的 `sync2_deps`。活 profile 名下带设备 ID 的键、
    /// 不分 profile 的设备键、被引用的因果上下文一个不动；再调一次什么都不变。
    #[test]
    fn sweep_rest_clears_meta_only_uids_and_orphan_deps() {
        let (core, _d) = open("sweep_rest");
        seed(&core, P, 2, 3);
        put_meta(&core, &format!("sync2_device_ext/{P}/{DEV}"));
        put_meta(&core, &format!("sync2_retired/{P}/{DEV}"));
        put_meta(&core, &format!("sync2_device_hint/{DEV}"));
        leave_meta_only(&core, Q);
        core.writer()
            .unwrap()
            .execute("INSERT INTO sync2_deps (vv) VALUES (x'DEADBEEF')", [])
            .unwrap();
        let p_before = core.profile_footprint(P).unwrap();
        let p_meta = meta_of(&core, P);
        let deps_before = count(&core, "SELECT COUNT(*) FROM sync2_deps");
        assert!(deps_before >= 2, "{deps_before}");
        // 表行并集里已经没有 Q：原扫描看不到它。
        assert_eq!(core.profile_uids().unwrap()["uids"], json!([P]));

        let out = core.orphan_sweep_done(9, &[P.to_owned()], true).unwrap();
        assert_eq!(out, json!({"metaUids": [Q], "meta": 4, "deps": 1}));

        assert_eq!(meta_of(&core, Q), 0);
        assert_eq!(meta_of(&core, P), p_meta, "the live profile's keys stay");
        assert!(has_meta(&core, &format!("sync2_device_ext/{P}/{DEV}")));
        assert!(has_meta(&core, &format!("sync2_retired/{P}/{DEV}")));
        assert!(has_meta(&core, &format!("sync2_device_hint/{DEV}")));
        assert_eq!(core.profile_footprint(P).unwrap(), p_before);
        assert_eq!(
            count(&core, "SELECT COUNT(*) FROM sync2_deps"),
            deps_before - 1
        );
        assert_eq!(
            count(
                &core,
                "SELECT COUNT(*) FROM sync2_ops WHERE deps NOT IN (SELECT id FROM sync2_deps)"
            ),
            0,
            "every op still has its causal context"
        );
        assert_eq!(sweep_marker(&core), json!(9));
        // 活 profile 照常能写（它的因果上下文还在、之后要用的重新插）。
        core.sync2_apply_local(P, 3, &json!([{"e": {"t": "entity", "x": {"id": "D2", "p": P, "k": "deck", "d": {"createdAt": 1}}}}]).to_string())
            .unwrap();

        // 幂等：再调一次没有可清的，库不变。
        let again = core.orphan_sweep_done(10, &[P.to_owned()], true).unwrap();
        assert_eq!(again, json!({"metaUids": [], "meta": 0, "deps": 0}));
        assert_eq!(meta_of(&core, P), p_meta);
        assert_eq!(sweep_marker(&core), json!(10));
    }

    /// 不许动的：`keep` 里的 uid（主库现存的 / 进行中并入涉及的）哪怕只剩 meta 键；表里还有行的 uid 哪怕不在 `keep`
    /// 里（那是 Dart 先备份再经 `profile_purge` 清的）。`mark` 为 false 时不写完成标记。
    #[test]
    fn sweep_rest_keeps_kept_uids_and_uids_that_still_have_rows() {
        let (core, _d) = open("sweep_keep");
        seed(&core, P, 1, 1);
        leave_meta_only(&core, Q);
        seed(&core, R, 1, 1);
        let r_rows = rows_of(&core, R);
        let r_meta = meta_of(&core, R);
        assert!(r_rows > 0 && r_meta > 0);

        // Q 是进行中并入的目标（Dart 把它放进 keep）：不动；R 不在 keep 里但表里有行：这条命令不碰。
        let out = core
            .orphan_sweep_done(5, &[P.to_owned(), Q.to_owned()], false)
            .unwrap();
        assert_eq!(out["metaUids"], json!([]));
        assert_eq!(out["meta"], json!(0));
        assert_eq!(meta_of(&core, Q), 4);
        assert_eq!(rows_of(&core, R), r_rows);
        assert_eq!(meta_of(&core, R), r_meta);
        assert_eq!(sweep_marker(&core), Value::Null, "mark = false");

        // 并入做完之后（Q 不再受保护）下一次扫描清掉它；R 仍然不归这条命令管。
        let out = core.orphan_sweep_done(6, &[P.to_owned()], true).unwrap();
        assert_eq!(out["metaUids"], json!([Q]));
        assert_eq!(meta_of(&core, Q), 0);
        assert_eq!(rows_of(&core, R), r_rows);
        assert_eq!(meta_of(&core, R), r_meta);
        assert_eq!(sweep_marker(&core), json!(6));
    }

    /// 「表里没有行」在删除的同一个 savepoint 里判：一个 uid 的键算进了候选之后才有了行（并入刚为目标 uid 开了
    /// 副本），它就不是只剩 meta 键的 uid，键不动。
    #[test]
    fn sweep_rest_leaves_a_uid_that_gained_rows() {
        let (core, _d) = open("sweep_rows");
        seed(&core, P, 1, 0);
        leave_meta_only(&core, Q);
        // 目标 uid 的副本打开：有了同步身份行。
        core.sync2_identity(Q, 1).unwrap();
        assert!(rows_of(&core, Q) > 0);
        let q_meta = meta_of(&core, Q);

        let out = core.orphan_sweep_done(7, &[P.to_owned()], true).unwrap();
        assert_eq!(out["metaUids"], json!([]));
        assert_eq!(meta_of(&core, Q), q_meta);
    }
}
