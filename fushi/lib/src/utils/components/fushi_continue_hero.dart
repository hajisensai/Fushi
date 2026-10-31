import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 书架 / 漫画书架 / 游戏 / 音乐 / 首页共用的「继续」大卡（2026-10-28 统一）：
/// tonal 纯色卡，起始侧封面，「眉标 → 标题 → 元信息 → 进度」。
/// 整卡点按 = 继续，悬停抬升（[FushiHoverLift]）、按压下沉与焦点环由
/// [FushiCard] 提供；进场随页面错峰淡入。
///
/// 不画背景图（模糊封面底纹 2026-10-28 撤掉）。这是 [FushiContinueSpotlight]
/// 的竖封面主卡皮；横图剧照主卡是同一组件里的剧照叠层皮。
///
/// 卡宽封顶 [maxWidth]、贴起始侧（用户同日「横屏全宽有点丑」）：满宽铺开时
/// 封面与文字只占起始侧一小块，剩下一大片空。
///
/// 卡上不放任何按钮（2026-10-28 用户拍板）：整卡点按 = 继续，「详情 / 打开专辑」
/// 这类次动作走长按 / 右键（[onLongPress]）。整卡是唯一的焦点站点。
///
/// 底色与合集详情 hero 同一块色（[fushiHeroBlockColor]），库页外的「继续」卡与
/// 合集里的 hero 一眼看出是同一种东西。
class FushiContinueHero extends StatelessWidget {
  const FushiContinueHero({
    required this.cover,
    required this.eyebrow,
    required this.title,
    required this.onOpen,
    this.coverAspectRatio = 2 / 3,
    this.metaLines = const <String>[],
    this.progress,
    this.progressLabel,
    this.focusId,
    this.cardKey,
    this.progressKey,
    this.entranceIndex = 0,
    this.frameCover = true,
    this.onLongPress,
    this.metaIcon,
    this.widthCap,
    this.coverHeight,
    super.key,
  });

  /// 调用方指定的封面高（首页宽屏主卡按版面放大，用户 2026-10-31 选定方案 A
  /// 「书影主卡」）；null = 按卡宽分档（宽卡 [_roomyCoverHeight]、窄卡 102）。
  /// 横图封面仍受「宽不超过卡宽 40%」约束，实际高度可能更矮。
  final double? coverHeight;

  /// 内边距（四周同值）：骨架、外部版面计算与真卡同一口径。
  static double _padding(double gap) => gap * 1.5;

  /// 给定封面高时整卡的高（竖封面、宽度放得下时）：首页宽屏把右侧封面行与
  /// 主卡对齐等高用。
  static double heightFor({required double coverHeight, required double gap}) =>
      coverHeight + _padding(gap) * 2;

  /// 调用方按自己的网格给的卡宽上限（书架：与第三本书右缘对齐）；null =
  /// [maxWidth]。
  final double? widthCap;

  /// 卡宽上限，见类注释。尺寸对齐旧版继续卡（用户 2026-10-28 给的旧版截图：
  /// 约 750 宽、封面 112 高、内边距 12）。
  static const double maxWidth = 750;

  /// 内容区（扣掉内边距）≥ 它时是宽卡：封面 [_roomyCoverHeight] 高。
  static const double _roomyMinWidth = 640;

  /// 宽卡封面高（窄卡 102）。
  static const double _roomyCoverHeight = 112;

  /// 首屏骨架用的卡高：与真卡同一套判据（同一个宽度上限与宽 / 窄分档），骨架
  /// 换真卡不跳。
  static double placeholderHeight(double cardWidth, {required double gap}) {
    final double pad = _padding(gap);
    final bool roomy =
        math.min(cardWidth, maxWidth) - pad * 2 >= _roomyMinWidth;
    return (roomy ? _roomyCoverHeight : 102.0) + pad * 2;
  }

  /// 封面（调用方自带材质 / 占位）；[frameCover] 时外面套 [ShelfCoverFrame]。
  final Widget cover;

  /// false：[cover] 自带框（如游戏盒框），不再套 [ShelfCoverFrame]。
  final bool frameCover;

  /// 封面宽高比（书 / 漫画 2:3，游戏盒 [kShelfGameCaseAspectRatio]，视频海报
  /// 2:3 / 剧照 16:9）。封面按**高度**定尺寸。
  final double coverAspectRatio;
  final String eyebrow;
  final String title;
  final List<String> metaLines;

