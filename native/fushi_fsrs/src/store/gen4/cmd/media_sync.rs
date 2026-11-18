//! 媒体同步的命令层（G8-7b；交接说明「G8-7b 同步补全」一节）。协议 3 `store/sync2/media.rs` 的 `media_*` 六条命令的新代
//! 实现（协议 3 原有的第七条 `media_bind_unbound` 只给已删的协议 1 位置迁移用，两代都已删掉），加上新代才有的媒体清单收发（`media_manifests` / `media_manifest_ingest` / `media_manifest_build` /
//! `media_manifest_published`）。存储层全部复用：名字 → 内容的绑定是真相层的 `Media` 操作（派生在 `media_ix`，
//! `weigh.rs`），本机文件缓存是迁移照搬的 `media_local`，各位置「在不在」是 G8-3 的 `media_at` 与清单（`gen4/media.rs`）。
//!
//! # 命令（Dart `srs_media_sync.dart` 的调用顺序；回包形状与协议 3 逐键相同）
//!
//! | 命令 | 事务 | 做什么 |
//! |---|---|---|
//! | `media_hash {root, names}` | 读快照 + 锁外读文件 | 本机文件此刻的 (size, mtime, sha256)；`media_local` 里 (size, mtime) 没变的不重算 |
//! | `media_scan {names, files, now}` | `write` | 每个名字该做什么；需要的绑定（`Media` 操作）同一个事务里写 |
//! | `media_landed {root, items, now}` | `write` | 下载落地：记成与绑定对齐，没绑定的补绑 |
//! | `media_doomed {expired, live}` | 读 | 过期名字绑定、且不被存活名字绑定的内容 |
//! | `media_known {location}` | 读 | 一个媒体目录（`<位置>/<目录>#sha256`）的已知内容：`media_at` 与「列举过」 |
//! | `media_record {location, present, absent, suspect, seeded, now}` | `write_local` | 本机观察写进 `media_at`（待发），HLC 由本机时钟 tick |
//! | `media_manifests {location, listing}` | 读 | 位置上各设备的清单里还没收的（代号大于水位），按 (设备, 代号) 升序 |
//! | `media_manifest_ingest {location, paths, now}` + 块 | `write_local` | 逐份收清单；某设备一份收不了就停在它（水位只升不降） |
//! | `media_manifest_build {location, loc, ownGens}` | `write_local` | 本机待发的事实打成下一份清单（预留代号） |
//! | `media_manifest_published {location}` + 块 | `write_local` | 那份清单写上了：清待发标记、推进本机水位 |
//!
//! `media_scan` / `media_landed` 落真相（绑定操作），经 `cmd/writes.rs` 的 [write]（本机身份、
//! 规范 ID、派生层收尾）；它们**不推进本机修订号**（协议 3 同样不算改投影的命令：绑定不进 Dart 的任何缓存），所以走
//! `G4Core::write` 而不是本机写命令的事务。`media_record` 与清单命令只改本机状态（`media_at` / `media_seen` /
//! `media_listed` / `media_gen`、`self_.hlc`），走 `write_local`。
//!
//! # 绑定的读
//!
//! 一个名字此刻绑定的内容 = `media_ix` 里这个名字 `state = 胜者` 的那条操作的 `Media` 体（[BINDING_SQL]，主键前缀
//! `(col, name)` 点查；查询计划测试用同一份语句）。绑定是名字上的寄存器，与实体 ID 无关，不归一。
//!
//! # 时钟
//!
//! 观察的 HLC = 本机时钟（`self_.hlc`，[super::super::native] 文件头）tick 一下，写回 `self_.hlc`。收清单时把读进来的
//! 不超前的最大 HLC 吸收进本机时钟（`gen4/media.rs` 调用方契约）；超前的作者只报在 `ahead` 里。

use std::collections::{BTreeMap, BTreeSet, HashMap};

use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

use super::Files;
use super::writes::write;
use crate::gen4::location::{V4File, device_path, parse_v4_path};
use crate::gen4::manifest::{MediaState, open as open_manifest};
use crate::gen4::op::Body4;
use crate::store::gen4::derive::{R_WINNER, body_of};
use crate::store::gen4::media::{self, parse_key};
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::Truth;
use crate::sync2::hlc::{Clock, Hlc};
use crate::sync2::id::Id;
use crate::sync2::op::Body;

