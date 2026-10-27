/// 云端删除墓碑合并清单（bundle，SDbJAx1Db6）。
///
/// 逐条标记（`__tombstones__/<marker>.json`，见 `deletion_propagation.dart`）每轮都要逐个
/// GET：标记永不 GC，数量只增不减，用户攒到几百条后单是这一阶段就 200 s+，每条都是一次
/// 独立的 HTTPS 往返（握手失败一条就记一条错）。合并清单把读侧压成「每台设备一个对象」：
///
/// - 每台设备只写自己那份 `__tombstones__/_bundles/tombstones-<deviceId>.json`（单写者，
///   不会互相覆盖丢更新，与 `collections-<deviceId>.json` 同一套路）。
/// - 清单装两类条目：本机自己的墓碑；本机**读过**的逐条标记（连同读时列目录给出的
///   `AssetEntry.revision` 内容指纹）。任何一台设备读过某条逐条标记后，整个设备群再列
///   目录时见到「同名 + 同指纹」的标记就知道它的内容已由某份清单携带，不再 GET。
/// - 旧格式照读：没被清单按「同名 + 同指纹」覆盖的逐条标记仍逐个 GET（编排器给每轮上限）。
///   新墓碑照旧**同时**写逐条标记，旧客户端仍能消费；旧客户端列目录跳过子文件夹，
///   看不到 `_bundles/`，不会把清单当成坏标记。
///
/// 纯 Dart、零 IO。
library;

/// 合并清单所在的 `__tombstones__` 子文件夹名。
const String kDeletionTombstoneBundlesFolder = '_bundles';

/// 合并清单的 `format` 判别值。
const String kDeletionTombstoneBundleFormat =
    'fushi.deletion-tombstones.bundle';

/// 本端合并清单资产名。deviceId 为空（测试 / 未配置）时调用方不写自己的清单（只读）。
String deletionTombstoneBundleNameFor(String deviceId) =>
    'tombstones-$deviceId.json';

/// 清单条目键：mediaType 与 itemKey 之间用 NUL 隔开（itemKey 本身可含 `__`）。
String deletionTombstoneBundleKey(String mediaType, String itemKey) =>
    '$mediaType\u0000$itemKey';

/// 合并清单里的一条墓碑。
///
/// [assetName] = 这条墓碑对应的逐条标记文件名（读来的 / 本机发布过的）。[revision] 非空
/// 表示：列目录时 [assetName] 那个文件的内容指纹是它，且那份内容的 deletedAt <=
/// [deletedAt]——这就是「同名同指纹免 GET」判据（[deletionTombstoneBundleCoverage]）
/// 成立的依据。
class DeletionTombstoneBundleEntry {
  const DeletionTombstoneBundleEntry({
    required this.mediaType,
    required this.itemKey,
    required this.deletedAt,
    this.assetName,
    this.revision,
  });

  final String mediaType;
  final String itemKey;
  final int deletedAt;
  final String? assetName;
  final String? revision;

  Map<String, Object?> toJson() => <String, Object?>{
    'm': mediaType,
    'k': itemKey,
    'd': deletedAt,
    if (assetName != null) 'a': assetName,
    if (revision != null) 'r': revision,
  };

