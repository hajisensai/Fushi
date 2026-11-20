//! 协议 4 的内核导出流 `ops.bin`（`.fushisrs` 第 2 版里的那一条；规划 g7_g11 §1.9、实现拆分 G11-1）。
//!
//! 纯编解码：不碰 SQLite，**没有接进导出 / 导入入口**（存储侧的导入导出是 G11-2，命令接线是 G11-3）。
//! 一个集合的真相层整份写成一条流：每条原生日志（含空洞）、每条承袭日志（槽 + 原链值标记 + 分叉的另一支）。
//! 待投递的槽（`op_pending`）不进导出（D34）。
//!
//! ```text
//! 整条流 zstd 压缩（单帧、流式）；下面是明文。
//!
//! 头    "FSRS4EXP"[8] | ver u8（写 2，读 1 或 2）| flags u8 = 0 | collection[16] | n_logs uv
//! 日志  tag u8，按 tag 不降、同 tag 内按 device 严格升序；原生与承袭的 device 互不相同
//!   0 原生  device[16] | bytes(public：0 或 32 字节) | count uv（日志覆盖 seq 1..=count）
//!           | 项 × 若干，首尾相接覆盖 1..=count | tail_chain[32]
//!           | （ver >= 3）转发材料：n_versions uv | n_stubs uv | 作者签名版本 × n_versions | 剔除记录 × n_stubs
//!           作者签名版本  bytes(原段头 `NativeHeader`，规范形) | sig[64] | n_voids uv
//!                         | (起始 seq uv, 条数 uv, 区间末链值[32]) × n_voids
//!                         段头的 device 必须是这条日志的；1 <= first <= last；按 (first, last) 严格升序；作者签的空洞
//!                         落在 [first, last] 里、按起始 seq 升序、互不重叠、条数 >= 1
//!           剔除记录      bytes(`gen4/recut.rs` `Stub` 的独立编码，规范形)：操作号属于这条日志、seq 严格升序、落在这条
//!                         日志的某个空洞区间里
//!           项  tag u8
//!             0 操作  bytes(协议 4 操作的独立编码：信封 + 操作体，`Op4::encode`)
//!             3 空洞  n uv（>= 1）| chain_after[32]          相邻两个空洞拒绝（写者合并）
//!             4 带记号的空洞（ver >= 2）  n uv（>= 2）| chain_after[32] | n_marks uv（>= 1）| (seq uv, chain[32]) × n_marks
//!                     记号是区间内部（不含区间末）那几格的完整链值：seq 严格升序、落在 [区间首, 区间末) 里。没有记号的
//!                     空洞只能写成 3（一个值只有一种字节形）
//!   1 承袭  source[16] | device[16] | count uv（日志槽覆盖 seq 1..=count）| n_forks uv（count 为 0 时必须为 0）
//!           | n_marks uv | (seq uv, chain[32]) × n_marks    seq 严格升序、1 <= seq <= count
//!           | (t_version uv, 槽的独立编码 `HeritageSlot::encode`) × (count + n_forks)
//!           槽按 (seq, fp) 严格升序：每个 seq 的第一个槽是日志里的那个，同 seq 后面跟着的是分叉的另一支（`op_forks`），
//!           链指纹必须严格大于前一个——即真相层「每个 seq 上链指纹最小的在日志里」的不变式，同一份真相只有一种字节形
//! ```
//!
//! 校验（读写两侧同一套规则，[Grammar]）：
//!
//! - 只收规范形：varint 最短形（`uv_min`）、`flags` 必须为 0、未知 tag 拒、读完最后一条日志后不许有尾字节。
//! - 原生日志逐条重算链（`chain_next4`；空洞处重置为 `chain_after`），末尾必须等于 `tail_chain`；每条操作的身份与日志一致、
//!   `seq` 连续，内容按 [super::op::native_allowed]（与原生段相同）。
//! - 承袭日志的日志槽从 1 起连续、属于这台旧设备，自洽（`HeritageSlot::check`）；每个标记的链值前 8 字节必须等于那个 seq 的
//!   日志槽的链指纹。标记排在槽前面、分叉支紧跟它的日志槽，所以读者只用记标记与上一个槽的 (seq, fp)，内存不随日志长度增长。
//! - 压缩流只许一个 zstd 帧：帧后面还有字节（垃圾或第二个帧）拒。
//! - `t_version` 逐槽记录而不是逐日志：真相层里同一条承袭日志的槽可以来自不同版本的转译（store/gen4/truth.rs「槽的落库规则」）。
//!
//! 与协议 3 的导出流（魔数 `FSRS2EXP`，store/sync2/transport.rs）互不误读：魔数不同，协议 3 的读者在魔数处就报
//! 「not a .fushisrs file」，本读者同样拒绝 `FSRS2EXP`；[sniff] 分得出两者。冻结的协议 3 读入器在 store/gen4/legacy_export.rs。
//!
//! 版本号与演进：`ver` 是本文件布局的版本。布局的任何变化都升 `ver`，读者对不认识的 `ver` 一律拒收（不按已知前缀读）。
//!
//! - 1（G11-1）：空洞只带区间末的链值。
//! - 2（第五波，交接 §38「第五波 导入与写接口」）：加项 4「带记号的空洞」。别的设备的原生日志上分几次清除、合并成一个空洞
//!   区间时，区间内部原来的区间末链值记成链值记号（`store/gen4/truth.rs` `insert_void_run`，交接 §33），转发按作者的
//!   切点重切段要用；第 1 版的流带不走它们，从备份 / 导出还原的库遇到切点埋在空洞里的作者段，只能整台不转发。第 2 版的
//!   写者在空洞内部有记号时写项 4。读者照读第 1 版（没有项 4，项 4 出现即拒）；只认第 1 版的读者（G11 之后、本版之前的
//!   开发构建）对第 2 版报「unsupported version 2」，不误读。
//! - 3（第六波，交接「第六波 转发收尾」）：每条原生日志的链尾之后带**转发材料**——本机收下的作者签名版本
//!   （`relay_auth`）与本机清除别人的操作时记下的剔除记录（`relay_stubs`）。从日志重切作者段（`FRX4`，
//!   `store/gen4/sync_state.rs` `recut_from_log`）要这两样；第 2 版的流带不走它们，从备份 / 导出还原的库清除过的
//!   作者段重切不出来、整台退回「不转发」。材料是收来的数据，不可信：导入方照存，重切时先拿作者公钥核过作者签名
//!   才签出（读者另外独立验），坏的只会让那一段重切不出来。读者照读第 1、2 版（没有转发材料）。

