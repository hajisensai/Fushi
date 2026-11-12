//! 换身份（设计 §7.3）之后旧身份目录的清理（former.rs `sync2_obsolete_former`）。
//!
//! 要保住的只有一条：**位置上旧身份目录里代号最大的 head 在，它引用的每个段都有文件**——读者只读这一份 head 与它
//! 引用的段，新设备 / 长期离线的设备拿旧身份那段历史只有这一个入口。这里逐个情形钉：只有被盖过的旧 head 会被删，
//! 段一个不删，证明不了的目录一个文件不动；别的设备回来 / 新设备加入 / 同一身份的另一个安装还在写 / 几台设备同时
//! 清 / 清到一半 / 列目录不准，都不少读到东西。

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::former::FORMER_QUIET_MS;
use super::tests::{
    Bucket, DAY, Device, P, deck_entity, edit, listed, projection, review, sweep_former,
};
use crate::sync2::keys::DeviceKey;
use crate::sync2::segment::{self, Head, chain_tag, parse_head_file_name, relay_file_name};

const T0: i64 = 1_700_000_000_000;
const L: &str = "L";

fn device_id(d: &Device) -> String {
    d.core.sync2_identity(P, T0).unwrap()["device"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn count(d: &Device, sql: &str) -> usize {
    d.rows(sql)[1][0].parse().unwrap()
}

fn exec(d: &Device, sql: &str) {
    d.core.writer().unwrap().execute_batch(sql).unwrap();
}

/// [bucket] 上 [device] 目录里的 head，按代号升序。
fn heads_of(bucket: &Bucket, device: &str) -> Vec<Head> {
    let mut out: Vec<Head> = listed(bucket, device)
        .into_iter()
        .filter(|n| parse_head_file_name(n).is_some())
        .map(|n| Head::decode(&bucket.0[&format!("devices/{device}/{n}")]).unwrap())
        .collect();
    out.sort_by_key(|h| (h.gen, h.seq));
    out
}

fn path_of(h: &Head) -> String {
    format!("devices/{}/{}", h.device.text(), h.file_name())
}

fn files_under(bucket: &Bucket, device: &str) -> BTreeSet<String> {
    bucket
        .0
        .keys()
        .filter(|k| k.starts_with(&format!("devices/{device}/")))
        .cloned()
        .collect()
}

fn segments_under(bucket: &Bucket, device: &str) -> BTreeSet<String> {
    files_under(bucket, device)
        .into_iter()
        .filter(|p| !p.contains("/head-"))
        .collect()
}

/// 位置上还在的**每一份** head 引用的段都有文件（作者写的或转发来的）——比「代号最大的那份可读」更强。
fn assert_no_dangling(bucket: &Bucket, device: &str, what: &str) {
    let heads = heads_of(bucket, device);
    assert!(!heads.is_empty(), "{what}: no head left");
    for h in heads {
        for f in h.segment_files() {
            assert!(
                bucket.0.contains_key(&format!("devices/{device}/{f}"))
                    || bucket
                        .0
                        .contains_key(&format!("devices/{device}/{}", relay_file_name(&f))),
                "{what}: {} references {f}, which is gone",
                h.file_name()
            );
        }
    }
}

/// 生产的调用方在一个旧身份目录上做的事的前半：列目录、读其中每一份 head、问内核。返回内核给的清单，不删。
fn ask(d: &Device, bucket: &Bucket, device: &str, now: i64) -> Vec<String> {
    let present = listed(bucket, device);
    let heads: Vec<Vec<u8>> = present
        .iter()
        .filter(|n| n.starts_with("head-"))
        .map(|n| bucket.0[&format!("devices/{device}/{n}")].clone())
        .collect();
    d.core
        .sync2_obsolete_former(P, L, device, &present, &heads, false, now)
        .unwrap()
}

/// 这个位置上此刻内核要调用方去看的旧身份（`obsolete` 回复里的 `former`）。
fn due(d: &Device, bucket: &Bucket, now: i64) -> Vec<String> {
    let me = device_id(d);
    d.core
        .sync2_obsolete(P, L, &listed(bucket, &me), false, now)
        .unwrap()
        .former
}

fn first_deck(d: &Device) {
    let deck = super::config::default_deck_id(P);
    d.apply(
        T0,
        vec![
            deck_entity(&deck),
            edit("deck", &deck, "name", json!("Default")),
        ],
    );
}

/// 一台在 [L] 上同步了 [rounds] 轮的设备：每轮一条复习（一轮一个小段，反复合并），轮与轮只隔 1 ms——合并换下来
/// 的旧小段都还在 24 小时宽限期里，一个没删，全登记在待删表里。返回 `(设备, 位置, 它的身份, 每一轮写出的 head)`。
fn busy_device(tag: &str, rounds: i64) -> (Device, Bucket, String, Vec<Head>) {
    let a = Device::new(tag);
    let mut bucket = Bucket::default();
    first_deck(&a);
    let id = device_id(&a);
    let mut written = Vec::new();
    for i in 0..rounds {
        a.apply(
            T0 + i,
            vec![review(&format!("r{i}"), "C", T0 + i, 3, "review")],
        );
        a.sync(&mut bucket, L, T0 + i);
        written.push(heads_of(&bucket, &id).pop().unwrap());
    }
    (a, bucket, id, written)
}

/// 旧目录下登记着的待删行数。
fn rows_under(d: &Device, device: &str) -> usize {
    count(
        d,
        &format!("SELECT COUNT(*) FROM sync2_obsolete WHERE name LIKE 'devices/{device}/%'"),
    )
}

/// 旧身份的私钥（换身份之后本机库里就没有了）：测试在换身份之前取出来，用来造「同一身份的另一个安装之后写进旧
/// 目录的 head」。
fn key_of(d: &Device) -> DeviceKey {
    let hex = d.rows("SELECT lower(hex(key_seed)) FROM sync2_self")[1][0].clone();
    let mut seed = [0u8; 32];
    for (i, b) in seed.iter_mut().enumerate() {
        *b = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).unwrap();
    }
    DeviceKey::from_seed(&seed)
}

/// 往 [bucket] 里放一份 head（[key] 签名），放进它自己声明的设备目录。返回相对路径。
fn put_head(bucket: &mut Bucket, head: &Head, key: &DeviceKey) -> String {
    let path = path_of(head);
    bucket.0.insert(path.clone(), head.encode(key));
    path
}

/// 同一身份的另一个安装在 [base] 之后又写了一条操作时会写出的 head：多发布一个段（文件一并放上），链值不同。
fn longer(bucket: &mut Bucket, base: &Head, gen: u64, salt: u8) -> Head {
    let mut h = base.clone();
    h.gen = gen;
    h.seq = base.seq + 1;
    h.chain = [salt; 32];
    h.segments.push((h.seq, h.seq, chain_tag(&h.chain)));
    let file = segment::segment_file_name(h.seq, h.seq, &chain_tag(&h.chain));
    bucket.0.insert(
        format!("devices/{}/{file}", h.device.text()),
        b"another install's segment".to_vec(),
    );
    h
}

/// 换了身份、旧目录已经被看过一次（计时从 [T0] + [DAY] 起）的设备。返回
/// `(设备, 位置, 旧身份, 旧身份的私钥, 第一次看的时刻)`；旧目录里有三份 head。
fn retired(tag: &str) -> (Device, Bucket, String, DeviceKey, i64) {
    let (a, mut bucket, old, _) = busy_device(tag, 12);
    let key = key_of(&a);
    a.core.sync2_rotate(P, T0 + 1000).unwrap();
    assert_eq!(heads_of(&bucket, &old).len(), 3);
    let t1 = T0 + DAY;
    assert_eq!(sweep_former(&a.core, &mut bucket, L, &old, t1), [""; 0]);
    (a, bucket, old, key, t1)
}

/// 主路径。换身份之后旧目录里：被盖过的旧 head 在目录静止一个周期之后删掉；段——包括本机还是旧身份时合并换下来、
/// 登记了还没删的旧小段——一个不删；待删表里旧目录下的行在换身份那一刻作废。清之前同步到一半的设备、清之后才
/// 第一次来的设备，读到的与清之前就同步完的设备一样。
#[test]
fn a_retired_directory_loses_only_its_covered_heads() {
    let (a, mut bucket, old, _) = busy_device("fg-main", 40);
    let half_way = Device::new("fg-half");
    half_way.sync(&mut bucket, L, T0 + 100);
    for i in 40..43 {
        a.apply(
            T0 + 200 + i,
            vec![review(&format!("r{i}"), "C", T0 + 200 + i, 3, "review")],
        );
        a.sync(&mut bucket, L, T0 + 200 + i);
    }
    let reference = Device::new("fg-ref");
    reference.sync(&mut bucket, L, T0 + 300);
    reference.sync(&mut bucket, L, T0 + 300);
    assert!(rows_under(&a, &old) > 8, "{}", rows_under(&a, &old));
    let referenced: BTreeSet<String> = heads_of(&bucket, &old)
        .iter()
        .flat_map(Head::segment_files)
        .map(|f| format!("devices/{old}/{f}"))
        .collect();
    assert!(
        segments_under(&bucket, &old)
            .difference(&referenced)
            .count()
            > 8,
        "the directory must hold merged-away segments no head references"
    );
    a.core.sync2_rotate(P, T0 + 1000).unwrap();
    let new = device_id(&a);
    assert_ne!(new, old);
    assert_eq!(rows_under(&a, &old), 0, "rows under the old directory");
    let before = files_under(&bucket, &old);
    let heads = heads_of(&bucket, &old);
    assert_eq!(heads.len(), 3);
    let top = heads.last().unwrap().clone();
    // 新身份照常同步（写自己的目录）。旧目录第一次被看：只起算。
    let t1 = T0 + DAY;
    a.apply(t1, vec![review("n1", "C", t1, 3, "review")]);
    assert_eq!(due(&a, &bucket, t1), vec![old.clone()]);
    a.sync(&mut bucket, L, t1);
    assert_eq!(files_under(&bucket, &old), before);
    // 没静止够：不该看，看了也不给。
    let almost = t1 + FORMER_QUIET_MS - 1;
    assert_eq!(due(&a, &bucket, t1 + 1), [""; 0]);
    assert_eq!(due(&a, &bucket, almost), [""; 0]);
    assert_eq!(ask(&a, &bucket, &old, almost), [""; 0]);
    a.sync(&mut bucket, L, almost);
    assert_eq!(files_under(&bucket, &old), before);
    // 静止够了：被盖过的两份 head，别的一个不动。
    let t2 = t1 + FORMER_QUIET_MS;
    assert_eq!(due(&a, &bucket, t2), vec![old.clone()]);
    a.sync(&mut bucket, L, t2);
    let mut expected = before.clone();
    for h in &heads[..2] {
        assert!(expected.remove(&path_of(h)));
    }
    assert_eq!(files_under(&bucket, &old), expected);
    assert_eq!(heads_of(&bucket, &old), vec![top]);
    // 之后每个周期看一次，再没有东西可删。
    for k in 1..6 {
        let now = t2 + k * FORMER_QUIET_MS + k;
        a.sync(&mut bucket, L, now);
        assert_eq!(ask(&a, &bucket, &old, now + 1), [""; 0]);
        assert_eq!(files_under(&bucket, &old), expected);
    }
    assert_no_dangling(&bucket, &old, "after cleaning");
    // 读者：清之前同步到一半的设备回来、清之后才第一次来的新设备，都与清之前同步完的对照一致。
    let end = t2 + 10 * FORMER_QUIET_MS;
    let fresh = Device::new("fg-fresh");
    for _ in 0..2 {
        for d in [&a, &reference, &half_way, &fresh] {
            d.sync(&mut bucket, L, end);
        }
    }
    for (d, what) in [(&half_way, "half-way"), (&fresh, "fresh"), (&a, "author")] {
        assert_eq!(projection(d), projection(&reference), "{what}");
    }
    assert_eq!(fresh.digest(), reference.digest());
    assert_eq!(
        count(&fresh, "SELECT COUNT(*) FROM srs_review_logs"),
        44,
        "every review, old identity and new"
    );
}

/// 段一个不删，哪怕位置上没有任何 head 引用它、目录静止了很久。原因是这里钉的这条时间线（反驳式核验 M1）：同一
/// 身份的另一个安装切法里还有本机合并掉的小段，它之后来这个位置写出一份引用那个小段的 head——代号最大，读者只读
/// 它。小段要是被清掉了，这份 head 就引用了一个不在的文件，而那个安装自己也换了身份 / 不再来的话再没有人补。
#[test]
fn merged_away_segments_stay_for_a_head_another_install_may_still_write() {
    let (a, mut bucket, old, written) = busy_device("fg-m1", 40);
    let key = key_of(&a);
    let now_referenced: BTreeSet<String> = heads_of(&bucket, &old)
        .iter()
        .flat_map(Head::segment_files)
        .collect();
    // 另一个安装的切法：本机某一轮合并之前的切法（当时本机自己写过的 head 就是这样切的）。
    let stale = written
        .iter()
        .rev()
        .find(|h| {
            h.segment_files()
                .iter()
                .any(|f| !now_referenced.contains(f))
        })
        .expect("a head whose cut was later merged away")
        .clone();
    a.core.sync2_rotate(P, T0 + 1000).unwrap();
    let segments = segments_under(&bucket, &old);
    let top = heads_of(&bucket, &old).pop().unwrap();
    // 旧目录静止很久，每个周期都看。
    let mut given = Vec::new();
    for k in 0..8 {
        given.extend(sweep_former(
            &a.core,
            &mut bucket,
            L,
            &old,
            T0 + DAY + k * FORMER_QUIET_MS,
        ));
    }
    assert_eq!(given.len(), 2, "{given:?}");
    assert!(given.iter().all(|p| p.contains("/head-")), "{given:?}");
    assert_eq!(segments_under(&bucket, &old), segments);
    // 另一个安装回来了：它看见自己切法里的段都在（作者自检通过），写出代号最大的 head。
    let mut theirs = stale;
    theirs.gen = top.gen + 1;
    put_head(&mut bucket, &theirs, &key);
    assert_no_dangling(&bucket, &old, "after the other install wrote its head");
    // 之后照常清：还是只有 head，段照旧一个不动。
    let later = T0 + DAY + 20 * FORMER_QUIET_MS;
    for k in 0..4 {
        let more = sweep_former(&a.core, &mut bucket, L, &old, later + k * FORMER_QUIET_MS);
        assert!(more.iter().all(|p| p.contains("/head-")), "{more:?}");
    }
    assert_eq!(segments_under(&bucket, &old), segments);
    assert_no_dangling(&bucket, &old, "at the end");
    assert!(heads_of(&bucket, &old).contains(&theirs));
}

/// 还有安装在往旧目录里写（目录每次看都不一样）：本机不碰，由写的人按它自己的规则清。写的人停了、目录静止够一个
/// 周期之后才清。
#[test]
fn a_directory_someone_still_writes_to_is_left_alone() {
    let (a, mut bucket, old, key, t1) = retired("fg-live");
    let before = files_under(&bucket, &old);
    let mut top = heads_of(&bucket, &old).pop().unwrap();
    let half = FORMER_QUIET_MS / 2;
    let mut now = t1;
    for _ in 0..10 {
        now += half;
        top.gen += 1;
        top.at_ms = now;
        put_head(&mut bucket, &top, &key);
        // 内核不催（刚看过、还没到期），调用方硬去看也什么都拿不到。
        assert_eq!(ask(&a, &bucket, &old, now + 1), [""; 0]);
        assert_eq!(
            sweep_former(&a.core, &mut bucket, L, &old, now + 2),
            [""; 0]
        );
    }
    assert!(files_under(&bucket, &old).is_superset(&before));
    assert_eq!(heads_of(&bucket, &old).len(), 13);
    // 不再有人写：最后一次看到变化之后满一个周期才清，清到只剩代号最大的那份。
    let quiet_from = now + 1;
    assert_eq!(
        ask(&a, &bucket, &old, quiet_from + FORMER_QUIET_MS - 1),
        [""; 0]
    );
    let given = sweep_former(&a.core, &mut bucket, L, &old, quiet_from + FORMER_QUIET_MS);
    assert_eq!(given.len(), 12);
    assert_eq!(heads_of(&bucket, &old), vec![top]);
    assert_no_dangling(&bucket, &old, "after the writer stopped");
}

/// 「被盖过」= 另有一份代号更大、**发布的 seq 不比它小**的 head。head 代号是每个安装自己的计数器：另一个安装的
/// head 可以代号小而发布得更多（位置上唯一记着「这个身份还有更多操作」的东西），同代号的两份互不盖。
#[test]
fn a_head_that_publishes_more_is_kept_whatever_its_generation() {
    let (a, mut bucket, old, key, _) = retired("fg-seq");
    let heads = heads_of(&bucket, &old);
    let (low, top) = (heads[0].clone(), heads[2].clone());
    // 另一个安装：代号比位置上最小的还小，却多发布了两条；以及一份与最大代号同代号、多发布一条的。
    let step = longer(&mut bucket, &top, low.gen - 1, 0xa1);
    let ahead = longer(&mut bucket, &step, low.gen - 1, 0xa2);
    let sibling = longer(&mut bucket, &top, top.gen, 0xb2);
    put_head(&mut bucket, &ahead, &key);
    put_head(&mut bucket, &sibling, &key);
    let t = T0 + 3 * DAY;
    assert_eq!(sweep_former(&a.core, &mut bucket, L, &old, t), [""; 0]);
    let given: BTreeSet<String> = sweep_former(&a.core, &mut bucket, L, &old, t + FORMER_QUIET_MS)
        .into_iter()
        .collect();
    // 只有本机自己那两份旧的（代号更小、seq 也不更大）。
    assert_eq!(
        given,
        heads[..2].iter().map(path_of).collect::<BTreeSet<_>>()
    );
    let left: BTreeSet<String> = heads_of(&bucket, &old).iter().map(path_of).collect();
    assert_eq!(
        left,
        [&ahead, &top, &sibling]
            .into_iter()
            .map(path_of)
            .collect::<BTreeSet<_>>()
    );
    for k in 2..5 {
        assert_eq!(
            sweep_former(&a.core, &mut bucket, L, &old, t + k * FORMER_QUIET_MS),
            [""; 0]
        );
    }
}

/// 两台都换掉了同一个旧身份的设备同时清，其中一台删到一半就死了：清的人只删不写，每一份删除都以一份代号更大的
/// head 为据，谁先谁后、删了几份都一样——代号最大的那份始终在，段始终都在。
#[test]
fn concurrent_and_interrupted_cleaners_never_touch_the_newest_head() {
    let (a, mut bucket, old, _) = busy_device("fg-two", 12);
    let twin = Device::copy_of(&a, "fg-two-twin");
    a.core.sync2_rotate(P, T0 + 1000).unwrap();
    twin.core.sync2_rotate(P, T0 + 1000).unwrap();
    assert_ne!(device_id(&a), device_id(&twin));
    let heads = heads_of(&bucket, &old);
    let top = heads[2].clone();
    let segments = segments_under(&bucket, &old);
    let t1 = T0 + DAY;
    assert_eq!(ask(&a, &bucket, &old, t1), [""; 0]);
    assert_eq!(ask(&twin, &bucket, &old, t1), [""; 0]);
    // 同一份目录列表上两边各自拿到清单。
    let t2 = t1 + FORMER_QUIET_MS;
    let (mine, theirs) = (ask(&a, &bucket, &old, t2), ask(&twin, &bucket, &old, t2));
    assert_eq!(mine, theirs);
    assert_eq!(mine, vec![path_of(&heads[0]), path_of(&heads[1])]);
    // a 删了第一份就死了。
    bucket.0.remove(&mine[0]);
    assert_no_dangling(&bucket, &old, "half-way");
    // a 重启后下一轮：目录与上次不同，从头计时，这一轮什么都不给；没有待删记录可接着删。
    assert_eq!(due(&a, &bucket, t2 + 1), vec![old.clone()]);
    assert_eq!(ask(&a, &bucket, &old, t2 + 1), [""; 0]);
    assert_eq!(
        ask(&a, &bucket, &old, t2 + FORMER_QUIET_MS),
        [""; 0],
        "a full period after the change, not after the first look"
    );
    assert_eq!(
        ask(&a, &bucket, &old, t2 + 1 + FORMER_QUIET_MS),
        vec![mine[1].clone()]
    );
    // 另一台这时才把它那份（旧的）清单删完：其中一份早就不在了（删除幂等）。
    for p in &theirs {
        bucket.0.remove(p);
    }
    assert_eq!(heads_of(&bucket, &old), vec![top]);
    assert_eq!(segments_under(&bucket, &old), segments);
    assert_no_dangling(&bucket, &old, "after both");
    // 两边之后都再没有东西可删。
    for k in 2..5 {
        for d in [&a, &twin] {
            assert_eq!(ask(d, &bucket, &old, t2 + 1 + k * FORMER_QUIET_MS), [""; 0]);
        }
    }
    // 第一次来的设备读得到旧身份的全部历史。
    let fresh = Device::new("fg-two-fresh");
    fresh.sync(&mut bucket, L, t2 + 9 * DAY);
    assert_eq!(count(&fresh, "SELECT COUNT(*) FROM srs_review_logs"), 12);
}

/// 列目录不准（网盘最终一致）。少列了最新的 head：没列到的既不删、也不拿来当依据，按列到的那些判，删掉的仍然是被
/// 另一份**在场**的 head 盖过的。多列了已经不在的 head（读不到它）：证明不了，整个目录不动。
#[test]
fn a_stale_listing_never_costs_the_newest_head() {
    let (a, bucket, old, _, t1) = retired("fg-list");
    let heads = heads_of(&bucket, &old);
    let ask_with = |d: &Device, present: &[String], heads: &[&Head], now: i64| {
        let bytes: Vec<Vec<u8>> = heads
            .iter()
            .map(|h| bucket.0[&path_of(h)].clone())
            .collect();
        d.core
            .sync2_obsolete_former(P, L, &old, present, &bytes, false, now)
            .unwrap()
    };
    // 少列：最新那份 head 还列不到。
    let short: Vec<String> = listed(&bucket, &old)
        .into_iter()
        .filter(|n| *n != heads[2].file_name())
        .collect();
    let d = Device::copy_of(&a, "fg-list-short");
    assert_eq!(ask_with(&d, &short, &[&heads[0], &heads[1]], t1), [""; 0]);
    assert_eq!(
        ask_with(&d, &short, &[&heads[0], &heads[1]], t1 + FORMER_QUIET_MS),
        vec![path_of(&heads[0])]
    );
    // 多列：列表里有三份 head，其中一份读不到。
    let full = listed(&bucket, &old);
    for missing in 0..3 {
        let read: Vec<&Head> = heads
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != missing)
            .map(|(_, h)| h)
            .collect();
        let d = Device::copy_of(&a, "fg-list-long");
        assert_eq!(
            ask_with(&d, &full, &read, t1 + FORMER_QUIET_MS),
            [""; 0],
            "head {missing} listed but unreadable"
        );
    }
}

