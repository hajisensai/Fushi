//! 开机时钟：自本次开机以来经过的毫秒，**睡眠 / 休眠期间照走**，不受用户改系统时间影响。
//!
//! SRS 可信时间（packages/fushi_srs/lib/src/hlc.dart `SrsTrustedClock`）= 校时那一刻的服务器时间 + 之后
//! 这个时钟走过的量。它必须同时满足两条：
//! - 不受墙钟改动影响：校时之后用户把系统时间往前 / 往后拨，可信时间不跟着跳（所以不能用「墙钟 + 偏移」）；
//! - 深睡也计时：Dart `Stopwatch` 与 Rust `Instant` 在 Android / Linux 上是 CLOCK_MONOTONIC，在 Apple 上是
//!   CLOCK_UPTIME_RAW，都**不计睡眠**，手机睡一觉可信时间就落后睡掉的时长（BUG-3900）。
//!
//! 标准库给不出这样的时钟，按平台直接取：
//! - Linux / Android：`clock_gettime(CLOCK_BOOTTIME)`（= Android `SystemClock.elapsedRealtime`）；
//! - macOS / iOS：`clock_gettime(CLOCK_MONOTONIC)`——Darwin 的 CLOCK_MONOTONIC 基于 `mach_continuous_time`，
//!   睡眠期间照走（不计睡眠的是 CLOCK_UPTIME_RAW）；
//! - Windows：`GetTickCount64`（中断时间的毫秒数，含睡眠与休眠；不计睡眠的是 `QueryUnbiasedInterruptTime`）。
//!
//! 重启后从 0 重新计：跨进程的校时状态不能直接接着用，见 `SrsTrustedClock.restoreAnchor`。

/// 自本次开机以来的毫秒（含睡眠）。系统调用失败返回 None（实际不会发生）。
pub fn boot_time_ms() -> Option<i64> {
    imp::now_ms()
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod imp {
    pub(super) fn now_ms() -> Option<i64> {
        read(libc::CLOCK_BOOTTIME)
    }

    pub(super) fn read(clock: libc::clockid_t) -> Option<i64> {
        let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // SAFETY: ts 是本函数里的局部变量，clock_gettime 只写它。
        let rc = unsafe { libc::clock_gettime(clock, &mut ts) };
        (rc == 0).then(|| ts.tv_sec as i64 * 1000 + ts.tv_nsec as i64 / 1_000_000)
    }
}

#[cfg(target_vendor = "apple")]
mod imp {
    pub(super) fn now_ms() -> Option<i64> {
        let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // SAFETY: ts 是本函数里的局部变量，clock_gettime 只写它。
        let rc = unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
        (rc == 0).then(|| ts.tv_sec as i64 * 1000 + ts.tv_nsec as i64 / 1_000_000)
    }
}

#[cfg(windows)]
mod imp {
    #[link(name = "kernel32")]
    extern "system" {
        fn GetTickCount64() -> u64;
    }

    pub(super) fn now_ms() -> Option<i64> {
        // SAFETY: 无参数、无副作用的系统调用。
        i64::try_from(unsafe { GetTickCount64() }).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn advances_with_elapsed_time_and_never_goes_back() {
        let a = boot_time_ms().expect("boot clock");
        assert!(a >= 0);
        let started = Instant::now();
        std::thread::sleep(Duration::from_millis(120));
        let b = boot_time_ms().expect("boot clock");
        let elapsed = started.elapsed().as_millis() as i64;
        assert!(b >= a, "boot clock went backwards: {a} -> {b}");
        // Windows GetTickCount64 的分辨率约 16 ms：两边各留一格。
        assert!(b - a >= elapsed - 40, "boot clock advanced {} ms, expected ~{elapsed}", b - a);
        assert!(b - a <= elapsed + 40, "boot clock advanced {} ms, expected ~{elapsed}", b - a);
    }

    /// 开机时钟 ≥ 不计睡眠的单调时钟（两者同一起点：开机；前者多出睡眠时长）。
    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    fn boottime_is_at_least_monotonic() {
        let mono = imp::read(libc::CLOCK_MONOTONIC).unwrap();
        let boot = boot_time_ms().unwrap();
        assert!(boot >= mono);
    }
}
