/// 卡面里的媒体引用改写：Anki 字段里的 `<img src="x.png">` / `<video src>` / CSS
/// `url(x)` 是相对媒体库的裸文件名，`[sound:x.mp3]` 是 Anki 的声音标记。WebView
/// 拿不到「媒体库」这个概念，这里把它们换成：
///
/// - 裸文件名 → 卡面专属虚拟域上的绝对 URL（[srsMediaUrlPrefix]），由卡面 WebView 的
///   拦截器从 `SrsMediaStore` 供字节（Android / Windows 拦 `https://srs.local/`，
///   iOS / macOS / Linux 走自定义 scheme `fushi-srs://`，与漫画 / 阅读器同一套判据）；
/// - `[sound:x]` → 一个播放按钮，点了经 JS 桥交给 Dart 播放（复用 app 的音频播放器）。
///
/// 纯函数，不依赖 Flutter，单测直接调。
library;

import 'package:fushi_core/fushi_core.dart' show mimeTypeForFilePath;

/// 卡面媒体的虚拟域。必须与阅读器 `fushi.local`、漫画 `manga.local` 互异。
const String kSrsMediaHost = 'srs.local';

/// 自定义 scheme 平台（iOS / macOS / Linux）上的卡面媒体 scheme。
const String kSrsMediaScheme = 'fushi-srs';

/// 媒体路径前缀。
const String kSrsMediaPath = '/media/';

/// 卡面 JS 桥：播放 `[sound:]` 的 handler 名。
const String kSrsPlaySoundHandler = 'onSrsPlaySound';

/// 卡面媒体 URL 前缀（[customScheme] = 本平台走自定义 scheme）。
String srsMediaUrlPrefix({required bool customScheme}) => customScheme
    ? '$kSrsMediaScheme://$kSrsMediaHost$kSrsMediaPath'
    : 'https://$kSrsMediaHost$kSrsMediaPath';

final RegExp _soundTag = RegExp(r'\[sound:([^\]]+)\]');
final RegExp _srcAttr = RegExp(
  r'''(\s(?:src|poster)\s*=\s*)(["'])([^"']*)\2''',
  caseSensitive: false,
);
final RegExp _cssUrl = RegExp(
  r'''url\(\s*(["']?)([^"')]+)\1\s*\)''',
  caseSensitive: false,
);
final RegExp _schemePrefix = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:');

