//! 写命令的新代实现（规划 §2.1 G7-3b；设计 §2.2「真相只有操作」、§3.4「新写入不带 v1 形状的数据」、§5.2「新写入按
//! 规范 ID」）。已接分发器（`dispatch.rs`「本机写命令」一节）；协议 3 的写命令（`store/legacy3` `local_write_body` 与
//! `store/sync2/*` 的 `*_on`）不再经分发器调用（冻结）。
//!
//! 本文件是底座与「拼操作」一组：[Session]（一条写命令的事务、写入者、索引与回包）、`apply` / `import_drafts` /
//! `purge` / `checkpoint` / `resolve`。意图命令（`note_fields_if`、`change`、`merge_notes`、`deck_delete`、`sched`）
//! 在 `writes_intent.rs`，本机状态类（`trust`、`device_hint`、`status`、`dedup`、`digest_heal`）在 `writes_local.rs`，
//! 时间线恢复（`restore`，与只读的预览 `plan_restore`）在 `writes_restore.rs`。
//!
//! # 共同约定
//!
//! - **一条命令一个事务**（[write]）：调用方没开事务就由 [Truth::tx] 开一个（开头 [Truth::reset]，规划 §1.2 G-1）；
//!   调用方已在事务里就开 SAVEPOINT。命令本体报错 = 整笔回滚（操作、链尾、`self_.hlc`、派生表一个都不留），会话
//!   reset。读现值与写入在同一个事务里，中间插不进别的写入（协议 3 的「判定与落库同一笔」原样保留）。
//! - **作者是本机身份**：每条操作经 [Native::write]（G7-3a）落原生日志——seq / 链 / 依赖 / HLC 都由它定，HLC 带
//!   `now`（内核不读系统时钟）。一条命令中途本机身份被换掉（G8-6 `rotate_identity`），下一条写入报错、整笔回滚，不会
//!   用旧设备 ID 接着写。集合没有本机身份 = 报错（协议 3 的 `Local::create` 自动建身份；新代的身份由迁移 / 建库
//!   时 `create_self` 建，写命令不偷偷建）。
//! - **只写协议 4 原生能收的形**（设计 §3.4）：修改不带旧戳、日志不带旧 HLC / 旧服务器时刻（[native_body4] 与
//!   `native_allowed` 两道关）。所以：
//!   - 输入项的 `stamped`（带来源身份的外来修改 / 日志，协议 3 并入旧 profile 用）一律拒：换代后外来数据经并入
//!     （G9 `collection_join` / `adopt_foreign`）进来，不在本机日志里冒充；
//!   - 日志事件里的 `hlc` 丢掉（协议 3 存成 `legacy_hlc`）：原生日志的排序键（卡片历史规则 `crate::history` 按 HLC
//!     排、按 HLC 认同一事件的副本）是操作自己的 HLC；**Anki 来源的日志例外**：它的 HLC 由来源数据派生（铁律 C，
//!     `crate::anki_import_rules` [derived_log_hlc]，与 Dart 导入器写的 `srsImportedRevlogHlc` / `srsImportAnchorHlc`
//!     逐字相同），在日志投影（`cache.rs` `log_body`）与回包 `logHlcs` 里派生，不落进操作——输入里带的 `hlc` 照样丢；
//!     **回导的外来原生日志**（Dart `_remapExtLog` 打上 `foreignLog: true` 的）同理按发生时刻派生 `{at}:0:fushi`（第五波，
//!     规划 §6）：作者 HLC 不进操作，排序键也不随导入时刻 / 导入设备变；
//!   - 旧版时钟（`legacyDevice` / `recvNow` / `tickNow` / 输入项的 `clk`）不再存在（设计 §2.4 删旧写入者状态），这些
//!     键收到也不看；要旧版时钟戳的 `stamps: true` 明确拒绝；
//!   - 不认识的事件（协议 3 存成 `LegacyUnknown`）明确拒绝：那是协议 1 的残留，新写入不生成。
//! - **按规范 ID 写**（D5，规划 §1.5）：输入里的 ID（实体、修改键与值里嵌的 ID、日志的卡 / 笔记 / `revokes`、标签的
//!   笔记）先按这个集合的别名表归一（`alias.rs` [Index::canonical]，命令开始时已收好的那张表），再写。不做「映射到已
//!   有别名成员」的过渡层。
//! - **实体归属闸**（BUG-5005，`writes_owner.rs`）：ID 不再加盐，同库别的集合的实体 ID 在这里虽然读不到，写下去却会成为
//!   悬空操作、等本集合之后并进那个集合时对它生效。调用方给实体 ID 的写命令（`apply_in` / `purge` / `sched`）在写之前
//!   问 [Session::foreign]：别的集合有、本集合一点痕迹都没有的实体不写（身份记录与 profile 设置实体的判法见
//!   `writes_owner.rs` 文件头）；`apply` 一族回包的 `foreign` 交回这些项的调用方输入下标（`import_drafts` 按筛掉初值
//!   之前的原输入计，同 `edits` 第 7 列）。
//! - **回包**：命令自己的键之外，[write] 统一补上 `changed`（`[种类, 规范实体 ID]`，碰过的实体）、`purged`（彻底清除的
//!   实体）、`replayed`（写了日志的卡）、`edits`（`[种类, 实体, 字段键, 设备, 序号, 值]`，撤销据它判断之后有没有
//!   被别人动过，与协议 3 同形）、`nextSeq`（本机身份日志的下一个 seq）与 `settled`（这条命令里派生层收尾的计数，
//!   缓存层重算了多少笔记 / 卡 / 统计行）。协议 3 的 `marks` / `diagnostics` 是投影表的落库细节，新代没有。
//!   S1c 起（交接说明「S1c 刷新计数与写回包」节）：
//!   - `edits` 每项第 7 列是**输入下标**：这条修改来自调用方输入的第几项（`apply` / `change` 的输入原样计，
//!     `import_drafts` 按筛掉初值之前的原输入计；意图命令自己拼的项、命令直接落的修改是 null）。值没变被丢掉的项不占位，
//!     所以 Dart 按下标认领，不再按 (种类, 实体, 字段键) 猜、不再逐条点查归一（实体与键已是规范形）。
//!   - `tagWrites`：整列表 `tags` 项展开成的标签操作每项报一条 `[输入下标, 规范笔记 ID, 设备, 最后一条操作的 seq]`
//!     （协议 3 的 `stamps` 给这一项的也是展开出的最后一条操作的身份）。不进 `edits`：它们不是修改记录，撤销记录器按
//!     差量撤标签（Dart `noteTags`）。
//!   - `logHlcs`（只在 `apply` 的请求带 `logHlcs: true` 时）：每条写下的日志 `[输入下标, 规范日志 ID, HLC]`，HLC 与
//!     `read` 的 `logs` 行里的 `hlc` 同形（原生日志是操作的 HLC，Anki 来源的是派生 HLC，见上「只写协议 4 原生能收的
//!     形」）。导入成批的日志不要它（回包会随日志数线性涨）。
//!   - 修改行（只在 `apply` / `import_drafts` / `change` 的请求带 `editRows: true` 时）：`edits` 里有输入下标的每项后面
//!     补三列 `[…, 行 JSON, 服务器时刻, 被盖掉]`，`tagWrites` 每项后面补两列 `[…, 行 JSON, 被盖掉]`——行是收尾之后这条
//!     修改 / 这条笔记合成的 `tags` 行在 `read` 的 `edits` 里的 `j` / `st`（同一个函数 [super::edit_rows] 出的，逐字
//!     相同）。**被盖掉**（第五波，交接 §38「第五波 导入与写接口」）是 bool：这一项被同批后面的写入盖掉了——同一 (种类,
//!     实体, 字段键) 后面还有一条修改（标签是同一条笔记后面还有一次整列表写入）、或这个实体在这批里被彻底清除；这时行
//!     与服务器时刻是 null（标签项不给后面那次的合成行）。行是 null 却没标被盖掉 = 内核与调用方对不上（调用方报错）。
//!     调用方（Dart `_emit(stamps: true)` 的 `_writtenEdits`）直接用它拼落库后的修改记录、跳过被盖掉的项（同一个键
//!     只交回最后一条），不在命令之后再发一条 `read edits` 回读（T1 `srs_write_preread_cost`）。
//!   - `entityWrites`（G9-7）：每条落下的身份记录 `[输入下标, 种类, 规范实体 ID]`（输入下标规则同 `edits`）。调用方
//!     按请求 ID 建实体（Dart `createDeck` / `createNote` / 内置实体），返回给上层的是这里的规范 ID，不拿请求 ID 当
//!     结果：请求 ID 是别名类的成员时（迁移来的库里持久化的旧 ID、带盐的旧算法），两者不同。
//!   - `stamps: true` 仍然拒绝（要的是旧版时钟的戳）；替代形状就是上面几项。
//!   - 回包里还有一项 `refreshTally`（`refresh.rs` [TALLY_KEY]）：这条命令落下的变化类别，分发器提交之后取走、推进进程内
//!     刷新计数，**不交给 Dart**。
//!
//! # 读现值
//!
//! 意图命令与 `chg` / 标签展开要读「此刻的值」：一律经派生层按别名类读（`class.rs` [Index::class_lines] /
//! [Index::class_tags]，缓存层同一份），读之前把这条命令已写的操作收尾（[Session::settled]）——所以「先写后读」读到的
//! 是包含本命令前面写入的状态，与协议 3 逐条投影之后再读相同。批内只为「需要读」收尾，纯日志的作答批不收尾到最后。

