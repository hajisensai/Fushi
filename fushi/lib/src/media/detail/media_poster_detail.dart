/// 作品详情的「海报面板」版式（重设计外壳，[shellRedesignActive] 为 true 时才
/// 生效；墨水屏照旧走 [MediaDetailLayout] + 各自 hero）。视频系列 / 独立作品 /
/// 远端作品详情与漫画作品页共用。
///
/// 仍是推入的二级页面（返回键、路由、返回行为都归调用页原来的 Scaffold / 顶栏），
/// 只换正文的视觉与版式：
///
/// - [MediaPosterDetailTheme]：按封面取色（[coverColorSchemeCache]，与库页封面
///   色块同一份缓存、同一套 HSL [FushiCoverBlockColors.resolve]，两套设计系统都
///   取色），把整块面板的 [ColorScheme]（以及 Apple 设计系统的 [FushiAppleColors]）
///   换成「封面色底 + 对应前景」。面板里原有的区块（季分段、人物表、相关作品、
///   章节列表…）一律读主题色，于是不改它们就和面板讲同一套颜色。
/// - [MediaPosterDetailLayout]：整页一块大圆角面板（宽屏四周留页边、窄屏铺满），
///   面板里第一块是 [MediaPosterDetailHero]，下面接调用页原有的 sliver 区块。
///   右下角「继续 / 开始」悬浮按钮沿用 [MediaDetailFabHost]（与单列详情同一判据）。
/// - [MediaPosterDetailHero]：顶部背景图 / 剧照铺满并向下渐隐进面板底色，叠作品
///   logo；略微倾斜、带投影的竖版海报压在面板上；右侧（窄屏在海报下）小标签行、
///   大标题、信息胶囊、续播行、简介、动作按钮。没有背景图时拿封面重模糊垫底，
///   连封面都没有时只剩一条强调色渐变带——面板照样成立、不留空洞。
/// - [MediaPosterEpisodeTile]：分集剧照格（剧照 + 集号 · 集名 + 元信息 + 观看
///   状态）。状态不压在剧照角上（仓库规则「封面上不压角标」）：已看 / 看到哪 /
///   远端 / 下载失败都进文字区的状态行；进度条在剧照下面；只有「正在下载」这种
///   整格状态才盖在剧照上（压暗 + 进度环）。
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/page_scroll_registry.dart';
import 'package:fushi/src/media/async_file_existence_cache.dart'
    show PendingCoverImage;
import 'package:fushi/src/media/collections/collection_detail_layout.dart'
    show collectionEpisodeThumb, collectionEpisodeWatchedLabel;
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart'
    show CoverAspectProbe;
import 'package:fushi/src/sync/remote_download_progress_badge.dart'
    show RemoteDownloadProgressBadge;
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellClip, shellShape;
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart'
    show coverColorSchemeCache;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors;
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart'
    show FushiDesktopTitleBar, FushiTitleBarPassthroughScope;
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiHeightReporter;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart'
    show FushiMastheadFrame, kFushiMastheadBareRowExtent;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_poster_block.dart'
    show fushiPosterColors, fushiPosterHue;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart'
    show FushiAppleColors;
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiLinearProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// =============================================================================
// 配色
// =============================================================================

/// 面板配色下的主题：面板底 = [ColorScheme.surface]，前景 = onSurface，强调色 =
/// primary（主按钮实心强调色胶囊、选中季分段、进度条），各级 surfaceContainer 是
/// 前景色按不同透明度叠在面板底上（集卡悬停 / 续播高亮 / 次按钮底）。亮暗不变：
/// [FushiCoverBlockColors] 在深色主题下给深底浅字、浅色主题下给浅底深字。
ThemeData mediaPosterDetailTheme(ThemeData base, FushiCoverBlockColors colors) {
  final Color bg = colors.container;
  final Color on = colors.onContainer;
  final Color accent = colors.accent;
  Color mix(double alpha) => Color.alphaBlend(on.withValues(alpha: alpha), bg);
  final ColorScheme scheme = base.colorScheme.copyWith(
    primary: accent,
    onPrimary: bg,
    primaryContainer: mix(0.2),
    onPrimaryContainer: on,
    secondary: accent,
    onSecondary: bg,
    secondaryContainer: mix(0.14),
    onSecondaryContainer: on,
    tertiary: accent,
    onTertiary: bg,
    tertiaryContainer: mix(0.18),
    onTertiaryContainer: on,
    surface: bg,
    onSurface: on,
    onSurfaceVariant: mix(0.74),
    surfaceDim: mix(0.02),
    surfaceBright: mix(0.1),
    surfaceContainerLowest: mix(0.03),
    surfaceContainerLow: mix(0.06),
    surfaceContainer: mix(0.09),
    surfaceContainerHigh: mix(0.12),
    surfaceContainerHighest: mix(0.16),
    outline: mix(0.45),
    outlineVariant: mix(0.22),
    surfaceTint: accent,
    inverseSurface: on,
    onInverseSurface: bg,
    inversePrimary: bg,
  );
  final FushiAppleColors? apple = base.extension<FushiAppleColors>();
  // ThemeData 按扩展类型建表、后者覆盖前者，所以把面板版 FushiAppleColors 追加
  // 在原扩展之后即可替换掉原值。不写 `ThemeExtension<dynamic>` 元素类型注解：前端编译器把它按上界展开，与
  // analyzer 的推断不一致，显式注解会编不过（video_side_panel.dart 同款写法）。
  final List<FushiAppleColors> panelApple = <FushiAppleColors>[
    if (apple != null)
      FushiAppleColors(
        accent: accent,
        onAccent: bg,
        groupedBackground: bg,
        secondaryGroupedBackground: mix(0.08),
        tertiaryGroupedBackground: mix(0.14),
        label: on,
        secondaryLabel: on.withValues(alpha: 0.7),
        tertiaryLabel: on.withValues(alpha: 0.4),
        separator: on.withValues(alpha: 0.18),
        opaqueSeparator: mix(0.2),
        fill: on.withValues(alpha: 0.2),
        secondaryFill: on.withValues(alpha: 0.16),
        tertiaryFill: on.withValues(alpha: 0.12),
        destructive: apple.destructive,
        success: apple.success,
        warning: apple.warning,
      ),
  ];
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    cardColor: mix(0.06),
    dividerColor: mix(0.18),
    textTheme: base.textTheme.apply(bodyColor: on, displayColor: on),
    iconTheme: base.iconTheme.copyWith(color: on),
    extensions: base.extensions.values.followedBy(panelApple),
  );
}

/// 按封面取色并把面板主题（[mediaPosterDetailTheme]）装到 [child] 上；配色算好
/// 前用主题中性色，算好后经 [AnimatedTheme] 过渡（时长 [FushiMotion.medium]，
/// 减弱动效时归零）。没有封面时按 [fallbackKey]（作品名）折叠出稳定的色相，
/// 与库页无封面色块同一做法（[fushiPosterHue]）。
class MediaPosterDetailTheme extends StatefulWidget {
  const MediaPosterDetailTheme({
    required this.image,
    required this.fallbackKey,
    required this.child,
    super.key,
  });

  /// 取色用的封面（与 hero 海报同源）；null / 还在探测（[PendingCoverImage]）=
  /// 不取色。
  final ImageProvider? image;
  final String fallbackKey;
  final Widget child;

  @override
  State<MediaPosterDetailTheme> createState() => _MediaPosterDetailThemeState();
}

class _MediaPosterDetailThemeState extends State<MediaPosterDetailTheme> {
  ColorScheme? _scheme;
  ImageProvider? _resolvedFor;
  Brightness? _resolvedBrightness;

