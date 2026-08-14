import 'dart:io';

import 'package:fushi/src/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/collection_manifest.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

// ── 术语约定（命名统一轮审计词表）────────────────────────────────────────────
//
// 本文件（及互联域）的角色词汇统一如下，doc 注释里的「host …」均按此读：
// * **peer / 对端**：已配对的另一台设备（对称概念，不指角色）。
// * **host**：一次交互里**提供库**的角色（开着内嵌 server、被拉取清单/内容的一侧）。
// * **client**：一次交互里消费库的角色（拉清单、下载、上报进度的一侧）。
// * **Remote\***：从消费端视角描述「对端数据」的 wire DTO——类名的 Remote 指
//   「对端（通常是 host 角色）的条目」，`RemoteBookInfo` = 对端 host 书库里的一本书。
//   host 端 materialize 自己的库为同一 DTO 下发，client 端 fromJson 消费。

// ── 书籍 push 的元数据 header（BUG-1503）────────────────────────────────────
//
// `PUT /api/library/books/<title>` 的 body 是**裸 .epub 字节流**（无 multipart、
// 无 sidecar、无 query），所以随行元数据只能走自定义 header——沿用视频推送
// `X-Hibiki-Video-Title` 的既有先例。两侧共用这两个常量，避免字面量各写一份漂开。
//
// ⚠️ header 值只收 ASCII：写侧必须 `Uri.encodeComponent`，读侧 `Uri.decodeComponent`
// （日文书名直接塞进 header 会抛）。additive：没改过名就不发，旧 host 对未知 header
// 静默忽略，旧 client 不发 → 新 host 读到 null，两个方向都零破坏。

/// 本机用户给这本书改的显示名（`Uri.encodeComponent` 编码）。
const String kBookDisplayTitleHeader = 'X-Hibiki-Book-Display-Title';

/// [kBookDisplayTitleHeader] 的 LWW 毫秒戳（十进制 ASCII）。缺失 = 0 =「时刻未知」，
/// 收下的一方按 LWW 平局处理（保留本机），见 `FushiDatabase.setPrefIfNewer`。
const String kBookDisplayTitleAtHeader = 'X-Hibiki-Book-Display-Title-At';

// ── 键集 union diff（本地音频 / 有声书 / 词典共享）──────────────────────────

/// 按字符串键 union 的双向同步 diff 结果。
///
/// 本地音频（键 = displayName）、有声书（键 = bookKey）、词典（键 = 词典名）三条
/// 资产管道共用；删除不在此推断（交给各自的删除传播，见 BUG-086 A）。历史上
/// `LocalAudioSyncDiff` / `AudiobookSyncDiff` / `DictionarySyncDiff` 三个类字段
/// 完全相同、三个 compute 函数逐字相同，命名统一轮合并为单一类型。
class SyncKeyDiff {
  const SyncKeyDiff({required this.toPull, required this.toPush});

  /// 对端有 ∧ 本端无 → 需从对端拉取。
  final Set<String> toPull;

  /// 本端有 ∧ 对端无 → 需推送到对端。
  final Set<String> toPush;
}

/// 按键集 union 计算双向同步 diff（[SyncKeyDiff] 的唯一构造入口）。
///
/// [localKeys]  本端已有条目的键集合。
/// [remoteKeys] 对端已有条目的键集合。
SyncKeyDiff computeKeyUnionDiff({
  required Set<String> localKeys,
  required Set<String> remoteKeys,
}) {
  return SyncKeyDiff(
    toPull: remoteKeys.difference(localKeys),
    toPush: localKeys.difference(remoteKeys),
  );
}

// ── 本地音频 ──────────────────────────────────────────────────────────────────

/// host 实时本地音频来源的清单条目（键 = displayName）。
///
/// [displayName] 是用户设置的显示名，用作跨设备 union-key（与 orchestrator
/// `kSyncLocalAudioNamespace` 的资产名语义一致）。
class RemoteLocalAudioInfo {
  const RemoteLocalAudioInfo({required this.displayName});

  final String displayName;

  Map<String, Object?> toJson() =>
      <String, Object?>{'displayName': displayName};

  static RemoteLocalAudioInfo fromJson(Map<String, Object?> json) =>
      RemoteLocalAudioInfo(
        displayName: json['displayName']?.toString() ?? '',
      );
}

/// 旧名兼容：本地音频 diff 已并入 [SyncKeyDiff]。
@Deprecated('已并入 SyncKeyDiff（computeKeyUnionDiff），请改用新名')
typedef LocalAudioSyncDiff = SyncKeyDiff;

/// 旧名兼容：转发 [computeKeyUnionDiff]（键 = 本地音频 displayName）。
@Deprecated('已并入 computeKeyUnionDiff，请改用新名')
SyncKeyDiff computeLocalAudioSyncDiff({
  required Set<String> localNames,
  required Set<String> remoteNames,
}) =>
    computeKeyUnionDiff(localKeys: localNames, remoteKeys: remoteNames);

// ── 有声书包 ──────────────────────────────────────────────────────────────────

/// host 实时有声书的清单条目。
///
/// 两类有声书统一走本 DTO：
/// - **srt-backed**（EPUB 配对）：[bookKey] 非空（= `sanitizeTtuFilename(title)`），
///   在 Audiobooks/SrtBooks/AudioCues 表中以 bookKey 为外键；[uid] 是其 SrtBook 的
///   uid（新增，供 client 落地时定位）。
/// - **纯 SRT（standalone）有声书**：无 EPUB、无 Audiobooks 行、[bookKey] 为空，
///   身份只能靠 SrtBook 的 [uid]（cue/进度/持久目录全在 uid 命名空间）。旧枚举完全
///   遗漏这类书，无法跨设备下载/同步。
///
/// [identity] 是传输/URL 身份键：srt-backed 取 bookKey（向后兼容旧 client/host），
/// 纯 SRT 取 uid。host 端按此键先查 Audiobooks(bookKey) 再查 SrtBooks(uid) 解析。
/// [title] 可选，供显示用（允许 null）。
class RemoteAudiobookInfo {
  const RemoteAudiobookInfo({
    required this.bookKey,
    this.uid,
    this.title,
    this.positionMs = 0,
    this.positionUpdatedAtMs = 0,
    this.delayMs = 0,
    this.delayUpdatedAtMs = 0,
  });

  final String bookKey;

  /// SrtBook uid。纯 SRT 有声书（[bookKey] 空）的唯一身份；srt-backed 也带上供
  /// client 落地定位。旧 host 不下发此字段 → fromJson 得 null（向后兼容）。
  final String? uid;

  final String? title;

  /// host 端听书断点（毫秒）+ 最后更新时刻（互联完整支持批次：清单内联，供
  /// sweep 免逐本 GET、以及下载回填/首页展示；旧 host 不带 → 0，消费方回退
  /// 逐本 `GET /position`）。
  final int positionMs;
  final int positionUpdatedAtMs;

  /// host 端调轴（`audiobook_delay_<identity>` prefs，毫秒可负）+ 最后更新时刻
  /// （LWW；与视频 BUG-1620 同范式。旧 host / 从未带戳调过 → 0）。
  final int delayMs;
  final int delayUpdatedAtMs;

  /// 传输/URL 身份键：srt-backed=bookKey；纯 SRT（bookKey 空）=uid。
  String get identity => bookKey.isNotEmpty ? bookKey : (uid ?? '');

  /// 纯 SRT（standalone）有声书：无 EPUB 配对、无 Audiobooks 行、bookKey 为空。
  bool get isStandaloneSrt => bookKey.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'bookKey': bookKey,
        if (uid != null && uid!.isNotEmpty) 'uid': uid,
        'title': title,
        if (positionMs > 0) 'positionMs': positionMs,
        if (positionUpdatedAtMs > 0) 'positionUpdatedAtMs': positionUpdatedAtMs,
        if (delayMs != 0) 'delayMs': delayMs,
        if (delayUpdatedAtMs > 0) 'delayUpdatedAtMs': delayUpdatedAtMs,
      };

  static RemoteAudiobookInfo fromJson(Map<String, Object?> json) =>
      RemoteAudiobookInfo(
        bookKey: json['bookKey']?.toString() ?? '',
        uid: (json['uid']?.toString().isNotEmpty ?? false)
            ? json['uid']!.toString()
            : null,
        title: json['title']?.toString(),
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        positionUpdatedAtMs:
            (json['positionUpdatedAtMs'] as num?)?.toInt() ?? 0,
        delayMs: (json['delayMs'] as num?)?.toInt() ?? 0,
        delayUpdatedAtMs: (json['delayUpdatedAtMs'] as num?)?.toInt() ?? 0,
      );
}

/// host 端「有声书调轴跨设备同步」的**可选**能力（互联完整支持批次；与视频
/// [VideoDelayHost] 同范式——不并进主接口，避免十余个测试 fake 全量补桩）。
/// server 用 `is` 探测，host 不实现 → `/delay` 落 404，client best-effort 降级。
abstract interface class AudiobookDelayHost {
  /// 读 host 端有声书 [identity] 的调轴。返回 (毫秒（可负）, 更新时刻毫秒)；
  /// 无带戳记录时值取既有 `audiobook_delay_` pref（时间戳 0），未知 identity
  /// 返回 (0, 0)。
  Future<({int delayMs, int updatedAtMs})> getAudiobookDelay(String identity);

  /// 把 client 上报的调轴写入 host。「严格较新时间戳者胜」（[resolveDelayLww]）；
  /// clamp ±[kVideoSubtitleDelayLimitMs]；host 无该有声书时 no-op。
  Future<void> putAudiobookDelay(
      String identity, int delayMs, int updatedAtMs);
}

/// 旧名兼容：有声书 diff 已并入 [SyncKeyDiff]。
@Deprecated('已并入 SyncKeyDiff（computeKeyUnionDiff），请改用新名')
typedef AudiobookSyncDiff = SyncKeyDiff;

/// 旧名兼容：转发 [computeKeyUnionDiff]（键 = 有声书 bookKey）。
@Deprecated('已并入 computeKeyUnionDiff，请改用新名')
SyncKeyDiff computeAudiobookSyncDiff({
  required Set<String> localKeys,
  required Set<String> remoteKeys,
}) =>
    computeKeyUnionDiff(localKeys: localKeys, remoteKeys: remoteKeys);

// ── 词典 ──────────────────────────────────────────────────────────────────────

/// host 实时词典的清单条目（不含 contentHash：Phase 1 按名 union，与现有暂存
/// 路径同语义，避免引入跨设备哈希一致性的新风险；overwrite-by-hash 列为 follow-up）。
class RemoteDictionaryInfo {
  const RemoteDictionaryInfo({required this.name, required this.type});
  final String name;
  final String type;

  Map<String, Object?> toJson() =>
      <String, Object?>{'name': name, 'type': type};

  static RemoteDictionaryInfo fromJson(Map<String, Object?> json) =>
      RemoteDictionaryInfo(
        name: json['name']?.toString() ?? '',
        type: json['type']?.toString() ?? '',
      );
}

