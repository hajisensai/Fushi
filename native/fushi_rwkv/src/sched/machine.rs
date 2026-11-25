// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! RWKV 排程的编排状态机：维护「整个 collection 的复习历史回放进 RWKV」这份状态，并给候选复习卡打分。
//!
//! 对齐日志的四级（结果始终与全量回放逐位相同），按代价从低到高：
//! 1. **追加**（[`Kernel::append_new`]）：新评分都严格晚于已回放的最后一条、各是其卡末尾的保留评分 → 按顺序
//!    追加，每条记一条撤销日志；撤销最近的作答按撤销日志原样撤回。
//! 2. **退回重放**（[`Kernel::rebase`]）：其余变化由取数侧在同一个快照里算出分歧时刻，按撤销日志退到它之前，
//!    再按时间顺序追加从这里起的全部行。
//! 3. **从检查点重来**（[`Kernel::rebase_from_checkpoint`]）：撤销日志够不着时，从磁盘上较早的状态快照恢复，
//!    只回放它之后的行。
//! 4. **全量重建**（[`Kernel::rebuild_all`]）：第一次准备、删过日志、检查点也够不着、宿主要求重建。
//!
//! 3、4 期间「准备中」。没就绪时打分入口一律返回「没有」（宿主这一次不出 RWKV 牌组的复习卡），**没有任何
//! 退回别的算法的路径**——app 与无头服务端共用这一份。
//!
//! 逐流程对应搬迁前的 Dart 实现（`packages/fushi_engine/lib/srs/srs_rwkv_service.dart`），行为由
//! `packages/fushi_engine/test/srs/fixtures/srs_rwkv_orchestration.json` 逐值对拍。

use std::cell::{RefCell, RefMut};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Instant;

use super::exec::{Flag, Lock};
use super::files::{self, Checkpoint, Layout, MetaObject, Print};
use super::host::{
    Backend, Fault, Host, LOG_REVIEW, LOG_UNDO, R, Replay, RowsView, ScoreInputs, TailLog,
};
use super::wire::{Writer, le_i64};

/// `rewind_from` 的 floor：状态是空的（reset 之后）。
const FLOOR_EMPTY: i64 = i64::MIN;
/// `rewind_from` 的 floor：不知道（刚建的 runtime）。
const FLOOR_UNKNOWN: i64 = i64::MAX;
/// 整块回放时一块多少行（原生侧成批并行）。
const REPLAY_BLOCK: usize = 65536;
const ROW: usize = 80;
const WEEK_MS: i64 = 7 * 24 * 60 * 60 * 1000;

pub struct Cfg {
    pub profile: String,
    pub dir: PathBuf,
    /// 原生线程数：0 = 全部核心。
    pub threads: usize,
    /// 整块回放时最后这么多条 append 进撤销日志，其余整块 replay。
    pub journal_seed: usize,
    /// 距上次整表重查满这么久，下一次排队前整表重查。
    pub requery_after_ms: i64,
    /// runtime 调用转给宿主（测试用的替身后端）。
    pub host_backend: bool,
    /// 有未存的追加 / 撤回时，空闲这么久后存一次快照。
    pub snapshot_idle_ms: i64,
    /// 失败后的自动重试最多每这么久一次。
    pub retry_after_ms: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Phase {
    Idle = 0,
    Downloading = 1,
    Preparing = 2,
    Ready = 3,
    Failed = 4,
}

pub enum Command {
    Start { force: bool },
    Rebuild,
    Refresh,
    Instant { cards: u32, at_ms: i64 },
    Current { cards: u32, now_ms: i64 },
    Answered,
    Purged { ids: Vec<i64> },
    Close,
}

struct St {
    backend: Option<Rc<Backend>>,
    next_backend: u32,
    replayed: Option<Print>,
    /// 上次全量计数核对过 `replayed` 时的内容修订号：没变时日志只可能新增，行数按新增的行累加。
    counted_at: Option<String>,
    /// 已回放的评分里最晚的时刻（追加只接受严格晚于它的）。
    last_at: Option<i64>,
    appends_since_snapshot: i64,
    /// 状态里不经撤销日志进来的行最晚的时刻（`rewind_from` 的 floor）。
    journal_floor: i64,
    /// 空闲存快照的定时器：代号与到点时要存的后端。
    timer: Option<(u32, Rc<Backend>)>,
    timer_generation: u32,
    scores_clear_key: Option<String>,
    scores_requery_key: Option<String>,
    scores_today: Option<i64>,
    scores_at: i64,
    /// 上次整表重查以来模型状态推进的次数。
    state_changes: i64,
    requery_pending: bool,
    /// 宿主的修订号上次核对时的值（状态与日志表一致时记下）。
    checked_revision: Option<String>,
    preparing: Option<Flag>,
    closed: bool,
    status_closed: bool,
    phase: Phase,
    failed_at: Option<Instant>,
    align_after_ingest_pending: bool,
}

pub struct Kernel {
    cfg: Cfg,
    layout: Layout,
    pub host: Rc<Host>,
    st: RefCell<St>,
    /// runtime 不能交错使用：回放 / 查询 / 快照串行。
    queue: Lock,
    /// 对齐串行：作答与预览可能同时触发，同一条日志只能追加一次。
    refresh_queue: Lock,
}

fn same(a: &Rc<Backend>, b: Option<&Rc<Backend>>) -> bool {
    b.is_some_and(|b| Rc::ptr_eq(a, b))
}

impl Kernel {
    pub fn new(cfg: Cfg, host: Rc<Host>) -> Rc<Self> {
        let layout = Layout::new(cfg.dir.clone(), cfg.profile.clone());
        let exec = host.exec.clone();
        Rc::new(Self {
            cfg,
            layout,
            host,
            st: RefCell::new(St {
                backend: None,
                next_backend: 1,
                replayed: None,
                counted_at: None,
                last_at: None,
                appends_since_snapshot: 0,
                journal_floor: FLOOR_UNKNOWN,
                timer: None,
                timer_generation: 0,
                scores_clear_key: None,
                scores_requery_key: None,
                scores_today: None,
                scores_at: 0,
                state_changes: 0,
                requery_pending: false,
                checked_revision: None,
                preparing: None,
                closed: false,
                status_closed: false,
                phase: Phase::Idle,
                failed_at: None,
                align_after_ingest_pending: false,
            }),
            queue: Lock::new(exec.clone()),
            refresh_queue: Lock::new(exec),
        })
    }

