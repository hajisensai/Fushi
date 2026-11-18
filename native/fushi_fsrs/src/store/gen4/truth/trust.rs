//! 首见设备的信任判定（设计 §4.2「设备信任纯本机（首次信任 + 待确认）」、§3.3「换身份带信任」；BUG-4306）。
//!
//! 是 [Truth] 的子模块：判定要读真相（[Truth::library_fresh] 直接看操作日志，不读派生投影）、写本机状态（`trust` /
//! `peers`），这些都是真相层的内部操作，`truth.rs` 只多一行 `mod trust;`。
//!
//! # 谁调
//!
//! 一切把一台设备第一次登记进 `peers` 的**同步**入口：收新根 head（`cmd/sync.rs` `plan`，含别的设备转发来的 head）与
//! 捡旧根 v3 head（`cmd/sync_oldroot.rs` `oldroot_ingest`），在 [Truth::set_peer] 回 [PeerPut::Inserted] 的同一个
//! 事务里调 [Truth::note_new_peer]。不在调用点各自补判断。
//!
//! 不走这里的登记：迁移（`carry.rs`，搬协议 3 已有的设备与信任行）、`.fushisrs` 导入与旧备份读入（`import.rs`，前面有
//! `needsConfirm` 闸门，确认过的按出自同一个 profile 当可信；备份里的不信任行另搬）、本机身份（`create_self`）。
//!
//! # 判定顺序（[Truth::note_new_peer]）
//!
//! 只在一台设备的公钥**第一次**登记进本机时判（[PeerPut::Inserted]）。公钥一经登记就先到先得，之后换钥匙的 head 是
//! [PeerPut::KeyMismatch]、按冒名不认，不再到这里。所以「这台设备可信」只能来自下面几条之一，或来自受信方的担保——
//! 承袭段头带上传者记着的作者公钥（`heritage.rs` `author_key`，`receive.rs` 收段时登记、不判信任：上传者受信，D20），
//! 它的 head 之后再来就是已认识的设备，根本不进这里。
//!
//! 本机已有它的日志、公钥却是第一次登记的（承袭段头没带公钥：上传者也不知道，协议 3 里没有公钥的设备行），**不**因为
//! 「已有日志」就当可信：公钥没有任何受信方担保，谁先拿一把钥匙写它的 head 谁就成了它（G10-4 第四轮复核 major：
//! 冒充者在旧根上换钥匙写 head 与清除，收方按「本机已有它的日志」放行、清除照执行）。照下面 1–3 条判，库里有它的日志
//! 就不是空库，结论是待确认；调用方按 [FirstSeen::wrote] 告诉派生层重判，它已落下的删除与清除随之扣住（与重建一致），
//! 用户确认后放行——只多一次确认，不丢东西；清除已经执行过的不受影响。与协议 3 `trust_head` 给「有设备行、没公钥」
//! 补公钥时不判待确认的口径不同，是有意收紧。
//!
//! 1. **换身份继承**：新 head 带 `prev`，且 `peers` 里 `prev.device` 已登记的公钥与新 head 的公钥**逐字节相同**（同一把
//!    签名钥匙：换代迁移、`rotate`、复制目录后的分叉换身份都沿用钥匙，`truth/own.rs` 文件头）——把旧身份的信任状态
//!    （含 `since`）原样带到新身份上，新身份没自报名字时把旧名字也带上。不重新弹确认：换代迁移给每台设备换新身份
//!    （设计 §5 第 4 步），漏了这一步，升级后所有老设备会整批变成待确认。**必须核公钥**：只凭 `prev` 指向谁就继承，
//!    任何人写一份 `prev` 指向可信设备的 head 就能冒充它。公钥不同 = 不继承，按下面的规则当新设备判。
//! 2. **本机库还是空的**（[Truth::library_fresh]）：首次信任。新装的设备第一次同步时谁都不认识，库里也没有可丢的东西。
//! 3. 否则：**待确认**（[TRUST_PENDING]，`since` = 它那份 head 的写出时刻）。它的普通操作照常生效，删除与彻底清除照收
//!    进日志但扣住（`weigh.rs` 不受信作者），用户确认后整批放行。
//!
//! 同一轮里先把所有 head 登记完再收段（`plan` 在前、`ingest` 在后；`oldroot_ingest` 先登记 head 再收段）：全新设备
//! 第一轮同时见到几台设备时它们都还算首次信任，与协议 3 相同。
//!
//! 「这一轮」按轮记（第五波，混合版本家庭）：一轮里旧根接手（`oldroot_ingest`）排在收新根之后，全新设备收完新根库就
//! 非空了，旧根上用户自己还没升级的协议 3 设备若照「此刻库非空」判，全成了待确认。所以 `plan`（每轮开头、收段之前）按
//! 位置记下「这一轮开始时库是不是空的」（`cmd/sync.rs` `round_fresh_key`），`oldroot_ingest` 第一次见到、且本机还
//! 没有它任何日志的协议 3 作者按这一轮开头的结论判（[Truth::note_new_peer_in_round]）——与协议 3 一轮之内同时见到
//! 的设备都算首次信任同一口径。本机已有它的日志、公钥却第一次登记的，照旧按此刻判（不放宽 G10-4 的收紧）。

