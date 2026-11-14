// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 内核 → 宿主的出口：effect（要宿主取数 / 办事、按 id 回复）、事件与命令结果；以及 runtime 后端
//! （生产 = 内核自己持有的 [`RwkvRuntime`]；`backend = host` 的测试模式 = 把每次调用转给宿主）。
//! 消息的字节布局见 `mod.rs` 文件头。

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::path::Path;
use std::pin::Pin;
use std::rc::Rc;
use std::task::{Context, Poll};

use super::exec::Exec;
use super::wire::{Reader, Writer, le_i64, le_i64s, le_u64s};
use crate::{FrwkvReview, Model, RwkvError, RwkvRuntime, StatePrecision, query_input};

/// 一次失败：文本，加上它出自哪个 effect 的回复（0 = 内核自己）。宿主凭 `origin` 找回原始的异常对象。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Fault {
    pub text: String,
    pub origin: u32,
}

impl Fault {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            origin: 0,
        }
    }
}

impl From<std::io::Error> for Fault {
    fn from(error: std::io::Error) -> Self {
        Self::new(error.to_string())
    }
}

impl From<RwkvError> for Fault {
    fn from(error: RwkvError) -> Self {
        Self::new(error.to_string())
    }
}

impl std::fmt::Display for Fault {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.text)
    }
}

pub type R<T> = Result<T, Fault>;

fn wire(error: String) -> Fault {
    Fault::new(error)
}

// 输出记录的标签。
pub const OUT_STATUS: u8 = 1;
pub const OUT_DONE: u8 = 2;
pub const OUT_EFFECT: u8 = 3;
pub const OUT_LOG: u8 = 4;
pub const OUT_OP_BEGIN: u8 = 5;
pub const OUT_OP_END: u8 = 6;
pub const OUT_TIMER: u8 = 7;
pub const OUT_CANCEL: u8 = 8;

// effect 种类。
pub const FX_REVISION: u8 = 1;
pub const FX_TAIL: u8 = 2;
pub const FX_REPLAY: u8 = 3;
pub const FX_APPEND_ROWS: u8 = 4;
pub const FX_SCORE_INPUTS: u8 = 5;
pub const FX_QUERY_ROWS: u8 = 6;
pub const FX_INGESTING: u8 = 7;
pub const FX_INGEST_SETTLED: u8 = 8;
pub const FX_DAY_INDEX: u8 = 9;
pub const FX_MODEL_READY: u8 = 10;
pub const FX_DOWNLOAD: u8 = 11;
pub const FX_DELETE_RETIRED: u8 = 12;
pub const FX_REBUILD_HOOK: u8 = 13;
pub const FX_OPEN_BACKEND: u8 = 14;
pub const FX_BACKEND: u8 = 15;

// `FX_BACKEND` 的调用号（只在 `backend = host` 时出现）。
pub const BK_REPLAY: u8 = 1;
pub const BK_APPEND: u8 = 2;
pub const BK_UNAPPEND: u8 = 3;
pub const BK_REWIND: u8 = 4;
pub const BK_QUERY: u8 = 5;
pub const BK_CLEAR_SCORES: u8 = 6;
pub const BK_LOOKUP_SCORES: u8 = 7;
pub const BK_UPDATE_SCORES: u8 = 8;
pub const BK_REQUERY_SCORES: u8 = 9;
pub const BK_REMOVE_SCORES: u8 = 10;
pub const BK_SNAPSHOT_TO_FILE: u8 = 11;
pub const BK_RESTORE_FROM_FILE: u8 = 12;
pub const BK_RESET: u8 = 13;
pub const BK_CLOSE: u8 = 14;

/// 宿主对一个 effect 的回复：整条输入消息（内核拥有），正文从 `at` 开始。
pub struct Reply {
    pub buffer: Box<[u8]>,
    pub at: usize,
}

impl Reply {
    pub fn body(&self) -> &[u8] {
        &self.buffer[self.at..]
    }
}

enum Incoming {
    Reply(R<Reply>),
    Progress(i64, i64),
}

pub struct Host {
    pub exec: Rc<Exec>,
    out: RefCell<Writer>,
    next_effect: Cell<u32>,
    inbox: RefCell<HashMap<u32, VecDeque<Incoming>>>,
    next_op: Cell<u32>,
}

