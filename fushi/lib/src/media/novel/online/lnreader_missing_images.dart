import 'package:meta/meta.dart';

/// 在线书章节里「没取到的插图」的落盘标记。
///
/// 在线书的章节正文写在解压树里（`OEBPS/chapter-<n>.xhtml`）。插图单张取不到时
/// 不再把 `<img>` 直接摘掉，而是换成一个**不可见、无文字**的占位 `<span>`，记下
/// 原图地址、本地文件名、alt 和已经试过几次——阅读器据此知道这一章缺几张图，
/// 能补取（`LnReaderOnlineChapterLoader.retryMissingImages`），补到了再换回
/// `<img>`。占位不含文字，不改变章节字数与阅读位置的坐标系。
///
/// 已下载成 EPUB 的书（`LnReaderBookDownload.run`）不写占位：那本书和源站已无
/// 关联、补不了，照旧摘掉断链。
///
/// 标记只由本文件生成、只由本文件解析，属性顺序固定，所以解析用定序正则即可。
const String kLnReaderMissingImageAttribute =
    'data-fushi-lnreader-missing-file';

/// 打开章节时自动补取每张图最多试几次（不含第一次下载）。维护者拍板「重试一两
/// 三次就行」：次数记在占位里随文件持久化，坏图床不会每开一次书就再被打一轮；
/// 用尽后只剩用户手动「重新获取」。
const int kLnReaderMissingImageAutoRetries = 3;

/// 一张没取到的插图。
@immutable
class LnReaderMissingImage {
  const LnReaderMissingImage({
    required this.fileName,
    required this.url,
    required this.alt,
    required this.tries,
  });

  /// 解压树 `OEBPS/` 下的相对文件名（`images/<前缀><n>.<ext>`）。
  final String fileName;

  /// 原图绝对地址（插件给出的，已解析成 http(s)）。
  final String url;

  /// 原 `<img>` 的 alt（已是 XML 转义后的属性值，原样写回）。
  final String alt;

  /// 已经试过几次（含第一次下载）。
  final int tries;

  /// 还能不能自动补取（[kLnReaderMissingImageAutoRetries]）。
  bool get autoRetryAvailable => tries <= kLnReaderMissingImageAutoRetries;
}

final RegExp _markerPattern = RegExp(
  '<span $kLnReaderMissingImageAttribute="([^"]*)" '
  'data-fushi-lnreader-missing-url="([^"]*)" '
  'data-fushi-lnreader-missing-alt="([^"]*)" '
  'data-fushi-lnreader-missing-tries="(\\d+)" hidden="hidden"></span>',
);

String _escAttr(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _unescAttr(String value) => value
    .replaceAll('&quot;', '"')
    .replaceAll('&gt;', '>')
    .replaceAll('&lt;', '<')
    .replaceAll('&amp;', '&');

LnReaderMissingImage _imageOf(Match match) => LnReaderMissingImage(
  fileName: _unescAttr(match.group(1)!),
  url: _unescAttr(match.group(2)!),
  alt: match.group(3)!,
  tries: int.parse(match.group(4)!),
);

/// 一张图的占位标记。
String lnReaderMissingImageMarker(LnReaderMissingImage image) =>
    '<span $kLnReaderMissingImageAttribute="${_escAttr(image.fileName)}" '
    'data-fushi-lnreader-missing-url="${_escAttr(image.url)}" '
    'data-fushi-lnreader-missing-alt="${image.alt}" '
    'data-fushi-lnreader-missing-tries="${image.tries}" hidden="hidden"></span>';

/// 把引用 [fileName] 的 `<img>` 换成占位标记（第一次下载失败时用，tries = 1）。
/// alt 取原标签上的。没有这样的 `<img>` 时原样返回。
String replaceLnReaderImageWithMissingMarker(
  String xhtml, {
  required String fileName,
  required String url,
}) {
  final String escaped = RegExp.escape(fileName);
  return xhtml.replaceAllMapped(
    RegExp('<img\\b[^>]*\\ssrc="$escaped"[^>]*/?>', caseSensitive: false),
    (Match match) {
      final String tag = match.group(0)!;
      final String alt =
          RegExp(r'\salt="([^"]*)"').firstMatch(tag)?.group(1) ?? '';
      return lnReaderMissingImageMarker(
        LnReaderMissingImage(fileName: fileName, url: url, alt: alt, tries: 1),
      );
    },
  );
}

/// [xhtml] 里所有没取到的插图（文档序）。
List<LnReaderMissingImage> parseLnReaderMissingImages(String xhtml) {
  if (!xhtml.contains(kLnReaderMissingImageAttribute)) {
    return const <LnReaderMissingImage>[];
  }
  return <LnReaderMissingImage>[
    for (final RegExpMatch match in _markerPattern.allMatches(xhtml))
      _imageOf(match),
  ];
}

/// 补取一轮之后改写 [xhtml]：[recovered] 里的图换回 `<img>`，[failed] 里的图
/// tries 加一。按文件名认占位，期间文件被改过、占位已不在的图自然跳过。
String applyLnReaderMissingImageRetry(
  String xhtml, {
  required Set<String> recovered,
  required Set<String> failed,
}) => xhtml.replaceAllMapped(_markerPattern, (Match match) {
  final LnReaderMissingImage image = _imageOf(match);
  if (recovered.contains(image.fileName)) {
    return '<img alt="${image.alt}" src="${_escAttr(image.fileName)}"/>';
  }
  if (failed.contains(image.fileName)) {
    return lnReaderMissingImageMarker(
      LnReaderMissingImage(
        fileName: image.fileName,
        url: image.url,
        alt: image.alt,
        tries: image.tries + 1,
      ),
    );
  }
  return match.group(0)!;
});
