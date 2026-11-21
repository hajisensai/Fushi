//! 整包备份 / 还原里旧形态复习数据的读入（G11-4；规划 §1.9、D34；交接说明 G11-4 一节）：`legacy_backup_import`。
//!
//! 新形态的整包备份（`srs/manifest.json` + 每个集合一条 `srs/<n>.bin`，`FSRS4EXP` 流）还原时直接走 G11-3 的 `import`；
//! 这里只管**换代之前**的三种形态，全部落到 G11-2 的旧备份读入 `import.rs` [import_backup]：
//!
//! - `source: "db"`：协议 3 整包备份 / 服务端备份里的 `srs.db` 快照（2026-10-23 起）。`path` = Dart 从 zip 里解出来的
//!   文件，命令**只读不改**：拷进 `scratch` 再在拷贝上备。
//! - `source: "events"`：只有 v1 事件的旧输入——2026-10-23 之前的整包备份（SRS 表在主库条目里）、v2 同步之前的
//!   `.fushisrs` 事件备份（清单魔数 `fushi-srs-backup`）。Dart 把事件按协议 3 `apply` 的「外来、已盖戳」输入项一行一个写进
//!   JSONL 文件（`path`），命令在 `scratch` 里新建一份协议 3 库落进去。
//!
//! `scratch`（两种来源都要）：调用方给的临时目录，里面只能有本命令自己备的 `srs.db`（及 -wal / -shm / -journal），别的
//! 文件一概拒绝；不得是已打开的新代库目录、也不得与它互相包含（命令会删 / 重建 `<scratch>/srs.db*`，那里可能是迁移后
//! 封存的协议 3 库）。同一份备份里的几个 profile 各给一个 `scratch`，输入文件始终原样，每个 profile 的输入摘要都相同。
//!
//! # 备副本（冻结代码，写锁之外）
//!
//! [import_backup] 只核对、不代做：旧库必须是用冻结的协议 3 代码备好的（规划 §1.2 缺口 G-10 的 `open_legacy_scratch`）。
//! 这里就是那一步，与迁移的前提补完（`prepare.rs`）同一串协议 3 命令、同一个分发器（`store/legacy3` `sync2_dispatch`）：
//! `SrsCore::open`（schema 阶梯）→ `cache_config_set` → `migrate` 到 `done`（建副本自己的身份、旧行包成操作）→（事件来源）
//! 分批 `apply` 外来已盖戳的事件 → `dedup` → `replay_pending`。全部在副本上做、在新代库的写锁之外做（协议 3 的阶梯与重放
//! 可能很久），备好之后在副本的 `srs_meta` 记 [PREPARED_KEY]，同一个副本再来一次（预检之后的真导入）直接跳过。
//! 标记的值 = profile + 输入文件的 BLAKE3 摘要 + 来源（[prepared_marker]）：输入是不可信的备份文件，自带一条标记也不能让
//! 命令跳过备副本（文件里写进的标记要等于这份文件自身的摘要，做不到）；换了输入的旧副本也不会被误认。
//!
//! # 落库（一个写事务，分发器 `write_binding`）
//!
//! 与 `.fushisrs` 第 2 版的导入同一套认领与确认（`cmd/fushisrs.rs` 文件头第 1 步）：协议 3 时代集合 = `collection_of(uid)`、
//! 目录名 = uid（交接说明 G9-4 定案 2），备份里那个 profile 的盐（`legacy::salts`：uid 本身 + 退役的旧 uid）、设备公钥
//! （`sync2_devices`，与 [import_backup] 带的同一份）拼成清单 → 没确认时新盐 / 新设备回 `needsConfirm`（`reason: identity`）、
//! 另一个集合回 `needsConfirm`（`reason: join`），什么都不写；确认了就 `collection_adopt`（没绑过 = `bound`，这时本机
//! 另写一条 `Salts` 声明备份的盐：协议 3 备份里没有 `Salts` 操作，R0 Windows 实测 e1-replace）→
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
use super::identity::{Emitting, PendingSelf, collection_adopt_with, declare_salts};
use crate::store::SrsCore;
use crate::store::gen4::carry::{legacy_peers, legacy_self};
use crate::store::gen4::import::{Imported, import_backup};
use crate::store::gen4::legacy;
use crate::store::gen4::local;
use crate::store::gen4::refresh::{TALLY_KEY, Tally};
use crate::store::gen4::truth::Truth;
use crate::store::sync2::collection_of;