    fn s(&self) -> RefMut<'_, St> {
        self.st.borrow_mut()
    }

    fn phase(&self) -> Phase {
        self.st.borrow().phase
    }

    fn closed(&self) -> bool {
        self.st.borrow().closed
    }

    fn log(&self, message: String) {
        self.host.log(&message);
    }

    // ------------------------------------------------------------------ 命令入口

    pub fn command(self: &Rc<Self>, op: u32, command: Command) {
        let k = self.clone();
        self.host.exec.spawn(async move {
            match command {
                Command::Start { force } => {
                    let result = k.start(force).await;
                    k.host.done(op, result, |_| {});
                }
                Command::Rebuild => {
                    let result = k.rebuild().await;
                    k.host.done(op, result, |_| {});
                }
                Command::Refresh => match k.refresh().await {
                    Ok(aligned) => k.host.done(op, Ok(()), |w| {
                        w.bool(aligned);
                    }),
                    Err(error) => k.host.done(op, Err(error), |_| {}),
                },
                Command::Instant { cards, at_ms } => {
                    let scores = k.instant(op, cards, at_ms).await;
                    k.host
                        .done(op, Ok(()), |w| write_scores(w, scores.as_deref()));
                }
                Command::Current { cards, now_ms } => {
                    let scores = k.current(op, cards, now_ms).await;
                    k.host
                        .done(op, Ok(()), |w| write_scores(w, scores.as_deref()));
                }
                Command::Answered => {
                    let result = k.answered().await;
                    k.host.done(op, result, |_| {});
                }
                Command::Purged { ids } => {
                    k.purged(&ids).await;
                    k.host.done(op, Ok(()), |_| {});
                }
                Command::Close => {
                    let result = k.close().await;
                    k.host.done(op, result, |_| {});
                }
            }
        });
    }

    /// 空闲存快照的定时器到点了。
    pub fn timer_fired(self: &Rc<Self>, generation: u32) {
        let backend = {
            let mut st = self.s();
            match st.timer.take() {
                Some((current, backend)) if current == generation => backend,
                other => {
                    st.timer = other;
                    return;
                }
            }
        };
        {
            let st = self.st.borrow();
            if st.closed || st.appends_since_snapshot == 0 || st.phase != Phase::Ready {
                return;
            }
        }
        let k = self.clone();
        self.host.exec.spawn(async move {
            let saved = {
                let _serial = k.queue.lock().await;
                k.save_snapshot(&backend).await
            };
            if let Err(error) = saved {
                k.log(format!("RWKV snapshot save failed: {error}"));
            }
        });
    }

    // ------------------------------------------------------------------ 状态

    fn set(&self, phase: Phase, done: i64, total: i64, error: Option<&Fault>) {
        let (changed, open) = {
            let mut st = self.s();
            let changed = st.phase != phase;
            st.phase = phase;
            (changed, !st.status_closed)
        };
        if open {
            self.host.status(phase as u8, changed, done, total, error);
        }
    }

    fn set_phase(&self, phase: Phase) {
        self.set(phase, 0, 0, None);
    }

    fn fail(&self, error: &Fault) {
        self.s().failed_at = Some(Instant::now());
        self.set(Phase::Failed, 0, 0, Some(error));
    }

    /// 状态整体换过（reset / restore）：原生分数表已清空，按此刻重来。
    fn forget_scores(&self) {
        let mut st = self.s();
        st.checked_revision = None;
        st.scores_clear_key = None;
        st.scores_requery_key = None;
        st.scores_today = None;
        st.state_changes = 0;
    }

    fn cancel_timer(&self) {
        if let Some((generation, _)) = self.s().timer.take() {
            self.host.timer(generation, -1);
        }
    }

    /// 有未存的追加 / 撤回：空闲一阵后存快照（期间再有作答就顺延）。
    fn schedule_snapshot(&self, backend: &Rc<Backend>) {
        let generation = {
            let mut st = self.s();
            st.timer_generation = st.timer_generation.wrapping_add(1);
            st.timer = Some((st.timer_generation, backend.clone()));
            st.timer_generation
        };
        self.host.timer(generation, self.cfg.snapshot_idle_ms);
    }

    /// 让 `body` 成为「正在准备」的那一个任务（同时只跑一个），返回等它跑完用的标记。
    fn share_preparing(
        self: &Rc<Self>,
        body: impl std::future::Future<Output = ()> + 'static,
    ) -> Flag {
        let flag = Flag::new();
        self.s().preparing = Some(flag.clone());
        let (k, done) = (self.clone(), flag.clone());
        self.host.exec.spawn(async move {
            body.await;
            k.s().preparing = None;
            done.set(&k.host.exec);
        });
        flag
    }

    // ------------------------------------------------------------------ 准备

    /// 开始准备：权重没下载时先下载，再恢复快照或全量回放。已在准备时等它，已就绪时只对齐日志。失败后的
    /// 自动重试最多每 `retry_after_ms` 一次；`force`（宿主的「重试」）不受此限。
    async fn start(self: &Rc<Self>, force: bool) -> R<()> {
        if self.closed() {
            return Ok(());
        }
        if self.phase() == Phase::Ready {
            self.refresh().await?;
            return Ok(());
        }
        let running = {
            let st = self.st.borrow();
            if !force
                && st.preparing.is_none()
                && st
                    .failed_at
                    .is_some_and(|at| (at.elapsed().as_millis() as i64) < self.cfg.retry_after_ms)
            {
                return Ok(());
            }
            st.preparing.clone()
        };
        let flag = running.unwrap_or_else(|| {
            let k = self.clone();
            self.share_preparing(async move { k.prepare().await })
        });
        flag.wait().await;
        Ok(())
    }

