//! G8-7b 转发（`cmd/sync_relay.rs`）与收段让路（`ingest` 的 `maxItems`）的端到端测试，经 C ABI，位置是内存表
//! （装置在 `sync_tests.rs`）。
//!
//! - 拓扑不全连通：a 只连明文位置 L1、c 只连加密位置 L2、b 两个都连。b 把 a 的段转发到 L2（按 L2 的钥匙封装）、把 c 的
//!   转发到 L1，三台收敛，派生层增量 == 重建；转发完 b 不再留原文；被转发的 head 不当位置证据。
//! - 收段让路：一大批按 `maxItems` 切成多个事务，每个事务做的新工作不超过预算，最后与一次收完的结果相同；量一批的持锁时间。

use std::time::Instant;

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::dispatch_tests::T1;
use super::sync_relay::{
    LOC_KEYS_SQL, RELAY_GET_SQL, RELAY_HAS_SQL, RELAY_LIST_SQL, RHEAD_RANGE_SQL,
};
use super::sync_tests::{Dev, Loc, Opts, cmd, heads, listing, round, sync_all};
use super::tests::{N1, N2, N3, N4};
use crate::store::gen4::files::GEN4_FILE;
use crate::store::sync2::tests::{DAY, edit};

const KEY2: &str = "2222222222222222222222222222222222222222222222222222222222222222";

/// 跑一遍转发：要一批、写上、确认，直到没有；最后删掉待删的、报回去。回包：写上的文件路径（相对 `v4/`）。
pub(super) fn relay(
    d: &Dev,
    loc: &mut Loc,
    location: &str,
    key: Option<&str>,
    now: i64,
) -> Vec<String> {
    let mut written = Vec::new();
    let mut delete: Vec<Value> = Vec::new();
    for _ in 0..64 {
        let (v, files) = cmd(
            d.h,
            "relay_outbox",
            now,
            json!({"location": location, "key": key, "maxBytes": 1}),
            &[],
        );
        let paths = v["files"].as_array().unwrap().clone();
        assert_eq!(paths.len(), files.len(), "{v}");
        for (p, b) in files {
            written.push(p.clone());
            loc.insert(format!("v4/{p}"), b);
        }
        let (ack, _) = cmd(
            d.h,
            "relay_ack",
            now,
            json!({"location": location, "paths": paths}),
            &[],
        );
        delete = ack["delete"].as_array().unwrap().clone();
        if v["more"] != json!(true) {
            break;
        }
    }
    for p in &delete {
        loc.remove(&format!("v4/{}", p.as_str().unwrap()));
    }
    if !delete.is_empty() {
        cmd(
            d.h,
            "relay_ack",
            now,
            json!({"location": location, "deleted": delete}),
            &[],
        );
    }
    written
}

pub(super) fn relay_segs(d: &mut Dev) -> i64 {
    d.direct(|t, _| {
        t.conn()
            .query_row("SELECT COUNT(*) FROM relay_segs", [], |r| r.get(0))
            .map_err(|e| e.to_string())
    })
}

/// a 只连 L1（明文）、c 只连 L2（加密）、b 两个都连：b 转发之后三台都看得到彼此写的，派生层相同、增量 == 重建。
/// 转发件在 L2 上按 L2 的钥匙封装；被转发的 head 用 `rhd-` 前缀，不覆盖、不冒充作者自写的 head；全部转发完 b 不再留
/// 原文；再跑一遍转发什么都不写。
#[test]
fn a_device_on_two_locations_relays_between_them() {
    let a = Dev::new("g87ra");
    let mut b = Dev::new("g87rb");
    let c = Dev::new("g87rc");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    let sealed = Opts {
        key: Some(KEY2),
        ..Opts::default()
    };
    // b 先认识两个位置（只有同步着 ≥ 2 个位置才留原文）。
    round(&b, &mut l1, "L1", T1, plain);
    round(&b, &mut l2, "L2", T1, sealed);
    a.write(T1 + 1, N1, "鯨");
    c.write(T1 + 2, N2, "猫");
    round(&a, &mut l1, "L1", T1 + 3, plain);
    round(&c, &mut l2, "L2", T1 + 3, sealed);
    round(&b, &mut l1, "L1", T1 + 4, plain);
    round(&b, &mut l2, "L2", T1 + 4, sealed);
    // b 收下 a 的段之后库已非空，在 L2 第一次见到的 c 是待确认（`truth/trust.rs`）：只转发受信作者的段，用户确认之后
    // 下一轮为转发再拉一次 c 的段（`wanted_for_relay`）。
    let (v, _) = cmd(
        b.h,
        "trust",
        T1 + 4,
        json!({"device": c.device(), "trust": true}),
        &[],
    );
    assert_eq!(v["trusted"], json!(true), "{v}");
    b.write(T1 + 5, N3, "犬");
    round(&b, &mut l1, "L1", T1 + 6, plain);
    round(&b, &mut l2, "L2", T1 + 6, sealed);
    assert!(relay_segs(&mut b) >= 2);

    let to_l2 = relay(&b, &mut l2, "L2", Some(KEY2), T1 + 7);
    let to_l1 = relay(&b, &mut l1, "L1", None, T1 + 7);
    let (da, dc) = (a.device(), c.device());
    assert!(
        to_l2.iter().any(|p| p.contains(&da) && p.contains("/rly-"))
            && to_l2.iter().any(|p| p.contains(&da) && p.contains("/rhd-")),
        "{to_l2:?}"
    );
    assert!(
        to_l1.iter().any(|p| p.contains(&dc) && p.contains("/rly-"))
            && to_l1.iter().any(|p| p.contains(&dc) && p.contains("/rhd-")),
        "{to_l1:?}"
    );
    // L2 上的转发件按 L2 的钥匙封装（FRL4 的 flags bit0）。
    for p in to_l2.iter().filter(|p| p.contains("/rly-")) {
        let bytes = &l2[&format!("v4/{p}")];
        assert!(bytes.starts_with(b"FRL4") && bytes[5] & 1 == 1, "{p}");
    }
    // 被转发的 head 不出现在作者自写 head 的那一组里。
    assert!(heads(&l2).len() <= 2, "only b and c wrote heads at L2");

    for _ in 0..2 {
        round(&a, &mut l1, "L1", T1 + 8, plain);
        round(&c, &mut l2, "L2", T1 + 8, sealed);
    }
    for d in [&a, &b, &c] {
        assert_eq!(d.field(N1), Some(json!("鯨")), "{}", d.device());
        assert_eq!(d.field(N2), Some(json!("猫")), "{}", d.device());
        assert_eq!(d.field(N3), Some(json!("犬")), "{}", d.device());
    }
    let mut a = a;
    let mut c = c;
    let (ga, gb, gc) = (a.derived(), b.derived(), c.derived());
    assert_eq!(ga, gb);
    assert_eq!(gb, gc);
    // 每个位置都有了：b 不再留原文；再跑一遍转发什么都不写。
    assert_eq!(relay_segs(&mut b), 0);
    assert!(relay(&b, &mut l2, "L2", Some(KEY2), T1 + 9).is_empty());
    assert!(relay(&b, &mut l1, "L1", None, T1 + 9).is_empty());
    // L1 上的被转发 head 不是 L1 的证据。先让 c 再写一条、b 在 L2 收下（L1 缺，留原文），再让 b 在 L1 跑一轮——这一轮的
    // plan 读得到 L1 上 c 的 `rhd-`：b 不把 c 记成 L1 上的设备（c 的 loc_heads 只在 L2），也不因此把还没转发到 L1
    // 的原文 prune 掉。
    c.write(T1 + 10, N4, "鳥");
    round(&c, &mut l2, "L2", T1 + 10, sealed);
    round(&b, &mut l2, "L2", T1 + 11, sealed);
    assert_eq!(relay_segs(&mut b), 1);
    let r = round(&b, &mut l1, "L1", T1 + 12, plain);
    assert!(
        l1.keys().any(|k| k.contains(&dc) && k.contains("/rhd-")),
        "L1 carries c's relayed head: {}",
        r.plan
    );
    assert_eq!(relay_segs(&mut b), 1, "not relayed to L1 yet");
    let rows: Vec<String> = b.direct(|t, col| {
        Ok(t.loc_heads(col, "L1")?
            .into_iter()
            .map(|h| h.device.text())
            .collect())
    });
    assert!(!rows.contains(&dc), "{rows:?}");
}

