// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 实测回放 / 查询耗时与每卡状态字节数（README「实测」一节的数据来源）。
//!
//! cargo run --release --example bench -- [model.bin] [cards] [days] [threads] [f32,int8]
//!   默认 model/RWKV_trained_on_5000_10000.bin、5000 张卡、730 天、threads=0（全部核心）、两种精度。
use std::time::Instant;

use fushi_rwkv::{ReviewInput, RwkvModel, RwkvRuntime, StatePrecision};

struct Lcg(u64);

impl Lcg {
    fn below(&mut self, n: i64) -> i64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ((self.0 >> 33) as i64).rem_euclid(n)
    }
}

/// 与 tests/fixtures/simulated_collection 同一套规则的模拟收藏（新卡学习步、复习间隔增长、遗忘重学）。
fn simulate(cards: usize, days: i64) -> (Vec<ReviewInput>, Vec<ReviewInput>) {
    const DAY: i64 = 86_400;
    let mut rng = Lcg(0x5eed);
    let new_per_day = (cards as i64 / (days / 2).max(1)).max(1) as usize;
    let mut last: Vec<Option<(i64, i64)>> = vec![None; cards];
    let mut due = vec![i64::MAX; cards];
    let mut interval = vec![0_i64; cards];
    let mut introduced = 0;
    let mut reviews = Vec::new();
    let ids = |i: usize| {
        let note = i as i64 / 2;
        (
            1_600_000_000_000 + i as i64,
            1_500_000_000_000 + note,
            1_700_000_000_000 + note % 20,
            [1, 2, 3, 4, 5][(note % 20 % 5) as usize],
        )
    };
    for day in 0..days {
        let mut ts = day * DAY + 8 * 3600;
        let mut today: Vec<usize> = (0..cards).filter(|&i| due[i] <= day).collect();
        for _ in 0..new_per_day {
            if introduced < cards {
                today.push(introduced);
                introduced += 1;
            }
        }
        for i in today {
            let (card, note, deck, preset) = ids(i);
            let mut answer = |rng: &mut Lcg,
                              ease: i64,
                              card_type: i64,
                              ts: &mut i64,
                              last: &mut Option<(i64, i64)>| {
                let (ed, es) = last.map_or((-1, -1), |(d, t)| (day - d, *ts - t));
                reviews.push(ReviewInput {
                    card_id: card,
                    note_id: Some(note),
                    deck_id: Some(deck),
                    preset_id: Some(preset),
                    is_query: false,
                    ease: Some(ease as u8),
                    duration_millis: Some(2_000 + rng.below(20_000)),
                    card_type: Some(card_type),
                    day_offset: Some(day),
                    current_elapsed_days: Some(ed),
                    current_elapsed_seconds: Some(es),
                });
                *last = Some((day, *ts));
                *ts += 10 + rng.below(30);
            };
            if last[i].is_none() {
                answer(&mut rng, 3, 0, &mut ts, &mut last[i]);
                interval[i] = 1;
            } else {
                let roll = rng.below(100);
                let ease = if roll < 10 {
                    1
                } else if roll < 25 {
                    2
                } else if roll < 90 {
                    3
                } else {
                    4
                };
                answer(&mut rng, ease, 2, &mut ts, &mut last[i]);
                if ease == 1 {
                    ts += 600;
                    answer(&mut rng, 3, 3, &mut ts, &mut last[i]);
                    interval[i] = 1.max(interval[i] / 3);
                } else {
                    interval[i] =
                        (interval[i] * [0, 0, 12, 25, 35][ease as usize] / 10).max(interval[i] + 1);
                }
            }
            due[i] = day + interval[i];
        }
    }
    let now = days * DAY + 9 * 3600;
    let queries = (0..cards)
        .filter_map(|i| {
            let (d, t) = last[i]?;
            let (card, note, deck, preset) = ids(i);
            Some(ReviewInput {
                card_id: card,
                note_id: Some(note),
                deck_id: Some(deck),
                preset_id: Some(preset),
                is_query: true,
                ease: None,
                duration_millis: None,
                card_type: Some(2),
                day_offset: Some(days),
                current_elapsed_days: Some(days - d),
                current_elapsed_seconds: Some(now - t),
            })
        })
        .collect();
    (reviews, queries)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let model_path = args.get(1).cloned().unwrap_or_else(|| {
        concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/model/RWKV_trained_on_5000_10000.bin"
        )
        .to_owned()
    });
    let cards: usize = args.get(2).map_or(5_000, |v| v.parse().unwrap());
    let days: i64 = args.get(3).map_or(730, |v| v.parse().unwrap());
    let threads: usize = args.get(4).map_or(0, |v| v.parse().unwrap());
    let precisions: Vec<StatePrecision> = args
        .get(5)
        .map_or("f32,int8", String::as_str)
        .split(',')
        .map(|p| match p {
            "f32" => StatePrecision::F32,
            "int8" => StatePrecision::Int8,
            other => panic!("unknown precision {other}"),
        })
        .collect();

    let started = Instant::now();
    let bytes = std::fs::read(&model_path).expect("model file (run fetch_model.sh)");
    let model = RwkvModel::from_bytes(&bytes).unwrap();
    println!(
        "model load: {:.1} ms",
        started.elapsed().as_secs_f64() * 1e3
    );

    let (reviews, queries) = simulate(cards, days);
    println!(
        "history: {} reviews, {} cards queried, {days} days, threads={threads} ({} available)",
        reviews.len(),
        queries.len(),
        std::thread::available_parallelism().map_or(0, |n| n.get())
    );
    for precision in precisions {
        let mut runtime = RwkvRuntime::new(&model, precision, threads).unwrap();
        let started = Instant::now();
        // 与 kuma3 一样按 65,536 条一块追加
        for chunk in reviews.chunks(65_536) {
            runtime.replay(chunk, false).unwrap();
        }
        let replay = started.elapsed().as_secs_f64();
        let started = Instant::now();
        let r = runtime.query(&queries).unwrap();
        let query = started.elapsed().as_secs_f64();
        let started = Instant::now();
        let one = runtime.query(&queries[..1]).unwrap();
        let single = started.elapsed().as_secs_f64();
        // 作答后追加一条（同日再答一次）：Instant 每次作答的增量开销。
        let mut extra = reviews[reviews.len() - 1].clone();
        extra.current_elapsed_days = Some(0);
        extra.current_elapsed_seconds = Some(60);
        let started = Instant::now();
        runtime.replay(&[extra], false).unwrap();
        let append_one = started.elapsed().as_secs_f64();
        let stats = runtime.stats();
        let snapshot = runtime.snapshot().unwrap();
        let state = stats.card_state_bytes + stats.note_state_bytes + stats.shared_state_bytes;
        println!(
            "{precision:?}: replay {:.2} s ({:.0} reviews/s); query {} cards {:.1} ms ({:.1} µs/card), single query {:.2} ms, append one answer {:.2} ms",
            replay,
            reviews.len() as f64 / replay,
            queries.len(),
            query * 1e3,
            query * 1e6 / queries.len() as f64,
            single * 1e3,
            append_one * 1e3,
        );
        println!(
            "  states: card {} B/card ({} cards), note {} B/note ({} notes), shared {} B; features {} B ({} B/card); snapshot {:.1} MB; total state {:.1} MB",
            stats.card_state_bytes / stats.cards.max(1),
            stats.cards,
            stats.note_state_bytes / stats.notes.max(1),
            stats.notes,
            stats.shared_state_bytes,
            stats.feature_state_bytes,
            stats.feature_state_bytes / stats.cards.max(1),
            snapshot.len() as f64 / 1e6,
            state as f64 / 1e6,
        );
        let mean = r.iter().filter(|v| v.is_finite()).sum::<f32>() / r.len() as f32;
        println!("  mean R {mean:.4}, first {:?}", one);
    }
}
