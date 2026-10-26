import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';

import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show StreamVideoUrlImport, StreamVideoUrlImporter;
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_context.dart';

/// URL 视频导入（YouTube 等）的控制通道路由（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §2.2 / §8 P2）。每条路由调用 UI 按钮背后的同一个方法，不另写业务逻辑：
///
/// - 导入 = 视频导入对话框粘贴 URL 的「导入」（[StreamVideoUrlImporter.importUrl]）：
///   把 URL 当作一种视频源落进视频库（像本地视频一样进库、可重开，重开时 YouTube
///   现解析），**不下载视频字节**——这不是下载中心的能力，不受
///   `StoreRestrictedCapability.downloads` 管，iOS 上对话框同样有这个入口，只认视频模块门；
/// - 探测 = 播放页对 YouTube 用的同一组解析：[resolveYoutubeMetadata]（导入取标题 /
///   封面）、[resolveYoutubeVideoVariants]（画质菜单）、[resolveYoutubeCaptionTracks]
///   （字幕轨选择器）。只读，什么都不落库。
///
/// CLI 侧是 `fushi_cli url probe / import`
/// （`packages/fushi_cli/lib/src/commands/url_import_commands.dart`）。
List<CtlRoute> buildUrlImportCtlRoutes(OpContext context) =>
    buildUrlImportCtlRoutesFor(
      importer: () => StreamVideoUrlImporter(
        VideoBookRepository(context.appModel.database),
      ),
      videoEnabled: () =>
          context.appModel.moduleVisibility.isEnabled(ModuleId.video),
      isReadonly: () => context.appModel.isMigrationReadonly,
    );

/// 路由根。
const String kUrlImportCtlRoot = '/api/admin/url-import';

/// YouTube 探测用到的三段解析（测试注入假件，生产走引擎的同名函数）。
class UrlImportYoutubeProbe {
  const UrlImportYoutubeProbe({
    this.metadata = resolveYoutubeMetadata,
    this.variants = _defaultVariants,
    this.captions = _defaultCaptions,
  });

  final Future<YoutubeMetadata> Function(String url) metadata;
  final Future<YoutubeVariantSet> Function(String url) variants;
  final Future<List<YoutubeCaptionTrack>> Function(String url, String lang)
  captions;

  static Future<YoutubeVariantSet> _defaultVariants(String url) =>
      resolveYoutubeVideoVariants(url);

  static Future<List<YoutubeCaptionTrack>> _defaultCaptions(
    String url,
    String lang,
  ) => resolveYoutubeCaptionTracks(url, preferLang: lang);
}

/// 路由表本体：导入门面、模块门、只读闸门按回调注入，测试不必起 [OpContext]。
List<CtlRoute> buildUrlImportCtlRoutesFor({
  required StreamVideoUrlImporter Function() importer,
  required bool Function() videoEnabled,
  bool Function()? isReadonly,
  UrlImportYoutubeProbe youtube = const UrlImportYoutubeProbe(),
}) {
  void requireVideo() {
    if (!videoEnabled()) {
      throw const CtlFailure.rejected('视频模块已在设置里关闭（video）');
    }
  }

  return <CtlRoute>[
    CtlRoute.get('$kUrlImportCtlRoot/probe', (CtlCall call) async {
      requireVideo();
      final String url = _requireUrl(call);
      return probeImportUrl(
        url,
        youtube: youtube,
        lang:
            call.optString('lang') ??
            JapaneseLanguage.instance.locale.languageCode,
      );
    }),
    CtlRoute.post(kUrlImportCtlRoot, (CtlCall call) async {
      requireVideo();
      if (isReadonly?.call() ?? false) {
        throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
      }
      final String url = _requireUrl(call);
      final StreamVideoUrlImport imported = await importer().importUrl(
        url,
        subtitleUrl: _optUrl(call, 'subtitleUrl'),
        referer: call.optString('referer'),
        userAgent: call.optString('userAgent'),
      );
      return <String, Object?>{
        'bookUid': imported.bookUid,
        'key': 'video:${imported.bookUid}',
        'title': imported.title,
        'url': url.trim(),
        'kind': importUrlKind(url),
      };
    }),
  ];
}

