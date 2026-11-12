/// 音乐详情页的「海报大字」外壳（重设计外壳，[shellRedesignActive] 为 true 时才
/// 生效；墨水屏照旧走原来的悬浮顶栏 + 封面行）：
///
/// - 二级页的页头大字外壳是共享的 `FushiMastheadScaffold`
///   （`fushi_masthead_scaffold.dart`），由 `musicBrowseScaffold` 按门控挂上。
/// - [MusicDetailHero]：详情页头部色块（封面取色的大色块 + 作品名水印大字 + 封面
///   压在色块上 + 信息 + 原样的动作按钮），底子是 [FushiPosterBlock]。
/// - [MusicCoverPalette]：按封面取色（目录 / 缓存封面优先，没有时取曲目内嵌封面）
///   出色块配色，两套设计系统都取色。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data' show Uint8List;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellClip, shellRedesignActive, shellShape;
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart'
    show coverColorSchemeCache;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_poster_block.dart'
import 'package:fushi/src/utils/components/fushi_typography.dart';
    show FushiPosterBlock, FushiPosterChip, fushiPosterColors, fushiPosterHue;

// =============================================================================
// 封面取色
// =============================================================================

/// 按封面取色后的色块配色（[FushiCoverBlockColors.resolve]，与封面色块同一份
/// [coverColorSchemeCache] 与同一套 HSL）交给 [builder]。图源与 [MusicCover] 同一
/// 条来源链：目录 / 缓存 / 服务器封面（[musicCoverImageProvider]）优先，没有时取
/// 曲目内嵌封面（[MusicEmbeddedCoverCache] 同一份字节，[MemoryImage] 作缓存 key
/// 稳定）。都没有时：给了 [fallbackHue] 用它折叠出的海报色，否则中性色。与
/// `FushiCoverTint` 不同，Apple 设计系统下照样取色（色块两套设计系统都取封面色）。
class MusicCoverPalette extends StatefulWidget {
  const MusicCoverPalette({
    required this.builder,
    this.coverPath,
    this.embeddedFromPath,
    this.fallbackHue,
    super.key,
  });

  final String? coverPath;
  final String? embeddedFromPath;
  final double? fallbackHue;
  final Widget Function(BuildContext context, FushiCoverBlockColors colors)
  builder;

  @override
  State<MusicCoverPalette> createState() => _MusicCoverPaletteState();
}

class _MusicCoverPaletteState extends State<MusicCoverPalette> {
  /// 目录 / 服务器封面的图源（按 [MusicCoverPalette.coverPath] 缓存，不每帧查文件）。
  String? _fileFor;
  ImageProvider? _file;

  /// 内嵌封面字节做的图源（按音频路径缓存）。
  String? _embeddedFor;
  ImageProvider? _embedded;

