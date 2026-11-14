//! 本机状态行（`srs_local_state.json`，每个 profile 一行）：**只有内核写**（收掉 Dart 写路径第 12 步）。
//!
//! 这一行以前有两个写入方：Dart `_saveLocal` 按内存字段整行重写，改投影的命令把 Dart 内存里的整行（`localState`）交给
//! 内核在命令的事务里写；为了不让 Dart 的整行重写抹掉内核自己的键，两边共用一个合并协议（内核持有的键白名单 + SQL
//! 函数 `srs_local_state_merge`）。现在 Dart 不再写这一行、命令也不再带它：
//!
//! - 修订号 `revision`：改投影的命令在自己的 SAVEPOINT 里按**库里的值**推进（[persist_projected]），回包 `localRevision`；
//!   收段通道在别的命令之前自己做完的片没有回包，同样在那一片的 SAVEPOINT 里推进（[advance_revision]）；
//! - 纪元 `epoch`：行第一次写下时由内核生成（[new_epoch]），回包 `localEpoch`；
//! - 存量样式去重的游标 `styleCursor`：`edits_rewrite_repr` 推进、`rebuild_caches {resetStyles}` 归零；
//! - 校时状态 `anchor`：Dart 进程时钟的快照（「可信时间 − 墙钟」每次现算，内核算不出来），随改投影的命令交来（同
//!   `now`）、或经 `local_anchor` 单独交来，内核写下；请求没带就不动；
//! - 其余键各有各的模块：缓存推导口径版本 `cacheRev`（store/cache_rev.rs）、旧版时钟 / 写入者与冻结键
//!   （store/legacy_clock.rs）、媒体回收的待回收集合 `mediaGc`（store/media_gc.rs）。它们用 `json_set` 只改自己的键；
//!   行还不存在时经 [ensure_row] 建。
//!
//! 行的键名与形态没有变（旧版本读得懂；旧版本的整行重写走它自己那份内核的合并函数）。读：Dart 开库 / 重读时发
//! `local_state`（[read]，只读、不建行）；开库在缓存重建之后发一次 `local_state_ensure`（[ensure]）把行与纪元落下——
//! 「有事件却没有这一行」是 Dart 判「刚覆盖恢复了备份、缓存要重建」的依据，所以行不能建在重建之前。

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value, json};

use super::sync2::sql;

const REVISION_KEY: &str = "revision";
const EPOCH_KEY: &str = "epoch";
const ANCHOR_KEY: &str = "anchor";
/// 存量样式去重的进度：`srs_field_edits` 里已检查到的 rowid（store/repr_rewrite.rs）。
pub(crate) const STYLE_CURSOR_KEY: &str = "styleCursor";

