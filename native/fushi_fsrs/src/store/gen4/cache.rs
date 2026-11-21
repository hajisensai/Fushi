//! 缓存层（设计 §2.2 的 `notes` / `cards`、§2.3 的统计列、§2.5 的「物化笔记 / 卡片缓存（逐卡重放）」）：出卡、浏览、
//! 统计读的三张表。全部是「索引（`derive.rs` / `weigh.rs`）+ 宿主给的缓存配置」的纯函数：[Index::rebuild_all] 最后
//! 整份物化，[Index::settle] 收尾时只重算这一批碰到的笔记 / 卡，两条路出来的行逐行相同（测试与 `parity.rs` 钉死）。
//!
//! **行值只有一份实现**：从索引拼出协议 3 那批纯函数要的输入——实体的身份记录、活着的修改行（`derive.rs`
//! [Index::edit_lines_as]，冻结判定同一份拼法）、标签（[Index::tags_of]）、日志的投影行 JSON（`store/sync2` 的
//! `log_json`）——再调同一批函数：笔记视图 / 笔记类型视图 / 卡片血统与标志（`crate::registers`）、笔记行与卡行的
//! 列（`store/caches.rs` 的 `note_row` / `card_row` / `Material`）、重放（`crate::sync2::replay`，链尾与归属组的
//! 选取规则 `tails_with` / `group_lineage`）、卡片状态与有效复习投影（`crate::history`）、统计归属与 Anki 副本去重
//! （`caches.rs` 的 `stat_groups` / `anki_duplicate_log_ids`）。这里只有「从哪读、按什么粒度重算、往哪写」。
//!
//! # 表
//!
//! - `notes(col, id, …)`：列与协议 3 的 `srs_notes_cache` 相同（去掉 `profile_uid`）。ID 列存 [Ref]（规范 UUID 16 字节，
//!   其余文本）。
//! - `cards(col, id, …)`：列与 `srs_cards_cache` 相同。行只给「存在的笔记应有的卡」（笔记 × 模板 / cloze 序号）。
//!   出卡（`cmd/study.rs`）的五个部分索引 `cards_new_position` / `cards_new_freq` / `cards_learning` /
//!   `cards_review_due` / `cards_tally` 与协议 3 v9 的 `idx_srs_cards_cache_*` 逐列相同（`profile_uid` 换成 `col`）；
//!   自定义学习「只复习这一作」走 `notes_source`（协议 3 v25 `idx_srs_notes_cache_source`）。
//! - `anki_members(col, kind, num, canon, note)`：AnkiConnect 数字 id 的成员反查（`cmd/columns.rs` 按号查不到规范 ID
//!   的号时走它；G7-4g）。`kind` = [EntKind::Note] / [EntKind::Card]，`num` = 成员 ID 的号（`anki_numeric_id`），
//!   `canon` = 它归到的规范笔记 / 卡（有 `notes` / `cards` 行的那个），`note` = 所属的规范笔记（随笔记的行一起删、
//!   一起重写，[Index::member_numbers]）。笔记的成员 = 别名类里出现过的成员；卡的成员 = 别名类里出现过的成员，
//!   **加上从没在操作里出现过的带盐卡**：笔记的成员 × 模板的成员按卡的公式（`gen4_ids::rules::card`）算出来的 ID
//!   ——协议 3 给从没复习、没改过的卡也发了号（缓存行的 `anki_id`），新代的别名表里没有那个带盐 ID（它只记操作里
//!   出现过的 ID），号从这里来。内置笔记类型的模板从不作为实体出现（只嵌在宿主配置里），它的成员由笔记类型的成员
//!   按规则算（`class.rs` `builtin_template_members`）。每一边都取规范 ID 自己加出现过的成员：随机 ID 的笔记（规范 ID 就是它协议 3 的 ID）配
//!   带盐的模板、带盐的笔记配内置模板时规范 ID 那一边就是旧号的来源，类里另有成员（随机 ID 笔记的旧并入兜底副本，
//!   `gen4_ids::alias` 的 `root_fallbacks`）时也不能丢；规范 ID 是新代才有的那种（带盐的类）多出来的组合没有旧号，
//!   不撞别人的号就无害（与多盐交叉组合是同一类取舍；规范卡自己那个组合不写，它的号在 `cards.anki_id`）。
//!   **量级（第五波定，不收窄到同盐组合）**：一张卡的行数 = (1 + 笔记成员数) × (1 + 模板成员数)。内置模板的成员
//!   由笔记类型的成员按盐各算一个，所以 k 个盐（并入过 k 个 profile 的内置笔记类型）下每张内置笔记的卡是
//!   (k+1)² 行，只配同盐是 k+1 行（加规范自己）；k 实际是 1～2（一个 profile 并入过另一个才是 2），即每卡 4～9 行
//!   对 2～3 行，库按卡线性，不随别的量放大。收窄要在这里认出笔记成员的盐（逐盐 `rules::note(盐, guid)` 对比），
//!   换来的只是少几行无旧号的组合，没收益，不做；交叉组合的号是新 UUID 的号，与真实卡撞号的概率同随机 53 位号。
//!   行是「别名表 + 应有的卡」的函数，所以落在缓存层、随笔记的行维护（别名表变了的行经 [Index::moved_rows] 牵动
//!   所属笔记重算），重建同样物化。
//!   **为什么不在迁移时把协议 3 `srs_cards_cache` 的卡 ID 写进别名表**：别名表是「操作集合 + 盐 + 内置表」的函数
//!   （`alias.rs` 文件头「证据」），`rebuild_all` 会把迁移另写的行清掉；要写进真相只能给每张没出现过的卡造一条身份
//!   记录操作（真相多出与卡数同阶的操作，语义摘要与对拍都跟着变）。这里由同一份真相算出同一批号：迁移出来的库上
//!   协议 3 每张卡的号都查得到（`migrate_tests.rs` `every_protocol_3_card_number_resolves_after_migration`），且可重建。
//! - `stats(col, at, log, card, …)`：有效复习投影（协议 3 的 `srs_stat_reviews`，列 = `history::StatRow`）。`card` 是
//!   **归属卡**（`caches::stat_groups`：日志所属的卡可见就是它，否则是继承它历史的可见卡，归属随血统与可见性变），
//!   按发生时刻聚簇——统计读侧（#3287）那条「全部投影行按时刻
//!   升序」的查询是一次顺序扫、不解码任何操作体。
//!
//! # 取舍（G6c-3 定）
//!
//! - **`updated_at`**：协议 3 是写缓存行那一刻的本机时钟，不是真相的函数（重建一次就变）。这里取「这条笔记活着的
//!   写入里最大的 HLC 物理时刻」：身份记录、没被支配 / 清除 / 扣住的修改（带旧戳的取旧戳的 HLC）、没被清除的标签
//!   操作。语义是「这条笔记的内容最后一次被改的时刻」，换代后读它的浏览排序看到的是内容时间而不是本机刷新时间。
//!   对拍不比这一列。
//! - **`server_time`**：协议 3 里日志与修改的 S(e) 是本机收到它的时刻（迁移来的旧数据是旧戳里那份）；它只当排序键里
//!   给超前 HLC 钳位用。新代只有承袭来的那份（`HeritageStamp.server_time` / `Log4.server_time`），原生操作没有——
//!   没有就不钳位。协议 3 的钳位依赖本机收到的时刻，是本机状态，不搬。
//! - **统计列单独一张表，不并进 `log_ix`**：`log_ix` 是索引层，一条日志操作一行、按日志所属卡排；统计行是重放的输出，
//!   一个规范日志 ID 一行、按归属卡算，归属随血统与可见性变。并进 `log_ix` 会让索引层的逐条维护依赖缓存层的计算，
//!   而且读侧还得另建按时刻的索引。体积代价：每行约 col 1 + at 6 + log 17 + card 17 + 6 个小整数 ≈ 55 B，加按归属卡
//!   的索引约 40 B；样本库的 33 万条有效复习约 30 MB（以样本探针 `gen4_sample_index` 的实测为准）。
//! - **缓存配置**：本机状态表 `derive_cfg` 的 `"caches"` 项（值 = `caches::CacheConfig::parse` 吃的 JSON）。没设 =
//!   不物化（三张表这个集合没有行）：配置只有宿主知道，接线（G7）在第一次重建前写进去；配置变了调
//!   [Index::rebuild_caches]（只重建这一层）。
//!
//! # 别名：**缓存层按规范 ID 物化**（设计 §5.3「别名层接线」，G9-2）
//!
//! 三张表的 ID 列（笔记、笔记类型、牌组、卡、模板、最后一条日志、统计行的卡与日志）都是规范 ID（别名表 `alias.rs`
//! [Index::canonical]）；协议 3 的缓存表是原值 ID，对拍时先把协议 3 一侧改写成规范 ID（`compare.rs` 文件头「按规范
//! ID 比」）。各处：
//!
//! 1. **应有的卡**按规则算：规范笔记 + 规范模板派生规范卡（`gen4_ids::rules::card`，与 `registers::card_id` 同一个公
//!    式），从没出现在操作里的卡也给得出，第一次复习之后不换 ID。宿主给的配置里的内置定义 ID 先归一
//!    （[Index::canonical_config]：查表，表里没有的按内置规则表 `builtin_rule_canon`）。
//! 2. **一个寄存器的写入按整个别名类归并**：活着的写入取 [Index::class_lines]（`class.rs`），类里多个成员、或有归回
//!    的写入者时按类重判；只有一个成员、没有归回写入者的走 `reg_ix` 的现成状态。
//! 3. 修改行 / 日志投影行 JSON 里的 ID 归一（[Index::canonical_json]）；一条规范日志在类里有多份时取最小的那条操作。
//! 4. 标签：成员的 `tag_ix` 行并起来判（[Index::class_tags]）。
//! 5. 别名表变了：`alias.rs` 记下变了规范 ID 的 ID（连同前后的规范 ID，`alias_moves`）与归回写入者变没变
//!    （`writers_moved`）。收尾时逐个 ID 按键找引用它的行（[Index::moved_rows]），已不是规范 ID 的行删掉、按新规范 ID
//!    重算；写入者归回变了或变动的 ID 多于 [MOVES_IN_PLACE] 时整层重建。别名表还没重算（[Index::hold_aliases]）时缓存
//!    不动，攒到重算之后的那次收尾。
//!
//! # 变更记录（`cache_gen` / `cache_log`，G7-4d）
//!
//! 常驻的读者（浏览会话 `cmd/browse.rs`）要知道「上次读过之后缓存行变了哪些」。协议 3 靠写连接上的临时触发器记 id；
//! 这里由刷新自己记：每次收尾里行可能变了的笔记（重算 / 删掉的笔记、写了卡行的卡所属的笔记、别名挪走时被删的旧 ID
//! 与引用它的行的原值笔记 ID）记成一个新的**代号**（`cache_gen.gen` + 1，`cache_log` 每条笔记一行）；整层重建（
//! [Index::materialize_caches] 的三条路）把代号 + 1 并把**下限** `floor` 抬到它、清空记录——代号低于下限的读者只能
//! 整份重读。记录超过 [LOG_KEEP] 行时从代号旧的一头删到剩一半、下限抬到删掉的最大代号（只有比它还旧的读者整份
//! 重读；`logged` = 记录现有行数）。读者一次要重读多少才改成整份重读由读者自己判。两张表是本机状态（不在 `DERIVED_TABLES`、不参与对拍），
//! 与缓存行在同一个事务里写，回滚一起回滚。
//!
//! 没并起来的：清除、不可信仍按原值实体判（`class.rs` 文件头「没有并起来的」）；扣住按类判（G7-4g，`weigh.rs` 文件头
//! 「扣住的删除」），状态记在原值写入上，这里按类拼行时原样拿来。

//! # 与协议 3 的差别（都是「协议 3 依赖到达顺序 / 本机状态」）
//!
//! - `updated_at`、`server_time` 见上。
//! - 不成形的身份记录：笔记身份记录 / 修改算不出视图（缺 `noteTypeId`、字段类型不对）或笔记 ID 不是 UUID（卡 ID 由它
//!   派生）时这条笔记没有行（也没有卡行），
//!   笔记类型算不出时当作不在；协议 3 的 `caches::rebuild` / `refresh` 在这里整次失败。对拍在协议 3 这样失败时不比
//!   缓存三类（`parity.rs` [cache_pairs] 的口径）。
//! - 同一个旧修改记录 ID 下的两条不同修改（复制出来的两份旧库各自以同一个写入者续写了同一个 seq）：新代是两条独立的
//!   操作，都进视图；协议 3 的投影表按修改记录 ID 只存一行，留哪条看先收到哪份。
//! - 推迟的收尾：协议 3 收段会话里推迟的重放（`sync2_replay_pending`）没跑之前，缓存读到的是旧的重放结果；没刷新过的
//!   旧合成标签行（`sync2:tags:<笔记>`）可能与标签 OR-Set 不一致。新代没有推迟的重放，标签直接取 OR-Set。
//! - 重放写回：协议 3 只重放这一批碰到的卡的归属组，结果写回日志行、留到下次被碰到；一条日志落在两个链尾的归属组里
//!   （一张卡被两张后继卡继承）时，留下的是最后一次重放它的那组的结果。这里每次都对整个连通分量按链尾 ID 升序重放，
//!   后一组的结果为准（与协议 3 一次刷新里的顺序相同）。
//!
//! # 粒度
//!
//! 卡的状态取决于它的血统、血统上的日志，而日志的结果取决于它所在归属组的链尾——也就是整个「前身 ↔ 后继」连通分量
//! （链接按 `historyFrom/` 键、不看值，与协议 3 的 `Links` 同口径）。所以重算的单位是连通分量：一批碰到的笔记的卡、碰到
//! 的卡，扩成它们的连通分量，再按「有同一 Anki 复习时刻日志」扩到不动点（统计去重要看全，与协议 3 同）。

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use rusqlite::types::ValueRef;
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

use super::class::builtin_template_members;
use super::derive::{Index, R_LIVE, Ref, Reg, Settled, body_of};
use super::schema::sql;
use crate::anki_import_rules::derived_log_hlc;
use crate::gen4::heritage::SlotBody;
use crate::gen4::name::{read_edit_key, write_edit_key};
use crate::gen4::op::{Body4, Log4};
use crate::gen4_ids::rules;
use crate::history::{self, StoredLog};
use crate::registers::{self, StoredEdit};
use crate::store::caches::{
    self, AnkiStatKey, CacheConfig, Material, NoteInfo, TypeInfo, add_descendants,
    anki_duplicate_log_ids, card_row, note_row, sorted_ids, stat_groups,
};
use crate::store::schema::anki_numeric_id;
use crate::store::sync2::{
    canonical, config, group_lineage, log_json, note_type_key_affects_caches, tails_with,
};
use crate::sync2::codec::{Reader, Writer};
use crate::sync2::id::{Id, Key};
use crate::sync2::op::{EntKind, Intent, LogBody};
use crate::sync2::replay::{Row, replay};

