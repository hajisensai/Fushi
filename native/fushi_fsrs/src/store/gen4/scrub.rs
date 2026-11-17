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
//! 全靠 `secure_delete`。整理失败（空间不够等）不回滚已提交的清除（表层已经清掉），「欠一次收尾」留着，之后每条写
//! 命令与下一次打开接着做，做成为止。换代迁移建的库与全新安装都带标记，生产里需要整理的只有换代开发期间用集成分支
//! 建的库。

use rusqlite::{Connection, OptionalExtension};

use super::schema::sql;

/// `srs_meta` 键：这个库从建库起每条写连接都开着 `secure_delete`，或已经整理（`VACUUM`）过一次。值 `1`。
pub(crate) const SECURE_KEY: &str = "gen4_secure_delete";
/// `srs_meta` 键：有清除提交了、字节层收尾（[scrub]）还没做完。值 `1`。
pub(crate) const DUE_KEY: &str = "gen4_scrub_due";

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

/// 字节层收尾（[conn] 是写连接、不在事务里）：没有标记的存量库先整库整理一次，再把 WAL 并回主库并截断，都成了才删
/// 「欠一次收尾」。回包：做完了没有（`false` = 检查点被别的读者挡住，留到下一次）。没欠就什么都不做。
pub(crate) fn scrub(conn: &Connection) -> Result<bool, String> {
    if !conn.is_autocommit() {
        return Err("gen4 scrub: must run outside a transaction".to_owned());
    }
    if !due(conn)? {
        return Ok(true);
    }
    if !has(conn, SECURE_KEY)? {
        conn.execute_batch("VACUUM").map_err(sql)?;
        put(conn, SECURE_KEY)?;
    }
    if !checkpoint_truncate(conn)? {
        return Ok(false);
    }
    conn.prepare_cached("DELETE FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .execute([DUE_KEY])
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