    /// 按全部复习历史重新回放，期间「准备中」。还没准备好时等同 `start(force)`。
    async fn rebuild(self: &Rc<Self>) -> R<()> {
        if self.closed() {
            return Ok(());
        }
        let ready = {
            let st = self.st.borrow();
            st.backend.is_some() && st.phase == Phase::Ready
        };
        if !ready {
            return self.start(true).await;
        }
        if let Some(flag) = self.recover(None) {
            flag.wait().await;
        }
        Ok(())
    }

    async fn delete_retired(&self) -> R<()> {
        for path in self.layout.retired() {
            files::remove_if_exists(&path)?;
        }
        self.host.delete_retired().await
    }

    async fn prepare(self: &Rc<Self>) {
        if let Err(error) = self.delete_retired().await {
            self.log(format!("RWKV retired model cleanup failed: {error}"));
        }
        let (ready, weights) = match self.host.model_ready().await {
            Ok(model) => model,
            Err(error) => {
                self.log(format!("RWKV prepare failed: {error}"));
                self.fail(&error);
                return;
            }
        };
        if !ready {
            self.set_phase(Phase::Downloading);
            let download = self.host.download();
            loop {
                match self.host.download_event(download).await {
                    Ok(Some((done, total))) => {
                        if self.closed() {
                            self.host.cancel(download);
                            return;
                        }
                        self.set(Phase::Downloading, done, total, None);
                    }
                    Ok(None) => break,
                    Err(error) => {
                        self.log(format!("RWKV model download failed: {error}"));
                        self.fail(&error);
                        return;
                    }
                }
            }
            if self.closed() {
                return;
            }
        }
        self.set_phase(Phase::Preparing);
        let prepared: R<()> = async {
            let existing = self.st.borrow().backend.clone();
            let backend = match existing {
                Some(backend) => backend,
                None => {
                    let id = {
                        let mut st = self.s();
                        st.next_backend += 1;
                        st.next_backend - 1
                    };
                    let backend = Backend::open(
                        &self.host,
                        id,
                        self.cfg.host_backend,
                        &weights,
                        self.cfg.threads,
                    )
                    .await?;
                    self.s().backend = Some(backend.clone());
                    backend
                }
            };
            let restored = {
                let _serial = self.queue.lock().await;
                self.restore_snapshot(&backend).await
            };
            if !restored {
                self.rebuild_all(&backend).await?;
            }
            Ok(())
        }
        .await;
        match prepared {
            Ok(()) => self.set_phase(Phase::Ready),
            Err(error) => {
                self.log(format!("RWKV prepare failed: {error}"));
                self.fail(&error);
            }
        }
    }

    // ------------------------------------------------------------------ 日志指纹

    /// 日志表指纹。`replayed` 已知、且上次全量计数之后内容修订号没变（没删过日志）时只数新行，否则整表计数。
    async fn fingerprint(&self) -> R<Print> {
        let (base, counted) = {
            let st = self.st.borrow();
            (st.replayed, st.counted_at.clone())
        };
        let tail = self
            .host
            .tail(
                base.map_or(0, |b| b.max_row_id),
                0,
                false,
                base.and(counted.as_deref()),
            )
            .await?;
        if let (true, Some(base)) = (tail.incremental, base) {
            return Ok(Print {
                count: base.count + tail.count,
                max_row_id: if tail.count == 0 {
                    base.max_row_id
                } else {
                    tail.max_row_id
                },
            });
        }
        // 没有 `replayed` 时这次计数就是全量回放的基数；有时不知道它与 `replayed` 是否一致，不记。
        if base.is_none() {
            self.s().counted_at = Some(tail.content);
        }
        Ok(Print {
            count: tail.count,
            max_row_id: tail.max_row_id,
        })
    }

    /// 指纹连同 rowid 在 `after` 之后的行数（`with_rows` 时连同这些行），同一个快照里取出。
    async fn tail_after(&self, after: i64, with_rows: bool) -> R<(Print, i64, Vec<TailLog>)> {
        let (base, counted) = {
            let st = self.st.borrow();
            (
                st.replayed.filter(|b| b.max_row_id == after),
                st.counted_at.clone(),
            )
        };
        let tail = self
            .host
            .tail(after, after, with_rows, base.and(counted.as_deref()))
            .await?;
        if let (true, Some(base)) = (tail.incremental, base) {
            return Ok((
                Print {
                    count: base.count + tail.count,
                    max_row_id: if tail.count == 0 {
                        base.max_row_id
                    } else {
                        tail.max_row_id
                    },
                },
                tail.new_rows,
                tail.logs,
            ));
        }
        if base.is_some_and(|b| tail.count - tail.new_rows == b.count) {
            self.s().counted_at = Some(tail.content);
        }
        Ok((
            Print {
                count: tail.count,
                max_row_id: tail.max_row_id,
            },
            tail.new_rows,
            tail.logs,
        ))
    }

    // ------------------------------------------------------------------ 快照与检查点

    async fn restore_snapshot(&self, backend: &Rc<Backend>) -> bool {
        let (snap, meta) = (self.layout.snapshot(), self.layout.meta());
        if !snap.exists() || !meta.exists() {
            return false;
        }
        let restored: R<bool> = async {
            let object = MetaObject::read(&meta).map_err(Fault::new)?;
            if !object.is_v1() {
                return Ok(false);
            }
            backend.restore_from_file(&self.host, &snap).await?;
            let print = Print {
                count: object.int("count").map_err(Fault::new)?,
                max_row_id: object.int("maxRowId").map_err(Fault::new)?,
            };
            self.s().replayed = Some(print);
            let last_at = object.opt_int("lastAt").map_err(Fault::new)?;
            let mut st = self.s();
            st.last_at = last_at;
            st.journal_floor = last_at.unwrap_or(FLOOR_EMPTY);
            Ok(true)
        }
        .await;
        match restored {
            Ok(restored) => restored,
            Err(error) => {
                // 快照坏了或属于别的模型 / 精度：丢掉，全量重建。
                self.log(format!("RWKV snapshot ignored: {error}"));
                false
            }
        }
    }

