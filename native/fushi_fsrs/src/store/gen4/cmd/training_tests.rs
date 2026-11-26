//! 评分预览 `preview`（`cmd/preview.rs`）与逐卡重放 / 训练集直读命令（`cmd/training.rs`）和协议 3 对拍，以及它们的语句计划。
//! 别名类场景在 `tests_class.rs`。
//!
//! 同一个协议 3 的库（[train_library]：[library] 再加几天的复习、一条撤销、一张继承历史的后继卡上的复习），协议 3 一侧在
//! 写连接的 SAVEPOINT 里跑同一份计算（`on_p3`：先做完欠着的收尾），新代一侧把库灌进新代再跑 `cmd`。输出逐字节比；只有
//! 指纹里的「最大序号」两代各是各的游标（协议 3 rowid、新代操作主键，`cmd/training.rs` 文件头），比之前两边都置零，且
//! 传进去的 `since` / `rebase_since` 按同一条日志换成各自的序号。

use rusqlite::Connection;
use serde_json::{Value, json};

use super::preview::{NOTE_SQL, preview};
use super::tests::{N1, N2, N3, N4, Pair, T0, card, library, on_p3};
use super::training::{
    COUNT_SINCE_SQL, COUNT_SQL, SCAN_SQL, TAIL_SQL, calibration_items, history_states,
    optimizer_items, rwkv_cards, rwkv_log_tail, rwkv_replay, stat_projection,
};
use crate::gen4::op::tests::id;
use crate::gen4::op::{Body4, Log4};
use crate::projection::{Alg, Day};
use crate::store::gen4::cache::LOG_REP_SQL;
use crate::store::gen4::derive::{Ref, SEQ_BASE, SEQ_INSERT_SQL};
use crate::store::gen4::truth::Truth;
use crate::store::projections::{self, RwkvRange};
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{DAY, Device, P, edit, review};
use crate::sync2::id::Key;
use crate::sync2::op::Intent;

const D: Day = Day {
    utc_offset_min: 0,
    rollover_hour: 4,
};

fn undo(id: &str, card: &str, target: &str, at: i64) -> Value {
    json!({"t": "log", "x": {
        "id": id, "p": P, "card": card, "kind": "undo", "revokes": target,
        "hlc": format!("{at}:0:dart"), "at": at, "ts": "anchored", "origin": "fushi", "rtype": "manual",
        "utcOff": 0, "rollover": 4, "fv": 1
    }})
}

/// [library] 再加几天的复习：后继卡 c2（N1 t2，历史继承自 c1）、N2 t1 各复习几次，N2 t1 的一次被撤销，N3 t2 一条学习步。
fn train_library() -> Device {
    let d = library();
    let (c2, n2, n3b) = (card(N1, "t2"), card(N2, "t1"), card(N3, "t2"));
    let at = |days: i64, ms: i64| T0 + days * DAY + ms;
    d.apply(at(2, 0), vec![review("q1", &c2, at(2, 0), 3, "review")]);
    d.apply(at(3, 0), vec![review("q2", &n2, at(3, 0), 3, "review")]);
    d.apply(
        at(5, 5),
        vec![
            review("q3", &c2, at(5, 0), 2, "review"),
            review("q4", &n2, at(5, 5), 4, "review"),
        ],
    );
    d.apply(at(6, 0), vec![undo("u1", &n2, "q4", at(6, 0))]);
    d.apply(
        at(8, 0),
        vec![
            review("q5", &n3b, at(7, 0), 1, "learn"),
            review("q6", &n2, at(8, 0), 3, "review"),
        ],
    );
    d
}

