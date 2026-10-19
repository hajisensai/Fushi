//! Generates the parity fixtures for native/fushi_rwkv from the **upstream**
//! implementation (kuma3-anki-core `rslib/src/rwkv`, compiled verbatim by this
//! crate's lib.rs).
//!
//! usage: golden <model.bin> <py_golden.json> <out_dir>
//!
//! Every fixture holds the input rows and, per state precision, the values the
//! upstream `RwkvInference` produced for them:
//!   * `warm_up` step: `warm_up_reviews(rows, record_predictions)` → the
//!     `(index, retrievability)` pairs it returns;
//!   * `query` step: `predict_retrievability_many_from_warm_up(rows)`.
//!
//! Row layout (10 entries, `null` = None):
//!   [card_id, note_id, deck_id, preset_id, ease, duration_millis, card_type,
//!    day_offset, current_elapsed_days, current_elapsed_seconds]
use std::collections::BTreeMap;
use std::path::PathBuf;

use rwkv_oracle::rwkv::ReviewInput;
use rwkv_oracle::rwkv::RwkvInference;
use rwkv_oracle::rwkv::StatePrecision;
use serde::Deserialize;
use serde::Serialize;
use serde_json::json;
use serde_json::Value;

type Row = [Option<i64>; 10];

#[derive(Clone, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Step {
    WarmUp {
        record_predictions: bool,
        rows: Vec<Row>,
    },
    Query {
        rows: Vec<Row>,
    },
}

fn review_input(row: &Row, is_query: bool) -> ReviewInput {
    ReviewInput {
        card_id: row[0].expect("card id"),
        note_id: row[1],
        deck_id: row[2],
        preset_id: row[3],
        is_query,
        ease: if is_query { None } else { row[4].map(|e| e as u8) },
        duration_millis: if is_query { None } else { row[5] },
        card_type: row[6],
        day_offset: row[7],
        current_elapsed_days: row[8],
        current_elapsed_seconds: row[9],
        // Only read by the curve/interval solver, which fushi_rwkv drops.
        target_retentions: [Some(0.9); 4],
        enforce_grade_order: true,
    }
}

fn run(model: &PathBuf, precision: StatePrecision, steps: &[Step]) -> Vec<Value> {
    let mut inference =
        RwkvInference::load_with_precision(model.clone(), 0.9, 36_500, precision).unwrap();
    steps
        .iter()
        .map(|step| match step {
            Step::WarmUp {
                record_predictions,
                rows,
            } => {
                let inputs = rows.iter().map(|r| review_input(r, false)).collect();
                let out = inference
                    .warm_up_reviews(inputs, *record_predictions)
                    .unwrap();
                json!(out.into_iter().map(|(i, r)| json!([i, r])).collect::<Vec<_>>())
            }
            Step::Query { rows } => {
                let inputs = rows.iter().map(|r| review_input(r, true)).collect();
                json!(inference
                    .predict_retrievability_many_from_warm_up(inputs)
                    .unwrap())
            }
        })
        .collect()
}

fn write_fixture(
    out_dir: &PathBuf,
    name: &str,
    description: &str,
    model: &PathBuf,
    steps: Vec<Step>,
    extra: Value,
) {
    let mut expected = BTreeMap::new();
    for (label, precision) in [("f32", StatePrecision::F32), ("int8", StatePrecision::Int8)] {
        expected.insert(label, run(model, precision, &steps));
    }
    let fixture = json!({
        "name": name,
        "description": description,
        "generated_by": "tools/oracle: upstream kuma3-anki-core rslib/src/rwkv compiled verbatim",
        "upstream": {
            "repo": "https://github.com/Pedrubik2000/kuma3-anki-core",
            "sha": std::env::var("RWKV_UPSTREAM_SHA").unwrap_or_default(),
        },
        "target": format!("{}-{}", std::env::consts::ARCH, std::env::consts::OS),
        "steps": steps,
        "expected": expected,
        "extra": extra,
    });
    let path = out_dir.join(format!("{name}.json"));
    // Compact single-line JSON keeps the large fixture small.
    let mut text = serde_json::to_string(&fixture).unwrap();
    text.push('\n');
    std::fs::write(&path, text).unwrap();
    eprintln!("wrote {}", path.display());
}

