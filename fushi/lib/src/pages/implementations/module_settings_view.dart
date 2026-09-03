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

    // BUG-1658：不再包 DesktopContentLayout(settings)。共享的分段导航页头由六个
    // 分区轮流渲染，其余分区（库页/发现/导入）都是 readerShelf 全出血 + 页头自身
    // spacing.page 内边距；这里再叠 16/24px 侧向留白 + 宽屏 960 居中限宽，会让
    // 切到「设置」时顶栏选择条整体偏移、宽度包络也不同。页头与兄弟分区同构对齐，
    // 正文横向缩进由 renderer 的 detailHorizontalInsets 自持（与「导入」分区的
    // 文字流处理同源）；全局设置主页（settings_home_page.dart）仍走
    // DesktopContentKind.settings，不受影响。
    return Column(
      children: <Widget>[
        FushiPageHeader.customTitle(title: widget.navigation),
        Expanded(
          child: renderer.buildDetailContent(
            settingsContext: settingsContext,
            destination: destination,
          ),
        ),
      ],
    );
  }
}
