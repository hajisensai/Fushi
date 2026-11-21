/// 发现页的「来源色块」（拼贴改版设计稿第二节 DI2 / DI6 / DI11）。
///
/// 漫画「浏览来源」（`MangaSourceCatalogSection`）与书 / 游戏「选择来源」
/// （`MediaDiscoveryPage`）共用这一套：每个来源一块按源取色的色块，块里是多边形
/// glyph（源图标或名字首字）+ 名称 + 语言 / 能力 chip，漫画源再带 3–4 张热门封面
/// 小条。块高恒定——拿不到封面条 / 计数的源（游戏源、iOS 上的用户服务器）只画
/// glyph + 名称 + chip，不留空白占位，也不改块高。
///
/// **同源同色**：取色顺序 源图标 → 封面条第一张 → 源名哈希（[fushiGeneratedCoverHue]）。
/// 取到的色相记在进程级的 [DiscoverySourceHues] 里，按来源 id 共享——同一个来源
/// 在漫画首块旁的来源块、下方网格、结果行行首图标三处一定同色。取色失败退回源名
/// 哈希（设计稿「空状态与降级」：取色失败 → 名字哈希兜底）。
///
/// 不做的事（所有者拍板 DI17 / DI18 / DI19）：不按「最近使用」排序、不预取目录
/// 计数、不显示「上次浏览」、「添加来源」块不显示已装 / 可更新计数。
library;

import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_generated_cover.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 来源块的固定高度：glyph + 两行名称 + 一行 chip（封面条与失败态都排在同一高度
/// 里，有没有封面块高都不变）。
const double kDiscoverySourceBlockHeight = 140;

/// 来源块网格的最小块宽：按它算列数（宽屏多列、手机单列）。
const double kDiscoverySourceBlockMinWidth = 248;

/// 来源块里多边形 glyph 的边长。
const double kDiscoverySourceGlyphSize = 40;

/// 一个来源色相的出处，按优先级从低到高排（[DiscoverySourceHues] 只接受更高档
/// 的结果覆盖已有值）。
enum DiscoverySourceHueOrigin {
  /// 源名哈希（兜底，恒可用、无需计算）。
  nameHash,

  /// 封面条第一张封面的主色。
  cover,

  /// 源图标的主色。
  icon,
}

/// 按来源 id 共享的色相表：同一个来源在发现页各处同色（见文件头）。
///
/// 进程级单例：来源色是来源的身份属性，不随页面重建而变；切页 / 切域回来同一个
/// 源仍是同一颜色。只存 id → 色相，不持有图片。
class DiscoverySourceHues extends ChangeNotifier {
  DiscoverySourceHues._();

  /// 全局唯一实例。
  static final DiscoverySourceHues instance = DiscoverySourceHues._();

  final Map<String, ({double hue, DiscoverySourceHueOrigin origin})> _resolved =
      <String, ({double hue, DiscoverySourceHueOrigin origin})>{};

  /// 正在取色的来源与档位（同一来源同时只取一档：更高档到来时作废低档结果）。
  final Map<String, DiscoverySourceHueOrigin> _pending =
      <String, DiscoverySourceHueOrigin>{};

  /// 取色失败过的（来源, 档位）：不再重试同一档，下一档（封面）接着试。
  final Set<(String, DiscoverySourceHueOrigin)> _failed =
      <(String, DiscoverySourceHueOrigin)>{};

  /// [sourceId] 当前的色相：已取到图片主色就用它，否则 [name] 的哈希色相。
  double hueOf({required String sourceId, required String name}) =>
      _resolved[sourceId]?.hue ?? fushiGeneratedCoverHue(name);

  /// [sourceId] 当前色相的出处。
  DiscoverySourceHueOrigin originOf(String sourceId) =>
      _resolved[sourceId]?.origin ?? DiscoverySourceHueOrigin.nameHash;

