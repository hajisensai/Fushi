//! 真实库干跑（设计 §6.1、§8 G4 / G4b）：**旧库只读** → 临时新库 → `rebuild_all` → 对拍报告。
//!
//! 迁移（G7）要做的前五步在这里原样走一遍，只是不提交：
//!
//! 1. 旧库用只读连接打开（`SQLITE_OPEN_READ_ONLY`；WAL 下读者照常更新 `-shm` 里的读标记，那不是库内容），整个干跑在一个读事务里，看到的是同一个快照——
//!    app 同时在写也不影响结果，也不会被它拖住（WAL 下读不挡写；代价是干跑期间 WAL 并不回去，结束后照常）。
//!    旧库一个字节不写：协议 3 一侧的缓存重建写进同名的**临时表**（`temp` 库里的同名表遮住 `main` 的，见 [old_caches]）。
//! 2. 先过 `legacy::preflight`（换代前必须在旧代码上做完的事）；没做完的 profile 报 `blocked`、不往下走。
//! 3. 按 profile 把操作日志转译、灌进工作目录里的临时新代文件（`import.rs`），由一台假想的迁移设备在它的原生日志里写
//!    一条 `Salts`（本机 uid ∪ 已退役 uid，§6.1 第 7 步），再 `rebuild_all`（索引、别名、摘要、缓存全程）。
//! 4. 对拍（`compare.rs`，与测试装置同一份比法）。基准是**冻结的旧代码对旧库全量重建出来的缓存**，不是旧库里现成的
//!    缓存表（它允许过期）；现成的与重建的另比一次，单列（§10 第 7 条，不计入判定）。协议 3 自己还欠着收尾的卡与笔记
//!    （待重放集合、没刷新的合成标签行）只读连接上做不了，跳过并计数。
//! 5. 在对拍之外再按规范 ID 比（§6.1 第 5 步、§5.3）：每个寄存器的胜者、每张规范卡的调度状态、每张规范卡（含不在缓存
//!    里的历史血统卡）名下的规范日志与有效复习。
//!
//! 另外几项只报数、不计入判定：旧戳闭包对 `sync2_legacy`（§10 第 14 条）、归回去的改名写入者的旧戳逐条对照（G3 没验的
//! 第一项）、验不上的日志重建后是否仍挂在同一张规范卡上（G3 没验的第二项）、别名表各类的数（与 G3 探针同口径）。
//!
//! 可中断：[Stop::stop] 置位并打断两条连接上正在跑的语句；灌入每批提交前、各阶段之间都查一次。中断、出错、跑完都删掉
//! 临时新库（[Options::keep] 时留下）。报告只有计数与 ID，不含笔记内容（[Options::full_examples] 时例子给整行，只供本地
//! 排查用）。

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, InterruptHandle, OpenFlags, OptionalExtension, params};
use serde_json::{Map, Value, json};

use super::alias::{A_UNVERIFIED, AliasCounts};
use super::cache::CFG_KEY;
use super::compare::{
    self, CARD_COLS, CacheRows, Diff, NOTE_COLS, Pair, STAT_COLS, Skip, rows_of, texts,
};
use super::derive::{Index, R_CONFLICT, R_WINNER, Ref, Settled, body_of};
use super::import::{Imported, import_legacy_checked};
use super::legacy;
use super::schema::{self, sql};
use super::truth::Truth;
use crate::gen4::op::{Body4, Op4};
use crate::gen4::stamp::{HeritageStamp, StampHlc};
use crate::registers::{StoredEdit, judge_register};
use crate::store::sync2::collection_of;
use crate::store::sync2::config::default_deck_id;
use crate::sync2::dvv::Dvv;
use crate::sync2::hlc::Hlc;
use crate::sync2::id::{Id, Key};
use crate::sync2::vv::OpId;

/// 报告格式的版本（[run] 的返回值里的 `version`）。
pub const REPORT_VERSION: i64 = 1;