impl Host {
    pub fn new(exec: Rc<Exec>) -> Self {
        Self {
            exec,
            out: RefCell::new(Writer::default()),
            next_effect: Cell::new(1),
            inbox: RefCell::new(HashMap::new()),
            next_op: Cell::new(1),
        }
    }

    /// 取走攒下的输出记录。
    pub fn take_output(&self) -> Vec<u8> {
        std::mem::take(&mut self.out.borrow_mut().0)
    }

    pub fn deliver_reply(&self, id: u32, reply: R<Reply>) {
        self.inbox
            .borrow_mut()
            .entry(id)
            .or_default()
            .push_back(Incoming::Reply(reply));
        self.exec.signal();
    }

    pub fn deliver_progress(&self, id: u32, done: i64, total: i64) {
        self.inbox
            .borrow_mut()
            .entry(id)
            .or_default()
            .push_back(Incoming::Progress(done, total));
        self.exec.signal();
    }

    /// 写一条输出记录：标签、正文长度（u32）、正文。
    fn record(&self, tag: u8, write: impl FnOnce(&mut Writer)) {
        let mut out = self.out.borrow_mut();
        out.u8(tag).u32(0);
        let start = out.0.len();
        write(&mut out);
        let len = (out.0.len() - start) as u32;
        out.0[start - 4..start].copy_from_slice(&len.to_le_bytes());
    }

    pub fn status(
        &self,
        phase: u8,
        phase_changed: bool,
        done: i64,
        total: i64,
        error: Option<&Fault>,
    ) {
        self.record(OUT_STATUS, |out| {
            out.u8(phase)
                .bool(phase_changed)
                .i64(done)
                .i64(total)
                .bool(error.is_some());
            if let Some(error) = error {
                out.u32(error.origin).str(&error.text);
            }
        });
    }

    pub fn log(&self, message: &str) {
        self.record(OUT_LOG, |out| {
            out.str(message);
        });
    }

    /// 命令结果；成功时 `write` 写正文。
    pub fn done(&self, op: u32, result: R<()>, write: impl FnOnce(&mut Writer)) {
        self.record(OUT_DONE, |out| {
            out.u32(op).bool(result.is_ok());
            match result {
                Ok(()) => write(out),
                Err(error) => {
                    out.u32(error.origin).str(&error.text);
                }
            }
        });
    }

    /// 空闲存快照的定时器：`after_ms < 0` = 取消。
    pub fn timer(&self, generation: u32, after_ms: i64) {
        self.record(OUT_TIMER, |out| {
            out.u32(generation).i64(after_ms);
        });
    }

    /// 发一个 effect，返回它的 id。
    fn effect(&self, kind: u8, write: impl FnOnce(&mut Writer)) -> u32 {
        let id = self.next_effect.get();
        self.next_effect.set(id.wrapping_add(1).max(1));
        self.record(OUT_EFFECT, |out| {
            out.u32(id).u8(kind);
            write(out);
        });
        id
    }

