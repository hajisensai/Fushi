//! 协议 4 的内核导出流 `ops.bin`（`.fushisrs` 第 2 版里的那一条；规划 g7_g11 §1.9、实现拆分 G11-1）。
//!
//! 纯编解码：不碰 SQLite，**没有接进导出 / 导入入口**（存储侧的导入导出是 G11-2，命令接线是 G11-3）。
//! 一个集合的真相层整份写成一条流：每条原生日志（含空洞）、每条承袭日志（槽 + 原链值标记）、分叉的另一支。
//! 待投递的槽（`op_pending`）不进导出（D34）。
//!
//! ```text
//! 整条流 zstd 压缩（单帧、流式）；下面是明文。
//!
//! 头    "FSRS4EXP"[8] | ver u8 = 1 | flags u8 = 0 | collection[16] | n_logs uv
//! 日志  tag u8，按 tag 不降、同 tag 内按 device 严格升序；原生与承袭的 device 互不相同
//!   0 原生  device[16] | bytes(public：0 或 32 字节) | count uv（日志覆盖 seq 1..=count）
//!           | 项 × 若干，首尾相接覆盖 1..=count | tail_chain[32]
//!           项  tag u8
//!             0 操作  bytes(协议 4 操作的独立编码：信封 + 操作体，`Op4::encode`)
//!             3 空洞  n uv（>= 1）| chain_after[32]          相邻两个空洞拒绝（写者合并）
//!   1 承袭  source[16] | device[16] | count uv（槽覆盖 seq 1..=count）
//!           | n_marks uv | (seq uv, chain[32]) × n_marks    seq 严格升序、1 <= seq <= count
//!           | (t_version uv, 槽的独立编码 `HeritageSlot::encode`) × count
//!   2 分叉  source[16] | device[16] | n uv（>= 1）| (t_version uv, 槽) × n
//!           按 (seq, fp) 严格升序；device 必须是前面某条承袭日志的旧设备、source 与它相同、seq <= 它的 count
//! ```
//!
//! 校验（读写两侧同一套规则，[Grammar]）：
//!
//! - 只收规范形：varint 最短形（`uv_min`）、`flags` 必须为 0、未知 tag 拒、读完最后一条日志后不许有尾字节。
//! - 原生日志逐条重算链（`chain_next4`；空洞处重置为 `chain_after`），末尾必须等于 `tail_chain`；每条操作的身份与日志一致、
//!   `seq` 连续，内容按 [super::op::native_allowed]（与原生段相同）。
//! - 承袭日志的槽从 1 起连续、属于这台旧设备，自洽（`HeritageSlot::check`）；每个标记的链值前 8 字节必须等于那个 seq 的槽的
//!   链指纹。标记排在槽前面，所以读者只用记标记，不用记每个槽的指纹。
//! - `t_version` 逐槽记录而不是逐日志：真相层里同一条承袭日志的槽可以来自不同版本的转译（store/gen4/truth.rs「槽的落库规则」）。
//!
//! 与协议 3 的导出流（魔数 `FSRS2EXP`，store/sync2/transport.rs）互不误读：魔数不同，协议 3 的读者在魔数处就报
//! 「not a .fushisrs file」，本读者同样拒绝 `FSRS2EXP`；[sniff] 分得出两者。冻结的协议 3 读入器在 store/gen4/legacy_export.rs。
//!
//! 版本号与演进：`ver` 是本文件布局的版本。布局的任何变化都升 `ver`，旧读者对 `ver != 1` 一律拒收（不按已知前缀读）。

use std::collections::{HashMap, VecDeque};
use std::io::Write;

use super::heritage::{Fp, HeritageSlot, fingerprint};
use super::op::{Op4, chain_next4, native_allowed};
use super::uv_min;
use crate::sync2::codec::{DResult, DecodeError, Reader, StreamError, ZstdWindow};
use crate::sync2::id::Id;
use crate::sync2::segment::{CHAIN_ZERO, Chain};

pub const EXPORT4_MAGIC: &[u8; 8] = b"FSRS4EXP";
pub const EXPORT4_VER: u8 = 1;
/// 协议 3 导出流的魔数（只用来嗅探；读它的是 store/gen4/legacy_export.rs）。
pub const EXPORT1_MAGIC: &[u8; 8] = b"FSRS2EXP";
/// 压缩级别。压缩输出不是契约（解码方向才是）；换级别不改格式。
pub const ZSTD_LEVEL: i32 = 3;

const LOG_NATIVE: u8 = 0;
const LOG_HERITAGE: u8 = 1;
const LOG_FORK: u8 = 2;
const ITEM_OP: u8 = 0;
const ITEM_VOID: u8 = 3;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExportHeader {
    pub collection: Id,
    /// 流里的日志条数（原生 + 承袭 + 分叉）。
    pub logs: u64,
}

