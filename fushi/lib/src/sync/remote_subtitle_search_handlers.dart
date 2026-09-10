import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart' show decodeTextBytes;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart';

/// 浏览器扩展「查字幕」桥（Side Panel → server → 全部已配置的在线字幕来源）的共享
/// handler 逻辑。与 [buildRemoteDictionaryLookupResponse] 同范式：纯逻辑（已解析
/// body Map → 注入的窄依赖 → 响应 Map），不碰 shelf/HTTP，便于单测。
///
/// **来源清单只有一个真相源**：[VideoSubtitleRegistry]。app 内「找字幕」对话框
/// （`subtitle_search_panel.dart`）早已改成走 registry，于是 Jimaku / OpenSubtitles /
/// AJATT 三家在视频页都搜得到；只有扩展这一侧还直连 [JimakuClient]，同一个用户在两个
/// 入口能力不同——没填 Jimaku key 的人在扩展里一个来源都没有（零配置的 AJATT 明明可用）。
///
/// 当初不走 registry 的理由是「registry.search 只在 `media.discoveryCategory == anime`
/// 时才让 jimaku 参与，而扩展请求只有页面标题、没有 media 引用」。那道分类门在
/// BUG-1694 之后已经从 registry 里删掉（见 `video_subtitle_registry.dart` 的注释：
/// 分类现在只影响**排序**，不再筛掉任何 provider），旧理由不再成立。
///
/// 旧端点 `/api/subtitle/jimaku/{search,fetch}` 保留、语义逐字不变：内置扩展随 app
/// 自更新，但磁盘副本刷新失败时会滞留旧版（BUG-1079 的 stale 态），旧扩展仍打旧路径。
/// 旧路径 = 本 handler 带 `restrictToProviderIds: {'jimaku'}`——只搜 Jimaku、缺 key 时
/// 仍回 `no-api-key`，handle 串也与旧实现逐字节相同（`jimaku:<entryId>:<fileName>`
/// 正是 [VideoSubtitleCandidate.identityKey]）。
///
/// 下载侧的候选按 handle 缓存在 server（LRU 上限见 server 侧），`fetch` 凭 handle 取回
/// 并交还给**它自己的 provider**（registry 按 providerId 分派）——两端点都过鉴权中间件，
/// handle 无需不可猜。

/// 响应候选总量上限（防整季包/合集条目把响应撑爆；截断计入 `truncated` 字段，扩展侧
/// 据此提示「结果过多，请带集数搜索」）。
const int kRemoteSubtitleSearchMaxCandidates = 100;

/// Jimaku 专用旧端点的 provider 限定集。
const Set<String> kJimakuOnlyProviderIds = <String>{'jimaku'};

