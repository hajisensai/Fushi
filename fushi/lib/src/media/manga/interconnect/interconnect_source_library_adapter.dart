/// 对端借出的扩展源在书架侧的运行时适配器（[OnlineMangaRuntimeKind.interconnectSource]）。
///
/// 与 `InterconnectLibraryAdapter`（对端漫画**库**）并列：那条读对端已下载的内容，
/// 这条让对端替本机跑扩展。作品页 / 下载 worker / 更新探针只认
/// [OnlineMangaRuntimeAdapter]，所以这里只做「entry → 找对端 → 打端点 → 归一化」，
/// 页图的 4 并发 / 落盘 / 重试全是既有管线的事。
library;

import 'dart:typed_data';

import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_client.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_registry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi_engine/sync/manga_sources/host_manga_source_host.dart';

class InterconnectSourceLibraryAdapter implements OnlineMangaRuntimeAdapter {
  const InterconnectSourceLibraryAdapter({
    required this.registry,
    required this.transport,
    this.presetSource,
  });

  final InterconnectMangaSourceRegistry registry;
  final InterconnectMangaSourceTransport transport;

  /// 浏览页已经知道该走哪台对端时直接给，省一次注册表解析（与 Mihon 的
  /// `presetContext` 同理）。
  final InterconnectRemoteSource? presetSource;

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.interconnectSource;

  /// 经对端代理浏览第三方扩展源，合规上仍是「在线漫画源宿主」——iOS 与 Mihon /
  /// Aidoku / mokuro.moe 同一道门（判据只写在 [StoreRestrictedCapability]）。
  @override
  bool get isSupportedOnThisPlatform =>
      StoreRestrictedCapability.onlineMangaSource.isAvailable;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async {
    final InterconnectRemoteSource? source = await _resolveOrNull(entry);
    return source == null
        ? null
        : sourceLabelFor(source.name, source.peer.displayName);
  }

  /// 作品页副标题 / 搜索段行头共用的「源名 · 设备名」拼法。
  static String sourceLabelFor(String sourceName, String deviceName) =>
      '$sourceName · $deviceName';

  @override
  Future<OnlineMangaRefreshResult> refresh(OnlineMangaLibraryEntry entry) =>
      _guarded('details', () async {
        final InterconnectRemoteSource source = await _resolve(entry);
        final RemoteMangaSeriesDetail detail = await transport.details(
          source.peer,
          source.id,
          entry.series.toJson(),
        );
        return OnlineMangaRefreshResult(
          // 详情可能不带 key（与 Mihon BUG-1767 同因）：身份沿用已知的。
          series: OnlineMangaSeries.fromJson(detail.series) ?? entry.series,
          chapters: <OnlineMangaChapter>[
            for (final Map<String, Object?> json in detail.chapters)
              if (OnlineMangaChapter.fromJson(json)
                  case final OnlineMangaChapter chapter)
                chapter,
          ],
        );
      });

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) => _guarded('pages', () async {
    final InterconnectRemoteSource source = await _resolve(entry);
    final Map<String, Object?> series = entry.series.toJson();
    final Map<String, Object?> chapterJson = chapter.toJson();
    final List<Map<String, Object?>> pages = await transport.pages(
      source.peer,
      source.id,
      series,
      chapterJson,
    );
    if (pages.isEmpty) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'EMPTY_CHAPTER',
        stage: 'pages',
      );
    }
    return <OnlineMangaPageRef>[
      for (int i = 0; i < pages.length; i++)
        InterconnectSourceMangaPageRef(
          index: i,
          sourceId: source.id,
          series: series,
          chapter: chapterJson,
          page: pages[i],
        ),
    ];
  });

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) {
    if (page is! InterconnectSourceMangaPageRef) {
      throw ArgumentError.value(
        page,
        'page',
        'InterconnectSourceLibraryAdapter only fetches its own page refs',
      );
    }
    return _guarded('pages', () async {
      final InterconnectRemoteSource source = await _resolveSource(
        page.sourceId,
      );
      return transport.pageImage(
        source.peer,
        source.id,
        page.series,
        page.chapter,
        page.page,
      );
    });
  }

  @override
  Future<List<int>> fetchCover(OnlineMangaLibraryEntry entry, String url) =>
      _guarded('cover', () async {
        final InterconnectRemoteSource source = await _resolve(entry);
        return transport.coverImage(
          source.peer,
          source.id,
          entry.series.toJson(),
          url,
        );
      });

  /// 浏览页 / 作品页未入库时的封面取图器（磁盘缓存命名空间按源分槽）。
  /// [series] 随请求带给对端（Aidoku 封面要作品页当 Referer）。
  RemoteCoverFetcher coverFetcher(
    InterconnectRemoteSource source,
    OnlineMangaSeries series,
  ) => _SourceCoverFetcher(transport, source, series.toJson());

  Future<InterconnectRemoteSource> _resolve(OnlineMangaLibraryEntry entry) =>
      _resolveSource(entry.sourceId);

  Future<InterconnectRemoteSource?> _resolveOrNull(
    OnlineMangaLibraryEntry entry,
  ) async {
    final InterconnectRemoteSource? preset = presetSource;
    if (preset != null && preset.id == entry.sourceId) return preset;
    try {
      return await registry.resolve(entry.sourceId);
    } catch (_) {
      return null;
    }
  }

  Future<InterconnectRemoteSource> _resolveSource(String sourceId) async {
    final InterconnectRemoteSource? preset = presetSource;
    if (preset != null && preset.id == sourceId) return preset;
    final InterconnectRemoteSource? found = await registry.resolve(sourceId);
    if (found == null) {
      throw const InterconnectMangaSourceException(
        InterconnectMangaSourceException.codeUnavailable,
        'No paired device currently provides this source',
      );
    }
    return found;
  }

  Future<T> _guarded<T>(String stage, Future<T> Function() request) async {
    try {
      return await request();
    } on OnlineMangaUnavailable {
      rethrow;
    } on InterconnectMangaSourceException catch (error) {
      // 「没有对端提供该源」/「对端已停用该源」= 源不可用：作品页据此引导去来源页
      // 看对端状态，而不是给一个永远不会成功的「重试」。其余（对端离线、站点抽风、
      // 对端被 Cloudflare 拦下）都是这次调用失败，可重试。
      final bool disabled =
          error.code == InterconnectMangaSourceException.codeUnavailable ||
          error.isSourceNotFound;
      throw OnlineMangaUnavailable(
        disabled
            ? OnlineMangaUnavailableReason.sourceDisabled
            : OnlineMangaUnavailableReason.runtimeFailure,
        error.message,
        cause: error,
        stage: stage,
      );
    } on Object catch (error) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        '$error',
        cause: error,
        stage: stage,
      );
    }
  }
}

class _SourceCoverFetcher implements RemoteCoverFetcher {
  const _SourceCoverFetcher(this._transport, this._source, this._series);

  final InterconnectMangaSourceTransport _transport;
  final InterconnectRemoteSource _source;
  final Map<String, Object?> _series;

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) =>
      _transport.coverImage(_source.peer, _source.id, _series, coverUrl);

  /// 按源分槽：同一封面 URL 在不同源下可能是不同图；同源经不同对端走则是同一张。
  @override
  String get coverCacheNamespace => 'interconnect_source|${_source.id}';
}
