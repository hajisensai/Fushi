/// 有声制作的步骤外壳：左侧步骤栏（窄屏为顶部步骤选择片）+ 常驻主操作。
///
/// 「制作有声书」（[TtsStudioStep] 四步：内容 / 角色与配音 / 生成 / 结果）与
/// 「有声漫画工作台」共用这一个外壳（设计 2026-11-20 #4：两个功能长得一样，学一次
/// 就都会用）。步骤枚举是类型参数，各页只交步骤数据与回调。
///
/// 按**可用宽度**分两形态（不按平台）：
/// - 宽（≥ [kTtsStudioWideMinWidth]，骨架是共用的 [TtsTwoPaneLayout]）：左侧固定宽侧栏列步骤（图标 + 标题 + 一行
///   实时摘要），侧栏底部常驻主操作；右侧只显示选中步骤，独立滚动。
/// - 窄：顶部一排步骤选择片，正文独立滚动，底部固定条放摘要 + 主操作。
///
/// 纯 widget：不读 AppModel / Riverpod，页面把步骤数据与回调交进来，单测可直接挂。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/audiobook/tts/tts_two_pane_layout.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 切成「步骤侧栏 + 内容」双栏的最小宽度（与「朗读声音」共用 [kTtsWideMinWidth]）。
const double kTtsStudioWideMinWidth = kTtsWideMinWidth;

/// 双栏形态下步骤侧栏的固定宽度（共用 [kTtsSidebarWidth]）。
const double kTtsStudioSidebarWidth = kTtsSidebarWidth;

/// 当前可用宽度是否走双栏。
bool ttsStudioUsesWideLayout(double width) => ttsUsesWideLayout(width);

/// 制作台的四个步骤（顺序即展示顺序）。
enum TtsStudioStep { content, cast, generate, result }

/// 「制作有声书」的步骤数据（[AudioProductionStepEntry] 的特化）。
typedef TtsStudioStepEntry = AudioProductionStepEntry<TtsStudioStep>;

/// 「制作有声书」的版面（[AudioProductionStepLayout] 的特化）。
typedef TtsStudioLayout = AudioProductionStepLayout<TtsStudioStep>;

/// 一个步骤在导航里的展示数据。
@immutable
class AudioProductionStepEntry<S extends Enum> {
  const AudioProductionStepEntry({
    required this.step,
    required this.icon,
    required this.title,
    this.summary,
    this.attention = false,
  });

  final S step;
  final IconData icon;
  final String title;

  /// 一行实时摘要（如「12/20 · 声音名」「待复核（5）」）；null = 不显示。
  final String? summary;

  /// 需要注意（待复核 / 失败等）：导航项上加一个提示点。
  final bool attention;
}

/// 有声制作的版面骨架。
class AudioProductionStepLayout<S extends Enum> extends StatelessWidget {
  const AudioProductionStepLayout({
    required this.steps,
    required this.selected,
    required this.onSelect,
    required this.body,
    required this.footerBuilder,
    this.header,
    this.keyPrefix = 'tts-studio',
    super.key,
  });

  final List<AudioProductionStepEntry<S>> steps;
  final S selected;
  final ValueChanged<S> onSelect;

  /// 骨架内各固定部件 key 的前缀（`<前缀>-step-<步骤名>`、`<前缀>-footer` 等），
  /// 各页的测试按自己的前缀找部件。
  final String keyPrefix;

  /// 选中步骤的内容（自带滚动视图）。
  final Widget body;

  /// 常驻主操作区：宽形态放在侧栏底部（[wide] = true，竖排），窄形态放在
  /// 底部固定条（[wide] = false，横排）。
  final Widget Function(BuildContext context, bool wide) footerBuilder;

