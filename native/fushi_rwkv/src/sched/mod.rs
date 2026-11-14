// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! RWKV 排程内核：编排状态机（[`machine`]）+ 它与宿主之间的一条消息通道。
//!
//! 内核持有全部编排状态（已回放到哪、撤销日志的 floor、分数表的刷新时机、准备 / 出错 / 重试……）与
//! runtime 本身；宿主（Dart）只做三件事：把命令递进来、替内核取数（effect）、把状态事件转给界面。
//! 没就绪时打分命令一律回「没有」，app 与无头服务端共用这一处判断。
//!
//! # 调用方式
//!
//! `frwkv_sched_step(句柄, 一条输入消息)` → 一段输出（若干条记录）。句柄不是线程安全的：同一时刻只能有
//! 一个调用在跑，调用之间由宿主串行化（Dart 侧是专门的后台 isolate——回放要几秒到几十秒；isolate 在两次
//! 调用之间可能换操作系统线程，内核不依赖线程身份，只有 `frwkv_last_error` 是线程局部的，所以失败后要在
//! 同一段同步代码里取错误文本）。输入消息的内存由
//! [`frwkv_sched_alloc`] 分配、`step` 接管（大块的回放行因此只复制一次）；输出由调用方用
//! `frwkv_free_bytes` 释放。输出第一个字节非 0 = 内核还有活要干（刚把「开始」之类的记录交出来），
//! 宿主应立刻用空消息再调一次。
//!
//! # 消息布局（小端；`str` / `bytes` = u32 长度 + 内容，`T[]` = u32 个数 + 元素，`opt T` = u8 有无 + T）
//!
//! 输入（第一个字节是种类；空消息 = 接着跑）：
//! - 1 命令：`op u32, cmd u8`，再按命令：1 start `force u8`；2 rebuild；3 refresh；
//!   4 instant `cards u32, at_ms i64`；5 current `cards u32, now_ms i64`；6 answered；
//!   7 purged `ids i64[]`；8 close。
//! - 2 回复：`effect u32, ok u8`，成功时后面整段是正文，失败时是 `str` 错误文本。
//! - 3 进度：`effect u32, done i64, total i64`（下载）。
//! - 4 定时器到点：`generation u32`。
//!
//! 输出：第一个字节 = 还要不要立刻再调，之后是若干条记录，每条 `tag u8, len u32, 正文`：
//! - 1 状态：`phase u8, phase_changed u8, done i64, total i64, has_error u8 [, origin u32, text str]`。
//!   每次设置都发；同一段输出里状态在命令结果之前。
//! - 2 命令结果：`op u32, ok u8`，失败 `origin u32, text str`；成功按命令：refresh `aligned u8`；
//!   instant / current `has u8 [, f32[]]`；其余没有正文。
//! - 3 effect：`id u32, kind u8`，再按种类（回复正文在「→」后）：
//!   1 修订号 → `str`；
//!   2 日志尾巴 `since_incremental i64, since_full i64, with_rows u8, if_content opt str`
//!   → `content str, incremental u8, count i64, max_row_id i64, new_rows i64, n u32,
//!   n × (id str, card str, kind u8 (1 评分 / 2 撤销 / 0 其它), at i64, revokes opt str)`；
//!   3 回放行 `since i64, rebase_since opt i64, rows_from opt i64` → `ffsrs_store_rwkv_rows` 的原始字节；
//!   4 追加行 `cards u32, 每张 (card str, ids u32, id str…), tags u32, tag str…`
//!   → `missing_card u8`；为 0 时每张卡 `has u8 [, 每条日志 bytes]`，再 `tags u64[]`；
//!   5 打分输入 `op u32, at_ms i64`
//!   → `today i64, refresh_every i64, clear_key str, requery_key str, ids i64[], versions u64[]`；
//!   6 查询行 `op u32, at_ms i64, some u8 [, indices u32[]]` → `rows bytes, anchors i64[]`；
//!   7 正在收段 → `u8`；8 等收段结束 → 空；9 调度日序 `a i64, b i64` → `i64, i64`；
//!   10 权重 → `ready u8, path str`；11 下载（进度走输入 3，完成走回复）；12 清理已移除的模型 → 空；
//!   13 重建钩子（测试）→ 空；14 打开后端 `backend u32, weights str` → 空（仅宿主后端模式）；
//!   15 后端调用 `backend u32, call u8, …`（仅宿主后端模式，调用号与参数见 `host.rs` 的 `BK_*`）。
//! - 4 日志：`str`。
//! - 5 原生调用开始：`id u32, name str, bytes i64, rows i64`；6 原生调用结束：`id u32`（宿主记进操作账本）。
//! - 7 定时器：`generation u32, after_ms i64`（< 0 = 取消；新的一个顶掉旧的）。
//! - 8 不再等某个 effect：`id u32`。

