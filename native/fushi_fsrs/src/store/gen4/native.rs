//! 原生写入者（规划 §1.5，G7-3a）：本机在一个集合里写协议 4 操作的唯一入口。G7-3b 的写命令、G9-3 的 `join`、
//! G7-2 迁移第 6 步的 `Salts`、G8 / G11 收尾都建在它上面；这里不接任何命令（第一段：没有生产调用方）。
//!
//! 一次写入 = 一条原生操作：
//!
//! - **作者**是本机身份（`self_`，[Truth::self_identity]）。每次写都重读一遍：两次写之间身份被换掉（G8-6 的换身份）
//!   就报错，不会拿旧设备 ID 接着写。
//! - **seq** = 本机日志末尾 + 1，**链**由 [Truth::append_native] 接上；两样都从真相层现取，不在这里另存一份。
//! - **依赖**（`deps`）= 本机已应用的版本向量去掉作者自己（[Truth::applied]，每台设备日志的末尾）。同一事务里先收进来
//!   的操作，紧接着的写入就依赖它们。
//! - **HLC** = 本机时钟 tick（[Clock::tick]）。时钟的起点取三者之大：`self_.hlc`（本机发过的最大值）、每台设备日志
//!   末尾那条操作的 HLC，超前本机墙钟 [crate::sync2::hlc::MAX_AHEAD_MS] 以上的不追（协议 3 的 `Clock::absorb` 口径）。
//!   末尾是空洞 / 副本记录的设备没有可读的 HLC，跳过。所以只在依赖都没超前过多、末尾都可读时，新 HLC 才大于它依赖的
//!   每一条；超前过多的依赖、空洞 / 副本末尾的设备都可能让新 HLC 小于所依赖的操作（测试
//!   `the_clock_tops_every_dependency_but_not_a_runaway_one`）。**判定不依赖这一条**：设计稿以因果优先、HLC 只比并发
//!   的写入，收段一侧（G8-4）要不要吸收远端时钟按它自己的需要定，不能拿这里当前提。写完把新 HLC 记回
//!   `self_`（[Truth::set_self_hlc]，只升不降）。
//! - **索引**：落库后立刻 [Index::add]，派生层的收尾由 [Native::finish]（= [Index::settle]）或 `ingest.rs` 的
//!   [super::ingest::ingest_settle] 做。
//!
//! # 事务、崩溃与并发
//!
//! 写入必须在调用方的事务里（[Truth::tx] 或自己开的事务 + [Truth::reset]）；操作、链尾、`self_.hlc`、索引行同一个
//! 事务提交，崩溃 = 整笔没发生，重开后从提交过的末尾接着写。任何一步报错，调用方回滚并 reset [Truth] 与 [Index]
//! （真相层报错会毒化会话，见 `truth.rs`「会话与事务」）。
//!
//! [Native] 只缓存「依赖向量 → 各设备末尾 HLC」这一项，按依赖向量逐次核对，别的连接或同一事务里的另一个写入者写过，
//! 依赖向量就变了、缓存自动作废；seq、链、时钟都每次从库里读。所以同一个集合上开几个 [Native]、跨事务复用、
//! 别的连接在两个事务之间写过，结果都与只有一个写入者相同（测试 `two_writers_interleave_without_gaps`、
//! `writers_on_two_connections_race_without_gaps`）。新代下只有主进程写（D10），这里不另加锁。
//!
//! # 盐（规划缺口 G-5）
//!
//! `Salts`（种类 15）只经 [Native::write_salts] 写：只写本机身份**自己的**原生日志里还没带过的那些盐，全都带过就
//! 不写（`None`）。不拿别的设备写过的盐抵：盐集合按「本机信任的作者」算（设计 §5.1），别的设备信不信那个作者不由
//! 本机定，自己再声明一遍重复无害（并集），省掉的那一条却可能让信任关系不同的设备算出不同的别名表。
//! [Native::write] 拒收 `Salts`，免得绕过这条去重。「`Salts` 先于按规范 ID 写的新操作」（设计 §6.1 第 4 步）是
//! 迁移编排（G7-2）的顺序，这里不强制：全新建的集合没有旧 uid，根本不写 `Salts`。

use std::collections::BTreeSet;
use std::sync::Arc;

use rusqlite::params;

use super::derive::{Index, Settled};
use super::schema::{k_dev, k_range, sql};
use super::truth::Truth;
use crate::gen4::op::{Body4, Op4};
use crate::sync2::hlc::{Clock, Hlc};
use crate::sync2::id::Id;
use crate::sync2::segment::Chain;
use crate::sync2::vv::{OpId, Vv};

/// 本机在一个集合里的原生写入者。
pub struct Native<'t, 'c> {
    t: &'t Truth<'c>,
    col: i64,
    device: Id,
    /// (依赖向量, 当时各设备日志末尾那条操作的 HLC)。依赖向量不同就重读。
    tails: Option<(Vv, Vec<Hlc>)>,
    written: u64,
}