  /// 0..1；null = 不画进度行。
  final double? progress;

  /// 进度条行尾文字（「已读 27%」）。
  final String? progressLabel;

  /// 整卡点按 = 继续（卡上不再单放「继续」主按钮）。
  final VoidCallback? onOpen;
  final FushiFocusId? focusId;
  final Key? cardKey;
  final Key? progressKey;

  /// 长按 / 右键：条目菜单或详情（游戏详情、音乐专辑、视频条目菜单）。
  final VoidCallback? onLongPress;

  /// 第一行元信息前的小图标（视频远端条目的云图标）。
  final IconData? metaIcon;

  /// 错峰进场序号；null = 调用方自己包进场动画。
  final int? entranceIndex;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final Color accent = eink
        ? cs.onSurface
        : (apple ? appleColorsOf(context).accent : tokens.surfaces.primary);
    final TextStyle titleStyle = tokens.type.listTitle.copyWith(
      fontWeight: FontWeight.w700,
      height: 1.2,
    );

    Widget info() {
      final double? v = progress?.clamp(0.0, 1.0);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            eyebrow,
            style: tokens.type.sectionLabel.copyWith(color: accent),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          ShelfTitleOverflowTooltip(
            title: title,
            style: titleStyle,
            maxLines: 2,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
          for (int i = 0; i < metaLines.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: <Widget>[
                  if (i == 0 && metaIcon != null) ...<Widget>[
                    FushiIcon(
                      metaIcon!,
                      size: (tokens.type.metadata.fontSize ?? 12) + 2,
                      color: tokens.type.metadata.color,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      metaLines[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.type.metadata,
                    ),
                  ),
                ],
              ),
            ),
          if (v != null) ...<Widget>[
            SizedBox(height: tokens.spacing.gap * 1.25),
            Row(
              children: <Widget>[
                Expanded(
                  child: FushiLinearProgressIndicator(
                    key: progressKey,
                    value: v,
                    minHeight: 4,
                    borderRadius: const BorderRadius.all(Radius.circular(2)),
                    // MD3 = M3 Expressive 波浪线性进度（轨道间隙 + 末端停止点，
                    // 轨道色取主题的 M3E 轨道色）；Apple 原生细条；墨水屏平直。
                    color: accent,
                    backgroundColor: apple
                        ? appleColorsOf(context).tertiaryFill
                        : null,
                  ),
                ),
                if (progressLabel != null) ...<Widget>[
                  SizedBox(width: tokens.spacing.gap),
                  Text(progressLabel!, style: tokens.type.metadata),
                ],
              ],
            ),
          ],
        ],
      );
    }

    final Widget card = FushiCard(
      key: cardKey,
      focusId: focusId,
      color: eink || apple ? tokens.surfaces.group : fushiHeroBlockColor(cs),
      borderRadius: eink || apple ? null : FushiM3eShape.containerLargeRadius,
      padding: EdgeInsets.zero,
      onTap: onOpen,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints outer) {
          final EdgeInsets pad = EdgeInsets.all(_padding(tokens.spacing.gap));
          final BoxConstraints c = outer.deflate(pad);
          final bool roomy = c.maxWidth >= _roomyMinWidth;
          final double gap = tokens.spacing.gap * (roomy ? 2 : 1.5);
          final double coverHeight =
              this.coverHeight ?? (roomy ? _roomyCoverHeight : 102);
          // 横图封面在窄卡上别吃掉信息列：宽度封顶卡宽 40%。
          final double coverWidth = (coverHeight * coverAspectRatio).clamp(
            0.0,
            c.maxWidth * 0.4,
          );
          final Widget coverBox = SizedBox(
            width: coverWidth,
            height: coverWidth / coverAspectRatio,
            child: frameCover ? ShelfCoverFrame(child: cover) : cover,
          );

          final Widget body = roomy
              // 宽卡：封面 | 信息列（眉标 → 标题 → 元信息 → 进度）；信息列
              // 封顶 520，进度条不被拉成整行长线。
              ? Row(
                  children: <Widget>[
                    coverBox,
                    SizedBox(width: gap),
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: info(),
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        coverBox,
                        SizedBox(width: gap),
                        Expanded(child: info()),
                      ],
                    ),
                  ],
                );
          return Padding(padding: pad, child: body);
        },
      ),
    );
    final Widget lifted = Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widthCap ?? maxWidth),
        child: FushiHoverLift(
          scale: 1.01,
          builder: (BuildContext _, bool __) => card,
        ),
      ),
    );
    final int? index = entranceIndex;
    return index == null
        ? lifted
        : FushiStaggeredEntrance(index: index, child: lifted);
  }
}

