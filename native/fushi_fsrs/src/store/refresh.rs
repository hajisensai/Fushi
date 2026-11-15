//! 进程内刷新键：Dart 那一侧「这份缓存还能不能用」的判据（牌组树、profile 修改记录、同步冲突 / 待裁决角标、统计、
//! RWKV 分数表）。**只在内存、不落盘**；由内核持有（收掉 Dart 写路径第 15 步）。
//!
//! 以前这几个计数在 Dart `SrsDbStore` 对象的内存里、每个对象从头数，靠回包里的 `marks` 一条一条加。于是：
//! 收段通道自己做完的片没有回包，要另开一条 `settled` 交付把变化送回 Dart；同一个 profile 的两个副本对象各数各的；
//! 换一个对象计数回到以前的值，指纹里还得再拼进程启动 ID 与对象序号。现在计数按 profile 归这里，落进投影的变化在
//! **提交之后**由内核自己记（[SrsCore::refresh_after] 按回包、[SrsCore::refresh_slice] 按通道的每一片），Dart 只同步读
//! 拼好的键（`refresh_keys`，[SrsCore::refresh_keys]），不存任何一份。
//!
//! 键的形态是 `<开库标识>:<计数>`：开库标识每次打开库随机生成（[Refresh::new]），进程重启、同一进程里关库重开（覆盖
//! 恢复）之后键必然不同；同一次打开里各计数只增不减，所以「键相等 = 这期间没有那一类变化」。读者只比相等，不解析。
//!
//! 必须在提交之后记：先记后提交的话，读者会拿到新键、读到提交前的旧数据，把旧数据记在新键名下，之后键不再变就一直
//! 是旧的。反过来（已提交、还没记）读者只是多重读一次。

use std::collections::HashMap;

use serde_json::{Value, json};

use super::sync2::Touched;

/// 一个 profile 的刷新计数。
#[derive(Default, Debug)]
struct Counters {
    /// 内容：复习日志与界面状态以外的事件落库、冲突扣住 / 解除改变了实体的可见性。同步冲突 / 待裁决 / 迁移提醒这类
    /// 「整库扫一遍」的角标只随它变。
    content: u64,
    /// 界面状态类修改记录（牌组收起 / 展开、排序位、新卡位置）。只进牌组树的键。
    view: u64,
    /// RWKV 分数表整表重查：牌组 / 配置类事件落库、别的设备的事件落库（同步合并）。
    rwkv: u64,
    /// 会改变统计结果的事件：落库的事件与可见性变化，去掉界面状态类。
    stats: u64,
    /// 任何落库的事件与可见性变化（= 落盘修订号在这次打开期间的增量）。
    landed: u64,
    /// 收段会话（`ingest_begin` … `ingest_end`）期间攒着的 RWKV 推进次数；None = 没有会话。会话里每片投递 / 收尾重放
    /// 都可能推进，逐片放出去的话分数表整表重查跟着每片来一次、与下一片抢内存（35 万条日志的 iPhone 收尾 OOM），
    /// 所以攒到会话结束并成一次（[Counters::release]）。
    rwkv_held: Option<u64>,
}

impl Counters {
    fn bump_rwkv(&mut self, n: u64) {
        if n == 0 {
            return;
        }
        match &mut self.rwkv_held {
            Some(held) => *held += n,
            None => self.rwkv += n,
        }
    }

    fn absorb(&mut self, l: Landed) {
        let events = l.landed + l.changed;
        self.content += l.content + l.changed;
        self.view += l.view;
        self.stats += events.saturating_sub(l.view);
        self.landed += events;
        self.bump_rwkv(l.rwkv + u64::from(l.merged));
    }

    /// 按这些键记的缓存全部作废（新开的副本对象、命令失败后的重读、整份数据被删 / 并入）。
    fn invalidate(&mut self) {
        self.content += 1;
        self.stats += 1;
        self.landed += 1;
        self.bump_rwkv(1);
    }

    fn hold(&mut self) {
        self.rwkv_held.get_or_insert(0);
    }

    fn release(&mut self) {
        if self.rwkv_held.take().is_some_and(|held| held > 0) {
            self.rwkv += 1;
        }
    }
}

