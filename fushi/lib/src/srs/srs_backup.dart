/// 复习自动备份的 app 侧装配（设计见 docs/specs/2026-10-17-srs-auto-backup-restore.md）。
///
/// - [srsBackupStoreProvider]：当前 profile 的本机备份库（`<documents>/srs_backups/<profileUid>/`）。
/// - [SrsBackupController]：自动备份的触发与串行化、立即备份、恢复（恢复前先存一份当前状态）。
///   触发点由 `SrsAppRuntime` 接：库有变动（[srsRevisionProvider]）→ 满间隔就备份，不满就定时到点再看；
///   离开复习页 → 有变动就立即备份。没有变动（库指纹与最近一份相同）一律不备份。
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_merge.dart';
import 'package:fushi_engine/srs/srs_backup_retention.dart';
import 'package:fushi_engine/srs/srs_backup_store.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_point_in_time_restore.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 复习备份根（`<documents>/srs_backups`，[AppPaths.srsBackupsDirectory]；测试覆写成临时目录）。
final Provider<Future<Directory> Function()> srsBackupsRootProvider =
    Provider<Future<Directory> Function()>(
      (Ref ref) => AppPaths.srsBackupsDirectory,
    );

/// 当前 profile 的本机复习备份库；模块关着时为 null。
///
/// 打开时把旧位置（`<支持目录>/srs_backups`，第一版放在那里，iOS「文件」里看不到、卸载即删）
/// 的备份整体搬到新位置；搬不动（权限、空间）只记日志、照常用新位置，旧文件原样留着下次再搬。
final FutureProvider<SrsBackupStore?> srsBackupStoreProvider =
    FutureProvider<SrsBackupStore?>((Ref ref) async {
      final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
      if (store == null) return null;
      final Directory support = await ref.watch(srsSupportRootProvider)();
      final Directory root = await ref.watch(srsBackupsRootProvider)();
      try {
        await srsRelocateBackupRoot(
          from: SrsBackupStore.rootFor(support),
          to: root,
        );
      } catch (e, stack) {
        ErrorLogService.instance.log('srsRelocateBackupRoot', e, stack);
      }
      return SrsBackupStore(
        root: root,
        profileUid: store.profileUid,
        mediaDir: SrsMediaStore.directoryFor(support, store.profileUid),
      );
    });

/// 进程内唯一的备份控制器（读当前 store / 备份库，不绑定某个 profile）。
final Provider<SrsBackupController> srsBackupControllerProvider =
    Provider<SrsBackupController>((Ref ref) {
      final AppModel app = ref.read(appProvider);
      final SrsBackupController c = SrsBackupController(
        readStore: () => ref.read(srsStoreProvider.future),
        readBackups: () => ref.read(srsBackupStoreProvider.future),
        autoEnabled: () => app.srsBackupAuto,
        limits: () => app.srsBackupLimits,
        profileName: (String uid) => _profileNameOf(app.database, uid),
      );
      ref.onDispose(c.dispose);
      return c;
    });

Future<String> _profileNameOf(FushiDatabase db, String uid) async {
  final QueryRow? r = await db
      .customSelect(
        'SELECT name FROM profiles WHERE uid = ?',
        variables: <Variable<Object>>[Variable<String>(uid)],
      )
      .getSingleOrNull();
  return r?.read<String>('name') ?? '';
}

/// 备份属于本机另一个 profile：请切到那个 profile 再恢复。
class SrsRestoreOtherLocalProfile implements Exception {
  const SrsRestoreOtherLocalProfile(this.profileName);

  final String profileName;

  @override
  String toString() => 'SrsRestoreOtherLocalProfile($profileName)';
}

/// 一次恢复的结果。
class SrsBackupRestoreOutcome {
  const SrsBackupRestoreOutcome({required this.report, this.snapshot});

  final SrsRestoreReport report;

  /// 恢复前自动存的当前状态（新装设备接上别人的 profile 时没有可存的，为 null）。
  final SrsBackupInfo? snapshot;
}