/// 旧名兼容：词典 diff 已并入 [SyncKeyDiff]。
@Deprecated('已并入 SyncKeyDiff（computeKeyUnionDiff），请改用新名')
typedef DictionarySyncDiff = SyncKeyDiff;

/// 旧名兼容：转发 [computeKeyUnionDiff]（键 = 词典名）。
@Deprecated('已并入 computeKeyUnionDiff，请改用新名')
SyncKeyDiff computeDictionarySyncDiff({
  required Set<String> localNames,
  required Set<String> remoteNames,
}) =>
    computeKeyUnionDiff(localKeys: localNames, remoteKeys: remoteNames);

// ── 合集归属（多端库联合视图 §2.3 任务5.1）────────────────────────────────────

/// 一条目在 host 端的**主合集归属**（跟随 [FushiDatabase.getPrimaryCollectionIdByEntry]
/// 的「最小 collectionId」折叠语义：一条目可属多合集，只带它折进的那一张）。
///
/// 远端占位卡据此归进对应合集行（UI 批任务 8-10 消费）：[collectionName] +
/// [collectionType] 是合集自然键（与合集清单 / 备份合并的 (name, collection_type) 对齐），
/// [sortIndex] 是该条目在该合集里的组内序（= `MediaCollectionItems.sortIndex`，与本地卡
/// `groupByCollections` 的 memberSortIndex 同源）。[RemoteBookInfo.collection] /
/// [RemoteVideoInfo.collection] 缺省 null = 该条目不属任何合集（散卡）。
class RemoteCollectionMembership {
  const RemoteCollectionMembership({
    required this.collectionName,
    required this.collectionType,
    required this.sortIndex,
  });

  /// 合集自然键：合集名。
  final String collectionName;

  /// 合集自然键：'collection' | 'playlist'。
  final String collectionType;

  /// 条目在该合集内的组内序（`MediaCollectionItems.sortIndex`）。
  final int sortIndex;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': collectionName,
        'collectionType': collectionType,
        'sortIndex': sortIndex,
      };

  /// 解析归属条目。非对象 / 缺自然键（旧 host 不带该字段）返回 null（向后兼容：
  /// 无归属 = 散卡，不破坏既有调用方）。
  static RemoteCollectionMembership? fromJson(Object? json) {
    if (json is! Map) return null;
    final Map<String, Object?> map = json.cast<String, Object?>();
    final String name = map['name']?.toString() ?? '';
    final String type = map['collectionType']?.toString() ?? '';
    if (name.isEmpty || type.isEmpty) return null;
    return RemoteCollectionMembership(
      collectionName: name,
      collectionType: type,
      sortIndex: _jsonInt(map['sortIndex']) ?? 0,
    );
  }
}

// ── Books ──────────────────────────────────────────────────────────────────

/// host 实时书籍的清单条目。
///
/// [title]      书名（与 DB `epub_books.title` 列一致）。**身份用**：`downloadId`
///              / `bookKey` 派生 / 去重全走它，永远是 raw 列值。
/// [displayTitle] 用户在 host 上改过的显示名（BUG-1488）。**只给人看**，绝不参与
///              任何键派生。null = host 没改过名 / 旧 host 不带该字段。
/// [hasContent] 存在可导出的 EPUB 根目录时为 true——表示该书可被导出。
///              无内容的书（extractDir 丢失或空）不应被 pull（与 orchestrator
///              `importRemoteBooks` 的跳过语义一致）。
class RemoteBookInfo {
  const RemoteBookInfo({
    required this.title,
    required this.hasContent,
    this.displayTitle,
    this.displayTitleAt = 0,
    this.bookKey,
    this.hasEmbeddedCover = false,
    this.coverUrl,
    this.coverPath,
    this.hasAudiobook = false,
    this.tags = const <String>[],
    this.tagsAddedAt = const <String, int>{},
    this.tagTombstones = const <String, int>{},
    this.collection,
    this.progressPercent = 0,
    this.progressUpdatedAtMs = 0,
    this.kind = MediaKind.epub,
  });

  /// 该书的媒体种类（BUG-1119）。additive wire 字段 `'kind'`：epub 缺省**不写键**
  /// （旧书清单 wire 字节完全不变），缺失/未知一律回落 [MediaKind.epub]（旧 host
  /// 兼容）。视频走独立 `/api/library/videos` 清单，天然 video，无此字段。
  final MediaKind kind;

  /// host 端阅读进度百分比（0..100，来自 host `MediaItems.position/duration`，
  /// 与本地首页「继续」条目同源同算）；0 = 未读/旧 host 未带。additive 字段：
  /// 旧 client 忽略、旧 host 不发——供新首页仪表盘把 host 在读书并进「继续」。
  final int progressPercent;

  /// host 端该书最近阅读时刻（epoch 毫秒，来自 host `reader_positions.updatedAt`）；
  /// 0 = 无记录/旧 host。仪表盘「继续」混排排序用。
  final int progressUpdatedAtMs;

  final String title;

  /// host 端用户自定义的显示名（BUG-1488；host `preferences` 表的
  /// `override_title://` 覆盖层，写入方 `MediaSource.setOverrideTitleFromMediaItem`）。
  ///
  /// additive wire 字段 `'displayTitle'`：**只在与 [title] 不同时才写键**，所以
  /// 「没改过名」的书清单 wire 字节完全不变、旧 client 忽略、旧 host 不发。
  /// 消费恒走 [displayName]——直接读本字段的调用点在旧 host 上会拿到 null。
  ///
  /// ⚠️ 身份红线：[downloadId] / `bookKey` / 去重键一律用 [title]，本字段永不参与。
  final String? displayTitle;

  /// [displayTitle] 的最后修改毫秒戳（BUG-1502，host `preferences.updated_at`）。
  ///
  /// additive wire 字段 `'displayTitleAt'`：只在 `> 0` 且真发了 [displayTitle]
  /// 时写键。**0 = 「时刻未知」**，涵盖两种对端：不带该键的旧 host（BUG-1488 那
  /// 一代只发名字不发时刻），以及 host 上 v84 迁移前就改好、之后没再动过的存量行。
  ///
  /// 收下 0 的一方按 LWW 平局处理 → 保留本机（见 `setPrefIfNewer`），所以旧对端
  /// 永远不会覆盖本机用户刚改的名字；本机没有 override 时仍照常采纳。
  final int displayTitleAt;

  final bool hasContent;
  final String? bookKey;

  /// host 端存在**书内封面文件**（EPUB 内嵌封面解析到磁盘存在的绝对路径，见
  /// [resolveEpubCoverFilePath]）。注意与 wire key `'hasCover'` 同名不同义：wire
  /// 上写的是 [hasDisplayCover]（内嵌封面 ∨ coverUrl ∨ coverPath 任一可用），
  /// 本字段只是其中「内嵌封面」一支——故 Dart 侧改名消歧，wire key 不动。
  final bool hasEmbeddedCover;
  final String? coverUrl;
  final String? coverPath;

  /// 该书在 host 端是否已配有有声书（bookKey 出现在 Audiobooks 表）。远端书卡据此
  /// 渲染类型徽章（耳机 / 书本），与本地书卡 `_getAudiobookInfo` 同源（TODO-655a）。
  final bool hasAudiobook;

  /// 该书在 host 端的标签名列表（TODO-1165）。标签是每设备本地数据，只传
  /// 名不传本地 id；client 下载后 getOrCreateTagByName + addTagToBook 重建映射。
  final List<String> tags;

  /// tags 稳健档 LWW：标签「名→加入戳」（client mergeRemoteBookTags 用）。空 = 旧 host
  /// 未带（退化为按 [tags] 名单只增 + 尊重本地移除墓碑）。
  final Map<String, int> tagsAddedAt;

  /// tags 稳健档 LWW：标签移除墓碑「名→移除戳」（host 移除标签跨端传播、防复活）。
  final Map<String, int> tagTombstones;

  /// 该书在 host 端的主合集归属（多端库联合视图 §2.3 任务5.1；null = 散卡）。
  /// 远端占位卡据此归进对应合集行（UI 批任务 10）。
  final RemoteCollectionMembership? collection;

  String get downloadId => _isNonEmpty(bookKey) ? bookKey! : title;

  /// 该书**给人看**的名字：host 改过名用改后的，否则回落 raw [title]。
  /// 一切 UI 上屏点必须走这里（与本地书的 `displayTitleForBook` 门面对称）。
  String get displayName => _isNonEmpty(displayTitle) ? displayTitle! : title;

  bool get hasDisplayCover =>
      hasEmbeddedCover || _isNonEmpty(coverUrl) || _isNonEmpty(coverPath);

  Map<String, Object?> toJson() => <String, Object?>{
        'title': title,
        if (_isNonEmpty(displayTitle) && displayTitle != title)
          'displayTitle': displayTitle,
        if (_isNonEmpty(displayTitle) &&
            displayTitle != title &&
            displayTitleAt > 0)
          'displayTitleAt': displayTitleAt,
        if (_isNonEmpty(bookKey)) 'bookKey': bookKey,
        'hasContent': hasContent,
        if (hasDisplayCover) 'hasCover': true,
        if (_isNonEmpty(coverUrl)) 'coverUrl': coverUrl,
        if (hasAudiobook) 'hasAudiobook': true,
        if (tags.isNotEmpty) 'tags': tags,
        if (tagsAddedAt.isNotEmpty) 'tagsAddedAt': tagsAddedAt,
        if (tagTombstones.isNotEmpty) 'tagTombstones': tagTombstones,
        if (collection != null) 'collection': collection!.toJson(),
        if (progressPercent > 0) 'progressPercent': progressPercent,
        if (progressUpdatedAtMs > 0) 'progressUpdatedAtMs': progressUpdatedAtMs,
        if (kind != MediaKind.epub) 'kind': kind.dbValue,
      };

  RemoteBookInfo copyWith({
    String? displayTitle,
    int? displayTitleAt,
    String? bookKey,
    bool? hasEmbeddedCover,
    String? coverUrl,
    String? coverPath,
    bool? hasAudiobook,
    List<String>? tags,
    Map<String, int>? tagsAddedAt,
    Map<String, int>? tagTombstones,
    RemoteCollectionMembership? collection,
    int? progressPercent,
    int? progressUpdatedAtMs,
    MediaKind? kind,
  }) =>
      RemoteBookInfo(
        title: title,
        hasContent: hasContent,
        displayTitle: displayTitle ?? this.displayTitle,
        displayTitleAt: displayTitleAt ?? this.displayTitleAt,
        bookKey: bookKey ?? this.bookKey,
        hasEmbeddedCover: hasEmbeddedCover ?? this.hasEmbeddedCover,
        coverUrl: coverUrl ?? this.coverUrl,
        coverPath: coverPath ?? this.coverPath,
        hasAudiobook: hasAudiobook ?? this.hasAudiobook,
        tags: tags ?? this.tags,
        tagsAddedAt: tagsAddedAt ?? this.tagsAddedAt,
        tagTombstones: tagTombstones ?? this.tagTombstones,
        collection: collection ?? this.collection,
        progressPercent: progressPercent ?? this.progressPercent,
        progressUpdatedAtMs: progressUpdatedAtMs ?? this.progressUpdatedAtMs,
        kind: kind ?? this.kind,
      );