/// 「继续」卡与合集详情 hero 共用的 M3E 色块：primaryContainer 叠在
/// surfaceContainerLow 上。
///
/// 深色下 vibrant 方案的 primaryContainer 是 tone 30 的满彩度色（紫色主题下一大块
/// 纯紫，iOS 深色反馈截图），叠 62% 后整块像一面纯色墙、压过封面与正文；深色改叠
/// 32%，色相仍在、彩度降到与其它深色卡面同一档。浅色维持原配比。
Color fushiHeroBlockColor(ColorScheme scheme) => Color.alphaBlend(
  scheme.primaryContainer.withValues(
    alpha: scheme.brightness == Brightness.dark ? 0.32 : 0.62,
  ),
  scheme.surfaceContainerLow,
);

/// 「继续」区里的一个条目（主卡与旁边封面行共用一份数据）。
///
/// 主卡长什么样只看封面方向（[still]）：横图（视频剧照）走剧照叠层皮——
/// 文字压在图底渐变上；竖图（书 / 漫画 / 游戏盒 / 专辑 / 只有竖海报的视频）走
/// [FushiContinueHero] 的封面 + 信息列皮。用户 2026-10-31：「视频只有竖着的
/// 剧照呢 / 合成一个组件吧」——此前视频首屏另有一套 `VideoContinueSpotlight`，
/// 竖海报被塞进 16:9 卡里靠模糊底垫满。
class FushiContinueEntry {
  const FushiContinueEntry({
    required this.key,
    required this.cover,
    required this.title,
    required this.onOpen,
    this.focusId,
    this.coverAspectRatio = 2 / 3,
    this.frameCover = true,
    this.material,
    this.eyebrow,
    this.metaLines = const <String>[],
    this.metaIcon,
    this.subtitle,
    this.progress,
    this.progressLabel,
    this.progressKey,
    this.onLongPress,
    this.orientationImage,
    this.landscapeCover,
    this.subtitleIcon,
  });

  /// 卡键（主卡 = 整卡，封面行 = 封面那张卡）。
  final Key key;
  final FushiFocusId? focusId;

  /// 封面 / 剧照（调用方自带无图占位）；竖图 [frameCover] 时套
  /// [ShelfCoverFrame]。
  final Widget cover;

  /// 宽 / 高；> 1 = 横图剧照（[still]）。
  final double coverAspectRatio;

  /// false：[cover] 自带框（游戏盒），不再套 [ShelfCoverFrame]。
  final bool frameCover;

  /// 竖封面的材质（书皮 / 卡盒 / 专辑）；null = 无材质框。
  final ShelfCoverMaterial? material;
  final String title;

  /// 主卡眉标（「继续阅读」/ 视频「看到第 N 集 · 剩余 M 分钟」）。
  final String? eyebrow;

  /// 主卡（封面皮）眉标与标题下的元信息行。
  final List<String> metaLines;

  /// 眉标 / 第一行元信息前的小图标（远端条目的云图标）。
  final IconData? metaIcon;

  /// 封面行里的一行短副标题（集数 / 作者）；剧照压在图左下，竖封面放标题下。
  final String? subtitle;

  /// 0..1；null = 不画进度。
  final double? progress;

  /// 主卡（封面皮）进度条行尾文字（「已读 27%」）。
  final String? progressLabel;
  final Key? progressKey;
  final VoidCallback? onOpen;

  /// 长按 / 右键：条目菜单或详情。
  final VoidCallback? onLongPress;

  /// 封面方向要等图解码才知道时（首页「继续」混排的视频：作品海报是竖图，
  /// 回落到的每集截图 / 横版画面是横图，用户 2026-10-14「卡片比例跟着实际用到的
  /// 图走」）给它：解码出横图后条目按 16:9 剧照画、封面换成 [landscapeCover]；
  /// 解码前 / 失败 / 竖图按 [coverAspectRatio]。与封面渲染共用同一个 provider。
  final ImageProvider? orientationImage;

  /// 探测为横图时用的封面（横槽渲染）；null = 仍用 [cover]。
  final Widget? landscapeCover;

