//! 身份命令（规划 §1.6、§2.2 G9-4；设计 §5.1、§5.4）：本机身份 `identity`、绑定状态 `binding_set`、集合信息
//! `collection_info`、并入 `collection_join`、补盐 `collection_salts_add`、外来数据认领 `collection_adopt`、按规范 ID
//! 归一 `canonical_ids`、分叉检测 `key_evidence` / `divergence`。存储层在 `store/gen4/identity.rs`（G9-3）与
//! `truth.rs`（绑定、本机身份）；这里只做请求解析、事务边界与回包。`binding_get` 在 `profile.rs`（G7-4e）。
//!
//! # 谁在什么时候建身份与绑定
//!
//! - **只有两处建**：`identity`（Dart 每次打开 profile 时调；协议 3 `sync2_identity` 同样「没有就建」）与
//!   `collection_adopt` 的 [AdoptOutcome::Bound]（profile 还没绑过、确认后直接绑到对方，设计 §5.4 第 5 条「先加入」）。
//!   其余命令遇到没绑定的 profile 照旧明确报错（`dispatch.rs` `col_of`），**不顺手建**：建绑定要一个可信的时刻
//!   （本机身份的建立时刻、`Salts` 的 HLC 起点），读命令与多数写命令的请求里没有 `now`，内核又不读系统时钟；而且
//!   顺手建会让「先加入」永远走不到（profile 一旦被别的命令绑了，认领就只能并入）。
//! - Dart 现在的打开顺序（`SrsDbStore.open`：`local_state` → `cache_config_set` → … → `identity`）在全新 profile 上
//!   会先撞到「没绑定」：G7-5 要把 `identity` 挪到第一条按集合的命令之前（交接说明「G9-4」一节的调用点清单）。
//! - 全新 profile 建的集合：集合标识 = `collection_of(profile)`（`v5(NS, "sync2/collection/{uid}")`）、位置目录名 =
//!   profile uid——与协议 3 的 `Local::create` 和迁移（`dryrun.rs` 的 `bind`）同一个口径。设计 §5.1 原写「新集合随机
//!   一个 UUIDv7」，这里有意偏离：同一个 uid 的两台设备（协议 3 时代采用过同一个 uid 的、D32 服务端 uid = 目录名的）
//!   不用并入就落在同一个集合里，与协议 3 行为一致；全新库与「迁移了一份空的协议 3 库」逐表相同，派生层只有一条路。
//! - 本机身份：随机的 UUIDv7 设备 ID（`migrate::random_device`）、随机签名钥匙，时钟从零起；同一个事务里在本机原生
//!   日志写一条 `Salts{profile uid}`（集合的盐集合里已有就不写）——与迁移写的初始盐同一口径（`legacy::salts` 的
//!   第一项）：Dart 在 G9-6 之前仍按 profile uid 加盐算内置实体的 ID（默认牌组等），盐在集合里才归得到规范 ID。
//! - Secondary（查词弹窗进程，只读）上没有身份时 `identity` 报只读：等主进程建。
//!
//! # 绑定变化的事件（规划缺口 G-4）
//!
//! 可能改绑定（集合标识、目录名、盐集合）的命令——`identity`（第一次建）、`collection_join`、`collection_salts_add`、
//! `collection_adopt`——的存储层结果一律经 [AdoptOutcome::binding_changed] / [JoinWritten::changed]（建身份时按
//! 前后的 [Binding] 比）取事件，交给分发器；分发器在**最外层事务提交成功之后**把它放进回包的 `bindingChanged`
//! （`{"profile": uid}`），提交失败 / 回滚就没有回包，事件随之丢掉（`dispatch.rs` `write_binding`）。回包就是这条
//! 事件流：Dart 的每条内核命令都经 `SrsDbStore` 的同一个入口，G7-5 在那里看到 `bindingChanged` 就发
//! `onBindingChanged()`（缓存的四个 ID 失效）。`binding_set` 只写绑定状态三列（`state` / `via` / `at`），不属于
//! [Binding]、不影响任何 ID，不发。
//!
//! # 回包
//!
//! - `identity` → `{device, collection, dir, nextSeq, migrated, name, public}`：协议 3 的 `device` / `collection` /
//!   `nextSeq` / `name` / `public` 原样（`nextSeq` = 本机原生日志末尾 + 1；`name` = `device_info` 的人读名），
//!   `migrated` 恒为 true（新代库本来就是迁移之后的，Dart 不再发已删的 `migrate`）；新增 `dir`（位置目录名，设计 §5.1
//!   「Dart 不再自己按 uid 拼同步目录，改成向内核要」）。协议 3 的 `legacyWriter`（旧协议 v1 写入者 ID，`legacy_clock.rs`）
//!   与 `channel`（有没做完的收段通道）新代没有对应物：**不回这两个键**（不回占位值：`legacyWriter` 的空值会让 Dart
//!   `writerId` 的非空断言在用到时才炸，缺键在 G7-5 改调用点时一眼可见）。请求里的 `legacyDevice` 忽略。
//! - `binding_set` → `{"binding": {state, via, at}}`，与协议 3 逐键相同（只进不退，[Truth::settle_binding]）。
//! - `collection_info` → `{profile, collection, dir, salts, binding, joins}`；`joins` 每项
//!   `{op: {device, seq}, from, dir, salts, trusted}`（[Index::joins]）。
//! - `collection_join` / `collection_salts_add` / `collection_adopt` → `{outcome, …}`（[outcome_json]）+ 有事件时的
//!   `bindingChanged`。
//! - `canonical_ids {ids}` → `{ids}`：逐个换成规范 ID（与键 / 值 / 缓存配置同口径：别名表查不到的带盐内置字段 /
//!   模板也按规则归一），顺序与条数照请求（不去重：调用方按下标对回）。每个 ID 一次
//!   带索引的单点查询（`alias.rs`），都在同一个读快照里：一次最多 [LOOKUP_MAX] 条，超了明确报错、调用方分批（整库
//!   ID 一次塞进来会长时间占着一个读连接）。`key_evidence` 同一个上限。
//! - `key_evidence {items: [{kind, entity}]}` → `{evidence: [n…]}`。**不归一**：这是拿另一台设备 `divergence` 列出的
//!   那个成员 ID 来问它的自然键证据（`alias.rs` [Index::key_evidence]），归一到规范 ID 会把要找的分叉抹平。
//! - `divergence` → `{hollowed: [{kind, entity, purges, distrusted, evidence, pending}], withheldSalts: [{salt, ops}]}`
//!   （[Index::hollowed] / [Index::withheld_salts]；UI 是 D30，归 G10）。
//!
//! # 事务与读快照
//!
//! 读命令（`collection_info` / `canonical_ids` / `key_evidence` / `divergence`）一个读快照；写命令在分发器的一个
//! `BEGIN IMMEDIATE` 事务里，存储层函数各自开 SAVEPOINT。没有新语句：查询全在 `truth.rs` / `identity.rs` / `alias.rs`
//! 的既有 API 里（各自已有查询计划测试）。

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::{hex, ref_of, snapshot};
use crate::store::gen4::derive::{Index, Ref, Settled};
use crate::store::gen4::identity::{
    AdoptOutcome, BindingChanged, Foreign, JoinRow, JoinWritten, adopt_foreign,
};
use crate::store::gen4::ingest::{Settle, ingest_settle};
use crate::store::gen4::migrate::random_device;
use crate::store::gen4::native::Native;
use crate::store::gen4::truth::{BindStage, Binding, Truth};
use crate::store::sync2::collection_of;
use crate::sync2::id::Id;
use crate::sync2::keys::DeviceKey;
use crate::sync2::op::EntKind;
use crate::sync2::vv::OpId;

