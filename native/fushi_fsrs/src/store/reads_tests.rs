//! 只读查询命令（`read` / `read_lib`，store/reads.rs）：经分发器（[crate::store::ffi::sync2_dispatch]）发真命令。

use rusqlite::params;
use serde_json::{Value, json};

use crate::store::SrsCore;
use crate::store::sync2::tests::{P, deck_entity, edit, review, tempdir};

const Q: &str = "0193a1b2-0000-7000-8000-00000000cafe";

fn open(tag: &str) -> (SrsCore, tempdir::Dir) {
    let dir = tempdir::new(tag);
    let core = SrsCore::open(&dir.0.join("srs.db")).unwrap();
    core.legacy_mark_none().unwrap();
    (core, dir)
}

/// 结果里的一格。
#[derive(Debug, Clone, PartialEq)]
enum Cell {
    I(Option<i64>),
    F(Option<f64>),
    S(Option<String>),
}

fn s(v: &str) -> Cell {
    Cell::S(Some(v.to_owned()))
}

fn i(v: i64) -> Cell {
    Cell::I(Some(v))
}

/// `FCL1`（store/bulk.rs）解码成 (列名, 各行的值)。
fn decode(b: &[u8]) -> Vec<(String, Vec<Cell>)> {
    assert_eq!(&b[0..4], b"FCL1");
    let u32_at = |at: usize| u32::from_le_bytes(b[at..at + 4].try_into().unwrap()) as usize;
    let pad = |x: usize| (x + 7) & !7;
    let (rows, cols) = (u32_at(4), u32_at(8));
    let mut at = 16;
    let mut out = Vec::new();
    for _ in 0..cols {
        let n = u32_at(at);
        let name = String::from_utf8(b[at + 4..at + 4 + n].to_vec()).unwrap();
        at = pad(at + 4 + n);
        let kind = u32_at(at);
        at += 8;
        let valid: Option<Vec<bool>> = if matches!(kind, 3 | 4 | 6) {
            let v = b[at..at + rows].iter().map(|x| *x != 0).collect();
            at = pad(at + rows);
            Some(v)
        } else {
            None
        };
        let has = |r: usize| valid.as_ref().is_none_or(|v| v[r]);
        let mut cells = Vec::with_capacity(rows);
        match kind {
            1 | 3 => {
                for r in 0..rows {
                    let v = i64::from_le_bytes(b[at + r * 8..at + r * 8 + 8].try_into().unwrap());
                    cells.push(Cell::I(has(r).then_some(v)));
                }
                at += rows * 8;
            }
            2 | 4 => {
                for r in 0..rows {
                    let v = f64::from_le_bytes(b[at + r * 8..at + r * 8 + 8].try_into().unwrap());
                    cells.push(Cell::F(has(r).then_some(v)));
                }
                at += rows * 8;
            }
            _ => {
                let total = u64::from_le_bytes(b[at..at + 8].try_into().unwrap()) as usize;
                at += 8;
                let offs: Vec<usize> = (0..=rows).map(|r| u32_at(at + r * 4)).collect();
                at = pad(at + (rows + 1) * 4);
                for r in 0..rows {
                    let t = String::from_utf8(b[at + offs[r]..at + offs[r + 1]].to_vec()).unwrap();
                    cells.push(Cell::S(has(r).then_some(t)));
                }
                at = pad(at + total);
            }
        }
        out.push((name, cells));
    }
    assert_eq!(at, b.len(), "trailing bytes");
    out
}

/// 发一条命令，返回 (回包 JSON, 各结果表)。
fn command(core: &SrsCore, req: Value) -> Result<(Value, Vec<(String, Vec<u8>)>), String> {
    let mut files = Vec::new();
    let v = crate::store::ffi::sync2_dispatch(core, &req, &mut Vec::new(), &mut files)?;
    Ok((v, files))
}

fn read(core: &SrsCore, profile: &str, q: &str, args: Value) -> (Value, Vec<(String, Vec<u8>)>) {
    let mut req = args;
    req["op"] = json!("read");
    req["profile"] = json!(profile);
    req["q"] = json!(q);
    command(core, req).unwrap()
}