#[derive(Deserialize)]
struct PyGolden {
    #[serde(rename = "_RWKV_GOLDEN_REVIEWS")]
    reviews: Vec<PyReview>,
    #[serde(rename = "_RWKV_GOLDEN_ROW0_IMMEDIATE")]
    row0: f64,
    #[serde(rename = "_RWKV_GOLDEN_ROW34_IMMEDIATE")]
    row34: f64,
}

#[derive(Deserialize)]
struct PyReview {
    card_id: i64,
    note_id: i64,
    deck_id: i64,
    preset_id: i64,
    day_offset: i64,
    rating: i64,
    state: i64,
    duration: i64,
    elapsed_days: i64,
    elapsed_seconds: i64,
}

fn py_row(r: &PyReview) -> Row {
    [
        Some(r.card_id),
        Some(r.note_id),
        Some(r.deck_id),
        Some(r.preset_id),
        Some(r.rating),
        Some(r.duration),
        Some(r.state),
        Some(r.day_offset),
        Some(r.elapsed_days),
        Some(r.elapsed_seconds),
    ]
}

fn query_row(r: &Row) -> Row {
    [r[0], r[1], r[2], r[3], None, None, r[6], r[7], r[8], r[9]]
}

/// Same LCG as upstream's `bulk_parity_reviews` test helper.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> i64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (self.0 >> 33) as i64
    }
    fn below(&mut self, n: i64) -> i64 {
        self.next().rem_euclid(n)
    }
}

const DAY: i64 = 86_400;

struct SimCard {
    card_id: i64,
    note_id: Option<i64>,
    deck_id: Option<i64>,
    preset_id: Option<i64>,
    last_ts: Option<i64>,
    last_day: Option<i64>,
    interval: i64,
    due_day: i64,
}

