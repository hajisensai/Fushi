/// Audiobookshelf（ABS）的发现源 adapter：一个实例 = 一台用户自配的 ABS 服务器。
///
/// 浏览两层：根（`path == null`）列出**有声书库**（podcast 库 v1 不支持，过滤掉）→
/// 进库（`path == 'library:<id>'`）分页列条目。搜索在全部有声书库里各搜一次再合并
/// （ABS 的搜索端点按库、不分页）。
///
/// 下载 payload **延迟物化**（列表阶段 `payload: null`）：access token 一小时就
/// 过期，列表阶段塞进去的 `Authorization` 等到下载队列真正开跑时可能早已作废；而
/// `resolvePayload` 由下载队列在每次（含重试）开跑前调，经协议层 `/api/me` 先把
/// 令牌刷新好、把下载权限核掉，交出去的永远是一枚新鲜令牌。
library;

import 'package:http/http.dart' as http;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/external_provider.dart';

/// 源 id 前缀。持久化的「停用源清单」按 id 存，改前缀即断档。
const String kAudiobookshelfSourceIdPrefix = 'abs-';

String audiobookshelfSourceIdFor(String configId) =>
    '$kAudiobookshelfSourceIdPrefix$configId';

/// 库目录的 browse 路径前缀（`DiscoveryFolder.path` 的源内语义）。
const String kAudiobookshelfLibraryPathPrefix = 'library:';

/// 每个库的搜索条数上限（ABS 搜索不分页）。
const int kAudiobookshelfSearchLimitPerLibrary = 25;

/// 下载前物化失败、需要用户采取行动的错误。
///
/// 下载队列把失败原样 `'$error'` 展示在任务行上（`DiscoveryDownloadTask.error`），
/// 所以 [toString] 就是给用户看的那句话，而不是 `ExternalProviderFailure(...)` 那串
/// 诊断格式——「没有下载权限」「登录已失效」是用户自己能照着改的结论。
class AudiobookshelfActionRequired implements Exception {
  const AudiobookshelfActionRequired(this.message, {required this.failure});

  final String message;

  /// 协议层的原始脱敏失败（诊断用）。
  final ExternalProviderFailure failure;

  @override
  String toString() => message;
}

class AudiobookshelfDiscoverySource extends MediaDiscoverySource {
  AudiobookshelfDiscoverySource({
    required this.config,
    this.priority = 30,
    AudiobookshelfTokensChanged? onTokensChanged,
    http.Client? client,
  }) : _api = AudiobookshelfApi(
         serverUrl: config.serverUrl,
         providerId: audiobookshelfSourceIdFor(config.id),
         tokens: config.tokens,
         onTokensChanged: onTokensChanged,
         client: client,
       );

  final AudiobookshelfServerConfig config;
  final AudiobookshelfApi _api;

  /// 有声书库清单缓存。null = 还没取到（失败也保持 null，下次重取）。
  List<AudiobookshelfLibrary>? _bookLibraries;

  @override
  String get id => audiobookshelfSourceIdFor(config.id);

  @override
  String get displayName => config.displayName;

  @override
  final int priority;

  @override
  bool get isUserConfigured => true;

