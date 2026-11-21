//! 迁移编排（设计 §6.1，规划 §1.4 第 1–11 步，G7-2）：把一个 profile 目录里协议 3 的 `srs.db` 迁成新代的 `srs4.db`。
//! 还没有调用方（第一段）：内核命令 `gen4_migrate_status` / `gen4_migrate_run` / `gen4_migrate_cancel` 与 Dart 的
//! `srsMigrateToGen4` 在第二段接（G7-5 / S1）。
//!
//! # 步骤（[run]；进度按 [Step] 报）
//!
//! 1. **空间**（[Step::Space]）：旧库 × 0.3（设计 §6.1 第 1 步）+ 对拍时冻结代码在临时表里重建旧缓存要的空间（旧库里
//!    三张缓存表的现有体积，`dbstat` 量）+ 余量。不够 = [Outcome::NoSpace]，什么都不碰。上一次留下的临时文件算可用空间
//!    （开跑前会删掉）。
//! 2. **取锁**（[Step::Lock]）：换代锁 `srs.gen.lock`（[GenLock]），再对旧库开写事务（`BEGIN IMMEDIATE`，不写任何东西）
//!    并一直持到封存提交——从取锁到封存，任何进程都写不进旧库，所以对拍核对过的就是封存进去的全部（设计 §6.1 第 2 步；
//!    原文写「持到第 6 步结束」，但提交点与封存之间若能插进写入，那笔写入就永远进不了新代）。锁被别人拿着 =
//!    [Outcome::Blocked]（`migrating`）；旧库正被写 = [Outcome::Blocked]（等一会再来）。
//! 3. **前提补完**（[Step::Prepare]，G7-2b，`prepare.rs`）：旧库没满足的前提——从没同步过（`migrated_at` 为空、
//!    旧行还在 `sync2_migrate_queue`）、只在投影表里的 profile（孤儿 uid）、去重作业、收段通道 / 待重放 / 待刷新缓存、
//!    schema 比这一版的协议 3 旧（v3.3.0 正式版是 26）——先用**冻结的协议 3 代码**（`SrsCore::open` 的升级阶梯与
//!    `store/legacy3` `sync2_dispatch` 的 `migrate` / `dedup` / `replay_pending`）做完。**在原件的副本上做**
//!    （`files::PREPARE_COPY`）：原件的写锁从这一步之前持到封存，原件在提交点之前一个字节不写，不论结局都还能被写它的
//!    那个协议 3 版本打开；之后的读快照与阶段都开在副本上。什么都不用补的库不拷副本。补不了的（并入做到一半、缺缓存
//!    配置、库比这一版新、文件坏了）拦下，[BlockCode] 给机器可读的原因。
//! 4. **前提核对**（[Step::Precondition]）：补完之后再核对一遍：整库的（`legacy::library_blockers`）与每个 profile 的
//!    （`dryrun::profile_blockers`）一项不齐就 [Outcome::Blocked]（[BlockCode::Precondition]），原因逐条列出。
//! 4. **临时文件里走一遍阶段**：在 `srs4.db-migrating` 里逐 profile 跑 `dryrun::profile_stages`（与预演**同一个函数**）：
//!    灌入（[Step::Translate]）→ 本机状态（公钥、信任、暂扣、检查点、本机媒体、`media_at`、加密位置记忆、绑定状态，
//!    `carry.rs`）→ 切点 `log_marks` → 新身份（新设备 ID、沿用签名钥匙、`prev` = 旧设备的日志末尾，先核对它指得到灌进来的那一槽、链指纹相同）+ `Salts`
//!    （[Step::Salts]）→ `ingest_settle(Rebuild)`（[Step::Rebuild]）→ 对拍（[Step::Parity]：G4 的口径 + 按规范 ID 的比较）。
//! 5. **对拍有一项不过（或某个 profile 的缓存基准拿不到）就中止**（[Outcome::Aborted]）：不提交、不封存，旧库原样可用；
//!    报告写到目录里的 [REPORT_FILE]，临时文件留作诊断（下次开跑时删掉重来）。同机多 profile 一个不过整个文件不提交
//!    （设计 §6.3）。
//! 6. **提交**（[Step::Commit]）：临时文件里记下迁移来源（`files::record_migrated_from`，设计 §6.1 第 7 步的「已核对」
//!    标记：身份 + 日志水位）→ 检查点并关掉（确认没有残留 WAL）→ 落盘 → 改名成 `srs4.db` 并落盘
//!    （`seal::rename_durable`）。**改名就是提交点。**
//! 7. **封存**（[Step::Seal]）：在持着的旧库写事务里把 `schema` 写成 39999（`seal::seal_legacy_locked`），提交
//!    （`synchronous = FULL`，返回前已落盘）。
//!
//! # 中断与续做（每一步之后被杀 / 断电，重跑结果相同）
//!
//! - **提交点之前**：旧库一个字节没写（前提补完写的是副本；前提核对、灌入、对拍都只读；写锁不改文件），临时文件与
//!   补完副本只是旧库的派生物（副本每次迁移结束都删、下次开跑前也删）。重跑
//!   **整个删掉临时文件从头来**，不在半份上续做：设计 §6.1 原写「第 3 步整份重扫、已有槽幂等」，可中断之后旧库可能又被
//!   协议 3 的版本写过（回退再升级），半份临时文件里的槽与旧库对不上时（例如旧库里那条后来被清成了空洞：秩不同本机一律
//!   不动），对拍会把它报成差异、把用户永远挡在迁移外。重扫本来就要整份读一遍旧库，省下的只是写入。
//! - **提交点之后、封存之前**：`srs4.db` 在、记着的迁移来源就是旁边这份没封存的 `srs.db`。重跑（或 Primary 打开，
//!   `files::open_gen4`）在锁里补封（`files::finish_seal`，幂等）。迁移来源记的是身份**和日志水位**
//!   （`seal::legacy_log_mark`）：这段窗口里写锁随进程一起没了，退回旧版本往 `srs.db` 写过东西的，水位对不上，不封、
//!   报「旁边有没迁移的协议 3 库」，那几笔写入不会被封进保留副本里丢掉。
//! - **封存落了盘、改名没有**（文件系统不守序时的兜底；改名本身用 `seal::rename_durable` 落盘后才封存）：`srs.db` 已
//!   封存进 `srs4.db`、`srs4.db` 不在、`srs4.db-migrating` 记的迁移来源就是它（[lost_rename]）。[status] 报
//!   [GenState::NeedsMigration]，重跑补做改名，报 [Outcome::Committed]（`recoveredRename`）。
//! - **封存之后**：重跑什么也不做，报 [Outcome::Committed]。
//!
//! 每一种断点都有子进程测试（`migrate_tests.rs`：子进程在指定步骤 `exit` 掉，父进程核对旧库可用、重跑结果与一次跑完的
//! 逐表相同）。
//!
//! # 不在这里的
//!
//! - 偏好里的 ID 归一（设计 §6.1 第 8 步）：Dart 侧（G9-6）。
//! - 保留副本到期换墓碑库：`seal::write_tombstone`，由 G7-5 / G10 按 D6 / D32 的口径调。