/// A plausible collection: new cards graduate through same-day learning steps,
/// reviews follow a growing interval, lapses go through relearning, a few
/// rows are early (cram) reviews or rating-less (manual reschedule) entries.
/// `day_offset` is the scheduler day (rollover already applied), and the
/// elapsed values are measured between the card's own answered reviews.
fn simulate(
    seed: u64,
    cards: usize,
    days: i64,
    new_per_day: usize,
    first_day: i64,
) -> (Vec<(i64, Row)>, Vec<SimCard>) {
    let mut rng = Lcg(seed);
    let mut sim: Vec<SimCard> = (0..cards)
        .map(|i| {
            let card_id = 1_600_000_000_000 + i as i64 * 7;
            let note_index = i as i64 / 2;
            let deck_index = note_index % 5;
            SimCard {
                card_id,
                note_id: (i % 17 != 16).then_some(1_500_000_000_000 + note_index),
                deck_id: (i % 23 != 22).then_some(1_700_000_000_000 + deck_index),
                preset_id: (deck_index != 4)
                    .then_some([8_169_090_998_413_644_153_i64, 3_366_177_995_109_454_929, 1][deck_index as usize % 3]),
                last_ts: None,
                last_day: None,
                interval: 0,
                due_day: i64::MAX,
            }
        })
        .collect();
    let mut rows = Vec::new();
    let mut introduced = 0;
    for day in 0..days {
        // a missed day now and then
        if rng.below(11) == 0 {
            continue;
        }
        let mut ts = (first_day + day) * DAY + 6 * 3600 + rng.below(8 * 3600);
        let mut today: Vec<usize> = sim
            .iter()
            .enumerate()
            .filter(|(_, c)| c.due_day <= day)
            .map(|(i, _)| i)
            .collect();
        // a few early reviews of cards not yet due
        for (i, c) in sim.iter().enumerate() {
            if c.last_day.is_some() && c.due_day > day && rng.below(97) == 0 {
                today.push(i);
            }
        }
        for _ in 0..new_per_day {
            if introduced < cards {
                today.push(introduced);
                introduced += 1;
            }
        }
        for index in today {
            let mut push = |sim: &mut Vec<SimCard>,
                            rng: &mut Lcg,
                            ts: &mut i64,
                            card_type: i64,
                            ease: Option<i64>| {
                let c = &mut sim[index];
                let duration = 1_500 + rng.below(25_000);
                let (ed, es) = match (c.last_ts, c.last_day) {
                    (Some(lt), Some(ld)) => (day - ld, *ts - lt),
                    _ => (-1, -1),
                };
                rows.push((
                    *ts,
                    [
                        Some(c.card_id),
                        c.note_id,
                        c.deck_id,
                        c.preset_id,
                        ease,
                        Some(duration),
                        Some(card_type),
                        Some(first_day + day),
                        Some(ed),
                        Some(es),
                    ],
                ));
                if ease.is_some() {
                    c.last_ts = Some(*ts);
                    c.last_day = Some(day);
                }
                *ts += duration / 1000 + 5 + rng.below(40);
            };
            let is_new = sim[index].last_day.is_none();
            if is_new {
                let ease = [1, 1, 2, 3, 3, 3, 4][rng.below(7) as usize];
                push(&mut sim, &mut rng, &mut ts, 0, Some(ease));
                let mut ease = ease;
                while ease < 3 {
                    ts += 60 + rng.below(540);
                    ease = [1, 2, 3, 3, 3, 4][rng.below(6) as usize];
                    push(&mut sim, &mut rng, &mut ts, 1, Some(ease));
                }
                let c = &mut sim[index];
                c.interval = if ease == 4 { 4 } else { 1 };
                c.due_day = day + c.interval;
                continue;
            }
            if rng.below(53) == 0 {
                // rating-less entry (manual reschedule): upstream skips it
                push(&mut sim, &mut rng, &mut ts, 2, None);
                continue;
            }
            let roll = rng.below(100);
            let ease = if roll < 11 {
                1
            } else if roll < 25 {
                2
            } else if roll < 90 {
                3
            } else {
                4
            };
            push(&mut sim, &mut rng, &mut ts, 2, Some(ease));
            let c = &mut sim[index];
            if ease == 1 {
                ts += 300 + rng.below(600);
                push(&mut sim, &mut rng, &mut ts, 3, Some(3));
                let c = &mut sim[index];
                c.interval = 1.max(c.interval / 3);
            } else {
                let factor = [0, 0, 12, 25, 35][ease as usize];
                c.interval = (c.interval * factor / 10).max(c.interval + 1);
            }
            let c = &mut sim[index];
            c.due_day = day + c.interval;
        }
    }
    (rows, sim)
}

fn queries_for(sim: &[SimCard], day: i64, first_day: i64, extra_unseen: &[i64]) -> Vec<Row> {
    let now = (first_day + day) * DAY + 9 * 3600;
    let mut rows: Vec<Row> = sim
        .iter()
        .filter(|c| c.last_day.is_some())
        .map(|c| {
            [
                Some(c.card_id),
                c.note_id,
                c.deck_id,
                c.preset_id,
                None,
                None,
                Some(2),
                Some(first_day + day),
                Some(day - c.last_day.unwrap()),
                Some(now - c.last_ts.unwrap()),
            ]
        })
        .collect();
    for card_id in extra_unseen {
        rows.push([
            Some(*card_id),
            Some(card_id + 1),
            Some(1_700_000_000_000),
            Some(1),
            None,
            None,
            Some(0),
            Some(first_day + day),
            Some(-1),
            Some(-1),
        ]);
    }
    rows
}