use rusqlite::params;
use serde_json::Value;

use super::*;
use crate::gen4::op::{KIND_CHECKPOINT, KIND_ENTITY};

/// [Truth::note_new_peer] 的结论。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FirstSeen {
    /// 换身份：从 `from` 原样继承了信任状态 `state`（None = 可信）。
    Inherited { from: Id, state: Option<i64> },
    /// 本机库还是空的：首次信任。
    Fresh,
    /// 记成待确认。
    Pending,
}

impl FirstSeen {
    /// 写没写信任行（写了 = 调用方要告诉派生层 `trust_changed`）。
    pub fn wrote(&self) -> bool {
        matches!(
            self,
            FirstSeen::Pending | FirstSeen::Inherited { state: Some(_), .. }
        )
    }
}

/// 不算用户内容的操作种类（[Truth::library_fresh]）：盐（迁移 / 补盐写的初始盐）、并入（认领 / 并入集合）、还原点。
/// 实体创建另判（只有内置种子不算）。别的种类（修改、日志、标签、清除、媒体、牌组别名、去重、不认识的……）一律算。
const NOT_CONTENT: [u16; 3] = [KIND_SALTS, KIND_JOIN, KIND_CHECKPOINT];

impl Truth<'_> {
    /// 集合 [col] 里还没有用户自己的东西：真相里除了内置种子（`data` 带 `builtin` 的实体创建：默认牌组、内置笔记类型，
    /// Dart 开库就写，`SrsDbStore.ensureBuiltins`）与 [NOT_CONTENT] 以外一条操作都没有，也没有空洞、副本记录、待投递的
    /// 承袭槽、暂缓 / 分叉中的条目、还在等待缓冲里的原生操作（它们都说明这里有过内容；后者已收下、只是前面缺着，G10-4）。
    /// 原生日志与承袭日志一样看。
    ///
    /// 这是「库里有没有用户的东西」的唯一实现：首次信任（本文件）与「空集合可换绑」（`discard.rs` [super::super::discard::disposable]，
    /// 第五波 G9 身份收尾）都问它，两处口径不会分叉。
    ///
    /// 直接查真相、不读派生投影：真相先于派生落库，判定不受投影是否收好影响（协议 3 BUG-4478 是读投影读到了空库）。
    /// 协议 3 的口径（`store/sync2/trust.rs` `library_fresh`：没有复习日志、没有修改记录、身份记录全是内置的）在这里
    /// 更保守：任何非内置的操作都算「有」——判成「有」只会让新设备先待确认，不会丢东西。
    ///
    /// 代价：逐台设备按主键区间扫，碰到第一条算数的就停；内置种子只有几条。
    pub fn library_fresh(&self, col: i64) -> Result<bool, String> {
        let skip = NOT_CONTENT
            .iter()
            .map(u16::to_string)
            .collect::<Vec<_>>()
            .join(", ");
        let ops_sql = format!(
            "SELECT k, kind FROM ops WHERE k BETWEEN ?1 AND ?2 AND kind NOT IN ({skip}) ORDER BY k"
        );
        for d in self.devices(col)? {
            let (lo, hi) = k_range(d.dev);
            for table in ["op_voids", "op_alias", "op_pending", "op_forks", "op_wait"] {
                let any: bool = self
                    .conn
                    .prepare_cached(&format!(
                        "SELECT EXISTS (SELECT 1 FROM {table} WHERE k BETWEEN ?1 AND ?2)"
                    ))
                    .map_err(sql)?
                    .query_row(params![lo, hi], |r| r.get(0))
                    .map_err(sql)?;
                if any {
                    return Ok(false);
                }
            }
            let mut stmt = self.conn.prepare_cached(&ops_sql).map_err(sql)?;
            let mut it = stmt.query(params![lo, hi]).map_err(sql)?;
            while let Some(r) = it.next().map_err(sql)? {
                let kind: i64 = r.get(1).map_err(sql)?;
                if kind != i64::from(KIND_ENTITY) || !self.builtin_seed(r.get(0).map_err(sql)?)? {
                    return Ok(false);
                }
            }
        }
        Ok(true)
    }

    /// 主键 [k] 那一条是不是内置种子（实体创建、`data` 的 `builtin` 非空）。
    fn builtin_seed(&self, k: i64) -> Result<bool, String> {
        let Some(e) = self.entry_by_key(k)? else {
            return Ok(false);
        };
        let body = match e.slot() {
            Some(slot) => applied_body(&slot),
            None => e.op().and_then(|op| op.body().ok()),
        };
        Ok(match body {
            Some(Body4::Entity { data, .. }) => serde_json::from_str::<Value>(&data)
                .ok()
                .and_then(|v| v.get("builtin").cloned())
                .is_some_and(|b| !b.is_null()),
            _ => false,
        })
    }

    /// 一台设备刚被 [Truth::set_peer] 第一次登记（[PeerPut::Inserted]）：按模块文件头的顺序判它的信任状态并写下。
    /// [public] 是它这份 head 的公钥，[prev] 是 head 自报的前一个身份（协议 3 head 没有），[seen_at] 是 head 的写出时刻。
    /// 在调用方的写事务里。
    pub fn note_new_peer(
        &self,
        col: i64,
        device: &Id,
        public: &[u8; 32],
        prev: Option<&PrevIdentity>,
        seen_at: i64,
    ) -> Result<FirstSeen, String> {
        self.note_new_peer_in_round(col, device, public, prev, seen_at, false)
    }

    /// [Truth::note_new_peer]，[round_fresh] = 这一轮开始时本机库还是空的（模块文件头「这一轮」按轮记）：为真时库此刻
    /// 非空也按首次信任判。调用方只对本机还没有它任何日志的设备传真。
    pub fn note_new_peer_in_round(
        &self,
        col: i64,
        device: &Id,
        public: &[u8; 32],
        prev: Option<&PrevIdentity>,
        seen_at: i64,
        round_fresh: bool,
    ) -> Result<FirstSeen, String> {
        self.write(|| {
            if let Some(p) = prev.filter(|p| p.device != *device) {
                if self.device_key(col, &p.device)?.as_ref() == Some(public) {
                    let entry = self.trust_entry(col, &p.device)?;
                    if let Some((state, since)) = entry {
                        self.set_trust(col, device, Some(state), since)?;
                    }
                    let old_name = self.peer(col, &p.device)?.and_then(|o| o.name);
                    if let Some(name) = old_name {
                        self.conn
                            .prepare_cached(
                                "UPDATE peers SET name = ?3 WHERE col = ?1 AND device = ?2 AND name IS NULL",
                            )
                            .map_err(sql)?
                            .execute(params![col, &device.0[..], name])
                            .map_err(sql)?;
                    }
                    return Ok(FirstSeen::Inherited {
                        from: p.device,
                        state: entry.map(|(s, _)| s),
                    });
                }
            }
            if round_fresh || self.library_fresh(col)? {
                return Ok(FirstSeen::Fresh);
            }
            self.set_trust(col, device, Some(TRUST_PENDING), seen_at)?;
            Ok(FirstSeen::Pending)
        })
    }
}
