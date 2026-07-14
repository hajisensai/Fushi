/// 显式确认式删除传播的纯决策核心 + 远端墓碑标记编解码（多端库联合视图 / 删除传播）。
///
/// 数据流：本地删资产 → sync_deletion_tombstones 记墓碑（见 HibikiDatabase）→ 同步时发布
/// 成远端标记（云 `__tombstones__/<marker>.json` / 互联 host 暴露）→ compare 对话框读双方
/// 墓碑与在库态，经 [computeDeletionPropagation] 算出**待用户逐条确认**的候选，绝不静默自动删
/// （与 union-only 的安全取舍一致）。纯 Dart：零 IO、零 Flutter 依赖，便于单测。
library;

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

/// 纯函数：给定本地删除墓碑、远端删除墓碑、两端当前在库键，算出双向删除传播候选。
///
/// - **deleteRemote**：本地有删除墓碑 ∧ 远端仍在库 → 用户可选「远端也删」。
/// - **deleteLocal**：远端有删除墓碑 ∧ 本地仍在库 → 用户可选「本地也删」。
///
/// 输入均为 `mediaType → itemKeys` 集合。两端都删（墓碑齐）不产生候选（已收敛）；两端都在库
/// 且无墓碑同样不产生候选。确定性排序（mediaType 再 itemKey 再方向），便于稳定展示 + 单测。
List<DeletionPropagationCandidate> computeDeletionPropagation({
  required Map<String, Set<String>> localTombstones,
  required Map<String, Set<String>> remoteTombstones,
  required Map<String, Set<String>> localPresent,
  required Map<String, Set<String>> remotePresent,
}) {
  final List<DeletionPropagationCandidate> out =
      <DeletionPropagationCandidate>[];
  final Set<String> types = <String>{
    ...localTombstones.keys,
    ...remoteTombstones.keys,
  };
  for (final String mt in types) {
    final Set<String> remoteHere = remotePresent[mt] ?? const <String>{};
    for (final String key in localTombstones[mt] ?? const <String>{}) {
      if (remoteHere.contains(key)) {
        out.add(DeletionPropagationCandidate(
          mediaType: mt,
          itemKey: key,
          direction: DeletionPropagationDirection.deleteRemote,
        ));
      }
    }
    final Set<String> localHere = localPresent[mt] ?? const <String>{};
    for (final String key in remoteTombstones[mt] ?? const <String>{}) {
      if (localHere.contains(key)) {
        out.add(DeletionPropagationCandidate(
          mediaType: mt,
          itemKey: key,
          direction: DeletionPropagationDirection.deleteLocal,
        ));
      }
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
  return '${mediaType}__${cleaned}_${_stableHashHex(itemKey)}.json';
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

/// FNV-1a 32-bit 稳定哈希（确定性、无外部依赖，仅用于资产名去歧义，非安全用途）。
String _stableHashHex(String s) {
  int hash = 0x811c9dc5;
  for (final int c in s.codeUnits) {
    hash = (hash ^ (c & 0xff)) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
    hash = (hash ^ ((c >> 8) & 0xff)) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
