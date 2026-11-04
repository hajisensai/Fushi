//! 投递队列按窗读缓冲表（transport.rs [Delivery]，反馈 6fSVptGebt / IUS9S0lWiZ / P8Kaf1_y0c 的原生 OOM）：
//! 等依赖的操作在 `sync2_pending` 里堆积时，收段会话在内存里只留每台设备 [DELIVERY_WINDOW] 条队列项，不再开会话就
//! 整表读进来；`pending` 计数与表一致；放行之后的投影与一次收完逐字节相同。

use serde_json::{json, Value};

use super::tests::{deck_entity, edit, projection, Bucket, Device, P};
use super::transport::{CommitBudget, DELIVERY_WINDOW};

const T0: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;

fn heads(b: &Bucket) -> Vec<Vec<u8>> {
    b.0.iter()
        .filter(|(k, _)| {
            k.rsplit('/')
                .next()
                .and_then(crate::sync2::segment::parse_head_file_name)
                .is_some()
        })
        .map(|(_, v)| v.clone())
        .collect()
}

fn segs_of(b: &Bucket, device: &str) -> Vec<Vec<u8>> {
    b.0.iter()
        .filter(|(k, _)| k.contains(device) && k.contains("/seg-"))
        .map(|(_, v)| v.clone())
        .collect()
}

fn device_text(d: &Device) -> String {
    let w = d.core.writer().unwrap();
    super::Local::load(&w, P).unwrap().unwrap().device.text()
}

fn pending_rows(d: &Device) -> i64 {
    d.rows("SELECT COUNT(*) FROM sync2_pending")[1][0]
        .parse()
        .unwrap()
}

fn resident(d: &Device) -> usize {
    d.core
        .ingest_phase()
        .unwrap()
        .session()
        .and_then(|s| s.delivery_resident())
        .unwrap_or(0)
}

/// A 写一批，B 收下 A 之后再写一批（B 的每条操作因果上都依赖 A 的）。
fn world(n: usize) -> (Bucket, String, String) {
    let a = Device::new("dw-a");
    let b = Device::new("dw-b");
    let deck = super::config::default_deck_id(P);
    let mut bucket = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck)]);
    for i in 0..n {
        a.apply(
            T0 + 1 + i as i64,
            vec![edit(
                "note",
                &format!("A{i}"),
                "f/s",
                json!(format!("a{i}")),
            )],
        );
    }
    a.sync(&mut bucket, "loc", T0 + DAY);
    b.sync(&mut bucket, "loc", T0 + DAY);
    for i in 0..n {
        b.apply(
            T0 + 2 * DAY + i as i64,
            vec![edit(
                "note",
                &format!("B{i}"),
                "f/s",
                json!(format!("b{i}")),
            )],
        );
    }
    b.sync(&mut bucket, "loc", T0 + 3 * DAY);
    let (a_dev, b_dev) = (device_text(&a), device_text(&b));
    (bucket, a_dev, b_dev)
}

fn commit_all(
    d: &Device,
    segments: Vec<Vec<u8>>,
    now: i64,
    slice: usize,
    max_resident: &mut usize,
) {
    d.core.sync2_ingest_prepare(P, segments, None).unwrap();
    loop {
        let r: Value = serde_json::from_str(
            &d.core
                .sync2_ingest_commit(P, now, CommitBudget::ops(slice))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            r["pending"],
            json!(pending_rows(d)),
            "pending is the buffer table's row count: {r}"
        );
        *max_resident = (*max_resident).max(resident(d));
        if r["more"] != json!(true) {
            break;
        }
    }
}

