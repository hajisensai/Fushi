//! 真实库干跑（设计 §6.1、§8 G4 / G4b）：**旧库只读** → 临时新库 → `rebuild_all` → 对拍报告。
//!
//! 迁移（G7）要做的前五步在这里原样走一遍，只是不提交：
//!
//! 1. 旧库用只读连接打开（`SQLITE_OPEN_READ_ONLY`；WAL 下读者照常更新 `-shm` 里的读标记，那不是库内容），整个干跑在一个读事务里，看到的是同一个快照——
//!    app 同时在写也不影响结果，也不会被它拖住（WAL 下读不挡写；代价是干跑期间 WAL 并不回去，结束后照常）。
//!    旧库一个字节不写：协议 3 一侧的缓存重建写进同名的**临时表**（`temp` 库里的同名表遮住 `main` 的，见 [old_caches]）。
//! 2. 先过 `legacy::preflight`（换代前必须在旧代码上做完的事）；没做完的 profile 报 `blocked`、不往下走。
//! 3. 按 profile 把操作日志转译、灌进工作目录里的临时新代文件（`import.rs`），带上本机状态（`carry.rs`），由一台假想的
//!    迁移设备（占位钥匙）建身份、经原生写入者在它的原生日志里写一条 `Salts`（本机 uid ∪ 已退役 uid，§6.1 第 4 步），再
//!    `rebuild_all`（索引、别名、摘要、缓存全程）。
//!
//! 第 2–5 步是 [profile_stages]，真迁移（`migrate.rs`，G7-2）调的是同一个函数，只有 [Mode] 的两处不同：新身份（真迁移
//! 是新设备 ID + 沿用的签名钥匙 + 指向旧设备的 `prev`）与真迁移才拦的前提（[profile_blockers]：收段留下的待重放 / 待
//! 刷新、没给缓存配置；预演只在 `migrationBlockers` 里报）。
//! 4. 对拍（`compare.rs`，与测试装置同一份比法）。基准是**冻结的旧代码对旧库全量重建出来的缓存**，不是旧库里现成的
//!    缓存表（它允许过期）；现成的与重建的另比一次，单列（§10 第 7 条，不计入判定）。协议 3 自己还欠着收尾的卡与笔记
//!    （待重放集合、没刷新的合成标签行）只读连接上做不了，跳过并计数。旧代码重放改写过、再没改回来的日志结果（没有 `sc` 的
//!    日志，投影行结果 ≠ 它操作里作者给的，`stale.rs` 逐条佐证）在影子日志表上改回、按协议 3 的重放重放后再重建，
//!    报 `oldSideStaleResults`。
//! 5. 在对拍之外再按规范 ID 比（§6.1 第 5 步、§5.3）：每个寄存器的胜者、每张规范卡的调度状态、每张规范卡（含不在缓存
//!    里的历史血统卡）名下的规范日志与有效复习。缓存层本身按规范 ID 物化，第 4 步的缓存三类也是按规范 ID 比的
//!    （协议 3 一侧的行先改写成规范 ID，`compare.rs` 文件头「按规范 ID 比」）。
//! 6. 按类判定的已知差异（§5.3「按类判定的已知差异」、§10 第 24 条，G9-2）：寄存器按别名类判与原值判不同的，逐条列出
//!    并逐条佐证（`knownDifferences`）。佐证得了的不计入判定，缓存行里只盖它们真喂得到的列（`compare::known_effect`），
//!    行的其余列照比、照计入判定。佐证不了的计入对拍差异
//!    （`classRegisters`），结论是 `fail`。只有 ID、写入者名与 seq，不含内容；任何一份库都能重跑（命令行
//!    `examples/gen4_dryrun.rs`）。
//!
//! 另外几项只报数、不计入判定：旧戳闭包对 `sync2_legacy`（§10 第 14 条）、归回去的改名写入者的旧戳逐条对照（G3 没验的
//! 第一项）、验不上的日志重建后是否仍挂在同一张规范卡上（G3 没验的第二项）、别名表各类的数（与 G3 探针同口径）。
//!
//! 可中断：[Stop::stop] 置位并打断两条连接上正在跑的语句；灌入每批提交前、各阶段之间都查一次。中断、出错、跑完都删掉
//! 临时新库（[Options::keep] 时留下）。报告只有计数与 ID，不含笔记内容（[Options::full_examples] 时例子给整行，只供本地
//! 排查用）。

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, InterruptHandle, OpenFlags, OptionalExtension, params};
use serde_json::{Map, Value, json};

use super::alias::{A_UNVERIFIED, AliasCounts};
use super::cache::CFG_KEY;
use super::carry::{self, Carried};
use super::class::DiffEvidence;
use super::compare::{
    self, CARD_COLS, CacheBaseline, CacheRows, CanonMap, Diff, Known, NOTE_COLS, OldCachesError,
    Pair, STAT_COLS, Skip, rows_of, texts,
};
use super::derive::{Index, R_CONFLICT, R_WINNER, Ref, Settled, body_of};
use super::import::{Imported, import_legacy_checked};
use super::ingest::{Settle, ingest_settle};
use super::legacy;
use super::native::Native;
use super::schema::{self, sql};
use super::stale::{self, Stale};
use super::trace;
use super::truth::Truth;
use crate::gen4::heritage::fingerprint;
use crate::gen4::op::Body4;
use crate::gen4::stamp::{HeritageStamp, StampHlc};
use crate::registers::{StoredEdit, judge_register};
use crate::store::sync2::collection_of;
use crate::store::sync2::config::default_deck_id;
use crate::sync2::dvv::Dvv;
use crate::sync2::hlc::Hlc;
use crate::sync2::id::{Id, Key};
use crate::sync2::segment::CHAIN_ZERO;
use crate::sync2::vv::OpId;

/// 报告格式的版本（[run] 的返回值里的 `version`）。
///
/// - 2：profile 报告加 `cacheBaseline`（`"rebuilt"` / `"notConfigured"` / `{"unavailable": 错误}`），新结论 `incomplete`。
/// - 3：缓存层按规范 ID 物化、按规范 ID 对拍（G9-2）；profile 报告加 `knownDifferences`（[known_json]），`parity` 里可能
///   出现 `classRegisters` 类。
/// - 4：预演与真迁移（G7-2）走同一套阶段（[profile_stages]）：重建换成 `ingest_settle(Rebuild)`，之前多了本机状态
///   搬运与新身份 + `Salts` 两步。profile 报告加 `local`（`carry.rs` 搬过来的本机状态计数与切点）、`identity`（新身份的
///   设备、`prev`、`Salts` 的 seq）、`migrationBlockers`（只有真迁移才拦的前提，预演只报、有才写）。旧库的本机状态
///   形状不对（`sync2_self` 的 `next_seq` < 1、公钥冲突等，`carry.rs` 报错）时这个 profile 的结论是 `error`、整份也随之
///   `error`（以前照样 `pass` / `fail`）。
/// - 5：profile 报告加 `oldSideStaleResults`（`{logs, cards, examples}`，`stale.rs`）：协议 3 一侧被旧代码重放改写过、
///   再没改回来的日志结果，基准改回后重建，逐条佐证、不计入判定（反馈 RhMpA6bn8v）。
pub const REPORT_VERSION: i64 = 5;

/// `knownDifferences.entries` 最多列几条（只有 ID；超出的只计数，`truncated` 为真）。
pub const KNOWN_ENTRIES: usize = 5_000;

/// 被中断时的错误文本（[run] 返回 `Ok`、`verdict = "cancelled"`；只有内部各步之间用它传）。
pub const CANCELLED: &str = "gen4 dry run: cancelled";

/// 临时新库在工作目录里的文件名。
pub const WORK_FILE: &str = "gen4-dryrun.db";

/// 假想的迁移设备（写那条 `Salts`）。只在临时新库里出现。
const REHEARSAL_DEVICE: Id = Id([0x6d; 16]);

/// 报告里每类差异最多给几个例子。
pub const DEFAULT_EXAMPLES: usize = 8;

/// 空间余量（与 `store/schema.rs` 的升级余量同值）。
pub(crate) const SPACE_MARGIN: u64 = 64 << 20;

/// 中断开关。可以从别的线程调 [Stop::stop]。
#[derive(Default)]
pub struct Stop {
    flag: AtomicBool,
    handles: Mutex<Vec<InterruptHandle>>,
}

impl Stop {
    pub fn new() -> Stop {
        Stop::default()
    }

    /// 置位并打断已登记的连接上正在跑的语句。可以重复调。
    pub fn stop(&self) {
        self.flag.store(true, Ordering::SeqCst);
        if let Ok(hs) = self.handles.lock() {
            for h in hs.iter() {
                h.interrupt();
            }
        }
    }

    pub fn stopped(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }

    pub(crate) fn attach(&self, c: &Connection) {
        if let Ok(mut hs) = self.handles.lock() {
            hs.push(c.get_interrupt_handle());
        }
        if self.stopped() {
            c.get_interrupt_handle().interrupt();
        }
    }

    pub(crate) fn detach_all(&self) {
        if let Ok(mut hs) = self.handles.lock() {
            hs.clear();
        }
    }

    pub(crate) fn check(&self) -> Result<(), String> {
        if self.stopped() {
            Err(CANCELLED.to_owned())
        } else {
            Ok(())
        }
    }
}

/// 干跑的参数。
pub struct Options<'a> {
    /// 每个 profile 的缓存配置（`CacheConfig` 的 JSON 文本：默认牌组、内置笔记类型的代码默认值），与 app 交给新代内核的
    /// 是同一份（规范 ID）；协议 3 一侧的重建用内核按 profile uid 派生的带盐那份（`compare.rs` `cache_pairs`）。没给的
    /// profile 只有默认牌组（内置类型的笔记行会对不上，差异照报）。
    pub caches: &'a BTreeMap<String, String>,
    /// 灌入每批条数。
    pub batch: u64,
    /// 跑完留下临时新库（只给本地排查用）。
    pub keep: bool,
    /// 每类差异最多几个例子。
    pub examples: usize,
    /// 例子给整行（含笔记内容；只给本地排查用）。默认只给 ID。
    pub full_examples: bool,
    pub stop: &'a Stop,
    /// 进度：(阶段, profile)。阶段：`open`、`preflight`、`import`（灌入期间每提交一批另报一次 `batch`）、`local`、
    /// `salts`、`rebuild`、`compare`、`checks`、`done`。
    pub progress: &'a mut dyn FnMut(&str, Option<&str>),
}

impl Options<'_> {
    pub(crate) fn note(&mut self, stage: &str, profile: Option<&str>) {
        (self.progress)(stage, profile);
    }
}

/// 进程的内存峰值（MiB）：(常驻 / 工作集峰值, 提交量峰值)。拿不到给 0。app 里跑时是整个进程的峰值，报告里同时给开始时
/// 的值，差才是干跑自己抬高的部分（只增不减，抬不高就是 0）。
#[cfg(windows)]
pub fn peak_mem_mb() -> (f64, f64) {
    #[repr(C)]
    #[derive(Default)]
    struct Counters {
        cb: u32,
        page_fault_count: u32,
        peak_working_set: usize,
        working_set: usize,
        quota_peak_paged_pool: usize,
        quota_paged_pool: usize,
        quota_peak_non_paged_pool: usize,
        quota_non_paged_pool: usize,
        pagefile: usize,
        peak_pagefile: usize,
        private_usage: usize,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentProcess() -> isize;
        fn K32GetProcessMemoryInfo(p: isize, c: *mut Counters, cb: u32) -> i32;
    }
    let mut c = Counters {
        cb: std::mem::size_of::<Counters>() as u32,
        ..Default::default()
    };
    // SAFETY: 输出结构体是本函数的局部变量，大小如实给出。
    let ok = unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut c, c.cb) };
    if ok == 0 {
        return (0.0, 0.0);
    }
    (
        c.peak_working_set as f64 / 1048576.0,
        c.peak_pagefile as f64 / 1048576.0,
    )
}

/// Unix 上只有常驻内存的峰值（`ru_maxrss`：macOS 给字节、其余给 KiB）；没有提交量，第二个数是 0。
#[cfg(unix)]
pub fn peak_mem_mb() -> (f64, f64) {
    // SAFETY: 输出结构体是本函数的局部变量；全零是 rusage 的合法值。
    let mut u: libc::rusage = unsafe { std::mem::zeroed() };
    // SAFETY: 指针指向上面那个局部变量。
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut u) } != 0 {
        return (0.0, 0.0);
    }
    let unit = if cfg!(target_os = "macos") {
        1.0
    } else {
        1024.0
    };
    (u.ru_maxrss as f64 * unit / 1048576.0, 0.0)
}

#[cfg(not(any(windows, unix)))]
pub fn peak_mem_mb() -> (f64, f64) {
    (0.0, 0.0)
}

pub(crate) fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64)
}

pub(crate) fn secs(t: Instant) -> f64 {
    (t.elapsed().as_secs_f64() * 10.0).round() / 10.0
}

pub(crate) fn mb(x: f64) -> f64 {
    x.round()
}

pub(crate) fn file_len(p: &Path) -> u64 {
    std::fs::metadata(p).map_or(0, |m| m.len())
}

fn remove_db(p: &Path) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", p.display()));
    }
}

/// 只读打开旧库，并开一个读事务钉住快照（[run] 结束时回滚）。
pub fn open_legacy(path: &Path) -> Result<Connection, String> {
    let c = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(sql)?;
    // 与 SrsCore 的连接同一套 SQL 函数：ID 编码、瘦 JSON 的生成列（旧代码读 `json` 列）、摘要桶（触发器引用）。
    crate::store::sync2::digest::register(&c).map_err(sql)?;
    crate::store::ids::register(&c).map_err(sql)?;
    crate::store::slim::register(&c).map_err(sql)?;
    // 只读打开：主库写不进去（`SQLITE_READONLY`），`temp` 库照常可写——协议 3 一侧的缓存重建写的影子临时表就在那里。
    // 临时表落临时文件（超出页缓存的部分；app 里临时目录由 store/compact.rs 的 `use_temp_dir`（`ffsrs_set_temp_dir`）设好，Android
    // 也有），不放内存：大库的影子缓存表有几十上百 MB。不开 `query_only`：它连临时表也拦。不做内存映射、页缓存取小值。
    c.execute_batch(
        "PRAGMA temp_store = FILE; PRAGMA mmap_size = 0; PRAGMA cache_size = -16384; BEGIN",
    )
    .map_err(sql)?;
    // 第一条读语句才真正开始读事务、钉住快照。
    c.query_row("SELECT COUNT(*) FROM sqlite_schema", [], |r| {
        r.get::<_, i64>(0)
    })
    .map_err(sql)?;
    Ok(c)
}