/// 一条可能改绑定的命令的结果：回包与绑定变化（分发器提交后发，模块文件头「绑定变化的事件」）。
pub type Emitting = (Value, Option<BindingChanged>);

fn op_json(id: &OpId) -> Value {
    json!({"device": id.device.text(), "seq": id.seq})
}

fn settled_json(s: &Settled) -> Value {
    json!({"cacheNotes": s.cache_notes, "cacheCards": s.cache_cards, "cacheStats": s.cache_stats})
}

fn now_of(req: &Value, op: &str) -> Result<i64, String> {
    req.get("now")
        .and_then(Value::as_i64)
        .ok_or_else(|| format!("{op}: missing now"))
}

fn str_of<'a>(req: &'a Value, k: &str, op: &str) -> Result<&'a str, String> {
    req.get(k)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{op}: missing {k}"))
}

fn id_of(req: &Value, k: &str, op: &str) -> Result<Id, String> {
    let s = str_of(req, k, op)?;
    Id::parse(s).ok_or_else(|| format!("{op}: bad {k} {s}"))
}

/// 请求里的盐（字符串数组；缺省 = 空）。
fn salts_of(req: &Value, op: &str) -> Result<BTreeSet<String>, String> {
    let Some(v) = req.get("salts") else {
        return Ok(BTreeSet::new());
    };
    v.as_array()
        .ok_or_else(|| format!("{op}: salts must be an array"))?
        .iter()
        .map(|s| {
            s.as_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("{op}: salts must be strings"))
        })
        .collect()
}

