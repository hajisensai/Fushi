//! srs.db v26（副本重放）/ v27（副本补 undo）升级耗时的合成库测量（BUG-4218 后续）。手动跑：
//! `cargo test --release --lib copy_migration_bench -- --ignored --nocapture`，可用环境变量
//! `FUSHI_COPY_BENCH_CARDS`（默认 20000）调规模。不是回归测试，只打印数字。

use std::time::Instant;

use serde_json::{Value, json};

use super::tests::{DAY, Device, P, deck_entity, review};

const T0: i64 = 1_700_000_000_000;
/// 每张卡的复习条数。
const PER_CARD: i64 = 6;

#[test]
#[ignore]
fn copy_migration_bench() {
    let cards: i64 = std::env::var("FUSHI_COPY_BENCH_CARDS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(20_000);
    let deck = super::config::default_deck_id(P);
    let a = Device::new("copy-bench");
    a.apply(T0, vec![deck_entity(&deck)]);
    let started = Instant::now();
    let mut batch: Vec<Value> = Vec::new();
    let (mut logs, mut copies, mut undos) = (0u64, 0u64, 0u64);
    let flush = |batch: &mut Vec<Value>| {
        if !batch.is_empty() {
            a.apply(T0 + 100 * DAY, std::mem::take(batch));
        }
    };
    for c in 0..cards {
        let card = format!("C{c}");
        for k in 0..PER_CARD {
            let at = T0 + k * DAY + c;
            let id = format!("r{c}-{k}");
            let r = review(&id, &card, at, 3, if k == 0 { "learn" } else { "review" });
            // 五分之一的卡：每条复习都有一份换了 ID 的副本（BUG-4217 合并写出的形状）；其中一半的卡用户撤销过最后
            // 一条的副本。
            if c % 5 == 0 {
                let mut copy = r.clone();
                copy["x"]["id"] = json!(format!("{id}-copy"));
                batch.push(copy);
                copies += 1;
                if c % 10 == 0 && k == PER_CARD - 1 {
                    batch.push(json!({"t": "log", "x": {
                        "id": format!("u{c}"), "p": P, "card": card, "kind": "undo", "revokes": format!("{id}-copy"),
                        "hlc": format!("{}:0:dart", at + 1), "at": at + 1, "ts": "anchored", "origin": "fushi",
                        "rtype": "manual", "utcOff": 0, "rollover": 4, "fv": 1
                    }}));
                    undos += 1;
                }
            }
            batch.push(r);
            logs += 1;
        }
        if batch.len() >= 3000 {
            flush(&mut batch);
        }
    }
    flush(&mut batch);
    let built = started.elapsed();
    let total: i64 = a.rows("SELECT COUNT(*) FROM srs_review_logs")[1][0]
        .parse()
        .unwrap();
    let size = std::fs::metadata(a._dir.0.join("srs.db"))
        .map(|m| m.len())
        .unwrap_or(0);
    println!(
        "copy_migration_bench: cards={cards} reviews={logs} copies={copies} undos={undos} rows={total} db={:.1}MB built in {:.1}s",
        size as f64 / 1e6,
        built.as_secs_f64()
    );

    // 两个步骤各自在一个事务里计时（与升级时同样在写连接上的一个事务里跑）。
    let w = a.core.writer().unwrap();
    w.execute_batch("BEGIN").unwrap();
    let t = Instant::now();
    let replayed = super::replay_event_copies(&w).unwrap();
    let v26 = t.elapsed();
    let t = Instant::now();
    let repaired = super::revoke_copies_of_revoked_events(&w, T0 + 200 * DAY).unwrap();
    let v27 = t.elapsed();
    w.execute_batch("COMMIT").unwrap();
    println!(
        "copy_migration_bench: v26 replay_event_copies {:.0} ms (changed cards {}), v27 revoke_copies_of_revoked_events {:.0} ms (undos written {repaired})",
        v26.as_secs_f64() * 1e3,
        replayed.len(),
        v27.as_secs_f64() * 1e3,
    );
    drop(w);
    assert_eq!(
        repaired as u64, undos,
        "one repair per revoked event's unnamed copy"
    );

    // 端到端：版本退回 v25、重开（升级在打开时跑，含 v26 + v27 两步与打开的其余开销）。v27 这次什么也不写（已补过）。
    a.core
        .writer()
        .unwrap()
        .execute_batch("UPDATE srs_meta SET value = '25' WHERE key = 'schema';")
        .unwrap();
    let Device { core, _dir } = a;
    drop(core);
    let t = Instant::now();
    let reopened = crate::store::SrsCore::open(&_dir.0.join("srs.db")).unwrap();
    println!(
        "copy_migration_bench: reopen from v25 (v26 + v27 steps, nothing left to repair) {:.0} ms",
        t.elapsed().as_secs_f64() * 1e3
    );
    drop(reopened);
}
