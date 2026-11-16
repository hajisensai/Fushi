use super::*;
use crate::gen4::location::{MediaRoot, meta4};
use crate::gen4::op::tests::id;
use crate::store::gen4::inherit::tests::{
    NOW, OLD, key_of, landed, old_log, old_seg, peer, scavenge,
};
use crate::store::gen4::native::tests::ready;
use crate::store::gen4::receive::Defer;
use crate::store::gen4::schema::open_in_memory;
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

/// D21：只有协议 1 旧根（`v2/`）的位置明确拒绝、给机读码；别的代照常认（`v2/` 与新旧根并存时按新旧根认）。
#[test]
fn only_a_protocol1_root_is_refused() {
    let refused = check_root(&["v2"]).unwrap_err();
    assert_eq!(refused.code, ERR_PROTOCOL1_ROOT);
    assert!(refused.message.contains("not affected"));
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
    let (taken, _) = scavenge(&t, col, "dir", &[&s1, &s2], None);
    assert_eq!(taken, vec![landed(6, 0, 0), landed(4, 0, 0)]);
    assert_eq!(
        t.tx(|t| t.oldroot_settle(col, LOC, &scan, &taken, true, NOW)),
        Ok(true)
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
    let waiting = [Taken::Deferred(Defer::Undecryptable)];
    assert_eq!(
        t.tx(|t| t.oldroot_settle(col, LOC, &scan, &waiting, true, NOW)),
        Ok(false)
    );
    assert!(
        t.tx(|t| t.oldroot_settle(col, LOC, &scan, &[], true, NOW))
            .is_err()
    );
    let (taken, _) = scavenge(&t, col, "dir", &[&s3], None);
    assert_eq!(
        t.tx(|t| t.oldroot_settle(col, LOC, &scan, &taken, false, NOW)),
        Ok(false)
    );
    let scan = t.tx(|t| t.oldroot_scan(col, LOC, "dir", &listing)).unwrap();
    assert!(scan.changed && scan.fetch.is_empty());
    assert_eq!(
        t.tx(|t| t.oldroot_settle(col, LOC, &scan, &[], true, NOW + 1)),
        Ok(true)
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
