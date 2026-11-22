//! 协议 4 的存储侧（设计 §2、§6.1）。C ABI 的库句柄与 `ffsrs_store_sync2` 的命令已经接到这里（S1：[kernel] /
//! [dispatch]）；协议 3 的 `srs.db` 内核代码原地留着给协议 3 的测试与对拍装置，由 G7-6 删。
//!
//! - [legacy]：旧代读入器。把协议 3 的 srs.db 里的操作日志读出来、验链、逐条转译。只读。
//! - [legacy_export]：冻结的协议 3 导出流（`.fushisrs` 第 1 版，魔数 `FSRS2EXP`）读入器。只读。
//! - [schema]：新代库文件的表与打开方式。
//! - [files]：新代的文件名、换代锁（[files::GenLock]）与打开模式（[files::open_gen4]）。
//! - `pack`：操作体的本机存储编码（旧戳内部化、配置快照剪出、压缩），逐字节可逆。
//! - [truth]：真相层——每台设备一条日志（承袭槽 / 原生操作 / 空洞），槽的落库规则，待投递与分叉，原生日志的链。
//! - [import]：把一份协议 3 的库灌进真相层；导入 `.fushisrs` 第 2 版 / 第 1 版的内核流、旧备份读入（G11-2）。
//! - [export]：把一个集合的真相层写成 `.fushisrs` 第 2 版的内核流 `FSRS4EXP`（G11-2，没有调用方）。
//! - [identity]：身份——绑定状态、并入（`Join`，改绑）、外来数据该怎么认（[identity::adopt_foreign]）、`join_ix`，G9-3。
//! - [native]：本机原生写入者（seq / 依赖 / HLC / 链，`Salts` 去重），G7-3a。
//! - [ingest]：一批落库之后收派生层（逐条维护 / 整个重建），本机写入、收段、导入共用。
//! - [receive]：收段——原生段 / 中继件 / 承袭段验过之后按因果落进真相层（原生的等待缓冲 `op_wait`），收尾用 [ingest]，G8-4。
//! - [sync_state]：同步运行时的本机状态——各位置的 head、转发记账（两段式删除）、旧根清单指纹，G8-4。
//! - [inherit]：承袭上传——位置上缺的承袭区间切段补传，本机已传的段同号槽只降不升地原区间重写（D19 / D20），G8-5。
//! - [oldroot]：旧根捡漏与围栏——认位置的代（只有协议 1 旧根的明确拒绝，D21）、旧根清单变了列出要转译并入的旧段、
//!   重立围栏，G8-5（旧段的落库在 [receive] 的 `Receiver::legacy`）。
//! - [derive]：派生层的索引（实体、寄存器、日志、旧闭包）与 `rebuild_all`；冻结的旧判定从操作体读。
//! - [class]：读侧按别名类判定——寄存器、标签按别名类并起来再过冻结判据，内嵌 ID 归一（只读，没有调用方）。
//! - [cache]：缓存层——笔记 / 卡片缓存、逐卡重放、有效复习投影（统计列）。
//! - [media]：各位置媒体「在不在」的本机缓存 `media_at` 的读写、媒体清单（`crate::gen4::manifest`）的收与发、协议 3
//!   `sync2_media_at` 的播种（G8-3，没有调用方）。
//! - [weigh]：派生层的语义部分——标签 OR-Set、媒体绑定、彻底清除、被扣住的删除、设备信任。
//! - [fork]：本机身份分叉的检测（换身份本身是 `truth` 的 `rotate_identity`，本机身份表 `self_` 的读写也在那里）。
//! - [compact]：本机原生段的小段合并（分层合并的计划与重新切段、签名；不改表）。
//! - `compare`：协议 3 的投影与新代派生层逐类对拍（干跑与测试装置共用）。
//! - [cmd]：读写命令的新代实现（`read` / `read_lib` 的各个查询、`entity_views`、修改历史、写命令）。
//! - [kernel]：命令层的库句柄（C ABI 句柄表里放的就是它）：连接、常驻会话、写入代数；迁移的全局命令（S1）。
//! - [dispatch]：新代分发器——`ffsrs_store_sync2` 的每条命令接到 [cmd]，未接线 / 已删的给明确的错误（S1）。
//! - [local]：新代库里的本机状态行（修订号、纪元、校时状态；`srs_meta` 键，S1）。
//! - [carry]：迁移时带过去的本机状态（公钥与名字、暂扣、检查点、本机媒体、`media_at`、加密位置记忆、绑定状态、切点），
//!   预演与迁移共用。
//! - [migrate]：迁移编排（设计 §6.1、规划 §1.4 第 1–11 步，G7-2）：取锁 → 前提 → 临时文件里走 [dryrun] 的同一套阶段 →
//!   对拍全过才提交（改名）→ 原位封存旧库。还没有调用方。
//! - [dryrun]：真实库干跑（设计 §8 G4）：旧库只读 → 临时新库 → 重建 → 对拍报告；也是换代前版本里的预演自检（G4b）。

pub mod alias;
pub mod cache;
pub mod carry;
pub mod class;
pub mod cmd;
pub mod compact;
pub(crate) mod compare;
pub mod derive;
pub mod digest;
pub mod discard;
pub mod dispatch;
pub mod dryrun;
pub mod export;
pub mod files;
pub mod fork;
#[cfg(test)]
mod guards_tests;
#[cfg(any(test, feature = "id_audit"))]
pub(crate) mod id_audit;
pub mod identity;
pub mod import;
pub mod ingest;
pub mod inherit;
pub mod kernel;
pub mod legacy;
pub mod legacy_export;
pub mod local;
pub mod media;
pub mod migrate;
pub mod native;
pub mod oldroot;
pub(crate) mod pack;
#[cfg(test)]
pub(crate) mod parity;
pub(crate) mod prepare;
#[cfg(test)]
mod rebuild_scale_tests;
pub mod receive;
pub mod refresh;
pub mod retained;
pub mod schema;
pub(crate) mod scrub;
pub mod sync_state;
pub mod truth;
pub mod weigh;
