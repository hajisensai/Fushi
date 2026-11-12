//! 本机写入的归属核对：一份 srs.db 里可以同时放几个 profile（app 的多份配置、无头服务端一门语言一份），实体的
//! ID 却是整库的主键——`srs_entities` / `srs_notes_cache` / `srs_cards_cache` 按 `id`，修改记录按
//! `(entity_kind, entity_id)`、复习日志按 `card_id` 归到实体上，投影、缓存刷新、重放读它们时都不带
//! `profile_uid`。profile 之间互不干扰靠的是「一个 profile 的操作只指向它自己的实体」：ID 的派生里带着 uid
//! （packages/fushi_srs/lib/src/ids.dart），正常产生的 ID 不会落到别的 profile 上。
//!
//! 但这条前提以前没有任何地方核对：调用方拿 A 的命令（`profile` = A）给出 B 的实体 ID——切换配置前留下的 ID、
//! 点名 A 却带着 B 的 ID 的远程请求——内核就把一条 A 的操作投影到 B 的实体上：B 的笔记被删、字段被改、卡被重排，
//! B 名下的修改记录还可能被这条「并发」的写入支配掉。
//!
//! 这里是这条前提的唯一判据（[foreign]），本机产生操作的三个本体在追加操作**之前**问它（内核的写命令都落在这三个
//! 本体之一上，命令自己不再各判一遍）：
//! - [super::apply_local_on]（`apply`、`change`、`import_drafts`、`note_fields_if`、`merge_notes`、`deck_delete`）：
//!   指向别的 profile 实体的那一项不追加、不投影，回包的 `foreign` 里交回它在输入里的下标；
//! - [super::sched_local::sched_local_on]（`sched`）：别的 profile 的卡按「没有这张卡」跳过（撤销计入撤不了的条数）；
//! - [super::append_on]（冲突解决 / 彻底清除 / 还原点）：跳过。
//!
//! 先读笔记再决定写什么的意图命令（merge_notes.rs、note_fields_if.rs）在预读那一步就把别人的笔记当成不存在：
//! 报错 / 进 `rejected` 的口径与不存在的 ID 相同，也不会为一次什么都不落的并入先打还原点。
//!
//! 评分预览（[super::SrsCore::sync2_preview]）是按卡 ID 读的命令，同样先问。
//!
//! 「哪里都没有的 ID」不归这里管：给还没有身份记录的实体写修改记录是合法的（换笔记类型时给还没生成的卡写血统、
//! 导入时同一批里先后到），照旧落一条悬空记录。只有本库里**已经记在别的 profile 名下**的 ID 才拒绝。
//!
//! 远端操作（收段、导入，transport.rs）不经过这里：那是「集合里的对端写了什么」，拒绝投影会让本机与只有这一个
//! profile 的设备算出不同的状态摘要，要另行设计。

use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension, params};

use super::sql;
use crate::sync2::op::{Body, EntKind};

/// 一次命令里问过的 ID → 是否属于别的 profile。命令在写连接的一个 SAVEPOINT 里，期间别的 profile 不会多出行；
/// 本命令自己只会把「没人的」ID 落到本 profile 名下，所以记下的答案在命令结束前一直成立。
pub(crate) type Seen = HashMap<(EntKind, String), bool>;

/// [id] 这个 [kind] 实体在本库里记在别的 profile 名下。
///
/// 依次看能把一个 ID 归到某个 profile 的行：身份记录（笔记 / 笔记类型 / 牌组）、卡片缓存行、指向它的修改记录、
/// 记在它（卡）上的复习日志。有一处记在 [profile] 名下就是本 profile 的；哪里都没有就是没人的（不拒绝）。
pub(crate) fn foreign(
    c: &Connection,
    profile: &str,
    kind: EntKind,
    id: &str,
) -> Result<bool, String> {
    if kind == EntKind::Profile {
        // profile 实体的 ID 就是 profile uid：别的 uid 只要在本库里开过（有同步身份）就是别人的。
        if id == profile {
            return Ok(false);
        }
        let known: bool = c
            .prepare_cached(
                "SELECT EXISTS(SELECT 1 FROM sync2_self WHERE profile_uid = srs_id(?1))",
            )
            .map_err(sql)?
            .query_row([id], |r| r.get(0))
            .map_err(sql)?;
        if known {
            return Ok(true);
        }
    }
    // 一行的归属：Some(true) = 本 profile，Some(false) = 别的 profile，None = 没有这样的行。
    let one = |q: &str| -> Result<Option<bool>, String> {
        c.prepare_cached(q)
            .map_err(sql)?
            .query_row(params![id, profile], |r| r.get::<_, Option<bool>>(0))
            .optional()
            .map(Option::flatten)
            .map_err(sql)
    };
    if let Some(own) =
        one("SELECT profile_uid = srs_id(?2) FROM srs_entities WHERE id = srs_id(?1)")?
    {
        return Ok(!own);
    }
    if kind == EntKind::Card {
        if let Some(own) =
            one("SELECT profile_uid = srs_id(?2) FROM srs_cards_cache WHERE id = srs_id(?1)")?
        {
            return Ok(!own);
        }
        if let Some(own) = one(
            "SELECT MAX(profile_uid = srs_id(?2)) FROM srs_review_logs WHERE card_id = srs_id(?1)",
        )? {
            return Ok(!own);
        }
    }
    let edits: Option<bool> = c
        .prepare_cached(
            "SELECT MAX(profile_uid = srs_id(?3)) FROM srs_field_edits WHERE entity_kind = ?1 AND entity_id = srs_id(?2)",
        )
        .map_err(sql)?
        .query_row(params![kind.wire(), id, profile], |r| r.get::<_, Option<bool>>(0))
        .optional()
        .map(Option::flatten)
        .map_err(sql)?;
    Ok(edits == Some(false))
}

/// [foreign]，同一次命令里问过的 ID 不再查库（一批导入里同一条笔记有十几条修改记录）。
pub(crate) fn foreign_seen(
    c: &Connection,
    profile: &str,
    kind: EntKind,
    id: &str,
    seen: &mut Seen,
) -> Result<bool, String> {
    if let Some(&known) = seen.get(&(kind, id.to_owned())) {
        return Ok(known);
    }
    let f = foreign(c, profile, kind, id)?;
    seen.insert((kind, id.to_owned()), f);
    Ok(f)
}

/// 本机要追加的操作 [body] 指向别的 profile 的实体（身份记录 / 修改记录 / 标签 / 彻底清除看实体，复习日志看卡）。
/// 不指向实体的操作（还原点、媒体、不认识的事件……）恒为否。
pub(crate) fn targets_foreign(
    c: &Connection,
    profile: &str,
    body: &Body,
    seen: &mut Seen,
) -> Result<bool, String> {
    let (kind, id) = match body {
        Body::Entity { kind, id, .. } => (*kind, id.text()),
        Body::Edit(e) => (e.kind, e.entity.text()),
        Body::Log(l) => (EntKind::Card, l.card.text()),
        Body::TagAdd { note, .. } | Body::TagRemove { note, .. } | Body::TagOrder { note, .. } => {
            (EntKind::Note, note.text())
        }
        Body::Purge { kind, entity } => (*kind, entity.text()),
        _ => return Ok(false),
    };
    foreign_seen(c, profile, kind, &id, seen)
}
