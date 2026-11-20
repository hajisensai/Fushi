//! `media.rs` 的测试：每条不变量一个（含失败路径、崩溃后自愈、两个连接 / 两个线程并发、迁移播种）。

use std::collections::BTreeSet;

use rusqlite::Connection;

use super::*;
use crate::gen4::location::{V4File, parse_v4_path};
use crate::gen4::manifest::{PLAIN_FOLDER, Section};
use crate::store::gen4::schema;
use crate::store::gen4::truth::{Peer, TRUST_PENDING};

const P: &str = crate::store::sync2::tests::P;
const LOC: &str = "loc-a";
const SEALED: &str = "media-e/ab12";
/// 测试里的本机墙钟（各测试的 HLC 墙钟都远小于它；超前的用 `NOW + MAX_AHEAD_MS + …`）。
const NOW: i64 = 10_000;

fn id(b: u8) -> Id {
    Id([b; 16])
}

fn coll() -> Id {
    id(0xc0)
}

fn marker() -> Id {
    id(0x10)
}

fn markers() -> BTreeSet<Id> {
    [marker(), id(0x11)].into_iter().collect()
}

fn key_of(dev: u8) -> DeviceKey {
    DeviceKey::from_seed(&[dev; 32])
}

fn hlc(wall: i64, dev: u8) -> Hlc {
    Hlc {
        wall,
        logical: 0,
        device: id(dev),
    }
}

/// 一台新代设备：库、集合号，以及它认识的设备公钥（[peers]）。
struct Dev {
    conn: Connection,
    col: i64,
    me: u8,
}

impl Dev {
    fn new(me: u8, peers: &[u8]) -> Dev {
        let conn = schema::open_in_memory().unwrap();
        let col = init(&conn, me, peers);
        Dev { conn, col, me }
    }

    fn t(&self) -> Truth<'_> {
        Truth::new(&self.conn)
    }

    fn record(&self, facts: &[([u8; 32], MediaState)], listed: bool, wall: i64) -> Recorded {
        record(
            &self.t(),
            self.col,
            LOC,
            PLAIN_FOLDER,
            facts,
            listed,
            hlc(wall, self.me),
        )
        .unwrap()
    }

    fn build(&self, own: &[u64]) -> Option<Built> {
        build(
            &self.t(),
            self.col,
            LOC,
            marker(),
            id(self.me),
            &key_of(self.me),
            own,
        )
        .unwrap()
    }

    fn ingest(&self, b: &Built) -> Result<Ingested, IngestError> {
        let (dev, gen, tag) = named(b);
        ingest(
            &self.t(),
            self.col,
            LOC,
            &markers(),
            &dev,
            gen,
            &tag,
            &b.bytes,
            NOW,
        )
    }

    fn known(&self) -> MediaKnown {
        known(&self.t(), self.col, LOC, PLAIN_FOLDER).unwrap()
    }

    fn pending(&self) -> i64 {
        pending_count(&self.t(), self.col).unwrap()
    }

    /// `media_at` 的全部 (键, 哈希, 状态, HLC)。
    fn dump(&self) -> Vec<(String, Vec<u8>, i64, String)> {
        self.conn
            .prepare("SELECT loc_key, sha, state, hlc FROM media_at ORDER BY loc_key, sha")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }
}

fn init(conn: &Connection, me: u8, peers: &[u8]) -> i64 {
    let t = Truth::new(conn);
    t.tx(|t| {
        let col = t.bind(P, &coll(), "dir")?;
        for d in peers.iter().chain([&me]) {
            t.set_peer(
                col,
                &Peer {
                    device: id(*d),
                    public: key_of(*d).public(),
                    name: None,
                    ext: None,
                    head_gen: None,
                    first_seen: None,
                },
            )?;
        }
        Ok(col)
    })
    .unwrap()
}

/// 从文件名解出 (作者, 代号, 标签)：走真实的路径解析（`parse_v4_path`）。
fn named(b: &Built) -> (Id, u64, String) {
    let path = crate::gen4::location::device_path(&b.manifest.device, &b.name);
    match parse_v4_path(&path) {
        Some(V4File::Manifest { device, gen, tag }) => (device, gen, tag),
        other => panic!("{path}: {other:?}"),
    }
}

fn sha(b: u8) -> [u8; 32] {
    [b; 32]
}

#[test]
fn presence_keys_round_trip_and_match_the_protocol_3_form() {
    assert_eq!(presence_key("L", "media").unwrap(), "L/media#sha256");
    assert_eq!(
        presence_key("a/b", SEALED).unwrap(),
        "a/b/media-e/ab12#sha256"
    );
    for (l, f) in [
        ("L", "media"),
        ("a/b", SEALED),
        ("x/media", "media"),
        ("x/media-e", "media-e/k"),
    ] {
        let k = presence_key(l, f).unwrap();
        assert_eq!(parse_key(&k), Some((l, f)), "{k}");
    }
    for k in [
        "L/media", // 协议 3 按名字存的旧键
        "L/other#sha256",
        "/media#sha256",
        "media#sha256",
        "L/media-e/#sha256",
        "L/x/fp#sha256",
        "L/media-e/a/b#sha256",
    ] {
        assert_eq!(parse_key(k), None, "{k}");
    }
    assert!(presence_key("", "media").is_err());
    assert!(presence_key("L", "../media").is_err());
    let h = Hlc {
        wall: -3,
        logical: 7,
        device: id(0xab),
    };
    assert_eq!(parse_hlc_text(&hlc_text(&h)).unwrap(), h);
    for bad in [
        "1:2",
        "1:2:zz",
        "01:2:abababab-abab-abab-abab-abababababab",
        "1:2:ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB",
        "1:2:abababababababababababababababab",
        "1:-1:abababab-abab-abab-abab-abababababab",
    ] {
        assert!(parse_hlc_text(bad).is_err(), "{bad}");
    }
}