use std::cell::Cell;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use rusqlite::{Connection, ErrorCode, OpenFlags, OptionalExtension};
use serde_json::{Map, Value, json};

use super::dryrun::{
    self, CANCELLED, DEFAULT_EXAMPLES, Mode, SPACE_MARGIN, Stop, file_len, mb, now_ms, overall,
    peak_mem_mb, profile_blockers, profile_stages, secs, write_json_atomically,
};
use super::files::{self, GEN4_FILE, GEN4_TEMP, GenLock, LEGACY_FILE, OpenError, PREPARE_COPY};
use super::legacy;
use super::prepare;
use super::schema;
use super::truth::Truth;
use crate::store::schema::SCHEMA_VERSION;
use crate::store::seal::{self, SEALED_SCHEMA};
use crate::sync2::id::Id;

/// 迁移报告在 profile 目录里的文件名（中止时用户与诊断导出拿它；提交后留着备查）。只有计数与 ID，不含笔记内容。
pub const REPORT_FILE: &str = "srs4-migration-report.json";

/// 已删的 app 内换代前预演（G7-6 删）留在 profile 目录里的工作目录（名字冻结，旧 `dryrun::rehearsal_dir`）：里面是
/// `report.json`（只有计数与 ID），进程在预演中途被杀时还可能有临时新库 `gen4-dryrun.db`（旧库内容的副本）。没有别的
/// 代码会再碰它，迁移拿到换代锁后与前提补完副本一起删掉（[run]），彻底清除不在库外留内容副本。
pub(crate) const LEFTOVER_REHEARSAL_DIR: &str = "gen4-rehearsal";

/// 报告格式的版本。每个 profile 的报告与预演（`dryrun::REPORT_VERSION`）同形。
pub const REPORT_VERSION: i64 = 1;

/// 灌入每批条数（设计 §6.1 第 3 步：每 2 万条提交一批）。
pub const DEFAULT_BATCH: u64 = 20_000;

/// 进度的步骤（规划 §1.4 `SrsMigrationProgress.step`）。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Step {
    Space,
    Lock,
    /// 前提补完（G7-2b）：`done` / `total` 按要补的 profile 数报。
    Prepare,
    Precondition,
    Translate,
    Salts,
    Rebuild,
    Parity,
    Commit,
    Seal,
}

impl Step {
    /// 线上 / Dart 的名字。
    pub fn wire(self) -> &'static str {
        match self {
            Step::Space => "space",
            Step::Lock => "lock",
            Step::Prepare => "prepare",
            Step::Precondition => "precondition",
            Step::Translate => "translate",
            Step::Salts => "salts",
            Step::Rebuild => "rebuild",
            Step::Parity => "parity",
            Step::Commit => "commit",
            Step::Seal => "seal",
        }
    }
}

/// 一次 [run] 的结果（规划 §1.4 `SrsMigrationOutcome`，与 [Outcome::verdict] 一一对应）。跑不下去（IO、库坏了……）是
/// `Err`，这时旧库同样原样可用。
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    /// 提交了（含「之前已经提交、这次只补了封存 / 什么也不用做」，`report` 里 `resumed` 为真）。
    Committed { report: Value },
    /// 对拍不过：没提交、没封存。报告在 [report_path]，临时文件留作诊断。
    Aborted { report_path: PathBuf, report: Value },
    /// 前提补不了 / 迁移在别处进行 / 旧库正忙 / 状态不对：没有迁移，旧库没动（前提补完只写副本）。[code] 是机器可读的
    /// 分类（线上 `code`），[reason] 是给人看的原文。
    Blocked { code: BlockCode, reason: String },
    /// 空间不够：什么都没做。
    NoSpace { needed: u64, free: u64 },
    /// 调用方叫停（提交点之前）：临时文件删掉，旧库原样。
    Cancelled,
}

impl Outcome {
    pub fn verdict(&self) -> &'static str {
        match self {
            Outcome::Committed { .. } => "committed",
            Outcome::Aborted { .. } => "aborted",
            Outcome::Blocked { .. } => "blocked",
            Outcome::NoSpace { .. } => "noSpace",
            Outcome::Cancelled => "cancelled",
        }
    }

    /// 命令回包的形状：`{verdict, ...}`。
    pub fn json(&self) -> Value {
        let mut m = Map::new();
        m.insert("verdict".into(), json!(self.verdict()));
        match self {
            Outcome::Committed { report } => {
                m.insert("report".into(), report.clone());
            }
            Outcome::Aborted {
                report_path,
                report,
            } => {
                m.insert(
                    "reportPath".into(),
                    json!(report_path.display().to_string()),
                );
                m.insert("report".into(), report.clone());
            }
            Outcome::Blocked { code, reason } => {
                m.insert("code".into(), json!(code.wire()));
                m.insert("reason".into(), json!(reason));
            }
            Outcome::NoSpace { needed, free } => {
                m.insert("needed".into(), json!(needed));
                m.insert("free".into(), json!(free));
            }
            Outcome::Cancelled => {}
        }
        Value::Object(m)
    }
}

pub(super) fn blocked(code: BlockCode, reason: impl Into<String>) -> Outcome {
    Outcome::Blocked {
        code,
        reason: reason.into(),
    }
}

