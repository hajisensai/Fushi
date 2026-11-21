use serde_json::json;

use super::*;
use crate::gen4::golden;
use crate::gen4::head::{HeadError, PrevIdentity};
use crate::gen4::op::tests::id;
use crate::sync2::segment::{self as v3, PROTOCOL as V3_PROTOCOL};

const DIR: &str = "0193a1b2-0000-7000-8000-00000000beef";

fn kdf() -> Value {
    json!({"check": "9f86d081884c7d65", "m": 19456, "p": 1, "salt": "c2FsdHNhbHRzYWx0", "t": 2})
}

fn coll() -> Id {
    Id::parse("0194b0c1-1111-7222-8333-444455556666").unwrap()
}

fn heritage_header() -> HeritageHeader {
    HeritageHeader {
        encrypted: false,
        collection: coll(),
        source: collection_of(DIR),
        device: id(0x0d),
        uploader: id(0xa1),
        author_key: None,
        t_version: 1,
        first: 1,
        last: 4321,
        prev_chain: [0; 32],
        last_chain: [0x5a; 32],
    }
}

fn native_header() -> NativeHeader {
    NativeHeader {
        encrypted: true,
        collection: coll(),
        device: id(0xb2),
        first: 13,
        last: 40,
        prev_chain: [0x11; 32],
        last_chain: [0xc3; 32],
    }
}

fn head4() -> Head4 {
    Head4 {
        gen: 7,
        protocol: PROTOCOL,
        min_reader: MIN_READER,
        collection: coll(),
        device: id(0xb2),
        public: [9; 32],
        seq: 0,
        chain: [0x7e; 32],
        segs: Vec::new(),
        ack: Vv::new(),
        digest: String::new(),
        at_ms: 0,
        name: String::new(),
        loc: String::new(),
        seal: String::new(),
        derive: 1,
        prev: None::<PrevIdentity>,
        ext: None,
        extra: Default::default(),
    }
}

// ---------------------------------------------------------------- meta

#[test]
fn meta4_is_a_frozen_pure_function() {
    let plain = meta4(&coll(), None, MediaRoot::V4).unwrap();
    golden(
        "meta4_plain",
        &plain,
        "7b22636f6c6c656374696f6e223a2230313934623063312d313131312d373232322d383333332d343434343535353536363636222c22666d74223a2266757368692d7372732d6d6574612f34222c226d65646961223a227634222c226d696e526561646572223a342c2276223a347d",
    );
    assert_eq!(
        std::str::from_utf8(&plain).unwrap(),
        r#"{"collection":"0194b0c1-1111-7222-8333-444455556666","fmt":"fushi-srs-meta/4","media":"v4","minReader":4,"v":4}"#
    );
    let sealed = meta4(&collection_of(DIR), Some(&kdf()), MediaRoot::V3).unwrap();
    golden(
        "meta4_kdf",
        &sealed,
        "7b22636f6c6c656374696f6e223a2265626339343361662d663639332d353632342d393566612d373665363433353131623938222c22666d74223a2266757368692d7372732d6d6574612f34222c226b6466223a7b22636865636b223a2239663836643038313838346337643635222c226d223a31393435362c2270223a312c2273616c74223a226332467364484e686248527a59577830222c2274223a327d2c226d65646961223a227633222c226d696e526561646572223a342c2276223a347d",
    );
    // 两台设备各自算：字节相同（没有时间戳、没有随机量）。
    assert_eq!(
        meta4(&collection_of(DIR), Some(&kdf()), MediaRoot::V3).unwrap(),
        sealed
    );
    // kdf 只收对象；非整数数值不是规范 JSON。
    assert!(meta4(&coll(), Some(&json!("x")), MediaRoot::V4).is_err());
    assert!(meta4(&coll(), Some(&json!({"m": 1.5})), MediaRoot::V4).is_err());
}

