// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 撤销日志（`append` / `unappend`）与常驻分数表（`scores_*`）的契约（小模型，三种精度）：
//! - append 与 replay 同一批行：快照逐字节相同；
//! - unappend 回到 append 之前：快照逐字节相同（含首次见到的卡抽的 ID 编码与随机流位置）；
//!   中间有查询抽了新编码时，状态流与簿记照样回去、已知卡的查询结果逐位相同；
//! - 标签不是最近一条 / 之后有 replay：什么都不改、返回 false；
//! - 分数表：update 与 query 同批逐位相同；逐行 update 与整批 update 逐位相同（每行的 R 不取决于
//!   同批别的行——增量「只重算一张」与全量刷新数值一致）；append / unappend 只作废同卡、同笔记的项；
//! - C ABI 往返；大模型 append 返回 Unsupported。

mod common;

use std::io::Read;

use common::{model, small_package};
use fushi_rwkv::*;

fn small_model() -> Model {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(small_package())).unwrap();
    let mut bytes = Vec::new();
    archive
        .by_name("sm56/weights.int8.bin")
        .unwrap()
        .read_to_end(&mut bytes)
        .unwrap();
    Model::from_bytes(&bytes).unwrap()
}

/// 90 天、60 张卡（两卡一笔记、三个牌组）的确定性历史 + 第 90 天要追加的几条作答（其中一条是
/// 从没复习过的新卡 999：首次见到，抽新的 ID 编码）。
fn history() -> (Vec<ReviewInput>, Vec<ReviewInput>) {
    let mut reviews = Vec::new();
    let mut last: Vec<Option<(i64, i64)>> = vec![None; 60];
    let mut seed = 11u64;
    let mut next = || {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (seed >> 33) as i64
    };
    let row = |card: i64, day: i64, ts: i64, last: Option<(i64, i64)>, ease: u8, card_type: i64| {
        let (ed, es) = last.map_or((-1, -1), |(d, t)| (day - d, ts - t));
        ReviewInput {
            card_id: 1_000 + card,
            note_id: Some(5_000 + card / 2),
            deck_id: Some(1 + card % 3),
            preset_id: Some(1),
            is_query: false,
            ease: Some(ease),
            duration_millis: Some(4_000),
            card_type: Some(card_type),
            day_offset: Some(day),
            current_elapsed_days: Some(ed),
            current_elapsed_seconds: Some(es),
        }
    };
    for day in 0..90i64 {
        let mut ts = day * 86_400 + 9 * 3600;
        for card in 0..60usize {
            let due = match last[card] {
                None => card as i64 / 2 == day,
                Some((d, _)) => (day - d) >= 1 + (next() % 9),
            };
            if !due {
                continue;
            }
            let ease = [1u8, 3, 3, 3, 3, 4, 2][(next() % 7) as usize];
            let card_type = if last[card].is_none() { 0 } else { 2 };
            reviews.push(row(card as i64, day, ts, last[card], ease, card_type));
            last[card] = Some((day, ts));
            ts += 30;
        }
    }
    let ts = 90 * 86_400 + 9 * 3600;
    let appended = vec![
        row(4, 90, ts, last[4], 3, 2),
        row(5, 90, ts + 20, last[5], 1, 2),
        row(999, 90, ts + 40, None, 3, 0),
        row(4, 90, ts + 90, Some((90, ts)), 4, 2),
    ];
    (reviews, appended)
}

fn queries(day: i64, cards: impl Iterator<Item = i64>) -> Vec<ReviewInput> {
    cards
        .map(|card| ReviewInput {
            card_id: 1_000 + card,
            note_id: Some(5_000 + card / 2),
            deck_id: Some(1 + card % 3),
            preset_id: Some(1),
            is_query: true,
            ease: None,
            duration_millis: None,
            card_type: None,
            day_offset: Some(day),
            current_elapsed_days: Some(3),
            current_elapsed_seconds: Some(3 * 86_400 + 77),
        })
        .collect()
}

const PRECISIONS: [StatePrecision; 3] = [
    StatePrecision::F32,
    StatePrecision::Int8,
    StatePrecision::Int4,
];

fn bits(values: &[f32]) -> Vec<u32> {
    values.iter().map(|v| v.to_bits()).collect()
}