/// 证明不了的目录一个文件都不给，也不催着再看（一个周期之后再说）。每一种都从同一个「下一次看就会给出两份旧 head」
/// 的状态出发，只改一处。
#[test]
fn an_unprovable_directory_is_left_untouched() {
    let (a, bucket, old, key, t1) = retired("fg-unproven");
    let heads = heads_of(&bucket, &old);
    let top = heads[2].clone();
    let now = t1 + FORMER_QUIET_MS;
    let present = listed(&bucket, &old);
    let bytes: Vec<Vec<u8>> = heads
        .iter()
        .map(|h| bucket.0[&path_of(h)].clone())
        .collect();
    let covered = vec![path_of(&heads[0]), path_of(&heads[1])];
    let other = DeviceKey::from_seed(&[9u8; 32]);
    let with_head = |h: &Head, signer: &DeviceKey| {
        let mut present = present.clone();
        present.push(h.file_name());
        let mut bytes = bytes.clone();
        bytes.push(h.encode(signer));
        (present, bytes)
    };
    let mut newer = top.clone();
    newer.gen = top.gen + 1;
    type Case = (&'static str, Vec<String>, Vec<Vec<u8>>, bool, Vec<String>);
    let mut cases: Vec<Case> = Vec::new();
    // 对照：原样、以及多一份代号更大的真 head，都给得出清单。
    cases.push((
        "control",
        present.clone(),
        bytes.clone(),
        false,
        covered.clone(),
    ));
    let (p, b) = with_head(&newer, &key);
    cases.push((
        "control: a newer genuine head",
        p,
        b,
        false,
        heads.iter().map(path_of).collect(),
    ));
    // 归档位置：只写不删。
    cases.push(("archive", present.clone(), bytes.clone(), true, vec![]));
    // 伪造的 head：签名的钥匙不是这个身份的那把（head 里的公钥照抄真的）。
    let (p, b) = with_head(&newer, &other);
    cases.push(("forged signature", p, b, false, vec![]));
    // 自洽的 head，但公钥不是设备表里记的那把。
    let mut impostor = newer.clone();
    impostor.public = other.public();
    let (p, b) = with_head(&impostor, &other);
    cases.push(("unknown key", p, b, false, vec![]));
    // 别的设备的 head 放在这个目录里。
    let mut stranger = newer.clone();
    stranger.device = crate::sync2::id::Id::random();
    let (p, b) = with_head(&stranger, &key);
    cases.push(("another device's head", p, b, false, vec![]));
    // 别的集合的 head。
    let mut foreign = newer.clone();
    foreign.collection = crate::sync2::id::Id::random();
    let (p, b) = with_head(&foreign, &key);
    cases.push(("another collection's head", p, b, false, vec![]));
    // 更新版本写的 head（本机读不懂它的内容）。
    let mut future = newer.clone();
    future.min_reader = segment::PROTOCOL + 1;
    let (p, b) = with_head(&future, &key);
    cases.push(("needs a newer reader", p, b, false, vec![]));
    // 坏字节。
    let mut broken = bytes.clone();
    broken[1].truncate(40);
    cases.push(("corrupt head", present.clone(), broken, false, vec![]));
    // 交来的 head 不在列表里（列表是旧的 / 不是同一次列的）。
    let (_, b) = with_head(&newer, &key);
    cases.push(("head not in the listing", present.clone(), b, false, vec![]));
    // 列表里的 head 少交了一份。
    cases.push((
        "listed head not read",
        present.clone(),
        bytes[..2].to_vec(),
        false,
        vec![],
    ));
    // 少交一份、又多交一份列表里没有的：份数对得上也不行。
    let mut swapped = bytes[..2].to_vec();
    swapped.push(newer.encode(&key));
    cases.push((
        "one listed head unread, one unlisted head supplied",
        present.clone(),
        swapped,
        false,
        vec![],
    ));
    // `head-` 开头却不是合法 head 文件名的东西：也得有对得上的字节。
    let mut odd = present.clone();
    odd.push("head-partial.tmp".into());
    cases.push(("unparseable head name", odd, bytes.clone(), false, vec![]));
    // 一份 head 都没有。
    let none: Vec<String> = present
        .iter()
        .filter(|n| !n.starts_with("head-"))
        .cloned()
        .collect();
    cases.push(("no head at all", none, vec![], false, vec![]));
    // 留下的 head 引用的段不在：目录本身不完整。
    let gone = top.segment_files().pop().unwrap();
    let incomplete: Vec<String> = present.iter().filter(|n| **n != gone).cloned().collect();
    cases.push((
        "a referenced segment is missing",
        incomplete.clone(),
        bytes.clone(),
        false,
        vec![],
    ));
    // ……除非它以转发件的名字在（读者两个名字都认）。
    let mut relayed = incomplete;
    relayed.push(relay_file_name(&gone));
    cases.push((
        "control: the segment is there as a relayed copy",
        relayed,
        bytes.clone(),
        false,
        covered.clone(),
    ));
    for (what, present, bytes, archive, expected) in cases {
        // 同一份输入隔一个周期交两次：证明得了的目录最迟第二次给出清单（列表与上次看时不同就从头计时），证明不了
        // 的两次都不给。
        let d = Device::copy_of(&a, "fg-unproven-case");
        let look = |at: i64| {
            d.core
                .sync2_obsolete_former(P, L, &old, &present, &bytes, archive, at)
                .unwrap()
        };
        let first = look(now);
        let given = if first.is_empty() {
            look(now + FORMER_QUIET_MS)
        } else {
            first
        };
        assert_eq!(given, expected, "{what}");
        if !expected.is_empty() || archive {
            continue;
        }
        // 证明不了：一个周期之内不催；之后目录正常了也要重新静止一个周期。
        let then = now + FORMER_QUIET_MS;
        assert_eq!(due(&d, &bucket, then + 1), [""; 0], "{what}");
        assert_eq!(
            due(&d, &bucket, then + FORMER_QUIET_MS),
            vec![old.clone()],
            "{what}"
        );
        assert_eq!(
            ask(&d, &bucket, &old, then + FORMER_QUIET_MS),
            [""; 0],
            "{what}"
        );
        assert_eq!(
            ask(&d, &bucket, &old, then + 2 * FORMER_QUIET_MS),
            covered,
            "{what}"
        );
    }
}

/// 只认本机的旧身份：当前身份、别的设备、不认识的设备都不归这里清（它们的目录有主人），也不为它们记任何东西。
#[test]
fn only_identities_this_device_left_behind_are_cleaned() {
    let (a, mut bucket, old, _, t1) = retired("fg-scope");
    let other = Device::new("fg-scope-other");
    for i in 0..5 {
        other.apply(
            T0 + i,
            vec![review(&format!("o{i}"), "C", T0 + i, 3, "review")],
        );
        other.sync(&mut bucket, L, t1 + 1 + i);
    }
    a.sync(&mut bucket, L, t1 + 10);
    let (new, theirs) = (device_id(&a), device_id(&other));
    let watches = |d: &Device| {
        count(
            d,
            "SELECT COUNT(*) FROM srs_meta WHERE key LIKE 'sync2_former/%'",
        )
    };
    assert_eq!(watches(&a), 1);
    let unknown = crate::sync2::id::Id::random().text();
    for device in [&new, &theirs, &unknown] {
        for now in [t1, t1 + FORMER_QUIET_MS, t1 + 3 * FORMER_QUIET_MS] {
            assert_eq!(ask(&a, &bucket, device, now), [""; 0], "{device}");
        }
    }
    assert_eq!(watches(&a), 1);
    assert_eq!(heads_of(&bucket, &theirs).len(), 3);
    assert!(
        a.core
            .sync2_obsolete_former(P, L, "not-an-id", &[], &[], false, t1)
            .is_err()
    );
    // 没换过身份的设备：内核从不点名，问了也不给。
    assert_eq!(due(&other, &bucket, t1 + 9 * DAY), [""; 0]);
    assert_eq!(ask(&other, &bucket, &old, t1 + 9 * DAY), [""; 0]);
    assert_eq!(watches(&other), 0);
}

/// 节流与时钟。每个位置各记各的；看过之后一个周期内不催；时钟被拨回去（记录的时刻比现在晚得不合理）时照样去看，
/// 并从头计时，不拿「未来」的起点算静止期。
#[test]
fn each_location_is_watched_on_its_own_clock() {
    let (a, mut bucket, old, _, t1) = retired("fg-due");
    // 另一个位置：没看过，该看。
    let mut m = Bucket::default();
    a.sync(&mut m, "M", t1 + 5);
    let me = device_id(&a);
    let due_at = |location: &str, b: &Bucket, now: i64| {
        a.core
            .sync2_obsolete(P, location, &listed(b, &me), false, now)
            .unwrap()
            .former
    };
    assert_eq!(due_at(L, &bucket, t1 + 10), [""; 0]);
    // M 上没有旧身份的目录（旧身份没在那里写过）：看了一次、证明不了、过一个周期再看。
    assert_eq!(due_at("M", &m, t1 + 10), [""; 0]);
    assert_eq!(due_at("M", &m, t1 + 5 + FORMER_QUIET_MS), vec![old.clone()]);
    // 归档位置不看。
    assert_eq!(
        a.core
            .sync2_obsolete(P, "A", &[], true, t1 + 10)
            .unwrap()
            .former,
        [""; 0]
    );
    // 时钟拨回 10 天。
    let back = t1 - 10 * DAY;
    assert_eq!(due_at(L, &bucket, back), vec![old.clone()]);
    assert_eq!(sweep_former(&a.core, &mut bucket, L, &old, back), [""; 0]);
    assert_eq!(
        sweep_former(&a.core, &mut bucket, L, &old, back + FORMER_QUIET_MS - 1),
        [""; 0]
    );
    assert_eq!(
        sweep_former(&a.core, &mut bucket, L, &old, back + FORMER_QUIET_MS).len(),
        2
    );
}

/// 以前的版本换身份留下的待删行（那时旧目录下的行原样留着，更早的版本还会给它们盖上新身份的代号）：升级后第一轮
/// 收尾就作废。之后待删表里没有任何旧目录下的行——2026-11 之前的内核按「代号 + 2 且过了 24 小时」交出任何行、不看
/// 它在谁的目录（BUG-4324），降级回去也无行可交。
#[test]
fn rows_left_under_a_former_identity_by_older_versions_are_dropped() {
    let (a, mut bucket, old, _) = busy_device("fg-rows", 30);
    let rows = rows_under(&a, &old);
    assert!(rows > 4, "{rows}");
    // 旧版本的换身份：不动待删表。
    let saved = a.rows(&format!(
        "SELECT location, name, last, since_gen, since_at FROM sync2_obsolete WHERE name LIKE 'devices/{old}/%'"
    ));
    a.core.sync2_rotate(P, T0 + 1000).unwrap();
    assert_eq!(rows_under(&a, &old), 0, "this version drops them on rotate");
    for r in saved.iter().skip(1) {
        exec(
            &a,
            &format!(
                "INSERT INTO sync2_obsolete (profile_uid, location, name, last, since_gen, since_at) \
                 VALUES (srs_id('{P}'), '{}', '{}', {}, NULL, NULL)",
                r[0], r[1], r[2]
            ),
        );
    }
    // 别的位置上登记在旧目录下的行同样作废。
    exec(
        &a,
        &format!(
            "INSERT INTO sync2_obsolete (profile_uid, location, name, last, since_gen, since_at) VALUES \
             (srs_id('{P}'), 'M', 'devices/{old}/seg-000000000001-000000000002-aaaaaaaa.bin', 2, 3, 0)"
        ),
    );
    assert_eq!(rows_under(&a, &old), rows + 1);
    let segments = segments_under(&bucket, &old);
    // 升级后的第一轮。
    let t = T0 + 30 * DAY;
    a.apply(t, vec![review("n1", "C", t, 3, "review")]);
    a.sync(&mut bucket, L, t);
    assert_eq!(rows_under(&a, &old), 0);
    // 旧内核交出一行的条件（冻结在这里）：旧目录下再没有满足它的行——表里已经没有旧目录下的行。
    for k in 1..6 {
        let now = t + k * 2 * DAY;
        a.apply(now, vec![review(&format!("m{k}"), "C", now, 3, "review")]);
        a.sync(&mut bucket, L, now);
        let legacy = a.rows(&format!(
            "SELECT name FROM sync2_obsolete WHERE since_gen + 2 <= (SELECT head_gen FROM sync2_self) \
             AND since_at + {DAY} <= {now} AND name LIKE 'devices/{old}/%'"
        ));
        assert_eq!(legacy.len(), 1, "{legacy:?}");
    }
    assert_eq!(segments_under(&bucket, &old), segments);
    assert_no_dangling(&bucket, &old, "after the upgrade");
}

/// 经生产分发器发一条 v2 命令。
fn cmd(d: &Device, req: Value, blobs: Vec<Vec<u8>>) -> Result<Value, String> {
    let mut req = req;
    req["profile"] = json!(P);
    req["caches"] = json!({"defaultDeck": super::config::default_deck_id(P)});
    let mut blobs = blobs;
    let mut files = Vec::new();
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files)
}

