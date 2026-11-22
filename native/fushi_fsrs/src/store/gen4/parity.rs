//! 测试装置：协议 3 的投影，对同一份库灌进新存储之后的派生层（设计 §8 G6 行「现有内核行为测试在新存储上全绿」）。
//!
//! [check_core] 挂在协议 3 内核 `SrsCore` 的析构上（只在测试构建里）：每个场景里每个库关掉之前，把它灌进一个内存里的
//! 新代库，查三件事——
//!
//! 1. `rebuild_all` 再做一遍，派生表逐行不变；
//! 2. 换一种到达方式（一台设备一台设备地逐条落、逐条维护，信任状态最后才给），派生表与重建出来的逐行相同；
//! 3. 与协议 3 的投影对拍（[against_protocol_3]，比法在 `compare.rs`，干跑共用）没有差异——协议 3 一侧比的是「它自己的
//!    规则作用在全集上」：扣住在全集上重判（[rejudge_holds]），活着的修改记录按它自己的寄存器判据取
//!    （`compare::protocol_3_live_edits`）；两份旧库撞了同一个旧修改记录 ID 的不比（`compare::Collisions`）；缓存层（笔记行 /
//!    卡行 / 有效复习投影）按同一份缓存配置（只有默认牌组）与协议 3 在 SAVEPOINT 里 `caches::rebuild` 出来的行逐列比，
//!    比完回滚。缓存层的有意差别与口径（`cache.rs` 文件头「与协议 3 的差别」）：笔记行的 `updated_at` 不比；协议 3 因
//!    身份记录不成形整次重建失败时缓存三类不比；有删除被扣住的笔记不比 `deleted_at` / `pending_decision` 与它的卡的
//!    `hidden`、笔记类型的删除被扣住时它的笔记的卡不比 `hidden`（同 `edits` 的口径）；同一个旧修改记录 ID 下有两条
//!    不同修改的笔记（复制出来的两份旧库各自续写）不比它与它的卡。
//!    协议 3 一侧先做完它自己欠着的收尾（待重放集合、没刷新的合成标签行）再重建（[protocol_3_caches]）。
//!
//! 库还没做完换代前必须做完的事（旧行没包成操作、去重作业没跑完）时，在一份拷贝上把它们做完再对拍（拷贝、收尾
//! 出错都算失败）；做不完的（新设备收段通道还开着）跳过，跳过的场景逐个列在 [SKIPS]，没列的跳过让测试失败。与协议 3
//! 有意不同的场景列在 [KNOWN]，逐条写原因。
//! 设了环境变量 `FUSHI_GEN4_PARITY_REPORT=<文件>` 时不让测试失败，改成把每个场景的结果追加进那个文件（盘点用）。

use std::cell::Cell;
use std::collections::BTreeSet;
use std::io::Write as _;
use std::path::Path;
use std::time::Instant;

use rusqlite::{Connection, params};

use super::cache::CFG_KEY;
use super::compare::{
    self, CARD_COLS, CacheRows, NOTE_COLS, OldCachesError, STAT_COLS, op_text, rows_of, texts,
};
pub(crate) use super::compare::{Diff, cell};
use super::derive::tests::{canon, digest, dump};
use super::derive::{Index, R_LIVE, Ref, body_of};
use super::import::import_legacy;
use super::legacy;
use super::legacy::tests::peak_mem_mb;
use super::schema::{open, open_in_memory};
use super::truth::Truth;
use crate::gen4::op::Body4;
use crate::store::SrsCore;
use crate::store::sync2::collection_of;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{Device, P, tempdir};
use crate::sync2::id::Id;
use crate::sync2::vv::OpId;

/// 接不进对拍的场景（设计 §8 G6c「接不进的逐个列原因」）：(测试名的结尾, 拦下它的那条 [legacy::preflight] 拦截项,
/// 原因)。一个场景里关掉的库不止一个，表里的场景只是其中某一次被拦下，其余照常对拍。被拦下、拦截项却不在这张表里
/// 的，让那个测试失败（[unlisted_blockers]）；表里的场景已经不再被拦下的，让 [skips_are_exactly_the_listed_ones]
/// 失败——跳过的集合恰好是这张表。这几处都是库关在新设备收段会话中途（`sync2_boot` 还有行）：会话要靠对端剩下的段
/// 收完，在拷贝上做不完；真实升级遇到同样的库也被 preflight 拦下、先等会话收完。
const SKIPS: &[(&str, &str, &str)] = &[
    (
        "store::sync2::tests::ingest_session_requires_begin_and_a_stable_identity",
        "a new-device ingest channel is still open",
        "the session is voided by an identity change after ingest_begin and the test ends there",
    ),
    (
        "store::sync2::tests_cache_pending::a_session_voided_by_an_error_releases_the_held_cache",
        "a new-device ingest channel is still open",
        "ingest_commit fails on the rotated identity and the test ends with the session's channel row left behind",
    ),
    (
        "store::sync2::tests_channel::nothing_is_distrusted_when_the_channel_opens",
        "a new-device ingest channel is still open",
        "the test only checks the trust state right after the channel opens and never finishes the session",
    ),
    (
        "store::sync2::transport::budget_tests::ingest_session_is_a_bootstrap_until_this_device_reviews",
        "a new-device ingest channel is still open",
        "the test only reads the slice policy of sessions it begins and never finishes them",
    ),
    (
        "store::sync2::tests_replay_pending::interrupted_session_resumes_the_pending_replay",
        "a new-device ingest channel is still open",
        "the channel half closes the database mid-append on purpose (\"killed\") before reopening it to resume",
    ),
];

/// 协议 3 冻结的缓存重建在身份记录不成形的笔记上整次失败时报的错误文本（`registers.rs`；`cache.rs` 文件头「与协议 3
/// 的差别」）：[KNOWN] 里 `caches` 类的条目按它逐字认。
const NOTE_TYPE_MISSING: &str = "noteTypeId missing";