use std::collections::{BTreeSet, HashMap, HashSet};

use rusqlite::params;
use serde_json::{Map, Value, json};

use super::super::cache::CFG_KEY;
use super::super::derive::{Index, Ref, Settled};
use super::super::native::Native;
use super::super::refresh::{TALLY_KEY, Tally};
use super::super::schema::sql;
use super::super::truth::Truth;
use super::{profile_of, ref_of, with_profile};
use crate::anki_import_rules::{anki_source_hlc, derived_log_hlc};
use crate::gen4::translate::native_body4;
use crate::registers::{self, StoredEdit};
use crate::store::caches::NoteInfo;
use crate::store::sync2::config::{self, DeckTree};
use crate::store::sync2::{body_of_event, canonical};
use crate::sync2::id::{Id, Key};
use crate::sync2::op::{Body, EditBody, EntKind, Intent, LogBody};
use crate::sync2::replay::SNAPSHOT_KEY;
use crate::sync2::vv::OpId;

#[path = "writes_owner.rs"]
mod owner;
use owner::Batch;
pub(super) use owner::Born;

/// 一个实体的修改行（寄存器内核的落库行 JSON + server_time），`registers` 的输入。
pub(super) type Lines = Vec<(String, Option<i64>)>;

pub(super) fn stored(v: &[(String, Option<i64>)]) -> Vec<StoredEdit<'_>> {
    config::stored(v)
}

/// 一条写命令的会话：本机身份的写入者、这个集合的索引、回包里统一的那几项（见文件头「回包」）。
pub struct Session<'t, 'c> {
    pub(super) t: &'t Truth<'c>,
    pub(super) col: i64,
    /// 这个集合绑定的 profile uid：行 JSON 的分区键 `p`（与读命令同口径，`cmd/mod.rs`）。
    pub(super) profile: String,
    ix: Index<'t, 'c>,
    native: Native<'t, 'c>,
    /// 上次收尾之后写过操作。
    dirty: bool,
    /// 牌组树（日志的配置快照用）；落过非日志操作就作废重读（协议 3 `stamp_local_config` 同口径）。
    tree: Option<DeckTree>,
    edits: Vec<Value>,
    changed: BTreeSet<(String, String)>,
    purged: BTreeSet<(String, String)>,
    replayed: BTreeSet<String>,
    settled: Settled,
    written: u64,
    /// 正在落的操作来自调用方输入的第几项（[apply_in] 设、落完清；意图命令自己拼的项、命令直接落的操作是 None）：进
    /// 回包 `edits` 每项的第 7 列与 `tagWrites` / `logHlcs` 的第 1 列（文件头「回包」）。
    at: Option<usize>,
    /// 刷新计数要的变化类别（`refresh.rs` [Tally]）：每条操作按种类记，[Session::finish] 写进回包，分发器提交之后取走。
    tally: Tally,
    /// 整列表标签项展开成的标签操作，每项一条 `[输入下标, 规范笔记 ID, 设备, 最后一条操作的 seq]`。
    tag_writes: Vec<Value>,
    /// 请求带 `logHlcs: true` 时（[apply]）：写下的每条日志 `[输入下标, 规范日志 ID, HLC]`。None = 不报。
    log_hlcs: Option<Vec<Value>>,
    /// 落下的身份记录，每条 `[输入下标, 种类, 规范实体 ID]`（文件头「回包」`entityWrites`）。
    entity_writes: Vec<Value>,
    /// 请求带 `editRows: true`：收尾时给 `edits` / `tagWrites` 补上落库修改行（文件头「回包」，[Session::attach_rows]）。
    edit_rows: bool,
    /// 库里有没有别的集合（实体归属闸 [Session::foreign] 用；None = 还没问过）。
    others: Option<bool>,
    /// 落下的修改记录进不进回包 `edits`（默认进）。`change` 的换类型段（`writes_retype.rs`）关掉它：那一段由内核自己拼、
    /// 可能是整个牌组的字段值，宿主用不上，回传只会让宿主把整批内容再解码一遍（BUG-5176）。
    echo_edits: bool,
}

/// 一条写命令（见文件头「一条命令一个事务」）：[f] 在 [Session] 里做命令本体，返回命令自己的回包（JSON 对象）；
/// 这里补上统一的那几项。回包带 `stale: true` 的（`apply` 的前置条件不成立）原样返回、什么都没写。
pub fn write<'c>(
    t: &Truth<'c>,
    col: i64,
    f: impl FnOnce(&mut Session<'_, 'c>) -> Result<Value, String>,
) -> Result<Value, String> {
    t.tx(|t| {
        let mut s = Session::open(t, col)?;
        let mut v = f(&mut s)?;
        if v.get("stale") == Some(&Value::Bool(true)) {
            if s.written > 0 {
                return Err("gen4 write: a stale command wrote ops".to_owned());
            }
            return Ok(v);
        }
        s.finish(&mut v)?;
        Ok(v)
    })
}

impl<'t, 'c> Session<'t, 'c> {
    fn open(t: &'t Truth<'c>, col: i64) -> Result<Session<'t, 'c>, String> {
        let profile = profile_of(t, col)?;
        let native = Native::open(t, col)?;
        Ok(Session {
            t,
            col,
            profile,
            ix: Index::new(t, col),
            native,
            dirty: false,
            tree: None,
            edits: Vec::new(),
            changed: BTreeSet::new(),
            purged: BTreeSet::new(),
            replayed: BTreeSet::new(),
            settled: Settled::default(),
            written: 0,
            at: None,
            tally: Tally::default(),
            tag_writes: Vec::new(),
            log_hlcs: None,
            entity_writes: Vec::new(),
            edit_rows: false,
            others: None,
            echo_edits: true,
        })
    }

    /// 请求带 `editRows: true` 就在回包里补上落库修改行（文件头「回包」）。
    pub(super) fn want_edit_rows(&mut self, req: &Value) {
        self.edit_rows = req.get("editRows") == Some(&Value::Bool(true));
    }

    /// 之后落下的修改记录进不进回包 `edits`（[Session::echo_edits] 字段）。
    pub(super) fn set_echo_edits(&mut self, on: bool) {
        self.echo_edits = on;
    }