/// 被中断时的错误文本（[run] 返回 `Ok`、`verdict = "cancelled"`；只有内部各步之间用它传）。
pub const CANCELLED: &str = "gen4 dry run: cancelled";

/// 临时新库在工作目录里的文件名。
pub const WORK_FILE: &str = "gen4-dryrun.db";

/// 假想的迁移设备（写那条 `Salts`）。只在临时新库里出现。
const REHEARSAL_DEVICE: Id = Id([0x6d; 16]);

/// 报告里每类差异最多给几个例子。
pub const DEFAULT_EXAMPLES: usize = 8;

/// 空间余量（与 `store/schema.rs` 的升级余量同值）。
const SPACE_MARGIN: u64 = 64 << 20;

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

    fn attach(&self, c: &Connection) {
        if let Ok(mut hs) = self.handles.lock() {
            hs.push(c.get_interrupt_handle());
        }
        if self.stopped() {
            c.get_interrupt_handle().interrupt();
        }
    }

    fn detach_all(&self) {
        if let Ok(mut hs) = self.handles.lock() {
            hs.clear();
        }
    }

    fn check(&self) -> Result<(), String> {
        if self.stopped() {
            Err(CANCELLED.to_owned())
        } else {
            Ok(())
        }
    }
}

/// 干跑的参数。
pub struct Options<'a> {
    /// 每个 profile 的缓存配置（`CacheConfig` 的 JSON 文本：默认牌组、内置笔记类型的代码默认值），与 app 交给旧内核的是
    /// 同一份。没给的 profile 只有默认牌组（内置类型的笔记行会对不上，差异照报）。
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
    /// 进度：(阶段, profile)。阶段：`open`、`preflight`、`import`、`rebuild`、`compare`、`checks`、`done`。
    pub progress: &'a mut dyn FnMut(&str, Option<&str>),
}

impl Options<'_> {
    fn note(&mut self, stage: &str, profile: Option<&str>) {
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

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64)
}

fn secs(t: Instant) -> f64 {
    (t.elapsed().as_secs_f64() * 10.0).round() / 10.0
}

fn mb(x: f64) -> f64 {
    x.round()
}

fn file_len(p: &Path) -> u64 {
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
            let one = profile_run(&src, &t, &profile, &mut opts);
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

/// 整个库的结论：有出错的报 `error`，否则有不过的报 `fail`，否则有没做完前提的报 `blocked`，都过了才 `pass`；
/// 一个 profile 都没有是 `empty`。
fn overall(verdicts: &[&str]) -> &'static str {
    if verdicts.is_empty() {
        "empty"
    } else if verdicts.contains(&"error") {
        "error"
    } else if verdicts.contains(&"fail") {
        "fail"
    } else if verdicts.contains(&"blocked") {
        "blocked"
    } else {
        "pass"
    }
}