/// `store/tests_v15_upgrade.rs` 的真实 v15 / v8 库（tests/fixtures 的生成器）里笔记身份记录没有 `noteTypeId`：协议 3 的
/// 缓存重建整次失败。
const OLD_SCHEMA_FIXTURE_NOTES: &str = "the real v15 / v8 fixture databases (tests/fixtures generators) hold note \
     identity records without noteTypeId: protocol 3's frozen cache rebuild fails as a whole on them (cache.rs \
     header), so there is no protocol 3 cache baseline to compare against";

/// [KNOWN] 的一条。
struct Known {
    /// 测试的全名（[known_is_exactly_what_the_listed_tests_hit] 拿它 `--exact` 跑）。
    test: &'static str,
    /// [against_protocol_3] 的类别，或 `error`（灌入本身失败）。
    what: &'static str,
    /// 只认这一种差异：协议 3 一侧恰好是这一条、新代一侧为空。`caches` 类必须给（[known_caches_entries_name_their_error]）
    /// ——那是协议 3 缓存重建失败报的错误文本，同一个场景因别的原因（协议 3 收尾里的真 bug、搭环境出错）报出的不同
    /// 文本照样失败。`None` 只按类别认。
    old: Option<&'static str>,
    why: &'static str,
}

/// 对不上、而且不该对上的场景，逐条写原因。大多是测试手改了协议 3 的日志表或投影表、库自己已经不自洽；`caches` 类是
/// 有意造出协议 3 缓存重建失败的场景。登记了却不再命中的条目让 [known_is_exactly_what_the_listed_tests_hit] 失败。
const KNOWN: &[Known] = &[
    Known {
        test: "store::gen4::dryrun::tests::a_projection_that_disagrees_with_the_log_fails",
        what: "edits",
        old: None,
        why: "the test deletes one live srs_field_edits row by hand to prove the dry run catches a projection that \
              disagrees with its own log; the field, the note row and its cards differ on purpose",
    },
    Known {
        test: "store::gen4::dryrun::tests::a_projection_that_disagrees_with_the_log_fails",
        what: "notes",
        old: None,
        why: "the test deletes one live srs_field_edits row by hand to prove the dry run catches a projection that \
              disagrees with its own log; the field, the note row and its cards differ on purpose",
    },
    Known {
        test: "store::gen4::dryrun::tests::a_projection_that_disagrees_with_the_log_fails",
        what: "cards",
        old: None,
        why: "the test deletes one live srs_field_edits row by hand to prove the dry run catches a projection that \
              disagrees with its own log; the field, the note row and its cards differ on purpose",
    },
    Known {
        test: "store::gen4::dryrun::tests::an_unrelated_column_on_a_masked_row_still_fails",
        what: "edits",
        old: None,
        why: "the test deletes one live srs_field_edits row (the note's deck) by hand to prove a column the known               difference does not feed is still compared on a masked row; the edit and the note row differ on purpose",
    },
    Known {
        test: "store::gen4::dryrun::tests::an_unrelated_column_on_a_masked_row_still_fails",
        what: "notes",
        old: None,
        why: "the test deletes one live srs_field_edits row (the note's deck) by hand to prove a column the known               difference does not feed is still compared on a masked row; the edit and the note row differ on purpose",
    },
    Known {
        test: "store::gen4::legacy::tests::a_duplicate_skeleton_in_the_log_becomes_an_alias",
        what: "edits",
        old: None,
        why: "the test rewrites one sync2_ops row into a duplicate skeleton by hand (not through dedup::apply), so \
              the protocol 3 projection still holds the edit its own log no longer has",
    },
    Known {
        test: "store::sync2::tests_digest::diverged_devices_locate_the_differing_bucket",
        what: "stats",
        old: None,
        why: "the test rewrites one srs_review_logs row's rating by hand (a silent divergence that never went \
              through sync), so the protocol 3 projection no longer matches the log op the new store reads",
    },
    Known {
        test: "store::sync2::tests_footprint::upgrading_from_before_v16_adds_the_snapshot_columns_before_reading_ops",
        what: "error",
        old: None,
        why: "the test drops sync2_ops.sc / sc_at by hand: the ops whose payload was packed against a config \
              snapshot lose the reference, so their bytes no longer hash to the stored chain (the reader refuses \
              them)",
    },
    Known {
        test: "store::tests_v15_upgrade::a_real_v15_database_upgrades_row_for_row",
        what: "caches",
        old: Some(NOTE_TYPE_MISSING),
        why: OLD_SCHEMA_FIXTURE_NOTES,
    },
    Known {
        test: "store::tests_v15_upgrade::a_real_v8_database_upgrades_row_for_row",
        what: "caches",
        old: Some(NOTE_TYPE_MISSING),
        why: OLD_SCHEMA_FIXTURE_NOTES,
    },
    Known {
        test: "store::gen4::dryrun::tests::a_failed_protocol_3_cache_rebuild_is_incomplete_not_pass",
        what: "caches",
        old: Some(NOTE_TYPE_MISSING),
        why: "the test adds a note identity record without noteTypeId on purpose: protocol 3's frozen cache \
              rebuild fails as a whole on it (cache.rs header), so there is no protocol 3 cache baseline to \
              compare against",
    },
    Known {
        test: "store::gen4::migrate::tests::an_incomplete_parity_aborts_like_a_failure",
        what: "caches",
        old: Some(NOTE_TYPE_MISSING),
        why: "the same fixture as the dry run's incomplete test, used to prove the migration aborts on an \
              incomplete parity: protocol 3's frozen cache rebuild fails as a whole on the note without \
              noteTypeId, so there is no protocol 3 cache baseline to compare against",
    },
    Known {
        test: "store::gen4::dryrun::tests::parity_reports_a_failed_protocol_3_cache_rebuild_as_a_caches_diff",
        what: "caches",
        old: Some(NOTE_TYPE_MISSING),
        why: "the test adds a note identity record without noteTypeId on purpose to prove the parity gate reports \
              a failed protocol 3 cache rebuild instead of skipping the cache layer",
    },
    Known {
        test: "store::gen4::prepare::tests::a_library_missing_tables_its_schema_claims_is_refused_as_corrupt",
        what: "caches",
        old: Some("no such table: sync2_replay_pending"),
        why: "the test drops sync2_replay_pending and marks the library as schema 13 on purpose (a development \
              build's library) to prove the migration refuses it as corrupt: protocol 3's own catch-up fails on \
              the missing table, so there is no protocol 3 cache baseline when the preparation copy is closed",
    },
    Known {
        test: "store::sync2::tests_channel::channel_is_for_a_profile_holding_nothing_but_its_own_builtins",
        what: "entities",
        old: None,
        why: "the ch-missing-row device deletes the srs_entities row of a builtin note type by hand (to check \
              that the channel stays shut when a projected row is gone): its own log still holds the identity \
              record",
    },
];

