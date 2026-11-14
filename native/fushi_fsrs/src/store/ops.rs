//! 内核命令（`ffsrs_store_sync2` 的 `op`，store/ffi.rs `sync2_dispatch`）的元数据：**唯一声明处**。
//!
//! 每条命令一行：它针对不针对单个 profile、收段通道没做完时要不要先做完、改不改投影、是不是本机写命令、要不要缓存
//! 配置、是不是浏览会话命令，以及宿主（Dart `SrsDbStore`）发它时进不进本副本的独占区、走哪条 worker 道。分发器按这
//! 张表分流（[spec]）；Dart 侧不手抄任何一项，用的是由这张表生成的类型化绑定
//! `packages/fushi_srs/lib/src/ffi/srs_ops.g.dart`（`SrsOp`；`tests::dart_bindings_are_current`：生成物与表不一致
//! 就红；重新生成：在 native/fushi_fsrs 下 `FUSHI_SRS_WRITE_OPS=1 cargo test --profile quick --lib store::ops`）。
//!
//! 新增命令必须登记在这里（store/ffi.rs `every_command_has_a_spec` 按分发器的匹配臂逐条核对），并显式写出收段通道
//! 策略（[op] 的第二个参数）：新增命令时必须想一遍它要不要完整投影，不会悄悄落进默认。
//!
//! 各项的判据：
//! - **收段通道**（[Channel]）：新设备收段通道（store/sync2/channel.rs）没做完时，投影里还缺已收下的操作。
//!   [Channel::Transparent]：收段命令本身（推进通道）、只读命令（读到的投影与逐条投递收段途中一样不全，收尾后一致），
//!   以及不碰投影的传输记账 / 加解密。其余 [Channel::Settles] 先把通道按片做完——标错成 Settles 只多花时间，不会错。
//!   `digest` / `digest_buckets` 是 Settles：摘要按已应用的版本向量发布，投影不全时算出来的会被别的设备当成分歧（没有
//!   通道时它们照样只走读连接：分发器只读内存标记，见 `SrsCore::sync2_channel_settle`）。
//! - **改投影**（[OpSpec::projecting]，结果带 `marks`）：分发器在同一次调用里刷新缓存行、推进刷新键（store/refresh.rs）；
//!   `ingest_commit` 在投递的事务里自己刷（只刷本机已有缓存行的，新实体记待刷新）。宿主只能在本副本的独占区里发（回包
//!   要按顺序接进副本的内存）。
//! - **本机写命令**（[OpSpec::local_write]）：分发器取**一次**写锁，在**一个** SAVEPOINT 里依次做完命令本体、缓存刷新、
//!   请求带 `study` 时的排队，以及本机状态行（store/ffi.rs `local_write`）。
//! - **缓存配置**（[OpSpec::caches]）：命令会刷新 / 读本机缓存行，要内置笔记类型的代码默认值与默认牌组（只有宿主知道）。
//!   请求不带 `caches` 时用打开副本时注册的那份（`cache_config_set`）；宿主照这一项随命令带上。
//! - **浏览会话命令**（[OpSpec::browse]）：store/browse.rs 的常驻浏览会话，只读（读快照；写连接上有事务时在它的
//!   SAVEPOINT 里读）。宿主的浏览入口只放行这一组，远程复习原样转给已配对设备调用的也只有这一组——放任意命令进来等于
//!   把 `seal_file` / `open_file`（按请求给的路径读写文件）与改库命令都开放了。
//! - **宿主独占区**（[HostLock]）：同步 v2 的命令与写事务互斥（内核与本机写入共用一条连接，不排队的话 `outbox` /
//!   `head` / `plan` 会读到另一笔还没提交的写事务里的操作——那笔回滚后同一个 seq 被重用、head 的代号回退，已经发出去的
//!   段与 head 让对端判本机分叉）。[HostLock::Free] 的判据：结果不依赖写连接上还没提交的行，也不在别的写入的中途改
//!   本机状态——纯计算（`derive_key` / `seal` / `open`；`seal_file` / `open_file` 只读写调用方给的路径），以及只走读连接
//!   （WAL 快照，只见已提交的行）的命令；`digest` 只在末尾往写连接记一行摘要缓存，恰好落进另一笔写事务而那笔回滚，丢的
//!   只是这行缓存。读写连接上未提交行的命令（浏览会话、`study`、`preview`）不算。
//! - **worker 道**（[Lane]）：复习页的作答 / 排队 / 预览、本机手动排程与编辑类撤销的裁决（`undo_check`，只读、紧接着写回）走交互道，不排在同步的成批命令与媒体文件加解密
//!   后面；媒体文件的流式加解密 / 哈希走文件道；内核读命令走查询道（只读连接池上并发）；其余走默认道。

