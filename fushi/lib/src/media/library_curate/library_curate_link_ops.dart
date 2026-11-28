/// AI 库管家 ④ 步的两条宿主操作（spec `docs/specs/2026-11-18-ai-library-curator-design.md`
/// §5.2 / §5.4 / §4.4）：一批端点的关系推断、全库音乐关系批量推断。
///
/// 与详情页「查找相关作品」（`runMediaLinkInference`，固定手动门槛、一次一个端点、
/// 只撤新行）的区别：
/// - 门槛按触发方式取（自动路径只落高置信，[MediaLinkInferenceTrigger.automatic]）；
/// - 带作品层分量（§5.4：会把两部已成形作品并成一部的连接自动路径降为建议）；
/// - 撤销回执完整：生效连接带写入前的行（建议被 AI 升成生效的也能退回建议），建议
///   只删本轮新写的。
///
/// 一批端点共用一份库快照、一份作品图、**一次**裁决：先收齐所有端点的候选，同一对
/// 条目只留一条（从两端各出一次的不重复问 AI），再按 20 条一批发 AI 请求——请求数
/// 从「每个端点一次」降到「候选数 / 20」。本批先生效的连接造成的分量合并由
/// `applyMediaLinkCandidates` 在同一轮里记账（§5.4 第二条照常成立；图里还没有的
/// 孤立端点按单成员作品参与记账）。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_media_link_assistant.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/links/media_link_inference.dart';
import 'package:fushi_engine/media/links/music_link_inference.dart';
import 'package:fushi_engine/media/links/work_graph.dart';
import 'package:fushi_engine/media/links/work_graph_loader.dart';
import 'package:fushi_engine/media/links/wikidata_anime_bridge.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart'
    show VideoMetadataNetworkException;
import 'package:fushi_engine/utils/net/app_http.dart';

import 'package:fushi/src/media/links/media_link_inference_host.dart';

/// 触发方式的线上值 → 推断门槛。
MediaLinkInferenceTrigger libraryCurateLinkTrigger(String? raw) => raw == 'auto'
    ? MediaLinkInferenceTrigger.automatic
    : MediaLinkInferenceTrigger.manual;

/// 数一数 AI 裁决发了几次请求。
class _CountingJudge implements MediaLinkJudge {
  _CountingJudge(this.inner);

  final MediaLinkJudge inner;
  int calls = 0;

  /// 裁决中碰到的 AI 失败（第一批就失败时的抛出，或后面批次的
  /// [AiMediaLinkJudge.partialFailure]）；null = 没失败。
  AiChatFailure? failure;

  /// 真正发出的请求数：[AiMediaLinkJudge] 一次裁决会按批拆成多次请求，取它自己的
  /// 计数；别的实现（测试桩）按调用次数算。
  int get requests => switch (inner) {
    final AiMediaLinkJudge ai => ai.requestCount,
    _ => calls,
  };

  @override
  Future<List<MediaLinkVerdict?>> judge(
    List<MediaLinkCandidate> candidates,
  ) async {
    calls++;
    try {
      final List<MediaLinkVerdict?> out = await inner.judge(candidates);
      if (inner case final AiMediaLinkJudge ai) {
        failure ??= ai.partialFailure;
      }
      return out;
    } on AiChatFailure catch (e) {
      failure ??= e;
      rethrow;
    }
  }
}

/// 一次推断写下的一条（撤销回执）。
typedef LibraryCurateLinkWrite = ({
  MediaLinkId id,
  bool applied,
  MediaLinkRow? previous,
});

Map<String, Object?> libraryCurateLinkWriteJson(LibraryCurateLinkWrite w) =>
    <String, Object?>{
      'fromKind': w.id.fromKind,
      'fromKey': w.id.fromKey,
      'relation': w.id.relation,
      'toKind': w.id.toKind,
      'toKey': w.id.toKey,
      'applied': w.applied,
      if (w.previous != null) 'previous': w.previous!.toJson(),
    };

