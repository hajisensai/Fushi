//! 出卡读命令 `study`（`cmd/study.rs`）与协议 3 对拍，以及它的语句计划。别名类场景在 `tests_class.rs`。

use std::cell::RefCell;
use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::study::{card_set, log_state, study_stateless};
use super::tests::{N1, N2, N3, Pair, T0, card, library, note, on_p3};
use crate::projection::Day;
use crate::store::gen4::derive::{Index, Ref};
use crate::store::gen4::parity::imported;
use crate::store::gen4::truth::Truth;
use crate::store::queue::StudyHub;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{DAY, Device, P, edit, review};

const CHILD: &str = "DCHILD";
const MIX: &str = "DMIX";
const NEW1: &str = "DNEW";
const N5: &str = "0193a1b2-0000-7000-8000-0000000000a5";
const N6: &str = "0193a1b2-0000-7000-8000-0000000000a6";

/// [library] 再加两个子牌组：`DCHILD`（自己的参数、每日上限 1 / 1、按到期日复习、按位置出新卡，N3 的卡在这里）与
/// `DMIX`（新卡与复习均匀穿插、按难度复习、按位置出新卡，N2 的卡在这里），外加几条今天的复习，让计数、上限截断、学习卡、到期卡、
/// 今天已学 / 已复习都有东西可比。
fn study_library() -> Device {
    let d = library();
    study_extras(&d);
    d
}

/// [study_library] 在 [library] 上加的那些（子牌组、今天的学习步、手动改到期的日志）：迁移来的库（`study_session_tests.rs`）
/// 在协议 3 一侧迁移之前补同一批。
pub(super) fn study_extras(d: &Device) {
    let deck = default_deck_id(P);
    let child = |id: &str| -> Value {
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "deck", "d": {"createdAt": 2}}})
    };
    d.apply(
        T0 + DAY + 70,
        vec![
            child(CHILD),
            edit("deck", CHILD, "name", json!("Child")),
            edit("deck", CHILD, "parent", json!(deck)),
            edit("deck", CHILD, "paramsMode", json!("own")),
            edit("deck", CHILD, "limits", json!({"new": 1, "review": 1})),
            edit("deck", CHILD, "reviewOrder", json!("dueDate")),
            edit("deck", CHILD, "newOrder", json!("position")),
            edit("note", N3, "deck", json!(CHILD)),
            child(MIX),
            edit("deck", MIX, "name", json!("Mix")),
            edit("deck", MIX, "parent", json!(deck)),
            edit("deck", MIX, "paramsMode", json!("own")),
            edit("deck", MIX, "newMix", json!("mixed")),
            edit("deck", MIX, "reviewOrder", json!("difficulty")),
            edit("deck", MIX, "newOrder", json!("position")),
            edit("note", N2, "deck", json!(MIX)),
        ],
    );
    // `DNEW`：新卡上限 2，N5、N6 各两张卡在这里。今天学了 N5 t1（新卡的第一条学习步，重放后 `res.reps` = 1：引入）；
    // N6 t1 前一天学过、今天又走一步学习步（`reps` = 2：不是引入）→ 今天的新卡配额剩 1，N5 t2 / N6 t2 今天只出一张、
    // 明天出两张（[study_counts_todays_new_cards_against_the_new_limit]）。操作里写的 `res.reps` 都是 0，只有按血统
    // 重放写回的那份才分得出这两条。
    d.apply(
        T0 + DAY + 72,
        vec![
            child(NEW1),
            edit("deck", NEW1, "name", json!("New1")),
            edit("deck", NEW1, "parent", json!(deck)),
            edit("deck", NEW1, "paramsMode", json!("own")),
            edit("deck", NEW1, "limits", json!({"new": 2, "review": 50})),
            note(N5, "NT", 50),
            edit("note", N5, "f/fa", json!("魚")),
            edit("note", N5, "f/fb", json!("fish")),
            edit("note", N5, "deck", json!(NEW1)),
            note(N6, "NT", 60),
            edit("note", N6, "f/fa", json!("鳥")),
            edit("note", N6, "f/fb", json!("bird")),
            edit("note", N6, "deck", json!(NEW1)),
        ],
    );
    d.apply(
        T0 + DAY + 73,
        vec![review("s0", &card(N6, "t1"), T0 + 20, 3, "learn")],
    );
    d.apply(
        T0 + DAY + 80,
        vec![
            review("s1", &card(N1, "t2"), T0 + DAY + 80, 3, "learn"),
            review("s2", &card(N3, "t2"), T0 + DAY + 81, 1, "learn"),
            review("s3", &card(N5, "t1"), T0 + DAY + 82, 3, "learn"),
            review("s4", &card(N6, "t1"), T0 + DAY + 84, 3, "learn"),
        ],
    );
    // 窗口里一条不是 `kind = 'review'` 的日志（手动改到期，`rtype` 照写 review）：计数上下文不收它（协议 3 `LOGS_SQL`
    // 的种类过滤）——收了就会把 N3 t1 记成「今天复习过」、多一次作答。
    d.apply(
        T0 + DAY + 83,
        vec![manual("m1", &card(N3, "t1"), T0 + DAY + 83)],
    );
}