  /// 提供一张可取色的图片（[origin] = 图标或封面）。只有比现有结果（含在途）更
  /// 高档、且这一档没失败过时才真的去取色；取到后通知全部监听者重画。
  void offer({
    required String sourceId,
    required ImageProvider image,
    required DiscoverySourceHueOrigin origin,
  }) {
    if (origin == DiscoverySourceHueOrigin.nameHash) return;
    if (originOf(sourceId).index >= origin.index) return;
    final DiscoverySourceHueOrigin? pending = _pending[sourceId];
    if (pending != null && pending.index >= origin.index) return;
    if (_failed.contains((sourceId, origin))) return;
    _pending[sourceId] = origin;
    unawaited(_extract(sourceId, image, origin));
  }

  Future<void> _extract(
    String sourceId,
    ImageProvider image,
    DiscoverySourceHueOrigin origin,
  ) async {
    double? hue;
    try {
      final ColorScheme scheme = await ColorScheme.fromImageProvider(
        provider: image,
      );
      hue = HSLColor.fromColor(scheme.primary).hue;
    } on Object {
      // 取色失败是设计稿明写的降级态（「取色失败：源名哈希兜底」），不是要上报
      // 的错误：记下这一档失败，下一档（图标失败 → 封面）照常尝试，都失败就停在
      // 源名哈希色。
      _failed.add((sourceId, origin));
    }
    if (_pending[sourceId] != origin) return; // 已被更高档作废
    _pending.remove(sourceId);
    if (hue != null) {
      _resolved[sourceId] = (hue: hue, origin: origin);
    }
    notifyListeners();
  }

  /// 测试用：清空全部记录。
  @visibleForTesting
  void resetForTest() {
    _resolved.clear();
    _pending.clear();
    _failed.clear();
  }
}

/// [sourceId] 此刻的色块配色（墨水屏退成主题中性色，与色块同一口径）。
FushiCoverBlockColors discoverySourceColors(
  BuildContext context, {
  required String sourceId,
  required String name,
}) {
  final ThemeData theme = Theme.of(context);
  if (isEinkTheme(context)) return FushiCoverBlockColors.resolve(theme, null);
  return FushiCoverBlockColors.fromHue(
    theme,
    DiscoverySourceHues.instance.hueOf(sourceId: sourceId, name: name),
  );
}

/// 按来源身份色构建子树：把 [icon] / [cover] 交给 [DiscoverySourceHues] 取色，
/// 色相变了（取色完成）就用新配色重建。
class DiscoverySourceColorsBuilder extends StatefulWidget {
  const DiscoverySourceColorsBuilder({
    required this.sourceId,
    required this.name,
    required this.builder,
    this.icon,
    this.cover,
    super.key,
  });

  final String sourceId;
  final String name;

  /// 源图标（取色第一优先）。
  final ImageProvider? icon;

  /// 封面条第一张封面（取色第二优先）。
  final ImageProvider? cover;

  final Widget Function(BuildContext context, FushiCoverBlockColors colors)
  builder;

  @override
  State<DiscoverySourceColorsBuilder> createState() =>
      _DiscoverySourceColorsBuilderState();
}