  static RemoteBookInfo fromJson(Map<String, Object?> json) {
    final String? coverUrl = _jsonString(json['coverUrl']);
    final String? coverPath = _jsonString(json['coverPath']);
    return RemoteBookInfo(
      title: json['title']?.toString() ?? '',
      hasContent: json['hasContent'] == true,
      // 旧 host 无该键 → null → [displayName] 回落 raw title（向后兼容）。
      displayTitle: _jsonString(json['displayTitle']),
      // 旧 host 无该键 → 0 =「时刻未知」→ LWW 平局 → 保留本机（BUG-1502）。
      displayTitleAt: _jsonNonNegativeInt(json['displayTitleAt']),
      bookKey: _jsonString(json['bookKey']),
      // wire `hasCover` 是对端的 hasDisplayCover；解码侧无从区分「内嵌」与「其它
      // 来源」，与 coverUrl/coverPath 一并折进本字段（客户端只消费 hasDisplayCover）。
      hasEmbeddedCover: json['hasCover'] == true ||
          _isNonEmpty(coverUrl) ||
          _isNonEmpty(coverPath),
      coverUrl: coverUrl,
      coverPath: coverPath,
      hasAudiobook: json['hasAudiobook'] == true,
      tags: _jsonStringList(json['tags']),
      tagsAddedAt: _jsonNameIntMap(json['tagsAddedAt']),
      tagTombstones: _jsonNameIntMap(json['tagTombstones']),
      collection: RemoteCollectionMembership.fromJson(json['collection']),
      progressPercent:
          _jsonNonNegativeInt(json['progressPercent']).clamp(0, 100),
      progressUpdatedAtMs: _jsonNonNegativeInt(json['progressUpdatedAtMs']),
      // 缺失（旧 host）/未知（对端未来新增）一律回落 epub，绝不抛异常。
      kind: MediaKind.tryParse(_jsonString(json['kind'])) ?? MediaKind.epub,
    );
  }
}

/// 互联 host 活动事件（新首页 Activity 面板的远端数据源；host `activity_events`
/// 表最近 N 条的 wire DTO）。display-only：client 只用于与本地事件混排展示，
/// **不落库**（追加式本地表无跨端去重键，落库会在每次浏览时重复导入）。
class RemoteActivityEvent {
  const RemoteActivityEvent({
    required this.eventType,
    required this.mediaType,
    required this.title,
    required this.dateKey,
    required this.timestampMs,
    this.mediaKey,
    this.durationMs,
    this.charsDelta,
  });

  /// 'read' / 'watch' / 'added' / 'game'（同 ActivityEvents.eventType 值域）。
  final String eventType;

  /// 'book' / 'video' / 'game'。
  final String mediaType;

  final String title;

  /// 'YYYY-MM-DD'（host 本地时区的按天分组键）。
  final String dateKey;

  /// 精确发生时刻（epoch 毫秒）。
  final int timestampMs;

  final String? mediaKey;
  final int? durationMs;
  final int? charsDelta;

  Map<String, Object?> toJson() => <String, Object?>{
        'eventType': eventType,
        'mediaType': mediaType,
        'title': title,
        'dateKey': dateKey,
        'timestampMs': timestampMs,
        if (mediaKey != null) 'mediaKey': mediaKey,
        if (durationMs != null) 'durationMs': durationMs,
        if (charsDelta != null) 'charsDelta': charsDelta,
      };

  /// 宽容解码：字段缺失/类型错给安全默认（坏一条不拖垮整个列表由调用方 skip）。
  static RemoteActivityEvent fromJson(Map<String, Object?> json) {
    return RemoteActivityEvent(
      eventType: json['eventType']?.toString() ?? '',
      mediaType: json['mediaType']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      dateKey: json['dateKey']?.toString() ?? '',
      timestampMs: _jsonNonNegativeInt(json['timestampMs']),
      mediaKey: _jsonString(json['mediaKey']),
      durationMs: json['durationMs'] is int ? json['durationMs'] as int : null,
      charsDelta: json['charsDelta'] is int ? json['charsDelta'] as int : null,
    );
  }
}

/// 解析非负 int（非 int / 负值 → 0）。additive 数值字段的宽容解码。
int _jsonNonNegativeInt(Object? raw) {
  if (raw is int && raw >= 0) return raw;
  return 0;
}

/// 按 `sanitizeTtuFilename(title)` union 的书籍同步 diff 结果。
///
/// 删除由删除传播处理，不在此推断。
class BookSyncDiff {
  const BookSyncDiff({required this.toPull, required this.toPush});

  /// 远端有内容（hasContent==true）∧ 本端无 → 需从远端 pull。
  final Set<String> toPull;

  /// 本端有 ∧ 远端无 → 需推送到远端。
  final Set<String> toPush;
}

/// 按 `sanitizeTtuFilename(title)` union 计算书籍同步 diff。
///
/// [localKeys]          本端书籍的 sanitizeTtuFilename(title) 集合。
/// [remoteKeyHasContent] 远端书籍的 key → hasContent 映射；
///                       只有 hasContent==true 的远端书才进入 [BookSyncDiff.toPull]
///                       （无内容的书跳过，与 orchestrator importRemoteBooks 语义一致）。
BookSyncDiff computeBookSyncDiff({
  required Set<String> localKeys,
  required Map<String, bool> remoteKeyHasContent,
}) {
  final Set<String> toPull = <String>{};
  final Set<String> toPush = <String>{};

  for (final MapEntry<String, bool> entry in remoteKeyHasContent.entries) {
    if (entry.value && !localKeys.contains(entry.key)) {
      toPull.add(entry.key);
    }
  }
  for (final String key in localKeys) {
    if (!remoteKeyHasContent.containsKey(key)) {
      toPush.add(key);
    }
  }

  return BookSyncDiff(toPull: toPull, toPush: toPush);
}

