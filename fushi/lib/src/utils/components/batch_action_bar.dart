import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// 批量操作栏：多选态下钉在页面底部的那条「已选 N · 全选 · 反选 · 若干动作」。
///
/// 视频库页与书架页原本各写一份近逐字重复的实现，且已经漂移出真实差异——书架侧按
/// 「全 app elevation 0」纪律换成了上边框分隔，并把左侧三件套改 [Wrap] 以免窄屏 +
/// 大字体下 [Row] 全员不可收缩必溢出；视频侧仍停在 `Material(elevation: 6)` + 裸
/// [Row]。本组件取书架侧（较新、已修溢出）的形态作为唯一实现，后续新增多选表面
/// （下载任务、资源选集、字幕候选等）一律复用，不再各写一份。
///
/// 只封装容器 chrome 与左侧三件套；右侧动作按钮由各表面自行构造后经 [actions] 注入
/// ——动作的可用态判据（能否组合、能否删除、选中集是否跨类型）是各域的业务语义，
/// 塞进共享组件只会变成一堆 bool 开关。
class BatchActionBar extends StatelessWidget {
  const BatchActionBar({
    required this.selectedCount,
    required this.onSelectAll,
    required this.onInvertSelection,
    required this.actions,
    super.key,
  });

  /// 当前选中总数，渲染为 `t.batch_selected_count`。
  final int selectedCount;

  /// 「全选」：各表面按自己的可见集合语义实现（只选可见项，不含被筛选隐藏的）。
  final VoidCallback onSelectAll;

  /// 「反选」：同样以可见集合为域。
  final VoidCallback onInvertSelection;

  /// 右侧动作按钮，按给出顺序排布，之间自动插入半个 gap 间隔。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    final List<Widget> trailing = <Widget>[];
    for (int i = 0; i < actions.length; i++) {
      if (i > 0) {
        trailing.add(SizedBox(width: gap / 2));
      }
      trailing.add(actions[i]);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card - gap / 2,
            vertical: gap,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: gap,
                  children: <Widget>[
                    Text(
                      t.batch_selected_count(n: selectedCount),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextButton(
                      onPressed: onSelectAll,
                      child: Text(t.batch_select_all),
                    ),
                    TextButton(
                      onPressed: onInvertSelection,
                      child: Text(t.batch_invert_selection),
                    ),
                  ],
                ),
              ),
              ...trailing,
            ],
          ),
        ),
      ),
    );
  }
}
