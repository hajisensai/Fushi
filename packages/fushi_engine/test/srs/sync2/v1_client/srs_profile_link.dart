// 冻结的旧版本（协议 1，develop@d407ae22ca）同步代码，只给 2026-10-30 格式断代的测试用：证明旧客户端碰到新格式的
// 位置时停下、一个字节都不改。原样复制，只改了包内互相引用的 import；不要修改、不要在测试之外引用。
// ignore_for_file: type=lint

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
/// - [srsDecideProfileLink] 是纯函数：给定本机 profile 与目录里已有的 profile，决定保持 / 自动采用
///   对方 uid / 交给用户选。自动采用只在答案唯一时发生：本机 profile **没有用户笔记**（只有内置行，
///   内置行 ID 由 uid 派生、换 uid 后随新 uid 重新生成），且目录里恰好一个有数据的同一 profile；
/// - 答案不唯一时**不静默保持**（以前那样做，三台设备各自随机生成 uid、都叫「Default」时，新设备永远按
///   自己的空 profile 同步，复习数据从不互通、也没有任何提示）：目录里有多个有数据的候选，或本机与对方都有
///   用户笔记，交给用户选采用哪一个（[SrsProfileLinkChoose]）。本机有笔记时选定后并入所选 profile（见
///   srs_profile_merge.dart），不丢任何一边的数据；
/// - 没有用户笔记的 profile 不算候选：它所在的设备会来采用有数据的一方；
/// - 双方都没有用户笔记时按 uid 字典序只让一边采用，不会两边互相采用来回翻。
///
/// 只读写 [SyncAssetStore]，与后端无关（互联 / 云盘同一份格式）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/srs/srs_backup_merge.dart' show srsAdoptProfileUid;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_merge.dart';
import 'srs_location_store.dart'
    show kSrsSync2Folder, kSrsSync2Namespace;
import 'package:fushi_engine/sync/sync_asset_store.dart';

/// srs.db `srs_meta`：本设备改用别的 uid 之前用过的同步 v2 设备身份（JSON 数组）。换 uid 后本机在新集合里是新的
/// v2 设备，旧集合的本机身份行也随并入删掉了——不记下来就认不出同步目录里那个旧 uid 目录是自己留下的孤儿。
/// 只存本机 srs.db（不进偏好表，不随偏好同步到别的设备）。
const String kSrsRetiredV2DevicesKey = 'srs_retired_v2_devices';

/// srs.db `srs_meta`：本设备**改用别的 uid** 时离开的旧 profile uid（JSON 数组）。孤儿目录清理只认这里记着的 uid：
/// 只有换 uid（采用 / 并入）才保证旧 uid 的数据已经搬到了新 uid 下。「只有本设备写过、本机又没有这个 uid 的
/// profile」本身不是证据——删 profile（srs_profile_cleanup.dart 明确约定远端已同步的集合不动、只删本机）、恢复
/// 旧备份之后都是这个样子，那时同步目录里的那份可能是唯一的副本。
const String kSrsRetiredProfileUidsKey = 'srs_retired_profile_uids';

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
    this.updatedAt,
  });

  /// 显示名：说明文件里报的第一个名字，没有时用 uid。
  String get displayName => names.isEmpty ? uid : names.first;

  final String uid;

  /// 目录里的写入者（`<deviceId>#<化身号>`）。
  final List<String> writers;

  /// 各写入者说明文件里最新的修改时刻（毫秒；后端不给或没有说明文件时为 null）。让用户分辨候选用。
  final int? updatedAt;

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
  const SrsProfileLinkKeep({this.linked = false});

  /// 已经关联上了（本机 uid 的目录里有别的设备）：以后不会再变，调用方不必每轮重判。
  final bool linked;
}

/// 本机 profile 改用 [uid]（目录里已有的同一个 profile）。
class SrsProfileLinkAdopt extends SrsProfileLinkDecision {
  const SrsProfileLinkAdopt(this.uid);
  final String uid;
}

/// 没法自动确定：目录里有多个有数据的同一 profile 候选，或本机与对方都有用户笔记。由用户在 [candidates]
/// 里选一个采用（本机有笔记时并入），或保持本机独立。
class SrsProfileLinkChoose extends SrsProfileLinkDecision {
  const SrsProfileLinkChoose(this.candidates);

