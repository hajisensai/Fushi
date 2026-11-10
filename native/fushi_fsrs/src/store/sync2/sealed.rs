//! 存储位置「是加密的」这一事实的本机记账（设计 docs/specs/2026-10-25-srs-sync-v2-design.md §9）。
//!
//! 位置上的 `meta.json` 是多设备可读改写的单文件：被旧版本 / 别的工具整份重写丢了 `kdf`、在最终一致的网盘上暂时
//! 读不到，或本机密钥被清掉时，单看这一刻的 `meta.json`，没有密钥的设备会把它当成明文位置，往一个已经有密文的地方
//! 写明文段 / 明文媒体（明文泄露，且一旦写上就收不回）。所以本机**一旦见过**「这个位置是加密的」就记下来，此后
//! 不论 `meta.json` 怎么样，Dart 侧握手（srs_location_crypto.dart）都不再向它写明文。
//!
//! 「见过」的来源：读到带 `kdf` 的 `meta.json`、本机为它持有过密钥（握手用密钥收发 / 开加密）、拉段时遇到对这个位置
//! 而言是密封的段或转发件（[sealed_at_location]）、位置上有密封媒体目录。存量：本机在修复之前用密钥同步过的位置，
//! 上传进度身份是 `<位置>#e<密钥指纹>`（`sync2_locations`），同样算见过。
//!
//! 记在 `srs_meta`（键值表，不改表结构）：`sync2_sealed/<位置>/<profile>` = `{"at": 首次记下的毫秒, "kdf": 最近见到
//! 的 kdf（含校验值 `check`；只从段 / 媒体看到时为 null）}`。键以 `/<profile>` 结尾，删 profile 时随按后缀删的元数据
//! 一起删（profile_data.rs）。记下就不撤：位置开了加密就不能在这里关（设计 §9）。

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use super::{in_savepoint, sql};
use crate::store::SrsCore;
use crate::sync2::segment::{MAGIC, RELAY_MAGIC};

/// 记下的 kdf 序列化后的上限（参数来自不可信的 `meta.json`；Dart 侧已按界检查，这里再兜一层）。
const KDF_MAX_BYTES: usize = 1024;

fn key(profile: &str, location: &str) -> String {
    format!("sync2_sealed/{location}/{profile}")
}

