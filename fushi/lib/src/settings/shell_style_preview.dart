/// 外壳样式（库页布局 / 色块摆放 / 侧栏样式）的缩略预览与选择控件（设计稿
/// S1 / G1）。
///
/// 设置 › 外观 的三项选择用行尾的紧凑选择块（[ShellChoiceTiles]：迷你示意 + 短
/// 标签）；首页「选一种库页布局」弹窗与新手引导欢迎页用带说明的大选择卡
/// （[ShellLayoutChoiceCards]）。预览只按当前主题色与书库前几张封面画示意，不挂
/// 真实库页（拿不到封面时用主题色块），几何随盒子缩放、不放真实文字以外的固定
/// 尺寸，任何盒子都不溢出。
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show MediaKind;
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show fushiBooksProvider;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';

/// 预览最多用几张封面（封面网格一屏 10 格，拼贴只用首块那一张）。
const int kShellPreviewCoverLimit = 10;

/// 书库（小说 / 漫画书架）里有封面的前几本的封面图，给预览用（[ref] 订阅书架，
/// 载入完成后重建）。书架还没载入或一本带封面的都没有时为空表，预览改画主题色块。
List<ImageProvider<Object>> shellPreviewCoversOf(
  WidgetRef ref,
  AppModel appModel, {
  int limit = kShellPreviewCoverLimit,
}) => shellPreviewCoversFrom(
  appModel,
  ref.watch(fushiBooksProvider(JapaneseLanguage.instance)).valueOrNull ??
      const <MediaItem>[],
  limit: limit,
);

/// 不订阅、只取书架此刻已载入的那份（弹窗打开前取一次）。
List<ImageProvider<Object>> shellPreviewCoversNow(
  BuildContext context,
  AppModel appModel, {
  int limit = kShellPreviewCoverLimit,
}) => shellPreviewCoversFrom(
  appModel,
  ProviderScope.containerOf(
        context,
        listen: false,
      ).read(fushiBooksProvider(JapaneseLanguage.instance)).valueOrNull ??
      const <MediaItem>[],
  limit: limit,
);

/// 预览封面的解码宽度（预览格最宽一百来像素）。
const int kShellPreviewCoverDecodeWidth = 160;

/// [books] 里有封面的前 [limit] 本的封面图（解码宽度 [kShellPreviewCoverDecodeWidth]）。
List<ImageProvider<Object>> shellPreviewCoversFrom(
  AppModel appModel,
  List<MediaItem> books, {
  int limit = kShellPreviewCoverLimit,
}) {
  final List<ImageProvider<Object>> covers = <ImageProvider<Object>>[];
  for (final MediaItem item in books) {
    if (covers.length >= limit) break;
    final String? url = item.imageUrl;
    if (url == null || url.isEmpty) continue;
    // 封面一律经 [resolveMediaCoverImage]（封面来源的唯一真相源），解码宽度压到
    // 预览格的量级。
    final ImageProvider<Object>? cover = resolveMediaCoverImage(
      kind: MediaKind.epub,
      book: item,
      appModel: appModel,
      decodeWidth: kShellPreviewCoverDecodeWidth,
    );
    if (cover != null) covers.add(cover);
  }
  return covers;
}

/// 预览里的色块配色：取当前主题的三组 container 色与强调色轮换。
List<Color> shellPreviewBlockColors(ColorScheme scheme) => <Color>[
  scheme.primaryContainer,
  scheme.tertiaryContainer,
  scheme.secondaryContainer,
  Color.alphaBlend(
    scheme.primary.withValues(alpha: 0.35),
    scheme.surfaceContainerHighest,
  ),
  Color.alphaBlend(
    scheme.tertiary.withValues(alpha: 0.35),
    scheme.surfaceContainerHighest,
  ),
];

/// 色块摆放的示意位姿（偏移按块边长的比例，旋转为弧度）：规整不偏不转；交错
/// 奇偶一上一下各转一点；散落每块按序号取一组固定值（不随重建变）。
({Offset offset, double turns}) shellPreviewBlockPose(
  ShellBlockArrangement arrangement,
  int index,
) {
  switch (arrangement) {
    case ShellBlockArrangement.aligned:
      return (offset: Offset.zero, turns: 0.0);
    case ShellBlockArrangement.staggered:
      final bool even = index.isEven;
      return (
        offset: Offset(0, even ? -0.04 : 0.04),
        turns: (even ? -2 : 2) / 360,
      );
    case ShellBlockArrangement.scattered:
      const List<(double, double, double)> table = <(double, double, double)>[
        (0.03, -0.03, -3.0),
        (-0.04, 0.02, 1.5),
        (0.04, 0.03, 2.5),
        (-0.02, -0.04, -1.0),
        (0.02, 0.04, 2.0),
      ];
      final (double dx, double dy, double deg) = table[index % table.length];
      return (offset: Offset(dx, dy), turns: deg / 360);
  }
}

