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

use fushi_rwkv::{FrwkvReview, Model, ReviewInput, RwkvRuntime, StatePrecision};

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

/// 每个模型的回放统计。
#[derive(Clone, Default)]
struct ModelStats {
    seconds: f64,
    peak_card: f32,
    peak_note: f32,
    nonfinite: usize,
}

fn parse_precision(arg: &str) -> StatePrecision {
    match arg {
        "f32" => StatePrecision::F32,
        "int8" => StatePrecision::Int8,
        "int4" => StatePrecision::Int4,
        other => panic!("unknown precision {other}"),
    }
}

fn load_models(specs: &[String]) -> Vec<(String, Model)> {
    specs
        .iter()
        .map(|spec| {
            let (name, path) = spec.split_once('=').unwrap();
            (
                name.to_owned(),
                Model::from_bytes(&std::fs::read(path).unwrap()).unwrap(),
            )
        })
        .collect()
}

/// 目录：其中全部 *.bin（按大小升序）；文件：它自己。
fn history_files(target: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = if target.is_dir() {
        std::fs::read_dir(target)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.extension().is_some_and(|e| e == "bin"))
            .collect()
    } else {
        vec![target.to_path_buf()]
    };
    files.sort_by_key(|p| std::fs::metadata(p).unwrap().len());
    files
}

/// 不计分的首条复习：有 `<file>.first` 就按它，否则按 `elapsed_days == -1`。
fn first_rows(file: &Path, rows: &[FrwkvReview]) -> Vec<bool> {
    match std::fs::read(format!("{}.first", file.display())) {
        Ok(bytes) => {
            assert_eq!(bytes.len(), rows.len());
            bytes.iter().map(|&b| b != 0).collect()
        }
        Err(_) => rows.iter().map(|r| r.elapsed_days == -1).collect(),
    }
}

/// 每行的聚类单元与单元总数：按用户（`user` = 文件序号, 用户数）时整个文件是一个单元，否则每卡一个。
fn cluster_units(rows: &[FrwkvReview], user: Option<(usize, usize)>) -> (Vec<usize>, usize) {
    if let Some((index, users)) = user {
        return (vec![index; rows.len()], users);
    }
    let mut card_index: HashMap<i64, usize> = HashMap::new();
    let units = rows
        .iter()
        .map(|r| {
            let next = card_index.len();
            *card_index.entry(r.card_id).or_insert(next)
        })
        .collect();
    (units, card_index.len())
}

/// 一个模型回放整段历史，返回每行作答前的 R。
fn replay(
    model: &Model,
    precision: StatePrecision,
    inputs: &[ReviewInput],
    stats: &mut ModelStats,
) -> Vec<f32> {
    let mut runtime = RwkvRuntime::new(model, precision, 0).unwrap();
    let started = Instant::now();
    let mut p = vec![f32::NAN; inputs.len()];
    for (block, chunk) in inputs.chunks(65_536).enumerate() {
        for (index, value) in runtime.replay(chunk, true).unwrap() {
            p[block * 65_536 + index] = value;
        }
    }
    stats.seconds += started.elapsed().as_secs_f64();
    if let Some(peaks) = runtime.state_peaks() {
        stats.peak_card = stats.peak_card.max(peaks[0]);
        stats.peak_note = stats.peak_note.max(peaks[2]);
    }
    p
}

/// 一个文件的回放结果（每模型每行的 R）与计分所需的行信息。
struct ScoredFile<'a> {
    rows: &'a [FrwkvReview],
    first: &'a [bool],
    unit_of: &'a [usize],
    predictions: &'a [Vec<f32>],
}