#[test]
fn append_matches_replay_and_unappend_restores_exactly() {
    let model = small_model();
    let (reviews, appended) = history();
    for precision in PRECISIONS {
        let mut replayed = RwkvRuntime::new(&model, precision, 1).unwrap();
        replayed.replay(&reviews, false).unwrap();
        replayed.replay(&appended, false).unwrap();

        let mut journaled = RwkvRuntime::new(&model, precision, 1).unwrap();
        journaled.replay(&reviews, false).unwrap();
        let before = journaled.snapshot().unwrap();
        let tags: Vec<u64> = (0..appended.len() as u64).map(|t| 100 + t).collect();
        journaled.append(&appended, &tags).unwrap();
        assert_eq!(journaled.journal_len(), appended.len());
        assert_eq!(
            journaled.snapshot().unwrap(),
            replayed.snapshot().unwrap(),
            "{precision:?}: append == replay"
        );

        // 不是最近一条：什么都不改。
        assert!(!journaled.unappend(100).unwrap());
        assert_eq!(journaled.snapshot().unwrap(), replayed.snapshot().unwrap());

        // 撤回最后两条（含新卡 999 那条之后的一条）与只回放前两条的状态逐字节相同。
        assert!(journaled.unappend(103).unwrap());
        assert!(journaled.unappend(102).unwrap());
        let mut partial = RwkvRuntime::new(&model, precision, 1).unwrap();
        partial.replay(&reviews, false).unwrap();
        partial.replay(&appended[..2], false).unwrap();
        assert_eq!(
            journaled.snapshot().unwrap(),
            partial.snapshot().unwrap(),
            "{precision:?}: unappend 2 of 4"
        );
        assert!(journaled.unappend(101).unwrap());
        assert!(journaled.unappend(100).unwrap());
        assert_eq!(journaled.snapshot().unwrap(), before, "{precision:?}: unappend all");
        assert!(!journaled.unappend(100).unwrap(), "journal is empty");
    }
}

#[test]
fn unappend_after_a_query_drew_new_codes_keeps_them_but_restores_the_states() {
    let model = small_model();
    let (reviews, appended) = history();
    let known = queries(91, 0..60);
    for precision in PRECISIONS {
        let mut reference = RwkvRuntime::new(&model, precision, 1).unwrap();
        reference.replay(&reviews, false).unwrap();
        let expected = reference.query(&known).unwrap();

        let mut runtime = RwkvRuntime::new(&model, precision, 1).unwrap();
        runtime.replay(&reviews, false).unwrap();
        runtime.append(&appended[2..3], &[7]).unwrap(); // 新卡 999：抽新编码
        runtime.query(&queries(91, 5_000..5_001)).unwrap(); // 查询一张首次见到的卡：再抽
        assert!(runtime.unappend(7).unwrap());
        assert_eq!(
            bits(&runtime.query(&known).unwrap()),
            bits(&expected),
            "{precision:?}"
        );
    }
}

#[test]
fn replay_restore_reset_clear_the_journal() {
    let model = small_model();
    let (reviews, appended) = history();
    let mut runtime = RwkvRuntime::new(&model, StatePrecision::Int4, 1).unwrap();
    runtime.replay(&reviews, false).unwrap();
    let snapshot = runtime.snapshot().unwrap();
    runtime.append(&appended[..1], &[1]).unwrap();
    runtime.replay(&appended[1..2], false).unwrap();
    assert!(!runtime.unappend(1).unwrap(), "replay cleared the journal");
    runtime.append(&appended[2..3], &[2]).unwrap();
    runtime.restore(&snapshot).unwrap();
    assert!(!runtime.unappend(2).unwrap(), "restore cleared the journal");
    runtime.append(&appended[..1], &[3]).unwrap();
    runtime.reset();
    assert!(!runtime.unappend(3).unwrap(), "reset cleared the journal");
}

#[test]
fn append_rejects_unrated_rows_and_the_large_model() {
    let model = small_model();
    let (reviews, appended) = history();
    let mut runtime = RwkvRuntime::new(&model, StatePrecision::Int4, 1).unwrap();
    runtime.replay(&reviews, false).unwrap();
    let before = runtime.snapshot().unwrap();
    let mut unrated = appended[0].clone();
    unrated.ease = None;
    assert!(matches!(
        runtime.append(&[appended[1].clone(), unrated], &[1, 2]),
        Err(RwkvError::Input(_))
    ));
    assert_eq!(runtime.snapshot().unwrap(), before, "nothing applied");
    assert!(matches!(
        runtime.append(&appended[..1], &[]),
        Err(RwkvError::Input(_))
    ));

    let large = Model::from(model_large());
    let mut runtime = RwkvRuntime::new(&large, StatePrecision::Int8, 1).unwrap();
    assert!(matches!(
        runtime.append(&appended[..1], &[1]),
        Err(RwkvError::Unsupported(_))
    ));
}

