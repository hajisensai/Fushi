/// 复习（SRS）同步的 profile 关联（docs/specs/2026-10-14-fushi-srs-design.md 铁律 E）。
///
/// 同步目录按 profile 的全局身份分区：`fushi-srs/<profileUid>/<writerId>/...`。profileUid 是每台
/// 设备第一次打开 SRS 时**本机随机生成**的（`FushiDatabase.profileUidOf`），所以两台各自装好的
/// 设备即使都叫「默认」，也各写各的 `<profileUid>` 目录、谁也读不到谁——互联 / 云盘看起来「连上了、
/// 同步成功了」，复习数据却从不互通。设计里要求的「新设备第一次接入同步时关联到已有的 profile」
/// 此前只在备份恢复里做了，同步路径上没有。
///
/// 本文件补上同步路径的关联：
/// - 每个写入者在自己的目录里放一份 [kSrsProfileInfoName]（profile 名 + 有没有用户数据），
///   别的设备据此认出「同一个 profile」；
/// - [srsDecideProfileLink] 是纯函数：给定本机 profile 与目录里已有的 profile，决定保持 / 自动采用
///   对方 uid / 交给用户选。自动采用只在答案唯一时发生：本机 profile **没有用户数据**（只有内置行，
///   内置行 ID 由 uid 派生、换 uid 后随新 uid 重新生成），且目录里恰好一个有数据的同一 profile；
/// - 答案不唯一时**不静默保持**（以前那样做，三台设备各自随机生成 uid、都叫「Default」时，新设备永远按
///   自己的空 profile 同步，复习数据从不互通、也没有任何提示）：目录里有多个有数据的候选，或本机与对方都有
///   用户笔记，交给用户选采用哪一个（[SrsProfileLinkChoose]）；迁移带过来的半截并入在 [SrsProfileLinker.link] 开头续做
///   （srs_profile_merge.dart）；
/// - 新代（协议 4，G9-5）里「采用 / 并入」不再改 profile 的 uid：位置上每个 `fushi-srs/<目录>/` 按它 `v4/meta.json`
///   （没有新根时退到旧根 `v3/meta.json`）的 `collection` 认成一个集合（[SrsRemoteProfile.collection]），选定之后调内核
///   `collection_adopt`（[SrsDbProfileLinker]）：本机是空集合且目录名较大 → 换绑到对方（`bound`）；否则按 D27「目录名大的
///   并入小的」写 `Join`——本机目录名大时本机改绑到对方（`joined`，`rebound`），本机目录名小时对方并进本机（`joined`，
///   绑定不动）。本机自己的集合与已经并进本机的集合（`collection_info` 的 `joins`）不再算候选；
/// - **吸收方向的发现**（本机目录名小、对方并进本机）：那条 `Join` 在本机集合的根里，对方集合的设备只读自己的根、
///   看不到它。本机在对方集合的目录里放一个并入提示（[kSrsJoinHintPrefix]，设计 §5.4 第 3 条「B 的根里留一个指向
///   A 的提示，放独立文件、不进 meta.json」）；对方设备每轮关联时读自己目录里的提示，提示指向的集合确实在位置上
///   （目录名、`meta.json` 的集合标识都对得上）且目录名比自己小，就把它当成候选**再问一次用户**（D25），即使自己的
///   集合里已经有别的设备（[srsDecideProfileLink] 的「已关联」不挡提示）。提示没有签名，伪造它最多让对方多问一次，
///   跟不跟由用户定；确认之后对方按 D27 改绑到本机的集合，两边收敛。提示从持久状态派生：集合里每台设备每轮发布时
///   按本机集合日志里受信、带目录名的 `Join` 在当前位置上补写缺的提示（[SrsDbProfileLinker.publish]），不只靠认领那一刻
///   的一次写入——写失败、换了位置、集合里别的设备都覆盖到；本机改绑进别的集合（`rebound`）时同样在离开的旧目录里放
///   指向新集合的提示，旧集合里没被问过的设备据此跟过来；
/// - 没有用户笔记的 profile 不算候选：它所在的设备会来采用有数据的一方；
/// - 双方都没有用户笔记时按 uid 字典序只让一边采用，不会两边互相采用来回翻；
/// - 已经选定要并入别的 uid、只是并入暂缓着的写入者（说明文件里的 `mergingInto`，BUG-4296）不再算它旧 profile 的
///   成员：它按旧 uid 照常同步只是为了把缺的日志收进来，别的设备不能再把这个旧 profile 当成候选并进去。
///
/// 只读写 [SyncAssetStore]，与后端无关（互联 / 云盘同一份格式）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/srs/srs_collection_binding.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_data.dart'
    show
        SrsMetaSet,
        SrsProfileMergeFinish,
        srsEditMetaSet,
        srsFinishProfileMerge;
import 'package:fushi_engine/srs/srs_profile_merge.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show
        kSrsSync2Folder,
        kSrsSync2Namespace,
        kSrsSync2V1Folder,
        srsLocationDirOf;
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart' show kSrs4Root;
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show SrsCore, SrsProfileUnboundException;

/// srs.db `srs_meta`：本设备改用别的 uid 之前用过的同步 v2 设备身份（JSON 数组）。换 uid 后本机在新集合里是新的
/// v2 设备，旧集合的本机身份行也随并入删掉了——不记下来就认不出同步目录里那个旧 uid 目录是自己留下的孤儿。
/// 只存本机 srs.db（不进偏好表，不随偏好同步到别的设备）。读写都经内核的 `meta_set_edit`（[srsEditMetaSet]，
/// [SrsMetaSet.retiredDevices]）。
const String kSrsRetiredV2DevicesKey = 'srs_retired_v2_devices';

/// srs.db `srs_meta`：本设备**改用别的 uid** 时离开的旧 profile uid（JSON 数组）。孤儿目录清理只认这里记着的 uid：
/// 只有换 uid（采用 / 并入）才保证旧 uid 的数据已经搬到了新 uid 下。「只有本设备写过、本机又没有这个 uid 的
/// profile」本身不是证据——删 profile（srs_profile_cleanup.dart 明确约定远端已同步的集合不动、只删本机）、恢复
/// 旧备份之后都是这个样子，那时同步目录里的那份可能是唯一的副本。读写都经内核的 `meta_set_edit`
/// （[SrsMetaSet.retiredUids]）。
const String kSrsRetiredProfileUidsKey = 'srs_retired_profile_uids';

/// 写入者目录里的 profile 说明文件。同步引擎只认 `batch-*` / `snapshot-*` / `cursor` / `probe`，
/// 其余文件名忽略。
const String kSrsProfileInfoName = 'profile.json';

