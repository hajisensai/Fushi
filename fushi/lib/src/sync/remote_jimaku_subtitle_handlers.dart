import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart' show decodeTextBytes;

import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart';

/// 浏览器扩展「Jimaku 查字幕」桥（Side Panel → server → jimaku.cc）的共享 handler 逻辑。
/// 与 [buildRemoteDictionaryLookupResponse] 同范式：纯逻辑（已解析 body Map → 注入的窄
/// 依赖 → 响应 Map），不碰 shelf/HTTP，便于单测。
///
/// 为什么**不走** VideoSubtitleRegistry：registry.search 只在
/// `media.discoveryCategory == anime` 时才让 jimaku 参与，而扩展请求只有页面标题、没有
/// media 引用——走 registry 则 jimaku 永远被过滤掉。扩展桥的目标就是 Jimaku（用户点名），
/// 直连 [JimakuClient] 语义最诚实；OpenSubtitles 等以后要接再抽通用层。
///
/// 下载侧的候选以 [RemoteJimakuCandidate] 形式按 handle 缓存在 server（LRU 上限见
/// server 侧），`/api/subtitle/jimaku/fetch` 凭 handle 取回——两端点都过鉴权中间件，
/// handle 无需不可猜。

class RemoteJimakuCandidate {
  RemoteJimakuCandidate({
    required this.entryId,
    required this.entryName,
    required this.fileName,
    required this.fileUrl,
    required this.language,
    this.fileSize,
    this.episode,
  });

  final int entryId;
  final String entryName;
  final String fileName;
  final String fileUrl;
  final String language;
  final int? fileSize;
  final int? episode;
}

/// 每个 entry 最多取的文件数与响应候选总量上限（防整季包/合集条目把响应撑爆；截断计入
/// `truncated` 字段，扩展侧可提示「结果过多，请带集数搜索」）。
const int kJimakuSearchMaxEntries = 5;
const int kJimakuSearchMaxCandidates = 100;

/// `POST /api/subtitle/jimaku/search` 的响应体。
/// body：`{query?, anilistId?, episode?, anime?}`——query 与 anilistId 至少给一个；
/// anime 缺省时先按 Jimaku 默认（只搜番剧）搜，空结果再显式 `anime=false` 补搜真人剧
/// （Jimaku 的 anime 是硬相等过滤且服务端默认 true，不补搜日剧/真人剧永远 0 结果）。
Future<Map<String, dynamic>> buildJimakuSearchResponse(
  Map<String, dynamic> body, {
  required JimakuClient? Function() clientProvider,
  required void Function(String handle, RemoteJimakuCandidate candidate)
      rememberCandidate,
}) async {
  final JimakuClient? client = clientProvider();
  if (client == null) {
    return <String, dynamic>{'ok': false, 'error': 'no-api-key'};
  }
  final String query = body['query']?.toString().trim() ?? '';
  final Object? rawAnilistId = body['anilistId'];
  final int? anilistId = rawAnilistId is num ? rawAnilistId.toInt() : null;
  if (query.isEmpty && anilistId == null) {
    return <String, dynamic>{'ok': false, 'error': 'missing-query'};
  }
  final Object? rawEpisode = body['episode'];
  final int? episode = rawEpisode is num ? rawEpisode.toInt() : null;
  final Object? rawAnime = body['anime'];
  final bool? anime = rawAnime is bool ? rawAnime : null;

  try {
    List<JimakuEntry> entries = await client.searchEntries(
      anilistId: anilistId,
      queryFallbacks: <String>[if (query.isNotEmpty) query],
      anime: anime,
      throwOnError: true,
    );
    if (entries.isEmpty && anime == null) {
      entries = await client.searchEntries(
        anilistId: anilistId,
        queryFallbacks: <String>[if (query.isNotEmpty) query],
        anime: false,
        throwOnError: true,
      );
    }
    final List<Map<String, dynamic>> candidates = <Map<String, dynamic>>[];
    bool truncated = entries.length > kJimakuSearchMaxEntries;
    for (final JimakuEntry entry in entries.take(kJimakuSearchMaxEntries)) {
      final List<JimakuFile> files = await client.listFiles(
        entry.id,
        episode: episode,
        throwOnError: true,
      );
      for (final JimakuFile file in files) {
        if (!file.isTextSubtitle) continue;
        if (candidates.length >= kJimakuSearchMaxCandidates) {
          truncated = true;
          break;
        }
        final String handle = 'jimaku:${entry.id}:${file.name}';
        final String language = detectSubtitleLanguage(file.name) ?? '';
        rememberCandidate(
          handle,
          RemoteJimakuCandidate(
            entryId: entry.id,
            entryName: entry.name,
            fileName: file.name,
            fileUrl: file.url,
            language: language,
            fileSize: file.size,
            episode: file.episode,
          ),
        );
        candidates.add(<String, dynamic>{
          'handle': handle,
          'provider': 'jimaku',
          'entryId': entry.id,
          'entryName': entry.name,
          'fileName': file.name,
          'language': language,
          if (file.episode != null) 'episode': file.episode,
          if (file.size != null) 'fileSize': file.size,
        });
      }
    }
    return <String, dynamic>{
      'ok': true,
      'candidates': candidates,
      if (truncated) 'truncated': true,
    };
  } on JimakuRequestException catch (e) {
    return <String, dynamic>{
      'ok': false,
      'error': switch (e.statusCode) {
        401 || 403 => 'unauthorized',
        429 => 'rate-limited',
        _ => 'unavailable',
      },
      if (e.statusCode != null) 'status': e.statusCode,
    };
  } on Object {
    return <String, dynamic>{'ok': false, 'error': 'unavailable'};
  }
}

