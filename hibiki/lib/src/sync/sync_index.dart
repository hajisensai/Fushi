import 'dart:convert';

/// 同步「远端变更游标」命名空间（增量同步 / TODO-2656）。
///
/// 在此之前，每一轮同步都无条件把整个本地书表遍历一遍，**每本书**发一次
/// `listSyncFiles`（WebDAV 一次 PROPFIND / Drive 一次 files.list）。500 本书就是
/// 500 次网络往返，哪怕一本都没动过——「有没有更新」这个问题从来没被问过，答案
/// 每轮都是花 O(书数) 次请求重新算出来的。
///
/// 本命名空间下每台设备各存一份 [SyncIndexManifest]，文件名里编着该设备的
/// **revision**（[syncIndexAssetName]）。于是一次 `listChildren(__index__)` 就能
/// 回答「自上次以来，哪台设备动过远端」——无需下载任何内容。没动过的设备，它记录
/// 的那批书的远端状态就仍然成立，本端据此纯本地判定「双方一致」并整本跳过，零往返。
///
/// 与 `__collections__` / `__aggregate__` 的 per-device 清单同一范式（各写各的、
/// 绝不互相覆盖），故同样必须被 `isReservedSyncFolderName` 过滤掉，否则它会被当成
/// 一本书的文件夹（BUG-619 同类）。
const String kSyncIndexNamespace = '__index__';

/// 距上次**完整**书籍 sweep 超过此时长，下一轮强制忽略索引、走全量列举。
///
/// 索引的正确性建立在「所有写远端的设备都会 bump 自己的 revision」之上。这个前提
/// 对本版本的所有设备成立，但对**尚未升级**的旧版本设备不成立：它照旧直接改远端
/// progress 文件，却不碰 `__index__`，于是本端会以为「没人动过」而漏拉它的更新。
///
/// 周期性强制全量是这个前提失效时的兜底：漂移最多被隐藏一个周期，之后必然由一次
/// 完整列举纠正。24 小时是「用户察觉不到的延迟」与「不白跑全量」之间的取舍——升级
/// 共存窗口通常以天计，而全量 sweep 一天一次的成本可以忽略。
const int kSyncIndexFullSweepIntervalMs = 24 * 60 * 60 * 1000;

/// 一本书在索引里的远端已知状态 = 本端上次完整同步该书时，远端 progress 文件的样子。
///
/// [progressAt] / [progressFraction] 直接取自远端 progress 文件名里编码的两个值
/// （`progress_1_6_<timestamp>_<fraction>.json`）——同步方向本来就只由它们决定，
/// 所以索引记住它们，就等于记住了「上次那次网络往返问出来的答案」。
///
/// 两者同时为 null 是**有意义的记录**，不是「没记录」：它表示「本端上次确认过，
/// 远端这本书没有 progress 文件」。少了这一条，从没读过的书就永远命不中索引、每轮
/// 照旧发一次列举请求。
class SyncIndexBookEntry {
  const SyncIndexBookEntry({this.progressAt, this.progressFraction});

  /// 远端 progress 文件名里的时间戳；null = 远端没有 progress 文件。
  final int? progressAt;

  /// 远端 progress 文件名里的阅读分数（0..1）；null = 远端没有 progress 文件，
  /// 或该文件名解析不出分数（老格式）。
  final double? progressFraction;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (progressAt != null) 'p': progressAt,
        if (progressFraction != null) 'f': progressFraction,
      };

  factory SyncIndexBookEntry.fromJson(Map<String, dynamic> json) =>
      SyncIndexBookEntry(
        progressAt: (json['p'] as num?)?.toInt(),
        progressFraction: (json['f'] as num?)?.toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      other is SyncIndexBookEntry &&
      other.progressAt == progressAt &&
      other.progressFraction == progressFraction;

  @override
  int get hashCode => Object.hash(progressAt, progressFraction);

  @override
  String toString() =>
      'SyncIndexBookEntry(p: $progressAt, f: $progressFraction)';
}

/// 一台设备发布的索引清单。
///
/// [books] 是该设备上次完整 sweep 时观测到的每本书远端状态；[stages] 是该设备
/// 上次成功跑完各**非书籍**阶段时，那个阶段所依赖的**本地**状态指纹（见
/// [SyncIndexStage]）。两者语义不同，折叠方式也不同：books 跨设备取并集（谁都可能
/// 更新过某本书），stages 只有本端自己那份有意义（它描述的是本端本地的数据）。
class SyncIndexManifest {
  const SyncIndexManifest({
    required this.deviceId,
    required this.revision,
    required this.publishedAt,
    this.books = const <String, SyncIndexBookEntry>{},
    this.stages = const <String, String>{},
  });

