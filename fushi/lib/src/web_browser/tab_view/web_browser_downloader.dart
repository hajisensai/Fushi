import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:external_path/external_path.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show XFile;

import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// 网页触发的一次下载（`onDownloadStartRequest`、链接菜单「保存图片」）。
@immutable
class WebBrowserDownloadRequest {
  const WebBrowserDownloadRequest({
    required this.url,
    this.suggestedFileName,
    this.contentDisposition,
    this.mimeType,
    this.contentLength,
    this.userAgent,
    this.referer,
    this.incognito = false,
  });

  final Uri url;
  final String? suggestedFileName;
  final String? contentDisposition;
  final String? mimeType;
  final int? contentLength;
  final String? userAgent;

  /// 发起下载的页面（带 Referer，很多图床 / 网盘靠它防盗链）。
  final Uri? referer;

  /// 无痕标签页发起：照常下载，但不进下载记录（store）。
  final bool incognito;
}

/// 下载落到哪。
enum WebBrowserDownloadDestination {
  /// 用户的「下载」目录（桌面 / Android），进下载记录。
  userDownloads,

  /// 下到临时文件后交给系统分享面板（iOS：下载中心受商店合规限制，用户从分享
  /// 面板「存储到文件」）。不进下载记录。
  shareSheet,
}

/// 判据只问 [StoreRestrictedCapability.downloads]（与下载中心同一道合规门），不写
/// 平台特判。
WebBrowserDownloadDestination webBrowserDownloadDestinationFor({
  required bool isIOS,
}) => StoreRestrictedCapability.downloads.availableOn(isIOS: isIOS)
    ? WebBrowserDownloadDestination.userDownloads
    : WebBrowserDownloadDestination.shareSheet;

WebBrowserDownloadDestination webBrowserDownloadDestination() =>
    StoreRestrictedCapability.downloads.isAvailable
    ? WebBrowserDownloadDestination.userDownloads
    : WebBrowserDownloadDestination.shareSheet;

const Map<String, String> _kMimeExtensions = <String, String>{
  'application/pdf': 'pdf',
  'application/zip': 'zip',
  'application/x-zip-compressed': 'zip',
  'application/x-rar-compressed': 'rar',
  'application/vnd.rar': 'rar',
  'application/x-7z-compressed': '7z',
  'application/epub+zip': 'epub',
  'application/json': 'json',
  'application/vnd.android.package-archive': 'apk',
  'application/x-bittorrent': 'torrent',
  'text/plain': 'txt',
  'text/html': 'html',
  'text/csv': 'csv',
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/avif': 'avif',
  'image/svg+xml': 'svg',
  'image/bmp': 'bmp',
  'audio/mpeg': 'mp3',
  'audio/mp4': 'm4a',
  'audio/ogg': 'ogg',
  'audio/wav': 'wav',
  'audio/flac': 'flac',
  'video/mp4': 'mp4',
  'video/webm': 'webm',
  'video/x-matroska': 'mkv',
  'application/x-subrip': 'srt',
  'text/vtt': 'vtt',
};

/// `Content-Disposition` 里的文件名：`filename*=UTF-8''…`（RFC 5987）优先，再
/// `filename="…"` / `filename=…`。
String? webBrowserContentDispositionFileName(String? header) {
  if (header == null || header.isEmpty) return null;
  final RegExpMatch? star = RegExp(
    r"""filename\*\s*=\s*([^']*)'[^']*'([^;]+)""",
    caseSensitive: false,
  ).firstMatch(header);
  if (star != null) {
    final String raw = star.group(2)!.trim().replaceAll('"', '');
    try {
      return Uri.decodeComponent(raw);
    } on ArgumentError {
      return raw;
    }
  }
  final RegExpMatch? plain = RegExp(
    r'''filename\s*=\s*("([^"]*)"|[^;]+)''',
    caseSensitive: false,
  ).firstMatch(header);
  if (plain == null) return null;
  final String value = (plain.group(2) ?? plain.group(1) ?? '').trim();
  return value.isEmpty ? null : value;
}

/// 清成能落盘的文件名；清完是空的给 null。
String? sanitizeWebBrowserFileName(String? name) {
  if (name == null) return null;
  // 非法字符（Windows 最严，五端统一按它清）走唯一真相源。
  String out = safeWindowsFileName(name).trim();
  // 结尾的点和空格 Windows 不认。
  out = out.replaceAll(RegExp(r'[. ]+$'), '');
  if (out.isEmpty || out == '_') return null;
  if (out.length > 180) {
    final String ext = p.extension(out);
    out = out.substring(0, 180 - ext.length) + ext;
  }
  return out;
}

