//! 本机 head 声明的 `minReader`（按内容，sync2/min_reader.rs）在 srs.db 上的记账。
//!
//! 值 = max([CONTENT_FLOOR], 本机写过的每条操作要求的版本, 本机收下的别的设备 head 的 `minReader`)，只增不减，存在
//! `srs_meta` 的 `sync2_min_reader/<profile>`。等于地板值时不写键（今天所有内容都是 3：这张表不产生任何写入）。
//!
//! 为什么要把别的设备的声明也算进来（传递）：A 的操作依赖 C 的新内容（`deps` 里有 C 的 seq），读者看得到 A 的 head、
//! 看不到 C 的（C 的 head 在别的位置、或 C 已停用——停用设备在 `deps_ready` 里视为已满足），只按 A 自己的内容声明，
//! 旧读者就会收下 A、缺着 C 的语义投影，或者让 A 的操作在待投递里无限堆积。代价为零：只要集合里有一台设备用了新内容，
//! 旧读者本来就会因为那台设备的 head 整轮停下。
//!
//! 换身份（分叉收尾）、快照恢复不清这个键：集合里的内容没变，声明不该变低。删 profile 时随 `…/<uid>` 键一起删。

use rusqlite::{Connection, OptionalExtension, params};

use crate::store::sync2::sql;
use crate::sync2::segment::{CONTENT_FLOOR, PROTOCOL};

fn key(profile: &str) -> String {
    format!("sync2_min_reader/{profile}")
}

/// 本机 head 该写的 `minReader`。
pub(crate) fn declared(c: &Connection, profile: &str) -> Result<u32, String> {
    let v: Option<String> = c
        .prepare_cached("SELECT value FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .query_row([key(profile)], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    let stored = v.and_then(|s| s.parse::<u32>().ok()).unwrap_or(0);
    Ok(stored.max(CONTENT_FLOOR))
}

/// 把声明抬到至少 [v]。[v] 不超过 [cap]（本版本的协议）：本机写出了本版本自己都不认识的内容是内核 bug，直接报错，
/// 不让它悄悄把集合里所有设备（包括本机）停下。
fn raise_capped(c: &Connection, profile: &str, v: u32, cap: u32) -> Result<(), String> {
    if v <= CONTENT_FLOOR {
        return Ok(());
    }
    if v > cap {
        return Err(format!(
            "sync2 min reader: content needs reader {v}, newer than this version ({cap})"
        ));
    }
    c.prepare_cached(
        "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
         ON CONFLICT(key) DO UPDATE SET value = excluded.value \
         WHERE CAST(srs_meta.value AS INTEGER) < CAST(excluded.value AS INTEGER)",
    )
    .map_err(sql)?
    .execute(params![key(profile), v.to_string()])
    .map_err(sql)?;
    Ok(())
}

/// 本机写了一条要求读者 [v] 的操作，或收下了一份声明 [v] 的 head。
pub(crate) fn raise(c: &Connection, profile: &str, v: u32) -> Result<(), String> {
    raise_capped(c, profile, v, PROTOCOL)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch("CREATE TABLE srs_meta (key TEXT PRIMARY KEY, value TEXT)")
            .unwrap();
        c
    }

    #[test]
    fn floor_content_writes_nothing() {
        let c = db();
        raise(&c, "p", CONTENT_FLOOR).unwrap();
        raise(&c, "p", 2).unwrap();
        let n: i64 = c
            .query_row("SELECT COUNT(*) FROM srs_meta", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 0);
        assert_eq!(declared(&c, "p").unwrap(), CONTENT_FLOOR);
    }

    #[test]
    fn declaration_only_grows_and_never_drops_below_the_floor() {
        // 本版本协议是 3，产生不了 > 3 的声明；按将来的协议上限演练「只增不减」。
        let c = db();
        raise_capped(&c, "p", 5, 9).unwrap();
        raise_capped(&c, "p", 4, 9).unwrap();
        raise_capped(&c, "p", 3, 9).unwrap();
        assert_eq!(declared(&c, "p").unwrap(), 5);
        raise_capped(&c, "p", 7, 9).unwrap();
        assert_eq!(declared(&c, "p").unwrap(), 7);
        assert_eq!(declared(&c, "q").unwrap(), CONTENT_FLOOR);
        // 键里是比地板值低的旧值 / 坏值：按地板值。
        c.execute(
            "INSERT INTO srs_meta VALUES ('sync2_min_reader/r', '2'), ('sync2_min_reader/s', 'x')",
            [],
        )
        .unwrap();
        assert_eq!(declared(&c, "r").unwrap(), CONTENT_FLOOR);
        assert_eq!(declared(&c, "s").unwrap(), CONTENT_FLOOR);
    }

    #[test]
    fn content_newer_than_this_version_is_an_error_not_a_silent_stop() {
        let c = db();
        assert!(raise(&c, "p", PROTOCOL + 1).is_err());
        assert_eq!(declared(&c, "p").unwrap(), CONTENT_FLOOR);
    }
}
