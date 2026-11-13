//! 协议 3 的投影与灌进新存储、重建之后的派生层逐类对拍（设计 §6.1 第 5 步、§8 G4 / G6c）。生产代码：G4 的干跑
//! （`dryrun.rs`）与测试装置（`parity.rs`）共用这一份比法，两边不会各比各的。
//!
//! 协议 3 一侧的缓存行由调用方给（[against_protocol_3] 的 `old_caches`）：测试装置在可写连接的 SAVEPOINT 里先做完
//! 协议 3 自己欠着的收尾再重建、整个回滚；干跑在只读连接上用影子临时表重建（`dryrun.rs`），不写旧库一个字节。

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{Connection, ToSql, params};

use super::cache::CFG_KEY;
use super::derive::{Index, R_LIVE, Ref, body_of};
use super::schema::sql;
use super::truth::Truth;
use crate::gen4::op::Body4;
use crate::store::sync2::semantics::current_tags;
use crate::sync2::id::{Id, Key};
use crate::sync2::vv::OpId;

/// 有差异的类别：(类别, 只在旧库, 只在新库)。空 = 完全一致。
pub(crate) type Diff = Vec<(&'static str, Vec<String>, Vec<String>)>;

pub(crate) fn op_text(id: &OpId) -> String {
    format!("{}:{}", id.device.text(), id.seq)
}

/// 索引里没被支配、也没被扣住 / 清除的写入的修改记录 ID（协议 3 的 `srs_field_edits.id`：由 dot 决定）。[skip] 里的
/// 实体（`种类:ID`）的 `deleted` 寄存器不算。
fn live_edit_ids(
    t: &Truth<'_>,
    col: i64,
    skip: &BTreeSet<String>,
) -> Result<BTreeSet<Ref>, String> {
    let mut out = BTreeSet::new();
    for k in live_keys(t, col)? {
        let e = t
            .entry_by_key(k)?
            .ok_or_else(|| format!("gen4 compare: register row {k} has no op"))?;
        let Some(Body4::Edit(ed)) = body_of(&e) else {
            return Err(format!("gen4 compare: register row {k} is not an edit"));
        };
        if ed.key == "deleted"
            && skip.contains(&format!(
                "{}:{}",
                ed.kind.wire(),
                Ref::of(&ed.entity).text()
            ))
        {
            continue;
        }
        let id = match &ed.stamp {
            Some(s) => crate::registers::edit_id(&s.writer, s.seq),
            None => crate::registers::edit_id(&e.id.device.text(), e.id.seq as i64),
        };
        out.insert(Ref::of(&Key::of(&id)));
    }
    Ok(out)
}

/// `reg_ix` 里没被支配的写入（`state >= R_LIVE`）的操作键。
fn live_keys(t: &Truth<'_>, col: i64) -> Result<Vec<i64>, String> {
    t.conn()
        .prepare("SELECT k FROM reg_ix WHERE col = ?1 AND state >= ?2")
        .map_err(sql)?
        .query_map(params![col, R_LIVE], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)
}

pub(crate) fn texts(
    conn: &Connection,
    q: &str,
    args: &[&dyn ToSql],
) -> Result<BTreeSet<String>, String> {
    conn.prepare(q)
        .map_err(sql)?
        .query_map(args, |r| r.get::<_, String>(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)
}

fn ops(conn: &Connection, table: &str, profile: &str) -> Result<BTreeSet<String>, String> {
    // 这张表比库新（真实样本是加这个功能之前的 schema）：那时没有这类行。
    let exists = conn
        .prepare("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?1")
        .map_err(sql)?
        .exists([table])
        .map_err(sql)?;
    if !exists {
        return Ok(BTreeSet::new());
    }
    let rows: Vec<([u8; 16], i64)> = conn
        .prepare(&format!(
            "SELECT device, seq FROM {table} WHERE profile_uid = srs_id(?1)"
        ))
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    Ok(rows
        .into_iter()
        .map(|(d, s)| {
            op_text(&OpId {
                device: Id(d),
                seq: s as u64,
            })
        })
        .collect())
}

pub(crate) fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02X}")).collect()
}