  /// 封面行副标题前的小图标（视频看到的时间点前的 ▶）。
  final IconData? subtitleIcon;

  /// 横图剧照。
  bool get still => coverAspectRatio > 1;

  /// 按探测结果定型：横图 → 16:9 剧照 + [landscapeCover]；否则原样。
  FushiContinueEntry _oriented(bool landscape) => !landscape
      ? this
      : FushiContinueEntry(
          key: key,
          focusId: focusId,
          cover: landscapeCover ?? cover,
          coverAspectRatio: 16 / 9,
          frameCover: frameCover,
          material: material,
          title: title,
          eyebrow: eyebrow,
          metaLines: metaLines,
          metaIcon: metaIcon,
          subtitle: subtitle,
          subtitleIcon: subtitleIcon,
          progress: progress,
          progressLabel: progressLabel,
          progressKey: progressKey,
          onOpen: onOpen,
          onLongPress: onLongPress,
        );
}

/// 按 [FushiContinueEntry.orientationImage] 的真实宽高比给条目定型再建子树；没给
/// 探测图时直接原样。
class _OrientedEntry extends StatelessWidget {
  const _OrientedEntry({required this.entry, required this.builder});

  final FushiContinueEntry entry;
  final Widget Function(FushiContinueEntry entry) builder;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? image = entry.orientationImage;
    if (image == null) return builder(entry);
    return _EntryAspectProbe(image: image, entry: entry, builder: builder);
  }
}

class _EntryAspectProbe extends StatefulWidget {
  const _EntryAspectProbe({
    required this.image,
    required this.entry,
    required this.builder,
  });

  final ImageProvider image;
  final FushiContinueEntry entry;
  final Widget Function(FushiContinueEntry entry) builder;

  @override
  State<_EntryAspectProbe> createState() => _EntryAspectProbeState();
}

class _EntryAspectProbeState extends State<_EntryAspectProbe>
    with CoverAspectProbe<_EntryAspectProbe> {
  @override
  ImageProvider probedImageOf(_EntryAspectProbe widget) => widget.image;

  /// 只回答横竖，一个像素都不画：不需要主色底采样。
  @override
  bool needsBackdropSeed(double aspect) => false;

  @override
  Widget build(BuildContext context) {
    final double? aspect = coverAspect;
    final bool landscape = !coverFailed && aspect != null && aspect > 1;
    // 冷启动时探测图还没解码，先按竖版排；解出横图后整块换成剧照几何，高度
    // 渐变过去而不是一帧跳变。不裁切：悬停放大与投影要能溢出这块。
    return FushiAnimatedSize(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
      alignment: AlignmentDirectional.topStart,
      clipBehavior: Clip.none,
      child: widget.builder(widget.entry._oriented(landscape)),
    );
  }
}

/// 所有库页与首页的「继续」区（2026-10-31 合一：书架 / 漫画 / 游戏 / 音乐 /
/// 首页 dashboard / 视频首页同一个组件，用户先选定方案 A「书影主卡」，再要求
/// 「合成一个组件」）：
///
/// - 宽屏（≥ [sideBySideMinWidth]）：主卡在起始侧，其余条目的封面行排在它旁边、
///   与主卡等高（行高含悬停放大余量）。全是剧照且主卡够高时排两行横滑网格，
///   否则一行，竖封面与剧照可以混排（统一按高定宽）。
/// - 窄屏：主卡在上；[showSideWhenNarrow] 时封面行挂在下面（首页），库页下面另有
///   自己的「最近」行就不挂。
///
/// 卡上不放按钮：点按 = 继续，长按 / 右键 = 条目菜单。主卡与每张封面都是独立
/// 焦点站点，悬停抬升 + 光面材质（投影、扫光、倾斜、镜面高光）。
class FushiContinueSpotlight extends StatelessWidget {
  const FushiContinueSpotlight({
    required this.main,
    this.side = const <FushiContinueEntry>[],
    this.heroCoverHeight = 200,
    this.soloCoverHeight,
    this.soloWidthCap,
    this.showSideWhenNarrow = false,
    this.narrowSideCoverHeight,
    this.sideRowKey = const ValueKey<String>('fushi-continue-side-row'),
    this.staggerEntrance = true,
    super.key,
  });

  final FushiContinueEntry main;
  final List<FushiContinueEntry> side;

  /// 宽屏并排时竖封面主卡的封面高。
  final double heroCoverHeight;

