//! 本机状态行（`srs_local_state.json`，每个 profile 一行）的合并协议（收掉 Dart 写路径第 1.5 步，审查 S1）。
//!
//! 这一行以前只有 Dart 一个主人：`_saveLocal` 按内存字段重新拼整份 JSON、整行覆盖；收段的一步把同一份 JSON 交给内核在
//! 投递的事务里写（store/sync2/transport.rs `persist_local_state`），同样整行覆盖。之后的步骤要把其中的字段一个个交给
//! 内核持有（缓存口径版本 `cacheRev`、变更戳……），整行覆盖会让 Dart 下一次 `_saveLocal` 把内核刚写的值抹掉。
//!
//! 协议：键分两类——
//! - **内核持有**（[KERNEL_HELD_KEYS]）：只有内核写。任何一方交来的整行里带了这些键也不认，一律保留库里原值（没有原值
//!   就没有这个键）。
//! - **其余键**：Dart 持有。整行以交来的为准（交来的没有就删掉，例如媒体回收清单清空时 Dart 省略 `mediaGc`）。
//!
//! 两个写入方共用同一个合并函数 [merge]：Dart 经 SQL 函数 `srs_local_state_merge(旧, 新)`（在写连接上注册，
//! [register]）写 upsert，内核经 [upsert]（同一条 SQL）。内核持有的键的写入方（之后的步骤）直接改这一行里自己的键，
//! 不经这里。
//!
//! 首版白名单为空：这一步只立协议、不交出任何字段（审查 S1：协议完成前不得把字段交给内核持有）。

use rusqlite::functions::FunctionFlags;
use rusqlite::types::ValueRef;
use rusqlite::{Connection, params};
use serde_json::{Map, Value};

/// 内核持有的本机状态键（见模块文档）。新增一个键 = 把它的所有权交给内核：同时删掉 Dart `_localStateJson` 里的这个键
/// 的写入（写了也被忽略），读仍可读。
pub(crate) const KERNEL_HELD_KEYS: &[&str] = &[];

#[cfg(test)]
thread_local! {
    /// 测试用：替换 [KERNEL_HELD_KEYS]（白名单首版为空，合并语义只能在测试里用非空表验证）。
    static HELD_OVERRIDE: std::cell::RefCell<Option<Vec<&'static str>>> =
        const { std::cell::RefCell::new(None) };
}