    /// 本机身份（作者）的设备 ID。
    pub(super) fn device(&self) -> Id {
        self.native.device()
    }

    /// 只查别名表的读（规范 ID）：不要求收尾，读的是命令开始时（或上次收尾时）的别名表。
    pub(super) fn ix(&self) -> &Index<'t, 'c> {
        &self.ix
    }

    /// 先把这条命令已写的操作收尾，再交出索引（按类读、读缓存表之前都走这里）。
    pub(super) fn settled(&mut self) -> Result<&mut Index<'t, 'c>, String> {
        if self.dirty {
            let st = self.ix.settle()?;
            absorb(&mut self.settled, &st);
            self.dirty = false;
        }
        Ok(&mut self.ix)
    }

    /// 派生层整个重建（`digest_heal`）：之后的读与收尾都基于重建结果。
    pub(super) fn rebuild(&mut self) -> Result<Settled, String> {
        let st =
            super::super::ingest::ingest_settle(self.t, &mut self.ix, self.col, ingest_mode())?;
        absorb(&mut self.settled, &st);
        self.dirty = false;
        self.tree = None;
        // 整层重建：按刷新键记的缓存全部作废。
        self.tally.invalidate();
        Ok(st)
    }

    /// 本机改了某台设备的信任状态：告诉派生层，收尾时重判扣住的删除与清除（`weigh.rs` [Index::trust_changed]）。
    pub(super) fn trust_changed(&mut self) {
        // 可见性变了（协议 3 按回包 `changed` 记进内容计数）：不是牌组 / 配置事件，RWKV 分数表不整表重查。
        self.tally.landed = true;
        self.tally.content = true;
        self.tally.stats = true;
        self.ix.trust_changed();
        self.dirty = true;
        self.tree = None;
    }

    // ------------------------------------------------------------ 写

    /// 落一条本机操作（协议 3 形的操作体：命令层的拼法与协议 3 共用）。先归一 ID（文件头「按规范 ID 写」），再转成
    /// 协议 4 原生操作体（[native_body4]：带旧戳 / 旧 HLC 的拒），经 [Native::write] 写。
    pub(super) fn land(&mut self, body: Body, now: i64) -> Result<OpId, String> {
        let body = self.canon_body(body)?;
        let note = |kind: EntKind, e: &Key| (kind.wire().to_owned(), e.text());
        match &body {
            Body::Entity { kind, id, .. } => {
                self.changed.insert(note(*kind, id));
                self.entity_writes
                    .push(json!([self.at, kind.wire(), id.text()]));
            }
            Body::Edit(e) => {
                self.changed.insert(note(e.kind, &e.entity));
            }
            Body::TagAdd { note: n, .. }
            | Body::TagRemove { note: n, .. }
            | Body::TagOrder { note: n, .. } => {
                self.changed.insert(note(EntKind::Note, n));
            }
            Body::Purge { kind, entity } => {
                self.changed.insert(note(*kind, entity));
                self.purged.insert(note(*kind, entity));
            }
            Body::Log(l) => {
                self.replayed.insert(l.card.text());
            }
            _ => {}
        }
        self.append(body, now)
    }

    /// 写下一条已归一的操作体（[Session::land] 的后半段：不再归一、不记回包的 `changed` / `purged`）。[Session::purge_class]
    /// 给类里的带盐成员各落一条清除时直接用它：那几条点名的是原值成员，不能归一回规范 ID。
    fn append(&mut self, body: Body, now: i64) -> Result<OpId, String> {
        if !matches!(body, Body::Log(_)) {
            self.tree = None;
        }
        self.tally.op(&body);
        let edit = match &body {
            Body::Edit(e) => Some((e.kind, e.entity.text(), e.key.clone(), e.value.clone())),
            _ => None,
        };
        // 派生排序键要用到写下后那条操作的 HLC（外来日志的上界，[derived_log_hlc]），先留下派生要的字段。
        let log = match &body {
            Body::Log(l) if self.log_hlcs.is_some() => Some((
                l.id.text(),
                l.origin.clone(),
                l.kind.clone(),
                l.anki_id,
                l.at,
                l.extra.clone(),
            )),
            _ => None,
        };
        let b4 = native_body4(body)?;
        let (id, _) = self.native.write(&mut self.ix, b4, now)?;
        self.dirty = true;
        self.written += 1;
        if let Some((kind, entity, key, value)) = edit.filter(|_| self.echo_edits) {
            self.edits.push(json!([
                kind.wire(),
                entity,
                key,
                id.device.text(),
                id.seq,
                serde_json::from_str::<Value>(&value).unwrap_or(Value::Null),
                self.at,
            ]));
        }
        if let Some((log_id, origin, kind, anki_id, at, extra)) = log {
            // 与 `read` 的 `logs` 行里的 `hlc` 同口径（`cache.rs` `log_body` / `log_at`）：Anki 来源与回导的外来原生日志是由
            // 来源数据派生的 HLC，其余原生日志是它那条操作的 HLC（文件头「只写协议 4 原生能收的形」）。操作刚写下、按主键点读；
            // Anki 来源的派生不看操作，省掉这次读。
            let text = match anki_source_hlc(&origin, &kind, anki_id, at) {
                Some(text) => text,
                None => {
                    let hlc = self
                        .t
                        .entry(self.col, &id)?
                        .and_then(|e| e.op().map(|o| o.hlc))
                        .ok_or_else(|| {
                            format!("gen4 write: log {log_id} is not readable after append")
                        })?;
                    derived_log_hlc(&origin, &kind, anki_id, at, &extra, hlc.wall).unwrap_or_else(
                        || format!("{}:{}:{}", hlc.wall, hlc.logical, id.device.text()),
                    )
                }
            };
            if let Some(out) = self.log_hlcs.as_mut() {
                out.push(json!([self.at, log_id, text]));
            }
        }
        Ok(id)
    }

    /// 收尾，补上统一的回包项（文件头「回包」）。
    fn finish(&mut self, v: &mut Value) -> Result<(), String> {
        let st = self.native.finish(&mut self.ix)?;
        absorb(&mut self.settled, &st);
        self.dirty = false;
        // 派生层判成「已清除」的操作在真相层落成空洞（设计 §3.2；`weigh.rs` [Index::execute_purges]）：本机的 `purge`、
        // 改信任放开了扣住的清除都在这里执行，同一个事务。发件按日志里的空洞条数重切、重传（`cmd/sync.rs` 已传水位）。
        if self.ix.execute_purges()? > 0 {
            self.tally.landed = true;
            self.tally.content = true;
            self.tally.stats = true;
        }
        if self.edit_rows {
            self.attach_rows()?;
        }
        let next = self.t.last_of(self.col, &self.native.device())? + 1;
        if !v.is_object() {
            *v = json!({});
        }
        let pairs = |s: &BTreeSet<(String, String)>| -> Value {
            Value::Array(s.iter().map(|(k, e)| json!([k, e])).collect())
        };
        let m = v.as_object_mut().expect("object");
        m.insert("changed".into(), pairs(&self.changed));
        m.insert("purged".into(), pairs(&self.purged));
        m.insert("replayed".into(), json!(self.replayed));
        m.insert(
            "edits".into(),
            Value::Array(std::mem::take(&mut self.edits)),
        );
        m.insert(
            "tagWrites".into(),
            Value::Array(std::mem::take(&mut self.tag_writes)),
        );
        m.insert(
            "entityWrites".into(),
            Value::Array(std::mem::take(&mut self.entity_writes)),
        );
        if let Some(logs) = self.log_hlcs.take() {
            m.insert("logHlcs".into(), Value::Array(logs));
        }
        m.insert(TALLY_KEY.into(), self.tally.json());
        m.insert("nextSeq".into(), json!(next));
        m.insert(
            "settled".into(),
            json!({
                "cacheNotes": self.settled.cache_notes,
                "cacheCards": self.settled.cache_cards,
                "cacheStats": self.settled.cache_stats,
                // 这条命令里别名表整表重算的次数（诊断；`alias.rs`「重算与增量」，C8）。
                "aliasRebuilds": self.settled.aliases_rebuilt,
            }),
        );
        Ok(())
    }

