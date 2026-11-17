use super::*;
use crate::gen4::location::{MediaRoot, meta4};
use crate::gen4::op::tests::id;
use crate::store::gen4::ingest::Settle;
use crate::store::gen4::inherit::tests::{NOW, OLD, key_of, landed, old_log, old_seg, peer};
use crate::store::gen4::native::tests::ready;
use crate::store::gen4::receive::{Defer, Receiver};
use crate::store::gen4::schema::open_in_memory;
use crate::sync2::keys::CollectionKey;
use crate::sync2::segment::{SegmentHeader, relay_file_name};

const LOC: &str = "loc-1";

fn entry(path: &str, size: u64, modified: i64) -> OldRootEntry {
    OldRootEntry {
        path: path.to_owned(),
        size,
        modified: Some(modified),
    }
}

fn seg_path(h: &SegmentHeader) -> String {
    format!("{DEVICES_DIR}/{}/{}", h.device.text(), h.file_name())
}

/// 一批收旧根（位置目录 `dir`）的 [segs]（按 [scan] 的待读列表的顺序配路径），在同一个事务里收尾；[settle] = 这一批
/// 是这一轮的收尾批（按 [listing] 重算、全部有结论才记指纹）。回 (逐段结论, 记了指纹没有)。[crash] = 收尾之后这一笔
/// 回滚（崩溃 / 调用方后面的步骤出错）。
fn batch(
    t: &Truth<'_>,
    col: i64,
    (scan, listing): (&OldRootScan, &[OldRootEntry]),
    segs: &[(&str, &[u8])],
    key: Option<&CollectionKey>,
    (settle, fenced, at, crash): (bool, bool, i64, bool),
) -> Result<(Vec<Taken>, bool), String> {
    t.tx(|t| {
        let mut r = Receiver::open(t, col, Settle::Incremental)?;
        let mut out = Vec::new();
        for (_, s) in segs {
            out.push(r.legacy(s, "dir", key)?);
        }
        let paths: Vec<String> = segs.iter().map(|(p, _)| (*p).to_owned()).collect();
        let settle = settle.then_some(OldRootSettle {
            dir: "dir",
            listing,
            fenced,
            at,
        });
        let (_, settled) = r.finish_oldroot(LOC, &scan.fp, &paths, settle)?;
        if crash {
            return Err("crash after settling".to_owned());
        }
        Ok((out, settled))
    })
}

/// 一轮只有一批（收尾批）：[segs] 依次配 [scan] 待读列表里的路径。
fn round(
    t: &Truth<'_>,
    col: i64,
    (scan, listing): (&OldRootScan, &[OldRootEntry]),
    segs: &[&[u8]],
    key: Option<&CollectionKey>,
    (fenced, at, crash): (bool, i64, bool),
) -> Result<(Vec<Taken>, bool), String> {
    let pairs: Vec<(&str, &[u8])> = scan
        .fetch
        .iter()
        .map(String::as_str)
        .zip(segs.iter().copied())
        .collect();
    assert_eq!(pairs.len(), segs.len(), "one path per segment");
    batch(
        t,
        col,
        (scan, listing),
        &pairs,
        key,
        (true, fenced, at, crash),
    )
}

/// D21：只有协议 1 旧根（`v2/`）的位置明确拒绝、给机读码；别的代照常认（`v2/` 与新旧根并存时按新旧根认）。
#[test]
fn only_a_protocol1_root_is_refused() {
    let refused = check_root(&["v2"]).unwrap_err();
    assert_eq!(refused.code, ERR_PROTOCOL1_ROOT);
    assert!(refused.message.contains("not affected"));
    // G8-7c：升级位置要在另一台仍是 3.x 的设备上做；本机库已封存，装回 3.x 打不开（交接 §第四波 G8-7c）。
    assert!(refused.message.contains("another device still running 3.x"));
    assert!(refused.message.contains("do not downgrade this device"));
    assert_eq!(
        check_root(&["v2", "media"]).unwrap_err().code,
        ERR_PROTOCOL1_ROOT
    );
    assert_eq!(check_root(&[]), Ok(RootKind::Empty));
    assert_eq!(check_root(&["v2", "v3"]), Ok(RootKind::Protocol3));
    assert_eq!(check_root(&["v3"]), Ok(RootKind::Protocol3));
    assert_eq!(check_root(&["v2", "v3", "v4"]), Ok(RootKind::Protocol4));
    assert_eq!(check_root(&["v4"]), Ok(RootKind::Protocol4));
    assert_eq!(root_kind(&["v2"]), RootKind::Protocol1Only);
}

