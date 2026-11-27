// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 小模型对拍，Small Instant-Only（sm113，"w64"）与默认的六层 Tiny Instant-Only（sm130io，"w64-c1-d2p1u1"）
//! 两套都跑（同一套由权重张量目录推出架构的代码）：上游 `rslib/src/rwkv/testdata/<模型>-vectors.json.gz` 里 NumPy 参考
//! 实现的黄金值（两位用户各 500 行，无泄漏输入，show-time 查询行，f32 / int8 两种权重），逐行比对
//! p_imm、四个评分概率、标签时刻与 6 个扫描时刻的 p_curve（曲线头没训练过，这里只当网络数值对拍），
//! 容差 1e-5（发布包自己的验收标准）。
//! 另测：本库的特征构造（回放时每条作答的查询行 + 更新行）与向量里训练用的输入逐列一致（§6.10 的
//! show-time 查询行）；缺失 ID 标志（输入 13–15）不影响任何输出（无泄漏规则）；块边界不影响结果；
//! RWKV-Curve 对 Instant-Only 模型明确拒绝。

mod common;

use common::{SmallFile, SmallModelId, small_file_of};
use fushi_rwkv::{
    Model, ModelKind, ReviewInput, RwkvError, RwkvRuntime, SmallHeads, SmallInference, SmallModel,
    StatePrecision, show_time_query,
};
use serde::Deserialize;

const TOLERANCE: f32 = 1e-5;
const CARD_FEATURES: usize = 92;
/// 训练导出里标「已删除卡」的缺失 note / deck / preset 标志（无泄漏规则恒为 0）。
const MISSING_ID_FLAGS: [usize; 3] = [13, 14, 15];