fn model_large() -> RwkvModel {
    model().clone()
}

#[test]
fn scores_single_and_batch_are_bit_identical_and_patching_is_scoped() {
    let model = small_model();
    let (reviews, appended) = history();
    let all = queries(90, 0..60);
    for precision in PRECISIONS {
        let mut runtime = RwkvRuntime::new(&model, precision, 0).unwrap();
        runtime.replay(&reviews, false).unwrap();
        let plain = runtime.query(&all).unwrap();
        let versions: Vec<u64> = (0..all.len() as u64).collect();
        let anchors = vec![-1i64; all.len()];
        let batch = runtime.scores_update(&all, &versions, &anchors).unwrap();
        assert_eq!(bits(&batch), bits(&plain), "{precision:?}: update == query");
        assert_eq!(runtime.scores_len(), 60);

        // 逐行 update（增量路径）与整批（全量刷新）逐位相同。
        let mut single = Vec::new();
        for (row, version) in all.iter().zip(&versions) {
            single.extend(
                runtime
                    .scores_update(std::slice::from_ref(row), &[*version], &[-1])
                    .unwrap(),
            );
        }
        assert_eq!(bits(&single), bits(&batch), "{precision:?}: single == batch");

        let ids: Vec<i64> = all.iter().map(|q| q.card_id).collect();
        let hits = runtime.scores_lookup(&ids, &versions);
        assert!(hits.iter().all(Option::is_some));
        let other: Vec<u64> = versions.iter().map(|v| v + 1).collect();
        assert!(runtime.scores_lookup(&ids, &other).iter().all(Option::is_none));

        // 作答卡 1004（笔记 5002，与 1005 同笔记）：只作废 1004 / 1005。
        runtime.append(&appended[..1], &[9]).unwrap();
        let hits = runtime.scores_lookup(&ids, &versions);
        for (id, hit) in ids.iter().zip(&hits) {
            assert_eq!(
                hit.is_none(),
                *id == 1_004 || *id == 1_005,
                "{precision:?}: card {id}"
            );
        }
        // 重算这两张后再撤回：又只作废这两张。
        runtime
            .scores_update(&all[4..6], &versions[4..6], &anchors[4..6])
            .unwrap();
        assert!(runtime.unappend(9).unwrap());
        let hits = runtime.scores_lookup(&ids, &versions);
        assert_eq!(hits.iter().filter(|h| h.is_none()).count(), 2);
        // 卡被永久清除：项从表里删掉（整表刷新不再算它），别的项不动；删不存在的不算。
        let before = runtime.scores_len();
        assert_eq!(runtime.scores_remove(&[ids[10], ids[11], 999_999]), 2);
        assert_eq!(runtime.scores_len(), before - 2);
        assert_eq!(
            runtime.scores_requery(1, 90 * 86_400_000).unwrap(),
            runtime.scores_len()
        );
        let hits = runtime.scores_lookup(&ids[10..13], &versions[10..13]);
        assert!(hits[0].is_none() && hits[1].is_none() && hits[2].is_some());
        runtime.scores_clear();
        assert_eq!(runtime.scores_len(), 0);
    }
}