/// 并入提示的文件名前缀（`fushi-srs/<被并入的集合的目录>/joined-into-<并入方集合标识>.json`，内容
/// `{"v": 1, "collection": <并入方集合标识>, "dir": <并入方目录名>}`）。放在集合目录这一级、不在 `v4/` 里：同步一轮只读
/// `v4/` / `v3/` / `v2/`，旧版本列目录时也只认文件夹，都不会把它当成别的东西。见文件头「吸收方向的发现」。
const String kSrsJoinHintPrefix = 'joined-into-';

/// 位置上读来的说明 / meta / 提示文件最多读多大（外来数据，不可信）：都是几十字节的 JSON。
const int kSrsLocationJsonMaxBytes = 64 * 1024;

/// 一个并入提示：别的设备的集合 [collection]（位置目录名 [dir]）已经把这个集合并了进去。
class SrsJoinHint {
  const SrsJoinHint({required this.collection, required this.dir});

  final String collection;
  final String dir;
}

/// 同步目录里的一个 profile（`fushi-srs/<目录名>/`）。
class SrsRemoteProfile {
  const SrsRemoteProfile({
    required this.uid,
    required this.writers,
    this.names = const <String>{},
    this.hasNotes,
    this.updatedAt,
    this.devices = const <String>[],
    this.noteCount,
    this.mergingInto = const <String, String>{},
    this.collection,
    this.joinHints = const <SrsJoinHint>[],
  });

  /// 显示名：说明文件里报的第一个名字，没有时用 uid。
  String get displayName => names.isEmpty ? uid : names.first;

  /// 位置目录名（`fushi-srs/<它>/`）。协议 3 时代它就是 profile uid（字段名沿用）；新代里是集合的目录名（内核
  /// `identity` 的 `dir`），本机 profile 的 uid 不随关联改变。
  final String uid;

  /// 这个目录里的集合标识：`v4/meta.json` 的 `collection`，没有新根时取旧根 `v3/meta.json` 的；都读不到为 null（只有
  /// 说明文件、还没立过根的目录），这样的目录不能认领。
  final String? collection;

  /// 目录里的并入提示（[kSrsJoinHintPrefix]）：别的集合已经把这个集合并了进去。
  final List<SrsJoinHint> joinHints;

  /// 目录里的写入者（`<deviceId>#<化身号>`）。
  final List<String> writers;

  /// 各写入者说明文件里最新的修改时刻（毫秒；后端不给或没有说明文件时为 null）。让用户分辨候选用。
  final int? updatedAt;

  /// 各写入者 [kSrsProfileInfoName] 里报的 profile 名（旧版本不写说明文件时为空）。
  final Set<String> names;

  /// 有没有写入者报告过「有用户笔记」；没有任何说明文件时为 null（未知）。
  final bool? hasNotes;

  /// 各写入者说明文件里报的设备人读名（昵称或型号，按出现顺序去重；旧版本不报时为空）。让用户分辨候选用。
  final List<String> devices;

  /// 各写入者报的用户笔记数里最大的那个（同一 profile 各设备看到的是同一份笔记，取最新最全的一份）；没人报时为 null。
  final int? noteCount;

  /// 写入者 → 它已经选定要并入的 uid（说明文件的 `mergingInto`，[srsPublishProfileInfo]）：那台设备的用户已经决定离开
  /// 这个 profile，只是并入暂缓（[SrsDeferredProfileMerge]）期间还按这个 uid 同步。[srsDecideProfileLink] 不把这些
  /// 写入者算作这个 profile 的成员（BUG-4296）。旧版本不写这个键：空，按以前那样算。
  final Map<String, String> mergingInto;