/// 本机观察：只写变了的；HLC 不大于现有的不写（D18 下会输，写了就和别人分叉）；同一哈希两种状态整批拒。
#[test]
fn recording_writes_only_changes_that_would_win() {
    let a = Dev::new(0xa1, &[]);
    let r = a.record(
        &[(sha(1), MediaState::Present), (sha(2), MediaState::Absent)],
        false,
        100,
    );
    assert_eq!((r.written, r.unchanged, r.lifted), (2, 0, 0));
    // 同一事实再记：不变。
    let r = a.record(
        &[(sha(1), MediaState::Present), (sha(1), MediaState::Present)],
        false,
        200,
    );
    assert_eq!((r.written, r.unchanged, r.lifted), (0, 1, 0));
    // 改成可疑，但调用方给的 HLC 比现有的旧：观察在读到现有那条之后，盖到它之上写下（不丢）。
    let r = a.record(&[(sha(1), MediaState::Suspect)], false, 50);
    assert_eq!((r.written, r.unchanged, r.lifted), (1, 0, 1));
    assert_eq!(
        fact(&a.t(), a.col, LOC, PLAIN_FOLDER, &sha(1)).unwrap(),
        Some(Fact {
            state: MediaState::Suspect,
            hlc: Hlc {
                wall: 100,
                logical: 1,
                device: id(0xa1)
            }
        })
    );
    let r = a.record(
        &[(sha(1), MediaState::Suspect), (sha(3), MediaState::Present)],
        true,
        300,
    );
    assert_eq!((r.written, r.unchanged, r.lifted), (1, 1, 0));
    assert_eq!(
        a.known(),
        MediaKnown {
            seeded: true,
            present: vec![sha(3)],
            absent: vec![sha(2)],
            suspect: vec![sha(1)],
        }
    );
    assert_eq!(
        fact(&a.t(), a.col, LOC, PLAIN_FOLDER, &sha(1))
            .unwrap()
            .unwrap()
            .hlc,
        Hlc {
            wall: 100,
            logical: 1,
            device: id(0xa1)
        },
        "unchanged state keeps its fact"
    );
    assert_eq!(
        fact(&a.t(), a.col, LOC, PLAIN_FOLDER, &sha(9)).unwrap(),
        None
    );
    // 别的目录 / 别的位置互不相干。
    assert_eq!(
        known(&a.t(), a.col, LOC, SEALED).unwrap(),
        MediaKnown::default()
    );
    assert_eq!(
        known(&a.t(), a.col, "loc-b", PLAIN_FOLDER).unwrap(),
        MediaKnown::default()
    );
    let before = a.dump();
    let err = record(
        &a.t(),
        a.col,
        LOC,
        PLAIN_FOLDER,
        &[(sha(5), MediaState::Present), (sha(5), MediaState::Absent)],
        false,
        hlc(400, 0xa1),
    )
    .unwrap_err();
    assert!(err.contains("two states"), "{err}");
    assert!(record(&a.t(), a.col, LOC, "nope", &[], false, hlc(1, 1)).is_err());
    assert_eq!(a.dump(), before);
}

/// 发：清单验得过、文件名走真实解析器；代号压过本机已发出的与位置上已有的；签名钥匙与本机记录不符时拒。
#[test]
fn building_signs_a_manifest_readers_accept() {
    let a = Dev::new(0xa1, &[]);
    assert_eq!(a.build(&[]), None);
    a.record(&[(sha(1), MediaState::Present)], true, 100);
    record(
        &a.t(),
        a.col,
        LOC,
        SEALED,
        &[(sha(2), MediaState::Absent)],
        false,
        hlc(101, 0xa1),
    )
    .unwrap();
    // 别的位置的待发不进这一份（含前缀相同、带 `/` 的位置 ID）。
    record(
        &a.t(),
        a.col,
        "loc-a/x",
        PLAIN_FOLDER,
        &[(sha(3), MediaState::Present)],
        false,
        hlc(102, 0xa1),
    )
    .unwrap();
    record(
        &a.t(),
        a.col,
        "loc-ab",
        PLAIN_FOLDER,
        &[(sha(4), MediaState::Present)],
        false,
        hlc(103, 0xa1),
    )
    .unwrap();
    let b = a.build(&[4, 2]).unwrap();
    assert_eq!(b.manifest.gen, 5);
    let (dev, gen, tag) = named(&b);
    assert_eq!((dev, gen), (id(0xa1), 5));
    assert_eq!(tag, tag_of(&b.bytes));
    let m = open(&b.bytes)
        .unwrap()
        .verify(&key_of(0xa1).public())
        .unwrap();
    assert_eq!(m, b.manifest);
    assert_eq!(m.collection, coll());
    assert_eq!(m.loc, marker());
    assert_eq!(m.sections.len(), 2);
    assert!(m.sections[PLAIN_FOLDER].listed);
    assert_eq!(m.sections[PLAIN_FOLDER].entries.len(), 1);
    assert_eq!(
        m.sections[SEALED].entries[&sha(2)].state,
        MediaState::Absent
    );
    // build 只读。
    assert_eq!(a.pending(), 4);
    // 钥匙不对。
    let e = build(&a.t(), a.col, LOC, marker(), id(0xa1), &key_of(0x99), &[]).unwrap_err();
    assert!(e.contains("signing key"), "{e}");
    // 没绑定的集合。
    assert!(build(&a.t(), 999, LOC, marker(), id(0xa1), &key_of(0xa1), &[]).is_err());
}