fn binding_of(t: &Truth<'_>, col: i64) -> Result<Binding, String> {
    t.binding(col)?
        .ok_or_else(|| format!("gen4 identity: no collection {col}"))
}

// ---------------------------------------------------------------------- identity

/// 本机在 [b] 里的身份回包（还没建本机身份 = None）。
fn view(t: &Truth<'_>, b: &Binding) -> Result<Option<Value>, String> {
    let Some(me) = t.self_identity(b.col)? else {
        return Ok(None);
    };
    Ok(Some(json!({
        "device": me.device.text(),
        "collection": b.collection.text(),
        "dir": b.dir,
        "nextSeq": t.last_of(b.col, &me.device)? + 1,
        "migrated": true,
        "name": super::writes_local::self_name(t, b.col)?,
        "public": hex(&me.public()),
    })))
}

/// `identity` 的只读路径：绑定与本机身份都在就回包（一个读快照），否则 None（分发器转写路径）。
pub fn identity_read(t: &Truth<'_>, profile: &str) -> Result<Option<Value>, String> {
    snapshot(t, |t| match t.binding_of(profile)? {
        Some(b) => view(t, &b),
        None => Ok(None),
    })
}

/// `identity` 的写路径（模块文件头「谁在什么时候建」）：没绑定就按 profile uid 建集合并绑定，没有本机身份就建，
/// 一个事务（SAVEPOINT，嵌在分发器的写事务里）。另一个调用方先建好了（读路径看到「没有」之后）就只是读。
pub fn identity_ensure(t: &Truth<'_>, profile: &str, now: i64) -> Result<Emitting, String> {
    if profile.is_empty() {
        return Err("identity: empty profile uid".to_owned());
    }
    t.tx(|t| {
        let before = t.binding_of(profile)?;
        let col = match &before {
            Some(b) => b.col,
            None => {
                // 这个 uid 的独立库刚并进共享库、app 还没把组合恢复继承（`collection_merge.rs` 文件头「墓碑」）：
                // 不给它另建一个空集合，否则在上面制的卡收尾之后就成了看不见的孤儿。
                if let Some(into) = super::collection_merge::pending_merge_of(t, profile)? {
                    return Err(format!(
                        "identity: library {profile} was merged into {into};                          the merge is not finished yet (collection_merge_done)"
                    ));
                }
                t.bind(profile, &collection_of(profile), profile)?
            }
        };
        ensure_self(t, col, profile, now, None)?;
        let after = binding_of(t, col)?;
        let changed = (before.as_ref() != Some(&after)).then(|| BindingChanged {
            profile: profile.to_owned(),
            col,
        });
        let v = view(t, &after)?
            .ok_or_else(|| format!("gen4 identity: collection {col} has no local identity"))?;
        Ok((v, changed))
    })
}