/// 清单没变不重读；变了只读本机还没有的段（段尾记着链值、标签对得上的跳过，转发件同理）；有段要等、围栏没写好时
/// 不记指纹，下一轮照样重来。
#[test]
fn the_old_root_is_rescanned_only_when_its_listing_changes() {
    let conn = open_in_memory().unwrap();
    let t = Truth::new(&conn);
    let col = ready(&t);
    peer(&t, col, id(OLD), key_of(OLD).public());
    let (ops, chains) = old_log(12);
    let (h1, s1) = old_seg(&ops, &chains, (1, 6), None);
    let (h2, s2) = old_seg(&ops, &chains, (7, 10), None);
    let (h3, s3) = old_seg(&ops, &chains, (11, 12), None);
    let tomb_seg = format!(
        "{DEVICES_DIR}/{}/{}",
        tombstone_device("dir").text(),
        h1.file_name()
    );
    let mut listing = vec![
        entry(META_FILE, 80, 1),
        entry(
            &format!(
                "{DEVICES_DIR}/{}/head-000000000003-0a0b0c0d.json",
                id(OLD).text()
            ),
            500,
            1,
        ),
        entry(&seg_path(&h2), s2.len() as u64, 1),
        entry(&seg_path(&h1), s1.len() as u64, 1),
        entry(&tomb_seg, 10, 1),
        entry(&format!("{DEVICES_DIR}/{}/notes.txt", id(OLD).text()), 3, 1),
        entry(&format!("{DEVICES_DIR}/not-an-id/{}", h1.file_name()), 3, 1),
    ];
    let scan = t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing)).unwrap();
    assert!(scan.changed && scan.read_meta);
    assert_eq!(scan.fetch, vec![seg_path(&h1), seg_path(&h2)]);
    assert_eq!(
        round(
            &t,
            col,
            (&scan, &listing),
            &[&s1, &s2],
            None,
            (true, NOW, false)
        ),
        Ok((vec![landed(6, 0, 0), landed(4, 0, 0)], true))
    );
    // 没变：什么都不读。
    let again = t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing)).unwrap();
    assert!(!again.changed && !again.read_meta && again.fetch.is_empty());
    // 同名重写（修改时刻变了）、多了一个转发件：本机都有了，跳过。
    listing[2].modified = Some(2);
    let rly = format!(
        "{DEVICES_DIR}/{}/{}",
        id(OLD).text(),
        relay_file_name(&h2.file_name())
    );
    listing.push(entry(&rly, 99, 2));
    let scan = t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing)).unwrap();
    assert!(scan.changed);
    assert!(scan.fetch.is_empty());
    assert_eq!(scan.skipped, 3);
    // 旧客户端又写了一段：只读它。要等的不记指纹。
    listing.push(entry(&seg_path(&h3), s3.len() as u64, 3));
    let scan = t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing)).unwrap();
    assert_eq!(scan.fetch, vec![seg_path(&h3)]);
    let sealed = old_seg(&ops, &chains, (11, 12), Some(&CollectionKey([9; 32]))).1;
    assert_eq!(
        round(
            &t,
            col,
            (&scan, &listing),
            &[&sealed],
            None,
            (true, NOW, false)
        ),
        Ok((vec![Taken::Deferred(Defer::Undecryptable)], false))
    );
    // 这一批交的路径与收的段对不上：报错、整笔回滚。
    assert!(
        t.tx(|t| {
            let r = Receiver::open(t, col, Settle::Incremental)?;
            r.finish_oldroot(LOC, &scan.fp, &scan.fetch, None)
        })
        .is_err()
    );
    // 收尾批什么都没交：要读的那一段在这一轮名下没有结论（上面要等的不算），不记。
    assert_eq!(
        round(&t, col, (&scan, &listing), &[], None, (true, NOW, false)),
        Ok((vec![], false))
    );
    assert_eq!(
        round(
            &t,
            col,
            (&scan, &listing),
            &[&s3],
            None,
            (false, NOW, false)
        ),
        Ok((vec![landed(2, 0, 0)], false))
    );
    let scan = t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing)).unwrap();
    assert!(scan.changed && scan.fetch.is_empty());
    assert_eq!(
        round(
            &t,
            col,
            (&scan, &listing),
            &[],
            None,
            (true, NOW + 1, false)
        ),
        Ok((vec![], true))
    );
    assert!(
        !t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing))
            .unwrap()
            .changed
    );
    // 另一个位置的旧根（被并入的集合的目录名不同）：来源集合不同，本机这条日志不算它的，全读；`dir` 的墓碑设备在
    // 那里只是一个普通目录，也读（读到的段集合不对，`Receiver::legacy` 会拒）。
    let other = t
        .tx(|t| t.oldroot_scan(col, "loc-2", "other", &listing))
        .unwrap();
    assert_eq!(other.fetch.len(), 5);
    assert!(other.fetch.contains(&tomb_seg));
    assert_eq!(t.tx(|t| t.audit(col)), Ok(12));
}

