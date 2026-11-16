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
use crate::store::sync2::tests::{Device, P, tempdir};
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
/// 目录（中止、带对拍差异），临时文件留作诊断，状态报迁移失败。旧库没动过，协议 3 的内核照旧能开。再跑一次同样中止（从头重来，不在留下的半份上续做）。
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
            report_path,
            report,
        } = &out
        else {
            panic!("{out:?}")
        };
        assert_eq!(report_path, &dir.0.join(REPORT_FILE));
        assert_eq!(report["verdict"], "aborted");
        assert_eq!(report["profiles"][0]["verdict"], "fail");
        assert_ne!(report["profiles"][0]["parity"], json!([]));
        assert_eq!(report_file(&dir.0)["verdict"], "aborted");
        assert!(dir.0.join(GEN4_TEMP).exists());
        assert!(!dir.0.join(GEN4_FILE).exists());
        assert_eq!(masked(&dir.0), before);
        assert_eq!(
            schema_of(&dir.0),
            crate::store::schema::SCHEMA_VERSION.to_string()
        );
        assert_eq!(status(&dir.0), Ok(GenState::MigrationFailed));
    }
}

/// 前提不齐一律拦下、什么都不碰（旧库逐字节不变，不留临时文件）：没给缓存配置、并入做到一半、收段留下的待重放卡、
/// 有投影数据却不在操作日志里的 profile。拦下的原因逐条带 profile。
#[test]
fn unmet_preconditions_block_before_anything_is_written() {
    let other = "0193a1b2-0000-7000-8000-00000000cafe";
    let cases: [(&str, &dyn Fn(&Connection), BTreeMap<String, String>, &str); 4] = [
        (
            "g72-nocfg",
            &|_| {},
            BTreeMap::new(),
            "no cache configuration",
        ),
        (
            "g72-merge",
            &|c| {
                c.execute(
                    "INSERT INTO srs_meta (key, value) VALUES (?1, '{}')",
                    [format!("profile_merge/{other}")],
                )
                .unwrap();
            },
            caches(),
            "profile merge is half done",
        ),
        (
            "g72-replay",
            &|c| {
                c.execute(
                    "INSERT INTO sync2_replay_pending (profile_uid, card_id) VALUES (srs_id(?1), srs_id(?2))",
                    [P, N2],
                )
                .unwrap();
            },
            caches(),
            "waiting to be replayed",
        ),
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
            "not in the protocol 3 op log",
        ),
    ];
    for (tag, prep, caches, why) in cases {
        let dir = legacy_dir(tag, &|_| {});
        prep(&raw(&dir.0));
        let before = masked(&dir.0);
        let out = migrate_with(&dir.0, &caches, &Stop::new(), &mut Vec::new());
        let Outcome::Blocked { reason } = &out else {
            panic!("{tag}: {out:?}")
        };
        assert!(reason.contains(why), "{tag}: {reason}");
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
    assert_eq!(migrate(&dir.0), blocked(BLOCKED_MIGRATING));
    assert_eq!(status(&dir.0), Ok(GenState::MigratingElsewhere));
    drop(lock);
    let writer = raw(&dir.0);
    writer.execute_batch("BEGIN IMMEDIATE").unwrap();
    assert_eq!(migrate(&dir.0), blocked(BLOCKED_BUSY));
    writer.execute_batch("ROLLBACK").unwrap();
    drop(writer);
    assert!(!dir.0.join(GEN4_TEMP).exists());
    assert!(!dir.0.join(GEN4_FILE).exists());

    raw(&dir.0)
        .execute("UPDATE srs_meta SET value = '28' WHERE key = 'schema'", [])
        .unwrap();
    let Outcome::Blocked { reason } = migrate(&dir.0) else {
        panic!()
    };
    assert!(reason.contains("schema 28"), "{reason}");
    raw(&dir.0)
        .execute(
            "UPDATE srs_meta SET value = ?1 WHERE key = 'schema'",
            [SEALED_SCHEMA.to_string()],
        )
        .unwrap();
    let Outcome::Blocked { reason } = migrate(&dir.0) else {
        panic!()
    };
    assert!(reason.contains("sealed"), "{reason}");
    assert_eq!(status(&dir.0), Ok(GenState::SealedOldOnly));

    let empty = tempdir::new("g72-empty");
    let Outcome::Blocked { reason } = migrate(&empty.0) else {
        panic!()
    };
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
    let Outcome::Aborted { report, .. } = &out else {
        panic!("{out:?}")
    };
    assert_eq!(report["verdict"], "aborted");
    assert_eq!(report["profileVerdict"], "incomplete", "{report:#}");
    assert_eq!(report["profiles"][0]["verdict"], "incomplete", "{report:#}");
    assert!(!dir.0.join(GEN4_FILE).exists());
    assert_eq!(masked(&dir.0), before);
    assert_eq!(
        schema_of(&dir.0),
        crate::store::schema::SCHEMA_VERSION.to_string()
    );
    assert_eq!(status(&dir.0), Ok(GenState::MigrationFailed));
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
