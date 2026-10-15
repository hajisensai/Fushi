import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_collection_order_assistant.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/collections/collection_one_key_sort.dart'
    show
        collectionDetailSortPrefKey,
        kCollectionDetailManualSortValue,
        loadCollectionMemberMeta;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 合集「AI 排序」的 app 侧装配：从库里取成员事实 → 规则序 → 判歧义 → 问 AI
/// （`ai_collection_order_assistant.dart`）→ 按调用方意图落盘。
///
/// 三个入口共用 [runCollectionAiOrder]：
/// - 自动路径（导入 / 归组后，[scheduleAutomaticCollectionAiOrder]）：只在合集
///   `orderUpdatedAt == 0`（用户没手动排过）时动，落盘走
///   `reorderCollectionItemsAutomatically`（不把机器整理伪装成用户意图）；
/// - 合集详情页「AI 排序」菜单项与 CLI `collection sort --by ai`：用户意图，落盘走
///   `reorderCollectionItems` 并把详情页排序偏好切成 manual。
///
/// 规则已能完整定序（没有 SP / OVA / 汉字卷号这类判不出的成员）时不发请求：自动
/// 路径什么都不做（归组器已按规则排过），用户意图路径按规则序落盘。

/// 一次 AI 排序的结论。
enum CollectionAiOrderStatus {
  /// 合集不存在。
  notFound,

  /// 成员不足两个，无序可排。
  tooFew,

  /// 自动路径：用户手动排过（`orderUpdatedAt > 0`），不动。
  skippedManual,

  /// 自动路径：规则已能完整定序，不发请求、不动。
  noAmbiguity,

  /// 未指派提供商（或 AI 模块关闭）：不发请求、不动。
  noProvider,

  /// 合集过大，不发请求、不动。
  tooLarge,

  /// AI 请求失败（[CollectionAiOrderOutcome.failure] 是脱敏错误码），不动。
  failed,

  /// AI 回复没通过本地校验，不动。
  invalidReply,

  /// AI 不认识这部作品 / 对判不出的成员都拿不准（联网资料也没帮上），不动。
  unknown,

  /// 用户意图路径：规则已能定序，按规则序排（没问 AI）。
  ruleOrdered,

  /// 采用了 AI 给的顺序。
  aiOrdered,
}

/// 结论里的一个成员（排序单元里的每个成员行各一条）。
class CollectionAiOrderEntry {
  const CollectionAiOrderEntry({
    required this.mediaType,
    required this.entryKey,
    required this.title,
    required this.ambiguous,
  });

  final String mediaType;
  final String entryKey;
  final String title;

  /// 规则判不出位置、交给 AI 定位的成员。
  final bool ambiguous;

  String get key => '$mediaType|$entryKey';

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'mediaType': mediaType,
    'entryKey': entryKey,
    'title': title,
    'ambiguous': ambiguous,
  };
}

class CollectionAiOrderOutcome {
  const CollectionAiOrderOutcome(
    this.status, {
    this.order = const <CollectionAiOrderEntry>[],
    this.changed = false,
    this.persisted = false,
    this.failure,
  });

  final CollectionAiOrderStatus status;

  /// [CollectionAiOrderStatus.ruleOrdered] / [CollectionAiOrderStatus.aiOrdered]
  /// 时是建议的完整顺序；其余为空。
  final List<CollectionAiOrderEntry> order;

  /// 建议序与当前序不同。
  final bool changed;

  /// 已经落盘（dry-run 恒 false）。
  final bool persisted;

  /// [CollectionAiOrderStatus.failed] 时的脱敏错误码（`AiChatFailure.message`）。
  final String? failure;
}

/// 造 AI 客户端：测试注入假 `http.Client` 走这条缝；生产恒是默认构造。
typedef CollectionAiClientFactory = AiChatClient Function();

/// 造联网资料客户端（模型不认识作品时查资料用）：测试注入假站点；生产按用户在
/// 「设置 › 模型 › LLM」启用的资料站构造。
typedef CollectionWebKnowledgeFactory = WebKnowledgeClient Function();

