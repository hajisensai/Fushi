//! 内置笔记类型表（设计稿 §5.3「内置笔记类型的字段 / 模板表只能追加」、§9 第 15 行；实现拆分 G6c）。
//!
//! 别名判定（[super::alias::resolve]）用它验算存量库里内置笔记类型、它们的字段定义与模板定义的带盐 ID：
//! `ankiNum` 由 `key` / 字段种子 / 模板键按 [super::rules] 的公式算出，规范 ID 再由 `ankiNum` 算出。
//! 这张表以前是宿主输入（Dart `srs_builtin.dart` 的 `kSrsBuiltinNoteTypes` 经 `derive_cfg` 传进来），
//! 现在由内核持有：判定的输入不随宿主版本、也不随哪台设备先给了哪一版而变，别名表才是「真相 + 本表」的纯函数。
//!
//! **只能追加**：删掉一个内置类型 / 字段 / 模板，它在存量库里的带盐 ID 就再也归不了一（规范 ID 退回它自己，
//! 两台设备之间的同一个字段从此是两个实体）。改名同理——种子与模板键是哈希输入，不是显示名。
//! 守卫：
//! - `tests::the_table_only_grows`：对着本文件里冻结的第一版逐项比，每一项都必须还在、且原有的种子 / 模板键是前缀；
//! - `tests::the_table_matches_the_frozen_vectors`：与 `golden_ids.json` 的 `builtins` 逐项相同。那个文件由
//!   packages/fushi_engine/test/srs/srs_gen4_canonical_ids_golden_test.dart 从 Dart 的表生成并逐项核对，
//!   所以 Dart 的表与这里一改不同步，两边总有一个测试红。

use super::alias::BuiltinNoteType;

/// 一个内置笔记类型：`key`（哈希输入）、字段种子、模板键，各按 Dart 表里的顺序。
#[derive(Clone, Copy, Debug)]
pub struct BuiltinSpec {
    pub key: &'static str,
    pub field_seeds: &'static [&'static str],
    pub template_keys: &'static [&'static str],
}

/// Lapis 与 Fushi 卡共用的前 22 个字段种子（Fushi 卡在末尾多一个 `SentenceTranslation`）。
const LAPIS_FIELDS: [&str; 22] = [
    "Expression",
    "ExpressionFurigana",
    "ExpressionReading",
    "ExpressionAudio",
    "SelectionText",
    "MainDefinition",
    "DefinitionPicture",
    "Sentence",
    "SentenceFurigana",
    "SentenceAudio",
    "Picture",
    "Glossary",
    "Hint",
    "IsWordAndSentenceCard",
    "IsClickCard",
    "IsSentenceCard",
    "IsAudioCard",
    "PitchPosition",
    "PitchCategories",
    "Frequency",
    "FreqSort",
    "MiscInfo",
];

const FUSHI_CARD_FIELDS: [&str; 23] = [
    "Expression",
    "ExpressionFurigana",
    "ExpressionReading",
    "ExpressionAudio",
    "SelectionText",
    "MainDefinition",
    "DefinitionPicture",
    "Sentence",
    "SentenceFurigana",
    "SentenceAudio",
    "Picture",
    "Glossary",
    "Hint",
    "IsWordAndSentenceCard",
    "IsClickCard",
    "IsSentenceCard",
    "IsAudioCard",
    "PitchPosition",
    "PitchCategories",
    "Frequency",
    "FreqSort",
    "MiscInfo",
    "SentenceTranslation",
];

/// 内核持有的那张表（顺序与 Dart `kSrsBuiltinNoteTypes` 相同）。只能追加，见文件头。
pub const BUILTIN_NOTE_TYPES: &[BuiltinSpec] = &[
    BuiltinSpec {
        key: "lapis",
        field_seeds: &LAPIS_FIELDS,
        template_keys: &["Card 1"],
    },
    BuiltinSpec {
        key: "fushi_card",
        field_seeds: &FUSHI_CARD_FIELDS,
        template_keys: &["Card 1"],
    },
];

/// 别名判定要的形状（[super::alias::Evidence::builtins]）。
pub fn builtin_note_types() -> Vec<BuiltinNoteType> {
    BUILTIN_NOTE_TYPES
        .iter()
        .map(|b| BuiltinNoteType {
            key: b.key.to_owned(),
            field_seeds: b.field_seeds.iter().map(|s| (*s).to_owned()).collect(),
            template_keys: b.template_keys.iter().map(|s| (*s).to_owned()).collect(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    /// 协议 4 发布时冻结的第一版（不许改；表变了只往 [BUILTIN_NOTE_TYPES] 追加）。
    const FROZEN_V1: [(&str, &[&str], &[&str]); 2] = [
        ("lapis", &LAPIS_FIELDS, &["Card 1"]),
        ("fushi_card", &FUSHI_CARD_FIELDS, &["Card 1"]),
    ];

    #[test]
    fn the_table_only_grows() {
        assert!(BUILTIN_NOTE_TYPES.len() >= FROZEN_V1.len());
        for (i, (key, fields, templates)) in FROZEN_V1.iter().enumerate() {
            let now = &BUILTIN_NOTE_TYPES[i];
            assert_eq!(now.key, *key, "builtin #{i} was renamed or reordered");
            assert!(
                now.field_seeds.starts_with(fields),
                "{key}: field seeds may only be appended"
            );
            assert!(
                now.template_keys.starts_with(templates),
                "{key}: template keys may only be appended"
            );
        }
        let mut keys: Vec<&str> = BUILTIN_NOTE_TYPES.iter().map(|b| b.key).collect();
        keys.sort_unstable();
        keys.dedup();
        assert_eq!(
            keys.len(),
            BUILTIN_NOTE_TYPES.len(),
            "duplicate builtin key"
        );
    }

    #[test]
    fn the_table_matches_the_frozen_vectors() {
        let golden: Value = serde_json::from_str(super::super::GOLDEN).unwrap();
        let strings = |v: &Value, field: &str| -> Vec<String> {
            v.as_array()
                .unwrap()
                .iter()
                .map(|f| f[field].as_str().unwrap().to_owned())
                .collect()
        };
        let want: Vec<(String, Vec<String>, Vec<String>)> = golden["builtins"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| {
                (
                    b["key"].as_str().unwrap().to_owned(),
                    strings(&b["fields"], "seed"),
                    strings(&b["templates"], "name"),
                )
            })
            .collect();
        let have: Vec<(String, Vec<String>, Vec<String>)> = builtin_note_types()
            .into_iter()
            .map(|b| (b.key, b.field_seeds, b.template_keys))
            .collect();
        assert_eq!(have, want);
    }
}
