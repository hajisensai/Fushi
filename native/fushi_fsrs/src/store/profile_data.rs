//! 一个 profile 在 `srs.db` 里的全部本机数据：统计、整体删除、找无主数据（反馈 8TaOy2i-lL 现象 3）。
//!
//! `srs.db` 是所有 profile 共用的一个文件，每张按 profile 分的表都有 `profile_uid` 列。删 profile 以前只删主库
//! `profiles` 行，这里的行全部留下成了无主副本。这里给 Dart 三条粗粒度命令（经 `ffsrs_store_sync2` 分派）：
//!
//! - [SrsCore::profile_footprint]：确认框要显示的笔记 / 卡 / 复习记录数（读连接上一次读完）；
//! - [SrsCore::profile_purge]：一个事务里删掉该 uid 在**每一张**带 `profile_uid` 列的 `srs_*` / `sync2_*` 表里的
//!   行、`srs_meta` 里以 `/<uid>` 结尾的按 profile 记的键，再回收没人引用的 `sync2_deps`；
//! - [SrsCore::profile_uids]：库里出现过的全部 uid（Dart 与主库现存 profile 比对得出无主 uid）+ 一次性存量扫描的
//!   完成标记（[SrsCore::orphan_sweep_done] 写）。
//!
//! 表清单按 `sqlite_master` + `pragma_table_info` 现查，不手抄：以后加的按 profile 分的表自动落进删除面
//! （回归测试 `every_profile_table_is_purged` 钉住「除 `srs_meta` / `sync2_deps` 外每张表都有 `profile_uid`」）。
//! 只动本机：远端存储位置上已同步的集合一个字节也不碰（`sync2_locations` 只是本机记的上传进度）。

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Map, Value};

use super::sync2::{in_savepoint, sql};
use super::SrsCore;
use std::sync::atomic::Ordering;

/// `srs_meta` 里一次性存量无主数据扫描的完成标记（值 = 完成时刻毫秒）。
pub(crate) const ORPHAN_SWEEP_KEY: &str = "profile_orphan_sweep_v1";

/// 带 `profile_uid` 列的 `srs_*` / `sync2_*` 表（按名字排序）。
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
    let names = stmt.query_map([], |r| r.get::<_, String>(0)).map_err(sql)?.collect::<Result<Vec<_>, _>>().map_err(sql)?;
    Ok(names)
}