/// 备好的副本在自己的 `srs_meta` 里记的标记（值 = [prepared_marker]）：同一个副本第二次来不再重做。
pub const PREPARED_KEY: &str = "gen4_backup_prepared";

/// 落库时集合的本机秘密已不是备副本时用的那个（[land]）：整条命令什么都没留，重发即按新的秘密重备。
pub const LOCAL_IDENTITY_MOVED: &str = "gen4 legacy backup import: the local identity of this profile changed while the copy was being prepared; nothing was written, send the request again";

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
    crate::store::legacy3::dispatch(core, &req, &mut blobs).map_err(|e| {
        format!(
            "gen4 legacy backup import: protocol 3 `{}`: {e}",
            req["op"].as_str().unwrap_or_default()
        )
    })
}

/// 副本标记的值：备的是哪个 profile、从哪份输入（摘要）、哪种来源、按哪个本机秘密（[seed_scratch_identity]）备出来的。
/// 秘密只进它的单向指纹（BLAKE3 派生键），不落原文：副本是临时库，也不该带着本机签名钥匙的种子。秘密变了（profile 还没
/// 绑定时每次请求现生成的 [PendingSelf]：没确认的那一次与确认后的那一次不同）副本整份重备，副本身份与落库时建的本机
/// 身份始终同源。
fn prepared_marker(
    profile: &str,
    digest: &[u8; 32],
    kind: Kind,
    secret: Option<&[u8; 32]>,
) -> String {
    let hex = |b: &[u8]| -> String { b.iter().map(|b| format!("{b:02x}")).collect() };
    let fp = match secret {
        Some(s) => {
            let mut h = blake3::Hasher::new_derive_key(
                "fushi gen4 legacy backup scratch secret fingerprint 2026-11-18",
            );
            h.update(s);
            hex(&h.finalize().as_bytes()[..16])
        }
        None => "-".to_owned(),
    };
    format!("{profile}:{}:{}:{fp}", kind.wire(), hex(digest))
}

/// 副本是不是按 [marker] 备好的（[PREPARED_KEY]）。不是 SQLite 文件 / 没有 `srs_meta` = 没有。
fn already_prepared(db: &Path, marker: &str) -> bool {
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
        == Some(marker)
}

/// `scratch` 的核对（模块文件头）：是目录、只有本命令备的协议 3 库文件、与已打开的新代库目录 [library] 不相交。
fn checked_scratch(req: &Value, library: &Path) -> Result<PathBuf, String> {
    let scratch = PathBuf::from(str_of(req, "scratch")?);
    if !scratch.is_dir() {
        return Err(format!(
            "legacy_backup_import: scratch directory {} does not exist",
            scratch.display()
        ));
    }
    let canon = |p: &Path| {
        std::fs::canonicalize(p)
            .map_err(|e| format!("legacy_backup_import: resolve {}: {e}", p.display()))
    };
    let (s, lib) = (canon(&scratch)?, canon(library)?);
    if s.starts_with(&lib) || lib.starts_with(&s) {
        return Err(format!(
            "legacy_backup_import: scratch directory {} overlaps the open library",
            scratch.display()
        ));
    }
    let legacy = crate::store::gen4::files::LEGACY_FILE;
    let entries = std::fs::read_dir(&scratch)
        .map_err(|e| format!("legacy_backup_import: read {}: {e}", scratch.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("legacy_backup_import: read scratch: {e}"))?;
        let name = entry.file_name();
        let ours = name.to_str().is_some_and(|n| {
            n == legacy
                || ["-wal", "-shm", "-journal"]
                    .iter()
                    .any(|x| n == format!("{legacy}{x}"))
        });
        if !ours || !entry.path().is_file() {
            return Err(format!(
                "legacy_backup_import: scratch directory {} is not empty ({})",
                scratch.display(),
                name.to_string_lossy()
            ));
        }
    }
    Ok(scratch)
}

