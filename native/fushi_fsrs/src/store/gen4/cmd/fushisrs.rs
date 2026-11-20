//! `.fushisrs` 的导出 / 导入命令（规划 §1.9、§2.2 G11-3）：`export` / `import`。存储层在 `store/gen4/export.rs`
//! （[export_ops]）与 `store/gen4/import.rs`（[import_ops_from] / [import_v1] / [import_peers] / [own_fork_point]），流的
//! 编解码在 `crate::gen4::export`；这里只做请求解析、来源（文件或字节块）、事务边界与回包。zip 外壳、清单 JSON 的其余
//! 字段与媒体由 Dart 写（`packages/fushi_engine/lib/srs/sync2/srs_fushisrs.dart`）。
//!
//! # `export {path?}`
//!
//! 一个读快照里把本集合的真相层写成 `FSRS4EXP` 流（D34：不含待投递的槽、含分叉的另一支；不含本机状态）。给了 `path`
//! 就边压缩边写进那个文件（内存只有压缩窗口与一项，写坏了删掉半截文件）；没给就作为回包文件 `ops.bin` 交回（测试、
//! 小库）。回包是清单里归内核的那几项：
//!
//! ```text
//! {collection, dir, salts: [..], peers: [{device, public, name?}], counts: {...}}
//! ```
//!
//! - `collection` / `dir` / `salts`：本机绑定（规划 §1.9 清单的同名字段；导入方据此判断与本机的关系，见下）。
//! - `peers`（缺口 G-12 的定案）：`FSRS4EXP` 只有原生日志的抬头带公钥，承袭日志（协议 3 设备）没有；它们的公钥、名字
//!   随清单走，导入方与旧备份读入同口径记下（`import.rs` [import_peers]），否则还原之后位置上协议 3 的段因为不认识
//!   签名者一直暂缓。不升 `FSRS4EXP` 的版本（G11-1 的格式冻结不动）。整张 `peers` 都带（原生设备的公钥流里也有，
//!   重复无害：同一把公钥是「已有」）。
//!
//! # `import {path? | 字节块, manifest?, confirmed?, now, anchor?}`
//!
//! 来源：`path`（Dart 从 zip 里解出来的 `ops.bin` 临时文件，内核按 [Read] 流式读，压缩字节也不整份进内存；G11-2 复核的
//! 内存遗留在此根修）或第一个字节块。嗅探魔数分两代：
//!
//! - **第 2 版（`FSRS4EXP`）**：一个写事务（分发器 `write_binding`）里依次：
//!   1. 与本机的关系：清单的 `{collection, dir, salts}` 交给 G9-4 的 `collection_adopt`（判据只在 `identity::adopt_foreign`
//!      一处）——同一个集合 / 早已并入的照常导入；**另一个集合**在没有 `confirmed` 时回
//!      `{outcome: "needsConfirm", reason: "join", collection, dir, newSalts, newPeers}`、什么都不写（BUG-4011 / D25：
//!      确认之前不并入），带 `confirmed` 重发就先并入（写 `Join`）再导入。
//!      同一个集合 / 早已并入的文件若带来本机还不算数的盐（会写一条本机签名的 `Salts`）或本机还不认识的设备公钥（清单的
//!      `peers`），同样要确认（W2 合流定案，见交接说明 §18「导入补盐与设备公钥要确认」）：没有 `confirmed` 时回
//!      `{outcome: "needsConfirm", reason: "identity", collection, dir, newSalts, newPeers}`、什么都不写。盐不受证据约束：
//!      别名层对每个盐直接把「ID 等于这个盐」的已出现实体归到 profile 级设置实体（`gen4_ids/alias.rs` `profile_entities`），
//!      一个自称同一集合的文件带一个等于本机某实体 ID 的「盐」就能把它并错；设备公钥先到先得，错的公钥让那台设备真正的段
//!      以后一直被拒。清单里的集合必须就是流头里的集合；没带清单（裸 `ops.bin`）不做认领，流头的集合
//!      不是本集合（或被它并入过的）就由存储层拒绝。
//!   2. 清单的 `peers` → [import_peers]（公钥先到先得、冲突整个拒绝、名字只补空缺）。
//!   3. 本机身份的分叉（[own_fork_point]，协议 3 `import_on` 的「包里有本机身份的操作时先换身份」）：分了就
//!      `Truth::rotate_identity(col, keep, now)`（G8-6）再导入，回包 `rotated`。
//!   4. [import_ops_from]：落真相、`Settle::Rebuild` 收派生层。
//! - **第 1 版（协议 3 的 `FSRS2EXP`）**：冻结读入器转译（[import_v1]）。另一个集合的第 1 版文件照旧拒绝（D34），不认领。
//!   冻结读入器只收切片：第 1 版文件整份读进内存（压缩后的字节；解码仍是流式窗口）——第 1 版只会越来越少，不为它改冻结
//!   代码（`legacy_export.rs` 文件头）。
//!
//! **预检**（`preflight: true`）：只判「会不会要确认、会不会被拒」，什么都不写、修订号不动——Dart 据此在用户确认之前不打
//! 还原点、不往媒体目录写文件（复核：用户拒绝后不留孤儿媒体）。判据与真导入同一处：嗅探魔数；第 1 版走存储层的
//! `check_v1_collection`；第 2 版先比清单与流头，再在一个**回滚掉的保存点**里跑 `collection_adopt`（`same` 时可能补盐，
//! 回滚不留）与存储层的 `check_stream_collection`。回包 `{format, outcome: "ready" | "needsConfirm", preflight: true,
//! reason?, collection?, dir?, newSalts?, newPeers?}`（要确认时同真导入的形状）。坏在流中间的文件预检看不出（不读全流），由 Dart 在真导入报错时删掉这次补进来的媒体。
//!
//! 坏流、另一个集合、与本机矛盾一律报错、整笔回滚、一条不落；同一份再导一遍什么都不改（槽幂等），所以中断后重来不产生
//! 重复卡片或复习记录。v2 之前那种「事件 + 魔数清单」的旧备份不归内核：Dart 那一侧明确拒绝并提示（`apply` 的 stamped 输入
//! 在新代已拒，冻结侧的 stamped apply 还没有，见交接说明 G11-3 一节）。
//!
//! 回包：
//!
//! ```text
//! {format: 1 | 2, outcome, applied, unchanged, peers, rotated: null | {device, previous, keep, moved},
//!  counts: {...}, settled: {...}, localRevision, localEpoch}      （+ 绑定变了时分发器加 bindingChanged）
//! ```
//!
//! `outcome`：第 2 版是认领结论（`same` / `alreadyJoined` / `saltsAdded` / `joined` / `bound`；没带清单是 `stream`），
//! 第 1 版是 `legacy`。`unchanged` = 这次一点没改：新落的操作、新记的设备公钥、认领写下的盐 / 并入 / 绑定、换身份都算改动
//! （Dart 据它决定丢不丢缓存日志）。`applied` = 新落的原生操作与空洞区间 + 新落 / 换掉 / 分叉的承袭槽（Dart「并入了几条」）。
//!
//! 本机状态行（`local.rs` `persist`）：协议 3 的 `import` 是本机写命令（推进修订号、带 `anchor`），这里同口径；导入按
//! `Settle::Rebuild` 收派生层、没有逐实体的变更清单，有改动时修订号推进 1（Dart 的刷新键只看变没变），回包不带
//! `changed`，Dart 收到有改动的回包整份丢掉缓存日志。
//!
//! 查询：`peers` 清单一条语句（[PEERS_SQL]，主键前缀 `col`，查询计划测试在 `fushisrs_tests.rs`）；其余都在存储层既有 API 里。

