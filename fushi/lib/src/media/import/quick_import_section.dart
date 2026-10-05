import 'dart:async' show unawaited;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 「快速导入」区的一个入口按钮声明。
class QuickImportAction {
  const QuickImportAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.description,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;
  final bool enabled;

  /// 导入方式卡片上的一行说明（可选）。
  final String? description;
}

/// 库页「导入」视图顶部的快速导入区（M3E）。
///
/// 自上而下两块：
/// - **拖放区卡片**：28 圆角饱和色块 + 花瓣形大图标 + 主按钮（[actions] 第一个，
///   「选择文件」）与 tonal 次按钮（[actions] 最后一个，「导入文件夹」）+ 支持格式
///   chip 行；任一入口在跑时底部亮波浪进度。
/// - **导入方式网格**：[actions] 与 [extraActions]（如「添加网络来源」）逐个画成
///   图标选择卡，按宽度自适应 1–4 列。
///
/// 三个媒体域（书 / 漫画 / 视频）同构复用——各域只声明自己真正有的入口（与
/// `MediaLibraryShell`「不放空壳 tab」同一哲学）。单件导入入口从各库页页头 / FAB
/// 收敛到这里后，「要进内容 → 去导入」是全 app 唯一心智模型；批量常驻入口
/// （扫描根）由同一页下方的来源列表承接。
///
/// 拖放本身由库页（书架 / 媒体库）承接：本卡片只说明这一点，不另起一套拖放管线。
class QuickImportSection extends StatefulWidget {
  const QuickImportSection({
    required this.actions,
    super.key,
    this.extraActions = const <QuickImportAction>[],
    this.formats = const <String>[],
    this.heroIcon = FushiIcons.importFile,
  });

  final List<QuickImportAction> actions;

  /// 只出现在导入方式网格里的入口（不进拖放区的按钮）。
  final List<QuickImportAction> extraActions;

  /// 支持格式（扩展名 / 协议的显示名，如 `EPUB`），画成 chip 行。
  final List<String> formats;

  /// 拖放区中央的大图标（各域给自己的语义图标）。
  final IconData heroIcon;

  @override
  State<QuickImportSection> createState() => _QuickImportSectionState();
}

class _QuickImportSectionState extends State<QuickImportSection> {
  /// 正在跑的入口数（对话框开着 / 文件夹扫描中）。>0 时拖放区亮波浪进度。
  int _running = 0;

  Future<void> _run(QuickImportAction action) async {
    if (!action.enabled) return;
    setState(() => _running++);
    try {
      await action.onTap();
    } finally {
      if (mounted) setState(() => _running--);
    }
  }

  VoidCallback? _tapOf(QuickImportAction action) =>
      action.enabled ? () => unawaited(_run(action)) : null;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<QuickImportAction> actions = widget.actions;
    final List<QuickImportAction> all = <QuickImportAction>[
      ...actions,
      ...widget.extraActions,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (actions.isNotEmpty)
          FushiStaggeredEntrance(
            index: 0,
            child: _ImportDropZone(
              icon: widget.heroIcon,
              primary: actions.first,
              secondary: actions.length > 1 ? actions.last : null,
              formats: widget.formats,
              busy: _running > 0,
              onRun: _tapOf,
            ),
          ),
        if (all.isNotEmpty) ...<Widget>[
          const SizedBox(height: 28),
          FushiStaggeredEntrance(
            index: 1,
            child: Text(
              t.import_methods_title,
              style: context.fushiType.titleLargeEmphasized,
            ),
          ),
          SizedBox(height: tokens.spacing.gap + 4),
          FushiStaggeredEntrance(
            index: 2,
            child: _ImportMethodGrid(actions: all, onRun: _tapOf),
          ),
        ],
      ],
    );
  }
}

/// 拖放区卡片：28 圆角（Apple 12）虚线描边 + 饱和容器色块，悬停 spring 轻放大、
/// 底色转 primaryContainer。与游戏「导入」视图同一视觉语言。
class _ImportDropZone extends StatelessWidget {
  const _ImportDropZone({
    required this.icon,
    required this.primary,
    required this.secondary,
    required this.formats,
    required this.busy,
    required this.onRun,
  });

