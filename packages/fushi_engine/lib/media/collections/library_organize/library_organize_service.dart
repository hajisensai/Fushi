import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_facts.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/collections/library_organize/organize_convergence.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';

/// 一次整理的结论。
enum LibraryOrganizeStatus {
  /// 跑完（可能一处也没改）。
  done,

  /// 没指派提供商 / AI 模块关闭：没发请求，只做了规则那一步。
  noProvider,

  /// 自动整理今天的请求额度用完了：没发请求，只做了规则那一步。
  overBudget,

  /// 用户取消：已完成的批次保留。
  cancelled,

  /// 某批请求失败（[LibraryOrganizeResult.error] 是脱敏短码）：已完成的批次保留。
  failed,
}

class LibraryOrganizeResult {
  const LibraryOrganizeResult({
    required this.status,
    required this.runId,
    required this.changes,
    required this.requests,
    this.error,
    this.touchedCollectionIds = const <int>{},
  });

  final LibraryOrganizeStatus status;

  /// 整理记录里的这一次；没落任何东西时也有（状态写成 skipped / failed）。
  final int runId;

  /// 落了几处改动。
  final int changes;
  final int requests;
  final String? error;
  final Set<int> touchedCollectionIds;
}

/// 自动整理每个域每天最多发几次请求（spec §10.2）。
const int kLibraryOrganizeDailyAutoRequests = 5;

/// 编排一次整理（spec §4）：规则成组 → 分块问 AI → 逐块裁决落盘 → 收敛。
///
/// 每块落盘一次：中途失败 / 取消时已完成的块保留（每处都在整理记录里、可撤销）。
class LibraryOrganizeService {
  LibraryOrganizeService({
    required this.db,
    required this.settings,
    required this.nameLanguage,
    required this.videoTagPrefix,
    AiChatClient Function()? clientFactory,
    DateTime Function()? clock,
    Set<String> Function()? allowedRejectedKeys,
  }) : _clientFactory = clientFactory ?? AiChatClient.new,
       _clock = clock ?? DateTime.now,
       _allowed = allowedRejectedKeys ?? (() => const <String>{});

  final FushiDatabase db;
  final AiSettingsSource settings;

  /// 新合集名的语言（BCP-47）。
  final String nameLanguage;

  /// 视频系列标签前缀（UI 语言，如 `系列:`）。
  final String videoTagPrefix;
  final AiChatClient Function() _clientFactory;
  final DateTime Function() _clock;

  /// 设备本地「允许再次建议」的分组键（app 偏好；服务端没有）。
  final Set<String> Function() _allowed;

  Future<LibraryOrganizeFacts> _facts(
    CollectionShelfDomain domain,
    Set<String>? onlyEntryKeys,
  ) => loadLibraryOrganizeFacts(
    db,
    domain,
    onlyEntryKeys: onlyEntryKeys,
    allowedKeys: _allowed(),
  );

  AiProviderConfig? get provider => resolveLibraryOrganizeAiProvider(settings);