/// 预先定好的本机身份（设备 ID 与签名钥匙种子）：落库前就要知道本机身份的命令先生成它，绑定那一刻（[collection_adopt_with]
/// 的 `bound`）照它建，而不是另生成一个。
///
/// 用处（第五波 G9 身份收尾，交接 §25「没做」第 1 条）：旧备份读入（`cmd/backup.rs`）的副本身份由「目标集合的本机签名
/// 钥匙种子 + 输入摘要」派生（`seed_scratch_identity`），同一份输入再导一次才是已有的槽。覆盖还原把复习数据落进一个空库，
/// profile 在那里还没有绑定、也就没有本机身份：以前副本身份只能随机，绑定在落库事务里才建（随机钥匙），于是还原之后
/// **第一次**合并同一份旧输入以另一个合成设备再落一遍。现在分发器在备副本之前生成 [PendingSelf]、拿它的种子派生副本身份，
/// 落库时 profile 按它建本机身份：之后的合并读到的本机秘密就是同一个。
#[derive(Clone)]
pub struct PendingSelf {
    pub(crate) device: Id,
    pub(crate) seed: [u8; 32],
}

impl PendingSelf {
    /// 一个新的（随机设备 ID 与钥匙，与 [ensure_self] 自己建的同一种）。
    pub fn generate(profile: &str, now: i64) -> PendingSelf {
        PendingSelf {
            device: random_device(profile, now),
            seed: DeviceKey::generate().seed(),
        }
    }

    /// 沿用现有签名钥匙种子 [seed]、设备 ID 新生成的一份：profile 已绑定、但认领可能走「空集合可换绑」（`identity.rs`
    /// `rebind_empty` 丢掉本机的空集合、在对方集合里重建本机身份）的命令用它，换绑之后本机秘密仍是 [seed]。设备 ID 不沿用：
    /// 被丢掉的空集合导出过的话，它的设备号与序号可能已在别处出现，同一个设备号在新集合里从头记会撞号。钥匙只在本机，
    /// 空集合从没发布过（`discard.rs` `disposable`），沿用不扩大暴露面。
    pub fn carrying(profile: &str, now: i64, seed: [u8; 32]) -> PendingSelf {
        PendingSelf {
            device: random_device(profile, now),
            seed,
        }
    }

    /// 签名钥匙种子（副本身份的本机秘密）。
    pub fn seed(&self) -> &[u8; 32] {
        &self.seed
    }
}

/// 集合 [col] 还没有本机身份就建（模块文件头）：随机设备 ID 与签名钥匙（给了 [pending] 就用它），盐集合里没有
/// [profile] 就在本机原生日志写一条 `Salts{profile}`，收尾。返回建没建。
fn ensure_self(
    t: &Truth<'_>,
    col: i64,
    profile: &str,
    now: i64,
    pending: Option<&PendingSelf>,
) -> Result<bool, String> {
    if t.self_identity(col)?.is_some() {
        return Ok(false);
    }
    let fresh;
    let p = match pending {
        Some(p) => p,
        None => {
            fresh = PendingSelf::generate(profile, now);
            &fresh
        }
    };
    t.create_self(col, &p.device, &p.seed, None, now)?;
    if !binding_of(t, col)?.salts.contains(profile) {
        let mut ix = Index::new(t, col);
        Native::open(t, col)?.write_salts(&mut ix, &BTreeSet::from([profile.to_owned()]), now)?;
        ingest_settle(t, &mut ix, col, Settle::Incremental)?;
    }
    Ok(true)
}

/// 换绑丢掉的空集合里本机声明过的盐（[AdoptOutcome::Bound] 的 `carry`）：本机身份在新集合里建好之后，新集合还不算数的
/// 那几个由本机另写一条 `Salts`（同 [ensure_self] 写初始盐的口径）。旧整包备份读入（`cmd/backup.rs` `land`）在 `bound`
/// 之后也经这里声明备份 profile 的盐：那份输入自身不带 `Salts` 操作（位置 / `.fushisrs` 第 2 版的盐随对方的操作到）。
pub(super) fn declare_salts(
    t: &Truth<'_>,
    col: i64,
    carry: &BTreeSet<String>,
    now: i64,
) -> Result<(), String> {
    let have = binding_of(t, col)?.salts;
    let missing: BTreeSet<String> = carry.difference(&have).cloned().collect();
    if missing.is_empty() {
        return Ok(());
    }
    let mut ix = Index::new(t, col);
    Native::open(t, col)?.write_salts(&mut ix, &missing, now)?;
    ingest_settle(t, &mut ix, col, Settle::Incremental)?;
    Ok(())
}

