//! 新代库文件的表（设计 §2.1、§2.2）。新代是**另一个文件**：这里不碰协议 3 的 `srs.db`，也不认它的任何一张表。
//!
//! 三类表：
//!
//! - **真相**：`ops` / `op_alias` / `op_voids`（每台设备一条从 1 起连续的日志，一个 seq 恰好落在三张表之一）、
//!   它们引用的内部化表 `op_deps` / `writers` / `snapshots`、原生日志的链值 `log_marks`、还没接上前缀的 `op_pending`、
//!   分叉的另一支 `op_forks`。本机不可再生。
//! - **派生**：索引与缓存。全部能从真相与本机状态重建（`derive.rs`）。索引：`ent_ix` / `reg_ix` / `log_ix`（带 `log_id`
//!   索引）/ `closure_ix`；语义层（`weigh.rs`）：`tag_ix`（标签 OR-Set 与顺序提示）、`media_ix`（媒体名 → 内容）、
//!   `purge_ix`（彻底清除）、`ent_ops`（实体 → 碰过它、别的索引里查不到的操作）、`hold_ix`（被并发改动扣住的删除）。
//!   盐与别名（`alias.rs`）：`salt_ix`（带盐的操作）、`alias_ix`（出现过的 ID → 规范 ID）、`alias_writer_ix`（改了名的
//!   旧写入者 → 最初的写入者）；身份（`identity.rs`）：`join_ix`（本集合日志里的并入操作 `Join`：被并入的集合与它的
//!   位置目录名；盐另在 `salt_ix`）；语义摘要（`digest.rs`）：`dg_ix`（每个实体一行）、`dg_dirty`（等重算的实体，静止时为空；
//!   由 `reg_ix` / `tag_ix` / `log_ix` / `ent_ix` / `media_ix` 上的触发器记）。
//!   缓存层（`cache.rs`）：`notes` / `cards`（出卡、浏览读的缓存，列同协议 3 的两张缓存表）、`stats`（有效复习投影）。
//! - **本机状态**：`collections`（profile ↔ 集合的绑定，设计 §5.1；`state` / `via` / `at` 是绑定状态，协议 3
//!   `srs_meta` 里 `srs_collection_bound/<uid>` 的落点，由身份接线 G9-3 读写）、`devs`（设备 ↔ 小整数下标；`kind` 空 = 只被别的操作
//!   点过名、还没见过它的日志，0 = 原生日志，1 = 承袭日志；`src` = 承袭日志的来源集合；`tail` = 原生日志末尾的链值）、
//!   `trust`（还没信任的设备：`state` 1 = 待确认，2 = 已拒绝；没有行 = 可信。纯本机，不同步，协议 3 的 `sync2_trust`）。
//!   `derive_cfg`（派生层的输入里只有宿主知道的那部分，按名字存文本：内置笔记类型表、缓存配置；`truth.rs`）。
//!   迁移时从协议 3 灌过来的其余本机状态（[LOCAL]，规划 §1.3）：`self_`（本机身份：设备 ID、签名钥匙种子、HLC、换身份前
//!   的上一个身份 `prev_*` 三列）、`peers`（各设备的公钥、名字与扩展信息，`sync2_devices` 里本机要留的那部分；
//!   [super::truth::Truth::device_key] / [super::truth::Truth::set_peer]）、`held` / `checkpoints` / `media_local`（照搬对应的
//!   `sync2_*` 表，`profile_uid` 换成 `col`）、`media_at`（各位置媒体在 / 不在，按内容哈希）、`loc_state`（各位置的加密
//!   记忆：BUG-4299 的 `location_seal`）。除 `peers` 外这一版只建表，读写 API 由各自的 PR 加（G7-2 / G8-3 / G8-4 / G8-6）。
//!   同步运行时的本机状态（[SYNC]，G8-4，不迁移、从头对账）：`loc_heads`（各位置上各设备最新的 head）、`op_wait`（原生
//!   操作的因果等待缓冲）、`relay_out`（本机转发到各位置的文件与两段式删除）、`oldroot_fp`（各位置旧根的清单指纹）；
//!   读写 API 在 `sync_state.rs`，收段在 `receive.rs`。
//!   媒体清单（G8-3，`media.rs`）另有两张不迁移的进度表：`media_seen`（各作者的清单收到了哪几代）、`media_listed`（哪些媒体
//!   目录有人完整列举过）；`media_at` 多一列 `pend`（还没随本机清单发出）。
//!
//! 各列的取值见 `truth.rs`（落库规则）与 `pack.rs`（操作体的存储编码）。`writers.name` 存的是名字的紧凑字节形
//! （`gen4::name`：一个文本只有一种字节形，所以按字节唯一就是按名字唯一）。
//!
//! 操作的主键是一个整数 `k = dev << 40 | seq`（[opk]）：`dev` 是 `devs` 的下标，全库唯一、自带所属集合，所以按操作
//! 寻址的表不再另存集合号；rowid 表的点读与顺序扫都是一次 B 树下降，行里不重复存键。
//!
//! `srs_meta(key, value)` 与文本形式的 `schema` 照旧（设计 §6.1 末）：协议 3 的内核把它读成整数、比自己大就拒绝打开，
//! 所以新代文件即使被旧版本当成它的库打开，也只会报错、不会被从头建表。另外建库时在文件头写 `PRAGMA application_id`
//! = [APPLICATION_ID] 做正向识别（D7）：[check_kind] 只认带这个魔数、`schema` 正好是 [SCHEMA] 的文件；协议 3 的封存值
//! （`crate::store::schema::SEALED_SCHEMA` = 39999）与一切小于 [GEN_FLOOR] 的值都明确拒绝。

use std::path::Path;

use rusqlite::Connection;

/// 新代库的 schema 号。只要求远大于协议 3 的任何一个 schema 号（最后一个是 29）；万位是代，低位是这一代里的存储版本。
///
/// G7-1 起 `40006`（本机状态表、`collections` 的绑定状态列、`application_id`）；G9-3 起 `40007`（派生表 `join_ix`）；
/// G8-4 起 `40008`（同步运行时的本机状态 [SYNC]）；G8-3 起 `40009`（`media_at.pend`、`media_seen`、`media_listed`、
/// `media_gen`）；G9-2 起 `40010`（缓存层按规范 ID 建后，别名变了要按牌组 / 模板找回引用它的行：`notes_deck`、
/// `cards_deck`、`cards_template` 三个索引）；G7-4 起 `40011`（读命令 `cmd/reads.rs` 的查词热路径与待裁决计数：
/// `notes_term`、`notes_pending` 两个索引，协议 3 缓存表上都有）；G7-4b 起 `40014`（AnkiConnect 数字 id 反查
/// `cmd/columns.rs` 的 `anki_resolve` / `anki_notes_info`：`notes_anki`、`cards_anki` 两个索引，协议 3 v13 的
/// `idx_srs_*_cache_anki_id`；号段 40012 / 40013 预分配给同批别的 PR）；G7-4c 起 `40015`（出卡读命令 `cmd/study.rs`：
/// `cards_new_position`、`cards_new_freq`、`cards_learning`、`cards_review_due`、`cards_tally` 五个部分索引与
/// `notes_source`，协议 3 v9 / v25 的同名索引）；G7-4d 起 `40016`（浏览读命令 `cmd/browse.rs`：`anki_dupes` 按查重
/// 规范形查的 `notes_dupe` 索引——协议 3 v15 的 `idx_srs_notes_cache_dupe`——与常驻浏览会话按代号失效用的缓存层
/// 变更记录 `cache_gen` / `cache_log`，`cache.rs` 文件头「变更记录」）；G7-4e 起 `40017`（还原点列表 `cmd/center.rs`
/// `checkpoints`：真相表 `ops` 上只收种类 6（`Checkpoint`）的部分索引 `ops_checkpoint`，按设备主键区间读还原点、
/// 不扫日志）；G7-4f 起 `40018`（RWKV 对齐的日志指纹与尾巴、回放扫描 `cmd/training.rs`：本机落库序 `log_seq` 与它的
/// 唯一索引 `log_seq_k`——协议 3 按日志表 rowid（本机落库序）数行、取 rowid 之后的新行；新代的操作主键是
/// 「设备下标 × 2^40 + seq」，不随落库单调，晚到的低下标设备的日志会落在游标之前）；G7-4g 起 `40019`
/// （AnkiConnect 数字 id 的成员反查表 `anki_members` 与它按笔记维护用的 `anki_members_note`——`cmd/columns.rs`
/// 按号点查，不再扫别名表逐个算号，`cache.rs` 文件头「表」；`entity_count {kind, limit}` 按种类数到 `limit` 就停用的
/// `ent_ix` 部分索引 `ent_kind`，`cmd/reads.rs` `each_class`）；G8-7b 起 `40021`（转发要的作者段原文 `relay_segs`，
/// [SYNC]，`cmd/sync_relay.rs`；没有显式索引，[PLANNER_STATS] 不变；40020 预分配给同批别的 PR）；第五波 G9 身份收尾起
/// `40023`（实体归属闸 `cmd/writes_owner.rs` 按 ID 跨集合查：`ent_ix` 的 `ent_id`、`alias_ix` 的 `alias_canon_any`、
/// 缓存层 `cards` 的 `cards_id` 三个索引；40022 预分配给同批别的 PR）；第五波 K2 根治起 `40024`（重切的材料
/// `relay_auth` / `relay_stubs`，[SYNC]，`sync_state.rs`；主键点查与主键前缀，没有显式索引，[PLANNER_STATS] 不变）；
/// 第六波转发收尾起 `40026`（重切件的停放 `relay_park`，[SYNC]，`cmd/sync_park.rs`：读者记下一个位置上的重切件在等
/// 哪条 Purge / 哪台设备的信任变化，只在那件事发生时再拉；主键点查与主键前缀，没有显式索引，[PLANNER_STATS] 不变；
/// 40025 分给同批别的 PR、最后没用）；第六波合流起 `40027`（`40026` 的形状再加 develop 上 G8-3 修复的 `media_seen`
/// 按代号一行的集合、主键多一列 `gen`——那次修复在 develop 上单独用了 `40020`，与本线 40020 的预分配撞号，合流后
/// 两边的表合起来才是终态，另起新号，不复用任何一边进过构建的号）。
/// 整批推送前每个改表的 PR 各自用分到的号。
pub const SCHEMA: i64 = 40_027;

