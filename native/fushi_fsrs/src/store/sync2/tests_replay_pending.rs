//! 审查 S-4：分批收段会话里受影响的卡只记进待重放集合、收尾按片重放一次。对拍：随机多设备交错复习（含插进历史
//! 中间的离线补交）、随机切批 / 切片 / 重放分片，新设备逐卡日志与「一次收完当场重放」、与全量重放逐字节相同；
//! 收尾前被打断（会话丢掉 / 重开库）后，下一次收尾接着把剩下的重放完。

use proptest::prelude::*;
use serde_json::{json, Value};

use super::tests::{deck_entity, edit, review, Bucket, Device, P};
use super::transport::CommitBudget;

const T0: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;

fn logs(d: &Device) -> Vec<Vec<String>> {
    d.rows("SELECT id, card_id, json FROM srs_review_logs ORDER BY id")
}

fn heads(b: &Bucket) -> Vec<Vec<u8>> {
    b.0.iter()
        .filter(|(k, _)| k.rsplit('/').next().and_then(crate::sync2::segment::parse_head_file_name).is_some())
        .map(|(_, v)| v.clone())
        .collect()
}

fn segs(b: &Bucket) -> Vec<Vec<u8>> {
    b.0.iter().filter(|(k, _)| k.contains("/seg-")).map(|(_, v)| v.clone()).collect()
}

/// 三台设备在随机时刻复习几张共用的卡，两波（第二波含早于第一波的离线补交），每波后各自同步一次。
fn world(reviews: &[(usize, usize, i64, i64)]) -> Bucket {
    let deck = super::config::default_deck_id(P);
    let devs: Vec<Device> = (0..3).map(|i| Device::new(&format!("rp{i}"))).collect();
    let mut bucket = Bucket::default();
    devs[0].apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("D"))]);
    devs[0].sync(&mut bucket, "loc", T0);
    for d in &devs[1..] {
        d.sync(&mut bucket, "loc", T0);
    }
    let half = reviews.len() / 2;
    for (wave, part) in [&reviews[..half], &reviews[half..]].into_iter().enumerate() {
        for (i, d) in devs.iter().enumerate() {
            let mut mine: Vec<&(usize, usize, i64, i64)> = part.iter().filter(|r| r.0 == i).collect();
            mine.sort_by_key(|r| r.2);
            for (k, (_, card, at, rating)) in mine.into_iter().enumerate() {
                let at = T0 + at;
                let rtype = if k == 0 && wave == 0 { "learn" } else { "review" };
                let id = format!("w{wave}d{i}k{k}c{card}");
                d.apply(T0 + 40 * DAY + (wave as i64) * DAY, vec![review(&id, &format!("C{card}"), at, *rating, rtype)]);
            }
        }
        for (i, d) in devs.iter().enumerate() {
            d.sync(&mut bucket, "loc", T0 + 41 * DAY + (wave as i64) * DAY + i as i64);
        }
    }
    bucket
}

/// 新设备按分批会话收齐 [bucket]：段按 [batch] 个一批，投递每片 [slice] 条，收尾的重放每片 [replay] 张卡。
fn join_sliced(bucket: &Bucket, batch: usize, slice: usize, replay: usize) -> Device {
    let d = Device::new("rp-join");
    let now = T0 + 50 * DAY;
    d.core.sync2_identity(P, now).unwrap();
    d.core.sync2_plan(P, &heads(bucket)).unwrap();
    d.core.sync2_ingest_begin(P).unwrap();
    for chunk in segs(bucket).chunks(batch.max(1)) {
        d.core.sync2_ingest_prepare(P, chunk, None).unwrap();
        loop {
            let r: Value = serde_json::from_str(&d.core.sync2_ingest_commit(P, now, CommitBudget::ops(slice)).unwrap()).unwrap();
            assert_eq!(r["replayed"], json!([]), "slices only record the touched cards: {r}");
            if r["more"] != json!(true) {
                break;
            }
        }
    }
    let mut r: Value = serde_json::from_str(&d.core.sync2_ingest_finish_within(P, now, CommitBudget::ops(replay)).unwrap()).unwrap();
    while r["more"] == json!(true) {
        r = serde_json::from_str(&d.core.sync2_replay_pending(P, CommitBudget::ops(replay)).unwrap()).unwrap();
    }
    assert_eq!(d.rows("SELECT COUNT(*) FROM sync2_replay_pending")[1][0], "0");
    d
}