    fn next(&self, id: u32) -> Next<'_> {
        Next { host: self, id }
    }

    async fn call(&self, kind: u8, write: impl FnOnce(&mut Writer)) -> R<Reply> {
        let id = self.effect(kind, write);
        loop {
            if let Incoming::Reply(reply) = self.next(id).await {
                self.inbox.borrow_mut().remove(&id);
                return reply.map_err(|mut fault| {
                    fault.origin = id;
                    fault
                });
            }
        }
    }

    // ------------------------------------------------------------------ 取数

    /// `SrsDbStore.changeFingerprint`。
    pub async fn revision(&self) -> R<String> {
        let reply = self.call(FX_REVISION, |_| {}).await?;
        Reader::new(reply.body()).str().map_err(wire)
    }

    /// 日志表指纹与尾巴（`SrsDbStore.rwkvLogTail`）。宿主在发查询的那一刻同步读内容修订号：等于
    /// `if_content` 就只数 `since_incremental` 之后的新行，否则按 `since_full` 整表数。
    pub async fn tail(
        &self,
        since_incremental: i64,
        since_full: i64,
        with_rows: bool,
        if_content: Option<&str>,
    ) -> R<Tail> {
        let reply = self
            .call(FX_TAIL, |w| {
                w.i64(since_incremental)
                    .i64(since_full)
                    .bool(with_rows)
                    .opt_str(if_content);
            })
            .await?;
        let mut r = Reader::new(reply.body());
        (|| {
            let content = r.str()?;
            let incremental = r.bool()?;
            let count = r.i64()?;
            let max_row_id = r.i64()?;
            let new_rows = r.i64()?;
            let n = r.u32()?;
            let mut logs = Vec::with_capacity(n as usize);
            for _ in 0..n {
                logs.push(TailLog {
                    id: r.str()?,
                    card_id: r.str()?,
                    kind: r.u8()?,
                    at: r.i64()?,
                    revokes: r.opt_str()?,
                });
            }
            Ok(Tail {
                content,
                incremental,
                count,
                max_row_id,
                new_rows,
                logs,
            })
        })()
        .map_err(wire)
    }

    /// 回放行（宿主的 `_fetchReplay` 整个：列卡、算身份、补漏掉的卡），回复正文是
    /// `ffsrs_store_rwkv_rows` 的原始字节。
    pub async fn replay(
        &self,
        since: i64,
        rebase_since: Option<i64>,
        rows_from: Option<i64>,
    ) -> R<Replay> {
        let reply = self
            .call(FX_REPLAY, |w| {
                w.i64(since).opt_i64(rebase_since).opt_i64(rows_from);
            })
            .await?;
        Replay::parse(reply).map_err(wire)
    }

    /// 追加用的行：每张卡末尾这几条日志各自的回放行，与撤销日志标签。
    pub async fn append_rows(
        &self,
        cards: &[(String, Vec<String>)],
        tags: &[&str],
    ) -> R<AppendRows> {
        let reply = self
            .call(FX_APPEND_ROWS, |w| {
                w.u32(cards.len() as u32);
                for (card, ids) in cards {
                    w.str(card).u32(ids.len() as u32);
                    for id in ids {
                        w.str(id);
                    }
                }
                w.u32(tags.len() as u32);
                for tag in tags {
                    w.str(tag);
                }
            })
            .await?;
        let mut r = Reader::new(reply.body());
        (|| {
            if r.bool()? {
                return Ok(AppendRows {
                    missing_card: true,
                    rows: Vec::new(),
                    tags: Vec::new(),
                });
            }
            let mut rows = Vec::with_capacity(cards.len());
            for (_, ids) in cards {
                if !r.bool()? {
                    rows.push(None);
                    continue;
                }
                let mut per_id = Vec::with_capacity(ids.len());
                for _ in ids {
                    per_id.push(r.bytes()?.to_vec());
                }
                rows.push(Some(per_id));
            }
            let tags = r.u64s()?;
            Ok(AppendRows {
                missing_card: false,
                rows,
                tags,
            })
        })()
        .map_err(wire)
    }

    /// 排队打分的输入：调度日、「每答几题刷新」、分数表的两把钥匙、候选卡的数字 id 与版本。
    pub async fn score_inputs(&self, op: u32, at_ms: i64) -> R<ScoreInputs> {
        let reply = self
            .call(FX_SCORE_INPUTS, |w| {
                w.u32(op).i64(at_ms);
            })
            .await?;
        let mut r = Reader::new(reply.body());
        (|| {
            Ok(ScoreInputs {
                today: r.i64()?,
                refresh_every: r.i64()?,
                clear_key: r.str()?,
                requery_key: r.str()?,
                ids: r.i64s()?,
                versions: r.u64s()?,
            })
        })()
        .map_err(wire)
    }

    /// 命令 `op` 的候选卡里 `indices`（`None` = 全部）在时刻 `at_ms` 的查询行与锚点。
    pub async fn query_rows(
        &self,
        op: u32,
        indices: Option<&[u32]>,
        at_ms: i64,
    ) -> R<(Vec<u8>, Vec<i64>)> {
        let reply = self
            .call(FX_QUERY_ROWS, |w| {
                w.u32(op).i64(at_ms).bool(indices.is_some());
                if let Some(indices) = indices {
                    w.u32(indices.len() as u32);
                    for i in indices {
                        w.u32(*i);
                    }
                }
            })
            .await?;
        let mut r = Reader::new(reply.body());
        (|| Ok((r.bytes()?.to_vec(), r.i64s()?)))().map_err(wire)
    }

    /// `SrsDbStore.sync2Ingesting`。
    pub async fn ingesting(&self) -> R<bool> {
        let reply = self.call(FX_INGESTING, |_| {}).await?;
        Reader::new(reply.body()).bool().map_err(wire)
    }

    /// `SrsDbStore.sync2IngestSettled`。
    pub async fn ingest_settled(&self) -> R<()> {
        self.call(FX_INGEST_SETTLED, |_| {}).await.map(|_| ())
    }

    /// 两个时刻各自的调度日序。
    pub async fn day_index(&self, a: i64, b: i64) -> R<(i64, i64)> {
        let reply = self
            .call(FX_DAY_INDEX, |w| {
                w.i64(a).i64(b);
            })
            .await?;
        let mut r = Reader::new(reply.body());
        (|| Ok((r.i64()?, r.i64()?)))().map_err(wire)
    }

    /// 权重是否就位，以及权重文件的路径。
    pub async fn model_ready(&self) -> R<(bool, String)> {
        let reply = self.call(FX_MODEL_READY, |_| {}).await?;
        let mut r = Reader::new(reply.body());
        (|| Ok((r.bool()?, r.str()?)))().map_err(wire)
    }

    /// 开始下载权重；之后用 [`Host::download_event`] 取进度与结果。
    pub fn download(&self) -> u32 {
        self.effect(FX_DOWNLOAD, |_| {})
    }

    /// `Ok(Some((done, total)))` = 进度；`Ok(None)` = 下完了。
    pub async fn download_event(&self, id: u32) -> R<Option<(i64, i64)>> {
        match self.next(id).await {
            Incoming::Progress(done, total) => Ok(Some((done, total))),
            Incoming::Reply(reply) => {
                self.inbox.borrow_mut().remove(&id);
                reply.map(|_| None).map_err(|mut fault| {
                    fault.origin = id;
                    fault
                })
            }
        }
    }

    /// 不再等这个 effect（宿主停掉对应的工作）。
    pub fn cancel(&self, id: u32) {
        self.inbox.borrow_mut().remove(&id);
        self.record(OUT_CANCEL, |out| {
            out.u32(id);
        });
    }

    pub async fn delete_retired(&self) -> R<()> {
        self.call(FX_DELETE_RETIRED, |_| {}).await.map(|_| ())
    }

    pub async fn rebuild_hook(&self) -> R<()> {
        self.call(FX_REBUILD_HOOK, |_| {}).await.map(|_| ())
    }
}

