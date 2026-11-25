//! 升级前「还原点」快照：在改动 `srs4.db` 之前用 `VACUUM INTO` 留一份可回滚的副本。
//!
//! 磁盘格式与 Dart 侧（fushi_core 对 `fushi.db` 的同名机制）共用，两个库在同一目录：
//! - 目录：`<库文件所在目录>/restore_points/`；
//! - 一个还原点 = 一个子目录，id = `<UTC yyyyMMdd-HHmmss-SSS>-<database>-<kind>`，
//!   重名时追加 `-2`、`-3`……；
//! - 目录内：与活库同名的快照文件 + 最后写入的 `restore_point.json`（存在即完整）；
//! - 状态文件：`<restore_points>/last_snapshot_status.<database>.json`，每次尝试后写。
//!
//! 快照失败只记录、不阻断打开库：调用方拿到 `Err` 后应继续。

#[cfg(test)]
use std::cell::Cell;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};

/// 还原点仓库目录名（位于库文件同级）。
pub const STORE_DIR: &str = "restore_points";
/// 完整性标记文件名；最后写入。
pub const META_FILE: &str = "restore_point.json";
/// 元数据临时文件名（写完改名为 [`META_FILE`]）。
pub const META_TMP: &str = "restore_point.json.tmp";
/// 本库在还原点 id / 状态文件里的库标识。
pub const DATABASE: &str = "srs";
/// `pre_update` 类还原点保留份数。
pub const KEEP_PRE_UPDATE: usize = 3;
/// 元数据 / 状态文件格式版本。
pub const FORMAT: i64 = 1;

/// 还原点种类（只有 `PreUpdate` 在这里创建，其余与 Dart 侧对齐）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    PreUpdate,
    PreRollback,
    Scheduled,
    Forced,
}

impl Kind {
    /// 写进 id 与元数据的字符串。
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::PreUpdate => "pre_update",
            Kind::PreRollback => "pre_rollback",
            Kind::Scheduled => "scheduled",
            Kind::Forced => "forced",
        }
    }
}

/// 还原点内的单个文件。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileEntry {
    pub name: String,
    pub size: u64,
}

/// `restore_point.json` 的内容。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PointMeta {
    pub format: i64,
    pub kind: String,
    pub database: String,
    pub created_at_ms: i64,
    pub from_schema: i64,
    pub to_schema: i64,
    pub app_version: Option<String>,
    pub files: Vec<FileEntry>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Status<'a> {
    format: i64,
    database: &'a str,
    ok: bool,
    at_ms: i64,
    from_schema: i64,
    to_schema: i64,
    point_id: Option<&'a str>,
    error: Option<&'a str>,
    acknowledged: bool,
}