/// 预览的归属组笔记夹具：[train_library] 再加一个子牌组 [PREV_DECK]（笔记 N3 的首选牌组），以及三张没有卡片记录、
/// 也就没有 deck 标志的卡（有效牌组只看归属组的笔记：`config::card_deck_with`「笔记首选牌组」那一级）：
/// - 后继卡 [SUCC]（自己没有日志，历史继承自 [PRED]）：前身的日志上记的笔记是 N3，调用方给的是别的笔记（取前身日志上
///   记的，牌组是 [PREV_DECK]；调用方的笔记优先就成了默认牌组）；
/// - 链尾 [TAIL] 的两条日志先后记了 N1、N3（链尾里最后一条记了笔记的优先：N3、[PREV_DECK]；取第一条就成了 N1、默认
///   牌组）。
fn preview_library() -> Device {
    let d = train_library();
    let (succ, pred, tail) = (SUCC, PRED, TAIL);
    // 日志上记的笔记是本地写入信封里的 `note`（`Device::apply` 一律填 N1）。
    let noted = |lid: &str, c: &str, note: &str, at: i64| {
        let input = json!([{"e": review(lid, c, at, 3, "review"), "note": note}]);
        d.core.sync2_apply_local(P, at, &input.to_string()).unwrap();
    };
    let at = T0 + 8 * DAY + 100;
    d.apply(
        at,
        vec![
            json!({"t": "entity", "x": {"id": PREV_DECK, "p": P, "k": "deck", "d": {"createdAt": 2}}}),
            edit("deck", PREV_DECK, "name", json!("Prev")),
            edit("deck", PREV_DECK, "parent", json!(default_deck_id(P))),
            edit("note", N3, "deck", json!(PREV_DECK)),
            edit("card", succ, &format!("historyFrom/{pred}"), json!(true)),
        ],
    );
    noted("w1", pred, N3, at + 10);
    noted("w2", tail, N1, at + 20);
    noted("w3", tail, N3, at + 30);
    d
}

const PREV_DECK: &str = "DPREV";
const SUCC: &str = "XSUCC";
const PRED: &str = "XPRED";
const TAIL: &str = "XTAIL";

/// 训练集 / RWKV 的输入：每张卡一份（调用方只给卡自己），含一张不存在的卡与一张后继卡在前身之前。
fn seeds() -> Vec<Vec<String>> {
    vec![
        vec![card(N1, "t2")],
        vec![card(N1, "t1")],
        vec![card(N2, "t1")],
        vec![card(N3, "t1")],
        vec![card(N3, "t2")],
        vec!["missing".to_owned()],
    ]
}

/// 第 [k] 个 8 字节字置零（指纹里的「最大序号」）。
fn zero_word(mut b: Vec<u8>, k: usize) -> Vec<u8> {
    b[8 * k..8 * k + 8].fill(0);
    b
}

/// 两边各自的日志序号（协议 3 rowid、新代落库序 `log_seq.n`），按序号升序，连同日志 ID。灌库时新代按设备逐台建索引，
/// 所以两边的序只在若干个前缀上圈进同一批日志（[aligned]；这个库里另一台设备的 r3 在协议 3 排第四、在新代排最后）。
/// 两边圈进同一批日志的前缀长度（含 0 与全部）。
fn aligned(p: &Pair<'_>, w: &Connection) -> Vec<usize> {
    let (old, new) = (p3_rowids(p, w), g4_keys(p));
    assert_eq!(old.len(), new.len());
    let mut a = std::collections::BTreeSet::new();
    let mut b = std::collections::BTreeSet::new();
    let mut out = vec![0];
    for i in 0..old.len() {
        a.insert(p.canon(&old[i].1));
        b.insert(new[i].1.clone());
        if a == b {
            out.push(i + 1);
        }
    }
    out
}

