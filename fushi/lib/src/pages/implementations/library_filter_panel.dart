import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

// 库页「筛选」面板（游戏库 / 视频库共用，2026-10-14 用户定案）。
//
// 库页页头只留一行：筛选维度不再在页头下方铺一排下拉胶囊，而是页头动作里一颗
// 「筛选」按钮（生效时亮圆点），点开这个面板按分组列出全部维度。形态走全应用
// 唯一的弹层入口 [adaptiveModalSheet]：窄窗（< 600）是底部弹层，宽窗是居中浮动
// 面板（与对话框同一套弹簧进出 / scrim）；Esc / 手柄 B / 点遮罩关闭。改动即时
// 生效，面板不必「确定」，底部只有一个「清除全部」。
//
// - [showLibraryFilterPanel]：打开面板。[sections] 每次重建都重新求值，读的是
//   页面自己的筛选状态；改状态一律经 `update` 包一层，面板跟着重画。
// - [LibraryFilterSection]：分组标题 + 一组 chip（Wrap 换行）。
// - [LibraryFilterChoiceSection]：单选维度的便捷形态（M3E choice chip）。
// - [LibraryActiveFilterChip]：生效中的筛选条件，页头下方 chip 行里带 ✕ 的那枚。

/// 面板里改筛选状态的包装：先跑 [change]（页面自己 setState / 持久化），再让
/// 面板按新状态重画。
typedef LibraryFilterPanelUpdate = void Function(VoidCallback change);

/// 打开库页筛选面板。[sections] 返回各分组（通常是 [LibraryFilterSection] /
/// [LibraryFilterChoiceSection]，也可以夹开关行之类的非 chip 控件）；
/// [onClearAll] 是「清除全部」，只复位面板里的维度。
Future<void> showLibraryFilterPanel({
  required BuildContext context,
  required String title,
  required List<Widget> Function(
    BuildContext context,
    LibraryFilterPanelUpdate update,
  )
  sections,
  required String clearLabel,
  required VoidCallback onClearAll,
  Key? clearKey,
}) {
  return adaptiveModalSheet<void>(
    context: context,
    builder: (BuildContext sheetContext) {
      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          void update(VoidCallback change) {
            change();
            setSheetState(() {});
          }

          final FushiDesignTokens tokens = FushiDesignTokens.of(context);
          return FushiModalSheetFrame(
            title: title,
            leadingIcon: FushiIcons.filter,
            scrollable: true,
            bodyPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ...sections(context, update),
                SizedBox(height: tokens.spacing.gap),
              ],
            ),
            footer: Row(
              children: <Widget>[
                const Spacer(),
                FushiTextButton(
                  key: clearKey,
                  onPressed: () => update(onClearAll),
                  child: Text(clearLabel),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

/// 筛选面板里的一个分组：分组标题 + 一组 chip（放不下换行）。
class LibraryFilterSection extends StatelessWidget {
  const LibraryFilterSection({
    required this.title,
    required this.children,
    super.key,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(
            top: tokens.spacing.gap * 2,
            bottom: tokens.spacing.gap,
          ),
          child: Text(title, style: tokens.type.sectionLabel),
        ),
        Wrap(
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: children,
        ),
      ],
    );
  }
}

/// 单选维度：每个档位一枚 choice chip，[allValue] 那一档显示 [allLabel]
/// （「全部」）。点已选中的档位不取消（单选维度总有一档生效）。
class LibraryFilterChoiceSection<T> extends StatelessWidget {
  const LibraryFilterChoiceSection({
    required this.title,
    required this.values,
    required this.selected,
    required this.allValue,
    required this.allLabel,
    required this.labelOf,
    required this.onSelected,
    this.avatarOf,
    super.key,
  });

  final String title;
  final List<T> values;
  final T selected;
  final T allValue;
  final String allLabel;
  final String Function(T value) labelOf;
  final ValueChanged<T> onSelected;

  /// 档位前的图标（可选）。
  final IconData? Function(T value)? avatarOf;

  @override
  Widget build(BuildContext context) {
    return LibraryFilterSection(
      title: title,
      children: <Widget>[
        for (final T value in values)
          FushiChoiceChip(
            avatar: switch (avatarOf?.call(value)) {
              final IconData icon => FushiIcon(icon, size: 18),
              null => null,
            },
            label: Text(value == allValue ? allLabel : labelOf(value)),
            selected: value == selected,
            onSelected: (_) {
              if (value != selected) onSelected(value);
            },
          ),
      ],
    );
  }
}

/// 页头下方 chip 行里的一枚生效中筛选条件：点 ✕（或手柄 X）移除这一条，
/// 点 chip 本身打开筛选面板。
class LibraryActiveFilterChip extends StatelessWidget {
  const LibraryActiveFilterChip({
    required this.label,
    required this.onRemove,
    this.onTap,
    super.key,
  });

  final String label;
  final VoidCallback onRemove;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return FushiTagChip(
      label: label,
      selected: true,
      onTap: onTap,
      onDeleted: onRemove,
    );
  }
}
