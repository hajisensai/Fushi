/// 音乐曲目行的「海报大字」外观（重设计外壳，[musicTrackRowSurfaceActive] 为 true
/// 时用；墨水屏照旧走 `FushiGroupedListItem` + `FushiListItem` 的灰底分组卡）：
///
/// - 每行一条独立的平滑圆角条（[shellShape]），静止透明、行与行之间留一道小缝，
///   不再有灰底分组卡与分隔线；
/// - 悬停 / 键盘焦点 / 按下时整条铺这首歌封面取色的色块底（[FushiCoverBlockColors]，
///   与 `FushiCoverBlock` 同一份 `coverColorSchemeCache` 与同一套 HSL，经
///   [MusicCoverPalette]），字换色块前景色，封面小图轻微抬起、偏转
///   （[FushiHoverLift]）；
/// - 正在播放的行常驻色块底，并在末端压一行 900 字重的低透明度标题水印（与
///   `FushiCoverBlock` 的水印同一套字号比例 / 字距 / 透明度），被条带裁掉；
/// - 标题 800 字重、时长等宽数字、序号（专辑曲序 / 榜单名次）用强调色 900 字重。
///
/// 行为不归本组件管：点按 / 长按 / 右键 / 焦点由内部的 [FushiCard] 照常承接，行尾
/// 的 MV 键、VIP / 试听标记、「⋯」菜单、拖拽把手由调用方经 [MusicTrackRowSurface.trailing]
/// / [MusicTrackRowSurface.badges] 原样传进来。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart'
    show MusicCover, MusicCoverTintSource, kMusicHoverLiftScale;
import 'package:fushi/src/pages/implementations/music/music_detail_chrome.dart'
    show MusicCoverPalette;
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellClip, shellRedesignActive, shellShape;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show
        FushiCoverBlock,
        FushiCoverBlockArt,
        FushiCoverBlockColors,
        FushiCoverBlockSize,
        fushiCoverBlockShape;
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart'
    show kFushiCoverBlockHeight;
import 'package:fushi/src/utils/components/fushi_poster_block.dart'
    show FushiPosterBlock, FushiPosterWatermarkEdge;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiFilledButton;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_bleed_title.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiCard;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show shelfCoverCard;

/// 曲目行是否换成 [MusicTrackRowSurface]（重设计外壳生效、非墨水屏）。
bool musicTrackRowSurfaceActive(BuildContext context) =>
    shellRedesignActive(context);

/// 曲目行条带圆角（平滑圆角下由 [shellShape] 再放大）。
const double kMusicTrackRowRadius = 16;

/// 相邻两行之间的缝（条带上下各让一半）。
const double kMusicTrackRowGap = 4;

/// 曲目网格的最小列宽：可用宽放得下几列这么宽的格子就排几列（推荐页曲目段与歌单
/// 详情页同一口径）。约 600 宽两列、960 宽三列。
const double kMusicTrackGridMinColumnWidth = 296;

/// 曲目网格相邻两列之间的缝（行与行之间是 [kMusicTrackRowGap]）。
const double kMusicTrackGridColumnGap = kMusicTrackRowGap * 2;

/// 曲目网格最多几列（再宽也不把一行切得更碎，标题要放得下）。
const int kMusicTrackGridMaxColumns = 4;

/// 可用宽 [width] 下曲目网格排几列；窄窗退回单列。
int musicTrackGridColumns(double width) {
  if (!width.isFinite) return 1;
  final int cols =
      ((width + kMusicTrackGridColumnGap) /
              (kMusicTrackGridMinColumnWidth + kMusicTrackGridColumnGap))
          .floor();
  return cols.clamp(1, kMusicTrackGridMaxColumns);
}

/// 曲目网格的一行：[cols] 等宽列，列间留 [kMusicTrackGridColumnGap]，不满的
/// 末行用空位补齐（格子宽与上面各行一致）。
Widget musicTrackGridRow({
  required int row,
  required int cols,
  required int itemCount,
  required IndexedWidgetBuilder itemBuilder,
  required BuildContext context,
}) => Row(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: <Widget>[
    for (int k = 0; k < cols; k++)
      Expanded(
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            end: k < cols - 1 ? kMusicTrackGridColumnGap : 0,
          ),
          child: row * cols + k < itemCount
              ? itemBuilder(context, row * cols + k)
              : const SizedBox.shrink(),
        ),
      ),
  ],
);

