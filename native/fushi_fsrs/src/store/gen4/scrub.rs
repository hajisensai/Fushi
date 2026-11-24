//! 彻底清除的字节层收尾（设计 §3.2「清除后原文不在本机」；交接 §26 T1 节 C3）。
//!
//! 清除在真相层把操作落成空洞（`Truth::advance_purge`：删掉 `ops` 那一行、记空洞），派生层的缓存行随之改写。表里
//! 读不到原文了，但 SQLite 删行 / 改行只是把旧内容所在的空间记成空闲，字节还在库文件的空闲页、页内碎片和 WAL 的
//! 旧帧里，按字节扫 `srs4.db` / `srs4.db-wal` 照样读得到。三件事一起保证字节层也干净：
//!
//! 1. **每条写连接开 `secure_delete`**（`schema.rs` `configure`）：删行、改行、释放页时把旧内容写零。新代库只有一条
//!    写连接（`schema::open`：内核写连接、迁移 / 预演的目标库），读连接是 `query_only`。`kernel.rs` 并 WAL 的旁路
//!    连接只做检查点、不删改行；协议 3 旧库的连接（封存、备份读入的临时副本）不是新代库。
//! 2. **清除提交之后把 WAL 并回主库并截断**（[scrub] 的 `wal_checkpoint(TRUNCATE)`）：WAL 里还留着原文最初写入那一笔
//!    的帧（写零的是新帧，旧帧要等检查点覆盖、WAL 重绕才没）。检查点要在事务外做，所以由内核的写命令在提交之后做
//!    （`kernel.rs` `write_tx`）。做之前在同一个事务里记下「欠一次收尾」（[DUE_KEY]，`advance_purge` 写）：进程在提交
//!    与收尾之间被杀、或检查点被别的读者挡住（`busy`），下一条写命令 / 下一次打开接着做，做完才删这一行。
//! 3. **存量库整理一次**：`secure_delete` 只管开了它之后释放的空间；在它之前释放的空闲页 / 页内碎片里可能还躺着更早的
//!    旧内容（同一段文字改过几次、派生缓存行重写过）。所以库上记一个标记 [SECURE_KEY] =「这个库从建库起每条写连接都
//!    开着 `secure_delete`，或已经整理过一次」：`schema::open` 新建库时写下；没有标记的库（这个改动之前建的新代库）在
//!    第一次清除收尾时整库 `VACUUM` 一次再写标记。
//!
//! 取舍（存量库）：`VACUUM` 重写整个库，要约等于库大小的临时空间、期间占着写锁；每次清除都做代价太大，开库时做会让
//! 每个存量库都在启动时卡一次。只在「第一次清除」时做一次：这时用户刚明确要求抹掉内容，承担一次整理是合理的，之后
//! 全靠 `secure_delete`。换代迁移建的库与全新安装都带标记，生产里需要整理的只有换代开发期间用集成分支建的库。
//!
//! # 没做成怎么办
//!
//! 收尾在命令提交之后做，没做成不回滚已提交的清除（表层已经清掉）；「欠一次收尾」[DUE_KEY] 留着。两种没做成分开处理：
//!
//! - **检查点被读者挡住**（[scrub] 回 `Ok(false)`）：读者放手就能做成。内核在之后每条写命令提交后接着试，但**不等**
//!   （[Wait::No]：忙等临时设成 0，被挡就立刻回来），不让复习作答因为一个读快照卡上 [super::schema::BUSY_TIMEOUT]。
//! - **出错**（整理时空间不够、I/O 错误……，[scrub] 回 `Err`）：原因记进 [ERROR_KEY]（读命令 `scrub_state` 的 `error`，
//!   UI 据此告诉用户「清除的内容在磁盘上还没抹干净」），内核不再逐条写命令重试——那样每条写命令都要重做一次注定失败的
//!   整库整理——只在下一次打开、或下一次又有清除落成空洞时再试。做成了删掉 [ERROR_KEY]。
//! - **被关库打断**（库句柄的取消令牌，`cancel.rs`）：不算出错，同「被读者挡住」回 `Ok(false)`、不记 [ERROR_KEY]，
//!   下一次打开接着做。

use rusqlite::{Connection, OptionalExtension};

use super::schema::sql;

/// `srs_meta` 键：这个库从建库起每条写连接都开着 `secure_delete`，或已经整理（`VACUUM`）过一次。值 `1`。
pub(crate) const SECURE_KEY: &str = "gen4_secure_delete";
/// `srs_meta` 键：有清除提交了、字节层收尾（[scrub]）还没做完。值 `1`。
pub(crate) const DUE_KEY: &str = "gen4_scrub_due";
/// `srs_meta` 键：上一次字节层收尾出错的原因（原文）。做成了删掉。
pub(crate) const ERROR_KEY: &str = "gen4_scrub_error";