/// 把 EPUB 行里持久化的封面 [coverPath]（通常是 **EPUB 内部相对 href**，如
/// `OEBPS/images/cover.jpg`）解析成磁盘上**存在的绝对文件路径**；没有可用封面
/// 时返回 null。
///
/// 纯函数（除文件存在性探测外无副作用）。host 的 `listBooks` 用它把相对 href 拼到
/// [extractDir] 再判存在——否则相对 href 被当绝对路径 `File(href).existsSync()` 恒
/// false，远端书卡永远只有占位图（TODO-033 #4：远端书籍没封面的根因，
/// TODO-007 只修对了绝对路径的视频侧）。
///
/// 探测顺序与 reader_fushi_source 的封面解析一致：先 [extractDir] + 声明的相对
/// href（去掉前导 `/`），再回退到约定名 `cover.jpg/jpeg/png`，取首个存在者。
/// [coverPath] 本身已是存在的绝对路径时（视频侧 / 旧数据）原样返回。
String? resolveEpubCoverFilePath({
  required String extractDir,
  required String? coverPath,
}) {
  bool exists(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  // 已是存在的绝对路径（视频封面就是绝对路径，故视频侧本就正常）：直接用。
  if (coverPath != null && coverPath.isNotEmpty && exists(coverPath)) {
    return coverPath;
  }
  if (extractDir.isEmpty) return null;

  final List<String> candidates = <String>[];
  if (coverPath != null && coverPath.isNotEmpty) {
    String rel = coverPath;
    if (rel.startsWith('/')) rel = rel.substring(1);
    candidates.add(p.join(extractDir, rel));
  }
  for (final String name in const <String>[
    'cover.jpg',
    'cover.jpeg',
    'cover.png',
  ]) {
    candidates.add(p.join(extractDir, name));
  }
  for (final String candidate in candidates) {
    if (exists(candidate)) return candidate;
  }
  return null;
}

/// host 端某本书的阅读进度（TODO-767 跨设备书籍进度同步）。
///
/// 字段照 `reader_positions` 列：[sectionIndex]/[normCharOffset]/[charOffset] 是
/// 阅读器恢复锚（[charOffset] = -1 表示无精确偏移，回退 [normCharOffset] 分数），
/// [updatedAtMs] 是该行 `updatedAt`（epoch 毫秒），跨设备冲突解决「取较新时间戳」用它
/// （见 [resolveBookProgressSync]）。[updatedAtMs] = 0 表示 host 无记录（该书从未读过）。
class RemoteBookProgress {
  const RemoteBookProgress({
    required this.sectionIndex,
    required this.normCharOffset,
    required this.charOffset,
    required this.updatedAtMs,
  });

  final int sectionIndex;
  final int normCharOffset;
  final int charOffset;
  final int updatedAtMs;

  /// host 无该书 `reader_positions` 行时的「空」进度（updatedAtMs=0）。
  static const RemoteBookProgress empty = RemoteBookProgress(
    sectionIndex: 0,
    normCharOffset: 0,
    charOffset: -1,
    updatedAtMs: 0,
  );

  Map<String, Object?> toJson() => <String, Object?>{
        'sectionIndex': sectionIndex,
        'normCharOffset': normCharOffset,
        'charOffset': charOffset,
        'updatedAtMs': updatedAtMs,
      };

  static RemoteBookProgress fromJson(Map<String, Object?> json) =>
      RemoteBookProgress(
        sectionIndex: _jsonInt(json['sectionIndex']) ?? 0,
        normCharOffset: _jsonInt(json['normCharOffset']) ?? 0,
        charOffset: _jsonInt(json['charOffset']) ?? -1,
        updatedAtMs: _jsonInt(json['updatedAtMs']) ?? 0,
      );
}

/// 书籍阅读进度跨设备冲突解决（TODO-767）——「取较新时间戳」last-write-wins，
/// 与视频/有声书统一的单维 LWW [resolvePositionLww] 同范式（取较新者；时间戳相等时
/// 取「读得更远」者）。本函数是其双维（sectionIndex + normCharOffset）变体，且胜者
/// 是整条 [RemoteBookProgress] 而非 (位置, 时间戳) 二元组——语义差异故未并入
/// [resolvePositionLww]，合并需单独评审。
///
/// host 收到 client 上报时用它决定是否覆盖已存进度，client 全量 sweep 时用它在 host
/// 真相与本地 `reader_positions` 之间选较新者再 upsert 回本地。纯函数。
///
/// [local]/[remote] 两侧进度。返回胜出的整条进度。两侧时间戳均为 0（都无记录）时
/// 取阅读位置更靠后者（先比 [RemoteBookProgress.sectionIndex] 再比 normCharOffset），
/// 保留 0 时间戳。
RemoteBookProgress resolveBookProgressSync({
  required RemoteBookProgress local,
  required RemoteBookProgress remote,
}) {
  if (remote.updatedAtMs > local.updatedAtMs) return remote;
  if (local.updatedAtMs > remote.updatedAtMs) return local;
  // 时间戳相等（含都为 0）：取阅读位置更靠后者（读得更远者胜），保留该时间戳。
  final bool remoteFurther = remote.sectionIndex > local.sectionIndex ||
      (remote.sectionIndex == local.sectionIndex &&
          remote.normCharOffset > local.normCharOffset);
  return remoteFurther ? remote : local;
}

/// 从远端书清单 [remote] 里剔除本端已存在的书（按 [localBookKeys] 去重）。
///
/// 纯函数。远端书的去重键 = `sanitizeTtuFilename(title)`（与 `EpubBooks.bookKey`
/// 派生一致，由调用方算好后传入 [keyOf]）。本端已有同 key 的书就不再在「配对设备」
/// 区重复展示（TODO-033 #6：远端与本地重复同一本书）。
List<RemoteBookInfo> dedupeRemoteBooks({
  required List<RemoteBookInfo> remote,
  required Set<String> localBookKeys,
  required String Function(String title) keyOf,
}) {
  return <RemoteBookInfo>[
    for (final RemoteBookInfo book in remote)
      if (!localBookKeys.contains(keyOf(book.title))) book,
  ];
}

// ── 视频 ──────────────────────────────────────────────────────────────────────

/// 播放断点 prefs 键「三件套」生成器：位置键、时间戳键、位置键→id 逆解析。
///
/// 视频（`video_remote_position_*`）与有声书（`audiobook_pos_*`）的断点键结构
/// 完全同构——`<prefix><id>` 位置键（毫秒）、`<prefix>at_<id>` 时间戳键（epoch
/// 毫秒）、以及从位置键反解 id（**必须排除更长前缀的时间戳键**，否则会把
/// `<prefix>at_<id>` 误当成以 `at_` 开头的 id）。历史上两组三件套逐字复制（连
/// 上述坑注释都是复制的），命名统一轮收口成本类；**键字符串逐字节不变**，由
/// `position_pref_keys_guard_test.dart` 守卫锁死。
class PositionPrefKeys {
  const PositionPrefKeys(this.positionPrefix);

  /// 位置键前缀（`video_remote_position_` / `audiobook_pos_`）。
  final String positionPrefix;

  /// 时间戳键前缀：`<positionPrefix>at_`。
  String get atPrefix => '${positionPrefix}at_';

  /// [id] 的位置键（值 = 断点毫秒）。
  String positionKey(String id) => '$positionPrefix$id';

  /// [id] 的「最后更新时间」键（值 = epoch 毫秒；LWW 冲突解决用，见
  /// [resolvePositionLww]）。
  String atKey(String id) => '$atPrefix$id';

  /// [positionKey] 的逆：从位置键反解 id；时间戳键（更长前缀 [atPrefix]）、
  /// 非本键空间、空 id 一律返回 null。
  String? idFromPositionKey(String key) {
    if (key.startsWith(atPrefix)) return null;
    if (!key.startsWith(positionPrefix)) return null;
    final String id = key.substring(positionPrefix.length);
    return id.isEmpty ? null : id;
  }
}

/// 视频远端断点三件套（TODO-559/653）。前缀冻结：`video_remote_position_`。
const PositionPrefKeys videoRemotePositionPrefKeys =
    PositionPrefKeys('video_remote_position_');

/// 有声书断点三件套（BUG-471）。前缀冻结：`audiobook_pos_`（与
/// `AudiobookRepository._kPositionMsKeyPrefix` 同公式）。
const PositionPrefKeys audiobookPositionPrefKeys =
    PositionPrefKeys('audiobook_pos_');

/// 视频远端断点位置 prefs key（TODO-559/653）——单一真相源，host service 与
/// video_fushi_page `_remotePositionPrefKey` 共用同一公式。
///
/// 在线远端视频在 client/host 本地都按稳定 bookUid（= `RemoteVideoInfo.id`）落
/// Drift `preferences` 表。host 自己播放该视频时也用同一 key，故 host 上的这条 prefs
/// 即跨设备进度的真相源。
String videoRemotePositionPrefKey(String bookUid) =>
    videoRemotePositionPrefKeys.positionKey(bookUid);

/// [videoRemotePositionPrefKey] 对应的「最后更新时间」prefs key（epoch 毫秒）。
/// 冲突解决「取较新时间戳」需要它（见 [resolvePositionLww]）。
String videoRemotePositionAtPrefKey(String bookUid) =>
    videoRemotePositionPrefKeys.atKey(bookUid);

/// 远端**播放列表按集**断点位置 prefs key（TODO-885）——单一真相源，host service 与
/// video_fushi_page 共用同一公式。
///
/// 设计：[episodeIndex] == 0 时回退到整书 [videoRemotePositionPrefKey]（与单视频 /
/// 旧 TODO-559 prefs 完全同键，无迁移、向后兼容）；index>0 才用带 `#ep<index>` 后缀的
/// 按集键，各集进度互不干扰。client 恢复某集、host 反查某集进度都用它。
String videoRemotePositionEpisodePrefKey(String bookUid, int episodeIndex) =>
    episodeIndex <= 0
        ? videoRemotePositionPrefKey(bookUid)
        : 'video_remote_position_$bookUid#ep$episodeIndex';

/// [videoRemotePositionEpisodePrefKey] 对应的「最后更新时间」prefs key（epoch 毫秒）。
String videoRemotePositionEpisodeAtPrefKey(String bookUid, int episodeIndex) =>
    episodeIndex <= 0
        ? videoRemotePositionAtPrefKey(bookUid)
        : 'video_remote_position_at_$bookUid#ep$episodeIndex';

/// [videoRemotePositionPrefKey] 的逆：从位置 prefs key 反解出 bookUid，非该 key 返回
/// null。用于全量同步枚举「本地看过的流式视频 uid」（无 VideoBooks 行也有此 prefs，
/// TODO-816 断点①）。时间戳键的排除见 [PositionPrefKeys.idFromPositionKey]。
String? videoUidFromRemotePositionPrefKey(String key) =>
    videoRemotePositionPrefKeys.idFromPositionKey(key);

/// 视频字幕调轴（delayMs）跨设备三件套——键结构与断点三件套同构（复用
/// [PositionPrefKeys]，值语义不同：断点是位置毫秒，这里是可负的调轴毫秒）。
/// 前缀冻结：`video_remote_delay_`。
///
/// 为什么需要（互联远端调轴不持久化 bug）：断点有「本地 prefs + LWW + 上报 host」
/// 三件套，而调轴此前只有 host→client 单向下发（BUG-996）——client 远端播放里调轴
/// 写的是 `VideoBooks.delayMs` 的 UPDATE，但远端视频在 client 无行，静默 0 行写入；
/// 重进又被 host 清单值覆盖归 0。本三件套补上 client 侧持久化与双向 LWW。
const PositionPrefKeys videoRemoteDelayPrefKeys =
    PositionPrefKeys('video_remote_delay_');

/// 视频 [bookUid] 的字幕调轴 prefs key（值 = 调轴毫秒，可负）。client 远端播放与
/// host 本机播放共用同一公式（与断点键空间同范式，TODO-816）。
String videoRemoteDelayPrefKey(String bookUid) =>
    videoRemoteDelayPrefKeys.positionKey(bookUid);

/// [videoRemoteDelayPrefKey] 对应的「最后更新时间」prefs key（epoch 毫秒）。
/// LWW 冲突解决用（见 [resolveDelayLww]）。
String videoRemoteDelayAtPrefKey(String bookUid) =>
    videoRemoteDelayPrefKeys.atKey(bookUid);

/// 字幕调轴统一 clamp 界（±10 分钟，毫秒）。页面滑条 / host 端 PUT 收口共用，
/// 防越界值经互联写进 DB/prefs。
const int kVideoSubtitleDelayLimitMs = 600000;

/// 字幕调轴跨设备冲突解决——「严格较新时间戳者胜」。纯函数。
///
/// 与 [resolvePositionLww] 分开的理由：位置的平局规则「取较大位置（看得更远者胜）」
/// 对调轴没有意义（调轴可负、大小不代表新旧）。调轴的平局（含两侧都无时间戳的旧
/// 数据）保守取 [aDelayMs] 侧——调用方把「平局时应保留的一侧」放 a：host 收 PUT 时
/// a=已存值（仅严格更新才覆盖）；client 起播决议时 a=host 下发值（两侧都无戳 =
/// 本机从未调过，跟随 host，保留 BUG-996 行为）。
({int delayMs, int updatedAtMs}) resolveDelayLww({
  required int aDelayMs,
  required int aUpdatedAtMs,
  required int bDelayMs,
  required int bUpdatedAtMs,
}) =>
    bUpdatedAtMs > aUpdatedAtMs
        ? (delayMs: bDelayMs, updatedAtMs: bUpdatedAtMs)
        : (delayMs: aDelayMs, updatedAtMs: aUpdatedAtMs);

/// 播放位置跨设备冲突解决——「取较新时间戳」last-write-wins（LWW）。
///
/// 视频（TODO-653）与有声书（BUG-471）共用同一实现：历史上
/// `resolveVideoPositionSync` 与 `resolveAudiobookPositionSync` 除注释外逐字节
/// 相同，命名统一轮合并为本函数。纯函数。
///
/// host 收到 client 上报时用它决定是否覆盖已存进度，client 恢复 / 全量 sweep 时
/// 用它在 host 真相与本地 prefs 之间选较新者。旧数据无独立时间戳记 0，被任何带
/// 时间戳的对端进度盖过（向后兼容降级）。
///
/// [localPositionMs]/[localUpdatedAtMs] 一侧；[remotePositionMs]/[remoteUpdatedAtMs]
/// 另一侧。返回胜出的 (位置, 更新时间)。两侧时间戳均为 0（都无记录）时返回较大位置
/// （看/听得更远者胜），保留该时间戳。
///
/// 关系脚注（本轮未并入，合并需单独评审）：书籍进度 [resolveBookProgressSync] 是
/// 同范式的双维（sectionIndex + normCharOffset）变体；云通道
/// `SyncManager._determineSyncDirection` 是同范式的方向枚举变体（返回同步方向而非
/// 胜者值，且带存储网格量化 tie-break）。
({int positionMs, int updatedAtMs}) resolvePositionLww({
  required int localPositionMs,
  required int localUpdatedAtMs,
  required int remotePositionMs,
  required int remoteUpdatedAtMs,
}) {
  if (remoteUpdatedAtMs > localUpdatedAtMs) {
    return (positionMs: remotePositionMs, updatedAtMs: remoteUpdatedAtMs);
  }
  if (localUpdatedAtMs > remoteUpdatedAtMs) {
    return (positionMs: localPositionMs, updatedAtMs: localUpdatedAtMs);
  }
  // 时间戳相等（含都为 0）：取较大位置（看/听得更远者胜），保留该时间戳。
  final int winnerPos =
      localPositionMs >= remotePositionMs ? localPositionMs : remotePositionMs;
  return (positionMs: winnerPos, updatedAtMs: localUpdatedAtMs);
}

/// 旧名兼容：视频进度 LWW 已并入 [resolvePositionLww]。
@Deprecated(
    '已并入 resolvePositionLww（与 resolveAudiobookPositionSync 逐字节相同），请改用新名')
({int positionMs, int updatedAtMs}) resolveVideoPositionSync({
  required int localPositionMs,
  required int localUpdatedAtMs,
  required int remotePositionMs,
  required int remoteUpdatedAtMs,
}) =>
    resolvePositionLww(
      localPositionMs: localPositionMs,
      localUpdatedAtMs: localUpdatedAtMs,
      remotePositionMs: remotePositionMs,
      remoteUpdatedAtMs: remoteUpdatedAtMs,
    );

// ── 有声书进度（BUG-471）──────────────────────────────────────────────────────

/// 有声书播放位置 pref key（毫秒）——单一真相源，host service 与
/// `AudiobookRepository._kPositionMsKeyPrefix` 共用同一公式。
String audiobookPositionPrefKey(String bookKey) =>
    audiobookPositionPrefKeys.positionKey(bookKey);

/// [audiobookPositionPrefKey] 对应的「最后更新时间」pref key（epoch 毫秒）——与
/// `AudiobookRepository._kPositionAtMsKeyPrefix` 同公式。冲突解决「取较新时间戳」用它。
String audiobookPositionAtPrefKey(String bookKey) =>
    audiobookPositionPrefKeys.atKey(bookKey);

/// 有声书调轴三件套（互联完整支持批次）——键结构与断点三件套同构。值键
/// `audiobook_delay_<identity>` 是既有冻结键（`AudiobookRepository._kDelayMsKeyPrefix`
/// 同公式）；时间戳键 `audiobook_delay_at_<identity>` 为 LWW 新增（repo 的
/// `updateDelayMs` 现同步盖戳）。identity = srt-backed 的 bookKey / 纯 SRT 的 uid，
/// 与断点键空间同一身份约定。
const PositionPrefKeys audiobookDelayPrefKeys =
    PositionPrefKeys('audiobook_delay_');

/// 有声书 [identity] 的调轴 pref key（值 = 毫秒，可负）。
String audiobookDelayPrefKey(String identity) =>
    audiobookDelayPrefKeys.positionKey(identity);

/// [audiobookDelayPrefKey] 对应的「最后更新时间」pref key（epoch 毫秒；LWW 用）。
String audiobookDelayAtPrefKey(String identity) =>
    audiobookDelayPrefKeys.atKey(identity);

/// [audiobookPositionPrefKey] 的逆：从位置 pref key 反解出 bookKey，非该 key 返回
/// null。用于全量同步枚举「本地有有声书播放进度的 bookKey」。时间戳键的排除见
/// [PositionPrefKeys.idFromPositionKey]。
String? audiobookKeyFromPositionPrefKey(String key) =>
    audiobookPositionPrefKeys.idFromPositionKey(key);

/// 旧名兼容：有声书进度 LWW（BUG-471）已并入 [resolvePositionLww]。
@Deprecated('已并入 resolvePositionLww（与 resolveVideoPositionSync 逐字节相同），请改用新名')
({int positionMs, int updatedAtMs}) resolveAudiobookPositionSync({
  required int localPositionMs,
  required int localUpdatedAtMs,
  required int remotePositionMs,
  required int remoteUpdatedAtMs,
}) =>
    resolvePositionLww(
      localPositionMs: localPositionMs,
      localUpdatedAtMs: localUpdatedAtMs,
      remotePositionMs: remotePositionMs,
      remoteUpdatedAtMs: remoteUpdatedAtMs,
    );

/// host 视频容器内封字幕轨的清单条目（[RemoteVideoInfo.embeddedSubtitleTracks]
/// 的元素）：[streamIndex]/[codec] 定位轨道，[isText] 区分文本轨与图形轨，
/// [url]/[fileName] 是 client 侧下载该轨转出文本时的定位与落地名。
class RemoteVideoEmbeddedSubtitleTrack {
  const RemoteVideoEmbeddedSubtitleTrack({
    required this.streamIndex,
    required this.codec,
    this.language,
    this.title,
    this.isText = true,
    this.url,
    this.fileName,
  });

  final int streamIndex;
  final String codec;
  final String? language;
  final String? title;
  final bool isText;
  final String? url;
  final String? fileName;

  Map<String, Object?> toJson() => <String, Object?>{
        'streamIndex': streamIndex,
        'codec': codec,
        if (_isNonEmpty(language)) 'language': language,
        if (_isNonEmpty(title)) 'title': title,
        'isText': isText,
        if (_isNonEmpty(url)) 'url': url,
        if (_isNonEmpty(fileName)) 'fileName': fileName,
      };

  RemoteVideoEmbeddedSubtitleTrack copyWith({
    String? url,
    String? fileName,
  }) =>
      RemoteVideoEmbeddedSubtitleTrack(
        streamIndex: streamIndex,
        codec: codec,
        language: language,
        title: title,
        isText: isText,
        url: url ?? this.url,
        fileName: fileName ?? this.fileName,
      );

  static RemoteVideoEmbeddedSubtitleTrack fromJson(
    Map<String, Object?> json,
  ) =>
      RemoteVideoEmbeddedSubtitleTrack(
        streamIndex: _jsonInt(json['streamIndex']) ?? -1,
        codec: json['codec']?.toString() ?? '',
        language: _jsonString(json['language']),
        title: _jsonString(json['title']),
        isText: json['isText'] != false,
        url: _jsonString(json['url']),
        fileName: _jsonString(json['fileName']),
      );
}

/// 远端播放列表中的一集（TODO-885）。
///
/// **铁律：只带 [index]+[title]，绝不带 host 端文件 path**——path 是 host 本地绝对
/// 路径，client 无意义且会泄露 host 文件结构。client 持 (bookUid, episodeIndex) 向
/// server 请求该集的流式 url / 字幕，server 端按 `playlistJson[episodeIndex].path`
/// 反查真实文件（DB-only，沿用既有「绝不接受外部传入 path」安全契约）。
class RemoteVideoEpisode {
  const RemoteVideoEpisode({required this.index, required this.title});

  /// 该集在 `VideoBooks.playlistJson` 数组里的下标（= client 请求时传的 episodeIndex）。
  final int index;

  /// 集标题（来自 m3u8 `#EXTINF` 解析，或回退文件名）。
  final String title;

  Map<String, Object?> toJson() =>
      <String, Object?>{'index': index, 'title': title};

  static RemoteVideoEpisode fromJson(Map<String, Object?> json) =>
      RemoteVideoEpisode(
        index: _jsonInt(json['index']) ?? 0,
        title: json['title']?.toString() ?? '',
      );
}

/// host 实时视频的清单条目（只读，不同步——视频文件通常过大，不走同步管道）。
///
/// [id] 即 `VideoBooks.bookUid`，从文件名派生的稳定字符串（如 `video/my_film`
/// 或 `video/playlist/series`）。host 服务用 id 反查 DB 行拿真实路径，client
/// 持 id 请求流式传输时 **host 只做 DB 查询，绝不接受外部传入的文件路径**。
///
/// [sizeBytes] 对单视频是当前集文件大小（字节）；播放列表取第一集大小；
///             文件不存在或无法 stat 时为 null。
/// [durationMs] DB 无 duration 列，此字段留给后续任务由 ffprobe/libmpv 填充；
///              目前恒为 null（占位）。
/// [hasSubtitle] host 能找到可下载/可查词的文本字幕时为 true；
///               包括当前集 sidecar 或容器内封文本轨，不包括 PGS/DVD 等图形轨。
/// [subtitleFileName] host 找到的 sidecar 字幕文件名（含真实扩展名），供 client
///                    下载到本地临时文件时保留 `.ass/.ssa/.vtt/.srt` 解析语义。
///                    内封字幕的临时下载名在 [RemoteVideoEmbeddedSubtitleTrack.fileName]。
class RemoteVideoInfo {
  const RemoteVideoInfo({
    required this.id,
    required this.title,
    this.sizeBytes,
    this.hasSubtitle = false,
    this.subtitleFileName,
    this.embeddedSubtitleTracks = const <RemoteVideoEmbeddedSubtitleTrack>[],
    this.durationMs,
    this.hasCover = false,
    this.coverUrl,
    this.coverPath,
    this.positionMs = 0,
    this.positionUpdatedAtMs = 0,
    this.delayMs = 0,
    this.delayUpdatedAtMs = 0,
    this.audioTrackId,
    this.completedAt,
    this.episodes = const <RemoteVideoEpisode>[],
    this.currentEpisode = 0,
    this.tags = const <String>[],
    this.tagsAddedAt = const <String, int>{},
    this.tagTombstones = const <String, int>{},
    this.collection,
  });

  final String id;
  final String title;
  final int? sizeBytes;
  final bool hasSubtitle;
  final String? subtitleFileName;
  final List<RemoteVideoEmbeddedSubtitleTrack> embeddedSubtitleTracks;
  final int? durationMs;
  final bool hasCover;
  final String? coverUrl;
  final String? coverPath;

  /// 远端播放列表的剧集（TODO-885）。空 = 单视频（向后兼容）；length>1 = 多集播放列表。
  final List<RemoteVideoEpisode> episodes;

  /// 默认起播集下标（= host 端 `VideoBooks.currentEpisode`）。单视频恒 0。
  final int currentEpisode;

  /// 该视频在 host 端的标签名列表（TODO-1165）。标签每设备本地，只传名；
  /// client 下载后 getOrCreateTagByName + addTagToVideoBook 重建映射。
  final List<String> tags;

  /// tags 稳健档 LWW：标签「名→加入戳」（下载端 mergeRemoteVideoTags 用，云清单携带）。
  /// 空 = 旧端未带（退化为按 [tags] 名单只增）。
  final Map<String, int> tagsAddedAt;

  /// tags 稳健档 LWW：标签移除墓碑「名→移除戳」（跨端传播删除/改名、防复活）。
  final Map<String, int> tagTombstones;

  /// 该视频在 host 端的主合集归属（多端库联合视图 §2.3 任务5.1；null = 散卡）。
  /// 远端占位卡据此归进对应合集行（UI 批任务 10）。
  final RemoteCollectionMembership? collection;

  /// 是否为多集远端播放列表（≥2 集）。client UI 据此渲染集数角标 + 切集面板。
  bool get isPlaylist => episodes.length > 1;

  /// host 端记录的该视频上次播放断点（毫秒，TODO-653 跨设备视频进度同步）。
  ///
  /// 视频远端是 host/client 模型——client 不存视频、只从 host 流式播放——故进度的
  /// 唯一真相源是 host，落 host 自己的 `video_remote_position_<bookUid>` prefs（与
  /// host 本地播放该视频时同一键空间，见 video_fushi_page `_remotePositionPrefKey`）。
  /// 0 表示无记录（从头）。
  final int positionMs;

  /// [positionMs] 的最后更新时间（epoch 毫秒）。跨设备冲突解决用「取较新时间戳」
  /// （last-write-wins by timestamp），与有声书进度的 `_determineSyncDirection`
  /// 同范式。0 表示无记录。
  final int positionUpdatedAtMs;

  /// host 端该视频的字幕时序偏移（毫秒，可负；BUG-996）。设备无关的纯时序设置，
  /// 跨端语义一致 → 远端播放时应用，使桌面设的字幕调轴在手机跟随。取值为 host 端
  /// `video_remote_delay_` prefs（带戳，client 上报 / host 本机调轴写入）与旧
  /// `VideoBooks.delayMs`（无戳记 0）经 [resolveDelayLww] 的胜者。
  final int delayMs;

  /// [delayMs] 的最后更新时间（epoch 毫秒）。跨设备冲突解决「严格较新者胜」
  /// （[resolveDelayLww]）。0 = 旧 host 未带 / 从未有人带戳调过轴（client 侧视为
  /// 「host 无新主张」，本机带戳值即胜）。
  final int delayUpdatedAtMs;

  /// host 端该视频的音轨偏好（系列级 ?? 本集 `VideoBooks.audioTrackId`，schema v52
  /// 同系列音轨记忆；null = host 没选过 → client 跟随 libmpv 默认轨）。同一文件的
  /// 轨 id 跨设备同义，client 本机没选过音轨时按它起播（远端音轨持久化 bug 的
  /// host→client 半边；client 自己的选择落本地 prefs、优先于此值）。
  final String? audioTrackId;

  /// host 端该视频的「看完」时刻（epoch 毫秒；null = 未看完）。client 剧集面板的
  /// 看完角标（Jellyfin played 勾）数据源——此前远端集无口径恒无标记。
  final int? completedAt;

  bool get hasDisplayCover =>
      hasCover || _isNonEmpty(coverUrl) || _isNonEmpty(coverPath);

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        'hasSubtitle': hasSubtitle,
        if (_isNonEmpty(subtitleFileName)) 'subtitleFileName': subtitleFileName,
        if (embeddedSubtitleTracks.isNotEmpty)
          'embeddedSubtitleTracks': <Map<String, Object?>>[
            for (final RemoteVideoEmbeddedSubtitleTrack track
                in embeddedSubtitleTracks)
              track.toJson(),
          ],
        if (durationMs != null) 'durationMs': durationMs,
        if (hasDisplayCover) 'hasCover': true,
        if (_isNonEmpty(coverUrl)) 'coverUrl': coverUrl,
        if (positionMs > 0) 'positionMs': positionMs,
        if (positionUpdatedAtMs > 0) 'positionUpdatedAtMs': positionUpdatedAtMs,
        if (delayMs != 0) 'delayMs': delayMs,
        if (delayUpdatedAtMs > 0) 'delayUpdatedAtMs': delayUpdatedAtMs,
        if (_isNonEmpty(audioTrackId)) 'audioTrackId': audioTrackId,
        if (completedAt != null) 'completedAt': completedAt,
        // 单视频（episodes <=1）向后兼容：不写 episodes/currentEpisode 键。
        if (episodes.length > 1) ...<String, Object?>{
          'episodes': <Map<String, Object?>>[
            for (final RemoteVideoEpisode ep in episodes) ep.toJson(),
          ],
          if (currentEpisode > 0) 'currentEpisode': currentEpisode,
        },
        if (tags.isNotEmpty) 'tags': tags,
        if (tagsAddedAt.isNotEmpty) 'tagsAddedAt': tagsAddedAt,
        if (tagTombstones.isNotEmpty) 'tagTombstones': tagTombstones,
        if (collection != null) 'collection': collection!.toJson(),
      };

  RemoteVideoInfo copyWith({
    bool? hasCover,
    String? coverUrl,
    String? coverPath,
    String? subtitleFileName,
    List<RemoteVideoEmbeddedSubtitleTrack>? embeddedSubtitleTracks,
    int? positionMs,
    int? positionUpdatedAtMs,
    int? delayMs,
    int? delayUpdatedAtMs,
    String? audioTrackId,
    int? completedAt,
    RemoteCollectionMembership? collection,
  }) =>
      RemoteVideoInfo(
        id: id,
        title: title,
        sizeBytes: sizeBytes,
        hasSubtitle: hasSubtitle,
        subtitleFileName: subtitleFileName ?? this.subtitleFileName,
        embeddedSubtitleTracks:
            embeddedSubtitleTracks ?? this.embeddedSubtitleTracks,
        durationMs: durationMs,
        hasCover: hasCover ?? this.hasCover,
        coverUrl: coverUrl ?? this.coverUrl,
        coverPath: coverPath ?? this.coverPath,
        positionMs: positionMs ?? this.positionMs,
        positionUpdatedAtMs: positionUpdatedAtMs ?? this.positionUpdatedAtMs,
        delayMs: delayMs ?? this.delayMs,
        delayUpdatedAtMs: delayUpdatedAtMs ?? this.delayUpdatedAtMs,
        audioTrackId: audioTrackId ?? this.audioTrackId,
        completedAt: completedAt ?? this.completedAt,
        episodes: episodes,
        currentEpisode: currentEpisode,
        tags: tags,
        tagsAddedAt: tagsAddedAt,
        tagTombstones: tagTombstones,
        collection: collection ?? this.collection,
      );

  static RemoteVideoInfo fromJson(Map<String, Object?> json) {
    final String? coverUrl = _jsonString(json['coverUrl']);
    final String? coverPath = _jsonString(json['coverPath']);
    final String? subtitleFileName = _jsonString(json['subtitleFileName']);
    final List<RemoteVideoEmbeddedSubtitleTrack> embeddedSubtitleTracks =
        _jsonEmbeddedSubtitleTracks(json['embeddedSubtitleTracks']);
    return RemoteVideoInfo(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
      hasSubtitle: json['hasSubtitle'] == true,
      subtitleFileName: subtitleFileName,
      embeddedSubtitleTracks: embeddedSubtitleTracks,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      hasCover: json['hasCover'] == true ||
          _isNonEmpty(coverUrl) ||
          _isNonEmpty(coverPath),
      coverUrl: coverUrl,
      coverPath: coverPath,
      positionMs: _jsonInt(json['positionMs']) ?? 0,
      positionUpdatedAtMs: _jsonInt(json['positionUpdatedAtMs']) ?? 0,
      delayMs: _jsonInt(json['delayMs']) ?? 0,
      delayUpdatedAtMs: _jsonInt(json['delayUpdatedAtMs']) ?? 0,
      audioTrackId: _jsonString(json['audioTrackId']),
      completedAt: _jsonInt(json['completedAt']),
      episodes: _jsonVideoEpisodes(json['episodes']),
      currentEpisode: _jsonInt(json['currentEpisode']) ?? 0,
      tags: _jsonStringList(json['tags']),
      tagsAddedAt: _jsonNameIntMap(json['tagsAddedAt']),
      tagTombstones: _jsonNameIntMap(json['tagTombstones']),
      // BUG：toJson 写了 'collection'（合集归属）但 fromJson 从不解析 → LAN 远端视频
      // video.collection 恒 null → 首页收不到合集分组（全成散卡）、播放器也无从重建合集连播。
      // 对齐 RemoteBookInfo.fromJson。旧 host 无该字段 → fromJson 返 null（向后兼容）。
      collection: RemoteCollectionMembership.fromJson(json['collection']),
    );
  }
}