    /// 给回包 `edits` 里有输入下标的每项补上 `[行 JSON, 服务器时刻]`、`tagWrites` 每项补上 `[行 JSON]`（文件头「回包」
    /// 修改行）。在收尾之后调：行与之后一条 `read edits` 读到的逐字相同（同一个 [super::edit_rows]，按类判定活着的行）。
    /// 每个碰过的实体只读一次。
    fn attach_rows(&mut self) -> Result<(), String> {
        let mut want: BTreeSet<(String, String)> = BTreeSet::new();
        for e in &self.edits {
            if e[6].is_null() {
                continue;
            }
            if let (Some(k), Some(id)) = (e[0].as_str(), e[1].as_str()) {
                want.insert((k.to_owned(), id.to_owned()));
            }
        }
        for tw in &self.tag_writes {
            if let Some(id) = tw[1].as_str() {
                want.insert((EntKind::Note.wire().to_owned(), id.to_owned()));
            }
        }
        let mut rows: HashMap<(String, String), Vec<(String, String, Option<i64>)>> =
            HashMap::with_capacity(want.len());
        for (k, id) in want {
            let kind = EntKind::parse(&k)
                .ok_or_else(|| format!("gen4 write: unknown entity kind {k} in edits"))?;
            let r = super::edit_rows(self.t, &mut self.ix, kind, &ref_of(&id), &self.profile)?;
            rows.insert((k, id), r);
        }
        let row_of = |k: &str, id: &str, pick: &dyn Fn(&str, &Value) -> bool| -> Value {
            rows.get(&(k.to_owned(), id.to_owned()))
                .and_then(|r| {
                    r.iter().find(|(f, j, _)| {
                        serde_json::from_str::<Value>(j).is_ok_and(|v| pick(f, &v))
                    })
                })
                .map_or(json!([null, null]), |(_, j, st)| json!([j, st]))
        };
        // 被同批后面的写入盖掉（文件头「回包」修改行）：同一 (种类, 实体, 字段键) 后面还有一条修改、或这个实体在这批里被
        // 彻底清除。按位置判，不按「行找不到」猜——找不到又不是被盖掉的，照样给 null、不标，调用方当契约不符报错。
        let purged = &self.purged;
        let edit_key = |e: &Value| -> (String, String, String) {
            (
                e[0].as_str().unwrap_or("").to_owned(),
                e[1].as_str().unwrap_or("").to_owned(),
                e[2].as_str().unwrap_or("").to_owned(),
            )
        };
        let keys: Vec<(String, String, String)> = self.edits.iter().map(edit_key).collect();
        for (i, e) in self.edits.iter_mut().enumerate() {
            if e[6].is_null() {
                continue;
            }
            let (k, id, _) = &keys[i];
            let (device, seq) = (e[3].clone(), e[4].clone());
            let found = row_of(k, id, &|_, v| v["w"] == device && v["s"] == seq);
            let superseded = found[0].is_null()
                && (keys[i + 1..].contains(&keys[i]) || purged.contains(&(k.clone(), id.clone())));
            if let (Some(arr), Value::Array(pair)) = (e.as_array_mut(), found) {
                arr.extend(pair);
                arr.push(Value::Bool(superseded));
            }
        }
        let notes: Vec<String> = self
            .tag_writes
            .iter()
            .map(|tw| tw[1].as_str().unwrap_or("").to_owned())
            .collect();
        let note_kind = EntKind::Note.wire().to_owned();
        for (i, tw) in self.tag_writes.iter_mut().enumerate() {
            let id = &notes[i];
            // 同一条笔记后面还有一次整列表标签写入：合成的 `tags` 行是后面那次的结果，不是这一项写下的。
            let superseded =
                notes[i + 1..].contains(id) || purged.contains(&(note_kind.clone(), id.clone()));
            let row = if superseded {
                Value::Null
            } else {
                row_of(&note_kind, id, &|f, _| f == "tags")[0].clone()
            };
            if let Some(arr) = tw.as_array_mut() {
                arr.push(row);
                arr.push(Value::Bool(superseded));
            }
        }
        Ok(())
    }

    // ------------------------------------------------------------ 归一

    pub(super) fn canon(&self, k: &Key) -> Result<Key, String> {
        Ok(key_of(&self.ix.canonical(&Ref::of(k))?))
    }

    /// 彻底清除实体 [entity] 的**整个别名类**（所有者拍板「清整个别名类」，设计 §10 第 19 条同源；`class.rs` 文件头
    /// 「没有并起来的」）：规范 ID 那一条照常经 [Session::land]（回包的 `changed` / `purged` 记规范 ID），类里此刻已知的
    /// 每个别的成员（带盐别名，`Index::class_of`）各落一条点名原值成员的 `Purge`。
    ///
    /// 为什么是「每个成员一条」而不是让一条清除在读侧覆盖整类：清除在索引层与真相层都按原值实体生效（`weigh.rs`
    /// `purge_ix`、`truth.rs` `purge_covering`），语义摘要也按原值 ID 记、不过别名表（`digest.rs`）。让一条清除按类生效，
    /// 就把各设备各自的别名表（信任状态不同时可以不同，设计 §10 第 18 条）带进了清除结果与摘要，两台设备对同一批操作会
    /// 算出不同的摘要。每个成员一条清除是普通操作：同步到别的设备，它按同一条按原值实体的规则清掉同一批成员，不依赖它的
    /// 别名表。代价：写的那一刻本机还不知道的成员（之后才随别的设备的承袭段出现的带盐成员）不在这批里。
    pub(super) fn purge_class(
        &mut self,
        kind: EntKind,
        entity: &str,
        now: i64,
    ) -> Result<(), String> {
        // 先收尾：同一批前面的操作可能刚改过别名表，成员按收好的表取。
        let ix = self.settled()?;
        let members = ix.class_of(&ref_of(entity))?;
        let canon = key_of(&members[0]);
        self.land(
            Body::Purge {
                kind,
                entity: canon.clone(),
            },
            now,
        )?;
        for m in &members[1..] {
            let member = key_of(m);
            if member != canon {
                self.append(
                    Body::Purge {
                        kind,
                        entity: member,
                    },
                    now,
                )?;
            }
        }
        Ok(())
    }

    /// 文本 ID 的规范形。
    pub(super) fn canon_text(&self, s: &str) -> Result<String, String> {
        Ok(self.ix.canonical(&ref_of(s))?.text())
    }

    fn canon_body(&self, body: Body) -> Result<Body, String> {
        let ix = &self.ix;
        Ok(match body {
            Body::Entity { kind, id, data } => {
                let d: Value =
                    serde_json::from_str(&data).map_err(|e| format!("gen4 write: {e}"))?;
                Body::Entity {
                    kind,
                    id: self.canon(&id)?,
                    data: canonical(&ix.canonical_json(&d)?),
                }
            }
            Body::Edit(e) => {
                let key = ix.canonical_key(&e.key)?;
                let v: Value =
                    serde_json::from_str(&e.value).map_err(|x| format!("gen4 write: {x}"))?;
                Body::Edit(EditBody {
                    entity: self.canon(&e.entity)?,
                    value: canonical(&ix.canonical_value(&key, &v)?),
                    key,
                    ..e
                })
            }
            Body::Log(mut l) => {
                l.id = self.canon(&l.id)?;
                l.card = self.canon(&l.card)?;
                l.note = l.note.as_ref().map(|n| self.canon(n)).transpose()?;
                l.revokes = l.revokes.as_ref().map(|r| self.canon(r)).transpose()?;
                Body::Log(l)
            }
            Body::TagAdd { note, tag } => Body::TagAdd {
                note: self.canon(&note)?,
                tag,
            },
            Body::TagRemove { note, tag } => Body::TagRemove {
                note: self.canon(&note)?,
                tag,
            },
            Body::TagOrder { note, tags } => Body::TagOrder {
                note: self.canon(&note)?,
                tags,
            },
            Body::Purge { kind, entity } => Body::Purge {
                kind,
                entity: self.canon(&entity)?,
            },
            other => other,
        })
    }