/// 流里的一项（按出现顺序）。日志抬头之后跟它的内容：
///
/// - [ExportItem::NativeLog] → `NativeOp` / `NativeVoid` 若干（覆盖 1..=count）→ [ExportItem::NativeTail]；
/// - [ExportItem::HeritageLog] → [ExportItem::Mark] × marks → [ExportItem::Slot] × count；
/// - [ExportItem::ForkLog] → [ExportItem::Slot] × n。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExportItem {
    NativeLog {
        device: Id,
        public: Option<[u8; 32]>,
        count: u64,
    },
    NativeOp(Op4),
    NativeVoid {
        n: u64,
        chain_after: Chain,
    },
    NativeTail(Chain),
    HeritageLog {
        source: Id,
        device: Id,
        count: u64,
        marks: u64,
    },
    Mark {
        seq: u64,
        chain: Chain,
    },
    Slot {
        t_version: u32,
        slot: HeritageSlot,
    },
    ForkLog {
        source: Id,
        device: Id,
        n: u64,
    },
}

/// 嗅探出的导出流种类。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportKind {
    /// 协议 3 的 `FSRS2EXP`（`.fushisrs` 第 1 版）。
    V1,
    /// 本文件的 `FSRS4EXP`。
    V4,
}

/// 看魔数分出是哪一代的导出流（只解压前 8 字节，不校验其余部分）。
pub fn sniff(bytes: &[u8]) -> Result<ExportKind, String> {
    let mut window = ZstdWindow::new(bytes).map_err(|e| e.to_string())?;
    let magic = window
        .parse(|r| r.raw(8).map(<[u8]>::to_vec))
        .map_err(|e| e.to_string())?;
    if magic == EXPORT4_MAGIC {
        Ok(ExportKind::V4)
    } else if magic == EXPORT1_MAGIC {
        Ok(ExportKind::V1)
    } else {
        Err("not a .fushisrs operations stream".into())
    }
}

// ---------------------------------------------------------------- 语法（读写共用）

/// 承袭日志的摘要：分叉支要对着它查。
#[derive(Clone, Copy)]
enum Seen {
    Native,
    Heritage { source: Id, count: u64 },
}

enum Phase {
    /// 等下一条日志的抬头（或流结束）。
    Logs,
    Native {
        device: Id,
        next: u64,
        last: u64,
        chain: Chain,
        prev_void: bool,
    },
    Marks {
        device: Id,
        count: u64,
        left: u64,
        prev: u64,
        marks: VecDeque<(u64, Fp)>,
    },
    Slots {
        device: Id,
        next: u64,
        last: u64,
        marks: VecDeque<(u64, Fp)>,
    },
    Fork {
        device: Id,
        count: u64,
        left: u64,
        prev: Option<(u64, Fp)>,
    },
}

/// 下一项该是什么（读者按它决定怎么解下一段字节）。
enum Expect {
    Log,
    NativeItem,
    Tail,
    Mark,
    Slot,
    End,
}

/// 流的规范形规则：写者每写一项、读者每读一项都过一遍，两侧收的东西完全相同。
struct Grammar {
    logs_left: u64,
    /// 上一条日志的 (tag, device)。
    prev_log: Option<(u8, Id)>,
    seen: HashMap<Id, Seen>,
    phase: Phase,
}

fn err<T>(m: impl Into<String>) -> Result<T, String> {
    Err(format!("FSRS4EXP: {}", m.into()))
}

impl Grammar {
    fn new(logs: u64) -> Grammar {
        Grammar {
            logs_left: logs,
            prev_log: None,
            seen: HashMap::new(),
            phase: Phase::Logs,
        }
    }

    fn expect(&self) -> Expect {
        match &self.phase {
            Phase::Logs if self.logs_left == 0 => Expect::End,
            Phase::Logs => Expect::Log,
            Phase::Native { next, last, .. } if *next > *last => Expect::Tail,
            Phase::Native { .. } => Expect::NativeItem,
            Phase::Marks { .. } => Expect::Mark,
            Phase::Slots { .. } | Phase::Fork { .. } => Expect::Slot,
        }
    }

    /// 新日志：tag 不降、同 tag 内 device 严格升序、原生与承袭的 device 不重。
    fn open_log(&mut self, tag: u8, device: Id) -> Result<(), String> {
        if !matches!(self.phase, Phase::Logs) {
            return err("a log starts before the previous one ends");
        }
        if self.logs_left == 0 {
            return err("more logs than the header declares");
        }
        if let Some((pt, pd)) = self.prev_log {
            if tag < pt || (tag == pt && device <= pd) {
                return err("logs out of order");
            }
        }
        self.logs_left -= 1;
        self.prev_log = Some((tag, device));
        Ok(())
    }

    fn claim(&mut self, device: Id, seen: Seen) -> Result<(), String> {
        if self.seen.insert(device, seen).is_some() {
            return err(format!("device {device} has two logs"));
        }
        Ok(())
    }