/// 一次提交落进投影的变化里，刷新计数要的那几样。
#[derive(Default, Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Landed {
    /// 落进投影的事件数。
    pub landed: u64,
    /// 其中推进内容的 / 界面状态类的 / 推进 RWKV 整表重查的（sync2/mod.rs `Marks`）。
    pub content: u64,
    pub view: u64,
    pub rwkv: u64,
    /// 可见性被冲突扣住 / 解除改变了的实体数（类别认得的；口径同 local_state.rs 推进修订号时的）。
    pub changed: u64,
    /// 这次落的是别的设备的事件（收段、导入、通道的片、`apply {remote}`）：带动了牌组 / 全局状态，分数表整表重查一次。
    pub merged: bool,
}

impl Landed {
    /// 通道自己做完的一片（sync2/channel.rs `settle`）：对端事件，落了就算一次合并。
    pub(crate) fn of_slice(t: &Touched) -> Self {
        Landed {
            landed: t.marks.landed,
            content: t.marks.content,
            view: t.marks.view,
            rwkv: t.marks.rwkv,
            changed: t
                .entities_changed
                .iter()
                .filter(|(k, _)| crate::sync2::op::EntKind::parse(k).is_some())
                .count() as u64,
            merged: t.marks.landed > 0,
        }
    }

    /// 改投影的命令的回包（带 `localRevision`：内核在这条命令里写了本机状态行，local_state.rs `persist_projected_with`）。
    /// 不是这样的回包 → None。[op] / [req] 决定这次算不算合并了别的设备的事件。
    pub(crate) fn of_reply(op: &str, req: &Value, reply: &Value) -> Option<Self> {
        reply.get("localRevision")?;
        let n = |k: &str| reply["marks"][k].as_u64().unwrap_or(0);
        let landed = n("landed");
        let changed = reply["changed"].as_array().map_or(0, |a| {
            a.iter()
                .filter(|x| {
                    x.as_array().is_some_and(|p| {
                        p.len() == 2
                            && p[0]
                                .as_str()
                                .and_then(crate::sync2::op::EntKind::parse)
                                .is_some()
                    })
                })
                .count() as u64
        });
        let merged = match op {
            // 收段的一步：落了对端事件，或收尾重放了卡。
            "ingest" | "ingest_batch" | "ingest_commit" | "ingest_finish" | "replay_pending" => {
                landed > 0
                    || reply["replayed"]
                        .as_array()
                        .is_some_and(|replayed| !replayed.is_empty())
            }
            // 导入别的设备导出的操作：与旧行为一致，不看落了几条。
            "import" => true,
            // 调用方声明这批是别的设备的事件（Dart `applyRemote`：备份合并、profile 并入、`.fushisrs` 导入）。
            "apply" => req.get("remote") == Some(&Value::Bool(true)) && landed > 0,
            _ => false,
        };
        Some(Landed {
            landed,
            content: n("content"),
            view: n("view"),
            rwkv: n("rwkv"),
            changed,
            merged,
        })
    }
}

/// 一个库（一次打开）的刷新状态。
pub(crate) struct Refresh {
    /// 这次打开库的随机标识。
    open: String,
    /// 不知道影响哪些 profile 的库级变化（旧库搬迁提交）：读的时候加进每个 profile 的计数。
    all: u64,
    by_profile: HashMap<String, Counters>,
}

impl Refresh {
    pub(crate) fn new() -> Self {
        let mut b = [0u8; 8];
        getrandom::fill(&mut b).expect("system random source");
        Refresh {
            open: b.iter().map(|x| format!("{x:02x}")).collect(),
            all: 0,
            by_profile: HashMap::new(),
        }
    }

    fn of(&mut self, profile: &str) -> &mut Counters {
        self.by_profile.entry(profile.to_owned()).or_default()
    }

    fn keys(&self, profile: &str) -> Value {
        let zero = Counters::default();
        let c = self.by_profile.get(profile).unwrap_or(&zero);
        let (open, all) = (&self.open, self.all);
        json!({
            "content": format!("{open}:{}", c.content + all),
            "structure": format!("{open}:{}:{}", c.content + all, c.view),
            "rwkv": format!("{open}:{}", c.rwkv + all),
            "stats": format!("{open}:{}", c.stats + all),
            "landed": format!("{open}:{}", c.landed + all),
        })
    }
}

impl super::SrsCore {
    fn refresh(&self) -> std::sync::MutexGuard<'_, Refresh> {
        // 只是几个计数：panic 毒化过照常用。
        self.refresh.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// `refresh_keys`：[profile] 此刻的刷新键（`{content, structure, rwkv, stats, landed}`，都是不透明串）。只读内存：
    /// 不碰通道、不拿写锁、不读库，调用方在自己的线程上同步调。
    pub(crate) fn refresh_keys(&self, profile: &str) -> Value {
        self.refresh().keys(profile)
    }