  ImageProvider? get _image {
    final ImageProvider? image = widget.image;
    return image is PendingCoverImage ? null : image;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(MediaPosterDetailTheme oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    coverColorSchemeCache.resolve(image, brightness).then((ColorScheme? s) {
      if (!mounted ||
          _resolvedFor != image ||
          _resolvedBrightness != brightness) {
        return;
      }
      setState(() => _scheme = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData base = Theme.of(context);
    final FushiCoverBlockColors colors = _image == null
        ? fushiPosterColors(context, fushiPosterHue(widget.fallbackKey))
        : FushiCoverBlockColors.resolve(base, _scheme);
    return AnimatedTheme(
      data: mediaPosterDetailTheme(base, colors),
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
      child: widget.child,
    );
  }
}

// =============================================================================
// 布局
// =============================================================================

/// 页面宽到这个值（已乘界面缩放）起走宽式：海报在左、文字在右；更窄时海报与
/// 标题同排、其余整宽。两种都是取色底铺满整页。
const double kMediaPosterDetailWideMinWidth = 720;

/// 宽式 hero 的 [MediaPosterDetailHero.aside] 单独成右列所需的最小宽度（再窄就
/// 接在下段末尾）：左列至少要放得下标题块 + 一行动作按钮。
const double kMediaPosterDetailAsideMinWidth = 1300;

/// 右列附栏的宽度区间（按内容宽的 36% 取，夹在这两者之间）。
const double kMediaPosterDetailAsideMinColumn = 400;
const double kMediaPosterDetailAsideMaxColumn = 600;

/// 布局下发给 hero 的版式参数。
class _MediaPosterDetailScope extends InheritedWidget {
  const _MediaPosterDetailScope({
    required this.wide,
    required this.topInset,
    required this.radius,
    required super.child,
  });

  final bool wide;

  /// hero 顶部要让开的高度（背景带铺到窗口顶端、页头裸图标压在背景图上）。
  final double topInset;

  /// 面板圆角（hero 背景图按它裁上沿）。
  final double radius;

  static _MediaPosterDetailScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MediaPosterDetailScope>();

  @override
  bool updateShouldNotify(_MediaPosterDetailScope oldWidget) =>
      wide != oldWidget.wide ||
      topInset != oldWidget.topInset ||
      radius != oldWidget.radius;
}

/// 海报面板布局（见文件头）。须放在 [MediaPosterDetailTheme] 之下：面板底色读
/// 主题的 [ColorScheme.surface]。页头由 [MediaPosterDetailChrome] 浮在正文上、
/// 按 MediaQuery 顶部 padding 让位：宽式面板从页头下沿起排；窄式面板铺满整页、
/// 背景图一直画到窗口顶端，页头的裸图标压在背景图上。
class MediaPosterDetailLayout extends StatelessWidget {
  const MediaPosterDetailLayout({
    this.header,
    this.slivers = const <Widget>[],
    this.fab,
    this.controller,
    this.bottomPadding = 24,
    super.key,
  });

  /// 面板顶部（通常是 [MediaPosterDetailHero]）。null = 没有整宽 hero，正文
  /// 自己在 [slivers] 里排版（合集详情宽屏两栏）：页名淡入的时机由 slivers 里
  /// 的 [MediaPosterHeroExtent] 登记。
  final Widget? header;

  /// hero 以下的区块（调用页原有的 sliver，原样排进面板）。
  final List<Widget> slivers;

  /// 右下角「继续 / 开始」悬浮按钮（[MediaDetailResumeFab]），主按钮滚出视口后
  /// 出现。
  final Widget? fab;
  final ScrollController? controller;
  final double bottomPadding;

  /// [width]（未乘缩放的逻辑宽）下是否走宽式。
  static bool isWide(BuildContext context, double width) =>
      width * FushiAppUiScale.of(context) >= kMediaPosterDetailWideMinWidth;

  /// [header] 所在面板的版式参数：是否宽式、顶部要给页头让出的高度。自定义
  /// header（不走 [MediaPosterDetailHero] 的页面，如合集详情）按它与海报 hero
  /// 同一判据排版；不在面板里时按宽式、零让位。
  static ({bool wide, double topInset}) metricsOf(BuildContext context) {
    final _MediaPosterDetailScope? scope = _MediaPosterDetailScope.maybeOf(
      context,
    );
    return (wide: scope?.wide ?? true, topInset: scope?.topInset ?? 0);
  }

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.paddingOf(context).top;
    final double bottomSafe = MediaQuery.paddingOf(context).bottom;
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = isWide(context, constraints.maxWidth);
          // 页头（[MediaPosterDetailChrome]）据 hero 高度决定何时淡入作品名。
          final ValueNotifier<double>? heroExtent =
              _MediaPosterHeroExtentScope.maybeOf(context);
          final ColorScheme cs = Theme.of(context).colorScheme;
          final Widget? fab = this.fab;
          // 取色底铺满整个二级页（左右到边、顶部铺进页头 / 窗口标题行、底部到
          // 底），不是「页面底上放一张圆角面板」（用户 2026-11-12「详情页不要
          // 留白」）。内容自己的左右页边距由 hero / 各区块照常留。
          final Widget scroll = CustomScrollView(
            key: const ValueKey<String>('media-poster-detail-scroll'),
            controller: controller,
            slivers: <Widget>[
              DecoratedSliver(
                key: const ValueKey<String>('media-poster-detail-panel'),
                decoration: BoxDecoration(color: cs.surface),
                // 版式参数罩住整组 sliver：header 与 slivers 里的自定义区块
                // （[metricsOf]）同一份宽窄判据与页头让位高度。
                sliver: _MediaPosterDetailScope(
                  wide: wide,
                  topInset: topInset,
                  radius: 0,
                  child: SliverMainAxisGroup(
                    slivers: <Widget>[
                      if (header case final Widget header)
                        SliverToBoxAdapter(
                          child: heroExtent == null
                              ? header
                              : FushiHeightReporter(
                                  onHeight: (double h) => heroExtent.value = h,
                                  child: header,
                                ),
                        ),
                      ...slivers,
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height:
                              bottomPadding +
                              (fab == null ? 0 : kMediaDetailFabClearance) +
                              bottomSafe,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
          // 内容不足一屏时取色底一直铺到窗口底，不露出页面底。
          final Widget body = ColoredBox(color: cs.surface, child: scroll);
          if (fab == null) return body;
          return MediaDetailFabHost(fab: fab, topInset: topInset, child: body);
        },
      ),
    );
  }
}

// =============================================================================
// 页头
// =============================================================================

/// 页头一行的高度：一个图标按钮的命中区。
const double kMediaPosterDetailChromeRowHeight = kFushiMastheadBareRowExtent;

/// [MediaPosterDetailChrome] 交给正文的 hero 高度登记口：[MediaPosterDetailLayout]
/// 把 hero 的实测高度写进来，页头据此在 hero 滚出页头下沿后才淡入作品名。
/// 没有整宽 header 的海报面板（[MediaPosterDetailLayout.header] 为 null）里充当
/// hero 的那块：把它的下沿（自身高度 + [leading]，即它在面板里的起点）登记给
/// [MediaPosterDetailChrome]，页头在它滚出页头下沿后才淡入页名。不在页头下时
/// 原样返回 [child]。
class MediaPosterHeroExtent extends StatelessWidget {
  const MediaPosterHeroExtent({
    required this.child,
    this.leading = 0,
    super.key,
  });

  final Widget child;

  /// 这块在面板里的上沿偏移（通常是页头让位高度 + 间距）。
  final double leading;

  @override
  Widget build(BuildContext context) {
    final ValueNotifier<double>? extent = _MediaPosterHeroExtentScope.maybeOf(
      context,
    );
    if (extent == null) return child;
    return FushiHeightReporter(
      onHeight: (double h) => extent.value = h + leading,
      child: child,
    );
  }
}

class _MediaPosterHeroExtentScope extends InheritedWidget {
  const _MediaPosterHeroExtentScope({
    required this.extent,
    required super.child,
  });

  final ValueNotifier<double> extent;

  static ValueNotifier<double>? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<_MediaPosterHeroExtentScope>()
      ?.extent;

  @override
  bool updateShouldNotify(_MediaPosterHeroExtentScope oldWidget) =>
      extent != oldWidget.extent;
}

/// 海报面板详情页的页头：共享页头大字内核（[FushiMastheadFrame]）的 `titleInBody`
/// 形态——一排不带胶囊底色的裸图标（返回键 + 右侧 [actions]），浮在 [child] 上，
/// 与音乐详情页、设置 / 媒体服务器二级页同一套。正文 hero 已有大标题，页头在
/// 内容在顶时不写页名；hero 滚出页头下沿后，[title]（作品名）以收缩字号淡入，
/// 底板与音乐一致（[FushiMastheadPanel]：90% 页面底色 + 高斯模糊，随滚动渐入）。
/// 桌面装了自绘顶栏时这一行画进窗口标题行（[FushiTitleBarPassthroughScope]，两侧
/// 让开窗口按钮组 / macOS 红绿灯，空白处垫拖窗区）；没有自绘标题行的平台排在
/// 状态栏下面。[child] 的 MediaQuery 顶部 padding 改成页头下沿，正文照常按它让位。
/// 在顶时裸图标压在背景图上：垫一层由面板底色向下渐隐的薄雾保证对比度（用户
/// 2026-11-12「顶部按钮容易看不到」），底板渐入时薄雾随之退掉。
class MediaPosterDetailChrome extends StatefulWidget {
  const MediaPosterDetailChrome({
    required this.child,
    this.title = '',
    this.actions = const <Widget>[],
    this.ownPrimaryScroll = false,
    super.key,
  });

  final Widget child;

  /// 作品名：滚过 hero 后在页头淡入；空 = 页头不写页名。
  final String title;

  /// 页头右侧的动作（图标按钮原样排，key / tooltip 由调用页给；放不下才收「⋯」）。
  final List<Widget> actions;

  /// 替换 `FushiPageScaffold` 的页面传 true：与它同一约定，自持一个全平台继承的
  /// [PrimaryScrollController] 并登记 [PageScrollRegistry]（手柄 LB / RB 翻屏兜底
  /// 够得到正文）。原本挂 Scaffold + AppBar 的页面保持 false，行为不变。
  final bool ownPrimaryScroll;

  @override
  State<MediaPosterDetailChrome> createState() =>
      _MediaPosterDetailChromeState();
}

class _MediaPosterDetailChromeState extends State<MediaPosterDetailChrome> {
  /// hero 实测高度（[MediaPosterDetailLayout] 写入）。
  final ValueNotifier<double> _heroExtent = ValueNotifier<double>(0);

  /// 作品名开始淡入的主滚动偏移：hero 下沿到达页头下沿时。
  final ValueNotifier<double> _revealStart = ValueNotifier<double>(
    double.infinity,
  );

  /// 页头下沿（状态栏 / 标题行折算后 + 一行），build 时更新。
  double _inset = 0;

  @override
  void initState() {
    super.initState();
    _heroExtent.addListener(_syncRevealStart);
  }

  @override
  void dispose() {
    _heroExtent.removeListener(_syncRevealStart);
    _heroExtent.dispose();
    _revealStart.dispose();
    super.dispose();
  }

  void _syncRevealStart() {
    final double hero = _heroExtent.value;
    // 还没量到 hero（加载态 / 无 hero 的正文）时不写页名。
    _revealStart.value = hero <= 0
        ? double.infinity
        : math.max(0, hero - _inset);
  }

  @override
  Widget build(BuildContext context) {
    final double statusTop = MediaQuery.paddingOf(context).top;
    // 与内核同一判据：标题行高度折在顶部 padding 里时页头上移进标题行。
    final double captionLift = math.min(
      FushiDesktopTitleBar.immersiveCaptionInset,
      statusTop,
    );
    final double inset =
        statusTop - captionLift + kMediaPosterDetailChromeRowHeight;
    if (inset != _inset) {
      _inset = inset;
      // build 里不能改 notifier（会让页头在本帧建造中被标脏）：帧后重算。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncRevealStart();
      });
    }
    return _MediaPosterHeroExtentScope(
      extent: _heroExtent,
      child: FushiMastheadFrame(
        title: widget.title,
        titleInBody: true,
        titleRevealOffset: _revealStart,
        actions: widget.actions,
        ownPrimaryScroll: widget.ownPrimaryScroll,
        backKey: const ValueKey<String>('media-poster-detail-back'),
        dragKey: const ValueKey<String>('media-poster-detail-drag'),
        backdrop: (BuildContext context, double height, double progress) {
          final Color surface = Theme.of(context).colorScheme.surface;
          final double mist = 0.72 * (1 - progress);
          if (mist <= 0) return const SizedBox.shrink();
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  surface.withValues(alpha: mist),
                  surface.withValues(alpha: 0),
                ],
              ),
            ),
          );
        },
        body: widget.child,
      ),
    );
  }
}

