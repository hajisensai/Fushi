import 'dart:convert';

/// 合集同步清单（多端库联合视图 §2.3 任务3）。
///
/// 云后端在 sync 根 `__collections__/collections.json` 存一份共享清单，各端
/// 读-合并-写（互联 host API 走同一编解码，任务5/6 接线）。清单是**知识的并集**：
/// 活合集（成员 + 手动序 + 序时间戳）、成员移出墓碑、合集级删除墓碑都在其中，
/// 合并语义由 `CollectionSyncEngine` 负责——本文件只做类型化编解码，纯 Dart、
/// 零 IO、零 Flutter 依赖。
///
/// 输出**确定性排序**（合集按自然键、成员按 sortIndex、墓碑按成员键），使
/// 「内容相等 ⇒ 字节相等」成立：编排器靠 canonical JSON 比对决定要不要回写
/// 远端清单，两端反复同步不产生无意义的写放大。
class CollectionManifest {
  const CollectionManifest({
    this.version = currentVersion,
    this.collections = const <CollectionManifestEntry>[],
  });

  /// 清单格式版本（向后兼容判据；解码只认 <= [currentVersion]）。
  static const int currentVersion = 1;

  /// 空清单（远端尚无 `collections.json` 时的合并起点）。
  static const CollectionManifest empty = CollectionManifest();

  final int version;

  /// 全部合集条目（活合集 + 已删合集的墓碑壳），无序输入、编码时排序。
  final List<CollectionManifestEntry> collections;

  /// 解码。[json] 是 `jsonDecode` 的产物（Map）。结构非法抛 [FormatException]
  /// （编排器捕获后计入 report.errors，不让一份坏清单毁掉整轮同步）。
  factory CollectionManifest.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('collection manifest: not a JSON object');
    }
    final Object? version = json['version'];
    if (version is! int || version < 1) {
      throw const FormatException('collection manifest: bad version');
    }
    if (version > currentVersion) {
      // 更新版 app 写的清单：拒绝解析（宁可跳过本轮合集同步，也不能按旧语义
      // 误读新字段后把降级结果写回去，破坏新端数据——与 DB 降级保护同一律）。
      throw FormatException(
          'collection manifest: version $version is newer than '
          'supported $currentVersion');
    }
    final Object? rawCollections = json['collections'];
    if (rawCollections is! List) {
      throw const FormatException('collection manifest: bad collections');
    }
    return CollectionManifest(
      version: version,
      collections: <CollectionManifestEntry>[
        for (final Object? c in rawCollections)
          CollectionManifestEntry.fromJson(c),
      ],
    );
  }

  /// 编码为确定性排序的 JSON 结构（见类注释）。
  Map<String, dynamic> toJson() {
    final List<CollectionManifestEntry> sorted =
        List<CollectionManifestEntry>.of(collections)
          ..sort((CollectionManifestEntry a, CollectionManifestEntry b) {
            final int byName = a.name.compareTo(b.name);
            if (byName != 0) return byName;
            return a.collectionType.compareTo(b.collectionType);
          });
    return <String, dynamic>{
      'version': version,
      'collections': <Map<String, dynamic>>[
        for (final CollectionManifestEntry c in sorted) c.toJson(),
      ],
    };
  }

  /// 规范化 JSON 字符串（确定性排序 ⇒ 内容相等则字节相等，供变更检测）。
  String canonicalJson() => jsonEncode(toJson());
}

/// 清单里的一个合集：活合集（[deletedAt] == null）或删除墓碑壳（!= null，
/// 此时 [members] 与 [memberTombstones] 语义上为空——引擎归一化会丢弃）。
class CollectionManifestEntry {
  const CollectionManifestEntry({
    required this.name,
    required this.collectionType,
    this.orderUpdatedAt = 0,
    this.deletedAt,
    this.members = const <CollectionManifestMember>[],
    this.memberTombstones = const <CollectionMemberTombstone>[],
  });

  /// 自然键：合集名（跨端身份，同 backup 合并的 (name, collection_type) 对齐）。
  final String name;

  /// 自然键：'collection' | 'playlist'。
  final String collectionType;

  /// 手动序最后人为改动毫秒戳（0 = 从未手动排序）；整合集 LWW 的比较键。
  final int orderUpdatedAt;

  /// 合集级删除墓碑毫秒戳；null = 活合集。
  final int? deletedAt;

  /// 成员（按 sortIndex 排序输出；sortIndex 即合集内手动序）。
  final List<CollectionManifestMember> members;

  /// 成员移出墓碑（防对端并集复活；重加清除）。
  final List<CollectionMemberTombstone> memberTombstones;

