//! 冻结的 `.fushisrs` 第 1 版内核流读入器（魔数 `FSRS2EXP`，协议 3；规划 g7_g11 §1.9、实现拆分 G11-1）。
//!
//! 照抄自 develop 262391b3264 的 native/fushi_fsrs/src/store/sync2/transport.rs `ExportReader` / `ExportItem`
//! （`EXPORT_MAGIC` 与 `ExportReader::open` / `next_item`）：魔数、版本字节、设备抬头、「每台设备从 seq 1 起连续」的校验，
//! 以及它**不查**的东西（不查尾字节、varint 收宽松形）逐条照旧——收什么、拒什么与已发布的读者相同。操作的解码与链的算法
//! 用协议 3 本身（`crate::sync2::op::Op::read`、`crate::sync2::segment::chain_next`），它们随协议 3 一起冻结。
//!
//! 不随本仓演进：协议 3 的 `sync2_export` / `sync2_import` 换代后会删掉（G11-3），旧包靠这里读入。**不要为了让新代码方便去改它**；
//! 要改格式就是新的魔数（store/gen4 的 `ops.bin` 是 `FSRS4EXP`，见 `crate::gen4::export`）。
//!
//! 用法（G11-2 的 `import_v1`）：[for_each_v1] 逐设备从 seq 1 起重算协议 3 的链，把每条操作连同它的链值交出去，调用方再喂
//! 转译 T（`crate::gen4::translate::translate`）。

use crate::sync2::codec::{Reader, ZstdWindow};
use crate::sync2::id::Id;
use crate::sync2::op::Op;
use crate::sync2::segment::{CHAIN_ZERO, Chain, chain_next};

/// 第 1 版内核流的魔数（transport.rs `EXPORT_MAGIC`）。
pub const EXPORT_MAGIC: &[u8; 8] = b"FSRS2EXP";

/// `.fushisrs` 的一项（按出现顺序）：一台设备的抬头，接着是它从 seq 1 起的 `count` 条操作。
enum ExportItem {
    Device {
        device: Id,
        public: Vec<u8>,
        // 冻结副本照原样保留（原读者用它；这里的消费者只要逐条的操作）。
        #[allow(dead_code)]
        count: u64,
    },
    Op(Op),
}

/// 流式读 `.fushisrs` 的操作部分（[ZstdWindow]），顺手校验每台设备的操作是从 1 起连续的。
struct ExportReader<'s> {
    window: ZstdWindow<'s>,
    collection: Id,
    devices_left: u64,
    /// 当前设备与下一条应有的 seq、最后一条 seq。
    cur: Option<(Id, u64, u64)>,
}

impl<'s> ExportReader<'s> {
    fn open(bytes: &'s [u8]) -> Result<ExportReader<'s>, String> {
        let mut window = ZstdWindow::new(bytes).map_err(|e| e.to_string())?;
        if window
            .parse(|r| r.raw(8).map(<[u8]>::to_vec))
            .map_err(|e| e.to_string())?
            != EXPORT_MAGIC
        {
            return Err("not a .fushisrs file".into());
        }
        if window.parse(|r| r.u8()).map_err(|e| e.to_string())? != 1 {
            return Err("unsupported .fushisrs version".into());
        }
        let collection = window.parse(Id::read).map_err(|e| e.to_string())?;
        let devices_left = window.parse(|r| r.uv()).map_err(|e| e.to_string())?;
        Ok(ExportReader {
            window,
            collection,
            devices_left,
            cur: None,
        })
    }

    fn next_item(&mut self) -> Result<Option<ExportItem>, String> {
        if let Some((device, next, top)) = self.cur.as_mut() {
            if *next <= *top {
                let op = self
                    .window
                    .parse(|r| Op::read(&mut Reader::new(r.bytes()?)))
                    .map_err(|e| e.to_string())?;
                if op.id.device != *device || op.id.seq != *next {
                    return Err("corrupt .fushisrs (op order)".into());
                }
                *next += 1;
                return Ok(Some(ExportItem::Op(op)));
            }
            self.cur = None;
        }
        if self.devices_left == 0 {
            return Ok(None);
        }
        self.devices_left -= 1;
        let (device, public, count) = self
            .window
            .parse(|r| Ok((Id::read(r)?, r.bytes()?.to_vec(), r.uv()?)))
            .map_err(|e| e.to_string())?;
        self.cur = Some((device, 1, count));
        Ok(Some(ExportItem::Device {
            device,
            public,
            count,
        }))
    }
}

/// [for_each_v1] 读完之后的统计。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V1Stats {
    /// 包头里的集合标识（协议 3 的集合；作承袭日志的来源集合）。
    pub collection: Id,
    /// 设备抬头数（含没有操作的设备）。
    pub devices: u64,
    pub ops: u64,
}

/// 只读包头的集合标识（导入前判「同一个集合」用），不往下读。
pub fn v1_collection(bytes: &[u8]) -> Result<Id, String> {
    Ok(ExportReader::open(bytes)?.collection)
}