// =============================================================================
// hero
// =============================================================================

/// 面板顶部（见文件头）。数据求值留在调用页；这里只吃纯值与现成按钮（按钮本体、
/// key、焦点顺序都由调用页给，原样排进 [MediaDetailActionBar]）。
class MediaPosterDetailHero extends StatelessWidget {
  const MediaPosterDetailHero({
    required this.title,
    this.primaryAction,
    this.poster,
    this.posterImage,
    this.backdrop,
    this.backdropKey,
    this.backdropFallback,
    this.logo,
    this.logoSemanticsName,
    this.kicker,
    this.originalTitle,
    this.titleKey,
    this.originalTitleKey,
    this.selectableHeading = false,
    this.pills = const <MediaDetailChip>[],
    this.continueLabel,
    this.summary,
    this.summaryKey,
    this.selectableSummary = true,
    this.secondaryActions = const <Widget>[],
    this.more,
    this.actionsKey,
    this.footer,
    this.aside,
    super.key,
  });

  final String title;

  /// 尾侧附栏（视频合集详情的「接着看」卡 + 作品资料）：宽式且宽度够
  /// （≥ [kMediaPosterDetailAsideMinWidth]）时与标题块顶端对齐、单独占右列，
  /// 标题块 / 简介 / 动作栏收成左列；不够宽或窄式时接在下段末尾。null = 不占位，
  /// 其它详情页行为不变。
  final Widget? aside;

  /// 主按钮（[MediaDetailPrimaryButton]）：面板主题下是实心强调色胶囊。null =
  /// 条目没有主操作（播客、无音频条目等）：次按钮与「⋯」照常从行首排，三者都
  /// 没有时整行不画、不留空位。
  final Widget? primaryAction;

  /// 竖版海报的内容（不含外框，由本组件裁圆角、斜放、加投影）；null = 没有
  /// 竖版海报（横版截帧不塞进竖版位），文字区从页边起排。
  final Widget? poster;

  /// [poster] 画的那张图的图片源（与海报内容同一个 provider 实例，共用一条解码
  /// 流）。给了就按它的固有宽高比定海报位的高度——整张封面显示全，不裁成 2:3
  /// （2026-11-12 用户：「详情封面显示要显示全」）；首帧解码前、解码失败或没给
  /// 时按 2:3。
  final ImageProvider? posterImage;

  /// 横版背景图 / 剧照（铺满顶部、向下渐隐进面板底色）。
  final ImageProvider? backdrop;

  /// 背景图轮换下标：变化时交叉淡入。
  final Object? backdropKey;

  /// 没有 [backdrop] 时拿来重模糊垫底的图（通常是封面）。
  final ImageProvider? backdropFallback;

  /// 作品 logo（透明底）：叠在背景图上，解码失败不占位（大标题照样在）。
  final ImageProvider? logo;
  final String? logoSemanticsName;

  /// 标题上方的小标签行（「TV · Ended」「本地卷」）。
  final String? kicker;

  /// 标题下一行（原名；游戏详情放开发商 / 品牌）。
  final String? originalTitle;

  /// 大标题 / [originalTitle] 那一行的 key（测试与读屏定位用）。
  final Key? titleKey;
  final Key? originalTitleKey;

  /// 大标题与 [originalTitle] 可选择复制（刮削来的资料要能复制去编辑，游戏详情
  /// 反馈 2DmrXg-wtD）。
  final bool selectableHeading;

  /// 信息胶囊：[MediaDetailChipTone.primary] 画实心强调色（评分），其余半透明。
  final List<MediaDetailChip> pills;

