//! 协议 4 的存储侧（设计 §2、§6.1）。还没有任何命令接到这里：现有的 `srs.db` 与协议 3 的内核照旧，这里是另一个文件、
//! 另一套表。
//!
//! - [legacy]：旧代读入器。把协议 3 的 srs.db 里的操作日志读出来、验链、逐条转译。只读。
//! - [legacy_export]：冻结的协议 3 导出流（`.fushisrs` 第 1 版，魔数 `FSRS2EXP`）读入器。只读。
//! - [schema]：新代库文件的表与打开方式。
//! - [files]：新代的文件名、换代锁（[files::GenLock]）与打开模式（[files::open_gen4]）。
//! - `pack`：操作体的本机存储编码（旧戳内部化、配置快照剪出、压缩），逐字节可逆。
//! - [truth]：真相层——每台设备一条日志（承袭槽 / 原生操作 / 空洞），槽的落库规则，待投递与分叉，原生日志的链。
//! - [import]：把一份协议 3 的库灌进真相层。
//! - [identity]：身份——绑定状态、并入（`Join`，改绑）、外来数据该怎么认（[identity::adopt_foreign]）、`join_ix`，G9-3。
//! - [native]：本机原生写入者（seq / 依赖 / HLC / 链，`Salts` 去重），G7-3a。
//! - [ingest]：一批落库之后收派生层（逐条维护 / 整个重建），本机写入、收段、导入共用。
//! - [receive]：收段——原生段 / 中继件 / 承袭段验过之后按因果落进真相层（原生的等待缓冲 `op_wait`），收尾用 [ingest]，G8-4。
//! - [sync_state]：同步运行时的本机状态——各位置的 head、转发记账（两段式删除）、旧根清单指纹，G8-4。
//! - [derive]：派生层的索引（实体、寄存器、日志、旧闭包）与 `rebuild_all`；冻结的旧判定从操作体读。
//! - [class]：读侧按别名类判定——寄存器、标签按别名类并起来再过冻结判据，内嵌 ID 归一（只读，没有调用方）。
//! - [cache]：缓存层——笔记 / 卡片缓存、逐卡重放、有效复习投影（统计列）。
//! - [weigh]：派生层的语义部分——标签 OR-Set、媒体绑定、彻底清除、被扣住的删除、设备信任。
//! - `compare`：协议 3 的投影与新代派生层逐类对拍（干跑与测试装置共用）。
//! - [dryrun]：真实库干跑（设计 §8 G4）：旧库只读 → 临时新库 → 重建 → 对拍报告；也是换代前版本里的预演自检（G4b）。

pub mod alias;
pub mod cache;
pub mod class;
pub(crate) mod compare;
pub mod derive;
pub mod digest;
pub mod dryrun;
pub mod files;
pub mod identity;
pub mod import;
pub mod ingest;
pub mod legacy;
pub mod legacy_export;
pub mod native;
pub(crate) mod pack;
#[cfg(test)]
pub(crate) mod parity;
pub mod receive;
pub mod schema;
pub mod sync_state;
pub mod truth;
pub mod weigh;