#[cfg(test)]
thread_local! {
    /// 测试钩子：为 true 时在 `VACUUM INTO` 写出副本后强制失败。
    static FORCE_FAIL_AFTER_VACUUM: Cell<bool> = const { Cell::new(false) };
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 毫秒时间戳 → `yyyyMMdd-HHmmss-SSS`（UTC，civil-from-days 算法）。
pub fn format_timestamp(ms: i64) -> String {
    let days = ms.div_euclid(86_400_000);
    let rem = ms.rem_euclid(86_400_000);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let mut y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    if m <= 2 {
        y += 1;
    }
    format!(
        "{y:04}{m:02}{d:02}-{:02}{:02}{:02}-{:03}",
        rem / 3_600_000,
        rem / 60_000 % 60,
        rem / 1000 % 60,
        rem % 1000
    )
}

/// 取一个未被占用的还原点 id（重名追加 `-2`、`-3`……）。
fn unique_id(store: &Path, ms: i64, kind: Kind) -> String {
    let base = format!("{}-{DATABASE}-{}", format_timestamp(ms), kind.as_str());
    let mut id = base.clone();
    let mut n = 2;
    while store.join(&id).exists() {
        id = format!("{base}-{n}");
        n += 1;
    }
    id
}

fn read_meta(dir: &Path) -> Option<PointMeta> {
    let text = fs::read_to_string(dir.join(META_FILE)).ok()?;
    serde_json::from_str(&text).ok()
}

fn write_atomic(dir: &Path, tmp: &str, name: &str, body: &str) -> Result<(), String> {
    let tmp_path = dir.join(tmp);
    fs::write(&tmp_path, body).map_err(|e| format!("write {tmp}: {e}"))?;
    fs::rename(&tmp_path, dir.join(name)).map_err(|e| format!("rename {tmp}: {e}"))
}

/// 列出 `database` 的完整还原点（有可解析的元数据），新的在前。
pub fn list(store_dir: &Path, database: &str) -> Vec<(String, PointMeta)> {
    let Ok(rd) = fs::read_dir(store_dir) else {
        return Vec::new();
    };
    let mut out: Vec<(String, PointMeta)> = rd
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .filter_map(|e| {
            let id = e.file_name().to_string_lossy().into_owned();
            let meta = read_meta(&e.path())?;
            (meta.database == database).then_some((id, meta))
        })
        .collect();
    out.sort_by(|a, b| (b.1.created_at_ms, &b.0).cmp(&(a.1.created_at_ms, &a.0)));
    out
}

/// id 是否形如 `*-srs-pre_update` 或 `*-srs-pre_update-<n>`。
fn is_srs_pre_update(id: &str) -> bool {
    let tag = format!("-{DATABASE}-{}", Kind::PreUpdate.as_str());
    match id.rfind(&tag) {
        None => false,
        Some(i) => {
            let rest = &id[i + tag.len()..];
            rest.is_empty()
                || rest
                    .strip_prefix("-")
                    .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
        }
    }
}

/// 保留策略：pre_update 留最新 [`KEEP_PRE_UPDATE`] 份；清掉本库未写完的目录。
/// 不碰其他库（如 `-fushi-`）与未知名字的目录。
fn apply_retention(store: &Path, just_created: &str) {
    let Ok(rd) = fs::read_dir(store) else { return };
    let marker = format!("-{DATABASE}-");
    let mut complete: Vec<(i64, String)> = Vec::new();
    for e in rd.filter_map(|e| e.ok()) {
        let path = e.path();
        if !path.is_dir() {
            continue;
        }
        let id = e.file_name().to_string_lossy().into_owned();
        let meta = read_meta(&path);
        match meta {
            None => {
                if id != just_created && id.contains(&marker) {
                    let _ = fs::remove_dir_all(&path);
                }
            }
            Some(m) => {
                if is_srs_pre_update(&id) {
                    complete.push((m.created_at_ms, id));
                }
            }
        }
    }
    complete.sort_by(|a, b| b.cmp(a));
    for (_, id) in complete.into_iter().skip(KEEP_PRE_UPDATE) {
        let _ = fs::remove_dir_all(store.join(id));
    }
}

fn create_point(
    store: &Path,
    db_path: &Path,
    from_schema: i64,
    to_schema: i64,
    app_version: Option<&str>,
    id: &str,
    ms: i64,
) -> Result<(), String> {
    let name = db_path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| "bad db path".to_string())?
        .to_string();
    let dir = store.join(id);
    fs::create_dir(&dir).map_err(|e| format!("create point dir: {e}"))?;
    let copy = dir.join(&name);
    {
        let live = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|e| format!("open live db: {e}"))?;
        live.execute("VACUUM INTO ?1", [copy.to_string_lossy().as_ref()])
            .map_err(|e| format!("vacuum into: {e}"))?;
    }
    #[cfg(test)]
    if FORCE_FAIL_AFTER_VACUUM.with(|f| f.get()) {
        return Err("forced failure after vacuum".to_string());
    }
    {
        let snap = Connection::open_with_flags(&copy, OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|e| format!("open snapshot: {e}"))?;
        let mut stmt = snap
            .prepare("PRAGMA quick_check")
            .map_err(|e| format!("quick_check: {e}"))?;
        let rows: Vec<String> = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(|e| format!("quick_check: {e}"))?
            .collect::<Result<_, _>>()
            .map_err(|e| format!("quick_check: {e}"))?;
        if rows.len() != 1 || rows[0] != "ok" {
            return Err(format!("quick_check not ok: {}", rows.join("; ")));
        }
    }
    let size = fs::metadata(&copy)
        .map_err(|e| format!("stat snapshot: {e}"))?
        .len();
    let meta = PointMeta {
        format: FORMAT,
        kind: Kind::PreUpdate.as_str().to_string(),
        database: DATABASE.to_string(),
        created_at_ms: ms,
        from_schema,
        to_schema,
        app_version: app_version.map(str::to_string),
        files: vec![FileEntry { name, size }],
    };
    let body = serde_json::to_string(&meta).map_err(|e| format!("encode meta: {e}"))?;
    write_atomic(&dir, META_TMP, META_FILE, &body)
}