use std::borrow::Cow;
use std::collections::BTreeSet;
use std::fs::File;
use std::io::{BufReader, BufWriter, Read};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::identity::{Emitting, collection_adopt};
use super::{hex, snapshot};
use crate::gen4::export::{ExportKind, sniff_reader};
use crate::store::gen4::derive::Index;
use crate::store::gen4::export::{Exported, export_ops};
use crate::store::gen4::identity::BindingChanged;
use crate::store::gen4::import::{
    ImportedOps, check_stream_collection, check_v1_collection, import_ops_from, import_peers,
    import_v1, open_ops_reader, own_fork_point,
};
use crate::store::gen4::local;
use crate::store::gen4::refresh::{TALLY_KEY, Tally};
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::{Peer, Truth};
use crate::sync2::id::Id;

/// 导出清单里的 `peers`：本集合记下的全部设备（主键前缀 `col`，按设备升序）。
pub const PEERS_SQL: &str = "SELECT device, public, name FROM peers WHERE col = ?1 ORDER BY device";

/// 导入的来源（模块文件头「来源」）。
pub enum Source<'a> {
    Path(PathBuf),
    Bytes(&'a [u8]),
}

impl<'a> Source<'a> {
    /// 请求的 `path`，没有就取第一个字节块。
    pub fn of(req: &Value, blobs: &'a [Vec<u8>]) -> Result<Source<'a>, String> {
        match req.get("path").and_then(Value::as_str) {
            Some(p) if !p.is_empty() => Ok(Source::Path(PathBuf::from(p))),
            _ => blobs
                .first()
                .map(|b| Source::Bytes(b))
                .ok_or_else(|| "import: missing path or file".to_owned()),
        }
    }

    /// 从头读一遍（每次都是新的读游标）。按路径时经 [FileSource] 一块块读，不整份进内存。
    fn open(&self) -> Result<Box<dyn Read + '_>, String> {
        Ok(match self {
            Source::Path(p) => {
                Box::new(BufReader::new(FileSource(File::open(p).map_err(|e| {
                    format!("import: cannot open {}: {e}", p.display())
                })?)))
            }
            Source::Bytes(b) => Box::new(*b),
        })
    }