/// 传成功后只清「仍是那一条」的待发：打包之后又改写的（本连接或别的连接）照旧待发；可重放。
#[test]
fn publishing_clears_only_what_was_shipped() {
    let dir = crate::store::sync2::tests::tempdir::new("g4-media-pub");
    let path = dir.0.join("srs4.db");
    let c1 = schema::open(&path).unwrap();
    let col = init(&c1, 0xa1, &[]);
    let c2 = schema::open(&path).unwrap();
    let (t1, t2) = (Truth::new(&c1), Truth::new(&c2));
    record(
        &t1,
        col,
        LOC,
        PLAIN_FOLDER,
        &[(sha(1), MediaState::Present), (sha(2), MediaState::Present)],
        true,
        hlc(100, 0xa1),
    )
    .unwrap();
    let b = build(&t1, col, LOC, marker(), id(0xa1), &key_of(0xa1), &[])
        .unwrap()
        .unwrap();
    // 上传期间，另一个连接把 sha 2 改成不在。
    record(
        &t2,
        col,
        LOC,
        PLAIN_FOLDER,
        &[(sha(2), MediaState::Absent)],
        false,
        hlc(200, 0xa1),
    )
    .unwrap();
    assert_eq!(mark_published(&t1, col, LOC, &b.manifest).unwrap(), 1);
    assert_eq!(pending_count(&t1, col).unwrap(), 1);
    assert_eq!(mark_published(&t1, col, LOC, &b.manifest).unwrap(), 0);
    assert_eq!(seen_gens(&t2, col, LOC, &id(0xa1)).unwrap(), vec![1]);
    let next = build(&t2, col, LOC, marker(), id(0xa1), &key_of(0xa1), &[])
        .unwrap()
        .unwrap();
    assert_eq!(next.manifest.gen, 2);
    assert_eq!(next.manifest.len(), 1);
    // listed 已发出，不再带。
    assert!(!next.manifest.sections[PLAIN_FOLDER].listed);
    assert_eq!(
        next.manifest.sections[PLAIN_FOLDER].entries[&sha(2)].state,
        MediaState::Absent
    );
}

/// 崩溃：清单传上去了、没来得及 mark_published。下一轮收到自己的那份就自愈（不必重发）；直接再发也只是多一份重复。
#[test]
fn a_crash_after_upload_heals_from_the_location() {
    let a = Dev::new(0xa1, &[]);
    a.record(
        &[(sha(1), MediaState::Present), (sha(2), MediaState::Absent)],
        true,
        100,
    );
    let b = a.build(&[]).unwrap();
    // 「崩溃」：没有 mark_published。重启后位置上列出了 gen 1。
    assert_eq!(a.pending(), 2);
    let again = a.build(&[1]).unwrap();
    assert_eq!(
        again.manifest.gen, 2,
        "never reuses a gen seen on the location"
    );
    let got = a.ingest(&b).unwrap();
    assert_eq!(
        (got.covered, got.applied, got.older, got.listed),
        (2, 0, 0, 1)
    );
    assert_eq!(a.pending(), 0);
    assert_eq!(a.build(&[1]), None);
    assert_eq!(seen_gens(&a.t(), a.col, LOC, &id(0xa1)).unwrap(), vec![1]);
}

/// 两台设备经清单对齐；「不在」压过更早的「在」（D18，不取并集）；收到的最大 HLC 交给调用方吸收。
#[test]
fn two_devices_converge_and_absence_is_not_lost() {
    let a = Dev::new(0xa1, &[0xb2]);
    let b = Dev::new(0xb2, &[0xa1]);
    a.record(
        &[(sha(1), MediaState::Present), (sha(2), MediaState::Present)],
        true,
        100,
    );
    let ma = a.build(&[]).unwrap();
    mark_published(&a.t(), a.col, LOC, &ma.manifest).unwrap();
    let got = b.ingest(&ma).unwrap();
    assert_eq!((got.applied, got.listed), (2, 1));
    assert_eq!(got.seen.max_hlc, Some(hlc(100, 0xa1)));
    assert!(got.seen.ahead.is_empty());
    assert!(b.known().seeded);
    assert_eq!(
        b.pending(),
        0,
        "facts that came from the location are not re-sent"
    );
    // b 发现 sha 1 被外部删了。
    b.record(&[(sha(1), MediaState::Absent)], false, 150);
    let mb = b.build(&[]).unwrap();
    assert!(
        !mb.manifest.sections[PLAIN_FOLDER].listed,
        "someone already listed it"
    );
    let got = a.ingest(&mb).unwrap();
    assert_eq!(got.applied, 1);
    assert_eq!(a.known(), b.known());
    assert_eq!(a.known().absent, vec![sha(1)]);
    // 旧的「在」再来一遍（重收 a 的 gen 1 在别的库上）不会把「不在」盖回去。
    let c = Dev::new(0xc3, &[0xa1, 0xb2]);
    c.ingest(&mb).unwrap();
    let got = c.ingest(&ma).unwrap();
    assert_eq!((got.applied, got.older), (1, 1));
    assert_eq!(c.known(), a.known());
}

/// 合并与收到的顺序无关：三份清单按 6 种顺序收进三个新库，表逐行相同。
#[test]
fn ingest_order_does_not_matter() {
    let a = Dev::new(0xa1, &[]);
    let b = Dev::new(0xb2, &[]);
    let c = Dev::new(0xc3, &[]);
    a.record(
        &[(sha(1), MediaState::Present), (sha(2), MediaState::Present)],
        true,
        100,
    );
    b.record(
        &[(sha(1), MediaState::Absent), (sha(3), MediaState::Suspect)],
        false,
        200,
    );
    c.record(
        &[(sha(2), MediaState::Absent), (sha(3), MediaState::Present)],
        false,
        150,
    );
    let ms = [
        a.build(&[]).unwrap(),
        b.build(&[]).unwrap(),
        c.build(&[]).unwrap(),
    ];
    let orders: [[usize; 3]; 6] = [
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0],
    ];
    let mut dumps = Vec::new();
    for o in orders {
        let r = Dev::new(0xee, &[0xa1, 0xb2, 0xc3]);
        for i in o {
            r.ingest(&ms[i]).unwrap();
        }
        dumps.push((r.dump(), r.known()));
    }
    assert!(dumps.windows(2).all(|w| w[0] == w[1]));
    let k = &dumps[0].1;
    assert_eq!(k.absent, vec![sha(1), sha(2)]);
    assert_eq!(k.suspect, vec![sha(3)]);
    assert!(k.seeded);
}