/// 缓存层对拍的列：(新代列, 协议 3 列)。笔记的 `updated_at` 不比（协议 3 是写行那一刻的本机时钟，新代是内容最后
/// 被改的 HLC 物理时刻——`cache.rs` 文件头「取舍」）。第一列是行的身份（只用来让差异好读，整行都比）。
pub(crate) const NOTE_COLS: &[(&str, &str)] = &[
    ("id", "id"),
    ("note_type_id", "note_type_id"),
    ("guid", "guid"),
    ("created_at", "created_at"),
    ("deck_id", "deck_id"),
    ("deleted_at", "deleted_at"),
    ("term_key", "term_key"),
    ("reading_key", "reading_key"),
    ("sort_field", "sort_field"),
    ("tags_json", "tags_json"),
    ("pending_decision", "pending_decision"),
    ("media_refs", "media_refs"),
    ("source_kind", "source_kind"),
    ("source_title", "source_title"),
    ("anki_id", "anki_id"),
    ("dupe_norm", "dupe_norm"),
    ("source_key", "source_key"),
];
pub(crate) const CARD_COLS: &[(&str, &str)] = &[
    ("id", "id"),
    ("note_id", "note_id"),
    ("template_id", "template_id"),
    ("cloze_ord", "cloze_ord"),
    ("deck_id", "deck_id"),
    ("suspended", "suspended"),
    ("buried_until_day", "buried_until_day"),
    ("flag", "flag"),
    ("hidden", "hidden"),
    ("queue", "queue"),
    ("due_day", "due_day"),
    ("due_at", "due_at"),
    ("scheduled_days", "scheduled_days"),
    ("reps", "reps"),
    ("lapses", "lapses"),
    ("stability", "stability"),
    ("difficulty", "difficulty"),
    ("last_reviewed_at", "last_reviewed_at"),
    ("last_log_id", "last_log_id"),
    ("scheduler", "scheduler"),
    ("note_created_at", "note_created_at"),
    ("new_position", "new_position"),
    ("freq_rank", "freq_rank"),
    ("anki_id", "anki_id"),
];
pub(crate) const STAT_COLS: &[(&str, &str)] = &[
    ("log", "log_id"),
    ("card", "card_id"),
    ("at", "occurred_at"),
    ("utc_offset_min", "utc_offset_min"),
    ("rating", "rating"),
    ("kind", "kind"),
    ("duration_ms", "duration_ms"),
    ("prev_due_day", "prev_due_day"),
    ("maturity_delta", "maturity_delta"),
];

/// 一格的文本形：16 字节的 ID 写成 UUID 文本（新代存 [Ref]，协议 3 存 `srs_id`），其余按值。
pub(crate) fn cell(v: rusqlite::types::ValueRef<'_>) -> String {
    use rusqlite::types::ValueRef;
    match v {
        ValueRef::Null => "∅".to_owned(),
        ValueRef::Integer(i) => i.to_string(),
        ValueRef::Real(f) => format!("{f:?}"),
        ValueRef::Text(t) => String::from_utf8_lossy(t).into_owned(),
        ValueRef::Blob(b) => match <[u8; 16]>::try_from(b) {
            Ok(u) => Ref::Uuid(u).text(),
            Err(_) => hex(b),
        },
    }
}

/// 一张表的行（每行各列的文本形）。
pub(crate) fn rows_of(
    conn: &Connection,
    table: &str,
    cols: &[&str],
    filter: &str,
    arg: &dyn ToSql,
) -> Result<Vec<Vec<String>>, String> {
    let mut stmt = conn
        .prepare(&format!(
            "SELECT {} FROM {table} WHERE {filter}",
            cols.join(", ")
        ))
        .map_err(|e| e.to_string())?;
    let mut rows = stmt.query([arg]).map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    while let Some(r) = rows.next().map_err(|e| e.to_string())? {
        out.push(
            (0..cols.len())
                .map(|i| r.get_ref(i).map(cell))
                .collect::<Result<_, _>>()
                .map_err(sql)?,
        );
    }
    Ok(out)
}

