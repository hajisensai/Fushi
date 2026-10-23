// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! C ABI 往返：只通过 `extern "C"` 函数走一遍（加载 → 回放 → 查询 → 快照 → 恢复 → 统计 →
//! 重置 → 释放），结果必须与 Rust API / 上游黄金值一致；错误路径不 panic、给可读错误。
mod common;

use std::ffi::CStr;

use common::*;
use fushi_rwkv::*;

fn last_error() -> String {
    let ptr = frwkv_last_error();
    assert!(!ptr.is_null(), "expected an error message");
    let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
    unsafe { frwkv_free_string(ptr) };
    text
}

fn rows(rows: &[Row], is_query: bool) -> Vec<FrwkvReview> {
    inputs(rows, is_query)
        .iter()
        .map(FrwkvReview::from_input)
        .collect()
}

struct Handles {
    model: *mut FrwkvModel,
    runtime: *mut FrwkvRuntime,
}

impl Handles {
    fn new(precision: i32, threads: u32) -> Self {
        let bytes = model_bytes();
        let model = unsafe { frwkv_model_load(bytes.as_ptr(), bytes.len()) };
        assert!(!model.is_null());
        let runtime = unsafe { frwkv_runtime_new(model, precision, threads) };
        assert!(!runtime.is_null());
        Self { model, runtime }
    }
}

impl Drop for Handles {
    fn drop(&mut self) {
        unsafe {
            frwkv_runtime_free(self.runtime);
            frwkv_model_free(self.model);
        }
    }
}

/// 只用 C ABI 跑一个夹具，返回每一步的输出。
fn run_c(fixture: &Fixture, runtime: *mut FrwkvRuntime) -> Vec<Output> {
    fixture
        .steps
        .iter()
        .map(|step| match step {
            Step::WarmUp {
                record_predictions,
                rows: step_rows,
            } => {
                let reviews = rows(step_rows, false);
                let mut out = vec![0.0_f32; reviews.len()];
                let out_ptr = if *record_predictions {
                    out.as_mut_ptr()
                } else {
                    std::ptr::null_mut()
                };
                let code = unsafe {
                    frwkv_runtime_replay(runtime, reviews.as_ptr(), reviews.len(), out_ptr)
                };
                assert_eq!(code, FRWKV_OK, "{}", last_error());
                if *record_predictions {
                    // 无评分行写 NaN，其余与上游 `(index, R)` 对应。
                    Output::Predictions(
                        out.iter()
                            .enumerate()
                            .filter(|(index, value)| {
                                let rated = step_rows[*index][4].is_some();
                                assert_eq!(rated, !value.is_nan(), "row {index}");
                                rated
                            })
                            .map(|(index, value)| (index, *value))
                            .collect(),
                    )
                } else {
                    Output::Predictions(Vec::new())
                }
            }
            Step::Query { rows: step_rows } => {
                let queries = rows(step_rows, true);
                let mut out = vec![0.0_f32; queries.len()];
                let code = unsafe {
                    frwkv_runtime_query(runtime, queries.as_ptr(), queries.len(), out.as_mut_ptr())
                };
                assert_eq!(code, FRWKV_OK, "{}", last_error());
                Output::Retrievability(out)
            }
        })
        .collect()
}

#[test]
fn abi_version_and_struct_layout() {
    assert_eq!(frwkv_abi_version(), ABI_VERSION);
    assert_eq!(frwkv_review_struct_size(), 80);
    assert_eq!(std::mem::align_of::<FrwkvReview>(), 8);
    assert_eq!(std::mem::size_of::<FrwkvStats>(), 72);
}