/// [Outcome::Blocked] 的机器可读分类（线上 `code`；Dart `SrsGen4BlockedReason` 只认它，不比原因原文）。线上名是持久的
/// 协议（Dart 测试读本文件核对），不改名。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlockCode {
    /// 换代锁在别的进程手里，或本进程里同一目录已经在跑（[BLOCKED_MIGRATING]）。等一会再来。
    Migrating,
    /// 旧库正被别的连接写（[BLOCKED_BUSY]）。等一会再来。
    Busy,
    /// 旧库里有 profile 没给缓存配置（`legacy::all_profiles` 里每个都要有；Dart 按 `gen4_migrate_profiles` 的 `profiles`
    /// 给）。调用方的 bug，补上再跑。
    MissingCacheConfig,
    /// 旧库的 schema 比这一版的协议 3 新（用更新的版本写过）：这一版读不了，要装新版本。
    SchemaNewer,
    /// `srs.db` 不是协议 3 的库（没有 `srs_meta.schema`）。
    NotProtocol3,
    /// 旧库文件坏了（SQLite 报库损坏 / 不是数据库，或写入前的完整性检查没过）：一个字节不写。
    Corrupt,
    /// 目录里没有可迁移的旧库（什么都没有，或只剩一份迁移临时文件）。
    NoLibrary,
    /// 旧库已封存、新代库却不在。
    SealedWithoutNew,
    /// 新代库旁边有一份没迁移的协议 3 库。
    LegacyBesideNew,
    /// 补完之后前提核对仍不过（不该出现：补完与核对判得不一样）。原因原文逐条列出。
    Precondition,
}

impl BlockCode {
    pub fn wire(self) -> &'static str {
        match self {
            BlockCode::Migrating => "migrating",
            BlockCode::Busy => "busy",
            BlockCode::MissingCacheConfig => "missingCacheConfig",
            BlockCode::SchemaNewer => "schemaNewer",
            BlockCode::NotProtocol3 => "notProtocol3",
            BlockCode::Corrupt => "corrupt",
            BlockCode::NoLibrary => "noLibrary",
            BlockCode::SealedWithoutNew => "sealedWithoutNew",
            BlockCode::LegacyBesideNew => "legacyBesideNew",
            BlockCode::Precondition => "precondition",
        }
    }
}

/// [Outcome::Blocked] 的原因：换代锁在别人手里。
pub const BLOCKED_MIGRATING: &str = "migrating: another process holds the generation lock";
/// [Outcome::Blocked] 的原因：旧库正被别的连接写（`BEGIN IMMEDIATE` 等满了忙等时限）。
pub const BLOCKED_BUSY: &str = "busy: the protocol 3 library is being written";

/// 迁移的参数。
pub struct Options<'a> {
    /// 每个 profile 的缓存配置（`CacheConfig` 的 JSON 文本，与 app 交给新代内核的同一份：规范 ID、不带盐，Dart
    /// `srsCacheConfigFor`）。**每个 profile 都要有**：没有它新代缓存层建不出内置笔记类型的行（前提里拦下）。对拍时
    /// 冻结的协议 3 重建要的带盐那份由内核按 profile uid 派生（`class.rs` `legacy_config_for`），调用方不拼盐。
    pub caches: &'a BTreeMap<String, String>,
    /// 灌入每批条数（[DEFAULT_BATCH]）。
    pub batch: u64,
    /// 本机墙钟（毫秒）：新身份的建立时刻、HLC 起点、报告时间戳。
    pub now_ms: i64,
    /// 中断开关（提交点之前有效）。
    pub stop: &'a Stop,
    /// 进度：(步骤, 已做, 总数)。灌入按条数报，其余按 profile 报。
    pub progress: &'a mut dyn FnMut(Step, u64, u64),
    /// 新身份的设备 ID：(profile, now_ms) → ID。生产用 [random_device]；测试给定值，好让重跑结果逐表可比。
    pub new_device: &'a dyn Fn(&str, i64) -> Id,
}

/// 新身份的设备 ID：随机的 UUIDv7（设计 §3.3：换代时每台设备给自己生成新的设备 ID）。
pub fn random_device(_profile: &str, now_ms: i64) -> Id {
    Id::new_v7(now_ms.max(0) as u64)
}

/// 一个 profile 目录的代际状态（规划 §1.4 `SrsGenState`）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GenState {
    /// 有新代库，或什么都没有（全新安装，Primary 打开时建库）。
    Ready,
    /// 有协议 3 的库要迁移。
    NeedsMigration,
    /// 别的进程拿着换代锁。
    MigratingElsewhere,
    /// 只有封存了的旧库（`srs4.db` 不见了）：迁移不了、也不能当新库用，要用户处理。
    SealedOldOnly,
    /// 上一次迁移对拍不过（报告在 [REPORT_FILE]，针对的就是旁边这份旧库），或只剩一份迁移临时文件、旧库不见了。
    MigrationFailed,
}

impl GenState {
    pub fn wire(self) -> &'static str {
        match self {
            GenState::Ready => "ready",
            GenState::NeedsMigration => "needsMigration",
            GenState::MigratingElsewhere => "migratingElsewhere",
            GenState::SealedOldOnly => "sealedOldOnly",
            GenState::MigrationFailed => "migrationFailed",
        }
    }
}

/// 只读打开（不建、不写），给判断状态用。
fn open_ro(path: &Path) -> Result<Connection, String> {
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(schema::sql)
}

/// 旧库 `srs_meta.schema` 的值（没有这张表 / 这一行 / 不是数 = None）。
fn legacy_schema(c: &Connection) -> Result<Option<i64>, String> {
    legacy_schema_raw(c).map_err(schema::sql)
}

fn legacy_schema_raw(c: &Connection) -> rusqlite::Result<Option<i64>> {
    let has: bool = c.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'srs_meta')",
        [],
        |r| r.get(0),
    )?;
    if !has {
        return Ok(None);
    }
    let v: Option<String> = c
        .query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| {
            r.get(0)
        })
        .optional()?;
    Ok(v.and_then(|v| v.parse().ok()))
}

/// SQLite 报的是「库坏了 / 不是数据库」。
pub(super) fn is_corrupt(e: &rusqlite::Error) -> bool {
    matches!(
        e.sqlite_error_code(),
        Some(ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase)
    )
}

/// 旧库 `srs_meta.schema` 的值；文件坏了（读不出页头 / schema 表）= `Err(Ok(原因))`，其余读不了 = `Err(Err(..))`。
fn probe_schema(path: &Path) -> Result<Option<i64>, Result<String, String>> {
    let c = open_ro(path).map_err(Err)?;
    legacy_schema_raw(&c).map_err(|e| {
        if is_corrupt(&e) {
            Ok(format!("srs.db is damaged: {e}"))
        } else {
            Err(schema::sql(e))
        }
    })
}