/// FFI 的两条命令：`obsolete` 的回复点名旧身份，`obsolete_former` 收目录列表 + head 字节、回清单。
#[test]
fn the_dispatcher_names_former_identities_and_takes_their_heads() {
    let (a, bucket, old, _, t1) = retired("fg-ffi");
    let me = device_id(&a);
    let now = t1 + FORMER_QUIET_MS;
    let reply = cmd(
        &a,
        json!({"op": "obsolete", "location": L, "present": listed(&bucket, &me), "now": now}),
        vec![],
    )
    .unwrap();
    assert_eq!(reply["former"], json!([old]));
    let present = listed(&bucket, &old);
    let heads = heads_of(&bucket, &old);
    let bytes: Vec<Vec<u8>> = heads
        .iter()
        .map(|h| bucket.0[&path_of(h)].clone())
        .collect();
    let request = json!({"op": "obsolete_former", "location": L, "device": old, "present": present, "now": now});
    // 归档位置：不给。
    let mut archived = request.clone();
    archived["archive"] = json!(true);
    assert_eq!(
        cmd(&a, archived, bytes.clone()).unwrap(),
        json!({"delete": []})
    );
    assert_eq!(
        cmd(&a, request.clone(), bytes).unwrap(),
        json!({"delete": [path_of(&heads[0]), path_of(&heads[1])]})
    );
    // 缺参数是调用方的错，不当成「空目录」。
    for missing in ["present", "device", "location", "now"] {
        let mut r = request.clone();
        r.as_object_mut().unwrap().remove(missing);
        assert!(cmd(&a, r, vec![]).is_err(), "{missing}");
    }
    // 没换过身份的设备：`former` 是空数组（不是缺字段）。
    let plain = Device::new("fg-ffi-plain");
    first_deck(&plain);
    let reply = cmd(
        &plain,
        json!({"op": "obsolete", "location": L, "present": [], "now": now}),
        vec![],
    )
    .unwrap();
    assert_eq!(reply["former"], json!([]));
}

