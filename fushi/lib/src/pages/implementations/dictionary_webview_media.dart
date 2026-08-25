import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi/src/dictionary/dictionary_media_types.dart';
import 'package:fushi/src/epub/epub_book.dart' show fallbackMimeType;
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show isValidFontData;
import 'package:path/path.dart' as p;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

const List<String> dictionaryMediaCustomSchemes = <String>[
  'image',
  'dictmedia',
];

/// in-app 查词弹窗给导入词典字体用的虚拟 URL 前缀。
///
/// 为什么字体不能再走 `data:` 内联：内联把字体塞进了「每次渲染都要重新注入的那段
/// 脚本」。两个 CJK 字体（8.3 MB + 17 MB）base64 之后是三十多 MB，而 in-app 弹窗
/// **每嵌套一层就新建一个 WebView**（新 JS realm，window.* 全空，静态段必须重发）
/// ——于是「在弹窗里点词」每点一次就重新序列化、跨平台通道、重新解析这三十多 MB。
/// 这正是用户报的「查词弹窗慢的逆天，特别是嵌套查词开始」。
///
/// 换成 URL 之后，字节由下面的拦截器按需供，而且**跨 WebView 共享 HTTP 缓存**
/// （`data:` URL 每次都是一个全新资源，永远共享不了）。
///
/// host 沿用阅读器那套 `fushi.local`（与阅读器 WebView 各自拦截，互不干扰），
/// 路径段是 URI 编码后的绝对路径。
const String kDictionaryFontUrlPrefix = 'https://fushi.local/dictfonts/';

/// in-app 查词弹窗能不能用 URL 投递字体，取决于该平台有没有**能带 CORS 头**的资源
/// 拦截器。字体是强制 CORS 模式的子资源，而弹窗文档与 `fushi.local` 从来不同源
/// （Android 是 `file://`，Windows 是 `initialData` 的 opaque origin），拿不到
/// `Access-Control-Allow-Origin` 就会被静默拒绝——表现为「字体没生效」，比慢更糟。
///
///   - Android：`useShouldInterceptRequest: true` 让所有请求进 Dart，
///     `WebResourceResponse` 支持 headers。✅（阅读器的 `fushi.local/fonts/` 已在
///     生产用同一套机制跑了很久）
///   - Windows：fork 的 `WebResourceRequested` 对 file/http/https 恒触发，并把
///     `shouldInterceptRequest` 的响应连同 headers 灌回去。✅
///   - iOS / macOS：**没有** `shouldInterceptRequest`，只有 `WKURLSchemeHandler`，
///     而它构造的 `URLResponse` 带不了任何 header。❌ 这两个平台继续内联 `data:`
///     URL——不是偷懒，是平台能力边界；要绕开只能把 popup 文档本身改成从自定义
///     scheme 加载以取得同源，那是另一个量级的改动。
bool get kInAppPopupFontUrlSupported =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.windows;

/// 把通过白名单校验的绝对字体路径编成 [kDictionaryFontUrlPrefix] 下的 URL。
///
/// URL 末尾带 `?v=<mtimeUs>-<size>` 内容版本戳。**不是装饰**：内联路径的缓存键本来
/// 就是 `(path, mtime, size)`（见 DictionaryFontCss 的 _dataUrlCache，注释写明「文件
/// 被原地覆盖时 mtime/size 变化自动失效」）。换成 URL 之后，如果 URL 只含路径，用户
/// 用同名文件覆盖导入的字体后产出的 URL 一字不变，而响应带着 `max-age`——浏览器可能
/// 在缓存期内继续用旧字节。那是相对内联模式的**行为倒退**。版本戳让覆盖后的 URL 天然
/// 变成一条新资源。stat 失败时退化成不带版本（仍可用，只是失去自动失效）。
String dictionaryFontUrl(String safePath) {
  String version = '';
  try {
    final FileStat stat = FileStat.statSync(safePath);
    if (stat.type != FileSystemEntityType.notFound) {
      version = '?v=${stat.modified.microsecondsSinceEpoch}-${stat.size}';
    }
  } catch (_) {
    // 拿不到版本不影响可用性，只是少了自动失效。
  }
  return '$kDictionaryFontUrlPrefix${Uri.encodeComponent(safePath)}$version';
}