  factory CollectionManifestEntry.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('collection entry: not a JSON object');
    }
    final Object? name = json['name'];
    final Object? type = json['collectionType'];
    if (name is! String || name.isEmpty || type is! String || type.isEmpty) {
      throw const FormatException('collection entry: bad natural key');
    }
    final Object? orderUpdatedAt = json['orderUpdatedAt'];
    final Object? deletedAt = json['deletedAt'];
    final Object? rawMembers = json['members'];
    final Object? rawTombstones = json['memberTombstones'];
    if (rawMembers is! List || rawTombstones is! List) {
      throw const FormatException('collection entry: bad member lists');
    }
    return CollectionManifestEntry(
      name: name,
      collectionType: type,
      orderUpdatedAt: orderUpdatedAt is int ? orderUpdatedAt : 0,
      deletedAt: deletedAt is int ? deletedAt : null,
      members: <CollectionManifestMember>[
        for (final Object? m in rawMembers)
          CollectionManifestMember.fromJson(m),
      ],
      memberTombstones: <CollectionMemberTombstone>[
        for (final Object? t in rawTombstones)
          CollectionMemberTombstone.fromJson(t),
      ],
    );
  }

  Map<String, dynamic> toJson() {
    final List<CollectionManifestMember> sortedMembers =
        List<CollectionManifestMember>.of(members)
          ..sort((CollectionManifestMember a, CollectionManifestMember b) {
            final int byIndex = a.sortIndex.compareTo(b.sortIndex);
            if (byIndex != 0) return byIndex;
            final int byType = a.mediaType.compareTo(b.mediaType);
            if (byType != 0) return byType;
            return a.entryKey.compareTo(b.entryKey);
          });
    final List<CollectionMemberTombstone> sortedTombstones =
        List<CollectionMemberTombstone>.of(memberTombstones)
          ..sort((CollectionMemberTombstone a, CollectionMemberTombstone b) {
            final int byType = a.mediaType.compareTo(b.mediaType);
            if (byType != 0) return byType;
            return a.entryKey.compareTo(b.entryKey);
          });
    return <String, dynamic>{
      'name': name,
      'collectionType': collectionType,
      'orderUpdatedAt': orderUpdatedAt,
      if (deletedAt != null) 'deletedAt': deletedAt,
      'members': <Map<String, dynamic>>[
        for (final CollectionManifestMember m in sortedMembers) m.toJson(),
      ],
      'memberTombstones': <Map<String, dynamic>>[
        for (final CollectionMemberTombstone t in sortedTombstones) t.toJson(),
      ],
    };
  }
}

/// 清单里的一个合集成员。
class CollectionManifestMember {
  const CollectionManifestMember({
    required this.mediaType,
    required this.entryKey,
    required this.sortIndex,
  });

  /// 'epub' | 'srt' | 'video'（同 MediaCollectionItems.mediaType 值域）。
  final String mediaType;

  /// 条目稳定身份：epub=bookKey / srt=uid / video=bookUid。
  final String entryKey;

  /// 合集内序（整合集 LWW 覆盖的载荷）。
  final int sortIndex;

  factory CollectionManifestMember.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('collection member: not a JSON object');
    }
    final Object? mediaType = json['mediaType'];
    final Object? entryKey = json['entryKey'];
    final Object? sortIndex = json['sortIndex'];
    if (mediaType is! String ||
        mediaType.isEmpty ||
        entryKey is! String ||
        entryKey.isEmpty) {
      throw const FormatException('collection member: bad key');
    }
    return CollectionManifestMember(
      mediaType: mediaType,
      entryKey: entryKey,
      sortIndex: sortIndex is int ? sortIndex : 0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mediaType': mediaType,
        'entryKey': entryKey,
        'sortIndex': sortIndex,
      };
}

/// 清单里的一条成员移出墓碑。
class CollectionMemberTombstone {
  const CollectionMemberTombstone({
    required this.mediaType,
    required this.entryKey,
    required this.removedAt,
  });

  final String mediaType;
  final String entryKey;

  /// 移出毫秒戳（LWW；与对端「最后同步基线」比较判新旧，见引擎）。
  final int removedAt;

  factory CollectionMemberTombstone.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('member tombstone: not a JSON object');
    }
    final Object? mediaType = json['mediaType'];
    final Object? entryKey = json['entryKey'];
    final Object? removedAt = json['removedAt'];
    if (mediaType is! String ||
        mediaType.isEmpty ||
        entryKey is! String ||
        entryKey.isEmpty ||
        removedAt is! int) {
      throw const FormatException('member tombstone: bad fields');
    }
    return CollectionMemberTombstone(
      mediaType: mediaType,
      entryKey: entryKey,
      removedAt: removedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mediaType': mediaType,
        'entryKey': entryKey,
        'removedAt': removedAt,
      };
}