/// 逐条读出第 1 版内核流里的操作：`f(集合, 设备, 公钥, 操作, 该处的链值)`。链值逐设备从 seq 1 起按协议 3 的
/// `chain_next` 重算（包里不带链值）。没有操作的设备不回调，只计入 [V1Stats::devices]。`f` 报错就停、原样返回。
pub fn for_each_v1(
    bytes: &[u8],
    mut f: impl FnMut(&Id, &Id, &[u8], &Op, &Chain) -> Result<(), String>,
) -> Result<V1Stats, String> {
    let mut reader = ExportReader::open(bytes)?;
    let collection = reader.collection;
    let mut stats = V1Stats {
        collection,
        devices: 0,
        ops: 0,
    };
    let mut cur: Option<(Id, Vec<u8>, Chain)> = None;
    while let Some(item) = reader.next_item()? {
        match item {
            ExportItem::Device { device, public, .. } => {
                stats.devices += 1;
                cur = Some((device, public, CHAIN_ZERO));
            }
            ExportItem::Op(op) => {
                let (device, public, chain) =
                    cur.as_mut().ok_or("corrupt .fushisrs (op before device)")?;
                *chain = chain_next(chain, &op);
                f(&collection, device, public, &op, chain)?;
                stats.ops += 1;
            }
        }
    }
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::gen4::export::{
        EXPORT4_MAGIC, Export4Reader, Export4Writer, ExportHeader, ExportKind, sniff,
    };
    use crate::gen4::translate::translate;
    use crate::store::gen4::legacy::tests::{T0, pair, read_all};
    use crate::store::sync2::tests::{DAY, P};

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02X}")).collect()
    }

    /// 对着真实的 `sync2_export` 产物：逐条重算出的链值与源库 `sync2_ops.chain` 相同，条数相同，设备齐全；
    /// 交给 T 转出来的槽与直接从库里读（旧代读入器）转出来的完全相同。
    #[test]
    fn chains_recomputed_from_a_real_export_match_the_source_library() {
        let (a, _b, mut bucket) = pair();
        // 有清除过的操作（协议 3 的骨架也在导出里）。
        a.core.sync2_purge(P, "note", "N1", T0 + 2 * DAY).unwrap();
        a.sync(&mut bucket, "loc", T0 + 2 * DAY);
        let exported = a.core.sync2_export(P).unwrap();
        assert_eq!(sniff(&exported).unwrap(), ExportKind::V1);

        let want: BTreeMap<(String, u64), String> = a
            .rows("SELECT hex(device), seq, hex(chain) FROM sync2_ops WHERE profile_uid = srs_id('0193a1b2-0000-7000-8000-00000000beef')")
            .into_iter()
            .skip(1)
            .map(|r| ((r[0].clone(), r[1].parse().unwrap()), r[2].clone()))
            .collect();
        assert!(!want.is_empty());

        let mut got = BTreeMap::new();
        let mut slots = Vec::new();
        let mut publics = 0;
        let stats = for_each_v1(&exported, |_, device, public, op, chain| {
            assert_eq!(op.id.device, *device);
            if op.id.seq == 1 && public.len() == 32 {
                publics += 1;
            }
            got.insert((hex(&device.0), op.id.seq), hex(chain));
            slots.push(translate(op, chain).map_err(str::to_owned)?.encode());
            Ok(())
        })
        .unwrap();
        assert_eq!(got, want);
        assert_eq!(stats.ops, want.len() as u64);
        assert_eq!(stats.devices, 2);
        assert_eq!(publics, 2);
        assert_eq!(v1_collection(&exported).unwrap(), stats.collection);

        let (set, pending, _) = read_all(&a);
        assert!(pending.is_empty());
        let mut from_db: Vec<Vec<u8>> = set.iter().map(|s| s.encode()).collect();
        from_db.sort();
        slots.sort();
        assert_eq!(slots, from_db);

        // 回调报错就停。
        let mut n = 0;
        let e = for_each_v1(&exported, |_, _, _, _, _| {
            n += 1;
            Err("stop".into())
        })
        .unwrap_err();
        assert_eq!((e.as_str(), n), ("stop", 1));
        // 截断报错、不 panic。
        for cut in [0, 5, exported.len() / 2, exported.len() - 1] {
            assert!(for_each_v1(&exported[..cut], |_, _, _, _, _| Ok(())).is_err());
        }
    }

    /// 两个方向互不误读：协议 3 的真实读者（`SrsCore::sync2_import`）在魔数处拒 `FSRS4EXP`，且库里什么都不变；
    /// 冻结副本同样拒；第 4 代读者拒 `FSRS2EXP`。
    #[test]
    fn the_two_generations_never_read_each_other() {
        let (a, _, _) = pair();
        let w = Export4Writer::new(
            Vec::new(),
            &ExportHeader {
                collection: crate::sync2::id::Id([0xc0; 16]),
                logs: 0,
            },
        )
        .unwrap();
        let v4 = w.finish().unwrap();
        assert_eq!(sniff(&v4).unwrap(), ExportKind::V4);
        let before = a.rows("SELECT COUNT(*), COALESCE(SUM(seq), 0) FROM sync2_ops");
        let e = a.core.sync2_import(P, &v4, T0 + 3 * DAY).unwrap_err();
        assert!(e.contains("not a .fushisrs file"), "{e}");
        assert_eq!(
            a.rows("SELECT COUNT(*), COALESCE(SUM(seq), 0) FROM sync2_ops"),
            before
        );
        let e = for_each_v1(&v4, |_, _, _, _, _| Ok(())).unwrap_err();
        assert_eq!(e, "not a .fushisrs file");
        assert!(v1_collection(&v4).is_err());

        let v1 = a.core.sync2_export(P).unwrap();
        let e = Export4Reader::open(&v1).err().unwrap();
        assert!(e.contains("not a protocol 4"), "{e}");
        // 第 1 版读者对版本字节 != 1 的旧魔数包拒收（冻结行为）。
        let mut plain = zstd::stream::decode_all(&v1[..]).unwrap();
        plain[8] = 2;
        let e = for_each_v1(
            &zstd::bulk::compress(&plain, 3).unwrap(),
            |_, _, _, _, _| Ok(()),
        )
        .unwrap_err();
        assert_eq!(e, "unsupported .fushisrs version");
        assert_ne!(&EXPORT4_MAGIC[..], &EXPORT_MAGIC[..]);
    }
}
