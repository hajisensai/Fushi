/// 删 Profile 时级联清理它的复习（SRS）数据（反馈 8TaOy2i-lL 现象 3，所有者 2026-10-27 拍板方案 A）。
///
/// `srs.db` 是所有 profile 共用的一个文件，行按 `profiles.uid` 归属；主库的外键级联管不到它。这里：
///
/// 1. **统计**（[impactOf]）：确认框写明会连带删掉多少卡、多少复习记录——数字由 Rust 一次读出
///    （native/fushi_fsrs/src/store/profile_data.rs）。
/// 2. **先备份**（[prepare]）：用现有的 `.fushisrs` 导出（`srsExportFushiSrs`，操作 + 被引用的媒体）落到
///    `<documents>/srs_profile_backups/`，文件名带 profile 名与时刻，作为撤销途径；备份失败就抛
///    [ProfileDeletionBackupException]，删除中止、什么都不动。
/// 3. **再清**（[ProfileDeletionCleanup.run]，`profiles` 行删掉之后）：Rust 一条命令在一个事务里删光这个 uid 在
///    每张 `srs_*` / `sync2_*` 表里的行；再删 `srs_media/<uid>`（媒体与释义样式同目录）和这个 uid 的 RWKV 快照。
///    远端存储位置上已同步的集合不动（只删本机）。
/// 4. **存量**（[sweepOrphans]）：进 Profile 管理时扫一次 srs.db 里不属于任何现存 profile 的 uid，同样先备份再清；
///    全部清完在 srs.db 记下完成标记，之后不再扫。
///
/// 删数据的那一刻，这个 uid 的副本（[SrsDbStore]）先 [SrsDbStore.retire]：在途写入做完、之后的写入一律失败，
/// 不会有迟到的写把行写回一个已删的 uid。所有对共用写连接的操作都排进当前副本的独占区：Rust 命令在写连接上是
/// savepoint，夹进别的副本开着的事务里就会随它回滚。
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show ProfileRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_data.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_fushisrs.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/profile/profile_deletion_cascade.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// [SrsProfileCleanup] 的依赖（测试注入）。
class SrsProfileCleanupDeps {
  const SrsProfileCleanupDeps({
    required this.storage,
    required this.activeStore,
    required this.deviceId,
    required this.supportRoot,
    required this.backupRoot,
    this.releaseForeign = _noForeignStores,
    this.clock = DateTime.now,
  });

  static Future<void> _noForeignStores(String profileUid) async {}

  /// 本机 srs.db；没有（从没用过复习）为 null，不凭空建库。
  final Future<SrsStorage?> Function() storage;

  /// 当前 profile 的副本；复习模块关着时为 null。
  final Future<SrsDbStore?> Function() activeStore;

  final Future<String> Function() deviceId;

  /// `srs_media` / `srs_rwkv` 所在的支持目录。
  final Future<Directory> Function() supportRoot;

  /// 删除前备份的落点。
  final Future<Directory> Function() backupRoot;

  /// 作废浏览器扩展为这个 uid 开着的复习副本（`SrsProfileStores.release`）：本清理要为它另开一份
  /// 副本，同一个 uid 不能同时有两份活副本。
  final Future<void> Function(String profileUid) releaseForeign;

  final DateTime Function() clock;
}

/// 删 Profile 的复习数据级联清理。
class SrsProfileCleanup implements ProfileDeletionCascade {
  SrsProfileCleanup(this._deps);

  final SrsProfileCleanupDeps _deps;

  @override
  Future<ProfileDeletionImpact> impactOf(ProfileRow profile) async {
    final String? uid = _uidOf(profile);
    if (uid == null) return const ProfileDeletionImpact.none();
    return (await _scan(uid)).impact;
  }

  @override
  Future<ProfileDeletionCleanup> prepare(ProfileRow profile) async {
    final String? uid = _uidOf(profile);
    if (uid == null) return _NoCleanup.instance;
    return _prepareUid(uid, label: profile.name);
  }