fn record(c: &Connection, profile: &str, location: &str) -> Result<Option<Value>, String> {
    let raw: Option<String> = c
        .prepare_cached("SELECT value FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .query_row([key(profile, location)], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    // 记录坏了（不该发生）也按「见过」算：宁可多拦一次，不放明文出去。
    Ok(raw.map(|s| serde_json::from_str::<Value>(&s).unwrap_or_else(|_| json!({}))))
}

/// 本机在修复之前用密钥同步过这个位置：上传进度身份 `<位置>#e…` 在 `sync2_locations` 里。
fn progressed_sealed(c: &Connection, profile: &str, location: &str) -> Result<bool, String> {
    c.prepare_cached(
        "SELECT EXISTS(SELECT 1 FROM sync2_locations WHERE profile_uid = srs_id(?1) \
         AND substr(location, 1, length(?2) + 2) = ?2 || '#e')",
    )
    .map_err(sql)?
    .query_row(params![profile, location], |r| r.get::<_, bool>(0))
    .map_err(sql)
}

fn answer(rec: Option<&Value>, progressed: bool) -> Value {
    match rec {
        Some(v) => json!({"sealed": true, "kdf": v.get("kdf").cloned().unwrap_or(Value::Null)}),
        None => json!({"sealed": progressed, "kdf": Value::Null}),
    }
}

/// 段文件或转发件对**它所在的位置**而言是不是密封的：原段看段头的加密位，转发件看外层的封装位（转发到明文位置的
/// 密文原段带着明文体，对那个位置不算密封）。两种格式都是 `魔数[4] | 版本 u8 | flags u8（bit0）` 开头
/// （crate::sync2::segment 的格式说明），所以只要前 6 个字节。认不出的前缀不算。
pub fn sealed_at_location(prefix: &[u8]) -> bool {
    (prefix.starts_with(MAGIC) || prefix.starts_with(RELAY_MAGIC))
        && prefix.get(5).is_some_and(|f| f & 1 != 0)
}

impl SrsCore {
    /// 这个位置本机是否见过加密：`{"sealed": bool, "kdf": 最近见到的 kdf 或 null}`。
    pub fn sync2_location_sealed(&self, profile: &str, location: &str) -> Result<Value, String> {
        self.read_visible(|c| {
            let rec = record(c, profile, location)?;
            let progressed = rec.is_none() && progressed_sealed(c, profile, location)?;
            Ok(answer(rec.as_ref(), progressed))
        })
    }

    /// 记下「这个位置是加密的」：[kdf] = 这一刻见到的 kdf（位置的 `meta.json` 上的，或本机密钥的）；[seen] = 调用方另有
    /// 证据（`meta.json` 上有 `kdf` 但参数认不出、位置上有密封媒体目录）；[prefixes] = 从位置上读到的段 / 转发件的开头
    /// 几个字节（任一对这个位置是密封的就算见过）。都不成立时什么都不写。已记的 kdf 只在见到不同的 kdf 时更新（另一台
    /// 设备换了口令）；只从旁证看到时不抹掉已记的 kdf。返回同 [Self::sync2_location_sealed]。
    pub fn sync2_location_seal(
        &self,
        profile: &str,
        location: &str,
        kdf: Option<&Value>,
        seen: bool,
        prefixes: &[Vec<u8>],
        now: i64,
    ) -> Result<Value, String> {
        if let Some(k) = kdf {
            if !k.is_object() || k.to_string().len() > KDF_MAX_BYTES {
                return Err("location_seal: bad kdf".into());
            }
        }
        if kdf.is_none() && !seen && !prefixes.iter().any(|p| sealed_at_location(p)) {
            return self.sync2_location_sealed(profile, location);
        }
        let k = key(profile, location);
        let cur = self.read_visible(|c| record(c, profile, location))?;
        let next_kdf = kdf
            .cloned()
            .or_else(|| cur.as_ref().and_then(|v| v.get("kdf").cloned()))
            .unwrap_or(Value::Null);
        if let Some(v) = cur.as_ref() {
            if v.get("kdf").unwrap_or(&Value::Null) == &next_kdf {
                return Ok(answer(Some(v), false));
            }
        }
        let at = cur
            .as_ref()
            .and_then(|v| v.get("at").and_then(Value::as_i64))
            .unwrap_or(now);
        let rec = json!({"at": at, "kdf": next_kdf});
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            c.prepare_cached(
                "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            )
            .map_err(sql)?
            .execute(params![k, rec.to_string()])
            .map_err(sql)?;
            Ok(())
        })?;
        Ok(answer(Some(&rec), false))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::sync2::tests::{P, tempdir};

    fn open(tag: &str) -> (SrsCore, tempdir::Dir) {
        let dir = tempdir::new(tag);
        let core = SrsCore::open(&dir.0.join("srs.db")).unwrap();
        (core, dir)
    }

    #[test]
    fn prefix_flags_decide_sealed_for_the_location() {
        assert!(sealed_at_location(b"FSG2\x01\x01rest"));
        assert!(!sealed_at_location(b"FSG2\x01\x00rest"));
        assert!(sealed_at_location(b"FSRL\x01\x01"));
        assert!(!sealed_at_location(b"FSRL\x01\x00"));
        assert!(!sealed_at_location(b"FSG2\x01"));
        assert!(!sealed_at_location(b"XXXX\x01\x01"));
    }

    #[test]
    fn seal_is_sticky_and_keeps_known_kdf() {
        let (core, _dir) = open("sealed-sticky");
        let loc = "folder:a";
        assert_eq!(core.sync2_location_sealed(P, loc).unwrap()["sealed"], false);
        // 只有明文段：不记。
        let plain = core
            .sync2_location_seal(P, loc, None, false, &[b"FSG2\x01\x00".to_vec()], 1)
            .unwrap();
        assert_eq!(plain["sealed"], false);
        let kdf = json!({"alg": "argon2id", "salt": "00", "check": "c1"});
        let r = core
            .sync2_location_seal(P, loc, Some(&kdf), false, &[], 2)
            .unwrap();
        assert_eq!(r["sealed"], true);
        assert_eq!(r["kdf"], kdf);
        // 之后只从段看到：kdf 不被抹掉。
        let r = core
            .sync2_location_seal(P, loc, None, false, &[b"FSG2\x01\x01".to_vec()], 3)
            .unwrap();
        assert_eq!(r["kdf"], kdf);
        let got = core.sync2_location_sealed(P, loc).unwrap();
        assert_eq!(got["sealed"], true);
        assert_eq!(got["kdf"], kdf);
        // 别的位置不受影响（前缀相同也不算）。
        assert_eq!(
            core.sync2_location_sealed(P, "folder:ab").unwrap()["sealed"],
            false
        );
        assert_eq!(
            core.sync2_location_sealed(P, "folder").unwrap()["sealed"],
            false
        );
        // 只有旁证（媒体目录 / 认不出的 kdf）：记下，kdf 未知。
        let r = core
            .sync2_location_seal(P, "folder:b", None, true, &[], 4)
            .unwrap();
        assert_eq!(r["sealed"], true);
        assert_eq!(r["kdf"], Value::Null);
    }

    #[test]
    fn encrypted_upload_progress_counts_as_sealed() {
        let (core, _dir) = open("sealed-progress");
        core.writer()
            .unwrap()
            .execute(
                "INSERT INTO sync2_locations (profile_uid, location, uploaded) VALUES (srs_id(?1), 'folder:a#e0011', 3)",
                [P],
            )
            .unwrap();
        assert_eq!(
            core.sync2_location_sealed(P, "folder:a").unwrap()["sealed"],
            true
        );
        assert_eq!(
            core.sync2_location_sealed(P, "folder:").unwrap()["sealed"],
            false
        );
    }
}