/// 一条手动改到期的日志（`kind = 'manual'`）。
fn manual(id: &str, card: &str, at: i64) -> Value {
    let mut m = review(id, card, at, 0, "review");
    m["x"]["kind"] = json!("manual");
    m["x"].as_object_mut().unwrap().remove("rating");
    m["x"]["res"] = json!({"queue": "review", "dueDay": 19_690, "ivl": 3, "step": 0, "reps": 3, "lapses": 0, "scheduler": "fushi"});
    m
}

/// 新代一侧：每次一个新的出卡会话（整份建；会话随写入增量维护的对拍在 `study_session_tests.rs`）。
fn study(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    super::study::study(t, &StudyHub::default(), col, req, None)
}

/// 协议 3 一侧：同一份缓存配置重建缓存表之后，用一个新的会话排一次（`store/study.rs` 的生产路径）。
fn p3_study(p: &Pair<'_>, req: &Value) -> Value {
    let w = p.d.core.writer().unwrap();
    on_p3(&w, &p.cfg, |c| {
        crate::store::study::study(c, &StudyHub::default(), true, P, req).unwrap()
    })
}

fn base(now: i64) -> Value {
    json!({"now": now, "utcOff": 0, "rollover": 4})
}

fn with(now: i64, extra: Value) -> Value {
    let mut r = base(now);
    for (k, v) in extra.as_object().unwrap() {
        r[k] = v.clone();
    }
    r
}

/// 一组请求：几个「此刻」× [requests_at]。
fn requests() -> Vec<Value> {
    [
        T0 + DAY + 100,
        T0 + 2 * DAY + 5,
        T0 + 5 * DAY,
        T0 + 40 * DAY,
    ]
    .into_iter()
    .flat_map(requests_at)
    .collect()
}

/// 此刻 [now] 的一组请求：全部牌组 / 各个根 / 出卡 / 排除 / 自定义学习各模式（会话开始早于今天、在今天之内）/ RWKV。
pub(super) fn requests_at(now: i64) -> Vec<Value> {
    let deck = default_deck_id(P);
    let c1 = card(N1, "t1");
    let mut out = Vec::new();
    {
        out.push(base(now));
        for root in [deck.as_str(), CHILD, MIX, NEW1] {
            out.push(with(now, json!({"deck": root, "pick": true})));
            out.push(with(now, json!({"deck": root, "pick": false})));
        }
        out.push(with(
            now,
            json!({"deck": deck, "pick": true, "exclude": [c1, card(N2, "t1")]}),
        ));
        out.push(with(now, json!({"deck": "no-such-deck", "pick": true})));
        for custom in [
            json!({"since": T0, "mode": "forgotten", "days": 3}),
            json!({"since": T0 + DAY + 75, "mode": "forgotten", "days": 30}),
            json!({"since": T0, "mode": "ahead", "days": 30}),
            json!({"since": T0, "mode": "filter", "states": ["new"]}),
            json!({"since": T0, "mode": "filter", "states": ["learning", "due"], "limit": 2}),
            json!({"since": T0, "mode": "filter", "tags": ["A"]}),
            json!({"since": T0, "mode": "filter", "source": "book:none"}),
            // 会话开始在今天之内（一小时前）：「会话里答过」取常驻会话今天的作答。
            json!({"since": now - 3_600_000, "mode": "filter", "states": ["new", "learning", "due"]}),
        ] {
            out.push(with(
                now,
                json!({"deck": deck, "pick": true, "custom": custom}),
            ));
            out.push(with(
                now,
                json!({"deck": deck, "pick": true, "custom": custom, "exclude": [c1]}),
            ));
        }
        out.push(with(
            now,
            json!({"deck": deck, "pick": true, "rwkv": {
                "decks": {CHILD: [0.9, 0, 0, 0]},
                "cands": [[card(N3, "t1"), CHILD, null, 0.5], [card(N3, "t2"), CHILD, T0 + DAY + 81, 0.95]],
            }}),
        ));
    }
    out
}