    // ------------------------------------------------------------ 读现值

    /// 一个实体（任何别名）按类判定活着的修改行（规范形）。读之前收尾（文件头「读现值」）。
    pub(super) fn lines(&mut self, kind: EntKind, id: &str) -> Result<Lines, String> {
        let ix = self.settled()?;
        Ok(ix.class_lines(kind, &ref_of(id))?.0)
    }

    /// 一条笔记此刻的视图（协议 3 `caches::note_infos` 的新代版：身份记录的胜者 + 按类判定的修改 + 标签 OR-Set）。
    /// 不存在 / 不是笔记 / 身份记录不成形 = None（缓存层同口径，`cache.rs` 文件头「与协议 3 的差别」）。`id` 字段是
    /// 规范 ID。
    pub(super) fn note_info(&mut self, id: &str) -> Result<Option<NoteInfo>, String> {
        let r = ref_of(id);
        let ix = self.settled()?;
        let Some((kind, _, payload)) = ix.definition(&r)? else {
            return Ok(None);
        };
        if kind != EntKind::Note as i64 {
            return Ok(None);
        }
        let canon = ix.canon(&r)?;
        let (lines, _) = ix.class_lines(EntKind::Note, &canon)?;
        let Ok(mut view) = registers::note_view_of(&payload, &stored(&lines)) else {
            return Ok(None);
        };
        view["t"] = json!(ix.class_tags(&canon)?);
        Ok(Some(NoteInfo::of(&canon.text(), &view)))
    }

    /// 一条笔记（任何别名）的卡片缓存行，按卡 ID：(卡, 模板, cloze 序号, 隐藏, 牌组)。缓存层没配置（宿主没给缓存
    /// 配置、`cards` 不物化）时报错——这些命令要的「此刻有哪些卡」只有缓存层知道，静默当成没有卡会写错。
    pub(super) fn note_cards(&mut self, note: &str) -> Result<Vec<CardRow>, String> {
        self.require_caches()?;
        let n = ref_of(note);
        let (col, canon) = {
            let ix = self.settled()?;
            (ix.col, ix.canon(&n)?)
        };
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT id, template_id, cloze_ord, hidden, deck_id FROM cards \
                 WHERE col = ?1 AND note_id = ?2 ORDER BY id",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![col, canon], |r| {
                Ok(CardRow {
                    card: r.get::<_, Ref>(0)?.text(),
                    template: r.get::<_, Ref>(1)?.text(),
                    ord: r.get(2)?,
                    hidden: r.get::<_, i64>(3)? != 0,
                    deck: r.get::<_, Ref>(4)?.text(),
                })
            })
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    /// 缓存层没配置就报错（见 [Session::note_cards]）。
    pub(super) fn require_caches(&self) -> Result<(), String> {
        if self.t.derive_cfg(self.col, CFG_KEY)?.is_none() {
            return Err("gen4 write: the caches are not configured for this collection".to_owned());
        }
        Ok(())
    }

    /// 默认牌组（规范 ID）：缓存配置给了就用它（归一后，与缓存层同一个），否则是规范规则的内置默认牌组（常量）。
    pub(super) fn default_deck(&self) -> Result<String, String> {
        super::default_deck(self.t, &self.ix, self.col)
    }

    /// 此刻的牌组树（未删除的牌组，ID 是规范 ID；[super::deck_tree]）。命令里落过非日志操作就重读。
    pub(super) fn deck_tree(&mut self) -> Result<&DeckTree, String> {
        if self.tree.is_none() {
            let default = self.default_deck()?;
            let ix = self.settled()?;
            self.tree = Some(super::deck_tree(ix, default)?);
        }
        Ok(self.tree.as_ref().expect("tree just loaded"))
    }

    /// 卡（规范 ID）的有效牌组（只读规则 [super::card_deck]；读之前先收尾，同 [Session::lines]）。
    pub(super) fn card_deck(&mut self, card: &str, note: Option<&str>) -> Result<String, String> {
        self.deck_tree()?;
        let tree = self.tree.take().expect("tree just loaded");
        let r = self
            .settled()
            .and_then(|ix| super::card_deck(ix, &tree, card, note));
        self.tree = Some(tree);
        r
    }

    /// 本机新写的派生日志记下此刻的生效配置（协议 3 `stamp_config`；重放按它算，改配置不追溯）。`Absolute` 意图的
    /// 日志（结果照抄）不盖。
    pub(super) fn stamp_config(&mut self, l: &mut LogBody) -> Result<(), String> {
        if matches!(l.intent, Intent::Absolute) {
            return Ok(());
        }
        let card = self.canon_text(&l.card.text())?;
        let note = l
            .note
            .as_ref()
            .map(|n| self.canon_text(&n.text()))
            .transpose()?;
        let deck = self.card_deck(&card, note.as_deref())?;
        let cfg = self.deck_tree()?.config(&deck).to_json();
        let mut extra: Map<String, Value> = match serde_json::from_str::<Value>(&l.extra) {
            Ok(Value::Object(m)) => m,
            _ => Map::new(),
        };
        extra.insert(SNAPSHOT_KEY.into(), cfg);
        l.extra = canonical(&Value::Object(extra));
        Ok(())
    }
}

/// 卡片缓存的一行（[Session::note_cards]）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct CardRow {
    pub(super) card: String,
    pub(super) template: String,
    pub(super) ord: i64,
    pub(super) hidden: bool,
    pub(super) deck: String,
}

fn ingest_mode() -> super::super::ingest::Settle {
    super::super::ingest::Settle::Rebuild
}

pub(super) fn key_of(r: &Ref) -> Key {
    match r {
        Ref::Uuid(b) => Key::Uuid(Id(*b)),
        Ref::Text(s) => Key::Text(s.clone()),
    }
}

/// 把一次收尾的计数加进总数。
fn absorb(total: &mut Settled, s: &Settled) {
    total.registers += s.registers;
    total.judged += s.judged;
    total.entities += s.entities;
    total.logs += s.logs;
    total.closures += s.closures;
    total.purged += s.purged;
    total.holds += s.holds;
    total.notes += s.notes;
    total.media += s.media;
    total.scanned += s.scanned;
    total.aliases += s.aliases;
    total.aliases_proven += s.aliases_proven;
    total.aliases_rebuilt += s.aliases_rebuilt;
    total.digests += s.digests;
    total.cache_notes += s.cache_notes;
    total.cache_cards += s.cache_cards;
    total.cache_stats += s.cache_stats;
}

pub(super) fn now_of(req: &Value) -> Result<i64, String> {
    req.get("now")
        .and_then(Value::as_i64)
        .ok_or_else(|| "gen4 write: missing now".to_owned())
}

/// 测试注入：请求带 `failAfter: <段>` 时在做完那一段之后报错（验证整笔回滚；生产调用方不带）。协议 3 的意图命令
/// 同一个约定。
pub(super) fn fail_after(req: &Value, stage: &str) -> Result<(), String> {
    if req["failAfter"].as_str() == Some(stage) {
        return Err(format!("gen4 write: injected failure after {stage}"));
    }
    Ok(())
}

// ---------------------------------------------------------------------- apply