/// 本次迁移要给缓存配置的 profile：旧库里全部有数据的 profile（`legacy::all_profiles`，含只在投影表里的孤儿 uid）。
/// 全局命令 `gen4_migrate_profiles` 回给 Dart（只读，开读快照、读完即关；每张表按 profile 跳着取，profile 数 × 一次索引
/// 查找，但仍是毫秒级以上的磁盘读，Dart 在后台 isolate 调）。
pub fn legacy_profiles(dir: &Path) -> Result<Vec<String>, String> {
    let src = dryrun::open_legacy(&dir.join(LEGACY_FILE))?;
    let out = legacy::all_profiles(&src);
    let _ = src.execute_batch("ROLLBACK");
    out
}

/// [dir] 的代际状态（只读；会建出锁文件——要试锁才分得清「迁移中」）。
pub fn status(dir: &Path) -> Result<GenState, String> {
    if dir.join(GEN4_FILE).exists() {
        return Ok(GenState::Ready);
    }
    match GenLock::try_acquire(dir)? {
        None => return Ok(GenState::MigratingElsewhere),
        Some(lock) => drop(lock),
    }
    let legacy = dir.join(LEGACY_FILE);
    if !legacy.exists() {
        return Ok(if dir.join(GEN4_TEMP).exists() {
            GenState::MigrationFailed
        } else {
            GenState::Ready
        });
    }
    let c = open_ro(&legacy)?;
    if legacy_schema(&c)? == Some(SEALED_SCHEMA) {
        drop(c);
        // 改名没落盘、封存落了盘（[lost_rename]）：[run] 补做改名即可，按「要迁移」报，让调用方去跑它。
        return Ok(if lost_rename(dir)? {
            GenState::NeedsMigration
        } else {
            GenState::SealedOldOnly
        });
    }
    // 报告针对的是不是旁边这份旧库：按身份认（报告的 `legacyIdentity`）。原件没有协议 3 身份时报告里记的是 null，
    // 与这里的 None 相等也算——认不出「是不是同一份」，但当成「上次失败」只多一次手动重试（恢复页给「重新升级」），
    // 当成「要迁移」则服务端每次启动都自动重迁、每次再中止（交接 §11 已知项，第五波修）。按内容摘要认要扫整个旧库，
    // 不能放进 UI isolate 上轮询的状态命令。
    let identity = seal::legacy_identity(&c)?;
    let failed = std::fs::read_to_string(dir.join(REPORT_FILE))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .is_some_and(|r| {
            r["verdict"] == "aborted" && r["legacyIdentity"].as_str() == identity.as_deref()
        });
    Ok(if failed {
        GenState::MigrationFailed
    } else {
        GenState::NeedsMigration
    })
}

/// 第 1 步要的空间（字节）：旧库 × 0.3 + 旧缓存三张表（含索引）的现有体积 + 余量。
fn space_needed(legacy: &Path) -> Result<u64, String> {
    let c = open_ro(legacy)?;
    let mut baseline = 0u64;
    for table in ["srs_notes_cache", "srs_cards_cache", "srs_stat_reviews"] {
        let names: Vec<String> = c
            .prepare("SELECT name FROM sqlite_schema WHERE tbl_name = ?1 AND rootpage > 0")
            .map_err(schema::sql)?
            .query_map([table], |r| r.get(0))
            .map_err(schema::sql)?
            .collect::<Result<_, _>>()
            .map_err(schema::sql)?;
        for name in names {
            // 没编 dbstat 的库量不出来：这一项按 0 算（旧库 × 0.3 已经按最大的样本库留了余量）。
            let Ok(n) = c.query_row(
                "SELECT COALESCE(SUM(pgsize), 0) FROM dbstat WHERE name = ?1",
                [&name],
                |r| r.get::<_, i64>(0),
            ) else {
                continue;
            };
            baseline += n.max(0) as u64;
        }
    }
    Ok(file_len(legacy) * 3 / 10 + baseline + SPACE_MARGIN)
}

/// 临时文件（含 `-wal` / `-shm`）占的字节。
fn temp_bytes(tmp: &Path) -> u64 {
    ["", "-wal", "-shm"]
        .iter()
        .map(|s| file_len(&seal::with_suffix(tmp, s)))
        .sum()
}

/// 补完副本在空间核对时的身份（[reclaimable]）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PrepCopy {
    /// 上一次留下的、开跑前会删掉的：算可用空间。
    Stale,
    /// 这一次补完出来、之后的阶段还要读的：**不算**可用空间（G7-2b 复核遗留：补完之后的第二次核对曾把它算成可用，
    /// 副本有多大就多报多大的可用空间）。
    InUse,
}

/// 核对空间时可以算进可用空间的字节：上一次留下的迁移临时文件（开跑前删掉），加上 [copy] 为 [PrepCopy::Stale] 时的补完副本。
fn reclaimable(dir: &Path, copy: PrepCopy) -> u64 {
    let stale_copy = match copy {
        PrepCopy::Stale => temp_bytes(&dir.join(PREPARE_COPY)),
        PrepCopy::InUse => 0,
    };
    temp_bytes(&dir.join(GEN4_TEMP)) + stale_copy
}

/// 第 1 步的空间核对：[source]（之后读的那份旧库）要的空间再加 [extra]，不够 = [Outcome::NoSpace]。上一次留下的临时
/// 文件算可用空间（开跑前会删掉）；补完副本只在它是上一次留下的时候算（[PrepCopy]）。前提补完要拷副本（[extra] = 原件
/// 连同 WAL 的大小），补完之后按副本（变大了）再核一次——那时副本在用，不算可用。
fn check_space(
    dir: &Path,
    source: &Path,
    extra: u64,
    copy: PrepCopy,
) -> Result<Option<Outcome>, String> {
    let needed = space_needed(source)? + extra;
    if let Some(free) = free_bytes(dir) {
        let free = free + reclaimable(dir, copy);
        if free < needed {
            return Ok(Some(Outcome::NoSpace { needed, free }));
        }
    }
    Ok(None)
}

/// [check_space] 量的可用空间。测试可以经 [FREE_BYTES] 注入（按调用现算：要在补完副本出来之后按它的大小卡边界）。
fn free_bytes(dir: &Path) -> Option<u64> {
    #[cfg(test)]
    if let Some(v) = FREE_BYTES.with(|f| f.borrow_mut().as_mut().map(|f| f(dir))) {
        return v;
    }
    crate::store::compact::free_bytes(dir)
}

