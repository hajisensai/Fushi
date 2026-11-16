//! 本机身份（`self_` 表）与换身份（设计 §3.3、§4.2「身份分叉的检测与换身份重签发」；规划 §1.1 G8 / G11 行，G8-6）。
//!
//! 是 [Truth] 的子模块：换身份要截断本机身份的原生日志、改设备行的末尾，这些都是真相层的内部操作，放在这里不必把
//! 内部函数放宽成 `pub(crate)`，`truth.rs` 只多一行 `mod own;`（规划 §2.3：truth.rs 的热点排在队尾）。
//!
//! # `self_` 的一行
//!
//! 每个集合一行：设备 ID、签名钥匙种子、本机 HLC、换身份之前的上一个身份（`prev_*`，没换过 = 全空）、这一行建立的时刻。
//! HLC 的文本形是 `<wall>:<logical>`（十进制、无前导零、无符号位以外的修饰；[hlc_text] / [parse_hlc] 互逆，读到别的形状
//! 报错）：设备就是这一行的设备，不重复写。
//!
//! # 换身份（[Truth::rotate_identity]）
//!
//! 两种情形用同一个入口：
//!
//! - **分叉**（`gen4::fork` 找到分叉点 `keep`）：同一个身份在两个安装里各自往下写了（数据目录被拷过）。本机身份
//!   `seq > keep` 的操作撤出旧身份、以新身份按原顺序重签发（载荷逐字节不变，HLC 重新取、依赖向量把旧身份的分量
//!   压到 `keep`），旧身份冻结在 `keep`：它之后的操作归另一个安装，按普通设备收（`append_native` 从 `keep` 处的链值
//!   接着验）。
//! - **主动换**（导入 / 恢复 / 拷目录之后预防，`keep` = 本机日志末尾）：什么都不搬，只换身份。
//!
//! 签名钥匙**沿用**（§3.3：新 head 带 `prev`、用同一把钥匙签，别的设备据此把信任与设备名带到新身份上）。`prev` =
//! `{旧设备, keep, keep 处的完整链值}`。
//!
//! `keep` 落在本机清出来的空洞区间**内部**时（那里没有链值，旧身份冻结不了），往前退到区间起点之前：多搬的只是空洞，
//! 空洞没有内容可重签发，直接丢掉；另一个安装的同号操作之后照常收来（彻底清除在派生层按实体逻辑生效，不靠这几个
//! 空洞）。往前退是安全方向：留在旧身份下的必须是两个安装共有的前缀，多搬只会多出几条内容相同、身份不同的重签发
//! （日志与身份记录按内容 ID 去重，与协议 3 的 `rotate` 同口径）。
//!
//! 整个换身份在一个事务里：中途出错整笔回滚（`Truth::tx`），不会留下半截日志或换了一半的身份。派生索引在同一个
//! 事务里逐条维护（撤出的 `Index::remove`、重签发的 `Index::add`，最后 `Index::settle`），结果与 `rebuild_all` 逐行
//! 相同（测试钉住）。调用方手里若有一个攒着没收尾的 `Index`，先收尾再换身份。
//!
//! 本机状态里按操作号记的两张表（`held` 暂扣、`checkpoints` 检查点）随之改键：搬走的改成新操作号，丢掉的空洞上的
//! 行删除（那个旧操作号从此属于另一个安装）。位置进度、段清单这些按本机身份 seq 记的同步状态不在 G7-1 的表里，
//! 由 G8-4 的表在换身份后从头对账（它们按设备 ID 记，新身份没有旧记录）。

use rusqlite::{OptionalExtension, params};

use super::*;
use crate::gen4::head::PrevIdentity;
use crate::store::gen4::derive::Index;
use crate::sync2::hlc::Clock;
use crate::sync2::keys::DeviceKey;

/// 本机在一个集合里的身份（`self_` 的一行）。
#[derive(Clone, PartialEq, Eq)]
pub struct SelfIdentity {
    pub col: i64,
    pub device: Id,
    seed: [u8; 32],
    /// 本机 HLC：发出过 / 吸收过的最大时刻（设备 = [SelfIdentity::device]）。
    pub clock: Hlc,
    /// 换身份之前的上一个身份。
    pub prev: Option<PrevIdentity>,
    /// 这一行（这个身份）建立的时刻（毫秒）。
    pub created: i64,
}

