/// 显式确认式删除传播的纯决策核心 + 远端墓碑标记编解码（多端库联合视图 / 删除传播）。
///
/// 数据流：本地删资产 → sync_deletion_tombstones 记墓碑（见 FushiDatabase）→ 同步时发布
/// 成远端标记（云 `__tombstones__/<marker>.json` / 互联 host 暴露）→ compare 对话框读双方
/// 墓碑与在库态，经 [computeDeletionPropagation] 算出**待用户逐条确认**的候选，绝不静默自动删
/// （与 union-only 的安全取舍一致）。纯 Dart：零 IO、零 Flutter 依赖，便于单测。
library;

import 'package:fushi_core/fushi_core.dart' show fnv1a32Utf16PairHex;

/// 用户在删除某资产时选择的传播范围（源设备弹窗采集）。
///
/// - [keepLocalOnly]：只删本机，不写传播墓碑——其他设备保留（仍走本机原有防复活语义）。
/// - [syncEverywhere]：写 `sync_deletion_tombstones` 墓碑并在同步时发布到远端标记，
///   其他设备同步时读到标记 → 逐条确认 → 也删（见 [computeDeletionPropagation]）。
enum DeleteScope {
  keepLocalOnly,
  syncEverywhere,
}

/// 用户在删除确认框里做出的完整决定：传播范围 + 要不要连本地原始文件一起删。
///
/// 两个维度正交：[scope] 只管「其他设备删不删」（墓碑），[deleteLocalFiles] 只管
/// 「本机磁盘上用户自己的原件删不删」（视频文件 / 有声书原始音频）。默认后者为
/// false——现有所有入口的语义（只删库记录 + app 自己的副本）一个字都不变。
class DeleteDecision {
  const DeleteDecision({
    required this.scope,
    this.deleteLocalFiles = false,
  });

  final DeleteScope scope;
  final bool deleteLocalFiles;

  @override
  bool operator ==(Object other) =>
      other is DeleteDecision &&
      other.scope == scope &&
      other.deleteLocalFiles == deleteLocalFiles;

  @override
  int get hashCode => Object.hash(scope, deleteLocalFiles);

  @override
  String toString() =>
      'DeleteDecision(${scope.name}, deleteLocalFiles: $deleteLocalFiles)';
}

/// 删除传播的方向：远端也删 / 本地也删。
enum DeletionPropagationDirection {
  /// 本地已删（有墓碑）而远端仍在库 → 提示用户「远端也删除？」。
  deleteRemote,

  /// 远端已删（有墓碑标记）而本地仍在库 → 提示用户「本地也删除？」。
  deleteLocal,
}

/// 一条待用户确认的删除传播候选。
class DeletionPropagationCandidate {
  const DeletionPropagationCandidate({
    required this.mediaType,
    required this.itemKey,
    required this.direction,
  });

  /// 资产种类：'book' | 'audiobook' | 'video' | 'localaudio'。
  final String mediaType;

  /// 资产跨设备稳定身份（bookKey / bookUid / displayName）。
  final String itemKey;

  final DeletionPropagationDirection direction;

  @override
  bool operator ==(Object other) =>
      other is DeletionPropagationCandidate &&
      other.mediaType == mediaType &&
      other.itemKey == itemKey &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(mediaType, itemKey, direction);

  @override
  String toString() =>
      'DeletionPropagationCandidate($mediaType/$itemKey → ${direction.name})';
}

/// 一端「当前在库」的条目：`itemKey → 该条目在这一端的**存在起始时刻**`（毫秒纪元）。
///
/// 值可空：`null` = 这类资产不记录存在起始时刻（当前是 `localaudio` 与 `audiobook`），
/// 该条目退化为旧的纯集合语义（只看在不在库）。其余资产都有真实时刻可用——书 / 字幕书 /
/// 视频用 `importedAt`，收藏词 / 收藏句用 `createdAt`。
typedef DeletionPresentEntries = Map<String, Map<String, int?>>;

/// 一端的删除墓碑：`itemKey → deletedAt`（毫秒纪元）。
typedef DeletionTombstoneEntries = Map<String, Map<String, int>>;

/// 这条墓碑管不管得着那一端现存的这条同名条目。
///
/// 「在库」不是一个布尔量，而是一段**从某个时刻开始**的存在。墓碑说的是「这个身份在
/// [deletedAt] 被删过」；若该端现存的这条是在那之后才建立的（[presentSinceAt] >=
/// [deletedAt]），它就不是墓碑指的那一条，而是**删除之后重新加回来的新条目**——墓碑对
/// 它无效。
///
/// BUG-2044：这正是删除确认弹窗曾把「本机自己取消收藏、之后又重新收藏」的句子当成
/// 「其他设备已删除」来问用户要不要删的原因。聚合快照那条通道早就有等价仲裁
/// （`AggregateSyncService._arbitrateFavorites`，`aggregate_sync_service.dart:454`，
/// BUG-1642：墓碑 deletedAt **严格大于**收藏 createdAt 才让收藏出局），本通道却只做
/// 集合交、从不比时刻，同一份数据两条通道给出相反结论。
///
/// 时刻未知（[presentSinceAt] == null）时保守返回 true：宁可多问一次，也不因为缺时刻
/// 而静默压制一次真实的跨端删除。
bool tombstoneAppliesTo({
  required int deletedAt,
  required int? presentSinceAt,
}) =>
    presentSinceAt == null || deletedAt > presentSinceAt;