/// 一个排序单元：视频一个文件；书一卷（EPUB 与它配对的 SRT 合成一个单元）。
class _Unit {
  _Unit(this.member, this.rows);

  final AiCollectionOrderMember member;
  final List<MediaCollectionItemRow> rows;
}

/// 对合集 [collectionId] 跑一次 AI 排序。
///
/// [userIntent] = 用户点的（详情页菜单 / CLI）：不看 `orderUpdatedAt`，落盘走
/// `reorderCollectionItems` 并写 manual 排序偏好；否则是自动路径（见文件头）。
/// [dryRun] 只算建议序、不落盘（CLI `--dry-run`）。
///
/// AI 失败一律返回 [CollectionAiOrderStatus.failed]，不抛；数据库异常照常抛。
Future<CollectionAiOrderOutcome> runCollectionAiOrder({
  required FushiDatabase db,
  required int collectionId,
  required AiSettingsSource settings,
  required bool userIntent,
  bool dryRun = false,
  CollectionAiClientFactory? clientFactory,
  AiChatClient? client,
  CollectionWebKnowledgeFactory? webFactory,
}) async {
  final MediaCollectionRow? collection = await db.getMediaCollectionById(
    collectionId,
  );
  if (collection == null) {
    return const CollectionAiOrderOutcome(CollectionAiOrderStatus.notFound);
  }
  if (!userIntent && collection.orderUpdatedAt != 0) {
    return const CollectionAiOrderOutcome(
      CollectionAiOrderStatus.skippedManual,
    );
  }
  final List<MediaCollectionItemRow> rows = await db.getCollectionItems(
    collectionId,
  );
  final AiCollectionOrderKind kind = collectionAiOrderKindOf(rows);
  final List<_Unit> units = await _loadUnits(db, rows, kind);
  if (units.length < 2) {
    return const CollectionAiOrderOutcome(CollectionAiOrderStatus.tooFew);
  }
  final List<int> ruleIndex = ruleOrderCollectionMembers(
    <AiCollectionOrderMember>[for (final _Unit u in units) u.member],
    kind,
  );
  final List<_Unit> ruled = <_Unit>[for (final int i in ruleIndex) units[i]];
  final List<AiCollectionOrderMember> ruledMembers = <AiCollectionOrderMember>[
    for (final _Unit u in ruled) u.member,
  ];
  final Set<int> ambiguous = collectionOrderAmbiguousIndices(
    ruledMembers,
    kind,
  );

  if (ambiguous.isEmpty) {
    if (!userIntent) {
      return const CollectionAiOrderOutcome(
        CollectionAiOrderStatus.noAmbiguity,
      );
    }
    return _finish(
      db: db,
      collectionId: collectionId,
      status: CollectionAiOrderStatus.ruleOrdered,
      current: rows,
      ordered: ruled,
      ambiguous: const <int>{},
      userIntent: true,
      dryRun: dryRun,
    );
  }

  final AiProviderConfig? provider = resolveCollectionOrderAiProvider(settings);
  if (provider == null) {
    return const CollectionAiOrderOutcome(CollectionAiOrderStatus.noProvider);
  }
  final AiChatClient useClient =
      client ?? clientFactory?.call() ?? AiChatClient();
  final WebKnowledgeClient web =
      webFactory?.call() ??
      WebKnowledgeClient(sites: settings.aiWebKnowledgeSites);
  final AiCollectionOrderProposal proposal;
  try {
    proposal = await requestAiCollectionOrder(
      client: useClient,
      provider: provider,
      kind: kind,
      collectionName: collection.name,
      members: ruledMembers,
      web: web,
    );
  } on AiChatFailure catch (failure) {
    debugPrint(
      '[collection-ai-order] collection $collectionId: AI request failed '
      '(${failure.message}); keeping rule order',
    );
    return CollectionAiOrderOutcome(
      CollectionAiOrderStatus.failed,
      failure: failure.message,
    );
  } finally {
    // 调用方传进来的共享客户端由调用方关。
    if (client == null) useClient.close();
    web.close();
  }
  switch (proposal.status) {
    case AiCollectionOrderStatus.tooLarge:
      return const CollectionAiOrderOutcome(CollectionAiOrderStatus.tooLarge);
    case AiCollectionOrderStatus.invalidReply:
      debugPrint(
        '[collection-ai-order] collection $collectionId: AI reply failed '
        'validation; keeping rule order',
      );
      return const CollectionAiOrderOutcome(
        CollectionAiOrderStatus.invalidReply,
      );
    case AiCollectionOrderStatus.unknown:
      debugPrint(
        '[collection-ai-order] collection $collectionId: AI does not know '
        'this work (web references did not help); keeping rule order',
      );
      return const CollectionAiOrderOutcome(CollectionAiOrderStatus.unknown);
    case AiCollectionOrderStatus.noAmbiguity:
    case AiCollectionOrderStatus.proposed:
      break;
  }
  final List<int> order = proposal.order;
  return _finish(
    db: db,
    collectionId: collectionId,
    status: CollectionAiOrderStatus.aiOrdered,
    current: rows,
    ordered: <_Unit>[for (final int i in order) ruled[i]],
    ambiguous: <int>{
      for (int pos = 0; pos < order.length; pos++)
        if (ambiguous.contains(order[pos])) pos,
    },
    userIntent: userIntent,
    dryRun: dryRun,
  );
}

