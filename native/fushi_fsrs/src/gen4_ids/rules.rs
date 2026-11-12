//! ID 规则表（docs/specs/2026-11-11-srs-generation-break.md §5.2）。
//!
//! 每条规则一个函数，名字拼法与 Dart `SrsIds`（packages/fushi_srs/lib/src/ids.dart）逐字节相同；向量冻结在
//! `golden_ids.json`，Dart 与 Rust 各自对着它重算（`tests.rs` 与
//! packages/fushi_engine/test/srs/srs_gen4_canonical_ids_golden_test.dart）。
//!
//! 根上的规则（笔记、笔记类型、牌组、内置默认牌组）带一个 [Salt]：
//! - [CANONICAL]（`None`）：规范 ID——协议 4 起新写入的实体用的值，名字里没有 uid；
//! - `Some(uid)`：存量规则——名字前面多一段 `<uid>/`。**只用来验算存量 ID**（alias.rs），不再用来生成新 ID。
//!
//! 由父 ID 派生的规则（字段、模板、卡、导入日志、锚点）本来就不带 uid，公式不变。

use sha2::{Digest, Sha256};

use crate::sync2::id::Id;

/// Fushi SRS 固定命名空间（Dart `srsNamespace`）。冻结。
pub const NAMESPACE: Id = Id([
    0x6f, 0x1c, 0x8a, 0x2e, 0x4b, 0x7d, 0x5e, 0x3f, 0x9a, 0x10, 0x2d, 0x4c, 0x6e, 0x8f, 0x0b, 0x13,
]);

/// 规则里的盐：存量规则是当时的 profile uid（原样文本），规范规则没有。
pub type Salt<'a> = Option<&'a str>;

/// 规范规则（不带盐）。
pub const CANONICAL: Salt<'static> = None;

fn rooted(salt: Salt<'_>, name: &str) -> Id {
    match salt {
        None => Id::v5(&NAMESPACE, name),
        Some(uid) => Id::v5(&NAMESPACE, &format!("{uid}/{name}")),
    }
}

/// 笔记：`v5(NS, [uid/]note/<guid>)`。
pub fn note(salt: Salt<'_>, guid: &str) -> Id {
    rooted(salt, &format!("note/{guid}"))
}

/// 笔记类型：`v5(NS, [uid/]notetype/<ankiNum>)`。内置类型的 ankiNum 是 [builtin_note_type_anki_num]，
/// 所以规范规则下内置笔记类型在所有设备、所有集合里是同一个常量。
pub fn note_type(salt: Salt<'_>, anki_num: i64) -> Id {
    rooted(salt, &format!("notetype/{anki_num}"))
}

/// 字段：`v5(noteTypeId, field/<ankiNum>)`。
pub fn field(note_type: &Id, anki_num: i64) -> Id {
    Id::v5(note_type, &format!("field/{anki_num}"))
}

/// 模板：`v5(noteTypeId, template/<ankiNum>)`。
pub fn template(note_type: &Id, anki_num: i64) -> Id {
    Id::v5(note_type, &format!("template/{anki_num}"))
}

/// 来源里字段没有 ankiNum 时按名字的回退：`v5(noteTypeId, field-name/<名字>)`。
pub fn field_by_name(note_type: &Id, name: &str) -> Id {
    Id::v5(note_type, &format!("field-name/{name}"))
}

/// 模板按名字的回退：`v5(noteTypeId, template-name/<名字>)`。
pub fn template_by_name(note_type: &Id, name: &str) -> Id {
    Id::v5(note_type, &format!("template-name/{name}"))
}

/// 卡：`v5(noteId, <templateId 文本>/<clozeOrd>)`，模板 ID 取规范小写带连字符文本；普通模板 clozeOrd = 0。
pub fn card(note: &Id, template: &Id, cloze_ord: i64) -> Id {
    Id::v5(note, &format!("{}/{cloze_ord}", template.text()))
}

/// Dart `String.trim()` 去掉的空白：Unicode White_Space 加 U+FEFF。Rust `str::trim` 不含 U+FEFF，
/// 牌组全名的规范化必须按 Dart 的集合来，否则带 BOM 的名字两边算出不同的 ID。
fn dart_whitespace(c: char) -> bool {
    matches!(
        c,
        '\u{0009}'..='\u{000D}'
            | '\u{0020}'
            | '\u{0085}'
            | '\u{00A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
            | '\u{FEFF}'
    )
}