/// 这个场景的一类差异（协议 3 一侧 [old]、新代一侧 [new]）在 [KNOWN] 里对得上的那条。
fn known_entry(name: &str, what: &str, old: &[String], new: &[String]) -> Option<&'static Known> {
    KNOWN.iter().find(|k| {
        name.ends_with(k.test)
            && k.what == what
            && match k.old {
                None => true,
                Some(text) => new.is_empty() && old.len() == 1 && old[0] == text,
            }
    })
}

/// 协议 3 一侧的缓存行：在 SAVEPOINT 里先把协议 3 自己还欠着的收尾做完——待重放集合（`transport::replay_pending`：
/// 协议 3 的日志结果是重放写回的，收段会话里推迟的重放没跑之前缓存读到的是旧结果）、合成标签行（`semantics::
/// refresh_tags_row`：`tags` 修改行是 OR-Set 的投影，没被刷新过的旧合成行与 OR-Set 不一致）——再按同一份缓存配置
/// `caches::rebuild` 一遍、读行、整个回滚（库原样不动）。新代没有推迟的重放、标签直接取 OR-Set，比的是两边各自收尾
/// 做完的样子。只读打开的库（真实样本）动不了，读它现有的缓存表——那是 app 用自己的配置写的，新代那边要给同一份
/// 配置（`gen4_sample_index` 的 `FUSHI_GEN4_CACHE_CFG_FILE`）。
fn protocol_3_caches(
    src: &Connection,
    profile: &str,
    cfg: &str,
) -> Result<CacheRows, OldCachesError> {
    use OldCachesError::{Protocol3, Setup};
    let read = || -> Result<CacheRows, String> {
        let olds = |cols: &[(&'static str, &'static str)]| -> Vec<&'static str> {
            cols.iter().map(|c| c.1).collect()
        };
        let filter = "profile_uid = srs_id(?1)";
        Ok((
            rows_of(src, "srs_notes_cache", &olds(NOTE_COLS), filter, &profile)?,
            rows_of(src, "srs_cards_cache", &olds(CARD_COLS), filter, &profile)?,
            rows_of(src, "srs_stat_reviews", &olds(STAT_COLS), filter, &profile)?,
        ))
    };
    if src.is_readonly("main").map_err(|e| Setup(e.to_string()))? {
        return read().map_err(Setup);
    }
    let cfg = crate::store::caches::CacheConfig::parse(
        &serde_json::from_str(cfg).map_err(|e| Setup(e.to_string()))?,
    )
    .map_err(Setup)?;
    src.execute_batch("SAVEPOINT g4par")
        .map_err(|e| Setup(e.to_string()))?;
    let out = (|| -> Result<CacheRows, OldCachesError> {
        // 收尾与重建都是协议 3 自己的代码。
        crate::store::sync2::transport::replay_pending(
            src,
            profile,
            &mut crate::store::sync2::transport::CommitBudget::unlimited(),
        )
        .map_err(Protocol3)?;
        let synthetic = texts(
            src,
            "SELECT DISTINCT srs_idt(entity_id) FROM srs_field_edits WHERE profile_uid = srs_id(?1) \
             AND entity_kind = 'note' AND field_key = 'tags' AND writer_id LIKE 'sync2:%'",
            &[&profile],
        )
        .map_err(Setup)?;
        let mut touched = crate::store::sync2::Touched::default();
        for note in &synthetic {
            crate::store::sync2::semantics::refresh_tags_row(src, profile, note, &mut touched)
                .map_err(Protocol3)?;
        }
        crate::store::caches::rebuild(src, profile, &cfg).map_err(Protocol3)?;
        read().map_err(Setup)
    })();
    src.execute_batch("ROLLBACK TO g4par; RELEASE g4par")
        .map_err(|e| Setup(e.to_string()))?;
    out
}

