//! 缓存层（设计 §2.2 的 `notes` / `cards`、§2.3 的统计列、§2.5 的「物化笔记 / 卡片缓存（逐卡重放）」）：出卡、浏览、
//! 统计读的三张表。全部是「索引（`derive.rs` / `weigh.rs`）+ 宿主给的缓存配置」的纯函数：[Index::rebuild_all] 最后
//! 整份物化，[Index::settle] 收尾时只重算这一批碰到的笔记 / 卡，两条路出来的行逐行相同（测试与 `parity.rs` 钉死）。
//!
//! **行值只有一份实现**：从索引拼出协议 3 那批纯函数要的输入——实体的身份记录、活着的修改行（`derive.rs`
//! [Index::edit_lines]，冻结判定同一份拼法）、标签（[Index::tags_of]）、日志的投影行 JSON（`store/sync2` 的
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
//! # 别名的接缝（设计 §5.3）
//!
//! 缓存层里所有「取一个实体 / 卡 / 日志的 ID」都经 [Index::canon]（现在恒等），读一个规范 ID 的东西都经
//! [Index::class_of]（这个类的全部原值 ID，现在只有它自己）：身份记录取第一个有定义的成员、修改行与日志按成员并起来
//! （dot 与日志 ID 本来就各自唯一，并集就是归并）。内嵌在键里的 ID（`historyFrom/<卡>`）经 [Index::canon_text]。
//! 标签目前按规范 ID 直接取（[Index::tags_of]），别名层接上时把成员的 `tag_ix` 行并起来再判。
//!
//! # 与协议 3 的差别（都是「协议 3 依赖到达顺序 / 本机状态」）
//!
//! - `updated_at`、`server_time` 见上。
//! - 不成形的身份记录：笔记身份记录 / 修改算不出视图（缺 `noteTypeId`、字段类型不对）或笔记 ID 不是 UUID（卡 ID 由它
//!   派生）时这条笔记没有行（也没有卡行），
//!   笔记类型算不出时当作不在；协议 3 的 `caches::rebuild` / `refresh` 在这里整次失败。对拍在协议 3 这样失败时不比
//!   缓存三类（`parity.rs` [cache_pairs] 的口径）。
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

use rusqlite::params;
use rusqlite::types::ValueRef;
use serde_json::{Value, json};

use super::derive::{Index, R_LIVE, Ref, Reg, Settled, body_of};
use super::schema::sql;
use crate::gen4::heritage::SlotBody;
use crate::gen4::name::{read_edit_key, write_edit_key};
use crate::gen4::op::{Body4, Log4};
use crate::history::{self, StoredLog};
use crate::registers::{self, StoredEdit};
use crate::store::caches::{
    self, AnkiStatKey, CacheConfig, Material, NoteInfo, TypeInfo, add_descendants,
    anki_duplicate_log_ids, card_row, note_row, sorted_ids, stat_groups,
};
use crate::store::sync2::{canonical, config, group_lineage, log_json, tails_with};
use crate::sync2::codec::{Reader, Writer};
use crate::sync2::id::Key;
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
CREATE INDEX IF NOT EXISTS reg_card_key ON reg_ix (col, key) WHERE ekind = 4;
CREATE INDEX IF NOT EXISTS log_at ON log_ix (col, at);
";

/// 缓存层的三张表。
const TABLES: [&str; 3] = ["notes", "cards", "stats"];