/// 牌组全名的规范形（Dart `SrsIds.normalizeDeckPath`）：按 `::` 切，每段去首尾空白，丢掉空段，再用 `::` 接回。
pub fn normalize_deck_path(full_path: &str) -> String {
    let mut out = String::with_capacity(full_path.len());
    for part in full_path.split("::") {
        let part = part.trim_matches(dart_whitespace);
        if part.is_empty() {
            continue;
        }
        if !out.is_empty() {
            out.push_str("::");
        }
        out.push_str(part);
    }
    out
}

/// 牌组：`v5(NS, [uid/]deck/<规范全名>)`。
pub fn deck(salt: Salt<'_>, full_path: &str) -> Id {
    rooted(salt, &format!("deck/{}", normalize_deck_path(full_path)))
}

/// 同一全名的第 [n] 个备选牌组 ID（n ≥ 1）：`v5(NS, [uid/]deck-alt/<n>/<规范全名>)`。
pub fn deck_alternate(salt: Salt<'_>, full_path: &str, n: u32) -> Id {
    rooted(
        salt,
        &format!("deck-alt/{n}/{}", normalize_deck_path(full_path)),
    )
}

/// 内置默认牌组：`v5(NS, [uid/]builtin-deck/default)`。规范规则下是常量。
pub fn builtin_default_deck(salt: Salt<'_>) -> Id {
    rooted(salt, "builtin-deck/default")
}

/// profile 级设置实体的规范 ID。存量里它的 ID 就是 profile uid 本身（没有公式）；规范值取
/// `v5(NS, "profile")`。
pub fn profile_entity() -> Id {
    Id::v5(&NAMESPACE, "profile")
}

/// 从 Anki 导入的 revlog：`v5(cardId, anki-revlog/<revlog id>)`。
pub fn imported_revlog(card: &Id, anki_revlog_id: i64) -> Id {
    Id::v5(card, &format!("anki-revlog/{anki_revlog_id}"))
}

/// 导入锚点：`v5(cardId, anki-anchor/<时刻毫秒>)`。
pub fn import_anchor(card: &Id, anchor_ms: i64) -> Id {
    Id::v5(card, &format!("anki-anchor/{anchor_ms}"))
}

/// fushi-ext 导入到另一个 profile 时日志 ID 的重映射：`v5(新卡 ID, fushi-log/<原日志 ID 文本>)`。
/// 原日志 ID 没有存下来，别名判定验不了它（这类日志的规范 ID 是它自己）；这里只是把规则表列全。
pub fn remapped_log(new_card: &Id, original_log_id: &str) -> Id {
    Id::v5(new_card, &format!("fushi-log/{original_log_id}"))
}

/// 给「整组已撤销、但没被 undo 直接点名」的事件副本补的 undo：`v5(NS, event-copy-revoke/<副本日志 ID 文本>)`
/// （与 store/sync2 的 `copy_repair_undo_id` 同一个值；内核自己的规则，Dart 没有对应物）。
pub fn copy_repair_undo(copy: &Id) -> Id {
    Id::v5(&NAMESPACE, &format!("event-copy-revoke/{}", copy.text()))
}

/// 修改记录：`v5(NS, edit/<写入者>/<seq>)`（与 registers.rs 的 `edit_id` 同一个值）。
pub fn field_edit(writer: &str, seq: u64) -> Id {
    Id::v5(&NAMESPACE, &format!("edit/{writer}/{seq}"))
}

/// 由字符串确定性派生 53 位正整数（Dart `hash53`）：SHA-256 前 7 字节大端取低 53 位，0 记作 1。
pub fn hash53(input: &str) -> i64 {
    let d = Sha256::digest(input.as_bytes());
    let mut v = 0u64;
    for &b in &d[..7] {
        v = (v << 8) | u64::from(b);
    }
    v &= (1u64 << 53) - 1;
    if v == 0 { 1 } else { v as i64 }
}

/// 内置笔记类型（`lapis`、`fushi_card`）的固定 ankiNum。
pub fn builtin_note_type_anki_num(key: &str) -> i64 {
    hash53(&format!("fushi/builtin-notetype/{key}"))
}