  /// 续播行（「继续看第 3 集 · 集名」）。
  final String? continueLabel;
  final String? summary;
  final Key? summaryKey;
  final bool selectableSummary;

  /// 次按钮（[MediaDetailSecondaryButton]）：面板主题下是半透明胶囊。
  final List<Widget> secondaryActions;

  /// 「⋯」（[MediaDetailMoreButton]）。
  final Widget? more;
  final Key? actionsKey;

  /// 按钮下的附加内容（用户标签、刷新失败提示条…）。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final _MediaPosterDetailScope? scope = _MediaPosterDetailScope.maybeOf(
      context,
    );
    final bool wide = scope?.wide ?? true;
    final double topInset = scope?.topInset ?? 0;
    final double radius = scope?.radius ?? 0;
    Widget layout(_HeroPosterFit fit, double? backdropAspect) => LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        return wide
            ? _buildWide(context, width, radius, topInset, fit, backdropAspect)
            : _buildNarrow(context, width, topInset, fit, backdropAspect);
      },
    );
    Widget withBackdrop(_HeroPosterFit fit) {
      final ImageProvider? art = backdrop;
      if (art == null) return layout(fit, null);
      return _HeroImageAspect(
        image: art,
        builder: (double? aspect) => layout(fit, aspect),
      );
    }

    final ImageProvider? image = poster == null ? null : posterImage;
    if (image == null) {
      return withBackdrop(const _HeroPosterFit(slot: _kHeroPosterAspect));
    }
    return _HeroPosterAspect(image: image, builder: withBackdrop);
  }

  bool get _hasArt => backdrop != null || backdropFallback != null;

  /// 背景带高度（含页头那一截 [topInset]，背景图铺到窗口顶端）。有背景图且已知
  /// 固有比例时按整宽铺满所需的高度给（整张图看得全），但不超过视口高的
  /// [maxViewportFraction]——超过时 [_HeroBand] 把整张图等比缩进带里、贴尾侧，
  /// 空出的部分垫同图模糊。比例未知（首帧解码前 / 没有背景图）时用 [fallback]。
  double _artBandHeight(
    BuildContext context, {
    required double width,
    required double topInset,
    required double? backdropAspect,
    required double fallback,
    required double minArt,
    required double maxViewportFraction,
  }) {
    final double? aspect = backdropAspect;
    if (backdrop == null || aspect == null || aspect <= 0) {
      return topInset + fallback;
    }
    final double viewport = MediaQuery.sizeOf(context).height;
    final double natural = width / aspect;
    return math.max(
      topInset + minArt,
      math.min(natural, viewport * maxViewportFraction),
    );
  }

  // ── 宽式：背景带 + logo 在上，海报压在左侧跨过背景带下沿，文字在海报右侧 ──
  // 背景带同窄式一样铺到窗口顶端（页头裸图标压在上面），[topInset] 是页头下沿。
  Widget _buildWide(
    BuildContext context,
    double width,
    double radius,
    double topInset,
    _HeroPosterFit fit,
    double? backdropAspect,
  ) {
    const double px = 40;
    final bool hasPoster = poster != null;
    final double posterW = hasPoster
        ? (_hasArt ? (width * 0.17).clamp(150.0, 220.0) : 170.0)
        : 0;
    final double posterH = posterW / fit.slot;
    final double overhang = posterH * 0.38;
    final double bandH = math.max(
      _artBandHeight(
        context,
        width: width,
        topInset: topInset,
        backdropAspect: backdropAspect,
        // 没有横版背景图（只有封面重模糊垫底）时带子只留够海报上沿，不铺一大片
        // 没有信息量的模糊色。
        fallback: _hasArt
            ? (backdrop == null
                  ? (width * 0.1).clamp(150.0, 200.0)
                  : (width * 0.3).clamp(220.0, 380.0))
            : 72.0,
        minArt: 220,
        maxViewportFraction: 0.72,
      ),
      hasPoster ? topInset + posterH * 0.62 + 16 : 0.0,
    );
    final double textStart = hasPoster ? px + posterW + 32 : px;
    final Widget band = _HeroBand(
      height: bandH,
      radius: BorderRadius.vertical(top: Radius.circular(radius)),
      backdrop: backdrop,
      backdropKey: backdropKey,
      backdropFallback: backdropFallback,
      backdropAspect: backdropAspect,
      logo: logo == null
          ? null
          : PositionedDirectional(
              start: textStart,
              end: px,
              top: math.max(topInset + 8, bandH * 0.3),
              bottom: 18,
              child: FushiStaggeredEntrance(index: 1, child: _buildLogo()),
            ),
    );
    // 版面分上下两段，海报下方不留整块空白：
    // - 上段：海报旁（海报压过背景带下沿的那一截）只放标题块（小标签 / 大标题 /
    //   原名 + 信息胶囊 + 续播行）。上段高度取海报底与标题块底的较大者。
    // - 下段：简介 / 动作栏 / 页脚回到从页边起排、占满整宽（不再缩在海报右侧
    //   一条窄列里，把海报下方空成一块）。
    final double posterTop = bandH - posterH * 0.62;
    final Widget head = Padding(
      padding: EdgeInsetsDirectional.fromSTEB(textStart, 4, px, 0),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: hasPoster ? overhang : 0),
        child: Align(
          alignment: AlignmentDirectional.topStart,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FushiStaggeredEntrance(
                  index: 1,
                  child: _buildHeading(context, wide: true),
                ),
                ..._buildDetails(context, wide: true, tail: false),
              ],
            ),
          ),
        ),
      ),
    );
    final List<Widget> tail = <Widget>[
      ..._buildDetails(context, wide: true, head: false),
    ];
    final Widget? aside = this.aside;
    if (aside != null && width >= kMediaPosterDetailAsideMinWidth) {
      return _buildWideWithAside(
        context,
        width: width,
        px: px,
        band: band,
        head: head,
        tail: tail,
        aside: aside,
        posterOverlay: hasPoster
            ? PositionedDirectional(
                start: px,
                top: posterTop,
                child: FushiStaggeredEntrance(
                  index: 0,
                  child: _HeroPoster(
                    width: posterW,
                    height: posterH,
                    fit: fit,
                    image: posterImage,
                    child: poster!,
                  ),
                ),
              )
            : null,
      );
    }
    if (aside != null) {
      tail.addAll(<Widget>[
        const SizedBox(height: 24),
        FushiStaggeredEntrance(index: 2, child: aside),
      ]);
    }
    // Stack 的尺寸取左列（背景带 + 标题块）；海报是定位子项、另按它的下沿补高。
    final Widget top = Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            band,
            head,
            // 海报下沿以下留一点呼吸，与下段 / 下方区块分开。
            SizedBox(height: hasPoster ? 12 : 0),
          ],
        ),
        if (hasPoster)
          PositionedDirectional(
            start: px,
            top: posterTop,
            child: FushiStaggeredEntrance(
              index: 0,
              child: _HeroPoster(
                width: posterW,
                height: posterH,
                fit: fit,
                image: posterImage,
                child: poster!,
              ),
            ),
          ),
      ],
    );
    return Column(
      key: const ValueKey<String>('video-work-hero-card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        top,
        if (tail.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(px, 0, px, 8),
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: tail,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 宽式 + [aside]：背景带整宽在上；带下是两列——左列 = 标题块（海报旁）+
  /// 简介 / 动作栏 / 页脚（从页边起排），右列 = [aside]，顶端与标题块对齐。
  /// 海报照旧定位在左列起点、压过背景带下沿。
  Widget _buildWideWithAside(
    BuildContext context, {
    required double width,
    required double px,
    required Widget band,
    required Widget head,
    required List<Widget> tail,
    required Widget aside,
    required Widget? posterOverlay,
  }) {
    const double gap = 48;
    final double asideW = ((width - px * 2) * 0.36).clamp(
      kMediaPosterDetailAsideMinColumn,
      kMediaPosterDetailAsideMaxColumn,
    );
    final Widget left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        head,
        const SizedBox(height: 12),
        if (tail.isNotEmpty)
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(px, 0, 0, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: tail,
            ),
          ),
      ],
    );
    return Stack(
      key: const ValueKey<String>('video-work-hero-card'),
      clipBehavior: Clip.none,
      children: <Widget>[
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            band,
            Padding(
              padding: EdgeInsetsDirectional.only(end: px),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: left),
                  const SizedBox(width: gap),
                  SizedBox(
                    key: const ValueKey<String>('media-poster-detail-aside'),
                    width: asideW,
                    child: FushiStaggeredEntrance(index: 2, child: aside),
                  ),
                ],
              ),
            ),
          ],
        ),
        ?posterOverlay,
      ],
    );
  }

  // ── 窄式：背景带铺到窗口顶端，海报与 logo / 标题同排，其余整宽 ──
  Widget _buildNarrow(
    BuildContext context,
    double width,
    double topInset,
    _HeroPosterFit fit,
    double? backdropAspect,
  ) {
    const double px = 20;
    final bool hasPoster = poster != null;
    final double posterW = hasPoster ? (width * 0.3).clamp(96.0, 150.0) : 0;
    final double posterH = posterW / fit.slot;
    final double bandH = math.max(
      _artBandHeight(
        context,
        width: width,
        topInset: topInset,
        backdropAspect: backdropAspect,
        fallback: _hasArt ? width * 0.46 : 24.0,
        minArt: 120,
        maxViewportFraction: 0.6,
      ),
      hasPoster ? topInset + posterH * 0.62 + 12 : 0.0,
    );
    final double overhang = hasPoster ? posterH * 0.38 : 0;
    final double posterTop = bandH - posterH * 0.62;
    final double sideStart = hasPoster ? px + posterW + 16 : px;
    final Widget band = _HeroBand(
      height: bandH,
      radius: BorderRadius.zero,
      backdrop: backdrop,
      backdropKey: backdropKey,
      backdropFallback: backdropFallback,
      backdropAspect: backdropAspect,
      logo: null,
    );
    // 有海报：海报旁边（从顶栏下到海报底）放 logo + 小标签 + 标题，底边对齐海报；
    // 标题放不下时按高度截断（Flexible），不溢出。没有海报：logo 叠在背景带上，
    // 标题回到正文顶部。
    final Widget? side = hasPoster
        ? PositionedDirectional(
            start: sideStart,
            end: px,
            top: topInset + 8,
            bottom: 0,
            child: Align(
              alignment: AlignmentDirectional.bottomStart,
              child: FushiStaggeredEntrance(
                index: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (logo != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 48),
                          child: _buildLogo(),
                        ),
                      ),
                    Flexible(
                      child: _buildHeading(
                        context,
                        wide: false,
                        flexibleTitle: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        : (logo == null
              ? null
              : PositionedDirectional(
                  start: px,
                  end: px,
                  top: math.max(topInset + 8, bandH * 0.4),
                  bottom: 10,
                  child: FushiStaggeredEntrance(index: 1, child: _buildLogo()),
                ));
    final List<Widget> details = <Widget>[
      if (!hasPoster)
        FushiStaggeredEntrance(
          index: 1,
          child: _buildHeading(context, wide: false),
        ),
      ..._buildDetails(context, wide: false),
      if (aside case final Widget aside) ...<Widget>[
        const SizedBox(height: 24),
        FushiStaggeredEntrance(index: 2, child: aside),
      ],
    ];
    return Column(
      key: const ValueKey<String>('video-work-hero-card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: bandH + overhang,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(top: 0, left: 0, right: 0, child: band),
              if (hasPoster)
                PositionedDirectional(
                  start: px,
                  top: posterTop,
                  child: FushiStaggeredEntrance(
                    index: 0,
                    child: _HeroPoster(
                      width: posterW,
                      height: posterH,
                      fit: fit,
                      image: posterImage,
                      child: poster!,
                    ),
                  ),
                ),
              ?side,
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(px, 14, px, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: details,
          ),
        ),
      ],
    );
  }

  /// logo：读屏与测试按作品名找它（key `collection-hero-logo` 沿用旧 hero）。
  Widget _buildLogo() => Semantics(
    label: logoSemanticsName ?? title,
    image: true,
    child: Image(
      key: const ValueKey<String>('collection-hero-logo'),
      image: logo!,
      fit: BoxFit.contain,
      alignment: AlignmentDirectional.bottomStart,
      excludeFromSemantics: true,
      errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
          const SizedBox.shrink(),
    ),
  );

  /// 小标签行 + 大标题 + 原名。[flexibleTitle]：所在 Column 高度有限（窄式海报
  /// 旁边）时标题让出高度、按高度截断，不溢出。
  Widget _buildHeading(
    BuildContext context, {
    required bool wide,
    bool flexibleTitle = false,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final String? kicker = this.kicker?.trim();
    final String? originalTitle = this.originalTitle?.trim();
    final TextStyle titleStyle = (text.headlineMedium ?? const TextStyle())
        .copyWith(
          fontSize: wide ? 34 : 24,
          fontWeight: FontWeight.w900,
          height: 1.05,
          letterSpacing: wide ? -0.7 : -0.4,
          color: cs.onSurface,
        );
    final Widget titleText = Semantics(
      header: true,
      child: selectableHeading
          ? SelectableText(
              title,
              key: titleKey,
              maxLines: wide ? 3 : 4,
              style: titleStyle,
            )
          : Text(
              title,
              key: titleKey,
              maxLines: wide ? 3 : 4,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (kicker != null && kicker.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              kicker,
              key: const ValueKey<String>('media-poster-detail-kicker'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (text.labelMedium ?? const TextStyle()).copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
                color: cs.primary,
              ),
            ),
          ),
        if (flexibleTitle) Flexible(child: titleText) else titleText,
        if (originalTitle != null &&
            originalTitle.isNotEmpty &&
            originalTitle != title)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: selectableHeading
                ? SelectableText(
                    originalTitle,
                    key: originalTitleKey,
                    maxLines: 2,
                    style: (text.bodyMedium ?? const TextStyle()).copyWith(
                      color: cs.primary,
                    ),
                  )
                : Text(
                    originalTitle,
                    key: originalTitleKey,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: (text.bodyMedium ?? const TextStyle()).copyWith(
                      color: cs.primary,
                    ),
                  ),
          ),
      ],
    );
  }

  /// 胶囊 / 续播行 / 简介 / 按钮 / 页脚，缺的逐项跳过。
  /// [head]：信息胶囊 + 续播行；[tail]：简介 + 动作栏 + 页脚。宽式把两段分开排
  /// （head 在海报旁、tail 在海报下方整宽），窄式两段连排。
  List<Widget> _buildDetails(
    BuildContext context, {
    required bool wide,
    bool head = true,
    bool tail = true,
  }) {
    final String? summary = this.summary?.trim();
    final String? continueLabel = this.continueLabel;
    final Widget? footer = this.footer;
    final Widget? primaryAction = this.primaryAction;
    final Widget? more = this.more;
    // 没有主按钮时次按钮与「⋯」从行首排（与 [MediaDetailActionBar] 宽式同一套
    // Wrap 间距）；三者都没有时整行不画。
    final Widget? actionBar = primaryAction != null
        ? MediaDetailActionBar(
            key: actionsKey,
            alignment: WrapAlignment.start,
            primary: primaryAction,
            secondary: secondaryActions,
            more: more,
          )
        : secondaryActions.isEmpty && more == null
        ? null
        : Wrap(
            key: actionsKey,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[...secondaryActions, ?more],
          );
    int index = 2;
    Widget entrance(Widget child) =>
        FushiStaggeredEntrance(index: index++, child: child);
    return <Widget>[
      if (head && pills.isNotEmpty) ...<Widget>[
        SizedBox(height: wide ? 14 : 0),
        entrance(
          Wrap(
            key: const ValueKey<String>('media-poster-detail-pills'),
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final MediaDetailChip chip in pills) _HeroPill(chip: chip),
            ],
          ),
        ),
      ],
      if (head &&
          continueLabel != null &&
          continueLabel.isNotEmpty) ...<Widget>[
        const SizedBox(height: 14),
        entrance(_ContinueRow(label: continueLabel)),
      ],
      if (tail && summary != null && summary.isNotEmpty) ...<Widget>[
        const SizedBox(height: 14),
        entrance(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: MediaDetailSynopsis(
              key: summaryKey,
              text: summary,
              selectable: selectableSummary,
              collapsedLines: wide ? 4 : 3,
            ),
          ),
        ),
      ],
      if (tail && actionBar != null) ...<Widget>[
        const SizedBox(height: 18),
        entrance(actionBar),
      ],
      if (tail && footer != null) ...<Widget>[
        const SizedBox(height: 14),
        entrance(footer),
      ],
    ];
  }
}