/// 段标题右侧动作的种类（[musicSectionAction]）。
enum MusicSectionActionKind {
  /// 播放这一段（播放图标在前）。
  play,

  /// 进二级页看全部（箭头在后，随阅读方向镜像）。
  viewAll,
}

/// 音乐推荐 / 主页段标题右侧动作的统一样式（2026-11-13 用户：「播放」与「查看
/// 全部」样式不统一）：一律是色调胶囊按钮（[FushiFilledButton.tonalIcon]）+ 按压
/// 缩放。「播放」图标在前，「查看全部」箭头在后（[FushiIcons.chevronRight] 随阅读
/// 方向镜像）。
Widget musicSectionAction({
  required MusicSectionActionKind kind,
  required String label,
  required VoidCallback? onPressed,
  Key? key,
}) => FushiPressScale(
  child: FushiFilledButton.tonalIcon(
    key: key,
    onPressed: onPressed,
    icon: FushiIcon(
      kind == MusicSectionActionKind.play
          ? FushiIcons.play
          : FushiIcons.chevronRight,
    ),
    label: Text(label),
    iconAlignment: kind == MusicSectionActionKind.viewAll
        ? IconAlignment.end
        : IconAlignment.start,
  ),
);

/// 向曲目行广播「这一行排在曲目色块面板（[MusicTrackGridPanel]）里，面板配色是
/// [colors]」：行静止时字用面板前景色，悬停 / 焦点 / 按下 / 正在播放时铺一层面板
/// 前景色的半透明状态层（不再逐行取封面色——同一块色底上再换色相的条带反而糊）。
class MusicTrackPanelScope extends InheritedWidget {
  const MusicTrackPanelScope({
    required this.colors,
    required super.child,
    super.key,
  });

  final FushiCoverBlockColors colors;

  static FushiCoverBlockColors? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MusicTrackPanelScope>()
      ?.colors;

  @override
  bool updateShouldNotify(MusicTrackPanelScope oldWidget) =>
      oldWidget.colors.container != colors.container ||
      oldWidget.colors.onContainer != colors.onContainer ||
      oldWidget.colors.accent != colors.accent;
}

/// 推荐 / 主页里「一段歌曲」的色块面板（2026-11-13 用户：「新歌速递和最近播放
/// 看起来不像在同个图层」）。整段曲目装进一块与上下封面色块同一层级的大色块：
///
/// - 外形 / 圆角 / 投影与海报色块同一套（[FushiPosterBlock]，规整档，按实际高度取
///   `fushiCoverBlockRadius`）；
/// - 底色取段内首曲封面的色相（[MusicCoverPalette]，与 `FushiCoverBlock` 同一套
///   HSL），没封面 / 还没算好退中性 tonal surface（surfaceContainerHigh）；
/// - 底边压一行段标题的 900 字重水印大字，字号与封面色块水印同比例
///   （规整块高 × 0.62）；
/// - 曲目行（[MusicTrackRowSurface]，经 [MusicTrackPanelScope] 换面板配色）按面板内宽
///   排成 1–4 列网格（[musicTrackGridColumns]）。
///
/// 面板本身不是点按目标（不抬升、水印不滑），交互全在行上。
class MusicTrackGridPanel extends StatelessWidget {
  const MusicTrackGridPanel({
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    super.key,
    this.coverPath,
  });

  /// 段标题：画成底边水印（纯装饰，不进语义——段标题行里已经读过一遍）。
  final String title;

