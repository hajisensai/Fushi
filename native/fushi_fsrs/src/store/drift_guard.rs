//! Drift 事务守卫（收掉 Dart 写路径的第 1 步，docs 见 PR 正文）：Drift 在写连接上开着跨命令事务（[SrsCore] `drift_tx`）
//! 时来的每条 sync2 命令，按登记的策略分三类计数：
//!
//! - **Join**：写命令，今天就是有意在 Drift 事务里跑的（Dart 用 `BEGIN` 把它和本机状态行包成一笔，或多步领域事务里的
//!   一步）——它的写入随那笔事务提交 / 回滚。后面的步骤把这些调用方一个个改成「一条内核命令自己一笔事务」，这个集合
//!   随之缩小，最后清空。
//! - **ReadVisible**：允许，且不往那笔事务里写东西：只读命令（在写连接的 SAVEPOINT 里读，看得见未提交的行，
//!   [SrsCore::read_visible_tx]，设计行为）；不碰写连接的命令（纯计算、只置标志、另开连接的 WAL 并回）。
//!   `digest` / `digest_buckets` / `media_hash` / `plan_restore` 也在这里：Dart 不排写锁就发（`kSrsSync2LockFreeOps` /
//!   `sync2PlanRestore`），可能恰好撞上别人开着的 Drift 事务；它们顺带的写入只有收段通道的进度（通道没做完时分发器先
//!   收通道）与 `digest` 的一行摘要缓存，随那笔事务回滚也只丢可重做的进度，通道标记只在写连接空闲时清
//!   （store/sync2/channel.rs `recheck_channel_live`）。
//! - **Reject**：不该在别人的 Drift 事务里跑的命令：传输记账、收段、身份、媒体记账、迁移……它们的写入被那笔事务一起
//!   回滚就错了（例如 `export` / `outbox` 会把之后可能回滚的操作发出去）。
//!
//! **首版只计数、只打日志，不报错**：Reject 命中写一行 stderr（每条命令按 1、2、4、8… 次打，不刷屏）；环境变量
//! `FUSHI_SRS_DRIFT_TX_TRACE` 非空时每次命中都打（量整套测试的命中分布用）。计数经不针对 profile 的命令
//! `drift_tx_guard` 读出（`reset: true` 读完清零），测试据此验收「Join 集合缩小了」。
//!
//! 只看 `drift_tx`，不看旧库搬迁的 `legacy_open`（[SrsCore::writer_tx_open] 把两者合在一起）：搬迁事务开着时别的写命令
//! 本来就被拒绝。`drift_tx` 在写锁外读：不排写锁的命令读到的是那一刻 Drift 以为的事务状态，正是它们会不会落进那笔
//! 事务的判据。

use super::SrsCore;
use std::collections::BTreeMap;
use std::sync::Mutex;
use std::sync::OnceLock;
use std::sync::atomic::Ordering;

/// 一条 sync2 命令在 Drift 事务开着时的策略（见模块文档）。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum DriftTxPolicy {
    Join,
    ReadVisible,
    Reject,
}

impl DriftTxPolicy {
    /// `drift_tx_guard` 回包里的键。
    fn key(self) -> &'static str {
        match self {
            Self::Join => "join",
            Self::ReadVisible => "readVisible",
            Self::Reject => "reject",
        }
    }
}

use DriftTxPolicy::{Join, ReadVisible, Reject};

