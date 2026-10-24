/// 复习（SRS）同步的 profile 关联（docs/specs/2026-10-14-fushi-srs-design.md 铁律 E）。
///
/// 同步目录按 profile 的全局身份分区：`fushi-srs/<profileUid>/<writerId>/...`。profileUid 是每台
/// 设备第一次打开 SRS 时**本机随机生成**的（`FushiDatabase.profileUidOf`），所以两台各自装好的
/// 设备即使都叫「默认」，也各写各的 `<profileUid>` 目录、谁也读不到谁——互联 / 云盘看起来「连上了、
/// 同步成功了」，复习数据却从不互通。设计里要求的「新设备第一次接入同步时关联到已有的 profile」
/// 此前只在备份恢复里做了，同步路径上没有。
///
/// 本文件补上同步路径的关联：
/// - 每个写入者在自己的目录里放一份 [kSrsProfileInfoName]（profile 名 + 有没有用户笔记），
///   别的设备据此认出「同一个 profile」；
/// - [srsDecideProfileLink] 是纯函数：给定本机 profile 与目录里已有的 profile，决定保持 / 采用
///   对方 uid / 报告无法自动关联。采用只在本机 profile **没有用户笔记**时发生（只有内置行，
///   内置行 ID 由 uid 派生、换 uid 后随新 uid 重新生成），不做任何 ID 重映射；
/// - 双方都没有用户笔记时按 uid 字典序只让一边采用，不会两边互相采用来回翻。
///
/// 只读写 [SyncAssetStore]，与后端无关（互联 / 云盘同一份格式）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/srs/srs_asset_store_directory.dart'
    show kSrsSyncNamespace;
import 'package:fushi_engine/srs/srs_backup_merge.dart' show srsAdoptProfileUid;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

/// 写入者目录里的 profile 说明文件。同步引擎只认 `batch-*` / `snapshot-*` / `cursor` / `probe`，
/// 其余文件名忽略。
const String kSrsProfileInfoName = 'profile.json';

/// 同步目录里的一个 profile（`fushi-srs/<uid>/`）。
class SrsRemoteProfile {
  const SrsRemoteProfile({
    required this.uid,
    required this.writers,
    this.names = const <String>{},
    this.hasNotes,
  });

  final String uid;

  /// 目录里的写入者（`<deviceId>#<化身号>`）。
  final List<String> writers;

  /// 各写入者 [kSrsProfileInfoName] 里报的 profile 名（旧版本不写说明文件时为空）。
  final Set<String> names;

  /// 有没有写入者报告过「有用户笔记」；没有任何说明文件时为 null（未知）。
  final bool? hasNotes;
}

/// 关联决定。
sealed class SrsProfileLinkDecision {
  const SrsProfileLinkDecision();
}

/// 保持本机 profile 身份照常同步。
class SrsProfileLinkKeep extends SrsProfileLinkDecision {
  const SrsProfileLinkKeep();
}

/// 本机 profile 改用 [uid]（目录里已有的同一个 profile）。
class SrsProfileLinkAdopt extends SrsProfileLinkDecision {
  const SrsProfileLinkAdopt(this.uid);
  final String uid;
}

/// 目录里有疑似同一个 profile（[remoteName]），但两边都有用户笔记，不能自动关联。
class SrsProfileLinkConflict extends SrsProfileLinkDecision {
  const SrsProfileLinkConflict(this.remoteUid, this.remoteName);
  final String remoteUid;
  final String remoteName;
}

/// 写入者 [writerId] 是否属于设备 [deviceId]（写入者 id = `<deviceId>#<化身号>`）。
bool srsWriterOfDevice(String writerId, String deviceId) =>
    writerId.startsWith('$deviceId#');

