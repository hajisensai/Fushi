import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show MaterialPageRoute;

import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_tab.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_user_page.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_work_page.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

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

/// `fushi://leaderboard/user/<accountId>` → [LeaderboardUserPage]。
final class LeaderboardUserLink extends LeaderboardDeepLink {
  const LeaderboardUserLink(super.id);

  @override
  String toString() => 'LeaderboardUserLink($id)';
}

/// `fushi://leaderboard/work/<workId>` → [LeaderboardWorkPage]。
final class LeaderboardWorkLink extends LeaderboardDeepLink {
  const LeaderboardWorkLink(super.id);

  @override
  String toString() => 'LeaderboardWorkLink($id)';
}

/// 冷启动排队：链接比 `initialise()` 先到，等首页挂载后的首帧再推页；
/// 就绪前连点多次只落最后一条。
class LeaderboardDeepLinkQueue {
  LeaderboardDeepLinkQueue({required this.isActive, required this.run});

  /// 宿主（根 widget）是否还挂着；帧回调跑到时已卸载就丢弃。
  final bool Function() isActive;

  /// 真正的落地动作（见 [openLeaderboardDeepLink]）。
  final Future<void> Function(LeaderboardDeepLink link) run;

  LeaderboardDeepLink? _pending;
  bool _scheduled = false;

  @visibleForTesting
  LeaderboardDeepLink? get pending => _pending;

  /// 链接到达：先存下；[ready]（app 已初始化）时立刻排到下一帧。未就绪时由宿主在
  /// 就绪后的 build 里调 [schedule]。
  void enqueue(LeaderboardDeepLink link, {required bool ready}) {
    _pending = link;
    if (ready) schedule();
  }

  /// 有排队的链接就在下一帧落地。根 build 每次都会调，重复调用是 no-op。
  void schedule() {
    if (_scheduled || _pending == null) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final LeaderboardDeepLink? link = _pending;
      _pending = null;
      if (link != null && isActive()) unawaited(run(link));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}

/// 落地一条排行榜深链：在当前页面之上推对应页面（不打断正在看的东西，返回即回原处）。
///
/// 用户页 / 作品页靠已开启账户的签名客户端取数据；本机还没开启排行榜（或账户读取
/// 失败）时推排行榜主页——它显示开启说明 / 读取错误与重试，而不是一个永远空着的
/// 用户页。[isLeaderboardActive] 负责先等账户文件读完（`LeaderboardService.load`）。
Future<void> openLeaderboardDeepLink(
  LeaderboardDeepLink link, {
  required NavigatorState? navigator,
  required Future<bool> Function() isLeaderboardActive,
}) async {
  if (navigator == null || !navigator.mounted) return;
  bool active;
  try {
    active = await isLeaderboardActive();
  } catch (error, stackTrace) {
    // 排行榜主页自己会重新 load 并显示错误与重试。
    ErrorLogService.instance.log('Leaderboard.deepLink', error, stackTrace);
    active = false;
  }
  if (!navigator.mounted) return;
  final Widget page = !active
      ? const LeaderboardPage()
      : switch (link) {
          LeaderboardUserLink(:final String id) => LeaderboardUserPage(
            accountId: id,
          ),
          LeaderboardWorkLink(:final String id) => LeaderboardWorkPage(
            workId: id,
          ),
        };
  unawaited(
    navigator.push<void>(
      MaterialPageRoute<void>(builder: (BuildContext _) => page),
    ),
  );
}