    async fn save_snapshot(&self, backend: &Rc<Backend>) -> R<()> {
        let Some(replayed) = self.st.borrow().replayed else {
            return Ok(());
        };
        fs::create_dir_all(&self.layout.dir)?;
        // 先把新快照完整写进 .tmp，成功了才动磁盘上的旧主快照（留作检查点 / 被替换）。
        let tmp = self.layout.tmp();
        backend.snapshot_to_file(&self.host, &tmp).await?;
        self.keep_checkpoint().await?;
        fs::rename(&tmp, self.layout.snapshot())?;
        let last_at = self.st.borrow().last_at;
        files::write_meta(&self.layout.meta(), replayed, last_at)?;
        self.s().appends_since_snapshot = 0;
        self.cancel_timer();
        Ok(())
    }

    fn read_checkpoint(&self, snap: &std::path::Path) -> Option<Checkpoint> {
        match files::read_checkpoint(snap, &files::meta_of(snap)) {
            Ok(checkpoint) => checkpoint,
            Err(error) => {
                self.log(format!("RWKV checkpoint ignored: {error}"));
                None
            }
        }
    }

    /// 换日后第一次存快照时，把磁盘上前一天的主快照留作检查点（改名，不重写），再修剪。
    async fn keep_checkpoint(&self) -> R<()> {
        let previous = self.read_checkpoint(&self.layout.snapshot());
        let now = self.st.borrow().last_at;
        let (Some(previous), Some(now)) = (previous, now) else {
            return Ok(());
        };
        let Some(last) = previous.last_at else {
            return Ok(());
        };
        let (last_day, now_day) = self.host.day_index(last, now).await?;
        if last_day >= now_day {
            return Ok(());
        }
        let snap = self.layout.checkpoint(last);
        fs::rename(&previous.snap, &snap)?;
        fs::rename(&previous.meta, files::meta_of(&snap))?;
        self.prune_checkpoints(now)
    }

    /// 检查点只留两份：最新的一份，与最年轻的一份「比最新评分早一周以上」的（没有这么老的就留最老的一份）。
    fn prune_checkpoints(&self, newest_at: i64) -> R<()> {
        let all = self.checkpoints()?;
        if all.len() <= 2 {
            return Ok(());
        }
        let week_ago = newest_at - WEEK_MS;
        let old = all
            .iter()
            .position(|c| c.last_at.is_some_and(|at| at <= week_ago))
            .unwrap_or(all.len() - 1);
        for (index, checkpoint) in all.iter().enumerate() {
            if index != 0 && index != old {
                delete_checkpoint(checkpoint)?;
            }
        }
        Ok(())
    }

    /// 本 profile 的检查点，评分时刻新的在前（读不了的丢掉）。
    fn checkpoints(&self) -> R<Vec<Checkpoint>> {
        let mut out = Vec::new();
        for snap in self.layout.checkpoint_files()? {
            match self.read_checkpoint(&snap) {
                Some(checkpoint) if checkpoint.last_at.is_some() => out.push(checkpoint),
                _ => fs::remove_file(&snap)?,
            }
        }
        out.sort_by_key(|checkpoint| std::cmp::Reverse(checkpoint.last_at));
        Ok(out)
    }

    // ------------------------------------------------------------------ 回放

    /// 全量重建：在正在用的 runtime 上 reset 后回放全部历史，期间「准备中」。
    async fn rebuild_all(&self, backend: &Rc<Backend>) -> R<()> {
        let fingerprint = self.fingerprint().await?;
        self.host.rebuild_hook().await?;
        let replay = self.host.replay(fingerprint.max_row_id, None, None).await?;
        let _serial = self.queue.lock().await;
        backend.reset(&self.host).await?;
        self.s().journal_floor = FLOOR_EMPTY;
        self.replay_then_append(backend, replay.view(), true)
            .await?;
        {
            let mut st = self.s();
            st.replayed = Some(print_of(&replay));
            st.last_at = replay.last_at;
        }
        self.forget_scores();
        self.save_snapshot(backend).await
    }

    /// 按时间顺序把 `view` 的行接到后端当前状态之后（调用方已拿着串行锁）：前面的按块 replay（不进撤销日志，
    /// 且清空已有撤销日志），最后 `journal_seed` 条 append 进撤销日志；整块 replay 过的行把 floor 推到它们的
    /// 最后一条。`progress`：把进度报成「准备中」。
    async fn replay_then_append(
        &self,
        backend: &Rc<Backend>,
        view: RowsView<'_>,
        progress: bool,
    ) -> R<()> {
        let total = view.len();
        let split = total.saturating_sub(self.cfg.journal_seed);
        let report = |done: usize| {
            if progress {
                self.set(Phase::Preparing, done as i64, total as i64, None);
            }
        };
        report(0);
        let mut start = 0;
        while start < split {
            let end = (start + REPLAY_BLOCK).min(split);
            backend
                .replay(&self.host, &view.rows[start * ROW..end * ROW])
                .await?;
            report(end);
            start = end;
        }
        if split > 0 {
            self.s().journal_floor = view.at(split - 1);
        }
        if split < total {
            let tail = RowsView {
                rows: &view.rows[split * ROW..],
                ats: &view.ats[split * 8..],
                tags: &view.tags[split * 8..],
            };
            if !backend.append(&self.host, tail).await? {
                // 模型不支持撤销日志（行已按普通回放进去）：floor 推到这些行。
                let last = view.at(total - 1);
                let mut st = self.s();
                st.journal_floor = st.journal_floor.max(last);
            }
            report(total);
        }
        Ok(())
    }

