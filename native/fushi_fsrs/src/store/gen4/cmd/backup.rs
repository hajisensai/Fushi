//! 整包备份 / 还原里旧形态复习数据的读入（G11-4；规划 §1.9、D34；交接说明 G11-4 一节）：`legacy_backup_import`。
//!
//! 新形态的整包备份（`srs/manifest.json` + 每个集合一条 `srs/<n>.bin`，`FSRS4EXP` 流）还原时直接走 G11-3 的 `import`；
//! 这里只管**换代之前**的三种形态，全部落到 G11-2 的旧备份读入 `import.rs` [import_backup]：
//!
//! - `source: "db"`：协议 3 整包备份 / 服务端备份里的 `srs.db` 快照（2026-10-23 起）。`path` = Dart 从 zip 里解出来的
//!   **临时副本**（调用方的，命令会在原地改它）。
//! - `source: "events"`：只有 v1 事件的旧输入——2026-10-23 之前的整包备份（SRS 表在主库条目里）、v2 同步之前的
//!   `.fushisrs` 事件备份（清单魔数 `fushi-srs-backup`）。Dart 把事件按协议 3 `apply` 的「外来、已盖戳」输入项一行一个写进
//!   JSONL 文件（`path`），命令在调用方给的空目录 `scratch` 里新建一份协议 3 库落进去。
//!
//! # 备副本（冻结代码，写锁之外）
//!
//! [import_backup] 只核对、不代做：旧库必须是用冻结的协议 3 代码备好的（规划 §1.2 缺口 G-10 的 `open_legacy_scratch`）。
//! 这里就是那一步，与迁移的前提补完（`prepare.rs`）同一串协议 3 命令、同一个分发器（`store/ffi.rs` `sync2_dispatch`）：
//! `SrsCore::open`（schema 阶梯）→ `cache_config_set` → `migrate` 到 `done`（建副本自己的身份、旧行包成操作）→（事件来源）
//! 分批 `apply` 外来已盖戳的事件 → `dedup` → `replay_pending`。全部在副本上做、在新代库的写锁之外做（协议 3 的阶梯与重放
//! 可能很久），备好之后在副本的 `srs_meta` 记 [PREPARED_KEY]，同一个副本再来一次（预检之后的真导入）直接跳过。
//!
//! # 落库（一个写事务，分发器 `write_binding`）
//!
//! 与 `.fushisrs` 第 2 版的导入同一套认领与确认（`cmd/fushisrs.rs` 文件头第 1 步）：协议 3 时代集合 = `collection_of(uid)`、
//! 目录名 = uid（交接说明 G9-4 定案 2），备份里那个 profile 的盐（`legacy::salts`：uid 本身 + 退役的旧 uid）、设备公钥
//! （`sync2_devices`，与 [import_backup] 带的同一份）拼成清单 → 没确认时新盐 / 新设备回 `needsConfirm`（`reason: identity`）、
//! 另一个集合回 `needsConfirm`（`reason: join`），什么都不写；确认了就 `collection_adopt`（没绑过 = `bound`）→
//! [import_backup]（落真相、`Settle::Rebuild` 收派生层、带信任与公钥）→ 本机状态行（有改动修订号推进 1）。
//! `preflight: true` 在一个回滚掉的保存点里跑认领，只回 `ready` / `needsConfirm`（同 `import` 的预检）。
//!
//! 回包：`{format: "legacy", source, outcome, applied, unchanged, peers, untrusted, counts, localRevision, localEpoch}`
//! （+ 绑定变了时分发器加 `bindingChanged`，有改动时 `Tally::all()` 由分发器取走）。坏文件、备不好的副本（前提核对不过）、
//! 另一个集合没确认、与本机矛盾（公钥冲突）一律报错或 `needsConfirm`、整笔回滚、新代库一条不落。同一份再读一遍什么都不改。
//!
//! 内存：`events` 来源按行读、每 [APPLY_BATCH] 项发一次 `apply`，不整份读进内存；`db` 来源是 SQLite 文件。

use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OptionalExtension};
use serde_json::{Value, json};