/// [free_bytes] 的测试注入点（每个线程一份；`None` = 量真实磁盘）。
#[cfg(test)]
pub(crate) type FreeBytesHook = Box<dyn FnMut(&Path) -> Option<u64>>;

#[cfg(test)]
thread_local! {
    pub(crate) static FREE_BYTES: std::cell::RefCell<Option<FreeBytesHook>> =
        const { std::cell::RefCell::new(None) };
}

/// 临时新库连接刚建好（schema 已装、还没写任何数据）时的测试注入点：测试借它给这个连接设限（如
/// `PRAGMA max_page_count`，让之后的写入在中途撞上真的 `SQLITE_FULL`），验证「写到一半出错」时旧库不变、临时件清掉。
#[cfg(test)]
pub(crate) type StageConnHook = Box<dyn FnMut(&Connection)>;

#[cfg(test)]
thread_local! {
    pub(crate) static STAGE_CONN: std::cell::RefCell<Option<StageConnHook>> =
        const { std::cell::RefCell::new(None) };
}

/// 一次迁移要的空间（[check_space] 的 `needed` 去掉 `extra`；测试据此卡边界）。
#[cfg(test)]
pub(crate) fn space_needed_for_tests(source: &Path) -> Result<u64, String> {
    space_needed(source)
}

/// 对旧库开写事务并持住（不写任何东西）。旧库正被别的连接写、等满忙等时限 = None。
pub(super) fn hold_legacy(path: &Path) -> Result<Option<Connection>, String> {
    let c = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(schema::sql)?;
    c.busy_timeout(schema::BUSY_TIMEOUT).map_err(schema::sql)?;
    // 这个连接只写封存那一笔：提交时 fsync（seal.rs 文件头：改名已经落盘而封存丢了，旧版本就会把没封存的库当正常库写）。
    c.execute_batch("PRAGMA synchronous = FULL;")
        .map_err(schema::sql)?;
    match c.execute_batch("BEGIN IMMEDIATE") {
        Ok(()) => Ok(Some(c)),
        Err(e)
            if matches!(
                e.sqlite_error_code(),
                Some(ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked)
            ) =>
        {
            Ok(None)
        }
        Err(e) => Err(schema::sql(e)),
    }
}

/// 迁移 [dir] 里的 `srs.db`（文件头的七步）。
pub fn run(dir: &Path, opts: Options<'_>) -> Result<Outcome, String> {
    let legacy = dir.join(LEGACY_FILE);
    let gen4 = dir.join(GEN4_FILE);
    let tmp = dir.join(GEN4_TEMP);
    (opts.progress)(Step::Space, 0, 1);
    if !gen4.exists() {
        if !legacy.exists() {
            return Ok(blocked(
                BlockCode::NoLibrary,
                if tmp.exists() {
                    "a migration temp file is left but the protocol 3 library is gone"
                } else {
                    "there is no protocol 3 library to migrate"
                },
            ));
        }
        match probe_schema(&legacy) {
            Ok(_) => {}
            Err(Ok(damaged)) => return Ok(blocked(BlockCode::Corrupt, damaged)),
            Err(Err(e)) => return Err(e),
        }
        if let Some(out) = check_space(dir, &legacy, 0, PrepCopy::Stale)? {
            return Ok(out);
        }
    }
    (opts.progress)(Step::Lock, 0, 1);
    let Some(lock) = GenLock::try_acquire(dir)? else {
        return Ok(blocked(BlockCode::Migrating, BLOCKED_MIGRATING));
    };
    // 上一次崩溃留下的前提补完副本：不论接下来走哪条路都用不上了（补完每次从原件重拷）。已删的换代前预演的工作目录
    // 同样（[LEFTOVER_REHEARSAL_DIR]）。
    if let Err(e) = seal::remove_sqlite_files(&dir.join(PREPARE_COPY))
        .and_then(|()| remove_leftover_rehearsal(dir))
    {
        drop(lock);
        return Err(e);
    }
    let out = if gen4.exists() {
        resume_after_commit(dir)
    } else {
        migrate_locked(dir, opts)
    };
    drop(lock);
    out
}

/// 删掉 [LEFTOVER_REHEARSAL_DIR]（不在就算删过）。两处调：迁移拿到换代锁之后（[run]），以及新代库按 Primary 打开时
/// （kernel.rs `G4Core::open`）——在早期预发布版上已经迁移完、或迁移在拿锁之前就被挡住的用户，不再走 [run] 拿锁
/// 那一步，预演目录（里面可能有一份旧库内容的副本）要靠开库清掉。
pub(crate) fn remove_leftover_rehearsal(dir: &Path) -> Result<(), String> {
    let work = dir.join(LEFTOVER_REHEARSAL_DIR);
    match std::fs::remove_dir_all(&work) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("gen4 migrate: remove {}: {e}", work.display())),
    }
}

/// 封存落了盘、改名没落盘：`srs4.db` 不在，`srs.db` 已封存进 `srs4.db`，旁边的 `srs4.db-migrating` 是一份建好的
/// 新代库（没有残留 WAL）、记着的迁移来源（身份与日志水位，`files::migrated_from_is`）就是这份旧库。提交步骤里
/// 迁移来源只在对拍全过之后、临时文件落盘之前写进去，封存只在改名之后做，所以满足这几条的临时文件就是那次已经提交的
/// 新代库，补做改名即可。Windows 上改名带 `MOVEFILE_WRITE_THROUGH`、Unix 上改名后目录 fsync，本不该走到这里；这是
/// 文件系统不守序时的兜底。只读。
fn lost_rename(dir: &Path) -> Result<bool, String> {
    let tmp = dir.join(GEN4_TEMP);
    if dir.join(GEN4_FILE).exists() || !tmp.exists() || seal::with_suffix(&tmp, "-wal").exists() {
        return Ok(false);
    }
    let old = open_ro(&dir.join(LEGACY_FILE))?;
    if legacy_schema(&old)? != Some(SEALED_SCHEMA) {
        return Ok(false);
    }
    let into: Option<String> = old
        .query_row(
            "SELECT value FROM srs_meta WHERE key = 'sealed_into'",
            [],
            |r| r.get(0),
        )
        .optional()
        .map_err(schema::sql)?;
    if into.as_deref() != Some(GEN4_FILE) {
        return Ok(false);
    }
    let Ok(new) = files::open_ready(&tmp) else {
        return Ok(false);
    };
    let same = files::migrated_from_is(&new, &old)?;
    new.close().map_err(|(_, e)| schema::sql(e))?;
    Ok(same)
}

