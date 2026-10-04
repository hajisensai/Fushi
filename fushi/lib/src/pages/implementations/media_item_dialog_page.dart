import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/utils.dart';

// ---------------------------------------------------------------------------
// Action data model
// ---------------------------------------------------------------------------
//
// Every action carries a label + icon + onPressed. The three subtypes differ in
// placement / weight in the below-cover action column:
//   * [DialogQuickAction]  -> equal-width quick-action chip (FushiActionChip).
//   * [DialogListAction]   -> a labelled list row under a divider.
//   * [DialogDangerAction] -> a muted, centred destructive button at the bottom.

sealed class DialogAction {
  const DialogAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
}

final class DialogQuickAction extends DialogAction {
  const DialogQuickAction({
    required super.label,
    required super.icon,
    required super.onPressed,
  });
}

final class DialogListAction extends DialogAction {
  const DialogListAction({
    required super.label,
    required super.onPressed,
    super.icon = Icons.tune,
  });
}

final class DialogDangerAction extends DialogAction {
  const DialogDangerAction({
    required super.label,
    required super.onPressed,
    super.icon = Icons.delete_outline,
    this.muted = false,
  });
  final bool muted;
}

// ---------------------------------------------------------------------------
// Dialog page
// ---------------------------------------------------------------------------

class MediaItemDialogPage extends BasePage {
  const MediaItemDialogPage({
    required this.item,
    required this.isHistory,
    this.extraActions,
    this.showLaunchAction = true,
    this.coverFallbackIcon,
    super.key,
  });

  final MediaItem item;
  final bool isHistory;
  final List<DialogAction> Function(MediaItem)? extraActions;
  final bool showLaunchAction;

  /// TODO-1094：当条目没有任何可显示封面（无 override 缩略图 / imageUrl /
  /// base64Image / extraUrl）时，用它作占位图标渲染封面块，而不是整块隐藏封面区。
  /// 供 SRT/字幕卡与网格 `_buildSrtCover` 的占位判据统一；其它来源不传（保持
  /// 「无封面则不渲染封面块」的既有行为）。
  final IconData? coverFallbackIcon;

  @override
  BasePageState createState() => _MediaItemDialogPageState();
}

class _MediaItemDialogPageState extends BasePageState<MediaItemDialogPage> {
  MediaSource get mediaSource => widget.item.getMediaSource(appModel: appModel);

  // -- action categorisation ------------------------------------------------

  List<DialogAction> get _externalActions =>
      widget.extraActions?.call(widget.item) ?? const [];

  List<DialogQuickAction> get _quickActions =>
      _externalActions.whereType<DialogQuickAction>().toList();

  List<DialogListAction> get _listActions => [
        ..._externalActions.whereType<DialogListAction>(),
        if (widget.item.canEdit && widget.isHistory)
          DialogListAction(
            label: t.dialog_edit_info,
            icon: Icons.edit_outlined,
            onPressed: _executeEdit,
          ),
      ];

  List<DialogDangerAction> get _dangerActions => [
        ..._externalActions.whereType<DialogDangerAction>(),
        if (widget.item.canDelete && widget.isHistory)
          DialogDangerAction(
            label: t.dialog_clear,
            icon: Icons.clear_all,
            onPressed: _executeClear,
            muted: true,
          ),
      ];

  // -- callbacks ------------------------------------------------------------

  void _executeEdit() async {
    await showAppDialog(
      context: context,
      builder: (context) => MediaItemEditDialogPage(item: widget.item),
    );
  }

  void _executeLaunch() async {
    Navigator.pop(context);
    await appModel.openMedia(
      mediaSource: mediaSource,
      ref: ref,
      item: widget.item,
    );
  }

  void _executeClear() async {
    final navigator = Navigator.of(context);
    await appModel.deleteMediaItem(widget.item);
    navigator.pop();
  }

  // -- build ----------------------------------------------------------------

  bool get _hasCover =>
      mediaSource.getOverrideThumbnailFromMediaItem(
            appModel: appModel,
            item: widget.item,
          ) !=
          null ||
      (widget.item.imageUrl?.isNotEmpty ?? false) ||
      (widget.item.base64Image?.isNotEmpty ?? false) ||
      (widget.item.extraUrl?.isNotEmpty ?? false);

