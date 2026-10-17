import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_dialog_color_picker.dart';

import 'package:fushi/src/settings/settings_cli_values.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 桌面浮窗（galgame hook 台词浮窗 / 有声书悬浮字幕）共用的颜色设置行。
///
/// 两种浮窗是同一个原生窗类，颜色语义也一样：偏好里某个约定值代表「跟随主题」
/// （色样显示主题配对色、副标题标明在跟随），其余值是用户自选色。差别只在
/// 「哪个存储值算跟随」和「跟随时取主题里的哪一色」，由调用方传入。
///
/// - [followThemeValue]：写回它 = 回到跟随主题（「恢复默认」与取色框里的
///   「跟随主题」按钮都写它）。
/// - [followsTheme]：存储值是否视为跟随（galgame 侧兼容历史默认值，所以不是
///   简单的 `== followThemeValue`）。
/// - [themedColor]：跟随时实际下发的颜色——必须与浮窗下发同一个函数，保证
///   「设置页看到的颜色 = 浮窗画出来的颜色」。
/// - [commit]：写偏好 + 推样式 + 刷新设置页。
SettingsCustomItem overlayColorSettingItem({
  required String id,
  required String title,
  required IconData icon,
  required int followThemeValue,
  required bool Function(int stored) followsTheme,
  required int Function(SettingsContext context) value,
  required int Function(ThemeData theme) themedColor,
  required Future<void> Function(SettingsContext context, int value) commit,
  bool Function(SettingsContext context)? visible,
  bool enableAlpha = false,
}) {
  return SettingsCustomItem(
    id: id,
    icon: icon,
    searchTitle: title,
    visible: visible,
    // 「恢复默认」= 回到跟随主题；收在详情页的「恢复本页默认」里，行内不再画
    // 已改过标记。
    reset: SettingsCustomReset(
      isModified: (SettingsContext context) => !followsTheme(value(context)),
      reset: (SettingsContext context) => commit(context, followThemeValue),
      currentLabel: (SettingsContext context) {
        final int stored = value(context);
        return followsTheme(stored)
            ? t.theme_role_follows_theme
            : '#${stored.toRadixString(16).padLeft(8, '0').toUpperCase()}';
      },
      defaultLabel: (SettingsContext context) => t.theme_role_follows_theme,
    ),
    // 控制通道：`theme` = 跟随主题（写回 followThemeValue），否则 #AARRGGBB；
    // 写入走同一个 commit（写偏好 + 推样式到浮窗）。
    cliValue: SettingsCliValue(
      help: '$kSettingsCliFollowTheme（跟随主题）或 #RRGGBB / #AARRGGBB',
      read: (SettingsContext context) {
        final int stored = value(context);
        return followsTheme(stored)
            ? kSettingsCliFollowTheme
            : formatSettingsCliColor(stored);
      },
      write: (SettingsContext context, String raw) {
        if (raw.trim().toLowerCase() == kSettingsCliFollowTheme) {
          return commit(context, followThemeValue);
        }
        final int argb = parseSettingsCliColor(raw);
        return commit(context, enableAlpha ? argb : (0xFF000000 | argb));
      },
    ),
    builder: (SettingsContext settingsContext) {
      final ThemeData theme = Theme.of(settingsContext.context);
      final int stored = value(settingsContext);
      final bool following = followsTheme(stored);
      final Color current = Color(following ? themedColor(theme) : stored);
      final ColorScheme colors = theme.colorScheme;
      return AdaptiveSettingsRow(
        title: title,
        subtitle: following ? t.theme_role_follows_theme : null,
        icon: icon,
        showIcon: true,
        // M3E 色样：28 圆点 + outlineVariant 描边（浅色 / 透明色在卡片底上也
        // 读得出边界）。
        trailing: FushiColorSwatch(
          color: current,
          size: 28,
          shape: FushiColorSwatchShape.dot,
          borderColor: colors.outlineVariant,
        ),
        onTap: () => unawaited(() async {
          final _OverlayColorChoice? choice = await _pickOverlayColor(
            settingsContext.context,
            title: title,
            initial: current,
            enableAlpha: enableAlpha,
            offerFollowTheme: !following,
          );
          if (choice == null) return;
          if (choice.followTheme) {
            await commit(settingsContext, followThemeValue);
            return;
          }
          final int selected = choice.color!.toARGB32();
          // 跟随中直接按「完成」= 没改：不把此刻的主题色冻结成自定义值。
          if (selected == stored || selected == current.toARGB32()) return;
          await commit(settingsContext, selected);
        }()),
      );
    },
  );
}

class _OverlayColorChoice {
  const _OverlayColorChoice.color(Color this.color) : followTheme = false;
  const _OverlayColorChoice.followTheme() : color = null, followTheme = true;

  final Color? color;
  final bool followTheme;
}

Future<_OverlayColorChoice?> _pickOverlayColor(
  BuildContext context, {
  required String title,
  required Color initial,
  required bool enableAlpha,
  required bool offerFollowTheme,
}) async {
  Color picked = initial;
  _OverlayColorChoice? choice;
  await showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      title: Text(title),
      content: FushiDialogColorPicker(
        pickerColor: initial,
        onColorChanged: (Color color) {
          picked = enableAlpha
              ? color
              : Color(0xFF000000 | (color.toARGB32() & 0x00FFFFFF));
        },
        enableAlpha: enableAlpha,
      ),
      actions: <Widget>[
        if (offerFollowTheme)
          FushiTextButton(
            onPressed: () {
              choice = const _OverlayColorChoice.followTheme();
              Navigator.of(dialogContext).pop();
            },
            child: Text(t.theme_role_follows_theme),
          ),
        FushiTextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(t.dialog_cancel),
        ),
        FushiFilledButton(
          onPressed: () {
            choice = _OverlayColorChoice.color(picked);
            Navigator.of(dialogContext).pop();
          },
          child: Text(t.dialog_done),
        ),
      ],
    ),
  );
  return choice;
}