#[test]
fn check_meta4_compares_fields() {
    let want = meta4(&coll(), Some(&kdf()), MediaRoot::V3).unwrap();
    assert_eq!(check_meta4(&want, &want), Ok(()));
    // 位置上的字节不是规范形、字段相同：照过（按字段比，不按字节）。
    let spaced =
        serde_json::to_vec_pretty(&serde_json::from_slice::<Value>(&want).unwrap()).unwrap();
    assert_ne!(spaced, want);
    assert_eq!(check_meta4(&spaced, &want), Ok(()));
    // 别的设备写的是明文、媒体根不同。
    let other = meta4(&coll(), None, MediaRoot::V4).unwrap();
    assert_eq!(
        check_meta4(&other, &want),
        Err(MetaMismatch::Fields(vec!["kdf".into(), "media".into()]))
    );
    // 多出一个本版本不写的键也算不一致。
    let mut extra: Map<String, Value> = serde_json::from_slice(&want).unwrap();
    extra.insert("createdAt".into(), json!(1));
    assert_eq!(
        check_meta4(&serde_json::to_vec(&extra).unwrap(), &want),
        Err(MetaMismatch::Fields(vec!["createdAt".into()]))
    );
    // 更新的版本写的：先报需要升级，不论 fmt。
    let mut newer = extra.clone();
    newer.insert("minReader".into(), json!(5));
    newer.insert("fmt".into(), json!("fushi-srs-meta/5"));
    assert_eq!(
        check_meta4(&serde_json::to_vec(&newer).unwrap(), &want),
        Err(MetaMismatch::NeedsUpgrade { min_reader: 5 })
    );
    // minReader 写成浮点也认得：5.0 → 5，4.5 向上取 5；不论 fmt 换没换。
    for (mr, fmt) in [
        (json!(5.0), "fushi-srs-meta/5"),
        (json!(4.5), META_FMT),
        (json!(5.0), META_FMT),
    ] {
        let mut m = extra.clone();
        m.insert("minReader".into(), mr.clone());
        m.insert("fmt".into(), json!(fmt));
        assert_eq!(
            check_meta4(&serde_json::to_vec(&m).unwrap(), &want),
            Err(MetaMismatch::NeedsUpgrade { min_reader: 5 }),
            "{mr} {fmt}"
        );
    }
    // 4.0 不比本版本新：落到逐字段比（值类型不同也算不一致）。
    let mut same = serde_json::from_slice::<Map<String, Value>>(&want).unwrap();
    same.insert("minReader".into(), json!(4.0));
    assert_eq!(
        check_meta4(&serde_json::to_vec(&same).unwrap(), &want),
        Err(MetaMismatch::Fields(vec!["minReader".into()]))
    );
    // 旧根围栏、协议 3 的旧 meta、坏字节都不是新根 meta。
    let fence = fence3(DIR, &want).unwrap();
    assert!(matches!(
        check_meta4(&fence, &want),
        Err(MetaMismatch::NotMeta(_))
    ));
    let old = br#"{"collection":"x","createdAt":1,"minReader":3,"v":3}"#;
    assert!(matches!(
        check_meta4(old, &want),
        Err(MetaMismatch::NotMeta(_))
    ));
    assert!(matches!(
        check_meta4(b"[1]", &want),
        Err(MetaMismatch::NotMeta(_))
    ));
    assert!(matches!(
        check_meta4(b"{", &want),
        Err(MetaMismatch::NotMeta(_))
    ));
}

// ---------------------------------------------------------------- 围栏与墓碑