/// 三张缓存表的行：(笔记, 卡, 统计)。
pub(crate) type CacheRows = (Vec<Vec<String>>, Vec<Vec<String>>, Vec<Vec<String>>);

/// 协议 3 的缓存重建因身份记录不成形整次失败（`cache.rs` 文件头「与协议 3 的差别」）：缺字段 / 字段类型不对 /
/// 笔记 ID 不是 UUID（卡 ID 由它派生）。
pub(crate) fn malformed_definition(e: &str) -> bool {
    e.ends_with(" missing") || e.contains(": expected ") || e.starts_with("not a uuid: ")
}

/// 同一个旧修改记录 ID（旧戳的写入者 + seq）下有两条以上不同修改（不同实体或字段键）的笔记（`种类:ID`）：复制出来的
/// 两份旧库各自又以同一个写入者写了同一个 seq。新代两条都是独立的操作、都进视图；协议 3 的投影表按修改记录 ID 只存
/// 一行，留哪条看这台设备先收到哪份，所以这些笔记的内容（与由内容决定的卡）对不上协议 3 是到达顺序造成的。
pub(crate) fn collided_notes(t: &Truth<'_>, col: i64) -> Result<BTreeSet<String>, String> {
    let mut by_id: BTreeMap<(String, i64), BTreeSet<(String, String)>> = BTreeMap::new();
    for k in live_keys(t, col)? {
        let e = t
            .entry_by_key(k)?
            .ok_or_else(|| format!("gen4 compare: register row {k} has no op"))?;
        let Some(Body4::Edit(ed)) = body_of(&e) else {
            continue;
        };
        if let Some(st) = &ed.stamp {
            by_id
                .entry((st.writer.clone(), st.seq))
                .or_default()
                .insert((
                    format!("{}:{}", ed.kind.wire(), Ref::of(&ed.entity).text()),
                    ed.key.clone(),
                ));
        }
    }
    Ok(by_id
        .into_values()
        .filter(|edits| edits.len() > 1)
        .flatten()
        .map(|(ent, _)| ent)
        .filter(|ent| ent.starts_with("note:"))
        .collect())
}