  /// 有数据（或没有说明文件、不知道有没有）的候选，按 uid 排序。
  final List<SrsRemoteProfile> candidates;
}

/// 写入者 [writerId] 是否属于设备 [deviceId]（旧格式写入者 id = `<deviceId>#<化身号>`；同步 v2 的设备目录
/// 名是 v2 设备 ID，本机的 v2 设备 ID 以 `v2:<id>` 的形式放进 [deviceId] 的同组判断，见 [srsDecideProfileLink]）。
bool srsWriterOfDevice(String writerId, String deviceId) =>
    writerId.startsWith('$deviceId#') || writerId == deviceId;

/// 同步 v2 的设备目录在 [SrsRemoteProfile.writers] 里的名字。
String srsV2WriterName(String device) => 'v2:$device';

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
  String? v2Device,
}) {
  bool own(String w) =>
      srsWriterOfDevice(w, deviceId) ||
      (v2Device != null && w == srsV2WriterName(v2Device));
  SrsRemoteProfile? mine;
  final List<SrsRemoteProfile> others = <SrsRemoteProfile>[];
  for (final SrsRemoteProfile r in remote) {
    if (r.uid == localUid) {
      mine = r;
    } else if (r.writers.isNotEmpty) {
      others.add(r);
    }
  }
  // 本机 uid 的目录里已有别的设备：已经关联上了（别人采用了我们的 uid），改 uid 会把它们甩下。
  if (mine != null && mine.writers.any((String w) => !own(w))) {
    return const SrsProfileLinkKeep(linked: true);
  }
  // 只看「不全是本设备写的」profile：本设备旧化身留下的目录不算别人的数据。
  final List<SrsRemoteProfile> foreign = <SrsRemoteProfile>[
    for (final SrsRemoteProfile r in others)
      if (r.writers.any((String w) => !own(w))) r,
  ];
  if (foreign.isEmpty) return const SrsProfileLinkKeep();
  final List<SrsRemoteProfile> byName = <SrsRemoteProfile>[
    for (final SrsRemoteProfile r in foreign)
      if (r.names.contains(localName)) r,
  ];
  final List<SrsRemoteProfile> pool;
  if (byName.isNotEmpty) {
    pool = byName;
  } else if (localProfileCount == 1 &&
      foreign.every((SrsRemoteProfile r) => r.names.length <= 1)) {
    // 本机只有一个 profile、对方各自也只报一个名字：名字因语言不同（「默认」/「Default」）或旧版本没写说明
    // 文件而对不上，仍是同一个人的同一份数据。
    pool = foreign;
  } else {
    return const SrsProfileLinkKeep();
  }
  // 没有说明文件（旧版本写的）不知道有没有笔记：当作有。
  bool hasData(SrsRemoteProfile r) => r.hasNotes ?? true;
  final List<SrsRemoteProfile> withData = <SrsRemoteProfile>[
    for (final SrsRemoteProfile r in pool)
      if (hasData(r)) r,
  ]..sort((SrsRemoteProfile a, SrsRemoteProfile b) => a.uid.compareTo(b.uid));
  if (withData.isEmpty) {
    // 候选全是只有内置行的空 profile：本机有笔记就等它们来采用本机；本机也没有，就全体收敛到 uid 最小的那个
    // （只让较大的一边采用，不会互相采用来回翻）。
    if (localHasNotes) return const SrsProfileLinkKeep();
    final String smallest = pool
        .map((SrsRemoteProfile r) => r.uid)
        .reduce((String a, String b) => a.compareTo(b) <= 0 ? a : b);
    return smallest.compareTo(localUid) < 0
        ? SrsProfileLinkAdopt(smallest)
        : const SrsProfileLinkKeep();
  }
  // 本机是空的、有数据的候选恰好一个：答案唯一，直接采用。
  if (!localHasNotes && withData.length == 1) {
    return SrsProfileLinkAdopt(withData.single.uid);
  }
  return SrsProfileLinkChoose(withData);
}