    fn step(&mut self, it: &ExportItem) -> Result<(), String> {
        match it {
            ExportItem::NativeLog { device, count, .. } => {
                self.open_log(LOG_NATIVE, *device)?;
                self.claim(*device, Seen::Native)?;
                self.phase = Phase::Native {
                    device: *device,
                    next: 1,
                    last: *count,
                    chain: CHAIN_ZERO,
                    prev_void: false,
                };
            }
            ExportItem::NativeOp(op) => {
                let Phase::Native {
                    device,
                    next,
                    last,
                    chain,
                    prev_void,
                } = &mut self.phase
                else {
                    return err("native op outside a native log");
                };
                if *next > *last {
                    return err("native log overruns its count");
                }
                if op.id.device != *device || op.hlc.device != *device {
                    return err("native op belongs to another device");
                }
                if op.id.seq != *next {
                    return err("native op out of sequence");
                }
                if op.deps.get(device) != 0 {
                    return err("op deps name its own device");
                }
                native_allowed(op).map_err(|m| format!("FSRS4EXP: {m}"))?;
                *chain = chain_next4(chain, op);
                *next += 1;
                *prev_void = false;
            }
            ExportItem::NativeVoid { n, chain_after } => {
                let Phase::Native {
                    next,
                    last,
                    chain,
                    prev_void,
                    ..
                } = &mut self.phase
                else {
                    return err("void outside a native log");
                };
                if *n == 0 || *n > *last + 1 - (*next).min(*last + 1) {
                    return err("void count");
                }
                if *prev_void {
                    return err("adjacent voids");
                }
                *chain = *chain_after;
                *next += *n;
                *prev_void = true;
            }
            ExportItem::NativeTail(tail) => {
                let Phase::Native {
                    next, last, chain, ..
                } = &self.phase
                else {
                    return err("chain tail outside a native log");
                };
                if *next <= *last {
                    return err("native log ends before its count");
                }
                if chain != tail {
                    return err("native log chain does not reach its tail");
                }
                self.phase = Phase::Logs;
            }
            ExportItem::HeritageLog {
                source,
                device,
                count,
                marks,
            } => {
                self.open_log(LOG_HERITAGE, *device)?;
                self.claim(
                    *device,
                    Seen::Heritage {
                        source: *source,
                        count: *count,
                    },
                )?;
                if *marks > *count {
                    return err("more marks than slots");
                }
                self.phase = if *marks == 0 {
                    Phase::Slots {
                        device: *device,
                        next: 1,
                        last: *count,
                        marks: VecDeque::new(),
                    }
                } else {
                    Phase::Marks {
                        device: *device,
                        count: *count,
                        left: *marks,
                        prev: 0,
                        marks: VecDeque::new(),
                    }
                };
                self.settle_slots();
            }
            ExportItem::Mark { seq, chain } => {
                let Phase::Marks {
                    device,
                    count,
                    left,
                    prev,
                    marks,
                } = &mut self.phase
                else {
                    return err("mark outside a heritage log");
                };
                if *seq <= *prev || *seq > *count {
                    return err("marks out of order or past the log");
                }
                *prev = *seq;
                marks.push_back((*seq, fingerprint(chain)));
                *left -= 1;
                if *left == 0 {
                    self.phase = Phase::Slots {
                        device: *device,
                        next: 1,
                        last: *count,
                        marks: std::mem::take(marks),
                    };
                    self.settle_slots();
                }
            }
            ExportItem::Slot { t_version, slot } => {
                if *t_version == 0 {
                    return err("t_version 0");
                }
                slot.check().map_err(|m| format!("FSRS4EXP: {m}"))?;
                match &mut self.phase {
                    Phase::Slots {
                        device,
                        next,
                        last,
                        marks,
                    } => {
                        if *next > *last {
                            return err("heritage log overruns its count");
                        }
                        if slot.id.device != *device || slot.id.seq != *next {
                            return err("heritage slot out of sequence");
                        }
                        if let Some(&(seq, fp)) = marks.front() {
                            if seq == *next {
                                if fp != slot.fp {
                                    return err("mark does not match its slot");
                                }
                                marks.pop_front();
                            }
                        }
                        *next += 1;
                    }
                    Phase::Fork {
                        device,
                        count,
                        left,
                        prev,
                    } => {
                        if slot.id.device != *device || slot.id.seq > *count {
                            return err("fork slot outside its heritage log");
                        }
                        let key = (slot.id.seq, slot.fp);
                        if prev.is_some_and(|p| p >= key) {
                            return err("fork slots out of order");
                        }
                        *prev = Some(key);
                        *left -= 1;
                    }
                    _ => return err("slot outside a heritage or fork log"),
                }
                self.settle_slots();
            }
            ExportItem::ForkLog { source, device, n } => {
                self.open_log(LOG_FORK, *device)?;
                let count = match self.seen.get(device) {
                    Some(Seen::Heritage { source: s, count }) if s == source => *count,
                    _ => return err("fork log without a matching heritage log"),
                };
                if *n == 0 {
                    return err("empty fork log");
                }
                self.phase = Phase::Fork {
                    device: *device,
                    count,
                    left: *n,
                    prev: None,
                };
            }
        }
        Ok(())
    }

    /// 槽写够了就回到日志层。
    fn settle_slots(&mut self) {
        let done = match &self.phase {
            Phase::Slots { next, last, .. } => *next > *last,
            Phase::Fork { left, .. } => *left == 0,
            _ => false,
        };
        if done {
            self.phase = Phase::Logs;
        }
    }

    fn finish(&self) -> Result<(), String> {
        match self.expect() {
            Expect::End => Ok(()),
            _ => err("stream ends early"),
        }
    }
}

// ---------------------------------------------------------------- 写

/// 流式写：每一项编码后直接进 zstd 压缩器，内存只有压缩器的窗口与一项。
pub struct Export4Writer<W: Write> {
    out: zstd::stream::write::Encoder<'static, W>,
    grammar: Grammar,
    buf: crate::sync2::codec::Writer,
}