/// 新设备经分批收段会话（大库首次同步走的收段通道）加入：从清过的位置上读到的，与清之前就同步完的设备一样。
#[test]
fn a_new_device_joining_through_an_ingest_session_reads_the_whole_history() {
    let (a, mut bucket, old, _) = busy_device("fg-join", 30);
    let reference = Device::new("fg-join-ref");
    reference.sync(&mut bucket, L, T0 + 100);
    reference.sync(&mut bucket, L, T0 + 100);
    a.core.sync2_rotate(P, T0 + 1000).unwrap();
    let mut now = T0 + DAY;
    for k in 0..4 {
        now = T0 + DAY + k * FORMER_QUIET_MS;
        a.apply(now, vec![review(&format!("n{k}"), "C", now, 3, "review")]);
        a.sync(&mut bucket, L, now);
        reference.sync(&mut bucket, L, now);
    }
    reference.sync(&mut bucket, L, now);
    assert_eq!(heads_of(&bucket, &old).len(), 1);
    let fresh = Device::new("fg-join-fresh");
    // 生产的读半边：每台设备取代号最大的 head → 内核定要拉的段 → 分批收。
    let mut newest: std::collections::BTreeMap<String, (u64, Vec<u8>)> = Default::default();
    for (path, bytes) in &bucket.0 {
        let parts: Vec<&str> = path.split('/').collect();
        if parts.len() != 3 {
            continue;
        }
        if let Some(g) = parse_head_file_name(parts[2]) {
            let e = newest
                .entry(parts[1].to_owned())
                .or_insert((g, bytes.clone()));
            if g >= e.0 {
                *e = (g, bytes.clone());
            }
        }
    }
    let heads: Vec<Vec<u8>> = newest.into_values().map(|x| x.1).collect();
    cmd(&fresh, json!({"op": "identity", "now": now}), vec![]).unwrap();
    let plan = cmd(&fresh, json!({"op": "plan"}), heads).unwrap();
    let files: Vec<Vec<u8>> = plan["fetch"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|f| f["files"].as_array().unwrap().iter())
        .map(|name| {
            let name = name.as_str().unwrap();
            let (dir, file) = name.rsplit_once('/').unwrap();
            bucket
                .0
                .get(name)
                .or_else(|| bucket.0.get(&format!("{dir}/{}", relay_file_name(file))))
                .unwrap_or_else(|| panic!("{name} is not on the location"))
                .clone()
        })
        .collect();
    assert!(files.len() > 1);
    cmd(&fresh, json!({"op": "ingest_begin"}), vec![]).unwrap();
    for chunk in files.chunks(2) {
        cmd(&fresh, json!({"op": "ingest_prepare"}), chunk.to_vec()).unwrap();
        while cmd(&fresh, json!({"op": "ingest_commit", "now": now}), vec![]).unwrap()["more"]
            == json!(true)
        {}
    }
    let mut r = cmd(&fresh, json!({"op": "ingest_finish", "now": now}), vec![]).unwrap();
    while r["more"] == json!(true) {
        r = cmd(&fresh, json!({"op": "replay_pending", "now": now}), vec![]).unwrap();
    }
    assert_eq!(projection(&fresh), projection(&reference));
    assert_eq!(count(&fresh, "SELECT COUNT(*) FROM srs_review_logs"), 34);
}