/// 一个媒体名字此刻绑定的那条操作（`media_ix` 主键前缀 `(col, name)` 点查，胜者唯一）。
pub(crate) const BINDING_SQL: &str =
    "SELECT k FROM media_ix WHERE col = ?1 AND name = ?2 AND state = ?3";

/// 本机记的一个媒体文件（`media_local` 主键点查）。
pub(crate) const LOCAL_SQL: &str =
    "SELECT size, mtime, sha256, synced FROM media_local WHERE col = ?1 AND name = ?2";

/// 本机记的一个媒体文件：(size, mtime, 内容, 上次与绑定对齐时的内容)。
pub type LocalRow = (i64, i64, [u8; 32], Option<[u8; 32]>);

pub(super) fn hex32(b: &[u8; 32]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub(super) fn unhex32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, o) in out.iter_mut().enumerate() {
        *o = u8::from_str_radix(s.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

fn names_of(req: &Value, k: &str) -> Vec<String> {
    req.get(k)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect()
}

fn now_of(req: &Value) -> Result<i64, String> {
    req.get("now")
        .and_then(Value::as_i64)
        .ok_or_else(|| "media: missing now".to_owned())
}

fn str_of<'a>(req: &'a Value, k: &str) -> Result<&'a str, String> {
    req.get(k)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("media: missing {k}"))
}

