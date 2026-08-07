import 'package:flutter/foundation.dart';
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
      homeShellTabNotifier.addListener(_onShellTabChanged);
    }
  }

  @override
  void dispose() {
    if (shellTab != null) {
      homeShellTabNotifier.removeListener(_onShellTabChanged);
    }
    super.dispose();
  }

  void _onShellTabChanged() {
    if (!mounted) return;
    if (homeShellTabNotifier.value == shellTab) {
      onTabActivated();
    }
  }

  /// 用户切回本 tab（[shellTab]）时的钩子；仅 [shellTab] 非 null 时会被调用。
  @protected
  void onTabActivated() {}

  /// 守卫式整页刷新（原 `BaseTabPageState.refresh` 上提，供各 tab 复用）。
  void refresh() {
    if (mounted) {
      setState(() {});
    }
  }
}
