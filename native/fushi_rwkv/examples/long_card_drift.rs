// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 诊断（BUG-5588）：一张卡按几种作答模式答 N 次，比较 int8 与 f32 的 card / note 状态峰值、
//! 回放预测与有限性。
//! cargo run --profile quick --example long_card_drift -- <small.int8.bin> [answers] [pattern]
//! 给了 pattern 时改为逐段追踪（每 answers/40 次打印一次各精度的峰值与最后一次预测）。

use fushi_rwkv::{ReviewInput, SmallInference, SmallModel, StatePrecision};

fn pattern(name: &str, answers: usize) -> Vec<ReviewInput> {
    let mut seed = 7u64;
    let mut next = || {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (seed >> 33) as i64
    };
    let mut out = Vec::with_capacity(answers);
    let (mut day, mut ts): (i64, i64) = (0, 8 * 3600);
    let mut last: Option<(i64, i64)> = None;
    for i in 0..answers {
        let (ease, gap_days, gap_secs): (u8, i64, i64) = match name {
            "daily_mixed" => ([1u8, 2, 3, 3, 3, 3, 4][(next() % 7) as usize], 1, 0),
            "daily_good" => (3, 1, 0),
            "daily_again" => (1, 1, 0),
            "alternate" => (if i % 2 == 0 { 1 } else { 4 }, 1, 0),
            "cram_again" => (1, if i % 50 == 49 { 1 } else { 0 }, 30 + next() % 60),
            "cram_good" => (3, if i % 50 == 49 { 1 } else { 0 }, 30 + next() % 60),
            "sparse_easy" => (4, 1 + next() % 30, 0),
            "random_gaps" => ((1 + next() % 4) as u8, next() % 10, next() % 4000),
            _ => panic!("{name}"),
        };
        if gap_days > 0 {
            day += gap_days;
            ts = day * 86_400 + 8 * 3600 + next() % 3600;
        } else {
            ts += gap_secs.max(1);
        }
        let (ed, es) = last.map_or((-1, -1), |(d, t)| (day - d, ts - t));
        out.push(ReviewInput {
            card_id: 10,
            note_id: Some(100),
            deck_id: Some(1),
            preset_id: Some(1),
            is_query: false,
            ease: Some(ease),
            duration_millis: Some(2_000 + next() % 9_000),
            card_type: Some(if last.is_none() { 0 } else { 2 }),
            day_offset: Some(day),
            current_elapsed_days: Some(ed),
            current_elapsed_seconds: Some(es),
        });
        last = Some((day, ts));
    }
    out
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let model = SmallModel::from_bytes(&std::fs::read(&args[1]).unwrap()).unwrap();
    let answers: usize = args.get(2).map_or(20_000, |a| a.parse().unwrap());
    if let Some(name) = args.get(3) {
        // Trace: peaks every answers/40 answers.
        let reviews = pattern(name, answers);
        let mut rts: Vec<SmallInference> = [StatePrecision::F32, StatePrecision::Int8]
            .iter()
            .map(|&p| SmallInference::new(&model, p))
            .collect();
        let step = (answers / 40).max(1);
        for (k, chunk) in reviews.chunks(step).enumerate() {
            let mut cols = Vec::new();
            for rt in &mut rts {
                let preds = rt.warm_up_reviews(chunk.to_vec(), true).unwrap();
                cols.push(format!(
                    "{:.3e}/{:.3e} R={:.4}",
                    rt.stream_peak(0),
                    rt.stream_peak(2),
                    preds.last().unwrap().1
                ));
            }
            println!("{}	{}", (k + 1) * step, cols.join("	"));
        }
        return;
    }
    println!(
        "pattern\tprec\tcard_peak\tnote_peak\tf32_card\tf32_note\tmax|dp|\tmean|dp|\tlast|dp|\tnonfinite\tfirst_bad"
    );
    for name in [
        "daily_mixed",
        "daily_good",
        "daily_again",
        "alternate",
        "cram_again",
        "cram_good",
        "sparse_easy",
        "random_gaps",
    ] {
        let reviews = pattern(name, answers);
        let run = |p: StatePrecision| {
            let mut rt = SmallInference::new(&model, p);
            let preds = rt.warm_up_reviews(reviews.clone(), true).unwrap();
            (preds, rt.stream_peak(0), rt.stream_peak(2))
        };
        let (exact, ec, en) = run(StatePrecision::F32);
        for p in [StatePrecision::Int8] {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(p)));
            match result {
                Err(_) => println!("{name}\t{p:?}\tPANIC"),
                Ok((preds, c, n)) => {
                    let mut max = 0f32;
                    let mut sum = 0f64;
                    let mut bad = 0usize;
                    let mut first_bad = None;
                    for (k, ((_, a), (_, b))) in preds.iter().zip(&exact).enumerate() {
                        if !a.is_finite() {
                            bad += 1;
                            first_bad.get_or_insert(k);
                            continue;
                        }
                        let d = (a - b).abs();
                        max = max.max(d);
                        sum += d as f64;
                    }
                    let last = (preds.last().unwrap().1 - exact.last().unwrap().1).abs();
                    println!(
                        "{name}\t{p:?}\t{c:.4e}\t{n:.4e}\t{ec:.4}\t{en:.4}\t{max:.4}\t{:.5}\t{last:.4}\t{bad}\t{first_bad:?}",
                        sum / preds.len() as f64
                    );
                }
            }
        }
    }
}