/// 干跑一个库。返回报告（JSON，见文件头）；只有「根本跑不起来」（旧库打不开、工作目录建不了）才返回 `Err`，其余
/// （没做完前提、对拍不过、中断、某个 profile 出错）都写进报告的 `verdict`。
pub fn run(old: &Path, work: &Path, mut opts: Options<'_>) -> Result<Value, String> {
    let started = Instant::now();
    let (peak0, _) = peak_mem_mb();
    let mut report = Map::new();
    report.insert("version".into(), json!(REPORT_VERSION));
    report.insert("startedAtMs".into(), json!(now_ms()));
    report.insert("oldBytes".into(), json!(file_len(old)));
    report.insert(
        "oldWalBytes".into(),
        json!(file_len(&PathBuf::from(format!("{}-wal", old.display())))),
    );
    report.insert("peakMbAtStart".into(), json!(mb(peak0)));
    std::fs::create_dir_all(work).map_err(|e| format!("gen4 dry run: work dir: {e}"))?;
    let new_path = work.join(WORK_FILE);
    remove_db(&new_path);
    // 空间：设计 §6.1 第 1 步的估算（新库约为旧库的 0.3 倍）加余量。拿不到空闲空间就照跑。
    let need = file_len(old) * 3 / 10 + SPACE_MARGIN;
    if let Some(free) = crate::store::compact::free_bytes(work) {
        report.insert("freeBytes".into(), json!(free));
        if free < need {
            report.insert("verdict".into(), json!("skipped"));
            report.insert(
                "reason".into(),
                json!(format!(
                    "not enough free space: need {need} bytes, have {free}"
                )),
            );
            report.insert("elapsedS".into(), json!(secs(started)));
            return Ok(Value::Object(report));
        }
    }
    opts.note("open", None);
    let src = open_legacy(old)?;
    opts.stop.attach(&src);
    let outcome = (|| -> Result<(Vec<Value>, u64), String> {
        let dst = schema::open(&new_path)?;
        opts.stop.attach(&dst);
        let t = Truth::new(&dst);
        let mut profiles = Vec::new();
        for profile in legacy::profiles(&src)? {
            opts.stop.check()?;
            let one = profile_stages(&src, &t, &profile, &mut opts, &Mode::Rehearsal);
            match one {
                Err(e) if e == CANCELLED || opts.stop.stopped() => return Err(CANCELLED.into()),
                Err(e) => {
                    profiles.push(json!({"profile": profile, "verdict": "error", "error": e}))
                }
                Ok(v) => profiles.push(v),
            }
        }
        dst.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
            .map_err(sql)?;
        let bytes = file_len(&new_path);
        let tables: Map<String, Value> = schema::table_bytes(&dst)
            .into_iter()
            .map(|(name, n)| (name, json!(n)))
            .collect();
        report.insert("newTableBytes".into(), Value::Object(tables));
        Ok((profiles, bytes))
    })();
    let _ = src.execute_batch("ROLLBACK");
    drop(src);
    opts.stop.detach_all();
    let (peak1, commit1) = peak_mem_mb();
    report.insert("peakMb".into(), json!(mb(peak1)));
    report.insert("peakCommitMb".into(), json!(mb(commit1)));
    report.insert("peakMbRaised".into(), json!(mb((peak1 - peak0).max(0.0))));
    report.insert("elapsedS".into(), json!(secs(started)));
    let verdict = match outcome {
        Ok((profiles, bytes)) => {
            report.insert("newBytes".into(), json!(bytes));
            let verdicts: Vec<&str> = profiles
                .iter()
                .filter_map(|p| p["verdict"].as_str())
                .collect();
            report.insert("profiles".into(), Value::Array(profiles.clone()));
            overall(&verdicts)
        }
        Err(e) if e == CANCELLED || opts.stop.stopped() => "cancelled",
        Err(e) => {
            report.insert("error".into(), json!(e));
            "error"
        }
    };
    report.insert("verdict".into(), json!(verdict));
    if opts.keep {
        report.insert("kept".into(), json!(new_path.display().to_string()));
    } else {
        remove_db(&new_path);
    }
    opts.note("done", None);
    Ok(Value::Object(report))
}

/// 整个库的结论：有出错的报 `error`，否则有不过的报 `fail`，否则有没做完前提的报 `blocked`，否则有对拍没做全的
/// （协议 3 一侧的缓存基准拿不到，profile 报 `incomplete`）报 `incomplete`，都过了才 `pass`；一个 profile 都没有是 `empty`。
pub(crate) fn overall(verdicts: &[&str]) -> &'static str {
    if verdicts.is_empty() {
        "empty"
    } else if verdicts.contains(&"error") {
        "error"
    } else if verdicts.contains(&"fail") {
        "fail"
    } else if verdicts.contains(&"blocked") {
        "blocked"
    } else if verdicts.contains(&"incomplete") {
        "incomplete"
    } else {
        "pass"
    }
}

/// 阶段代码的走法（[profile_stages]）。预演与真迁移只在这两处不同，其余每一步是同一份代码（规划 §1.1：「预演与真迁移
/// 走同一套阶段代码」）。
pub(crate) enum Mode<'a> {
    /// 预演（G4 / G4b）：由一台假想的迁移设备写那条 `Salts`（占位钥匙，不把真签名钥匙抄进临时文件）；真迁移才拦的前提
    /// （[profile_blockers] 的第二项）只报不拦。
    Rehearsal,
    /// 真迁移（G7-2）：新身份 = [Mode::Migration::new_device] 给的设备 ID + 沿用的签名钥匙，`prev` 指向协议 3 的旧设备
    /// （设计 §3.3）；前提一项不齐就拦。`now_ms` 是本机墙钟（身份建立时刻、HLC、媒体事实的超前判断）。
    Migration {
        now_ms: i64,
        new_device: &'a dyn Fn(&str, i64) -> Id,
    },
}

/// 预演里那台假想迁移设备的签名钥匙种子（占位）。
const REHEARSAL_SEED: [u8; 32] = [0x6d; 32];

/// 一个 profile 迁不了的原因（预演与真迁移同一份判据）：(哪种走法都拦的, 只有真迁移拦的)。前者是读入器读不全的
/// （`legacy::preflight`）；后者是读入器读得全、但对拍会跳过或宿主输入不全的（`legacy::migration_blockers`、没给缓存
/// 配置——没有它新代的缓存层建不出内置笔记类型的行，提交后读到的就是错的）。
pub(crate) fn profile_blockers(
    src: &Connection,
    profile: &str,
    caches: &BTreeMap<String, String>,
) -> Result<(Vec<String>, Vec<String>), String> {
    let hard = legacy::preflight(src, profile)?;
    let mut later = legacy::migration_blockers(src, profile)?;
    if !caches.contains_key(profile) {
        later.push("no cache configuration was given for this profile".to_owned());
    }
    Ok((hard, later))
}

/// 新身份（[Mode] 的第一处不同）。
struct NewSelf {
    device: Id,
    sk: [u8; 32],
    prev: Option<crate::gen4::head::PrevIdentity>,
    /// 时钟的起点：协议 3 旧身份的时钟与媒体事实里不超前的最大 HLC 取大者（新身份发出的第一条 HLC 不落在本机已经
    /// 发出 / 吸收过的之前）。
    clock: Option<Hlc>,
}

fn new_self(
    src: &Connection,
    profile: &str,
    mode: &Mode<'_>,
    now: i64,
    carried: &Carried,
) -> Result<NewSelf, String> {
    let old = carry::legacy_self(src, profile)?;
    let (device, sk, prev) = match mode {
        Mode::Rehearsal => (REHEARSAL_DEVICE, REHEARSAL_SEED, None),
        Mode::Migration { new_device, .. } => {
            let old = old.as_ref().ok_or_else(|| {
                format!("gen4 migrate: profile {profile} has no protocol 3 identity")
            })?;
            let device = new_device(profile, now);
            if device == old.device {
                return Err(format!(
                    "gen4 migrate: the new identity of {profile} reuses the old device id"
                ));
            }
            (device, old.key_seed, Some(old.prev()))
        }
    };
    let clock = [
        old.as_ref().and_then(|o| o.clock_for(device)),
        carried.media_hlc.map(|h| Hlc { device, ..h }),
    ]
    .into_iter()
    .flatten()
    .max_by_key(|h| (h.wall, h.logical));
    Ok(NewSelf {
        device,
        sk,
        prev,
        clock,
    })
}

/// 新身份的 `prev` 指得到灌进来的承袭日志（设计 §3.3：读者沿 `prev` 把新旧两个设备认成同一台）：seq ≥ 1 时旧设备
/// 名下那一槽在日志里、链指纹等于 `prev.chain` 的指纹；seq = 0（旧设备一条没写过）时链值是 [CHAIN_ZERO]、日志里也
/// 没有它的条目。对不上（灌入没带进末尾那一槽、`sync2_self` 与日志不一致……）报错：不在指空的 `prev` 上建新身份。
fn check_prev(
    t: &Truth<'_>,
    col: i64,
    profile: &str,
    prev: &crate::gen4::head::PrevIdentity,
) -> Result<(), String> {
    let at = OpId {
        device: prev.device,
        seq: prev.seq,
    };
    let ok = if prev.seq == 0 {
        prev.chain == CHAIN_ZERO && t.last_of(col, &prev.device)? == 0
    } else {
        t.entry(col, &at)?.and_then(|e| e.fp) == Some(fingerprint(&prev.chain))
    };
    if ok {
        Ok(())
    } else {
        Err(format!(
            "gen4 migrate: profile {profile}: the previous identity {}:{} does not match the imported log",
            prev.device.text(),
            prev.seq
        ))
    }
}

