//! 存储侧导出（规划 g7_g11 §1.9、实现拆分 G11-2）：把一个集合的真相层整份写成 `.fushisrs` 第 2 版里的内核流 `ops.bin`
//! （魔数 `FSRS4EXP`，编解码与校验规则在 [crate::gen4::export]）。读入方向在 `import.rs`（[super::import::import_ops]）。
//!
//! 调用方：`.fushisrs` 第 2 版的 `export` 命令（G11-3，`cmd/fushisrs.rs`，清单与协议 3 设备的公钥也在那里）；整包备份按
//! 集合导出是 G11-4。
//!
//! # 写什么（D34）
//!
//! - 每条原生日志（含本机的）：从 seq 1 到末尾的每条操作，已清除的区间写成空洞（条数 + 区间末的链值）；相邻的空洞区间
//!   （分几次清除 / 收到的）合成一个——流的规则是一个值只有一种字节形。日志抬头带作者公钥：本机的从签名钥匙算，
//!   别的设备取 `peers`（没记过 = 空）。
//! - 每条承袭日志：日志里的槽、每个 seq 后面紧跟分叉的另一支（`op_forks`，链指纹升序），以及记着的完整原链值
//!   （`log_marks`，之后切承袭段要用）。
//! - **不写**待投递的槽（`op_pending`）：它们前面还缺，导入方接不上，原样留在本机等同步轮。
//! - 不写本机状态：信任、暂扣、检查点、各位置进度、本机身份的私钥都不出这台机器。槽是不是本机自己推进出来的
//!   （`local` 标记）也不写：导入方收到的空洞 / 副本记录就是来路数据。
//!
//! 一个事务里读完（[Truth::tx]），导出的是同一个快照；同一份真相导出的字节恒相同（日志按 (种类, 设备) 排序、槽按
//! (seq, 链指纹) 排序、压缩确定），所以「导出 → 导入 → 再导出」逐字节相等（`import_tests.rs` 钉住）。写出的每一项都
//! 先过 [crate::gen4::export::Export4Writer] 的同一套语法核对：真相层里有违背流规则的东西（本不该发生）就报错，
//! 不写出一份读者会拒收的流。

use std::collections::BTreeMap;
use std::io::Write;

use super::truth::{DEV_HERITAGE, DEV_NATIVE, DevInfo, Parked, Truth};
use crate::gen4::export::{Export4Writer, ExportHeader, ExportItem};
use crate::gen4::heritage::SlotBody;
use crate::sync2::id::Id;
use crate::sync2::segment::Chain;

/// 一次导出的计数。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Exported {
    pub native_logs: u64,
    pub heritage_logs: u64,
    /// 原生日志里的完整操作。
    pub ops: u64,
    /// 原生日志里的空洞区间（合并之后）与它们盖住的 seq 数。
    pub void_runs: u64,
    pub voided: u64,
    /// 承袭日志里的槽（不含分叉的另一支）。
    pub slots: u64,
    pub forks: u64,
    pub marks: u64,
    /// 没写进去的待投递槽（D34）。
    pub pending_skipped: u64,
}

/// 把集合 [col] 的真相层写成一条 `FSRS4EXP` 流，写进 [out]（边读边压缩，内存是压缩窗口加一项）。返回 [out] 与计数。
///
/// 自己开（或嵌进调用方的）事务读，导出的是同一个快照。集合没绑过、真相层里有违背流规则的东西都报错。
pub fn export_ops<W: Write>(t: &Truth<'_>, col: i64, out: W) -> Result<(W, Exported), String> {
    t.tx(|t| export_in_tx(t, col, out))
}