/// 顶部背景带：背景图（或封面重模糊）铺满，底部渐隐进面板底色；没有图时是一条
/// 强调色淡渐变。上沿按面板圆角裁。
class _HeroBand extends StatelessWidget {
  const _HeroBand({
    required this.height,
    required this.radius,
    required this.backdrop,
    required this.backdropKey,
    required this.backdropFallback,
    required this.logo,
    this.backdropAspect,
  });

  final double height;

  /// [backdrop] 的固有宽高比（宽 / 高）；null = 未知，按 `cover` 铺。
  final double? backdropAspect;
  final BorderRadius radius;
  final ImageProvider? backdrop;
  final Object? backdropKey;
  final ImageProvider? backdropFallback;

  /// 叠在背景带上的 logo（已定位）。
  final Widget? logo;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ImageProvider? backdrop = this.backdrop;
    final ImageProvider? fallback = backdropFallback;
    final Widget art;
    if (backdrop != null) {
      art = KeyedSubtree(
        key: const ValueKey<String>('collection-hero-backdrop'),
        child: AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.long),
          child: LayoutBuilder(
            key: ValueKey<Object>(backdropKey ?? backdrop),
            builder: (BuildContext context, BoxConstraints constraints) =>
                _buildBackdrop(context, backdrop, constraints.maxWidth),
          ),
        ),
      );
    } else if (fallback != null) {
      art = KeyedSubtree(
        key: const ValueKey<String>('collection-hero-cover'),
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
          child: Transform.scale(
            scale: 1.25,
            child: Image(
              image: fallback,
              fit: BoxFit.cover,
              width: double.infinity,
              height: height,
              excludeFromSemantics: true,
              errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                  const SizedBox.shrink(),
            ),
          ),
        ),
      );
    } else {
      art = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              cs.primary.withValues(alpha: 0.28),
              cs.primary.withValues(alpha: 0.06),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: ShellClip(
              radius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  art,
                  // 渐隐进面板底色（设计稿 `.shade`：底 2% 实色、45% 处 40%、80% 起透明）。
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: <Color>[
                            cs.surface,
                            cs.surface.withValues(alpha: 0.55),
                            cs.surface.withValues(alpha: 0),
                          ],
                          // 只在底部一小截渐隐进面板底色，背景图主体完整露出
                          // （用户 2026-11-12「视频详情封面显示不全」）。
                          stops: const <double>[0.0, 0.12, 0.3],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          ?logo,
        ],
      ),
    );
  }
}

