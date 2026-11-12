//! 位置上旧文件的保留策略只在内核（transport.rs `HEAD_KEEP_GENS` / `sync2_obsolete`）：旧 head 与旧小段出自同一份
//! 清单、同样两段式回执，**段的删除永远不早于最后一份引用它的 head 被删**。
//!
//! 以前「留几代旧 head」写在 Dart（srs_sync2_round.dart 第 4 步，`gen < 当前 - 2`、删了不回执），内核回收旧小段时
//! 只是假设 Dart 已经把引用它的旧 head 删掉了——同一轮里旧小段其实先删，旧 head 删失败也拦不住旧小段（BUG-4323）；
//! 换过身份之后旧身份目录里的 head 再没有人删，旧身份的旧小段却照删（BUG-4324）。

use std::collections::BTreeSet;

use serde_json::json;

use super::tests::{Bucket, DAY, Device, P, deck_entity, edit, listed, review, sweep};
use super::transport::{HEAD_KEEP_GENS, HeadWrite, head_retire_below};
use crate::sync2::segment::{Head, parse_head_file_name};

const T0: i64 = 1_700_000_000_000;

fn device_id(d: &Device) -> String {
    d.core.sync2_identity(P, T0).unwrap()["device"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// 待删表里的旧 head 行（`last = 0`，transport.rs `OBSOLETE_HEAD_ROW`）。
const HEAD_ROWS: &str = "SELECT COUNT(*) FROM sync2_obsolete WHERE last = 0";

fn count(d: &Device, sql: &str) -> usize {
    d.rows(sql)[1][0].parse().unwrap()
}

/// 一轮的发件半边：发件 → 写 head 并传上去。不收尾（什么都不删）。返回 head 的代号。
fn publish(d: &Device, bucket: &mut Bucket, location: &str, now: i64) -> u64 {
    d.core.sync2_identity(P, now).unwrap();
    let upto = d.upload_all(bucket, location);
    let (path, bytes, gen) = d.core.sync2_head(P, location, upto, now).unwrap();
    bucket.0.insert(path, bytes);
    gen
}

/// [bucket] 上 [device] 目录里的 head：`(代号, 相对路径)`，按代号升序。
fn heads_of(bucket: &Bucket, device: &str) -> Vec<(u64, String)> {
    let mut out: Vec<(u64, String)> = listed(bucket, device)
        .into_iter()
        .filter_map(|n| parse_head_file_name(&n).map(|g| (g, format!("devices/{device}/{n}"))))
        .collect();
    out.sort();
    out
}

/// 旧版本 Dart 的规则，冻结在这里（srs_sync2_round.dart 第 4 步，2026-11 之前）：写出代号 `gen` 的 head 之后删
/// `g < gen - 2` 的本机 head。新旧版本的设备共用一个位置时，内核给的清单必须与它是同一条数值规则。
fn legacy_dart_deletes(g: u64, gen: u64) -> bool {
    (g as i64) < (gen as i64) - 2
}

/// 旧版本内核回收旧小段的代号条件（transport.rs `OBSOLETE_KEEP_GENS = 2`，`since_gen + 2 <= gen`）。
fn legacy_kernel_releases(since_gen: u64, gen: u64) -> bool {
    since_gen + 2 <= gen
}

fn heads_in(paths: &[String]) -> Vec<String> {
    paths
        .iter()
        .filter(|p| p.contains("/head-"))
        .cloned()
        .collect()
}

/// [bucket] 上每份 head 引用的段都在（读者只认 head 列出的段，设计 §6.1）。
fn missing_referenced(bucket: &Bucket) -> Vec<String> {
    let mut out = Vec::new();
    for (k, v) in bucket.0.iter().filter(|(k, _)| k.contains("/head-")) {
        let h = Head::decode(v).unwrap();
        let dir = k.rsplit_once('/').unwrap().0;
        for f in h.segment_files() {
            if !bucket.0.contains_key(&format!("{dir}/{f}")) {
                out.push(format!("{k} -> {f}"));
            }
        }
    }
    out
}

/// 保留代数与旧小段多留几代是同一个常量、同一处推导：旧 head 的规则就是旧版本 Dart 的 `g < gen - 2`；旧小段的代号
/// 条件 `since_gen <= head_retire_below(gen)` 恰好是「可能引用它的 head（代号 < since_gen）按规则全都该删了」，也恰好
/// 是旧版本内核的 `since_gen + 2 <= gen`。改 [HEAD_KEEP_GENS] 之前先想清楚新旧版本混用（这里会红）。
#[test]
fn segment_delay_is_derived_from_the_head_retention_rule() {
    assert_eq!(HEAD_KEEP_GENS, 2, "old clients delete heads below gen - 2");
    for gen in 0..40u64 {
        let below = head_retire_below(gen);
        for g in 0..40u64 {
            assert_eq!(g < below, legacy_dart_deletes(g, gen), "head {g} at {gen}");
        }
        for since in 1..40u64 {
            let every_referencing_head_is_retired = (0..since).all(|g| g < below);
            assert_eq!(
                since <= below,
                every_referencing_head_is_retired,
                "segment since {since} at {gen}"
            );
            assert_eq!(
                since <= below,
                legacy_kernel_releases(since, gen),
                "segment since {since} at {gen}"
            );
        }
    }
}

/// 内核给的旧 head 清单 = 旧版本 Dart 的规则；删成功并确认之前每一轮照样再给（head 没变、不写的一轮也给）；
/// 只确认一部分就只移除那一部分。
#[test]
fn old_heads_are_listed_by_the_kernel_until_their_deletion_is_acked() {
    let a = Device::new("rt-a");
    let mut bucket = Bucket::default();
    let dev = device_id(&a);
    let mut gen = 0;
    for i in 0..7 {
        a.apply(
            T0 + i,
            vec![review(&format!("r{i}"), "C", T0 + i, 3, "review")],
        );
        gen = publish(&a, &mut bucket, "loc", T0 + i);
        // 这几轮一个都没删、也没确认：清单是位置上全部该删的旧 head。
        let expected: Vec<String> = heads_of(&bucket, &dev)
            .into_iter()
            .filter(|(g, _)| legacy_dart_deletes(*g, gen))
            .map(|(_, p)| p)
            .collect();
        let got = a
            .core
            .sync2_obsolete(P, "loc", &listed(&bucket, &dev), false, T0 + i)
            .unwrap()
            .delete;
        assert_eq!(heads_in(&got), expected, "round {i}, gen {gen}");
    }
    assert_eq!(gen, 7);
    let all = a
        .core
        .sync2_obsolete(P, "loc", &listed(&bucket, &dev), false, T0 + 10)
        .unwrap()
        .delete;
    assert_eq!(all.len(), 4, "{all:?}");
    assert_eq!(heads_in(&all), all);
    assert!(
        heads_of(&bucket, &dev)
            .iter()
            .rev()
            .take(3)
            .all(|(_, p)| !all.contains(p)),
        "the newest head and the two before it stay"
    );
    // 只删成、确认了前两份：剩下两份留在记录里。
    for p in &all[..2] {
        bucket.0.remove(p);
    }
    assert_eq!(a.core.sync2_obsolete_ack(P, "loc", &all[..2]).unwrap(), 2);
    // head 没变、不写的一轮：照样给出没确认的。
    match a
        .core
        .sync2_head_if_changed(P, "loc", u64::MAX, T0 + 20, Some(DAY))
        .unwrap()
    {
        HeadWrite::Unchanged { .. } => {}
        HeadWrite::Written { .. } | HeadWrite::Recut => panic!("head content did not change"),
    }
    let rest = a
        .core
        .sync2_obsolete(P, "loc", &listed(&bucket, &dev), false, T0 + 20)
        .unwrap()
        .delete;
    assert_eq!(rest, all[2..].to_vec());
    // 列目录暂时列不到其中一份（最终一致）：没确认的照样在清单里——记录在内核，不靠这一次列目录。
    let partial: Vec<String> = listed(&bucket, &dev)
        .into_iter()
        .filter(|n| !rest[0].ends_with(n.as_str()))
        .collect();
    assert_eq!(
        a.core
            .sync2_obsolete(P, "loc", &partial, false, T0 + 21)
            .unwrap()
            .delete,
        rest
    );
    let given = sweep(&a.core, &mut bucket, "loc", T0 + 30);
    assert_eq!(given, rest);
    assert_eq!(count(&a, HEAD_ROWS), 0);
    assert_eq!(
        heads_of(&bucket, &dev)
            .iter()
            .map(|h| h.0)
            .collect::<Vec<_>>(),
        vec![5, 6, 7]
    );
    assert!(
        sweep(&a.core, &mut bucket, "loc", T0 + 31).is_empty(),
        "nothing left to delete"
    );
}

/// 代号是本机全局的：两个位置轮流写，每个位置上的代号不连续，规则只看数值（与旧版本 Dart 相同）。归档位置一份旧
/// head 都不给、也不登记。
#[test]
fn head_generations_are_device_wide_and_archive_locations_keep_every_head() {
    let a = Device::new("rt-s");
    let (mut l1, mut l2, mut arch) = (Bucket::default(), Bucket::default(), Bucket::default());
    let dev = device_id(&a);
    for i in 0..6 {
        a.apply(
            T0 + i,
            vec![review(&format!("r{i}"), "C", T0 + i, 3, "review")],
        );
        for (bucket, location, archive) in [
            (&mut l1, "l1", false),
            (&mut l2, "l2", false),
            (&mut arch, "arch", true),
        ] {
            let gen = publish(&a, bucket, location, T0 + i);
            let expected: Vec<String> = heads_of(bucket, &dev)
                .into_iter()
                .filter(|(g, _)| !archive && legacy_dart_deletes(*g, gen))
                .map(|(_, p)| p)
                .collect();
            let got = a
                .core
                .sync2_obsolete(P, location, &listed(bucket, &dev), archive, T0 + i)
                .unwrap()
                .delete;
            assert_eq!(heads_in(&got), expected, "{location} gen {gen}");
            for p in &got {
                bucket.0.remove(p);
            }
            a.core.sync2_obsolete_ack(P, location, &got).unwrap();
        }
    }
    // 三个位置共用一个代号计数：每个位置上隔两个代号才有一份，只留得下最新的那一份。
    assert_eq!(heads_of(&l1, &dev).len(), 1);
    assert_eq!(heads_of(&l2, &dev).len(), 1);
    assert_eq!(heads_of(&arch, &dev).len(), 6, "archive keeps every head");
    assert_eq!(count(&a, HEAD_ROWS), 0);
}

/// 以列得到的最新本机 head 为准：刚写的 head 还列不到（列目录最终一致）时按位置上实际最新的那份算——宁可晚删，任何
/// 时候都不把列到的最新 head 删掉；位置上的代号比本机记的新（库回退）时不按它算。
#[test]
fn retention_is_measured_from_the_newest_head_actually_listed() {
    let a = Device::new("rt-l");
    let mut bucket = Bucket::default();
    let dev = device_id(&a);
    for i in 0..6 {
        a.apply(
            T0 + i,
            vec![review(&format!("r{i}"), "C", T0 + i, 3, "review")],
        );
        publish(&a, &mut bucket, "loc", T0 + i);
    }
    let all = heads_of(&bucket, &dev);
    assert_eq!(
        all.iter().map(|h| h.0).collect::<Vec<_>>(),
        (1..=6).collect::<Vec<_>>()
    );
    let name = |p: &str| p.rsplit('/').next().unwrap().to_owned();
    // 最新的两份（5、6）都还列不到：按 4 算，只有 1 该删。
    let lagging: Vec<String> = all[..4].iter().map(|h| name(&h.1)).collect();
    assert_eq!(
        a.core
            .sync2_obsolete(P, "loc", &lagging, false, T0 + 10)
            .unwrap()
            .delete,
        vec![all[0].1.clone()]
    );
    // 一份本机 head 都列不到：什么都不给（登记过的那一份留在记录里，等列得到 head 的一轮再给）。
    assert_eq!(
        a.core
            .sync2_obsolete(P, "loc", &[], false, T0 + 11)
            .unwrap()
            .delete,
        Vec::<String>::new()
    );
    assert_eq!(count(&a, HEAD_ROWS), 1);
    // 位置上有一份代号比本机记的还新的本机 head（本机库回退过）：不拿它当基准，也不删它。
    let mut ahead: Vec<String> = all.iter().map(|h| name(&h.1)).collect();
    ahead.push("head-000000000099-deadbeef.json".to_owned());
    let got = a
        .core
        .sync2_obsolete(P, "loc", &ahead, false, T0 + 12)
        .unwrap()
        .delete;
    assert_eq!(
        got,
        all[..3].iter().map(|h| h.1.clone()).collect::<Vec<_>>()
    );
}

/// 段的删除永远不早于最后一份引用它的 head 被删。每一轮隔两天（旧小段的宽限期在代号够之前就过了——以前恰好在这种
/// 节奏下，旧小段与引用它的旧 head 在同一轮交出去，旧小段先删），旧 head 的删除成批失败：
/// - 内核交出一个段的那一刻，位置上没有任何一份 head 引用它；
/// - 任何时刻位置上留着的每一份 head 引用的段都在；
/// - 删除恢复正常后旧 head、旧小段全部删光，不留记录。
#[test]
fn a_segment_is_never_deleted_before_the_last_head_referencing_it() {
    let a = Device::new("rt-inv");
    let mut bucket = Bucket::default();
    let dev = device_id(&a);
    let deck = super::config::default_deck_id(P);
    a.apply(
        T0,
        vec![
            deck_entity(&deck),
            edit("deck", &deck, "name", json!("Default")),
        ],
    );
    let mut withheld_passes = 0;
    let mut clean_rounds = 0;
    let mut deleted_segments = 0;
    let mut failed_head_deletes = 0;
    for step in 0..72i64 {
        let now = T0 + step * 2 * DAY;
        // 后 8 轮不再写新操作（不再有新的合并），删除也不再失败：收敛到干净。
        let settling = step >= 64;
        if !settling {
            a.apply(
                now,
                vec![review(&format!("r{step}"), "C", now, 3, "review")],
            );
        }
        let gen = publish(&a, &mut bucket, "loc", now);
        let below = head_retire_below(gen);
        // 旧 head 的删除每 8 轮里连着失败 4 轮；段的删除从不失败（对「段先于 head 被删」最不利的组合）。
        let heads_fail = !settling && (step / 4) % 2 == 1;
        // 生产的收尾（srs_sync2_round.dart `srsSweepObsolete`）：清单全部删成、内核说 `again` 就再问一次。
        for pass in 0..2 {
            let out = a
                .core
                .sync2_obsolete(P, "loc", &listed(&bucket, &dev), false, now)
                .unwrap();
            let referenced: BTreeSet<String> = heads_of(&bucket, &dev)
                .iter()
                .flat_map(|(_, p)| {
                    Head::decode(&bucket.0[p])
                        .unwrap()
                        .segment_files()
                        .into_iter()
                        .map(|f| format!("devices/{dev}/{f}"))
                })
                .collect();
            for p in out.delete.iter().filter(|p| p.contains("/seg-")) {
                assert!(
                    !referenced.contains(p),
                    "step {step}: {p} is handed out while a head on the location still references it"
                );
            }
            for (g, p) in heads_of(&bucket, &dev) {
                if out.delete.contains(&p) {
                    assert!(
                        legacy_dart_deletes(g, gen),
                        "step {step}: head {g} at {gen}"
                    );
                }
            }
            // 代号与宽限期都够的旧小段（旧版本内核在这一轮交出去的那些）：没交出来的只能是引用它的旧 head 还没确认
            // 删掉，内核用 `again` 说明。
            let ripe = count(
                &a,
                &format!(
                    "SELECT COUNT(*) FROM sync2_obsolete WHERE last > 0 AND since_gen + 2 <= {gen} AND since_at + {DAY} <= {now}"
                ),
            );
            let given = out.delete.iter().filter(|p| p.contains("/seg-")).count();
            assert!(given <= ripe);
            assert_eq!(out.again, given < ripe, "step {step} pass {pass}");
            if out.again {
                withheld_passes += 1;
            }
            let mut done = Vec::new();
            let mut failed = false;
            for p in out.delete {
                if p.contains("/head-") && heads_fail {
                    failed_head_deletes += 1;
                    failed = true;
                    continue;
                }
                if p.contains("/seg-") {
                    deleted_segments += 1;
                }
                bucket.0.remove(&p);
                done.push(p);
            }
            a.core.sync2_obsolete_ack(P, "loc", &done).unwrap();
            assert_eq!(
                missing_referenced(&bucket),
                Vec::<String>::new(),
                "step {step}: every head left on the location can still be read in full"
            );
            if !out.again || failed {
                break;
            }
            assert_eq!(pass, 0, "step {step}: a second ask settles the round");
        }
        if !heads_fail {
            // 删除不失败的一轮结束时，位置上与旧版本（Dart `g < gen - 2` + 旧内核 `since_gen + 2 <= gen`、满宽限期）
            // 这一轮删完之后是同一个样子：时机没有变，只是段排在引用它的 head 之后。
            assert!(
                heads_of(&bucket, &dev)
                    .iter()
                    .all(|(g, _)| !legacy_dart_deletes(*g, gen)),
                "step {step}"
            );
            assert_eq!(
                count(
                    &a,
                    &format!(
                        "SELECT COUNT(*) FROM sync2_obsolete WHERE last = 0 OR (since_gen + 2 <= {gen} AND since_at + {DAY} <= {now})"
                    ),
                ),
                0,
                "step {step}: {below}"
            );
            clean_rounds += 1;
        }
    }
    assert!(
        withheld_passes > 0 && clean_rounds > 8,
        "the overlap this test is about never happened"
    );
    assert!(
        failed_head_deletes > 0 && deleted_segments > 8,
        "{deleted_segments}"
    );
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_obsolete"), 0);
    assert_eq!(heads_of(&bucket, &dev).len(), 3);
    let segments = listed(&bucket, &dev)
        .iter()
        .filter(|n| n.starts_with("seg-"))
        .count();
    assert_eq!(
        segments,
        count(&a, "SELECT COUNT(*) FROM sync2_segments"),
        "only the current cut is left on the location"
    );
}

/// 换过身份（设计 §7.3）之后，旧身份目录里的文件不归本机删：那里留着的 head 本机不再更新、不再删，同一身份的另一个
/// 安装还在往里写。这里 a 在位置 L 上合并了小段、head 还没写（这一轮断在 head 之前），随后在位置 M 上与孪生分叉、换
/// 身份；以前这批旧小段在新身份写出两代 head、过了宽限期后照删，而 L 上旧身份留着的那份 head 引用的正是它们。
#[test]
fn files_under_a_rotated_away_identity_are_never_handed_out() {
    let a = Device::new("rt-fa");
    let (mut l, mut m) = (Bucket::default(), Bucket::default());
    let old = device_id(&a);
    let unstamped = |d: &Device| {
        count(
            d,
            "SELECT COUNT(*) FROM sync2_obsolete WHERE since_gen IS NULL",
        )
    };
    let mut i = 0;
    loop {
        i += 1;
        assert!(i < 200, "no compaction happened");
        a.apply(
            T0 + i,
            vec![review(&format!("r{i}"), "C", T0 + i, 3, "review")],
        );
        a.core.sync2_identity(P, T0 + i).unwrap();
        let upto = a.upload_all(&mut l, "L");
        if unstamped(&a) > 0 {
            break;
        }
        let (path, bytes, _) = a.core.sync2_head(P, "L", upto, T0 + i).unwrap();
        l.0.insert(path, bytes);
        sweep(&a.core, &mut l, "L", T0 + i);
    }
    let under_old: BTreeSet<String> =
        l.0.keys()
            .filter(|k| k.starts_with(&format!("devices/{old}/")))
            .cloned()
            .collect();
    assert_eq!(missing_referenced(&l), Vec::<String>::new());
    // 同一身份的两个安装在 M 上各写各的：a 判分叉、换身份。
    let twin = Device::copy_of(&a, "rt-ft");
    twin.apply(T0 + 1000, vec![review("rt", "C", T0 + 1000, 4, "review")]);
    twin.sync(&mut m, "M", T0 + 1000);
    a.apply(T0 + 2000, vec![review("ra", "C", T0 + 2000, 3, "review")]);
    for k in 0..3 {
        a.sync(&mut m, "M", T0 + 2000 + k);
    }
    let new = device_id(&a);
    assert_ne!(new, old, "a took a new identity");
    // a 以新身份回到 L：写够代号、过了宽限期。
    for k in 0..8i64 {
        let now = T0 + (k + 1) * 2 * DAY;
        a.apply(now, vec![review(&format!("n{k}"), "C", now, 3, "review")]);
        a.sync(&mut l, "L", now);
        let handed = a
            .core
            .sync2_obsolete(P, "L", &listed(&l, &new), false, now)
            .unwrap()
            .delete;
        assert!(
            handed.iter().all(|p| !under_old.contains(p)),
            "round {k}: a file written under the old identity is handed out: {handed:?}"
        );
    }
    // 旧目录另按当场的证据清（former.rs，同步助手与生产一样在收尾后跑它）：被盖过的旧 head 可以删，段一个不删，
    // 留下的 head 引用的段都在。
    let newest_old = heads_of(&l, &old)
        .last()
        .expect("the newest old head stays")
        .1
        .clone();
    for p in &under_old {
        let kept = !p.contains("/head-") || p.ends_with(&newest_old);
        assert!(!kept || l.0.contains_key(p), "{p} was deleted");
    }
    assert_eq!(heads_of(&l, &old).len(), 1, "covered old heads are gone");
    assert_eq!(missing_referenced(&l), Vec::<String>::new());
    assert!(heads_of(&l, &new).len() <= 3);
}
