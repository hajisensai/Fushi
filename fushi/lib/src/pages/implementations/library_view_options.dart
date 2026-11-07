import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/library_grid_columns.dart';
import 'package:fushi/src/pages/implementations/library_filter_panel.dart'
    show LibraryFilterSection;
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart'
    show LibraryViewOption, LibraryViewSection;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

// 库页「排序与显示」（书架 / 漫画 / 视频 / 游戏，2026-11-07 用户拍板）。
//
// 宽窗：页头排序按钮下的锚定菜单（[FushiTagFilterBar] / 游戏库自己的排序菜单），
// 各组之间分隔线 + 小标题。窄窗（真实宽度 compact，手机竖屏）：同样几组改成底部
// 抽屉 [showLibraryViewSheet]——三组单选项塞进弹出菜单太长，抽屉也更好点。
// 「每行数量」组由 [libraryGridColumnsSection] 生成，值按库 × 尺寸档存在
// [kLibraryGridColumnsPrefKey]。

/// 库页网格当前所在的尺寸档：按**真实**宽度（[windowSizeClassReal]）判，界面
/// 缩放不会把手机推进 medium 档、也不会换掉用户在这一档选的列数。
WindowSizeClass libraryGridSizeClassOf(BuildContext context) =>
    windowSizeClassReal(
      MediaQuery.sizeOf(context).width,
      FushiAppUiScale.of(context),
    );

/// 排序按钮在这个窗口下该开底部抽屉（true）还是锚定菜单（false）。
bool libraryViewOptionsUseSheet(BuildContext context) =>
    libraryGridSizeClassOf(context) == WindowSizeClass.compact;

/// 「每行数量」一组：自动 + 本尺寸档的可选列数。[selected] 为 null = 自动。
LibraryViewSection libraryGridColumnsSection({
  required WindowSizeClass sizeClass,
  required int? selected,
  required ValueChanged<int?> onSelected,
}) {
  return LibraryViewSection(
    title: t.library_grid_columns,
    options: <LibraryViewOption>[
      LibraryViewOption(
        key: const ValueKey<String>('library_grid_columns_auto'),
        label: t.library_grid_columns_auto,
        selected: selected == null,
        onSelected: () => onSelected(null),
      ),
      for (final int columns in libraryGridColumnChoices(sizeClass))
        LibraryViewOption(
          key: ValueKey<String>('library_grid_columns_$columns'),
          label: '$columns',
          selected: selected == columns,
          onSelected: () => onSelected(columns),
        ),
    ],
  );
}

/// 窄窗的「排序与显示」底部抽屉。[sections] 每次重建都重新求值（读页面自己的
/// 状态）；点一项先跑它的 onSelected（页面 setState / 持久化），再重画抽屉，
/// 抽屉不关——连着改排序和列数不用反复打开。
Future<void> showLibraryViewSheet({
  required BuildContext context,
  required String title,
  required List<LibraryViewSection> Function() sections,
}) {
  return adaptiveModalSheet<void>(
    context: context,
    builder: (BuildContext sheetContext) {
      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          final FushiDesignTokens tokens = FushiDesignTokens.of(context);
          return FushiModalSheetFrame(
            key: const ValueKey<String>('library_view_sheet'),
            title: title,
            leadingIcon: FushiIcons.settings,
            scrollable: true,
            bodyPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final LibraryViewSection section in sections())
                  LibraryFilterSection(
                    title: section.title,
                    children: <Widget>[
                      for (final LibraryViewOption option in section.options)
                        FushiChoiceChip(
                          key: option.key,
                          avatar: switch (option.icon) {
                            final IconData icon => FushiIcon(icon, size: 18),
                            null => null,
                          },
                          label: Text(option.label),
                          selected: option.selected,
                          onSelected: (_) {
                            option.onSelected();
                            setSheetState(() {});
                          },
                        ),
                    ],
                  ),
                SizedBox(height: tokens.spacing.gap * 2),
              ],
            ),
          );
        },
      );
    },
  );
}
