//! 混合逻辑时钟（设计 §3.2）。
//!
//! `hlc = (wall_ms, logical, device)`，全序可比。只用于两件事：同一寄存器上**并发**写的决胜（因果覆盖
//! 由上下文判定，HLC 不参与）、重放与列表的稳定排序。复习的调度时刻另存真实墙钟（`reviewed_at`）。
//!
//! 时钟快的设备不会「永远赢」：本机推进只认 `max(本机墙钟, 已见的、不超前的最大 wall)`；远端 wall
//! 超出本机墙钟 [MAX_AHEAD_MS] 的操作照常收下并打标（[Observed::ahead]），但不把本机时钟拽过去。
//! 这不破坏因果：因果覆盖看上下文，不看 HLC。

use std::cmp::Ordering;

use super::codec::{DResult, Reader, Writer};
use super::id::Id;

/// 远端时钟超前多少算异常（打标告警）。
pub const MAX_AHEAD_MS: i64 = 24 * 60 * 60 * 1000;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub struct Hlc {
    pub wall: i64,
    pub logical: u32,
    pub device: Id,
}

impl Ord for Hlc {
    fn cmp(&self, o: &Self) -> Ordering {
        self.wall
            .cmp(&o.wall)
            .then(self.logical.cmp(&o.logical))
            .then(self.device.cmp(&o.device))
    }
}

impl PartialOrd for Hlc {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}

impl Hlc {
    /// 编码时省掉 device（段里每条操作的作者就是段的设备）。
    pub fn write_time(&self, w: &mut Writer) {
        w.iv(self.wall);
        w.uv(u64::from(self.logical));
    }

    pub fn read_time(r: &mut Reader<'_>, device: Id) -> DResult<Hlc> {
        let wall = r.iv()?;
        let logical = u32::try_from(r.uv()?).map_err(|_| super::codec::DecodeError("hlc logical"))?;
        Ok(Hlc { wall, logical, device })
    }
}

/// 本机时钟状态。
#[derive(Clone, Copy, Debug)]
pub struct Clock {
    pub device: Id,
    pub last: Hlc,
}

/// 收到远端时间戳的结论。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Observed {
    /// 远端 wall 超出本机墙钟 [MAX_AHEAD_MS]：收下、打标，不推进本机时钟。
    pub ahead: bool,
}

impl Clock {
    pub fn new(device: Id) -> Self {
        Clock { device, last: Hlc { wall: 0, logical: 0, device } }
    }

    /// 发出一条本机操作。
    pub fn tick(&mut self, now_ms: i64) -> Hlc {
        let next = if now_ms > self.last.wall {
            Hlc { wall: now_ms, logical: 0, device: self.device }
        } else {
            Hlc { wall: self.last.wall, logical: self.last.logical.saturating_add(1), device: self.device }
        };
        self.last = next;
        next
    }

    /// 收到远端操作：`max(local, remote) + 1`，但不追超前过多的远端。
    pub fn observe(&mut self, remote: Hlc, now_ms: i64) -> Observed {
        if remote.wall.saturating_sub(now_ms) > MAX_AHEAD_MS {
            return Observed { ahead: true };
        }
        let wall = now_ms.max(self.last.wall).max(remote.wall);
        let logical = if wall == self.last.wall && wall == remote.wall {
            self.last.logical.max(remote.logical).saturating_add(1)
        } else if wall == self.last.wall {
            self.last.logical.saturating_add(1)
        } else if wall == remote.wall {
            remote.logical.saturating_add(1)
        } else {
            0
        };
        self.last = Hlc { wall, logical, device: self.device };
        Observed { ahead: false }
    }

    /// 收到远端操作（落库用的形式）：本机时钟取 `max(local, remote)`，下一次 [Self::tick] 自然比它大（等价于
    /// [Self::observe] 的「+1」推迟到发出时）。与 [Self::observe] 不同，它幂等、可结合：同一批远端操作不论分几批、
    /// 按什么顺序吸收，结果都相同——收段按任意段边界切批时，本机之后发出的操作逐字节不变。
    pub fn absorb(&mut self, remote: Hlc, now_ms: i64) -> Observed {
        if remote.wall.saturating_sub(now_ms) > MAX_AHEAD_MS {
            return Observed { ahead: true };
        }
        if (remote.wall, remote.logical) > (self.last.wall, self.last.logical) {
            self.last = Hlc { wall: remote.wall, logical: remote.logical, device: self.device };
        }
        Observed { ahead: false }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tick_is_strictly_increasing_even_when_wall_clock_goes_back() {
        let mut c = Clock::new(Id([1; 16]));
        let a = c.tick(1000);
        let b = c.tick(900);
        let d = c.tick(1000);
        assert!(a < b && b < d);
    }

    #[test]
    fn observe_follows_causality_but_not_a_clock_far_in_the_future() {
        let mut c = Clock::new(Id([1; 16]));
        c.tick(1000);
        let remote = Hlc { wall: 5000, logical: 7, device: Id([2; 16]) };
        assert_eq!(c.observe(remote, 1000), Observed { ahead: false });
        let next = c.tick(1000);
        assert!(next > remote);

        let future = Hlc { wall: 1000 + MAX_AHEAD_MS + 1, logical: 0, device: Id([2; 16]) };
        assert_eq!(c.observe(future, 1000), Observed { ahead: true });
        assert!(c.tick(1000) < future);
    }

    #[test]
    fn absorb_is_idempotent_and_the_next_tick_follows_the_remote() {
        let remote = Hlc { wall: 5000, logical: 7, device: Id([2; 16]) };
        let mut once = Clock::new(Id([1; 16]));
        once.absorb(remote, 1000);
        let mut twice = Clock::new(Id([1; 16]));
        twice.absorb(Hlc { wall: 4000, ..remote }, 1000);
        twice.absorb(remote, 1000);
        twice.absorb(remote, 1000);
        assert_eq!(once.last, twice.last);
        assert!(once.tick(1000) > remote);
        let future = Hlc { wall: 1000 + MAX_AHEAD_MS + 1, logical: 0, device: Id([2; 16]) };
        assert_eq!(twice.absorb(future, 1000), Observed { ahead: true });
        assert!(twice.tick(1000) < future);
    }
}