  /// 当前索引格式版本。读到更高版本 = 对方是更新的 app，本端读不懂它的语义，
  /// 必须当作「索引不可用」整体退回全量，绝不能只挑认识的字段用（那会用旧语义
  /// 解释新数据，正是漏同步的来源）。
  static const int schemaVersion = 1;

  final String deviceId;
  final int revision;
  final int publishedAt;
  final Map<String, SyncIndexBookEntry> books;
  final Map<String, String> stages;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'deviceId': deviceId,
        'revision': revision,
        'publishedAt': publishedAt,
        'books': books.map((String k, SyncIndexBookEntry v) =>
            MapEntry<String, dynamic>(k, v.toJson())),
        'stages': stages,
      };

  String encode() => jsonEncode(toJson());

  /// 内容等价判据：只含真正描述「远端长什么样」的部分，**不含** [publishedAt]
  /// 与 [revision]。
  ///
  /// 发布时间每轮都不同，把它算进等价判据的话「内容没变」就永远为假，于是每轮都会
  /// 重传一份一模一样的清单——而每一次重传都是一个改动痕迹，会让所有对端的「无人
  /// 动过」判据失效。与 `CollectionManifest.canonicalJson` 把 `lastWrittenAt` 排除在
  /// 外是同一个道理。
  String canonicalJson() => jsonEncode(<String, dynamic>{
        'schemaVersion': schemaVersion,
        'deviceId': deviceId,
        'books': books.map((String k, SyncIndexBookEntry v) =>
            MapEntry<String, dynamic>(k, v.toJson())),
        'stages': stages,
      });

  /// 解析一份清单；格式不认识 / 版本高于本端 / 结构损坏一律返回 null（调用方据此
  /// 退回全量，而不是拿半懂的数据做跳过决策）。
  static SyncIndexManifest? tryParse(Object? json) {
    if (json is! Map) return null;
    final Map<String, dynamic> map = Map<String, dynamic>.from(json);
    final int? version = (map['schemaVersion'] as num?)?.toInt();
    if (version == null || version > schemaVersion) return null;

    final String? deviceId = map['deviceId'] as String?;
    final int? revision = (map['revision'] as num?)?.toInt();
    if (deviceId == null || deviceId.isEmpty || revision == null) return null;

    final Map<String, SyncIndexBookEntry> books =
        <String, SyncIndexBookEntry>{};
    final Object? rawBooks = map['books'];
    if (rawBooks is Map) {
      for (final MapEntry<Object?, Object?> e in rawBooks.entries) {
        final Object? k = e.key;
        final Object? v = e.value;
        if (k is! String || v is! Map) continue;
        books[k] = SyncIndexBookEntry.fromJson(Map<String, dynamic>.from(v));
      }
    }

    final Map<String, String> stages = <String, String>{};
    final Object? rawStages = map['stages'];
    if (rawStages is Map) {
      for (final MapEntry<Object?, Object?> e in rawStages.entries) {
        final Object? k = e.key;
        final Object? v = e.value;
        if (k is String && v is String) stages[k] = v;
      }
    }

    return SyncIndexManifest(
      deviceId: deviceId,
      revision: revision,
      publishedAt: (map['publishedAt'] as num?)?.toInt() ?? 0,
      books: books,
      stages: stages,
    );
  }

  static SyncIndexManifest? tryDecode(String raw) {
    try {
      return tryParse(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }
}

/// 从索引文件名解析出的三元组（无需下载文件内容即可得到）。
class SyncIndexAssetRef {
  const SyncIndexAssetRef({
    required this.name,
    required this.deviceId,
    required this.revision,
    required this.dirty,
  });

  final String name;
  final String deviceId;
  final int revision;

  /// 该设备**正处在一轮同步中**，随时可能改远端。它记录的书状态此刻不可信。
  final bool dirty;

  @override
  String toString() =>
      'SyncIndexAssetRef($deviceId r$revision ${dirty ? 'dirty' : 'clean'})';
}

const String _indexAssetPrefix = 'index-';
const String _indexAssetSuffix = '.json';
const String _dirtyMarker = 'dirty';
const String _cleanMarker = 'clean';

/// 索引资产名：`index-<deviceId>-r<revision>-<clean|dirty>.json`。
///
/// revision 与 dirty 编进**文件名**而不是只写在内容里，是这套机制省掉网络往返的
/// 全部原因：一次列举拿到的名字就够回答「谁动过 / 谁正在动」，不必逐个下载。
String syncIndexAssetName({
  required String deviceId,
  required int revision,
  required bool dirty,
}) =>
    '$_indexAssetPrefix$deviceId-r$revision-'
    '${dirty ? _dirtyMarker : _cleanMarker}$_indexAssetSuffix';

/// [syncIndexAssetName] 的逆。不是索引名返回 null。
///
/// **从右往左**剥（后缀 → clean/dirty → r<digits>），剩下的整段才是 deviceId：
/// deviceId 里若含 `-`，从左往右分割会把它切碎并错认设备身份，进而把两台设备的
/// 记录混成一台。
SyncIndexAssetRef? parseSyncIndexAssetName(String name) {
  if (!name.startsWith(_indexAssetPrefix)) return null;
  if (!name.endsWith(_indexAssetSuffix)) return null;

  String body = name.substring(
      _indexAssetPrefix.length, name.length - _indexAssetSuffix.length);

  final bool dirty;
  if (body.endsWith('-$_dirtyMarker')) {
    dirty = true;
    body = body.substring(0, body.length - _dirtyMarker.length - 1);
  } else if (body.endsWith('-$_cleanMarker')) {
    dirty = false;
    body = body.substring(0, body.length - _cleanMarker.length - 1);
  } else {
    return null;
  }

  final int sep = body.lastIndexOf('-r');
  if (sep <= 0) return null;
  final String revisionText = body.substring(sep + 2);
  final int? revision = int.tryParse(revisionText);
  if (revision == null || revision < 0 || revisionText != revision.toString()) {
    return null;
  }

  final String deviceId = body.substring(0, sep);
  if (deviceId.isEmpty) return null;

  return SyncIndexAssetRef(
    name: name,
    deviceId: deviceId,
    revision: revision,
    dirty: dirty,
  );
}

/// 非书籍阶段的稳定标识。每个阶段的「本地指纹」以此为键存进 [SyncIndexManifest.stages]。
///
/// 值是**持久化字符串**（进远端 JSON），改名会让升级后的第一轮把所有阶段判为
/// 「指纹不匹配」而全部重跑一次——不丢数据，但白跑，故没有充分理由不要改。
class SyncIndexStage {
  const SyncIndexStage._();

  /// 书籍阶段的**整体**本地指纹（全部书的 bookKey + 阅读位置时间戳）。
  ///
  /// 它不参与「跳过某本书」——那是 per-book 判据的事。它回答的是另一个问题：
  /// 「本轮书籍阶段有没有可能写远端？」本地这批时间戳与上轮完全相同、且远端无人
  /// 动过时，答案必然是「不会」，于是整轮同步可以连 dirty 租约都不必发布。
  static const String books = 'books';

  static const String dictionaries = 'dictionaries';
  static const String localAudio = 'localAudio';
  static const String audiobookPackages = 'audiobookPackages';
  static const String videoAssets = 'videoAssets';
  static const String collections = 'collections';
  static const String aggregate = 'aggregate';

  /// 全部阶段 id，供守卫测试穷举核对。
  ///
  /// 故意**不含**删除墓碑阶段：它算出的 deleteLocal 候选要经 UI 逐条确认，用户没
  /// 处理完时基线不推进；跳过它就等于把「还没答复的确认框」永久吞掉。它的成本本来
  /// 也只是一次列举加几份极小的墓碑 JSON，不值得为此冒吞掉用户确认的风险。
  static const List<String> all = <String>[
    books,
    dictionaries,
    localAudio,
    audiobookPackages,
    videoAssets,
    collections,
    aggregate,
  ];
}

/// 一轮同步开始时算出的「哪些活可以不干」。
///
/// 构造它只花**一次** `listChildren(__index__)`，外加为数不多的、只针对
/// 「revision 变过的对端」的清单下载。
class SyncIndexPlan {
  const SyncIndexPlan({
    required this.usable,
    required this.remoteUnchanged,
    required this.books,
    required this.ownStages,
    required this.ownRevision,
    required this.peerRevisions,
    required this.forcedFullSweep,
  });

  /// 索引整体可信。false = 本轮完全按老路子走（全量列举），且**照常发布**新索引，
  /// 使下一轮能重新用上。
  final bool usable;

  /// 自本端上次同步以来，没有任何**对端**设备动过远端（revision 全部未变、无人
  /// 处于 dirty、没有新增/消失的设备）。非书籍阶段的跳过必须以此为前提：那些阶段
  /// 的远端状态没有 per-item 时间戳可比，只能靠「整体没人动过」来断言。
  final bool remoteUnchanged;

  /// 跨设备折叠后的每本书远端已知状态（同一本书取 [progressAt] 最大的那份记录）。
  final Map<String, SyncIndexBookEntry> books;

  /// 本端上轮发布的各阶段本地指纹。
  final Map<String, String> ownStages;

  /// 本端当前 revision（发布新索引时在此基础上 +1）。
  final int ownRevision;

  /// 本轮观测到的各对端 revision，供本轮结束后写回本地缓存。
  final Map<String, int> peerRevisions;

  /// 本轮被周期性全量兜底（[kSyncIndexFullSweepIntervalMs]）强制走全量。
  final bool forcedFullSweep;

  /// 索引不可用时的保守 plan：什么都不跳过。
  static const SyncIndexPlan disabled = SyncIndexPlan(
    usable: false,
    remoteUnchanged: false,
    books: <String, SyncIndexBookEntry>{},
    ownStages: <String, String>{},
    ownRevision: 0,
    peerRevisions: <String, int>{},
    forcedFullSweep: false,
  );

  /// [stage] 这一阶段能否跳过：远端无人动过，且本端该阶段依赖的本地数据指纹与
  /// 上轮发布的完全相同。
  ///
  /// [currentFingerprint] 为 null 表示「这个阶段算不出指纹」（例如底层查询失败）
  /// ——一律不跳过。**不可指纹化必须等于不跳过**，反过来会把「不知道有没有变」
  /// 当成「没变」，那正是漏同步。
  bool canSkipStage(String stage, String? currentFingerprint) {
    if (!usable || !remoteUnchanged || currentFingerprint == null) return false;
    final String? published = ownStages[stage];
    return published != null && published == currentFingerprint;
  }
}

/// 把一批清单折叠成 [SyncIndexPlan.books]：同一本书以 [SyncIndexBookEntry.progressAt]
/// 最大的那份记录为准。
///
/// 「取最大」而不是「取最后写入的设备」：progressAt 是远端 progress 文件名里的
/// 时间戳，是一个所有设备共同观测同一个对象得到的值，不是各设备的私有状态。谁看到
/// 的时间戳更晚，谁的观测就更接近当前远端真相。
///
/// null（远端无 progress 文件）在这个序里最小：任何一台设备看到过真实的 progress
/// 文件，就说明它确实存在过，不能被另一台设备「我上次看的时候还没有」抹掉。
Map<String, SyncIndexBookEntry> foldSyncIndexBooks(
  Iterable<SyncIndexManifest> manifests,
) {
  final Map<String, SyncIndexBookEntry> folded = <String, SyncIndexBookEntry>{};
  for (final SyncIndexManifest m in manifests) {
    for (final MapEntry<String, SyncIndexBookEntry> e in m.books.entries) {
      final SyncIndexBookEntry? existing = folded[e.key];
      if (existing == null) {
        folded[e.key] = e.value;
        continue;
      }
      final int a = existing.progressAt ?? -1;
      final int b = e.value.progressAt ?? -1;
      if (b > a) folded[e.key] = e.value;
    }
  }
  return folded;
}

/// 把一组「名称 → 值」摊平成稳定指纹（键排序，故与遍历顺序无关）。
///
/// 阶段指纹的唯一要求是**本地状态一变它就变**，且**同样的状态永远算出同样的值**
/// ——包括跨进程、跨 app 版本、跨平台。这排除了 `Object.hashCode`：Dart 不保证它
/// 在不同运行间稳定，用它会让每轮都判成「变了」，跳过永远不生效；更糟的是它可能
/// 在某些平台上恰好稳定，于是问题只在部分用户身上出现。
String syncStageFingerprint(Map<String, Object?> parts) {
  final List<String> keys = parts.keys.toList()..sort();
  final StringBuffer buffer = StringBuffer();
  for (final String k in keys) {
    buffer
      ..write(k)
      ..write('=')
      ..write(parts[k])
      ..write(';');
  }
  return stableContentHash(buffer.toString());
}

/// FNV-1a（64 位）。自己实现而不是引 crypto：这不是安全哈希，只是变更检测，需要的
/// 只有「确定性」和「零依赖」。碰撞在此处的后果是漏跑一个阶段，概率 2^-64 量级，
/// 与磁盘静默损坏同数量级，不构成实际风险。
String stableContentHash(String input) {
  // 用两个 32 位半字模拟 64 位乘法，避免依赖 int 的位宽（web 上 int 是 double）。
  const int prime = 0x01000193;
  int hi = 0xcbf29ce4;
  int lo = 0x84222325;
  for (final int unit in input.codeUnits) {
    lo ^= unit;
    final int loProduct = lo * prime;
    final int hiProduct = hi * prime + (loProduct ~/ 0x100000000);
    lo = loProduct & 0xffffffff;
    hi = hiProduct & 0xffffffff;
  }
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}