// ---------------------------------------------------------------------- 绑定状态

/// `binding_set {state, via, now}`（协议 3 `store/binding.rs` 的同名命令，只进不退；状态认不出报错，什么都不写）。
pub fn binding_set(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let state = str_of(req, "state", "binding_set")?;
    let stage =
        BindStage::of_text(state).ok_or_else(|| format!("binding_set: unknown state {state}"))?;
    let via = str_of(req, "via", "binding_set")?;
    let at = now_of(req, "binding_set")?;
    let s = t.settle_binding(col, stage, via, at)?;
    Ok(json!({"binding": s.json()}))
}

// ---------------------------------------------------------------------- 集合

fn join_json(j: &JoinRow) -> Value {
    json!({
        "op": op_json(&j.op),
        "from": j.from.text(),
        "dir": j.dir,
        "salts": j.salts,
        "trusted": j.trusted,
    })
}

/// `collection_info`：集合 [col] 的标识、目录名、盐集合、绑定状态与日志里的全部 `Join`。一个读快照。
pub fn collection_info(t: &Truth<'_>, col: i64) -> Result<Value, String> {
    snapshot(t, |t| {
        let b = binding_of(t, col)?;
        let joins = Index::new(t, col).joins()?;
        Ok(json!({
            "profile": b.profile,
            "collection": b.collection.text(),
            "dir": b.dir,
            "salts": b.salts,
            "binding": t.binding_state(col)?.map(|s| s.json()),
            "joins": joins.iter().map(join_json).collect::<Vec<_>>(),
        }))
    })
}

/// 位置目录名的长度上限（字节；常见文件系统单个名字 255 字节）。超了不可能是哪个集合的目录。
pub const DIR_MAX: usize = 255;

/// `profile_of_dir`（G10-4，规划 §1.1 G10 行「`profile_of_dir(dir)` 由 `collection_info` 反查提供」）：不针对单个
/// profile 的读。请求 `{dir}`，回 `{profiles: [uid, …]}`——当前**绑定**的位置目录名等于 [dir] 的本机 profile（按 uid
/// 排，没有 = 空表）。互联 host（无头服务端）收到已配对设备往 `fushi-srs/<dir>/…` 的写入，据此找该同步哪份 profile，
/// 不把目录名当 uid（并入 / 认领后两者不同，设计 §5.1 2026-11-17 修订）。
///
/// [dir] 来自对端写入的路径，不可信：不是字符串、空、`.` / `..`、含路径分隔符或超过 [DIR_MAX] 字节一律报错（不回空表，
/// 调用方据此区分「坏路径」与「没人绑这个目录」）。
pub fn profile_of_dir(t: &Truth<'_>, req: &Value) -> Result<Value, String> {
    let dir = req
        .get("dir")
        .ok_or("profile_of_dir: missing dir")?
        .as_str()
        .ok_or("profile_of_dir: dir must be a string")?;
    if dir.len() > DIR_MAX || !crate::gen4::location::dir_name_ok(dir) {
        return Err("profile_of_dir: bad dir".into());
    }
    snapshot(t, |t| Ok(json!({"profiles": t.profiles_of_dir(dir)?})))
}

fn written_json(w: &JoinWritten) -> Value {
    json!({
        "op": op_json(&w.op),
        "from": w.join.from.text(),
        "fromDir": w.join.dir,
        "rebound": w.rebound,
        "collection": w.binding.collection.text(),
        "dir": w.binding.dir,
        "settled": settled_json(&w.settled),
    })
}