  /// 不在离开中的写入者（[writers] 去掉 [mergingInto] 里的）。
  Iterable<String> get stayingWriters =>
      writers.where((String w) => !mergingInto.containsKey(w));
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
/// - [localHasNotes]：本机 profile 有没有用户数据（[SrsDbStore.hasUserData]：笔记、自建牌组、改过的预设…，不只是
///   笔记；参数名沿用旧名）。为假时可能判成采用，采用会删掉本机旧 uid 的全部行。
/// - [settled]：本机 profile 已经在**别的**同步位置上定下了集合（[SrsCollectionBinding.settledElsewhere]）。为真时
///   不再返回 [SrsProfileLinkAdopt]：唯一的有数据候选也交给用户选（[SrsProfileLinkChoose]），候选全空时保持——一台设备的
///   几个位置各自判出不同答案时不来回改 uid。
/// - [localProfileCount]：本机 profile 总数。目录里的 profile 都没有说明文件（旧版本写的）、
///   名字对不上时，只有「两边都只有一个 profile」才把唯一那个当成同一个。
///
/// 新代（[ownCollection] 非 null，[localUid] 是本机集合的目录名）：集合标识等于 [ownCollection] 或在 [joined]（已经并进
/// 本机集合的）里的目录、读不出集合标识的目录（没立过根，认领不了）不算候选；本机目录里有指向别的集合的并入提示（[SrsRemoteProfile.joinHints]）、提示的集合在
/// [remote] 里对得上且目录名比本机小时，直接交给用户再确认一次（D25），不看「已关联」。
SrsProfileLinkDecision srsDecideProfileLink({
  required String localUid,
  required String localName,
  required String deviceId,
  required bool localHasNotes,
  required int localProfileCount,
  required List<SrsRemoteProfile> remote,
  String? v2Device,
  bool settled = false,
  String? ownCollection,
  Set<String> joined = const <String>{},
}) {
  bool own(String w) =>
      srsWriterOfDevice(w, deviceId) ||
      (v2Device != null && w == srsV2WriterName(v2Device));
  if (ownCollection != null) {
    remote = <SrsRemoteProfile>[
      for (final SrsRemoteProfile r in remote)
        if (r.uid == localUid ||
            (r.collection != null &&
                r.collection != ownCollection &&
                !joined.contains(r.collection)))
          r,
    ];
    final SrsRemoteProfile? self = remote
        .where((SrsRemoteProfile r) => r.uid == localUid)
        .firstOrNull;
    final List<SrsRemoteProfile> hinted = <SrsRemoteProfile>[
      for (final SrsRemoteProfile r in remote)
        if (r.uid != localUid &&
            r.uid.compareTo(localUid) < 0 &&
            r.collection != null &&
            (self?.joinHints.any(
                  (SrsJoinHint h) =>
                      h.dir == r.uid && h.collection == r.collection,
                ) ??
                false))
          r,
    ]..sort((SrsRemoteProfile a, SrsRemoteProfile b) => a.uid.compareTo(b.uid));
    if (hinted.isNotEmpty) return SrsProfileLinkChoose(hinted);
  }
  // 别的设备里只算留在这个 profile 的：已经选定并入别处、并入暂缓着的写入者（[SrsRemoteProfile.mergingInto]）不算
  // ——否则对方采用了本机的 profile 之后、并入做完之前，本机还会被问要不要并进对方已经放弃的那个 profile，选了两边
  // 就分叉（BUG-4296）。
  bool otherMember(SrsRemoteProfile r) =>
      r.stayingWriters.any((String w) => !own(w));
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
  if (mine != null && otherMember(mine)) {
    return const SrsProfileLinkKeep(linked: true);
  }
  // 只看「不全是本设备写的」profile：本设备旧化身留下的目录不算别人的数据。
  final List<SrsRemoteProfile> foreign = <SrsRemoteProfile>[
    for (final SrsRemoteProfile r in others)
      if (otherMember(r)) r,
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
    if (localHasNotes || settled) return const SrsProfileLinkKeep();
    final String smallest = pool
        .map((SrsRemoteProfile r) => r.uid)
        .reduce((String a, String b) => a.compareTo(b) <= 0 ? a : b);
    return smallest.compareTo(localUid) < 0
        ? SrsProfileLinkAdopt(smallest)
        : const SrsProfileLinkKeep();
  }
  // 本机是空的、有数据的候选恰好一个：答案唯一，直接采用。
  if (!localHasNotes && !settled && withData.length == 1) {
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
    final List<String> devices = <String>[];
    int? noteCount;
    final Map<String, String> mergingInto = <String, String>{};
    String? v4Collection;
    String? v3Collection;
    final List<SrsJoinHint> hints = <SrsJoinHint>[];
    Future<void> readInfo(String writer, String folder) async {
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
      final Object? device = info['device'];
      if (device is String && device.isNotEmpty && !devices.contains(device)) {
        devices.add(device);
      }
      final Object? count = info['notes'];
      if (count is int && (noteCount == null || count > noteCount!)) {
        noteCount = count;
      }
      final Object? into = info['mergingInto'];
      if (into is String && into.isNotEmpty && into != p.name) {
        mergingInto[writer] = into;
      }
    }

    for (final AssetEntry w in await store.listChildren(p.id)) {
      if (!w.isFolder) {
        final SrsJoinHint? hint = await _readJoinHint(store, w, tempDir);
        if (hint != null) hints.add(hint);
        continue;
      }
      // 新代集合根 `v4/`（G8-7）不是写入者目录；它下面的设备只有 head、没有 `profile.json`。它的 `meta.json` 给出集合标识。
      if (w.name == kSrs4Root) {
        v4Collection = await _readCollection(store, w.id, tempDir);
        continue;
      }
      if (w.name == kSrsSync2Folder) {
        v3Collection ??= await _readCollection(store, w.id, tempDir);
      }
      if (w.name == kSrsSync2Folder || w.name == kSrsSync2V1Folder) {
        // 同步 v2：`v3/devices/<设备>/profile.json`（协议 2）；还没迁移的位置在 `v2/devices/` 下（协议 1，同一台
        // 设备两边都有时只算一次）。
        for (final AssetEntry d in await store.listChildren(w.id)) {
          if (!d.isFolder || d.name != 'devices') continue;
          for (final AssetEntry dev in await store.listChildren(d.id)) {
            if (!dev.isFolder) continue;
            final String name = srsV2WriterName(dev.name);
            if (!writers.contains(name)) writers.add(name);
            await readInfo(name, dev.id);
          }
        }
        continue;
      }
      writers.add(w.name);
      await readInfo(w.name, w.id);
    }
    out.add(
      SrsRemoteProfile(
        uid: p.name,
        writers: writers,
        names: names,
        hasNotes: hasNotes,
        updatedAt: updatedAt,
        devices: devices,
        noteCount: noteCount,
        mergingInto: mergingInto,
        collection: v4Collection ?? v3Collection,
        joinHints: hints,
      ),
    );
  }
  return out;
}

/// 集合根 [rootFolder]（`v4/` 或旧根 `v3/`）的 `meta.json` 里的集合标识；没有 / 读不出 / 不是字符串为 null。
Future<String?> _readCollection(
  SyncAssetStore store,
  String rootFolder,
  Directory? tempDir,
) async {
  final Map<String, Object?>? meta = (await _readJsonAsset(
    store,
    await store.findAsset(rootFolder, 'meta.json'),
    tempDir,
  )).$1;
  final Object? c = meta?['collection'];
  return c is String && c.isNotEmpty ? c : null;
}

/// [file] 是并入提示（[kSrsJoinHintPrefix]）就读出来；不是、读不出或内容不对为 null。
Future<SrsJoinHint?> _readJoinHint(
  SyncAssetStore store,
  AssetEntry file,
  Directory? tempDir,
) async {
  if (!file.name.startsWith(kSrsJoinHintPrefix) ||
      !file.name.endsWith('.json')) {
    return null;
  }
  final Map<String, Object?>? j = (await _readJsonAsset(
    store,
    file,
    tempDir,
  )).$1;
  final Object? collection = j?['collection'];
  final Object? dir = j?['dir'];
  if (collection is! String || collection.isEmpty) return null;
  if (dir is! String || dir.isEmpty) return null;
  // 文件名里的集合标识与内容不符 = 坏文件。
  if (file.name != '$kSrsJoinHintPrefix$collection.json') return null;
  return SrsJoinHint(collection: collection, dir: dir);
}

/// 在被并入的集合的目录 `fushi-srs/<[targetDir]>/` 里放一个并入提示：集合 [collection]（目录名 [dir]）已经把它并了进去
/// （见文件头「吸收方向的发现」）。同名文件已在就先删（Google Drive 允许同名多文件），内容只由两个集合标识决定，
/// 几台设备各写一次结果相同。
Future<void> srsWriteJoinHint(
  SyncAssetStore store, {
  required String targetDir,
  required String collection,
  required String dir,
  Directory? tempDir,
}) async {
  final String ns = await store.ensureNamespace(kSrsSync2Namespace);
  final String target = await store.ensureFolder(ns, targetDir);
  final String name = '$kSrsJoinHintPrefix$collection.json';
  final AssetEntry? old = await store.findAsset(target, name);
  if (old != null) await store.deleteAsset(old.id);
  final Directory tmp = await (tempDir ?? Directory.systemTemp).createTemp(
    'fushi_srs_join_hint_',
  );
  try {
    final File f = File('${tmp.path}${Platform.pathSeparator}hint');
    await f.writeAsString(
      jsonEncode(<String, Object?>{
        'v': 1,
        'collection': collection,
        'dir': dir,
      }),
      flush: true,
    );
    await store.putAsset(target, name, f);
  } finally {
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // 临时目录留给系统清理。
    }
  }
}

/// 一个写入者的说明文件内容与它的修改时刻（毫秒）。
Future<(Map<String, Object?>?, int?)> _readInfo(
  SyncAssetStore store,
  String writerFolder,
  Directory? tempDir,
) async => _readJsonAsset(
  store,
  await store.findAsset(writerFolder, kSrsProfileInfoName),
  tempDir,
);