/// 解析 `{name: ms}` 映射（值容忍 int/num/数字串；空名/非数值跳过）。非 Map → 空。
Map<String, int> _jsonNameIntMap(Object? raw) {
  if (raw is! Map) return const <String, int>{};
  final Map<String, int> out = <String, int>{};
  raw.forEach((Object? k, Object? v) {
    final String name = k?.toString() ?? '';
    if (name.isEmpty) return;
    final int? ms = v is int
        ? v
        : (v is num ? v.toInt() : int.tryParse(v?.toString() ?? ''));
    if (ms != null) out[name] = ms;
  });
  return out;
}

List<RemoteVideoEpisode> _jsonVideoEpisodes(Object? value) {
  if (value is! List) return const <RemoteVideoEpisode>[];
  return <RemoteVideoEpisode>[
    for (final Object? item in value)
      if (item is Map)
        RemoteVideoEpisode.fromJson(item.cast<String, Object?>()),
  ];
}

/// 解析 JSON 数组为非空字符串列表（标签名）。非 List / 缺字段返回空列表
/// （向后兼容：旧 host 不带 tags 字段时按空标签处理）。
List<String> _jsonStringList(Object? value) {
  if (value is! List) return const <String>[];
  return <String>[
    for (final Object? item in value)
      if (item != null && item.toString().isNotEmpty) item.toString(),
  ];
}

