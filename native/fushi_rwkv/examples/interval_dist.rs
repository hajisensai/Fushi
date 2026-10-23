// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 作答时排程在真实历史上排出的间隔分布：回放一个用户的全部复习，再对（最多 N 张）复习过的卡
//! 假设「在它按原历史下一次该到期的那天」以 Good / Hard 作答，统计 `next_intervals` 给出的天数。
//! 用来判断某个目标保留率下会不会天天到期。
//!
//! cargo run --release --example interval_dist -- <weights.bin> <precision> <retention,...> <max_cards> <user.bin>...
//! 输出每用户每保留率一行 TSV：user retention cards good_p10 good_p50 good_p90 good_1day_frac hard_p50 again_p50

use std::collections::HashMap;
use std::path::Path;

use fushi_rwkv::{FrwkvReview, Model, RwkvRuntime, StatePrecision};

fn read_rows(path: &Path) -> Vec<FrwkvReview> {
    let bytes = std::fs::read(path).unwrap();
    bytes
        .chunks_exact(80)
        .map(|b| {
            let i = |k: usize| i64::from_le_bytes(b[8 * k..8 * k + 8].try_into().unwrap());
            FrwkvReview {
                card_id: i(0),
                note_id: i(1),
                deck_id: i(2),
                preset_id: i(3),
                duration_millis: i(4),
                card_type: i(5),
                day_offset: i(6),
                elapsed_days: i(7),
                elapsed_seconds: i(8),
                present: u32::from_le_bytes(b[72..76].try_into().unwrap()),
                ease: b[76],
                reserved: [0; 3],
            }
        })
        .collect()
}

fn pct(sorted: &[u32], q: f64) -> u32 {
    if sorted.is_empty() {
        return 0;
    }
    sorted[((sorted.len() - 1) as f64 * q).round() as usize]
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let model = Model::from_bytes(&std::fs::read(&args[1]).unwrap()).unwrap();
    let precision = match args[2].as_str() {
        "f32" => StatePrecision::F32,
        "int8" => StatePrecision::Int8,
        _ => StatePrecision::Int4,
    };
    let retentions: Vec<f32> = args[3].split(',').map(|r| r.parse().unwrap()).collect();
    let max_cards: usize = args[4].parse().unwrap();
    println!("user\tretention\tcards\tgood_p10\tgood_p50\tgood_p90\tgood_1day_frac\thard_p50\tagain_p50");
    for file in &args[5..] {
        let path = Path::new(file);
        let user = path.file_stem().unwrap().to_string_lossy().into_owned();
        let rows = read_rows(path);
        let inputs: Vec<_> = rows.iter().map(|r| r.to_input(false).unwrap()).collect();
        let mut runtime = RwkvRuntime::new(&model, precision, 0).unwrap();
        for chunk in inputs.chunks(65_536) {
            runtime.replay(chunk, false).unwrap();
        }
        let last_day = rows.iter().filter(|r| r.ease != 0).map(|r| r.day_offset).max().unwrap();
        // 每张卡最后一条有评分的复习与它之前那段间隔：假设下一次作答在「上一次 + 上一段间隔
        // （至少 1 天）」，但不早于全局最后一天（运行时要求时间不倒退）。
        let mut last: HashMap<i64, (usize, i64)> = HashMap::new();
        for (index, row) in rows.iter().enumerate() {
            if row.ease == 0 {
                continue;
            }
            let gap = if row.elapsed_days > 0 { row.elapsed_days } else { 1 };
            last.insert(row.card_id, (index, gap));
        }
        let mut cards: Vec<(i64, (usize, i64))> = last.into_iter().collect();
        cards.sort_by_key(|(id, _)| *id);
        let stride = (cards.len() / max_cards.max(1)).max(1);
        let picked: Vec<_> = cards.into_iter().step_by(stride).take(max_cards).collect();
        if std::env::var_os("CURVES").is_some() {
            let horizons = [1i64, 3, 7, 14, 30, 90, 365, 1825, 36_500];
            for (card, (index, gap)) in picked.iter().take(6) {
                let row = &rows[*index];
                let due = (row.day_offset + gap).max(last_day);
                let mut answer = row.to_input(false).unwrap();
                answer.day_offset = Some(due);
                answer.current_elapsed_days = Some(due - row.day_offset);
                answer.current_elapsed_seconds = Some((due - row.day_offset) * 86_400);
                answer.card_type = Some(2);
                let r = runtime.forecast(&answer, &[1, 3], &horizons).unwrap();
                let fmt = |s: &[f32]| s.iter().map(|v| format!("{v:.3}")).collect::<Vec<_>>().join(" ");
                println!("# {user} card {card} again: {}", fmt(&r[..9]));
                println!("# {user} card {card} good:  {}", fmt(&r[9..]));
            }
        }
        for &retention in &retentions {
            let (mut good, mut hard, mut again) = (Vec::new(), Vec::new(), Vec::new());
            for (_, (index, gap)) in &picked {
                let row = &rows[*index];
                let due = (row.day_offset + gap).max(last_day);
                let elapsed = due - row.day_offset;
                let mut answer = row.to_input(false).unwrap();
                answer.day_offset = Some(due);
                answer.current_elapsed_days = Some(elapsed);
                answer.current_elapsed_seconds = Some(elapsed * 86_400);
                answer.card_type = Some(2);
                let Ok((days, _)) = runtime.next_intervals(&answer, retention, 36_500) else {
                    continue;
                };
                again.push(days[0]);
                hard.push(days[1]);
                good.push(days[2]);
            }
            good.sort_unstable();
            hard.sort_unstable();
            again.sort_unstable();
            let one = good.iter().filter(|&&d| d <= 1).count() as f64 / good.len().max(1) as f64;
            println!(
                "{user}\t{retention}\t{}\t{}\t{}\t{}\t{one:.3}\t{}\t{}",
                good.len(),
                pct(&good, 0.1),
                pct(&good, 0.5),
                pct(&good, 0.9),
                pct(&hard, 0.5),
                pct(&again, 0.5),
            );
        }
    }
}