  /// 没有并排（窄屏 / 没有其余条目）时竖封面主卡的封面高；null =
  /// [FushiContinueHero] 按卡宽分档。
  final double? soloCoverHeight;

  /// 没有并排时竖封面主卡的卡宽上限（书架：与第三本书右缘对齐）；null =
  /// [FushiContinueHero.maxWidth]。
  final double? soloWidthCap;
  final bool showSideWhenNarrow;

  /// 窄屏封面行里竖封面的高；null = 132（全剧照行恒为 16:9 宽 168）。
  final double? narrowSideCoverHeight;
  final Key sideRowKey;

  /// 主卡与封面行各自错峰进场（[FushiStaggeredEntrance]）。外层已经把整个
  /// 「继续」区包进一个进场项的调用方（首页 dashboard、游戏首页）传 false，
  /// 否则同一张卡会叠两层进场动画（淡入 + 位移各走两遍）。
  final bool staggerEntrance;

  /// 内容宽 ≥ 它时主卡与封面行左右并排。
  static const double sideBySideMinWidth = 840;

  /// 宽 [width]、有 [sideCount] 个其余条目时是否并排（库页据此决定另一条「最近」
  /// 横滑行要不要再画，免得同一批封面出现两次）。
  static bool sideBySide(double width, int sideCount) =>
      sideCount > 0 && width >= sideBySideMinWidth;

  /// 剧照主卡宽屏宽度上限（16:9 → 高 360），不像影院横幅那样占半屏。
  static const double _stillMaxWidth = 640;

  /// 窄屏剧照主卡高上限（平板竖屏不让主卡吃掉半屏）。
  static const double _narrowStillMaxHeight = 300;

  static double _gap(double unit) => unit * 1.5;

  /// 宽屏剧照主卡尺寸。
  static Size _wideStillSize(double width) {
    final double w = math.min(width * 0.55, _stillMaxWidth);
    return Size(w, w * 9 / 16);
  }

  /// 首屏骨架的剧照主卡位尺寸：与真主卡同一套几何（[width] 是本组件拿到的
  /// 宽）。骨架只画主卡位——封面行有几张要等数据。
  static Size placeholderStillSize(double width) => width >= sideBySideMinWidth
      ? _wideStillSize(width)
      : Size(width, math.min(width * 9 / 16, _narrowStillMaxHeight));

