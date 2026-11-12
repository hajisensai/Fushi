//! 测试装置：协议 3 的投影，对同一份库灌进新存储之后的派生层（设计 §8 G6 行「现有内核行为测试在新存储上全绿」）。
//!
//! [check_core] 挂在协议 3 内核 `SrsCore` 的析构上（只在测试构建里）：每个场景里每个库关掉之前，把它灌进一个内存里的
//! 新代库，查三件事——
//!
//! 1. `rebuild_all` 再做一遍，派生表逐行不变；
//! 2. 换一种到达方式（一台设备一台设备地逐条落、逐条维护，信任状态最后才给），派生表与重建出来的逐行相同；
//! 3. 与协议 3 的投影对拍（[against_protocol_3]）没有差异。
//!
//! 库还没做完换代前必须做完的事（旧行没包成操作、去重作业没跑完）时，在一份拷贝上把它们做完再对拍；做不完的
//! （新设备收段通道还开着）跳过。与协议 3 有意不同的场景列在 [KNOWN]，逐条写原因。
//! 设了环境变量 `FUSHI_GEN4_PARITY_REPORT=<文件>` 时不让测试失败，改成把每个场景的结果追加进那个文件（盘点用）。

use std::cell::Cell;
use std::collections::BTreeSet;
use std::io::Write as _;
use std::path::Path;
use std::time::Instant;

use rusqlite::{Connection, ToSql, params};

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
use crate::store::sync2::semantics::current_tags;
use crate::store::sync2::tests::{Device, P, tempdir};
use crate::sync2::id::Id;
use crate::sync2::vv::OpId;