/// 测试用：本线程上把白名单换成 [keys]，返回的守卫析构时恢复。
#[cfg(test)]
pub(crate) fn override_held_keys(keys: &[&'static str]) -> HeldOverride {
    HELD_OVERRIDE.with(|h| *h.borrow_mut() = Some(keys.to_vec()));
    HeldOverride
}

/// [override_held_keys] 的守卫。
#[cfg(test)]
pub(crate) struct HeldOverride;

#[cfg(test)]
impl Drop for HeldOverride {
    fn drop(&mut self) {
        HELD_OVERRIDE.with(|h| *h.borrow_mut() = None);
    }
}

fn is_held(key: &str) -> bool {
    #[cfg(test)]
    if let Some(held) = HELD_OVERRIDE.with(|h| h.borrow().clone()) {
        return held.contains(&key);
    }
    KERNEL_HELD_KEYS.contains(&key)
}

/// 合并：[incoming]（整行 JSON 对象）去掉内核持有的键，再补上 [existing] 里内核持有的键。[existing] 为 None（还没有这
/// 一行）或解析不了（损坏的行）时只去掉内核持有的键。[incoming] 必须是 JSON 对象。
pub(crate) fn merge(existing: Option<&str>, incoming: &str) -> Result<String, String> {
    let incoming: Value =
        serde_json::from_str(incoming).map_err(|e| format!("srs local state: bad json: {e}"))?;
    let Value::Object(incoming) = incoming else {
        return Err("srs local state must be a JSON object".into());
    };
    let mut out: Map<String, Value> = incoming.into_iter().filter(|(k, _)| !is_held(k)).collect();
    if let Some(Ok(Value::Object(old))) = existing.map(serde_json::from_str::<Value>) {
        for (k, v) in old {
            if is_held(&k) {
                out.insert(k, v);
            }
        }
    }
    Ok(Value::Object(out).to_string())
}

/// `srs_local_state_merge(旧 json 或 NULL, 新 json)`：[merge] 的 SQL 形态（Dart `_saveLocal` 的 upsert 用）。
pub(crate) fn register(conn: &Connection) -> rusqlite::Result<()> {
    let flags = FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC;
    conn.create_scalar_function("srs_local_state_merge", 2, flags, |ctx| {
        let text = |i: usize| -> rusqlite::Result<Option<&str>> {
            match ctx.get_raw(i) {
                ValueRef::Null => Ok(None),
                ValueRef::Text(t) => std::str::from_utf8(t)
                    .map(Some)
                    .map_err(|e| rusqlite::Error::UserFunctionError(e.into())),
                _ => Err(rusqlite::Error::UserFunctionError(
                    "srs_local_state_merge: json must be text".into(),
                )),
            }
        };
        let incoming = text(1)?.ok_or_else(|| {
            rusqlite::Error::UserFunctionError("srs_local_state_merge: missing json".into())
        })?;
        merge(text(0)?, incoming).map_err(|e| rusqlite::Error::UserFunctionError(e.into()))
    })
}

/// 写本机状态行的唯一语句（Dart `_saveLocal` 用同一条，见 packages/fushi_engine/lib/srs/srs_db_store.dart）。
pub(crate) const UPSERT_SQL: &str = "INSERT INTO srs_local_state (profile_uid, json) \
     VALUES (srs_id(?1), srs_local_state_merge(NULL, ?2)) \
     ON CONFLICT(profile_uid) DO UPDATE SET json = srs_local_state_merge(json, excluded.json)";

/// 按协议写 [profile] 的本机状态行（[json] 是交来的整行）。
pub(crate) fn upsert(c: &Connection, profile: &str, json: &str) -> Result<(), String> {
    c.prepare_cached(UPSERT_SQL)
        .map_err(|e| e.to_string())?
        .execute(params![profile, json])
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parsed(s: &str) -> Value {
        serde_json::from_str(s).unwrap()
    }

    #[test]
    fn empty_whitelist_keeps_the_incoming_row_as_is() {
        let out = merge(Some(r#"{"a":1,"gone":2}"#), r#"{"a":3,"b":4}"#).unwrap();
        assert_eq!(parsed(&out), json!({"a": 3, "b": 4}));
    }

    #[test]
    fn kernel_held_keys_keep_the_stored_value() {
        let _g = override_held_keys(&["k"]);
        // 库里有：保留库里的值，交来的同名键不认。
        let out = merge(Some(r#"{"a":1,"k":7}"#), r#"{"a":3,"k":99}"#).unwrap();
        assert_eq!(parsed(&out), json!({"a": 3, "k": 7}));
        // 交来的没有：照样保留。
        let out = merge(Some(r#"{"k":7}"#), r#"{"a":3}"#).unwrap();
        assert_eq!(parsed(&out), json!({"a": 3, "k": 7}));
        // 库里没有（新行 / 损坏的行）：交来的内核键也不认。
        let out = merge(None, r#"{"a":3,"k":99}"#).unwrap();
        assert_eq!(parsed(&out), json!({"a": 3}));
        let out = merge(Some("not json"), r#"{"a":3,"k":99}"#).unwrap();
        assert_eq!(parsed(&out), json!({"a": 3}));
        assert!(merge(None, "[1]").is_err());
        assert!(merge(None, "nope").is_err());
    }

    /// Dart `_saveLocal` 经 Drift 执行器（`SrsCore::exec`）跑 [UPSERT_SQL]：新行、更新都走同一个合并。
    #[test]
    fn the_drift_upsert_merges_through_the_sql_function() {
        let _g = override_held_keys(&["k"]);
        let dir = std::env::temp_dir().join(format!(
            "srs_local_state_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let core = crate::store::SrsCore::open(&dir.join("srs.db")).unwrap();
        let p = "01928c3e-0000-7000-8000-000000001a5e";
        let put = |json: &str| {
            core.exec(
                UPSERT_SQL,
                &[
                    rusqlite::types::Value::Text(p.into()),
                    rusqlite::types::Value::Text(json.into()),
                ],
                false,
            )
            .unwrap();
        };
        let stored = || -> Value {
            let w = core.writer().unwrap();
            parsed(
                &w.query_row(
                    "SELECT json FROM srs_local_state WHERE profile_uid = srs_id(?1)",
                    [p],
                    |r| r.get::<_, String>(0),
                )
                .unwrap(),
            )
        };
        put(r#"{"a":1,"k":5}"#);
        assert_eq!(stored(), json!({"a": 1}));
        core.exec(
            "UPDATE srs_local_state SET json = json_set(json, '$.k', 7)",
            &[],
            false,
        )
        .unwrap();
        put(r#"{"a":2,"k":99}"#);
        assert_eq!(stored(), json!({"a": 2, "k": 7}));
        // 内核这一侧的写入（收段的 `persist_local_state` 等）用同一个函数。
        upsert(&core.writer().unwrap(), p, r#"{"b":3}"#).unwrap();
        assert_eq!(stored(), json!({"b": 3, "k": 7}));
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