/// 内置笔记类型字段的固定 ankiNum；[seed] 是字段的派生种子（改过名的字段用旧名，Dart `srsBuiltinFieldSeed`）。
pub fn builtin_field_anki_num(note_type_key: &str, seed: &str) -> i64 {
    hash53(&format!(
        "fushi/builtin-notetype/{note_type_key}/field/{seed}"
    ))
}

/// 内置笔记类型模板的固定 ankiNum；[template_key] 是模板名。
pub fn builtin_template_anki_num(note_type_key: &str, template_key: &str) -> i64 {
    hash53(&format!(
        "fushi/builtin-notetype/{note_type_key}/template/{template_key}"
    ))
}

/// 来源笔记类型里一个字段 / 模板在 [duplicate_note_type_anki_num] 里的身份：有配置 ID 用它，没有用名字。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DupPart<'a> {
    Config(i64),
    Name(&'a str),
}

/// 导入时「不合并笔记类型」另建的那一份的 ankiNum（以前在 Dart `SrsApkgImporter._duplicateAnkiNum`，G5 收进来）：
/// `hash53("notetype-dup/<来源 ankiNum>/<J>")`，J 是 `{"cloze":…,"fields":[…],"tmpls":[…]}` 的规范 JSON——键按字典序、
/// 紧凑、非 ASCII 原样，字符串转义与 Dart `jsonEncode` 相同；每项是配置 ID（数字）或 `"name:<名字>"`。
/// 由来源身份 + 结构确定性派生：两台设备导入同一个包得到同一个值，同一种结构再导入回到同一份副本。
/// 它再经 [note_type] 成为笔记类型 ID。
pub fn duplicate_note_type_anki_num(
    src_anki_num: i64,
    cloze: bool,
    fields: &[DupPart<'_>],
    templates: &[DupPart<'_>],
) -> i64 {
    let parts = |ps: &[DupPart<'_>]| -> Vec<serde_json::Value> {
        ps.iter()
            .map(|p| match p {
                DupPart::Config(n) => serde_json::Value::from(*n),
                DupPart::Name(name) => serde_json::Value::from(format!("name:{name}")),
            })
            .collect()
    };
    // json! 的对象是有序映射（serde_json 没开 preserve_order），键按字典序输出。
    let body = serde_json::json!({
        "cloze": cloze,
        "fields": parts(fields),
        "tmpls": parts(templates),
    });
    hash53(&format!("notetype-dup/{src_anki_num}/{body}"))
}

/// 导出到 Anki 的笔记 / 卡片数字 id：`hash53("anki-id/<UUID 文本>")`（与 store/schema.rs `anki_numeric_id` 同值）。
pub fn anki_numeric_id(uuid: &str) -> i64 {
    hash53(&format!("anki-id/{uuid}"))
}

/// 旧并入（packages/fushi_engine/lib/srs/srs_profile_merge.dart `_IdMap.fallbackAll`）给还原不出派生输入的 ID
/// 取的兜底：`v5(NS, profile-merge/<目标 uid>/<旧 ID 小写文本>)`。**只用来验算**，协议 4 不再生成。
///
/// [old_id] 是旧 ID 的文本；UUID 传规范小写形式即可。非 UUID 文本按 `str::to_lowercase` 转小写——Dart 那边是
/// `String.toLowerCase()`，非 ASCII 字符的大小写规则两边可能不同（没有向量，也没见过这样的存量 ID）。
pub fn merge_fallback(target_uid: &str, old_id: &str) -> Id {
    Id::v5(
        &NAMESPACE,
        &format!("profile-merge/{target_uid}/{}", old_id.to_lowercase()),
    )
}

/// 旧并入给写入者改名用的哈希（同文件 `_mergedWriterNames`）：`v5(NS, profile-merge/<目标 uid>/writer/<最初的写入者>)`，
/// 改名后的写入者是 `merged-<它>`（2026-11 之前）或 `merged-<它>~<最初的写入者>`。**只用来验算**。
pub fn merged_writer_hash(target_uid: &str, origin_writer: &str) -> Id {
    Id::v5(
        &NAMESPACE,
        &format!("profile-merge/{target_uid}/writer/{origin_writer}"),
    )
}