/// 决定本机 profile 与同步目录的关联（纯函数，规则见库注释）。
///
/// - [localProfileCount]：本机 profile 总数。目录里的 profile 都没有说明文件（旧版本写的）、
///   名字对不上时，只有「两边都只有一个 profile」才把唯一那个当成同一个。
SrsProfileLinkDecision srsDecideProfileLink({
  required String localUid,
  required String localName,
  required String deviceId,
  required bool localHasNotes,
  required int localProfileCount,
  required List<SrsRemoteProfile> remote,
}) {
  SrsRemoteProfile? own;
  final List<SrsRemoteProfile> others = <SrsRemoteProfile>[];
  for (final SrsRemoteProfile r in remote) {
    if (r.uid == localUid) {
      own = r;
    } else if (r.writers.isNotEmpty) {
      others.add(r);
    }
  }
  // 本机 uid 的目录里已有别的设备：已经关联上了（别人采用了我们的 uid），改 uid 会把它们甩下。
  if (own != null &&
      own.writers.any((String w) => !srsWriterOfDevice(w, deviceId))) {
    return const SrsProfileLinkKeep();
  }
  // 只看「不全是本设备写的」profile：本设备旧化身留下的目录不算别人的数据。
  final List<SrsRemoteProfile> foreign = <SrsRemoteProfile>[
    for (final SrsRemoteProfile r in others)
      if (r.writers.any((String w) => !srsWriterOfDevice(w, deviceId))) r,
  ];
  if (foreign.isEmpty) return const SrsProfileLinkKeep();
  final List<SrsRemoteProfile> byName = <SrsRemoteProfile>[
    for (final SrsRemoteProfile r in foreign)
      if (r.names.contains(localName)) r,
  ];
  final SrsRemoteProfile match;
  if (byName.length == 1) {
    match = byName.single;
  } else if (byName.isEmpty &&
      foreign.length == 1 &&
      localProfileCount == 1 &&
      (foreign.single.names.isEmpty || foreign.single.names.length == 1)) {
    // 两边都只有一个 profile：名字因语言不同（「默认」/「Default」）或旧版本没写说明文件而对不上，
    // 仍是同一个人的同一份数据。
    match = foreign.single;
  } else {
    return const SrsProfileLinkKeep();
  }
  final bool remoteHasNotes = match.hasNotes ?? true;
  if (!localHasNotes) {
    // 双方都只有内置行：只让 uid 较大的一边采用较小的，另一边保持，不会互相采用。
    if (!remoteHasNotes && match.uid.compareTo(localUid) > 0) {
      return const SrsProfileLinkKeep();
    }
    return SrsProfileLinkAdopt(match.uid);
  }
  if (remoteHasNotes) {
    return SrsProfileLinkConflict(
      match.uid,
      match.names.isEmpty ? match.uid : match.names.first,
    );
  }
  // 对方只有内置行：它会来采用本机的 uid。
  return const SrsProfileLinkKeep();
}

/// 列出同步目录里的全部 profile（读各写入者的说明文件）。
Future<List<SrsRemoteProfile>> srsListRemoteProfiles(
  SyncAssetStore store, {
  Directory? tempDir,
}) async {
  final String ns = await store.ensureNamespace(kSrsSyncNamespace);
  final List<SrsRemoteProfile> out = <SrsRemoteProfile>[];
  for (final AssetEntry p in await store.listChildren(ns)) {
    if (!p.isFolder) continue;
    final List<String> writers = <String>[];
    final Set<String> names = <String>{};
    bool? hasNotes;
    for (final AssetEntry w in await store.listChildren(p.id)) {
      if (!w.isFolder) continue;
      writers.add(w.name);
      final Map<String, Object?>? info = await _readInfo(store, w.id, tempDir);
      if (info == null) continue;
      final Object? name = info['name'];
      if (name is String && name.isNotEmpty) names.add(name);
      final Object? notes = info['hasNotes'];
      if (notes is bool) hasNotes = (hasNotes ?? false) || notes;
    }
    out.add(
      SrsRemoteProfile(
        uid: p.name,
        writers: writers,
        names: names,
        hasNotes: hasNotes,
      ),
    );
  }
  return out;
}

Future<Map<String, Object?>?> _readInfo(
  SyncAssetStore store,
  String writerFolder,
  Directory? tempDir,
) async {
  final AssetEntry? a = await store.findAsset(
    writerFolder,
    kSrsProfileInfoName,
  );
  if (a == null) return null;
  final Directory dir = await (tempDir ?? Directory.systemTemp).createTemp(
    'fushi_srs_profile_',
  );
  try {
    final File f = File('${dir.path}${Platform.pathSeparator}info');
    await store.getAsset(a.id, f);
    final Object? j = jsonDecode(await f.readAsString());
    return j is Map ? j.cast<String, Object?>() : null;
  } on Object {
    // 半截 / 坏文件 = 这一轮当作没有说明文件。
    return null;
  } finally {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // 临时目录留给系统清理。
    }
  }
}