fn profile_run(
    src: &Connection,
    t: &Truth<'_>,
    profile: &str,
    opts: &mut Options<'_>,
) -> Result<Value, String> {
    let mut out = Map::new();
    out.insert("profile".into(), json!(profile));
    opts.note("preflight", Some(profile));
    let blockers = legacy::preflight(src, profile)?;
    if !blockers.is_empty() {
        out.insert("verdict".into(), json!("blocked"));
        out.insert("blockers".into(), json!(blockers));
        return Ok(Value::Object(out));
    }
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
    let imported = import_legacy_checked(src, profile, t, col, opts.batch.max(1), &mut || {
        stop.check()
    })?;
    out.insert("importS".into(), json!(secs(started)));
    out.insert("imported".into(), imported_json(&imported));
    out.insert("peakMbAfterImport".into(), json!(mb(peak_mem_mb().0)));

    // 盐（§6.1 第 7 步）+ 重建。
    opts.note("rebuild", Some(profile));
    opts.stop.check()?;
    let salts = legacy::salts(src, profile)?;
    out.insert("salts".into(), json!(salts.len()));
    let started = Instant::now();
    let settled = t.tx(|t| {
        if t.last_of(col, &REHEARSAL_DEVICE)? == 0 {
            let body = Body4::salts(salts.iter().cloned()).map_err(|e| format!("{e:?}"))?;
            let op = Op4::of(
                OpId {
                    device: REHEARSAL_DEVICE,
                    seq: 1,
                },
                Hlc {
                    wall: now_ms(),
                    logical: 0,
                    device: REHEARSAL_DEVICE,
                },
                std::sync::Arc::new(t.applied(col)?),
                &body,
            );
            t.append_native(col, &op)?;
        }
        Index::new(t, col).rebuild_all()
    })?;
    out.insert("rebuildS".into(), json!(secs(started)));
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
    let mut peaks = Map::new();
    let mut mark = |what: &str| {
        peaks.insert(what.into(), json!(mb(peak_mem_mb().0)));
    };
    let (diff, baseline) = compare::against_protocol_3(
        src,
        profile,
        t,
        col,
        &mut |src: &Connection, profile: &str, cfg: &str| old_caches(src, profile, cfg),
        &skip,
    )?;
    mark("parity");
    let failing = !diff.is_empty();
    out.insert("parity".into(), diff_json(&diff, opts));
    if let Some(rebuilt) = &baseline {
        let stale = existing_vs_rebuilt(src, profile, rebuilt, &skip)?;
        out.insert("existingCachesVsRebuilt".into(), diff_json(&stale, opts));
    }
    mark("existingCaches");
    out.insert("compareS".into(), json!(secs(started)));

    // 按规范 ID 比。
    opts.note("checks", Some(profile));
    opts.stop.check()?;
    let started = Instant::now();
    let canon = Canon::load(t, col)?;
    mark("canonLoad");
    let regs = registers(src, profile, t, col)?;
    mark("registerWinners");
    let mut canonical_diff = differences_of(regs);
    match &baseline {
        Some(old) => canonical_pairs(
            src,
            profile,
            t,
            col,
            &canon,
            &skip,
            old,
            &mut canonical_diff,
        )?,
        // 没设缓存配置 / 协议 3 的缓存重建因身份记录不成形失败：没有旧侧的卡行与统计行，只比日志。
        None => canonical_pairs(
            src,
            profile,
            t,
            col,
            &canon,
            &skip,
            &Default::default(),
            &mut canonical_diff,
        )?,
    }
    drop(baseline);
    mark("canonicalPairs");
    canonical_diff.sort_by_key(|d| d.0);
    let failing = failing || !canonical_diff.is_empty();
    out.insert("canonical".into(), diff_json(&canonical_diff, opts));
    out.insert(
        "canonicalCounts".into(),
        canon.counts_json(src, profile, t, col)?,
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
        json!(if failing { "fail" } else { "pass" }),
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
/// 笔记 ID、`media` 的内容哈希），不带笔记内容。
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
                json!({
                    "what": what,
                    "onlyOld": old_only.len(),
                    "onlyNew": new_only.len(),
                    "examplesOld": ex(what, old_only),
                    "examplesNew": ex(what, new_only),
                })
            })
            .collect(),
    )
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

/// 协议 3 缓存重建要写的表。
const CACHE_TABLES: [&str; 4] = [
    "srs_notes_cache",
    "srs_cards_cache",
    "srs_stat_reviews",
    "sync2_cache_pending",
];