/// 单表查询的一列（按行）。
fn column(core: &SrsCore, profile: &str, q: &str, args: Value, col: &str) -> Vec<Cell> {
    let (_, files) = read(core, profile, q, args);
    assert_eq!(files.len(), 1, "{q}: one table");
    assert_eq!(files[0].0, "t");
    decode(&files[0].1)
        .into_iter()
        .find(|(n, _)| n == col)
        .unwrap_or_else(|| panic!("{q}: no column {col}"))
        .1
}

fn sorted(mut v: Vec<Cell>) -> Vec<Cell> {
    v.sort_by(|a, b| format!("{a:?}").cmp(&format!("{b:?}")));
    v
}

fn note_id(profile: &str, n: usize) -> String {
    format!("N-{profile}-{n}")
}

fn card_id(profile: &str, n: usize) -> String {
    format!("C-{profile}-{n}")
}

/// 给 [profile] 落一套数据：一个牌组、两条笔记（各一条字段记录 + 一条 `notDup/` 记录）、每条笔记一张卡、第 0 张卡
/// 一条复习日志；外加笔记 / 卡片缓存行（第 1 条笔记已删、第 1 张卡隐藏）。
fn seed(core: &SrsCore, profile: &str) {
    let mut events = vec![
        (deck_entity(&format!("D-{profile}")), note_id(profile, 0)),
        (
            review(
                &format!("L-{profile}"),
                &card_id(profile, 0),
                1_700_000_000_000,
                3,
                "learn",
            ),
            note_id(profile, 0),
        ),
    ];
    for n in 0..2 {
        let note = note_id(profile, n);
        events.push((
            json!({"t": "entity", "x": {"id": note, "p": profile, "k": "note", "d": {"createdAt": 1, "guid": note, "noteType": "NT"}}}),
            note.clone(),
        ));
        events.push((
            edit("note", &note, "f/a", json!(format!("text {n}"))),
            note.clone(),
        ));
        events.push((edit("note", &note, "notDup/x", json!(true)), note.clone()));
    }
    let events: Vec<Value> = events
        .into_iter()
        .map(|(mut e, note)| {
            e["x"]["p"] = json!(profile);
            json!({"e": e, "note": note})
        })
        .collect();
    core.sync2_identity(profile, 1).unwrap();
    core.sync2_apply_local(profile, 2, &Value::Array(events).to_string())
        .unwrap();
    let w = core.writer().unwrap();
    for n in 0..2 {
        let deleted: Option<i64> = (n == 1).then_some(5);
        w.execute(
            "INSERT INTO srs_notes_cache (id, profile_uid, note_type_id, guid, created_at, deleted_at, term_key, media_refs) \
             VALUES (srs_id(?1), srs_id(?2), 'NT', ?1, ?3, ?4, 'term', ?5)",
            params![note_id(profile, n), profile, 10 + n as i64, deleted, format!("m{n}.png")],
        )
        .unwrap();
        w.execute(
            "INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, hidden, queue) \
             VALUES (srs_id(?1), srs_id(?2), srs_id(?3), 'T', srs_id(?4), ?5, 'new')",
            params![
                card_id(profile, n),
                profile,
                note_id(profile, n),
                format!("D-{profile}"),
                n as i64
            ],
        )
        .unwrap();
    }
}

/// 两个 profile 都有数据的库。
fn two_profiles(tag: &str) -> (SrsCore, tempdir::Dir) {
    let (core, dir) = open(tag);
    seed(&core, P);
    seed(&core, Q);
    (core, dir)
}

