//! 修改记录的表示层改写（收掉 Dart 写路径第 5 步，审查 M1）：存量样式去重（Dart `SrsDbStore.compactStoredStyles`）
//! 把笔记字段值里的内联 `<style>` 换成共享样式引用。去重算法与样式文件库仍在 Dart（`_compactEdit` 会写样式文件，
//! 样式文件随媒体同步）；内核只做落库这一半：`edits_rewrite_repr {rows: [[rowid, 规范编码], ...], cursor, localState}`
//! 在**一个** SAVEPOINT 里依次
//!
//! - 按 rowid 改写这些修改记录的瘦存 `jslim`（`json` 是生成列，srs.db v18，store/slim.rs；同 sync2/mod.rs 写
//!   `jslim` 的写法），只换表示、不改内容，所以不进操作日志、不推进修订号；
//! - 刷新改写过的笔记的缓存行（媒体引用跟着表示变），回包带 `cache`（Dart 的缓存变更日志要收它）；
//! - 写本机状态行：Dart 交来的 `localState` 里的去重游标 `styleCursor` 换成这一批的 [cursor]（游标与改写同进同退），
//!   修订号不变（store/local_state.rs `persist_projected`，回包带 `localRevision`）。
//!
//! 出错整个回滚：改写、缓存行、游标一起不落，Dart 下次从原游标重来。

use std::collections::BTreeSet;

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use super::caches::{self, CacheConfig, Dirty};
use super::sync2::sql;

/// 本机状态行里的去重游标键（Dart 持有的键：Dart 交整行，这里只换它）。
const CURSOR_KEY: &str = "styleCursor";

/// 解析请求的 `rows`：`[[rowid, 规范编码], ...]`。
fn parse_rows(req: &Value) -> Result<Vec<(i64, String)>, String> {
    let mut out = Vec::new();
    for r in req
        .get("rows")
        .and_then(Value::as_array)
        .ok_or("edits_rewrite_repr: missing rows")?
    {
        let (Some(rid), Some(canonical)) = (r[0].as_i64(), r[1].as_str()) else {
            return Err("edits_rewrite_repr: a row must be [rowid, canonical]".into());
        };
        out.push((rid, canonical.to_owned()));
    }
    Ok(out)
}

/// 改写 [rows]（本 profile 的笔记修改记录；rowid 已不在的跳过），返回改写过的笔记。
pub(crate) fn rewrite_on(
    c: &Connection,
    profile: &str,
    rows: &[(i64, String)],
) -> Result<BTreeSet<String>, String> {
    let mut stmt = c
        .prepare_cached(
            "UPDATE srs_field_edits SET jslim = srs_edit_pack(?1, id, profile_uid, entity_kind, \
             entity_id, field_key, writer_id, seq) \
             WHERE rowid = ?2 AND profile_uid = srs_id(?3) AND entity_kind = 'note' \
             RETURNING srs_idt(entity_id)",
        )
        .map_err(sql)?;
    let mut notes = BTreeSet::new();
    for (rid, canonical) in rows {
        if let Some(note) = stmt
            .query_row(params![canonical, rid, profile], |r| r.get::<_, String>(0))
            .optional()
            .map_err(sql)?
        {
            notes.insert(note);
        }
    }
    Ok(notes)
}

