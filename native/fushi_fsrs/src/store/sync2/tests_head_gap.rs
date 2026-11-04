//! head 只引用位置上已有的段（BUG：设备 01a173ca 的 head 引用了 `seg-647566-647731` / `seg-647989`，位置上没有、
//! 也没有任何文件覆盖那段 seq，读者的待应用永久卡在 2582 条）。
//!
//! 根因（transport.rs）：写 head 时取的是**当下**的切法，而这个位置最后一次发件确认之后，另一个位置的发件跑了小段
//! 合并——合并出的段只登记了「要重传」，还没传到这个位置；以前写 head 时照样引用它并清掉重传登记，被换下的旧小段过
//! 了宽限期再被删，缺口就永久了。修法：有重传未完时不写 head（交回改切，下一轮补传）；作者每轮按位置上自己目录的
//! 列表自检，head 引用却不在的段登记重传（已有的缺口也由作者补上）。

use std::collections::BTreeSet;

use serde_json::json;

use super::tests::{Bucket, Device, P, deck_entity, edit, projection, review};
use super::transport::{HeadWrite, OUTBOX_BATCH_BYTES, OUTBOX_BATCH_SEGMENTS};

const T0: i64 = 1_700_000_000_000;

fn device_id(d: &Device) -> String {
    d.core.sync2_identity(P, T0).unwrap()["device"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// 发件到 [location]（分批、逐批确认），返回水位；只发段，不写 head。
fn upload(d: &Device, bucket: &mut Bucket, location: &str) -> u64 {
    loop {
        let batch = d
            .core
            .sync2_outbox(P, location, None, OUTBOX_BATCH_BYTES, OUTBOX_BATCH_SEGMENTS)
            .unwrap();
        if batch.files.is_empty() {
            return batch.upto;
        }
        for (path, bytes) in batch.files {
            bucket.0.insert(path, bytes);
        }
        let (accepted, mark) = d
            .core
            .sync2_outbox_ack(P, location, &batch.segments)
            .unwrap();
        assert!(accepted);
        if !batch.more {
            return mark;
        }
    }
}

/// 写 head 到 [location]，并按生产两段式删掉可删的旧段。返回是否写了。
fn write_head(d: &Device, bucket: &mut Bucket, location: &str, upto: u64, now: i64) -> bool {
    match d
        .core
        .sync2_head_if_changed(P, location, upto, now, None)
        .unwrap()
    {
        HeadWrite::Written {
            path,
            bytes,
            obsolete,
            gen,
        } => {
            let dir = path.rsplit_once('/').unwrap().0.to_owned();
            bucket.0.insert(path, bytes);
            for p in &obsolete {
                bucket.0.remove(p);
            }
            d.core.sync2_obsolete_ack(P, location, &obsolete).unwrap();
            // 与生产（srs_sync2_round.dart 第 4 步）同样：删本机两代以前的 head。
            bucket.0.retain(|k, _| {
                !(k.starts_with(&format!("{dir}/"))
                    && k.rsplit('/')
                        .next()
                        .and_then(crate::sync2::segment::parse_head_file_name)
                        .is_some_and(|g| g + 2 < gen))
            });
            true
        }
        HeadWrite::Recut => false,
        HeadWrite::Unchanged { .. } => unreachable!("no skip window given"),
    }
}

/// [bucket] 上每份 head 引用的段都在（读者只认 head 列出的段）。
fn missing_referenced(bucket: &Bucket) -> Vec<String> {
    let mut out = Vec::new();
    for (k, v) in bucket.0.iter().filter(|(k, _)| k.contains("/head-")) {
        let h = crate::sync2::segment::Head::decode(v).unwrap();
        let dir = k.rsplit_once('/').unwrap().0;
        for f in h.segment_files() {
            if !bucket.0.contains_key(&format!("{dir}/{f}")) {
                out.push(format!("{k} -> {f}"));
            }
        }
    }
    out
}

/// 作者自检（生产里随一轮的第一批发件带上 `present`）：列 [bucket] 上本机目录交给内核。
fn audit(d: &Device, bucket: &Bucket, location: &str) -> usize {
    let prefix = format!("devices/{}/", device_id(d));
    let present: BTreeSet<String> = bucket
        .0
        .keys()
        .filter_map(|k| k.strip_prefix(&prefix))
        .map(str::to_owned)
        .collect();
    d.core.sync2_audit_own(P, location, &present).unwrap()
}

/// 约 [bytes] 字节、几乎不可压缩的修改记录（让段落在合并的高层、合并后要再切成几段）。
fn bulky(deck: &str, tag: &str, bytes: usize, seed: &mut u64) -> Vec<serde_json::Value> {
    const PIECE: usize = 48 * 1024;
    (0..bytes.div_ceil(PIECE))
        .map(|j| {
            let v: String = (0..PIECE)
                .map(|_| {
                    *seed = seed
                        .wrapping_mul(6364136223846793005)
                        .wrapping_add(1442695040888963407);
                    char::from(b'!' + ((*seed >> 33) % 90) as u8)
                })
                .collect();
            edit("deck", deck, &format!("{tag}-{j}"), json!(v))
        })
        .collect()
}

/// 两个位置的轮次交错：L1 发件确认之后、写 head 之前，本机又写了一批、L2 的发件把它与 L1 已有的几个高层段合并，
/// 合并结果按体积再切成几段——前一段整个落在 L1 的水位以内、名字是新的、从没传到 L1。head 绝不引用它；过了宽限期
/// 旧段删掉之后，新设备只从 L1 也能收齐。
#[test]
fn head_never_references_a_segment_merged_after_the_last_upload() {
    let a = Device::new("gap-a");
    let mut l1 = Bucket::default();
    let mut l2 = Bucket::default();
    let deck = super::config::default_deck_id(P);
    a.apply(
        T0,
        vec![
            deck_entity(&deck),
            edit("deck", &deck, "name", json!("Default")),
        ],
    );
    let mut seed = 7u64;
    let mut recuts = 0;
    for i in 0..4i64 {
        let now = T0 + 1000 * i;
        a.apply(now, bulky(&deck, &format!("a{i}"), 2_300_000, &mut seed));
        let upto = upload(&a, &mut l1, "l1");
        // 交错：L1 确认之后，本机又写了一批，另一个位置的发件在这里跑（同一台设备的另一个进程 / 旧版本未串行的轮次）。
        a.apply(
            now + 1,
            bulky(&deck, &format!("b{i}"), 2_300_000, &mut seed),
        );
        let upto2 = upload(&a, &mut l2, "l2");
        if !write_head(&a, &mut l1, "l1", upto, now) {
            recuts += 1;
        }
        write_head(&a, &mut l2, "l2", upto2, now);
        let missing = missing_referenced(&l1);
        assert!(
            missing.is_empty(),
            "round {i}: L1 head references segments that were never uploaded there: {missing:?}"
        );
    }
    assert!(
        recuts > 0,
        "the interleaving must actually hit a post-ack merge"
    );
    // 过了宽限期，正常轮次（先发后写 head）几代：合并掉的旧段删光，head 仍然只引用在的段。
    for k in 0..4i64 {
        let now = T0 + 2 * super::tests::DAY + 1000 * k;
        let upto = upload(&a, &mut l1, "l1");
        assert!(write_head(&a, &mut l1, "l1", upto, now));
        assert!(missing_referenced(&l1).is_empty());
    }
    let c = Device::new("gap-c");
    c.sync(&mut l1, "l1", T0 + 3 * super::tests::DAY);
    assert_eq!(c.core.sync2_status(P).unwrap()["pending"], 0);
    assert_eq!(projection(&a), projection(&c));
}

/// 位置上已经缺了 head 引用的段（旧版本留下的缺口 / 被误删）：读者的待应用卡住；作者下一轮自检补传，读者收齐。
#[test]
fn author_reuploads_own_segments_missing_from_a_location() {
    let a = Device::new("heal-a");
    let mut bucket = Bucket::default();
    let deck = super::config::default_deck_id(P);
    a.apply(
        T0,
        vec![
            deck_entity(&deck),
            edit("deck", &deck, "name", json!("Default")),
        ],
    );
    // 一个满段（不参与合并）打底，之后每轮一条复习：位置上至少两段，丢掉第一段后后面的都收不了。
    let mut seed = 11u64;
    a.apply(T0, bulky(&deck, "base", 2_800_000, &mut seed));
    a.sync(&mut bucket, "loc", T0);
    for i in 0..6i64 {
        let now = T0 + 1000 * (i + 1);
        a.apply(now, vec![review(&format!("h{i}"), "C", now, 3, "review")]);
        a.sync(&mut bucket, "loc", now);
    }
    // 删掉 head 引用的第一段：之后的段照样可读，读者只能把它们堆在待应用里。
    let dev = device_id(&a);
    let (_, latest) = bucket
        .0
        .iter()
        .filter(|(k, _)| k.starts_with(&format!("devices/{dev}/head-")))
        .max_by_key(|(k, _)| (*k).clone())
        .unwrap();
    let segs = crate::sync2::segment::Head::decode(latest)
        .unwrap()
        .segment_files();
    assert!(segs.len() >= 2, "{segs:?}");
    let lost = format!("devices/{dev}/{}", segs[0]);
    bucket.0.remove(&lost);
    assert!(!missing_referenced(&bucket).is_empty());

    let c = Device::new("heal-c");
    c.sync(&mut bucket, "loc", T0 + 10_000);
    let stuck = c.core.sync2_status(P).unwrap()["pending"].as_u64().unwrap();
    assert!(stuck > 0, "the reader is stuck behind the hole");

    // 作者这一轮：自检登记重传 → 发件补上 → head 照常。
    assert_eq!(audit(&a, &bucket, "loc"), 1);
    a.sync(&mut bucket, "loc", T0 + 11_000);
    assert!(
        bucket.0.contains_key(&lost),
        "the lost segment is uploaded again under the same name"
    );
    assert!(missing_referenced(&bucket).is_empty());
    // 位置完整时自检什么都不登记。
    assert_eq!(audit(&a, &bucket, "loc"), 0);

    c.sync(&mut bucket, "loc", T0 + 12_000);
    assert_eq!(c.core.sync2_status(P).unwrap()["pending"], 0);
    assert_eq!(projection(&a), projection(&c));
}

/// 已经传上去的段里有 [n] 个满段的修改记录压在牌组 DX 上（不参与合并），随后彻底清除 DX：DX 的内容段登记成同名改写。
fn purged_with_restamps(tag: &str, bucket: &mut Bucket) -> Device {
    let a = Device::new(tag);
    let mut seed = 5u64;
    for i in 0..3i64 {
        a.apply(T0 + i, bulky("DX", &format!("p{i}"), 2_800_000, &mut seed));
        a.sync(bucket, "loc", T0 + i);
    }
    a.core.sync2_purge(P, "deck", "DX", T0 + 10).unwrap();
    let restamps: usize = a.rows("SELECT COUNT(*) FROM sync2_rewrites WHERE restamp = 1")[1][0]
        .parse()
        .unwrap();
    assert!(
        restamps >= 3,
        "every content segment of DX is a same-name rewrite: {restamps}"
    );
    a
}

/// 修 c8e02cbb0a 的回归：有重传未完就不写 head 只该挡「位置上缺的段」。彻底清除（以及骨架化）登记的是同名改写——
/// 位置上的旧文件仍是同一个名字、同一条链的合法段——一轮只传得完一部分时 head 照常写（以前交回改切，几百 MB 的
/// 改写要传几轮，这台设备的新操作就几轮没人看得见）。
#[test]
fn same_name_rewrites_do_not_hold_back_the_head() {
    let mut bucket = Bucket::default();
    let a = purged_with_restamps("restamp-a", &mut bucket);
    // 这一轮只来得及传一段（一批一段、字节预算 1）。
    let batch = a.core.sync2_outbox(P, "loc", None, 1, 1).unwrap();
    assert!(batch.more, "the rewrites take more than one batch");
    for (path, bytes) in batch.files {
        bucket.0.insert(path, bytes);
    }
    let (accepted, mark) = a.core.sync2_outbox_ack(P, "loc", &batch.segments).unwrap();
    assert!(accepted);
    let left: usize = a.rows("SELECT COUNT(*) FROM sync2_rewrites WHERE restamp = 1")[1][0]
        .parse()
        .unwrap();
    assert!(left >= 2, "same-name rewrites are still pending: {left}");
    assert!(
        write_head(&a, &mut bucket, "loc", mark, T0 + 11),
        "pending same-name rewrites must not hold back the head"
    );
    assert!(missing_referenced(&bucket).is_empty());
    // 剩下的改写随后几轮传完；新设备收到的与作者一致。
    a.sync(&mut bucket, "loc", T0 + 12);
    assert_eq!(a.rows("SELECT COUNT(*) FROM sync2_rewrites")[1][0], "0");
    let c = Device::new("restamp-c");
    c.sync(&mut bucket, "loc", T0 + 13);
    assert_eq!(c.core.sync2_status(P).unwrap()["pending"], 0);
    assert_eq!(projection(&a), projection(&c));
}

/// 位置上缺了 head 引用的段时照样挡 head——即便这个段同时也登记了同名改写（缺段的登记把它升成缺段）。
#[test]
fn a_missing_segment_still_holds_back_the_head_when_it_is_also_a_same_name_rewrite() {
    let mut bucket = Bucket::default();
    let a = purged_with_restamps("restamp-gap-a", &mut bucket);
    let dev = device_id(&a);
    let (_, latest) = bucket
        .0
        .iter()
        .filter(|(k, _)| k.starts_with(&format!("devices/{dev}/head-")))
        .max_by_key(|(k, _)| (*k).clone())
        .unwrap();
    let segs = crate::sync2::segment::Head::decode(latest)
        .unwrap()
        .segment_files();
    let lost = format!("devices/{dev}/{}", segs[0]);
    bucket.0.remove(&lost);
    assert_eq!(audit(&a, &bucket, "loc"), 1);
    let gaps: usize = a.rows("SELECT COUNT(*) FROM sync2_rewrites WHERE restamp = 0")[1][0]
        .parse()
        .unwrap();
    assert_eq!(
        gaps, 1,
        "the missing segment is registered as a gap even though the purge registered it first"
    );
    let uploaded: u64 = a.rows("SELECT uploaded FROM sync2_locations")[1][0]
        .parse()
        .unwrap();
    assert!(
        !write_head(&a, &mut bucket, "loc", uploaded, T0 + 11),
        "a head must never reference a segment missing from the location"
    );
    a.sync(&mut bucket, "loc", T0 + 12);
    assert!(bucket.0.contains_key(&lost));
    assert!(missing_referenced(&bucket).is_empty());
}