  /// 取色用的封面（段内首曲）。
  final String? coverPath;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    return MusicCoverPalette(
      coverPath: coverPath,
      builder: (BuildContext context, FushiCoverBlockColors colors) =>
          FushiPosterBlock(
            watermark: title,
            colors: colors,
            hoverEnabled: false,
            watermarkEdge: FushiPosterWatermarkEdge.bottom,
            watermarkFontSize: kFushiCoverBlockHeight * 0.62,
            padding: EdgeInsets.all(gap),
            child: MusicTrackPanelScope(
              colors: colors,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  final int cols = musicTrackGridColumns(c.maxWidth);
                  final int rows = (itemCount / cols).ceil();
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (int r = 0; r < rows; r++)
                        musicTrackGridRow(
                          row: r,
                          cols: cols,
                          itemCount: itemCount,
                          itemBuilder: itemBuilder,
                          context: context,
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
    );
  }
}

/// 曲目区的一格曲目（重设计外壳「色块」样式，样式切换见
/// `music_collection_view.dart`）：与推荐页 / 曲库同款的封面色块——方形专辑
/// 摆法、封面取色底、曲名水印大字；副行是歌手 · 专辑，底行 chip 是时长，正在播放
/// 时顶上多一枚「正在播放」chip。点块 = 从这首起播（[onTap] 为 null 的不可播曲目
/// 不响应）；右键菜单由调用方包（[musicWithContextMenu]）。几千首的歌单由
/// `SliverFushiCoverBlocks` 按行惰性构建（2026-11-12 用户：「做成多列的……色块弄大，
/// 跟外面一样并且有大字」）。
class MusicTrackBlock extends StatelessWidget {
  const MusicTrackBlock({
    required this.title,
    required this.size,
    super.key,
    this.subtitle,
    this.coverPath,
    this.embeddedFromPath,
    this.durationText,
    this.playing = false,
    this.onTap,
    this.onLongPress,
    this.focusId,
  });

  final String title;
  final FushiCoverBlockSize size;
  final String? subtitle;
  final String? coverPath;

  /// 没有 [coverPath] 时从这个音频文件取内嵌封面（本地曲目）。
  final String? embeddedFromPath;
  final String? durationText;
  final bool playing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final FushiFocusId? focusId;

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  @override
  Widget build(BuildContext context) => FushiHoverLift(
    scale: kMusicHoverLiftScale,
    builder: (BuildContext context, bool _) => shelfCoverCard(
      shape: fushiCoverBlockShape(context, size),
      focusId: focusId,
      onTap: onTap,
      onLongPress: onLongPress,
      child: MusicCoverTintSource(
        coverPath: coverPath,
        embeddedFromPath: embeddedFromPath,
        builder: (BuildContext context, ImageProvider? tint) => FushiCoverBlock(
          size: size,
          art: FushiCoverBlockArt.square,
          title: title,
          subtitle: _nonEmpty(subtitle),
          eyebrow: playing ? t.music_now_playing : null,
          chip: _nonEmpty(durationText),
          covers: <Widget>[
            MusicCover(
              coverPath: coverPath,
              embeddedFromPath: embeddedFromPath,
              borderRadius: BorderRadius.zero,
            ),
          ],
          tintImage: tint,
        ),
      ),
    ),
  );
}

/// 一行曲目的外观件。见库注释。
class MusicTrackRowSurface extends StatefulWidget {
  const MusicTrackRowSurface({
    required this.title,
    super.key,
    this.subtitle,
    this.subtitleWidget,
    this.leading,
    this.ordinal,
    this.coverPath,
    this.embeddedFromPath,
    this.durationText,
    this.badges = const <Widget>[],
    this.trailing = const <Widget>[],
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.playing = false,
    this.focusId,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  });

  /// 标题（也是正在播放时的水印字）。
  final String title;

  /// 副行（艺人 · 专辑 · 备注）；null / 空串不画。
  final String? subtitle;

  /// 自带构造的副行（带续播进度等富内容，如 `musicTrackSubtitleWithResume`）；
  /// 给了就代替 [subtitle]，字样仍套副行的字号与颜色。
  final Widget? subtitleWidget;

  /// 起始侧的封面小图（悬停 / 焦点 / 按下时抬起偏转）。与 [ordinal] 同时给时
  /// 序号在前、封面在后。
  final Widget? leading;

  /// 序号（专辑曲序 / 榜单名次），强调色 900 字重。
  final String? ordinal;

  /// 取色用的封面（目录 / 缓存 / 服务器封面，与 `MusicCover.coverPath` 同一口径）。
  final String? coverPath;

  /// 没有 [coverPath] 时从这个音频文件取内嵌封面取色（本地曲目）。
  final String? embeddedFromPath;

  /// 时长文字（已格式化），等宽数字画在行尾动作前；null 不画。
  final String? durationText;

  /// 紧跟标题的小标记（VIP / 试听 / 无损等），原样传入。
  final List<Widget> badges;

  /// 行尾控件（MV 键、「⋯」菜单、拖拽把手……），按序排在时长之后。
  final List<Widget> trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

  /// 这首正在播放：常驻色块底 + 末端标题水印。
  final bool playing;

  final FushiFocusId? focusId;

  /// 条带内边距。
  final EdgeInsetsGeometry padding;

  @override
  State<MusicTrackRowSurface> createState() => _MusicTrackRowSurfaceState();
}

class _MusicTrackRowSurfaceState extends State<MusicTrackRowSurface> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  /// 交互态（不含正在播放）：封面抬起只看这个。
  bool get _engaged => _hovered || _focused || _pressed;

  bool get _tinted => _engaged || widget.playing;

  void _set({bool? hovered, bool? focused, bool? pressed}) {
    final bool h = hovered ?? _hovered;
    final bool f = focused ?? _focused;
    final bool p = pressed ?? _pressed;
    if (h == _hovered && f == _focused && p == _pressed) return;
    setState(() {
      _hovered = h;
      _focused = f;
      _pressed = p;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    // 面板里（[MusicTrackGridPanel]）：配色跟面板走，不再逐行取封面色；按下多一层
    // 缩放反馈。
    final FushiCoverBlockColors? panel = MusicTrackPanelScope.maybeOf(context);
    if (panel != null) {
      return FushiPressScale(
        enabled: widget.onTap != null,
        child: _buildStrip(context, panel, duration, panel: true),
      );
    }
    // 只在要铺色时才给取色件封面：静止的行不为每张小图跑一遍取色。树形恒定，
    // 只换参数，取色件一直在。
    return MusicCoverPalette(
      coverPath: _tinted ? widget.coverPath : null,
      embeddedFromPath: _tinted ? widget.embeddedFromPath : null,
      builder: (BuildContext context, FushiCoverBlockColors colors) =>
          _buildStrip(context, colors, duration),
    );
  }

  /// [panel]：排在曲目色块面板里——[colors] 是面板配色，字恒用面板前景色，铺色
  /// 换成面板前景色的半透明状态层。
  Widget _buildStrip(
    BuildContext context,
    FushiCoverBlockColors colors,
    Duration duration, {
    bool panel = false,
  }) {
    final bool tinted = _tinted;
    const BorderRadius radius = BorderRadius.all(
      Radius.circular(kMusicTrackRowRadius),
    );
    final ThemeData theme = Theme.of(context);
    final bool onBlock = tinted || panel;
    final Color foreground = onBlock
        ? colors.onContainer
        : theme.colorScheme.onSurface;
    final Color secondary = onBlock
        ? colors.onContainer.withValues(alpha: 0.72)
        : theme.colorScheme.onSurfaceVariant;
    final Color accent = onBlock ? colors.accent : theme.colorScheme.primary;
    final Color fill = !tinted
        ? Colors.transparent
        : panel
        ? colors.onContainer.withValues(alpha: _engaged ? 0.12 : 0.08)
        : colors.container;

    final Widget content = IconTheme.merge(
      data: IconThemeData(color: foreground),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: foreground),
        child: _buildContent(context, secondary, accent, duration),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kMusicTrackRowGap / 2),
      child: MouseRegion(
        onEnter: (_) => _set(hovered: true),
        onExit: (_) => _set(hovered: false),
        child: Listener(
          onPointerDown: (_) => _set(pressed: true),
          onPointerUp: (_) => _set(pressed: false),
          onPointerCancel: (_) => _set(pressed: false),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            // 只有键盘 / 手柄焦点才铺色：鼠标点一下留下的焦点不算。
            onFocusChange: (bool f) => _set(
              focused:
                  f &&
                  FocusManager.instance.highlightMode ==
                      FocusHighlightMode.traditional,
            ),
            child: AnimatedContainer(
              duration: duration,
              curve: FushiMotion.standard,
              decoration: ShapeDecoration(
                color: fill,
                shape: shellShape(context, radius),
              ),
              child: ShellClip(
                radius: radius,
                child: Stack(
                  children: <Widget>[
                    if (widget.playing)
                      Positioned.fill(
                        child: _RowWatermark(
                          title: widget.title,
                          colors: colors,
                        ),
                      ),
                    FushiCard(
                      color: Colors.transparent,
                      borderRadius: radius,
                      stateLayer: false,
                      clipBehavior: Clip.none,
                      padding: widget.padding,
                      onTap: widget.onTap,
                      onLongPress: widget.onLongPress,
                      onSecondaryTap: widget.onSecondaryTap,
                      focusId: widget.focusId,
                      child: content,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    Color secondary,
    Color accent,
    Duration duration,
  ) {
    final FushiTypography type = context.fushiType;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? subtitle = widget.subtitle;
    final String? ordinal = widget.ordinal;
    final Widget? leading = widget.leading;
    final String? durationText = widget.durationText;
    return Row(
      children: <Widget>[
        if (ordinal != null)
          SizedBox(
            width: 32,
            child: Text(
              ordinal,
              textAlign: TextAlign.end,
              maxLines: 1,
              style: type.titleMedium.copyWith(
                color: accent,
                fontWeight: FontWeight.w900,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        if (ordinal != null && leading != null)
          SizedBox(width: tokens.spacing.gap),
        if (leading != null)
          FushiHoverLift(
            forceLifted: _engaged,
            builder: (BuildContext context, bool lifted) => AnimatedRotation(
              duration: duration,
              curve: FushiMotion.standard,
              // 抬起时轻轻偏一点（约 -2.5°），与色块里压着的封面同一种姿态。
              turns: lifted ? -0.007 : 0,
              child: leading,
            ),
          ),
        SizedBox(width: tokens.spacing.gap * 1.25),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodyLarge.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  for (final Widget badge in widget.badges) ...<Widget>[
                    const SizedBox(width: 6),
                    badge,
                  ],
                ],
              ),
              if (widget.subtitleWidget case final Widget custom)
                DefaultTextStyle.merge(
                  style: type.bodySmall.copyWith(color: secondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  child: custom,
                )
              else if (subtitle != null && subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.bodySmall.copyWith(color: secondary),
                ),
            ],
          ),
        ),
        if (durationText != null) ...<Widget>[
          SizedBox(width: tokens.spacing.gap),
          Text(
            durationText,
            style: type.bodySmall.copyWith(
              color: secondary,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
        ...widget.trailing,
      ],
    );
  }
}

/// 正在播放行末端的标题水印：纯装饰，不进语义、不参与命中；字号比例 / 字距 /
/// 行高 / 透明度与 `FushiCoverBlock` 的水印同一套，从条带中段起往末端排、被条带
/// 裁掉。
class _RowWatermark extends StatelessWidget {
  const _RowWatermark({required this.title, required this.colors});

  final String title;
  final FushiCoverBlockColors colors;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) {
      final double height = box.maxHeight.isFinite ? box.maxHeight : 64;
      // 画出来的装饰大字（不是 Text）：不进语义、不进文字查找，标题只读一遍。
      return FushiBleedTitle(
        text: title,
        textSize: height * 0.62,
        color: colors.accent.withValues(alpha: colors.watermarkOpacity),
        start: box.maxWidth.isFinite ? box.maxWidth * 0.42 : 0,
        top: height * 0.02,
      );
    },
  );
}

/// 监听音乐引擎、只在「[trackUid] 是不是当前曲」翻转时重建（引擎播放中频繁通知，
/// 每行直接 ListenableBuilder 会跟着位置刷新整行重建）。
class MusicNowPlayingMatch extends StatefulWidget {
  const MusicNowPlayingMatch({
    required this.listenable,
    required this.isCurrent,
    required this.builder,
    super.key,
  });

  /// 音乐引擎（或任何会在当前曲变化时通知的对象）。
  final Listenable listenable;

  /// 当前是否正在播这一行。
  final bool Function() isCurrent;

  final Widget Function(BuildContext context, bool playing) builder;

  @override
  State<MusicNowPlayingMatch> createState() => _MusicNowPlayingMatchState();
}

class _MusicNowPlayingMatchState extends State<MusicNowPlayingMatch> {
  late bool _playing = widget.isCurrent();

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(MusicNowPlayingMatch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    _playing = widget.isCurrent();
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final bool now = widget.isCurrent();
    if (now != _playing) setState(() => _playing = now);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _playing);
}