Future<CollectionAiOrderOutcome> _finish({
  required FushiDatabase db,
  required int collectionId,
  required CollectionAiOrderStatus status,
  required List<MediaCollectionItemRow> current,
  required List<_Unit> ordered,
  required Set<int> ambiguous,
  required bool userIntent,
  required bool dryRun,
}) async {
  final List<CollectionAiOrderEntry> entries = <CollectionAiOrderEntry>[
    for (int pos = 0; pos < ordered.length; pos++)
      for (final MediaCollectionItemRow r in ordered[pos].rows)
        CollectionAiOrderEntry(
          mediaType: r.mediaType,
          entryKey: r.entryKey,
          title: ordered[pos].member.title,
          ambiguous: ambiguous.contains(pos),
        ),
  ];
  final bool changed = !_sameOrder(current, entries);
  if (dryRun) {
    return CollectionAiOrderOutcome(status, order: entries, changed: changed);
  }
  final List<CollectionMemberKey> keys = <CollectionMemberKey>[
    for (final CollectionAiOrderEntry e in entries)
      (mediaType: e.mediaType, entryKey: e.entryKey),
  ];
  if (userIntent) {
    await db.reorderCollectionItems(collectionId, keys);
    // 用户点的排序就是用户要的手动序：详情页此后默认按手动序展示（同一键整理）。
    await db.setPref(
      collectionDetailSortPrefKey(collectionId),
      kCollectionDetailManualSortValue,
    );
    return CollectionAiOrderOutcome(
      status,
      order: entries,
      changed: changed,
      persisted: true,
    );
  }
  if (!changed) {
    return CollectionAiOrderOutcome(status, order: entries);
  }
  // AI 跑的几秒里用户可能已经手动拖过：落盘前再核一次，绝不覆盖手动序。
  final MediaCollectionRow? latest = await db.getMediaCollectionById(
    collectionId,
  );
  if (latest == null || latest.orderUpdatedAt != 0) {
    return const CollectionAiOrderOutcome(
      CollectionAiOrderStatus.skippedManual,
    );
  }
  await db.reorderCollectionItemsAutomatically(collectionId, keys);
  return CollectionAiOrderOutcome(
    status,
    order: entries,
    changed: true,
    persisted: true,
  );
}

bool _sameOrder(
  List<MediaCollectionItemRow> current,
  List<CollectionAiOrderEntry> next,
) {
  if (current.length != next.length) return false;
  for (int i = 0; i < current.length; i++) {
    if ('${current[i].mediaType}|${current[i].entryKey}' != next[i].key) {
      return false;
    }
  }
  return true;
}