  ColorScheme? _scheme;
  ImageProvider? _resolvedFor;
  Brightness? _resolvedBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(MusicCoverPalette oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  ImageProvider? get _image => _file ?? _embedded;

  void _sync() {
    final String? cover = widget.coverPath;
    if (cover != _fileFor) {
      _fileFor = cover;
      _file = musicCoverImageProvider(cover, size: 128);
    }
    final String? audio = _file == null ? widget.embeddedFromPath : null;
    if (audio != _embeddedFor) {
      _embeddedFor = audio;
      _embedded = null;
      if (audio != null) {
        unawaited(
          MusicEmbeddedCoverCache.instance.load(audio).then((Uint8List? bytes) {
            if (!mounted || _embeddedFor != audio || bytes == null) return;
            setState(() => _embedded = MemoryImage(bytes));
            _resolve();
          }),
        );
      }
    }
    _resolve();
  }

  void _resolve() {
    final ImageProvider? image = _image;
    final Brightness brightness = Theme.of(context).brightness;
    if (image == _resolvedFor && brightness == _resolvedBrightness) return;
    _resolvedFor = image;
    _resolvedBrightness = brightness;
    if (image == null) {
      _scheme = null;
      return;
    }
    // 换了封面：先取缓存里的（没有就 null = 中性色），不留上一张的配色。
    _scheme = coverColorSchemeCache.peek(image, brightness);
    if (_scheme != null) return;
    unawaited(
      coverColorSchemeCache.resolve(image, brightness).then((ColorScheme? s) {
        if (!mounted ||
            _resolvedFor != image ||
            _resolvedBrightness != brightness) {
          return;
        }
        setState(() => _scheme = s);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme? scheme = _scheme;
    final double? hue = widget.fallbackHue;
    final FushiCoverBlockColors colors = scheme == null && _image == null
        ? (hue == null
              ? FushiCoverBlockColors.resolve(Theme.of(context), null)
              : fushiPosterColors(context, hue))
        : FushiCoverBlockColors.resolve(Theme.of(context), scheme);
    return widget.builder(context, colors);
  }
}

// =============================================================================
// 详情页头部色块
// =============================================================================

/// 色块里一行可交互 / 富文本内容的构造器：[style] 是色块前景色的字样，[accent]
/// 是色块强调色（可点的艺人名等用它，代替主题 primary）。
typedef MusicDetailHeroLineBuilder =
    Widget Function(BuildContext context, TextStyle style, Color accent);

/// 色块宽到这个值起封面排在左侧、文字在右；更窄时封面与标题同排、其余整宽。
const double _kHeroWideBreakpoint = 560;

/// 头部（[MusicDetailHero]）与下方曲目 / 分区之间的间距：色块是一整块大面，下面
/// 隔一档 section；墨水屏原版头部照旧隔 [legacy]（各页原来的值）。
double musicDetailHeroGap(BuildContext context, double legacy) =>
    shellRedesignActive(context)
    ? FushiDesignTokens.of(context).spacing.section
    : legacy;

/// 详情页头部（见文件头）。重设计外壳不生效（墨水屏）时原样画 [legacy]——
/// 调用点原来那一行「封面 + 标题 + 信息 + 按钮」，一字不变。
///
/// 色块里有真按钮：整块不是点按目标、不随悬停抬升（与推荐页主卡、复习页今日计划
/// 同一做法）；悬停只让封面换姿态。按钮本体、key、焦点顺序都由调用点给，原样
/// 排进色块。封面上不压角标，格式 / 光盘规格等信息进文字区的 chip。
class MusicDetailHero extends StatelessWidget {
  const MusicDetailHero({
    required this.title,
    required this.legacy,
    this.coverPath,
    this.embeddedFromPath,
    this.showCover = true,
    this.roundCover = false,
    this.eyebrow,
    this.byline,
    this.meta,
    this.note,
    this.chips = const <String>[],
    this.strongChips = const <String>[],
    this.leadingBadges = const <Widget>[],
    this.actions = const <Widget>[],
    this.footer,
    super.key,
  });

  /// 作品名：色块标题与大字水印同一份。
  final String title;

  /// 墨水屏下的原版头部。
  final Widget legacy;

  final String? coverPath;
  final String? embeddedFromPath;

  /// false = 不画封面（来源没有图，例如本地艺人）：色块颜色由 [title] 折叠出
  /// 色相（[fushiPosterHue]），文字整宽。
  final bool showCover;

  /// 艺人头像：正圆，不是唱片。
  final bool roundCover;

  /// 色块左上的类别 chip（专辑 / 歌单 / 艺人…）。
  final String? eyebrow;

  /// 标题下第一行（艺人名链接 / 歌单创建者）。
  final MusicDetailHeroLineBuilder? byline;

  /// 信息行（歌手 · 年份 · N 首 · 来源）。
  final String? meta;

  /// 补充说明（别名、标签、简介摘要）。
  final MusicDetailHeroLineBuilder? note;

  /// 规格 chip（格式徽章）与强调 chip（Hi-Res）。
  final List<String> chips;
  final List<String> strongChips;

  /// 排在 chip 行最前的现成徽标（光盘规格等）。
  final List<Widget> leadingBadges;

  /// 动作按钮（播放 / 随机 / 收藏 / 下载 / 编辑…），原样。
  final List<Widget> actions;

  /// 按钮下的一行说明（光盘未导入等）。
  final String? footer;

  @override
  Widget build(BuildContext context) {
    if (!shellRedesignActive(context)) return legacy;
    return MusicCoverPalette(
      coverPath: showCover ? coverPath : null,
      embeddedFromPath: showCover ? embeddedFromPath : null,
      fallbackHue: showCover ? null : fushiPosterHue(title),
      builder: (BuildContext context, FushiCoverBlockColors colors) =>
          _MusicDetailHeroBlock(hero: this, colors: colors),
    );
  }
}

class _MusicDetailHeroBlock extends StatelessWidget {
  const _MusicDetailHeroBlock({required this.hero, required this.colors});

  final MusicDetailHero hero;
  final FushiCoverBlockColors colors;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= _kHeroWideBreakpoint;
        final bool hasCover = hero.showCover;
        final double pad = wide ? 24 : 18;
        final double coverSize = wide ? 200 : 112;
        final TextStyle base =
            Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
        final Color on = colors.onContainer;
        final TextStyle titleStyle = base.copyWith(
          fontSize: wide ? 34 : 26,
          fontWeight: FontWeight.w900,
          height: 1.05,
          letterSpacing: -0.5,
          color: on,
        );
        final TextStyle bylineStyle = base.copyWith(
          fontSize: wide ? 16 : 14,
          fontWeight: FontWeight.w800,
          height: 1.25,
          color: on,
        );
        final TextStyle metaStyle = base.copyWith(
          fontSize: context.fushiType.bodySmall.fontSize,
          fontWeight: FontWeight.w700,
          height: 1.3,
          color: on.withValues(alpha: 0.85),
        );
        final TextStyle noteStyle = base.copyWith(
          fontSize: context.fushiType.bodySmall.fontSize,
          fontWeight: FontWeight.w600,
          height: 1.35,
          color: on.withValues(alpha: 0.78),
        );
        final String? eyebrow = hero.eyebrow;
        final Widget head = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (eyebrow != null && eyebrow.isNotEmpty) ...<Widget>[
              FushiPosterChip(label: eyebrow, colors: colors, solid: true),
              SizedBox(height: wide ? 12 : 8),
            ],
            Semantics(
              header: true,
              child: Text(
                hero.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
            if (hero.byline case final MusicDetailHeroLineBuilder line)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: line(context, bylineStyle, colors.accent),
              ),
          ],
        );
        final bool hasChips =
            hero.leadingBadges.isNotEmpty ||
            hero.chips.isNotEmpty ||
            hero.strongChips.isNotEmpty;
        final String? meta = hero.meta;
        final String? footer = hero.footer;
        final List<Widget> details = <Widget>[
          if (meta != null && meta.isNotEmpty)
            Text(
              meta,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: metaStyle,
            ),
          if (hero.note case final MusicDetailHeroLineBuilder line)
            line(context, noteStyle, colors.accent),
          if (hasChips)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                ...hero.leadingBadges,
                for (final String c in hero.chips)
                  FushiPosterChip(label: c, colors: colors),
                for (final String c in hero.strongChips)
                  FushiPosterChip(label: c, colors: colors, solid: true),
              ],
            ),
          if (hero.actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: hero.actions,
              ),
            ),
          if (footer != null && footer.isNotEmpty)
            Text(footer, style: noteStyle),
        ];
        final Widget cover = _MusicDetailHeroCover(
          coverPath: hero.coverPath,
          embeddedFromPath: hero.embeddedFromPath,
          size: coverSize,
          round: hero.roundCover,
        );
        final Widget content;
        if (hasCover && wide) {
          content = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              cover,
              SizedBox(width: pad + 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 10,
                  children: <Widget>[head, ...details],
                ),
              ),
            ],
          );
        } else {
          content = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: <Widget>[
              if (hasCover)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    cover,
                    const SizedBox(width: 18),
                    Expanded(child: head),
                  ],
                )
              else
                head,
              for (final Widget d in details)
                Align(alignment: AlignmentDirectional.centerStart, child: d),
            ],
          );
        }
        // 水印：900 字重的作品名，字号按封面行高（色块至少这么高）；封面在左时
        // 从文字区左缘起，开头几个字压在封面底下（与封面色块同一摆法）。
        final double rowHeight = hasCover ? coverSize + pad * 2 : 180;
        return FushiPosterBlock(
          key: const ValueKey<String>('music-detail-hero'),
          watermark: hero.title,
          colors: colors,
          watermarkFontSize: rowHeight * 0.62,
          watermarkStart: hasCover && wide ? pad + coverSize + pad - 2 : -8,
          hoverEnabled: false,
          padding: EdgeInsets.all(pad),
          child: content,
        );
      },
    );
  }
}

