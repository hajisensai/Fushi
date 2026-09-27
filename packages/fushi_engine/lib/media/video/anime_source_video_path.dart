/// 在线视频源（Aniyomi 扩展）入库集的 `VideoBooks.videoPath` 标识。
///
/// 2026-09-27「浏览」阶段 2b：视频在线作品「加入媒体库」时每集落一行 `VideoBooks`，
/// 复用 TODO-1157 流媒体书的形态——但它不是可直接播的 URL（扩展给的流地址是短 TTL
/// 签名链接，必须每次起播重新向扩展取），所以 `videoPath` 用一个**非 http** 的自定义
/// scheme 标识，重开规格（扩展包 / 源 / 作品 / 本集）放在 `streamSpecJson`。
///
/// 形如 `anime-source://<扩展包>/<源 id>/<作品名> - E03`：最后一段只为可读（按
/// basename 解析集号的旧逻辑拿到的是 `… - E03`），身份永远是 bookUid + spec。
///
/// 凡是「按 http 前缀判是不是本地文件」的门（存在性校验、抽帧、刮削、互联下发、
/// 备份可达性）都必须同时认它——否则这行会被当成丢失的本地文件。判据只在这里写一次。
library;

import 'package:fushi_engine/utils/misc/safe_file_name.dart';

/// 自定义 scheme（不带 `://`）。
const String kAnimeSourceVideoPathScheme = 'anime-source';

const String _prefix = '$kAnimeSourceVideoPathScheme://';

/// [path] 是不是在线视频源入库集的标识（大小写不敏感，容忍首尾空白）。
bool isAnimeSourceVideoPath(String? path) {
  if (path == null) return false;
  final String trimmed = path.trimLeft();
  return trimmed.length >= _prefix.length &&
      trimmed.substring(0, _prefix.length).toLowerCase() == _prefix;
}

/// 拼一集的标识。[label] 是可读的末段（作品名 + 集号），非法路径字符替换掉。
String animeSourceVideoPath({
  required String extensionPackage,
  required String sourceId,
  required String label,
}) {
  final String safe = safeWindowsFileName(label).trim();
  return '$_prefix$extensionPackage/$sourceId/${safe.isEmpty ? 'episode' : safe}';
}

/// 视频行是不是「只在网络上」的（http/https 流或在线视频源集）：没有本地文件可以
/// stat、抽帧、刮削或经互联下发。
bool isNetworkOnlyVideoPath(String? path) {
  if (path == null) return false;
  final String lower = path.trimLeft().toLowerCase();
  return lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      isAnimeSourceVideoPath(path);
}