/// 一个新纪元：本机状态行被清空重建（覆盖恢复、删 profile 后重来）后换一个，修订号从 0 重数也不会撞上旧指纹。只当
/// 不透明串用（Dart 把它拼进 `纪元:修订号` 这样的指纹）：十六进制，不含分隔符。
fn new_epoch() -> String {
    let mut b = [0u8; 10];
    getrandom::fill(&mut b).expect("system random source");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// 新行的内容：缓存推导口径取当前版本（还没有这一行 = 新设备或覆盖恢复之后，缓存要么还没有、要么随即整份重建，
/// store/cache_rev.rs）+ 一个新纪元。
fn fresh() -> Map<String, Value> {
    let mut row = Map::new();
    row.insert(
        super::cache_rev::KEY.to_owned(),
        Value::from(super::cache_rev::CACHE_REVISION),
    );
    row.insert(EPOCH_KEY.to_owned(), Value::from(new_epoch()));
    row
}

/// [profile] 的行：没有 → None；损坏（不是 JSON 对象）→ 空对象（没有 `cacheRev` = 版本 0，下次开库整库补算）。
fn stored(c: &Connection, profile: &str) -> Result<Option<Map<String, Value>>, String> {
    let raw: Option<String> = c
        .prepare_cached("SELECT json FROM srs_local_state WHERE profile_uid = srs_id(?1)")
        .map_err(sql)?
        .query_row([profile], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    Ok(raw.map(|j| match serde_json::from_str::<Value>(&j) {
        Ok(Value::Object(m)) => m,
        _ => Map::new(),
    }))
}

fn has_epoch(row: &Map<String, Value>) -> bool {
    row.get(EPOCH_KEY).is_some_and(Value::is_string)
}

/// 行还不存在就建一行（[fresh]）；已有的不动。只改自己那个键的模块在 `json_set` 之前调。
pub(crate) fn ensure_row(c: &Connection, profile: &str) -> Result<(), String> {
    c.prepare_cached(
        "INSERT OR IGNORE INTO srs_local_state (profile_uid, json) VALUES (srs_id(?1), ?2)",
    )
    .map_err(sql)?
    .execute(params![profile, Value::Object(fresh()).to_string()])
    .map_err(sql)?;
    Ok(())
}

/// 读改写整行（调用方的写连接、调用方的 SAVEPOINT 里）：没有行从 [fresh] 起，有行没纪元补一个，再过 [f]，写回。
/// 返回写下的行。
fn edit(
    c: &Connection,
    profile: &str,
    f: impl FnOnce(&mut Map<String, Value>),
) -> Result<Map<String, Value>, String> {
    let mut row = stored(c, profile)?.unwrap_or_else(fresh);
    if !has_epoch(&row) {
        row.insert(EPOCH_KEY.to_owned(), Value::from(new_epoch()));
    }
    f(&mut row);
    c.prepare_cached(
        "INSERT INTO srs_local_state (profile_uid, json) VALUES (srs_id(?1), ?2) \
         ON CONFLICT(profile_uid) DO UPDATE SET json = excluded.json",
    )
    .map_err(sql)?
    .execute(params![profile, Value::Object(row.clone()).to_string()])
    .map_err(sql)?;
    Ok(row)
}

/// 请求里的校时状态（`anchor: {o, b, s?, t?}`：o = 可信时间 − 墙钟，b = 写下它的进程，s / t = 校时那一刻的服务器
/// 时间与开机时钟读数；fushi_srs `SrsTrustedClock.anchorState`）。没带 → None；形态不对报错（不写下 Dart 读不懂的值）。
pub(crate) fn anchor_of(req: &Value) -> Result<Option<Value>, String> {
    let a = match req.get(ANCHOR_KEY) {
        None | Some(Value::Null) => return Ok(None),
        Some(a) => a,
    };
    let bad = || format!("srs local state: bad anchor {a}");
    let obj = a.as_object().ok_or_else(bad)?;
    let mut out = Map::new();
    out.insert(
        "o".to_owned(),
        Value::from(obj.get("o").and_then(Value::as_i64).ok_or_else(bad)?),
    );
    out.insert(
        "b".to_owned(),
        Value::from(obj.get("b").and_then(Value::as_str).ok_or_else(bad)?),
    );
    for k in ["s", "t"] {
        match obj.get(k) {
            None | Some(Value::Null) => {}
            Some(v) => {
                out.insert(k.to_owned(), Value::from(v.as_i64().ok_or_else(bad)?));
            }
        }
    }
    Ok(Some(Value::Object(out)))
}

/// 一次改投影的命令在**同一笔事务**里推进并写下本机状态行（本机写命令与收段的每一片共用）。
///
/// 修订号按 [result] 推进：每条落进投影的事件（`marks.landed`）、每个可见性变了的实体（`changed` 里每个 `[kind, id]`，
/// kind 是认得的实体类别）各 +1，从**库里的值**起算——不再信调用方内存里的那份（以前 Dart 交来的整行落后于库时会把
/// 修订号写回去）。[anchor]（[anchor_of]）给了就一并写下；[patch] 给命令自己要改的键（`edits_rewrite_repr` 的游标）。
/// 写下的修订号与纪元放进结果的 `localRevision` / `localEpoch`（Dart 以它们为准）。
pub(crate) fn persist_projected_with(
    c: &Connection,
    profile: &str,
    anchor: Option<&Value>,
    result: &mut Value,
    patch: impl FnOnce(&mut Map<String, Value>),
) -> Result<(), String> {
    let landed = result["marks"]["landed"].as_i64().unwrap_or(0);
    let changed = result["changed"].as_array().map_or(0, |a| {
        a.iter()
            .filter(|x| {
                x.as_array().is_some_and(|p| {
                    p.len() == 2
                        && p[0]
                            .as_str()
                            .and_then(crate::sync2::op::EntKind::parse)
                            .is_some()
                })
            })
            .count() as i64
    });
    let row = edit(c, profile, |row| {
        let revision = row.get(REVISION_KEY).and_then(Value::as_i64).unwrap_or(0);
        row.insert(
            REVISION_KEY.to_owned(),
            Value::from(revision + landed + changed),
        );
        if let Some(a) = anchor {
            row.insert(ANCHOR_KEY.to_owned(), a.clone());
        }
        patch(row);
    })?;
    if let Some(m) = result.as_object_mut() {
        m.insert("localRevision".to_owned(), row[REVISION_KEY].clone());
        m.insert("localEpoch".to_owned(), row[EPOCH_KEY].clone());
    }
    Ok(())
}

/// 没有回包可带的投影变化（收段通道在别的命令之前自己做完的片，sync2/channel.rs `settle`）：修订号同样从库里的
/// 值推进，口径同 [persist_projected_with]（每条落进投影的事件、每个可见性变了的实体各 +1）。什么都没落就不写。
pub(crate) fn advance_revision(
    c: &Connection,
    profile: &str,
    t: &super::sync2::Touched,
) -> Result<(), String> {
    let changed = t
        .entities_changed
        .iter()
        .filter(|(k, _)| crate::sync2::op::EntKind::parse(k).is_some())
        .count() as i64;
    let by = t.marks.landed as i64 + changed;
    if by == 0 {
        return Ok(());
    }
    edit(c, profile, |row| {
        let revision = row.get(REVISION_KEY).and_then(Value::as_i64).unwrap_or(0);
        row.insert(REVISION_KEY.to_owned(), Value::from(revision + by));
    })?;
    Ok(())
}

/// [persist_projected_with]，没有命令自己的键要改。
pub(crate) fn persist_projected(
    c: &Connection,
    profile: &str,
    anchor: Option<&Value>,
    result: &mut Value,
) -> Result<(), String> {
    persist_projected_with(c, profile, anchor, result, |_| {})
}

fn view(row: Option<&Map<String, Value>>) -> Value {
    let int = |k: &str| {
        row.and_then(|r| r.get(k))
            .and_then(Value::as_i64)
            .unwrap_or(0)
    };
    let epoch = row.filter(|r| has_epoch(r)).map(|r| r[EPOCH_KEY].clone());
    json!({
        "exists": row.is_some(),
        "revision": int(REVISION_KEY),
        "styleCursor": int(STYLE_CURSOR_KEY),
        "epochStored": epoch.is_some(),
        // 没有行 / 老行没纪元：给一个没落盘的新纪元（每次重读都换，同以前 Dart 现生成的）。
        "epoch": epoch.unwrap_or_else(|| Value::from(new_epoch())),
        "anchor": row.and_then(|r| r.get(ANCHOR_KEY)).cloned().unwrap_or(Value::Null),
    })
}

/// `local_state`：Dart 开库 / 重读时要的那几个值（`{exists, revision, styleCursor, epoch, epochStored, anchor}`）。
/// 只读，不建行、不补纪元。
pub(crate) fn read(c: &Connection, profile: &str) -> Result<Value, String> {
    Ok(view(stored(c, profile)?.as_ref()))
}

/// `local_state_ensure`：没有行就建、没有纪元就补，再回同 [read] 的形态（`exists` = 调用前有没有行）。
pub(crate) fn ensure(c: &Connection, profile: &str) -> Result<Value, String> {
    let existed = stored(c, profile)?.is_some();
    let row = edit(c, profile, |_| {})?;
    let mut out = view(Some(&row));
    out["exists"] = Value::from(existed);
    Ok(out)
}

/// `local_anchor`：写下校时状态（没有行就建）。
pub(crate) fn set_anchor(c: &Connection, profile: &str, anchor: &Value) -> Result<(), String> {
    edit(c, profile, |row| {
        row.insert(ANCHOR_KEY.to_owned(), anchor.clone());
    })?;
    Ok(())
}

/// 存量样式去重从头再查（`rebuild_caches {resetStyles}`：覆盖恢复 / 采用别处的 profile 之后，恢复进来的行可能还是
/// 内联样式）。还没有行就不写（新行没有游标 = 0）。
pub(crate) fn reset_style_cursor(c: &Connection, profile: &str) -> Result<(), String> {
    c.prepare_cached(
        "UPDATE srs_local_state SET json = json_remove(json, '$.styleCursor') \
         WHERE profile_uid = srs_id(?1) AND json_valid(json)",
    )
    .map_err(sql)?
    .execute([profile])
    .map_err(sql)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::SrsCore;
    use crate::store::sync2::tests::{P, tempdir};

    fn open(tag: &str) -> (SrsCore, tempdir::Dir) {
        let dir = tempdir::new(tag);
        let core = SrsCore::open(&dir.0.join("srs.db")).unwrap();
        (core, dir)
    }

    fn raw(core: &SrsCore) -> Option<String> {
        let w = core.writer().unwrap();
        w.query_row(
            "SELECT json FROM srs_local_state WHERE profile_uid = srs_id(?1)",
            [P],
            |r| r.get(0),
        )
        .optional()
        .unwrap()
    }

    fn row(core: &SrsCore) -> Value {
        serde_json::from_str(&raw(core).expect("row")).unwrap()
    }

    fn put(core: &SrsCore, json: &str) {
        let w = core.writer().unwrap();
        w.execute(
            "INSERT OR REPLACE INTO srs_local_state (profile_uid, json) VALUES (srs_id(?1), ?2)",
            params![P, json],
        )
        .unwrap();
    }

    fn projected(landed: i64, changed: Value) -> Value {
        json!({"marks": {"landed": landed}, "changed": changed})
    }

    /// 读不建行：没有行时每次给一个没落盘的新纪元；`ensure` 才建行，之后纪元稳定。
    #[test]
    fn read_never_creates_the_row_and_ensure_does() {
        let (core, _d) = open("ls-read");
        let w = core.writer().unwrap();
        let a = read(&w, P).unwrap();
        let b = read(&w, P).unwrap();
        assert_eq!(a["exists"], json!(false));
        assert_eq!(a["epochStored"], json!(false));
        assert_eq!(a["revision"], json!(0));
        assert_eq!(a["styleCursor"], json!(0));
        assert_eq!(a["anchor"], Value::Null);
        assert_ne!(a["epoch"], b["epoch"], "an unstored epoch is new each read");
        drop(w);
        assert_eq!(raw(&core), None);

        let w = core.writer().unwrap();
        let e = ensure(&w, P).unwrap();
        assert_eq!(e["exists"], json!(false), "it did not exist before");
        assert_eq!(e["epochStored"], json!(true));
        let again = ensure(&w, P).unwrap();
        assert_eq!(again["exists"], json!(true));
        assert_eq!(again["epoch"], e["epoch"]);
        assert_eq!(read(&w, P).unwrap()["epoch"], e["epoch"]);
        drop(w);
        let stored = row(&core);
        assert_eq!(stored["epoch"], e["epoch"]);
        assert_eq!(
            stored["cacheRev"],
            json!(crate::store::cache_rev::CACHE_REVISION),
            "a new row starts at the current cache revision"
        );
        let epoch = e["epoch"].as_str().unwrap();
        assert_eq!(epoch.len(), 20);
        assert!(epoch.bytes().all(|b| b.is_ascii_hexdigit()));
    }

    /// 老行没有纪元：读时给没落盘的，`ensure` 补上、别的键原样；损坏的行当空对象重建（没有 `cacheRev` = 整库补算）。
    #[test]
    fn ensure_fills_the_epoch_of_an_old_row_and_repairs_a_corrupt_one() {
        let (core, _d) = open("ls-old");
        put(
            &core,
            r#"{"revision":7,"styleCursor":3,"cacheRev":5,"hlc":"1:2:w","future":{"x":1}}"#,
        );
        let w = core.writer().unwrap();
        let r = read(&w, P).unwrap();
        assert_eq!(r["exists"], json!(true));
        assert_eq!(r["epochStored"], json!(false));
        assert_eq!(r["revision"], json!(7));
        assert_eq!(r["styleCursor"], json!(3));
        let e = ensure(&w, P).unwrap();
        assert_eq!(e["exists"], json!(true));
        assert_eq!(e["epochStored"], json!(true));
        drop(w);
        let mut stored = row(&core);
        assert_eq!(stored["epoch"], e["epoch"]);
        stored.as_object_mut().unwrap().remove("epoch");
        assert_eq!(
            stored,
            json!({"revision": 7, "styleCursor": 3, "cacheRev": 5, "hlc": "1:2:w", "future": {"x": 1}}),
            "every other key survives, including ones this version does not know"
        );

        put(&core, "not json");
        let w = core.writer().unwrap();
        assert_eq!(read(&w, P).unwrap()["revision"], json!(0));
        ensure(&w, P).unwrap();
        drop(w);
        let stored = row(&core);
        assert!(stored["epoch"].is_string());
        assert!(stored.get("cacheRev").is_none(), "{stored}");
    }

    /// 修订号从库里的值起算、连续两次累加；认不得的 `changed` 项不计；回包带写下的修订号与纪元；别的键不动。
    #[test]
    fn persist_projected_advances_the_stored_revision() {
        let (core, _d) = open("ls-persist");
        let w = core.writer().unwrap();
        let mut r = projected(2, json!([["note", "N"], ["bogus", "X"], ["card"]]));
        persist_projected(&w, P, None, &mut r).unwrap();
        assert_eq!(r["localRevision"], json!(3));
        let epoch = r["localEpoch"].clone();
        assert!(epoch.is_string());
        w.execute(
            "UPDATE srs_local_state SET json = json_set(json, '$.mediaGc', json('[\"a.png\"]'), '$.hlc', '9:9:w')",
            [],
        )
        .unwrap();
        let mut r = projected(1, json!([]));
        persist_projected(&w, P, None, &mut r).unwrap();
        assert_eq!(r["localRevision"], json!(4));
        assert_eq!(r["localEpoch"], epoch);
        // 没有投影变化：修订号不动，照样回当前值。
        let mut r = json!({});
        persist_projected(&w, P, None, &mut r).unwrap();
        assert_eq!(r["localRevision"], json!(4));
        drop(w);
        let stored = row(&core);
        assert_eq!(stored["revision"], json!(4));
        assert_eq!(stored["mediaGc"], json!(["a.png"]));
        assert_eq!(stored["hlc"], json!("9:9:w"));
    }

    /// 校时状态：请求带了就写下、没带不动；形态不对报错；`local_anchor` 单独写。
    #[test]
    fn the_anchor_is_written_when_given_and_kept_otherwise() {
        let (core, _d) = open("ls-anchor");
        let w = core.writer().unwrap();
        let a = anchor_of(&json!({"anchor": {"o": -5, "b": "boot", "s": 10, "t": 20, "x": 1}}))
            .unwrap()
            .unwrap();
        assert_eq!(a, json!({"o": -5, "b": "boot", "s": 10, "t": 20}));
        let mut r = projected(1, json!([]));
        persist_projected(&w, P, Some(&a), &mut r).unwrap();
        assert_eq!(read(&w, P).unwrap()["anchor"], a);
        let mut r = projected(1, json!([]));
        persist_projected(&w, P, None, &mut r).unwrap();
        assert_eq!(read(&w, P).unwrap()["anchor"], a, "kept when not given");

        let carried = anchor_of(&json!({"anchor": {"o": 3, "b": "other", "s": null}}))
            .unwrap()
            .unwrap();
        assert_eq!(carried, json!({"o": 3, "b": "other"}));
        set_anchor(&w, P, &carried).unwrap();
        assert_eq!(read(&w, P).unwrap()["anchor"], carried);
        assert_eq!(read(&w, P).unwrap()["revision"], json!(2));

        assert_eq!(anchor_of(&json!({})).unwrap(), None);
        assert_eq!(anchor_of(&json!({"anchor": null})).unwrap(), None);
        for bad in [
            json!({"anchor": 1}),
            json!({"anchor": {"b": "x"}}),
            json!({"anchor": {"o": 1}}),
            json!({"anchor": {"o": "1", "b": "x"}}),
            json!({"anchor": {"o": 1, "b": "x", "s": "2"}}),
        ] {
            assert!(anchor_of(&bad).unwrap_err().contains("bad anchor"), "{bad}");
        }
    }

    /// 命令自己的键（去重游标）与修订号同一次写下；归零只动游标，没有行不建。
    #[test]
    fn the_style_cursor_moves_with_the_command_and_resets() {
        let (core, _d) = open("ls-cursor");
        let w = core.writer().unwrap();
        reset_style_cursor(&w, P).unwrap();
        assert_eq!(read(&w, P).unwrap()["exists"], json!(false));
        let mut r = json!({});
        persist_projected_with(&w, P, None, &mut r, |row| {
            row.insert(STYLE_CURSOR_KEY.to_owned(), Value::from(42));
        })
        .unwrap();
        let before = read(&w, P).unwrap();
        assert_eq!(before["styleCursor"], json!(42));
        reset_style_cursor(&w, P).unwrap();
        let after = read(&w, P).unwrap();
        assert_eq!(after["styleCursor"], json!(0));
        assert_eq!(after["epoch"], before["epoch"]);
        assert_eq!(after["revision"], before["revision"]);
    }

    /// 只改自己那个键的模块先 `ensure_row`：新行带当前缓存版本与纪元，已有的行不动。
    #[test]
    fn ensure_row_creates_once() {
        let (core, _d) = open("ls-row");
        let w = core.writer().unwrap();
        ensure_row(&w, P).unwrap();
        let first = read(&w, P).unwrap();
        assert_eq!(first["epochStored"], json!(true));
        ensure_row(&w, P).unwrap();
        assert_eq!(read(&w, P).unwrap(), first);
    }
}
