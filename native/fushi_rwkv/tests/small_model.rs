// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 小模型（sm72e25）对拍：上游 `rslib/src/rwkv/testdata/sm72e25-vectors.json.gz` 里 NumPy 参考
//! 实现的黄金值（两位 benchmark 用户各 500 行，无泄漏输入，f32 / int8 两种权重），逐行比对
//! p_imm、四个评分概率、标签时刻与 6 个扫描时刻的 p_curve，容差 1e-5（发布包自己的验收标准）。
//! 另测：缺失 ID 标志（输入 13–15）不影响任何输出（无泄漏规则）、块边界不影响结果。

mod common;

use common::{SmallFile, small_file};
use fushi_rwkv::{Model, ModelKind, SmallHeads, SmallInference, SmallModel, StatePrecision};
use serde::Deserialize;

const TOLERANCE: f32 = 1e-5;
const CARD_FEATURES: usize = 92;
/// 训练导出里标「已删除卡」的缺失 note / deck / preset 标志（无泄漏规则恒为 0）。
const MISSING_ID_FLAGS: [usize; 3] = [13, 14, 15];

fn small_model(file: SmallFile) -> SmallModel {
    match Model::from_bytes(small_file(file)).expect("parse weights") {
        Model::Small(model) => model,
        Model::Large(_) => panic!("{file:?} parsed as the large model"),
    }
}

#[derive(Deserialize)]
struct VectorRow {
    features: Vec<f32>,
    /// card, deck, note, preset, user（与本库的流顺序相同）。
    ids: [i64; 5],
    /// 查询行（不提交状态）。
    skip: bool,
    /// 标签时刻（距上次作答的秒数）。
    elapsed: f32,
    /// p_imm、四个评分概率、p_curve(elapsed)、6 个扫描时刻的 p_curve。
    fp32: Vec<f32>,
    int8: Vec<f32>,
}

#[derive(Deserialize)]
struct UserVectors {
    name: String,
    sweep: Vec<f32>,
    rows: Vec<VectorRow>,
}

struct Vectors {
    name: String,
    n: usize,
    features: Vec<f32>,
    keys: Vec<[i64; 5]>,
    commit: Vec<bool>,
    elapsed: Vec<f32>,
    sweep: Vec<f32>,
    fp32: Vec<Vec<f32>>,
    int8: Vec<Vec<f32>>,
}

fn vectors() -> Vec<Vectors> {
    let json = flate2::read::GzDecoder::new(small_file(SmallFile::Vectors));
    let users: Vec<UserVectors> = serde_json::from_reader(json).expect("parse vectors");
    assert_eq!(users.len(), 2);
    users
        .into_iter()
        .map(|user| {
            let n = user.rows.len();
            assert!(n > 0);
            let mut features = Vec::with_capacity(n * CARD_FEATURES);
            for row in &user.rows {
                assert_eq!(row.features.len(), CARD_FEATURES);
                assert_eq!(row.fp32.len(), 6 + user.sweep.len());
                features.extend_from_slice(&row.features);
            }
            Vectors {
                name: user.name,
                n,
                features,
                keys: user.rows.iter().map(|r| r.ids).collect(),
                commit: user.rows.iter().map(|r| !r.skip).collect(),
                elapsed: user.rows.iter().map(|r| r.elapsed).collect(),
                sweep: user.sweep,
                fp32: user.rows.iter().map(|r| r.fp32.clone()).collect(),
                int8: user.rows.iter().map(|r| r.int8.clone()).collect(),
            }
        })
        .collect()
}

/// 一行的 12 个输出，顺序同黄金值。p_imm 与上游一样夹到 [1e-5, 1 − 1e-5]。
fn outputs(heads: &SmallHeads, elapsed: f32, sweep: &[f32]) -> Vec<f32> {
    let mut out = vec![heads.retrievability().clamp(1e-5, 1.0 - 1e-5)];
    out.extend(heads.rating_probabilities());
    // 库里的 `p_curve`（INTEGRATION.md §9.1）：排程用的就是这一份，黄金向量直接钉它。
    out.push(heads.curve_retrievability(elapsed));
    out.extend(sweep.iter().map(|&t| heads.curve_retrievability(t)));
    out
}