/// 纯函数：给定两端删除墓碑与两端当前在库条目，算出双向删除传播候选。
///
/// - **deleteRemote**：本地有删除墓碑 ∧ 远端仍在库 → 用户可选「远端也删」。
/// - **deleteLocal**：远端有删除墓碑 ∧ 本地仍在库 → 用户可选「本地也删」。
///
/// 两个方向共用同一条判据 [tombstoneAppliesTo]：墓碑只对「删除时刻之前就存在」的那条
/// 生效，删后重加的新条目不产生候选。**没有按资产种类分叉的特例**——时刻缺失由
/// [DeletionPresentEntries] 的可空值统一表达。
///
/// 两端都删（墓碑齐）不产生候选（已收敛）；两端都在库且无墓碑同样不产生候选。确定性排序
/// （mediaType 再 itemKey 再方向），便于稳定展示 + 单测。
List<DeletionPropagationCandidate> computeDeletionPropagation({
  required DeletionTombstoneEntries localTombstones,
  required DeletionTombstoneEntries remoteTombstones,
  required DeletionPresentEntries localPresent,
  required DeletionPresentEntries remotePresent,
}) {
  final List<DeletionPropagationCandidate> out =
      <DeletionPropagationCandidate>[];
  final Set<String> types = <String>{
    ...localTombstones.keys,
    ...remoteTombstones.keys,
  };
  for (final String mt in types) {
    final Map<String, int?> remoteHere =
        remotePresent[mt] ?? const <String, int?>{};
    for (final MapEntry<String, int> e
        in (localTombstones[mt] ?? const <String, int>{}).entries) {
      if (!remoteHere.containsKey(e.key)) continue;
      if (!tombstoneAppliesTo(
          deletedAt: e.value, presentSinceAt: remoteHere[e.key])) {
        continue;
      }
      out.add(DeletionPropagationCandidate(
        mediaType: mt,
        itemKey: e.key,
        direction: DeletionPropagationDirection.deleteRemote,
      ));
    }
    final Map<String, int?> localHere =
        localPresent[mt] ?? const <String, int?>{};
    for (final MapEntry<String, int> e
        in (remoteTombstones[mt] ?? const <String, int>{}).entries) {
      if (!localHere.containsKey(e.key)) continue;
      if (!tombstoneAppliesTo(
          deletedAt: e.value, presentSinceAt: localHere[e.key])) {
        continue;
      }
      out.add(DeletionPropagationCandidate(
        mediaType: mt,
        itemKey: e.key,
        direction: DeletionPropagationDirection.deleteLocal,
      ));
    }
  }
  out.sort((DeletionPropagationCandidate a, DeletionPropagationCandidate b) {
    final int t = a.mediaType.compareTo(b.mediaType);
    if (t != 0) return t;
    final int k = a.itemKey.compareTo(b.itemKey);
    if (k != 0) return k;
    return a.direction.index.compareTo(b.direction.index);
  });
  return out;
}

/// 云端删除墓碑标记的命名空间（保留文件夹，不当书文件夹）。
const String kSyncTombstonesNamespace = '__tombstones__';

/// 一条云端删除墓碑标记的资产名：`<mediaType>__<safeItemKey>.json`。itemKey 清洗成文件系统
/// 安全基名（非 `[A-Za-z0-9._-]` → `_`，截 80，附 itemKey 稳定哈希消歧义），确定性、跨后端安全。
String deletionTombstoneAssetName(String mediaType, String itemKey) {
  String cleaned = itemKey.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (cleaned.isEmpty) cleaned = 'item';
  if (cleaned.length > 80) cleaned = cleaned.substring(0, 80);
  return '${mediaType}__${cleaned}_${fnv1a32Utf16PairHex(itemKey)}.json';
}

/// 一条删除墓碑标记的 JSON 载荷。
Map<String, Object?> deletionTombstoneJson(
        String mediaType, String itemKey, int deletedAt) =>
    <String, Object?>{
      'mediaType': mediaType,
      'itemKey': itemKey,
      'deletedAt': deletedAt,
    };

/// 解析一条删除墓碑标记 JSON → (mediaType, itemKey, deletedAt)；非法返回 null（安全降级）。
({String mediaType, String itemKey, int deletedAt})? parseDeletionTombstoneJson(
    Object? json) {
  if (json is! Map) return null;
  final String mediaType = json['mediaType']?.toString() ?? '';
  final String itemKey = json['itemKey']?.toString() ?? '';
  if (mediaType.isEmpty || itemKey.isEmpty) return null;
  final Object? raw = json['deletedAt'];
  final int? deletedAt = raw is int
      ? raw
      : (raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? ''));
  if (deletedAt == null) return null;
  return (mediaType: mediaType, itemKey: itemKey, deletedAt: deletedAt);
}

/// 解析 `favoriteword` 删除墓碑的 itemKey（= `FushiDatabase.favoriteWordItemKey` 的
/// NUL 连接串 `expression\u0000reading\u0000sourceType`）。非法（段数≠3）返回 null。
({String expression, String reading, String sourceType})?
    parseFavoriteWordItemKey(String key) {
  final List<String> parts = key.split('\u0000');
  if (parts.length != 3) return null;
  return (expression: parts[0], reading: parts[1], sourceType: parts[2]);
}
