// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 测试共用：权重加载（缺失 / 校验失败直接 panic 并提示跑 fetch_model）与上游黄金值夹具。
#![allow(dead_code)]

use std::path::PathBuf;
use std::sync::OnceLock;

use fushi_rwkv::{
    ReviewInput, RwkvModel, StatePrecision, MODEL_SHA256, SMALL_MODEL_PACKAGE_SHA256,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};

/// 夹具里 f32 状态与上游实现的容差（任务要求 1e-5）。
pub const F32_TOLERANCE: f32 = 1e-5;
/// int8 状态的容差。来源：int8 模式在每次作答后把 card/note 时间混合矩阵逐行量化
/// （`round_ties_even(x / scale)`），量化对输入的最后几位很敏感——上游的 SIMD 内核
/// （x86 AVX2+FMA / aarch64 NEON / macOS Accelerate / 标量）求和顺序不同，跨平台时恰好
/// 落在舍入边界上的元素会差一个量化台阶（行最大值 / 127），再经后续复习传播。
/// 实测（x86_64-windows，夹具生成平台）：本 crate 与上游 f32、int8 都是 0 差；
/// 把 x86 的 AVX2+FMA 内核强制换成标量内核（只改求和顺序，模拟另一个平台）再对夹具：
/// f32 最大差 2.98e-7，int8 最大差 3.78e-4（simulated_collection）。
/// 取 1e-3（约 2.6 倍余量）。上游自己的对比（docs/rwkv-state-precision-2026-10-10.MD）里
/// 整体 int8 与 f32 的单条最大差是 6.8e-3，本容差仍比它小一个数量级。
pub const INT8_TOLERANCE: f32 = 1e-3;

pub fn tolerance(precision: StatePrecision) -> f32 {
    match precision {
        StatePrecision::F32 => F32_TOLERANCE,
        _ => INT8_TOLERANCE,
    }
}

pub fn model_path() -> PathBuf {
    match std::env::var_os("FUSHI_RWKV_MODEL") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("model")
            .join("RWKV_trained_on_5000_10000.bin"),
    }
}

/// 权重缺失或 SHA-256 不符时**失败**（不静默跳过）。
pub fn model_bytes() -> &'static [u8] {
    static BYTES: OnceLock<Vec<u8>> = OnceLock::new();
    BYTES.get_or_init(|| {
        let path = model_path();
        let bytes = std::fs::read(&path).unwrap_or_else(|error| {
            panic!(
                "RWKV weights not found at {} ({error}).\n\
                 Run native/fushi_rwkv/fetch_model.sh (or fetch_model.ps1 on Windows) first, \
                 or point FUSHI_RWKV_MODEL at the file.",
                path.display()
            )
        });
        let digest = Sha256::digest(&bytes);
        let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(
            hex,
            MODEL_SHA256,
            "RWKV weights at {} have the wrong SHA-256; re-run fetch_model.sh / fetch_model.ps1",
            path.display()
        );
        bytes
    })
}

/// 小模型发布包（`fetch_model.sh` / `fetch_model.ps1` 一并下载）；缺失或 SHA-256 不符时失败。
/// `FUSHI_RWKV_SMALL_PACKAGE` 可指向别处的包。
pub fn small_package() -> &'static [u8] {
    static BYTES: OnceLock<Vec<u8>> = OnceLock::new();
    BYTES.get_or_init(|| {
        let path = match std::env::var_os("FUSHI_RWKV_SMALL_PACKAGE") {
            Some(path) => PathBuf::from(path),
            None => PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("model")
                .join("sm56-package.zip"),
        };
        let bytes = std::fs::read(&path).unwrap_or_else(|error| {
            panic!(
                "small RWKV model package not found at {} ({error}).\n\
                 Run native/fushi_rwkv/fetch_model.sh (or fetch_model.ps1 on Windows) first, \
                 or point FUSHI_RWKV_SMALL_PACKAGE at the zip.",
                path.display()
            )
        });
        let hex: String = Sha256::digest(&bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        assert_eq!(
            hex,
            SMALL_MODEL_PACKAGE_SHA256,
            "small RWKV model package at {} has the wrong SHA-256; \
             re-run fetch_model.sh / fetch_model.ps1",
            path.display()
        );
        bytes
    })
}

pub fn model() -> &'static RwkvModel {
    static MODEL: OnceLock<RwkvModel> = OnceLock::new();
    MODEL.get_or_init(|| RwkvModel::from_bytes(model_bytes()).expect("parse weights"))
}