  @override
  Future<int> sweepOrphans(List<ProfileRow> live) async {
    final Set<String> liveUids = <String>{
      for (final ProfileRow r in live) ?_uidOf(r),
    };
    // 主库一个 profile 都读不出来时绝不能把 srs.db 当成全部无主。
    if (liveUids.isEmpty) return 0;
    final SrsStorage? storage = await _deps.storage();
    if (storage == null) return 0;
    final SrsStoredProfiles stored = await srsStoredProfiles(storage.core);
    if (stored.orphanSweptAt != null) return 0;
    final List<String> orphans = <String>[
      for (final String uid in stored.uids)
        if (!liveUids.contains(uid)) uid,
    ];
    for (final String uid in orphans) {
      final ProfileDeletionCleanup cleanup = await _prepareUid(
        uid,
        label: 'orphan-${uid.length > 8 ? uid.substring(0, 8) : uid}',
      );
      await cleanup.run();
    }
    await srsMarkOrphanSweepDone(
      storage.core,
      _deps.clock().millisecondsSinceEpoch,
    );
    return orphans.length;
  }

  static String? _uidOf(ProfileRow profile) {
    final String? uid = profile.uid;
    return uid == null || uid.isEmpty ? null : uid;
  }

  Future<Directory> _mediaDir(String uid) async =>
      SrsMediaStore.directoryFor(await _deps.supportRoot(), uid);

  Future<_Scan> _scan(String uid) async {
    final SrsStorage? storage = await _deps.storage();
    final SrsProfileFootprint footprint = storage == null
        ? const SrsProfileFootprint.empty()
        : await srsProfileFootprint(storage.core, uid);
    final bool hasMedia = (await _mediaDir(uid)).existsSync();
    return _Scan(
      storage: storage,
      footprint: footprint,
      impact: ProfileDeletionImpact(
        srsNotes: footprint.notes,
        srsCards: footprint.cards,
        srsReviews: footprint.reviews,
        hasSrsData: !footprint.isEmpty || hasMedia,
      ),
    );
  }

  /// 在当前副本的独占区里跑 [body]（[target] 就是当前副本时直接跑：它自己的命令已在它的独占区里排队）。
  Future<T> _serialized<T>(
    SrsDbStore? target,
    Future<T> Function() body,
  ) async {
    final SrsDbStore? active = await _deps.activeStore();
    if (active == null || identical(active, target)) return body();
    return active.runExclusive(body);
  }

  Future<ProfileDeletionCleanup> _prepareUid(
    String uid, {
    required String label,
  }) async {
    final _Scan scan = await _scan(uid);
    if (!scan.impact.hasSrsData) return _NoCleanup.instance;
    final SrsStorage? storage = scan.storage;
    final Directory mediaDir = await _mediaDir(uid);
    if (storage == null || scan.footprint.isEmpty) {
      // 库里没有它的行，只剩媒体目录：没有任何笔记引用这些文件，也就没有可备份的复习数据。
      return _SrsCleanup(
        owner: this,
        uid: uid,
        storage: null,
        store: null,
        mediaDir: mediaDir,
        impact: scan.impact,
        backupPath: null,
      );
    }
    final SrsDbStore store;
    final File backup;
    try {
      final SrsDbStore? active = await _deps.activeStore();
      final bool isActive = active != null && active.profileUid == uid;
      if (!isActive) await _deps.releaseForeign(uid);
      store = isActive
          ? active
          : await _serialized(
              null,
              () async => SrsDbStore.open(
                db: storage.db,
                core: storage.core,
                profileUid: uid,
                deviceId: await _deps.deviceId(),
              ),
            );
      backup = await _backupFile(label);
      await _serialized(
        store,
        () => srsExportFushiSrs(store, backup, mediaRoot: mediaDir),
      );
    } on Object catch (e, stack) {
      Error.throwWithStackTrace(ProfileDeletionBackupException(e), stack);
    }
    return _SrsCleanup(
      owner: this,
      uid: uid,
      storage: storage,
      store: store,
      mediaDir: mediaDir,
      impact: scan.impact,
      backupPath: backup.path,
    );
  }