/// [compare::against_protocol_3] 的测试口径：协议 3 一侧的缓存行取 [protocol_3_caches]（可写连接上先收尾再重建、
/// 整个回滚；只读连接读现有的缓存表），不另外跳过什么；出错直接让测试失败。协议 3 一侧收尾 / 重建失败
/// （[OldCachesError::Protocol3]）在干跑里记成基准缺失（结论 `incomplete`），在这里一律报成 `caches` 差异：测试门
/// 不接受「缓存层没比成」，真预期协议 3 重建会失败的场景写进 [KNOWN] 显式豁免。
///
/// 可写连接上先在一个 SAVEPOINT 里把扣住按协议 3 自己的规则在全集上重判一遍（[rejudge_holds]）再比，比完整个回滚
/// （库原样不动）；只读打开的库（真实样本、干跑）动不了，比它落库时的判定。
pub(crate) fn against_protocol_3(src: &Connection, profile: &str, t: &Truth<'_>, col: i64) -> Diff {
    let compare = || -> Diff {
        let mut protocol_3_failed: Option<String> = None;
        let mut diff = compare::against_protocol_3(
            src,
            profile,
            t,
            col,
            &mut |src: &Connection, profile: &str, cfg: &str| {
                protocol_3_caches(src, profile, cfg).inspect_err(|e| {
                    if let OldCachesError::Protocol3(text) = e {
                        protocol_3_failed = Some(text.clone());
                    }
                })
            },
            &compare::Skip::default(),
        )
        .unwrap()
        .0;
        if let Some(text) = protocol_3_failed {
            compare::push_pair(
                &mut diff,
                ("caches", BTreeSet::from([text]), BTreeSet::new()),
            );
        }
        diff
    };
    if src.is_readonly("main").unwrap() {
        return compare();
    }
    src.execute_batch("SAVEPOINT gen4_parity_holds").unwrap();
    rejudge_holds(src, profile);
    let diff = compare();
    src.execute_batch("ROLLBACK TO gen4_parity_holds; RELEASE gen4_parity_holds")
        .unwrap();
    diff
}

/// 协议 3 只在有操作落到一个实体上时重判这个实体上的删除该不该扣住（`semantics::evaluate_holds`），而把卡挪进牌组
/// 的修改只重判那张卡、不重判目标牌组（`store/sync2/mod.rs` `project_edit_noted`；移卡只记进牌组的实体操作索引）。
/// 于是牌组的删除先到、与它并发的移卡后到时删除不被扣住；反过来的顺序就扣住——扣不扣取决于到达顺序（设计 §2.5
/// 差别表「重判扣住的时机」）。新存储对全集判。对拍时协议 3 一侧对每个有删除的实体照它自己的规则重判一遍，比的是
/// 「协议 3 的规则作用在全集上」，不是它落库那一刻的判定。
fn rejudge_holds(src: &Connection, profile: &str) {
    let ents: Vec<(String, String)> = src
        .prepare(
            "SELECT DISTINCT kind, srs_idt(entity) FROM sync2_ent_ops WHERE profile_uid = srs_id(?1) AND what = 'deleted'",
        )
        .unwrap()
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let mut touched = crate::store::sync2::Touched::default();
    for (kind, ent) in ents {
        crate::store::sync2::semantics::evaluate_holds(src, profile, &kind, &ent, 0, &mut touched)
            .unwrap();
    }
}

/// 把 [t] 里的日志换一种到达方式再建一遍：新开一个库，一台设备一台设备地逐条落、逐条告诉索引（别的设备的依赖
/// 这时还没到），每 [every] 条收尾一次；信任状态最后才给。返回那边的派生表（[canon]）。
fn replayed(
    t: &Truth<'_>,
    col: i64,
    profile: &str,
    every: u64,
) -> Result<BTreeSet<String>, String> {
    let conn = open_in_memory()?;
    let t2 = Truth::new(&conn);
    let source = collection_of(profile);
    let col2 = t2.tx(|x| x.bind(profile, &source, profile))?;
    if let Some(cfg) = t.derive_cfg(col, CFG_KEY)? {
        t2.tx(|x| x.set_derive_cfg(col2, CFG_KEY, Some(&cfg)))?;
    }
    t2.tx(|t2| {
        let mut ix = Index::new(t2, col2);
        let mut n = 0u64;
        for d in t.devices(col)? {
            t.for_each(col, &d.id, 1, |e| {
                let slot = e
                    .slot()
                    .ok_or("replay: an imported entry is not a heritage slot")?;
                t2.put_heritage(col2, &source, &slot, e.tv)?;
                if let Some(now) = t2.entry(col2, &e.id)? {
                    ix.add(&now)?;
                }
                n += 1;
                if n % every == 0 {
                    ix.settle()?;
                }
                Ok(())
            })?;
        }
        ix.settle()?;
        for (device, state) in t.untrusted(col)? {
            t2.set_trust(col2, &device, Some(state), 0)?;
        }
        ix.trust_changed();
        ix.settle()?;
        Ok(())
    })?;
    Ok(canon(&t2, col2))
}

/// 一份协议 3 的库灌进内存里的新代库并重建；返回 (新库, 与协议 3 的差异)。重建两遍相同、换一种到达方式逐条维护出来
/// 的也相同——不同就报错。
pub(crate) fn imported_from(src: &Connection, profile: &str) -> Result<(Connection, Diff), String> {
    let conn = open_in_memory()?;
    let diff = {
        let t = Truth::new(&conn);
        let col = t.tx(|t| t.bind(profile, &collection_of(profile), profile))?;
        // 缓存层按协议 3 同一份配置物化（只有默认牌组；内置笔记类型的代码默认值两边都缺，同样缺）。
        let cfg = serde_json::json!({"defaultDeck": default_deck_id(profile)}).to_string();
        t.tx(|t| t.set_derive_cfg(col, CFG_KEY, Some(&cfg)))?;
        let n = import_legacy(src, profile, &t, col, 1000)?;
        t.tx(|t| Index::new(t, col).rebuild_all())?;
        let first = dump(t.conn(), col);
        t.tx(|t| Index::new(t, col).rebuild_all())?;
        if first != dump(t.conn(), col) {
            return Err("rebuild_all twice gives different rows".to_owned());
        }
        let every = if n.applied < 2000 { 1 } else { 257 };
        let (rebuilt, again) = (canon(&t, col), replayed(&t, col, profile, every)?);
        if rebuilt != again {
            let only = |a: &BTreeSet<String>, b: &BTreeSet<String>| -> Vec<String> {
                a.difference(b).take(6).cloned().collect()
            };
            return Err(format!(
                "incremental maintenance differs from rebuild_all: only rebuilt {:?}, only incremental {:?}",
                only(&rebuilt, &again),
                only(&again, &rebuilt)
            ));
        }
        against_protocol_3(src, profile, &t, col)
    };
    Ok((conn, diff))
}