/// 这条 URL 是否是字体请求。
///
/// 拦截器闭包必须先用它做**廉价前缀判定**，再去构造白名单实参——`shouldInterceptRequest`
/// 接住的是 WebView 的每一条子资源请求，把白名单当实参写在调用处会让它们在前缀判定
/// 之前就被求值（其中一个要全量 decode 两串 JSON）。
bool isDictionaryFontUrl(Uri url) =>
    url.toString().startsWith(kDictionaryFontUrlPrefix);

/// 服务 [kDictionaryFontUrlPrefix] 下的字体请求；不是字体 URL 时返回 null（交回
/// 其它拦截分支）。
///
/// 三道校验照抄阅读器 `/fonts/` 那条已在生产跑了很久的路径，一道都不少：
///   ① 路径必须落在 [allowedRoots]（`safeCustomFontPath` 做规范化 + 前缀比对，
///      挡 `..` 逃逸）；
///   ② 路径必须在**当前配置的字体白名单**里——光有目录白名单不够，
///      那样任何能影响注入 CSS 的人都能读走该目录下的任意文件；
///   ③ 字节必须通过字体魔数校验，避免把任意文件当字体吐出去。
/// 另外必须带 `Access-Control-Allow-Origin`：字体是强制 CORS 模式的子资源，而弹窗
/// 文档在 Android 是 `file://`、在 Windows 是 opaque origin，都与 `fushi.local`
/// 不同源，没有这个头字体会被静默拒绝（表现为「字体没生效」而不是报错）。
Future<WebResourceResponse?> dictionaryFontWebResourceResponse(
  Uri url, {
  required Iterable<String> allowedRoots,
  required Set<String> whitelistedPaths,
}) async {
  final String full = url.toString();
  if (!full.startsWith(kDictionaryFontUrlPrefix)) return null;
  String raw = full.substring(kDictionaryFontUrlPrefix.length);
  // 剥掉 `?v=<mtime>-<size>` 内容版本戳：它只为让覆盖字体后的 URL 成为新资源，
  // 不参与路径解析。
  final int q = raw.indexOf('?');
  if (q >= 0) raw = raw.substring(0, q);
  if (raw.isEmpty) return null;

  String requested;
  try {
    requested = Uri.decodeComponent(raw);
  } catch (e, stack) {
    _logDictionaryMediaSkip('font url undecodable: $raw ($e)', stack);
    return _fontDenied();
  }

  final String? safePath = ReaderFushiSource.safeCustomFontPath(
    requested,
    allowedRoots: allowedRoots,
  );
  if (safePath == null) {
    _logDictionaryMediaSkip('font outside allowed directory: $requested');
    return _fontDenied();
  }
  if (!whitelistedPaths.contains(p.canonicalize(safePath))) {
    _logDictionaryMediaSkip('font not in configured list: $requested');
    return _fontDenied();
  }

  try {
    final File file = File(safePath);
    if (!file.existsSync()) {
      _logDictionaryMediaSkip('font not found: $safePath');
      return _fontDenied();
    }
    final Uint8List data = await file.readAsBytes();
    if (!isValidFontData(data)) {
      _logDictionaryMediaSkip('font corrupted: $safePath (${data.length} B)');
      return _fontDenied();
    }
    return WebResourceResponse(
      contentType: fallbackMimeType(safePath),
      statusCode: 200,
      reasonPhrase: 'OK',
      headers: const <String, String>{
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'max-age=3600',
      },
      data: data,
    );
  } catch (e, stack) {
    _logDictionaryMediaSkip('font read failed: $safePath ($e)', stack);
    return _fontDenied();
  }
}

/// 拒绝一条字体请求：回 403 空体而不是 null。
///
/// 返回 null 会让请求**穿透**到真实网络（`fushi.local` 不存在，最终是一次 DNS 失败
/// 的等待），而不是干脆地失败；给个明确的 403 让浏览器立刻回退到字体链的下一位。
WebResourceResponse _fontDenied() => WebResourceResponse(
      contentType: 'text/plain',
      statusCode: 403,
      reasonPhrase: 'Forbidden',
      data: Uint8List(0),
    );