/// 列出同步目录里的全部 profile（读各写入者的说明文件）。
Future<List<SrsRemoteProfile>> srsListRemoteProfiles(
  SyncAssetStore store, {
  Directory? tempDir,
}) async {
  final String ns = await store.ensureNamespace(kSrsSync2Namespace);
  final List<SrsRemoteProfile> out = <SrsRemoteProfile>[];
  for (final AssetEntry p in await store.listChildren(ns)) {
    if (!p.isFolder) continue;
    final List<String> writers = <String>[];
    final Set<String> names = <String>{};
    bool? hasNotes;
    int? updatedAt;
    Future<void> readInfo(String folder) async {
      final (Map<String, Object?>?, int?) read = await _readInfo(
        store,
        folder,
        tempDir,
      );
      final Map<String, Object?>? info = read.$1;
      if (info == null) return;
      final int? at = read.$2;
      if (at != null && (updatedAt == null || at > updatedAt!)) updatedAt = at;
      final Object? name = info['name'];
      if (name is String && name.isNotEmpty) names.add(name);
      final Object? notes = info['hasNotes'];
      if (notes is bool) hasNotes = (hasNotes ?? false) || notes;
    }

    for (final AssetEntry w in await store.listChildren(p.id)) {
      if (!w.isFolder) continue;
      if (w.name == kSrsSync2Folder) {
        // 同步 v2：`v2/devices/<设备>/profile.json`。
        for (final AssetEntry d in await store.listChildren(w.id)) {
          if (!d.isFolder || d.name != 'devices') continue;
          for (final AssetEntry dev in await store.listChildren(d.id)) {
            if (!dev.isFolder) continue;
            writers.add(srsV2WriterName(dev.name));
            await readInfo(dev.id);
          }
        }
        continue;
      }
      writers.add(w.name);
      await readInfo(w.id);
    }
    out.add(
      SrsRemoteProfile(
        uid: p.name,
        writers: writers,
        names: names,
        hasNotes: hasNotes,
        updatedAt: updatedAt,
      ),
    );
  }
  return out;
}

/// 一个写入者的说明文件内容与它的修改时刻（毫秒）。
Future<(Map<String, Object?>?, int?)> _readInfo(
  SyncAssetStore store,
  String writerFolder,
  Directory? tempDir,
) async {
  final AssetEntry? a = await store.findAsset(
    writerFolder,
    kSrsProfileInfoName,
  );
  if (a == null) return (null, null);
  final int? at = a.modifiedAt;
  final Directory dir = await (tempDir ?? Directory.systemTemp).createTemp(
    'fushi_srs_profile_',
  );
  try {
    final File f = File('${dir.path}${Platform.pathSeparator}info');
    await store.getAsset(a.id, f);
    final Object? j = jsonDecode(await f.readAsString());
    return (j is Map ? j.cast<String, Object?>() : null, at);
  } on Object {
    // 半截 / 坏文件 = 这一轮当作没有说明文件。
    return (null, null);
  } finally {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // 临时目录留给系统清理。
    }
  }
}

