import 'package:flutter/widgets.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

/// 设置渲染器的**唯一**选择点兼唯一构造点：玻璃 → [GlassSettingsRenderer]，
/// 其余 → MD3 [MaterialSettingsRenderer]。设置主页、详情页、模块设置页签、
/// 快捷设置弹窗都调这里，不各自再判设计系统、也不自己 new 渲染器
/// （`settings_renderer_single_resolver_guard_test.dart` 守着：lib 里别处出现
/// 渲染器构造或第三个 [SettingsRenderer] 实现即红）。
///
/// [showDetailHeader]：宽屏主从的详情窗格顶上画当前分类的大标题，只有设置
/// 主页的宽屏布局传 true。
SettingsRenderer resolveSettingsRenderer(
  BuildContext context, {
  bool showDetailHeader = false,
}) {
  return isGlassDesign(context)
      ? GlassSettingsRenderer(showDetailHeader: showDetailHeader)
      : MaterialSettingsRenderer(showDetailHeader: showDetailHeader);
}

abstract class SettingsRenderer {
  Widget buildHomePage({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required SettingsDestinationId selectedDestinationId,
    required ValueChanged<SettingsDestinationId> onDestinationSelected,
    bool embedded = false,
  });

  Widget buildDestinationList({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required SettingsDestinationId selectedDestinationId,
    required ValueChanged<SettingsDestinationId> onDestinationSelected,
    bool pushRoutes = true,
  });

  /// 窄屏单列的分类分组（不带滚动容器，由设置主页塞进自己的滚动视图）。
  Widget buildDestinationGroups({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required ValueChanged<SettingsDestinationId> onDestinationSelected,
  });

  Widget buildDetailPage({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
  });

  /// [insetHorizontally] — 详情正文是否自带水平内边距。默认 true（渲染器拥有横向
  /// 留白，用于主页 master-detail / 全屏详情等自持滚动容器）。当详情被嵌进一个已
  /// 经提供横向 padding 的父容器时（书内快捷设置面板的宽/窄 pane），调用方传 false，
  /// 让渲染器只保留纵向内边距、把横向留白交给外层——否则会双重缩进，使 schema 投影
  /// 子页比同面板里 bespoke 的「导航 / 有声书」子页更窄（TODO-1321）。
  ///
  /// [consumeTopPadding] — 自滚动正文是否把 `MediaQuery` 顶部 padding 加进自己的
  /// 顶部内边距（与底部安全区同一约定）。库页外壳的「设置」分区传 true：外壳经
  /// `FushiFloatingChromeScrollInset` 把浮动工具区的让位高度交成 MediaQuery 顶部
  /// padding，正文从工具区下方开始、往下滚时滚到工具区底下，工具区收起后顶部不留
  /// 空白。默认 false，其它宿主行为不变。
  Widget buildDetailContent({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
    ScrollController? scrollController,
    bool shrinkWrap = false,
    bool insetHorizontally = true,
    bool consumeTopPadding = false,
  });

  /// 把一个 [SettingsSection] 的可见项渲染成「裸行」列表（不含卡片容器、不含
  /// ListView/整页内边距），供调用方塞进自己的 [AdaptiveSettingsSection] 与其它
  /// bespoke 行拼成同一张卡。用于书内快捷面板把主题行 + appearance schema 行 +
  /// 编辑书籍CSS 合并成一张等宽卡片。
  List<Widget> buildSectionRows({
    required SettingsContext settingsContext,
    required SettingsSection section,
    bool showIcons = true,
  });
}
