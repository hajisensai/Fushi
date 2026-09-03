// 流媒体认证头的**作用域判据**：认证头只能发给来源自己的主机。
//
// 为什么需要这个原语（BUG：WebDAV 凭据外泄给第三方主机）：
// 来源库扫描会把 WebDAV 根下的 `.m3u8` 清单导入成条目，而清单里允许出现指向
// **任意第三方主机**的绝对 http(s) 行（IPTV / 混合清单很常见）。这些条目入库时
// 照样打上该 WebDAV 来源的 `sourceId`，于是播放期按 sourceId 解析出的
// `Authorization: Basic base64(user:pass)` 会被原样发给第三方主机——对端直接拿到
// 用户 NAS 的明文账号密码。
//
// 根因不是「清单解析写错了」，而是**认证头的解析结果没有作用域**：一旦拿到 map，
// 调用方可以把它发到任何 URL 去。故这里把「能不能发」做成判据原语，让认证头的
// 每一个下发点都必须先过它，而不是靠各调用点自觉。
library;

/// [target] 是否落在 [root] 这个来源根之内（同 origin 且路径在根之下）。
///
/// 判据（全部满足才算同域，任一不满足一律判 false —— 宁可不发认证头导致
/// 401，也不能把凭据发给别人）：
/// - 两边都能解析成带 host 的绝对 URL；
/// - scheme 相同（http 的凭据不许升/降级到别的协议上）、host 相同（大小写无关）；
/// - 端口相同（按 scheme 默认端口归一，故 `http://h` 与 `http://h:80` 等价）；
/// - target 的路径在 root 的路径**之下**（按 `/` 分段前缀比较，避免
///   `/dav-evil/` 被 `/dav` 前缀匹配蒙混过去）。
bool isUrlWithinSourceRoot(String target, String root) {
  if (!isSameHttpOrigin(target, root)) return false;
  final Uri t = Uri.parse(target);
  final Uri r = Uri.parse(root);
  return _isPathPrefix(_segments(r.path), _segments(t.path));
}

/// [a] 与 [b] 是否同 origin（scheme + host + 端口，端口按 scheme 默认值归一）。
///
/// 给「凭据只能发回它自己那台主机」这类判断用：字幕 sidecar 与流是兄弟路径而非
/// 子路径，故不能套 [isUrlWithinSourceRoot] 的路径前缀判据，只比 origin。
/// 任一侧不是带 host 的绝对 URL 一律返回 false（宁可不发凭据）。
bool isSameHttpOrigin(String a, String b) {
  final Uri? x = _tryAbsolute(a);
  final Uri? y = _tryAbsolute(b);
  if (x == null || y == null) return false;
  return x.scheme == y.scheme &&
      x.host.toLowerCase() == y.host.toLowerCase() &&
      x.port == y.port;
}

Uri? _tryAbsolute(String raw) {
  if (raw.isEmpty) return null;
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  // `Uri.port` 已按 scheme 归一默认端口，无需自行补。
  return uri;
}

List<String> _segments(String path) =>
    path.split('/').where((String s) => s.isNotEmpty).toList(growable: false);

bool _isPathPrefix(List<String> root, List<String> target) {
  if (root.length > target.length) return false;
  for (int i = 0; i < root.length; i++) {
    if (root[i] != target[i]) return false;
  }
  return true;
}
