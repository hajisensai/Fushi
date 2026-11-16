//! 新代的进程内刷新键（S1c，交接说明 §9.5 第 3 条、「S1c 刷新计数与写回包」节）：Dart 那一侧「这份缓存还能不能用」的判据（牌组树 / profile
//! 修改记录、同步冲突 / 待裁决角标、统计、RWKV 分数表）。协议 3 `store/refresh.rs` 的新代对应物，口径照它：
//!
//! | 键 | 随什么变 | 特意不随什么变 |
//! |---|---|---|
//! | `content` | 身份记录、非界面状态的修改记录、标签操作、彻底清除、可见性变化（信任改了、派生层整层重建） | 复习日志、界面状态 |
//! | `structure` | `content` 再加界面状态类修改记录（牌组收起 / 展开、排序位、新卡位置） | 复习日志 |
//! | `rwkv` | 牌组 / profile 的身份记录与非界面状态修改记录、别的设备的事件（`apply {remote}`）、整份作废 | **复习日志**、卡 / 笔记自己的修改 |
//! | `stats` | 落库的一切去掉只改界面状态的 | 只改界面状态 |
//! | `landed` | 任何落库、可见性变化 | — |
//!
//! `rwkv` 不随复习日志变是硬要求：RWKV 分数表按它整表重查，跟着每题走会与作答抢内存（以前 35 万条日志的 iPhone OOM），
//! 排队设置里的「每答几题刷新」也靠它（`SrsRwkvService`）。
//!
//! # 谁推进
//!
//! **写路径**（`dispatch.rs` 的本机写命令 `local_write`）：命令本体经 `cmd/writes.rs` 的 `Session` 落操作，`Session::land`
//! 按每条操作体的种类记一份 [Tally]（[Tally::op]，判据与协议 3 `sync2/mod.rs` `Marks` 相同）；整笔**提交之后**分发器
//! 按它推进本 profile 的计数（[G4Core::refresh_note]）。必须在提交之后：先记后提交，读者会拿到新键、读到提交前的旧数据，
//! 把旧数据记在新键名下（同协议 3）。命令失败 = 整笔回滚（新代一条命令一个事务，没有协议 3 那种分块提交），什么都不推进。
//! `apply` 的前置条件不成立（`stale`）什么都没写，也不推进。
//!
//! 不经 `Session` 的写：派生层整层重建（`cache_config_set` 改了配置、`rebuild_caches`、`refresh_caches` 实际收了东西）、
//! 改别名 / 绑定的身份命令（`collection_join` / `collection_salts_add` / `collection_adopt` / `binding_set`、`identity`
//! 第一次建）一律整份作废（[G4Core::refresh_invalidate]）；`local_state {reload: true}`（Dart 命令失败后的重读）同样整份
//! 作废（协议 3 同口径）。只动本机状态行 / 设备信息 / 媒体回收待回收集合的写不推进。
//!
//! 落真相但不经 `Session` 的命令（`import`，`cmd/fushisrs.rs`；同步一轮的 `ingest` / `ingest_finish` / `retire` / `rotate`，
//! `cmd/sync.rs`）：派生层按整层重建或增量收尾、没有逐操作的种类，真有改动（与推进本机修订号同一个判据）时在回包里放
//! [Tally::all]，分发器提交之后同样经 [Tally::take] 取走、整份作废；`import` 的预检、要确认、`unchanged` 与没收到东西的
//! 收段不放、不推进。
//!
//! # 读：`refresh_keys {profile}` → `{content, structure, rwkv, stats, landed}`（不透明串，只比相等）
//!
//! - **Primary**：只读内存（一把互斥锁里几个整数），不读库、不排写锁；Dart 在调用方 isolate 上同步调。键形 `<开库标识>:<计数>`
//!   （`structure` 是 `<开库标识>:<content>:<view>`）：开库标识每次打开库随机生成（[Refresh::new]），进程重启、关库重开
//!   （覆盖恢复、迁移后的 reopen）之后键必然不同；同一次打开里各计数只增不减，所以「键相等 = 这期间没有那一类变化」。
//! - **Secondary**（查词弹窗等只读辅助进程）：自己不写，看不见主进程内存里的计数，**分不清别的进程写的是哪一类**——五个键
//!   取同一个值，在一个读快照里拼：`<开库标识>:s:<纪元>:<修订号>:<缓存层代号>.<下限>:<绑定指纹>`。修订号是本机状态行
//!   （`local.rs`）的，主进程每条改投影的写命令在同一笔事务里推进它（含作答）；缓存层代号 `cache_gen`（`cache.rs` 文件头
//!   「变更记录」）补上修订号不覆盖的整层重建（`cache_config_set`、`rebuild_caches`）。只用 `cache_gen` 不够：牌组收起 /
//!   排序位、profile 设置这类修改不碰笔记 / 卡缓存行，代号不动，弹窗的牌组树会一直是旧的。改别名 / 绑定的身份命令
//!   （`collection_salts_add` / `collection_join` / `collection_adopt` / `binding_set`、`identity` 第一次建）既不推进修订号，
//!   也不一定碰缓存行（实测补一个还没有数据的盐两样都不动）：它们改的是 `collections` 这一行（集合标识、位置目录名、盐集合、
//!   绑定状态），绑定指纹就是这一行的散列（[binding_mark]）。纪元没落盘时（这个 profile 还没有本机状态行）记 `unstored`，
//!   不拿内核每次现生成的纪元当键（否则每读一次都不命中）。profile 没绑定集合时代号记 `0.0`、指纹记 `-`。Secondary
//!   只会多重读（作答也让它的五个键一起变），不会读到旧值；它不跑 RWKV 排队。
//!
//! # 别的进程
//!
//! 同一个库只有 Primary 写（D10，换代锁 + 写连接只在 Primary 上开）。所以 Primary 的内存计数覆盖全部写入；Secondary
//! 按上面的落盘值判。收段会话期间的 RWKV 延后（协议 3 `rwkv_held`）属于同步命令（G8-7），这里留了 [G4Core::refresh_note]
//! 的 `merged` 入口，会话的攒 / 放由 G8-7 接线时按协议 3 口径补。

