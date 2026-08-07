/// anime-offline-database（minified）离线别名库下载器 —— 刮削匹配层的**离线首选源**。
///
/// 该库把 AniList / Bangumi / TMDB 等站点的动画条目聚合为一个 JSON（含跨站别名），
/// 用来在完全离线的情况下把「文件名标题 → 规范条目」匹配上，再去在线源取海报。
/// 文件几十 MB，必须**流式落盘**（`http.Client.send`），不整块进内存。
///
/// 代理：`package:http` 默认走 `dart:io` `HttpClient`，尊重进程环境系统代理设置；
/// GitHub Releases 在部分地区需代理，由外层环境配置后自动继承，本层不额外处理。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi/src/media/video/scraper/bangumi_client.dart'
    show ScrapeNetworkException;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 离线库下载器。构造可注入 [http.Client]（默认自建）与覆盖 [downloadUrl]（镜像/测试）。
class OfflineDbDownloader {
  OfflineDbDownloader({
    http.Client? client,
    Uri? downloadUrl,
  })  : _client = client ?? http.Client(),
        _downloadUrl = downloadUrl ?? Uri.parse(_defaultUrl);

  final http.Client _client;
  final Uri _downloadUrl;

  /// 默认下载地址（manami-project 官方 latest release 的 minified 产物）。
  static const String _defaultUrl =
      'https://github.com/manami-project/anime-offline-database/releases/download/latest/anime-offline-database-minified.json';

  /// 落地文件名（与官方产物同名，便于 [isFresh] 复用识别）。
  static const String fileName = 'anime-offline-database-minified.json';

  static const Duration _timeout = Duration(minutes: 5);

  /// 流式下载到 [targetDir]：先写 `<name>.tmp` 再原子 rename 为正式文件，返回落地文件。
  ///
  /// [onProgress] 每收到一个数据块回调 `(已接收字节, 总字节或 null)`。
  ///
  /// 任意失败（网络 / 非 2xx / 写盘）→ 抛 [ScrapeNetworkException]，并**保证不留半截
  /// 正式文件**（清掉 .tmp，正式文件从不在下载完成前出现）。
  Future<File> download({
    required Directory targetDir,
    void Function(int received, int? total)? onProgress,
  }) async {
    await targetDir.create(recursive: true);
    final String finalPath = p.join(targetDir.path, fileName);
    final File tmpFile = File('$finalPath.tmp');
    // 清掉可能残留的上次半截 .tmp。
    if (await tmpFile.exists()) {
      await tmpFile.delete();
    }

    IOSink? sink;
    try {
      final http.StreamedResponse response = await _client
          .send(http.Request('GET', _downloadUrl))
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ScrapeNetworkException(
          'Offline DB download HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }

      final int? total =
          response.contentLength != null && response.contentLength! > 0
              ? response.contentLength
              : null;
      int received = 0;

      sink = tmpFile.openWrite();
      await for (final List<int> chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      // 原子替换：目标已存在时先删（Windows rename 不覆盖）。
      final File finalFile = File(finalPath);
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await tmpFile.rename(finalPath);
      return finalFile;
    } on ScrapeNetworkException {
      await _cleanup(sink, tmpFile);
      rethrow;
    } on TimeoutException {
      await _cleanup(sink, tmpFile);
      throw const ScrapeNetworkException('Offline DB download timed out');
    } catch (e) {
      await _cleanup(sink, tmpFile);
      throw ScrapeNetworkException('Offline DB download failed: $e');
    }
  }

  /// [targetDir] 内的正式文件是否存在且 mtime 未超 [maxAge]（默认 30 天）。
  bool isFresh(Directory targetDir,
      {Duration maxAge = const Duration(days: 30)}) {
    final File file = File(p.join(targetDir.path, fileName));
    if (!file.existsSync()) return false;
    final DateTime modified = file.lastModifiedSync();
    return DateTime.now().difference(modified) <= maxAge;
  }

  /// 关闭内部 client（若为默认自建）。
  void close() => _client.close();

  /// 关闭残留 sink 并删除半截 .tmp（best-effort，绝不掩盖原始异常）。
  Future<void> _cleanup(IOSink? sink, File tmpFile) async {
    try {
      await sink?.close();
    } catch (_) {
      // sink 已损坏时关闭失败不影响清理目标（删 tmp）。
    }
    try {
      if (await tmpFile.exists()) await tmpFile.delete();
    } catch (_) {
      // .tmp 删除失败（占用/权限）不再抛：正式文件从不生成，无脏正式产物。
    }
  }
}