LibraryCurateLinkWrite? libraryCurateLinkWriteFromJson(Object? raw) {
  if (raw is! Map) return null;
  final List<Object?> parts = <Object?>[
    raw['fromKind'],
    raw['fromKey'],
    raw['relation'],
    raw['toKind'],
    raw['toKey'],
  ];
  if (parts.any((Object? p) => p is! String)) return null;
  MediaLinkRow? previous;
  if (raw['previous'] is Map) {
    previous = MediaLinkRow.fromJson(
      Map<String, dynamic>.from(raw['previous'] as Map),
    );
  }
  return (
    id: (
      fromKind: parts[0]! as String,
      fromKey: parts[1]! as String,
      relation: parts[2]! as String,
      toKind: parts[3]! as String,
      toKey: parts[4]! as String,
    ),
    applied: raw['applied'] == true,
    previous: previous,
  );
}

/// 撤销一批回执（倒序）：生效的退回写入前的行（之前没有 = 删行），建议删掉。用户
/// 之后确认 / 否决过的两者都拒绝（算已被处理，保留现值）。返回撤掉的条数。
Future<int> revertLibraryCurateLinkWrites(
  FushiDatabase db,
  List<LibraryCurateLinkWrite> writes,
) async {
  int reverted = 0;
  for (final LibraryCurateLinkWrite w in writes.reversed) {
    final bool ok = w.applied
        ? await db.revertAiMediaLink(w.id, previous: w.previous)
        : await db.discardMediaLinkSuggestion(w.id);
    if (ok) reverted++;
  }
  return reverted;
}

/// 推断用的外部依赖（测试注入离线桩）。
class LibraryCurateLinkDeps {
  const LibraryCurateLinkDeps({
    required this.fetchMalSourceMaterial,
    required this.lookupWikidataAnime,
    this.judge,
  });

  final MalSourceMaterialFetcher fetchMalSourceMaterial;
  final WikidataAnimeLookup lookupWikidataAnime;

  /// null = 不发 AI 请求（只落确定性证据）。
  final MediaLinkJudge? judge;
}

/// 一批端点推断的结论。
class LibraryCurateLinkResult {
  LibraryCurateLinkResult();

  final List<LibraryCurateLinkWrite> writes = <LibraryCurateLinkWrite>[];

  /// 推断失败（资料源连不上 / 限流）的端点：没写任何东西，下一趟再试。
  final List<String> failed = <String>[];
  int requests = 0;

  /// AI 裁决失败的短码（`AiChatFailure.message`；操作照常退回只落确定性证据）。
  /// 库管家据此判断要不要停掉后续 AI 请求（额度用尽 / 鉴权被拒）。null = 没失败。
  String? aiError;

  int get applied =>
      writes.where((LibraryCurateLinkWrite w) => w.applied).length;
  int get suggested => writes.length - applied;

  Map<String, Object?> toJson() => <String, Object?>{
    'applied': applied,
    'suggested': suggested,
    'requests': requests,
    'failed': failed,
    if (aiError != null) 'aiError': aiError,
    'writes': <Object?>[
      for (final LibraryCurateLinkWrite w in writes)
        libraryCurateLinkWriteJson(w),
    ],
  };
}

