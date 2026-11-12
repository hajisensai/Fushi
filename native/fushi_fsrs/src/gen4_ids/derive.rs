//! Dart 向内核要 ID 的入口（`ffsrs_call` 的 `ids`，docs/specs/2026-11-11-srs-generation-break.md §5.1、§5.2、G5）。
//!
//! 规则表只在 [rules] 一处；Dart 不再自己拼「`<uid>/note/<guid>`」这类名字，也不再按 uid 拼同步目录，一律经这里问。
//! 一批请求一次 FFI（`items` 逐项对应结果），不逐个跨边界。
//!
//! 根上的 ID 用哪个盐、同步目录叫什么，由内核按 profile 决定（[salt_of] / [location_dir_of]）。协议 4 切换（G7）之前
//! 内核仍按存量规则答：盐 = profile uid、目录名 = profile uid——与改造前 Dart 自己算的逐字节相同，行为不变。G7 起
//! 这两个函数改查集合绑定（§5.1）；绑定在 srs.db 里，到时这个入口要连到 store（改成带 store 的内核命令），
//! 调用方只经 Dart 的 `SrsKernelIds` 问，改动收在那一处。
//!
//! 请求：`{"op":"ids","profile":<uid>?,"items":[[种类, 参数…], …]}`，响应是与 `items` 等长的数组：
//!
//! | 种类 | 参数 | 结果 |
//! |---|---|---|
//! | `note` | guid | 笔记 ID |
//! | `notetype` | ankiNum | 笔记类型 ID |
//! | `builtin_notetype` | 内置类型的键（`lapis` / `fushi_card`） | 内置笔记类型 ID |
//! | `deck` | 全名 | 牌组 ID |
//! | `deck_alt` | 全名, n（≥ 1） | 第 n 个备选牌组 ID |
//! | `default_deck` | — | 内置默认牌组 ID |
//! | `location_dir` | — | 同步位置上集合根的目录名（`fushi-srs/<它>/`） |
//! | `dup_notetype_num` | 来源 ankiNum, 是否填空, 字段, 模板 | 「不合并笔记类型」另建那一份的 ankiNum（整数） |
//! | `merge_fallback` | 目标 uid, 旧 ID | 旧并入的兜底 ID |
//! | `merged_writer` | 目标 uid, 最初的写入者 | 旧并入改名写入者用的哈希 |
//!
//! 前七种要 `profile`；后三种不依赖 profile（`merge_*` 的盐是显式给的目标 uid，只给旧并入用）。
//! `dup_notetype_num` 的字段 / 模板每项是 `[配置 ID 或 null, 名字]`。

use serde_json::{Value, json};

use super::rules::{self, DupPart, Salt};

/// [profile] 的根上 ID 用哪个盐。G7 之前 = profile uid（存量规则）；G7 起改查集合绑定。
fn salt_of(profile: &str) -> Salt<'_> {
    Some(profile)
}

/// [profile] 的集合根在同步位置上的目录名（§5.1「位置目录名」）。G7 之前 = profile uid；G7 起改查集合绑定。
fn location_dir_of(profile: &str) -> String {
    profile.to_string()
}

fn arg<'a>(item: &'a [Value], i: usize, kind: &str) -> Result<&'a Value, String> {
    item.get(i)
        .ok_or_else(|| format!("ids: `{kind}` needs argument {i}"))
}

fn arg_str<'a>(item: &'a [Value], i: usize, kind: &str) -> Result<&'a str, String> {
    arg(item, i, kind)?
        .as_str()
        .ok_or_else(|| format!("ids: `{kind}` argument {i} must be a string"))
}

fn arg_int(item: &[Value], i: usize, kind: &str) -> Result<i64, String> {
    arg(item, i, kind)?
        .as_i64()
        .ok_or_else(|| format!("ids: `{kind}` argument {i} must be an integer"))
}

fn parts<'a>(v: &'a Value, kind: &str) -> Result<Vec<DupPart<'a>>, String> {
    let bad = || format!("ids: `{kind}` parts must be [[configId|null, name], …]");
    v.as_array()
        .ok_or_else(bad)?
        .iter()
        .map(|p| {
            let p = p.as_array().filter(|p| p.len() == 2).ok_or_else(bad)?;
            match (&p[0], p[1].as_str()) {
                (Value::Null, Some(name)) => Ok(DupPart::Name(name)),
                (n, Some(_)) => n.as_i64().map(DupPart::Config).ok_or_else(bad),
                _ => Err(bad()),
            }
        })
        .collect()
}

