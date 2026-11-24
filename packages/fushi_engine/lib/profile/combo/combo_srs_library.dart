/// 复习库解析（拍板台 design-srs-shared-library 方案 a，组合阶段 4；纯函数，无 I/O）。
///
/// 复习集合的身份是一个 `profiles.uid`（不改 SRS schema 的归属列）。哪个 uid 由组合的
/// `srs.library` 叶子决定（设计 §4.1）：
///
/// * 从最高的绑定层往下（作品 → 媒体类型 → 语言 → 激活配置），第一个**单独设置了**
///   `srs.library` 的组合说了算：值为 `own` → 用这个组合自己的 uid（独立复习库，沿用现有实体
///   归属闸）；值为 `shared` → 共享库。
/// * 都没拆（全部继承默认组合）→ 共享库。
/// * 共享库的 uid 记在默认组合的 `combo/srs_shared_uid` 行（迁移时可能指向别的 Profile 的
///   uid，见 §4.2），不是默认组合自己的 uid。
/// * 「待定」：还没有默认组合（未迁移 / 迁移没跑成），或默认组合还没写 `srs_shared_uid`（迁移
///   时复习库打不开）。这时不知道哪份数据是共享库，按迁移前的语义取**激活配置**自己的那份
///   ——绝不在没定的时候把卡写进一份可能被判成别人独立库的集合；下次归一定下来后自然切过去。
///
/// app 侧从 `profile_settings` 读出几张小表喂进来（`fushi/lib/src/profile/combo/
/// srs_library_resolver.dart`），服务端 profile hub 可用同一份。
///
/// 设计见 `docs/specs/2026-11-23-combo-settings-tree-design.md` §4。
library;

import 'package:fushi_engine/profile/combo/combo_migration.dart'
    show kComboSrsLibraryLeafId, kComboSrsLibraryOwnValue;
import 'package:fushi_engine/profile/combo/combo_rows.dart';
import 'package:fushi_engine/profile/combo/settings_tree.dart';

/// `srs.library` 叶子的拆分标记行的 key（category [kComboSyntheticCategory]）。
const String kComboSrsLibrarySplitKey =
    '$kComboSplitKeyPrefix$kComboSrsLibraryLeafId';

/// 一份复习库（一个复习集合）。
class ComboSrsLibrary {
  const ComboSrsLibrary({
    required this.uid,
    required this.shared,
    this.ownerProfileId,
  });

  /// 集合身份（`profiles.uid`）。
  final String uid;

  /// 是不是共享库（[ComboSrsLibraries.decided] 为 false 时恒为 false：没有共享库这回事）。
  final bool shared;

  /// 拆出这份独立库的组合；共享库为承载它的 Profile（`srs_shared_uid` 指向的那份，已不在
  /// 库里时 null）。
  final int? ownerProfileId;

  @override
  bool operator ==(Object other) =>
      other is ComboSrsLibrary &&
      other.uid == uid &&
      other.shared == shared &&
      other.ownerProfileId == ownerProfileId;

  @override
  int get hashCode => Object.hash(uid, shared, ownerProfileId);

  @override
  String toString() =>
      'ComboSrsLibrary($uid, ${shared ? 'shared' : 'own'}, owner: $ownerProfileId)';
}

/// 一个库里全部 Profile 的复习库归属快照（由几张 `profile_settings` 小表构造）。
class ComboSrsLibraries {
  ComboSrsLibraries._({
    required Map<int, String> uidById,
    required this.defaultId,
    required this.sharedUid,
    required Set<int> splitIds,
    required Set<int> ownIds,
  }) : _uidById = Map<int, String>.unmodifiable(uidById),
       _splitIds = Set<int>.unmodifiable(splitIds),
       _ownIds = Set<int>.unmodifiable(ownIds);