use super::fushisrs::{Manifest, unconfirmed_identity};
use super::identity::{Emitting, collection_adopt};
use crate::store::SrsCore;
use crate::store::gen4::carry::{legacy_peers, legacy_self};
use crate::store::gen4::import::{Imported, import_backup};
use crate::store::gen4::legacy;
use crate::store::gen4::local;
use crate::store::gen4::refresh::{TALLY_KEY, Tally};
use crate::store::gen4::truth::Truth;
use crate::store::sync2::collection_of;

/// 备好的副本在自己的 `srs_meta` 里记的标记（值 = 备的是哪个 profile）：同一个副本第二次来不再重做。
pub const PREPARED_KEY: &str = "gen4_backup_prepared";

/// `events` 来源一次 `apply` 的项数。
pub const APPLY_BATCH: usize = 1000;

/// `migrate` 一次包的旧行数。
const MIGRATE_BATCH: usize = 2000;

/// 预检里回滚保存点用的错误（不会出现在回包里）。
const PREFLIGHT_ROLLBACK: &str = "gen4 legacy backup import: preflight rollback";

/// 请求里的来源（模块文件头）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Db,
    Events,
}

impl Kind {
    fn wire(self) -> &'static str {
        match self {
            Kind::Db => "db",
            Kind::Events => "events",
        }
    }
}

/// 备好的副本：协议 3 库的路径与它属于备份里的哪个 profile。
pub struct Prepared {
    pub kind: Kind,
    pub db: PathBuf,
    pub profile: String,
}

fn str_of<'v>(req: &'v Value, k: &str) -> Result<&'v str, String> {
    req.get(k)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("legacy_backup_import: missing {k}"))
}

/// 经协议 3 的分发器发一条命令（与旧 app 发的同形，`prepare.rs` 同口径）。
fn p3(core: &SrsCore, req: Value, blobs: Vec<Vec<u8>>) -> Result<Value, String> {
    let mut blobs = blobs;
    crate::store::ffi::sync2_dispatch(core, &req, &mut blobs, &mut Vec::new()).map_err(|e| {
        format!(
            "gen4 legacy backup import: protocol 3 `{}`: {e}",
            req["op"].as_str().unwrap_or_default()
        )
    })
}

/// 副本已经为 [profile] 备好了没有（[PREPARED_KEY]）。不是 SQLite 文件 / 没有 `srs_meta` = 没有。
fn already_prepared(db: &Path, profile: &str) -> bool {
    let Ok(c) = Connection::open_with_flags(
        db,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) else {
        return false;
    };
    c.query_row(
        "SELECT value FROM srs_meta WHERE key = ?1",
        [PREPARED_KEY],
        |r| r.get::<_, String>(0),
    )
    .optional()
    .ok()
    .flatten()
    .as_deref()
        == Some(profile)
}

/// 备副本（模块文件头「备副本」）：在新代库的写锁之外跑。
pub fn prepare(req: &Value) -> Result<Prepared, String> {
    let kind = match str_of(req, "source")? {
        "db" => Kind::Db,
        "events" => Kind::Events,
        other => return Err(format!("legacy_backup_import: unknown source {other}")),
    };
    let profile = str_of(req, "backupProfile")?.to_owned();
    let now = req
        .get("now")
        .and_then(Value::as_i64)
        .ok_or("legacy_backup_import: missing now")?;
    let caches = req
        .get("caches")
        .filter(|v| v.is_object())
        .ok_or("legacy_backup_import: missing caches")?
        .clone();
    let path = PathBuf::from(str_of(req, "path")?);
    if !path.is_file() {
        return Err(format!(
            "legacy_backup_import: {} does not exist",
            path.display()
        ));
    }
    let db = match kind {
        Kind::Db => path.clone(),
        Kind::Events => {
            let scratch = PathBuf::from(str_of(req, "scratch")?);
            if !scratch.is_dir() {
                return Err(format!(
                    "legacy_backup_import: scratch directory {} does not exist",
                    scratch.display()
                ));
            }
            scratch.join(crate::store::gen4::files::LEGACY_FILE)
        }
    };
    if already_prepared(&db, &profile) {
        return Ok(Prepared { kind, db, profile });
    }
    if kind == Kind::Events {
        // 上一次备到一半的副本整份重来（它只是临时库）。
        crate::store::seal::remove_sqlite_files(&db)?;
    }
    let core = SrsCore::open(&db).map_err(|e| {
        format!("gen4 legacy backup import: open the protocol 3 library in the backup: {e}")
    })?;
    let out = (|| -> Result<(), String> {
        let base = |op: &str| json!({"op": op, "profile": profile, "now": now, "caches": caches});
        p3(&core, base("cache_config_set"), Vec::new())?;
        let mut migrate = base("migrate");
        migrate["limit"] = json!(MIGRATE_BATCH);
        while p3(&core, migrate.clone(), Vec::new())?["done"] != json!(true) {}
        if kind == Kind::Events {
            apply_events(&core, &path, &profile, now, &caches)?;
        }
        while p3(&core, base("dedup"), Vec::new())?["done"] == json!(false) {}
        while p3(&core, base("replay_pending"), Vec::new())?["more"] == json!(true) {}
        Ok(())
    })();
    // 关库：WAL 并回副本主文件（最后一条连接负责），之后的读连接看到的就是备好的全部。
    core.close();
    drop(core);
    out?;
    let c = Connection::open(&db).map_err(|e| format!("gen4 legacy backup import: {e}"))?;
    c.execute(
        "INSERT OR REPLACE INTO srs_meta (key, value) VALUES (?1, ?2)",
        rusqlite::params![PREPARED_KEY, profile],
    )
    .map_err(|e| format!("gen4 legacy backup import: {e}"))?;
    drop(c);
    Ok(Prepared { kind, db, profile })
}