impl std::fmt::Debug for SelfIdentity {
    /// 不打印钥匙种子。
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SelfIdentity")
            .field("col", &self.col)
            .field("device", &self.device)
            .field("clock", &self.clock)
            .field("prev", &self.prev)
            .field("created", &self.created)
            .finish_non_exhaustive()
    }
}

impl SelfIdentity {
    pub fn key(&self) -> DeviceKey {
        DeviceKey::from_seed(&self.seed)
    }

    pub fn public(&self) -> [u8; 32] {
        self.key().public()
    }

    pub fn seed(&self) -> [u8; 32] {
        self.seed
    }

    /// 本机时钟（下一次 `tick` 发出的时刻严格大于 [SelfIdentity::clock]）。
    pub fn clock(&self) -> Clock {
        Clock {
            device: self.device,
            last: Hlc {
                device: self.device,
                ..self.clock
            },
        }
    }
}

/// [Truth::rotate_identity_report] 的结果。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rotated {
    /// 新身份。
    pub device: Id,
    /// 旧身份。
    pub previous: Id,
    /// 旧身份实际冻结在哪个 seq（文件头：落在空洞内部时会往前退）。
    pub keep: u64,
    /// 重签发的操作：(旧操作号, 新操作号)，按 seq 升序。
    pub moved: Vec<(OpId, OpId)>,
    /// 撤出时丢掉的空洞条数（没有内容可重签发）。
    pub dropped_voids: u64,
}

/// 原生日志一段里的一项（[Truth::native_walk]）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum NativeStep {
    Op(Op4),
    /// 空洞区间与所走范围的交集 `first..=last`；`end` 是整个区间的末尾、`chain_after` 是区间末的链值。
    Void {
        first: u64,
        last: u64,
        end: u64,
        chain_after: Chain,
    },
}

/// `self_.hlc` 的文本形。
pub(crate) fn hlc_text(h: &Hlc) -> String {
    format!("{}:{}", h.wall, h.logical)
}

/// [hlc_text] 的逆；只收它写得出的形状。
pub(crate) fn parse_hlc(text: &str, device: Id) -> Result<Hlc, String> {
    let bad = || format!("gen4 store: bad self_ hlc {text:?}");
    let (w, l) = text.split_once(':').ok_or_else(bad)?;
    let wall: i64 = w.parse().map_err(|_| bad())?;
    let logical: u32 = l.parse().map_err(|_| bad())?;
    let h = Hlc {
        wall,
        logical,
        device,
    };
    if hlc_text(&h) != text {
        return Err(bad());
    }
    Ok(h)
}

/// 分叉点记录在 `srs_meta` 里的键（`gen4::fork`；换身份时删）。
pub(crate) fn fork_key(col: i64) -> String {
    format!("gen4_fork_at/{col}")
}

fn blob_id(b: Option<Vec<u8>>) -> Result<Option<Id>, String> {
    b.as_deref().map(id_of).transpose()
}

impl<'c> Truth<'c> {
    // ------------------------------------------------------------ self_

