//! 本机 profile（集合）的绑定状态：这台设备上的这个 uid 是不是已经定下了「就是这个集合」。
//!
//! 集合身份就是 `profiles.uid`（不拆分）。新设备第一次打开复习时随机生成一个 uid，接入同步后可能改用同步位置上已有
//! 的那个（关联，`srs_profile_link.dart`）。绑定状态记录这件事走到了哪一步，存在 `srs_meta` 的
//! `srs_collection_bound/<uid>` 键里，值是 `{state, via, at}`：
//!
//! - `state`：`provisional`（暂定：想先加入已有集合，但没赶上——离线、超时、还没确认同步，照常写入、之后由合并兜底）
//!   或 `settled`（已定：已经在某个位置上跑完关联，之后在**别的**位置上看到别的集合只交给用户选，不再自动采用，
//!   免得各位置判出不同答案来回翻）；
//! - `via`：在哪定下 / 想在哪加入的：同步位置的身份（directoryKey），或 `backup`；
//! - `at`：写下的时刻（毫秒）。
//!
//! 只进不退：`settled` 写下后不再被改写（第一次定下的位置为准），`provisional` 只能升成 `settled`。没写过 = 没有记录
//! （null）：老用户升级不迁移，「有没有用户数据」这类隐式判断由调用方按数据现查（Dart 才知道内置行的 ID）。
//!
//! 键按 `…/<uid>` 记，删 / 换 uid 时 `profile_purge` 按后缀一并删掉（profile_data.rs）。只动本机，不随同步传。

use rusqlite::OptionalExtension;
use serde_json::{Value, json};

use super::SrsCore;
use super::sync2::sql;

/// `srs_meta` 里绑定状态的键前缀（键 = 前缀 + uid）。
pub(crate) const BINDING_PREFIX: &str = "srs_collection_bound/";

const PROVISIONAL: &str = "provisional";
const SETTLED: &str = "settled";

fn key(profile: &str) -> String {
    format!("{BINDING_PREFIX}{profile}")
}

/// 解析存着的值；坏了 / 认不出的状态当作没有记录。
fn parse(raw: &str) -> Option<Value> {
    let v: Value = serde_json::from_str(raw).ok()?;
    let state = v.get("state")?.as_str()?;
    if state != PROVISIONAL && state != SETTLED {
        return None;
    }
    Some(json!({
        "state": state,
        "via": v.get("via").and_then(Value::as_str).unwrap_or(""),
        "at": v.get("at").and_then(Value::as_i64).unwrap_or(0),
    }))
}

impl SrsCore {
    /// [profile] 的绑定状态：`{binding: {state, via, at} | null}`。
    pub fn binding_get(&self, profile: &str) -> Result<Value, String> {
        let r = self.reader()?;
        let raw: Option<String> = r
            .query_row(
                "SELECT value FROM srs_meta WHERE key = ?1",
                [key(profile)],
                |x| x.get(0),
            )
            .optional()
            .map_err(sql)?;
        Ok(json!({"binding": raw.as_deref().and_then(parse)}))
    }

    /// 写 [profile] 的绑定状态（只进不退，见模块注释），返回写完之后的状态（同 [Self::binding_get]）。
    /// 已经 `settled` 时什么都不改；已经 `provisional` 时再写 `provisional` 只换 `via` / `at`。
    pub fn binding_set(
        &self,
        profile: &str,
        state: &str,
        via: &str,
        at: i64,
    ) -> Result<Value, String> {
        if profile.is_empty() {
            return Err("binding_set: empty profile uid".into());
        }
        if state != PROVISIONAL && state != SETTLED {
            return Err(format!("binding_set: unknown state {state}"));
        }
        let w = self.writer()?;
        let k = key(profile);
        let current: Option<Value> = w
            .query_row("SELECT value FROM srs_meta WHERE key = ?1", [&k], |x| {
                x.get::<_, String>(0)
            })
            .optional()
            .map_err(sql)?
            .as_deref()
            .and_then(parse);
        if current.as_ref().and_then(|c| c["state"].as_str()) == Some(SETTLED) {
            return Ok(json!({"binding": current}));
        }
        let next = json!({"state": state, "via": via, "at": at});
        w.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [&k, &next.to_string()],
        )
        .map_err(sql)?;
        Ok(json!({"binding": next}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::sync2::tests::{P, tempdir};

    const Q: &str = "0193a1b2-0000-7000-8000-00000000cafe";

    fn open(tag: &str) -> (SrsCore, tempdir::Dir) {
        let dir = tempdir::new(tag);
        let core = SrsCore::open(&dir.0.join("srs.db")).unwrap();
        (core, dir)
    }

    fn state(core: &SrsCore, profile: &str) -> Value {
        core.binding_get(profile).unwrap()["binding"].clone()
    }

    /// 没写过 = 没有记录：升级不迁移，老库里一个键都不用补。
    #[test]
    fn unwritten_binding_is_null() {
        let (core, _d) = open("binding-null");
        assert_eq!(state(&core, P), Value::Null);
    }

    /// 暂定可以升成已定；已定之后再写暂定或别的位置的已定都不改（第一次定下的位置为准）。
    #[test]
    fn binding_only_moves_forward() {
        let (core, _d) = open("binding-forward");
        core.binding_set(P, PROVISIONAL, "loc-a", 1).unwrap();
        assert_eq!(state(&core, P)["state"], PROVISIONAL);
        core.binding_set(P, PROVISIONAL, "loc-b", 2).unwrap();
        assert_eq!(state(&core, P)["via"], "loc-b");
        core.binding_set(P, SETTLED, "loc-a", 3).unwrap();
        assert_eq!(
            state(&core, P),
            json!({"state": SETTLED, "via": "loc-a", "at": 3})
        );
        let after = core.binding_set(P, SETTLED, "loc-b", 4).unwrap();
        assert_eq!(after["binding"]["via"], "loc-a");
        core.binding_set(P, PROVISIONAL, "loc-b", 5).unwrap();
        assert_eq!(state(&core, P)["state"], SETTLED);
        assert_eq!(state(&core, Q), Value::Null, "按 uid 分开记");
    }

    #[test]
    fn binding_set_rejects_unknown_state() {
        let (core, _d) = open("binding-bad");
        assert!(core.binding_set(P, "bound", "x", 1).is_err());
        assert!(core.binding_set("", SETTLED, "x", 1).is_err());
    }

    /// 删 / 换 uid 的唯一实现 `profile_purge` 连绑定状态一起删；别的 uid 的不动。
    #[test]
    fn purge_removes_the_binding() {
        let (core, _d) = open("binding-purge");
        core.binding_set(P, SETTLED, "loc-a", 1).unwrap();
        core.binding_set(Q, SETTLED, "loc-a", 1).unwrap();
        core.profile_purge(P).unwrap();
        assert_eq!(state(&core, P), Value::Null);
        assert_eq!(state(&core, Q)["state"], SETTLED);
    }
}
