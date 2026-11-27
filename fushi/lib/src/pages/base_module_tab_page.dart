import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi/src/pages/base_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';

/// 首页模块 tab 的共通基类：**不要求 MediaType / MediaSource**
/// （审计 Phase 3.6「页面骨架两套」）。
///
/// 此前 5 个 home tab 三种血统各自为政：reader / dictionary 走 [BaseTabPage]
/// （强绑 MediaSource），dashboard / video 用裸 ConsumerStatefulWidget 手搓
/// 生命周期，game 是无 Riverpod 的纯 StatefulWidget。本类只收口真实重复的
/// 部分：
/// - [BaseModuleTabPageState.refresh]：守卫式 setState（原
///   `BaseTabPageState.refresh` 上提）；
/// - [BaseModuleTabPageState.shellTab] / [BaseModuleTabPageState.onTabActivated]：
///   「切回本 tab 时刷新」的 [homeShellTabNotifier] 监听三件套
///   （原 home_video_page 的 BUG-994 手搓样板收口）；
/// - [BaseModuleTabPageState.isShownToUser] /
///   [BaseModuleTabPageState.onShownToUserAgain]：「本页此刻真在用户眼前吗」——
///   既没被 Offstage 藏着（切到别的 tab），也没被播放页 / 阅读器 / 详情页盖住。
///   后台到达的数据信号据此推迟重载，回到眼前时补做（原 home_video_page 的
///   BUG-3610 样板收口，BUG-4895 起首页也走它）；
/// - 经 [BasePageState] 继承 appModel / theme 快捷入口与
///   `FushiPagePlaceholders` 的 buildLoading / buildError 骨架占位。
///
/// [BaseTabPage] 改为本类的 MediaSource 特化子类。HomeGamePage 因测试需要在
/// 无 ProviderScope 下单独 pump（见 home_game_page_test.dart 的桩说明），
/// 刻意保持纯 StatefulWidget，不挂本基类。
abstract class BaseModuleTabPage extends BasePage {
  /// Create an instance of this tab page.
  const BaseModuleTabPage({super.key});

  @override
  BaseModuleTabPageState<BaseModuleTabPage> createState();
}

/// [BaseModuleTabPage] 的 State 基类；见类注释。
abstract class BaseModuleTabPageState<T extends BaseModuleTabPage>
    extends BasePageState<T> {
  /// 本 tab 对应的首页 shell tab。非 null 时基类监听 [homeShellTabNotifier]，
  /// 用户切回本 tab 时回调 [onTabActivated]（保活 tab 的「切回刷新」范式，
  /// BUG-994）。null（默认）= 不监听——非保活 tab 切回时整页重建，无需信号。
  HomeTab? get shellTab => null;

  @override
  void initState() {
    super.initState();
    if (shellTab != null) {
      listenTo(homeShellTabNotifier, _onShellTabChanged);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachTickerMode();
  }

  @override
  void activate() {
    super.activate();
    // 被挪到树上别处：祖先 TickerMode 可能换了一个。
    _attachTickerMode();
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_onTickerModeChanged);
    _tickerMode = null;
    super.dispose();
  }

  /// 祖先 [TickerMode] 的通知器。框架在两种情况下把它关掉，正好是「本页不在
  /// 用户眼前」的全部情形：
  /// - 所在路由被一个不透明路由完全盖住（[Overlay] 给被盖住的条目挂
  ///   `TickerMode(enabled: false)`；对话框 / 弹层不算，底下的页面还看得见）；
  /// - 保活 tab 没被选中（`HomePage` 用 `Offstage` + `TickerMode` 藏未选中的 tab）。
  ///
  /// 走 [TickerMode.getValuesNotifier] 而不是 `TickerMode.of`：后者建立依赖，
  /// 每次开关都让整页重建一遍；这里只要信号。
  ValueListenable<TickerModeData>? _tickerMode;

  /// 上一次看到的 [_tickerMode] 开关（判「看不见 → 又看得见」的边沿）。
  bool _tickersWereEnabled = true;

  void _attachTickerMode() {
    final ValueListenable<TickerModeData> notifier =
        TickerMode.getValuesNotifier(context);
    if (identical(notifier, _tickerMode)) return;
    _tickerMode?.removeListener(_onTickerModeChanged);
    _tickerMode = notifier..addListener(_onTickerModeChanged);
    _onTickerModeChanged();
  }

  void _onTickerModeChanged() {
    final bool enabled = _tickerMode?.value.enabled ?? true;
    final bool shownAgain = enabled && !_tickersWereEnabled;
    _tickersWereEnabled = enabled;
    if (!shownAgain) return;
    // 通知在构建期内到达（祖先 TickerMode 正在重建），钩子里要 setState / 改
    // provider，挪到这一帧之后。
    scheduleMicrotask(() {
      if (mounted && isShownToUser) onShownToUserAgain();
    });
  }

  /// 本页此刻是否真在用户眼前：没被别的页面盖住、没被 Offstage 藏着，且
  /// （[shellTab] 非 null 时）本 tab 是当前 shell tab。
  ///
  /// 不在眼前时，本页的数据监听照常在跑。这时重查聚合 + 整页 setState 用户一帧
  /// 都看不到，却实打实占着 UI isolate——盖在上面的播放页的新视频帧要等 UI 线程
  /// 排到才能上屏（BUG-4895）。所以后台到达的数据信号一律先问这里：不在眼前就
  /// 只记一笔，[onTabActivated] / [onShownToUserAgain] 时补做。
  @protected
  bool get isShownToUser =>
      _tickersWereEnabled &&
      (shellTab == null || homeShellTabNotifier.value == shellTab);

  void _onShellTabChanged() {
    if (!mounted) return;
    if (homeShellTabNotifier.value == shellTab) {
      onTabActivated();
    }
  }

  /// 用户切回本 tab（[shellTab]）时的钩子；仅 [shellTab] 非 null 时会被调用。
  ///
  /// 调用时 `Offstage` 还没重建，[isShownToUser] 可能仍为假；随后那一帧会再来
  /// 一次 [onShownToUserAgain]。
  @protected
  void onTabActivated() {}

  /// 本页回到用户眼前的边沿（[isShownToUser] 由假变真）：盖着它的页面弹走，或
  /// 所在 tab 重新显示。补做不在眼前期间推迟的工作用。
  @protected
  void onShownToUserAgain() {}

  /// 守卫式整页刷新（原 `BaseTabPageState.refresh` 上提，供各 tab 复用）。
  void refresh() {
    if (mounted) {
      setState(() {});
    }
  }
}
