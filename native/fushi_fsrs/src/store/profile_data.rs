//! 一个 profile 在 `srs.db` 里的全部本机数据：统计、整体删除、找无主数据（反馈 8TaOy2i-lL 现象 3）。
//!
//! `srs.db` 是所有 profile 共用的一个文件，每张按 profile 分的表都有 `profile_uid` 列。删 profile 以前只删主库
//! `profiles` 行，这里的行全部留下成了无主副本。这里给 Dart 三条粗粒度命令（经 `ffsrs_store_sync2` 分派）：
//!
//! - [SrsCore::profile_footprint]：确认框要显示的笔记 / 卡 / 复习记录数（读连接上一次读完）；
//! - [SrsCore::profile_purge]：一个事务里删掉该 uid 在**每一张**带 `profile_uid` 列的 `srs_*` / `sync2_*` 表里的
//!   行、`srs_meta` 里按 profile 记的键（`…/<uid>` 与 `…/<uid>/…`），再回收没人引用的 `sync2_deps`。删本机一个
//!   uid 的唯一实现：删 profile、并入（srs_profile_merge.dart）、采用别的 uid（srs_backup_merge.dart）都经它；
//! - [SrsCore::profile_merge_mark] / [SrsCore::profile_merge_commit]：并入（srs_profile_merge.dart）在 srs.db 里的两步写——
//!   记「并入进行中」的标记、收尾的「核对 + 删旧 uid」（一笔）；[SrsCore::meta_set_edit]：profile 链接记的两个字符串
//!   集合的原子增删。它们取代了 Dart 经 Drift 的直写与那笔 Drift 事务（收掉 Dart 写路径第 11 步）；
//! - [SrsCore::profile_uids]：库里出现过的全部 uid（Dart 与主库现存 profile 比对得出无主 uid）+ 一次性存量扫描的
//!   完成标记（[SrsCore::orphan_sweep_done] 写）。
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
pub(crate) const ORPHAN_SWEEP_KEY: &str = "profile_orphan_sweep_v1";

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
    let mut rows = 0i64;
    for t in profile_tables(c)? {
        rows += count(&format!(
            "SELECT COUNT(*) FROM \"{t}\" WHERE profile_uid = srs_id(?1)"
        ))?;
    }
    Ok(json!({"notes": notes, "cards": cards, "reviews": reviews, "rows": rows}))
}

/// 并入标记的键前缀（Dart `kSrsProfileMergeMarkerPrefix`）：`profile_merge/<旧 uid>` → `{"profileId":..,"newUid":..}`。
const MERGE_MARKER_PREFIX: &str = "profile_merge/";

/// [SrsCore::meta_set_edit] 认得的集合 → `srs_meta` 的键（Dart `kSrsRetiredV2DevicesKey` / `kSrsRetiredProfileUidsKey`）。
fn meta_set_key(set: &str) -> Result<&'static str, String> {
    match set {
        "retiredDevices" => Ok("srs_retired_v2_devices"),
        "retiredUids" => Ok("srs_retired_profile_uids"),
        other => Err(format!("meta_set_edit: unknown set {other}")),
    }
}

/// `srs_meta` 里 [key] 存的字符串集合（JSON 数组；没有 / 坏了 / 不是数组 = 空）。保留数组里的顺序、去重；非字符串
/// 元素不认（这两个集合只有本模块写，写的都是字符串）。
fn read_meta_set(c: &Connection, key: &str) -> Result<Vec<String>, String> {
    let raw: Option<String> = c
        .query_row("SELECT value FROM srs_meta WHERE key = ?1", [key], |r| {
            r.get(0)
        })
        .optional()
        .map_err(sql)?;
    let mut out: Vec<String> = Vec::new();
    if let Some(Ok(Value::Array(items))) = raw.map(|r| serde_json::from_str::<Value>(&r)) {
        for x in items {
            if let Value::String(s) = x {
                if !out.contains(&s) {
                    out.push(s);
                }
            }
        }
    }
    Ok(out)
}

/// [profile] 名下投影里的全部事件 ID（并入的收尾核对用；Dart 旧 `_eventIds`）。
fn event_ids(c: &Connection, profile: &str) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for table in [
        "srs_entities",
        "srs_field_edits",
        "srs_review_logs",
        "srs_unknown_events",
    ] {
        let mut stmt = c
            .prepare_cached(&format!(
                "SELECT srs_idt(id) FROM {table} WHERE profile_uid = srs_id(?1)"
            ))
            .map_err(sql)?;
        let mut rows = stmt.query([profile]).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            out.push(r.get::<_, String>(0).map_err(sql)?);
        }
    }
    Ok(out)
}