/// b 在 L2 上的状态行（`loc_state`、`loc_heads`）数。
fn l2_rows(d: &Dev) -> (i64, i64) {
    let c = Connection::open_with_flags(
        d.dir.0.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    let n = |q: &str| -> i64 { c.query_row(q, ["L2"], |r| r.get(0)).unwrap() };
    (
        n("SELECT COUNT(*) FROM loc_state WHERE loc_key = ?1"),
        n("SELECT COUNT(*) FROM loc_heads WHERE loc_key = ?1"),
    )
}

/// 移除位置（G8-7c，`location_forget`）：b 同步着 L1、L2，为 L2 留着 a 的原文；移除 L2 之后它的状态行（加密记忆 / loc
/// 标记 / `last_ok`、head 记录）全没了，留给它的原文按剩下的一个位置全删，之后 a 再写、b 在 L1 收也不再留原文（不再
/// 向 L2 转发）；再移除一次照常回包。之后把 L2 加回来：b 在 L2 上的 head 代号接着往上（水位没清），收敛照旧。
#[test]
fn a_removed_location_is_forgotten_and_no_longer_relayed_to() {
    let a = Dev::new("g87fga");
    let mut b = Dev::new("g87fgb");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    let sealed = Opts {
        key: Some(KEY2),
        ..Opts::default()
    };
    round(&b, &mut l1, "L1", T1, plain);
    let before = round(&b, &mut l2, "L2", T1, sealed);
    let gen_before = before.head["gen"].as_u64().unwrap();
    a.write(T1 + 1, N1, "鯨");
    round(&a, &mut l1, "L1", T1 + 2, plain);
    round(&b, &mut l1, "L1", T1 + 3, plain);
    assert!(relay_segs(&mut b) >= 1, "b keeps a's segment for L2");
    let (st, hs) = l2_rows(&b);
    assert!(st == 1 && hs >= 1, "{st} {hs}");

    let (v, _) = cmd(
        b.h,
        "location_forget",
        T1 + 4,
        json!({"location": "L2"}),
        &[],
    );
    assert!(v["forgotten"].as_u64().unwrap() >= 2, "{v}");
    assert!(v["relayDropped"].as_u64().unwrap() >= 1, "{v}");
    assert_eq!(l2_rows(&b), (0, 0));
    assert_eq!(relay_segs(&mut b), 0);
    assert!(relay(&b, &mut l2, "L2", Some(KEY2), T1 + 4).is_empty());
    // 只剩一个位置：再收别的设备的段也不留原文。
    a.write(T1 + 5, N2, "猫");
    round(&a, &mut l1, "L1", T1 + 6, plain);
    round(&b, &mut l1, "L1", T1 + 7, plain);
    assert_eq!(b.field(N2), Some(json!("猫")));
    assert_eq!(relay_segs(&mut b), 0);
    // 幂等。
    let (v, _) = cmd(
        b.h,
        "location_forget",
        T1 + 8,
        json!({"location": "L2"}),
        &[],
    );
    assert_eq!(v, json!({"forgotten": 0, "relayDropped": 0}));
    // 加回来：head 代号接着往上，b 在 L2 上照常发布。
    let after = round(&b, &mut l2, "L2", T1 + 9, sealed);
    assert!(
        after.head["gen"].as_u64().unwrap() > gen_before,
        "{}",
        after.head
    );
    assert_eq!(after.head["unchanged"], json!(false));
}

/// a 的作者自己后来也连上了 L2：b 留着的 a 的原文被删掉（L2 上作者 head 已覆盖），转发件也不再给。
#[test]
fn an_author_reaching_the_location_itself_ends_the_relay() {
    let a = Dev::new("g87rx");
    let mut b = Dev::new("g87ry");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let o = Opts::default();
    round(&b, &mut l1, "L1", T1, o);
    round(&b, &mut l2, "L2", T1, o);
    a.write(T1 + 1, N1, "鯨");
    round(&a, &mut l1, "L1", T1 + 2, o);
    round(&b, &mut l1, "L1", T1 + 3, o);
    assert_eq!(relay_segs(&mut b), 1);
    round(&a, &mut l2, "L2", T1 + 4, o);
    round(&b, &mut l2, "L2", T1 + 5, o);
    assert_eq!(relay_segs(&mut b), 0);
    assert!(relay(&b, &mut l2, "L2", None, T1 + 6).is_empty());
}

/// 后来才连上第二个位置：b 先只连 L1、早就收了 a 的段（当时只有一个位置，不留原文）；之后连上 L2（c 在那里）。b 在
/// L1 的下一轮 `plan` 把 a 那些「本机早有、没留原文、L2 缺」的段再要一次（收段按已有跳过、只留原文），随后转发到 L2，
/// c 收齐 a 写的；转发完 b 不再留原文。
#[test]
fn a_second_location_added_later_still_gets_the_relay() {
    let a = Dev::new("g87la");
    let mut b = Dev::new("g87lb");
    let c = Dev::new("g87lc");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let o = Opts::default();
    a.write(T1 + 1, N1, "鯨");
    round(&a, &mut l1, "L1", T1 + 2, o);
    round(&b, &mut l1, "L1", T1 + 3, o);
    assert_eq!(b.field(N1), Some(json!("鯨")));
    assert_eq!(relay_segs(&mut b), 0, "one location: nothing kept");
    round(&b, &mut l2, "L2", T1 + 4, o);
    // 这一轮 L1 的 plan 为转发补拉 a 的段。
    let r = round(&b, &mut l1, "L1", T1 + 5, o);
    let da = a.device();
    assert!(
        r.plan["fetch"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["device"] == json!(da)),
        "{}",
        r.plan
    );
    assert_eq!(relay_segs(&mut b), 1);
    assert!(!relay(&b, &mut l2, "L2", None, T1 + 6).is_empty());
    for _ in 0..2 {
        round(&c, &mut l2, "L2", T1 + 7, o);
    }
    assert_eq!(c.field(N1), Some(json!("鯨")));
    // b 这一轮在 L2 收到 c 的段（L1 缺）会留原文；转发到 L1 之后两边都齐，原文一份不剩。
    round(&b, &mut l2, "L2", T1 + 8, o);
    relay(&b, &mut l1, "L1", None, T1 + 9);
    assert_eq!(relay_segs(&mut b), 0);
}

/// 转发目标只认活跃位置：迁移灌进来的、从没在新代成功过的位置行（`last_ok` 为空），和 30 天以上没成功过的旧位置，
/// 都不算目标——b 只在 L1 上同步时不为它们留原文，`plan` 也不为它们把早已收过的段再拉一遍。
#[test]
fn stale_or_never_synced_locations_are_not_relay_targets() {
    let a = Dev::new("g87sa");
    let mut b = Dev::new("g87sb");
    let mut l1 = Loc::new();
    let o = Opts::default();
    a.write(T1 + 1, N1, "鯨");
    round(&a, &mut l1, "L1", T1 + 2, o);
    round(&b, &mut l1, "L1", T1 + 3, o);
    assert_eq!(b.field(N1), Some(json!("鯨")));
    // 迁移留下的加密位置行（从没成功过）与一个 40 天前最后成功的位置。
    b.direct(|t, col| {
        t.conn()
            .execute(
                "INSERT INTO loc_state (col, loc_key, sealed, last_ok) VALUES (?1, 'Lcarried', 1, NULL),                  (?1, 'Lold', 0, ?2)",
                rusqlite::params![col, T1 - 40 * DAY],
            )
            .map_err(|e| e.to_string())
    });
    let r = round(&b, &mut l1, "L1", T1 + 4, o);
    let da = a.device();
    assert!(
        !r.plan["fetch"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["device"] == json!(da)),
        "nothing is fetched again for a dead location: {}",
        r.plan
    );
    assert_eq!(relay_segs(&mut b), 0);
    a.write(T1 + 5, N2, "猫");
    round(&a, &mut l1, "L1", T1 + 6, o);
    round(&b, &mut l1, "L1", T1 + 7, o);
    assert_eq!(b.field(N2), Some(json!("猫")));
    assert_eq!(relay_segs(&mut b), 0, "no relay copy for inactive targets");
}

/// 一个位置 30 天以上没成功过之后不再是转发目标：先前为它留的原文在下一轮 `plan` 里被 prune 清空，之后收的段也不再留。
#[test]
fn a_location_left_idle_past_the_window_stops_holding_relay_copies() {
    let a = Dev::new("g87wa");
    let mut b = Dev::new("g87wb");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let o = Opts::default();
    round(&b, &mut l1, "L1", T1, o);
    round(&b, &mut l2, "L2", T1, o);
    a.write(T1 + 1, N1, "鯨");
    round(&a, &mut l1, "L1", T1 + 2, o);
    round(&b, &mut l1, "L1", T1 + 3, o);
    assert_eq!(relay_segs(&mut b), 1, "L2 lacks a's segment");
    let late = T1 + 31 * DAY;
    // 第一轮写完 head 时 L1 的 last_ok 前进，L2 落出窗口；下一轮的 plan 就把留给 L2 的原文清掉。
    round(&b, &mut l1, "L1", late, o);
    round(&b, &mut l1, "L1", late + 1, o);
    assert_eq!(relay_segs(&mut b), 0);
    a.write(late + 2, N2, "猫");
    round(&a, &mut l1, "L1", late + 3, o);
    round(&b, &mut l1, "L1", late + 4, o);
    assert_eq!(b.field(N2), Some(json!("猫")));
    assert_eq!(relay_segs(&mut b), 0);
    assert!(relay(&b, &mut l2, "L2", None, late + 5).is_empty());
}

/// 只连一个位置的设备不留原文、不转发。
#[test]
fn a_single_location_device_keeps_nothing_to_relay() {
    let a = Dev::new("g87r1");
    let mut b = Dev::new("g87r2");
    let mut l1 = Loc::new();
    a.write(T1 + 1, N1, "鯨");
    for d in [&a, &b] {
        round(d, &mut l1, "L1", T1 + 2, Opts::default());
    }
    round(&b, &mut l1, "L1", T1 + 3, Opts::default());
    assert_eq!(b.field(N1), Some(json!("鯨")));
    assert_eq!(relay_segs(&mut b), 0);
    assert!(relay(&b, &mut l1, "L1", None, T1 + 4).is_empty());
}

/// 本机等待缓冲里的项数（`op_wait` 与承袭的 `op_pending`）。直接读库（只读连接），不经命令：经一条不限预算的
/// `ingest` 读回包会顺手把还接得上的残留等待项投完，断言就测不出「切片收段漏投」了。
fn v_pending(d: &Dev) -> i64 {
    let c = Connection::open_with_flags(
        d.dir.0.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    c.query_row(
        "SELECT (SELECT COUNT(*) FROM op_wait) + (SELECT COUNT(*) FROM op_pending)",
        [],
        |r| r.get(0),
    )
    .unwrap()
}

fn note_id(i: usize) -> String {
    format!("0193a1b2-0000-7000-8000-{:012x}", 0x1000 + i)
}

/// 一台设备写 [n] 条（一次 `apply`）。
fn write_many(d: &Dev, now: i64, n: usize) {
    write_many_as(d, now, n, "v");
}

/// 一台设备写 [n] 条，第 i 条的值是 `{prefix}{i}`（一次 `apply`）。
fn write_many_as(d: &Dev, now: i64, n: usize, prefix: &str) {
    let items: Vec<Value> = (0..n)
        .map(|i| {
            let note = note_id(i);
            json!({"e": edit("note", &note, "f/fa", json!(format!("{prefix}{i}"))), "note": note})
        })
        .collect();
    let blob = Value::Array(items).to_string().into_bytes();
    let (v, _) = cmd(d.h, "apply", now, json!({}), &[blob]);
    assert_eq!(v["landed"].as_array().unwrap().len(), n, "{v}");
}

/// 收段让路：b 收 a 的一大批时带 `maxItems`，内核每个事务做的新工作不超过预算、中途停下的段下一个事务原样再交；最后
/// 派生层增量 == 重建，三台互相同步后与一次收完的 c 语义摘要相同。同时量一下每个事务的持锁时间（打印，不设阈值）。
#[test]
fn ingest_slices_a_large_batch_into_budgeted_transactions() {
    const N: usize = 1500;
    const BUDGET: u64 = 200;
    let a = Dev::new("g87ya");
    let mut b = Dev::new("g87yb");
    let mut c = Dev::new("g87yc");
    write_many(&a, T1 + 1, N);
    let mut loc = Loc::new();
    round(&a, &mut loc, "loc", T1 + 2, Opts::default());
    // c：一次收完（对照组）。
    round(&c, &mut loc, "loc", T1 + 3, Opts::default());
    // b：手动按 plan 拉，再按预算切事务交。
    let root = {
        let mut blobs = Vec::new();
        blobs.extend(loc.get("v4/meta.json").cloned());
        blobs.extend(loc.get("v3/meta.json").cloned());
        let locs: Vec<String> = loc
            .keys()
            .filter_map(|k| k.strip_prefix("v4/loc/").map(str::to_owned))
            .collect();
        cmd(
            b.h,
            "location_root",
            T1 + 4,
            json!({"location": "loc", "has4": true, "has3": loc.contains_key("v3/meta.json"), "locs": locs}),
            &blobs,
        )
        .0
    };
    let (plan, _) = cmd(
        b.h,
        "plan",
        T1 + 4,
        json!({"location": "loc", "loc": root["loc"], "listing": listing(&loc)}),
        &heads(&loc),
    );
    let mut pending: Vec<Vec<u8>> = plan["fetch"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|f| f["files"].as_array().unwrap().clone())
        .filter_map(|p| loc.get(&format!("v4/{}", p.as_str().unwrap())).cloned())
        .collect();
    assert!(!pending.is_empty());
    let mut txs = 0;
    let mut slowest = std::time::Duration::ZERO;
    while !pending.is_empty() {
        let t0 = Instant::now();
        let (v, _) = cmd(b.h, "ingest", T1 + 5, json!({"maxItems": BUDGET}), &pending);
        let dt = t0.elapsed();
        slowest = slowest.max(dt);
        txs += 1;
        let landed = v["landed"].as_u64().unwrap() + v["delivered"].as_u64().unwrap();
        assert!(landed <= BUDGET, "{v}");
        let rest = v["rest"].as_u64().unwrap() as usize;
        pending.drain(..rest);
        assert!(txs < 100, "no progress: {v}");
    }
    eprintln!(
        "ingest slices: {N} ops in {txs} transactions of <= {BUDGET} items, slowest {slowest:?}"
    );
    assert!(txs as u64 >= N as u64 / BUDGET, "{txs}");
    for i in [0, N / 2, N - 1] {
        assert_eq!(b.field(&note_id(i)), Some(json!(format!("v{i}"))));
    }
    // 增量 == 重建（切片收的派生层与整个重建逐行相同）；三台互相同步之后语义摘要相同（各自的身份操作要先互相到达）。
    sync_all(&[&a, &b, &c], &mut loc, T1 + 6, Opts::default());
    let mut a = a;
    assert_eq!(b.derived(), c.derived());
    assert_eq!(a.derived(), c.derived());
}

/// 照搬 Dart `SrsDbStore.sync2IngestBatch` 的循环收一批：每片带 `maxItems`，交完的段从队首去掉；段都交完了但回包
/// `drainMore`（收尾投等待缓冲时预算用完）就不带段再收一次；`rest == 0 && spent == 0` 判契约坏了。每片的新工作
/// （`spent`、落库 + 投出）不超过预算。回包：(事务数, 只停放没落库的片数, 不带段的投递片数)。
fn ingest_like_dart(d: &Dev, mut pending: Vec<Vec<u8>>, budget: u64, now: i64) -> (u32, u32, u32) {
    let (mut txs, mut parked_only, mut drains) = (0u32, 0u32, 0u32);
    loop {
        let (v, _) = cmd(d.h, "ingest", now, json!({"maxItems": budget}), &pending);
        txs += 1;
        assert!(txs < 200, "{v}");
        let done = v["rest"].as_u64().unwrap() as usize;
        let spent = v["spent"].as_u64().unwrap();
        let work = v["landed"].as_u64().unwrap() + v["delivered"].as_u64().unwrap();
        assert!(spent <= budget && work <= budget, "{v}");
        if pending.is_empty() {
            drains += 1;
        }
        if done >= pending.len() {
            assert_eq!(v["requeue"], json!([]), "{v}");
            if v["drainMore"] == json!(true) {
                assert!(spent > 0, "a drain slice must deliver something: {v}");
                pending.clear();
                continue;
            }
            return (txs, parked_only, drains);
        }
        // Dart 的判据：交完的段数与新工作数都是 0 才算没进展。
        assert!(!(done == 0 && spent == 0), "no progress: {v}");
        if done == 0 && v["landed"] == json!(0) {
            parked_only += 1;
        }
        // 交回的（等同一批里 Purge 的重切件）接在剩下的后面。
        let back: Vec<Vec<u8>> = v["requeue"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| pending[i.as_u64().unwrap() as usize].clone())
            .collect();
        pending.drain(..done);
        pending.extend(back);
    }
}

/// c 认位置、读 head，回各设备要拉的段（按 `plan` 的 fetch，设备 → 段的字节）。
fn fetch_of(c: &Dev, loc: &Loc, now: i64) -> Vec<(String, Vec<Vec<u8>>)> {
    let mut blobs = Vec::new();
    blobs.extend(loc.get("v4/meta.json").cloned());
    let locs: Vec<String> = loc
        .keys()
        .filter_map(|k| k.strip_prefix("v4/loc/").map(str::to_owned))
        .collect();
    let (root, _) = cmd(
        c.h,
        "location_root",
        now,
        json!({"location": "loc", "has4": true, "has3": false, "locs": locs}),
        &blobs,
    );
    let (plan, _) = cmd(
        c.h,
        "plan",
        now,
        json!({"location": "loc", "loc": root["loc"], "listing": listing(loc)}),
        &heads(loc),
    );
    plan["fetch"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| {
            let files = f["files"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|p| loc.get(&format!("v4/{}", p.as_str().unwrap())).cloned())
                .collect();
            (f["device"].as_str().unwrap().to_owned(), files)
        })
        .collect()
}

/// 收段让路的进展判据：依赖方的段排在被依赖方前面时，前几片全停进等待缓冲、一项都不落库（`landed == 0`、`rest == 0`），
/// 这也是进展。a 写 300 条、b 收下后改这 300 条（b 的操作依赖 a 的），c 收段时把 b 的段排在前面、预算很小；循环照搬
/// Dart `sync2IngestBatch` 的判据（`rest == 0 && spent == 0` 才算没进展），必须一路收完、不报没进展，最后与 b 收敛。
#[test]
fn ingest_slices_count_parked_items_as_progress() {
    const N: usize = 300;
    const BUDGET: u64 = 100;
    let a = Dev::new("g87pa");
    let mut b = Dev::new("g87pb");
    let mut c = Dev::new("g87pc");
    let mut loc = Loc::new();
    write_many(&a, T1 + 1, N);
    round(&a, &mut loc, "loc", T1 + 2, Opts::default());
    round(&b, &mut loc, "loc", T1 + 3, Opts::default());
    write_many_as(&b, T1 + 4, N, "b");
    round(&b, &mut loc, "loc", T1 + 5, Opts::default());
    let db = b.device();
    let mut fetch = fetch_of(&c, &loc, T1 + 6);
    // 依赖方（b）排在前面。
    fetch.sort_by_key(|(d, _)| *d != db);
    assert_eq!(fetch[0].0, db);
    let pending: Vec<Vec<u8>> = fetch.into_iter().flat_map(|(_, f)| f).collect();
    let (_, parked_only, _) = ingest_like_dart(&c, pending, BUDGET, T1 + 7);
    assert!(
        parked_only >= 1,
        "the dependent-first order must produce parked-only slices"
    );
    // b 的 300 条全部从等待缓冲投出（测试装置的编辑不带因果上下文，与 a 的同字段编辑按并发取舍，所以比的是与 b 一致）。
    assert_eq!(v_pending(&c), 0);
    for i in [0, N / 2, N - 1] {
        assert!(c.field(&note_id(i)).is_some());
        assert_eq!(c.field(&note_id(i)), b.field(&note_id(i)));
    }
    sync_all(&[&a, &b, &c], &mut loc, T1 + 8, Opts::default());
    assert_eq!(b.derived(), c.derived());
}

/// 收尾投递等待缓冲也按预算切：c 先把 b 的段整段收进等待缓冲（b 的 300 条都依赖 a），再按预算收 a 的段；a 的段收完
/// 那一片投不完 b 的 300 条，回包 `drainMore`，之后不带段的几片接着投，每片投出的不超过预算。最后不剩等待项、与 b
/// 收敛、增量 == 重建。
#[test]
fn ingest_drain_of_the_waiting_buffer_is_sliced_too() {
    const N: usize = 300;
    const BUDGET: u64 = 64;
    let a = Dev::new("g87da");
    let mut b = Dev::new("g87db");
    let mut c = Dev::new("g87dc");
    let mut loc = Loc::new();
    write_many(&a, T1 + 1, N);
    round(&a, &mut loc, "loc", T1 + 2, Opts::default());
    round(&b, &mut loc, "loc", T1 + 3, Opts::default());
    write_many_as(&b, T1 + 4, N, "b");
    round(&b, &mut loc, "loc", T1 + 5, Opts::default());
    let db = b.device();
    let fetch = fetch_of(&c, &loc, T1 + 6);
    let (of_b, others): (Vec<_>, Vec<_>) = fetch.into_iter().partition(|(d, _)| *d == db);
    // b 的段一次收完（不限预算）：依赖 a 的 300 条全部停进等待缓冲（b 在收 a 之前写的身份操作直接落）。
    let (v, _) = cmd(c.h, "ingest", T1 + 7, json!({}), &of_b[0].1);
    assert!(v["waiting"].as_u64().unwrap() >= N as u64, "{v}");
    let pending: Vec<Vec<u8>> = others.into_iter().flat_map(|(_, f)| f).collect();
    let (_, _, drains) = ingest_like_dart(&c, pending, BUDGET, T1 + 8);
    assert!(
        drains >= (N as u64 / BUDGET) as u32 - 1,
        "the waiting buffer is drained in budgeted slices: {drains}"
    );
    assert_eq!(v_pending(&c), 0);
    for i in [0, N / 2, N - 1] {
        assert_eq!(c.field(&note_id(i)), b.field(&note_id(i)));
    }
    sync_all(&[&a, &b, &c], &mut loc, T1 + 9, Opts::default());
    assert_eq!(b.derived(), c.derived());
}

/// 等待缓冲里停着 b 的 [n] 条（都依赖 a 的），a 的段已经交完、只剩不带段的投递片时，量前 [slices] 个投递片（预算
/// [budget]）各自实际执行的语句（虚拟机步数、全表扫描步数，按语句原文汇总；`browse_tests.rs` 的 [profile]）。
/// 回包：每片的 (投出项数, 语句 → (步数, 全表扫描步数))。
fn drain_cost(
    tag: &str,
    n: usize,
    budget: u64,
    slices: usize,
) -> Vec<(u64, std::collections::BTreeMap<String, (i64, i64)>)> {
    use super::browse_tests::profile;
    use crate::store::sync2::tests::P;
    let a = Dev::new(&format!("{tag}a"));
    let b = Dev::new(&format!("{tag}b"));
    let mut c = Dev::new(&format!("{tag}c"));
    let mut loc = Loc::new();
    write_many(&a, T1 + 1, n);
    round(&a, &mut loc, "loc", T1 + 2, Opts::default());
    round(&b, &mut loc, "loc", T1 + 3, Opts::default());
    write_many_as(&b, T1 + 4, n, "b");
    round(&b, &mut loc, "loc", T1 + 5, Opts::default());
    let db = b.device();
    let (of_b, others): (Vec<_>, Vec<_>) = fetch_of(&c, &loc, T1 + 6)
        .into_iter()
        .partition(|(d, _)| *d == db);
    let (v, _) = cmd(c.h, "ingest", T1 + 7, json!({}), &of_b[0].1);
    assert!(v["waiting"].as_u64().unwrap() >= n as u64, "{v}");
    // a 的段按预算交完（交完的那一片收尾已经开始投 b 的）。
    let mut pending: Vec<Vec<u8>> = others.into_iter().flat_map(|(_, f)| f).collect();
    while !pending.is_empty() {
        let (v, _) = cmd(c.h, "ingest", T1 + 8, json!({"maxItems": budget}), &pending);
        let done = v["rest"].as_u64().unwrap() as usize;
        assert!(done > 0 || v["spent"].as_u64().unwrap() > 0, "{v}");
        pending.drain(..done);
    }
    let mut out = Vec::new();
    for _ in 0..slices {
        let (delivered, ran) = c.direct(|t, col| {
            let mut reply = Value::Null;
            let ran = profile(t, || {
                reply = super::sync::ingest(t, col, P, &json!({"maxItems": budget}), &[], None)
                    .unwrap();
            });
            assert_eq!(reply["drainMore"], json!(true), "{reply}");
            Ok((reply["delivered"].as_u64().unwrap(), ran))
        });
        let mut by_sql: std::collections::BTreeMap<String, (i64, i64)> = Default::default();
        for r in ran {
            let e = by_sql.entry(r.sql).or_default();
            e.0 += r.steps;
            e.1 += r.fullscan;
        }
        out.push((delivered, by_sql));
    }
    out
}

/// 收尾投递等待缓冲按片做时，每片的读取量只跟这一片投出的项数走，不随缓冲里还排着的项数变大（G8-7b 遗留：以前
/// 每片都在写事务里把整张 `op_wait` 连操作正文扫一遍、再把整个缓冲解一遍数个数，等 8000 项时合计 2.3 s、近似平方）。
/// 停着 300 条与 1200 条时，前两个投递片各自的语句与步数：投递读的语句（[WAIT_RANGE_SQL] / [WAIT_OP_SQL]）步数相同量级、
/// 不读整张表；整片没有一步全表扫描。计数（[WAIT_COUNT_SQL] / `PENDING_COUNT_SQL`）是主键区间上的计数，随缓冲线性，
/// 但不读正文、不解码，单独核它走索引（`wait_lookups_use_their_keys`）。
#[test]
fn draining_a_large_waiting_buffer_reads_only_what_it_delivers() {
    use crate::store::gen4::sync_state::{WAIT_COUNT_SQL, WAIT_OP_SQL, WAIT_RANGE_SQL};
    use crate::store::gen4::truth::PENDING_COUNT_SQL;
    const BUDGET: u64 = 64;
    let small = drain_cost("g87ws", 300, BUDGET, 2);
    let large = drain_cost("g87wl", 1200, BUDGET, 2);
    let is_count = |q: &str| q == WAIT_COUNT_SQL || q == PENDING_COUNT_SQL;
    for (s, l) in small.iter().zip(&large) {
        assert_eq!(s.0, BUDGET, "a full drain slice");
        assert_eq!(l.0, BUDGET, "a full drain slice");
        for (q, cost) in s.1.iter().chain(&l.1) {
            assert_eq!(cost.1, 0, "no full scans in a drain slice: {q}");
        }
        let work = |m: &std::collections::BTreeMap<String, (i64, i64)>| -> i64 {
            m.iter()
                .filter(|(q, _)| !is_count(q))
                .map(|(_, c)| c.0)
                .sum()
        };
        let read = |m: &std::collections::BTreeMap<String, (i64, i64)>| -> i64 {
            [WAIT_RANGE_SQL, WAIT_OP_SQL]
                .iter()
                .map(|q| m.get(*q).map_or(0, |c| c.0))
                .sum()
        };
        let (rs, rl) = (read(&s.1), read(&l.1));
        assert!(rs > 0 && rl > 0, "the drain reads the waiting buffer");
        assert!(
            rl * 10 <= rs * 13,
            "waiting-buffer reads grow with the buffer: {rs} steps at 300, {rl} at 1200"
        );
        let (ws, wl) = (work(&s.1), work(&l.1));
        eprintln!("drain slice: {ws} steps at 300 waiting, {wl} at 1200");
        assert!(
            wl * 10 <= ws * 13,
            "a drain slice's work grows with the buffer: {ws} steps at 300, {wl} at 1200"
        );
    }
}

/// 收尾投递与计数的语句按键找：等待缓冲的区间读 / 点查 / 计数、承袭待投递的计数都是主键上的 SEARCH。
#[test]
fn wait_lookups_use_their_keys() {
    use crate::store::gen4::sync_state::{WAIT_COUNT_SQL, WAIT_OP_SQL, WAIT_RANGE_SQL};
    use crate::store::gen4::truth::PENDING_COUNT_SQL;
    let a = Dev::new("g87wq");
    let c = Connection::open_with_flags(
        a.dir.0.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    for (q, n) in [
        (WAIT_RANGE_SQL, 2),
        (WAIT_OP_SQL, 3),
        (WAIT_COUNT_SQL, 2),
        (PENDING_COUNT_SQL, 2),
    ] {
        let params: Vec<i64> = (0..n).map(|i| i + 1).collect();
        let plan: Vec<String> = c
            .prepare(&format!("EXPLAIN QUERY PLAN {q}"))
            .unwrap()
            .query_map(rusqlite::params_from_iter(params), |r| {
                r.get::<_, String>(3)
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(
            plan.iter().all(|p| p.starts_with("SEARCH"))
                && !plan.iter().any(|p| p.contains("TEMP")),
            "{q}: {plan:?}"
        );
    }
}

/// 转发的新语句按键找，不扫表。
#[test]
fn relay_lookups_use_their_keys() {
    let a = Dev::new("g87rq");
    let c = Connection::open_with_flags(
        a.dir.0.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    for (q, n) in [
        (LOC_KEYS_SQL, 1),
        (RELAY_GET_SQL, 5),
        (RELAY_HAS_SQL, 5),
        (crate::store::gen4::sync_state::RELAY_OUT_OF_SQL, 3),
        (RELAY_LIST_SQL, 2),
        (RHEAD_RANGE_SQL, 2),
        (super::sync::RELAY_AUTHORS_SQL, 1),
        (super::sync::LOC_STATE_DROP_SQL, 2),
    ] {
        let params: Vec<i64> = (0..n).map(|i| i + 1).collect();
        let plan: Vec<String> = c
            .prepare(&format!("EXPLAIN QUERY PLAN {q}"))
            .unwrap()
            .query_map(rusqlite::params_from_iter(params), |r| {
                r.get::<_, String>(3)
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(
            plan.iter().all(|p| p.starts_with("SEARCH")),
            "{q}: {plan:?}"
        );
    }
}

// ---------------------------------------------------------------------- 并入之后的同步

/// 并入（`collection_join`）之后经位置同步：b 绑在集合 Y（盐 `uidB`）上写 N2；a 在自己的集合里写 N1，然后并入 Y。
/// 两台经 Y 的位置同步之后都看得到 N1、N2；两份盐派生的默认牌组 ID 在两台上归一到同一个规范 ID（别名类按类回答）；
/// 语义摘要相同、派生层增量 == 重建。
#[test]
fn devices_converge_after_a_join() {
    use super::dispatch_tests::{cfg, g4, open};
    use crate::gen4::op::tests::id;
    use crate::store::sync2::config::default_deck_id;
    use crate::store::sync2::tests::{P, tempdir};
    let mut a = Dev::new("g87ja");
    let mut b = {
        let dir = tempdir::new("g87jb");
        let h = open(&dir.0, 0).unwrap();
        let v = g4(
            h,
            "collection_adopt",
            T1,
            json!({"collection": id(0x0a).text(), "dir": "0000-home", "salts": ["uidB"], "confirmed": true}),
        );
        assert_eq!(v["outcome"], json!("bound"), "{v}");
        g4(h, "cache_config_set", T1, json!({"caches": cfg()}));
        Dev { dir, h }
    };
    a.write(T1 + 1, N1, "鯨");
    b.write(T1 + 2, N2, "猫");
    let j = g4(
        a.h,
        "collection_join",
        T1 + 3,
        json!({"into": id(0x0a).text(), "dir": "0000-home"}),
    );
    assert_eq!(j["outcome"], json!("joined"), "{j}");
    let mut loc = Loc::new();
    sync_all(&[&b, &a], &mut loc, T1 + 4, Opts::default());
    for d in [&a, &b] {
        assert_eq!(d.field(N1), Some(json!("鯨")), "{}", d.device());
        assert_eq!(d.field(N2), Some(json!("猫")), "{}", d.device());
    }
    let ids = json!({"ids": [default_deck_id(P), default_deck_id("uidB")]});
    let ca = g4(a.h, "canonical_ids", T1, ids.clone());
    let cb = g4(b.h, "canonical_ids", T1, ids);
    assert_eq!(ca, cb);
    assert_eq!(a.derived(), b.derived());
}

// ---------------------------------------------------------------------- 围栏中途

/// 围栏中途：a 在一个协议 3 的存量位置上立新根时只写成了新根（`v4/`），旧根 meta 还没改写成围栏就断了。下一台设备
/// b 进来：仍认它是存量集合（媒体根 `v3`、不立墓碑 head），把围栏补上；围栏立好之后不再改写；两台照常收敛。
#[test]
fn a_fence_interrupted_midway_is_completed_by_the_next_device() {
    use crate::store::sync2::collection_of;
    use crate::store::sync2::tests::P;
    let a = Dev::new("g87fa");
    let b = Dev::new("g87fb");
    let mut loc = Loc::new();
    let v3 = json!({"collection": collection_of(P).text(), "v": 3, "minReader": 3})
        .to_string()
        .into_bytes();
    loc.insert("v3/meta.json".into(), v3.clone());
    let root = |d: &Dev, loc: &Loc| -> (Value, Vec<(String, Vec<u8>)>) {
        let mut blobs = Vec::new();
        blobs.extend(loc.get("v4/meta.json").cloned());
        blobs.extend(loc.get("v3/meta.json").cloned());
        let locs: Vec<String> = loc
            .keys()
            .filter_map(|k| k.strip_prefix("v4/loc/").map(str::to_owned))
            .collect();
        cmd(
            d.h,
            "location_root",
            T1,
            json!({"location": "loc", "has4": loc.contains_key("v4/meta.json"),
                "has3": loc.contains_key("v3/meta.json"), "locs": locs}),
            &blobs,
        )
    };
    let (r, files) = root(&a, &loc);
    assert_eq!(r["state"], json!("ok"), "{r}");
    assert_eq!(r["media"], json!("v3"));
    // 只写成新根那一半（先新根、后围栏的顺序在 v3 之前断了）。
    for (p, bytes) in files {
        if p.starts_with("v4/") {
            loc.insert(p, bytes);
        }
    }
    assert_eq!(loc["v3/meta.json"], v3, "the fence was not written yet");
    let (r, files) = root(&b, &loc);
    assert_eq!(r["state"], json!("ok"), "{r}");
    assert_eq!(r["media"], json!("v3"), "still an existing collection");
    assert_eq!(
        r["ensure"],
        json!([]),
        "no tombstone head for an existing collection"
    );
    let fence = files
        .iter()
        .find(|(p, _)| p == "v3/meta.json")
        .expect("b completes the fence")
        .1
        .clone();
    let fv: Value = serde_json::from_slice(&fence).unwrap();
    assert_eq!(fv["minReader"], json!(4), "{fv}");
    for (p, bytes) in files {
        loc.insert(p, bytes);
    }
    // 围栏立好之后再来：不再改写旧根 meta。
    let (_, again) = root(&a, &loc);
    assert!(!again.iter().any(|(p, _)| p == "v3/meta.json"), "{again:?}");
    a.write(T1 + 1, N1, "鯨");
    b.write(T1 + 2, N2, "猫");
    sync_all(&[&a, &b], &mut loc, T1 + 3, Opts::default());
    for d in [&a, &b] {
        assert_eq!(d.field(N1), Some(json!("鯨")));
        assert_eq!(d.field(N2), Some(json!("猫")));
    }
}

/// 第六波：重切材料（`relay_auth` / `relay_stubs`）的回收判据与规模（`cmd/sync_relay.rs` 文件头「重切材料的回收」）。
mod reclaim {
    use std::collections::BTreeMap;
    use std::time::Instant;

    use super::super::sync_relay::{note_head, prune, reclaim_material};
    use crate::gen4::head::Head4;
    use crate::gen4::op::Op4;
    use crate::gen4::op::tests::id;
    use crate::gen4::recut::Stub;
    use crate::gen4::segment::NativeHeader;
    use crate::gen4::{MIN_READER, PROTOCOL};
    use crate::store::gen4::native::tests::ready;
    use crate::store::gen4::schema::open_in_memory;
    use crate::store::gen4::sync_state::AuthorVersion;
    use crate::store::gen4::truth::Truth;
    use crate::sync2::id::Id;
    use crate::sync2::keys::DeviceKey;
    use crate::sync2::vv::{OpId, Vv};

    const A: u8 = 0x31;

    fn author() -> Id {
        id(A)
    }

    /// 作者 a 的一份 head，清单 = [segs]（回收只看清单）。
    fn head(gen: u64, segs: &[(u64, u64)]) -> Head4 {
        Head4 {
            gen,
            protocol: PROTOCOL,
            min_reader: MIN_READER,
            collection: id(0xc0),
            device: author(),
            public: DeviceKey::from_seed(&[A; 32]).public(),
            seq: segs.last().map_or(0, |s| s.1),
            chain: [0; 32],
            segs: segs
                .iter()
                .map(|(a, b)| (*a, *b, format!("{a:08x}")))
                .collect(),
            ack: Vv::new(),
            digest: "0:0".into(),
            at_ms: 1_800_000_000_000,
            name: "a".into(),
            loc: "loc-1".into(),
            seal: String::new(),
            derive: 1,
            prev: None,
            ext: None,
            extra: BTreeMap::new(),
        }
    }

    /// 作者签名版本：区间 [first, last]、作者签的空洞 [voids]（签名不验，存取不看）。
    fn version(first: u64, last: u64, voids: &[(u64, u64)]) -> AuthorVersion {
        AuthorVersion {
            header: NativeHeader {
                encrypted: false,
                collection: id(0xc0),
                device: author(),
                first,
                last,
                prev_chain: [0; 32],
                last_chain: [first as u8; 32],
            },
            sig: [1; 64],
            voids: voids.iter().map(|(s, c)| (*s, *c, [2; 32])).collect(),
        }
    }

    fn stub(seq: u64) -> Stub {
        let base = crate::gen4::segment::tests::ops()[0].clone();
        let op = Op4 {
            id: OpId {
                device: author(),
                seq,
            },
            ..base
        };
        Stub::of(
            &op,
            OpId {
                device: id(0x22),
                seq: 7,
            },
        )
    }

    fn ranges(t: &Truth<'_>, col: i64) -> Vec<(u64, u64)> {
        t.author_versions_of(col, &author())
            .unwrap()
            .iter()
            .map(|v| (v.header.first, v.header.last))
            .collect()
    }

    fn stub_seqs(t: &Truth<'_>, col: i64) -> Vec<u64> {
        t.stubs_of(col, &author())
            .unwrap()
            .iter()
            .map(|s| s.id().seq)
            .collect()
    }

    fn put_relay_row(t: &Truth<'_>, col: i64, first: u64, last: u64) {
        t.tx(|t| {
            t.conn()
                .execute(
                    "INSERT INTO relay_segs (col, device, first, last, tag, piece) VALUES (?1, ?2, ?3, ?4, 'x', x'00')",
                    rusqlite::params![col, &author().0[..], first as i64, last as i64],
                )
                .map_err(|e| e.to_string())
        })
        .unwrap();
    }

    /// 判据：没记过 head 全留；记下的最新 head 列着的区间、转发缓存里还有件的区间留；其余（作者重切 / 合并掉的旧区间）
    /// 删。剔除记录跟着还需要的区间走：落在某个还需要的区间里就留，只有那个区间本机有作者签名版本、而 seq 在它作者
    /// 签的空洞里才不算；还需要却还没有版本的区间（作者刚合并）整段留。换上更新的 head（`note_head`）就回收。
    #[test]
    fn material_is_kept_exactly_where_some_location_can_still_need_it() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        t.tx(|t| {
            // 旧清单：[1,4] [5,8] [9,10]；[5,8] 作者签了空洞 seq 6。
            t.note_author_version(col, &version(1, 4, &[]))?;
            t.note_author_version(col, &version(5, 8, &[(6, 1)]))?;
            t.note_author_version(col, &version(9, 10, &[]))?;
            for s in [2, 6, 7, 9] {
                t.put_stub(col, &stub(s))?;
            }
            Ok(())
        })
        .unwrap();
        // 1：还没记过 head，全留。
        assert_eq!(
            t.tx(|t| reclaim_material(t, col, &author(), None)).unwrap(),
            (0, 0)
        );
        assert_eq!(ranges(&t, col).len(), 3);
        // 作者合并成 [1,8] 再接 [9,10]；[5,8] 那份件还在转发缓存里（原地重切要它）。
        put_relay_row(&t, col, 5, 8);
        let h = head(2, &[(1, 8), (9, 10)]);
        let bytes = h.encode(&DeviceKey::from_seed(&[A; 32])).unwrap();
        t.tx(|t| note_head(t, col, &h, &bytes)).unwrap();
        // [1,4] 不在新清单、缓存也没有 → 删；[5,8] 缓存有 → 留；[9,10] 新清单列着 → 留。
        assert_eq!(ranges(&t, col), vec![(5, 8), (9, 10)]);
        // 新清单列着 [1,8]、本机还没有它的版本：落在里面的剔除记录（含 seq 2、以及 [5,8] 作者空洞里的 6）全留，
        // [1,8] 的版本到了还要靠它们拼本机清除过的格。
        assert_eq!(stub_seqs(&t, col), vec![2, 6, 7, 9]);
        // 缓存里的件删了（只同步一个位置时 prune 全删）：只为它留的 [5,8] 跟着回收；[1,8] 还需要，剔除记录不动。
        assert_eq!(t.tx(|t| prune(t, col, &author())).unwrap(), 1);
        assert_eq!(ranges(&t, col), vec![(9, 10)]);
        assert_eq!(stub_seqs(&t, col), vec![2, 6, 7, 9]);
        // [1,8] 的作者签名版本晚到（作者签了空洞 seq 6）：回收一遍，只有作者空洞里的 seq 6 走。
        t.tx(|t| t.note_author_version(col, &version(1, 8, &[(6, 1)])))
            .unwrap();
        let stored = head(2, &[(1, 8), (9, 10)]);
        assert_eq!(
            t.tx(|t| reclaim_material(t, col, &author(), Some(&stored)))
                .unwrap(),
            (0, 1)
        );
        assert_eq!(ranges(&t, col), vec![(1, 8), (9, 10)]);
        assert_eq!(stub_seqs(&t, col), vec![2, 7, 9]);
        // 再回收一遍什么都不删。
        assert_eq!(
            t.tx(|t| reclaim_material(t, col, &author(), Some(&stored)))
                .unwrap(),
            (0, 0)
        );
    }

    /// 端到端：重切者收下作者 a 的 [1,2]、[3,5] 两段并清除了 seq 2（剔除记录 + 空洞）。作者在还没见到这条 Purge 时
    /// 把两段合并成 [1,5]；重切者先读到新 head（`plan` 里的 `note_head` 早于收段），旧版本回收，再收到 [1,5] 的作者
    /// 签名版本。这时从日志重切 [1,5] 必须还拼得出来——seq 2 的剔除记录是本机清除时写的，删了就再也生不出来，这位
    /// 作者就会被 `relay_outbox` 整台跳过、不再转发。
    #[test]
    fn a_merge_seen_before_its_version_still_recuts_from_the_log() {
        use crate::gen4::segment::tests::{DEV, coll, items_of, ops, signer};
        use crate::gen4::segment::{open_native_verified, pack_native};
        use crate::store::gen4::truth::Peer;
        use crate::store::gen4::truth::tests::bound;
        use crate::sync2::segment::{CHAIN_ZERO, chain_tag};
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        // 本机身份不能是作者（`DEV`）。
        assert_eq!(
            t.tx(|t| t.create_self(col, &id(0xb2), &[0xb2; 32], None, 1_800_000_000_000)),
            Ok(true)
        );
        let a = id(DEV);
        let key = signer();
        t.tx(|t| {
            t.set_peer(
                col,
                &Peer {
                    device: a,
                    public: key.public(),
                    name: None,
                    ext: None,
                    head_gen: None,
                    first_seen: None,
                },
            )
            .map(|_| ())
        })
        .unwrap();
        let ops = ops();
        let signed = |first: u64, prev, part: &[Op4]| {
            let (header, seg) =
                pack_native(coll(), a, first, &items_of(part), prev, &key, None).unwrap();
            let sig = open_native_verified(&seg, &key.public(), None)
                .unwrap()
                .author_sig();
            AuthorVersion {
                header,
                sig,
                voids: Vec::new(),
            }
        };
        let left = signed(1, CHAIN_ZERO, &ops[..2]);
        let right = signed(3, left.header.last_chain, &ops[2..]);
        let merged = signed(1, CHAIN_ZERO, &ops);
        let tag = chain_tag(&merged.header.last_chain);
        t.tx(|t| {
            for op in &ops {
                t.append_native(col, op)?;
            }
            t.note_author_version(col, &left)?;
            t.note_author_version(col, &right)?;
            t.put_stub(
                col,
                &Stub::of(
                    &ops[1],
                    OpId {
                        device: id(0x22),
                        seq: 7,
                    },
                ),
            )?;
            t.advance_purge(col, &ops[1].id)?;
            Ok(())
        })
        .unwrap();
        // 合并后的 head 先到：[1,2] / [3,5] 不再需要，回收。
        let mut h = head(3, &[(1, 5)]);
        h.device = a;
        let got = t.tx(|t| reclaim_material(t, col, &a, Some(&h))).unwrap();
        assert_eq!(got, (2, 0), "versions go, the stub [1,5] still needs stays");
        assert!(t.stub_at(col, &a, 2).unwrap().is_some());
        // [1,5] 的作者签名版本晚到：照样从日志重切得出来，作者签名照样验得过。
        t.tx(|t| t.note_author_version(col, &merged)).unwrap();
        let cut = t
            .recut_from_log(col, &a, (1, 5, &tag))
            .unwrap()
            .expect("the merged range still recuts from the log");
        assert_eq!(cut.author_sig, merged.sig);
        assert_eq!(cut.items.len(), 5);
    }

    /// 导入用的「已存在则不动」落在 SQL 这一层也成立（`land_relay` 先按 `stub_at` 跳过只是第一道）：本机已有的剔除记录
    /// 不被另一条（别的 Purge 的）换掉；没有的照记。
    #[test]
    fn put_stub_if_absent_never_replaces_a_stored_stub() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        let mine = stub(3);
        let other = {
            let base = crate::gen4::segment::tests::ops()[0].clone();
            Stub::of(
                &Op4 {
                    id: OpId {
                        device: author(),
                        seq: 3,
                    },
                    ..base
                },
                OpId {
                    device: id(0x23),
                    seq: 9,
                },
            )
        };
        assert_ne!(mine.encode(), other.encode());
        t.tx(|t| t.put_stub(col, &mine)).unwrap();
        assert_eq!(t.tx(|t| t.put_stub_if_absent(col, &other)), Ok(false));
        assert_eq!(
            t.stub_at(col, &author(), 3).unwrap().unwrap().encode(),
            mine.encode()
        );
        assert_eq!(t.tx(|t| t.put_stub_if_absent(col, &stub(4))), Ok(true));
        assert_eq!(stub_seqs(&t, col), vec![3, 4]);
    }

    /// 规模：两万个作者签名版本、四万条剔除记录，作者合并掉一半之后回收一遍：删得对，语句数随区间数（不逐条扫），
    /// 时间有界；别的作者的剔除记录不碰。
    #[test]
    fn reclaiming_at_scale_drops_the_dead_half_without_touching_other_authors() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        const N: u64 = 20_000;
        let other = {
            let base = crate::gen4::segment::tests::ops()[0].clone();
            Stub::of(
                &Op4 {
                    id: OpId {
                        device: id(0x44),
                        seq: 3,
                    },
                    ..base
                },
                OpId {
                    device: id(0x22),
                    seq: 7,
                },
            )
        };
        t.tx(|t| {
            for i in 0..N {
                let (a, b) = (2 * i + 1, 2 * i + 2);
                t.note_author_version(col, &version(a, b, &[(b, 1)]))?;
                t.put_stub(col, &stub(a))?;
                t.put_stub(col, &stub(b))?;
            }
            t.put_stub(col, &other)
        })
        .unwrap();
        // 新清单只列偶数号版本（奇数号的被作者并掉了）。
        let segs: Vec<(u64, u64)> = (0..N)
            .filter(|i| i % 2 == 0)
            .map(|i| (2 * i + 1, 2 * i + 2))
            .collect();
        let h = head(5, &segs);
        let started = Instant::now();
        let got = t
            .tx(|t| reclaim_material(t, col, &author(), Some(&h)))
            .unwrap();
        let took = started.elapsed();
        eprintln!("reclaim {N} versions / {} stubs: {took:?}", 2 * N);
        // 删一半版本；剩下的版本里第二格是作者空洞，剔除记录只留第一格。
        assert_eq!(got, (N / 2, 2 * N - N / 2));
        assert_eq!(ranges(&t, col), segs);
        assert_eq!(
            stub_seqs(&t, col),
            segs.iter().map(|s| s.0).collect::<Vec<_>>()
        );
        assert!(t.stub_at(col, &id(0x44), 3).unwrap().is_some());
        assert!(took.as_secs() < 30, "{took:?}");
    }
}