impl<'t, 'c> Native<'t, 'c> {
    /// 集合 [col] 的写入者。本机在这个集合里还没有身份（[Truth::create_self]）就报错。
    pub fn open(t: &'t Truth<'c>, col: i64) -> Result<Native<'t, 'c>, String> {
        let me = t
            .self_identity(col)?
            .ok_or_else(|| format!("gen4 native: collection {col} has no local identity"))?;
        Ok(Native {
            t,
            col,
            device: me.device,
            tails: None,
            written: 0,
        })
    }

    /// 作者（本机身份的设备 ID）。
    pub fn device(&self) -> Id {
        self.device
    }

    pub fn col(&self) -> i64 {
        self.col
    }

    /// 这个写入者写过的条数。
    pub fn written(&self) -> u64 {
        self.written
    }

    /// 写一条操作，返回操作号与该处的链值。`Salts` 走 [Native::write_salts]；[Body4::Unknown] 不是本机能写的东西。
    pub fn write(
        &mut self,
        idx: &mut Index<'_, '_>,
        body: Body4,
        now_ms: i64,
    ) -> Result<(OpId, Chain), String> {
        match &body {
            Body4::Salts { .. } => {
                return Err("gen4 native: salts are written through write_salts".to_owned());
            }
            Body4::Unknown => {
                return Err("gen4 native: an unknown body cannot be written".to_owned());
            }
            _ => {}
        }
        self.append(idx, &body, now_ms)
    }

    /// 让本机身份声明 [salts]：只写自己的原生日志里还没带过的那些（一条 `Salts`），全都带过 / 给的是空集 = `None`。
    /// 超过一条 `Salts` 的上限（`SALTS_MAX`）报错。
    pub fn write_salts(
        &mut self,
        idx: &mut Index<'_, '_>,
        salts: &BTreeSet<String>,
        now_ms: i64,
    ) -> Result<Option<OpId>, String> {
        self.bound(idx)?;
        if salts.is_empty() {
            return Ok(None);
        }
        let have = self.own_salts()?;
        let new: Vec<&String> = salts.difference(&have).collect();
        if new.is_empty() {
            return Ok(None);
        }
        let body =
            Body4::salts(new.into_iter().cloned()).map_err(|e| format!("gen4 native: {e}"))?;
        self.append(idx, &body, now_ms).map(|(id, _)| Some(id))
    }

    /// 收尾：把这一批写入攒下的派生层变化判完（[Index::settle]）。
    pub fn finish(&mut self, idx: &mut Index<'_, '_>) -> Result<Settled, String> {
        self.bound(idx)?;
        idx.settle()
    }

    // ------------------------------------------------------------ 内部

    /// [idx] 必须是同一个会话、同一个集合的索引，且在事务里。
    fn bound(&self, idx: &Index<'_, '_>) -> Result<(), String> {
        if !same_truth(idx.t, self.t) || idx.col != self.col {
            return Err(format!(
                "gen4 native: the index is not collection {} of this session",
                self.col
            ));
        }
        if self.t.conn().is_autocommit() {
            return Err("gen4 native: write outside a transaction".to_owned());
        }
        Ok(())
    }

    fn append(
        &mut self,
        idx: &mut Index<'_, '_>,
        body: &Body4,
        now_ms: i64,
    ) -> Result<(OpId, Chain), String> {
        self.bound(idx)?;
        let t = self.t;
        let me = t
            .self_identity(self.col)?
            .ok_or_else(|| format!("gen4 native: collection {} has no local identity", self.col))?;
        if me.device != self.device {
            return Err(format!(
                "gen4 native: the local identity changed from {} to {}; open a new writer",
                self.device, me.device
            ));
        }
        let applied = t.applied(self.col)?;
        let id = OpId {
            device: self.device,
            seq: applied.get(&self.device) + 1,
        };
        let mut deps = applied;
        deps.set(self.device, 0);
        let mut clock = Clock {
            device: self.device,
            last: me.hlc,
        };
        for remote in self.tails(&deps)? {
            clock.absorb(remote, now_ms);
        }
        let own = t
            .entry(
                self.col,
                &OpId {
                    device: self.device,
                    seq: id.seq - 1,
                },
            )?
            .and_then(|e| e.op().map(|o| o.hlc));
        if let Some(h) = own {
            // 自己日志末尾的 HLC 照理不超过 `self_.hlc`（同一个事务里一起写的）；`self_` 被外部改小过也不倒退。
            if (h.wall, h.logical) > (clock.last.wall, clock.last.logical) {
                clock.last = Hlc {
                    device: self.device,
                    ..h
                };
            }
        }
        let hlc = clock.tick(now_ms);
        let op = Op4::of(id, hlc, Arc::new(deps), body);
        let chain = t.append_native(self.col, &op)?;
        t.set_self_hlc(self.col, &hlc)?;
        let e = t.entry(self.col, &id)?.ok_or_else(|| {
            format!(
                "gen4 native: {}:{} vanished after append",
                id.device, id.seq
            )
        })?;
        idx.add(&e)?;
        self.written += 1;
        Ok((id, chain))
    }