  /// 封面行：与首页其它横滚行同一套——鼠标 / 触控板可拖（每处各包
  /// [HorizontalDragScrollable]，守卫按文件逐处计数），滑到边缘交给分区级联
  /// （[SectionSwipeCascade]）。不接裸滚轮横滚：外层是纵向滚动，滚轮留给它。
  Widget _sideRow(BuildContext context, double height, double gap) {
    final double metaHeight = ShelfCardMeta.heightFor(context);
    final bool allStill = side.every((FushiContinueEntry e) => e.still);
    const double scale = kFushiHoverLiftScale;
    const double rise = kShelfMaterialHoverRise * scale;
    // 两行只给全剧照且够高的情况（16:9 一行撑满 360 高会大得像主卡）。
    final int rows = allStill && height >= 240 ? 2 : 1;
    // rows 行卡 + 行距 + 上下悬停余量（[shelfHoverLiftHeadroom]）= height。
    final double tileHeight =
        (height - gap * (rows - 1) - 2 * rise) / (rows + scale - 1);
    // 单行里有剧照时封面高封顶：16:9 按 360 高主卡撑满会大得像第二张主卡
    // （一张就 500+ 宽），行在主卡旁竖向居中。
    final double coverHeight = math.max(
      60,
      rows == 1 && side.any((FushiContinueEntry e) => e.still)
          ? math.min(tileHeight - metaHeight, _kStillSideMaxHeight)
          : tileHeight - metaHeight,
    );
    final double vertical =
        (height - rows * (coverHeight + metaHeight) - gap * (rows - 1)) / 2;
    final double widest =
        coverHeight *
        side.fold<double>(
          0,
          (double m, FushiContinueEntry e) => math.max(m, e.coverAspectRatio),
        );
    final EdgeInsets padding = EdgeInsets.symmetric(
      horizontal: widest * (scale - 1) / 2,
      vertical: math.max(0, vertical),
    );
    Widget tile(int i) {
      final Widget child = _OrientedEntry(
        entry: side[i],
        builder: (FushiContinueEntry e) => FushiContinueSideTile(
          entry: e,
          coverHeight: coverHeight,
          metaHeight: metaHeight,
        ),
      );
      return staggerEntrance
          ? FushiStaggeredEntrance(index: i + 1, child: child)
          : child;
    }

    return SizedBox(
      key: sideRowKey,
      height: height,
      child: SectionSwipeCascade(
        child: rows == 1
            ? HorizontalDragScrollable(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: desktopAwareScrollPhysics(),
                  padding: padding,
                  itemCount: side.length,
                  separatorBuilder: (BuildContext _, int __) =>
                      SizedBox(width: gap),
                  itemBuilder: (BuildContext _, int i) => tile(i),
                ),
              )
            : HorizontalDragScrollable(
                child: GridView.builder(
                  scrollDirection: Axis.horizontal,
                  physics: desktopAwareScrollPhysics(),
                  padding: padding,
                  itemCount: side.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: rows,
                    mainAxisSpacing: gap,
                    crossAxisSpacing: gap,
                    mainAxisExtent: coverHeight * 16 / 9,
                  ),
                  itemBuilder: (BuildContext _, int i) => tile(i),
                ),
              ),
      ),
    );
  }

  /// 竖封面主卡（[FushiContinueHero]）。
  Widget _coverMain(
    FushiContinueEntry main, {
    double? coverHeight,
    double? widthCap,
  }) {
    final ShelfCoverMaterial? material = main.material;
    return FushiContinueHero(
      cardKey: main.key,
      focusId: main.focusId,
      cover: material == null
          ? main.cover
          : ShelfCoverMaterialScope(material: material, child: main.cover),
      coverAspectRatio: main.coverAspectRatio,
      frameCover: main.frameCover,
      eyebrow: main.eyebrow ?? '',
      title: main.title,
      metaLines: main.metaLines,
      metaIcon: main.metaIcon,
      progress: main.progress,
      progressLabel: main.progressLabel,
      progressKey: main.progressKey,
      onOpen: main.onOpen,
      onLongPress: main.onLongPress,
      coverHeight: coverHeight,
      widthCap: widthCap ?? soloWidthCap,
      entranceIndex: staggerEntrance ? 0 : null,
    );
  }

  Widget _stillMain(FushiContinueEntry main) {
    final Widget card = _StillMainCard(entry: main);
    return staggerEntrance
        ? FushiStaggeredEntrance(index: 0, child: card)
        : card;
  }

  @override
  Widget build(BuildContext context) => _OrientedEntry(
    entry: main,
    builder: (FushiContinueEntry m) => _layout(context, m),
  );

  Widget _layout(BuildContext context, FushiContinueEntry main) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = _gap(tokens.spacing.gap);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double width = c.maxWidth;
        if (width >= sideBySideMinWidth) {
          final Widget mainCard;
          final double mainWidth;
          final double mainHeight;
          if (main.still) {
            final Size s = _wideStillSize(width);
            mainWidth = s.width;
            mainHeight = s.height;
            mainCard = SizedBox.fromSize(size: s, child: _stillMain(main));
          } else if (side.isEmpty) {
            return _coverMain(main, coverHeight: soloCoverHeight);
          } else {
            mainWidth = (width * 0.42).clamp(440.0, 640.0);
            mainHeight = FushiContinueHero.heightFor(
              coverHeight: heroCoverHeight,
              gap: tokens.spacing.gap,
            );
            mainCard = SizedBox(
              width: mainWidth,
              child: _coverMain(
                main,
                coverHeight: heroCoverHeight,
                widthCap: mainWidth,
              ),
            );
          }
          if (side.isEmpty) {
            return Align(
              alignment: AlignmentDirectional.centerStart,
              child: mainCard,
            );
          }
          return Row(
            children: <Widget>[
              SizedBox(width: mainWidth, child: mainCard),
              SizedBox(width: tokens.spacing.card),
              Expanded(child: _sideRow(context, mainHeight, gap)),
            ],
          );
        }
        final Widget mainCard = main.still
            ? SizedBox(
                height: math.min(width * 9 / 16, _narrowStillMaxHeight),
                child: _stillMain(main),
              )
            : _coverMain(main, coverHeight: soloCoverHeight);
        if (!showSideWhenNarrow || side.isEmpty) return mainCard;
        final bool allStill = side.every((FushiContinueEntry e) => e.still);
        final double coverHeight = allStill
            ? 168 * 9 / 16
            : (narrowSideCoverHeight ?? 132);
        final double tileHeight =
            coverHeight + ShelfCardMeta.heightFor(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            mainCard,
            SizedBox(height: gap),
            _sideRow(
              context,
              tileHeight + shelfHoverLiftHeadroom(tileHeight) * 2,
              gap,
            ),
          ],
        );
      },
    );
  }
}