pub(crate) fn imported(d: &Device) -> (Connection, Diff) {
    let w = d.core.writer().unwrap();
    imported_from(&w, P).unwrap()
}

fn report(name: &str, profile: &str, status: &str, detail: &str) -> bool {
    let Some(path) = std::env::var_os("FUSHI_GEN4_PARITY_REPORT") else {
        return false;
    };
    let line = format!(
        "{name}\t{profile}\t{status}\t{}\n",
        detail.replace(['\n', '\t'], " ")
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut f| f.write_all(line.as_bytes()));
    true
}

/// 有差异的修改记录各是什么（给人看的；只在报差异时算）。
fn explain(
    src: &Connection,
    profile: &str,
    conn: &Connection,
    diff: &[&(&'static str, Vec<String>, Vec<String>)],
) -> String {
    let mut out = Vec::new();
    let t = Truth::new(conn);
    for (what, old_only, new_only) in diff {
        if *what == "held" {
            for text in old_only.iter().chain(new_only) {
                out.push(explain_hold(src, profile, &t, text));
            }
        }
        if *what != "edits" {
            continue;
        }
        for id in old_only {
            let row: Option<(String, String, String, String, i64, String)> = src
                .prepare(
                    "SELECT entity_kind, srs_idt(entity_id), field_key, srs_idt(writer_id), seq, json FROM srs_field_edits \
                     WHERE profile_uid = srs_id(?1) AND srs_idt(id) = ?2",
                )
                .unwrap()
                .query_row([profile, id.as_str()], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?))
                })
                .ok();
            out.push(format!("old {id}: {row:?}"));
        }
        let mut stmt = conn
            .prepare("SELECT ekind, ent, k, state FROM reg_ix WHERE state >= ?1")
            .unwrap();
        let rows: Vec<(i64, Ref, i64, i64)> = stmt
            .query_map([R_LIVE], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for (ekind, ent, k, state) in rows {
            let e = t.entry_by_key(k).unwrap().unwrap();
            let Some(Body4::Edit(ed)) = body_of(&e) else {
                continue;
            };
            let id = match &ed.stamp {
                Some(s) => crate::registers::edit_id(&s.writer, s.seq),
                None => crate::registers::edit_id(&e.id.device.text(), e.id.seq as i64),
            };
            if new_only.contains(&id) {
                out.push(format!(
                    "new {id}: kind {ekind} ent {} key {} op {} state {state} stamp {:?} value {}",
                    ent.text(),
                    ed.key,
                    op_text(&e.id),
                    ed.stamp.as_ref().map(|s| (&s.writer, s.seq)),
                    ed.value
                ));
            }
        }
    }
    out.join(" ;; ")
}

