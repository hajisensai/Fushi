//! 本机缓存的推导口径版本（收掉 Dart 写路径第 4 步）：本机缓存（`srs_notes_cache` / `srs_cards_cache` /
//! `srs_stat_reviews`）按哪一版推导规则建的。存在本机状态行（`srs_local_state.json` 的 `cacheRev`），是内核持有的键
//! （store/local_state.rs `KERNEL_HELD_KEYS`）：只有这里写，Dart 整行重写抹不掉它。
//!
//! 以前由 Dart 持有（`SrsDbStore._cacheRevision` / `_kCacheRevision` / `_upgradeCaches`）：打开时比内存里的版本，
//! 低了就在一笔 Drift 事务里发一串 `refresh_caches` / `backfill_*`，再整行写一次本机状态。现在打开时 Dart 只发一条
//! `cache_config_set`（注册本 profile 的缓存配置，见 store/mod.rs `cache_configs`），内核在**同一个 SAVEPOINT** 里
//! 读出存着的版本、补做落后的各级、记下 [CACHE_REVISION]（[upgrade]）；重建缓存（`rebuild_caches`）同样在它的
//! SAVEPOINT 里记下当前版本（[record]）。
//!
//! 兼容：存量库的这个键就是旧版 Dart 写的同一个键（旧值原样当起点）；有本机状态行却没有这个键 = 比修订号 1 还老，
//! 按 0；还没有本机状态行（新设备 / 覆盖恢复备份后）= 缓存要么还没有、要么随即整份重建，按当前规则算——行第一次
//! 写下时由合并协议补上当前版本（local_state.rs `held_default`）。
//!
//! 版本历史（缓存加了新的派生列、而存量库里可能已有喂它的修改记录时 +1，并在 [upgrade] 里补一步定向重算）：
//!
//! 1（v123）：srs_cards_cache.new_position。旧版本设备会照常收下对端同步来的 `newPos` 修改记录，但它的卡片缓存没有
//! 这一列；升级加列时留 NULL，这些卡就一直按创建时刻出，直到这张卡再被改一次。
//! 2（srs.db schema v3）：srs_stat_reviews（有效复习投影）。存量库的投影表是新建的空表，按全部有日志的卡算一遍。
//! 3（srs.db schema v4）：srs_notes_cache.media_refs。老库这一列是空的，全部笔记缓存重算一遍。
//! 4（同步 v2）：已删笔记也存 media_refs（以前写空串），升级时随 3 / 7 的整库重算补上。
//! 5（BUG-3797）：srs_notes_cache.pending_decision 的推导改了（标签 OR-Set 的合成 `tags` 行不再当成「与删除并发的
//! 修改」），把标着待裁决的笔记重算一遍（[pending_decision_notes]，原 Dart `notesPendingDecision`）。
//! 6（srs.db schema v8）：srs_cards_cache.freq_rank，随 7 的整库重算补上。
//! 7（srs.db schema v13）：srs_notes_cache.source_kind / source_title，全部笔记缓存重算一遍。
//! 8（srs.db schema v15）：srs_notes_cache.dupe_norm，只补仍为 NULL 的行（caches.rs `backfill_dupe_norms`）。
//! 9：没有出处记录的制卡笔记按制卡标签认出处，只补出处两列（caches.rs `backfill_tag_sources`）。
//! 10（srs.db schema v25）：srs_notes_cache.source_key，只补仍为 NULL 的行（caches.rs `backfill_source_keys`）。
//! 11（BUG-4218）/ 12（BUG-4254）：卡片历史选取规则变了，卡片状态与有效复习投影整库重算（两级同一件事）。
//! 13（反馈 MCJLSBR5Wg）：出处带 `seriesTitle` 的笔记按「系列 → 集」分组，只重算出处记录里带它的笔记（已在 12 的库）。
//!
//! 各级合成一次 [caches::refresh]（缓存行只由事件决定，分几次算与合起来算结果相同），之后再做只补 NULL 的 backfill
//! （整行重算已写好的不会再被它们改）。

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use super::caches::{self, CacheConfig, Dirty};
use super::sync2::sql;

