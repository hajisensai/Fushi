//! 写连接页缓存的上限按本机可用内存自适应：内存紧了往下调。
//!
//! 上限 = 可用内存的 1/[AVAIL_SHARE]，夹在 [MIN_KIB]..=[MAX_KIB]。取写连接时至多每 [RECHECK] 重算一次，调低时
//! SQLite 当场把超出新上限的页还掉；查不到可用内存（不支持的平台）用 [MAX_KIB]，与以前的固定值相同。
//!
//! 为什么上限不往上放（2026-11-06 实测，store/sync2/import_apply_bench.rs，3.6 万卡 × 38 条、约 1 GB 的库，交错两轮）：
//! 64 MB 每条 74.1 / 73.5 µs，256 MB 71.0 / 77.6 µs，256 MB 且批间留着页缓存 76.3 / 82.4 µs——放大没有更快，留得多
//! 反而更慢（原因未证实；推测是 mmap 已经把读页交给系统文件缓存，私有页缓存大了只多出管理与淘汰开销）。真正稳定见效的是
//! 批量写入期间批间不收回页缓存（64 MB：69.7 / 70.6 µs，约 −5%，[super::SrsCore::set_bulk_holds_cache]）。

use std::time::{Duration, Instant};

/// 上限占可用内存的份数。
const AVAIL_SHARE: u64 = 8;
pub(crate) const MIN_KIB: i64 = 16 * 1024;
/// 上限（也是查不到可用内存时的值，与读连接相同）。
pub(crate) const MAX_KIB: i64 = 64 * 1024;
/// 两次重算之间至少隔多久（取写连接很频繁，读 `/proc/meminfo` / 系统调用不每次做）。
pub(crate) const RECHECK: Duration = Duration::from_secs(10);

/// 可用内存 [avail]（字节，None = 查不到）对应的写连接页缓存上限（KiB，`PRAGMA cache_size = -n` 的 n）。
pub(crate) fn writer_cache_kib(avail: Option<u64>) -> i64 {
    let Some(avail) = avail else {
        return MAX_KIB;
    };
    i64::try_from(avail / AVAIL_SHARE / 1024)
        .unwrap_or(i64::MAX)
        .clamp(MIN_KIB, MAX_KIB)
}

/// 写连接页缓存上限的当前设定与上次重算时刻（[super::SrsCore] 持有，写连接锁内读写）。
pub(crate) struct WriterCache {
    pub kib: i64,
    pub checked: Option<Instant>,
}

impl WriterCache {
    pub(crate) fn new() -> Self {
        Self {
            kib: MAX_KIB,
            checked: None,
        }
    }

    /// 到了重算时刻就按此刻的可用内存重算，返回要设的新上限（与现值相同 / 还没到时刻 = None）。
    pub(crate) fn due(&mut self, now: Instant, avail: impl FnOnce() -> Option<u64>) -> Option<i64> {
        if self
            .checked
            .is_some_and(|t| now.duration_since(t) < RECHECK)
        {
            return None;
        }
        self.checked = Some(now);
        let kib = writer_cache_kib(avail());
        (kib != self.kib).then(|| {
            self.kib = kib;
            kib
        })
    }
}

/// 本机此刻的可用物理内存（字节）。
#[cfg(windows)]
pub(crate) fn available_bytes() -> Option<u64> {
    #[repr(C)]
    struct MemoryStatusEx {
        length: u32,
        memory_load: u32,
        total_phys: u64,
        avail_phys: u64,
        total_page_file: u64,
        avail_page_file: u64,
        total_virtual: u64,
        avail_virtual: u64,
        avail_extended_virtual: u64,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GlobalMemoryStatusEx(buffer: *mut MemoryStatusEx) -> i32;
    }
    let mut s = MemoryStatusEx {
        length: std::mem::size_of::<MemoryStatusEx>() as u32,
        memory_load: 0,
        total_phys: 0,
        avail_phys: 0,
        total_page_file: 0,
        avail_page_file: 0,
        total_virtual: 0,
        avail_virtual: 0,
        avail_extended_virtual: 0,
    };
    // SAFETY: 结构体按 MEMORYSTATUSEX 布局、dwLength 已填，只写这块栈内存。
    let ok = unsafe { GlobalMemoryStatusEx(&mut s) };
    (ok != 0).then_some(s.avail_phys)
}

/// 本机此刻的可用物理内存（字节）：`MemAvailable`（内核估计的不换页就能拿到的内存，含可回收的文件缓存）。
#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn available_bytes() -> Option<u64> {
    let s = std::fs::read_to_string("/proc/meminfo").ok()?;
    parse_meminfo(&s)
}

/// `/proc/meminfo` 里 `MemAvailable:  123456 kB` 那一行（字节）。
#[cfg_attr(not(any(target_os = "linux", target_os = "android")), allow(dead_code))]
fn parse_meminfo(s: &str) -> Option<u64> {
    let line = s.lines().find(|l| l.starts_with("MemAvailable:"))?;
    let kb: u64 = line
        .trim_start_matches("MemAvailable:")
        .trim()
        .trim_end_matches("kB")
        .trim()
        .parse()
        .ok()?;
    Some(kb * 1024)
}

/// 本机此刻的可用内存（字节）：本进程在被系统终止前还能再分配多少（iOS 13+ 的 `os_proc_available_memory`，
/// 前台 app 的额度，不是整机空闲）。
#[cfg(target_os = "ios")]
pub(crate) fn available_bytes() -> Option<u64> {
    unsafe extern "C" {
        fn os_proc_available_memory() -> usize;
    }
    // SAFETY: 无参数的系统查询。
    let n = unsafe { os_proc_available_memory() };
    (n > 0).then_some(n as u64)
}