struct Next<'a> {
    host: &'a Host,
    id: u32,
}

impl Future for Next<'_> {
    type Output = Incoming;
    fn poll(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Incoming> {
        let mut inbox = self.host.inbox.borrow_mut();
        match inbox.get_mut(&self.id).and_then(VecDeque::pop_front) {
            Some(incoming) => {
                self.host.exec.signal();
                Poll::Ready(incoming)
            }
            None => Poll::Pending,
        }
    }
}

pub const LOG_REVIEW: u8 = 1;
pub const LOG_UNDO: u8 = 2;

pub struct TailLog {
    pub id: String,
    pub card_id: String,
    /// [`LOG_REVIEW`] / [`LOG_UNDO`]；其它 kind 是 0。
    pub kind: u8,
    pub at: i64,
    pub revokes: Option<String>,
}

pub struct Tail {
    /// 发查询那一刻的内容修订号。
    pub content: String,
    /// 这次只数了新增的行（`count` / `max_row_id` 只算新增部分）。
    pub incremental: bool,
    pub count: i64,
    pub max_row_id: i64,
    pub new_rows: i64,
    pub logs: Vec<TailLog>,
}

pub struct AppendRows {
    /// 有卡在卡表里找不到（已删）。
    pub missing_card: bool,
    /// 与请求的卡同序；`None` = 这张卡要的日志不是它末尾的保留评分。里层与该卡的日志 id 同序。
    pub rows: Vec<Option<Vec<Vec<u8>>>>,
    pub tags: Vec<u64>,
}

pub struct ScoreInputs {
    pub today: i64,
    pub refresh_every: i64,
    pub clear_key: String,
    pub requery_key: String,
    pub ids: Vec<i64>,
    pub versions: Vec<u64>,
}

/// `ffsrs_store_rwkv_rows` 的结果，不解码：行、时刻、标签都留在宿主给的那块内存里，回放时按块取。
pub struct Replay {
    reply: Reply,
    pub count: i64,
    pub max_row_id: i64,
    pub last_at: Option<i64>,
    pub rows: usize,
    pub diverge_at: Option<i64>,
    pub tail_rows: i64,
}