/// `edits_rewrite_repr` 命令（见模块文档），在调用方持着的写连接、开好的 SAVEPOINT 里做。
pub(crate) fn command_on(
    c: &Connection,
    profile: &str,
    req: &Value,
    cfg: &CacheConfig,
) -> Result<Value, String> {
    let rows = parse_rows(req)?;
    let cursor = req
        .get("cursor")
        .and_then(Value::as_i64)
        .ok_or("edits_rewrite_repr: missing cursor")?;
    let local = req
        .get("localState")
        .and_then(Value::as_str)
        .ok_or("edits_rewrite_repr: missing localState")?;
    let notes = rewrite_on(c, profile, &rows)?;
    let rewritten = notes.len();
    let written = caches::refresh(
        c,
        profile,
        cfg,
        Dirty {
            notes,
            ..Dirty::default()
        },
    )?;
    let mut state: Value =
        serde_json::from_str(local).map_err(|e| format!("srs local state: bad localState: {e}"))?;
    state
        .as_object_mut()
        .ok_or("srs local state: localState must be a JSON object")?
        .insert(CURSOR_KEY.to_owned(), Value::from(cursor));
    let mut v = json!({"rewritten": rows.len(), "notes": rewritten});
    crate::store::local_state::persist_projected(c, profile, &state.to_string(), &mut v, None)?;
    if let Some(m) = v.as_object_mut() {
        m.insert("cache".to_owned(), written.to_json());
    }
    Ok(v)
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use crate::store::sync2::tests::{Device, P, deck_entity, edit};

    const T0: i64 = 1_700_000_000_000;
    const NT: &str = "0193a1b2-0000-7000-8000-00000000e0a1";
    const NOTE: &str = "0193a1b2-0000-7000-8000-00000000e0b1";
    const STYLED: &str = "<style>.x{color:red}</style>word";

    fn caches() -> Value {
        json!({"defaultDeck": crate::store::sync2::config::default_deck_id(P)})
    }

    fn dispatch(d: &Device, req: Value, blob: Option<String>) -> Result<Value, String> {
        let mut blobs: Vec<Vec<u8>> = blob.into_iter().map(String::into_bytes).collect();
        let mut files = Vec::new();
        crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files)
    }

    fn add_note(d: &Device) {
        let deck = crate::store::sync2::config::default_deck_id(P);
        let events = [
            deck_entity(&deck),
            json!({"t": "entity", "x": {"id": NT, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            edit(
                "notetype",
                NT,
                "fieldDef/fa",
                json!({"name": "Front", "ord": 0}),
            ),
            edit(
                "notetype",
                NT,
                "tmplDef/t1",
                json!({"name": "C", "ord": 0, "front": "{{Front}}"}),
            ),
            json!({"t": "entity", "x": {"id": NOTE, "p": P, "k": "note", "d": {"createdAt": 1, "guid": NOTE, "noteTypeId": NT}}}),
            edit("note", NOTE, "f/fa", json!(STYLED)),
        ];
        let input = Value::Array(
            events
                .into_iter()
                .map(|e| json!({"e": e, "note": null}))
                .collect(),
        )
        .to_string();
        dispatch(
            d,
            json!({"op": "apply", "profile": P, "now": T0, "caches": caches(),
                   "localState": json!({"revision": 0, "styleCursor": 0}).to_string()}),
            Some(input),
        )
        .unwrap();
    }

    /// 这条笔记字段修改记录的 (rowid, 存储形态 json)。
    fn field_row(d: &Device) -> (i64, String) {
        let r = d.rows(&format!(
            "SELECT rowid AS rid, json FROM srs_field_edits WHERE entity_id = srs_id('{NOTE}') AND field_key = 'f/fa'"
        ));
        (r[1][0].parse().unwrap(), r[1][1].clone())
    }

    fn local(d: &Device) -> Value {
        serde_json::from_str(
            &d.rows(&format!(
                "SELECT json FROM srs_local_state WHERE profile_uid = srs_id('{P}')"
            ))[1][0],
        )
        .unwrap()
    }

    /// 改写表示、刷新这条笔记的缓存行、推进游标在一个 SAVEPOINT 里；修订号不动。中途出错（本机状态行坏了）三者都不落。
    #[test]
    fn rewrites_the_representation_refreshes_caches_and_advances_the_cursor_together() {
        let d = Device::new("repr-rewrite");
        add_note(&d);
        let (rid, stored) = field_row(&d);
        assert!(stored.contains("<style>"), "{stored}");
        let canonical = stored.replace("<style>.x{color:red}</style>", "");
        let before = local(&d);

        let bad = dispatch(
            &d,
            json!({"op": "edits_rewrite_repr", "profile": P, "caches": caches(),
                   "rows": [[rid, canonical]], "cursor": rid, "localState": "[1]"}),
            None,
        );
        assert!(bad.is_err());
        assert_eq!(field_row(&d).1, stored, "rewrite rolled back");
        assert_eq!(local(&d), before, "cursor not advanced");

        let mut state = before.clone();
        state["styleCursor"] = json!(0);
        let r = dispatch(
            &d,
            json!({"op": "edits_rewrite_repr", "profile": P, "caches": caches(),
                   "rows": [[rid, canonical], [rid + 100_000, "{}"]], "cursor": rid,
                   "localState": state.to_string()}),
            None,
        )
        .unwrap();
        assert_eq!(r["notes"], json!(1), "{r}");
        assert_eq!(r["cache"]["notes"], json!([NOTE]), "{r}");
        assert_eq!(r["localRevision"], before["revision"], "{r}");
        let (_, now) = field_row(&d);
        assert!(!now.contains("<style>") && now.contains("word"), "{now}");
        let after = local(&d);
        assert_eq!(after["styleCursor"], json!(rid));
        assert_eq!(after["revision"], before["revision"]);
    }
}
