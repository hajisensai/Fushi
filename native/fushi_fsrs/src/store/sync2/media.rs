//! 各存储位置媒体目录的内容，记在操作日志里（设计 §6.4，`Body::MediaAt`）。
//!
//! 媒体对账以前每轮都把位置上的媒体目录整个列一遍：一个重度用户四万个媒体，网盘按页列要几十个请求、几分钟，
//! 而且它在全局同步锁里跑，书同步只能干等。现在「远端有什么」是日志的投影：
//!
//! - 设备把媒体传上 / 拉下某位置、或确认它在那里后，追加一条 `MediaAt{location, PRESENT, names}`；读取时确认
//!   不在（被外部删掉、网盘丢了）追加一条不带 PRESENT 的。每个（位置, 名字）按 HLC 大者胜。
//! - 位置上第一次对账（日志里还没有任何设备对它列举过）时列一次目录，结果带 SEEDED 标志写进日志；之后**所有**
//!   设备对这个位置只看投影、只对投影里没有的名字逐个查。
//!
//! 投影是日志的函数：同一批操作在每台设备上得到同一张表，与到达顺序无关。

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use crate::sync2::op::{Body, Op, MEDIA_AT_MAX_NAMES, MEDIA_AT_PRESENT, MEDIA_AT_SEEDED};

use super::{append_local, applied_vv, in_savepoint, mvr, sql, Local, Touched};
use crate::store::SrsCore;

/// 把一条 `MediaAt` 落进投影。每个（位置, 名字）是一个「因果优先、并发才比 HLC」的寄存器（mvr.rs）：看过「在」
/// 之后才记的「不在」（或反过来）一定生效，与两台设备的时钟谁快无关。
pub(crate) fn project_media_at(conn: &Connection, profile: &str, op: &Op, location: &str, flags: u8, names: &[String]) -> Result<(), String> {
    let present = flags & MEDIA_AT_PRESENT != 0;
    for name in names {
        let win = mvr::write(conn, profile, &mvr::reg("a", &[location, name]), op)?;
        let p = if win.id == op.id { Some(present) } else { None };
        land_media_at(conn, profile, location, name, &win, p)?;
    }
    if flags & MEDIA_AT_SEEDED != 0 {
        conn.prepare_cached(
            "INSERT INTO sync2_media_seeded (profile_uid, location, wall) VALUES (?1, ?2, ?3) \
             ON CONFLICT(profile_uid, location) DO UPDATE SET wall = MAX(wall, excluded.wall)",
        )
        .map_err(sql)?
        .execute(params![profile, location, op.hlc.wall])
        .map_err(sql)?;
    }
    Ok(())
}

