//! 测试二进制的全局分配器（一个二进制只能有一个，各模块共用）：按「当前线程」记
//!
//! - 期间最大的单次分配请求（含 `try_reserve` 的尝试）——证明畸形输入不会按声明值触发巨量分配；
//! - 期间活跃字节的峰值（只算本线程分配、本线程释放的）——核算单线程内核的工作集。
//!
//! 按线程记，测试并行跑互不干扰。

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

struct TrackingAlloc;

thread_local! {
    static MAX_REQUEST: Cell<usize> = const { Cell::new(0) };
    static LIVE: Cell<isize> = const { Cell::new(0) };
    static PEAK: Cell<isize> = const { Cell::new(0) };
}

fn grow(size: usize) {
    // try_with：线程析构阶段 TLS 已销毁时静默跳过。
    let _ = MAX_REQUEST.try_with(|m| m.set(m.get().max(size)));
    let _ = LIVE.try_with(|l| {
        let now = l.get() + size as isize;
        l.set(now);
        let _ = PEAK.try_with(|p| p.set(p.get().max(now)));
    });
}

fn shrink(size: usize) {
    let _ = LIVE.try_with(|l| l.set(l.get() - size as isize));
}

unsafe impl GlobalAlloc for TrackingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        grow(layout.size());
        System.alloc(layout)
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        grow(layout.size());
        System.alloc_zeroed(layout)
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let _ = MAX_REQUEST.try_with(|m| m.set(m.get().max(new_size)));
        let _ = LIVE.try_with(|l| {
            let now = l.get() + new_size as isize - layout.size() as isize;
            l.set(now);
            let _ = PEAK.try_with(|p| p.set(p.get().max(now)));
        });
        System.realloc(ptr, layout, new_size)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        shrink(layout.size());
        System.dealloc(ptr, layout)
    }
}

#[global_allocator]
static ALLOC: TrackingAlloc = TrackingAlloc;

/// 跑 `f`，返回它的结果与期间当前线程最大的单次分配请求。
pub(crate) fn max_request_during<T>(f: impl FnOnce() -> T) -> (T, usize) {
    MAX_REQUEST.with(|m| m.set(0));
    let v = f();
    (v, MAX_REQUEST.with(|m| m.get()))
}

/// 跑 `f`，返回它的结果与期间当前线程活跃字节相对起点的峰值（含返回值本身）。
pub(crate) fn peak_bytes_during<T>(f: impl FnOnce() -> T) -> (T, usize) {
    let base = LIVE.with(|l| l.get());
    PEAK.with(|p| p.set(base));
    let v = f();
    let peak = PEAK.with(|p| p.get());
    (v, (peak - base).max(0) as usize)
}
