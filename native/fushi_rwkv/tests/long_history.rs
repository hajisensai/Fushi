// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 长历史压力：几张卡各被复习几千次（按天、混合评分）。小模型 card / note 状态在 int8 / int4 下
//! 必须与 f32 同一量级、全程有限。
//!
//! 背景（2026-10-20）：旧的 int4 量化（每行按 max/7 定标、四舍五入）在一份真实的 121 万条复习
//! 历史上让 101 张高频卡的 card 状态每次复习 ×1.06（0.25 → 7,962，往 f32 溢出走）；上游大模型
//! 在 350 万条历史上的 int4 笔记状态也是同样的结局（UPSTREAM.md）。修法见
//! `src/rwkv/small/model.rs` 的 `Layout::write_rows`（最小二乘比例因子：存下的行不长于原行）。

mod common;

use std::io::Read;

use common::{model, small_package};
use fushi_rwkv::{ReviewInput, RwkvInference, SmallInference, SmallModel, StatePrecision};

fn small_model() -> SmallModel {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(small_package())).unwrap();
    let mut bytes = Vec::new();
    archive
        .by_name("sm56/weights.int8.bin")
        .unwrap()
        .read_to_end(&mut bytes)
        .unwrap();
    SmallModel::from_bytes(&bytes).unwrap()
}

fn history(cards: i64, days: i64) -> Vec<ReviewInput> {
    let mut seed = 3u64;
    let mut next = || {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (seed >> 33) as i64
    };
    let mut reviews = Vec::new();
    let mut last: Vec<Option<(i64, i64)>> = vec![None; cards as usize];
    for day in 0..days {
        let mut ts = day * 86_400 + 8 * 3600;
        for card in 0..cards {
            let previous = last[card as usize];
            let (ed, es) = previous.map_or((-1, -1), |(d, t)| (day - d, ts - t));
            reviews.push(ReviewInput {
                card_id: 10 + card,
                note_id: Some(100 + card / 2),
                deck_id: Some(1),
                preset_id: Some(1),
                is_query: false,
                ease: Some([1u8, 2, 3, 3, 3, 3, 4][(next() % 7) as usize]),
                duration_millis: Some(2_000 + next() % 9_000),
                card_type: Some(if previous.is_none() { 0 } else { 2 }),
                day_offset: Some(day),
                current_elapsed_days: Some(ed),
                current_elapsed_seconds: Some(es),
            });
            last[card as usize] = Some((day, ts));
            ts += 40 + next() % 300;
        }
    }
    reviews
}

#[test]
fn long_histories_keep_compact_states_bounded() {
    let model = small_model();
    let (cards, days): (i64, i64) = (6, std::env::var("LONG_DAYS").ok().and_then(|v| v.parse().ok()).unwrap_or(2500));
    let reviews = history(cards, days);
    let peaks = |precision: StatePrecision| {
        let mut runtime = SmallInference::new(&model, precision);
        runtime.warm_up_reviews(reviews.clone(), false).unwrap();
        [runtime.stream_peak(0), runtime.stream_peak(2)]
    };
    let exact = peaks(StatePrecision::F32);
    for precision in [StatePrecision::Int8, StatePrecision::Int4] {
        let compact = peaks(precision);
        eprintln!("{precision:?}: card / note peaks {compact:?} (f32 {exact:?})");
        for (stream, (&c, &e)) in ["card", "note"].iter().zip(compact.iter().zip(&exact)) {
            assert!(
                c.is_finite() && c <= 2.0 * e.max(0.1),
                "{precision:?} {stream} state peak {c} vs f32 {e} after {days} reviews per card"
            );
        }
    }
}

/// 大模型同样的历史：int8 与 f32 同量级。int4 不支持（`ModelKind::supports`）：card 状态在这份
/// 历史上照样发散（每卡 2,500 次复习峰值 ~1.2e3、1 万次 ~1.3e16），这里一并钉住，
/// 免得有人以为换了量化器就能放开。`LONG_DAYS=10000` 可加长（本地 ~1 分钟）。
#[test]
fn long_histories_keep_large_model_compact_states_bounded() {
    let (cards, days): (i64, i64) = (6, std::env::var("LONG_DAYS").ok().and_then(|v| v.parse().ok()).unwrap_or(2500));
    let reviews = history(cards, days);
    let peaks = |precision: StatePrecision| {
        let mut runtime = RwkvInference::new(model(), precision);
        runtime.warm_up_reviews(reviews.clone(), false).unwrap();
        [runtime.stream_peak(0), runtime.stream_peak(2)]
    };
    let exact = peaks(StatePrecision::F32);
    let int4 = peaks(StatePrecision::Int4)[0];
    eprintln!("large Int4 card peak {int4} (f32 {})", exact[0]);
    assert!(
        !(int4 <= 10.0 * exact[0]),
        "large-model int4 card states no longer diverge ({int4}); revisit ModelKind::supports"
    );
    assert!(
        fushi_rwkv::RwkvRuntime::new(
            &fushi_rwkv::Model::from(model().clone()),
            StatePrecision::Int4,
            1
        )
        .is_err()
    );
    for precision in [StatePrecision::Int8] {
        let compact = peaks(precision);
        eprintln!("large {precision:?}: card / note peaks {compact:?} (f32 {exact:?})");
        for (stream, (&c, &e)) in ["card", "note"].iter().zip(compact.iter().zip(&exact)) {
            assert!(
                c.is_finite() && c <= 2.0 * e.max(0.1),
                "large {precision:?} {stream} state peak {c} vs f32 {e} after {days} reviews per card"
            );
        }
    }
}