/// 在本机的同步 v2 设备目录（`fushi-srs/<uid>/v2/devices/<设备>/`）里写（覆盖）profile 说明文件。
Future<void> srsPublishProfileInfo(
  SyncAssetStore store, {
  required String profileUid,
  required String writerId,
  required String name,
  required bool hasNotes,
  Directory? tempDir,
}) async {
  final String ns = await store.ensureNamespace(kSrsSync2Namespace);
  final String profile = await store.ensureFolder(ns, profileUid);
  final String v2 = await store.ensureFolder(profile, kSrsSync2Folder);
  final String devices = await store.ensureFolder(v2, 'devices');
  final String writer = await store.ensureFolder(devices, writerId);
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

/// 采用别的 uid 之后，删掉本设备在旧 uid 下留下的目录：旧格式的写入者目录（`<设备>#n`）与同步 v2 的设备目录
/// （`v2/devices/<[v2Device]>`）。[srsDecideProfileLink] 只在旧目录里没有别的设备时才会决定采用，所以删的只是
/// 本设备自己的孤儿目录；`v2/devices` 下没有别的设备了，v2 集合根（meta.json、媒体）也只属于本设备。旧 profile
/// 目录空了一并删除——否则后来的设备会看到两个同名 profile，判不出该关联哪个。
Future<void> srsRemoveOwnProfileFolder(
  SyncAssetStore store, {
  required String profileUid,
  required String deviceId,
  String? v2Device,
}) async {
  final String ns = await store.ensureNamespace(kSrsSync2Namespace);
  AssetEntry? profile;
  for (final AssetEntry e in await store.listChildren(ns)) {
    if (e.isFolder && e.name == profileUid) profile = e;
  }
  if (profile == null) return;
  bool foreign = false;
  for (final AssetEntry e in await store.listChildren(profile.id)) {
    if (e.isFolder && srsWriterOfDevice(e.name, deviceId)) {
      await store.deleteAsset(e.id, isFolder: true);
    } else if (e.isFolder && e.name == kSrsSync2Folder) {
      if (!await _removeOwnV2Device(store, e, v2Device)) foreign = true;
    } else {
      foreign = true;
    }
  }
  if (!foreign) await store.deleteAsset(profile.id, isFolder: true);
}

/// 删掉 v2 集合根里本设备的设备目录；返回 v2 根是否只剩本设备的东西（已整个删掉）。
Future<bool> _removeOwnV2Device(
  SyncAssetStore store,
  AssetEntry v2,
  String? v2Device,
) async {
  bool others = false;
  for (final AssetEntry e in await store.listChildren(v2.id)) {
    if (!e.isFolder || e.name != 'devices') continue;
    for (final AssetEntry d in await store.listChildren(e.id)) {
      if (d.isFolder && d.name == v2Device) {
        await store.deleteAsset(d.id, isFolder: true);
      } else {
        others = true;
      }
    }
  }
  if (others) return false;
  await store.deleteAsset(v2.id, isFolder: true);
  return true;
}

/// 一次 profile 关联的结果：继续同步用的 store（采用了目录里已有的 uid 时是按新身份重开的那个）。
class SrsProfileLinkOutcome {
  const SrsProfileLinkOutcome(
    this.store, {
    this.choose,
    this.localHasNotes = false,
    this.linked = false,
  });

  final SrsDbStore store;

  /// 已经与目录里别的设备关联上了（[SrsProfileLinkKeep.linked]，或这一轮刚采用了对方的 uid）：之后的判定不会再变。
  final bool linked;

  /// 非 null = 没法自动关联，要用户在这些候选里选（[SrsProfileLinkChoose]）。
  final List<SrsRemoteProfile>? choose;

  /// 判定时本机 profile 有没有用户笔记（有 = 选定后要并入，而不是直接改用）。
  final bool localHasNotes;
}

/// 同步前的 profile 关联与同步后的说明文件发布（铁律 E，见文件头）。
abstract interface class SrsProfileLinker {
  /// 跑引擎之前：决定本机 profile 是否改用目录里已有的 uid（必要时采用并重开 store）。
  Future<SrsProfileLinkOutcome> link(SyncAssetStore backend, SrsDbStore store);

  /// 用户在 [SrsProfileLinkChoose] 的候选里选了 [uid]：本机 profile 改用它（本机有用户笔记时并入），返回按新身份
  /// 重开的 store。本设备在旧 uid 下的同步目录由之后的 [link] 清掉。
  Future<SrsDbStore> adopt(SrsDbStore store, String uid);

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
    this.mediaRoot,
    this.onError,
  });

  /// 全部 profile 的 SRS 媒体根（`<support>/srs_media`）：并入时把旧 uid 的媒体与共享样式文件搬到新 uid 下。
  final Future<Directory?> Function()? mediaRoot;

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
    // 上次并入做到一半进程就退出了（标记还在 srs.db）：先用同样的参数做完，再按新身份判定。
    final SrsDbStore? resumed = await _resumePendingMerges(store);
    if (resumed != null) return SrsProfileLinkOutcome(resumed, linked: true);
    final List<SrsRemoteProfile> remote = await srsListRemoteProfiles(backend);
    // 本设备的孤儿目录：本设备**换 uid 时离开的**旧 uid（[kSrsRetiredProfileUidsKey]，例如用户在冲突弹窗里选了
    // 别的 profile），且只有本设备写过、本机也没有 profile 再用它。本机判定本来就不把它算作别人的数据，但别的设备会
    // 一直把它当成又一个有数据的候选，所以清掉。没记在退役名单里的一律不碰：删掉的 profile、恢复旧备份前的 uid
    // 同样「只有本设备写过、本机没有」，它们在同步目录里的那份可能是唯一的副本。
    final Set<String> retired = await _readMetaSet(
      store,
      kSrsRetiredV2DevicesKey,
    );
    final Set<String> retiredUids = await _readMetaSet(
      store,
      kSrsRetiredProfileUidsKey,
    );
    for (final SrsRemoteProfile r in <SrsRemoteProfile>[...remote]) {
      if (r.uid == store.profileUid || r.writers.isEmpty) continue;
      if (!retiredUids.contains(r.uid)) continue;
      String? v2Device;
      bool ownOnly = true;
      for (final String w in r.writers) {
        if (srsWriterOfDevice(w, store.deviceId)) continue;
        final String? device = w.startsWith('v2:') ? w.substring(3) : null;
        if (device != null &&
            (device == store.sync2Device || retired.contains(device))) {
          v2Device = device;
          continue;
        }
        ownOnly = false;
        break;
      }
      if (!ownOnly || await _uidTakenLocally(r.uid)) continue;
      try {
        await srsRemoveOwnProfileFolder(
          backend,
          profileUid: r.uid,
          deviceId: store.deviceId,
          v2Device: v2Device,
        );
        remote.remove(r);
      } catch (e, stack) {
        // 删不掉下一轮再删；本机判定本来就不把它算作别人的数据。
        onError?.call('SrsProfileLinker.cleanup', e, stack);
      }
    }
    final bool localHasNotes = await store.hasUserNotes();
    final SrsProfileLinkDecision decision = srsDecideProfileLink(
      localUid: store.profileUid,
      localName: await _nameOf(store.profileUid),
      deviceId: store.deviceId,
      localHasNotes: localHasNotes,
      localProfileCount: await _profileCount(),
      remote: remote,
      v2Device: store.sync2Device,
    );
    switch (decision) {
      case SrsProfileLinkKeep(:final bool linked):
        return SrsProfileLinkOutcome(store, linked: linked);
      case SrsProfileLinkChoose(:final List<SrsRemoteProfile> candidates):
        return SrsProfileLinkOutcome(
          store,
          choose: candidates,
          localHasNotes: localHasNotes,
        );
      case SrsProfileLinkAdopt(:final String uid):
        // 那个 uid 已是本机另一个 profile（profiles.uid 唯一）：用户切过去就能同步，不动。
        if (await _uidTakenLocally(uid)) return SrsProfileLinkOutcome(store);
        final SrsDbStore adopted = await _switchUid(store, uid, merge: false);
        try {
          await srsRemoveOwnProfileFolder(
            backend,
            profileUid: store.profileUid,
            deviceId: store.deviceId,
            v2Device: store.sync2Device,
          );
        } catch (e, stack) {
          // 孤儿目录只有本设备的内置行批次，删不掉不影响同步。
          onError?.call('SrsProfileLinker.cleanup', e, stack);
        }
        return SrsProfileLinkOutcome(adopted, linked: true);
    }
  }

  @override
  Future<SrsDbStore> adopt(SrsDbStore store, String uid) async {
    if (uid == store.profileUid) return store;
    if (await _uidTakenLocally(uid)) {
      throw StateError('profile uid $uid is already another local profile');
    }
    return _switchUid(store, uid, merge: await store.hasUserNotes());
  }

  /// srs.db `srs_meta` 里 [key] 存的字符串集合（JSON 数组；没有 / 坏了为空）。
  Future<Set<String>> _readMetaSet(SrsDbStore store, String key) async {
    final QueryRow? row = await store.db
        .customSelect(
          'SELECT value FROM srs_meta WHERE key = ?',
          variables: <Variable<Object>>[Variable<String>(key)],
        )
        .getSingleOrNull();
    final String? raw = row?.read<String>('value');
    if (raw == null) return <String>{};
    try {
      final Object? j = jsonDecode(raw);
      return j is List ? <String>{for (final Object? x in j) '$x'} : <String>{};
    } on FormatException {
      return <String>{};
    }
  }

  /// 往 srs.db `srs_meta` 的字符串集合 [key] 里加 [value]（已有就不写）。
  Future<void> _addToMetaSet(SrsDbStore store, String key, String value) async {
    final Set<String> values = await _readMetaSet(store, key);
    if (!values.add(value)) return;
    await store.db.customStatement(
      'INSERT OR REPLACE INTO srs_meta (key, value) VALUES (?, ?)',
      <Object>[key, jsonEncode(values.toList())],
    );
  }

  /// 从 srs.db `srs_meta` 的字符串集合 [key] 里去掉 [value]。
  Future<void> _removeFromMetaSet(
    SrsDbStore store,
    String key,
    String value,
  ) async {
    final Set<String> values = await _readMetaSet(store, key);
    if (!values.remove(value)) return;
    await store.db.customStatement(
      'INSERT OR REPLACE INTO srs_meta (key, value) VALUES (?, ?)',
      <Object>[key, jsonEncode(values.toList())],
    );
  }

  /// 换 uid 之前记下本机在旧集合里的 v2 设备身份（[kSrsRetiredV2DevicesKey]）：并入会删掉旧 uid 的本机身份行，
  /// 之后（含中断后续做的并入）就再也查不到了。只凭它不会删任何目录，见 [kSrsRetiredProfileUidsKey]。
  Future<void> _retireV2Device(SrsDbStore store) async {
    final String? device = store.sync2Device;
    if (device != null) {
      await _addToMetaSet(store, kSrsRetiredV2DevicesKey, device);
    }
  }

  /// 当前 profile 有没做完的并入（[srsPendingProfileMerges]）：做完并按新身份重开 store；没有返回 null。
  Future<SrsDbStore?> _resumePendingMerges(SrsDbStore store) async {
    final int profileId = await activeProfileId();
    bool resumed = false;
    for (final SrsPendingProfileMerge m in await srsPendingProfileMerges(
      store.db,
    )) {
      if (m.profileId != profileId) continue;
      await srsMergeProfileUid(
        db,
        store.db,
        core: store.core,
        profileId: m.profileId,
        oldUid: m.oldUid,
        newUid: m.newUid,
        deviceId: store.deviceId,
        mediaRoot: await mediaRoot?.call(),
      );
      await _addToMetaSet(store, kSrsRetiredProfileUidsKey, m.oldUid);
      resumed = true;
    }
    if (!resumed) return null;
    final SrsDbStore? reopened = await reopenStore();
    if (reopened == null) {
      throw StateError('store did not reopen after resuming a profile merge');
    }
    await reopened.afterRestore(freshIncarnation: true);
    return reopened;
  }

  /// 当前 profile 改用 [uid] 并按新身份重开 store。[merge]：本机有用户笔记，并入（[srsMergeProfileUid]）而不是
  /// 直接改用（[srsAdoptProfileUid] 会删掉旧 uid 下的全部行，只适用于只有内置行的 profile）。
  Future<SrsDbStore> _switchUid(
    SrsDbStore store,
    String uid, {
    required bool merge,
  }) async {
    final int profileId = await activeProfileId();
    final String oldUid = store.profileUid;
    await _retireV2Device(store);
    if (merge) {
      await srsMergeProfileUid(
        db,
        store.db,
        core: store.core,
        profileId: profileId,
        oldUid: oldUid,
        newUid: uid,
        deviceId: store.deviceId,
        mediaRoot: await mediaRoot?.call(),
      );
    } else {
      await srsAdoptProfileUid(
        db,
        store.db,
        profileId: profileId,
        oldUid: oldUid,
        newUid: uid,
      );
    }
    // 主库已经改用 [uid]：旧 uid 的数据已在新 uid 下（并入）或本来只有内置行（采用），它在同步目录里的本设备
    // 目录可以由之后的 [link] 清掉。
    await _addToMetaSet(store, kSrsRetiredProfileUidsKey, oldUid);
    try {
      final SrsDbStore? reopened = await reopenStore();
      if (reopened == null || reopened.profileUid != uid) {
        throw StateError('store did not reopen under the adopted profile');
      }
      // 新写入者化身：本设备可能早年在这个 profile 下写过（重装等），不沿用旧 writerId。
      await reopened.afterRestore(freshIncarnation: true);
      return reopened;
    } catch (_) {
      if (!merge) {
        // 采用要么整体成功、要么回到原样（旧 uid 下只有内置行 / 本机状态，重开时重建）。
        await srsAdoptProfileUid(
          db,
          store.db,
          profileId: profileId,
          oldUid: uid,
          newUid: oldUid,
        );
        await _removeFromMetaSet(store, kSrsRetiredProfileUidsKey, oldUid);
        await reopenStore();
      }
      rethrow;
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
    final String? device = store.sync2Device;
    if (device == null) return;
    final String sig = '${store.profileUid}|$device|$name|$hasNotes';
    if (_published[directoryKey] == sig) return;
    await srsPublishProfileInfo(
      backend,
      profileUid: store.profileUid,
      writerId: device,
      name: name,
      hasNotes: hasNotes,
    );
    _published[directoryKey] = sig;
  }
}