/// 下载文件名：显式建议名 → Content-Disposition → 地址最后一段 → `download`；没有
/// 扩展名时按 MIME 补一个。
String inferWebBrowserDownloadFileName({
  required Uri url,
  String? suggestedFileName,
  String? contentDisposition,
  String? mimeType,
}) {
  // 服务器的 Content-Disposition 优先：WebView2 给的建议名取自它推好的保存路径，
  // 「下载」目录里已有同名文件时会带上「 (1)」这类编号。
  String? name =
      sanitizeWebBrowserFileName(
        webBrowserContentDispositionFileName(contentDisposition),
      ) ??
      sanitizeWebBrowserFileName(suggestedFileName);
  if (name == null) {
    final List<String> segments = url.pathSegments
        .where((String s) => s.isNotEmpty)
        .toList();
    if (segments.isNotEmpty) {
      String last = segments.last;
      try {
        last = Uri.decodeComponent(last);
      } on ArgumentError {
        // 保留原样。
      }
      name = sanitizeWebBrowserFileName(last);
    }
  }
  name ??= 'download';
  if (p.extension(name).isEmpty) {
    final String mime = (mimeType ?? '').split(';').first.trim().toLowerCase();
    final String? ext = _kMimeExtensions[mime];
    if (ext != null) name = '$name.$ext';
  }
  return name;
}

/// [directory] 里不撞名的路径：`a.pdf` → `a (1).pdf` → `a (2).pdf`……
String uniqueWebBrowserDownloadPath(
  String directory,
  String fileName,
  bool Function(String path) exists,
) {
  final String base = p.basenameWithoutExtension(fileName);
  final String ext = p.extension(fileName);
  String candidate = p.join(directory, fileName);
  for (int i = 1; exists(candidate) || exists('$candidate.part'); i++) {
    candidate = p.join(directory, '$base ($i)$ext');
  }
  return candidate;
}

/// 进度写库的节流：每涨 1% 或 1 MiB 写一次（大文件不至于每个分块都写库）。
bool shouldReportWebBrowserDownloadProgress({
  required int lastReported,
  required int received,
  required int? total,
}) {
  final int delta = received - lastReported;
  if (delta <= 0) return false;
  if (delta >= 1024 * 1024) return true;
  if (total != null && total > 0) return delta * 100 >= total;
  return false;
}

/// 一次下载的结果。
@immutable
class WebBrowserDownloadOutcome {
  const WebBrowserDownloadOutcome({
    required this.fileName,
    this.savedPath,
    this.error,
    this.sharedInstead = false,
  });

  final String fileName;
  final String? savedPath;
  final Object? error;

  /// 走了系统分享面板（[WebBrowserDownloadDestination.shareSheet]）。
  final bool sharedInstead;

  bool get succeeded => error == null;
}

/// 取下载目录（[WebBrowserDownloadDestination.userDownloads]）。
typedef WebBrowserDownloadsDirectoryResolver = Future<String> Function();

/// 取这条地址该带的 Cookie 头（与 WebView 同一个 cookie 罐；Windows 上 cookie 归
/// WebView2 环境所有，必须用同一个环境的 CookieManager 取）。
typedef WebBrowserCookieHeaderResolver = Future<String?> Function(Uri url);

WebBrowserCookieHeaderResolver webBrowserCookieHeaderResolverFor(
  WebViewEnvironment? environment,
) => (Uri url) async {
  try {
    final CookieManager manager = CookieManager.instance(
      webViewEnvironment: environment,
    );
    final List<Cookie> cookies = await manager.getCookies(url: WebUri.uri(url));
    if (cookies.isEmpty) return null;
    return cookies.map((Cookie c) => '${c.name}=${c.value}').join('; ');
  } on Object {
    return null;
  }
};