    /// 整份字节（只给第 1 版的冻结读入器用，模块文件头）。
    fn bytes(&self) -> Result<Cow<'a, [u8]>, String> {
        Ok(match self {
            Source::Path(p) => Cow::Owned(
                std::fs::read(p)
                    .map_err(|e| format!("import: cannot read {}: {e}", p.display()))?,
            ),
            Source::Bytes(b) => Cow::Borrowed(b),
        })
    }
}

/// 按路径导入时对文件的读（[Source::open]）：每次读的都是调用方给的有界缓冲（[BufReader] 的一块或解码器的输入窗口），
/// 第 2 版不整份读进内存（G11-2 复核遗留的根修）。测试里经 [meter] 记下每次读的请求大小与读到的字节，钉住命令层的
/// 读法（`fushisrs_tests.rs` 的大文件测试）。
struct FileSource(File);

impl Read for FileSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.0.read(buf)?;
        #[cfg(test)]
        meter::record(buf.len(), n);
        Ok(n)
    }
}

/// [FileSource] 的读记录（只在测试里编译；命令经 C ABI 在调用线程上同步跑，所以按线程记）。
#[cfg(test)]
pub(super) mod meter {
    use std::cell::Cell;

    /// 一段时间里对导入文件的读：次数、最大的一次请求、读到的总字节。
    #[derive(Clone, Copy, Debug, Default)]
    pub struct Reads {
        pub calls: u64,
        pub widest: usize,
        pub bytes: u64,
    }

    thread_local! {
        static READS: Cell<Reads> = const {
            Cell::new(Reads { calls: 0, widest: 0, bytes: 0 })
        };
    }

    pub(super) fn record(asked: usize, got: usize) {
        READS.with(|m| {
            let mut r = m.get();
            r.calls += 1;
            r.widest = r.widest.max(asked);
            r.bytes += got as u64;
            m.set(r);
        });
    }

    /// 取走本线程的记录并清零。
    pub fn take() -> Reads {
        READS.with(|m| m.replace(Reads::default()))
    }
}

fn str_of<'v>(v: &'v Value, k: &str, what: &str) -> Result<&'v str, String> {
    v.get(k)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{what}: missing {k}"))
}

fn id_of(v: &Value, k: &str, what: &str) -> Result<Id, String> {
    let s = str_of(v, k, what)?;
    Id::parse(s).ok_or_else(|| format!("{what}: bad {k} {s}"))
}

fn key_of(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 || !s.is_ascii() {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&s[2 * i..2 * i + 2], 16).ok()?;
    }
    Some(out)
}

// ---------------------------------------------------------------------- export

fn counts_json(e: &Exported) -> Value {
    json!({
        "nativeLogs": e.native_logs, "heritageLogs": e.heritage_logs, "ops": e.ops,
        "voidRuns": e.void_runs, "voided": e.voided, "slots": e.slots, "forks": e.forks,
        "marks": e.marks, "pendingSkipped": e.pending_skipped,
    })
}