/// 认领 / 并入的结论（[AdoptOutcome]）：`outcome` 是结论名，其余是写下的东西。
pub(crate) fn outcome_json(o: &AdoptOutcome) -> Value {
    match o {
        AdoptOutcome::Same => json!({"outcome": "same"}),
        AdoptOutcome::AlreadyJoined => json!({"outcome": "alreadyJoined"}),
        AdoptOutcome::NeedsConfirm => json!({"outcome": "needsConfirm"}),
        AdoptOutcome::Bound { .. } => json!({"outcome": "bound"}),
        AdoptOutcome::Joined { written, salts } => {
            let mut v = written_json(written);
            v["outcome"] = json!("joined");
            v["saltsOp"] = salts.as_ref().map_or(Value::Null, op_json);
            v
        }
        AdoptOutcome::SaltsAdded { op, settled, .. } => json!({
            "outcome": "saltsAdded",
            "op": op_json(op),
            "settled": settled_json(settled),
        }),
    }
}

/// `collection_join {into, dir, now}`：本机集合并入另一个集合（[Truth::join]：方向反了、目标已绑在本机别的 profile
/// 上等情形报错，什么都不写）。
pub fn collection_join(t: &Truth<'_>, col: i64, req: &Value) -> Result<Emitting, String> {
    let into = id_of(req, "into", "collection_join")?;
    let dir = str_of(req, "dir", "collection_join")?;
    let now = now_of(req, "collection_join")?;
    let w = t.join(col, &into, dir, now)?;
    let mut v = written_json(&w);
    v["outcome"] = json!("joined");
    Ok((v, w.changed.clone()))
}

/// `collection_salts_add {salts, now}`：让本机集合认下几个旧 uid（设计 §5.4 第 6 条「同一个集合在另一个旧 uid 下的
/// 数据只写 Salts」）。走 [adopt_foreign] 的「同一个集合」分支：盐都已算数 = `same`，否则写一条只含新盐的 `Salts`
/// = `saltsAdded`。判据与事件都只在 [adopt_foreign] 一处。
pub fn collection_salts_add(t: &Truth<'_>, col: i64, req: &Value) -> Result<Emitting, String> {
    let salts = salts_of(req, "collection_salts_add")?;
    let now = now_of(req, "collection_salts_add")?;
    let b = binding_of(t, col)?;
    let foreign = Foreign {
        collection: b.collection,
        dir: b.dir,
        salts,
    };
    let out = adopt_foreign(t, &b.profile, &foreign, true, now)?;
    Ok((outcome_json(&out), out.binding_changed().cloned()))
}

/// `collection_adopt {collection, dir, salts?, confirmed?, now}`：外来数据（导入的 `.fushisrs` 第 2 版、整包备份、
/// 位置上读到的 `meta.json` + 盐）声明了身份，按 [adopt_foreign] 认（`confirmed` 缺省 false：没问过用户只会答
/// `needsConfirm`，BUG-4011 / D25）。结论是 `bound`（profile 还没绑过）时同一个事务里建本机身份（模块文件头）。
pub fn collection_adopt(t: &Truth<'_>, profile: &str, req: &Value) -> Result<Emitting, String> {
    collection_adopt_with(t, profile, req, None)
}

/// [collection_adopt]，`bound` 时本机身份按 [pending] 建（[PendingSelf]；None = 现生成）。
pub fn collection_adopt_with(
    t: &Truth<'_>,
    profile: &str,
    req: &Value,
    pending: Option<&PendingSelf>,
) -> Result<Emitting, String> {
    let foreign = Foreign {
        collection: id_of(req, "collection", "collection_adopt")?,
        dir: str_of(req, "dir", "collection_adopt")?.to_owned(),
        salts: salts_of(req, "collection_adopt")?,
    };
    let confirmed = req.get("confirmed").and_then(Value::as_bool) == Some(true);
    let now = now_of(req, "collection_adopt")?;
    t.tx(|t| {
        let out = adopt_foreign(t, profile, &foreign, confirmed, now)?;
        if let AdoptOutcome::Bound { col, carry, .. } = &out {
            ensure_self(t, *col, profile, now, pending)?;
            declare_salts(t, *col, carry, now)?;
        }
        Ok((outcome_json(&out), out.binding_changed().cloned()))
    })
}