#[test]
fn backlog_waiting_on_a_missing_device_stays_out_of_memory() {
    let n = 40;
    let (bucket, a_dev, b_dev) = world(n);
    let now = T0 + 9 * DAY;

    // 新设备先只收到 B：B 的全部操作都等着 A，进缓冲表。
    let d = Device::new("dw-d");
    d.core.sync2_identity(P, now).unwrap();
    d.core.sync2_plan(P, &heads(&bucket)).unwrap();
    let mut max_resident = 0;
    d.core.sync2_ingest_begin(P).unwrap();
    for seg in segs_of(&bucket, &b_dev) {
        commit_all(&d, vec![seg], now, 5, &mut max_resident);
    }
    d.core.sync2_ingest_finish(P, now).unwrap();
    let backlog = pending_rows(&d);
    assert!(backlog >= n as i64, "B's ops wait on A: {backlog}");
    assert!(
        max_resident <= DELIVERY_WINDOW,
        "only one window of the backlog stays in memory: {max_resident} > {DELIVERY_WINDOW} (backlog {backlog})"
    );

    // 下一轮（新会话）：缓冲表不整张读进来；又一轮还是收不到 A 的段，队列照样只有一窗。
    let mut max_resident = 0;
    d.core.sync2_ingest_begin(P).unwrap();
    commit_all(&d, segs_of(&bucket, &b_dev), now, 4, &mut max_resident);
    d.core.sync2_ingest_finish(P, now).unwrap();
    assert_eq!(
        pending_rows(&d),
        backlog,
        "re-received B segments add nothing"
    );
    assert!(max_resident <= DELIVERY_WINDOW, "{max_resident}");

    // A 的段到了：积压按窗读回、全部投完，投影与一次收齐的设备逐字节相同。
    let mut max_resident = 0;
    d.core.sync2_ingest_begin(P).unwrap();
    for seg in segs_of(&bucket, &a_dev) {
        commit_all(&d, vec![seg], now, 7, &mut max_resident);
    }
    d.core.sync2_ingest_finish(P, now).unwrap();
    assert_eq!(pending_rows(&d), 0, "the backlog drained");
    assert!(max_resident <= 2 * DELIVERY_WINDOW, "{max_resident}");

    let reference = Device::new("dw-ref");
    reference.core.sync2_identity(P, now).unwrap();
    reference.core.sync2_plan(P, &heads(&bucket)).unwrap();
    let all: Vec<Vec<u8>> = bucket
        .0
        .iter()
        .filter(|(k, _)| k.contains("/seg-"))
        .map(|(_, v)| v.clone())
        .collect();
    let out: Value =
        serde_json::from_str(&reference.core.sync2_ingest(P, &all, None, now).unwrap()).unwrap();
    assert_eq!(out["pending"], json!(0), "{out}");
    assert_eq!(projection(&d), projection(&reference));
}

/// 一次收完（不分片）也走分窗：同一批里先 B 后 A，B 的操作先进缓冲（溢出写表、截窗），A 投完后按窗读回放行。
#[test]
fn one_shot_ingest_drains_a_windowed_backlog() {
    let (bucket, a_dev, b_dev) = world(25);
    let now = T0 + 9 * DAY;
    let d = Device::new("dw-one");
    d.core.sync2_identity(P, now).unwrap();
    d.core.sync2_plan(P, &heads(&bucket)).unwrap();
    let b: Vec<Vec<u8>> = segs_of(&bucket, &b_dev);
    let out: Value = serde_json::from_str(&d.core.sync2_ingest(P, &b, None, now).unwrap()).unwrap();
    assert_eq!(out["pending"], json!(pending_rows(&d)), "{out}");
    assert!(pending_rows(&d) >= 25);
    let a: Vec<Vec<u8>> = segs_of(&bucket, &a_dev);
    let out: Value = serde_json::from_str(&d.core.sync2_ingest(P, &a, None, now).unwrap()).unwrap();
    assert_eq!(out["pending"], json!(0), "{out}");
    assert_eq!(pending_rows(&d), 0);
}

/// 投影前只取 ID 的地方不再整份算 [super::edit_row]（不读旧闭包、不拼 ctx）：两者给出的 ID 必须相同（v2 写入与
/// 迁移进来的旧记录都是）。
#[test]
fn edit_row_id_matches_the_full_row() {
    use std::sync::Arc;

    use crate::sync2::hlc::Hlc;
    use crate::sync2::id::{Id, Key};
    use crate::sync2::op::{EditBody, EntKind, LegacyStamp, Op};
    use crate::sync2::vv::{OpId, Vv};

    let a = Device::new("dw-eid");
    let conn = a.core.writer().unwrap();
    let device = Id::random();
    let op = Op {
        id: OpId { device, seq: 7 },
        hlc: Hlc {
            wall: T0,
            logical: 0,
            device,
        },
        deps: Arc::new(Vv::default()),
        kind: crate::sync2::op::KIND_EDIT,
        schema: 1,
        payload: Arc::from(Vec::new()),
        purged: false,
    };
    let body = |legacy: Option<LegacyStamp>| EditBody {
        kind: EntKind::Note,
        entity: Key::of("N1"),
        key: "f/x".into(),
        value: "\"o\"".into(),
        machine: false,
        ts: 0,
        legacy,
    };
    let legacy = LegacyStamp {
        writer: "old".into(),
        seq: 3,
        ctx_json: r#"{"vv":{"old":2}}"#.into(),
        hlc: format!("{T0}:0:old"),
        server_time: None,
    };
    for e in [body(None), body(Some(legacy))] {
        let (id, row) = super::edit_row(&conn, P, &op, &e).unwrap();
        assert_eq!(super::edit_row_id(&op, &e), id);
        assert_eq!(row["id"], json!(id));
    }
}
