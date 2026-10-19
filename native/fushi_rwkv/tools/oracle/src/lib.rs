// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! Golden-value oracle: compiles the upstream kuma3-anki-core `rslib/src/rwkv`
//! module **verbatim** (via `#[path]`, from a checkout in `./upstream`) with
//! tiny shims for the crate-level names it imports. Nothing numeric lives here.
#![allow(dead_code, unused_imports, unused_variables, unexpected_cfgs)]

pub mod card {
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum CardType {
        New = 0,
        Learn = 1,
        Review = 2,
        Relearn = 3,
    }
}

pub mod scheduler {
    pub mod rwkv {
        // Verbatim from rslib/src/scheduler/rwkv.rs:910 (workload simulation only).
        pub(crate) fn relative_overdueness(retrievability: f32, target_retention: f32) -> f32 {
            retrievability / target_retention.max(0.0001)
        }
    }
}

#[path = "../upstream/rslib/src/rwkv/mod.rs"]
pub mod rwkv;