/// JSONL 里的外来已盖戳事件按批 `apply` 进副本（[APPLY_BATCH] 项一批；空行跳过）。
fn apply_events(
    core: &SrsCore,
    path: &Path,
    profile: &str,
    now: i64,
    caches: &Value,
) -> Result<(), String> {
    let f = File::open(path)
        .map_err(|e| format!("legacy_backup_import: cannot open {}: {e}", path.display()))?;
    let mut batch: Vec<String> = Vec::with_capacity(APPLY_BATCH);
    let flush = |batch: &mut Vec<String>| -> Result<(), String> {
        if batch.is_empty() {
            return Ok(());
        }
        let blob = format!("[{}]", batch.join(",")).into_bytes();
        batch.clear();
        p3(
            core,
            json!({
                "op": "apply", "profile": profile, "now": now, "caches": caches,
                // 副本没有宿主设备：旧版时钟的缺省写入者用一个固定名（副本用完即删，名字不出副本）。
                "legacyDevice": "gen4-backup-import", "recvNow": now, "tickNow": now,
            }),
            vec![blob],
        )
        .map(|_| ())
    };
    for (n, line) in BufReader::new(f).lines().enumerate() {
        let line = line.map_err(|e| format!("legacy_backup_import: read events: {e}"))?;
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // 先确认是一个 JSON 对象（坏行明确报行号，不交给协议 3 报一个看不出位置的错）。
        match serde_json::from_str::<Value>(line) {
            Ok(Value::Object(_)) => {}
            _ => {
                return Err(format!(
                    "legacy_backup_import: events line {} is not a JSON object",
                    n + 1
                ));
            }
        }
        batch.push(line.to_owned());
        if batch.len() >= APPLY_BATCH {
            flush(&mut batch)?;
        }
    }
    flush(&mut batch)
}

/// 备好的副本 → 认领用的清单（模块文件头「落库」）：协议 3 时代集合 = `collection_of(uid)`、目录名 = uid，盐与设备公钥
/// 取副本里那个 profile 的（与 [import_backup] 落的同一份；副本自己备副本时现建、一条都没写过的身份不算）。
fn manifest_of(src: &Connection, profile: &str) -> Result<Manifest, String> {
    let scratch = legacy_self(src, profile)?
        .filter(|s| s.last == 0)
        .map(|s| s.device);
    let (peers, _) = legacy_peers(src, profile)?;
    Ok(Manifest {
        collection: collection_of(profile),
        dir: profile.to_owned(),
        salts: legacy::salts(src, profile)?.into_iter().collect(),
        peers: peers
            .into_iter()
            .filter(|p| Some(p.device) != scratch)
            .collect(),
    })
}

fn imported_json(o: &Imported) -> Value {
    json!({
        "devices": o.devices, "applied": o.applied, "pending": o.pending, "inserted": o.inserted,
        "same": o.same, "kept": o.kept, "replaced": o.replaced, "forks": o.forks, "parked": o.parked,
    })
}