/// 在本机写入者目录里写（覆盖）profile 说明文件。
Future<void> srsPublishProfileInfo(
  SyncAssetStore store, {
  required String profileUid,
  required String writerId,
  required String name,
  required bool hasNotes,
  Directory? tempDir,
}) async {
  final String ns = await store.ensureNamespace(kSrsSyncNamespace);
  final String profile = await store.ensureFolder(ns, profileUid);
  final String writer = await store.ensureFolder(profile, writerId);
  // 允许同名多文件的后端（Google Drive）先删旧的再写，避免读到旧的那份。
  final AssetEntry? old = await store.findAsset(writer, kSrsProfileInfoName);
  if (old != null) await store.deleteAsset(old.id);
  final Directory dir = await (tempDir ?? Directory.systemTemp).createTemp(
    'fushi_srs_profile_',
  );
  try {
    final File f = File('${dir.path}${Platform.pathSeparator}info');
    await f.writeAsString(
      jsonEncode(<String, Object?>{'v': 1, 'name': name, 'hasNotes': hasNotes}),
      flush: true,
    );
    await store.putAsset(writer, kSrsProfileInfoName, f);
  } finally {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // 临时目录留给系统清理。
    }
  }
}

/// 采用别的 uid 之后，删掉本设备在旧 uid 下留下的写入者目录（[srsDecideProfileLink] 只在旧目录
/// 里没有别的设备时才会决定采用，所以这里删的只是本设备自己的孤儿目录）。旧 profile 目录空了
/// 一并删除。
Future<void> srsRemoveOwnProfileFolder(
  SyncAssetStore store, {
  required String profileUid,
  required String deviceId,
}) async {
  final String ns = await store.ensureNamespace(kSrsSyncNamespace);
  AssetEntry? profile;
  for (final AssetEntry e in await store.listChildren(ns)) {
    if (e.isFolder && e.name == profileUid) profile = e;
  }
  if (profile == null) return;
  final List<AssetEntry> children = await store.listChildren(profile.id);
  if (children.any(
    (AssetEntry e) => !e.isFolder || !srsWriterOfDevice(e.name, deviceId),
  )) {
    for (final AssetEntry e in children) {
      if (e.isFolder && srsWriterOfDevice(e.name, deviceId)) {
        await store.deleteAsset(e.id, isFolder: true);
      }
    }
    return;
  }
  await store.deleteAsset(profile.id, isFolder: true);
}

/// 一次 profile 关联的结果：继续同步用的 store（采用了目录里已有的 uid 时是按新身份重开的那个）。
class SrsProfileLinkOutcome {
  const SrsProfileLinkOutcome(this.store, {this.unlinkedProfileName});

  final SrsDbStore store;

  /// 非 null = 目录里有疑似同一个 profile（这个名字）但两边都有用户笔记，没有自动关联。
  final String? unlinkedProfileName;
}

/// 同步前的 profile 关联与同步后的说明文件发布（铁律 E，见文件头）。
abstract interface class SrsProfileLinker {
  /// 跑引擎之前：决定本机 profile 是否改用目录里已有的 uid（必要时采用并重开 store）。
  Future<SrsProfileLinkOutcome> link(SyncAssetStore backend, SrsDbStore store);

  /// 引擎跑成功之后：在本机写入者目录里写 profile 说明文件（内容没变就不重写）。
  Future<void> publish(
    SyncAssetStore backend,
    SrsDbStore store,
    String directoryKey,
  );
}

/// 生产实现：读写 [db] 的 profiles 表，采用后用 [reopenStore] 按新身份重开当前 profile 的 store。
class SrsDbProfileLinker implements SrsProfileLinker {
  SrsDbProfileLinker({
    required this.db,
    required this.activeProfileId,
    required this.reopenStore,
    this.onError,
  });

  final FushiDatabase db;

