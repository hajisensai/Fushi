//! 排序键（铁律 F）：卡片历史（history.rs）与字段寄存器（registers.rs）共用的唯一一份。
//!
//! 排序键 = (钳位后的物理时间, 计数器, HLC writerId, eventId)，钳位 = min(HLC 物理部分, S(e) + 10 分钟)；
//! 字符串按 **UTF-16 码元**比较（Dart `String.compareTo`），不是 Rust 默认的码点序。
//! 钳位只影响排序，不改事件本身；它保证的是「事件在排序里领先它被发布的时刻最多 10 分钟」，
//! 不是「领先真实发生时刻最多 10 分钟」（设计文档第六轮审查第 4 条）。

use std::cmp::Ordering;

/// 排序与 HLC 推进共用的容差（Dart `srsClockToleranceMs`）：S(e) 之后最多 10 分钟。
pub const CLOCK_TOLERANCE_MS: i64 = 10 * 60 * 1000;

/// Dart `String.compareTo`：按 UTF-16 码元比较。与码点序只在「增补平面字符 vs U+E000..U+FFFF」处不同。
pub fn cmp_utf16(a: &str, b: &str) -> Ordering {
    if a.is_ascii() && b.is_ascii() {
        return a.as_bytes().cmp(b.as_bytes());
    }
    a.encode_utf16().cmp(b.encode_utf16())
}

/// 钳位后的物理时间：S(e) 未知（只经备份 / 快照拿到、还没见到批次）时按原始 HLC。
pub fn sort_physical(physical: i64, server_time: Option<i64>) -> i64 {
    match server_time {
        Some(s) => physical.min(s.saturating_add(CLOCK_TOLERANCE_MS)),
        None => physical,
    }
}

/// 物理部分被钳位了（排序键早于事件自己的 HLC）：可证明时间有错的必要条件之一（优化器用）。
pub fn is_clamped(physical: i64, server_time: Option<i64>) -> bool {
    sort_physical(physical, server_time) < physical
}

/// 一个事件的排序键（借用事件里的串）。
#[derive(Debug, Clone, Copy)]
pub struct SortKey<'a> {
    pub physical: i64,
    pub counter: i64,
    pub writer: &'a str,
    pub event_id: &'a str,
}

impl<'a> SortKey<'a> {
    pub fn new(
        physical: i64,
        counter: i64,
        writer: &'a str,
        event_id: &'a str,
        server_time: Option<i64>,
    ) -> Self {
        SortKey {
            physical: sort_physical(physical, server_time),
            counter,
            writer,
            event_id,
        }
    }

    pub fn cmp(&self, other: &SortKey<'_>) -> Ordering {
        self.physical
            .cmp(&other.physical)
            .then(self.counter.cmp(&other.counter))
            .then_with(|| cmp_utf16(self.writer, other.writer))
            .then_with(|| cmp_utf16(self.event_id, other.event_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf16_order_differs_from_code_point_order() {
        // U+1D4E7 的高代理 0xD835 < U+FF21：UTF-16 序在前，码点序在后。
        assert_eq!(cmp_utf16("\u{1D4E7}", "\u{FF21}"), Ordering::Less);
        assert_eq!("\u{1D4E7}".cmp("\u{FF21}"), Ordering::Greater);
    }

    #[test]
    fn clamp_only_lowers() {
        assert_eq!(sort_physical(10, None), 10);
        assert_eq!(sort_physical(10_000_000, Some(0)), CLOCK_TOLERANCE_MS);
        assert_eq!(sort_physical(5, Some(0)), 5);
        assert!(is_clamped(CLOCK_TOLERANCE_MS + 1, Some(0)));
        assert!(!is_clamped(CLOCK_TOLERANCE_MS, Some(0)));
    }
}
