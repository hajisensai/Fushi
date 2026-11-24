/// 手动「合并进共享库」的 app 侧编排（拍板台 design-srs-shared-library 方案 a，组合阶段 5；设计
/// `docs/specs/2026-11-23-combo-settings-tree-design.md` §4.3）。
///
/// 合并本身在内核（`srs_collection_merge.dart` → native/fushi_fsrs/src/store/gen4/cmd/collection_merge.rs，一个写事务）。
/// 这里只做内核做不了的几件事，顺序有讲究：
///
/// 1. **媒体先拷**：独立库的媒体与释义样式在 `srs_media/<独立库 uid>`，共享库读 `srs_media/<共享库 uid>`。按名字拷过去
///    （文件名按内容寻址，同名即同内容，已有的不覆盖）。拷失败整个中止，内核一行没动。
/// 2. **作废独立库的副本**：激活副本正看着它就在它的最后一段独占区里发内核命令（[SrsDbStore.retire]），否则作废浏览器
///    扩展为它开的副本——之后再经旧副本写它都明确失败，不会有迟到的写把它的集合重新建出来。
/// 3. **内核合并**（`collection_merge`）：成功后库里记了墓碑 `collection_merged/<独立库 uid>`。
/// 4. **组合恢复继承**：调用方给的 [SrsLibraryMerger.merge] 的 `restoreInheritance`（在配置变更锁里撤掉那个组合的
///    `srs.library` 拆分），之后它制卡 / 复习都落共享库。
/// 5. **删墓碑**，再删独立库的媒体目录与 RWKV 快照。
///
/// 3 与 4 之间被杀：墓碑留着，下次进配置管理页 [SrsLibraryMerger.finishPending] 补做 4、5（数据早就在共享库里）。
/// 4 之后、5 之前被杀同理（恢复继承是幂等的）。复习页正看着共享库时合并经那份副本发（`sync2Command`）：回包的
/// `bindingChanged` 让它的缓存整份作废、重取身份；浏览器扩展为两边开着的副本一律作废，下次用时按新库重开。
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase, ProfileRow;
import 'package:fushi_engine/profile/combo/combo_srs_library.dart';
import 'package:fushi_engine/srs/srs_collection_merge.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_attach.dart'
    show srsDeleteRwkvSnapshots;
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/profile/combo/srs_library_resolver.dart';
import 'package:fushi/src/srs/srs_providers.dart';

export 'package:fushi_engine/srs/srs_collection_merge.dart'
    show
        SrsMergeChoice,
        SrsMergeConflict,
        SrsMergeFieldDiff,
        SrsMergePreview,
        SrsMergeResult,
        SrsMergeSide;

/// 合并时复习库此刻打不开（模块关着 / 换代中）。
class SrsLibraryMergeUnavailableException implements Exception {
  const SrsLibraryMergeUnavailableException();

  @override
  String toString() => 'SrsLibraryMergeUnavailableException';
}

/// 预览之后组合的复习库归属变了（那个组合已不再拆独立库、共享库换了宿主）：要重新预览。
class SrsLibraryMergeStaleException implements Exception {
  const SrsLibraryMergeStaleException(this.profileId);

  final int profileId;

  @override
  String toString() => 'SrsLibraryMergeStaleException($profileId)';
}

/// 一次合并的对象：组合 [profileId] 拆出的独立库 [fromUid] 并进共享库 [intoUid]，与合并前的预览。
class SrsLibraryMergePlan {
  const SrsLibraryMergePlan({
    required this.profileId,
    required this.profileName,
    required this.fromUid,
    required this.intoUid,
    required this.preview,
  });

  final int profileId;
  final String profileName;
  final String fromUid;
  final String intoUid;
  final SrsMergePreview preview;
}

/// [SrsLibraryMerger] 的依赖（测试注入）。
class SrsLibraryMergeDeps {
  const SrsLibraryMergeDeps({
    required this.storage,
    required this.activeStore,
    required this.releaseForeign,
    required this.supportRoot,
    required this.libraries,
    required this.profiles,
    this.clock = DateTime.now,
  });

  /// 本机 srs.db；没有（模块关着、从没用过复习）为 null。
  final Future<SrsStorage?> Function() storage;

