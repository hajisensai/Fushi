//! 规则表对冻结向量、别名判定的单测。

use std::collections::BTreeSet;

use serde_json::Value;

use crate::sync2::id::{Id, Key};

use super::alias::{
    BuiltinNoteType, DeckEv, DefEv, Dot, Evidence, How, Limits, LogEv, NoteEv, NoteTypeEv, Why,
    WriterEv, WriterHow, resolve, strict_id,
};
use super::rules::{self, CANONICAL};

fn id(v: &Value) -> Id {
    Id::parse(v.as_str().expect("id text")).expect("uuid")
}

fn text<'a>(args: &'a Value, key: &str) -> &'a str {
    args[key]
        .as_str()
        .unwrap_or_else(|| panic!("{key} in {args}"))
}

fn int(args: &Value, key: &str) -> i64 {
    args[key]
        .as_i64()
        .unwrap_or_else(|| panic!("{key} in {args}"))
}

/// 根规则的一条向量：规范值、每个盐下的值、规范名字。
fn rooted(case: &Value, rule: impl Fn(rules::Salt<'_>) -> Id) {
    assert_eq!(rule(CANONICAL), id(&case["canonical"]), "{case}");
    assert_eq!(
        Id::v5(&rules::NAMESPACE, case["name"].as_str().unwrap()),
        id(&case["canonical"]),
        "{case}"
    );
    let salted = case["salted"].as_object().unwrap();
    assert!(!salted.is_empty());
    for (uid, want) in salted {
        assert_eq!(rule(Some(uid)), id(want), "{case} / {uid}");
        assert_ne!(id(want), id(&case["canonical"]), "{case}");
    }
}

/// 规则表与 Dart `SrsIds` 逐值相同：向量由 Dart 生成并冻结，Dart 测试
/// （packages/fushi_engine/test/srs/srs_gen4_canonical_ids_golden_test.dart）对同一个文件重算。
#[test]
fn rule_table_matches_the_frozen_dart_vectors() {
    let g: Value = serde_json::from_str(super::GOLDEN).unwrap();
    assert_eq!(g["namespace"].as_str().unwrap(), rules::NAMESPACE.text());
    assert_eq!(
        id(&g["builtinDefaultDeck"]),
        rules::builtin_default_deck(CANONICAL)
    );
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let cases = g["cases"].as_array().unwrap();
    for c in cases {
        let rule = c["rule"].as_str().unwrap();
        let a = &c["args"];
        seen.insert(rule.to_owned());
        match rule {
            "note" => rooted(c, |s| rules::note(s, text(a, "guid"))),
            "note_type" => rooted(c, |s| rules::note_type(s, int(a, "ankiNum"))),
            "deck" => {
                assert_eq!(
                    rules::normalize_deck_path(text(a, "path")),
                    text(a, "normalized"),
                    "{c}"
                );
                rooted(c, |s| rules::deck(s, text(a, "path")));
            }
            "deck_alternate" => rooted(c, |s| {
                rules::deck_alternate(s, text(a, "path"), int(a, "n") as u32)
            }),
            "builtin_default_deck" => rooted(c, rules::builtin_default_deck),
            "field" => assert_eq!(
                rules::field(&id(&a["noteType"]), int(a, "ankiNum")),
                id(&c["id"]),
                "{c}"
            ),
            "template" => assert_eq!(
                rules::template(&id(&a["noteType"]), int(a, "ankiNum")),
                id(&c["id"]),
                "{c}"
            ),
            "field_by_name" => assert_eq!(
                rules::field_by_name(&id(&a["noteType"]), text(a, "name")),
                id(&c["id"]),
                "{c}"
            ),
            "template_by_name" => assert_eq!(
                rules::template_by_name(&id(&a["noteType"]), text(a, "name")),
                id(&c["id"]),
                "{c}"
            ),
            "card" => assert_eq!(
                rules::card(&id(&a["note"]), &id(&a["template"]), int(a, "clozeOrd")),
                id(&c["id"]),
                "{c}"
            ),
            "imported_revlog" => assert_eq!(
                rules::imported_revlog(&id(&a["card"]), int(a, "ankiRevlogId")),
                id(&c["id"]),
                "{c}"
            ),
            "import_anchor" => assert_eq!(
                rules::import_anchor(&id(&a["card"]), int(a, "anchorMs")),
                id(&c["id"]),
                "{c}"
            ),
            "remapped_log" => assert_eq!(
                rules::remapped_log(&id(&a["card"]), text(a, "originalLogId")),
                id(&c["id"]),
                "{c}"
            ),
            "field_edit" => {
                let (w, seq) = (text(a, "writer"), int(a, "seq"));
                assert_eq!(rules::field_edit(w, seq as u64), id(&c["id"]), "{c}");
                // 内核现有的同一条规则（registers.rs）。
                assert_eq!(
                    crate::registers::edit_id(w, seq),
                    id(&c["id"]).text(),
                    "{c}"
                );
            }
            "profile_entity" => assert_eq!(rules::profile_entity(), id(&c["id"]), "{c}"),
            "merge_fallback" => assert_eq!(
                rules::merge_fallback(text(a, "targetUid"), text(a, "oldId")),
                id(&c["id"]),
                "{c}"
            ),
            "merged_writer_hash" => assert_eq!(
                rules::merged_writer_hash(text(a, "targetUid"), text(a, "origin")),
                id(&c["id"]),
                "{c}"
            ),
            "hash53" => assert_eq!(rules::hash53(text(a, "input")), int(c, "n"), "{c}"),
            "anki_numeric_id" => {
                assert_eq!(rules::anki_numeric_id(text(a, "uuid")), int(c, "n"), "{c}");
                // 内核现有的同一条规则（store/schema.rs）。
                assert_eq!(
                    crate::store::schema::anki_numeric_id(text(a, "uuid")),
                    int(c, "n"),
                    "{c}"
                );
            }
            other => panic!("vector for a rule this test does not know: {other}"),
        }
    }
    // 每条规则至少一条向量：规则表加了函数而没加向量时这里会少一项。
    let want: BTreeSet<String> = [
        "note",
        "note_type",
        "deck",
        "deck_alternate",
        "builtin_default_deck",
        "field",
        "template",
        "field_by_name",
        "template_by_name",
        "card",
        "imported_revlog",
        "import_anchor",
        "remapped_log",
        "field_edit",
        "profile_entity",
        "merge_fallback",
        "merged_writer_hash",
        "hash53",
        "anki_numeric_id",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect();
    assert_eq!(seen, want);
    assert!(cases.len() > 150, "{}", cases.len());
}

/// 内置笔记类型：ankiNum、字段 / 模板的 ankiNum 与 ID 都与 Dart 的内置表相同；规范 ID 不随 uid 变。
#[test]
fn builtin_note_types_match_the_frozen_dart_table() {
    let g: Value = serde_json::from_str(super::GOLDEN).unwrap();
    let builtins = g["builtins"].as_array().unwrap();
    assert!(builtins.len() >= 2);
    for b in builtins {
        let key = b["key"].as_str().unwrap();
        let n = rules::builtin_note_type_anki_num(key);
        assert_eq!(n, int(b, "ankiNum"), "{key}");
        let canonical = rules::note_type(CANONICAL, n);
        assert_eq!(canonical, id(&b["canonical"]), "{key}");
        let salted = b["salted"].as_object().unwrap();
        for (uid, want) in salted {
            assert_eq!(rules::note_type(Some(uid), n), id(want), "{key} / {uid}");
        }
        let fields = b["fields"].as_array().unwrap();
        assert!(!fields.is_empty());
        for f in fields {
            let fnum = rules::builtin_field_anki_num(key, f["seed"].as_str().unwrap());
            assert_eq!(fnum, int(f, "ankiNum"), "{key} {f}");
            assert_eq!(rules::field(&canonical, fnum), id(&f["canonical"]), "{f}");
            for (uid, want) in f["salted"].as_object().unwrap() {
                assert_eq!(rules::field(&id(&salted[uid]), fnum), id(want), "{f}");
            }
        }
        let templates = b["templates"].as_array().unwrap();
        assert!(!templates.is_empty());
        for t in templates {
            let tnum = rules::builtin_template_anki_num(key, t["name"].as_str().unwrap());
            assert_eq!(tnum, int(t, "ankiNum"), "{key} {t}");
            assert_eq!(
                rules::template(&canonical, tnum),
                id(&t["canonical"]),
                "{t}"
            );
            for (uid, want) in t["salted"].as_object().unwrap() {
                assert_eq!(rules::template(&id(&salted[uid]), tnum), id(want), "{t}");
            }
        }
    }
}

/// 几个值的字面量：黄金文件被重新生成也不该跟着变。
#[test]
fn a_few_ids_are_pinned_as_literals() {
    let pin = |s: &str| Id::parse(s).unwrap();
    assert_eq!(
        rules::builtin_default_deck(CANONICAL),
        pin("02794a1b-ad99-5812-a13b-52217cd24bdd")
    );
    assert_eq!(
        rules::profile_entity(),
        pin("797b9d31-5e40-51b5-8c9d-ec2c0f7886a6")
    );
    assert_eq!(
        rules::builtin_note_type_anki_num("lapis"),
        863_107_405_324_239
    );
    assert_eq!(
        rules::note_type(CANONICAL, 863_107_405_324_239),
        pin("a87b85bc-7b87-542e-9fa5-7e1e6716c2ef")
    );
    assert_eq!(
        rules::builtin_note_type_anki_num("fushi_card"),
        6_865_678_542_292_102
    );
    assert_eq!(
        rules::note_type(CANONICAL, 6_865_678_542_292_102),
        pin("21888fd9-6405-5de7-be19-863ab4acde63")
    );
    assert_eq!(
        rules::note(CANONICAL, "abc"),
        pin("bddc2151-8d2c-5d81-a860-482e869b1f39")
    );
    assert_eq!(
        rules::note(Some("01928c3e-0000-7000-8000-0000000000a1"), "abc"),
        pin("6c3af7e5-8821-54c3-9016-1ab91314647d")
    );
}

/// 牌组全名的 trim 按 Dart 的空白集合（多一个 U+FEFF；U+180E、U+200B 不算空白）。
#[test]
fn deck_paths_trim_like_dart() {
    assert_eq!(rules::normalize_deck_path("\u{feff}A::B\u{3000}"), "A::B");
    assert_eq!(rules::normalize_deck_path(" A :: B "), "A::B");
    assert_eq!(rules::normalize_deck_path("A::::B"), "A::B");
    assert_eq!(rules::normalize_deck_path(":::"), ":");
    assert_eq!(rules::normalize_deck_path("\u{180e}A"), "\u{180e}A");
    assert_eq!(rules::normalize_deck_path("\u{200b}A"), "\u{200b}A");
    assert_eq!(rules::normalize_deck_path(""), "");
}

// ------------------------------------------------------------------ 别名判定

const U1: &str = "01928c3e-0000-7000-8000-0000000000a1";
const U2: &str = "01928c3e-0000-7000-8000-0000000000b2";
/// [U1] 是排序后的第一个盐。
const S1: How = How::Salted { salt: 0 };

fn evidence(salts: &[&str]) -> Evidence {
    Evidence {
        salts: salts.iter().map(|s| (*s).to_owned()).collect(),
        ..Evidence::default()
    }
}

fn def_num(id: Id, n: i64) -> DefEv {
    DefEv {
        id,
        anki_nums: vec![n],
        names: Vec::new(),
    }
}

fn def_name(id: Id, name: &str) -> DefEv {
    DefEv {
        id,
        anki_nums: Vec::new(),
        names: vec![name.to_owned()],
    }
}

/// 随机 ID（UUIDv7）。
fn v7(n: u64) -> Id {
    Id::new_v7(1_700_000_000_000 + n)
}

/// 不是任何规则算得出的 UUIDv5。
fn stray(tag: &str) -> Id {
    Id::v5(&rules::NAMESPACE, &format!("test-stray/{tag}"))
}

/// 一个盐下的小集合：一个笔记类型（按号的字段 / 模板各一，按名的模板一个）、一条笔记、两张卡、父子牌组、
/// 一条导入日志和一个锚点。返回 (证据, 每个 ID 与它该有的规范 ID)。
/// 下标：0 笔记类型 1 字段 2 模板 3 按名模板 4 笔记 5 卡 6 第二张卡 7 父牌组 8 子牌组 9 导入日志 10 锚点。
fn small_collection(salt: rules::Salt<'_>) -> (Evidence, Vec<(Id, Id)>) {
    let at = |s: rules::Salt<'_>| {
        let nt = rules::note_type(s, 1_600_000_000_001);
        let field = rules::field(&nt, 5);
        let tpl = rules::template(&nt, 7);
        let tpl2 = rules::template_by_name(&nt, "Card 2");
        let note = rules::note(s, "guid-1");
        let card = rules::card(&note, &tpl, 0);
        let card2 = rules::card(&note, &tpl2, 0);
        let parent = rules::deck(s, "A");
        let deck = rules::deck(s, "A::B");
        let log = rules::imported_revlog(&card, 1_650_000_000_123);
        let anchor = rules::import_anchor(&card2, 1_650_000_000_999);
        [
            nt, field, tpl, tpl2, note, card, card2, parent, deck, log, anchor,
        ]
    };
    let [
        nt,
        field,
        tpl,
        tpl2,
        note,
        card,
        card2,
        parent,
        deck,
        log,
        anchor,
    ] = at(salt);
    let salts: Vec<&str> = salt.into_iter().collect();
    let mut ev = evidence(&salts);
    ev.note_types.push(NoteTypeEv {
        id: nt,
        anki_num: Some(1_600_000_000_001),
        cloze: false,
        fields: vec![def_num(field, 5)],
        templates: vec![def_num(tpl, 7), def_name(tpl2, "Card 2")],
    });
    ev.notes.push(NoteEv {
        id: note,
        guid: Some("guid-1".to_owned()),
        note_types: vec![nt],
        cloze_ords: Vec::new(),
    });
    ev.cards = vec![card, card2];
    ev.decks.push(DeckEv {
        id: parent,
        names: vec!["A".to_owned()],
        parents: Vec::new(),
    });
    ev.decks.push(DeckEv {
        id: deck,
        names: vec!["B".to_owned()],
        parents: vec![parent],
    });
    ev.logs.push(LogEv {
        id: log,
        card,
        anki_revlog_id: Some(1_650_000_000_123),
        anchor_at: None,
        revokes: None,
    });
    ev.logs.push(LogEv {
        id: anchor,
        card: card2,
        anki_revlog_id: None,
        anchor_at: Some(1_650_000_000_999),
        revokes: None,
    });
    let pairs = at(salt).into_iter().zip(at(CANONICAL)).collect();
    (ev, pairs)
}

/// 没并入过的单盐集合：每个 ID 都验上，带盐 ID 与规范 ID 一一对应。
#[test]
fn a_single_salt_collection_maps_one_to_one() {
    let (ev, pairs) = small_collection(Some(U1));
    let a = resolve(&ev, &Limits::default());
    let mut canon: BTreeSet<Id> = BTreeSet::new();
    for (i, (id, want)) in pairs.iter().enumerate() {
        assert_eq!(a.canonical(id), *want, "#{i}");
        assert_ne!(id, want, "#{i}");
        assert!(
            matches!(a.how(id), How::Salted { .. } | How::Derived),
            "#{i}"
        );
        // 规范 ID 再归一还是它自己。
        assert_eq!(a.canonical(want), *want, "#{i}");
        canon.insert(*want);
    }
    assert_eq!(canon.len(), pairs.len());
    assert_eq!(a.how(&pairs[0].0), S1);
    assert_eq!(a.how(&pairs[4].0), S1);
    assert_eq!(a.how(&pairs[8].0), S1);
    assert_eq!(a.how(&pairs[1].0), How::Derived);
    assert_eq!(a.conflicts(), 0);
    assert_eq!(a.salts(), [U1.to_owned()]);
}

/// 已经是规范 ID 的集合（协议 4 之后新建的）：一个都不变，有没有盐都一样。
#[test]
fn a_canonical_collection_is_left_alone() {
    let none: &[&str] = &[];
    for salts in [none, &[U1, U2]] {
        let (mut ev, pairs) = small_collection(CANONICAL);
        ev.salts = salts.iter().map(|s| (*s).to_owned()).collect();
        let a = resolve(&ev, &Limits::default());
        for (i, (id, want)) in pairs.iter().enumerate() {
            assert_eq!(id, want);
            assert_eq!(a.canonical(id), *id, "#{i}");
            assert!(matches!(a.how(id), How::Canonical | How::Derived), "#{i}");
        }
        assert_eq!(a.conflicts(), 0);
    }
}

/// 验不上的 ID 规范 ID 是它自己，原因分得开。
#[test]
fn unverifiable_ids_stay_themselves() {
    let (mut ev, _) = small_collection(Some(U1));
    let nt = ev.note_types[0].id;
    // U2 不在盐集合里：按它派生的 ID 一律验不上。
    let wrong_guid = rules::note(Some(U2), "guid-x");
    let no_guid = v7(1);
    let wrong_nt = rules::note_type(Some(U2), 42);
    let no_num_nt = v7(2);
    let keyless_def = v7(3);
    let stray_def = stray("def");
    let nameless_deck = v7(4);
    let stray_deck = rules::deck(Some(U2), "Elsewhere");
    let random_log = v7(5);
    let stray_log = stray("log");
    let stray_card = stray("card");
    let other = stray("other");
    ev.notes.push(NoteEv {
        id: wrong_guid,
        guid: Some("guid-x".to_owned()),
        note_types: vec![nt],
        cloze_ords: Vec::new(),
    });
    ev.notes.push(NoteEv {
        id: no_guid,
        guid: None,
        note_types: vec![nt],
        cloze_ords: Vec::new(),
    });
    ev.note_types.push(NoteTypeEv {
        id: wrong_nt,
        anki_num: Some(42),
        ..NoteTypeEv::default()
    });
    ev.note_types.push(NoteTypeEv {
        id: no_num_nt,
        anki_num: None,
        fields: vec![
            DefEv {
                id: keyless_def,
                ..DefEv::default()
            },
            def_num(stray_def, 9),
        ],
        ..NoteTypeEv::default()
    });
    ev.decks.push(DeckEv {
        id: nameless_deck,
        ..DeckEv::default()
    });
    ev.decks.push(DeckEv {
        id: stray_deck,
        names: vec!["Elsewhere".to_owned()],
        parents: Vec::new(),
    });
    ev.logs.push(LogEv {
        id: random_log,
        card: stray_card,
        ..LogEv::default()
    });
    ev.logs.push(LogEv {
        id: stray_log,
        card: stray_card,
        anki_revlog_id: Some(77),
        anchor_at: None,
        revokes: None,
    });
    ev.other_ids.push(other);
    let a = resolve(&ev, &Limits::default());
    for (id, why) in [
        (wrong_guid, Why::NoMatch),
        (no_guid, Why::NoNaturalKey),
        (wrong_nt, Why::NoMatch),
        (no_num_nt, Why::NoNaturalKey),
        (keyless_def, Why::NoNaturalKey),
        (stray_def, Why::NoMatch),
        (nameless_deck, Why::NoNaturalKey),
        (stray_deck, Why::NoMatch),
        (random_log, Why::NotDerived),
        (stray_log, Why::NoMatch),
        (stray_card, Why::NoMatch),
        (other, Why::NoMatch),
    ] {
        assert_eq!(a.canonical(&id), id, "{why:?}");
        assert_eq!(a.how(&id), How::Unverified(why), "{id}");
    }
    // 证据里没出现过的 ID。
    let never = stray("never");
    assert_eq!(a.canonical(&never), never);
    assert_eq!(a.how(&never), How::Unknown);
    assert_eq!(a.conflicts(), 0);
}

/// 父 ID 验不上不拖累子 ID：卡按「笔记原样 + 规范模板」重算，导入日志按规范卡重算。
#[test]
fn children_of_unverified_parents_follow_the_verified_part() {
    let (mut ev, pairs) = small_collection(Some(U1));
    let (tpl, tpl_canonical) = pairs[2];
    let nt = pairs[0].0;
    let note = v7(9);
    let card = rules::card(&note, &tpl, 0);
    let log = rules::imported_revlog(&card, 5);
    ev.notes.push(NoteEv {
        id: note,
        guid: None,
        note_types: vec![nt],
        cloze_ords: Vec::new(),
    });
    ev.logs.push(LogEv {
        id: log,
        card,
        anki_revlog_id: Some(5),
        anchor_at: None,
        revokes: None,
    });
    let a = resolve(&ev, &Limits::default());
    let want = rules::card(&note, &tpl_canonical, 0);
    assert_eq!(a.canonical(&note), note);
    assert_eq!(a.canonical(&card), want);
    assert_eq!(a.how(&card), How::Derived);
    assert_eq!(a.canonical(&log), rules::imported_revlog(&want, 5));
}

/// 旧并入的兜底卡：原 ID（另一个 uid 下的卡）不在集合里，但能由「自然键 × 盐」算出来。
/// 原件与兜底副本归到同一个规范卡；只认集合里出现过的 ID 的对照模式下验不上。
#[test]
fn merge_fallback_of_an_id_that_is_no_longer_in_the_collection() {
    let (mut ev, pairs) = small_collection(Some(U1));
    ev.salts.push(U2.to_owned());
    let nt2 = rules::note_type(Some(U2), 1_600_000_000_001);
    let gone = rules::card(
        &rules::note(Some(U2), "guid-1"),
        &rules::template(&nt2, 7),
        0,
    );
    let fallback = rules::merge_fallback(U1, &gone.text());
    let log = rules::imported_revlog(&fallback, 1_650_000_000_123);
    ev.cards.push(fallback);
    ev.logs.push(LogEv {
        id: log,
        card: fallback,
        anki_revlog_id: Some(1_650_000_000_123),
        anchor_at: None,
        revokes: None,
    });
    let (card, card_canonical) = pairs[5];
    let (log1, log_canonical) = pairs[9];

    let a = resolve(&ev, &Limits::default());
    assert_eq!(a.canonical(&fallback), card_canonical);
    assert_eq!(a.how(&fallback), How::Fallback { salt: 0 });
    assert_eq!(a.canonical(&card), card_canonical);
    // 两张卡上同一条 Anki 日志归一后是同一个 ID。
    assert_eq!(a.canonical(&log), log_canonical);
    assert_eq!(a.canonical(&log1), log_canonical);
    // 候选卡不进表（只与观察到的 ID 求交）：没观察到的原 ID 自己查不到。
    assert_eq!(a.how(&gone), How::Unknown);
    assert_eq!(a.conflicts(), 0);

    let strict = Limits {
        virtual_aliases: false,
        ..Limits::default()
    };
    let b = resolve(&ev, &strict);
    assert_eq!(b.canonical(&fallback), fallback);
    assert_eq!(b.how(&fallback), How::Unverified(Why::NoMatch));
    assert_eq!(b.canonical(&card), card_canonical);
    assert_eq!(b.canonical(&log), log);
}

/// 兜底 ID 的原 ID 在集合里（观察到的）时，两种模式都认；链式并入（兜底的兜底）一路归到头；
/// 日志的兜底 ID 跟着日志自己的规范 ID 走（日志的规范 ID 要等卡定了才算得出）。
#[test]
fn merge_fallback_chains_and_observed_originals() {
    for virtual_aliases in [true, false] {
        let (mut ev, pairs) = small_collection(Some(U1));
        ev.salts.push(U2.to_owned());
        let (card, card_canonical) = pairs[5];
        let (log, log_canonical) = pairs[9];
        let (note, note_canonical) = pairs[4];
        let f1 = rules::merge_fallback(U2, &card.text());
        let f2 = rules::merge_fallback(U1, &f1.text());
        let log_fallback = rules::merge_fallback(U2, &log.text());
        let note_fallback = rules::merge_fallback(U2, &note.text());
        // 兜底笔记上的卡：笔记的别名变多之后才枚举得到。
        let card_of_fallback_note = rules::card(&note_fallback, &pairs[2].0, 0);
        // 大写的原 ID 文本算出来是同一个兜底 ID（旧并入先转小写）。
        assert_eq!(rules::merge_fallback(U2, &card.text().to_uppercase()), f1);
        ev.cards.extend([f1, f2, card_of_fallback_note]);
        ev.logs.push(LogEv {
            id: log_fallback,
            card: f1,
            anki_revlog_id: None,
            anchor_at: None,
            revokes: None,
        });
        ev.other_ids.push(note_fallback);
        let limits = Limits {
            virtual_aliases,
            ..Limits::default()
        };
        let a = resolve(&ev, &limits);
        assert_eq!(a.canonical(&f1), card_canonical);
        assert_eq!(a.canonical(&f2), card_canonical);
        assert_eq!(a.how(&f1), How::Fallback { salt: 1 });
        assert_eq!(a.how(&f2), How::Fallback { salt: 0 });
        assert_eq!(a.canonical(&log_fallback), log_canonical);
        assert_eq!(a.canonical(&note_fallback), note_canonical);
        assert_eq!(a.canonical(&card_of_fallback_note), card_canonical);
        assert!(a.rounds() >= 2);
        assert_eq!(a.conflicts(), 0);
    }
}

/// 牌组：改过名、挪过父牌组、建的时候是顶层、备选序号、内置默认牌组。
#[test]
fn decks_verify_against_their_name_and_parent_history() {
    let mut ev = evidence(&[U1]);
    let parent = rules::deck(Some(U1), "P");
    let old_parent = rules::deck(Some(U1), "Q");
    let renamed = rules::deck(Some(U1), "Old");
    let moved = rules::deck(Some(U1), "Q::M");
    let born_top = rules::deck(Some(U1), "T");
    let alternate = rules::deck_alternate(Some(U1), "P::Dup", 3);
    let too_far = rules::deck_alternate(Some(U1), "P::Far", 9);
    let default = rules::builtin_default_deck(Some(U1));
    let untrimmed = rules::deck(Some(U1), "P::X");
    for (id, names, parents) in [
        (parent, vec!["P"], vec![]),
        (old_parent, vec!["Q"], vec![]),
        (renamed, vec!["New", "Old"], vec![]),
        (moved, vec!["M"], vec![parent, old_parent]),
        (born_top, vec!["T"], vec![parent]),
        (alternate, vec!["Dup"], vec![parent]),
        (too_far, vec!["Far"], vec![parent]),
        (default, vec!["Default"], vec![]),
        (untrimmed, vec![" X "], vec![parent]),
    ] {
        ev.decks.push(DeckEv {
            id,
            names: names.into_iter().map(str::to_owned).collect(),
            parents,
        });
    }
    let a = resolve(&ev, &Limits::default());
    assert_eq!(a.canonical(&renamed), rules::deck(CANONICAL, "Old"));
    assert_eq!(a.canonical(&moved), rules::deck(CANONICAL, "Q::M"));
    assert_eq!(a.canonical(&born_top), rules::deck(CANONICAL, "T"));
    assert_eq!(
        a.canonical(&alternate),
        rules::deck_alternate(CANONICAL, "P::Dup", 3)
    );
    assert_eq!(a.canonical(&too_far), too_far);
    assert_eq!(a.how(&too_far), How::Unverified(Why::NoMatch));
    assert_eq!(
        a.canonical(&default),
        rules::builtin_default_deck(CANONICAL)
    );
    assert_eq!(a.canonical(&untrimmed), rules::deck(CANONICAL, "P::X"));
    // 证据里没有牌组时，内置默认牌组的带盐值也认（卡的 deck 寄存器里会引用它）。
    let b = resolve(&evidence(&[U1]), &Limits::default());
    assert_eq!(
        b.canonical(&default),
        rules::builtin_default_deck(CANONICAL)
    );
    assert_eq!(b.how(&default), S1);

    // 候选全名超过上限：不枚举，按验不上处理。
    let tight = Limits {
        deck_paths: 1,
        ..Limits::default()
    };
    let c = resolve(&ev, &tight);
    assert_eq!(c.canonical(&moved), moved);
    assert_eq!(c.how(&moved), How::Unverified(Why::TooManyCandidates));
    assert_eq!(c.canonical(&parent), rules::deck(CANONICAL, "P"));
}

/// 互为父牌组的坏数据不会转不出来。
#[test]
fn deck_parent_cycles_terminate() {
    let mut ev = evidence(&[U1]);
    let a_id = rules::deck(Some(U1), "B::A");
    let b_id = rules::deck(Some(U1), "B");
    ev.decks.push(DeckEv {
        id: a_id,
        names: vec!["A".to_owned()],
        parents: vec![b_id, a_id],
    });
    ev.decks.push(DeckEv {
        id: b_id,
        names: vec!["B".to_owned()],
        parents: vec![a_id],
    });
    let a = resolve(&ev, &Limits::default());
    assert_eq!(a.canonical(&a_id), rules::deck(CANONICAL, "B::A"));
    assert_eq!(a.canonical(&b_id), rules::deck(CANONICAL, "B"));
}

/// 按号与按名派生的定义是两个不同的 ID、两个不同的规范 ID：别名判定不把它们并成一个。
#[test]
fn definitions_by_number_and_by_name_do_not_merge() {
    let mut ev = evidence(&[U1]);
    let nt = rules::note_type(Some(U1), 77);
    let by_num = rules::field(&nt, 5);
    let by_name = rules::field_by_name(&nt, "Front");
    // 这个定义的 ankiNum 史里有两个值：建的时候是 5。
    let renumbered = rules::template(&nt, 5);
    ev.note_types.push(NoteTypeEv {
        id: nt,
        anki_num: Some(77),
        cloze: false,
        fields: vec![
            DefEv {
                id: by_num,
                anki_nums: vec![5],
                names: vec!["Front".to_owned()],
            },
            def_name(by_name, "Front"),
        ],
        templates: vec![DefEv {
            id: renumbered,
            anki_nums: vec![6, 5],
            names: Vec::new(),
        }],
    });
    let a = resolve(&ev, &Limits::default());
    let c = rules::note_type(CANONICAL, 77);
    assert_eq!(a.canonical(&by_num), rules::field(&c, 5));
    assert_eq!(a.canonical(&by_name), rules::field_by_name(&c, "Front"));
    assert_ne!(a.canonical(&by_num), a.canonical(&by_name));
    assert_eq!(a.canonical(&renumbered), rules::template(&c, 5));
    assert_eq!(a.conflicts(), 0);
}

/// 填空类型的卡序号枚举到上限；普通类型只有 0；笔记换过类型时两个类型的模板都试。
#[test]
fn cards_enumerate_cloze_ordinals_and_note_type_history() {
    let mut ev = evidence(&[U1]);
    let cloze = rules::note_type(Some(U1), 1);
    let basic = rules::note_type(Some(U1), 2);
    let cloze_tpl = rules::template(&cloze, 10);
    let basic_tpl = rules::template(&basic, 20);
    for (id, n, is_cloze, tpl, tn) in [
        (cloze, 1, true, cloze_tpl, 10),
        (basic, 2, false, basic_tpl, 20),
    ] {
        ev.note_types.push(NoteTypeEv {
            id,
            anki_num: Some(n),
            cloze: is_cloze,
            fields: Vec::new(),
            templates: vec![def_num(tpl, tn)],
        });
    }
    let note = rules::note(Some(U1), "g");
    let plain = rules::note(Some(U1), "h");
    ev.notes.push(NoteEv {
        id: note,
        guid: Some("g".to_owned()),
        note_types: vec![basic, cloze],
        // 上限之外的序号由证据给（这条笔记的字段史里出现过 c777）。
        cloze_ords: vec![777],
    });
    ev.notes.push(NoteEv {
        id: plain,
        guid: Some("h".to_owned()),
        note_types: vec![basic],
        cloze_ords: Vec::new(),
    });
    let ord37 = rules::card(&note, &cloze_tpl, 37);
    let on_basic = rules::card(&note, &basic_tpl, 0);
    let basic_ord1 = rules::card(&plain, &basic_tpl, 1);
    let beyond = rules::card(&note, &cloze_tpl, 60);
    // 这条笔记没用过填空类型：它的模板不试。
    let never_that_type = rules::card(&plain, &cloze_tpl, 0);
    let far = rules::card(&note, &cloze_tpl, 777);
    ev.cards = vec![ord37, on_basic, basic_ord1, beyond, never_that_type, far];
    let limits = Limits {
        cloze_ords: 50,
        ..Limits::default()
    };
    let a = resolve(&ev, &limits);
    let (cn, cc, cb) = (
        rules::note(CANONICAL, "g"),
        rules::note_type(CANONICAL, 1),
        rules::note_type(CANONICAL, 2),
    );
    assert_eq!(
        a.canonical(&ord37),
        rules::card(&cn, &rules::template(&cc, 10), 37)
    );
    assert_eq!(
        a.canonical(&on_basic),
        rules::card(&cn, &rules::template(&cb, 20), 0)
    );
    assert_eq!(
        a.canonical(&far),
        rules::card(&cn, &rules::template(&cc, 10), 777)
    );
    for id in [basic_ord1, beyond, never_that_type] {
        assert_eq!(a.canonical(&id), id);
        assert_eq!(a.how(&id), How::Unverified(Why::NoMatch));
    }
}

/// 内置笔记类型不靠证据：它的字段 / 模板在每个盐下的 ID 都认（偏好与 `f/<字段>` 键里引用的就是这些）。
#[test]
fn builtin_note_types_are_known_without_evidence() {
    let mut ev = evidence(&[U1, U2]);
    ev.builtins.push(BuiltinNoteType {
        key: "lapis".to_owned(),
        field_seeds: vec!["Expression".to_owned()],
        template_keys: vec!["Card 1".to_owned()],
    });
    let n = rules::builtin_note_type_anki_num("lapis");
    let f = rules::builtin_field_anki_num("lapis", "Expression");
    let t = rules::builtin_template_anki_num("lapis", "Card 1");
    let canonical = rules::note_type(CANONICAL, n);
    let a = resolve(&ev, &Limits::default());
    for (i, uid) in [U1, U2].into_iter().enumerate() {
        let nt = rules::note_type(Some(uid), n);
        assert_eq!(a.canonical(&nt), canonical);
        assert_eq!(a.how(&nt), How::Salted { salt: i as u16 });
        assert_eq!(
            a.canonical(&rules::field(&nt, f)),
            rules::field(&canonical, f)
        );
        assert_eq!(
            a.canonical(&rules::template(&nt, t)),
            rules::template(&canonical, t)
        );
    }
    // 只认集合里出现过的 ID 的对照模式下，没观察到的就不认。
    let strict = Limits {
        virtual_aliases: false,
        ..Limits::default()
    };
    let b = resolve(&ev, &strict);
    assert_eq!(b.how(&rules::note_type(Some(U1), n)), How::Unknown);
    assert_eq!(b.how(&canonical), How::Canonical);
}

/// profile 级设置实体：存量 ID 是 uid 本身，每个盐都归到同一个规范实体。
#[test]
fn profile_entities_collapse_onto_one_id() {
    let mut ev = evidence(&[U1, U2, "not-a-uuid"]);
    ev.other_ids.push(Id::parse(U1).unwrap());
    let a = resolve(&ev, &Limits::default());
    for uid in [U1, U2] {
        assert_eq!(
            a.canonical(&Id::parse(uid).unwrap()),
            rules::profile_entity()
        );
    }
    assert_eq!(a.how(&Id::parse(U2).unwrap()), How::Salted { salt: 1 });
    assert_eq!(a.how(&rules::profile_entity()), How::Canonical);
}

fn merged_name(uid: &str, origin: &str) -> String {
    format!("merged-{}", rules::merged_writer_hash(uid, origin).text())
}

/// 一个写入者名下 seq = `seqs` 的记录；戳由 (stream, seq) 决定：同一个 stream 的同一个 seq 是同一条记录。
fn writer(name: &str, stream: i64, seqs: std::ops::RangeInclusive<u64>) -> WriterEv {
    WriterEv {
        name: name.to_owned(),
        dots: seqs
            .map(|seq| Dot {
                seq,
                physical: 1_700_000_000_000 + stream * 1_000_000 + seq as i64,
                counter: 0,
            })
            .collect(),
    }
}

/// 只在 HLC / 旧上下文里出现过、名下没有记录的写入者。
fn bare_writer(name: &str) -> WriterEv {
    WriterEv {
        name: name.to_owned(),
        dots: Vec::new(),
    }
}

/// 旧并入改名的写入者：哈希验上、且与最初的写入者有同 seq 的同一条记录才归过去。
#[test]
fn merged_writers_need_the_hash_and_a_shared_record() {
    let dev = "01928c3e-1111-7000-8000-00000000d001";
    // 旧格式：原件（另一台还在旧 uid 上的设备带来的）与并入的副本都在，副本是原件的一段。
    let old = merged_name(U1, "abcDEF#1");
    // 新格式：名字里带着最初的写入者。
    let tagged = format!("{}~{dev}", merged_name(U1, dev));
    // 名字里带的不是算出哈希的那个名字。
    let lying = format!("{}~{dev}", merged_name(U1, "someone-else"));
    // 最初的写入者没在集合里出现过。
    let orphan = merged_name(U1, "never-seen");
    // 目标 uid 不在盐集合里。
    let other_salt = merged_name(U2, "abcDEF#1");
    // 并入过两次：abcDEF#2 → merged-A → merged-B，中间的名字还在。
    let twice_inner = merged_name(U1, "abcDEF#2");
    let twice = merged_name(U1, &twice_inner);
    // 并入过两次，中间的名字不在集合里。
    let skipped = merged_name(U1, &merged_name(U1, "abcDEF#3"));
    let synthetic_origin = merged_name(U1, "sync2:tags:x");
    let mut ev = evidence(&[U1]);
    ev.writers = vec![
        writer("abcDEF#1", 1, 1..=50),
        writer(&old, 1, 10..=20),
        writer(dev, 2, 1..=5),
        writer(&tagged, 2, 3..=9),
        writer(&lying, 2, 1..=5),
        writer(&orphan, 3, 1..=5),
        writer(&other_salt, 1, 1..=5),
        writer("abcDEF#2", 4, 1..=30),
        writer(&twice_inner, 4, 5..=6),
        writer(&twice, 4, 6..=7),
        writer("abcDEF#3", 5, 1..=3),
        writer(&skipped, 5, 2..=2),
        writer("sync2:tags:x", 6, 1..=3),
        writer(&synthetic_origin, 6, 1..=3),
        writer("merged-not-a-hash", 7, 1..=1),
        writer("merged-", 7, 1..=1),
        writer("plain", 7, 1..=1),
    ];
    let a = resolve(&ev, &Limits::default());
    assert_eq!(a.canonical_writer(&old), "abcDEF#1");
    assert_eq!(a.canonical_writer(&tagged), dev);
    assert_eq!(a.canonical_writer(&twice), "abcDEF#2");
    assert_eq!(a.canonical_writer(&twice_inner), "abcDEF#2");
    assert_eq!(a.canonical_writer(&skipped), "abcDEF#3");
    for w in [&old, &tagged, &twice, &twice_inner, &skipped] {
        assert_eq!(a.writer_how(w), WriterHow::Resolved);
    }
    for w in [&lying, &orphan, &other_salt, &synthetic_origin] {
        assert_eq!(a.canonical_writer(w), w.as_str());
        assert_eq!(a.writer_how(w), WriterHow::Unverified);
        assert_eq!(a.writer_origin(w), None);
    }
    for w in [
        "abcDEF#1",
        "merged-not-a-hash",
        "merged-",
        "plain",
        "nobody",
    ] {
        assert_eq!(a.canonical_writer(w), w);
        assert_eq!(a.writer_how(w), WriterHow::Plain);
    }
    assert_eq!(a.merged_writers().len(), 5);

    // 修改记录的 ID：确实是 (写入者, seq) 派生的才跟着写入者换；否则不动。
    let id = rules::field_edit(&old, 12);
    assert_eq!(
        a.canonical_edit(&id, &old, 12),
        rules::field_edit("abcDEF#1", 12)
    );
    assert_eq!(a.canonical_edit(&id, &old, 13), id);
    let orphan_edit = rules::field_edit(&orphan, 1);
    assert_eq!(a.canonical_edit(&orphan_edit, &orphan, 1), orphan_edit);
    let random = v7(1);
    assert_eq!(a.canonical_edit(&random, &old, 12), random);

    // 追链的跳数有上限。
    let one_hop = Limits {
        writer_hops: 1,
        ..Limits::default()
    };
    let b = resolve(&ev, &one_hop);
    assert_eq!(b.writer_how(&skipped), WriterHow::Unverified);
    assert_eq!(b.writer_how(&twice), WriterHow::Resolved);
}

/// 哈希验上不等于是同一套 seq：v1 的写入者名是「设备#代次」，序号按 profile 记，同一个名字在两个 uid 下
/// 各数各的。同 seq 上是另一条记录的不归（归了就是两条不同的修改记录同 dot）；没有一条记录对得上的也不归。
#[test]
fn merged_writers_with_another_seq_space_stay_themselves() {
    // 副本的 seq 1..=40 与同名写入者在目标 uid 下自己的 seq 1..=50 撞上，但不是同一批记录。
    let clash = merged_name(U1, "dev#1");
    // 最初的写入者只在别人的旧上下文里出现过，名下没有记录。
    let no_records = merged_name(U1, "dev#2");
    // 两边都有记录，但没有一个 seq 重合。
    let apart = merged_name(U1, "dev#3");
    // 自己没有记录的改名写入者（只在 HLC / 旧上下文里出现）。
    let bare = merged_name(U1, "dev#4");
    // 同一个最初写入者的两份副本：一份对得上，另一份有一个 seq 是另一条记录。
    let good = merged_name(U1, "dev#5");
    let bad = merged_name(U2, "dev#5");
    let mut ev = evidence(&[U1, U2]);
    ev.writers = vec![
        writer("dev#1", 1, 1..=50),
        writer(&clash, 2, 1..=40),
        bare_writer("dev#2"),
        writer(&no_records, 3, 1..=5),
        writer("dev#3", 4, 1..=5),
        writer(&apart, 4, 6..=9),
        writer("dev#4", 5, 1..=5),
        bare_writer(&bare),
        writer("dev#5", 6, 1..=9),
        writer(&good, 6, 2..=4),
        writer(&bad, 6, 4..=6),
        writer(&bad, 7, 7..=7),
        // 候选名字给两次、记录分两批给：按并集算。
        writer(&clash, 2, 41..=45),
    ];
    // dev#5 的 seq 7 是 stream 6 的记录，bad 的 seq 7 是 stream 7 的。
    let a = resolve(&ev, &Limits::default());
    for (w, how, origin) in [
        (&clash, WriterHow::DotsDiffer, "dev#1"),
        (&no_records, WriterHow::Unproven, "dev#2"),
        (&apart, WriterHow::Unproven, "dev#3"),
        (&bare, WriterHow::Unproven, "dev#4"),
        (&bad, WriterHow::DotsDiffer, "dev#5"),
    ] {
        assert_eq!(a.writer_how(w), how, "{origin}");
        assert_eq!(a.writer_origin(w), Some(origin));
        assert_eq!(a.canonical_writer(w), w.as_str());
        let id = rules::field_edit(w, 1);
        assert_eq!(a.canonical_edit(&id, w, 1), id);
    }
    assert_eq!(a.writer_how(&good), WriterHow::Resolved);
    assert_eq!(a.canonical_writer(&good), "dev#5");
    assert_eq!(a.merged_writers(), [(good.as_str(), "dev#5")]);

    // 只当候选给的名字（设备 ID 之类）能认出「是从谁改来的」，但它名下没有记录，不够归过去。
    let hinted = merged_name(U1, "dev#9");
    let mut ev = evidence(&[U1]);
    ev.writers = vec![writer(&hinted, 1, 1..=3)];
    assert_eq!(
        resolve(&ev, &Limits::default()).writer_how(&hinted),
        WriterHow::Unverified
    );
    ev.writer_hints = vec!["dev#9".to_owned()];
    let b = resolve(&ev, &Limits::default());
    assert_eq!(b.writer_how(&hinted), WriterHow::Unproven);
    assert_eq!(b.writer_origin(&hinted), Some("dev#9"));
}

/// 给事件副本补的 undo：ID 只由它点名的日志派生，点名的日志归一了它也跟着重算。
#[test]
fn copy_repair_undos_follow_the_log_they_name() {
    let (mut ev, pairs) = small_collection(Some(U1));
    let (log, log_canonical) = pairs[9];
    let native = v7(7);
    let undo = rules::copy_repair_undo(&log);
    let undo_of_native = rules::copy_repair_undo(&native);
    let plain_undo = v7(8);
    assert_eq!(
        crate::store::sync2::copy_repair_undo_id(&log.text()),
        Key::Uuid(undo)
    );
    for (id, target) in [(undo, log), (undo_of_native, native), (plain_undo, log)] {
        ev.logs.push(LogEv {
            id,
            card: pairs[5].0,
            revokes: Some(target),
            ..LogEv::default()
        });
    }
    let a = resolve(&ev, &Limits::default());
    assert_eq!(a.canonical(&undo), rules::copy_repair_undo(&log_canonical));
    assert_eq!(a.how(&undo), How::Derived);
    assert_eq!(a.canonical(&undo_of_native), undo_of_native);
    assert_eq!(a.how(&undo_of_native), How::Derived);
    assert_eq!(a.how(&plain_undo), How::Unverified(Why::NotDerived));
    // 只被 undo 点名、别处没出现过的日志也算观察到的。
    assert_eq!(a.how(&native), How::Unverified(Why::NotDerived));
}

/// 同一个 ID 的多条证据取并集：一条缺自然键、另一条有，或者两条给了不同的自然键，都按「有一个验得上就验上」。
#[test]
fn evidence_about_the_same_id_is_merged() {
    let (mut ev, pairs) = small_collection(Some(U1));
    let (note, note_canonical) = pairs[4];
    let (nt, nt_canonical) = pairs[0];
    ev.notes.insert(
        0,
        NoteEv {
            id: note,
            guid: None,
            ..NoteEv::default()
        },
    );
    ev.notes.push(NoteEv {
        id: note,
        guid: Some("some-other-guid".to_owned()),
        ..NoteEv::default()
    });
    ev.note_types.insert(
        0,
        NoteTypeEv {
            id: nt,
            anki_num: None,
            fields: vec![DefEv {
                id: pairs[1].0,
                ..DefEv::default()
            }],
            ..NoteTypeEv::default()
        },
    );
    ev.note_types.push(NoteTypeEv {
        id: nt,
        anki_num: Some(99),
        ..NoteTypeEv::default()
    });
    let a = resolve(&ev, &Limits::default());
    assert_eq!(a.canonical(&note), note_canonical);
    assert_eq!(a.canonical(&nt), nt_canonical);
    for (id, want) in &pairs {
        assert_eq!(a.canonical(id), *want);
    }
    assert_eq!(a.conflicts(), 0);
}

/// 只认规范形状的 UUID 文本：大写、无连字符的在存储层是另一个值，不能解析成同一个 ID。
#[test]
fn only_canonical_uuid_text_is_an_id() {
    let text = "7cb0b0f1-fee9-52a0-971a-9bbe263d021d";
    assert_eq!(strict_id(text), Id::parse(text));
    assert!(strict_id(text).is_some());
    assert_eq!(strict_id(&text.to_uppercase()), None);
    assert_eq!(strict_id(&text.replace('-', "")), None);
    assert_eq!(strict_id("Deck-Default"), None);
    assert_eq!(strict_id(""), None);
}

fn shuffle<T>(v: &mut [T], state: &mut u64) {
    for i in (1..v.len()).rev() {
        *state ^= *state << 13;
        *state ^= *state >> 7;
        *state ^= *state << 17;
        v.swap(i, (*state % (i as u64 + 1)) as usize);
    }
}

/// 两个盐下各一份、规范 ID 下一份的同一个小集合，加上兜底 ID（原 ID 在 / 不在集合里、链式、日志的）、
/// 验不上的 ID、改过名的写入者。
fn mixed_collection() -> Evidence {
    let (mut ev, _) = small_collection(Some(U1));
    let (other, _) = small_collection(Some(U2));
    let (plain, _) = small_collection(CANONICAL);
    ev.salts.push(U2.to_owned());
    for e in [other, plain] {
        ev.note_types.extend(e.note_types);
        ev.notes.extend(e.notes);
        ev.decks.extend(e.decks);
        ev.cards.extend(e.cards);
        ev.logs.extend(e.logs);
    }
    let card = ev.cards[0];
    let gone = rules::card(
        &rules::note(Some(U2), "guid-9"),
        &rules::template(&rules::note_type(Some(U2), 1_600_000_000_001), 7),
        0,
    );
    ev.notes.push(NoteEv {
        id: rules::note(Some(U1), "guid-9"),
        guid: Some("guid-9".to_owned()),
        note_types: vec![ev.note_types[0].id],
        cloze_ords: Vec::new(),
    });
    let f1 = rules::merge_fallback(U1, &card.text());
    let f2 = rules::merge_fallback(U2, &f1.text());
    ev.cards
        .extend([f1, f2, rules::merge_fallback(U1, &gone.text()), stray("c")]);
    ev.logs.push(LogEv {
        id: rules::merge_fallback(U1, &ev.logs[0].id.text()),
        card: f1,
        anki_revlog_id: None,
        anchor_at: None,
        revokes: None,
    });
    ev.logs.push(LogEv {
        id: Id::new_v7(1_700_000_000_003),
        card: f2,
        anki_revlog_id: None,
        anchor_at: None,
        revokes: None,
    });
    ev.other_ids.push(Id::parse(U2).unwrap());
    ev.writers = vec![
        writer("w#1", 1, 1..=9),
        writer(&merged_name(U2, "w#1"), 1, 3..=5),
        writer(&merged_name(U1, "w#2"), 1, 1..=2),
    ];
    ev
}

fn observed_ids(ev: &Evidence) -> BTreeSet<Id> {
    let mut ids: BTreeSet<Id> = BTreeSet::new();
    for t in &ev.note_types {
        ids.insert(t.id);
        ids.extend(t.fields.iter().chain(&t.templates).map(|d| d.id));
    }
    ids.extend(ev.notes.iter().map(|n| n.id));
    ids.extend(ev.decks.iter().map(|d| d.id));
    ids.extend(ev.cards.iter().copied());
    ids.extend(ev.logs.iter().flat_map(|l| [l.id, l.card]));
    ids.extend(ev.other_ids.iter().copied());
    ids
}

/// 结果只由证据的内容决定：各项乱序、重复都不改变任何一个 ID 的规范 ID 与认法；归一是幂等的。
#[test]
fn the_result_does_not_depend_on_evidence_order() {
    let base = mixed_collection();
    let ids = observed_ids(&base);
    for virtual_aliases in [true, false] {
        let limits = Limits {
            virtual_aliases,
            ..Limits::default()
        };
        let want = resolve(&base, &limits);
        assert_eq!(want.conflicts(), 0);
        let changed = ids.iter().filter(|id| want.canonical(id) != **id).count();
        assert!(changed > 20, "{changed}");
        for id in &ids {
            let c = want.canonical(id);
            assert_eq!(want.canonical(&c), c, "{id}");
            assert_ne!(want.how(id), How::Unknown, "{id}");
        }
        let mut state = 0x9e37_79b9_7f4a_7c15_u64;
        for round in 0..40 {
            let mut ev = base.clone();
            if round % 3 == 0 {
                // 重复的证据。
                ev.notes.extend(base.notes.iter().cloned());
                ev.note_types.extend(base.note_types.iter().cloned());
                ev.logs.extend(base.logs.iter().cloned());
                ev.cards.extend(base.cards.iter().copied());
                ev.decks.extend(base.decks.iter().cloned());
                ev.salts.extend(base.salts.iter().cloned());
                ev.writers.extend(base.writers.iter().cloned());
            }
            shuffle(&mut ev.salts, &mut state);
            shuffle(&mut ev.note_types, &mut state);
            for t in &mut ev.note_types {
                shuffle(&mut t.fields, &mut state);
                shuffle(&mut t.templates, &mut state);
            }
            shuffle(&mut ev.notes, &mut state);
            shuffle(&mut ev.decks, &mut state);
            shuffle(&mut ev.cards, &mut state);
            shuffle(&mut ev.logs, &mut state);
            shuffle(&mut ev.other_ids, &mut state);
            shuffle(&mut ev.writers, &mut state);
            let got = resolve(&ev, &limits);
            for id in &ids {
                assert_eq!(got.canonical(id), want.canonical(id), "round {round} {id}");
                assert_eq!(got.how(id), want.how(id), "round {round} {id}");
            }
            assert_eq!(got.merged_writers(), want.merged_writers());
            assert_eq!(got.len(), want.len());
            assert_eq!(got.conflicts(), 0);
        }
    }
}