/// 每条 sync2 命令（含不针对 profile 的前置命令）恰好登记一次：`every_command_declares_its_drift_tx_policy`
/// （store/ffi.rs）按分发器的匹配臂逐条核对，新增命令没登记就红。不在表里的命令按 Reject 计（分发器随后也会报
/// 「unknown sync2 op」）。
pub(crate) const DRIFT_TX_POLICY: &[(&str, DriftTxPolicy)] = &[
    // ---- Join：今天有意在 Drift 事务里跑的写命令（调用方见 PR 盘点 wp_inventory）。
    // `_emit` → `_transactionOrReload`（本机写入、导入、Lapis 迁移的外层事务里的每一步）。
    ("apply", Join),
    // `_schedLocal` → `_transactionOrReload`。
    ("sched", Join),
    // `sync2ImportOps` → `_transactionOrReload`。
    ("import", Join),
    // `_sync2Write` → `_transactionOrReload`。
    ("resolve", Join),
    ("purge", Join),
    ("checkpoint", Join),
    ("restore", Join),
    ("retire", Join),
    ("dedup", Join),
    ("trust", Join),
    // 缓存维护的 Drift 事务（`_upgradeCaches` / `rebuildCaches` / `compactStoredStyles`）与上面各事务里的刷新。
    ("refresh_caches", Join),
    ("rebuild_caches", Join),
    ("backfill_dupe_norms", Join),
    ("backfill_tag_sources", Join),
    ("backfill_source_keys", Join),
    // profile 并入的核对 + 删除在一笔 Drift 事务里（srs_profile_merge.dart）。
    ("profile_purge", Join),
    // ---- ReadVisible：只读，或不碰写连接上的事务。
    ("profile_uids", ReadVisible),
    ("wal_checkpoint", ReadVisible),
    ("bulk_cache", ReadVisible),
    ("ingest_yield", ReadVisible),
    ("drift_tx_guard", ReadVisible),
    ("study", ReadVisible),
    ("card_columns", ReadVisible),
    ("stats_bundle", ReadVisible),
    ("anki_resolve", ReadVisible),
    ("anki_notes_info", ReadVisible),
    ("browse_query", ReadVisible),
    ("browse_rows", ReadVisible),
    ("browse_ids", ReadVisible),
    ("browse_targets", ReadVisible),
    ("browse_close", ReadVisible),
    ("browse_stats", ReadVisible),
    ("browse_counts", ReadVisible),
    ("browse_sources", ReadVisible),
    ("anki_find", ReadVisible),
    ("anki_dupes", ReadVisible),
    ("anki_tags", ReadVisible),
    ("lineages", ReadVisible),
    ("preview", ReadVisible),
    ("status", ReadVisible),
    ("legacy_dots", ReadVisible),
    ("conflicts", ReadVisible),
    ("checkpoints", ReadVisible),
    ("history", ReadVisible),
    ("location_sealed", ReadVisible),
    ("media_known", ReadVisible),
    ("profile_footprint", ReadVisible),
    // 集合绑定状态（store/binding.rs）：只读一行 `srs_meta`。
    ("binding_get", ReadVisible),
    ("ingest_prepare", ReadVisible),
    ("derive_key", ReadVisible),
    ("seal", ReadVisible),
    ("open", ReadVisible),
    ("open_v1", ReadVisible),
    ("seal_file", ReadVisible),
    ("open_file", ReadVisible),
    // Dart 不排写锁、可能顺带收通道 / 记摘要缓存的（见模块文档）。
    ("digest", ReadVisible),
    ("digest_buckets", ReadVisible),
    ("media_hash", ReadVisible),
    ("plan_restore", ReadVisible),
    // ---- Reject：不该落进别人的 Drift 事务。`plan` 只有 `readOnly` 那一路是读（[policy_of]）。
    ("plan", Reject),
    ("identity", Reject),
    // 集合绑定状态只进不退（store/binding.rs）：与 `identity` 同属身份记账，随别人的 Drift 事务回滚就把「已定下」退回去了；
    // 调用方（srs_db_store.dart `setCollectionBinding`）走排队的 `sync2Command`，不开 Drift 事务。
    ("binding_set", Reject),
    ("channel_settle", Reject),
    ("migrate", Reject),
    ("replay_all", Reject),
    ("export", Reject),
    ("outbox", Reject),
    ("outbox_ack", Reject),
    ("head", Reject),
    ("relay_outbox", Reject),
    // 一轮收尾问「位置上此刻该删什么」（transport.rs `sync2_obsolete`）：登记待删的旧 head，与 `obsolete_ack` 同属传输记账。
    ("obsolete", Reject),
    ("obsolete_ack", Reject),
    ("relay_ack", Reject),
    ("ingest", Reject),
    ("ingest_begin", Reject),
    ("ingest_batch", Reject),
    ("ingest_commit", Reject),
    ("ingest_finish", Reject),
    ("ingest_end", Reject),
    ("replay_pending", Reject),
    ("rotate", Reject),
    ("device_info", Reject),
    ("device_hint", Reject),
    ("location_seal", Reject),
    ("media_record", Reject),
    ("media_scan", Reject),
    ("media_landed", Reject),
    ("media_bind_unbound", Reject),
    ("media_doomed", Reject),
    ("orphan_sweep_done", Reject),
];

/// [op] 的策略；`plan` 带 `readOnly: true` 时只在读连接上算（store/ffi.rs），按 ReadVisible。
pub(crate) fn policy_of(op: &str, req: &serde_json::Value) -> DriftTxPolicy {
    if op == "plan" && req.get("readOnly") == Some(&serde_json::Value::Bool(true)) {
        return ReadVisible;
    }
    DRIFT_TX_POLICY
        .iter()
        .find(|(o, _)| *o == op)
        .map_or(Reject, |(_, p)| *p)
}

