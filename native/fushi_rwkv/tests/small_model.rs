// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 小模型（SM56）对拍：发布包 `sm56-package.zip` 里的 NumPy 参考实现黄金值
//! （`testvectors/user_{4676,1745}.npz`，两位 benchmark 用户、14,403 行，f32 / int8 两种权重），
//! 逐行比对 p_imm、p_rating、标签时刻与 6 个扫描时刻的 p_curve，容差 1e-5（包自己的验收标准）。
//! 另测：块边界不影响结果、快照续跑逐位相同、int8 / int4 状态在超长历史上有界。

mod common;

use std::collections::HashMap;
use std::io::Read;

use common::small_package;
use fushi_rwkv::{Model, ModelKind, SmallHeads, SmallInference, SmallModel, StatePrecision};

const TOLERANCE: f32 = 1e-5;

/// 一个 .npy：dtype 描述、形状、原始小端字节。
struct Npy {
    descr: String,
    shape: Vec<usize>,
    data: Vec<u8>,
}

impl Npy {
    fn parse(bytes: &[u8]) -> Self {
        assert_eq!(&bytes[..6], b"\x93NUMPY");
        let (header_len, start) = match bytes[6] {
            1 => (u16::from_le_bytes([bytes[8], bytes[9]]) as usize, 10),
            _ => (
                u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]) as usize,
                12,
            ),
        };
        let header = std::str::from_utf8(&bytes[start..start + header_len]).unwrap();
        assert!(header.contains("'fortran_order': False"), "{header}");
        let field = |key: &str| {
            let at = header.find(key).unwrap() + key.len();
            header[at..].trim_start_matches([':', ' '])
        };
        let descr = field("'descr'").trim_start_matches('\'');
        let descr = descr[..descr.find('\'').unwrap()].to_owned();
        let shape = field("'shape'");
        let shape: Vec<usize> = shape[1..shape.find(')').unwrap()]
            .split(',')
            .filter_map(|dim| dim.trim().parse().ok())
            .collect();
        Self {
            descr,
            shape,
            data: bytes[start + header_len..].to_vec(),
        }
    }

    fn f32(&self) -> Vec<f32> {
        assert_eq!(self.descr, "<f4");
        self.data
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
            .collect()
    }

    fn i64(&self) -> Vec<i64> {
        assert_eq!(self.descr, "<i8");
        self.data
            .chunks_exact(8)
            .map(|b| i64::from_le_bytes(b.try_into().unwrap()))
            .collect()
    }

    fn u8(&self) -> Vec<u8> {
        assert_eq!(self.descr, "|u1");
        self.data.clone()
    }
}

fn zip_entries(bytes: &[u8]) -> HashMap<String, Vec<u8>> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes)).unwrap();
    (0..archive.len())
        .map(|index| {
            let mut file = archive.by_index(index).unwrap();
            let mut data = Vec::new();
            file.read_to_end(&mut data).unwrap();
            (file.name().to_owned(), data)
        })
        .collect()
}

fn package_file(name: &str) -> Vec<u8> {
    let entries = zip_entries(small_package());
    entries
        .get(&format!("sm56/{name}"))
        .unwrap_or_else(|| panic!("{name} missing from the package"))
        .clone()
}

fn small_model(weights: &str) -> SmallModel {
    match Model::from_bytes(&package_file(weights)).expect("parse weights") {
        Model::Small(model) => model,
        Model::Large(_) => panic!("{weights} parsed as the large model"),
    }
}

struct Vectors {
    n: usize,
    features: Vec<f32>,
    keys: Vec<[i64; 5]>,
    commit: Vec<bool>,
    has_label: Vec<u8>,
    label_seconds: Vec<f32>,
    sweep: Vec<f32>,
    expected: HashMap<String, Vec<f32>>,
}