  Future<LibraryOrganizeResult> run(
    CollectionShelfDomain domain, {
    required OrganizeTrigger trigger,
    Set<String>? onlyEntryKeys,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final AiProviderConfig? useProvider = provider;
    final int runId = await db
        .into(db.libraryOrganizeRuns)
        .insert(
          LibraryOrganizeRunsCompanion.insert(
            domain: domain.name,
            trigger: trigger.name,
            startedAt: _clock().millisecondsSinceEpoch,
            status: 'running',
            providerName: Value<String>(useProvider?.name ?? ''),
            model: Value<String>(useProvider?.model ?? ''),
          ),
        );
    int changes = 0;
    int requests = 0;
    int inputTokens = 0;
    int outputTokens = 0;
    final Set<int> touched = <int>{};
    LibraryOrganizeStatus status = LibraryOrganizeStatus.done;
    String? error;

    Future<int> countChanges() async => (await (db.select(
      db.libraryOrganizeChanges,
    )..where((t) => t.runId.equals(runId))).get()).length;

    try {
      // ① 规则：刮到同一个作品的散条目成组（不花钱，没提供商也做）。
      LibraryOrganizeFacts facts = await _facts(domain, onlyEntryKeys);
      touched.addAll(
        await applyOrganizeActions(
          db,
          runId: runId,
          actions: planFromRules(facts: facts, nameOf: _ruleGroupName),
        ),
      );

      // ② AI。
      if (useProvider == null) {
        status = LibraryOrganizeStatus.noProvider;
        error = 'provider_not_configured';
      } else if (trigger == OrganizeTrigger.auto &&
          await autoRequestsToday(domain) >=
              kLibraryOrganizeDailyAutoRequests) {
        status = LibraryOrganizeStatus.overBudget;
        error = 'daily_budget';
      } else {
        facts = await _facts(domain, onlyEntryKeys);
        final List<List<String>> plan = chunkOrganizeEntries(facts.entries);
        final AiChatClient client = _clientFactory();
        try {
          for (int i = 0; i < plan.length; i++) {
            if (isCancelled?.call() == true) {
              status = LibraryOrganizeStatus.cancelled;
              break;
            }
            if (trigger == OrganizeTrigger.auto &&
                requests +
                        await autoRequestsToday(domain, excludeRunId: runId) >=
                    kLibraryOrganizeDailyAutoRequests) {
              status = LibraryOrganizeStatus.overBudget;
              error = 'daily_budget';
              break;
            }
            onProgress?.call(i, plan.length);
            // 上一块可能建了合集、改了名字占用：每块重读一次。
            facts = await _facts(domain, onlyEntryKeys);
            final OrganizeChunk? chunk = buildOrganizeChunk(facts, plan[i]);
            if (chunk == null) continue;
            final AiLibraryOrganizeResponse response;
            try {
              response = await requestAiLibraryOrganize(
                client: client,
                provider: useProvider,
                request: organizeRequestOf(facts, chunk, nameLanguage),
              );
            } on AiChatFailure catch (failure) {
              status = LibraryOrganizeStatus.failed;
              error = failure.message;
              break;
            } finally {
              requests++;
            }
            inputTokens += response.usage?.inputTokens ?? 0;
            outputTokens += response.usage?.outputTokens ?? 0;
            final AiOrganizeReply? reply = response.reply;
            if (reply == null) {
              engineLog.logDiagnostic(
                'libraryOrganize',
                'run $runId chunk $i: reply failed validation; skipped',
              );
              continue;
            }
            touched.addAll(
              await applyOrganizeActions(
                db,
                runId: runId,
                actions: planFromAiReply(
                  facts: facts,
                  chunk: chunk,
                  reply: reply,
                  trigger: trigger,
                  tagPrefix: videoTagPrefix,
                ),
              ),
            );
          }
          if (status == LibraryOrganizeStatus.done) {
            onProgress?.call(plan.length, plan.length);
          }
        } finally {
          client.close();
        }
      }
      // ③ 本机同系列整理器合集合成一个（与同步后同一套收敛规划），并记进这次的整理
      // 记录——撤销整次整理时这些合并也能还原。
      touched.addAll(
        await applyOrganizeActions(
          db,
          runId: runId,
          actions: <OrganizeAction>[
            for (final ConvergenceMerge m in planOrganizeConvergence(
              await loadConvergenceCollections(db),
            ))
              OrganizeAction(
                kind: OrganizeActionKind.merge,
                source: 'rule',
                confidence: AiOrganizeConfidence.high,
                targetCollectionId: m.targetId,
                sourceCollectionIds: m.sourceIds,
              ),
          ],
        ),
      );
      changes = await countChanges();
    } on Object catch (e, stack) {
      engineLog.log('libraryOrganize.run', e, stack);
      status = LibraryOrganizeStatus.failed;
      error ??= 'internal_error';
      changes = await countChanges();
    }

    await (db.update(
      db.libraryOrganizeRuns,
    )..where((t) => t.id.equals(runId))).write(
      LibraryOrganizeRunsCompanion(
        finishedAt: Value<int?>(_clock().millisecondsSinceEpoch),
        // 只有每一块都处理完才是 done——自动整理的水位只认 done（见
        // [lastCompletedAutoRunStartedAt]），中途被额度 / 失败 / 取消截断的那批新条目
        // 下一轮还会再看。
        status: Value<String>(switch (status) {
          LibraryOrganizeStatus.done => 'done',
          LibraryOrganizeStatus.cancelled => 'cancelled',
          LibraryOrganizeStatus.failed => 'failed',
          LibraryOrganizeStatus.overBudget => 'partial',
          LibraryOrganizeStatus.noProvider => 'skipped',
        }),
        requestCount: Value<int>(requests),
        inputTokens: Value<int>(inputTokens),
        outputTokens: Value<int>(outputTokens),
        error: Value<String?>(error),
      ),
    );
    return LibraryOrganizeResult(
      status: status,
      runId: runId,
      changes: changes,
      requests: requests,
      error: error,
      touchedCollectionIds: touched,
    );
  }

  /// [domain] 上最近一次**跑完**（status = done，每一块都处理了）的自动整理的开始
  /// 时刻；没有返回 null。自动整理只看此后新入库的条目——被额度 / 失败 / 取消截断的
  /// 那次不推进水位，没处理到的条目下一轮还在。
  Future<int?> lastCompletedAutoRunStartedAt(
    CollectionShelfDomain domain,
  ) async {
    final LibraryOrganizeRunRow? row =
        await (db.select(db.libraryOrganizeRuns)
              ..where(
                (t) =>
                    t.domain.equals(domain.name) &
                    t.trigger.equals(OrganizeTrigger.auto.name) &
                    t.status.equals('done'),
              )
              ..orderBy(<OrderClauseGenerator<$LibraryOrganizeRunsTable>>[
                (t) => OrderingTerm.desc(t.startedAt),
              ])
              ..limit(1))
            .getSingleOrNull();
    return row?.startedAt;
  }

  /// 今天（本地日）自动整理在 [domain] 上已发的请求数。
  Future<int> autoRequestsToday(
    CollectionShelfDomain domain, {
    int? excludeRunId,
  }) async {
    final DateTime now = _clock();
    final int dayStart = DateTime(
      now.year,
      now.month,
      now.day,
    ).millisecondsSinceEpoch;
    int total = 0;
    for (final LibraryOrganizeRunRow r
        in await (db.select(db.libraryOrganizeRuns)..where(
              (t) =>
                  t.domain.equals(domain.name) &
                  t.trigger.equals(OrganizeTrigger.auto.name) &
                  t.startedAt.isBiggerOrEqualValue(dayStart),
            ))
            .get()) {
      if (r.id == excludeRunId) continue;
      total += r.requestCount;
    }
    return total;
  }
}

/// 规则成组的名字：视频取刮削作品标题，否则取第一条标题的系列主干。
String _ruleGroupName(List<OrganizeEntry> members) {
  for (final OrganizeEntry e in members) {
    final String? t = e.groupTitle;
    if (t != null && t.trim().isNotEmpty) return t.trim();
  }
  return parseVideoFilename(members.first.item.title).series;
}

/// 把条目分块（每块 ≤ [kAiOrganizeMaxItemsPerRequest]）：按折叠后的标题排序再切，
/// 同前缀的系列天然落在同一块；同一个整理器合集的成员尽量不拆开。返回每块的成员行键。
List<List<String>> chunkOrganizeEntries(List<OrganizeEntry> entries) {
  final List<OrganizeEntry> sorted = List<OrganizeEntry>.of(entries)
    ..sort((OrganizeEntry a, OrganizeEntry b) {
      // 同一合集的成员挨着放（按合集里最小标题作排序锚）。
      final int c = foldMediaTitle(
        a.item.title,
      ).compareTo(foldMediaTitle(b.item.title));
      return c != 0 ? c : a.memberKey.compareTo(b.memberKey);
    });
  final List<List<String>> out = <List<String>>[];
  List<String> current = <String>[];
  for (final OrganizeEntry e in sorted) {
    if (current.length >= kAiOrganizeMaxItemsPerRequest) {
      out.add(current);
      current = <String>[];
    }
    current.add(e.memberKey);
  }
  if (current.isNotEmpty) out.add(current);
  return out;
}

/// 用当前事实把一块成员行键还原成请求块：条目 + 合集。本域合集不超过
/// [kAiOrganizeMaxCollectionsPerRequest] 个时全部带上——跨语言 / 繁简不同的合集名与块内
/// 标题未必有共同字，正是要 AI 认的；超过时先带成员所在的整理器合集，再按与块内标题
/// 共有二字组的多少取前若干。块里的条目都已不在（被删 / 进了用户合集）时返回 null。
OrganizeChunk? buildOrganizeChunk(
  LibraryOrganizeFacts facts,
  List<String> memberKeys,
) {
  final Set<String> wanted = memberKeys.toSet();
  final List<OrganizeEntry> entries = <OrganizeEntry>[
    for (final OrganizeEntry e in facts.entries)
      if (wanted.contains(e.memberKey)) e,
  ];
  if (entries.isEmpty) return null;
  if (facts.collections.length <= kAiOrganizeMaxCollectionsPerRequest) {
    return OrganizeChunk(entries: entries, collections: facts.collections);
  }
  final Set<int> required = <int>{
    for (final OrganizeEntry e in entries)
      if (e.managedCollectionId != null) e.managedCollectionId!,
  };
  final Set<String> grams = <String>{
    for (final OrganizeEntry e in entries) ..._bigrams(e.item.title),
  };
  final List<(OrganizeCollectionFact, int)> scored =
      <(OrganizeCollectionFact, int)>[
        for (final OrganizeCollectionFact c in facts.collections)
          if (!required.contains(c.id))
            (c, _bigrams(c.name).where(grams.contains).length),
      ]..sort((
        (OrganizeCollectionFact, int) a,
        (OrganizeCollectionFact, int) b,
      ) {
        final int c = b.$2.compareTo(a.$2);
        return c != 0 ? c : a.$1.id.compareTo(b.$1.id);
      });
  final List<OrganizeCollectionFact> collections = <OrganizeCollectionFact>[
    for (final OrganizeCollectionFact c in facts.collections)
      if (required.contains(c.id)) c,
    for (final (OrganizeCollectionFact, int) s in scored) s.$1,
  ].take(kAiOrganizeMaxCollectionsPerRequest).toList();
  return OrganizeChunk(entries: entries, collections: collections);
}

Set<String> _bigrams(String title) {
  final List<int> r = foldMediaTitle(title).runes.toList();
  if (r.length < 2) return <String>{if (r.isNotEmpty) String.fromCharCodes(r)};
  return <String>{
    for (int i = 0; i + 1 < r.length; i++)
      String.fromCharCodes(r.sublist(i, i + 2)),
  };
}

/// 一块 → AI 请求（条目的 `in` 改写成块内合集编号）。
AiLibraryOrganizeRequest organizeRequestOf(
  LibraryOrganizeFacts facts,
  OrganizeChunk chunk,
  String nameLanguage,
) {
  final Map<int, String> cid = <int, String>{
    for (int n = 0; n < chunk.collections.length; n++)
      chunk.collections[n].id: chunk.collectionIdOf(n),
  };
  return AiLibraryOrganizeRequest(
    domain: facts.domain.name,
    nameLanguage: nameLanguage,
    knownKeys: <String>[
      for (final OrganizeCollectionFact c in chunk.collections)
        if (c.organizeKey != null) c.organizeKey!,
    ],
    rejected: <({String key, String name})>[
      for (final String k in facts.rejectedKeys.toList()..sort())
        (key: k, name: facts.rejectedNames[k] ?? ''),
    ].take(100).toList(),
    collections: <AiOrganizeCollection>[
      for (int n = 0; n < chunk.collections.length; n++)
        AiOrganizeCollection(
          id: chunk.collectionIdOf(n),
          name: chunk.collections[n].name,
          memberCount: chunk.collections[n].memberKeys.length,
          sampleTitles: chunk.collections[n].sampleTitles,
          userOwned: !chunk.collections[n].origin.isOrganizerManaged,
          organizeKey: chunk.collections[n].organizeKey,
        ),
    ],
    items: <AiOrganizeItem>[
      for (final OrganizeEntry e in chunk.entries)
        AiOrganizeItem(
          title: e.item.title,
          creator: e.item.creator,
          year: e.item.year,
          folder: e.item.folder,
          season: e.item.season,
          episode: e.item.episode,
          inCollection: e.managedCollectionId == null
              ? null
              : cid[e.managedCollectionId],
        ),
    ],
  );
}