  /// App 激活的复习副本（复习页正看的那份库）；模块关着为 null。
  final Future<SrsDbStore?> Function() activeStore;

  /// 作废浏览器扩展为 [profileUid] 开着的副本（`SrsProfileStores.release`）。
  final Future<void> Function(String profileUid) releaseForeign;

  /// `srs_media` / `srs_rwkv` 所在的支持目录。
  final Future<Directory> Function() supportRoot;

  /// 此刻的复习库归属（`loadComboSrsLibraries`）。
  final Future<ComboSrsLibraries> Function() libraries;

  /// 此刻的全部配置。
  final Future<List<ProfileRow>> Function() profiles;

  final DateTime Function() clock;
}

/// 手动合并进共享库（见库文档）。
class SrsLibraryMerger {
  SrsLibraryMerger(this._deps);

  final SrsLibraryMergeDeps _deps;

  /// 组合 [profileId] 拆出的独立库要并进的共享库：(独立库 uid, 共享库 uid)；它没有独立库（没拆 / 拆了却设回共享 /
  /// 共享库待定 / 独立库就是共享库那份）时 null。
  static ({String from, String into})? endpointsOf(
    ComboSrsLibraries libraries,
    int profileId,
  ) {
    final String? into = libraries.sharedUid;
    if (into == null) return null;
    for (final ComboSrsLibrary l in libraries.libraries) {
      if (!l.shared && l.ownerProfileId == profileId && l.uid != into) {
        return (from: l.uid, into: into);
      }
    }
    return null;
  }

  Future<SrsStorage> _openStorage() async {
    final SrsStorage? storage = await _deps.storage();
    if (storage == null) throw const SrsLibraryMergeUnavailableException();
    return storage;
  }

  /// 组合 [profileId] 的合并预览；它没有独立库时 null。
  Future<SrsLibraryMergePlan?> plan(int profileId) async {
    final ({String from, String into})? ends = endpointsOf(
      await _deps.libraries(),
      profileId,
    );
    if (ends == null) return null;
    String name = '';
    for (final ProfileRow r in await _deps.profiles()) {
      if (r.id == profileId) name = r.name;
    }
    final SrsStorage storage = await _openStorage();
    return SrsLibraryMergePlan(
      profileId: profileId,
      profileName: name,
      fromUid: ends.from,
      intoUid: ends.into,
      preview: await srsCollectionMergePreview(
        storage.core,
        from: ends.from,
        into: ends.into,
      ),
    );
  }

  /// 按 [plan] 合并（见库文档的顺序）。[resolutions]：冲突笔记 → 保留哪一边，没列的保留共享库。
  /// [restoreInheritance]：撤掉组合 [SrsLibraryMergePlan.profileId] 的 `srs.library` 拆分（调用方在配置变更锁里给）。
  ///
  /// 预览之后归属变了抛 [SrsLibraryMergeStaleException]、复习库打不开抛 [SrsLibraryMergeUnavailableException]，
  /// 都什么都没改。
  Future<SrsMergeResult> merge(
    SrsLibraryMergePlan plan,
    Map<String, SrsMergeChoice> resolutions, {
    required Future<void> Function() restoreInheritance,
  }) async {
    final ({String from, String into})? ends = endpointsOf(
      await _deps.libraries(),
      plan.profileId,
    );
    if (ends == null ||
        ends.from != plan.fromUid ||
        ends.into != plan.intoUid) {
      throw SrsLibraryMergeStaleException(plan.profileId);
    }
    final SrsStorage storage = await _openStorage();
    final Directory support = await _deps.supportRoot();
    final Directory fromMedia = SrsMediaStore.directoryFor(
      support,
      plan.fromUid,
    );
    await _copyMissing(
      fromMedia,
      SrsMediaStore.directoryFor(support, plan.intoUid),
    );
    final int now = _deps.clock().millisecondsSinceEpoch;
    Future<SrsMergeResult> direct() => srsCollectionMerge(
      storage.core,
      from: plan.fromUid,
      into: plan.intoUid,
      nowMs: now,
      resolutions: resolutions,
    );
    final SrsDbStore? active = await _deps.activeStore();
    final SrsMergeResult result;
    if (active != null && active.profileUid == plan.fromUid) {
      // 正看着独立库：在它最后一段独占区里并，之后它作废（库没了）。
      await _deps.releaseForeign(plan.intoUid);
      result = await active.retire(
        direct,
        reason: 'library ${plan.fromUid} was merged into ${plan.intoUid}',
      );
    } else if (active != null &&
        active.isUsable &&
        active.profileUid == plan.intoUid) {
      // 正看着共享库：经它发，回包的 `bindingChanged` 让它的缓存整份作废、重取身份（多了 Join、盐与并进来的内容）。
      await _deps.releaseForeign(plan.fromUid);
      result = SrsMergeResult.fromJson(
        (await active.sync2Command(
          srsCollectionMergeRequest(
            from: plan.fromUid,
            into: plan.intoUid,
            nowMs: now,
            resolutions: resolutions,
          ),
        )).map,
      );
    } else {
      await _deps.releaseForeign(plan.fromUid);
      await _deps.releaseForeign(plan.intoUid);
      result = await direct();
    }
    await _finish(storage, plan.fromUid, restoreInheritance);
    return result;
  }