/// 落库（模块文件头「落库」）。[t] 在分发器的写事务里；[src] 是备好的副本的读连接（`dryrun::open_legacy`）。
pub fn land(
    t: &Truth<'_>,
    profile: &str,
    req: &Value,
    p: &Prepared,
    src: &Connection,
    anchor: Option<&Value>,
    col_of: &dyn Fn(&Truth<'_>) -> Result<i64, String>,
) -> Result<Emitting, String> {
    let now = req
        .get("now")
        .and_then(Value::as_i64)
        .ok_or("legacy_backup_import: missing now")?;
    let preflight = req.get("preflight").and_then(Value::as_bool) == Some(true);
    let confirmed = req.get("confirmed").and_then(Value::as_bool) == Some(true);
    let m = manifest_of(src, &p.profile)?;
    let identity = if confirmed {
        None
    } else {
        unconfirmed_identity(t, profile, &m)?
    };
    let (new_salts, new_peers) = identity.clone().unwrap_or_default();
    let needs_confirm = |reason: &str| {
        json!({
            "format": "legacy",
            "source": p.kind.wire(),
            "outcome": "needsConfirm",
            "reason": reason,
            "collection": m.collection.text(),
            "dir": m.dir,
            "newSalts": new_salts,
            "newPeers": new_peers,
        })
    };
    let sub = json!({
        "collection": m.collection.text(),
        "dir": m.dir,
        "salts": m.salts.iter().collect::<Vec<_>>(),
        "confirmed": confirmed,
        "now": now,
    });
    if preflight {
        // 副本备没备好（[import_backup] 开头同一处核对）；认领在一个回滚掉的保存点里跑（同 `import` 的预检），补的盐 /
        // 绑定不留。认领之后副本 profile 的集合按构造就在本集合的来源里（目录名 = 备份 uid），不用再落一遍真相来验。
        let blockers = legacy::preflight(src, &p.profile)?;
        if !blockers.is_empty() {
            return Err(format!(
                "gen4 legacy backup import: the backup library is not ready: {}",
                blockers.join("; ")
            ));
        }
        let mut asks = false;
        let probe: Result<(), String> = t.tx(|t| {
            let (v, _) = collection_adopt(t, profile, &sub)?;
            asks = v["outcome"] == json!("needsConfirm");
            Err(PREFLIGHT_ROLLBACK.to_owned())
        });
        match probe {
            Err(e) if e == PREFLIGHT_ROLLBACK => {}
            Err(e) => return Err(e),
            Ok(()) => unreachable!("the preflight savepoint always rolls back"),
        }
        let mut v = if asks {
            needs_confirm("join")
        } else if identity.is_some() {
            needs_confirm("identity")
        } else {
            json!({"format": "legacy", "source": p.kind.wire(), "outcome": "ready"})
        };
        v["preflight"] = json!(true);
        return Ok((v, None));
    }
    if identity.is_some() {
        return Ok((needs_confirm("identity"), None));
    }
    let (adopted, changed) = collection_adopt(t, profile, &sub)?;
    if adopted["outcome"] == json!("needsConfirm") {
        return Ok((needs_confirm("join"), None));
    }
    let wrote = !matches!(adopted["outcome"].as_str(), Some("same" | "alreadyJoined"));
    let got = import_backup(src, &p.profile, t, col_of(t)?)?;
    let applied = got.inserted + got.replaced + got.forks;
    let unchanged = applied == 0 && got.peers == 0 && got.untrusted == 0 && !wrote;
    let mut probe = if unchanged {
        json!({})
    } else {
        json!({"changed": [Value::Null]})
    };
    local::persist(t, profile, anchor, &mut probe)?;
    let mut v = json!({
        "format": "legacy",
        "source": p.kind.wire(),
        "outcome": adopted["outcome"],
        "applied": applied,
        "unchanged": unchanged,
        "peers": got.peers,
        "untrusted": got.untrusted,
        "counts": imported_json(&got),
    });
    for k in ["localRevision", "localEpoch"] {
        v[k] = probe[k].clone();
    }
    if !unchanged {
        v[TALLY_KEY] = Tally::all().json();
    }
    Ok((v, changed))
}
