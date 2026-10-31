//! SRS 同步 v2 内核（docs/specs/2026-10-25-srs-sync-v2-design.md，实现计划同目录 `-plan.md`）。
//!
//! 复习是事实，不是状态：同步只交换不可变的操作，卡片调度状态永远是「全部复习事实按确定顺序重放」
//! 的纯函数。本模块是纯 Rust、不碰 SQLite 的那一层（编解码、因果、段协议、确定性 FSRS 与重放、合并）；
//! srs.db 上的持久化与投影在 `store::sync2`。

pub mod codec;
pub mod dvv;
pub mod fsrs_det;
pub mod hlc;
pub mod id;
pub mod keys;
pub mod media_seal;
pub mod op;
pub mod replay;
pub mod sched;
pub mod segment;
pub mod vv;