/// 位置上一个 JSON 小文件 [a] 的内容（对象）与修改时刻（毫秒）。外来数据：大于 [kSrsLocationJsonMaxBytes]（后端报了
/// 大小时）、半截、坏文件、不是对象都当没有。
Future<(Map<String, Object?>?, int?)> _readJsonAsset(
  SyncAssetStore store,
  AssetEntry? a,
  Directory? tempDir,
) async {
  if (a == null) return (null, null);
  final int? size = a.sizeBytes;
  if (size != null && size > kSrsLocationJsonMaxBytes) return (null, null);
  final int? at = a.modifiedAt;
  final Directory dir = await (tempDir ?? Directory.systemTemp).createTemp(
    'fushi_srs_profile_',
  );
  try {
    final File f = File('${dir.path}${Platform.pathSeparator}info');
    await store.getAsset(a.id, f);
    if (await f.length() > kSrsLocationJsonMaxBytes) return (null, null);
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

/// 在本机的同步 v2 设备目录（`fushi-srs/<uid>/v3/devices/<设备>/`）里写（覆盖）profile 说明文件。
///
/// [mergingInto]：本设备已经选定把这个 profile 并入哪个 uid、并入还没做完（srs.db 里的并入标记还在，
/// [srsPendingProfileMerges]）。别的设备据此不再把这个 profile 当成候选（[SrsRemoteProfile.mergingInto]）。
///
/// [dir]：集合的位置目录名（内核 `identity` 的 `dir`）；不给按 [profileUid] 向内核要（协议 3 口径，二者相同）。
Future<void> srsPublishProfileInfo(
  SyncAssetStore store, {
  required String profileUid,
  String? dir,
  required String writerId,
  required String name,
  required bool hasNotes,
  String? device,
  int? noteCount,
  String? mergingInto,
  Directory? tempDir,
}) async {
  final String ns = await store.ensureNamespace(kSrsSync2Namespace);
  final String profile = await store.ensureFolder(
    ns,
    dir ?? srsLocationDirOf(profileUid),
  );
  final String v2 = await store.ensureFolder(profile, kSrsSync2Folder);
  final String devices = await store.ensureFolder(v2, 'devices');
  final String writer = await store.ensureFolder(devices, writerId);
  // 允许同名多文件的后端（Google Drive）先删旧的再写，避免读到旧的那份。
  final AssetEntry? old = await store.findAsset(writer, kSrsProfileInfoName);
  if (old != null) await store.deleteAsset(old.id);
  final Directory tmp = await (tempDir ?? Directory.systemTemp).createTemp(
    'fushi_srs_profile_',
  );
  try {
    final File f = File('${tmp.path}${Platform.pathSeparator}info');
    await f.writeAsString(
      // `device` / `notes`（反馈 dOv8AdJ6yV）、`mergingInto`（BUG-4296）是附加键：旧读者只认 name / hasNotes，
      // 忽略它们（不认识 `mergingInto` 的旧版本照旧把这个 profile 当候选，与以前一样）。
      jsonEncode(<String, Object?>{
        'v': 1,
        'name': name,
        'hasNotes': hasNotes,
        'device': ?device,
        'notes': ?noteCount,
        'mergingInto': ?mergingInto,
      }),
      flush: true,
    );
    await store.putAsset(writer, kSrsProfileInfoName, f);
  } finally {
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // 临时目录留给系统清理。
    }
  }
}

/// 采用别的 uid 之后，删掉本设备在旧 uid 下留下的目录：旧格式的写入者目录（`<设备>#n`）与同步 v2 的设备目录
/// （`v2/devices/<[v2Device]>`）。[srsDecideProfileLink] 只在旧目录里没有别的设备时才会决定采用，所以删的只是
/// 本设备自己的孤儿目录；`v2/devices` 下没有别的设备了，v2 集合根（meta.json、媒体）也只属于本设备。旧 profile
/// 目录空了一并删除——否则后来的设备会看到两个同名 profile，判不出该关联哪个。
///
/// 新代集合根 `v4/`（[kSrs4Root]，G9-5）：与 v2 根同形（`devices/<设备>/…` + `meta.json` + 媒体），先于写入者目录判，
/// 绝不当成旧格式的写入者目录。只删本机新代身份的设备目录 `v4/devices/<[v4Device]>`，**根本身永远留着**（连同
/// profile 目录）：`meta.json` 是这个集合在位置上的身份，别的设备可能已经按它换绑（`collection_adopt` 结论 `bound`）、
/// 只是还没发布自己的设备目录——只剩本机目录就删根，它下一轮就看不到这个集合了。[v4Device] 不给 = 本机在这个集合里
/// 没有新代身份：`v4/` 一个字节不碰。[dir] 给了就按它找目录（新代：集合的位置目录名），否则按 [profileUid] 向内核要。
/// 目录里的并入提示（[kSrsJoinHintPrefix]）与别的文件一样算「别人的东西」，有它就不删目录。
Future<void> srsRemoveOwnProfileFolder(
  SyncAssetStore store, {
  required String profileUid,
  String? dir,
  required String deviceId,
  String? v2Device,
  String? v4Device,
}) async {
  final String ns = await store.ensureNamespace(kSrsSync2Namespace);
  AssetEntry? profile;
  final String folder = dir ?? srsLocationDirOf(profileUid);
  for (final AssetEntry e in await store.listChildren(ns)) {
    if (e.isFolder && e.name == folder) profile = e;
  }
  if (profile == null) return;
  bool foreign = false;
  for (final AssetEntry e in await store.listChildren(profile.id)) {
    if (e.isFolder && e.name == kSrs4Root) {
      if (v4Device != null) await _removeOwnV4Device(store, e, v4Device);
      foreign = true;
    } else if (e.isFolder && srsWriterOfDevice(e.name, deviceId)) {
      await store.deleteAsset(e.id, isFolder: true);
    } else if (e.isFolder &&
        (e.name == kSrsSync2Folder || e.name == kSrsSync2V1Folder)) {
      if (!await _removeOwnV2Device(store, e, v2Device)) foreign = true;
    } else {
      foreign = true;
    }
  }
  if (!foreign) await store.deleteAsset(profile.id, isFolder: true);
}

/// 删掉新代集合根 [v4] 里本机新代身份 [v4Device] 的设备目录 `devices/<v4Device>`；根与别的一切不动（见
/// [srsRemoveOwnProfileFolder]）。
Future<void> _removeOwnV4Device(
  SyncAssetStore store,
  AssetEntry v4,
  String v4Device,
) async {
  for (final AssetEntry e in await store.listChildren(v4.id)) {
    if (!e.isFolder || e.name != 'devices') continue;
    for (final AssetEntry d in await store.listChildren(e.id)) {
      if (d.isFolder && d.name == v4Device) {
        await store.deleteAsset(d.id, isFolder: true);
      }
    }
  }
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
    this.localNoteCount = 0,
    this.linked = false,
    this.changed = false,
  });

  final SrsDbStore store;

  /// 这一轮本机 profile 的绑定变了（认领 / 并入了别的集合，或续做了半截并入）：本机数据跟着变，调用方要让界面重读。
  /// 新代认领不换 profile uid、[store] 可能还是原来那个对象，不能只靠比对象身份判断。
  final bool changed;

  /// 已经与目录里别的设备关联上了（[SrsProfileLinkKeep.linked]，或这一轮刚采用了对方的 uid）：之后的判定不会再变。
  final bool linked;

  /// 非 null = 没法自动关联，要用户在这些候选里选（[SrsProfileLinkChoose]）。
  final List<SrsRemoteProfile>? choose;

  /// 判定时本机 profile 有没有用户数据（[SrsDbStore.hasUserData]，不只是笔记；有 = 选定后要并入，而不是直接改用）。
  final bool localHasNotes;

  /// 判定时本机 profile 的用户笔记数（只在 [choose] 非 null 时数，给用户对比本机与候选）。
  final int localNoteCount;
}