fn local_row(t: &Truth<'_>, col: i64, name: &str) -> Result<Option<LocalRow>, String> {
    let row: Option<(i64, i64, Vec<u8>, Option<Vec<u8>>)> = t
        .conn()
        .prepare_cached(LOCAL_SQL)
        .map_err(sql)?
        .query_row(params![col, name], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .optional()
        .map_err(sql)?;
    Ok(row.and_then(|(size, mtime, sha, synced)| {
        let sha: [u8; 32] = sha.try_into().ok()?;
        Some((size, mtime, sha, synced.and_then(|s| s.try_into().ok())))
    }))
}

fn put_local_row(t: &Truth<'_>, col: i64, name: &str, row: &LocalRow) -> Result<(), String> {
    t.conn()
        .prepare_cached(
            "INSERT OR REPLACE INTO media_local (col, name, size, mtime, sha256, synced) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        )
        .map_err(sql)?
        .execute(params![
            col,
            name,
            row.0,
            row.1,
            row.2.to_vec(),
            row.3.map(|s| s.to_vec())
        ])
        .map_err(sql)?;
    Ok(())
}

/// 名字此刻绑定的内容 (sha256, size)（模块文件头「绑定的读」）。
pub(crate) fn binding(
    t: &Truth<'_>,
    col: i64,
    name: &str,
) -> Result<Option<([u8; 32], i64)>, String> {
    let k: Option<i64> = t
        .conn()
        .prepare_cached(BINDING_SQL)
        .map_err(sql)?
        .query_row(params![col, name, R_WINNER], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    let Some(k) = k else {
        return Ok(None);
    };
    let e = t
        .entry_by_key(k)?
        .ok_or_else(|| format!("media: binding row {k} has no op"))?;
    match body_of(&e) {
        Some(Body4::Media { sha256, size, .. }) => Ok(Some((sha256, size as i64))),
        _ => Err(format!("media: binding row {k} is not a media binding")),
    }
}

// ---------------------------------------------------------------------- 本机文件 → 内容

/// 一个本机媒体文件此刻的 (size, mtime 毫秒)；不在 / 不是普通文件 = None。
fn stat_file(path: &std::path::Path) -> Option<(i64, i64)> {
    let m = std::fs::metadata(path).ok()?;
    if !m.is_file() {
        return None;
    }
    let mtime = m
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_millis() as i64);
    Some((m.len() as i64, mtime))
}

/// 文件内容的 sha256（按块读，不整个读进内存）。
fn sha256_file(path: &std::path::Path) -> Result<[u8; 32], String> {
    use sha2::Digest;
    use std::io::Read;
    let mut f =
        std::fs::File::open(path).map_err(|e| format!("media: open {}: {e}", path.display()))?;
    let mut h = sha2::Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = f
            .read(&mut buf)
            .map_err(|e| format!("media: read {}: {e}", path.display()))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(h.finalize().into())
}

/// `media_hash` 的读半边：[names] 各自在 `media_local` 里的行（一个读快照里读）。
pub fn hash_cached(
    t: &Truth<'_>,
    col: i64,
    names: &[String],
) -> Result<Vec<Option<LocalRow>>, String> {
    names.iter().map(|n| local_row(t, col, n)).collect()
}

/// `media_hash` 的锁外半边：本机媒体目录 [root] 下 [names] 中存在的文件此刻的 (size, mtime, sha256)，[cached] 里
/// (size, mtime) 没变的不重算。回包 `{"files": [{"name", "size", "mtime", "sha"}…]}`（不在 / 读不了的不列）。
pub fn hash_files(root: &str, names: &[String], cached: &[Option<LocalRow>]) -> Value {
    let root = std::path::Path::new(root);
    let mut files = Vec::new();
    for (name, row) in names.iter().zip(cached) {
        let path = root.join(name);
        let Some((size, mtime)) = stat_file(&path) else {
            continue;
        };
        let sha = match row {
            Some((s, m, sha, _)) if *s == size && *m == mtime => Some(*sha),
            // 读不了（被占用 / 刚被删）就当这一轮本机没有它。
            _ => sha256_file(&path).ok(),
        };
        if let Some(sha) = sha {
            files.push(json!({"name": name, "size": size, "mtime": mtime, "sha": hex32(&sha)}));
        }
    }
    json!({"files": files})
}

/// `media_scan {names, files, now}`（协议 3 `sync2_media_scan` 同语义同回包）：每个名字该做什么，需要的绑定在同一个
/// 事务里写进日志。本机有文件、内容 L：没有绑定 → 绑 L；绑定就是 L → 无事；绑定是别的内容 B 而本机上次对齐后文件
/// 没变过（`synced == L`）→ 别的设备后来改了绑定，下载 B；文件改过（或从没对齐过）→ 本机这次改动是新写，绑 L。
pub fn scan(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let names = names_of(req, "names");
    let mut files: HashMap<String, (i64, i64, [u8; 32])> = HashMap::new();
    for f in req
        .get("files")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let name = f
            .get("name")
            .and_then(Value::as_str)
            .ok_or("media_scan: missing name")?;
        let sha = f
            .get("sha")
            .and_then(Value::as_str)
            .and_then(unhex32)
            .ok_or("media_scan: bad sha")?;
        let n = |k: &str| {
            f.get(k)
                .and_then(Value::as_i64)
                .ok_or(format!("media_scan: missing {k}"))
        };
        files.insert(name.to_owned(), (n("size")?, n("mtime")?, sha));
    }
    write(t, col, |s| {
        let t = s.t;
        let mut items = Vec::with_capacity(names.len());
        let mut binds: Vec<(String, [u8; 32], i64)> = Vec::new();
        for name in &names {
            let bound = binding(t, col, name)?;
            let Some(&(size, mtime, l)) = files.get(name) else {
                items.push(match bound {
                    Some((sha, size)) => {
                        json!({"name": name, "sha": hex32(&sha), "size": size, "have": false, "local": null})
                    }
                    None => json!({"name": name, "sha": null, "size": 0, "have": false, "local": null}),
                });
                continue;
            };
            let row = local_row(t, col, name)?;
            let synced = row.as_ref().and_then(|r| r.3);
            let (target, tsize, have, synced) = match bound {
                Some((b, _)) if b == l => (l, size, true, Some(l)),
                Some((b, bsize)) if synced == Some(l) => (b, bsize, false, synced),
                _ => {
                    binds.push((name.clone(), l, size));
                    (l, size, true, Some(l))
                }
            };
            let new_row: LocalRow = (size, mtime, l, synced);
            if row.as_ref() != Some(&new_row) {
                put_local_row(t, col, name, &new_row)?;
            }
            items.push(json!({"name": name, "sha": hex32(&target), "size": tsize, "have": have, "local": hex32(&l)}));
        }
        for (name, sha, size) in &binds {
            s.land(
                Body::Media {
                    name: name.clone(),
                    sha256: *sha,
                    size: (*size).max(0) as u64,
                },
                now,
            )?;
        }
        Ok(json!({"items": items, "appended": binds.len()}))
    })
}

/// `media_landed {root, items: [{name, sha}], now}`（协议 3 `sync2_media_landed`）：下载落地之后记成「本机已与绑定
/// 对齐」（记下此刻的 size / mtime）；名字还没有绑定就绑上。文件已经不在的不记。回包 `{"appended": n}`。文件的 stat 在
/// 调用方（分发器）进事务之前做完：[stats] 与 [items] 一一对应，None = 不在。
pub fn landed(
    t: &Truth<'_>,
    col: i64,
    items: &[(String, [u8; 32])],
    stats: &[Option<(i64, i64)>],
    now: i64,
) -> Result<Value, String> {
    write(t, col, |s| {
        let t = s.t;
        let mut binds: Vec<(String, [u8; 32], i64)> = Vec::new();
        for ((name, sha), st) in items.iter().zip(stats) {
            let Some((size, mtime)) = st else {
                continue;
            };
            put_local_row(t, col, name, &(*size, *mtime, *sha, Some(*sha)))?;
            if binding(t, col, name)?.is_none() && !binds.iter().any(|b| &b.0 == name) {
                binds.push((name.clone(), *sha, *size));
            }
        }
        for (name, sha, size) in &binds {
            s.land(
                Body::Media {
                    name: name.clone(),
                    sha256: *sha,
                    size: (*size).max(0) as u64,
                },
                now,
            )?;
        }
        Ok(json!({"appended": binds.len()}))
    })
}

/// [landed] 的请求：`items` 与各文件此刻的 stat（在事务之外做）。
pub fn landed_items(
    req: &Value,
) -> Result<(Vec<(String, [u8; 32])>, Vec<Option<(i64, i64)>>), String> {
    let root = std::path::Path::new(str_of(req, "root")?).to_path_buf();
    let mut items = Vec::new();
    for it in req
        .get("items")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let name = it
            .get("name")
            .and_then(Value::as_str)
            .ok_or("media_landed: missing name")?;
        let sha = it
            .get("sha")
            .and_then(Value::as_str)
            .and_then(unhex32)
            .ok_or("media_landed: bad sha")?;
        items.push((name.to_owned(), sha));
    }
    let stats = items
        .iter()
        .map(|(n, _)| stat_file(&root.join(n)))
        .collect();
    Ok((items, stats))
}