pub type Row = [Option<i64>; 10];

#[derive(Deserialize, Clone)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Step {
    WarmUp {
        record_predictions: bool,
        rows: Vec<Row>,
    },
    Query {
        rows: Vec<Row>,
    },
}

#[derive(Deserialize)]
pub struct Fixture {
    pub name: String,
    pub steps: Vec<Step>,
    pub expected: std::collections::BTreeMap<String, Vec<serde_json::Value>>,
    pub extra: serde_json::Value,
}

/// 一步的上游输出：warm-up 是 `(行号, R)`，query 是 R 数组。
#[derive(Debug, Clone, PartialEq)]
pub enum Output {
    Predictions(Vec<(usize, f32)>),
    Retrievability(Vec<f32>),
}

impl Fixture {
    pub fn load(name: &str) -> Fixture {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests")
            .join("fixtures")
            .join(format!("{name}.json"));
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("fixture {}: {error}", path.display()));
        serde_json::from_str(&text).unwrap_or_else(|error| panic!("fixture {name}: {error}"))
    }

    pub fn all() -> Vec<Fixture> {
        [
            "upstream_golden_history",
            "upstream_golden_history_incremental",
            "edge_cases",
            "simulated_collection",
        ]
        .into_iter()
        .map(Fixture::load)
        .collect()
    }

    pub fn expected(&self, precision: StatePrecision) -> Vec<Output> {
        let key = precision_key(precision);
        let values = &self.expected[key];
        assert_eq!(
            values.len(),
            self.steps.len(),
            "{}: expected/steps",
            self.name
        );
        self.steps
            .iter()
            .zip(values)
            .map(|(step, value)| match step {
                Step::WarmUp { .. } => Output::Predictions(
                    serde_json::from_value(value.clone()).expect("warm-up expectation"),
                ),
                Step::Query { .. } => Output::Retrievability(
                    serde_json::from_value(value.clone()).expect("query expectation"),
                ),
            })
            .collect()
    }
}

pub fn precision_key(precision: StatePrecision) -> &'static str {
    match precision {
        StatePrecision::F32 => "f32",
        StatePrecision::Int8 => "int8",
        StatePrecision::Int4 => "int4",
    }
}

pub const PRECISIONS: [StatePrecision; 2] = [StatePrecision::F32, StatePrecision::Int8];

pub fn input(row: &Row, is_query: bool) -> ReviewInput {
    ReviewInput {
        card_id: row[0].expect("card id"),
        note_id: row[1],
        deck_id: row[2],
        preset_id: row[3],
        is_query,
        ease: if is_query {
            None
        } else {
            row[4].map(|e| e as u8)
        },
        duration_millis: if is_query { None } else { row[5] },
        card_type: row[6],
        day_offset: row[7],
        current_elapsed_days: row[8],
        current_elapsed_seconds: row[9],
    }
}

pub fn inputs(rows: &[Row], is_query: bool) -> Vec<ReviewInput> {
    rows.iter().map(|row| input(row, is_query)).collect()
}

/// 逐值比较；返回 (比较个数, 最大绝对差)。下标 / 长度不一致直接失败。
pub fn compare(context: &str, actual: &Output, expected: &Output, tolerance: f32) -> (usize, f32) {
    let pairs: Vec<(f32, f32)> = match (actual, expected) {
        (Output::Predictions(a), Output::Predictions(e)) => {
            assert_eq!(a.len(), e.len(), "{context}: prediction count");
            a.iter()
                .zip(e)
                .map(|((ai, av), (ei, ev))| {
                    assert_eq!(ai, ei, "{context}: prediction row index");
                    (*av, *ev)
                })
                .collect()
        }
        (Output::Retrievability(a), Output::Retrievability(e)) => {
            assert_eq!(a.len(), e.len(), "{context}: query count");
            a.iter().copied().zip(e.iter().copied()).collect()
        }
        _ => panic!("{context}: output kind mismatch"),
    };
    let mut max = 0.0_f32;
    for (index, (a, e)) in pairs.iter().enumerate() {
        assert!(
            a.is_finite() && e.is_finite(),
            "{context}[{index}]: {a} vs {e}"
        );
        let diff = (a - e).abs();
        assert!(
            diff <= tolerance,
            "{context}[{index}]: got {a}, upstream {e}, |diff| {diff} > {tolerance}"
        );
        max = max.max(diff);
    }
    (pairs.len(), max)
}