/// 新代的号段从这里起：`schema` 小于它的都不是新代库（协议 3 的 1～29 与封存值 39999）。
pub const GEN_FLOOR: i64 = 40_000;

/// 新代文件头里的 `PRAGMA application_id`（大端 ASCII `FSR4`）。建库时写；打开时不等就拒绝。
pub const APPLICATION_ID: i32 = 0x4653_5234;

const SEQ_BITS: u32 = 40;
const SEQ_MASK: i64 = (1 << SEQ_BITS) - 1;
const DEV_MAX: i64 = 1 << 22;

/// `(设备下标, seq)` → 操作的主键。
pub(crate) fn opk(dev: i64, seq: u64) -> Result<i64, String> {
    if dev <= 0 || dev >= DEV_MAX || seq == 0 || seq > SEQ_MASK as u64 {
        return Err(format!("gen4 store: op key out of range ({dev}, {seq})"));
    }
    Ok((dev << SEQ_BITS) | seq as i64)
}

pub(crate) fn k_dev(k: i64) -> i64 {
    k >> SEQ_BITS
}

pub(crate) fn k_seq(k: i64) -> u64 {
    (k & SEQ_MASK) as u64
}

/// 一台设备的主键区间 `[lo, hi]`。
pub(crate) fn k_range(dev: i64) -> (i64, i64) {
    (dev << SEQ_BITS, (dev << SEQ_BITS) | SEQ_MASK)
}

pub(crate) fn sql<E: std::fmt::Display>(e: E) -> String {
    format!("gen4 store: {e}")
}