impl<W: Write> Export4Writer<W> {
    pub fn new(out: W, h: &ExportHeader) -> Result<Self, String> {
        let out = zstd::stream::write::Encoder::new(out, ZSTD_LEVEL)
            .map_err(|e| format!("FSRS4EXP compress: {e}"))?;
        let mut w = Export4Writer {
            out,
            grammar: Grammar::new(h.logs),
            buf: crate::sync2::codec::Writer::new(),
        };
        w.buf.raw(EXPORT4_MAGIC);
        w.buf.u8(EXPORT4_VER);
        w.buf.u8(0);
        h.collection.write(&mut w.buf);
        w.buf.uv(h.logs);
        w.flush_buf()?;
        Ok(w)
    }

    fn flush_buf(&mut self) -> Result<(), String> {
        self.out
            .write_all(&self.buf.buf)
            .map_err(|e| format!("FSRS4EXP write: {e}"))?;
        self.buf.buf.clear();
        Ok(())
    }

    /// 写一项。不合规则的（顺序、条数、链、身份）报错，什么都不写；报错后这个写者不该再用。
    pub fn item(&mut self, it: &ExportItem) -> Result<(), String> {
        self.grammar.step(it)?;
        write_item(&mut self.buf, it);
        self.flush_buf()
    }

    /// 收尾：日志条数必须与头里声明的相同、最后一条日志必须写完。交回底层的输出。
    pub fn finish(self) -> Result<W, String> {
        self.grammar.finish()?;
        self.out
            .finish()
            .map_err(|e| format!("FSRS4EXP compress: {e}"))
    }
}

fn write_item(w: &mut crate::sync2::codec::Writer, it: &ExportItem) {
    match it {
        ExportItem::NativeLog {
            device,
            public,
            count,
        } => {
            w.u8(LOG_NATIVE);
            device.write(w);
            w.bytes(public.as_ref().map_or(&[][..], |p| &p[..]));
            w.uv(*count);
        }
        ExportItem::NativeOp(op) => {
            w.u8(ITEM_OP);
            w.bytes(&op.encode());
        }
        ExportItem::NativeVoid { n, chain_after } => {
            w.u8(ITEM_VOID);
            w.uv(*n);
            w.raw(chain_after);
        }
        ExportItem::NativeTail(c) => w.raw(c),
        ExportItem::HeritageLog {
            source,
            device,
            count,
            marks,
        } => {
            w.u8(LOG_HERITAGE);
            source.write(w);
            device.write(w);
            w.uv(*count);
            w.uv(*marks);
        }
        ExportItem::Mark { seq, chain } => {
            w.uv(*seq);
            w.raw(chain);
        }
        ExportItem::Slot { t_version, slot } => {
            w.uv(u64::from(*t_version));
            slot.write(w);
        }
        ExportItem::ForkLog { source, device, n } => {
            w.u8(LOG_FORK);
            source.write(w);
            device.write(w);
            w.uv(*n);
        }
    }
}

// ---------------------------------------------------------------- 读

/// 流式读：边解压边解码（[ZstdWindow]），内存只有一个读窗口与一项（外加承袭日志的标记与每台设备一个摘要）。
pub struct Export4Reader<'s> {
    window: ZstdWindow<'s>,
    grammar: Grammar,
    /// 读出错之后不再往下读。
    failed: bool,
}

fn stream(e: StreamError) -> String {
    format!("FSRS4EXP: {e}")
}

fn read_chain(r: &mut Reader<'_>) -> DResult<Chain> {
    r.raw(32)?.try_into().map_err(|_| DecodeError("chain"))
}

fn read_t_version(r: &mut Reader<'_>) -> DResult<u32> {
    u32::try_from(uv_min(r)?).map_err(|_| DecodeError("t_version"))
}

fn read_log(r: &mut Reader<'_>) -> DResult<ExportItem> {
    match r.u8()? {
        LOG_NATIVE => {
            let device = Id::read(r)?;
            let public = match super::bytes_min(r)? {
                [] => None,
                p => Some(<[u8; 32]>::try_from(p).map_err(|_| DecodeError("public key length"))?),
            };
            Ok(ExportItem::NativeLog {
                device,
                public,
                count: uv_min(r)?,
            })
        }
        LOG_HERITAGE => Ok(ExportItem::HeritageLog {
            source: Id::read(r)?,
            device: Id::read(r)?,
            count: uv_min(r)?,
            marks: uv_min(r)?,
        }),
        LOG_FORK => Ok(ExportItem::ForkLog {
            source: Id::read(r)?,
            device: Id::read(r)?,
            n: uv_min(r)?,
        }),
        _ => Err(DecodeError("unknown log tag")),
    }
}

fn read_native_item(r: &mut Reader<'_>) -> DResult<ExportItem> {
    match r.u8()? {
        ITEM_OP => {
            let mut inner = Reader::new(super::bytes_min(r)?);
            let op = Op4::read(&mut inner)?;
            if !inner.is_empty() {
                return Err(DecodeError("trailing bytes in op"));
            }
            Ok(ExportItem::NativeOp(op))
        }
        ITEM_VOID => Ok(ExportItem::NativeVoid {
            n: uv_min(r)?,
            chain_after: read_chain(r)?,
        }),
        _ => Err(DecodeError("unknown native item tag")),
    }
}