fn has(conn: &Connection, key: &str) -> Result<bool, String> {
    Ok(conn
        .prepare_cached("SELECT 1 FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .query_row([key], |_| Ok(()))
        .optional()
        .map_err(sql)?
        .is_some())
}

fn put(conn: &Connection, key: &str) -> Result<(), String> {
    conn.prepare_cached("INSERT OR REPLACE INTO srs_meta (key, value) VALUES (?1, '1')")
        .map_err(sql)?
        .execute([key])
        .map_err(sql)?;
    Ok(())
}

/// 新建的库：从第一页起就开着 `secure_delete`（`schema::open` 在建表的同一个事务里调）。
pub(crate) fn mark_secure_from_birth(conn: &Connection) -> Result<(), String> {
    put(conn, SECURE_KEY)
}

/// 记下「欠一次字节层收尾」（落空洞的同一个事务里调）。
pub(crate) fn mark_due(conn: &Connection) -> Result<(), String> {
    put(conn, DUE_KEY)
}

/// 有没有欠着的字节层收尾。
pub(crate) fn due(conn: &Connection) -> Result<bool, String> {
    has(conn, DUE_KEY)
}

/// 有没有欠着的字节层收尾，与上一次没做成的原因（[ERROR_KEY]）。读命令 `scrub_state` 用。
pub(crate) fn state(conn: &Connection) -> Result<(bool, Option<String>), String> {
    let error = conn
        .prepare_cached("SELECT value FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .query_row([ERROR_KEY], |r| r.get::<_, String>(0))
        .optional()
        .map_err(sql)?;
    Ok((due(conn)?, error))
}

/// [scrub] 的检查点等不等读者。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Wait {
    /// 按连接上的忙等（[super::schema::BUSY_TIMEOUT]）等：刚落了空洞、打开库时。
    Yes,
    /// 不等：被挡就回 `Ok(false)`。之前被挡、之后的写命令顺手再试时用。
    No,
}

/// 字节层收尾（[conn] 是写连接、不在事务里）：没有标记的存量库先整库整理一次，再把 WAL 并回主库并截断，都成了才删
/// 「欠一次收尾」。回包：做完了没有（`false` = 检查点被别的读者挡住，留到下一次）。没欠就什么都不做。出错时原因记进
/// [ERROR_KEY]（记不下也照样把原错误报回去），做成了删掉它。
///
/// [cancel]：库句柄的取消令牌（`cancel.rs`；开库时还没有句柄，给 `None`）。关库开始之后不动手，动手途中被打断
/// （进度回调让 `VACUUM` / 检查点以 `SQLITE_INTERRUPT` 退出）也不算出错：「欠一次收尾」留着、不记 [ERROR_KEY]，回
/// `Ok(false)`，下一次打开接着做——被关库打断不是「整理时空间不够」那类要告诉用户的失败。
pub(crate) fn scrub(
    conn: &Connection,
    wait: Wait,
    cancel: Option<&super::cancel::Cancel>,
) -> Result<bool, String> {
    let cancelled = || cancel.is_some_and(super::cancel::Cancel::is_cancelled);
    if !conn.is_autocommit() {
        return Err("gen4 scrub: must run outside a transaction".to_owned());
    }
    if cancelled() {
        return Ok(false);
    }
    if !due(conn)? {
        return Ok(true);
    }
    let out = match wait {
        Wait::Yes => attempt(conn),
        Wait::No => {
            conn.busy_timeout(std::time::Duration::ZERO).map_err(sql)?;
            let out = attempt(conn);
            conn.busy_timeout(super::schema::BUSY_TIMEOUT)
                .map_err(sql)?;
            out
        }
    };
    if out.is_err() && cancelled() {
        return Ok(false);
    }
    if let Err(e) = &out {
        // 记不下（库坏了、盘满）就只把原错误报回去：调用方照样知道没做成。
        let _ = conn
            .prepare_cached("INSERT OR REPLACE INTO srs_meta (key, value) VALUES (?1, ?2)")
            .and_then(|mut s| s.execute([ERROR_KEY, e.as_str()]));
    }
    out
}

/// 测试注入：下一次 [attempt] 直接报错（模拟整理时空间不够）。按线程。
#[cfg(test)]
pub(crate) mod test_fail {
    use std::cell::Cell;

    thread_local! {
        pub(crate) static FAIL: Cell<bool> = const { Cell::new(false) };
        /// [super::attempt] 真正动手的次数。
        pub(crate) static ATTEMPTS: Cell<u32> = const { Cell::new(0) };
    }
}

fn attempt(conn: &Connection) -> Result<bool, String> {
    #[cfg(test)]
    {
        test_fail::ATTEMPTS.with(|c| c.set(c.get() + 1));
        if test_fail::FAIL.with(|f| f.get()) {
            return Err("gen4 scrub: injected failure".to_owned());
        }
    }
    if !has(conn, SECURE_KEY)? {
        conn.execute_batch("VACUUM").map_err(sql)?;
        put(conn, SECURE_KEY)?;
    }
    if !checkpoint_truncate(conn)? {
        return Ok(false);
    }
    conn.prepare_cached("DELETE FROM srs_meta WHERE key IN (?1, ?2)")
        .map_err(sql)?
        .execute([DUE_KEY, ERROR_KEY])
        .map_err(sql)?;
    // 删标记那一笔又写了一帧（只有 `srs_meta` 那一页，不带内容）：再并一次，WAL 归零。
    checkpoint_truncate(conn)
}

/// `wal_checkpoint(TRUNCATE)`：全部并回主库、WAL 截成 0 字节。被读者挡住（`busy`）= false。
fn checkpoint_truncate(conn: &Connection) -> Result<bool, String> {
    let busy: i64 = conn
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |r| r.get(0))
        .map_err(sql)?;
    Ok(busy == 0)
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::*;
    use crate::store::gen4::schema::{BUSY_TIMEOUT, open};
    use crate::store::sync2::tests::tempdir;

    /// 第三轮复核：[Wait::No] 被读者挡住时立刻回来（不等 [BUSY_TIMEOUT]），「欠一次收尾」留着、不算出错，连接的忙等
    /// 照旧；读者放手之后同样不等就做成。
    #[test]
    fn a_retry_that_does_not_wait_returns_at_once_when_a_reader_holds_the_wal() {
        let dir = tempdir::new("scrub-nowait");
        let path = dir.0.join("srs4.db");
        let w = open(&path).unwrap();
        w.execute_batch("INSERT INTO srs_meta (key, value) VALUES ('scrub-test-1', 'x')")
            .unwrap();
        let r = rusqlite::Connection::open(&path).unwrap();
        r.execute_batch("BEGIN").unwrap();
        let _: i64 = r
            .query_row("SELECT COUNT(*) FROM srs_meta", [], |x| x.get(0))
            .unwrap();
        w.execute_batch("INSERT INTO srs_meta (key, value) VALUES ('scrub-test-2', 'y')")
            .unwrap();
        mark_due(&w).unwrap();

        let started = Instant::now();
        assert_eq!(
            scrub(&w, Wait::No, None),
            Ok(false),
            "blocked by the reader"
        );
        let took = started.elapsed();
        assert!(
            took < BUSY_TIMEOUT / 5,
            "did not wait for the reader: {took:?}"
        );
        assert!(due(&w).unwrap(), "still owed");
        assert_eq!(state(&w).unwrap(), (true, None), "blocked is not an error");
        let ms: i64 = w
            .query_row("PRAGMA busy_timeout", [], |x| x.get(0))
            .unwrap();
        assert_eq!(Duration::from_millis(ms as u64), BUSY_TIMEOUT);

        r.execute_batch("COMMIT").unwrap();
        assert_eq!(scrub(&w, Wait::No, None), Ok(true));
        assert!(!due(&w).unwrap());
    }

    /// 拍板台 review-merge-1124-leftovers 第 5 条（关库取消在途命令）：存量库的整库 `VACUUM` 做到一半关库开始了，被
    /// 进度回调打断——不是「整理出错」：不记 [ERROR_KEY]（否则界面会说「清除的内容在磁盘上还没抹干净：interrupted」），
    /// 「欠一次收尾」留着、回 `Ok(false)`，下一次打开（不带令牌）照常做完。关库开始之后再到的收尾不动手。
    #[test]
    fn a_scrub_interrupted_by_closing_is_still_owed_and_not_an_error() {
        use crate::store::gen4::cancel::{Cancel, PROGRESS_OPS};
        let dir = tempdir::new("scrub-cancel");
        let path = dir.0.join("srs4.db");
        let w = open(&path).unwrap();
        w.execute_batch(
            "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 5000)              INSERT INTO srs_meta (key, value) SELECT 'scrub-cancel-' || x, 'x' FROM n",
        )
        .unwrap();
        // 存量库：没有「从建库起就 secure_delete」的标记，收尾要整库 `VACUUM`。
        w.execute("DELETE FROM srs_meta WHERE key = ?1", [SECURE_KEY])
            .unwrap();
        mark_due(&w).unwrap();

        let cancel = Cancel::new();
        // 关库开始在 `VACUUM` 途中到达：第一次进度回调时置位令牌并打断（同 `Cancel::watch` 装的回调置位之后的样子）。
        let arrives = cancel.clone();
        w.progress_handler(
            PROGRESS_OPS,
            Some(move || {
                arrives.cancel();
                true
            }),
        );
        assert_eq!(scrub(&w, Wait::Yes, Some(&cancel)), Ok(false));
        w.progress_handler(PROGRESS_OPS, None::<fn() -> bool>);
        assert!(!has(&w, SECURE_KEY).unwrap(), "the VACUUM did not finish");
        assert_eq!(state(&w).unwrap(), (true, None), "still owed, not an error");

        // 已经取消了：再到的收尾不动手。
        assert_eq!(scrub(&w, Wait::Yes, Some(&cancel)), Ok(false));
        assert_eq!(state(&w).unwrap(), (true, None));

        // 下一次打开（没有令牌）照常做完。
        assert_eq!(scrub(&w, Wait::Yes, None), Ok(true));
        assert_eq!(state(&w).unwrap(), (false, None));
        assert!(has(&w, SECURE_KEY).unwrap());
    }
}
