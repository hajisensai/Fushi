import 'dart:typed_data';

import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/utils/misc/audio_mime.dart';

/// TODO-1335 ②：把 `resolveLookupAudioUrl` 解析出的单词音频 URL/路径归一成字节 +
/// contentType，供浏览器扩展 `/api/lookup/audio`（以及 `HibikiSyncServer` 同款端点）经本地
/// 短命 token 播放。
///
/// 此前 server 端音频解析（`_AppModelRemoteLookupService.lookupAudio`）只查本地音频库，忽略
/// 用户在「管理音频来源」里配置的远程发音源（jpod/forvo/hibikiRemote）——仅配远程源的用户
/// 在扩展/远端查词弹窗里恒无单词音频。改为复用 app 内查词同一条 `resolveLookupAudioUrl` 全源
/// 解析链后，解析结果可能是本地文件路径，也可能是远程 http(s) URL；本 helper 负责把两者都归
/// 一成字节（远程源下字节、本地源读文件），仍经本地 127.0.0.1 短命 token 播放（扩展宿主在
/// https 页面无法直连任意远程 http URL——mixed content；127.0.0.1 是可信来源不受限）。
///
/// 纯函数：下载与读文件都由参数注入，可单测三分支（远程 / 本地 / 未命中）。
typedef RemoteAudioDownloader = Future<RemoteAudioLookup?> Function(Uri uri);
typedef LocalAudioFileLoader = Future<Uint8List?> Function(String filePath);

/// 把 [resolved]（`resolveLookupAudioUrl` 的返回：本地文件路径 / `file://` / 远程 http(s) URL /
/// null）归一成 [RemoteAudioLookup]。远程 URL 走 [downloadRemote]，本地路径走 [loadLocalFile]。
/// 任一环节缺字节即回 null（弹窗降级为无音频，与 app 内一致）。
Future<RemoteAudioLookup?> remoteAudioLookupFromResolvedUrl(
  String? resolved, {
  required RemoteAudioDownloader downloadRemote,
  required LocalAudioFileLoader loadLocalFile,
}) async {
  if (resolved == null || resolved.isEmpty) return null;
  final Uri? uri = Uri.tryParse(resolved);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return downloadRemote(uri);
  }
  final String filePath =
      uri != null && uri.scheme == 'file' ? uri.toFilePath() : resolved;
  final Uint8List? bytes = await loadLocalFile(filePath);
  if (bytes == null || bytes.isEmpty) return null;
  return RemoteAudioLookup(
    bytes: bytes,
    contentType: remoteAudioContentTypeForPath(filePath),
  );
}

/// 按文件扩展名推 audio content-type（本地文件 / 无响应头时用）。映射与弹窗
/// `data:` URL 侧共用同一张 [kAudioMimeByExtension]（audio_mime.dart，`.opus`
/// 按 RFC 7845 → audio/ogg）；未知扩展兜底 `application/octet-stream`——HTTP
/// 响应头诚实报未知，浏览器按字节嗅探仍能播常见音频（与 `data:` URL 侧的
/// audio/mpeg 兜底是刻意的消费端差异，见 audio_mime.dart 注释）。
String remoteAudioContentTypeForPath(String filePath) =>
    audioMimeForPathWithFallback(
      filePath,
      fallback: 'application/octet-stream',
    );

/// 远程下载的 content-type：优先取响应头里的 `audio/*`（去掉 `; charset` 等参数），缺失/非
/// 音频类型时从 [uri] 路径扩展名兜底（Forvo/jpod 的 URL 常带扩展名）。
String remoteAudioContentTypeFromResponse(Uri uri, String? header) {
  if (header != null) {
    final int semi = header.indexOf(';');
    final String type =
        (semi >= 0 ? header.substring(0, semi) : header).trim().toLowerCase();
    if (type.startsWith('audio/')) return type;
  }
  return remoteAudioContentTypeForPath(uri.path);
}