impl<'s> Export4Reader<'s> {
    /// 解开头部。魔数不对（含协议 3 的 `FSRS2EXP`）、版本不认识、标志位非 0 都拒。
    pub fn open(bytes: &'s [u8]) -> Result<(Self, ExportHeader), String> {
        let mut window = ZstdWindow::new(bytes).map_err(stream)?;
        let magic = window
            .parse(|r| r.raw(8).map(<[u8]>::to_vec))
            .map_err(stream)?;
        if magic != EXPORT4_MAGIC {
            return err("not a protocol 4 operations stream");
        }
        let ver = window.parse(|r| r.u8()).map_err(stream)?;
        if ver != EXPORT4_VER {
            return err(format!("unsupported version {ver}"));
        }
        if window.parse(|r| r.u8()).map_err(stream)? != 0 {
            return err("unknown flags");
        }
        let collection = window.parse(Id::read).map_err(stream)?;
        let logs = window.parse(uv_min).map_err(stream)?;
        Ok((
            Export4Reader {
                window,
                grammar: Grammar::new(logs),
                failed: false,
            },
            ExportHeader { collection, logs },
        ))
    }

    /// 下一项；流读完了（且没有尾字节）返回 `None`。
    pub fn next_item(&mut self) -> Result<Option<ExportItem>, String> {
        if self.failed {
            return err("reader already failed");
        }
        let r = self.next_inner();
        if r.is_err() {
            self.failed = true;
        }
        r
    }

