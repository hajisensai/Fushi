// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 诊断：小模型在一份真实历史上逐块回放，比较两种精度下 card / note 状态峰值的走势。
//! cargo run --release --example state_drift -- <small.bin> <user.bin> <precision> [<precision>]
//! 输出：峰值最高的 10 张卡（各精度峰值与复习次数），以及最差那张卡每次复习后的峰值。

use std::collections::HashMap;

use fushi_rwkv::{FrwkvReview, SmallInference, SmallModel, StatePrecision};

fn read_rows(path: &str) -> Vec<FrwkvReview> {
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

fn precision(name: &str) -> StatePrecision {
    match name {
        "f32" => StatePrecision::F32,
        "int8" => StatePrecision::Int8,
        "int4" => StatePrecision::Int4,
        other => panic!("{other}"),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let model = SmallModel::from_bytes(&std::fs::read(&args[1]).unwrap()).unwrap();
    let rows = read_rows(&args[2]);
    let inputs: Vec<_> = rows.iter().map(|r| r.to_input(false).unwrap()).collect();
    let precisions: Vec<StatePrecision> = args[3..].iter().map(|p| precision(p)).collect();
    let mut reviews: HashMap<i64, usize> = HashMap::new();
    for row in &rows {
        *reviews.entry(row.card_id).or_default() += 1;
    }

    let mut peaks: Vec<HashMap<i64, f32>> = Vec::new();
    for &p in &precisions {
        let mut runtime = SmallInference::new(&model, p);
        for chunk in inputs.chunks(65_536) {
            runtime.warm_up_reviews(chunk.to_vec(), false).unwrap();
        }
        peaks.push(
            runtime
                .state_ids(0)
                .into_iter()
                .map(|id| (id, runtime.state_peaks(0, id).unwrap().into_iter().fold(0.0, f32::max)))
                .collect(),
        );
    }
    let mut worst: Vec<(i64, f32)> = peaks[0].iter().map(|(&id, &p)| (id, p)).collect();
    worst.sort_by(|a, b| b.1.total_cmp(&a.1));
    println!("card\treviews\t{}", args[3..].join("\t"));
    for &(id, _) in worst.iter().take(10) {
        let cols: Vec<String> = peaks.iter().map(|m| format!("{:.4}", m[&id])).collect();
        println!("{id}\t{}\t{}", reviews[&id], cols.join("\t"));
    }
    let above: Vec<usize> = peaks.iter().map(|m| m.values().filter(|&&p| p > 2.0).count()).collect();
    println!("cards with peak > 2: {above:?} of {}", peaks[0].len());

    // 最差那张卡：每次复习后（逐块回放到它的每一条）各精度的峰值。
    let target = worst[0].0;
    let positions: Vec<usize> = rows
        .iter()
        .enumerate()
        .filter(|(_, r)| r.card_id == target)
        .map(|(i, _)| i)
        .collect();
    println!("trace of card {target} ({} reviews)", positions.len());
    let mut runtimes: Vec<SmallInference> =
        precisions.iter().map(|&p| SmallInference::new(&model, p)).collect();
    let mut done = 0;
    let step = (positions.len() / 40).max(1);
    for (k, &pos) in positions.iter().enumerate() {
        let upto = pos + 1;
        for runtime in &mut runtimes {
            runtime.warm_up_reviews(inputs[done..upto].to_vec(), false).unwrap();
        }
        done = upto;
        if k % step == 0 || k + 1 == positions.len() {
            let cols: Vec<String> = runtimes
                .iter()
                .map(|r| format!("{:?}", r.state_peaks(0, target).unwrap()))
                .collect();
            println!("review {k}\tday {}\t{}", rows[pos].day_offset, cols.join("\t"));
        }
    }
}
