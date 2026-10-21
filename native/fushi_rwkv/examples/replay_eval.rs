// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 真实复习历史上的端到端评测：每个用户一个 `FrwkvReview` 二进制文件（80 字节一行，复习顺序），
//! 按 65,536 条一块回放并记录每条作答前的 R，对**非首次**复习算 LogLoss（y = 不是 Again）。
//! 走的是部署路径（本库的特征构造器、ID 编码、批量回放），不是训练仓库的打分器。
//!
//! cargo run --release --example replay_eval -- <large.bin> <small.bin> <dir> <config,...> [user ...]
//!   config：large:f32 / large:int8 / large:int4 / small:f32 / small:int8 / small:int4
//!   不给 user 时评测目录里全部 *.bin（按文件大小升序）。
//! 输出每用户每配置一行 TSV：user rows scored logloss seconds peak_card peak_note peak_user nonfinite

use std::path::{Path, PathBuf};
use std::time::Instant;

use fushi_rwkv::{FrwkvReview, Model, RwkvRuntime, StatePrecision};

fn read_rows(path: &Path) -> Vec<FrwkvReview> {
    let bytes = std::fs::read(path).unwrap();
    assert_eq!(bytes.len() % 80, 0, "{}", path.display());
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

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let large = Model::from_bytes(&std::fs::read(&args[1]).unwrap()).unwrap();
    let small = Model::from_bytes(&std::fs::read(&args[2]).unwrap()).unwrap();
    let dir = PathBuf::from(&args[3]);
    let configs: Vec<(String, &Model, StatePrecision)> = args[4]
        .split(',')
        .map(|config| {
            let (model, precision) = config.split_once(':').unwrap();
            let model = match model {
                "large" => &large,
                "small" => &small,
                other => panic!("unknown model {other}"),
            };
            let precision = match precision {
                "f32" => StatePrecision::F32,
                "int8" => StatePrecision::Int8,
                "int4" => StatePrecision::Int4,
                other => panic!("unknown precision {other}"),
            };
            (config.to_owned(), model, precision)
        })
        .collect();
    let mut files: Vec<PathBuf> = if args.len() > 5 {
        args[5..].iter().map(|u| dir.join(format!("{u}.bin"))).collect()
    } else {
        std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.extension().is_some_and(|e| e == "bin"))
            .collect()
    };
    files.sort_by_key(|p| std::fs::metadata(p).unwrap().len());
    println!("config\tuser\trows\tscored\tlogloss\tseconds\tpeak_card\tpeak_note\tpeak_user\tnonfinite");
    for file in files {
        let user = file.file_stem().unwrap().to_string_lossy().into_owned();
        let rows = read_rows(&file);
        let inputs: Vec<_> = rows.iter().map(|r| r.to_input(false).unwrap()).collect();
        for (name, model, precision) in &configs {
            let mut runtime = RwkvRuntime::new(model, *precision, 0).unwrap();
            let started = Instant::now();
            let mut predictions = vec![f32::NAN; inputs.len()];
            for (block, chunk) in inputs.chunks(65_536).enumerate() {
                for (index, p) in runtime.replay(chunk, true).unwrap() {
                    predictions[block * 65_536 + index] = p;
                }
            }
            let seconds = started.elapsed().as_secs_f64();
            let (mut loss, mut scored, mut nonfinite) = (0.0f64, 0usize, 0usize);
            for (row, p) in rows.iter().zip(&predictions) {
                if row.elapsed_days == -1 || row.ease == 0 {
                    continue;
                }
                if !p.is_finite() {
                    nonfinite += 1;
                    continue;
                }
                let p = (*p as f64).clamp(1e-6, 1.0 - 1e-6);
                loss -= if row.ease > 1 { p.ln() } else { (1.0 - p).ln() };
                scored += 1;
            }
            let peaks = runtime.state_peaks().unwrap_or([f32::NAN; 5]);
            println!(
                "{name}\t{user}\t{}\t{scored}\t{:.6}\t{seconds:.2}\t{:.4}\t{:.4}\t{:.4}\t{nonfinite}",
                rows.len(),
                loss / scored.max(1) as f64,
                peaks[0],
                peaks[2],
                peaks[4],
            );
        }
    }
}