/// `POST /api/subtitle/jimaku/fetch` 的响应体：下载 handle 对应的字幕文件，自动识别编码
/// （Jimaku 上 Shift-JIS 档不罕见，[decodeTextBytes] 处理），并直接复用
/// [buildParsedSubtitleResponse] 解析成与 `/api/subtitle/parse` **完全同形**的 cue 载荷——
/// 扩展侧下游（InstallTrack → applyExternalSubtitle）零改动。
Future<Map<String, dynamic>> buildJimakuFetchResponse(
  Map<String, dynamic> body, {
  required JimakuClient? Function() clientProvider,
  required RemoteJimakuCandidate? Function(String handle) resolveCandidate,
}) async {
  final JimakuClient? client = clientProvider();
  if (client == null) {
    return <String, dynamic>{'ok': false, 'error': 'no-api-key'};
  }
  final String handle = body['handle']?.toString() ?? '';
  final RemoteJimakuCandidate? candidate =
      handle.isEmpty ? null : resolveCandidate(handle);
  if (candidate == null) {
    // 缓存过期 / app 重启：扩展侧重搜一次即可恢复。
    return <String, dynamic>{'ok': false, 'error': 'unknown-handle'};
  }
  try {
    final Uint8List? bytes = await client.downloadFile(
      candidate.fileUrl,
      throwOnError: true,
    );
    if (bytes == null || bytes.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': 'download-failed'};
    }
    final String content = await decodeTextBytes(bytes);
    final Map<String, dynamic> parsed = buildParsedSubtitleResponse(
      filename: candidate.fileName,
      content: content,
    );
    return <String, dynamic>{
      'ok': parsed['error'] == null,
      'filename': candidate.fileName,
      'language': candidate.language,
      ...parsed,
    };
  } on JimakuRequestException catch (e) {
    return <String, dynamic>{
      'ok': false,
      'error': switch (e.statusCode) {
        401 || 403 => 'unauthorized',
        429 => 'rate-limited',
        _ => 'download-failed',
      },
      if (e.statusCode != null) 'status': e.statusCode,
    };
  } on Object {
    return <String, dynamic>{'ok': false, 'error': 'download-failed'};
  }
}