/// [ids] 里有几个不在 [profile] 名下：在投影表或操作索引的**任意一张**里出现就算在（含被支配而不在投影里的修改
/// 记录、被清除内容的日志；Dart `_presentIn` 的口径）。
fn missing_under(c: &Connection, profile: &str, ids: &[&str]) -> Result<usize, String> {
    let mut found: std::collections::HashSet<String> = std::collections::HashSet::new();
    for chunk in ids.chunks(500) {
        let marks = vec!["srs_id(?)"; chunk.len()].join(",");
        for (table, col) in [
            ("srs_entities", "id"),
            ("srs_field_edits", "id"),
            ("sync2_edit_ops", "edit_id"),
            ("srs_review_logs", "id"),
            ("sync2_log_meta", "log_id"),
            ("srs_unknown_events", "id"),
        ] {
            let mut stmt = c
                .prepare_cached(&format!(
                    "SELECT srs_idt({col}) FROM {table} WHERE profile_uid = srs_id(?) AND {col} IN ({marks})"
                ))
                .map_err(sql)?;
            let args = std::iter::once(profile).chain(chunk.iter().copied());
            let mut rows = stmt.query(rusqlite::params_from_iter(args)).map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                found.insert(r.get::<_, String>(0).map_err(sql)?);
            }
        }
    }
    Ok(ids.iter().filter(|id| !found.contains(**id)).count())
}