/// `derive_cfg` 里缓存配置的键。
pub const CFG_KEY: &str = "caches";

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

    pub(super) fn registers(&mut self, regs: &BTreeSet<Reg>) {
        for r in regs {
            self.entity(r.ekind, &r.ent);
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

/// 一条日志（规范日志 ID 的代表）在缓存层的样子。
struct LogIn {
    json: String,
    server_time: Option<i64>,
    intent: Intent,
}

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

fn log_body(l: Log4) -> LogBody {
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
        legacy_hlc: l.hlc.map(|h| h.text()),
        legacy_server_time: l.server_time,
    }
}

fn is_anki_review(l: &Log4) -> bool {
    l.origin == "anki" && (l.kind == "review" || l.kind == "manual")
}

impl<'t, 'c> Index<'t, 'c> {
    // ------------------------------------------------------------ 别名的接缝

    /// 一个 ID 的规范 ID（设计 §5.3）。别名层接上之前恒等。
    pub fn canon(&self, id: &Ref) -> Ref {
        id.clone()
    }

    /// 一个规范 ID 的别名类：它的全部原值 ID（规范 ID 自己在前）。别名层接上之前只有它自己——快路径。
    pub fn class_of(&self, canon: &Ref) -> Vec<Ref> {
        vec![canon.clone()]
    }

    /// 文本形式的 ID（嵌在修改键 / 值里的）的规范形。
    pub fn canon_text(&self, text: &str) -> String {
        self.canon(&ref_of(text)).text()
    }

    // ------------------------------------------------------------ 入口

    fn cache_config(&self) -> Result<Option<CacheConfig>, String> {
        let Some(text) = self.t.derive_cfg(self.col, CFG_KEY)? else {
            return Ok(None);
        };
        let v: Value =
            serde_json::from_str(&text).map_err(|e| format!("gen4 cache: bad config: {e}"))?;
        Ok(Some(CacheConfig::parse(&v)?))
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
                out.insert(self.canon(&r.map_err(sql)?));
            }
            out
        };
        self.cache_pass(&cfg, notes, BTreeSet::new(), true, out)
    }

    /// 收尾（[Index::settle] 的最后一步）：只重算这一批碰到的。
    pub(super) fn refresh_caches(&mut self, out: &mut Settled) -> Result<(), String> {
        let dirt = std::mem::take(&mut self.dirt);
        let Some(cfg) = self.cache_config()? else {
            return Ok(());
        };
        let (note, notetype, card) = (
            EntKind::Note as i64,
            EntKind::NoteType as i64,
            EntKind::Card as i64,
        );
        let mut notes: BTreeSet<Ref> = BTreeSet::new();
        let mut types: BTreeSet<Ref> = BTreeSet::new();
        let mut cards: BTreeSet<Ref> = BTreeSet::new();
        for (kind, ent) in &dirt.entities {
            let ent = self.canon(ent);
            match *kind {
                k if k == note => notes.insert(ent),
                k if k == notetype => types.insert(ent),
                k if k == card => cards.insert(ent),
                _ => false,
            };
        }
        for id in &dirt.ids {
            // 身份记录进出：按现在的定义认种类；定义没了的，按缓存里它曾经是什么认。
            let id = self.canon(id);
            let kinds: Vec<i64> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached("SELECT DISTINCT kind FROM ent_ix WHERE col = ?1 AND id = ?2")
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, id], |r| r.get(0))
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            notes.insert(id.clone());
            types.insert(id.clone());
            if kinds.contains(&card) {
                cards.insert(id);
            }
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
                notes.insert(self.canon(&r.map_err(sql)?));
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
        if notes.is_empty() && cards.is_empty() {
            return Ok(());
        }
        self.cache_pass(&cfg, notes, cards, false, out)
    }

    // ------------------------------------------------------------ 读索引

    /// 一个实体（规范 ID）的定义：(种类, 身份记录的数据)。类里多个成员时取第一个有定义的。
    fn definition(&self, id: &Ref) -> Result<Option<(i64, i64, Value)>, String> {
        for m in self.class_of(id) {
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
            if let Some(Body4::Entity { data, .. }) = body_of(&e) {
                // 协议 3 `project_entity` 存的就是这份数据的规范 JSON。
                let d: Value = serde_json::from_str(&data).unwrap_or(Value::Null);
                return Ok(Some((kind, k, d)));
            }
        }
        Ok(None)
    }

    /// 一个实体（规范 ID）活着的修改行（寄存器内核的输入）与其中最大的 HLC 物理时刻（没有 = 0）。
    fn live_lines(
        &mut self,
        kind: EntKind,
        id: &Ref,
    ) -> Result<(Vec<(String, Option<i64>)>, i64), String> {
        let mut ks: Vec<i64> = Vec::new();
        let mut states: Vec<i64> = Vec::new();
        for m in self.class_of(id) {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached(
                    "SELECT k, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND state >= 0 ORDER BY key, k",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![self.col, kind as i64, m], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
                })
                .map_err(sql)?;
            for r in rows {
                let (k, s) = r.map_err(sql)?;
                ks.push(k);
                states.push(s);
            }
        }
        if ks.is_empty() {
            return Ok((Vec::new(), 0));
        }
        let lines = self.edit_lines(&ks, &|i| states[i] >= R_LIVE)?;
        let top = lines.iter().map(|l| l.physical).max().unwrap_or(0);
        Ok((
            lines.into_iter().map(|l| (l.json, l.server_time)).collect(),
            top,
        ))
    }

    /// 一条笔记（规范 ID）没被清除的标签操作里最大的 HLC 物理时刻（没有 = 0）。
    fn tag_time(&self, note: &Ref) -> Result<i64, String> {
        let mut top = 0;
        for m in self.class_of(note) {
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

    /// 一张卡（规范 ID）的日志：每个规范日志 ID 一条（`log_ix.win` 的代表），按 (发生时刻, 操作主键)。
    fn card_logs(&self, card: &Ref) -> Result<Vec<LogIn>, String> {
        let mut out: Vec<LogIn> = Vec::new();
        let mut seen: HashSet<Ref> = HashSet::new();
        for m in self.class_of(card) {
            let rows: Vec<(i64, Ref)> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT k, id FROM log_ix WHERE col = ?1 AND card = ?2 AND win = 1 ORDER BY at, k",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, m], |r| Ok((r.get(0)?, r.get(1)?)))
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            for (k, id) in rows {
                let id = self.canon(&id);
                if !seen.insert(id.clone()) {
                    continue;
                }
                out.push(self.log_at(k)?);
            }
        }
        Ok(out)
    }

    /// 一条日志操作的投影行（协议 3 `log_row` 同一份拼法）。
    fn log_at(&self, k: i64) -> Result<LogIn, String> {
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
        let device = e.id.device;
        // 投影行里的 profile 只是协议 3 的分区列，读侧不用；集合内取常量。
        let row = log_json("", &log_body(l), || {
            format!("{wall}:{logical}:{}", device.text())
        });
        Ok(LogIn {
            json: canonical(&row),
            server_time,
            intent,
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
        for m in self.class_of(card) {
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
                    succ.insert(self.canon(&r.map_err(sql)?));
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
                    pred.insert(ref_of(&self.canon_text(&p)));
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
            for m in self.class_of(c) {
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
                        out.insert(self.canon(&Ref::of(&l.card)));
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
                nodes.insert(self.canon(&r.map_err(sql)?));
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
                    let (a, b) = (self.canon(&ent), ref_of(&self.canon_text(&p)));
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
    /// 后旧分量裂开，裂出去的那半不在新的连通分量里，但它的日志原来记在这边的卡名下——不一起重算就会丢行。
    fn old_partners(&self, cards: &BTreeSet<Ref>) -> Result<BTreeSet<Ref>, String> {
        let mut out = BTreeSet::new();
        for c in cards {
            for m in self.class_of(c) {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT DISTINCT l.card FROM stats s JOIN log_ix l ON l.col = s.col AND l.id = s.log \
                         WHERE s.col = ?1 AND s.card = ?2 \
                         UNION SELECT DISTINCT s.card FROM log_ix l JOIN stats s \
                         ON s.col = l.col AND s.at = l.at AND s.log = l.id WHERE l.col = ?1 AND l.card = ?2",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, m], |r| r.get::<_, Ref>(0))
                    .map_err(sql)?;
                for r in rows {
                    out.insert(self.canon(&r.map_err(sql)?));
                }
            }
        }
        Ok(out)
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

    fn delete_note_rows(&self, note: &Ref) -> Result<(), String> {
        let conn = self.t.conn();
        conn.prepare_cached("DELETE FROM notes WHERE col = ?1 AND id = ?2")
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
        mut cards: BTreeSet<Ref>,
        all: bool,
        out: &mut Settled,
    ) -> Result<(), String> {
        let mut plans: HashMap<Ref, Plan> = HashMap::new();
        let mut types: HashMap<Ref, Option<TypeInfo>> = HashMap::new();
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
            let def = self
                .definition(n)?
                .filter(|(kind, ..)| *kind == EntKind::Note as i64);
            let Some((_, def_k, payload)) = def else {
                // 不是笔记（只是种类未定的 ID）、或身份记录没了：没有行。
                if !all {
                    self.delete_note_rows(n)?;
                }
                continue;
            };
            let (lines, edited) = self.live_lines(EntKind::Note, n)?;
            let stored: Vec<StoredEdit<'_>> =
                lines.iter().map(|(j, s)| (j.as_str(), *s, None)).collect();
            // 身份记录不成形（缺 `noteTypeId`、字段类型不对）的笔记没有行：真相里的操作来自别的设备，一条坏操作不能
            // 让整个索引层的收尾失败。协议 3 在这里让整次刷新失败（文件头「与协议 3 的差别」）。
            let Ok(mut view) = registers::note_view_of(&payload, &stored) else {
                if !all {
                    self.delete_note_rows(n)?;
                }
                continue;
            };
            // 协议 3 把 OR-Set 的结果写成一条合成的 `tags` 修改行再交给视图；这里直接给结果，同一个值。
            view["t"] = json!(self.tags_of(&Key::of(&n.text()))?);
            let info = NoteInfo::of(&n.text(), &view);
            let tref = self.canon(&ref_of(&info.note_type));
            if !types.contains_key(&tref) {
                let ti = self.type_info(&tref, cfg)?;
                types.insert(tref.clone(), ti);
            }
            // 卡 ID 由笔记 ID 派生（`registers::card_id`）：笔记 ID 不是 UUID 时算不出，同不成形的身份记录。
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
                    info.deck.as_deref().map(|d| ref_of(&self.canon_text(d))),
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
            let expected: Vec<Ref> = row
                .expected
                .iter()
                .map(|e| self.canon(&ref_of(&e.0)))
                .collect();
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
                        template: ref_of(&self.canon_text(tpl)),
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
            let ps: Vec<String> = config::predecessors(ls)
                .into_iter()
                .map(|p| self.canon_text(&p))
                .collect();
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
                    ref_of(&self.canon_text(r.deck)),
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
                    s.last_log_id.as_deref().map(|l| ref_of(&self.canon_text(l))),
                    s.scheduler,
                    t.created,
                    r.new_position,
                    t.freq,
                    crate::store::schema::anki_numeric_id(&card),
                ])
                .map_err(sql)?;
            out.cache_cards += 1;
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
                let log = self.canon_text(&r.log_id);
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
}
