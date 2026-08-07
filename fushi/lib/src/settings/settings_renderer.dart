import 'package:flutter/widgets.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';

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

  Widget buildDetailPage({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
  });

  /// [insetHorizontally] — 详情正文是否自带水平内边距。默认 true（渲染器拥有横向
  /// 留白，用于主页 master-detail / 全屏详情等自持滚动容器）。当详情被嵌进一个已
  /// 经提供横向 padding 的父容器时（书内快捷设置面板的宽/窄 pane），调用方传 false，
  /// 让渲染器只保留纵向内边距、把横向留白交给外层——否则会双重缩进，使 schema 投影
  /// 子页比同面板里 bespoke 的「导航 / 有声书」子页更窄（TODO-1321）。Cupertino 渲染
  /// 器本就无横向内边距，此参数对其为 no-op。
  Widget buildDetailContent({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
    ScrollController? scrollController,
    bool shrinkWrap = false,
    bool insetHorizontally = true,
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
