//! 协议 4 的存储侧（设计 §2、§6.1）。还没有任何命令接到这里：现有的 `srs.db` 与协议 3 的内核照旧，这里是另一个文件、
//! 另一套表。
//!
//! - [legacy]：旧代读入器。把协议 3 的 srs.db 里的操作日志读出来、验链、逐条转译。只读。
//! - [schema]：新代库文件的表与打开方式。
//! - `pack`：操作体的本机存储编码（旧戳内部化、配置快照剪出、压缩），逐字节可逆。
//! - [truth]：真相层——每台设备一条日志（承袭槽 / 原生操作 / 空洞），槽的落库规则，待投递与分叉，原生日志的链。
//! - [import]：把一份协议 3 的库灌进真相层。
//! - [derive]：派生层的索引（实体、寄存器、日志、旧闭包）与 `rebuild_all`；冻结的旧判定从操作体读。
//! - [cache]：缓存层——笔记 / 卡片缓存、逐卡重放、有效复习投影（统计列）。
//! - [weigh]：派生层的语义部分——标签 OR-Set、媒体绑定、彻底清除、被扣住的删除、设备信任。

pub mod alias;
pub mod cache;
pub mod derive;
pub mod digest;
pub mod import;
pub mod legacy;
pub(crate) mod pack;
#[cfg(test)]
pub(crate) mod parity;
pub mod schema;
pub mod truth;
pub mod weigh;