fn join_one_shot(bucket: &Bucket) -> Device {
    let d = Device::new("rp-one");
    let now = T0 + 50 * DAY;
    d.core.sync2_identity(P, now).unwrap();
    d.core.sync2_plan(P, &heads(bucket)).unwrap();
    d.core.sync2_ingest(P, &segs(bucket), None, now).unwrap();
    d
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 16, ..ProptestConfig::default() })]

    #[test]
    fn deferred_replay_matches_immediate_and_full_replay(
        reviews in prop::collection::vec((0usize..3, 0usize..4, 0i64..30 * DAY, 1i64..5), 2..24),
        batch in 1usize..4,
        slice in 1usize..7,
        replay in 1usize..3,
    ) {
        let bucket = world(&reviews);
        let one = join_one_shot(&bucket);
        let sliced = join_sliced(&bucket, batch, slice, replay);
        prop_assert_eq!(logs(&sliced), logs(&one));
        // 收尾后的投影就是全量重放的结果：再全量重放一次什么都不改。
        prop_assert_eq!(sliced.core.sync2_replay_all(P).unwrap(), Vec::<String>::new());
        prop_assert_eq!(logs(&sliced), logs(&one));
    }
}

/// 收尾之前被打断（会话丢了、库重开）：待重放集合留在库里，下一轮会话一收尾（没有新段也一样）就接着重放完，
/// 结果与一次收完相同。`plan` 报 `finishPending` 让 Dart 侧知道要收这个尾。
#[test]
fn interrupted_session_resumes_the_pending_replay() {
    let reviews: Vec<(usize, usize, i64, i64)> = vec![
        (0, 0, 2 * DAY, 3),
        (1, 0, DAY, 2),
        (2, 0, 3 * DAY, 4),
        (0, 1, 5 * DAY, 1),
        (1, 1, 4 * DAY, 3),
        (2, 0, 2 * DAY + 5, 3),
        (0, 0, 10 * DAY, 3),
        (1, 1, 6 * DAY, 2),
    ];
    let bucket = world(&reviews);
    let one = join_one_shot(&bucket);
    let dir = super::tests::tempdir::new("rp-crash");
    let path = dir.0.join("srs.db");
    let now = T0 + 50 * DAY;
    {
        let core = crate::store::SrsCore::open(&path).unwrap();
        core.sync2_identity(P, now).unwrap();
        core.sync2_plan(P, &heads(&bucket)).unwrap();
        core.sync2_ingest_begin(P).unwrap();
        core.sync2_ingest_prepare(P, &segs(&bucket), None).unwrap();
        loop {
            let r: Value = serde_json::from_str(&core.sync2_ingest_commit(P, now, CommitBudget::ops(3)).unwrap()).unwrap();
            if r["more"] != json!(true) {
                break;
            }
        }
        // 「被杀」：不收尾。
    }
    let d = Device { core: crate::store::SrsCore::open(&path).unwrap(), _dir: dir };
    assert_ne!(d.rows("SELECT COUNT(*) FROM sync2_replay_pending")[1][0], "0");
    let plan = d.core.sync2_plan(P, &heads(&bucket)).unwrap();
    assert_eq!(plan["fetch"], json!([]), "{plan}");
    assert_eq!(plan["finishPending"], json!(true), "{plan}");
    d.core.sync2_ingest_begin(P).unwrap();
    let r: Value = serde_json::from_str(&d.core.sync2_ingest_finish(P, now).unwrap()).unwrap();
    assert_eq!(r["more"], json!(false), "{r}");
    assert_eq!(d.rows("SELECT COUNT(*) FROM sync2_replay_pending")[1][0], "0");
    assert_eq!(d.core.sync2_plan(P, &heads(&bucket)).unwrap()["finishPending"], json!(false));
    assert_eq!(logs(&d), logs(&one));
}