/// 制卡前把 JS 负载里的词典媒体（gaiji 外字等）字节落盘到 Anki 媒体缓存目录，
/// 供 [BaseAnkiRepository] 的 storeMediaFile 读取嵌进卡片。
///
/// 背景：popup.js 在 `window.embedMedia` 为真时把外字渲染成
/// `<img src="fushi_dict_N.ext">` 并在负载 `dictionaryMedia`
/// （`[{dictionary, path, filename}]` 的 JSON 串）里登记。两个 Anki repo 从
/// [ankiDictionaryMediaCacheDirPath]/[ankiDictionaryMediaCacheFilename] 读字节再
/// storeMediaFile + 把字段里的 `fushi_dict_N.ext` 替换成真实媒体引用。**但此前没有
/// 任何地方写这个缓存**（`image://` 服务只把字节喂给页面显示、不落盘），故媒体永远
/// 读不到、外字退化成 alt 文本（明鏡义项序号显示成烂 alt「3分の2」）。本函数补上写缓存
/// 这一环：用 [FushiDicts.getMediaFile] 取字节、按与 repo 共用的命名写盘。
///
/// 幂等：已存在的缓存文件跳过。FushiDicts 未初始化 / 字节取不到 / 写盘失败均跳过
/// （该条媒体退回 alt 文本，不阻断制卡）。
///
/// BUG-1265：跳过**必须留痕**。这三条跳过路径以前只有一句不含原因的 debugPrint
/// （甚至直接 `return`），于是「缓存里没有这个文件」在日志里毫无前因；下游 repo 报
/// 「Dictionary media file is missing」时无从判断是词典取不到字节、还是根本没走到
/// 写入方。现在每条跳过都带原因进 [ErrorLogService]（用户上传的报错日志里能看到），
/// 一条媒体一行，只在真出问题时才产生。
Future<void> writeDictionaryMediaCache(String dictionaryMediaJson) async {
  if (dictionaryMediaJson.isEmpty || dictionaryMediaJson == '[]') return;
  final List<dynamic> entries;
  try {
    entries = jsonDecode(dictionaryMediaJson) as List<dynamic>;
  } catch (e, stack) {
    _logDictionaryMediaSkip('payload JSON 解析失败: $e', stack);
    return;
  }
  if (entries.isEmpty) return;

  // 未初始化的判断放在「确实有媒体要写」之后：无媒体时不该产生噪音日志。
  if (!FushiDicts.isInitialized) {
    _logDictionaryMediaSkip(
      'FushiDicts 未初始化，${entries.length} 条词典媒体未落盘（卡片将缺外字）',
    );
    return;
  }

  final Directory dir = Directory(ankiDictionaryMediaCacheDirPath());
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
  } catch (e, stack) {
    _logDictionaryMediaSkip('缓存目录 ${dir.path} 创建失败: $e', stack);
    return;
  }

  for (final dynamic raw in entries) {
    if (raw is! Map) continue;
    final String dict = raw['dictionary']?.toString() ?? '';
    final String path = raw['path']?.toString() ?? '';
    if (dict.isEmpty || path.isEmpty) {
      _logDictionaryMediaSkip('媒体条目缺 dictionary/path，无法定位字节: $raw');
      continue;
    }
    final File file =
        File('${dir.path}/${ankiDictionaryMediaCacheFilename(dict, path)}');
    if (file.existsSync()) continue; // 幂等：已缓存。
    try {
      final Uint8List? bytes = FushiDicts.instance.getMediaFile(dict, path);
      if (bytes == null || bytes.isEmpty) {
        // 最常见的一条：词典里取不到这个资源（分卷 MDD 未挂载、资源名对不上、
        // 词典已删除重导）。以前这里连 debugPrint 都没有。
        _logDictionaryMediaSkip('词典「$dict」取不到媒体字节: $path');
        continue;
      }
      await file.writeAsBytes(bytes, flush: true);
    } catch (e, stack) {
      _logDictionaryMediaSkip('写盘失败 $dict/$path: $e', stack);
    }
  }
}