const ROW: usize = std::mem::size_of::<FrwkvReview>();
const REPLAY_HEADER: usize = 56;
const NONE_I64: i64 = i64::MIN;

impl Replay {
    fn parse(reply: Reply) -> Result<Self, String> {
        let body = reply.body();
        if body.len() < REPLAY_HEADER {
            return Err(format!("replay rows: {} bytes, no header", body.len()));
        }
        let word = |k: usize| le_i64(body, k);
        let rows = usize::try_from(word(3)).map_err(|_| "replay rows: negative count")?;
        let need = rows
            .checked_mul(ROW + 16)
            .and_then(|n| n.checked_add(REPLAY_HEADER))
            .ok_or("replay rows: count overflow")?;
        if body.len() < need {
            return Err(format!(
                "replay rows: {} bytes for {rows} rows, need {need}",
                body.len()
            ));
        }
        let opt = |v: i64| (v != NONE_I64).then_some(v);
        Ok(Self {
            count: word(0),
            max_row_id: word(1),
            last_at: opt(word(2)),
            rows,
            diverge_at: opt(word(5)),
            tail_rows: word(6),
            reply,
        })
    }

    pub fn view(&self) -> RowsView<'_> {
        let body = self.reply.body();
        let ats = REPLAY_HEADER + self.rows * ROW;
        let tags = ats + self.rows * 8;
        RowsView {
            rows: &body[REPLAY_HEADER..ats],
            ats: &body[ats..tags],
            tags: &body[tags..tags + self.rows * 8],
        }
    }
}

/// 一批行连同各自的评分时刻与撤销日志标签（都是小端原始字节）。
#[derive(Clone, Copy)]
pub struct RowsView<'a> {
    pub rows: &'a [u8],
    pub ats: &'a [u8],
    pub tags: &'a [u8],
}

impl RowsView<'_> {
    pub fn len(&self) -> usize {
        self.rows.len() / ROW
    }

    pub fn at(&self, index: usize) -> i64 {
        le_i64(self.ats, index)
    }
}

// ------------------------------------------------------------------ runtime 后端

/// 排程用的状态精度（int4 卡状态 + int8 笔记状态）。
pub const PRECISION: StatePrecision = StatePrecision::Int4;

pub struct Backend {
    /// 第几个后端（判断「排队期间后台换上了新后端」用）。
    pub id: u32,
    /// `None` = 调用转给宿主；里层 `None` = 已关闭。
    native: Option<RefCell<Option<RwkvRuntime>>>,
}

fn inputs(rows: &[u8], is_query: bool) -> R<Vec<crate::ReviewInput>> {
    let rows = FrwkvReview::parse_rows(rows)?;
    if is_query {
        return Ok(rows.iter().map(query_input).collect());
    }
    rows.iter()
        .enumerate()
        .map(|(index, row)| {
            row.to_input(false).ok_or_else(|| {
                Fault::new(format!(
                    "invalid input: review {index}: unknown present bits"
                ))
            })
        })
        .collect()
}

impl Backend {
    /// 打开后端：生产模式读权重、建 runtime；宿主模式让宿主打开它的后端。
    pub async fn open(
        host: &Host,
        id: u32,
        host_backend: bool,
        weights: &str,
        threads: usize,
    ) -> R<Rc<Self>> {
        if host_backend {
            host.call(FX_OPEN_BACKEND, |w| {
                w.u32(id).str(weights);
            })
            .await?;
            return Ok(Rc::new(Self { id, native: None }));
        }
        let model = Model::from_bytes(&std::fs::read(Path::new(weights))?)?;
        let runtime = RwkvRuntime::new(&model, PRECISION, threads)?;
        Ok(Rc::new(Self {
            id,
            native: Some(RefCell::new(Some(runtime))),
        }))
    }

    async fn remote(&self, host: &Host, call: u8, write: impl FnOnce(&mut Writer)) -> R<Reply> {
        host.call(FX_BACKEND, |w| {
            w.u32(self.id).u8(call);
            write(w);
        })
        .await
    }

