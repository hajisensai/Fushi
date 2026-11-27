/// 「跟随某个主题色 / 自选色」两态颜色设置共用的取色对话框：整块取色器
/// （[FushiDialogColorPicker]）+「跟随」/ 取消 / 完成。桌面浮窗颜色行
/// （overlay_color_setting_item.dart）与复习卡外观的注音颜色共用这一份。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_dialog_color_picker.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 取色对话框的结果：选了一个颜色，或选了「跟随」。
@immutable
class FushiFollowableColorChoice {
  const FushiFollowableColorChoice.color(Color this.color)
    : followTheme = false;
  const FushiFollowableColorChoice.followTheme()
    : color = null,
      followTheme = true;

  /// 选中的颜色（[followTheme] 时为 null）。
  final Color? color;

  /// 用户点了「跟随」按钮。
  final bool followTheme;
}

/// 弹出取色对话框；取消 / 点外部关闭返回 null。
///
/// [followLabel] 非空时多一个「跟随」按钮（调用方在已经跟随时传 null，不重复给）。
/// [enableAlpha] 关时结果强制不透明。
Future<FushiFollowableColorChoice?> showFushiFollowableColorDialog(
  BuildContext context, {
  required String title,
  required Color initial,
  bool enableAlpha = false,
  String? followLabel,
}) async {
  Color picked = initial;
  FushiFollowableColorChoice? choice;
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
        if (followLabel != null)
          FushiTextButton(
            onPressed: () {
              choice = const FushiFollowableColorChoice.followTheme();
              Navigator.of(dialogContext).pop();
            },
            child: Text(followLabel),
          ),
        FushiTextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(t.dialog_cancel),
        ),
        FushiFilledButton(
          onPressed: () {
            choice = FushiFollowableColorChoice.color(picked);
            Navigator.of(dialogContext).pop();
          },
          child: Text(t.dialog_done),
        ),
      ],
    ),
  );
  return choice;
}