/// 收段通道没做完时这条命令要不要先做完它（见模块说明）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Channel {
    Transparent,
    Settles,
}

/// 宿主发这条命令时进不进本副本的独占区（见模块说明）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HostLock {
    /// 进独占区（默认）。
    Exclusive,
    /// 不进。
    Free,
    /// 先带 `readOnly: true` 在读连接上算；回包 `needsWrite` 才进独占区再发一次（`plan`：空轮 head 都没变，什么都不用记）。
    ReadFirst,
}

/// 宿主的哪条 worker 道（Dart `SrsCoreLane`，见模块说明）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Lane {
    Interactive,
    Bulk,
    File,
    Query,
}

/// 一条命令的元数据（见模块说明）。
#[derive(Clone, Copy, Debug)]
pub(crate) struct OpSpec {
    pub name: &'static str,
    /// 不针对单个 profile（请求不带 `profile`；分发器开头就返回，不碰收段通道）。
    pub global: bool,
    pub channel: Channel,
    pub projecting: bool,
    pub local_write: bool,
    pub caches: bool,
    pub browse: bool,
    pub lock: HostLock,
    pub lane: Lane,
}

const fn op(name: &'static str, channel: Channel) -> OpSpec {
    OpSpec {
        name,
        global: false,
        channel,
        projecting: false,
        local_write: false,
        caches: false,
        browse: false,
        lock: HostLock::Exclusive,
        lane: Lane::Bulk,
    }
}

const fn global(name: &'static str) -> OpSpec {
    OpSpec {
        global: true,
        ..op(name, Channel::Transparent)
    }
}

impl OpSpec {
    const fn projecting(self) -> Self {
        OpSpec {
            projecting: true,
            ..self
        }
    }
    const fn local_write(self) -> Self {
        OpSpec {
            local_write: true,
            ..self
        }
    }
    const fn caches(self) -> Self {
        OpSpec {
            caches: true,
            ..self
        }
    }
    const fn browse(self) -> Self {
        OpSpec {
            browse: true,
            ..self
        }
    }
    const fn lock_free(self) -> Self {
        OpSpec {
            lock: HostLock::Free,
            ..self
        }
    }
    const fn read_first(self) -> Self {
        OpSpec {
            lock: HostLock::ReadFirst,
            ..self
        }
    }
    const fn lane(self, lane: Lane) -> Self {
        OpSpec { lane, ..self }
    }
}

use Channel::{Settles, Transparent};

