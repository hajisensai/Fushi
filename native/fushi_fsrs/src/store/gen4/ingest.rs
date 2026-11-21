//! 一批写入 / 收入之后把派生层收好（规划缺口 G-9，G7-3a）。本机原生写入（[super::native::Native::finish]）、收段
//! （G8-4）、导入与还原（G11-2）共用这一处，不各写各的。
//!
//! 两种收法（[Settle]）：
//!
//! - [Settle::Incremental]：调用方每落一条都 [Index::add] / [Index::remove] 过，这里只判这一批碰到的部分
//!   （[Index::settle]）。日常写入与小段收入用它。
//! - [Settle::Rebuild]：调用方大批只落真相、没逐条告诉索引（迁移灌入、整包导入、一次收很多段），这里清空派生表从真相
//!   重建（[Index::rebuild_all]）。重建不看索引里攒着的东西，调用方逐条 add 过也不会算两遍。
//!
//! 收完派生层就是「真相 + 本机信任状态 + 宿主输入」的函数（设计 §2.5）：两种收法的结果逐行相同（测试钉住）。
//! 为此 [ingest_settle] 总是放开别名表的攒批（[Index::hold_aliases]）——它是一批的终点，别名表不能留着没算；
//! 想跨多批攒着的调用方在中途直接用 [Index::settle]，最后再调这里。
//!
//! 必须在调用方的事务里，与这一批的落库同一个事务提交；报错时回滚并 reset [Truth] 与 [Index]。

use super::derive::{Index, Settled};
use super::native::same_truth;
use super::truth::Truth;

/// [ingest_settle] 的收法。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Settle {
    /// 逐条维护过：只判这一批碰到的。
    Incremental,
    /// 只落了真相：从真相整个重建派生表。
    Rebuild,
}