/// 合集按视频还是书的规则看：视频成员占多数（含一半）按视频，否则按书。
AiCollectionOrderKind collectionAiOrderKindOf(
  List<MediaCollectionItemRow> rows,
) {
  final int videos = rows
      .where(
        (MediaCollectionItemRow r) => r.mediaType == MediaKind.video.dbValue,
      )
      .length;
  return rows.isNotEmpty && videos * 2 >= rows.length
      ? AiCollectionOrderKind.video
      : AiCollectionOrderKind.book;
}

/// 成员行 → 排序单元（保持当前 sortIndex 序）。
Future<List<_Unit>> _loadUnits(
  FushiDatabase db,
  List<MediaCollectionItemRow> rows,
  AiCollectionOrderKind kind,
) async {
  final Map<String, ({String title, int importedAt})> meta =
      await loadCollectionMemberMeta(db);
  String titleOf(MediaCollectionItemRow r) =>
      meta['${r.mediaType}|${r.entryKey}']?.title ?? r.entryKey;

  if (kind == AiCollectionOrderKind.video) {
    final Map<int, int> seasonNumberById = <int, int>{};
    bool seasonsLoaded = false;
    final List<_Unit> out = <_Unit>[];
    for (final MediaCollectionItemRow r in rows) {
      if (r.mediaType != MediaKind.video.dbValue) {
        out.add(
          _Unit(
            AiCollectionOrderMember(title: titleOf(r)),
            <MediaCollectionItemRow>[r],
          ),
        );
        continue;
      }
      final VideoBookRow? book = await db.getVideoBookByBookUid(r.entryKey);
      final List<VideoMetadataEpisodeRow> episodes = await db
          .getVideoMetadataEpisodesByBook(r.entryKey);
      if (episodes.isNotEmpty && !seasonsLoaded) {
        seasonsLoaded = true;
        for (final VideoMetadataSeasonRow s
            in await db.getAllVideoMetadataSeasons()) {
          seasonNumberById[s.id] = s.seasonNumber;
        }
      }
      out.add(
        _Unit(
          AiCollectionOrderMember.video(
            title: book?.title ?? titleOf(r),
            fileName: book == null ? titleOf(r) : p.basename(book.videoPath),
            metadata: collectionAiEpisodeMetadata(episodes, seasonNumberById),
          ),
          <MediaCollectionItemRow>[r],
        ),
      );
    }
    return out;
  }

  // 书：EPUB 配对的有声书 SRT（`srt.bookKey == epub.bookKey`）在书架上就是同一卷，
  // 与 `BookSeriesGrouper` 同口径合成一个单元，排序时相邻、不被当成卷号冲突。
  final Map<String, String> epubBookKeyByUid = <String, String>{
    for (final EpubBookMeta e in await db.getEpubBookMetas())
      if (e.uid.isNotEmpty) e.uid: e.bookKey,
  };
  final Map<String, String> srtBookKeyByUid = <String, String>{
    for (final SrtBookRow s in await db.getAllSrtBooks())
      if (s.bookKey.isNotEmpty) s.uid: s.bookKey,
  };
  final List<_Unit> out = <_Unit>[];
  final Map<String, _Unit> unitByBookKey = <String, _Unit>{};
  final List<MediaCollectionItemRow> pendingSrt = <MediaCollectionItemRow>[];
  for (final MediaCollectionItemRow r in rows) {
    if (r.mediaType == MediaKind.srt.dbValue &&
        srtBookKeyByUid[r.entryKey] != null) {
      pendingSrt.add(r);
      continue;
    }
    final _Unit unit = _Unit(
      AiCollectionOrderMember.book(title: titleOf(r)),
      <MediaCollectionItemRow>[r],
    );
    out.add(unit);
    if (r.mediaType == MediaKind.epub.dbValue) {
      final String? bookKey = epubBookKeyByUid[r.entryKey];
      if (bookKey != null) unitByBookKey.putIfAbsent(bookKey, () => unit);
    }
  }
  for (final MediaCollectionItemRow r in pendingSrt) {
    final _Unit? paired = unitByBookKey[srtBookKeyByUid[r.entryKey]];
    if (paired != null) {
      paired.rows.add(r);
    } else {
      out.add(
        _Unit(
          AiCollectionOrderMember.book(title: titleOf(r)),
          <MediaCollectionItemRow>[r],
        ),
      );
    }
  }
  return out;
}

