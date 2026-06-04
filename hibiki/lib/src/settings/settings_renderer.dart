import 'package:flutter/widgets.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';

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

  Widget buildDetailContent({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
    ScrollController? scrollController,
    bool shrinkWrap = false,
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