use std::collections::HashMap;
use std::sync::MutexGuard;

use rusqlite::OptionalExtension;
use serde_json::{Value, json};

use super::files::OpenMode;
use super::kernel::G4Core;
use super::schema::sql;
use super::truth::Truth;
use crate::store::local_state::{EPOCH_KEY, REVISION_KEY};
use crate::sync2::op::{Body, EntKind};

/// 一条写命令落下的变化里，刷新计数要的那几类（模块文件头的表）。只记「有没有」：键只比相等，推进 1 与推进 n 等价。
#[derive(Default, Clone, Copy, Debug, PartialEq, Eq)]
pub struct Tally {
    pub landed: bool,
    pub content: bool,
    pub view: bool,
    pub rwkv: bool,
    pub stats: bool,
}

impl Tally {
    /// 一条本机操作落下（`cmd/writes.rs` `Session::land`，归一之后的操作体）。判据同协议 3 `Marks::entity` / `edit` /
    /// `log`、`semantics.rs` 的标签行、彻底清除的可见性变化；还原点不投影任何东西（协议 3 同）。
    pub fn op(&mut self, body: &Body) {
        let rwkv_kind = |k: EntKind| matches!(k, EntKind::Deck | EntKind::Profile);
        match body {
            Body::Log(_) => {
                self.landed = true;
                self.stats = true;
            }
            Body::Edit(e) if crate::store::sync2::is_view_state(e.kind, &e.key) => {
                self.landed = true;
                self.view = true;
            }
            Body::Edit(e) => {
                self.landed = true;
                self.content = true;
                self.stats = true;
                self.rwkv |= rwkv_kind(e.kind);
            }
            Body::Entity { kind, .. } => {
                self.landed = true;
                self.content = true;
                self.stats = true;
                self.rwkv |= rwkv_kind(*kind);
            }
            Body::Checkpoint { .. } => {}
            // 标签操作、彻底清除、其余（本机写命令不写别的，但不认识的一律按内容变化算：只会多重读）。
            _ => {
                self.landed = true;
                self.content = true;
                self.stats = true;
            }
        }
    }

    /// 可见性 / 派生层整体变了（信任改了、派生层整层重建）：按这些键记的缓存全部作废（协议 3 `Counters::invalidate`）。
    pub fn invalidate(&mut self) {
        self.landed = true;
        self.content = true;
        self.stats = true;
        self.rwkv = true;
    }

    pub fn all() -> Tally {
        let mut t = Tally::default();
        t.invalidate();
        t
    }

    /// 写进回包（`Session::finish`，键 [TALLY_KEY]）；分发器提交之后取走（[Tally::take]），不交给 Dart。
    pub fn json(&self) -> Value {
        json!([self.landed, self.content, self.view, self.rwkv, self.stats])
    }

    /// 从回包里取走 [TALLY_KEY]（没有 = 什么都没落，如 `stale`）。
    pub fn take(v: &mut Value) -> Tally {
        let Some(raw) = v.as_object_mut().and_then(|m| m.remove(TALLY_KEY)) else {
            return Tally::default();
        };
        let b = |i: usize| raw.get(i).and_then(Value::as_bool).unwrap_or(true);
        Tally {
            landed: b(0),
            content: b(1),
            view: b(2),
            rwkv: b(3),
            stats: b(4),
        }
    }
}