/// 收的失败路径：每一种都不写、不记代号；公钥 / 信任补上之后同一份照收。
#[test]
fn ingest_refuses_what_it_cannot_trust_and_writes_nothing() {
    let a = Dev::new(0xa1, &[]);
    a.record(&[(sha(1), MediaState::Present)], true, 100);
    let ma = a.build(&[]).unwrap();
    let (dev, gen, tag) = named(&ma);
    // r 还不认识 a。
    let r = Dev::new(0xee, &[]);
    let go = |locs: &BTreeSet<Id>, dev: &Id, gen: u64, tag: &str, bytes: &[u8]| {
        ingest(&r.t(), r.col, LOC, locs, dev, gen, tag, bytes, NOW)
    };
    assert_eq!(
        go(&markers(), &dev, gen, &tag, &ma.bytes),
        Err(IngestError::UnknownDevice(dev))
    );
    // 补上公钥，但待确认。
    let t = r.t();
    t.tx(|t| {
        t.set_peer(
            r.col,
            &Peer {
                device: dev,
                public: key_of(0xa1).public(),
                name: None,
                ext: None,
                head_gen: None,
                first_seen: None,
            },
        )?;
        t.set_trust(r.col, &dev, Some(TRUST_PENDING), 1)
    })
    .unwrap();
    assert_eq!(
        go(&markers(), &dev, gen, &tag, &ma.bytes),
        Err(IngestError::Untrusted(dev, TRUST_PENDING))
    );
    t.tx(|t| t.set_trust(r.col, &dev, None, 1)).unwrap();
    let mismatch = |e: Result<Ingested, IngestError>| matches!(e, Err(IngestError::Mismatch(_)));
    assert!(
        mismatch(go(&markers(), &dev, gen, "00000000", &ma.bytes)),
        "tag"
    );
    assert!(
        mismatch(go(&markers(), &id(0xb2), gen, &tag, &ma.bytes)),
        "folder of another device"
    );
    assert!(
        mismatch(go(&markers(), &dev, gen + 1, &tag, &ma.bytes)),
        "gen"
    );
    assert!(
        mismatch(go(
            &[id(0x77)].into_iter().collect(),
            &dev,
            gen,
            &tag,
            &ma.bytes
        )),
        "loc"
    );
    // 别的集合的清单。
    let mut other = ma.manifest.clone();
    other.collection = id(0x01);
    let (ob, _) = other.encode(&key_of(0xa1)).unwrap();
    assert!(
        mismatch(go(&markers(), &dev, gen, &tag_of(&ob), &ob)),
        "collection"
    );
    // 冒名：别人的钥匙签的。
    let (fb, _) = ma.manifest.encode(&key_of(0x99)).unwrap();
    assert_eq!(
        go(&markers(), &dev, gen, &tag_of(&fb), &fb),
        Err(IngestError::Manifest(ManifestError::BadSignature))
    );
    // 坏字节。
    let mut bad = ma.bytes.clone();
    bad[4] = 9;
    assert!(matches!(
        go(&markers(), &dev, gen, &tag_of(&bad), &bad),
        Err(IngestError::Manifest(_))
    ));
    assert_eq!(r.dump(), vec![]);
    assert_eq!(
        seen_gens(&r.t(), r.col, LOC, &dev).unwrap(),
        Vec::<u64>::new()
    );
    assert!(!r.known().seeded);
    assert_eq!(
        go(&markers(), &dev, gen, &tag, &ma.bytes).map(|g| g.applied),
        Ok(1)
    );
    // 没绑定的集合。
    assert_eq!(
        ingest(
            &r.t(),
            999,
            LOC,
            &markers(),
            &dev,
            gen,
            &tag,
            &ma.bytes,
            NOW
        ),
        Err(IngestError::Unbound)
    );
}

/// 已收集合：按代号记、不是水位。pending_gens 给列出了但没收过的（升序去重），并把集合裁到本轮列举；收过的整份跳过；
/// 比已收的小的代号照样收（列举滞后时它晚出现）。
#[test]
fn seen_gens_are_a_set_not_a_watermark() {
    let a = Dev::new(0xa1, &[]);
    let r = Dev::new(0xee, &[0xa1]);
    a.record(&[(sha(1), MediaState::Present)], false, 100);
    let m1 = a.build(&[]).unwrap();
    mark_published(&a.t(), a.col, LOC, &m1.manifest).unwrap();
    a.record(&[(sha(2), MediaState::Present)], false, 200);
    let m2 = a.build(&[]).unwrap();
    assert_eq!(m2.manifest.gen, 2);
    assert_eq!(
        pending_gens(&r.t(), r.col, LOC, &id(0xa1), &[2, 1, 2]).unwrap(),
        vec![1, 2]
    );
    r.ingest(&m2).unwrap();
    assert_eq!(
        pending_gens(&r.t(), r.col, LOC, &id(0xa1), &[1, 2, 3]).unwrap(),
        vec![1, 3],
        "a smaller gen not yet taken is still pending"
    );
    let got = r.ingest(&m1).unwrap();
    assert!(!got.already);
    assert_eq!(got.applied, 1);
    assert_eq!(r.known().present, vec![sha(1), sha(2)]);
    let again = r.ingest(&m1).unwrap();
    assert!(again.already);
    assert_eq!(again.applied, 0);
    assert_eq!(
        seen_gens(&r.t(), r.col, LOC, &id(0xa1)).unwrap(),
        vec![1, 2]
    );
    // 裁剪：gen 1 被压缩回收删掉、不在本轮列举里，出集合；之后又列出来（列举滞后裁错了）就重收一份，幂等。
    assert_eq!(
        pending_gens(&r.t(), r.col, LOC, &id(0xa1), &[2]).unwrap(),
        Vec::<u64>::new()
    );
    assert_eq!(seen_gens(&r.t(), r.col, LOC, &id(0xa1)).unwrap(), vec![2]);
    assert_eq!(
        pending_gens(&r.t(), r.col, LOC, &id(0xa1), &[1, 2]).unwrap(),
        vec![1]
    );
    let re = r.ingest(&m1).unwrap();
    assert_eq!((re.already, re.applied, re.covered), (false, 0, 1));
    assert_eq!(r.known().present, vec![sha(1), sha(2)]);
    // 集合是按位置分开的。
    assert_eq!(
        seen_gens(&r.t(), r.col, "loc-b", &id(0xa1)).unwrap(),
        Vec::<u64>::new()
    );
}

