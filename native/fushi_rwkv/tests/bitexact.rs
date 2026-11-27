// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 跨平台逐位一致（`src/rwkv/det.rs`）：同一权重 + 同一复习历史，状态字节与 R 在 x86_64（AVX2+FMA /
//! 无 FMA 的标量）、aarch64（NEON）、其他架构上**逐位相同**。
//!
//! 背景（2026-11-26）：之前 x86 走 AVX2+FMA、aarch64 走 NEON、macOS 走 Accelerate，求和顺序与 libm
//! 各不相同，同一张卡电脑上 R = 0.91486245、模拟别的平台（强制标量）0.9148693；R 恰好压在目标保留率
//! 上的卡两端判定不同，同步完成后「今天到期」电脑 73、手机 72（BUG 见 docs/bugs）。
//!
//! 每个 (模型, 精度) 跑同一组工作负载（四份夹具的回放 + 查询、几张卡各复习上千次的长历史），把回放
//! 预测、查询 R 的位模式与最终快照字节压成一个 SHA-256：
//! - [vector_and_portable_kernels_agree_bit_for_bit]：本机的向量内核（AVX2 / NEON）与强制的可移植内核
//!   （`FUSHI_RWKV_PORTABLE_KERNELS=1`，标量 + 软件 FMA，即无 FMA 的老 x86 / 其他架构走的路）在子进程里各算一遍，
//!   摘要必须相同；
//! - [digests_match_the_golden_values]：摘要等于 x86_64 Windows 上生成的黄金值；CI 的
//!   linux-x86_64 / linux-aarch64 / macos-arm64 三个任务都跑这条（native-rwkv-gate.yml），即跨平台对拍。
//!
//! 改了数值（运算序、超越函数、量化）黄金值就会变：那同时意味着旧快照作废（快照魔数要升版，见
//! README「快照」），用 `FUSHI_RWKV_PRINT_DIGESTS=1 cargo test --test bitexact -- --nocapture` 打印新值替换。
mod common;

use std::collections::BTreeMap;
use std::sync::OnceLock;

use common::{Fixture, SmallFile, SmallModelId, Step, inputs, model_bytes, small_file_of};
use fushi_rwkv::{Model, PORTABLE_KERNELS_ENV, ReviewInput, RwkvRuntime, StatePrecision};
use sha2::{Digest, Sha256};

/// x86_64 Windows（AVX2+FMA，Ryzen 7 9800X3D）生成：大模型 2026-11-26，小模型 2026-11-27（换 sm113 / sm130io）。
const GOLDEN: [(&str, &str); 8] = [
    (
        "large f32",
        "5a20955b6a8811662bad408a689756ac05d02a1a2149b17ad3ad105639204426",
    ),
    (
        "large int8",
        "93adcbf62392f9bc461d07bc74e9cd449ed8770e4fafb70a2b910179e80ac53f",
    ),
    (
        "sm113 f32",
        "b976e3848c243c1b3986d6e88d2528de7917c083c178631d07c59c0fe9913a76",
    ),
    (
        "sm113 int4",
        "4462ed9bf0005fee999567fdf6bcddb4869e0e0a110a2f988d5b5446ae26fe97",
    ),
    (
        "sm113 int8",
        "ca70bc77ce0efb1f36a7d01967a5722d78c9d8ce48f914ed5e2a4bd5e87f6d0c",
    ),
    (
        "sm130io f32",
        "45e1c9b20e34da9a9a71f25203e952fd3e2acfb080b3a549876e4950fff734a6",
    ),
    (
        "sm130io int4",
        "dc6ff5c1fbbb00cf0c64b5e147c7ef70fdc448a5829922d421fa87c6d5e81fba",
    ),
    (
        "sm130io int8",
        "2bcdab19d6c0a9eacb9bec6d28debbd77239a0898974b46ded7f9cd070252713",
    ),
];

const CHILD_MARKER: &str = "BITEXACT-DIGEST";

/// 几张卡各被复习上千次（混合评分）：量化舍入、长递推都走到。
fn long_history() -> Vec<ReviewInput> {
    let mut seed = 7u64;
    let mut next = || {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (seed >> 33) as i64
    };
    let cards = 5;
    let mut reviews = Vec::new();
    let mut last: Vec<Option<(i64, i64)>> = vec![None; cards];
    for day in 0..1_200 {
        let mut ts = day * 86_400 + 8 * 3600;
        for card in 0..cards {
            if next() % 3 == 0 {
                continue;
            }
            let previous = last[card];
            let (ed, es) = previous.map_or((-1, -1), |(d, t)| (day - d, ts - t));
            reviews.push(ReviewInput {
                card_id: 50 + card as i64,
                note_id: Some(500 + card as i64 / 2),
                deck_id: Some(1 + card as i64 % 2),
                preset_id: Some(1),
                is_query: false,
                ease: Some([1u8, 2, 3, 3, 3, 3, 4][(next() % 7) as usize]),
                duration_millis: Some(1_000 + next() % 20_000),
                card_type: Some(if previous.is_none() { 0 } else { 2 }),
                day_offset: Some(day),
                current_elapsed_days: Some(ed),
                current_elapsed_seconds: Some(es),
            });
            last[card] = Some((day, ts));
            ts += 30 + next() % 600;
        }
    }
    reviews
}

fn feed_bits(hasher: &mut Sha256, values: impl IntoIterator<Item = f32>) {
    for value in values {
        hasher.update(value.to_bits().to_le_bytes());
    }
}

