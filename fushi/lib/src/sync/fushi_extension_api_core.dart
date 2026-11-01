import 'package:flutter/foundation.dart' show immutable;
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart'
    show VideoSubtitleRegistry;
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart'
    show VideoSubtitleCandidate;
import 'package:fushi_engine/media/video/video_subtitle_source.dart'
    show buildParsedSubtitleResponse;
import 'package:fushi_engine/media/video/youtube_source_resolver.dart'
    show resolveYoutubeCaptionsForExtension;
import 'package:fushi/src/media/favorites/web_video_favorite.dart'
    show ExtensionVideoFavoriteHandler, ExtensionVideoFavoriteRequest;
import 'package:fushi/src/media/video/browser_video_study_bridge.dart'
    show BrowserVideoSample;
import 'package:fushi/src/sync/extension_font_api.dart';
import 'package:fushi/src/sync/remote_subtitle_search_handlers.dart';

/// [FushiExtensionApiCore.handle] 的结果：成功体是 JSON 对象，失败是状态码 + 纯文本
/// （文案与 HTTP 端点返回的 body 逐字一致）。
@immutable
class FushiExtensionApiResponse {
  const FushiExtensionApiResponse.json(
    Map<String, dynamic> this.json, {
    this.status = 200,
  }) : text = null;

  const FushiExtensionApiResponse.error(this.status, this.text) : json = null;

  final int status;

  /// 成功体。
  final Map<String, dynamic>? json;

  /// 错误时的纯文本体（如 `'Missing videoId'`）。
  final String? text;

  bool get ok => status >= 200 && status < 300;
}

/// YouTube 整集字幕解析函数的形状（生产实现是 [resolveYoutubeCaptionsForExtension]）。
typedef YoutubeCaptionsResolver =
    Future<Map<String, dynamic>> Function(
      String idOrUrl, {
      required String preferLang,
    });

/// 浏览器扩展一组端点（YouTube 字幕 / 外挂字幕解析 / 在线字幕搜索下载 / 字体列表 /
/// 弹窗尺寸回写 / 视频沉浸时间）与 HTTP 无关的核心逻辑。
///
/// 两个调用方共用同一实例：[FushiApiServer]（扩展经本机 HTTP 打过来）与 app 内浏览器
/// （进程内直接调，HTTP 服务没开时也可用）。在线字幕候选缓存挂在实例上，所以 search
/// 与 fetch 必须走同一实例。
class FushiExtensionApiCore {
  FushiExtensionApiCore({
    Future<VideoSubtitleRegistry?> Function()? subtitleRegistryProvider,
    ExtensionFontApi? fontApi,
    void Function(double maxWidth, double maxHeight)? onExtensionPopupSize,
    void Function(BrowserVideoSample sample)? onExtensionStudy,
    ExtensionVideoFavoriteHandler? onVideoFavorite,
    YoutubeCaptionsResolver? youtubeCaptionsResolver,
  }) : _subtitleRegistryProvider = subtitleRegistryProvider,
       _onVideoFavorite = onVideoFavorite,
       _fontApi = fontApi,
       _onExtensionPopupSize = onExtensionPopupSize,
       _onExtensionStudy = onExtensionStudy,
       _youtubeCaptionsResolver =
           youtubeCaptionsResolver ?? _defaultYoutubeCaptionsResolver;

  static const String youtubeCaptionsPath = '/api/youtube/captions';
  static const String subtitleParsePath = '/api/subtitle/parse';
  static const String subtitleSearchPath = '/api/subtitle/search';
  static const String subtitleFetchPath = '/api/subtitle/fetch';
  static const String jimakuSearchPath = '/api/subtitle/jimaku/search';
  static const String jimakuFetchPath = '/api/subtitle/jimaku/fetch';
  static const String fontsPath = '/api/extension/fonts';
  static const String popupSizePath = '/api/extension/popup-size';
  static const String studyPath = '/api/extension/study';

  /// 反馈 KGC1ifR1a3：看网页视频时收藏当前句 / 视频本身（写 App 收藏夹同一份收藏句）。
  static const String videoFavoritePath = '/api/extension/video-favorite';

  /// 本核心认的全部路径（含 jimaku 两条旧路径）。
  static const Set<String> paths = <String>{
    youtubeCaptionsPath,
    subtitleParsePath,
    subtitleSearchPath,
    subtitleFetchPath,
    jimakuSearchPath,
    jimakuFetchPath,
    fontsPath,
    popupSizePath,
    studyPath,
    videoFavoritePath,
  };

  final Future<VideoSubtitleRegistry?> Function()? _subtitleRegistryProvider;
  final ExtensionFontApi? _fontApi;
  final void Function(double maxWidth, double maxHeight)? _onExtensionPopupSize;
  final void Function(BrowserVideoSample sample)? _onExtensionStudy;
  final ExtensionVideoFavoriteHandler? _onVideoFavorite;
  final YoutubeCaptionsResolver _youtubeCaptionsResolver;

