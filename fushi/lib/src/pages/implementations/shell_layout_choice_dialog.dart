/// 「选一种库页布局」：升级上来、从没选过库页布局的老用户首页弹一次（设计稿
/// G1）。
///
/// 拼贴成了新默认，但老用户不能被静默切过去：他们升级后先保持封面网格（出厂判定
/// 见 `ShellLayoutInstallDefault`），首页首帧串在新手引导之后弹这个框。「用这个」
/// 写入所选布局，「稍后再说」/ 关掉框保持封面网格，两种都记成已处理、之后不再弹；
/// 随时可在 设置 › 外观 › 库页布局 里改。新安装不弹（新手引导欢迎页里选）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/shell_style_preview.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 要不要弹：还没处理过（[pending]）且重设计外壳此刻生效（[redesignActive]，
/// 墨水屏库页恒为封面网格，问了也看不到效果——留着待处理，离开墨水屏后再问）。
bool shouldShowShellLayoutChoice({
  required bool pending,
  required bool redesignActive,
}) => pending && redesignActive;

/// 首页首帧调用：该弹就弹一次，并把用户的选择交给 `ThemeNotifier`。
Future<void> maybeShowShellLayoutChoice({
  required BuildContext context,
  required AppModel appModel,
}) async {
  if (!shouldShowShellLayoutChoice(
    pending: appModel.themeNotifier.shellLayoutChoicePending,
    redesignActive: shellRedesignActive(context),
  )) {
    return;
  }
  final List<ShellPreviewCover> covers = shellPreviewCoversNow(
    context,
    appModel,
  );
  final ShellContentLayout? chosen = await showAppDialog<ShellContentLayout>(
    context: context,
    builder: (BuildContext dialogContext) => ShellLayoutChoiceDialog(
      arrangement: appModel.shellBlockArrangement,
      covers: covers,
      onConfirm: (ShellContentLayout layout) =>
          Navigator.of(dialogContext).pop(layout),
      onLater: () => Navigator.of(dialogContext).pop(),
    ),
  );
  // null =「稍后再说」或关掉了框：保持出厂的封面网格，同样记成已处理。
  await appModel.themeNotifier.resolveShellLayoutChoice(chosen);
}

/// 选择框本体：两张库页布局预览卡（复用设置页的 [ShellLayoutChoiceCards]），
/// 默认高亮拼贴。
class ShellLayoutChoiceDialog extends StatefulWidget {
  const ShellLayoutChoiceDialog({
    required this.arrangement,
    required this.onConfirm,
    required this.onLater,
    this.covers = const <ShellPreviewCover>[],
    this.initial = ShellContentLayout.collage,
    super.key,
  });

  /// 拼贴卡里色块的摆放（跟着当前设置）。
  final ShellBlockArrangement arrangement;

  /// 书库前几张封面（[shellPreviewCoversNow]）；空 = 画主题色块。
  final List<ShellPreviewCover> covers;

  /// 打开时高亮的布局。
  final ShellContentLayout initial;

  /// 「用这个」。
  final ValueChanged<ShellContentLayout> onConfirm;

  /// 「稍后再说」。
  final VoidCallback onLater;

  @override
  State<ShellLayoutChoiceDialog> createState() =>
      _ShellLayoutChoiceDialogState();
}

class _ShellLayoutChoiceDialogState extends State<ShellLayoutChoiceDialog> {
  late ShellContentLayout _selected = widget.initial;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return FushiAlertDialog(
      key: const ValueKey<String>('shell_layout_choice'),
      title: Text(t.library_layout_choice_title),
      scrollable: true,
      // 定宽而不是只给上限：AlertDialog 把内容包在 IntrinsicWidth 里量宽度，选择卡
      // 内部按可用宽度排列（LayoutBuilder），不支持固有尺寸查询；定宽让量宽在这一
      // 层直接得到答案，窄屏下仍被对话框的约束收窄。
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.library_layout_choice_body(
                settings: t.settings,
                appearance: t.settings_destination_appearance,
                layout: t.library_layout,
              ),
              style: context.fushiType.bodyMedium.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            ShellLayoutChoiceCards(
              selected: _selected,
              arrangement: widget.arrangement,
              covers: widget.covers,
              collageLabel: t.library_layout_collage_new_label,
              gridLabel: t.library_layout_grid_classic_label,
              previewHeight: 120,
              onSelected: (ShellContentLayout layout) =>
                  setState(() => _selected = layout),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('shell_layout_choice_later'),
          onPressed: widget.onLater,
          child: Text(t.library_layout_choice_later),
        ),
        FushiFilledButton(
          key: const ValueKey<String>('shell_layout_choice_confirm'),
          onPressed: () => widget.onConfirm(_selected),
          child: Text(t.library_layout_choice_confirm),
        ),
      ],
    );
  }
}
