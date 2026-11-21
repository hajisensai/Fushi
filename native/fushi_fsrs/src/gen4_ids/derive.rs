//! Dart 向内核要 ID 的入口（`ffsrs_call` 的 `ids`，docs/specs/2026-11-11-srs-generation-break.md §5.1、§5.2、G5）。
//!
//! 规则表只在 [rules] 一处；Dart 不再自己拼「`<uid>/note/<guid>`」这类名字，也不再按 uid 拼同步目录，一律经这里问。
//! 一批请求一次 FFI（`items` 逐项对应结果），不逐个跨边界。
//!
//! **根上的 ID 一律按规范规则答（不带盐，G9-7）**：设计 §5.2「新写入的实体一律按现有规则表、去掉 `<profileUid>/`
//! 前缀」、§5.1「查绑定只为两件事：位置目录名，与别名验算用的盐集合；写入不用盐」（D24）。所以这里答的就是内核读命令
//! 回的规范 ID，不依赖 profile、不依赖绑定，纯函数、不碰库：
//!
//! - 全新库：没有带盐的存量，规范规则算出的 ID 就是规范 ID；
//! - 迁移来的库：存量实体的 ID 是协议 3 按 uid 加盐派生的，派生层把它们归到**同一个**规范 ID（别名验算按自然键 ×
//!   盐集合重算，`alias.rs`；内置默认牌组 / 内置笔记类型同理，`builtin_default_deck(CANONICAL)`）。这里答的规范 ID
//!   落在已有的别名类上，不会另建一份（默认牌组等内置实体只有一个类）。
//!
//! 协议 3 时代这里答带盐的值（盐 = profile uid）：切到新代后那是别名类的成员 ID，Dart 拿它和读命令回的规范 ID 比就
//! 对不上（新卡被藏、按请求 ID 预建的槽取空，交接说明 §13.6 第 1 条、§14）。带盐规则只剩别名验算一个用途。
//! 位置目录名不在这里定：同步目录向绑定要（`identity` 回包的 `dir`，§5.1）；`location_dir` 只按 profile uid 答协议 3
//! 时代的存量目录名，留给还没改到 `dir` 的旧调用点。
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
//! | `tombstone_device` | 集合目录名 | 新代在旧根 `v3/devices/` 下立的墓碑 head 的「设备」（`gen4/location.rs` [crate::gen4::location::tombstone_device]；列位置上的写入者时跳过它） |
//!
//! 只有 `location_dir` 要 `profile`；其余不依赖 profile（请求里带了也不看；`merge_*` 的盐是显式给的目标 uid，只给旧
//! 并入用）。
//! `dup_notetype_num` 的字段 / 模板每项是 `[配置 ID 或 null, 名字]`。

use serde_json::{Value, json};

use super::rules::{self, CANONICAL, DupPart};

/// [profile] 在协议 3 时代的同步目录名（= profile uid）。新代的目录名向绑定要（`identity` 回包的 `dir`，见模块说明）。
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
        "note" => id(rules::note(CANONICAL, arg_str(item, 1, kind)?)),
        "notetype" => id(rules::note_type(CANONICAL, arg_int(item, 1, kind)?)),
        "builtin_notetype" => id(rules::note_type(
            CANONICAL,
            rules::builtin_note_type_anki_num(arg_str(item, 1, kind)?),
        )),
        "deck" => id(rules::deck(CANONICAL, arg_str(item, 1, kind)?)),
        "deck_alt" => {
            let n = u32::try_from(arg_int(item, 2, kind)?)
                .ok()
                .filter(|n| *n >= 1)
                .ok_or("ids: `deck_alt` n must be ≥ 1")?;
            id(rules::deck_alternate(CANONICAL, arg_str(item, 1, kind)?, n))
        }
        "default_deck" => id(rules::builtin_default_deck(CANONICAL)),
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
        "tombstone_device" => id(crate::gen4::location::tombstone_device(arg_str(
            item, 1, kind,
        )?)),
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

    /// 根上的规则一律按规范规则答（G9-7，模块说明）：与 [rules::CANONICAL] 逐项相同、与按 uid 加盐的存量规则不同，
    /// 换一个 profile 问答案不变；目录名仍是 profile uid。
    #[test]
    fn answers_the_canonical_rules_whatever_the_profile() {
        let items = json!([
            ["note", "i0.As71JXL"],
            ["notetype", 1725626812943i64],
            ["builtin_notetype", "lapis"],
            ["deck", " 日本語 :: 単語 "],
            ["deck_alt", "日本語::単語", 2],
            ["default_deck"],
            ["location_dir"],
        ]);
        let got = ask(items.clone());
        assert_eq!(
            got,
            vec![
                text(rules::note(CANONICAL, "i0.As71JXL")),
                text(rules::note_type(CANONICAL, 1725626812943)),
                text(rules::note_type(
                    CANONICAL,
                    rules::builtin_note_type_anki_num("lapis")
                )),
                text(rules::deck(CANONICAL, "日本語::単語")),
                text(rules::deck_alternate(CANONICAL, "日本語::単語", 2)),
                text(rules::builtin_default_deck(CANONICAL)),
                Value::String(UID.into()),
            ]
        );
        assert_ne!(got[0], text(rules::note(Some(UID), "i0.As71JXL")));
        assert_ne!(got[5], text(rules::builtin_default_deck(Some(UID))));
        const OTHER: &str = "019a5e4c-0000-7000-8000-00000000ef01";
        let other = match derive(&json!({ "profile": OTHER, "items": items })).unwrap() {
            Value::Array(v) => v,
            v => panic!("{v}"),
        };
        assert_eq!(other[..6], got[..6]);
        assert_eq!(other[6], Value::String(OTHER.into()));
        // 不带 profile 也答得出（只有 `location_dir` 要 profile）。
        let bare = derive(&json!({ "items": [["note", "i0.As71JXL"], ["default_deck"]] })).unwrap();
        assert_eq!(bare, json!([got[0], got[5]]));
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
        let err = derive(&json!({ "items": [["location_dir"]] })).unwrap_err();
        assert!(err.contains("needs `profile`"), "{err}");
    }

    /// `tombstone_device`（第五波 G9 身份收尾）：Dart 列位置上的写入者时要跳过的墓碑设备由内核给，与立围栏写的同一个；
    /// 值就是冻结的 `v5(NS, "fushi-srs/tombstone/4/<dir>")`（改造前 Dart `srsTombstoneDevice` 自己算的那个）。不要 profile。
    #[test]
    fn tombstone_device_is_the_fence_writers_device() {
        use crate::sync2::id::Id;
        let got = derive(
            &json!({ "items": [["tombstone_device", "dir-a"], ["tombstone_device", "dir-b"]] }),
        )
        .unwrap();
        let want = |dir: &str| {
            Id::v5(
                &Id::parse(crate::store::sync2::config::SRS_NAMESPACE).unwrap(),
                &format!("fushi-srs/tombstone/4/{dir}"),
            )
            .text()
        };
        assert_eq!(got, json!([want("dir-a"), want("dir-b")]));
        assert_eq!(
            got[0],
            json!(crate::gen4::location::tombstone_device("dir-a").text())
        );
        let err = derive(&json!({ "items": [["tombstone_device"]] })).unwrap_err();
        assert!(err.contains("argument 1"), "{err}");
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