#[test]
fn fence3_is_a_function_of_dir_and_meta() {
    let v4 = meta4(&collection_of(DIR), Some(&kdf()), MediaRoot::V3).unwrap();
    let fence = fence3(DIR, &v4).unwrap();
    golden(
        "fence3_kdf",
        &fence,
        "7b22636f6c6c656374696f6e223a2265626339343361662d663639332d353632342d393566612d373665363433353131623938222c226b6466223a7b22636865636b223a2239663836643038313838346337643635222c226d223a31393435362c2270223a312c2273616c74223a226332467364484e686248527a59577830222c2274223a327d2c226d696e526561646572223a342c226d6f766564223a227634222c2276223a337d",
    );
    let v: Value = serde_json::from_slice(&fence).unwrap();
    // 协议 3 集合标识（存量的现值）、kdf 原样、minReader 比协议 3 新、指向新根。
    assert_eq!(v["collection"], json!(collection_of(DIR).text()));
    assert_eq!(v["kdf"], kdf());
    assert!(v["minReader"].as_u64().unwrap() > u64::from(V3_PROTOCOL));
    assert_eq!(v["moved"], json!("v4"));
    assert_eq!(v["v"], json!(3));
    assert_eq!(fence3(DIR, &v4).unwrap(), fence);
    // 明文位置：没有 kdf 键。
    let plain = fence3(DIR, &meta4(&coll(), None, MediaRoot::V4).unwrap()).unwrap();
    assert_eq!(
        std::str::from_utf8(&plain).unwrap(),
        format!(
            r#"{{"collection":"{}","minReader":4,"moved":"v4","v":3}}"#,
            collection_of(DIR).text()
        )
    );
    // 输入必须是新根 meta。
    assert!(fence3(DIR, &fence).is_err());
    assert!(fence3(DIR, b"nope").is_err());
}

#[test]
fn tombstone_head_is_a_frozen_protocol3_head() {
    let (path, bytes) = tombstone_head(DIR);
    let dev = tombstone_device(DIR);
    assert_eq!(
        path,
        format!("v3/devices/{}/head-000000000001-00000000.json", dev.text())
    );
    golden(
        "tombstone_head",
        &bytes,
        "7b2261636b223a7b7d2c226174223a302c22636861696e223a2230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030222c22636f6c6c656374696f6e223a2265626339343361662d663639332d353632342d393566612d373665363433353131623938222c22646576696365223a2266653931333133372d303562392d353366632d613161312d383434326566616238343564222c22646967657374223a22222c2267656e223a312c226d696e526561646572223a342c226e616d65223a2266757368692d73727320746f6d6273746f6e6520287570677261646520726571756972656429222c22707562223a2231313839316664663831313336616265623933643336363636666133396461323639333866623431646137343537346636656535653266663466663036386666222c227365676d656e7473223a5b5d2c22736571223a302c22736967223a223030326135316635356136396563393665343863646566663632623639633866393836663362633966646161393335396534313031373332373765636164386365326263373132626261646363363839386637363064343634323738653439326666323766653033656639356261646138363063613162316338386634663066222c2276223a347d",
    );
    // 逐字节是 dir 的纯函数；换个 dir 就是另一台墓碑设备、另一个集合。
    assert_eq!(tombstone_head(DIR), (path.clone(), bytes.clone()));
    let (p2, b2) = tombstone_head("other-dir");
    assert_ne!(p2, path);
    assert_ne!(b2, bytes);
    // 协议 3 的解码器读得懂：minReader 4、协议 3 集合标识、无段、公开钥匙。
    let h = Head::decode(&bytes).unwrap();
    assert_eq!(h.min_reader, MIN_READER);
    assert!(h.min_reader > V3_PROTOCOL);
    assert_eq!(h.collection, collection_of(DIR));
    assert_eq!(h.device, dev);
    assert_eq!((h.seq, h.segments.len(), h.gen), (0, 0, 1));
    assert_eq!(h.public, tombstone_key().public());
    assert_eq!(
        v3::parse_head_file_name(path.rsplit('/').next().unwrap()),
        Some(1)
    );
    // 协议 4 的解码器拒它。
    assert_eq!(Head4::decode(&bytes), Err(HeadError::NotProtocol4));
    // 守卫放行它的路径。
    assert_eq!(guard_location_path(&path), Ok(()));
}