#[test]
fn c_abi_round_trip() {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(small_package())).unwrap();
    let mut bytes = Vec::new();
    archive
        .by_name("sm56/weights.int8.bin")
        .unwrap()
        .read_to_end(&mut bytes)
        .unwrap();
    let (reviews, appended) = history();
    let rows = |inputs: &[ReviewInput]| -> Vec<FrwkvReview> {
        inputs.iter().map(FrwkvReview::from_input).collect()
    };
    assert_eq!(frwkv_abi_version(), ABI_VERSION);
    unsafe {
        let model = frwkv_model_load(bytes.as_ptr(), bytes.len());
        let runtime = frwkv_runtime_new(model, FRWKV_PRECISION_INT4, 1);
        let history = rows(&reviews);
        assert_eq!(
            frwkv_runtime_replay(runtime, history.as_ptr(), history.len(), std::ptr::null_mut()),
            FRWKV_OK
        );
        let tail = rows(&appended[..2]);
        let tags = [41u64, 42];
        assert_eq!(
            frwkv_runtime_append(runtime, tail.as_ptr(), tags.as_ptr(), 2),
            FRWKV_OK
        );
        assert_eq!(frwkv_runtime_unappend(runtime, 41), 0);
        assert_eq!(frwkv_runtime_unappend(runtime, 42), 1);
        assert_eq!(frwkv_runtime_unappend(runtime, 41), 1);

        let q = rows(&queries(90, 0..4));
        let versions = [1u64, 2, 3, 4];
        let mut out = [0f32; 4];
        assert_eq!(
            frwkv_runtime_scores_update(
                runtime,
                q.as_ptr(),
                versions.as_ptr(),
                [-1i64; 4].as_ptr(),
                4,
                out.as_mut_ptr()
            ),
            FRWKV_OK
        );
        let ids: Vec<i64> = q.iter().map(|r| r.card_id).collect();
        let asked = [1u64, 2, 99, 4];
        let mut scores = [0f32; 4];
        let mut found = [9u8; 4];
        let hits = frwkv_runtime_scores_lookup(
            runtime,
            ids.as_ptr(),
            asked.as_ptr(),
            4,
            scores.as_mut_ptr(),
            found.as_mut_ptr(),
        );
        assert_eq!(hits, 3);
        assert_eq!(found, [1, 1, 0, 1]);
        assert_eq!(scores[0].to_bits(), out[0].to_bits());
        assert!(scores[2].is_nan());
        assert_eq!(frwkv_runtime_scores_clear(runtime), FRWKV_OK);
        let hits = frwkv_runtime_scores_lookup(
            runtime,
            ids.as_ptr(),
            versions.as_ptr(),
            4,
            scores.as_mut_ptr(),
            found.as_mut_ptr(),
        );
        assert_eq!(hits, 0);
        frwkv_runtime_free(runtime);
        frwkv_model_free(model);
    }
}

/// 「此刻」查询行，与 Dart `srsRwkvAddNowRow` 同规则（复习队列）：锚点 = 上次评分时刻（毫秒）。
fn now_row(card: i64, last_ms: i64, last_type: i64, now_ms: i64, day_of: impl Fn(i64) -> i64) -> ReviewInput {
    let today = day_of(now_ms);
    let last_day = day_of(last_ms);
    ReviewInput {
        card_id: 1_000 + card,
        note_id: Some(5_000 + card / 2),
        deck_id: Some(1 + card % 3),
        preset_id: Some(1),
        is_query: true,
        ease: Some(0).filter(|_| false),
        duration_millis: None,
        card_type: Some(if today == last_day { last_type } else { 2 }),
        day_offset: Some(today),
        current_elapsed_days: Some((today - last_day).clamp(0, 1 << 40)),
        current_elapsed_seconds: Some(((now_ms - last_ms) / 1000).clamp(0, 1 << 50)),
    }
}

#[test]
fn requery_equals_rebuilding_the_rows_at_the_new_time() {
    let model = small_model();
    let (reviews, _) = history();
    let day_of = |ms: i64| ms.div_euclid(86_400_000);
    let base = 90 * 86_400_000 + 10 * 3_600_000;
    for precision in PRECISIONS {
        let mut runtime = RwkvRuntime::new(&model, precision, 0).unwrap();
        runtime.replay(&reviews, false).unwrap();
        // 30 张卡：一半昨天评过、一半今天早些时候评过（同日行 card_type 4）。
        let lasts: Vec<(i64, i64)> = (0..30)
            .map(|c| if c % 2 == 0 { (c, base - 86_400_000 + c * 1_000) } else { (c, base - 3_600_000 + c * 1_000) })
            .collect();
        let rows: Vec<ReviewInput> = lasts.iter().map(|&(c, at)| now_row(c, at, 4, base, day_of)).collect();
        let versions: Vec<u64> = (0..30).collect();
        let anchors: Vec<i64> = lasts.iter().map(|&(_, at)| at).collect();
        runtime.scores_update(&rows, &versions, &anchors).unwrap();

        for later in [base + 1_234_567, base + 20 * 3_600_000] {
            assert_eq!(runtime.scores_requery(day_of(later), later).unwrap(), 30);
            let fresh: Vec<ReviewInput> = lasts.iter().map(|&(c, at)| now_row(c, at, 4, later, day_of)).collect();
            let expected = runtime.query(&fresh).unwrap();
            let ids: Vec<i64> = fresh.iter().map(|r| r.card_id).collect();
            let got: Vec<f32> = runtime
                .scores_lookup(&ids, &versions)
                .into_iter()
                .map(Option::unwrap)
                .collect();
            assert_eq!(bits(&got), bits(&expected), "{precision:?} at {later}");
        }
    }
}
