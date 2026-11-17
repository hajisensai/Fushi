//! 丢掉本机一个集合（G9-5，规划 §2.2「删旧并入、收薄 profile 关联」、§6 合并条件「空集合可换绑」）：删 profile 时清它的
//! 集合数据（命令 `profile_purge`，`cmd/profile_data.rs`）、「空集合可换绑」（`identity.rs` [adopt_foreign] 的 `Bound`
//! 分支）与半截并入的收尾（`profile_merge_commit`）都经 [discard_collection] 这一处删。
//!
//! # 删除面
//!
//! 集合 [col] 在库里的全部行，表清单在库里现查（同 `cmd/profile.rs` 的 `profile_footprint`：以后加的表自动落进删除面）：
//!
//! - 带 `col` 列的表（真相的 `devs` / `trust` / `derive_cfg`、本机状态、同步状态、派生层、缓存层、`cache_gen` /
//!   `cache_log`）：`WHERE col = ?`；
//! - 按操作主键寻址、没有 `col` 列的真相表（`ops` / `op_alias` / `op_voids` / `op_pending` / `op_forks` / `op_wait`）：
//!   按本集合每台设备的主键区间 `k BETWEEN lo AND hi`（`devs.dev` 只属于一个集合）；
//! - 按设备下标的 `log_marks`：`WHERE dev = ?`；
//! - `srs_meta` 里按集合号记的键：`self_info/<col>`（`device_info`）、`gen4_out/<col>/…`（已传水位）、
//!   `gen4_retired/<col>/…`（停用记录）——[META_COL_PREFIXES]；
//! - 最后是绑定 `collections` 那一行。
//!
//! # 缓存层代号
//!
//! `cache_gen` 那一行不删，抬一代、下限抬上去（[CACHE_GEN_BUMP_SQL]）：`collections.col` 是没有 AUTOINCREMENT 的整数
//! 主键，丢掉的号会被之后新绑的集合复用（「空集合可换绑」紧接着就绑一个），而常驻的浏览会话按 (集合号, 代号) 认缓存。
//!
//! **不删**：按内容跨集合共用、只增的 `op_deps` / `writers` / `snapshots`（别的集合的操作可能引用同一行；留下的几行
//! 无害，协议 3 的 `sync2_snapshots` 同口径）；按 profile 记的本机状态行 `local_state/<profile>`（换绑时 profile 不变，
//! 删 profile 时由 `profile_purge` 另删）；按设备记的 `device_hint/<设备>`（设备 ID 全局唯一、不分集合）。
//!
//! 别的集合一行不碰：每条语句都带本集合的 `col` / 本集合设备的主键区间 / 设备下标（测试
//! `discarding_one_collection_leaves_the_other_untouched` 逐表核对另一个集合的行数与语义摘要）。
//!
//! # 「空集合」（[disposable]）
//!
//! 规划 §6：本机集合里**没有任何用户内容**、**没有别的设备**、**从没发布到任何位置**——丢掉它不丢任何人的东西、也没有
//! 别的设备可能已经认它（并入它、跟着它）。逐条：
//!
//! - 有本机身份；`devs` 里只有本机设备（承袭日志、别的设备一个都没有，连「被点过名、还没见过日志」的也没有）；
//! - **没有用户内容**：与首次信任同一个判据 [Truth::library_fresh]（`truth/trust.rs`，一份实现）——日志里只有内置种子
//!   （Dart 开库就写的默认牌组、内置笔记类型，`SrsDbStore.ensureBuiltins`）、盐、还原点，没有空洞、承袭槽、暂缓 / 分叉
//!   / 等待中的条目。以前这里只认「每条都是 `Salts`」，于是 app 里开过 store 的全新 profile（`ensureBuiltins` 写了内置
//!   实体）一律判成非空、关联已有集合时照 D27 写 `Join`，§6「新设备关联已有集合，结论 bound、不产生 Join」在 app 里
//!   达不到（第五波 G9 身份收尾）。内置种子按规范规则派生、不带盐（G9-7），对方集合里的同一个内置实体是同一个 ID，
//!   丢掉本机这几条不丢东西；
//! - 本机日志里没有 `Join`：并入过别的集合 = 那个集合的设备可能跟着它（与下一条「发布过」同一类理由）；
//! - `peers` 里除本机自己没有别的设备，`trust` 里没有任何记录；
//! - 没发布过：`loc_heads` 没有本集合的行（`head` 写下的本机 head 就记在这里）、`relay_out` 没有、`srs_meta` 里没有
//!   已传水位 `gen4_out/<col>/…`（`outbox_ack` 记的）、**`loc_state` 没有**（G9-5 第二轮复核）——`location_root`
//!   写过位置的根（`v4/meta.json`、loc 标记、旧根围栏）或 `location_seal` 记过加密，都会在 `loc_state` 留一行。那份
//!   `meta.json` 已经让别的设备在位置上看得到这个集合，丢掉它就在位置上留下一个指向没人持有的集合的孤儿 `meta.json`，
//!   而内核不碰位置上的文件、删不掉它：所以碰过位置就不再是空集合，照 D27 并入。同步调度先关联、后跑第一轮
//!   （`srs_sync_scheduler.dart`：`link` 在 `_runRoundOn` 之前），新设备关联已有集合时通常还没立过根，照样能换绑。
//!
//! 只读、一个快照里判（调用方在写事务里调，判与删在同一个事务）。
//!
//! # 查询
//!
//! 删除语句按表现拼（[delete_sql]，表名来自库里的 `sqlite_schema`），每条都走主键 / 唯一索引打头的 `col` / `k` / `dev`：
//! `discard_statements_use_an_index` 对库里的每张表用同一个 [delete_sql] 拼出语句、查执行计划，不许 `SCAN`。
//! [disposable] 的几条语句同样有执行计划测试（[DISPOSABLE_SQL]）。