// ---------------------------------------------------------------------- 别名与分叉

/// `canonical_ids` / `key_evidence` 一次请求最多的条数（模块文件头「回包」）：每条一次带索引的单点查询、同一个
/// 读快照，上限卡住「整库 ID 一次传进来、长时间占着读连接」。调用方按这个数分批。
pub const LOOKUP_MAX: usize = 4096;

pub(super) fn lookup_cap(n: usize, op: &str) -> Result<(), String> {
    if n > LOOKUP_MAX {
        return Err(format!(
            "{op}: at most {LOOKUP_MAX} entries per request, got {n}; split into batches"
        ));
    }
    Ok(())
}

/// `canonical_ids {ids}`：逐个归一（规范 ID；不是 UUID 的、别名表里没有又不是内置实体存量 ID 的原样）。一个读快照。
///
/// 归一走 [Index::canonical_embedded]（先查别名表、查不到再按当前盐集合的内置规则认），与笔记视图里的键 / 值 / 宿主
/// 缓存配置同一个结论：调用方发来的 ID 可能是偏好里存的带盐内置字段 / 模板 ID（只嵌在 `f/<字段>` 键里、从不作为
/// 实体出现，别名表里没有），只查表会原样返回、与视图里的规范字段 ID 对不上。
pub fn canonical_ids(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let ids = req
        .get("ids")
        .and_then(Value::as_array)
        .ok_or("canonical_ids: ids must be an array")?;
    lookup_cap(ids.len(), "canonical_ids")?;
    snapshot(t, |t| {
        let ix = Index::new(t, col);
        let mut out = Vec::with_capacity(ids.len());
        for x in ids {
            let s = x.as_str().ok_or("canonical_ids: ids must be strings")?;
            let canon = match ref_of(s) {
                Ref::Uuid(b) => ix.canonical_embedded(&Id(b))?,
                other => other,
            };
            out.push(canon.text());
        }
        Ok(json!({"ids": out}))
    })
}

fn kind_of(s: &str, op: &str) -> Result<EntKind, String> {
    EntKind::parse(s).ok_or_else(|| format!("{op}: unknown kind {s}"))
}

/// `key_evidence {items: [{kind, entity}]}`：各实体在本机还算数的自然键证据条数（模块文件头：成员 ID 原样问，不归一）。
pub fn key_evidence(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let items = req
        .get("items")
        .and_then(Value::as_array)
        .ok_or("key_evidence: items must be an array")?;
    lookup_cap(items.len(), "key_evidence")?;
    snapshot(t, |t| {
        let ix = Index::new(t, col);
        let mut out = Vec::with_capacity(items.len());
        for it in items {
            let kind = kind_of(str_of(it, "kind", "key_evidence")?, "key_evidence")?;
            let entity = ref_of(str_of(it, "entity", "key_evidence")?);
            out.push(ix.key_evidence(kind, &entity)?);
        }
        Ok(json!({"evidence": out}))
    })
}

/// `divergence`：本机见过清除的、带自然键的实体（拿去另一台设备问 `key_evidence`）与只有本机不信任的作者带来的盐。
pub fn divergence(t: &Truth<'_>, col: i64) -> Result<Value, String> {
    snapshot(t, |t| {
        let mut ix = Index::new(t, col);
        let hollowed: Vec<Value> = ix
            .hollowed()?
            .iter()
            .map(|h| {
                json!({
                    "kind": h.kind.wire(),
                    "entity": h.entity.text(),
                    "purges": h.purges.iter().map(op_json).collect::<Vec<_>>(),
                    "distrusted": h.distrusted.iter().map(op_json).collect::<Vec<_>>(),
                    "evidence": h.evidence,
                    "pending": h.pending,
                })
            })
            .collect();
        let withheld: Vec<Value> = ix
            .withheld_salts()?
            .iter()
            .map(|(salt, ops)| json!({"salt": salt, "ops": ops.iter().map(op_json).collect::<Vec<_>>()}))
            .collect();
        Ok(json!({"hollowed": hollowed, "withheldSalts": withheld}))
    })
}