  static DeletionTombstoneBundleEntry? tryParse(Object? json) {
    if (json is! Map) return null;
    final Object? m = json['m'];
    final Object? k = json['k'];
    final Object? d = json['d'];
    if (m is! String || m.isEmpty || k is! String || k.isEmpty) return null;
    final int? at = d is int ? d : (d is num ? d.toInt() : null);
    if (at == null) return null;
    final Object? a = json['a'];
    final Object? r = json['r'];
    return DeletionTombstoneBundleEntry(
      mediaType: m,
      itemKey: k,
      deletedAt: at,
      assetName: a is String && a.isNotEmpty ? a : null,
      revision: r is String && r.isNotEmpty ? r : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeletionTombstoneBundleEntry &&
      other.mediaType == mediaType &&
      other.itemKey == itemKey &&
      other.deletedAt == deletedAt &&
      other.assetName == assetName &&
      other.revision == revision;

  @override
  int get hashCode =>
      Object.hash(mediaType, itemKey, deletedAt, assetName, revision);
}

/// 一份设备合并清单：墓碑条目 + 读过但内容不合法的逐条标记指纹（[malformed]：
/// assetName → revision；同指纹下次不再 GET，坏文件不必每轮重下）。
class DeletionTombstoneBundle {
  DeletionTombstoneBundle({
    Map<String, DeletionTombstoneBundleEntry>? entries,
    Map<String, String>? malformed,
  }) : entries = entries ?? <String, DeletionTombstoneBundleEntry>{},
       malformed = malformed ?? <String, String>{};

  /// 键 = [deletionTombstoneBundleKey]。
  final Map<String, DeletionTombstoneBundleEntry> entries;
  final Map<String, String> malformed;

  /// 并入一条墓碑，deletedAt 取较大。指纹规则：
  /// - [revision] 非空：记下 ([assetName], [revision])——新指纹指向的内容 deletedAt <=
  ///   合并后的 deletedAt，覆盖判据仍成立。
  /// - 只给了 [assetName]（本机刚发布、尚未列到指纹）且与旧名不同：换名、清指纹。
  /// - 其余：保留旧的名与指纹。
  void add(
    String mediaType,
    String itemKey,
    int deletedAt, {
    String? assetName,
    String? revision,
  }) {
    final String key = deletionTombstoneBundleKey(mediaType, itemKey);
    final DeletionTombstoneBundleEntry? prev = entries[key];
    String? name = prev?.assetName;
    String? rev = prev?.revision;
    if (assetName != null && revision != null) {
      name = assetName;
      rev = revision;
    } else if (assetName != null && assetName != name) {
      name = assetName;
      rev = null;
    }
    entries[key] = DeletionTombstoneBundleEntry(
      mediaType: mediaType,
      itemKey: itemKey,
      deletedAt: prev == null || deletedAt > prev.deletedAt
          ? deletedAt
          : prev.deletedAt,
      assetName: name,
      revision: rev,
    );
  }

  /// 条目与坏文件集合是否与 [other] 完全相同（决定本轮要不要重写清单）。
  bool sameContentAs(DeletionTombstoneBundle other) {
    if (entries.length != other.entries.length ||
        malformed.length != other.malformed.length) {
      return false;
    }
    for (final MapEntry<String, DeletionTombstoneBundleEntry> e
        in entries.entries) {
      if (other.entries[e.key] != e.value) return false;
    }
    for (final MapEntry<String, String> e in malformed.entries) {
      if (other.malformed[e.key] != e.value) return false;
    }
    return true;
  }

  DeletionTombstoneBundle copy() => DeletionTombstoneBundle(
    entries: Map<String, DeletionTombstoneBundleEntry>.of(entries),
    malformed: Map<String, String>.of(malformed),
  );

  Map<String, Object?> toJson(String deviceId) => <String, Object?>{
    'format': kDeletionTombstoneBundleFormat,
    'version': 1,
    'deviceId': deviceId,
    'entries': <Object?>[
      for (final DeletionTombstoneBundleEntry e in entries.values) e.toJson(),
    ],
    if (malformed.isNotEmpty) 'malformed': malformed,
  };

  /// 解析；不是本协议（format 不符 / 结构不对）返回 null。单条坏条目跳过。
  static DeletionTombstoneBundle? tryParse(Object? json) {
    if (json is! Map || json['format'] != kDeletionTombstoneBundleFormat) {
      return null;
    }
    final Object? list = json['entries'];
    if (list is! List) return null;
    final DeletionTombstoneBundle out = DeletionTombstoneBundle();
    for (final Object? raw in list) {
      final DeletionTombstoneBundleEntry? e =
          DeletionTombstoneBundleEntry.tryParse(raw);
      if (e == null) continue;
      out.add(
        e.mediaType,
        e.itemKey,
        e.deletedAt,
        assetName: e.assetName,
        revision: e.revision,
      );
    }
    final Object? bad = json['malformed'];
    if (bad is Map) {
      bad.forEach((Object? k, Object? v) {
        if (k is String && v is String && v.isNotEmpty) out.malformed[k] = v;
      });
    }
    return out;
  }
}

/// 从若干清单汇总「哪些逐条标记已被覆盖」：assetName → 该名字下已知的内容指纹集合。
/// 列目录时某个逐条标记的 (name, revision) 落在这里 ⇒ 其内容已由某份清单携带，免 GET。
/// revision 为 null 的后端（FTP / SFTP 不给可靠内容指纹）永远不会命中，照旧逐个读。
Map<String, Set<String>> deletionTombstoneBundleCoverage(
  Iterable<DeletionTombstoneBundle> bundles,
) {
  final Map<String, Set<String>> out = <String, Set<String>>{};
  for (final DeletionTombstoneBundle b in bundles) {
    for (final DeletionTombstoneBundleEntry e in b.entries.values) {
      final String? a = e.assetName;
      final String? r = e.revision;
      if (a == null || r == null) continue;
      out.putIfAbsent(a, () => <String>{}).add(r);
    }
    b.malformed.forEach((String a, String r) {
      out.putIfAbsent(a, () => <String>{}).add(r);
    });
  }
  return out;
}