class _DiscoverySourceColorsBuilderState
    extends State<DiscoverySourceColorsBuilder> {
  @override
  void initState() {
    super.initState();
    DiscoverySourceHues.instance.addListener(_changed);
    _offer();
  }

  @override
  void didUpdateWidget(covariant DiscoverySourceColorsBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceId != widget.sourceId ||
        oldWidget.icon != widget.icon ||
        oldWidget.cover != widget.cover) {
      _offer();
    }
  }

  @override
  void dispose() {
    DiscoverySourceHues.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // 图标那一档失败后，封面这一档要接着试（offer 内部会跳过已失败 / 更低档）。
    _offer();
  }

  void _offer() {
    final ImageProvider? icon = widget.icon;
    final ImageProvider? cover = widget.cover;
    if (icon != null) {
      DiscoverySourceHues.instance.offer(
        sourceId: widget.sourceId,
        image: icon,
        origin: DiscoverySourceHueOrigin.icon,
      );
    }
    if (cover != null) {
      DiscoverySourceHues.instance.offer(
        sourceId: widget.sourceId,
        image: cover,
        origin: DiscoverySourceHueOrigin.cover,
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    discoverySourceColors(
      context,
      sourceId: widget.sourceId,
      name: widget.name,
    ),
  );
}

/// glyph 的形状：MD3 按来源 id 哈希挑一个 M3E 多边形（同源恒同形）；Apple 是
/// 圆角方块（DI16「iOS 改画 Cupertino（圆角方块 glyph）」）。
ShapeBorder _glyphShape(
  BuildContext context,
  String sourceId,
  double size, {
  BorderSide side = BorderSide.none,
}) {
  if (isGlassDesign(context)) {
    return RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(size * 0.26),
      side: side,
    );
  }
  final int pick = fushiTitleHash(sourceId) % 8;
  return MaterialShapeBorder(
    side: side,
    shape: switch (pick) {
      0 => MaterialShapes.cookie4Sided,
      1 => MaterialShapes.cookie6Sided,
      2 => MaterialShapes.cookie9Sided,
      3 => MaterialShapes.clover4Leaf,
      4 => MaterialShapes.pentagon,
      5 => MaterialShapes.sunny,
      6 => MaterialShapes.gem,
      _ => MaterialShapes.softBurst,
    },
  );
}

/// 来源 glyph：多边形底（来源身份色的前景色）里放源图标，没有图标时放名字首字
/// （[fushiGeneratedCoverInitials]）。纯装饰，不进语义树（名称在旁边另有一份）。
///
/// [colors] 为空时自己按来源取色（结果行行首用）；块里由块传入同一份配色。
class DiscoverySourceGlyph extends StatelessWidget {
  const DiscoverySourceGlyph({
    required this.sourceId,
    required this.name,
    this.icon,
    this.colors,
    this.size = kDiscoverySourceGlyphSize,
    super.key,
  });

  final String sourceId;
  final String name;
  final ImageProvider? icon;
  final FushiCoverBlockColors? colors;
  final double size;

  @override
  Widget build(BuildContext context) {
    final FushiCoverBlockColors? given = colors;
    if (given == null) {
      return DiscoverySourceColorsBuilder(
        sourceId: sourceId,
        name: name,
        icon: icon,
        builder: (BuildContext context, FushiCoverBlockColors colors) =>
            _build(context, colors),
      );
    }
    return _build(context, given);
  }

  Widget _build(BuildContext context, FushiCoverBlockColors colors) {
    final ShapeBorder shape = _glyphShape(context, sourceId, size);
    final ImageProvider? image = icon;
    final String initials = fushiGeneratedCoverInitials(name);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(color: colors.onContainer, shape: shape),
          child: image != null
              ? ClipPath(
                  clipper: ShapeBorderClipper(shape: shape),
                  child: Image(
                    image: image,
                    fit: BoxFit.cover,
                    errorBuilder:
                        (BuildContext context, Object _, StackTrace? __) =>
                            _initials(context, initials, colors),
                  ),
                )
              : _initials(context, initials, colors),
        ),
      ),
    );
  }

  Widget _initials(
    BuildContext context,
    String initials,
    FushiCoverBlockColors colors,
  ) => Center(
    child: Padding(
      padding: EdgeInsets.all(size * 0.16),
      child: FittedBox(
        // 字号由 glyph 尺寸定：取排版角色后按盒子等比缩放（不另写字号）。
        fit: BoxFit.contain,
        child: Text(
          initials.isEmpty ? '?' : initials,
          maxLines: 1,
          textScaler: TextScaler.noScaling,
          style: context.fushiType.headlineMedium.copyWith(
            fontWeight: FontWeight.w900,
            height: 1,
            color: colors.container,
          ),
        ),
      ),
    ),
  );
}

/// 色块内的小 chip（语言 / 能力 / 置顶 / 预置）：实色底（容器色叠前景 14% 后
/// 合成的不透明色）+ 前景实色字，12 号，不叠透明度（DI16）。
class DiscoverySourceChip extends StatelessWidget {
  const DiscoverySourceChip({
    required this.label,
    required this.colors,
    this.icon,
    super.key,
  });