String? _jsonString(Object? value) {
  if (value == null) return null;
  final String text = value.toString();
  return text.isEmpty ? null : text;
}

int? _jsonInt(Object? value) {
  if (value is num) return value.toInt();
  if (value == null) return null;
  return int.tryParse(value.toString());
}

List<RemoteVideoEmbeddedSubtitleTrack> _jsonEmbeddedSubtitleTracks(
  Object? value,
) {
  if (value is! List) return const <RemoteVideoEmbeddedSubtitleTrack>[];
  return <RemoteVideoEmbeddedSubtitleTrack>[
    for (final Object? item in value)
      if (item is Map)
        RemoteVideoEmbeddedSubtitleTrack.fromJson(
          item.cast<String, Object?>(),
        ),
  ];
}

bool _isNonEmpty(String? value) => value != null && value.isNotEmpty;

/// client 向 host 申请到的视频播放 URL。
///
/// [streamUrl] 是可直接交给播放器的短时 token URL；[subtitleUrl] 仅表示 host 有
/// 可下载外挂字幕，实际播放器应先通过 client 下载到本地再复用现有字幕路径。
/// [subtitleFileName] 与 [subtitleUrl] 配套，保留 host sidecar 的真实文件名/扩展名。
class RemoteVideoStreamUrls {
  const RemoteVideoStreamUrls({
    required this.streamUrl,
    this.subtitleUrl,
    this.subtitleFileName,
    this.audioStreamUrl,
    this.miningVideoUrl,
    this.miningVideoHasAudio = false,
    this.embeddedSubtitleTracks = const <RemoteVideoEmbeddedSubtitleTrack>[],
  });

  final String streamUrl;
  final String? subtitleUrl;
  final String? subtitleFileName;

  /// TODO-1000：分离音视频流（YouTube video-only）时的 audio-only 流 URL；播放页经
  /// `AudioTrack.uri` 外挂、制卡音频从它裁。同轨/muxed 时为 null。
  final String? audioStreamUrl;

  /// TODO-1000（BUG-528）：制卡 GIF/帧专用的低分辨率视频流 URL（muxed 360p 等）。播放
  /// 用的 [streamUrl] 可达 4K，从它抽 GIF 会网络超时；制卡封面只需小图，故另取小流。
  /// null=从 [streamUrl] 抽（本地文件 / 已是低分辨率流）。
  final String? miningVideoUrl;

