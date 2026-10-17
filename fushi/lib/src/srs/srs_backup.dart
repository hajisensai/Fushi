/// 复习自动备份的 app 侧装配（设计见 docs/specs/2026-10-17-srs-auto-backup-restore.md）。
///
/// - [srsBackupStoreProvider]：当前 profile 的本机备份库（`<支持目录>/srs_backups/<profileUid>/`）。
/// - [SrsBackupController]：自动备份的触发与串行化、立即备份、恢复（恢复前先存一份当前状态）。
///   触发点由 `SrsAppRuntime` 接：库有变动（[srsRevisionProvider]）→ 满间隔就备份，不满就定时到点再看；
///   离开复习页 → 有变动就立即备份。没有变动（库指纹与最近一份相同）一律不备份。
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_merge.dart';
import 'package:fushi_engine/srs/srs_backup_retention.dart';
import 'package:fushi_engine/srs/srs_backup_store.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_point_in_time_restore.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// 当前 profile 的本机复习备份库；模块关着时为 null。
final FutureProvider<SrsBackupStore?> srsBackupStoreProvider =
    FutureProvider<SrsBackupStore?>((Ref ref) async {
      final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
      if (store == null) return null;
      final Directory support = await ref.watch(srsSupportRootProvider)();
      return SrsBackupStore(
        root: SrsBackupStore.rootFor(support),
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
        if (_disposed || !_autoEnabled()) return null;
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
          force: leavingReview,
        )) {
          return null;
        }
        return _create(store, backups, SrsBackupKind.auto);
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
    SrsBackupKind kind,
  ) async {
    final SrsBackupInfo info = await backups.create(
      store,
      kind: kind,
      profileName: await _profileName(store.profileUid),
      nowMs: _now(),
    );
    await backups.thin(
      limits: _limits(),
      now: DateTime.fromMillisecondsSinceEpoch(_now()),
    );
    _notify();
    return info;
  }

  /// 库有变动：满间隔就备份，不满就定时到点再看一次（只留一个定时器）。
  void onDataChanged() {
    if (_disposed || !_autoEnabled()) return;
    srsRunLogged('SrsBackup.onDataChanged', () async {
      final SrsBackupStore? backups = await _readBackups();
      if (backups == null || _disposed) return;
      final List<SrsBackupInfo> all = await backups.list();
      final int interval = _limits().intervalMinutes * 60 * 1000;
      final int due = all.isEmpty ? 0 : all.first.manifest.createdAt + interval;
      final int wait = due - _now();
      if (wait <= 0) {
        await autoBackup();
        return;
      }
      if (_timer?.isActive ?? false) return;
      _timer = Timer(Duration(milliseconds: wait), () {
        _timer = null;
        srsRunLogged('SrsBackup.timer', () async {
          await autoBackup();
        });
      });
    });
  }

  /// 离开复习页：有变动就立即备份（不等间隔）。
  void onLeftReview() {
    srsRunLogged('SrsBackup.leftReview', () async {
      await autoBackup(leavingReview: true);
    });
  }

  /// 删一份备份。
  Future<void> delete(SrsBackupInfo info) => _serial(() async {
    final SrsBackupStore? backups = await _readBackups();
    if (backups == null) return;
    await backups.delete(info);
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
  /// 备份属于另一个 profile 时：当前 profile 还没有用户笔记、也从未同步发布过 → 采用备份的 profile
  /// 身份（新装设备接上原来的 profile，[reopenStore] 让 app 按新身份重开 store）再恢复；否则抛
  /// [SrsRestoreProfileMismatch]（不把别人的数据混进有数据的 profile）。
  Future<SrsBackupRestoreOutcome?> restoreFile(
    File file, {
    required FushiDatabase db,
    required Future<int> Function() activeProfileId,
    required Future<void> Function() reopenStore,
  }) => _serial(() async {
    final SrsBackupArchive a = await SrsBackupStore.read(file);
    try {
      final SrsDbStore? store = await _readStore();
      if (store == null) return null;
      if (a.manifest.profileUid != store.profileUid) {
        final String deviceId = await SyncRepository(db).getOrCreateDeviceId();
        if (!await srsCanAdoptProfileUid(db, store.profileUid, deviceId)) {
          throw SrsRestoreProfileMismatch(
            a.manifest.profileUid,
            store.profileUid,
          );
        }
        await srsAdoptProfileUid(
          db,
          profileId: await activeProfileId(),
          oldUid: store.profileUid,
          newUid: a.manifest.profileUid,
        );
        await reopenStore();
        return await _restoreArchive(a, snapshot: false);
      }
      return await _restoreArchive(a);
    } finally {
      a.close();
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
    changes.dispose();
  }
}
