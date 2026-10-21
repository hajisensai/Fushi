// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 排程实际效果的离线检验（小模型）：按曲线头在 R = 目标处排间隔，隔那么久后真的能答对目标那么多吗？
//!
//! 回放一个用户的全部复习；同一张卡相邻两次复习 (r, r')：曲线头在 r 作答后给出的遗忘曲线，在真实间隔
//! t = r' 距 r 的秒数处的值 = 预测；r' 不是 Again = 结果。另记 r' 之前即时头的 R 作对照。按真实间隔
//! 分桶、按用户通过率分组输出校准：预测均值 vs 实际通过率，以及预测落在 [0.75, 0.85]（目标 0.8
//! 附近、排程正好会选的那些点）时的实际通过率。
//!
//! cargo run --release --example curve_calibration -- <small weights> <precision> <user.bin>...
//! 每用户一行 `#U user rows scored pass_rate`；全部用户聚合后输出：
//! `group bucket n curve_mean imm_mean observed near80_n near80_observed curve_ll imm_ll`

use std::collections::HashMap;
use std::path::Path;

use fushi_rwkv::{FrwkvReview, SmallInference, SmallModel, StatePrecision};

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

const BUCKETS: [(&str, f64); 7] = [
    ("<1d", 1.0),
    ("1-7d", 7.0),
    ("7-30d", 30.0),
    ("30-90d", 90.0),
    ("90-365d", 365.0),
    ("1-3y", 1095.0),
    (">3y", f64::INFINITY),
];
const GROUPS: [&str; 4] = ["all", "pass>=0.95", "pass0.85-0.95", "pass<0.85"];

#[derive(Default, Clone, Copy)]
struct Cell {
    n: f64,
    curve: f64,
    imm: f64,
    passed: f64,
    near_n: f64,
    near_passed: f64,
    curve_ll: f64,
    imm_ll: f64,
}

fn ll(p: f64, y: bool) -> f64 {
    let p = p.clamp(1e-6, 1.0 - 1e-6);
    -if y { p.ln() } else { (1.0 - p).ln() }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let model = SmallModel::from_bytes(&std::fs::read(&args[1]).unwrap()).unwrap();
    let precision = match args[2].as_str() {
        "f32" => StatePrecision::F32,
        "int8" => StatePrecision::Int8,
        _ => StatePrecision::Int4,
    };
    let mut cells = vec![[Cell::default(); BUCKETS.len()]; GROUPS.len()];
    for file in &args[3..] {
        let path = Path::new(file);
        let user = path.file_stem().unwrap().to_string_lossy().into_owned();
        let rows = read_rows(path);
        let inputs: Vec<_> = rows.iter().map(|r| r.to_input(false).unwrap()).collect();
        let mut inference = SmallInference::new(&model, precision);
        let replayed = inference.replay_with_curves(inputs).unwrap();
        let by_row: HashMap<usize, (f32, fushi_rwkv::SmallHeads)> =
            replayed.into_iter().map(|(index, imm, heads)| (index, (imm, heads))).collect();
        // (pred_curve, pred_imm, passed, elapsed_days) for every non-first review with a known previous answer.
        let mut samples = Vec::new();
        let mut last: HashMap<i64, usize> = HashMap::new();
        for (index, row) in rows.iter().enumerate() {
            if row.ease == 0 {
                continue;
            }
            if let Some(&previous) = last.get(&row.card_id) {
                if row.elapsed_seconds > 0 {
                    let (_, heads) = by_row[&previous];
                    let (imm, _) = by_row[&index];
                    let curve = heads.curve_retrievability(row.elapsed_seconds as f32);
                    samples.push((curve as f64, imm as f64, row.ease > 1, row.elapsed_seconds as f64 / 86_400.0));
                }
            }
            last.insert(row.card_id, index);
        }
        let pass_rate = samples.iter().filter(|s| s.2).count() as f64 / samples.len().max(1) as f64;
        println!("#U\t{user}\t{}\t{}\t{pass_rate:.4}", rows.len(), samples.len());
        let group = if pass_rate >= 0.95 {
            1
        } else if pass_rate >= 0.85 {
            2
        } else {
            3
        };
        for (curve, imm, passed, days) in samples {
            let bucket = BUCKETS.iter().position(|(_, upper)| days < *upper).unwrap();
            for g in [0, group] {
                let c = &mut cells[g][bucket];
                c.n += 1.0;
                c.curve += curve;
                c.imm += imm;
                c.passed += f64::from(u8::from(passed));
                if (0.75..=0.85).contains(&curve) {
                    c.near_n += 1.0;
                    c.near_passed += f64::from(u8::from(passed));
                }
                c.curve_ll += ll(curve, passed);
                c.imm_ll += ll(imm, passed);
            }
        }
    }
    println!("group\tbucket\tn\tcurve_mean\timm_mean\tobserved\tnear80_n\tnear80_observed\tcurve_ll\timm_ll");
    for (g, name) in GROUPS.iter().enumerate() {
        for (b, (bucket, _)) in BUCKETS.iter().enumerate() {
            let c = cells[g][b];
            if c.n == 0.0 {
                continue;
            }
            println!(
                "{name}\t{bucket}\t{}\t{:.4}\t{:.4}\t{:.4}\t{}\t{:.4}\t{:.4}\t{:.4}",
                c.n,
                c.curve / c.n,
                c.imm / c.n,
                c.passed / c.n,
                c.near_n,
                if c.near_n > 0.0 { c.near_passed / c.near_n } else { f64::NAN },
                c.curve_ll / c.n,
                c.imm_ll / c.n,
            );
        }
    }
}