String _requireUrl(CtlCall call) {
  final String url = call.requireString('url').trim();
  if (!isPlayableStreamUrl(url)) {
    throw CtlFailure.badRequest('只认 http(s) 地址：$url');
  }
  return url;
}

/// 可选的 URL 参数：给了就必须是 http(s)（对话框里非 http 的字幕地址静默忽略，命令行
/// 如实报错，免得用户以为挂上了字幕）。
String? _optUrl(CtlCall call, String name) {
  final String? raw = call.optString(name)?.trim();
  if (raw == null || raw.isEmpty) return null;
  if (!isPlayableStreamUrl(raw)) {
    throw CtlFailure.badRequest('$name 只认 http(s) 地址：$raw');
  }
  return raw;
}

/// URL 的种类：`youtube`（导入后由播放页现解析）/ `webPage`（已知网页视频站，导入后
/// 由网页播放器打开、无自动封面）/ `stream`（直链 / HLS，ffmpeg 抽封面）。与导入的封面
/// 策略同一个判据（[streamImportCoverStrategy]）。
String importUrlKind(String url) => switch (streamImportCoverStrategy(url)) {
  StreamImportCoverStrategy.youtubeThumbnail => 'youtube',
  StreamImportCoverStrategy.noAutomaticCover => 'webPage',
  StreamImportCoverStrategy.ffmpegFrame => 'stream',
};

/// 探测一个 URL：种类、导入后的条目身份；YouTube 再取标题 / 封面、可选画质、字幕轨。
/// 三段解析各自 best-effort：哪段失败记进 `errors`，其余照常返回（与播放页一致——
/// 字幕轨取不到视频照播）。
Future<Map<String, Object?>> probeImportUrl(
  String url, {
  required UrlImportYoutubeProbe youtube,
  required String lang,
}) async {
  final String kind = importUrlKind(url);
  final Map<String, Object?> out = <String, Object?>{
    'url': url,
    'kind': kind,
    'bookUid': streamVideoBookUid(url),
  };
  if (kind != 'youtube') return out;
  final Map<String, String> errors = <String, String>{};
  try {
    final YoutubeMetadata meta = await youtube.metadata(url);
    out['title'] = meta.title;
    out['thumbnail'] = meta.thumbnailUrl;
  } on Object catch (e) {
    errors['metadata'] = _shortError(e);
  }
  try {
    final YoutubeVariantSet set = await youtube.variants(url);
    out['qualities'] = <Map<String, Object?>>[
      for (int i = 0; i < set.variants.length; i++)
        <String, Object?>{
          'label': set.variants[i].label,
          'height': set.variants[i].height,
          'codec': set.variants[i].codec,
          if (i == set.defaultIndex) 'default': true,
        },
    ];
    // 没有分离流：只有 muxed ≤360p（YouTube 侧限制，播放页同样不显示画质档）。
    if (set.isEmpty) out['muxedOnly'] = true;
  } on Object catch (e) {
    errors['qualities'] = _shortError(e);
  }
  try {
    final List<YoutubeCaptionTrack> tracks = await youtube.captions(url, lang);
    out['captions'] = <Map<String, Object?>>[
      for (final YoutubeCaptionTrack t in tracks)
        <String, Object?>{
          'key': t.trackKey,
          'language': t.languageCode,
          'label': youtubeCaptionLanguageLabel(t),
          if (t.isAutoGenerated) 'auto': true,
          if (t.translateToCode != null) 'translatedTo': t.translateToCode,
        },
    ];
  } on Object catch (e) {
    errors['captions'] = _shortError(e);
  }
  if (errors.isNotEmpty) out['errors'] = errors;
  return out;
}

String _shortError(Object e) {
  final String text = '$e'.replaceAll('\n', ' ');
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}