/// 压在色块上的封面：平滑圆角 + 投影，斜放 −5°；悬停时转到 −9° 并略放大
/// （[FushiHoverLift]，时长取 [FushiMotion]）。艺人头像是正圆、不斜放。
class _MusicDetailHeroCover extends StatelessWidget {
  const _MusicDetailHeroCover({
    required this.coverPath,
    required this.embeddedFromPath,
    required this.size,
    required this.round,
  });

  final String? coverPath;
  final String? embeddedFromPath;
  final double size;
  final bool round;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.circular(
      round ? size / 2 : (size >= 160 ? 18 : 14),
    );
    final ShapeBorder shape = round
        ? const CircleBorder()
        : shellShape(context, radius);
    final Widget image = SizedBox.square(
      dimension: size,
      child: MusicCover(
        coverPath: coverPath,
        embeddedFromPath: embeddedFromPath,
        size: size,
        borderRadius: BorderRadius.zero,
      ),
    );
    final Widget card = DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: const <BoxShadow>[
          BoxShadow(
            color: Color(0x80000000),
            offset: Offset(0, 12),
            blurRadius: 28,
          ),
        ],
      ),
      child: round
          ? ClipOval(child: image)
          : ShellClip(radius: radius, child: image),
    );
    return ExcludeSemantics(
      child: FushiHoverLift(
        builder: (BuildContext context, bool hovering) =>
            TweenAnimationBuilder<double>(
              tween: Tween<double>(end: round ? 0 : (hovering ? -9 : -5)),
              duration: fushiMotionDuration(context, FushiMotion.medium),
              curve: FushiMotion.standard,
              child: card,
              builder: (BuildContext context, double degrees, Widget? child) =>
                  Transform.rotate(
                    angle: degrees * math.pi / 180,
                    child: child,
                  ),
            ),
      ),
    );
  }
}
