//! 新代库里的本机状态行（协议 3 `store/local_state.rs` 的新代存处，规划 §2.2 S1）：每个 profile 一行 JSON，存在新代库的
//! `srs_meta` 里，键 `local_state/<profile uid>`（[KEY_PREFIX]）。只有内核写。
//!
//! 行的键与协议 3 相同（`revision`、`epoch`、`anchor`），回包形态也相同（`local_state::view`）：
//!
//! - 修订号 `revision`：改投影的写命令在自己的事务里按**库里的值**推进（[persist]），回包 `localRevision` /
//!   `localEpoch`。推进量 = 回包里 `changed` + `purged` + `replayed` + `edits` 的条数（新代写命令的统一回包，
//!   `cmd/writes.rs` 文件头；协议 3 是 `marks.landed` + `changed`——两边都只要求「有改动就前进」，Dart 只拿它拼指纹）。
//! - 纪元 `epoch`：行第一次写下时生成。**迁移不带协议 3 的行过来**（`carry.rs` 不收它）：迁移之后第一次写下是新纪元，
//!   Dart 的指纹（`纪元:修订号`）随之全换，缓存全部重读——换代本来就要重读。
//! - 校时状态 `anchor`：随写命令交来或 `local_anchor` 单独交来。迁移同样不带：迁移后第一次校时之前当没校过。
//! - 媒体回收的待回收集合 `mediaGc`（[media_gc_pending] / [set_media_gc_pending]，`cmd/media_gc.rs`）：键名与形态同协议 3
//!   （排序的字符串数组，空集合时没有这个键），整行读改写时原样留着。**迁移同样不带**：换代时还没回收的名字留在旧库
//!   里，那些文件这一轮不删（宁可多留；以后引用它们的笔记删除满保留期时会重新成为候选）。
//! - 协议 3 的 `styleCursor`（存量样式去重）、`cacheRev`（缓存推导口径）在新代没有：是协议 3 存储表示的事。
//!
//! 不需要 profile 已经绑定集合（与协议 3 相同：这一行只按 profile uid 记）。
//!
//! **profile 串原样进键、不归一**：协议 3 的 `srs_local_state.profile_uid` 是 ID 列，经 `srs_id(?1)` 把 UUID 文本打包成
//! 16 字节，大小写不同的同一个 UUID 落到同一行；新代的 `collections.profile_uid`（`Truth::binding_of`）同样按原样的串比，
//! 这里跟它一致——一个 profile 在新代里只认一种写法。Dart 一直传同一种写法（`Profile.uid`），不受影响；换写法 = 另一行。

use serde_json::{Map, Value};

use super::schema::sql;
use super::truth::Truth;
use crate::store::local_state::{ANCHOR_KEY, EPOCH_KEY, REVISION_KEY, has_epoch, new_epoch, view};
use rusqlite::OptionalExtension;

/// `srs_meta` 里本机状态行的键前缀（按 profile 记、uid 在最后：登记在 `profile_data.rs` 的 `META_PROFILE_LAST`，
/// 那边的守卫按 [key] 里的字面量核对）。
pub const KEY_PREFIX: &str = "local_state/";

fn key(profile: &str) -> String {
    format!("local_state/{profile}")
}

/// [stored] 执行的语句（查询计划测试用同一份）。
pub(crate) const STORED_SQL: &str = "SELECT value FROM srs_meta WHERE key = ?1";