/// 用户「下载」目录：Android 公共 Download（写不进去时退到 app 外部私有目录），
/// 桌面走系统已知目录（Linux 先看 XDG）。
Future<String> resolveWebBrowserDownloadsDirectory() async {
  if (Platform.isAndroid) {
    try {
      final String public =
          await ExternalPath.getExternalStoragePublicDirectory(
            ExternalPath.DIRECTORY_DOWNLOAD,
          );
      final Directory dir = Directory(public);
      if (await _writable(dir)) return dir.path;
    } on Object {
      // 退到私有目录。
    }
    final Directory? external = await getExternalStorageDirectory();
    final Directory fallback = Directory(
      p.join(
        (external ?? await getApplicationDocumentsDirectory()).path,
        'Download',
      ),
    );
    await fallback.create(recursive: true);
    return fallback.path;
  }
  if (Platform.isLinux) {
    final String? xdg = Platform.environment['XDG_DOWNLOAD_DIR'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
  }
  try {
    final Directory? downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads.path;
  } on Object {
    // 退到家目录。
  }
  final String home =
      Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '.';
  return p.join(home, 'Downloads');
}

Future<bool> _writable(Directory dir) async {
  try {
    if (!await dir.exists()) await dir.create(recursive: true);
    final File probe = File(
      p.join(
        dir.path,
        '.fushi-write-probe-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await probe.writeAsBytes(const <int>[0], flush: true);
    await probe.delete();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// 网页下载的执行者：桌面 / Android 用 app 的 HTTP 客户端（经全应用代理）带上
/// WebView 的 cookie / UA / Referer 下到「下载」目录，进度写下载记录；iOS 下到
/// 临时文件后弹系统分享面板。
class WebBrowserDownloader {
  WebBrowserDownloader({
    required this.store,
    required this.cookieHeader,
    WebBrowserDownloadDestination? destination,
    WebBrowserDownloadsDirectoryResolver? downloadsDirectory,
    HttpClient Function()? httpClient,
    Future<bool> Function(String path)? share,
    DateTime Function()? clock,
  }) : _destination = destination ?? webBrowserDownloadDestination(),
       _downloadsDirectory =
           downloadsDirectory ?? resolveWebBrowserDownloadsDirectory,
       _httpClient = httpClient ?? createAppHttpClient,
       _share = share ?? _shareFile,
       _clock = clock ?? DateTime.now;

  final WebBrowserStore store;
  final WebBrowserCookieHeaderResolver cookieHeader;
  final WebBrowserDownloadDestination _destination;
  final WebBrowserDownloadsDirectoryResolver _downloadsDirectory;
  final HttpClient Function() _httpClient;
  final Future<bool> Function(String path) _share;
  final DateTime Function() _clock;

  WebBrowserDownloadDestination get destination => _destination;

  static Future<bool> _shareFile(String path) =>
      FushiShare.shareFiles(<XFile>[XFile(path)]);

  /// 执行一次下载，返回结果（调用方据此弹完成 / 失败提示）。不抛。
  Future<WebBrowserDownloadOutcome> download(
    WebBrowserDownloadRequest request,
  ) async {
    String fileName = inferWebBrowserDownloadFileName(
      url: request.url,
      suggestedFileName: request.suggestedFileName,
      contentDisposition: request.contentDisposition,
      mimeType: request.mimeType,
    );
    final bool share = _destination == WebBrowserDownloadDestination.shareSheet;
    final bool record = !share && !request.incognito;
    int? id;
    HttpClient? client;
    File? part;
    try {
      final String directory = share
          ? (await getTemporaryDirectory()).path
          : await _downloadsDirectory();
      await Directory(directory).create(recursive: true);
      if (request.url.scheme == 'data') {
        return await _saveDataUri(request, directory, share: share);
      }
      client = _httpClient();
      final HttpClientRequest http = await client.getUrl(request.url);
      final String? cookie = await cookieHeader(request.url);
      if (cookie != null) http.headers.set(HttpHeaders.cookieHeader, cookie);
      final String? ua = request.userAgent;
      if (ua != null && ua.isNotEmpty) {
        http.headers.set(HttpHeaders.userAgentHeader, ua);
      }
      final Uri? referer = request.referer;
      if (referer != null) {
        http.headers.set(HttpHeaders.refererHeader, referer.toString());
      }
      final HttpClientResponse response = await http.close();
      if (response.statusCode >= 400) {
        throw HttpException('HTTP ${response.statusCode}', uri: request.url);
      }
      // 响应头里的文件名比页面给的更准（没显式建议名时）。
      if (request.suggestedFileName == null &&
          request.contentDisposition == null) {
        fileName = inferWebBrowserDownloadFileName(
          url: request.url,
          contentDisposition: response.headers.value('content-disposition'),
          mimeType: response.headers.contentType?.mimeType ?? request.mimeType,
        );
      }
      final String target = uniqueWebBrowserDownloadPath(
        directory,
        fileName,
        (String path) => File(path).existsSync(),
      );
      fileName = p.basename(target);
      final int? total = response.contentLength >= 0
          ? response.contentLength
          : request.contentLength;
      if (record) {
        id = await store.addDownload(
          WebBrowserDownload(
            id: 0,
            url: request.url,
            fileName: fileName,
            startedAt: _clock(),
            mimeType:
                response.headers.contentType?.mimeType ?? request.mimeType,
            totalBytes: total,
          ),
        );
      }
      part = File('$target.part');
      final IOSink sink = part.openWrite();
      int received = 0;
      int reported = 0;
      try {
        await for (final List<int> chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          final int? recordId = id;
          if (recordId != null &&
              shouldReportWebBrowserDownloadProgress(
                lastReported: reported,
                received: received,
                total: total,
              )) {
            reported = received;
            unawaited(store.updateDownload(recordId, receivedBytes: received));
          }
        }
      } finally {
        await sink.close();
      }
      final File done = await part.rename(target);
      part = null;
      final int? recordId = id;
      if (recordId != null) {
        await store.updateDownload(
          recordId,
          receivedBytes: received,
          totalBytes: total ?? received,
          state: WebBrowserDownloadState.completed,
          savedPath: done.path,
        );
      }
      if (share) {
        final bool shown = await _share(done.path);
        if (!shown) {
          throw const FileSystemException('share sheet was not presented');
        }
      }
      return WebBrowserDownloadOutcome(
        fileName: fileName,
        savedPath: done.path,
        sharedInstead: share,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'WebBrowserDownloader.download',
        error,
        stack,
      );
      final int? recordId = id;
      if (recordId != null) {
        unawaited(
          store.updateDownload(recordId, state: WebBrowserDownloadState.failed),
        );
      }
      final File? leftover = part;
      if (leftover != null) {
        try {
          if (await leftover.exists()) await leftover.delete();
        } on FileSystemException {
          // 留着就留着。
        }
      }
      return WebBrowserDownloadOutcome(fileName: fileName, error: error);
    } finally {
      client?.close();
    }
  }

  /// 取一张图的字节（「对图片 OCR 查词」）：与下载同一套 cookie / UA / Referer。
  /// 超过 [maxBytes] 或 HTTP 出错抛异常。
  Future<Uint8List> fetchBytes(
    Uri url, {
    Uri? referer,
    String? userAgent,
    int maxBytes = 32 * 1024 * 1024,
  }) async {
    if (url.scheme == 'data') return UriData.fromUri(url).contentAsBytes();
    final HttpClient client = _httpClient();
    try {
      final HttpClientRequest http = await client.getUrl(url);
      final String? cookie = await cookieHeader(url);
      if (cookie != null) http.headers.set(HttpHeaders.cookieHeader, cookie);
      if (userAgent != null && userAgent.isNotEmpty) {
        http.headers.set(HttpHeaders.userAgentHeader, userAgent);
      }
      if (referer != null) {
        http.headers.set(HttpHeaders.refererHeader, referer.toString());
      }
      final HttpClientResponse response = await http.close();
      if (response.statusCode >= 400) {
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      final BytesBuilder bytes = BytesBuilder(copy: false);
      await for (final List<int> chunk in response) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) {
          throw HttpException('image too large', uri: url);
        }
      }
      return bytes.takeBytes();
    } finally {
      client.close();
    }
  }

  /// `data:` 地址（内联图片的「保存图片」）：直接解码落盘，不进下载记录。
  Future<WebBrowserDownloadOutcome> _saveDataUri(
    WebBrowserDownloadRequest request,
    String directory, {
    required bool share,
  }) async {
    final UriData data = UriData.fromUri(request.url);
    final String name = inferWebBrowserDownloadFileName(
      url: Uri(path: 'image'),
      suggestedFileName: request.suggestedFileName,
      mimeType: data.mimeType,
    );
    final String target = uniqueWebBrowserDownloadPath(
      directory,
      name,
      (String path) => File(path).existsSync(),
    );
    final File file = await File(
      target,
    ).writeAsBytes(data.contentAsBytes(), flush: true);
    if (share && !await _share(file.path)) {
      throw const FileSystemException('share sheet was not presented');
    }
    return WebBrowserDownloadOutcome(
      fileName: p.basename(target),
      savedPath: file.path,
      sharedInstead: share,
    );
  }
}