  @override
  Widget build(BuildContext context) {
    final String displayTitle =
        mediaSource.getDisplayTitleFromMediaItem(widget.item);
    final String? author = widget.item.author;
    final bool hasAuthor = author != null && author.isNotEmpty;

    final IconData? fallbackIcon = widget.coverFallbackIcon;
    final Widget? cover = _hasCover
        ? _buildCover()
        : (fallbackIcon != null ? _buildFallbackCover(fallbackIcon) : null);
    return MediaItemDialogFrame(
      cover: cover,
      title: displayTitle,
      author: hasAuthor ? author : null,
      showLaunchAction: widget.showLaunchAction,
      launchLabel: t.dialog_read,
      onLaunch: _executeLaunch,
      quickActions: _quickActions,
      listActions: _listActions,
      dangerActions: _dangerActions,
      coverBackdrop: _hasCover
          ? mediaSource.getDisplayThumbnailFromMediaItem(
              appModel: appModel,
              item: widget.item,
            )
          : null,
    );
  }

  /// TODO-1094：无真实封面时的占位封面块，居中显示一个来源相关图标。视觉与书架
  /// 网格 `_coverPlaceholderIcon`（size 40 / onSurfaceVariant）保持一致，让长按
  /// 对话框不再出现「网格有占位图标、长按却空白」的不一致。
  Widget _buildFallbackCover(IconData icon) {
    return SizedBox(
      height: 120,
      child: Center(
        child: Icon(
          icon,
          size: 40,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildCover() {
    return FadeInImage(
      placeholder: MemoryImage(kTransparentImage),
      imageErrorBuilder: (_, __, ___) {
        if (widget.item.extraUrl != null) {
          return FadeInImage(
            placeholder: MemoryImage(kTransparentImage),
            imageErrorBuilder: (_, __, ___) => const SizedBox.shrink(),
            image: mediaSource.getDisplayThumbnailFromMediaItem(
              appModel: appModel,
              item: widget.item,
              fallbackUrl: widget.item.extraUrl,
            ),
            fit: BoxFit.contain,
          );
        }
        return const SizedBox.shrink();
      },
      image: mediaSource.getDisplayThumbnailFromMediaItem(
        appModel: appModel,
        item: widget.item,
      ),
      fit: BoxFit.contain,
    );
  }
}

// ---------------------------------------------------------------------------
// Dialog frame (pure layout, testable in isolation)
// ---------------------------------------------------------------------------

/// Long-press / right-click media dialog shared by the book, video, game and
/// collection libraries.
///
/// 2026-10-04 重设计（用户反馈：书架右键弹窗「两侧有空白很丑」）。旧版把封面
/// 整宽 `BoxFit.contain` 画成限高顶块：竖版书封在 420 宽的框里只占中间三分之一，
/// 两侧是大片 letterbox；下面再接一长串单列动作，桌面上又高又窄。现在：
///
/// * **头部（hero）**：封面按**自身宽高比**画成带圆角与投影的封面卡，不再有
///   letterbox；整条头部背后铺同一张图的模糊垫底，并用渐变淡入对话框底色。
///   竖版 / 方形封面（书、漫画、游戏）与标题**并排**；横版封面（视频）自动切到
///   **横幅**，整宽显示、标题在下。宽高比从 [coverBackdrop] 的降采样解码里取，
///   与模糊垫底共用同一次解码。
/// * **宽框（桌面 / 平板）**：对话框放宽到 [_wideMaxWidth]，启动按钮与快捷 chip
///   挪进封面右侧（填掉标题下方的空白），列表动作排成两列，整体高度大幅缩短。
/// * **窄框（手机）**：单列、封面卡缩到 [_narrowCoverWidth]，快捷 chip 在头部下方。
///
/// The launch/read affordance is optional so shelf book long-press menus can
/// stay management-only while ordinary history dialogs can still expose it.
///
/// 不是 `@visibleForTesting`：视频卡（`home_video_page._showVideoMenu`）与游戏卡
/// （`games_library_page._GameCard`）的长按菜单在生产直接复用本骨架——它是三库
/// 共用的正式 API，不再只服务测试。
class MediaItemDialogFrame extends StatelessWidget {
  const MediaItemDialogFrame({
    required this.title,
    this.cover,
    this.author,
    this.showLaunchAction = true,
    this.launchLabel,
    this.onLaunch,
    this.quickActions = const [],
    this.listActions = const [],
    this.dangerActions = const [],
    this.coverBackdrop,
    super.key,
  });

  /// 封面 widget（调用方自己负责 `BoxFit.contain` 与解码失败兜底）。本骨架把它
  /// 放进按宽高比定尺寸的封面卡里，所以 contain 恰好铺满、不留边。
  final Widget? cover;

  /// 封面图源：头部模糊垫底 + 封面宽高比探测共用。
  ///
  /// 只收图源、不复用 [cover] widget：后者可能带 key / GlobalKey，画两遍会撞
  /// key。解码按 [_backdropDecodeWidth] 降采样——模糊后看不出分辨率，宽高比也只差
  /// 不到 1%。为 null（占位图标、拿不到图源）时头部退回纯色底、封面卡按默认竖版
  /// 比例；墨水屏不模糊。
  final ImageProvider? coverBackdrop;
  final String title;
  final String? author;
  final bool showLaunchAction;
  final String? launchLabel;
  final VoidCallback? onLaunch;
  final List<DialogQuickAction> quickActions;
  final List<DialogListAction> listActions;
  final List<DialogDangerAction> dangerActions;

  /// Cover height cap as a fraction of screen height, so neither a very tall
  /// portrait cover nor a full-width video banner can push the dialog past the
  /// screen. The whole artwork stays visible (no hard crop): the cover card is
  /// sized to the artwork's own aspect ratio and only shrinks proportionally.
  ///
  /// TODO-455 had turned the cover into a dimmed background behind a heavy
  /// readability scrim, which made the cover effectively invisible (~7% opacity);
  /// TODO-557 restored the cover as a visible foreground block — the hero cover
  /// card keeps that rule (the blurred backdrop is decoration only).
  static const double _coverHeightFactor = 0.34;

  /// 模糊垫底与宽高比探测的解码宽度（像素）：σ=28 的模糊之后 64px 与原图看不出差别。
  static const int _backdropDecodeWidth = 64;

  /// 对话框可用宽度达到它即按宽框排版（启动 / 快捷动作进头部、列表动作双列）。
  static const double _wideLayoutMinWidth = 520;

  /// 屏幕宽度达到它才把对话框放宽到 [_wideMaxWidth]；更窄的屏维持
  /// [FushiDialogFrame] 默认的 420 上限（手机本来也到不了）。
  static const double _wideScreenMinWidth = 720;
  static const double _wideMaxWidth = 600;
  static const double _narrowMaxWidth = 420;

  static const double _wideCoverWidth = 148;
  static const double _narrowCoverWidth = 104;

  /// 宽高比超过它按横版封面（视频缩略图）走横幅；方形游戏封面仍与标题并排。
  static const double _bannerMinAspect = 1.15;

  /// 宽高比尚未解析（加载中 / 无图源）时封面卡的默认比例：书封最常见的 2:3。
  static const double _defaultPortraitAspect = 2 / 3;

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final bool wideScreen = screen.width >= _wideScreenMinWidth;
    // 一份降采样 provider 同时喂宽高比探测与模糊垫底（ImageCache 只解码一次）。
    final ImageProvider? decoded = coverBackdrop == null
        ? null
        : ResizeImage.resizeIfNeeded(
            _backdropDecodeWidth, null, coverBackdrop!);
    final ImageProvider? backdrop = isEinkTheme(context) ? null : decoded;
    return FushiDialogFrame(
      maxWidth: wideScreen ? _wideMaxWidth : _narrowMaxWidth,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= _wideLayoutMinWidth;
          return _CoverAspectResolver(
            image: decoded,
            builder: (BuildContext context, double? aspect) => _buildBody(
              context,
              wide: wide,
              aspect: aspect,
              backdrop: backdrop,
              screenHeight: screen.height,
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required bool wide,
    required double? aspect,
    required ImageProvider? backdrop,
    required double screenHeight,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool banner =
        cover != null && aspect != null && aspect > _bannerMinAspect;
    // 宽框 + 并排头部：启动按钮与快捷 chip 进头部右栏；横幅头部下方本来就是整宽，
    // 动作留在正文里。没有任何主动作时不进头部，否则右栏只剩一段空白间距。
    final bool actionsInHeader =
        wide && !banner && cover != null && _hasPrimaryActions;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildHeader(
          context,
          tokens,
          wide: wide,
          banner: banner,
          aspect: aspect,
          backdrop: backdrop,
          screenHeight: screenHeight,
          actionsInHeader: actionsInHeader,
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.card,
            0,
            tokens.spacing.card,
            tokens.spacing.card,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (!actionsInHeader) ..._buildPrimaryActions(tokens),
              if (listActions.isNotEmpty) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                const FushiDivider(),
                SizedBox(height: tokens.spacing.gap / 2),
                _buildListActions(tokens, columns: wide ? 2 : 1),
              ],
              if (dangerActions.isNotEmpty) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                const FushiDivider(),
                SizedBox(height: tokens.spacing.gap / 2),
                _buildDangerActions(context),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // -- header -----------------------------------------------------------------

  Widget _buildHeader(
    BuildContext context,
    FushiDesignTokens tokens, {
    required bool wide,
    required bool banner,
    required double? aspect,
    required ImageProvider? backdrop,
    required double screenHeight,
    required bool actionsInHeader,
  }) {
    final double maxCoverHeight = screenHeight * _coverHeightFactor;
    final Widget info = _buildTitleBlock(context, tokens, wide: wide);
    final Widget content;
    if (cover == null) {
      content = info;
    } else if (banner) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(
            child: _buildCoverCard(
              context,
              tokens,
              aspect: aspect!,
              maxWidth: double.infinity,
              maxHeight: maxCoverHeight,
            ),
          ),
          SizedBox(height: tokens.spacing.card - 4),
          info,
        ],
      );
    } else {
      final Widget coverCard = _buildCoverCard(
        context,
        tokens,
        aspect: aspect ?? _defaultPortraitAspect,
        maxWidth: wide ? _wideCoverWidth : _narrowCoverWidth,
        maxHeight: maxCoverHeight,
      );
      content = IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Align(alignment: Alignment.topCenter, child: coverCard),
            SizedBox(width: tokens.spacing.rowHorizontal),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  info,
                  if (actionsInHeader) ...<Widget>[
                    const Spacer(),
                    SizedBox(height: tokens.spacing.card),
                    ..._buildPrimaryActions(tokens, trailingGap: false),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Stack(
      children: <Widget>[
        Positioned.fill(child: _buildHeaderBackground(context, backdrop)),
        Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.card,
            tokens.spacing.card,
            tokens.spacing.card,
            tokens.spacing.card - 4,
          ),
          child: content,
        ),
      ],
    );
  }

  /// 头部背景：同图模糊垫底，按纵向渐变透明度淡出（顶部约半透明、底部完全透明），
  /// 直接透出对话框自己的底色——头部无缝融进正文、交界处没有硬边，也不必知道
  /// 对话框底色是哪个 surface 角色。无图源 / 墨水屏时只是一层同样淡出的浅 overlay。
  Widget _buildHeaderBackground(BuildContext context, ImageProvider? backdrop) {
    if (backdrop == null) {
      final Color overlay = FushiDesignTokens.of(context).surfaces.overlay;
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[overlay, overlay.withValues(alpha: 0)],
          ),
        ),
      );
    }
    return ClipRect(
      child: ExcludeSemantics(
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          // 只取 alpha：模糊色块只做氛围，压到半透明以下，浅色封面也不会让
          // 标题发白看不清。
          shaderCallback: (Rect bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: <double>[0, 0.55, 1],
            colors: <Color>[
              Color(0x8CFFFFFF),
              Color(0x4DFFFFFF),
              Color(0x00FFFFFF),
            ],
          ).createShader(bounds),
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: Image(
              key: const ValueKey<String>('media_item_dialog_cover_backdrop'),
              image: backdrop,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }

  /// 封面卡：按 [aspect] 定尺寸（宽不超过 [maxWidth]、高不超过 [maxHeight]），
  /// 前景封面清晰画在最上层，整幅可见不裁切。
  Widget _buildCoverCard(
    BuildContext context,
    FushiDesignTokens tokens, {
    required double aspect,
    required double maxWidth,
    required double maxHeight,
  }) {
    final bool eink = isEinkTheme(context);
    final Widget card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: tokens.radii.cardRadius,
        boxShadow: eink
            ? null
            : const <BoxShadow>[
                BoxShadow(
                  color: Color(0x47000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: tokens.radii.cardRadius,
        child: ColoredBox(
          color: tokens.surfaces.overlay,
          child: cover!,
        ),
      ),
    );
    if (!maxWidth.isFinite) {
      // 横幅：宽度跟可用宽度走，由 AspectRatio 推高、ConstrainedBox 限高。
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: AspectRatio(aspectRatio: aspect, child: card),
      );
    }
    // 并排头部在 IntrinsicHeight 里：尺寸必须是确定值，不能依赖封面 widget 的
    // 内在尺寸（图片未解码时为 0）。先按宽定高，超高再按高反推宽。
    double width = maxWidth;
    double height = width / aspect;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * aspect;
    }
    return SizedBox(width: width, height: height, child: card);
  }

  Widget _buildTitleBlock(
    BuildContext context,
    FushiDesignTokens tokens, {
    required bool wide,
  }) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          // TODO-2490：本弹窗是库页卡片长按/右键「看全名」的兜底路径——
          // 卡上标题最多两行省略，这里再截断则超长条目名到处都看不全。
          // 外层 FushiDialogFrame 默认可滚动且限高，不会撑出屏。
          style:
              (wide ? tokens.type.pageTitle : tokens.type.listTitle).copyWith(
            color: colors.onSurface,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
        ),
        if (author != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            author!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.listSubtitle.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  // -- actions ----------------------------------------------------------------

  bool get _hasLaunchAction =>
      showLaunchAction && launchLabel != null && onLaunch != null;

  bool get _hasPrimaryActions => _hasLaunchAction || quickActions.isNotEmpty;

  /// 启动按钮 + 快捷 chip。正文里时末尾留 [FushiSpacingTokens.gap] 与列表动作分开；
  /// 在头部右栏时贴底，不再追加间距。
  List<Widget> _buildPrimaryActions(
    FushiDesignTokens tokens, {
    bool trailingGap = true,
  }) {
    final bool hasLaunch = _hasLaunchAction;
    return <Widget>[
      if (hasLaunch) ...<Widget>[
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: onLaunch,
            child: Text(
              launchLabel!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (quickActions.isNotEmpty) SizedBox(height: tokens.spacing.gap),
      ],
      if (quickActions.isNotEmpty) _buildQuickActions(tokens),
      if (trailingGap && (hasLaunch || quickActions.isNotEmpty))
        SizedBox(height: tokens.spacing.gap),
    ];
  }

  Widget _buildQuickActions(FushiDesignTokens tokens) {
    return Builder(
      builder: (BuildContext context) => _QuickActionGrid(
        gap: tokens.spacing.gap,
        textDirection: Directionality.of(context),
        children: <Widget>[
          for (final DialogQuickAction action in quickActions)
            FushiActionChip(
              label: action.label,
              icon: action.icon,
              onPressed: action.onPressed,
            ),
        ],
      ),
    );
  }

  /// 列表动作：窄框单列；宽框按行两列（焦点 / Tab 顺序仍是阅读顺序：左→右、上→下）。
  Widget _buildListActions(FushiDesignTokens tokens, {required int columns}) {
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < listActions.length; i += columns) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int c = 0; c < columns; c++) ...<Widget>[
              if (c > 0) SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: i + c < listActions.length
                    ? _listActionItem(listActions[i + c], tokens)
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  Widget _listActionItem(DialogListAction action, FushiDesignTokens tokens) {
    return FushiListItem(
      minHeight: 44,
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
      leading: Icon(action.icon),
      title: Text(action.label),
      // 不画尾部 chevron（2026-10-04）：这些是「就地执行 / 弹个小框」
      // 的菜单动作，不是推入子页的导航项；每行一个「>」暗示了不存在
      // 的层级，还把视线拉向右缘。MD3 菜单项同样不带箭头。
      onTap: action.onPressed,
    );
  }

  Widget _buildDangerActions(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: FushiDesignTokens.of(context).spacing.gap,
      children: <Widget>[
        for (final DialogDangerAction action in dangerActions)
          TextButton(
            onPressed: action.onPressed,
            style: TextButton.styleFrom(
              foregroundColor:
                  action.muted ? colors.onSurfaceVariant : colors.error,
            ),
            child: Text(
              action.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

/// 解析 [image] 的宽高比交给 [builder]；未解析完 / 解析失败 / 无图源时给 null。
///
/// 封面卡要在第一帧就按真实比例定尺寸才不会留 letterbox，而 [cover] 是调用方
/// 给的不透明 widget、量不到图片本身。这里直接监听图源（与模糊垫底同一个降采样
/// provider，ImageCache 命中后同步回调，不额外解码）。
class _CoverAspectResolver extends StatefulWidget {
  const _CoverAspectResolver({required this.image, required this.builder});

  final ImageProvider? image;
  final Widget Function(BuildContext context, double? aspect) builder;

  @override
  State<_CoverAspectResolver> createState() => _CoverAspectResolverState();
}

class _CoverAspectResolverState extends State<_CoverAspectResolver> {
  ImageStream? _stream;
  late final ImageStreamListener _listener = ImageStreamListener(
    _onImage,
    onError: (Object _, StackTrace? __) {},
  );
  double? _aspect;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_CoverAspectResolver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) {
      _aspect = null;
      _resolve();
    }
  }

  void _resolve() {
    final ImageProvider? image = widget.image;
    if (image == null) {
      _stream?.removeListener(_listener);
      _stream = null;
      return;
    }
    final ImageStream stream =
        image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    final int width = info.image.width;
    final int height = info.image.height;
    info.dispose();
    if (width <= 0 || height <= 0) return;
    final double aspect = width / height;
    if (aspect == _aspect) return;
    if (synchronousCall) {
      _aspect = aspect;
    } else if (mounted) {
      setState(() => _aspect = aspect);
    }
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _aspect);
}

/// 等宽快捷 chip 网格：按 chip 的**真实内在宽度**决定每行放几列。
///
/// BUG-2603：旧实现用常量 96 猜「一个 chip 最少要多宽」再平分。中文「从互联对端
/// 下载有声书」、日语「オーディオブックをインポート」这类标签远超 96，手机宽度下
/// 三等分后每个 chip 只剩三四个字，被 ellipsis 截成「查…/导…/从…」。这里改成在
/// layout 阶段量每个 chip 的 maxIntrinsicWidth（含图标、内边距与字号缩放），取最宽者
/// 为列宽下限，从「全部一行」往下试到一列，第一个「等分列宽 ≥ 最宽 chip」的列数
/// 胜出；所有 chip 等宽，放不进本行的换行沿用同一列宽。不再依赖任何拍脑袋常量。
class _QuickActionGrid extends MultiChildRenderObjectWidget {
  const _QuickActionGrid({
    required this.gap,
    required this.textDirection,
    required super.children,
  });

  final double gap;
  final TextDirection textDirection;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderQuickActionGrid(gap: gap, textDirection: textDirection);
  }

  @override
  void updateRenderObject(
      BuildContext context, _RenderQuickActionGrid renderObject) {
    renderObject
      ..gap = gap
      ..textDirection = textDirection;
  }
}

class _QuickActionGridParentData extends ContainerBoxParentData<RenderBox> {}

/// 一次布局决议：[columns] 列、每列 [width] 宽。
typedef _QuickActionColumns = ({int columns, double width});

class _RenderQuickActionGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _QuickActionGridParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _QuickActionGridParentData> {
  _RenderQuickActionGrid({
    required double gap,
    required TextDirection textDirection,
  })  : _gap = gap,
        _textDirection = textDirection;

  double _gap;
  double get gap => _gap;
  set gap(double value) {
    if (_gap == value) return;
    _gap = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  TextDirection get textDirection => _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _QuickActionGridParentData) {
      child.parentData = _QuickActionGridParentData();
    }
  }

  /// 从「全部一行」往下试到一列，第一个「等分列宽容得下最宽 chip」的列数胜出；
  /// 一列都容不下时仍取一列铺满——chip 内部的 ellipsis 只是最后防线，不是布局目标。
  _QuickActionColumns _resolveColumns(double maxWidth) {
    int count = 0;
    double widest = 0;
    RenderBox? child = firstChild;
    while (child != null) {
      count++;
      widest = math.max(widest, child.getMaxIntrinsicWidth(double.infinity));
      child = childAfter(child);
    }
    if (count == 0) return (columns: 0, width: 0);
    if (!maxWidth.isFinite) return (columns: count, width: widest);
    for (int columns = count; columns > 1; columns--) {
      final double width = (maxWidth - gap * (columns - 1)) / columns;
      if (width >= widest) return (columns: columns, width: width);
    }
    return (columns: 1, width: maxWidth);
  }

  /// 逐 chip 走一遍网格：[childHeight] 给出 chip 在 [grid].width 下的高度，
  /// [place] 非空时顺带把 chip 的偏移写进 parentData。返回整块的尺寸。
  Size _walkGrid(
    _QuickActionColumns grid,
    double Function(RenderBox child, BoxConstraints constraints) childHeight, {
    bool place = false,
  }) {
    if (grid.columns == 0) return Size.zero;
    final BoxConstraints chipConstraints =
        BoxConstraints.tightFor(width: grid.width);
    final double totalWidth =
        grid.columns * grid.width + gap * (grid.columns - 1);
    double y = 0;
    double rowHeight = 0;
    int column = 0;
    RenderBox? child = firstChild;
    while (child != null) {
      if (column == grid.columns) {
        column = 0;
        y += rowHeight + gap;
        rowHeight = 0;
      }
      final double height = childHeight(child, chipConstraints);
      if (place) {
        final double start = column * (grid.width + gap);
        final double x = switch (textDirection) {
          TextDirection.ltr => start,
          TextDirection.rtl => totalWidth - start - grid.width,
        };
        final _QuickActionGridParentData parentData =
            child.parentData! as _QuickActionGridParentData;
        parentData.offset = Offset(x, y);
      }
      rowHeight = math.max(rowHeight, height);
      column++;
      child = childAfter(child);
    }
    return Size(totalWidth, y + rowHeight);
  }

  @override
  void performLayout() {
    final _QuickActionColumns grid = _resolveColumns(constraints.maxWidth);
    final Size content = _walkGrid(
      grid,
      (RenderBox child, BoxConstraints chipConstraints) {
        child.layout(chipConstraints, parentUsesSize: true);
        return child.size.height;
      },
      place: true,
    );
    size = constraints.constrain(content);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final _QuickActionColumns grid = _resolveColumns(constraints.maxWidth);
    final Size content = _walkGrid(
      grid,
      (RenderBox child, BoxConstraints chipConstraints) =>
          child.getDryLayout(chipConstraints).height,
    );
    return constraints.constrain(content);
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    double widest = 0;
    RenderBox? child = firstChild;
    while (child != null) {
      widest = math.max(widest, child.getMinIntrinsicWidth(height));
      child = childAfter(child);
    }
    return widest;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    return _walkGrid(
      _resolveColumns(double.infinity),
      (RenderBox child, BoxConstraints chipConstraints) => 0,
    ).width;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    return _walkGrid(
      _resolveColumns(width),
      (RenderBox child, BoxConstraints chipConstraints) =>
          child.getMinIntrinsicHeight(chipConstraints.maxWidth),
    ).height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    return _walkGrid(
      _resolveColumns(width),
      (RenderBox child, BoxConstraints chipConstraints) =>
          child.getMaxIntrinsicHeight(chipConstraints.maxWidth),
    ).height;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }
}
