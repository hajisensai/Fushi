// 排行榜深链的纯解析（无 Flutter 依赖）：平台层 incoming_fushi_link.dart 的
// 链接分类也用它，不必为了判一个 host 把排行榜页面拉进平台层的 import 图。

/// 排行榜公开分享页（rank.fushi.moe `/u/<id>`、`/w/<id>`）「在 Fushi 中打开」的深链
/// `fushi://leaderboard/user/<id>` / `fushi://leaderboard/work/<id>`
/// （产生端 services/leaderboard/src/pages.js 的 `layout({open})`）。
///
/// 各平台送达后都汇到 main.dart 的 `handleIncomingUrl`：Android 走 manifest 里
/// host=leaderboard 的 VIEW intent-filter + ReceiveIntent；iOS 走 url_events；
/// macOS 走 `SourceUrlChannel.routedHosts`；Windows / Linux 走协议注册的 argv
/// （冷启动）与单实例转交（热启动）。
sealed class LeaderboardDeepLink {
  const LeaderboardDeepLink(this.id);

  /// 服务端账户 / 作品 id（与 pages.js 的 `PAGE_ID` 同一字符集与长度上限）。
  final String id;

  static const String host = 'leaderboard';

  static final RegExp _id = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

  /// 不是排行榜深链（scheme / host / 路径形状 / id 字符集任一不符）回 null。
  static LeaderboardDeepLink? tryParse(String? url) {
    if (url == null) return null;
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    return fromUri(uri);
  }

  static LeaderboardDeepLink? fromUri(Uri uri) {
    if (uri.scheme.toLowerCase() != 'fushi') return null;
    if (uri.host.toLowerCase() != host) return null;
    final List<String> segments = uri.pathSegments
        .where((String s) => s.isNotEmpty)
        .toList();
    if (segments.length != 2) return null;
    final String id = segments[1];
    if (!_id.hasMatch(id)) return null;
    return switch (segments[0].toLowerCase()) {
      'user' => LeaderboardUserLink(id),
      'work' => LeaderboardWorkLink(id),
      _ => null,
    };
  }

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is LeaderboardDeepLink &&
      other.id == id;

  @override
  int get hashCode => Object.hash(runtimeType, id);
}

/// `fushi://leaderboard/user/<accountId>` → `LeaderboardUserPage`。
final class LeaderboardUserLink extends LeaderboardDeepLink {
  const LeaderboardUserLink(super.id);

  @override
  String toString() => 'LeaderboardUserLink($id)';
}

/// `fushi://leaderboard/work/<workId>` → `LeaderboardWorkPage`。
final class LeaderboardWorkLink extends LeaderboardDeepLink {
  const LeaderboardWorkLink(super.id);

  @override
  String toString() => 'LeaderboardWorkLink($id)';
}