/// 缓存层三类（`notes` / `cards` / `stats`）的对拍对：新代没设缓存配置时没有（不物化）。两种口径：
///
/// - [held] 是有删除被扣住的实体（`种类:ID`，任一边）：协议 3 的 `deleted` 寄存器里留着哪几条取决于被扣住的那条删除
///   到的时候落没落过投影（[against_protocol_3] 的 `edits` 口径），所以这些笔记行的 `deleted_at` / `pending_decision`
///   与它们的卡的 `hidden` 不比，其余列照比。
/// - [collided_notes]：这些笔记的行与它们的卡行两边都不比（统计行的归属随卡的可见性变，归属卡是这些卡的也不比）。
///
/// [skip] 是调用方另外不比的笔记与卡（干跑：协议 3 自己还欠着收尾、只读连接上做不了的，见 `dryrun.rs`）。
pub(crate) fn cache_pairs(
    src: &Connection,
    profile: &str,
    t: &Truth<'_>,
    col: i64,
    held: &BTreeSet<String>,
    old_caches: &mut OldCaches<'_>,
    skip: &Skip,
    diff: &mut Diff,
) -> Result<Option<CacheRows>, String> {
    let Some(cfg) = t.derive_cfg(col, CFG_KEY)? else {
        return Ok(None);
    };
    let old = match old_caches(src, profile, &cfg) {
        Ok(v) => v,
        // 协议 3 那边没有行可比；新代那边这些实体没有行、其余照常（单元测试钉）。别的失败照报。
        Err(e) if malformed_definition(&e) => return Ok(None),
        Err(e) => {
            push_pair(diff, ("caches", BTreeSet::from([e]), BTreeSet::new()));
            return Ok(None);
        }
    };
    let (old_notes, old_cards, old_stats) = (&old.0, &old.1, &old.2);
    let news = |cols: &[(&'static str, &'static str)]| -> Vec<&'static str> {
        cols.iter().map(|c| c.0).collect()
    };
    let new =
        |table: &str, cols: &[(&'static str, &'static str)]| -> Result<Vec<Vec<String>>, String> {
            rows_of(t.conn(), table, &news(cols), "col = ?1", &col)
        };
    let at = |cols: &[(&str, &str)], name: &str| -> usize {
        cols.iter()
            .position(|c| c.0 == name)
            .expect("column listed in the constant")
    };
    let held_note = |id: &str| held.contains(&format!("note:{id}"));
    let collided = collided_notes(t, col)?;
    let skip_note = |id: &str| collided.contains(&format!("note:{id}")) || skip.notes.contains(id);
    // 三张表一张一张比：同时在内存里的只有一张表两侧的行。
    let notes = |rows: &[Vec<String>]| -> BTreeSet<String> {
        rows.iter()
            .filter(|r| !skip_note(&r[0]))
            .map(|r| {
                if held_note(&r[0]) {
                    let mut r = r.clone();
                    r[at(NOTE_COLS, "deleted_at")] = "(held)".to_owned();
                    r[at(NOTE_COLS, "pending_decision")] = "(held)".to_owned();
                    r.join(" | ")
                } else {
                    r.join(" | ")
                }
            })
            .collect()
    };
    let new_notes = new("notes", NOTE_COLS)?;
    push_pair(diff, ("notes", notes(old_notes), notes(&new_notes)));
    drop(new_notes);
    let new_cards = new("cards", CARD_COLS)?;
    let skipped_cards: BTreeSet<String> = old_cards
        .iter()
        .chain(&new_cards)
        .filter(|r| skip_note(&r[at(CARD_COLS, "note_id")]))
        .map(|r| r[0].clone())
        .chain(skip.cards.iter().cloned())
        .collect();
    let cards = |rows: &[Vec<String>]| -> BTreeSet<String> {
        rows.iter()
            .filter(|r| !skipped_cards.contains(&r[0]))
            .map(|r| {
                if held_note(&r[at(CARD_COLS, "note_id")]) {
                    let mut r = r.clone();
                    r[at(CARD_COLS, "hidden")] = "(held)".to_owned();
                    r.join(" | ")
                } else {
                    r.join(" | ")
                }
            })
            .collect()
    };
    push_pair(diff, ("cards", cards(old_cards), cards(&new_cards)));
    drop(new_cards);
    let stats = |rows: &[Vec<String>]| -> BTreeSet<String> {
        rows.iter()
            .filter(|r| !skipped_cards.contains(&r[at(STAT_COLS, "card")]))
            .map(|r| r.join(" | "))
            .collect()
    };
    let new_stats = new("stats", STAT_COLS)?;
    push_pair(diff, ("stats", stats(old_stats), stats(&new_stats)));
    Ok(Some(old))
}