/// 一个 (模型, 精度) 的工作负载摘要。
fn digest(model: &Model, precision: StatePrecision, fixtures: &[Fixture]) -> String {
    let mut hasher = Sha256::new();
    for fixture in fixtures {
        let mut runtime = RwkvRuntime::new(model, precision, 0).unwrap();
        for step in &fixture.steps {
            match step {
                Step::WarmUp {
                    record_predictions,
                    rows,
                } => {
                    let predictions = runtime
                        .replay(&inputs(rows, false), *record_predictions)
                        .expect("replay");
                    for (index, r) in predictions {
                        hasher.update((index as u64).to_le_bytes());
                        feed_bits(&mut hasher, [r]);
                    }
                }
                Step::Query { rows } => {
                    feed_bits(
                        &mut hasher,
                        runtime.query(&inputs(rows, true)).expect("query"),
                    );
                }
            }
        }
        hasher.update(runtime.snapshot().expect("snapshot"));
    }
    let history = long_history();
    let mut runtime = RwkvRuntime::new(model, precision, 0).unwrap();
    let predictions = runtime.replay(&history, true).expect("replay");
    feed_bits(&mut hasher, predictions.into_iter().map(|(_, r)| r));
    let last = history.last().unwrap().day_offset.unwrap();
    let queries: Vec<ReviewInput> = (0..5)
        .map(|card| ReviewInput {
            is_query: true,
            ease: None,
            duration_millis: None,
            card_type: None,
            day_offset: Some(last + 3),
            current_elapsed_days: Some(3),
            current_elapsed_seconds: Some(3 * 86_400 + 17 * card),
            ..history[card as usize].clone()
        })
        .collect();
    feed_bits(&mut hasher, runtime.query(&queries).expect("query"));
    hasher.update(runtime.snapshot().expect("snapshot"));
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// 本进程（按本机内核）的全部摘要，键 `"<模型> <精度>"`。
fn digests() -> &'static BTreeMap<String, String> {
    static DIGESTS: OnceLock<BTreeMap<String, String>> = OnceLock::new();
    DIGESTS.get_or_init(|| {
        let all = Fixture::all();
        // 大模型慢：只跑最大的一份夹具。
        let large_fixtures: Vec<Fixture> = Fixture::all()
            .into_iter()
            .filter(|fixture| fixture.name == "simulated_collection")
            .collect();
        let mut out = BTreeMap::new();
        let large = Model::from_bytes(model_bytes()).unwrap();
        for precision in [StatePrecision::F32, StatePrecision::Int8] {
            out.insert(
                format!("large {}", common::precision_key(precision)),
                digest(&large, precision, &large_fixtures),
            );
        }
        for id in SmallModelId::ALL {
            let small = Model::from_bytes(small_file_of(id, SmallFile::Int8Weights)).unwrap();
            for precision in [
                StatePrecision::F32,
                StatePrecision::Int8,
                StatePrecision::Int4,
            ] {
                out.insert(
                    format!("{} {}", id.name(), common::precision_key(precision)),
                    digest(&small, precision, &all),
                );
            }
        }
        out
    })
}

#[test]
fn vector_and_portable_kernels_agree_bit_for_bit() {
    if std::env::var_os(PORTABLE_KERNELS_ENV).is_some() {
        // 子进程：只报摘要。
        for (case, digest) in digests() {
            println!("{CHILD_MARKER} {case}={digest}");
        }
        return;
    }
    let child = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "vector_and_portable_kernels_agree_bit_for_bit",
            "--exact",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(PORTABLE_KERNELS_ENV, "1")
        .output()
        .expect("spawn the portable-kernel child");
    let stdout = String::from_utf8_lossy(&child.stdout);
    assert!(
        child.status.success(),
        "portable-kernel child failed:\n{stdout}\n{}",
        String::from_utf8_lossy(&child.stderr)
    );
    let portable: BTreeMap<String, String> = stdout
        .lines()
        // libtest prints "test <name> ... " in front of the first line.
        .filter_map(|line| {
            line.find(CHILD_MARKER)
                .map(|at| &line[at + CHILD_MARKER.len()..])
        })
        .filter_map(|rest| rest.trim().split_once('='))
        .map(|(case, digest)| (case.to_owned(), digest.to_owned()))
        .collect();
    assert_eq!(portable.len(), digests().len(), "child output:\n{stdout}");
    for (case, vector) in digests() {
        assert_eq!(
            &portable[case], vector,
            "{case}: portable kernels differ from this machine's vector kernels"
        );
    }
}

#[test]
fn digests_match_the_golden_values() {
    let actual = digests();
    if std::env::var_os("FUSHI_RWKV_PRINT_DIGESTS").is_some() {
        for (case, digest) in actual {
            println!("    (\"{case}\", \"{digest}\"),");
        }
    }
    assert_eq!(actual.len(), GOLDEN.len());
    let mismatched: Vec<String> = GOLDEN
        .iter()
        .filter(|(case, golden)| actual[*case] != *golden)
        .map(|(case, golden)| format!("{case}: golden {golden}, here {}", actual[*case]))
        .collect();
    assert!(
        mismatched.is_empty(),
        "this platform ({} {}) is not bit-identical to the x86_64 golden values:\n  {}",
        std::env::consts::ARCH,
        std::env::consts::OS,
        mismatched.join("\n  ")
    );
}