  /// TODO-1301（BUG-600）：[miningVideoUrl] 是否自带音轨（muxed）。true 时制卡音频从
  /// [miningVideoUrl] 抽，播放页把制卡音频源置 null 回落 miningSource；false 时用
  /// [audioStreamUrl]（分离 audio-only 流）。见 [UrlStreamVideoClient.miningVideoHasAudio]。
  final bool miningVideoHasAudio;
  final List<RemoteVideoEmbeddedSubtitleTrack> embeddedSubtitleTracks;

  static RemoteVideoStreamUrls fromJson(Map<String, Object?> json) {
    final String streamUrl = json['url']?.toString() ?? '';
    final String? subtitleUrl = json['subtitleUrl']?.toString();
    final String? subtitleFileName = _jsonString(json['subtitleFileName']);
    final String? audioStreamUrl = _jsonString(json['audioStreamUrl']);
    final String? miningVideoUrl = _jsonString(json['miningVideoUrl']);
    final bool miningVideoHasAudio = json['miningVideoHasAudio'] == true;
    final List<RemoteVideoEmbeddedSubtitleTrack> embeddedSubtitleTracks =
        _jsonEmbeddedSubtitleTracks(json['embeddedSubtitleTracks']);
    return RemoteVideoStreamUrls(
      streamUrl: streamUrl,
      subtitleUrl: subtitleUrl,
      subtitleFileName: subtitleFileName,
      audioStreamUrl: audioStreamUrl,
      miningVideoUrl: miningVideoUrl,
      miningVideoHasAudio: miningVideoHasAudio,
      embeddedSubtitleTracks: embeddedSubtitleTracks,
    );
  }
}

/// 从远端视频清单 [remote] 里剔除本端已存在的视频（按 [localBookUids] 去重）。
///
/// 纯函数。视频的跨设备身份就是 [RemoteVideoInfo.id]（= `VideoBooks.bookUid`，
/// 从文件名经 [sanitizeTtuFilename] 派生，host 与本端同源），故直接按 id 精确去重，
/// 不必再走标题再派生（标题可能两端不同，bookUid 才是规范同步键）。本端已有同 id 的
/// 视频就不在「配对设备」区重复展示（TODO-033 #6：远端与本地重复同一视频）。
List<RemoteVideoInfo> dedupeRemoteVideos({
  required List<RemoteVideoInfo> remote,
  required Set<String> localBookUids,
}) {
  return <RemoteVideoInfo>[
    for (final RemoteVideoInfo video in remote)
      if (!localBookUids.contains(video.id)) video,
  ];
}

// ── Abstract service ───────────────────────────────────────────────────────

/// host 侧「库感知」服务：把 host 的实时库即时 export/import/delete/list。
/// 抽象不依赖 AppModel，便于测试用 fake 注入。所有实现里的库变动必须串行
/// （经 runExclusiveWithSync）——见 AppModelLibraryHostService（后续任务实现）。
abstract class FushiLibraryHostService {
  /// host 当前实时词典清单（从 DictionaryMeta 表读，不是从任何暂存目录）。
  Future<List<RemoteDictionaryInfo>> listDictionaries();

  /// 即时把名为 [name] 的实时词典打包成 .fushidict 临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。词典不存在抛 [StateError]。
  Future<File> exportDictionary(String name);

  /// 把 [packageFile]（.fushidict）导入 host 实时库（幂等：同名覆盖资源 + upsert 元数据）。
  Future<void> importDictionary(File packageFile);

  /// 从 host 实时库删除名为 [name] 的词典（DB 元数据 + 资源目录）。
  Future<void> deleteDictionary(String name);

  // ── 书籍 ─────────────────────────────────────────────────────────────────

  /// host 当前书库清单（从 EpubBooks 表读）。
  Future<List<RemoteBookInfo>> listBooks();

  /// 即时把书名为 [title] 的书 extractDir 重打包成 .epub 临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。
  /// [title] 含路径穿越字符时抛 [ArgumentError]；
  /// 书不存在或 extractDir 为空/不存在时抛 [StateError]。
  Future<File> exportBook(String title);

  /// 把 [epubFile] 导入 host 书库（复用 EpubImporter）。
  ///
  /// [displayTitle] / [displayTitleAt]（BUG-1503）是**推送方用户给这本书改的名字**
  /// 及其 LWW 毫秒戳，经 [kBookDisplayTitleHeader] / [kBookDisplayTitleAtHeader]
  /// 随行。落地后按 last-write-wins 写成 host 本机的 `override_title://` 覆盖行。
  ///
  /// ⚠️ 身份红线（BUG-1488 定的原则）：只搬显示名，**绝不搬身份**。host 端这本书
  /// 的 bookKey / uid 仍完全由 [epubFile] 的内容 + 文件名经 `EpubImporter` 派生
  /// （含重名 `(2)` 后缀），[displayTitle] 永不参与任何键派生。
  ///
  /// 旧 client 不发这两个 header → 两参为 null/0 → 与本轮之前逐字同行为。
  Future<void> importBook(
    File epubFile, {
    String? displayTitle,
    int displayTitleAt = 0,
  });

  /// 从 host 书库删除书名为 [title] 的书（DB 行 + 磁盘目录）。
  /// [title] 含路径穿越字符时抛 [ArgumentError]。
  Future<void> deleteBook(String title);

  /// 读 host 端记录的书 [bookKey] 阅读进度（TODO-767）。返回 host 自己
  /// `reader_positions` 行；无记录时返回 [RemoteBookProgress.empty]。
  Future<RemoteBookProgress> getBookProgress(String bookKey);

  /// 把 client 上报的书 [bookKey] 阅读进度写入 host 自己的 `reader_positions`
  /// （TODO-767）。冲突解决「取较新时间戳」（见 [resolveBookProgressSync]）：仅当
  /// [progress] 严格新于 host 已存时间戳才覆盖，避免旧设备滞后上报回退新进度。
  Future<void> putBookProgress(String bookKey, RemoteBookProgress progress);

  // ── 本地音频 ───────────────────────────────────────────────────────────────

  /// host 当前本地音频来源清单（从已注入的 localAudioEntries 取 displayName）。
  Future<List<RemoteLocalAudioInfo>> listLocalAudio();

  /// 即时把 displayName 为 [displayName] 的本地音频库打包成临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。
  /// [displayName] 含路径穿越字符时抛 [ArgumentError]；
  /// 找不到该来源或其 DB 文件不存在时抛 [StateError]。
  Future<File> exportLocalAudio(String displayName);

  /// 把本地音频包文件导入 host（解包 + 注册回调）。
  /// 实现应调用 [onLocalAudioImported] 回调完成 native 注册；
  /// 回调为 null 时抛 [UnsupportedError]。
  Future<void> importLocalAudio(File packageFile);

  /// 从 host 删除 displayName 为 [displayName] 的本地音频来源。
  /// [displayName] 含路径穿越字符时抛 [ArgumentError]。
  Future<void> deleteLocalAudio(String displayName);

  // ── 有声书包 ──────────────────────────────────────────────────────────────

  /// host 当前可导出的有声书清单。
  Future<List<RemoteAudiobookInfo>> listAudiobooks();

  /// 即时把 bookKey 为 [bookKey] 的有声书打包成临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。
  /// [bookKey] 含路径穿越字符时抛 [ArgumentError]；
  /// 找不到该有声书时抛 [StateError]。
  Future<File> exportAudiobook(String bookKey);

  /// 廉价判断 host 库是否存在 bookKey 为 [bookKey] 的有声书（仅一次 DB 查询，
  /// 不打包导出）。position 路由的存在性闸门用它替代重量级 [exportAudiobook]
  /// （BUG-471a：旧实现每次 GET/PUT position 都把整本有声书打包成 .fushiaudio
  /// 临时文件再删，对每本共享有声书的 live sweep 造成大量无谓 zip I/O）。与视频
  /// position 路由用 [resolveVideoFile] 廉价等价。
  /// [bookKey] 含路径穿越字符时抛 [ArgumentError]。
  Future<bool> audiobookExists(String bookKey);

  /// 把有声书包文件导入 host（解包写 DB + 音频文件）。
  /// 实现需要 [audioDatabaseRoot] 来确定音频文件落盘目录。
  Future<void> importAudiobook(File packageFile, {String? bookKeyOverride});

  /// 从 host 删除 bookKey 为 [bookKey] 的有声书（Audiobooks/SrtBooks/AudioCues 行
  /// + 磁盘音频目录）。[bookKey] 含路径穿越字符时抛 [ArgumentError]。
  Future<void> deleteAudiobook(String bookKey);

  /// 读 host 端记录的有声书 [bookKey] 播放断点（BUG-471）。返回 (位置毫秒, 更新时间毫秒)；
  /// 无记录时返回 (0, 0)。
  Future<({int positionMs, int updatedAtMs})> getAudiobookPosition(
    String bookKey,
  );

  /// 把 client 上报的有声书 [bookKey] 播放断点写入 host（BUG-471）。
  ///
  /// 冲突解决「取较新时间戳」（见 [resolvePositionLww]）：仅当 [updatedAtMs]
  /// 严格新于 host 已存时间戳才覆盖，避免旧设备的滞后上报回退新进度。
  Future<void> putAudiobookPosition(
    String bookKey,
    int positionMs,
    int updatedAtMs,
  );

  // ── 视频 ──────────────────────────────────────────────────────────────────────

  /// host 当前视频清单（从 VideoBooks 表读，按 importedAt DESC 排序）。
  ///
  /// 流式播放：视频文件通常数 GB，host→client 只按需流式传输（不走同步管道下发整
  /// 文件）；client→host 方向由 [importVideo] 接收上传（syncVideoFiles 开关驱动，
  /// 见 [SyncOrchestrator]._syncVideosLive）。
  Future<List<RemoteVideoInfo>> listVideos();

  /// 廉价判断 host 库是否已存在 bookUid 为 [id] 的视频（仅一次 DB 查询）。
  /// 供 client 侧 push 幂等判据（远端已有同 uid+同尺寸则跳过重传）与上传端点用。
  /// [id] 含路径穿越字符（`..` / `\`）时抛 [ArgumentError]。
  Future<bool> videoExists(String id);

  /// 接收 client 上传的单文件视频并注册进 host 视频库（client→host，
  /// syncVideoFiles 开关驱动的 live push）。
  ///
  /// [videoFile] 是已落到临时位置的上传字节；实现把它搬进 host 拥有的视频目录，按
  /// [id]（= client 端 `VideoBooks.bookUid`，跨设备稳定同步键）+ [title] upsert 一行
  /// `VideoBooks`（`videoPath` = 目录内绝对路径），使上传的视频出现在 host 视频列表、
  /// 可被其它 client 流式播放。bookUid 稳定 ⇒ upsert，重复上传同一视频只覆盖同一行。
  /// [originalFileName] 用于保留扩展名（media_kit 依赖），实现须做路径穿越校验。
  /// 封面为可选增强，best-effort 抽取，绝不挡建行落库。
  Future<void> importVideo(
    File videoFile, {
    required String id,
    required String title,
    String? originalFileName,
  });