/// `media_doomed {expired, live}`（协议 3 同名命令）：[expired] 绑定的内容里不被 [live] 任何一个名字绑定的那些。
pub fn doomed(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let mut keep = BTreeSet::new();
    for n in names_of(req, "live") {
        if let Some((sha, _)) = binding(t, col, &n)? {
            keep.insert(sha);
        }
    }
    let mut out = BTreeSet::new();
    for n in names_of(req, "expired") {
        if let Some((sha, _)) = binding(t, col, &n)? {
            if !keep.contains(&sha) {
                out.insert(hex32(&sha));
            }
        }
    }
    Ok(json!({"sha": out.into_iter().collect::<Vec<_>>()}))
}

// ---------------------------------------------------------------------- 位置上有什么

/// 请求里的「在不在」键（Dart `srsMediaContentPresenceKey`：`<位置>/<媒体目录>#sha256`）拆成 (位置, 目录)。
fn presence(req: &Value) -> Result<(String, String), String> {
    let key = str_of(req, "location")?;
    let (l, f) = parse_key(key).ok_or_else(|| format!("media: bad presence key {key:?}"))?;
    Ok((l.to_owned(), f.to_owned()))
}

/// `media_known {location}`：`{"seeded", "present", "absent", "suspect"}`（名字 = 内容哈希的十六进制，协议 3 同形）。
pub fn known(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let (location, folder) = presence(req)?;
    let k = media::known(t, col, &location, &folder)?;
    let hexes = |v: &[[u8; 32]]| v.iter().map(hex32).collect::<Vec<_>>();
    Ok(json!({
        "seeded": k.seeded,
        "present": hexes(&k.present),
        "absent": hexes(&k.absent),
        "suspect": hexes(&k.suspect),
    }))
}