/// [apply_in] 的选项。
#[derive(Clone, Copy, Debug, Default)]
pub(super) struct ApplyOpts<'a> {
    /// 收不收 `chg` 项（`import_drafts` 不收）。
    pub(super) chg: bool,
    /// `chg` 筛掉的项不进 `landed`（协议 3 `change_on` 先就地筛掉输入项再走 `apply`，`landed` 只对留下的项）。
    pub(super) compact: bool,
    /// 输入项与调用方输入的对应（回包里的输入下标，[Session::at]）。
    pub(super) origin: Origin<'a>,
}

/// [apply_in] 的输入项是调用方的哪几项。
#[derive(Clone, Copy, Debug, Default)]
pub(super) enum Origin<'a> {
    /// 就是调用方的输入（`apply`、`change`）：第 i 项 = 输入第 i 项。
    #[default]
    Caller,
    /// 调用方输入筛掉一些之后留下的（`import_drafts` 的初值筛选）：第 i 项 = 输入第 `kept[i]` 项。
    Kept(&'a [usize]),
    /// 命令自己拼的（意图命令）：没有输入下标。
    Synthesized,
}

impl Origin<'_> {
    fn of(self, at: usize) -> Option<usize> {
        match self {
            Origin::Caller => Some(at),
            Origin::Kept(kept) => kept.get(at).copied(),
            Origin::Synthesized => None,
        }
    }
}

/// 一项输入解析出的操作体，与它带的标记。
struct Item {
    body: Body,
    chg: bool,
    /// 卡片修改带的笔记（输入的 `note`，调用方声明「这张卡是这条笔记的」）：这条修改再跟着笔记过实体归属闸
    /// （`writes_owner.rs` 文件头「判据」），笔记被拒时它一并不写。只读卡片修改的；日志的笔记在 [Body::Log] 里。
    card_note: Option<Key>,
}

/// 协议 3 的修改记录草稿（Dart `_applyInput` 为一条草稿发的那一项，意图命令拼输入用）。
pub(super) fn draft(
    profile: &str,
    kind: &str,
    entity: &str,
    key: &str,
    v: &Value,
    ts: &str,
) -> Value {
    json!({
        "e": {"t": "edit", "x": {"p": profile, "k": kind, "e": entity, "f": key, "v": v, "ts": ts}},
        "note": Value::Null,
    })
}

/// 一项输入 → 协议 3 形的操作体（文件头「只写协议 4 原生能收的形」）。
fn parse_item(it: &Value) -> Result<Item, String> {
    if it["stamped"] == Value::Bool(true) {
        return Err(
            "apply: stamped items carry a foreign identity; in gen4 they come in through a collection join"
                .to_owned(),
        );
    }
    let ev = &it["e"];
    if !matches!(ev["t"].as_str(), Some("entity" | "edit" | "log")) {
        return Err(format!(
            "apply: event type {:?} is not written by gen4",
            ev["t"]
        ));
    }
    let body = body_of_event(ev, it["note"].as_str(), false, None)?;
    let body = match (body, it["intent"].as_str()) {
        (Body::Log(mut l), Some("answer")) => {
            l.intent = Intent::Answer;
            Body::Log(l)
        }
        (_, Some(other)) => return Err(format!("apply: unknown intent {other}")),
        (b, None) => b,
    };
    let body = match body {
        Body::Log(mut l) => {
            l.legacy_hlc = None;
            l.legacy_server_time = None;
            Body::Log(l)
        }
        b => b,
    };
    let chg = it["chg"] == Value::Bool(true);
    let card_note = match &body {
        Body::Edit(e) if e.kind == EntKind::Card => it["note"].as_str().map(Key::of),
        _ => None,
    };
    if chg {
        if !matches!(body, Body::Edit(_)) {
            return Err("apply: chg on an item that is not an edit".into());
        }
        if it["init"] == Value::Bool(true) {
            return Err("apply: chg cannot be combined with init / stamped".into());
        }
    }
    Ok(Item {
        body,
        chg,
        card_note,
    })
}

/// `apply` 的本体（协议 3 `apply_local_on` 的新代版），在 [s] 里做；意图命令拼好输入也走这里。回包
/// `{"landed": [每项落没落], "foreign": [下标]}`，`landed` 与 [items] 等长：`chg` 筛掉的、标签写入展开为空的、指向别的
/// 集合的实体的（实体归属闸，`writes_owner.rs`）是 false，它们的**调用方输入下标**进 `foreign`（与 `edits` 第 7 列同一
/// 口径，[Origin]：`import_drafts` 按筛掉初值之前的原输入计——导入路径按它认出被拒的笔记、记进导入报告，BUG-5005；意图
/// 命令自己拼的项没有输入下标，按 [items] 里的位置计）。
///
/// - `chg`（store/sync2/changing.rs 的判据，[registers::write_is_noop]）：值没变的修改不写；同一批里同一个
///   (种类, 实体, 字段键) 按顺序判，后一项比前一项写下的值。
/// - 标签是 OR-Set：整列表 `tags` 按与此刻的值的差拆成添加 / 观察删除 + 一条显示顺序（协议 3 `expand_tags`）；此刻
///   的值含这一批前面写下的标签。
/// - 非 `Absolute` 的日志盖此刻的配置快照（[Session::stamp_config]）。
pub(super) fn apply_in(
    s: &mut Session<'_, '_>,
    now: i64,
    items: &[Value],
    opts: ApplyOpts<'_>,
) -> Result<Value, String> {
    let mut parsed = Vec::with_capacity(items.len());
    for it in items {
        let item = parse_item(it)?;
        if item.chg && !opts.chg {
            return Err("import_drafts: chg items are not accepted".into());
        }
        // 归一提前做：`chg` 与标签的判定按规范的 (种类, 实体, 键) 比。
        let body = s.canon_body(item.body)?;
        let card_note = item.card_note.as_ref().map(|n| s.canon(n)).transpose()?;
        parsed.push(Item {
            body,
            card_note,
            ..item
        });
    }
    let keep = drop_noops(s, &parsed)?;
    // 实体归属闸（`writes_owner.rs`）：身份记录先各自过闸（牌组按同批的名字 / 父牌组自证）；过了闸的、这一批要建的实体
    // 算本集合的（同批先后到）。
    let mut entity_foreign = vec![false; parsed.len()];
    let mut born = Born::new();
    let batch = Batch::of(parsed.iter().map(|i| &i.body));
    for (at, item) in parsed.iter().enumerate() {
        if !keep[at] {
            continue;
        }
        if let Body::Entity { kind, id, data } = &item.body {
            if s.foreign_record(*kind, &id.text(), data, &batch)? {
                entity_foreign[at] = true;
            } else {
                born.insert(id.text());
            }
        }
    }
    let mut foreign: Vec<usize> = Vec::new();
    // 标签：这一批要碰的笔记此刻的标签（批内写过的按批内的算，见 [expand_tags]）。
    let mut tags_now: HashMap<String, Vec<String>> = HashMap::new();
    let mut landed = vec![false; parsed.len()];
    for (at, item) in parsed.into_iter().enumerate() {
        if !keep[at] {
            continue;
        }
        let theirs = match &item.body {
            Body::Entity { .. } => entity_foreign[at],
            b => {
                s.foreign_body(b, &born)?
                    || match &item.card_note {
                        Some(n) => s.foreign(EntKind::Note, &n.text(), &born)?,
                        None => false,
                    }
            }
        };
        if theirs {
            foreign.push(opts.origin.of(at).unwrap_or(at));
            continue;
        }
        s.at = opts.origin.of(at);
        // 已有的实体再发一遍身份记录：照样追加（同协议 3），但不算「落了」——协议 3 的 `landed` 是「投影里有东西
        // 变了」，身份记录只在实体第一次出现时投影（`Marks::entity`）。批内前面刚建的同一个实体也算已有。
        if let Body::Entity { id, .. } = &item.body {
            let existed = s.settled()?.definition(&Ref::of(id))?.is_some();
            s.land(item.body, now)?;
            landed[at] = !existed;
            continue;
        }
        // 整列表标签：展开成的标签操作在回包 `tagWrites` 里报一项（最后一条操作的 dot），不进 `edits`（不是修改记录）。
        let tags_of = match &item.body {
            Body::Edit(e) if e.kind == EntKind::Note && e.key == "tags" => Some(e.entity.text()),
            _ => None,
        };
        let bodies = match item.body {
            Body::Edit(e) if e.kind == EntKind::Note && e.key == "tags" => {
                expand_tags(s, &mut tags_now, e)?
            }
            Body::Log(mut l) => {
                s.stamp_config(&mut l)?;
                vec![Body::Log(l)]
            }
            b => vec![b],
        };
        let mut last = None;
        for b in bodies {
            last = Some(s.land(b, now)?);
            landed[at] = true;
        }
        if let (Some(note), Some(id)) = (tags_of, last) {
            s.tag_writes
                .push(json!([s.at, note, id.device.text(), id.seq]));
        }
    }
    s.at = None;
    if opts.compact {
        let landed: Vec<bool> = landed
            .into_iter()
            .zip(&keep)
            .filter(|(_, k)| **k)
            .map(|(l, _)| l)
            .collect();
        return Ok(json!({"landed": landed, "foreign": foreign}));
    }
    Ok(json!({"landed": landed, "foreign": foreign}))
}