/// 转发：清理之前就同步过的设备，清理之后把旧身份的 head 与段带到另一个位置；只从那个位置读的设备读得到全部。
#[test]
fn a_relayer_carries_the_cleaned_identity_to_another_location() {
    let (a, mut bucket, old, _) = busy_device("fg-relay", 30);
    let carrier = Device::new("fg-relay-carrier");
    carrier.sync(&mut bucket, L, T0 + 100);
    carrier.sync(&mut bucket, L, T0 + 100);
    a.core.sync2_rotate(P, T0 + 1000).unwrap();
    let mut now = T0 + DAY;
    for k in 0..4 {
        now = T0 + DAY + k * FORMER_QUIET_MS;
        a.sync(&mut bucket, L, now);
    }
    assert_eq!(heads_of(&bucket, &old).len(), 1);
    // 清过之后转发者回到这个位置，再去另一个位置。
    let mut m = Bucket::default();
    for _ in 0..2 {
        carrier.sync(&mut bucket, L, now + 1);
        carrier.sync(&mut m, "M", now + 2);
    }
    assert_no_dangling(&m, &old, "on the other location");
    let far = Device::new("fg-relay-far");
    far.sync(&mut m, "M", now + 3);
    far.sync(&mut m, "M", now + 3);
    assert_eq!(projection(&far), projection(&carrier));
    assert_eq!(count(&far, "SELECT COUNT(*) FROM srs_review_logs"), 30);
    // 清理者自己不往别处带旧身份（它不转发自己冻结的身份），也不动转发者放的东西。
    assert_no_dangling(&bucket, &old, "on the first location");
}

/// 备份快照（去掉设备本地状态的那种）不带观察记录：恢复出来的是另一台设备，不能接着别人的计时算静止期。
#[test]
fn a_backup_snapshot_does_not_carry_the_watch() {
    let (a, _bucket, _old, _, _) = retired("fg-snap");
    assert_eq!(
        count(
            &a,
            "SELECT COUNT(*) FROM srs_meta WHERE key LIKE 'sync2_former/%'"
        ),
        1
    );
    let dir = super::tests::tempdir::new("fg-snap-out");
    let path = dir.0.join("srs.db");
    a.core.snapshot_into(&path, true).unwrap();
    let restored = Device {
        core: crate::store::SrsCore::open(&path).unwrap(),
        _dir: dir,
    };
    assert_eq!(
        count(
            &restored,
            "SELECT COUNT(*) FROM srs_meta WHERE key LIKE 'sync2_former/%'"
        ),
        0
    );
}
