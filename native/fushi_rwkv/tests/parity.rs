// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 与上游实现对拍。黄金值全部来自上游：
//! - tests/fixtures/*.json 由 tools/oracle（把 kuma3-anki-core 的 `rslib/src/rwkv`
//!   **原样**编译进去）对同一组输入跑 `warm_up_reviews` / `predict_retrievability_many_from_warm_up`
//!   得出，f32 与 int8 两种状态精度各一份；
//! - 另外核对上游自己测试里写死的两个数（qt/tests/test_rwkv_inference_process.py 的
//!   `_RWKV_GOLDEN_ROW0_IMMEDIATE` / `_RWKV_GOLDEN_ROW34_IMMEDIATE`）。
mod common;

use common::*;
use fushi_rwkv::{Model, RwkvInference, RwkvRuntime, StatePrecision};

/// 用上游原样的 API（`RwkvInference`）跑夹具的每一步。
fn run_raw(fixture: &Fixture, inference: &mut RwkvInference) -> Vec<Output> {
    fixture
        .steps
        .iter()
        .map(|step| match step {
            Step::WarmUp {
                record_predictions,
                rows,
            } => Output::Predictions(
                inference
                    .warm_up_reviews(inputs(rows, false), *record_predictions)
                    .expect("warm up"),
            ),
            Step::Query { rows } => Output::Retrievability(
                inference
                    .predict_retrievability_many_from_warm_up(inputs(rows, true))
                    .expect("query"),
            ),
        })
        .collect()
}

#[test]
fn every_fixture_matches_upstream_in_f32_and_int8() {
    let mut report = Vec::new();
    for fixture in Fixture::all() {
        for precision in PRECISIONS {
            let mut inference = RwkvInference::new(model(), precision);
            let actual = run_raw(&fixture, &mut inference);
            let expected = fixture.expected(precision);
            let mut compared = 0;
            let mut max = 0.0_f32;
            for (index, (a, e)) in actual.iter().zip(&expected).enumerate() {
                let (n, diff) = compare(
                    &format!("{} {:?} step {index}", fixture.name, precision),
                    a,
                    e,
                    tolerance(precision),
                );
                compared += n;
                max = max.max(diff);
            }
            assert!(compared > 0, "{}: nothing compared", fixture.name);
            report.push(format!(
                "{:<38} {:<5} values={compared:>6} max|diff|={max:e}",
                fixture.name,
                precision_key(precision)
            ));
        }
    }
    eprintln!("parity vs upstream oracle:\n  {}", report.join("\n  "));
}

#[test]
fn upstream_python_test_constants_hold() {
    // 上游测试：逐行先查询（is_query）再作答；第 0 行与第 34 行查询值写死在测试里，容差 1e-6。
    let fixture = Fixture::load("upstream_golden_history");
    let row0 = fixture.extra["python_test_row0_immediate"]
        .as_f64()
        .unwrap() as f32;
    let row34 = fixture.extra["python_test_row34_immediate"]
        .as_f64()
        .unwrap() as f32;
    let Step::WarmUp { rows, .. } = &fixture.steps[0] else {
        panic!("first step is the warm-up");
    };
    assert_eq!(rows.len(), 35);
    for one_call in [true, false] {
        let mut inference = RwkvInference::new(model(), StatePrecision::F32);
        let predictions: Vec<(usize, f32)> = if one_call {
            inference
                .warm_up_reviews(inputs(rows, false), true)
                .unwrap()
        } else {
            rows.iter()
                .enumerate()
                .map(|(index, row)| {
                    let out = inference
                        .warm_up_reviews(vec![input(row, false)], true)
                        .unwrap();
                    assert_eq!(out.len(), 1);
                    (index, out[0].1)
                })
                .collect()
        };
        let r0 = predictions[0].1;
        let r34 = predictions[34].1;
        eprintln!(
            "one_call={one_call}: row0 {r0} (python test {row0}, diff {:e}), row34 {r34} (python test {row34}, diff {:e})",
            (r0 - row0).abs(),
            (r34 - row34).abs()
        );
        assert!((r0 - row0).abs() <= F32_TOLERANCE, "row0 {r0} vs {row0}");
        assert!(
            (r34 - row34).abs() <= F32_TOLERANCE,
            "row34 {r34} vs {row34}"
        );
    }
}

#[test]
fn bulk_replay_states_equal_the_per_review_reference_bit_for_bit() {
    // 上游声明：批量回放的持久状态与逐条回放逐位一致（bulk.rs 文件头）。用快照字节核对。
    let fixture = Fixture::load("simulated_collection");
    for precision in PRECISIONS {
        let mut bulk = RwkvInference::new(model(), precision);
        let mut sequential = RwkvInference::new(model(), precision);
        for step in &fixture.steps {
            if let Step::WarmUp { rows, .. } = step {
                bulk.warm_up_reviews(inputs(rows, false), false).unwrap();
                sequential
                    .warm_up_reviews_sequential(inputs(rows, false), false)
                    .unwrap();
            }
        }
        assert!(
            bulk.snapshot() == sequential.snapshot(),
            "{precision:?}: bulk and per-review replay diverged"
        );
    }
}

