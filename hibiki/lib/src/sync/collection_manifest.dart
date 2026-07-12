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
    this.lastWrittenAt = 0,
    this.collections = const <CollectionManifestEntry>[],
  });

  /// 清单格式版本（向后兼容判据；解码只认 <= [currentVersion]）。
  static const int currentVersion = 1;

  /// 空清单（远端尚无 `collections.json` 时的合并起点）。
  static const CollectionManifest empty = CollectionManifest();

  final int version;

  /// 本 per-device 清单文件**最后写入的毫秒戳**（多端库联合视图 finding 1 因果修复）。
  /// 折叠多份对端清单时用它裁决「陈旧文件的活成员 vs 墓碑」：一个活成员仅当其所在文件的
  /// [lastWrittenAt] **晚于**该成员墓碑的 publishedAt 才算「看过墓碑后的有意重加」，否则
  /// 墓碑默认获胜。这消除了「发布端第二轮同步时自己已发布的墓碑 publishedAt==上轮基线、
  /// 被判旧闻而让陈旧对端文件里的活成员重加胜」的复活循环。旧文件 / 旧单文件缺该字段解码
  /// 为 0（恒陈旧，永远输给任何已发布墓碑）。
  ///
  /// **不进 [canonicalJson]**（内容等价判据只看合集/成员/墓碑），故只在真正内容变化时才
  /// 重写文件——每轮都重盖时戳会破坏「字节相等 ⇒ 跳过回写」的幂等、造成写放大。
  final int lastWrittenAt;

  /// 全部合集条目（活合集 + 已删合集的墓碑壳），无序输入、编码时排序。
  final List<CollectionManifestEntry> collections;

  /// 复制一份并盖上新的 [lastWrittenAt]（写盘前用当前发布时刻盖戳；内容不变）。
  CollectionManifest withLastWrittenAt(int ms) => CollectionManifest(
        version: version,
        lastWrittenAt: ms,
        collections: collections,
      );

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
    // lastWrittenAt 是 additive 文件级字段（finding 1）：旧清单缺它 / 非法 / 负值一律
    // 解码为 0（恒陈旧），绝不因缺字段拒绝解析——向后兼容读老写新。
    final Object? lastWrittenAt = json['lastWrittenAt'];
    return CollectionManifest(
      version: version,
      lastWrittenAt:
          (lastWrittenAt is int && lastWrittenAt >= 0) ? lastWrittenAt : 0,
      collections: <CollectionManifestEntry>[
        for (final Object? c in rawCollections)
          CollectionManifestEntry.fromJson(c),
      ],
    );
  }

  /// 编码为确定性排序的 JSON 结构（见类注释）。写盘用：含 [lastWrittenAt] 文件级字段。
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> map = _contentJson();
    // lastWrittenAt 单独附在内容之后：写盘时携带文件级时戳，但不进 canonicalJson（内容
    // 等价判据），故内容不变时回写门槛不触发、时戳不被每轮重盖（幂等，见类注释）。
    map['lastWrittenAt'] = lastWrittenAt;
    return map;
  }

  /// 内容部分的确定性排序 JSON（不含 [lastWrittenAt]）——变更检测的唯一依据。
  Map<String, dynamic> _contentJson() {
    // 跳过非法自然键条目（空 name / 空 collectionType）：绝不把本地脏行原样发布
    // 毒害对端（对端 fromJson 对空自然键抛 FormatException，拖垮整份清单解析）。
    final List<CollectionManifestEntry> sorted = <CollectionManifestEntry>[
      for (final CollectionManifestEntry c in collections)
        if (c.name.isNotEmpty && c.collectionType.isNotEmpty) c,
    ]..sort((CollectionManifestEntry a, CollectionManifestEntry b) {
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

  /// 规范化 JSON 字符串（确定性排序 ⇒ 内容相等则字节相等，供变更检测）。**不含
  /// [lastWrittenAt]**：文件级写盘时戳每轮不同，若纳入判据会让每轮都误判「内容变了」
  /// 而无谓回写，破坏幂等。
  String canonicalJson() => jsonEncode(_contentJson());
}

/// 清单里的一个合集：活合集（[deletedAt] == null）或删除墓碑壳（!= null，
/// 此时 [members] 与 [memberTombstones] 语义上为空——引擎归一化会丢弃）。
class CollectionManifestEntry {
  const CollectionManifestEntry({
    required this.name,
    required this.collectionType,
    this.orderUpdatedAt = 0,
    this.deletedAt,
    this.deletedPublishedAt,
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

  /// 合集级删除墓碑**首次进入共享清单**的毫秒戳（多端库联合视图 §2.3 因果修复）；
  /// null = 本端尚未发布该删除（一律视为新闻）。对端用「基线 vs publishedAt」判新旧
  /// （而非用移出端墙钟 [deletedAt] 对比本端基线，避免因果轴错位复活）。旧清单无该
  /// 字段时引擎回退用 [deletedAt] 裁决（读老写新）。
  final int? deletedPublishedAt;

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
    // 负删除墓碑戳非法（时间戳恒非负；负值会污染 max 比较与裁决，拒之）。
    if (deletedAt != null && (deletedAt is! int || deletedAt < 0)) {
      throw const FormatException('collection entry: bad deletedAt');
    }
    final Object? deletedPublishedAt = json['deletedPublishedAt'];
    if (deletedPublishedAt != null &&
        (deletedPublishedAt is! int || deletedPublishedAt < 0)) {
      throw const FormatException('collection entry: bad deletedPublishedAt');
    }
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
      deletedPublishedAt: deletedPublishedAt is int ? deletedPublishedAt : null,
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
    // 跳过非法条目（空 mediaType / 空 entryKey）：本地脏行绝不原样发布毒害对端
    // （对端 fromJson 会对空键抛 FormatException，一条坏成员会拖垮整份清单解析）。
    final List<CollectionManifestMember> sortedMembers =
        <CollectionManifestMember>[
      for (final CollectionManifestMember m in members)
        if (m.mediaType.isNotEmpty && m.entryKey.isNotEmpty) m,
    ]..sort((CollectionManifestMember a, CollectionManifestMember b) {
            final int byIndex = a.sortIndex.compareTo(b.sortIndex);
            if (byIndex != 0) return byIndex;
            final int byType = a.mediaType.compareTo(b.mediaType);
            if (byType != 0) return byType;
            return a.entryKey.compareTo(b.entryKey);
          });
    final List<CollectionMemberTombstone> sortedTombstones =
        <CollectionMemberTombstone>[
      for (final CollectionMemberTombstone t in memberTombstones)
        if (t.mediaType.isNotEmpty && t.entryKey.isNotEmpty && t.removedAt >= 0)
          t,
    ]..sort((CollectionMemberTombstone a, CollectionMemberTombstone b) {
            final int byType = a.mediaType.compareTo(b.mediaType);
            if (byType != 0) return byType;
            return a.entryKey.compareTo(b.entryKey);
          });
    return <String, dynamic>{
      'name': name,
      'collectionType': collectionType,
      'orderUpdatedAt': orderUpdatedAt,
      if (deletedAt != null) 'deletedAt': deletedAt,
      if (deletedPublishedAt != null) 'deletedPublishedAt': deletedPublishedAt,
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
    this.publishedAt,
  });

  final String mediaType;
  final String entryKey;

  /// 移出毫秒戳（移出端墙钟；保留做展示与**本端裁决**——本端自己移出的墓碑
  /// removedAt 与本端基线同一时钟轴可靠比较）。
  final int removedAt;

  /// 该墓碑**首次进入共享清单**的毫秒戳（多端库联合视图 §2.3 因果修复）；
  /// null = 本端尚未发布该移出（一律视为新闻）。**对端**用「基线 vs publishedAt」
  /// 判新旧——移出端墙钟 [removedAt] 与本端基线是不同因果轴（对端可能在移出端离线
  /// 期间推进过基线），直接比较会把上线后才发布的墓碑误判为旧闻→成员复活。旧清单
  /// 无该字段时引擎回退用 [removedAt] 裁决（读老写新）。
  final int? publishedAt;

  factory CollectionMemberTombstone.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('member tombstone: not a JSON object');
    }
    final Object? mediaType = json['mediaType'];
    final Object? entryKey = json['entryKey'];
    final Object? removedAt = json['removedAt'];
    // 负 removedAt 非法：时间戳恒非负，负值触发引擎 max 比较的 null 展开崩溃
    // （历史 `(lt ?? -1)` 哨兵与负值撞车），拒之。
    if (mediaType is! String ||
        mediaType.isEmpty ||
        entryKey is! String ||
        entryKey.isEmpty ||
        removedAt is! int ||
        removedAt < 0) {
      throw const FormatException('member tombstone: bad fields');
    }
    final Object? publishedAt = json['publishedAt'];
    if (publishedAt != null && (publishedAt is! int || publishedAt < 0)) {
      throw const FormatException('member tombstone: bad publishedAt');
    }
    return CollectionMemberTombstone(
      mediaType: mediaType,
      entryKey: entryKey,
      removedAt: removedAt,
      publishedAt: publishedAt is int ? publishedAt : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mediaType': mediaType,
        'entryKey': entryKey,
        'removedAt': removedAt,
        if (publishedAt != null) 'publishedAt': publishedAt,
      };
}