/// `study` 与协议 3 逐键相同（这个库没有带盐的 ID，规范 ID 就是原值）。另验场景真有东西：计数非空、出过卡、自定义学习
/// 出过卡。
#[test]
fn study_matches_protocol_3() {
    let d = study_library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let (mut picked, mut custom_picked, mut counted) = (0, 0, 0);
    for req in requests() {
        let old = p3_study(&p, &req);
        let new = study(&t, p.col, &req).unwrap();
        assert!(p.g4.is_autocommit(), "a read leaves no transaction open");
        assert_eq!(old, new, "{req}");
        picked += usize::from(!new["next"].is_null());
        custom_picked += usize::from(!new["next"].is_null() && req.get("custom").is_some());
        counted += new["counts"].as_object().map_or(0, |m| m.len());
    }
    assert!(picked >= 10, "{picked}");
    assert!(custom_picked >= 3, "{custom_picked}");
    assert!(counted >= 20, "{counted}");
    // 缺了日界是调用方的 bug：报错，不留事务。
    assert!(study(&t, p.col, &json!({"now": T0})).is_err());
    assert!(p.g4.is_autocommit());
}

/// 今天已学的新卡占新卡配额：`DNEW`（新卡上限 2）今天引入了 N5 t1、N6 t1 只是又走一步学习步（两条都是学习步日志，
/// 是不是引入只看按血统重放写回的 `res.reps`）。与协议 3 对拍，并验场景本身真的受「今天已引入」影响：今天剩下的两张
/// 新卡只出 1 张（引入恒假会出 2 张、学习步恒算引入会出 0 张）、明天出 2 张，免得对拍退化成两边同样错也能过。另验种类
/// 过滤：窗口里那条手动改到期的日志（`rtype` 写成 review）不进计数上下文。
#[test]
fn study_counts_todays_new_cards_against_the_new_limit() {
    let d = study_library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let (t1, t2) = (card(N5, "t1"), card(N5, "t2"));
    let today = with(T0 + DAY + 100, json!({"deck": NEW1, "pick": true}));
    let tomorrow = with(T0 + 2 * DAY + 5, json!({"deck": NEW1, "pick": true}));
    let now = study(&t, p.col, &today).unwrap();
    assert_eq!(p3_study(&p, &today), now, "{today}");
    let next = study(&t, p.col, &tomorrow).unwrap();
    assert_eq!(p3_study(&p, &tomorrow), next, "{tomorrow}");
    assert_eq!(
        now["counts"][NEW1][0],
        json!(1),
        "one left in the quota: {now}"
    );
    assert_eq!(next["counts"][NEW1][0], json!(2), "a new day: {next}");

    let day = Day {
        utc_offset_min: 0,
        rollover_hour: 4,
    };
    let mut ix = Index::new(&t, p.col);
    let s = log_state(&t, &mut ix, p.col, day, day.index(T0 + DAY + 100)).unwrap();
    assert!(s.introduced(&t1), "{s:?}");
    assert!(!s.introduced(&t2), "{s:?}");
    assert!(
        !s.introduced(&card(N6, "t1")),
        "a second learning step: {s:?}"
    );
    // 手动改到期的那条：不算今天复习过、不算作答。
    let m = card(N3, "t1");
    assert!(!s.reviewed(&m), "{s:?}");
    assert!(s.answers().all(|(c, _)| *c != m), "{s:?}");
}