/// 本机时钟 tick 一下（写回 `self_.hlc`）。
fn tick(t: &Truth<'_>, col: i64, now: i64) -> Result<Hlc, String> {
    let me = t
        .self_identity(col)?
        .ok_or_else(|| format!("media: collection {col} has no local identity"))?;
    let mut clock = Clock {
        device: me.device,
        last: me.hlc,
    };
    let hlc = clock.tick(now);
    t.set_self_hlc(col, &hlc)?;
    Ok(hlc)
}

/// `media_record {location, present, absent, suspect, seeded, now}`：本机对一个媒体目录的观察写进 `media_at`（待发，
/// 随下一份清单发出，`gen4/media.rs` [media::record]）。名字是内容哈希；不是 64 位十六进制的（协议 3 按名字存的旧
/// 格式）不认。回包 `{"appended": 写下的条数}`。
pub fn record(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let (location, folder) = presence(req)?;
    let now = now_of(req)?;
    let mut facts: Vec<([u8; 32], MediaState)> = Vec::new();
    for (k, s) in [
        ("present", MediaState::Present),
        ("absent", MediaState::Absent),
        ("suspect", MediaState::Suspect),
    ] {
        for n in names_of(req, k) {
            let sha = unhex32(&n).ok_or_else(|| format!("media_record: bad content hash {n:?}"))?;
            facts.push((sha, s));
        }
    }
    let seeded = req.get("seeded") == Some(&Value::Bool(true));
    if facts.is_empty() && !seeded {
        return Ok(json!({"appended": 0}));
    }
    let hlc = tick(t, col, now)?;
    let r = media::record(t, col, &location, &folder, &facts, seeded, hlc)?;
    Ok(json!({"appended": r.written, "unchanged": r.unchanged}))
}

// ---------------------------------------------------------------------- 清单

/// 这个位置的 loc 标记（`location_root` 记进 `loc_state.loc_ids` 的）。
fn locs_of(t: &Truth<'_>, col: i64, location: &str) -> Result<BTreeSet<Id>, String> {
    let ids: Option<Option<String>> = t
        .conn()
        .prepare_cached(super::sync::LOC_STATE_SQL)
        .map_err(sql)?
        .query_row(params![col, location], |r| r.get::<_, Option<String>>(0))
        .optional()
        .map_err(sql)?;
    Ok(ids
        .flatten()
        .and_then(|s| serde_json::from_str::<Vec<String>>(&s).ok())
        .unwrap_or_default()
        .iter()
        .filter_map(|s| Id::parse(s))
        .collect())
}

/// `media_manifests {location, listing: {设备: [文件名…]}}`：各设备目录里还没收的清单（代号大于本机水位，
/// [media::pending_gens]），路径相对 `v4/`，按 (设备, 代号) 升序。本机自己的清单不收（发出时已推进水位）。回包
/// `{"fetch": [路径…]}`。
pub fn manifests(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let location = str_of(req, "location")?;
    let me = t.self_identity(col)?.map(|s| s.device);
    let mut by_dev: BTreeMap<Id, Vec<(u64, String)>> = BTreeMap::new();
    if let Some(listing) = req.get("listing").and_then(Value::as_object) {
        for (dev, names) in listing {
            for name in names
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                let path = format!("devices/{dev}/{name}");
                if let Some(V4File::Manifest { device, gen, .. }) = parse_v4_path(&path) {
                    if Some(device) != me {
                        by_dev.entry(device).or_default().push((gen, path));
                    }
                }
            }
        }
    }
    let mut fetch = Vec::new();
    for (device, mut files) in by_dev {
        files.sort();
        let gens: Vec<u64> = files.iter().map(|(g, _)| *g).collect();
        let want: BTreeSet<u64> = media::pending_gens(t, col, location, &device, &gens)?
            .into_iter()
            .collect();
        fetch.extend(
            files
                .into_iter()
                .filter(|(g, _)| want.contains(g))
                .map(|(_, p)| p),
        );
    }
    Ok(json!({"fetch": fetch}))
}