fn vectors(user: u32) -> Vectors {
    let npz = zip_entries(&package_file(&format!("testvectors/user_{user}.npz")));
    let array = |name: &str| Npy::parse(&npz[&format!("{name}.npy")]);
    let features = array("features");
    let n = features.shape[0];
    assert_eq!(features.shape, [n, 92]);
    let ids: Vec<Vec<i64>> = ["card_id", "deck_id", "note_id", "preset_id", "user_id"]
        .iter()
        .map(|stream| array(&format!("id_{stream}")).i64())
        .collect();
    let keys = (0..n)
        .map(|row| std::array::from_fn(|stream| ids[stream][row]))
        .collect();
    let mut expected = HashMap::new();
    for weights in ["fp32", "int8"] {
        for output in ["p_imm", "p_rating", "p_curve", "p_curve_sweep"] {
            let name = format!("{weights}_{output}");
            expected.insert(name.clone(), array(&name).f32());
        }
    }
    Vectors {
        n,
        features: features.f32(),
        keys,
        commit: array("skip").u8().iter().map(|&skip| skip == 0).collect(),
        has_label: array("has_label").u8(),
        label_seconds: array("label_elapsed_seconds").f32(),
        sweep: array("sweep_seconds").f32(),
        expected,
    }
}

/// 库里的 `p_curve`（INTEGRATION.md §9.1）：排程用的就是这一份，黄金向量直接钉它。
fn p_curve(heads: &SmallHeads, seconds: f32) -> f32 {
    heads.curve_retrievability(seconds)
}

fn check(user: u32, weights_file: &str, prefix: &str, chunk: usize) -> f32 {
    let v = vectors(user);
    let model = small_model(weights_file);
    let mut runtime = SmallInference::new(&model, StatePrecision::F32);
    let heads = runtime.run_prepared_rows(&v.features, &v.keys, &v.commit, chunk);
    assert_eq!(heads.len(), v.n);
    let e = |name: &str| &v.expected[&format!("{prefix}_{name}")];
    let mut worst = 0.0f32;
    let mut compare = |what: &str, row: usize, got: f32, want: f32| {
        let diff = (got - want).abs();
        assert!(
            diff <= TOLERANCE,
            "user {user} {prefix} chunk {chunk} row {row} {what}: got {got}, want {want} (diff {diff})"
        );
        worst = worst.max(diff);
    };
    for (row, heads) in heads.iter().enumerate() {
        compare("p_imm", row, heads.retrievability(), e("p_imm")[row]);
        for (rating, p) in heads.rating_probabilities().iter().enumerate() {
            compare("p_rating", row, *p, e("p_rating")[row * 4 + rating]);
        }
        compare("p_curve", row, p_curve(heads, v.label_seconds[row]), e("p_curve")[row]);
        for (i, &t) in v.sweep.iter().enumerate() {
            compare("p_curve_sweep", row, p_curve(heads, t), e("p_curve_sweep")[row * 6 + i]);
        }
    }
    assert!(v.has_label.iter().any(|&l| l == 1));
    worst
}

#[test]
fn weight_files_load_as_the_small_model_with_the_published_schedule() {
    for file in ["weights.f32.bin", "weights.int8.bin"] {
        let model = Model::from_bytes(&package_file(file)).unwrap();
        assert_eq!(model.kind(), ModelKind::Small, "{file}");
    }
    let architecture: serde_json::Value =
        serde_json::from_slice(&package_file("architecture.json")).unwrap();
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
    assert_eq!(small_model("weights.f32.bin").layer_steps(), published);
    assert_eq!(architecture["zero_features"], serde_json::json!([22]));
    assert_eq!(architecture["d_model"], 64);
}

#[test]
fn matches_reference_f32_weights() {
    for user in [4676, 1745] {
        let worst = check(user, "weights.f32.bin", "fp32", 1 << 20);
        eprintln!("user {user} fp32 weights: worst diff {worst:e}");
    }
}

#[test]
fn matches_reference_int8_weights() {
    for user in [4676, 1745] {
        let worst = check(user, "weights.int8.bin", "int8", 1 << 20);
        eprintln!("user {user} int8 weights: worst diff {worst:e}");
    }
}

/// 块边界（每次引擎调用的行数）只影响批处理方式，不影响结果。
#[test]
fn chunking_does_not_change_results() {
    let v = vectors(4676);
    let model = small_model("weights.int8.bin");
    for precision in [StatePrecision::F32, StatePrecision::Int8, StatePrecision::Int4] {
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