/// 自动备份与恢复。所有备份 / 恢复操作串行（同一时刻只跑一个），防止自动备份与恢复交叉。
class SrsBackupController {
  SrsBackupController({
    required Future<SrsDbStore?> Function() readStore,
    required Future<SrsBackupStore?> Function() readBackups,
    required bool Function() autoEnabled,
    required SrsBackupLimits Function() limits,
    required Future<String> Function(String profileUid) profileName,
    int Function()? nowMs,
  }) : _readStore = readStore,
       _readBackups = readBackups,
       _autoEnabled = autoEnabled,
       _limits = limits,
       _profileName = profileName,
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Future<SrsDbStore?> Function() _readStore;
  final Future<SrsBackupStore?> Function() _readBackups;
  final bool Function() _autoEnabled;
  final SrsBackupLimits Function() _limits;
  final Future<String> Function(String profileUid) _profileName;
  final int Function() _now;

  Future<void> _tail = Future<void>.value();
  Timer? _timer;

  /// 每个 profile 最近一份备份的创建时刻（null = 一份都没有）。评分等高频写入触发 [onDataChanged]
  /// 时只看它，不每次列目录；新建 / 删除 / 恢复后更新或作废。
  final Map<String, int?> _latestAt = <String, int?>{};

  Future<int?> _latestCreatedAt(SrsBackupStore backups) async {
    if (_latestAt.containsKey(backups.profileUid)) {
      return _latestAt[backups.profileUid];
    }
    final List<SrsBackupInfo> all = await backups.list();
    return _latestAt[backups.profileUid] = all.isEmpty
        ? null
        : all.first.manifest.createdAt;
  }

  bool _disposed = false;