/// macOS：物理内存的 1/4 当作可用（有内存压缩与交换，桌面上页缓存上限不是瓶颈；精确的空闲页统计要走 mach 接口）。
#[cfg(target_os = "macos")]
pub(crate) fn available_bytes() -> Option<u64> {
    let mut total: u64 = 0;
    let mut len = std::mem::size_of::<u64>();
    // SAFETY: 名字以 NUL 结尾，输出缓冲是一个 u64、长度如实给出。
    let rc = unsafe {
        libc::sysctlbyname(
            c"hw.memsize".as_ptr(),
            (&mut total as *mut u64).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    (rc == 0 && total > 0).then_some(total / 4)
}

#[cfg(not(any(
    windows,
    target_os = "linux",
    target_os = "android",
    target_os = "ios",
    target_os = "macos"
)))]
pub(crate) fn available_bytes() -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const GIB: u64 = 1 << 30;

    #[test]
    fn cap_follows_available_memory_within_bounds() {
        assert_eq!(writer_cache_kib(None), MAX_KIB);
        assert_eq!(writer_cache_kib(Some(8 * GIB)), MAX_KIB);
        assert_eq!(writer_cache_kib(Some(256 << 20)), 32 * 1024);
        assert_eq!(writer_cache_kib(Some(64 << 20)), MIN_KIB);
        assert_eq!(writer_cache_kib(Some(0)), MIN_KIB);
    }

    #[test]
    fn recheck_is_throttled_and_only_reports_changes() {
        let mut w = WriterCache::new();
        let t0 = Instant::now();
        // 内存充足：与起始值相同，不报。
        assert_eq!(w.due(t0, || Some(8 * GIB)), None);
        // 还没到重算时刻：内存掉了也不查。
        assert_eq!(
            w.due(t0 + Duration::from_secs(1), || panic!("not due")),
            None
        );
        // 到了：内存紧了就调低；没变就不报；宽裕了再调回。
        assert_eq!(w.due(t0 + RECHECK, || Some(256 << 20)), Some(32 * 1024));
        assert_eq!(w.due(t0 + RECHECK * 2, || Some(256 << 20)), None);
        assert_eq!(w.due(t0 + RECHECK * 3, || Some(8 * GIB)), Some(MAX_KIB));
    }

    #[test]
    fn meminfo_parses_mem_available() {
        let s = "MemTotal:       16000000 kB\nMemFree:         1000000 kB\nMemAvailable:    4000000 kB\n";
        assert_eq!(parse_meminfo(s), Some(4_000_000 * 1024));
        assert_eq!(parse_meminfo("MemTotal: 1 kB\n"), None);
    }

    fn cache_used(c: &rusqlite::Connection) -> i32 {
        let (mut used, mut high) = (0, 0);
        // SAFETY: 测试独占这条连接，只读一项统计。
        unsafe {
            rusqlite::ffi::sqlite3_db_status(
                c.handle(),
                rusqlite::ffi::SQLITE_DBSTATUS_CACHE_USED,
                &mut used,
                &mut high,
                0,
            )
        };
        used
    }

    /// 写连接按可用内存设上限；批量写入期间命令之间留着页缓存，结束后下一次放回照常收回。
    #[test]
    fn writer_uses_the_adaptive_cap_and_bulk_writes_keep_the_cache() {
        let dir = crate::store::sync2::tests::tempdir::new("mem-budget");
        let core = crate::store::SrsCore::open(&dir.0.join("srs.db")).unwrap();
        // 上限由核心在打开时按当时的可用内存算出；这里只认核心自己的值（不再单独读宿主内存），
        // 并确认它落在 [MIN_KIB, MAX_KIB] 内。换算本身由纯函数测试覆盖。
        let want = core.writer_cache_kib();
        assert!((MIN_KIB..=MAX_KIB).contains(&want), "{want}");
        {
            let w = core.writer().unwrap();
            let n: i64 = w.query_row("PRAGMA cache_size", [], |r| r.get(0)).unwrap();
            assert_eq!(n, -want);
            assert_eq!(core.writer_cache_kib(), want);
        }
        // 约 24 MB 的表：整表读一遍，页缓存远超命令之间的收回线（8 MB）。
        let fill = |core: &crate::store::SrsCore| {
            let w = core.writer().unwrap();
            w.execute_batch(
                "CREATE TABLE IF NOT EXISTS t (x BLOB); \
                 WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 6000) \
                 INSERT INTO t SELECT randomblob(4000) FROM n; \
                 SELECT sum(length(x)) FROM t;",
            )
            .unwrap();
        };
        core.set_bulk_holds_cache(true);
        fill(&core);
        // 上限最低 MIN_KIB（16 MB）> 收回线 8 MB，24 MB 的表必然把缓存撑过收回线，与宿主内存无关。
        assert!(
            cache_used(&core.writer().unwrap()) > super::super::IDLE_CACHE_BYTES,
            "bulk writes keep the cache"
        );
        core.set_bulk_holds_cache(false);
        drop(core.writer().unwrap());
        assert!(cache_used(&core.writer().unwrap()) <= super::super::IDLE_CACHE_BYTES);
        fill(&core);
        assert!(
            cache_used(&core.writer().unwrap()) <= super::super::IDLE_CACHE_BYTES,
            "trimmed between commands"
        );
    }

    /// 本机平台实现取得到可用内存（CI 跑的 Windows / Linux / macOS 都支持）。
    #[test]
    fn available_bytes_reads_the_real_machine() {
        let n = available_bytes().expect("available memory on this platform");
        assert!(n > 16 << 20, "{n}");
    }
}