/// develop 上冻结的协议 3 `plan` 读到墓碑：整轮报需要升级、不拉任何东西、不记这台设备。
/// 墓碑必须带协议 3 的集合标识——`plan` 先按集合过滤，集合不对就走不到升级判断。
#[test]
fn protocol3_plan_reports_upgrade_on_tombstone() {
    use crate::store::sync2::tests::{Device, P};
    let a = Device::new("g8-tomb");
    let collection = a.core.sync2_identity(P, 1_700_000_000_000).unwrap()["collection"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        collection,
        collection_of(P).text(),
        "dir = profile uid for existing collections"
    );
    let before = a.rows("SELECT count(*) FROM sync2_devices");
    let (_, tomb) = tombstone_head(P);
    let plan = a.core.sync2_plan_at(P, &[tomb], Some("loc")).unwrap();
    assert_eq!(plan["needsUpgrade"], json!(true), "{plan}");
    assert_eq!(plan["fetch"], json!([]));
    assert_eq!(a.rows("SELECT count(*) FROM sync2_devices"), before);
    // 别的目录的墓碑：集合不同，被过滤掉，不触发升级（这正是墓碑必须用本集合标识的原因）。
    let (_, foreign) = tombstone_head("some-other-dir");
    let plan = a.core.sync2_plan_at(P, &[foreign], Some("loc")).unwrap();
    assert_eq!(plan["needsUpgrade"], json!(false), "{plan}");
}

// ---------------------------------------------------------------- 跳转提示