/// 本集合记下的设备（[PEERS_SQL]）→ 清单的 `peers`。
fn peers_json(t: &Truth<'_>, col: i64) -> Result<Vec<Value>, String> {
    let mut stmt = t.conn().prepare_cached(PEERS_SQL).map_err(sql)?;
    let rows = stmt
        .query_map([col], |r| {
            Ok((
                r.get::<_, Vec<u8>>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, Option<String>>(2)?,
            ))
        })
        .map_err(sql)?;
    let mut out = Vec::new();
    for row in rows {
        let (device, public, name) = row.map_err(sql)?;
        let device: [u8; 16] = device
            .try_into()
            .map_err(|_| "export: bad device id in peers".to_owned())?;
        let mut p = json!({"device": Id(device).text(), "public": hex(&public)});
        if let Some(n) = name {
            p["name"] = json!(n);
        }
        out.push(p);
    }
    Ok(out)
}

/// [path] 的临时文件 `<path>.g4tmp`：在整个文件名后面追加（不是替换扩展名，否则只差扩展名的两个目标会撞到同一个临时文件）。
fn tmp_of(path: &Path) -> PathBuf {
    let mut s = path.as_os_str().to_owned();
    s.push(".g4tmp");
    PathBuf::from(s)
}

/// 写进 [path]：先写同目录的临时文件（[tmp_of]）、刷盘后改名；出错删掉临时文件，不留半截。
fn export_to_file(t: &Truth<'_>, col: i64, path: &Path) -> Result<Exported, String> {
    let tmp = tmp_of(path);
    let run = || -> Result<Exported, String> {
        let f = File::create(&tmp)
            .map_err(|e| format!("export: cannot create {}: {e}", tmp.display()))?;
        let (w, counts) = export_ops(t, col, BufWriter::new(f))?;
        let f = w.into_inner().map_err(|e| format!("export: {e}"))?;
        f.sync_all().map_err(|e| format!("export: {e}"))?;
        drop(f);
        std::fs::rename(&tmp, path)
            .map_err(|e| format!("export: cannot move into {}: {e}", path.display()))?;
        Ok(counts)
    };
    let out = run();
    if out.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    out
}

/// `export {path?}`（模块文件头）。[t] 是读连接；集合号与导出同一个读快照。
pub fn export(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    files: &mut super::Files,
) -> Result<Value, String> {
    snapshot(t, |t| {
        let binding = t
            .binding(col)?
            .ok_or_else(|| format!("export: collection {col} is not bound"))?;
        let counts = match req.get("path").and_then(Value::as_str) {
            Some(p) if !p.is_empty() => export_to_file(t, col, Path::new(p))?,
            _ => {
                let (bytes, counts) = export_ops(t, col, Vec::new())?;
                files.push(("ops.bin".to_owned(), bytes));
                counts
            }
        };
        Ok(json!({
            "collection": binding.collection.text(),
            "dir": binding.dir,
            "salts": binding.salts.iter().collect::<Vec<_>>(),
            "peers": peers_json(t, col)?,
            "counts": counts_json(&counts),
        }))
    })
}

// ---------------------------------------------------------------------- import

/// 清单里归内核的部分（模块文件头）。整包备份里协议 3 旧库的读入（`cmd/backup.rs`）按同一形状拼出来、走同一道确认。
pub(super) struct Manifest {
    pub(super) collection: Id,
    pub(super) dir: String,
    pub(super) salts: BTreeSet<String>,
    pub(super) peers: Vec<Peer>,
}

/// 同一个集合 / 早已并入的文件带来、要用户确认才落的身份变化（模块文件头第 1 步）：本机还不算数的盐、本机还不认识的设备
/// （清单 `peers` 里不是本机、也没记过公钥的）。另一个集合（`collection_adopt` 本来就问）或还没绑定时 = None；没有新东西
/// 也是 None。只读。
pub(super) fn unconfirmed_identity(
    t: &Truth<'_>,
    profile: &str,
    m: &Manifest,
) -> Result<Option<(Vec<String>, Vec<String>)>, String> {
    let Some(b) = t.binding_of(profile)? else {
        return Ok(None);
    };
    let mut ix = Index::new(t, b.col);
    if b.collection != m.collection && !ix.joined(&m.collection)? {
        return Ok(None);
    }
    let have = ix.trusted_salts()?;
    let salts: Vec<String> = m.salts.difference(&have).cloned().collect();
    let me = t.self_identity(b.col)?.map(|s| s.device);
    let mut peers = Vec::new();
    for p in &m.peers {
        if Some(p.device) != me && t.peer(b.col, &p.device)?.is_none() {
            peers.push(p.device.text());
        }
    }
    Ok((!salts.is_empty() || !peers.is_empty()).then_some((salts, peers)))
}