    /// 第 2 级。true = 已对齐（或已转去第 3 级，那时不在「就绪」）；false = 删过日志，只能全量重建。
    async fn rebase(self: &Rc<Self>, backend: &Rc<Backend>, done: Print) -> R<bool> {
        let replay = self
            .host
            .replay(done.max_row_id, Some(done.max_row_id), None)
            .await?;
        // 同一个快照里：rowid 不超过已回放位置的行数没变 = 没删过日志。
        if replay.count - replay.tail_rows != done.count {
            return Ok(false);
        }
        let now = print_of(&replay);
        let diverge = replay.diverge_at;
        let reached = {
            let _serial = self.queue.lock().await;
            match diverge {
                // 新日志不改变任何回放行（例如暂停、改标签）。
                None => {
                    self.s().replayed = Some(now);
                    true
                }
                Some(diverge) => {
                    let (last_at, floor) = {
                        let st = self.st.borrow();
                        (st.last_at, st.journal_floor)
                    };
                    let rewound = if last_at.is_some_and(|last| diverge <= last) {
                        backend.rewind_from(&self.host, diverge, floor).await?
                    } else {
                        Some(0)
                    };
                    match rewound {
                        None => false,
                        Some(rewound) => {
                            if replay.rows > 0 {
                                self.replay_then_append(backend, replay.view(), false)
                                    .await?;
                            }
                            let moved = rewound + replay.rows as i64;
                            {
                                let mut st = self.s();
                                st.replayed = Some(now);
                                st.last_at = replay.last_at;
                                st.state_changes += moved;
                                st.appends_since_snapshot += moved;
                            }
                            self.schedule_snapshot(backend);
                            true
                        }
                    }
                }
            }
        };
        if !reached {
            let _ = self.recover(diverge);
        }
        Ok(true)
    }

    /// 第 3、4 级：「准备中」，先找评分时刻早于 `diverge` 的检查点恢复、回放它之后的行，不行就全量重建
    /// （`diverge` 为 None = 直接全量）。同时只跑一个（与 [`Kernel::start`] 共用）；失败 → 「出错」。
    fn recover(self: &Rc<Self>, diverge: Option<i64>) -> Option<Flag> {
        {
            let st = self.st.borrow();
            if st.closed {
                return None;
            }
            if let Some(running) = &st.preparing {
                return Some(running.clone());
            }
        }
        self.set_phase(Phase::Preparing);
        let k = self.clone();
        Some(self.share_preparing(async move {
            let recovered: R<()> = async {
                let backend =
                    k.st.borrow()
                        .backend
                        .clone()
                        .ok_or_else(|| Fault::new("RWKV backend is gone"))?;
                let from_checkpoint = match diverge {
                    Some(diverge) => k.rebase_from_checkpoint(&backend, diverge).await?,
                    None => false,
                };
                if !from_checkpoint {
                    k.rebuild_all(&backend).await?;
                }
                Ok(())
            }
            .await;
            match recovered {
                Ok(()) => {
                    if !k.closed() {
                        k.set_phase(Phase::Ready);
                    }
                }
                Err(error) => {
                    k.log(format!("RWKV recovery failed: {error}"));
                    k.fail(&error);
                }
            }
        }))
    }

    /// 第 3 级：从评分时刻早于 `diverge` 的检查点（新的先试）恢复，只回放它之后的行。检查点按当前日志当场
    /// 核对，核对不过的删掉。都不行返回 false。
    async fn rebase_from_checkpoint(&self, backend: &Rc<Backend>, diverge: i64) -> R<bool> {
        for checkpoint in self.checkpoints()? {
            let Some(at) = checkpoint.last_at else {
                continue;
            };
            if at >= diverge {
                continue;
            }
            let replay = self
                .host
                .replay(
                    checkpoint.print.max_row_id,
                    Some(checkpoint.print.max_row_id),
                    Some(at + 1),
                )
                .await?;
            if replay.count - replay.tail_rows != checkpoint.print.count
                || replay.diverge_at.is_some_and(|since| since <= at)
            {
                delete_checkpoint(&checkpoint)?;
                continue;
            }
            let restored = {
                let _serial = self.queue.lock().await;
                match backend
                    .restore_from_file(&self.host, &checkpoint.snap)
                    .await
                {
                    Err(error) => {
                        // 检查点坏了：与主快照同一处置——不用它，删掉、试下一份，都不行就全量重建。
                        self.log(format!("RWKV checkpoint ignored: {error}"));
                        false
                    }
                    Ok(()) => {
                        self.s().journal_floor = at;
                        self.replay_then_append(backend, replay.view(), true)
                            .await?;
                        {
                            let mut st = self.s();
                            st.replayed = Some(print_of(&replay));
                            st.last_at = Some(replay.last_at.unwrap_or(at));
                        }
                        self.forget_scores();
                        self.s().appends_since_snapshot += replay.rows as i64;
                        true
                    }
                }
            };
            if !restored {
                delete_checkpoint(&checkpoint)?;
                continue;
            }
            self.schedule_snapshot(backend);
            return Ok(true);
        }
        Ok(false)
    }

    // ------------------------------------------------------------------ 对齐

    /// 对齐日志（四级）。false = RWKV 现在没有可用状态（未就绪 / 已关闭 / 刚转去检查点或全量重建）。
    async fn refresh(self: &Rc<Self>) -> R<bool> {
        let _turn = self.refresh_queue.lock().await;
        self.refresh_once().await
    }