#[test]
fn snapshot_restore_then_continue_matches_uninterrupted_replay() {
    for name in ["edge_cases", "simulated_collection"] {
        let fixture = Fixture::load(name);
        for precision in PRECISIONS {
            let mut uninterrupted = RwkvInference::new(model(), precision);
            let reference = run_raw(&fixture, &mut uninterrupted);

            // 每一步之后导出快照、换一个全新的 runtime 恢复，再继续下一步。
            let mut current = RwkvInference::new(model(), precision);
            let mut outputs = Vec::new();
            for step in &fixture.steps {
                let single = Fixture {
                    name: fixture.name.clone(),
                    steps: vec![step.clone()],
                    expected: Default::default(),
                    extra: serde_json::Value::Null,
                };
                outputs.extend(run_raw(&single, &mut current));
                let bytes = current.snapshot();
                let mut restored = RwkvInference::new(model(), precision);
                restored.restore_snapshot(&bytes).expect("restore");
                assert!(
                    restored.snapshot() == bytes,
                    "{name} {precision:?}: snapshot round trip"
                );
                current = restored;
            }
            assert_eq!(
                outputs, reference,
                "{name} {precision:?}: continued replay differs"
            );
            assert!(current.snapshot() == uninterrupted.snapshot());
            // 也仍然对得上上游。
            for (index, (a, e)) in outputs.iter().zip(fixture.expected(precision)).enumerate() {
                compare(
                    &format!("{name} {precision:?} restored step {index}"),
                    a,
                    &e,
                    tolerance(precision),
                );
            }
        }
    }
}

#[test]
fn snapshot_restore_rejects_damage_and_precision_mismatch() {
    let fixture = Fixture::load("edge_cases");
    let mut f32_runtime = RwkvInference::new(model(), StatePrecision::F32);
    run_raw(&fixture, &mut f32_runtime);
    let bytes = f32_runtime.snapshot();

    let mut int8_runtime = RwkvInference::new(model(), StatePrecision::Int8);
    assert!(int8_runtime.restore_snapshot(&bytes).is_err());

    let mut fresh = RwkvInference::new(model(), StatePrecision::F32);
    let before = fresh.snapshot();
    for cut in [0, 5, 11, 12, bytes.len() / 2, bytes.len() - 1] {
        assert!(
            fresh.restore_snapshot(&bytes[..cut]).is_err(),
            "truncated at {cut}"
        );
        assert!(
            fresh.snapshot() == before,
            "a refused restore changed state"
        );
    }
    let mut trailing = bytes.clone();
    trailing.push(0);
    assert!(fresh.restore_snapshot(&trailing).is_err());
    // 一个 state 的层数被改坏（第一张卡状态的 layer count 字段）。
    let mut corrupt = bytes.clone();
    let magic = b"ARWKVMODSTATE1";
    let at = corrupt
        .windows(magic.len())
        .position(|w| w == magic)
        .expect("a card state");
    corrupt[at + magic.len()] = 7;
    assert!(fresh.restore_snapshot(&corrupt).is_err());
    assert!(fresh.snapshot() == before);
    fresh.restore_snapshot(&bytes).unwrap();
    assert!(fresh.snapshot() == bytes);
}

#[test]
fn runtime_thread_count_does_not_change_results() {
    let fixture = Fixture::load("simulated_collection");
    let mut results = Vec::new();
    for threads in [0, 1, 3] {
        let mut runtime = RwkvRuntime::new(&Model::from(model().clone()), StatePrecision::Int8, threads).unwrap();
        let mut outputs = Vec::new();
        for step in &fixture.steps {
            match step {
                Step::WarmUp {
                    record_predictions,
                    rows,
                } => outputs.push(Output::Predictions(
                    runtime
                        .replay(&inputs(rows, false), *record_predictions)
                        .unwrap(),
                )),
                Step::Query { rows } => outputs.push(Output::Retrievability(
                    runtime.query(&inputs(rows, true)).unwrap(),
                )),
            }
        }
        results.push((outputs, runtime.snapshot().unwrap()));
    }
    assert!(results.windows(2).all(|pair| pair[0] == pair[1]));
}

#[test]
fn reset_returns_to_a_fresh_runtime() {
    let fixture = Fixture::load("edge_cases");
    let mut inference = RwkvInference::new(model(), StatePrecision::F32);
    let fresh = inference.snapshot();
    run_raw(&fixture, &mut inference);
    assert!(inference.snapshot() != fresh);
    inference.reset();
    assert!(inference.snapshot() == fresh);
    // 重放一遍得到同样的上游结果。
    let actual = run_raw(&fixture, &mut inference);
    for (index, (a, e)) in actual
        .iter()
        .zip(fixture.expected(StatePrecision::F32))
        .enumerate()
    {
        compare(&format!("after reset step {index}"), a, &e, F32_TOLERANCE);
    }
}
