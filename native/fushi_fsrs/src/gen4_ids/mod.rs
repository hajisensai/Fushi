//! 协议 4 的规范 ID 与别名规则（docs/specs/2026-11-11-srs-generation-break.md §5.2、§5.3；实现拆分 G3）。
//!
//! 还没有接线：这里只有纯函数，没有任何读写路径调用它。
//!
//! - [rules]：ID 规则表。规范 ID = 现有规则表（Dart `SrsIds`）去掉 profile uid 这个盐；带盐的旧规则留着，只用来验算
//!   存量 ID。
//! - [alias]：存量 ID → 规范 ID。存量 ID 不改写；按规则重算的哈希对得上才归到规范 ID，对不上的规范 ID 就是它自己。
//!
//! 规则只在这里一处。Dart 侧不加第二份实现：packages/fushi_engine/test/srs/srs_gen4_canonical_ids_golden_test.dart
//! 用现有 `SrsIds` 对同一个冻结向量文件（`golden_ids.json`）重算，本模块的测试也对着它重算。

pub mod alias;
pub mod rules;

/// 冻结的向量文件（由上面那个 Dart 测试生成）。
#[cfg(test)]
pub(crate) const GOLDEN: &str = include_str!("golden_ids.json");

#[cfg(test)]
mod probe;
#[cfg(test)]
mod tests;