/// 暂缓中的并入（协议 3 的 BUG-4217）：profile [profileId] 要从 [oldUid] 并入 [newUid]，但旧 profile 里有 undo 撤销的
/// 日志（[missingRevoked]，旧 ID）还没同步到。新代没有这种暂缓（续做半截并入是一条内核命令，见 srs_profile_merge.dart），
/// [SrsProfileLinker.deferredMerge] 恒为 null；类型留给调度器与同步状态页，随 profile 关联改走
/// `collection_adopt` / `collection_join` 时一并删（G9-5 续）。
class SrsDeferredProfileMerge {
  const SrsDeferredProfileMerge({
    required this.profileId,
    required this.oldUid,
    required this.newUid,
    required this.missingRevoked,
  });

  final int profileId;
  final String oldUid;
  final String newUid;

  /// 被撤销、还没收到的日志的旧 ID（排序后）。
  final List<String> missingRevoked;
}

/// 用户选定候选之后 [SrsProfileLinker.adopt] 的结果。
sealed class SrsProfileAdoptResult {
  const SrsProfileAdoptResult(this.store);

  /// 之后继续同步用的 store：改用成功时是按新身份重开的那个，暂缓时是原来那个（旧 uid）。
  final SrsDbStore store;
}

/// 改用 / 并入做完了。
final class SrsProfileAdopted extends SrsProfileAdoptResult {
  const SrsProfileAdopted(super.store);
}

/// 并入暂缓（协议 3）：新代不再产生（见 [SrsDeferredProfileMerge]）。
final class SrsProfileAdoptDeferred extends SrsProfileAdoptResult {
  const SrsProfileAdoptDeferred(super.store, this.deferred);

  final SrsDeferredProfileMerge deferred;
}

/// 同步前的 profile 关联与同步后的说明文件发布（铁律 E，见文件头）。
abstract interface class SrsProfileLinker {
  /// 跑引擎之前：决定本机 profile 是否改用目录里已有的 uid（必要时采用并重开 store）。
  ///
  /// [directoryKey]：[backend] 的位置身份。关联上（目录里已有别的设备在本机 uid 下，或刚采用了对方的 uid）时把绑定
  /// 状态定为 `settled`、记下这个位置（[SrsCollectionBinding]）；已经在别的位置定下时不再自动采用。null = 调用方不知道
  /// 位置：不记绑定，已定下的绑定按「别处」算。
  Future<SrsProfileLinkOutcome> link(
    SyncAssetStore backend,
    SrsDbStore store, {
    String? directoryKey,
  });

  /// 用户在 [SrsProfileLinkChoose] 的候选里选了 [uid]（候选的位置目录名，[SrsRemoteProfile.uid]）：本机 profile 认领
  /// 它的集合（内核 `collection_adopt`，用户的选择就是确认；见文件头），返回之后继续同步用的 store。profile 的 uid 不变。
  ///
  /// [within]：候选所在的那条通道 / 本机目录（调用方正拿着它的锁）：从它重读候选的集合标识，认领之后在它上面清本机
  /// 离开的旧目录、或给被并入的一方放并入提示。不给时抛 [StateError]、什么都不改。
  ///
  /// [directoryKey]：候选所在位置的身份；改用成功后按它把绑定状态定为 `settled`（null = 不记）。
  Future<SrsProfileAdoptResult> adopt(
    SrsDbStore store,
    String uid, {
    SyncAssetStore? within,
    String? directoryKey,
  });

  /// [store] 所属的当前 profile 正在暂缓的并入（协议 3）。新代没有暂缓，生产实现恒为 null（见
  /// [SrsDeferredProfileMerge]）。
  Future<SrsDeferredProfileMerge?> deferredMerge(SrsDbStore store);