/// 每条按 profile 的查询只交回本 profile 的行；按 ID 取别的 profile 名下的 ID = 不存在（空结果）。
#[test]
fn reads_are_scoped_to_the_profile_and_foreign_ids_read_as_absent() {
    let (core, _d) = two_profiles("scope");
    let foreign_notes = json!([note_id(Q, 0), note_id(Q, 1)]);
    let foreign_cards = json!([card_id(Q, 0), card_id(Q, 1)]);

    // 身份记录：整份只有自己的；按别人的 ID 取为空。
    assert_eq!(
        sorted(column(
            &core,
            P,
            "entities",
            json!({"kind": "note", "bare": true}),
            "id"
        )),
        vec![s(&note_id(P, 0)), s(&note_id(P, 1))]
    );
    assert!(column(&core, P, "entities", json!({"ids": foreign_notes}), "id").is_empty());
    assert_eq!(
        column(
            &core,
            P,
            "entities",
            json!({"ids": [note_id(P, 0), note_id(Q, 0)]}),
            "id"
        ),
        vec![s(&note_id(P, 0))]
    );
    assert_eq!(
        read(&core, P, "entity_count", json!({"kind": "note"})).0["n"],
        json!(2)
    );
    assert_eq!(
        read(&core, P, "entity_count", json!({"limit": 1})).0["n"],
        json!(1)
    );

    // 修改记录、日志、服务器时刻、事件存在性。
    assert!(
        column(
            &core,
            P,
            "edits",
            json!({"kind": "note", "ids": foreign_notes}),
            "e"
        )
        .is_empty()
    );
    assert_eq!(
        column(
            &core,
            P,
            "edits",
            json!({"kind": "note", "ids": [note_id(P, 0)]}),
            "e"
        )
        .len(),
        2
    );
    assert!(column(&core, P, "logs", json!({"cards": foreign_cards}), "id").is_empty());
    assert_eq!(
        column(&core, P, "logs", json!({"cards": [card_id(P, 0)]}), "id"),
        vec![s(&format!("L-{P}"))]
    );
    assert_eq!(
        column(
            &core,
            P,
            "events_present",
            json!({"ids": [format!("L-{P}"), format!("L-{Q}"), "nope"], "ops": true}),
            "id"
        )
        .into_iter()
        .map(|c| format!("{c:?}"))
        .collect::<std::collections::BTreeSet<_>>()
        .len(),
        1
    );

    // 缓存行。
    assert!(column(&core, P, "cards", json!({"ids": foreign_cards}), "id").is_empty());
    assert!(column(&core, P, "cards", json!({"notes": foreign_notes}), "id").is_empty());
    assert!(
        column(
            &core,
            P,
            "cards",
            json!({"decks": [format!("D-{Q}")]}),
            "id"
        )
        .is_empty()
    );
    assert_eq!(
        sorted(column(
            &core,
            P,
            "cards",
            json!({"decks": [format!("D-{P}")]}),
            "id"
        )),
        vec![s(&card_id(P, 0)), s(&card_id(P, 1))]
    );
    assert!(column(&core, P, "notes", json!({"ids": foreign_notes}), "id").is_empty());
    assert_eq!(
        sorted(column(&core, P, "notes", json!({}), "id")),
        vec![s(&note_id(P, 0)), s(&note_id(P, 1))]
    );

    // 整份事件只有自己的。
    let (_, files) = read(&core, P, "events", json!({"ordered": true}));
    let names: Vec<&str> = files.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(names, ["entities", "edits", "logs", "unknown"]);
    let entities = decode(&files[0].1);
    assert_eq!(
        entities[0].1,
        vec![s(&format!("D-{P}")), s(&note_id(P, 0)), s(&note_id(P, 1))]
    );
    assert_eq!(decode(&files[1].1)[0].1.len(), 4);
    assert_eq!(decode(&files[2].1)[0].1.len(), 1);
    assert!(decode(&files[3].1)[0].1.is_empty());

    // 没有数据的 profile：全空。
    const NOBODY: &str = "0193a1b2-0000-7000-8000-000000000000";
    assert!(column(&core, NOBODY, "entities", json!({}), "id").is_empty());
    assert_eq!(
        read(&core, NOBODY, "entity_count", json!({})).0["n"],
        json!(0)
    );
    assert_eq!(
        read(&core, NOBODY, "has_user_data", json!({"builtins": []})).0["any"],
        json!(false)
    );
}