  final String label;
  final FushiCoverBlockColors colors;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final Color background = Color.alphaBlend(
      colors.onContainer.withValues(alpha: 0.14),
      colors.container,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(FushiRadii.chipValue),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon case final IconData icon) ...<Widget>[
              FushiIcon(icon, size: 13, color: colors.onContainer),
              const SizedBox(width: 3),
            ],
            // Flexible：chip 比块窄时标签自己省略号收尾，不把整行顶出块外。
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.labelMedium.copyWith(
                  height: 1.25,
                  fontWeight: FontWeight.w600,
                  color: colors.onContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一行 chip：只排一行，放不下的裁掉（块高恒定）。
class _ChipLine extends StatelessWidget {
  const _ChipLine({required this.chips, required this.colors});

  final List<String> chips;
  final FushiCoverBlockColors colors;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 22,
    child: ClipRect(
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          for (final String chip in chips)
            DiscoverySourceChip(label: chip, colors: colors),
        ],
      ),
    ),
  );
}

/// 来源块：按来源取色的色块（见文件头）。
///
/// 交互：整块可点（[onTap]，Enter / 手柄确认同效）；悬停上浮放大
/// （[FushiHoverLift]）、封面条第一张翘起；按压回弹（[FushiCard] 内置
/// [FushiPressScale]）。[failed] 时在块内给「无法连接 · 重试」，块高不变。
class DiscoverySourceBlock extends StatelessWidget {
  const DiscoverySourceBlock({
    required this.sourceId,
    required this.name,
    required this.onTap,
    this.chips = const <String>[],
    this.icon,
    this.covers = const <Widget>[],
    this.failed = false,
    this.onRetry,
    this.focusId,
    this.height = kDiscoverySourceBlockHeight,
    super.key,
  });

  /// 来源稳定 id（取色、glyph 形状都按它）。
  final String sourceId;

  /// 展示名（站名 / 来源名）。
  final String name;

  final VoidCallback onTap;

  /// 块内 chip 文案（语言 / 能力 / 置顶 / 预置…），按顺序只排一行。
  final List<String> chips;

  /// 源图标；null = 用名字首字。
  final ImageProvider? icon;

  /// 封面条（最多取前 4 张）。游戏源没有封面，不画封面条。
  final List<Widget> covers;

  /// 该源最近一次加载失败：块内出「无法连接 · 重试」。
  final bool failed;

  /// 失败态的重试；null 时只显示「无法连接」。
  final VoidCallback? onRetry;

  final FushiFocusId? focusId;

  /// 块高；null = 填满父级给的高度（漫画首块旁边的两块）。
  final double? height;

  @override
  Widget build(BuildContext context) {
    final List<Widget> strip = covers.take(4).toList(growable: false);
    final ImageProvider? coverImage = strip.isEmpty
        ? null
        : fushiCoverImageOf(strip.first);
    return DiscoverySourceColorsBuilder(
      sourceId: sourceId,
      name: name,
      icon: icon,
      cover: coverImage,
      builder: (BuildContext context, FushiCoverBlockColors colors) {
        final double radius = fushiCoverBlockRadius(
          FushiCoverBlockSize.regular,
          height ?? kDiscoverySourceBlockHeight,
        );
        return FushiHoverLift(
          builder: (BuildContext context, bool hovering) {
            final Widget body = Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: ClipRect(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          DiscoverySourceGlyph(
                            sourceId: sourceId,
                            name: name,
                            icon: icon,
                            colors: colors,
                          ),
                          const Spacer(),
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.fushiType.titleSmall.copyWith(
                              height: 1.2,
                              fontWeight: FontWeight.w700,
                              color: colors.onContainer,
                            ),
                          ),
                          if (chips.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 6),
                            _ChipLine(chips: chips, colors: colors),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (failed)
                    _SourceFailure(colors: colors, onRetry: onRetry)
                  else if (strip.isNotEmpty)
                    _CoverFan(covers: strip, lifted: hovering),
                ],
              ),
            );
            return FushiCard(
              focusId: focusId,
              onTap: onTap,
              color: colors.container,
              shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
              borderRadius: BorderRadius.circular(radius),
              padding: EdgeInsets.zero,
              child: height == null
                  ? body
                  : SizedBox(height: height, child: body),
            );
          },
        );
      },
    );
  }
}