/// 全部命令（顺序即生成的 Dart 枚举的顺序）。
pub(crate) const OPS: &[OpSpec] = &[
    // ---- 不针对单个 profile 的命令（分发器开头就返回，不碰收段通道）
    global("profile_uids"),
    global("read_lib").lock_free().lane(Lane::Query),
    global("orphan_sweep_done"),
    global("profile_merge_mark"),
    global("profile_merge_commit"),
    global("meta_set_edit"),
    global("wal_checkpoint"),
    global("bulk_cache"),
    global("ingest_yield"),
    global("refresh_keys"),
    // ---- 收段通道没做完时不必先做完的命令（收段本身、只读、不碰投影的传输记账 / 加解密）
    op("identity", Transparent),
    op("device_info", Transparent),
    op("device_hint", Transparent),
    op("location_sealed", Transparent),
    op("location_seal", Transparent),
    op("channel_settle", Transparent),
    op("open_v1", Transparent),
    op("plan", Transparent).read_first(),
    op("ingest_begin", Transparent),
    op("ingest_batch", Transparent).projecting().caches(),
    op("ingest_prepare", Transparent),
    op("ingest_commit", Transparent).projecting().caches(),
    op("ingest_finish", Transparent).projecting().caches(),
    op("ingest_end", Transparent),
    op("replay_pending", Transparent).projecting().caches(),
    op("status", Transparent).lock_free(),
    op("legacy_dots", Transparent),
    op("conflicts", Transparent).lock_free(),
    op("checkpoints", Transparent).lock_free(),
    op("history", Transparent).lock_free(),
    op("study", Transparent).lane(Lane::Interactive),
    op("read", Transparent).lock_free().lane(Lane::Query),
    op("card_columns", Transparent),
    op("stats_report", Transparent),
    op("stats_recall", Transparent),
    op("stats_rows", Transparent),
    op("stats_release", Transparent),
    op("anki_resolve", Transparent),
    op("anki_notes_info", Transparent),
    op("lineages", Transparent),
    op("preview", Transparent).lane(Lane::Interactive),
    op("browse_query", Transparent).browse(),
    op("browse_rows", Transparent).browse(),
    op("browse_ids", Transparent).browse(),
    op("browse_targets", Transparent).browse(),
    op("browse_close", Transparent).browse(),
    op("anki_find", Transparent).browse(),
    op("anki_dupes", Transparent).browse(),
    op("anki_tags", Transparent).browse(),
    op("browse_stats", Transparent).browse(),
    op("browse_counts", Transparent).browse(),
    op("browse_sources", Transparent).browse(),
    op("outbox", Transparent),
    op("outbox_ack", Transparent),
    op("head", Transparent),
    op("relay_outbox", Transparent),
    op("obsolete", Transparent),
    op("obsolete_former", Transparent),
    op("obsolete_ack", Transparent),
    op("relay_ack", Transparent),
    op("media_known", Transparent).lock_free(),
    op("media_gc_queue", Transparent),
    op("media_live_refs", Transparent).caches(),
    op("local_state", Transparent),
    op("local_state_ensure", Transparent),
    op("local_anchor", Transparent),
    op("profile_footprint", Transparent),
    op("profile_purge", Transparent),
    op("binding_get", Transparent),
    op("binding_set", Transparent),
    op("derive_key", Transparent).lock_free(),
    op("seal", Transparent).lock_free(),
    op("open", Transparent).lock_free(),
    op("seal_file", Transparent).lock_free().lane(Lane::File),
    op("open_file", Transparent).lock_free().lane(Lane::File),
    op("refresh_caches", Transparent).caches(),
    op("rebuild_caches", Transparent).caches(),
    op("cache_config_set", Transparent).caches(),
    // ---- 收段通道没做完时要先做完的命令（改投影、读完整投影、在投影上记账的）
    op("apply", Settles)
        .projecting()
        .local_write()
        .caches()
        .lane(Lane::Interactive),
    op("import_drafts", Settles)
        .projecting()
        .local_write()
        .caches(),
    op("change", Settles).projecting().local_write().caches(),
    op("note_fields_if", Settles)
        .projecting()
        .local_write()
        .caches(),
    op("merge_notes", Settles)
        .projecting()
        .local_write()
        .caches(),
    op("sched", Settles)
        .projecting()
        .local_write()
        .caches()
        .lane(Lane::Interactive),
    op("deck_delete", Settles)
        .projecting()
        .local_write()
        .caches(),
    op("undo_check", Settles).lane(Lane::Interactive),
    op("retire", Settles).projecting().local_write().caches(),
    op("dedup", Settles).projecting().local_write().caches(),
    op("migrate", Settles),
    op("replay_all", Settles),
    op("ingest", Settles).projecting().caches(),
    op("rotate", Settles),
    op("export", Settles),
    op("import", Settles).projecting().local_write().caches(),
    op("digest", Settles).lock_free(),
    op("digest_buckets", Settles).lock_free(),
    op("digest_heal", Settles)
        .projecting()
        .local_write()
        .caches(),
    op("media_record", Settles),
    op("media_hash", Settles).lock_free().lane(Lane::File),
    op("media_scan", Settles),
    op("media_landed", Settles),
    op("media_bind_unbound", Settles),
    op("media_doomed", Settles),
    op("resolve", Settles).projecting().local_write().caches(),
    op("trust", Settles).projecting().local_write().caches(),
    op("purge", Settles).projecting().local_write().caches(),
    op("checkpoint", Settles)
        .projecting()
        .local_write()
        .caches(),
    op("plan_restore", Settles),
    op("restore", Settles).projecting().local_write().caches(),
    op("backfill_dupe_norms", Settles).caches(),
    op("backfill_tag_sources", Settles),
    op("backfill_source_keys", Settles),
    op("edits_rewrite_repr", Settles).caches(),
    op("media_gc_collect", Settles).caches(),
];