  /// 备份列表变了（新建 / 清理 / 删除 / 恢复）。备份页据此重读。
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// 把 [body] 排进串行队列。
  Future<T> _serial<T>(Future<T> Function() body) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await body());
      } catch (e, stack) {
        done.completeError(e, stack);
      }
    });
    return done.future;
  }

  void _notify() {
    if (!_disposed) changes.value++;
  }

  /// 自动备份：开着、有变动，且（[leavingReview] 或距最近一份已满间隔）才备份。返回新备份；没备份为 null。
  Future<SrsBackupInfo?> autoBackup({bool leavingReview = false}) =>
      _serial(() async {
        // SRS 界面在用时不做自动备份：读快照的事务会把复习页的查询挡上二三十秒（BUG-3579），
        // SRS 界面不再被使用时 [onSrsIdle] 再补。
        if (_disposed || !_autoEnabled() || _reviewing) return null;
        final SrsDbStore? store = await _readStore();
        final SrsBackupStore? backups = await _readBackups();
        if (store == null || backups == null) return null;
        if (!await store.hasUserNotes()) return null;
        final List<SrsBackupInfo> all = await backups.list();
        final SrsBackupInfo? latest = all.isEmpty ? null : all.first;
        final SrsBackupLimits limits = _limits();
        if (!srsShouldAutoBackup(
          currentFingerprint: await store.changeFingerprint(),
          latestFingerprint: latest?.manifest.fingerprint,
          latestCreatedAtMs: latest?.manifest.createdAt,
          nowMs: _now(),
          limits: limits,
          leavingReview: leavingReview,
        )) {
          return null;
        }
        try {
          return await _create(
            store,
            backups,
            SrsBackupKind.auto,
            shouldStop: () => _disposed || _reviewing,
          );
        } on SrsBackupCancelled {
          return null;
        }
      });

  /// 「立即备份」：不看间隔与变动。
  Future<SrsBackupInfo?> backupNow() => _serial(() async {
    final SrsDbStore? store = await _readStore();
    final SrsBackupStore? backups = await _readBackups();
    if (store == null || backups == null) return null;
    return _create(store, backups, SrsBackupKind.manual);
  });

  Future<SrsBackupInfo> _create(
    SrsDbStore store,
    SrsBackupStore backups,
    SrsBackupKind kind, {
    bool Function()? shouldStop,
  }) async {
    final SrsBackupInfo info = await backups.create(
      store,
      kind: kind,
      profileName: await _profileName(store.profileUid),
      nowMs: _now(),
      shouldStop: shouldStop,
    );
    await backups.thin(
      limits: _limits(),
      now: DateTime.fromMillisecondsSinceEpoch(_now()),
    );
    _latestAt.remove(backups.profileUid);
    _notify();
    return info;
  }

  /// 库有变动：满间隔就备份，不满就定时到点再看一次（只留一个定时器）。
  /// 高频调用（每次评分都会 bump 修订号）：定时器在等就直接返回，不碰磁盘。
  void onDataChanged() {
    if (_disposed || !_autoEnabled() || (_timer?.isActive ?? false)) return;
    srsRunLogged('SrsBackup.onDataChanged', scheduleCheck);
  }

  /// [onDataChanged] 的可等待版本（测试与 [reschedule] 用）：满间隔就备份，否则挂一个到点再看的定时器。
  /// 每个 await 之后都重新检查 dispose / 开关 / 已有定时器：等待期间控制器可能已被释放，或别的调用已挂好定时器。
  @visibleForTesting
  Future<void> scheduleCheck() async {
    bool stale() => _disposed || !_autoEnabled() || (_timer?.isActive ?? false);
    if (stale()) return;
    final SrsBackupStore? backups = await _readBackups();
    if (backups == null || stale()) return;
    final int? latest = await _latestCreatedAt(backups);
    if (stale()) return;
    final int interval = _limits().intervalMinutes * 60 * 1000;
    final int wait = latest == null ? 0 : latest + interval - _now();
    if (wait <= 0) {
      await autoBackup();
      return;
    }
    _timerDueAtMs = _now() + wait;
    _timer = Timer(Duration(milliseconds: wait), () {
      _timer = null;
      _timerDueAtMs = null;
      srsRunLogged('SrsBackup.timer', () async {
        await autoBackup();
      });
    });
  }

  /// 自动备份的开关或间隔变了：已挂起的定时器按旧间隔算的，作废后按新设置重排（关掉则只作废）。
  Future<void> reschedule() async {
    _timer?.cancel();
    _timer = null;
    _timerDueAtMs = null;
    await scheduleCheck();
  }

  /// 已挂起定时器的到点时刻（毫秒，按注入的时钟）；没有挂起为 null。
  int? _timerDueAtMs;

  @visibleForTesting
  int? get pendingTimerDueAtMs =>
      (_timer?.isActive ?? false) ? _timerDueAtMs : null;

  /// SRS 界面正在用（复习页开着 / SRS 底栏在显示）：不开始自动备份，正在做的自动备份读完
  /// 当前这一页就停下（手动「立即备份」不受影响）。
  bool _reviewing = false;

  /// SRS 界面开始被使用。
  void onSrsInUse() {
    _reviewing = true;
  }

  /// SRS 界面不再被使用（离开复习页 / 切走 SRS 底栏）：有变动、且距最近一份满 5 分钟就备份
  /// （不等 30 分钟的定时间隔）；复习中被叫停的那一份也在这里补上。
  void onSrsIdle() {
    _reviewing = false;
    srsRunLogged('SrsBackup.leftReview', () async {
      await autoBackup(leavingReview: true);
    });
  }

  /// 删一份备份。
  Future<void> delete(SrsBackupInfo info) => _serial(() async {
    final SrsBackupStore? backups = await _readBackups();
    if (backups == null) return;
    await backups.delete(info);
    _latestAt.remove(backups.profileUid);
    _notify();
  });

  /// 恢复到本机备份库里的一份（恢复前先存一份当前状态，可撤回）。
  Future<SrsBackupRestoreOutcome?> restore(SrsBackupInfo info) =>
      _serial(() async {
        final SrsBackupArchive a = await SrsBackupStore.read(info.file);
        try {
          return await _restoreArchive(a);
        } finally {
          a.close();
        }
      });

  /// 从外部选来的备份文件恢复。
  ///
  /// 备份属于另一个 profile 时：
  /// - 本机已有那个 profile（同 uid）→ 抛 [SrsRestoreOtherLocalProfile]，让用户切过去再恢复
  ///   （不能再让当前 profile 采用同一个 uid：`profiles.uid` 唯一）；
  /// - 当前 profile 没有用户笔记、也从未同步发布过（新装的设备）→ 采用备份的 profile 身份（铁律 E），
  ///   [reopenStore] 按新身份重开 store、换一个新的写入者化身（不沿用这台设备可能用过的旧 writerId），再恢复；
  ///   任何一步失败都把 uid 换回去、重开 store（采用与恢复要么都成、要么都不成）；
  /// - 否则抛 [SrsRestoreProfileMismatch]（不把别人的数据混进有数据的 profile）。
  Future<SrsBackupRestoreOutcome?> restoreFile(
    File file, {
    required FushiDatabase db,
    required SrsStorage srs,
    required Future<int> Function() activeProfileId,
    required Future<void> Function() reopenStore,
  }) => _serial(() async {
    final SrsBackupArchive a = await SrsBackupStore.read(file);
    try {
      final SrsDbStore? store = await _readStore();
      if (store == null) return null;
      final String backupUid = a.manifest.profileUid;
      if (backupUid == store.profileUid) return await _restoreArchive(a);
      final QueryRow? owner = await db
          .customSelect(
            'SELECT name FROM profiles WHERE uid = ?',
            variables: <Variable<Object>>[Variable<String>(backupUid)],
          )
          .getSingleOrNull();
      if (owner != null) {
        throw SrsRestoreOtherLocalProfile(owner.read<String>('name'));
      }
      final String deviceId = await SyncRepository(db).getOrCreateDeviceId();
      if (!await srsCanAdoptProfileUid(srs, store.profileUid, deviceId)) {
        throw SrsRestoreProfileMismatch(backupUid, store.profileUid);
      }
      final int profileId = await activeProfileId();
      final String oldUid = store.profileUid;
      await srsAdoptProfileUid(
        db,
        srs.db,
        profileId: profileId,
        oldUid: oldUid,
        newUid: backupUid,
      );
      try {
        await reopenStore();
        final SrsDbStore? adopted = await _readStore();
        if (adopted == null || adopted.profileUid != backupUid) {
          throw StateError('store did not reopen under the adopted profile');
        }
        await adopted.afterRestore(freshIncarnation: true);
        return await _restoreArchive(a, snapshot: false);
      } catch (_) {
        // 回到采用之前：新 uid 下的行全部删掉、uid 换回去（旧 uid 下只有内置行 / 本机状态，重开时重建）。
        await srsAdoptProfileUid(
          db,
          srs.db,
          profileId: profileId,
          oldUid: backupUid,
          newUid: oldUid,
        );
        await reopenStore();
        rethrow;
      }
    } finally {
      a.close();
      _latestAt.clear();
    }
  });

  Future<SrsBackupRestoreOutcome?> _restoreArchive(
    SrsBackupArchive a, {
    bool snapshot = true,
  }) async {
    final SrsDbStore? store = await _readStore();
    final SrsBackupStore? backups = await _readBackups();
    if (store == null || backups == null) return null;
    SrsBackupInfo? pre;
    if (snapshot) {
      pre = await backups.create(
        store,
        kind: SrsBackupKind.preRestore,
        profileName: await _profileName(store.profileUid),
        nowMs: _now(),
      );
    }
    final SrsRestoreReport report = await backups.restore(store, a);
    _latestAt.remove(backups.profileUid);
    _notify();
    return SrsBackupRestoreOutcome(report: report, snapshot: pre);
  }

  /// 导出一份自包含文件（带媒体）到 [out]。
  Future<File?> export(SrsBackupInfo info, File out) => _serial(() async {
    final SrsBackupStore? backups = await _readBackups();
    if (backups == null) return null;
    return backups.exportSelfContained(info, out);
  });

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _timerDueAtMs = null;
    changes.dispose();
  }
}