#[test]
fn c_abi_round_trip_matches_upstream_and_rust_api() {
    // simulated_collection 的查询行都不早于最后回放日，C ABI 不会给 NaN。
    let fixture = Fixture::load("simulated_collection");
    for (code, precision) in [
        (FRWKV_PRECISION_F32, StatePrecision::F32),
        (FRWKV_PRECISION_INT8, StatePrecision::Int8),
    ] {
        let handles = Handles::new(code, 0);
        let actual = run_c(&fixture, handles.runtime);
        for (index, (a, e)) in actual.iter().zip(fixture.expected(precision)).enumerate() {
            if matches!(a, Output::Predictions(p) if p.is_empty()) {
                assert!(matches!(&e, Output::Predictions(p) if p.is_empty()));
                continue;
            }
            compare(
                &format!("C ABI {precision:?} step {index}"),
                a,
                &e,
                tolerance(precision),
            );
        }

        // 统计
        let mut stats = FrwkvStats::default();
        assert_eq!(
            unsafe { frwkv_runtime_stats(handles.runtime, &mut stats) },
            FRWKV_OK
        );
        assert!(stats.cards > 500 && stats.notes > 250 && stats.decks == 5 && stats.presets == 3);
        assert!(stats.card_state_bytes > 0 && stats.feature_state_bytes > 0);

        // 快照 → 新 runtime 恢复 → 同一查询逐位相同
        let mut ptr = std::ptr::null_mut();
        let mut len = 0usize;
        assert_eq!(
            unsafe { frwkv_runtime_snapshot(handles.runtime, &mut ptr, &mut len) },
            FRWKV_OK
        );
        let snapshot = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
        unsafe { frwkv_free_bytes(ptr, len) };

        let other = Handles::new(code, 1);
        assert_eq!(
            unsafe { frwkv_runtime_restore(other.runtime, snapshot.as_ptr(), snapshot.len()) },
            FRWKV_OK,
            "{}",
            last_error()
        );
        let Some(Step::Query { rows: last_rows }) = fixture.steps.last() else {
            panic!("fixture ends with a query");
        };
        let queries = rows(last_rows, true);
        let query = |runtime| {
            let mut out = vec![0.0_f32; queries.len()];
            let code = unsafe {
                frwkv_runtime_query(runtime, queries.as_ptr(), queries.len(), out.as_mut_ptr())
            };
            assert_eq!(code, FRWKV_OK);
            out
        };
        let a = query(handles.runtime);
        let b = query(other.runtime);
        assert_eq!(
            a.iter().map(|v| v.to_bits()).collect::<Vec<_>>(),
            b.iter().map(|v| v.to_bits()).collect::<Vec<_>>()
        );

        // 与 Rust API 逐位一致
        let mut rust = RwkvRuntime::new(&Model::from(model().clone()), precision, 0).unwrap();
        rust.restore(&snapshot).unwrap();
        let c = rust.query(&inputs(last_rows, true)).unwrap();
        assert_eq!(
            c.iter().map(|v| v.to_bits()).collect::<Vec<_>>(),
            b.iter().map(|v| v.to_bits()).collect::<Vec<_>>()
        );

        // 重置后统计归零
        assert_eq!(unsafe { frwkv_runtime_reset(handles.runtime) }, FRWKV_OK);
        assert_eq!(
            unsafe { frwkv_runtime_stats(handles.runtime, &mut stats) },
            FRWKV_OK
        );
        assert_eq!((stats.reviews, stats.cards), (0, 0));
    }
}