const TRUTH: &str = "
CREATE TABLE IF NOT EXISTS collections (
  col INTEGER PRIMARY KEY,
  profile_uid TEXT NOT NULL UNIQUE,
  collection BLOB NOT NULL UNIQUE,
  dir TEXT NOT NULL,
  salts TEXT NOT NULL,
  state INTEGER,
  via TEXT,
  at INTEGER
);
CREATE TABLE IF NOT EXISTS devs (
  dev INTEGER PRIMARY KEY,
  col INTEGER NOT NULL,
  id BLOB NOT NULL,
  kind INTEGER,
  src BLOB,
  tail BLOB,
  UNIQUE (col, id)
);
CREATE TABLE IF NOT EXISTS trust (
  col INTEGER NOT NULL,
  device BLOB NOT NULL,
  state INTEGER NOT NULL,
  since INTEGER NOT NULL,
  PRIMARY KEY (col, device)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS derive_cfg (
  col INTEGER NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (col, key)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS ops (
  k INTEGER PRIMARY KEY,
  wall INTEGER NOT NULL,
  logical INTEGER NOT NULL,
  deps INTEGER NOT NULL,
  kind INTEGER NOT NULL,
  fmt INTEGER NOT NULL,
  flags INTEGER NOT NULL,
  body BLOB NOT NULL,
  aux BLOB,
  fp BLOB
);
CREATE INDEX IF NOT EXISTS ops_checkpoint ON ops (k) WHERE kind = 6;
CREATE TABLE IF NOT EXISTS op_alias (
  k INTEGER PRIMARY KEY,
  kind INTEGER NOT NULL,
  wall INTEGER NOT NULL,
  logical INTEGER NOT NULL,
  of_dev INTEGER NOT NULL,
  of_seq INTEGER NOT NULL,
  flags INTEGER NOT NULL,
  stamp BLOB,
  fp BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS op_voids (
  k INTEGER PRIMARY KEY,
  n INTEGER NOT NULL,
  flags INTEGER NOT NULL,
  fps BLOB,
  chain BLOB
);
CREATE TABLE IF NOT EXISTS op_deps (id INTEGER PRIMARY KEY, bytes BLOB NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS writers (id INTEGER PRIMARY KEY, name BLOB NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS snapshots (id INTEGER PRIMARY KEY, body TEXT NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS log_marks (
  dev INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  chain BLOB NOT NULL,
  PRIMARY KEY (dev, seq)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS op_pending (
  k INTEGER NOT NULL,
  fp BLOB NOT NULL,
  prev_fp BLOB,
  tv INTEGER NOT NULL,
  slot BLOB NOT NULL,
  PRIMARY KEY (k, fp)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS op_forks (
  k INTEGER NOT NULL,
  fp BLOB NOT NULL,
  tv INTEGER NOT NULL,
  slot BLOB NOT NULL,
  PRIMARY KEY (k, fp)
) WITHOUT ROWID;
";

/// 本机状态里迁移时从协议 3 灌过来的那部分（规划 §1.3；表头注释）。不同步、不可再生、不是派生表。
///
/// - `self_`：每个集合一行本机身份。`sk` = 签名钥匙种子（沿用 `sync2_self.key_seed`），`hlc` = HLC 的文本形，
///   `prev_device` / `prev_seq` / `prev_chain` = 换身份之前的上一个身份在它日志末尾的位置（没换过 = 全空）。
/// - `peers`：各设备的公钥（先到先得，换不了：[super::truth::Truth::set_peer]）、名字、扩展信息（JSON 文本）、见过的最新
///   head 代号、第一次见到的时刻。
/// - `held` / `checkpoints` / `media_local`：列同 `sync2_held` / `sync2_checkpoints` / `sync2_media_local`。
/// - `media_at`：`(位置, 内容哈希)` → 在 / 不在 / 可疑与 HLC 文本（D18）；`pend` = 这条还没出现在位置上的任何清单里、
///   要随本机下一份清单发出去（G8-3，`media.rs`）。`loc_key` = 协议 3 同口径的「位置/媒体目录#sha256」。
/// - `media_seen`：每个位置上每个作者已收到的清单代号，一代一行（集合，不是水位：代号有空洞、列目录会滞后；本机自己
///   的行 = 已发出的代号）。每轮裁到当轮列举里还在的代号（`media::pending_gens`）。
/// - `media_listed`：哪些「位置/媒体目录」有人完整列举过（协议 3 的 SEEDED）；`pend` = 是本机列的、还没随清单发出。
/// - `media_gen`：本机在每个位置上已预留的最大清单代号（只升不降，换根 / 对账也不清：一个代号只对应一个文件）。
/// - `loc_state`：每个位置的加密记忆（`location_seal`）：`loc_ids` = 位置 ID 的 JSON，`sealed` 0/1，`kdf` = 派生参数 JSON，
///   `check_` = 口令校验串，`last_ok` = 本机最近一次在这个位置上跑完一轮的时刻（G8-7b 起由 `cmd/sync.rs` `head`
///   记，写了 head 或判定不变都算；判定不变、离上次记不满一天时不为它开写事务，所以最多滞后一天）。转发的活跃窗口
///   （`cmd/sync_relay.rs`）只认它；迁移灌入（`carry.rs`）与别的命令（`cmd/sync.rs` 记 loc 标记、`location_seal`）新建的行是空的。不再是协议 3
///   「上次口令核对通过」的意思（列名冻结）。
pub(crate) const LOCAL: &str = "
CREATE TABLE IF NOT EXISTS self_ (
  col INTEGER PRIMARY KEY,
  device BLOB NOT NULL,
  sk BLOB NOT NULL,
  hlc TEXT NOT NULL,
  prev_device BLOB,
  prev_seq INTEGER,
  prev_chain BLOB,
  created INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS peers (
  col INTEGER NOT NULL,
  device BLOB NOT NULL,
  public BLOB NOT NULL,
  name TEXT,
  ext TEXT,
  head_gen INTEGER,
  first_seen INTEGER,
  PRIMARY KEY (col, device)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS held (
  col INTEGER NOT NULL,
  device BLOB NOT NULL,
  seq INTEGER NOT NULL,
  kind TEXT NOT NULL,
  entity TEXT NOT NULL,
  PRIMARY KEY (col, device, seq)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS checkpoints (
  col INTEGER NOT NULL,
  device BLOB NOT NULL,
  seq INTEGER NOT NULL,
  wall INTEGER NOT NULL,
  name TEXT NOT NULL,
  reason TEXT NOT NULL,
  PRIMARY KEY (col, device, seq)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS media_local (
  col INTEGER NOT NULL,
  name TEXT NOT NULL,
  size INTEGER NOT NULL,
  mtime INTEGER NOT NULL,
  sha256 BLOB NOT NULL,
  synced BLOB,
  PRIMARY KEY (col, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS media_at (
  col INTEGER NOT NULL,
  loc_key TEXT NOT NULL,
  sha BLOB NOT NULL,
  state INTEGER NOT NULL,
  hlc TEXT NOT NULL,
  pend INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (col, loc_key, sha)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS media_seen (
  col INTEGER NOT NULL,
  loc TEXT NOT NULL,
  device BLOB NOT NULL,
  gen INTEGER NOT NULL,
  PRIMARY KEY (col, loc, device, gen)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS media_listed (
  col INTEGER NOT NULL,
  loc_key TEXT NOT NULL,
  pend INTEGER NOT NULL,
  PRIMARY KEY (col, loc_key)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS media_gen (
  col INTEGER NOT NULL,
  loc TEXT NOT NULL,
  device BLOB NOT NULL,
  gen INTEGER NOT NULL,
  PRIMARY KEY (col, loc, device)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS loc_state (
  col INTEGER NOT NULL,
  loc_key TEXT NOT NULL,
  loc_ids TEXT,
  sealed INTEGER,
  kdf TEXT,
  check_ TEXT,
  last_ok INTEGER,
  PRIMARY KEY (col, loc_key)
) WITHOUT ROWID;
";

/// 同步运行时的本机状态（G8-4，规划 §1.3：不迁移，换代后从头对账）。读写 API 在 `sync_state.rs`，`op_wait` 由
/// `receive.rs` 写。不同步、不进导出与备份（导出不含待投递，D34）。
///
/// - `loc_heads`：每个位置上每台设备最新的 head（上一轮在这个位置上读到的）：代号、seq、段清单（JSON 文本数组）。
///   本机自己那一行就是「这个位置上已经发布到哪里」（协议 3 `sync2_locations.uploaded` / `head_gen` 的落点）。
///   协议 3 `sync2_location_heads` 的对应物。
/// - `op_wait`：原生操作的因果等待缓冲（设计 §4.2：新库真相层只有承袭用的 `op_pending`）。每行是原生段里的一项：
///   `k` = 它第一个 seq 的操作主键（`devs` 的下标自带集合，同 `op_pending`），`prev` / `chain` = 这一项前后的链值
///   （作者签名担保的段里重算出来的），`span` = 占几个 seq，`op` = 操作的规范字节（空 = 空洞）。
/// - `relay_out`：本机转发到各位置的文件（`rly-` 中继件 / `rhd-` 转发 head）与当时转发的 head 代号；`gone` = 1 是被更新的
///   转发取代、等调用方删掉位置上的文件（两段式删除，协议 3 `sync2_relay_out` + `sync2_relay_gone`）。
/// - `oldroot_fp`：每个位置旧根（`v3/`）上一次核对时的清单指纹与时刻（设计 §6.2 第 4 步「每轮核对旧根」）。
/// - `relay_segs`（G8-7b 起）：收段时留下的、可以转发给别的位置的作者段原文（不封装的中继件 `FRL4`，`piece`），按
///   （作者, 区间, 链尾标签）唯一；每个位置都有了就删（`cmd/sync_relay.rs`）。行里是几 KB 到几 MB 的 blob，所以是普通
///   rowid 表（唯一约束的自动索引承担全部查找：前缀 `(col, device)` 与整键等值），不用 `WITHOUT ROWID`。协议 3
///   `sync2_relay_segs` 的对应物。
/// - `relay_auth`（第五波 K2 根治起）：收下的别的设备的每一段的作者签名、原段头与作者签的空洞（`voids` =
///   `n uv | (起始 seq uv | 条数 uv | 区间末链值[32]) × n`），同一区间只留作者签的空洞最多的那份。本机清除了这位作者的
///   操作之后从日志重切这一段（`gen4/recut.rs` 的 `FRX4` 带作者原签名）用（`sync_state.rs` `recut_from_log`）。
/// - `relay_stubs`（同上）：被挖掉的别的设备的操作的剔除记录（`gen4/recut.rs` `Stub` 的独立编码：信封、载荷哈希、
///   清除目标、清掉它的 Purge），按操作主键 `k`。本机清除别人的操作时（`truth.rs` `advance_purge`）与收重切件落下别人
///   挖掉的那些时写；重切要它把被挖掉的那一项照样算进作者签名的摘要与链里。
/// - `relay_park`（第六波起）：一个位置上收不了的重切件（`FRX4`）在等什么——等一条本机还没有的 Purge（`wait` /
///   `wait_seq` > 0）或一台设备的信任状态变化（`wait_seq` = 0，`trust` = 停放时的状态，0 = 可信）；按 (集合, 位置,
///   作者, 文件名) 一行，`last` = 件的区间末尾。`plan` 对被转发来的 head 只在等的事发生之后才再拉这一件（`cmd/sync_park.rs`）。
pub(crate) const SYNC: &str = "
CREATE TABLE IF NOT EXISTS loc_heads (
  col INTEGER NOT NULL,
  loc_key TEXT NOT NULL,
  device BLOB NOT NULL,
  gen INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  segs TEXT NOT NULL,
  PRIMARY KEY (col, loc_key, device)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS op_wait (
  k INTEGER NOT NULL,
  prev BLOB NOT NULL,
  chain BLOB NOT NULL,
  span INTEGER NOT NULL,
  op BLOB,
  PRIMARY KEY (k, prev, chain)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS relay_out (
  col INTEGER NOT NULL,
  loc_key TEXT NOT NULL,
  device BLOB NOT NULL,
  name TEXT NOT NULL,
  gen INTEGER NOT NULL,
  gone INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (col, loc_key, device, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS relay_segs (
  id INTEGER PRIMARY KEY,
  col INTEGER NOT NULL,
  device BLOB NOT NULL,
  first INTEGER NOT NULL,
  last INTEGER NOT NULL,
  tag TEXT NOT NULL,
  piece BLOB NOT NULL,
  UNIQUE (col, device, first, last, tag)
);
CREATE TABLE IF NOT EXISTS relay_auth (
  col INTEGER NOT NULL,
  device BLOB NOT NULL,
  first INTEGER NOT NULL,
  last INTEGER NOT NULL,
  head BLOB NOT NULL,
  sig BLOB NOT NULL,
  voids BLOB NOT NULL,
  PRIMARY KEY (col, device, first, last)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS relay_stubs (
  k INTEGER PRIMARY KEY,
  stub BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS relay_park (
  col INTEGER NOT NULL,
  loc_key TEXT NOT NULL,
  device BLOB NOT NULL,
  name TEXT NOT NULL,
  last INTEGER NOT NULL,
  wait BLOB NOT NULL,
  wait_seq INTEGER NOT NULL,
  trust INTEGER NOT NULL,
  PRIMARY KEY (col, loc_key, device, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS oldroot_fp (
  col INTEGER NOT NULL,
  loc_key TEXT NOT NULL,
  fp BLOB NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (col, loc_key)
) WITHOUT ROWID;
";

/// 派生表：全部能由 `derive.rs` 的 `rebuild_all` 从真相重建。列的取值见那里。
const DERIVED: &str = "
CREATE TABLE IF NOT EXISTS ent_ix (
  col INTEGER NOT NULL,
  id NOT NULL,
  k INTEGER NOT NULL,
  kind INTEGER NOT NULL,
  win INTEGER NOT NULL,
  PRIMARY KEY (col, id, k)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ent_kind ON ent_ix (col, kind, id) WHERE win = 1;
-- 实体归属闸（cmd/writes_owner.rs）：按 ID 问别的集合有没有它的身份记录。部分索引的条件 col > 0 只有归属闸的查询写
-- （集合号从 1 起，恒成立）：带 col = ? 的既有查询推不出它、用不上这个索引，计划不受影响。
CREATE INDEX IF NOT EXISTS ent_id ON ent_ix (id) WHERE col > 0;
CREATE TABLE IF NOT EXISTS reg_ix (
  col INTEGER NOT NULL,
  ekind INTEGER NOT NULL,
  ent NOT NULL,
  key BLOB NOT NULL,
  k INTEGER NOT NULL,
  state INTEGER NOT NULL,
  PRIMARY KEY (col, ekind, ent, key, k)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS log_ix (
  col INTEGER NOT NULL,
  card NOT NULL,
  at INTEGER NOT NULL,
  k INTEGER NOT NULL,
  id NOT NULL,
  win INTEGER NOT NULL,
  PRIMARY KEY (col, card, at, k)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS log_id ON log_ix (col, id, k);
-- 本机落库序（本机状态，不在 DERIVED_TABLES、不参与对拍）：log_ix 每一行（一条日志操作）第一次进索引时取集合里下一个
-- 序号 n（起点 derive.rs SEQ_BASE = 2^40，与协议 3 rowid 不相交），删出索引时删掉；整层重建保留还在的行的序号。协议 3 日志表 rowid 的对应物（cmd/training.rs 文件头「rowid」）。
CREATE TABLE IF NOT EXISTS log_seq (
  col INTEGER NOT NULL,
  n INTEGER NOT NULL,
  k INTEGER NOT NULL,
  card NOT NULL,
  PRIMARY KEY (col, n)
) WITHOUT ROWID;
CREATE UNIQUE INDEX IF NOT EXISTS log_seq_k ON log_seq (col, k);
CREATE INDEX IF NOT EXISTS reg_set_aside ON reg_ix (col, state, k) WHERE state < 0;
CREATE TABLE IF NOT EXISTS closure_ix (
  col INTEGER NOT NULL,
  device BLOB NOT NULL,
  upto INTEGER NOT NULL,
  ctx TEXT NOT NULL,
  PRIMARY KEY (col, device)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS tag_ix (
  col INTEGER NOT NULL,
  note NOT NULL,
  k INTEGER NOT NULL,
  what INTEGER NOT NULL,
  tag TEXT NOT NULL,
  state INTEGER NOT NULL,
  PRIMARY KEY (col, note, k, what, tag)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS tag_set_aside ON tag_ix (col, state, k) WHERE state < 0;
CREATE TABLE IF NOT EXISTS media_ix (
  col INTEGER NOT NULL,
  name TEXT NOT NULL,
  k INTEGER NOT NULL,
  state INTEGER NOT NULL,
  PRIMARY KEY (col, name, k)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS purge_ix (
  col INTEGER NOT NULL,
  ekind INTEGER NOT NULL,
  ent NOT NULL,
  k INTEGER NOT NULL,
  state INTEGER NOT NULL,
  PRIMARY KEY (col, ekind, ent, k)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS ent_ops (
  col INTEGER NOT NULL,
  ekind INTEGER NOT NULL,
  ent NOT NULL,
  what INTEGER NOT NULL,
  k INTEGER NOT NULL,
  PRIMARY KEY (col, ekind, ent, what, k)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS hold_ix (
  col INTEGER NOT NULL,
  ekind INTEGER NOT NULL,
  ent NOT NULL,
  k INTEGER NOT NULL,
  edits INTEGER NOT NULL,
  reviews INTEGER NOT NULL,
  moves INTEGER NOT NULL,
  PRIMARY KEY (col, ekind, ent, k)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS salt_ix (
  col INTEGER NOT NULL,
  k INTEGER NOT NULL,
  salt TEXT NOT NULL,
  PRIMARY KEY (col, k, salt)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS alias_ix (
  col INTEGER NOT NULL,
  id BLOB NOT NULL,
  canon BLOB NOT NULL,
  how INTEGER NOT NULL,
  PRIMARY KEY (col, id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS alias_canon ON alias_ix (col, canon, id) WHERE canon != id;
CREATE INDEX IF NOT EXISTS alias_pool ON alias_ix (col, id) WHERE how >= 3;
-- 实体归属闸（cmd/writes_owner.rs）：按规范 ID 问别的集合里有没有它的成员（迁移来的带盐存量）。col > 0 同 ent_id。
CREATE INDEX IF NOT EXISTS alias_canon_any ON alias_ix (canon) WHERE canon != id AND col > 0;
CREATE TABLE IF NOT EXISTS alias_writer_ix (
  col INTEGER NOT NULL,
  name TEXT NOT NULL,
  origin TEXT NOT NULL,
  PRIMARY KEY (col, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS join_ix (
  col INTEGER NOT NULL,
  k INTEGER NOT NULL,
  src BLOB NOT NULL,
  dir TEXT NOT NULL,
  PRIMARY KEY (col, k)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS dg_ix (
  col INTEGER NOT NULL,
  ekind INTEGER NOT NULL,
  ent NOT NULL,
  sum BLOB NOT NULL,
  n INTEGER NOT NULL,
  PRIMARY KEY (col, ekind, ent)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS dg_dirty (
  col INTEGER NOT NULL,
  ekind INTEGER NOT NULL,
  ent NOT NULL,
  PRIMARY KEY (col, ekind, ent)
) WITHOUT ROWID;
";

/// 派生表的名字（每张都有 `col` 列）。
pub(crate) const DERIVED_TABLES: [&str; 19] = [
    "ent_ix",
    "reg_ix",
    "log_ix",
    "closure_ix",
    "tag_ix",
    "media_ix",
    "purge_ix",
    "ent_ops",
    "hold_ix",
    "salt_ix",
    "alias_ix",
    "alias_writer_ix",
    "join_ix",
    "dg_ix",
    "dg_dirty",
    "notes",
    "cards",
    "stats",
    "anki_members",
];

/// 这个文件是不是新代的库：空文件（还没有任何表）才可以建；有表的必须 `schema` 等于 [SCHEMA] 且 `application_id` =
/// [APPLICATION_ID]。只读。
///
/// 协议 3 的 `srs.db`（含封存成 `SEALED_SCHEMA` 的保留副本与墓碑库）、更新版本写的新代库、别的 SQLite 文件都在这里
/// 拒掉——在动任何 PRAGMA、建任何表之前。
pub(crate) fn check_kind(conn: &Connection) -> Result<(), String> {
    if table_count(conn)? == 0 {
        return Ok(());
    }
    let has_meta: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'srs_meta')",
            [],
            |r| r.get(0),
        )
        .map_err(sql)?;
    let current: Option<String> = if has_meta {
        conn.query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| {
            r.get(0)
        })
        .ok()
    } else {
        None
    };
    let v = match current.as_deref().map(str::parse::<i64>) {
        Some(Ok(v)) => v,
        other => {
            return Err(format!(
                "gen4 store: not a generation 4 library (schema {other:?})"
            ));
        }
    };
    if v == crate::store::schema::SEALED_SCHEMA {
        return Err(format!(
            "gen4 store: a sealed protocol 3 library (schema {v}), not a generation 4 library"
        ));
    }
    if v < GEN_FLOOR {
        return Err(format!(
            "gen4 store: a protocol 3 library (schema {v}), not a generation 4 library"
        ));
    }
    let app: i32 = conn
        .query_row("PRAGMA application_id", [], |r| r.get(0))
        .map_err(sql)?;
    if app != APPLICATION_ID {
        return Err(format!(
            "gen4 store: not a generation 4 library (application_id {app:#x})"
        ));
    }
    if v > SCHEMA {
        return Err(format!(
            "gen4 store: schema {v} is newer than this build ({SCHEMA})"
        ));
    }
    if v != SCHEMA {
        return Err(format!(
            "gen4 store: not a generation 4 library of this build (schema {v})"
        ));
    }
    Ok(())
}

fn table_count(conn: &Connection) -> Result<i64, String> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table'",
        [],
        |r| r.get(0),
    )
    .map_err(sql)
}

/// [check_kind] 之上再要求已经建过表：不建库的打开（`files::OpenMode::Secondary`）用。
pub(crate) fn check_ready(conn: &Connection) -> Result<(), String> {
    check_kind(conn)?;
    if table_count(conn)? == 0 {
        return Err("gen4 store: the generation 4 library is empty".to_owned());
    }
    Ok(())
}

/// 查询规划器的统计：**手写、随 schema 走，不跑 `ANALYZE`**。
///
/// 派生表的键都以 `col` 打头，而一个文件里通常只有一个集合。没有统计时 SQLite 默认「索引第一列相等 ≈ 只剩 10 行」，
/// 于是 `WHERE col = ? AND id = ?` 这样的查询宁可沿主键把整个集合扫一遍，也不走 `(col, id, k)` 的二级索引——样本库
/// （35 万条日志）上这样查一次 80 ms：按日志 ID 重选代表每条日志一次，重建语义摘要每张卡一次（19 分钟）。这里把
/// 「`col` 不区分行、其余各列大致区分到多少」告诉它。`sqlite_stat1.stat` 的格式：行数，再是按索引前 1、2、… 列相等时
/// 平均剩下的行数；`WITHOUT ROWID` 表的主键那一行 `idx` = 表名。量级取样本库，数字只表达形状、不随数据更新：计划因此
/// 是 schema 的函数，不因某台设备数据多少而变（`tests::lookups_with_a_key_never_walk_the_whole_collection` 钉住）。
/// 对这个文件跑 `ANALYZE` / `PRAGMA optimize` 会把它们换成随数据变的统计——下次打开时 [install] 会写回来。
const PLANNER_STATS: [(&str, &str, &str); 45] = [
    ("alias_ix", "alias_canon", "1000000 1000000 2 1"),
    ("alias_ix", "alias_canon_any", "1000000 2"),
    ("alias_ix", "alias_ix", "1000000 1000000 1"),
    ("alias_ix", "alias_pool", "5000 5000 1"),
    ("anki_members", "anki_members", "100000 100000 50000 1 1"),
    ("anki_members", "anki_members_note", "100000 100000 3"),
    ("cache_log", "cache_log", "4096 4096 8 1"),
    ("cards", "cards", "100000 100000 1"),
    ("cards", "cards_anki", "100000 100000 1"),
    ("cards", "cards_deck", "100000 100000 5000"),
    ("cards", "cards_id", "100000 2"),
    ("cards", "cards_learning", "500 500 2 1"),
    ("cards", "cards_new_freq", "30000 30000 15000 2 2 1 1"),
    ("cards", "cards_new_position", "30000 30000 15000 2 1"),
    ("cards", "cards_note", "100000 100000 2"),
    ("cards", "cards_review_due", "60000 60000 3000 30"),
    ("cards", "cards_tally", "100000 100000 5000 1500 20"),
    ("cards", "cards_template", "100000 100000 5000"),
    ("dg_ix", "dg_ix", "200000 200000 40000 1"),
    ("ent_ix", "ent_id", "50000 2"),
    ("ent_ix", "ent_ix", "50000 50000 1 1"),
    ("ent_ix", "ent_kind", "40000 40000 10000 1"),
    ("ent_ops", "ent_ops", "1000000 1000000 500000 20 20 1"),
    ("log_ix", "log_at", "1000000 1000000 2"),
    ("log_ix", "log_id", "1000000 1000000 1 1"),
    ("log_ix", "log_ix", "1000000 1000000 20 1 1"),
    ("log_seq", "log_seq", "1000000 1000000 1"),
    ("log_seq", "log_seq_k", "1000000 1000000 1"),
    ("media_ix", "media_ix", "100000 100000 1 1"),
    ("notes", "notes", "50000 50000 1"),
    ("notes", "notes_anki", "50000 50000 1"),
    ("notes", "notes_deck", "50000 50000 5000"),
    ("notes", "notes_dupe", "50000 50000 2"),
    ("notes", "notes_pending", "100 100"),
    ("notes", "notes_source", "50000 50000 50"),
    ("notes", "notes_term", "50000 50000 2"),
    ("notes", "notes_type", "50000 50000 1000"),
    ("ops", "ops_checkpoint", "100 1"),
    ("reg_ix", "reg_card_key", "50000 50000 3"),
    ("reg_ix", "reg_ix", "1000000 1000000 250000 13 1 1"),
    ("reg_ix", "reg_set_aside", "1000 1000 500 1"),
    ("stats", "stats", "1000000 1000000 2 1"),
    ("stats", "stats_card", "1000000 1000000 20"),
    ("tag_ix", "tag_ix", "300000 300000 7 4 2 1"),
    ("tag_ix", "tag_set_aside", "1000 1000 500 1"),
];

/// 把 [PLANNER_STATS] 装进 `sqlite_stat1`（已经一样就不写）。
fn planner_stats(conn: &Connection) -> Result<(), String> {
    let exists: bool = conn
        .prepare("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'sqlite_stat1'")
        .map_err(sql)?
        .exists([])
        .map_err(sql)?;
    let have: Vec<(String, String, String)> = if exists {
        let mut stmt = conn
            .prepare("SELECT tbl, COALESCE(idx, ''), stat FROM sqlite_stat1 ORDER BY tbl, idx")
            .map_err(sql)?;
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)?
    } else {
        Vec::new()
    };
    if have
        .iter()
        .map(|(t, i, s)| (t.as_str(), i.as_str(), s.as_str()))
        .eq(PLANNER_STATS.iter().copied())
    {
        return Ok(());
    }
    // `ANALYZE <一张小表>` 只是为了让 SQLite 建出 `sqlite_stat1`（不能直接 CREATE）；`ANALYZE sqlite_schema` 让本连接
    // 重读统计。
    conn.execute_batch("ANALYZE srs_meta; DELETE FROM sqlite_stat1;")
        .map_err(sql)?;
    for (tbl, idx, stat) in PLANNER_STATS {
        conn.execute(
            "INSERT INTO sqlite_stat1 (tbl, idx, stat) VALUES (?1, ?2, ?3)",
            [tbl, idx, stat],
        )
        .map_err(sql)?;
    }
    conn.execute_batch("ANALYZE sqlite_schema;").map_err(sql)
}

/// 建表（可重放）。不是新代库的文件报错、什么都不改。
pub fn install(conn: &Connection) -> Result<(), String> {
    check_kind(conn)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS srs_meta (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);",
    )
    .map_err(sql)?;
    let app: i32 = conn
        .query_row("PRAGMA application_id", [], |r| r.get(0))
        .map_err(sql)?;
    if app != APPLICATION_ID {
        // 只有空文件会走到这里（有表的在 check_kind 已经核过魔数）。文件头的这个字段随事务提交 / 回滚。
        conn.execute_batch(&format!("PRAGMA application_id = {APPLICATION_ID};"))
            .map_err(sql)?;
    }
    conn.execute_batch(TRUTH).map_err(sql)?;
    conn.execute_batch(LOCAL).map_err(sql)?;
    conn.execute_batch(SYNC).map_err(sql)?;
    conn.execute_batch(DERIVED).map_err(sql)?;
    super::digest::set_triggers(conn, true)?;
    conn.execute_batch(super::cache::DDL).map_err(sql)?;
    planner_stats(conn)?;
    conn.execute(
        "INSERT OR REPLACE INTO srs_meta (key, value) VALUES ('schema', ?1)",
        [SCHEMA.to_string()],
    )
    .map_err(sql)?;
    Ok(())
}

/// 打开（不存在就建）新代库文件。不做内存映射（设计 §6.5：迁移用的连接不映射）、页缓存取保守值：迁移 / 干跑 / 建库
/// 直接用这份；生产开库（`kernel.rs` `G4Core::open`）在这之上按协议 3 的内存预算重配（`store/mod.rs`
/// `tune_for_daily_use` / `retune_writer_cache`，`store/mem_budget.rs`）。
///
/// 并发：同一个文件可能有别的连接正拿着写锁（另一个线程的 `BEGIN IMMEDIATE`、迁移、收段）。打开要读文件头、切 WAL、
/// 再跑一遍 [install]（它会写：装触发器、`srs_meta`）。[install] 先读（`check_kind`、`application_id`、
/// `CREATE … IF NOT EXISTS`）后写，放在延迟事务里时，读的那一刻定下快照，别的连接在这之后提交过，升级写锁就直接报
/// `SQLITE_BUSY_SNAPSHOT`（「database is locked」）、**不经忙等**——这才是复核里两条并发测试在负载下随机红的根因
/// （光设忙等不够，实测仍红）。所以 [install] 走 [in_write_tx]：`BEGIN IMMEDIATE` 一开始就经忙等排队拿写锁，之后
/// 不会再撞快照。忙等显式设成 [BUSY_TIMEOUT]（rusqlite 的默认也是 5 秒，这里写明，不依赖库的默认值）。测试
/// `concurrent_opens_under_a_busy_writer_all_succeed`、`in_write_tx_takes_the_write_lock_before_running`、
/// `open_waits_for_another_connections_write_lock`。
pub fn open(path: &Path) -> Result<Connection, String> {
    let conn = Connection::open(path).map_err(sql)?;
    conn.busy_timeout(BUSY_TIMEOUT).map_err(sql)?;
    check_kind(&conn)?;
    configure(&conn)?;
    in_write_tx(&conn, |c| {
        // 还没有任何表 = 这一笔建库：从第一页起就开着 `secure_delete`，记下来（`scrub.rs` 第 3 条：有这个标记的库
        // 清除时不必整库整理）。
        let born = !c
            .query_row("SELECT EXISTS (SELECT 1 FROM sqlite_schema)", [], |r| {
                r.get::<_, bool>(0)
            })
            .map_err(sql)?;
        install(c)?;
        if born {
            super::scrub::mark_secure_from_birth(c)?;
        }
        Ok(())
    })?;
    Ok(conn)
}

/// [open] 给连接设的忙等时长（别的连接拿着锁时等多久再报 `database is locked`）。与协议 3 `store/mod.rs` 的
/// `configure_as` 同值；调用方可以再调。
pub const BUSY_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(5000);

/// 在一个**一开始就拿写锁**的事务（`BEGIN IMMEDIATE`）里跑 [f]；出错整笔回滚。只用于不嵌在别的事务里的入口
/// （[open]）：要先读再写、又可能与别的连接并发时，延迟事务读完再升级会撞上 `SQLITE_BUSY_SNAPSHOT`（不经忙等），
/// 这里在 `BEGIN` 时就经忙等排队。已在事务里时报错（SQLite 不许嵌套 `BEGIN`），不落任何东西。
pub(crate) fn in_write_tx<T>(
    conn: &Connection,
    f: impl FnOnce(&Connection) -> Result<T, String>,
) -> Result<T, String> {
    conn.execute_batch("BEGIN IMMEDIATE").map_err(sql)?;
    match f(conn) {
        Ok(v) => match conn.execute_batch("COMMIT") {
            Ok(()) => Ok(v),
            Err(e) => {
                let _ = conn.execute_batch("ROLLBACK");
                Err(sql(e))
            }
        },
        Err(e) => {
            let _ = conn.execute_batch("ROLLBACK");
            Err(e)
        }
    }
}

/// 内存库（测试）。
pub fn open_in_memory() -> Result<Connection, String> {
    let conn = Connection::open_in_memory().map_err(sql)?;
    in_tx(&conn, install)?;
    Ok(conn)
}

pub(crate) fn configure(conn: &Connection) -> Result<(), String> {
    // 新文件才生效；已有的文件保持它建库时的设置。
    conn.execute_batch("PRAGMA auto_vacuum = INCREMENTAL;")
        .map_err(sql)?;
    let mode: String = conn
        .query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))
        .map_err(sql)?;
    if !mode.eq_ignore_ascii_case("wal") {
        return Err(format!("gen4 store: journal_mode is {mode}, expected wal"));
    }
    conn.execute_batch("PRAGMA synchronous = NORMAL; PRAGMA cache_size = -16384;")
        .map_err(sql)?;
    // 删行 / 改行 / 释放页时把旧内容写零（彻底清除的字节层，`scrub.rs`）。按连接生效，每条写连接都经这里。
    let on: i64 = conn
        .query_row("PRAGMA secure_delete = ON", [], |r| r.get(0))
        .map_err(sql)?;
    if on != 1 {
        return Err(format!("gen4 store: secure_delete is {on}, expected 1"));
    }
    Ok(())
}

/// 在一个事务里跑 [f]；出错整笔回滚。
pub fn in_tx<T>(
    conn: &Connection,
    f: impl FnOnce(&Connection) -> Result<T, String>,
) -> Result<T, String> {
    conn.execute_batch("SAVEPOINT gen4").map_err(sql)?;
    match f(conn) {
        Ok(v) => match conn.execute_batch("RELEASE gen4") {
            Ok(()) => Ok(v),
            Err(e) => {
                let _ = conn.execute_batch("ROLLBACK TO gen4; RELEASE gen4");
                Err(sql(e))
            }
        },
        Err(e) => {
            let _ = conn.execute_batch("ROLLBACK TO gen4; RELEASE gen4");
            Err(e)
        }
    }
}

/// 每张表（含它的索引）占的字节，按名字升序。库没编 `dbstat` 时返回空表。
pub fn table_bytes(conn: &Connection) -> Vec<(String, i64)> {
    let Ok(mut stmt) = conn.prepare(
        "SELECT COALESCE(s.tbl_name, d.name), SUM(d.pgsize) FROM dbstat d \
         LEFT JOIN sqlite_schema s ON s.name = d.name GROUP BY 1 ORDER BY 1",
    ) else {
        return Vec::new();
    };
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)));
    match rows {
        Ok(it) => it.filter_map(Result::ok).collect(),
        Err(_) => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 源码里一个字符串字面量的内容（处理行尾续行与常见转义）；[at] 指向开头的引号。返回 (内容, 结束引号之后的位置)。
    fn literal(src: &[u8], at: usize) -> (String, usize) {
        let mut out = Vec::new();
        let mut i = at + 1;
        while src[i] != b'"' {
            if src[i] == b'\\' {
                i += 1;
                match src[i] {
                    b'\n' | b'\r' => {
                        while src[i].is_ascii_whitespace() {
                            i += 1;
                        }
                        continue;
                    }
                    b'n' => out.push(b'\n'),
                    c => out.push(c),
                }
            } else {
                out.push(src[i]);
            }
            i += 1;
        }
        (String::from_utf8(out).unwrap(), i + 1)
    }

    /// 一个文件（测试模块之前的部分）里的全部 SQL 语句字面量。
    fn statements(src: &str) -> Vec<String> {
        let src = src.split("#[cfg(test)]").next().unwrap().as_bytes();
        let mut out = Vec::new();
        let mut i = 0;
        while i < src.len() {
            if src[i] != b'"' {
                i += 1;
                continue;
            }
            let (text, next) = literal(src, i);
            i = next;
            let verb = ["SELECT ", "DELETE ", "UPDATE "]
                .iter()
                .any(|v| text.starts_with(v));
            // 带 `{` 的是 format! 的模板（表名待填），不是完整语句。
            if verb && !text.contains('{') {
                out.push(text);
            }
        }
        out
    }

    /// 派生层的每条语句：只要它除了 `col = ?` 之外还给了别的相等条件，计划里就不能有「只按 `col` 找」的一步——
    /// 那是把整个集合走一遍（[PLANNER_STATS] 说的那个坑）。计划只取决于 schema 与手写的统计，空库上看就够。
    #[test]
    fn lookups_with_a_key_never_walk_the_whole_collection() {
        // 本来就是对整个集合做的（多出来的相等条件是 `state` / `kind` / 键名这类过滤，不是定位）。
        const WHOLE: [&str; 11] = [
            "SELECT DISTINCT ekind, ent FROM reg_ix WHERE col = ?1 AND key = ?2",
            "SELECT k FROM reg_ix WHERE col = ?1 AND state = ?2 UNION SELECT k FROM tag_ix WHERE col = ?1 AND state = ?2",
            "SELECT k FROM reg_ix WHERE col = ?1 AND state = ?2 UNION SELECT k FROM purge_ix WHERE col = ?1 AND state = ?2",
            // 同上一条分开数（`weigh.rs` `distrusted_split`，同步页的扣着条数）。
            "SELECT DISTINCT k FROM reg_ix WHERE col = ?1 AND state = ?2",
            "SELECT DISTINCT k FROM purge_ix WHERE col = ?1 AND state = ?2",
            "SELECT name, k FROM media_ix WHERE col = ?1 AND state = ?2 ORDER BY name",
            "SELECT id, kind, k FROM ent_ix WHERE col = ?1 AND typeof(id) = 'blob' ORDER BY id, k",
            "SELECT ekind, ent, key, k FROM reg_ix WHERE col = ?1 AND state != ?2 AND typeof(ent) = 'blob' ORDER BY ekind, ent, key, k",
            // 整份物化：本来就要列出集合里全部活着的笔记。
            "SELECT id FROM ent_ix WHERE col = ?1 AND kind = ?2 AND win = 1",
            // 别名增量证明：全部笔记类型 / 牌组的身份记录（量小，扫的是身份记录表）。
            "SELECT id, k FROM ent_ix WHERE col = ?1 AND kind = ?2 AND typeof(id) = 'blob' ORDER BY id, k",
            // 收尾时找检查点之前建的旧闭包行（`derive.rs` `Index::settle`）：一台承袭设备一行，`>=` 不是定位。
            "SELECT device FROM closure_ix WHERE col = ?1 AND upto >= ?2 AND json_type(ctx, '$.at') IS NULL",
        ];
        let conn = open_in_memory().unwrap();
        let mut seen = 0;
        let mut bad = Vec::new();
        for src in [
            include_str!("derive.rs"),
            include_str!("weigh.rs"),
            include_str!("alias.rs"),
            include_str!("digest.rs"),
            include_str!("cache.rs"),
        ] {
            for q in statements(src) {
                seen += 1;
                let keyed = q.matches("= ?").count() > q.matches("col = ?").count();
                if !keyed || WHOLE.contains(&q.as_str()) {
                    continue;
                }
                let mut stmt = conn
                    .prepare(&format!("EXPLAIN QUERY PLAN {q}"))
                    .unwrap_or_else(|e| panic!("{q}: {e}"));
                let mut rows = stmt.raw_query();
                while let Some(r) = rows.next().unwrap() {
                    let step: String = r.get(3).unwrap();
                    if step.starts_with("SCAN ") && !step.contains("CONSTANT")
                        || step.starts_with("SEARCH ") && step.ends_with("(col=?)")
                    {
                        bad.push(format!("{q}\n    {step}"));
                    }
                }
            }
        }
        assert!(seen > 60, "only {seen} statements found");
        assert!(bad.is_empty(), "{}", bad.join("\n"));
    }

    #[test]
    fn the_planner_statistics_are_installed_once_and_restored() {
        let conn = open_in_memory().unwrap();
        let read = |conn: &Connection| -> Vec<(String, String)> {
            conn.prepare("SELECT idx, stat FROM sqlite_stat1 ORDER BY tbl, idx")
                .unwrap()
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap()
        };
        let want: Vec<(String, String)> = PLANNER_STATS
            .iter()
            .map(|(_, i, s)| ((*i).to_owned(), (*s).to_owned()))
            .collect();
        assert_eq!(read(&conn), want);
        // 每个名字都真有那张表 / 那个索引。
        for (tbl, idx, _) in PLANNER_STATS {
            let n: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_schema WHERE tbl_name = ?1 AND name = ?2",
                    [tbl, idx],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(n, 1, "{tbl}.{idx}");
        }
        // 反过来：每个显式建的索引都有统计。漏一个，SQLite 就按「第一列相等剩 10 行」估它，`col = ?` 打头的索引
        // 会被当成高选择性的、抢掉真正的键（G9-2 的 `cards_template` 曾让 `term_status` 按模板扫整个集合）。
        let idxs: Vec<(String, String)> = conn
            .prepare(
                "SELECT tbl_name, name FROM sqlite_schema WHERE type = 'index' \
                 AND name NOT LIKE 'sqlite_autoindex_%' ORDER BY tbl_name, name",
            )
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for (tbl, idx) in idxs {
            assert!(
                PLANNER_STATS.iter().any(|(t, i, _)| *t == tbl && *i == idx),
                "index {tbl}.{idx} has no PLANNER_STATS row"
            );
        }
        // 有人跑了 ANALYZE：下次建表时写回来。
        conn.execute_batch("ANALYZE;").unwrap();
        assert_ne!(read(&conn), want);
        in_tx(&conn, install).unwrap();
        assert_eq!(read(&conn), want);
    }

    /// D7 的正向识别：有表的文件，`schema` 在新代号段里也还要 `application_id` 对、号正好是本版本的。
    #[test]
    fn check_kind_refuses_a_wrong_magic_an_older_and_a_newer_generation_4_schema() {
        let conn = open_in_memory().unwrap();
        assert_eq!(check_kind(&conn), Ok(()));
        let set_schema = |v: i64| {
            conn.execute(
                "UPDATE srs_meta SET value = ?1 WHERE key = 'schema'",
                [v.to_string()],
            )
            .unwrap();
        };
        let refused = |want: &str| {
            let e = check_kind(&conn).unwrap_err();
            assert!(e.contains(want), "want {want:?}: {e}");
            // 建表也走同一个判定：拒绝时什么都不改。
            assert!(in_tx(&conn, install).unwrap_err().contains(want));
        };
        // 号对、魔数不对（0 = 没写过；别的应用的值）。
        for app in [0, 0x1234_5678] {
            conn.execute_batch(&format!("PRAGMA application_id = {app};"))
                .unwrap();
            refused("application_id");
        }
        conn.execute_batch(&format!("PRAGMA application_id = {APPLICATION_ID};"))
            .unwrap();
        // 魔数对、号是新代号段里更早的一版。
        for v in [GEN_FLOOR, SCHEMA - 1] {
            set_schema(v);
            refused("of this build");
        }
        // 魔数对、号比本版本新。
        set_schema(SCHEMA + 1);
        refused("is newer than this build");
        // 号更新、魔数又不对：先报魔数（不是新代库就不谈版本）。
        conn.execute_batch("PRAGMA application_id = 0;").unwrap();
        refused("application_id");
        conn.execute_batch(&format!("PRAGMA application_id = {APPLICATION_ID};"))
            .unwrap();
        set_schema(SCHEMA);
        assert_eq!(check_kind(&conn), Ok(()));
        // 有表、没有 schema 行 / 不是数字。
        conn.execute("UPDATE srs_meta SET value = 'x' WHERE key = 'schema'", [])
            .unwrap();
        refused("not a generation 4 library");
        conn.execute("DELETE FROM srs_meta WHERE key = 'schema'", [])
            .unwrap();
        refused("not a generation 4 library");
    }

    /// 本机状态表与 `collections` 的列（规划 §1.3）：名字、类型、NOT NULL、主键位置。
    #[test]
    fn the_local_state_tables_have_the_planned_columns() {
        let conn = open_in_memory().unwrap();
        let cols = |table: &str| -> Vec<String> {
            conn.prepare(&format!("PRAGMA table_info({table})"))
                .unwrap()
                .query_map([], |r| {
                    let name: String = r.get(1)?;
                    let ty: String = r.get(2)?;
                    let notnull: i64 = r.get(3)?;
                    let pk: i64 = r.get(5)?;
                    let mut s = format!("{name} {ty}");
                    if notnull != 0 {
                        s.push_str(" NN");
                    }
                    if pk != 0 {
                        s.push_str(&format!(" PK{pk}"));
                    }
                    Ok(s)
                })
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap()
        };
        let want: [(&str, &[&str]); 19] = [
            (
                "collections",
                &[
                    "col INTEGER PK1",
                    "profile_uid TEXT NN",
                    "collection BLOB NN",
                    "dir TEXT NN",
                    "salts TEXT NN",
                    "state INTEGER",
                    "via TEXT",
                    "at INTEGER",
                ],
            ),
            (
                "self_",
                &[
                    "col INTEGER PK1",
                    "device BLOB NN",
                    "sk BLOB NN",
                    "hlc TEXT NN",
                    "prev_device BLOB",
                    "prev_seq INTEGER",
                    "prev_chain BLOB",
                    "created INTEGER NN",
                ],
            ),
            (
                "peers",
                &[
                    "col INTEGER NN PK1",
                    "device BLOB NN PK2",
                    "public BLOB NN",
                    "name TEXT",
                    "ext TEXT",
                    "head_gen INTEGER",
                    "first_seen INTEGER",
                ],
            ),
            (
                "held",
                &[
                    "col INTEGER NN PK1",
                    "device BLOB NN PK2",
                    "seq INTEGER NN PK3",
                    "kind TEXT NN",
                    "entity TEXT NN",
                ],
            ),
            (
                "checkpoints",
                &[
                    "col INTEGER NN PK1",
                    "device BLOB NN PK2",
                    "seq INTEGER NN PK3",
                    "wall INTEGER NN",
                    "name TEXT NN",
                    "reason TEXT NN",
                ],
            ),
            (
                "media_local",
                &[
                    "col INTEGER NN PK1",
                    "name TEXT NN PK2",
                    "size INTEGER NN",
                    "mtime INTEGER NN",
                    "sha256 BLOB NN",
                    "synced BLOB",
                ],
            ),
            (
                "media_at",
                &[
                    "col INTEGER NN PK1",
                    "loc_key TEXT NN PK2",
                    "sha BLOB NN PK3",
                    "state INTEGER NN",
                    "hlc TEXT NN",
                    "pend INTEGER NN",
                ],
            ),
            (
                "media_seen",
                &[
                    "col INTEGER NN PK1",
                    "loc TEXT NN PK2",
                    "device BLOB NN PK3",
                    "gen INTEGER NN PK4",
                ],
            ),
            (
                "media_listed",
                &[
                    "col INTEGER NN PK1",
                    "loc_key TEXT NN PK2",
                    "pend INTEGER NN",
                ],
            ),
            (
                "media_gen",
                &[
                    "col INTEGER NN PK1",
                    "loc TEXT NN PK2",
                    "device BLOB NN PK3",
                    "gen INTEGER NN",
                ],
            ),
            (
                "loc_state",
                &[
                    "col INTEGER NN PK1",
                    "loc_key TEXT NN PK2",
                    "loc_ids TEXT",
                    "sealed INTEGER",
                    "kdf TEXT",
                    "check_ TEXT",
                    "last_ok INTEGER",
                ],
            ),
            (
                "loc_heads",
                &[
                    "col INTEGER NN PK1",
                    "loc_key TEXT NN PK2",
                    "device BLOB NN PK3",
                    "gen INTEGER NN",
                    "seq INTEGER NN",
                    "segs TEXT NN",
                ],
            ),
            (
                "op_wait",
                &[
                    "k INTEGER NN PK1",
                    "prev BLOB NN PK2",
                    "chain BLOB NN PK3",
                    "span INTEGER NN",
                    "op BLOB",
                ],
            ),
            (
                "relay_out",
                &[
                    "col INTEGER NN PK1",
                    "loc_key TEXT NN PK2",
                    "device BLOB NN PK3",
                    "name TEXT NN PK4",
                    "gen INTEGER NN",
                    "gone INTEGER NN",
                ],
            ),
            (
                "relay_segs",
                &[
                    "id INTEGER PK1",
                    "col INTEGER NN",
                    "device BLOB NN",
                    "first INTEGER NN",
                    "last INTEGER NN",
                    "tag TEXT NN",
                    "piece BLOB NN",
                ],
            ),
            (
                "relay_auth",
                &[
                    "col INTEGER NN PK1",
                    "device BLOB NN PK2",
                    "first INTEGER NN PK3",
                    "last INTEGER NN PK4",
                    "head BLOB NN",
                    "sig BLOB NN",
                    "voids BLOB NN",
                ],
            ),
            ("relay_stubs", &["k INTEGER PK1", "stub BLOB NN"]),
            (
                "relay_park",
                &[
                    "col INTEGER NN PK1",
                    "loc_key TEXT NN PK2",
                    "device BLOB NN PK3",
                    "name TEXT NN PK4",
                    "last INTEGER NN",
                    "wait BLOB NN",
                    "wait_seq INTEGER NN",
                    "trust INTEGER NN",
                ],
            ),
            (
                "oldroot_fp",
                &[
                    "col INTEGER NN PK1",
                    "loc_key TEXT NN PK2",
                    "fp BLOB NN",
                    "at INTEGER NN",
                ],
            ),
        ];
        for (table, columns) in want {
            assert_eq!(cols(table), columns, "{table}");
        }
        // 复合主键的本机表都是 WITHOUT ROWID（照搬 sync2_*）。
        for table in [
            "peers",
            "held",
            "checkpoints",
            "media_local",
            "media_at",
            "media_seen",
            "media_listed",
            "media_gen",
            "loc_state",
            "loc_heads",
            "op_wait",
            "relay_out",
            "relay_auth",
            "relay_park",
            "oldroot_fp",
        ] {
            let sql: String = conn
                .query_row(
                    "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?1",
                    [table],
                    |r| r.get(0),
                )
                .unwrap();
            assert!(sql.ends_with("WITHOUT ROWID"), "{table}: {sql}");
        }
    }

    /// 别的连接拿着写锁时，[open] 经忙等排队、等它提交后打开成功，而不是立刻报 `database is locked`。
    #[test]
    fn open_waits_for_another_connections_write_lock() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-open-busy");
        let path = dir.0.join("srs4.db");
        let holder = open(&path).unwrap();
        holder.execute_batch("BEGIN IMMEDIATE").unwrap();
        holder
            .execute(
                "INSERT OR REPLACE INTO srs_meta (key, value) VALUES ('probe', '1')",
                [],
            )
            .unwrap();
        let release = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(300));
            holder.execute_batch("COMMIT").unwrap();
        });
        let conn = open(&path).expect("open must wait for the other writer");
        release.join().unwrap();
        let probe: String = conn
            .query_row("SELECT value FROM srs_meta WHERE key = 'probe'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(probe, "1");
    }

    /// [in_write_tx] 在跑 [f] 之前就拿到写锁：闭包里只读，别的连接也已经拿不到写锁（延迟事务这时还没锁，读完再升级
    /// 才会撞 `SQLITE_BUSY_SNAPSHOT`）。已在事务里时报错，外层事务不受影响。
    #[test]
    fn in_write_tx_takes_the_write_lock_before_running() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-write-tx");
        let path = dir.0.join("srs4.db");
        let (c1, c2) = (open(&path).unwrap(), open(&path).unwrap());
        c2.busy_timeout(std::time::Duration::ZERO).unwrap();
        in_write_tx(&c1, |c| {
            let _: i64 = c
                .query_row("SELECT COUNT(*) FROM srs_meta", [], |r| r.get(0))
                .map_err(sql)?;
            let e = c2.execute_batch("BEGIN IMMEDIATE").unwrap_err();
            assert!(e.to_string().contains("locked"), "{e}");
            Ok(())
        })
        .unwrap();
        c2.execute_batch("BEGIN IMMEDIATE; ROLLBACK").unwrap();

        c1.execute_batch("BEGIN").unwrap();
        assert!(in_write_tx(&c1, |_| Ok(())).is_err());
        assert!(!c1.is_autocommit(), "the outer transaction is still open");
        c1.execute_batch("ROLLBACK").unwrap();

        // 闭包报错：整笔回滚，连接回到自动提交。
        let e = in_write_tx(&c1, |c| {
            c.execute("INSERT INTO srs_meta (key, value) VALUES ('gone', '1')", [])
                .map_err(sql)?;
            Err::<(), _>("boom".to_owned())
        })
        .unwrap_err();
        assert_eq!(e, "boom");
        assert!(c1.is_autocommit());
        let n: i64 = c1
            .query_row(
                "SELECT COUNT(*) FROM srs_meta WHERE key = 'gone'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 0);
    }

    /// 复核报的失败形态（G7-3a / G9-3 的两条并发测试在负载下随机报 `database is locked`）：几个线程反复 [open] 同一个
    /// 文件，同时另一个连接不停地开写事务。每次打开都要成功。[open] 改回延迟事务（`in_tx`）跑 [install] 时这条稳定红，
    /// 即使设了忙等（`SQLITE_BUSY_SNAPSHOT` 不经忙等）。
    #[test]
    fn concurrent_opens_under_a_busy_writer_all_succeed() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-open-race");
        let path = dir.0.join("srs4.db");
        drop(open(&path).unwrap());
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let writer = {
            let (path, stop) = (path.clone(), stop.clone());
            std::thread::spawn(move || {
                let conn = open(&path).unwrap();
                conn.busy_timeout(std::time::Duration::from_secs(30))
                    .unwrap();
                let mut i = 0u64;
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    conn.execute_batch("BEGIN IMMEDIATE").unwrap();
                    conn.execute(
                        "INSERT OR REPLACE INTO srs_meta (key, value) VALUES ('w', ?1)",
                        [i.to_string()],
                    )
                    .unwrap();
                    std::thread::sleep(std::time::Duration::from_millis(2));
                    conn.execute_batch("COMMIT").unwrap();
                    // 让出一会儿（真实写者不会不间断地霸着写锁；不让的话是写者饿死别人，与打开无关）。
                    std::thread::sleep(std::time::Duration::from_millis(1));
                    i += 1;
                }
            })
        };
        let openers: Vec<_> = (0..4)
            .map(|_| {
                let path = path.clone();
                std::thread::spawn(move || {
                    for _ in 0..15 {
                        drop(open(&path).unwrap());
                    }
                })
            })
            .collect();
        for o in openers {
            o.join().unwrap();
        }
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        writer.join().unwrap();
    }
}