  /// [uidById]：全部 Profile 的 uid；[roles] / [sharedUids] / [librarySplits] /
  /// [libraryValues]：`combo` category 下 `role` / `srs_shared_uid` /
  /// `split:srs.library` / `srs_library` 各自的 `profile id → value`。
  factory ComboSrsLibraries.fromRows({
    required Map<int, String> uidById,
    required Map<int, String> roles,
    required Map<int, String> sharedUids,
    required Map<int, String> librarySplits,
    required Map<int, String> libraryValues,
  }) {
    int? defaultId;
    for (final MapEntry<int, String> e in roles.entries) {
      if (e.value != ComboRole.defaults.wire) continue;
      if (!uidById.containsKey(e.key)) continue;
      // 坏状态下有多份默认时取 id 最小的（与 `ComboRepository.defaultComboId` 同口径；
      // 下一次归一会把其余降级）。
      if (defaultId == null || e.key < defaultId) defaultId = e.key;
    }
    final String? shared = defaultId == null ? null : sharedUids[defaultId];
    final Set<int> split = <int>{};
    final Set<int> own = <int>{};
    for (final int id in uidById.keys) {
      // 只有非默认角色的组合格式才存拆分（默认组合恒为共享库的宿主；存量快照与不认识的
      // 角色没有可信的拆分）。
      final ComboRole? role = ComboRole.fromWire(roles[id]);
      if (role == null || role == ComboRole.defaults) continue;
      if (!librarySplits.containsKey(id)) continue;
      split.add(id);
      if (libraryValues[id] == kComboSrsLibraryOwnValue) own.add(id);
    }
    return ComboSrsLibraries._(
      uidById: uidById,
      defaultId: defaultId,
      sharedUid: shared == null || shared.isEmpty ? null : shared,
      splitIds: split,
      ownIds: own,
    );
  }

  final Map<int, String> _uidById;

  /// 默认组合；还没迁移成组合格式时 null。
  final int? defaultId;

  /// 共享库的集合 uid；null = 待定（见库文档）。
  final String? sharedUid;

  /// 单独设置了 `srs.library` 的组合（值 `own` 或 `shared`）。
  final Set<int> _splitIds;

  /// 拆出独立复习库的组合。
  final Set<int> _ownIds;

  /// 共享库定下来了（默认组合有 `srs_shared_uid`）。
  bool get decided => sharedUid != null;

  /// 承载共享库的 Profile（uid == [sharedUid] 的那份）；待定 / 宿主已不在库里时 null。
  int? get sharedHostId {
    final String? shared = sharedUid;
    if (shared == null) return null;
    for (final MapEntry<int, String> e in _uidById.entries) {
      if (e.value == shared) return e.key;
    }
    return null;
  }

  ComboSrsLibrary get _shared => ComboSrsLibrary(
    uid: sharedUid!,
    shared: true,
    ownerProfileId: sharedHostId,
  );

  /// [baseProfileId]（激活配置，或浏览器扩展 / 互联选的那份配置）之上叠 [layers]（绑定层 →
  /// Profile id）时制卡 / 导入 / 复习落进哪份库。指向 [baseProfileId] 自己、已不存在的层忽略。
  ///
  /// 待定时取 [baseProfileId] 自己的 uid（迁移前的语义）；[baseProfileId] 也不在库里时 null。
  ComboSrsLibrary? resolve({
    required int baseProfileId,
    Map<ComboScope, int> layers = const <ComboScope, int>{},
  }) {
    if (!decided) {
      final String? uid = _uidById[baseProfileId];
      return uid == null
          ? null
          : ComboSrsLibrary(
              uid: uid,
              shared: false,
              ownerProfileId: baseProfileId,
            );
    }
    final List<int> candidates = <int>[
      for (final ComboScope s in ComboScope.bindingLayers)
        if (layers[s] case final int id when id != baseProfileId) id,
      baseProfileId,
    ];
    for (final int id in candidates) {
      if (!_splitIds.contains(id)) continue;
      final String? uid = _uidById[id];
      if (uid == null) continue;
      if (_ownIds.contains(id)) {
        return ComboSrsLibrary(uid: uid, shared: false, ownerProfileId: id);
      }
      // 在这一层明确设回共享：盖过更低层的独立库。
      return _shared;
    }
    return _shared;
  }

  /// 本库现有的全部复习库：共享库在前，其余按组合 id。待定时为空（没有可切换的库）。
  List<ComboSrsLibrary> get libraries {
    if (!decided) return const <ComboSrsLibrary>[];
    final List<int> owners = _ownIds.toList()..sort();
    return <ComboSrsLibrary>[
      _shared,
      for (final int id in owners)
        // 独立库的 uid 恰好就是共享库那份（迁移时共享库指向了它，之后又被设成 own）：同一份
        // 集合，不重复列。
        if (_uidById[id] != sharedUid)
          ComboSrsLibrary(
            uid: _uidById[id]!,
            shared: false,
            ownerProfileId: id,
          ),
    ];
  }

  /// 删 [profileId] 会不会删掉共享库的宿主（集合 uid 挂在 `profiles` 行上，行没了备份 /
  /// 导出 / 同步都找不到这份库）。
  bool hostsSharedLibrary(int profileId) =>
      decided && _uidById[profileId] == sharedUid;
}