    /// 在 runtime 上跑 `f`：先把「开始」交给宿主（账本里看得见正在跑的调用），跑完记「结束」。
    async fn local<T>(
        &self,
        host: &Host,
        cell: &RefCell<Option<RwkvRuntime>>,
        name: &str,
        bytes: usize,
        rows: usize,
        f: impl FnOnce(&mut RwkvRuntime) -> R<T>,
    ) -> R<T> {
        let op = host.next_op.get();
        host.next_op.set(op.wrapping_add(1));
        host.record(OUT_OP_BEGIN, |out| {
            out.u32(op).str(name).i64(bytes as i64).i64(rows as i64);
        });
        host.exec.flush().await;
        let result = match cell.borrow_mut().as_mut() {
            Some(runtime) => f(runtime),
            None => Err(Fault::new("RWKV worker closed")),
        };
        host.record(OUT_OP_END, |out| {
            out.u32(op);
        });
        result
    }

    pub async fn replay(&self, host: &Host, rows: &[u8]) -> R<()> {
        match &self.native {
            Some(cell) => {
                self.local(host, cell, "replay", rows.len(), rows.len() / ROW, |rt| {
                    rt.replay(&inputs(rows, false)?, false)?;
                    Ok(())
                })
                .await
            }
            None => self
                .remote(host, BK_REPLAY, |w| {
                    w.bytes(rows);
                })
                .await
                .map(|_| ()),
        }
    }

    /// false = 模型不支持撤销日志，行已按普通回放追加。
    pub async fn append(&self, host: &Host, view: RowsView<'_>) -> R<bool> {
        match &self.native {
            Some(cell) => {
                let (bytes, n) = (view.rows.len(), view.len());
                self.local(host, cell, "append", bytes, n, |rt| {
                    let rows = inputs(view.rows, false)?;
                    match rt.append(&rows, &le_u64s(view.tags), &le_i64s(view.ats)) {
                        Ok(()) => Ok(true),
                        Err(RwkvError::Unsupported(_)) => {
                            rt.replay(&rows, false)?;
                            Ok(false)
                        }
                        Err(error) => Err(error.into()),
                    }
                })
                .await
            }
            None => {
                let reply = self
                    .remote(host, BK_APPEND, |w| {
                        w.bytes(view.rows).bytes(view.tags).bytes(view.ats);
                    })
                    .await?;
                Reader::new(reply.body()).bool().map_err(wire)
            }
        }
    }

    pub async fn unappend(&self, host: &Host, tag: u64) -> R<bool> {
        match &self.native {
            Some(cell) => {
                self.local(host, cell, "unappend", 0, 0, |rt| Ok(rt.unappend(tag)?))
                    .await
            }
            None => {
                let reply = self
                    .remote(host, BK_UNAPPEND, |w| {
                        w.u64(tag);
                    })
                    .await?;
                Reader::new(reply.body()).bool().map_err(wire)
            }
        }
    }

    /// `None` = 退不到，什么都没改。
    pub async fn rewind_from(&self, host: &Host, at: i64, floor: i64) -> R<Option<i64>> {
        match &self.native {
            Some(cell) => {
                self.local(host, cell, "rewind", 0, 0, |rt| {
                    Ok(rt.rewind_from(at, floor)?.map(|n| n as i64))
                })
                .await
            }
            None => {
                let reply = self
                    .remote(host, BK_REWIND, |w| {
                        w.i64(at).i64(floor);
                    })
                    .await?;
                Reader::new(reply.body()).opt_i64().map_err(wire)
            }
        }
    }

    pub async fn query(&self, host: &Host, rows: &[u8]) -> R<Vec<f32>> {
        match &self.native {
            Some(cell) => {
                self.local(host, cell, "query", rows.len(), rows.len() / ROW, |rt| {
                    Ok(rt.query(&inputs(rows, true)?)?)
                })
                .await
            }
            None => {
                let reply = self
                    .remote(host, BK_QUERY, |w| {
                        w.bytes(rows);
                    })
                    .await?;
                Reader::new(reply.body()).f32s().map_err(wire)
            }
        }
    }

    pub async fn clear_scores(&self, host: &Host) -> R<()> {
        match &self.native {
            Some(cell) => {
                self.local(host, cell, "clear_scores", 0, 0, |rt| {
                    rt.scores_clear();
                    Ok(())
                })
                .await
            }
            None => self.remote(host, BK_CLEAR_SCORES, |_| {}).await.map(|_| ()),
        }
    }