  /// 两种形态都显示在内容区顶上的全局提示（如书文件打不开）。
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    // 设置页壳把页头让位放在 padding.top 里（bodyConsumesTopPadding）：骨架顶上
    // 是固定的步骤导航（侧栏 / 选择片），不滚到页头底下，整体让开一次；步骤正文
    // 的滚动视图在这之下，不再重复让位（与「朗读声音」的双栏同一约定）。
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool wide = ttsStudioUsesWideLayout(constraints.maxWidth);
            return wide ? _buildWide(context) : _buildNarrow(context);
          },
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final Widget switched = AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      switchInCurve: FushiMotion.standard,
      switchOutCurve: FushiMotion.standard,
      child: KeyedSubtree(key: ValueKey<S>(selected), child: body),
    );
    if (header == null) return switched;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        header!,
        Expanded(child: switched),
      ],
    );
  }

  Widget _buildWide(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    return TtsTwoPaneLayout(
      key: ValueKey<String>('$keyPrefix-layout-wide'),
      sidebarKey: ValueKey<String>('$keyPrefix-sidebar'),
      sidebar: ListView(
        key: ValueKey<String>('$keyPrefix-step-nav'),
        padding: EdgeInsets.symmetric(vertical: gap),
        children: <Widget>[
          for (int i = 0; i < steps.length; i++)
            _StepNavItem<S>(
              key: ValueKey<String>('$keyPrefix-step-${steps[i].step.name}'),
              entry: steps[i],
              index: i,
              selected: steps[i].step == selected,
              onTap: () => onSelect(steps[i].step),
            ),
        ],
      ),
      sidebarFooter: KeyedSubtree(
        key: ValueKey<String>('$keyPrefix-footer'),
        child: footerBuilder(context, true),
      ),
      content: _content(context),
    );
  }

  Widget _buildNarrow(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    return Column(
      key: ValueKey<String>('$keyPrefix-layout-narrow'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FocusTraversalGroup(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: gap / 2),
            child: HorizontalDragScrollable(
              child: SingleChildScrollView(
                key: ValueKey<String>('$keyPrefix-step-tabs'),
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
                child: Row(
                  children: <Widget>[
                    for (int i = 0; i < steps.length; i++)
                      Padding(
                        padding: EdgeInsets.only(left: i == 0 ? 0 : gap / 2),
                        child: FushiChoiceChip(
                          key: ValueKey<String>(
                            '$keyPrefix-step-${steps[i].step.name}',
                          ),
                          avatar: FushiIcon(steps[i].icon, size: 18),
                          label: Text(
                            steps[i].attention
                                ? '${steps[i].title} •'
                                : steps[i].title,
                          ),
                          tooltip: steps[i].summary,
                          selected: steps[i].step == selected,
                          onSelected: (_) => onSelect(steps[i].step),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(child: FocusTraversalGroup(child: _content(context))),
        Material(
          key: ValueKey<String>('$keyPrefix-bottom-bar'),
          color: tokens.surfaces.card,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.gap + bottomSafeInsetOf(context),
            ),
            child: FocusTraversalGroup(
              key: ValueKey<String>('$keyPrefix-footer'),
              child: footerBuilder(context, false),
            ),
          ),
        ),
      ],
    );
  }
}

/// 侧栏里的一个步骤：序号 / 图标 + 标题 + 摘要，整行可聚焦、Enter 切换。
class _StepNavItem<S extends Enum> extends StatelessWidget {
  const _StepNavItem({
    required this.entry,
    required this.index,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final AudioProductionStepEntry<S> entry;
  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ink = selected
        ? scheme.onSecondaryContainer
        : tokens.surfaces.onVariant;
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap / 4),
      child: FushiListItem(
        selected: selected,
        selectedShape: FushiListItemSelectedShape.pill,
        onTap: onTap,
        leading: FushiBadgeControl(
          isLabelVisible: entry.attention,
          smallSize: 8,
          backgroundColor: scheme.error,
          child: FushiIcon(entry.icon, size: 22, color: ink),
        ),
        title: Text('${index + 1}. ${entry.title}'),
        subtitle: entry.summary == null
            ? null
            : AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                child: Text(
                  entry.summary!,
                  key: ValueKey<String>(entry.summary!),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
      ),
    );
  }
}