  /// 补做内核已并完、组合还没恢复继承的合并（墓碑）。[restoreInheritance]：撤掉组合 id 的 `srs.library` 拆分（调用方在
  /// 配置变更锁里给）。复习库打不开时什么都不做。返回收尾了几条。
  Future<int> finishPending({
    required Future<void> Function(int profileId) restoreInheritance,
  }) async {
    final SrsStorage? storage = await _deps.storage();
    if (storage == null) return 0;
    final List<SrsPendingCollectionMerge> pending =
        await srsPendingCollectionMerges(storage.core);
    if (pending.isEmpty) return 0;
    final List<ProfileRow> profiles = await _deps.profiles();
    for (final SrsPendingCollectionMerge m in pending) {
      await _finish(storage, m.from, () async {
        for (final ProfileRow r in profiles) {
          if (r.uid == m.from) await restoreInheritance(r.id);
        }
      });
    }
    return pending.length;
  }

  /// 库文档第 4、5 步：恢复继承 → 删墓碑 → 删独立库的媒体目录与 RWKV 快照（数据都已在共享库里）。
  Future<void> _finish(
    SrsStorage storage,
    String from,
    Future<void> Function() restoreInheritance,
  ) async {
    await restoreInheritance();
    await srsFinishCollectionMerge(storage.core, from);
    final Directory support = await _deps.supportRoot();
    final Directory media = SrsMediaStore.directoryFor(support, from);
    if (media.existsSync()) await media.delete(recursive: true);
    await srsDeleteRwkvSnapshots(support, from);
  }

  /// 把 [from] 下的文件按相对路径拷进 [into]；[into] 里已有的不覆盖（文件名按内容寻址）。
  static Future<void> _copyMissing(Directory from, Directory into) async {
    if (!from.existsSync()) return;
    await for (final FileSystemEntity e in from.list(
      recursive: true,
      followLinks: false,
    )) {
      if (e is! File) continue;
      final File target = File(
        p.join(into.path, p.relative(e.path, from: from.path)),
      );
      if (target.existsSync()) continue;
      await target.parent.create(recursive: true);
      await e.copy(target.path);
    }
  }
}

/// App 装配：srs.db 只在复习模块开着、或文件已经存在时打开（同删配置的级联清理）。
SrsLibraryMerger srsLibraryMergerFor(Ref ref) => SrsLibraryMerger(
  SrsLibraryMergeDeps(
    storage: () => ref.read(appProvider).srsStorageForBackup(),
    activeStore: () async => ref.read(srsModuleEnabledProvider)
        ? ref.read(srsStoreProvider.future)
        : null,
    releaseForeign: (String uid) =>
        ref.read(srsProfileStoresProvider).release(uid),
    supportRoot: () => ref.read(srsSupportRootProvider)(),
    libraries: () => loadComboSrsLibraries(_database(ref)),
    profiles: () => _database(ref).getAllProfiles(),
  ),
);

FushiDatabase _database(Ref ref) => ref.read(appProvider).database;
