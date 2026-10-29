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

use crate::sync2::op::{Body, Op, MEDIA_AT_MAX_NAMES, MEDIA_AT_PRESENT, MEDIA_AT_SEEDED, MEDIA_AT_SUSPECT};

/// `sync2_media_at.present` 的取值：不在 / 在 / 在但可疑（[MEDIA_AT_SUSPECT]）。
const AT_ABSENT: i64 = 0;
const AT_PRESENT: i64 = 1;
const AT_SUSPECT: i64 = 2;

/// 一条 `MediaAt` 的标志位对应的投影值。
fn at_state(flags: u8) -> i64 {
    if flags & MEDIA_AT_PRESENT != 0 {
        AT_PRESENT
    } else if flags & MEDIA_AT_SUSPECT != 0 {
        AT_SUSPECT
    } else {
        AT_ABSENT
    }
}

use super::{append_local, applied_vv, in_savepoint, mvr, sql, Local, Touched};
use crate::store::SrsCore;

/// 把一条 `MediaAt` 落进投影。每个（位置, 名字）是一个「因果优先、并发才比 HLC」的寄存器（mvr.rs）：看过「在」
/// 之后才记的「不在」（或反过来）一定生效，与两台设备的时钟谁快无关。
pub(crate) fn project_media_at(conn: &Connection, profile: &str, op: &Op, location: &str, flags: u8, names: &[String]) -> Result<(), String> {
    let state = at_state(flags);
    for name in names {
        let win = mvr::write(conn, profile, &mvr::reg("a", &[location, name]), op)?;
        let p = if win.id == op.id { Some(state) } else { None };
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

/// `sync2_media_at` 的一行落到寄存器的当前值 [win]（[present] = 它的在 / 不在 / 可疑（[at_state]），没给就从日志读）；
/// 相同就不写。
pub(crate) fn land_media_at(conn: &Connection, profile: &str, location: &str, name: &str, win: &mvr::Write, present: Option<i64>) -> Result<(), String> {
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
            Some(Body::MediaAt { flags, .. }) => at_state(flags),
            _ => return Ok(()),
        },
    };
    conn.prepare_cached(
        "INSERT OR REPLACE INTO sync2_media_at (profile_uid, location, name, present, wall, logical, device) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    )
    .map_err(sql)?
    .execute(params![profile, location, name, present, win.wall, win.logical, win.id.device.0.to_vec()])
    .map_err(sql)?;
    Ok(())
}

/// 投影里此刻与 [present]（[at_state] 的取值）不一致的名字（去重、保持首见顺序）。一样的不再写，免得每轮对账都往
/// 日志里灌重复事实。
fn changed(conn: &Connection, profile: &str, location: &str, names: &[String], present: i64) -> Result<Vec<String>, String> {
    let mut stmt =
        conn.prepare_cached("SELECT present FROM sync2_media_at WHERE profile_uid = ?1 AND location = ?2 AND name = ?3").map_err(sql)?;
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for n in names {
        if n.is_empty() || !seen.insert(n.as_str()) {
            continue;
        }
        let cur: Option<i64> = stmt.query_row(params![profile, location, n], |r| r.get(0)).optional().map_err(sql)?;
        if cur != Some(present) {
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
    /// 某位置媒体目录的已知内容：`{"seeded": bool, "present": [名字…], "absent": [名字…], "suspect": [名字…]}`。
    /// `seeded` 为假 = 日志里还没有任何设备对它完整列举过，调用方要先列一次再 [SrsCore::sync2_media_record] 带 `seeded`。
    /// `absent` 是确认过不在的（不必再逐个查）；`suspect` 是在、但有设备下载到的内容与名字对不上的（[MEDIA_AT_SUSPECT]）；
    /// 都没有的名字 = 未知。
    pub fn sync2_media_known(&self, profile: &str, location: &str) -> Result<Value, String> {
        let r = self.reader()?;
        let mut present = Vec::new();
        let mut absent = Vec::new();
        let mut suspect = Vec::new();
        let mut stmt = r
            .prepare("SELECT name, present FROM sync2_media_at WHERE profile_uid = ?1 AND location = ?2 ORDER BY name")
            .map_err(sql)?;
        let rows = stmt.query_map(params![profile, location], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))).map_err(sql)?;
        for row in rows {
            let (name, p) = row.map_err(sql)?;
            match p {
                AT_PRESENT => present.push(name),
                AT_SUSPECT => suspect.push(name),
                _ => absent.push(name),
            }
        }
        Ok(json!({"seeded": is_seeded(&r, profile, location)?, "present": present, "absent": absent, "suspect": suspect}))
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
        self.sync2_media_record_with_suspect(profile, location, present, absent, &[], seeded, now)
    }

    /// 同 [SrsCore::sync2_media_record]，另记 [suspect]：在、但下载到的内容与名字对不上（[MEDIA_AT_SUSPECT]）。
    #[allow(clippy::too_many_arguments)]
    pub fn sync2_media_record_with_suspect(
        &self,
        profile: &str,
        location: &str,
        present: &[String],
        absent: &[String],
        suspect: &[String],
        seeded: bool,
        now: i64,
    ) -> Result<Value, String> {
        if location.is_empty() {
            return Err("media_record: empty location".into());
        }
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let mut bodies = Vec::new();
            for (names, flag) in [(present, MEDIA_AT_PRESENT), (absent, 0), (suspect, MEDIA_AT_SUSPECT)] {
                let todo = changed(c, profile, location, names, at_state(flag))?;
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

// ---------------------------------------------------------------------------------------------------------------
// 内容寻址媒体（设计 §6.1 / §6.4，审查 S-3）：位置上的媒体按内容存 `media/<sha256 前 2 位>/<sha256>`（不可变），本机文件名
// 经日志里的绑定（`Body::Media{name, sha256, size}`，`sync2_media`）映射到内容。以前按名字存 `media/<name>`、下载不校验：
// 两台设备各有一个同名不同内容的 `image.jpg` 时各留各的、永远分叉；云盘覆盖写的半截文件被当成本机文件永久留下。
//
// 每个名字的绑定是「因果优先、并发才比 HLC」的寄存器（mvr.rs）。本机怎么对齐（[SrsCore::sync2_media_scan]）：
// - 本机有文件、内容 L：没有绑定 → 绑 L；绑定就是 L → 无事；绑定是别的内容 B 而本机上次对齐后文件没变过（`synced == L`）
//   → 别的设备后来改了绑定，下载 B 换掉本机文件；文件改过（或从没对齐过）→ 本机这次改动是新写，绑 L（它看过 B，因果上盖过 B）。
// - 本机没有文件：有绑定 → 下载绑定的内容（校验 sha256）；没有绑定 → 只能从旧格式（按名字存的）兜底，下载后再绑。
// ---------------------------------------------------------------------------------------------------------------

/// 一个本机媒体文件此刻的 (size, mtime 毫秒)；不在 / 不是普通文件 = None。
fn stat_file(path: &std::path::Path) -> Option<(i64, i64)> {
    let m = std::fs::metadata(path).ok()?;
    if !m.is_file() {
        return None;
    }
    let mtime = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_millis() as i64);
    Some((m.len() as i64, mtime))
}

/// 文件内容的 sha256（按块读，不整个读进内存）。
fn sha256_file(path: &std::path::Path) -> Result<[u8; 32], String> {
    use sha2::Digest;
    use std::io::Read;
    let mut f = std::fs::File::open(path).map_err(|e| format!("media: open {}: {e}", path.display()))?;
    let mut h = sha2::Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = f.read(&mut buf).map_err(|e| format!("media: read {}: {e}", path.display()))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(h.finalize().into())
}

fn hex32(b: &[u8; 32]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// 64 位十六进制 → 32 字节。
pub(crate) fn unhex32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, o) in out.iter_mut().enumerate() {
        *o = u8::from_str_radix(s.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

/// 本机记的一个媒体文件：(size, mtime, 内容, 上次与绑定对齐时的内容)。
type LocalRow = (i64, i64, [u8; 32], Option<[u8; 32]>);

fn local_row(c: &Connection, profile: &str, name: &str) -> Result<Option<LocalRow>, String> {
    let row: Option<(i64, i64, Vec<u8>, Option<Vec<u8>>)> = c
        .prepare_cached("SELECT size, mtime, sha256, synced FROM sync2_media_local WHERE profile_uid = ?1 AND name = ?2")
        .map_err(sql)?
        .query_row(params![profile, name], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .optional()
        .map_err(sql)?;
    Ok(row.and_then(|(size, mtime, sha, synced)| {
        let sha: [u8; 32] = sha.try_into().ok()?;
        Some((size, mtime, sha, synced.and_then(|s| s.try_into().ok())))
    }))
}

fn put_local_row(c: &Connection, profile: &str, name: &str, row: &LocalRow) -> Result<(), String> {
    c.prepare_cached(
        "INSERT OR REPLACE INTO sync2_media_local (profile_uid, name, size, mtime, sha256, synced) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .map_err(sql)?
    .execute(params![profile, name, row.0, row.1, row.2.to_vec(), row.3.map(|s| s.to_vec())])
    .map_err(sql)?;
    Ok(())
}

/// 名字此刻绑定的内容 (sha256, size)。
fn binding(c: &Connection, profile: &str, name: &str) -> Result<Option<([u8; 32], i64)>, String> {
    let row: Option<(Vec<u8>, i64)> = c
        .prepare_cached("SELECT sha256, size FROM sync2_media WHERE profile_uid = ?1 AND name = ?2")
        .map_err(sql)?
        .query_row(params![profile, name], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
        .map_err(sql)?;
    Ok(row.and_then(|(sha, size)| Some((sha.try_into().ok()?, size))))
}

/// 在一个写事务里追加一批绑定（本机操作，立即投影）。
fn append_bindings(c: &Connection, profile: &str, binds: &[(String, [u8; 32], i64)], now: i64) -> Result<(), String> {
    if binds.is_empty() {
        return Ok(());
    }
    let mut local = match Local::load(c, profile)? {
        Some(l) => l,
        None => Local::create(c, profile, now)?,
    };
    let mut applied = applied_vv(c, profile)?;
    let mut t = Touched::default();
    for (name, sha, size) in binds {
        let body = Body::Media { name: name.clone(), sha256: *sha, size: (*size).max(0) as u64 };
        let op = append_local(c, &mut local, &mut applied, &body, now)?;
        super::project(c, profile, &op, now, true, &mut t)?;
    }
    local.save(c)
}

/// 本机一个媒体文件此刻的 (size, mtime, sha256)（[SrsCore::sync2_media_hash] 的结果，交回 [SrsCore::sync2_media_scan]）。
pub type LocalFile = (i64, i64, [u8; 32]);

impl SrsCore {
    /// 媒体对账的第一步（只走读连接、不进写锁：首次对账要把几万个文件各读一遍）：本机媒体目录 [root] 下 [names] 中存在的
    /// 文件此刻的 (size, mtime, sha256)。本机记过且 (size, mtime) 没变的不重算。返回 `{"files": [{"name", "size", "mtime",
    /// "sha"}…]}`（不在 / 读不了的不列）。
    pub fn sync2_media_hash(&self, profile: &str, root: &str, names: &[String]) -> Result<Value, String> {
        let root = std::path::Path::new(root);
        let cached: Vec<Option<LocalRow>> = {
            let r = self.reader()?;
            names.iter().map(|n| local_row(&r, profile, n)).collect::<Result<_, _>>()?
        };
        let mut files = Vec::new();
        for (name, row) in names.iter().zip(&cached) {
            let path = root.join(name);
            let Some((size, mtime)) = stat_file(&path) else { continue };
            let sha = match row {
                Some((s, m, sha, _)) if *s == size && *m == mtime => Some(*sha),
                // 读不了（被占用 / 刚被删）就当这一轮本机没有它。
                _ => sha256_file(&path).ok(),
            };
            if let Some(sha) = sha {
                files.push(json!({"name": name, "size": size, "mtime": mtime, "sha": hex32(&sha)}));
            }
        }
        Ok(json!({"files": files}))
    }

    /// 媒体对账的第二步（写锁里）：[names] 各自该做什么，[files] 是第一步得到的本机现有文件。需要的绑定在同一个调用里写进
    /// 日志。返回 `{"items": [{"name", "sha": 目标内容|null, "size", "have": 本机已是目标内容, "local": 本机现有内容|null}…],
    /// "appended": 新绑定数}`。
    /// `have == false && sha != null` = 去下载 `sha`（若 `local` 还不在位置上，先把它传上去，免得被换掉的本机内容只此一份）；
    /// `sha == null` = 没有绑定、本机也没有（只能从旧格式兜底）。
    pub fn sync2_media_scan(
        &self,
        profile: &str,
        names: &[String],
        files: &std::collections::HashMap<String, LocalFile>,
        now: i64,
    ) -> Result<Value, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let mut items = Vec::with_capacity(names.len());
            let mut binds: Vec<(String, [u8; 32], i64)> = Vec::new();
            for name in names {
                let bound = binding(c, profile, name)?;
                let Some(&(size, mtime, l)) = files.get(name) else {
                    items.push(match bound {
                        Some((sha, size)) => json!({"name": name, "sha": hex32(&sha), "size": size, "have": false, "local": null}),
                        None => json!({"name": name, "sha": null, "size": 0, "have": false, "local": null}),
                    });
                    continue;
                };
                let row = local_row(c, profile, name)?;
                let synced = row.as_ref().and_then(|r| r.3);
                let (target, tsize, have, synced) = match bound {
                    Some((b, _)) if b == l => (l, size, true, Some(l)),
                    Some((b, bsize)) if synced == Some(l) => (b, bsize, false, synced),
                    _ => {
                        binds.push((name.clone(), l, size));
                        (l, size, true, Some(l))
                    }
                };
                let new_row: LocalRow = (size, mtime, l, synced);
                if row.as_ref() != Some(&new_row) {
                    put_local_row(c, profile, name, &new_row)?;
                }
                items.push(json!({"name": name, "sha": hex32(&target), "size": tsize, "have": have, "local": hex32(&l)}));
            }
            append_bindings(c, profile, &binds, now)?;
            Ok(json!({"items": items, "appended": binds.len()}))
        })
    }

    /// 下载落地之后：[items]（名字, 写进本机的内容，调用方已校验过 sha256）已在 [root] 下。记成「本机已与绑定对齐」（记下此刻
    /// 的 size / mtime，下一轮不重算）；名字还没有绑定（旧格式兜底下来的）就绑上。文件已经不在的不记。返回 `{"appended": n}`。
    pub fn sync2_media_landed(&self, profile: &str, root: &str, items: &[(String, [u8; 32])], now: i64) -> Result<Value, String> {
        let root = std::path::Path::new(root);
        let mut rows: Vec<(String, LocalRow)> = Vec::new();
        for (name, sha) in items {
            let Some((size, mtime)) = stat_file(&root.join(name)) else { continue };
            rows.push((name.clone(), (size, mtime, *sha, Some(*sha))));
        }
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let mut binds = Vec::new();
            for (name, row) in &rows {
                put_local_row(c, profile, name, row)?;
                if binding(c, profile, name)?.is_none() {
                    binds.push((name.clone(), row.2, row.0));
                }
            }
            append_bindings(c, profile, &binds, now)?;
            Ok(json!({"appended": binds.len()}))
        })
    }

    /// 位置清理用：[expired]（只被删除已满保留期的笔记引用的名字）绑定的内容里，不被 [live]（存活引用）任何一个名字绑定的
    /// 那些。返回 `{"sha": [十六进制…]}`。
    pub fn sync2_media_doomed(&self, profile: &str, expired: &[String], live: &[String]) -> Result<Value, String> {
        let r = self.reader()?;
        let mut keep = std::collections::HashSet::new();
        for n in live {
            if let Some((sha, _)) = binding(&r, profile, n)? {
                keep.insert(sha);
            }
        }
        let mut out = std::collections::BTreeSet::new();
        for n in expired {
            if let Some((sha, _)) = binding(&r, profile, n)? {
                if !keep.contains(&sha) {
                    out.insert(hex32(&sha));
                }
            }
        }
        Ok(json!({"sha": out.into_iter().collect::<Vec<_>>()}))
    }
}