/// 删掉 [profile] 的全部本机数据（[SrsCore::profile_purge] 的本体）：在调用方的写连接、调用方开的 SAVEPOINT 里做。
fn purge_on(c: &Connection, profile: &str) -> Result<Value, String> {
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
    // 按 profile 记的元数据键是 `<前缀>/<uid>`（迁移进度、状态摘要、并入标记…）或 `<前缀>/<uid>/<下级>`
    // （别的设备的扩展 / 停用标记、各位置的 head 签名，sync2/devices.rs、transport.rs）；uid 是 UUID，
    // 不会误伤别的键。
    let meta = c
        .execute(
            "DELETE FROM srs_meta WHERE substr(key, -length(?1) - 1) = '/' || ?1 \
             OR instr(key, '/' || ?1 || '/') > 0",
            [profile],
        )
        .map_err(sql)? as i64;
    if meta > 0 {
        tables.insert("srs_meta".into(), json!(meta));
    }
    // 迁移队列是按需建的表（没迁移过的库里没有它），表清单查询已经把它算进去了；因果上下文跨 profile 共用，
    // 只回收已经没有任何操作引用的。
    let deps = c
        .execute(
            "DELETE FROM sync2_deps WHERE id NOT IN (SELECT deps FROM sync2_ops)",
            [],
        )
        .map_err(sql)? as i64;
    if deps > 0 {
        tables.insert("sync2_deps".into(), json!(deps));
    }
    out["deleted"] = json!(deleted + meta + deps);
    out["tables"] = Value::Object(tables);
    Ok(out)
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
        let w = self.profile_writer()?;
        let out = in_savepoint(&w, |c| purge_on(c, profile))?;
        // 正在收这个 profile 的会话（或它的收尾）一起放掉，连同留着的页缓存。
        self.sync2_ingest_end(profile)?;
        Ok(out)
    }

    /// 写锁 + 旧库搬迁事务没开着（搬迁会整表重写）。
    fn profile_writer(&self) -> Result<super::Conn<'_>, String> {
        // 先取写锁再看 `legacy_open`（同 [SrsCore::exec]）。
        let w = self.writer()?;
        if self.legacy_open.load(Ordering::SeqCst) {
            return Err("legacy import in progress".into());
        }
        Ok(w)
    }

    /// `profile_merge_mark`：记下「旧 uid [from]（主库 profile [profile_id]）正在并入 [to]」（并入的第一步，
    /// srs_profile_merge.dart）。之后任何一步中断，标记还在，下次从 `srs_meta` 读到它续做；并入提交
    /// （[Self::profile_merge_commit]）时随 [from] 的元数据键一起删掉。值的形态与 Dart 旧版 `jsonEncode` 写下的逐字节
    /// 相同（`profileId` 在前）。
    pub fn profile_merge_mark(
        &self,
        from: &str,
        profile_id: i64,
        to: &str,
    ) -> Result<Value, String> {
        if from.is_empty() || to.is_empty() || from == to {
            return Err("profile_merge_mark: bad from / to".into());
        }
        let value = format!(
            "{{\"profileId\":{profile_id},\"newUid\":{}}}",
            serde_json::to_string(to).map_err(|e| e.to_string())?
        );
        let w = self.profile_writer()?;
        in_savepoint(&w, |c| {
            c.execute(
                "INSERT OR REPLACE INTO srs_meta (key, value) VALUES (?1, ?2)",
                params![format!("{MERGE_MARKER_PREFIX}{from}"), value],
            )
            .map_err(sql)?;
            Ok(json!({}))
        })
    }

    /// `profile_merge_commit`：并入的收尾——核对 + 删旧 uid，**一次持写锁、一个 SAVEPOINT**。[map]（JSON 对象）是
    /// 调用方这一轮计划的「旧事件 ID → 新事件 ID」。
    ///
    /// - 旧 uid [from] 此刻投影里的事件有一条不在 [map] 的键里（计划之后它又被写了）→ `{"done": false}`，什么都不写，
    ///   调用方重新计划再来；
    /// - 这些事件映射过去的新 ID 有 N 条不在新 uid [to] 名下 → `{"done": false, "missing": N}`，什么都不写（调用方
    ///   报错、旧行留着）；
    /// - 否则删掉 [from] 的全部数据（[purge_on]：含并入标记），回包 `{"done": true, ...规模}`。
    ///
    /// 以前这是 Dart 的一笔 Drift 事务（两批读 + `profile_purge`），不在任何副本的独占区里：别的副本此时发的写命令
    /// 会落进那笔事务。现在核对与删除之间只有内核的写锁，没有别的写入。[from] 的收段通道没做完就先做完（通道里还没
    /// 投影的操作进了投影才看得见；多出来的事件不在 [map] 里 → 再来一轮）。Drift 在写连接上开着事务时拒绝：不把这次
    /// 删除嵌进别人的事务、跟着它回滚。[fail_after]（测试注入）= `"check"`：核对通过之后报错，验证整笔回滚。
    pub fn profile_merge_commit(
        &self,
        from: &str,
        to: &str,
        map: &[u8],
        fail_after: Option<&str>,
    ) -> Result<Value, String> {
        if from.is_empty() || to.is_empty() || from == to {
            return Err("profile_merge_commit: bad from / to".into());
        }
        let map: std::collections::HashMap<String, String> = serde_json::from_slice(map)
            .map_err(|e| format!("profile_merge_commit: bad map: {e}"))?;
        let w = self.profile_writer()?;
        if self.drift_tx.load(Ordering::SeqCst) {
            return Err(
                "profile_merge_commit: a Drift transaction is open on the write connection".into(),
            );
        }
        self.settle_channel_on(&w, from)?;
        let out = in_savepoint(&w, |c| {
            let now_old = event_ids(c, from)?;
            let mut want: Vec<&str> = Vec::with_capacity(now_old.len());
            for id in &now_old {
                match map.get(id) {
                    Some(new_id) => want.push(new_id.as_str()),
                    None => return Ok(json!({"done": false})),
                }
            }
            want.sort_unstable();
            want.dedup();
            let missing = missing_under(c, to, &want)?;
            if missing > 0 {
                return Ok(json!({"done": false, "missing": missing}));
            }
            if fail_after == Some("check") {
                return Err("profile_merge_commit: injected failure after check".into());
            }
            let mut out = purge_on(c, from)?;
            out["done"] = json!(true);
            Ok(out)
        })?;
        if out["done"] == json!(true) {
            // 正在收旧 uid 的会话（或它的收尾）一起放掉，同 [Self::profile_purge]。
            self.sync2_ingest_end(from)?;
        }
        Ok(out)
    }

    /// `meta_set_edit`：`srs_meta` 里一个字符串集合的原子增删（[set] 见 [meta_set_key]；profile 链接记「本设备退役的
    /// v2 设备身份 / 离开的旧 uid」，srs_profile_link.dart）。读、改、写在一次持写锁、一个 SAVEPOINT 里——以前是 Dart
    /// 的「Drift 读一条 → 改 → Drift 写一条」，两个并发的增删互相覆盖。[add] / [remove] 都不给 = 只读（不取写锁）。
    /// 已有元素的顺序不动，新值追加；没变化不写。回包 `{"values": [...]}`。
    pub fn meta_set_edit(
        &self,
        set: &str,
        add: Option<&str>,
        remove: Option<&str>,
    ) -> Result<Value, String> {
        let key = meta_set_key(set)?;
        if add.is_none() && remove.is_none() {
            return self.read_visible(|c| Ok(json!({"values": read_meta_set(c, key)?})));
        }
        let w = self.profile_writer()?;
        in_savepoint(&w, |c| {
            let before = read_meta_set(c, key)?;
            let mut values = before.clone();
            if let Some(v) = remove {
                values.retain(|x| x != v);
            }
            if let Some(v) = add {
                if !values.iter().any(|x| x == v) {
                    values.push(v.to_owned());
                }
            }
            if values != before {
                c.execute(
                    "INSERT OR REPLACE INTO srs_meta (key, value) VALUES (?1, ?2)",
                    params![key, json!(values).to_string()],
                )
                .map_err(sql)?;
            }
            Ok(json!({"values": values}))
        })
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
    use crate::store::sync2::tests::{P, deck_entity, review, tempdir};
    use serde_json::json;

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

    // ---- 并入的标记 / 收尾、链接记的集合（收掉 Dart 写路径第 11 步）

    fn meta(core: &SrsCore, key: &str) -> Option<String> {
        let w = core.writer().unwrap();
        w.query_row("SELECT value FROM srs_meta WHERE key = ?1", [key], |r| {
            r.get(0)
        })
        .optional()
        .unwrap()
    }

    /// `seed(P, _, logs)` 与 `seed(Q, _, logs)` 落下的事件之间的「旧 ID → 新 ID」。
    fn seeded_map(logs: usize) -> Map<String, Value> {
        let mut map = Map::new();
        map.insert(format!("D-{P}"), json!(format!("D-{Q}")));
        for i in 0..logs {
            map.insert(format!("L-{P}-{i}"), json!(format!("L-{Q}-{i}")));
        }
        map
    }

    fn commit(
        core: &SrsCore,
        map: &Map<String, Value>,
        fail: Option<&str>,
    ) -> Result<Value, String> {
        core.profile_merge_commit(
            P,
            Q,
            Value::Object(map.clone()).to_string().as_bytes(),
            fail,
        )
    }

    /// 标记的值与 Dart 旧版 `jsonEncode({'profileId': .., 'newUid': ..})` 逐字节相同（旧版本读同一个键续做）。
    #[test]
    fn merge_mark_writes_the_marker_byte_for_byte() {
        let (core, _d) = open("mark");
        assert_eq!(core.profile_merge_mark(P, 7, Q).unwrap(), json!({}));
        assert_eq!(
            meta(&core, &format!("profile_merge/{P}")).unwrap(),
            format!("{{\"profileId\":7,\"newUid\":\"{Q}\"}}")
        );
        // 再记一次是覆盖（换了 profile 行号的续做）。
        core.profile_merge_mark(P, 9, Q).unwrap();
        assert_eq!(
            meta(&core, &format!("profile_merge/{P}")).unwrap(),
            format!("{{\"profileId\":9,\"newUid\":\"{Q}\"}}")
        );
        for (from, to) in [("", Q), (P, ""), (P, P)] {
            assert!(core.profile_merge_mark(from, 1, to).is_err());
        }
    }

    /// 旧 uid 的每条事件都在计划里、映射过去的都在新 uid 下 → 一笔删掉旧 uid（含并入标记），新 uid 原样。映射里
    /// 多出来的键（旧 uid 已经没有的事件）不算缺。
    #[test]
    fn merge_commit_deletes_the_old_uid_once_everything_landed() {
        let (core, _d) = open("commit");
        seed(&core, P, 3, 4);
        seed(&core, Q, 2, 4);
        core.profile_merge_mark(P, 7, Q).unwrap();
        let q_before = core.profile_footprint(Q).unwrap();
        let mut map = seeded_map(4);
        map.insert("gone-from-old".into(), json!("never-landed"));
        let out = commit(&core, &map, None).unwrap();
        assert_eq!(out["done"], json!(true));
        assert_eq!(out["reviews"], json!(4));
        assert!(out["deleted"].as_i64().unwrap() > 0);
        assert_eq!(rows_of(&core, P), 0);
        assert_eq!(meta_of(&core, P), 0);
        assert_eq!(meta(&core, &format!("profile_merge/{P}")), None);
        assert_eq!(core.profile_footprint(Q).unwrap(), q_before);
        // 旧 uid 已经没有事件：再提交一次照样成立（空集合都在计划里），删 0 行。
        let again = commit(&core, &Map::new(), None).unwrap();
        assert_eq!(again["done"], json!(true));
        assert_eq!(again["deleted"], json!(0));
    }

    /// 计划之后旧 uid 又多了事件（不在映射的键里）→ `{"done": false}`，一行不动；调用方重新计划。
    #[test]
    fn merge_commit_waits_for_events_outside_the_plan() {
        let (core, _d) = open("commit-late");
        seed(&core, P, 1, 2);
        seed(&core, Q, 1, 2);
        core.profile_merge_mark(P, 7, Q).unwrap();
        let before = rows_of(&core, P);
        let mut map = seeded_map(2);
        map.remove(&format!("L-{P}-1"));
        assert_eq!(commit(&core, &map, None).unwrap(), json!({"done": false}));
        assert_eq!(rows_of(&core, P), before);
        assert!(meta(&core, &format!("profile_merge/{P}")).is_some());
    }

    /// 映射过去的新 ID 不在新 uid 下 → `{"done": false, "missing": N}`，一行不动。在操作索引里出现（被支配的修改
    /// 记录、被清除内容的日志不在投影里）也算到位。
    #[test]
    fn merge_commit_counts_events_missing_under_the_new_uid() {
        let (core, _d) = open("commit-missing");
        seed(&core, P, 1, 2);
        seed(&core, Q, 1, 2);
        let before = rows_of(&core, P);
        let mut map = seeded_map(2);
        map.insert(format!("L-{P}-0"), json!("only-in-log-meta"));
        map.insert(format!("L-{P}-1"), json!("only-in-edit-ops"));
        assert_eq!(
            commit(&core, &map, None).unwrap(),
            json!({"done": false, "missing": 2})
        );
        assert_eq!(rows_of(&core, P), before);
        // 别的 uid 名下有同名 ID 不算。
        {
            let w = core.writer().unwrap();
            w.execute(
                "INSERT INTO sync2_edit_ops (edit_id, profile_uid, device, seq) VALUES (srs_id('only-in-edit-ops'), srs_id(?1), x'00', 1)",
                [P],
            )
            .unwrap();
        }
        assert_eq!(commit(&core, &map, None).unwrap()["missing"], json!(2));
        {
            let w = core.writer().unwrap();
            w.execute(
                "UPDATE sync2_edit_ops SET profile_uid = srs_id(?1) WHERE edit_id = srs_id('only-in-edit-ops')",
                [Q],
            )
            .unwrap();
        }
        assert_eq!(commit(&core, &map, None).unwrap()["missing"], json!(1));
        {
            let w = core.writer().unwrap();
            w.execute(
                "INSERT INTO sync2_log_meta (log_id, profile_uid, card_id, intent, device, seq) VALUES (srs_id('only-in-log-meta'), srs_id(?1), 'C', 0, x'00', 2)",
                [Q],
            )
            .unwrap();
        }
        assert_eq!(commit(&core, &map, None).unwrap()["done"], json!(true));
        assert_eq!(rows_of(&core, P), 0);
    }

    /// 核对通过之后出错（测试注入）：整笔回滚，旧 uid 与标记都还在；再来一次照常完成。
    #[test]
    fn merge_commit_is_all_or_nothing() {
        let (core, _d) = open("commit-fail");
        seed(&core, P, 2, 3);
        seed(&core, Q, 2, 3);
        core.profile_merge_mark(P, 7, Q).unwrap();
        let before = core.profile_footprint(P).unwrap();
        let map = seeded_map(3);
        let err = commit(&core, &map, Some("check")).unwrap_err();
        assert!(err.contains("injected failure"), "{err}");
        assert_eq!(core.profile_footprint(P).unwrap(), before);
        assert!(meta(&core, &format!("profile_merge/{P}")).is_some());
        assert_eq!(commit(&core, &map, None).unwrap()["done"], json!(true));
        assert_eq!(rows_of(&core, P), 0);
    }

    /// 不嵌进 Drift 开着的事务（那笔事务回滚会把删除一起带走）；旧库搬迁开着时三条写命令都拒绝；参数不对报错。
    #[test]
    fn merge_commit_refuses_foreign_transactions_and_bad_arguments() {
        let (core, _d) = open("commit-refuse");
        seed(&core, P, 1, 1);
        seed(&core, Q, 1, 1);
        let before = rows_of(&core, P);
        let map = seeded_map(1);
        for (from, to) in [("", Q), (P, ""), (P, P)] {
            assert!(
                core.profile_merge_commit(from, to, b"{}", None)
                    .unwrap_err()
                    .contains("bad from / to")
            );
        }
        assert!(
            core.profile_merge_commit(P, Q, b"[1]", None)
                .unwrap_err()
                .contains("bad map")
        );
        core.exec("BEGIN", &[], false).unwrap();
        let err = commit(&core, &map, None).unwrap_err();
        assert!(err.contains("Drift transaction"), "{err}");
        core.exec("ROLLBACK", &[], false).unwrap();
        assert_eq!(rows_of(&core, P), before);

        let (legacy, _d2) = open("commit-legacy");
        legacy.legacy_begin().unwrap();
        for err in [
            legacy.profile_merge_mark(P, 1, Q).unwrap_err(),
            legacy.profile_merge_commit(P, Q, b"{}", None).unwrap_err(),
            legacy
                .meta_set_edit("retiredUids", Some("a"), None)
                .unwrap_err(),
            legacy.profile_purge(P).unwrap_err(),
        ] {
            assert_eq!(err, "legacy import in progress");
        }
        legacy.legacy_abort().unwrap();
    }

    /// 集合的增删：已有元素的顺序不动、新值追加、重复不写、删不存在的不写；坏值 / 非字符串元素当空 / 丢弃；
    /// 两个集合各用各的键；不认识的集合报错。
    #[test]
    fn meta_set_edit_adds_and_removes_in_place() {
        let (core, _d) = open("meta-set");
        let edit = |set: &str, add: Option<&str>, remove: Option<&str>| {
            core.meta_set_edit(set, add, remove).unwrap()["values"].clone()
        };
        assert_eq!(edit("retiredUids", None, None), json!([]));
        assert_eq!(edit("retiredUids", None, Some("x")), json!([]));
        assert_eq!(
            meta(&core, "srs_retired_profile_uids"),
            None,
            "no change, no write"
        );
        assert_eq!(edit("retiredUids", Some("b"), None), json!(["b"]));
        assert_eq!(edit("retiredUids", Some("a"), None), json!(["b", "a"]));
        assert_eq!(edit("retiredUids", Some("b"), None), json!(["b", "a"]));
        assert_eq!(
            meta(&core, "srs_retired_profile_uids").unwrap(),
            "[\"b\",\"a\"]"
        );
        assert_eq!(edit("retiredDevices", Some("d"), None), json!(["d"]));
        assert_eq!(meta(&core, "srs_retired_v2_devices").unwrap(), "[\"d\"]");
        // 同一次里先删后加：换到末尾。
        assert_eq!(edit("retiredUids", Some("b"), Some("b")), json!(["a", "b"]));
        assert_eq!(edit("retiredUids", None, Some("a")), json!(["b"]));
        assert_eq!(edit("retiredUids", None, None), json!(["b"]));
        assert_eq!(edit("retiredDevices", None, None), json!(["d"]));
        assert!(
            core.meta_set_edit("other", Some("a"), None)
                .unwrap_err()
                .contains("unknown set")
        );
        for (bad, want) in [
            ("not json", json!(["n"])),
            ("{\"a\": 1}", json!(["n"])),
            ("[1, \"a\", null, \"a\", \"c\"]", json!(["a", "c", "n"])),
        ] {
            {
                let w = core.writer().unwrap();
                w.execute(
                    "INSERT OR REPLACE INTO srs_meta (key, value) VALUES ('srs_retired_profile_uids', ?1)",
                    [bad],
                )
                .unwrap();
            }
            assert_eq!(edit("retiredUids", Some("n"), None), want, "{bad}");
        }
    }

    /// 只读调用在 Drift 开着的事务里看得见那笔事务里未提交的值（走写连接），事务回滚后看到原值。
    #[test]
    fn meta_set_read_sees_the_open_transaction() {
        let (core, _d) = open("meta-set-tx");
        core.meta_set_edit("retiredUids", Some("a"), None).unwrap();
        core.exec("BEGIN", &[], false).unwrap();
        core.meta_set_edit("retiredUids", Some("b"), None).unwrap();
        assert_eq!(
            core.meta_set_edit("retiredUids", None, None).unwrap()["values"],
            json!(["a", "b"])
        );
        core.exec("ROLLBACK", &[], false).unwrap();
        assert_eq!(
            core.meta_set_edit("retiredUids", None, None).unwrap()["values"],
            json!(["a"])
        );
    }
}