fn p3_rowids(p: &Pair<'_>, w: &Connection) -> Vec<(i64, String)> {
    on_p3(w, &p.cfg, |c| {
        c.prepare(
            "SELECT rowid, srs_idt(id) FROM srs_review_logs WHERE profile_uid = srs_id(?1) ORDER BY rowid",
        )
        .unwrap()
        .query_map([P], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
    })
}

fn g4_keys(p: &Pair<'_>) -> Vec<(i64, String)> {
    p.g4.prepare(
        "SELECT s.n, l.id FROM log_seq s JOIN log_ix l ON l.col = s.col AND l.card = s.card AND l.k = s.k \
         WHERE s.col = ?1 ORDER BY s.n",
    )
        .unwrap()
        .query_map([p.col], |r| Ok((r.get(0)?, r.get::<_, Ref>(1)?.text())))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// 「第 [n] 条日志及之前」在两边的序号：协议 3 第 n 条的 rowid，新代同一批日志里最大的 k（并核对两边圈进来的是同一批）。
fn cut(p: &Pair<'_>, w: &Connection, n: usize) -> (i64, i64) {
    let (old, new) = (p3_rowids(p, w), g4_keys(p));
    assert_eq!(old.len(), new.len());
    let before: std::collections::BTreeSet<String> =
        old[..n].iter().map(|(_, id)| p.canon(id)).collect();
    let k = new
        .iter()
        .filter(|(_, id)| before.contains(id))
        .map(|(k, _)| *k)
        .max()
        .unwrap_or(0);
    let mine: std::collections::BTreeSet<String> = new
        .iter()
        .filter(|(x, _)| *x <= k)
        .map(|(_, id)| id.clone())
        .collect();
    assert_eq!(
        mine, before,
        "the two orders put the same logs before the cut: {old:?} / {new:?}"
    );
    (old.get(n.wrapping_sub(1)).map_or(0, |(r, _)| *r), k)
}

#[test]
fn history_states_and_stat_projection_match_protocol_3() {
    let d = train_library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let w = d.core.writer().unwrap();
    let (c1, c2) = (card(N1, "t1"), card(N1, "t2"));
    let groups = vec![
        vec![c2.clone(), c1.clone()],
        vec![c1.clone()],
        vec![card(N2, "t1")],
        vec![card(N3, "t1")],
        vec![card(N3, "t2")],
        vec![card(N4, "t1")],
        vec!["missing".to_owned()],
        vec![],
    ];
    let old = on_p3(&w, &p.cfg, |c| {
        let logs = crate::store::logs_of(c, &groups).unwrap();
        (
            crate::store::history_states_of(&groups, &logs).unwrap(),
            crate::store::stat_projection_of(&groups, &logs).unwrap(),
        )
    });
    let states = history_states(&t, p.col, &groups).unwrap();
    assert!(p.g4.is_autocommit());
    assert_eq!(old.0, states, "history_states");
    let stats = stat_projection(&t, p.col, &groups).unwrap();
    assert_eq!(old.1, stats, "stat_projection");
    // 有东西可比：撤销、继承历史都在里面。
    let (_, rows) = crate::store::rows::decode(&stats).unwrap();
    assert!(rows.len() >= 6, "{}", rows.len());
}

#[test]
fn training_sets_and_rwkv_cards_match_protocol_3() {
    let d = train_library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let w = d.core.writer().unwrap();
    let groups = seeds();
    let card_ids: Vec<i64> = (1..=groups.len() as i64).collect();
    let rwkv_ids: Vec<i64> = (1..=4 * groups.len() as i64).collect();
    for alg in [Alg::Fsrs6, Alg::Fsrs7] {
        let (old_opt, old_cal) = on_p3(&w, &p.cfg, |c| {
            let (g, logs) = projections::training_groups_on(c, &groups).unwrap();
            (
                projections::optimizer_items_of(&g, &logs, &card_ids, alg, &D).unwrap(),
                projections::calibration_items_of(&g, &logs, &card_ids, alg, &D).unwrap(),
            )
        });
        let opt = optimizer_items(&t, p.col, &groups, &card_ids, alg, &D).unwrap();
        assert_eq!(old_opt, opt, "optimizer {alg:?}");
        // 有条目可比（头段第三个字 = n_items）。
        assert!(i64::from_le_bytes(opt[16..24].try_into().unwrap()) > 0);
        let cal = calibration_items(&t, p.col, &groups, &card_ids, alg, &D).unwrap();
        assert_eq!(old_cal, cal, "calibration {alg:?}");
    }
    let old = on_p3(&w, &p.cfg, |c| {
        let (g, logs) = projections::training_groups_on(c, &groups).unwrap();
        projections::rwkv_cards_of(&g, &logs, &rwkv_ids, &D).unwrap()
    });
    assert_eq!(old, rwkv_cards(&t, p.col, &groups, &rwkv_ids, &D).unwrap());
    assert!(p.g4.is_autocommit());
    // 参数个数不对：报错，不留事务。
    assert!(optimizer_items(&t, p.col, &groups, &card_ids[1..], Alg::Fsrs6, &D).is_err());
    assert!(rwkv_cards(&t, p.col, &groups, &card_ids, &D).is_err());
    assert!(p.g4.is_autocommit());
}

#[test]
fn rwkv_replay_and_log_tail_match_protocol_3() {
    let d = train_library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let w = d.core.writer().unwrap();
    // 只列两张卡：别的卡的日志都是「漏掉的卡」。
    let groups = vec![vec![card(N1, "t2")], vec![card(N2, "t1")]];
    let ids: Vec<i64> = (1..=8).collect();
    let n = p3_rowids(&p, &w).len();
    assert!(n >= 10, "{n}");
    let al = aligned(&p, &w);
    let mid: Vec<usize> = al.iter().copied().filter(|&x| x > 0 && x < n).collect();
    assert!(mid.len() >= 2, "need cuts inside the history: {al:?}");
    let (m0, m) = (mid[0], mid[mid.len() - 1]);
    // (第几条之前算「列卡之前」, 局部重放从第几条之后, rows_from)。
    let cases: Vec<(usize, Option<usize>, Option<i64>)> = vec![
        (0, None, None),
        (n, None, None),
        (m, None, None),
        (n, Some(m), None),
        (n, Some(n), None),
        (n, Some(m0), Some(T0)),
        (n, Some(m0), None),
        (m, Some(m0), None),
    ];
    for (s, rebase, rows_from) in cases {
        let (s3, s4) = cut(&p, &w, s);
        let rb = rebase.map(|r| cut(&p, &w, r));
        let range3 = RwkvRange {
            rebase_since: rb.map(|r| r.0),
            rows_from,
        };
        let range4 = RwkvRange {
            rebase_since: rb.map(|r| r.1),
            rows_from,
        };
        let old = on_p3(&w, &p.cfg, |c| {
            projections::rwkv_scan_on(c, P, &groups, s3, range3)
                .unwrap()
                .finish(&ids, &D)
                .unwrap()
        });
        let new = rwkv_replay(&t, p.col, &groups, &ids, &D, s4, range4).unwrap();
        assert_eq!(
            zero_word(old, 1),
            zero_word(new.clone(), 1),
            "since {s} rebase {rebase:?} rows_from {rows_from:?}"
        );
        assert_eq!(
            i64::from_le_bytes(new[8..16].try_into().unwrap()),
            g4_keys(&p).last().unwrap().0,
            "maxRowId is the largest arrival number"
        );
    }
    assert!(p.g4.is_autocommit());

    for s in al {
        let (s3, s4) = cut(&p, &w, s);
        for (with_rows, incremental) in [(true, false), (false, false), (true, true), (false, true)]
        {
            let old = on_p3(&w, &p.cfg, |c| {
                projections::rwkv_log_tail_on(c, P, s3, with_rows, incremental).unwrap()
            });
            let new = rwkv_log_tail(&t, p.col, s4, with_rows, incremental).unwrap();
            assert_eq!(
                zero_word(old, 1),
                zero_word(new, 1),
                "since {s} with_rows {with_rows} incremental {incremental}"
            );
        }
    }
    assert!(p.g4.is_autocommit());
}

#[test]
fn preview_matches_protocol_3() {
    let d = preview_library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let w = d.core.writer().unwrap();
    let canon = |v: &Value| -> Value {
        let mut v = v.clone();
        for k in ["note", "deck"] {
            if let Some(s) = v[k].as_str() {
                v[k] = json!(p.canon(s));
            }
        }
        v
    };
    let cards = [
        card(N1, "t2"),
        card(N1, "t1"),
        card(N2, "t1"),
        SUCC.to_owned(),
        PRED.to_owned(),
        TAIL.to_owned(),
        card(N3, "t1"),
        card(N3, "t2"),
        card(N4, "t1"),
        "missing".to_owned(),
    ];
    let mut seen = 0;
    let mut in_prev: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    for c in &cards {
        for note in [None, Some(N1), Some(N3)] {
            for (now, off, roll) in [(T0 + 9 * DAY, 0, 4), (T0 + 20 * DAY + 7, 540, 0)] {
                let old = on_p3(&w, &p.cfg, |x| {
                    crate::store::sync2::preview_on(x, P, c, note, now, off, roll).unwrap()
                });
                let new = preview(&t, p.col, c, note, now, off, roll).unwrap();
                assert!(p.g4.is_autocommit());
                assert_eq!(canon(&old), new, "{c} {note:?} {now}");
                if new["current"]["reps"].as_i64().unwrap_or(0) > 0 {
                    seen += 1;
                }
                if new["deck"].as_str() == Some(p.canon(PREV_DECK).as_str()) {
                    *in_prev.entry(c.clone()).or_default() += 1;
                }
            }
        }
    }
    assert!(seen > 0, "some previews replay logs");
    // 归属组的笔记取日志上记的：继承历史的 [SUCC]、链尾最后一条记了 N3 的 [TAIL] 在每种调用方笔记下都落在 N3 的牌组。
    assert_eq!(
        in_prev.get(SUCC).copied().zip(in_prev.get(TAIL).copied()),
        Some((6, 6)),
        "{in_prev:?}"
    );
}

/// 新代一侧的语句：指纹、尾巴、回放扫描沿 `log_seq` 主键（增量计数与尾巴是 n 的一段区间，扫描按 n 不排序），预览读卡片
/// 缓存行走主键。
#[test]
fn fingerprint_tail_and_scan_statements_use_the_arrival_order() {
    let d = library();
    let p = Pair::new(&d);
    let plan = |q: &str| -> Vec<String> {
        p.g4.prepare(&format!("EXPLAIN QUERY PLAN {q}"))
            .unwrap()
            .raw_query()
            .mapped(|r| r.get::<_, String>(3))
            .collect::<Result<_, _>>()
            .unwrap()
    };
    for q in [COUNT_SINCE_SQL, TAIL_SQL] {
        let steps = plan(q);
        assert!(
            steps
                .iter()
                .any(|s| s.contains("log_seq USING PRIMARY KEY (col=? AND n>?)")),
            "{q}: {steps:?}"
        );
    }
    for q in [COUNT_SQL, SCAN_SQL] {
        let steps = plan(q);
        assert!(
            steps
                .iter()
                .any(|s| s.starts_with("SEARCH log_seq") && s.ends_with("(col=?)")),
            "{q}: {steps:?}"
        );
        assert!(
            !steps
                .iter()
                .any(|s| s.starts_with("SCAN") || s.contains("TEMP B-TREE")),
            "{q}: {steps:?}"
        );
    }
    let steps = plan(NOTE_SQL);
    assert!(
        steps
            .iter()
            .any(|s| s.contains("cards USING PRIMARY KEY (col=? AND id=?)")),
        "{NOTE_SQL}: {steps:?}"
    );
    // 判别名类代表的点查（每行尾巴每个成员一次）：走 `log_id (col, id, k)`，不按 `log_ix` 主键 (col=?) 扫整个集合。
    let steps = plan(LOG_REP_SQL);
    assert!(
        steps
            .iter()
            .any(|s| s.contains("log_ix USING") && s.contains("INDEX log_id (col=? AND id=?)")),
        "{LOG_REP_SQL}: {steps:?}"
    );
    // 每条日志进索引时取落库序：`log_seq` 主键上的 MAX（不扫、不建临时表）。
    let steps = plan(SEQ_INSERT_SQL);
    assert!(
        steps
            .iter()
            .any(|s| s == "SEARCH log_seq USING PRIMARY KEY (col=?)"),
        "{SEQ_INSERT_SQL}: {steps:?}"
    );
    assert!(
        !steps
            .iter()
            .any(|s| s.starts_with("SCAN") || s.contains("TEMP B-TREE")),
        "{SEQ_INSERT_SQL}: {steps:?}"
    );
}

/// 换代前（协议 3）留下的 RWKV 主快照指纹与检查点在新库上必不可用：RWKV 状态机（`fushi_rwkv` `sched/machine.rs`）只按
/// (行数, 最大 rowid) 判，协议 3 的 rowid 与落库序若都从 1 起连续、两边圈进的日志却不是同一批（[aligned]），旧检查点的
/// `count - tailRows` 核对会照样通过。落库序从 [SEQ_BASE] 起，两代的游标空间不相交。
#[test]
fn protocol_3_checkpoints_and_fingerprints_never_fit_the_new_library() {
    let d = train_library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let w = d.core.writer().unwrap();
    let groups = vec![vec![card(N1, "t2")], vec![card(N2, "t1")]];
    let ids: Vec<i64> = (1..=8).collect();
    let word = |b: &[u8], k: usize| i64::from_le_bytes(b[8 * k..8 * k + 8].try_into().unwrap());
    let old = p3_rowids(&p, &w);
    let n = old.len() as i64;
    // 前提：协议 3 这一侧 rowid 就是 1..C（与从 1 起编号的落库序撞得上的情形）。
    assert_eq!(
        old.iter().map(|(r, _)| *r).collect::<Vec<_>>(),
        (1..=n).collect::<Vec<_>>()
    );
    // 检查点：协议 3 每个前缀的检查点 print (count = i, maxRowId = rowid_i)，照状态机的调法局部重放。
    for (i, (r, _)) in old.iter().enumerate() {
        let count = i as i64 + 1;
        let range = RwkvRange {
            rebase_since: Some(*r),
            rows_from: Some(T0),
        };
        let out = rwkv_replay(&t, p.col, &groups, &ids, &D, *r, range).unwrap();
        let (c, tail_rows) = (word(&out, 0), word(&out, 6));
        assert_eq!(c, n);
        assert_ne!(
            c - tail_rows,
            count,
            "a protocol 3 checkpoint at rowid {r} must not fit the new library"
        );
        assert_eq!(c - tail_rows, 0, "every arrival number is after any rowid");
    }
    // 主快照：新库的指纹行数一样，最大序号恒大于协议 3 的最大 rowid（指纹必不相等）。
    let fp = rwkv_log_tail(&t, p.col, 0, false, false).unwrap();
    let old_max = old.last().unwrap().0;
    assert_eq!(word(&fp, 0), n);
    assert!(word(&fp, 1) > old_max, "{} vs {old_max}", word(&fp, 1));
    assert!(p.g4.is_autocommit());
}

/// 一条复习日志（落在卡 [card] 上）。
fn log_op(lid: u8, card: u8, at: i64) -> Body4 {
    Body4::Log(Log4 {
        id: Key::Uuid(id(lid)),
        card: Key::Uuid(id(card)),
        note: None,
        kind: "review".into(),
        rating: Some(3),
        revokes: None,
        at,
        ts: 1,
        origin: "fushi".into(),
        rtype: "review".into(),
        dur: 1000,
        params: None,
        alg: None,
        utc_off: 0,
        rollover: 4,
        anki_id: None,
        fv: 1,
        intent: Intent::Absolute,
        res: Some(
            json!({"queue": "review", "ivl": 3, "step": 0, "reps": 1, "lapses": 0, "scheduler": "fushi", "dueDay": 1})
                .to_string(),
        ),
        extra: "{}".into(),
        hlc: None,
        server_time: None,
    })
}

/// 落库序（新代独有）：下标小的设备晚到的日志排在已有的之后、增量尾巴看得见它（操作主键排在前面也一样）；整层重建
/// 不改已有的序号；同一个规范日志 ID 的两份带盐导入在尾巴里只出代表那一份，指纹两份都数。
#[test]
fn arrival_order_counts_late_logs_of_low_devices_as_new_and_survives_rebuilds() {
    use crate::store::gen4::derive::Index;
    use crate::store::gen4::derive::tests::{native, op, with};
    with(|t, col| {
        let land = |dev: u8, seq: u64, body: Body4| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                native(t, &mut ix, col, &op(dev, seq, 100 + seq as i64, &[], &body));
                ix.settle()?;
                Ok(())
            })
            .unwrap();
        };
        // 0xb1 先被见到（下标小），0xb2 后到；然后 0xb1 的第二条才到——它的操作主键小于 0xb2 的。
        land(0xb1, 1, log_op(0x51, 0x01, T0));
        land(0xb2, 1, log_op(0x52, 0x02, T0 + 1));
        let tail_since = |since: i64| rwkv_log_tail(t, col, since, true, true).unwrap();
        let fp = tail_since(0);
        let word = |b: &[u8], k: usize| i64::from_le_bytes(b[8 * k..8 * k + 8].try_into().unwrap());
        assert_eq!((word(&fp, 0), word(&fp, 1)), (2, SEQ_BASE + 2));
        land(0xb1, 2, log_op(0x53, 0x01, T0 + 2));
        let keys: Vec<(i64, i64)> = t
            .conn()
            .prepare("SELECT n, k FROM log_seq WHERE col = ?1 ORDER BY n")
            .unwrap()
            .query_map([col], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(keys.len(), 3);
        assert!(
            keys[2].1 < keys[1].1,
            "the late log has the smaller op key: {keys:?}"
        );
        let new = tail_since(SEQ_BASE + 2);
        // 增量：1 行新增、最大序号 SEQ_BASE + 3、尾巴就是它。
        assert_eq!(
            (word(&new, 0), word(&new, 1), word(&new, 2), word(&new, 3)),
            (1, SEQ_BASE + 3, 1, 1)
        );
        let s = String::from_utf8_lossy(&new);
        assert!(s.contains(&id(0x53).text()), "{s}");
        // 整层重建：序号不变，指纹与尾巴逐字节相同。
        let before = rwkv_log_tail(t, col, SEQ_BASE + 1, true, false).unwrap();
        t.tx(|t| Index::new(t, col).rebuild_all().map(|_| ()))
            .unwrap();
        let after: Vec<(i64, i64)> = t
            .conn()
            .prepare("SELECT n, k FROM log_seq WHERE col = ?1 ORDER BY n")
            .unwrap()
            .query_map([col], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(keys, after);
        assert_eq!(
            before,
            rwkv_log_tail(t, col, SEQ_BASE + 1, true, false).unwrap()
        );
        assert!(t.conn().is_autocommit());
    });
}

/// BUG-5547（反馈 gPPVTfHm1b）：按 `CACHE_RULES` 6 物化的库（`rwkv_last` 是空的）开库时不整层重建——`cache_config_set`
/// 只记下当前修订号与回填游标，回包 `rwkvLastFill`；回填完成前末条读（`rwkv_last`）对没填到的卡逐卡重放，结果与填满后
/// 逐卡相同；`rwkv_last_fill` 一批一笔推进，填完删游标，表与整层重建逐行相同；整份物化也删游标。
#[test]
fn rwkv_last_backfills_in_batches_after_an_in_place_rules_upgrade() {
    use super::training::{rwkv_last, rwkv_last_fill};
    use crate::store::gen4::cache::{CACHE_RULES, RULES_KEY, RWKV_FILL_FROM, RWKV_FILL_KEY};
    use crate::store::gen4::derive::Index;
    use crate::store::gen4::dispatch::cache_config_set;

    let d = train_library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let col = p.col;
    let caches: Value = serde_json::from_str(&p.cfg).unwrap();
    let cards: Vec<String> = {
        let mut stmt =
            p.g4.prepare("SELECT id FROM cards WHERE col = ?1 ORDER BY id")
                .unwrap();
        stmt.query_map([col], |r| r.get::<_, Ref>(0))
            .unwrap()
            .map(|r| r.unwrap().text())
            .collect()
    };
    assert!(cards.len() >= 3, "{cards:?}");
    let table = |p: &Pair<'_>| -> Vec<(String, i64, i64, i64)> {
        let mut stmt = p
            .g4
            .prepare("SELECT card, at, rating, rtype FROM rwkv_last WHERE col = ?1 ORDER BY card")
            .unwrap();
        stmt.query_map([col], |r| {
            Ok((r.get::<_, Ref>(0)?.text(), r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .unwrap()
        .map(|r| r.unwrap())
        .collect()
    };
    let want = rwkv_last(&t, col, &cards).unwrap();
    let full = table(&p);
    assert!(!full.is_empty(), "夹具里要有保留评分");

    // 退回 6 的样子：表空、修订号 6、没有游标。
    let from = RWKV_FILL_FROM.expect("当前口径能从 6 就地升级");
    t.tx(|t| {
        t.conn()
            .execute("DELETE FROM rwkv_last WHERE col = ?1", [col])
            .unwrap();
        t.set_derive_cfg(col, RULES_KEY, Some(&from.to_string()))?;
        Ok(())
    })
    .unwrap();

    let v = t.tx(|t| cache_config_set(t, col, &caches)).unwrap();
    assert_eq!(
        v,
        json!({"changed": false, "rwkvLastFill": true}),
        "不整层重建"
    );
    assert!(table(&p).is_empty(), "开库不填表");
    assert_eq!(
        t.derive_cfg(col, RULES_KEY).unwrap(),
        Some(CACHE_RULES.to_string())
    );
    assert_eq!(
        t.derive_cfg(col, RWKV_FILL_KEY).unwrap(),
        Some(String::new())
    );
    assert_eq!(
        rwkv_last(&t, col, &cards).unwrap(),
        want,
        "没填的卡逐卡重放"
    );
    // 回填没做完时再开：回包照样带 rwkvLastFill，宿主接着填。
    let v = t.tx(|t| cache_config_set(t, col, &caches)).unwrap();
    assert_eq!(v, json!({"changed": false, "rwkvLastFill": true}));

    // 一批一张：每一步之后读到的都与填满后相同；n 张卡 n + 1 步（最后一步取到空批 = 填完）。
    let mut steps = 0;
    loop {
        let r = t.tx(|t| rwkv_last_fill(t, col, 1)).unwrap();
        steps += 1;
        assert_eq!(rwkv_last(&t, col, &cards).unwrap(), want, "第 {steps} 步");
        if r["done"] == json!(true) {
            break;
        }
        assert_eq!(r["filled"], json!(1), "{r}");
        assert!(steps <= cards.len(), "回填不收敛");
    }
    assert_eq!(steps, cards.len() + 1);
    assert_eq!(t.derive_cfg(col, RWKV_FILL_KEY).unwrap(), None);
    assert_eq!(table(&p), full, "回填结果与整层物化逐行相同");
    let v = t.tx(|t| cache_config_set(t, col, &caches)).unwrap();
    assert_eq!(v, json!({"changed": false}), "填完不再要求回填");
    assert_eq!(
        t.tx(|t| rwkv_last_fill(t, col, 64)).unwrap(),
        json!({"done": true, "filled": 0})
    );

    // 回填中途整层重建：表填满、游标删掉。
    t.tx(|t| {
        t.conn()
            .execute("DELETE FROM rwkv_last WHERE col = ?1", [col])
            .unwrap();
        t.set_derive_cfg(col, RWKV_FILL_KEY, Some(""))?;
        Ok(())
    })
    .unwrap();
    t.tx(|t| Index::new(t, col).rebuild_caches().map(|_| ()))
        .unwrap();
    assert_eq!(t.derive_cfg(col, RWKV_FILL_KEY).unwrap(), None);
    assert_eq!(table(&p), full);

    // 比 6 更老的修订号照旧整层重建。
    t.tx(|t| {
        t.set_derive_cfg(col, RULES_KEY, Some(&(from - 1).to_string()))?;
        Ok(())
    })
    .unwrap();
    let v = t.tx(|t| cache_config_set(t, col, &caches)).unwrap();
    assert_eq!(v["changed"], json!(true), "{v}");
    assert_eq!(t.derive_cfg(col, RWKV_FILL_KEY).unwrap(), None);
    assert_eq!(table(&p), full);
}
