/// 媒体库 `alist` 来源条目的稳定地址 ↔ AList 路径互转。
///
/// 条目落库的 `videoPath` 形如 `<站点根>/d/<AList 路径>`——这是 AList 自己的
/// 下载路由（`/d/`），与用户在浏览器里看到的地址同形，肉眼可辨认；但它带临期
/// 签名要求，**不直接拿来播**，播放前经 `/api/fs/get` 换成签名 `raw_url`。
///
/// 与 WebDAV 来源条目同口径：路径段保持**解码态**（`#01 旅は道連れ.mkv` 原样），
/// 扫描器的 `p.dirname` / `sourceEntryBasename` 才能直接用；不要把它当成
/// 可 `Uri.parse` 的严格 URL（`#` 会被当 fragment）。
library;

/// 条目路径里紧随站点根之后的下载路由段。
const String kAListSourceDownloadSegment = '/d';

/// 去尾斜杠的站点根（`https://od.example.com` / `https://x.example.com/alist`）。
String normalizeAListBaseUrl(String baseUrl) {
  String s = baseUrl.trim();
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// AList 路径（`/GD-3/ep01.mkv`）→ 条目地址（`<根>/d/GD-3/ep01.mkv`）。
String alistSourceUrlFor({required String baseUrl, required String path}) {
  final String root = normalizeAListBaseUrl(baseUrl);
  final String normalizedPath = path.startsWith('/') ? path : '/$path';
  return '$root$kAListSourceDownloadSegment$normalizedPath';
}

/// 条目地址 → AList 路径；不属于本站点 `/d/` 命名空间返回 null。
///
/// 纯字符串前缀判定（不走 `Uri`，见文件头）；主机大小写无关由调用方保证站点根
/// 写法一致——两边都出自同一份 configJson。
String? alistPathFromSourceUrl({
  required String baseUrl,
  required String url,
}) {
  final String prefix =
      '${normalizeAListBaseUrl(baseUrl)}$kAListSourceDownloadSegment';
  if (url == prefix) return '/';
  if (!url.startsWith('$prefix/')) return null;
  String rest = url.substring(prefix.length);
  while (rest.length > 1 && rest.endsWith('/')) {
    rest = rest.substring(0, rest.length - 1);
  }
  return rest.isEmpty ? '/' : rest;
}