fn manifest_of(req: &Value) -> Result<Option<Manifest>, String> {
    let Some(m) = req.get("manifest").filter(|m| !m.is_null()) else {
        return Ok(None);
    };
    let what = "import manifest";
    let salts = match m.get("salts") {
        None | Some(Value::Null) => BTreeSet::new(),
        Some(v) => v
            .as_array()
            .ok_or_else(|| format!("{what}: salts must be an array"))?
            .iter()
            .map(|s| {
                s.as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| format!("{what}: salts must be strings"))
            })
            .collect::<Result<_, _>>()?,
    };
    let mut peers = Vec::new();
    for p in m
        .get("peers")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
    {
        let public = str_of(p, "public", what)?;
        peers.push(Peer {
            device: id_of(p, "device", what)?,
            public: key_of(public).ok_or_else(|| format!("{what}: bad public key {public}"))?,
            name: p
                .get("name")
                .and_then(Value::as_str)
                .filter(|n| !n.is_empty())
                .map(str::to_owned),
            ext: None,
            head_gen: None,
            first_seen: None,
        });
    }
    Ok(Some(Manifest {
        collection: id_of(m, "collection", what)?,
        dir: str_of(m, "dir", what)?.to_owned(),
        salts,
        peers,
    }))
}

/// 预检里回滚保存点用的错误（不会出现在回包里）。
const PREFLIGHT_ROLLBACK: &str = "gen4 import: preflight rollback";

/// 预检通过的回包（模块文件头「预检」）。
fn ready(format: u8) -> Value {
    json!({"format": format, "outcome": "ready", "preflight": true})
}

/// Dart「并入了几条」（模块文件头）。
fn applied_of(o: &ImportedOps) -> u64 {
    o.native_landed + o.voids_landed + o.slots_inserted + o.slots_replaced + o.slots_forked
}

fn imported_json(o: &ImportedOps) -> Value {
    json!({
        "nativeLogs": o.native_logs, "heritageLogs": o.heritage_logs,
        "nativeLanded": o.native_landed, "nativeKnown": o.native_known, "voidsLanded": o.voids_landed,
        "slotsInserted": o.slots_inserted, "slotsSame": o.slots_same, "slotsKept": o.slots_kept,
        "slotsReplaced": o.slots_replaced, "slotsForked": o.slots_forked, "marks": o.marks,
        "relayVersions": o.relay_versions, "relayStubs": o.relay_stubs, "relaySkipped": o.relay_skipped,
    })
}

