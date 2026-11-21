//! 出卡（`study`）随「今天学过的卡」增长的耗时基准（BUG：换代到新代存储后「一开始背卡就卡、越背越卡」）。默认不跑
//! （`#[ignore]`）；跑法：
//!
//! ```text
//! cargo test --profile quick --lib study_bench -- --ignored --nocapture
//! ```
//!
//! 合成库：几千张卡（[NOTES] 条笔记 × 两个模板）、最近 30 天每天 [PER_DAY] 条复习，迁移成新代库后经 C ABI 的分发器
//! （与 Dart 同一个入口）逐张作答 [ANSWERS] 张新卡（学习步），每次作答带 `study`（`answerAndStudy` 的形状），另外每隔
//! 几张单独排一次队。打出第 n 张作答（含排队）与单独排队的耗时。
//!
//! 2026-11-21 实测（`quick` profile，只看相对量级）：常驻会话接线前，作答带排队第 1 张 31 ms、第 120 张 35 ms（每张都整份
//! 现读 30 天日志 + 逐卡重放），单独排队 26～33 ms；接线后作答带排队约 2.5 ms、单独排队约 0.5 ms，不随今天学卡数增长。
//! 真库副本见 `study_realdb_bench_tests.rs`。

use std::time::Instant;

use serde_json::{Value, json};

use super::dispatch_tests::{T1, call, g4req, migrated_prepared};
use super::tests::{card, note};
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{DAY, P, edit, review};

const NOTES: usize = 2_000;
const PER_DAY: usize = 150;
const ANSWERS: usize = 120;

fn nid(i: usize) -> String {
    format!("0193a1b2-0000-7000-8000-{:012x}", 0x1000 + i)
}

fn study_req(now: i64) -> Value {
    json!({"now": now, "utcOff": 0, "rollover": 4, "deck": default_deck_id(P), "pick": true})
}

fn ms(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1000.0
}

#[test]
#[ignore = "benchmark: run with --ignored --nocapture"]
fn study_bench_answer_and_study_cost_vs_cards_learned_today() {
    let build = Instant::now();
    let m = migrated_prepared(false, &|d| {
        // 笔记（NT 两个模板 → 每条两张卡）。
        for chunk in (0..NOTES).collect::<Vec<_>>().chunks(250) {
            let mut ev = Vec::new();
            for &i in chunk {
                let n = nid(i);
                ev.push(note(&n, "NT", 100 + i as i64));
                ev.push(edit("note", &n, "f/fa", json!(format!("語{i}"))));
                ev.push(edit("note", &n, "f/fb", json!(format!("word {i}"))));
            }
            d.apply(T1 - 40 * DAY, ev);
        }
        // 最近 30 天的复习：每天 [PER_DAY] 条，落在前一半笔记的 t1 上（一张卡一天至多一条）。
        for day in 1..=30i64 {
            let at0 = T1 - day * DAY;
            let mut ev = Vec::new();
            for j in 0..PER_DAY {
                let i = (day as usize * 37 + j) % (NOTES / 2);
                let rtype = if day == 30 { "learn" } else { "review" };
                ev.push(review(
                    &format!("b{day}-{j}"),
                    &card(&nid(i), "t1"),
                    at0 + j as i64 * 1000,
                    3,
                    rtype,
                ));
            }
            d.apply(T1 - 35 * DAY + (30 - day) * 1000, ev);
        }
    });
    eprintln!(
        "[study_bench] library built + migrated in {:.0} ms ({} notes, {} cards, {} logs in 30 days)",
        ms(build),
        NOTES,
        NOTES * 2,
        30 * PER_DAY
    );
    let today = T1 + 6 * 3_600_000;
    // 先排一次（会话第一次建 / 冷缓存）。
    let t = Instant::now();
    call(m.h, &g4req("study", today, study_req(today)), None).unwrap();
    eprintln!("[study_bench] first study: {:.1} ms", ms(t));
    let mut answer_ms: Vec<f64> = Vec::new();
    let mut study_ms: Vec<(usize, f64)> = Vec::new();
    for k in 0..ANSWERS {
        // 后一半笔记从没复习过：今天第一次学（学习步）。
        let i = NOTES / 2 + k;
        let c = card(&nid(i), "t1");
        let now = today + k as i64 * 10_000;
        let items = vec![json!({
            "e": review(&format!("today-{k}"), &c, now, 3, "learn"),
            "note": nid(i),
            "intent": "answer",
        })];
        let t = Instant::now();
        let (v, _) = call(
            m.h,
            &g4req("apply", now, json!({"study": study_req(now + 1)})),
            Some(&items),
        )
        .unwrap();
        answer_ms.push(ms(t));
        assert!(v["study"]["counts"].is_object(), "{v}");
        if (k + 1) % 20 == 0 {
            let t = Instant::now();
            call(m.h, &g4req("study", now + 2, study_req(now + 2)), None).unwrap();
            study_ms.push((k + 1, ms(t)));
        }
    }
    for n in [1usize, 10, 20, 40, 60, 80, 100, 120] {
        if n <= answer_ms.len() {
            let lo = n.saturating_sub(5);
            let window = &answer_ms[lo..n];
            let avg = window.iter().sum::<f64>() / window.len() as f64;
            eprintln!(
                "[study_bench] answer+study #{n:>3}: {:.1} ms (avg of #{}..#{n}: {avg:.1} ms)",
                answer_ms[n - 1],
                lo + 1
            );
        }
    }
    for (n, t) in &study_ms {
        eprintln!("[study_bench] study alone after {n:>3} learned today: {t:.1} ms");
    }
    let total: f64 = answer_ms.iter().sum();
    eprintln!(
        "[study_bench] {} answers total {:.0} ms",
        answer_ms.len(),
        total
    );
}