/// `chg` 筛选（见 [apply_in]）：每项留不留。
fn drop_noops(s: &mut Session<'_, '_>, items: &[Item]) -> Result<Vec<bool>, String> {
    let mut keep = vec![true; items.len()];
    if !items.iter().any(|i| i.chg) {
        return Ok(keep);
    }
    // 这一批前面的项给 (种类, 实体, 键) 写下的值。
    let mut written: HashMap<(EntKind, String, String), Value> = HashMap::new();
    let mut current: HashMap<(EntKind, String), Lines> = HashMap::new();
    for (at, it) in items.iter().enumerate() {
        let Body::Edit(e) = &it.body else { continue };
        let slot = (e.kind, e.entity.text(), e.key.clone());
        let value: Value = serde_json::from_str(&e.value).unwrap_or(Value::Null);
        if it.chg {
            let noop = match written.get(&slot) {
                Some(prev) => *prev == value,
                None if e.kind == EntKind::Note && e.key == "tags" => {
                    tags_unchanged(s, &e.entity.text(), &value)?
                }
                None => {
                    let ent = (e.kind, e.entity.text());
                    if !current.contains_key(&ent) {
                        let l = s.lines(e.kind, &ent.1)?;
                        current.insert(ent.clone(), l);
                    }
                    registers::write_is_noop(&stored(&current[&ent]), &e.key, &value)?
                }
            };
            keep[at] = !noop;
        }
        written.insert(slot, value);
    }
    Ok(keep)
}

/// `chg` 的整列表 `tags` 项「没变」（[drop_noops]）。协议 3 的投影给碰过标签的每条笔记写一行合成的 `tags` 修改行，值
/// 是此刻的标签（`semantics.rs` `tags_row`），`write_is_noop` 拿它逐值比；新代的修改行里没有这行（标签是 `tag_ix`
/// 的 OR-Set，缓存层直接给结果），所以照协议 3 的口径单独判：这条笔记（别名类）有过标签操作（= 协议 3 有那行合成
/// 行），且此刻的标签（[Index::class_tags]）与 [value] 逐值相同。从没碰过标签的笔记没有那行，协议 3 判「变了」，这里同。
fn tags_unchanged(s: &mut Session<'_, '_>, note: &str, value: &Value) -> Result<bool, String> {
    let ix = s.settled()?;
    let canon = ix.canon(&ref_of(note))?;
    let mut touched = false;
    for m in ix.members(&canon)? {
        if !ix.tags_rows(&m)?.is_empty() {
            touched = true;
            break;
        }
    }
    if !touched {
        return Ok(false);
    }
    let now = Value::from(ix.class_tags(&canon)?);
    Ok(registers::same_value(&now, value))
}

/// 整列表 `tags` → OR-Set 操作（协议 3 `expand_tags` 同一份拼法）。[tags_now] 记这一批里每条笔记写到哪了。
fn expand_tags(
    s: &mut Session<'_, '_>,
    tags_now: &mut HashMap<String, Vec<String>>,
    e: EditBody,
) -> Result<Vec<Body>, String> {
    let note = e.entity.text();
    let cur = match tags_now.get(&note) {
        Some(t) => t.clone(),
        None => {
            let ix = s.settled()?;
            ix.class_tags(&ref_of(&note))?
        }
    };
    let want: Vec<String> = match serde_json::from_str::<Value>(&e.value) {
        Ok(Value::Array(xs)) => xs
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect(),
        _ => Vec::new(),
    };
    let mut out: Vec<Body> = Vec::new();
    for tag in want.iter().filter(|x| !cur.contains(x)) {
        out.push(Body::TagAdd {
            note: e.entity.clone(),
            tag: tag.clone(),
        });
    }
    for tag in cur.iter().filter(|x| !want.contains(x)) {
        out.push(Body::TagRemove {
            note: e.entity.clone(),
            tag: tag.clone(),
        });
    }
    let mut seen = BTreeSet::new();
    let order: Vec<String> = want
        .iter()
        .filter(|t| seen.insert((*t).clone()))
        .cloned()
        .collect();
    if order != cur || !out.is_empty() {
        out.push(Body::TagOrder {
            note: e.entity.clone(),
            tags: order.clone(),
        });
    }
    tags_now.insert(note, order);
    Ok(out)
}

/// `apply` 的前置条件 `expectLast: {card, log}`（远程作答核对基准，协议 3 `store/ffi.rs` `expect_last_holds`）：这张卡
/// 的缓存行还在、且它最后一条生效日志就是 `log`（null = 还没有日志）。不带 = 成立。按规范 ID 比。
fn expect_last_holds(s: &mut Session<'_, '_>, req: &Value) -> Result<bool, String> {
    let Some(expect) = req.get("expectLast").filter(|e| e.is_object()) else {
        return Ok(true);
    };
    let card = expect["card"]
        .as_str()
        .ok_or("apply: missing expectLast.card")?;
    let card = ref_of(&s.canon_text(card)?);
    let col = s.col;
    let last: Option<Option<Ref>> = {
        let ix = s.settled()?;
        let mut stmt =
            ix.t.conn()
                .prepare_cached("SELECT last_log_id FROM cards WHERE col = ?1 AND id = ?2")
                .map_err(sql)?;
        let mut rows = stmt.query(params![col, card]).map_err(sql)?;
        match rows.next().map_err(sql)? {
            Some(r) => Some(r.get::<_, Option<Ref>>(0).map_err(sql)?),
            None => None,
        }
    };
    let want = expect["log"]
        .as_str()
        .map(|l| s.canon_text(l))
        .transpose()?;
    Ok(last.is_some_and(|l| l.map(|r| r.text()) == want))
}

/// `apply`（协议 3 `local_write_body` 的 `apply` 分支 + `expectLast`）。[req]：`{"now", "expectLast"?}`；[items]：输入
/// 项（JSON 数组，同协议 3）。前置条件不成立 = `{"stale": true}`、什么都不写。
pub fn apply(t: &Truth<'_>, col: i64, req: &Value, items: &[Value]) -> Result<Value, String> {
    let now = now_of(req)?;
    if req.get("stamps") == Some(&Value::Bool(true)) {
        return Err(
            "apply: stamps belong to the protocol 3 legacy clock, which gen4 does not keep"
                .to_owned(),
        );
    }
    write(t, col, |s| {
        if !expect_last_holds(s, req)? {
            return Ok(json!({"stale": true}));
        }
        if req.get("logHlcs") == Some(&Value::Bool(true)) {
            s.log_hlcs = Some(Vec::new());
        }
        s.want_edit_rows(req);
        apply_in(
            s,
            now,
            items,
            ApplyOpts {
                chg: true,
                compact: false,
                origin: Origin::Caller,
            },
        )
    })
}