    /// 一条命令返回之后（它自己的写入已提交或已回滚）按请求与结果记刷新计数。分发器的统一出口（ffi.rs
    /// `sync2_dispatch`）调；[projecting]：这条命令会改投影（ffi.rs `PROJECTING_OPS`）。
    ///
    /// - 成功、回包带 `localRevision`（内核在这条命令里写了本机状态行）：按 `marks` / `changed` 记（[Landed::of_reply]）；
    /// - `local_state` 带 `reload: true`：调用方要丢掉它按这些键记的一切（新开的副本对象、命令失败后的重读）；
    /// - 改投影的命令失败：按「可能已提交了一部分」作废一次。命令大多是单个 SAVEPOINT、失败什么都没落，但有分块
    ///   提交的（彻底清除按块）、也有提交之后才在收尾一步出错的（删 profile 后放掉收段会话）；多作废一次只让读者多重读
    ///   一次，漏记则让读者把旧数据记在新键名下。
    ///
    /// 收段会话的 RWKV 延后不在这里：挂在内核会话的开 / 关上（transport.rs `sync2_ingest_begin` / `sync2_ingest_end`），
    /// 删 profile / 并入时内核自己放掉会话也随之放掉。
    pub(crate) fn refresh_after(&self, req: &Value, reply: Result<&Value, ()>, projecting: bool) {
        let (Some(op), Some(profile)) = (
            req.get("op").and_then(Value::as_str),
            req.get("profile").and_then(Value::as_str),
        ) else {
            return;
        };
        let Ok(reply) = reply else {
            if projecting {
                self.refresh().of(profile).invalidate();
            }
            return;
        };
        if op == "local_state" && req.get("reload") == Some(&Value::Bool(true)) {
            self.refresh().of(profile).invalidate();
            return;
        }
        if let Some(landed) = Landed::of_reply(op, req, reply) {
            self.refresh().of(profile).absorb(landed);
        }
    }

    /// 收段会话开始（内核 `sync2_ingest_begin` 一进来，早于它自己做完上一次没收完的通道片）：之后这个 profile 的 RWKV
    /// 推进攒着。会话开不成时调用方紧接着 [Self::refresh_release]。
    pub(crate) fn refresh_hold(&self, profile: &str) {
        self.refresh().of(profile).hold();
    }

    /// 收段会话结束（内核 `sync2_ingest_end`：Dart 一轮结束 / 中途收手、作废副本、删 profile / 并入时内核自己放掉）：
    /// 攒下的 RWKV 推进并成一次（攒了 0 次不推进）。
    pub(crate) fn refresh_release(&self, profile: &str) {
        self.refresh().of(profile).release();
    }

    /// 收段通道自己做完的一片（已提交；sync2/channel.rs `settle` 的回调）。
    pub(crate) fn refresh_slice(&self, profile: &str, t: &Touched) {
        self.refresh().of(profile).absorb(Landed::of_slice(t));
    }

    /// [profile] 的数据整份变了（`profile_purge`、并入提交的两头）：按键记的缓存全部作废，开着的收段会话的延后也放掉。
    pub(crate) fn refresh_replaced(&self, profile: &str) {
        let mut r = self.refresh();
        let c = r.of(profile);
        c.release();
        c.invalidate();
    }