fn write_status(
    store: &Path,
    ok: bool,
    from_schema: i64,
    to_schema: i64,
    point_id: Option<&str>,
    error: Option<&str>,
) {
    let status = Status {
        format: FORMAT,
        database: DATABASE,
        ok,
        at_ms: now_ms(),
        from_schema,
        to_schema,
        point_id,
        error,
        acknowledged: false,
    };
    if let Ok(body) = serde_json::to_string(&status) {
        let file = format!("last_snapshot_status.{DATABASE}.json");
        let _ = write_atomic(store, &format!("{file}.tmp"), &file, &body);
    }
}

/// 升级前给 `db_path` 留一份还原点，成功返回还原点 id。
///
/// 失败已记入状态文件并清掉半成品，以 `Err(原因)` 返回；调用方应继续打开库，不得因此中止。
pub fn snapshot_before_upgrade(
    db_path: &Path,
    from_schema: i64,
    to_schema: i64,
    app_version: Option<&str>,
) -> Result<String, String> {
    let store: PathBuf = db_path
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_default()
        .join(STORE_DIR);
    if let Err(e) = fs::create_dir_all(&store) {
        let err = format!("create store dir: {e}");
        write_status(&store, false, from_schema, to_schema, None, Some(&err));
        return Err(err);
    }
    let ms = now_ms();
    let id = unique_id(&store, ms, Kind::PreUpdate);
    match create_point(
        &store,
        db_path,
        from_schema,
        to_schema,
        app_version,
        &id,
        ms,
    ) {
        Ok(()) => {
            apply_retention(&store, &id);
            write_status(&store, true, from_schema, to_schema, Some(&id), None);
            Ok(id)
        }
        Err(err) => {
            let _ = fs::remove_dir_all(store.join(&id));
            write_status(&store, false, from_schema, to_schema, None, Some(&err));
            Err(err)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "fushi_rp_{tag}_{}_{}",
            std::process::id(),
            now_ms()
        ));
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn make_db(dir: &Path, rows: i64) -> (PathBuf, Connection) {
        let p = dir.join("srs4.db");
        let c = Connection::open(&p).unwrap();
        c.pragma_update(None, "journal_mode", "WAL").unwrap();
        c.pragma_update(None, "wal_autocheckpoint", 0).unwrap();
        c.execute("CREATE TABLE t(x INTEGER)", []).unwrap();
        for i in 0..rows {
            c.execute("INSERT INTO t VALUES (?1)", [i]).unwrap();
        }
        (p, c)
    }

    fn status(store: &Path) -> serde_json::Value {
        let t = fs::read_to_string(store.join("last_snapshot_status.srs.json")).unwrap();
        serde_json::from_str(&t).unwrap()
    }

    fn fake_point(store: &Path, id: &str, db: &str, ms: i64, with_meta: bool) {
        let d = store.join(id);
        fs::create_dir_all(&d).unwrap();
        if with_meta {
            let m = PointMeta {
                format: 1,
                kind: "pre_update".into(),
                database: db.into(),
                created_at_ms: ms,
                from_schema: 1,
                to_schema: 2,
                app_version: None,
                files: vec![],
            };
            fs::write(d.join(META_FILE), serde_json::to_string(&m).unwrap()).unwrap();
        }
    }

    #[test]
    fn creates_point_from_wal_db() {
        let dir = temp_dir("create");
        let (p, live) = make_db(&dir, 50);
        assert!(dir.join("srs4.db-wal").exists());
        let id = snapshot_before_upgrade(&p, 7, 8, Some("1.2.3")).unwrap();
        let store = dir.join(STORE_DIR);
        let pts = list(&store, "srs");
        assert_eq!(pts.len(), 1);
        assert_eq!(pts[0].0, id);
        let m = &pts[0].1;
        assert_eq!((m.from_schema, m.to_schema), (7, 8));
        assert_eq!(m.kind, "pre_update");
        assert_eq!(m.app_version.as_deref(), Some("1.2.3"));
        let copy = store.join(&id).join("srs4.db");
        assert_eq!(m.files[0].name, "srs4.db");
        assert_eq!(m.files[0].size, fs::metadata(&copy).unwrap().len());
        let c = Connection::open(&copy).unwrap();
        let n: i64 = c
            .query_row("SELECT COUNT(*) FROM t", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 50);
        let raw: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(store.join(&id).join(META_FILE)).unwrap())
                .unwrap();
        assert_eq!(raw["createdAtMs"], m.created_at_ms);
        assert_eq!(raw["format"], 1);
        let s = status(&store);
        assert_eq!(s["ok"], true);
        assert_eq!(s["pointId"], id.as_str());
        assert_eq!(s["acknowledged"], false);
        assert!(s["error"].is_null());
        drop(c);
        drop(live);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn retention_keeps_newest_three_and_spares_others() {
        let dir = temp_dir("retain");
        let (p, live) = make_db(&dir, 3);
        let store = dir.join(STORE_DIR);
        fake_point(
            &store,
            "20200101-000000-000-fushi-pre_update",
            "fushi",
            1,
            true,
        );
        fake_point(&store, "somethingelse", "srs", 1, true);
        fake_point(&store, "20200101-000000-000-srs-scheduled", "srs", 1, false);
        let mut ids = Vec::new();
        for _ in 0..5 {
            ids.push(snapshot_before_upgrade(&p, 1, 2, None).unwrap());
        }
        let left: Vec<String> = list(&store, "srs")
            .into_iter()
            .filter(|(id, _)| is_srs_pre_update(id))
            .map(|(id, _)| id)
            .collect();
        assert_eq!(left.len(), 3);
        for id in &ids[2..] {
            assert!(left.contains(id), "{id} should be kept");
        }
        assert!(store.join("20200101-000000-000-fushi-pre_update").exists());
        assert!(store.join("somethingelse").exists());
        assert!(!store.join("20200101-000000-000-srs-scheduled").exists());
        drop(live);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn failure_cases_leave_nothing_behind() {
        let dir = temp_dir("fail");
        let (p, live) = make_db(&dir, 3);
        // 仓库路径被文件占用：建不了目录，状态也写不了。
        fs::write(dir.join(STORE_DIR), b"x").unwrap();
        assert!(snapshot_before_upgrade(&p, 1, 2, None).is_err());
        assert!(dir.join(STORE_DIR).is_file());
        fs::remove_file(dir.join(STORE_DIR)).unwrap();
        // 写出副本后强制失败：半成品被清掉，状态 ok=false。
        FORCE_FAIL_AFTER_VACUUM.with(|f| f.set(true));
        let r = snapshot_before_upgrade(&p, 1, 2, None);
        FORCE_FAIL_AFTER_VACUUM.with(|f| f.set(false));
        assert!(r.is_err());
        let store = dir.join(STORE_DIR);
        let dirs = fs::read_dir(&store)
            .unwrap()
            .filter(|e| e.as_ref().unwrap().path().is_dir())
            .count();
        assert_eq!(dirs, 0);
        let s = status(&store);
        assert_eq!(s["ok"], false);
        assert!(s["pointId"].is_null());
        assert!(s["error"].as_str().unwrap().contains("forced"));
        // 活库未被改动。
        let n: i64 = live
            .query_row("SELECT COUNT(*) FROM t", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 3);
        drop(live);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn id_format_sort_and_collision() {
        assert_eq!(format_timestamp(0), "19700101-000000-000");
        // 2026-11-25 14:25:30.123 UTC
        assert_eq!(format_timestamp(1_795_616_730_123), "20261125-142530-123");
        assert_eq!(format_timestamp(951_782_400_000), "20000229-000000-000");
        assert!(format_timestamp(1_000) < format_timestamp(2_000));
        assert!(is_srs_pre_update("20261125-142530-123-srs-pre_update"));
        assert!(is_srs_pre_update("20261125-142530-123-srs-pre_update-2"));
        assert!(!is_srs_pre_update("20261125-142530-123-fushi-pre_update"));
        assert!(!is_srs_pre_update("20261125-142530-123-srs-pre_update-x"));
        let dir = temp_dir("collide");
        let a = unique_id(&dir, 5, Kind::PreUpdate);
        assert_eq!(a, "19700101-000000-005-srs-pre_update");
        fs::create_dir(dir.join(&a)).unwrap();
        let b = unique_id(&dir, 5, Kind::PreUpdate);
        assert_eq!(b, format!("{a}-2"));
        fs::create_dir(dir.join(&b)).unwrap();
        assert_eq!(unique_id(&dir, 5, Kind::PreUpdate), format!("{a}-3"));
        let _ = fs::remove_dir_all(&dir);
    }
}
