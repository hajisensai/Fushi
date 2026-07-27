import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/mining/galgame_cover_resolver.dart';

/// 刮削封面落地：把合并层算出的 `coverUrl`（`galgame_metadata_merge.dart`）真正
/// 下载落盘。此前刮削只落元数据快照，`coverUrl` 无人消费——用户刮完元数据齐了、
/// 封面还是默认手柄图标。
///
/// 决策（是否下载、扩展名推导）拆成纯函数可单测；网络 IO 收在
/// [downloadGalgameCoverToFile]，失败一律返回 null 并记 debug 日志（刮削元数据
/// 本身已成功，封面失败静默降级，不打断用户流程）。

/// 下载体积上限：封面不该超过它（防被超大图/错误资源撑爆内存）。
const int kGalgameCoverMaxDownloadBytes = 20 * 1024 * 1024;

/// 下载体积下限：小于它的响应不可能是可用封面图（多为错误页/空响应）。
const int kGalgameCoverMinDownloadBytes = 1024;

/// 纯函数：刮削成功后是否要自动下载封面。
///
/// 规则只有一条：**已有可用封面文件（手选/自动/上次下载）绝不覆盖**；没有可用
/// 封面且合并层给出了 URL 才下载。[hasUsableCoverFile] 由调用方按
/// 「coverPath 非空且文件真实存在」判定（与卡片渲染的 existsSync 短路同判据）。
bool shouldAutoDownloadScrapedCover({
  required bool hasUsableCoverFile,
  required String? coverUrl,
}) {
  if (hasUsableCoverFile) return false;
  return coverUrl != null && coverUrl.trim().isNotEmpty;
}

/// 纯函数：用户在统一刮削弹窗里**显式选中**候选后是否下载封面。
///
/// 与 [shouldAutoDownloadScrapedCover]（隐式路径：已有可用封面绝不覆盖）语义
/// 不同：显式选择 = 用户点名要这一条 → 只要源给了 URL 就下载并**覆盖**现有封面
/// （与视频「在线匹配海报」的手动「使用」同语义）。隐式规则保持原样，仅继续
/// 服务将来的自动刮削路径；两条路径的分界由各自纯函数钉死，禁止互相借用。
bool shouldDownloadExplicitScrapedCover({required String? coverUrl}) =>
    coverUrl != null && coverUrl.trim().isNotEmpty;

/// 纯函数：从响应 Content-Type / URL 路径推导落盘扩展名（小写、含点）。
///
/// 优先信 Content-Type（服务器端真相）；拿不到或不认识再看 URL 路径后缀是否在
/// [kGameCoverImageExtensions] 白名单内；都不中回退 `.jpg`（bgm/vndb 封面绝大多
/// 数是 JPEG；解码按内容嗅探，后缀只是文件名）。`.jpeg` 统一归一成 `.jpg`，与
/// `saveGameCoverFromFile` 的归一化一致。
String galgameCoverExtension({required String url, String? contentType}) {
  final String normalizedType =
      (contentType ?? '').split(';').first.trim().toLowerCase();
  const Map<String, String> byContentType = <String, String>{
    'image/png': '.png',
    'image/jpeg': '.jpg',
    'image/jpg': '.jpg',
    'image/webp': '.webp',
    'image/bmp': '.bmp',
  };
  final String? fromType = byContentType[normalizedType];
  if (fromType != null) return fromType;
  final Uri? uri = Uri.tryParse(url);
  if (uri != null && uri.path.isNotEmpty) {
    final String path = uri.path.toLowerCase();
    final int dot = path.lastIndexOf('.');
    if (dot >= 0) {
      final String ext =
          path.substring(dot) == '.jpeg' ? '.jpg' : path.substring(dot);
      if (kGameCoverImageExtensions.contains(ext)) return ext;
    }
  }
  return '.jpg';
}

/// 下载 [url] 的封面图并落盘为该游戏的封面文件，返回落盘路径；任何失败返回 null。
///
/// 校验：仅 http/https、HTTP 200、Content-Type 是 image/*（或缺省——部分图床不给
/// 类型，交给字节数下限兜底）、字节数在 [kGalgameCoverMinDownloadBytes] 与
/// [kGalgameCoverMaxDownloadBytes] 之间。落盘复用 [saveGameCoverBytes]（与手动/
/// 自动封面同名同目录，替换不残留孤儿文件）。[client] / [coverDirectory] 是测试接缝。
Future<String?> downloadGalgameCoverToFile({
  required String gameId,
  required String url,
  HttpClient? client,
  Directory? coverDirectory,
}) async {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    debugPrint('[galgame] cover download skipped, bad url: $url');
    return null;
  }
  final HttpClient http = client ?? HttpClient();
  final bool ownsClient = client == null;
  try {
    final HttpClientRequest request = await http.getUrl(uri);
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      debugPrint('[galgame] cover download HTTP ${response.statusCode}: $url');
      return null;
    }
    final String? contentType = response.headers.contentType?.mimeType;
    if (contentType != null && !contentType.startsWith('image/')) {
      debugPrint('[galgame] cover download non-image type $contentType: $url');
      return null;
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response) {
      builder.add(chunk);
      if (builder.length > kGalgameCoverMaxDownloadBytes) {
        debugPrint('[galgame] cover download too large (> '
            '$kGalgameCoverMaxDownloadBytes bytes): $url');
        return null;
      }
    }
    final Uint8List bytes = builder.takeBytes();
    if (bytes.length < kGalgameCoverMinDownloadBytes) {
      debugPrint(
          '[galgame] cover download too small (${bytes.length} bytes): $url');
      return null;
    }
    return await saveGameCoverBytes(
      gameId: gameId,
      bytes: bytes,
      extension: galgameCoverExtension(url: url, contentType: contentType),
      coverDirectory: coverDirectory,
    );
  } catch (e) {
    debugPrint('[galgame] cover download failed: $url ($e)');
    return null;
  } finally {
    if (ownsClient) http.close(force: true);
  }
}