fn one(profile: Option<&str>, item: &Value) -> Result<Value, String> {
    let item = item
        .as_array()
        .filter(|a| !a.is_empty())
        .ok_or("ids: every item must be a non-empty array")?;
    let kind = item[0].as_str().ok_or("ids: item kind must be a string")?;
    let profile = || profile.ok_or_else(|| format!("ids: `{kind}` needs `profile`"));
    let id = |id: crate::sync2::id::Id| Value::String(id.text());
    Ok(match kind {
        "note" => id(rules::note(salt_of(profile()?), arg_str(item, 1, kind)?)),
        "notetype" => id(rules::note_type(
            salt_of(profile()?),
            arg_int(item, 1, kind)?,
        )),
        "builtin_notetype" => id(rules::note_type(
            salt_of(profile()?),
            rules::builtin_note_type_anki_num(arg_str(item, 1, kind)?),
        )),
        "deck" => id(rules::deck(salt_of(profile()?), arg_str(item, 1, kind)?)),
        "deck_alt" => {
            let n = u32::try_from(arg_int(item, 2, kind)?)
                .ok()
                .filter(|n| *n >= 1)
                .ok_or("ids: `deck_alt` n must be ≥ 1")?;
            id(rules::deck_alternate(
                salt_of(profile()?),
                arg_str(item, 1, kind)?,
                n,
            ))
        }
        "default_deck" => id(rules::builtin_default_deck(salt_of(profile()?))),
        "location_dir" => Value::String(location_dir_of(profile()?)),
        "dup_notetype_num" => {
            let cloze = arg(item, 2, kind)?
                .as_bool()
                .ok_or("ids: `dup_notetype_num` cloze must be a bool")?;
            json!(rules::duplicate_note_type_anki_num(
                arg_int(item, 1, kind)?,
                cloze,
                &parts(arg(item, 3, kind)?, kind)?,
                &parts(arg(item, 4, kind)?, kind)?,
            ))
        }
        "merge_fallback" => id(rules::merge_fallback(
            arg_str(item, 1, kind)?,
            arg_str(item, 2, kind)?,
        )),
        "merged_writer" => id(rules::merged_writer_hash(
            arg_str(item, 1, kind)?,
            arg_str(item, 2, kind)?,
        )),
        other => return Err(format!("ids: unknown kind `{other}`")),
    })
}

/// `ffsrs_call` 的 `ids`：见模块说明。
pub fn derive(req: &Value) -> Result<Value, String> {
    let profile = req.get("profile").and_then(Value::as_str);
    let items = req
        .get("items")
        .and_then(Value::as_array)
        .ok_or("ids: missing `items`")?;
    items
        .iter()
        .map(|item| one(profile, item))
        .collect::<Result<Vec<_>, _>>()
        .map(Value::Array)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gen4_ids::rules::CANONICAL;

    const UID: &str = "019a5e4c-0000-7000-8000-00000000abcd";

    fn ask(items: Value) -> Vec<Value> {
        match derive(&json!({ "profile": UID, "items": items })).unwrap() {
            Value::Array(v) => v,
            other => panic!("{other}"),
        }
    }

    fn text(id: crate::sync2::id::Id) -> Value {
        Value::String(id.text())
    }

    #[test]
    fn answers_the_salted_rules_until_the_switch() {
        // G7 之前：盐 = profile uid，目录名 = profile uid（与改造前 Dart 算的相同）。
        let got = ask(json!([
            ["note", "i0.As71JXL"],
            ["notetype", 1725626812943i64],
            ["builtin_notetype", "lapis"],
            ["deck", " 日本語 :: 単語 "],
            ["deck_alt", "日本語::単語", 2],
            ["default_deck"],
            ["location_dir"],
        ]));
        let salt = Some(UID);
        assert_eq!(
            got,
            vec![
                text(rules::note(salt, "i0.As71JXL")),
                text(rules::note_type(salt, 1725626812943)),
                text(rules::note_type(
                    salt,
                    rules::builtin_note_type_anki_num("lapis")
                )),
                text(rules::deck(salt, "日本語::単語")),
                text(rules::deck_alternate(salt, "日本語::単語", 2)),
                text(rules::builtin_default_deck(salt)),
                Value::String(UID.into()),
            ]
        );
        assert_ne!(got[0], text(rules::note(CANONICAL, "i0.As71JXL")));
    }

    #[test]
    fn profile_free_kinds_do_not_need_a_profile() {
        let got = derive(&json!({ "items": [
            ["merge_fallback", UID, "ABC-def"],
            ["merged_writer", UID, "dev-1"],
            ["dup_notetype_num", 7, false, [[1, "Front"], [null, "Back"]], [[null, "Card 1"]]],
        ] }))
        .unwrap();
        assert_eq!(
            got,
            json!([
                rules::merge_fallback(UID, "ABC-def").text(),
                rules::merged_writer_hash(UID, "dev-1").text(),
                rules::duplicate_note_type_anki_num(
                    7,
                    false,
                    &[DupPart::Config(1), DupPart::Name("Back")],
                    &[DupPart::Name("Card 1")],
                ),
            ])
        );
        let err = derive(&json!({ "items": [["note", "g"]] })).unwrap_err();
        assert!(err.contains("needs `profile`"), "{err}");
    }

    /// 向量由改造前的 Dart 公式（`hash53('notetype-dup/<n>/${srsCanonicalJson({cloze, fields, tmpls})}')`）的
    /// 等价实现算出：转义（引号、反斜杠、控制字符、DEL、非 ASCII）与 Dart `jsonEncode` 相同。
    #[test]
    fn duplicate_note_type_anki_num_matches_the_dart_formula() {
        use DupPart::{Config, Name};
        assert_eq!(
            rules::duplicate_note_type_anki_num(
                1725626812943,
                false,
                &[Config(1725626812944), Name("Back")],
                &[Name("Card 1"), Config(1725626812950)],
            ),
            5964709379676257
        );
        assert_eq!(
            rules::duplicate_note_type_anki_num(
                42,
                true,
                &[Name("\u{8868}\u{9762} \"q\"\\\n\t\u{1}\u{7f}/")],
                &[Config(7)],
            ),
            2137450084047616
        );
        assert_eq!(
            rules::duplicate_note_type_anki_num(-5, false, &[], &[]),
            3380722550824366
        );
    }

    #[test]
    fn rejects_malformed_items() {
        for bad in [
            json!([[]]),
            json!([["nope"]]),
            json!([["note"]]),
            json!([["notetype", "1"]]),
            json!([["deck_alt", "A", 0]]),
            json!([["dup_notetype_num", 1, false, [[1]], []]]),
        ] {
            assert!(
                derive(&json!({ "profile": UID, "items": bad })).is_err(),
                "{bad}"
            );
        }
    }
}