  /// `<备份根>/fushi-review-<profile 名>-<yyyyMMdd-HHmmss>.fushisrs`；同一秒撞名时加序号。
  Future<File> _backupFile(String label) async {
    final Directory root = await _deps.backupRoot();
    await root.create(recursive: true);
    final DateTime c = _deps.clock();
    String two(int v) => v.toString().padLeft(2, '0');
    final String stamp =
        '${c.year}${two(c.month)}${two(c.day)}-'
        '${two(c.hour)}${two(c.minute)}${two(c.second)}';
    final String name = safeWindowsFileName(label).trim();
    final String base =
        'fushi-review-${name.isEmpty ? 'profile' : name}-$stamp';
    File f = File(p.join(root.path, '$base.$kSrsFushiSrsExtension'));
    for (int n = 2; f.existsSync(); n++) {
      f = File(p.join(root.path, '$base-$n.$kSrsFushiSrsExtension'));
    }
    return f;
  }

  /// 本机这个 uid 的 RWKV 排程快照（`<support>/srs_rwkv/state/rwkv-<uid>-<模型>.snap`，见 srs_rwkv_service.dart）。
  Future<void> _deleteRwkvSnapshots(String uid) async {
    final Directory dir = Directory(
      p.join((await _deps.supportRoot()).path, 'srs_rwkv', 'state'),
    );
    if (!dir.existsSync()) return;
    final String prefix = 'rwkv-$uid-';
    await for (final FileSystemEntity e in dir.list(followLinks: false)) {
      if (e is File && p.basename(e.path).startsWith(prefix)) {
        await e.delete();
      }
    }
  }
}

class _Scan {
  const _Scan({
    required this.storage,
    required this.footprint,
    required this.impact,
  });

  final SrsStorage? storage;
  final SrsProfileFootprint footprint;
  final ProfileDeletionImpact impact;
}

class _NoCleanup implements ProfileDeletionCleanup {
  const _NoCleanup();

  static const _NoCleanup instance = _NoCleanup();

  @override
  String? get backupPath => null;

  @override
  ProfileDeletionImpact get impact => const ProfileDeletionImpact.none();

  @override
  Future<void> run() async {}
}

class _SrsCleanup implements ProfileDeletionCleanup {
  _SrsCleanup({
    required this.owner,
    required this.uid,
    required this.storage,
    required this.store,
    required this.mediaDir,
    required this.impact,
    required this.backupPath,
  });

  final SrsProfileCleanup owner;
  final String uid;
  final SrsStorage? storage;
  final SrsDbStore? store;
  final Directory mediaDir;
  @override
  final ProfileDeletionImpact impact;
  @override
  final String? backupPath;

  @override
  Future<void> run() async {
    final SrsStorage? s = storage;
    final SrsDbStore? target = store;
    if (s != null && target != null) {
      await owner._serialized(
        target,
        () => target.retire(() => srsPurgeProfileRows(s.core, uid)),
      );
    }
    if (mediaDir.existsSync()) await mediaDir.delete(recursive: true);
    await owner._deleteRwkvSnapshots(uid);
  }
}

/// App 装配：srs.db 只在复习模块开着、或文件已经存在时打开（同备份导出，[AppModel.srsStorageForBackup]）。
SrsProfileCleanup srsProfileCleanupFor(Ref ref) => SrsProfileCleanup(
  SrsProfileCleanupDeps(
    storage: () => ref.read(appProvider).srsStorageForBackup(),
    activeStore: () async => ref.read(srsModuleEnabledProvider)
        ? ref.read(srsStoreProvider.future)
        : null,
    deviceId: () =>
        SyncRepository(ref.read(appProvider).database).getOrCreateDeviceId(),
    supportRoot: () => ref.read(srsSupportRootProvider)(),
    backupRoot: AppPaths.srsProfileBackupsDirectory,
    releaseForeign: (String uid) =>
        ref.read(srsProfileStoresProvider).release(uid),
  ),
);