extension on _HeroBand {
  /// 背景图：整宽铺满。带高按图的整宽高度给（[_artBandHeight]），被视口上限
  /// 截住时上下裁一点、偏上对齐保住人物脸；不缩进带里留空白、也不垫模糊
  /// （2026-11-13 用户：「没必要模糊吧」→「不要留白」）。
  Widget _buildBackdrop(
    BuildContext context,
    ImageProvider image,
    double width,
  ) => Image(
    image: image,
    fit: BoxFit.cover,
    alignment: const Alignment(0, -0.35),
    width: double.infinity,
    height: height,
    excludeFromSemantics: true,
    errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
        const SizedBox.shrink(),
  );
}

/// 背景图的固有宽高比探测（同 [_HeroPosterAspect]，共用解码流、不采色）；
/// 解码前 / 失败时给 null。
class _HeroImageAspect extends StatefulWidget {
  const _HeroImageAspect({required this.image, required this.builder});

  final ImageProvider image;
  final Widget Function(double? aspect) builder;

  @override
  State<_HeroImageAspect> createState() => _HeroImageAspectState();
}

class _HeroImageAspectState extends State<_HeroImageAspect>
    with CoverAspectProbe<_HeroImageAspect> {
  @override
  ImageProvider probedImageOf(_HeroImageAspect widget) => widget.image;

  @override
  bool needsBackdropSeed(double aspect) => false;

  @override
  Widget build(BuildContext context) =>
      widget.builder(coverFailed ? null : coverAspect);
}

/// 海报位的默认宽高比（宽 / 高）：竖版海报 2:3。
const double _kHeroPosterAspect = 2 / 3;

/// 海报位跟随封面固有宽高比时的取值范围：再瘦 / 再宽的图海报位按边界取（版面的
/// 文字起点与背景带高度都跟着海报位算，不让一张异形图把它们撑坏），图本身在
/// 海报位里等比缩进、整张显示（[_HeroPoster]，条漫长图 / 横跨页都不裁）。
const double _kHeroPosterAspectMin = 0.5;
const double _kHeroPosterAspectMax = 1;

/// 海报位的版面比例 [slot] 与封面的固有比例 [image]（未知 = null）。两者不等时
/// （异形图被夹到边界）海报位里等比缩放画整张图、空出的部分垫同图模糊。
@immutable
class _HeroPosterFit {
  const _HeroPosterFit({required this.slot, this.image});

  final double slot;
  final double? image;

  /// 图要不要在海报位里等比缩进（比例差出 1% 以上才算异形）。
  bool get letterboxed {
    final double? natural = image;
    return natural != null && (natural - slot).abs() > slot * 0.01;
  }
}

/// 取海报图的固有宽高比交给版面（[MediaPosterDetailHero.posterImage]）。与
/// 海报内容共用同一个 provider 的解码流（[CoverAspectProbe]），不另解码、不采色。
class _HeroPosterAspect extends StatefulWidget {
  const _HeroPosterAspect({required this.image, required this.builder});

  final ImageProvider image;
  final Widget Function(_HeroPosterFit fit) builder;

  @override
  State<_HeroPosterAspect> createState() => _HeroPosterAspectState();
}

class _HeroPosterAspectState extends State<_HeroPosterAspect>
    with CoverAspectProbe<_HeroPosterAspect> {
  @override
  ImageProvider probedImageOf(_HeroPosterAspect widget) => widget.image;

  @override
  bool needsBackdropSeed(double aspect) => false;

  @override
  Widget build(BuildContext context) {
    final double? aspect = coverFailed ? null : coverAspect;
    return widget.builder(
      aspect == null || aspect <= 0
          ? const _HeroPosterFit(slot: _kHeroPosterAspect)
          : _HeroPosterFit(
              slot: aspect.clamp(_kHeroPosterAspectMin, _kHeroPosterAspectMax),
              image: aspect,
            ),
    );
  }
}

/// 压在面板上的竖版海报：平滑圆角 + 投影，斜放 −2.5°；悬停时转到 −5° 并略放大
/// （[FushiHoverLift]，时长取 [FushiMotion]）。
///
/// 异形封面（[_HeroPosterFit.letterboxed]：条漫长图、横跨页）不裁：调用方的
/// 海报内容放进按封面固有比例的框里、在海报位里等比缩进（contain），四周垫同一
/// 张图的模糊铺底。
class _HeroPoster extends StatelessWidget {
  const _HeroPoster({
    required this.width,
    required this.height,
    required this.fit,
    required this.image,
    required this.child,
  });

  final double width;
  final double height;
  final _HeroPosterFit fit;
  final ImageProvider? image;
  final Widget child;