    /// 本机在这个集合里的身份（还没建 = None）。
    pub fn self_identity(&self, col: i64) -> Result<Option<SelfIdentity>, String> {
        type Row = (
            Vec<u8>,
            Vec<u8>,
            String,
            Option<Vec<u8>>,
            Option<i64>,
            Option<Vec<u8>>,
            i64,
        );
        let row: Option<Row> = self
            .conn
            .prepare_cached(
                "SELECT device, sk, hlc, prev_device, prev_seq, prev_chain, created FROM self_ WHERE col = ?1",
            )
            .map_err(sql)?
            .query_row([col], |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                    r.get(6)?,
                ))
            })
            .optional()
            .map_err(sql)?;
        let Some((device, sk, hlc, prev_device, prev_seq, prev_chain, created)) = row else {
            return Ok(None);
        };
        let device = id_of(&device)?;
        let seed: [u8; 32] = sk
            .try_into()
            .map_err(|_| format!("gen4 store: bad signing key seed for collection {col}"))?;
        let prev = match (blob_id(prev_device)?, prev_seq, prev_chain) {
            (None, None, None) => None,
            (Some(device), Some(seq), Some(chain)) if seq >= 0 => Some(PrevIdentity {
                device,
                seq: seq as u64,
                chain: chain_of(&chain)?,
            }),
            _ => {
                return Err(format!(
                    "gen4 store: self_ of collection {col} has a partial previous identity"
                ));
            }
        };
        Ok(Some(SelfIdentity {
            col,
            device,
            seed,
            clock: parse_hlc(&hlc, device)?,
            prev,
            created,
        }))
    }

    /// 一个这个集合里没出现过的新设备 ID（UUIDv7）。
    fn fresh_device(&self, col: i64, now: i64, avoid: &[Id]) -> Result<Id, String> {
        for _ in 0..16 {
            let id = Id::new_v7(now.max(0) as u64);
            if !avoid.contains(&id) && self.dev_find(col, &id)?.is_none() {
                return Ok(id);
            }
        }
        Err("gen4 store: could not draw a fresh device id".to_owned())
    }

    /// 把本机的公钥记到 [device] 名下（本机的新身份与冻结的旧身份）。
    fn own_peer(&self, col: i64, device: &Id, public: [u8; 32], now: i64) -> Result<(), String> {
        let put = self.set_peer(
            col,
            &Peer {
                device: *device,
                public,
                name: None,
                ext: None,
                head_gen: None,
                first_seen: Some(now),
            },
        )?;
        if put == PeerPut::KeyMismatch {
            return Err(format!(
                "gen4 store: device {device} is registered with another public key"
            ));
        }
        Ok(())
    }

    /// 建本机身份：新设备 ID（UUIDv7），签名钥匙用 [seed]（迁移时沿用 `sync2_self.key_seed`，规划 §1.3），[prev] =
    /// 换代之前的身份在它日志末尾的位置（设计 §3.3；全新的库 = None）。已经有身份的集合报错（换身份走
    /// [Truth::rotate_identity]）。本机的公钥同时记进 `peers`（导出、验签与别人一样从那里取）。
    pub fn init_self(
        &self,
        col: i64,
        seed: &[u8; 32],
        prev: Option<&PrevIdentity>,
        now: i64,
    ) -> Result<SelfIdentity, String> {
        self.write(|| {
            if self.binding(col)?.is_none() {
                return Err(format!("gen4 store: no collection {col}"));
            }
            if self.self_identity(col)?.is_some() {
                return Err(format!(
                    "gen4 store: collection {col} already has a local identity"
                ));
            }
            let avoid: Vec<Id> = prev.map(|p| p.device).into_iter().collect();
            let device = self.fresh_device(col, now, &avoid)?;
            let me = SelfIdentity {
                col,
                device,
                seed: *seed,
                clock: Hlc {
                    wall: 0,
                    logical: 0,
                    device,
                },
                prev: prev.cloned(),
                created: now,
            };
            self.put_self(&me)?;
            self.own_peer(col, &device, me.public(), now)?;
            Ok(me)
        })
    }

    fn put_self(&self, me: &SelfIdentity) -> Result<(), String> {
        self.conn
            .prepare_cached(
                "INSERT OR REPLACE INTO self_ (col, device, sk, hlc, prev_device, prev_seq, prev_chain, created) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            )
            .map_err(sql)?
            .execute(params![
                me.col,
                &me.device.0[..],
                &me.seed[..],
                hlc_text(&me.clock),
                me.prev.as_ref().map(|p| p.device.0.to_vec()),
                me.prev.as_ref().map(|p| p.seq as i64),
                me.prev.as_ref().map(|p| p.chain.to_vec()),
                me.created,
            ])
            .map_err(sql)?;
        Ok(())
    }

    /// 记下本机时钟走到了 [hlc]（发出 / 吸收之后）。只进不退：不比已记的大就不写。返回写没写。
    pub fn set_self_clock(&self, col: i64, hlc: &Hlc) -> Result<bool, String> {
        self.write(|| {
            let me = self
                .self_identity(col)?
                .ok_or_else(|| format!("gen4 store: collection {col} has no local identity"))?;
            if (hlc.wall, hlc.logical) <= (me.clock.wall, me.clock.logical) {
                return Ok(false);
            }
            let text = hlc_text(hlc);
            self.conn
                .prepare_cached("UPDATE self_ SET hlc = ?2 WHERE col = ?1")
                .map_err(sql)?
                .execute(params![col, text])
                .map_err(sql)?;
            Ok(true)
        })
    }

    // ------------------------------------------------------------ 原生日志的读（分叉检测、小段合并用）

    /// 原生日志在 [seq] 处的链值；落在空洞区间内部（只有区间末有链值）或超出日志末尾 = None。
    pub(crate) fn chain_known(
        &self,
        col: i64,
        device: &Id,
        seq: u64,
    ) -> Result<Option<Chain>, String> {
        if seq == 0 {
            return Ok(Some(CHAIN_ZERO));
        }
        let Some(dev) = self.dev_find(col, device)? else {
            return Ok(None);
        };
        if self.dev_row(dev)?.kind != Some(DEV_NATIVE) || seq > self.last(dev)? {
            return Ok(None);
        }
        if let Some(run) = self.run_at_or_before(dev, seq)? {
            if run.end() > seq {
                return Ok(None);
            }
        }
        self.chain_at_dev(dev, seq).map(Some)
    }

    /// 按 seq 升序走一台设备原生日志的 `first..=last`（超出日志末尾的部分不走）。空洞区间按与范围的交集给一项。
    pub(crate) fn native_walk(
        &self,
        col: i64,
        device: &Id,
        first: u64,
        last: u64,
        mut f: impl FnMut(NativeStep) -> Result<(), String>,
    ) -> Result<(), String> {
        let Some(dev) = self.dev_find(col, device)? else {
            return Ok(());
        };
        if self.dev_row(dev)?.kind != Some(DEV_NATIVE) {
            return Err(format!("gen4 store: {device} has no native log"));
        }
        let first = first.max(1);
        let last = last.min(self.last(dev)?);
        if first > last {
            return Ok(());
        }
        let (lo, hi) = (opk(dev, first)?, opk(dev, last)?);
        let run_lo = match self.run_at_or_before(dev, first)? {
            Some(run) if first <= run.end() => run.k,
            _ => lo,
        };
        let mut op_stmt = self
            .conn
            .prepare(
                "SELECT k, wall, logical, deps, kind, fmt, flags, body, aux, fp FROM ops WHERE k BETWEEN ?1 AND ?2 ORDER BY k",
            )
            .map_err(sql)?;
        let mut void_stmt = self
            .conn
            .prepare(
                "SELECT k, n, flags, fps, chain FROM op_voids WHERE k BETWEEN ?1 AND ?2 ORDER BY k",
            )
            .map_err(sql)?;
        let mut ops = op_stmt.query_map(params![lo, hi], op_row).map_err(sql)?;
        let mut voids = void_stmt
            .query_map(params![run_lo, hi], void_row)
            .map_err(sql)?;
        let mut o = ops.next().transpose().map_err(sql)?;
        let mut v = voids.next().transpose().map_err(sql)?;
        let mut next = first;
        loop {
            let ko = o.as_ref().map(|r| r.k);
            let kv = v.as_ref().map(|r| r.k);
            let Some(min) = [ko, kv].into_iter().flatten().min() else {
                break;
            };
            let step = if ko == Some(min) {
                let row = o.take().expect("peeked row");
                o = ops.next().transpose().map_err(sql)?;
                let e = self.op_entry(row)?;
                let op = e
                    .op()
                    .cloned()
                    .ok_or("gen4 store: native log holds something that is not an op")?;
                (e.id.seq, e.id.seq, NativeStep::Op(op))
            } else {
                let run = v.take().expect("peeked row");
                v = voids.next().transpose().map_err(sql)?;
                let chain_after = chain_of(run.chain.as_deref().ok_or_else(|| {
                    "gen4 store: native void run without its chain value".to_owned()
                })?)?;
                let a = k_seq(run.k).max(first);
                let b = run.end().min(last);
                (
                    a,
                    b,
                    NativeStep::Void {
                        first: a,
                        last: b,
                        end: run.end(),
                        chain_after,
                    },
                )
            };
            if step.0 != next {
                return Err(format!("gen4 store: {device} log has a hole at {next}"));
            }
            next = step.1 + 1;
            f(step.2)?;
        }
        if next != last + 1 {
            return Err(format!("gen4 store: {device} log has a hole at {next}"));
        }
        Ok(())
    }

    // ------------------------------------------------------------ 换身份

    /// 换身份（规划 §1.1 的统一契约，G11-3 消费）：本机身份 `seq > keep_prefix` 的操作以新身份重签发，旧身份冻结在
    /// `keep_prefix`。返回新身份。细节见文件头与 [Truth::rotate_identity_report]。
    pub fn rotate_identity(&self, col: i64, keep_prefix: u64, now: i64) -> Result<Id, String> {
        self.rotate_identity_report(col, keep_prefix, now)
            .map(|r| r.device)
    }

    /// 同 [Truth::rotate_identity]，返回搬了什么。`keep_prefix` 超出本机日志末尾报错（那不是本机写过的前缀）。
    pub fn rotate_identity_report(
        &self,
        col: i64,
        keep_prefix: u64,
        now: i64,
    ) -> Result<Rotated, String> {
        self.tx(|t| t.rotate_in_tx(col, keep_prefix, now))
    }

    fn rotate_in_tx(&self, col: i64, keep_prefix: u64, now: i64) -> Result<Rotated, String> {
        let me = self
            .self_identity(col)?
            .ok_or_else(|| format!("gen4 store: collection {col} has no local identity"))?;
        let old = me.device;
        let old_dev = self.dev_find(col, &old)?;
        let last = match old_dev {
            Some(d) => self.last(d)?,
            None => 0,
        };
        if keep_prefix > last {
            return Err(format!(
                "gen4 store: cannot keep {keep_prefix} ops of {old}; its log ends at {last}"
            ));
        }
        // 1. 冻结点：不能落在空洞区间内部（那里没有链值）。
        let mut keep = keep_prefix;
        if let Some(dev) = old_dev {
            while keep > 0 {
                match self.run_at_or_before(dev, keep)? {
                    Some(run) if run.end() > keep => keep = k_seq(run.k) - 1,
                    _ => break,
                }
            }
        }
        let keep_chain = match old_dev {
            Some(dev) if keep > 0 => self.chain_at_dev(dev, keep)?,
            _ => CHAIN_ZERO,
        };
        // 2. 撤出：先从派生索引里拿掉（传改之前的样子），再删真相层的行。
        let mut idx = Index::new(self, col);
        let mut moved_ops: Vec<Op4> = Vec::new();
        let mut dropped_voids = 0u64;
        if let Some(dev) = old_dev {
            if keep < last {
                let mut gone: Vec<Entry> = Vec::new();
                self.for_each(col, &old, keep + 1, |e| {
                    gone.push(e);
                    Ok(())
                })?;
                for e in &gone {
                    idx.remove(e)?;
                    match e.op() {
                        Some(op) => moved_ops.push(op.clone()),
                        None => dropped_voids += 1,
                    }
                }
                self.truncate_native(dev, keep, &keep_chain)?;
            }
        }
        // 3. 新身份：钥匙沿用，时钟接着旧身份的走。
        let fresh = self.fresh_device(col, now, &[old])?;
        let mut clock = Clock {
            device: fresh,
            last: Hlc {
                device: fresh,
                ..me.clock
            },
        };
        let applied = self.applied(col)?;
        let mut moved: Vec<(OpId, OpId)> = Vec::with_capacity(moved_ops.len());
        for (i, op) in moved_ops.iter().enumerate() {
            // 依赖：旧身份的分量隐含为 seq - 1，压到冻结点（之后的前驱已重签发成新身份更早的 seq，由新身份的隐含分量
            // 覆盖）；其它设备照旧，但不超过本机已应用的（与协议 3 的 `rotate` 同口径）。
            let mut deps = (*op.deps).clone();
            deps.set(old, (op.id.seq - 1).min(keep));
            let named: Vec<(Id, u64)> = deps.0.iter().map(|(d, s)| (*d, *s)).collect();
            for (d, s) in named {
                if d != old && s > applied.get(&d) {
                    deps.set(d, applied.get(&d));
                }
            }
            let re = Op4 {
                id: OpId {
                    device: fresh,
                    seq: i as u64 + 1,
                },
                hlc: clock.tick(op.hlc.wall.max(now)),
                deps: Arc::new(deps),
                kind: op.kind,
                fmt: op.fmt,
                payload: op.payload.clone(),
            };
            self.append_native(col, &re)?;
            let e = self
                .entry(col, &re.id)?
                .ok_or("gen4 store: re-issued op is not in the log")?;
            idx.add(&e)?;
            moved.push((op.id, re.id));
        }
        // 4. 本机状态里按操作号记的行改键；丢掉的空洞上的行删除。
        for table in ["held", "checkpoints"] {
            for (from, to) in &moved {
                self.conn
                    .prepare_cached(&format!(
                        "UPDATE {table} SET device = ?4, seq = ?5 WHERE col = ?1 AND device = ?2 AND seq = ?3"
                    ))
                    .map_err(sql)?
                    .execute(params![
                        col,
                        &from.device.0[..],
                        from.seq as i64,
                        &to.device.0[..],
                        to.seq as i64
                    ])
                    .map_err(sql)?;
            }
            self.conn
                .prepare_cached(&format!(
                    "DELETE FROM {table} WHERE col = ?1 AND device = ?2 AND seq > ?3"
                ))
                .map_err(sql)?
                .execute(params![col, &old.0[..], keep as i64])
                .map_err(sql)?;
        }
        // 5. self_ 换成新身份；两个身份的公钥都记在 peers（冻结的旧身份之后按普通设备收、验签要用）。
        let next = SelfIdentity {
            col,
            device: fresh,
            seed: me.seed,
            clock: clock.last,
            prev: Some(PrevIdentity {
                device: old,
                seq: keep,
                chain: keep_chain,
            }),
            created: now,
        };
        self.write(|| {
            self.put_self(&next)?;
            self.conn
                .prepare_cached("DELETE FROM srs_meta WHERE key = ?1")
                .map_err(sql)?
                .execute([fork_key(col)])
                .map_err(sql)?;
            Ok(())
        })?;
        let public = me.public();
        self.own_peer(col, &old, public, now)?;
        self.own_peer(col, &fresh, public, now)?;
        idx.settle()?;
        Ok(Rotated {
            device: fresh,
            previous: old,
            keep,
            moved,
            dropped_voids,
        })
    }

    /// 把一台设备的原生日志截到 [keep]（之后的操作、空洞、链值记号都删），末尾的链值改成 [keep_chain]。[keep] 不在
    /// 空洞区间内部（调用方保证）。
    fn truncate_native(&self, dev: i64, keep: u64, keep_chain: &Chain) -> Result<(), String> {
        self.write(|| {
            let (_, hi) = k_range(dev);
            let from = opk(dev, keep + 1)?;
            for q in [
                "DELETE FROM ops WHERE k BETWEEN ?1 AND ?2",
                "DELETE FROM op_alias WHERE k BETWEEN ?1 AND ?2",
                "DELETE FROM op_voids WHERE k BETWEEN ?1 AND ?2",
            ] {
                self.conn
                    .prepare_cached(q)
                    .map_err(sql)?
                    .execute(params![from, hi])
                    .map_err(sql)?;
            }
            self.conn
                .prepare_cached("DELETE FROM log_marks WHERE dev = ?1 AND seq > ?2")
                .map_err(sql)?
                .execute(params![dev, keep as i64])
                .map_err(sql)?;
            let tail = (keep > 0).then(|| keep_chain.to_vec());
            self.conn
                .prepare_cached("UPDATE devs SET tail = ?2 WHERE dev = ?1")
                .map_err(sql)?
                .execute(params![dev, tail])
                .map_err(sql)?;
            self.with_dev(dev, |d| {
                d.tail = (keep > 0).then_some(*keep_chain);
                d.last = Some(keep);
            })
        })
    }
}