  /// 接收 client 上传的视频外挂字幕（sidecar，BUG-964）。
  ///
  /// [subtitleFile] 是已落到临时位置的上传字节；实现把它搬到 [id] 视频文件的
  /// **同目录**，命名为 `<视频文件 stem><suffix>`（[suffix] 形如 `.srt` / `.ja.srt`，
  /// 由 client 从其本地 sidecar 名裁出、实现须用 [isSidecarSubtitleSuffix] 白名单
  /// 校验），使 [resolveVideoSubtitle] 的同 stem 匹配天然可见。落盘后按 host 学习
  /// 语言重解析首选 sidecar，镜像 client 下载路径的行语义（`subtitleSource` /
  /// `subtitleFormat`、`embeddedSubtitleTrack=null`、解析 cue 落库）。
  /// [id] 未知视频抛 [StateError]（端点映射 404）；非法 [suffix] 抛 [ArgumentError]
  /// （端点映射 400）。
  Future<void> importVideoSubtitle(
    File subtitleFile, {
    required String id,
    required String suffix,
  });

  /// 按 [id]（即 `VideoBooks.bookUid`）反查真实视频文件。
  ///
  /// 实现**只查 DB** 得到 videoPath，然后验证文件存在后返回；文件不存在或 id 未知
  /// 时返回 null。绝不接受外部任意路径——[id] 只能来自 [listVideos] 返回的条目，
  /// 防止路径穿越。
  ///
  /// [episodeIndex]>0（远端播放列表，TODO-885）时反查 `playlistJson[episodeIndex].path`
  /// 那一集的文件（仍 DB-only，不接受外部 path）；0 = 当前选中集（`videoPath`）。
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0});

  /// host 最近 [limit] 条活动事件（`activity_events` 表，按精确时刻倒序），供
  /// client 新首页 Activity 面板与本地事件混排展示（display-only，不落库）。
  Future<List<RemoteActivityEvent>> listActivityEvents({int limit = 100});

  /// 按 [id]（即 `VideoBooks.bookUid`）单查该视频封面的磁盘绝对路径；无封面 /
  /// 文件不存在 / id 未知时返回 null。
  ///
  /// 封面端点的廉价存在判据：**只做一次 DB 单行查询 + 文件 stat**，绝不 materialize
  /// 整份 [listVideos] 清单（旧实现每张封面请求重跑全量清单——每行一次目录扫描 +
  /// 多次 DB 查询，N 张封面就是 O(N²)，大库浏览一次封面墙拖成分钟级）。
  Future<String?> videoCoverPath(String id);

  /// 按 [id]（downloadId：bookKey 或 title）单查该书封面的磁盘绝对路径；无封面 /
  /// 文件不存在 / id 未知时返回 null。与 [videoCoverPath] 同理——封面端点专用的
  /// 单行查询，不 materialize 整份 [listBooks]。
  Future<String?> bookCoverPath(String id);

  /// 按 [id] 查找对应视频的外挂字幕文件（sidecar）。
  ///
  /// 用 [langCode] 优先匹配带语言标记的字幕（如 `.ja.srt`）；内封字幕不在此列。
  /// 找不到外挂字幕或视频未知时返回 null。[episodeIndex]>0（TODO-885）时按
  /// `playlistJson[episodeIndex]` 那一集的视频路径找 sidecar。
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = '',
    int episodeIndex = 0,
  });

  /// BUG-1004：在 host **本地**对视频 [id] 的 `[startMs,endMs)` 段裁出 mining 句子音频，
  /// 返回临时 aac(adts) 文件（调用方读完负责删其所在临时目录）；无该视频 / 区间非法 /
  /// ffmpeg 失败时返回 null。host 用本地文件裁、不经网络/TLS，是「client ffmpeg 打不开 host
  /// 自签 https / token 流」（BUG-891 残余缺口）的根治路径——client 全程不用 ffmpeg 抓远端流。
  /// [audioStreamIndex]/[audioStreamCount] 选多音轨视频里用户当前听的轨（越界回退默认轨）；
  /// [audioChannels]/[audioBitrate] 对齐制卡压缩档，使 host 裁出的片段与本地路径同规格。
  Future<File?> clipVideoAudio(
    String id, {
    required int startMs,
    required int endMs,
    int episodeIndex = 0,
    int? audioStreamIndex,
    int? audioStreamCount,
    int audioChannels = 1,
    String audioBitrate = '64k',
  });

  /// 读 host 端记录的视频 [id] 播放断点（TODO-653）。返回 (位置毫秒, 更新时间毫秒)；
  /// 无记录时返回 (0, 0)。[episodeIndex]>0（TODO-885）按集隔离读断点。
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id, {
    int episodeIndex = 0,
  });

  /// 把 client 上报的视频 [id] 播放断点写入 host（TODO-653）。
  ///
  /// 冲突解决「取较新时间戳」（见 [resolvePositionLww]）：仅当 [updatedAtMs]
  /// 严格新于 host 已存时间戳才覆盖，避免旧设备的滞后上报回退新进度。
  /// [episodeIndex]>0（TODO-885）按集隔离写断点。
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  });

  // ── 聚合（统计 + 收藏，TODO-1056 phase C）────────────────────────────────────

  /// 读 host 端当前聚合快照（四张统计表 + 挖掘计数 + 收藏词 + 收藏句），供 client
  /// 拉取 host 真相源做并集合并（TODO-1056 phase C 互联 live 通道）。纯读，无副作用。
  ///
  /// 与云后端 phase B 用同一 [AggregateSnapshot] 形状（materialize 自 host DB），
  /// 但通道是互联 live 端点而非云上 per-device 快照文件。
  Future<AggregateSnapshot> getAggregateSnapshot();

  /// 把 client 上报的（已在 client 端与 host 并集合并的）聚合快照折叠进 host 自己的
  /// DB（TODO-1056 phase C）。写入语义只用 MAX / 并集 upsert（统计逐桶取大、挖掘计数
  /// MAX 非 SUM、收藏词/句并集去重），故重复 apply 同一快照是幂等 no-op，删除绝不跨端
  /// 传播——与云后端 phase B 的 applySnapshotToLocal 完全同语义（复用同一实现）。
  Future<void> applyAggregateSnapshot(AggregateSnapshot snapshot);

  // ── 合集清单（多端库联合视图 §2.3 任务5.2）──────────────────────────────────

  /// 读 host 当前合集全量快照清单（`loadLocalCollectionManifest` 结果）。GET
  /// `/api/library/collections` 返回其 canonicalJson，供 client 拉取 host 合集真相源
  /// 做读-合并-写。纯读，无副作用。
  Future<CollectionManifest> getCollectionManifest();

  /// 把 client 上报的合集清单 [incoming] 并入 host 自己的合集库并返回合并后清单
  /// （POST `/api/library/collections`）。语义：`CollectionSyncEngine.merge`（host 自身
  /// 因果基线 `sync_collections_baseline_ms`）→ `applyCollectionLocalChanges` 把变更
  /// 落 host DB → 推进 host 基线 → 返回合并后清单。与云后端 `__collections__` 通道
  /// 同一引擎、同一墓碑/LWW 语义，仅通道不同；成员并集 + 移出/删除墓碑防复活 +
  /// 手动序整合集 LWW。重放同一清单幂等（应用端按目标态调和）。
  Future<CollectionManifest> mergeCollectionManifest(
      CollectionManifest incoming);
}

/// host 端「列删除墓碑」的**可选**能力（显式确认式删除传播，host→client 消费方向）。
/// 与 [FushiLibraryHostService] 分开：不是每个 host 实现（尤其测试 fake）都需要它，
/// 塞进主接口会强制全部实现者补方法（Never break userspace）。真实 host
/// （[AppModelLibraryHostService]）额外 implements 本接口；server 用 `is` 探测——不实现
/// 就 GET `/api/tombstones` → 404，client 侧 [getRemoteDeletionTombstones] 已优雅降级。
abstract interface class DeletionTombstoneHost {
  /// 列出 host 当前全部删除墓碑（`sync_deletion_tombstones`）为 JSON 数组，供 client
  /// 拉取后与本地在库键求交、弹逐条确认删本地。纯读，无副作用。
  Future<List<({String mediaType, String itemKey, int deletedAt})>>
      listDeletionTombstones();
}

/// host 端「删除视频」的**可选**能力（client→host 删除方向）。
///
/// 与 [FushiLibraryHostService] 分开的理由同 [DeletionTombstoneHost]：主接口有十余个
/// 测试 fake 用 `implements` 全量实现，往主接口加方法会强制它们全部补桩（Never break
/// userspace）。书 / 有声书 / 本地音频 / 词典的 delete 是主接口的历史既成事实，新增的
/// 视频删除不再扩大那个面。
///
/// server 用 `is` 探测——host 不实现就让 `DELETE /api/library/videos/<id>` 落 404，
/// client 侧 [RemoteVideoDeletionClient.deleteRemoteVideo] 已按 404/405 优雅降级
/// （旧版本 host 天然如此）。
abstract interface class VideoDeletionHost {
  /// 从 host 视频库删除 bookUid 为 [id] 的视频。
  ///
  /// 语义与 host 用户在自己视频库里长按删除**完全一致**：删 `VideoBooks` 行 + 其字幕
  /// cue、清合集引用、记删除墓碑（供 host 的其它已配对设备继续传播），磁盘侧**只回收
  /// app 自己拥有的文件**——client 上传副本目录、封面 / 字幕缓存。
  /// **用户自己导入的原始视频文件绝不删除**（本地删除路径同此约束，见
  /// `VideoBookRepository.reclaimDeletedVideoBookAssets`）。
  ///
  /// 幂等：[id] 不存在时静默返回。[id] 含路径穿越字符时抛 [ArgumentError]。
  Future<void> deleteVideo(String id);
}

/// host 端「视频字幕调轴跨设备同步」的**可选**能力（互联远端调轴不持久化 bug）。
///
/// 与 [FushiLibraryHostService] 分开的理由同 [VideoDeletionHost]：主接口有十余个
/// 测试 fake 用 `implements` 全量实现，往主接口加方法会强制它们全部补桩。
///
/// server 用 `is` 探测——host 不实现就让 `GET/PUT /api/library/videos/<id>/delay`
/// 落 404；client 上报是 best-effort（失败只记日志），本地 prefs 已持久化，对旧
/// host 优雅降级（Never break userspace）。
abstract interface class VideoDelayHost {
  /// 读 host 端视频 [id] 的字幕调轴。返回 (调轴毫秒（可负）, 更新时间毫秒)；
  /// 无带戳记录时回退旧 `VideoBooks.delayMs`（时间戳 0），id 未知返回 (0, 0)。
  Future<({int delayMs, int updatedAtMs})> getVideoDelay(String id);

  /// 把 client 上报的视频 [id] 字幕调轴写入 host。冲突解决「严格较新时间戳者胜」
  /// （[resolveDelayLww]）；[delayMs] 越界 clamp 到 ±[kVideoSubtitleDelayLimitMs]；
  /// host 库不存在该视频时 no-op（防任意 id 写脏 prefs，与断点同语义）。
  Future<void> putVideoDelay(String id, int delayMs, int updatedAtMs);
}