/// 一类对拍：(类别, 旧库一侧, 新库一侧)。
pub(crate) type Pair = (&'static str, BTreeSet<String>, BTreeSet<String>);

/// 协议 3 一侧的缓存行从哪来：(旧库连接, profile, 新代的缓存配置 JSON) → (笔记, 卡, 统计)。
pub(crate) type OldCaches<'a> =
    dyn FnMut(&Connection, &str, &str) -> Result<CacheRows, String> + 'a;

/// 调用方另外不比的笔记与卡（ID 文本）。
#[derive(Clone, Debug, Default)]
pub(crate) struct Skip {
    pub notes: BTreeSet<String>,
    pub cards: BTreeSet<String>,
}

/// 协议 3 的投影，与同一份库灌进新存储、重建之后的派生层比。类别：活着的修改记录 ID（`edits`，不算合成的标签行）、
/// 日志 ID（`logs`）、实体 ID（`entities`）、每条笔记现在的标签与顺序（`tags`）、媒体名绑定的内容（`media`）、
/// 被并发改动扣住的删除（`held`）、因设备不可信没执行的删除与清除（`distrusted`）、清除过的实体（`purged`）；新代设了
/// 缓存配置时再加缓存层的笔记行（`notes`）、卡行（`cards`）、有效复习投影（`stats`），逐列比（[cache_pairs]）。
pub(crate) fn against_protocol_3(
    src: &Connection,
    profile: &str,
    t: &Truth<'_>,
    col: i64,
    old_caches: &mut OldCaches<'_>,
    skip: &Skip,
) -> Result<(Diff, Option<CacheRows>), String> {
    // 每一类算出来马上化成差异、放掉两侧的集合：同时在内存里的只有一类（大库的修改记录 ID 一类就有上百万条）。
    let mut diff = Diff::new();
    let ix = Index::new(t, col);
    // ID 类（修改记录、日志、实体）两侧都按 [Ref] 收：UUID 只占 16 字节，大库这几类各有几十万到上百万条。
    let refs = |q: &str| -> Result<BTreeSet<Ref>, String> {
        t.conn()
            .prepare(q)
            .map_err(sql)?
            .query_map([col], |r| r.get::<_, Ref>(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)
    };
    let mut old_tags: BTreeSet<String> = BTreeSet::new();
    for n in texts(
        src,
        "SELECT DISTINCT srs_idt(note) FROM sync2_tag_adds WHERE profile_uid = srs_id(?1)",
        &[&profile],
    )? {
        let tags = current_tags(src, profile, &n)?;
        if !tags.is_empty() {
            old_tags.insert(format!("{n}={tags:?}"));
        }
    }
    let mut new_tags: BTreeSet<String> = BTreeSet::new();
    for n in ix.tagged_notes()? {
        let tags = ix.tags_of(&crate::sync2::id::Key::of(&n.text()))?;
        if !tags.is_empty() {
            new_tags.insert(format!("{}={tags:?}", n.text()));
        }
    }
    // 协议 3 在两处依赖到达顺序 / 留着骨架（`weigh.rs` 文件头「与协议 3 的差别」），这两处按下面的口径比：
    // - 有删除被扣住的实体（任一边）：`deleted` 寄存器里留着哪几条修改记录不比（协议 3 取决于被扣住的那条删除
    //   到的时候落没落过投影），只比扣住的集合；
    // - 清除过的实体：扣住的集合不比（协议 3 把已清除操作的骨架也算作「并发的操作」）。
    let new_holds = ix.holds()?;
    let old_held_ents: Vec<(String, String)> = src
        .prepare(
            "SELECT srs_idt(device) || ':' || seq, kind || ':' || srs_idt(entity) FROM sync2_held              WHERE profile_uid = srs_id(?1)",
        )
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let new_held_ents: Vec<(String, String)> = new_holds
        .iter()
        .map(|h| {
            (
                op_text(&h.op),
                format!("{}:{}", h.kind.wire(), h.entity.text()),
            )
        })
        .collect();
    let held_ents: BTreeSet<String> = old_held_ents
        .iter()
        .chain(&new_held_ents)
        .map(|(_, ent)| ent.clone())
        .collect();
    let old_purged = texts(
        src,
        "SELECT kind || ':' || srs_idt(entity) FROM sync2_purged WHERE profile_uid = srs_id(?1)",
        &[&profile],
    )?;
    let new_purged: BTreeSet<String> = ix
        .purged_entities()?
        .into_iter()
        .map(|(k, e)| format!("{}:{}", k.wire(), e.text()))
        .collect();
    let on_unpurged = |held: &[(String, String)]| -> BTreeSet<String> {
        held.iter()
            .filter(|(_, ent)| !old_purged.contains(ent) && !new_purged.contains(ent))
            .map(|(op, _)| op.clone())
            .collect()
    };
    let mut old_edits: BTreeSet<Ref> = BTreeSet::new();
    {
        let mut stmt = src
            .prepare(
                "SELECT id, entity_kind || ':' || srs_idt(entity_id), field_key FROM srs_field_edits              WHERE profile_uid = srs_id(?1) AND writer_id NOT LIKE 'sync2:%'",
            )
            .map_err(sql)?;
        let mut rows = stmt.query([profile]).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            let key: String = r.get(2).map_err(sql)?;
            if key == "deleted" && held_ents.contains(&r.get::<_, String>(1).map_err(sql)?) {
                continue;
            }
            old_edits.insert(r.get(0).map_err(sql)?);
        }
    }
    push_refs(
        &mut diff,
        "edits",
        old_edits,
        live_edit_ids(t, col, &held_ents)?,
    );
    let logs = old_refs(
        src,
        "SELECT id FROM srs_review_logs WHERE profile_uid = srs_id(?1)",
        profile,
    )?;
    push_refs(
        &mut diff,
        "logs",
        logs,
        refs("SELECT DISTINCT id FROM log_ix WHERE col = ?1")?,
    );
    let entities = old_refs(
        src,
        "SELECT id FROM srs_entities WHERE profile_uid = srs_id(?1)",
        profile,
    )?;
    push_refs(
        &mut diff,
        "entities",
        entities,
        refs("SELECT DISTINCT id FROM ent_ix WHERE col = ?1")?,
    );
    push_pair(&mut diff, ("tags", old_tags, new_tags));
    let media = texts(
        src,
        "SELECT name || '=' || hex(sha256) || ':' || size FROM sync2_media WHERE profile_uid = srs_id(?1)",
        &[&profile],
    )?;
    push_pair(
        &mut diff,
        (
            "media",
            media,
            ix.media()?
                .into_iter()
                .map(|(name, sha, size)| format!("{name}={}:{size}", hex(&sha)))
                .collect(),
        ),
    );
    push_pair(
        &mut diff,
        (
            "held",
            on_unpurged(&old_held_ents),
            on_unpurged(&new_held_ents),
        ),
    );
    push_pair(
        &mut diff,
        (
            "distrusted",
            ops(src, "sync2_trust_held", profile)?,
            ix.distrusted()?.iter().map(op_text).collect(),
        ),
    );
    push_pair(
        &mut diff,
        ("purged", old_purged.clone(), new_purged.clone()),
    );
    let rows = cache_pairs(
        src, profile, t, col, &held_ents, old_caches, skip, &mut diff,
    )?;
    Ok((diff, rows))
}

/// 协议 3 一侧的一列 ID（存的是 `srs_id` 的形：规范 UUID 为 16 字节，其余为文本），按 [Ref] 收。
fn old_refs(src: &Connection, q: &str, profile: &str) -> Result<BTreeSet<Ref>, String> {
    src.prepare(q)
        .map_err(sql)?
        .query_map([profile], |r| r.get::<_, Ref>(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)
}

/// ID 类的一类对拍化成差异：只有不同的那几条转成文本。
fn push_refs(diff: &mut Diff, what: &'static str, a: BTreeSet<Ref>, b: BTreeSet<Ref>) {
    push_set(diff, what, a, b, Ref::text);
}

/// 一类对拍（两侧是紧凑形的集合）化成差异：两侧相同就没有；不同的那几条按 [text] 转成文本。
pub(crate) fn push_set<T: Ord>(
    diff: &mut Diff,
    what: &'static str,
    a: BTreeSet<T>,
    b: BTreeSet<T>,
    text: impl Fn(&T) -> String,
) {
    if a != b {
        diff.push((
            what,
            a.difference(&b).map(&text).collect(),
            b.difference(&a).map(&text).collect(),
        ));
    }
}

/// 一类对拍化成差异（两侧相同就没有），追加到 [diff]。
pub(crate) fn push_pair(diff: &mut Diff, pair: Pair) {
    diff.extend(differences([pair]));
}

/// 只留两侧不同的类别：(类别, 只在旧库, 只在新库)。
pub(crate) fn differences(pairs: impl IntoIterator<Item = Pair>) -> Diff {
    pairs
        .into_iter()
        .filter(|(_, a, b)| a != b)
        .map(|(what, a, b)| {
            (
                what,
                a.difference(&b).cloned().collect(),
                b.difference(&a).cloned().collect(),
            )
        })
        .collect()
}