/// 新代库已经在（拿着换代锁）：之前提交过。旁边的 `srs.db` 若就是迁移来源、还没封存，补封（提交点之后中断的续做）。
fn resume_after_commit(dir: &Path) -> Result<Outcome, String> {
    let new = files::open_ready(&dir.join(GEN4_FILE))?;
    let r = files::finish_seal(dir, &new);
    drop(new);
    match r {
        Ok(retained) => Ok(Outcome::Committed {
            report: json!({
                "version": REPORT_VERSION,
                "verdict": "committed",
                "resumed": true,
                "retainedCopyUnreadable": retained == files::Retained::Unreadable,
            }),
        }),
        Err(OpenError::LegacyNotMigrated) if empty_source(dir)? => {
            let rw = Connection::open_with_flags(
                dir.join(LEGACY_FILE),
                OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
            )
            .map_err(schema::sql)?;
            seal::seal_legacy(&rw, GEN4_FILE)?;
            rw.close().map_err(|(_, e)| schema::sql(e))?;
            Ok(Outcome::Committed {
                report: json!({"version": REPORT_VERSION, "verdict": "committed", "resumed": true}),
            })
        }
        Err(OpenError::LegacyNotMigrated) => Ok(blocked(
            BlockCode::LegacyBesideNew,
            "srs4.db already exists next to an unmigrated protocol 3 library",
        )),
        Err(e) => Err(e.to_string()),
    }
}

/// 新代库没记迁移来源、旁边的 `srs.db` 也没有身份：是不是「从一份空的协议 3 库迁来、封存前中断」——旧库里一个协议 3
/// profile 都没有、也没有任何投影数据（[legacy::library_blockers] 为空），新代库里一个集合都没有。是才补封：封了也不会
/// 把任何数据标成「已迁入」。
fn empty_source(dir: &Path) -> Result<bool, String> {
    let new = files::open_ready(&dir.join(GEN4_FILE))?;
    let unmarked: bool = new
        .query_row(
            "SELECT NOT EXISTS(SELECT 1 FROM srs_meta WHERE key = ?1) \
             AND NOT EXISTS(SELECT 1 FROM collections)",
            [files::MIGRATED_FROM_KEY],
            |r| r.get(0),
        )
        .map_err(schema::sql)?;
    drop(new);
    if !unmarked {
        return Ok(false);
    }
    let src = dryrun::open_legacy(&dir.join(LEGACY_FILE))?;
    let empty = legacy_schema(&src)? == Some(SCHEMA_VERSION)
        && seal::legacy_identity(&src)?.is_none()
        && legacy::profiles(&src)?.is_empty()
        && legacy::library_blockers(&src)?.is_empty();
    let _ = src.execute_batch("ROLLBACK");
    Ok(empty)
}

/// 迁移原样带进新代库 `srs_meta` 的协议 3 库级键（G9-5）：
///
/// - `profile_merge/<旧 uid>`（并入做到一半的标记，值 `{profileId, newUid}`）：新代里由 Dart 发 `profile_merge_commit`
///   收尾（`cmd/profile_data.rs`），扫无主数据时据此不动并入涉及的 uid；
/// - `srs_retired_v2_devices` / `srs_retired_profile_uids`（`meta_set_edit` 的两个集合，profile 链接记「本机退役的 v2
///   设备身份 / 离开的旧 uid」，清同步位置上本机留下的旧目录用）。
///
/// 只认这几个键（不按前缀猜别的）；值原样。读 [src] 的 `srs_meta`（没有这张表 = 什么都不带）。
pub(super) const CARRIED_META_SQL: &str = "SELECT key, value FROM srs_meta WHERE \
     (key >= 'profile_merge/' AND key < 'profile_merge0') \
     OR key IN ('srs_retired_v2_devices', 'srs_retired_profile_uids') ORDER BY key";

/// 把 [CARRIED_META_SQL] 选出的键从协议 3 库 [src] 原样写进新代库 [dst]。
pub(crate) fn carry_library_meta(src: &Connection, dst: &Connection) -> Result<usize, String> {
    let has_meta: bool = src
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'srs_meta')",
            [],
            |r| r.get(0),
        )
        .map_err(schema::sql)?;
    if !has_meta {
        return Ok(0);
    }
    let rows: Vec<(String, String)> = src
        .prepare(CARRIED_META_SQL)
        .map_err(schema::sql)?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(schema::sql)?
        .collect::<Result<_, _>>()
        .map_err(schema::sql)?;
    for (key, value) in &rows {
        dst.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value],
        )
        .map_err(schema::sql)?;
    }
    Ok(rows.len())
}

/// 拿着换代锁、还没有新代库：第 2 步后半起。
fn migrate_locked(dir: &Path, mut opts: Options<'_>) -> Result<Outcome, String> {
    let legacy = dir.join(LEGACY_FILE);
    let tmp = dir.join(GEN4_TEMP);
    let version = match probe_schema(&legacy) {
        Ok(v) => v,
        Err(Ok(damaged)) => return Ok(blocked(BlockCode::Corrupt, damaged)),
        Err(Err(e)) => return Err(e),
    };
    {
        match version {
            // 这一版协议 3 的库，或更老、协议 3 的升级阶梯升得上来的（前提补完里由 `SrsCore::open` 升）。
            Some(v) if (1..=SCHEMA_VERSION).contains(&v) => {}
            Some(v) if v == SEALED_SCHEMA => {
                if !lost_rename(dir)? {
                    return Ok(blocked(
                        BlockCode::SealedWithoutNew,
                        "the protocol 3 library is sealed but srs4.db is missing",
                    ));
                }
                seal::rename_durable(&tmp, &dir.join(GEN4_FILE))?;
                // 核对时打开过它：别留下属于旧名字的 `-shm`。
                let _ = seal::remove_sqlite_files(&tmp);
                return match resume_after_commit(dir)? {
                    Outcome::Committed { mut report } => {
                        report["recoveredRename"] = json!(true);
                        Ok(Outcome::Committed { report })
                    }
                    other => Ok(other),
                };
            }
            Some(v) if v > SCHEMA_VERSION => {
                return Ok(blocked(
                    BlockCode::SchemaNewer,
                    format!(
                        "the protocol 3 library is at schema {v}, newer than this build's protocol 3 \
                         (schema {SCHEMA_VERSION}); install a newer version"
                    ),
                ));
            }
            _ => {
                return Ok(blocked(
                    BlockCode::NotProtocol3,
                    "srs.db is not a protocol 3 library",
                ));
            }
        }
    }
    let version = version.unwrap_or(0);
    // 原件的写锁：从这里持到封存（不写任何东西）。前提补完只写副本，之后谁也写不进原件，对拍核对过的就是封存的全部。
    let Some(held) = hold_legacy(&legacy)? else {
        return Ok(blocked(BlockCode::Busy, BLOCKED_BUSY));
    };
    let copy = dir.join(PREPARE_COPY);
    let out = prepare_and_stage(dir, &held, version, &mut opts);
    if !held.is_autocommit() {
        // 没走到封存（中止、拦下、出错、叫停）：放开写锁，什么都没写。
        let _ = held.execute_batch("ROLLBACK");
    }
    drop(held);
    // 补完副本不论结论都删（提交了的已经封存原件、记的是原件的指纹；没提交的下次从原件重拷）。
    let _ = seal::remove_sqlite_files(&copy);
    match &out {
        Ok(Outcome::Aborted { .. }) => {}
        Ok(Outcome::Committed { .. }) => {}
        // 拦下、叫停、出错：临时文件没有诊断价值，删掉。
        _ => {
            let _ = seal::remove_sqlite_files(&tmp);
        }
    }
    out
}