/// [profile] 的行：没有 → None；损坏（不是 JSON 对象）→ 空对象（同协议 3）。
fn stored(t: &Truth<'_>, profile: &str) -> Result<Option<Map<String, Value>>, String> {
    let raw: Option<String> = t
        .conn()
        .prepare_cached(STORED_SQL)
        .map_err(sql)?
        .query_row([key(profile)], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    Ok(raw.map(|j| match serde_json::from_str::<Value>(&j) {
        Ok(Value::Object(m)) => m,
        _ => Map::new(),
    }))
}

/// 读改写整行（调用方的写事务里）：没有行从空行起，没纪元补一个，过 [f]，写回。返回写下的行。
fn edit(
    t: &Truth<'_>,
    profile: &str,
    f: impl FnOnce(&mut Map<String, Value>),
) -> Result<Map<String, Value>, String> {
    let mut row = stored(t, profile)?.unwrap_or_default();
    if !has_epoch(&row) {
        row.insert(EPOCH_KEY.to_owned(), Value::from(new_epoch()));
    }
    f(&mut row);
    let text = Value::Object(row.clone()).to_string();
    t.write(|| {
        t.conn()
            .prepare_cached(
                "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            )
            .map_err(sql)?
            .execute([key(profile), text])
            .map_err(sql)?;
        Ok(())
    })?;
    Ok(row)
}

/// `local_state`：`{exists, revision, styleCursor, epoch, epochStored, anchor}`（同协议 3）。只读，不建行。
pub fn read(t: &Truth<'_>, profile: &str) -> Result<Value, String> {
    Ok(view(stored(t, profile)?.as_ref()))
}

/// `local_state_ensure`：没有行就建、没有纪元就补，回同 [read] 的形态（`exists` = 调用前有没有行）。
pub fn ensure(t: &Truth<'_>, profile: &str) -> Result<Value, String> {
    let existed = stored(t, profile)?.is_some();
    let row = edit(t, profile, |_| {})?;
    let mut out = view(Some(&row));
    out["exists"] = Value::from(existed);
    Ok(out)
}

/// `local_anchor`：写下校时状态（没有行就建）。
pub fn set_anchor(t: &Truth<'_>, profile: &str, anchor: &Value) -> Result<(), String> {
    edit(t, profile, |row| {
        row.insert(ANCHOR_KEY.to_owned(), anchor.clone());
    })?;
    Ok(())
}

/// 本机状态行里待回收集合的键（协议 3 `store/media_gc.rs` `KEY` 同一个）。
const MEDIA_GC_KEY: &str = crate::store::media_gc::KEY;

/// [profile] 的待回收集合（没有行、没有这个键、行损坏 = 空；同协议 3 `media_gc::pending`）。
pub fn media_gc_pending(
    t: &Truth<'_>,
    profile: &str,
) -> Result<std::collections::BTreeSet<String>, String> {
    Ok(stored(t, profile)?
        .and_then(|row| row.get(MEDIA_GC_KEY).cloned())
        .and_then(|v| match v {
            Value::Array(a) => Some(a),
            _ => None,
        })
        .into_iter()
        .flatten()
        .filter_map(|n| n.as_str().map(str::to_owned))
        .collect())
}

/// 写下 [profile] 的待回收集合（调用方的写事务里，只动这一个键）：空集合删掉这个键（没有行就什么都不写）；非空时没有
/// 行先建行（同协议 3 `media_gc::save`）。
pub fn set_media_gc_pending(
    t: &Truth<'_>,
    profile: &str,
    names: &std::collections::BTreeSet<String>,
) -> Result<(), String> {
    if names.is_empty() {
        if stored(t, profile)?.is_some_and(|row| row.contains_key(MEDIA_GC_KEY)) {
            edit(t, profile, |row| {
                row.remove(MEDIA_GC_KEY);
            })?;
        }
        return Ok(());
    }
    let list = Value::Array(names.iter().cloned().map(Value::String).collect());
    edit(t, profile, |row| {
        row.insert(MEDIA_GC_KEY.to_owned(), list);
    })?;
    Ok(())
}

/// 一条写命令在**同一笔事务**里推进修订号并写下本机状态行（文件头）；[anchor] 给了就一并写下。写下的修订号与纪元放进
/// [result] 的 `localRevision` / `localEpoch`。
pub fn persist(
    t: &Truth<'_>,
    profile: &str,
    anchor: Option<&Value>,
    result: &mut Value,
) -> Result<(), String> {
    let count = |k: &str| result[k].as_array().map_or(0, |a| a.len() as i64);
    let by = count("changed") + count("purged") + count("replayed") + count("edits");
    let row = edit(t, profile, |row| {
        let revision = row.get(REVISION_KEY).and_then(Value::as_i64).unwrap_or(0);
        row.insert(REVISION_KEY.to_owned(), Value::from(revision + by));
        if let Some(a) = anchor {
            row.insert(ANCHOR_KEY.to_owned(), a.clone());
        }
    })?;
    if let Some(m) = result.as_object_mut() {
        m.insert(
            "localRevision".to_owned(),
            row.get(REVISION_KEY).cloned().unwrap_or(Value::from(0)),
        );
        m.insert("localEpoch".to_owned(), row[EPOCH_KEY].clone());
    }
    Ok(())
}
