// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 排程内核经 C ABI 的端到端测试（宿主后端模式：取数与 runtime 调用都由这里的脚本化宿主回答）。
//! 逐值的行为对拍在 Dart 侧（`packages/fushi_engine/test/srs/srs_rwkv_service_test.dart` 的夹具）；
//! 这里钉内核自己的不变式：消息布局、没就绪不打分、追加 / 撤回 / 全量重建各走哪条路。

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;

use super::host::*;
use super::wire::{Reader, Writer};
use super::{FrwkvSched, frwkv_sched_alloc, frwkv_sched_free, frwkv_sched_new, frwkv_sched_step};
use crate::frwkv_free_bytes;

const ROW: usize = 80;

#[derive(Clone)]
struct Log {
    id: String,
    card: String,
    kind: u8,
    at: i64,
    revokes: Option<String>,
}

/// 脚本化的宿主：一张日志表、一个记账的假后端。
struct World {
    logs: Vec<Log>,
    content: String,
    revision: u32,
    model_ready: bool,
    /// 下载的结局：`None` = 挂着不回。
    download: Option<Result<(), String>>,
    ingesting: bool,
    /// 假后端：撤销日志里的标签（新的在后）。
    journal: Vec<u64>,
    scores: HashMap<i64, (u64, f32)>,
    /// 假后端下一次调用失败。
    backend_fails: bool,
}

impl World {
    fn new() -> Self {
        Self {
            logs: Vec::new(),
            content: "c0".to_owned(),
            revision: 0,
            model_ready: true,
            download: None,
            ingesting: false,
            journal: Vec::new(),
            scores: HashMap::new(),
            backend_fails: false,
        }
    }

    fn review(&mut self, card: &str, at: i64) -> String {
        let id = format!("log{}", self.logs.len() + 1);
        self.logs.push(Log {
            id: id.clone(),
            card: card.to_owned(),
            kind: LOG_REVIEW,
            at,
            revokes: None,
        });
        self.revision += 1;
        id
    }

    fn undo(&mut self, target: &str, at: i64) {
        let card = self
            .logs
            .iter()
            .find(|l| l.id == target)
            .unwrap()
            .card
            .clone();
        self.logs.push(Log {
            id: format!("log{}", self.logs.len() + 1),
            card,
            kind: LOG_UNDO,
            at,
            revokes: Some(target.to_owned()),
        });
        self.revision += 1;
    }

    /// 保留评分：没被撤销的评分，按时间。
    fn kept(&self) -> Vec<&Log> {
        let mut kept: Vec<&Log> = self
            .logs
            .iter()
            .filter(|l| {
                l.kind == LOG_REVIEW
                    && !self
                        .logs
                        .iter()
                        .any(|u| u.revokes.as_deref() == Some(l.id.as_str()))
            })
            .collect();
        kept.sort_by_key(|l| l.at);
        kept
    }
}

fn hash(text: &str) -> u64 {
    text.bytes().fold(1469598103934665603u64, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(1099511628211)
    }) >> 12
}

fn row_of(card: &str) -> [u8; ROW] {
    let mut row = [0u8; ROW];
    row[..8].copy_from_slice(&(hash(card) as i64).to_le_bytes());
    row[76] = 3;
    row
}

struct Rig {
    sched: *mut FrwkvSched,
    dir: PathBuf,
    world: World,
    trace: Vec<String>,
    /// 挂着没回的 effect（id，种类）。
    held: Vec<(u32, u8)>,
    next_op: u32,
    /// 每条命令的命令号（解它的结果用）。
    commands: HashMap<u32, u8>,
}