/// 拿着换代锁与原件的写锁 [held]：3. 前提补完（只读核对要补什么；要补才拷副本、在副本上用协议 3 的内核补）→ 读快照
/// （副本或原件）→ [with_snapshot]。
fn prepare_and_stage(
    dir: &Path,
    held: &Connection,
    version: i64,
    opts: &mut Options<'_>,
) -> Result<Outcome, String> {
    let legacy = dir.join(LEGACY_FILE);
    (opts.progress)(Step::Prepare, 0, 1);
    let plan = {
        let src = dryrun::open_legacy(&legacy)?;
        let plan = prepare::plan(&src, version, opts.caches);
        let _ = src.execute_batch("ROLLBACK");
        plan?
    };
    let plan = match plan {
        Ok(plan) => plan,
        Err(out) => return Ok(out),
    };
    let source = if plan.is_empty() {
        legacy.clone()
    } else {
        // 副本要一份原件（连同 WAL）的空间。
        let whole = file_len(&legacy) + file_len(&seal::with_suffix(&legacy, "-wal"));
        if let Some(out) = check_space(dir, &legacy, whole, PrepCopy::Stale)? {
            return Ok(out);
        }
        let copy = match prepare::complete(dir, &plan, opts)? {
            Ok(copy) => copy,
            Err(out) => return Ok(out),
        };
        // 补完的副本（升级、包进旧行之后变大了）：之后的阶段按它再核一次空间。
        if let Some(out) = check_space(dir, &copy, 0, PrepCopy::InUse)? {
            return Ok(out);
        }
        copy
    };
    // 拿到写锁之后才开读快照：此后谁也提交不进原件；副本只有这里读。
    let src = dryrun::open_legacy(&source)?;
    // 原件的读快照：迁移来源的身份与指纹按它记（没补完时与 `src` 是同一份文件的两个快照，内容相同）。
    let origin = match dryrun::open_legacy(&legacy) {
        Ok(c) => c,
        Err(e) => {
            let _ = src.execute_batch("ROLLBACK");
            return Err(e);
        }
    };
    // `src` 交给 with_snapshot（它负责回滚、关闭）。
    let out = with_snapshot(dir, held, src, &origin, opts);
    let _ = origin.execute_batch("ROLLBACK");
    out
}