/// 一条扣住有差异的删除：协议 3 的实体操作索引里，它所在实体的每条操作与它的因果关系、在新存储里的样子。
fn explain_hold(src: &Connection, profile: &str, t: &Truth<'_>, text: &str) -> String {
    let Some((dev, seq)) = text.rsplit_once(':') else {
        return format!("hold {text}: ?");
    };
    let Some(device) = crate::gen4_ids::alias::strict_id(dev) else {
        return format!("hold {text}: ?");
    };
    let d = OpId {
        device,
        seq: seq.parse().unwrap_or(0),
    };
    let col: i64 = t
        .conn()
        .query_row("SELECT col FROM collections LIMIT 1", [], |r| r.get(0))
        .unwrap();
    let head_of = |id: &OpId| {
        t.key_of(col, id)
            .ok()
            .flatten()
            .and_then(|k| t.head_by_key(k).ok().flatten().map(|h| (k, h)))
    };
    let Some((_, dh)) = head_of(&d) else {
        return format!("hold {text}: not in the new store");
    };
    let ents: Vec<(String, String)> = src
        .prepare(
            "SELECT kind, srs_idt(entity) FROM sync2_ent_ops WHERE profile_uid = srs_id(?1) AND device = ?2 AND seq = ?3",
        )
        .unwrap()
        .query_map(params![profile, d.device.0.to_vec(), d.seq as i64], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let mut out = vec![format!("hold {text} on {ents:?}")];
    for (kind, entity) in &ents {
        let rows: Vec<(Vec<u8>, i64, String)> = src
            .prepare(
                "SELECT device, seq, what FROM sync2_ent_ops WHERE profile_uid = srs_id(?1) AND kind = ?2 AND entity = srs_id(?3)",
            )
            .unwrap()
            .query_map(params![profile, kind, entity], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for (dev, seq, what) in rows {
            let x = OpId {
                device: Id(dev.try_into().unwrap()),
                seq: seq as u64,
            };
            if x == d {
                continue;
            }
            let Some((k, xh)) = head_of(&x) else {
                out.push(format!("{} {what}: not in the new store", op_text(&x)));
                continue;
            };
            let relation = match (dh.saw(&x), xh.saw(&d)) {
                (true, _) => "before",
                (_, true) => "after",
                _ => "concurrent",
            };
            if relation == "before" && what != "deleted" {
                continue;
            }
            let body = t
                .entry_by_key(k)
                .ok()
                .flatten()
                .map(|e| match body_of(&e) {
                    Some(Body4::Edit(ed)) => format!(
                        "edit {} = {} stamped {}",
                        ed.key,
                        ed.value,
                        ed.stamp.is_some()
                    ),
                    Some(other) => format!("{other:?}").chars().take(60).collect(),
                    None => "not applied".to_owned(),
                })
                .unwrap_or_default();
            let state: Option<i64> = t
                .conn()
                .query_row("SELECT state FROM reg_ix WHERE k = ?1", [k], |r| r.get(0))
                .ok();
            out.push(format!(
                "{} {what} {relation} raw {} state {state:?}: {body}",
                op_text(&x),
                xh.raw
            ));
        }
    }
    out.join(" ;; ")
}

thread_local! {
    /// 对拍自己开的库（收尾用的拷贝）关掉时不再对拍。
    static BUSY: Cell<bool> = const { Cell::new(false) };
}

struct Busy;

impl Drop for Busy {
    fn drop(&mut self) {
        BUSY.set(false);
    }
}

/// 协议 3 的库关掉之前调（`store/mod.rs` 的 `SrsCore::close` 与 `Drop for SrsCore`，只在测试构建里）。
pub(crate) fn check_core(core: &SrsCore) {
    if std::thread::panicking() || BUSY.get() {
        return;
    }
    BUSY.set(true);
    let _busy = Busy;
    let thread = std::thread::current();
    let name = thread.name().unwrap_or("?").to_owned();
    // 已经关掉的库（`close` 时对过了）：没有可读的。
    let (profiles, ready) = {
        let Ok(w) = core.writer() else {
            return;
        };
        let Ok(profiles) = legacy::profiles(&w) else {
            return;
        };
        let ready = profiles
            .iter()
            .all(|p| legacy::preflight(&w, p).is_ok_and(|b| b.is_empty()));
        (profiles, ready)
    };
    if profiles.is_empty() {
        // 没启用协议 3 的库：没有操作日志可灌。
        return;
    }
    if ready {
        if let Ok(w) = core.writer() {
            for profile in &profiles {
                check_profile(&name, &w, profile);
            }
        }
        return;
    }
    // 还没做完换代前必须做完的事（旧行没包成操作、去重作业没跑完）：在一份拷贝上把它们做完再对拍——真实的升级
    // 也是先在旧代码上收尾。原库不动（这个测试后面可能还要重新打开它）。
    let dir = tempdir::new("g4par");
    let path = dir.0.join("srs.db");
    // 拷贝、收尾出错都是失败，不是跳过：吞掉的话这个场景会无声地从对拍里掉出去。
    if let Err(e) = core.snapshot_into(&path, false) {
        fail(&name, "-", "error", &format!("cannot snapshot: {e}"));
        return;
    }
    let copy = match SrsCore::open(&path) {
        Ok(c) => c,
        Err(e) => {
            fail(
                &name,
                "-",
                "error",
                &format!("cannot reopen the snapshot: {e}"),
            );
            return;
        }
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64);
    let mut finished = Vec::new();
    for profile in &profiles {
        match finish_on_old_code(&copy, profile, now) {
            Ok(()) => finished.push(profile),
            Err(e) => fail(
                &name,
                profile,
                "error",
                &format!("cannot finish the pre-upgrade work: {e}"),
            ),
        }
    }
    // 写连接在收尾之后才拿：收尾的每一步自己要拿它。
    match copy.writer() {
        Ok(w) => {
            for profile in finished {
                check_profile(&name, &w, profile);
            }
        }
        Err(e) => fail(
            &name,
            "-",
            "error",
            &format!("cannot read the snapshot: {e}"),
        ),
    };
}

/// 换代前在旧代码上必须做完的事，在拷贝上做完：建协议 3 身份、把旧行包成操作、跑完去重作业。任何一步出错（或
/// 十万步还没做完）照实返回。
fn finish_on_old_code(copy: &SrsCore, profile: &str, now: i64) -> Result<(), String> {
    copy.sync2_identity(profile, now)?;
    let to_done = |what: &str, step: &dyn Fn() -> Result<serde_json::Value, String>| {
        for _ in 0..100_000 {
            if step()?["done"] == serde_json::json!(true) {
                return Ok(());
            }
        }
        Err(format!("{what} did not finish in 100000 steps"))
    };
    to_done("sync2_migrate", &|| copy.sync2_migrate(profile, now, None))?;
    to_done("sync2_dedup", &|| copy.sync2_dedup(profile, now))
}

fn check_profile(name: &str, w: &Connection, profile: &str) {
    let blockers = match legacy::preflight(w, profile) {
        Ok(b) => b,
        Err(e) => {
            fail(name, profile, "error", &format!("preflight: {e}"));
            return;
        }
    };
    if !blockers.is_empty() {
        let unlisted = unlisted_blockers(name, &blockers);
        if unlisted.is_empty() {
            report(name, profile, "skip", &blockers.join("; "));
        } else {
            fail(
                name,
                profile,
                "unlisted skip",
                &format!("blocked by {unlisted:?}, which SKIPS does not list for this test"),
            );
        }
        return;
    }
    let outcome = imported_from(w, profile);
    // 报告里每命中一条 [KNOWN] 记一行 `known`，详情以类别开头（[known_is_exactly_what_the_listed_tests_hit] 据此判过时）。
    let problem = match &outcome {
        Err(e) if known_entry(name, "error", std::slice::from_ref(e), &[]).is_some() => {
            report(name, profile, "known", &format!("error {e}"));
            return;
        }
        Err(e) => Some(("error", e.clone())),
        Ok((_, diff)) => {
            let (hits, unknown): (Vec<_>, Vec<_>) = diff
                .iter()
                .partition(|(what, old, new)| known_entry(name, what, old, new).is_some());
            if !hits.is_empty() && unknown.is_empty() {
                for (what, old, new) in hits {
                    report(name, profile, "known", &format!("{what} {old:?} {new:?}"));
                }
                return;
            }
            (!unknown.is_empty()).then(|| {
                let conn = &outcome.as_ref().unwrap().0;
                let columns: Vec<String> = unknown
                    .iter()
                    .filter_map(|(what, old, new)| {
                        compare::column_diffs(what, old, new).map(|c| format!("{what} {c:?}"))
                    })
                    .collect();
                (
                    "diff",
                    format!(
                        "{unknown:?} {columns:?} {}",
                        explain(w, profile, conn, &unknown)
                    ),
                )
            })
        }
    };
    match problem {
        None => {
            report(name, profile, "ok", "");
        }
        Some((status, detail)) => fail(name, profile, status, &detail),
    }
}

/// 让这个场景失败（设了 `FUSHI_GEN4_PARITY_REPORT` 时只记进报告）。
fn fail(name: &str, profile: &str, status: &str, detail: &str) {
    if !report(name, profile, status, detail) {
        panic!("gen4 parity ({name}, profile {profile}): {status}: {detail}");
    }
}

/// [blockers] 里 [SKIPS] 没为这个场景列的拦截项（空 = 这次跳过是表里列过的）。
fn unlisted_blockers<'a>(name: &str, blockers: &'a [String]) -> Vec<&'a str> {
    blockers
        .iter()
        .map(String::as_str)
        .filter(|b| {
            !SKIPS
                .iter()
                .any(|(test, blocker, _)| name.ends_with(test) && b == blocker)
        })
        .collect()
}