    async fn refresh_once(self: &Rc<Self>) -> R<bool> {
        {
            let st = self.st.borrow();
            if st.closed
                || st.backend.is_none()
                || st.replayed.is_none()
                || st.phase != Phase::Ready
            {
                return Ok(false);
            }
        }
        // 先比宿主的内存修订号（零成本）：没变就不必扫日志表（每张卡出题都会走到这里）。
        let revision = self.host.revision().await?;
        if self.st.borrow().checked_revision.as_deref() == Some(revision.as_str()) {
            return Ok(true);
        }
        // 对齐途中用户可能又答了一题，读到的日志就比指纹新：按新指纹再对一次，而不是当成「历史被改写」
        // 去全量重建。
        for _ in 0..10 {
            let (backend, done) = {
                let st = self.st.borrow();
                match (st.backend.clone(), st.replayed) {
                    (Some(backend), Some(done)) => (backend, done),
                    _ => return Err(Fault::new("RWKV state was dropped during alignment")),
                }
            };
            let (now, new_rows, _) = self.tail_after(done.max_row_id, false).await?;
            if now == done {
                self.s().checked_revision = Some(revision);
                return Ok(true);
            }
            // 没有新行而指纹变了 = 删过日志：改写了历史。
            if now.max_row_id <= done.max_row_id {
                break;
            }
            // 新增行数与行数差对不上（同一快照里取的，所以是删过日志）：重来一次。
            if now.count - done.count != new_rows {
                continue;
            }
            let Some(appended) = self.append_new(&backend, done.max_row_id, now).await? else {
                continue;
            };
            if !appended {
                // 正在收段：退回重放要把整个 profile 的日志扫一遍，与收段叠在一起会撑爆内存。先不对齐，
                // 会话结束后对齐一次。
                if self.host.ingesting().await? {
                    self.align_after_ingest();
                    return Ok(false);
                }
                let rebased = match self.rebase(&backend, done).await {
                    Ok(rebased) => rebased,
                    Err(error) => {
                        // 例如换过日界设置、行的日序对不上已回放的：状态可能退了一半，全量重建会先 reset。
                        self.log(format!("RWKV rebase failed, rebuilding: {error}"));
                        break;
                    }
                };
                if !rebased {
                    break;
                }
                // 撤销日志够不着、转去从检查点重来：这次没有可用状态。
                if self.phase() != Phase::Ready {
                    return Ok(false);
                }
            }
            self.s().checked_revision = Some(revision);
            return Ok(true);
        }
        let _ = self.recover(None);
        Ok(false)
    }

    /// 收段会话结束后对齐一次，对齐成了再报一次「就绪」（会话期间拿到「等 RWKV」的界面按这个事件重新排队）。
    fn align_after_ingest(self: &Rc<Self>) {
        {
            let mut st = self.s();
            if st.align_after_ingest_pending {
                return;
            }
            st.align_after_ingest_pending = true;
        }
        let k = self.clone();
        self.host.exec.spawn(async move {
            let aligned: R<()> = async {
                k.host.ingest_settled().await?;
                k.s().align_after_ingest_pending = false;
                if k.closed() {
                    return Ok(());
                }
                if k.refresh().await? && !k.closed() && k.phase() == Phase::Ready {
                    k.set_phase(Phase::Ready);
                }
                Ok(())
            }
            .await;
            if let Err(error) = aligned {
                k.s().align_after_ingest_pending = false;
                k.log(format!("RWKV align after sync ingest failed: {error}"));
            }
        });
    }

    /// 第 1 级。`Some(true)` = 已追加 / 撤回；`Some(false)` = 不满足追加条件（调用方走退回重放）；
    /// `None` = 读的途中日志表又变了，调用方按新指纹重来。
    async fn append_new(&self, backend: &Rc<Backend>, after: i64, now: Print) -> R<Option<bool>> {
        let (print, _, fetched) = self.tail_after(after, true).await?;
        if print != now {
            return Ok(None);
        }
        if fetched
            .iter()
            .any(|r| r.kind != LOG_REVIEW && (r.kind != LOG_UNDO || r.revokes.is_none()))
        {
            return Ok(Some(false));
        }
        // 两次对齐之间答了又撤回（同一批里评分与撤销它的那条）：相互抵消，两条都不碰状态。
        let revoked_here: HashSet<&str> = fetched
            .iter()
            .filter(|r| r.kind == LOG_UNDO)
            .filter_map(|r| r.revokes.as_deref())
            .collect();
        let cancelled: HashSet<&str> = fetched
            .iter()
            .filter(|r| r.kind == LOG_REVIEW && revoked_here.contains(r.id.as_str()))
            .map(|r| r.id.as_str())
            .collect();
        let rows: Vec<&TailLog> = fetched
            .iter()
            .filter(|r| {
                let cancels = r.kind == LOG_UNDO
                    && r.revokes
                        .as_deref()
                        .is_some_and(|target| cancelled.contains(target));
                !cancelled.contains(r.id.as_str()) && !cancels
            })
            .collect();
        // 只接受严格晚于已回放的最后一条、且彼此按时间先后的评分；同一时刻也不追加（全量回放里同一时刻的行
        // 按卡排序，追加顺序未必是那样）。其余交给退回重放。
        let mut last = self.st.borrow().last_at;
        let mut cards: Vec<(String, Vec<String>)> = Vec::new();
        let mut card_index: HashMap<&str, usize> = HashMap::new();
        for r in rows.iter().filter(|r| r.kind == LOG_REVIEW) {
            if last.is_some_and(|last| r.at <= last) {
                return Ok(Some(false));
            }
            last = Some(r.at);
        }
        // 同一张卡可能来了多条：按卡一次算出它末尾这几条的行，再按全局时间顺序拼。
        for r in rows.iter().filter(|r| r.kind == LOG_REVIEW) {
            let index = *card_index.entry(r.card_id.as_str()).or_insert_with(|| {
                cards.push((r.card_id.clone(), Vec::new()));
                cards.len() - 1
            });
            cards[index].1.push(r.id.clone());
        }
        let tag_ids: Vec<&str> = rows
            .iter()
            .map(|r| r.revokes.as_deref().unwrap_or(r.id.as_str()))
            .collect();
        let fetched_rows = self.host.append_rows(&cards, &tag_ids).await?;
        if fetched_rows.missing_card {
            return Ok(Some(false));
        }
        // 取完再核对：取的途中又写进了日志，取到的行就比 `now` 新，按新指纹重来。
        if self.fingerprint().await? != now {
            return Ok(None);
        }
        let mut row_of: HashMap<&str, &[u8]> = HashMap::new();
        for (k, (_, ids)) in cards.iter().enumerate() {
            let Some(appended) = &fetched_rows.rows[k] else {
                return Ok(Some(false));
            };
            for (id, row) in ids.iter().zip(appended) {
                row_of.insert(id.as_str(), row.as_slice());
            }
        }
        let tags = &fetched_rows.tags;
        if tags.len() != rows.len() {
            return Err(Fault::new("append rows: tag count mismatch"));
        }
        let _serial = self.queue.lock().await;
        // 排队期间后台重建换上了新 runtime：这批行属于新状态的指纹之后，按新状态重来。
        if !same(backend, self.st.borrow().backend.as_ref()) {
            return Ok(None);
        }
        let mut pending = Pending::default();
        for (i, r) in rows.iter().enumerate() {
            if r.kind == LOG_REVIEW {
                let row = row_of
                    .get(r.id.as_str())
                    .ok_or_else(|| Fault::new("append rows: row missing"))?;
                pending.push(row, tags[i], r.at);
                continue;
            }
            self.flush_pending(backend, &mut pending).await?;
            // 撤的不是撤销日志里最近的那条（更早的作答、重启前的作答）：退回重放。
            if !backend.unappend(&self.host, tags[i]).await? {
                return Ok(Some(false));
            }
        }
        self.flush_pending(backend, &mut pending).await?;
        {
            let mut st = self.s();
            st.state_changes += rows.len() as i64;
            st.replayed = Some(now);
            st.appends_since_snapshot += fetched.len() as i64;
        }
        if !fetched.is_empty() {
            self.schedule_snapshot(backend);
        }
        Ok(Some(true))
    }

