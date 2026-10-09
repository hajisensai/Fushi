import 'package:flutter/widgets.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/settings/cupertino_settings_renderer.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_renderer.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/utils.dart';

/// Renders [destination] through the active platform's settings detail shell
/// (Material → [FushiPageScaffold] + 24px padding + [AdaptiveSettingsSection];
/// Cupertino → grouped sliver list). This is the SAME chrome the master-detail
/// renderer uses, so any pushed settings sub-page built on top of it is visually
/// indistinguishable from a real schema destination — no scaffold/padding/card
/// drift between the unified detail pane and the pages it links to.
///
/// Used by the pushed sub-pages that are not first-class schema destinations
/// (shortcut bindings, app-icon picker): they synthesise a [SettingsDestination]
/// (usually with a `body` escape hatch carrying their custom content) and call
/// this, instead of hand-rolling their own scaffold.
Widget buildSettingsDetailShell({
  required BuildContext context,
  required SettingsContext settingsContext,
  required SettingsDestination destination,
}) {
  final SettingsRenderer renderer = resolveSettingsRenderer(context);
  return renderer.buildDetailPage(
    settingsContext: settingsContext,
    destination: destination,
  );
}

class SettingsDetailPage extends BasePage {
  const SettingsDetailPage({
    required SettingsDestination this.destination,
    super.key,
  }) : subPageBuilder = null;

  /// 子 schema 页（[SettingsNavigationItem.child]）：与顶层分类同一套详情壳，但
  /// 新鲜树来自 [subPageBuilder] 而不是按 id 到顶层 schema 里找——子页共用父分类的
  /// id，按 id 找会把父页渲染出来。
  const SettingsDetailPage.subPage(
    SettingsDestination Function() this.subPageBuilder, {
    super.key,
  }) : destination = null;

  final SettingsDestination? destination;
  final SettingsDestination Function()? subPageBuilder;

  @override
  BasePageState<SettingsDetailPage> createState() => _SettingsDetailPageState();
}

class _SettingsDetailPageState extends BasePageState<SettingsDetailPage>
    with SettingsContextHost<SettingsDetailPage> {
  // 错误 / 调试日志、游戏内查词准入（hook 异步上报）、推荐包下载阶段（BUG-2097）
  // 这些不经 settingsContext.refresh 的外部事件源，由读它们的分组自己订阅
  // （SettingsSection.liveListenable），宿主页不再整页 setState——此前调试日志
  // 开着时每条 debugPrint 都会把整页设置行重建一遍。

  /// 「不可见就退回去」只调度一次：build 每帧都会重跑，不设这个闸门就会往
  /// 队列里堆一串 pop，把上层页面一并弹掉。
  bool _popScheduled = false;

  /// 分类在本页停留期间变得不可见（用户在设置 → 外观 → 功能模块里关掉了它所属的
  /// 模块，或平台能力消失）时，退回上一层。
  ///
  /// 详情页是 push 上来的独立路由，[_freshDestination] 只按 id 找回最新声明、不判
  /// 可见性，于是关掉模块后这一页仍会整页渲染——「看不见也到不了」在这条路径上漏了。
  /// pop 而不是渲染空态：上一层（设置主页 / 引它进来的正文页）的列表本身已按
  /// `isVisible` 过滤，退回去就是干净状态，也不用新增一句空态文案。
  void _popInvisibleDestination() {
    if (_popScheduled) return;
    _popScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      final NavigatorState navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final SettingsContext settingsContext =
        createSettingsContext(appModel: appModel, ref: ref);
    final SettingsDestination destination = _freshDestination(settingsContext);
    if (!destination.isVisible(settingsContext)) {
      _popInvisibleDestination();
      // 本帧还得返回点什么；pop 在帧末执行，用户看不到这一帧的空白。
      return const SizedBox.shrink();
    }
    // 「玻璃」设计系统：iOS / macOS 设置详情（见 GlassSettingsRenderer）。
    if (isGlassDesign(context) && !isCupertinoPlatform(context)) {
      return const GlassSettingsRenderer().buildDetailPage(
        settingsContext: settingsContext,
        destination: destination,
      );
    }
    if (isCupertinoPlatform(context)) {
      return const CupertinoSettingsRenderer().buildDetailPage(
        settingsContext: settingsContext,
        destination: destination,
      );
    }
    return const MaterialSettingsRenderer().buildDetailPage(
      settingsContext: settingsContext,
      destination: destination,
    );
  }

  SettingsDestination _freshDestination(SettingsContext settingsContext) {
    final SettingsDestination Function()? subPage = widget.subPageBuilder;
    if (subPage != null) return subPage();
    final SettingsDestination top = widget.destination!;
    for (final SettingsDestination destination
        in buildSettingsSchema(settingsContext)) {
      if (destination.id == top.id) return destination;
    }
    return top;
  }
}