/// 指纹只和这一批的落库一起提交：收尾之后这一笔回滚（崩溃），指纹与落库一起没了，下一轮清单不变也照样把段读回来；
/// 提交了才算核对过。
#[test]
fn the_fingerprint_commits_with_the_landing_or_not_at_all() {
    let conn = open_in_memory().unwrap();
    let t = Truth::new(&conn);
    let col = ready(&t);
    peer(&t, col, id(OLD), key_of(OLD).public());
    let (ops, chains) = old_log(6);
    let (h, s) = old_seg(&ops, &chains, (1, 6), None);
    let listing = [entry(&seg_path(&h), s.len() as u64, 1)];
    let scan = t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing)).unwrap();
    assert_eq!(scan.fetch, vec![seg_path(&h)]);
    assert!(round(&t, col, (&scan, &listing), &[&s], None, (true, NOW, true)).is_err());
    assert_eq!(t.oldroot_fp(col, LOC), Ok(None));
    assert_eq!(t.tx(|t| t.audit(col)), Ok(0));
    let again = t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing)).unwrap();
    assert_eq!(again, scan);
    assert_eq!(
        round(&t, col, (&again, &listing), &[&s], None, (true, NOW, false)),
        Ok((vec![landed(6, 0, 0)], true))
    );
    assert_eq!(t.tx(|t| t.audit(col)), Ok(6));
    assert!(
        !t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing))
            .unwrap()
            .changed
    );
}

/// 有段要等时这一轮不记指纹、下一轮重读；但已经落了库的段（段尾记着链值、标签对得上）下一轮不再读，重读的只有
/// 还没结论的那几段。
#[test]
fn a_deferred_segment_does_not_refetch_what_already_landed() {
    let conn = open_in_memory().unwrap();
    let t = Truth::new(&conn);
    let col = ready(&t);
    peer(&t, col, id(OLD), key_of(OLD).public());
    let (ops, chains) = old_log(12);
    let (h1, s1) = old_seg(&ops, &chains, (1, 6), None);
    let (h2, _) = old_seg(&ops, &chains, (7, 12), None);
    let sealed = old_seg(&ops, &chains, (7, 12), Some(&CollectionKey([9; 32]))).1;
    let listing = [
        entry(&seg_path(&h1), s1.len() as u64, 1),
        entry(&seg_path(&h2), sealed.len() as u64, 1),
    ];
    let scan = t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing)).unwrap();
    assert_eq!(scan.fetch, vec![seg_path(&h1), seg_path(&h2)]);
    assert_eq!(
        round(
            &t,
            col,
            (&scan, &listing),
            &[&s1, &sealed],
            None,
            (true, NOW, false)
        ),
        Ok((
            vec![landed(6, 0, 0), Taken::Deferred(Defer::Undecryptable)],
            false
        ))
    );
    let again = t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing)).unwrap();
    assert!(again.changed);
    assert_eq!(again.fetch, vec![seg_path(&h2)]);
    assert_eq!(again.skipped, 1);
}