/// 失败态：「无法连接」+ 重试（热区 ≥48dp），排在块尾，块高不变。
class _SourceFailure extends StatelessWidget {
  const _SourceFailure({required this.colors, required this.onRetry});

  final FushiCoverBlockColors colors;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? retry = onRetry;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          FushiIcon(FushiIcons.cloudOff, size: 20, color: colors.accent),
          const SizedBox(height: 4),
          Text(
            t.discovery_source_load_failed,
            style: context.fushiType.labelMedium.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.onContainer,
            ),
          ),
          if (retry != null)
            FushiTextButton(
              onPressed: retry,
              style: TextButton.styleFrom(
                foregroundColor: colors.accent,
                minimumSize: const Size(48, 48),
              ),
              child: Text(t.retry),
            ),
        ],
      ),
    );
  }
}

/// 封面条：最多 4 张小封面错落排开，第一张在最前；悬停时第一张翘起（减弱动效
/// 下只淡入，不转动——由 [fushiMotionDuration] 归零）。
class _CoverFan extends StatelessWidget {
  const _CoverFan({required this.covers, required this.lifted});

  final List<Widget> covers;
  final bool lifted;

  static const double _coverWidth = 46;
  static const double _coverHeight = 69;
  static const double _step = 22;

  @override
  Widget build(BuildContext context) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final bool motion = fushiMotionEnabled(context);
    final int n = covers.length;
    final double width = _coverWidth + _step * (n - 1);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: Align(
        alignment: AlignmentDirectional.bottomEnd,
        child: SizedBox(
          width: width,
          height: _coverHeight + 14,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              // 后画的在上：第一张最后画，压在最前。
              for (int i = n - 1; i >= 0; i--)
                PositionedDirectional(
                  start: _step * i,
                  bottom: 0,
                  child: AnimatedSlide(
                    duration: duration,
                    curve: FushiMotion.standard,
                    offset: Offset(0, i == 0 && lifted && motion ? -0.1 : 0),
                    child: AnimatedRotation(
                      duration: duration,
                      curve: FushiMotion.standard,
                      turns: !motion
                          ? 0
                          : (i == 0
                                    ? (lifted ? -10 : -5)
                                    : (i.isOdd ? 3 : -2)) /
                                360,
                      child: _SmallCover(child: covers[i]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallCover extends StatelessWidget {
  const _SmallCover({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(FushiRadii.chipValue),
      boxShadow: const <BoxShadow>[
        BoxShadow(
          color: Color(0x40000000),
          offset: Offset(0, 3),
          blurRadius: 8,
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(FushiRadii.chipValue),
      child: SizedBox(
        width: _CoverFan._coverWidth,
        height: _CoverFan._coverHeight,
        child: ExcludeSemantics(child: child),
      ),
    ),
  );
}

/// 网格末尾的「添加来源」块：只做跳转，不写已装 / 可更新计数（DI19）。
class DiscoveryAddSourceBlock extends StatelessWidget {
  const DiscoveryAddSourceBlock({
    required this.onTap,
    required this.hint,
    this.height = kDiscoverySourceBlockHeight,
    super.key,
  });

  final VoidCallback onTap;

  /// 副文案（「去『扩展』安装」/ iOS「连接服务器」，由调用方按合规判据给）。
  final String hint;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final FushiCoverBlockColors colors = FushiCoverBlockColors.resolve(
      Theme.of(context),
      null,
    );
    final double radius = fushiCoverBlockRadius(
      FushiCoverBlockSize.regular,
      height ?? kDiscoverySourceBlockHeight,
    );
    final Widget body = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox.square(
            dimension: kDiscoverySourceGlyphSize,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: _glyphShape(
                  context,
                  'discovery-add-source',
                  kDiscoverySourceGlyphSize,
                  side: BorderSide(color: colors.onContainer),
                ),
              ),
              child: FushiIcon(
                FushiIcons.add,
                size: 22,
                color: colors.onContainer,
              ),
            ),
          ),
          const Spacer(),
          Text(
            t.discovery_source_add_title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.titleSmall.copyWith(
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: colors.onContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.bodySmall.copyWith(
              color: colors.onContainer,
            ),
          ),
        ],
      ),
    );
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => FushiCard(
        focusId: const FushiFocusId('discovery-add-source'),
        onTap: onTap,
        color: colors.container,
        shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
        borderRadius: BorderRadius.circular(radius),
        padding: EdgeInsets.zero,
        child: height == null ? body : SizedBox(height: height, child: body),
      ),
    );
  }
}

/// 来源块网格：按 [minTileWidth] 算列数、等宽排开，每块错峰进场
/// （[FushiStaggeredEntrance]，序号从 [indexOffset] 起）。调用方在外层包
/// [FushiEntranceScope]。
class DiscoverySourceBlockGrid extends StatelessWidget {
  const DiscoverySourceBlockGrid({
    required this.children,
    this.indexOffset = 0,
    this.minTileWidth = kDiscoverySourceBlockMinWidth,
    super.key,
  });

  final List<Widget> children;
  final int indexOffset;
  final double minTileWidth;

  /// [available] 宽度下的列数。
  static int columnsFor(double available, double gap, double minTileWidth) =>
      math.max(1, ((available + gap) / (minTileWidth + gap)).floor());

  @override
  Widget build(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth;
        final int columns = columnsFor(available, gap, minTileWidth);
        final double tile = (available - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            // 等尺寸网格：格子同时定宽定高。来源块不传 height 时是「填满父级」，
            // 只给宽度会让块里 stretch 的 Row 拿到无限高约束直接抛错。
            for (int i = 0; i < children.length; i++)
              SizedBox(
                width: tile,
                height: kDiscoverySourceBlockHeight,
                child: FushiStaggeredEntrance(
                  index: indexOffset + i,
                  child: children[i],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 单源选中态的页头条：来源块原位展开成的一条（同一身份色），左边「← 全部来源」
/// 回到全部来源，右边 [trailing]（如热门 / 最新切换）。
class DiscoverySourceSelectedHeader extends StatelessWidget {
  const DiscoverySourceSelectedHeader({
    required this.sourceId,
    required this.name,
    required this.onBack,
    this.chips = const <String>[],
    this.icon,
    this.trailing,
    super.key,
  });

  final String sourceId;
  final String name;
  final VoidCallback onBack;
  final List<String> chips;
  final ImageProvider? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return DiscoverySourceColorsBuilder(
      sourceId: sourceId,
      name: name,
      icon: icon,
      builder: (BuildContext context, FushiCoverBlockColors colors) {
        final Widget? tail = trailing;
        return DecoratedBox(
          decoration: ShapeDecoration(
            color: colors.container,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                fushiCoverBlockRadius(FushiCoverBlockSize.half, 72),
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(4, 12, 16, 12),
            child: Row(
              children: <Widget>[
                FushiTextButton.icon(
                  key: const ValueKey<String>('discovery_source_back_to_all'),
                  onPressed: onBack,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.onContainer,
                    minimumSize: const Size(48, 48),
                  ),
                  icon: const FushiIcon(FushiIcons.back),
                  label: Text(t.discovery_all_sources),
                ),
                const SizedBox(width: 8),
                DiscoverySourceGlyph(
                  sourceId: sourceId,
                  name: name,
                  icon: icon,
                  colors: colors,
                  size: 36,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.fushiType.titleMedium.copyWith(
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: colors.onContainer,
                        ),
                      ),
                      if (chips.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 4),
                        _ChipLine(chips: chips, colors: colors),
                      ],
                    ],
                  ),
                ),
                if (tail != null) tail,
              ],
            ),
          ),
        );
      },
    );
  }
}