/// `sync2_media_at` 的一行落到寄存器的当前值 [win]（[present] = 它的在 / 不在，没给就从日志读）；相同就不写。
pub(crate) fn land_media_at(conn: &Connection, profile: &str, location: &str, name: &str, win: &mvr::Write, present: Option<bool>) -> Result<(), String> {
    let cur: Option<(i64, i64, Vec<u8>)> = conn
        .prepare_cached("SELECT wall, logical, device FROM sync2_media_at WHERE profile_uid = ?1 AND location = ?2 AND name = ?3")
        .map_err(sql)?
        .query_row(params![profile, location, name], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()
        .map_err(sql)?;
    if cur.as_ref().is_some_and(|(w, l, d)| (*w, *l, d.as_slice()) == (win.wall, win.logical, &win.id.device.0[..])) {
        return Ok(());
    }
    let present = match present {
        Some(p) => p,
        None => match super::load_op(conn, profile, &win.id)?.and_then(|o| o.body().ok()) {
            Some(Body::MediaAt { flags, .. }) => flags & MEDIA_AT_PRESENT != 0,
            _ => return Ok(()),
        },
    };
    conn.prepare_cached(
        "INSERT OR REPLACE INTO sync2_media_at (profile_uid, location, name, present, wall, logical, device) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    )
    .map_err(sql)?
    .execute(params![profile, location, name, i64::from(present), win.wall, win.logical, win.id.device.0.to_vec()])
    .map_err(sql)?;
    Ok(())
}

/// 投影里此刻与 [present] 不一致的名字（去重、保持首见顺序）。一样的不再写，免得每轮对账都往日志里灌重复事实。
fn changed(conn: &Connection, profile: &str, location: &str, names: &[String], present: bool) -> Result<Vec<String>, String> {
    let mut stmt =
        conn.prepare_cached("SELECT present FROM sync2_media_at WHERE profile_uid = ?1 AND location = ?2 AND name = ?3").map_err(sql)?;
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for n in names {
        if n.is_empty() || !seen.insert(n.as_str()) {
            continue;
        }
        let cur: Option<i64> = stmt.query_row(params![profile, location, n], |r| r.get(0)).optional().map_err(sql)?;
        if cur != Some(i64::from(present)) {
            out.push(n.clone());
        }
    }
    Ok(out)
}

fn is_seeded(conn: &Connection, profile: &str, location: &str) -> Result<bool, String> {
    Ok(conn
        .prepare_cached("SELECT 1 FROM sync2_media_seeded WHERE profile_uid = ?1 AND location = ?2")
        .map_err(sql)?
        .query_row(params![profile, location], |_| Ok(()))
        .optional()
        .map_err(sql)?
        .is_some())
}

impl SrsCore {
    /// 某位置媒体目录的已知内容：`{"seeded": bool, "present": [名字…], "absent": [名字…]}`。`seeded` 为假 = 日志里
    /// 还没有任何设备对它完整列举过，调用方要先列一次再 [SrsCore::sync2_media_record] 带 `seeded`。`absent` 是确认过
    /// 不在的（不必再逐个查）；两边都没有的名字 = 未知。
    pub fn sync2_media_known(&self, profile: &str, location: &str) -> Result<Value, String> {
        let r = self.reader()?;
        let mut present = Vec::new();
        let mut absent = Vec::new();
        let mut stmt = r
            .prepare("SELECT name, present FROM sync2_media_at WHERE profile_uid = ?1 AND location = ?2 ORDER BY name")
            .map_err(sql)?;
        let rows = stmt.query_map(params![profile, location], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))).map_err(sql)?;
        for row in rows {
            let (name, p) = row.map_err(sql)?;
            if p != 0 {
                present.push(name);
            } else {
                absent.push(name);
            }
        }
        Ok(json!({"seeded": is_seeded(&r, profile, location)?, "present": present, "absent": absent}))
    }

    /// 记下某位置媒体目录的事实：[present] 在、[absent] 不在；[seeded] = 这是一次完整列举的结果。只写与投影
    /// 不一致的名字（一样的不重复记），按 [MEDIA_AT_MAX_NAMES] 切成多条操作。返回 `{"appended": 条数}`。
    pub fn sync2_media_record(
        &self,
        profile: &str,
        location: &str,
        present: &[String],
        absent: &[String],
        seeded: bool,
        now: i64,
    ) -> Result<Value, String> {
        if location.is_empty() {
            return Err("media_record: empty location".into());
        }
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let mut bodies = Vec::new();
            for (names, flag) in [(present, MEDIA_AT_PRESENT), (absent, 0)] {
                let todo = changed(c, profile, location, names, flag != 0)?;
                for chunk in todo.chunks(MEDIA_AT_MAX_NAMES) {
                    bodies.push(Body::MediaAt { location: location.to_owned(), flags: flag, names: chunk.to_vec() });
                }
            }
            if seeded && !is_seeded(c, profile, location)? {
                // 列举标记放在最后一条：读到它的设备也已读到同一作者此前的各批（同设备按 seq 连续应用）。
                bodies.push(Body::MediaAt { location: location.to_owned(), flags: MEDIA_AT_PRESENT | MEDIA_AT_SEEDED, names: Vec::new() });
            }
            if bodies.is_empty() {
                return Ok(json!({"appended": 0}));
            }
            let mut local = match Local::load(c, profile)? {
                Some(l) => l,
                None => Local::create(c, profile, now)?,
            };
            let mut applied = applied_vv(c, profile)?;
            let mut t = Touched::default();
            for b in &bodies {
                let op = append_local(c, &mut local, &mut applied, b, now)?;
                super::project(c, profile, &op, now, true, &mut t)?;
            }
            local.save(c)?;
            Ok(json!({"appended": bodies.len()}))
        })
    }
}