/// 一个 profile 从前提到对拍的全部阶段（预演 [run] 与真迁移 `migrate.rs` 共用）：前提 → 绑定与缓存配置 → 灌入 →
/// 本机状态（`carry.rs`）→ 新身份与 `Salts` → `rebuild_all` → 对拍与按规范 ID 的比较。返回这个 profile 的报告；
/// 结论在 `verdict`：`blocked` / `fail` / `incomplete` / `pass`。只有跑不下去（中断 = [CANCELLED]、IO……）才返回 `Err`。
/// 新库 [t] 的写一律在自己开的事务里，调用方不在事务里调。
pub(crate) fn profile_stages(
    src: &Connection,
    t: &Truth<'_>,
    profile: &str,
    opts: &mut Options<'_>,
    mode: &Mode<'_>,
) -> Result<Value, String> {
    let mut out = Map::new();
    out.insert("profile".into(), json!(profile));
    opts.note("preflight", Some(profile));
    let (mut blockers, later) = profile_blockers(src, profile, opts.caches)?;
    match mode {
        Mode::Migration { .. } => blockers.extend(later),
        Mode::Rehearsal if !later.is_empty() => {
            out.insert("migrationBlockers".into(), json!(later));
        }
        Mode::Rehearsal => {}
    }
    if !blockers.is_empty() {
        out.insert("verdict".into(), json!("blocked"));
        out.insert("blockers".into(), json!(blockers));
        return Ok(Value::Object(out));
    }
    let now = match mode {
        Mode::Rehearsal => now_ms(),
        Mode::Migration { now_ms, .. } => *now_ms,
    };
    let col = t.tx(|t| t.bind(profile, &collection_of(profile), profile))?;
    let cfg = opts
        .caches
        .get(profile)
        .cloned()
        .unwrap_or_else(|| json!({"defaultDeck": default_deck_id(profile)}).to_string());
    out.insert(
        "cacheConfig".into(),
        json!(if opts.caches.contains_key(profile) {
            "given"
        } else {
            "defaultDeckOnly"
        }),
    );
    t.tx(|t| t.set_derive_cfg(col, CFG_KEY, Some(&cfg)))?;

    // 灌入。
    opts.note("import", Some(profile));
    let started = Instant::now();
    let stop = opts.stop;
    let batch = opts.batch.max(1);
    let progress = &mut *opts.progress;
    let imported = import_legacy_checked(src, profile, t, col, batch, &mut || {
        stop.check()?;
        progress("batch", Some(profile));
        Ok(())
    })?;
    out.insert("importS".into(), json!(secs(started)));
    out.insert("imported".into(), imported_json(&imported));
    out.insert("peakMbAfterImport".into(), json!(mb(peak_mem_mb().0)));

    // 本机状态（§6.1 第 3 步的「带过去」，D11；规划 §1.4 第 5、7 步）。
    opts.note("local", Some(profile));
    opts.stop.check()?;
    let carried = carry::carry_local(src, t, col, profile, now)?;
    let cut_points = carry::carry_cut_points(src, t, col, profile)?;
    let mut local = carried.json();
    local["cutPoints"] = json!(cut_points);
    out.insert("local".into(), local);

    // 新身份 + 盐（§6.1 第 4 步，D9：在重建与对拍之前；规划 §1.4 第 6 步）。
    opts.note("salts", Some(profile));
    opts.stop.check()?;
    let salts: BTreeSet<String> = legacy::salts(src, profile)?.into_iter().collect();
    out.insert("salts".into(), json!(salts.len()));
    let me = new_self(src, profile, mode, now, &carried)?;
    let salts_op = t.tx(|t| {
        if let Some(prev) = &me.prev {
            check_prev(t, col, profile, prev)?;
        }
        t.create_self(col, &me.device, &me.sk, me.prev.as_ref(), now)?;
        if let Some(h) = &me.clock {
            if (h.wall, h.logical) > (0, 0) {
                t.set_self_hlc(col, h)?;
            }
        }
        let mut idx = Index::new(t, col);
        Native::open(t, col)?.write_salts(&mut idx, &salts, now)
    })?;
    out.insert(
        "identity".into(),
        json!({
            "device": me.device.text(),
            "prev": me.prev.as_ref().map(|p| json!({"device": p.device.text(), "seq": p.seq})),
            "saltsSeq": salts_op.map(|id| id.seq),
        }),
    );

    // 重建（§6.1 第 5 步）。
    opts.note("rebuild", Some(profile));
    opts.stop.check()?;
    let started = Instant::now();
    let (settled, stages) = t.tx(|t| {
        let mut idx = Index::new(t, col);
        let settled = ingest_settle(t, &mut idx, col, Settle::Rebuild)?;
        Ok((settled, std::mem::take(&mut idx.rebuild_stages)))
    })?;
    out.insert("rebuildS".into(), json!(secs(started)));
    // 各阶段秒数（BUG-5137：重建慢只在用户的大库上出现，凭报告定位到阶段）。
    let stages: serde_json::Map<String, Value> = stages
        .into_iter()
        .map(|(name, s)| (name.to_owned(), json!((s * 10.0).round() / 10.0)))
        .collect();
    out.insert("rebuildStages".into(), Value::Object(stages));
    out.insert("settled".into(), settled_json(&settled));
    out.insert("peakMbAfterRebuild".into(), json!(mb(peak_mem_mb().0)));
    let ix = Index::new(t, col);
    out.insert("aliases".into(), alias_json(&ix.alias_counts()?));

    // 对拍。
    opts.note("compare", Some(profile));
    opts.stop.check()?;
    let started = Instant::now();
    let skip = old_side_pending(src, profile)?;
    out.insert(
        "oldSidePending".into(),
        json!({"replayCards": skip.cards.len(), "staleTagNotes": skip.notes.len()}),
    );
    // 协议 3 一侧被旧代码重放改写过、再没改回来的日志结果（`stale.rs`）：基准先改回再重建，逐条报出来。
    let stale = stale::find(src, profile)?;
    out.insert("oldSideStaleResults".into(), stale::report(&stale));
    let mut peaks = Map::new();
    let mut mark = |what: &str| {
        peaks.insert(what.into(), json!(mb(peak_mem_mb().0)));
    };
    let (diff, baseline, collided, known) = compare::against_protocol_3(
        src,
        profile,
        t,
        col,
        &mut |src: &Connection, profile: &str, cfg: &str| old_caches(src, profile, cfg, &stale),
        &skip,
    )?;
    mark("parity");
    let failing = !diff.is_empty();
    out.insert("parity".into(), diff_json(&diff, opts));
    out.insert("knownDifferences".into(), known_json(&known));
    // 协议 3 一侧的缓存基准拿不到：缓存层三类没比成，这个 profile 最多是 `incomplete`，不能报 `pass`。
    let incomplete = matches!(baseline, CacheBaseline::Unavailable(_));
    out.insert(
        "cacheBaseline".into(),
        match &baseline {
            CacheBaseline::NotConfigured => json!("notConfigured"),
            CacheBaseline::Rows(_) => json!("rebuilt"),
            CacheBaseline::Unavailable(e) => json!({ "unavailable": e }),
        },
    );
    if let Some(rebuilt) = baseline.rows() {
        let stale = existing_vs_rebuilt(src, profile, rebuilt, &skip)?;
        out.insert("existingCachesVsRebuilt".into(), diff_json(&stale, opts));
    }
    mark("existingCaches");
    out.insert("compareS".into(), json!(secs(started)));

    // 按规范 ID 比。
    opts.note("checks", Some(profile));
    opts.stop.check()?;
    let started = Instant::now();
    let canon = CanonMap::load(t, col)?;
    // 按规范 ID 比的几类，跳过的集合也按规范 ID：协议 3 自己欠着收尾的、撞车的旧修改记录 ID 落在的笔记（同
    // `compare::cache_pairs` 的口径），连同这些笔记的卡。胜者变了的已知差异喂得到的列同 `compare::cache_pairs` 一样
    // 只盖那几列（[canonical_pairs] 的 `known`），不整卡跳过。
    let old_rows: Option<CacheRows> = baseline.rows().map(|r| canon.rows(r));
    let mut skip = Skip {
        notes: skip.notes.iter().map(|n| canon.text(n)).collect(),
        cards: skip.cards.iter().map(|c| canon.text(c)).collect(),
    };
    skip.notes.extend(
        collided
            .notes
            .iter()
            .filter_map(|n| n.strip_prefix("note:"))
            .map(|n| canon.text(n)),
    );
    if !skip.notes.is_empty() {
        let note_at = CARD_COLS
            .iter()
            .position(|c| c.0 == "note_id")
            .expect("listed column");
        let news: Vec<&str> = CARD_COLS.iter().map(|c| c.0).collect();
        let new_cards = rows_of(t.conn(), "cards", &news, "col = ?1", &col)?;
        let cards: Vec<String> = old_rows
            .iter()
            .flat_map(|old| old.1.iter())
            .chain(&new_cards)
            .filter(|r| skip.notes.contains(&r[note_at]))
            .map(|r| r[0].clone())
            .collect();
        skip.cards.extend(cards);
    }
    out.insert("collidedNotes".into(), json!(collided.notes.len()));
    mark("canonLoad");
    let regs = registers(src, profile, t, col, &collided)?;
    mark("registerWinners");
    let mut canonical_diff = differences_of(regs);
    match &old_rows {
        Some(old) => canonical_pairs(
            src,
            profile,
            t,
            col,
            &canon,
            &skip,
            &known,
            old,
            &mut canonical_diff,
        )?,
        // 没设缓存配置 / 协议 3 的缓存重建失败（`cacheBaseline` 记着）：没有旧侧的卡行与统计行，只比日志。
        None => canonical_pairs(
            src,
            profile,
            t,
            col,
            &canon,
            &skip,
            &known,
            &Default::default(),
            &mut canonical_diff,
        )?,
    }
    drop(old_rows);
    mark("canonicalPairs");
    canonical_diff.sort_by_key(|d| d.0);
    // ID 溯源（BUG-5269）：对拍与按规范 ID 比的例子里出现的 ID、别名层验不上的 ID，逐个摊开两侧的行与派生规则。只是
    // 诊断：读失败记进报告，不让真迁移（同一个函数）因此失败。
    let unverified = trace::unverified_ids(t, col, opts.examples);
    if let Some(a) = out.get_mut("aliases") {
        a["unverifiedExamples"] = match &unverified {
            Ok(ids) => json!(ids),
            Err(e) => json!({ "error": e }),
        };
    }
    let mut trace_ids = example_ids(&[&diff, &canonical_diff], opts.examples);
    trace_ids.extend(unverified.unwrap_or_default());
    out.insert(
        "idTrace".into(),
        trace::id_trace(t, col, &canon, baseline.rows(), &trace_ids)
            .unwrap_or_else(|e| json!({ "error": e })),
    );
    drop(baseline);
    mark("idTrace");
    let failing = failing || !canonical_diff.is_empty();
    out.insert("canonical".into(), diff_json(&canonical_diff, opts));
    out.insert(
        "canonicalCounts".into(),
        canon_counts(&canon, src, profile, t, col)?,
    );
    mark("canonicalCounts");
    opts.stop.check()?;
    out.insert("closures".into(), closures(src, profile, t, col)?);
    mark("closures");
    opts.stop.check()?;
    out.insert("renamedWriters".into(), renamed_writers(t, col, opts)?);
    mark("renamedWriters");
    opts.stop.check()?;
    out.insert(
        "unverifiedLogs".into(),
        unverified_logs(src, t, col, &canon)?,
    );
    mark("unverifiedLogs");
    out.insert("peakMbBySteps".into(), Value::Object(peaks));
    out.insert("checksS".into(), json!(secs(started)));
    out.insert("peakMbAfterChecks".into(), json!(mb(peak_mem_mb().0)));
    out.insert(
        "verdict".into(),
        json!(if failing {
            "fail"
        } else if incomplete {
            "incomplete"
        } else {
            "pass"
        }),
    );
    Ok(Value::Object(out))
}

fn imported_json(i: &Imported) -> Value {
    json!({
        "devices": i.devices, "applied": i.applied, "pending": i.pending, "pendingLinked": i.pending_linked,
        "ops": i.ops, "raw": i.raw, "alias": i.alias, "voids": i.voids,
        "inserted": i.inserted, "same": i.same, "kept": i.kept, "replaced": i.replaced,
        "forks": i.forks, "parked": i.parked, "untrusted": i.untrusted,
    })
}

fn settled_json(s: &Settled) -> Value {
    json!({
        "registers": s.registers, "judged": s.judged, "entities": s.entities, "logs": s.logs,
        "closures": s.closures, "purged": s.purged, "holds": s.holds, "notes": s.notes, "media": s.media,
        "scanned": s.scanned, "aliases": s.aliases, "digests": s.digests,
        "cacheNotes": s.cache_notes, "cacheCards": s.cache_cards, "cacheStats": s.cache_stats,
    })
}

fn alias_json(a: &AliasCounts) -> Value {
    json!({
        "salted": a.salted, "derived": a.derived, "fallback": a.fallback,
        "unverified": a.unverified, "writers": a.writers,
    })
}

/// 差异的报告形：每类只给条数与前几个例子。默认例子只取行的身份（`notes` / `cards` / `stats` 行的第一列、`tags` 的
/// 笔记 ID、`media` 的内容哈希），不带笔记内容。笔记行、卡行与统计行另给「同一身份两侧都有的行按列名的差异计数」与
/// 前几行的「列: 旧 -> 新」（[compare::column_diffs]；笔记行的内容列默认只报字符数，[Options::full_examples] 时给原文）。
/// 「为什么对不上」由 `idTrace`（[trace::id_trace]）摊开。
fn diff_json(diff: &Diff, opts: &Options<'_>) -> Value {
    let ex = |what: &str, xs: &[String]| -> Vec<String> {
        xs.iter()
            .take(opts.examples)
            .map(|s| {
                if opts.full_examples {
                    s.clone()
                } else {
                    ident(what, s)
                }
            })
            .collect()
    };
    Value::Array(
        diff.iter()
            .map(|(what, old_only, new_only)| {
                let mut v = json!({
                    "what": what,
                    "onlyOld": old_only.len(),
                    "onlyNew": new_only.len(),
                    "examplesOld": ex(what, old_only),
                    "examplesNew": ex(what, new_only),
                });
                // 卡行 / 统计行：同一身份两侧都有的，哪几列不同（列全是调度数值与 ID，默认就带）。
                if let Some(c) =
                    compare::column_diffs(what, old_only, new_only, !opts.full_examples)
                {
                    v["sameIdRows"] = json!(c.rows);
                    v["columns"] = json!(c.columns);
                    v["columnExamples"] = json!(
                        c.examples
                            .into_iter()
                            .take(opts.examples)
                            .collect::<Vec<_>>()
                    );
                }
                v
            })
            .collect(),
    )
}

/// 按类判定的已知差异的报告形（模块文件头第 6 步）：总数、佐证得了 / 不了、按类别（实体种类 + 键名的头一段，如
/// `notetype css`、`note f`、`card newPos`）分的数、牵动的缓存行，与逐条的佐证（只有 ID、写入者名与 seq）。
fn known_json(k: &Known) -> Value {
    let mut by: BTreeMap<String, [u64; 3]> = BTreeMap::new();
    let mut entries = Vec::new();
    for d in &k.diffs.diffs {
        let head = d.key.split('/').next().unwrap_or(&d.key);
        let c = by.entry(format!("{} {head}", d.kind.wire())).or_default();
        c[0] += 1;
        if d.proven {
            c[1] += 1;
        }
        if d.winner_changed {
            c[2] += 1;
        }
        if entries.len() >= KNOWN_ENTRIES {
            continue;
        }
        let dominated: Vec<Value> = d
            .dominated
            .iter()
            .map(|x| {
                let evidence = match &x.evidence {
                    DiffEvidence::Copy { name } => json!({"copy": name}),
                    DiffEvidence::Overlap { name, lo, hi } => {
                        json!({"overlap": {"name": name, "lo": lo, "hi": hi}})
                    }
                    DiffEvidence::Mismatch { name } => json!({"mismatch": name}),
                    DiffEvidence::None => json!("none"),
                };
                json!({
                    "op": compare::op_text(&x.op),
                    "writer": x.writer,
                    "seq": x.seq,
                    "canonicalWriter": x.canonical_writer,
                    "evidence": evidence,
                })
            })
            .collect();
        entries.push(json!({
            "kind": d.kind.wire(),
            "entity": d.entity.text(),
            "key": d.key,
            "rawConflict": d.raw_conflict,
            "classConflict": d.class_conflict,
            "winnerChanged": d.winner_changed,
            "hlcTie": d.hlc_tie,
            "proven": d.proven,
            "dominated": dominated,
            "revived": d.revived.iter().map(compare::op_text).collect::<Vec<_>>(),
        }));
    }
    let total = k.diffs.diffs.len();
    let unproven = k.diffs.unproven().count();
    json!({
        "examined": k.diffs.examined,
        "mergedRegisters": k.diffs.merged,
        "mergedRegistersInConflict": k.diffs.merged_conflicts,
        "total": total,
        "proven": total - unproven,
        "unproven": unproven,
        "byCategory": by
            .into_iter()
            .map(|(c, [n, p, w])| (c, json!({"total": n, "proven": p, "winnerChanged": w})))
            .collect::<Map<String, Value>>(),
        // 胜者变了的已知差异盖了列的笔记 / 卡 / 统计行所属的卡、统计行整行不比的卡、这些行（两侧合计）与其中原文不同的。
        "cacheNotesMasked": k.note_cols.len(),
        "cacheCardsMasked": k.card_cols.len(),
        "cacheStatCardsMasked": k.stat_cols.len(),
        "cacheStatCardsAside": k.stats_aside.len(),
        "cacheStatCardsEventCopies": k.stats_event_copies.len(),
        // 同一事件的副本两边选了不同代表、只换了日志 ID 那一格的统计行与卡行（BUG-5063）。
        "cacheStatRepresentativeSwaps": k.stat_swaps.len(),
        "cacheCardRepresentativeSwaps": k.card_swaps.len(),
        "cacheRowsMasked": k.rows,
        "cacheRowsMaskedDiffer": k.rows_differ,
        "entries": entries,
        "truncated": total > KNOWN_ENTRIES,
    })
}

/// 差异例子（每类每侧前 [examples] 行）里出现的 UUID 格，按出现顺序（去重在 [trace::id_trace]）。只取 UUID 格，
/// 笔记行的内容列不会进报告。
fn example_ids(diffs: &[&Diff], examples: usize) -> Vec<String> {
    let mut out = Vec::new();
    for d in diffs {
        for (what, old, new) in d.iter() {
            if matches!(*what, "media" | "caches") {
                continue;
            }
            for r in old.iter().take(examples).chain(new.iter().take(examples)) {
                out.extend(trace::uuids_in_row(r).map(str::to_owned));
            }
        }
    }
    out
}