/// `media_manifest_ingest {location, paths, now}`，字节块与 `paths` 一一对应（null 块 = 没读到）：逐份收
/// （[media::ingest]）。同一个作者的清单按代号升序，一份收不了（没读到、坏的、作者还不认得 / 不受信）就停在它，这一轮不收
/// 它之后的（水位只升不降，跳过的文件不会再收）。读进来的不超前的最大 HLC 吸收进本机时钟。回包
/// `{"ingested", "applied", "errors": [..], "ahead": [设备…]}`。
pub fn manifest_ingest(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    blobs: &[Vec<u8>],
    present: &[bool],
) -> Result<Value, String> {
    let location = str_of(req, "location")?;
    let now = now_of(req)?;
    let paths = names_of(req, "paths");
    if paths.len() != present.len() {
        return Err("media_manifest_ingest: paths and blobs differ in length".into());
    }
    let locs = locs_of(t, col, location)?;
    let mut stopped: BTreeSet<Id> = BTreeSet::new();
    let mut errors: Vec<String> = Vec::new();
    let mut ahead: BTreeSet<Id> = BTreeSet::new();
    let mut max_hlc: Option<Hlc> = None;
    let (mut ingested, mut applied) = (0u64, 0u64);
    let mut it = blobs.iter();
    for (path, &has) in paths.iter().zip(present) {
        let bytes = if has { it.next() } else { None };
        let Some(V4File::Manifest { device, gen, tag }) = parse_v4_path(path) else {
            errors.push(format!("{path}: not a manifest path"));
            continue;
        };
        if stopped.contains(&device) {
            continue;
        }
        let Some(bytes) = bytes else {
            stopped.insert(device);
            errors.push(format!("{path}: not read"));
            continue;
        };
        match media::ingest(t, col, location, &locs, &device, gen, &tag, bytes, now) {
            Ok(r) => {
                ingested += 1;
                applied += r.applied as u64;
                ahead.extend(r.seen.ahead);
                max_hlc = max_hlc.max(r.seen.max_hlc);
            }
            Err(media::IngestError::Store(e)) => return Err(e),
            Err(e) => {
                stopped.insert(device);
                errors.push(format!("{path}: {e}"));
            }
        }
    }
    if let Some(h) = max_hlc {
        if let Some(me) = t.self_identity(col)? {
            let mut clock = Clock {
                device: me.device,
                last: me.hlc,
            };
            if !clock.absorb(h, now).ahead && clock.last != me.hlc {
                t.set_self_hlc(col, &clock.last)?;
            }
        }
    }
    Ok(json!({
        "ingested": ingested,
        "applied": applied,
        "errors": errors,
        "ahead": ahead.iter().map(Id::text).collect::<Vec<_>>(),
    }))
}

/// `media_manifest_build {location, loc, ownGens}`：本机待发的事实打成下一份清单（[media::build]；没有待发的回
/// `{"built": false}`、不烧代号）。文件在 [files]（路径相对 `v4/`：`devices/<本机>/mf-…`）。
pub fn manifest_build(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    files: &mut Files,
) -> Result<Value, String> {
    let location = str_of(req, "location")?;
    let loc = Id::parse(str_of(req, "loc")?).ok_or("media_manifest_build: bad loc")?;
    let own: Vec<u64> = req
        .get("ownGens")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_u64)
        .collect();
    let me = t
        .self_identity(col)?
        .ok_or_else(|| format!("media: collection {col} has no local identity"))?;
    match media::build(t, col, location, loc, me.device, &me.key(), &own)? {
        None => Ok(json!({"built": false})),
        Some(b) => {
            let path = device_path(&me.device, &b.name);
            files.push((path.clone(), b.bytes));
            Ok(json!({"built": true, "path": path, "gen": b.manifest.gen}))
        }
    }
}

/// `media_manifest_published {location}`，字节块 = [manifest_build] 给出、已经写到位置上的那份：按本机公钥验过之后
/// 清掉仍是那几条事实的待发标记、推进本机水位（[media::mark_published]，可重放）。回包 `{"cleared": n}`。
pub fn manifest_published(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    blob: &[u8],
) -> Result<Value, String> {
    let location = str_of(req, "location")?;
    let me = t
        .self_identity(col)?
        .ok_or_else(|| format!("media: collection {col} has no local identity"))?;
    let m = open_manifest(blob)
        .and_then(|o| o.verify(&me.public()))
        .map_err(|e| format!("media_manifest_published: {e}"))?;
    if m.device != me.device {
        return Err("media_manifest_published: not this device's manifest".into());
    }
    let n = media::mark_published(t, col, location, &m)?;
    Ok(json!({"cleared": n}))
}