/// [name] 的元数据；不是命令 = None。
pub(crate) fn spec(name: &str) -> Option<&'static OpSpec> {
    OPS.iter().find(|s| s.name == name)
}

/// 收段通道没做完时 [name] 不必先做完它。不认识的命令按要先做完算（分发器随后报不认识）。
pub(crate) fn channel_transparent(name: &str) -> bool {
    spec(name).is_some_and(|s| s.channel == Channel::Transparent)
}

/// [name] 改投影（[OpSpec::projecting]）。
pub(crate) fn projecting(name: &str) -> bool {
    spec(name).is_some_and(|s| s.projecting)
}

/// [name] 是本机写命令（[OpSpec::local_write]）。
pub(crate) fn local_write(name: &str) -> bool {
    spec(name).is_some_and(|s| s.local_write)
}

/// 由 [OPS] 生成的 Dart 绑定（`packages/fushi_srs/lib/src/ffi/srs_ops.g.dart`）全文。
#[cfg(test)]
fn render_dart() -> String {
    use std::fmt::Write;
    fn camel(wire: &str) -> String {
        let mut out = String::with_capacity(wire.len());
        let mut up = false;
        for ch in wire.chars() {
            if ch == '_' {
                up = true;
            } else if up {
                out.extend(ch.to_uppercase());
                up = false;
            } else {
                out.push(ch);
            }
        }
        out
    }
    let mut s = String::new();
    s.push_str(DART_HEAD);
    for o in OPS {
        let mut args = vec![format!("'{}'", o.name)];
        if o.global {
            args.push("global: true".into());
        }
        if o.channel == Channel::Settles {
            args.push("settlesChannel: true".into());
        }
        if o.projecting {
            args.push("projecting: true".into());
        }
        if o.caches {
            args.push("caches: true".into());
        }
        if o.browse {
            args.push("browse: true".into());
        }
        match o.lock {
            HostLock::Exclusive => {}
            HostLock::Free => args.push("lock: SrsOpLock.free".into()),
            HostLock::ReadFirst => args.push("lock: SrsOpLock.readFirst".into()),
        }
        match o.lane {
            Lane::Bulk => {}
            Lane::Interactive => args.push("lane: SrsOpLane.interactive".into()),
            Lane::File => args.push("lane: SrsOpLane.file".into()),
            Lane::Query => args.push("lane: SrsOpLane.query".into()),
        }
        writeln!(s, "  {}({}),", camel(o.name), args.join(", ")).unwrap();
    }
    // 最后一项的逗号换成分号（枚举值列表到此为止）。
    s.truncate(s.len() - 2);
    s.push_str(";\n");
    s.push_str(DART_TAIL);
    s
}

#[cfg(test)]
const DART_HEAD: &str = "// GENERATED FILE - DO NOT EDIT.
// 由 native/fushi_fsrs/src/store/ops.rs 的命令表生成（判据与各项含义见那个文件的模块说明）。重新生成：在
// native/fushi_fsrs 下 `FUSHI_SRS_WRITE_OPS=1 cargo test --profile quick --lib store::ops`；不重新生成时那条测试
// 比对本文件，不一致就红。
//
// 内核命令（`SrsCore.sync2` / `ffsrs_store_sync2` 的 `op`）与它们的元数据：宿主进不进独占区、走哪条 worker 道、
// 改不改投影、要不要缓存配置、是不是浏览会话命令。Dart 侧不另抄任何一项。