  /// 非致命错误（孤儿目录删不掉等）的日志出口。
  final void Function(String where, Object error, StackTrace stack)? onError;
  final Future<int> Function() activeProfileId;

  /// 让当前 profile 的 store 按 profiles 表里的新 uid 重开，返回新 store。
  final Future<SrsDbStore?> Function() reopenStore;

  /// 目录 → 上次发布的说明内容（同一进程里不重复写）。
  final Map<String, String> _published = <String, String>{};

  Future<String> _nameOf(String uid) async {
    final QueryRow? row = await db
        .customSelect(
          'SELECT name FROM profiles WHERE uid = ?',
          variables: <Variable<Object>>[Variable<String>(uid)],
        )
        .getSingleOrNull();
    return row?.read<String?>('name') ?? '';
  }

  Future<bool> _uidTakenLocally(String uid) async =>
      (await db
              .customSelect(
                'SELECT 1 FROM profiles WHERE uid = ?',
                variables: <Variable<Object>>[Variable<String>(uid)],
              )
              .get())
          .isNotEmpty;

  Future<int> _profileCount() async {
    final QueryRow row = await db
        .customSelect('SELECT COUNT(*) AS c FROM profiles')
        .getSingle();
    return row.read<int>('c');
  }

  @override
  Future<SrsProfileLinkOutcome> link(
    SyncAssetStore backend,
    SrsDbStore store,
  ) async {
    final SrsProfileLinkDecision decision = srsDecideProfileLink(
      localUid: store.profileUid,
      localName: await _nameOf(store.profileUid),
      deviceId: store.deviceId,
      localHasNotes: await store.hasUserNotes(),
      localProfileCount: await _profileCount(),
      remote: await srsListRemoteProfiles(backend),
    );
    switch (decision) {
      case SrsProfileLinkKeep():
        return SrsProfileLinkOutcome(store);
      case SrsProfileLinkConflict(:final String remoteName):
        return SrsProfileLinkOutcome(store, unlinkedProfileName: remoteName);
      case SrsProfileLinkAdopt(:final String uid):
        // 那个 uid 已是本机另一个 profile（profiles.uid 唯一）：用户切过去就能同步，不动。
        if (await _uidTakenLocally(uid)) return SrsProfileLinkOutcome(store);
        final int profileId = await activeProfileId();
        final String oldUid = store.profileUid;
        await srsAdoptProfileUid(
          db,
          store.db,
          profileId: profileId,
          oldUid: oldUid,
          newUid: uid,
        );
        final SrsDbStore adopted;
        try {
          final SrsDbStore? reopened = await reopenStore();
          if (reopened == null || reopened.profileUid != uid) {
            throw StateError('store did not reopen under the adopted profile');
          }
          // 新写入者化身：本设备可能早年在这个 profile 下写过（重装等），不沿用旧 writerId。
          await reopened.afterRestore(freshIncarnation: true);
          adopted = reopened;
        } catch (_) {
          // 采用要么整体成功、要么回到原样（旧 uid 下只有内置行 / 本机状态，重开时重建）。
          await srsAdoptProfileUid(
            db,
            store.db,
            profileId: profileId,
            oldUid: uid,
            newUid: oldUid,
          );
          await reopenStore();
          rethrow;
        }
        try {
          await srsRemoveOwnProfileFolder(
            backend,
            profileUid: oldUid,
            deviceId: store.deviceId,
          );
        } catch (e, stack) {
          // 孤儿目录只有本设备的内置行批次，删不掉不影响同步。
          onError?.call('SrsProfileLinker.cleanup', e, stack);
        }
        return SrsProfileLinkOutcome(adopted);
    }
  }

  @override
  Future<void> publish(
    SyncAssetStore backend,
    SrsDbStore store,
    String directoryKey,
  ) async {
    final String name = await _nameOf(store.profileUid);
    final bool hasNotes = await store.hasUserNotes();
    final String sig = '${store.profileUid}|${store.writerId}|$name|$hasNotes';
    if (_published[directoryKey] == sig) return;
    await srsPublishProfileInfo(
      backend,
      profileUid: store.profileUid,
      writerId: store.writerId,
      name: name,
      hasNotes: hasNotes,
    );
    _published[directoryKey] = sig;
  }
}
