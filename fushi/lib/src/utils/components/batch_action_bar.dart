import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 批量操作栏：多选态下钉在页面底部的那条「已选 N · 全选 · 反选 · 若干动作」。
///
/// 视频库页与书架页原本各写一份近逐字重复的实现，已收编为本组件这唯一实现（左侧
/// 三件套用 [Wrap]，窄屏 + 大字体下不溢出）；书架、视频库、下载任务、字体页、字幕
/// 候选都复用它，新增多选表面不再各写一份。
///
/// 外观：
/// - MD3（M3 Expressive floating toolbar，2026-10-05 起）：离边 12 的 vibrant
///   悬浮工具栏——primaryContainer 全胶囊 + Elevation 3 投影（与阅读器悬浮
///   工具栏同一份 [fushiFloatingPillDecoration]），进入多选时从底部弹入
///   （[FushiMotion.release] 轻回弹）；按钮是主题的全胶囊文字按钮；
/// - Apple：浮在内容上的玻璃胶囊工具条（Mail / Photos 选择模式底栏），动作是
///   单色 SF 图标钮；
/// - 墨水屏：保留贴底整条 + 上边框（阴影与半透明在灰阶下都会糊成脏边）。
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
    final Widget content = Row(
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
              FushiTextButton(
                onPressed: onSelectAll,
                child: Text(t.batch_select_all),
              ),
              FushiTextButton(
                onPressed: onInvertSelection,
                child: Text(t.batch_invert_selection),
              ),
            ],
          ),
        ),
        ...trailing,
      ],
    );
    if (isEinkTheme(context)) {
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
            child: content,
          ),
        ),
      );
    }
    // 浮动条与屏幕边缘 / 内容之间留 12 的空隙（Apple 底栏与 MD3 浮动工具条同口径）。
    const EdgeInsets outer = EdgeInsets.fromLTRB(12, 4, 12, 12);
    if (isGlassDesign(context)) {
      final bool compact = fushiAppleCompact(context);
      final double minHeight = compact ? 44 : 52;
      return SafeArea(
        top: false,
        child: Padding(
          padding: outer,
          child: GlassContainer(
            useOwnLayer: true,
            quality: fushiGlassQuality(context, prominent: true),
            settings: fushiClearGlassSettings(context, bar: true),
            shape: LiquidRoundedSuperellipse(borderRadius: minHeight / 2),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: 18,
                  end: 8,
                  top: 4,
                  bottom: 4,
                ),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: appleColorsOf(context).label),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      );
    }
    final ColorScheme cs = theme.colorScheme;
    // 多选态切换成 vibrant 批量操作浮动栏：从底部弹入，与普通页头 / 工具栏的
    // standard 面一眼区分开。
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: fushiMotionDuration(context, FushiMotion.long),
      curve: FushiMotion.release,
      builder: (BuildContext context, double t, Widget? child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 24),
          child: child,
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: outer,
          child: DecoratedBox(
            decoration: fushiFloatingPillDecoration(
              context,
              color: cs.primaryContainer,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(28)),
              ),
            ),
            child: Padding(
              padding: EdgeInsetsDirectional.only(
                start: tokens.spacing.card + 4,
                end: gap,
                top: gap / 2,
                bottom: gap / 2,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: IconTheme.merge(
                  data: IconThemeData(color: cs.onPrimaryContainer),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: cs.onPrimaryContainer),
                    child: content,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