use std::collections::{HashSet, VecDeque};
use std::io::Write;

use super::heritage::{Fp, HeritageSlot, fingerprint};
use super::op::{Op4, chain_next4, native_allowed, payload_within_cap};
use super::recut::Stub;
use super::segment::NativeHeader;
use super::uv_min;
use crate::sync2::codec::{DResult, DecodeError, Reader, StreamError, ZstdWindow};
use crate::sync2::id::Id;
use crate::sync2::segment::{CHAIN_ZERO, Chain};

pub const EXPORT4_MAGIC: &[u8; 8] = b"FSRS4EXP";
/// 写者写的版本（模块文档「版本号与演进」）。
pub const EXPORT4_VER: u8 = 3;
/// 读者还认的最旧版本。
pub const EXPORT4_VER_OLDEST: u8 = 1;
/// 协议 3 导出流的魔数（只用来嗅探；读它的是 store/gen4/legacy_export.rs）。
pub const EXPORT1_MAGIC: &[u8; 8] = b"FSRS2EXP";
/// 压缩级别。压缩输出不是契约（解码方向才是）；换级别不改格式。
pub const ZSTD_LEVEL: i32 = 3;

const LOG_NATIVE: u8 = 0;
const LOG_HERITAGE: u8 = 1;
const ITEM_OP: u8 = 0;
const ITEM_VOID: u8 = 3;
/// 带链值记号的空洞（ver >= 2）。
const ITEM_VOID_MARKED: u8 = 4;
/// 项 4 起于这一版。
const VER_VOID_MARKS: u8 = 2;
/// 原生日志链尾之后的转发材料起于这一版。
const VER_RELAY: u8 = 3;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExportHeader {
    pub collection: Id,
    /// 流里的日志条数（原生 + 承袭）。
    pub logs: u64,
}

/// 流里的一项（按出现顺序）。日志抬头之后跟它的内容：
///
/// - [ExportItem::NativeLog] → `NativeOp` / `NativeVoid` 若干（覆盖 1..=count）→ [ExportItem::NativeTail]；
/// - [ExportItem::HeritageLog] → [ExportItem::Mark] × marks → [ExportItem::Slot] × (count + forks)，
///   每个日志槽后面紧跟同 seq 的分叉槽（链指纹严格升序）。
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
        /// 区间内部（不含区间末）记着的完整链值，seq 升序；第 1 版的流恒为空。
        marks: Vec<(u64, Chain)>,
    },
    NativeTail(Chain),
    /// 原生日志链尾之后的转发材料条数（ver >= 3，每条原生日志恰好一项）：后面跟 `versions` 个
    /// [ExportItem::AuthorVersion]、再 `stubs` 个 [ExportItem::Stub]。
    NativeRelay {
        versions: u64,
        stubs: u64,
    },
    /// 一段作者签过的原段头、作者签名与作者签的空洞（起始 seq, 条数, 区间末链值）。
    AuthorVersion {
        header: NativeHeader,
        sig: [u8; 64],
        voids: Vec<(u64, u64, Chain)>,
    },
    /// 一条被挖掉的这台设备的操作的剔除记录。
    Stub(Stub),
    HeritageLog {
        source: Id,
        device: Id,
        count: u64,
        /// 分叉的另一支（`op_forks`）的槽数，穿插在日志槽之间。
        forks: u64,
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
    sniff_reader(bytes)
}