    /// 把攒着的评分行接进状态（与退回重放同一种拆法：新行可能有几万条，前面的整块 replay）。
    async fn flush_pending(&self, backend: &Rc<Backend>, pending: &mut Pending) -> R<()> {
        if pending.tags.is_empty() {
            return Ok(());
        }
        self.replay_then_append(backend, pending.view(), false)
            .await?;
        // 先记下：后面的撤回失败时，退回重放要从不晚于这些行的时刻退。
        let newest = le_i64(&pending.ats, pending.ats.len() / 8 - 1);
        {
            let mut st = self.s();
            st.last_at = Some(st.last_at.unwrap_or(newest).max(newest));
        }
        *pending = Pending::default();
        Ok(())
    }

    // ------------------------------------------------------------------ 打分

    /// 排队用：`cards` 张候选卡在时刻 `at_ms` 的回忆率（走常驻分数表）。`None` = 没准备好 / 打分失败，
    /// 宿主这一次不出 RWKV 牌组的复习卡。
    async fn instant(self: &Rc<Self>, op: u32, cards: u32, at_ms: i64) -> Option<Vec<f32>> {
        let backend = self.scoring_backend()?;
        let scored: R<Option<Vec<f32>>> = async {
            if !self.refresh().await? {
                return Ok(None);
            }
            if cards == 0 {
                return Ok(Some(Vec::new()));
            }
            let inputs = self.host.score_inputs(op, at_ms).await?;
            let requery_after_this = self.align_scores(&backend, &inputs, at_ms).await?;
            let (mut scores, found) = {
                let _serial = self.queue.lock().await;
                backend
                    .lookup_scores(&self.host, &inputs.ids, &inputs.versions)
                    .await?
            };
            let missing: Vec<u32> = (0..found.len() as u32)
                .filter(|i| !found[*i as usize])
                .collect();
            if !missing.is_empty() {
                // 分数表里没有（或版本变了）的卡：读历史、建查询行，一次原生调用算完并记进表里。
                let (rows, anchors) = self.host.query_rows(op, Some(&missing), at_ms).await?;
                let versions: Vec<u64> = missing
                    .iter()
                    .map(|i| inputs.versions[*i as usize])
                    .collect();
                let fresh = {
                    let _serial = self.queue.lock().await;
                    backend
                        .update_scores(&self.host, &rows, &versions, &anchors)
                        .await?
                };
                if fresh.len() != missing.len() {
                    return Err(Fault::new("score update: result count mismatch"));
                }
                for (k, i) in missing.iter().enumerate() {
                    scores[*i as usize] = fresh[k];
                }
            }
            if requery_after_this {
                self.requery_in_background(&backend, inputs.today, at_ms);
            }
            Ok(Some(scores))
        }
        .await;
        match scored {
            Ok(scores) => scores,
            Err(error) => {
                self.log(format!("RWKV instant retrievability failed: {error}"));
                self.scoring_failed(&backend, &error);
                None
            }
        }
    }

    /// 统计 / 今天答过的卡用：此刻的回忆率，直接查询、不进分数表。
    async fn current(self: &Rc<Self>, op: u32, cards: u32, now_ms: i64) -> Option<Vec<f32>> {
        let backend = self.scoring_backend()?;
        let scored: R<Option<Vec<f32>>> = async {
            if !self.refresh().await? {
                return Ok(None);
            }
            if cards == 0 {
                return Ok(Some(Vec::new()));
            }
            let (rows, _) = self.host.query_rows(op, None, now_ms).await?;
            let _serial = self.queue.lock().await;
            Ok(Some(backend.query(&self.host, &rows).await?))
        }
        .await;
        match scored {
            Ok(scores) => scores,
            Err(error) => {
                self.log(format!("RWKV current retrievability failed: {error}"));
                self.scoring_failed(&backend, &error);
                None
            }
        }
    }

    /// 打分入口的开头：没就绪就顺手触发准备、这一次不打分。
    fn scoring_backend(self: &Rc<Self>) -> Option<Rc<Backend>> {
        if self.phase() != Phase::Ready {
            let k = self.clone();
            self.host.exec.spawn(async move {
                if let Err(error) = k.start(false).await {
                    k.log(format!("RWKV start failed: {error}"));
                }
            });
            return None;
        }
        self.st.borrow().backend.clone()
    }

    /// 已就绪时打分失败。这不是「还没准备好」：留在「就绪」的话宿主等的「就绪」永远不会再来。所以转「出错」，
    /// 并丢掉这个后端——它的状态已不可信；重试重新打开、从快照恢复再按日志对齐。正在准备或已关闭时不动。
    fn scoring_failed(self: &Rc<Self>, backend: &Rc<Backend>, error: &Fault) {
        let dropped = {
            let mut st = self.s();
            if st.closed || st.preparing.is_some() || st.phase != Phase::Ready {
                return;
            }
            if same(backend, st.backend.as_ref()) {
                st.backend = None;
                st.replayed = None;
                st.counted_at = None;
                st.appends_since_snapshot = 0;
                true
            } else {
                false
            }
        };
        if dropped {
            self.cancel_timer();
            self.forget_scores();
            let (k, backend) = (self.clone(), backend.clone());
            self.host.exec.spawn(async move {
                if let Err(error) = backend.close(&k.host).await {
                    k.log(format!(
                        "RWKV backend close after scoring failure failed: {error}"
                    ));
                }
            });
        }
        self.fail(error);
    }