/// 剧照叠层主卡：眉标 / 片名 / 进度压在底部暗渐变上。
class _StillMainCard extends StatelessWidget {
  const _StillMainCard({required this.entry});

  final FushiContinueEntry entry;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    // 文字压在底部暗渐变上，深浅主题一律用浅色字；眉标取固定色调的浅主色
    // （Apple 取系统强调色，墨水屏纯白），与 [FushiContinueHero] 同一套分派。
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final Color accent = eink
        ? Colors.white
        : (apple ? appleColorsOf(context).accent : cs.primaryFixedDim);
    final double? v = entry.progress?.clamp(0.0, 1.0);
    final String eyebrow = entry.eyebrow ?? '';
    final BorderRadius? radius = eink || apple
        ? null
        : FushiM3eShape.containerLargeRadius;
    return FushiHoverLift(
      enabled: entry.onOpen != null,
      scale: _kStillMainHoverLiftScale,
      builder: (BuildContext _, bool lifted) => _StillMaterial(
        lifted: lifted,
        radius: radius ?? _kStillFallbackRadius,
        card: FushiCard(
          key: entry.key,
          focusId: entry.focusId,
          padding: EdgeInsets.zero,
          borderRadius: radius,
          onTap: entry.onOpen,
          onLongPress: entry.onLongPress,
          onSecondaryTap: entry.onLongPress,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              entry.cover,
              ..._StillMaterial.layers(lifted),
              const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: <Color>[
                        Color(0xE6120E18),
                        Color(0x80120E18),
                        Color(0x00120E18),
                      ],
                      stops: <double>[0, 0.42, 0.75],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: tokens.spacing.gap * 2.5,
                right: tokens.spacing.gap * 2.5,
                bottom: tokens.spacing.gap * 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (eyebrow.isNotEmpty) ...<Widget>[
                      Row(
                        children: <Widget>[
                          if (entry.metaIcon != null) ...<Widget>[
                            FushiIcon(entry.metaIcon!, size: 14, color: accent),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              eyebrow,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.type.sectionLabel.copyWith(
                                color: accent,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                    ],
                    Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: (text.titleLarge ?? const TextStyle()).copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    if (v != null) ...<Widget>[
                      SizedBox(height: tokens.spacing.gap),
                      FushiLinearProgressIndicator(
                        key: entry.progressKey,
                        value: v,
                        minHeight: 4,
                        borderRadius: const BorderRadius.all(
                          Radius.circular(2),
                        ),
                        color: accent,
                        backgroundColor: Colors.white.withValues(alpha: 0.24),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 封面行里的一张：封面按行高定宽（竖封面 / 剧照混排顶底对齐），下面挂库页同款
/// 文字块（[ShelfCardMeta]）。剧照的集数压在图左下、进度贴图底边；竖封面的
/// 副标题与进度在文字块里。
class FushiContinueSideTile extends StatelessWidget {
  const FushiContinueSideTile({
    super.key,
    required this.entry,
    required this.coverHeight,
    required this.metaHeight,
  });

  final FushiContinueEntry entry;
  final double coverHeight;
  final double metaHeight;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double width = coverHeight * entry.coverAspectRatio;
    final String? subtitle = entry.subtitle;
    return FushiHoverLift(
      enabled: entry.onOpen != null,
      builder: (BuildContext context, bool lifted) {
        final Widget cover;
        if (entry.still) {
          cover = _StillMaterial(
            lifted: lifted,
            radius: _kStillSideRadius,
            card: FushiCard(
              key: entry.key,
              focusId: entry.focusId,
              padding: EdgeInsets.zero,
              borderRadius: _kStillSideRadius,
              onTap: entry.onOpen,
              onLongPress: entry.onLongPress,
              onSecondaryTap: entry.onLongPress,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  entry.cover,
                  ..._StillMaterial.layers(lifted),
                  if (subtitle != null && subtitle.isNotEmpty)
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 10,
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.type.metadata.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          shadows: const <Shadow>[
                            Shadow(color: Color(0xCC000000), blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                  if (entry.progress != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: CoverProgressStrip(value: entry.progress!),
                    ),
                ],
              ),
            ),
          );
        } else {
          Widget framed = entry.frameCover
              ? ShelfCoverFrame(child: entry.cover)
              : entry.cover;
          final ShelfCoverMaterial? material = entry.material;
          if (material != null) {
            framed = ShelfCoverMaterialScope(material: material, child: framed);
          }
          cover = shelfCoverCard(
            key: entry.key,
            focusId: entry.focusId,
            borderRadius: shelfCoverRadius(context),
            onTap: entry.onOpen,
            onLongPress: entry.onLongPress,
            onSecondaryTap: entry.onLongPress,
            child: framed,
          );
        }
        // 整张小卡对读屏是一个按钮：封面卡与文字块各自的点按语义并进来，
        // 否则同一条目会读成两三个可点节点。
        return Semantics(
          container: true,
          button: true,
          excludeSemantics: true,
          label: subtitle == null ? entry.title : '${entry.title} · $subtitle',
          onTap: entry.onOpen,
          onLongPress: entry.onLongPress,
          child: SizedBox(
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(width: width, height: coverHeight, child: cover),
                // 文字块也是点按面（封面那张卡只盖封面）。右键走绑定表
                // （ContextMenuTrigger），不硬绑次按钮。
                ContextMenuTrigger(
                  onInvoke: contextMenuInvoker(entry.onLongPress),
                  child: GestureDetector(
                    key: const ValueKey<String>('fushi-continue-tile-meta'),
                    behavior: HitTestBehavior.opaque,
                    onTap: entry.onOpen,
                    onLongPress: entry.onLongPress,
                    child: SizedBox(
                      height: metaHeight,
                      child: ShelfCardMeta(
                        title: entry.title,
                        subtitle: entry.still ? null : subtitle,
                        leadingIcon: entry.still ? null : entry.subtitleIcon,
                        progress: entry.still
                            ? null
                            : entry.progress?.clamp(0.0, 1.0),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 剧照主卡悬停放大：主卡比封面大得多，按 [kFushiHoverLiftScale] 放大会顶出
/// 版面，但 1.01 几乎看不出「抬起」（用户 2026-10-31：视频继续观看缺抬起的
/// 金属效果），取 1.025 配合投影 / 扫光读出抬升。
const double _kStillMainHoverLiftScale = 1.025;

/// 单行封面行里剧照封面的最高高度（16:9 → 宽 320）。
const double _kStillSideMaxHeight = 180;

/// 封面行剧照圆角。
const BorderRadius _kStillSideRadius = BorderRadius.all(Radius.circular(16));

/// Apple / 墨水屏下剧照主卡不传圆角（[FushiCard] 用系统默认），投影按这个近似
/// 圆角画。
const BorderRadius _kStillFallbackRadius = BorderRadius.all(
  Radius.circular(12),
);

/// 剧照卡的「光面材质」悬停反馈，与库页封面（[ShelfMaterialSurface]）同一套：
/// 抬升时投影加深下沉、一道柔光从右往左扫过（[ShelfCoverSheen]，触屏按下也扫
/// 一遍）、3D 倾斜跟随指针（[FushiTilt]）、镜面高光落在指针处（[FushiTiltGlare]）。
/// [layers] 画进卡内的裁切区；本组件包在卡外负责投影与倾斜。墨水屏不画投影
/// （抖动灰），倾斜 / 高光由 [FushiHoverLift] 自行降级。
class _StillMaterial extends StatelessWidget {
  const _StillMaterial({
    required this.lifted,
    required this.radius,
    required this.card,
  });

  final bool lifted;
  final BorderRadius radius;
  final Widget card;

  /// 卡内裁切区里的光层：扫光 + 跟指针的镜面高光。
  static List<Widget> layers(bool lifted) => <Widget>[
    IgnorePointer(child: ShelfCoverSheen(active: lifted)),
    const FushiTiltGlare(),
  ];

  @override
  Widget build(BuildContext context) {
    final bool eink = isEinkTheme(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return FushiTilt(
      child: AnimatedContainer(
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.standard,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: eink
              ? const <BoxShadow>[]
              : shelfMaterialShadows(dark: dark, lifted: lifted),
        ),
        child: card,
      ),
    );
  }
}