/// `POST /api/subtitle/search` 的响应体。
///
/// body：`{query?, anilistId?, episode?, season?, anime?, languages?}`——query 与
/// anilistId 至少给一个。`anime` 是内容类型提示（Jimaku 的 `anime` 是硬相等过滤且服务端
/// 默认 true，真人剧不显式 false 永远 0 结果）：缺省 = 两档都试。
///
/// 成功响应带 `candidates`（每条含 `provider`，扩展据此显示来源徽标）与可选的
/// `failures`（部分来源挂了但另一些答了——把它们混成一个空结果，用户只会一遍遍换
/// 搜索词，见 [ProviderBatchResult.isPartial] 的同款理由）。
Future<Map<String, dynamic>> buildRemoteSubtitleSearchResponse(
  Map<String, dynamic> body, {
  required Future<VideoSubtitleRegistry?> Function() registryProvider,
  required void Function(String handle, VideoSubtitleCandidate candidate)
      rememberCandidate,
  Set<String>? restrictToProviderIds,
}) async {
  final List<VideoSubtitleProvider> providers =
      _selectProviders(await registryProvider(), restrictToProviderIds);
  if (providers.isEmpty) {
    return <String, dynamic>{
      'ok': false,
      'error': _noProviderError(restrictToProviderIds),
    };
  }
  final String query = body['query']?.toString().trim() ?? '';
  final Object? rawAnilistId = body['anilistId'];
  final int? anilistId = rawAnilistId is num ? rawAnilistId.toInt() : null;
  if (query.isEmpty && anilistId == null) {
    return <String, dynamic>{'ok': false, 'error': 'missing-query'};
  }
  final Object? rawEpisode = body['episode'];
  final Object? rawSeason = body['season'];
  final Object? rawAnime = body['anime'];
  final Object? rawLanguages = body['languages'];
  final VideoSubtitleSearchRequest request = VideoSubtitleSearchRequest(
    query: query,
    episode: rawEpisode is num ? rawEpisode.toInt() : null,
    season: rawSeason is num ? rawSeason.toInt() : null,
    anime: rawAnime is bool ? rawAnime : null,
    languages: rawLanguages is List
        ? rawLanguages
            .map((Object? value) => value?.toString().trim() ?? '')
            .where((String value) => value.isNotEmpty)
        : const <String>[],
  );
  // anilistId 只在扩展将来能认出作品身份时才有值；registry 的请求模型把它挂在
  // media 引用上，而扩展没有 media——现阶段忠实地不传，别造一个假的 media。
  final ProviderBatchResult<VideoSubtitleCandidate> result =
      await _searchProviders(providers, request);
  if (result.isTotalFailure) {
    final ExternalProviderFailure worst = _worstFailure(result.failures);
    return <String, dynamic>{
      'ok': false,
      'error': _failureError(worst, operation: 'search'),
      if (worst.statusCode != null) 'status': worst.statusCode,
      'failures': _failuresPayload(result.failures, operation: 'search'),
    };
  }
  final List<Map<String, dynamic>> candidates = <Map<String, dynamic>>[];
  bool truncated = false;
  for (final VideoSubtitleCandidate candidate in result.items) {
    if (candidates.length >= kRemoteSubtitleSearchMaxCandidates) {
      truncated = true;
      break;
    }
    final String handle = candidate.identityKey;
    rememberCandidate(handle, candidate);
    candidates.add(<String, dynamic>{
      'handle': handle,
      'provider': candidate.providerId,
      'entryName': _entryNameOf(candidate),
      'fileName': candidate.fileName,
      'language': candidate.language,
      if (candidate.episode != null) 'episode': candidate.episode,
      if (candidate.fileSize != null) 'fileSize': candidate.fileSize,
      if (candidate.downloadCount > 0) 'downloadCount': candidate.downloadCount,
      // 来源明确标注的机翻：扩展列表要能把它标出来，否则用户只能靠文件名猜
      // （OpenSubtitles 的机翻档与人工档并排，质量差一个数量级）。
      if (candidate.aiTranslated) 'aiTranslated': true,
      if (candidate.hearingImpaired) 'hearingImpaired': true,
    });
  }
  return <String, dynamic>{
    'ok': true,
    'candidates': candidates,
    if (truncated) 'truncated': true,
    if (result.hasFailures)
      'failures': _failuresPayload(result.failures, operation: 'search'),
  };
}

/// `POST /api/subtitle/fetch` 的响应体：下载 handle 对应的字幕文件，自动识别编码
/// （Jimaku 上 Shift-JIS 档不罕见，[decodeTextBytes] 处理），并直接复用
/// [buildParsedSubtitleResponse] 解析成与 `/api/subtitle/parse` **完全同形**的 cue
/// 载荷——扩展侧下游（InstallTrack → applyExternalSubtitle）零改动。
Future<Map<String, dynamic>> buildRemoteSubtitleFetchResponse(
  Map<String, dynamic> body, {
  required Future<VideoSubtitleRegistry?> Function() registryProvider,
  required VideoSubtitleCandidate? Function(String handle) resolveCandidate,
  Set<String>? restrictToProviderIds,
}) async {
  final VideoSubtitleRegistry? registry = await registryProvider();
  final List<VideoSubtitleProvider> providers =
      _selectProviders(registry, restrictToProviderIds);
  if (registry == null || providers.isEmpty) {
    return <String, dynamic>{
      'ok': false,
      'error': _noProviderError(restrictToProviderIds),
    };
  }
  final String handle = body['handle']?.toString() ?? '';
  final VideoSubtitleCandidate? candidate =
      handle.isEmpty ? null : resolveCandidate(handle);
  if (candidate == null ||
      (restrictToProviderIds != null &&
          !restrictToProviderIds.contains(candidate.providerId))) {
    // 缓存过期 / app 重启：扩展侧重搜一次即可恢复。
    return <String, dynamic>{'ok': false, 'error': 'unknown-handle'};
  }
  try {
    final VideoSubtitleDownload download = await registry.download(candidate);
    final Uint8List bytes = download.bytes;
    if (bytes.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': 'download-failed'};
    }
    final String content = await decodeTextBytes(bytes);
    final String fileName =
        download.fileName.isNotEmpty ? download.fileName : candidate.fileName;
    final Map<String, dynamic> parsed = buildParsedSubtitleResponse(
      filename: fileName,
      content: content,
    );
    return <String, dynamic>{
      'ok': parsed['error'] == null,
      'filename': fileName,
      'language':
          download.language.isNotEmpty ? download.language : candidate.language,
      'provider': candidate.providerId,
      ...parsed,
    };
  } on Object catch (error) {
    final ExternalProviderFailure failure =
        ExternalProviderFailure.fromException(
      providerId: candidate.providerId,
      operation: 'download',
      error: error,
    );
    return <String, dynamic>{
      'ok': false,
      'error': _failureError(failure, operation: 'download'),
      if (failure.statusCode != null) 'status': failure.statusCode,
    };
  }
}