/// 当前缓存推导口径版本（见模块文档的版本历史）。
pub(crate) const CACHE_REVISION: i64 = 13;

/// 本机状态行里的键（内核持有）。
pub(crate) const KEY: &str = "cacheRev";

/// [profile] 存着的版本：没有本机状态行 → None；有行没有这个键（或行损坏）→ 0。
pub(crate) fn stored(c: &Connection, profile: &str) -> Result<Option<i64>, String> {
    let row: Option<String> = c
        .query_row(
            "SELECT json FROM srs_local_state WHERE profile_uid = srs_id(?1)",
            [profile],
            |r| r.get(0),
        )
        .optional()
        .map_err(sql)?;
    Ok(row.map(|j| {
        serde_json::from_str::<Value>(&j)
            .ok()
            .and_then(|v| v.get(KEY).and_then(Value::as_i64))
            .unwrap_or(0)
    }))
}

/// 记下当前版本（缓存刚按当前规则建好 / 补好）。还没有本机状态行就不写：行第一次写下时由合并协议补上当前版本。
pub(crate) fn record(c: &Connection, profile: &str) -> Result<(), String> {
    c.prepare_cached(
        "UPDATE srs_local_state SET json = json_set(json, '$.cacheRev', ?2) \
         WHERE profile_uid = srs_id(?1)",
    )
    .map_err(sql)?
    .execute(params![profile, CACHE_REVISION])
    .map_err(sql)?;
    Ok(())
}

/// 标着待裁决（内容类冲突 / 删除与并发修改）的笔记（原 Dart `SrsDbStore.notesPendingDecision` 的 ID 部分）。
pub(crate) fn pending_decision_notes(c: &Connection, profile: &str) -> Result<Vec<String>, String> {
    ids(
        c,
        "SELECT srs_idt(id) AS id FROM srs_notes_cache \
         WHERE profile_uid = srs_id(?1) AND pending_decision = 1",
        profile,
    )
}

fn ids(c: &Connection, q: &str, profile: &str) -> Result<Vec<String>, String> {
    let mut stmt = c.prepare(q).map_err(sql)?;
    let rows = stmt
        .query_map([profile], |r| r.get::<_, String>(0))
        .map_err(sql)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(sql)
}

/// 把 [profile] 的缓存补到 [CACHE_REVISION]（调用方持写锁、开好 SAVEPOINT；出错整个回滚，下次打开重来）。没有本机
/// 状态行、或已是当前（或更新的）版本时什么也不做。返回 `{from, to, current, cache}`（`cache` 同投影命令的缓存写入清单）。
pub(crate) fn upgrade(c: &Connection, profile: &str, cfg: &CacheConfig) -> Result<Value, String> {
    let Some(from) = stored(c, profile)? else {
        return Ok(done(
            CACHE_REVISION,
            CACHE_REVISION,
            &caches::Written::default(),
        ));
    };
    if from >= CACHE_REVISION {
        return Ok(done(from, from, &caches::Written::default()));
    }
    let mut dirty = Dirty::default();
    if from < 1 {
        dirty.cards.extend(ids(
            c,
            "SELECT DISTINCT srs_idt(entity_id) AS id FROM srs_field_edits \
             WHERE profile_uid = srs_id(?1) AND entity_kind = 'card' AND field_key = 'newPos'",
            profile,
        )?);
    }
    if from < 2 {
        dirty.all_stats = true;
    }
    // 3 / 7（以及随它们补上的 4 / 6）：全部笔记缓存重算。
    if from < 7 {
        dirty.all_notes = true;
    }
    if from < 5 {
        dirty.notes.extend(pending_decision_notes(c, profile)?);
    }
    if from < 12 {
        dirty.all_notes = true;
        dirty.all_stats = true;
    } else if from < 13 {
        // 整库重算已按新规则写好；只有已在 12 的库才需要挑出带系列的出处。按子串粗筛（多挑只是多重算几行），真正的
        // 分组键由刷新按出处 JSON 算。
        dirty.notes.extend(ids(
            c,
            "SELECT DISTINCT srs_idt(entity_id) AS id FROM srs_field_edits \
             WHERE profile_uid = srs_id(?1) AND entity_kind = 'note' AND field_key = 'source' \
             AND json LIKE '%seriesTitle%'",
            profile,
        )?);
    }
    let written = caches::refresh(c, profile, cfg, dirty)?;
    // 整行重算已顺带写好这些列；下面只补仍为 NULL / 空的老行（只改这几列，不算缓存写入）。
    if from < 8 {
        caches::backfill_dupe_norms(c, profile, cfg)?;
    }
    if from < 9 {
        caches::backfill_tag_sources(c, profile)?;
    }
    if from < 10 {
        caches::backfill_source_keys(c, profile)?;
    }
    record(c, profile)?;
    Ok(done(from, CACHE_REVISION, &written))
}

