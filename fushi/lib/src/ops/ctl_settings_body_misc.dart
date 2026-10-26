import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/misc/app_icon_apply.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart';
import 'package:fushi/utils.dart';

/// 应用图标页（`MiscellaneousSettingsPage`，「外观 › 应用图标」，正文是图标网格
/// 走 body 逃生口）在控制通道上的条目。
///
/// - `appearance.app_icon.cli.icon`：读当前图标（预设 key 或 `custom`），写预设 key
///   切换（`fushi_cli config set appearance.app_icon.cli.icon default`）；
/// - `appearance.app_icon.cli.set_custom`：`--arg path=<图片>` 设自定义图标。
///   页面里的 1:1 裁剪是交互步骤，CLI 直接用给出的图片（请先裁成正方形）。
///
/// 业务与页面同一份：`app_icon_apply.dart` 的 [applyPresetAppIcon] /
/// [applyCustomAppIcon]。同页的「图标跟随主题色 / 主题色跟随图标」开关已在
/// schema 里（`appearance.tint_app_logo` / `appearance.follow_app_icon_accent`）。
const String kCtlAppIconIdPrefix = 'appearance.app_icon.cli.';

List<CtlBodyPage> buildCtlMiscBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: '${t.settings_destination_appearance} › ${t.app_icon_label}',
    visible: (SettingsContext _) => appIconSwitchSupported,
    items: <SettingsItem>[
      SettingsCustomItem(
        id: '${kCtlAppIconIdPrefix}icon',
        builder: (SettingsContext _) => const SizedBox.shrink(),
        searchTitle: t.app_icon_presets,
        cliValue: SettingsCliValue(
          read: (SettingsContext _) => currentAppIconSelection.value.presetKey,
          write: _writePresetIcon,
          help:
              '预设图标 key（${presetIconAssets.keys.join(' / ')}）；'
              '自定义图片用 `config run ${kCtlAppIconIdPrefix}set_custom`',
          options: (SettingsContext _) => presetIconAssets.keys.toList(),
        ),
      ),
      SettingsActionItem(
        id: '${kCtlAppIconIdPrefix}set_custom',
        title: t.icon_custom,
        subtitle: t.icon_custom_confirm_body,
        onTap: (SettingsContext _) {},
        cli: SettingsCliAction(
          run: _setCustomIcon,
          params: const <SettingsCliParam>[
            SettingsCliParam(
              'path',
              help: '图标图片绝对路径（按正方形渲染，非正方形会被拉伸，请先裁好）',
              path: true,
            ),
          ],
        ),
      ),
    ],
  ),
];

Future<void> _writePresetIcon(SettingsContext _, String raw) async {
  final String key = raw.trim();
  final bool ok = await applyPresetAppIcon(key);
  if (!ok) {
    throw StateError('系统拒绝切换应用图标（原生图标接口返回失败）');
  }
}

Future<Object?> _setCustomIcon(
  SettingsContext _,
  Map<String, String> args,
) async {
  final String path = args['path']!.trim();
  if (!File(path).isAbsolute) {
    throw ArgumentError('path 必须是绝对路径：$path');
  }
  final bool ok = await applyCustomAppIcon(path);
  if (!ok) {
    throw StateError(
      Platform.isAndroid ? t.icon_shortcut_unsupported : '系统拒绝设置窗口图标',
    );
  }
  final AppIconSelection current = currentAppIconSelection.value;
  return <String, Object?>{
    'ok': true,
    'preset': current.presetKey,
    'customPath': current.customPath,
    if (Platform.isAndroid) 'note': t.icon_shortcut_created,
  };
}