/// 用户看得见的规模：未删除的笔记、它们的卡、全部复习记录；外加该 uid 在各表里的总行数。
fn footprint(c: &Connection, profile: &str) -> Result<Value, String> {
    let count = |q: &str| -> Result<i64, String> { c.query_row(q, [profile], |r| r.get(0)).map_err(sql) };
    let notes = count("SELECT COUNT(*) FROM srs_notes_cache WHERE profile_uid = ?1 AND deleted_at IS NULL")?;
    let cards = count(
        "SELECT COUNT(*) FROM srs_cards_cache c WHERE c.profile_uid = ?1 AND EXISTS \
         (SELECT 1 FROM srs_notes_cache n WHERE n.id = c.note_id AND n.deleted_at IS NULL)",
    )?;
    let reviews = count("SELECT COUNT(*) FROM srs_review_logs WHERE profile_uid = ?1")?;
    let mut rows = 0i64;
    for t in profile_tables(c)? {
        rows += count(&format!("SELECT COUNT(*) FROM \"{t}\" WHERE profile_uid = ?1"))?;
    }
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
        if self.legacy_open.load(Ordering::SeqCst) {
            return Err("legacy import in progress".into());
        }
        let w = self.writer()?;
        let out = in_savepoint(&w, |c| {
            let mut out = footprint(c, profile)?;
            let mut tables = Map::new();
            let mut deleted = 0i64;
            for t in profile_tables(c)? {
                let n = c.execute(&format!("DELETE FROM \"{t}\" WHERE profile_uid = ?1"), [profile]).map_err(sql)? as i64;
                if n > 0 {
                    tables.insert(t, json!(n));
                }
                deleted += n;
            }
            // 按 profile 记的元数据键一律是 `<前缀>/<uid>`（迁移进度、状态摘要…）；uid 是 UUID，不会误伤别的键。
            let meta = c
                .execute("DELETE FROM srs_meta WHERE substr(key, -length(?1) - 1) = '/' || ?1", [profile])
                .map_err(sql)? as i64;
            if meta > 0 {
                tables.insert("srs_meta".into(), json!(meta));
            }
            // 迁移队列是按需建的表（没迁移过的库里没有它），表清单查询已经把它算进去了；因果上下文跨 profile 共用，
            // 只回收已经没有任何操作引用的。
            let deps = c
                .execute("DELETE FROM sync2_deps WHERE id NOT IN (SELECT deps FROM sync2_ops)", [])
                .map_err(sql)? as i64;
            if deps > 0 {
                tables.insert("sync2_deps".into(), json!(deps));
            }
            out["deleted"] = json!(deleted + meta + deps);
            out["tables"] = Value::Object(tables);
            Ok(out)
        })?;
        let mut session = self.ingest_session.lock().map_err(|_| "ingest session poisoned")?;
        if session.as_ref().is_some_and(|s| s.belongs_to(profile)) {
            *session = None;
        }
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
                let union = tables.iter().map(|t| format!("SELECT profile_uid FROM \"{t}\"")).collect::<Vec<_>>().join(" UNION ");
                let mut stmt = r.prepare(&format!("SELECT profile_uid FROM ({union}) ORDER BY profile_uid")).map_err(sql)?;
                uids = stmt.query_map([], |x| x.get::<_, String>(0)).map_err(sql)?.collect::<Result<_, _>>().map_err(sql)?;
            }
            let swept: Option<i64> = r
                .query_row("SELECT value FROM srs_meta WHERE key = ?1", [ORPHAN_SWEEP_KEY], |x| x.get::<_, String>(0))
                .optional()
                .map_err(sql)?
                .and_then(|v| v.parse().ok());
            Ok::<_, String>(json!({"uids": uids, "orphanSweptAt": swept}))
        })();
        r.execute_batch("COMMIT").map_err(sql)?;
        out
    }

    /// 记下一次性存量扫描已完成（[ORPHAN_SWEEP_KEY]）。
    pub fn orphan_sweep_done(&self, now: i64) -> Result<Value, String> {
        let w = self.writer()?;
        w.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![ORPHAN_SWEEP_KEY, now.to_string()],
        )
        .map_err(sql)?;
        Ok(json!({}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::sync2::tests::{deck_entity, review, tempdir, P};
    use serde_json::json;

    const Q: &str = "0193a1b2-0000-7000-8000-00000000cafe";

    /// 不按 profile 分、删除时不按 uid 删的表：库级元数据（按 profile 的键单独按后缀删）、跨 profile 去重存的
    /// 因果上下文（按引用回收）。
    const SHARED_TABLES: [&str; 2] = ["srs_meta", "sync2_deps"];

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
            events.push(review(&format!("L-{profile}-{i}"), &format!("C-{profile}-0"), 1_700_000_000_000 + i as i64, 3, "learn"));
        }
        let events: Vec<Value> = events
            .into_iter()
            .map(|mut e| {
                e["x"]["p"] = json!(profile);
                json!({"e": e, "note": format!("N-{profile}-0")})
            })
            .collect();
        core.sync2_identity(profile, 1).unwrap();
        core.sync2_apply_local(profile, 2, &Value::Array(events).to_string()).unwrap();
        core.sync2_digest(profile).unwrap();
        let w = core.writer().unwrap();
        for i in 0..notes {
            let deleted: Option<i64> = if i == 0 && notes > 1 { Some(5) } else { None };
            w.execute(
                "INSERT INTO srs_notes_cache (id, profile_uid, note_type_id, guid, created_at, deleted_at) VALUES (?1, ?2, 'NT', ?1, 1, ?3)",
                params![format!("N-{profile}-{i}"), profile, deleted],
            )
            .unwrap();
            w.execute(
                "INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id) VALUES (?1, ?2, ?3, 'T', 'D')",
                params![format!("C-{profile}-{i}"), profile, format!("N-{profile}-{i}")],
            )
            .unwrap();
        }
        w.execute("INSERT INTO srs_local_state (profile_uid, json) VALUES (?1, '{}')", [profile]).unwrap();
        w.execute_batch(
            "CREATE TABLE IF NOT EXISTS sync2_migrate_queue (profile_uid TEXT NOT NULL, pos INTEGER NOT NULL, \
             phase INTEGER NOT NULL, src TEXT NOT NULL, PRIMARY KEY (profile_uid, pos)) WITHOUT ROWID;",
        )
        .unwrap();
        w.execute("INSERT INTO sync2_migrate_queue (profile_uid, pos, phase, src) VALUES (?1, 1, 0, 'x')", [profile]).unwrap();
        w.execute("INSERT INTO srs_meta (key, value) VALUES ('sync2_migrating/' || ?1, '1')", [profile]).unwrap();
    }

    fn rows_of(core: &SrsCore, profile: &str) -> i64 {
        core.profile_footprint(profile).unwrap()["rows"].as_i64().unwrap()
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
        assert!(count(&core, &format!("SELECT COUNT(*) FROM sync2_ops WHERE profile_uid = '{P}'")) > 0);
        assert!(count(&core, &format!("SELECT COUNT(*) FROM sync2_self WHERE profile_uid = '{P}'")) == 1);
        assert!(count(&core, &format!("SELECT COUNT(*) FROM srs_meta WHERE key LIKE '%/{P}'")) >= 2);

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
            let n: i64 = w.query_row(&format!("SELECT COUNT(*) FROM \"{t}\" WHERE profile_uid = ?1"), [P], |r| r.get(0)).unwrap();
            assert_eq!(n, 0, "{t} still has rows of the purged profile");
        }
        let meta: i64 = w.query_row("SELECT COUNT(*) FROM srs_meta WHERE key LIKE '%/' || ?1", [P], |r| r.get(0)).unwrap();
        assert_eq!(meta, 0);
        let schema: i64 = w.query_row("SELECT COUNT(*) FROM srs_meta WHERE key = 'schema'", [], |r| r.get(0)).unwrap();
        assert_eq!(schema, 1, "library-level meta must survive");
        // 另一个 profile 还在用的因果上下文一个都没少（GC 只回收没人引用的）。
        let dangling: i64 = w
            .query_row("SELECT COUNT(*) FROM sync2_ops WHERE deps NOT IN (SELECT id FROM sync2_deps)", [], |r| r.get(0))
            .unwrap();
        assert_eq!(dangling, 0);
        drop(w);
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
        let missing: Vec<&String> = all.iter().filter(|t| !purged.contains(t) && !SHARED_TABLES.contains(&t.as_str())).collect();
        assert!(missing.is_empty(), "tables outside the purge set: {missing:?}");
        for t in ["srs_entities", "srs_review_logs", "srs_cards_cache", "srs_notes_cache", "srs_stat_reviews", "sync2_ops", "sync2_self", "sync2_media"] {
            assert!(purged.iter().any(|x| x == t), "{t} not in purge set");
        }
    }

    /// 存量扫描的输入：库里出现过的全部 uid；完成标记写后读得回。
    #[test]
    fn profile_uids_lists_every_owner_and_the_sweep_marker() {
        let (core, _d) = open("uids");
        assert_eq!(core.profile_uids().unwrap(), json!({"uids": [], "orphanSweptAt": null}));
        seed(&core, P, 1, 1);
        seed(&core, Q, 1, 0);
        let mut want = vec![P, Q];
        want.sort();
        assert_eq!(core.profile_uids().unwrap()["uids"], json!(want));
        core.orphan_sweep_done(42).unwrap();
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
}