/// `edits` 的字段键筛选（一个键 / 一段前缀）与 `cards` / `notes` 的筛选条件。
#[test]
fn filters_select_the_same_rows_the_drift_queries_did() {
    let (core, _d) = two_profiles("filters");
    let both = json!([note_id(P, 0), note_id(P, 1)]);
    let keys = |args: Value| -> Vec<String> {
        let mut out: Vec<String> = column(&core, P, "edits", args, "j")
            .into_iter()
            .map(|c| match c {
                Cell::S(Some(j)) => serde_json::from_str::<Value>(&j).unwrap()["f"]
                    .as_str()
                    .unwrap()
                    .to_owned(),
                other => panic!("{other:?}"),
            })
            .collect();
        out.sort();
        out
    };
    assert_eq!(
        keys(json!({"kind": "note", "ids": both})),
        ["f/a", "f/a", "notDup/x", "notDup/x"]
    );
    assert_eq!(
        keys(json!({"kind": "note", "ids": both, "key": "f/a"})),
        ["f/a", "f/a"]
    );
    assert_eq!(
        keys(json!({"kind": "note", "ids": both, "prefix": "notDup/"})),
        ["notDup/x", "notDup/x"]
    );
    assert!(keys(json!({"kind": "note", "ids": both, "prefix": "notDup0"})).is_empty());
    assert!(keys(json!({"kind": "card", "ids": both})).is_empty());

    // 卡：可见 / 队列 / 模板 / 只要几列。
    assert_eq!(
        column(
            &core,
            P,
            "cards",
            json!({"visibleOnly": true, "decks": [format!("D-{P}")]}),
            "id"
        ),
        vec![s(&card_id(P, 0))]
    );
    assert_eq!(
        column(
            &core,
            P,
            "cards",
            json!({"queue": "review", "decks": [format!("D-{P}")]}),
            "id"
        ),
        Vec::<Cell>::new()
    );
    assert_eq!(
        column(
            &core,
            P,
            "cards",
            json!({"templates": ["T"], "ordered": true, "fields": ["id", "hidden"]}),
            "hidden"
        ),
        vec![i(0), i(1)]
    );
    assert_eq!(
        column(
            &core,
            P,
            "cards",
            json!({"decks": [format!("D-{P}")], "queue": "new", "studyableOn": 100, "visibleOnly": true}),
            "note_id"
        ),
        vec![s(&note_id(P, 0))]
    );
    let err = command(
        &core,
        json!({"op": "read", "profile": P, "q": "cards", "fields": ["nope"]}),
    )
    .unwrap_err();
    assert!(err.contains("unknown column nope"), "{err}");

    // 笔记：未删除 / 词条键 / 排序 + 分页 / 类型。
    assert_eq!(
        column(&core, P, "notes", json!({"alive": true}), "id"),
        vec![s(&note_id(P, 0))]
    );
    assert_eq!(
        column(
            &core,
            P,
            "notes",
            json!({"order": "created_desc", "limit": 1}),
            "created_at"
        ),
        vec![i(11)]
    );
    assert_eq!(
        column(
            &core,
            P,
            "notes",
            json!({"order": "created_asc", "limit": 5, "offset": 1, "termKey": "term", "typeId": "NT"}),
            "deleted_at"
        ),
        vec![i(5)]
    );
    assert_eq!(
        column(&core, P, "note_type_counts", json!({}), "c"),
        vec![i(1)]
    );
    assert_eq!(read(&core, P, "pending_notes", json!({})).0["n"], json!(0));
    assert_eq!(
        column(&core, P, "media_refs", json!({}), "refs"),
        vec![s("m0.png")]
    );
    assert_eq!(
        column(&core, P, "media_refs", json!({"deletedBefore": 5}), "refs"),
        vec![s("m1.png")]
    );
    assert_eq!(
        sorted(column(
            &core,
            P,
            "media_refs",
            json!({"deletedAfter": 4}),
            "refs"
        )),
        vec![s("m0.png"), s("m1.png")]
    );
    assert_eq!(
        column(
            &core,
            P,
            "term_status",
            json!({"terms": ["term", "other"]}),
            "id"
        ),
        vec![s(&card_id(P, 0))]
    );
    // 两条笔记同类型同词条键，但一条已删：不成组。
    assert!(column(&core, P, "dup_groups", json!({}), "id").is_empty());
}

/// 字段类别的筛选条件按 Dart 给的规则拼出来，与 Dart 以前自己拼的文本逐字相同。
#[test]
fn class_filter_spells_the_rules_as_sql() {
    let f = |rules: Value| super::class_filter(&rules).unwrap();
    assert_eq!(f(json!([])), "(0)");
    assert_eq!(
        f(json!([
            {"kind": "note", "keep": ["deck", "type"]},
            {"kind": "card", "drop": ["newPos"]},
            {"kind": "profile", "drop": []},
        ])),
        "((entity_kind = 'note' AND field_key IN ('deck', 'type')) OR \
         (entity_kind = 'card' AND field_key NOT IN ('newPos')) OR (entity_kind = 'profile'))"
    );
    assert_eq!(
        f(json!([{"kind": "de'ck", "keep": ["a'b"]}])),
        "((entity_kind = 'de''ck' AND field_key IN ('a''b')))"
    );
    assert!(super::class_filter(&json!([{"kind": "note"}])).is_err());
    assert!(super::class_filter(&json!([{"kind": "note", "keep": [], "drop": []}])).is_err());
}

