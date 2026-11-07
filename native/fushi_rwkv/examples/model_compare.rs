// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 多个权重在同一份复习历史上的成对对比（部署路径：本库特征构造 + 批量回放）。
//!
//! cargo run --release --example model_compare -- <rows.bin | dir> <f32|int8|int4> <name=weights.bin> ...
//!   rows.bin：80 字节一行的 FrwkvReview。不计分的首条复习：有 rows.bin.first（每行 1 字节，
//!   1 = 该卡首条）就按它，否则按 `elapsed_days == -1`。
//!   dir：目录里每个 *.bin 是一个用户；按用户聚类 bootstrap。单文件按卡聚类。
//! 计分：每条非首次、有评分的复习，用作答前的 R 算 LogLoss（y = 不是 Again）。
//! 第一个模型是基线；其余报与基线的成对差，聚类 bootstrap（2,000 次，按条加权）给 95% 区间，
//! 以及按用户 LogLoss 赢基线的用户数（dir 时）。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use fushi_rwkv::{FrwkvReview, Model, RwkvRuntime, StatePrecision};

fn read_rows(path: &Path) -> Vec<FrwkvReview> {
    FrwkvReview::parse_rows(&std::fs::read(path).unwrap()).unwrap()
}

/// splitmix64：bootstrap 抽样用，免依赖。
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

fn loss_of(p: f32, ease: u8) -> f64 {
    let p = (p as f64).clamp(1e-6, 1.0 - 1e-6);
    if ease > 1 { -p.ln() } else { -(1.0 - p).ln() }
}

const SLICES: [&str; 4] = ["all", "same_day", "spaced", "spaced_review"];

fn in_slice(slice: usize, r: &FrwkvReview) -> bool {
    match slice {
        0 => true,
        1 => r.elapsed_days == 0,
        2 => r.elapsed_days >= 1,
        _ => r.elapsed_days >= 1 && r.card_type == 2,
    }
}