fn small_model(id: SmallModelId, file: SmallFile) -> SmallModel {
    match Model::from_bytes(small_file_of(id, file)).expect("parse weights") {
        Model::Small(model) => model,
        Model::Large(_) => panic!("{id:?} {file:?} parsed as the large model"),
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
    /// 这一行输入用的原始间隔 `[elapsed_seconds, elapsed_days]`（首次 -1）：查询行是出示时刻的
    /// 间隔（INTEGRATION.md §6.10），更新行是作答到作答。
    interval: [f64; 2],
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
    interval: Vec<[f64; 2]>,
    features: Vec<f32>,
    keys: Vec<[i64; 5]>,
    commit: Vec<bool>,
    elapsed: Vec<f32>,
    sweep: Vec<f32>,
    fp32: Vec<Vec<f32>>,
    int8: Vec<Vec<f32>>,
}

fn vectors(id: SmallModelId) -> Vec<Vectors> {
    let json = flate2::read::GzDecoder::new(small_file_of(id, SmallFile::Vectors));
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
                name: format!("{} {}", id.name(), user.name),
                n,
                interval: user.rows.iter().map(|r| r.interval).collect(),
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

fn check(id: SmallModelId, weights: SmallFile, chunk: usize) -> f32 {
    let model = small_model(id, weights);
    let mut worst = 0.0f32;
    for v in vectors(id) {
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
    for id in SmallModelId::ALL {
        for file in [SmallFile::F32Weights, SmallFile::Int8Weights] {
            let model = Model::from_bytes(small_file_of(id, file)).unwrap();
            assert_eq!(model.kind(), ModelKind::Small, "{id:?} {file:?}");
        }
        let architecture: serde_json::Value =
            serde_json::from_slice(small_file_of(id, SmallFile::Architecture)).unwrap();
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
        for file in [SmallFile::F32Weights, SmallFile::Int8Weights] {
            assert_eq!(
                small_model(id, file).layer_steps(),
                published,
                "{id:?} {file:?}"
            );
        }
        assert_eq!(architecture["zero_features"], serde_json::json!([22]));
        assert_eq!(architecture["d_model"], 64);
    }
}

/// 两套架构确实不同（层数 / 调度步：Small 13 步，六层 Tiny 6 步），且 Tiny 的每卡状态更小。
#[test]
fn tiny_model_has_its_own_architecture_and_smaller_card_state() {
    let small = small_model(SmallModelId::Sm113, SmallFile::Int8Weights);
    let tiny = small_model(SmallModelId::Sm130io, SmallFile::Int8Weights);
    assert_eq!(small.layer_steps().len(), 13);
    assert_eq!(
        tiny.layer_steps(),
        vec![(0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (1, 1)]
    );
    assert_ne!(small.fingerprint(), tiny.fingerprint());
    // 同一段复习回放进两个模型，比每张卡 / 每个笔记的状态字节数（Fushi 用的 card / note 都是 int4）。
    let per_entity = |model: &SmallModel, id: SmallModelId| {
        let v = vectors(id).remove(0);
        let mut runtime = SmallInference::new(model, StatePrecision::Int4);
        runtime.run_prepared_rows(&v.features, &v.keys, &v.commit, 1 << 20);
        let stats = runtime.stats();
        (
            (
                stats.card_state_bytes / stats.cards,
                stats.note_state_bytes / stats.notes,
            ),
            runtime.snapshot(),
        )
    };
    let ((s, small_snapshot), (t, tiny_snapshot)) = (
        per_entity(&small, SmallModelId::Sm113),
        per_entity(&tiny, SmallModelId::Sm130io),
    );
    eprintln!("int4 state per card / note: sm113 {s:?} B, sm130io {t:?} B");
    assert!(t.0 < s.0 && t.1 <= s.1, "sm113 {s:?}, sm130io {t:?}");
    // 换模型（设置里切 Small / Tiny）时旧快照按权重指纹被拒，排程内核据此全量重放；同模型照常恢复。
    for (model, own, other) in [
        (&small, &small_snapshot, &tiny_snapshot),
        (&tiny, &tiny_snapshot, &small_snapshot),
    ] {
        let mut runtime = SmallInference::new(model, StatePrecision::Int4);
        assert!(runtime.restore_snapshot(other).is_err());
        runtime.restore_snapshot(own).unwrap();
        assert_eq!(&runtime.snapshot(), own);
    }
}

/// 层结构按权重里各流的层数认：只认 "w64"（Small）与六层 Tiny 两种 plan，对不上的拒绝加载，不拿没人训练 /
/// 对拍过的调度去跑。改名保持名字长度，权重文件的其余字节不变。
#[test]
fn weights_with_an_unknown_layer_layout_are_refused() {
    let tiny = small_file_of(SmallModelId::Sm130io, SmallFile::F32Weights);
    let rename = |from: &str, to: &str| -> Vec<u8> {
        assert_eq!(from.len(), to.len());
        let (from, to) = (from.as_bytes(), to.as_bytes());
        let mut bytes = tiny.to_vec();
        let mut hits = 0;
        let mut at = 0;
        while let Some(offset) = bytes[at..].windows(from.len()).position(|w| w == from) {
            let start = at + offset;
            bytes[start..start + to.len()].copy_from_slice(to);
            at = start + to.len();
            hits += 1;
        }
        assert!(hits > 5, "{hits}");
        bytes
    };
    let refusal = |bytes: &[u8]| match Model::from_bytes(bytes) {
        Ok(_) => panic!("loaded a weight file with a broken layer layout"),
        Err(error) => error.to_string(),
    };
    // deck 流的第 2 层挪到 preset 流：层数 [1, 1, 1, 2, 1]，不是已知 plan。
    let moved = refusal(&rename(
        "rwkv_modules.1.blocks.1.",
        "rwkv_modules.3.blocks.1.",
    ));
    assert!(moved.contains("does not load"), "{moved}");
    // deck 流缺第 2 层、多出第 3 层：中间断了，多出来的张量不能被静默忽略。
    let gap = refusal(&rename(
        "rwkv_modules.1.blocks.1.",
        "rwkv_modules.1.blocks.2.",
    ));
    assert!(gap.contains("outside its layers"), "{gap}");
    // 原样的文件照常加载。
    assert!(Model::from_bytes(tiny).is_ok());
}

#[test]
fn matches_reference_f32_weights() {
    for id in SmallModelId::ALL {
        let worst = check(id, SmallFile::F32Weights, 1 << 20);
        eprintln!("{id:?} fp32 weights: worst diff {worst:e}");
    }
}

#[test]
fn matches_reference_int8_weights() {
    for id in SmallModelId::ALL {
        let worst = check(id, SmallFile::Int8Weights, 1 << 20);
        eprintln!("{id:?} int8 weights: worst diff {worst:e}");
    }
}

/// 无泄漏规则：把缺失 ID 标志（输入 13–15）全置 1，回放与查询的每个输出逐位不变。
/// 去掉 `LEAK_FREE_ZERO_FEATURES` 的清零即红（这些权重对这三个输入并不是零响应）。
#[test]
fn missing_id_flags_change_no_output() {
    for id in SmallModelId::ALL {
        missing_id_flags_change_no_output_for(id);
    }
}

fn missing_id_flags_change_no_output_for(id: SmallModelId) {
    let model = small_model(id, SmallFile::Int8Weights);
    for v in vectors(id) {
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
    for id in SmallModelId::ALL {
        chunking_does_not_change_results_for(id);
    }
}

fn chunking_does_not_change_results_for(id: SmallModelId) {
    let v = vectors(id).remove(0);
    let model = small_model(id, SmallFile::Int8Weights);
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
                    "{id:?} {precision:?} chunk {chunk} row {row}"
                );
            }
        }
    }
}

/// 从向量的更新行还原本库的回放输入：间隔取 `interval`，评分取 one-hot（输入 9–12），时长从输入 8
/// 反解（`ln(10 + ms)` 标准化），调度日从输入 16（距上一条复习的天数，`ln(ln(e + d))`）累加。
/// 返回每条更新行的（行号，输入）。
fn replay_inputs(v: &Vectors) -> Vec<(usize, ReviewInput)> {
    let mut day = 0i64;
    let mut out = Vec::new();
    for row in (0..v.n).filter(|&row| v.commit[row]) {
        let f = &v.features[row * CARD_FEATURES..(row + 1) * CARD_FEATURES];
        let rating = (9..13)
            .find(|&i| f[i] == 1.0)
            .expect("update row without a rating") as u8
            - 8;
        let duration = ((f[8] as f64 * 1.07 + 8.9).exp() - 10.0).round() as i64;
        let day_gap = ((f[16] as f64).exp().exp() - std::f64::consts::E).round() as i64;
        day += day_gap;
        let [seconds, days] = v.interval[row];
        let ids = v.keys[row];
        out.push((
            row,
            ReviewInput {
                card_id: ids[0],
                note_id: Some(ids[2]),
                deck_id: Some(ids[1]),
                preset_id: Some(ids[3]),
                is_query: false,
                ease: Some(rating),
                duration_millis: Some(duration),
                card_type: Some(2),
                day_offset: Some(day),
                current_elapsed_days: Some(days as i64),
                current_elapsed_seconds: Some(seconds as i64),
            },
        ));
    }
    out
}

/// 本库回放时为每条作答构造的两行（作答前的查询行、作答的更新行）与向量里训练 / 打分用的输入逐列
/// 一致：输入 0–21 与 23（22 被模型清零；24–91 是随机实体编码与带随机基线的日历编码，按设计不可复现）。
/// 查询行的 2–7 列是出示时刻的间隔（§6.10，`elapsed − duration / 1000`），按作答间隔构造即红。
#[test]
fn replay_builds_the_trained_query_and_update_rows() {
    for id in SmallModelId::ALL {
        replay_builds_the_trained_query_and_update_rows_for(id);
    }
}

fn replay_builds_the_trained_query_and_update_rows_for(id: SmallModelId) {
    const COLUMNS: [std::ops::Range<usize>; 2] = [0..22, 23..24];
    let model = small_model(id, SmallFile::Int8Weights);
    let mut checked = [0usize; 2];
    let mut show_time_rows = 0;
    for v in vectors(id) {
        let inputs = replay_inputs(&v);
        let reviews: Vec<ReviewInput> = inputs.iter().map(|(_, input)| input.clone()).collect();
        let mut runtime = SmallInference::new(&model, StatePrecision::F32);
        let built = runtime.replay_features(&reviews);
        assert_eq!(built.len(), inputs.len());
        for ((row, _), (index, query, update)) in inputs.iter().zip(&built) {
            let row = *row;
            assert_eq!(inputs[*index].0, row);
            let mut compare = |kind: usize, vector_row: usize, got: &[f32]| {
                let want =
                    &v.features[vector_row * CARD_FEATURES..(vector_row + 1) * CARD_FEATURES];
                for column in COLUMNS.iter().cloned().flatten() {
                    assert!(
                        (got[column] - want[column]).abs() <= 1e-4,
                        "{} row {vector_row} ({}) input {column}: built {}, trained {}",
                        v.name,
                        ["query", "update"][kind],
                        got[column],
                        want[column]
                    );
                }
                checked[kind] += 1;
            };
            compare(1, row, update);
            // 向量里首次复习没有查询行；其余每条更新行前紧挨着同一复习的查询行。
            if row > 0 && !v.commit[row - 1] {
                assert_eq!(v.keys[row - 1], v.keys[row]);
                compare(0, row - 1, query);
                if v.interval[row - 1][0] != v.interval[row][0] {
                    show_time_rows += 1;
                }
            }
        }
    }
    eprintln!(
        "{id:?}: checked {} query rows ({show_time_rows} with a show-time interval) and {} update rows",
        checked[0], checked[1]
    );
    assert!(checked[0] > 100 && checked[1] > 100, "{checked:?}");
    assert!(show_time_rows > 100, "vectors do not exercise §6.10");
}

/// Instant-Only 模型的曲线头没训练过：RWKV-Curve（作答时排程）一律拒绝，不给垃圾间隔；即时头照常。
#[test]
fn instant_only_small_model_refuses_rwkv_curve() {
    for id in SmallModelId::ALL {
        instant_only_small_model_refuses_rwkv_curve_for(id);
    }
}

fn instant_only_small_model_refuses_rwkv_curve_for(id: SmallModelId) {
    let model = Model::from_bytes(small_file_of(id, SmallFile::Int8Weights)).unwrap();
    assert!(!model.kind().has_trained_curve_head());
    let mut runtime = RwkvRuntime::new(&model, StatePrecision::Int4, 1).unwrap();
    let answer = ReviewInput {
        card_id: 1,
        note_id: Some(2),
        deck_id: Some(3),
        preset_id: Some(4),
        is_query: false,
        ease: Some(3),
        duration_millis: Some(4_000),
        card_type: Some(2),
        day_offset: Some(10),
        current_elapsed_days: Some(3),
        current_elapsed_seconds: Some(3 * 86_400),
    };
    let mut first = answer.clone();
    first.day_offset = Some(7);
    first.card_type = Some(0);
    first.current_elapsed_days = Some(-1);
    first.current_elapsed_seconds = Some(-1);
    runtime.replay(&[first], false).unwrap();
    let before = runtime.snapshot().unwrap();
    assert!(matches!(
        runtime.next_intervals(&answer, 0.9, 365),
        Err(RwkvError::Unsupported(_))
    ));
    assert!(matches!(
        runtime.answer_curves(&answer),
        Err(RwkvError::Unsupported(_))
    ));
    assert_eq!(runtime.snapshot().unwrap(), before);
    let mut query = answer.clone();
    query.is_query = true;
    let r = runtime.query(&[query]).unwrap()[0];
    assert!((0.0..=1.0).contains(&r), "{r}");
}

/// §6.10 的取整与边界：`floor(max(elapsed − duration / 1000, 0))`，首次（-1）不变，天数不变（缺省时
/// 按原作答间隔推出、不跟着出示时刻走），没有时长时只能保持作答间隔；评分与时长清空。
#[test]
fn show_time_query_rounding_and_edges() {
    let answer = |seconds: Option<i64>, days: Option<i64>, millis: Option<i64>| ReviewInput {
        card_id: 1,
        note_id: Some(2),
        deck_id: Some(3),
        preset_id: Some(4),
        is_query: false,
        ease: Some(3),
        duration_millis: millis,
        card_type: Some(2),
        day_offset: Some(10),
        current_elapsed_days: days,
        current_elapsed_seconds: seconds,
    };
    let shown = |a: &ReviewInput| {
        let q = show_time_query(a);
        assert!(q.is_query && q.ease.is_none() && q.duration_millis.is_none());
        (q.current_elapsed_seconds, q.current_elapsed_days)
    };
    // 21,192 s − 11.205 s → 21,180.795 → 21,180（向量 user_1745 第一组查询 / 更新行）。
    assert_eq!(
        shown(&answer(Some(21_192), Some(0), Some(11_205))),
        (Some(21_180), Some(0))
    );
    assert_eq!(
        shown(&answer(Some(100), Some(0), Some(100_000))),
        (Some(0), Some(0))
    );
    assert_eq!(
        shown(&answer(Some(100), Some(0), Some(1_000))),
        (Some(99), Some(0))
    );
    assert_eq!(
        shown(&answer(Some(100), Some(0), Some(1))),
        (Some(99), Some(0))
    );
    assert_eq!(
        shown(&answer(Some(-1), Some(-1), Some(5_000))),
        (Some(-1), Some(-1))
    );
    assert_eq!(
        shown(&answer(Some(500), Some(0), None)),
        (Some(500), Some(0))
    );
    // 天数缺省：按作答间隔推出（86,401 s → 1 天），不按出示时刻（86,391 s → 0 天）。
    assert_eq!(
        shown(&answer(Some(86_401), None, Some(10_000))),
        (Some(86_391), Some(1))
    );
    // 首次复习的学习起点（card_type 0）：作答行不读 elapsed，查询行读「自创建起」的间隔，同样减去时长。
    let mut learning_start = answer(Some(3_600), Some(0), Some(6_000));
    learning_start.card_type = Some(0);
    assert_eq!(shown(&learning_start), (Some(3_594), Some(0)));
}