/// 自定义学习「会话里答过」的卡集合只占一个绑定变量：四万张（远超 SQLite 的 32766 个变量上限）照样能查，结果只认
/// 集合里真有的卡（UUID 与文本 ID 都对得上）。
#[test]
fn custom_study_card_set_is_one_parameter() {
    let d = study_library();
    let p = Pair::new(&d);
    let real: Vec<Ref> =
        p.g4.prepare("SELECT id FROM cards WHERE col = ?1 ORDER BY id")
            .unwrap()
            .query_map([p.col], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
    assert!(real.len() >= 6, "{}", real.len());
    let mut set: BTreeSet<Ref> = (0..40_000u32)
        .map(|i| {
            let mut b = [0xeeu8; 16];
            b[..4].copy_from_slice(&i.to_be_bytes());
            Ref::Uuid(b)
        })
        .collect();
    set.insert(Ref::Text("no-such-card".into()));
    set.extend(real.iter().take(3).cloned());
    let (cond, args) = card_set(&set);
    assert_eq!(args.len(), 1);
    let mut all = vec![rusqlite::types::Value::Integer(p.col)];
    all.extend(args);
    let n: i64 =
        p.g4.query_row(
            &format!("SELECT COUNT(*) FROM cards WHERE col = ? AND {cond}"),
            rusqlite::params_from_iter(all),
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 3);
}

/// 一条命令一个读快照：命令开始时调用方没开事务就自己开、跑完关掉；调用方已在事务里就沿用。
#[test]
fn study_runs_in_the_callers_transaction_when_there_is_one() {
    let d = study_library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let req = with(
        T0 + 5 * DAY,
        json!({"deck": default_deck_id(P), "pick": true}),
    );
    let alone = study(&t, p.col, &req).unwrap();
    p.g4.execute_batch("BEGIN").unwrap();
    let inside = study(&t, p.col, &req).unwrap();
    assert!(!p.g4.is_autocommit(), "the caller's transaction stays open");
    p.g4.execute_batch("COMMIT").unwrap();
    assert_eq!(alone, inside);
}

thread_local! {
    static TRACED: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

/// 出卡的语句都走索引：跑真命令、截下实际执行的语句（参数已展开）逐条 `EXPLAIN QUERY PLAN`。
/// - 缓存层与日志的表没有整表扫描（`SCAN cards` / `notes` / `log_ix` / `stats` / `ops`）；
/// - 新卡按索引序取第一张：走 `cards_new_freq` / `cards_new_position`，没有 TEMP B-TREE；学习卡走 `cards_learning`、
///   没有 TEMP B-TREE；计数原料走 `cards_tally`；R 顺序的到期卡走 `cards_review_due`；
/// - 日志窗口走 `log_at`；「最近评过重来」走 `stats` 的主键区间；「只复习这一作」走 `notes_source`。
#[test]
#[allow(deprecated)]
fn study_queries_use_their_indexes() {
    let d = study_library();
    let (mut g4, _) = imported(&d);
    let col = Truth::new(&g4).binding_of(P).unwrap().unwrap().col;
    g4.trace(Some(|sql: &str| {
        TRACED.with(|t| t.borrow_mut().push(sql.to_owned()));
    }));
    TRACED.with(|t| t.borrow_mut().clear());
    {
        let t = Truth::new(&g4);
        for req in requests() {
            // 生产路径（建会话）与测试基准（逐条 SQL 现读，`study_session_tests.rs` 拿它对拍）都要走索引。
            study(&t, col, &req).unwrap();
            study_stateless(&t, col, &req).unwrap();
        }
    }
    g4.trace(None);
    let stmts: BTreeSet<String> = TRACED.with(|t| t.borrow().iter().cloned().collect());
    let plan = |q: &str| -> String {
        let mut stmt = g4.prepare(&format!("EXPLAIN QUERY PLAN {q}")).unwrap();
        let mut rows = stmt.raw_query();
        let mut out = Vec::new();
        while let Some(r) = rows.next().unwrap() {
            out.push(r.get::<_, String>(3).unwrap());
        }
        out.join("\n")
    };
    let mut bad = Vec::new();
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    for q in &stmts {
        let up = q.trim_start().to_ascii_uppercase();
        if !up.starts_with("SELECT") && !up.starts_with("WITH") {
            continue;
        }
        // 自定义学习「会话里答过」是空集合时条件是常量假（`AND 0`）：SQLite 在进循环之前判一次就结束，计划里的 SCAN
        // 不会真跑。
        if q.contains(" AND 0 ") || q.contains(" AND 0)") || q.ends_with(" AND 0") {
            continue;
        }
        let p = plan(q);
        for step in p.lines() {
            let step = step.trim();
            for table in ["cards", "notes", "log_ix", "stats", "ops"] {
                if step == format!("SCAN {table}") || step.starts_with(&format!("SCAN {table} ")) {
                    bad.push(format!("whole table: {q}\n    {step}"));
                }
            }
            if step == "SCAN n" || step.starts_with("SCAN n ") {
                bad.push(format!("whole table: {q}\n    {step}"));
            }
        }
        let mut want = |label: &'static str, index: &str, sorted: bool| {
            seen.insert(label);
            if !p.contains(index) {
                bad.push(format!("{label}: want {index}\n{q}\n{p}"));
            }
            if sorted && p.contains("TEMP B-TREE") {
                bad.push(format!("{label}: want no TEMP B-TREE\n{q}\n{p}"));
            }
        };
        let custom = q.contains("COALESCE(due_day, 0), new_position IS NULL");
        if q.contains("queue = 'new'") && q.contains("ORDER BY freq_rank IS NULL") {
            want("new(freq)", "cards_new_freq", true);
        } else if q.contains("queue = 'new'") && q.contains("ORDER BY new_position IS NULL") {
            want("new(position)", "cards_new_position", true);
        } else if q.contains("COALESCE(due_at, 0) <= ")
            && q.contains("ORDER BY COALESCE(due_at, 0), id LIMIT 1")
        {
            want("learning", "cards_learning", true);
        } else if q.contains("GROUP BY deck_id") {
            want("tallies", "cards_tally", false);
        } else if q.contains("ORDER BY 1.0 / (1.0 +") {
            want("due(R)", "cards_review_due", false);
        } else if q.contains("FROM log_ix") && q.contains(" id = ") {
            want("logs(id)", "log_id", false);
        } else if q
            .contains("difficulty FROM cards INDEXED BY sqlite_autoindex_cards_1 WHERE col = ")
        {
            // 建会话 / 按 id 重读卡行：主键 (col, id)。
            want("session cards", "USING PRIMARY KEY (col=?", false);
        } else if q.contains("FROM log_ix") && q.contains("at >= ") {
            want("logs", "log_at", false);
        } else if q.contains("FROM stats WHERE col = ") && q.contains("rating = 1") {
            want(
                "forgotten",
                "SEARCH stats USING PRIMARY KEY (col=? AND at>?)",
                false,
            );
        } else if q.contains("source_key = ") {
            want("source", "notes_source", false);
        } else if custom {
            seen.insert("custom");
        }
    }
    assert!(bad.is_empty(), "{}", bad.join("\n\n"));
    for label in [
        "new(freq)",
        "new(position)",
        "learning",
        "tallies",
        "due(R)",
        "logs",
        "forgotten",
        "source",
        "session cards",
    ] {
        assert!(seen.contains(label), "no {label} statement ran: {seen:?}");
    }
    // 会话按规范日志 ID 重读日志（`cmd::logs_of_ids`，只在有写入时跑，上面的请求走不到）：`log_id (col, id, k)`。
    let p = plan(
        "SELECT k FROM log_ix WHERE col = 1 AND id = x'00112233445566778899aabbccddeeff' AND win = 1 AND at >= 0",
    );
    assert!(p.contains("log_id"), "{p}");
}