/// 把集合 [col] 这一批落库之后的派生层收好。[idx] 必须是 [t] 上集合 [col] 的索引。
pub fn ingest_settle(
    t: &Truth<'_>,
    idx: &mut Index<'_, '_>,
    col: i64,
    mode: Settle,
) -> Result<Settled, String> {
    if !same_truth(idx.t, t) || idx.col != col {
        return Err(format!(
            "gen4 ingest: the index is not collection {col} of this session"
        ));
    }
    if t.conn().is_autocommit() {
        return Err("gen4 ingest: settle outside a transaction".to_owned());
    }
    if t.binding(col)?.is_none() {
        return Err(format!("gen4 ingest: no collection {col}"));
    }
    idx.hold_aliases(false);
    match mode {
        Settle::Incremental => idx.settle(),
        Settle::Rebuild => idx.rebuild_all(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gen4::heritage::HeritageSlot;
    use crate::gen4::op::tests::id;
    use crate::gen4::op::{Body4, Op4};
    use crate::gen4::translate::T_VERSION;
    use crate::store::gen4::derive::tests::{assert_rebuild_is_identity, dump, op};
    use crate::store::gen4::native::Native;
    use crate::store::gen4::native::tests::{edit, ready};
    use crate::store::gen4::schema::open_in_memory;
    use crate::sync2::id::Key;
    use crate::sync2::op::EntKind;

    const NOW: i64 = 1_800_000_000_000;

    /// 一批收进来的东西：两台设备的原生操作（含一条身份记录、一条 Salts）与一台旧设备的承袭操作。
    fn batch() -> Vec<(bool, Op4)> {
        let note = Body4::Entity {
            kind: EntKind::Note,
            id: Key::Uuid(id(3)),
            data: r#"{"guid":"g1","noteTypeId":"x"}"#.to_owned(),
        };
        vec![
            (true, op(0x21, 1, 10, &[], &note)),
            (true, op(0x21, 2, 11, &[], &edit("x2"))),
            (true, op(0x22, 1, 12, &[(0x21, 1)], &edit("y1"))),
            (
                true,
                op(
                    0x22,
                    2,
                    13,
                    &[(0x21, 2)],
                    &Body4::salts(["old-uid"]).unwrap(),
                ),
            ),
            (false, op(0xd1, 1, 5, &[], &edit("h1"))),
        ]
    }

    /// 落一批：[tell] = 每条都告诉索引（逐条维护）。
    fn land(t: &Truth<'_>, ix: &mut Index<'_, '_>, col: i64, tell: bool) -> Result<(), String> {
        for (native, o) in batch() {
            let oid = o.id;
            if native {
                t.append_native(col, &o)?;
            } else {
                t.put_heritage(col, &id(0xc0), &HeritageSlot::op([1; 8], o), T_VERSION)?;
            }
            if tell {
                ix.add(&t.entry(col, &oid)?.expect("just landed"))?;
            }
        }
        Ok(())
    }

    fn settled_dump(mode: Settle, tell: bool, hold: bool) -> (Vec<String>, Settled, bool) {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        let (settled, stale) = t
            .tx(|t| {
                let mut ix = Index::new(t, col);
                ix.hold_aliases(hold);
                land(t, &mut ix, col, tell)?;
                // 本机在同一批里也写一条：写入者与收入共用这一个收尾。
                Native::open(t, col)?.write(&mut ix, edit("mine"), NOW)?;
                let s = ingest_settle(t, &mut ix, col, mode)?;
                Ok((s, ix.aliases_stale()))
            })
            .unwrap();
        assert_rebuild_is_identity(&t, col);
        (dump(&conn, col), settled, stale)
    }

    /// 两种收法收出来的派生表逐行相同，都等于从空重建；攒着的别名表在收尾时一定算掉。
    #[test]
    fn both_ways_of_settling_give_the_same_index() {
        let (inc, s_inc, stale_inc) = settled_dump(Settle::Incremental, true, false);
        let (held, _, stale_held) = settled_dump(Settle::Incremental, true, true);
        let (reb, s_reb, stale_reb) = settled_dump(Settle::Rebuild, false, false);
        let (reb_told, _, _) = settled_dump(Settle::Rebuild, true, true);
        assert!(!inc.is_empty());
        assert_eq!(inc, held);
        assert_eq!(inc, reb);
        assert_eq!(inc, reb_told);
        assert!(!stale_inc && !stale_held && !stale_reb);
        assert_eq!(s_inc.scanned, 0);
        assert_eq!(s_reb.scanned, 6);
    }

    /// 盐集合随收尾进绑定表（受信作者的 Salts）。
    #[test]
    fn salts_reach_the_binding_when_settled() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            land(t, &mut ix, col, false)?;
            ingest_settle(t, &mut ix, col, Settle::Rebuild).map(|_| ())
        })
        .unwrap();
        let salts = t.binding(col).unwrap().unwrap().salts;
        assert_eq!(
            salts.into_iter().collect::<Vec<_>>(),
            vec!["old-uid".to_owned()]
        );
    }

    #[test]
    fn misuse_is_refused() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        let mut ix = Index::new(&t, col);
        let e = ingest_settle(&t, &mut ix, col, Settle::Incremental).unwrap_err();
        assert!(e.contains("outside a transaction"), "{e}");
        let e = t
            .tx(|t| ingest_settle(t, &mut Index::new(t, col), col + 1, Settle::Rebuild))
            .unwrap_err();
        assert!(e.contains("not collection"), "{e}");
        let e = t
            .tx(|t| ingest_settle(t, &mut Index::new(t, col + 1), col + 1, Settle::Rebuild))
            .unwrap_err();
        assert!(e.contains("no collection"), "{e}");
        // 另一个会话的索引。
        let other = Truth::new(&conn);
        let e = t
            .tx(|t| ingest_settle(t, &mut Index::new(&other, col), col, Settle::Incremental))
            .unwrap_err();
        assert!(e.contains("not collection"), "{e}");
    }
}