/// 有差异的类别：(类别, 只在旧库, 只在新库)。空 = 完全一致。
pub(crate) type Diff = Vec<(&'static str, Vec<String>, Vec<String>)>;

/// 对不上、而且不该对上的场景：(测试名的结尾, 类别——[against_protocol_3] 的类别或 `error`, 原因)。两条都是测试
/// 手改了协议 3 的日志表、库自己已经不自洽。
const KNOWN: &[(&str, &str, &str)] = &[
    (
        "legacy::tests::a_duplicate_skeleton_in_the_log_becomes_an_alias",
        "edits",
        "the test rewrites one sync2_ops row into a duplicate skeleton by hand (not through dedup::apply), so the \
         protocol 3 projection still holds the edit its own log no longer has",
    ),
    (
        "tests_footprint::upgrading_from_before_v16_adds_the_snapshot_columns_before_reading_ops",
        "error",
        "the test drops sync2_ops.sc / sc_at by hand: the ops whose payload was packed against a config snapshot \
         lose the reference, so their bytes no longer hash to the stored chain (the reader refuses them)",
    ),
];

fn op_text(id: &OpId) -> String {
    format!("{}:{}", id.device.text(), id.seq)
}

/// 索引里没被支配、也没被扣住 / 清除的写入的修改记录 ID（协议 3 的 `srs_field_edits.id`：由 dot 决定）。[skip] 里的
/// 实体（`种类:ID`）的 `deleted` 寄存器不算。
fn live_edit_ids(t: &Truth<'_>, col: i64, skip: &BTreeSet<String>) -> BTreeSet<String> {
    let mut stmt = t
        .conn()
        .prepare("SELECT k FROM reg_ix WHERE col = ?1 AND state >= ?2")
        .unwrap();
    let ks: Vec<i64> = stmt
        .query_map(params![col, R_LIVE], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    ks.into_iter()
        .filter_map(|k| {
            let e = t.entry_by_key(k).unwrap().unwrap();
            let Some(Body4::Edit(ed)) = body_of(&e) else {
                panic!("register row {k} is not an edit")
            };
            if ed.key == "deleted"
                && skip.contains(&format!(
                    "{}:{}",
                    ed.kind.wire(),
                    Ref::of(&ed.entity).text()
                ))
            {
                return None;
            }
            Some(match &ed.stamp {
                Some(s) => crate::registers::edit_id(&s.writer, s.seq),
                None => crate::registers::edit_id(&e.id.device.text(), e.id.seq as i64),
            })
        })
        .collect()
}

fn texts(conn: &Connection, sql: &str, args: &[&dyn ToSql]) -> BTreeSet<String> {
    conn.prepare(sql)
        .unwrap()
        .query_map(args, |r| r.get::<_, String>(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn ops(conn: &Connection, table: &str, profile: &str) -> BTreeSet<String> {
    // 这张表比库新（真实样本是加这个功能之前的 schema）：那时没有这类行。
    let exists = conn
        .prepare("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?1")
        .unwrap()
        .exists([table])
        .unwrap();
    if !exists {
        return BTreeSet::new();
    }
    conn.prepare(&format!(
        "SELECT device, seq FROM {table} WHERE profile_uid = srs_id(?1)"
    ))
    .unwrap()
    .query_map([profile], |r| {
        Ok((r.get::<_, [u8; 16]>(0)?, r.get::<_, i64>(1)?))
    })
    .unwrap()
    .map(|r| {
        let (d, s) = r.unwrap();
        op_text(&OpId {
            device: Id(d),
            seq: s as u64,
        })
    })
    .collect()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02X}")).collect()
}

/// 协议 3 的投影，与同一份库灌进新存储、重建之后的派生层比。类别：活着的修改记录 ID（`edits`，不算合成的标签行）、
/// 日志 ID（`logs`）、实体 ID（`entities`）、每条笔记现在的标签与顺序（`tags`）、媒体名绑定的内容（`media`）、
/// 被并发改动扣住的删除（`held`）、因设备不可信没执行的删除与清除（`distrusted`）、清除过的实体（`purged`）。
pub(crate) fn against_protocol_3(src: &Connection, profile: &str, t: &Truth<'_>, col: i64) -> Diff {
    let ix = Index::new(t, col);
    let refs = |sql: &str| -> BTreeSet<String> {
        t.conn()
            .prepare(sql)
            .unwrap()
            .query_map([col], |r| r.get::<_, Ref>(0))
            .unwrap()
            .map(|r| r.unwrap().text())
            .collect()
    };
    let old_tags: BTreeSet<String> = texts(
        src,
        "SELECT DISTINCT srs_idt(note) FROM sync2_tag_adds WHERE profile_uid = srs_id(?1)",
        &[&profile],
    )
    .into_iter()
    .filter_map(|n| {
        let tags = current_tags(src, profile, &n).unwrap();
        (!tags.is_empty()).then(|| format!("{n}={tags:?}"))
    })
    .collect();
    let new_tags: BTreeSet<String> = ix
        .tagged_notes()
        .unwrap()
        .into_iter()
        .filter_map(|n| {
            let tags = ix.tags_of(&crate::sync2::id::Key::of(&n.text())).unwrap();
            (!tags.is_empty()).then(|| format!("{}={tags:?}", n.text()))
        })
        .collect();
    // 协议 3 在两处依赖到达顺序 / 留着骨架（`weigh.rs` 文件头「与协议 3 的差别」），这两处按下面的口径比：
    // - 有删除被扣住的实体（任一边）：`deleted` 寄存器里留着哪几条修改记录不比（协议 3 取决于被扣住的那条删除
    //   到的时候落没落过投影），只比扣住的集合；
    // - 清除过的实体：扣住的集合不比（协议 3 把已清除操作的骨架也算作「并发的操作」）。
    let new_holds = ix.holds().unwrap();
    let old_held_ents: Vec<(String, String)> = src
        .prepare(
            "SELECT srs_idt(device) || ':' || seq, kind || ':' || srs_idt(entity) FROM sync2_held \
             WHERE profile_uid = srs_id(?1)",
        )
        .unwrap()
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let new_held_ents: Vec<(String, String)> = new_holds
        .iter()
        .map(|h| {
            (
                op_text(&h.op),
                format!("{}:{}", h.kind.wire(), h.entity.text()),
            )
        })
        .collect();
    let held_ents: BTreeSet<String> = old_held_ents
        .iter()
        .chain(&new_held_ents)
        .map(|(_, ent)| ent.clone())
        .collect();
    let old_purged = texts(
        src,
        "SELECT kind || ':' || srs_idt(entity) FROM sync2_purged WHERE profile_uid = srs_id(?1)",
        &[&profile],
    );
    let new_purged: BTreeSet<String> = ix
        .purged_entities()
        .unwrap()
        .into_iter()
        .map(|(k, e)| format!("{}:{}", k.wire(), e.text()))
        .collect();
    let on_unpurged = |held: &[(String, String)]| -> BTreeSet<String> {
        held.iter()
            .filter(|(_, ent)| !old_purged.contains(ent) && !new_purged.contains(ent))
            .map(|(op, _)| op.clone())
            .collect()
    };
    let old_edits: BTreeSet<String> = src
        .prepare(
            "SELECT srs_idt(id), entity_kind || ':' || srs_idt(entity_id), field_key FROM srs_field_edits \
             WHERE profile_uid = srs_id(?1) AND writer_id NOT LIKE 'sync2:%'",
        )
        .unwrap()
        .query_map([profile], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })
        .unwrap()
        .map(Result::unwrap)
        .filter(|(_, ent, key)| !(key == "deleted" && held_ents.contains(ent)))
        .map(|(id, ..)| id)
        .collect();
    let pairs: Vec<(&'static str, BTreeSet<String>, BTreeSet<String>)> = vec![
        ("edits", old_edits, live_edit_ids(t, col, &held_ents)),
        (
            "logs",
            texts(
                src,
                "SELECT srs_idt(id) FROM srs_review_logs WHERE profile_uid = srs_id(?1)",
                &[&profile],
            ),
            refs("SELECT DISTINCT id FROM log_ix WHERE col = ?1"),
        ),
        (
            "entities",
            texts(
                src,
                "SELECT srs_idt(id) FROM srs_entities WHERE profile_uid = srs_id(?1)",
                &[&profile],
            ),
            refs("SELECT DISTINCT id FROM ent_ix WHERE col = ?1"),
        ),
        ("tags", old_tags, new_tags),
        (
            "media",
            texts(
                src,
                "SELECT name || '=' || hex(sha256) || ':' || size FROM sync2_media WHERE profile_uid = srs_id(?1)",
                &[&profile],
            ),
            ix.media()
                .unwrap()
                .into_iter()
                .map(|(name, sha, size)| format!("{name}={}:{size}", hex(&sha)))
                .collect(),
        ),
        (
            "held",
            on_unpurged(&old_held_ents),
            on_unpurged(&new_held_ents),
        ),
        (
            "distrusted",
            ops(src, "sync2_trust_held", profile),
            ix.distrusted().unwrap().iter().map(op_text).collect(),
        ),
        ("purged", old_purged.clone(), new_purged.clone()),
    ];
    pairs
        .into_iter()
        .filter(|(_, a, b)| a != b)
        .map(|(what, a, b)| {
            (
                what,
                a.difference(&b).cloned().collect(),
                b.difference(&a).cloned().collect(),
            )
        })
        .collect()
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
                    "SELECT entity_kind, srs_idt(entity_id), field_key, srs_idt(writer_id), seq, json FROM srs_field_edits                      WHERE profile_uid = srs_id(?1) AND srs_idt(id) = ?2",
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
    if let Err(e) = core.snapshot_into(&path, false) {
        report(&name, "-", "skip", &format!("cannot snapshot: {e}"));
        return;
    }
    let copy = match SrsCore::open(&path) {
        Ok(c) => c,
        Err(e) => {
            report(
                &name,
                "-",
                "skip",
                &format!("cannot reopen the snapshot: {e}"),
            );
            return;
        }
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64);
    for profile in &profiles {
        let _ = copy.sync2_identity(profile, now);
        for _ in 0..100_000 {
            match copy.sync2_migrate(profile, now, None) {
                Ok(v) if v["done"] != serde_json::json!(true) => {}
                _ => break,
            }
        }
        for _ in 0..100_000 {
            match copy.sync2_dedup(profile, now) {
                Ok(v) if v["done"] != serde_json::json!(true) => {}
                _ => break,
            }
        }
    }
    if let Ok(w) = copy.writer() {
        for profile in &profiles {
            check_profile(&name, &w, profile);
        }
    };
}

fn check_profile(name: &str, w: &Connection, profile: &str) {
    let blockers = legacy::preflight(w, profile).unwrap_or_else(|e| vec![e]);
    if !blockers.is_empty() {
        report(name, profile, "skip", &blockers.join("; "));
        return;
    }
    let outcome = imported_from(w, profile);
    let known = |what: &str| {
        KNOWN
            .iter()
            .any(|(test, kind, _)| name.ends_with(test) && *kind == what)
    };
    let problem = match &outcome {
        Err(e) if known("error") => {
            report(name, profile, "known", e);
            return;
        }
        Err(e) => Some(("error", e.clone())),
        Ok((_, diff)) => {
            let unknown: Vec<_> = diff.iter().filter(|(what, ..)| !known(what)).collect();
            if !diff.is_empty() && unknown.is_empty() {
                report(name, profile, "known", &format!("{diff:?}"));
                return;
            }
            (!unknown.is_empty()).then(|| {
                let conn = &outcome.as_ref().unwrap().0;
                (
                    "diff",
                    format!("{unknown:?} {}", explain(w, profile, conn, &unknown)),
                )
            })
        }
    };
    match problem {
        None => {
            report(name, profile, "ok", "");
        }
        Some((status, detail)) => {
            if !report(name, profile, status, &detail) {
                panic!("gen4 parity ({name}, profile {profile}): {status}: {detail}");
            }
        }
    }
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
            for key in ["builtins", "caches"] {
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