/// 回包：`from` / `to` 是这次之前 / 之后存着的版本，`current` 是这一版内核的 [CACHE_REVISION]（测试读它，不写字面量）。
fn done(from: i64, to: i64, written: &caches::Written) -> Value {
    json!({"from": from, "to": to, "current": CACHE_REVISION, "cache": written.to_json()})
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::{CACHE_REVISION, stored};
    use crate::store::sync2::tests::{Device, P, deck_entity, edit};

    const T0: i64 = 1_700_000_000_000;
    const NT: &str = "0193a1b2-0000-7000-8000-00000000c0a1";
    const NOTE: &str = "0193a1b2-0000-7000-8000-00000000c0b1";

    fn caches() -> Value {
        json!({"defaultDeck": crate::store::sync2::config::default_deck_id(P)})
    }

    fn dispatch(d: &Device, req: Value, blob: Option<String>) -> Result<Value, String> {
        let mut blobs: Vec<Vec<u8>> = blob.into_iter().map(String::into_bytes).collect();
        let mut files = Vec::new();
        crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files)
    }

    /// 一个笔记类型 + 一条笔记（生成一张卡）。
    fn add_note(d: &Device) {
        let deck = crate::store::sync2::config::default_deck_id(P);
        let events = vec![
            deck_entity(&deck),
            json!({"t": "entity", "x": {"id": NT, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            edit(
                "notetype",
                NT,
                "fieldDef/fa",
                json!({"name": "Front", "ord": 0}),
            ),
            edit(
                "notetype",
                NT,
                "tmplDef/t1",
                json!({"name": "C", "ord": 0, "front": "{{Front}}"}),
            ),
            json!({"t": "entity", "x": {"id": NOTE, "p": P, "k": "note", "d": {"createdAt": 1, "guid": NOTE, "noteTypeId": NT}}}),
            edit("note", NOTE, "f/fa", json!("word")),
        ];
        let input = Value::Array(
            events
                .into_iter()
                .map(|e| json!({"e": e, "note": null}))
                .collect(),
        )
        .to_string();
        dispatch(
            d,
            json!({"op": "apply", "profile": P, "now": T0, "caches": caches(), "legacyDevice": "dev"}),
            Some(input),
        )
        .unwrap();
    }

    fn put_row(d: &Device, json: &str) {
        d.core
            .writer()
            .unwrap()
            .execute(
                "INSERT INTO srs_local_state (profile_uid, json) VALUES (srs_id(?1), ?2) \
                 ON CONFLICT(profile_uid) DO UPDATE SET json = excluded.json",
                rusqlite::params![P, json],
            )
            .unwrap();
    }

    fn rev(d: &Device) -> Option<i64> {
        stored(&d.core.reader().unwrap(), P).unwrap()
    }

    fn note_rows(d: &Device) -> i64 {
        d.rows("SELECT COUNT(*) AS n FROM srs_notes_cache")[1][0]
            .parse()
            .unwrap()
    }

    /// 存量库（旧 Dart 写下的 `cacheRev`）：打开时注册配置的同一次调用里补到当前版本并记下；再开一次什么也不做；注册过
    /// 的配置供之后没带 `caches` 的命令用。
    #[test]
    fn cache_config_set_upgrades_an_old_row_and_records_the_revision() {
        let d = Device::new("cr-upgrade");
        add_note(&d);
        put_row(&d, r#"{"revision":3,"cacheRev":1}"#);
        d.core
            .writer()
            .unwrap()
            .execute_batch("DELETE FROM srs_notes_cache")
            .unwrap();
        let r = dispatch(
            &d,
            json!({"op": "cache_config_set", "profile": P, "caches": caches()}),
            None,
        )
        .unwrap();
        assert_eq!(
            (r["from"].clone(), r["to"].clone()),
            (json!(1), json!(CACHE_REVISION)),
            "{r}"
        );
        assert_eq!(r["current"], json!(CACHE_REVISION));
        assert!(!r["cache"]["notes"].as_array().unwrap().is_empty(), "{r}");
        assert_eq!(note_rows(&d), 1, "all notes recomputed (revision < 7)");
        assert_eq!(rev(&d), Some(CACHE_REVISION));
        let again = dispatch(
            &d,
            json!({"op": "cache_config_set", "profile": P, "caches": caches()}),
            None,
        )
        .unwrap();
        assert_eq!(again["from"], json!(CACHE_REVISION));
        assert!(again["cache"]["notes"].as_array().unwrap().is_empty());
        // 注册过：没带 `caches` 的刷新用注册的配置。
        dispatch(
            &d,
            json!({"op": "refresh_caches", "profile": P, "allNotes": true}),
            None,
        )
        .unwrap();
    }

    /// 有本机状态行却没有 `cacheRev`：比修订号 1 还老，按 0 全补。
    #[test]
    fn a_row_without_the_key_counts_as_zero() {
        let d = Device::new("cr-zero");
        add_note(&d);
        put_row(&d, r#"{"revision":3}"#);
        let r = dispatch(
            &d,
            json!({"op": "cache_config_set", "profile": P, "caches": caches()}),
            None,
        )
        .unwrap();
        assert_eq!(r["from"], json!(0), "{r}");
        assert_eq!(rev(&d), Some(CACHE_REVISION));
    }

    /// 还没有本机状态行：注册不补也不建行；行第一次写下时取当前版本，交来的 `cacheRev` 不认，之后也改不动。
    #[test]
    fn a_new_row_starts_at_the_current_revision_and_the_key_is_kernel_held() {
        let d = Device::new("cr-new");
        let r = dispatch(
            &d,
            json!({"op": "cache_config_set", "profile": P, "caches": caches()}),
            None,
        )
        .unwrap();
        assert_eq!(r["from"], json!(CACHE_REVISION), "{r}");
        assert_eq!(
            rev(&d),
            None,
            "no local state row is created by registering"
        );
        let w = d.core.writer().unwrap();
        crate::store::local_state::upsert(&w, P, r#"{"revision":1,"cacheRev":2}"#).unwrap();
        drop(w);
        assert_eq!(rev(&d), Some(CACHE_REVISION));
        let w = d.core.writer().unwrap();
        crate::store::local_state::upsert(&w, P, r#"{"revision":2,"cacheRev":4}"#).unwrap();
        drop(w);
        assert_eq!(rev(&d), Some(CACHE_REVISION));
    }

    /// 整份重建：同一个 SAVEPOINT 里记下当前版本。
    #[test]
    fn rebuild_caches_records_the_current_revision() {
        let d = Device::new("cr-rebuild");
        add_note(&d);
        put_row(&d, r#"{"revision":3,"cacheRev":2}"#);
        dispatch(
            &d,
            json!({"op": "rebuild_caches", "profile": P, "caches": caches()}),
            None,
        )
        .unwrap();
        assert_eq!(rev(&d), Some(CACHE_REVISION));
    }

    /// 既没带 `caches` 也没注册过：投影命令报错，不跳过刷新。
    #[test]
    fn a_cache_command_without_config_or_registration_fails() {
        let d = Device::new("cr-missing");
        let err = dispatch(
            &d,
            json!({"op": "refresh_caches", "profile": P, "allNotes": true}),
            None,
        )
        .unwrap_err();
        assert!(err.contains("cache_config_set"), "{err}");
    }
}
