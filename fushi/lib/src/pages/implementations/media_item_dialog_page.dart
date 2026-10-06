import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show
        GlassButton,
        GlassButtonStyle,
        GlassContainer,
        LiquidGlassSettings,
        LiquidOval,
        LiquidRoundedSuperellipse;
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
//   * [DialogQuickAction]  -> equal-width quick action (MD3 tonal button /
//                             Apple glass round button + caption).
//   * [DialogListAction]   -> a labelled row (MD3 segmented card / Apple menu).
//   * [DialogDangerAction] -> a destructive action at the bottom.

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
    super.icon = FushiIcons.settings,
  });
}

final class DialogDangerAction extends DialogAction {
  const DialogDangerAction({
    required super.label,
    required super.onPressed,
    super.icon = FushiIcons.delete,
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
            icon: FushiIcons.edit,
            onPressed: _executeEdit,
          ),
      ];

  List<DialogDangerAction> get _dangerActions => [
        ..._externalActions.whereType<DialogDangerAction>(),
        if (widget.item.canDelete && widget.isHistory)
          DialogDangerAction(
            label: t.dialog_clear,
            icon: FushiIcons.deleteSweep,
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
        child: FushiIcon(
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
/// * **宽框（桌面 / 平板）**：对话框放宽到 [_wideMaxWidth]，启动按钮与快捷动作
///   挪进封面右侧（填掉标题下方的空白），列表动作排成两列，整体高度大幅缩短。
/// * **窄框（手机）**：单列、封面卡缩到 [_narrowCoverWidth]，快捷动作在头部下方。
///
/// 两套设计系统在同一棵树上只换参数与叶子控件（不按设计系统增删父包装层）：
///
/// * **MD3（Material 3 Expressive）**：头部模糊垫底 + 圆角 16 投影封面卡，标题
///   headlineSmall（窄框 titleLarge）、元信息 bodyMedium onSurfaceVariant；启动
///   按钮是 56 高的大号 filled 按钮（按压变形）；快捷动作是等宽 tonal 图标文字
///   按钮（40 高、按压变形）；列表动作是分段分组卡（surfaceContainerLow，组内
///   2px 缝、首尾 24 / 中间 4 圆角）；危险动作是居中文字按钮。面板
///   surfaceContainerHigh 圆角 28（[FushiDialogFrame]）。
/// * **Apple（iOS 26 上下文菜单预览 / macOS 26 Quick Look）**：面板是真·液态
///   厚玻璃（透出背后页面，系统降低透明度时整块实色），封面预览卡
///   圆角 18、柔和大阴影浮在上面；启动按钮是强调色玻璃胶囊（`.glassProminent`）；
///   快捷动作是一排 44 玻璃圆钮 + 下方 11 号小字（分享表单 / 控制中心式）；
///   列表与危险动作合进一块玻璃菜单面板（行高 44 / 桌面 30、单色 SF 图标、组间
///   细分隔、破坏性动作 destructive 红字），桌面宽框两列。
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

  /// 封面卡圆角：MD3 16（Expressive 卡片档）；Apple 18（iOS 26 上下文菜单预览 /
  /// Quick Look 的大圆角）。
  static const double _md3CoverRadius = 16;
  static const double _appleCoverRadius = 18;

  /// 启动按钮高度：MD3 Expressive 的 M 号按钮 56；Apple 大号胶囊（移动 50 /
  /// 桌面 36，macOS 26 large control）。外面套同高的 SizedBox，并排头部的
  /// IntrinsicHeight 量得到确定高度（玻璃按钮的渲染对象不报内在尺寸）。
  static const double _md3LaunchHeight = 56;
  static const double _appleLaunchHeight = 50;
  static const double _appleCompactLaunchHeight = 36;

  static const ValueKey<String> _backdropKey =
      ValueKey<String>('media_item_dialog_cover_backdrop');

  /// 把调用方图源降采样到 [_backdropDecodeWidth] 宽。
  ///
  /// 调用方给的图源本身常已是 [ResizeImage]（`resizedFileImage` 的 720 宽封面、
  /// 远端封面的解码上限）。[ResizeImage] **不能嵌套**：内层的 decode 回调断言
  /// `getTargetSize == null`（debug 下直接抛，release 下内层尺寸覆盖外层）——
  /// 2026-10-04 用户截图里头部没有模糊垫底、视频横版封面仍按 2:3 竖卡排，都是
  /// 这一次解码失败：模糊层走 errorBuilder 变空，宽高比探测拿不到尺寸回落默认
  /// 竖版。这里先剥掉外面所有 [ResizeImage] 再套自己的一层。
  static ImageProvider? _downsampled(ImageProvider? source) {
    ImageProvider? base = source;
    while (base is ResizeImage) {
      base = base.imageProvider;
    }
    if (base == null) return null;
    return ResizeImage(base, width: _backdropDecodeWidth);
  }

  /// MD3：快捷动作不多于它时画成标题下方的 tonal 按钮（书：查看插画 / 导入有声书；
  /// 远端条目：播放 / 下载 / 信息）；更多时（本地视频的重命名 / 封面 / 字幕 /
  /// 合集 / 标签……八项）并进下方统一的分段列表——一格格挤在标题旁的 chip 网格
  /// 把低频管理动作抬成了主操作，层级是反的（2026-10-04 用户截图）。
  static const int _md3MaxQuickButtons = 3;

  /// Apple：一排玻璃圆钮（分享表单式）超过它也并进下方玻璃菜单面板——八个
  /// 40 圆钮 + 11 号小字挤成一排既难点又难读。
  static const int _appleMaxQuickButtons = 4;

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final bool wideScreen = screen.width >= _wideScreenMinWidth;
    final bool apple = isGlassDesign(context);
    // 一份降采样 provider 同时喂宽高比探测与模糊垫底（ImageCache 只解码一次）。
    final ImageProvider? decoded = _downsampled(coverBackdrop);
    // 墨水屏不模糊；Apple 下系统「降低透明度」时面板整块实色，同样不铺模糊色。
    final bool solid = isEinkTheme(context) ||
        (apple && glassMaterialOf(context) == FushiGlassMaterial.off);
    final ImageProvider? backdrop = solid ? null : decoded;
    return FushiDialogFrame(
      maxWidth: wideScreen ? _wideMaxWidth : _narrowMaxWidth,
      // Apple：面板是真·液态玻璃（iOS 26 上下文菜单预览 / Quick Look 的厚
      // 玻璃），透出背后的页面；系统降低透明度时共享面板自己回落实色。
      appleLiquidGlass: true,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= _wideLayoutMinWidth;
          return _CoverAspectResolver(
            image: decoded,
            builder: (BuildContext context, double? aspect) => _buildBody(
              context,
              wide: wide,
              apple: apple,
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
    required bool apple,
    required double? aspect,
    required ImageProvider? backdrop,
    required double screenHeight,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool banner =
        cover != null && aspect != null && aspect > _bannerMinAspect;
    final bool quickAsRows = quickActions.length >
        (apple ? _appleMaxQuickButtons : _md3MaxQuickButtons);
    final List<DialogQuickAction> buttonActions =
        quickAsRows ? const <DialogQuickAction>[] : quickActions;
    final List<DialogAction> rowActions = <DialogAction>[
      if (quickAsRows) ...quickActions,
      ...listActions,
    ];
    // 宽框 + 并排头部：启动按钮与快捷动作进头部右栏、紧接标题；横幅头部下方本来
    // 就是整宽，动作留在正文里。没有任何主动作时不进头部，否则右栏只剩标题下
    // 一段空白间距（标题比封面高时会原样撑大头部）。
    final bool hasLaunch =
        showLaunchAction && launchLabel != null && onLaunch != null;
    final bool actionsInHeader = wide &&
        !banner &&
        cover != null &&
        (hasLaunch || buttonActions.isNotEmpty);
    final int columns = wide ? 2 : 1;
    // 两套设计系统同一棵树：面板垫底层 + 头部 + 正文。MD3 的模糊垫底只铺头部；
    // Apple 面板本身是液态玻璃，两层都留空。
    return Stack(
      children: <Widget>[
        // 面板垫底层恒在（结构恒定）。Apple 面板本身已是液态玻璃
        // （[FushiDialogFrame.appleLiquidGlass]），不再在近实色面板里铺一层
        // 封面模糊色冒充厚玻璃；MD3 的模糊垫底只铺头部，这一层同样留空。
        const Positioned.fill(child: SizedBox.shrink()),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(
              context,
              tokens,
              wide: wide,
              apple: apple,
              banner: banner,
              aspect: aspect,
              backdrop: apple ? null : backdrop,
              screenHeight: screenHeight,
              actionsInHeader: actionsInHeader,
              buttonActions: buttonActions,
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
                  if (!actionsInHeader)
                    ..._buildPrimaryActions(
                      context,
                      tokens,
                      apple: apple,
                      quick: buttonActions,
                    ),
                  if (apple)
                    ..._buildAppleMenu(
                      context,
                      tokens,
                      columns: columns,
                      rows: rowActions,
                    )
                  else ...<Widget>[
                    if (rowActions.isNotEmpty) ...<Widget>[
                      SizedBox(height: tokens.spacing.gap),
                      _buildMd3SegmentGrid(
                        context,
                        actions: rowActions,
                        columns: columns,
                      ),
                    ],
                    if (dangerActions.isNotEmpty) ...<Widget>[
                      SizedBox(height: tokens.spacing.card - 4),
                      _buildMd3SegmentGrid(
                        context,
                        actions: dangerActions,
                        columns: columns,
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // -- header -----------------------------------------------------------------

  Widget _buildHeader(
    BuildContext context,
    FushiDesignTokens tokens, {
    required bool wide,
    required bool apple,
    required bool banner,
    required double? aspect,
    required ImageProvider? backdrop,
    required double screenHeight,
    required bool actionsInHeader,
    required List<DialogQuickAction> buttonActions,
  }) {
    final double maxCoverHeight = screenHeight * _coverHeightFactor;
    final Widget info =
        _buildTitleBlock(context, tokens, wide: wide, apple: apple);
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
              apple: apple,
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
        apple: apple,
        aspect: aspect ?? _defaultPortraitAspect,
        maxWidth: wide ? _wideCoverWidth : _narrowCoverWidth,
        maxHeight: maxCoverHeight,
      );
      // 右栏顶对齐、动作紧接标题区：旧版用 Spacer 把按钮推到封面底边，标题与
      // 按钮之间留出一大片空洞（2026-10-04 用户截图）。
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          coverCard,
          SizedBox(width: tokens.spacing.rowHorizontal),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                info,
                if (actionsInHeader) ...<Widget>[
                  SizedBox(height: tokens.spacing.card),
                  ..._buildPrimaryActions(
                    context,
                    tokens,
                    apple: apple,
                    quick: buttonActions,
                    trailingGap: false,
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: _buildHeaderBackground(context, backdrop, apple: apple),
        ),
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
  /// Apple 下面板本身是液态玻璃（见 [_buildBody]），头部这一层留空。
  Widget _buildHeaderBackground(
    BuildContext context,
    ImageProvider? backdrop, {
    required bool apple,
  }) {
    if (apple) return const SizedBox.shrink();
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
    // 只取 alpha：模糊色块只做氛围，压到半透明以下，浅色封面也不会让标题发白
    // 看不清。
    return _buildBlurredBackdrop(
      backdrop,
      sigma: 24,
      alphas: const <Color>[
        Color(0xB3FFFFFF),
        Color(0x66FFFFFF),
        Color(0x00FFFFFF),
      ],
    );
  }

  /// 同图模糊垫底：降采样图源 cover 铺满、高斯模糊，再用纵向渐变的 alpha
  /// （[alphas] 三档，停在 0 / 0.55 / 1）把它淡进面板底色。无图源时为空层。
  Widget _buildBlurredBackdrop(
    ImageProvider? backdrop, {
    required double sigma,
    required List<Color> alphas,
  }) {
    if (backdrop == null) return const SizedBox.shrink();
    return ClipRect(
      child: ExcludeSemantics(
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (Rect bounds) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const <double>[0, 0.55, 1],
            colors: alphas,
          ).createShader(bounds),
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: Image(
              key: _backdropKey,
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
  /// 前景封面清晰画在最上层，整幅可见不裁切。两套设计系统同一结构，只换圆角、
  /// 阴影与占位底色：MD3 圆角 16 + 中等投影；Apple 圆角 18 + 两层柔和大阴影
  /// （预览卡「浮」在模糊背景上）。
  Widget _buildCoverCard(
    BuildContext context,
    FushiDesignTokens tokens, {
    required bool apple,
    required double aspect,
    required double maxWidth,
    required double maxHeight,
  }) {
    final bool eink = isEinkTheme(context);
    final bool dark =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    final BorderRadius radius = BorderRadius.all(
      Radius.circular(apple ? _appleCoverRadius : _md3CoverRadius),
    );
    final List<BoxShadow>? shadows = eink
        ? null
        : apple
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.5 : 0.22),
                  blurRadius: 32,
                  spreadRadius: -4,
                  offset: const Offset(0, 14),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.3 : 0.1),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ]
            : const <BoxShadow>[
                BoxShadow(
                  color: Color(0x47000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ];
    final Widget card = DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: shadows),
      child: ClipRRect(
        borderRadius: radius,
        child: ColoredBox(
          color: apple
              ? appleColorsOf(context).secondaryFill
              : tokens.surfaces.overlay,
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
    required bool apple,
  }) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final TextStyle titleStyle;
    final TextStyle authorStyle;
    if (apple) {
      // Apple：iOS title3 / macOS Quick Look 标题——粗体 label 色、无字距；
      // 元信息是 subheadline 的 secondaryLabel 灰字。
      final FushiAppleColors palette = appleColorsOf(context);
      titleStyle = (textTheme.titleLarge ?? tokens.type.pageTitle).copyWith(
        color: palette.label,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
        height: 1.25,
      );
      authorStyle = FushiAppleMetrics.of(context).subtitleStyle(context);
    } else {
      // MD3 Expressive：标题 headlineSmall（窄框并排时 titleLarge，免得一行只剩
      // 几个字），元信息 bodyMedium onSurfaceVariant。
      titleStyle = ((wide ? textTheme.headlineSmall : textTheme.titleLarge) ??
              tokens.type.pageTitle)
          .copyWith(
        color: colors.onSurface,
        fontWeight: FontWeight.w500,
        height: 1.25,
      );
      authorStyle = (textTheme.bodyMedium ?? tokens.type.listSubtitle)
          .copyWith(color: colors.onSurfaceVariant);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          // TODO-2490：本弹窗是库页卡片长按/右键「看全名」的兜底路径——
          // 卡上标题最多两行省略，这里再截断则超长条目名到处都看不全。
          // 外层 FushiDialogFrame 默认可滚动且限高，不会撑出屏。
          style: titleStyle,
        ),
        if (author != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            author!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: authorStyle,
          ),
        ],
      ],
    );
  }

  // -- actions ----------------------------------------------------------------

  /// 启动按钮 + 快捷动作。正文里时末尾留 [FushiSpacingTokens.gap] 与列表动作分开；
  /// 在头部右栏时贴底，不再追加间距。
  ///
  /// 启动按钮两套同一个 [FushiFilledButton]、只换 style：MD3 是 56 高的大号
  /// filled 按钮（titleMedium 字、按压变形，见 [FushiPressMorph]）；Apple 是强调色
  /// 玻璃胶囊（`.glassProminent`，移动 50 / 桌面 36）。
  List<Widget> _buildPrimaryActions(
    BuildContext context,
    FushiDesignTokens tokens, {
    required bool apple,
    required List<DialogQuickAction> quick,
    bool trailingGap = true,
  }) {
    final List<DialogQuickAction> quickActions = quick;
    final bool hasLaunch =
        showLaunchAction && launchLabel != null && onLaunch != null;
    final double launchHeight = !apple
        ? _md3LaunchHeight
        : (fushiAppleCompact(context)
            ? _appleCompactLaunchHeight
            : _appleLaunchHeight);
    return <Widget>[
      if (hasLaunch) ...<Widget>[
        SizedBox(
          width: double.infinity,
          height: launchHeight,
          child: FushiFilledButton(
            onPressed: onLaunch,
            style: FilledButton.styleFrom(
              minimumSize: Size(0, launchHeight),
              textStyle: apple ? null : Theme.of(context).textTheme.titleMedium,
            ),
            child: Text(
              launchLabel!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (quickActions.isNotEmpty)
          SizedBox(
            height: apple ? tokens.spacing.card - 4 : tokens.spacing.gap + 4,
          ),
      ],
      if (quickActions.isNotEmpty)
        _QuickActionGrid(
          gap: apple ? tokens.spacing.gap / 2 : tokens.spacing.gap,
          textDirection: Directionality.of(context),
          children: <Widget>[
            for (final DialogQuickAction action in quickActions)
              _QuickActionButton(action: action),
          ],
        ),
      if (trailingGap && (hasLaunch || quickActions.isNotEmpty))
        SizedBox(height: tokens.spacing.gap),
    ];
  }

  /// 按「行优先」把 [count] 个单元排进 [columns] 列：焦点 / Tab 顺序仍是阅读
  /// 顺序（左→右、上→下）。[cell] 收到单元下标、它在本列里的行号与本列的单元
  /// 总数（分段卡按列算首尾圆角）；末行不满时空位留白。
  Widget _actionGrid({
    required int count,
    required int columns,
    required double columnGap,
    required double rowGap,
    required Widget Function(int index, int row, int rowsInColumn) cell,
  }) {
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < count; i += columns) {
      if (rows.isNotEmpty && rowGap > 0) rows.add(SizedBox(height: rowGap));
      final int row = i ~/ columns;
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int c = 0; c < columns; c++) ...<Widget>[
              if (c > 0) SizedBox(width: columnGap),
              Expanded(
                child: i + c < count
                    ? cell(i + c, row, (count - 1 - c) ~/ columns + 1)
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

  /// MD3 动作列表：**一张**分段分组网格（Android 16 设置的 segmented list，
  /// 外侧圆角 [kSettingsSegmentOuterRadius]、内侧 [kSettingsSegmentInnerRadius]、
  /// 行列缝都是 [kSettingsSegmentGap]）。宽框两列按行优先排，每行两格等高；行数
  /// 为奇数时末格横跨两列——旧版两列各成一组，左列比右列多一行，底边不齐、右下
  /// 空一格（2026-10-04 用户截图）。窄框单列。焦点 / Tab 顺序仍是阅读顺序。
  ///
  /// 危险动作同一形态另起一组：图标与文字 error 色（muted 的「清除历史」走普通
  /// 色），比旧版居中的一行小红字醒目，又不像 filled 红按钮那样喧宾夺主。
  Widget _buildMd3SegmentGrid(
    BuildContext context, {
    required List<DialogAction> actions,
    required int columns,
  }) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextDirection direction = Directionality.of(context);
    const Radius outer = Radius.circular(kSettingsSegmentOuterRadius);
    const Radius inner = Radius.circular(kSettingsSegmentInnerRadius);
    final int rowCount = (actions.length + columns - 1) ~/ columns;
    final List<Widget> rows = <Widget>[];
    for (int r = 0; r < rowCount; r++) {
      final int first = r * columns;
      final int inRow = math.min(columns, actions.length - first);
      final bool top = r == 0;
      final bool bottom = r == rowCount - 1;
      if (r > 0) rows.add(const SizedBox(height: kSettingsSegmentGap));
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int c = 0; c < inRow; c++) ...<Widget>[
                if (c > 0) const SizedBox(width: kSettingsSegmentGap),
                Expanded(
                  child: _Md3SegmentRow(
                    icon: actions[first + c].icon,
                    label: actions[first + c].label,
                    onPressed: actions[first + c].onPressed,
                    foreground: switch (actions[first + c]) {
                      DialogDangerAction(muted: false) => colors.error,
                      _ => null,
                    },
                    borderRadius: BorderRadiusDirectional.only(
                      topStart: top && c == 0 ? outer : inner,
                      topEnd: top && c == inRow - 1 ? outer : inner,
                      bottomStart: bottom && c == 0 ? outer : inner,
                      bottomEnd: bottom && c == inRow - 1 ? outer : inner,
                    ).resolve(direction),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  /// Apple 列表 + 危险动作：一块玻璃菜单面板（iOS 26 上下文菜单 / macOS 26
  /// 菜单）。两组之间一条细分隔；破坏性动作 destructive 红字，muted 的（例如
  /// 清除历史）是普通 label 色。宽框两列。系统降低透明度时玻璃回落实色。
  List<Widget> _buildAppleMenu(
    BuildContext context,
    FushiDesignTokens tokens, {
    required int columns,
    required List<DialogAction> rows,
  }) {
    if (rows.isEmpty && dangerActions.isEmpty) return const <Widget>[];
    final bool compact = fushiAppleCompact(context);
    final FushiAppleColors palette = appleColorsOf(context);
    final double inset = compact ? 5 : 6;
    final double radius = compact ? 12 : 20;
    final LiquidGlassSettings base = fushiGlassSettings(context);
    // 液态档：菜单玻璃取 secondarySystemFill 的淡灰，叠在面板上仍能看出一块；
    // 磨砂 / 关闭档沿用作用域的实底玻璃（关闭档即 #1C1C1E / 近白实色）。
    final LiquidGlassSettings settings =
        glassMaterialOf(context) == FushiGlassMaterial.liquid
            ? base.copyWith(glassColor: palette.secondaryFill, blur: 10)
            : base;
    return <Widget>[
      SizedBox(height: tokens.spacing.gap),
      GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context, prominent: true),
        settings: settings,
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: EdgeInsets.all(inset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (rows.isNotEmpty)
                  _actionGrid(
                    count: rows.length,
                    columns: columns,
                    columnGap: inset,
                    rowGap: 0,
                    cell: (int index, int row, int rowsInColumn) {
                      final DialogAction action = rows[index];
                      return _AppleMenuRow(
                        icon: action.icon,
                        label: action.label,
                        onPressed: action.onPressed,
                      );
                    },
                  ),
                if (rows.isNotEmpty && dangerActions.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: inset,
                      horizontal: compact ? 6 : 10,
                    ),
                    child: SizedBox(
                      height: fushiHairline(context),
                      child: ColoredBox(color: palette.separator),
                    ),
                  ),
                if (dangerActions.isNotEmpty)
                  _actionGrid(
                    count: dangerActions.length,
                    columns: columns,
                    columnGap: inset,
                    rowGap: 0,
                    cell: (int index, int row, int rowsInColumn) {
                      final DialogDangerAction action = dangerActions[index];
                      return _AppleMenuRow(
                        icon: action.icon,
                        label: action.label,
                        onPressed: action.onPressed,
                        destructive: !action.muted,
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    ];
  }
}

/// 一个快捷动作。MD3 = Expressive tonal 图标文字按钮（40 高胶囊、按压变形），
/// 单行标签——列宽由 [_QuickActionGrid] 按真实内在宽度保证放得下（BUG-2603）。
/// Apple = 44（桌面 40）玻璃圆钮 + 下方 11 号小字（iOS 分享表单 / 控制中心式），
/// 标签最多两行；单元内在宽度封顶 [_appleMaxWidth]，一行能排下更多圆钮。
/// 点小字同样触发（整块都是点击目标）；键盘 / 手柄焦点落在圆钮上，Enter 激活。
class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({required this.action});

  final DialogQuickAction action;

  static const double _appleMaxWidth = 84;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return FushiFilledButton.tonalIcon(
        onPressed: action.onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: FushiIcon(action.icon, size: 18),
        label: Text(
          action.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    final FushiAppleColors palette = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    final double extent = compact ? 40 : 44;
    final TextStyle captionStyle =
        (Theme.of(context).textTheme.labelSmall ?? const TextStyle()).copyWith(
      color: palette.label,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      height: 1.2,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _appleMaxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: extent,
            height: extent,
            child: GlassButton.custom(
              onTap: action.onPressed,
              style: GlassButtonStyle.filled,
              settings: fushiGlassSettings(context),
              quality: fushiGlassQuality(context),
              useOwnLayer: true,
              shape: const LiquidOval(),
              width: extent,
              height: extent,
              label: action.label,
              child: FushiIcon(
                action.icon,
                size: compact ? 18 : 20,
                color: palette.label,
              ),
            ),
          ),
          const SizedBox(height: 6),
          ExcludeSemantics(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: action.onPressed,
              child: Text(
                action.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: captionStyle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// MD3 分段分组卡里的一行：整张卡就是点击目标（水波铺满分段），surfaceContainerLow
/// 底（[FushiSurfaceColors.group]），行首 24 单色图标 onSurfaceVariant、标题
/// listTitle onSurface。不画尾部 chevron（2026-10-04）：这些是「就地执行 / 弹个
/// 小框」的菜单动作，不是推入子页的导航项。墨水屏下卡底塌成背景色，补实描边。
/// InkWell 自带焦点节点，Tab 可达、Enter / 手柄 A 激活。
class _Md3SegmentRow extends StatelessWidget {
  const _Md3SegmentRow({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.borderRadius,
    this.foreground,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final BorderRadius borderRadius;

  /// 图标与文字的颜色覆盖（危险动作 = error）；null 时图标 onSurfaceVariant、
  /// 文字 onSurface。
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Color iconColor = foreground ?? tokens.surfaces.onVariant;
    return Material(
      color: tokens.surfaces.group,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius,
        side:
            eink ? BorderSide(color: tokens.surfaces.outline) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        overlayColor: eink ? null : fushiMd3ContentStateLayer(scheme),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: tokens.density.listMinHeight,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.rowHorizontal,
              vertical: tokens.spacing.gap,
            ),
            child: Row(
              children: <Widget>[
                FushiIcon(icon, size: 24, color: iconColor),
                SizedBox(width: tokens.spacing.rowHorizontal),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.listTitle.copyWith(
                      color: foreground ?? tokens.surfaces.onSurface,
                    ),
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

/// Apple 菜单行（iOS 26 上下文菜单 / macOS 26 菜单口径）：
/// - 移动：行高 44、17 号 label 字、文字在左单色图标在右（iOS 上下文菜单），
///   按下铺 systemFill、键盘焦点 / 悬停铺 tertiarySystemFill，高亮块圆角 12；
/// - 桌面：行高 30、13 号字、图标在左（macOS 菜单），悬停 / 键盘焦点 = 强调色
///   圆角块（圆角 5）+ onAccent 文字与图标；
/// - [destructive] 时文字与图标都是 destructive 红（高亮态下照样换 onAccent）。
/// 自带焦点节点：Tab 可达，Enter / 手柄 A（[ActivateIntent]）触发。
class _AppleMenuRow extends StatefulWidget {
  const _AppleMenuRow({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  State<_AppleMenuRow> createState() => _AppleMenuRowState();
}

class _AppleMenuRowState extends State<_AppleMenuRow> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors palette = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final bool compact = fushiAppleCompact(context);
    final bool accentHighlight = compact && (_hovered || _focused || _pressed);
    final Color background;
    if (accentHighlight) {
      background = palette.accent;
    } else if (_pressed) {
      background = palette.fill;
    } else if (_hovered || _focused) {
      background = palette.tertiaryFill;
    } else {
      background = Colors.transparent;
    }
    final Color foreground = accentHighlight
        ? palette.onAccent
        : (widget.destructive ? palette.destructive : palette.label);
    final TextStyle labelStyle =
        (compact ? metrics.footnoteStyle(context) : metrics.titleStyle(context))
            .copyWith(color: foreground);
    final Widget glyph =
        FushiIcon(widget.icon, size: compact ? 15 : 20, color: foreground);
    final Widget text = Text(
      widget.label,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: labelStyle,
    );
    final Widget row = Row(
      children: compact
          ? <Widget>[glyph, const SizedBox(width: 8), Expanded(child: text)]
          : <Widget>[Expanded(child: text), const SizedBox(width: 12), glyph],
    );
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            widget.onPressed();
            return null;
          },
        ),
      },
      onShowHoverHighlight: (bool value) => setState(() => _hovered = value),
      onShowFocusHighlight: (bool value) => setState(() => _focused = value),
      child: Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          onTap: widget.onPressed,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.all(
                Radius.circular(compact ? 5 : 12),
              ),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: compact ? 30 : 44),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 9 : metrics.rowHorizontal,
                  vertical: compact ? 4 : 8,
                ),
                child: row,
              ),
            ),
          ),
        ),
      ),
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