/// `import_drafts`（导入攒的一批草稿，协议 3 `import_drafts_on`）：[apply_in] 的本体，外加
///
/// - 输入项 `init: true` 是「新建实体的初值」：这个 (种类, 实体, 字段键) 落库这一刻已经有活着的修改（攒批期间同步
///   把对端的同一实体应用进来了）就不落——判据是这一批写之前的库；
/// - 回包 `existed`：这批身份记录里落库前就已存在的实体 ID（按调用方给的 ID，升序去重）。
///
/// 不收 `chg` 项。`landed` 按去掉不落的项之后的顺序（同协议 3）。
pub fn import_drafts(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    items: &[Value],
) -> Result<Value, String> {
    let now = now_of(req)?;
    write(t, col, |s| {
        s.want_edit_rows(req);
        let mut existed: BTreeSet<String> = BTreeSet::new();
        for it in items {
            if it["e"]["t"].as_str() != Some("entity") {
                continue;
            }
            let Some(id) = it["e"]["x"]["id"].as_str() else {
                continue;
            };
            let ix = s.settled()?;
            if ix.definition(&ref_of(id))?.is_some() {
                existed.insert(id.to_owned());
            }
        }
        let is_init =
            |it: &Value| it["init"] == Value::Bool(true) && it["e"]["t"].as_str() == Some("edit");
        let mut authored: HashSet<(String, String, String)> = HashSet::new();
        let mut seen: HashSet<(String, String)> = HashSet::new();
        for it in items.iter().filter(|it| is_init(it)) {
            let x = &it["e"]["x"];
            let (Some(k), Some(e)) = (x["k"].as_str(), x["e"].as_str()) else {
                continue;
            };
            if !seen.insert((k.to_owned(), e.to_owned())) {
                continue;
            }
            let kind = EntKind::parse(k).ok_or("import_drafts: unknown entity kind")?;
            for (json, _) in s.lines(kind, e)? {
                let v: Value = serde_json::from_str(&json).unwrap_or(Value::Null);
                if let Some(f) = v["f"].as_str() {
                    authored.insert((k.to_owned(), e.to_owned(), f.to_owned()));
                }
            }
        }
        let mut kept: Vec<Value> = Vec::with_capacity(items.len());
        let mut kept_at: Vec<usize> = Vec::with_capacity(items.len());
        for (at, it) in items.iter().enumerate() {
            if is_init(it) {
                let x = &it["e"]["x"];
                if let (Some(k), Some(e), Some(f)) =
                    (x["k"].as_str(), x["e"].as_str(), x["f"].as_str())
                {
                    // 活着的修改行的键是规范形；输入的键归一了再比。
                    let f = s.ix().canonical_key(f)?;
                    if authored.contains(&(k.to_owned(), e.to_owned(), f)) {
                        continue;
                    }
                }
            }
            kept.push(it.clone());
            kept_at.push(at);
        }
        let mut v = apply_in(
            s,
            now,
            &kept,
            ApplyOpts {
                chg: false,
                compact: false,
                origin: Origin::Kept(&kept_at),
            },
        )?;
        v["existed"] = json!(existed);
        Ok(v)
    })
}

/// `purge`（彻底清除一批同类实体，协议 3 `local_write_body` 的 `purge` 分支）：每个实体「删除 + 清除」，按输入顺序，
/// 一笔落下；清除覆盖实体的整个别名类（[Session::purge_class]：规范 ID 一条 + 每个带盐成员一条）。[req]：`{"now", "kind", "entities": [...]}`（非空）。不存在 / 已清除过的照常追加（清除幂等）；
/// 别的集合的实体（实体归属闸，`writes_owner.rs`）不写，回包 `foreign` 交回它们在 `entities` 里的下标。
pub fn purge(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let kind = req["kind"].as_str().ok_or("purge: missing kind")?;
    let entities = req
        .get("entities")
        .and_then(Value::as_array)
        .filter(|e| !e.is_empty())
        .ok_or("purge: missing entities")?;
    let mut bodies = Vec::with_capacity(entities.len());
    for e in entities {
        let e = e.as_str().ok_or("purge: entity is not a string")?;
        bodies.push(crate::store::sync2::purge_bodies(kind, e, now)?);
    }
    write(t, col, |s| {
        let mut foreign: Vec<usize> = Vec::new();
        for (at, pair) in bodies.into_iter().enumerate() {
            // 归属按归一后的实体判（清除操作体里那一条，删除与清除指向同一个实体）。
            let canon: Vec<Body> = pair
                .into_iter()
                .map(|b| s.canon_body(b))
                .collect::<Result<_, _>>()?;
            let mut theirs = false;
            for b in &canon {
                if s.foreign_body(b, &Born::new())? {
                    theirs = true;
                    break;
                }
            }
            if theirs {
                foreign.push(at);
                continue;
            }
            for b in canon {
                match b {
                    Body::Purge { kind, entity } => s.purge_class(kind, &entity.text(), now)?,
                    b => {
                        s.land(b, now)?;
                    }
                }
            }
        }
        Ok(json!({"foreign": foreign}))
    })
}

/// `checkpoint`（还原点）。[req]：`{"now", "name", "reason"}`。
pub fn checkpoint(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let name = req["name"].as_str().ok_or("checkpoint: missing name")?;
    let reason = req["reason"].as_str().ok_or("checkpoint: missing reason")?;
    write(t, col, |s| {
        for b in crate::store::sync2::checkpoint_bodies(name, reason) {
            s.land(b, now)?;
        }
        Ok(json!({}))
    })
}

/// 冲突 ID（协议 3 `semantics.rs` 写 `sync2_conflicts` 的同一个公式）：被扣住的删除的 (设备, seq) 与冲突类别。
pub(super) fn conflict_id(op: &OpId, kind: &str) -> String {
    blake3::hash(format!("{}:{}:{kind}", op.device.text(), op.seq).as_bytes()).to_hex()[..32]
        .to_owned()
}

/// `resolve`（裁决一个删除冲突，协议 3 `resolve_bodies`）：`delete` = 一条因果覆盖并发方的新删除；否则一条覆盖删除
/// 的恢复。[req]：`{"now", "conflict", "delete"?}`。冲突按 ID 在此刻被扣住的删除里找（新代的冲突就是
/// `hold_ix`，`weigh.rs` [Index::holds]；ID 与协议 3 同一个公式，[conflict_id]）；找不到 = 报错（协议 3 同）。
pub fn resolve(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let conflict = req["conflict"]
        .as_str()
        .ok_or("resolve: missing conflict")?;
    let delete = req["delete"] == Value::Bool(true);
    write(t, col, |s| {
        let ix = s.settled()?;
        let mut target: Option<(EntKind, String)> = None;
        for h in ix.holds()? {
            let kinds = [
                (h.edits, "delete_edit"),
                (h.reviews, "delete_review"),
                (h.moves, "delete_move"),
            ];
            if kinds
                .iter()
                .any(|(n, k)| *n > 0 && conflict_id(&h.op, k) == conflict)
            {
                target = Some((h.kind, h.entity.text()));
                break;
            }
        }
        let (kind, entity) = target.ok_or_else(|| format!("no such conflict {conflict}"))?;
        for b in crate::store::sync2::resolve_bodies(kind, &entity, delete, now) {
            s.land(b, now)?;
        }
        Ok(json!({}))
    })
}

/// 行 JSON 换上这个集合的 profile（读命令同一个约定）。
pub(super) fn row_with_profile(json: &str, profile: &str) -> Value {
    serde_json::from_str(&with_profile(json, profile)).unwrap_or(Value::Null)
}