    /// 分数表的全量刷新时机：日界设置 / 本机状态纪元变了 → 清空；换日、牌组设置或同步合并、距上次整表重查
    /// 满 `requery_after_ms` → 当场整表重查；只是模型状态推进满 `refresh_every` 次 → 返回 true，调用方用完
    /// 这次的分数后在后台重查。
    async fn align_scores(
        &self,
        backend: &Rc<Backend>,
        inputs: &ScoreInputs,
        at_ms: i64,
    ) -> R<bool> {
        enum Action {
            Clear,
            Requery,
        }
        let action = {
            let st = self.st.borrow();
            if st.scores_clear_key.as_deref() != Some(inputs.clear_key.as_str()) {
                Action::Clear
            } else if st.scores_requery_key.as_deref() != Some(inputs.requery_key.as_str())
                || st.scores_today != Some(inputs.today)
                || at_ms - st.scores_at >= self.cfg.requery_after_ms
                || at_ms < st.scores_at
            {
                Action::Requery
            } else {
                return Ok(st.state_changes >= inputs.refresh_every);
            }
        };
        {
            let _serial = self.queue.lock().await;
            match action {
                Action::Clear => backend.clear_scores(&self.host).await?,
                Action::Requery => {
                    backend
                        .requery_scores(&self.host, inputs.today, at_ms)
                        .await?;
                }
            }
        }
        let mut st = self.s();
        st.scores_clear_key = Some(inputs.clear_key.clone());
        st.scores_requery_key = Some(inputs.requery_key.clone());
        st.scores_today = Some(inputs.today);
        st.scores_at = at_ms;
        st.state_changes = 0;
        Ok(false)
    }

    /// 后台整表重查：排在本次排队的查询后面，同一个 runtime 串行。计数在排进去时清零；已有一轮在排队时
    /// 不再排。
    fn requery_in_background(self: &Rc<Self>, backend: &Rc<Backend>, today: i64, at_ms: i64) {
        {
            let mut st = self.s();
            if st.requery_pending {
                return;
            }
            st.requery_pending = true;
            st.state_changes = 0;
        }
        let (k, backend) = (self.clone(), backend.clone());
        let turn = self.queue.lock();
        self.host.exec.spawn(async move {
            let requeried = {
                let _serial = turn.await;
                backend.requery_scores(&k.host, today, at_ms).await
            };
            match requeried {
                Ok(_) => {
                    let mut st = k.s();
                    if st.scores_today == Some(today) && at_ms > st.scores_at {
                        st.scores_at = at_ms;
                    }
                }
                Err(error) => k.log(format!("RWKV background requery failed: {error}")),
            }
            k.s().requery_pending = false;
        });
    }

    // ------------------------------------------------------------------ 其余入口

    async fn answered(self: &Rc<Self>) -> R<()> {
        if self.phase() != Phase::Ready {
            return Ok(());
        }
        // 本机这条与对端同步来的都在日志表里：统一按指纹对齐。
        self.refresh().await.map(|_| ())
    }

    /// 卡被永久清除：从分数表删掉它们的项。
    async fn purged(&self, ids: &[i64]) {
        let backend = {
            let st = self.st.borrow();
            if st.closed || ids.is_empty() {
                return;
            }
            st.backend.clone()
        };
        let Some(backend) = backend else {
            return;
        };
        let _serial = self.queue.lock().await;
        if let Err(error) = backend.remove_scores(&self.host, ids).await {
            // 删不掉只是多占内存；下次重建 / 清空时随整表一起没了。
            self.log(format!("RWKV score eviction failed: {error}"));
        }
    }

    /// 存快照、关后端。
    async fn close(&self) -> R<()> {
        let (backend, save) = {
            let mut st = self.s();
            if st.closed {
                return Ok(());
            }
            st.closed = true;
            (
                st.backend.clone(),
                st.phase == Phase::Ready && st.appends_since_snapshot > 0,
            )
        };
        self.cancel_timer();
        let mut result = Ok(());
        if let Some(backend) = backend {
            if save {
                let _serial = self.queue.lock().await;
                result = self.save_snapshot(&backend).await;
            }
            if let Err(error) = backend.close(&self.host).await {
                result = Err(error);
            }
        }
        self.s().status_closed = true;
        result
    }
}

fn print_of(replay: &Replay) -> Print {
    Print {
        count: replay.count,
        max_row_id: replay.max_row_id,
    }
}

fn delete_checkpoint(checkpoint: &Checkpoint) -> R<()> {
    files::remove_if_exists(&checkpoint.snap)?;
    files::remove_if_exists(&checkpoint.meta)?;
    Ok(())
}

fn write_scores(w: &mut Writer, scores: Option<&[f32]>) {
    w.bool(scores.is_some());
    if let Some(scores) = scores {
        w.u32(scores.len() as u32);
        for score in scores {
            w.f32(*score);
        }
    }
}

/// 攒着还没接进状态的评分行。
#[derive(Default)]
struct Pending {
    rows: Vec<u8>,
    tags: Vec<u8>,
    ats: Vec<u8>,
}

impl Pending {
    fn push(&mut self, row: &[u8], tag: u64, at: i64) {
        self.rows.extend_from_slice(row);
        self.tags.extend_from_slice(&tag.to_le_bytes());
        self.ats.extend_from_slice(&at.to_le_bytes());
    }

    fn view(&self) -> RowsView<'_> {
        RowsView {
            rows: &self.rows,
            ats: &self.ats,
            tags: &self.tags,
        }
    }
}