/// 跳过只认表里列过的：没列的场景、列了别的拦截项的场景都不放过。
#[test]
fn a_skip_must_be_listed_for_its_test_and_blocker() {
    let ch = vec!["a new-device ingest channel is still open".to_owned()];
    let listed = "store::sync2::tests_channel::nothing_is_distrusted_when_the_channel_opens";
    assert!(unlisted_blockers(listed, &ch).is_empty());
    assert_eq!(
        unlisted_blockers("store::sync2::tests::some_other_test", &ch),
        vec![ch[0].as_str()]
    );
    let more = vec![
        ch[0].clone(),
        "legacy rows are not migrated into the op log yet".to_owned(),
    ];
    assert_eq!(unlisted_blockers(listed, &more), vec![more[1].as_str()]);
}

/// [SKIPS] 里的场景现在仍然被拦下、而且只被表里那条拦截项拦下：在一个子进程里只跑这几个测试（报告模式，见文件头），
/// 读报告。表里的条目过时（场景已经能对拍了）就在这里失败，提醒把它删掉、让它回到对拍里。
#[test]
fn skips_are_exactly_the_listed_ones() {
    let dir = tempdir::new("g4skip");
    let out = dir.0.join("report.tsv");
    let mut cmd = std::process::Command::new(std::env::current_exe().unwrap());
    cmd.args(SKIPS.iter().map(|(test, ..)| *test))
        .args(["--exact", "--test-threads=1", "-q"])
        .env("FUSHI_GEN4_PARITY_REPORT", &out);
    let run = cmd.output().unwrap();
    assert!(
        run.status.success(),
        "the listed tests themselves failed: {}{}",
        String::from_utf8_lossy(&run.stdout),
        String::from_utf8_lossy(&run.stderr)
    );
    let ran = String::from_utf8_lossy(&run.stdout);
    assert!(
        ran.contains(&format!("ok. {} passed;", SKIPS.len())),
        "every listed test must exist and run: {ran}"
    );
    let report = std::fs::read_to_string(&out).unwrap_or_default();
    let lines: Vec<Vec<&str>> = report.lines().map(|l| l.split('\t').collect()).collect();
    for (test, blocker, _) in SKIPS {
        assert!(
            lines
                .iter()
                .any(|l| l[0].ends_with(test) && l[2] == "skip" && l[3] == *blocker),
            "{test} is listed in SKIPS but is no longer blocked by {blocker:?}: remove the entry\n{report}"
        );
    }
    let bad: Vec<&Vec<&str>> = lines
        .iter()
        .filter(|l| !matches!(l[2], "ok" | "skip" | "known"))
        .collect();
    assert!(bad.is_empty(), "{bad:?}");
}

/// `caches` 类的豁免必须写明协议 3 报的是哪一句错误：只按类别认的话，同一个场景里协议 3 一侧因任何别的原因失败
/// 都会被当成已知。
#[test]
fn known_caches_entries_name_their_error() {
    for k in KNOWN {
        assert!(
            k.what != "caches" || k.old.is_some(),
            "{} exempts caches without naming the expected error",
            k.test
        );
    }
    let name = "store::tests_v15_upgrade::a_real_v15_database_upgrades_row_for_row";
    let text = |t: &str| vec![t.to_owned()];
    assert!(known_entry(name, "caches", &text(NOTE_TYPE_MISSING), &[]).is_some());
    assert!(known_entry(name, "caches", &text("replay_pending: boom"), &[]).is_none());
    assert!(known_entry(name, "caches", &text(NOTE_TYPE_MISSING), &text("x")).is_none());
    let two = vec![NOTE_TYPE_MISSING.to_owned(), "other".to_owned()];
    assert!(known_entry(name, "caches", &two, &[]).is_none());
    assert!(
        known_entry(
            "store::other::test",
            "caches",
            &text(NOTE_TYPE_MISSING),
            &[]
        )
        .is_none()
    );
}

