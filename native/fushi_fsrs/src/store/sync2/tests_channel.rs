//! 新设备收段通道（channel.rs，先追加后折叠）与逐条投递对拍：同一份段、同一个起点（`copy_of` 复制，本机身份也相同），
//! 都经生产分发器的分批会话（`ingest_begin` / `ingest_prepare` / `ingest_commit` / `ingest_finish` / `replay_pending`）
//! 收完，一边走通道、一边关掉通道（[super::channel::sequential]），之后**每一张表**逐行相同（摘要桶逐位相同、缓存行
//! 相同），复习队列 / 浏览的待重读相同。
//!
//! 世界是伪随机的多设备历史：并发改同一字段、删除 / 恢复（与删除并发的内容 → 挂起与冲突中心）、清除、整列表标签、
//! 复习、移卡、删牌组（移进被删牌组的卡要逐条），以及两台设备各自迁移同一个旧库（同一条旧记录被包两次、旧记录带
//! 服务器时刻、合成写入者的旧 `tags` 记录、一台设备分两批迁移让 v2 写入只见过它一部分旧记录）。
//!
//! 除了一口气收完，还对拍几种中途打断：追加到一半重开会话、折叠到一半重开会话、追加到一半本机写入（分发器先把通道
//! 做完，之后逐条投递）。打断落在「交完一半的段」之后，所以段按世界里钉死的设备顺序交（[World]），不按文件夹里
//! 设备 ID 的顺序（ID 是随机的）。
//!
//! 起点有两种（[Start]）：裸 profile（只建了身份），与真实新设备（BUG-4387：Dart `SrsDbStore.open` 在任何同步之前就
//! 写下内置身份记录，[builtins]）。带内置实体的起点上，世界（[Shape]）还覆盖：每台设备各写一份同样的内置身份记录、
//! 远端没直接动过内置实体、改过（牌组名 / 配置、笔记类型字段与模板）、删过 / 恢复过 / 清除过、同 ID 内容不同。

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::tests::{Bucket, Device, P, deck_entity, edit, review};

const T0: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;
const NOW: i64 = T0 + 400 * DAY;
const NOTES: u64 = 9;

/// 两个内置笔记类型的 ID（真实 ID 由 Dart 按 profile uid 派生；内核只认载荷里的 `builtin` 键）。
const NT_LAPIS: &str = "0193a1b2-0000-7000-8000-0000000b0001";
const NT_CARD: &str = "0193a1b2-0000-7000-8000-0000000b0002";

fn note_type(id: &str, d: Value) -> (Value, String) {
    (
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "notetype", "d": d}}),
        String::new(),
    )
}

/// 内置身份记录（Dart `srsBuiltinEntities`：默认牌组 + 两个内置笔记类型，载荷带 `builtin` 键）：每台设备开库就写
/// 同一份，ID 相同、内容逐字节相同。
fn builtins() -> Vec<(Value, String)> {
    vec![
        (
            deck_entity(&super::config::default_deck_id(P)),
            String::new(),
        ),
        note_type(
            NT_LAPIS,
            json!({"ankiNum": 1, "ntKind": "standard", "builtin": "lapis"}),
        ),
        note_type(
            NT_CARD,
            json!({"ankiNum": 2, "ntKind": "standard", "builtin": "fushi"}),
        ),
    ]
}

/// 收段那台设备的起点。
#[derive(Clone, Copy, PartialEq, Debug)]
enum Start {
    /// 只建了身份（操作日志与投影全空）。
    Bare,
    /// 真实新设备：开库时已写下内置身份记录。
    Builtins,
    /// v2 之前装的、从没用过的库：内置身份记录是旧投影行，迁移把它们包成本机的操作。
    Migrated,
}

/// 世界里与内置实体有关的部分。缺省 = 原来的世界（只有第一台设备写默认牌组的身份记录，改它的名字与配置）。
#[derive(Clone, Copy, Default, Debug)]
struct Shape {
    /// 每台设备开库都写内置身份记录（同 ID 同内容，彼此并发），部分笔记用内置笔记类型。
    builtins: bool,
    /// 远端不直接改内置实体（牌组名 / 配置改在第二个牌组上；内置笔记类型没有修改记录）。
    hands_off: bool,
    /// 远端删 / 恢复内置牌组与内置笔记类型，并彻底清除一个内置笔记类型。
    delete: bool,
    /// 两台设备写的内置身份记录内容与别人不同（同 ID）：一份规范文本更小（盖掉本机那行）、一份更大（不落）。
    divergent: bool,
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn note_id(n: u64) -> String {
    format!("0193a1b2-0000-7000-8000-{n:012x}")
}

fn card_of(n: u64) -> String {
    crate::registers::card_id(&note_id(n), "t1", 0).unwrap()
}

/// 旧库里一条笔记字段的旧修改记录（[server] = 旧服务器记下的时刻）。
#[allow(clippy::too_many_arguments)]
fn legacy_edit(
    d: &Device,
    writer: &str,
    s: i64,
    n: u64,
    key: &str,
    v: Value,
    vv: Value,
    server: Option<i64>,
) {
    let id = crate::registers::edit_id(writer, s);
    let note = note_id(n);
    let j = json!({"ctx": {"vv": vv}, "e": note, "f": key, "hlc": format!("{}:0:{writer}", T0 - 1000 + s), "id": id, "k": "note",
                   "p": P, "s": s, "ts": "wall", "v": v, "w": writer})
    .to_string();
    d.core
        .writer()
        .unwrap()
        .execute(
            "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
             VALUES (srs_id(?1), srs_id(?2), 'note', srs_id(?3), ?4, ?5, ?6, ?7)",
            rusqlite::params![id, P, note, key, writer, s, j],
        )
        .unwrap();
    legacy_server_time(d, &id, server);
}

fn legacy_server_time(d: &Device, id: &str, server: Option<i64>) {
    if let Some(st) = server {
        d.core
            .writer()
            .unwrap()
            .execute(
                "INSERT INTO srs_event_local (event_id, profile_uid, outbox_seq, server_time, received_at) VALUES (srs_id(?1), srs_id(?2), 1, ?3, 1)",
                rusqlite::params![id, P, st],
            )
            .unwrap();
    }
}

/// 旧库里一条复习日志（作者结果照抄，见 mod.rs `sync2_migrate`）。
fn legacy_log(d: &Device, id: &str, n: u64, at: i64, server: Option<i64>) {
    let card = card_of(n);
    let x = json!({"id": id, "p": P, "card": card, "kind": "review", "rating": 3, "hlc": format!("{at}:0:old1"), "at": at,
                   "ts": "anchored", "origin": "fushi", "rtype": "review", "utcOff": 0, "rollover": 4, "fv": 1,
                   "res": {"queue": "review", "dueDay": 19_700, "ivl": 3, "step": 0, "reps": 2, "lapses": 0, "scheduler": "fushi"}});
    d.core
        .writer()
        .unwrap()
        .execute(
            "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, jslim) \
             VALUES (srs_id(?1), srs_id(?2), srs_id(?3), 'review', 3, ?4, 'review', 'fushi', ?5)",
            rusqlite::params![id, P, card, at, x.to_string()],
        )
        .unwrap();
    legacy_server_time(d, id, server);
}

/// 旧库：几条笔记上的旧修改记录（两个旧写入者，有因果覆盖也有并发，部分带服务器时刻）、一条合成写入者的旧整列表
/// 标签（走标签路径，不让笔记变复杂）与几条旧复习日志。
fn legacy_library(d: &Device) {
    let rows: [(&str, i64, u64, &str, Value, Value, Option<i64>); 6] = [
        (
            "old1",
            1,
            0,
            "f/fa",
            json!("legacy a"),
            json!({}),
            Some(T0 - 900),
        ),
        (
            "old1",
            2,
            0,
            "f/fa",
            json!("legacy a2"),
            json!({"old1": 1}),
            None,
        ),
        (
            "old2",
            1,
            0,
            "f/fa",
            json!("legacy concurrent"),
            json!({}),
            Some(T0 - 950),
        ),
        (
            "old2",
            2,
            1,
            "f/fb",
            json!("legacy b"),
            json!({"old1": 2}),
            None,
        ),
        (
            "old1",
            3,
            2,
            "f/fa",
            json!("legacy c"),
            json!({"old1": 2, "old2": 2}),
            Some(T0 - 800),
        ),
        (
            "old2",
            3,
            2,
            "deleted",
            json!(null),
            json!({"old2": 2}),
            None,
        ),
    ];
    for (writer, s, n, key, v, vv, server) in rows {
        legacy_edit(d, writer, s, n, key, v, vv, server);
    }
    let synth = format!(
        "{}tags:{}",
        crate::registers::SYNTHETIC_WRITER_PREFIX,
        note_id(5)
    );
    legacy_edit(
        d,
        &synth,
        1,
        5,
        "tags",
        json!(["legacy-tag", "t1"]),
        json!({"old1": 1}),
        None,
    );
    legacy_log(
        d,
        "0193a1b2-0000-7000-8000-0000000010a1",
        1,
        T0 - 5 * DAY,
        Some(T0 - 5 * DAY + 10),
    );
    legacy_log(
        d,
        "0193a1b2-0000-7000-8000-0000000010a2",
        1,
        T0 - 2 * DAY,
        None,
    );
    legacy_log(
        d,
        "0193a1b2-0000-7000-8000-0000000010a3",
        4,
        T0 - 3 * DAY,
        Some(T0 - 3 * DAY + 10),
    );
}

fn local(d: &Device, now: i64, events: Vec<(Value, String)>) {
    let input: Vec<Value> = events
        .into_iter()
        .map(|(e, note)| json!({"e": e, "note": note}))
        .collect();
    d.core
        .sync2_apply_local(P, now, &Value::Array(input).to_string())
        .unwrap();
}

/// 一个伪随机世界：同步文件夹（全部历史）与交段的顺序。当 [Bucket] 用（解引用）。
///
/// 设备 ID 是随机的（mod.rs `Local::create`：UUIDv7，时间前缀取建身份那一刻的 `now`——前四台设备都是 `T0`，前缀
/// 相同，先后全看随机位），而文件夹按路径 `devices/<设备 ID>/…` 排序：照文件夹的顺序交段，哪台设备的段先到就随运行
/// 而变。一口气收完时无所谓（收下的是同一批操作），中途打断时不行——打断那一刻通道里已追加的是哪些操作跟着变。三台
/// v2 设备里只有第一台的操作不依赖别人；另两台的 ID 恰好排在最前时（四台里排前两名：六次里一次），一半的段交完也
/// 只投得出它们开库时写的内置身份记录，[Interrupt::LocalWrite] 那一刻通道里一条可折的都没有——PR #3314 的 CI 红在
/// 这里（当时拿「折了几条」当「走没走通道」）。所以交段的顺序是世界的一部分（[World::feed]），不跟设备 ID 走；那种
/// 到法另有一条测试钉着（`a_local_write_settles_a_channel_holding_only_identity_records_already_there`）。
struct World {
    bucket: Bucket,
    /// 写这份文件夹的设备 ID，按交段的先后（[fed]）。[world_of] 给的是设备建出来的顺序：三台 v2 设备，再两台迁移
    /// 旧库的。
    feed: Vec<String>,
}

impl std::ops::Deref for World {
    type Target = Bucket;

