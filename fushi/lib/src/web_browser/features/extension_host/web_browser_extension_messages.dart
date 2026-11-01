import 'package:fushi/src/sync/fushi_extension_api_core.dart';

/// 扩展 `chrome.runtime.sendMessage` 在 app 内浏览器里的落点要用到的 app 能力。
class WebBrowserExtensionHostServices {
  const WebBrowserExtensionHostServices({
    required this.api,
    required this.openSidePanel,
    required this.openOptions,
    required this.dismissLookup,
    this.onStudySample,
    this.recordStudy = true,
  });

  /// 扩展后端核心（与 HTTP 服务器同一份实现，进程内直接调，不绕本机 HTTP）。
  final Future<FushiExtensionApiResponse> Function(
    String path,
    Map<String, dynamic> body,
  )
  api;

  /// 打开 app 原生字幕侧栏（扩展里是浏览器 Side Panel）。
  final void Function() openSidePanel;

  /// 打开扩展设置（扩展里是 options 页）。
  final void Function() openOptions;

  /// 关掉 app 查词弹窗（扩展里是让 Side Panel 自关；宿主弹窗由 content.js 的适配口另关）。
  final void Function() dismissLookup;

  /// 沉浸时间样本到达（不论是否落库成功）：浏览器的阅读计时据此避让在播的视频。
  final void Function(Map<String, dynamic> sample)? onStudySample;

  /// 沉浸时间是否落库。无痕标签页为 false：与网页阅读计时（`WebBrowserStudyFeature`
  /// 无痕不计）同一条规矩，样本不进学习统计。
  final bool recordStudy;
}

/// 宿主不支持的消息（Netflix 录制、批量剪辑、页内弹窗专用链路……留后续阶段）回这个：
/// 调用方都按 `ok !== true` 当失败处理，不会卡住。
const Map<String, Object?> kWebBrowserExtensionUnsupported = <String, Object?>{
  'ok': false,
  'error': 'unsupported-in-app',
};

Future<Map<String, Object?>> _apiReply(
  WebBrowserExtensionHostServices s,
  String path,
  Map<String, dynamic> body,
) async {
  final FushiExtensionApiResponse r = await s.api(path, body);
  return <String, Object?>{
    'ok': r.ok,
    'status': r.status,
    'data': r.ok ? r.json : null,
    if (!r.ok) 'error': r.text ?? 'http_${r.status}',
  };
}

String _str(Object? v) => v is String ? v : '';

/// 一条 `chrome.runtime.sendMessage` 的回应（形状与扩展 background.js 对应分支的
/// `sendResponse` 一致，内容脚本按原样消费）。
Future<Map<String, Object?>> routeWebBrowserExtensionMessage(
  Map<String, dynamic> message,
  WebBrowserExtensionHostServices s,
) async {
  final Object? type = message['type'];
  switch (type) {
    case 'youtubeCaptions':
      return _apiReply(
        s,
        FushiExtensionApiCore.youtubeCaptionsPath,
        <String, dynamic>{
          'videoId': _str(message['videoId']),
          'preferLang': _str(message['preferLang']).isEmpty
              ? 'ja'
              : _str(message['preferLang']),
        },
      );
    case 'parseSubtitle':
      return _apiReply(
        s,
        FushiExtensionApiCore.subtitleParsePath,
        <String, dynamic>{
          'filename': _str(message['filename']),
          'content': _str(message['content']),
        },
      );
    case 'subtitleSearch':
      return _apiReply(
        s,
        FushiExtensionApiCore.subtitleSearchPath,
        <String, dynamic>{
          'query': _str(message['query']),
          if (message['episode'] case final int episode) 'episode': episode,
          if (message['anime'] case final bool anime) 'anime': anime,
        },
      );
    case 'subtitleFetch':
      return _apiReply(
        s,
        FushiExtensionApiCore.subtitleFetchPath,
        <String, dynamic>{'handle': _str(message['handle'])},
      );
    case 'subtitleFonts':
      // 字体列表照给；app 内没有可供页面 @font-face 取字节的地址，覆盖层按字体名用本机已装字体。
      final FushiExtensionApiResponse r = await s.api(
        FushiExtensionApiCore.fontsPath,
        <String, dynamic>{},
      );
      final Map<String, dynamic> json = r.json ?? const <String, dynamic>{};
      return <String, Object?>{
        'ok': r.ok,
        'status': r.status,
        'fonts': json['fonts'] is List<dynamic> ? json['fonts'] : <Object?>[],
        'recommended': json['recommended'] is List<dynamic>
            ? json['recommended']
            : <Object?>[],
      };
    case 'studySample':
      final Object? sample = message['sample'];
      if (sample is! Map<String, dynamic>) {
        return <String, Object?>{'ok': false, 'error': 'no sample'};
      }
      s.onStudySample?.call(sample);
      if (!s.recordStudy) {
        return <String, Object?>{'ok': false, 'error': 'incognito'};
      }
      final FushiExtensionApiResponse r = await s.api(
        FushiExtensionApiCore.studyPath,
        sample,
      );
      return <String, Object?>{'ok': r.ok, 'status': r.status};
    // 反馈 KGC1ifR1a3：网页视频收藏（video-favorite.js）。与扩展 background.js 同形转发。
    case 'videoFavorite':
      return _apiReply(
        s,
        FushiExtensionApiCore.videoFavoritePath,
        <String, dynamic>{
          'op': message['op'] == 'toggle' ? 'toggle' : 'state',
          'kind': message['kind'] == 'video' ? 'video' : 'sentence',
          'url': _str(message['url']),
          'title': _str(message['title']),
          'text': _str(message['text']),
          if (message['startMs'] case final num startMs) 'startMs': startMs,
          if (message['endMs'] case final num endMs) 'endMs': endMs,
        },
      );
    case 'openSubtitleSidePanel':
      s.openSidePanel();
      return <String, Object?>{'ok': true};
    case 'openOptions':
      s.openOptions();
      return <String, Object?>{'ok': true};
    case 'fushiLookupDismiss':
      s.dismissLookup();
      return <String, Object?>{'ok': true};
    // 纯通知 / 诊断：宿主没有对应的东西要做。
    case 'lookupPerf':
    case 'fushiSidePanelLookupGone':
      return <String, Object?>{'ok': true};
    default:
      return kWebBrowserExtensionUnsupported;
  }
}