/// 宿主发这条命令时进不进本副本的独占区（`SrsDbStore.sync2Command`）。
enum SrsOpLock {
  /// 进独占区。
  exclusive,

  /// 不进：纯计算，或只读已提交快照（结果不依赖写连接上还没提交的行，也不在别的写入的中途改本机状态）。
  free,

  /// 先带 `readOnly: true` 不进独占区发一次；回包 `needsWrite` 才进独占区再发（`plan`）。
  readFirst,
}

/// 走宿主内核 worker 池的哪条道（`SrsCoreLane`）。
enum SrsOpLane {
  /// 复习页的作答 / 排队 / 预览与本机手动排程：短、用户在等。
  interactive,

  /// 其余。
  bulk,

  /// 媒体文件的流式加解密与哈希。
  file,

  /// 内核读命令（只读连接池上并发）。
  query,
}

/// 一条内核命令。[wire] 是请求里的 `op`。
enum SrsOp {
";

#[cfg(test)]
const DART_TAIL: &str = "
  const SrsOp(
    this.wire, {
    this.global = false,
    this.settlesChannel = false,
    this.projecting = false,
    this.caches = false,
    this.browse = false,
    this.lock = SrsOpLock.exclusive,
    this.lane = SrsOpLane.bulk,
  });

  /// 请求里的 `op`。
  final String wire;

  /// 不针对单个 profile（请求不带 `profile`）。
  final bool global;

  /// 新设备收段通道没做完时，内核先把它做完再执行这条命令。
  final bool settlesChannel;

  /// 改投影（回包带 `marks`）：只能在本副本的独占区里发，回包要按顺序接进副本的内存。
  final bool projecting;

  /// 要缓存配置（请求带 `caches`）。
  final bool caches;

  /// 浏览会话命令（只读）：浏览入口与远程复习只放行这一组。
  final bool browse;

  /// 宿主进不进独占区。
  final SrsOpLock lock;

  /// 走哪条 worker 道。
  final SrsOpLane lane;

  /// [wire] 对应的命令；不是内核命令 = null。
  static SrsOp? byWire(Object? wire) => _byWire[wire];

  static final Map<Object?, SrsOp> _byWire = <Object?, SrsOp>{
    for (final SrsOp o in values) o.wire: o,
  };
}
";

#[cfg(test)]
mod tests {
    use super::*;

    /// 生成的 Dart 绑定与 [OPS] 一致（设了 `FUSHI_SRS_WRITE_OPS` 就重新生成）。
    #[test]
    fn dart_bindings_are_current() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../packages/fushi_srs/lib/src/ffi/srs_ops.g.dart"
        );
        let want = render_dart();
        if std::env::var_os("FUSHI_SRS_WRITE_OPS").is_some() {
            std::fs::write(path, &want).unwrap();
            return;
        }
        let have = std::fs::read_to_string(path)
            .unwrap_or_default()
            .replace("\r\n", "\n");
        assert!(
            have == want,
            "{path} is stale: run `FUSHI_SRS_WRITE_OPS=1 cargo test --profile quick --lib store::ops` in native/fushi_fsrs"
        );
    }

    /// 名字唯一；各项之间的蕴含关系。
    #[test]
    fn specs_are_consistent() {
        let mut names = std::collections::BTreeSet::new();
        for o in OPS {
            assert!(names.insert(o.name), "`{}` is listed twice", o.name);
            if o.local_write {
                assert!(o.projecting, "local write `{}` must be projecting", o.name);
            }
            if o.projecting {
                // 改投影的命令刷新缓存行，回包要在独占区里按顺序接进副本的内存。
                assert!(
                    o.caches,
                    "projecting `{}` must take the cache config",
                    o.name
                );
                assert_eq!(o.lock, HostLock::Exclusive, "projecting `{}`", o.name);
                assert!(!o.global && !o.browse, "projecting `{}`", o.name);
            }
            if o.browse || o.global {
                assert_eq!(o.channel, Channel::Transparent, "`{}`", o.name);
            }
        }
        assert!(spec("apply").is_some_and(|s| s.local_write && s.lane == Lane::Interactive));
        assert!(spec("no_such_op").is_none());
        assert!(!channel_transparent("no_such_op"));
    }
}
