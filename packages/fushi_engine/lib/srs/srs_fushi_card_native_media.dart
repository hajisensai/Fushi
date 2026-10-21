/// 「Fushi 卡片」的媒体字段能不能交给复习页的**原生**卡面画（见
/// `SrsRenderedCard.fushiCardDefinitions` 与 app 侧 `srs_fushi_card_view.dart`）。
///
/// 原生卡面认得制卡链路写出的全部媒体形态：Picture 里的 `<img src>`（栅格图片、GIF / WebP
/// 动图、AVIF 静图与动图）、视频片段（WebM `<video>` / MP4 `[sound:]`，原生片段播放器），
/// 音频字段里的 `[sound:]` 与内嵌重播按钮 + `<audio src>`。只有原生确实画不出来的形态才留在
/// 整面 WebView（与 Anki 同一份 Fushi 卡片模板）：
///
/// - SVG / 远程 URL 的 `<img>`；
/// - Picture 里图片、片段之外的其它内容（文字、按钮、非视频的 `[sound:]`）；
/// - 音频字段里的 `<video>` / `<iframe>` 等嵌入元素。
///
/// 判据是「原生能不能把这些字段**原样**画全」，不是挑卡型：画得全就原生，画不全就整面
/// WebView，两边用的是同一份模板设计。
library;

/// 原生卡面直接画的图片字段。
const String kSrsFushiNativePictureField = 'Picture';

/// 原生卡面按 `[sound:]` 出播放按钮的音频字段。
const List<String> kSrsFushiNativeAudioFields = <String>[
  'ExpressionAudio',
  'SentenceAudio',
];

final RegExp _img = RegExp(r'<img\b[^>]*>', caseSensitive: false);
final RegExp _imgSrc = RegExp(
  r'''\ssrc\s*=\s*(["'])([^"']*)\1''',
  caseSensitive: false,
);

/// 不带内容的排版包装（`<div><img></div>`、`<br>`）：去掉后不影响「只有图片」的判断。
final RegExp _wrapperTag = RegExp(
  r'</?(?:div|span|p|br|figure)\b[^>]*>',
  caseSensitive: false,
);
final RegExp _nbsp = RegExp(r'&nbsp;|&#160;| ', caseSensitive: false);

/// 音频字段里原生卡面认不了的元素。制卡内嵌的重播按钮 + `<audio src>` 原生认得
/// （app 侧 `srsAudioSources` 出按钮、`srsCardMediaNames` 排进自动播放）。
final RegExp _foreignAudioElement = RegExp(
  r'<(?:video|object|embed|iframe)\b',
  caseSensitive: false,
);

/// Picture 里的视频片段：WebM 内嵌 `<video …></video>`（原生 `SrsCardVideoClip` 播）。
final RegExp _videoElement = RegExp(
  r'<video\b[^>]*>(?:\s*<source\b[^>]*>)*\s*(?:</video>)?',
  caseSensitive: false,
);

/// Picture 里的 MP4 片段：`[sound:x.mp4]`（Anki 惯例），原生同样当视频片段播。
final RegExp _videoSound = RegExp(
  r'\[sound:[^\]]+\.(?:webm|mp4|m4v|mov|mkv)\]',
  caseSensitive: false,
);

final RegExp _schemePrefix = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:');

String _unescapeAttr(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

/// `<img src>` 的值原生能不能画：栅格 `data:image/...` 与媒体库裸文件名可以；
/// SVG（原生不渲染）与远程 / 其它 scheme 不行。
bool _nativeImageSource(String src) {
  final String s = src.trim();
  if (s.isEmpty) return false;
  final String lower = s.toLowerCase();
  if (lower.startsWith('data:')) {
    return lower.startsWith('data:image/') &&
        !lower.startsWith('data:image/svg');
  }
  if (_schemePrefix.hasMatch(s) || s.startsWith('/')) return false;
  return !lower.endsWith('.svg');
}

/// [fields]（按字段名，已展开）里的媒体原生卡面能否原样画全（见文件头）。
bool srsFushiCardMediaIsNative(Map<String, String> fields) {
  for (final String name in kSrsFushiNativeAudioFields) {
    final String? value = fields[name];
    if (value != null && _foreignAudioElement.hasMatch(value)) return false;
  }
  final String picture = (fields[kSrsFushiNativePictureField] ?? '')
      .replaceAll(_videoElement, '')
      .replaceAll(_videoSound, '');
  final List<String> sources = <String>[];
  for (final Match m in _img.allMatches(picture)) {
    final Match? src = _imgSrc.firstMatch(m.group(0)!);
    if (src == null) return false;
    sources.add(_unescapeAttr(src.group(2)!));
  }
  final String rest = picture
      .replaceAll(_img, '')
      .replaceAll(_wrapperTag, '')
      .replaceAll(_nbsp, '')
      .trim();
  if (rest.isNotEmpty) return false;
  for (final String src in sources) {
    if (!_nativeImageSource(src)) return false;
  }
  return true;
}