/// 切片与累计（G8-7c）：一轮的段分几批（几个事务）收，每批把结论记到这一轮名下；收尾批什么都不交，也能凭前面几批的
/// 结论记下指纹——包括重扫时还会列出来的段（坏段：落不了库，重扫照样要读）。中途崩溃的那一批结论随它回滚；清单在
/// 中途变了，前面几批的结论不算。
#[test]
fn slices_of_one_round_add_up_to_a_recorded_fingerprint() {
    let conn = open_in_memory().unwrap();
    let t = Truth::new(&conn);
    let col = ready(&t);
    peer(&t, col, id(OLD), key_of(OLD).public());
    let (ops, chains) = old_log(12);
    let (h1, s1) = old_seg(&ops, &chains, (1, 6), None);
    let (h2, s2) = old_seg(&ops, &chains, (7, 12), None);
    // 一个坏段（另一条区间、内容截断）：永远落不了库，重扫照样列它。
    let (h3, s3) = old_seg(&ops, &chains, (1, 12), None);
    let bad = &s3[..s3.len() / 2];
    let (p1, p2, p3) = (seg_path(&h1), seg_path(&h2), seg_path(&h3));
    let mut listing = vec![
        entry(&p1, s1.len() as u64, 1),
        entry(&p2, s2.len() as u64, 1),
        entry(&p3, s3.len() as u64, 1),
    ];
    let scan = t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing)).unwrap();
    assert_eq!(scan.fetch.len(), 3);
    let lst = listing.clone();
    let one = |segs: &[(&str, &[u8])], settle: bool, crash: bool| {
        batch(
            &t,
            col,
            (&scan, &lst),
            segs,
            None,
            (settle, true, NOW, crash),
        )
    };
    // 第一批：坏段，提交。第二批：第一段，崩溃回滚。
    assert!(matches!(
        one(&[(&p3, bad)], false, false).unwrap().0[..],
        [Taken::Rejected(_)]
    ));
    assert!(one(&[(&p1, &s1)], false, true).is_err());
    // 收尾批只交第二段：第一段没有结论（那一批回滚了），不记。
    assert_eq!(
        one(&[(&p2, &s2)], true, false),
        Ok((vec![landed(0, 0, 6)], false))
    );
    // 再交第一段（第二段随之投出）、提交；收尾批什么都不交：坏段的结论在更早那一批里，记下指纹。
    assert_eq!(one(&[(&p1, &s1)], false, false).map(|r| r.1), Ok(false));
    assert_eq!(t.tx(|t| t.audit(col)), Ok(12));
    assert_eq!(one(&[], true, false), Ok((vec![], true)));
    assert!(
        !t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing))
            .unwrap()
            .changed
    );
    // 记完就清掉累计的结论。
    assert_eq!(
        t.tx(|t| t.oldroot_concluded(col, LOC, &scan.fp, &p3)),
        Ok(false)
    );
    // 清单变了（坏段被旧客户端重写）：上一轮的结论不算，收尾批不交它就不记。
    listing[2].modified = Some(2);
    let next = t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing)).unwrap();
    assert!(next.fetch.contains(&p3), "{:?}", next.fetch);
    assert_eq!(
        batch(
            &t,
            col,
            (&next, &listing),
            &[],
            None,
            (true, true, NOW, false)
        ),
        Ok((vec![], false))
    );
}

/// 围栏：没有、被改过（旧客户端重建的 `minReader 3`）就写；这一轮没读到 meta 不动它；墓碑 head 不在或大小不对就写。
#[test]
fn fences_are_put_back_when_missing_or_changed() {
    let v4 = meta4(&id(0xc0), None, MediaRoot::V3).unwrap();
    let fence = fence3("dir", &v4).unwrap();
    let (tpath, tbytes) = tombstone_head("dir");
    let trel = tpath.strip_prefix("v3/").unwrap().to_owned();
    let meta_path = format!("{OLD_ROOT}/{META_FILE}");
    assert_eq!(
        fence_writes("dir", &v4, Meta3::Absent, &[]),
        Ok(vec![
            (meta_path.clone(), fence.clone()),
            (tpath.clone(), tbytes.clone())
        ])
    );
    let ok = [
        entry(META_FILE, fence.len() as u64, 1),
        entry(&trel, tbytes.len() as u64, 1),
    ];
    assert_eq!(
        fence_writes("dir", &v4, Meta3::Read(&fence), &ok),
        Ok(vec![])
    );
    let reopened = br#"{"collection":"x","minReader":3,"v":3}"#;
    assert_eq!(
        fence_writes("dir", &v4, Meta3::Read(reopened), &ok),
        Ok(vec![(meta_path, fence.clone())])
    );
    let shrunk = [entry(&trel, 1, 2)];
    assert_eq!(
        fence_writes("dir", &v4, Meta3::Unread, &shrunk),
        Ok(vec![(tpath, tbytes)])
    );
    assert!(fence_writes("dir", b"{}", Meta3::Absent, &[]).is_err());
}
