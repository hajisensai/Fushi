//! [super]（迁移编排）的测试：一次跑完、本机状态带过去、对拍不过中止、前提拦下、锁与忙、叫停、每个断点被杀后重跑
//! 结果相同（子进程）、提交之后补封、预演与迁移走同一套阶段。

use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;

use rusqlite::{Connection, OpenFlags, params};
use serde_json::{Value, json};

use super::*;
use crate::gen4::head::PrevIdentity;
use crate::store::SrsCore;
use crate::store::gen4::carry;
use crate::store::gen4::compare::cell;
use crate::store::gen4::dryrun::tests::{N2, T0, cfg, library};
use crate::store::gen4::files::{OpenMode, open_gen4};
use crate::store::gen4::truth::BindStage;
use crate::store::sync2::tests::{Bucket, Device, P, tempdir};
use crate::sync2::keys::DeviceKey;
use crate::sync2::segment::Chain;

const NOW: i64 = T0 + 30 * 86_400_000;
const NEW_DEV: Id = Id([0x4e; 16]);

fn fixed_device(_profile: &str, _now: i64) -> Id {
    NEW_DEV
}

fn caches() -> BTreeMap<String, String> {
    BTreeMap::from([(P.to_owned(), cfg())])
}

/// 一个目录里的协议 3 小库（`dryrun::tests::library`），[prep] 在内核开着时跑；之后内核关掉（关掉时 WAL 并回主文件）。
fn legacy_dir(tag: &str, prep: &dyn Fn(&SrsCore)) -> tempdir::Dir {
    let Device { core, _dir } = library(tag);
    prep(&core);
    core.close();
    drop(core);
    _dir
}

/// 不经内核直接改旧库（注册了 ID 函数）。
fn raw(dir: &Path) -> Connection {
    let c = Connection::open(dir.join(LEGACY_FILE)).unwrap();
    crate::store::ids::register(&c).unwrap();
    crate::store::slim::register(&c).unwrap();
    crate::store::sync2::digest::register(&c).unwrap();
    c
}

fn copy_dir(from: &Path, tag: &str) -> tempdir::Dir {
    let to = tempdir::new(tag);
    for suffix in ["", "-wal"] {
        let f = format!("{LEGACY_FILE}{suffix}");
        if from.join(&f).exists() {
            std::fs::copy(from.join(&f), to.0.join(&f)).unwrap();
        }
    }
    to
}

fn migrate_with(
    dir: &Path,
    caches: &BTreeMap<String, String>,
    stop: &Stop,
    steps: &mut Vec<Step>,
) -> Outcome {
    run(
        dir,
        Options {
            caches,
            batch: 2,
            now_ms: NOW,
            stop,
            progress: &mut |s, _, _| {
                if steps.last() != Some(&s) {
                    steps.push(s);
                }
            },
            new_device: &fixed_device,
        },
    )
    .unwrap()
}

fn migrate(dir: &Path) -> Outcome {
    migrate_with(dir, &caches(), &Stop::new(), &mut Vec::new())
}

/// 旧库的 `srs_meta.schema`。
fn schema_of(dir: &Path) -> String {
    Connection::open_with_flags(dir.join(LEGACY_FILE), OpenFlags::SQLITE_OPEN_READ_ONLY)
        .unwrap()
        .query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| {
            r.get(0)
        })
        .unwrap()
}

/// 抹掉 SQLite 文件头里两处计数字段（设计 §6.1 末「已知例外」）后的旧库字节。
fn masked(dir: &Path) -> Vec<u8> {
    let mut b = std::fs::read(dir.join(LEGACY_FILE)).unwrap();
    if b.len() >= 100 {
        b[24..28].fill(0);
        b[92..96].fill(0);
    }
    b
}