  Widget _content() {
    final double? natural = fit.image;
    final ImageProvider? provider = image;
    if (!fit.letterboxed || natural == null || provider == null) return child;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        IgnorePointer(
          child: ExcludeSemantics(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Image(
                image: provider,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                excludeFromSemantics: true,
                errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                    const SizedBox.shrink(),
              ),
            ),
          ),
        ),
        Center(
          child: AspectRatio(aspectRatio: natural, child: child),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.circular(width >= 160 ? 22 : 16);
    final Widget card = DecoratedBox(
      decoration: ShapeDecoration(
        shape: shellShape(context, radius),
        shadows: const <BoxShadow>[
          BoxShadow(
            color: Color(0x8C000000),
            offset: Offset(0, 18),
            blurRadius: 44,
          ),
        ],
      ),
      child: ShellClip(
        radius: radius,
        child: SizedBox(width: width, height: height, child: _content()),
      ),
    );
    return FushiHoverLift(
      builder: (BuildContext context, bool hovering) =>
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: hovering ? -5 : -2.5),
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.standard,
            child: card,
            builder: (BuildContext context, double degrees, Widget? child) =>
                Transform.rotate(angle: degrees * math.pi / 180, child: child),
          ),
    );
  }
}

/// 附栏的「接着看」卡：横排，16:9 剧照（没有就用背景图 / 封面），旁边是「继续看 第 N 集」小标签、集名、元信息与观看进度。整卡点按 =
/// [onPlay]（与 hero 主按钮同一动作）；悬停上浮、按压回弹。
class MediaPosterUpNextCard extends StatelessWidget {
  const MediaPosterUpNextCard({
    required this.label,
    required this.title,
    required this.onPlay,
    this.image,
    this.meta = const <String>[],
    this.progress,
    this.completed = false,
    super.key,
  });

  /// 「继续看 第 N 集」。
  final String label;
  final String title;
  final ImageProvider? image;
  final List<String> meta;

