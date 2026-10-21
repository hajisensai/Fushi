/// 「Fushi 卡片」的媒体字段能不能交给复习页的**原生**卡面画（见
/// `SrsRenderedCard.fushiCardDefinitions` 与 app 侧 `srs_fushi_card_view.dart`）。
///
/// 原生卡面只认两种媒体写法：图片字段（Picture）里的 `<img src>`（Flutter 图片解码器，
/// PNG / JPEG / GIF 动图 / WebP 动图 / 静态 AVIF），音频字段（ExpressionAudio /
/// SentenceAudio）里的 `[sound:]`。制卡链路还会写出另外几种形态，原生画不出来、会被**静默
/// 丢掉**——这些卡必须留在整面 WebView（与 Anki 同一份 Fushi 卡片模板，Chromium 内核什么都
/// 认）：
///
/// - 视频片段（默认的视频制卡模式）：Picture 是 `<video class="fushi-inline-video">`（WebM）
///   或重播按钮（MP4），句子 / 单词音频是重播按钮 + 页内 `<audio>`，没有 `[sound:]`；
/// - 动图 AVIF（`ftyp` 品牌 `avis`）：Flutter 的解码器只解出静态主图（实测 frameCount == 1），
///   动图在原生卡面上变成一张截图；
/// - SVG / 远程 URL 的 `<img>`、Picture 里的其它内容（文字、按钮、`[sound:]`）。
///
/// 判据是「原生能不能把这些字段**原样**画全」，不是挑卡型：画得全就原生，画不全就整面
/// WebView，两边用的是同一份模板设计。
library;

/// 媒体库里的文件 [mediaName]（裸文件名）原生图片解码器能否完整显示（动图 AVIF → false）。
/// 读不到文件时返回 true：缺文件两边都画不出来，不为此换渲染器。
typedef SrsNativeImageProbe = Future<bool> Function(String mediaName);

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

/// 原生音频按钮之外的页内媒体元素（视频片段卡的重播按钮 + `<audio>`）。
final RegExp _inlineMediaElement = RegExp(
  r'<(?:audio|video|source|button|object|embed|iframe)\b',
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
/// [nativeImage] 为 null 时不探测文件（动图 AVIF 无法识别，按可画处理）。
Future<bool> srsFushiCardMediaIsNative(
  Map<String, String> fields, {
  SrsNativeImageProbe? nativeImage,
}) async {
  for (final String name in kSrsFushiNativeAudioFields) {
    final String? value = fields[name];
    if (value != null && _inlineMediaElement.hasMatch(value)) return false;
  }
  final String picture = fields[kSrsFushiNativePictureField] ?? '';
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
    if (nativeImage != null &&
        !src.toLowerCase().startsWith('data:') &&
        !await nativeImage(src.trim())) {
      return false;
    }
  }
  return true;
}

/// 文件头是不是 AVIF **图像序列**（动图）：ISO BMFF 的首个 `ftyp` box，主品牌或兼容品牌
/// 含 `avis`。静态 AVIF（只有 `avif` / `mif1`）返回 false。[head] 取文件开头若干字节即可
/// （`ftyp` 总在最前；64 字节足够覆盖常见的品牌列表）。
bool srsIsAnimatedAvifHeader(List<int> head) {
  if (head.length < 16) return false;
  final int size = (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
  if (String.fromCharCodes(head.sublist(4, 8)) != 'ftyp') return false;
  final int end = (size < 16 || size > head.length) ? head.length : size;
  bool isAvis(int at) =>
      at + 4 <= end && String.fromCharCodes(head.sublist(at, at + 4)) == 'avis';
  // 主品牌（8..12），跳过 minor_version（12..16），其后每 4 字节一个兼容品牌。
  if (isAvis(8)) return true;
  for (int at = 16; at + 4 <= end; at += 4) {
    if (isAvis(at)) return true;
  }
  return false;
}