  final IconData icon;
  final QuickImportAction primary;
  final QuickImportAction? secondary;
  final List<String> formats;
  final bool busy;
  final VoidCallback? Function(QuickImportAction action) onRun;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context);
    final double radius =
        apple ? FushiM3eShape.small : FushiM3eShape.containerLarge;
    final QuickImportAction? secondary = this.secondary;
    return FushiHoverLift(
      scale: 1.01,
      builder: (BuildContext context, bool hovering) {
        final Color fill = eink
            ? colors.surface
            : hovering
                ? colors.primaryContainer
                : colors.secondaryContainer;
        final Color border = eink
            ? colors.outline
            : hovering
                ? colors.primary
                : colors.outlineVariant;
        // 色块上的文字跟随该色块的 on 色（墨水屏退回页面前景）。
        final Color onFill = eink
            ? colors.onSurface
            : hovering
                ? colors.onPrimaryContainer
                : colors.onSecondaryContainer;
        final Color hintColor = eink ? colors.onSurfaceVariant : onFill;
        return AnimatedContainer(
          duration: motion.effectsDefault.duration,
          curve: motion.effectsDefault.curve,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: CustomPaint(
            foregroundPainter: _DashedRRectPainter(
              color: border,
              radius: radius,
              // 墨水屏实线：虚线在低刷新灰阶上读成噪点。
              dashed: !eink,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AnimatedScale(
                    scale: hovering ? 1.08 : 1,
                    duration: motion.spatialFast.duration,
                    curve: motion.spatialFast.curve,
                    child: FushiListLeadingIcon(
                      icon,
                      shape: FushiLeadingShape.flower,
                      tone: FushiCardTone.primary,
                      size: 72,
                      iconSize: 36,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    t.import_drop_zone_title,
                    textAlign: TextAlign.center,
                    style: context.fushiType.titleLargeEmphasized
                        .copyWith(color: onFill),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: <Widget>[
                      FushiFilledButton.icon(
                        key: const ValueKey<String>('quick-import-primary'),
                        onPressed: busy ? null : onRun(primary),
                        size: FushiButtonSize.m,
                        icon: FushiIcon(primary.icon),
                        label: Text(primary.label),
                      ),
                      if (secondary != null)
                        FushiFilledButton.tonalIcon(
                          key: const ValueKey<String>('quick-import-secondary'),
                          onPressed: busy ? null : onRun(secondary),
                          size: FushiButtonSize.m,
                          icon: FushiIcon(secondary.icon),
                          label: Text(secondary.label),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    t.import_drop_zone_hint,
                    textAlign: TextAlign.center,
                    style: context.fushiType.bodyMedium.copyWith(
                      color: hintColor,
                    ),
                  ),
                  if (formats.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Semantics(
                      label: t.import_supported_formats,
                      container: true,
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          for (final String format in formats)
                            FushiTag(
                              text: format,
                              tone: FushiTagTone.neutral,
                              dense: true,
                            ),
                        ],
                      ),
                    ),
                  ],
                  AnimatedSize(
                    duration: motion.spatialDefault.duration,
                    curve: motion.spatialDefault.curve,
                    alignment: Alignment.topCenter,
                    child: busy
                        ? Padding(
                            padding: const EdgeInsets.only(top: 20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const FushiLinearProgressIndicator(),
                                const SizedBox(height: 8),
                                Text(
                                  t.import_in_progress,
                                  style: context.fushiType.labelMedium
                                      .copyWith(color: hintColor),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 导入方式网格：每个入口一张图标选择卡（形状图标 + 名称 + 说明），按可用宽度
/// 排 1–4 列；卡片本身可聚焦（Tab / 方向键遍历，Enter 打开）。
class _ImportMethodGrid extends StatelessWidget {
  const _ImportMethodGrid({required this.actions, required this.onRun});

  final List<QuickImportAction> actions;
  final VoidCallback? Function(QuickImportAction action) onRun;

  /// 卡片目标最小宽度：再窄就换行减列。
  static const double _minCardWidth = 200;

  /// 形状轮换：同一排图标不同形，M3E 的形状语言。
  static const List<FushiLeadingShape> _shapes = <FushiLeadingShape>[
    FushiLeadingShape.cookie,
    FushiLeadingShape.square,
    FushiLeadingShape.flower,
    FushiLeadingShape.circle,
  ];

  @override
  Widget build(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final int columns = ((width + gap) ~/ (_minCardWidth + gap))
            .clamp(1, 4)
            .clamp(1, actions.length);
        final double itemWidth = (width - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (int i = 0; i < actions.length; i++)
              SizedBox(
                width: itemWidth,
                child: FushiStaggeredEntrance(
                  index: i + 3,
                  child: _ImportMethodCard(
                    action: actions[i],
                    shape: _shapes[i % _shapes.length],
                    onTap: onRun(actions[i]),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ImportMethodCard extends StatelessWidget {
  const _ImportMethodCard({
    required this.action,
    required this.shape,
    required this.onTap,
  });

  final QuickImportAction action;
  final FushiLeadingShape shape;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String? description = action.description;
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: FushiCard(
        variant: FushiCardVariant.filled,
        onTap: onTap,
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 96),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiListLeadingIcon(action.icon, shape: shape),
              const SizedBox(height: 12),
              Text(
                action.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.titleSmallEmphasized,
              ),
              if (description != null && description.isNotEmpty) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.fushiType.bodySmall.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 拖放区的圆角矩形描边：[dashed] 时画虚线（拖放区的通用视觉语言），否则实线。
class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({
    required this.color,
    required this.radius,
    required this.dashed,
  });

  final Color color;
  final double radius;
  final bool dashed;

  static const double _strokeWidth = 2;
  static const double _dash = 8;
  static const double _gap = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth;
    final RRect rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(_strokeWidth / 2),
      Radius.circular(radius),
    );
    if (!dashed) {
      canvas.drawRRect(rrect, paint);
      return;
    }
    final Path outline = Path()..addRRect(rrect);
    for (final ui.PathMetric metric in outline.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double end = (distance + _dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += _dash + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.dashed != dashed;
}