    /// 每张卡的分数（没有的是 NaN）与是否命中。
    pub async fn lookup_scores(
        &self,
        host: &Host,
        ids: &[i64],
        versions: &[u64],
    ) -> R<(Vec<f32>, Vec<bool>)> {
        match &self.native {
            Some(cell) => {
                self.local(host, cell, "lookup_scores", 0, 0, |rt| {
                    let found = rt.scores_lookup(ids, versions);
                    Ok((
                        found.iter().map(|v| v.unwrap_or(f32::NAN)).collect(),
                        found.iter().map(Option::is_some).collect(),
                    ))
                })
                .await
            }
            None => {
                let reply = self
                    .remote(host, BK_LOOKUP_SCORES, |w| {
                        w.i64s(ids).u64s(versions);
                    })
                    .await?;
                let mut r = Reader::new(reply.body());
                (|| {
                    let scores = r.f32s()?;
                    let found = r.bytes()?.iter().map(|b| *b != 0).collect();
                    Ok((scores, found))
                })()
                .map_err(wire)
            }
        }
    }

    pub async fn update_scores(
        &self,
        host: &Host,
        rows: &[u8],
        versions: &[u64],
        anchors: &[i64],
    ) -> R<Vec<f32>> {
        match &self.native {
            Some(cell) => {
                self.local(
                    host,
                    cell,
                    "update_scores",
                    rows.len(),
                    rows.len() / ROW,
                    |rt| Ok(rt.scores_update(&inputs(rows, true)?, versions, anchors)?),
                )
                .await
            }
            None => {
                let reply = self
                    .remote(host, BK_UPDATE_SCORES, |w| {
                        w.bytes(rows).u64s(versions).i64s(anchors);
                    })
                    .await?;
                Reader::new(reply.body()).f32s().map_err(wire)
            }
        }
    }

    pub async fn requery_scores(&self, host: &Host, today: i64, now_ms: i64) -> R<i64> {
        match &self.native {
            Some(cell) => {
                self.local(host, cell, "requery_scores", 0, 0, |rt| {
                    Ok(rt.scores_requery(today, now_ms)? as i64)
                })
                .await
            }
            None => {
                let reply = self
                    .remote(host, BK_REQUERY_SCORES, |w| {
                        w.i64(today).i64(now_ms);
                    })
                    .await?;
                Reader::new(reply.body()).i64().map_err(wire)
            }
        }
    }

    pub async fn remove_scores(&self, host: &Host, ids: &[i64]) -> R<i64> {
        match &self.native {
            Some(cell) => {
                self.local(host, cell, "remove_scores", 0, 0, |rt| {
                    Ok(rt.scores_remove(ids) as i64)
                })
                .await
            }
            None => {
                let reply = self
                    .remote(host, BK_REMOVE_SCORES, |w| {
                        w.i64s(ids);
                    })
                    .await?;
                Reader::new(reply.body()).i64().map_err(wire)
            }
        }
    }

    pub async fn snapshot_to_file(&self, host: &Host, path: &Path) -> R<()> {
        match &self.native {
            Some(cell) => {
                self.local(host, cell, "snapshot_to_file", 0, 0, |rt| {
                    Ok(rt.snapshot_to_file(path)?)
                })
                .await
            }
            None => self
                .remote(host, BK_SNAPSHOT_TO_FILE, |w| {
                    w.str(&path.to_string_lossy());
                })
                .await
                .map(|_| ()),
        }
    }

    pub async fn restore_from_file(&self, host: &Host, path: &Path) -> R<()> {
        match &self.native {
            Some(cell) => {
                self.local(host, cell, "restore_from_file", 0, 0, |rt| {
                    Ok(rt.restore_from_file(path)?)
                })
                .await
            }
            None => self
                .remote(host, BK_RESTORE_FROM_FILE, |w| {
                    w.str(&path.to_string_lossy());
                })
                .await
                .map(|_| ()),
        }
    }

    pub async fn reset(&self, host: &Host) -> R<()> {
        match &self.native {
            Some(cell) => {
                self.local(host, cell, "reset", 0, 0, |rt| {
                    rt.reset();
                    Ok(())
                })
                .await
            }
            None => self.remote(host, BK_RESET, |_| {}).await.map(|_| ()),
        }
    }

    pub async fn close(&self, host: &Host) -> R<()> {
        match &self.native {
            Some(cell) => {
                cell.borrow_mut().take();
                Ok(())
            }
            None => self.remote(host, BK_CLOSE, |_| {}).await.map(|_| ()),
        }
    }
}