  static Future<Map<String, dynamic>> _defaultYoutubeCaptionsResolver(
    String idOrUrl, {
    required String preferLang,
  }) => resolveYoutubeCaptionsForExtension(idOrUrl, preferLang: preferLang);

  // 搜索候选按 handle 暂存（download 要交回候选对象本身：OpenSubtitles 的 fileId、
  // Jimaku/AJATT 的下载 URL 都只活在候选里，裸 handle 串重建不出来）；插入序 LRU。
  static const int _kSubtitleCandidateCacheLimit = 200;
  final Map<String, VideoSubtitleCandidate> _subtitleCandidates =
      <String, VideoSubtitleCandidate>{};

  Future<VideoSubtitleRegistry?> _subtitleRegistryFor() async =>
      await _subtitleRegistryProvider?.call();

  void _rememberSubtitleCandidate(String handle, VideoSubtitleCandidate c) {
    _subtitleCandidates.remove(handle); // 重插到尾部（LRU 触达即续期）
    _subtitleCandidates[handle] = c;
    while (_subtitleCandidates.length > _kSubtitleCandidateCacheLimit) {
      _subtitleCandidates.remove(_subtitleCandidates.keys.first);
    }
  }

  /// 服务器 stop 时清候选缓存。
  void clearSubtitleCandidates() => _subtitleCandidates.clear();

  /// 端点依赖的 sink / 字体源未注入时的 404 回应（与读请求体无关，先于 body 判）；
  /// 可用时回 null。HTTP 层据此保持「未注入 → 404 优先于非法 JSON 的 400」的旧顺序。
  FushiExtensionApiResponse? unavailableResponse(String path) {
    switch (path) {
      case fontsPath:
        if (_fontApi == null) {
          return const FushiExtensionApiResponse.error(404, 'Not Found');
        }
      case popupSizePath:
        if (_onExtensionPopupSize == null) {
          return const FushiExtensionApiResponse.error(
            404,
            'Popup size sink off',
          );
        }
      case studyPath:
        if (_onExtensionStudy == null) {
          return const FushiExtensionApiResponse.error(404, 'Study sink off');
        }
      case videoFavoritePath:
        if (_onVideoFavorite == null) {
          return const FushiExtensionApiResponse.error(
            404,
            'Video favorite sink off',
          );
        }
    }
    return null;
  }

  /// [body] 已解析好的 JSON 对象（`/api/extension/fonts` 忽略 body）。
  /// 未知路径 → 404 `Unknown endpoint`。
  Future<FushiExtensionApiResponse> handle(
    String path,
    Map<String, dynamic> body,
  ) async {
    final FushiExtensionApiResponse? unavailable = unavailableResponse(path);
    if (unavailable != null) return unavailable;
    switch (path) {
      case youtubeCaptionsPath:
        return _youtubeCaptions(body);
      case subtitleParsePath:
        return _subtitleParse(body);
      case subtitleSearchPath:
        return _subtitleSearch(body);
      case subtitleFetchPath:
        return _subtitleFetch(body);
      // 旧扩展副本（BUG-1079 的自更新 stale 态）仍打 jimaku 专用路径：限定到
      // Jimaku 一家，语义与旧实现逐字不变。
      case jimakuSearchPath:
        return _subtitleSearch(
          body,
          restrictToProviderIds: kJimakuOnlyProviderIds,
        );
      case jimakuFetchPath:
        return _subtitleFetch(
          body,
          restrictToProviderIds: kJimakuOnlyProviderIds,
        );
      case fontsPath:
        return _fonts();
      case popupSizePath:
        return _popupSize(body);
      case studyPath:
        return _study(body);
      case videoFavoritePath:
        return _videoFavorite(body);
      default:
        return const FushiExtensionApiResponse.error(404, 'Unknown endpoint');
    }
  }

  /// A（BUG-783 后续）：YouTube 网页视频**真整集字幕**——返回全部轨（自动/人工）+
  /// 各轨 cue。body：`{videoId 或 url, preferLang?}`。best-effort：无字幕/失败返回
  /// `{tracks:[]}`。
  Future<FushiExtensionApiResponse> _youtubeCaptions(
    Map<String, dynamic> body,
  ) async {
    final Object? id = body['videoId'] ?? body['url'];
    if (id is! String || id.isEmpty) {
      return const FushiExtensionApiResponse.error(400, 'Missing videoId');
    }
    final Object? lang = body['preferLang'];
    return FushiExtensionApiResponse.json(
      await _youtubeCaptionsResolver(
        id,
        preferLang: lang is String && lang.isNotEmpty ? lang : 'ja',
      ),
    );
  }