/// 新代库的逻辑内容：每张表的每一行（按文本排序）。
fn dump(path: &Path) -> Vec<String> {
    let c = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let tables: Vec<String> = c
        .prepare("SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let mut out = Vec::new();
    for t in tables {
        let mut stmt = c.prepare(&format!("SELECT * FROM \"{t}\"")).unwrap();
        let n = stmt.column_count();
        let mut rows: Vec<String> = stmt
            .query_map([], |r| {
                Ok((0..n)
                    .map(|i| cell(r.get_ref(i).unwrap()))
                    .collect::<Vec<_>>()
                    .join(" | "))
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        rows.sort();
        out.extend(rows.into_iter().map(|r| format!("{t}: {r}")));
    }
    out
}

/// 协议 3 里本机在 [P] 下的身份：(设备, 钥匙种子, 日志末尾, 末尾链值, hlc_wall)。
fn old_self(dir: &Path) -> (Id, [u8; 32], u64, Chain, i64) {
    let c = raw(dir);
    c.query_row(
        "SELECT device, key_seed, next_seq, chain, hlc_wall FROM sync2_self WHERE profile_uid = srs_id(?1)",
        [P],
        |r| {
            Ok((
                Id(r.get::<_, Vec<u8>>(0)?.try_into().unwrap()),
                r.get::<_, Vec<u8>>(1)?.try_into().unwrap(),
                (r.get::<_, i64>(2)? - 1) as u64,
                r.get::<_, Vec<u8>>(3)?.try_into().unwrap(),
                r.get(4)?,
            ))
        },
    )
    .unwrap()
}

fn report_file(dir: &Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(dir.join(REPORT_FILE)).unwrap()).unwrap()
}

/// 一个做完了前提的库：按顺序报每一步，提交、原位封存（协议 3 的内核随后拒绝打开它），新代库就位且 Primary 打得开；
/// 新身份是新设备 ID、沿用签名钥匙、`prev` 指向旧设备的日志末尾（链值同 `sync2_self`），旧设备名下记着同一把公钥，
/// 时钟不落在旧身份之前，原生日志里只有那一条 `Salts`；迁移来源记进了新代库；报告（含已知差异一节）落在目录里。
/// 再跑一次什么都不改。
#[test]
fn a_ready_library_is_migrated_sealed_and_opens() {
    let dir = legacy_dir("g72-ok", &|_| {});
    let (old, seed, last, chain, wall) = old_self(&dir.0);
    let identity = seal::legacy_identity(&raw(&dir.0)).unwrap();
    let mut steps = Vec::new();
    let out = migrate_with(&dir.0, &caches(), &Stop::new(), &mut steps);
    let Outcome::Committed { report } = &out else {
        panic!("{out:?}")
    };
    assert_eq!(out.verdict(), "committed");
    assert_eq!(report["sealed"], true, "{report:#}");
    let p = &report["profiles"][0];
    assert_eq!(p["verdict"], "pass", "{p:#}");
    assert_eq!(p["parity"], json!([]));
    assert_eq!(p["canonical"], json!([]));
    assert_eq!(p["knownDifferences"]["unproven"], 0);
    assert_eq!(p["identity"]["device"], NEW_DEV.text());
    assert_eq!(p["identity"]["prev"]["seq"], last);
    assert_eq!(
        steps,
        [
            Step::Space,
            Step::Lock,
            Step::Prepare,
            Step::Precondition,
            Step::Translate,
            Step::Salts,
            Step::Rebuild,
            Step::Parity,
            Step::Commit,
            Step::Seal
        ]
    );
    assert!(dir.0.join(GEN4_FILE).exists());
    assert!(!dir.0.join(GEN4_TEMP).exists());
    assert_eq!(schema_of(&dir.0), SEALED_SCHEMA.to_string());
    let err = SrsCore::open(&dir.0.join(LEGACY_FILE))
        .err()
        .expect("protocol 3 must refuse the sealed library");
    assert!(err.contains("is newer than this build"), "{err}");
    assert_eq!(report_file(&dir.0)["verdict"], "committed");
    assert_eq!(status(&dir.0), Ok(GenState::Ready));

    let opened = open_gen4(&dir.0, OpenMode::Primary).unwrap();
    assert!(!opened.retained_copy_unreadable);
    let t = Truth::new(&opened.conn);
    let b = t.binding_of(P).unwrap().unwrap();
    let me = t.self_identity(b.col).unwrap().unwrap();
    assert_eq!(me.device, NEW_DEV);
    assert_eq!(me.sk, seed);
    assert_eq!(me.created, NOW);
    assert!(last > 0);
    assert_eq!(
        me.prev,
        Some(PrevIdentity {
            device: old,
            seq: last,
            chain
        })
    );
    assert!(me.hlc.wall >= wall.max(NOW), "{:?} vs {wall}", me.hlc);
    let public = DeviceKey::from_seed(&seed).public();
    assert_eq!(t.device_key(b.col, &old), Ok(Some(public)));
    assert_eq!(t.device_key(b.col, &NEW_DEV), Ok(Some(public)));
    assert_eq!(t.last_of(b.col, &NEW_DEV), Ok(1));
    assert_eq!(t.last_of(b.col, &old), Ok(last));
    let from: String = opened
        .conn
        .query_row(
            "SELECT value FROM srs_meta WHERE key = ?1",
            [files::MIGRATED_FROM_KEY],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(Some(from), identity);
    let (notes, cards): (i64, i64) = opened
        .conn
        .query_row(
            "SELECT (SELECT COUNT(*) FROM notes), (SELECT COUNT(*) FROM cards)",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(notes, 2);
    assert!(cards >= 4, "{cards}");
    drop(t);
    drop(opened);

    let before = dump(&dir.0.join(GEN4_FILE));
    let again = migrate(&dir.0);
    let Outcome::Committed { report } = &again else {
        panic!("{again:?}")
    };
    assert_eq!(report["resumed"], true);
    assert_eq!(dump(&dir.0.join(GEN4_FILE)), before);
}

/// 本机状态带过去（D11、缺口 G-2）：加密位置记忆的两个来源（BUG-4299：记账键带 kdf 与校验串；带 `#e` 的老上传进度）、
/// 坏了的记账也按见过算、绑定状态、别的设备的公钥 / 名字（没自报名字的取补充名）/ 扩展信息、没有公钥的设备不带、
/// 检查点、本机媒体登记、各位置媒体在不在（内容寻址口径的才带）、协议 3 已切的段两端成为切点。
#[test]
fn local_state_comes_along() {
    let kdf = json!({"alg": "argon2id", "salt": "c2FsdA", "check": "chk-1"});
    let dir = legacy_dir("g72-local", &|core| {
        core.binding_set(P, "settled", "folder:home", 1234).unwrap();
        core.sync2_location_seal(P, "folder:enc", Some(&kdf), false, &[], 5)
            .unwrap();
    });
    let peer = Id([0x51; 16]);
    let nameless = Id([0x52; 16]);
    let keyless = Id([0x53; 16]);
    let sha = "ab".repeat(32);
    let (old, ..) = old_self(&dir.0);
    let max_seq: i64 = {
        let c = raw(&dir.0);
        c.query_row(
            "SELECT MAX(seq) FROM sync2_ops WHERE profile_uid = srs_id(?1) AND device = ?2",
            params![P, &old.0[..]],
            |r| r.get(0),
        )
        .unwrap()
    };
    assert!(max_seq >= 3, "{max_seq}");
    {
        let c = raw(&dir.0);
        c.execute_batch(&format!(
            "INSERT INTO sync2_locations (profile_uid, location, uploaded) VALUES (srs_id('{P}'), 'folder:old#e00aa', 3);
             INSERT INTO srs_meta (key, value) VALUES ('sync2_sealed/folder:bad/{P}', 'not json');
             INSERT INTO srs_meta (key, value) VALUES ('sync2_sealed/folder:other/0193a1b2-0000-7000-8000-00000000dead', '{{}}');"
        ))
        .unwrap();
        for (d, public, name) in [
            (peer, Some(vec![1u8; 32]), "Pixel"),
            (nameless, Some(vec![2u8; 32]), ""),
            (keyless, None, "Ghost"),
        ] {
            c.execute(
                "INSERT INTO sync2_devices (profile_uid, device, public, applied, name) VALUES (srs_id(?1), ?2, ?3, 0, ?4)",
                params![P, &d.0[..], public, name],
            )
            .unwrap();
        }
        c.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, '{\"model\":\"P8\",\"v\":3}')",
            [format!("sync2_device_ext/{P}/{}", peer.text())],
        )
        .unwrap();
        c.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, 'Tablet')",
            [format!("sync2_device_hint/{}", nameless.text())],
        )
        .unwrap();
        c.execute(
            "INSERT INTO sync2_checkpoints (profile_uid, device, seq, wall, name, reason) VALUES (srs_id(?1), ?2, 2, 77, 'cp', 'manual')",
            params![P, &old.0[..]],
        )
        .unwrap();
        c.execute(
            "INSERT INTO sync2_media_local (profile_uid, name, size, mtime, sha256, synced) VALUES (srs_id(?1), 'a.mp3', 9, 8, ?2, NULL)",
            params![P, &[7u8; 32][..]],
        )
        .unwrap();
        for (location, name) in [("folder:enc/media", sha.as_str()), ("folder:enc", "a.mp3")] {
            c.execute(
                "INSERT INTO sync2_media_at (profile_uid, location, name, present, wall, logical, device) \
                 VALUES (srs_id(?1), ?2, ?3, 1, ?4, 0, ?5)",
                params![P, format!("{location}#sha256"), name, T0, &peer.0[..]],
            )
            .unwrap();
        }
        c.execute(
            "INSERT INTO sync2_segments (profile_uid, device, first, last, bytes) VALUES (srs_id(?1), ?2, 2, 3, 0)",
            params![P, &old.0[..]],
        )
        .unwrap();
    }
    let out = migrate(&dir.0);
    let Outcome::Committed { report } = &out else {
        panic!("{out:?}")
    };
    let local = &report["profiles"][0]["local"];
    assert_eq!(local["sealedLocations"], 3, "{local:#}");
    assert_eq!(local["binding"], "settled");
    assert_eq!(local["peersWithoutKey"], 1);
    assert_eq!(local["mediaAt"], 1);
    assert_eq!(local["mediaSkipped"], 1);
    assert_eq!(local["cutPoints"], 2);

    let opened = open_gen4(&dir.0, OpenMode::Secondary).unwrap();
    let t = Truth::new(&opened.conn);
    let col = t.binding_of(P).unwrap().unwrap().col;
    let sealed: Vec<(String, i64, Option<String>, Option<String>)> = opened
        .conn
        .prepare(
            "SELECT loc_key, sealed, kdf, check_ FROM loc_state WHERE col = ?1 ORDER BY loc_key",
        )
        .unwrap()
        .query_map([col], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(sealed.len(), 3, "{sealed:?}");
    assert_eq!(
        (sealed[0].0.as_str(), sealed[0].1, &sealed[0].2),
        ("folder:bad", 1, &None)
    );
    assert_eq!(sealed[1].0, "folder:enc");
    assert_eq!(
        serde_json::from_str::<Value>(sealed[1].2.as_deref().unwrap()).unwrap(),
        kdf
    );
    assert_eq!(sealed[1].3.as_deref(), Some("chk-1"));
    assert_eq!((sealed[2].0.as_str(), sealed[2].1), ("folder:old", 1));
    let st = t.binding_state(col).unwrap().unwrap();
    assert_eq!(
        (st.stage, st.via.as_str(), st.at),
        (BindStage::Settled, "folder:home", 1234)
    );
    let p = t.peer(col, &peer).unwrap().unwrap();
    assert_eq!(
        (p.public, p.name.as_deref(), p.ext.as_deref()),
        ([1; 32], Some("Pixel"), Some("{\"model\":\"P8\",\"v\":3}"))
    );
    assert_eq!(
        t.peer(col, &nameless).unwrap().unwrap().name.as_deref(),
        Some("Tablet")
    );
    assert_eq!(t.peer(col, &keyless), Ok(None));
    let n = |q: &str| -> i64 { opened.conn.query_row(q, [col], |r| r.get(0)).unwrap() };
    assert_eq!(
        n("SELECT COUNT(*) FROM checkpoints WHERE col = ?1 AND seq = 2 AND name = 'cp'"),
        1
    );
    assert_eq!(
        n("SELECT COUNT(*) FROM media_local WHERE col = ?1 AND name = 'a.mp3' AND size = 9"),
        1
    );
    assert_eq!(
        n(
            "SELECT COUNT(*) FROM media_at WHERE col = ?1 AND loc_key = 'folder:enc/media#sha256' AND pend = 1"
        ),
        1
    );
    let marks: Vec<u64> = t
        .marks(col, &old)
        .unwrap()
        .into_iter()
        .map(|m| m.0)
        .collect();
    assert!(marks.contains(&1) && marks.contains(&3), "{marks:?}");
}

/// `carry_local` 单独跑：暂扣照搬、实体存成 ID 文本（协议 3 存的是存储值）。暂扣是对拍比的一类，所以不在端到端里造假行。
#[test]
fn held_rows_are_copied_with_text_entity_ids() {
    let dir = legacy_dir("g72-held", &|_| {});
    let (old, ..) = old_self(&dir.0);
    let src = raw(&dir.0);
    src.execute(
        "INSERT INTO sync2_held (profile_uid, device, seq, kind, entity) VALUES (srs_id(?1), ?2, 2, 'note', srs_id(?3))",
        params![P, &old.0[..], N2],
    )
    .unwrap();
    let conn = schema::open_in_memory().unwrap();
    let t = Truth::new(&conn);
    let col = t
        .tx(|t| t.bind(P, &crate::store::sync2::collection_of(P), P))
        .unwrap();
    let c = carry::carry_local(&src, &t, col, P, NOW).unwrap();
    assert_eq!(c.held, 1);
    let row: (Vec<u8>, i64, String, String) = conn
        .query_row("SELECT device, seq, kind, entity FROM held", [], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .unwrap();
    assert_eq!(row, (old.0.to_vec(), 2, "note".to_owned(), N2.to_owned()));
}

/// 对拍不过（投影与日志不一致：手删一条活着的字段修改）：不提交、不封存，旧库逐字节不变、协议 3 照常能开；报告写进
/// 目录（中止、带对拍差异），临时文件当场删掉（目录里只多一份报告），状态报迁移失败。旧库没动过，协议 3 的内核照旧能开。再跑一次同样中止（从头重来，不在留下的半份上续做）。
#[test]
fn a_parity_failure_aborts_and_leaves_the_library_usable() {
    let dir = legacy_dir("g72-abort", &|_| {});
    raw(&dir.0)
        .execute(
            "DELETE FROM srs_field_edits WHERE entity_kind = 'note' AND entity_id = srs_id(?1) AND field_key = 'f/fa'",
            [N2],
        )
        .unwrap();
    let before = masked(&dir.0);
    for _ in 0..2 {
        let out = migrate(&dir.0);
        let Outcome::Aborted {
            reason,
            report_path,
            report,
        } = &out
        else {
            panic!("{out:?}")
        };
        assert_eq!(*reason, AbortReason::Fail);
        assert_eq!(report_path, &dir.0.join(REPORT_FILE));
        // 命令回包带与状态命令同一形状的原因：本进程刚跑出的与重启后读到的说同一件事。
        assert_eq!(
            out.json()["failure"],
            GenState::MigrationFailed(Failure::Aborted(AbortReason::Fail)).json(&dir.0)["failure"]
        );
        assert_eq!(report["verdict"], "aborted");
        assert_eq!(report["profiles"][0]["verdict"], "fail");
        assert_ne!(report["profiles"][0]["parity"], json!([]));
        assert_eq!(report_file(&dir.0)["verdict"], "aborted");
        assert!(!dir.0.join(GEN4_TEMP).exists());
        assert!(!dir.0.join(GEN4_FILE).exists());
        assert_eq!(masked(&dir.0), before);
        assert_eq!(
            schema_of(&dir.0),
            crate::store::schema::SCHEMA_VERSION.to_string()
        );
        assert_eq!(
            status(&dir.0),
            Ok(GenState::MigrationFailed(Failure::Aborted(
                AbortReason::Fail
            )))
        );
    }
}

/// 前提不齐一律拦下、什么都不碰（旧库逐字节不变，不留临时文件）：没给缓存配置、收段留下的待重放卡、
/// 有投影数据却不在操作日志里的 profile。拦下的原因逐条带 profile。
#[test]
fn unmet_preconditions_block_before_anything_is_written() {
    let other = "0193a1b2-0000-7000-8000-00000000cafe";
    let cases: [(
        &str,
        &dyn Fn(&Connection),
        BTreeMap<String, String>,
        BlockCode,
        &str,
    ); 2] = [
        (
            "g72-nocfg",
            &|_| {},
            BTreeMap::new(),
            BlockCode::MissingCacheConfig,
            "no cache configuration",
        ),
        // 只在投影表里的孤儿 uid 也要缓存配置（补完与迁移都要）：没给就拦，旧库不动。
        (
            "g72-outside",
            &|c| {
                c.execute(
                    "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES (srs_id(?1), srs_id(?2), 'note', '{}')",
                    ["0193a1b2-0000-7000-8000-0000000000f1", other],
                )
                .unwrap();
            },
            caches(),
            BlockCode::MissingCacheConfig,
            other,
        ),
    ];
    for (tag, prep, caches, code, why) in cases {
        let dir = legacy_dir(tag, &|_| {});
        prep(&raw(&dir.0));
        let before = masked(&dir.0);
        let out = migrate_with(&dir.0, &caches, &Stop::new(), &mut Vec::new());
        let Outcome::Blocked { code: got, reason } = &out else {
            panic!("{tag}: {out:?}")
        };
        assert_eq!(*got, code, "{tag}: {reason}");
        assert!(reason.contains(why), "{tag}: {reason}");
        assert_eq!(out.json()["code"], json!(code.wire()), "{tag}");
        assert_eq!(masked(&dir.0), before, "{tag}");
        assert!(!dir.0.join(GEN4_TEMP).exists(), "{tag}");
        assert!(!dir.0.join(GEN4_FILE).exists(), "{tag}");
        assert_eq!(status(&dir.0), Ok(GenState::NeedsMigration), "{tag}");
    }
}

/// 换代锁在别人手里 = 拦下（迁移中）；旧库正被别的连接写 = 拦下（忙），都不碰任何文件。旧库不是这一版协议 3 的、
/// 已封存却没有新代库、目录里什么都没有：拦下并说明。
#[test]
fn locks_busy_libraries_and_wrong_states_are_refused() {
    let dir = legacy_dir("g72-locks", &|_| {});
    let lock = GenLock::try_acquire(&dir.0).unwrap().unwrap();
    assert_eq!(
        migrate(&dir.0),
        blocked(BlockCode::Migrating, BLOCKED_MIGRATING)
    );
    assert_eq!(status(&dir.0), Ok(GenState::MigratingElsewhere));
    drop(lock);
    let writer = raw(&dir.0);
    writer.execute_batch("BEGIN IMMEDIATE").unwrap();
    assert_eq!(migrate(&dir.0), blocked(BlockCode::Busy, BLOCKED_BUSY));
    writer.execute_batch("ROLLBACK").unwrap();
    drop(writer);
    assert!(!dir.0.join(GEN4_TEMP).exists());
    assert!(!dir.0.join(GEN4_FILE).exists());

    // 比这一版的协议 3 新：拦下（装新版本），不是升级。不是协议 3 的库：拦下。
    let newer = crate::store::schema::SCHEMA_VERSION + 1;
    raw(&dir.0)
        .execute(
            "UPDATE srs_meta SET value = ?1 WHERE key = 'schema'",
            [newer.to_string()],
        )
        .unwrap();
    let Outcome::Blocked { code, reason } = migrate(&dir.0) else {
        panic!()
    };
    assert_eq!(code, BlockCode::SchemaNewer, "{reason}");
    assert!(reason.contains(&format!("schema {newer}")), "{reason}");
    raw(&dir.0)
        .execute("UPDATE srs_meta SET value = 'x' WHERE key = 'schema'", [])
        .unwrap();
    let Outcome::Blocked { code, .. } = migrate(&dir.0) else {
        panic!()
    };
    assert_eq!(code, BlockCode::NotProtocol3);
    raw(&dir.0)
        .execute(
            "UPDATE srs_meta SET value = ?1 WHERE key = 'schema'",
            [SEALED_SCHEMA.to_string()],
        )
        .unwrap();
    let Outcome::Blocked { code, reason } = migrate(&dir.0) else {
        panic!()
    };
    assert_eq!(code, BlockCode::SealedWithoutNew, "{reason}");
    assert!(reason.contains("sealed"), "{reason}");
    assert_eq!(status(&dir.0), Ok(GenState::SealedOldOnly));

    let empty = tempdir::new("g72-empty");
    let Outcome::Blocked { code, reason } = migrate(&empty.0) else {
        panic!()
    };
    assert_eq!(code, BlockCode::NoLibrary, "{reason}");
    assert!(reason.contains("no protocol 3 library"), "{reason}");
    assert_eq!(status(&empty.0), Ok(GenState::Ready));
}

/// 叫停：开跑前就停 / 灌入中途停，都报叫停、临时文件删掉、旧库逐字节不变；之后照常能迁。
#[test]
fn a_cancelled_migration_leaves_nothing_behind() {
    let dir = legacy_dir("g72-cancel", &|_| {});
    let before = masked(&dir.0);
    let stop = Stop::new();
    stop.stop();
    assert_eq!(
        migrate_with(&dir.0, &caches(), &stop, &mut Vec::new()),
        Outcome::Cancelled
    );
    let stop = Stop::new();
    let out = run(
        &dir.0,
        Options {
            caches: &caches(),
            batch: 2,
            now_ms: NOW,
            stop: &stop,
            progress: &mut |s, done, _| {
                if s == Step::Translate && done > 0 {
                    stop.stop();
                }
            },
            new_device: &fixed_device,
        },
    )
    .unwrap();
    assert_eq!(out, Outcome::Cancelled);
    assert!(!dir.0.join(GEN4_TEMP).exists());
    assert!(!dir.0.join(GEN4_FILE).exists());
    assert_eq!(masked(&dir.0), before);
    assert_eq!(migrate(&dir.0).verdict(), "committed");
}

/// 一个协议 3 profile 都没有的空库（没有身份可记成迁移来源）：迁成空的新代库并封存。改名之后、封存之前被杀的，
/// 重跑认得出旁边是一份空的旧库，补封。
#[test]
fn an_empty_library_migrates_to_an_empty_one() {
    for crash in [false, true] {
        let dir = tempdir::new("g72-blank");
        let core = SrsCore::open(&dir.0.join(LEGACY_FILE)).unwrap();
        core.close();
        drop(core);
        if crash {
            assert_eq!(crash_child(&dir.0, "seal:1"), Some(CRASHED));
            assert!(dir.0.join(GEN4_FILE).exists());
            assert_eq!(
                schema_of(&dir.0),
                crate::store::schema::SCHEMA_VERSION.to_string()
            );
        }
        let out = migrate_with(&dir.0, &BTreeMap::new(), &Stop::new(), &mut Vec::new());
        assert_eq!(out.verdict(), "committed", "{out:?}");
        assert_eq!(schema_of(&dir.0), SEALED_SCHEMA.to_string());
        let opened = open_gen4(&dir.0, OpenMode::Primary).unwrap();
        let n: i64 = opened
            .conn
            .query_row("SELECT COUNT(*) FROM collections", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 0);
    }
}

/// 已删的换代前预演（G7-6）在库旁留下的工作目录（临时新库可能含旧库内容的副本）：迁移拿到换代锁就删掉，迁移之后
/// profile 目录里不再有它；迁移已经提交过、只是重跑（补封 / 补改名）时同样删。
#[test]
fn a_leftover_rehearsal_work_dir_is_removed_by_the_migration() {
    let dir = legacy_dir("g76-rehearsal-left", &|_| {});
    let leave = |dir: &Path| {
        let work = dir.join(LEFTOVER_REHEARSAL_DIR);
        std::fs::create_dir_all(&work).unwrap();
        std::fs::write(work.join("gen4-dryrun.db"), b"old content copy").unwrap();
        std::fs::write(work.join("report.json"), b"{}").unwrap();
    };
    leave(&dir.0);
    let out = migrate(&dir.0);
    assert_eq!(out.verdict(), "committed", "{out:?}");
    assert!(!dir.0.join(LEFTOVER_REHEARSAL_DIR).exists());
    leave(&dir.0);
    let again = migrate(&dir.0);
    assert_eq!(again.verdict(), "committed", "{again:?}");
    assert!(!dir.0.join(LEFTOVER_REHEARSAL_DIR).exists());
}

/// 已经迁移完的库（早期预发布版迁的，不再走迁移拿锁那一步）：库旁残留的预演目录在新代库按 Primary 打开时清掉；
/// Secondary 打开不动它（不是这个目录的写者）。
#[test]
fn a_leftover_rehearsal_work_dir_is_removed_when_the_primary_opens() {
    use crate::store::gen4::kernel::G4Core;
    let dir = legacy_dir("g76-rehearsal-open", &|_| {});
    assert_eq!(migrate(&dir.0).verdict(), "committed");
    let work = dir.0.join(LEFTOVER_REHEARSAL_DIR);
    std::fs::create_dir_all(&work).unwrap();
    std::fs::write(work.join("gen4-dryrun.db"), b"old content copy").unwrap();
    drop(G4Core::open(&dir.0, OpenMode::Secondary).unwrap());
    assert!(
        work.exists(),
        "a secondary open must not touch the directory"
    );
    drop(G4Core::open(&dir.0, OpenMode::Primary).unwrap());
    assert!(!work.exists());
    // 没有残留也照常打开。
    drop(G4Core::open(&dir.0, OpenMode::Primary).unwrap());
}

/// 预演与迁移走同一套阶段代码：同一份库，预演的每个 profile 报告与迁移的逐项相同（只差新身份那一节与耗时 / 内存）。
#[test]
fn the_rehearsal_and_the_migration_run_the_same_stages() {
    let dir = legacy_dir("g72-same", &|_| {});
    let caches = caches();
    let stop = Stop::new();
    let rehearsal = dryrun::run(
        &dir.0.join(LEGACY_FILE),
        &dir.0.join("work"),
        dryrun::Options {
            caches: &caches,
            batch: 2,
            keep: false,
            examples: DEFAULT_EXAMPLES,
            full_examples: false,
            stop: &stop,
            progress: &mut |_, _| {},
        },
    )
    .unwrap();
    let Outcome::Committed { report } = migrate(&dir.0) else {
        panic!()
    };
    let strip = |v: &Value| -> Value {
        let mut m = v.as_object().unwrap().clone();
        m.retain(|k, _| !(k.ends_with('S') || k.starts_with("peakMb") || k == "identity"));
        Value::Object(m)
    };
    assert_eq!(
        strip(&rehearsal["profiles"][0]),
        strip(&report["profiles"][0])
    );
}

// ---------------------------------------------------------------- 断点（子进程）

const CHILD_DIR: &str = "FUSHI_G72_CHILD_DIR";
const CHILD_CRASH: &str = "FUSHI_G72_CRASH_AT";
/// 子进程在断点上退出用的码（父进程据此确认断点真的走到了）。
const CRASHED: i32 = 86;

/// 子进程那一半：环境变量给了目录才动作。跑迁移，第 n 次报到指定步骤时立刻 `exit`（不跑析构、不关连接、不放锁——
/// 等同被杀，操作系统收回文件锁）。
#[test]
fn migrate_child_process_half() {
    let Ok(dir) = std::env::var(CHILD_DIR) else {
        return;
    };
    let at = std::env::var(CHILD_CRASH).unwrap();
    let (step, nth) = at.split_once(':').unwrap();
    let nth: u64 = nth.parse().unwrap();
    let mut seen = 0u64;
    let caches = caches();
    let stop = Stop::new();
    let r = run(
        Path::new(&dir),
        Options {
            caches: &caches,
            batch: 2,
            now_ms: NOW,
            stop: &stop,
            progress: &mut |s, _, _| {
                if s.wire() == step {
                    seen += 1;
                    if seen == nth {
                        std::process::exit(CRASHED);
                    }
                }
            },
            new_device: &fixed_device,
        },
    );
    panic!("the crash point {at} was never reached: {r:?}");
}

/// 在 [dir] 上起一个子进程跑迁移、到 [at] 退出；返回退出码。
fn crash_child(dir: &Path, at: &str) -> Option<i32> {
    let out = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "store::gen4::migrate::tests::migrate_child_process_half",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(CHILD_DIR, dir)
        .env(CHILD_CRASH, at)
        .output()
        .unwrap();
    if out.status.code() != Some(CRASHED) {
        eprintln!(
            "{at}: {}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    out.status.code()
}

/// 每一步之后被杀（灌入中途的事务里、对拍两段之间、提交前、改名之后封存之前……）：提交点之前旧库逐字节不变、不会有
/// 新代库；改名之后封存之前新代库已在、旧库还没封。重跑一律提交，结果与一次跑完的逐表逐行相同，旧库封存、不留临时文件。
#[test]
fn every_crash_point_resumes_to_the_same_library() {
    let base = legacy_dir("g72-crash", &|_| {});
    let reference = copy_dir(&base.0, "g72-crash-ref");
    assert_eq!(migrate(&reference.0).verdict(), "committed");
    let want = dump(&reference.0.join(GEN4_FILE));
    let legacy_before = masked(&base.0);
    for at in [
        "lock:1",
        "precondition:1",
        "translate:1",
        "translate:3",
        "salts:1",
        "rebuild:1",
        "parity:1",
        "parity:2",
        "commit:1",
        "seal:1",
    ] {
        let d = copy_dir(&base.0, &format!("g72-crash-{}", at.replace(':', "-")));
        assert_eq!(crash_child(&d.0, at), Some(CRASHED), "{at}");
        let v3 = crate::store::schema::SCHEMA_VERSION.to_string();
        assert_eq!(
            schema_of(&d.0),
            v3,
            "{at}: the legacy library is not sealed yet"
        );
        if at == "seal:1" {
            assert!(d.0.join(GEN4_FILE).exists(), "{at}");
        } else {
            assert!(!d.0.join(GEN4_FILE).exists(), "{at}");
            assert_eq!(masked(&d.0), legacy_before, "{at}");
        }
        let out = migrate(&d.0);
        assert_eq!(out.verdict(), "committed", "{at}: {out:?}");
        assert_eq!(dump(&d.0.join(GEN4_FILE)), want, "{at}");
        assert_eq!(schema_of(&d.0), SEALED_SCHEMA.to_string(), "{at}");
        assert!(!d.0.join(GEN4_TEMP).exists(), "{at}");
    }
}

/// 提交之后、封存之前中断的另一条续做路径：不重跑迁移，直接 Primary 打开新代库，也在锁里补封。
#[test]
fn opening_after_a_lost_seal_finishes_it() {
    let base = legacy_dir("g72-reseal", &|_| {});
    assert_eq!(crash_child(&base.0, "seal:1"), Some(CRASHED));
    assert_eq!(
        schema_of(&base.0),
        crate::store::schema::SCHEMA_VERSION.to_string()
    );
    drop(open_gen4(&base.0, OpenMode::Primary).unwrap());
    assert_eq!(schema_of(&base.0), SEALED_SCHEMA.to_string());
}

// ---------------------------------------------------------------- 复核补的不变量

/// 协议 3 一侧的缓存基准拿不到（一条笔记身份记录缺 `noteTypeId`，协议 3 的缓存重建整次失败）：对拍没做全，结论
/// `incomplete`，与对拍不过一样中止——不提交、不封存，旧库逐字节不变，没有新代库。
#[test]
fn an_incomplete_parity_aborts_like_a_failure() {
    let Device { core, _dir: dir } =
        crate::store::gen4::dryrun::tests::library_with_a_malformed_note("g72-incomplete");
    core.close();
    drop(core);
    let before = masked(&dir.0);
    let out = migrate(&dir.0);
    let Outcome::Aborted { reason, report, .. } = &out else {
        panic!("{out:?}")
    };
    assert_eq!(*reason, AbortReason::Incomplete);
    assert_eq!(out.json()["failure"]["reason"], "incomplete");
    assert_eq!(report["verdict"], "aborted");
    assert_eq!(report["profileVerdict"], "incomplete", "{report:#}");
    assert_eq!(report["profiles"][0]["verdict"], "incomplete", "{report:#}");
    assert!(!dir.0.join(GEN4_FILE).exists());
    assert!(!dir.0.join(GEN4_TEMP).exists());
    assert_eq!(masked(&dir.0), before);
    assert_eq!(
        schema_of(&dir.0),
        crate::store::schema::SCHEMA_VERSION.to_string()
    );
    assert_eq!(
        status(&dir.0),
        Ok(GenState::MigrationFailed(Failure::Aborted(
            AbortReason::Incomplete
        )))
    );
}

/// 改名之后、封存之前被杀，之后退回旧版本往 `srs.db` 写了一笔（写锁随进程没了）：迁移来源的身份没变、日志水位
/// 变了。重跑与 Primary 打开都不封它（封了那一笔就进不了新代），报「旁边有没迁移的协议 3 库」，旧库照常能用。
#[test]
fn a_write_after_the_commit_point_keeps_the_library_unsealed() {
    let dir = legacy_dir("g72-late-write", &|_| {});
    assert_eq!(crash_child(&dir.0, "seal:1"), Some(CRASHED));
    assert!(dir.0.join(GEN4_FILE).exists());
    let core = SrsCore::open(&dir.0.join(LEGACY_FILE)).unwrap();
    let input = json!([{
        "e": crate::store::sync2::tests::edit("note", N2, "f/fa", json!("猫")),
        "note": "N1"
    }]);
    core.sync2_apply_local(P, NOW, &input.to_string()).unwrap();
    core.close();
    drop(core);
    let v3 = crate::store::schema::SCHEMA_VERSION.to_string();
    let out = migrate(&dir.0);
    assert_eq!(out.verdict(), "blocked", "{out:?}");
    assert_eq!(schema_of(&dir.0), v3);
    assert_eq!(
        open_gen4(&dir.0, OpenMode::Primary).err(),
        Some(files::OpenError::LegacyNotMigrated)
    );
    assert_eq!(schema_of(&dir.0), v3);
    drop(SrsCore::open(&dir.0.join(LEGACY_FILE)).unwrap());
}

/// 封存落了盘、改名没有（文件系统不守序时断电）：只剩封存了的 `srs.db` 与记着它为来源的 `srs4.db-migrating`。状态
/// 报「要迁移」，重跑补做改名，结果与一次跑完的逐表相同。临时文件记的来源对不上时不碰它：照旧报「只剩封存了的
/// 旧库」、拦下。
#[test]
fn a_seal_that_landed_without_its_rename_is_finished_by_a_rerun() {
    let base = legacy_dir("g72-lost-rename", &|_| {});
    let reference = copy_dir(&base.0, "g72-lost-rename-ref");
    assert_eq!(migrate(&reference.0).verdict(), "committed");
    let want = dump(&reference.0.join(GEN4_FILE));
    for tamper in [false, true] {
        let d = copy_dir(&base.0, &format!("g72-lost-rename-{tamper}"));
        assert_eq!(migrate(&d.0).verdict(), "committed");
        std::fs::rename(d.0.join(GEN4_FILE), d.0.join(GEN4_TEMP)).unwrap();
        if tamper {
            Connection::open(d.0.join(GEN4_TEMP))
                .unwrap()
                .execute(
                    "UPDATE srs_meta SET value = 'other' WHERE key = ?1",
                    [files::MIGRATED_LOG_KEY],
                )
                .unwrap();
            assert_eq!(status(&d.0), Ok(GenState::SealedOldOnly));
            let out = migrate(&d.0);
            assert_eq!(out.verdict(), "blocked", "{out:?}");
            assert!(d.0.join(GEN4_TEMP).exists());
            assert!(!d.0.join(GEN4_FILE).exists());
            continue;
        }
        assert_eq!(status(&d.0), Ok(GenState::NeedsMigration));
        let out = migrate(&d.0);
        let Outcome::Committed { report } = &out else {
            panic!("{out:?}")
        };
        assert_eq!(report["recoveredRename"], true, "{report:#}");
        assert!(!d.0.join(GEN4_TEMP).exists());
        assert_eq!(dump(&d.0.join(GEN4_FILE)), want);
        assert_eq!(schema_of(&d.0), SEALED_SCHEMA.to_string());
        assert_eq!(status(&d.0), Ok(GenState::Ready));
    }
}

/// 新身份的 `prev` 必须指得到灌进来的那一槽、链指纹相同：`sync2_self` 记的末尾链值与日志对不上、或末尾 seq 超出
/// 日志，迁移报错停下，不提交、不封存，旧库不变、不留临时文件。
#[test]
fn a_prev_that_misses_the_imported_log_stops_the_migration() {
    let cases: [(&str, &str); 2] = [
        (
            "g72-prev-chain",
            "UPDATE sync2_self SET chain = zeroblob(32) WHERE profile_uid = srs_id(?1)",
        ),
        (
            "g72-prev-seq",
            "UPDATE sync2_self SET next_seq = next_seq + 3 WHERE profile_uid = srs_id(?1)",
        ),
    ];
    for (tag, sql) in cases {
        let dir = legacy_dir(tag, &|_| {});
        raw(&dir.0).execute(sql, [P]).unwrap();
        let before = masked(&dir.0);
        let caches = caches();
        let stop = Stop::new();
        let r = run(
            &dir.0,
            Options {
                caches: &caches,
                batch: 2,
                now_ms: NOW,
                stop: &stop,
                progress: &mut |_, _, _| {},
                new_device: &fixed_device,
            },
        );
        let e = r.expect_err(tag);
        assert!(e.contains("previous identity"), "{tag}: {e}");
        assert!(!dir.0.join(GEN4_FILE).exists(), "{tag}");
        assert!(!dir.0.join(GEN4_TEMP).exists(), "{tag}");
        assert_eq!(masked(&dir.0), before, "{tag}");
        assert_eq!(
            schema_of(&dir.0),
            crate::store::schema::SCHEMA_VERSION.to_string(),
            "{tag}"
        );
    }
}

/// 协议 3 给每张卡都发了 AnkiConnect 数字 id（缓存行的 `anki_id`），从没复习、没改过的卡也有；带盐的笔记（笔记类型、
/// 字段、模板、笔记的 ID 都是按 profile uid 加盐的规则值——迁移把 profile uid 记成盐）的这种卡从没在任何操作里出现过，
/// 新代的别名表里没有它。迁移之后协议 3 缓存表里每张卡、每条笔记的号用 `anki_resolve` 都查得到规范行，且所属笔记、
/// 模板、cloze 序号与协议 3 那一行对得上（`cache.rs` 文件头「表」的 `anki_members`）。
#[test]
fn every_protocol_3_card_number_resolves_after_migration() {
    use crate::gen4_ids::rules;
    use crate::store::gen4::cmd::columns::anki_resolve;
    use crate::store::gen4::derive::{Index, Ref};
    use crate::store::sync2::tests::edit;
    use crate::sync2::id::Key;

    const ANKI_NT: i64 = 1_700_000_000_777;
    let nt = rules::note_type(Some(P), ANKI_NT);
    let (field, tmpl) = (rules::field(&nt, 0), rules::template(&nt, 0));
    let note = rules::note(Some(P), "g74g-guid");
    let d = library("g74g-anki-ids");
    d.apply(
        T0 + 2 * 86_400_000,
        vec![
            json!({"t": "entity", "x": {"id": nt.text(), "p": P, "k": "notetype",
                   "d": {"createdAt": 1, "ntKind": "standard", "ankiNum": ANKI_NT}}}),
            edit(
                "notetype",
                &nt.text(),
                &format!("fieldDef/{}", field.text()),
                json!({"ankiNum": 0, "name": "E", "ord": 0}),
            ),
            edit(
                "notetype",
                &nt.text(),
                &format!("tmplDef/{}", tmpl.text()),
                json!({"ankiNum": 0, "name": "A", "ord": 0, "front": "{{E}}"}),
            ),
            json!({"t": "entity", "x": {"id": note.text(), "p": P, "k": "note",
                   "d": {"createdAt": 5, "guid": "g74g-guid", "noteTypeId": nt.text()}}}),
            edit(
                "note",
                &note.text(),
                &format!("f/{}", field.text()),
                json!("猫"),
            ),
        ],
    );
    // 协议 3 的缓存表不随本地写入刷新（`library` 也是写完再整份重建）：同一份配置重建一次。
    let parsed =
        crate::store::caches::CacheConfig::parse(&serde_json::from_str(&cfg()).unwrap()).unwrap();
    let w = d.core.writer().unwrap();
    crate::store::sync2::in_savepoint(&w, |c| crate::store::caches::rebuild(c, P, &parsed))
        .unwrap();
    drop(w);
    let Device { core, _dir: dir } = d;
    core.close();
    drop(core);
    let rows = |q: &str| -> Vec<(String, String, i64, i64)> {
        let c = raw(&dir.0);
        let mut stmt = c.prepare(q).unwrap();
        stmt.query_map([P], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    // (卡, 笔记, 模板 + cloze 序号, 号)
    let cards: Vec<(String, String, String, i64)> = {
        let c = raw(&dir.0);
        let mut stmt = c
            .prepare(
                "SELECT srs_idt(id), srs_idt(note_id), srs_idt(template_id) || '/' || cloze_ord, anki_id \
                 FROM srs_cards_cache WHERE profile_uid = srs_id(?1) ORDER BY 1",
            )
            .unwrap();
        stmt.query_map([P], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    let notes = rows(
        "SELECT srs_idt(id), '', 0, anki_id FROM srs_notes_cache WHERE profile_uid = srs_id(?1) ORDER BY 1",
    );
    let salted_card = rules::card(&note, &tmpl, 0).text();
    assert!(
        cards.iter().any(|c| c.0 == salted_card),
        "the salted note's card must be in the protocol 3 cache: {cards:?}"
    );
    assert!(cards.len() >= 5 && notes.len() >= 3, "{cards:?} {notes:?}");

    let out = migrate(&dir.0);
    assert_eq!(out.verdict(), "committed", "{out:?}");
    let opened = open_gen4(&dir.0, OpenMode::Primary).unwrap();
    let t = Truth::new(&opened.conn);
    let col = t.binding_of(P).unwrap().unwrap().col;
    let canon = |s: &str| -> String {
        Index::new(&t, col)
            .canonical(&Ref::of(&Key::of(s)))
            .unwrap()
            .text()
    };
    // 那张带盐的卡从没出现在操作里：别名表里没有它。
    assert_eq!(canon(&salted_card), salted_card, "no alias row for it");
    assert!(
        canon(&note.text()) != note.text(),
        "the salted note itself is an alias member"
    );
    let req = json!({
        "notes": notes.iter().map(|n| n.3).collect::<Vec<_>>(),
        "cards": cards.iter().map(|c| c.3).collect::<Vec<_>>(),
    });
    let v = anki_resolve(&t, col, &req).unwrap();
    for (n, got) in notes.iter().zip(v["notes"].as_array().unwrap()) {
        assert_eq!(got, &json!(canon(&n.0)), "note {}", n.0);
    }
    let mut via_members = 0;
    for (c, got) in cards.iter().zip(v["cards"].as_array().unwrap()) {
        let got = got
            .as_str()
            .unwrap_or_else(|| panic!("card {} ({}) does not resolve: {v}", c.0, c.3));
        let (note_id, tpl): (Ref, String) = opened
            .conn
            .query_row(
                "SELECT note_id, template_id FROM cards WHERE col = ?1 AND id = ?2",
                rusqlite::params![col, Ref::of(&Key::of(got))],
                |r| {
                    let t: Ref = r.get(1)?;
                    Ok((r.get(0)?, t.text()))
                },
            )
            .unwrap();
        let ord: i64 = opened
            .conn
            .query_row(
                "SELECT cloze_ord FROM cards WHERE col = ?1 AND id = ?2",
                rusqlite::params![col, Ref::of(&Key::of(got))],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(note_id.text(), canon(&c.1), "card {}", c.0);
        let (p3_tpl, p3_ord) = c.2.rsplit_once('/').unwrap();
        assert_eq!(tpl, canon(p3_tpl), "card {}", c.0);
        assert_eq!(ord.to_string(), p3_ord, "card {}", c.0);
        via_members += usize::from(got != c.0);
    }
    assert!(
        via_members >= 1,
        "the salted card resolves through its members"
    );
}

/// 交接 §26 C1：几乎每个真实用户的库都有「没改过的内置笔记类型」的笔记——笔记类型、字段、模板、默认牌组全是按
/// profile uid 加盐的存量 ID，字段 ID 只嵌在笔记的 `f/<字段>` 键里，卡从没出现在操作里，评分日志带作答时的配置快照
/// （`sc`，迁移后会重放）。迁移只拿到宿主的**规范**缓存配置（Dart `srsCacheConfigFor`，不带盐），对拍时协议 3 那份由
/// 内核派生：迁移判 committed、对拍与规范化都没有差异；迁移后每条笔记字段不空、每张卡不隐藏，到期日、间隔逐张与协议 3
/// 当时算的相同（fuzz 种子是作答时的带盐卡，不是规范卡）。另有两条从没复习、没改过的笔记（卡从没出现在任何操作里，
/// 内置模板只嵌在宿主配置里）：协议 3 给每张卡发的 AnkiConnect 数字 id 迁移后都按号反查得到对应的规范卡。
#[test]
fn a_salted_library_of_untouched_builtin_note_types_migrates_unchanged() {
    use crate::gen4_ids::rules::{self, CANONICAL};
    use crate::store::gen4::cmd::columns::anki_resolve;
    use crate::store::gen4::derive::Ref;
    use crate::store::gen4::truth::Truth;
    use crate::store::sync2::config::default_deck_id;
    use crate::store::sync2::tests::{DAY, deck_entity, edit, review};
    use crate::sync2::id::Key;

    let lapis = rules::builtin_note_type_anki_num("lapis");
    let field_n = rules::builtin_field_anki_num("lapis", "Expression");
    let tmpl_n = rules::builtin_template_anki_num("lapis", "Card 1");
    let cfg_for = |salt: Option<&str>| -> String {
        let nt = rules::note_type(salt, lapis);
        let f = rules::field(&nt, field_n).text();
        let tpl = rules::template(&nt, tmpl_n).text();
        json!({
            "defaultDeck": rules::builtin_default_deck(salt).text(),
            "builtins": {"lapis": {"b": {
                "name": "Lapis", "css": "", "termFieldId": f,
                "fields": [{"id": f, "name": "Expression", "ord": 0}],
                "templates": [{"id": tpl, "name": "Card 1", "ord": 0,
                               "front": "{{Expression}}", "back": "{{FrontSide}}"}],
            }, "reading": null}},
        })
        .to_string()
    };
    let (s_nt, c_nt) = (
        rules::note_type(Some(P), lapis),
        rules::note_type(CANONICAL, lapis),
    );
    let (s_field, s_tmpl, c_tmpl) = (
        rules::field(&s_nt, field_n),
        rules::template(&s_nt, tmpl_n),
        rules::template(&c_nt, tmpl_n),
    );
    assert_eq!(
        default_deck_id(P),
        rules::builtin_default_deck(Some(P)).text()
    );
    let words = ["猫", "犬", "鳥", "魚", "馬", "牛", "羊", "猿"];
    // 从没复习过的两条（卡不进任何操作）。
    let quiet = ["鹿", "熊"];

    let d = Device::new("k1-builtin");
    d.core.sync2_identity(P, T0).unwrap();
    while d.core.sync2_migrate(P, T0, None).unwrap()["done"] != json!(true) {}
    let mut events = vec![
        deck_entity(&default_deck_id(P)),
        json!({"t": "entity", "x": {"id": s_nt.text(), "p": P, "k": "notetype",
               "d": {"createdAt": 1, "ntKind": "standard", "builtin": "lapis", "ankiNum": lapis}}}),
    ];
    // (带盐卡, 规范卡, 带盐笔记)
    let mut cards: Vec<(String, Id, String)> = Vec::new();
    for (i, w) in words.iter().chain(&quiet).enumerate() {
        let guid = format!("k1-guid-{i}");
        let note = rules::note(Some(P), &guid);
        events.push(
            json!({"t": "entity", "x": {"id": note.text(), "p": P, "k": "note",
                           "d": {"createdAt": 1, "guid": guid, "noteTypeId": s_nt.text()}}}),
        );
        events.push(edit(
            "note",
            &note.text(),
            &format!("f/{}", s_field.text()),
            json!(w),
        ));
        cards.push((
            rules::card(&note, &s_tmpl, 0).text(),
            rules::card(&rules::note(CANONICAL, &guid), &c_tmpl, 0),
            note.text(),
        ));
    }
    d.apply(T0, events);
    // 评分日志与 app 写的同形：ID 是 UUIDv7、记上它的笔记（`Device::apply` 给的是占位笔记）。别名证据只收 UUID 形
    // 的日志（`alias.rs` `alias_evidence`），日志上的卡才算观察到、才认得出它是哪张规范卡。
    for (k, at) in [0, DAY, 3 * DAY, 8 * DAY, 20 * DAY].into_iter().enumerate() {
        let rtype = if k == 0 { "learn" } else { "review" };
        let logs: Vec<Value> = cards[..words.len()]
            .iter()
            .enumerate()
            .map(|(i, (c, _, n))| {
                let id = format!("0193a1b2-0000-7000-8000-{:012x}", 0xc100 + 16 * k + i);
                json!({"e": review(&id, c, T0 + at, 3, rtype), "note": n})
            })
            .collect();
        d.core
            .sync2_apply_local(P, T0 + at, &Value::Array(logs).to_string())
            .unwrap();
    }
    // 协议 3 的缓存按带盐的那份配置建（真实用户的库就是这样）。
    let salted = cfg_for(Some(P));
    let parsed =
        crate::store::caches::CacheConfig::parse(&serde_json::from_str(&salted).unwrap()).unwrap();
    let w = d.core.writer().unwrap();
    crate::store::sync2::in_savepoint(&w, |c| crate::store::caches::rebuild(c, P, &parsed))
        .unwrap();
    drop(w);
    let Device { core, _dir: dir } = d;
    core.close();
    drop(core);
    // 协议 3 算的：带盐卡 → (到期日, 间隔, 隐藏)。
    let old: BTreeMap<String, (Option<i64>, Option<i64>, i64)> = {
        let c = raw(&dir.0);
        let mut stmt = c
            .prepare(
                "SELECT srs_idt(id), due_day, scheduled_days, hidden FROM srs_cards_cache \
                 WHERE profile_uid = srs_id(?1)",
            )
            .unwrap();
        stmt.query_map([P], |r| Ok((r.get(0)?, (r.get(1)?, r.get(2)?, r.get(3)?))))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(old.len(), words.len() + quiet.len(), "{old:?}");
    // 协议 3 发的数字 id：带盐卡 → 号。
    let old_nums: Vec<(String, i64)> = {
        let c = raw(&dir.0);
        let mut stmt = c
            .prepare(
                "SELECT srs_idt(id), anki_id FROM srs_cards_cache WHERE profile_uid = srs_id(?1) ORDER BY 1",
            )
            .unwrap();
        stmt.query_map([P], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(old_nums.len(), old.len());
    assert!(
        old.values().all(|v| v.2 == 0),
        "protocol 3 shows every card: {old:?}"
    );
    assert!(
        old.values().any(|v| v.1.is_some_and(|ivl| ivl >= 3)),
        "the history must reach fuzzed intervals: {old:?}"
    );

    let canonical = BTreeMap::from([(P.to_owned(), cfg_for(CANONICAL))]);
    let out = migrate_with(&dir.0, &canonical, &Stop::new(), &mut Vec::new());
    let Outcome::Committed { report } = &out else {
        panic!("{out:?}")
    };
    let p = &report["profiles"][0];
    assert_eq!(p["verdict"], "pass", "{p:#}");
    assert_eq!(p["parity"], json!([]), "{p:#}");
    assert_eq!(p["canonical"], json!([]), "{p:#}");

    let opened = open_gen4(&dir.0, OpenMode::Primary).unwrap();
    let mut sorts: Vec<String> = opened
        .conn
        .prepare("SELECT sort_field FROM notes")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    sorts.sort();
    let mut want: Vec<String> = words
        .iter()
        .chain(&quiet)
        .map(|w| (*w).to_owned())
        .collect();
    want.sort();
    assert_eq!(sorts, want, "every note keeps its field");
    for (salted_card, canon, _) in &cards {
        let got: (Option<i64>, Option<i64>, i64) = opened
            .conn
            .query_row(
                "SELECT due_day, scheduled_days, hidden FROM cards WHERE id = ?1",
                rusqlite::params![Ref::of(&Key::Uuid(*canon))],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap_or_else(|e| panic!("card {} has no row: {e}", canon.text()));
        assert_eq!(
            got,
            old[salted_card],
            "card {salted_card} → {}",
            canon.text()
        );
    }
    let t = Truth::new(&opened.conn);
    let col = t.binding_of(P).unwrap().unwrap().col;
    let req = json!({"cards": old_nums.iter().map(|(_, n)| *n).collect::<Vec<_>>()});
    let got = anki_resolve(&t, col, &req).unwrap();
    for ((salted_card, num), got) in old_nums.iter().zip(got["cards"].as_array().unwrap()) {
        let want = &cards.iter().find(|c| &c.0 == salted_card).unwrap().1;
        assert_eq!(
            got,
            &json!(want.text()),
            "protocol 3 card {salted_card} (#{num}) resolves to its canonical card"
        );
    }
}

/// 空间核对（G9-5 修 G7-2b 复核遗留）：上一次留下的迁移临时文件与补完副本（连同 WAL）算可用空间；补完之后的第二次核对
/// 时补完副本在用（之后的阶段还要读它），不算。
#[test]
fn an_in_use_preparation_copy_is_not_counted_as_free_space() {
    let dir = tempdir::new("g95-space");
    std::fs::write(dir.0.join(GEN4_TEMP), vec![0u8; 100]).unwrap();
    let copy = dir.0.join(PREPARE_COPY);
    std::fs::write(&copy, vec![0u8; 1000]).unwrap();
    std::fs::write(seal::with_suffix(&copy, "-wal"), vec![0u8; 24]).unwrap();
    assert_eq!(reclaimable(&dir.0, PrepCopy::Stale), 1124);
    assert_eq!(reclaimable(&dir.0, PrepCopy::InUse), 100);
}

/// 第二个 profile（uid 排在 [P] 之后）。
const Q: &str = "0193a1b2-0000-7000-8000-00000000cafe";
const QN1: &str = "0193a1b2-0000-7000-8000-0000000000c1";
const QN2: &str = "0193a1b2-0000-7000-8000-0000000000c2";

fn cfg_of(profile: &str) -> String {
    json!({"defaultDeck": crate::store::sync2::config::default_deck_id(profile)}).to_string()
}

/// 两个 profile 的缓存配置。
fn caches_pq() -> BTreeMap<String, String> {
    BTreeMap::from([(P.to_owned(), cfg()), (Q.to_owned(), cfg_of(Q))])
}

/// 在 [core] 里给 [Q] 建与 `dryrun::tests::library` 同形的一份数据：牌组、笔记类型两条模板、两条笔记、一次复习，
/// 缓存表按 [Q] 的配置建好。同一个 `srs.db` 里两个 profile，迁移时各成一个集合。
fn add_second_profile(core: &SrsCore) {
    core.sync2_identity(Q, T0).unwrap();
    while core.sync2_migrate(Q, T0, None).unwrap()["done"] != json!(true) {}
    let entity = |id: &str, kind: &str, d: Value| json!({"t": "entity", "x": {"id": id, "p": Q, "k": kind, "d": d}});
    let edit = |kind: &str, e: &str, key: &str, v: Value| {
        json!({"t": "edit", "x": {
            "id": "ignored", "p": Q, "k": kind, "e": e, "f": key, "w": "dart", "s": 1,
            "ctx": {"vv": {}}, "v": v, "hlc": "0:0:dart", "ts": "anchored"
        }})
    };
    let apply = |now: i64, events: Vec<Value>| {
        let input: Vec<Value> = events
            .into_iter()
            .map(|e| json!({"e": e, "note": "N1"}))
            .collect();
        core.sync2_apply_local(Q, now, &Value::Array(input).to_string())
            .unwrap();
    };
    let deck = crate::store::sync2::config::default_deck_id(Q);
    let tdef = |name: &str, ord: i64| json!({"name": name, "ord": ord, "front": "{{Expression}}"});
    apply(
        T0,
        vec![
            entity(&deck, "deck", json!({"createdAt": 1, "builtin": "default"})),
            entity(
                "NTQ",
                "notetype",
                json!({"createdAt": 1, "ntKind": "standard"}),
            ),
            edit(
                "notetype",
                "NTQ",
                "fieldDef/fa",
                json!({"name": "Expression", "ord": 0}),
            ),
            edit("notetype", "NTQ", "tmplDef/t1", tdef("A", 0)),
            edit("notetype", "NTQ", "tmplDef/t2", tdef("B", 1)),
            entity(
                QN1,
                "note",
                json!({"createdAt": 1, "guid": QN1, "noteTypeId": "NTQ"}),
            ),
            edit("note", QN1, "f/fa", json!("鳥")),
            entity(
                QN2,
                "note",
                json!({"createdAt": 1, "guid": QN2, "noteTypeId": "NTQ"}),
            ),
            edit("note", QN2, "f/fa", json!("魚")),
        ],
    );
    let c1 = crate::registers::card_id(QN1, "t1", 0).unwrap();
    apply(
        T0 + 10,
        vec![json!({"t": "log", "x": {
            "id": "q1", "p": Q, "card": c1, "kind": "review", "rating": 3, "hlc": format!("{}:0:dart", T0 + 10),
            "at": T0 + 10, "ts": "anchored", "origin": "fushi", "rtype": "learn", "utcOff": 0, "rollover": 4,
            "fv": 1, "res": {"queue": "new", "ivl": 0, "step": 0, "reps": 0, "lapses": 0, "scheduler": "fushi"}
        }})],
    );
    let parsed =
        crate::store::caches::CacheConfig::parse(&serde_json::from_str(&cfg_of(Q)).unwrap())
            .unwrap();
    let w = core.writer().unwrap();
    crate::store::sync2::in_savepoint(&w, |c| crate::store::caches::rebuild(c, Q, &parsed))
        .unwrap();
}

/// 同机两个 profile、只有第二个对拍不过（设计 §6.3「同机多 profile：逐集合迁移；一个集合对拍不过，整个文件不提交」）：
/// 整次迁移中止，第一个 profile 的 `pass` 也不提交——没有 `srs4.db`、旧库逐字节不变、还是协议 3 的 schema，两次都一样。
/// 对照：同一份两 profile 的库不改坏就整份提交，两个 profile 都进了新代库。
#[test]
fn one_failing_profile_of_two_keeps_the_whole_file_uncommitted() {
    let ok = legacy_dir("g72-pq-ok", &add_second_profile);
    let out = migrate_with(&ok.0, &caches_pq(), &Stop::new(), &mut Vec::new());
    assert_eq!(out.verdict(), "committed", "{out:?}");
    let profiles: Vec<String> =
        Connection::open_with_flags(ok.0.join(GEN4_FILE), OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap()
            .prepare("SELECT profile_uid FROM collections ORDER BY profile_uid")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
    assert_eq!(profiles, vec![P.to_owned(), Q.to_owned()]);

    let dir = legacy_dir("g72-pq-abort", &add_second_profile);
    raw(&dir.0)
        .execute(
            "DELETE FROM srs_field_edits WHERE entity_kind = 'note' AND entity_id = srs_id(?1) AND field_key = 'f/fa'",
            [QN2],
        )
        .unwrap();
    let before = masked(&dir.0);
    for _ in 0..2 {
        let out = migrate_with(&dir.0, &caches_pq(), &Stop::new(), &mut Vec::new());
        let Outcome::Aborted { report, .. } = &out else {
            panic!("{out:?}")
        };
        assert_eq!(report["verdict"], "aborted");
        let verdicts: Vec<(&str, &str)> = report["profiles"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| {
                (
                    p["profile"].as_str().unwrap_or("?"),
                    p["verdict"].as_str().unwrap(),
                )
            })
            .collect();
        assert_eq!(verdicts, vec![(P, "pass"), (Q, "fail")], "{report:#}");
        assert!(!dir.0.join(GEN4_FILE).exists());
        assert!(!dir.0.join(GEN4_TEMP).exists());
        assert_eq!(masked(&dir.0), before);
        assert_eq!(
            schema_of(&dir.0),
            crate::store::schema::SCHEMA_VERSION.to_string()
        );
        assert_eq!(
            status(&dir.0),
            Ok(GenState::MigrationFailed(Failure::Aborted(
                AbortReason::Fail
            )))
        );
    }
}

/// BUG-5267（反馈 n4WhWEKPtQ）：同库两个 profile 的操作日志里都有同一个实体的身份记录（[P] 的集合里另一台设备写过
/// [Q] 的实体，收段不经本机写入的归属核对）。协议 3 的 `srs_entities` 主键全库共用，只存一行：内容相同的留给先落
/// 投影的 profile，不同的归规范 JSON 小者（`sync2::project_entity`），另一个 profile 名下就没有；新代按集合各存各的。
/// 这里 [Q] 的默认牌组与 [QN1] 的行留在 [Q] 名下、`NTQ` 的行被 [P] 那条内容更小的改写到 [P] 名下。对拍的 `entities`
/// 一类按本 profile 的操作集合比：两个 profile 都对拍通过、整份提交，撞车的实体逐个计数。
#[test]
fn entities_whose_protocol_3_row_another_profile_holds_migrate() {
    let lib = library("g72-pq-taken");
    add_second_profile(&lib.core);
    let peer = Device::new("g72-pq-taken-peer");
    let entity = |id: &str, kind: &str, d: Value| json!({"t": "entity", "x": {"id": id, "p": P, "k": kind, "d": d}});
    let deck_q = crate::store::sync2::config::default_deck_id(Q);
    peer.apply(
        T0 + 20,
        vec![
            entity(
                &deck_q,
                "deck",
                json!({"createdAt": 1, "builtin": "default"}),
            ),
            entity(
                "NTQ",
                "notetype",
                json!({"createdAt": 0, "ntKind": "standard"}),
            ),
            entity(
                QN1,
                "note",
                json!({"createdAt": 1, "guid": QN1, "noteTypeId": "NTQ"}),
            ),
        ],
    );
    let mut bucket = Bucket::default();
    peer.sync(&mut bucket, "loc", T0 + 30);
    lib.sync(&mut bucket, "loc", T0 + 30);
    let owner = |id: &str| -> String {
        lib.rows(&format!(
            "SELECT srs_idt(profile_uid) AS p FROM srs_entities WHERE id = srs_id('{id}')"
        ))[1][0]
            .clone()
    };
    assert_eq!(owner(&deck_q), Q);
    assert_eq!(owner("NTQ"), P);
    assert_eq!(owner(QN1), Q);
    let Device { core, _dir: dir } = lib;
    core.close();
    drop(core);

    let out = migrate_with(&dir.0, &caches_pq(), &Stop::new(), &mut Vec::new());
    let report = match &out {
        Outcome::Committed { report } | Outcome::Aborted { report, .. } => report,
        _ => panic!("{out:?}"),
    };
    assert_eq!(out.verdict(), "committed", "{report:#}");
    let by_profile: Vec<(&str, &str, &Value, &Value)> = report["profiles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| {
            (
                p["profile"].as_str().unwrap(),
                p["verdict"].as_str().unwrap(),
                &p["parity"],
                &p["collidedEntities"],
            )
        })
        .collect();
    assert_eq!(
        by_profile,
        vec![
            (P, "pass", &json!([]), &json!(2)),
            (Q, "pass", &json!([]), &json!(1)),
        ],
        "{report:#}"
    );
}

/// 写临时新库写到一半磁盘满（临时库连接设 `max_page_count`，之后的写入撞上真的 `SQLITE_FULL`）：迁移报错，不当成中止
/// 也不当成叫停；旧库逐字节不变、还是协议 3 的 schema、仍可迁移（状态 `NeedsMigration`），临时文件与补完副本都清掉。
/// 去掉限制后重跑照常提交。
#[test]
fn a_disk_full_midway_through_staging_leaves_the_library_as_it_was() {
    // 再加 40 条带长字段的笔记：小夹具的数据装得进建库时就有的根页，写不到「要新页」那一步。
    let dir = legacy_dir("g72-full", &|core| {
        let items: Vec<Value> = (0..40)
            .flat_map(|i| {
                let id = format!("0193a1b2-0000-7000-8000-0000000f{i:04x}");
                [
                    json!({"e": {"t": "entity", "x": {"id": id, "p": P, "k": "note",
                        "d": {"createdAt": 1, "guid": id, "noteTypeId": "NT"}}}, "note": "N1"}),
                    json!({"e": {"t": "edit", "x": {
                        "id": "ignored", "p": P, "k": "note", "e": id, "f": "f/fa", "w": "dart", "s": 1,
                        "ctx": {"vv": {}}, "v": format!("{i}{}", "語".repeat(1500)), "hlc": "0:0:dart",
                        "ts": "anchored"
                    }}, "note": "N1"}),
                ]
            })
            .collect();
        core.sync2_apply_local(P, T0 + 20, &Value::Array(items).to_string())
            .unwrap();
        let parsed =
            crate::store::caches::CacheConfig::parse(&serde_json::from_str(&cfg()).unwrap())
                .unwrap();
        let w = core.writer().unwrap();
        crate::store::sync2::in_savepoint(&w, |c| crate::store::caches::rebuild(c, P, &parsed))
            .unwrap();
    });
    let before = masked(&dir.0);
    STAGE_CONN.with(|h| {
        *h.borrow_mut() = Some(Box::new(|c: &Connection| {
            let pages: i64 = c.query_row("PRAGMA page_count", [], |r| r.get(0)).unwrap();
            c.execute_batch(&format!("PRAGMA max_page_count = {pages}"))
                .unwrap();
        }));
    });
    let mut steps = Vec::new();
    let out = run(
        &dir.0,
        Options {
            caches: &caches(),
            batch: 2,
            now_ms: NOW,
            stop: &Stop::new(),
            progress: &mut |s, _, _| {
                if steps.last() != Some(&s) {
                    steps.push(s);
                }
            },
            new_device: &fixed_device,
        },
    );
    STAGE_CONN.with(|h| *h.borrow_mut() = None);
    let err = out.expect_err("a full disk must fail the migration");
    assert!(err.contains("full"), "{err}");
    assert!(steps.contains(&Step::Translate), "{steps:?}");
    assert!(!steps.contains(&Step::Commit), "{steps:?}");
    assert_eq!(masked(&dir.0), before);
    assert_eq!(
        schema_of(&dir.0),
        crate::store::schema::SCHEMA_VERSION.to_string()
    );
    for f in [GEN4_FILE, GEN4_TEMP, PREPARE_COPY] {
        assert!(!dir.0.join(f).exists(), "{f} left behind");
    }
    assert_eq!(status(&dir.0), Ok(GenState::NeedsMigration));
    assert_eq!(migrate(&dir.0).verdict(), "committed");
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// 迁移完的新代库里不随本机新身份变的部分，一行一项：每个集合的 profile、集合标识、目录名、盐集合、新根 meta 的字节
/// （`location::meta4`，纯函数）、本机身份的签名钥匙与 `prev`；每台承袭设备（`devs.src` 有值）的来源集合与日志里每个槽的
/// 规范编码；本机原生日志里每条操作的 (seq, kind, fmt, deps, 载荷)。本机新设备 ID 单独返回。
fn device_independent(dir: &Path) -> (Vec<String>, Vec<Id>) {
    use crate::gen4::location::{MediaRoot, meta4};
    let opened = open_gen4(dir, OpenMode::Primary).unwrap();
    let t = Truth::new(&opened.conn);
    let mut out = Vec::new();
    let mut me_all = Vec::new();
    for profile in [P, Q] {
        let b = t.binding_of(profile).unwrap().unwrap();
        out.push(format!(
            "{profile}: collection {} dir {} salts {:?}",
            b.collection.text(),
            b.dir,
            b.salts
        ));
        out.push(format!(
            "{profile}: meta4 {}",
            hex(&meta4(&b.collection, None, MediaRoot::V4).unwrap())
        ));
        let me = t.self_identity(b.col).unwrap().unwrap();
        out.push(format!("{profile}: sk {} prev {:?}", hex(&me.sk), me.prev));
        me_all.push(me.device);
        let mut heritage = 0;
        for d in t.devices(b.col).unwrap() {
            if d.id == me.device {
                t.for_each(b.col, &d.id, 1, |e| {
                    let op = e.op().expect("native log holds whole ops");
                    out.push(format!(
                        "{profile}: native {} kind {} fmt {} deps {:?} payload {}",
                        e.id.seq,
                        op.kind,
                        op.fmt,
                        op.deps,
                        hex(&op.payload)
                    ));
                    Ok(())
                })
                .unwrap();
                continue;
            }
            let Some(src) = d.src else { continue };
            out.push(format!(
                "{profile}: heritage device {} from {} last {}",
                d.id.text(),
                src.text(),
                d.last
            ));
            t.for_each(b.col, &d.id, 1, |e| {
                let slot = e.slot().expect("a heritage log holds slots");
                heritage += 1;
                out.push(format!(
                    "{profile}: slot {} {}",
                    e.id.seq,
                    hex(&slot.encode())
                ));
                Ok(())
            })
            .unwrap();
        }
        assert!(heritage > 0, "{profile}: no heritage slots");
    }
    (out, me_all)
}

/// 设计 §6.3「两台同时升级」：两台设备各自迁移同一份协议 3 库（两个 profile），本机新设备 ID、迁移时刻、批大小都不同；
/// 转译出的承袭日志逐槽字节相同、集合标识 / 目录名 / 盐集合相同、新根 `meta.json` 字节相同、新身份沿用同一把钥匙且
/// `prev` 指向同一个旧日志末尾，原生日志（那一条 `Salts`）除作者与时间以外也相同。于是两台谁先上传承袭段都一样
/// （重叠上传幂等），谁的新根 meta 覆盖谁都一样。
#[test]
fn two_devices_upgrading_at_once_translate_the_same_bytes() {
    const OTHER_DEV: Id = Id([0x4f; 16]);
    let base = legacy_dir("g72-twin", &add_second_profile);
    let a = copy_dir(&base.0, "g72-twin-a");
    let b = copy_dir(&base.0, "g72-twin-b");
    let out_a = migrate_with(&a.0, &caches_pq(), &Stop::new(), &mut Vec::new());
    assert_eq!(out_a.verdict(), "committed", "{out_a:?}");
    let out_b = run(
        &b.0,
        Options {
            caches: &caches_pq(),
            batch: 3,
            now_ms: NOW + 1_000,
            stop: &Stop::new(),
            progress: &mut |_, _, _| {},
            new_device: &|_, _| OTHER_DEV,
        },
    )
    .unwrap();
    assert_eq!(out_b.verdict(), "committed", "{out_b:?}");
    let (left, devs_a) = device_independent(&a.0);
    let (right, devs_b) = device_independent(&b.0);
    assert_eq!(devs_a, vec![NEW_DEV, NEW_DEV]);
    assert_eq!(devs_b, vec![OTHER_DEV, OTHER_DEV]);
    assert!(left.iter().any(|l| l.contains(": native ")), "{left:#?}");
    let diff: Vec<String> = left
        .iter()
        .zip(&right)
        .filter(|(l, r)| l != r)
        .map(|(l, r)| format!("A {l}\nB {r}"))
        .collect();
    assert!(
        diff.is_empty() && left.len() == right.len(),
        "two devices migrated the same library differently ({} vs {} lines):\n{}",
        left.len(),
        right.len(),
        diff.join("\n")
    );
}

/// BUG-5063（反馈 9G1OHF2dQe）：同一条 Anki revlog 导入到血统里的两张卡上（旧笔记删了、新卡继承旧卡的历史，
/// 再从 Anki 导一次），两份日志 ID 都由各自的带盐卡派生。同一事件的副本只算一份、代表取 ID 最小的那份——协议 3 比
/// 原值 ID，新代比规范 ID，带盐的原值与规范值的先后可以相反。挑一对先后相反的 guid：迁移照样判 committed，对拍
/// 没有差异（统计行、卡行的 `last_log_id` 两边指同一次复习）。
#[test]
fn anki_copies_across_a_lineage_whose_salted_and_canonical_order_differ_migrate_cleanly() {
    use crate::gen4_ids::rules::{self, CANONICAL};
    use crate::store::sync2::config::default_deck_id;
    use crate::store::sync2::tests::{deck_entity, edit};

    const ANKI_NT: i64 = 1_700_000_000_555;
    const RID: i64 = T0 + 5_000;
    let card_of = |salt: Option<&str>, guid: &str| -> Id {
        let nt = rules::note_type(salt, ANKI_NT);
        rules::card(&rules::note(salt, guid), &rules::template(&nt, 0), 0)
    };
    let log_of = |salt: Option<&str>, guid: &str| -> String {
        rules::imported_revlog(&card_of(salt, guid), RID).text()
    };
    // 带盐的两份日志 ID 与规范的两份先后相反的一对 guid。
    let (old_g, new_g) = (0..)
        .map(|i| (format!("bug5063-old-{i}"), format!("bug5063-new-{i}")))
        .find(|(a, b)| {
            (log_of(Some(P), a) < log_of(Some(P), b))
                != (log_of(CANONICAL, a) < log_of(CANONICAL, b))
        })
        .unwrap();
    let nt = rules::note_type(Some(P), ANKI_NT);
    let (field, tmpl) = (rules::field(&nt, 0), rules::template(&nt, 0));
    let note = |g: &str| rules::note(Some(P), g).text();
    let (c_old, c_new) = (
        card_of(Some(P), &old_g).text(),
        card_of(Some(P), &new_g).text(),
    );
    let anki = |card: &str, id: &str| -> Value {
        json!({"t": "log", "x": {
            "id": id, "p": P, "card": card, "kind": "review", "rating": 3, "hlc": format!("{RID}:0:anki"),
            "at": RID, "ts": "wall", "origin": "anki", "ankiId": RID, "rtype": "review", "dur": 5000, "utcOff": 0,
            "rollover": 4, "alg": "anki",
            "res": {"queue": "review", "ivl": 3, "step": 0, "reps": 1, "lapses": 0, "scheduler": "fushi",
                    "dueDay": 5, "lastReviewedAt": RID}
        }})
    };

    let d = Device::new("bug5063");
    d.core.sync2_identity(P, T0).unwrap();
    while d.core.sync2_migrate(P, T0, None).unwrap()["done"] != json!(true) {}
    let mut events = vec![
        deck_entity(&default_deck_id(P)),
        json!({"t": "entity", "x": {"id": nt.text(), "p": P, "k": "notetype",
               "d": {"createdAt": 1, "ntKind": "standard", "ankiNum": ANKI_NT}}}),
        edit(
            "notetype",
            &nt.text(),
            &format!("fieldDef/{}", field.text()),
            json!({"ankiNum": 0, "name": "E", "ord": 0}),
        ),
        edit(
            "notetype",
            &nt.text(),
            &format!("tmplDef/{}", tmpl.text()),
            json!({"ankiNum": 0, "name": "A", "ord": 0, "front": "{{E}}"}),
        ),
    ];
    for g in [&old_g, &new_g] {
        events.push(
            json!({"t": "entity", "x": {"id": note(g), "p": P, "k": "note",
                           "d": {"createdAt": 1, "guid": g, "noteTypeId": nt.text()}}}),
        );
        events.push(edit(
            "note",
            &note(g),
            &format!("f/{}", field.text()),
            json!("猫"),
        ));
    }
    d.apply(T0, events);
    d.apply(T0 + 1, vec![anki(&c_old, &log_of(Some(P), &old_g))]);
    d.apply(
        T0 + 2,
        vec![
            edit("note", &note(&old_g), "deleted", json!(T0 + 2)),
            edit("card", &c_new, &format!("historyFrom/{c_old}"), json!(true)),
        ],
    );
    d.apply(T0 + 3, vec![anki(&c_new, &log_of(Some(P), &new_g))]);
    let Device { core, _dir: dir } = d;
    core.close();
    drop(core);

    let canonical = BTreeMap::from([(
        P.to_owned(),
        json!({"defaultDeck": rules::builtin_default_deck(CANONICAL).text()}).to_string(),
    )]);
    let out = migrate_with(&dir.0, &canonical, &Stop::new(), &mut Vec::new());
    let Outcome::Committed { report } = &out else {
        panic!("{out:?}")
    };
    let p = &report["profiles"][0];
    assert_eq!(p["verdict"], "pass", "{p:#}");
    assert_eq!(p["parity"], json!([]), "{p:#}");
    assert_eq!(p["canonical"], json!([]), "{p:#}");
    // 正是「代表选得不同」这一格被认出来：新卡的统计行与卡行各一处。
    let k = &p["knownDifferences"];
    assert_eq!(k["cacheStatRepresentativeSwaps"], json!(1), "{p:#}");
    assert_eq!(k["cacheCardRepresentativeSwaps"], json!(1), "{p:#}");
}

/// BUG-5190（反馈 eZJEGqEt7K）：一张卡有两个前身（并入重复笔记、删光重导……），两个前身记着不同的卡片标志
/// （`newPos` / `deck` / `suspended` / `flag`），后继卡自己没记。卡片标志按血统继承时同一层的前身怎么排，决定了
/// 后继卡继承谁的。挑带盐与规范先后相反的一对前身：迁移的对拍不能因此判卡行不同。
#[test]
fn a_card_inheriting_from_two_predecessors_whose_salted_and_canonical_order_differ_migrates_cleanly()
 {
    use crate::gen4_ids::rules::{self, CANONICAL};
    use crate::store::sync2::config::default_deck_id;
    use crate::store::sync2::tests::{deck_entity, edit};

    const ANKI_NT: i64 = 1_700_000_000_556;
    let card_of = |salt: Option<&str>, guid: &str| -> Id {
        let nt = rules::note_type(salt, ANKI_NT);
        rules::card(&rules::note(salt, guid), &rules::template(&nt, 0), 0)
    };
    // 带盐的两张前身卡与规范的两张先后相反的一对 guid。
    let (g1, g2) = (0..)
        .map(|i| (format!("lineage2-a-{i}"), format!("lineage2-b-{i}")))
        .find(|(a, b)| {
            (card_of(Some(P), a).text() < card_of(Some(P), b).text())
                != (card_of(CANONICAL, a).text() < card_of(CANONICAL, b).text())
        })
        .unwrap();
    let g3 = "lineage2-merged".to_owned();
    let nt = rules::note_type(Some(P), ANKI_NT);
    let (field, tmpl) = (rules::field(&nt, 0), rules::template(&nt, 0));
    let note = |g: &str| rules::note(Some(P), g).text();
    let (c1, c2, c3) = (
        card_of(Some(P), &g1).text(),
        card_of(Some(P), &g2).text(),
        card_of(Some(P), &g3).text(),
    );
    let deck2 = rules::deck(Some(P), "lineage2-other").text();

    let d = Device::new("lineage2");
    d.core.sync2_identity(P, T0).unwrap();
    while d.core.sync2_migrate(P, T0, None).unwrap()["done"] != json!(true) {}
    let mut events = vec![
        deck_entity(&default_deck_id(P)),
        deck_entity(&deck2),
        json!({"t": "entity", "x": {"id": nt.text(), "p": P, "k": "notetype",
               "d": {"createdAt": 1, "ntKind": "standard", "ankiNum": ANKI_NT}}}),
        edit(
            "notetype",
            &nt.text(),
            &format!("fieldDef/{}", field.text()),
            json!({"ankiNum": 0, "name": "E", "ord": 0}),
        ),
        edit(
            "notetype",
            &nt.text(),
            &format!("tmplDef/{}", tmpl.text()),
            json!({"ankiNum": 0, "name": "A", "ord": 0, "front": "{{E}}"}),
        ),
    ];
    for (g, w) in [(&g1, "猫"), (&g2, "犬"), (&g3, "猫犬")] {
        events.push(
            json!({"t": "entity", "x": {"id": note(g), "p": P, "k": "note",
                           "d": {"createdAt": 1, "guid": g, "noteTypeId": nt.text()}}}),
        );
        events.push(edit(
            "note",
            &note(g),
            &format!("f/{}", field.text()),
            json!(w),
        ));
    }
    d.apply(T0, events);
    d.apply(
        T0 + 1,
        vec![
            edit("card", &c1, "newPos", json!(1)),
            edit("card", &c1, "flag", json!(1)),
            edit("card", &c2, "newPos", json!(2)),
            edit("card", &c2, "flag", json!(2)),
            edit("card", &c2, "deck", json!(deck2)),
            edit("card", &c2, "suspended", json!(true)),
        ],
    );
    d.apply(
        T0 + 2,
        vec![
            edit("note", &note(&g1), "deleted", json!(T0 + 2)),
            edit("note", &note(&g2), "deleted", json!(T0 + 2)),
            edit("card", &c3, &format!("historyFrom/{c1}"), json!(true)),
            edit("card", &c3, &format!("historyFrom/{c2}"), json!(true)),
        ],
    );
    let Device { core, _dir: dir } = d;
    core.close();
    drop(core);

    let canonical = BTreeMap::from([(
        P.to_owned(),
        json!({"defaultDeck": rules::builtin_default_deck(CANONICAL).text()}).to_string(),
    )]);
    let out = migrate_with(&dir.0, &canonical, &Stop::new(), &mut Vec::new());
    let report = match &out {
        Outcome::Committed { report } => report.clone(),
        Outcome::Aborted { report, .. } => report.clone(),
        other => panic!("{other:?}"),
    };
    let p = &report["profiles"][0];
    assert_eq!(p["parity"], json!([]), "{p:#}");
    assert_eq!(p["canonical"], json!([]), "{p:#}");
    assert_eq!(p["verdict"], "pass", "{p:#}");
    assert!(matches!(out, Outcome::Committed { .. }), "{out:?}");
}

/// 上次没完成的原因由状态命令判定（[GenState::MigrationFailed] 带 [Failure]），与「是不是失败」走同一份身份核对：
/// 中止报告按 `profileVerdict` 分成 `fail` / `incomplete` / `error`（认不出的算 `error`），报告的身份不是旁边这份
/// 旧库的不算失败（要迁移），提交时写的报告不算；旧库不见了、只剩临时文件 = `interrupted`（没有报告路径）。
/// 线上形状 `{state, failure: {reason, reportPath?}}` 状态命令与打开错误共用（[GenState::json]）。
#[test]
fn the_failed_state_carries_the_kernel_reason() {
    let dir = legacy_dir("g7-reason", &|_| {});
    let identity = {
        let c = open_ro(&dir.0.join(LEGACY_FILE)).unwrap();
        seal::legacy_identity(&c).unwrap()
    };
    assert!(identity.is_some());
    let write = |verdict: &str, profile_verdict: Value, legacy: Value| {
        let r = json!({
            "version": REPORT_VERSION,
            "verdict": verdict,
            "profileVerdict": profile_verdict,
            "legacyIdentity": legacy,
        });
        std::fs::write(dir.0.join(REPORT_FILE), r.to_string()).unwrap();
    };
    assert_eq!(status(&dir.0), Ok(GenState::NeedsMigration));
    for (pv, want) in [
        (json!("fail"), AbortReason::Fail),
        (json!("incomplete"), AbortReason::Incomplete),
        (json!("error"), AbortReason::Error),
        (json!("blocked"), AbortReason::Error),
        (Value::Null, AbortReason::Error),
    ] {
        write("aborted", pv.clone(), json!(identity));
        let st = status(&dir.0).unwrap();
        assert_eq!(
            st,
            GenState::MigrationFailed(Failure::Aborted(want)),
            "{pv}"
        );
        let j = st.json(&dir.0);
        assert_eq!(j["state"], "migrationFailed");
        assert_eq!(j["failure"]["reason"], want.wire());
        assert_eq!(
            j["failure"]["reportPath"],
            json!(dir.0.join(REPORT_FILE).display().to_string())
        );
    }
    // 别的旧库的报告（身份不同）：不是这份旧库的失败，照常要迁移，不带原因。
    write("aborted", json!("fail"), json!("someone-else"));
    assert_eq!(status(&dir.0), Ok(GenState::NeedsMigration));
    assert_eq!(
        GenState::NeedsMigration.json(&dir.0)["failure"],
        Value::Null
    );
    // 提交时写的报告不是失败。
    write("committed", json!("pass"), json!(identity));
    assert_eq!(status(&dir.0), Ok(GenState::NeedsMigration));
    // 旧库不见了、只剩迁移临时文件：上次跑到一半，没有报告路径。
    std::fs::remove_file(dir.0.join(REPORT_FILE)).unwrap();
    std::fs::rename(dir.0.join(LEGACY_FILE), dir.0.join(GEN4_TEMP)).unwrap();
    let _ = std::fs::remove_file(dir.0.join(format!("{LEGACY_FILE}-wal")));
    let st = status(&dir.0).unwrap();
    assert_eq!(st, GenState::MigrationFailed(Failure::Interrupted));
    assert_eq!(st.json(&dir.0)["failure"], json!({"reason": "interrupted"}));
}

/// 反馈 RhMpA6bn8v：迁移进协议 3 之前的旧日志（操作里没有生效配置快照 `sc`）的投影行，结果被旧代码的重放改写过
/// （2026-10-25 第一版协议 3 `829a67b942` 在迁移时用当时的牌组配置重放全部派生日志，7eeb05bc7c 之后不再改写，但改写过
/// 的行没人改回来：没有 `sc` 的日志重放时按投影行里的结果照抄）。新代按操作里作者给的结果算，协议 3 的现成日志行是
/// 旧代码留下的。卡的调度列、之后带 `sc` 的复习的统计分类（`kind`）与成熟变化（`maturity_delta`）跟着不同。
///
/// [stale] 把旧库里 L2（之后还有带 `sc` 的作答 r3）与 L3（另一张卡的最后一条）的结果改成旧代码重放出的那份。
/// 返回 (旧库目录, L2 的卡)。
fn library_with_a_rewritten_legacy_result(
    tag: &str,
    stale: &dyn Fn(&Value) -> Value,
) -> (tempdir::Dir, String) {
    use crate::store::gen4::dryrun::tests::library_with;
    use crate::store::sync2::tests::{DAY, review};

    let card = crate::registers::card_id(N2, "t1", 0).unwrap();
    let other = crate::registers::card_id(N2, "t2", 0).unwrap();
    let day = |at: i64| {
        crate::projection::Day {
            utc_offset_min: 0,
            rollover_hour: 4,
        }
        .index(at)
    };
    let (l1, l2) = (T0 - 40 * DAY, T0 - 37 * DAY);
    // 作者（迁移前的 Dart，经 FFI 拿到 f32、按 double 写出）给的结果。
    let author = |at: i64, ivl: i64, reps: i64, s: f64, d: f64| {
        json!({"queue": "review", "dueDay": day(at) + ivl, "ivl": ivl, "step": 0, "reps": reps, "lapses": 0,
               "scheduler": "fushi", "lastReviewedAt": at, "mem": {"s": s, "d": d, "sf": s}})
    };
    let legacy_log = |id: &str, card: &str, at: i64, rtype: &str, res: Value| {
        json!({"id": id, "p": P, "card": card, "kind": "review", "rating": 3, "hlc": format!("{at}:0:old"),
               "at": at, "ts": "anchored", "origin": "fushi", "rtype": rtype, "utcOff": 0, "rollover": 4,
               "fv": 1, "res": res})
    };
    let logs = [
        (
            "L1",
            &card,
            l1,
            "learn",
            author(l1, 3, 1, 3.1730000972747803, 5.282434463500977),
        ),
        (
            "L2",
            &card,
            l2,
            "review",
            author(l2, 15, 2, 15.343999862670898, 1.53643798828125),
        ),
        (
            "L3",
            &other,
            l2,
            "learn",
            author(l2, 15, 1, 15.343999862670898, 1.53643798828125),
        ),
    ];
    let lib = library_with(tag, &|d: &Device| {
        let w = d.core.writer().unwrap();
        for (id, card, at, rtype, res) in &logs {
            w.execute(
                "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, jslim) \
                 VALUES (srs_id(?1), srs_id(?2), srs_id(?3), 'review', 3, ?4, ?5, 'fushi', ?6)",
                params![id, P, card, at, rtype, legacy_log(id, card, *at, rtype, res.clone()).to_string()],
            )
            .unwrap();
        }
    });
    // 旧代码的重放改写了 L2 的投影行（落在 2026-10-25 迁移那一刻），之后才有带 `sc` 的作答。
    {
        let w = lib.core.writer().unwrap();
        for id in ["L2", "L3"] {
            let json: String = w
                .query_row(
                    "SELECT json FROM srs_review_logs WHERE id = srs_id(?1)",
                    [id],
                    |r| r.get(0),
                )
                .unwrap();
            let mut row: Value = serde_json::from_str(&json).unwrap();
            row["res"] = stale(&row["res"]);
            w.execute(
                "UPDATE srs_review_logs SET jslim = srs_log_pack(?2, id, profile_uid, card_id, kind, rating, occurred_at, \
                 review_type, origin, duration_ms) WHERE id = srs_id(?1)",
                params![id, row.to_string()],
            )
            .unwrap();
        }
    }
    // 之后作答（带 `sc`，重放按它重算；前一条的结果决定这条的结果、分类与成熟变化）。
    lib.apply(
        T0 + 2 * DAY,
        vec![review("r3", &card, T0 + 2 * DAY, 3, "review")],
    );
    let Device { core, _dir: dir } = lib;
    core.close();
    drop(core);
    (dir, card)
}

/// 旧代码重放改写的结果：f32 按最短十进制写、间隔按当时的配置算长了（15 → 30 天，跨过成熟线）、难度不同。
fn rewritten_by_old_replay(res: &Value) -> Value {
    let mut r = res.clone();
    let due = r["dueDay"].as_i64().unwrap();
    r["dueDay"] = json!(due + 15);
    r["ivl"] = json!(30);
    r["mem"] = json!({"s": 15.344, "d": 3.4977171, "sf": 15.344});
    r
}

#[test]
fn a_legacy_result_rewritten_by_the_old_replay_is_corrected_on_the_protocol_3_side_and_migrates() {
    let (dir, card) =
        library_with_a_rewritten_legacy_result("g7-stale-result", &rewritten_by_old_replay);
    let out = migrate_with(&dir.0, &caches(), &Stop::new(), &mut Vec::new());
    let report = match &out {
        Outcome::Committed { report } | Outcome::Aborted { report, .. } => report.clone(),
        other => panic!("{other:?}"),
    };
    let p = &report["profiles"][0];
    assert_eq!(p["parity"], json!([]), "{p:#}");
    assert_eq!(p["canonical"], json!([]), "{p:#}");
    assert_eq!(p["verdict"], "pass", "{p:#}");
    // 佐证逐条报出来：哪条日志、哪张卡、落库的与它操作里的结果。
    let s = &p["oldSideStaleResults"];
    assert_eq!(s["logs"], 2, "{s:#}");
    assert_eq!(s["cards"], 2, "{s:#}");
    let example = s["examples"][0].as_str().unwrap();
    assert!(example.starts_with("L2 "), "{example}");
    assert!(example.contains(&card), "{example}");
    assert!(matches!(out, Outcome::Committed { .. }), "{out:?}");
}

/// 只认佐证得了的：带 `sc` 的日志（协议 3 自己会重放它）的落库结果不对，不算这一类，照样判不同、中止。
#[test]
fn a_wrong_result_on_a_log_that_carries_its_config_still_fails_the_check() {
    let (dir, _) = library_with_a_rewritten_legacy_result("g7-stale-sc", &|r| r.clone());
    {
        let c = raw(&dir.0);
        let json: String = c
            .query_row(
                "SELECT json FROM srs_review_logs WHERE id = srs_id('r3')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let mut row: Value = serde_json::from_str(&json).unwrap();
        assert!(row["sc"].is_object(), "{row}");
        row["res"]["ivl"] = json!(row["res"]["ivl"].as_i64().unwrap() + 40);
        row["res"]["dueDay"] = json!(row["res"]["dueDay"].as_i64().unwrap() + 40);
        c.execute(
            "UPDATE srs_review_logs SET jslim = srs_log_pack(?2, id, profile_uid, card_id, kind, rating, occurred_at, \
             review_type, origin, duration_ms) WHERE id = srs_id(?1)",
            params!["r3", row.to_string()],
        )
        .unwrap();
    }
    let out = migrate_with(&dir.0, &caches(), &Stop::new(), &mut Vec::new());
    let Outcome::Aborted { report, .. } = &out else {
        panic!("{out:?}");
    };
    let p = &report["profiles"][0];
    assert_eq!(p["verdict"], "fail", "{p:#}");
    assert_eq!(p["oldSideStaleResults"]["logs"], 0, "{p:#}");
    assert!(
        p["parity"]
            .as_array()
            .unwrap()
            .iter()
            .any(|d| d["what"] == "cards"),
        "{p:#}"
    );
}

fn dup_config(ret: f64) -> Value {
    crate::sync2::sched::Config {
        desired_retention: ret,
        ..Default::default()
    }
    .to_json()
}

fn dup_day(at: i64) -> i64 {
    crate::projection::Day {
        utc_offset_min: 0,
        rollover_hour: 4,
    }
    .index(at)
}

fn dup_author_res(at: i64, ivl: i64, reps: i64, s: f64, d: f64) -> Value {
    json!({
        "queue": "review",
        "dueDay": dup_day(at) + ivl,
        "ivl": ivl,
        "step": 0,
        "reps": reps,
        "lapses": 0,
        "scheduler": "fushi",
        "lastReviewedAt": at,
        "mem": {"s": s, "d": d, "sf": s},
    })
}

/// 测试夹具专用键：[seed_dup_legacy_device] 写旧日志行时从行里摘掉，写成这条日志在本设备 `srs_event_local` 里的 S(e)。
const DUP_SERVER_TIME: &str = "test:serverTime";

fn seed_dup_legacy_device(d: &Device, l2_log: &Value, l3_log: Option<&Value>) -> (String, String) {
    use crate::store::gen4::dryrun::tests::N1;
    use crate::store::sync2::config::default_deck_id;
    use crate::store::sync2::tests::DAY;

    let card1 = crate::registers::card_id(N1, "t1", 0).unwrap();
    let card2 = crate::registers::card_id(N2, "t1", 0).unwrap();
    let l1_at = T0 - 40 * DAY;
    let l1_log = json!({
        "id": "L1", "p": P, "card": card1, "kind": "review", "rating": 3,
        "hlc": format!("{l1_at}:0:old"), "at": l1_at, "ts": "anchored",
        "origin": "fushi", "rtype": "learn", "utcOff": 0, "rollover": 4, "fv": 1,
        "res": dup_author_res(l1_at, 3, 1, 3.1730000972747803, 5.282434463500977),
    });

    {
        let w = d.core.writer().unwrap();
        let def_deck = default_deck_id(P);
        for (id, kind, data) in [
            (
                def_deck,
                "deck",
                json!({"createdAt": 1, "builtin": "default"}),
            ),
            (
                "NT".to_owned(),
                "notetype",
                json!({"createdAt": 1, "ntKind": "standard"}),
            ),
            (
                N1.to_owned(),
                "note",
                json!({"createdAt": 1, "guid": N1, "noteTypeId": "NT"}),
            ),
            (
                N2.to_owned(),
                "note",
                json!({"createdAt": 1, "guid": N2, "noteTypeId": "NT"}),
            ),
        ] {
            w.execute(
                "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) \
                 VALUES (srs_id(?1), srs_id(?2), ?3, ?4, 1)",
                params![id, P, kind, data.to_string()],
            )
            .unwrap();
        }
        let edits = [
            (
                "notetype",
                "NT",
                "fieldDef/fa",
                json!({"name": "Expression", "ord": 0}),
            ),
            (
                "notetype",
                "NT",
                "tmplDef/t1",
                json!({"name": "A", "ord": 0, "front": "{{Expression}}"}),
            ),
            (
                "notetype",
                "NT",
                "tmplDef/t2",
                json!({"name": "B", "ord": 1, "front": "{{Expression}}"}),
            ),
            ("note", N1, "f/fa", json!("猫")),
            ("note", N2, "f/fa", json!("犬")),
        ];
        for (idx, (ekind, eid, key, val)) in edits.iter().enumerate() {
            let seq = (idx + 1) as i64;
            let id = crate::registers::edit_id("old", seq);
            let vv = if seq == 1 {
                json!({})
            } else {
                json!({"old": seq - 1})
            };
            let j = json!({
                "ctx": {"vv": vv},
                "e": eid,
                "f": key,
                "hlc": format!("{}:0:old", T0 - 1000 + seq),
                "id": id,
                "k": ekind,
                "p": P,
                "s": seq,
                "ts": "anchored",
                "v": val,
                "w": "old",
            });
            w.execute(
                "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
                 VALUES (srs_id(?1), srs_id(?2), ?3, srs_id(?4), ?5, srs_id(?6), ?7, ?8)",
                params![id, P, ekind, eid, key, "old", seq, j.to_string()],
            )
            .unwrap();
        }
        let insert_log = |row: &Value| {
            let mut row = row.clone();
            let st = row
                .as_object_mut()
                .unwrap()
                .remove(DUP_SERVER_TIME)
                .and_then(|v| v.as_i64());
            w.execute(
                "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, \
                 duration_ms, jslim) VALUES (srs_id(?1), srs_id(?2), srs_id(?3), ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    row["id"].as_str().unwrap(),
                    P,
                    row["card"].as_str().unwrap(),
                    row["kind"].as_str().unwrap(),
                    row["rating"].as_i64(),
                    row["at"].as_i64().unwrap(),
                    row["rtype"].as_str().unwrap(),
                    row["origin"].as_str().unwrap(),
                    row["dur"].as_i64().unwrap_or(0),
                    row.to_string(),
                ],
            )
            .unwrap();
            if let Some(st) = st {
                w.execute(
                    "INSERT INTO srs_event_local (event_id, profile_uid, outbox_seq, server_time, received_at) \
                     VALUES (srs_id(?1), srs_id(?2), NULL, ?3, 0)",
                    params![row["id"].as_str().unwrap(), P, st],
                )
                .unwrap();
            }
        };
        insert_log(&l1_log);
        insert_log(l2_log);
        if let Some(l3) = l3_log {
            insert_log(l3);
        }
        let parsed =
            crate::store::caches::CacheConfig::parse(&serde_json::from_str(&cfg()).unwrap())
                .unwrap();
        crate::store::caches::rebuild(&w, P, &parsed).unwrap();
    }
    while d.core.sync2_migrate(P, T0, None).unwrap()["done"] != json!(true) {}
    {
        let w = d.core.writer().unwrap();
        let cards = std::collections::BTreeSet::from([card1.clone(), card2.clone()]);
        crate::store::sync2::replay_cards(&w, &cards).unwrap();
        let parsed =
            crate::store::caches::CacheConfig::parse(&serde_json::from_str(&cfg()).unwrap())
                .unwrap();
        crate::store::sync2::in_savepoint(&w, |c| crate::store::caches::rebuild(c, P, &parsed))
            .unwrap();
    }
    (card1, card2)
}

fn drain_dedup(d: &Device) {
    while d
        .core
        .sync2_dedup(P, T0 + 2 * crate::store::sync2::tests::DAY)
        .unwrap()["done"]
        != json!(true)
    {}
}

fn build_dup_device_pair(
    tag: &str,
    l2_small: &Value,
    l3_small: Option<&Value>,
    l2_large: &Value,
    l3_large: Option<&Value>,
    with_r3: bool,
) -> (Device, Device, String, String) {
    use crate::store::sync2::tests::{DAY, review};

    let x = Device::new(&format!("{tag}-x"));
    let y = Device::new(&format!("{tag}-y"));
    let id_of = |d: &Device| {
        d.core.sync2_identity(P, T0).unwrap()["device"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let (d_small, d_large) = if id_of(&x) < id_of(&y) {
        (x, y)
    } else {
        (y, x)
    };
    let (card1, card2) = seed_dup_legacy_device(&d_small, l2_small, l3_small);
    seed_dup_legacy_device(&d_large, l2_large, l3_large);

    let mut bucket = Bucket::default();
    d_small.sync(&mut bucket, "loc", T0 + DAY);
    d_large.sync(&mut bucket, "loc", T0 + DAY);
    drain_dedup(&d_large);
    if with_r3 {
        d_large.apply(
            T0 + 2 * DAY,
            vec![review("r3", &card1, T0 + 2 * DAY, 3, "review")],
        );
    }
    d_large.sync(&mut bucket, "loc", T0 + 2 * DAY);
    d_small.sync(&mut bucket, "loc", T0 + 2 * DAY);
    drain_dedup(&d_large);
    drain_dedup(&d_small);

    let parsed =
        crate::store::caches::CacheConfig::parse(&serde_json::from_str(&cfg()).unwrap()).unwrap();
    for d in [&d_small, &d_large] {
        let w = d.core.writer().unwrap();
        crate::store::sync2::in_savepoint(&w, |c| crate::store::caches::rebuild(c, P, &parsed))
            .unwrap();
    }
    (d_small, d_large, card1, card2)
}

fn close_device(d: Device) -> tempdir::Dir {
    let Device { core, _dir } = d;
    core.close();
    drop(core);
    _dir
}

/// 存量重复日志在各端所带配置快照 `sc` 不同时，协议 3 先到先得停在操作号更大的败者副本上（如手机本地先包的那份），
/// 而新代确定性选最小操作号。对拍前把败者代表及其 `sc` / `res` 改回最小操作号胜者再重放，两侧对齐并提交。
#[test]
fn duplicate_log_with_different_config_snapshot_heals_to_winning_op_and_migrates() {
    use crate::store::sync2::tests::DAY;

    let l2_at = T0 - 37 * DAY;
    let cfg_a = dup_config(0.7);
    let cfg_b = dup_config(0.85);
    let card1 = crate::registers::card_id(crate::store::gen4::dryrun::tests::N1, "t1", 0).unwrap();
    let card2 = crate::registers::card_id(N2, "t1", 0).unwrap();
    let mk_log = |id: &str, card: &str, rtype: &str, res: Value, sc: Option<&Value>| {
        let mut v = json!({
            "id": id, "p": P, "card": card, "kind": "review", "rating": 3,
            "hlc": format!("{l2_at}:0:old"), "at": l2_at, "ts": "anchored",
            "origin": "fushi", "rtype": rtype, "utcOff": 0, "rollover": 4, "fv": 1,
            "res": res,
        });
        if let Some(sc) = sc {
            v[crate::sync2::replay::SNAPSHOT_KEY] = sc.clone();
        }
        v
    };
    let l2_small = mk_log(
        "L2",
        &card1,
        "review",
        dup_author_res(l2_at, 15, 2, 15.343999862670898, 1.53643798828125),
        None,
    );
    let l2_large = mk_log(
        "L2",
        &card1,
        "review",
        dup_author_res(l2_at, 15, 2, 15.343999862670898, 1.53643798828125),
        Some(&cfg_b),
    );
    let l3_small = mk_log(
        "L3",
        &card2,
        "learn",
        dup_author_res(l2_at, 15, 1, 15.343999862670898, 1.53643798828125),
        Some(&cfg_a),
    );
    let l3_large = mk_log(
        "L3",
        &card2,
        "learn",
        dup_author_res(l2_at, 15, 1, 15.343999862670898, 1.53643798828125),
        Some(&cfg_b),
    );

    let (d_small, d_large, _, _) = build_dup_device_pair(
        "g7-dup-sc",
        &l2_small,
        Some(&l3_small),
        &l2_large,
        Some(&l3_large),
        true,
    );
    let dir_small = close_device(d_small);
    let dir_large = close_device(d_large);

    let out_large = migrate_with(&dir_large.0, &caches(), &Stop::new(), &mut Vec::new());
    let Outcome::Committed { report } = &out_large else {
        panic!("expected committed on d_large, got {out_large:?}");
    };
    let p = &report["profiles"][0];
    assert_eq!(p["verdict"], "pass", "{p:#}");
    assert_eq!(p["parity"], json!([]), "{p:#}");
    assert_eq!(p["canonical"], json!([]), "{p:#}");
    let s = &p["oldSideStaleResults"];
    assert_eq!(s["logs"], 2, "{s:#}");
    assert_eq!(s["cards"], 2, "{s:#}");
    let examples: Vec<&str> = s["examples"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert!(
        examples
            .iter()
            .any(|e| e.starts_with("L2 ") && e.contains(&card1) && e.contains("sc:")),
        "{examples:?}"
    );
    assert!(
        examples
            .iter()
            .any(|e| e.starts_with("L3 ") && e.contains(&card2) && e.contains("sc:")),
        "{examples:?}"
    );

    let out_small = migrate_with(&dir_small.0, &caches(), &Stop::new(), &mut Vec::new());
    let Outcome::Committed {
        report: report_small,
    } = &out_small
    else {
        panic!("expected committed on d_small, got {out_small:?}");
    };
    let p_small = &report_small["profiles"][0];
    assert_eq!(p_small["verdict"], "pass", "{p_small:#}");
    assert_eq!(p_small["parity"], json!([]), "{p_small:#}");
    assert_eq!(p_small["canonical"], json!([]), "{p_small:#}");
    assert_eq!(p_small["oldSideStaleResults"]["logs"], 0, "{p_small:#}");
}

/// 同 `sc` 且同组成的重复日志若落库投影行的 `res` 被手工改坏，不认作代表切换，照样判不同并中止。
#[test]
fn duplicate_log_with_same_config_and_corrupted_result_still_fails() {
    use crate::store::sync2::tests::DAY;

    let l2_at = T0 - 37 * DAY;
    let cfg_b = dup_config(0.85);
    let card1 = crate::registers::card_id(crate::store::gen4::dryrun::tests::N1, "t1", 0).unwrap();
    let mk_l2 = |ivl: i64| {
        let mut v = json!({
            "id": "L2", "p": P, "card": card1, "kind": "review", "rating": 3,
            "hlc": format!("{l2_at}:0:old"), "at": l2_at, "ts": "anchored",
            "origin": "fushi", "rtype": "review", "utcOff": 0, "rollover": 4, "fv": 1,
            "res": dup_author_res(l2_at, ivl, 2, 15.343999862670898, 1.53643798828125),
        });
        v[crate::sync2::replay::SNAPSHOT_KEY] = cfg_b.clone();
        v
    };
    let (_d_small, d_large, _, _) =
        build_dup_device_pair("g7-dup-same-sc", &mk_l2(15), None, &mk_l2(14), None, false);
    let dir_large = close_device(d_large);
    {
        let c = raw(&dir_large.0);
        let json: String = c
            .query_row(
                "SELECT json FROM srs_review_logs WHERE id = srs_id('L2')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let mut row: Value = serde_json::from_str(&json).unwrap();
        row["res"]["ivl"] = json!(row["res"]["ivl"].as_i64().unwrap() + 40);
        row["res"]["dueDay"] = json!(row["res"]["dueDay"].as_i64().unwrap() + 40);
        c.execute(
            "UPDATE srs_review_logs SET jslim = srs_log_pack(?2, id, profile_uid, card_id, kind, rating, occurred_at, \
             review_type, origin, duration_ms) WHERE id = srs_id(?1)",
            params!["L2", row.to_string()],
        )
        .unwrap();
    }
    let out = migrate_with(&dir_large.0, &caches(), &Stop::new(), &mut Vec::new());
    let Outcome::Aborted { report, .. } = &out else {
        panic!("expected Aborted, got {out:?}");
    };
    let p = &report["profiles"][0];
    assert_eq!(p["verdict"], "fail", "{p:#}");
    assert_eq!(p["oldSideStaleResults"]["logs"], 0, "{p:#}");
    assert!(
        p["parity"]
            .as_array()
            .unwrap()
            .iter()
            .any(|d| d["what"] == "cards"),
        "{p:#}"
    );
}

/// 落库行里的 `sc` 与 `sync2_log_meta` 所指败者操作不一致（磁盘篡改），或胜败两份操作的身份键（如 `rating`）不同，
/// 一律不予改回、照样判不同并中止。
#[test]
fn duplicate_log_with_mismatched_identity_or_tampered_sc_still_fails() {
    use crate::store::sync2::tests::DAY;

    let l2_at = T0 - 37 * DAY;
    let cfg_a = dup_config(0.7);
    let cfg_b = dup_config(0.85);
    let card1 = crate::registers::card_id(crate::store::gen4::dryrun::tests::N1, "t1", 0).unwrap();
    let mk_l2 = |rating: i64, sc: Option<&Value>| {
        let mut v = json!({
            "id": "L2", "p": P, "card": card1, "kind": "review", "rating": rating,
            "hlc": format!("{l2_at}:0:old"), "at": l2_at, "ts": "anchored",
            "origin": "fushi", "rtype": "review", "utcOff": 0, "rollover": 4, "fv": 1,
            "res": dup_author_res(l2_at, 15, 2, 15.343999862670898, 1.53643798828125),
        });
        if let Some(sc) = sc {
            v[crate::sync2::replay::SNAPSHOT_KEY] = sc.clone();
        }
        v
    };

    // 子例 A：落库行 `sc` 被手工改坏，不匹配败者操作原文。
    {
        let (_d_small, d_large, _, _) = build_dup_device_pair(
            "g7-dup-tamper-sc",
            &mk_l2(3, Some(&cfg_a)),
            None,
            &mk_l2(3, Some(&cfg_b)),
            None,
            false,
        );
        let dir_large = close_device(d_large);
        {
            let c = raw(&dir_large.0);
            let json: String = c
                .query_row(
                    "SELECT json FROM srs_review_logs WHERE id = srs_id('L2')",
                    [],
                    |r| r.get(0),
                )
                .unwrap();
            let mut row: Value = serde_json::from_str(&json).unwrap();
            row[crate::sync2::replay::SNAPSHOT_KEY]["ret"] = json!(0.65);
            row["res"]["ivl"] = json!(row["res"]["ivl"].as_i64().unwrap() + 40);
            row["res"]["dueDay"] = json!(row["res"]["dueDay"].as_i64().unwrap() + 40);
            c.execute(
                "UPDATE srs_review_logs SET jslim = srs_log_pack(?2, id, profile_uid, card_id, kind, rating, occurred_at, \
                 review_type, origin, duration_ms) WHERE id = srs_id(?1)",
                params!["L2", row.to_string()],
            )
            .unwrap();
        }
        let out = migrate_with(&dir_large.0, &caches(), &Stop::new(), &mut Vec::new());
        let Outcome::Aborted { report, .. } = &out else {
            panic!("expected Aborted for tampered sc, got {out:?}");
        };
        let p = &report["profiles"][0];
        assert_eq!(p["verdict"], "fail", "{p:#}");
        assert_eq!(p["oldSideStaleResults"]["logs"], 0, "{p:#}");
    }

    // 子例 B：落库行身份键（`rating` 3 vs 2）与胜者操作不一致，不改回。
    {
        let (_d_small, d_large, _, _) = build_dup_device_pair(
            "g7-dup-id-mismatch",
            &mk_l2(3, Some(&cfg_a)),
            None,
            &mk_l2(3, Some(&cfg_b)),
            None,
            false,
        );
        let dir_large = close_device(d_large);
        {
            let c = raw(&dir_large.0);
            let json: String = c
                .query_row(
                    "SELECT json FROM srs_review_logs WHERE id = srs_id('L2')",
                    [],
                    |r| r.get(0),
                )
                .unwrap();
            let mut row: Value = serde_json::from_str(&json).unwrap();
            row["rating"] = json!(2);
            c.execute(
                "UPDATE srs_review_logs SET rating = 2, jslim = srs_log_pack(?2, id, profile_uid, card_id, kind, 2, occurred_at, \
                 review_type, origin, duration_ms) WHERE id = srs_id(?1)",
                params!["L2", row.to_string()],
            )
            .unwrap();
        }
        let out = migrate_with(&dir_large.0, &caches(), &Stop::new(), &mut Vec::new());
        let Outcome::Aborted { report, .. } = &out else {
            panic!("expected Aborted for mismatched identity, got {out:?}");
        };
        let p = &report["profiles"][0];
        assert_eq!(p["verdict"], "fail", "{p:#}");
        assert_eq!(p["oldSideStaleResults"]["logs"], 0, "{p:#}");
    }
}

/// 重复日志代表切换同时改变意图（如 `Reset` vs `SetDue`）：干跑在只读连接上把 `sync2_log_meta` 也建进 `temp` 影子并改回、
/// 重放，不写旧库一字节、跑完不留临时表，且随后真实迁移同样提交。
#[test]
fn duplicate_log_with_different_intent_heals_shadow_meta_without_mutating_legacy_db() {
    use crate::store::sync2::tests::DAY;

    let l2_at = T0 - 37 * DAY;
    let cfg_b = dup_config(0.85);
    let card1 = crate::registers::card_id(crate::store::gen4::dryrun::tests::N1, "t1", 0).unwrap();
    let mk_manual = |res: Value| {
        let mut v = json!({
            "id": "L2", "p": P, "card": card1, "kind": "manual",
            "hlc": format!("{l2_at}:0:old"), "at": l2_at, "ts": "anchored",
            "origin": "fushi", "rtype": "manual", "utcOff": 0, "rollover": 4, "fv": 1,
            "res": res,
        });
        v[crate::sync2::replay::SNAPSHOT_KEY] = cfg_b.clone();
        v
    };
    let l2_reset = mk_manual(json!({
        "queue": "new", "ivl": 0, "step": 0, "reps": 0, "lapses": 0, "scheduler": "fushi",
    }));
    let l2_set_due = mk_manual(json!({
        "queue": "review", "dueDay": dup_day(l2_at) + 30, "ivl": 30, "step": 0, "reps": 2, "lapses": 0, "scheduler": "fushi",
    }));

    let (_d_small, d_large, _, _) =
        build_dup_device_pair("g7-dup-intent", &l2_reset, None, &l2_set_due, None, true);
    let dir_large = close_device(d_large);

    let db_path = dir_large.0.join(LEGACY_FILE);
    let bytes_before = std::fs::read(&db_path).unwrap();
    let meta_before: (i64, Option<i64>) = raw(&dir_large.0)
        .query_row(
            "SELECT intent, arg FROM sync2_log_meta WHERE log_id = srs_id('L2')",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(meta_before.0, 2, "SetDue before dryrun/heal");

    let work = dir_large.0.join("work");
    let caches_map = caches();
    let stop = Stop::new();
    let dry_report = crate::store::gen4::dryrun::run(
        &db_path,
        &work,
        crate::store::gen4::dryrun::Options {
            caches: &caches_map,
            batch: 2,
            keep: false,
            examples: crate::store::gen4::dryrun::DEFAULT_EXAMPLES,
            full_examples: false,
            stop: &stop,
            progress: &mut |_, _| {},
        },
    )
    .unwrap();
    assert_eq!(dry_report["verdict"], "pass", "{dry_report:#}");
    let dry_p = &dry_report["profiles"][0];
    assert_eq!(dry_p["parity"], json!([]), "{dry_p:#}");
    assert_eq!(dry_p["canonical"], json!([]), "{dry_p:#}");
    assert_eq!(dry_p["oldSideStaleResults"]["logs"], 1, "{dry_p:#}");
    assert!(
        dry_p["oldSideStaleResults"]["examples"][0]
            .as_str()
            .unwrap()
            .contains("intent:"),
        "{dry_p:#}"
    );
    assert_eq!(
        std::fs::read(&db_path).unwrap(),
        bytes_before,
        "dryrun must not touch legacy srs.db"
    );
    let meta_after: (i64, Option<i64>) = raw(&dir_large.0)
        .query_row(
            "SELECT intent, arg FROM sync2_log_meta WHERE log_id = srs_id('L2')",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(meta_after, meta_before, "legacy sync2_log_meta untouched");

    let out = migrate_with(&dir_large.0, &caches_map, &Stop::new(), &mut Vec::new());
    let Outcome::Committed { report } = &out else {
        panic!("expected Committed after intent heal, got {out:?}");
    };
    assert_eq!(report["profiles"][0]["verdict"], "pass", "{report:#}");
}

/// [copies] 的条数台设备各自包同一份旧库（第 i 台按设备 ID 升序拿 `copies[i]` 作 L2 / L3），互相同步、跑完副本收敛：
/// 每台的协议 3 都先投影了自己包的那份。
fn build_dup_devices(tag: &str, copies: &[(Value, Option<Value>)]) -> Vec<Device> {
    use crate::store::sync2::tests::DAY;

    let mut ds: Vec<(String, Device)> = (0..copies.len())
        .map(|i| {
            let d = Device::new(&format!("{tag}-{i}"));
            let id = d.core.sync2_identity(P, T0).unwrap()["device"]
                .as_str()
                .unwrap()
                .to_owned();
            (id, d)
        })
        .collect();
    ds.sort_by(|a, b| a.0.cmp(&b.0));
    let ds: Vec<Device> = ds.into_iter().map(|(_, d)| d).collect();
    for (d, (l2, l3)) in ds.iter().zip(copies) {
        seed_dup_legacy_device(d, l2, l3.as_ref());
    }
    let mut bucket = Bucket::default();
    for at in [T0 + DAY, T0 + 2 * DAY] {
        for d in &ds {
            d.sync(&mut bucket, "loc", at);
        }
        for d in &ds {
            drain_dedup(d);
        }
    }
    let parsed =
        crate::store::caches::CacheConfig::parse(&serde_json::from_str(&cfg()).unwrap()).unwrap();
    for d in &ds {
        let w = d.core.writer().unwrap();
        crate::store::sync2::in_savepoint(&w, |c| crate::store::caches::rebuild(c, P, &parsed))
            .unwrap();
    }
    ds
}

/// 重复日志的一份副本（夹具的 L2 / L3 形状）：[f] 改出这份副本与别的副本不同的地方。
fn dup_copy(id: &str, card: &str, f: impl FnOnce(&mut Value)) -> Value {
    use crate::store::sync2::tests::DAY;
    let at = T0 - 37 * DAY;
    let mut v = json!({
        "id": id, "p": P, "card": card, "kind": "review", "rating": 3,
        "hlc": format!("{at}:0:old"), "at": at, "ts": "anchored",
        "origin": "fushi", "rtype": "review", "utcOff": 0, "rollover": 4, "fv": 1,
        "res": dup_author_res(at, 15, 2, 15.343999862670898, 1.53643798828125),
    });
    f(&mut v);
    v
}

fn dup_cards() -> (String, String) {
    (
        crate::registers::card_id(crate::store::gen4::dryrun::tests::N1, "t1", 0).unwrap(),
        crate::registers::card_id(N2, "t1", 0).unwrap(),
    )
}

fn stale_examples(p: &Value) -> Vec<String> {
    p["oldSideStaleResults"]["examples"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect()
}

/// 同一条旧日志的两份副本在 `res` / `sc` / 意图以外的地方不同（PR #4245 第一版只认那三处）：L2 同一份 `sc`、意图
/// `Answer`，只差时长与 S(e)；L3 都没 `sc`，差评分与时区。协议 3 停在先到的那份（大设备自己包的），新代取操作号最小的，
/// 统计行的 `duration_ms` / `rating` / `utc_offset_min` 两侧不同，修之前整份撤回。改回 M → W 的差量后两台都提交；
/// 干跑在只读连接上给日志表、`sync2_log_meta`、`srs_event_local` 建影子，旧库一个字节不写。
#[test]
fn duplicate_log_copies_differing_beyond_result_config_and_intent_heal_and_migrate() {
    use crate::store::sync2::tests::DAY;

    let (card1, card2) = dup_cards();
    let cfg_b = dup_config(0.85);
    let at = T0 - 37 * DAY;
    let l2 = |dur: i64, st: i64| {
        dup_copy("L2", &card1, |v| {
            v[crate::sync2::replay::SNAPSHOT_KEY] = cfg_b.clone();
            v["dur"] = json!(dur);
            v[DUP_SERVER_TIME] = json!(st);
        })
    };
    let l3 = |rating: i64, utc_off: i64| {
        dup_copy("L3", &card2, |v| {
            v["rtype"] = json!("learn");
            v["rating"] = json!(rating);
            v["utcOff"] = json!(utc_off);
        })
    };
    let (d_small, d_large, _, _) = build_dup_device_pair(
        "g7-dup-any-field",
        &l2(3000, at + 1000),
        Some(&l3(3, 0)),
        &l2(5000, at + 9000),
        Some(&l3(4, 540)),
        true,
    );
    let dir_small = close_device(d_small);
    let dir_large = close_device(d_large);

    let db_path = dir_large.0.join(LEGACY_FILE);
    let bytes_before = std::fs::read(&db_path).unwrap();
    let caches_map = caches();
    let stop = Stop::new();
    let dry = crate::store::gen4::dryrun::run(
        &db_path,
        &dir_large.0.join("work"),
        crate::store::gen4::dryrun::Options {
            caches: &caches_map,
            batch: 2,
            keep: false,
            examples: crate::store::gen4::dryrun::DEFAULT_EXAMPLES,
            full_examples: false,
            stop: &stop,
            progress: &mut |_, _| {},
        },
    )
    .unwrap();
    assert_eq!(dry["verdict"], "pass", "{dry:#}");
    let p = &dry["profiles"][0];
    assert_eq!(p["parity"], json!([]), "{p:#}");
    assert_eq!(p["canonical"], json!([]), "{p:#}");
    assert_eq!(p["oldSideStaleResults"]["swaps"], 2, "{p:#}");
    let ex = stale_examples(p);
    let st_text = format!("serverTime: Some({})", at + 1000);
    assert!(
        ex.iter()
            .any(|e| e.starts_with("L2 ") && e.contains("keys: [dur]") && e.contains(&st_text)),
        "{ex:?}"
    );
    assert!(
        ex.iter()
            .any(|e| e.starts_with("L3 ") && e.contains("keys: [rating,utcOff]")),
        "{ex:?}"
    );
    assert_eq!(
        std::fs::read(&db_path).unwrap(),
        bytes_before,
        "the dry run must not touch the legacy srs.db"
    );

    for (dir, swaps) in [(&dir_large, 2), (&dir_small, 0)] {
        let out = migrate_with(&dir.0, &caches_map, &Stop::new(), &mut Vec::new());
        let Outcome::Committed { report } = &out else {
            panic!("expected Committed, got {out:?}");
        };
        let p = &report["profiles"][0];
        assert_eq!(p["verdict"], "pass", "{p:#}");
        assert_eq!(p["parity"], json!([]), "{p:#}");
        assert_eq!(p["oldSideStaleResults"]["swaps"], swaps, "{p:#}");
    }
}

/// 要换掉的键落库原值不是 M 的（这里 M、W 差时长，落库行的时长又被改成第三个值）：不是换代表能解释的，不改回，
/// 照样判不同并中止。
#[test]
fn duplicate_log_whose_swapped_field_was_tampered_still_fails() {
    let (card1, _) = dup_cards();
    let cfg_b = dup_config(0.85);
    let l2 = |dur: i64| {
        dup_copy("L2", &card1, |v| {
            v[crate::sync2::replay::SNAPSHOT_KEY] = cfg_b.clone();
            v["dur"] = json!(dur);
        })
    };
    let (_d_small, d_large, _, _) =
        build_dup_device_pair("g7-dup-tamper-dur", &l2(3000), None, &l2(5000), None, false);
    let dir_large = close_device(d_large);
    {
        let c = raw(&dir_large.0);
        let json: String = c
            .query_row(
                "SELECT json FROM srs_review_logs WHERE id = srs_id('L2')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let mut row: Value = serde_json::from_str(&json).unwrap();
        row["dur"] = json!(7000);
        c.execute(
            "UPDATE srs_review_logs SET duration_ms = 7000, jslim = srs_log_pack(?2, id, profile_uid, card_id, kind, \
             rating, occurred_at, review_type, origin, 7000) WHERE id = srs_id(?1)",
            params!["L2", row.to_string()],
        )
        .unwrap();
    }
    let out = migrate_with(&dir_large.0, &caches(), &Stop::new(), &mut Vec::new());
    let Outcome::Aborted { report, .. } = &out else {
        panic!("expected Aborted, got {out:?}");
    };
    let p = &report["profiles"][0];
    assert_eq!(p["verdict"], "fail", "{p:#}");
    assert_eq!(p["oldSideStaleResults"]["swaps"], 0, "{p:#}");
}

/// 三台设备各包了一份（最小设备的不带 `sc`、中间的带配置 A、最大的带配置 B 且时长不同）：中间与最大两台的协议 3
/// 各停在自己那份上，都要换成最小设备那份；三台都提交。
#[test]
fn duplicate_log_across_three_devices_heals_every_non_representative_copy() {
    let (card1, _) = dup_cards();
    let copy = |sc: Option<f64>, dur: i64| {
        dup_copy("L2", &card1, |v| {
            if let Some(r) = sc {
                v[crate::sync2::replay::SNAPSHOT_KEY] = dup_config(r);
            }
            v["dur"] = json!(dur);
        })
    };
    let ds = build_dup_devices(
        "g7-dup-three",
        &[
            (copy(None, 1000), None),
            (copy(Some(0.7), 1000), None),
            (copy(Some(0.85), 4000), None),
        ],
    );
    let dirs: Vec<tempdir::Dir> = ds.into_iter().map(close_device).collect();
    for (i, dir) in dirs.iter().enumerate() {
        let out = migrate_with(&dir.0, &caches(), &Stop::new(), &mut Vec::new());
        let Outcome::Committed { report } = &out else {
            panic!("device {i}: expected Committed, got {out:?}");
        };
        let p = &report["profiles"][0];
        assert_eq!(p["verdict"], "pass", "device {i}: {p:#}");
        assert_eq!(p["parity"], json!([]), "device {i}: {p:#}");
        let want = usize::from(i > 0);
        assert_eq!(p["oldSideStaleResults"]["swaps"], want, "device {i}: {p:#}");
        if i == 2 {
            let ex = stale_examples(p);
            assert!(
                ex.iter()
                    .any(|e| e.starts_with("L2 ") && e.contains("keys: [dur,sc]")),
                "{ex:?}"
            );
        }
    }
}

/// 一份迁移的报告（提交或中止都有）。
fn report_of(out: &Outcome) -> &Value {
    match out {
        Outcome::Committed { report } | Outcome::Aborted { report, .. } => report,
        _ => panic!("{out:?}"),
    }
}

/// 报告里每个 profile 的 (uid, 结论, 对拍差异)。
fn verdicts_of(report: &Value) -> Vec<(String, String, Value)> {
    report["profiles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| {
            (
                p["profile"].as_str().unwrap_or("?").to_owned(),
                p["verdict"].as_str().unwrap().to_owned(),
                p["parity"].clone(),
            )
        })
        .collect()
}

/// 直接往旧投影表插一条 [P] 名下笔记 [note] 的旧修改记录（旧写入者 [writer] 的第 [s] 条，不经操作日志）。返回它的 ID。
fn legacy_note_edit(
    c: &Connection,
    writer: &str,
    s: i64,
    note: &str,
    key: &str,
    v: Value,
) -> String {
    let id = crate::registers::edit_id(writer, s);
    let j = json!({"ctx": {"vv": {}}, "e": note, "f": key, "hlc": format!("{}:0:{writer}", T0 + s), "id": id, "k": "note",
                   "p": P, "s": s, "ts": "wall", "v": v, "w": writer})
    .to_string();
    c.execute(
        "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
         VALUES (srs_id(?1), srs_id(?2), 'note', srs_id(?3), ?4, ?5, ?6, ?7)",
        params![id, P, note, key, writer, s, j],
    )
    .unwrap();
    id
}

/// BUG-5295（反馈 EapjqHGvCl）：协议 3 的投影里有本 profile 的旧修改记录（笔记的 `source`、`deleted`），本 profile 的
/// 操作日志里却没有代表它的操作。协议 3 读投影，用户看得见；新代只认操作日志，迁过去就丢了——对拍报 `edits` onlyOld、
/// `registerWinners` onlyOld、笔记行 `source_*` / `deleted_at` 与卡的 `hidden` 不同，整份撤回。两种来路：
///
/// 1. 迁移（`sync2_migrate`）做完之后才出现在投影里的旧行：协议 3 对已迁移的 profile 从不再补包；
/// 2. 迁移时这条旧行被判成「已被代表」，代表它的却是**别的 profile** 的操作（`sync2_edit_ops` 以修改记录 ID 为主键、
///    全库共用，别的 profile 收到同一个旧 dot 的操作时 `INSERT OR REPLACE` 占走了这一行；以前的判据不看 profile）。
///
/// 修复后两种都在迁移前提补完时包成本 profile 的操作，对拍通过、整份提交。
#[test]
fn projection_rows_no_op_of_the_profile_represents_are_wrapped_before_migrating() {
    // 1：迁移做完之后的旧行。
    let dir = legacy_dir("g72-unrep-late", &|_| {});
    {
        let c = raw(&dir.0);
        legacy_note_edit(
            &c,
            "dart-late",
            1,
            N2,
            "source",
            json!({"kind": "book", "title": "本", "key": "k1"}),
        );
        legacy_note_edit(
            &c,
            "dart-late",
            2,
            crate::store::gen4::dryrun::tests::N1,
            "deleted",
            json!(T0 + 500),
        );
    }
    let out = migrate(&dir.0);
    let report = report_of(&out);
    assert_eq!(out.verdict(), "committed", "{report:#}");
    assert_eq!(
        verdicts_of(report),
        vec![(P.to_owned(), "pass".to_owned(), json!([]))],
        "{report:#}"
    );

    // 2：迁移时别的 profile 的操作占着同一个修改记录 ID。
    let Device { core, _dir } = crate::store::gen4::dryrun::tests::library_with(
        "g72-unrep-taken",
        &|d| {
            let w = d.core.writer().unwrap();
            let id = legacy_note_edit(
                &w,
                "dart-old",
                7,
                N2,
                "source",
                json!({"kind": "book", "title": "旧", "key": "k2"}),
            );
            w.execute(
            "INSERT INTO sync2_edit_ops (edit_id, profile_uid, device, seq) VALUES (srs_id(?1), srs_id(?2), ?3, 1)",
            params![id, Q, vec![0x51u8; 16]],
        )
        .unwrap();
        },
    );
    let ops_for_row: i64 = core
        .writer()
        .unwrap()
        .query_row(
            "SELECT COUNT(*) FROM sync2_edit_ops WHERE edit_id = srs_id(?1) AND profile_uid = srs_id(?2)",
            params![crate::registers::edit_id("dart-old", 7), P],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(ops_for_row, 1, "the profile's own migration wraps the row");
    core.close();
    drop(core);
    let out = migrate_with(&_dir.0, &caches_pq(), &Stop::new(), &mut Vec::new());
    let report = report_of(&out);
    assert_eq!(out.verdict(), "committed", "{report:#}");
}

/// BUG-5294（反馈 CQKRyvMoOC）：本 profile 的操作日志里有身份记录，协议 3 的 `srs_entities` 里却哪个 profile 名下都没有
/// 这一行。`srs_entities` 以实体 ID 为主键、全库共用（BUG-5267）：两个 profile 的日志里都有同一个实体时只存一行，归先落
/// 投影的那个；之后那个 profile 被删（`profile_purge` / 并入收尾 / 无主数据扫描都按 `profile_uid` 删投影行），行跟着没了，
/// 另一个 profile 的日志里那条身份记录还在——协议 3 自己的规则（`project_entity`：没有行就写）下它就是这个 profile 的
/// 实体，换一台设备收同样的操作就有这一行。对拍的 `entities` 一类把它们算进协议 3 一侧（`orphanedEntities` 计数），
/// 其中的笔记缓存层不比（协议 3 的缓存按 `profile_uid` 列笔记，行没了就没有）。去掉修复时 [P] 报 `entities` onlyNew。
#[test]
fn entities_whose_protocol_3_row_left_with_a_purged_profile_migrate() {
    let lib = library("g72-pq-orphaned");
    add_second_profile(&lib.core);
    let peer = Device::new("g72-pq-orphaned-peer");
    let entity = |id: &str, kind: &str, d: Value| json!({"t": "entity", "x": {"id": id, "p": P, "k": kind, "d": d}});
    let deck_q = crate::store::sync2::config::default_deck_id(Q);
    peer.apply(
        T0 + 20,
        vec![
            entity(
                &deck_q,
                "deck",
                json!({"createdAt": 1, "builtin": "default"}),
            ),
            entity(
                QN1,
                "note",
                json!({"createdAt": 1, "guid": QN1, "noteTypeId": "NTQ"}),
            ),
        ],
    );
    let mut bucket = Bucket::default();
    peer.sync(&mut bucket, "loc", T0 + 30);
    lib.sync(&mut bucket, "loc", T0 + 30);
    let owner = |id: &str| -> Vec<Vec<String>> {
        lib.rows(&format!(
            "SELECT srs_idt(profile_uid) AS p FROM srs_entities WHERE id = srs_id('{id}')"
        ))
    };
    assert_eq!(owner(&deck_q)[1][0], Q);
    lib.core.profile_purge(Q).unwrap();
    assert_eq!(
        owner(&deck_q).len(),
        1,
        "the row left with the purged profile"
    );
    assert_eq!(owner(QN1).len(), 1);
    let Device { core, _dir: dir } = lib;
    core.close();
    drop(core);

    let out = migrate_with(&dir.0, &caches(), &Stop::new(), &mut Vec::new());
    let report = report_of(&out);
    assert_eq!(out.verdict(), "committed", "{report:#}");
    let p = &report["profiles"][0];
    assert_eq!(
        (
            &p["profile"],
            &p["verdict"],
            &p["parity"],
            &p["orphanedEntities"],
            &p["collidedEntities"]
        ),
        (&json!(P), &json!("pass"), &json!([]), &json!(2), &json!(0)),
        "{report:#}"
    );
}

/// 反馈 n0eMBDo31- / 1_MeD_RbWU（BUG-5269）：协议 3 的 `srs_entities` 全库共用，[Q] 的笔记可以挂在 [P] 的带盐内置
/// 笔记类型上（`noteTypeId` = `note_type(P, …)`，身份记录只在 [P] 的日志里）：协议 3 按 ID 读到那一行（归 [P]），再按
/// [Q] 的配置给出带 [Q] 盐的内置模板，卡 = card(Q 笔记, template(note_type(Q, …)), 0)，复习落在这张卡上。
/// [Q] 自己的内置笔记类型也有身份记录（用户的库里新代为这个 profile 建出了 407 张卡）；[delete] = 最后删掉这条
/// 笔记（用户报告里的形态）。
fn library_with_a_note_on_another_profiles_builtin(tag: &str, delete: bool) -> (tempdir::Dir, Id) {
    use crate::gen4_ids::rules::{self, CANONICAL};
    let lapis = rules::builtin_note_type_anki_num("lapis");
    let field_n = rules::builtin_field_anki_num("lapis", "Expression");
    let tmpl_n = rules::builtin_template_anki_num("lapis", "Card 1");
    let d = Device::new(tag);
    for p in [P, Q] {
        d.core.sync2_identity(p, T0).unwrap();
        while d.core.sync2_migrate(p, T0, None).unwrap()["done"] != json!(true) {}
    }
    let apply = |p: &str, now: i64, events: Vec<Value>, note: &str| {
        let input: Vec<Value> = events
            .into_iter()
            .map(|e| json!({"e": e, "note": note}))
            .collect();
        d.core
            .sync2_apply_local(p, now, &Value::Array(input).to_string())
            .unwrap();
    };
    let entity = |p: &str, id: &str, kind: &str, dd: Value| json!({"t": "entity", "x": {"id": id, "p": p, "k": kind, "d": dd}});
    let edit = |p: &str, e: &str, key: &str, v: Value| {
        json!({"t": "edit", "x": {
            "id": "ignored", "p": p, "k": "note", "e": e, "f": key, "w": "dart", "s": 1,
            "ctx": {"vv": {}}, "v": v, "hlc": "0:0:dart", "ts": "anchored"
        }})
    };
    let deck = |p: &str| {
        entity(
            p,
            &crate::store::sync2::config::default_deck_id(p),
            "deck",
            json!({"createdAt": 1, "builtin": "default"}),
        )
    };
    let builtin = |p: &str| {
        entity(
            p,
            &rules::note_type(Some(p), lapis).text(),
            "notetype",
            json!({"createdAt": 1, "ntKind": "standard", "builtin": "lapis", "ankiNum": lapis}),
        )
    };
    let nt_q = rules::note_type(Some(Q), lapis);
    apply(P, T0, vec![deck(P), builtin(P)], "N0");
    let guid = "x-guid-q1";
    let note = rules::note(Some(Q), guid).text();
    let card = rules::card(
        &rules::note(Some(Q), guid),
        &rules::template(&nt_q, tmpl_n),
        0,
    );
    let mut q = vec![deck(Q), builtin(Q)];
    q.push(entity(
        Q,
        &note,
        "note",
        json!({"createdAt": 1, "guid": guid, "noteTypeId": rules::note_type(Some(P), lapis).text()}),
    ));
    // 字段键是 [Q] 的配置给的（Dart 按当前 profile 的内置视图写）。
    q.push(edit(
        Q,
        &note,
        &format!("f/{}", rules::field(&nt_q, field_n).text()),
        json!("猫"),
    ));
    apply(Q, T0, q, &note);
    let mut log = crate::store::sync2::tests::review(
        "0193a1b2-0000-7000-8000-00000000d001",
        &card.text(),
        T0 + 10,
        3,
        "learn",
    );
    log["x"]["p"] = json!(Q);
    apply(Q, T0 + 10, vec![log], &note);
    if delete {
        apply(
            Q,
            T0 + 20,
            vec![edit(Q, &note, "deleted", json!(T0 + 20))],
            &note,
        );
    }
    for p in [P, Q] {
        let salted = lapis_cfg(Some(p));
        let parsed =
            crate::store::caches::CacheConfig::parse(&serde_json::from_str(&salted).unwrap())
                .unwrap();
        let w = d.core.writer().unwrap();
        crate::store::sync2::in_savepoint(&w, |c| crate::store::caches::rebuild(c, p, &parsed))
            .unwrap();
    }
    // 协议 3 照常给了这条笔记一张卡。
    let rows = d.rows(&format!(
        "SELECT srs_idt(id) AS id, hidden FROM srs_cards_cache WHERE profile_uid = srs_id('{Q}')"
    ));
    assert_eq!(
        rows[1..],
        [vec![card.text(), (delete as i64).to_string()]],
        "{rows:?}"
    );
    let Device { core, _dir } = d;
    core.close();
    drop(core);
    let canonical_card = rules::card(
        &rules::note(CANONICAL, guid),
        &rules::template(&rules::note_type(CANONICAL, lapis), tmpl_n),
        0,
    );
    (_dir, canonical_card)
}

/// 内置 lapis 只有一个字段、一条模板的缓存配置（[salt] 下的 ID；`None` = 规范 ID，交给新代内核的那份）。
fn lapis_cfg(salt: Option<&str>) -> String {
    use crate::gen4_ids::rules;
    let lapis = rules::builtin_note_type_anki_num("lapis");
    let nt = rules::note_type(salt, lapis);
    let f = rules::field(&nt, rules::builtin_field_anki_num("lapis", "Expression")).text();
    let tpl = rules::template(&nt, rules::builtin_template_anki_num("lapis", "Card 1")).text();
    json!({
        "defaultDeck": rules::builtin_default_deck(salt).text(),
        "builtins": {"lapis": {"b": {
            "name": "Lapis", "css": "", "termFieldId": f,
            "fields": [{"id": f, "name": "Expression", "ord": 0}],
            "templates": [{"id": tpl, "name": "Card 1", "ord": 0,
                           "front": "{{Expression}}", "back": "{{FrontSide}}"}],
        }, "reading": null}},
    })
    .to_string()
}

/// BUG-5269：[Q] 的笔记挂在 [P] 的带盐内置笔记类型上。[Q] 的盐集合带上 [P]（它的数据里有 [P] 加盐的 ID），新代认出
/// 那是内置笔记类型：笔记有排序字段、有规范卡，复习挂在规范卡上，对拍通过、整份提交。[P] 不引用 [Q]，盐集合不变。
/// 删没删笔记都一样。去掉修复时与用户报告同签名（notes 词条键 / 排序字段 /
/// 去重键旧有新空，cards 旧侧多一张，stats 的卡两侧不同，别名层一个卡 ID 验不上）。
#[test]
fn a_note_on_another_profiles_builtin_note_type_migrates() {
    let canonical = lapis_cfg(crate::gen4_ids::rules::CANONICAL);
    let caches = BTreeMap::from([(P.to_owned(), canonical.clone()), (Q.to_owned(), canonical)]);
    for delete in [true, false] {
        let (dir, card) = library_with_a_note_on_another_profiles_builtin(
            &format!("x-foreign-nt-{delete}"),
            delete,
        );
        let out = migrate_with(&dir.0, &caches, &Stop::new(), &mut Vec::new());
        let report = match &out {
            Outcome::Committed { report } | Outcome::Aborted { report, .. } => report,
            _ => panic!("{out:?}"),
        };
        assert_eq!(out.verdict(), "committed", "delete={delete} {report:#}");
        let salts: Vec<(&str, &Value)> = report["profiles"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| (p["profile"].as_str().unwrap(), &p["salts"]))
            .collect();
        assert_eq!(
            salts,
            vec![(P, &json!(1)), (Q, &json!(2))],
            "delete={delete}"
        );
        let opened = open_gen4(&dir.0, OpenMode::Primary).unwrap();
        let got: (i64, String, i64) = opened
            .conn
            .query_row(
                "SELECT c.hidden, n.sort_field,                  (SELECT COUNT(*) FROM stats s WHERE s.col = c.col AND s.card = c.id)                  FROM cards c JOIN notes n ON n.col = c.col AND n.id = c.note_id WHERE c.id = ?1",
                params![crate::store::gen4::derive::Ref::of(
                    &crate::sync2::id::Key::Uuid(card)
                )],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap_or_else(|e| panic!("delete={delete}: card {} has no row: {e}", card.text()));
        assert_eq!(got, (delete as i64, "猫".to_owned(), 1), "delete={delete}");
    }
}
