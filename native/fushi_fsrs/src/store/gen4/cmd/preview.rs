//! 评分预览 `preview` 的新代实现（规划 §2.1 G7-4f；协议 3 `store/sync2/mod.rs` `SrsCore::sync2_preview`）。S1b 接进
//! 分发器（`gen4/dispatch.rs`，请求形状同协议 3：`card` / `note?` / `now` / `utcOff` / `rollover`）。
//!
//! 一份规则：重放（`replay::preview`）、有效配置与回包（`store/sync2/mod.rs` `preview_of`）、卡的有效牌组
//! （`config::card_deck_with`，经 [super::card_deck]）都与协议 3 同一个函数。这里只换「从哪读」：
//!
//! - **牌组树 / 默认牌组**：[super::deck_tree] / [super::default_deck]（写命令与 `study` 同一份）。
//! - **归属组的日志**：这张卡当链尾的归属组（链尾 + 广度优先的全部前身），各卡的日志按类取代表（`cache.rs`
//!   `Index::group`，写命令 `sched` 同一份），是重放的输入——与协议 3 `group_of` 读的日志行同一份数据。
//! - **笔记**：调用方给了就用（归一）；没给读缓存层 `cards` 的 `note_id`（主键 `(col, id)` 点读）。归属组的笔记按协议 3
//!   `group_of` 的规则取日志上记的（链尾优先），没有就退回上面那个。
//!
//! # 与协议 3 的差别（D24「按规范 ID」）
//!
//! - 请求里的卡与笔记先归一，回包里的 `note` / `deck` 是规范 ID；FSRS 的模糊种子按规范卡 ID 算（新写的日志也落在规范
//!   卡上，`cmd/writes.rs` `canon_body`）。
//! - 协议 3 对「别的 profile 的卡」按不存在的卡回包（`ownership::foreign`）；新代按集合分区，别的集合的卡在这个集合里
//!   本来就没有身份记录、日志与缓存行，回包同样是不存在的卡的形状，不用另判。

use serde_json::Value;

use super::{card_deck, deck_tree, default_deck, ref_of, snapshot};
use crate::projection::Day;
use crate::store::gen4::derive::{Index, Ref};
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::Truth;
use crate::store::sync2::preview_of;
use crate::sync2::replay::Row;

/// `preview`：卡 [card] 此刻作答的四个按钮的结果（回包同协议 3 `sync2_preview`）。[note] = 卡所属笔记（新卡没有日志时
/// 据它找牌组；None = 按缓存行补上，结果里交回）。日界用调用方此刻的口径。在一个读快照里（[snapshot]）。
pub fn preview(
    t: &Truth<'_>,
    col: i64,
    card: &str,
    note: Option<&str>,
    now: i64,
    utc_off: i64,
    rollover: i64,
) -> Result<Value, String> {
    snapshot(t, |t| {
        let mut ix = Index::new(t, col);
        let card = ix.canonical(&ref_of(card))?;
        let default = default_deck(t, &ix, col)?;
        let tree = deck_tree(&mut ix, default)?;
        let note: Option<String> = match note {
            Some(n) => Some(ix.canonical(&ref_of(n))?.text()),
            None => cached_note(t, col, &card)?,
        };
        let (rows, group_note) = ix.group(&card)?;
        let group_note = group_note.or_else(|| note.clone());
        let card = card.text();
        let deck = if rows.is_empty() && note.is_none() {
            None
        } else {
            Some(card_deck(&mut ix, &tree, &card, group_note.as_deref())?)
        };
        let input: Vec<Row<'_>> = rows
            .iter()
            .map(|(j, s, i, c)| Row {
                json: j,
                server_time: *s,
                intent: i.clone(),
                seed_card: Some(c),
            })
            .collect();
        let day = Day {
            utc_offset_min: utc_off,
            rollover_hour: rollover,
        };
        preview_of(&tree, note.as_deref(), deck, &input, &card, now, &day)
    })
}

/// [cached_note] 的点读（`cards` 主键 `(col, id)`）。
pub(super) const NOTE_SQL: &str = "SELECT note_id FROM cards WHERE col = ?1 AND id = ?2";

/// 卡片缓存行上的笔记（规范 ID；没有这张卡的缓存行 = None）。走 `cards` 主键。
fn cached_note(t: &Truth<'_>, col: i64, card: &Ref) -> Result<Option<String>, String> {
    let mut stmt = t.conn().prepare_cached(NOTE_SQL).map_err(sql)?;
    let mut rows = stmt.query(rusqlite::params![col, card]).map_err(sql)?;
    match rows.next().map_err(sql)? {
        Some(r) => Ok(Some(r.get::<_, Ref>(0).map_err(sql)?.text())),
        None => Ok(None),
    }
}