fn ident(what: &str, s: &str) -> String {
    match what {
        "media" => s.split_once('=').map_or(s, |(_, h)| h).to_owned(),
        "caches" => "(cache rebuild failed)".to_owned(),
        _ => {
            let end = [s.find(" | "), s.find('=')]
                .into_iter()
                .flatten()
                .min()
                .unwrap_or(s.len());
            s[..end].to_owned()
        }
    }
}

fn differences_of(pairs: impl IntoIterator<Item = Pair>) -> Diff {
    compare::differences(pairs)
}

// ---------------------------------------------------------------- 协议 3 一侧

/// 协议 3 自己还欠着、只读连接上做不了的收尾：待重放集合里的卡（`sync2_replay_pending`，收段会话被打断留下的）、
/// 合成 `tags` 行还没刷新的笔记（`semantics::tags_row` 只读地判）。这些卡与笔记的缓存行旧代码自己也给不出确定的
/// 结果，不比，计数。迁移（G7）要先用旧代码把它们做完（§6.1「前提」）。
fn old_side_pending(src: &Connection, profile: &str) -> Result<Skip, String> {
    let mut skip = Skip::default();
    let has = |name: &str| -> Result<bool, String> {
        src.prepare_cached("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?1")
            .map_err(sql)?
            .exists([name])
            .map_err(sql)
    };
    if has("sync2_replay_pending")? {
        skip.cards = texts(
            src,
            "SELECT srs_idt(card_id) FROM sync2_replay_pending WHERE profile_uid = srs_id(?1)",
            &[&profile],
        )?;
    }
    for note in texts(
        src,
        "SELECT DISTINCT srs_idt(entity_id) FROM srs_field_edits WHERE profile_uid = srs_id(?1) \
         AND entity_kind = 'note' AND field_key = 'tags' AND writer_id LIKE 'sync2:%'",
        &[&profile],
    )? {
        if !crate::store::sync2::semantics::tags_row(src, profile, &note)?.fresh {
            skip.notes.insert(note);
        }
    }
    Ok(skip)
}

/// 协议 3 的日志投影表（有过期结果要改回时也建影子，[old_caches]）。
const LOG_TABLE: &str = "srs_review_logs";

/// 协议 3 缓存重建要写的表。
const CACHE_TABLES: [&str; 4] = [
    "srs_notes_cache",
    "srs_cards_cache",
    "srs_stat_reviews",
    "sync2_cache_pending",
];

/// 冻结的旧代码（`store::caches::rebuild`）对旧库全量重建出来的缓存行，旧库一个字节不写：在连接的 `temp` 库里按
/// `main` 的定义建同名的空表与索引——不带库名的表名先找 `temp`，旧代码的读写都落在这几张临时表上——重建、读行、删表。
/// [cfg] 已是协议 3 口径（带盐的内置 ID，`compare.rs` `cache_pairs` 经 `class.rs` `legacy_config_for` 换好的）。
///
/// [stale] 是协议 3 一侧佐证得了的过期日志结果（`stale.rs`）：非空时日志投影表也在 `temp` 里建一份同名的（这个 profile
/// 的行），先改回、按协议 3 的重放重放那些卡，再重建。
fn old_caches(
    src: &Connection,
    profile: &str,
    cfg: &str,
    stale: &[Stale],
) -> Result<CacheRows, OldCachesError> {
    old_caches_with(
        src,
        profile,
        cfg,
        stale,
        &mut |src: &Connection, profile: &str, cfg| {
            crate::store::caches::rebuild(src, profile, cfg).map(|_| ())
        },
    )
}

/// 协议 3 的缓存重建这一步（生产是冻结的 `store::caches::rebuild`；测试注入失败）。
type Rebuild<'a> =
    dyn FnMut(&Connection, &str, &crate::store::caches::CacheConfig) -> Result<(), String> + 'a;

/// [old_caches]，协议 3 的重建这一步由调用方给。它的失败是 [OldCachesError::Protocol3]，其余（解析配置、建临时表、读行）
/// 是 [OldCachesError::Setup]。
fn old_caches_with(
    src: &Connection,
    profile: &str,
    cfg: &str,
    stale: &[Stale],
    rebuild: &mut Rebuild<'_>,
) -> Result<CacheRows, OldCachesError> {
    use OldCachesError::{Protocol3, Setup};
    let parsed = crate::store::caches::CacheConfig::parse(
        &serde_json::from_str(cfg).map_err(|e| Setup(e.to_string()))?,
    )
    .map_err(Setup)?;
    let mut tables: Vec<&str> = CACHE_TABLES.to_vec();
    if !stale.is_empty() {
        tables.push(LOG_TABLE);
    }
    // 日志投影表的影子要拷行：只拷存储列（`json` 是生成列）。
    let log_cols: Vec<String> = if stale.is_empty() {
        Vec::new()
    } else {
        texts(
            src,
            &format!("SELECT name FROM pragma_table_xinfo('{LOG_TABLE}', 'main') WHERE hidden = 0"),
            &[],
        )
        .map_err(Setup)?
        .into_iter()
        .collect()
    };
    let defs: Vec<(String, String, String)> = (|| -> Result<_, String> {
        let marks = tables
            .iter()
            .map(|t| format!("'{t}'"))
            .collect::<Vec<_>>()
            .join(", ");
        src.prepare(&format!(
            "SELECT type, tbl_name, sql FROM main.sqlite_schema WHERE tbl_name IN ({marks}) \
             AND type IN ('table', 'index') AND sql IS NOT NULL ORDER BY type DESC, name"
        ))
        .map_err(sql)?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)
    })()
    .map_err(Setup)?;
    let made: BTreeSet<&str> = defs
        .iter()
        .filter(|d| d.0 == "table")
        .map(|d| d.1.as_str())
        .collect();
    if made.len() != tables.len() {
        return Err(Setup(format!(
            "gen4 dry run: the legacy library lacks cache tables (has {made:?})"
        )));
    }
    let shadow = (|| -> Result<CacheRows, OldCachesError> {
        for (kind, _, ddl) in &defs {
            let ddl = match kind.as_str() {
                "table" => ddl.replacen("CREATE TABLE ", "CREATE TEMP TABLE ", 1),
                // 不带库名的索引建在它的表所在的库（这里是 temp）。
                _ => ddl.clone(),
            };
            src.execute_batch(&ddl).map_err(|e| Setup(sql(e)))?;
        }
        if !stale.is_empty() {
            let cols = log_cols.join(", ");
            src.execute(
                &format!(
                    "INSERT INTO temp.{LOG_TABLE} ({cols}) SELECT {cols} FROM main.{LOG_TABLE} \
                     WHERE profile_uid = srs_id(?1)"
                ),
                [profile],
            )
            .map_err(|e| Setup(sql(e)))?;
            stale::heal(src, stale).map_err(Protocol3)?;
        }
        rebuild(src, profile, &parsed).map_err(Protocol3)?;
        let olds = |cols: &[(&'static str, &'static str)]| -> Vec<&'static str> {
            cols.iter().map(|c| c.1).collect()
        };
        let filter = "profile_uid = srs_id(?1)";
        Ok((
            rows_of(
                src,
                "temp.srs_notes_cache",
                &olds(NOTE_COLS),
                filter,
                &profile,
            )
            .map_err(Setup)?,
            rows_of(
                src,
                "temp.srs_cards_cache",
                &olds(CARD_COLS),
                filter,
                &profile,
            )
            .map_err(Setup)?,
            rows_of(
                src,
                "temp.srs_stat_reviews",
                &olds(STAT_COLS),
                filter,
                &profile,
            )
            .map_err(Setup)?,
        ))
    })();
    for t in tables {
        let _ = src.execute_batch(&format!("DROP TABLE IF EXISTS temp.{t}"));
    }
    shadow
}

/// 旧库里现成的缓存表，对冻结的旧代码全量重建出来的（§10 第 7 条：现成的允许过期，对拍的基准是重建的）。只报数。
fn existing_vs_rebuilt(
    src: &Connection,
    profile: &str,
    rebuilt: &CacheRows,
    skip: &Skip,
) -> Result<Diff, String> {
    let olds = |cols: &[(&'static str, &'static str)]| -> Vec<&'static str> {
        cols.iter().map(|c| c.1).collect()
    };
    let filter = "profile_uid = srs_id(?1)";
    let card_at = |name: &str| -> usize {
        CARD_COLS
            .iter()
            .position(|c| c.0 == name)
            .expect("listed column")
    };
    let keep_note = |r: &Vec<String>| !skip.notes.contains(&r[0]);
    let keep_card = |r: &Vec<String>| {
        !skip.cards.contains(&r[0]) && !skip.notes.contains(&r[card_at("note_id")])
    };
    let keep_stat = |r: &Vec<String>| !skip.cards.contains(&r[1]);
    let set = |rows: &[Vec<String>], keep: &dyn Fn(&Vec<String>) -> bool| -> BTreeSet<String> {
        rows.iter()
            .filter(|r| keep(r))
            .map(|r| r.join(" | "))
            .collect()
    };
    // 一张表一张表比、比完就放掉（同 `compare::cache_pairs`）：三张表两侧同时在内存里，大库的这一步会把峰值抬高一倍。
    let mut diff = Diff::new();
    let tables: [(
        &'static str,
        &str,
        &[(&'static str, &'static str)],
        &dyn Fn(&Vec<String>) -> bool,
        &Vec<Vec<String>>,
    ); 3] = [
        (
            "notes",
            "main.srs_notes_cache",
            NOTE_COLS,
            &keep_note,
            &rebuilt.0,
        ),
        (
            "cards",
            "main.srs_cards_cache",
            CARD_COLS,
            &keep_card,
            &rebuilt.1,
        ),
        (
            "stats",
            "main.srs_stat_reviews",
            STAT_COLS,
            &keep_stat,
            &rebuilt.2,
        ),
    ];
    for (what, table, cols, keep, rebuilt) in tables {
        let existing = set(&rows_of(src, table, &olds(cols), filter, &profile)?, keep);
        compare::push_pair(&mut diff, (what, existing, set(rebuilt, keep)));
    }
    Ok(diff)
}

// ---------------------------------------------------------------- 寄存器