  /// B：给任意网页视频加载用户自己的外挂字幕文件。body：`{filename, content}`。
  /// 不支持的扩展名回 `{error:'unsupported'}`。
  FushiExtensionApiResponse _subtitleParse(Map<String, dynamic> body) {
    final Object? filename = body['filename'];
    final Object? content = body['content'];
    if (filename is! String || content is! String || filename.isEmpty) {
      return const FushiExtensionApiResponse.error(
        400,
        'Missing filename/content',
      );
    }
    return FushiExtensionApiResponse.json(
      buildParsedSubtitleResponse(filename: filename, content: content),
    );
  }

  /// 「查字幕」①搜索：逻辑在 [buildRemoteSubtitleSearchResponse]；候选按 handle 暂存供 fetch。
  Future<FushiExtensionApiResponse> _subtitleSearch(
    Map<String, dynamic> body, {
    Set<String>? restrictToProviderIds,
  }) async {
    return FushiExtensionApiResponse.json(
      await buildRemoteSubtitleSearchResponse(
        body,
        registryProvider: _subtitleRegistryFor,
        rememberCandidate: _rememberSubtitleCandidate,
        restrictToProviderIds: restrictToProviderIds,
      ),
    );
  }

  /// 「查字幕」②下载+解析：body `{handle}`，响应与 `/api/subtitle/parse` 同形。
  Future<FushiExtensionApiResponse> _subtitleFetch(
    Map<String, dynamic> body, {
    Set<String>? restrictToProviderIds,
  }) async {
    return FushiExtensionApiResponse.json(
      await buildRemoteSubtitleFetchResponse(
        body,
        registryProvider: _subtitleRegistryFor,
        resolveCandidate: (String handle) => _subtitleCandidates[handle],
        restrictToProviderIds: restrictToProviderIds,
      ),
    );
  }

  /// 字幕外观「字体」下拉框：目录里真实存在的字体 + 推荐字体表（逐项标注 installed）。
  Future<FushiExtensionApiResponse> _fonts() async {
    final ExtensionFontApi api = _fontApi!;
    final List<ExtensionFontEntry> fonts = await api.listFonts();
    final List<ExtensionRecommendedFont> recommended = await api
        .listRecommended();
    return FushiExtensionApiResponse.json(<String, dynamic>{
      'fonts': <Map<String, dynamic>>[
        for (final ExtensionFontEntry font in fonts) font.toJson(),
      ],
      'recommended': <Map<String, dynamic>>[
        for (final ExtensionRecommendedFont font in recommended) font.toJson(),
      ],
    });
  }

  /// 弹窗尺寸精细化 Phase D：扩展弹窗拖角后回写的最终基准最大宽高（未 clamp 的原始
  /// 逻辑像素），交给 sink（app 侧 clamp + 拖即解锁 + 只写扩展键）。
  FushiExtensionApiResponse _popupSize(Map<String, dynamic> body) {
    final dynamic w = body['maxWidth'];
    final dynamic h = body['maxHeight'];
    if (w is! num || h is! num) {
      return const FushiExtensionApiResponse.error(
        400,
        'Missing maxWidth/maxHeight',
      );
    }
    _onExtensionPopupSize!(w.toDouble(), h.toDouble());
    return const FushiExtensionApiResponse.json(<String, dynamic>{'ok': true});
  }

  /// 扩展视频沉浸时间样本（体见 [BrowserVideoSample]）：不合契约 400，成功 `{ok:true}`。
  /// 反馈 KGC1ifR1a3：body `{op: 'toggle'|'state', kind: 'sentence'|'video', url, title?,
  /// text?, startMs?, endMs?}` → `{favorite?: bool, video: bool, sentences: [{text, startMs}]}`。
  /// 地址不是网页 / 切换句子却没句子 400（写收藏夹的入口，HTTP 层与查词同一鉴权）。
  Future<FushiExtensionApiResponse> _videoFavorite(
    Map<String, dynamic> body,
  ) async {
    final ExtensionVideoFavoriteRequest? request =
        ExtensionVideoFavoriteRequest.tryParse(body);
    if (request == null) {
      return const FushiExtensionApiResponse.error(
        400,
        'Invalid video favorite',
      );
    }
    return FushiExtensionApiResponse.json(
      (await _onVideoFavorite!(request)).toJson(),
    );
  }

  FushiExtensionApiResponse _study(Map<String, dynamic> body) {
    final BrowserVideoSample? sample = BrowserVideoSample.tryParse(body);
    if (sample == null) {
      return const FushiExtensionApiResponse.error(400, 'Invalid study sample');
    }
    _onExtensionStudy!(sample);
    return const FushiExtensionApiResponse.json(<String, dynamic>{'ok': true});
  }
}