/// 把 HTML 属性 / 文本里常见的实体还原（Anki 字段把文件名里的 `&` 存成 `&amp;`）。
String _htmlUnescape(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

String _attrEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// 是不是「媒体库里的裸文件名」：不带 scheme、不以 `/` `#` 开头、不含路径分隔符。
bool srsIsBareMediaName(String raw) {
  final String s = raw.trim();
  if (s.isEmpty) return false;
  if (s.startsWith('/') || s.startsWith('#') || s.startsWith('.')) return false;
  if (_schemePrefix.hasMatch(s)) return false;
  if (s.contains('/') || s.contains(r'\')) return false;
  return true;
}

String _mediaUrl(String prefix, String rawName) =>
    '$prefix${Uri.encodeComponent(_htmlUnescape(rawName.trim()))}';

/// `[sound:x]` 渲染成的播放按钮（内联 SVG 三角，样式见 [kSrsCardMediaCss]）。
String srsSoundButtonHtml(String name) {
  final String n = _attrEscape(_htmlUnescape(name.trim()));
  return '<button type="button" class="fushi-srs-sound" data-sound="$n" '
      'aria-label="$n">'
      '<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true">'
      '<path d="M8 5v14l11-7z" fill="currentColor"/></svg></button>';
}

/// 卡面正文的媒体改写（见文件头）。
String srsLocalizeCardHtml(String html, {required String urlPrefix}) {
  String out = html.replaceAllMapped(
    _soundTag,
    (Match m) => srsSoundButtonHtml(m.group(1)!),
  );
  out = out.replaceAllMapped(_srcAttr, (Match m) {
    final String value = m.group(3)!;
    if (!srsIsBareMediaName(value)) return m.group(0)!;
    return '${m.group(1)}${m.group(2)}'
        '${_attrEscape(_mediaUrl(urlPrefix, value))}${m.group(2)}';
  });
  return srsLocalizeCardCss(out, urlPrefix: urlPrefix);
}

/// 卡片 CSS 里 `url(_font.woff2)` 这类媒体库引用的改写。
String srsLocalizeCardCss(String css, {required String urlPrefix}) =>
    css.replaceAllMapped(_cssUrl, (Match m) {
      final String value = m.group(2)!;
      if (!srsIsBareMediaName(value)) return m.group(0)!;
      return 'url("${_mediaUrl(urlPrefix, value)}")';
    });

/// [text]（卡面正文 / CSS / 字段值）引用的媒体库文件名：`[sound:]`、`src` / `poster`、CSS `url()`
/// 里的裸文件名，与 [srsLocalizeCardHtml] 改写的是同一批（远程刷卡据此先把媒体拉进缓存）。
Set<String> srsCardReferencedMedia(String text) {
  final Set<String> names = <String>{};
  void add(String raw) {
    if (srsIsBareMediaName(raw)) names.add(_htmlUnescape(raw.trim()));
  }

  for (final Match m in _soundTag.allMatches(text)) {
    add(m.group(1)!);
  }
  for (final Match m in _srcAttr.allMatches(text)) {
    add(m.group(3)!);
  }
  for (final Match m in _cssUrl.allMatches(text)) {
    add(m.group(2)!);
  }
  return names;
}

/// 拦截到的 URL 是不是卡面媒体请求；是则返回解码后的文件名，否则 null。
String? srsMediaNameFromUrl(Uri url) {
  if (url.host != kSrsMediaHost) return null;
  if (url.scheme != 'https' && url.scheme != kSrsMediaScheme) return null;
  final String path = url.path;
  if (!path.startsWith(kSrsMediaPath)) return null;
  final String rest = path.substring(kSrsMediaPath.length);
  if (rest.isEmpty) return null;
  try {
    return Uri.decodeComponent(rest);
  } on ArgumentError {
    return null;
  }
}

/// 媒体文件的 Content-Type。
String srsMediaMimeType(String name) =>
    mimeTypeForFilePath(name, fallback: 'application/octet-stream');

/// 播放按钮的样式与点击委托（随卡面 HTML 一起注入；`--fushi-srs-accent` 由宿主给）。
const String kSrsCardMediaCss = '''
.fushi-srs-sound{display:inline-flex;align-items:center;justify-content:center;
width:32px;height:32px;margin:0 4px;padding:0;border:none;border-radius:16px;
vertical-align:middle;cursor:pointer;color:var(--fushi-srs-on-accent,#fff);
background:var(--fushi-srs-accent,#6750a4);}
.fushi-srs-sound:active{opacity:.7;}
''';

/// 播放按钮的点击委托（捕获阶段，不受卡片自己的脚本影响）。
///
/// 卡片模板脚本在手势之外合成的 `.click()`（`isTrusted` 为 false，例如模板在显示时把
/// 每颗音频按钮挨个点一遍来「自动播放」）在牌组关了自动播放时一律不放行——闸门
/// `window.__fushiSrsMediaBlocked` 由 srs_card_autoplay.dart 的自动播放闸门脚本定义；
/// 同一次用户点按里转手的合成点击（Lapis「点例句重播」）仍在手势窗口内，照常播放（#15）。
const String kSrsCardMediaScript =
    '''
(function(){
  if (window.__fushiSrsSound) return;
  window.__fushiSrsSound = true;
  document.addEventListener('click', function(e){
    var t = e.target;
    var b = t && t.closest ? t.closest('[data-sound]') : null;
    if (!b) return;
    e.preventDefault();
    e.stopPropagation();
    if (e.isTrusted !== true && typeof window.__fushiSrsMediaBlocked === 'function' &&
        window.__fushiSrsMediaBlocked()) return;
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('$kSrsPlaySoundHandler', b.getAttribute('data-sound'));
    }
  }, true);
})();
''';
