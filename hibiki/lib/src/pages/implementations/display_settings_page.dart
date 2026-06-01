import 'package:flutter/material.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/utils.dart';

/// 阅读显示设置页：薄壳，直接投影 reading destination 的显示相关 section
/// （排版 / 布局 / 高级排版），不含导航/行为 section。所有写路径都走 schema
/// item 的 `setTtu*` + `notifyReaderSettingsChanged`，与其它设置入口共用同一
/// 存储与实时更新链路。
class DisplaySettingsPage extends BasePage {
  const DisplaySettingsPage({super.key});

  @override
  BasePageState createState() => _DisplaySettingsPageState();
}

class _DisplaySettingsPageState extends BasePageState {
  @override
  Widget build(BuildContext context) {
    final SettingsContext settingsContext = SettingsContext(
      context: context,
      appModel: appModel,
      ref: ref,
      readerSource: ReaderHibikiSource.instance,
      refresh: () {
        if (mounted) setState(() {});
      },
    );

    final SettingsDestination? reading = buildSettingsSchema(settingsContext)
        .cast<SettingsDestination?>()
        .firstWhere(
          (SettingsDestination? d) => d!.id == SettingsDestinationId.reading,
          orElse: () => null,
        );

    // 过滤掉导航 section（标题为 t.section_navigation，含 reading_controls.* 行为项），
    // 只保留显示相关 section。
    final List<SettingsSection> displaySections = reading == null
        ? const <SettingsSection>[]
        : reading.sections
            .where((SettingsSection s) => s.title != t.section_navigation)
            .toList(growable: false);

    final SettingsDestination destination = SettingsDestination(
      id: SettingsDestinationId.reading,
      title: t.display_settings,
      icon: Icons.auto_stories_outlined,
      sections: displaySections,
    );

    final bool cupertino = isCupertinoPlatform(context);
    final SettingsRenderer renderer = cupertino
        ? const CupertinoSettingsRenderer()
        : const MaterialSettingsRenderer();

    return AdaptiveSettingsScaffold(
      title: Text(t.display_settings),
      children: <Widget>[
        renderer.buildDetailContent(
          settingsContext: settingsContext,
          destination: destination,
          shrinkWrap: true,
        ),
      ],
    );
  }
}
