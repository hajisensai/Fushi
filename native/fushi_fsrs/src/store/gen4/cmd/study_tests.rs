//! 出卡读命令 `study`（`cmd/study.rs`）与协议 3 对拍，以及它的语句计划。别名类场景在 `tests_class.rs`。

use std::cell::RefCell;
use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::study::study;
use super::tests::{N1, N2, N3, Pair, T0, card, library, on_p3};
use crate::store::gen4::parity::imported;
use crate::store::gen4::truth::Truth;
use crate::store::queue::StudyHub;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{DAY, Device, P, edit, review};

const CHILD: &str = "DCHILD";
const MIX: &str = "DMIX";

/// [library] 再加两个子牌组：`DCHILD`（自己的参数、每日上限 1 / 1、按到期日复习、按位置出新卡，N3 的卡在这里）与
/// `DMIX`（新卡与复习均匀穿插、按难度复习、按位置出新卡，N2 的卡在这里），外加几条今天的复习，让计数、上限截断、学习卡、到期卡、
/// 今天已学 / 已复习都有东西可比。
fn study_library() -> Device {
    let d = library();
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
    d.apply(
        T0 + DAY + 80,
        vec![
            review("s1", &card(N1, "t2"), T0 + DAY + 80, 3, "learn"),
            review("s2", &card(N3, "t2"), T0 + DAY + 81, 1, "learn"),
        ],
    );
    d
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

/// 一组请求：几个「此刻」× 全部牌组 / 各个根 / 出卡 / 排除 / 自定义学习各模式 / RWKV。
fn requests() -> Vec<Value> {
    let deck = default_deck_id(P);
    let c1 = card(N1, "t1");
    let mut out = Vec::new();
    for now in [
        T0 + DAY + 100,
        T0 + 2 * DAY + 5,
        T0 + 5 * DAY,
        T0 + 40 * DAY,
    ] {
        out.push(base(now));
        for root in [deck.as_str(), CHILD, MIX] {
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
            study(&t, col, &req).unwrap();
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
    ] {
        assert!(seen.contains(label), "no {label} statement ran: {seen:?}");
    }
}