/// 一格封面：有图画图（解码失败落回色块），没图画色块。
///
/// 恒铺满父级给的最大尺寸（[SizedBox.expand]）：无子的 [ColoredBox] 与未解码完的
/// [Image] 在松约束下都缩成 0 高——封面网格示意曾因此整块空白。
class _PreviewCover extends StatelessWidget {
  const _PreviewCover({required this.image, required this.color});

  final ImageProvider<Object>? image;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ImageProvider<Object>? provider = image;
    final Widget fallback = ColoredBox(color: color);
    return SizedBox.expand(
      child: provider == null
          ? fallback
          : Image(
              image: provider,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              excludeFromSemantics: true,
              // 解码前先露出色块，不留白。
              frameBuilder:
                  (
                    BuildContext context,
                    Widget child,
                    int? frame,
                    bool wasSynchronouslyLoaded,
                  ) => frame == null && !wasSynchronouslyLoaded
                  ? fallback
                  : child,
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? stack) =>
                      fallback,
            ),
    );
  }
}

/// 库页布局的缩略预览：拼贴 = 首块加大（带首张封面）+ 右侧四块；封面网格 =
/// 5 × 2 封面格。拼贴的各块按 [arrangement] 偏移 / 旋转，换摆放时用
/// [fushiMotionDuration] 过渡。
class ShellLayoutPreview extends StatelessWidget {
  const ShellLayoutPreview({
    required this.layout,
    required this.arrangement,
    this.covers = const <ImageProvider<Object>>[],
    this.gridColumns = 5,
    this.gridRows = 2,
    super.key,
  });

  final ShellContentLayout layout;
  final ShellBlockArrangement arrangement;
  final List<ImageProvider<Object>> covers;

  /// 封面网格的列数 / 行数（选择卡里窄，弹窗里可以少放几列）。
  final int gridColumns;
  final int gridRows;

  @override
  Widget build(BuildContext context) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      child: KeyedSubtree(
        key: ValueKey<ShellContentLayout>(layout),
        child: switch (layout) {
          ShellContentLayout.collage => _CollagePreview(
            arrangement: arrangement,
            covers: covers,
          ),
          ShellContentLayout.grid => _GridPreview(
            covers: covers,
            columns: gridColumns,
            rows: gridRows,
          ),
        },
      ),
    );
  }
}

class _CollagePreview extends StatelessWidget {
  const _CollagePreview({required this.arrangement, required this.covers});