/// `Session::finish` 写下、分发器取走的回包键（模块文件头「谁推进」）。
pub const TALLY_KEY: &str = "refreshTally";

/// 一个 profile 的计数。
#[derive(Default, Debug, Clone, Copy, PartialEq, Eq)]
struct Counters {
    content: u64,
    view: u64,
    rwkv: u64,
    stats: u64,
    landed: u64,
    /// 收段会话（`ingest_begin` … `ingest_end`）期间攒着的 RWKV 推进：None = 没有会话，Some(攒到没有)。会话里每批收段
    /// 都会推进 RWKV 键，逐批放出去的话分数表整表重查跟着每批来一次、与下一批抢内存（协议 3 `rwkv_held` 同一个
    /// 起因：35 万条日志的 iPhone 收尾 OOM），所以攒到会话结束并成一次（[Counters::release]）。别的键照常逐批推进。
    rwkv_held: Option<bool>,
}

impl Counters {
    fn absorb(&mut self, t: Tally) {
        self.content += u64::from(t.content);
        self.view += u64::from(t.view);
        if t.rwkv {
            match &mut self.rwkv_held {
                Some(held) => *held = true,
                None => self.rwkv += 1,
            }
        }
        self.stats += u64::from(t.stats);
        self.landed += u64::from(t.landed);
    }

    fn hold(&mut self) {
        self.rwkv_held.get_or_insert(false);
    }

    fn release(&mut self) {
        if self.rwkv_held.take() == Some(true) {
            self.rwkv += 1;
        }
    }
}

/// 一个库（一次打开）的刷新状态。
pub struct Refresh {
    /// 这次打开库的随机标识。
    open: String,
    by_profile: HashMap<String, Counters>,
}

impl Refresh {
    pub fn new() -> Self {
        let mut b = [0u8; 8];
        getrandom::fill(&mut b).expect("system random source");
        Refresh {
            open: b.iter().map(|x| format!("{x:02x}")).collect(),
            by_profile: HashMap::new(),
        }
    }

    fn keys(&self, profile: &str) -> Value {
        let c = self.by_profile.get(profile).copied().unwrap_or_default();
        let open = &self.open;
        json!({
            "content": format!("{open}:{}", c.content),
            "structure": format!("{open}:{}:{}", c.content, c.view),
            "rwkv": format!("{open}:{}", c.rwkv),
            "stats": format!("{open}:{}", c.stats),
            "landed": format!("{open}:{}", c.landed),
        })
    }
}

impl Default for Refresh {
    fn default() -> Self {
        Refresh::new()
    }
}

/// [secondary_key] 读缓存层代号的语句（同 `dispatch.rs` 统计缓存键用的那一条；查询计划测试测的就是它）。
pub(crate) use super::dispatch::CACHE_MARK_SQL;

/// Secondary 的键（模块文件头「读」）：在调用方的读快照里读本机状态行与缓存层代号。
fn secondary_key(t: &Truth<'_>, open: &str, profile: &str) -> Result<String, String> {
    let st = super::local::read(t, profile)?;
    let epoch = if st["epochStored"] == Value::Bool(true) {
        st[EPOCH_KEY].as_str().unwrap_or("unstored").to_owned()
    } else {
        "unstored".to_owned()
    };
    let revision = st[REVISION_KEY].as_i64().unwrap_or(0);
    let ((gen, floor), mark): ((i64, i64), String) = match t.binding_of(profile)? {
        Some(b) => (
            t.conn()
                .prepare_cached(CACHE_MARK_SQL)
                .map_err(sql)?
                .query_row([b.col], |r| Ok((r.get(0)?, r.get(1)?)))
                .optional()
                .map_err(sql)?
                .unwrap_or((0, 0)),
            binding_mark(t, &b)?,
        ),
        None => ((0, 0), "-".to_owned()),
    };
    Ok(format!("{open}:s:{epoch}:{revision}:{gen}.{floor}:{mark}"))
}

/// 绑定指纹（模块文件头「读」的 Secondary）：`collections` 那一行（集合标识、位置目录名、盐集合、绑定状态）的散列。
/// 身份命令改的就是这一行；键只比相等、只在同一个进程里比，用标准库的固定键散列即可。
fn binding_mark(t: &Truth<'_>, b: &super::truth::Binding) -> Result<String, String> {
    use std::hash::{Hash, Hasher};
    let mut h = std::hash::DefaultHasher::new();
    b.collection.0.hash(&mut h);
    b.dir.hash(&mut h);
    b.salts.hash(&mut h);
    t.binding_state(b.col)?
        .map(|s| (s.stage.code(), s.via, s.at))
        .hash(&mut h);
    Ok(format!("{:016x}", h.finish()))
}

