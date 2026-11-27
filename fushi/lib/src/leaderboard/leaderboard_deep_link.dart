import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show MaterialPageRoute;

import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_tab.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_user_page.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_work_page.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_link.dart';

export 'package:fushi/src/leaderboard/leaderboard_link.dart';

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
