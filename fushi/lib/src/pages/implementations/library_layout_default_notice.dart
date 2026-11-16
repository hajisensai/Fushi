/// 库页默认布局从拼贴改成封面网格（PR #3454，2026-11-15）后的一次性提示。
///
/// 没选过布局的存量用户升级后库页会从拼贴变成封面网格。维护者在拍板台
/// （`pr3454`，2026-11-16）定：默认值照改，更新后提醒一次「拼贴仍可选」。
/// 提示里给一键换回拼贴，也写明设置里的位置。
///
/// 「只对升级上来、没选过布局的用户」靠**首次启动新版时就落标记**实现：全新安装、
/// 显式选过布局（含已删的 `blocks`）、墨水屏（库页布局恒为封面网格、设置项隐藏）
/// 在第一次判定时直接记成已处理；之后才落到默认值的人不会再被提示。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 一次判定的结果。
enum LibraryLayoutDefaultNoticeDecision {
  /// 已处理过：什么都不做。
  none,

  /// 本安装不需要提示（全新安装 / 显式选过布局 / 库页布局不生效）：只落标记。
  markHandled,

  /// 升级上来、从没选过布局（此前看到的是拼贴）的用户：弹一次提示再落标记。
  show,
}

/// 纯判定（测试钉住）：[handled] 是已处理标记，[freshInstall] 是本次启动是否
/// 全新安装，[layoutChosen] 是当前 Profile 是否显式选过库页布局，
/// [layoutActive] 是库页布局此刻是否生效（墨水屏恒为封面网格、设置项隐藏）。
LibraryLayoutDefaultNoticeDecision decideLibraryLayoutDefaultNotice({
  required bool handled,
  required bool freshInstall,
  required bool layoutChosen,
  required bool layoutActive,
}) {
  if (handled) return LibraryLayoutDefaultNoticeDecision.none;
  if (freshInstall || layoutChosen || !layoutActive) {
    return LibraryLayoutDefaultNoticeDecision.markHandled;
  }
  return LibraryLayoutDefaultNoticeDecision.show;
}

/// 首页首帧调用：按判定弹提示 / 落标记。标记在弹框**之前**落：弹框期间杀进程
/// 也不会下次再弹一遍（提示只是告知，换回拼贴随时可在设置里做）。
Future<void> maybeShowLibraryLayoutDefaultNotice({
  required BuildContext context,
  required AppModel appModel,
  required bool freshInstall,
}) async {
  final LibraryLayoutDefaultNoticeDecision decision =
      decideLibraryLayoutDefaultNotice(
        handled: appModel.libraryLayoutDefaultNoticeHandled,
        freshInstall: freshInstall,
        layoutChosen: appModel.shellContentLayoutChosen,
        layoutActive: shellRedesignActive(context),
      );
  if (decision == LibraryLayoutDefaultNoticeDecision.none) return;
  await appModel.setLibraryLayoutDefaultNoticeHandled();
  if (decision != LibraryLayoutDefaultNoticeDecision.show || !context.mounted) {
    return;
  }
  final bool useCollage = await showLibraryLayoutDefaultNoticeDialog(context);
  if (useCollage) {
    await appModel.setShellContentLayout(ShellContentLayout.collage);
  }
}

/// 提示框本体；返回 true = 用户点了「换成拼贴」。路径里的每一段都取设置页真实
/// 显示的标签（外观分类、库页布局行、拼贴选项），改名时这里自动跟着变。
Future<bool> showLibraryLayoutDefaultNoticeDialog(BuildContext context) async {
  final bool? result = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      key: const ValueKey<String>('library_layout_default_notice'),
      icon: const FushiIcon(FushiIcons.widgets),
      title: Text(
        t.library_layout_default_notice_title(grid: t.library_layout_grid),
      ),
      content: Text(
        t.library_layout_default_notice_body(
          collage: t.library_layout_collage,
          settings: t.settings,
          appearance: t.settings_destination_appearance,
          layout: t.library_layout,
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('library_layout_default_notice_keep'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(
            t.library_layout_default_notice_keep(grid: t.library_layout_grid),
          ),
        ),
        FushiTextButton(
          key: const ValueKey<String>('library_layout_default_notice_collage'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            t.library_layout_default_notice_try(
              collage: t.library_layout_collage,
            ),
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}