/// 参与本次请求的 provider。[only] 非空时按 id 限定（旧 jimaku 端点）。
List<VideoSubtitleProvider> _selectProviders(
  VideoSubtitleRegistry? registry,
  Set<String>? only,
) {
  if (registry == null) return const <VideoSubtitleProvider>[];
  if (only == null) return registry.providers;
  return registry.providers
      .where((VideoSubtitleProvider provider) => only.contains(provider.id))
      .toList();
}

/// 扇出搜索：套一个**临时** registry，复用它的排序/去重/失败合并（这三样正是
/// 「统一来源」的实质，重写一遍就等于又多一个真相源）。临时实例不持有 provider 的
/// 所有权，绝不能 close——provider 实例属于真正的 registry。
Future<ProviderBatchResult<VideoSubtitleCandidate>> _searchProviders(
  List<VideoSubtitleProvider> providers,
  VideoSubtitleSearchRequest request,
) {
  return VideoSubtitleRegistry(providers).search(request);
}

/// 一个来源都没有：旧 jimaku 端点回 `no-api-key`（扩展提示去 app 设置里填 key），
/// 通用端点回 `no-provider`（用户可能是把三家全关了，跟「没填 key」不是一回事）。
String _noProviderError(Set<String>? restrictToProviderIds) =>
    restrictToProviderIds == null ? 'no-provider' : 'no-api-key';

String _entryNameOf(VideoSubtitleCandidate candidate) {
  final String? label = candidate.collectionLabel ?? candidate.releaseName;
  return label == null || label.trim().isEmpty ? candidate.fileName : label;
}

/// 全灭时对外报哪一条：鉴权/限流这类**用户能动手修**的原因优先于泛泛的不可用。
ExternalProviderFailure _worstFailure(List<ExternalProviderFailure> failures) {
  int rank(ExternalProviderFailure failure) => switch (failure.kind) {
        ExternalProviderFailureKind.unauthorized ||
        ExternalProviderFailureKind.forbidden =>
          0,
        ExternalProviderFailureKind.rateLimited ||
        ExternalProviderFailureKind.quotaExceeded =>
          1,
        _ => 2,
      };
  final List<ExternalProviderFailure> sorted = failures.toList()
    ..sort((ExternalProviderFailure a, ExternalProviderFailure b) =>
        rank(a).compareTo(rank(b)));
  return sorted.first;
}

/// 失败 kind → 扩展侧文案键。搜索与下载共用一张表，只有兜底值不同（搜索失败是
/// `unavailable`，下载失败是 `download-failed`，与旧实现逐字一致）。
String _failureError(
  ExternalProviderFailure failure, {
  required String operation,
}) =>
    switch (failure.kind) {
      ExternalProviderFailureKind.unauthorized ||
      ExternalProviderFailureKind.forbidden =>
        'unauthorized',
      ExternalProviderFailureKind.rateLimited ||
      ExternalProviderFailureKind.quotaExceeded =>
        'rate-limited',
      _ => operation == 'download' ? 'download-failed' : 'unavailable',
    };

List<Map<String, dynamic>> _failuresPayload(
  List<ExternalProviderFailure> failures, {
  required String operation,
}) =>
    <Map<String, dynamic>>[
      for (final ExternalProviderFailure failure in failures)
        <String, dynamic>{
          'provider': failure.providerId,
          'error': _failureError(failure, operation: operation),
          if (failure.statusCode != null) 'status': failure.statusCode,
        },
    ];
