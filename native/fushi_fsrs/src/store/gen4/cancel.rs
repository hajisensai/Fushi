//! 库句柄上在途命令的协作式取消（拍板台 review-merge-1124-leftovers 第 5 条，承 BUG-5394 / 反馈 3he3GEoqcU）。
//!
//! 关库（`ffsrs_store_close_begin` / `ffsrs_store_close`，[super::kernel::G4Core::cancel]）先置位一个令牌，再等在途命令
//! 退出。没有它时，关库要等在途命令自己跑完——开库时的 `cache_config_set` 整层重建、整包导入的 `Settle::Rebuild`
//! 可能几十秒，导入 / 覆盖恢复的遮罩就挂那么久。
//!
//! 令牌在三处被看（都只是一次原子读）：
//!
//! - **语句里**：库句柄开的每一条连接（写连接、读连接池、并回 WAL 与快照的旁路连接）都装了 SQLite 进度回调
//!   （[Cancel::watch]），每 [PROGRESS_OPS] 条虚拟机指令看一次，置位了就让当前语句以 `SQLITE_INTERRUPT` 退出。整层
//!   重建的逐实体扫描、大查询、`VACUUM INTO` 都在长语句里，取消在几十微秒内生效。进度计数按预编译语句累计
//!   （`prepare_cached` 的语句在循环里反复执行也会走到），但一次性的短语句可能一条都走不到——所以还有下面两处。
//! - **批次边界**：真相层每一次写入的守卫（`truth.rs` `Truth::write`）、整层重建的逐实体回调（`derive.rs`
//!   `rebuild_all`）、借读 / 写连接（[super::kernel::G4Core::reader] / `writer`）都先看令牌。
//! - **提交之前**：写命令的事务在 `COMMIT` 之前再看一次（`kernel.rs` `write_tx`）：取消之后不会有半截命令被提交。
//!
//! **一致性**靠事务：取消以错误的形式从命令里冒出来，写命令的事务整笔回滚（SQLite 被打断的写语句本身也会回滚整个
//! 显式事务）。分多个事务提交的命令（分批回收、清除的字节层收尾）本来就要扛进程在任意两步之间被杀，被取消与被杀是
//! 同一种情形，下一次打开 / 下一条命令接着做。
//!
//! 被取消的命令一律报 `CLOSED`（`ffi.rs` `run_core` 把错误统一换成它）：与「关库之后才到达」的命令同一个结果，Dart 按
//! 原文认「已关闭」。令牌只在关库时置位、不复位：句柄已经从句柄表里摘掉，不会再有新命令。

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use rusqlite::Connection;

use crate::store::CLOSED;

/// 进度回调的间隔（虚拟机指令数）。回调只是一次原子读：每千条指令一次，开销可以忽略，取消延迟在微秒级。
pub const PROGRESS_OPS: i32 = 1000;

/// 取消令牌（克隆共享同一个开关）。
#[derive(Clone, Default)]
pub struct Cancel(Arc<AtomicBool>);

impl Cancel {
    pub fn new() -> Cancel {
        Cancel::default()
    }

    /// 置位（幂等，任意线程）。
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    /// 批次边界：置位了报 `CLOSED`。
    pub fn check(&self) -> Result<(), String> {
        if self.is_cancelled() {
            Err(CLOSED.to_owned())
        } else {
            Ok(())
        }
    }

    /// 在 [conn] 上装进度回调：置位之后这条连接上正在跑、以及之后再跑的语句以 `SQLITE_INTERRUPT` 退出。
    pub fn watch(&self, conn: &Connection) {
        let flag = Arc::clone(&self.0);
        conn.progress_handler(PROGRESS_OPS, Some(move || flag.load(Ordering::Relaxed)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 进度回调：置位之后长语句被打断，没置位的照常跑完。
    #[test]
    fn a_watched_connection_interrupts_a_long_statement_once_cancelled() {
        let conn = Connection::open_in_memory().unwrap();
        let c = Cancel::new();
        c.watch(&conn);
        let n: i64 = conn
            .query_row(
                "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 10000) \
                 SELECT count(*) FROM n",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 10000);
        assert!(c.check().is_ok());
        c.cancel();
        assert_eq!(c.check().unwrap_err(), CLOSED);
        let e = conn
            .query_row(
                "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 1000000000) \
                 SELECT count(*) FROM n",
                [],
                |r| r.get::<_, i64>(0),
            )
            .unwrap_err();
        assert_eq!(
            e.sqlite_error_code(),
            Some(rusqlite::ErrorCode::OperationInterrupted),
            "{e}"
        );
    }
}