  @override
  DiscoveryCapabilities get capabilities => DiscoveryCapabilities(
    kinds: const <DiscoveryMediaKind>{DiscoveryMediaKind.audiobook},
    supportsSearch: true,
    supportsBrowse: true,
    supportsPaging: true,
  );

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> browse(
    DiscoveryRequest request,
  ) async {
    final String? libraryId = _libraryIdOf(request.path);
    if (libraryId == null) {
      return _single(
        DiscoveryResultPage(
          entries: <DiscoveryEntry>[
            if (request.page <= 1)
              for (final AudiobookshelfLibrary library in await _libraries())
                DiscoveryFolder(
                  sourceId: id,
                  title: library.name,
                  path: '$kAudiobookshelfLibraryPathPrefix${library.id}',
                ),
          ],
          page: request.page,
          hasMore: false,
        ),
      );
    }
    final AudiobookshelfItemPage page = await _api.libraryItems(
      libraryId,
      page: request.page - 1,
      limit: request.pageSize,
    );
    return _single(
      DiscoveryResultPage(
        entries: _resourcesOf(page.items),
        page: request.page,
        hasMore: page.hasMore,
      ),
    );
  }

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) async {
    // ABS 搜索不分页：第一页即全部。
    if (request.page > 1) {
      return _single(
        DiscoveryResultPage(
          entries: const <DiscoveryEntry>[],
          page: request.page,
          hasMore: false,
        ),
      );
    }
    final String query = request.query!.trim();
    final List<AudiobookshelfItem> hits = <AudiobookshelfItem>[];
    final Set<String> seen = <String>{};
    for (final AudiobookshelfLibrary library in await _libraries()) {
      for (final AudiobookshelfItem item in await _api.search(
        library.id,
        query,
        limit: kAudiobookshelfSearchLimitPerLibrary,
      )) {
        if (seen.add(item.id)) hits.add(item);
      }
    }
    return _single(
      DiscoveryResultPage(
        entries: _resourcesOf(hits),
        page: request.page,
        hasMore: false,
      ),
    );
  }

  /// 下载前物化：新鲜令牌 + 下载权限 + 带扩展名的文件名。
  @override
  Future<DiscoveryPayload> resolvePayload(DiscoveryResourceItem item) async {
    final AudiobookshelfDownloadTarget target;
    try {
      target = await _api.prepareDownload(item.id);
    } on ExternalProviderFailure catch (failure) {
      throw _actionRequiredFor(failure) ?? failure;
    }
    return DiscoveryHttpPayload(
      url: target.url.toString(),
      // 鉴权头只发往本服务器自己的 origin（下载地址由本服务器拼出，恒同源；
      // 这条判据是给将来「条目里给出外部地址」留的闸门）。
      headers: _api.isServerOrigin(target.url)
          ? target.headers
          : const <String, String>{},
      fileName: target.fileName,
      sizeBytes: target.sizeBytes,
    );
  }

  /// 需要用户自己动手的失败 → 给人看的错误；其余原样上抛。
  static AudiobookshelfActionRequired? _actionRequiredFor(
    ExternalProviderFailure failure,
  ) => switch (failure.kind) {
    ExternalProviderFailureKind.forbidden => AudiobookshelfActionRequired(
      t.discovery_audiobookshelf_download_forbidden,
      failure: failure,
    ),
    ExternalProviderFailureKind.unauthorized => AudiobookshelfActionRequired(
      t.discovery_audiobookshelf_session_expired,
      failure: failure,
    ),
    _ => null,
  };

  Future<List<AudiobookshelfLibrary>> _libraries() async {
    final List<AudiobookshelfLibrary>? cached = _bookLibraries;
    if (cached != null) return cached;
    final List<AudiobookshelfLibrary> fetched = <AudiobookshelfLibrary>[
      for (final AudiobookshelfLibrary library in await _api.libraries())
        if (library.isBookLibrary) library,
    ];
    return _bookLibraries = fetched;
  }

  static String? _libraryIdOf(String? path) {
    if (path == null || !path.startsWith(kAudiobookshelfLibraryPathPrefix)) {
      return null;
    }
    final String id = path.substring(kAudiobookshelfLibraryPathPrefix.length);
    return id.isEmpty ? null : id;
  }

  /// 条目 → 资源项。只有电子书 / 补充文件、确定没有音频的条目不列：它们在有声书
  /// 页里点下载必然以导入失败收场。
  List<DiscoveryEntry> _resourcesOf(Iterable<AudiobookshelfItem> items) =>
      <DiscoveryEntry>[
        for (final AudiobookshelfItem item in items)
          if (!item.hasNoAudio && item.mediaType != 'podcast')
            DiscoveryResourceItem(
              sourceId: id,
              id: item.id,
              title: item.title,
              kind: DiscoveryMediaKind.audiobook,
              payloadKind: DiscoveryPayloadKind.httpFile,
              // payload 留空 → 下载时 resolvePayload 现取新鲜令牌。
              sizeBytes: item.sizeBytes,
              dateText: item.publishedYear,
              coverUrl: _api.coverUri(item.id).toString(),
              note: audiobookshelfItemNote(item),
            ),
      ];

  @override
  void close() => _api.close();
}

/// 条目的一行标注：作者 · 演播 · 系列 · 时长（缺的项跳过）。
String? audiobookshelfItemNote(AudiobookshelfItem item) {
  final List<String> parts = <String>[
    if (item.authorName case final String author) author,
    if (item.narratorName case final String narrator)
      t.discovery_audiobookshelf_item_narrated_by(name: narrator),
    if (item.seriesName case final String series) series,
    if (item.durationSeconds case final double seconds when seconds > 0)
      formatAudiobookshelfDuration(seconds),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// 秒 → `H:MM:SS`（有声书动辄十几小时，不折成天）。
String formatAudiobookshelfDuration(double seconds) {
  final int total = seconds.round();
  final int hours = total ~/ 3600;
  final int minutes = (total % 3600) ~/ 60;
  final int secs = total % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return '$hours:${two(minutes)}:${two(secs)}';
}

ProviderBatchResult<DiscoveryResultPage> _single(DiscoveryResultPage page) =>
    ProviderBatchResult<DiscoveryResultPage>.success(<DiscoveryResultPage>[
      page,
    ]);