use rusqlite::{OptionalExtension, params};

use super::schema::{k_range, sql};
use super::truth::Truth;
use crate::gen4::op::KIND_JOIN;

/// `srs_meta` 里按集合号记的键前缀（`<前缀><col>` 或 `<前缀><col>/…`）。
pub(crate) const META_COL_PREFIXES: [&str; 3] = ["self_info/", "gen4_out/", "gen4_retired/"];

/// 一张表怎么按集合寻址。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Addr {
    /// 有 `col` 列。
    Col,
    /// 没有 `col`、有操作主键 `k`：按设备区间。
    Key,
    /// 没有 `col` / `k`、有设备下标 `dev`。
    Dev,
}

/// 库里除 `collections` / `srs_meta` 与 SQLite 内部表以外的每张表，及它怎么按集合寻址（都不是 = 不按集合分的共用表，
/// 不列）。
pub(crate) fn tables(t: &Truth<'_>) -> Result<Vec<(String, Addr)>, String> {
    let rows: Vec<(String, bool, bool, bool)> = {
        let mut stmt = t
            .conn()
            .prepare_cached(
                "SELECT m.name, \
                 MAX(p.name = 'col'), MAX(p.name = 'k'), MAX(p.name = 'dev') \
                 FROM sqlite_schema m, pragma_table_info(m.name) p \
                 WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' \
                 AND m.name NOT IN ('collections', 'srs_meta') \
                 GROUP BY m.name ORDER BY m.name",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)?
    };
    Ok(rows
        .into_iter()
        .filter_map(|(name, col, k, dev)| {
            let addr = if col {
                Addr::Col
            } else if k {
                Addr::Key
            } else if dev {
                Addr::Dev
            } else {
                return None;
            };
            Some((name, addr))
        })
        .collect())
}

/// 删一张表里本集合的行的语句（[Addr::Col]：?1 = col；[Addr::Key]：?1..?2 = 一台设备的主键区间；[Addr::Dev]：?1 = 设备下标）。
pub(crate) fn delete_sql(table: &str, addr: Addr) -> String {
    let t = table.replace('"', "\"\"");
    match addr {
        Addr::Col => format!("DELETE FROM \"{t}\" WHERE col = ?1"),
        Addr::Key => format!("DELETE FROM \"{t}\" WHERE k BETWEEN ?1 AND ?2"),
        Addr::Dev => format!("DELETE FROM \"{t}\" WHERE dev = ?1"),
    }
}

/// [discard_collection] 删了什么。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Discarded {
    /// 删掉的总行数（含 `srs_meta` 键与绑定那一行）。
    pub rows: i64,
    /// 逐表行数（只列非零的；`srs_meta` 与 `collections` 也在里面）。
    pub tables: Vec<(String, i64)>,
}