fn check(weights: SmallFile, chunk: usize) -> f32 {
    let model = small_model(weights);
    let mut worst = 0.0f32;
    for v in vectors() {
        let expected = match weights {
            SmallFile::F32Weights => &v.fp32,
            SmallFile::Int8Weights => &v.int8,
            other => panic!("{other:?} is not a weights file"),
        };
        let mut runtime = SmallInference::new(&model, StatePrecision::F32);
        let heads = runtime.run_prepared_rows(&v.features, &v.keys, &v.commit, chunk);
        assert_eq!(heads.len(), v.n);
        for (row, heads) in heads.iter().enumerate() {
            let got = outputs(heads, v.elapsed[row], &v.sweep);
            for (head, (&a, &b)) in got.iter().zip(&expected[row]).enumerate() {
                let diff = (a - b).abs();
                assert!(
                    diff <= TOLERANCE,
                    "{} {weights:?} chunk {chunk} row {row} head {head}: got {a}, want {b} (diff {diff})",
                    v.name
                );
                worst = worst.max(diff);
            }
        }
        assert!(v.commit.iter().any(|&c| c) && v.commit.iter().any(|&c| !c));
    }
    worst
}

#[test]
fn weight_files_load_as_the_small_model_with_the_published_schedule() {
    for file in [SmallFile::F32Weights, SmallFile::Int8Weights] {
        let model = Model::from_bytes(small_file(file)).unwrap();
        assert_eq!(model.kind(), ModelKind::Small, "{file:?}");
    }
    let architecture: serde_json::Value =
        serde_json::from_slice(small_file(SmallFile::Architecture)).unwrap();
    let published: Vec<(usize, usize)> = architecture["layer_steps"]
        .as_array()
        .unwrap()
        .iter()
        .map(|step| {
            (
                step[0].as_u64().unwrap() as usize,
                step[1].as_u64().unwrap() as usize,
            )
        })
        .collect();
    assert_eq!(small_model(SmallFile::F32Weights).layer_steps(), published);
    assert_eq!(architecture["zero_features"], serde_json::json!([22]));
    assert_eq!(architecture["d_model"], 64);
}

#[test]
fn matches_reference_f32_weights() {
    let worst = check(SmallFile::F32Weights, 1 << 20);
    eprintln!("fp32 weights: worst diff {worst:e}");
}

#[test]
fn matches_reference_int8_weights() {
    let worst = check(SmallFile::Int8Weights, 1 << 20);
    eprintln!("int8 weights: worst diff {worst:e}");
}

/// 无泄漏规则：把缺失 ID 标志（输入 13–15）全置 1，回放与查询的每个输出逐位不变。
/// 去掉 `LEAK_FREE_ZERO_FEATURES` 的清零即红（这些权重对这三个输入并不是零响应）。
#[test]
fn missing_id_flags_change_no_output() {
    let model = small_model(SmallFile::Int8Weights);
    for v in vectors() {
        assert!(
            MISSING_ID_FLAGS
                .iter()
                .all(|&f| (0..v.n).all(|row| v.features[row * CARD_FEATURES + f] == 0.0)),
            "{}: published vectors keep the flags at 0",
            v.name
        );
        let mut flagged = v.features.clone();
        for row in 0..v.n {
            for f in MISSING_ID_FLAGS {
                flagged[row * CARD_FEATURES + f] = 1.0;
            }
        }
        for precision in [StatePrecision::F32, StatePrecision::Int4] {
            let run = |features: &[f32]| {
                let mut runtime = SmallInference::new(&model, precision);
                runtime.run_prepared_rows(features, &v.keys, &v.commit, 1 << 20)
            };
            let (plain, with_flags) = (run(&v.features), run(&flagged));
            for (row, (a, b)) in plain.iter().zip(&with_flags).enumerate() {
                assert_eq!(
                    outputs(a, v.elapsed[row], &v.sweep)
                        .iter()
                        .map(|x| x.to_bits())
                        .collect::<Vec<_>>(),
                    outputs(b, v.elapsed[row], &v.sweep)
                        .iter()
                        .map(|x| x.to_bits())
                        .collect::<Vec<_>>(),
                    "{} {precision:?} row {row}",
                    v.name
                );
            }
        }
    }
}

/// 块边界（每次引擎调用的行数）只影响批处理方式，不影响结果。
#[test]
fn chunking_does_not_change_results() {
    let v = vectors().remove(0);
    let model = small_model(SmallFile::Int8Weights);
    for precision in [
        StatePrecision::F32,
        StatePrecision::Int8,
        StatePrecision::Int4,
    ] {
        let run = |chunk: usize| {
            let mut runtime = SmallInference::new(&model, precision);
            runtime.run_prepared_rows(&v.features, &v.keys, &v.commit, chunk)
        };
        let whole = run(1 << 20);
        for chunk in [1, 7, 333] {
            let split = run(chunk);
            for (row, (a, b)) in whole.iter().zip(&split).enumerate() {
                assert_eq!(
                    a.p_logits.map(f32::to_bits),
                    b.p_logits.map(f32::to_bits),
                    "{precision:?} chunk {chunk} row {row}"
                );
            }
        }
    }
}