/// 备副本（模块文件头「备副本」）：在新代库的写锁之外跑。[secret] = 目标 profile 所在集合的本机签名钥匙种子（还没绑定 /
/// 没有本机身份时为 `None`），用来给副本定一个可重现的身份（[seed_scratch_identity]）。[library] = 已打开的新代库目录
/// （`scratch` 不得与它相交）。
pub fn prepare(req: &Value, secret: Option<&[u8; 32]>, library: &Path) -> Result<Prepared, String> {
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
    let scratch = checked_scratch(req, library)?;
    let db = scratch.join(crate::store::gen4::files::LEGACY_FILE);
    // 输入只读：摘要既是副本标记的一部分，也是副本身份的种子（同一份输入 → 同一个值，与导入几次、几个 profile 无关）。
    let digest = content_digest(&path)?;
    let marker = prepared_marker(&profile, &digest, kind, secret);
    if already_prepared(&db, &marker) {
        return Ok(Prepared { kind, db, profile });
    }
    // 别的输入 / 备到一半的副本整份重来（它只是临时库）。
    crate::store::seal::remove_sqlite_files(&db)?;
    if kind == Kind::Db {
        // 只拷主文件：zip 里只有快照主文件；输入旁边就算有 -wal 也不属于这份备份。
        std::fs::copy(&path, &db).map_err(|e| {
            format!(
                "legacy_backup_import: copy {} into scratch: {e}",
                path.display()
            )
        })?;
    }
    // 副本里的「此刻」：事件来源取输入里最晚的时刻（[input_time]，不晚于请求的 `now`），包出的操作才与哪天导入无关。
    let now = match kind {
        Kind::Events => input_time(&path)?.map_or(now, |t| t.min(now)),
        Kind::Db => now,
    };
    let core = SrsCore::open(&db).map_err(|e| {
        format!("gen4 legacy backup import: open the protocol 3 library in the backup: {e}")
    })?;
    let out = (|| -> Result<(), String> {
        if let Some(secret) = secret {
            seed_scratch_identity(&db, &profile, kind, secret, &digest)?;
        }
        let base = |op: &str| json!({"op": op, "profile": profile, "now": now, "caches": caches});
        p3(&core, base("cache_config_set"), Vec::new())?;
        let mut migrate = base("migrate");
        migrate["limit"] = json!(MIGRATE_BATCH);
        while p3(&core, migrate.clone(), Vec::new())?["done"] != json!(true) {}
        if kind == Kind::Events {
            apply_events(&core, &db, &path, &profile, now, &caches)?;
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
        rusqlite::params![PREPARED_KEY, marker],
    )
    .map_err(|e| format!("gen4 legacy backup import: {e}"))?;
    drop(c);
    Ok(Prepared { kind, db, profile })
}

/// 事件 JSONL 里最晚的时刻（毫秒）：日志的 `at`、身份记录的 `createdAt`、修改记录 / 日志 HLC 的物理部分、`server`。
/// 没有任何时刻回 `None`。
///
/// 副本把旧事件包成操作时，操作的时钟由副本的 `now` 推进（协议 3 `Local` 的 HLC）。拿请求的 `now`（墙钟）的话同一份输入
/// 每天包出的操作不同，第二次落库变成「替换 / 分叉」而不是「已有」；拿输入里最晚的时刻则只由输入决定，语义上也就是「备份
/// 做完的那一刻收到这些事件」。上限压到请求的 `now`：输入不可信，造一个远未来的时刻不能把副本的时钟推到未来。
fn input_time(path: &Path) -> Result<Option<i64>, String> {
    let mut best: Option<i64> = None;
    let mut see = |t: Option<i64>| {
        if let Some(t) = t {
            best = Some(best.map_or(t, |b| b.max(t)));
        }
    };
    each_event(path, |item| {
        let x = &item["e"]["x"];
        see(x.get("at").and_then(Value::as_i64));
        see(x
            .get("d")
            .and_then(|d| d.get("createdAt"))
            .and_then(Value::as_i64));
        see(item.get("server").and_then(Value::as_i64));
        if let Some(h) = x.get("hlc").and_then(Value::as_str) {
            see(h.split(':').next().and_then(|p| p.parse::<i64>().ok()));
        }
        Ok(())
    })?;
    Ok(best)
}

/// [path] 整份内容的 BLAKE3 摘要（按块读，不整份进内存）。
fn content_digest(path: &Path) -> Result<[u8; 32], String> {
    let f = File::open(path)
        .map_err(|e| format!("legacy_backup_import: cannot open {}: {e}", path.display()))?;
    let mut h = blake3::Hasher::new();
    h.update_reader(f)
        .map_err(|e| format!("legacy_backup_import: read {}: {e}", path.display()))?;
    Ok(*h.finalize().as_bytes())
}

/// 副本自己的身份（设备 ID、签名钥匙种子）：副本里还没有这个 profile 的身份时（`events` 来源总是没有；`db` 来源是剥过
/// 本机身份的整包备份快照），在协议 3 代码建身份（`Local::create`，随机）之前先写好一个**可重现**的。
///
/// 为什么：旧事件（以及没包过的旧行）由副本的身份包成操作，经 [import_backup] 成为这个设备名下的承袭日志。身份每次随机
/// 的话，用户隔天再导一次同一个旧文件（或覆盖还原之后又合并同一份备份），同样的内容会以另一个合成设备的名义再落一遍
/// ——派生层不重复，但真相层每导一次多一份、回包报「并入了 N 条」，不幂等。现在设备与钥匙 = BLAKE3 派生（本机签名钥匙
/// 种子 [secret]、备份里的 profile、输入内容的摘要、来源种类），同一台设备、同一个集合导同一份输入得到同一个合成设备，
/// 包出的操作逐字节相同，第二次落库全是已有的槽（`same`）。
///
/// 钥匙必须混进本机秘密：合成设备的公钥会记进集合的 `peers`，只拿备份内容就能推出私钥的话，拿到备份文件的人可以冒充
/// 这个设备往位置上写协议 3 段。换一台设备 / 另一个集合导同一份输入得到另一个合成设备（与改动之前同样的结果）。
///
/// 时钟：HLC 从 0 起（与 `Local::create` 相同）。
fn seed_scratch_identity(
    db: &Path,
    profile: &str,
    kind: Kind,
    secret: &[u8; 32],
    digest: &[u8; 32],
) -> Result<(), String> {
    let c = Connection::open(db).map_err(|e| format!("gen4 legacy backup import: {e}"))?;
    crate::store::ids::register(&c).map_err(|e| format!("gen4 legacy backup import: {e}"))?;
    let has: bool = c
        .query_row(
            "SELECT EXISTS (SELECT 1 FROM sync2_self WHERE profile_uid = srs_id(?1))",
            [profile],
            |r| r.get(0),
        )
        .map_err(|e| format!("gen4 legacy backup import: {e}"))?;
    if has {
        return Ok(());
    }
    let mut h =
        blake3::Hasher::new_derive_key("fushi gen4 legacy backup scratch identity 2026-11-17");
    h.update(secret);
    h.update(&(profile.len() as u64).to_le_bytes());
    h.update(profile.as_bytes());
    h.update(kind.wire().as_bytes());
    h.update(digest);
    let mut out = [0u8; 48];
    h.finalize_xof().fill(&mut out);
    let mut device = [0u8; 16];
    device.copy_from_slice(&out[..16]);
    // RFC 9562 UUIDv8（自定义内容）：版本与变体位照规矩，其余是派生字节。
    device[6] = (device[6] & 0x0f) | 0x80;
    device[8] = (device[8] & 0x3f) | 0x80;
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&out[16..]);
    let key = crate::sync2::keys::DeviceKey::from_seed(&seed);
    let chain = crate::sync2::segment::CHAIN_ZERO;
    let collection = collection_of(profile);
    // 与 `store/sync2/mod.rs` `Local::create` 写的同两行（冻结的协议 3 形状）。
    c.execute(
        "INSERT INTO sync2_self (profile_uid, collection, device, key_seed, next_seq, chain) \
         VALUES (srs_id(?1), ?2, ?3, ?4, 1, ?5)",
        rusqlite::params![
            profile,
            collection.0.to_vec(),
            device.to_vec(),
            seed.to_vec(),
            chain.to_vec()
        ],
    )
    .map_err(|e| format!("gen4 legacy backup import: {e}"))?;
    c.execute(
        "INSERT OR REPLACE INTO sync2_devices (profile_uid, device, public, applied, chain) \
         VALUES (srs_id(?1), ?2, ?3, 0, ?4)",
        rusqlite::params![
            profile,
            device.to_vec(),
            key.public().to_vec(),
            chain.to_vec()
        ],
    )
    .map_err(|e| format!("gen4 legacy backup import: {e}"))?;
    Ok(())
}

/// JSONL 里的外来已盖戳事件按批 `apply` 进副本（[APPLY_BATCH] 项一批；空行跳过），分两遍读文件：
///
/// 1. 身份记录 / 修改记录 / 不认识的事件，然后 `replay_pending`（副本的卡片派生缓存随之建好）；
/// 2. 复习日志。没带 `note` 的（v2 之前的 `.fushisrs` 事件备份只有事件、没有卡片缓存；老整包备份的缓存里也可能缺）按
///    副本 `srs_cards_cache` 的卡片 → 笔记补上（[log_note_of]）——与协议 3 `applyRemote` 落库前按卡片行查笔记同一口径；
///    卡片派生不出来（笔记被删 / 模板没了）就照旧不带。日志带不带笔记决定新代里笔记一级的删除 / 统计能不能找到它。
fn apply_events(
    core: &SrsCore,
    db: &Path,
    path: &Path,
    profile: &str,
    now: i64,
    caches: &Value,
) -> Result<(), String> {
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
    let mut batch: Vec<String> = Vec::with_capacity(APPLY_BATCH);
    each_event(path, |item| {
        if is_log(&item) {
            return Ok(());
        }
        batch.push(item.to_string());
        if batch.len() >= APPLY_BATCH {
            flush(&mut batch)?;
        }
        Ok(())
    })?;
    flush(&mut batch)?;
    let base = |op: &str| json!({"op": op, "profile": profile, "now": now, "caches": caches});
    while p3(core, base("replay_pending"), Vec::new())?["more"] == json!(true) {}
    // 副本的读连接（注册了 ID 编码函数）；每批日志之前重开一次读事务，看得到上一批落下的卡片。
    let mut notes: Option<Connection> = None;
    let mut pending: Vec<Value> = Vec::with_capacity(APPLY_BATCH);
    let land = |pending: &mut Vec<Value>, notes: &mut Option<Connection>| -> Result<(), String> {
        if pending.is_empty() {
            return Ok(());
        }
        if pending
            .iter()
            .any(|it| it.get("note").is_none_or(Value::is_null))
        {
            let c = match notes.take() {
                Some(c) => {
                    c.execute_batch("COMMIT; BEGIN")
                        .map_err(|e| format!("gen4 legacy backup import: {e}"))?;
                    c
                }
                None => crate::store::gen4::dryrun::open_legacy(db)?,
            };
            for it in pending.iter_mut() {
                if !it.get("note").is_none_or(Value::is_null) {
                    continue;
                }
                let Some(card) = it["e"]["x"]["card"].as_str().map(str::to_owned) else {
                    continue;
                };
                if let Some(n) = log_note_of(&c, profile, &card)? {
                    it["note"] = json!(n);
                }
            }
            *notes = Some(c);
        }
        let mut lines: Vec<String> = pending.drain(..).map(|v| v.to_string()).collect();
        flush(&mut lines)
    };
    each_event(path, |item| {
        if !is_log(&item) {
            return Ok(());
        }
        pending.push(item);
        if pending.len() >= APPLY_BATCH {
            land(&mut pending, &mut notes)?;
        }
        Ok(())
    })?;
    land(&mut pending, &mut notes)
}

/// 一项是不是复习日志（`{e: {t: "log", ...}}`）。
fn is_log(item: &Value) -> bool {
    item["e"]["t"].as_str() == Some("log")
}

/// 副本里卡片 [card] 的笔记（规范文本）；没有这张卡回 `None`。
pub(crate) const LOG_NOTE_SQL: &str = "SELECT srs_idt(note_id) FROM srs_cards_cache \
     WHERE id = srs_id(?1) AND profile_uid = srs_id(?2) AND note_id IS NOT NULL";

fn log_note_of(c: &Connection, profile: &str, card: &str) -> Result<Option<String>, String> {
    c.prepare_cached(LOG_NOTE_SQL)
        .and_then(|mut q| {
            q.query_row(rusqlite::params![card, profile], |r| r.get::<_, String>(0))
                .optional()
        })
        .map_err(|e| format!("gen4 legacy backup import: card note: {e}"))
}

/// 按行读 JSONL，每个非空行解成 JSON 对象交给 [f]；坏行报行号。
fn each_event(path: &Path, mut f: impl FnMut(Value) -> Result<(), String>) -> Result<(), String> {
    let file = File::open(path)
        .map_err(|e| format!("legacy_backup_import: cannot open {}: {e}", path.display()))?;
    for (n, line) in BufReader::new(file).lines().enumerate() {
        let line = line.map_err(|e| format!("legacy_backup_import: read events: {e}"))?;
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // 先确认是一个 JSON 对象（坏行明确报行号，不交给协议 3 报一个看不出位置的错）。
        match serde_json::from_str::<Value>(line) {
            Ok(v @ Value::Object(_)) => f(v)?,
            _ => {
                return Err(format!(
                    "legacy_backup_import: events line {} is not a JSON object",
                    n + 1
                ));
            }
        }
    }
    Ok(())
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
#[allow(clippy::too_many_arguments)]
pub fn land(
    t: &Truth<'_>,
    profile: &str,
    req: &Value,
    p: &Prepared,
    src: &Connection,
    anchor: Option<&Value>,
    pending: Option<&PendingSelf>,
    secret: Option<&[u8; 32]>,
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
            let (v, _) = collection_adopt_with(t, profile, &sub, pending)?;
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
    let (adopted, changed) = collection_adopt_with(t, profile, &sub, pending)?;
    if adopted["outcome"] == json!("needsConfirm") {
        return Ok((needs_confirm("join"), None));
    }
    // 副本身份是按 [secret] 派生的（[seed_scratch_identity]）；落进来的集合此刻的本机秘密必须就是它。分发器在读快照里定
    // 秘密、在写锁之外备副本，其间 profile 可能被别的命令绑定并建了身份（打开 profile 的 `identity`、并发的认领）：那时
    // 照落会让之后第一次合并同一份输入以另一个合成设备再落一遍。在这一笔写事务里核对，对不上整条命令失败（什么都不留），
    // 调用方重发即按新的本机秘密重备副本。
    let actual = t.self_identity(col_of(t)?)?.map(|s| s.sk);
    if actual.as_ref() != secret {
        return Err(LOCAL_IDENTITY_MOVED.to_owned());
    }
    let col = col_of(t)?;
    if adopted["outcome"] == json!("bound") {
        // 刚绑到备份的集合（没绑过 / 空集合换绑）：认领只带了本机的盐（`AdoptOutcome::Bound` 的盐随对方的操作到，位置
        // 与 `.fushisrs` 第 2 版都是如此），而协议 3 备份里没有任何 `Salts` 操作——备份 profile 的盐（`legacy::salts`，
        // 已过上面的身份确认）由本机在这里声明，与迁移第 6 步由本机身份写初始盐同一口径。缺了它，带 profile 盐的内置
        // 实体 ID 归不到规范 ID：卡片按不带盐的模板重新派生、与日志和别名表对不上（R0 Windows 实测 e1-replace）。
        declare_salts(t, col, &m.salts, now)?;
    }
    let wrote = !matches!(adopted["outcome"].as_str(), Some("same" | "alreadyJoined"));
    let got = import_backup(src, &p.profile, t, col)?;
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