/// 删掉集合 [col] 在库里的全部行（文件头「删除面」）。一个 SAVEPOINT（[Truth::tx]：嵌在调用方的写事务里）；集合不存在
/// 报错、什么都不删。删完之后 [col] 这个号不再属于任何 profile（`collections` 的整数主键可能被之后新绑的集合复用，
/// 调用方负责让按集合号缓存的常驻会话失效，见 `dispatch.rs`）。
pub fn discard_collection(t: &Truth<'_>, col: i64) -> Result<Discarded, String> {
    t.tx(|t| {
        if t.binding(col)?.is_none() {
            return Err(format!("gen4 discard: no collection {col}"));
        }
        let conn = t.conn();
        let devs: Vec<i64> = t.devices(col)?.into_iter().map(|d| d.dev).collect();
        let mut out = Discarded::default();
        let mut note = |table: &str, n: i64| {
            if n > 0 {
                out.rows += n;
                match out.tables.iter_mut().find(|(t, _)| t == table) {
                    Some((_, m)) => *m += n,
                    None => out.tables.push((table.to_owned(), n)),
                }
            }
        };
        // 先删按设备寻址的（要 `devs` 的下标），`devs` 自己有 `col` 列，最后随带 `col` 的表一起删。
        let all = tables(t)?;
        for (table, addr) in all.iter().filter(|(_, a)| *a != Addr::Col) {
            let q = delete_sql(table, *addr);
            let mut stmt = conn.prepare(&q).map_err(sql)?;
            for &dev in &devs {
                let n = match addr {
                    Addr::Key => {
                        let (lo, hi) = k_range(dev);
                        stmt.execute(params![lo, hi])
                    }
                    _ => stmt.execute([dev]),
                }
                .map_err(sql)?;
                note(table, n as i64);
            }
        }
        for (table, _) in all.iter().filter(|(_, a)| *a == Addr::Col) {
            if table == CACHE_GEN {
                continue;
            }
            let n = conn
                .prepare(&delete_sql(table, Addr::Col))
                .map_err(sql)?
                .execute([col])
                .map_err(sql)?;
            note(table, n as i64);
        }
        // 缓存层代号不删、抬到比现在高一代并把下限抬上去（文件头「缓存层代号」）。
        conn.prepare_cached(CACHE_GEN_BUMP_SQL)
            .map_err(sql)?
            .execute([col])
            .map_err(sql)?;
        let mut meta = 0i64;
        for prefix in META_COL_PREFIXES {
            let exact = format!("{prefix}{col}");
            let under = format!("{prefix}{col}/");
            meta += conn
                .prepare_cached(META_DELETE_SQL)
                .map_err(sql)?
                .execute(params![exact, under])
                .map_err(sql)? as i64;
        }
        note("srs_meta", meta);
        let n = conn
            .prepare_cached("DELETE FROM collections WHERE col = ?1")
            .map_err(sql)?
            .execute([col])
            .map_err(sql)?;
        note("collections", n as i64);
        // 同一个连接上按集合号攒着的读缓存（`Truth` 的本进程缓存）不能留着：这个号之后可能给别的集合用。
        t.reset();
        Ok(out)
    })
}

/// 缓存层代号表（`cache.rs`）：[discard_collection] 不删它的行，见 [CACHE_GEN_BUMP_SQL]。
const CACHE_GEN: &str = "cache_gen";

/// 丢掉一个集合时它的缓存层代号抬一代、下限抬到同一代、记录数清零（`cache_log` 随带 `col` 的表删掉）。`collections` 的
/// 整数主键会被之后新绑的集合复用（没有 AUTOINCREMENT）：常驻的浏览会话按 (集合号, 代号) 认缓存（`cmd/browse.rs`），
/// 代号要是从头算起，复用这个号的新集合可能正好落在旧会话记的代号上、被当成没变。抬过下限的代号让一切旧会话整份重读。
pub(crate) const CACHE_GEN_BUMP_SQL: &str =
    "UPDATE cache_gen SET gen = gen + 1, floor = gen + 1, logged = 0 WHERE col = ?1";

/// 删 `srs_meta` 里一个集合的键：?1 = 正好是 `<前缀><col>` 的键，?2 = `<前缀><col>/` 开头的键——按主键的半开区间
/// `[?2, ?2 末尾的 `/` 换成 `0`)`（`/` 的下一个字符是 `0`），不写 `LIKE` / `substr(key, …)`（那样要全表扫）。
pub(crate) const META_DELETE_SQL: &str = "DELETE FROM srs_meta WHERE key = ?1 \
     OR (key >= ?2 AND key < substr(?2, 1, length(?2) - 1) || '0')";

