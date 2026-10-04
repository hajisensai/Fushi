import 'package:flutter/material.dart';

import 'package:fushi/utils.dart';

/// 库页搜索栏右侧的单选下拉筛选（书架与漫画库的阅读状态、游戏库的游玩状态共用；
/// 视频库的几个下拉复用 [LibraryFilterChip] 视觉）。
///
/// [value] 为 null = 不筛选。chip 在不筛选时显示维度名 [title]、不描主色；菜单里
/// 同一档位显示 [allLabel]（chip 回答「这个下拉管什么」，菜单项回答「选了会怎
/// 样」）。null 不能直接当菜单值——[PopupMenuButton] 把 null 结果当成「取消」，
/// 「全部」项永远选不中——所以菜单值统一包一层 [_FilterChoice]。
class LibraryFilterDropdown<T extends Object> extends StatelessWidget {
  const LibraryFilterDropdown({
    required this.value,
    required this.options,
    required this.labelOf,
    required this.title,
    required this.allLabel,
    required this.onSelected,
    super.key,
  });

  final T? value;

  /// 「全部」之后的菜单项顺序。
  final List<T> options;
  final String Function(T value) labelOf;
  final String title;
  final String allLabel;
  final ValueChanged<T?> onSelected;

  @override
  Widget build(BuildContext context) {
    final T? current = value;
    return FushiPopupMenuButton<_FilterChoice<T>>(
      tooltip: title,
      initialValue: _FilterChoice<T>(current),
      onSelected: (_FilterChoice<T> choice) => onSelected(choice.value),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<_FilterChoice<T>>>[
        PopupMenuItem<_FilterChoice<T>>(
          value: _FilterChoice<T>(null),
          child: Text(allLabel),
        ),
        for (final T option in options)
          PopupMenuItem<_FilterChoice<T>>(
            value: _FilterChoice<T>(option),
            child: Text(labelOf(option)),
          ),
      ],
      child: LibraryFilterChip(
        label: current == null ? title : labelOf(current),
        active: current != null,
      ),
    );
  }
}

@immutable
class _FilterChoice<T extends Object> {
  const _FilterChoice(this.value);

  final T? value;

  @override
  bool operator ==(Object other) =>
      other is _FilterChoice<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// 下拉筛选 chip 视觉（激活态描主色），与搜索框同高。
///
/// eink：primary / outline / onSurfaceVariant 全塌成前景色，激活与未激活逐像素
/// 相同；改反色填充表达激活（chipTheme / segmentedButtonTheme 同一套处理）。
class LibraryFilterChip extends StatelessWidget {
  const LibraryFilterChip({
    required this.label,
    required this.active,
    super.key,
  });

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Color foreground = active
        ? (eink ? colors.surface : colors.primary)
        : colors.onSurfaceVariant;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active && eink ? colors.onSurface : null,
        border: Border.all(color: active ? colors.primary : colors.outline),
        // 与并排的搜索框（`const OutlineInputBorder()`）同一个圆角来源。
        borderRadius: const OutlineInputBorder().borderRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 长档位名（德语等）在窄窗口里不能把整条工具栏撑溢出。
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: foreground),
            ),
          ),
          Icon(Icons.arrow_drop_down, size: 18, color: foreground),
        ],
      ),
    );
  }
}
