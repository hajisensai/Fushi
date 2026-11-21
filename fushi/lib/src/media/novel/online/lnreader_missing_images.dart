import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/novel/online/lnreader_epub_assembler.dart';
import 'package:fushi/src/media/novel/online/online_novel_missing_images.dart';

/// 网文章节里「没取到的插图」的落盘标记。
///
/// 网文书的章节正文写在解压树里（`OEBPS/chapter-<n>.xhtml`）。插图单张取不到时
/// 不把 `<img>` 直接摘掉，而是换成一个**不可见、无文字**的占位 `<span>`，记下
/// 原图地址、本地文件名、alt 和已经试过几次——阅读器据此知道这一章缺几张图，
/// 能补取（[retryChapterMissingImages]），补到了再换回 `<img>`。占位不含文字，
/// 不改变章节字数与阅读位置的坐标系。
///
/// 三条网文管线都写它：LNReader 在线书（边读边取）、LNReader「下载」成的 EPUB、
/// 网页小说书（无界面 WebView + Rust 提取）。占位里还带补取要用的来源（引用页
/// [LnReaderMissingImage.referer]、插件 [LnReaderMissingImage.pluginId]）：下载成的
/// EPUB 书行里没有源站描述符（它的 `sourceMetadata` 是导入时写的系列描述符），
/// 补取全靠占位自带的来源；占位随 EPUB 正文走，备份 / 同步 / 换机后照样能补。
///
/// 标记只由本文件生成、只由本文件解析，属性顺序固定，所以解析用定序正则即可。
/// 来源两项是后加的可选属性：之前写下的占位没有它们，照样解析。
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
    this.referer,
    this.pluginId,
  });

  /// 占位键，也是补到后换回的 `<img src>`（解压树 `OEBPS/` 下的相对文件名）。
  /// 网页小说书取不到时还不知道图片格式，这里是不带扩展名的键，补到后由取图方
  /// 给出真文件名。
  final String fileName;

  /// 原图绝对地址（已解析成 http(s)）。
  final String url;

  /// 原 `<img>` 的 alt（已是 XML 转义后的属性值，原样写回）。
  final String alt;

  /// 已经试过几次（含第一次下载）。
  final int tries;

  /// 取图时带的引用页（章节页地址）。防盗链按引用页判，补取与第一次下载必须
  /// 是同一个。早期写下的占位没有，为 null（由调用方按书的描述符补）。
  final String? referer;

  /// 取图用的 LNReader 插件 id（插件自定的图片请求头）。网页小说书 / 早期占位为
  /// null。
  final String? pluginId;

  /// 还能不能自动补取（[kLnReaderMissingImageAutoRetries]）。
  bool get autoRetryAvailable => tries <= kLnReaderMissingImageAutoRetries;

  LnReaderMissingImage _withTries(int next) => LnReaderMissingImage(
    fileName: fileName,
    url: url,
    alt: alt,
    tries: next,
    referer: referer,
    pluginId: pluginId,
  );
}