/// 缓存层的表与它用到的索引（`schema.rs` 建表时一起建）。
pub(super) const DDL: &str = "
CREATE TABLE IF NOT EXISTS notes (
  col INTEGER NOT NULL,
  id NOT NULL,
  note_type_id NOT NULL,
  guid TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  deck_id,
  deleted_at INTEGER,
  term_key TEXT NOT NULL,
  reading_key TEXT NOT NULL,
  sort_field TEXT NOT NULL,
  tags_json TEXT NOT NULL,
  pending_decision INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  media_refs TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  source_title TEXT NOT NULL,
  anki_id INTEGER NOT NULL,
  dupe_norm TEXT NOT NULL,
  source_key TEXT NOT NULL,
  PRIMARY KEY (col, id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS notes_type ON notes (col, note_type_id);
CREATE INDEX IF NOT EXISTS notes_deck ON notes (col, deck_id);
CREATE INDEX IF NOT EXISTS notes_term ON notes (col, term_key);
CREATE INDEX IF NOT EXISTS notes_pending ON notes (col) WHERE pending_decision = 1;
CREATE INDEX IF NOT EXISTS notes_anki ON notes (col, anki_id);
CREATE INDEX IF NOT EXISTS notes_dupe ON notes (col, dupe_norm);
CREATE TABLE IF NOT EXISTS cards (
  col INTEGER NOT NULL,
  id NOT NULL,
  note_id NOT NULL,
  template_id NOT NULL,
  cloze_ord INTEGER NOT NULL,
  deck_id NOT NULL,
  suspended INTEGER NOT NULL,
  buried_until_day INTEGER,
  flag INTEGER NOT NULL,
  hidden INTEGER NOT NULL,
  queue TEXT NOT NULL,
  due_day INTEGER,
  due_at INTEGER,
  scheduled_days INTEGER NOT NULL,
  reps INTEGER NOT NULL,
  lapses INTEGER NOT NULL,
  stability REAL,
  difficulty REAL,
  last_reviewed_at INTEGER,
  last_log_id,
  scheduler TEXT NOT NULL,
  note_created_at INTEGER NOT NULL,
  new_position INTEGER,
  freq_rank INTEGER,
  anki_id INTEGER NOT NULL,
  PRIMARY KEY (col, id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS cards_note ON cards (col, note_id);
-- 实体归属闸（cmd/writes_owner.rs）：按卡 ID 问别的集合有没有这张卡。col > 0 同 schema.rs 的 ent_id（只有归属闸的
-- 查询用得上）。
CREATE INDEX IF NOT EXISTS cards_id ON cards (id) WHERE col > 0;
CREATE INDEX IF NOT EXISTS cards_deck ON cards (col, deck_id);
CREATE INDEX IF NOT EXISTS cards_template ON cards (col, template_id);
CREATE INDEX IF NOT EXISTS cards_anki ON cards (col, anki_id);
CREATE INDEX IF NOT EXISTS cards_new_position ON cards
  (col, new_position IS NULL, new_position, note_created_at, id, deck_id, buried_until_day,
   queue, hidden, suspended, scheduler)
  WHERE queue = 'new' AND hidden = 0 AND suspended = 0 AND scheduler = 'fushi';
CREATE INDEX IF NOT EXISTS cards_new_freq ON cards
  (col, freq_rank IS NULL, freq_rank, new_position IS NULL, new_position, note_created_at, id, deck_id,
   buried_until_day, queue, hidden, suspended, scheduler)
  WHERE queue = 'new' AND hidden = 0 AND suspended = 0 AND scheduler = 'fushi';
CREATE INDEX IF NOT EXISTS cards_learning ON cards
  (col, COALESCE(due_at, 0), id, deck_id, buried_until_day, due_at, queue, hidden, suspended, scheduler)
  WHERE queue IN ('learning', 'relearning') AND hidden = 0 AND suspended = 0 AND scheduler = 'fushi';
CREATE INDEX IF NOT EXISTS cards_review_due ON cards
  (col, deck_id, COALESCE(due_day, 0), buried_until_day, last_reviewed_at, stability, id, due_at, due_day,
   queue, hidden, suspended, scheduler)
  WHERE queue = 'review' AND hidden = 0 AND suspended = 0 AND scheduler = 'fushi';
CREATE INDEX IF NOT EXISTS cards_tally ON cards
  (col, deck_id, queue, due_day, due_at, suspended, scheduler, buried_until_day)
  WHERE hidden = 0;
CREATE INDEX IF NOT EXISTS notes_source ON notes (col, source_key) WHERE deleted_at IS NULL;
CREATE TABLE IF NOT EXISTS stats (
  col INTEGER NOT NULL,
  at INTEGER NOT NULL,
  log NOT NULL,
  card NOT NULL,
  utc_offset_min INTEGER NOT NULL,
  rating INTEGER,
  kind INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL,
  prev_due_day INTEGER,
  maturity_delta INTEGER NOT NULL,
  PRIMARY KEY (col, at, log)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS stats_card ON stats (col, card);
CREATE TABLE IF NOT EXISTS anki_members (
  col INTEGER NOT NULL,
  kind INTEGER NOT NULL,
  num INTEGER NOT NULL,
  canon NOT NULL,
  note NOT NULL,
  PRIMARY KEY (col, kind, num, canon)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS anki_members_note ON anki_members (col, note);
CREATE INDEX IF NOT EXISTS reg_card_key ON reg_ix (col, key) WHERE ekind = 4;
CREATE INDEX IF NOT EXISTS log_at ON log_ix (col, at);
CREATE TABLE IF NOT EXISTS cache_gen (
  col INTEGER PRIMARY KEY,
  gen INTEGER NOT NULL,
  floor INTEGER NOT NULL,
  logged INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS cache_log (
  col INTEGER NOT NULL,
  gen INTEGER NOT NULL,
  note NOT NULL,
  PRIMARY KEY (col, gen, note)
) WITHOUT ROWID;
";

/// 变更记录（[Index::cache_log_flush]）最多留这么多行；再多就从代号旧的一头删到剩一半、把下限抬到删掉的最大代号。
/// 这只是给记录本身的存储设上限：读者攒了多少要重读由读者自己判（`cmd/browse.rs` 的 `REFRESH_CAP`，同协议 3 浏览的
/// `DIRTY_CAP` 按单个会话算），跟得上的读者不会因为别人累计的写入被迫整份重读。
pub(crate) const LOG_KEEP: i64 = 20_000;

/// 缓存层的表（三张缓存表与数字 id 的成员反查表）。
const TABLES: [&str; 4] = ["notes", "cards", "stats", "anki_members"];

/// `derive_cfg` 里缓存配置的键。
pub const CFG_KEY: &str = "caches";

/// `derive_cfg` 里「缓存层按哪一版推导口径物化的」的键（文件头「缓存配置」）。值是 [CACHE_RULES] 的十进制文本；没有 =
/// 0（这个口径之前建的库）。
pub const RULES_KEY: &str = "cacheRules";

/// 缓存层推导口径修订号：同一份真相、同一份缓存配置算出的缓存行变了（规则改了）时 +1，并在这里记一行。整份物化
/// （[Index::materialize_caches]，`rebuild_all` / `rebuild_caches` 的最后一步）写下当前值；`cache_config_set`（宿主每次
/// 打开都发，`dispatch.rs`）发现库里记的不是当前值就整层重建一次——已有的新代库不必等配置变了才换上新口径。
/// 真相不动、线格式不动，所以不升 schema；不进 head 的 `derive`（摘要不含缓存行，`digest.rs`）。
///
/// - 1（K3，交接 §26 C4）：Anki 来源日志的排序键改为来源数据派生的 HLC（[log_body]、`crate::anki_import_rules`）。之前
///   新导入的 Anki 日志按操作 HLC 排：同一条 revlog 在血统两张卡上的副本各算一次、更早的 Anki 复习排到原生复习之后
///   覆盖当前排程。
/// - 2（第五波，交接 §38「第五波 导入与写接口」）：回导的外来原生日志（带 `foreignLog` 标记，Dart `_remapExtLog`）的排序键改为
///   由发生时刻派生的 HLC（`crate::anki_import_rules::derived_log_hlc`）。之前按导入时刻的操作 HLC 排：更早的外来复习排到
///   本机更晚的复习之后、改掉当前排程。
/// - 3（第六波，交接 §44「第六波 导入红测试收尾」）：同一派生加上界——外来日志的发生时刻晚于载着它的那条操作时不派生、
///   回落到操作 HLC（第五波复核修复，`derived_log_hlc` 的 `op_wall`）。2 推出时还没有这道上界，按 2 物化过的开发库里
///   带未来时刻的外来日志排在派生位置上，要重建一次才换成新口径。
/// - 4（嵌套并入的改名写入者）：按类判时改名写入者的旧上下文只换到归回证据撑得住的 seq 上界（`class.rs` 的
///   `Canon::dvv`，上界记在 `derive_cfg` 的 `alias::WRITER_UPTO_KEY`）。之前整段换：被并入两次的库里，中间那份库的
///   `{merged-…: n}` 把最初写入者名下 seq ≤ n、它其实没见过的写入判成已被覆盖（冲突变支配）。整层重建才写下上界。
pub const CACHE_RULES: i64 = 4;

/// [Index::log_class_rep] 每个成员一次的点查（走 `log_id (col, id, k)`；查询计划测试用同一份）。
pub(crate) const LOG_REP_SQL: &str =
    "SELECT k, at, card FROM log_ix WHERE col = ?1 AND id = ?2 AND win = 1";

/// 一批碰到的东西里缓存层要重看的（[Index::settle] 边判边记，收尾时 [Index::refresh_caches] 用掉）。
#[derive(Default, Debug)]
pub(crate) struct Dirt {
    /// (实体种类, 实体)：内容操作、寄存器状态、标签、日志碰过的。
    pub(super) entities: BTreeSet<(i64, Ref)>,
    /// 身份记录进出过的 ID（种类到用时再查）。
    pub(super) ids: BTreeSet<Ref>,
    /// 旧闭包变了：不带旧戳的写入「见过谁」可能变了，有活着的删除的笔记要重看「待裁决」。
    pub(super) closure: bool,
}

impl Dirt {
    pub(super) fn entity(&mut self, ekind: i64, ent: &Ref) {
        self.entities.insert((ekind, ent.clone()));
    }

    /// 一个寄存器（写入落库、状态重判变了）要不要让缓存层重看它的实体：笔记类型只看影响缓存行的键（协议 3
    /// `note_type_key_affects_caches` 同一条规则：名字、CSS、字段说明只在渲染 / 编辑时读，不进笔记 / 卡行），别的
    /// 种类一律要。笔记类型脏了就要把这一类的全部笔记重算（[Index::refresh_caches]），所以这几个键不能记脏（H5 读放大）。
    pub(super) fn register(&mut self, r: &Reg) -> Result<(), String> {
        if r.ekind == EntKind::NoteType as i64 {
            let key = read_edit_key(&mut Reader::new(&r.key))
                .map_err(|e| format!("gen4 cache: register key: {e}"))?;
            if !note_type_key_affects_caches(&key) {
                return Ok(());
            }
        }
        self.entity(r.ekind, &r.ent);
        Ok(())
    }

    pub(super) fn registers(&mut self, regs: &BTreeSet<Reg>) -> Result<(), String> {
        for r in regs {
            self.register(r)?;
        }
        Ok(())
    }

    /// 收尾时一批碰过的实体（`Index::touched`，扣住 / 清除按它重看）：笔记类型不从这里记脏——它被碰过只因为写入
    /// （由 [Dirt::register] 按键判）、清除（`derive.rs` 落 `Purge` 时直接记）或重判（同 [Dirt::register]），各自已记。
    pub(super) fn touched(&mut self, ents: &BTreeSet<(i64, Ref)>) {
        for (ekind, ent) in ents {
            if *ekind != EntKind::NoteType as i64 {
                self.entity(*ekind, ent);
            }
        }
    }
}

/// 一条笔记应有的一张卡（笔记那边算好的列）。
struct Plan {
    note: Ref,
    template: Ref,
    ord: i64,
    hidden: bool,
    created: i64,
    freq: Option<i64>,
    note_deck: Option<String>,
}

/// 一条日志（规范日志 ID 的代表）在缓存层的样子（读命令 `cmd/` 也读它）。
pub(super) struct LogIn {
    pub(super) json: String,
    pub(super) server_time: Option<i64>,
    intent: Intent,
    /// 代表这条日志的操作主键（`log_ix.k`；本机落库序另在 `log_seq`，`cmd/training.rs` 文件头「rowid」）。
    pub(super) k: i64,
    /// 日志上记的笔记（原值，未归一；协议 3 `sync2_log_meta.note_id`）。用到的地方自己归一，缓存层的重放不付这份代价。
    pub(super) note: Option<Ref>,
    /// 日志上记的卡（原值，未归一）：重放的 fuzz 种子（`sync2/replay.rs` [Row::seed_card]）。[json] 里的 `card` 已归一成
    /// 规范卡；种子跟着换的话，带盐的存量日志迁移后到期日会变。
    pub(super) seed_card: String,
}

/// 归属组的一行重放输入（[Index::group_rows]）：(投影行 JSON, server_time, 意图, fuzz 种子用的原值卡)。
pub(super) type GroupRow = (String, Option<i64>, Intent, String);

/// 统计去重要跨批看的东西（全量重建时一批一个或几个连通分量）。
#[derive(Default)]
struct StatAcc {
    keys: Vec<AnkiStatKey>,
    owners: Vec<String>,
    visible: HashSet<String>,
    note_of: HashMap<String, String>,
    at_of: HashMap<String, i64>,
}

/// 一批卡（若干个完整的连通分量）。
const BATCH: usize = 512;

/// 别名表一次收尾里变了的 ID（连同它们前后的规范 ID）超过这么多就整层重建，不逐个找引用它们的行（[Index::moved_rows]
/// 每个 ID 扫一遍三张表；盐集合变了这类情形整张别名表都会动）。
/// 扣住（`weigh.rs` `weigh_rest`）用同一个阈值：多了就与重建一样看全部有删除的实体。
pub(super) const MOVES_IN_PLACE: usize = 256;

/// 一批卡的血统（`Index::lineage`）：卡 ID（文本）→ 活着的修改行 / 重放写回的日志 / 生效的前身 / 后继。
struct Lineage {
    lines: BTreeMap<String, Vec<(String, Option<i64>)>>,
    logs: HashMap<String, Vec<LogIn>>,
    preds: HashMap<String, Vec<String>>,
    succs: HashMap<String, Vec<String>>,
}

/// 「前身 → 后继」链接（`historyFrom/` 键、不看值）：按卡按需查，查过的记下。
#[derive(Default)]
struct Links {
    succ: HashMap<Ref, Vec<Ref>>,
    pred: HashMap<Ref, Vec<Ref>>,
}

fn key_bytes(key: &str) -> Vec<u8> {
    let mut w = Writer::new();
    write_edit_key(&mut w, key);
    w.into_vec()
}

/// 修改键里 `historyFrom/` 后面的卡 ID。
fn history_from(key: &[u8]) -> Result<Option<String>, String> {
    let k = read_edit_key(&mut Reader::new(key)).map_err(|e| format!("gen4 cache: {e}"))?;
    Ok(k.strip_prefix("historyFrom/").map(str::to_owned))
}

fn ref_of(text: &str) -> Ref {
    Ref::of(&Key::of(text))
}

/// [op_wall]：载着这条日志的操作 HLC 的物理时刻（外来日志派生排序键的上界，[derived_log_hlc]）。
fn log_body(l: Log4, op_wall: i64) -> LogBody {
    // 承袭的日志带作者给的旧 HLC；原生日志没有，排序键回落到操作自己的 HLC（[Index::log_at]）——Anki 来源与回导的外来
    // 原生日志除外：它们的 HLC 由来源数据派生（铁律 C，`crate::anki_import_rules` [derived_log_hlc]）。协议 3 的卡片历史
    // 规则（`crate::history`）靠它把同一条 revlog 落在血统里几张卡上的副本归成一个事件、把更早的 Anki / 外来复习排在
    // 更晚的原生复习之前。
    let legacy_hlc = match l.hlc {
        Some(h) => Some(h.text()),
        None => derived_log_hlc(&l.origin, &l.kind, l.anki_id, l.at, &l.extra, op_wall),
    };
    LogBody {
        id: l.id,
        card: l.card,
        note: l.note,
        kind: l.kind,
        rating: l.rating,
        revokes: l.revokes,
        at: l.at,
        ts: l.ts,
        origin: l.origin,
        rtype: l.rtype,
        dur: l.dur,
        params: l.params,
        alg: l.alg,
        utc_off: l.utc_off,
        rollover: l.rollover,
        anki_id: l.anki_id,
        fv: l.fv,
        intent: l.intent,
        res: l.res,
        extra: l.extra,
        legacy_hlc,
        legacy_server_time: l.server_time,
    }
}

fn is_anki_review(l: &Log4) -> bool {
    l.origin == "anki" && (l.kind == "review" || l.kind == "manual")
}

impl<'t, 'c> Index<'t, 'c> {
    // ------------------------------------------------------------ 别名的接缝

    /// 一个 ID 的规范 ID（设计 §5.3，别名表 `alias.rs` [Index::canonical]）。
    pub fn canon(&self, id: &Ref) -> Result<Ref, String> {
        self.canonical(id)
    }

    /// 一个 ID 所在的别名类：规范 ID 在前，其后是归到它的、出现过的原值 ID（升序）。
    pub fn class_of(&self, id: &Ref) -> Result<Vec<Ref>, String> {
        let canon = self.canonical(id)?;
        let mut out = vec![canon.clone()];
        out.extend(self.members(&canon)?.into_iter().filter(|m| *m != canon));
        Ok(out)
    }

    /// 文本形式的 ID（嵌在修改键 / 值里的）的规范形。
    pub fn canon_text(&self, text: &str) -> Result<String, String> {
        Ok(self.canon(&ref_of(text))?.text())
    }

    // ------------------------------------------------------------ 入口

    /// 这个集合的缓存配置（已按规范 ID 归一）；没设 = None（缓存层没物化，三张表这个集合没有行）。
    pub(crate) fn cache_config(&self) -> Result<Option<CacheConfig>, String> {
        let Some(text) = self.t.derive_cfg(self.col, CFG_KEY)? else {
            return Ok(None);
        };
        let v: Value =
            serde_json::from_str(&text).map_err(|e| format!("gen4 cache: bad config: {e}"))?;
        // 配置里的 ID 是宿主给的，可能是带盐的存量 ID、也可能没在操作里出现过：按规范 ID 物化之前先归一（文件头「别名」）。
        Ok(Some(CacheConfig::parse(&self.canonical_config(&v)?)?))
    }

    /// 只重建缓存层（缓存配置变了之后调；索引不动）。在调用方的事务里。
    pub fn rebuild_caches(&mut self) -> Result<Settled, String> {
        self.writing()?;
        for table in TABLES {
            self.t
                .conn()
                .execute(&format!("DELETE FROM {table} WHERE col = ?1"), [self.col])
                .map_err(sql)?;
        }
        let mut out = Settled::default();
        self.materialize_caches(&mut out)?;
        Ok(out)
    }

    /// 整份物化（[Index::rebuild_all] 的最后一步；表已经清空）。
    pub(super) fn materialize_caches(&mut self, out: &mut Settled) -> Result<(), String> {
        self.dirt = Dirt::default();
        self.alias_moves.clear();
        self.writers_moved = false;
        self.cache_touched.clear();
        self.cache_log_flush(true)?;
        let Some(cfg) = self.cache_config()? else {
            return Ok(());
        };
        let notes: BTreeSet<Ref> = {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached("SELECT id FROM ent_ix WHERE col = ?1 AND kind = ?2 AND win = 1")
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![self.col, EntKind::Note as i64], |r| {
                    r.get::<_, Ref>(0)
                })
                .map_err(sql)?;
            let mut out = BTreeSet::new();
            for r in rows {
                out.insert(self.canon(&r.map_err(sql)?)?);
            }
            out
        };
        self.cache_pass(&cfg, notes, BTreeSet::new(), true, out)?;
        // 整份物化完：这一层是按当前推导口径建的（[CACHE_RULES]）。
        self.t
            .set_derive_cfg(self.col, RULES_KEY, Some(&CACHE_RULES.to_string()))?;
        Ok(())
    }

    /// 收尾（[Index::settle] 的最后一步）：只重算这一批碰到的。别名表还没重算（[Index::hold_aliases] 攒着）时不动、
    /// 攒着的东西留到别名表重算之后的那次收尾：缓存行按规范 ID 建，拿旧别名表算出来的行是错的。
    pub(super) fn refresh_caches(&mut self, out: &mut Settled) -> Result<(), String> {
        if self.aliases_stale() {
            return Ok(());
        }
        let dirt = std::mem::take(&mut self.dirt);
        let moves = std::mem::take(&mut self.alias_moves);
        let writers_moved = std::mem::take(&mut self.writers_moved);
        let Some(cfg) = self.cache_config()? else {
            return Ok(());
        };
        if writers_moved || moves.len() > MOVES_IN_PLACE {
            // 归回的写入者变了（按类判定的寄存器都可能变），或别名表大面积变了（盐集合变了之类）：整层重建。
            for table in TABLES {
                self.t
                    .conn()
                    .execute(&format!("DELETE FROM {table} WHERE col = ?1"), [self.col])
                    .map_err(sql)?;
            }
            return self.materialize_caches(out);
        }
        let (note, notetype, card) = (
            EntKind::Note as i64,
            EntKind::NoteType as i64,
            EntKind::Card as i64,
        );
        let mut notes: BTreeSet<Ref> = BTreeSet::new();
        let mut types: BTreeSet<Ref> = BTreeSet::new();
        let mut cards: BTreeSet<Ref> = BTreeSet::new();
        for (kind, ent) in &dirt.entities {
            let ent = self.canon(ent)?;
            match *kind {
                k if k == note => notes.insert(ent),
                k if k == notetype => types.insert(ent),
                k if k == card => cards.insert(ent),
                _ => false,
            };
        }
        for id in &dirt.ids {
            // 身份记录进出：按现在的定义认种类（类里任何一个成员）；定义没了的，按缓存里它曾经是什么认。
            let id = self.canon(id)?;
            let mut kinds: Vec<i64> = Vec::new();
            for m in self.class_of(&id)? {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached("SELECT DISTINCT kind FROM ent_ix WHERE col = ?1 AND id = ?2")
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, m], |r| r.get(0))
                    .map_err(sql)?;
                for k in rows {
                    kinds.push(k.map_err(sql)?);
                }
            }
            notes.insert(id.clone());
            types.insert(id.clone());
            if kinds.contains(&card) {
                cards.insert(id);
            }
        }
        // 别名表变了（`alias.rs` 记的：变了规范 ID 的 ID 与它前后的规范 ID）：按新表的规范 ID 重看，引用过这些 ID 的
        // 行也重看；不再是规范 ID 的那些 ID 名下的行删掉（行只按规范 ID 存）。
        let mut raw: BTreeSet<Ref> = BTreeSet::new();
        for r in &moves {
            self.moved_rows(r, &mut notes, &mut cards, &mut raw)?;
            let c = self.canon(r)?;
            notes.insert(c.clone());
            types.insert(c.clone());
            cards.insert(c);
        }
        if dirt.closure {
            // 「待裁决」看删除与内容修改并不并发，答案经旧闭包：有活着的删除的笔记重看。
            let mut stmt = self
                .t
                .conn()
                .prepare_cached(
                    "SELECT DISTINCT ent FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND key = ?3 AND state >= ?4",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![self.col, note, key_bytes("deleted"), R_LIVE], |r| {
                    r.get::<_, Ref>(0)
                })
                .map_err(sql)?;
            for r in rows {
                notes.insert(self.canon(&r.map_err(sql)?)?);
            }
        }
        for t in &types {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached("SELECT id FROM notes WHERE col = ?1 AND note_type_id = ?2")
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![self.col, t], |r| r.get::<_, Ref>(0))
                .map_err(sql)?;
            for r in rows {
                notes.insert(r.map_err(sql)?);
            }
        }
        // 只当笔记类型看的 ID：不是笔记就从笔记集合里拿掉（没有定义、也没有缓存行的会在笔记那一步自然跳过）。
        if !(notes.is_empty() && cards.is_empty()) {
            self.cache_pass(&cfg, notes, cards, false, out)?;
        }
        self.cache_touched.extend(raw);
        self.cache_log_flush(false)
    }

    /// 把这一趟记下的笔记（[Index::cache_touched]）写成一个新代号的变更记录（文件头「变更记录」）；[full] = 整层重建：
    /// 代号 + 1、下限抬到它、清空记录。没有要记的、也不是整层重建 = 什么都不写。在调用方的写事务里。
    pub(super) fn cache_log_flush(&mut self, full: bool) -> Result<(), String> {
        let touched = std::mem::take(&mut self.cache_touched);
        if !full && touched.is_empty() {
            return Ok(());
        }
        let conn = self.t.conn();
        let (gen, floor, logged): (i64, i64, i64) = conn
            .prepare_cached("SELECT gen, floor, logged FROM cache_gen WHERE col = ?1")
            .map_err(sql)?
            .query_row([self.col], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .optional()
            .map_err(sql)?
            .unwrap_or((0, 0, 0));
        let next = gen + 1;
        let (floor, logged) = if full {
            conn.prepare_cached("DELETE FROM cache_log WHERE col = ?1")
                .map_err(sql)?
                .execute([self.col])
                .map_err(sql)?;
            (next, 0)
        } else {
            let mut logged = logged;
            let mut stmt = conn
                .prepare_cached(
                    "INSERT OR IGNORE INTO cache_log (col, gen, note) VALUES (?1, ?2, ?3)",
                )
                .map_err(sql)?;
            for n in &touched {
                logged += stmt.execute(params![self.col, next, n]).map_err(sql)? as i64;
            }
            let mut floor = floor;
            if logged > LOG_KEEP {
                // 记录攒多了：从旧的一头删到剩一半，下限抬到删掉的最大代号（文件头「变更记录」）。只有对上的代号比它
                // 还旧的读者要整份重读；跟得上的读者不受影响。
                let cut: Option<i64> = conn
                    .prepare_cached(
                        "SELECT gen FROM cache_log WHERE col = ?1 ORDER BY gen DESC LIMIT 1 OFFSET ?2",
                    )
                    .map_err(sql)?
                    .query_row(params![self.col, LOG_KEEP / 2], |r| r.get(0))
                    .optional()
                    .map_err(sql)?;
                if let Some(cut) = cut {
                    let gone = conn
                        .prepare_cached("DELETE FROM cache_log WHERE col = ?1 AND gen <= ?2")
                        .map_err(sql)?
                        .execute(params![self.col, cut])
                        .map_err(sql)?;
                    logged -= gone as i64;
                    floor = floor.max(cut);
                }
            }
            (floor, logged)
        };
        conn.prepare_cached(
            "INSERT OR REPLACE INTO cache_gen (col, gen, floor, logged) VALUES (?1, ?2, ?3, ?4)",
        )
        .map_err(sql)?
        .execute(params![self.col, next, floor, logged])
        .map_err(sql)?;
        Ok(())
    }

    // ------------------------------------------------------------ 读索引

    /// 一个实体（规范 ID）的定义：(种类, 操作主键, 身份记录的数据，嵌的 ID 已归一)。类里不止一个成员有定义时取归一后
    /// 规范 JSON 文本最小的、再取操作号最小的（[Index] 选一个 ID 的定义的同一个规则搬到类上，与到达顺序无关）。
    pub(super) fn definition(&self, id: &Ref) -> Result<Option<(i64, i64, Value)>, String> {
        let canon = self.canon(id)?;
        let mut best: Option<((String, crate::sync2::vv::OpId), (i64, i64, Value))> = None;
        for m in self.class_of(&canon)? {
            let row: Option<(i64, i64)> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT kind, k FROM ent_ix WHERE col = ?1 AND id = ?2 AND win = 1",
                    )
                    .map_err(sql)?;
                let mut rows = stmt.query(params![self.col, m]).map_err(sql)?;
                match rows.next().map_err(sql)? {
                    Some(r) => Some((r.get(0).map_err(sql)?, r.get(1).map_err(sql)?)),
                    None => None,
                }
            };
            let Some((kind, k)) = row else { continue };
            let e = self
                .t
                .entry_by_key(k)?
                .ok_or_else(|| format!("gen4 cache: entity row {k} has no op"))?;
            if let Some(Body4::Entity { kind: ek, data, .. }) = body_of(&e) {
                // 协议 3 `project_entity` 存的就是这份数据的规范 JSON。
                let d: Value = serde_json::from_str(&data).unwrap_or(Value::Null);
                let d = self.canonical_json(&d)?;
                let rec = json!({"id": canon.text(), "p": "", "k": ek.wire(), "d": d}).to_string();
                let rank = (rec, e.id);
                if best.as_ref().is_none_or(|(b, _)| rank < *b) {
                    best = Some((rank, (kind, k, d)));
                }
            }
        }
        Ok(best.map(|(_, d)| d))
    }

    /// 一个实体（规范 ID）按类判定活着的修改行（寄存器内核的输入，规范形）与其中最大的 HLC 物理时刻（没有 = 0）：
    /// `class.rs` [Index::class_lines]（文件头「别名」第 2、3 条）。
    fn live_lines(
        &mut self,
        kind: EntKind,
        id: &Ref,
    ) -> Result<(Vec<(String, Option<i64>)>, i64), String> {
        self.class_lines(kind, id)
    }

    /// 一条笔记（规范 ID [n]）的视图摘要（`caches::NoteInfo`：笔记类型、字段、标签、牌组、删除、出处……）：身份记录
    /// 的胜者 + 按类判定活着的修改 + 类里各成员的标签并起来判。返回 (身份记录的操作主键, 活着的修改里最大的 HLC 物理
    /// 时刻, 摘要)。笔记行的物化与读命令（`cmd/columns.rs` 的 `anki_notes_info`）共用这一份。
    ///
    /// 不是笔记（只是种类未定的 ID）、身份记录没了、或身份记录不成形（缺 `noteTypeId`、字段类型不对）= None：真相里的
    /// 操作来自别的设备，一条坏操作不能让整个索引层的收尾失败。协议 3 在这里让整次刷新失败（文件头「与协议 3 的差别」）。
    pub(super) fn note_info(&mut self, n: &Ref) -> Result<Option<(i64, i64, NoteInfo)>, String> {
        let def = self
            .definition(n)?
            .filter(|(kind, ..)| *kind == EntKind::Note as i64);
        let Some((_, def_k, payload)) = def else {
            return Ok(None);
        };
        let (lines, edited) = self.live_lines(EntKind::Note, n)?;
        let stored: Vec<StoredEdit<'_>> =
            lines.iter().map(|(j, s)| (j.as_str(), *s, None)).collect();
        let Ok(mut view) = registers::note_view_of(&payload, &stored) else {
            return Ok(None);
        };
        // 协议 3 把 OR-Set 的结果写成一条合成的 `tags` 修改行再交给视图；这里直接给结果，同一个值。类里各成员的
        // 标签操作并起来判（文件头「别名」第 4 条）。
        view["t"] = json!(self.class_tags(n)?);
        Ok(Some((def_k, edited, NoteInfo::of(&n.text(), &view))))
    }

    /// 一条笔记（规范 ID）没被清除的标签操作里最大的 HLC 物理时刻（没有 = 0）。
    fn tag_time(&self, note: &Ref) -> Result<i64, String> {
        let mut top = 0;
        for m in self.class_of(note)? {
            let ks: Vec<i64> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT DISTINCT k FROM tag_ix WHERE col = ?1 AND note = ?2 AND state >= 0",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, m], |r| r.get(0))
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            for k in ks {
                if let Some(h) = self.t.head_by_key(k)? {
                    top = top.max(h.wall);
                }
            }
        }
        Ok(top)
    }

    /// 一张卡（规范 ID）的日志：每个规范日志 ID 一条，按代表的 (发生时刻, 操作主键)。代表是这个规范日志 ID 的全部
    /// 份（类里每个原值日志 ID 落在任何卡上的每一条）里操作号最小的那条（`log_ix.win` 的规则搬到类上，设计 §5.3
    /// `logs_of_class`）；代表落在这张卡的类里，这条日志才算这张卡的。规范日志 ID 只有一个成员时就是 `win = 1` 那条。
    pub(super) fn card_logs(&self, card: &Ref) -> Result<Vec<LogIn>, String> {
        let mut reps: BTreeMap<Ref, (i64, i64)> = BTreeMap::new();
        let class = self.class_of(card)?;
        for m in &class {
            let rows: Vec<(i64, Ref, i64)> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT k, id, at FROM log_ix WHERE col = ?1 AND card = ?2 AND win = 1 ORDER BY at, k",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, m], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                    })
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            for (k, id, at) in rows {
                let canon = self.canon(&id)?;
                if reps.contains_key(&canon) {
                    continue;
                }
                let log_class = self.class_of(&canon)?;
                let pick = if log_class.len() == 1 {
                    Some((at, k))
                } else {
                    self.log_rep(&log_class, &class)?
                };
                if let Some(p) = pick {
                    reps.insert(canon, p);
                }
            }
        }
        let mut order: Vec<(i64, i64)> = reps.into_values().collect();
        order.sort_unstable();
        order.into_iter().map(|(_, k)| self.log_at(k)).collect()
    }

    /// 一个规范日志 ID（类 [log_class]）的代表：全部份里操作号最小的；它落在 [cards] 里才返回 (发生时刻, 操作主键)。
    fn log_rep(&self, log_class: &[Ref], cards: &[Ref]) -> Result<Option<(i64, i64)>, String> {
        Ok(self
            .log_class_rep(log_class)?
            .filter(|(_, _, card)| cards.contains(card))
            .map(|(k, at, _)| (at, k)))
    }

    /// 一个规范日志 ID（类 [log_class]：规范 ID 与出现过的成员）的代表：类里每个成员的 `win = 1` 行（每个原值日志 ID
    /// 操作号最小的那份）中操作号最小的那条，(操作主键, 发生时刻, 落在哪张卡上（原值）)；类里一条日志都没有 = None。
    /// 「按类取代表」只有这一份：缓存层的 [Index::card_logs]、`cmd/training.rs` 的 RWKV 尾巴都调它。
    pub(crate) fn log_class_rep(
        &self,
        log_class: &[Ref],
    ) -> Result<Option<(i64, i64, Ref)>, String> {
        let mut best: Option<(crate::sync2::vv::OpId, i64, i64, Ref)> = None;
        for id in log_class {
            let mut stmt = self.t.conn().prepare_cached(LOG_REP_SQL).map_err(sql)?;
            let rows: Vec<(i64, i64, Ref)> = stmt
                .query_map(params![self.col, id], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                })
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for (k, at, card) in rows {
                let op = self.t.id_of_key(k)?;
                if best.as_ref().is_none_or(|b| op < b.0) {
                    best = Some((op, k, at, card));
                }
            }
        }
        Ok(best.map(|(_, k, at, card)| (k, at, card)))
    }

    /// 一条日志操作的投影行（协议 3 `log_row` 同一份拼法）。
    pub(super) fn log_at(&self, k: i64) -> Result<LogIn, String> {
        let e = self
            .t
            .entry_by_key(k)?
            .ok_or_else(|| format!("gen4 cache: log row {k} has no op"))?;
        let (wall, logical) = match &e.body {
            SlotBody::Op(op) => (op.hlc.wall, op.hlc.logical),
            SlotBody::Raw3(raw) => {
                let h = raw.hlc();
                (h.wall, h.logical)
            }
            _ => return Err(format!("gen4 cache: log row {k} is not an op")),
        };
        let Some(Body4::Log(l)) = body_of(&e) else {
            return Err(format!("gen4 cache: log row {k} is not a log"));
        };
        let (server_time, intent) = (l.server_time, l.intent.clone());
        let note = l.note.as_ref().map(Ref::of);
        let seed_card = Ref::of(&l.card).text();
        let device = e.id.device;
        // 投影行里的 profile 只是协议 3 的分区列，读侧不用；集合内取常量。
        let row = log_json("", &log_body(l, wall), || {
            format!("{wall}:{logical}:{}", device.text())
        });
        // 日志 ID、卡、笔记、`revokes` 归一（文件头「别名」第 3 条）：重放与统计读的是规范 ID。
        let row = self.canonical_json(&row)?;
        Ok(LogIn {
            json: canonical(&row),
            server_time,
            intent,
            k,
            note,
            seed_card,
        })
    }

    // ------------------------------------------------------------ 链接

    /// 一张卡的后继与前身（`historyFrom/` 键、不看值；活着的修改）。
    fn load_links(&self, links: &mut Links, card: &Ref) -> Result<(), String> {
        if links.succ.contains_key(card) {
            return Ok(());
        }
        let mut succ: BTreeSet<Ref> = BTreeSet::new();
        let mut pred: BTreeSet<Ref> = BTreeSet::new();
        for m in self.class_of(card)? {
            {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT DISTINCT ent FROM reg_ix WHERE col = ?1 AND ekind = 4 AND key = ?2 AND state >= ?3",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(
                        params![
                            self.col,
                            key_bytes(&format!("historyFrom/{}", m.text())),
                            R_LIVE
                        ],
                        |r| r.get::<_, Ref>(0),
                    )
                    .map_err(sql)?;
                for r in rows {
                    succ.insert(self.canon(&r.map_err(sql)?)?);
                }
            }
            let mut stmt = self
                .t
                .conn()
                .prepare_cached(
                    "SELECT DISTINCT key FROM reg_ix WHERE col = ?1 AND ekind = 4 AND ent = ?2 AND state >= ?3",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![self.col, m, R_LIVE], |r| r.get::<_, Vec<u8>>(0))
                .map_err(sql)?;
            for r in rows {
                if let Some(p) = history_from(&r.map_err(sql)?)? {
                    pred.insert(ref_of(&self.canon_text(&p)?));
                }
            }
        }
        links.succ.insert(card.clone(), succ.into_iter().collect());
        links.pred.insert(card.clone(), pred.into_iter().collect());
        Ok(())
    }

    /// [seeds] 所在的连通分量之并。
    fn link_family(
        &self,
        links: &mut Links,
        seeds: &BTreeSet<Ref>,
    ) -> Result<BTreeSet<Ref>, String> {
        let mut family = seeds.clone();
        let mut frontier: Vec<Ref> = seeds.iter().cloned().collect();
        while let Some(c) = frontier.pop() {
            self.load_links(links, &c)?;
            for n in links.succ[&c].iter().chain(&links.pred[&c]) {
                if family.insert(n.clone()) {
                    frontier.push(n.clone());
                }
            }
        }
        Ok(family)
    }

    /// [cards] 上 Anki 导入复习的发生时刻在这个集合里出现过的全部卡（协议 3 `anki_partners` 同口径：只按时刻粗筛，
    /// 是不是同一事件由去重判）。
    fn anki_partners(&self, cards: &BTreeSet<Ref>) -> Result<BTreeSet<Ref>, String> {
        let mut times: BTreeSet<i64> = BTreeSet::new();
        for c in cards {
            for m in self.class_of(c)? {
                let ks: Vec<i64> = {
                    let mut stmt = self
                        .t
                        .conn()
                        .prepare_cached(
                            "SELECT k FROM log_ix WHERE col = ?1 AND card = ?2 AND win = 1",
                        )
                        .map_err(sql)?;
                    let rows = stmt
                        .query_map(params![self.col, m], |r| r.get(0))
                        .map_err(sql)?;
                    rows.collect::<Result<_, _>>().map_err(sql)?
                };
                for k in ks {
                    if let Some(l) = self.log4_at(k)? {
                        if is_anki_review(&l) {
                            times.insert(l.at);
                        }
                    }
                }
            }
        }
        let mut out = BTreeSet::new();
        for at in times {
            let ks: Vec<i64> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached("SELECT k FROM log_ix WHERE col = ?1 AND at = ?2 AND win = 1")
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, at], |r| r.get(0))
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            for k in ks {
                if let Some(l) = self.log4_at(k)? {
                    if is_anki_review(&l) {
                        out.insert(self.canon(&Ref::of(&l.card))?);
                    }
                }
            }
        }
        Ok(out)
    }

    fn log4_at(&self, k: i64) -> Result<Option<Log4>, String> {
        let Some(e) = self.t.entry_by_key(k)? else {
            return Ok(None);
        };
        Ok(match body_of(&e) {
            Some(Body4::Log(l)) => Some(l),
            _ => None,
        })
    }

    /// 全集合的卡按链接分成连通分量（全量重建）：笔记应有的卡、有日志的卡、链接的两端。
    fn all_components(&self, plans: &HashMap<Ref, Plan>) -> Result<Vec<Vec<Ref>>, String> {
        let mut nodes: BTreeSet<Ref> = plans.keys().cloned().collect();
        {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached("SELECT DISTINCT card FROM log_ix WHERE col = ?1")
                .map_err(sql)?;
            let rows = stmt
                .query_map([self.col], |r| r.get::<_, Ref>(0))
                .map_err(sql)?;
            for r in rows {
                nodes.insert(self.canon(&r.map_err(sql)?)?);
            }
        }
        let mut edges: Vec<(Ref, Ref)> = Vec::new();
        {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached(
                    "SELECT ent, key FROM reg_ix WHERE col = ?1 AND ekind = 4 AND state >= ?2",
                )
                .map_err(sql)?;
            let mut rows = stmt.query(params![self.col, R_LIVE]).map_err(sql)?;
            while let Some(r) = rows.next().map_err(sql)? {
                let ent: Ref = r.get(0).map_err(sql)?;
                let key = match r.get_ref(1).map_err(sql)? {
                    ValueRef::Blob(b) => b.to_vec(),
                    _ => return Err("gen4 cache: bad register key".to_owned()),
                };
                if let Some(p) = history_from(&key)? {
                    let (a, b) = (self.canon(&ent)?, ref_of(&self.canon_text(&p)?));
                    nodes.insert(a.clone());
                    nodes.insert(b.clone());
                    edges.push((a, b));
                }
            }
        }
        let index: HashMap<&Ref, usize> = nodes.iter().enumerate().map(|(i, n)| (n, i)).collect();
        let mut parent: Vec<usize> = (0..nodes.len()).collect();
        fn find(parent: &mut [usize], mut x: usize) -> usize {
            while parent[x] != x {
                parent[x] = parent[parent[x]];
                x = parent[x];
            }
            x
        }
        for (a, b) in &edges {
            let (ra, rb) = (find(&mut parent, index[a]), find(&mut parent, index[b]));
            if ra != rb {
                parent[ra.max(rb)] = ra.min(rb);
            }
        }
        let mut comps: BTreeMap<usize, Vec<Ref>> = BTreeMap::new();
        for (i, n) in nodes.iter().enumerate() {
            let r = find(&mut parent, i);
            comps.entry(r).or_default().push(n.clone());
        }
        Ok(comps.into_values().collect())
    }

    /// 上一次物化时与 [cards] 在同一个归属关系里的卡：这些卡的日志现在归谁、这些卡名下的统计行是谁的日志。链接被撤掉
    /// 后旧分量裂开，裂出去的那半不在新的连通分量里，但它的日志原来记在这边的卡名下——不一起重算就会丢行。统计行按
    /// 规范日志 ID 存、日志索引按原值存，两边经别名类对上。
    fn old_partners(&self, cards: &BTreeSet<Ref>) -> Result<BTreeSet<Ref>, String> {
        let mut out = BTreeSet::new();
        for c in cards {
            // 这张卡名下的统计行的日志，现在落在哪些卡上。
            let logs: Vec<Ref> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached("SELECT log FROM stats WHERE col = ?1 AND card = ?2")
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, c], |r| r.get::<_, Ref>(0))
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            for log in logs {
                for id in self.class_of(&log)? {
                    let mut stmt = self
                        .t
                        .conn()
                        .prepare_cached(
                            "SELECT DISTINCT card FROM log_ix WHERE col = ?1 AND id = ?2",
                        )
                        .map_err(sql)?;
                    let rows = stmt
                        .query_map(params![self.col, id], |r| r.get::<_, Ref>(0))
                        .map_err(sql)?;
                    for r in rows {
                        out.insert(self.canon(&r.map_err(sql)?)?);
                    }
                }
            }
            // 这张卡（类里每个成员）上的日志，统计行记在谁名下。
            for m in self.class_of(c)? {
                let copies: Vec<(Ref, i64)> = {
                    let mut stmt = self
                        .t
                        .conn()
                        .prepare_cached(
                            "SELECT DISTINCT id, at FROM log_ix WHERE col = ?1 AND card = ?2",
                        )
                        .map_err(sql)?;
                    let rows = stmt
                        .query_map(params![self.col, m], |r| Ok((r.get(0)?, r.get(1)?)))
                        .map_err(sql)?;
                    rows.collect::<Result<_, _>>().map_err(sql)?
                };
                for (id, at) in copies {
                    // 统计行的发生时刻就是日志的发生时刻：按主键 (col, at, log) 点读。
                    let log = self.canon(&id)?;
                    for owner in self.stat_owners(at, &log)? {
                        out.insert(owner);
                    }
                }
            }
        }
        Ok(out)
    }

    /// 规范日志 [log]（发生在 [at]）的统计行记在谁名下。
    fn stat_owners(&self, at: i64, log: &Ref) -> Result<Vec<Ref>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached("SELECT card FROM stats WHERE col = ?1 AND at = ?2 AND log = ?3")
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![self.col, at, log], |r| r.get::<_, Ref>(0))
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    /// 别名表里变了的一个 ID [r]（`alias.rs` 记的）牵动的缓存行：引用它的笔记行（ID、笔记类型、牌组）与卡行（ID、
    /// 笔记、模板、牌组）所属的笔记进 [notes]；它名下的统计行的归属卡、它当日志时落在的卡（卡行的最后一条日志随卡重算）
    /// 进 [cards]。它已不是规范 ID 时，它名下的笔记行、卡行、统计行删掉（行只按规范 ID 存，重算按新的规范 ID 写回）。
    /// 每一问都是按键查（`notes_deck` / `cards_deck` / `cards_template` 三个索引就是为它建的）。
    fn moved_rows(
        &self,
        r: &Ref,
        notes: &mut BTreeSet<Ref>,
        cards: &mut BTreeSet<Ref>,
        raw: &mut BTreeSet<Ref>,
    ) -> Result<(), String> {
        let conn = self.t.conn();
        let refs = |q: &str| -> Result<Vec<Ref>, String> {
            let mut stmt = conn.prepare_cached(q).map_err(sql)?;
            let rows = stmt
                .query_map(params![self.col, r], |x| x.get::<_, Ref>(0))
                .map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)
        };
        for q in [
            "SELECT id FROM notes WHERE col = ?1 AND id = ?2",
            "SELECT id FROM notes WHERE col = ?1 AND note_type_id = ?2",
            "SELECT id FROM notes WHERE col = ?1 AND deck_id = ?2",
            "SELECT note_id FROM cards WHERE col = ?1 AND id = ?2",
            "SELECT note_id FROM cards WHERE col = ?1 AND note_id = ?2",
            "SELECT note_id FROM cards WHERE col = ?1 AND template_id = ?2",
            "SELECT note_id FROM cards WHERE col = ?1 AND deck_id = ?2",
        ] {
            for n in refs(q)? {
                notes.insert(self.canon(&n)?);
                raw.insert(n);
            }
        }
        for c in refs("SELECT DISTINCT card FROM stats WHERE col = ?1 AND card = ?2")? {
            cards.insert(self.canon(&c)?);
        }
        let copies: Vec<(Ref, i64)> = {
            let mut stmt = conn
                .prepare_cached("SELECT card, at FROM log_ix WHERE col = ?1 AND id = ?2")
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![self.col, r], |x| Ok((x.get(0)?, x.get(1)?)))
                .map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)?
        };
        let gone = self.canon(r)? != *r;
        for (card, at) in &copies {
            cards.insert(self.canon(card)?);
            for owner in self.stat_owners(*at, r)? {
                cards.insert(self.canon(&owner)?);
            }
            if gone {
                conn.prepare_cached("DELETE FROM stats WHERE col = ?1 AND at = ?2 AND log = ?3")
                    .map_err(sql)?
                    .execute(params![self.col, at, r])
                    .map_err(sql)?;
            }
        }
        if gone {
            raw.insert(r.clone());
            self.delete_note_rows(r)?;
            for q in [
                "DELETE FROM cards WHERE col = ?1 AND id = ?2",
                "DELETE FROM stats WHERE col = ?1 AND card = ?2",
            ] {
                conn.prepare_cached(q)
                    .map_err(sql)?
                    .execute(params![self.col, r])
                    .map_err(sql)?;
            }
        }
        Ok(())
    }

    /// 一批碰到的卡扩成连通分量，再按 Anki 复习时刻与旧的归属关系扩到不动点；按分量返回。
    fn dirty_components(&self, cards: &BTreeSet<Ref>) -> Result<Vec<Vec<Ref>>, String> {
        let mut links = Links::default();
        let mut family = self.link_family(&mut links, cards)?;
        loop {
            let mut partners = self.anki_partners(&family)?;
            partners.extend(self.old_partners(&family)?);
            if partners.iter().all(|p| family.contains(p)) {
                break;
            }
            let grown: BTreeSet<Ref> = family.union(&partners).cloned().collect();
            family = self.link_family(&mut links, &grown)?;
        }
        let mut comps: Vec<Vec<Ref>> = Vec::new();
        let mut done: HashSet<Ref> = HashSet::new();
        for c in &family {
            if done.contains(c) {
                continue;
            }
            let comp = self.link_family(&mut links, &BTreeSet::from([c.clone()]))?;
            done.extend(comp.iter().cloned());
            comps.push(comp.into_iter().collect());
        }
        Ok(comps)
    }

    // ------------------------------------------------------------ 物化

    fn type_info(&mut self, id: &Ref, cfg: &CacheConfig) -> Result<Option<TypeInfo>, String> {
        let Some((_, _, payload)) = self.definition(id)? else {
            return Ok(None);
        };
        let (lines, _) = self.live_lines(EntKind::NoteType, id)?;
        let stored: Vec<StoredEdit<'_>> =
            lines.iter().map(|(j, s)| (j.as_str(), *s, None)).collect();
        // 身份记录 / 修改不成形的笔记类型当作不在（同笔记，见 [Index::cache_pass]）。
        Ok(caches::type_info_of(&payload, &stored, cfg).ok())
    }

    /// 规范笔记 [n]（规范笔记类型 [nt]）在 `anki_members` 里的行（文件头「表」）：先删旧的，再按它现在的别名类与应有的卡
    /// [cards]（(规范卡, 规范模板, cloze 序号)）写。[all] = 全量物化（表已空，不删）。
    fn member_numbers(
        &self,
        n: &Ref,
        nt: &Ref,
        cards: &[(Ref, Ref, i64)],
        all: bool,
        tmpl_members: &mut HashMap<Ref, Vec<Ref>>,
    ) -> Result<(), String> {
        let conn = self.t.conn();
        if !all {
            conn.prepare_cached("DELETE FROM anki_members WHERE col = ?1 AND note = ?2")
                .map_err(sql)?
                .execute(params![self.col, n])
                .map_err(sql)?;
        }
        let put = |kind: EntKind, member: &Ref, canon: &Ref| -> Result<(), String> {
            conn.prepare_cached(
                "INSERT OR IGNORE INTO anki_members (col, kind, num, canon, note) VALUES (?1, ?2, ?3, ?4, ?5)",
            )
            .map_err(sql)?
            .execute(params![
                self.col,
                kind as i64,
                anki_numeric_id(&member.text()),
                canon,
                n
            ])
            .map_err(sql)?;
            Ok(())
        };
        let note_members = self.aliases_of(n)?;
        for m in &note_members {
            put(EntKind::Note, m, n)?;
        }
        // 配卡公式的一边：规范 ID 自己加出现过的成员（文件头「表」）。
        let side = |members: &[Ref], canon: &Ref| -> Vec<Id> {
            std::iter::once(canon)
                .chain(members)
                .filter_map(|r| match r {
                    Ref::Uuid(b) => Some(Id(*b)),
                    Ref::Text(_) => None,
                })
                .collect()
        };
        let notes = side(&note_members, n);
        for (card, tpl, ord) in cards {
            if !tmpl_members.contains_key(tpl) {
                let mut m = self.aliases_of(tpl)?;
                // 内置模板从不作为实体出现、别名表里没有它的带盐 ID：由笔记类型的成员按规则算回来（协议 3 给从没复习过
                // 的内置笔记的卡也发了号，那张卡的 ID 由带盐笔记 × 带盐模板配出）。
                let nt_members = self.aliases_of(nt)?;
                for x in builtin_template_members(nt, &nt_members, tpl) {
                    if !m.contains(&x) {
                        m.push(x);
                    }
                }
                tmpl_members.insert(tpl.clone(), m);
            }
            let tpls = side(&tmpl_members[tpl], tpl);
            for a in &notes {
                for t in &tpls {
                    let x = Ref::Uuid(rules::card(a, t, *ord).0);
                    if x != *card {
                        put(EntKind::Card, &x, card)?;
                    }
                }
            }
            for m in self.aliases_of(card)? {
                put(EntKind::Card, &m, card)?;
            }
        }
        Ok(())
    }

    fn delete_note_rows(&self, note: &Ref) -> Result<(), String> {
        let conn = self.t.conn();
        conn.prepare_cached("DELETE FROM notes WHERE col = ?1 AND id = ?2")
            .map_err(sql)?
            .execute(params![self.col, note])
            .map_err(sql)?;
        conn.prepare_cached("DELETE FROM anki_members WHERE col = ?1 AND note = ?2")
            .map_err(sql)?
            .execute(params![self.col, note])
            .map_err(sql)?;
        conn.prepare_cached("DELETE FROM cards WHERE col = ?1 AND note_id = ?2")
            .map_err(sql)?
            .execute(params![self.col, note])
            .map_err(sql)?;
        Ok(())
    }

    /// 重算 [notes] 这些笔记的行与它们应有的卡、[cards] 这些卡所在的连通分量的卡行、重放与统计行。[all] = 全量（表
    /// 已空，不读旧行）。
    fn cache_pass(
        &mut self,
        cfg: &CacheConfig,
        notes: BTreeSet<Ref>,
        cards: BTreeSet<Ref>,
        all: bool,
        out: &mut Settled,
    ) -> Result<(), String> {
        // 归回的写入者表在这一趟里不变：按类拼行（`class.rs` [Index::class_lines]）每个实体都要它，读一次。
        self.pass_writers = Some(std::rc::Rc::new(self.writer_aliases()?));
        self.pass_rules_begin()?;
        let done = self.cache_pass_with(cfg, notes, cards, all, out);
        self.pass_writers = None;
        self.pass_rules = None;
        done
    }

    fn cache_pass_with(
        &mut self,
        cfg: &CacheConfig,
        notes: BTreeSet<Ref>,
        mut cards: BTreeSet<Ref>,
        all: bool,
        out: &mut Settled,
    ) -> Result<(), String> {
        let mut plans: HashMap<Ref, Plan> = HashMap::new();
        let mut types: HashMap<Ref, Option<TypeInfo>> = HashMap::new();
        // 模板的别名类（[Index::member_numbers]）：同一种笔记类型的笔记共用，一趟里只查一次。
        let mut tmpl_members: HashMap<Ref, Vec<Ref>> = HashMap::new();
        if !all {
            self.cache_touched.extend(notes.iter().cloned());
        }
        for n in &notes {
            let existing: Vec<Ref> = if all {
                Vec::new()
            } else {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached("SELECT id FROM cards WHERE col = ?1 AND note_id = ?2")
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, n], |r| r.get::<_, Ref>(0))
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            cards.extend(existing.iter().cloned());
            let Some((def_k, edited, info)) = self.note_info(n)? else {
                if !all {
                    self.delete_note_rows(n)?;
                }
                continue;
            };
            let tref = self.canon(&ref_of(&info.note_type))?;
            if !types.contains_key(&tref) {
                let ti = self.type_info(&tref, cfg)?;
                types.insert(tref.clone(), ti);
            }
            // 卡 ID 由笔记 ID 派生（`registers::card_id`）：笔记 ID 不是 UUID 时算不出，同不成形的身份记录。笔记 ID 与
            // 笔记类型视图里的模板 ID 都已是规范 ID，派生出来的就是规范卡 ID（`gen4_ids::rules::card` 同一个公式，别名表
            // 对出现过的卡的派生判定也是它），不查表：一张从没出现在操作里的卡别名表里没有行（文件头「别名」第 1 条）。
            let Ok(row) = note_row(&info, types[&tref].as_ref()) else {
                if !all {
                    self.delete_note_rows(n)?;
                }
                continue;
            };
            let def_wall = self.t.head_by_key(def_k)?.map_or(0, |h| h.wall);
            let updated = def_wall.max(edited).max(self.tag_time(n)?);
            self.t
                .conn()
                .prepare_cached(
                    "INSERT OR REPLACE INTO notes (col, id, note_type_id, guid, created_at, deck_id, deleted_at, \
                     term_key, reading_key, sort_field, tags_json, pending_decision, updated_at, media_refs, \
                     source_kind, source_title, anki_id, dupe_norm, source_key) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)",
                )
                .map_err(sql)?
                .execute(params![
                    self.col,
                    n,
                    tref,
                    info.guid,
                    info.created_at,
                    info.deck.as_deref().map(ref_of),
                    info.deleted_at,
                    row.term,
                    row.reading,
                    row.sort,
                    row.tags,
                    info.pending,
                    updated,
                    row.media,
                    info.source_kind,
                    info.source_title,
                    row.anki_id,
                    row.dupe,
                    info.source_key,
                ])
                .map_err(sql)?;
            out.cache_notes += 1;
            let expected: Vec<Ref> = row.expected.iter().map(|e| ref_of(&e.0)).collect();
            let shape: Vec<(Ref, Ref, i64)> = expected
                .iter()
                .zip(&row.expected)
                .map(|(c, (_, tpl, ord, _))| (c.clone(), ref_of(tpl), *ord))
                .collect();
            self.member_numbers(n, &tref, &shape, all, &mut tmpl_members)?;
            for c in existing.iter().filter(|c| !expected.contains(c)) {
                self.t
                    .conn()
                    .prepare_cached("DELETE FROM cards WHERE col = ?1 AND id = ?2")
                    .map_err(sql)?
                    .execute(params![self.col, c])
                    .map_err(sql)?;
            }
            for (c, (_, tpl, ord, empty)) in expected.into_iter().zip(&row.expected) {
                cards.insert(c.clone());
                plans.insert(
                    c,
                    Plan {
                        note: n.clone(),
                        template: ref_of(tpl),
                        ord: *ord,
                        hidden: row.gone || *empty,
                        created: info.created_at,
                        freq: row.freq,
                        note_deck: info.deck.clone(),
                    },
                );
            }
        }
        let comps = if all {
            self.all_components(&plans)?
        } else if cards.is_empty() {
            Vec::new()
        } else {
            self.dirty_components(&cards)?
        };
        let mut acc = StatAcc::default();
        let mut batch: Vec<Ref> = Vec::new();
        for comp in comps {
            batch.extend(comp);
            if batch.len() >= BATCH {
                self.cache_batch(cfg, &std::mem::take(&mut batch), &plans, all, &mut acc, out)?;
            }
        }
        if !batch.is_empty() {
            self.cache_batch(cfg, &batch, &plans, all, &mut acc, out)?;
        }
        let losers = anki_duplicate_log_ids(&acc.keys, &acc.owners, &acc.visible, &acc.note_of);
        for log in losers {
            let at = acc.at_of[&log];
            out.cache_stats -= 1;
            self.t
                .conn()
                .prepare_cached("DELETE FROM stats WHERE col = ?1 AND at = ?2 AND log = ?3")
                .map_err(sql)?
                .execute(params![self.col, at, ref_of(&log)])
                .map_err(sql)?;
        }
        Ok(())
    }

    /// 一批卡（若干个完整的连通分量）：重放、卡行、统计行。
    fn cache_batch(
        &mut self,
        cfg: &CacheConfig,
        batch: &[Ref],
        plans: &HashMap<Ref, Plan>,
        all: bool,
        acc: &mut StatAcc,
        out: &mut Settled,
    ) -> Result<(), String> {
        let l = self.lineage(batch)?;
        self.cache_lineage(cfg, batch, plans, all, acc, out, l)
    }

    /// 卡 [card] 的日志，`res` 是按血统重放写回的（与缓存层、协议 3 落库的日志行同一份）：它的 historyFrom 连通分量
    /// 整个重放一遍再取它那一段。读命令 `logs` / `entity_views` 用（G7-4）。
    pub(super) fn replayed_card_logs(&mut self, card: &Ref) -> Result<Vec<LogIn>, String> {
        let card = self.canon(card)?;
        Ok(self
            .replayed_logs(&BTreeSet::from([card.clone()]))?
            .remove(&card.text())
            .unwrap_or_default())
    }

    /// [replayed_card_logs] 的批量版：[cards]（规范 ID）所在的全部 historyFrom 连通分量一起重放一遍，返回分量里**每张**卡
    /// （规范 ID 文本）的日志（`res` 是重放写回的）。训练集 / 逐卡重放的读命令（`cmd/training.rs`，G7-4f）按批调，
    /// 不逐卡各重放一次整个分量。
    pub(super) fn replayed_logs(
        &mut self,
        cards: &BTreeSet<Ref>,
    ) -> Result<HashMap<String, Vec<LogIn>>, String> {
        let mut links = Links::default();
        let comp: Vec<Ref> = self.link_family(&mut links, cards)?.into_iter().collect();
        Ok(self.lineage(&comp)?.logs)
    }

    /// 卡 [tail] 当链尾的归属组（链尾 + 广度优先的全部前身，`group_lineage`）的日志，按组里卡的顺序、各卡按
    /// (发生时刻, 操作主键)：(投影行 JSON, server_time, 意图, fuzz 种子用的原值卡)，未经重放写回（重放的输入）。写命令 `sched`（G7-3b，
    /// `cmd/writes_intent.rs`）据它算这张卡此刻的头状态——协议 3 `store/sync2/mod.rs` `group_of` 的新代版。
    pub(super) fn group_rows(&mut self, tail: &Ref) -> Result<Vec<GroupRow>, String> {
        Ok(self.group(tail)?.0)
    }

    /// [group_rows] 连同归属组的笔记（规范 ID）：取链尾自己日志上记的（链尾的日志里最后一条记了笔记的），链尾没有就取
    /// 前身里第一条记了笔记的——协议 3 `group_of` 的同一条规则（换笔记类型不换笔记）。评分预览（`cmd/preview.rs`）用。
    #[allow(clippy::type_complexity)]
    pub(super) fn group(&mut self, tail: &Ref) -> Result<(Vec<GroupRow>, Option<String>), String> {
        let tail = self.canon(tail)?;
        let lineage = {
            let mut preds = |c: &str| -> Result<Vec<String>, String> {
                let (ls, _) = self.live_lines(EntKind::Card, &ref_of(c))?;
                Ok(config::predecessors(&ls))
            };
            group_lineage(&tail.text(), &mut preds)?
        };
        let tail_text = tail.text();
        let mut out = Vec::new();
        let mut note: Option<Ref> = None;
        for c in &lineage {
            for l in self.card_logs(&ref_of(c))? {
                if l.note.is_some() && (note.is_none() || *c == tail_text) {
                    note = l.note.clone();
                }
                out.push((l.json, l.server_time, l.intent, l.seed_card));
            }
        }
        let note = note.map(|n| self.canon(&n).map(|c| c.text())).transpose()?;
        Ok((out, note))
    }

    /// 一批卡（若干个完整的 historyFrom 连通分量）：活着的修改行、生效的前身 / 后继、按链尾重放写回的日志。
    fn lineage(&mut self, batch: &[Ref]) -> Result<Lineage, String> {
        // 卡的活着的修改行（血统、标志、链尾都从它判）与日志。
        let mut lines: BTreeMap<String, Vec<(String, Option<i64>)>> = BTreeMap::new();
        let mut logs: HashMap<String, Vec<LogIn>> = HashMap::new();
        for c in batch {
            let (ls, _) = self.live_lines(EntKind::Card, c)?;
            if !ls.is_empty() {
                lines.insert(c.text(), ls);
            }
            logs.insert(c.text(), self.card_logs(c)?);
        }
        // 生效的前身（`historyFrom/<前身>` 为 true），与它反过来的后继。
        let mut preds: HashMap<String, Vec<String>> = HashMap::new();
        let mut succs: HashMap<String, Vec<String>> = HashMap::new();
        for (c, ls) in &lines {
            // 修改行已是规范形（键里的 `historyFrom/<卡>` 也归了一），前身就是规范卡 ID。
            let ps: Vec<String> = config::predecessors(ls);
            for p in &ps {
                succs.entry(p.clone()).or_default().push(c.clone());
            }
            preds.insert(c.clone(), ps);
        }
        for s in succs.values_mut() {
            s.sort();
            s.dedup();
        }
        // 重放：每个链尾的归属组按链尾 ID 升序各重放一遍，结果写回日志行（后一组为准）。
        let mut tails: BTreeSet<String> = BTreeSet::new();
        for c in batch {
            tails.extend(tails_with(&c.text(), &mut |x| {
                Ok(succs.get(x).cloned().unwrap_or_default())
            })?);
        }
        let mut replayed: HashMap<(String, usize), String> = HashMap::new();
        for tail in &tails {
            let lineage =
                group_lineage(tail, &mut |x| Ok(preds.get(x).cloned().unwrap_or_default()))?;
            let mut at: Vec<(String, usize)> = Vec::new();
            let mut rows: Vec<Row<'_>> = Vec::new();
            for c in &lineage {
                for (i, l) in logs.get(c).into_iter().flatten().enumerate() {
                    at.push((c.clone(), i));
                    rows.push(Row {
                        json: &l.json,
                        server_time: l.server_time,
                        intent: l.intent.clone(),
                        seed_card: Some(&l.seed_card),
                    });
                }
            }
            if rows.is_empty() {
                continue;
            }
            for (k, new) in replay(&rows)?.rows.into_iter().enumerate() {
                if let Some(json) = new {
                    replayed.insert(at[k].clone(), json);
                }
            }
        }
        for ((c, i), json) in replayed {
            if let Some(l) = logs.get_mut(&c).and_then(|ls| ls.get_mut(i)) {
                l.json = json;
            }
        }
        Ok(Lineage {
            lines,
            logs,
            preds,
            succs,
        })
    }

    /// [cache_batch] 的物化段：卡行、统计行（[l] = 这一批的 [lineage]）。
    #[allow(clippy::too_many_arguments)]
    fn cache_lineage(
        &mut self,
        cfg: &CacheConfig,
        batch: &[Ref],
        plans: &HashMap<Ref, Plan>,
        all: bool,
        acc: &mut StatAcc,
        out: &mut Settled,
        l: Lineage,
    ) -> Result<(), String> {
        let Lineage {
            lines,
            logs,
            preds,
            succs,
        } = l;
        let stored_of = |lineage: &[String]| -> Vec<StoredLog<'_>> {
            let mut s: Vec<StoredLog<'_>> = Vec::new();
            for c in lineage {
                for l in logs.get(c).into_iter().flatten() {
                    s.push((l.json.as_str(), l.server_time, None));
                }
            }
            s
        };
        let card_edits: Vec<(String, Vec<StoredEdit<'_>>)> = lines
            .iter()
            .map(|(c, ls)| {
                (
                    c.clone(),
                    ls.iter().map(|(j, s)| (j.as_str(), *s, None)).collect(),
                )
            })
            .collect();
        // 有行的卡：这一批笔记算好的，或（增量时）已有行、笔记没动的——那些列沿用行里的（协议 3 `flush_cards` 同）。
        struct Target {
            card: Ref,
            note: Ref,
            template: Ref,
            ord: i64,
            hidden: bool,
            created: i64,
            freq: Option<i64>,
            note_deck: Option<String>,
        }
        let mut targets: Vec<Target> = Vec::new();
        for c in batch {
            if let Some(p) = plans.get(c) {
                targets.push(Target {
                    card: c.clone(),
                    note: p.note.clone(),
                    template: p.template.clone(),
                    ord: p.ord,
                    hidden: p.hidden,
                    created: p.created,
                    freq: p.freq,
                    note_deck: p.note_deck.clone(),
                });
                continue;
            }
            if all {
                continue;
            }
            type Kept = (Ref, Ref, i64, bool, i64, Option<i64>);
            let row: Option<Kept> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT note_id, template_id, cloze_ord, hidden, note_created_at, freq_rank FROM cards \
                         WHERE col = ?1 AND id = ?2",
                    )
                    .map_err(sql)?;
                let mut rows = stmt.query(params![self.col, c]).map_err(sql)?;
                match rows.next().map_err(sql)? {
                    Some(r) => Some((
                        r.get(0).map_err(sql)?,
                        r.get(1).map_err(sql)?,
                        r.get(2).map_err(sql)?,
                        r.get::<_, i64>(3).map_err(sql)? != 0,
                        r.get(4).map_err(sql)?,
                        r.get(5).map_err(sql)?,
                    )),
                    None => None,
                }
            };
            let Some((note, template, ord, hidden, created, freq)) = row else {
                continue;
            };
            let n: Option<(Option<Ref>, i64)> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT deck_id, created_at FROM notes WHERE col = ?1 AND id = ?2",
                    )
                    .map_err(sql)?;
                let mut rows = stmt.query(params![self.col, note]).map_err(sql)?;
                match rows.next().map_err(sql)? {
                    Some(r) => Some((r.get(0).map_err(sql)?, r.get(1).map_err(sql)?)),
                    None => None,
                }
            };
            targets.push(Target {
                card: c.clone(),
                note,
                template,
                ord,
                hidden,
                created: n.as_ref().map_or(created, |n| n.1),
                freq,
                note_deck: n.and_then(|n| n.0).map(|d| d.text()),
            });
        }
        let want: Vec<(String, Option<String>, String)> = targets
            .iter()
            .map(|t| {
                (
                    t.card.text(),
                    t.note_deck.clone(),
                    cfg.default_deck().to_owned(),
                )
            })
            .collect();
        let flags = registers::card_lineage_flags(&card_edits, &want)?;
        let mut visible: HashSet<String> = HashSet::new();
        let mut note_of: HashMap<String, String> = HashMap::new();
        for (t, (lineage, flags)) in targets.iter().zip(flags) {
            let m = Material::of(flags, &stored_of(&lineage))?;
            let r = card_row(&m)?;
            let s = r.state;
            let card = t.card.text();
            self.t
                .conn()
                .prepare_cached(
                    "INSERT OR REPLACE INTO cards (col, id, note_id, template_id, cloze_ord, deck_id, suspended, \
                     buried_until_day, flag, hidden, queue, due_day, due_at, scheduled_days, reps, lapses, stability, \
                     difficulty, last_reviewed_at, last_log_id, scheduler, note_created_at, new_position, freq_rank, anki_id) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, \
                     ?21, ?22, ?23, ?24, ?25)",
                )
                .map_err(sql)?
                .execute(params![
                    self.col,
                    t.card,
                    t.note,
                    t.template,
                    t.ord,
                    ref_of(r.deck),
                    r.suspended,
                    r.buried_until_day,
                    r.flag,
                    t.hidden,
                    r.queue,
                    s.due_day,
                    s.due_at,
                    s.scheduled_days,
                    s.reps,
                    s.lapses,
                    s.memory.map(|m| m.0),
                    s.memory.map(|m| m.1),
                    s.last_reviewed_at,
                    s.last_log_id.as_deref().map(ref_of),
                    s.scheduler,
                    t.created,
                    r.new_position,
                    t.freq,
                    crate::store::schema::anki_numeric_id(&card),
                ])
                .map_err(sql)?;
            out.cache_cards += 1;
            if !all {
                self.cache_touched.insert(t.note.clone());
            }
            if !t.hidden {
                visible.insert(card.clone());
            }
            note_of.insert(card, t.note.text());
        }
        // 有效复习投影：归属组、每组的投影行、Anki 副本的轻量键。
        let mut descendants: HashMap<String, BTreeSet<String>> = HashMap::new();
        let linked: Vec<(String, Option<String>, String)> = batch
            .iter()
            .map(Ref::text)
            .filter(|c| preds.get(c).is_some_and(|p| !p.is_empty()) || succs.contains_key(c))
            .map(|c| (c, None, cfg.default_deck().to_owned()))
            .collect();
        for ((c, ..), (lineage, _)) in linked
            .iter()
            .zip(registers::card_lineage_flags(&card_edits, &linked)?)
        {
            add_descendants(c, lineage, &mut descendants);
        }
        let texts: Vec<String> = batch.iter().map(Ref::text).collect();
        let ids = sorted_ids(&texts);
        let (order, groups) = stat_groups(&ids, &visible, &descendants);
        if !all {
            for c in batch {
                self.t
                    .conn()
                    .prepare_cached("DELETE FROM stats WHERE col = ?1 AND card = ?2")
                    .map_err(sql)?
                    .execute(params![self.col, c])
                    .map_err(sql)?;
            }
        }
        let base = acc.owners.len();
        for (k, o) in order.iter().enumerate() {
            let owner = ref_of(o);
            for r in history::stats_from_stored(&stored_of(&groups[o]))? {
                let log = r.log_id.clone();
                self.t
                    .conn()
                    .prepare_cached(
                        "INSERT INTO stats (col, at, log, card, utc_offset_min, rating, kind, duration_ms, prev_due_day, \
                         maturity_delta) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) \
                         ON CONFLICT (col, at, log) DO UPDATE SET card = excluded.card, \
                         utc_offset_min = excluded.utc_offset_min, rating = excluded.rating, kind = excluded.kind, \
                         duration_ms = excluded.duration_ms, prev_due_day = excluded.prev_due_day, \
                         maturity_delta = excluded.maturity_delta",
                    )
                    .map_err(sql)?
                    .execute(params![
                        self.col,
                        r.occurred_at,
                        ref_of(&log),
                        owner,
                        r.utc_off,
                        r.rating,
                        r.kind,
                        r.dur,
                        r.prev_due_day,
                        r.maturity_delta,
                    ])
                    .map_err(sql)?;
                out.cache_stats += 1;
                acc.at_of.insert(log.clone(), r.occurred_at);
                if let Some(event) = r.anki_event {
                    acc.keys.push(AnkiStatKey {
                        event,
                        owner: base + k,
                        log_id: log,
                    });
                }
            }
        }
        acc.owners.extend(order);
        acc.visible.extend(visible);
        acc.note_of.extend(note_of);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;
    use rusqlite::Connection;
    use serde_json::{Value, json};

    use super::CFG_KEY;
    use crate::gen4::op::tests::{id, native_edit};
    use crate::gen4::op::{Body4, Edit4, Log4};
    use crate::store::gen4::derive::Index;
    use crate::store::gen4::derive::tests::{assert_rebuild_is_identity, native, note, op, with};
    use crate::store::gen4::parity::{cell, imported};
    use crate::store::gen4::truth::{TRUST_PENDING, Truth};
    use crate::store::sync2::config::default_deck_id;
    use crate::store::sync2::tests::{Bucket, DAY, Device, P, deck_entity, edit, review};
    use crate::sync2::id::Key;
    use crate::sync2::op::{EntKind, Intent};

    const T0: i64 = 1_700_000_000_000;
    const N1: &str = "0193a1b2-0000-7000-8000-0000000000a1";
    const N2: &str = "0193a1b2-0000-7000-8000-0000000000a2";
    const N3: &str = "0193a1b2-0000-7000-8000-0000000000a3";

    /// 一条查询的结果，每格按对拍的文本形（16 字节 ID 写成 UUID 文本）。
    fn rows(conn: &Connection, sql: &str) -> Vec<Vec<String>> {
        let mut stmt = conn.prepare(sql).unwrap();
        let n = stmt.column_count();
        let mut out = Vec::new();
        let mut rs = stmt.query([]).unwrap();
        while let Some(r) = rs.next().unwrap() {
            out.push((0..n).map(|i| cell(r.get_ref(i).unwrap())).collect());
        }
        out
    }

    fn strs<const N: usize>(rs: &[[&str; N]]) -> Vec<Vec<String>> {
        rs.iter()
            .map(|r| r.iter().map(|s| (*s).to_owned()).collect())
            .collect()
    }

    fn blob(uuid: &str) -> String {
        format!("x'{}'", uuid.replace('-', ""))
    }

    fn card_of(note: &str, template: &str, ord: i64) -> String {
        crate::registers::card_id(note, template, ord).unwrap()
    }

    // ---------------------------------------------------------------- 协议 3 的场景灌进新代

    /// 一开始就在协议 3 上的设备（没有旧行要迁）。
    fn fresh(name: &str) -> Device {
        let d = Device::new(name);
        d.core.sync2_identity(P, T0).unwrap();
        d.core.sync2_migrate(P, T0, None).unwrap();
        d
    }

    fn p3_note(id: &str, nt: &str) -> Value {
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": nt}}})
    }

    fn p3_note_type(id: &str, kind: &str) -> Value {
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": kind}}})
    }

    fn anki_review(id: &str, card: &str, rid: i64) -> Value {
        json!({"t": "log", "x": {
            "id": id, "p": P, "card": card, "kind": "review", "rating": 3, "hlc": format!("{rid}:0:anki"),
            "at": rid, "ts": "wall", "origin": "anki", "ankiId": rid, "rtype": "review", "dur": 5000, "utcOff": 0,
            "rollover": 4, "alg": "anki",
            "res": {"queue": "review", "ivl": 3, "step": 0, "reps": 1, "lapses": 0, "scheduler": "fushi", "dueDay": 1}
        }})
    }

    /// 协议 3 的一个库灌进新代：笔记行（字段 / 标签 / 牌组 / 删除）、卡 = 笔记 × 模板（含填空）、血统、重放（评分、
    /// undo）、同一次 Anki 复习的两份副本只算一份——行与协议 3 的 `caches::rebuild` 逐列相同（`imported` 里对拍、
    /// 重建两遍、换一种到达方式逐条维护都查过），这里再钉几个值。
    #[test]
    fn a_protocol_3_library_gives_the_same_note_card_and_stat_rows() {
        let d = fresh("g4cache");
        let deck = default_deck_id(P);
        let fdef = |name: &str| json!({"name": name, "ord": 0});
        let tdef =
            |name: &str, ord: i64, front: &str| json!({"name": name, "ord": ord, "front": front});
        d.apply(
            T0,
            vec![
                deck_entity(&deck),
                p3_note_type("NT", "standard"),
                edit("notetype", "NT", "fieldDef/fa", fdef("Expression")),
                edit(
                    "notetype",
                    "NT",
                    "tmplDef/t1",
                    tdef("A", 0, "{{Expression}}"),
                ),
                edit(
                    "notetype",
                    "NT",
                    "tmplDef/t2",
                    tdef("B", 1, "{{Expression}}"),
                ),
                p3_note_type("NC", "cloze"),
                edit("notetype", "NC", "fieldDef/fx", fdef("Text")),
                edit(
                    "notetype",
                    "NC",
                    "tmplDef/tc",
                    tdef("Cloze", 0, "{{cloze:Text}}"),
                ),
                p3_note(N1, "NT"),
                edit("note", N1, "f/fa", json!("猫")),
                edit("note", N1, "tags", json!(["b", "a"])),
                p3_note(N2, "NC"),
                edit("note", N2, "f/fx", json!("{{c1::a}} {{c2::b}}")),
                p3_note(N3, "NT"),
                edit("note", N3, "f/fa", json!("犬")),
            ],
        );
        let (c1, c2) = (card_of(N1, "t1", 0), card_of(N1, "t2", 0));
        let z1 = card_of(N2, "tc", 1);
        d.apply(T0 + 10, vec![review("r1", &c1, T0 + 10, 3, "learn")]);
        d.apply(T0 + DAY, vec![review("r2", &c1, T0 + DAY, 3, "review")]);
        d.apply(
            T0 + DAY + 5,
            vec![json!({"t": "log", "x": {
                "id": "u1", "p": P, "card": c1, "kind": "undo", "revokes": "r2",
                "hlc": format!("{}:0:dart", T0 + DAY + 5), "at": T0 + DAY + 5, "ts": "anchored", "origin": "fushi",
                "rtype": "manual", "utcOff": 0, "rollover": 4, "fv": 1
            }})],
        );
        d.apply(
            T0 + DAY + 10,
            vec![edit("card", &c2, &format!("historyFrom/{c1}"), json!(true))],
        );
        d.apply(
            T0 + DAY + 20,
            vec![edit("note", N3, "deleted", json!(T0 + DAY + 20))],
        );
        // 同一条 revlog 落在两张没有血统的卡上（一张不属于任何笔记）。
        let rid = T0 - 1000;
        d.apply(
            T0 + DAY + 30,
            vec![anki_review("a1", &z1, rid), anki_review("a2", "ZZ", rid)],
        );
        let (conn, diff) = imported(&d);
        assert!(diff.is_empty(), "{diff:?}");
        assert_eq!(
            rows(
                &conn,
                "SELECT id, note_type_id, deleted_at IS NOT NULL FROM notes ORDER BY note_type_id, created_at, guid",
            ),
            strs(&[[N2, "NC", "0"], [N1, "NT", "0"], [N3, "NT", "1"]])
        );
        let cards = |note: &str| -> Vec<Vec<String>> {
            rows(
                &conn,
                &format!(
                    "SELECT template_id, cloze_ord, hidden FROM cards WHERE note_id = {} ORDER BY template_id, cloze_ord",
                    blob(note)
                ),
            )
        };
        assert_eq!(cards(N1), strs(&[["t1", "0", "0"], ["t2", "0", "0"]]));
        assert_eq!(cards(N2), strs(&[["tc", "1", "0"], ["tc", "2", "0"]]));
        assert_eq!(cards(N3), strs(&[["t1", "0", "1"], ["t2", "0", "1"]]));
        // r2 被撤销：前身与继承它的后继都只有 r1。
        let state = |card: &str| -> Vec<Vec<String>> {
            rows(
                &conn,
                &format!(
                    "SELECT reps, last_log_id FROM cards WHERE id = {}",
                    blob(card)
                ),
            )
        };
        assert_eq!(state(&c1), strs(&[["1", "r1"]]));
        assert_eq!(state(&c2), strs(&[["1", "r1"]]));
        // 统计：日志所属的卡可见就归它自己（`caches::stat_groups`），后继继承历史不重复计；两份 Anki 副本只留归属卡
        // 可见的那份。
        assert_eq!(
            rows(&conn, "SELECT log, card FROM stats ORDER BY at, log"),
            strs(&[["a1", z1.as_str()], ["r1", c1.as_str()]])
        );
    }

    /// 删除被并发改动扣住时笔记照常显示；清除抹掉内容，身份记录留着（协议 3 `purge_entity` 同），笔记行还在、内容空。
    #[test]
    fn held_deletes_keep_the_note_and_purges_drop_it() {
        let deck = default_deck_id(P);
        let (a, b) = (fresh("g4ca"), fresh("g4cb"));
        let mut bucket = Bucket::default();
        a.apply(
            T0,
            vec![
                deck_entity(&deck),
                p3_note_type("NT", "standard"),
                edit(
                    "notetype",
                    "NT",
                    "fieldDef/fa",
                    json!({"name": "E", "ord": 0}),
                ),
                edit(
                    "notetype",
                    "NT",
                    "tmplDef/t1",
                    json!({"name": "A", "ord": 0, "front": "{{E}}"}),
                ),
                p3_note(N1, "NT"),
                edit("note", N1, "f/fa", json!("v1")),
            ],
        );
        a.sync(&mut bucket, "loc", T0);
        b.sync(&mut bucket, "loc", T0);
        a.apply(T0 + 1, vec![edit("note", N1, "deleted", json!(T0 + 1))]);
        b.apply(T0 + 2, vec![edit("note", N1, "f/fa", json!("edited on B"))]);
        for _ in 0..2 {
            a.sync(&mut bucket, "loc", T0 + 3);
            b.sync(&mut bucket, "loc", T0 + 3);
        }
        let (conn, diff) = imported(&a);
        assert!(diff.is_empty(), "{diff:?}");
        assert_eq!(
            rows(
                &conn,
                "SELECT deleted_at, (SELECT COUNT(*) FROM cards WHERE hidden = 0) FROM notes"
            ),
            strs(&[["∅", "1"]])
        );
        a.core.sync2_purge(P, "note", N1, T0 + 4).unwrap();
        let (conn, diff) = imported(&a);
        assert!(diff.is_empty(), "{diff:?}");
        assert_eq!(
            rows(&conn, "SELECT sort_field, tags_json FROM notes"),
            strs(&[["", "[]"]])
        );
    }

    // ---------------------------------------------------------------- 原生操作

    const FA: u8 = 0x41;
    const T1: u8 = 0x51;
    const T2: u8 = 0x52;
    const NT: u8 = 0x7a;
    const DECK: u8 = 0x0d;

    fn entity(kind: EntKind, key: Key, data: Value) -> Body4 {
        Body4::Entity {
            kind,
            id: key,
            data: data.to_string(),
        }
    }

    fn set(kind: EntKind, entity: Key, key: &str, value: Value) -> Body4 {
        Body4::Edit(Edit4 {
            kind,
            entity,
            key: key.to_owned(),
            value: value.to_string(),
            ..native_edit()
        })
    }

    fn uuid(b: u8) -> Key {
        Key::Uuid(id(b))
    }

    fn card(template: u8) -> Key {
        Key::of(&card_of(&note().text(), &id(template).text(), 0))
    }

    /// 一条评分。没有配置快照（`sc`），重放不重算、按作者给的结果（[reps]）走——这里测的是哪些日志生效、算在哪张卡上。
    fn log(lid: u8, template: u8, at: i64, rating: i64, rtype: &str, reps: i64) -> Body4 {
        Body4::Log(Log4 {
            id: uuid(lid),
            card: card(template),
            note: None,
            kind: "review".into(),
            rating: Some(rating),
            revokes: None,
            at,
            ts: 1,
            origin: "fushi".into(),
            rtype: rtype.into(),
            dur: 1000,
            params: None,
            alg: None,
            utc_off: 0,
            rollover: 4,
            anki_id: None,
            fv: 1,
            intent: Intent::Answer,
            res: Some(
                json!({"queue": "review", "dueDay": 20_000 + reps, "ivl": 1, "step": 0, "reps": reps, "lapses": 0,
                       "scheduler": "fushi", "lastReviewedAt": at})
                .to_string(),
            ),
            extra: "{}".into(),
            hlc: None,
            server_time: None,
        })
    }

    fn undo(lid: u8, template: u8, at: i64, revokes: u8) -> Body4 {
        let Body4::Log(mut l) = log(lid, template, at, 0, "manual", 0) else {
            unreachable!()
        };
        l.kind = "undo".into();
        l.rating = None;
        l.revokes = Some(uuid(revokes));
        l.intent = Intent::Absolute;
        l.res = None;
        Body4::Log(l)
    }

    fn tag(t: &str) -> Body4 {
        Body4::TagAdd {
            note: note(),
            tag: t.to_owned(),
        }
    }

    fn field() -> String {
        format!("f/{}", id(FA).text())
    }

    /// 一台设备的一步：(seq, HLC 物理时刻, 见过的别的设备, 操作体)。
    type Step = (u64, i64, Vec<(u8, u64)>, Body4);

    /// 设备 a1：牌组、笔记类型（一个字段、两个模板）、笔记、字段、标签、两条评分；设备 b2：与 a1 并发改同一字段、
    /// 再评一次、撤销 a1 的第二条、第二张卡继承第一张、加标签。
    fn script() -> (Vec<Step>, Vec<Step>) {
        let n = note;
        let nt_key = |k: &str, b: u8| format!("{k}/{}", id(b).text());
        let a: Vec<Step> = vec![
            (
                1,
                100,
                vec![],
                entity(
                    EntKind::Deck,
                    uuid(DECK),
                    json!({"createdAt": 1, "builtin": "default"}),
                ),
            ),
            (
                2,
                200,
                vec![],
                entity(
                    EntKind::NoteType,
                    uuid(NT),
                    json!({"createdAt": 1, "ntKind": "standard"}),
                ),
            ),
            (
                3,
                300,
                vec![],
                set(
                    EntKind::NoteType,
                    uuid(NT),
                    &nt_key("fieldDef", FA),
                    json!({"name": "E", "ord": 0}),
                ),
            ),
            (
                4,
                400,
                vec![],
                set(
                    EntKind::NoteType,
                    uuid(NT),
                    &nt_key("tmplDef", T1),
                    json!({"name": "A", "ord": 0, "front": "{{E}}"}),
                ),
            ),
            (
                5,
                500,
                vec![],
                set(
                    EntKind::NoteType,
                    uuid(NT),
                    &nt_key("tmplDef", T2),
                    json!({"name": "B", "ord": 1, "front": "{{E}}"}),
                ),
            ),
            (
                6,
                600,
                vec![],
                entity(
                    EntKind::Note,
                    n(),
                    json!({"createdAt": 1, "guid": "g", "noteTypeId": id(NT).text()}),
                ),
            ),
            (
                7,
                700,
                vec![],
                set(EntKind::Note, n(), &field(), json!("猫")),
            ),
            (8, 800, vec![], tag("x")),
            (9, T0, vec![], log(0x91, T1, T0, 3, "learn", 1)),
            (
                10,
                T0 + 2 * DAY,
                vec![],
                log(0x92, T1, T0 + 2 * DAY, 3, "review", 3),
            ),
        ];
        let b: Vec<Step> = vec![
            (
                1,
                150,
                vec![(0xa1, 6)],
                set(EntKind::Note, n(), &field(), json!("犬")),
            ),
            (
                2,
                T0 + DAY,
                vec![(0xa1, 9)],
                log(0x93, T1, T0 + DAY, 2, "review", 2),
            ),
            (
                3,
                T0 + 3 * DAY,
                vec![(0xa1, 10)],
                undo(0x94, T1, T0 + 3 * DAY, 0x92),
            ),
            (
                4,
                T0 + 3 * DAY + 1,
                vec![(0xa1, 10)],
                set(
                    EntKind::Card,
                    card(T2),
                    &format!("historyFrom/{}", card(T1).text()),
                    json!(true),
                ),
            ),
            (5, 550, vec![(0xa1, 8)], tag("y")),
        ];
        (a, b)
    }

    fn put_cfg(t: &Truth<'_>, col: i64) {
        let cfg = json!({"defaultDeck": id(DECK).text()}).to_string();
        t.tx(|t| t.set_derive_cfg(col, CFG_KEY, Some(&cfg)))
            .unwrap();
    }

    fn land(t: &Truth<'_>, ix: &mut Index<'_, '_>, col: i64, dev: u8, step: &Step) {
        native(t, ix, col, &op(dev, step.0, step.1, &step.2, &step.3));
    }

    #[test]
    fn native_ops_materialize_notes_cards_replay_and_stats() {
        with(|t, col| {
            put_cfg(t, col);
            let (a, b) = script();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                for s in &a {
                    land(t, &mut ix, col, 0xa1, s);
                }
                for s in &b {
                    land(t, &mut ix, col, 0xb2, s);
                }
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            let conn = t.conn();
            // 并发写同一字段：HLC 大的胜（a1 的 700）；内容最后被改的时刻 = 活着的写入与没清除的标签里最大的 HLC
            // 物理时刻（a1 的标签 800）。
            assert_eq!(
                rows(
                    conn,
                    "SELECT sort_field, tags_json, updated_at, deleted_at FROM notes"
                ),
                strs(&[["猫", r#"["y","x"]"#, "800", "∅"]])
            );
            let (c1, c2) = (card(T1).text(), card(T2).text());
            // 评分 0x91、0x93 生效，0x92 被撤销；第二张卡继承第一张的历史。
            let st = |c: &str| -> Vec<Vec<String>> {
                rows(
                    conn,
                    &format!(
                        "SELECT reps, last_log_id, hidden FROM cards WHERE id = {}",
                        blob(c)
                    ),
                )
            };
            let last = id(0x93).text();
            assert_eq!(st(&c1), strs(&[["2", last.as_str(), "0"]]));
            assert_eq!(st(&c2), strs(&[["2", last.as_str(), "0"]]));
            let (r1, r3) = (id(0x91).text(), id(0x93).text());
            assert_eq!(
                rows(conn, "SELECT log, card FROM stats ORDER BY at"),
                strs(&[[r1.as_str(), c1.as_str()], [r3.as_str(), c1.as_str()]])
            );
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 不可信设备的删除不落、确认之后落（卡随笔记隐藏）；与删除并发的内容改动把它扣住；清除抹掉内容（笔记行留着、
    /// 字段与标签空）。每一步逐条维护的结果都与整份重建相同。
    #[test]
    fn distrusted_held_and_purged_deletes_reach_the_caches() {
        with(|t, col| {
            put_cfg(t, col);
            let (a, _) = script();
            let deleted = || rows(t.conn(), "SELECT deleted_at FROM notes")[0][0].clone();
            let hidden = || rows(t.conn(), "SELECT SUM(hidden) FROM cards")[0][0].clone();
            t.tx(|t| {
                t.set_trust(col, &id(0xb2), Some(TRUST_PENDING), 7)?;
                let mut ix = Index::new(t, col);
                for s in &a[..8] {
                    land(t, &mut ix, col, 0xa1, s);
                }
                let del = set(EntKind::Note, note(), "deleted", json!(900));
                land(t, &mut ix, col, 0xb2, &(1, 900, vec![(0xa1, 8)], del));
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            assert_eq!((deleted(), hidden()), ("∅".to_owned(), "0".to_owned()));
            assert_rebuild_is_identity(t, col);
            t.tx(|t| {
                t.set_trust(col, &id(0xb2), None, 0)?;
                let mut ix = Index::new(t, col);
                ix.trust_changed();
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            assert_eq!((deleted(), hidden()), ("900".to_owned(), "2".to_owned()));
            assert_rebuild_is_identity(t, col);
            // 没见过这条删除的内容改动：删除被扣住，笔记照常显示。
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let late = set(EntKind::Note, note(), &field(), json!("鳥"));
                land(t, &mut ix, col, 0xc3, &(1, 950, vec![(0xa1, 6)], late));
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            assert_eq!((deleted(), hidden()), ("∅".to_owned(), "0".to_owned()));
            assert_rebuild_is_identity(t, col);
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let deps = [(0xb2, 1), (0xc3, 1)];
                let purge = Body4::Purge {
                    kind: EntKind::Note,
                    entity: note(),
                };
                native(t, &mut ix, col, &op(0xa1, 9, 990, &deps, &purge));
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            assert_eq!(
                rows(t.conn(), "SELECT sort_field, tags_json FROM notes"),
                strs(&[["", "[]"]])
            );
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 身份记录不成形的笔记（缺 `noteTypeId`）没有行，别的笔记照常物化，收尾不失败。
    #[test]
    fn a_malformed_note_gets_no_rows_and_does_not_block_the_rest() {
        with(|t, col| {
            put_cfg(t, col);
            let (a, _) = script();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                for s in &a[..7] {
                    land(t, &mut ix, col, 0xa1, s);
                }
                let bad = entity(EntKind::Note, uuid(0x33), json!({"createdAt": 1}));
                land(t, &mut ix, col, 0xb2, &(1, 900, vec![], bad));
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            assert_eq!(
                rows(t.conn(), "SELECT id FROM notes"),
                strs(&[[note().text().as_str()]])
            );
            assert_eq!(rows(t.conn(), "SELECT COUNT(*) FROM cards"), strs(&[["2"]]));
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 没设缓存配置：不物化；设了之后 `rebuild_caches` 只重建这一层，与整份重建相同。
    #[test]
    fn without_a_config_nothing_is_materialized_and_rebuild_caches_fills_it() {
        with(|t, col| {
            let (a, b) = script();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                for s in &a {
                    land(t, &mut ix, col, 0xa1, s);
                }
                land(t, &mut ix, col, 0xb2, &b[0]);
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            for table in ["notes", "cards", "stats"] {
                assert!(rows(t.conn(), &format!("SELECT * FROM {table}")).is_empty());
            }
            put_cfg(t, col);
            let did = t.tx(|t| Index::new(t, col).rebuild_caches()).unwrap();
            assert_eq!((did.cache_notes, did.cache_cards), (1, 2));
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 笔记类型的名字、CSS、字段说明不进笔记 / 卡行（协议 3 `note_type_key_affects_caches`）：改它们不把这一类的笔记
    /// 重算（H5 读放大，交接 §26 C5）；改词条字段、模板照样重算这一类。每一步之后增量与重建相同。
    #[test]
    fn note_type_keys_outside_the_rows_do_not_recompute_its_notes() {
        with(|t, col| {
            put_cfg(t, col);
            let (a, _) = script();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                for s in &a {
                    land(t, &mut ix, col, 0xa1, s);
                }
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            let nt_key = |k: &str, b: u8| format!("{k}/{}", id(b).text());
            let steps: [(String, Value, u64); 6] = [
                ("name".to_owned(), json!("Renamed"), 0),
                ("css".to_owned(), json!(".card {}"), 0),
                (nt_key("fieldDesc", FA), json!("the word"), 0),
                ("termField".to_owned(), json!(id(FA).text()), 1),
                (
                    nt_key("tmplDef", T1),
                    json!({"name": "A2", "ord": 0, "front": "{{E}}!"}),
                    1,
                ),
                ("name".to_owned(), json!("Again"), 0),
            ];
            for (i, (key, value, want)) in steps.iter().enumerate() {
                let i = i as u64;
                let did = t
                    .tx(|t| {
                        let mut ix = Index::new(t, col);
                        let step: Step = (
                            i + 1,
                            900 + i as i64,
                            vec![],
                            set(EntKind::NoteType, uuid(NT), key, value.clone()),
                        );
                        land(t, &mut ix, col, 0xc3, &step);
                        ix.settle()
                    })
                    .unwrap();
                assert_eq!(did.cache_notes, *want, "{key}");
                assert_rebuild_is_identity(t, col);
            }
        });
    }

    // ---------------------------------------------------------------- 按规范 ID 物化（G9-2）

    const U1: &str = "0192f0aa-0000-7000-8000-00000000000a";
    const U2: &str = "0192f0aa-0000-7000-8000-00000000000b";
    const ANKI_NT: i64 = 1_700_000_000_001;

    /// 同一条笔记（guid `g`）在两个盐下各一份：两份的笔记类型、字段、模板、笔记、卡都带盐，规范 ID 是不带盐的同一套。
    struct Twin {
        nt: [crate::sync2::id::Id; 2],
        note: [crate::sync2::id::Id; 2],
        card: [Key; 2],
        c_note: String,
        c_card: String,
    }

    fn twin() -> Twin {
        use crate::gen4_ids::rules::{self, CANONICAL};
        let nt = [
            rules::note_type(Some(U1), ANKI_NT),
            rules::note_type(Some(U2), ANKI_NT),
        ];
        let note = [rules::note(Some(U1), "g"), rules::note(Some(U2), "g")];
        let card = |n: &crate::sync2::id::Id, t: &crate::sync2::id::Id| {
            Key::of(&card_of(&n.text(), &rules::template(t, 0).text(), 0))
        };
        let c_nt = rules::note_type(CANONICAL, ANKI_NT);
        let c_note = rules::note(CANONICAL, "g");
        Twin {
            card: [card(&note[0], &nt[0]), card(&note[1], &nt[1])],
            nt,
            note,
            c_card: card(&c_note, &c_nt).text(),
            c_note: c_note.text(),
        }
    }

    /// 评分 [lid] 落在卡 [card] 上。
    fn log_on(lid: u8, card: &Key, at: i64, reps: i64) -> Body4 {
        let Body4::Log(mut l) = log(lid, T1, at, 3, "review", reps) else {
            unreachable!()
        };
        l.card = card.clone();
        Body4::Log(l)
    }

    /// 两份的定义、内容、标签与评分（不含盐）：第一份标签 `x`、评分 0x91；第二份标签 `y`、见过 0x91 之后评分 0x93。
    fn twin_steps(w: &Twin) -> Vec<Body4> {
        use crate::gen4_ids::rules;
        let mut out = vec![entity(
            EntKind::Deck,
            uuid(DECK),
            json!({"createdAt": 1, "builtin": "default"}),
        )];
        for i in 0..2 {
            let nt = Key::Uuid(w.nt[i]);
            let f = rules::field(&w.nt[i], 0).text();
            let t = rules::template(&w.nt[i], 0).text();
            let n = Key::Uuid(w.note[i]);
            out.push(entity(
                EntKind::NoteType,
                nt.clone(),
                json!({"createdAt": 1, "ntKind": "standard", "ankiNum": ANKI_NT}),
            ));
            out.push(set(
                EntKind::NoteType,
                nt.clone(),
                &format!("fieldDef/{f}"),
                json!({"ankiNum": 0, "name": "E", "ord": 0}),
            ));
            out.push(set(
                EntKind::NoteType,
                nt,
                &format!("tmplDef/{t}"),
                json!({"ankiNum": 0, "name": "A", "ord": 0, "front": "{{E}}"}),
            ));
            out.push(entity(
                EntKind::Note,
                n.clone(),
                json!({"createdAt": 1, "guid": "g", "noteTypeId": w.nt[i].text()}),
            ));
            out.push(set(
                EntKind::Note,
                n.clone(),
                &format!("f/{f}"),
                json!("猫"),
            ));
            out.push(Body4::TagAdd {
                note: n,
                tag: ["x", "y"][i].to_owned(),
            });
        }
        out.push(log_on(0x91, &w.card[0], T0, 1));
        out.push(log_on(0x93, &w.card[1], T0 + DAY, 2));
        out
    }

    fn feed(t: &Truth<'_>, ix: &mut Index<'_, '_>, col: i64, seq0: u64, bodies: &[Body4]) {
        for (i, b) in bodies.iter().enumerate() {
            let seq = seq0 + i as u64;
            native(t, ix, col, &op(0xa1, seq, 100 + seq as i64, &[], b));
        }
    }

    /// 两份合成一个类之后的缓存：一行规范笔记（标签并起来）、一张规范卡（两条评分都算在它名下）、两行统计。
    fn assert_one_canonical_note(conn: &Connection, w: &Twin) {
        let tags: Vec<String> = rows(conn, "SELECT id, tags_json FROM notes")
            .into_iter()
            .map(|r| {
                assert_eq!(r[0], w.c_note);
                r[1].clone()
            })
            .collect();
        assert_eq!(tags.len(), 1, "{tags:?}");
        let mut got: Vec<String> = serde_json::from_str(&tags[0]).unwrap();
        got.sort();
        assert_eq!(got, ["x", "y"]);
        let last = id(0x93).text();
        assert_eq!(
            rows(conn, "SELECT id, note_id, reps, last_log_id FROM cards"),
            strs(&[[w.c_card.as_str(), w.c_note.as_str(), "2", last.as_str()]])
        );
        let (r1, r3) = (id(0x91).text(), id(0x93).text());
        assert_eq!(
            rows(conn, "SELECT log, card FROM stats ORDER BY at"),
            strs(&[
                [r1.as_str(), w.c_card.as_str()],
                [r3.as_str(), w.c_card.as_str()]
            ])
        );
    }

    /// 两个盐下各一份的同一条笔记：缓存层只有规范 ID 的一行笔记、一张卡，两份的标签与评分都归到它名下；逐条维护与整份
    /// 重建相同。
    #[test]
    fn salted_copies_materialize_as_one_canonical_note_and_card() {
        with(|t, col| {
            put_cfg(t, col);
            let w = twin();
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let mut steps = vec![Body4::salts([U1, U2]).unwrap()];
                steps.extend(twin_steps(&w));
                feed(t, &mut ix, col, 1, &steps);
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            assert_one_canonical_note(t.conn(), &w);
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 带盐的内置笔记类型（Lapis）：字段只在宿主缓存配置的代码默认定义里（没有 `fieldDef/` 修改），字段 ID 只嵌在笔记的
    /// `f/<字段>` 键里、从不作为实体出现，别名表里没有它。配置按内置规则归一到规范字段 ID，键里的字段 ID 必须按同一份
    /// 规则归一，笔记行才拿得到字段值（以前键只查别名表、保持带盐 ID，排序字段 / 词条全空，预演对拍报 notes / cards 不同）。
    #[test]
    fn salted_builtin_note_fields_reach_the_canonical_note_row() {
        use crate::gen4_ids::rules;
        with(|t, col| {
            let num = rules::builtin_note_type_anki_num("lapis");
            let nt = rules::note_type(Some(U1), num);
            let f = rules::field(&nt, rules::builtin_field_anki_num("lapis", "Expression")).text();
            let tpl =
                rules::template(&nt, rules::builtin_template_anki_num("lapis", "Card 1")).text();
            let note = rules::note(Some(U1), "g");
            let cfg = json!({
                "defaultDeck": id(DECK).text(),
                "builtins": {"lapis": {"b": {
                    "name": "Lapis", "css": "", "termFieldId": f,
                    "fields": [{"id": f, "name": "Expression", "ord": 0}],
                    "templates": [{"id": tpl, "name": "Card 1", "ord": 0, "front": "{{Expression}}", "back": ""}],
                }, "reading": null}},
            })
            .to_string();
            t.tx(|t| t.set_derive_cfg(col, CFG_KEY, Some(&cfg)))
                .unwrap();
            let steps = vec![
                Body4::salts([U1]).unwrap(),
                entity(
                    EntKind::Deck,
                    uuid(DECK),
                    json!({"createdAt": 1, "builtin": "default"}),
                ),
                entity(
                    EntKind::NoteType,
                    Key::Uuid(nt),
                    json!({"createdAt": 1, "ntKind": "standard", "builtin": "lapis", "ankiNum": num}),
                ),
                entity(
                    EntKind::Note,
                    Key::Uuid(note),
                    json!({"createdAt": 1, "guid": "g", "noteTypeId": nt.text()}),
                ),
                set(
                    EntKind::Note,
                    Key::Uuid(note),
                    &format!("f/{f}"),
                    json!("猫"),
                ),
            ];
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 1, &steps);
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            assert_eq!(
                rows(t.conn(), "SELECT id, sort_field FROM notes"),
                strs(&[[rules::note(rules::CANONICAL, "g").text().as_str(), "猫"]])
            );
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 缓存已按原 ID 物化之后盐才到（别名表变了）：原 ID 的行删掉，按规范 ID 重算写回，与盐先到的结果相同、与整份重建
    /// 相同。改别名的批次里写入者没动、变动的 ID 不多，走的是逐个 ID 的就地维护（`refresh_caches`）。
    #[test]
    fn salts_arriving_after_the_caches_move_rows_onto_canonical_ids() {
        with(|t, col| {
            put_cfg(t, col);
            let w = twin();
            let steps = twin_steps(&w);
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 1, &steps);
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            assert_eq!(rows(t.conn(), "SELECT COUNT(*) FROM notes")[0][0], "2");
            assert_eq!(rows(t.conn(), "SELECT COUNT(*) FROM cards")[0][0], "2");
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let salts = [Body4::salts([U1, U2]).unwrap()];
                feed(t, &mut ix, col, steps.len() as u64 + 1, &salts);
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            assert_one_canonical_note(t.conn(), &w);
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 改别名的批次在 `hold_aliases` 下：缓存不跟着半新半旧的别名表刷，放开后补齐，与整份重建相同。
    #[test]
    fn held_aliases_defer_the_cache_refresh_and_catch_up() {
        with(|t, col| {
            put_cfg(t, col);
            let w = twin();
            let steps = twin_steps(&w);
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                feed(t, &mut ix, col, 1, &steps);
                ix.settle()?;
                ix.hold_aliases(true);
                let salts = [Body4::salts([U1, U2]).unwrap()];
                feed(t, &mut ix, col, steps.len() as u64 + 1, &salts);
                ix.settle()?;
                ix.hold_aliases(false);
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            assert_one_canonical_note(t.conn(), &w);
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 写入者归回发生在一批只碰了别的实体的操作里（证据落在另一条笔记的 `proof` 键上）：按类判的寄存器都可能变，
    /// 缓存层整层重建（`refresh_caches` 的 `writers_moved`）。被测笔记的字段寄存器里 `(merged, 2)` 与 `(v, 1)` HLC
    /// 平手：归回之前原名 `merged-…` < `v`，`v` 那条胜；归回之后 `w1` > `v`，`merged` 那条胜（「三处一起换」）。这条
    /// 笔记不在这一批碰到的实体里，只有整层重建才会更新它的 `sort_field`。
    #[test]
    fn a_writer_moving_back_rebuilds_rows_the_batch_did_not_touch() {
        use crate::gen4_ids::rules;
        use crate::store::gen4::derive::tests::{heritage, stamp};
        with(|t, col| {
            put_cfg(t, col);
            let w = twin();
            let merged = format!("merged-{}~w1", rules::merged_writer_hash(U1, "w1").text());
            let f0 = format!("f/{}", rules::field(&w.nt[0], 0).text());
            let write = |entity: &crate::sync2::id::Id, key: &str, value: &str, s| {
                Body4::Edit(Edit4 {
                    kind: EntKind::Note,
                    entity: Key::Uuid(*entity),
                    key: key.to_owned(),
                    value: format!("\"{value}\""),
                    stamp: Some(s),
                    ..native_edit()
                })
            };
            // 两份笔记都不写原生的字段内容：被测寄存器里只有两条带旧戳的写入。
            let steps: Vec<Body4> = twin_steps(&w)
                .into_iter()
                .filter(|b| !matches!(b, Body4::Edit(e) if e.key.starts_with("f/")))
                .collect();
            let sort_field = |conn: &Connection| -> String {
                rows(
                    conn,
                    &format!(
                        "SELECT sort_field FROM notes WHERE id = {}",
                        blob(&w.c_note)
                    ),
                )[0][0]
                    .clone()
            };
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let mut first = vec![Body4::salts([U1]).unwrap()];
                first.extend(steps.iter().cloned());
                feed(t, &mut ix, col, 1, &first);
                let a = write(&w.note[0], &f0, "a", stamp(&merged, 2, r#"{"vv":{}}"#, 100));
                let b = write(&w.note[0], &f0, "b", stamp("v", 1, r#"{"vv":{}}"#, 100));
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &a));
                heritage(t, &mut ix, col, op(0xd2, 1, 2, &[], &b));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, merged);
                Ok(())
            })
            .unwrap();
            assert_eq!(sort_field(t.conn()), "b");
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let proof =
                    |wr: &str| write(&w.note[1], "proof", "p", stamp(wr, 1, r#"{"vv":{}}"#, 50));
                heritage(t, &mut ix, col, op(0xc1, 1, 3, &[], &proof("w1")));
                heritage(t, &mut ix, col, op(0xc2, 1, 4, &[], &proof(&merged)));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                Ok(())
            })
            .unwrap();
            assert_eq!(sort_field(t.conn()), "a");
            assert_rebuild_is_identity(t, col);
        });
    }

    /// 名字表不变、只有归回写入者的证据范围变了（BUG-5056 的 `aliasWriterUpto`）：一样整层重建。被测笔记的字段寄存器
    /// 里 `(w1, 2)`（HLC 100）与 `(v, 1)`（上下文 `merged:2`、HLC 90）：范围只到 seq 1 时 `merged:2` 证不到盖住
    /// `(w1, 2)`，两条并发、HLC 大的 `a` 胜；另一条笔记上来了 `(merged, 2)` 与 `(w1, 2)` 的同一条记录，范围升到 2，
    /// `b` 支配 `a`。这条笔记不在这一批碰到的实体里，只有整层重建才会更新它的 `sort_field`。
    #[test]
    fn a_writer_bound_moving_rebuilds_rows_the_batch_did_not_touch() {
        use crate::gen4_ids::rules;
        use crate::store::gen4::derive::tests::{heritage, stamp};
        with(|t, col| {
            put_cfg(t, col);
            let w = twin();
            let merged = format!("merged-{}~w1", rules::merged_writer_hash(U1, "w1").text());
            let f0 = format!("f/{}", rules::field(&w.nt[0], 0).text());
            let write = |entity: &crate::sync2::id::Id, key: &str, value: &str, s| {
                Body4::Edit(Edit4 {
                    kind: EntKind::Note,
                    entity: Key::Uuid(*entity),
                    key: key.to_owned(),
                    value: format!("\"{value}\""),
                    stamp: Some(s),
                    ..native_edit()
                })
            };
            let steps: Vec<Body4> = twin_steps(&w)
                .into_iter()
                .filter(|b| !matches!(b, Body4::Edit(e) if e.key.starts_with("f/")))
                .collect();
            let sort_field = |conn: &Connection| -> String {
                rows(
                    conn,
                    &format!(
                        "SELECT sort_field FROM notes WHERE id = {}",
                        blob(&w.c_note)
                    ),
                )[0][0]
                    .clone()
            };
            let proof = |wr: &str, seq: i64, physical: i64| {
                write(
                    &w.note[1],
                    "proof",
                    "p",
                    stamp(wr, seq, r#"{"vv":{}}"#, physical),
                )
            };
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let mut first = vec![Body4::salts([U1]).unwrap()];
                first.extend(steps.iter().cloned());
                feed(t, &mut ix, col, 1, &first);
                heritage(t, &mut ix, col, op(0xc1, 1, 1, &[], &proof("w1", 1, 50)));
                heritage(t, &mut ix, col, op(0xc2, 1, 2, &[], &proof(&merged, 1, 50)));
                let ctx = format!(r#"{{"vv":{{"{merged}":2}}}}"#);
                let a = write(&w.note[0], &f0, "a", stamp("w1", 2, r#"{"vv":{}}"#, 100));
                let b = write(&w.note[0], &f0, "b", stamp("v", 1, &ctx, 90));
                heritage(t, &mut ix, col, op(0xd1, 1, 3, &[], &a));
                heritage(t, &mut ix, col, op(0xd2, 1, 4, &[], &b));
                ix.settle()?;
                assert_eq!(ix.canonical_writer(&merged)?, "w1");
                assert_eq!(ix.writer_aliases()?.bound(&merged).map(|b| b.upto), Some(1));
                Ok(())
            })
            .unwrap();
            assert_eq!(sort_field(t.conn()), "a");
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                heritage(
                    t,
                    &mut ix,
                    col,
                    op(0xc3, 1, 5, &[], &proof(&merged, 2, 100)),
                );
                ix.settle()?;
                assert_eq!(ix.writer_aliases()?.bound(&merged).map(|b| b.upto), Some(2));
                Ok(())
            })
            .unwrap();
            assert_eq!(sort_field(t.conn()), "b");
            assert_rebuild_is_identity(t, col);
        });
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(48))]

        /// 任意到达顺序（两台设备各自按序、彼此任意交错）、任意收尾时机：逐条维护出来的缓存层与整份重建相同。
        #[test]
        fn any_arrival_order_maintains_the_same_caches(
            picks in proptest::collection::vec(any::<bool>(), 15),
            settles in proptest::collection::vec(any::<bool>(), 15),
        ) {
            with(|t, col| {
                put_cfg(t, col);
                let (a, b) = script();
                t.tx(|t| {
                    let mut ix = Index::new(t, col);
                    let (mut i, mut j) = (0, 0);
                    for k in 0..a.len() + b.len() {
                        if (picks[k] && i < a.len()) || j == b.len() {
                            land(t, &mut ix, col, 0xa1, &a[i]);
                            i += 1;
                        } else {
                            land(t, &mut ix, col, 0xb2, &b[j]);
                            j += 1;
                        }
                        if settles[k] {
                            ix.settle()?;
                        }
                    }
                    ix.settle()?;
                    Ok(())
                })
                .unwrap();
                assert_eq!(rows(t.conn(), "SELECT COUNT(*) FROM stats")[0][0], "2");
                assert_rebuild_is_identity(t, col);
            });
        }
    }

    /// [super::CACHE_RULES] 与派生排序键的实际口径对表（交接 §44「第六波 导入红测试收尾」）。每一行是一条派生输入、
    /// 当前口径下的输出、以及让这一行输出成为现在这样的那一版修订号（文档注释里的修订表）。
    ///
    /// 钉两件事：
    /// - 派生口径改了（任一行输出变了）就红——改的人要在这里改期望、把那一行的修订号记成新的一版，并升 `CACHE_RULES`；
    /// - 表里最新一版必须等于 `CACHE_RULES`：常量退回去（比如退回 2，`op_wall` 上界还在）就红。
    ///   `a_cache_built_under_older_rules_is_rebuilt_once_on_open` 只钉「旧口径的库开库重建一次」，钉不住这一条。
    #[test]
    fn cache_rules_matches_the_pinned_derivation_table() {
        use crate::anki_import_rules::derived_log_hlc;

        const FOREIGN: &str = r#"{"foreignLog":true}"#;
        // (说明, origin, kind, anki_id, at, extra, op_wall, 期望, 修订号)
        type Row = (
            &'static str,
            &'static str,
            &'static str,
            Option<i64>,
            i64,
            &'static str,
            i64,
            Option<&'static str>,
            i64,
        );
        let table: [Row; 8] = [
            (
                "原生日志：用操作 HLC",
                "dev-a",
                "review",
                None,
                1_000,
                "{}",
                2_000,
                None,
                0,
            ),
            (
                "Anki revlog：(ankiId, 0, anki)，不看操作时刻",
                "anki",
                "review",
                Some(1_699_999_999_000),
                1_699_999_999_000,
                "{}",
                1,
                Some("1699999999000:0:anki"),
                1,
            ),
            (
                "Anki 导入锚点：(at, 1, anki)",
                "anki",
                "importAnchor",
                None,
                1_700_000_000_000,
                "{}",
                1,
                Some("1700000000000:1:anki"),
                1,
            ),
            (
                "外来日志早于操作：(at, 0, fushi)",
                "dev-b",
                "review",
                None,
                1_000,
                FOREIGN,
                2_000,
                Some("1000:0:fushi"),
                2,
            ),
            (
                "外来日志与操作同一毫秒：仍派生",
                "dev-b",
                "review",
                None,
                2_000,
                FOREIGN,
                2_000,
                Some("2000:0:fushi"),
                2,
            ),
            (
                "外来标记不是 true：用操作 HLC",
                "dev-b",
                "review",
                None,
                1_000,
                r#"{"foreignLog":"true"}"#,
                2_000,
                None,
                2,
            ),
            (
                "外来日志晚于操作（伪造的未来时刻）：不派生",
                "dev-b",
                "review",
                None,
                3_000,
                FOREIGN,
                2_000,
                None,
                3,
            ),
            (
                "外来日志远在未来：不派生",
                "dev-b",
                "review",
                None,
                i64::MAX,
                FOREIGN,
                2_000,
                None,
                3,
            ),
        ];
        for (what, origin, kind, anki_id, at, extra, op_wall, want, _) in table {
            assert_eq!(
                derived_log_hlc(origin, kind, anki_id, at, extra, op_wall).as_deref(),
                want,
                "{what}：派生口径变了，改期望、记新修订号并升 CACHE_RULES"
            );
        }
        // 不在日志排序键上的修订（各自由对应模块的测试钉口径）：(说明, 修订号)。
        const ELSEWHERE: [(&str, i64); 1] = [(
            "改名写入者的旧上下文只换到归回上界（class.rs 的 bounded_writer_rename_* 测试）",
            4,
        )];
        let latest = table
            .iter()
            .map(|r| r.8)
            .chain(ELSEWHERE.iter().map(|r| r.1))
            .max()
            .unwrap();
        assert_eq!(
            super::CACHE_RULES,
            latest,
            "CACHE_RULES 与派生口径对表的最新修订号不一致"
        );
    }
}