/// 把一个文件的计分行累加进 `acc`。任一模型非有限的行整行不计（保持成对）。
fn score_rows(file: &ScoredFile, acc: &mut Acc, stats: &mut [ModelStats]) {
    for (i, row) in file.rows.iter().enumerate() {
        if row.ease == 0 || file.first[i] {
            continue;
        }
        if file.predictions.iter().any(|p| !p[i].is_finite()) {
            for (m, p) in file.predictions.iter().enumerate() {
                stats[m].nonfinite += usize::from(!p[i].is_finite());
            }
            continue;
        }
        for (s, slice) in acc.iter_mut().enumerate() {
            if !in_slice(s, row) {
                continue;
            }
            for (m, p) in file.predictions.iter().enumerate() {
                let slot = &mut slice[m][file.unit_of[i]];
                slot.0 += loss_of(p[i], row.ease);
                slot.1 += 1;
            }
        }
    }
}

/// 模型 `m` 减基线的 LogLoss 差：聚类 bootstrap（2,000 次，按条加权）的 2.5% / 97.5% 分位。
fn bootstrap_interval(
    per_model: &[Vec<(f64, u64)>],
    m: usize,
    active: &[usize],
    seed: u64,
) -> (f64, f64) {
    let mut rng = Rng(seed);
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
    (diffs[50], diffs[1949])
}

/// 按用户时：LogLoss 赢基线的单元数 / 有计分的单元数；否则空。
fn units_better(
    per_model: &[Vec<(f64, u64)>],
    m: usize,
    active: &[usize],
    by_user: bool,
) -> String {
    if !by_user {
        return String::new();
    }
    let wins = active
        .iter()
        .filter(|&&u| per_model[m][u].0 < per_model[0][u].0)
        .count();
    format!("{wins}/{}", active.len())
}

fn print_report(acc: &Acc, names: &[&str], by_user: bool) {
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
        println!(
            "{slice_name}\t{}\t{}\t{base:.6}\t\t\t\t\t",
            names[0], totals[0].1
        );
        for (m, name) in names.iter().enumerate().skip(1) {
            let ll = totals[m].0 / totals[m].1.max(1) as f64;
            let seed = 0x5EED + m as u64 + 101 * s as u64;
            let (low, high) = bootstrap_interval(per_model, m, &active, seed);
            let better = units_better(per_model, m, &active, by_user);
            println!(
                "{slice_name}\t{name}\t{}\t{ll:.6}\t{:+.6}\t{low:+.6}\t{high:+.6}\t{:+.3}\t{better}",
                totals[m].1,
                ll - base,
                100.0 * (ll - base) / base
            );
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let target = PathBuf::from(&args[1]);
    let precision = parse_precision(&args[2]);
    let models = load_models(&args[3..]);
    let by_user = target.is_dir();
    let files = history_files(&target);

    let mut acc: Acc = vec![vec![Vec::new(); models.len()]; SLICES.len()];
    let mut stats = vec![ModelStats::default(); models.len()];
    let started_all = Instant::now();
    for (file_index, file) in files.iter().enumerate() {
        let rows = read_rows(file);
        let first = first_rows(file, &rows);
        let inputs: Vec<_> = rows.iter().map(|r| r.to_input(false).unwrap()).collect();
        let (unit_of, units) = cluster_units(&rows, by_user.then_some((file_index, files.len())));
        for per_model in acc.iter_mut().flatten() {
            per_model.resize(units, (0.0, 0));
        }
        let predictions: Vec<Vec<f32>> = models
            .iter()
            .zip(stats.iter_mut())
            .map(|((_, model), stats)| replay(model, precision, &inputs, stats))
            .collect();
        let scored = ScoredFile {
            rows: &rows,
            first: &first,
            unit_of: &unit_of,
            predictions: &predictions,
        };
        score_rows(&scored, &mut acc, &mut stats);
        if by_user && (file_index + 1) % 25 == 0 {
            eprintln!(
                "{}/{} users, {:.0}s",
                file_index + 1,
                files.len(),
                started_all.elapsed().as_secs_f64()
            );
        }
    }
    for ((name, _), s) in models.iter().zip(&stats) {
        eprintln!(
            "{name}: replay {:.1}s, max peak card {:.3} note {:.3}, nonfinite {}",
            s.seconds, s.peak_card, s.peak_note, s.nonfinite
        );
    }
    let names: Vec<&str> = models.iter().map(|(name, _)| name.as_str()).collect();
    print_report(&acc, &names, by_user);
}