final RegExp _markerPattern = RegExp(
  '<span $kLnReaderMissingImageAttribute="([^"]*)" '
  'data-fushi-lnreader-missing-url="([^"]*)" '
  'data-fushi-lnreader-missing-alt="([^"]*)" '
  'data-fushi-lnreader-missing-tries="(\\d+)"'
  '(?: data-fushi-lnreader-missing-referer="([^"]*)")?'
  '(?: data-fushi-lnreader-missing-plugin="([^"]*)")? hidden="hidden"></span>',
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

String? _optionalAttr(String? raw) => raw == null ? null : _unescAttr(raw);

LnReaderMissingImage _imageOf(Match match) => LnReaderMissingImage(
  fileName: _unescAttr(match.group(1)!),
  url: _unescAttr(match.group(2)!),
  alt: match.group(3)!,
  tries: int.parse(match.group(4)!),
  referer: _optionalAttr(match.group(5)),
  pluginId: _optionalAttr(match.group(6)),
);

/// 一张图的占位标记。
String lnReaderMissingImageMarker(LnReaderMissingImage image) {
  final String? referer = image.referer;
  final String? pluginId = image.pluginId;
  return '<span $kLnReaderMissingImageAttribute="${_escAttr(image.fileName)}" '
      'data-fushi-lnreader-missing-url="${_escAttr(image.url)}" '
      'data-fushi-lnreader-missing-alt="${image.alt}" '
      'data-fushi-lnreader-missing-tries="${image.tries}"'
      '${referer == null ? '' : ' data-fushi-lnreader-missing-referer="${_escAttr(referer)}"'}'
      '${pluginId == null ? '' : ' data-fushi-lnreader-missing-plugin="${_escAttr(pluginId)}"'}'
      ' hidden="hidden"></span>';
}

/// 把引用 [src]（缺省 = [fileName]）的 `<img>` 换成占位标记（第一次下载失败时
/// 用，tries = 1）。alt 取原标签上的。没有这样的 `<img>` 时原样返回。
///
/// [fileName] 是占位键，也是补到后换回的 `<img src>`：LNReader 两条管线里它就是
/// 原标签的 src；网页小说书原标签的 src 是提取占位（`fushi-img-<n>`），文件名要
/// 等取到图、知道格式才定，这时传不带扩展名的键，补到后由取图方给出真文件名
/// （[applyLnReaderMissingImageRetry] 的 `recovered`）。[referer] / [pluginId] 是
/// 补取要用的来源，原样记进占位。
String replaceLnReaderImageWithMissingMarker(
  String xhtml, {
  required String fileName,
  required String url,
  String? src,
  String? referer,
  String? pluginId,
}) {
  final String escaped = RegExp.escape(src ?? fileName);
  return xhtml.replaceAllMapped(
    RegExp('<img\\b[^>]*\\ssrc="$escaped"[^>]*/?>', caseSensitive: false),
    (Match match) {
      final String tag = match.group(0)!;
      final String alt =
          RegExp(r'\salt="([^"]*)"').firstMatch(tag)?.group(1) ?? '';
      return lnReaderMissingImageMarker(
        LnReaderMissingImage(
          fileName: fileName,
          url: url,
          alt: alt,
          tries: 1,
          referer: referer,
          pluginId: pluginId,
        ),
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

/// 补取一轮之后改写 [xhtml]：[recovered]（占位键 → 换回的 `<img src>`）里的图
/// 换回 `<img>`，[failed]（占位键）里的图 tries 加一。按占位键认占位，期间文件
/// 被改过、占位已不在的图自然跳过。
String applyLnReaderMissingImageRetry(
  String xhtml, {
  required Map<String, String> recovered,
  required Set<String> failed,
}) => xhtml.replaceAllMapped(_markerPattern, (Match match) {
  final LnReaderMissingImage image = _imageOf(match);
  final String? src = recovered[image.fileName];
  if (src != null) {
    return '<img alt="${image.alt}" src="${_escAttr(src)}"/>';
  }
  if (failed.contains(image.fileName)) {
    return lnReaderMissingImageMarker(image._withTries(image.tries + 1));
  }
  return match.group(0)!;
});

/// 章节文件 [file] 里的缺图占位；文件不在 / 还是待取的占位页（含
/// [pendingAttribute]）时为空。
Future<List<LnReaderMissingImage>> readChapterMissingImages(
  File file, {
  String? pendingAttribute,
}) async {
  if (!await file.exists()) return const <LnReaderMissingImage>[];
  final String xhtml = await file.readAsString();
  if (pendingAttribute != null && xhtml.contains(pendingAttribute)) {
    return const <LnReaderMissingImage>[];
  }
  return parseLnReaderMissingImages(xhtml);
}

/// [missing] 汇总成阅读器要的「缺几张、还能不能自动补取」。
OnlineNovelMissingImages summarizeChapterMissingImages(
  int index,
  List<LnReaderMissingImage> missing,
) => OnlineNovelMissingImages(
  index: index,
  count: missing.length,
  autoRetryAvailable: missing.any(
    (LnReaderMissingImage image) => image.autoRetryAvailable,
  ),
);

/// 补取排队：同一本书的几轮补取（自动 + 手动、不同章）串行，不并发读改写同一个
/// 章节文件，也不同时对图床发一堆请求。
class MissingImagesRetryQueue {
  Future<void> _chain = Future<void>.value();

  /// 排在前面的几轮结束（成败不论）后再跑 [task]。
  Future<T> run<T>(Future<T> Function() task) {
    final Future<T> result = _chain.then((_) => task());
    _chain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

/// 取一张缺图：取不到返回 null，原因交给 [onFailure]；补到的图文件名可以与占位
/// 键不同（网页小说书按格式定扩展名）。抛出 = 整轮取不了（插件没装 / 运行时起
/// 不来）。
typedef MissingImageFetch =
    Future<LnReaderEpubImage?> Function(
      LnReaderMissingImage image,
      void Function(String reason) onFailure,
    );

/// 三条网文管线共用的「补取一章缺图」一轮：读占位 → 逐张取图 → 图写回解压树 →
/// 章节文件里换回 `<img>` / 记次。
///
/// - [automatic]：打开章节时的自动补取，只试还没用尽自动次数的图；手动试全部。
/// - [prepare]：确实有图要取时、第一次 [fetch] 之前 await 一次（拉起插件运行时、
///   找插件；没东西可取时不拉起）。抛出向上抛，文件不动。
/// - [stillValid]：取图要等网络，回来后第 [index] 章是否还是这一章（解压树可能
///   已被就地重建）；false 就放弃这次结果。
/// - [write]：原子写（先写临时文件再改名），阅读器读到的要么旧要么新。
/// - [onStillMissing]：这一轮有图没补到（失败张数、试了几张、第一个原因），留痕用。
Future<OnlineNovelMissingImagesRetry> retryChapterMissingImages({
  required int index,
  required String extractDir,
  required File file,
  required bool automatic,
  required MissingImageFetch fetch,
  required Future<void> Function(File target, List<int> bytes) write,
  String? pendingAttribute,
  Future<void> Function()? prepare,
  Future<bool> Function()? stillValid,
  void Function(int failed, int attempted, String? firstFailure)?
  onStillMissing,
}) async {
  final List<LnReaderMissingImage> missing = await readChapterMissingImages(
    file,
    pendingAttribute: pendingAttribute,
  );
  final List<LnReaderMissingImage> targets = <LnReaderMissingImage>[
    for (final LnReaderMissingImage image in missing)
      if (!automatic || image.autoRetryAvailable) image,
  ];
  OnlineNovelMissingImagesRetry unchanged() => OnlineNovelMissingImagesRetry(
    index: index,
    recovered: 0,
    remaining: missing.length,
  );
  if (targets.isEmpty) return unchanged();
  await prepare?.call();
  final Map<String, LnReaderEpubImage> recovered =
      <String, LnReaderEpubImage>{};
  final Set<String> failed = <String>{};
  String? firstFailure;
  for (final LnReaderMissingImage image in targets) {
    final LnReaderEpubImage? fetched = await fetch(
      image,
      (String reason) => firstFailure ??= reason,
    );
    if (fetched == null) {
      failed.add(image.fileName);
    } else {
      recovered[image.fileName] = fetched;
    }
  }
  if (!await file.exists() || !(await stillValid?.call() ?? true)) {
    return unchanged();
  }
  for (final LnReaderEpubImage image in recovered.values) {
    await write(File(p.join(extractDir, 'OEBPS', image.fileName)), image.bytes);
  }
  // 重读再改：按占位键认占位，期间文件若被改过，对不上的占位自然跳过。
  final String updated = applyLnReaderMissingImageRetry(
    await file.readAsString(),
    recovered: <String, String>{
      for (final MapEntry<String, LnReaderEpubImage> entry in recovered.entries)
        entry.key: entry.value.fileName,
    },
    failed: failed,
  );
  await write(file, utf8.encode(updated));
  if (failed.isNotEmpty) {
    onStillMissing?.call(failed.length, targets.length, firstFailure);
  }
  return OnlineNovelMissingImagesRetry(
    index: index,
    recovered: recovered.length,
    remaining: parseLnReaderMissingImages(updated).length,
  );
}