#[test]
fn joined_hint_roundtrips_and_rejects_other_forms() {
    let b = joined4(&coll(), DIR).unwrap();
    assert_eq!(
        std::str::from_utf8(&b).unwrap(),
        format!(r#"{{"dir":"{DIR}","into":"{}"}}"#, coll().text())
    );
    assert_eq!(parse_joined4(&b), Some((coll(), DIR.to_owned())));
    let upper = format!(
        r#"{{"dir":"{DIR}","into":"{}"}}"#,
        coll().text().to_uppercase()
    );
    assert_eq!(parse_joined4(upper.as_bytes()), None);
    let spaced = format!(r#"{{"dir": "{DIR}","into":"{}"}}"#, coll().text());
    assert_eq!(parse_joined4(spaced.as_bytes()), None);
    let extra = format!(r#"{{"dir":"{DIR}","into":"{}","x":1}}"#, coll().text());
    assert_eq!(parse_joined4(extra.as_bytes()), None);
    for bad in ["", ".", "..", "a/b", "a\\b"] {
        assert!(joined4(&coll(), bad).is_err(), "{bad:?}");
    }
}

// ---------------------------------------------------------------- 文件名

#[test]
fn file_names_are_frozen() {
    let h = heritage_header();
    let name = heritage_file_name(&h);
    assert_eq!(
        name,
        format!(
            "hrt-{}-{}-000000000001-000000004321-5a5a5a5a.bin",
            &collection_of(DIR).text()[..8],
            id(0x0d).text()
        )
    );
    assert_eq!(
        relay_name(&native_header()),
        "rly-000000000013-000000000040-c3c3c3c3.bin"
    );
    assert_eq!(relay_head_name(&head4()), "rhd-000000000007-7e7e7e7e.json");
    assert_eq!(head4().file_name(), "head-000000000007-7e7e7e7e.json");
    assert_eq!(
        manifest_file_name(3, "0a1b2c3d"),
        "mf-000000000003-0a1b2c3d.bin"
    );
    let loc = Id::parse("0194b0c1-2222-7abc-9def-0123456789ab").unwrap();
    assert_eq!(loc_path(&loc), "loc/0194b0c1-2222-7abc-9def-0123456789ab");
    // 新前缀都不是协议 3 认的段 / head 名（互联 host 只把 seg- 当作者自写的段）。
    for n in [
        name.as_str(),
        "rhd-000000000007-7e7e7e7e.json",
        "mf-000000000003-0a1b2c3d.bin",
        "rly-000000000013-000000000040-c3c3c3c3.bin",
    ] {
        assert_eq!(v3::parse_segment_file_name(n), None, "{n}");
        assert_eq!(v3::parse_head_file_name(n), None, "{n}");
    }
}

fn all_files() -> Vec<V4File> {
    let h = heritage_header();
    let n = native_header();
    let hd = head4();
    let loc = Id::parse("0194b0c1-2222-7abc-9def-0123456789ab").unwrap();
    vec![
        V4File::Meta,
        V4File::Joined,
        V4File::Loc(loc),
        V4File::Head {
            device: hd.device,
            gen: hd.gen,
            tag: chain_tag(&hd.chain),
        },
        V4File::Seg {
            device: n.device,
            first: n.first,
            last: n.last,
            tag: chain_tag(&n.last_chain),
        },
        V4File::Relay {
            author: n.device,
            first: n.first,
            last: n.last,
            tag: chain_tag(&n.last_chain),
        },
        V4File::RelayHead {
            author: hd.device,
            gen: hd.gen,
            tag: chain_tag(&hd.chain),
        },
        V4File::Heritage {
            uploader: h.uploader,
            src8: collection_of(DIR).text()[..8].to_owned(),
            old_device: h.device,
            first: h.first,
            last: h.last,
            tag: chain_tag(&h.last_chain),
        },
        V4File::Manifest {
            device: id(0xa1),
            gen: 3,
            tag: "0a1b2c3d".into(),
        },
        V4File::Profile { device: id(0xa1) },
    ]
}

#[test]
fn v4_paths_roundtrip() {
    let files = all_files();
    let paths: Vec<String> = files.iter().map(V4File::path).collect();
    assert_eq!(
        paths,
        vec![
            "meta.json".to_owned(),
            "joined.json".into(),
            "loc/0194b0c1-2222-7abc-9def-0123456789ab".into(),
            device_path(&head4().device, &head4().file_name()),
            device_path(&native_header().device, &native_header().file_name()),
            device_path(&native_header().device, &relay_name(&native_header())),
            device_path(&head4().device, &relay_head_name(&head4())),
            device_path(&id(0xa1), &heritage_file_name(&heritage_header())),
            device_path(&id(0xa1), "mf-000000000003-0a1b2c3d.bin"),
            device_path(&id(0xa1), "profile.json"),
        ]
    );
    for (f, p) in files.iter().zip(&paths) {
        assert_eq!(parse_v4_path(p).as_ref(), Some(f), "{p}");
        // 新根顶层与写路径都过守卫。
        assert_eq!(guard_location_path(&format!("v4/{p}")), Ok(()), "{p}");
    }
    assert_eq!(
        files[7].device(),
        Some(id(0xa1)),
        "heritage lives under the uploader"
    );
    assert_eq!(files[0].device(), None);
}

#[test]
fn v4_paths_reject_non_canonical_forms() {
    let dev = id(0xa1).text();
    let old = id(0x0d).text();
    let bad = [
        // 大小写、UUID 不带连字符、位数不对、+ 号、空段。
        format!(
            "devices/{}/head-000000000001-0a1b2c3d.json",
            dev.to_uppercase()
        ),
        format!(
            "devices/{}/head-000000000001-0a1b2c3d.json",
            dev.replace('-', "")
        ),
        format!("devices/{dev}/head-000000000001-0A1B2C3D.json"),
        format!("devices/{dev}/head-1-0a1b2c3d.json"),
        format!("devices/{dev}/head-+00000000001-0a1b2c3d.json"),
        format!("devices/{dev}/head-000000000001-0a1b2c3.json"),
        format!("devices/{dev}/seg-000000000002-000000000001-0a1b2c3d.bin"),
        format!("devices/{dev}/seg-000000000000-000000000001-0a1b2c3d.bin"),
        format!("devices/{dev}/seg-000000000001-000000000001-0a1b2c3d.json"),
        format!("devices/{dev}/rly-1-2-0a1b2c3d.bin"),
        format!("devices/{dev}/rhd-000000000001-0a1b2c3d.bin"),
        format!("devices/{dev}/mf-000000000001-xyzxyzxy.bin"),
        format!(
            "devices/{dev}/hrt-0a1b2c3d-{}-000000000001-000000000002-0a1b2c3d.bin",
            old.to_uppercase()
        ),
        format!("devices/{dev}/hrt-0a1b2c3-{old}-000000000001-000000000002-0a1b2c3d.bin"),
        format!("devices/{dev}/hrt-0a1b2c3d-{old}-000000000002-000000000001-0a1b2c3d.bin"),
        format!("devices/{dev}/hrt-0a1b2c3d{old}-000000000001-000000000002-0a1b2c3d.bin"),
        format!("devices/{dev}/hrt-0a1b2c3d-{old}-000000000001-000000000002-0a1b2c3d-x.bin"),
        // 目录层数不对、未知名字、临时文件、Profile 大小写。
        format!("devices/{dev}/x/head-000000000001-0a1b2c3d.json"),
        format!("devices/{dev}"),
        format!("devices/{dev}/"),
        format!("devices/{dev}/head-000000000001-0a1b2c3d.json.tmp"),
        format!("devices/{dev}/Profile.json"),
        format!("devices/{dev}/batch-0000000001"),
        // loc 只收 UUIDv7 的规范文本。
        format!("loc/{}", id(0xa1).text()),
        "loc/0194B0C1-2222-7ABC-9DEF-0123456789AB".to_owned(),
        "loc/0194b0c1-2222-7abc-9def-0123456789ab/x".to_owned(),
        "loc/0194b0c1-2222-6abc-9def-0123456789ab".to_owned(),
        "loc/0194b0c1-2222-7abc-cdef-0123456789ab".to_owned(),
        // 顶层与非 ASCII。
        "Meta.json".to_owned(),
        "/meta.json".to_owned(),
        "media/abc".to_owned(),
        "cursor".to_owned(),
        "profile.json".to_owned(),
        format!(
            "devices/{dev}/hrt-0a1b2c3d-{}é-000000000001-000000000002-0a1b2c3d.bin",
            &old[..35]
        ),
        String::new(),
    ];
    for p in &bad {
        assert_eq!(parse_v4_path(p), None, "{p}");
    }
    // 测试用的 id() 不是 v7：上面那条 loc 负例确实因版本被拒。
    assert!(!is_v7(&id(0xa1)));
}

// ---------------------------------------------------------------- 名字守卫

#[test]
fn name_guard_blocks_old_writer_folder_names() {
    // v3.0.1 旧事件同步（sync_files.dart：srsBatchName / srsSnapshotName / srsCursorName / srsProbeName）
    // 与 v3.3.0 旧 linker（_readInfo 读 <写入者>/profile.json）认的名字。
    for n in [
        "cursor",
        "probe",
        "profile.json",
        "batch-0000000001",
        "batch-",
        "batch-x",
        "snapshot-0000000042",
        "snapshot-",
        "Cursor",
        "PROFILE.JSON",
        "Batch-0000000001",
    ] {
        assert!(!top_level_name_allowed(n), "{n}");
        assert_eq!(
            guard_location_path(&format!("v4/{n}")),
            Err(ForbiddenName(format!("v4/{n}")))
        );
        assert!(guard_location_path(&format!("v3/{n}")).is_err(), "{n}");
        assert!(guard_location_path(&format!("v4/{n}/x")).is_err(), "{n}");
    }
    // 新旧根顶层实际用的名字都放行；设备目录里的 profile.json 不是顶层。
    for n in [
        META_FILE,
        JOINED_FILE,
        LOC_DIR,
        DEVICES_DIR,
        "media",
        "media-e",
        "cursors",
        "batch",
        "probe.json",
    ] {
        assert!(top_level_name_allowed(n), "{n}");
    }
    assert_eq!(
        guard_location_path(&format!("v4/devices/{}/profile.json", id(1).text())),
        Ok(())
    );
    assert_eq!(guard_location_path("v4/meta.json"), Ok(()));
    assert_eq!(guard_location_path("v3/meta.json"), Ok(()));
    assert_eq!(guard_location_path("v4"), Ok(()));
    // 根名不分大小写、反斜杠与空段都按同一路径看。
    for p in [
        "V4/cursor",
        "V3/Probe",
        "v4\\cursor",
        "v3\\batch-1",
        "v4//cursor",
        "/v4/profile.json",
        "V4\\Snapshot-1\\x",
    ] {
        assert_eq!(
            guard_location_path(p),
            Err(ForbiddenName(p.to_owned())),
            "{p}"
        );
    }
    assert_eq!(guard_location_path("V4/meta.json"), Ok(()));
    assert_eq!(guard_location_path("v4\\devices"), Ok(()));
    // 别的根不归守卫管（v2 有自己的魔数行围栏）。
    assert_eq!(guard_location_path("v2/cursor"), Ok(()));
    assert_eq!(guard_location_path("cursor"), Ok(()));
}