    /// 库级的整体变化（旧库搬迁提交）：每个 profile 的键都变。
    pub(crate) fn refresh_all(&self) {
        self.refresh().all += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rev(v: &Value, k: &str) -> u64 {
        v[k].as_str()
            .unwrap()
            .rsplit(':')
            .next()
            .unwrap()
            .parse()
            .unwrap()
    }

    #[test]
    fn absorb_counts_like_the_persisted_revision_minus_view() {
        let mut r = Refresh::new();
        let k0 = r.keys("p");
        // 3 条事件：1 条界面状态、1 条内容、1 条日志；另有 2 个实体的可见性变了。
        r.of("p").absorb(Landed {
            landed: 3,
            content: 1,
            view: 1,
            rwkv: 0,
            changed: 2,
            merged: false,
        });
        let k1 = r.keys("p");
        assert_eq!(rev(&k1, "content"), rev(&k0, "content") + 3);
        assert_eq!(rev(&k1, "stats"), rev(&k0, "stats") + 4);
        assert_eq!(rev(&k1, "landed"), rev(&k0, "landed") + 5);
        assert_eq!(k1["rwkv"], k0["rwkv"]);
        assert_ne!(k1["structure"], k0["structure"]);
        // 只落界面状态：内容 / 统计的键不动，牌组树的键变。
        r.of("p").absorb(Landed {
            landed: 1,
            view: 1,
            ..Landed::default()
        });
        let k2 = r.keys("p");
        assert_eq!(k2["content"], k1["content"]);
        assert_eq!(k2["stats"], k1["stats"]);
        assert_ne!(k2["structure"], k1["structure"]);
        assert_ne!(k2["landed"], k1["landed"]);
        // 别的 profile 不受影响。
        assert_eq!(r.keys("q"), {
            let fresh = Refresh {
                open: r.open.clone(),
                all: 0,
                by_profile: HashMap::new(),
            };
            fresh.keys("q")
        });
    }

    #[test]
    fn rwkv_bumps_are_held_for_the_ingest_session_and_released_as_one() {
        let mut r = Refresh::new();
        let before = rev(&r.keys("p"), "rwkv");
        r.of("p").hold();
        for _ in 0..5 {
            r.of("p").absorb(Landed {
                landed: 1,
                rwkv: 2,
                merged: true,
                ..Landed::default()
            });
        }
        r.of("p").invalidate();
        assert_eq!(rev(&r.keys("p"), "rwkv"), before, "held during the session");
        r.of("p").release();
        assert_eq!(rev(&r.keys("p"), "rwkv"), before + 1, "released as one");
        // 没攒到东西的会话不推进；会话外照常逐次推进。
        r.of("p").hold();
        r.of("p").release();
        assert_eq!(rev(&r.keys("p"), "rwkv"), before + 1);
        r.of("p").release();
        assert_eq!(rev(&r.keys("p"), "rwkv"), before + 1);
        r.of("p").absorb(Landed {
            landed: 1,
            merged: true,
            ..Landed::default()
        });
        assert_eq!(rev(&r.keys("p"), "rwkv"), before + 2);
    }

    #[test]
    fn keys_of_two_opens_never_collide_and_a_library_wide_change_moves_every_profile() {
        let (a, b) = (Refresh::new(), Refresh::new());
        for k in ["content", "structure", "rwkv", "stats", "landed"] {
            assert_ne!(a.keys("p")[k], b.keys("p")[k], "{k}");
        }
        let mut r = Refresh::new();
        let (p0, q0) = (r.keys("p"), r.keys("q"));
        r.all += 1;
        for k in ["content", "structure", "rwkv", "stats", "landed"] {
            assert_ne!(r.keys("p")[k], p0[k], "{k}");
            assert_ne!(r.keys("q")[k], q0[k], "{k}");
        }
    }

    #[test]
    fn a_reply_counts_only_when_the_kernel_wrote_the_local_state_row() {
        let req = json!({"op": "apply", "profile": "p"});
        assert_eq!(
            Landed::of_reply("apply", &req, &json!({"stale": true})),
            None
        );
        let reply = json!({
            "marks": {"landed": 2, "content": 1, "view": 0, "rwkv": 1},
            "changed": [["note", "n1"], ["bogus", "x"], ["card"]],
            "localRevision": 9,
            "localEpoch": "e",
        });
        let got = Landed::of_reply("apply", &req, &reply).unwrap();
        assert_eq!(
            got,
            Landed {
                landed: 2,
                content: 1,
                view: 0,
                rwkv: 1,
                changed: 1,
                merged: false,
            }
        );
        // 别的设备的事件：收段的一步落了事件或重放了卡、导入、声明了 `remote` 的 `apply`。
        let remote = json!({"op": "apply", "profile": "p", "remote": true});
        assert!(Landed::of_reply("apply", &remote, &reply).unwrap().merged);
        let none = json!({"marks": {"landed": 0}, "localRevision": 9, "localEpoch": "e"});
        assert!(!Landed::of_reply("apply", &remote, &none).unwrap().merged);
        assert!(Landed::of_reply("import", &req, &none).unwrap().merged);
        assert!(
            !Landed::of_reply("ingest_commit", &req, &none)
                .unwrap()
                .merged
        );
        let replayed = json!({"marks": {"landed": 0}, "replayed": ["c1"], "localRevision": 9});
        assert!(
            Landed::of_reply("replay_pending", &req, &replayed)
                .unwrap()
                .merged
        );
        assert!(
            Landed::of_reply("ingest_commit", &req, &reply)
                .unwrap()
                .merged
        );
    }
}