/// 冻结的旧代码（`store::caches::rebuild`）对旧库全量重建出来的缓存行，旧库一个字节不写：在连接的 `temp` 库里按
/// `main` 的定义建同名的空表与索引——不带库名的表名先找 `temp`，旧代码的读写都落在这几张临时表上——重建、读行、删表。
fn old_caches(src: &Connection, profile: &str, cfg: &str) -> Result<CacheRows, String> {
    let parsed = crate::store::caches::CacheConfig::parse(
        &serde_json::from_str(cfg).map_err(|e| e.to_string())?,
    )?;
    let defs: Vec<(String, String, String)> = {
        let marks = CACHE_TABLES.map(|t| format!("'{t}'")).join(", ");
        src.prepare(&format!(
            "SELECT type, tbl_name, sql FROM main.sqlite_schema WHERE tbl_name IN ({marks}) \
             AND type IN ('table', 'index') AND sql IS NOT NULL ORDER BY type DESC, name"
        ))
        .map_err(sql)?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?
    };
    let made: BTreeSet<&str> = defs
        .iter()
        .filter(|d| d.0 == "table")
        .map(|d| d.1.as_str())
        .collect();
    if made.len() != CACHE_TABLES.len() {
        return Err(format!(
            "gen4 dry run: the legacy library lacks cache tables (has {made:?})"
        ));
    }
    let shadow = (|| -> Result<CacheRows, String> {
        for (kind, _, ddl) in &defs {
            let ddl = match kind.as_str() {
                "table" => ddl.replacen("CREATE TABLE ", "CREATE TEMP TABLE ", 1),
                // 不带库名的索引建在它的表所在的库（这里是 temp）。
                _ => ddl.clone(),
            };
            src.execute_batch(&ddl).map_err(sql)?;
        }
        crate::store::caches::rebuild(src, profile, &parsed)?;
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
            )?,
            rows_of(
                src,
                "temp.srs_cards_cache",
                &olds(CARD_COLS),
                filter,
                &profile,
            )?,
            rows_of(
                src,
                "temp.srs_stat_reviews",
                &olds(STAT_COLS),
                filter,
                &profile,
            )?,
        ))
    })();
    for t in CACHE_TABLES {
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
    let notes = rows_of(
        src,
        "main.srs_notes_cache",
        &olds(NOTE_COLS),
        filter,
        &profile,
    )?;
    let cards = rows_of(
        src,
        "main.srs_cards_cache",
        &olds(CARD_COLS),
        filter,
        &profile,
    )?;
    let stats = rows_of(
        src,
        "main.srs_stat_reviews",
        &olds(STAT_COLS),
        filter,
        &profile,
    )?;
    Ok(differences_of([
        (
            "notes",
            set(&notes, &keep_note),
            set(&rebuilt.0, &keep_note),
        ),
        (
            "cards",
            set(&cards, &keep_card),
            set(&rebuilt.1, &keep_card),
        ),
        (
            "stats",
            set(&stats, &keep_stat),
            set(&rebuilt.2, &keep_stat),
        ),
    ]))
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
    let skip = |ent: &str, key: &str| key == "tags" || (key == "deleted" && held.contains(ent));
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
        let e = t
            .entry_by_key(k)?
            .ok_or_else(|| format!("gen4 dry run: register row {k} has no op"))?;
        let Some(Body4::Edit(ed)) = body_of(&e) else {
            return Err(format!("gen4 dry run: register row {k} is not an edit"));
        };
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

/// 别名表的非恒等部分（出现过的 ID → 规范 ID）。
struct Canon {
    map: HashMap<[u8; 16], [u8; 16]>,
}

impl Canon {
    fn load(t: &Truth<'_>, col: i64) -> Result<Canon, String> {
        let mut map = HashMap::new();
        let mut stmt = t
            .conn()
            .prepare("SELECT id, canon FROM alias_ix WHERE col = ?1 AND canon != id")
            .map_err(sql)?;
        let rows = stmt
            .query_map([col], |r| {
                Ok((r.get::<_, [u8; 16]>(0)?, r.get::<_, [u8; 16]>(1)?))
            })
            .map_err(sql)?;
        for row in rows {
            let (id, canon) = row.map_err(sql)?;
            map.insert(id, canon);
        }
        Ok(Canon { map })
    }

    fn of(&self, r: &Ref) -> Ref {
        match r {
            Ref::Uuid(b) => Ref::Uuid(*self.map.get(b).unwrap_or(b)),
            Ref::Text(_) => r.clone(),
        }
    }

    fn text(&self, s: &str) -> String {
        self.of(&Ref::of(&Key::of(s))).text()
    }

    /// 各种规范类的大小：规范卡 / 规范日志各有多少、其中吃进不止一个出现过的 ID 的有多少（§5.3 的基线：2,856 / 47,228）。
    fn counts_json(
        &self,
        src: &Connection,
        profile: &str,
        t: &Truth<'_>,
        col: i64,
    ) -> Result<Value, String> {
        let classes = |ids: &[Ref]| -> (usize, usize, usize) {
            let mut by: BTreeMap<Ref, usize> = BTreeMap::new();
            for id in ids {
                *by.entry(self.of(id)).or_default() += 1;
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
}

/// 按规范 ID 的三类（§6.1 第 5 步）：
/// - `canonicalCards`：每张规范卡的调度状态（队列、到期、稳定度、难度、复习 / 遗忘次数）——同一张规范卡在一侧有几行
///   就有几条，两侧的多重集合要相同；
/// - `canonicalLogs`：每张规范卡（含不在缓存里的历史血统卡）名下的规范日志 ID 集合（日志表全集，未去重前的口径）；
/// - `canonicalStats`：每张规范卡的有效复习（统计行）条数。
fn canonical_pairs(
    src: &Connection,
    profile: &str,
    t: &Truth<'_>,
    col: i64,
    canon: &Canon,
    skip: &Skip,
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
            let state: Vec<&str> = state_cols.iter().map(|c| r[card_at(c)].as_str()).collect();
            *n.entry(format!("{} | {}", canon.text(&r[0]), state.join(" | ")))
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
            if skip.cards.contains(&card.text()) {
                continue;
            }
            by.entry(canon.of(&card))
                .or_default()
                .insert(canon.of(&log));
        }
        by.into_iter().map(|(c, logs)| (c, logs.len())).collect()
    };
    let old_stats: Vec<(Ref, Ref)> = old
        .2
        .iter()
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
    canon: &Canon,
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

// ---------------------------------------------------------------- app 里的预演（G4b）

/// 预演报告在工作目录里的文件名（只在本机；诊断包导出的就是它）。
pub const REPORT_FILE: &str = "report.json";

/// 在跑的预演：库文件路径 → 它的中断开关。同一个库同时只跑一个；关库（`SrsCore::close`）先停掉它并等它放开连接。
static REHEARSALS: Mutex<BTreeMap<PathBuf, std::sync::Arc<Stop>>> = Mutex::new(BTreeMap::new());
static REHEARSAL_DONE: std::sync::Condvar = std::sync::Condvar::new();

fn rehearsals() -> std::sync::MutexGuard<'static, BTreeMap<PathBuf, std::sync::Arc<Stop>>> {
    REHEARSALS.lock().unwrap_or_else(|e| e.into_inner())
}

/// 预演的默认工作目录：库文件旁边的 `gen4-rehearsal/`（临时新库与报告都在这里，和库在同一块盘上）。
pub fn rehearsal_dir(db: &Path) -> PathBuf {
    db.parent()
        .unwrap_or_else(|| Path::new("."))
        .join("gen4-rehearsal")
}

/// 换代前版本里的预演（设计 §8 G4b、§9 第 8 项）：对 [db]（app 正在用的 srs.db）跑一遍 [run]，只读、可中断；报告原子地
/// 写进 `<work>/report.json`（覆盖上一次）并返回。请求：`work`（工作目录，缺省 [rehearsal_dir]）、`caches`（profile →
/// 缓存配置对象，与 app 交给旧内核的同一份）、`appVersion`（原样记进报告，app 据此判断这个版本跑过没有）。同一个库已有
/// 一个在跑就报错。
pub fn rehearse(db: &Path, req: &Value) -> Result<Value, String> {
    let work = req
        .get("work")
        .and_then(Value::as_str)
        .map_or_else(|| rehearsal_dir(db), PathBuf::from);
    let caches: BTreeMap<String, String> = req
        .get("caches")
        .and_then(Value::as_object)
        .map(|m| m.iter().map(|(k, v)| (k.clone(), v.to_string())).collect())
        .unwrap_or_default();
    let stop = std::sync::Arc::new(Stop::new());
    {
        let mut running = rehearsals();
        if running.contains_key(db) {
            return Err("gen4 rehearsal: already running".to_owned());
        }
        running.insert(db.to_path_buf(), stop.clone());
    }
    let out = run(
        db,
        &work,
        Options {
            caches: &caches,
            batch: 20_000,
            keep: false,
            examples: DEFAULT_EXAMPLES,
            full_examples: false,
            stop: &stop,
            progress: &mut |_, _| {},
        },
    );
    {
        let mut running = rehearsals();
        running.remove(db);
        REHEARSAL_DONE.notify_all();
    }
    let mut report = out?;
    if let Some(m) = report.as_object_mut() {
        m.insert("finishedAtMs".into(), json!(now_ms()));
        if let Some(v) = req.get("appVersion") {
            m.insert("appVersion".into(), v.clone());
        }
    }
    let text = serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?;
    let tmp = work.join(format!("{REPORT_FILE}.tmp"));
    std::fs::write(&tmp, text).map_err(|e| format!("gen4 rehearsal: write report: {e}"))?;
    std::fs::rename(&tmp, work.join(REPORT_FILE))
        .map_err(|e| format!("gen4 rehearsal: write report: {e}"))?;
    Ok(report)
}

/// 上一次预演的报告（[rehearsal_dir] 里的 `report.json`）；没有就是 null。读坏了的文件当没有。
pub fn rehearsal_report(db: &Path) -> Value {
    std::fs::read_to_string(rehearsal_dir(db).join(REPORT_FILE))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null)
}

/// 请 [db] 上在跑的预演停下（不等）。没有在跑的就什么都不做。
pub fn cancel_rehearsal(db: &Path) {
    if let Some(stop) = rehearsals().get(db) {
        stop.stop();
    }
}

/// 停下 [db] 上在跑的预演并等它放开对库的连接（关库前调：之后库文件可以被换掉 / 删掉）。语句被当场打断；纯内存的
/// 阶段（别名判定等）做完这一段才查到开关，等的就是这一段。
pub fn stop_rehearsal(db: &Path) {
    let mut running = rehearsals();
    if let Some(stop) = running.get(db) {
        stop.stop();
    }
    while running.contains_key(db) {
        running = REHEARSAL_DONE
            .wait(running)
            .unwrap_or_else(|e| e.into_inner());
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::*;
    use crate::store::sync2::tests::{DAY, Device, P, deck_entity, edit, review};

    const T0: i64 = 1_700_000_000_000;
    const N1: &str = "0193a1b2-0000-7000-8000-0000000000b1";
    const N2: &str = "0193a1b2-0000-7000-8000-0000000000b2";

    fn note(id: &str, nt: &str) -> Value {
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": nt}}})
    }

    fn note_type(id: &str) -> Value {
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}})
    }

    fn cfg() -> String {
        json!({"defaultDeck": default_deck_id(P)}).to_string()
    }

    /// 协议 3 上的一个小库：一个笔记类型两条模板、两条笔记、几次复习，缓存表按同一份配置建好。
    fn library(tag: &str) -> Device {
        let d = Device::new(tag);
        d.core.sync2_identity(P, T0).unwrap();
        d.core.sync2_migrate(P, T0, None).unwrap();
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
        let r = dry(&d, &Stop::new(), &mut |s, _| stages.push(s.to_owned()));
        assert_eq!(r["verdict"], "pass", "{r:#}");
        let p = &r["profiles"][0];
        assert_eq!(p["verdict"], "pass");
        assert_eq!(p["parity"], json!([]));
        assert_eq!(p["canonical"], json!([]));
        assert_eq!(p["existingCachesVsRebuilt"], json!([]));
        assert_eq!(
            p["oldSidePending"],
            json!({"replayCards": 0, "staleTagNotes": 0})
        );
        assert_eq!(p["closures"]["different"], 0);
        assert_eq!(p["imported"]["devices"], 1);
        assert!(p["settled"]["cacheCards"].as_u64().unwrap() >= 4);
        assert_eq!(bytes(&old), before);
        assert_eq!(bytes(&wal), wal_before);
        assert!(!d._dir.0.join("work").join(WORK_FILE).exists());
        assert_eq!(
            stages,
            [
                "open",
                "preflight",
                "import",
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
        let (notes, cards, stats) = old_caches(&c, P, &cfg()).unwrap();
        assert_eq!((notes.len(), cards.len(), stats.len()), (2, 4, 2));
        assert_eq!(count(&c), n);
        let temps: i64 = c
            .query_row("SELECT COUNT(*) FROM temp.sqlite_schema", [], |r| r.get(0))
            .unwrap();
        assert_eq!(temps, 0);
        assert!(c.execute("DELETE FROM main.srs_cards_cache", []).is_err());
    }

    /// app 里的预演走内核命令（`gen4_rehearse`）：对内核自己打开的那个库跑，报告写进工作目录的 `report.json`；
    /// 关库（`SrsCore::close`）先停下在跑的预演、等它放开连接；停下之后不留登记。
    #[test]
    fn the_kernel_command_rehearses_its_own_library_and_close_stops_it() {
        let d = library("g4rehearse");
        let cfg_obj: Value = serde_json::from_str(&cfg()).unwrap();
        let dispatch = |req: &Value| {
            crate::store::ffi::sync2_dispatch(&d.core, req, &mut Vec::new(), &mut Vec::new())
                .unwrap()
        };
        let none = dispatch(&json!({"op": "gen4_rehearsal_report"}));
        assert_eq!(none, json!({"report": null}));
        // 不给工作目录：用库旁边的 gen4-rehearsal/；appVersion 原样记进报告，报告命令读得回来。
        let r = dispatch(
            &json!({"op": "gen4_rehearse", "caches": {P: cfg_obj.clone()}, "appVersion": "1.2.3+4"}),
        );
        assert_eq!(r["verdict"], "pass", "{r:#}");
        let default_dir = d._dir.0.join("gen4-rehearsal");
        assert!(!default_dir.join(WORK_FILE).exists());
        let saved = dispatch(&json!({"op": "gen4_rehearsal_report"}))["report"].clone();
        assert_eq!(saved["verdict"], "pass");
        assert_eq!(saved["appVersion"], "1.2.3+4");
        assert!(saved["finishedAtMs"].as_i64().is_some());

        let work = d._dir.0.join("rehearsal");
        let req = json!({"op": "gen4_rehearse", "work": work.display().to_string(), "caches": {P: cfg_obj}});
        let r = dispatch(&req);
        assert_eq!(r["verdict"], "pass", "{r:#}");
        let saved: Value =
            serde_json::from_str(&std::fs::read_to_string(work.join(REPORT_FILE)).unwrap())
                .unwrap();
        assert_eq!(saved["verdict"], "pass");
        assert!(!work.join(WORK_FILE).exists());
        dispatch(&json!({"op": "gen4_rehearse_cancel"}));

        // 关库时正在跑：停下、等它放开。
        let path = d._dir.0.join("srs.db");
        let runner = {
            let (path, req) = (path.clone(), req.clone());
            std::thread::spawn(move || rehearse(&path, &req))
        };
        while !rehearsals().contains_key(&path) && !runner.is_finished() {
            std::thread::yield_now();
        }
        d.core.close();
        assert!(!rehearsals().contains_key(&path));
        let r = runner.join().unwrap().unwrap();
        assert!(
            r["verdict"] == "cancelled" || r["verdict"] == "pass",
            "{r:#}"
        );
        assert!(!work.join(WORK_FILE).exists());
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
            let mut ours: HashMap<[u8; 16], i64> = HashMap::new();
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
}