impl G4Core {
    fn refresh_lock(&self) -> MutexGuard<'_, Refresh> {
        // 只是几个计数：panic 毒化过照常用。
        self.refresh.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// `refresh_keys`：[profile] 此刻的刷新键（模块文件头「读」）。
    pub fn refresh_keys(&self, profile: &str) -> Result<Value, String> {
        if matches!(self.mode(), OpenMode::Primary) {
            return Ok(self.refresh_lock().keys(profile));
        }
        let open = self.refresh_lock().open.clone();
        let key = self.read(|t| super::cmd::snapshot(t, |t| secondary_key(t, &open, profile)))?;
        Ok(json!({"content": key, "structure": key, "rwkv": key, "stats": key, "landed": key}))
    }

    /// 一条写命令提交之后按它的 [Tally] 推进 [profile] 的计数。[merged]：这批是别的设备的事件（`apply {remote}`、
    /// 以后的收段），落了东西就让 RWKV 分数表整表重查一次（协议 3 `Landed::merged`）。
    pub fn refresh_note(&self, profile: &str, mut t: Tally, merged: bool) {
        if merged && t.landed {
            t.rwkv = true;
        }
        if t == Tally::default() {
            return;
        }
        self.refresh_lock()
            .by_profile
            .entry(profile.to_owned())
            .or_default()
            .absorb(t);
    }

    /// [profile] 按这些键记的缓存全部作废（模块文件头「谁推进」里不经 `Session` 的写）。
    pub fn refresh_invalidate(&self, profile: &str) {
        self.refresh_note(profile, Tally::all(), false);
    }

    /// `ingest_begin`：[profile] 开一段收段会话，之后的 RWKV 推进攒到 [G4Core::refresh_release] 并成一次（[Counters]
    /// `rwkv_held`）。重复开是同一段。
    pub fn refresh_hold(&self, profile: &str) {
        self.refresh_lock()
            .by_profile
            .entry(profile.to_owned())
            .or_default()
            .hold();
    }

    /// `ingest_end`：结束 [G4Core::refresh_hold] 开的一段，攒着的 RWKV 推进放出一次。没开过 = 什么都不做。
    pub fn refresh_release(&self, profile: &str) {
        if let Some(c) = self.refresh_lock().by_profile.get_mut(profile) {
            c.release();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync2::id::Key;
    use crate::sync2::op::EditBody;

    fn edit(kind: EntKind, key: &str) -> Body {
        Body::Edit(EditBody {
            kind,
            entity: Key::Text("e".into()),
            key: key.into(),
            value: "1".into(),
            machine: false,
            ts: 0,
            legacy: None,
        })
    }

    #[test]
    fn view_state_edits_move_structure_but_not_content_or_stats() {
        let mut t = Tally::default();
        t.op(&edit(EntKind::Deck, "collapsed"));
        t.op(&edit(EntKind::Card, "newPos"));
        assert_eq!(
            t,
            Tally {
                landed: true,
                view: true,
                ..Tally::default()
            }
        );
        let mut r = Refresh::new();
        let k0 = r.keys("p");
        r.by_profile.entry("p".into()).or_default().absorb(t);
        let k1 = r.keys("p");
        for k in ["content", "rwkv", "stats"] {
            assert_eq!(k0[k], k1[k], "{k}");
        }
        for k in ["structure", "landed"] {
            assert_ne!(k0[k], k1[k], "{k}");
        }
    }

    #[test]
    fn deck_and_profile_content_moves_rwkv_and_notes_do_not() {
        for (kind, rwkv) in [
            (EntKind::Deck, true),
            (EntKind::Profile, true),
            (EntKind::Note, false),
            (EntKind::Card, false),
            (EntKind::NoteType, false),
        ] {
            let mut t = Tally::default();
            t.op(&edit(kind, "name"));
            assert!(t.content && t.stats && t.landed && !t.view, "{kind:?}");
            assert_eq!(t.rwkv, rwkv, "{kind:?}");
        }
    }

    #[test]
    fn the_tally_survives_the_reply_round_trip_and_is_removed() {
        let mut t = Tally::default();
        t.op(&edit(EntKind::Deck, "position"));
        t.op(&Body::TagAdd {
            note: Key::Text("n".into()),
            tag: "x".into(),
        });
        let mut v = json!({"changed": [], TALLY_KEY: t.json()});
        assert_eq!(Tally::take(&mut v), t);
        assert_eq!(v, json!({"changed": []}));
        assert_eq!(Tally::take(&mut v), Tally::default());
    }

    #[test]
    fn keys_of_two_opens_never_collide() {
        let (a, b) = (Refresh::new(), Refresh::new());
        for k in ["content", "structure", "rwkv", "stats", "landed"] {
            assert_ne!(a.keys("p")[k], b.keys("p")[k], "{k}");
        }
    }
}