    /// 依赖向量里每台设备日志末尾那条操作的 HLC（空洞 / 副本记录没有，跳过）。
    fn tails(&mut self, deps: &Vv) -> Result<Vec<Hlc>, String> {
        if let Some((vv, hlcs)) = &self.tails {
            if vv == deps {
                return Ok(hlcs.clone());
            }
        }
        let mut hlcs = Vec::with_capacity(deps.0.len());
        for (device, &seq) in &deps.0 {
            let e = self.t.entry(
                self.col,
                &OpId {
                    device: *device,
                    seq,
                },
            )?;
            if let Some(op) = e.as_ref().and_then(|e| e.op()) {
                hlcs.push(op.hlc);
            }
        }
        self.tails = Some((deps.clone(), hlcs.clone()));
        Ok(hlcs)
    }

    /// 本机身份自己的原生日志里带过的盐（`salt_ix` 里作者是本机的行）。
    fn own_salts(&self) -> Result<BTreeSet<String>, String> {
        let Some(k) = self.t.key_of(
            self.col,
            &OpId {
                device: self.device,
                seq: 1,
            },
        )?
        else {
            return Ok(BTreeSet::new());
        };
        let (lo, hi) = k_range(k_dev(k));
        let mut stmt = self
            .t
            .conn()
            .prepare_cached("SELECT salt FROM salt_ix WHERE col = ?1 AND k BETWEEN ?2 AND ?3")
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![self.col, lo, hi], |r| r.get::<_, String>(0))
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }
}

pub(super) fn same_truth(a: &Truth<'_>, b: &Truth<'_>) -> bool {
    std::ptr::eq(
        a as *const Truth<'_> as *const (),
        b as *const Truth<'_> as *const (),
    )
}

#[cfg(test)]
pub(crate) mod tests {
    use std::collections::BTreeSet;

    use super::*;
    use crate::gen4::op::Edit4;
    use crate::gen4::op::tests::{id, imported_log, native_edit};
    use crate::gen4::stamp::{HeritageStamp, StampCtx, StampHlc};
    use crate::gen4::translate::native_body4;
    use crate::store::gen4::derive::tests::{assert_rebuild_is_identity, heritage, native, op};
    use crate::store::gen4::schema::{open, open_in_memory};
    use crate::store::gen4::truth::tests::bound;
    use crate::store::gen4::truth::{SelfId, hlc_parse, hlc_text};
    use crate::sync2::id::Key;
    use crate::sync2::op as v3;
    use crate::sync2::op::EntKind;

    /// 本机身份的设备（与 `derive.rs` 测试里的设备字节不撞）。
    pub(crate) const ME: u8 = 0xa1;
    const SK: [u8; 32] = [7; 32];
    const NOW: i64 = 1_800_000_000_000;

    pub(crate) fn me() -> Id {
        id(ME)
    }

    /// 绑一个集合、建本机身份。
    pub(crate) fn ready(t: &Truth<'_>) -> i64 {
        let col = bound(t);
        assert_eq!(
            t.tx(|t| t.create_self(col, &me(), &SK, None, NOW)),
            Ok(true)
        );
        col
    }

    pub(crate) fn edit(value: &str) -> Body4 {
        Body4::Edit(Edit4 {
            value: format!("\"{value}\""),
            ..native_edit()
        })
    }

    fn field() -> String {
        native_edit().key
    }

    fn me_now(t: &Truth<'_>, col: i64) -> SelfId {
        t.self_identity(col).unwrap().unwrap()
    }