/// 词典媒体落盘跳过的统一留痕口：debugPrint（开发期）+ [ErrorLogService]（随用户
/// 上传的报错日志一起回来）。跳过只降级这一条媒体，不抛、不阻断制卡。
void _logDictionaryMediaSkip(String reason, [StackTrace? stack]) {
  debugPrint('[DictionaryMedia] $reason');
  ErrorLogService.instance.log('DictionaryMedia.cache', reason, stack);
}

WebResourceResponse? dictionaryMediaWebResourceResponse(Uri url) {
  final _DictionaryMediaResponse? response = _dictionaryMediaResponse(url);
  if (response == null) return null;

  return WebResourceResponse(
    contentType: response.contentType,
    contentEncoding: response.contentEncoding,
    statusCode: response.statusCode,
    reasonPhrase: response.reasonPhrase,
    data: response.data,
  );
}

CustomSchemeResponse? dictionaryMediaCustomSchemeResponse(Uri url) {
  final _DictionaryMediaResponse? response = _dictionaryMediaResponse(url);
  if (response == null) return null;

  return CustomSchemeResponse(
    data: response.data,
    contentType: response.contentType,
    contentEncoding: response.contentEncoding ?? 'utf-8',
  );
}

_DictionaryMediaResponse? _dictionaryMediaResponse(Uri url) {
  if (url.scheme == 'image') {
    final String dictName = url.queryParameters['dictionary'] ?? '';
    final String mediaPath = normalizeDictionaryMediaPath(
      url.queryParameters['path'] ?? '',
    );
    if (dictName.isEmpty || mediaPath.isEmpty) {
      return _DictionaryMediaResponse.notFound();
    }
    if (!FushiDicts.isInitialized) return _DictionaryMediaResponse.notFound();

    try {
      final Uint8List? data = FushiDicts.instance.getMediaFile(
        dictName,
        mediaPath,
      );
      if (data != null) {
        final String mime = dictionaryMediaMimeType(mediaPath);
        return _DictionaryMediaResponse.ok(
          data: data,
          contentType: mime,
          contentEncoding: mime.startsWith('text/') ? 'utf-8' : null,
        );
      }
    } catch (e) {
      debugPrint('[DictionaryMedia] image error: $e');
    }

    return _DictionaryMediaResponse.notFound();
  }

  if (url.scheme == 'dictmedia') {
    final String dictName = url.queryParameters['dictionary'] ?? '';
    final String mediaPath =
        normalizeDictionaryMediaPath(Uri.decodeComponent(url.host));
    if (dictName.isEmpty || mediaPath.isEmpty) {
      return _DictionaryMediaResponse.notFound();
    }
    if (!FushiDicts.isInitialized) return _DictionaryMediaResponse.notFound();

    final Uint8List? data = FushiDicts.instance.getMediaFile(
      dictName,
      mediaPath,
    );
    if (data == null) return _DictionaryMediaResponse.notFound();

    return _DictionaryMediaResponse.ok(
      data: data,
      contentType: 'text/css',
      contentEncoding: 'utf-8',
    );
  }

  return null;
}

class _DictionaryMediaResponse {
  const _DictionaryMediaResponse({
    required this.data,
    required this.contentType,
    required this.statusCode,
    required this.reasonPhrase,
    this.contentEncoding,
  });

  factory _DictionaryMediaResponse.ok({
    required Uint8List data,
    required String contentType,
    String? contentEncoding,
  }) {
    return _DictionaryMediaResponse(
      data: data,
      contentType: contentType,
      contentEncoding: contentEncoding,
      statusCode: 200,
      reasonPhrase: 'OK',
    );
  }

  factory _DictionaryMediaResponse.notFound() {
    return _DictionaryMediaResponse(
      data: Uint8List(0),
      contentType: 'text/plain',
      statusCode: 404,
      reasonPhrase: 'Not Found',
    );
  }

  final Uint8List data;
  final String contentType;
  final String? contentEncoding;
  final int statusCode;
  final String reasonPhrase;
}