/// 列目录滞后 + 代号空洞：作者先后发了 gen 5（X 不在）和 gen 6，读者第一轮只列到 gen 6、第二轮才列到 gen 5。
/// gen 5 不能因为「比已收的 6 小」被永久跳过——否则读者一直以为 X 还在，再也不传（D18 不取并集要防的就是这个）。
#[test]
fn a_lagged_gen_below_a_taken_one_is_still_ingested() {
    let a = Dev::new(0xa1, &[]);
    let r = Dev::new(0xee, &[0xa1]);
    a.record(&[(sha(1), MediaState::Present)], false, 100);
    let m1 = a.build(&[]).unwrap();
    mark_published(&a.t(), a.col, LOC, &m1.manifest).unwrap();
    // gen 2..4 烧掉了（上传失败 / 崩溃），位置上没有。
    a.record(&[(sha(1), MediaState::Absent)], false, 200);
    let m5 = a.build(&[4]).unwrap();
    assert_eq!(m5.manifest.gen, 5);
    mark_published(&a.t(), a.col, LOC, &m5.manifest).unwrap();
    a.record(&[(sha(2), MediaState::Present)], false, 300);
    let m6 = a.build(&[]).unwrap();
    assert_eq!(m6.manifest.gen, 6);
    mark_published(&a.t(), a.col, LOC, &m6.manifest).unwrap();
    assert_eq!(a.pending(), 0, "the author has nothing left to resend");
    // 第一轮：gen 5 还没列出来。
    assert_eq!(
        pending_gens(&r.t(), r.col, LOC, &id(0xa1), &[1, 6]).unwrap(),
        vec![1, 6]
    );
    r.ingest(&m1).unwrap();
    r.ingest(&m6).unwrap();
    assert_eq!(r.known().present, vec![sha(1), sha(2)]);
    // 第二轮：gen 5 出现了。
    assert_eq!(
        pending_gens(&r.t(), r.col, LOC, &id(0xa1), &[1, 5, 6]).unwrap(),
        vec![5]
    );
    let got = r.ingest(&m5).unwrap();
    assert!(!got.already, "the lagged gen is read, not skipped");
    assert_eq!(got.applied, 1);
    let k = r.known();
    assert_eq!(k.absent, vec![sha(1)]);
    assert_eq!(k.present, vec![sha(2)]);
}

/// 事务边界：外层事务回滚时，记下 / 收进来 / 标记发出的都一起回滚。
#[test]
fn writes_roll_back_with_the_enclosing_transaction() {
    let a = Dev::new(0xa1, &[]);
    let r = Dev::new(0xee, &[0xa1]);
    a.record(&[(sha(1), MediaState::Present)], true, 100);
    let m = a.build(&[]).unwrap();
    let t = r.t();
    let e = t
        .tx(|t| -> Result<(), String> {
            record(
                t,
                r.col,
                LOC,
                PLAIN_FOLDER,
                &[(sha(7), MediaState::Present)],
                true,
                hlc(1, 0xee),
            )?;
            let (d, g, tag) = named(&m);
            ingest(t, r.col, LOC, &markers(), &d, g, &tag, &m.bytes, NOW)
                .map_err(|e| e.to_string())?;
            mark_published(t, r.col, LOC, &m.manifest)?;
            Err("boom".into())
        })
        .unwrap_err();
    assert_eq!(e, "boom");
    assert_eq!(r.dump(), vec![]);
    assert_eq!(
        seen_gens(&r.t(), r.col, LOC, &id(0xa1)).unwrap(),
        Vec::<u64>::new()
    );
    assert!(!r.known().seeded);
    // 回滚之后照常可写（没有毒化会话）。
    assert_eq!(r.ingest(&m).unwrap().applied, 1);
}

/// 并发（新代的约定：只有主进程的一个写连接写，查词弹窗等只读，规划 G-1 / D10）：写线程边记观察边收清单，读线程在另一个
/// 连接上反复读——每次读到的都是某个已提交的快照（数目只增不减、从不报错），写完之后读到全部事实的合并。
#[test]
fn a_reader_on_another_connection_sees_only_committed_snapshots() {
    let dir = crate::store::sync2::tests::tempdir::new("g4-media-conc");
    let path = dir.0.join("srs4.db");
    let wc = schema::open(&path).unwrap();
    let col = init(&wc, 0xa1, &[0xb2]);
    let rc = schema::open(&path).unwrap();
    let src = Dev::new(0xb2, &[]);
    let facts: Vec<([u8; 32], MediaState)> = (0..200u8)
        .map(|i| {
            let mut s = [0x80; 32];
            s[0] = i;
            (s, MediaState::Present)
        })
        .collect();
    src.record(&facts, true, 50);
    let mb = src.build(&[]).unwrap();
    let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let writer = {
        let done = done.clone();
        std::thread::spawn(move || {
            let t = Truth::new(&wc);
            for i in 0..100u8 {
                let mut s = [0x01; 32];
                s[1] = i;
                // 每次两条：读者不该只看到其中一条。
                let mut s2 = s;
                s2[2] = 2;
                record(
                    &t,
                    col,
                    LOC,
                    PLAIN_FOLDER,
                    &[(s, MediaState::Present), (s2, MediaState::Present)],
                    false,
                    hlc(1000 + i64::from(i), 0xa1),
                )
                .unwrap();
                if i == 50 {
                    let (d, g, tag) = named(&mb);
                    ingest(&t, col, LOC, &markers(), &d, g, &tag, &mb.bytes, NOW).unwrap();
                }
            }
            done.store(true, std::sync::atomic::Ordering::SeqCst);
        })
    };
    let reader = std::thread::spawn(move || {
        let t = Truth::new(&rc);
        let mut last = 0usize;
        let mut reads = 0u32;
        loop {
            let finished = done.load(std::sync::atomic::Ordering::SeqCst);
            let k = known(&t, col, LOC, PLAIN_FOLDER).unwrap();
            let n = k.present.len();
            assert!(n >= last, "went back from {last} to {n}");
            let from_src = k.present.iter().filter(|s| s[31] == 0x80).count();
            // 收清单是一个事务：条目与「列举过」要么都看到、要么都没看到。
            assert!(
                from_src == 0 || from_src == 200,
                "saw part of one ingest ({from_src})"
            );
            assert_eq!(
                k.seeded,
                from_src == 200,
                "listing and entries from different snapshots"
            );
            assert_eq!((n - from_src) % 2, 0, "saw half of one record call ({n})");
            last = n;
            reads += 1;
            if finished {
                return (k, reads);
            }
        }
    });
    writer.join().unwrap();
    let (k, reads) = reader.join().unwrap();
    assert!(reads >= 1);
    assert_eq!(k.present.len(), 400);
    assert!(k.seeded);
    let c = schema::open(&path).unwrap();
    assert_eq!(
        pending_count(&Truth::new(&c), col).unwrap(),
        200,
        "only own observations wait to be sent"
    );
}