/// [slice][model][unit] -> (loss sum, count)
type Acc = Vec<Vec<Vec<(f64, u64)>>>;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let target = PathBuf::from(&args[1]);
    let precision = match args[2].as_str() {
        "f32" => StatePrecision::F32,
        "int8" => StatePrecision::Int8,
        "int4" => StatePrecision::Int4,
        other => panic!("unknown precision {other}"),
    };
    let models: Vec<(String, Model)> = args[3..]
        .iter()
        .map(|spec| {
            let (name, path) = spec.split_once('=').unwrap();
            (
                name.to_owned(),
                Model::from_bytes(&std::fs::read(path).unwrap()).unwrap(),
            )
        })
        .collect();
    let by_user = target.is_dir();
    let mut files: Vec<PathBuf> = if by_user {
        std::fs::read_dir(&target)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.extension().is_some_and(|e| e == "bin"))
            .collect()
    } else {
        vec![target.clone()]
    };
    files.sort_by_key(|p| std::fs::metadata(p).unwrap().len());

    let mut acc: Acc = vec![vec![Vec::new(); models.len()]; SLICES.len()];
    let mut nonfinite = vec![0usize; models.len()];
    let mut seconds = vec![0f64; models.len()];
    let mut max_peak = vec![[0f32; 2]; models.len()];
    let started_all = Instant::now();
    for (file_index, file) in files.iter().enumerate() {
        let rows = read_rows(file);
        let first: Vec<bool> = match std::fs::read(format!("{}.first", file.display())) {
            Ok(bytes) => {
                assert_eq!(bytes.len(), rows.len());
                bytes.iter().map(|&b| b != 0).collect()
            }
            Err(_) => rows.iter().map(|r| r.elapsed_days == -1).collect(),
        };
        let inputs: Vec<_> = rows.iter().map(|r| r.to_input(false).unwrap()).collect();
        // 聚类单元：按用户时每文件一个，否则每卡一个。
        let mut card_index: HashMap<i64, usize> = HashMap::new();
        let unit_of: Vec<usize> = if by_user {
            vec![file_index; rows.len()]
        } else {
            rows.iter()
                .map(|r| {
                    let next = card_index.len();
                    *card_index.entry(r.card_id).or_insert(next)
                })
                .collect()
        };
        let units = if by_user {
            files.len()
        } else {
            card_index.len()
        };
        for slice in acc.iter_mut() {
            for per_model in slice.iter_mut() {
                per_model.resize(units, (0.0, 0));
            }
        }

        let mut predictions: Vec<Vec<f32>> = Vec::with_capacity(models.len());
        for (m, (_, model)) in models.iter().enumerate() {
            let mut runtime = RwkvRuntime::new(model, precision, 0).unwrap();
            let started = Instant::now();
            let mut p = vec![f32::NAN; inputs.len()];
            for (block, chunk) in inputs.chunks(65_536).enumerate() {
                for (index, value) in runtime.replay(chunk, true).unwrap() {
                    p[block * 65_536 + index] = value;
                }
            }
            seconds[m] += started.elapsed().as_secs_f64();
            if let Some(peaks) = runtime.state_peaks() {
                max_peak[m][0] = max_peak[m][0].max(peaks[0]);
                max_peak[m][1] = max_peak[m][1].max(peaks[2]);
            }
            predictions.push(p);
        }
        for i in 0..rows.len() {
            if rows[i].ease == 0 || first[i] {
                continue;
            }
            if predictions.iter().any(|p| !p[i].is_finite()) {
                for (m, p) in predictions.iter().enumerate() {
                    if !p[i].is_finite() {
                        nonfinite[m] += 1;
                    }
                }
                continue;
            }
            for (s, slice) in acc.iter_mut().enumerate() {
                if !in_slice(s, &rows[i]) {
                    continue;
                }
                for (m, p) in predictions.iter().enumerate() {
                    let slot = &mut slice[m][unit_of[i]];
                    slot.0 += loss_of(p[i], rows[i].ease);
                    slot.1 += 1;
                }
            }
        }
        if by_user && (file_index + 1) % 25 == 0 {
            eprintln!(
                "{}/{} users, {:.0}s",
                file_index + 1,
                files.len(),
                started_all.elapsed().as_secs_f64()
            );
        }
    }
    for (m, (name, _)) in models.iter().enumerate() {
        eprintln!(
            "{name}: replay {:.1}s, max peak card {:.3} note {:.3}, nonfinite {}",
            seconds[m], max_peak[m][0], max_peak[m][1], nonfinite[m]
        );
    }

    println!("slice\tmodel\tscored\tlogloss\tdiff_vs_base\tci_low\tci_high\trel_pct\tunits_better");
    for (s, slice_name) in SLICES.iter().enumerate() {
        let per_model = &acc[s];
        let totals: Vec<(f64, u64)> = per_model
            .iter()
            .map(|u| u.iter().fold((0.0, 0), |(l, n), &(a, b)| (l + a, n + b)))
            .collect();
        let base = totals[0].0 / totals[0].1.max(1) as f64;
        let active: Vec<usize> = (0..per_model[0].len())
            .filter(|&u| per_model[0][u].1 > 0)
            .collect();
        for (m, (name, _)) in models.iter().enumerate() {
            let ll = totals[m].0 / totals[m].1.max(1) as f64;
            if m == 0 {
                println!("{slice_name}\t{name}\t{}\t{ll:.6}\t\t\t\t\t", totals[m].1);
                continue;
            }
            let mut rng = Rng(0x5EED + m as u64 + 101 * s as u64);
            let mut diffs: Vec<f64> = (0..2000)
                .map(|_| {
                    let (mut a, mut b, mut n) = (0.0, 0.0, 0u64);
                    for _ in 0..active.len() {
                        let u = active[(rng.next() % active.len() as u64) as usize];
                        a += per_model[m][u].0;
                        b += per_model[0][u].0;
                        n += per_model[0][u].1;
                    }
                    (a - b) / n.max(1) as f64
                })
                .collect();
            diffs.sort_by(|x, y| x.partial_cmp(y).unwrap());
            let better = if by_user {
                let wins = active
                    .iter()
                    .filter(|&&u| per_model[m][u].0 < per_model[0][u].0)
                    .count();
                format!("{wins}/{}", active.len())
            } else {
                String::new()
            };
            println!(
                "{slice_name}\t{name}\t{}\t{ll:.6}\t{:+.6}\t{:+.6}\t{:+.6}\t{:+.3}\t{better}",
                totals[m].1,
                ll - base,
                diffs[50],
                diffs[1949],
                100.0 * (ll - base) / base
            );
        }
    }
}
