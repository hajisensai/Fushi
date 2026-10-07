import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

// 页级「恢复本页默认」：普通 schema 设置页的行保持标准 M3E 列表项（不画「改过
// 默认值」圆点、行尾不追加撤销钮），恢复默认收进详情页页头的溢出菜单。判据与
// 恢复动作只有 settings_kit 的 [settingsResetSpecFor] 一份。快捷键设置页有自己
// 的逐条标记与恢复，不走这里。

/// 本页一条可恢复默认的设置项（已解析标题与 [SettingsResetSpec]）。
class SettingsPageResetEntry {
  const SettingsPageResetEntry({
    required this.item,
    required this.title,
    required this.spec,
  });

  final SettingsItem item;
  final String title;
  final SettingsResetSpec spec;
}

/// [sections]（含折叠分组）里所有声明了默认值的可见项，按页面顺序。
List<SettingsPageResetEntry> settingsPageResetEntries(
  List<SettingsSection> sections,
  SettingsContext settingsContext,
) {
  return <SettingsPageResetEntry>[
    for (final SettingsSection section in sections)
      for (final SettingsItem item in section.items)
        if (item.isVisible(settingsContext))
          if (settingsResetSpecFor(item, settingsContext)
              case final SettingsResetSpec spec)
            SettingsPageResetEntry(
              item: item,
              title: settingsItemSearchTitle(item, settingsContext),
              spec: spec,
            ),
  ];
}

/// 详情页页头的溢出菜单：唯一一项「恢复本页默认」。本页没有任何声明了默认值
/// 的项时整个按钮不出现；有但都没改过时菜单项禁用并写「本页均为默认值」。
class SettingsPageResetAction extends StatelessWidget {
  const SettingsPageResetAction({
    required this.settingsContext,
    required this.destination,
    super.key,
  });

  final SettingsContext settingsContext;
  final SettingsDestination destination;

  @override
  Widget build(BuildContext context) {
    final List<SettingsPageResetEntry> entries = settingsPageResetEntries(
      destination.visibleSections(settingsContext),
      settingsContext,
    );
    if (entries.isEmpty) return const SizedBox.shrink();
    final bool anyModified = entries.any(
      (SettingsPageResetEntry entry) => entry.spec.modified,
    );
    return FushiOverflowMenu<int>(
      key: const ValueKey<String>('settings-page-reset-menu'),
      tooltip: t.common_more_actions,
      items: <PopupMenuEntry<int>>[
        FushiPopupMenuItem<int>(
          key: const ValueKey<String>('settings-page-reset-item'),
          value: 0,
          icon: FushiIcons.undo,
          label: anyModified
              ? t.settings_page_reset_menu
              : t.settings_page_reset_all_default,
          enabled: anyModified,
        ),
      ],
      onSelected: (int _) => showSettingsPageResetDialog(
        context: context,
        settingsContext: settingsContext,
        destination: destination,
      ),
    );
  }
}

/// 列出本页改过默认值的项（标题 + 当前值 → 默认值），默认全选、可逐项取消，
/// 确认后按页面顺序逐项调用 [SettingsResetSpec.reset]。返回实际恢复的条数。
Future<int> showSettingsPageResetDialog({
  required BuildContext context,
  required SettingsContext settingsContext,
  required SettingsDestination destination,
}) async {
  // 打开时重新取一次：菜单是上一帧建的，值可能已经变了。
  final List<SettingsPageResetEntry> modified = settingsPageResetEntries(
    destination.visibleSections(settingsContext),
    settingsContext,
  ).where((SettingsPageResetEntry entry) => entry.spec.modified).toList();
  if (modified.isEmpty) return 0;
  final Set<String>? chosen = await showAppDialog<Set<String>>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _SettingsPageResetDialog(entries: modified),
  );
  if (chosen == null || chosen.isEmpty) return 0;
  int count = 0;
  for (final SettingsPageResetEntry entry in modified) {
    if (!chosen.contains(entry.item.id)) continue;
    await entry.spec.reset();
    count++;
  }
  return count;
}

class _SettingsPageResetDialog extends StatefulWidget {
  const _SettingsPageResetDialog({required this.entries});

  final List<SettingsPageResetEntry> entries;

  @override
  State<_SettingsPageResetDialog> createState() =>
      _SettingsPageResetDialogState();
}

class _SettingsPageResetDialogState extends State<_SettingsPageResetDialog> {
  late final Set<String> _selected = <String>{
    for (final SettingsPageResetEntry entry in widget.entries) entry.item.id,
  };

  @override
  Widget build(BuildContext context) {
    return FushiAlertDialog(
      key: const ValueKey<String>('settings-page-reset-dialog'),
      icon: const FushiDialogHeroIcon(
        icon: FushiIcons.undo,
        tone: FushiHeroTone.neutral,
      ),
      title: Text(t.settings_page_reset_menu),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.settings_page_reset_message),
          const SizedBox(height: 8),
          for (final SettingsPageResetEntry entry in widget.entries)
            FushiCheckboxListTile(
              key: ValueKey<String>('settings-page-reset.${entry.item.id}'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _selected.contains(entry.item.id),
              title: Text(entry.title),
              subtitle: Text(
                '${entry.spec.currentLabel} → ${entry.spec.defaultLabel}',
              ),
              onChanged: (bool? value) => setState(() {
                if (value ?? false) {
                  _selected.add(entry.item.id);
                } else {
                  _selected.remove(entry.item.id);
                }
              }),
            ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('settings-page-reset-confirm'),
          label: t.settings_page_reset_confirm,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(Set<String>.of(_selected)),
        ),
      ],
    );
  }
}