/// 每个库一份的命中计数：`(策略, 命令) → 次数`。
#[derive(Default)]
pub(crate) struct DriftTxHits(Mutex<BTreeMap<(DriftTxPolicy, String), u64>>);

impl DriftTxHits {
    /// 记一次命中，返回这条命令在这个策略下累计的次数。
    fn note(&self, policy: DriftTxPolicy, op: &str) -> u64 {
        // 只是计数：panic 毒化过照常用。
        let mut m = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let n = m.entry((policy, op.to_owned())).or_insert(0);
        *n += 1;
        *n
    }

    /// `{"join": {op: n}, "readVisible": {...}, "reject": {...}}`；[reset] 读完清零。
    fn snapshot(&self, reset: bool) -> serde_json::Value {
        let mut m = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let mut out = serde_json::Map::new();
        for p in [Join, ReadVisible, Reject] {
            out.insert(p.key().to_owned(), serde_json::json!({}));
        }
        for ((p, op), n) in m.iter() {
            out[p.key()][op] = serde_json::json!(n);
        }
        if reset {
            m.clear();
        }
        serde_json::Value::Object(out)
    }
}

/// `FUSHI_SRS_DRIFT_TX_TRACE` 非空：每次命中都打一行（量整套测试的命中分布）。
fn trace_all() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("FUSHI_SRS_DRIFT_TX_TRACE").is_some_and(|v| !v.is_empty()))
}

impl SrsCore {
    /// 分发器入口调：Drift 事务开着时按 [op] 的策略记一次命中（不改变命令的行为）。
    pub(crate) fn note_drift_tx(&self, op: &str, req: &serde_json::Value) {
        if !self.drift_tx.load(Ordering::SeqCst) {
            return;
        }
        let policy = policy_of(op, req);
        let n = self.drift_tx_hits.note(policy, op);
        if trace_all() || (policy == Reject && n.is_power_of_two()) {
            eprintln!(
                "srs drift_tx guard: {} `{op}` while a Drift transaction is open (hit {n})",
                policy.key()
            );
        }
    }

    /// `drift_tx_guard` 命令：本库的命中计数（见 [DriftTxHits::snapshot]）。
    pub(crate) fn drift_tx_guard(&self, reset: bool) -> serde_json::Value {
        self.drift_tx_hits.snapshot(reset)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_policy_entry_is_unique() {
        let mut seen = std::collections::BTreeSet::new();
        for (op, _) in DRIFT_TX_POLICY {
            assert!(
                seen.insert(*op),
                "`{op}` is listed twice in DRIFT_TX_POLICY"
            );
        }
    }

    #[test]
    fn plan_read_only_is_read_visible() {
        assert_eq!(
            policy_of("plan", &serde_json::json!({"readOnly": true})),
            ReadVisible
        );
        assert_eq!(policy_of("plan", &serde_json::json!({})), Reject);
        assert_eq!(policy_of("no_such_op", &serde_json::json!({})), Reject);
    }

    /// 计数只在 Drift 事务开着时记；只读命令、Join、Reject 各自归类；`reset` 清零。
    #[test]
    fn counts_only_while_a_drift_transaction_is_open() {
        let dir = std::env::temp_dir().join(format!(
            "srs_drift_guard_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let core = SrsCore::open(&dir.join("srs.db")).unwrap();
        let req = serde_json::json!({});
        core.note_drift_tx("apply", &req);
        assert_eq!(
            core.drift_tx_guard(false),
            serde_json::json!({"join": {}, "readVisible": {}, "reject": {}})
        );
        core.exec("BEGIN", &[], false).unwrap();
        core.note_drift_tx("apply", &req);
        core.note_drift_tx("apply", &req);
        core.note_drift_tx("status", &req);
        core.note_drift_tx("outbox", &req);
        core.note_drift_tx("plan", &serde_json::json!({"readOnly": true}));
        core.exec("COMMIT", &[], false).unwrap();
        core.note_drift_tx("outbox", &req);
        assert_eq!(
            core.drift_tx_guard(true),
            serde_json::json!({
                "join": {"apply": 2},
                "readVisible": {"status": 1, "plan": 1},
                "reject": {"outbox": 1},
            })
        );
        assert_eq!(
            core.drift_tx_guard(false),
            serde_json::json!({"join": {}, "readVisible": {}, "reject": {}})
        );
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