    fn next_inner(&mut self) -> Result<Option<ExportItem>, String> {
        let it = match self.grammar.expect() {
            Expect::End => {
                if !self.window.at_end().map_err(stream)? {
                    return err("trailing bytes");
                }
                return Ok(None);
            }
            Expect::Log => self.window.parse(read_log),
            Expect::NativeItem => self.window.parse(read_native_item),
            Expect::Tail => self.window.parse(read_chain).map(ExportItem::NativeTail),
            Expect::Mark => self.window.parse(|r| {
                Ok(ExportItem::Mark {
                    seq: uv_min(r)?,
                    chain: read_chain(r)?,
                })
            }),
            Expect::Slot => self.window.parse(|r| {
                Ok(ExportItem::Slot {
                    t_version: read_t_version(r)?,
                    slot: HeritageSlot::read(r)?,
                })
            }),
        }
        .map_err(stream)?;
        self.grammar.step(&it)?;
        Ok(Some(it))
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::gen4::golden;
    use crate::gen4::heritage::tests::slots;
    use crate::gen4::op::tests::{id, native_edit, op_of, sample_log};
    use crate::gen4::op::{Body4, Edit4};
    use crate::gen4::stamp::tests::typical;
    use crate::sync2::hlc::Hlc;
    use crate::sync2::vv::{OpId, Vv};

    const NAT: u8 = 0xa1;
    const OLD: u8 = 0x0d;
    const SRC: u8 = 0x5c;

    fn coll() -> Id {
        id(0xc0)
    }

    fn compress(plain: &[u8]) -> Vec<u8> {
        zstd::bulk::compress(plain, ZSTD_LEVEL).unwrap()
    }

    fn plain_of(stream: &[u8]) -> Vec<u8> {
        zstd::stream::decode_all(stream).unwrap()
    }

    /// 一条原生日志：两条操作、一段 2 条的空洞、再一条操作（seq 1..=5）。
    fn native_items() -> Vec<ExportItem> {
        let dev = id(NAT);
        let op = |seq: u64, body: &Body4| {
            let mut o = op_of(dev, seq, body);
            o.hlc = Hlc {
                wall: o.hlc.wall,
                logical: 0,
                device: dev,
            };
            o
        };
        let o1 = op(1, &Body4::Edit(native_edit()));
        let o2 = op(2, &Body4::Log(sample_log()));
        let o5 = op(5, &Body4::salts(["u1", "u2"]).unwrap());
        let void_end = [0x44; 32];
        // 空洞把链重置成它的 chain_after，前两条操作的链值不影响末尾。
        let chain = chain_next4(&void_end, &o5);
        vec![
            ExportItem::NativeLog {
                device: dev,
                public: Some([0x9a; 32]),
                count: 5,
            },
            ExportItem::NativeOp(o1),
            ExportItem::NativeOp(o2),
            ExportItem::NativeVoid {
                n: 2,
                chain_after: void_end,
            },
            ExportItem::NativeOp(o5),
            ExportItem::NativeTail(chain),
        ]
    }

    /// 承袭日志（seq 1..=8，标记在 1 与 8）+ 它在 seq 2 处的一条分叉。
    fn heritage_items() -> Vec<ExportItem> {
        let ss = slots();
        let mark = |s: &HeritageSlot| {
            let mut c = [0x77; 32];
            c[..8].copy_from_slice(&s.fp);
            ExportItem::Mark {
                seq: s.id.seq,
                chain: c,
            }
        };
        let mut out = vec![
            ExportItem::HeritageLog {
                source: id(SRC),
                device: id(OLD),
                count: ss.len() as u64,
                marks: 2,
            },
            mark(&ss[0]),
            mark(&ss[ss.len() - 1]),
        ];
        for (i, s) in ss.iter().enumerate() {
            out.push(ExportItem::Slot {
                t_version: if i == 3 { 2 } else { 1 },
                slot: s.clone(),
            });
        }
        let mut fork = ss[1].clone();
        fork.fp = [0xf0; 8];
        out.push(ExportItem::ForkLog {
            source: id(SRC),
            device: id(OLD),
            n: 1,
        });
        out.push(ExportItem::Slot {
            t_version: 1,
            slot: fork,
        });
        out
    }

    /// 只有公钥、没有操作的原生日志。
    fn empty_native(b: u8) -> Vec<ExportItem> {
        vec![
            ExportItem::NativeLog {
                device: id(b),
                public: None,
                count: 0,
            },
            ExportItem::NativeTail(CHAIN_ZERO),
        ]
    }

    fn logs_in(items: &[ExportItem]) -> u64 {
        items
            .iter()
            .filter(|i| {
                matches!(
                    i,
                    ExportItem::NativeLog { .. }
                        | ExportItem::HeritageLog { .. }
                        | ExportItem::ForkLog { .. }
                )
            })
            .count() as u64
    }

    fn sample() -> Vec<ExportItem> {
        let mut items = native_items();
        items.extend(empty_native(0xb2));
        items.extend(heritage_items());
        items
    }

    fn write_all(items: &[ExportItem]) -> Result<Vec<u8>, String> {
        let mut w = Export4Writer::new(
            Vec::new(),
            &ExportHeader {
                collection: coll(),
                logs: logs_in(items),
            },
        )?;
        for it in items {
            w.item(it)?;
        }
        w.finish()
    }

    fn read_all(bytes: &[u8]) -> Result<(ExportHeader, Vec<ExportItem>), String> {
        let (mut r, h) = Export4Reader::open(bytes)?;
        let mut out = Vec::new();
        while let Some(it) = r.next_item()? {
            out.push(it);
        }
        Ok((h, out))
    }

    /// 明文（未压缩）的写法：给手工拼坏字节的测试用。
    fn plain(items: &[ExportItem], logs: u64) -> Vec<u8> {
        let mut w = crate::sync2::codec::Writer::new();
        w.raw(EXPORT4_MAGIC);
        w.u8(EXPORT4_VER);
        w.u8(0);
        coll().write(&mut w);
        w.uv(logs);
        for it in items {
            write_item(&mut w, it);
        }
        w.into_vec()
    }

    #[test]
    fn round_trip() {
        let items = sample();
        let bytes = write_all(&items).unwrap();
        let (h, got) = read_all(&bytes).unwrap();
        assert_eq!(
            h,
            ExportHeader {
                collection: coll(),
                logs: 4
            }
        );
        assert_eq!(got, items);
        // 写者的明文就是逐项编码首尾相接。
        assert_eq!(plain_of(&bytes), plain(&items, 4));
        // 空集合：只有头。
        let empty = write_all(&[]).unwrap();
        let (h, got) = read_all(&empty).unwrap();
        assert_eq!((h.logs, got.len()), (0, 0));
        assert_eq!(sniff(&empty).unwrap(), ExportKind::V4);
    }

    /// 明文布局冻结：改动任何一个向量都等于换格式（升 `ver`）。
    #[test]
    fn golden_vectors() {
        golden(
            "export4_header_empty",
            &plain(&[], 0),
            "46535253344558500100c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c000",
        );
        let dev = id(NAT);
        let op = op_of(dev, 1, &Body4::salts(["u"]).unwrap());
        let nat = vec![
            ExportItem::NativeLog {
                device: dev,
                public: None,
                count: 3,
            },
            ExportItem::NativeOp(op),
            ExportItem::NativeVoid {
                n: 2,
                chain_after: [0x22; 32],
            },
            ExportItem::NativeTail([0x22; 32]),
        ];
        golden(
            "export4_native",
            &plain(&nat, 1)[27..],
            "00a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a100030030a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a10182c0e285e3680001d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2050f0403010175030222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222",
        );
        let ss = slots();
        let her = vec![
            ExportItem::HeritageLog {
                source: id(SRC),
                device: id(OLD),
                count: 1,
                marks: 1,
            },
            ExportItem::Mark {
                seq: 1,
                chain: {
                    let mut c = [0x77; 32];
                    c[..8].copy_from_slice(&ss[0].fp);
                    c
                },
            },
            ExportItem::Slot {
                t_version: 1,
                slot: HeritageSlot::void(ss[0].id, ss[0].fp),
            },
            ExportItem::ForkLog {
                source: id(SRC),
                device: id(OLD),
                n: 1,
            },
            ExportItem::Slot {
                t_version: 2,
                slot: HeritageSlot::void(ss[0].id, [0xf0; 8]),
            },
        ];
        golden(
            "export4_heritage_fork",
            &plain(&her, 2)[27..],
            "015c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0101010101010101010101777777777777777777777777777777777777777777777777010d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d01010101010101010103025c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d01020d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d01f0f0f0f0f0f0f0f003",
        );
        // 冻结的明文能读回同样的项。
        assert_eq!(read_all(&compress(&plain(&nat, 1))).unwrap().1, nat);
        assert_eq!(read_all(&compress(&plain(&her, 2))).unwrap().1, her);
    }

    #[test]
    fn truncated_streams_are_rejected() {
        let items = sample();
        let p = plain(&items, 4);
        // 明文在任何位置截断（再压成完整的 zstd 帧）都报错。
        for n in 0..p.len() {
            assert!(read_all(&compress(&p[..n])).is_err(), "plain cut at {n}");
        }
        // 压缩流本身截断也报错（不 panic）。
        let bytes = write_all(&items).unwrap();
        for n in 0..bytes.len() {
            assert!(read_all(&bytes[..n]).is_err(), "stream cut at {n}");
        }
        // 尾字节。
        let mut tail = p.clone();
        tail.push(0);
        assert!(read_all(&compress(&tail)).unwrap_err().contains("trailing"));
    }

    #[test]
    fn bad_magic_and_unknown_versions_are_rejected() {
        let p = plain(&sample(), 4);
        let mut bad = p.clone();
        bad[0] = b'X';
        assert!(Export4Reader::open(&compress(&bad)).is_err());
        assert!(sniff(&compress(&bad)).is_err());
        for ver in [0u8, 2, 255] {
            let mut v = p.clone();
            v[8] = ver;
            let e = Export4Reader::open(&compress(&v)).err().unwrap();
            assert!(e.contains("unsupported version"), "{e}");
            // 嗅探只看魔数：仍是第 4 代，版本由读者拒。
            assert_eq!(sniff(&compress(&v)).unwrap(), ExportKind::V4);
        }
        let mut f = p.clone();
        f[9] = 1;
        assert!(
            Export4Reader::open(&compress(&f))
                .err()
                .unwrap()
                .contains("flags")
        );
        // 不是 zstd。
        assert!(Export4Reader::open(&p).is_err());
        assert!(Export4Reader::open(&[]).is_err());
        // 协议 3 的导出流：魔数处就拒。
        let mut v1 = b"FSRS2EXP".to_vec();
        v1.push(1);
        v1.extend_from_slice(&coll().0);
        v1.push(0);
        let v1 = compress(&v1);
        assert!(
            Export4Reader::open(&v1)
                .err()
                .unwrap()
                .contains("not a protocol 4")
        );
        assert_eq!(sniff(&v1).unwrap(), ExportKind::V1);
    }

    /// 非规范形逐项拒：非最短 varint、未知 tag、公钥长度、相邻空洞、操作内尾字节。
    #[test]
    fn non_canonical_forms_are_rejected() {
        let rejects = |p: Vec<u8>, what: &str| {
            let e = read_all(&compress(&p)).err();
            assert!(e.is_some(), "{what} accepted");
        };
        let p = plain(&empty_native(0xb2), 1);
        // n_logs 写成两字节。
        let mut v = p[..26].to_vec();
        v.extend_from_slice(&[0x81, 0x00]);
        v.extend_from_slice(&p[27..]);
        rejects(v, "non-minimal n_logs");
        // 未知日志 tag。
        let mut v = p.clone();
        v[27] = 9;
        rejects(v, "unknown log tag");
        // 公钥 5 字节。
        let mut w = crate::sync2::codec::Writer::new();
        w.u8(LOG_NATIVE);
        id(0xb2).write(&mut w);
        w.bytes(&[1, 2, 3, 4, 5]);
        w.uv(0);
        w.raw(&CHAIN_ZERO);
        let mut v = p[..27].to_vec();
        v.extend_from_slice(&w.into_vec());
        rejects(v, "public key of 5 bytes");
        // 未知项 tag：把原生日志第一项的 tag 改成 1。
        let nat = native_items();
        let mut v = plain(&nat, 1);
        let at = 27 + 1 + 16 + 1 + 32 + 1;
        assert_eq!(v[at], ITEM_OP);
        v[at] = 1;
        rejects(v, "unknown native item tag");
        // 相邻空洞（写者也拒）。
        let adj = vec![
            ExportItem::NativeLog {
                device: id(NAT),
                public: None,
                count: 3,
            },
            ExportItem::NativeVoid {
                n: 1,
                chain_after: [1; 32],
            },
            ExportItem::NativeVoid {
                n: 2,
                chain_after: [2; 32],
            },
            ExportItem::NativeTail([2; 32]),
        ];
        rejects(plain(&adj, 1), "adjacent voids");
        assert!(write_all(&adj).unwrap_err().contains("adjacent voids"));
        // 操作的独立编码后面多一个字节。
        let o = op_of(id(NAT), 1, &Body4::Edit(native_edit()));
        let mut ob = o.encode();
        ob.push(0);
        let mut w = crate::sync2::codec::Writer::new();
        w.u8(LOG_NATIVE);
        id(NAT).write(&mut w);
        w.bytes(&[]);
        w.uv(1);
        w.u8(ITEM_OP);
        w.bytes(&ob);
        w.raw(&chain_next4(&CHAIN_ZERO, &o));
        let mut v = p[..27].to_vec();
        v.extend_from_slice(&w.into_vec());
        rejects(v, "trailing bytes in op");
    }

    /// 读写两侧同一套语义规则：写者拒的，手拼成字节读者也拒。
    #[test]
    fn grammar_rules_hold_on_both_sides() {
        let check = |items: Vec<ExportItem>, logs: u64, what: &str| {
            let mut w = Export4Writer::new(
                Vec::new(),
                &ExportHeader {
                    collection: coll(),
                    logs,
                },
            )
            .unwrap();
            let wrote = items
                .iter()
                .try_for_each(|it| w.item(it))
                .and_then(|_| w.finish().map(|_| ()));
            assert!(wrote.is_err(), "writer accepted: {what}");
            assert!(
                read_all(&compress(&plain(&items, logs))).is_err(),
                "reader accepted: {what}"
            );
        };
        let nat = native_items();
        // 链尾对不上。
        let mut v = nat.clone();
        *v.last_mut().unwrap() = ExportItem::NativeTail([9; 32]);
        check(v, 1, "wrong tail");
        // 少一条（count 5，只给到 4）。
        let mut v = nat.clone();
        v.remove(4);
        check(v, 1, "short native log");
        // seq 跳号。
        let mut v = nat.clone();
        v.remove(1);
        check(v, 1, "native seq gap");
        // 别的设备的操作。
        let mut v = nat.clone();
        if let ExportItem::NativeOp(o) = &mut v[1] {
            *o = op_of(id(0x33), 1, &Body4::Edit(native_edit()));
        }
        check(v, 1, "foreign op");
        // 原生日志里出现带旧戳的修改（承袭专属）。
        let mut v = nat.clone();
        if let ExportItem::NativeOp(o) = &mut v[1] {
            *o = op_of(
                id(NAT),
                1,
                &Body4::Edit(Edit4 {
                    stamp: Some(typical()),
                    ..native_edit()
                }),
            );
        }
        check(v, 1, "stamped native edit");
        // 日志条数比声明的多 / 少。
        check(sample(), 3, "more logs than declared");
        check(sample(), 5, "fewer logs than declared");
        // 同 tag 内 device 不升序。
        let mut v = empty_native(0xb2);
        v.extend(empty_native(0xb1));
        check(v, 2, "devices out of order");
        // 承袭在原生之前。
        let mut v = heritage_items();
        let forkless: Vec<_> = v.drain(..v.len() - 2).collect();
        let mut v = forkless.clone();
        v.extend(empty_native(0xb2));
        check(v, 2, "heritage before native");
        // 同一台设备既有原生又有承袭日志。
        let mut v = empty_native(OLD);
        v.extend(forkless.clone());
        check(v, 2, "device with two logs");
        // 标记与槽的指纹对不上。
        let mut v = forkless.clone();
        if let ExportItem::Mark { chain, .. } = &mut v[1] {
            chain[0] ^= 1;
        }
        check(v, 1, "mark fp mismatch");
        // 标记越过日志末尾 / 不升序。
        let mut v = forkless.clone();
        if let ExportItem::Mark { seq, .. } = &mut v[2] {
            *seq = 99;
        }
        check(v, 1, "mark past the log");
        let mut v = forkless.clone();
        v.swap(1, 2);
        check(v, 1, "marks out of order");
        // 承袭槽跳号。
        let mut v = forkless.clone();
        v.remove(4);
        check(v, 1, "heritage seq gap");
        // t_version 0。
        let mut v = forkless.clone();
        if let ExportItem::Slot { t_version, .. } = &mut v[3] {
            *t_version = 0;
        }
        check(v, 1, "t_version 0");
        // 分叉日志没有对应的承袭日志 / 来源不同 / 越过承袭日志末尾 / 不升序 / 为空。
        let fork_slot = |seq: u64, fp: u8| {
            let mut s = slots()[1].clone();
            s.fp = [fp; 8];
            if seq != 2 {
                s = HeritageSlot::void(
                    OpId {
                        device: id(OLD),
                        seq,
                    },
                    [fp; 8],
                );
            }
            ExportItem::Slot {
                t_version: 1,
                slot: s,
            }
        };
        let fork = |source: u8, n: u64| ExportItem::ForkLog {
            source: id(source),
            device: id(OLD),
            n,
        };
        check(vec![fork(SRC, 1), fork_slot(2, 1)], 1, "orphan fork");
        let mut v = forkless.clone();
        v.extend([fork(0x99, 1), fork_slot(2, 1)]);
        check(v, 2, "fork from another source");
        let mut v = forkless.clone();
        v.extend([fork(SRC, 1), fork_slot(9, 1)]);
        check(v, 2, "fork past the heritage log");
        let mut v = forkless.clone();
        v.extend([fork(SRC, 2), fork_slot(2, 2), fork_slot(2, 1)]);
        check(v, 2, "fork slots out of order");
        let mut v = forkless.clone();
        v.push(fork(SRC, 0));
        check(v, 2, "empty fork log");
    }

    /// 原生操作的依赖向量点名作者自己：两侧都拒。
    #[test]
    fn deps_naming_the_author_are_rejected() {
        let dev = id(NAT);
        let mut o = op_of(dev, 1, &Body4::Edit(native_edit()));
        let mut deps = Vv::new();
        deps.set(dev, 1);
        o.deps = Arc::new(deps);
        let items = vec![
            ExportItem::NativeLog {
                device: dev,
                public: None,
                count: 1,
            },
            ExportItem::NativeTail(chain_next4(&CHAIN_ZERO, &o)),
        ];
        let mut with_op = items.clone();
        with_op.insert(1, ExportItem::NativeOp(o));
        assert!(write_all(&with_op).is_err());
        assert!(read_all(&compress(&plain(&with_op, 1))).is_err());
    }
}