/// `conflict_edits`：只交回还留着两条以上记录的字段键上的记录，且只看规则圈定的类别。
#[test]
fn conflict_edits_returns_only_registers_with_two_or_more_edits() {
    let (core, _d) = two_profiles("conflicts");
    let rules = json!([{"kind": "note", "drop": []}]);
    assert!(column(&core, P, "conflict_edits", json!({"rules": rules}), "f").is_empty());
    // 同一个字段键上补第二条互不支配的记录（直接写投影表：另一台设备并发写下的形态）。
    {
        let w = core.writer().unwrap();
        w.execute(
            "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
             SELECT srs_id('E-extra'), profile_uid, entity_kind, entity_id, field_key, srs_id('other'), 9, jslim \
             FROM srs_field_edits WHERE profile_uid = srs_id(?1) AND entity_id = srs_id(?2) AND field_key = 'f/a'",
            params![P, note_id(P, 0)],
        )
        .unwrap();
    }
    assert_eq!(
        column(&core, P, "conflict_edits", json!({"rules": rules}), "f"),
        vec![s("f/a"), s("f/a")]
    );
    assert_eq!(
        column(
            &core,
            P,
            "conflict_edits",
            json!({"rules": rules, "kind": "note", "id": note_id(P, 1)}),
            "f"
        ),
        Vec::<Cell>::new()
    );
    assert_eq!(
        column(
            &core,
            P,
            "conflict_edits",
            json!({"rules": [{"kind": "note", "keep": ["deck"]}]}),
            "f"
        ),
        Vec::<Cell>::new()
    );
    assert!(column(&core, Q, "conflict_edits", json!({"rules": rules}), "f").is_empty());
}

/// 不针对单个 profile 的查询，与查询名 / 参数出错时的报错。
#[test]
fn library_queries_and_bad_requests() {
    let (core, _d) = two_profiles("lib");
    let lib = |q: &str| command(&core, json!({"op": "read_lib", "q": q})).unwrap();
    assert_eq!(lib("user_note_count").0["n"], json!(4));
    let owners = decode(&lib("entity_owners").1[0].1);
    assert_eq!(sorted(owners[0].1.clone()), sorted(vec![s(P), s(Q)]));
    assert!(decode(&lib("profile_merges").1[0].1)[0].1.is_empty());
    core.profile_merge_mark(P, 7, Q).unwrap();
    let merges = decode(&lib("profile_merges").1[0].1);
    assert_eq!(merges[0].1, vec![s(&format!("profile_merge/{P}"))]);

    for (req, want) in [
        (
            json!({"op": "read", "profile": P, "q": "nope"}),
            "unknown query nope",
        ),
        (json!({"op": "read", "profile": P}), "missing q"),
        (json!({"op": "read", "q": "entities"}), "missing profile"),
        (
            json!({"op": "read_lib", "q": "entities"}),
            "unknown query entities",
        ),
        (
            json!({"op": "read", "profile": P, "q": "edits", "kind": "note"}),
            "missing ids",
        ),
        (
            json!({"op": "read", "profile": P, "q": "entities", "ids": "x"}),
            "ids must be an array",
        ),
    ] {
        let err = command(&core, req.clone()).unwrap_err();
        assert!(err.contains(want), "{req}: {err}");
    }
}

/// 读命令看得见刚返回的写命令（开读事务时取最新的 WAL 尾），也不留下任何事务。
#[test]
fn a_read_sees_the_write_that_just_returned() {
    let (core, _d) = open("fresh");
    assert_eq!(read(&core, P, "entity_count", json!({})).0["n"], json!(0));
    seed(&core, P);
    assert_eq!(read(&core, P, "entity_count", json!({})).0["n"], json!(3));
    assert_eq!(
        read(
            &core,
            P,
            "has_user_data",
            json!({"builtins": [format!("D-{P}")]})
        )
        .0["any"],
        json!(true)
    );
    assert!(!core.in_transaction().unwrap());
}
