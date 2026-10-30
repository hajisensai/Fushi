//! 同步 v2 性能与长期膨胀（2026-10-29 审查 S-5 / S-6 / S-8 / S-12）的回归。

use serde_json::{json, Value};

use super::tests::{deck_entity, edit, Bucket, Device, P};
use super::transport::CommitBudget;

const T0: i64 = 1_700_000_000_000;

fn heads(b: &Bucket) -> Vec<Vec<u8>> {
    b.0.iter()
        .filter(|(k, _)| k.rsplit('/').next().and_then(crate::sync2::segment::parse_head_file_name).is_some())
        .map(|(_, v)| v.clone())
        .collect()
}

fn device_of(d: &Device) -> String {
    d.core.sync2_status(P).unwrap()["device"].as_str().unwrap().to_owned()
}

/// S-12：本机身份分叉时只拉分歧点之后的本机段（不是 head 里的全部），收段被打断后下一轮不再重拉，收尾照样换身份、
/// 冻结在同一个分叉点。
#[test]
fn own_fork_fetches_only_past_the_divergence_and_survives_an_interrupted_round() {
    let deck = super::config::default_deck_id(P);
    let a = Device::new("fk-a");
    let mut home = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck)]);
    a.sync(&mut home, "loc", T0);
    a.apply(T0 + 10, vec![edit("deck", &deck, "name", json!("One"))]);
    a.sync(&mut home, "loc", T0 + 10);
    // 数据目录被拷走：两个安装用同一身份各写各的。
    let twin = Device::copy_of(&a, "fk-twin");
    let shared = a.core.sync2_status(P).unwrap()["nextSeq"].as_u64().unwrap() - 1;
    let mut other = home.clone();
    twin.apply(T0 + 20, vec![edit("deck", &deck, "name", json!("Twin"))]);
    twin.sync(&mut other, "loc", T0 + 20);
    a.apply(T0 + 30, vec![edit("deck", &deck, "name", json!("Mine"))]);
    let me = device_of(&a);
    let own_segs = other.0.keys().filter(|k| k.contains(&me) && k.contains("/seg-")).count();
    assert_eq!(own_segs, 3, "two shared segments + the twin's: {:?}", other.0.keys().collect::<Vec<_>>());

    let plan = a.core.sync2_plan_at(P, &heads(&other), Some("loc")).unwrap();
    assert_eq!(plan["fork"], json!(true), "{plan}");
    let own: Vec<String> = plan["fetch"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|f| f["own"] == json!(true))
        .flat_map(|f| f["files"].as_array().unwrap().iter().map(|x| x.as_str().unwrap().to_owned()))
        .collect();
    assert_eq!(own.len(), 2, "the last shared segment (tag-collision guard) + the twin's one, not all three: {own:?}");

    // 收到一半被打断：分叉点已经找到并记下。
    let files: Vec<Vec<u8>> = own.iter().map(|p| other.0[p].clone()).collect();
    a.core.sync2_ingest_begin(P).unwrap();
    a.core.sync2_ingest_prepare(P, files, None).unwrap();
    loop {
        let r: Value = serde_json::from_str(&a.core.sync2_ingest_commit(P, T0 + 40, CommitBudget::ops(1)).unwrap()).unwrap();
        if r["more"] != json!(true) {
            break;
        }
    }
    // 下一轮：不再拉本机身份的段，只要收个尾。
    let plan = a.core.sync2_plan_at(P, &heads(&other), Some("loc")).unwrap();
    assert_eq!(plan["fork"], json!(true), "{plan}");
    assert!(plan["fetch"].as_array().unwrap().iter().all(|f| f["own"] != json!(true)), "{plan}");
    assert_eq!(plan["finishPending"], json!(true), "{plan}");
    a.core.sync2_ingest_begin(P).unwrap();
    let r: Value = serde_json::from_str(&a.core.sync2_ingest_finish(P, T0 + 50).unwrap()).unwrap();
    assert_eq!(r["fork"], json!(true), "{r}");
    assert_ne!(device_of(&a), me, "rotated to a new identity");
    let frozen = a.rows(&format!("SELECT applied FROM sync2_devices WHERE profile_uid = srs_id('{P}') AND frozen = 1"));
    assert_eq!(frozen[1][0], shared.to_string(), "frozen at the copy point");
    assert_eq!(a.rows("SELECT COUNT(*) FROM srs_meta WHERE key LIKE 'sync2_fork_at/%'")[1][0], "0");
    let plan = a.core.sync2_plan_at(P, &heads(&other), Some("loc")).unwrap();
    assert_eq!(plan["finishPending"], json!(false), "{plan}");
}

/// S-8：head 都没变的空轮，`plan` 在读连接上就答完（不拿写锁）；有新设备 / 新 head 时只读路径交回写锁，写锁路径结果
/// 与只读路径一致。
#[test]
fn plan_answers_on_the_reader_when_nothing_needs_recording() {
    let a = Device::new("pl-a");
    let b = Device::new("pl-b");
    let mut bucket = Bucket::default();
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck)]);
    a.sync(&mut bucket, "loc", T0);
    b.core.sync2_identity(P, T0).unwrap();
    assert_eq!(b.core.sync2_plan_read_only(P, &heads(&bucket), Some("loc")).unwrap(), None, "a's device is new to b");
    b.sync(&mut bucket, "loc", T0 + 1);
    let ro = b.core.sync2_plan_read_only(P, &heads(&bucket), Some("loc")).unwrap();
    let rw = b.core.sync2_plan_at(P, &heads(&bucket), Some("loc")).unwrap();
    assert_eq!(ro, Some(rw.clone()), "nothing changed: the reader answers, same as the writer");
    assert_eq!(rw["fetch"], json!([]), "{rw}");
    // 写锁里有一笔没提交的事务时，只读路径照样答（读连接不等写连接）。
    let w = b.core.writer().unwrap();
    w.execute_batch("BEGIN IMMEDIATE").unwrap();
    let during = b.core.sync2_plan_read_only(P, &heads(&bucket), Some("loc")).unwrap();
    w.execute_batch("ROLLBACK").unwrap();
    drop(w);
    assert_eq!(during, Some(rw));
    // a 有了新 head：只读路径交回写锁。
    a.apply(T0 + 2, vec![edit("deck", &deck, "name", json!("X"))]);
    a.sync(&mut bucket, "loc", T0 + 2);
    assert_eq!(b.core.sync2_plan_read_only(P, &heads(&bucket), Some("loc")).unwrap(), None);
    let rw = b.core.sync2_plan_at(P, &heads(&bucket), Some("loc")).unwrap();
    assert_eq!(rw["fetch"].as_array().unwrap().len(), 1, "{rw}");
}