    /// 在一个事务里写 [bodies]（每条带自己的 now），收尾，返回操作号与链值。
    fn write_all(t: &Truth<'_>, col: i64, bodies: &[(Body4, i64)]) -> Vec<(OpId, Chain)> {
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            let mut n = Native::open(t, col)?;
            let mut out = Vec::new();
            for (b, now) in bodies {
                out.push(n.write(&mut ix, b.clone(), *now)?);
            }
            n.finish(&mut ix)?;
            Ok(out)
        })
        .unwrap()
    }

    fn op_at(t: &Truth<'_>, col: i64, id: &OpId) -> Op4 {
        t.entry(col, id).unwrap().unwrap().op().unwrap().clone()
    }

    fn seq_of(seq: u64) -> OpId {
        OpId { device: me(), seq }
    }

    #[test]
    fn writes_get_the_next_seq_the_chain_and_deps_of_everything_applied() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        // 先收进来的：另一台设备的两条原生操作、一台旧设备的一条承袭操作。
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            native(t, &mut ix, col, &op(0x21, 1, 10, &[], &edit("x1")));
            native(t, &mut ix, col, &op(0x21, 2, 11, &[], &edit("x2")));
            heritage(t, &mut ix, col, op(0xd1, 1, 5, &[], &edit("h1")));
            ix.settle().map(|_| ())
        })
        .unwrap();
        let wrote = write_all(
            &t,
            col,
            &[(edit("a"), NOW), (edit("b"), NOW), (edit("c"), NOW + 5)],
        );
        let mut prev: Option<Hlc> = None;
        for (i, (oid, chain)) in wrote.iter().enumerate() {
            assert_eq!(*oid, seq_of(i as u64 + 1));
            assert_eq!(t.chain_at(col, &me(), oid.seq), Ok(*chain));
            let o = op_at(&t, col, oid);
            assert_eq!(o.deps.get(&me()), 0);
            assert_eq!(o.deps.get(&id(0x21)), 2);
            assert_eq!(o.deps.get(&id(0xd1)), 1);
            assert_eq!(o.hlc.device, me());
            if let Some(p) = prev {
                assert!(o.hlc > p, "{:?} after {p:?}", o.hlc);
            }
            prev = Some(o.hlc);
        }
        assert_eq!(me_now(&t, col).hlc, prev.unwrap());
        assert_eq!(t.tx(|t| t.audit(col)), Ok(6));
        // 本机最后写的支配了它见过的 x2：胜者是 c。
        let ix = Index::new(&t, col);
        assert_eq!(
            ix.value(EntKind::Note, &Key::Uuid(id(3)), &field()),
            Ok(Some("\"c\"".to_owned()))
        );
        assert_rebuild_is_identity(&t, col);
    }

    #[test]
    fn the_clock_never_goes_back_across_writers_and_sessions() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        // 墙钟倒退：逻辑位往上加，不倒退。
        let a = write_all(
            &t,
            col,
            &[(edit("a"), NOW), (edit("b"), NOW - 1000), (edit("c"), NOW)],
        );
        let h: Vec<(i64, u32)> = a
            .iter()
            .map(|(o, _)| {
                let h = op_at(&t, col, o).hlc;
                (h.wall, h.logical)
            })
            .collect();
        assert_eq!(h, vec![(NOW, 0), (NOW, 1), (NOW, 2)]);
        let stored: String = conn
            .query_row("SELECT hlc FROM self_ WHERE col = ?1", [col], |r| r.get(0))
            .unwrap();
        assert_eq!(stored, format!("{NOW}:2"));
        // 另一个会话、新的写入者：从 `self_` 接着走。
        let t2 = Truth::new(&conn);
        let b = write_all(&t2, col, &[(edit("d"), NOW - 50_000)]);
        let hb = op_at(&t2, col, &b[0].0).hlc;
        assert_eq!((b[0].0.seq, hb.wall, hb.logical), (4, NOW, 3));
    }

    #[test]
    fn the_clock_tops_every_dependency_but_not_a_runaway_one() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        let hour = 3_600_000;
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            native(
                t,
                &mut ix,
                col,
                &op(0x21, 1, NOW + hour, &[], &edit("ahead")),
            );
            ix.settle().map(|_| ())
        })
        .unwrap();
        let a = write_all(&t, col, &[(edit("a"), NOW)]);
        let ha = op_at(&t, col, &a[0].0).hlc;
        assert_eq!(
            (ha.wall, ha.logical),
            (NOW + hour, 1),
            "tops the op it depends on"
        );
        // 超前两天的不追：本机时钟从已有的最大值往前走。
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            native(
                t,
                &mut ix,
                col,
                &op(0x22, 1, NOW + 48 * hour, &[], &edit("runaway")),
            );
            ix.settle().map(|_| ())
        })
        .unwrap();
        let b = write_all(&t, col, &[(edit("b"), NOW)]);
        let ob = op_at(&t, col, &b[0].0);
        assert_eq!((ob.hlc.wall, ob.hlc.logical), (NOW + hour, 2));
        assert_eq!(ob.deps.get(&id(0x22)), 1, "still depends on it");
    }

    #[test]
    fn no_identity_or_a_changed_identity_is_refused() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let e = t.tx(|t| Native::open(t, col).map(|_| ())).unwrap_err();
        assert!(e.contains("no local identity"), "{e}");
        t.tx(|t| t.create_self(col, &me(), &SK, None, NOW)).unwrap();
        let e = t
            .tx(|t| {
                let mut ix = Index::new(t, col);
                let mut n = Native::open(t, col)?;
                n.write(&mut ix, edit("a"), NOW)?;
                // 身份在两次写之间被换掉（换身份是 G8-6 的事；这里直接改表模拟）。
                t.conn()
                    .execute("UPDATE self_ SET device = ?1", [&id(0xa2).0[..]])
                    .unwrap();
                n.write(&mut ix, edit("b"), NOW)
            })
            .unwrap_err();
        assert!(e.contains("identity changed"), "{e}");
        assert_eq!(t.tx(|t| t.last_of(col, &me())), Ok(0), "rolled back");
        assert_eq!(me_now(&t, col).device, me());
    }

    #[test]
    fn misuse_is_refused_before_anything_is_written() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        // 事务外。
        let mut ix = Index::new(&t, col);
        let mut n = Native::open(&t, col).unwrap();
        let e = n.write(&mut ix, edit("a"), NOW).unwrap_err();
        assert!(e.contains("outside a transaction"), "{e}");
        let one = BTreeSet::from(["u".to_owned()]);
        let e = n.write_salts(&mut ix, &one, NOW).unwrap_err();
        assert!(e.contains("outside a transaction"), "{e}");
        let e = n.finish(&mut ix).unwrap_err();
        assert!(e.contains("outside a transaction"), "{e}");
        // 别的集合的索引、`Salts` 绕道、不认识的种类。
        let other = t
            .tx(|t| t.bind("another-profile", &id(0xc1), "dir2"))
            .unwrap();
        let cases = [
            (other, edit("a"), "not collection"),
            (col, Body4::salts(["u"]).unwrap(), "write_salts"),
            (col, Body4::Unknown, "unknown body"),
            // 承袭来的复习日志（带旧 HLC / 旧服务器时刻）不是本机新写的形（设计稿 §536）。
            (
                col,
                Body4::Log(imported_log()),
                "heritage hlc / server time",
            ),
        ];
        for (ix_col, body, want) in cases {
            let e = t
                .tx(|t| {
                    let mut ix = Index::new(t, ix_col);
                    Native::open(t, col)?.write(&mut ix, body.clone(), NOW)
                })
                .unwrap_err();
            assert!(e.contains(want), "{e}");
        }
        assert_eq!(t.tx(|t| t.audit(col)), Ok(0));
        assert_eq!(me_now(&t, col).hlc.wall, 0);
    }

    /// 一批里中途有一条写不进去：整个事务回滚，日志、链尾、时钟、索引都像这一批没发生过；reset 之后照常写。
    #[test]
    fn a_failed_write_leaves_nothing_behind() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        let stamped = Body4::Edit(Edit4 {
            stamp: Some(HeritageStamp {
                writer: "w".to_owned(),
                seq: 1,
                ctx: StampCtx::parse("{}"),
                hlc: StampHlc::of("1:0:w"),
                server_time: None,
            }),
            ..native_edit()
        });
        let mut ix = Index::new(&t, col);
        let e = t
            .tx(|t| {
                let mut n = Native::open(t, col)?;
                n.write(&mut ix, edit("a"), NOW)?;
                n.write(&mut ix, stamped.clone(), NOW)
            })
            .unwrap_err();
        assert!(e.contains("heritage stamp"), "{e}");
        ix.reset();
        assert_eq!(t.tx(|t| t.last_of(col, &me())), Ok(0));
        assert_eq!(me_now(&t, col).hlc.wall, 0);
        let regs: i64 = conn
            .query_row("SELECT count(*) FROM reg_ix", [], |r| r.get(0))
            .unwrap();
        assert_eq!(regs, 0);
        let w = write_all(&t, col, &[(edit("b"), NOW)]);
        assert_eq!(w[0].0.seq, 1);
        assert_rebuild_is_identity(&t, col);
    }

    #[test]
    fn salts_are_declared_once_per_identity() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        let set = |xs: &[&str]| -> BTreeSet<String> { xs.iter().map(|s| s.to_string()).collect() };
        // 一台受信的别的设备已经声明过 d：本机照样自己声明（不拿别人的抵）。
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            native(
                t,
                &mut ix,
                col,
                &op(0x21, 1, 10, &[], &Body4::salts(["d"]).unwrap()),
            );
            ix.settle().map(|_| ())
        })
        .unwrap();
        let salts_of = |o: &OpId| match op_at(&t, col, o).body().unwrap() {
            Body4::Salts { salts } => salts,
            b => panic!("{b:?}"),
        };
        let run = |xs: BTreeSet<String>| -> Option<OpId> {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let mut n = Native::open(t, col)?;
                let r = n.write_salts(&mut ix, &xs, NOW)?;
                n.finish(&mut ix)?;
                Ok(r)
            })
            .unwrap()
        };
        let first = run(set(&["a", "b"])).unwrap();
        assert_eq!(salts_of(&first), set(&["a", "b"]));
        assert_eq!(run(set(&["a", "b"])), None);
        assert_eq!(run(set(&[])), None);
        let third = run(set(&["b", "c"])).unwrap();
        assert_eq!(
            salts_of(&third),
            set(&["c"]),
            "only what this identity has not declared"
        );
        let fourth = run(set(&["d"])).unwrap();
        assert_eq!(salts_of(&fourth), set(&["d"]));
        assert_eq!((first.seq, third.seq, fourth.seq), (1, 2, 3));
        assert_eq!(
            t.binding(col).unwrap().unwrap().salts,
            set(&["a", "b", "c", "d"])
        );
        // 超过一条 Salts 的上限：报错、不写。
        let many: BTreeSet<String> = (0..=crate::gen4::op::SALTS_MAX)
            .map(|i| format!("s{i:06}"))
            .collect();
        let e = t
            .tx(|t| {
                let mut ix = Index::new(t, col);
                Native::open(t, col)?.write_salts(&mut ix, &many, NOW)
            })
            .unwrap_err();
        assert!(e.contains("too many salts"), "{e}");
        assert_eq!(t.tx(|t| t.last_of(col, &me())), Ok(3));
        assert_rebuild_is_identity(&t, col);
    }

    #[test]
    fn the_local_identity_is_created_once() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let e = t
            .tx(|t| t.create_self(99, &me(), &SK, None, NOW))
            .unwrap_err();
        assert!(e.contains("no collection"), "{e}");
        assert_eq!(
            t.tx(|t| t.create_self(col, &me(), &SK, None, NOW)),
            Ok(true)
        );
        assert_eq!(
            t.tx(|t| t.create_self(col, &me(), &SK, None, NOW + 1)),
            Ok(false)
        );
        for (device, sk) in [(id(0xa2), SK), (me(), [8; 32])] {
            let e = t
                .tx(|t| t.create_self(col, &device, &sk, None, NOW))
                .unwrap_err();
            assert!(e.contains("already has local identity"), "{e}");
        }
        let got = me_now(&t, col);
        assert_eq!(
            (got.device, got.sk, got.hlc.wall, got.prev, got.created),
            (me(), SK, 0, None, NOW)
        );
        let public = crate::sync2::keys::DeviceKey::from_seed(&SK).public();
        assert_eq!(t.device_key(col, &me()), Ok(Some(public)));
        // 已有日志的设备 ID 不能拿来当新身份。
        let conn2 = open_in_memory().unwrap();
        let t2 = Truth::new(&conn2);
        let col2 = bound(&t2);
        t2.tx(|t| {
            t.append_native(col2, &op(ME, 1, 1, &[], &edit("x")))
                .map(|_| ())
        })
        .unwrap();
        let e = t2
            .tx(|t| t.create_self(col2, &me(), &SK, None, NOW))
            .unwrap_err();
        assert!(e.contains("already has a log"), "{e}");
        assert_eq!(t2.self_identity(col2), Ok(None));
    }

    /// 迁移建的身份带上一个身份（设计 §3.3 的 `prev`）：存进 `self_` 三列、读回原样；同一把钥匙的公钥也记到旧设备
    /// 名下；续做时同一个 prev 幂等、换了 prev 报错；坏形状（seq 0 却不在链起点、指向自己）拒收，旧设备已记过别的
    /// 公钥也拒收。
    #[test]
    fn the_local_identity_carries_its_previous_identity() {
        use crate::gen4::head::PrevIdentity;
        let old = id(0xb7);
        let prev = PrevIdentity {
            device: old,
            seq: 42,
            chain: [9; 32],
        };
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        for bad in [
            PrevIdentity {
                device: old,
                seq: 0,
                chain: [9; 32],
            },
            PrevIdentity {
                device: me(),
                seq: 3,
                chain: [9; 32],
            },
        ] {
            let e = t
                .tx(|t| t.create_self(col, &me(), &SK, Some(&bad), NOW))
                .unwrap_err();
            assert!(e.contains("previous identity"), "{e}");
        }
        assert_eq!(t.self_identity(col), Ok(None));
        assert_eq!(
            t.tx(|t| t.create_self(col, &me(), &SK, Some(&prev), NOW)),
            Ok(true)
        );
        assert_eq!(
            t.tx(|t| t.create_self(col, &me(), &SK, Some(&prev), NOW + 1)),
            Ok(false)
        );
        let e = t
            .tx(|t| t.create_self(col, &me(), &SK, None, NOW))
            .unwrap_err();
        assert!(e.contains("already has local identity"), "{e}");
        assert_eq!(me_now(&t, col).prev, Some(prev.clone()));
        let public = crate::sync2::keys::DeviceKey::from_seed(&SK).public();
        assert_eq!(t.device_key(col, &old), Ok(Some(public)));
        // 链起点（上一个身份一条操作都没留下）是合法的 prev。
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let start = PrevIdentity {
            device: old,
            seq: 0,
            chain: crate::sync2::segment::CHAIN_ZERO,
        };
        assert_eq!(
            t.tx(|t| t.create_self(col, &me(), &SK, Some(&start), NOW)),
            Ok(true)
        );
        assert_eq!(me_now(&t, col).prev, Some(start));
        // 旧设备已经以另一个公钥记在 peers 里：不建身份。
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        t.tx(|t| {
            t.set_peer(
                col,
                &crate::store::gen4::truth::Peer {
                    device: old,
                    public: [1; 32],
                    name: None,
                    ext: None,
                    head_gen: None,
                    first_seen: None,
                },
            )
        })
        .unwrap();
        let e = t
            .tx(|t| t.create_self(col, &me(), &SK, Some(&prev), NOW))
            .unwrap_err();
        assert!(e.contains("another public key"), "{e}");
        assert_eq!(t.self_identity(col), Ok(None));
    }

    #[test]
    fn the_stored_clock_text_only_takes_its_own_shape() {
        let d = me();
        let h = Hlc {
            wall: NOW,
            logical: 7,
            device: d,
        };
        assert_eq!(hlc_text(&h), format!("{NOW}:7"));
        assert_eq!(hlc_parse(&hlc_text(&h), d), Ok(h));
        assert_eq!(hlc_parse("-5:0", d).map(|h| h.wall), Ok(-5));
        for bad in [
            "",
            "1",
            "1:",
            ":1",
            "01:2",
            "1:02",
            "1:2:3",
            "+1:2",
            "1: 2",
            "1:-2",
            "1:4294967296",
            "-0:0",
        ] {
            assert!(hlc_parse(bad, d).is_err(), "{bad}");
        }
        // 存进库里的坏文本：读身份就报错，不是当成 0 接着发。
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        conn.execute("UPDATE self_ SET hlc = '00:1'", []).unwrap();
        assert!(t.self_identity(col).unwrap_err().contains("bad hlc"));
        assert!(t.tx(|t| Native::open(t, col).map(|_| ())).is_err());
    }

    #[test]
    fn the_stored_clock_only_moves_forward() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        let h = |wall: i64, logical: u32, b: u8| Hlc {
            wall,
            logical,
            device: id(b),
        };
        assert_eq!(t.tx(|t| t.set_self_hlc(col, &h(5, 0, ME))), Ok(()));
        for bad in [h(5, 0, ME), h(4, 9, ME)] {
            let e = t.tx(|t| t.set_self_hlc(col, &bad)).unwrap_err();
            assert!(e.contains("go back"), "{e}");
        }
        let e = t.tx(|t| t.set_self_hlc(col, &h(9, 0, 0xa2))).unwrap_err();
        assert!(e.contains("not the local identity"), "{e}");
        assert_eq!(me_now(&t, col).hlc, h(5, 0, ME));
    }

    /// 同一个事务里开两个写入者交替写（G9-3 的 `join` 与命令层同批时就是这样）：seq 不重不漏，各自的依赖都不含自己，
    /// 中途收进来的操作下一条立刻依赖上。
    #[test]
    fn two_writers_interleave_without_gaps() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            let mut a = Native::open(t, col)?;
            let mut b = Native::open(t, col)?;
            for i in 0..6u64 {
                let w = if i % 2 == 0 { &mut a } else { &mut b };
                let (oid, _) = w.write(&mut ix, edit(&format!("v{i}")), NOW)?;
                assert_eq!(oid.seq, i + 1);
                if i == 2 {
                    native(t, &mut ix, col, &op(0x21, 1, 10, &[], &edit("x")));
                }
            }
            a.finish(&mut ix)?;
            Ok(())
        })
        .unwrap();
        assert_eq!(t.tx(|t| t.audit(col)), Ok(7));
        for seq in 1..=6u64 {
            let o = op_at(&t, col, &seq_of(seq));
            assert_eq!(o.deps.get(&id(0x21)), u64::from(seq > 3), "seq {seq}");
        }
        assert_rebuild_is_identity(&t, col);
    }

    /// 两个连接、两个线程同时写同一个集合（真并发；新代下只有主进程写，这里验的是同进程里两个连接的最坏情况）：
    /// 调用方自己开 `BEGIN IMMEDIATE` + reset（`truth.rs`「会话与事务」），写锁排队，日志不重不漏、链接得上、时钟单调。
    #[test]
    fn writers_on_two_connections_race_without_gaps() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-native-race");
        let path = dir.0.join("srs4.db");
        let col = {
            let conn = open(&path).unwrap();
            ready(&Truth::new(&conn))
        };
        const N: u64 = 40;
        let run = |tag: &'static str| {
            let path = path.clone();
            std::thread::spawn(move || {
                let conn = open(&path).unwrap();
                conn.busy_timeout(std::time::Duration::from_secs(30))
                    .unwrap();
                let t = Truth::new(&conn);
                for i in 0..N {
                    conn.execute_batch("BEGIN IMMEDIATE").unwrap();
                    t.reset();
                    let r = (|| -> Result<(), String> {
                        let mut ix = Index::new(&t, col);
                        let mut n = Native::open(&t, col)?;
                        n.write(&mut ix, edit(&format!("{tag}{i}")), NOW)?;
                        n.finish(&mut ix).map(|_| ())
                    })();
                    match r {
                        Ok(()) => conn.execute_batch("COMMIT").unwrap(),
                        Err(e) => {
                            conn.execute_batch("ROLLBACK").unwrap();
                            panic!("{tag}{i}: {e}");
                        }
                    }
                }
            })
        };
        let (a, b) = (run("a"), run("b"));
        a.join().unwrap();
        b.join().unwrap();
        let conn = open(&path).unwrap();
        let t = Truth::new(&conn);
        assert_eq!(t.tx(|t| t.audit(col)), Ok(2 * N));
        let mut prev = None;
        for seq in 1..=2 * N {
            let h = op_at(&t, col, &seq_of(seq)).hlc;
            if let Some(p) = prev {
                assert!(h > p, "seq {seq}");
            }
            prev = Some(h);
        }
        assert_eq!(me_now(&t, col).hlc, prev.unwrap());
        assert_rebuild_is_identity(&t, col);
    }

    /// 子进程那一半：开一个事务写 3 条，不提交就直接退出（等于写到一半被杀）。
    #[test]
    fn native_child_process_half() {
        let Ok(path) = std::env::var("FUSHI_NATIVE_CHILD_DB") else {
            return;
        };
        let conn = open(std::path::Path::new(&path)).unwrap();
        let col: i64 = conn
            .query_row("SELECT col FROM self_", [], |r| r.get(0))
            .unwrap();
        let t = Truth::new(&conn);
        conn.execute_batch("BEGIN IMMEDIATE").unwrap();
        t.reset();
        let mut ix = Index::new(&t, col);
        let mut n = Native::open(&t, col).unwrap();
        for i in 0..3 {
            n.write(&mut ix, edit(&format!("child{i}")), NOW + 10_000)
                .unwrap();
        }
        n.finish(&mut ix).unwrap();
        println!("NATIVE_CHILD wrote 3, exiting without commit");
        std::process::exit(0);
    }

    /// 崩溃：另一个进程写到一半退出（事务没提交）。重开之后日志、链尾、时钟都停在最后一次提交，接着写的 seq 与链
    /// 接在那里。
    #[test]
    fn a_crash_mid_batch_commits_nothing() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-native-crash");
        let path = dir.0.join("srs4.db");
        let col = {
            let conn = open(&path).unwrap();
            let t = Truth::new(&conn);
            let col = ready(&t);
            write_all(&t, col, &[(edit("a"), NOW), (edit("b"), NOW)]);
            col
        };
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "store::gen4::native::tests::native_child_process_half",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("FUSHI_NATIVE_CHILD_DB", &path)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "{stdout}");
        assert!(stdout.contains("NATIVE_CHILD wrote 3"), "{stdout}");
        let conn = open(&path).unwrap();
        let t = Truth::new(&conn);
        assert_eq!(t.tx(|t| t.audit(col)), Ok(2));
        assert_eq!(
            me_now(&t, col).hlc.wall,
            NOW,
            "the child's clock never landed"
        );
        let tail = t.chain_at(col, &me(), 2).unwrap();
        let w = write_all(&t, col, &[(edit("c"), NOW)]);
        assert_eq!(w[0].0.seq, 3);
        let third = op_at(&t, col, &w[0].0);
        assert_eq!(w[0].1, crate::gen4::op::chain_next4(&tail, &third));
        assert_rebuild_is_identity(&t, col);
    }

    #[test]
    fn protocol_3_bodies_convert_only_in_their_native_shape() {
        let e3 = |legacy: Option<v3::LegacyStamp>| {
            v3::Body::Edit(v3::EditBody {
                kind: EntKind::Note,
                entity: Key::Uuid(id(3)),
                key: field(),
                value: "\"x\"".to_owned(),
                machine: false,
                ts: 1,
                legacy,
            })
        };
        assert_eq!(
            native_body4(e3(None)),
            Ok(Body4::Edit(Edit4 {
                value: "\"x\"".to_owned(),
                ..native_edit()
            }))
        );
        let stamp = v3::LegacyStamp {
            writer: "w".to_owned(),
            seq: 1,
            ctx_json: "{}".to_owned(),
            hlc: "1:0:w".to_owned(),
            server_time: None,
        };
        let e = native_body4(e3(Some(stamp))).unwrap_err();
        assert!(e.contains("legacy stamp"), "{e}");
        // 带旧 HLC 或旧服务器时刻（各自单独带也算）的日志是承袭数据；都不带的照转。
        let log = crate::gen4::translate::tests::log3();
        for (hlc, server_time) in [
            (Some("1741061848001:0:anki".to_owned()), None),
            (None, Some(1_741_061_900_000)),
        ] {
            let l = v3::LogBody {
                legacy_hlc: hlc,
                legacy_server_time: server_time,
                ..log.clone()
            };
            let e = native_body4(v3::Body::Log(l)).unwrap_err();
            assert!(e.contains("legacy hlc / server time"), "{e}");
        }
        let plain = v3::LogBody {
            legacy_hlc: None,
            legacy_server_time: None,
            ..log
        };
        assert!(matches!(
            native_body4(v3::Body::Log(plain)),
            Ok(Body4::Log(_))
        ));
        let e = native_body4(v3::Body::Dedup { pairs: vec![] }).unwrap_err();
        assert!(e.contains("dedup"), "{e}");
        let e = native_body4(v3::Body::MediaAt {
            location: "l".to_owned(),
            flags: 0,
            names: vec![],
        })
        .unwrap_err();
        assert!(e.contains("does not exist"), "{e}");
        assert_eq!(
            native_body4(v3::Body::Checkpoint {
                name: "n".to_owned(),
                reason: "r".to_owned(),
            }),
            Ok(Body4::Checkpoint {
                name: "n".to_owned(),
                reason: "r".to_owned(),
            })
        );
    }
}