/// [KNOWN] 里的每一条现在仍然命中、而且这些场景没有别的差异：在一个子进程里只跑表里的测试（报告模式，见文件头），
/// 读报告。条目过时（场景已经对上了，或报的错误变了）就在这里失败，提醒删掉它、让场景回到对拍里。
#[test]
fn known_is_exactly_what_the_listed_tests_hit() {
    let mut keys = BTreeSet::new();
    for k in KNOWN {
        assert!(
            keys.insert((k.test, k.what)),
            "{} lists {} twice",
            k.test,
            k.what
        );
    }
    let tests: BTreeSet<&str> = KNOWN.iter().map(|k| k.test).collect();
    let dir = tempdir::new("g4known");
    let out = dir.0.join("report.tsv");
    let mut cmd = std::process::Command::new(std::env::current_exe().unwrap());
    cmd.args(tests.iter().copied())
        .args(["--exact", "--test-threads=1", "-q"])
        .env("FUSHI_GEN4_PARITY_REPORT", &out);
    let run = cmd.output().unwrap();
    assert!(
        run.status.success(),
        "the listed tests themselves failed: {}{}",
        String::from_utf8_lossy(&run.stdout),
        String::from_utf8_lossy(&run.stderr)
    );
    let ran = String::from_utf8_lossy(&run.stdout);
    assert!(
        ran.contains(&format!("ok. {} passed;", tests.len())),
        "every listed test must exist and run: {ran}"
    );
    let report = std::fs::read_to_string(&out).unwrap_or_default();
    let lines: Vec<Vec<&str>> = report.lines().map(|l| l.split('\t').collect()).collect();
    for k in KNOWN {
        assert!(
            lines.iter().any(|l| l[0].ends_with(k.test)
                && l[2] == "known"
                && l[3].split(' ').next() == Some(k.what)),
            "{} is listed in KNOWN for {} ({}) but no longer hits it: remove the entry\n{report}",
            k.test,
            k.what,
            k.why
        );
    }
    let bad: Vec<&Vec<&str>> = lines
        .iter()
        .filter(|l| !matches!(l[2], "ok" | "skip" | "known"))
        .collect();
    assert!(bad.is_empty(), "{bad:?}");
}

/// 真实样本库：`gen4_sample_index` 重建好的新代文件（`FUSHI_GEN4_OUT`），对「从空库逐条维护」出来的另一份
/// （`<OUT>.inc`，比完删掉）——一台设备一台设备地逐条落、每 4096 条收尾一次、信任状态最后才给。派生表逐表的行数与
/// 行摘要之和相同。
///
/// `FUSHI_GEN4_OUT=<gen4_sample_index 跑过的文件> cargo test --release --lib gen4_sample_incremental -- --ignored --nocapture`
#[test]
#[ignore]
fn gen4_sample_incremental() {
    let Ok(out) = std::env::var("FUSHI_GEN4_OUT") else {
        println!("FUSHI_GEN4_OUT not set");
        return;
    };
    let (ws0, _) = peak_mem_mb();
    println!("SAMPLE incremental start peak_working_set_mb {ws0:.0}");
    let dst = open(Path::new(&out)).unwrap();
    let t = Truth::new(&dst);
    let inc_path = format!("{out}.inc");
    let wipe = || {
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{inc_path}{suffix}"));
        }
    };
    wipe();
    {
        let inc = open(Path::new(&inc_path)).unwrap();
        let t2 = Truth::new(&inc);
        let cols: Vec<i64> = dst
            .prepare("SELECT col FROM collections ORDER BY col")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for col in cols {
            let b = t.binding(col).unwrap().unwrap();
            let source = collection_of(&b.profile);
            let col2 = t2
                .tx(|x| x.bind(&b.profile, &b.collection, &b.dir))
                .unwrap();
            let started = Instant::now();
            let mut n = 0u64;
            inc.execute_batch("BEGIN IMMEDIATE").unwrap();
            // 派生层的宿主输入照搬。别名表只有全量重算，灌的时候攒着、最后算一次。
            for key in ["caches"] {
                let value = t.derive_cfg(col, key).unwrap();
                t2.set_derive_cfg(col2, key, value.as_deref()).unwrap();
            }
            let mut ix = Index::new(&t2, col2);
            ix.hold_aliases(true);
            for d in t.devices(col).unwrap() {
                t.for_each(col, &d.id, 1, |e| {
                    match (e.slot(), e.op()) {
                        (Some(slot), _) => {
                            t2.put_heritage(col2, &source, &slot, e.tv)?;
                        }
                        // 探针写的那条原生 Salts 操作。
                        (None, Some(op)) => {
                            t2.append_native(col2, op)?;
                        }
                        (None, None) => return Err("a native void in the sample".to_owned()),
                    }
                    if let Some(now) = t2.entry(col2, &e.id)? {
                        ix.add(&now)?;
                    }
                    n += 1;
                    if n % 4096 == 0 {
                        ix.settle()?;
                    }
                    if n % 65536 == 0 {
                        inc.execute_batch("COMMIT; BEGIN IMMEDIATE")
                            .map_err(|e| e.to_string())?;
                    }
                    Ok(())
                })
                .unwrap();
            }
            ix.settle().unwrap();
            for (device, state) in t.untrusted(col).unwrap() {
                t2.set_trust(col2, &device, Some(state), 0).unwrap();
            }
            ix.trust_changed();
            ix.settle().unwrap();
            let held_s = started.elapsed().as_secs_f64();
            ix.hold_aliases(false);
            let last = ix.settle().unwrap();
            inc.execute_batch("COMMIT").unwrap();
            let maintain_s = started.elapsed().as_secs_f64();
            println!(
                "SAMPLE incremental alias_rows {} alias_s {:.1}",
                last.aliases,
                maintain_s - held_s
            );
            let (ws1, _) = peak_mem_mb();
            println!(
                "SAMPLE incremental profile {} ops {n} maintain_s {maintain_s:.1} peak_working_set_mb {ws1:.0}",
                b.profile
            );
            let started = Instant::now();
            let (rebuilt, maintained) = (digest(&t, col), digest(&t2, col2));
            for ((table, rows_a, sum_a), (_, rows_b, sum_b)) in rebuilt.iter().zip(&maintained) {
                println!(
                    "SAMPLE incremental table {table} rebuilt_rows {rows_a} maintained_rows {rows_b} same {}",
                    rows_a == rows_b && sum_a == sum_b
                );
            }
            println!(
                "SAMPLE incremental compare_s {:.1} identical {}",
                started.elapsed().as_secs_f64(),
                rebuilt == maintained
            );
            assert_eq!(
                rebuilt, maintained,
                "incremental maintenance differs from rebuild_all"
            );
        }
    }
    wipe();
    let (ws2, _) = peak_mem_mb();
    println!("SAMPLE incremental end peak_working_set_mb {ws2:.0}");
}