  final ShellBlockArrangement arrangement;
  final List<ImageProvider<Object>> covers;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Color> colors = shellPreviewBlockColors(scheme);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double gap = math.max(3, constraints.maxWidth * 0.025);
        final double radius = math.max(4, constraints.maxWidth * 0.04);
        Widget block(int index, {Widget? child}) => _PosedBlock(
          arrangement: arrangement,
          index: index,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: ColoredBox(
              color: colors[index % colors.length],
              child: child ?? const SizedBox.expand(),
            ),
          ),
        );
        final Widget hero = block(
          0,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              final double coverSide = math.min(
                box.maxWidth * 0.5,
                box.maxHeight * 0.55,
              );
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: <Widget>[
                  // 大字水印（示意拼贴首块的标题大字）。
                  PositionedDirectional(
                    end: -box.maxWidth * 0.04,
                    top: -box.maxHeight * 0.12,
                    child: ExcludeSemantics(
                      child: Text(
                        'Aa',
                        style: TextStyle(
                          fontSize: box.maxHeight * 0.55,
                          fontWeight: FontWeight.w900,
                          height: 1,
                          color: scheme.onPrimaryContainer.withValues(
                            alpha: 0.14,
                          ),
                        ),
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    start: box.maxWidth * 0.12,
                    bottom: box.maxHeight * 0.12,
                    width: coverSide * 0.72,
                    height: coverSide,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(radius * 0.6),
                      child: _PreviewCover(
                        image: covers.isEmpty ? null : covers.first,
                        color: scheme.primary.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(flex: 2, child: hero),
            SizedBox(width: gap),
            Expanded(
              child: Column(
                children: <Widget>[
                  Expanded(child: block(1)),
                  SizedBox(height: gap),
                  Expanded(child: block(3)),
                ],
              ),
            ),
            SizedBox(width: gap),
            Expanded(
              child: Column(
                children: <Widget>[
                  Expanded(child: block(2)),
                  SizedBox(height: gap),
                  Expanded(child: block(4)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 按摆放给色块加偏移与旋转；换摆放时用 [fushiMotionDuration] 弹过去。
class _PosedBlock extends StatelessWidget {
  const _PosedBlock({
    required this.arrangement,
    required this.index,
    required this.child,
  });

  final ShellBlockArrangement arrangement;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ({Offset offset, double turns}) pose = shellPreviewBlockPose(
      arrangement,
      index,
    );
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return AnimatedSlide(
      offset: pose.offset,
      duration: duration,
      curve: FushiMotion.release,
      child: AnimatedRotation(
        turns: pose.turns,
        duration: duration,
        curve: FushiMotion.release,
        child: child,
      ),
    );
  }
}

class _GridPreview extends StatelessWidget {
  const _GridPreview({
    required this.covers,
    required this.columns,
    required this.rows,
  });

  final List<ImageProvider<Object>> covers;
  final int columns;
  final int rows;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Color> colors = shellPreviewBlockColors(scheme);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double gap = math.max(3, constraints.maxWidth * 0.02);
        final double radius = math.max(3, constraints.maxWidth * 0.025);
        // 行列都 stretch：格子拿到紧约束，色块 / 封面铺满整格。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int r = 0; r < rows; r++) ...<Widget>[
              if (r > 0) SizedBox(height: gap),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (int c = 0; c < columns; c++) ...<Widget>[
                      if (c > 0) SizedBox(width: gap),
                      Expanded(
                        child: ClipRRect(
                          key: ValueKey<String>(
                            'shell-preview-grid-cell-${r * columns + c}',
                          ),
                          borderRadius: BorderRadius.circular(radius),
                          child: _PreviewCover(
                            image: r * columns + c < covers.length
                                ? covers[r * columns + c]
                                : null,
                            color: colors[(r * columns + c) % colors.length],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 侧栏示意的几何：侧栏宽、留白、横条高都由**盒子宽高一起**求出。
///
/// 只按宽度求（曾经的写法：`itemHeight = max(4, railWidth * 0.12)`）时，宽而矮的
/// 盒子（设置页的侧栏样式选择卡 ~680 × 58）会让竖排的几格横条总高远超盒高，
/// 示意溢出画出红黄条。这里把竖向总需求钳进盒高：镂空脊竖向是 2.5 份留白 + 9 份
/// 横条高，色脊是 5 份留白 + 8.6 份横条高（含当前项菱形 1.6 份），各留一份余量。
@immutable
class ShellRailPreviewMetrics {
  const ShellRailPreviewMetrics({
    required this.railWidth,
    required this.pad,
    required this.itemHeight,
  });

  /// 按盒子尺寸求几何。
  factory ShellRailPreviewMetrics.of(Size box, ShellRailStyle style) {
    final double railWidth = math.min(64, math.max(18, box.width * 0.12));
    final double height = math.max(0, box.height);
    final double pad = math.min(railWidth * 0.16, height * 0.08);
    final double itemHeight = switch (style) {
      ShellRailStyle.notch => math.min(
        railWidth * 0.12,
        math.max(0, height - pad * 2.5) / 10,
      ),
      ShellRailStyle.spine => math.min(
        railWidth * 0.12,
        math.max(0, height - pad * 5) / 9.6,
      ),
    };
    return ShellRailPreviewMetrics(
      railWidth: railWidth,
      pad: pad,
      itemHeight: itemHeight,
    );
  }

  final double railWidth;
  final double pad;
  final double itemHeight;
}

/// 侧栏样式的缩略预览：镂空脊 = 贴边铺满的侧栏 + 内容区左上大圆角 + 与内容区
/// 连成一体的当前项缺口；色脊 = 悬浮大圆角色块 + 多边形当前项。纯色块示意，不放
/// 文字，几何随盒子缩放（[ShellRailPreviewMetrics]），任意尺寸都不溢出。
class ShellRailPreview extends StatelessWidget {
  const ShellRailPreview({required this.style, this.content, super.key});

  final ShellRailStyle style;

  /// 内容区里画什么；null = 空内容区。
  final Widget? content;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      child: KeyedSubtree(
        key: ValueKey<ShellRailStyle>(style),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final ShellRailPreviewMetrics metrics = ShellRailPreviewMetrics.of(
              constraints.biggest,
              style,
            );
            return switch (style) {
              ShellRailStyle.notch => _NotchRail(
                scheme: scheme,
                metrics: metrics,
                content: content,
              ),
              ShellRailStyle.spine => _SpineRail(
                scheme: scheme,
                metrics: metrics,
                content: content,
              ),
            };
          },
        ),
      ),
    );
  }
}

/// 侧栏里的一格普通项（短横条）。
class _RailItem extends StatelessWidget {
  const _RailItem({required this.color, required this.height});

  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(height / 2),
    ),
  );
}

class _NotchRail extends StatelessWidget {
  const _NotchRail({
    required this.scheme,
    required this.metrics,
    required this.content,
  });

  final ColorScheme scheme;
  final ShellRailPreviewMetrics metrics;
  final Widget? content;

  @override
  Widget build(BuildContext context) {
    final Color railColor = scheme.surfaceContainerHigh;
    final Color stage = scheme.surface;
    final Color item = scheme.primary.withValues(alpha: 0.45);
    final double railWidth = metrics.railWidth;
    final double itemHeight = metrics.itemHeight;
    final double pad = metrics.pad;
    return ColoredBox(
      color: railColor,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: railWidth,
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(pad, pad * 1.5, 0, pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: EdgeInsetsDirectional.only(end: pad),
                    child: _RailItem(color: item, height: itemHeight),
                  ),
                  SizedBox(height: itemHeight),
                  // 当前项：与内容区同色、向右连进内容区的缺口。
                  Container(
                    height: itemHeight * 2,
                    decoration: BoxDecoration(
                      color: stage,
                      borderRadius: BorderRadiusDirectional.horizontal(
                        start: Radius.circular(itemHeight),
                      ),
                    ),
                  ),
                  SizedBox(height: itemHeight),
                  for (int i = 0; i < 2; i++) ...<Widget>[
                    Padding(
                      padding: EdgeInsetsDirectional.only(end: pad),
                      child: _RailItem(color: item, height: itemHeight),
                    ),
                    SizedBox(height: itemHeight),
                  ],
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: pad * 0.6),
              child: Container(
                decoration: BoxDecoration(
                  color: stage,
                  borderRadius: BorderRadiusDirectional.only(
                    topStart: Radius.circular(railWidth * 0.4),
                  ),
                ),
                padding: EdgeInsets.all(pad),
                child: content,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpineRail extends StatelessWidget {
  const _SpineRail({
    required this.scheme,
    required this.metrics,
    required this.content,
  });

  final ColorScheme scheme;
  final ShellRailPreviewMetrics metrics;
  final Widget? content;

  @override
  Widget build(BuildContext context) {
    final Color item = scheme.onPrimary.withValues(alpha: 0.5);
    final double railWidth = metrics.railWidth;
    final double itemHeight = metrics.itemHeight;
    final double pad = metrics.pad;
    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              width: railWidth - pad,
              padding: EdgeInsets.symmetric(
                horizontal: pad,
                vertical: pad * 1.5,
              ),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(railWidth * 0.3),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _RailItem(color: item, height: itemHeight),
                  SizedBox(height: itemHeight),
                  // 当前项：专属多边形（示意成菱形）。
                  Center(
                    child: Transform.rotate(
                      angle: math.pi / 4,
                      child: Container(
                        width: itemHeight * 1.6,
                        height: itemHeight * 1.6,
                        decoration: BoxDecoration(
                          color: scheme.onPrimary,
                          borderRadius: BorderRadius.circular(itemHeight * 0.3),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: itemHeight),
                  for (int i = 0; i < 2; i++) ...<Widget>[
                    _RailItem(color: item, height: itemHeight),
                    SizedBox(height: itemHeight),
                  ],
                ],
              ),
            ),
            SizedBox(width: pad),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(railWidth * 0.25),
                ),
                padding: EdgeInsets.all(pad),
                child: content,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 色块摆放的缩略预览：2 × 2 色块按摆放偏移 / 旋转。
class ShellArrangementPreview extends StatelessWidget {
  const ShellArrangementPreview({required this.arrangement, super.key});

  final ShellBlockArrangement arrangement;

  @override
  Widget build(BuildContext context) {
    final List<Color> colors = shellPreviewBlockColors(
      Theme.of(context).colorScheme,
    );
    Widget block(int index) => _PosedBlock(
      arrangement: arrangement,
      index: index,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors[index % colors.length],
          borderRadius: BorderRadius.circular(6),
        ),
        child: const SizedBox.expand(),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        children: <Widget>[
          Expanded(
            child: Row(
              children: <Widget>[
                Expanded(child: block(0)),
                const SizedBox(width: 6),
                Expanded(child: block(1)),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Row(
              children: <Widget>[
                Expanded(child: block(2)),
                const SizedBox(width: 6),
                Expanded(child: block(3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一组预览选择卡里的一项。
@immutable
class ShellChoiceOption<T extends Object> {
  const ShellChoiceOption({
    required this.value,
    required this.label,
    required this.preview,
    this.hint,
  });

  final T value;
  final String label;

  /// 卡片下方的一行说明；null = 只有名称。
  final String? hint;

  /// 卡片上部的缩略预览。
  final Widget preview;
}

/// 一张预览选择卡：缩略预览 + 名称（+ 说明）。整卡是 [FushiCard]：Tab / 方向键 /
/// 手柄可达，Enter / A 选中；悬停抬升（[FushiHoverLift]），按下回弹（FushiCard
/// 自带的 FushiPressScale）。
class ShellChoiceCard extends StatelessWidget {
  const ShellChoiceCard({
    required this.label,
    required this.preview,
    required this.selected,
    required this.onTap,
    required this.previewHeight,
    this.hint,
    super.key,
  });

  final String label;
  final String? hint;
  final Widget preview;
  final bool selected;
  final VoidCallback onTap;
  final double previewHeight;

  @override
  Widget build(BuildContext context) {
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final double radius = SettingsKitRadii.card(style);
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final String? hintText = hint;
    return FushiHoverLift(
      scale: 1.02,
      builder: (BuildContext context, bool hovering) => Semantics(
        selected: selected,
        button: true,
        inMutuallyExclusiveGroup: true,
        label: hintText == null ? label : '$label, $hintText',
        // 子树语义整体排除（预览是示意图），点击动作要在这一层补回来，否则读屏
        // 只读得到「按钮」却激活不了。
        onTap: onTap,
        excludeSemantics: true,
        child: FushiCard(
          selected: selected,
          borderRadius: BorderRadius.circular(radius),
          padding: const EdgeInsets.all(8),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AnimatedContainer(
                duration: duration,
                curve: FushiMotion.standard,
                height: previewHeight,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(radius * 0.7),
                  border: Border.all(
                    color: selected ? scheme.primary : scheme.outlineVariant,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius * 0.5),
                  child: preview,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.titleSmall.copyWith(fontWeight: FontWeight.w700),
              ),
              if (hintText != null)
                Text(
                  hintText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: type.bodySmall.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一组等宽预览选择卡（单选）。宽度放得下时一行排开、等分铺满；太窄时按
/// [minCardWidth] 折行。卡片错峰进场（[FushiEntranceScope] +
/// [FushiStaggeredEntrance]）。
class ShellChoiceCards<T extends Object> extends StatelessWidget {
  const ShellChoiceCards({
    required this.options,
    required this.selected,
    required this.onSelected,
    this.previewHeight = 88,
    this.minCardWidth = 120,
    this.keyPrefix,
    super.key,
  });

  final List<ShellChoiceOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final double previewHeight;
  final double minCardWidth;

  /// 非 null 时每张卡带 `ValueKey('<keyPrefix>-<value>')`（测试与焦点驱动定位用）。
  final String? keyPrefix;

  @override
  Widget build(BuildContext context) {
    const double gap = 10;
    int columnsFor(double maxWidth) => math.max(
      1,
      math.min(
        options.length,
        ((maxWidth + gap) / (minCardWidth + gap)).floor(),
      ),
    );
    // 一张卡的估高（只用来回答 intrinsic 查询）：卡内边距 + 预览 + 间距 + 名称
    // 一行 + 说明两行。
    final double textScale = MediaQuery.textScalerOf(context).scale(1);
    final bool hasHint = options.any(
      (ShellChoiceOption<T> option) => option.hint != null,
    );
    final double cardHeight =
        16 +
        previewHeight +
        6 +
        20 * textScale +
        (hasHint ? 32 * textScale : 0);
    return FushiEntranceScope(
      child: _ShellChoiceCardsIntrinsics(
        minWidth: minCardWidth,
        maxWidth: minCardWidth * options.length + gap * (options.length - 1),
        heightForWidth: (double width) {
          final int rows = (options.length / columnsFor(width)).ceil();
          return rows * cardHeight + (rows - 1) * gap;
        },
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double maxWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : minCardWidth * options.length + gap * (options.length - 1);
            final int columns = columnsFor(maxWidth);
            // 显式按行排（不用 Wrap）：等分宽度的浮点误差会让 Wrap 把末张卡挤到
            // 下一行；Row + Expanded 恒铺满整行，末行不满时用空位补齐保持等宽。
            final int rows = (options.length / columns).ceil();
            Widget card(int i) => FushiStaggeredEntrance(
              index: i,
              child: ShellChoiceCard(
                key: keyPrefix == null
                    ? null
                    : ValueKey<String>(
                        '$keyPrefix-${_choiceToken(options[i].value)}',
                      ),
                label: options[i].label,
                hint: options[i].hint,
                preview: options[i].preview,
                previewHeight: previewHeight,
                selected: options[i].value == selected,
                onTap: () => onSelected(options[i].value),
              ),
            );
            return SizedBox(
              width: maxWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int r = 0; r < rows; r++) ...<Widget>[
                    if (r > 0) const SizedBox(height: gap),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        for (int c = 0; c < columns; c++) ...<Widget>[
                          if (c > 0) const SizedBox(width: gap),
                          Expanded(
                            child: r * columns + c < options.length
                                ? card(r * columns + c)
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 替 [ShellChoiceCards] 里的 LayoutBuilder 回答 intrinsic 尺寸。
///
/// 升级弹窗把选择卡放在 AlertDialog 正文里，对话框外层 IntrinsicWidth 量宽时会经
/// 带 Flexible 的列反问正文高度；一路问到 LayoutBuilder 就抛「LayoutBuilder does
/// not support returning intrinsic dimensions」（release 答 0）。布局 / 绘制 / 命中
/// 原样交给子树，只有 intrinsic 查询在这一层按卡片数与估高作答。
class _ShellChoiceCardsIntrinsics extends SingleChildRenderObjectWidget {
  const _ShellChoiceCardsIntrinsics({
    required this.minWidth,
    required this.maxWidth,
    required this.heightForWidth,
    required super.child,
  });

  final double minWidth;
  final double maxWidth;
  final double Function(double width) heightForWidth;

  @override
  _RenderShellChoiceCardsIntrinsics createRenderObject(BuildContext context) =>
      _RenderShellChoiceCardsIntrinsics(
        minWidth: minWidth,
        maxWidth: maxWidth,
        heightForWidth: heightForWidth,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderShellChoiceCardsIntrinsics renderObject,
  ) {
    renderObject
      ..minWidth = minWidth
      ..maxWidth = maxWidth
      ..heightForWidth = heightForWidth;
  }
}

class _RenderShellChoiceCardsIntrinsics extends RenderProxyBox {
  _RenderShellChoiceCardsIntrinsics({
    required this.minWidth,
    required this.maxWidth,
    required this.heightForWidth,
  });

  double minWidth;
  double maxWidth;
  double Function(double width) heightForWidth;

  @override
  double computeMinIntrinsicWidth(double height) => minWidth;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.max(minWidth, maxWidth);

  @override
  double computeMinIntrinsicHeight(double width) =>
      heightForWidth(width.isFinite ? width : maxWidth);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      heightForWidth(width.isFinite ? width : maxWidth);
}

/// 选择卡 key 里的取值写法：枚举取名字，其余取 `toString`。
String _choiceToken(Object value) => value is Enum ? value.name : '$value';

/// 库页布局的两张选择卡（拼贴 / 封面网格），设置页、升级弹窗、新手引导共用。
/// [collageLabel] / [gridLabel] 缺省用设置页的名称；升级弹窗传「拼贴（新）」
/// 「封面网格（原来的）」。
class ShellLayoutChoiceCards extends StatelessWidget {
  const ShellLayoutChoiceCards({
    required this.selected,
    required this.onSelected,
    required this.arrangement,
    this.covers = const <ImageProvider<Object>>[],
    this.collageLabel,
    this.gridLabel,
    this.previewHeight = 96,
    super.key,
  });

  final ShellContentLayout selected;
  final ValueChanged<ShellContentLayout> onSelected;

  /// 拼贴卡里色块的摆放（跟着当前设置）。
  final ShellBlockArrangement arrangement;
  final List<ImageProvider<Object>> covers;
  final String? collageLabel;
  final String? gridLabel;
  final double previewHeight;

  @override
  Widget build(BuildContext context) {
    return ShellChoiceCards<ShellContentLayout>(
      keyPrefix: 'shell-layout',
      selected: selected,
      onSelected: onSelected,
      previewHeight: previewHeight,
      minCardWidth: 140,
      options: <ShellChoiceOption<ShellContentLayout>>[
        ShellChoiceOption<ShellContentLayout>(
          value: ShellContentLayout.collage,
          label: collageLabel ?? t.library_layout_collage,
          hint: t.library_layout_collage_hint,
          preview: ShellLayoutPreview(
            layout: ShellContentLayout.collage,
            arrangement: arrangement,
            covers: covers,
          ),
        ),
        ShellChoiceOption<ShellContentLayout>(
          value: ShellContentLayout.grid,
          label: gridLabel ?? t.library_layout_grid,
          hint: t.library_layout_grid_hint,
          preview: ShellLayoutPreview(
            layout: ShellContentLayout.grid,
            arrangement: arrangement,
            covers: covers,
          ),
        ),
      ],
    );
  }
}

/// 库页布局的界面名称。
String shellContentLayoutLabel(ShellContentLayout layout) => switch (layout) {
  ShellContentLayout.collage => t.library_layout_collage,
  ShellContentLayout.grid => t.library_layout_grid,
};

/// 色块摆放的界面名称。
String shellBlockArrangementLabel(ShellBlockArrangement arrangement) =>
    switch (arrangement) {
      ShellBlockArrangement.aligned => t.library_arrangement_aligned,
      ShellBlockArrangement.staggered => t.library_arrangement_staggered,
      ShellBlockArrangement.scattered => t.library_arrangement_scattered,
    };

/// 侧栏样式的界面名称。
String shellRailStyleLabel(ShellRailStyle style) => switch (style) {
  ShellRailStyle.notch => t.home_nav_rail_style_notch,
  ShellRailStyle.spine => t.home_nav_rail_style_spine,
};

/// 紧凑选择块（设置页一行）里一块的外宽（迷你示意 + 下方短标签）。
const double kShellChoiceTileWidth = 80;

/// 紧凑选择块迷你示意的高度。
const double kShellChoiceTilePreviewHeight = 40;

/// 紧凑选择块之间的间距。
const double kShellChoiceTileGap = 8;

/// 一张紧凑选择块：迷你示意 + 下方短标签，设置页的外壳样式行用（放在行尾，
/// 不再整行铺大卡）。整块是 [FushiCard]：Tab / 方向键 / 手柄可达，Enter / A
/// 选中；悬停抬升（[FushiHoverLift]），按下回弹（FushiCard 自带）。
class ShellChoiceTile extends StatelessWidget {
  const ShellChoiceTile({
    required this.label,
    required this.preview,
    required this.selected,
    required this.onTap,
    this.hint,
    super.key,
  });

  final String label;

  /// 只进读屏标签（块上不显示说明）。
  final String? hint;
  final Widget preview;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final double radius = SettingsKitRadii.card(style);
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final String? hintText = hint;
    return SizedBox(
      width: kShellChoiceTileWidth,
      child: FushiHoverLift(
        scale: 1.04,
        builder: (BuildContext context, bool hovering) => Semantics(
          selected: selected,
          button: true,
          inMutuallyExclusiveGroup: true,
          label: hintText == null ? label : '$label, $hintText',
          onTap: onTap,
          excludeSemantics: true,
          child: FushiCard(
            selected: selected,
            borderRadius: BorderRadius.circular(radius),
            padding: const EdgeInsets.all(4),
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AnimatedContainer(
                  duration: duration,
                  curve: FushiMotion.standard,
                  height: kShellChoiceTilePreviewHeight,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(radius * 0.6),
                    border: Border.all(
                      color: selected ? scheme.primary : scheme.outlineVariant,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius * 0.4),
                    child: preview,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: type.labelMedium.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一组紧凑选择块（单选），放在设置行行尾；行宽不够时由设置行整体换到标题下方，
/// 块本身再按 [Wrap] 折行，任何宽度都不溢出。错峰进场（[FushiEntranceScope] +
/// [FushiStaggeredEntrance]）。
class ShellChoiceTiles<T extends Object> extends StatelessWidget {
  const ShellChoiceTiles({
    required this.options,
    required this.selected,
    required this.onSelected,
    this.keyPrefix,
    super.key,
  });

  final List<ShellChoiceOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;

  /// 非 null 时每块带 `ValueKey('<keyPrefix>-<value>')`（测试与焦点驱动定位用）。
  final String? keyPrefix;

  /// [count] 块排成一行的固有宽度（给设置行声明 trailingWidth 用）。
  static double widthFor(int count) =>
      count * kShellChoiceTileWidth +
      math.max(0, count - 1) * kShellChoiceTileGap;

  @override
  Widget build(BuildContext context) {
    return FushiEntranceScope(
      child: Wrap(
        spacing: kShellChoiceTileGap,
        runSpacing: kShellChoiceTileGap,
        children: <Widget>[
          for (int i = 0; i < options.length; i++)
            FushiStaggeredEntrance(
              index: i,
              child: ShellChoiceTile(
                key: keyPrefix == null
                    ? null
                    : ValueKey<String>(
                        '$keyPrefix-${_choiceToken(options[i].value)}',
                      ),
                label: options[i].label,
                hint: options[i].hint,
                preview: options[i].preview,
                selected: options[i].value == selected,
                onTap: () => onSelected(options[i].value),
              ),
            ),
        ],
      ),
    );
  }
}

/// 库页布局的紧凑选择块（设置页）。
class ShellLayoutChoiceTiles extends StatelessWidget {
  const ShellLayoutChoiceTiles({
    required this.selected,
    required this.onSelected,
    required this.arrangement,
    this.covers = const <ImageProvider<Object>>[],
    super.key,
  });

  final ShellContentLayout selected;
  final ValueChanged<ShellContentLayout> onSelected;
  final ShellBlockArrangement arrangement;
  final List<ImageProvider<Object>> covers;

  @override
  Widget build(BuildContext context) {
    return ShellChoiceTiles<ShellContentLayout>(
      keyPrefix: 'shell-layout',
      selected: selected,
      onSelected: onSelected,
      options: <ShellChoiceOption<ShellContentLayout>>[
        for (final ShellContentLayout layout in ShellContentLayout.values)
          ShellChoiceOption<ShellContentLayout>(
            value: layout,
            label: shellContentLayoutLabel(layout),
            hint: switch (layout) {
              ShellContentLayout.collage => t.library_layout_collage_hint,
              ShellContentLayout.grid => t.library_layout_grid_hint,
            },
            preview: ShellLayoutPreview(
              layout: layout,
              arrangement: arrangement,
              covers: covers,
              gridColumns: 4,
            ),
          ),
      ],
    );
  }
}

/// 色块摆放的紧凑选择块（设置页）。
class ShellArrangementChoiceTiles extends StatelessWidget {
  const ShellArrangementChoiceTiles({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final ShellBlockArrangement selected;
  final ValueChanged<ShellBlockArrangement> onSelected;

  @override
  Widget build(BuildContext context) {
    return ShellChoiceTiles<ShellBlockArrangement>(
      keyPrefix: 'shell-arrangement',
      selected: selected,
      onSelected: onSelected,
      options: <ShellChoiceOption<ShellBlockArrangement>>[
        for (final ShellBlockArrangement arrangement
            in ShellBlockArrangement.values)
          ShellChoiceOption<ShellBlockArrangement>(
            value: arrangement,
            label: shellBlockArrangementLabel(arrangement),
            preview: ShellArrangementPreview(arrangement: arrangement),
          ),
      ],
    );
  }
}

/// 侧栏样式的紧凑选择块（设置页）。
class ShellRailChoiceTiles extends StatelessWidget {
  const ShellRailChoiceTiles({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final ShellRailStyle selected;
  final ValueChanged<ShellRailStyle> onSelected;

  @override
  Widget build(BuildContext context) {
    return ShellChoiceTiles<ShellRailStyle>(
      keyPrefix: 'shell-rail',
      selected: selected,
      onSelected: onSelected,
      options: <ShellChoiceOption<ShellRailStyle>>[
        for (final ShellRailStyle style in ShellRailStyle.values)
          ShellChoiceOption<ShellRailStyle>(
            value: style,
            label: shellRailStyleLabel(style),
            preview: ShellRailPreview(style: style),
          ),
      ],
    );
  }
}