mod exec;
mod files;
mod host;
mod machine;
#[cfg(test)]
mod tests;
mod wire;

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::rc::Rc;

use self::exec::Exec;
use self::host::{Fault, Host, Reply};
use self::machine::{Cfg, Command, Kernel};
use self::wire::Reader;
use crate::{panic_message, set_last_error};

const IN_COMMAND: u8 = 1;
const IN_REPLY: u8 = 2;
const IN_PROGRESS: u8 = 3;
const IN_TIMER: u8 = 4;

const CMD_START: u8 = 1;
const CMD_REBUILD: u8 = 2;
const CMD_REFRESH: u8 = 3;
const CMD_INSTANT: u8 = 4;
const CMD_CURRENT: u8 = 5;
const CMD_ANSWERED: u8 = 6;
const CMD_PURGED: u8 = 7;
const CMD_CLOSE: u8 = 8;

/// 不透明句柄：一个排程内核。不是线程安全的：调用方串行化（同一时刻只有一个调用）。
pub struct FrwkvSched {
    exec: Rc<Exec>,
    host: Rc<Host>,
    kernel: Rc<Kernel>,
    /// 之前一次 `step` panic 过：状态不可信，之后的调用一律报错。
    poisoned: bool,
}

impl FrwkvSched {
    fn new(config: &[u8]) -> Result<Self, String> {
        let mut r = Reader::new(config);
        let cfg = Cfg {
            profile: r.str()?,
            dir: PathBuf::from(r.str()?),
            threads: r.u32()? as usize,
            journal_seed: usize::try_from(r.i64()?).map_err(|_| "negative journal seed")?,
            requery_after_ms: r.i64()?,
            host_backend: r.bool()?,
            snapshot_idle_ms: r.i64()?,
            retry_after_ms: r.i64()?,
        };
        let exec = Rc::new(Exec::default());
        let host = Rc::new(Host::new(exec.clone()));
        let kernel = Kernel::new(cfg, host.clone());
        Ok(Self {
            exec,
            host,
            kernel,
            poisoned: false,
        })
    }

    fn feed(&self, input: Box<[u8]>) -> Result<(), String> {
        if input.is_empty() {
            return Ok(());
        }
        let mut r = Reader::new(&input);
        match r.u8()? {
            IN_COMMAND => {
                let op = r.u32()?;
                let command = match r.u8()? {
                    CMD_START => Command::Start { force: r.bool()? },
                    CMD_REBUILD => Command::Rebuild,
                    CMD_REFRESH => Command::Refresh,
                    CMD_INSTANT => Command::Instant {
                        cards: r.u32()?,
                        at_ms: r.i64()?,
                    },
                    CMD_CURRENT => Command::Current {
                        cards: r.u32()?,
                        now_ms: r.i64()?,
                    },
                    CMD_ANSWERED => Command::Answered,
                    CMD_PURGED => Command::Purged { ids: r.i64s()? },
                    CMD_CLOSE => Command::Close,
                    other => return Err(format!("unknown command {other}")),
                };
                self.kernel.command(op, command);
            }
            IN_REPLY => {
                let id = r.u32()?;
                if r.bool()? {
                    let at = r.position();
                    self.host.deliver_reply(id, Ok(Reply { buffer: input, at }));
                } else {
                    let text = r.str()?;
                    self.host.deliver_reply(id, Err(Fault::new(text)));
                }
            }
            IN_PROGRESS => {
                let id = r.u32()?;
                let done = r.i64()?;
                let total = r.i64()?;
                self.host.deliver_progress(id, done, total);
            }
            IN_TIMER => self.kernel.timer_fired(r.u32()?),
            other => return Err(format!("unknown input kind {other}")),
        }
        Ok(())
    }