/// [disposable] 执行的语句（执行计划测试用同一份）：?1 = col，?2 = 本机设备（16 字节），?3..?4 = 本机设备的主键区间。
/// 前四条是不读日志的「别人 / 发布过」判据（[CHEAP]），第五条读本机日志，放在 [Truth::library_fresh] 之后（非空集合
/// 在那里碰到第一条用户内容就停，不为找 `Join` 扫整份日志），第六条取本机身份。
pub(crate) const DISPOSABLE_SQL: [&str; 6] = [
    // 本机以外的设备（含只被点过名的）。
    "SELECT EXISTS(SELECT 1 FROM devs WHERE col = ?1 AND id != ?2)",
    // 本机以外的公钥、任何信任记录。
    "SELECT EXISTS(SELECT 1 FROM peers WHERE col = ?1 AND device != ?2) \
     OR EXISTS(SELECT 1 FROM trust WHERE col = ?1)",
    // 发布过 head / 转发过 / 立过位置的根或记过位置的加密（文件头「空集合」）。
    "SELECT EXISTS(SELECT 1 FROM loc_heads WHERE col = ?1) \
     OR EXISTS(SELECT 1 FROM relay_out WHERE col = ?1) \
     OR EXISTS(SELECT 1 FROM loc_state WHERE col = ?1)",
    // 已传水位（`outbox_ack`）：`gen4_out/<col>/` 开头的键（区间同 [META_DELETE_SQL]）。
    "SELECT EXISTS(SELECT 1 FROM srs_meta WHERE key >= ?6 AND key < substr(?6, 1, length(?6) - 1) || '0')",
    // 本机日志里的 `Join`（并入过别的集合）。
    "SELECT EXISTS(SELECT 1 FROM ops WHERE k BETWEEN ?3 AND ?4 AND kind = ?5)",
    // 有没有本机身份（缺 = 不是「本机身份写的」，不算空）。
    "SELECT device FROM self_ WHERE col = ?1",
];

/// [DISPOSABLE_SQL] 里不读日志的那几条。
const CHEAP: std::ops::Range<usize> = 0..4;

/// [DISPOSABLE_SQL] 里找本机日志 `Join` 的那条。
const JOINED: usize = 4;

/// 集合 [col] 是不是「空集合」（文件头）：可以在确认之后整个丢掉、改绑到别的集合。
pub fn disposable(t: &Truth<'_>, col: i64) -> Result<bool, String> {
    let conn = t.conn();
    let me: Option<Vec<u8>> = conn
        .prepare_cached(DISPOSABLE_SQL[5])
        .map_err(sql)?
        .query_row([col], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    let Some(me) = me else {
        return Ok(false);
    };
    // 有身份、日志里一条都没有（`devs` 里还没有本机）：给一个空区间，什么都没写过。
    let range = conn
        .prepare_cached("SELECT dev FROM devs WHERE col = ?1 AND id = ?2")
        .map_err(sql)?
        .query_row(params![col, me], |r| r.get::<_, i64>(0))
        .optional()
        .map_err(sql)?
        .map_or((0, -1), k_range);
    for q in &DISPOSABLE_SQL[CHEAP] {
        if hit(t, q, col, &me, range)? {
            return Ok(false);
        }
    }
    // 用户内容：与首次信任同一个判据（文件头「空集合」第二条）。`devs` 里只有本机（上面第一条），所以它看的就是本机日志。
    if !t.library_fresh(col)? {
        return Ok(false);
    }
    Ok(!hit(t, DISPOSABLE_SQL[JOINED], col, &me, range)?)
}

/// [DISPOSABLE_SQL] 的一条成立不成立（[range] = 本机设备的主键区间；没有日志时给一个空区间）。
fn hit(t: &Truth<'_>, q: &str, col: i64, me: &[u8], range: (i64, i64)) -> Result<bool, String> {
    let out_prefix = format!("gen4_out/{col}/");
    let mut stmt = t.conn().prepare_cached(q).map_err(sql)?;
    // 每条语句只绑它用到的参数（rusqlite 按语句里出现的最大编号要参数）。
    match stmt.parameter_count() {
        2 => stmt.query_row(params![col, me], |r| r.get(0)),
        5 => stmt.query_row(params![col, me, range.0, range.1, KIND_JOIN as i64], |r| {
            r.get(0)
        }),
        6 => stmt.query_row(
            params![col, me, range.0, range.1, KIND_JOIN as i64, out_prefix],
            |r| r.get(0),
        ),
        1 => stmt.query_row([col], |r| r.get(0)),
        n => return Err(format!("gen4 discard: unexpected parameter count {n}")),
    }
    .map_err(sql)
}

#[cfg(test)]
#[path = "discard_tests.rs"]
mod tests;