fn export_in_tx<W: Write>(t: &Truth<'_>, col: i64, out: W) -> Result<(W, Exported), String> {
    let binding = t
        .binding(col)?
        .ok_or_else(|| format!("gen4 export: no collection {col}"))?;
    let me = t.self_identity(col)?.map(|s| (s.device, s.public()));
    let mut native: Vec<DevInfo> = Vec::new();
    let mut heritage: Vec<DevInfo> = Vec::new();
    for d in t.devices(col)? {
        if d.last == 0 {
            continue;
        }
        match d.kind {
            Some(DEV_NATIVE) => native.push(d),
            Some(DEV_HERITAGE) => heritage.push(d),
            _ => {}
        }
    }
    native.sort_by(|a, b| a.id.0.cmp(&b.id.0));
    heritage.sort_by(|a, b| a.id.0.cmp(&b.id.0));
    let mut forks: BTreeMap<Id, Vec<Parked>> = BTreeMap::new();
    for p in t.forks(col)? {
        forks.entry(p.slot.id.device).or_default().push(p);
    }
    for list in forks.values_mut() {
        list.sort_by(|a, b| (a.slot.id.seq, a.slot.fp).cmp(&(b.slot.id.seq, b.slot.fp)));
    }
    let mut n = Exported {
        pending_skipped: t.pending(col)?.len() as u64,
        ..Exported::default()
    };
    let header = ExportHeader {
        collection: binding.collection,
        logs: (native.len() + heritage.len()) as u64,
    };
    let mut w = Export4Writer::new(out, &header)?;

    for d in &native {
        let public = match me {
            Some((device, public)) if device == d.id => Some(public),
            _ => t.device_key(col, &d.id)?,
        };
        w.item(&ExportItem::NativeLog {
            device: d.id,
            public,
            count: d.last,
        })?;
        // 正在攒的空洞区间：(第一个 seq, 条数)。
        let mut run: Option<(u64, u64)> = None;
        let flush = |w: &mut Export4Writer<W>,
                     run: &mut Option<(u64, u64)>,
                     n: &mut Exported|
         -> Result<(), String> {
            if let Some((start, len)) = run.take() {
                let end = start + len - 1;
                let chain_after: Chain = t.chain_known(col, &d.id, end)?.ok_or_else(|| {
                    format!(
                        "gen4 export: {}:{end} ends a void run without a chain value",
                        d.id
                    )
                })?;
                w.item(&ExportItem::NativeVoid {
                    n: len,
                    chain_after,
                })?;
                n.void_runs += 1;
                n.voided += len;
            }
            Ok(())
        };
        t.for_each(col, &d.id, 1, |e| match e.body {
            SlotBody::Void => {
                run = Some(match run {
                    Some((start, len)) => (start, len + 1),
                    None => (e.id.seq, 1),
                });
                Ok(())
            }
            SlotBody::Op(op) => {
                flush(&mut w, &mut run, &mut n)?;
                w.item(&ExportItem::NativeOp(op))?;
                n.ops += 1;
                Ok(())
            }
            SlotBody::Raw3(_) | SlotBody::Alias(_) => Err(format!(
                "gen4 export: native log {} holds a heritage-only slot at {}",
                d.id, e.id.seq
            )),
        })?;
        flush(&mut w, &mut run, &mut n)?;
        w.item(&ExportItem::NativeTail(t.chain_at(col, &d.id, d.last)?))?;
        n.native_logs += 1;
    }

    for d in &heritage {
        let source = d
            .src
            .ok_or_else(|| format!("gen4 export: heritage log {} has no source", d.id))?;
        let marks = t.marks(col, &d.id)?;
        let mine: &[Parked] = forks.get(&d.id).map_or(&[], Vec::as_slice);
        w.item(&ExportItem::HeritageLog {
            source,
            device: d.id,
            count: d.last,
            forks: mine.len() as u64,
            marks: marks.len() as u64,
        })?;
        for (seq, chain) in &marks {
            w.item(&ExportItem::Mark {
                seq: *seq,
                chain: *chain,
            })?;
        }
        n.marks += marks.len() as u64;
        let mut next_fork = 0usize;
        t.for_each(col, &d.id, 1, |e| {
            let seq = e.id.seq;
            let tv = e.tv;
            let slot = e
                .slot()
                .ok_or_else(|| format!("gen4 export: {}:{seq} has no chain fingerprint", d.id))?;
            w.item(&ExportItem::Slot {
                t_version: tv,
                slot,
            })?;
            n.slots += 1;
            while let Some(p) = mine.get(next_fork).filter(|p| p.slot.id.seq == seq) {
                w.item(&ExportItem::Slot {
                    t_version: p.tv,
                    slot: p.slot.clone(),
                })?;
                n.forks += 1;
                next_fork += 1;
            }
            Ok(())
        })?;
        if next_fork != mine.len() {
            return Err(format!(
                "gen4 export: {} has a fork at seq {} outside its log",
                d.id, mine[next_fork].slot.id.seq
            ));
        }
        n.heritage_logs += 1;
    }
    let out = w.finish()?;
    Ok((out, n))
}