#[test]
fn c_abi_errors_are_codes_with_messages_not_panics() {
    // 空 / 坏权重
    assert!(unsafe { frwkv_model_load(std::ptr::null(), 10) }.is_null());
    assert!(last_error().contains("null"));
    let junk = [1u8, 2, 3, 4];
    assert!(unsafe { frwkv_model_load(junk.as_ptr(), junk.len()) }.is_null());
    assert!(last_error().contains("weights"));
    // 截断的权重
    let bytes = model_bytes();
    assert!(unsafe { frwkv_model_load(bytes.as_ptr(), bytes.len() - 1) }.is_null());

    let handles = Handles::new(FRWKV_PRECISION_F32, 0);
    for bad in [1, 16, -2] {
        assert!(unsafe { frwkv_runtime_new(handles.model, bad, 0) }.is_null());
        assert!(last_error().contains("precision"));
    }
    // ABI 2：模型种类、int4 与按模型取推荐精度。
    assert_eq!(unsafe { frwkv_model_kind(handles.model) }, FRWKV_MODEL_LARGE);
    assert_eq!(unsafe { frwkv_model_kind(std::ptr::null()) }, FRWKV_ERR_ARGUMENT);
    let runtime = unsafe { frwkv_runtime_new(handles.model, FRWKV_PRECISION_DEFAULT, 0) };
    assert!(!runtime.is_null());
    unsafe { frwkv_runtime_free(runtime) };
    // 大模型不支持 int4（见 ModelKind::supports）。
    assert!(unsafe { frwkv_runtime_new(handles.model, FRWKV_PRECISION_INT4, 0) }.is_null());
    assert!(last_error().contains("int8"));
    assert!(unsafe { frwkv_runtime_new(std::ptr::null(), 0, 0) }.is_null());

    let good = FrwkvReview {
        card_id: 1,
        day_offset: 100,
        elapsed_days: -1,
        elapsed_seconds: -1,
        card_type: 0,
        present: FRWKV_HAS_DAY_OFFSET
            | FRWKV_HAS_ELAPSED_DAYS
            | FRWKV_HAS_ELAPSED_SECONDS
            | FRWKV_HAS_CARD_TYPE,
        ease: 3,
        ..Default::default()
    };
    let replay = |reviews: &[FrwkvReview]| unsafe {
        frwkv_runtime_replay(
            handles.runtime,
            reviews.as_ptr(),
            reviews.len(),
            std::ptr::null_mut(),
        )
    };
    let snapshot = || {
        let (mut ptr, mut len) = (std::ptr::null_mut(), 0usize);
        assert_eq!(
            unsafe { frwkv_runtime_snapshot(handles.runtime, &mut ptr, &mut len) },
            FRWKV_OK
        );
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
        unsafe { frwkv_free_bytes(ptr, len) };
        bytes
    };
    let empty = snapshot();

    // 坏 ease、未知 present 位、缺 day_offset、elapsed < -1、负时长、card_type 越界：整批不应用
    for (bad, needle) in [
        (FrwkvReview { ease: 5, ..good }, "ease"),
        (
            FrwkvReview {
                present: good.present | (1 << 20),
                ..good
            },
            "present",
        ),
        (
            FrwkvReview {
                present: good.present & !FRWKV_HAS_DAY_OFFSET,
                ..good
            },
            "day_offset",
        ),
        (
            FrwkvReview {
                elapsed_days: -2,
                ..good
            },
            "elapsed",
        ),
        (
            FrwkvReview {
                duration_millis: -5,
                present: good.present | FRWKV_HAS_DURATION,
                ..good
            },
            "duration",
        ),
        (
            FrwkvReview {
                card_type: 6,
                ..good
            },
            "card_type",
        ),
    ] {
        assert_eq!(replay(&[good, bad]), FRWKV_ERR_INPUT, "{needle}");
        assert!(last_error().contains(needle), "{needle}");
        assert!(
            snapshot() == empty,
            "{needle}: a refused batch changed state"
        );
    }

    // 时间倒序（跨批次也查）
    assert_eq!(replay(&[good]), FRWKV_OK);
    let earlier = FrwkvReview {
        day_offset: 99,
        card_id: 2,
        ..good
    };
    assert_eq!(replay(&[earlier]), FRWKV_ERR_INPUT);
    assert!(last_error().contains("chronological"));

    // 查询：不合法的行给 NaN，其余照常
    let query = FrwkvReview {
        ease: 0,
        present: FRWKV_HAS_DAY_OFFSET | FRWKV_HAS_ELAPSED_DAYS | FRWKV_HAS_ELAPSED_SECONDS,
        day_offset: 101,
        elapsed_days: 1,
        elapsed_seconds: 86_400,
        ..good
    };
    let queries = [
        query,
        FrwkvReview {
            day_offset: 99,
            ..query
        }, // 早于最后回放日
        FrwkvReview {
            present: query.present & !FRWKV_HAS_DAY_OFFSET,
            ..query
        }, // 缺日
        FrwkvReview {
            elapsed_seconds: -7,
            ..query
        }, // elapsed < -1
        FrwkvReview {
            present: query.present | (1 << 31),
            ..query
        }, // 未知位
        FrwkvReview {
            card_id: 42,
            ..query
        }, // 没见过的卡：合法
    ];
    let mut out = [0.0_f32; 6];
    assert_eq!(
        unsafe {
            frwkv_runtime_query(
                handles.runtime,
                queries.as_ptr(),
                queries.len(),
                out.as_mut_ptr(),
            )
        },
        FRWKV_OK
    );
    assert!(out[0] > 0.0 && out[0] < 1.0, "{out:?}");
    assert!(
        out[1].is_nan() && out[2].is_nan() && out[3].is_nan() && out[4].is_nan(),
        "{out:?}"
    );
    assert!(out[5] > 0.0 && out[5] < 1.0, "{out:?}");

    // 空指针
    assert_eq!(
        unsafe { frwkv_runtime_query(handles.runtime, queries.as_ptr(), 1, std::ptr::null_mut()) },
        FRWKV_ERR_ARGUMENT
    );
    assert_eq!(
        unsafe {
            frwkv_runtime_replay(
                std::ptr::null_mut(),
                queries.as_ptr(),
                1,
                std::ptr::null_mut(),
            )
        },
        FRWKV_ERR_ARGUMENT
    );
    assert_eq!(
        unsafe { frwkv_runtime_reset(std::ptr::null_mut()) },
        FRWKV_ERR_ARGUMENT
    );
    // 0 条是合法的空操作
    assert_eq!(
        unsafe { frwkv_runtime_replay(handles.runtime, std::ptr::null(), 0, std::ptr::null_mut()) },
        FRWKV_OK
    );
    assert_eq!(
        unsafe { frwkv_runtime_query(handles.runtime, std::ptr::null(), 0, std::ptr::null_mut()) },
        FRWKV_OK
    );

    // 坏快照
    let junk = [0u8; 16];
    assert_eq!(
        unsafe { frwkv_runtime_restore(handles.runtime, junk.as_ptr(), junk.len()) },
        FRWKV_ERR_DATA
    );
    assert!(!last_error().is_empty());

    // 释放空指针无害
    unsafe {
        frwkv_runtime_free(std::ptr::null_mut());
        frwkv_model_free(std::ptr::null_mut());
        frwkv_free_bytes(std::ptr::null_mut(), 0);
        frwkv_free_string(std::ptr::null_mut());
    }
}

#[test]
fn model_handle_can_be_freed_before_its_runtimes() {
    let bytes = model_bytes();
    let model = unsafe { frwkv_model_load(bytes.as_ptr(), bytes.len()) };
    let runtime = unsafe { frwkv_runtime_new(model, FRWKV_PRECISION_INT8, 1) };
    unsafe { frwkv_model_free(model) };
    let fixture = Fixture::load("edge_cases");
    let actual = run_c(&fixture, runtime);
    for (index, (a, e)) in actual
        .iter()
        .zip(fixture.expected(StatePrecision::Int8))
        .enumerate()
    {
        if matches!(a, Output::Predictions(p) if p.is_empty()) {
            continue;
        }
        compare(&format!("step {index}"), a, &e, INT8_TOLERANCE);
    }
    unsafe { frwkv_runtime_free(runtime) };
}