  /// 引擎跑成功之后：在本机写入者目录里写 profile 说明文件（内容没变就不重写），再按本机集合的 `Join` 补写缺的并入
  /// 提示（见文件头「吸收方向的发现」）。
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
    this.nowMs = _wallClockMs,
  });

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// 当前时刻（毫秒；续做半截并入的收尾要一个可信时刻：内核不读系统时钟）。测试注入。
  final int Function() nowMs;

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

  /// 位置 → 已经补齐并入提示的那组 `Join`（[_publishJoinHints]）。
  final Map<String, String> _hinted = <String, String>{};

  /// 已经记过的续做失败（`profile|旧 uid->新 uid|错误`）：同一个失败每个进程只记一次日志，不每轮刷（标记留着，每一轮
  /// 照样重试；错误变了再记）。
  final Set<String> _resumeFailuresLogged = <String>{};

  /// 新代没有暂缓的并入（见 [SrsDeferredProfileMerge]）：恒为 null。
  @override
  Future<SrsDeferredProfileMerge?> deferredMerge(SrsDbStore store) async =>
      null;

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

  /// 在位置 [directoryKey] 上关联上了：[store] 的绑定状态定为 `settled`（只进不退，已定下的不改）。
  Future<void> _settle(SrsDbStore store, String? directoryKey) async {
    if (directoryKey == null) return;
    await store.setCollectionBinding(
      SrsCollectionBindingState.settled,
      via: directoryKey,
    );
  }

  @override
  Future<SrsProfileLinkOutcome> link(
    SyncAssetStore backend,
    SrsDbStore store, {
    String? directoryKey,
  }) async {
    // 上次并入做到一半进程就退出了（标记还在 srs.db）：先用同样的参数做完，再按新身份判定。
    final SrsDbStore? resumed = await _resumePendingMerges(store);
    if (resumed != null) {
      // 并入刚做完：本设备离开的旧 uid 目录这一轮就清掉。这一轮按「已关联」交回，调度器之后不再跑 [link]，不在这里清
      // 就要等下次启动——期间别的设备一直看得到那个旧 profile（BUG-4296）。清不掉不影响这一轮，下次 [link] 再清。
      try {
        await _removeRetiredFolders(
          backend,
          resumed,
          await srsListRemoteProfiles(backend),
        );
      } catch (e, stack) {
        onError?.call('SrsProfileLinker.cleanup', e, stack);
      }
      await _settle(resumed, directoryKey);
      return SrsProfileLinkOutcome(resumed, linked: true, changed: true);
    }
    final List<SrsRemoteProfile> remote = await srsListRemoteProfiles(backend);
    await _removeRetiredFolders(backend, store, remote);
    final _SrsOwnCollection own = await _ownCollection(store);
    // 「本机有数据」看的是全部用户数据（[SrsDbStore.hasUserData]），不只是笔记：只建了牌组 / 改了预设、还没有笔记的
    // profile 也不能被当成空的自动采用（新代认领不删数据，但空不空决定是自动认领还是交给用户选）。
    final bool localHasNotes = await store.hasUserData();
    final SrsCollectionBinding? binding = await store.collectionBinding();
    final SrsProfileLinkDecision decision = srsDecideProfileLink(
      localUid: own.dir,
      localName: await _nameOf(store.profileUid),
      deviceId: store.deviceId,
      localHasNotes: localHasNotes,
      localProfileCount: await _profileCount(),
      remote: remote,
      v2Device: store.sync2Device,
      settled: binding?.settledElsewhere(directoryKey) ?? false,
      ownCollection: own.collection,
      joined: own.joined,
    );
    switch (decision) {
      case SrsProfileLinkKeep(:final bool linked):
        if (linked) await _settle(store, directoryKey);
        return SrsProfileLinkOutcome(store, linked: linked);
      case SrsProfileLinkChoose(:final List<SrsRemoteProfile> candidates):
        return SrsProfileLinkOutcome(
          store,
          choose: candidates,
          localHasNotes: localHasNotes,
          localNoteCount: await store.userNoteCount(),
        );
      case SrsProfileLinkAdopt(:final String uid):
        final SrsRemoteProfile? target = remote
            .where((SrsRemoteProfile r) => r.uid == uid)
            .firstOrNull;
        final String? collection = target?.collection;
        // 目录里还没有集合（只有说明文件、没立过根）：认领不了，等它立了根再判。那个集合已是本机另一个 profile 的：
        // 用户切过去就能同步，不动（内核也会拒绝把它绑给第二个 profile）。
        if (target == null ||
            collection == null ||
            await _collectionTakenLocally(
              collection,
              store.profileUid,
              store.core,
            )) {
          return SrsProfileLinkOutcome(store);
        }
        await _adoptCollection(backend, store, target, remote);
        await _settle(store, directoryKey);
        return SrsProfileLinkOutcome(store, linked: true, changed: true);
    }
  }

  /// 删掉 [remote] 里本设备的孤儿目录（删掉的同时从 [remote] 里去掉）。规则见下面的注释。
  Future<void> _removeRetiredFolders(
    SyncAssetStore backend,
    SrsDbStore store,
    List<SrsRemoteProfile> remote,
  ) async {
    // 本设备的孤儿目录：本设备**换 uid 时离开的**旧 uid（[kSrsRetiredProfileUidsKey]，例如用户在冲突弹窗里选了
    // 别的 profile），且只有本设备写过、本机也没有 profile 再用它。本机判定本来就不把它算作别人的数据，但别的设备会
    // 一直把它当成又一个有数据的候选，所以清掉。没记在退役名单里的一律不碰：删掉的 profile、恢复旧备份前的 uid
    // 同样「只有本设备写过、本机没有」，它们在同步目录里的那份可能是唯一的副本。
    final Set<String> retired = await srsEditMetaSet(
      store.core,
      SrsMetaSet.retiredDevices,
    );
    final Set<String> retiredUids = await srsEditMetaSet(
      store.core,
      SrsMetaSet.retiredUids,
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
  }

  @override
  Future<SrsProfileAdoptResult> adopt(
    SrsDbStore store,
    String uid, {
    SyncAssetStore? within,
    String? directoryKey,
  }) async {
    final SyncAssetStore? backend = within;
    if (backend == null) {
      throw StateError('adopting $uid needs the location it was found on');
    }
    final List<SrsRemoteProfile> remote = await srsListRemoteProfiles(backend);
    final SrsRemoteProfile? target = remote
        .where((SrsRemoteProfile r) => r.uid == uid)
        .firstOrNull;
    final String? collection = target?.collection;
    if (target == null || collection == null) {
      throw StateError('no collection under $uid on this location');
    }
    if (await _collectionTakenLocally(
      collection,
      store.profileUid,
      store.core,
    )) {
      throw StateError('collection $collection is another local profile');
    }
    await _adoptCollection(backend, store, target, remote);
    await _settle(store, directoryKey);
    return SrsProfileAdopted(store);
  }

  /// 本机 profile 现在的集合：标识、目录名、已经并进来的集合标识（内核 `collection_info`）。
  Future<_SrsOwnCollection> _ownCollection(SrsDbStore store) async {
    final Map<String, Object?> info = (await store.sync2Command(
      <String, Object?>{'op': 'collection_info'},
    )).map;
    // 只认受信作者写的 `Join`：内核 `AlreadyJoined`（`identity.rs` `ix.joined`）也只认它们。未受信设备同步进来的一条
    // `Join` 不能让本机把对应集合从候选里藏掉——内核仍认为那是另一个集合。
    final List<({String from, String? dir})> joins =
        <({String from, String? dir})>[
          for (final Object? j in (info['joins'] as List<Object?>?) ?? const [])
            if (j is Map && j['trusted'] == true && j['from'] is String)
              (
                from: j['from']! as String,
                dir: j['dir'] is String ? j['dir']! as String : null,
              ),
        ];
    return (
      collection: info['collection']! as String,
      dir: info['dir']! as String,
      joined: <String>{for (final j in joins) j.from},
      joins: joins,
    );
  }

  /// 并入提示从持久状态派生（设计 §5.4 第 3 条，见文件头「吸收方向的发现」）：本机集合 [own] 里每条受信、带目录名的
  /// `Join{from, dir}`，只要位置 [backend] 上有那个目录、它的 `meta.json` 集合标识就是 `from`、里面还没有指向本机集合
  /// 的提示，就补写 `joined-into-<本机集合>.json`。两个方向一样：本机吸收了对方（`Join{from: 对方}` 在本机集合里），
  /// 或本机改绑进了别的集合（`Join{from: 本机原来的集合}` 在新集合里）——旧集合 / 被吸收集合里没被问过的设备都靠它
  /// 发现。不是只在认领那一刻写一次：每台设备、每个位置都按日志补，写失败下次再补，集合里别的设备、别的位置上的
  /// 同一个旧目录都覆盖到。[remote] 是这一轮刚列的目录（null = 现列）。写失败原样抛。
  Future<void> _ensureJoinHints(
    SyncAssetStore backend,
    _SrsOwnCollection own, {
    List<SrsRemoteProfile>? remote,
  }) async {
    if (own.joins.every((j) => j.dir == null)) return;
    final List<SrsRemoteProfile> listed =
        remote ?? await srsListRemoteProfiles(backend);
    for (final ({String from, String? dir}) j in own.joins) {
      final String? dir = j.dir;
      if (dir == null || dir == own.dir) continue;
      final SrsRemoteProfile? there = listed
          .where((SrsRemoteProfile r) => r.uid == dir)
          .firstOrNull;
      // 目录不在这个位置上，或那里已经不是这个集合（读不出 / 对不上）：这里没有要提示的设备。
      if (there == null || there.collection != j.from) continue;
      if (there.joinHints.any(
        (SrsJoinHint h) => h.collection == own.collection && h.dir == own.dir,
      )) {
        continue;
      }
      await srsWriteJoinHint(
        backend,
        targetDir: dir,
        collection: own.collection,
        dir: own.dir,
      );
    }
  }

  /// 集合 [collection] 已绑在本机 [store] 之外的某个 profile 上（内核 `collections.collection` 唯一，`collection_adopt`
  /// 会拒绝把它绑给第二个 profile）。按主库的 profile 逐个问内核（profile 不多，`collection_info` 是一次读）。
  Future<bool> _collectionTakenLocally(
    String collection,
    String exceptUid,
    SrsCore core,
  ) async {
    for (final QueryRow r
        in await db
            .customSelect(
              "SELECT uid FROM profiles WHERE uid IS NOT NULL AND uid != '' "
              'AND uid != ?',
              variables: <Variable<Object>>[Variable<String>(exceptUid)],
            )
            .get()) {
      try {
        final Object? c = core.sync2(<String, Object?>{
          'op': 'collection_info',
          'profile': r.read<String>('uid'),
        }).map['collection'];
        if (c == collection) return true;
      } on SrsProfileUnboundException {
        // 还没绑定的 profile 没有集合。
      }
    }
    return false;
  }

  /// 本机 profile 认领位置上的集合 [target]（内核 `collection_adopt`，`confirmed`：调用方已按规则决定 / 用户已选定），
  /// 再在 [backend] 上收拾位置（[remote] 是这一轮列出来的目录）：
  /// - `bound`（本机空集合换绑到对方）/ `joined` 且 `rebound`（本机按 D27 改绑到对方）：本机离开了原来的目录，删掉本机
  ///   在那里的说明文件目录与新代设备目录（[srsRemoveOwnProfileFolder]；`v4/` 根与别人的东西不动）——否则别的设备
  ///   一直把那个旧目录当候选。`joined` 改绑而旧集合里还有别的设备时不删新代设备目录：它们跟过来之前还要从那里收本机
  ///   之前的段。
  /// - `joined`（两个方向）：在被并入 / 本机离开的那个目录里放并入提示（[_ensureJoinHints]），那个集合的设备据此再问
  ///   它们的用户（见文件头「吸收方向的发现」）。
  /// - `same` / `alreadyJoined` / `saltsAdded`：位置上不用动。
  /// 收拾位置失败只记日志：认领已经在本机提交；提示由之后每轮的 [publish] 按日志补写，旧目录照样按「本机的旧化身」
  /// 不算别人的数据。
  Future<void> _adoptCollection(
    SyncAssetStore backend,
    SrsDbStore store,
    SrsRemoteProfile target,
    List<SrsRemoteProfile> remote,
  ) async {
    final String? oldDir = store.sync2Dir;
    final String? oldDevice = store.sync2Device;
    final SrsRemoteProfile? mine = oldDir == null
        ? null
        : remote.where((SrsRemoteProfile r) => r.uid == oldDir).firstOrNull;
    final bool othersInOld =
        mine?.stayingWriters.any(
          (String w) =>
              !srsWriterOfDevice(w, store.deviceId) &&
              (oldDevice == null || w != srsV2WriterName(oldDevice)),
        ) ??
        false;
    final Map<String, Object?> out =
        (await store.sync2Command(<String, Object?>{
          'op': 'collection_adopt',
          'collection': target.collection,
          'dir': target.uid,
          'confirmed': true,
          'now': store.now().$1,
        })).map;
    final Object? outcome = out['outcome'];
    try {
      switch (outcome) {
        case 'bound':
        case 'joined' when out['rebound'] == true:
          if (oldDir != null && oldDir != target.uid) {
            await srsRemoveOwnProfileFolder(
              backend,
              profileUid: store.profileUid,
              dir: oldDir,
              deviceId: store.deviceId,
              v2Device: oldDevice,
              v4Device: outcome == 'bound' || !othersInOld ? oldDevice : null,
            );
          }
        case 'joined':
        case 'same' || 'alreadyJoined' || 'saltsAdded':
          break;
        default:
          throw StateError('collection_adopt: unexpected outcome $outcome');
      }
      if (outcome == 'joined') {
        // 两个方向都在被并入 / 离开的那个目录里放提示（[_ensureJoinHints]，按刚写下的 `Join` 派生）。目录在上面可能刚
        // 收拾过：重新列。
        await _ensureJoinHints(backend, await _ownCollection(store));
      }
    } on StateError {
      rethrow;
    } catch (e, stack) {
      // 认领已在内核提交；位置上的收拾下一轮补：旧目录照样按「本机的旧化身」不算别人的数据，提示由每轮发布
      // （[publish] → [_ensureJoinHints]）按日志补写。
      onError?.call('SrsProfileLinker.adoptCleanup', e, stack);
    }
  }

  /// 当前 profile 有迁移带过来的半截并入（[srsPendingProfileMerges]）：续做（[srsResumeProfileMerge]：主库改指新 uid →
  /// 内核 `profile_merge_commit` 把旧集合并进新集合）并按新身份重开 store；没有返回 null。
  ///
  /// 续做失败时**不往外抛**：标记留着、旧集合一行不少（收尾在内核一个事务里，出错整笔回滚），抛出去的话之后每一次
  /// [link] 都重跑、再抛，这台设备的整个复习同步就永久卡死。这一轮按 profiles 表当前的 uid 继续同步，经 [onError] 记下
  /// （同一个失败每个进程只记一次），下一轮照样重试。
  ///
  /// 手里的 [store] 还是旧 uid 的副本时，续做在它的最后一段独占区里跑、之后副本作废（[SrsDbStore.retire]）：已经读完现值、正等着发命令的写入先写完再续做；排在后面的、以后再来的一律明确失败。否则改完主库
  /// uid 之后、收尾前后还有写入经旧副本落进旧 uid——收尾之后旧集合与它的本机状态行都删了，一条漏进来的写入会让旧 uid
  /// 重新长出本机状态行（内核写本机状态行时没有行就新建）。作废了就不管成败都按 profiles 表当前的 uid 重开。
  Future<SrsDbStore?> _resumePendingMerges(SrsDbStore store) async {
    final int profileId = await activeProfileId();
    bool resumed = false;
    bool retired = false;
    for (final SrsPendingProfileMerge m in await srsPendingProfileMerges(
      store.core,
    )) {
      if (m.profileId != profileId) continue;
      final Directory? media = await mediaRoot?.call();
      Future<SrsProfileMergeFinish> resume() => srsResumeProfileMerge(
        db,
        profileId: m.profileId,
        oldUid: m.oldUid,
        newUid: m.newUid,
        mediaRoot: media,
        commit: () => srsFinishProfileMerge(
          store.core,
          from: m.oldUid,
          to: m.newUid,
          nowMs: nowMs(),
        ),
      );
      try {
        if (store.profileUid == m.oldUid && store.isUsable) {
          retired = true;
          await store.retire(
            resume,
            reason: 'profile ${m.oldUid} is being merged into ${m.newUid}',
          );
        } else {
          await resume();
        }
      } catch (e, stack) {
        final String key =
            '${m.profileId}|${m.oldUid}->${m.newUid}|${e.runtimeType}: $e';
        if (_resumeFailuresLogged.add(key)) {
          onError?.call(
            'SrsProfileLinker.resumeMerge profile ${m.profileId} '
            '${m.oldUid} -> ${m.newUid} (marker kept, retried next round)',
            e,
            stack,
          );
        }
        continue;
      }
      await srsEditMetaSet(store.core, SrsMetaSet.retiredUids, add: m.oldUid);
      resumed = true;
    }
    // 收尾在改完主库 uid 之后失败，而手里的 store 还是旧 uid 的：按 profiles 表的新 uid 重开，否则这一轮会接着同步一个
    // 本机已经不再指向的 profile。旧副本已作废（[SrsDbStore.retire]）的同样要重开。
    if (!resumed &&
        !retired &&
        await db.profileUidOf(profileId) == store.profileUid) {
      return null;
    }
    final SrsDbStore? reopened = await reopenStore();
    if (reopened == null) {
      throw StateError('store did not reopen after resuming a profile merge');
    }
    await reopened.afterRestore(freshIncarnation: true);
    return reopened;
  }

  @override
  Future<void> publish(
    SyncAssetStore backend,
    SrsDbStore store,
    String directoryKey,
  ) async {
    final String name = await _nameOf(store.profileUid);
    final String? device = store.sync2Device;
    if (device == null) return;
    final int noteCount = await store.userNoteCount();
    // 说明文件的 `hasNotes` 报的是「有没有用户数据」（[SrsDbStore.hasUserData]）：只建了牌组 / 改了预设的设备也要
    // 被别的设备当成有数据的候选，否则对方（空的）按「双方都空、收敛到最小 uid」判，这边又因为有数据不采用，两边
    // 就各自保持、悄悄分叉。键名沿用旧名（旧版本读到 true 同样当作有数据）。
    final bool hasNotes = noteCount > 0 || await store.hasUserData();
    // 设备人读名（昵称或型号，devices.rs）：别的设备遇到 profile 冲突时靠它认出这份数据是哪台设备的。
    final Object? label = (await store.sync2DeviceInfo())['name'];
    final String? deviceLabel = label is String && label.isNotEmpty
        ? label
        : null;
    // 并入暂缓着（或做到一半）：用户已经选定离开这个 uid，告诉别的设备别再把它当候选（BUG-4296）。并入标记是 srs.db
    // 里的持久状态，进程重启、离线多久都还在；并入做完标记删掉、本设备换到新 uid，旧 uid 下的目录随后由 [link] 清掉。
    final String? mergingInto = await _mergingInto(store);
    // 写进集合的位置目录（内核 `identity` 的 `dir`）：认领 / 并入别的集合之后它不再等于 profile uid。
    final String? dir = store.sync2Dir;
    final String sig =
        '${store.profileUid}|${dir ?? ''}|$device|$name|$noteCount|$hasNotes|'
        '${deviceLabel ?? ''}|${mergingInto ?? ''}';
    if (_published[directoryKey] != sig) {
      await srsPublishProfileInfo(
        backend,
        profileUid: store.profileUid,
        dir: dir,
        writerId: device,
        name: name,
        hasNotes: hasNotes,
        device: deviceLabel,
        noteCount: noteCount,
        mergingInto: mergingInto,
      );
      _published[directoryKey] = sig;
    }
    await _publishJoinHints(backend, store, directoryKey);
  }

  /// [publish] 里按本机集合的 `Join` 补写并入提示（[_ensureJoinHints]）。同一位置上同一组 `Join` 补齐过一次就不再列目录
  /// （进程内）；没补齐（写失败抛出去）就不记，下一轮发布再补。
  Future<void> _publishJoinHints(
    SyncAssetStore backend,
    SrsDbStore store,
    String directoryKey,
  ) async {
    final _SrsOwnCollection own = await _ownCollection(store);
    final String sig = <String>[
      own.collection,
      own.dir,
      for (final ({String from, String? dir}) j in own.joins)
        '${j.from}@${j.dir ?? ''}',
    ].join('|');
    if (_hinted[directoryKey] == sig) return;
    await _ensureJoinHints(backend, own);
    _hinted[directoryKey] = sig;
  }

  /// [store] 所属的当前 profile 有没做完的并入、且它还在旧 uid 上（[srsPendingProfileMerges]）：要并入的 uid；否则 null。
  Future<String?> _mergingInto(SrsDbStore store) async {
    final int profileId = await activeProfileId();
    for (final SrsPendingProfileMerge m in await srsPendingProfileMerges(
      store.core,
    )) {
      if (m.profileId == profileId && m.oldUid == store.profileUid) {
        return m.newUid;
      }
    }
    return null;
  }
}

/// 本机 profile 现在的集合（[SrsDbProfileLinker] 判定用）：标识、位置目录名、已经并进来的集合标识。
typedef _SrsOwnCollection = ({
  String collection,
  String dir,
  Set<String> joined,
  List<({String from, String? dir})> joins,
});