/// 迁移播种：协议 3 的内容寻址行原样（旧 HLC）带过来、待发；按名字存的旧键不带；可重放；第一台发出后，同样播种的
/// 第二台收到它就不再发。
#[test]
fn seeding_from_protocol_3_carries_content_facts_and_listings() {
    let d = crate::store::sync2::tests::Device::new("g4-media-seed");
    let content = "loc-a/media#sha256";
    let hex = |b: u8| -> String { format!("{b:02x}").repeat(32) };
    d.core
        .sync2_media_record_with_suspect(P, content, &[hex(1)], &[hex(2)], &[hex(3)], true, 1_000)
        .unwrap();
    // 按名字存的旧格式键、不是十六进制的名字：不带。
    d.core
        .sync2_media_record(
            P,
            "loc-a/media",
            &["image.jpg".to_owned()],
            &[],
            true,
            1_001,
        )
        .unwrap();
    d.core
        .sync2_media_record(P, content, &["image.jpg".to_owned()], &[], false, 1_002)
        .unwrap();
    let a = Dev::new(0xa1, &[]);
    let w = d.core.writer().unwrap();
    let s = seed_legacy(&a.t(), a.col, &w, P, NOW).unwrap();
    assert_eq!((s.rows, s.skipped, s.listed), (3, 2, 1));
    assert_eq!(
        a.known(),
        MediaKnown {
            seeded: true,
            present: vec![sha(1)],
            absent: vec![sha(2)],
            suspect: vec![sha(3)],
        }
    );
    // 旧 HLC 原样：墙钟是旧操作的。
    let f = fact(&a.t(), a.col, LOC, PLAIN_FOLDER, &sha(1))
        .unwrap()
        .unwrap();
    assert_eq!(f.hlc.wall, 1_000);
    // 重放：什么都不变。
    let before = a.dump();
    assert_eq!(seed_legacy(&a.t(), a.col, &w, P, NOW).unwrap().rows, 0);
    assert_eq!(a.dump(), before);
    // 第一台发出；第二台同样播种，收到第一台的就没有要发的。
    let ma = a.build(&[]).unwrap();
    assert_eq!(ma.manifest.len(), 3);
    assert!(ma.manifest.sections[PLAIN_FOLDER].listed);
    let b = Dev::new(0xb2, &[0xa1]);
    seed_legacy(&b.t(), b.col, &w, P, NOW).unwrap();
    let got = b.ingest(&ma).unwrap();
    assert_eq!(got.covered, 3);
    assert_eq!(b.build(&[]), None);
    // 全新加入的设备只靠清单就知道「有人列过」。
    let n = Dev::new(0xc3, &[0xa1]);
    n.ingest(&ma).unwrap();
    assert_eq!(n.known(), a.known());
}

/// 丢缓存：只丢这个位置（前缀相同、带 `/` 的位置不受影响），已收集合清空。
#[test]
fn forgetting_a_location_resets_only_that_location() {
    let a = Dev::new(0xa1, &[0xb2]);
    let src = Dev::new(0xb2, &[]);
    src.record(&[(sha(1), MediaState::Present)], true, 10);
    a.ingest(&src.build(&[]).unwrap()).unwrap();
    a.record(&[(sha(2), MediaState::Present)], false, 20);
    record(
        &a.t(),
        a.col,
        LOC,
        SEALED,
        &[(sha(3), MediaState::Present)],
        true,
        hlc(30, 0xa1),
    )
    .unwrap();
    record(
        &a.t(),
        a.col,
        "loc-a/x",
        PLAIN_FOLDER,
        &[(sha(4), MediaState::Present)],
        true,
        hlc(40, 0xa1),
    )
    .unwrap();
    assert_eq!(forget(&a.t(), a.col, LOC).unwrap(), 3);
    assert_eq!(a.known(), MediaKnown::default());
    assert_eq!(
        known(&a.t(), a.col, LOC, SEALED).unwrap(),
        MediaKnown::default()
    );
    assert_eq!(
        seen_gens(&a.t(), a.col, LOC, &id(0xb2)).unwrap(),
        Vec::<u64>::new()
    );
    let kept = known(&a.t(), a.col, "loc-a/x", PLAIN_FOLDER).unwrap();
    assert!(kept.seeded);
    assert_eq!(kept.present, vec![sha(4)]);
}

/// 压缩回收：合并出的一份与几份增量收进来结果相同；作者混了、代号不够大都拒。
#[test]
fn compaction_is_an_upper_bound_of_its_parts() {
    let a = Dev::new(0xa1, &[]);
    let mut parts = Vec::new();
    for (i, s) in [
        (1u8, MediaState::Present),
        (2, MediaState::Present),
        (1, MediaState::Absent),
    ]
    .into_iter()
    .enumerate()
    {
        a.record(&[(sha(s.0), s.1)], i == 0, 100 + i as i64);
        let b = a.build(&[]).unwrap();
        mark_published(&a.t(), a.col, LOC, &b.manifest).unwrap();
        parts.push(b.manifest);
    }
    let whole = compact(&parts, marker(), 4).unwrap();
    let (bytes, name) = whole.encode(&key_of(0xa1)).unwrap();
    let packed = Built {
        manifest: whole.clone(),
        bytes,
        name,
    };
    let r1 = Dev::new(0xee, &[0xa1]);
    for p in &parts {
        let (b, n) = p.encode(&key_of(0xa1)).unwrap();
        r1.ingest(&Built {
            manifest: p.clone(),
            bytes: b,
            name: n,
        })
        .unwrap();
    }
    let r2 = Dev::new(0xee, &[0xa1]);
    r2.ingest(&packed).unwrap();
    assert_eq!(r1.dump(), r2.dump());
    assert_eq!(r1.known(), r2.known());
    assert!(r2.known().seeded);
    // 读者已收过增量（1～3）也照收合并件（4 没收过），不变。
    assert_eq!(r1.ingest(&packed).unwrap().applied, 0);
    assert!(compact(&parts, marker(), 3).is_err());
    assert!(compact(&[], marker(), 9).is_err());
    let mut alien = parts[0].clone();
    alien.device = id(0xb2);
    assert!(compact(&[parts[0].clone(), alien], marker(), 9).is_err());
    let _ = Section::default();
}