/// 对 [endpoints] 逐个推断并落库（spec §5.2 门槛 + §5.4 分量兜底）。
Future<LibraryCurateLinkResult> runLibraryCurateLinkInference({
  required FushiDatabase db,
  required List<MediaLinkEndpoint> endpoints,
  required MediaLinkInferenceTrigger trigger,
  required LibraryCurateLinkDeps deps,
}) async {
  final LibraryCurateLinkResult out = LibraryCurateLinkResult();
  final MediaLinkLibrarySnapshot library = await MediaLinkLibrarySnapshot.load(
    db,
  );
  final _CountingJudge? judge = deps.judge == null
      ? null
      : _CountingJudge(deps.judge!);
  final List<MediaLinkCandidate> candidates = <MediaLinkCandidate>[];
  for (final MediaLinkEndpoint self in endpoints) {
    try {
      candidates.addAll(
        await collectMediaLinkCandidates(
          library: library,
          self: self,
          fetchMalSourceMaterial: deps.fetchMalSourceMaterial,
          lookupWikidataAnime: deps.lookupWikidataAnime,
          withAiOnly: judge != null,
        ),
      );
    } on WikidataBridgeException {
      out.failed.add('${self.kind.dbValue}:${self.key}');
    } on VideoMetadataNetworkException {
      out.failed.add('${self.kind.dbValue}:${self.key}');
    }
  }
  if (candidates.isEmpty) return out;
  final WorkGraph graph = await loadWorkGraph(db);
  ({Object id, int size})? workOf(MediaLinkEndpoint e) {
    final Work? w = graph.workOf(e);
    return w == null ? null : (id: w.identity, size: w.members.length);
  }

  MediaLinkInferenceOutcome outcome;
  try {
    outcome = await applyMediaLinkCandidates(
      db: db,
      candidates: candidates,
      trigger: trigger,
      judge: judge,
      workOf: workOf,
    );
  } on AiChatFailure {
    // AI 第一批就失败（提供商不可用）：这一批只落确定性证据（与详情页按钮同一
    // 退路），不算失败。中途失败不走这里——已拿到的结论照常落库。
    outcome = await applyMediaLinkCandidates(
      db: db,
      candidates: candidates,
      trigger: trigger,
      workOf: workOf,
    );
  }
  for (final MediaLinkAiWrite w in outcome.appliedWrites) {
    out.writes.add((id: w.id, applied: true, previous: w.previous));
  }
  for (final MediaLinkId id in outcome.suggestedIds) {
    out.writes.add((id: id, applied: false, previous: null));
  }
  out.requests = judge?.requests ?? 0;
  out.aiError = judge?.failure?.message;
  return out;
}

/// 全库音乐关系批量推断（[runMusicMediaLinkBatchInference]）的结论 + 回执。
Future<LibraryCurateLinkResult> runLibraryCurateMusicInference({
  required FushiDatabase db,
  required MediaLinkInferenceTrigger trigger,
  MediaLinkJudge? judge,
}) async {
  final _CountingJudge? counting = judge == null ? null : _CountingJudge(judge);
  MusicLinkBatchResult batch;
  try {
    batch = await runMusicMediaLinkBatchInference(
      db: db,
      trigger: trigger,
      judge: counting,
    );
  } on AiChatFailure {
    batch = await runMusicMediaLinkBatchInference(db: db, trigger: trigger);
  }
  final LibraryCurateLinkResult out = LibraryCurateLinkResult()
    ..requests = counting?.requests ?? 0
    ..aiError = counting?.failure?.message;
  for (final MusicLinkBatchWrite w in batch.writes) {
    switch (w.disposition) {
      case MediaLinkDisposition.apply:
        out.writes.add((id: w.id, applied: true, previous: w.previous));
      case MediaLinkDisposition.suggest:
        out.writes.add((id: w.id, applied: false, previous: null));
      case MediaLinkDisposition.discard:
        break;
    }
  }
  return out;
}

/// 生产依赖：MAL（Jikan）+ Wikidata 桥 + 「作品关联」指派的 AI（[provider] 为 null
/// 不发 AI 请求）；AI 结论记进 [db] 的本机裁决缓存。用完调返回的 `close`。
({LibraryCurateLinkDeps deps, void Function() close}) libraryCurateLinkDeps(
  AiProviderConfig? provider,
  FushiDatabase db,
) {
  final MalVideoMetadataProvider mal = MalVideoMetadataProvider(
    client: createAppHttpIoClient(),
  );
  final AiChatClient? client = provider == null ? null : AiChatClient();
  return (
    deps: LibraryCurateLinkDeps(
      fetchMalSourceMaterial: mal.fetchSourceMaterial,
      lookupWikidataAnime: WikidataAnimeBridge.shared.anidbIdsForVndb,
      judge: provider == null
          ? null
          : AiMediaLinkJudge(
              client: client!,
              provider: provider,
              cache: MediaLinkVerdictCache(db),
            ),
    ),
    close: () {
      mal.close();
      client?.close();
    },
  );
}