/// Splits a chronological history into warm-up calls of `chunk` rows with
/// queries for every seen card after each call (snapshotting the simulated
/// card bookkeeping at those cut points).
fn chunked_steps(
    seed: u64,
    cards: usize,
    days: i64,
    new_per_day: usize,
    first_day: i64,
    cuts: &[i64],
    unseen: &[i64],
) -> Vec<Step> {
    let mut steps = Vec::new();
    let mut start_day = 0;
    for (n, &cut) in cuts.iter().chain(std::iter::once(&days)).enumerate() {
        // re-simulate up to the cut: deterministic, so the prefix is identical
        let (rows, sim) = simulate(seed, cards, cut, new_per_day, first_day);
        let chunk: Vec<Row> = rows
            .into_iter()
            .filter(|(_, r)| r[7].unwrap() - first_day >= start_day)
            .map(|(_, r)| r)
            .collect();
        steps.push(Step::WarmUp {
            record_predictions: n % 2 == 0,
            rows: chunk,
        });
        steps.push(Step::Query {
            rows: queries_for(&sim, cut + 3, first_day, unseen),
        });
        start_day = cut;
    }
    steps
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let model = PathBuf::from(&args[1]);
    let py: PyGolden =
        serde_json::from_str(&std::fs::read_to_string(&args[2]).unwrap()).unwrap();
    let out_dir = PathBuf::from(&args[3]);
    std::fs::create_dir_all(&out_dir).unwrap();

    // 1. The 35-review history of upstream's own golden test
    //    (qt/tests/test_rwkv_inference_process.py), replayed in one call with
    //    predictions, then the last nine rows queried, as that test does.
    let py_rows: Vec<Row> = py.reviews.iter().map(py_row).collect();
    let tail_queries: Vec<Row> = py_rows[py_rows.len() - 9..].iter().map(query_row).collect();
    write_fixture(
        &out_dir,
        "upstream_golden_history",
        "Upstream test_rwkv_inference_process.py history: one warm-up call with predictions, then its last nine rows as queries.",
        &model,
        vec![
            Step::WarmUp {
                record_predictions: true,
                rows: py_rows.clone(),
            },
            Step::Query {
                rows: tail_queries.clone(),
            },
        ],
        json!({
            "python_test_row0_immediate": py.row0,
            "python_test_row34_immediate": py.row34,
            "python_test_abs_tol": 1e-6,
        }),
    );

    // 2. Same history, one warm-up call per review (the incremental path an
    //    app takes after each answer).
    let mut steps: Vec<Step> = py_rows
        .iter()
        .map(|r| Step::WarmUp {
            record_predictions: true,
            rows: vec![*r],
        })
        .collect();
    steps.push(Step::Query { rows: tail_queries });
    write_fixture(
        &out_dir,
        "upstream_golden_history_incremental",
        "Upstream golden history replayed one review per warm-up call.",
        &model,
        steps,
        json!({
            "python_test_row0_immediate": py.row0,
            "python_test_row34_immediate": py.row34,
            "python_test_abs_tol": 1e-6,
        }),
    );

    // 3. Hand-written edge cases.
    let d0 = 20_000;
    let r = |c: i64, n: Option<i64>, d: Option<i64>, p: Option<i64>, e: Option<i64>, dur: Option<i64>, t: i64, day: i64, ed: i64, es: i64| -> Row {
        [Some(c), n, d, p, e, dur, Some(t), Some(d0 + day), Some(ed), Some(es)]
    };
    let edge_warm_1 = vec![
        r(1, Some(101), Some(11), Some(21), Some(1), Some(12_000), 0, 0, -1, -1),
        r(1, Some(101), Some(11), Some(21), Some(3), Some(4_000), 1, 0, 0, 75),
        r(2, Some(101), Some(11), Some(21), Some(3), Some(6_500), 0, 0, -1, -1), // sibling of card 1
        r(3, None, Some(12), Some(21), Some(4), Some(2_000), 0, 0, -1, -1),       // no note
        r(4, Some(104), None, None, Some(2), Some(30_000), 0, 0, -1, -1),          // no deck/preset
        r(4, Some(104), None, None, Some(3), None, 1, 0, 0, 610),                 // no duration
        r(5, Some(105), Some(13), Some(22), None, Some(1_000), 2, 0, 0, 30),      // rating-less: skipped
        r(1, Some(101), Some(11), Some(21), Some(3), Some(3_100), 2, 1, 1, 86_000),
        r(2, Some(101), Some(11), Some(21), Some(1), Some(9_000), 2, 1, 1, 86_410),
        r(2, Some(101), Some(11), Some(21), Some(3), Some(5_000), 3, 1, 0, 420),  // relearn same day
        r(3, None, Some(12), Some(21), Some(2), Some(7_000), 2, 4, 4, 4 * DAY + 999),
    ];
    let edge_query_1 = vec![
        r(1, Some(101), Some(11), Some(21), None, None, 2, 5, 4, 4 * DAY + 3_600),
        r(2, Some(101), Some(11), Some(21), None, None, 2, 5, 4, 4 * DAY + 1_234),
        r(3, None, Some(12), Some(21), None, None, 2, 5, 1, DAY + 77),
        r(4, Some(104), None, None, None, None, 2, 5, 5, 5 * DAY),
        r(1, Some(101), Some(11), Some(21), None, None, 2, 400, 399, 399 * DAY), // same card, far future
        r(9, Some(109), Some(11), Some(21), None, None, 0, 5, -1, -1),           // never reviewed
        r(10, None, None, None, None, None, 0, 5, -1, -1),                        // never reviewed, no ids
        [Some(1), Some(101), Some(11), Some(21), None, None, None, Some(d0 + 5), None, Some(4 * DAY)], // elapsed days from seconds
        [Some(2), Some(101), Some(11), Some(21), None, None, None, Some(d0 + 5), Some(4), None],       // elapsed seconds from days
    ];
    let edge_warm_2 = vec![
        r(9, Some(109), Some(11), Some(21), Some(4), Some(1_800), 0, 5, -1, -1),
        r(1, Some(101), Some(11), Some(21), Some(4), Some(2_200), 2, 5, 4, 4 * DAY + 3_700),
        r(1, Some(101), Some(11), Some(21), Some(3), Some(2_000), 2, 5, 0, 300), // same-day re-review
        r(4, Some(104), None, None, Some(1), Some(15_000), 2, 1100, 1095, 1095 * DAY + 5), // 3-year gap
        r(4, Some(104), None, None, Some(3), Some(8_000), 3, 1100, 0, 900),
    ];
    let edge_query_2 = edge_query_1
        .iter()
        .map(|q| {
            let mut q = *q;
            q[7] = Some(d0 + 1101);
            q
        })
        .collect();
    write_fixture(
        &out_dir,
        "edge_cases",
        "Hand-written edge cases: siblings, missing note/deck/preset ids, missing duration, rating-less row, same-day relearn, long gaps, never-reviewed queries, elapsed derived from the other unit.",
        &model,
        vec![
            Step::WarmUp { record_predictions: true, rows: edge_warm_1 },
            Step::Query { rows: edge_query_1 },
            Step::WarmUp { record_predictions: false, rows: edge_warm_2 },
            Step::Query { rows: edge_query_2 },
        ],
        json!({}),
    );

    // 4. A simulated collection: 640 cards (320 notes, 5 decks, 3 presets),
    //    ~400 days, several warm-up calls (one larger than the upstream bulk
    //    chunk of 2048 rows), query batches over every seen card (> 512 rows,
    //    the upstream state-view chunk) plus never-seen cards.
    let steps = chunked_steps(
        0x5eed_f05e_1234_0001,
        640,
        400,
        3,
        19_500,
        &[30, 200, 260],
        &[1_999_000_000_001, 1_999_000_000_003],
    );
    let rows: usize = steps
        .iter()
        .map(|s| match s {
            Step::WarmUp { rows, .. } => rows.len(),
            _ => 0,
        })
        .sum();
    eprintln!("simulated collection: {rows} warm-up rows");
    write_fixture(
        &out_dir,
        "simulated_collection",
        "Simulated collection (deterministic LCG): 640 cards, ~400 scheduler days, chunked warm-up calls and full-collection query batches.",
        &model,
        steps,
        json!({}),
    );
}