/// 刮削分集事实 → 提示词里的 metadata（只放有值的字段）。一文件多集取第一集。
Map<String, Object?> collectionAiEpisodeMetadata(
  List<VideoMetadataEpisodeRow> episodes,
  Map<int, int> seasonNumberById,
) {
  if (episodes.isEmpty) return const <String, Object?>{};
  final VideoMetadataEpisodeRow e = episodes.first;
  return <String, Object?>{
    if (seasonNumberById[e.seasonId] != null)
      'scraped_season': seasonNumberById[e.seasonId],
    'scraped_episode': e.episodeNumber,
    if (e.absoluteNumber != null) 'absolute': e.absoluteNumber,
    if (e.anidbEpisodeNumber?.trim().isNotEmpty == true)
      'anidb_episode': e.anidbEpisodeNumber!.trim(),
    if (e.airDate?.trim().isNotEmpty == true) 'air_date': e.airDate!.trim(),
    if (e.title?.trim().isNotEmpty == true) 'episode_title': e.title!.trim(),
  };
}

// ---------------------------------------------------------------------------
// 自动路径
// ---------------------------------------------------------------------------

/// 自动路径读 AI 指派的来源；主进程初始化时由 `AppModel` 装上（偏好仓库）。
/// 没装（测试、弹窗进程）= 自动路径什么都不做。
AiSettingsSource? _automaticSettings;

/// 装配自动路径的 AI 指派来源（null 卸下）。
void installCollectionAiOrderSettings(AiSettingsSource? settings) {
  _automaticSettings = settings;
}

/// 正在自动排序的合集：同一合集在一轮没跑完前不重复排队。
final Set<int> _automaticInFlight = <int>{};

/// 导入 / 归组后把新建或补了成员的合集交给自动 AI 排序，**不阻塞调用方**。
///
/// 门（任一不满足即不发请求）：已装配指派来源、`AiFeature.collectionOrder` 解析得到
/// 提供商、合集有规则判不出的成员、`orderUpdatedAt == 0`。逐个合集顺序跑、共用一个
/// 客户端（提供商限流按家排队）。失败只记诊断日志，规则序原样保留。
void scheduleAutomaticCollectionAiOrder({
  required FushiDatabase db,
  required Iterable<int> collectionIds,
  AiSettingsSource? settings,
}) {
  final AiSettingsSource? source = settings ?? _automaticSettings;
  if (source == null) return;
  if (resolveCollectionOrderAiProvider(source) == null) return;
  final List<int> ids = <int>[
    for (final int id in collectionIds.toSet())
      if (_automaticInFlight.add(id)) id,
  ];
  if (ids.isEmpty) return;
  unawaited(_runAutomaticBatch(db, source, ids));
}

Future<void> _runAutomaticBatch(
  FushiDatabase db,
  AiSettingsSource settings,
  List<int> ids,
) async {
  final AiChatClient client = AiChatClient();
  try {
    for (final int id in ids) {
      try {
        final CollectionAiOrderOutcome outcome = await runCollectionAiOrder(
          db: db,
          collectionId: id,
          settings: settings,
          userIntent: false,
          client: client,
        );
        if (outcome.persisted) {
          debugPrint('[collection-ai-order] collection $id: applied AI order');
        }
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'collectionAiOrder.automatic',
          error,
          stack,
        );
      } finally {
        _automaticInFlight.remove(id);
      }
    }
  } finally {
    client.close();
    _automaticInFlight.removeAll(ids);
  }
}

@visibleForTesting
bool get debugCollectionAiOrderSettingsInstalled => _automaticSettings != null;