  /// 0..1；null = 不画进度条。
  final double? progress;
  final bool completed;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    const double thumbW = 208;
    const double thumbH = thumbW * 9 / 16;
    final double? progress = this.progress;
    final OutlinedBorder shape = shellShape(context, FushiM3eShape.cardRadius);
    // 不压播放圆钮：整卡点按就是播放（2026-11-13 用户：「播放按钮可以砍掉」）。
    final Widget thumb = collectionEpisodeThumb(
      context,
      image,
      w: thumbW,
      h: thumbH,
    );
    final Widget text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tokens.type.sectionLabel.copyWith(color: cs.primary),
        ),
        SizedBox(height: tokens.spacing.gap / 2),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: type.titleMediumEmphasized.copyWith(color: cs.onSurface),
        ),
        if (meta.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            meta.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        if (progress != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          FushiLinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            minHeight: 4,
            wavy: false,
            color: completed ? cs.tertiary : cs.primary,
          ),
        ],
      ],
    );
    return FushiPressScale(
      child: FushiHoverLift(
        builder: (BuildContext context, bool hovering) => Material(
          key: const ValueKey<String>('media-poster-up-next'),
          color: cs.onSurface.withValues(alpha: hovering ? 0.12 : 0.08),
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: shape,
            onTap: onPlay,
            child: Padding(
              padding: EdgeInsets.all(tokens.spacing.rowVertical),
              child: Row(
                children: <Widget>[
                  thumb,
                  SizedBox(width: tokens.spacing.rowHorizontal),
                  Expanded(child: text),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 附栏的资料清单：小标题 + 两列 key-value（键一列定宽、值一列，最多 3 行）。
/// [facts] 为空时只写 [emptyText]（null = 整块不画）。
class MediaPosterFactList extends StatelessWidget {
  const MediaPosterFactList({
    required this.heading,
    required this.facts,
    this.emptyText,
    super.key,
  });

  final String heading;
  final List<(String, String)> facts;
  final String? emptyText;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    final String? emptyText = this.emptyText;
    if (facts.isEmpty && emptyText == null) return const SizedBox.shrink();
    return Column(
      key: const ValueKey<String>('media-poster-fact-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(heading, style: tokens.type.sectionLabel),
        SizedBox(height: tokens.spacing.gap),
        if (facts.isEmpty)
          Text(
            emptyText!,
            style: type.bodyMedium.copyWith(color: cs.onSurfaceVariant),
          )
        else
          for (final (String label, String value) in facts)
            Padding(
              padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 104,
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: type.labelLargeEmphasized.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  SizedBox(width: tokens.spacing.gap),
                  Expanded(
                    child: Text(
                      value,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodyMedium.copyWith(color: cs.onSurface),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

/// 信息胶囊（设计稿 `.pills span`：前景色 10% 底；`.st` 评分 = 强调色实心）。
class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.chip});

  final MediaDetailChip chip;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool solid = chip.tone == MediaDetailChipTone.primary;
    final Color fg = solid ? cs.onPrimary : cs.onSurface;
    final Color bg = solid
        ? cs.primary
        : cs.onSurface.withValues(
            alpha: chip.tone == MediaDetailChipTone.tertiary ? 0.2 : 0.1,
          );
    final IconData? icon = chip.icon;
    final TextStyle base =
        Theme.of(context).textTheme.labelMedium ?? const TextStyle();
    return DecoratedBox(
      key: chip.key,
      decoration: ShapeDecoration(shape: const StadiumBorder(), color: bg),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 5,
          children: <Widget>[
            if (icon != null) FushiIcon(icon, size: 14, color: fg),
            Flexible(
              child: Text(
                chip.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: base.copyWith(
                  fontSize: context.fushiType.labelMedium.fontSize,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 续播行（「继续看第 3 集 · 集名」）。
class _ContinueRow extends StatelessWidget {
  const _ContinueRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextStyle base =
        Theme.of(context).textTheme.labelLarge ?? const TextStyle();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiIcon(FushiIcons.history, size: 18, color: cs.primary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// 分集剧照格
// =============================================================================

/// 剧照格内边距。
const double kMediaPosterEpisodePadding = 8;

/// 剧照格网格的最小列宽（设计稿 `minmax(210px, 1fr)`）。
const double kMediaPosterEpisodeMinTileWidth = 220;

/// 面板正文宽到这个值起分集走剧照网格；更窄时一集一行（剧照在左，设计稿手机态）。
const double kMediaPosterEpisodeGridMinWidth = 560;

/// 一集一行时的行高。
const double kMediaPosterEpisodeRowHeight = 104;

/// 一行时的剧照宽。
const double kMediaPosterEpisodeRowThumbWidth = 132;

/// 集名最多行数（竖排剧照格与一集一行同一值）：无刮削集名时标题是整条发布文件名，
/// 单行省略会把集号 / 规格吃掉（BUG-1546）。
const int kMediaPosterEpisodeTitleLines = 2;

/// 竖排剧照格里集简介的最多行数（一集一行时行高钳死，只给一行）。
const int kMediaPosterEpisodeSummaryLines = 2;

/// 剧照网格的列数。
int mediaPosterEpisodeColumns(double width, double spacing) => math.max(
  2,
  ((width + spacing) / (kMediaPosterEpisodeMinTileWidth + spacing)).floor(),
);

/// 竖排剧照格在列宽 [width] 下的格高：剧照 + 进度条 + 文字区（集名两行 + 元信息
/// 一行 + [summaryLines] 行集简介 + 状态行，按 [textScaler] 量，与
/// [MediaPosterEpisodeTile] 的字号同步）。集名按两行留高：无刮削集名时标题是整条
/// 发布文件名，单行省略会把集号 / 规格吃掉（BUG-1546）。[summaryLines] 由调用页
/// 按「本页可见集里有没有集简介」给（[kMediaPosterEpisodeSummaryLines] 或 0）。
/// 格子本身贴合内容画底（续播高亮不拖一截空底），这里只给网格定行高。
double mediaPosterEpisodeTileHeight(
  double width, {
  TextScaler textScaler = TextScaler.noScaling,
  int summaryLines = 0,
}) {
  final double thumbH = (width - kMediaPosterEpisodePadding * 2) * 9 / 16;
  final double textH =
      textScaler.scale(13) * 1.3 * kMediaPosterEpisodeTitleLines +
      2 +
      textScaler.scale(11) * 1.3 +
      (summaryLines > 0 ? 2 + textScaler.scale(11) * 1.3 * summaryLines : 0) +
      4 +
      math.max(15.0, textScaler.scale(11.5) * 1.45);
  return kMediaPosterEpisodePadding * 2 + thumbH + 6 + 4 + 6 + textH.ceil();
}

/// 分集剧照格（见文件头）。纯视觉：手势归外层网格 / 焦点目标，整格
/// [IgnorePointer]；悬停由 [FushiHoverLiftRelay] 代收（与旧集卡同一做法）。
/// 关键子件的 key 沿用旧集卡（`collection-episode-*`），测试同一把 finder。
class MediaPosterEpisodeTile extends StatelessWidget {
  const MediaPosterEpisodeTile({
    required this.image,
    required this.title,
    this.number,
    this.identityLabel,
    this.meta = const <String>[],
    this.summary,
    this.completed = false,
    this.positionMs = 0,
    this.progress,
    this.isContinue = false,
    this.isRemote = false,
    this.downloadBadge,
    this.trailingStatus,
    this.horizontal = false,
    super.key,
  });

  /// 剧照 / 集缩略图；null = 占位。
  final ImageProvider? image;
  final String title;

  /// 集简介（集级刮削资料，TODO-2491）；null / 空 = 不占位。竖排剧照格最多
  /// [kMediaPosterEpisodeSummaryLines] 行，一集一行时一行。
  final String? summary;

  /// 显示序号（`3`）；null = 来源没给集号，只显示集名。
  final String? number;
  final String? identityLabel;
  final List<String> meta;
  final bool completed;
  final int positionMs;

  /// 观看进度 0..1（知道总时长时）；null = 不画进度条、不写百分比。
  final double? progress;
  final bool isContinue;
  final bool isRemote;

  /// 下载态：进行中（[RemoteDownloadProgressBadge]）盖满剧照；失败角标进状态行。
  final Widget? downloadBadge;

  /// 状态行末端（规格摘要）。
  final Widget? trailingStatus;

  /// true = 一集一行（剧照在左）。
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    return FushiHoverLiftRelay(
      builder: (BuildContext context, bool _) => IgnorePointer(
        child: FushiHoverLift(
          scale: kFushiWideCardHoverLiftScale,
          builder: (BuildContext context, bool hovering) => LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                _buildTile(context, constraints, hovering),
          ),
        ),
      ),
    );
  }

  Widget _buildTile(
    BuildContext context,
    BoxConstraints constraints,
    bool hovering,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool dimmed = completed && !isContinue;
    final Duration motion = fushiMotionDuration(context, FushiMotion.short);
    Widget dim(Widget child, String key) => AnimatedOpacity(
      key: ValueKey<String>(key),
      opacity: dimmed ? kMediaDetailCompletedOpacity : 1,
      duration: motion,
      child: child,
    );
    final double? progress = this.progress;
    final double? fraction = positionMs > 0 && progress != null && progress > 0
        ? progress.clamp(0.0, 1.0)
        : null;
    // 续播那一集整格抬一阶底色；悬停叠一层前景 7%（设计稿 `.ep:hover`）。
    final Color fill = isContinue
        ? cs.primaryContainer
        : (hovering
              ? cs.onSurface.withValues(alpha: 0.07)
              : Colors.transparent);
    const double pad = kMediaPosterEpisodePadding;
    final double thumbW = horizontal
        ? kMediaPosterEpisodeRowThumbWidth
        : constraints.maxWidth - pad * 2;
    final double thumbH = thumbW * 9 / 16;
    final Widget? badge = downloadBadge;
    final bool badgeCoversThumb = badge is RemoteDownloadProgressBadge;
    final Widget thumb = Stack(
      children: <Widget>[
        dim(
          collectionEpisodeThumb(context, image, w: thumbW, h: thumbH),
          'collection-episode-thumb',
        ),
        if (badge is RemoteDownloadProgressBadge) Positioned.fill(child: badge),
      ],
    );
    final Widget bar = SizedBox(
      height: 4,
      child: fraction == null
          ? null
          : ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(2)),
              child: FushiLinearProgressIndicator(
                key: const ValueKey<String>('collection-episode-progress'),
                value: fraction,
                minHeight: 4,
                backgroundColor: cs.onSurface.withValues(alpha: 0.12),
                color: cs.primary,
              ),
            ),
    );
    final Widget text = _buildText(
      context,
      dim: dim,
      failedBadge: badge != null && !badgeCoversThumb ? badge : null,
    );
    final Widget content = horizontal
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  thumb,
                  const SizedBox(height: 6),
                  SizedBox(width: thumbW, child: bar),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(child: text),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              thumb,
              const SizedBox(height: 6),
              bar,
              const SizedBox(height: 6),
              // 松约束：内容短就贴合，超出格高时文字区自己裁（ClipRect）。
              Flexible(child: text),
            ],
          );
    final Widget tile = AnimatedContainer(
      duration: motion,
      decoration: ShapeDecoration(
        shape: shellShape(context, BorderRadius.circular(20)),
        color: fill,
      ),
      padding: const EdgeInsets.all(pad),
      child: content,
    );
    // 竖排剧照格贴合内容画底（网格行高按最高的一格给，短的那格不拖一截空底）；
    // 一行一集的横排照旧铺满行高（同一行里左右对齐）。
    if (horizontal) return tile;
    return Align(alignment: Alignment.topCenter, child: tile);
  }

  Widget _buildText(
    BuildContext context, {
    required Widget Function(Widget child, String key) dim,
    required Widget? failedBadge,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextStyle base =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final Color variant = cs.onSurfaceVariant;
    final String? number = this.number;
    final List<String> metaParts = <String>[
      if (identityLabel case final String label when label.trim().isNotEmpty)
        label.trim(),
      for (final String part in meta)
        if (part.trim().isNotEmpty) part.trim(),
    ];
    final double? progress = this.progress;
    final double? percent = positionMs > 0 && progress != null && progress > 0
        ? progress.clamp(0.0, 1.0)
        : null;
    final Widget completedIcon = FushiIcon(
      FushiIcons.filled(FushiIcons.success),
      key: const ValueKey<String>('collection-episode-completed'),
      color: cs.primary,
      size: 15,
    );
    final TextStyle statusStyle = base.copyWith(
      fontSize: context.fushiType.labelSmall.fontSize,
      fontWeight: FontWeight.w600,
      color: variant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final Widget? watched = positionMs > 0
        ? Row(
            key: const ValueKey<String>('collection-episode-watched'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (completed)
                completedIcon
              else
                FushiIcon(FushiIcons.playCircle, color: variant, size: 14),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  collectionEpisodeWatchedLabel(
                    positionMs: positionMs,
                    progress: percent,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: statusStyle,
                ),
              ),
            ],
          )
        : completed
        ? completedIcon
        : null;
    final Widget status = Wrap(
      key: const ValueKey<String>('collection-episode-status'),
      spacing: 8,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        ?watched,
        if (failedBadge != null)
          failedBadge
        else if (isRemote)
          FushiIcon(FushiIcons.cloud, size: 14, color: variant),
        ?trailingStatus,
      ],
    );
    return ClipRect(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          dim(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  number == null ? title : '$number. $title',
                  maxLines: kMediaPosterEpisodeTitleLines,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(
                    fontSize: context.fushiType.bodySmall.fontSize,
                    fontWeight: isContinue ? FontWeight.w800 : FontWeight.w700,
                    height: 1.3,
                    color: cs.onSurface,
                  ),
                ),
                if (metaParts.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      metaParts.join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: base.copyWith(
                        fontSize: context.fushiType.labelSmall.fontSize,
                        color: variant,
                        height: 1.3,
                      ),
                    ),
                  ),
                if (summary case final String text when text.trim().isNotEmpty)
                  Padding(
                    key: const ValueKey<String>('collection-episode-summary'),
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      text.trim(),
                      maxLines: horizontal
                          ? 1
                          : kMediaPosterEpisodeSummaryLines,
                      overflow: TextOverflow.ellipsis,
                      style: base.copyWith(
                        fontSize: context.fushiType.labelSmall.fontSize,
                        color: variant,
                        height: 1.3,
                      ),
                    ),
                  ),
              ],
            ),
            'collection-episode-content',
          ),
          const SizedBox(height: 4),
          status,
        ],
      ),
    );
  }
}
