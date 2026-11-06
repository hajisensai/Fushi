import 'package:flutter/foundation.dart';

/// 扫图脚本回传的一张图。
@immutable
class WebComicScannedImage {
  const WebComicScannedImage({required this.url, this.width, this.height});

  final String url;

  /// 原图尺寸（`naturalWidth/Height`）；未知（API / 全局变量取图、图还没加载）为 null。
  final int? width;
  final int? height;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    if (width != null) 'w': width,
    if (height != null) 'h': height,
  };

  static WebComicScannedImage? fromJson(Object? json) {
    if (json is String) return WebComicScannedImage(url: json);
    if (json is! Map) return null;
    final String url = json['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    return WebComicScannedImage(
      url: url,
      width: _positiveInt(json['w'] ?? json['width']),
      height: _positiveInt(json['h'] ?? json['height']),
    );
  }
}

/// 一次扫图的结果（已归一化：绝对 URL、去重保序、按阈值筛过）。
@immutable
class WebComicScanResult {
  const WebComicScanResult({
    required this.pageUrl,
    required this.title,
    required this.images,
    this.nextChapterUrl,
    this.prevChapterUrl,
    this.ruleId,
    this.userAgent,
  });

  final Uri pageUrl;
  final String title;
  final List<WebComicScannedImage> images;
  final Uri? nextChapterUrl;
  final Uri? prevChapterUrl;

  /// 命中的站点规则；null = 通用扫图。
  final String? ruleId;

  /// 扫图那张 WebView 的 `navigator.userAgent`，取图时原样带上（不少站按 UA 拦）。
  final String? userAgent;

  bool get isEmpty => images.isEmpty;
}

/// 扫图阈值（与脚本里的默认值同一组数，脚本负责显示尺寸，Dart 再按原图尺寸
/// 兜一遍——脚本跑在不可信页面里，回传值不能直接当真）。
@immutable
class WebComicScanThresholds {
  const WebComicScanThresholds({this.minNaturalSide = 500});

  /// 原图长边的下限：小于它的是图标 / 头像 / 按钮，不是漫画页。
  final int minNaturalSide;
}

/// 把脚本回传的原始 map 归一化成 [WebComicScanResult]；形状不对返回 null。
///
/// - 相对 URL 按 [base] 解析：脚本报的 `pageUrl` 只在与 [fallbackPageUrl]（WebView 自己的
///   当前地址）同一主机时采信，否则用 [fallbackPageUrl]——页面脚本完全受站点控制，报一个别的
///   站的地址就能让取图带上那个站的 cookie、把章节并进别的作品；
/// - 只留 http(s)（`data:` / `blob:` 取不回字节）；
/// - 按绝对 URL 去重、保留首次出现的顺序；
/// - 报了原图尺寸且长边小于阈值的丢掉，没报尺寸的保留（API / 规则取图本来就没有）。
WebComicScanResult? normalizeWebComicScan(
  Object? raw, {
  required Uri fallbackPageUrl,
  WebComicScanThresholds thresholds = const WebComicScanThresholds(),
}) {
  if (raw is! Map) return null;
  final Uri? reported = _httpUri(raw['pageUrl']?.toString());
  final Uri base =
      reported != null &&
          reported.host.toLowerCase() == fallbackPageUrl.host.toLowerCase()
      ? reported
      : fallbackPageUrl;
  final Object? rawImages = raw['images'];
  final List<WebComicScannedImage> images = <WebComicScannedImage>[];
  final Set<String> seen = <String>{};
  if (rawImages is List) {
    for (final Object? item in rawImages) {
      final WebComicScannedImage? image = WebComicScannedImage.fromJson(item);
      if (image == null) continue;
      final Uri? resolved = resolveWebComicUrl(base, image.url);
      if (resolved == null) continue;
      final int? w = image.width;
      final int? h = image.height;
      if (w != null && h != null) {
        final int longSide = w > h ? w : h;
        if (longSide < thresholds.minNaturalSide) continue;
      }
      final String key = resolved.toString();
      if (!seen.add(key)) continue;
      images.add(WebComicScannedImage(url: key, width: w, height: h));
    }
  }
  final String title = (raw['title']?.toString() ?? '').trim();
  return WebComicScanResult(
    pageUrl: base.removeFragment(),
    title: title.isEmpty ? base.host : title,
    images: List<WebComicScannedImage>.unmodifiable(images),
    nextChapterUrl: _chapterLink(base, raw['nextChapterUrl']),
    prevChapterUrl: _chapterLink(base, raw['prevChapterUrl']),
    ruleId: _nonEmpty(raw['ruleId']),
    userAgent: _nonEmpty(raw['userAgent']),
  );
}

/// [value] 相对 [base] 解析成 http(s) 绝对地址（去掉 fragment）；不是 http(s) 返回 null。
Uri? resolveWebComicUrl(Uri base, String value) {
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final Uri? parsed = Uri.tryParse(trimmed);
  if (parsed == null) return null;
  final Uri resolved;
  try {
    resolved = base.resolveUri(parsed);
  } on FormatException {
    return null;
  }
  if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
  if (resolved.host.isEmpty) return null;
  return resolved.removeFragment();
}

/// 上下章链接：必须是 http(s)，且不能就是本页（脚本的文案匹配可能撞上 `#`）。
Uri? _chapterLink(Uri base, Object? value) {
  final String? text = _nonEmpty(value);
  if (text == null) return null;
  final Uri? resolved = resolveWebComicUrl(base, text);
  if (resolved == null) return null;
  if (resolved.toString() == base.removeFragment().toString()) return null;
  return resolved;
}

Uri? _httpUri(String? value) {
  if (value == null || value.isEmpty) return null;
  final Uri? uri = Uri.tryParse(value);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return uri;
}

String? _nonEmpty(Object? value) {
  final String? text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

int? _positiveInt(Object? value) {
  final int? parsed = value is num ? value.toInt() : int.tryParse('$value');
  return parsed == null || parsed <= 0 ? null : parsed;
}
