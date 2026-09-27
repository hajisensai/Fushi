import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/platform/app_shortcuts.dart';

/// 快捷方式 URL 的冷启动排队。
///
/// 冷启动时 URL 比 `initialise()` 先到，而 HomePage.initState 会把首页 tab 重置
/// 成启动 tab，所以先存着，等 home 挂载后的首帧再落地；连点多次只落最后一条。
class AppShortcutQueue {
  AppShortcutQueue({required this.isActive, required this.run});

  /// 宿主（根 widget）是否还挂着；帧回调跑到时已卸载就丢弃。
  final bool Function() isActive;

  /// 真正的落地动作（见 [runAppShortcut]）。
  final Future<void> Function(AppShortcut shortcut) run;

  AppShortcut? _pending;
  bool _scheduled = false;

  @visibleForTesting
  AppShortcut? get pending => _pending;

  /// URL 到达：先存下；[ready]（app 已初始化、首页即将渲染）时立刻排到下一帧。
  /// 未就绪时由宿主在就绪后的 build 里调 [schedule]。
  void enqueue(AppShortcut shortcut, {required bool ready}) {
    _pending = shortcut;
    if (ready) schedule();
  }

  /// 有排队的快捷方式就在下一帧落地。根 build 每次都会调，重复调用是 no-op。
  void schedule() {
    if (_scheduled || _pending == null) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final AppShortcut? shortcut = _pending;
      _pending = null;
      if (shortcut != null && isActive()) unawaited(run(shortcut));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}

/// 落地一条长按图标快捷方式。
///
/// - 目标模块已关：什么都不做。Android 上被固定到桌面的旧快捷方式不会随
///   `setDynamicShortcuts` 消失（原生侧会把它置灰，但老版本固定的、或置灰前点下
///   的仍可能到这里），此时既不能切 tab，也不能把用户正在看的页面退掉。
/// - 新手引导未完成：只在引导下面切 tab，不动路由栈（引导是压在首页上的路由，
///   以任何方式关掉都记为完成）；用户走完引导落在目标 tab 上。查词与其它 tab
///   同口径——不在引导上面再压一个独立查词页。
/// - 查词：交给 [openLookup]（HomePage 的查词落地入口；阅读器 / 播放器压在上面时
///   它推独立查词页到最上层，不打断正在看的东西）。
/// - 其余 tab：切 tab 后逐层退回首页根路由，否则 tab 切了也被上层页面挡住。
Future<void> runAppShortcut(
  AppShortcut shortcut, {
  required ModuleVisibility visibility,
  required bool onboardingCompleted,
  required NavigatorState? navigator,
  required void Function(HomeTab tab) selectHomeTab,
  required VoidCallback openLookup,
  ExternalMediaNavigation? media,
}) async {
  if (!visibility.isEnabled(shortcut.module)) return;
  if (!onboardingCompleted) {
    selectHomeTab(shortcut.homeTab);
    return;
  }
  if (shortcut == AppShortcut.lookup) {
    openLookup();
    return;
  }
  selectHomeTab(shortcut.homeTab);
  if (navigator == null) return;
  final ExternalMediaNavigation mediaNavigation =
      media ?? ExternalMediaNavigation.instance;
  // 与卡片来源回跳（card_source_router）同一条队列：两个外部入口不会同时去收
  // 同一个媒体页。
  await mediaNavigation.navigate(
    () => unwindToHomeRoute(navigator, media: mediaNavigation),
  );
}

/// 逐层退回首页根路由。
///
/// 每层先 `maybePop`（等同按返回键），让阅读器 / 编辑页的 PopScope 存进度或拦下
/// 未保存的改动。返回键被**吸收**（那一层还在）时分两种：
/// - 栈顶是登记在 [ExternalMediaNavigation] 的媒体页：返回键只关掉了它的一层
///   前台浮层（视频页词典弹窗 / 侧栏 / 字幕列表等，BUG-1862 的逐级退出）。
///   交给页面自己的 `closeActive`——它一次关掉全部浮层、落库、出栈并等路由真正
///   结束；落库失败它会拒绝，此时停在原地、不丢页面。
/// - 其它页面拒绝出栈（弹了「放弃修改？」之类）：停在那里交给用户。
///
/// 判「这层走没走」看路由是否还 active，而不是栈顶是否换了：拒绝出栈时弹出的
/// 确认对话框也会换掉栈顶，按身份比较会把对话框当成进展，下一轮再 pop 掉它
/// （= 替用户点了取消），然后无限重来。
Future<void> unwindToHomeRoute(
  NavigatorState navigator, {
  required ExternalMediaNavigation media,
}) async {
  while (navigator.mounted && navigator.canPop()) {
    final Route<dynamic>? top = _topRoute(navigator);
    if (top == null) return;
    await navigator.maybePop();
    if (!navigator.mounted) return;
    if (!top.isActive) continue;
    if (!top.isCurrent) return;
    if (!await media.closeActive()) return;
    if (!navigator.mounted || top.isActive) return;
  }
}

Route<dynamic>? _topRoute(NavigatorState navigator) {
  Route<dynamic>? top;
  navigator.popUntil((Route<dynamic> route) {
    top = route;
    return true;
  });
  return top;
}
