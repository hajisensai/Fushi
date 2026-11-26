import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/platform/desktop/desktop_tray.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 关闭询问框的结果：选了哪一种（只会是 [DesktopCloseAction.tray] 或
/// [DesktopCloseAction.exit]），以及要不要记住。
@immutable
class DesktopClosePromptResult {
  const DesktopClosePromptResult({
    required this.action,
    required this.remember,
  });

  final DesktopCloseAction action;
  final bool remember;
}

/// 「关闭窗口时：每次询问」下，用户点关闭按钮 / Alt+F4 弹的询问框。
///
/// 返回 null = 取消（点遮罩 / Esc / 取消键），窗口留着什么都不做。主键是「最小化到
/// 托盘」（Enter 直接收进托盘）；勾了「记住我的选择」以后不再询问，可在
/// 「设置 › 系统」改回来。
Future<DesktopClosePromptResult?> showDesktopClosePrompt(BuildContext context) {
  return showAppDialog<DesktopClosePromptResult>(
    context: context,
    builder: (BuildContext dialogContext) => const _DesktopClosePrompt(),
  );
}

class _DesktopClosePrompt extends StatefulWidget {
  const _DesktopClosePrompt();

  @override
  State<_DesktopClosePrompt> createState() => _DesktopClosePromptState();
}

class _DesktopClosePromptState extends State<_DesktopClosePrompt> {
  bool _remember = false;

  void _pick(DesktopCloseAction action) {
    Navigator.of(
      context,
    ).pop(DesktopClosePromptResult(action: action, remember: _remember));
  }

  @override
  Widget build(BuildContext context) {
    return FushiAlertDialog(
      icon: const FushiDialogHeroIcon(icon: FushiIcons.close),
      title: Text(t.desktop_close_prompt_title),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.desktop_close_prompt_message),
          const SizedBox(height: 8),
          FushiCheckboxListTile(
            key: const ValueKey<String>('desktop-close-remember'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _remember,
            title: Text(t.desktop_close_prompt_remember),
            subtitle: Text(t.desktop_close_prompt_remember_hint),
            onChanged: (bool? value) =>
                setState(() => _remember = value ?? false),
          ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          key: const ValueKey<String>('desktop-close-cancel'),
          label: t.dialog_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('desktop-close-exit'),
          label: t.desktop_tray_quit,
          onPressed: () => _pick(DesktopCloseAction.exit),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('desktop-close-tray'),
          label: t.desktop_close_action_tray,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed: () => _pick(DesktopCloseAction.tray),
        ),
      ],
    );
  }
}