impl Drop for Rig {
    fn drop(&mut self) {
        unsafe { frwkv_sched_free(self.sched) };
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn phase_name(phase: u8) -> &'static str {
    ["idle", "downloading", "preparing", "ready", "failed"][phase as usize]
}

impl Rig {
    fn new(name: &str, journal_seed: i64) -> Self {
        let dir = std::env::temp_dir().join(format!("frwkv-sched-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut cfg = Writer::default();
        cfg.str("p1")
            .str(&dir.to_string_lossy())
            .u32(1)
            .i64(journal_seed)
            .i64(30 * 60 * 1000)
            .bool(true)
            .i64(120_000)
            .i64(600_000);
        let sched = unsafe { frwkv_sched_new(cfg.0.as_ptr(), cfg.0.len()) };
        assert!(!sched.is_null());
        Self {
            sched,
            dir,
            world: World::new(),
            trace: Vec::new(),
            held: Vec::new(),
            next_op: 1,
            commands: HashMap::new(),
        }
    }

    fn step(&mut self, input: &[u8]) -> Vec<u8> {
        unsafe {
            let ptr = frwkv_sched_alloc(input.len());
            if !ptr.is_null() {
                std::slice::from_raw_parts_mut(ptr, input.len()).copy_from_slice(input);
            }
            let mut len = 0usize;
            let out = frwkv_sched_step(self.sched, ptr, input.len(), &mut len);
            assert!(!out.is_null(), "step failed");
            let bytes = std::slice::from_raw_parts(out, len).to_vec();
            frwkv_free_bytes(out, len);
            bytes
        }
    }

    /// 喂一条输入，回答内核发出的每个 effect，直到它停下。
    fn pump(&mut self, input: Vec<u8>) {
        let mut queue = VecDeque::from([input]);
        while let Some(message) = queue.pop_front() {
            let mut out = self.step(&message);
            loop {
                let more = out[0] != 0;
                let mut r = Reader::new(&out[1..]);
                while !r.done() {
                    let tag = r.u8().unwrap();
                    let body = r.bytes().unwrap().to_vec();
                    if let Some(reply) = self.record(tag, &body) {
                        queue.push_back(reply);
                    }
                }
                if !more {
                    break;
                }
                out = self.step(&[]);
            }
        }
    }

    fn command(&mut self, write: impl FnOnce(&mut Writer)) -> u32 {
        let op = self.next_op;
        self.next_op += 1;
        let mut w = Writer::default();
        w.u8(1).u32(op);
        write(&mut w);
        self.commands.insert(op, w.0[5]);
        self.pump(w.0);
        op
    }

    fn start(&mut self, force: bool) -> u32 {
        self.command(|w| {
            w.u8(1).bool(force);
        })
    }

    fn instant(&mut self, cards: u32, at_ms: i64) -> u32 {
        self.command(|w| {
            w.u8(4).u32(cards).i64(at_ms);
        })
    }

    fn answered(&mut self) -> u32 {
        self.command(|w| {
            w.u8(6);
        })
    }

    fn take_trace(&mut self) -> Vec<String> {
        std::mem::take(&mut self.trace)
    }

    fn reply(id: u32, body: Result<Writer, String>) -> Vec<u8> {
        let mut w = Writer::default();
        w.u8(2).u32(id);
        match body {
            Ok(body) => {
                w.bool(true);
                w.0.extend_from_slice(&body.0);
            }
            Err(text) => {
                w.bool(false).str(&text);
            }
        }
        w.0
    }

    /// 处理一条输出记录；是 effect 且现在就能回答时返回回复消息。
    fn record(&mut self, tag: u8, body: &[u8]) -> Option<Vec<u8>> {
        let mut r = Reader::new(body);
        match tag {
            OUT_STATUS => {
                let phase = r.u8().unwrap();
                let _changed = r.bool().unwrap();
                let (done, total) = (r.i64().unwrap(), r.i64().unwrap());
                let mut line = format!("status {} {done}/{total}", phase_name(phase));
                if r.bool().unwrap() {
                    let _origin = r.u32().unwrap();
                    line.push_str(&format!(" error={}", r.str().unwrap()));
                }
                self.trace.push(line);
                None
            }
            OUT_DONE => {
                let op = r.u32().unwrap();
                let ok = r.bool().unwrap();
                let detail = if !ok {
                    let _origin = r.u32().unwrap();
                    format!("error={}", r.str().unwrap())
                } else {
                    match self.commands[&op] {
                        3 => format!("{}", r.bool().unwrap()),
                        4 | 5 => {
                            if r.bool().unwrap() {
                                format!("{:?}", r.f32s().unwrap())
                            } else {
                                "[none]".to_owned()
                            }
                        }
                        _ => "ok".to_owned(),
                    }
                };
                assert!(r.done(), "trailing bytes in a command result");
                self.trace.push(format!("done {op} {detail}"));
                None
            }
            OUT_LOG => None,
            OUT_TIMER => {
                let _generation = r.u32().unwrap();
                let after = r.i64().unwrap();
                self.trace.push(if after < 0 {
                    "timer cancel".to_owned()
                } else {
                    format!("timer {after}")
                });
                None
            }
            OUT_CANCEL => {
                self.trace.push("cancel".to_owned());
                None
            }
            OUT_EFFECT => {
                let id = r.u32().unwrap();
                let kind = r.u8().unwrap();
                match self.effect(kind, &mut r) {
                    Some(body) => Some(Self::reply(id, body)),
                    None => {
                        self.held.push((id, kind));
                        None
                    }
                }
            }
            other => panic!("unexpected record {other}"),
        }
    }

    fn effect(&mut self, kind: u8, r: &mut Reader<'_>) -> Option<Result<Writer, String>> {
        let mut w = Writer::default();
        match kind {
            FX_REVISION => {
                self.trace.push("fx revision".to_owned());
                w.str(&format!("r{}", self.world.revision));
            }
            FX_TAIL => {
                let (since_incremental, since_full) = (r.i64().unwrap(), r.i64().unwrap());
                let with_rows = r.bool().unwrap();
                let if_content = r.opt_str().unwrap();
                let incremental = if_content.as_deref() == Some(self.world.content.as_str());
                let since = if incremental {
                    since_incremental
                } else {
                    since_full
                } as usize;
                self.trace.push(format!(
                    "fx tail since={since} rows={with_rows} incremental={incremental}"
                ));
                let logs = &self.world.logs;
                let new = &logs[since.min(logs.len())..];
                w.str(&self.world.content).bool(incremental);
                if incremental {
                    w.i64(new.len() as i64)
                        .i64(if new.is_empty() { 0 } else { logs.len() as i64 });
                } else {
                    w.i64(logs.len() as i64).i64(logs.len() as i64);
                }
                w.i64(new.len() as i64);
                let rows = if with_rows { new } else { &[] };
                w.u32(rows.len() as u32);
                for log in rows {
                    w.str(&log.id)
                        .str(&log.card)
                        .u8(log.kind)
                        .i64(log.at)
                        .opt_str(log.revokes.as_deref());
                }
            }
            FX_REPLAY => {
                let since = r.i64().unwrap();
                let rebase_since = r.opt_i64().unwrap();
                let _rows_from = r.opt_i64().unwrap();
                self.trace
                    .push(format!("fx replay since={since} rebase={rebase_since:?}"));
                // 这个世界不模拟分歧时刻：退回重放一律从头给全部保留评分（分歧 = 第一条的时刻）。
                let kept = self.world.kept();
                let total = self.world.logs.len() as i64;
                let tail = rebase_since.map_or(0, |from| total - from);
                w.i64(total)
                    .i64(total)
                    .i64(kept.last().map_or(i64::MIN, |l| l.at))
                    .i64(kept.len() as i64)
                    .i64(0)
                    .i64(match rebase_since {
                        Some(_) => kept.first().map_or(i64::MIN, |l| l.at),
                        None => i64::MIN,
                    })
                    .i64(tail);
                for log in &kept {
                    w.0.extend_from_slice(&row_of(&log.card));
                }
                for log in &kept {
                    w.i64(log.at);
                }
                for log in &kept {
                    w.u64(hash(&log.id));
                }
            }
            FX_APPEND_ROWS => {
                let cards = r.u32().unwrap();
                self.trace.push(format!("fx append_rows cards={cards}"));
                w.bool(false);
                for _ in 0..cards {
                    let card = r.str().unwrap();
                    let ids = r.u32().unwrap();
                    w.bool(true);
                    for _ in 0..ids {
                        r.str().unwrap();
                        w.bytes(&row_of(&card));
                    }
                }
                let tags = r.u32().unwrap();
                w.u32(tags);
                for _ in 0..tags {
                    w.u64(hash(&r.str().unwrap()));
                }
            }
            FX_SCORE_INPUTS => {
                self.trace.push("fx score_inputs".to_owned());
                w.i64(7).i64(1).str("clear").str("requery");
                w.i64s(&[101, 102]).u64s(&[1, 1]);
            }
            FX_QUERY_ROWS => {
                let _op = r.u32().unwrap();
                let _at = r.i64().unwrap();
                let indices: Vec<u32> = if r.bool().unwrap() {
                    let n = r.u32().unwrap();
                    (0..n).map(|_| r.u32().unwrap()).collect()
                } else {
                    vec![0, 1]
                };
                self.trace.push(format!("fx query_rows {indices:?}"));
                let mut rows = Vec::new();
                for i in &indices {
                    let mut row = [0u8; ROW];
                    row[..8].copy_from_slice(&(101 + i64::from(*i)).to_le_bytes());
                    rows.extend_from_slice(&row);
                }
                w.bytes(&rows);
                w.i64s(&vec![-1; indices.len()]);
            }
            FX_INGESTING => {
                w.bool(self.world.ingesting);
            }
            FX_INGEST_SETTLED => return None,
            FX_DAY_INDEX => {
                let (a, b) = (r.i64().unwrap(), r.i64().unwrap());
                w.i64(a / 86_400_000).i64(b / 86_400_000);
            }
            FX_MODEL_READY => {
                self.trace.push("fx model_ready".to_owned());
                w.bool(self.world.model_ready).str("weights.bin");
            }
            FX_DOWNLOAD => {
                self.trace.push("fx download".to_owned());
                return match self.world.download.clone()? {
                    Ok(()) => Some(Ok(w)),
                    Err(text) => Some(Err(text)),
                };
            }
            FX_DELETE_RETIRED | FX_REBUILD_HOOK => {}
            FX_OPEN_BACKEND => {
                self.trace.push("bk open".to_owned());
            }
            FX_BACKEND => {
                let _backend = r.u32().unwrap();
                let call = r.u8().unwrap();
                if self.world.backend_fails {
                    self.world.backend_fails = false;
                    self.trace.push("bk fails".to_owned());
                    return Some(Err("worker exited".to_owned()));
                }
                self.backend(call, r, &mut w);
            }
            other => panic!("unexpected effect {other}"),
        }
        Some(Ok(w))
    }

    fn backend(&mut self, call: u8, r: &mut Reader<'_>, w: &mut Writer) {
        match call {
            BK_RESET => {
                self.world.journal.clear();
                self.trace.push("bk reset".to_owned());
            }
            BK_REPLAY => {
                self.world.journal.clear();
                self.trace
                    .push(format!("bk replay {}", r.bytes().unwrap().len() / ROW));
            }
            BK_APPEND => {
                let rows = r.bytes().unwrap().len() / ROW;
                let tags = r.bytes().unwrap();
                for tag in tags.chunks_exact(8) {
                    self.world
                        .journal
                        .push(u64::from_le_bytes(tag.try_into().unwrap()));
                }
                self.trace.push(format!("bk append {rows}"));
                w.bool(true);
            }
            BK_UNAPPEND => {
                let tag = r.u64().unwrap();
                let hit = self.world.journal.last() == Some(&tag);
                if hit {
                    self.world.journal.pop();
                }
                self.trace.push(format!("bk unappend {hit}"));
                w.bool(hit);
            }
            BK_REWIND => {
                let n = self.world.journal.len() as i64;
                self.world.journal.clear();
                self.trace.push(format!("bk rewind {n}"));
                w.opt_i64(Some(n));
            }
            BK_CLEAR_SCORES => {
                self.world.scores.clear();
                self.trace.push("bk clear_scores".to_owned());
            }
            BK_LOOKUP_SCORES => {
                let ids = r.i64s().unwrap();
                let versions = r.u64s().unwrap();
                let hits: Vec<Option<f32>> = ids
                    .iter()
                    .zip(&versions)
                    .map(|(id, version)| {
                        self.world
                            .scores
                            .get(id)
                            .filter(|(v, _)| v == version)
                            .map(|(_, score)| *score)
                    })
                    .collect();
                self.trace.push(format!(
                    "bk lookup {}/{}",
                    hits.iter().flatten().count(),
                    ids.len()
                ));
                w.u32(hits.len() as u32);
                for hit in &hits {
                    w.f32(hit.unwrap_or(f32::NAN));
                }
                w.bytes(
                    &hits
                        .iter()
                        .map(|h| u8::from(h.is_some()))
                        .collect::<Vec<_>>(),
                );
            }
            BK_UPDATE_SCORES => {
                let rows = r.bytes().unwrap();
                let versions = r.u64s().unwrap();
                self.trace.push(format!("bk update {}", versions.len()));
                w.u32(versions.len() as u32);
                for (k, row) in rows.chunks_exact(ROW).enumerate() {
                    let id = i64::from_le_bytes(row[..8].try_into().unwrap());
                    let score = (id - 100) as f32 * 0.25;
                    self.world.scores.insert(id, (versions[k], score));
                    w.f32(score);
                }
            }
            BK_REQUERY_SCORES => {
                self.trace.push("bk requery".to_owned());
                w.i64(self.world.scores.len() as i64);
            }
            BK_SNAPSHOT_TO_FILE => {
                let path = r.str().unwrap();
                std::fs::write(&path, b"state").unwrap();
                self.trace.push(format!(
                    "bk snapshot {}",
                    PathBuf::from(path).file_name().unwrap().to_string_lossy()
                ));
            }
            BK_RESTORE_FROM_FILE => {
                self.world.journal.clear();
                self.trace.push("bk restore".to_owned());
            }
            BK_CLOSE => self.trace.push("bk close".to_owned()),
            other => panic!("unexpected backend call {other}"),
        }
    }

    fn ready_with(name: &str, journal_seed: i64, reviews: &[(&str, i64)]) -> Self {
        let mut rig = Self::new(name, journal_seed);
        for (card, at) in reviews {
            rig.world.review(card, *at);
        }
        rig.start(false);
        assert_eq!(rig.trace.last().map(String::as_str), Some("done 1 ok"));
        rig.take_trace();
        rig
    }
}

fn lines(expected: &[&str]) -> Vec<String> {
    expected.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn first_start_rebuilds_from_the_whole_history_and_saves_a_snapshot() {
    let mut rig = Rig::new("rebuild", 2);
    for (card, at) in [("a", 1_000), ("b", 2_000), ("c", 3_000)] {
        rig.world.review(card, at);
    }
    rig.start(false);
    assert_eq!(
        rig.take_trace(),
        lines(&[
            "fx model_ready",
            "status preparing 0/0",
            "bk open",
            "fx tail since=0 rows=false incremental=false",
            "fx replay since=3 rebase=None",
            "bk reset",
            "status preparing 0/3",
            "bk replay 1",
            "status preparing 1/3",
            "bk append 2",
            "status preparing 3/3",
            "bk snapshot rwkv-p1-small-int4.snap.tmp",
            "status ready 0/0",
            "done 1 ok",
        ])
    );
    assert_eq!(
        std::fs::read_to_string(rig.dir.join("rwkv-p1-small-int4.snap.json")).unwrap(),
        r#"{"v":1,"count":3,"maxRowId":3,"lastAt":3000}"#
    );
    assert!(rig.dir.join("rwkv-p1-small-int4.snap").exists());
    assert!(!rig.dir.join("rwkv-p1-small-int4.snap.tmp").exists());

    // 排队打分：先对齐（只数新增的行），清空分数表，表里没有的卡当场算并记进表。
    rig.instant(2, 50_000);
    assert_eq!(
        rig.take_trace(),
        lines(&[
            "fx revision",
            "fx tail since=3 rows=false incremental=true",
            "fx score_inputs",
            "bk clear_scores",
            "bk lookup 0/2",
            "fx query_rows [0, 1]",
            "bk update 2",
            "done 2 [0.25, 0.5]",
        ])
    );
    // 没有新日志、分数表命中：不取数、不重算。
    rig.instant(2, 50_001);
    assert_eq!(
        rig.take_trace(),
        lines(&[
            "fx revision",
            "fx score_inputs",
            "bk lookup 2/2",
            "done 3 [0.25, 0.5]",
        ])
    );
}

#[test]
fn not_ready_never_scores_and_never_touches_the_backend() {
    let mut rig = Rig::new("pending", 2);
    rig.world.review("a", 1_000);
    rig.world.model_ready = false;
    rig.world.download = Some(Err("offline".to_owned()));
    // 没就绪：这一次不打分（宿主不出 RWKV 牌组的复习卡），顺手触发准备；下载失败转「出错」。
    rig.instant(1, 9_000);
    assert_eq!(
        rig.take_trace(),
        lines(&[
            "done 1 [none]",
            "fx model_ready",
            "status downloading 0/0",
            "fx download",
            "status failed 0/0 error=offline",
        ])
    );
    // 出错后的排队不再打分，自动重试受间隔限制：什么都不做。
    rig.instant(1, 9_001);
    assert_eq!(rig.take_trace(), lines(&["done 2 [none]"]));
    // 宿主的「重试」不受间隔限制；权重就位后准备完成，之后才打分。
    rig.world.model_ready = true;
    rig.start(true);
    let trace = rig.take_trace();
    assert_eq!(trace.first().map(String::as_str), Some("fx model_ready"));
    assert_eq!(
        &trace[trace.len() - 2..],
        lines(&["status ready 0/0", "done 3 ok"])
    );
    rig.instant(2, 9_002);
    assert_eq!(
        rig.take_trace().last().map(String::as_str),
        Some("done 4 [0.25, 0.5]")
    );
}

#[test]
fn new_ratings_are_appended_and_the_latest_undo_is_unappended() {
    let mut rig = Rig::ready_with("append", 500, &[("a", 1_000), ("b", 2_000)]);
    let latest = rig.world.review("c", 3_000);
    rig.answered();
    assert_eq!(
        rig.take_trace(),
        lines(&[
            "fx revision",
            "fx tail since=2 rows=false incremental=true",
            "fx tail since=2 rows=true incremental=true",
            "fx append_rows cards=1",
            "fx tail since=2 rows=false incremental=true",
            "bk append 1",
            "timer 120000",
            "done 2 ok",
        ])
    );
    // 撤销最近的作答：按撤销日志原样撤回。
    rig.world.undo(&latest, 3_500);
    rig.answered();
    assert_eq!(
        rig.take_trace(),
        lines(&[
            "fx revision",
            "fx tail since=3 rows=false incremental=true",
            "fx tail since=3 rows=true incremental=true",
            "fx append_rows cards=0",
            "fx tail since=3 rows=false incremental=true",
            "bk unappend true",
            "timer 120000",
            "done 3 ok",
        ])
    );
    // 空闲定时器到点：存快照（顺带取消定时器记录）。
    let mut fired = Writer::default();
    fired.u8(4).u32(2);
    rig.pump(fired.0);
    assert_eq!(
        rig.take_trace(),
        lines(&["bk snapshot rwkv-p1-small-int4.snap.tmp"])
    );
    assert_eq!(
        std::fs::read_to_string(rig.dir.join("rwkv-p1-small-int4.snap.json")).unwrap(),
        r#"{"v":1,"count":4,"maxRowId":4,"lastAt":3000}"#
    );
}

#[test]
fn a_rating_not_after_the_last_replayed_one_rewinds_and_replays() {
    let mut rig = Rig::ready_with("rebase", 500, &[("a", 1_000), ("b", 2_000)]);
    // 同步来的评分插在已回放的行中间：不能追加，退回重放。
    rig.world.review("c", 1_500);
    rig.answered();
    assert_eq!(
        rig.take_trace(),
        lines(&[
            "fx revision",
            "fx tail since=2 rows=false incremental=true",
            "fx tail since=2 rows=true incremental=true",
            "fx replay since=2 rebase=Some(2)",
            "bk rewind 2",
            "bk append 3",
            "timer 120000",
            "done 2 ok",
        ])
    );
}

#[test]
fn scoring_failure_while_ready_turns_failed_and_drops_the_backend() {
    let mut rig = Rig::ready_with("scoring", 500, &[("a", 1_000)]);
    rig.world.backend_fails = true;
    rig.instant(2, 9_000);
    assert_eq!(
        rig.take_trace(),
        lines(&[
            "fx revision",
            "fx tail since=1 rows=false incremental=true",
            "fx score_inputs",
            "bk fails",
            "bk close",
            "status failed 0/0 error=worker exited",
            "done 2 [none]",
        ])
    );
    // 重试：重新打开后端、从快照恢复。
    rig.start(true);
    assert_eq!(
        rig.take_trace(),
        lines(&[
            "fx model_ready",
            "status preparing 0/0",
            "bk open",
            "bk restore",
            "status ready 0/0",
            "done 3 ok",
        ])
    );
}

#[test]
fn close_saves_pending_appends_and_stops_reporting() {
    let mut rig = Rig::ready_with("close", 500, &[("a", 1_000)]);
    rig.world.review("b", 2_000);
    rig.answered();
    rig.take_trace();
    rig.command(|w| {
        w.u8(8);
    });
    assert_eq!(
        rig.take_trace(),
        lines(&[
            "timer cancel",
            "bk snapshot rwkv-p1-small-int4.snap.tmp",
            "bk close",
            "done 3 ok",
        ])
    );
    // 关了的内核永远「没就绪」：不打分，也不再启动准备。
    rig.instant(1, 9_000);
    assert_eq!(rig.take_trace(), lines(&["done 4 [none]"]));
}

#[test]
fn malformed_input_is_an_error_not_a_crash() {
    let mut rig = Rig::new("malformed", 2);
    unsafe {
        let ptr = frwkv_sched_alloc(2);
        std::slice::from_raw_parts_mut(ptr, 2).copy_from_slice(&[9, 9]);
        let mut len = 7usize;
        assert!(frwkv_sched_step(rig.sched, ptr, 2, &mut len).is_null());
        assert_eq!(len, 0);
    }
    // 之后照常可用。
    rig.world.review("a", 1_000);
    rig.start(false);
    assert_eq!(rig.trace.last().map(String::as_str), Some("done 1 ok"));
}