    fn deref(&self) -> &Bucket {
        &self.bucket
    }
}

impl World {
    /// 一份现成的文件夹，照文件夹的顺序交段：给不在中途打断的会话用（一台设备，或全部段一批交完）。
    fn of(bucket: &Bucket) -> World {
        let mut feed: Vec<String> = Vec::new();
        for k in bucket.0.keys().filter(|k| k.contains("/seg-")) {
            let dev = k.split('/').nth(1).unwrap().to_owned();
            if feed.last() != Some(&dev) {
                feed.push(dev);
            }
        }
        World {
            bucket: bucket.clone(),
            feed,
        }
    }
}

fn device_id(d: &Device) -> String {
    d.core.sync2_identity(P, NOW).unwrap()["device"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn world(seed: u64) -> World {
    world_of(seed, Shape::default())
}

/// [world]，内置实体那部分按 [shape]。缺省的 [Shape] 不多取随机数：原有种子生成的世界不变。
fn world_of(seed: u64, shape: Shape) -> World {
    let mut rng = Rng(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1);
    let deck = super::config::default_deck_id(P);
    let deck2 = "0193a1b2-0000-7000-8000-00000000d0c2".to_owned();
    let devs = [
        Device::new("ch-a"),
        Device::new("ch-b"),
        Device::new("ch-c"),
    ];
    let l1 = Device::new("ch-l1");
    legacy_library(&l1);
    let l2 = Device::copy_of(&l1, "ch-l2");
    // 复制之后各自又写了同一个旧 ID（同一笔记、不同字段）。服务器时刻一边有一边没有。
    legacy_edit(&l1, "old3", 1, 3, "f/fa", json!("l1 copy"), json!({}), None);
    legacy_edit(
        &l2,
        "old3",
        1,
        3,
        "f/fb",
        json!("l2 copy"),
        json!({}),
        Some(T0 - 700),
    );
    let mut bucket = Bucket::default();
    // 牌组名 / 配置改在哪个牌组上。
    let named = if shape.hands_off { &deck2 } else { &deck };
    let mut setup = if shape.builtins {
        builtins()
    } else {
        vec![(deck_entity(&deck), String::new())]
    };
    if shape.builtins && !shape.hands_off {
        setup.push((
            edit(
                "notetype",
                NT_LAPIS,
                "fieldDef/fa",
                json!({"name": "A", "ord": 0}),
            ),
            String::new(),
        ));
        setup.push((
            edit(
                "notetype",
                NT_LAPIS,
                "tmplDef/t1",
                json!({"name": "C", "ord": 0, "front": "{{A}}"}),
            ),
            String::new(),
        ));
    }
    setup.extend([
        (edit("deck", named, "name", json!("D")), String::new()),
        (deck_entity(&deck2), String::new()),
        (
            json!({"t": "entity", "x": {"id": "NT", "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            String::new(),
        ),
        (
            edit(
                "notetype",
                "NT",
                "fieldDef/fa",
                json!({"name": "A", "ord": 0}),
            ),
            String::new(),
        ),
        (
            edit(
                "notetype",
                "NT",
                "tmplDef/t1",
                json!({"name": "C", "ord": 0, "front": "{{A}}"}),
            ),
            String::new(),
        ),
    ]);
    for n in 0..NOTES {
        let note = note_id(n);
        let nt = if shape.builtins && n % 3 == 0 {
            NT_LAPIS
        } else {
            "NT"
        };
        setup.push((json!({"t": "entity", "x": {"id": note, "p": P, "k": "note", "d": {"createdAt": 1, "guid": note, "noteTypeId": nt}}}), note));
    }
    local(&devs[0], T0, setup);
    if shape.builtins {
        // 另外两台设备开库时各写一份内置身份记录（还没同步过：与别人的那份并发）。
        let mut b1 = builtins();
        let mut b2 = builtins();
        if shape.divergent {
            b1[0] = (
                json!({"t": "entity", "x": {"id": deck, "p": P, "k": "deck", "d": {"createdAt": 0, "builtin": "default"}}}),
                String::new(),
            );
            b2[2] = note_type(
                NT_CARD,
                json!({"ankiNum": 9, "ntKind": "standard", "builtin": "fushi"}),
            );
        }
        local(&devs[1], T0, b1);
        local(&devs[2], T0, b2);
    }
    // l1 分两批迁移，中间 devs[0] 收了前一批并在旧记录写过的字段上写了一条。
    l1.core.sync2_migrate(P, T0, Some(3)).unwrap();
    l1.sync(&mut bucket, "loc", T0 + 1);
    devs[0].sync(&mut bucket, "loc", T0 + 1);
    local(
        &devs[0],
        T0 + 1,
        vec![(
            edit("note", &note_id(0), "f/fa", json!("over part of l1")),
            note_id(0),
        )],
    );
    devs[0].sync(&mut bucket, "loc", T0 + 1);
    l1.core.sync2_migrate(P, T0, None).unwrap();
    l1.sync(&mut bucket, "loc", T0 + 1);
    l2.core.sync2_migrate(P, T0 + 1, None).unwrap();
    l2.sync(&mut bucket, "loc", T0 + 1);
    for d in &devs {
        d.sync(&mut bucket, "loc", T0 + 2);
    }
    for round in 0..6i64 {
        for (i, d) in devs.iter().enumerate() {
            let now = T0 + (round + 1) * DAY + i as i64 * 3_600_000;
            let mut ev: Vec<(Value, String)> = Vec::new();
            for k in 0..4 + rng.below(10) {
                let n = rng.below(NOTES);
                let note = note_id(n);
                let tag = format!("r{round}d{i}k{k}");
                let e = match rng.below(21) {
                    0..=6 => edit(
                        "note",
                        &note,
                        if rng.below(2) == 0 { "f/fa" } else { "f/fb" },
                        json!(tag),
                    ),
                    7..=8 => edit(
                        "note",
                        &note,
                        "tags",
                        json!([format!("t{}", rng.below(4)), format!("t{}", rng.below(4))]),
                    ),
                    9..=12 => review(
                        &tag,
                        &card_of(n),
                        now + k as i64,
                        1 + rng.below(4) as i64,
                        if round == 0 { "learn" } else { "review" },
                    ),
                    13 => edit("note", &note, "deleted", json!(now)),
                    14 => edit("note", &note, "deleted", json!(null)),
                    15 => edit("card", &card_of(n), "flag", json!(rng.below(5))),
                    16 => edit(
                        "card",
                        &card_of(n),
                        "deck",
                        json!(if rng.below(2) == 0 { &deck } else { &deck2 }),
                    ),
                    17 => edit("deck", &deck2, "name", json!(tag)),
                    18 => edit("card", &card_of(n), "deleted", json!(now)),
                    // 删 / 恢复第二个牌组：移进它的卡在通道里要逐条投。
                    19 => edit(
                        "deck",
                        &deck2,
                        "deleted",
                        if rng.below(2) == 0 {
                            json!(now)
                        } else {
                            json!(null)
                        },
                    ),
                    _ => edit(
                        "deck",
                        named,
                        "retention",
                        json!(0.8 + rng.below(10) as f64 / 100.0),
                    ),
                };
                let mut e = e;
                // 远端改内置笔记类型（字段、模板、名字）与内置牌组的名字。
                if shape.builtins && !shape.hands_off && rng.below(6) == 0 {
                    e = match rng.below(4) {
                        0 => edit(
                            "notetype",
                            NT_LAPIS,
                            "tmplDef/t1",
                            json!({"name": "C", "ord": 0, "front": format!("{{{{A}}}} {tag}")}),
                        ),
                        1 => edit("notetype", NT_LAPIS, "name", json!(tag)),
                        2 => edit(
                            "notetype",
                            NT_CARD,
                            "fieldDef/fa",
                            json!({"name": tag, "ord": 0}),
                        ),
                        _ => edit("deck", &deck, "name", json!(tag)),
                    };
                }
                // 远端删 / 恢复内置牌组与内置笔记类型。
                if shape.delete && rng.below(7) == 0 {
                    let v = if rng.below(3) == 0 {
                        json!(null)
                    } else {
                        json!(now)
                    };
                    e = match rng.below(3) {
                        0 => edit("deck", &deck, "deleted", v),
                        1 => edit("notetype", NT_LAPIS, "deleted", v),
                        _ => edit("notetype", NT_CARD, "deleted", v),
                    };
                }
                ev.push((e, note));
            }
            local(d, now, ev);
            if shape.delete && round == 3 && i == 1 {
                d.core.sync2_purge(P, "notetype", NT_CARD, now + 2).unwrap();
            }
            if rng.below(12) == 0 {
                d.core
                    .sync2_purge(P, "note", &note_id(rng.below(NOTES)), now + 1)
                    .unwrap();
            }
        }
        // 只同步一部分设备、顺序随机：留下并发。
        for i in 0..devs.len() {
            if rng.below(3) != 0 {
                let d = &devs[(i + rng.below(3) as usize) % devs.len()];
                d.sync(
                    &mut bucket,
                    "loc",
                    T0 + (round + 1) * DAY + 20 * 3_600_000 + i as i64,
                );
            }
        }
    }
    for _ in 0..2 {
        for d in &devs {
            d.sync(&mut bucket, "loc", T0 + 30 * DAY);
        }
    }
    let feed = devs.iter().chain([&l1, &l2]).map(device_id).collect();
    World { bucket, feed }
}

/// 全部表（`sqlite_` 内部表除外）的全部列、逐行，排好序。缓存表的 `updated_at` 是刷新时的真实墙钟（两次运行必然
/// 不同），不比。
fn dump(d: &Device) -> Vec<(String, Vec<String>)> {
    let tables: Vec<String> =
        d.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")[1..].iter().map(|r| r[0].clone()).collect();
    tables
        .into_iter()
        .map(|t| {
            let cols: Vec<String> = d.rows(&format!(
                "SELECT name FROM pragma_table_info('{t}') ORDER BY cid"
            ))[1..]
                .iter()
                .filter(|r| !(t.ends_with("_cache") && r[0] == "updated_at"))
                .map(|r| format!("quote({})", r[0]))
                .collect();
            let mut rows: Vec<String> = d
                .rows(&format!("SELECT {} FROM {t}", cols.join(" || '|' || ")))[1..]
                .iter()
                .map(|r| r[0].clone())
                .collect();
            rows.sort();
            (t, rows)
        })
        .collect()
}

fn assert_same(a: &Device, b: &Device, what: &str) {
    let (da, db) = (dump(a), dump(b));
    assert_eq!(da.len(), db.len());
    for ((ta, ra), (tb, rb)) in da.iter().zip(&db) {
        assert_eq!(ta, tb);
        if ra != rb {
            // 只报两边各自多出来的行（整表打出来看不见差在哪）。
            let only = |x: &[String], y: &[String]| -> Vec<String> {
                let y: BTreeSet<&String> = y.iter().collect();
                x.iter().filter(|r| !y.contains(r)).cloned().collect()
            };
            panic!(
                "{what}: table {ta} differs
 only left: {:#?}
 only right: {:#?}",
                only(ra, rb),
                only(rb, ra)
            );
        }
    }
}

/// 复习队列（卡 / 日志）与浏览（卡 / 笔记）的待重读：取走。
fn dirty(d: &Device) -> [BTreeSet<String>; 4] {
    let s = d.core.study_hub.take_study(P);
    let b = d.core.study_hub.take_browse(P, true);
    assert!(!s.overflow && !b.overflow);
    let set = |h: std::collections::HashSet<String>| h.into_iter().collect::<BTreeSet<String>>();
    [set(s.cards), set(s.logs), set(b.cards), set(b.notes)]
}

fn digest_is_consistent(d: &Device) {
    let r = d.core.reader().unwrap();
    assert_eq!(
        super::digest::root(&r, P).unwrap(),
        super::digest::root_by_scan(&r, P).unwrap(),
        "bucket digest drifted from a full scan"
    );
}

/// 缓存配置（Dart `SrsDbStore._cacheConfig`）：默认牌组与内置笔记类型的代码默认值（没有修改记录的内置类型靠它
/// 物化出字段与模板）。
fn cache_config() -> Value {
    let builtin = |name: &str| {
        json!({
            "b": {
                "name": name, "css": "", "termFieldId": "fa",
                "fields": [{"id": "fa", "name": "A", "ord": 0}, {"id": "fb", "name": "B", "ord": 1}],
                "templates": [{"id": "t1", "name": "C", "ord": 0, "front": "{{A}}", "back": "{{B}}"}],
            },
            "reading": "fb",
        })
    };
    json!({
        "defaultDeck": super::config::default_deck_id(P),
        "builtins": {"lapis": builtin("Lapis"), "fushi": builtin("Fushi")},
    })
}

/// 经生产分发器发一条 v2 命令。
fn cmd(d: &Device, req: Value, blobs: Vec<Vec<u8>>) -> Value {
    let mut req = req;
    req["profile"] = json!(P);
    req["caches"] = cache_config();
    let mut blobs = blobs;
    let mut files = Vec::new();
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files).unwrap()
}

/// 经生产分发器发一条 v2 命令，期望它失败：返回错误文本。
fn cmd_err(d: &Device, req: Value) -> String {
    let mut req = req;
    req["profile"] = json!(P);
    let (mut blobs, mut files) = (Vec::new(), Vec::new());
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files).unwrap_err()
}

/// 文件夹里的 head 与段。
fn heads_and_segments(b: &Bucket) -> (Vec<Vec<u8>>, Vec<Vec<u8>>) {
    let heads =
        b.0.iter()
            .filter(|(k, _)| {
                k.rsplit('/')
                    .next()
                    .and_then(crate::sync2::segment::parse_head_file_name)
                    .is_some()
            })
            .map(|(_, v)| v.clone())
            .collect();
    let segs =
        b.0.iter()
            .filter(|(k, _)| k.contains("/seg-"))
            .map(|(_, v)| v.clone())
            .collect();
    (heads, segs)
}

/// [w] 的 head，与按 [World::feed] 的设备先后（一台设备之内按段名 = seq 先后）排好的段。
fn fed(w: &World) -> (Vec<Vec<u8>>, Vec<Vec<u8>>) {
    let (heads, all) = heads_and_segments(w);
    let segs: Vec<Vec<u8>> = w
        .feed
        .iter()
        .flat_map(|dev| {
            let dir = format!("devices/{dev}/seg-");
            w.bucket
                .0
                .iter()
                .filter(move |(k, _)| k.starts_with(&dir))
                .map(|(_, v)| v.clone())
        })
        .collect();
    assert_eq!(
        segs.len(),
        all.len(),
        "a segment of a device the feed order does not name"
    );
    (heads, segs)
}

/// 中途要做的事（[session] 在第 [at] 批投完之后）。
#[derive(Clone, Copy, PartialEq, Debug)]
enum Interrupt {
    None,
    /// 重开收段会话（App 在追加途中被杀）。
    ReopenWhileAppending,
    /// 本机写一条（作答）：分发器先把通道做完。
    LocalWrite,
    /// 收尾折到一半重开会话（App 在折叠途中被杀），新会话没有段可收。
    ReopenWhileFolding,
    /// 收尾归并到一半（至少归并过一张表）重开会话（App 在归并途中被杀）。
    ReopenWhileMerging,
}

/// 通道的（阶段, 游标）；没有通道 = None。
fn boot_state(d: &Device) -> Option<(i64, i64)> {
    let rows = d.rows("SELECT phase, cursor FROM sync2_boot");
    rows.get(1)
        .map(|r| (r[0].parse().unwrap(), r[1].parse().unwrap()))
}

/// 分批会话收完 [w]：按 [fed] 的顺序每批 [per] 个段，每片 [slice] 条（None = 生产的按时间切）。返回这个会话走不走
/// 通道（`ingest_begin` 报给 Dart 的 `channel`）。
fn session(d: &Device, w: &World, per: usize, slice: Option<u64>, interrupt: Interrupt) -> bool {
    let (heads, segs) = fed(w);
    let sliced = |op: &str| -> Value {
        let mut r = json!({"op": op, "now": NOW});
        if let Some(n) = slice {
            r["sliceOps"] = json!(n);
        }
        r
    };
    cmd(d, json!({"op": "plan"}), heads);
    let channel = cmd(d, json!({"op": "ingest_begin"}), vec![])["channel"] == json!(true);
    let at = segs.len() / per / 2;
    for (i, chunk) in segs.chunks(per).enumerate() {
        cmd(d, json!({"op": "ingest_prepare"}), chunk.to_vec());
        while cmd(d, sliced("ingest_commit"), vec![])["more"] == json!(true) {}
        if i == at {
            match interrupt {
                Interrupt::ReopenWhileAppending => {
                    assert_eq!(
                        cmd(d, json!({"op": "ingest_begin"}), vec![])["channel"],
                        json!(channel),
                        "the reopened session goes on the way the first one went"
                    );
                }
                Interrupt::LocalWrite => {
                    let input = json!([{"e": edit("note", &note_id(7), "f/fa", json!("typed mid-sync")), "note": note_id(7)}]).to_string();
                    cmd(
                        d,
                        json!({"op": "apply", "now": NOW}),
                        vec![input.into_bytes()],
                    );
                    let w = d.core.writer().unwrap();
                    assert!(
                        !super::channel::active(&w, P).unwrap(),
                        "a local write settles the channel first"
                    );
                }
                _ => {}
            }
        }
    }
    let mut r = cmd(d, sliced("ingest_finish"), vec![]);
    if interrupt == Interrupt::ReopenWhileFolding && r["more"] == json!(true) {
        cmd(d, json!({"op": "ingest_begin"}), vec![]);
        r = cmd(d, sliced("ingest_finish"), vec![]);
    }
    // 逐条投递的对照组没有通道，照常收完。
    if interrupt == Interrupt::ReopenWhileMerging && boot_state(d).is_some() {
        while !boot_state(d).is_some_and(|(phase, cursor)| phase == 2 && cursor >= 1) {
            assert_eq!(
                r["more"],
                json!(true),
                "the channel finished without being caught mid-merge"
            );
            r = cmd(d, sliced("replay_pending"), vec![]);
        }
        cmd(d, json!({"op": "ingest_begin"}), vec![]);
        assert!(
            boot_state(d).is_none(),
            "the next session settles the channel first"
        );
        r = cmd(d, sliced("ingest_finish"), vec![]);
    }
    while r["more"] == json!(true) {
        r = cmd(d, sliced("replay_pending"), vec![]);
    }
    channel
}

fn add(total: &mut [usize; 5], c: [usize; 5]) {
    for (t, c) in total.iter_mut().zip(c) {
        *t += c;
    }
}

/// 一台新设备（只建了身份，或已写下内置身份记录）。
fn new_device(tag: &str, start: Start) -> Device {
    let d = Device::new(tag);
    if start == Start::Migrated {
        {
            let w = d.core.writer().unwrap();
            for (e, _) in builtins() {
                let x = &e["x"];
                w.execute(
                    "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES (srs_id(?1), srs_id(?2), ?3, ?4, ?5)",
                    rusqlite::params![
                        x["id"].as_str(),
                        P,
                        x["k"].as_str(),
                        super::canonical(&x["d"]),
                        x["d"]["createdAt"].as_i64().unwrap_or(0)
                    ],
                )
                .unwrap();
            }
        }
        assert_eq!(
            d.core.sync2_migrate(P, NOW, None).unwrap()["done"],
            json!(true)
        );
    }
    d.core.sync2_identity(P, NOW).unwrap();
    if start == Start::Builtins {
        local(&d, NOW, builtins());
    }
    d
}

/// 一个新设备：通道与逐条两路经同一个分批会话收完，一切相同。
fn compare(
    seed: u64,
    per: usize,
    slice: Option<u64>,
    interrupt: Interrupt,
    total: &mut [usize; 5],
) {
    compare_from(
        Start::Bare,
        Shape::default(),
        seed,
        per,
        slice,
        interrupt,
        total,
    );
}

/// [compare]，收段那台设备从 [start] 起、世界按 [shape]。
fn compare_from(
    start: Start,
    shape: Shape,
    seed: u64,
    per: usize,
    slice: Option<u64>,
    interrupt: Interrupt,
    total: &mut [usize; 5],
) {
    let all = world_of(seed, shape);
    let what = format!(
        "{start:?}, {shape:?}, seed {seed}, {per} segments a batch, slice {slice:?}, {interrupt:?}"
    );
    let covered = compare_world(start, &all, per, slice, interrupt, &what);
    // 交段顺序钉死之后这是种子的函数：折了哪些只看收尾 / 打断那一刻通道里有哪些操作，不看它们到的先后。
    assert!(
        covered[0] > 0,
        "{what}: the channel folded nothing ({covered:?})"
    );
    add(total, covered);
}

/// 新设备从 [start] 起收 [all]：通道与逐条两路经同一个分批会话收完，一切相同。返回通道那一路各分支走过几次
/// （[super::channel::take_coverage]）。
fn compare_world(
    start: Start,
    all: &World,
    per: usize,
    slice: Option<u64>,
    interrupt: Interrupt,
    what: &str,
) -> [usize; 5] {
    let x = new_device("ch-x", start);
    let y = Device::copy_of(&x, "ch-y");
    dirty(&x);
    dirty(&y);
    super::channel::take_coverage();
    assert!(
        session(&x, all, per, slice, interrupt),
        "{what}: the session never took the channel"
    );
    let covered = super::channel::take_coverage();
    assert!(
        !super::channel::sequential(|| session(&y, all, per, slice, interrupt)),
        "{what}: the one-by-one control took the channel"
    );
    assert!(
        x.rows("SELECT COUNT(*) FROM sync2_ops")[1][0]
            .parse::<u64>()
            .unwrap()
            > 50,
        "{what}: world too small"
    );
    assert_same(&x, &y, what);
    assert_eq!(dirty(&x), dirty(&y), "{what}: study / browse touches");
    digest_is_consistent(&x);
    covered
}

/// 新设备第一次同步：通道与逐条投递逐表相同；随机世界走到了折叠、复杂实体逐条、折叠里落了又被支配、移进复杂牌组。
#[test]
fn channel_matches_sequential_for_a_new_device() {
    let mut total = [0usize; 5];
    for seed in 1..=5u64 {
        compare(seed, 2, Some(7), Interrupt::None, &mut total);
    }
    compare(6, 100, None, Interrupt::None, &mut total);
    for (k, name) in [
        "folded op",
        "complex op",
        "landed then dominated",
        "card moved into a complex deck",
    ]
    .iter()
    .enumerate()
    {
        assert!(
            total[k] > 0,
            "the random worlds never exercised: {name} ({total:?})"
        );
    }
}

/// 中途打断：追加到一半重开会话、本机写入（先做完通道再逐条）、折叠到一半 / 归并到一半重开会话。
#[test]
fn channel_survives_interruptions() {
    let mut total = [0usize; 5];
    for (seed, interrupt) in [
        (31, Interrupt::ReopenWhileAppending),
        (32, Interrupt::LocalWrite),
        (33, Interrupt::ReopenWhileFolding),
        (34, Interrupt::ReopenWhileMerging),
    ] {
        compare(seed, 2, Some(5), interrupt, &mut total);
    }
}

/// 带内置实体的起点上各种世界：远端没直接动过内置实体、改过、删过 / 清除过、同 ID 内容不同。
const SHAPES: [(&str, Shape); 4] = [
    (
        "untouched",
        Shape {
            builtins: true,
            hands_off: true,
            delete: false,
            divergent: false,
        },
    ),
    (
        "edited",
        Shape {
            builtins: true,
            hands_off: false,
            delete: false,
            divergent: false,
        },
    ),
    (
        "deleted",
        Shape {
            builtins: true,
            hands_off: false,
            delete: true,
            divergent: false,
        },
    ),
    (
        "divergent",
        Shape {
            builtins: true,
            hands_off: false,
            delete: true,
            divergent: true,
        },
    ),
];

/// 真实新设备（开库时已写下内置身份记录，BUG-4387）第一次同步：通道被选中，且与逐条投递逐表相同。远端每台设备都带着
/// 同一批内置身份记录（同 ID，与本机那份并发）；各种世界见 [SHAPES]。
#[test]
fn channel_matches_sequential_on_top_of_the_builtins() {
    for (name, shape) in SHAPES {
        let mut total = [0usize; 5];
        for seed in 51..=54u64 {
            compare_from(
                Start::Builtins,
                shape,
                seed,
                2,
                Some(7),
                Interrupt::None,
                &mut total,
            );
        }
        // 全部段一批交进去、一片投完。不用生产的按时间切（`None`）：两台设备的切点会不同，投递顺序跟着不同
        // （`deliver_ready` 每片从第一台设备重新轮），而逐条投影的删除挂起随投递顺序而变——两台都逐条投递、只是片长
        // 不同，结果也不同（与通道无关）。对拍要两边同一个投递顺序。
        compare_from(
            Start::Builtins,
            shape,
            55,
            100,
            Some(100_000),
            Interrupt::None,
            &mut total,
        );
        assert!(
            total[4] > 0,
            "{name}: no identity record met a row that was already there ({total:?})"
        );
        // 因为投影里已有行而不折的只有内置身份记录本身（三个 ID × 写过它们的三台设备，五次运行）：内置实体上的
        // 修改、用内置笔记类型的笔记照常折。
        assert!(
            total[4] <= 5 * 9,
            "{name}: more than the builtin identity records went one by one ({total:?})"
        );
    }
}

/// 裸起点（没有内置行）收带内置实体的世界：原有路径在新世界上照样成立（身份记录全走折叠）。
#[test]
fn channel_matches_sequential_for_a_bare_profile_in_the_builtin_worlds() {
    for (_, shape) in SHAPES {
        let mut total = [0usize; 5];
        compare_from(
            Start::Bare,
            shape,
            56,
            2,
            Some(7),
            Interrupt::None,
            &mut total,
        );
        assert_eq!(total[4], 0, "{shape:?}: nothing was there to collide with");
    }
}

/// v2 之前装的、从没用过的库迁移之后（内置身份记录是迁移包出来的本机操作）：同样走通道、同样逐表相同。
#[test]
fn channel_matches_sequential_on_top_of_migrated_builtins() {
    for (name, shape) in SHAPES {
        let mut total = [0usize; 5];
        compare_from(
            Start::Migrated,
            shape,
            57,
            2,
            Some(7),
            Interrupt::None,
            &mut total,
        );
        compare_from(
            Start::Migrated,
            shape,
            58,
            2,
            Some(5),
            Interrupt::ReopenWhileFolding,
            &mut total,
        );
        assert!(
            total[4] > 0,
            "{name}: no identity record met a row that was already there ({total:?})"
        );
    }
}

/// `srs_entities` 的主键是全局的（不分 profile）：别的 profile 占着世界里某条笔记的 ID 时，逐条投递的
/// `project_entity` 按 ID 看见那一行、比内容；折叠用同一个查法把这条身份记录交给它（以前折叠照折、归并时撞主键报错）。
#[test]
fn a_row_of_another_profile_under_the_same_id_is_met_like_one_by_one() {
    let all = world_of(59, SHAPES[1].1);
    let x = new_device("ch-foreign-x", Start::Builtins);
    x.core
        .writer()
        .unwrap()
        .execute(
            "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES (srs_id(?1), srs_id('0193a1b2-0000-7000-8000-0000000000ff'), 'note', '{}', 0)",
            [note_id(0)],
        )
        .unwrap();
    let y = Device::copy_of(&x, "ch-foreign-y");
    assert!(
        session(&x, &all, 2, Some(7), Interrupt::None),
        "the session took the channel"
    );
    super::channel::sequential(|| session(&y, &all, 2, Some(7), Interrupt::None));
    assert_same(&x, &y, "another profile holds a row under a note's id");
    digest_is_consistent(&x);
}

/// 带内置实体的起点上中途打断：追加到一半重开会话、本机写入、折叠到一半 / 归并到一半重开会话。
#[test]
fn channel_survives_interruptions_on_top_of_the_builtins() {
    for (_, shape) in [SHAPES[1], SHAPES[3]] {
        let mut total = [0usize; 5];
        for (seed, interrupt) in [
            (61, Interrupt::ReopenWhileAppending),
            (62, Interrupt::LocalWrite),
            (63, Interrupt::ReopenWhileFolding),
            (64, Interrupt::ReopenWhileMerging),
        ] {
            compare_from(
                Start::Builtins,
                shape,
                seed,
                2,
                Some(5),
                interrupt,
                &mut total,
            );
        }
    }
}

/// 本机写入那一刻通道里只有撞上本机已有行的内置身份记录：另两台设备的段先到，它们除了开库时写的内置身份记录，
/// 其余操作都依赖还没到的第一台设备、投不出去。通道照样被选中；做完它时一条都不折（六条身份记录全交给逐条的
/// `project_entity`，其中两条内容与本机那行不同），之后的段按逐条投递收，结果与逐条投递相同。
#[test]
fn a_local_write_settles_a_channel_holding_only_identity_records_already_there() {
    let mut all = world_of(62, SHAPES[3].1);
    // 第一台设备的段排到另两台之后。
    all.feed[..3].rotate_left(1);
    let what = "builtins, divergent, seed 62, the first writer fed third, local write half way";
    let covered = compare_world(
        Start::Builtins,
        &all,
        2,
        Some(5),
        Interrupt::LocalWrite,
        what,
    );
    assert_eq!(
        (covered[0], covered[1], covered[4]),
        (0, 6, 6),
        "{what}: the channel held something else when the local write came ({covered:?})"
    );
}

/// 这个 profile 开不开通道（`ingest_begin` 的回报）；开了就原样做完，不留痕迹。
fn opens_channel(d: &Device) -> bool {
    let w = d.core.writer().unwrap();
    let opened = super::channel::begin(&w, P).unwrap();
    super::channel::settle(&w, P).unwrap();
    assert!(!super::channel::active(&w, P).unwrap());
    opened
}

/// 走通道的判据（channel.rs `fresh`）：本机只有开库时自己写的内置身份记录——没有用户数据、没收过别的设备的操作。
#[test]
fn channel_is_for_a_profile_holding_nothing_but_its_own_builtins() {
    let deck = super::config::default_deck_id(P);
    // 裸 profile 与只有内置身份记录的 profile：开。
    let bare = new_device("ch-fresh-bare", Start::Bare);
    {
        let w = bare.core.writer().unwrap();
        assert!(
            super::channel::begin(&w, P).unwrap(),
            "a bare profile opens the channel"
        );
        assert!(
            super::channel::begin(&w, P).unwrap(),
            "an appending channel resumes"
        );
        super::channel::settle(&w, P).unwrap();
        assert!(
            !super::channel::active(&w, P).unwrap(),
            "settled channel leaves no rows"
        );
    }
    let fresh = new_device("ch-fresh", Start::Builtins);
    assert_eq!(
        cmd(&fresh, json!({"op": "ingest_begin"}), vec![])["channel"],
        json!(true),
        "a profile holding only its builtins reports the channel to Dart"
    );
    cmd(&fresh, json!({"op": "ingest_end"}), vec![]);
    assert!(opens_channel(&fresh));

    // 用户数据：每一种都关掉通道。
    let with = |tag: &str, events: Vec<(Value, String)>| {
        let d = new_device(tag, Start::Builtins);
        local(&d, NOW + 1, events);
        d
    };
    for (what, events) in [
        (
            "renamed the builtin deck",
            vec![(edit("deck", &deck, "name", json!("Mine")), String::new())],
        ),
        (
            "edited a builtin note type's template",
            vec![(
                edit(
                    "notetype",
                    NT_LAPIS,
                    "tmplDef/t1",
                    json!({"name": "C", "ord": 0, "front": "{{A}}!"}),
                ),
                String::new(),
            )],
        ),
        (
            "deleted a builtin note type",
            vec![(
                edit("notetype", NT_CARD, "deleted", json!(NOW)),
                String::new(),
            )],
        ),
        (
            "collapsed the builtin deck (view state)",
            vec![(edit("deck", &deck, "collapsed", json!(true)), String::new())],
        ),
        (
            "made a deck of their own",
            vec![(
                json!({"t": "entity", "x": {"id": "0193a1b2-0000-7000-8000-00000000d0c9", "p": P, "k": "deck", "d": {"createdAt": 1}}}),
                String::new(),
            )],
        ),
        (
            "made a note",
            vec![(
                json!({"t": "entity", "x": {"id": note_id(1), "p": P, "k": "note", "d": {"createdAt": 1, "guid": note_id(1), "noteTypeId": NT_LAPIS}}}),
                note_id(1),
            )],
        ),
        (
            "reviewed",
            vec![(review("r1", &card_of(1), NOW, 3, "learn"), note_id(1))],
        ),
        (
            "tagged a note",
            vec![(edit("note", &note_id(1), "tags", json!(["t"])), note_id(1))],
        ),
        (
            "wrote an event this version does not know",
            vec![(json!({"t": "future", "x": {"id": "u1"}}), String::new())],
        ),
    ] {
        let d = with("ch-used", events);
        assert!(
            d.rows("SELECT COUNT(*) FROM sync2_ops")[1][0] != "3",
            "{what}: the write did not reach the log"
        );
        assert!(
            !opens_channel(&d),
            "{what}: user data keeps the channel shut"
        );
    }
    // 还原点、清除：不落投影行的操作也算。
    let d = new_device("ch-checkpoint", Start::Builtins);
    d.core.sync2_checkpoint(P, "manual", "test", NOW).unwrap();
    assert!(!opens_channel(&d), "a restore point is the user's doing");
    let d = new_device("ch-purge", Start::Builtins);
    d.core.sync2_purge(P, "notetype", NT_CARD, NOW).unwrap();
    assert!(!opens_channel(&d), "purged a builtin note type");

    // 收过别的设备的操作（哪怕只是它的内置身份记录）：不开。
    let other = new_device("ch-other", Start::Builtins);
    let mut bucket = Bucket::default();
    other.sync(&mut bucket, "loc", NOW);
    let d = new_device("ch-received", Start::Builtins);
    super::channel::sequential(|| session(&d, &World::of(&bucket), 100, None, Interrupt::None));
    assert_eq!(
        d.rows("SELECT COUNT(*) FROM srs_entities")[1][0],
        "3",
        "the same three builtins"
    );
    assert!(!opens_channel(&d), "ops from another device are in the log");

    // 换过身份：旧身份下的操作不是「本机当前身份写的」。
    let d = new_device("ch-rotated", Start::Builtins);
    d.core.sync2_rotate(P, NOW).unwrap();
    assert!(!opens_channel(&d), "rotated identity");

    // 媒体目录的事实也是操作。
    let d = new_device("ch-media", Start::Builtins);
    d.core
        .sync2_media_record(P, "l/media", &["m.mp3".to_owned()], &[], true, NOW)
        .unwrap();
    assert!(!opens_channel(&d), "recorded media");

    // v2 之前原样留下的不认识的事件行（不经操作日志）。
    let d = new_device("ch-unknown-row", Start::Builtins);
    d.core
        .writer()
        .unwrap()
        .execute(
            "INSERT INTO srs_unknown_events (id, profile_uid, json) VALUES (srs_id('0193a1b2-0000-7000-8000-0000000e0001'), srs_id(?1), '{}')",
            [P],
        )
        .unwrap();
    assert!(!opens_channel(&d), "an unknown legacy event row");

    // 投影行与本机写的身份记录对不上（同 ID 内容不同 / 多一行 / 少一行）：不开。
    let d = new_device("ch-mismatch", Start::Builtins);
    d.core
        .writer()
        .unwrap()
        .execute(
            "UPDATE srs_entities SET payload_json = '{\"builtin\":\"other\"}' WHERE id = srs_id(?1)",
            [&deck],
        )
        .unwrap();
    assert!(!opens_channel(&d), "a row that is not what the op wrote");
    let d = new_device("ch-missing-row", Start::Builtins);
    d.core
        .writer()
        .unwrap()
        .execute("DELETE FROM srs_entities WHERE id = srs_id(?1)", [NT_CARD])
        .unwrap();
    assert!(!opens_channel(&d), "an op whose row is gone");

    // 别的 profile 的东西不算。
    let d = new_device("ch-other-profile", Start::Builtins);
    d.core
        .writer()
        .unwrap()
        .execute(
            "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES (srs_id(?1), srs_id('0193a1b2-0000-7000-8000-0000000000ff'), 'note', '{}', 0)",
            [note_id(1)],
        )
        .unwrap();
    assert!(
        opens_channel(&d),
        "another profile's rows are not this profile's data"
    );

    // v2 之前装的、从没用过的库：迁移之前不开（下面），迁移之后内置行都有本机的操作了，开。
    let d = new_device("ch-migrated", Start::Migrated);
    assert_eq!(d.rows("SELECT COUNT(*) FROM sync2_ops")[1][0], "3");
    assert!(
        opens_channel(&d),
        "a never-used library after its migration"
    );

    // v2 之前的旧库：投影行不经操作日志（还没迁移）。只有内置行也不开——迁移会把它们包成操作。
    let d = new_device("ch-legacy", Start::Bare);
    d.core
        .writer()
        .unwrap()
        .execute(
            "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES (srs_id(?1), srs_id(?2), 'deck', '{\"builtin\":\"default\"}', 0)",
            rusqlite::params![deck, P],
        )
        .unwrap();
    assert!(!opens_channel(&d), "a projected row without an op");
    legacy_library(&d);
    assert!(!opens_channel(&d), "a legacy library");
}

/// 追加途中被打断、下一轮才第一次见到的设备：信任判定（trust.rs `note_new_device`：本机库里已有用户的东西时新见到的
/// 设备待确认，它的删除与清除先扣住）读的是投影，通道在追加阶段时投影里还没有已收下的操作——判之前先把通道做完，
/// 两条路径判得一样、扣住的操作一样、之后放行的结果也一样。
#[test]
fn a_device_first_seen_while_the_channel_is_open_is_judged_like_one_by_one() {
    let a = new_device("ch-trust-a", Start::Builtins);
    let mut bucket = Bucket::default();
    let mut setup = vec![
        (
            edit(
                "notetype",
                NT_LAPIS,
                "fieldDef/fa",
                json!({"name": "A", "ord": 0}),
            ),
            String::new(),
        ),
        (
            edit(
                "notetype",
                NT_LAPIS,
                "tmplDef/t1",
                json!({"name": "C", "ord": 0, "front": "{{A}}"}),
            ),
            String::new(),
        ),
    ];
    for n in 0..6 {
        let note = note_id(n);
        setup.push((json!({"t": "entity", "x": {"id": note, "p": P, "k": "note", "d": {"createdAt": 1, "guid": note, "noteTypeId": NT_LAPIS}}}), note.clone()));
        setup.push((edit("note", &note, "f/fa", json!(format!("w{n}"))), note));
    }
    local(&a, T0, setup);
    a.sync(&mut bucket, "loc", T0 + 1);
    local(
        &a,
        T0 + DAY,
        (0..6)
            .map(|n| {
                (
                    review(
                        &format!("a{n}"),
                        &card_of(n),
                        T0 + DAY + n as i64,
                        3,
                        "learn",
                    ),
                    note_id(n),
                )
            })
            .collect(),
    );
    a.sync(&mut bucket, "loc", T0 + DAY + 1);
    let early = bucket.clone();
    // 之后才加入的设备 C：收下全部，删一条笔记、清除一条、改一条，发出去。
    let c = new_device("ch-trust-c", Start::Builtins);
    c.sync(&mut bucket, "loc", T0 + 2 * DAY);
    local(
        &c,
        T0 + 2 * DAY + 1,
        vec![
            (
                edit("note", &note_id(1), "deleted", json!(T0 + 2 * DAY + 1)),
                note_id(1),
            ),
            (edit("note", &note_id(2), "f/fa", json!("by c")), note_id(2)),
        ],
    );
    c.core
        .sync2_purge(P, "note", &note_id(3), T0 + 2 * DAY + 2)
        .unwrap();
    c.sync(&mut bucket, "loc", T0 + 2 * DAY + 3);
    let c_id = c.core.sync2_identity(P, NOW).unwrap()["device"]
        .as_str()
        .unwrap()
        .to_owned();

    let first = |d: &Device| -> bool {
        // 第一轮：位置上只有 A。各片收完、没收尾就被打断。
        let (heads, segs) = heads_and_segments(&early);
        cmd(d, json!({"op": "plan"}), heads);
        let channel = cmd(d, json!({"op": "ingest_begin"}), vec![])["channel"] == json!(true);
        cmd(d, json!({"op": "ingest_prepare"}), segs);
        while cmd(
            d,
            json!({"op": "ingest_commit", "now": NOW, "sliceOps": 5}),
            vec![],
        )["more"]
            == json!(true)
        {}
        cmd(d, json!({"op": "ingest_end"}), vec![]);
        channel
    };
    // 第二轮：C 出现了。
    let late = World::of(&bucket);
    let second = |d: &Device| session(d, &late, 100, Some(5), Interrupt::None);
    let x = new_device("ch-trust-x", Start::Builtins);
    let y = Device::copy_of(&x, "ch-trust-y");
    let z = Device::copy_of(&x, "ch-trust-z");
    assert!(first(&x), "the first round took the channel");
    assert_eq!(boot_state(&x), Some((0, 0)), "left appending");
    super::channel::take_settle_slices();
    second(&x);
    assert!(
        super::channel::take_settle_slices() > 1,
        "the plan that first sees C settles the channel slice by slice, before its own transaction"
    );
    assert!(!super::channel::sequential(|| {
        let channel = first(&y);
        second(&y);
        channel
    }));
    assert_same(&x, &y, "a device first seen mid-channel");

    // 做到一半出错：做完的片留着，这一轮 plan 什么都没记下（C 还是没见过的设备）；下一轮接着做，结果相同。
    assert!(first(&z));
    super::channel::take_settle_slices();
    super::channel::fail_settle_at(Some(1));
    let err = z
        .core
        .sync2_plan(P, &heads_and_segments(&bucket).0)
        .unwrap_err();
    super::channel::fail_settle_at(None);
    assert!(err.contains("injected settle failure"), "{err}");
    let (phase, cursor) = boot_state(&z).expect("the channel is still there");
    assert!(
        phase >= 1 && (phase, cursor) != (1, 0),
        "the committed slice stays done: ({phase}, {cursor})"
    );
    assert!(z.core.writer().unwrap().is_autocommit());
    assert_eq!(
        z.rows(&format!(
            "SELECT COUNT(*) FROM sync2_devices WHERE device = srs_id('{c_id}')"
        ))[1][0],
        "0",
        "the failed plan recorded nothing"
    );
    second(&z);
    assert_same(&z, &y, "settling before the plan failed once, then resumed");

    for d in [&x, &y] {
        assert_eq!(
            d.rows("SELECT srs_idt(device) AS device, state FROM sync2_trust")[1..],
            [vec![c_id.clone(), super::trust::PENDING.to_string()]],
            "C showed up after this device had the library: pending"
        );
        assert_eq!(
            d.rows("SELECT what, COUNT(*) FROM sync2_trust_held GROUP BY what ORDER BY what")[1..],
            [
                vec!["delete".to_owned(), "2".to_owned()],
                vec!["purge".to_owned(), "1".to_owned()]
            ],
            "its deletions and its purge are held"
        );
        assert_eq!(
            d.rows(&format!(
                "SELECT COUNT(*) FROM srs_field_edits WHERE entity_id = srs_id('{}') AND field_key = 'deleted'",
                note_id(1)
            ))[1][0],
            "0",
            "the held deletion is not in the projection"
        );
    }
    // 信任之后放行：两边仍然逐表相同。
    for d in [&x, &y] {
        let r = cmd(
            d,
            json!({"op": "trust", "device": c_id, "trust": true, "now": NOW}),
            vec![],
        );
        assert_eq!(r["released"], json!(3));
    }
    assert_same(&x, &y, "after trusting the late device");
    digest_is_consistent(&x);
}

/// 开通道那一刻不会有不被信任的设备：库里没有用户的东西时第一次见到的设备不记待确认（trust.rs `note_new_device`），
/// 可信的设备也不能凭空拒绝。之后才出现的设备见上一条；它们的删除与清除在通道里本来就按投递顺序逐条投
/// （有过 `deleted` 写入的实体是复杂实体），信任在生产的 `project_edit_noted` / `project_body` 里判。
#[test]
fn nothing_is_distrusted_when_the_channel_opens() {
    let all = world_of(65, SHAPES[2].1);
    let x = new_device("ch-rej-x", Start::Builtins);
    let (heads, _) = heads_and_segments(&all);
    cmd(&x, json!({"op": "plan"}), heads);
    let devices: Vec<String> = x
        .rows("SELECT srs_idt(device) AS device FROM sync2_devices ORDER BY device")[1..]
        .iter()
        .map(|r| r[0].clone())
        .collect();
    assert!(devices.len() >= 3, "{devices:?}");
    assert_eq!(x.rows("SELECT COUNT(*) FROM sync2_trust")[1][0], "0");
    for d in &devices {
        let err = x.core.sync2_trust(P, d, false, NOW).unwrap_err();
        // 「已经可信」；本机自己那一行是「永远可信」。
        assert!(err.contains("trusted"), "{err}");
    }
    assert_eq!(
        cmd(&x, json!({"op": "ingest_begin"}), vec![])["channel"],
        json!(true)
    );
    cmd(&x, json!({"op": "ingest_end"}), vec![]);
    assert_eq!(x.rows("SELECT COUNT(*) FROM sync2_trust")[1][0], "0");
}

/// 会话外把通道做完（分发器在本机写入前、`channel_settle`）按片提交：中途失败只丢那一片，已做的留着、下一次接着做，
/// 结果与逐条投递相同。以前整段在调用方的一个事务里：失败整段回滚，每条写命令都从头重做。
#[test]
fn settling_commits_slice_by_slice_and_resumes_after_a_failure() {
    settling_resumes_after_a_failure(Start::Bare, world(41));
    settling_resumes_after_a_failure(Start::Builtins, world_of(42, SHAPES[2].1));
}

fn settling_resumes_after_a_failure(start: Start, all: World) {
    let x = new_device("ch-settle-x", start);
    let y = Device::copy_of(&x, "ch-settle-y");
    // 只收完各片、不收尾：通道停在追加阶段。
    let appended = |d: &Device| {
        let (heads, segs) = fed(&all);
        cmd(d, json!({"op": "plan"}), heads);
        let begun = cmd(d, json!({"op": "ingest_begin"}), vec![]);
        for chunk in segs.chunks(2) {
            cmd(d, json!({"op": "ingest_prepare"}), chunk.to_vec());
            while cmd(
                d,
                json!({"op": "ingest_commit", "now": NOW, "sliceOps": 7}),
                vec![],
            )["more"]
                == json!(true)
            {}
        }
        begun
    };
    assert_eq!(
        appended(&x)["channel"],
        json!(true),
        "{start:?}: a fresh profile reports the channel to Dart"
    );
    assert_eq!(boot_state(&x), Some((0, 0)), "appending");
    // 第三片报错：前两片已提交，通道停在折叠里。
    super::channel::take_settle_slices();
    super::channel::fail_settle_at(Some(2));
    let err = cmd_err(&x, json!({"op": "channel_settle"}));
    super::channel::fail_settle_at(None);
    assert!(err.contains("injected settle failure"), "{err}");
    let (phase, cursor) = boot_state(&x).expect("the channel is still there");
    assert!(
        phase >= 1 && (phase, cursor) != (1, 0),
        "the committed slices stay done: ({phase}, {cursor})"
    );
    assert_eq!(
        cmd(&x, json!({"op": "identity", "now": NOW}), vec![])["channel"],
        json!(true),
        "Dart learns the channel at open"
    );
    // 接着做完（不从头来），之后写连接上没有挂着的事务。
    cmd(&x, json!({"op": "channel_settle"}), vec![]);
    assert!(boot_state(&x).is_none(), "settled");
    assert!(
        super::channel::take_settle_slices() > 3,
        "settling is sliced"
    );
    assert!(
        x.core.writer().unwrap().is_autocommit(),
        "every slice committed"
    );
    assert_eq!(
        cmd(&x, json!({"op": "identity", "now": NOW}), vec![])["channel"],
        json!(false)
    );
    let mut r = cmd(&x, json!({"op": "ingest_finish", "now": NOW}), vec![]);
    while r["more"] == json!(true) {
        r = cmd(&x, json!({"op": "replay_pending", "now": NOW}), vec![]);
    }
    super::channel::sequential(|| {
        appended(&y);
        let mut r = cmd(&y, json!({"op": "ingest_finish", "now": NOW}), vec![]);
        while r["more"] == json!(true) {
            r = cmd(&y, json!({"op": "replay_pending", "now": NOW}), vec![]);
        }
    });
    assert_same(&x, &y, "settled slice by slice after a failure");
    digest_is_consistent(&x);
}
