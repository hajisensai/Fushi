import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/settings/cupertino_settings_renderer.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_renderer.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/utils.dart';

/// 在媒体/游戏模块自己的顶部页签内嵌一个 schema 设置分类。
///
/// 设置项仍来自全局 [buildSettingsSchema]，所以这里不会复制第二套开关、持久化或
/// 平台门控。外层只负责保留模块的分段导航页头；正文交给与设置主页相同的 renderer。
class ModuleSettingsView extends ConsumerStatefulWidget {
  const ModuleSettingsView({
    required this.destinationId,
    required this.navigation,
    super.key,
  });

  final SettingsDestinationId destinationId;
  final Widget navigation;

  @override
  ConsumerState<ModuleSettingsView> createState() => _ModuleSettingsViewState();
}

class _ModuleSettingsViewState extends ConsumerState<ModuleSettingsView>
    with SettingsContextHost<ModuleSettingsView> {
  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    final SettingsContext settingsContext = createSettingsContext(
      appModel: appModel,
      ref: ref,
    );
    final SettingsDestination destination = buildSettingsSchema(
      settingsContext,
    ).firstWhere(
      (SettingsDestination destination) =>
          destination.id == widget.destinationId,
    );
    final SettingsRenderer renderer = isCupertinoPlatform(context)
        ? const CupertinoSettingsRenderer()
        : const MaterialSettingsRenderer();

    return DesktopContentLayout(
      kind: DesktopContentKind.settings,
      child: Column(
        children: <Widget>[
          HibikiPageHeader.customTitle(title: widget.navigation),
          Expanded(
            child: renderer.buildDetailContent(
              settingsContext: settingsContext,
              destination: destination,
            ),
          ),
        ],
      ),
    );
  }
}