/// 墙钟超前 `MAX_AHEAD_MS` 以上的设备记下的「在」压不住本机后来的「不在」：本机观察因果上更晚，HLC 盖到它之上
/// 写下待发；发出去后各设备（含超前的那台、收到顺序不同的第三台）都收敛到「不在」。
#[test]
fn a_fact_from_a_clock_far_ahead_does_not_pin_the_location() {
    let a = Dev::new(0xa1, &[0xb2]);
    let b = Dev::new(0xb2, &[0xa1]);
    let ahead_wall = NOW + 3 * 24 * 60 * 60 * 1000;
    b.record(&[(sha(1), MediaState::Present)], true, ahead_wall);
    let mb = b.build(&[]).unwrap();
    mark_published(&b.t(), b.col, LOC, &mb.manifest).unwrap();
    let got = a.ingest(&mb).unwrap();
    assert_eq!(got.applied, 1);
    assert_eq!(
        got.seen.max_hlc, None,
        "an ahead HLC is not offered to absorb"
    );
    assert_eq!(got.seen.ahead, [id(0xb2)].into_iter().collect());
    // a 的时钟吸收不了它（Clock::absorb 拒超前），照常 tick 出一个小得多的 HLC 记「不在」。
    let r = a.record(&[(sha(1), MediaState::Absent)], false, 2_000);
    assert_eq!((r.written, r.unchanged, r.lifted), (1, 0, 1));
    let f = fact(&a.t(), a.col, LOC, PLAIN_FOLDER, &sha(1))
        .unwrap()
        .unwrap();
    assert_eq!(f.state, MediaState::Absent);
    assert_eq!(
        f.hlc,
        Hlc {
            wall: ahead_wall,
            logical: 1,
            device: id(0xa1)
        }
    );
    assert_eq!(a.known().absent, vec![sha(1)]);
    let ma = a.build(&[]).unwrap();
    assert_eq!(
        ma.manifest.sections[PLAIN_FOLDER].entries[&sha(1)].state,
        MediaState::Absent
    );
    let got = b.ingest(&ma).unwrap();
    assert_eq!(got.applied, 1);
    assert_eq!(b.known(), a.known());
    for order in [[&ma, &mb], [&mb, &ma]] {
        let c = Dev::new(0xc3, &[0xa1, 0xb2]);
        for m in order {
            c.ingest(m).unwrap();
        }
        assert_eq!(c.known(), a.known());
    }
}

/// [after]：严格大于输入；logical 满了进位到 wall + 1；wall 也满了报错（record 整批不写）。
#[test]
fn after_is_strictly_later_and_carries_logical_overflow() {
    let h = Hlc {
        wall: 7,
        logical: 3,
        device: id(0xff),
    };
    let n = after(&h, id(0x01)).unwrap();
    assert!(n > h);
    assert_eq!((n.wall, n.logical, n.device), (7, 4, id(0x01)));
    let full = Hlc {
        wall: 7,
        logical: u32::MAX,
        device: id(0x01),
    };
    let n = after(&full, id(0x01)).unwrap();
    assert!(n > full);
    assert_eq!((n.wall, n.logical), (8, 0));
    let end = Hlc {
        wall: i64::MAX,
        logical: u32::MAX,
        device: id(0x01),
    };
    assert!(after(&end, id(0x01)).is_err());
    // 经 record：现有那条的 logical 已满，抬起来进位。
    let a = Dev::new(0xa1, &[]);
    record(
        &a.t(),
        a.col,
        LOC,
        PLAIN_FOLDER,
        &[(sha(1), MediaState::Present)],
        false,
        full,
    )
    .unwrap();
    a.record(&[(sha(1), MediaState::Absent)], false, 1);
    let f = fact(&a.t(), a.col, LOC, PLAIN_FOLDER, &sha(1))
        .unwrap()
        .unwrap();
    assert_eq!(
        (f.hlc.wall, f.hlc.logical, f.state),
        (8, 0, MediaState::Absent)
    );
    // 到顶了：报错，整批不写。
    let z = Dev::new(0xa1, &[]);
    record(
        &z.t(),
        z.col,
        LOC,
        PLAIN_FOLDER,
        &[(sha(1), MediaState::Present)],
        false,
        end,
    )
    .unwrap();
    let before = z.dump();
    assert!(
        record(
            &z.t(),
            z.col,
            LOC,
            PLAIN_FOLDER,
            &[(sha(2), MediaState::Present), (sha(1), MediaState::Absent)],
            false,
            hlc(1, 0xa1),
        )
        .is_err()
    );
    assert_eq!(z.dump(), before);
}