/// [sniff] 的一般形：来源是任何顺序读的 [std::io::Read]（只读到解出前 8 字节为止）。
pub fn sniff_reader<R: std::io::Read>(src: R) -> Result<ExportKind, String> {
    let mut window = ZstdWindow::from_reader(src).map_err(|e| e.to_string())?;
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

enum Phase {
    /// 等下一条日志的抬头（或流结束）。
    Logs,
    Native {
        device: Id,
        next: u64,
        last: u64,
        chain: Chain,
        prev_void: bool,
        /// 这条日志的空洞区间 [首, 末]（转发材料的剔除记录要落在里面）。
        voids: Vec<(u64, u64)>,
    },
    /// 链尾之后等转发材料的条数（ver >= 3）。
    RelayCounts { device: Id, voids: Vec<(u64, u64)> },
    Relay {
        device: Id,
        voids: Vec<(u64, u64)>,
        versions: u64,
        stubs: u64,
        /// 上一个作者签名版本的 (first, last)、上一条剔除记录的 seq。
        prev_version: Option<(u64, u64)>,
        prev_stub: u64,
        /// 剔除记录核对到的空洞下标：空洞与剔除记录都按 seq 升序，双指针前进（不逐条扫全部空洞）。
        void_at: usize,
    },
    Marks {
        device: Id,
        count: u64,
        forks: u64,
        left: u64,
        prev: u64,
        marks: VecDeque<(u64, Fp)>,
    },
    Slots {
        device: Id,
        /// 下一个日志槽的 seq。
        next: u64,
        last: u64,
        /// 还没出现的分叉槽数。
        forks: u64,
        /// 上一个槽（日志槽或分叉槽）的 (seq, fp)：同 seq 的分叉槽要排在它后面。
        cur: Option<(u64, Fp)>,
        marks: VecDeque<(u64, Fp)>,
    },
}

/// 下一项该是什么（读者按它决定怎么解下一段字节）。
enum Expect {
    Log,
    NativeItem,
    Tail,
    RelayCounts,
    Version,
    Stub,
    Mark,
    Slot,
    End,
}

/// 流的规范形规则：写者每写一项、读者每读一项都过一遍，两侧收的东西完全相同。
struct Grammar {
    /// 流的版本（写者是 [EXPORT4_VER]，读者是头里的）。
    ver: u8,
    logs_left: u64,
    /// 上一条日志的 (tag, device)。
    prev_log: Option<(u8, Id)>,
    seen: HashSet<Id>,
    phase: Phase,
}

fn err<T>(m: impl Into<String>) -> Result<T, String> {
    Err(format!("FSRS4EXP: {}", m.into()))
}

impl Grammar {
    fn new(logs: u64, ver: u8) -> Grammar {
        Grammar {
            ver,
            logs_left: logs,
            prev_log: None,
            seen: HashSet::new(),
            phase: Phase::Logs,
        }
    }

    fn expect(&self) -> Expect {
        match &self.phase {
            Phase::Logs if self.logs_left == 0 => Expect::End,
            Phase::Logs => Expect::Log,
            Phase::Native { next, last, .. } if *next > *last => Expect::Tail,
            Phase::Native { .. } => Expect::NativeItem,
            Phase::RelayCounts { .. } => Expect::RelayCounts,
            Phase::Relay { versions, .. } if *versions > 0 => Expect::Version,
            Phase::Relay { .. } => Expect::Stub,
            Phase::Marks { .. } => Expect::Mark,
            Phase::Slots { .. } => Expect::Slot,
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

    fn claim(&mut self, device: Id) -> Result<(), String> {
        if !self.seen.insert(device) {
            return err(format!("device {device} has two logs"));
        }
        Ok(())
    }

    fn step(&mut self, it: &ExportItem) -> Result<(), String> {
        match it {
            ExportItem::NativeLog { device, count, .. } => {
                self.open_log(LOG_NATIVE, *device)?;
                self.claim(*device)?;
                self.phase = Phase::Native {
                    device: *device,
                    next: 1,
                    last: *count,
                    chain: CHAIN_ZERO,
                    prev_void: false,
                    voids: Vec::new(),
                };
            }
            ExportItem::NativeOp(op) => {
                let Phase::Native {
                    device,
                    next,
                    last,
                    chain,
                    prev_void,
                    ..
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
                // 太大的一条给看得懂的报错（导入页按 [super::op::ERR_OP_TOO_LARGE] 认出来），其余照收段的口径。
                payload_within_cap(op).map_err(|m| format!("FSRS4EXP: {m}"))?;
                native_allowed(op).map_err(|m| format!("FSRS4EXP: {m}"))?;
                *chain = chain_next4(chain, op);
                *next += 1;
                *prev_void = false;
            }
            ExportItem::NativeVoid {
                n,
                chain_after,
                marks,
            } => {
                let Phase::Native {
                    next,
                    last,
                    chain,
                    prev_void,
                    voids,
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
                if !marks.is_empty() && self.ver < VER_VOID_MARKS {
                    return err("chain marks inside a void need version 2");
                }
                // 记号只在区间内部：[区间首, 区间末)，严格升序。
                let mut prev = None;
                for (seq, _) in marks {
                    if *seq < *next || *seq >= *next + *n - 1 || prev.is_some_and(|p| *seq <= p) {
                        return err("void marks out of order or outside the run");
                    }
                    prev = Some(*seq);
                }
                voids.push((*next, *next + *n - 1));
                *chain = *chain_after;
                *next += *n;
                *prev_void = true;
            }
            ExportItem::NativeTail(tail) => {
                let Phase::Native {
                    device,
                    next,
                    last,
                    chain,
                    voids,
                    ..
                } = &mut self.phase
                else {
                    return err("chain tail outside a native log");
                };
                if *next <= *last {
                    return err("native log ends before its count");
                }
                if chain != tail {
                    return err("native log chain does not reach its tail");
                }
                self.phase = if self.ver >= VER_RELAY {
                    Phase::RelayCounts {
                        device: *device,
                        voids: std::mem::take(voids),
                    }
                } else {
                    Phase::Logs
                };
            }
            ExportItem::NativeRelay { versions, stubs } => {
                let Phase::RelayCounts { device, voids } = &mut self.phase else {
                    return err("relay material outside a native log");
                };
                self.phase = Phase::Relay {
                    device: *device,
                    voids: std::mem::take(voids),
                    versions: *versions,
                    stubs: *stubs,
                    prev_version: None,
                    prev_stub: 0,
                    void_at: 0,
                };
                self.settle_relay();
            }
            ExportItem::AuthorVersion { header, voids, .. } => {
                let Phase::Relay {
                    device,
                    versions,
                    prev_version,
                    ..
                } = &mut self.phase
                else {
                    return err("author version outside the relay material");
                };
                if *versions == 0 {
                    return err("more author versions than declared");
                }
                if header.device != *device {
                    return err("author version of another device");
                }
                let range = (header.first, header.last);
                if range.0 == 0 || range.1 < range.0 || prev_version.is_some_and(|p| range <= p) {
                    return err("author versions out of order or empty");
                }
                let mut after = range.0;
                for (at, count, _) in voids {
                    if *count == 0 || *at < after || at.saturating_add(*count - 1) > range.1 {
                        return err("author version voids out of order or outside the segment");
                    }
                    after = at + count;
                }
                *prev_version = Some(range);
                *versions -= 1;
                self.settle_relay();
            }
            ExportItem::Stub(stub) => {
                let Phase::Relay {
                    device,
                    voids,
                    versions,
                    stubs,
                    prev_stub,
                    void_at,
                    ..
                } = &mut self.phase
                else {
                    return err("stub outside the relay material");
                };
                if *versions > 0 || *stubs == 0 {
                    return err("stub out of place");
                }
                let id = stub.id();
                if id.device != *device {
                    return err("stub of another device");
                }
                while voids.get(*void_at).is_some_and(|(_, b)| *b < id.seq) {
                    *void_at += 1;
                }
                let on_void = voids.get(*void_at).is_some_and(|(a, _)| *a <= id.seq);
                if id.seq <= *prev_stub || !on_void {
                    return err("stubs out of order or not on a void");
                }
                *prev_stub = id.seq;
                *stubs -= 1;
                self.settle_relay();
            }
            ExportItem::HeritageLog {
                source: _,
                device,
                count,
                forks,
                marks,
            } => {
                self.open_log(LOG_HERITAGE, *device)?;
                self.claim(*device)?;
                if *marks > *count {
                    return err("more marks than slots");
                }
                if *count == 0 && *forks > 0 {
                    return err("fork slots without log slots");
                }
                self.phase = if *marks == 0 {
                    Phase::Slots {
                        device: *device,
                        next: 1,
                        last: *count,
                        forks: *forks,
                        cur: None,
                        marks: VecDeque::new(),
                    }
                } else {
                    Phase::Marks {
                        device: *device,
                        count: *count,
                        forks: *forks,
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
                    forks,
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
                        forks: *forks,
                        cur: None,
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
                let Phase::Slots {
                    device,
                    next,
                    last,
                    forks,
                    cur,
                    marks,
                } = &mut self.phase
                else {
                    return err("slot outside a heritage log");
                };
                if slot.id.device != *device {
                    return err("heritage slot belongs to another device");
                }
                let (seq, fp) = (slot.id.seq, slot.fp);
                match *cur {
                    // 同 seq 的第二个起是分叉支：链指纹必须严格大于前一个（日志槽是最小的那个）。
                    Some((s, f)) if s == seq => {
                        if *forks == 0 {
                            return err("more fork slots than declared");
                        }
                        if fp <= f {
                            return err("fork slot does not sort after the slot before it");
                        }
                        *forks -= 1;
                        *cur = Some((seq, fp));
                    }
                    _ => {
                        if *next > *last || seq != *next {
                            return err("heritage slot out of sequence");
                        }
                        if let Some(&(ms, mfp)) = marks.front() {
                            if ms == seq {
                                if mfp != fp {
                                    return err("mark does not match its slot");
                                }
                                marks.pop_front();
                            }
                        }
                        *cur = Some((seq, fp));
                        *next += 1;
                    }
                }
                self.settle_slots();
            }
        }
        Ok(())
    }

    /// 转发材料写够了就回到日志层。
    fn settle_relay(&mut self) {
        if matches!(
            self.phase,
            Phase::Relay {
                versions: 0,
                stubs: 0,
                ..
            }
        ) {
            self.phase = Phase::Logs;
        }
    }

    /// 槽写够了就回到日志层。
    fn settle_slots(&mut self) {
        let done = match &self.phase {
            Phase::Slots {
                next, last, forks, ..
            } => *next > *last && *forks == 0,
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
            grammar: Grammar::new(h.logs, EXPORT4_VER),
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
        ExportItem::NativeVoid {
            n,
            chain_after,
            marks,
        } => {
            w.u8(if marks.is_empty() {
                ITEM_VOID
            } else {
                ITEM_VOID_MARKED
            });
            w.uv(*n);
            w.raw(chain_after);
            if !marks.is_empty() {
                w.uv(marks.len() as u64);
                for (seq, c) in marks {
                    w.uv(*seq);
                    w.raw(c);
                }
            }
        }
        ExportItem::NativeTail(c) => w.raw(c),
        ExportItem::NativeRelay { versions, stubs } => {
            w.uv(*versions);
            w.uv(*stubs);
        }
        ExportItem::AuthorVersion { header, sig, voids } => {
            let mut h = crate::sync2::codec::Writer::new();
            header.write(&mut h);
            w.bytes(&h.into_vec());
            w.raw(sig);
            w.uv(voids.len() as u64);
            for (at, count, chain) in voids {
                w.uv(*at);
                w.uv(*count);
                w.raw(chain);
            }
        }
        ExportItem::Stub(s) => w.bytes(&s.encode()),
        ExportItem::HeritageLog {
            source,
            device,
            count,
            forks,
            marks,
        } => {
            w.u8(LOG_HERITAGE);
            source.write(w);
            device.write(w);
            w.uv(*count);
            w.uv(*forks);
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
    }
}

/// 测试用：按第 1 版的布局写一整条流（压缩好）。项里有空洞记号（第 1 版写不出）报错。给「旧版本的流照读」的存储侧
/// 测试造输入用；产品代码只写当前版本（[Export4Writer]）。
#[cfg(test)]
pub(crate) fn encode_version_1(h: &ExportHeader, items: &[ExportItem]) -> Result<Vec<u8>, String> {
    let mut grammar = Grammar::new(h.logs, EXPORT4_VER_OLDEST);
    let mut w = crate::sync2::codec::Writer::new();
    w.raw(EXPORT4_MAGIC);
    w.u8(EXPORT4_VER_OLDEST);
    w.u8(0);
    h.collection.write(&mut w);
    w.uv(h.logs);
    for it in items {
        grammar.step(it)?;
        write_item(&mut w, it);
    }
    grammar.finish()?;
    zstd::bulk::compress(&w.into_vec(), ZSTD_LEVEL).map_err(|e| e.to_string())
}

/// 测试用：不过语法核对、按当前版本的布局写一整条流（压缩好）。给「读者拒收写者写不出的东西」（例如超过载荷上限的
/// 操作）的测试造输入用。
#[cfg(test)]
pub(crate) fn encode_unchecked(h: &ExportHeader, items: &[ExportItem]) -> Vec<u8> {
    let mut w = crate::sync2::codec::Writer::new();
    w.raw(EXPORT4_MAGIC);
    w.u8(EXPORT4_VER);
    w.u8(0);
    h.collection.write(&mut w);
    w.uv(h.logs);
    for it in items {
        write_item(&mut w, it);
    }
    zstd::bulk::compress(&w.into_vec(), ZSTD_LEVEL).expect("compress")
}

// ---------------------------------------------------------------- 读

/// 流式读：边解压边解码（[ZstdWindow]），内存只有一个读窗口与一项（外加承袭日志的标记与每台设备一个摘要）。
///
/// 来源默认是内存里的切片（[Export4Reader::open]）；[Export4Reader::open_reader] 收任何 [std::io::Read]（导入命令
/// 直接读文件，G11-3），两者收什么、拒什么完全相同。
pub struct Export4Reader<'s, R: std::io::Read = &'s [u8]> {
    window: ZstdWindow<'s, R>,
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
            forks: uv_min(r)?,
            marks: uv_min(r)?,
        }),
        _ => Err(DecodeError("unknown log tag")),
    }
}

/// 转发材料里的一个作者签名版本。段头只收规范形（重新编码与原字节相同）。
fn read_author_version(r: &mut Reader<'_>) -> DResult<ExportItem> {
    let raw = super::bytes_min(r)?;
    let mut inner = Reader::new(raw);
    let header = NativeHeader::read(&mut inner)?;
    let mut again = crate::sync2::codec::Writer::new();
    header.write(&mut again);
    if !inner.is_empty() || again.into_vec() != raw {
        return Err(DecodeError("author version header not canonical"));
    }
    let sig: [u8; 64] = r.raw(64)?.try_into().map_err(|_| DecodeError("sig"))?;
    let n = uv_min(r)?;
    let mut voids = Vec::with_capacity(n.min(1024) as usize);
    for _ in 0..n {
        voids.push((uv_min(r)?, uv_min(r)?, read_chain(r)?));
    }
    Ok(ExportItem::AuthorVersion { header, sig, voids })
}

/// 转发材料里的一条剔除记录（只收规范形）。
fn read_stub(r: &mut Reader<'_>) -> DResult<ExportItem> {
    let raw = super::bytes_min(r)?;
    let stub = Stub::decode(raw)?;
    if stub.encode() != raw {
        return Err(DecodeError("stub not canonical"));
    }
    Ok(ExportItem::Stub(stub))
}

fn read_native_item(r: &mut Reader<'_>, ver: u8) -> DResult<ExportItem> {
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
            marks: Vec::new(),
        }),
        ITEM_VOID_MARKED if ver >= VER_VOID_MARKS => {
            let n = uv_min(r)?;
            let chain_after = read_chain(r)?;
            let count = uv_min(r)?;
            // 至少一个记号（没有记号的空洞只能写成项 3），也不会多过区间内部的格数（语法再逐个核对位置）。
            if count == 0 || count >= n.max(1) {
                return Err(DecodeError("void mark count"));
            }
            let mut marks = Vec::with_capacity(count.min(1024) as usize);
            for _ in 0..count {
                marks.push((uv_min(r)?, read_chain(r)?));
            }
            Ok(ExportItem::NativeVoid {
                n,
                chain_after,
                marks,
            })
        }
        _ => Err(DecodeError("unknown native item tag")),
    }
}

impl<'s> Export4Reader<'s> {
    /// 解开头部。魔数不对（含协议 3 的 `FSRS2EXP`）、版本不认识、标志位非 0 都拒。
    pub fn open(bytes: &'s [u8]) -> Result<(Self, ExportHeader), String> {
        Export4Reader::open_reader(bytes)
    }
}

impl<'s, R: std::io::Read> Export4Reader<'s, R> {
    /// [Export4Reader::open] 的一般形：来源是任何顺序读的 [std::io::Read]（不整份读进内存）。
    pub fn open_reader(src: R) -> Result<(Self, ExportHeader), String> {
        let mut window = ZstdWindow::from_reader(src).map_err(stream)?;
        let magic = window
            .parse(|r| r.raw(8).map(<[u8]>::to_vec))
            .map_err(stream)?;
        if magic != EXPORT4_MAGIC {
            return err("not a protocol 4 operations stream");
        }
        let ver = window.parse(|r| r.u8()).map_err(stream)?;
        if !(EXPORT4_VER_OLDEST..=EXPORT4_VER).contains(&ver) {
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
                grammar: Grammar::new(logs, ver),
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

    /// 流头里的版本（[EXPORT4_VER_OLDEST]..=[EXPORT4_VER]）。
    pub fn version(&self) -> u8 {
        self.grammar.ver
    }

    /// 读窗口当前的容量（测试看内存上界用）。
    #[cfg(test)]
    pub fn window_capacity(&self) -> usize {
        self.window.window_capacity()
    }

    fn next_inner(&mut self) -> Result<Option<ExportItem>, String> {
        let it = match self.grammar.expect() {
            Expect::End => {
                if !self.window.at_end_of_input().map_err(stream)? {
                    return err("trailing bytes");
                }
                return Ok(None);
            }
            Expect::Log => self.window.parse(read_log),
            Expect::NativeItem => {
                let ver = self.grammar.ver;
                self.window.parse(|r| read_native_item(r, ver))
            }
            Expect::Tail => self.window.parse(read_chain).map(ExportItem::NativeTail),
            Expect::RelayCounts => self.window.parse(|r| {
                Ok(ExportItem::NativeRelay {
                    versions: uv_min(r)?,
                    stubs: uv_min(r)?,
                })
            }),
            Expect::Version => self.window.parse(read_author_version),
            Expect::Stub => self.window.parse(read_stub),
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
                marks: Vec::new(),
            },
            ExportItem::NativeOp(o5),
            ExportItem::NativeTail(chain),
        ]
    }

    /// 承袭日志（seq 1..=8，标记在 1 与 8），在 seq 2 处紧跟一条分叉槽。
    fn heritage_items() -> Vec<ExportItem> {
        let mut out = heritage_forkless();
        if let ExportItem::HeritageLog { forks, .. } = &mut out[0] {
            *forks = 1;
        }
        // 日志槽 seq 2 在下标 4（抬头、两个标记、seq 1）。
        out.insert(5, fork_slot(2, 0xf0));
        out
    }

    /// seq 处的一个分叉槽（seq 2 用真槽改指纹，其余用空洞）。
    fn fork_slot(seq: u64, fp: u8) -> ExportItem {
        let s = if seq == 2 {
            let mut s = slots()[1].clone();
            s.fp = [fp; 8];
            s
        } else {
            HeritageSlot::void(
                OpId {
                    device: id(OLD),
                    seq,
                },
                [fp; 8],
            )
        };
        ExportItem::Slot {
            t_version: 1,
            slot: s,
        }
    }

    /// 没有分叉的承袭日志。
    fn heritage_forkless() -> Vec<ExportItem> {
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
                forks: 0,
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
                    ExportItem::NativeLog { .. } | ExportItem::HeritageLog { .. }
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

    /// 项清单按第 3 版补齐：每个链尾后面没跟转发材料条数的，补一个空的（`NativeRelay {0, 0}`）。本文件的测试清单大多
    /// 照第 2 版的形状写（没有转发材料），写当前版本时经它补齐；[read_all] 读回时去掉空的那项，两边对得上。
    fn cur(items: &[ExportItem]) -> Vec<ExportItem> {
        let mut out = Vec::with_capacity(items.len() + 2);
        for (i, it) in items.iter().enumerate() {
            out.push(it.clone());
            if matches!(it, ExportItem::NativeTail(_))
                && !matches!(items.get(i + 1), Some(ExportItem::NativeRelay { .. }))
            {
                out.push(ExportItem::NativeRelay {
                    versions: 0,
                    stubs: 0,
                });
            }
        }
        out
    }

    fn write_all(items: &[ExportItem]) -> Result<Vec<u8>, String> {
        let items = cur(items);
        let mut w = Export4Writer::new(
            Vec::new(),
            &ExportHeader {
                collection: coll(),
                logs: logs_in(&items),
            },
        )?;
        for it in &items {
            w.item(it)?;
        }
        w.finish()
    }

    /// 读回全部项；空的转发材料条数（[cur] 补的）去掉。
    fn read_all(bytes: &[u8]) -> Result<(ExportHeader, Vec<ExportItem>), String> {
        let (mut r, h) = Export4Reader::open(bytes)?;
        let mut out = Vec::new();
        while let Some(it) = r.next_item()? {
            if !matches!(
                it,
                ExportItem::NativeRelay {
                    versions: 0,
                    stubs: 0
                }
            ) {
                out.push(it);
            }
        }
        Ok((h, out))
    }

    /// 明文（未压缩）的写法：给手工拼坏字节的测试用。
    fn plain(items: &[ExportItem], logs: u64) -> Vec<u8> {
        plain_ver(items, logs, EXPORT4_VER)
    }

    /// [plain]，头里写版本 [ver]（项照当前布局编码；第 1 版的流就是没有项 4 的同一种字节；第 3 版起经 [cur] 补齐转发
    /// 材料条数）。
    fn plain_ver(items: &[ExportItem], logs: u64, ver: u8) -> Vec<u8> {
        let items = if ver >= VER_RELAY {
            cur(items)
        } else {
            items.to_vec()
        };
        let mut w = crate::sync2::codec::Writer::new();
        w.raw(EXPORT4_MAGIC);
        w.u8(ver);
        w.u8(0);
        coll().write(&mut w);
        w.uv(logs);
        for it in &items {
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
                logs: 3
            }
        );
        assert_eq!(got, items);
        // 写者的明文就是逐项编码首尾相接。
        assert_eq!(plain_of(&bytes), plain(&items, 3));
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
            "46535253344558500300c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c000",
        );
        // 第 2 版的头冻结在这里：读者照读。
        golden(
            "export4_header_empty_v2",
            &plain_ver(&[], 0, 2),
            "46535253344558500200c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c000",
        );
        // 第 1 版的头冻结在这里：读者照读（`older_versions_still_read`）。
        golden(
            "export4_header_empty_v1",
            &plain_ver(&[], 0, 1),
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
                marks: Vec::new(),
            },
            ExportItem::NativeTail([0x22; 32]),
        ];
        golden(
            "export4_native",
            &plain(&nat, 1)[27..],
            "00a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a100030030a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a10182c0e285e3680001d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2050f04030101750302222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222220000",
        );
        let ss = slots();
        let her = vec![
            ExportItem::HeritageLog {
                source: id(SRC),
                device: id(OLD),
                count: 1,
                forks: 1,
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
            ExportItem::Slot {
                t_version: 2,
                slot: HeritageSlot::void(ss[0].id, [0xf0; 8]),
            },
        ];
        golden(
            "export4_heritage_fork",
            &plain(&her, 1)[27..],
            "015c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d010101010101010101010101777777777777777777777777777777777777777777777777010d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d01010101010101010103020d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d01f0f0f0f0f0f0f0f003",
        );
        // 带记号的空洞（项 4，第 2 版）。
        let marked = marked_native();
        golden(
            "export4_native_void_marks",
            &plain(&marked, 1)[27..],
            "00a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a10004040433333333333333333333333333333333333333333333333333333333333333330201111111111111111111111111111111111111111111111111111111111111111103131313131313131313131313131313131313131313131313131313131313131333333333333333333333333333333333333333333333333333333333333333330000",
        );
        // 冻结的明文能读回同样的项。
        assert_eq!(read_all(&compress(&plain(&nat, 1))).unwrap().1, nat);
        assert_eq!(read_all(&compress(&plain(&her, 1))).unwrap().1, her);
        assert_eq!(read_all(&compress(&plain(&marked, 1))).unwrap().1, marked);
    }

    /// 一条原生日志 seq 1..=4 整段是空洞，内部 1、3 两格带记号（区间末 4 的链值是 chain_after）。
    fn marked_native() -> Vec<ExportItem> {
        vec![
            ExportItem::NativeLog {
                device: id(NAT),
                public: None,
                count: 4,
            },
            ExportItem::NativeVoid {
                n: 4,
                chain_after: [0x33; 32],
                marks: vec![(1, [0x11; 32]), (3, [0x13; 32])],
            },
            ExportItem::NativeTail([0x33; 32]),
        ]
    }

    /// 第 1 版的流（空洞只带区间末链值）照读，读出的项与第 2 版写者写的相同；第 1 版里出现项 4 拒收。第 2 版的流对
    /// 只认第 1 版的读者是「unsupported version 2」（头一个字节就拒，见 [bad_magic_and_unknown_versions_are_rejected]
    /// 的同一条判断）。
    #[test]
    fn older_versions_still_read() {
        let items = sample();
        let v1_stream = compress(&plain_ver(&items, 3, 1));
        let (r, _) = Export4Reader::open(&v1_stream).unwrap();
        assert_eq!(r.version(), 1);
        assert_eq!(
            read_all(&compress(&plain_ver(&items, 3, 1))).unwrap().1,
            items
        );
        // 没有记号时，第 2 版与第 1 版只差头里的版本字节。
        let (v1, v2) = (plain_ver(&items, 3, 1), plain_ver(&items, 3, 2));
        assert_eq!((v1[8], v2[8]), (1, 2));
        assert_eq!(v1[9..], v2[9..]);
        // 第 2 版照读（没有转发材料），读出的项与当前版本写者写的相同。
        assert_eq!(read_all(&compress(&v2)).unwrap().1, items);
        assert_eq!(read_all(&write_all(&items).unwrap()).unwrap().1, items);
        // 第 2 版的流里出现转发材料：链尾之后按下一条日志读，拒收。
        assert!(read_all(&compress(&plain_ver(&cur(&items), 3, 2))).is_err());
        let e = read_all(&compress(&plain_ver(&marked_native(), 1, 1))).unwrap_err();
        assert!(e.contains("unknown native item tag"), "{e}");
        let v2_stream = write_all(&marked_native()).unwrap();
        let (r, _) = Export4Reader::open(&v2_stream).unwrap();
        assert_eq!(r.version(), EXPORT4_VER);
    }

    /// 空洞记号的规则读写两侧相同：越出区间、落在区间末、不升序都拒；项 4 不许零个记号、记号数不许多过区间内部的格数。
    #[test]
    fn void_marks_must_sit_inside_their_run() {
        let with = |marks: Vec<(u64, Chain)>| {
            let mut items = marked_native();
            if let ExportItem::NativeVoid { marks: m, .. } = &mut items[1] {
                *m = marks;
            }
            items
        };
        for (bad, what) in [
            (vec![(4, [1; 32])], "at the run end"),
            (vec![(5, [1; 32])], "past the run"),
            (vec![(0, [1; 32])], "before the run"),
            (vec![(2, [1; 32]), (1, [1; 32])], "not ascending"),
            (vec![(2, [1; 32]), (2, [1; 32])], "repeated"),
        ] {
            let items = with(bad);
            assert!(write_all(&items).is_err(), "writer took {what}");
            assert!(
                read_all(&compress(&plain(&items, 1))).is_err(),
                "reader took {what}"
            );
        }
        // 项 4 带零个记号（手拼）。
        let mut w = crate::sync2::codec::Writer::new();
        w.u8(LOG_NATIVE);
        id(NAT).write(&mut w);
        w.bytes(&[]);
        w.uv(4);
        w.u8(ITEM_VOID_MARKED);
        w.uv(4);
        w.raw(&[0x33; 32]);
        w.uv(0);
        w.raw(&[0x33; 32]);
        let mut v = plain(&[], 1);
        v.extend_from_slice(&w.into_vec());
        assert!(
            read_all(&compress(&v))
                .unwrap_err()
                .contains("void mark count")
        );
        // 一格的空洞没有内部。
        let one = vec![
            ExportItem::NativeLog {
                device: id(NAT),
                public: None,
                count: 1,
            },
            ExportItem::NativeVoid {
                n: 1,
                chain_after: [0x33; 32],
                marks: vec![(1, [1; 32])],
            },
            ExportItem::NativeTail([0x33; 32]),
        ];
        assert!(write_all(&one).is_err());
        assert!(read_all(&compress(&plain(&one, 1))).is_err());
    }

    #[test]
    fn truncated_streams_are_rejected() {
        let items = sample();
        let p = plain(&items, 3);
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
        // 帧后面的压缩输入：垃圾字节、第二个完整帧（哪怕它是另一份合法的流）都拒，不静默丢掉。
        let mut junk = bytes.clone();
        junk.extend_from_slice(&[0xde, 0xad, 0xbe, 0xef]);
        assert!(read_all(&junk).unwrap_err().contains("trailing"));
        let mut two = bytes.clone();
        two.extend_from_slice(&write_all(&[]).unwrap());
        assert!(read_all(&two).unwrap_err().contains("trailing"));
        // 一个字节的垃圾也拒。
        let mut one = bytes.clone();
        one.push(0);
        assert!(read_all(&one).is_err());
    }

    #[test]
    fn bad_magic_and_unknown_versions_are_rejected() {
        let p = plain(&sample(), 3);
        let mut bad = p.clone();
        bad[0] = b'X';
        assert!(Export4Reader::open(&compress(&bad)).is_err());
        assert!(sniff(&compress(&bad)).is_err());
        for ver in [0u8, EXPORT4_VER + 1, 255] {
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
                marks: Vec::new(),
            },
            ExportItem::NativeVoid {
                n: 2,
                chain_after: [2; 32],
                marks: Vec::new(),
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

    /// 一条带转发材料的原生日志（第 3 版）：[native_items]（seq 3..=4 是空洞）后面跟一个作者签名版本（seq 1..=5，作者
    /// 签的空洞在 3..=4）与 seq 3 的剔除记录。
    fn relay_items() -> Vec<ExportItem> {
        let mut items = native_items();
        let header = NativeHeader {
            encrypted: false,
            collection: coll(),
            device: id(NAT),
            first: 1,
            last: 5,
            prev_chain: CHAIN_ZERO,
            last_chain: [0x55; 32],
        };
        items.push(ExportItem::NativeRelay {
            versions: 1,
            stubs: 1,
        });
        items.push(ExportItem::AuthorVersion {
            header,
            sig: [0x5a; 64],
            voids: vec![(3, 2, [0x44; 32])],
        });
        items.push(ExportItem::Stub(relay_stub(3)));
        items
    }

    /// NAT 第 [seq] 条操作的剔除记录（清掉它的 Purge 是 0x22:7）。
    fn relay_stub(seq: u64) -> Stub {
        let op = op_of(id(NAT), seq, &Body4::Edit(native_edit()));
        Stub::of(
            &op,
            OpId {
                device: id(0x22),
                seq: 7,
            },
        )
    }

    /// 转发材料（第 3 版）：写读往返、明文冻结；规则读写两侧相同（作者签名版本的设备 / 区间 / 顺序 / 空洞，剔除记录的
    /// 设备 / 顺序 / 必须落在空洞上 / 排在版本之后，条数与声明相同）。
    #[test]
    fn relay_material_round_trips_and_follows_the_rules() {
        let items = relay_items();
        let bytes = write_all(&items).unwrap();
        assert_eq!(read_all(&bytes).unwrap().1, items);
        let p = plain(&items, 1);
        let tail_at = plain(&native_items(), 1).len() - 2;
        golden(
            "export4_native_relay",
            &p[tail_at..],
            "010168465347340100c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a10105000000000000000000000000000000000000000000000000000000000000000055555555555555555555555555555555555555555555555555555555555555555a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a010302444444444444444444444444444444444444444444444444444444444444444471a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a10386c0e285e3680001d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2050204007637d807b029390950be821319fb51acf97e47157c6794b2d16b113fee60ff87010300030303030303030303030303030303032222222222222222222222222222222207",
        );
        let check = |items: Vec<ExportItem>, what: &str| {
            let mut w = Export4Writer::new(
                Vec::new(),
                &ExportHeader {
                    collection: coll(),
                    logs: 1,
                },
            )
            .unwrap();
            let wrote = items
                .iter()
                .try_for_each(|it| w.item(it))
                .and_then(|_| w.finish().map(|_| ()));
            assert!(wrote.is_err(), "writer accepted: {what}");
            assert!(
                read_all(&compress(&plain(&items, 1))).is_err(),
                "reader accepted: {what}"
            );
        };
        let at_version = items.len() - 2;
        let with_version = |f: &dyn Fn(&mut NativeHeader, &mut Vec<(u64, u64, Chain)>)| {
            let mut v = items.clone();
            if let ExportItem::AuthorVersion { header, voids, .. } = &mut v[at_version] {
                f(header, voids);
            }
            v
        };
        check(
            with_version(&|h, _| h.device = id(0x33)),
            "version of another device",
        );
        check(with_version(&|h, _| h.first = 0), "version starting at 0");
        check(
            with_version(&|h, _| h.last = 0),
            "version ending before it starts",
        );
        check(with_version(&|_, v| v[0].0 = 5), "void past the segment");
        check(with_version(&|_, v| v[0].1 = 0), "empty void");
        check(
            with_version(&|_, v| v.push((3, 1, [1; 32]))),
            "overlapping voids",
        );
        // 两个版本同一区间（不严格升序）。
        let mut v = items.clone();
        if let ExportItem::NativeRelay { versions, .. } = &mut v[at_version - 1] {
            *versions = 2;
        }
        v.insert(at_version, v[at_version].clone());
        check(v, "versions out of order");
        // 剔除记录：别的设备、不在空洞上、不升序、多于声明。
        let at_stub = items.len() - 1;
        let with_stub = |s: Stub| {
            let mut v = items.clone();
            v[at_stub] = ExportItem::Stub(s);
            v
        };
        let mut foreign = relay_stub(3);
        foreign.op.id.device = id(0x33);
        check(with_stub(foreign), "stub of another device");
        check(with_stub(relay_stub(1)), "stub on a kept op");
        let mut v = items.clone();
        if let ExportItem::NativeRelay { stubs, .. } = &mut v[at_version - 1] {
            *stubs = 2;
        }
        v.insert(at_stub, ExportItem::Stub(relay_stub(4)));
        check(v, "stubs out of order");
        let mut v = items.clone();
        v.push(ExportItem::Stub(relay_stub(4)));
        check(v, "more stubs than declared");
        // 剔除记录排在版本前面。
        let mut v = items.clone();
        v.swap(at_version, at_stub);
        check(v, "stub before the versions");
        // 声明了材料却没给（流在材料中途结束）。
        let mut v = items.clone();
        v.pop();
        check(v, "missing stub");
        // 合法：两个不同区间的版本、两条升序的剔除记录。
        let mut v = items.clone();
        if let ExportItem::NativeRelay { versions, stubs } = &mut v[at_version - 1] {
            *versions = 2;
            *stubs = 2;
        }
        let mut second = v[at_version].clone();
        if let ExportItem::AuthorVersion { header, voids, .. } = &mut second {
            header.first = 2;
            voids.clear();
        }
        v.insert(at_version + 1, second);
        v.push(ExportItem::Stub(relay_stub(4)));
        assert_eq!(read_all(&write_all(&v).unwrap()).unwrap().1, v);
    }

    /// 读写两侧同一套语义规则：写者拒的，手拼成字节读者也拒。
    #[test]
    fn grammar_rules_hold_on_both_sides() {
        let check = |items: Vec<ExportItem>, logs: u64, what: &str| {
            let items = cur(&items);
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
            let _ = &items;
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
        check(sample(), 2, "more logs than declared");
        check(sample(), 4, "fewer logs than declared");
        // 同 tag 内 device 不升序。
        let mut v = empty_native(0xb2);
        v.extend(empty_native(0xb1));
        check(v, 2, "devices out of order");
        // 承袭在原生之前。
        let forkless = heritage_forkless();
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
        // 分叉支：紧跟同 seq 的日志槽、链指纹严格大于前一个槽、条数与声明的相同。
        let with_forks = |forks: u64, extra: &[(usize, ExportItem)]| {
            let mut v = forkless.clone();
            if let ExportItem::HeritageLog { forks: f, .. } = &mut v[0] {
                *f = forks;
            }
            for (at, it) in extra.iter().rev() {
                v.insert(*at, it.clone());
            }
            v
        };
        // seq 2 的日志槽在下标 4、seq 3 在 5，最后一个（seq 8）在 10。
        let log_fp = slots()[1].fp[0];
        assert!(log_fp > 0 && log_fp < 0xf0);
        // 合法：同 seq 两个分叉槽升序；最后一个日志槽后面的分叉。
        let ok = with_forks(2, &[(5, fork_slot(2, 0xf0)), (5, fork_slot(2, 0xf1))]);
        assert_eq!(read_all(&write_all(&ok).unwrap()).unwrap().1, ok);
        let ok = with_forks(1, &[(11, fork_slot(8, 0xf0))]);
        assert_eq!(read_all(&write_all(&ok).unwrap()).unwrap().1, ok);
        // 和日志槽完全相同的重复槽。
        let mut dup = slots()[1].clone();
        dup.fp = [log_fp; 8];
        let dup = ExportItem::Slot {
            t_version: 1,
            slot: dup,
        };
        assert_eq!(dup, forkless[4]);
        check(
            with_forks(1, &[(5, dup)]),
            1,
            "fork identical to the log slot",
        );
        // 链指纹比日志槽小（应当对调进日志）。
        check(
            with_forks(1, &[(5, fork_slot(2, 0))]),
            1,
            "fork sorting before the log slot",
        );
        // 两个分叉槽降序 / 相同。
        check(
            with_forks(2, &[(5, fork_slot(2, 0xf1)), (5, fork_slot(2, 0xf0))]),
            1,
            "fork slots out of order",
        );
        check(
            with_forks(2, &[(5, fork_slot(2, 0xf0)), (5, fork_slot(2, 0xf0))]),
            1,
            "duplicate fork slots",
        );
        // 分叉槽没紧跟它的日志槽（seq 2 的分叉放在 seq 3 后面）。
        check(
            with_forks(1, &[(6, fork_slot(2, 0xf0))]),
            1,
            "fork away from its log slot",
        );
        // 声明的分叉比实际多 / 少。
        check(with_forks(1, &[]), 1, "missing fork slot");
        check(
            with_forks(0, &[(5, fork_slot(2, 0xf0))]),
            1,
            "undeclared fork slot",
        );
        let mut v = with_forks(1, &[]);
        v.extend(empty_native(0xb2));
        check(v, 2, "fork count swallows the next log");
        // 别的设备的分叉槽。
        let mut foreign = slots()[1].clone();
        foreign.id.device = id(0x99);
        foreign.fp = [0xf0; 8];
        check(
            with_forks(
                1,
                &[(
                    5,
                    ExportItem::Slot {
                        t_version: 1,
                        slot: foreign,
                    },
                )],
            ),
            1,
            "fork slot of another device",
        );
        // 没有日志槽却声明了分叉。
        check(
            vec![ExportItem::HeritageLog {
                source: id(SRC),
                device: id(OLD),
                count: 0,
                forks: 1,
                marks: 0,
            }],
            1,
            "forks without log slots",
        );
        // 分叉槽的 t_version 0。
        let mut v = with_forks(1, &[(5, fork_slot(2, 0xf0))]);
        if let ExportItem::Slot { t_version, .. } = &mut v[5] {
            *t_version = 0;
        }
        check(v, 1, "fork t_version 0");
        // 旧的分叉日志 tag 2 已不存在：未知日志 tag。
        let mut p = plain(&empty_native(0xb2), 1);
        p[27] = 2;
        assert!(read_all(&compress(&p)).is_err());
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