/// 拿着原件的写锁 [held] 与读快照 [src]（补完过 = 副本上的，否则原件上的）：前提 → 临时文件里的阶段 → 中止或提交 →
/// 封存。[origin] 是原件的读快照：迁移来源的身份与指纹（报告、`files::record_migrated_from`）都按原件记——封存与补封
/// 针对的是原件。
fn with_snapshot(
    dir: &Path,
    held: &Connection,
    src: Connection,
    origin: &Connection,
    opts: &mut Options<'_>,
) -> Result<Outcome, String> {
    let started = Instant::now();
    let (peak0, _) = peak_mem_mb();
    let legacy = dir.join(LEGACY_FILE);
    let tmp = dir.join(GEN4_TEMP);
    opts.stop.attach(&src);
    let finish = |src: Connection, stop: &Stop| {
        let _ = src.execute_batch("ROLLBACK");
        drop(src);
        stop.detach_all();
    };
    // 3. 前提。
    (opts.progress)(Step::Precondition, 0, 1);
    let checked = (|| -> Result<(Vec<String>, Vec<String>, Option<String>), String> {
        let mut blockers = legacy::library_blockers(&src)?;
        let profiles = legacy::profiles(&src)?;
        for p in &profiles {
            let (hard, later) = profile_blockers(&src, p, opts.caches)?;
            blockers.extend(hard.into_iter().chain(later).map(|b| format!("{p}: {b}")));
        }
        Ok((profiles, blockers, seal::legacy_identity(origin)?))
    })();
    let (profiles, blockers, identity) = match checked {
        Ok(v) => v,
        Err(e) => {
            finish(src, opts.stop);
            return Err(e);
        }
    };
    if !blockers.is_empty() {
        finish(src, opts.stop);
        return Ok(blocked(BlockCode::Precondition, blockers.join("; ")));
    }
    let mut report = Map::new();
    report.insert("version".into(), json!(REPORT_VERSION));
    report.insert("startedAtMs".into(), json!(opts.now_ms));
    report.insert("legacyIdentity".into(), json!(identity));
    report.insert("oldBytes".into(), json!(file_len(&legacy)));
    report.insert("peakMbAtStart".into(), json!(mb(peak0)));

    // 4. 临时文件里的阶段。上一次留下的（中止的诊断件、被杀留下的半份）整个删掉从头来（文件头「中断与续做」）。
    let staged = (|| -> Result<Staged, String> {
        seal::remove_sqlite_files(&tmp)?;
        let dst = schema::open(&tmp)?;
        #[cfg(test)]
        STAGE_CONN.with(|h| h.borrow_mut().as_mut().map(|h| h(&dst)));
        opts.stop.attach(&dst);
        let profiles_json = stage_all(&src, &dst, &profiles, opts)?;
        Ok(Staged { dst, profiles_json })
    })();
    let staged = match staged {
        Ok(s) => s,
        Err(e) => {
            finish(src, opts.stop);
            return if e == CANCELLED || opts.stop.stopped() {
                Ok(Outcome::Cancelled)
            } else {
                Err(e)
            };
        }
    };
    let verdicts: Vec<&str> = staged
        .profiles_json
        .iter()
        .filter_map(|p| p["verdict"].as_str())
        .collect();
    let verdict = overall(&verdicts);
    report.insert(
        "profiles".into(),
        Value::Array(staged.profiles_json.clone()),
    );
    report.insert("profileVerdict".into(), json!(verdict));
    // 空库（一个 profile 都没有）与全过才提交；`blocked` 在前提里已经拦过，这里出现只能是前提与阶段判得不一样（bug）。
    if verdict != "pass" && verdict != "empty" {
        drop(staged.dst);
        finish(src, opts.stop);
        let (peak1, _) = peak_mem_mb();
        report.insert("peakMb".into(), json!(mb(peak1)));
        report.insert("elapsedS".into(), json!(secs(started)));
        report.insert("verdict".into(), json!("aborted"));
        let report = Value::Object(report);
        let report_path = dir.join(REPORT_FILE);
        write_json_atomically(&report_path, &report)?;
        return Ok(Outcome::Aborted {
            report_path,
            report,
        });
    }

    // 6. 提交。
    (opts.progress)(Step::Commit, 0, 1);
    if opts.stop.stopped() {
        drop(staged.dst);
        finish(src, opts.stop);
        return Ok(Outcome::Cancelled);
    }
    let committed = (|| -> Result<(), String> {
        let dst = staged.dst;
        // 协议 3 库级的本机记录：半截并入的标记、profile 链接记的两个集合（[carry_library_meta]）。
        carry_library_meta(origin, &dst)?;
        // 记原件的指纹（没有身份的原件记内容摘要，`files::source_mark`）：补封核对的是原件。
        files::record_migrated_from(&dst, origin)?;
        // 迁移提交的时刻：从没同步成功过的用户，保留副本按它到期（`retained.rs`，D32）。
        super::retained::record_migrated_at(&dst, opts.now_ms)?;
        dst.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
            .map_err(schema::sql)?;
        dst.close().map_err(|(_, e)| schema::sql(e))?;
        if seal::with_suffix(&tmp, "-wal").exists() {
            return Err("gen4 migrate: the new library's WAL was not checkpointed".to_owned());
        }
        std::fs::OpenOptions::new()
            .write(true)
            .open(&tmp)
            .and_then(|f| f.sync_all())
            .map_err(|e| format!("gen4 migrate: sync {}: {e}", tmp.display()))?;
        Ok(())
    })();
    finish(src, opts.stop);
    committed?;
    let new_bytes = file_len(&tmp);
    let gen4 = dir.join(GEN4_FILE);
    // 改名并落盘（Unix：目录 fsync；Windows：MOVEFILE_WRITE_THROUGH）。落盘之后才封存：不然断电后可能只剩封存了的
    // 旧库与没改过名的临时文件（[lost_rename] 认得出、能补，但不该依赖它）。
    let synced = seal::rename_durable(&tmp, &gen4);
    if let Err(e) = &synced {
        if !gen4.exists() {
            return Err(e.clone());
        }
    }
    // ---- 提交点 ----
    report.insert("newBytes".into(), json!(new_bytes));

    // 7. 封存（同一个写事务，提交即落盘）。失败不撤销提交：下次打开 / 重跑补封（files::finish_seal）。
    (opts.progress)(Step::Seal, 0, 1);
    let sealed = synced
        .and_then(|()| seal::seal_legacy_locked(held, GEN4_FILE))
        .and_then(|_| held.execute_batch("COMMIT").map_err(schema::sql));
    report.insert("sealed".into(), json!(sealed.is_ok()));
    if let Err(e) = &sealed {
        report.insert("sealError".into(), json!(e));
    }
    let (peak1, _) = peak_mem_mb();
    report.insert("peakMb".into(), json!(mb(peak1)));
    report.insert("elapsedS".into(), json!(secs(started)));
    report.insert("finishedAtMs".into(), json!(now_ms()));
    report.insert("verdict".into(), json!("committed"));
    let report = Value::Object(report);
    // 报告写不下来不影响已经提交的迁移。
    let _ = write_json_atomically(&dir.join(REPORT_FILE), &report);
    Ok(Outcome::Committed { report })
}

struct Staged {
    dst: Connection,
    profiles_json: Vec<Value>,
}

/// 逐 profile 跑 `dryrun::profile_stages`（[Mode::Migration]），把阶段名换成 [Step] 报进度。某个 profile 出错（不是
/// 对拍不过）整个停下：已经不可能提交了。
fn stage_all(
    src: &Connection,
    dst: &Connection,
    profiles: &[String],
    opts: &mut Options<'_>,
) -> Result<Vec<Value>, String> {
    let t = Truth::new(dst);
    let mut total = 0u64;
    for p in profiles {
        for d in legacy::devices(src, p)? {
            total += d.applied + d.pending;
        }
    }
    let n = profiles.len() as u64;
    let at = Cell::new(0u64);
    let done = Cell::new(0u64);
    let batch = opts.batch.max(1);
    let progress = &mut *opts.progress;
    let mut note = |stage: &str, _profile: Option<&str>| match stage {
        "import" | "local" => progress(Step::Translate, done.get().min(total), total),
        "batch" => {
            done.set(done.get() + batch);
            progress(Step::Translate, done.get().min(total), total);
        }
        "salts" => progress(Step::Salts, at.get(), n),
        "rebuild" => progress(Step::Rebuild, at.get(), n),
        "compare" | "checks" => progress(Step::Parity, at.get(), n),
        _ => {}
    };
    let mode = Mode::Migration {
        now_ms: opts.now_ms,
        new_device: opts.new_device,
    };
    let mut stage_opts = dryrun::Options {
        caches: opts.caches,
        batch,
        keep: true,
        examples: DEFAULT_EXAMPLES,
        full_examples: false,
        stop: opts.stop,
        progress: &mut note,
    };
    let mut out = Vec::with_capacity(profiles.len());
    for p in profiles {
        opts.stop.check()?;
        out.push(profile_stages(src, &t, p, &mut stage_opts, &mode)?);
        at.set(at.get() + 1);
    }
    Ok(out)
}

#[cfg(test)]
#[path = "migrate_tests.rs"]
mod tests;