/// `seen.max_hlc` 只取不超前的：一份清单里混了超前的，正常范围的那条仍交给调用方吸收；播种同口径。
#[test]
fn ahead_hlcs_are_kept_out_of_what_the_caller_absorbs() {
    let a = Dev::new(0xa1, &[0xb2]);
    let b = Dev::new(0xb2, &[0xa1]);
    b.record(
        &[(sha(1), MediaState::Present)],
        false,
        NOW + 2 * 24 * 60 * 60 * 1000,
    );
    b.record(&[(sha(2), MediaState::Present)], false, 5_000);
    let mb = b.build(&[]).unwrap();
    let got = a.ingest(&mb).unwrap();
    assert_eq!(got.seen.max_hlc, Some(hlc(5_000, 0xb2)));
    assert_eq!(got.seen.ahead, [id(0xb2)].into_iter().collect());
    let mut clock = crate::sync2::hlc::Clock::new(id(0xa1));
    assert!(!clock.absorb(got.seen.max_hlc.unwrap(), NOW).ahead);
    assert_eq!(clock.last.wall, 5_000);
    // 整份跳过的：什么都没读，seen 为空。
    let again = a.ingest(&mb).unwrap();
    assert!(again.already);
    assert_eq!(again.seen, SeenHlc::default());
    // 播种：同一批旧事实，本机墙钟正常时给最大 HLC；墙钟远落后时全算超前。
    let d = crate::store::sync2::tests::Device::new("g4-media-seed-seen");
    let hex = |x: u8| -> String { format!("{x:02x}").repeat(32) };
    d.core
        .sync2_media_record_with_suspect(
            P,
            "loc-a/media#sha256",
            &[hex(1)],
            &[hex(2)],
            &[],
            true,
            1_000,
        )
        .unwrap();
    let w = d.core.writer().unwrap();
    let s = seed_legacy(&a.t(), a.col, &w, P, NOW).unwrap();
    let top = s.seen.max_hlc.unwrap();
    assert!(top.wall >= 1_000, "{top:?}");
    assert!(s.seen.ahead.is_empty());
    let s = seed_legacy(&a.t(), a.col, &w, P, top.wall - MAX_AHEAD_MS - 1).unwrap();
    assert_eq!(s.seen.max_hlc, None);
    assert_eq!(s.seen.ahead, [top.device].into_iter().collect());
}

/// 代号持久预留：上传后没来得及 mark_published 就崩了、下一轮列目录又没列出刚传的那份（网盘列举滞后），再发的也
/// 绝不与它同代号；读者两份都收。没东西发不烧代号；forget 之后也不重用。
#[test]
fn a_gen_is_never_reused_even_when_the_listing_lags() {
    let a = Dev::new(0xa1, &[]);
    let r = Dev::new(0xee, &[0xa1]);
    a.record(&[(sha(1), MediaState::Present)], false, 100);
    let first = a.build(&[]).unwrap();
    assert_eq!(first.manifest.gen, 1);
    // 「崩溃」，重启后待发集合变了，列目录（滞后）什么都没列出。
    a.record(&[(sha(2), MediaState::Present)], false, 200);
    let second = a.build(&[]).unwrap();
    assert_eq!(
        second.manifest.gen, 2,
        "a reserved gen is never handed out twice"
    );
    assert_ne!(first.name, second.name);
    let pg = pending_gens(&r.t(), r.col, LOC, &id(0xa1), &[1, 2]).unwrap();
    assert_eq!(pg, vec![1, 2]);
    assert_eq!(r.ingest(&first).unwrap().applied, 1);
    let got = r.ingest(&second).unwrap();
    assert_eq!(
        (got.applied, got.covered),
        (1, 1),
        "the second file is read, not skipped"
    );
    assert_eq!(r.known().present, vec![sha(1), sha(2)]);
    mark_published(&a.t(), a.col, LOC, &second.manifest).unwrap();
    assert_eq!(a.build(&[]), None);
    assert_eq!(
        reserve_gen(&a.t(), a.col, LOC, &id(0xa1), &[]).unwrap(),
        3,
        "an empty build reserved nothing"
    );
    // 换根 / 从头对账：已收集合清了，预留不清。
    forget(&a.t(), a.col, LOC).unwrap();
    assert_eq!(
        seen_gens(&a.t(), a.col, LOC, &id(0xa1)).unwrap(),
        Vec::<u64>::new()
    );
    a.record(&[(sha(3), MediaState::Present)], false, 300);
    assert_eq!(a.build(&[]).unwrap().manifest.gen, 4);
    // 位置上列出更大的代号（别的副本 / 旧库发的）：照样压过。
    assert_eq!(a.build(&[9]).unwrap().manifest.gen, 10);
    // 预留跟着事务走：外层事务回滚，预留也回滚（没提交的代号没人见过，可以再用）。
    let t = a.t();
    let e = t
        .tx(|t| {
            reserve_gen(t, a.col, LOC, &id(0xa1), &[])?;
            Err::<(), String>("boom".into())
        })
        .unwrap_err();
    assert_eq!(e, "boom");
    assert_eq!(reserve_gen(&a.t(), a.col, LOC, &id(0xa1), &[]).unwrap(), 11);
    // 按位置、按设备分开。
    assert_eq!(
        reserve_gen(&a.t(), a.col, "loc-b", &id(0xa1), &[]).unwrap(),
        1
    );
    assert_eq!(reserve_gen(&a.t(), a.col, LOC, &id(0xa2), &[]).unwrap(), 1);
    assert!(reserve_gen(&a.t(), a.col, "", &id(0xa1), &[]).is_err());
}

/// mark_published 要状态与 HLC 都相同才清：打包后本机改「不在」又改回「在」，状态与打包时相同但 HLC 更大，这条
/// 仍待发（误清就发不出去，吸收过别人更新事实的设备从此分叉）。
#[test]
fn publishing_keeps_a_fact_rewritten_to_the_same_state_with_a_newer_hlc() {
    let a = Dev::new(0xa1, &[]);
    a.record(&[(sha(1), MediaState::Present)], false, 100);
    let b = a.build(&[]).unwrap();
    a.record(&[(sha(1), MediaState::Absent)], false, 200);
    a.record(&[(sha(1), MediaState::Present)], false, 300);
    assert_eq!(mark_published(&a.t(), a.col, LOC, &b.manifest).unwrap(), 0);
    assert_eq!(a.pending(), 1);
    let next = a.build(&[]).unwrap();
    assert_eq!(
        next.manifest.sections[PLAIN_FOLDER].entries[&sha(1)],
        Fact {
            state: MediaState::Present,
            hlc: hlc(300, 0xa1)
        }
    );
}