/// `import`（模块文件头）。[t] 在分发器的写事务里；[col_of] 是分发器的 profile → 集合号（认领可能刚建好绑定）。
pub fn import(
    t: &Truth<'_>,
    profile: &str,
    req: &Value,
    src: &Source<'_>,
    anchor: Option<&Value>,
    col_of: &dyn Fn(&Truth<'_>) -> Result<i64, String>,
) -> Result<Emitting, String> {
    let now = req
        .get("now")
        .and_then(Value::as_i64)
        .ok_or("import: missing now")?;
    let preflight = req.get("preflight").and_then(Value::as_bool) == Some(true);
    let kind = sniff_reader(src.open()?)
        .map_err(|e| format!("gen4 import: not a Fushi SRS export ({e})"))?;
    let mut changed: Option<BindingChanged> = None;
    let mut wrote = false;
    let (format, outcome, got, rotated, peers) = match kind {
        ExportKind::V1 => {
            let col = col_of(t)?;
            let bytes = src.bytes()?;
            if preflight {
                check_v1_collection(t, col, &bytes)?;
                return Ok((ready(1), None));
            }
            let got = import_v1(t, col, &bytes)?;
            (1, json!("legacy"), got, Value::Null, 0)
        }
        ExportKind::V4 => {
            let manifest = manifest_of(req)?;
            let header = open_ops_reader(src.open()?)?.1;
            let mut outcome = json!("stream");
            if let Some(m) = &manifest {
                if m.collection != header.collection {
                    return Err(format!(
                        "gen4 import: the manifest names collection {} but the stream is {}",
                        m.collection, header.collection
                    ));
                }
                let confirmed = req.get("confirmed").and_then(Value::as_bool) == Some(true);
                let sub = json!({
                    "collection": m.collection.text(),
                    "dir": m.dir,
                    "salts": m.salts.iter().collect::<Vec<_>>(),
                    "confirmed": confirmed,
                    "now": now,
                });
                // 同一个集合 / 早已并入时要确认的新盐与新设备（模块文件头第 1 步）；确认过了就不再问。
                let identity = if confirmed {
                    None
                } else {
                    unconfirmed_identity(t, profile, m)?
                };
                let (new_salts, new_peers) = identity.clone().unwrap_or_default();
                let needs_confirm = |reason: &str| {
                    json!({
                        "format": 2,
                        "outcome": "needsConfirm",
                        "reason": reason,
                        "collection": m.collection.text(),
                        "dir": m.dir,
                        "newSalts": new_salts,
                        "newPeers": new_peers,
                    })
                };
                if preflight {
                    // 认领与流头的判据都在一个回滚掉的保存点里跑（与真导入同一处 adopt_foreign / 存储层判据），补的盐不留。
                    let mut asks = false;
                    let probe: Result<(), String> = t.tx(|t| {
                        let (v, _) = collection_adopt(t, profile, &sub)?;
                        asks = v["outcome"] == json!("needsConfirm");
                        if !asks {
                            check_stream_collection(t, col_of(t)?, &header.collection)?;
                        }
                        Err(PREFLIGHT_ROLLBACK.to_owned())
                    });
                    match probe {
                        Err(e) if e == PREFLIGHT_ROLLBACK => {}
                        Err(e) => return Err(e),
                        Ok(()) => unreachable!("the preflight savepoint always rolls back"),
                    }
                    let mut v = if asks {
                        needs_confirm("join")
                    } else if identity.is_some() {
                        needs_confirm("identity")
                    } else {
                        ready(2)
                    };
                    v["preflight"] = json!(true);
                    return Ok((v, None));
                }
                // 没确认的新盐 / 新设备：什么都不写就回（认领还没跑，库一字不动）。
                if identity.is_some() {
                    return Ok((needs_confirm("identity"), None));
                }
                let (v, ch) = collection_adopt(t, profile, &sub)?;
                if v["outcome"] == json!("needsConfirm") {
                    return Ok((needs_confirm("join"), None));
                }
                wrote = !matches!(v["outcome"].as_str(), Some("same" | "alreadyJoined"));
                changed = ch;
                outcome = v["outcome"].clone();
            } else if preflight {
                check_stream_collection(t, col_of(t)?, &header.collection)?;
                return Ok((ready(2), None));
            }
            let col = col_of(t)?;
            let peers = match manifest {
                Some(m) => import_peers(t, col, m.peers)?,
                None => 0,
            };
            let rotated = match own_fork_point(t, col, open_ops_reader(src.open()?)?)? {
                Some(keep) => {
                    let r = t.rotate_identity_report(col, keep, now)?;
                    wrote = true;
                    json!({
                        "device": r.device.text(),
                        "previous": r.previous.text(),
                        "keep": r.keep,
                        "moved": r.moved.len(),
                    })
                }
                None => Value::Null,
            };
            let got = import_ops_from(t, col, open_ops_reader(src.open()?)?)?;
            (2, outcome, got, rotated, peers)
        }
    };
    // 认领 / 补盐 / 绑定 / 换身份（`wrote`）也是改动：补盐会收派生层（别名类变了），Dart 据 `unchanged` 决定丢不丢缓存日志。
    let unchanged = got.unchanged() && peers == 0 && !wrote;
    // 有改动时修订号推进 1（模块文件头「本机状态行」）。
    let mut probe = if unchanged {
        json!({})
    } else {
        json!({"changed": [Value::Null]})
    };
    local::persist(t, profile, anchor, &mut probe)?;
    let mut v = json!({
        "format": format,
        "outcome": outcome,
        "applied": applied_of(&got),
        "unchanged": unchanged,
        "peers": got.peers + peers,
        "rotated": rotated,
        "counts": imported_json(&got),
        "settled": {
            "cacheNotes": got.settled.cache_notes,
            "cacheCards": got.settled.cache_cards,
            "cacheStats": got.settled.cache_stats,
        },
    });
    for k in ["localRevision", "localEpoch"] {
        v[k] = probe[k].clone();
    }
    // 有改动（派生层按整层重建收、可能换了绑定）：进程内刷新计数整份作废，分发器提交之后取走（`refresh.rs` 文件头）。
    if !unchanged {
        v[TALLY_KEY] = Tally::all().json();
    }
    Ok((v, changed))
}
