//! 分段计时，只在冷启动探针的构建里（`RUSTFLAGS="--cfg srs_probe"`，见 sync2/bootstrap_probe.rs）生效：收段通道、
//! 重放、缓存刷新各段各花多少，探针结束时打印（[dump]）。别的构建里 [span] 是空壳（零大小、不取时钟），生产路径
//! 不多做任何事。
//!
//! 用法：`let _p = prof::span("fold.read");`，离开作用域时把这一段的耗时与次数记到这个名字下。名字用「阶段.子段」，
//! 同一阶段的子段互不嵌套时可以直接相加；嵌套的（外层含内层）在名字上看得出来（例如 `cache.notes` 含
//! `cache.notes.logs`）。

/// 一段计时。探针构建之外是零大小的空壳。
pub(crate) struct Span {
    #[cfg(srs_probe)]
    name: &'static str,
    #[cfg(srs_probe)]
    start: std::time::Instant,
}

#[cfg(srs_probe)]
static TOTALS: std::sync::Mutex<std::collections::BTreeMap<&'static str, (u128, u64)>> =
    std::sync::Mutex::new(std::collections::BTreeMap::new());

/// 开始一段计时，返回值离开作用域时记账。
#[cfg(srs_probe)]
pub(crate) fn span(name: &'static str) -> Span {
    Span {
        name,
        start: std::time::Instant::now(),
    }
}

/// 开始一段计时（探针构建之外不做任何事）。
#[cfg(not(srs_probe))]
#[inline(always)]
pub(crate) fn span(_name: &'static str) -> Span {
    Span {}
}

#[cfg(srs_probe)]
impl Drop for Span {
    fn drop(&mut self) {
        let ns = self.start.elapsed().as_nanos();
        if let Ok(mut totals) = TOTALS.lock() {
            let e = totals.entry(self.name).or_insert((0, 0));
            e.0 += ns;
            e.1 += 1;
        }
    }
}

/// 至今各段的累计（纳秒, 次数）快照（探针用：一条命令前后各取一次、相减，知道这条命令做的是哪一类事）。探针构建
/// 之外是空表。
#[cfg(test)]
pub(crate) fn totals() -> std::collections::BTreeMap<&'static str, (u128, u64)> {
    #[cfg(srs_probe)]
    {
        TOTALS.lock().unwrap().clone()
    }
    #[cfg(not(srs_probe))]
    {
        std::collections::BTreeMap::new()
    }
}

/// 打印至今各段的累计耗时与次数并清零（探针用；探针构建之外什么也不打印）。
#[cfg(test)]
pub(crate) fn dump() {
    #[cfg(srs_probe)]
    {
        let totals = std::mem::take(&mut *TOTALS.lock().unwrap());
        for (name, (ns, calls)) in totals {
            println!("PROF {name:<28} {:>8} ms {calls:>9} calls", ns / 1_000_000);
        }
    }
}