    /// 喂一条输入、跑到停下，返回输出（第一个字节 = 还要不要立刻再调）。
    fn step(&self, input: Box<[u8]>) -> Result<Vec<u8>, String> {
        self.feed(input)?;
        let more = self.exec.run();
        let records = self.host.take_output();
        let mut out = Vec::with_capacity(records.len() + 1);
        out.push(u8::from(more));
        out.extend_from_slice(&records);
        Ok(out)
    }
}

impl Drop for FrwkvSched {
    fn drop(&mut self) {
        // 任务里握着内核的引用、内核又经宿主握着执行器：先清任务，环才解得开。
        self.exec.clear();
    }
}

/// 给一条输入消息分配 `len` 字节（清零）。写好后交给 [frwkv_sched_step]（它接管这块内存）；没交出去的
/// 用 `frwkv_free_bytes` 释放。`len == 0` 返回空指针。
#[no_mangle]
pub extern "C" fn frwkv_sched_alloc(len: usize) -> *mut u8 {
    if len == 0 {
        return std::ptr::null_mut();
    }
    match catch_unwind(|| Box::into_raw(vec![0u8; len].into_boxed_slice()).cast::<u8>()) {
        Ok(ptr) => ptr,
        Err(panic) => {
            set_last_error(panic_message(panic.as_ref()));
            std::ptr::null_mut()
        }
    }
}

/// 新建排程内核。`config`：`profile str, snapshot_dir str, threads u32, journal_seed i64,
/// requery_after_ms i64, host_backend u8, snapshot_idle_ms i64, retry_after_ms i64`（布局见模块注释）。
/// 失败返回空指针。
///
/// # Safety
/// `config` 指向 `config_len` 个可读字节。
#[no_mangle]
pub unsafe extern "C" fn frwkv_sched_new(config: *const u8, config_len: usize) -> *mut FrwkvSched {
    let created = catch_unwind(AssertUnwindSafe(|| {
        let config = crate::slice_or_empty(config, config_len).ok_or("null config")?;
        FrwkvSched::new(config)
    }));
    match created {
        Ok(Ok(sched)) => Box::into_raw(Box::new(sched)),
        Ok(Err(message)) => {
            set_last_error(message);
            std::ptr::null_mut()
        }
        Err(panic) => {
            set_last_error(panic_message(panic.as_ref()));
            std::ptr::null_mut()
        }
    }
}

/// 喂一条输入消息（`input` 来自 [frwkv_sched_alloc]，本调用接管；空指针 + 0 = 接着跑），返回输出并把长度
/// 写进 `out_len`；输出用 `frwkv_free_bytes` 释放。失败（消息不合布局 / 内核 panic 过）返回空指针、
/// `out_len` 写 0，原因走 `frwkv_last_error`。
///
/// # Safety
/// `sched` 有效且没有别的调用同时在用它；`input` / `input_len` 来自 [frwkv_sched_alloc]（或空）；`out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn frwkv_sched_step(
    sched: *mut FrwkvSched,
    input: *mut u8,
    input_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let input: Box<[u8]> = if input.is_null() || input_len == 0 {
        Box::new([])
    } else {
        Box::from_raw(std::ptr::slice_from_raw_parts_mut(input, input_len))
    };
    if let Some(out_len) = out_len.as_mut() {
        *out_len = 0;
    }
    let Some(sched) = sched.as_mut() else {
        set_last_error("null sched".to_owned());
        return std::ptr::null_mut();
    };
    if out_len.is_null() {
        set_last_error("null output length".to_owned());
        return std::ptr::null_mut();
    }
    if sched.poisoned {
        set_last_error("scheduler is poisoned by an earlier panic".to_owned());
        return std::ptr::null_mut();
    }
    match catch_unwind(AssertUnwindSafe(|| sched.step(input))) {
        Ok(Ok(out)) => {
            let out = out.into_boxed_slice();
            *out_len = out.len();
            Box::into_raw(out).cast::<u8>()
        }
        Ok(Err(message)) => {
            set_last_error(message);
            std::ptr::null_mut()
        }
        Err(panic) => {
            sched.poisoned = true;
            set_last_error(panic_message(panic.as_ref()));
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `sched` 必须是 [frwkv_sched_new] 返回且未释放过的句柄（或空指针），且没有别的调用同时在用它。
#[no_mangle]
pub unsafe extern "C" fn frwkv_sched_free(sched: *mut FrwkvSched) {
    if !sched.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(sched))));
    }
}