/// 每个寄存器的胜者（§6.1 第 5 步「每个寄存器活着的写入与胜者值」；活着的写入已在 `edits` 类里比过）。协议 3 一侧：
/// 投影表里这个寄存器现存的修改记录过同一份判据（`registers::judge_register`，读路径也是它），取排第一的；新代一侧：
/// `reg_ix` 里 `state` 为胜者 / 冲突的胜者的那条。两边都写成「种类:实体:键 = 胜者的修改记录 ID（冲突加 `!`）」。
/// 标签（OR-Set，协议 3 是合成行）不比；有删除被扣住的实体的 `deleted` 也不比（同 `edits` 的口径）。
fn registers(
    src: &Connection,
    profile: &str,
    t: &Truth<'_>,
    col: i64,
    collided: &compare::Collisions,
) -> Result<Vec<Pair>, String> {
    let ix = Index::new(t, col);
    let held: BTreeSet<String> = ix
        .holds()?
        .iter()
        .map(|h| format!("{}:{}", h.kind.wire(), h.entity.text()))
        .chain(texts(
            src,
            "SELECT kind || ':' || srs_idt(entity) FROM sync2_held WHERE profile_uid = srs_id(?1)",
            &[&profile],
        )?)
        .collect();
    // 撞车的旧修改记录 ID 落在的寄存器不比（`compare::Collisions`，同 `edits` 的口径）。
    let skip = |ent: &str, key: &str| {
        key == "tags"
            || (key == "deleted" && held.contains(ent))
            || collided
                .registers
                .contains(&(ent.to_owned(), key.to_owned()))
    };
    // 协议 3：按实体分块读（同 `caches::edits_of` 的那条 JOIN），每块在内存里按键分组判。
    let ents: Vec<(String, String)> = src
        .prepare(
            "SELECT DISTINCT entity_kind, srs_idt(entity_id) FROM srs_field_edits WHERE profile_uid = srs_id(?1)",
        )
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut by_kind: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (k, e) in ents {
        by_kind.entry(k).or_default().push(e);
    }
    let mut old = BTreeSet::new();
    for (kind, ids) in &by_kind {
        for chunk in ids.chunks(400) {
            let q = format!(
                "SELECT srs_idt(f.entity_id), f.field_key, srs_idt(f.id), s.server_time, {} FROM srs_field_edits f \
                 LEFT JOIN srs_event_local s ON s.event_id = f.id WHERE f.entity_kind = ? AND f.profile_uid = srs_id(?) \
                 AND f.entity_id IN ({})",
                crate::store::slim::EDIT_READ,
                vec!["srs_id(?)"; chunk.len()].join(", ")
            );
            let mut stmt = src.prepare_cached(&q).map_err(sql)?;
            let args = [kind.as_str(), profile]
                .into_iter()
                .chain(chunk.iter().map(String::as_str));
            let mut rows = stmt.query(rusqlite::params_from_iter(args)).map_err(sql)?;
            type Row = (String, Option<i64>, Option<crate::registers::EditCols>);
            let mut regs: BTreeMap<(String, String), Vec<Row>> = BTreeMap::new();
            while let Some(r) = rows.next().map_err(sql)? {
                let ent: String = r.get(0).map_err(sql)?;
                let key: String = r.get(1).map_err(sql)?;
                let id: String = r.get(2).map_err(sql)?;
                let st: Option<i64> = r.get(3).map_err(sql)?;
                let (j, cols) = crate::store::slim::edit_row(r, 4).map_err(sql)?;
                let _ = id;
                regs.entry((ent, key)).or_default().push((j, st, cols));
            }
            for ((ent, key), rows) in regs {
                let ent = format!("{kind}:{ent}");
                if skip(&ent, &key) {
                    continue;
                }
                let stored: Vec<StoredEdit<'_>> = rows
                    .iter()
                    .map(|(j, st, cols)| (j.as_str(), *st, cols.as_ref()))
                    .collect();
                let (live, conflicted) = judge_register(&stored)?;
                let Some(&w) = live.first() else { continue };
                let winner_id = rows[w]
                    .2
                    .as_ref()
                    .map(|c| c.id.clone())
                    .or_else(|| {
                        serde_json::from_str::<Value>(&rows[w].0)
                            .ok()
                            .and_then(|v| v["id"].as_str().map(str::to_owned))
                    })
                    .ok_or_else(|| {
                        format!("gen4 dry run: register {ent} {key}: winner has no id")
                    })?;
                old.insert(format!(
                    "{ent}:{key}={winner_id}{}",
                    if conflicted { "!" } else { "" }
                ));
            }
        }
    }
    // 新代。
    let mut new = BTreeSet::new();
    let ks: Vec<(i64, i64)> = t
        .conn()
        .prepare("SELECT k, state FROM reg_ix WHERE col = ?1 AND state IN (?2, ?3)")
        .map_err(sql)?
        .query_map(params![col, R_WINNER, R_CONFLICT], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for (k, state) in ks {
        let Some(e) = t.edit_read(k, false)? else {
            return Err(format!("gen4 dry run: register row {k} is not an edit"));
        };
        let ed = &e.head;
        let ent = format!("{}:{}", ed.kind.wire(), Ref::of(&ed.entity).text());
        if skip(&ent, &ed.key) {
            continue;
        }
        let id = match &ed.stamp {
            Some(s) => crate::registers::edit_id(&s.writer, s.seq),
            None => crate::registers::edit_id(&e.id.device.text(), e.id.seq as i64),
        };
        new.insert(format!(
            "{ent}:{}={id}{}",
            ed.key,
            if state == R_CONFLICT { "!" } else { "" }
        ));
    }
    Ok(vec![("registerWinners", old, new)])
}

// ---------------------------------------------------------------- 规范 ID

/// 各种规范类的大小：规范卡 / 规范日志各有多少、其中吃进不止一个出现过的 ID 的有多少（§5.3 的基线：2,856 / 47,228）。
fn canon_counts(
    canon: &CanonMap,
    src: &Connection,
    profile: &str,
    t: &Truth<'_>,
    col: i64,
) -> Result<Value, String> {
    let classes = |ids: &[Ref]| -> (usize, usize, usize) {
        let mut by: BTreeMap<Ref, usize> = BTreeMap::new();
        for id in ids {
            *by.entry(canon.of(id)).or_default() += 1;
        }
        (ids.len(), by.len(), by.values().filter(|n| **n > 1).count())
    };
    let refs = |c: &Connection, q: &str, p: &dyn rusqlite::ToSql| -> Result<Vec<Ref>, String> {
        c.prepare(q)
            .map_err(sql)?
            .query_map([p], |r| r.get::<_, Ref>(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)
    };
    let new_cards = refs(
        t.conn(),
        "SELECT DISTINCT card FROM log_ix WHERE col = ?1",
        &col,
    )?;
    let new_logs = refs(
        t.conn(),
        "SELECT DISTINCT id FROM log_ix WHERE col = ?1",
        &col,
    )?;
    let old_cards = refs(
        src,
        "SELECT DISTINCT card_id FROM srs_review_logs WHERE profile_uid = srs_id(?1)",
        &profile,
    )?;
    let old_logs = refs(
        src,
        "SELECT id FROM srs_review_logs WHERE profile_uid = srs_id(?1)",
        &profile,
    )?;
    let row = |(n, classes, merged): (usize, usize, usize)| json!({"ids": n, "classes": classes, "merged": merged});
    Ok(json!({
        "cardsWithLogsNew": row(classes(&new_cards)),
        "cardsWithLogsOld": row(classes(&old_cards)),
        "logsNew": row(classes(&new_logs)),
        "logsOld": row(classes(&old_logs)),
    }))
}

/// 按规范 ID 的三类（§6.1 第 5 步；[old] 是协议 3 一侧已改写成规范 ID 的缓存行，[skip] 也是规范 ID）：
/// - `canonicalCards`：每张规范卡的调度状态（队列、到期、稳定度、难度、复习 / 遗忘次数）——同一张规范卡在一侧有几行
///   就有几条，两侧的多重集合要相同；
/// - `canonicalLogs`：每张规范卡（含不在缓存里的历史血统卡）名下的规范日志 ID 集合（日志表全集，未去重前的口径）；
/// - `canonicalStats`：每张规范卡的有效复习（统计行）条数（协议 3 一侧不计已证出的同一次复习的副本）。
fn canonical_pairs(
    src: &Connection,
    profile: &str,
    t: &Truth<'_>,
    col: i64,
    canon: &CanonMap,
    skip: &Skip,
    known: &Known,
    old: &CacheRows,
    diff: &mut Diff,
) -> Result<(), String> {
    let state_cols = [
        "queue",
        "due_day",
        "due_at",
        "reps",
        "lapses",
        "stability",
        "difficulty",
    ];
    let card_at = |name: &str| -> usize {
        CARD_COLS
            .iter()
            .position(|c| c.0 == name)
            .expect("listed column")
    };
    let cards = |rows: &[Vec<String>]| -> BTreeSet<String> {
        let mut n: BTreeMap<String, usize> = BTreeMap::new();
        for r in rows {
            if skip.cards.contains(&r[0]) || skip.notes.contains(&r[card_at("note_id")]) {
                continue;
            }
            // 胜者变了的已知差异喂得到的调度列盖住（[Known]），其余照比。
            let masked = known.card_cols.get(&r[0]);
            let state: Vec<&str> = state_cols
                .iter()
                .map(|c| match masked {
                    Some(m) if m.contains(c) => compare::MASKED,
                    _ => r[card_at(c)].as_str(),
                })
                .collect();
            // 两侧的行都已是规范 ID（新代按规范 ID 物化，协议 3 一侧由调用方改写过）。
            *n.entry(format!("{} | {}", r[0], state.join(" | ")))
                .or_default() += 1;
        }
        n.into_iter().map(|(k, c)| format!("{k} | x{c}")).collect()
    };
    // 协议 3 一侧是冻结的旧代码重建出来的那一份（对拍的基准，[old_caches]），不是旧库现成的缓存表。
    let news: Vec<&str> = CARD_COLS.iter().map(|c| c.0).collect();
    let empty = old.0.is_empty() && old.1.is_empty() && old.2.is_empty();
    let new_card_rows = if empty {
        Vec::new()
    } else {
        rows_of(t.conn(), "cards", &news, "col = ?1", &col)?
    };

    // 一类一类比完就放掉（大库的日志有几十万条）；两侧按 [Ref] 收，只有不同的那几条转成文本。
    compare::push_pair(
        diff,
        ("canonicalCards", cards(&old.1), cards(&new_card_rows)),
    );
    let two =
        |c: &Connection, q: &str, p: &dyn rusqlite::ToSql| -> Result<Vec<(Ref, Ref)>, String> {
            c.prepare(q)
                .map_err(sql)?
                .query_map([p], |r| Ok((r.get::<_, Ref>(0)?, r.get::<_, Ref>(1)?)))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)
        };
    let pairs_of = |rows: Vec<(Ref, Ref)>| -> BTreeSet<(Ref, Ref)> {
        rows.into_iter()
            .filter(|(card, _)| !skip.cards.contains(&card.text()))
            .map(|(card, log)| (canon.of(&card), canon.of(&log)))
            // 血统变了的卡（[Known::stats_aside]）名下有哪些日志本身就跟着变。
            .filter(|(card, _)| !known.stats_aside.contains(&card.text()))
            .collect()
    };
    let pair_text = |(card, log): &(Ref, Ref)| format!("{} | {}", card.text(), log.text());
    let old_logs = pairs_of(two(
        src,
        "SELECT card_id, id FROM srs_review_logs WHERE profile_uid = srs_id(?1)",
        &profile,
    )?);
    let new_logs = pairs_of(two(
        t.conn(),
        "SELECT card, id FROM log_ix WHERE col = ?1",
        &col,
    )?);
    compare::push_set(diff, "canonicalLogs", old_logs, new_logs, pair_text);
    let counts = |rows: Vec<(Ref, Ref)>| -> BTreeSet<(Ref, usize)> {
        let mut by: BTreeMap<Ref, BTreeSet<Ref>> = BTreeMap::new();
        for (card, log) in rows {
            if skip.cards.contains(&card.text())
                || known.stats_aside.contains(&canon.of(&card).text())
            {
                continue;
            }
            by.entry(canon.of(&card))
                .or_default()
                .insert(canon.of(&log));
        }
        by.into_iter().map(|(c, logs)| (c, logs.len())).collect()
    };
    // 协议 3 多算的同一次复习的副本（`compare.rs` 的 `event_copies`，已证出）不计：新代按规范卡只算一次。
    let copies: BTreeSet<&str> = known
        .stats_event_copies
        .values()
        .flatten()
        .map(String::as_str)
        .collect();
    let old_stats: Vec<(Ref, Ref)> = old
        .2
        .iter()
        .filter(|r| !copies.contains(r[0].as_str()))
        .map(|r| (Ref::of(&Key::of(&r[1])), Ref::of(&Key::of(&r[0]))))
        .collect();
    let old_stats = counts(old_stats);
    let new_stats = counts(if empty {
        Vec::new()
    } else {
        two(t.conn(), "SELECT card, log FROM stats WHERE col = ?1", &col)?
    });
    compare::push_set(diff, "canonicalStats", old_stats, new_stats, |(c, n)| {
        format!("{} | {n}", c.text())
    });
    Ok(())
}

// ---------------------------------------------------------------- 只报数的几项

/// 从槽重建的旧戳闭包（`closure_ix`）对协议 3 设备累计的 `sync2_legacy`（§10 第 14 条）。逐台：是否相同、`upto`、
/// 只在一边的 dot 数。
fn closures(src: &Connection, profile: &str, t: &Truth<'_>, col: i64) -> Result<Value, String> {
    let read = |c: &Connection,
                q: &str,
                p: &dyn rusqlite::ToSql|
     -> Result<BTreeMap<[u8; 16], (i64, Dvv)>, String> {
        let rows: Vec<([u8; 16], i64, String)> = c
            .prepare(q)
            .map_err(sql)?
            .query_map([p], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        Ok(rows
            .into_iter()
            .map(|(d, upto, ctx)| (d, (upto, Dvv::parse(&ctx))))
            .collect())
    };
    let has_legacy = src
        .prepare("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'sync2_legacy'")
        .map_err(sql)?
        .exists([])
        .map_err(sql)?;
    let old = if has_legacy {
        read(
            src,
            "SELECT device, upto, ctx FROM sync2_legacy WHERE profile_uid = srs_id(?1)",
            &profile,
        )?
    } else {
        BTreeMap::new()
    };
    let new = read(
        t.conn(),
        "SELECT device, upto, ctx FROM closure_ix WHERE col = ?1",
        &col,
    )?;
    let devices: BTreeSet<[u8; 16]> = old.keys().chain(new.keys()).copied().collect();
    let empty = (0, Dvv::default());
    let (mut same, mut differ) = (0u64, 0u64);
    let mut rows = Vec::new();
    for d in devices {
        let o = old.get(&d).unwrap_or(&empty);
        let n = new.get(&d).unwrap_or(&empty);
        let equal = o.0 == n.0 && o.1 == n.1;
        if equal {
            same += 1;
        } else {
            differ += 1;
        }
        rows.push(json!({
            "device": Id(d).text(),
            "same": equal,
            "uptoOld": o.0,
            "uptoNew": n.0,
            "dotsOnlyOld": dots_minus(&o.1, &n.1),
            "dotsOnlyNew": dots_minus(&n.1, &o.1),
        }));
    }
    Ok(json!({"same": same, "different": differ, "devices": rows}))
}

/// [a] 里有、[b] 里没有的 dot 数。
fn dots_minus(a: &Dvv, b: &Dvv) -> u64 {
    let has = |d: &Dvv, w: &str, s: i64| -> bool {
        d.vv.get(w).is_some_and(|n| s <= *n) || d.cloud.get(w).is_some_and(|c| c.contains(&s))
    };
    let mut n = 0u64;
    let writers: BTreeSet<&String> = a.vv.keys().chain(a.cloud.keys()).collect();
    for w in writers {
        let top = a.vv.get(w).copied().unwrap_or(0);
        for s in 1..=top {
            if !has(b, w, s) {
                n += 1;
            }
        }
        if let Some(c) = a.cloud.get(w) {
            n += c.iter().filter(|s| **s > top && !has(b, w, **s)).count() as u64;
        }
    }
    n
}

/// 一条承袭修改换成规范写入者之后的样子：(实体, 键, 值, 规范化的 HLC 文本, 规范化的旧上下文)。dot 的写入者、HLC 的
/// 写入者、旧上下文的键三处一起换（§5.3「改名的写入者」）。
fn normalized(
    ed: &crate::gen4::op::Edit4,
    s: &HeritageStamp,
    writer: &dyn Fn(&str) -> String,
) -> (String, String, String, String, String) {
    let hlc = match &s.hlc {
        StampHlc::Parsed {
            physical,
            counter,
            writer: w,
        } => StampHlc::Parsed {
            physical: *physical,
            counter: *counter,
            writer: writer(w),
        }
        .text(),
        StampHlc::Raw(r) => r.clone(),
    };
    let mut ctx: BTreeMap<String, BTreeSet<u64>> = BTreeMap::new();
    let mut prefix: BTreeMap<String, u64> = BTreeMap::new();
    for e in s.ctx.entries() {
        let w = writer(&e.writer);
        let p = prefix.entry(w.clone()).or_default();
        *p = (*p).max(e.vv);
        ctx.entry(w).or_default().extend(e.cloud.iter().copied());
    }
    let ctx_text = prefix
        .iter()
        .map(|(w, vv)| {
            let cloud: Vec<String> = ctx
                .get(w)
                .into_iter()
                .flatten()
                .filter(|s| **s > *vv)
                .map(u64::to_string)
                .collect();
            format!("{w}:{vv}[{}]", cloud.join(","))
        })
        .collect::<Vec<_>>()
        .join(";");
    (
        format!("{}:{}", ed.kind.wire(), Ref::of(&ed.entity).text()),
        ed.key.clone(),
        ed.value.clone(),
        hlc,
        ctx_text,
    )
}

/// G3 没验的第一项：归回去的改名写入者（`alias_writer_ix`）名下的修改，与最初写入者同 seq 的那条在换成规范写入者之后
/// 是否逐项相同（实体、键、值、HLC、旧上下文）。实体与键另按别名表换成规范 ID 再比一次（`differentAfterAliases`）：
/// 改名的那份库里的 ID 可能是兜底 / 派生出来的别名，原文不同、规范 ID 相同仍是同一条修改。只在别名表里有改名写入者时
/// 走日志：先走一遍只记改名写入者用过的 (规范写入者, seq)，再走一遍只收这些位置上的修改（最初写入者名下的修改很多，
/// 不整份收进内存）。
fn renamed_writers(t: &Truth<'_>, col: i64, opts: &Options<'_>) -> Result<Value, String> {
    let names: BTreeMap<String, String> = t
        .conn()
        .prepare("SELECT name, origin FROM alias_writer_ix WHERE col = ?1")
        .map_err(sql)?
        .query_map([col], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    if names.is_empty() {
        return Ok(json!({"writers": 0}));
    }
    let origins: BTreeSet<&String> = names.values().collect();
    let canonical = |w: &str| -> String { names.get(w).cloned().unwrap_or_else(|| w.to_owned()) };
    let devices = t.devices(col)?;
    let mut wanted: BTreeSet<(String, i64)> = BTreeSet::new();
    for d in &devices {
        opts.stop.check()?;
        t.for_each(col, &d.id, 1, |e| {
            if let Some(Body4::Edit(ed)) = body_of(&e) {
                if let Some(s) = ed.stamp.as_ref().filter(|s| names.contains_key(&s.writer)) {
                    wanted.insert((canonical(&s.writer), s.seq));
                }
            }
            Ok(())
        })?;
    }
    let ix = Index::new(t, col);
    // (规范写入者, seq) → [(原名, 规范化的修改, (规范实体, 规范键))]
    type Norm = (String, String, String, String, String);
    type Item = (String, Norm, (String, String));
    let mut by: BTreeMap<(String, i64), Vec<Item>> = BTreeMap::new();
    for d in &devices {
        opts.stop.check()?;
        let mut failed: Option<String> = None;
        t.for_each(col, &d.id, 1, |e| {
            let Some(Body4::Edit(ed)) = body_of(&e) else {
                return Ok(());
            };
            if let Some(s) = ed
                .stamp
                .as_ref()
                .filter(|s| names.contains_key(&s.writer) || origins.contains(&s.writer))
            {
                let at = (canonical(&s.writer), s.seq);
                if wanted.contains(&at) {
                    let canon = ix.canonical(&Ref::of(&ed.entity)).and_then(|c| {
                        Ok((
                            format!("{}:{}", ed.kind.wire(), c.text()),
                            ix.canonical_key(&ed.key)?,
                        ))
                    });
                    match canon {
                        Ok(c) => by.entry(at).or_default().push((
                            s.writer.clone(),
                            normalized(&ed, s, &canonical),
                            c,
                        )),
                        Err(err) => failed = Some(err),
                    }
                }
            }
            Ok(())
        })?;
        if let Some(err) = failed {
            return Err(err);
        }
    }
    let (mut pairs, mut alone) = (0u64, 0u64);
    let mut differ: BTreeMap<&str, u64> = BTreeMap::new();
    let mut differ_canon: BTreeMap<&str, u64> = BTreeMap::new();
    let mut examples: Vec<String> = Vec::new();
    for ((w, seq), items) in &by {
        let renamed: Vec<&Item> = items
            .iter()
            .filter(|(n, ..)| names.contains_key(n))
            .collect();
        let Some(o) = items.iter().find(|(n, ..)| n == w) else {
            alone += renamed.len() as u64;
            continue;
        };
        for r in renamed {
            pairs += 1;
            let (rn, on) = (&r.1, &o.1);
            let mut bad = Vec::new();
            for (what, same) in [
                ("entity", rn.0 == on.0),
                ("key", rn.1 == on.1),
                ("value", rn.2 == on.2),
                ("hlc", rn.3 == on.3),
                ("ctx", rn.4 == on.4),
            ] {
                if !same {
                    *differ.entry(what).or_default() += 1;
                    bad.push(what);
                }
            }
            for (what, same) in [("entity", r.2.0 == o.2.0), ("key", r.2.1 == o.2.1)] {
                if !same {
                    *differ_canon.entry(what).or_default() += 1;
                }
            }
            if !bad.is_empty() && examples.len() < opts.examples {
                examples.push(format!("{w}:{seq} {}", bad.join(",")));
            }
        }
    }
    Ok(json!({
        "writers": names.len(),
        "pairs": pairs,
        "withoutOriginal": alone,
        "different": differ,
        "differentAfterAliases": differ_canon,
        "examples": examples,
    }))
}

/// G3 没验的第二项：别名表里验不上的 ID 中是日志的那些（§5.3：样本库 1,520 条 review + 26 条 undo），重建之后是否仍挂在
/// 协议 3 投影里它所在的那张卡的规范卡上。按日志种类分开计数。
fn unverified_logs(
    src: &Connection,
    t: &Truth<'_>,
    col: i64,
    canon: &CanonMap,
) -> Result<Value, String> {
    let ids: Vec<Ref> = t
        .conn()
        .prepare("SELECT id FROM alias_ix WHERE col = ?1 AND how = ?2")
        .map_err(sql)?
        .query_map(params![col, A_UNVERIFIED], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut by_kind: BTreeMap<String, [u64; 4]> = BTreeMap::new();
    let (mut not_logs, mut examples) = (0u64, Vec::new());
    for id in &ids {
        let new_card: Option<Ref> = t
            .conn()
            .prepare_cached(
                "SELECT card FROM log_ix WHERE col = ?1 AND id = ?2 ORDER BY win DESC, k LIMIT 1",
            )
            .map_err(sql)?
            .query_row(params![col, id], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        let Some(new_card) = new_card else {
            not_logs += 1;
            continue;
        };
        let old: Option<(Ref, String)> = src
            .prepare_cached("SELECT card_id, kind FROM srs_review_logs WHERE id = srs_id(?1)")
            .map_err(sql)?
            .query_row([id.text()], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()
            .map_err(sql)?;
        // [同一张规范卡, 不同, 协议 3 投影里没有, 合计]
        let (kind, slot) = match &old {
            Some((card, kind)) if canon.of(card) == canon.of(&new_card) => (kind.clone(), 0),
            Some((_, kind)) => (kind.clone(), 1),
            None => ("?".to_owned(), 2),
        };
        if slot != 0 && examples.len() < DEFAULT_EXAMPLES {
            examples.push(id.text());
        }
        let row = by_kind.entry(kind).or_default();
        row[slot] += 1;
        row[3] += 1;
    }
    let kinds: Map<String, Value> = by_kind
        .into_iter()
        .map(|(k, [same, differ, missing, total])| {
            (
                k,
                json!({"total": total, "sameCanonicalCard": same, "differentCard": differ, "notInLegacy": missing}),
            )
        })
        .collect();
    Ok(json!({
        "unverifiedIds": ids.len(),
        "notLogs": not_logs,
        "logs": kinds,
        "examples": examples,
    }))
}

/// 原子地把 [value] 写到 [path]（同目录临时文件 `<名字>.tmp` 再改名，读的一方不会读到半份）。迁移报告用。
pub(crate) fn write_json_atomically(path: &Path, value: &Value) -> Result<(), String> {
    let text = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    std::fs::write(&tmp, text).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
pub(crate) mod tests {
    use serde_json::{Value, json};

    use super::*;
    use crate::store::sync2::tests::{DAY, Device, P, deck_entity, edit, review};

    pub(crate) const T0: i64 = 1_700_000_000_000;
    pub(crate) const N1: &str = "0193a1b2-0000-7000-8000-0000000000b1";
    pub(crate) const N2: &str = "0193a1b2-0000-7000-8000-0000000000b2";

    fn note(id: &str, nt: &str) -> Value {
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": nt}}})
    }

    fn note_type(id: &str) -> Value {
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}})
    }

    pub(crate) fn cfg() -> String {
        json!({"defaultDeck": default_deck_id(P)}).to_string()
    }

    /// 协议 3 上的一个小库：一个笔记类型两条模板、两条笔记、几次复习，缓存表按同一份配置建好。
    pub(crate) fn library(tag: &str) -> Device {
        library_with(tag, &|_| {})
    }

    /// 同 [library]，迁移进协议 3 之前先跑 [legacy]（往旧表里插迁移前的旧修改记录，迁移把它们收成旧戳）。
    pub(crate) fn library_with(tag: &str, legacy: &dyn Fn(&Device)) -> Device {
        let d = Device::new(tag);
        d.core.sync2_identity(P, T0).unwrap();
        legacy(&d);
        while d.core.sync2_migrate(P, T0, None).unwrap()["done"] != json!(true) {}
        let fdef = json!({"name": "Expression", "ord": 0});
        let tdef =
            |name: &str, ord: i64| json!({"name": name, "ord": ord, "front": "{{Expression}}"});
        d.apply(
            T0,
            vec![
                deck_entity(&default_deck_id(P)),
                note_type("NT"),
                edit("notetype", "NT", "fieldDef/fa", fdef),
                edit("notetype", "NT", "tmplDef/t1", tdef("A", 0)),
                edit("notetype", "NT", "tmplDef/t2", tdef("B", 1)),
                note(N1, "NT"),
                edit("note", N1, "f/fa", json!("猫")),
                edit("note", N1, "tags", json!(["b", "a"])),
                note(N2, "NT"),
                edit("note", N2, "f/fa", json!("犬")),
            ],
        );
        let c1 = crate::registers::card_id(N1, "t1", 0).unwrap();
        d.apply(T0 + 10, vec![review("r1", &c1, T0 + 10, 3, "learn")]);
        d.apply(T0 + DAY, vec![review("r2", &c1, T0 + DAY, 3, "review")]);
        let parsed =
            crate::store::caches::CacheConfig::parse(&serde_json::from_str(&cfg()).unwrap())
                .unwrap();
        let w = d.core.writer().unwrap();
        crate::store::sync2::in_savepoint(&w, |c| crate::store::caches::rebuild(c, P, &parsed))
            .unwrap();
        drop(w);
        d
    }

    fn bytes(p: &Path) -> Vec<u8> {
        std::fs::read(p).unwrap_or_default()
    }

    fn dry(d: &Device, stop: &Stop, progress: &mut dyn FnMut(&str, Option<&str>)) -> Value {
        let old = d._dir.0.join("srs.db");
        let work = d._dir.0.join("work");
        let caches = BTreeMap::from([(P.to_owned(), cfg())]);
        run(
            &old,
            &work,
            Options {
                caches: &caches,
                batch: 3,
                keep: false,
                examples: DEFAULT_EXAMPLES,
                full_examples: false,
                stop,
                progress,
            },
        )
        .unwrap()
    }

    /// 一个做完了换代前提的库：判 `pass`，各类对拍与按规范 ID 的比较都没有差异；旧库与它的 WAL 一个字节不变；临时
    /// 新库删掉了；阶段按顺序报。
    #[test]
    fn a_ready_library_passes_and_the_legacy_file_is_untouched() {
        let d = library("g4dry");
        let old = d._dir.0.join("srs.db");
        let wal = d._dir.0.join("srs.db-wal");
        let (before, wal_before) = (bytes(&old), bytes(&wal));
        let mut stages = Vec::new();
        let r = dry(&d, &Stop::new(), &mut |s, _| {
            if s != "batch" {
                stages.push(s.to_owned())
            }
        });
        assert_eq!(r["verdict"], "pass", "{r:#}");
        let p = &r["profiles"][0];
        assert_eq!(p["verdict"], "pass");
        assert_eq!(p["cacheBaseline"], "rebuilt");
        assert_eq!(p["parity"], json!([]));
        assert_eq!(p["canonical"], json!([]));
        assert_eq!(p["existingCachesVsRebuilt"], json!([]));
        assert_eq!(
            p["oldSidePending"],
            json!({"replayCards": 0, "staleTagNotes": 0})
        );
        assert_eq!(
            p["oldSideStaleResults"],
            json!({"logs": 0, "cards": 0, "examples": []})
        );
        // 单设备、无改名写入者：没有按类判定的差异，报告里照样有这一节（版本 3）。
        let k = &p["knownDifferences"];
        assert_eq!(r["version"], 5);
        assert_eq!(
            (&k["total"], &k["unproven"]),
            (&json!(0), &json!(0)),
            "{k:#}"
        );
        assert_eq!(k["entries"], json!([]));
        assert_eq!(k["truncated"], false);
        assert_eq!(p["closures"]["different"], 0);
        assert_eq!(p["imported"]["devices"], 1);
        assert!(p["settled"]["cacheCards"].as_u64().unwrap() >= 4);
        // 重建各阶段的秒数（BUG-5137：凭报告定位慢在哪一段）。
        let rebuild = p["rebuildStages"].as_object().expect("rebuildStages");
        for s in [
            "scan",
            "closures",
            "aliases",
            "registers",
            "logs",
            "digests",
            "caches",
        ] {
            assert!(
                rebuild.get(s).is_some_and(Value::is_number),
                "{s}: {rebuild:?}"
            );
        }
        assert_eq!(bytes(&old), before);
        assert_eq!(bytes(&wal), wal_before);
        assert!(!d._dir.0.join("work").join(WORK_FILE).exists());
        assert_eq!(
            stages,
            [
                "open",
                "preflight",
                "import",
                "local",
                "salts",
                "rebuild",
                "compare",
                "checks",
                "done"
            ]
        );
    }

    /// 投影与操作日志不一致的库（这里手删一条活着的字段修改）：对拍抓得到——活着的修改、寄存器胜者、笔记缓存行都
    /// 报差异，判 `fail`。例子默认只给 ID，不带笔记内容。
    #[test]
    fn a_projection_that_disagrees_with_the_log_fails() {
        let d = library("g4dryfail");
        d.core
            .writer()
            .unwrap()
            .execute(
                "DELETE FROM srs_field_edits WHERE entity_kind = 'note' AND entity_id = srs_id(?1) AND field_key = 'f/fa'",
                [N2],
            )
            .unwrap();
        let r = dry(&d, &Stop::new(), &mut |_, _| {});
        assert_eq!(r["verdict"], "fail", "{r:#}");
        let p = &r["profiles"][0];
        let whats = |k: &str| -> Vec<String> {
            p[k].as_array()
                .unwrap()
                .iter()
                .map(|d| d["what"].as_str().unwrap().to_owned())
                .collect()
        };
        assert!(whats("parity").contains(&"edits".to_owned()), "{p:#}");
        assert!(whats("parity").contains(&"notes".to_owned()), "{p:#}");
        assert!(
            whats("canonical").contains(&"registerWinners".to_owned()),
            "{p:#}"
        );
        let text = r.to_string();
        assert!(!text.contains("犬"), "examples must not carry note content");
        // BUG-5269：笔记行也报「哪一列不同」，内容列只报字符数；例子里的笔记在 `idTrace` 里摊开两侧的笔记类型与卡。
        let notes = p["parity"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["what"] == "notes")
            .unwrap();
        assert_eq!(notes["sameIdRows"], 1, "{notes:#}");
        let cols = notes["columns"].as_object().unwrap();
        assert!(!cols.is_empty(), "{notes:#}");
        let example = notes["columnExamples"][0].as_str().unwrap();
        assert!(example.starts_with(N2), "{example}");
        assert!(
            example.contains("chars>"),
            "content columns are redacted: {example}"
        );
        assert!(example.contains("(note_type_id NT)"), "{example}");
        let traced = p["idTrace"]["ids"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["id"] == N2)
            .unwrap_or_else(|| panic!("{:#}", p["idTrace"]));
        assert_eq!(traced["oldNote"]["noteType"]["id"], "NT", "{traced:#}");
        assert_eq!(traced["newNote"]["noteType"]["id"], "NT", "{traced:#}");
        assert_eq!(traced["found"], true, "{traced:#}");
        assert!(p["aliases"]["unverifiedExamples"].is_array(), "{p:#}");
    }

    /// `idTrace` 对卡 ID 的派生反查（BUG-5269）：卡行在的给笔记 / 模板 / 序号与「行 ID 正是由这三者派生」，再在相关笔记
    /// × 候选模板 × 序号里列出能派生出它的组合；统计行挂的卡、日志索引里挂的卡也摊开。
    #[test]
    fn the_id_trace_explains_where_a_card_id_comes_from() {
        let d = library("g4drytrace");
        let old = d._dir.0.join("srs.db");
        let work = d._dir.0.join("work");
        let caches = BTreeMap::from([(P.to_owned(), cfg())]);
        let r = run(
            &old,
            &work,
            Options {
                caches: &caches,
                batch: 3,
                keep: true,
                examples: DEFAULT_EXAMPLES,
                full_examples: false,
                stop: &Stop::new(),
                progress: &mut |_, _| {},
            },
        )
        .unwrap();
        assert_eq!(r["verdict"], "pass", "{r:#}");
        let conn = schema::open(&work.join(WORK_FILE)).unwrap();
        let t = Truth::new(&conn);
        let col = t.binding_of(P).unwrap().unwrap().col;
        let canon = CanonMap::load(&t, col).unwrap();
        let c1 = crate::registers::card_id(N1, "t1", 0).unwrap();
        let log: String = conn
            .query_row("SELECT log FROM stats WHERE col = ?1 LIMIT 1", [col], |r| {
                r.get::<_, Ref>(0)
            })
            .unwrap()
            .text();
        let v = trace::id_trace(
            &t,
            col,
            &canon,
            None,
            &[c1.clone(), log.clone(), c1.clone()],
        )
        .unwrap();
        let ids = v["ids"].as_array().unwrap();
        assert_eq!(ids.len(), 2, "duplicates are traced once: {v:#}");
        let card = &ids[0];
        assert_eq!(card["newCard"]["note"]["id"], N1, "{card:#}");
        assert_eq!(card["newCard"]["template"]["id"], "t1", "{card:#}");
        assert_eq!(card["newCard"]["ord"], "0", "{card:#}");
        assert_eq!(card["newCard"]["idFromRow"], true, "{card:#}");
        let derivations: Vec<&str> = card["derivations"]
            .as_array()
            .unwrap()
            .iter()
            .map(|d| d.as_str().unwrap())
            .collect();
        assert!(
            derivations.contains(&format!("card({N1}, t1 [template of a card row], 0)").as_str()),
            "{card:#}"
        );
        assert!(card["newStatLogs"].as_u64().unwrap() >= 1, "{card:#}");
        let stat = &ids[1];
        assert_eq!(stat["newStat"]["card"], c1, "{stat:#}");
        assert_eq!(stat["newLogCard"], c1, "{stat:#}");
        assert!(stat.get("derivations").is_none(), "{stat:#}");
    }

    /// 协议 3 的缓存重建整次失败（这里：一条笔记身份记录缺 `noteTypeId`，`cache.rs` 文件头「与协议 3 的差别」）：缓存层
    /// 三类没比成。profile 报告记下 `cacheBaseline.unavailable`，结论是 `incomplete`、不是 `pass`。
    #[test]
    fn a_failed_protocol_3_cache_rebuild_is_incomplete_not_pass() {
        let d = library_with_a_malformed_note("g4dryincomplete");
        let r = dry(&d, &Stop::new(), &mut |_, _| {});
        assert_eq!(r["verdict"], "incomplete", "{r:#}");
        let p = &r["profiles"][0];
        assert_eq!(p["verdict"], "incomplete", "{p:#}");
        let why = p["cacheBaseline"]["unavailable"]
            .as_str()
            .unwrap_or_default();
        assert!(why.contains("noteTypeId missing"), "{p:#}");
    }

    /// [library] 再加一条身份记录缺 `noteTypeId` 的笔记：协议 3 的缓存重建因此整次失败（`cache.rs` 文件头「与协议 3
    /// 的差别」）。
    pub(crate) fn library_with_a_malformed_note(tag: &str) -> Device {
        const N3: &str = "0193a1b2-0000-7000-8000-0000000000b3";
        let d = library(tag);
        d.apply(
            T0 + 2 * DAY,
            vec![
                json!({"t": "entity", "x": {"id": N3, "p": P, "k": "note", "d": {"createdAt": 1, "guid": N3}}}),
            ],
        );
        d
    }

    /// 同一种库在对拍装置里（`parity::against_protocol_3` 的测试口径）：协议 3 一侧重建失败报成 `caches` 差异，测试门
    /// 不悄悄跳过缓存层（干跑那边记 `incomplete`，对拍装置这边没有这个兜底，只能报差异、靠 `KNOWN` 显式豁免）。
    #[test]
    fn parity_reports_a_failed_protocol_3_cache_rebuild_as_a_caches_diff() {
        let d = library_with_a_malformed_note("g4parincomplete");
        let (_, diff) = crate::store::gen4::parity::imported(&d);
        assert!(
            diff.iter().any(|(what, old, _)| *what == "caches"
                && old.iter().any(|e| e.contains("noteTypeId missing"))),
            "{diff:?}"
        );
    }

    /// 协议 3 一侧的缓存行拿不到时按失败发生在哪一段分类型：重建这一步（协议 3 自己的代码）失败是 `Protocol3`，不论
    /// 错误文本是什么；解析配置等搭环境的失败是 `Setup`。失败之后临时表照样删掉。
    #[test]
    fn old_cache_errors_are_typed_by_where_they_fail() {
        let d = library("g4dryoldtyped");
        let c = open_legacy(&d._dir.0.join("srs.db")).unwrap();
        let e = old_caches_with(&c, P, &cfg(), &[], &mut |_, _, _| {
            Err("any text at all".to_owned())
        })
        .unwrap_err();
        assert_eq!(e, OldCachesError::Protocol3("any text at all".to_owned()));
        let temps: i64 = c
            .query_row("SELECT COUNT(*) FROM temp.sqlite_schema", [], |r| r.get(0))
            .unwrap();
        assert_eq!(temps, 0);
        let e = old_caches_with(&c, P, "not json", &[], &mut |_, _, _| Ok(())).unwrap_err();
        assert!(matches!(e, OldCachesError::Setup(_)), "{e:?}");
    }

    /// 整个库的结论：对拍没做全的 profile 不让整库 `pass`，但更重的结论压过它。
    #[test]
    fn an_incomplete_profile_keeps_the_library_from_passing() {
        assert_eq!(overall(&["pass", "incomplete"]), "incomplete");
        assert_eq!(overall(&["incomplete", "blocked"]), "blocked");
        assert_eq!(overall(&["incomplete", "fail"]), "fail");
        assert_eq!(overall(&["pass", "pass"]), "pass");
    }

    /// 没做完换代前提（协议 3 身份有了、旧行还没迁成操作）：判 `blocked`，给出原因，不灌入。
    #[test]
    fn a_library_that_is_not_ready_is_blocked() {
        let d = Device::new("g4dryblock");
        d.core.sync2_identity(P, T0).unwrap();
        let r = dry(&d, &Stop::new(), &mut |_, _| {});
        assert_eq!(r["verdict"], "blocked", "{r:#}");
        assert!(
            r["profiles"][0]["blockers"][0]
                .as_str()
                .unwrap()
                .contains("not migrated"),
            "{r:#}"
        );
    }

    /// 中断：开始前就停、或跑到一半（重建那一步）停，都报 `cancelled`、删掉临时新库、旧库不变。
    #[test]
    fn a_stopped_run_is_cancelled_and_leaves_nothing_behind() {
        let d = library("g4drystop");
        let old = d._dir.0.join("srs.db");
        let before = bytes(&old);
        let stop = Stop::new();
        stop.stop();
        let r = dry(&d, &stop, &mut |_, _| {});
        assert_eq!(r["verdict"], "cancelled", "{r:#}");
        let stop = Stop::new();
        let r = dry(&d, &stop, &mut |s, _| {
            if s == "rebuild" {
                stop.stop();
            }
        });
        assert_eq!(r["verdict"], "cancelled", "{r:#}");
        assert!(!d._dir.0.join("work").join(WORK_FILE).exists());
        assert_eq!(bytes(&old), before);
    }

    /// 协议 3 的缓存基准建在影子临时表上：旧库的缓存表行数不变，临时表用完删掉；只读连接直接写主库被拒。
    #[test]
    fn the_legacy_cache_baseline_is_built_in_temp_tables_only() {
        let d = library("g4dryshadow");
        let old = d._dir.0.join("srs.db");
        let c = open_legacy(&old).unwrap();
        let count = |c: &Connection| -> i64 {
            c.query_row("SELECT COUNT(*) FROM main.srs_cards_cache", [], |r| {
                r.get(0)
            })
            .unwrap()
        };
        let n = count(&c);
        let (notes, cards, stats) = old_caches(&c, P, &cfg(), &[]).unwrap();
        assert_eq!((notes.len(), cards.len(), stats.len()), (2, 4, 2));
        assert_eq!(count(&c), n);
        let temps: i64 = c
            .query_row("SELECT COUNT(*) FROM temp.sqlite_schema", [], |r| r.get(0))
            .unwrap();
        assert_eq!(temps, 0);
        assert!(c.execute("DELETE FROM main.srs_cards_cache", []).is_err());
    }

    /// 设计 §10 第 14 条的合成实测：协议 3 迁移过的旧修改记录（带旧戳）被清除之后，从槽重建的旧戳闭包比老设备累计的
    /// `sync2_legacy` 小——空洞不带旧戳，`sync2_legacy` 只增不减。干跑照报（`closures`），不计入判定。
    #[test]
    fn a_purged_heritage_edit_shrinks_the_rebuilt_closure() {
        let d = Device::new("g4dryclosure");
        let legacy = |writer: &str, s: i64, note: &str, vv: Value| {
            let id = crate::registers::edit_id(writer, s);
            let j = json!({"ctx": {"vv": vv}, "e": note, "f": "f/fa", "hlc": format!("{}:0:{writer}", T0 - 1000 + s),
                           "id": id, "k": "note", "p": P, "s": s, "ts": "wall", "v": format!("v{s}"), "w": writer});
            d.core
                .writer()
                .unwrap()
                .execute(
                    "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
                     VALUES (srs_id(?1), srs_id(?2), 'note', srs_id(?3), 'f/fa', ?4, ?5, ?6)",
                    params![id, P, note, writer, s, j.to_string()],
                )
                .unwrap();
        };
        // 旧写入者 old1 只写过 N1（seq 1、2），old2 只写过 N2、没见过 old1。
        legacy("old1", 1, N1, json!({}));
        legacy("old1", 2, N1, json!({"old1": 1}));
        legacy("old2", 1, N2, json!({}));
        d.core.sync2_identity(P, T0).unwrap();
        d.core.sync2_migrate(P, T0, None).unwrap();
        let before = dry(&d, &Stop::new(), &mut |_, _| {});
        assert_eq!(
            before["profiles"][0]["closures"]["different"], 0,
            "{before:#}"
        );
        d.core.sync2_purge(P, "note", N1, T0 + 1).unwrap();
        let after = dry(&d, &Stop::new(), &mut |_, _| {});
        let c = &after["profiles"][0]["closures"];
        assert_eq!(c["different"], 1, "{after:#}");
        let dev = &c["devices"][0];
        // 老设备累计的仍见过 old1 的 1、2；从槽重建的只剩 N2 上 old2 那条的旧戳。
        assert_eq!(dev["dotsOnlyOld"], 2, "{after:#}");
        assert_eq!(dev["dotsOnlyNew"], 0, "{after:#}");
    }

    /// 真实样本库的私有拷贝上干跑一遍，打印报告；别名各类的数与 G3 探针（证据取旧投影表、另一份实现）同口径对照。
    ///
    /// `FUSHI_GEN4_SAMPLE_DB=<srs.db 的私有拷贝> [FUSHI_GEN4_CACHE_CFG_FILE=<CacheConfig JSON>] [FUSHI_GEN4_WORK=<目录>]
    ///  cargo test --release --lib gen4_sample_dryrun -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn gen4_sample_dryrun() {
        let Ok(path) = std::env::var("FUSHI_GEN4_SAMPLE_DB") else {
            println!("FUSHI_GEN4_SAMPLE_DB not set");
            return;
        };
        let old = PathBuf::from(&path);
        let work = std::env::var("FUSHI_GEN4_WORK").map_or_else(
            |_| std::env::temp_dir().join("fushi-gen4-dryrun"),
            PathBuf::from,
        );
        let src = open_legacy(&old).unwrap();
        let profiles = legacy::profiles(&src).unwrap();
        drop(src);
        let cfg = std::env::var("FUSHI_GEN4_CACHE_CFG_FILE")
            .ok()
            .map(|p| std::fs::read_to_string(p).unwrap());
        let caches: BTreeMap<String, String> = match cfg {
            Some(c) => profiles.iter().map(|p| (p.clone(), c.clone())).collect(),
            None => BTreeMap::new(),
        };
        let stop = Stop::new();
        let started = Instant::now();
        let mut progress = |s: &str, p: Option<&str>| {
            println!(
                "SAMPLE stage {s} {} at_s {:.1} peak_mb {:.0}",
                p.unwrap_or("-"),
                started.elapsed().as_secs_f64(),
                peak_mem_mb().0
            );
        };
        let r = run(
            &old,
            &work,
            Options {
                caches: &caches,
                batch: 20_000,
                keep: std::env::var("FUSHI_GEN4_KEEP").is_ok(),
                examples: DEFAULT_EXAMPLES,
                full_examples: false,
                stop: &stop,
                progress: &mut progress,
            },
        )
        .unwrap();
        println!(
            "SAMPLE report {}",
            serde_json::to_string_pretty(&r).unwrap()
        );
        // G3 探针（另一份实现，证据取旧投影表）。
        let uri = format!("file:///{}?immutable=1", path.replace('\\', "/"));
        let c = Connection::open_with_flags(
            &uri,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
        )
        .unwrap();
        crate::store::ids::register(&c).unwrap();
        let g3 = crate::gen4_ids::probe::alias_table_counts(&c);
        let a = &r["profiles"][0]["aliases"];
        let ours = [
            a["salted"].as_u64().unwrap_or(0),
            a["derived"].as_u64().unwrap_or(0),
            a["fallback"].as_u64().unwrap_or(0),
            a["unverified"].as_u64().unwrap_or(0),
            a["writers"].as_u64().unwrap_or(0),
        ];
        println!(
            "SAMPLE aliases dryrun {ours:?} g3_probe {g3:?} same {}",
            ours == g3
        );
        // 留下了临时新库：逐个对别名表，差出来的按探针一侧的来源归类。
        let kept = work.join(WORK_FILE);
        if kept.exists() {
            let probe = crate::gen4_ids::probe::alias_table_sources(&c);
            let n = Connection::open_with_flags(&kept, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
            let mut ours: std::collections::HashMap<[u8; 16], i64> =
                std::collections::HashMap::new();
            let mut stmt = n.prepare("SELECT id, how FROM alias_ix").unwrap();
            for row in stmt
                .query_map([], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?)))
                .unwrap()
            {
                let (id, how) = row.unwrap();
                if let Ok(a) = <[u8; 16]>::try_from(id.as_slice()) {
                    ours.insert(a, how);
                }
            }
            let mut only_probe: BTreeMap<String, u64> = BTreeMap::new();
            let mut slot_differs: BTreeMap<String, u64> = BTreeMap::new();
            for (id, (slot, from)) in &probe {
                let key = format!("slot{slot} {}", from.join("+"));
                match ours.get(&id.0) {
                    None => *only_probe.entry(key).or_default() += 1,
                    Some(how) if (*how - 1) as usize != (*slot).min(3) => {
                        *slot_differs.entry(format!("{key} how{how}")).or_default() += 1
                    }
                    _ => {}
                }
            }
            let only_ours = ours
                .keys()
                .filter(|k| !probe.contains_key(&crate::sync2::id::Id(**k)))
                .count();
            println!(
                "SAMPLE alias diff onlyProbe {only_probe:?} slotDiffers {slot_differs:?} onlyOurs {only_ours} ourRows {}",
                ours.len()
            );
            drop(stmt);
            drop(n);
            let _ = std::fs::remove_file(&kept);
        }
    }

    // ------------------------------------------------------------ 按类判定的已知差异（端到端）

    const N3: &str = "0193a1b2-0000-7000-8000-0000000000b3";

    /// 本 profile 下旧并入改名的写入者 `w1` 的新名字（盐 = profile uid）。
    fn merged_w1() -> String {
        format!(
            "merged-{}~w1",
            crate::gen4_ids::rules::merged_writer_hash(P, "w1").text()
        )
    }

    /// 旧库里笔记 [N3] 上一条带旧戳的修改记录（与 `tests_dedup.rs` 的 `legacy_edit` 同一个形状）：物理时刻
    /// `T0 + physical`。
    fn legacy_edit(d: &Device, writer: &str, s: i64, key: &str, v: &str, vv: Value, physical: i64) {
        let id = crate::registers::edit_id(writer, s);
        let j = json!({"ctx": {"vv": vv}, "e": N3, "f": key, "hlc": format!("{}:0:{writer}", T0 + physical),
                       "id": id, "k": "note", "p": P, "s": s, "ts": "wall", "v": v, "w": writer})
        .to_string();
        d.core
            .writer()
            .unwrap()
            .execute(
                "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
                 VALUES (srs_id(?1), srs_id(?2), 'note', srs_id(?3), ?4, ?5, ?6, ?7)",
                rusqlite::params![id, P, N3, key, writer, s, j],
            )
            .unwrap();
    }

    /// [library] 再加一条笔记 [N3]（同一个笔记类型，字段内容只来自 [edits] 在迁移前写的旧修改记录），缓存表照同一份
    /// 配置重建。
    fn library_with_legacy(tag: &str, edits: &dyn Fn(&Device)) -> Device {
        let d = library_with(tag, edits);
        d.apply(T0 + 2 * DAY, vec![note(N3, "NT")]);
        let parsed =
            crate::store::caches::CacheConfig::parse(&serde_json::from_str(&cfg()).unwrap())
                .unwrap();
        let w = d.core.writer().unwrap();
        crate::store::sync2::in_savepoint(&w, |c| crate::store::caches::rebuild(c, P, &parsed))
            .unwrap();
        drop(w);
        d
    }

    /// `knownDifferences.entries` 里 `f/fa` 上的那几条。
    fn known_on_field(p: &Value) -> Vec<Value> {
        p["knownDifferences"]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|e| e["key"] == "f/fa")
            .cloned()
            .collect()
    }

    /// 佐证得了、胜者没变（「有冲突变没冲突」，样本库的绝大多数）：`(w1, 1)` 原值判与 `(w1, 2)`（上下文只写了改名后的
    /// `merged:1`）并发，按类判被盖掉；`(merged, 1)` 是同一条记录（同 seq 同 HLC）。列进 `knownDifferences`、佐证是副本，
    /// 结论不是 `fail`。胜者没变，缓存行只盖 N3 笔记行的 `pending_decision`（协议 3 任一寄存器有冲突即待裁决，两侧
    /// 确实不同），其余列照比、两侧相同；卡行一列不盖。
    #[test]
    fn a_proven_difference_with_the_same_winner_is_listed_and_its_rows_still_compared() {
        let merged = merged_w1();
        let d = library_with_legacy("g4dryknown", &|d| {
            legacy_edit(d, "w1", 1, "f/fa", "x", json!({}), 100);
            legacy_edit(d, &merged, 1, "f/fa", "x", json!({}), 100);
            legacy_edit(d, "w1", 2, "f/fa", "y", json!({&merged: 1}), 200);
        });
        let r = dry(&d, &Stop::new(), &mut |_, _| {});
        let p = &r["profiles"][0];
        assert_eq!(p["verdict"], "pass", "{p:#}");
        assert_eq!(p["parity"], json!([]), "{p:#}");
        assert_eq!(p["canonical"], json!([]), "{p:#}");
        let k = &p["knownDifferences"];
        assert_eq!(k["unproven"], 0, "{k:#}");
        let got = known_on_field(p);
        assert_eq!(got.len(), 1, "{k:#}");
        let e = &got[0];
        assert_eq!(e["kind"], "note");
        assert_eq!(e["entity"], N3);
        assert_eq!(
            (&e["rawConflict"], &e["classConflict"], &e["winnerChanged"]),
            (&json!(true), &json!(false), &json!(false)),
            "{e:#}"
        );
        assert_eq!(e["proven"], true);
        assert_eq!(e["dominated"].as_array().unwrap().len(), 1, "{e:#}");
        let dom = &e["dominated"][0];
        assert_eq!((&dom["writer"], &dom["seq"]), (&json!("w1"), &json!(1)));
        assert_eq!(dom["canonicalWriter"], "w1");
        assert_eq!(dom["evidence"], json!({"copy": merged}));
        assert_eq!(e["revived"], json!([]));
        assert_eq!(k["byCategory"]["note f"]["proven"], 1, "{k:#}");
        // 胜者没变：只盖这条笔记的 `pending_decision`，卡行不盖。
        assert_eq!(
            (&k["cacheNotesMasked"], &k["cacheCardsMasked"]),
            (&json!(1), &json!(0)),
            "{k:#}"
        );
        assert_eq!(
            (&k["cacheRowsMasked"], &k["cacheRowsMaskedDiffer"]),
            (&json!(2), &json!(2)),
            "{k:#}"
        );
    }

    /// 佐证不了的（被盖掉的 `(merged, 5)` 在另一个名字下没有副本，5 也不在已证明的重叠区间 `[1, 1]` 里）：记成
    /// `parity` 的 `classRegisters`，结论 `fail`（所有者定案「对不上的按 bug 处理」）。
    #[test]
    fn an_unproven_difference_fails_the_run() {
        let merged = merged_w1();
        let d = library_with_legacy("g4dryunproven", &|d| {
            legacy_edit(d, "w1", 1, "f/pp", "p", json!({}), 50);
            legacy_edit(d, &merged, 1, "f/pp", "p", json!({}), 50);
            legacy_edit(d, &merged, 5, "f/fa", "x", json!({}), 100);
            legacy_edit(d, "v", 1, "f/fa", "y", json!({"w1": 5}), 200);
        });
        let r = dry(&d, &Stop::new(), &mut |_, _| {});
        let p = &r["profiles"][0];
        assert_eq!(r["verdict"], "fail", "{r:#}");
        assert_eq!(p["verdict"], "fail");
        let class = p["parity"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["what"] == "classRegisters")
            .cloned()
            .unwrap_or_else(|| panic!("{p:#}"));
        assert_eq!(class["onlyOld"], 1, "{class:#}");
        let k = &p["knownDifferences"];
        assert_eq!(k["unproven"], 1, "{k:#}");
        let got = known_on_field(p);
        assert_eq!(got.len(), 1, "{k:#}");
        assert_eq!(got[0]["proven"], false);
        assert_eq!(got[0]["dominated"][0]["evidence"], "none", "{:#}", got[0]);
    }

    /// 佐证得了、胜者变了（HLC 平手：原名 `merged-…` < `v`，`v` 那条胜；归回成 `w1` > `v`，`merged` 那条胜）：N3 的
    /// 笔记行只盖 `f/…` 喂得到的列（`sort_field` 等，两侧确实不同），行本身照比；结论不是 `fail`。
    #[test]
    fn a_proven_winner_change_masks_only_the_columns_it_feeds() {
        let merged = merged_w1();
        let d = library_with_legacy("g4drymasked", &|d| {
            legacy_edit(d, "w1", 1, "f/pp", "p", json!({}), 50);
            legacy_edit(d, &merged, 1, "f/pp", "p", json!({}), 50);
            legacy_edit(d, &merged, 2, "f/fa", "a", json!({}), 100);
            legacy_edit(d, "v", 1, "f/fa", "b", json!({}), 100);
        });
        let r = dry(&d, &Stop::new(), &mut |_, _| {});
        let p = &r["profiles"][0];
        assert_eq!(p["verdict"], "pass", "{p:#}");
        assert_eq!(p["parity"], json!([]), "{p:#}");
        assert_eq!(p["canonical"], json!([]), "{p:#}");
        let k = &p["knownDifferences"];
        let got = known_on_field(p);
        assert_eq!(got.len(), 1, "{k:#}");
        let e = &got[0];
        assert_eq!(
            (&e["winnerChanged"], &e["hlcTie"], &e["proven"]),
            (&json!(true), &json!(true), &json!(true)),
            "{e:#}"
        );
        assert_eq!(k["cacheNotesMasked"], 1, "{k:#}");
        // N3 的两张卡（两条模板）盖 `hidden` / `freq_rank`。
        assert_eq!(k["cacheCardsMasked"], 2, "{k:#}");
        assert!(k["cacheRowsMaskedDiffer"].as_u64().unwrap() >= 2, "{k:#}");
    }

    /// 盖了列的行里，没被盖住的列上的真差异照样计入：胜者变了的那条笔记（同上）另有一条协议 3 投影里丢了的 `deck`
    /// 修改（旧代码按投影重建出 `deck_id = ∅`，新代按日志是默认牌组）。`f/…` 喂不到 `deck_id`，`notes` 报差异、
    /// 结论 `fail`——整行豁免时这一条会被藏起来。
    #[test]
    fn an_unrelated_column_on_a_masked_row_still_fails() {
        let merged = merged_w1();
        let d = library_with_legacy("g4drymaskedbug", &|d| {
            legacy_edit(d, "w1", 1, "f/pp", "p", json!({}), 50);
            legacy_edit(d, &merged, 1, "f/pp", "p", json!({}), 50);
            legacy_edit(d, &merged, 2, "f/fa", "a", json!({}), 100);
            legacy_edit(d, "v", 1, "f/fa", "b", json!({}), 100);
        });
        d.apply(
            T0 + 3 * DAY,
            vec![edit("note", N3, "deck", json!(default_deck_id(P)))],
        );
        d.core
            .writer()
            .unwrap()
            .execute(
                "DELETE FROM srs_field_edits WHERE entity_kind = 'note' AND entity_id = srs_id(?1) AND field_key = 'deck'",
                [N3],
            )
            .unwrap();
        let r = dry(&d, &Stop::new(), &mut |_, _| {});
        let p = &r["profiles"][0];
        assert_eq!(p["verdict"], "fail", "{p:#}");
        let notes = p["parity"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["what"] == "notes")
            .cloned()
            .unwrap_or_else(|| panic!("{p:#}"));
        assert_eq!(notes["examplesOld"], json!([N3]), "{notes:#}");
        assert_eq!(notes["examplesNew"], json!([N3]), "{notes:#}");
        assert_eq!(p["knownDifferences"]["unproven"], 0);
        assert_eq!(known_on_field(p)[0]["winnerChanged"], true);
    }
}
