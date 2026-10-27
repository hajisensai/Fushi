import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

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
//
// 2026-10-25 重设计（用户拍板「手机 B + 桌面 D + E」）：动作再按 [group] 分组，
// 三种呈现共用同一份分组——手机图标宫格按组排序、桌面双栏对话框按组分节、
// 桌面右键菜单按组分段（[DialogActionGroup.settings] 收进悬停子菜单）。

/// 动作所属分组。决定三种呈现里的排序与分节，不改变动作本身。
enum DialogActionGroup {
  /// 整理：重命名、合集、标签、封面、编辑信息、隐私、打开所在位置……（默认）。
  organize,

  /// 内容：有声书 / 字幕 / 插画 / OCR / 远端下载等围绕条目内容的操作。
  content,

  /// 进度：标记读完、重置进度、清除观看记录、统计、悬浮字幕。
  progress,

  /// 条目级设置：内容语言、指定配置、书籍 CSS。桌面右键菜单里收进子菜单。
  settings,
}

sealed class DialogAction {
  const DialogAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.group = DialogActionGroup.organize,
    this.selected = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  /// 分组（见 [DialogActionGroup]）。
  final DialogActionGroup group;

  /// 开关类动作当前处于「开」（已读完、悬浮字幕开着……）：宫格格子与菜单行
  /// 用强调色标出，让用户点之前就知道现在的状态。
  final bool selected;
}

final class DialogQuickAction extends DialogAction {
  const DialogQuickAction({
    required super.label,
    required super.icon,
    required super.onPressed,
    super.group = DialogActionGroup.content,
    super.selected,
  });
}

final class DialogListAction extends DialogAction {
  const DialogListAction({
    required super.label,
    required super.onPressed,
    super.icon = FushiIcons.settings,
    super.group,
    super.selected,
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

  /// 封面材质按条目域推断：阅读器条目（书 / 漫画 / 有声书）= 光面书皮；其它
  /// 媒体类型（词典历史等）没有库页材质，保留旧封面卡。
  ShelfCoverMaterial? get _coverMaterial =>
      widget.item.mediaTypeIdentifier == ReaderMediaType.instance.uniqueKey
      ? ShelfCoverMaterial.glossyBook
      : null;

  @override
  Widget build(BuildContext context) {
    final String displayTitle = mediaSource.getDisplayTitleFromMediaItem(
      widget.item,
    );
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
      coverMaterial: _coverMaterial,
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
// Presentation
// ---------------------------------------------------------------------------

/// 条目菜单的三种呈现（2026-10-25 用户拍板「手机 B + 桌面 D + E」）：
///
/// * [sheet]：窄屏（手机）从底部抽出的抽屉——紧凑书头 + 主动作大色块 + 4 列
///   图标宫格（设计稿 B）。
/// * [dialog]：宽屏居中对话框——左栏封面 / 标题 / 主动作 / 删除，右栏按
///   [DialogActionGroup] 分节的分段列表（设计稿 D）。对话框可用宽度不够双栏时
///   退回 B 的宫格内容。
/// * [contextMenu]：桌面鼠标右键，在指针处弹出的菜单——迷你书头 + 主动作图标排
///   + 分组菜单行，「设置」组收进悬停子菜单（设计稿 E）。
enum MediaItemActionsLayout { sheet, dialog, contextMenu }

/// 告诉 [MediaItemDialogFrame] 当前由哪种容器承载。没有它时按 [dialog] 排版
/// （直接用 [showAppDialog] 弹出的旧调用点与测试）。
class MediaItemActionsHost extends InheritedWidget {
  const MediaItemActionsHost({
    required this.layout,
    required super.child,
    super.key,
  });

  final MediaItemActionsLayout layout;

  static MediaItemActionsLayout layoutOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MediaItemActionsHost>()
          ?.layout ??
      MediaItemActionsLayout.dialog;

  @override
  bool updateShouldNotify(MediaItemActionsHost oldWidget) =>
      oldWidget.layout != layout;
}

/// 全应用唯一的条目菜单入口：书 / 漫画 / 有声书 / 视频 / 游戏 / 合集卡的长按、
/// 右键与键盘 / 手柄长按确认都走这里。
///
/// * [anchor] 非空（鼠标右键的全局坐标）→ 在指针处弹右键菜单；
/// * 否则窄屏（< [kFushiSheetWideBreakpoint]）→ 底部抽屉；
/// * 否则 → 居中对话框。
///
/// [builder] 返回 [MediaItemDialogPage] / [MediaItemDialogFrame]，三种容器共用
/// 同一份动作清单，各动作的 `Navigator.pop(dialogContext)` 对三种路由都成立。
Future<T?> showMediaItemActions<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Offset? anchor,
}) {
  // 卡片右键经 [contextMenuInvoker] 同步派发到这里时，按下坐标就在
  // [activeContextMenuAnchor] 里；先 await 再弹的调用方自己在入口处读好传进来。
  final Offset? globalAnchor = anchor ?? activeContextMenuAnchor;
  if (globalAnchor != null) {
    final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
    // 全局 UI 缩放下 Overlay 与屏幕坐标不同尺度：一律经 globalToLocal 换算
    // （同 showFushiMenu 的锚点，BUG-781）。
    final RenderBox? overlayBox =
        navigator.overlay?.context.findRenderObject() as RenderBox?;
    final Offset local =
        overlayBox?.globalToLocal(globalAnchor) ?? globalAnchor;
    return navigator.push<T>(
      _MediaItemContextMenuRoute<T>(
        anchor: local,
        themes: InheritedTheme.capture(from: context, to: navigator.context),
        barrierLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
        reduceMotion: !fushiMotionEnabled(context),
        builder: (BuildContext menuContext) => MediaItemActionsHost(
          layout: MediaItemActionsLayout.contextMenu,
          child: builder(menuContext),
        ),
      ),
    );
  }
  final bool narrow =
      MediaQuery.sizeOf(context).width < kFushiSheetWideBreakpoint;
  // Apple 移动端的系统弹层（showCupertinoModalPopup）不给面板底色，这里改用
  // 对话框承载同一份宫格内容。
  if (narrow && !isCupertinoPlatform(context)) {
    return adaptiveModalSheet<T>(
      context: context,
      builder: (BuildContext sheetContext) => MediaItemActionsHost(
        layout: MediaItemActionsLayout.sheet,
        child: builder(sheetContext),
      ),
    );
  }
  return showAppDialog<T>(
    context: context,
    builder: (BuildContext dialogContext) => MediaItemActionsHost(
      layout: MediaItemActionsLayout.dialog,
      child: builder(dialogContext),
    ),
  );
}

/// 分组的显示名（分节标题 / 子菜单名）。
String _groupLabel(DialogActionGroup group) => switch (group) {
  DialogActionGroup.organize => t.item_actions_group_organize,
  DialogActionGroup.content => t.item_actions_group_content,
  DialogActionGroup.progress => t.item_actions_group_progress,
  DialogActionGroup.settings => t.item_actions_group_settings,
};

// ---------------------------------------------------------------------------
// Dialog frame (pure layout, testable in isolation)
// ---------------------------------------------------------------------------

/// Long-press / right-click media menu shared by the book, manga, audiobook,
/// video, game and collection libraries.
///
/// 2026-10-25 重设计（用户拍板「手机 B + 桌面 D + E」，设计稿
/// `fushi/build/book_menu_design/`）：旧版不分组，十几个动作 2×6 等权平铺，
/// 顶部还垫一层封面高斯模糊（与库页定版「不要封面模糊背景」冲突）。现在动作按
/// [DialogActionGroup] 分组，由承载容器（[MediaItemActionsHost]）决定排法：
///
/// * **抽屉 / 窄对话框（B）**：紧凑书头（小封面 + 全名 + 作者）→ 启动按钮 →
///   不多于 [_heroMaxActions] 个快捷动作画成大色块 → 其余动作按组排成 4 列
///   图标宫格（形状容器，悬停 / 聚焦 / 开着时从圆角方变圆形）→ 删除类描边按钮。
/// * **宽对话框（D）**：左栏是条目身份（封面卡、全名、作者、启动、快捷动作、
///   删除），右栏按组分节的分段列表；够宽时右栏两列。
/// * **右键菜单（E）**：见 [_ContextMenuPanel]。
///
/// 两套设计系统同一棵树，只换叶子控件与颜色：MD3 Expressive 用形状变形 /
/// 分段列表；Apple 用圆形填充钮 + 菜单行（实色面，2026-10-13 拍板）。
/// 进场：宫格 / 列表行 / 菜单行错峰（[FushiStaggeredEntrance]），按压缩放
/// （[FushiPressScale]）；墨水屏与「减弱动态效果」下全部归零。
///
/// The launch/read affordance is optional so shelf book long-press menus can
/// stay management-only while ordinary history dialogs can still expose it.
///
/// 不是 `@visibleForTesting`：视频卡（`home_video_page._showVideoMenu`）与游戏卡
/// （`games_library_page._GameCard`）的菜单在生产直接复用本骨架。
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
    this.coverMaterial,
    super.key,
  });

  /// 封面 widget（调用方自己负责 `BoxFit.contain` 与解码失败兜底）。本骨架把它
  /// 放进按宽高比定尺寸的封面卡里，所以 contain 恰好铺满、不留边。
  final Widget? cover;

  /// 封面图源：只用来探测封面宽高比（横版视频封面与竖版书封排法不同）。
  ///
  /// 只收图源、不复用 [cover] widget：后者可能带 key / GlobalKey，画两遍会撞
  /// key。解码按 [_aspectDecodeWidth] 降采样，宽高比只差不到 1%。为 null 时
  /// 封面卡按默认竖版比例。
  final ImageProvider? coverBackdrop;

  /// 封面卡的条目材质（库页定版，用户 2026-10-26：长按菜单封面与库页同一套
  /// 材质）：由调用方按条目域给——书 / 漫画 [ShelfCoverMaterial.glossyBook]、
  /// 视频 [ShelfCoverMaterial.glossyPoster]、游戏 [ShelfCoverMaterial.gameCase]。
  /// null = 旧封面卡（圆角 + 投影）；墨水屏下材质自动退回描边框。
  final ShelfCoverMaterial? coverMaterial;
  final String title;
  final String? author;
  final bool showLaunchAction;
  final String? launchLabel;
  final VoidCallback? onLaunch;
  final List<DialogQuickAction> quickActions;
  final List<DialogListAction> listActions;
  final List<DialogDangerAction> dangerActions;

  /// 宽高比探测的解码宽度（像素）。
  static const int _aspectDecodeWidth = 64;

  /// 屏宽达到它对话框放宽到 [_wideMaxWidth]（右栏两列）；否则 [_midMaxWidth]。
  static const double _wideScreenMinWidth = 900;
  static const double _wideMaxWidth = 780;
  static const double _midMaxWidth = 600;
  static const double _narrowMaxWidth = 420;

  /// 对话框可用宽度达到它才走双栏（D），否则退回宫格（B）。
  static const double _twoPaneMinWidth = 540;

  /// 右栏可用宽度达到它分两列。
  static const double _twoColumnMinWidth = 460;

  /// 宽高比超过它按横版封面（视频）排。
  static const double _bannerMinAspect = 1.15;

  /// 材质封面宽不超过它时走 [ShelfCoverDensity.compact]（宫格 / 右键菜单的
  /// 小书头，含横版视频的 104 宽），更宽的（双栏左栏大封面）走完整材质。
  static const double _compactCoverMaxWidth = 104;

  /// 宽高比尚未解析时的默认比例：书封最常见的 2:3。
  static const double _defaultPortraitAspect = 2 / 3;

  /// 快捷动作不多于它时画成大色块 / 左栏按钮；更多时（本地视频八项）并进宫格
  /// 与分组列表——一排挤满低频管理动作会把它们抬成主操作，层级是反的。
  static const int _heroMaxActions = 3;

  /// 右键菜单顶部图标排最多放几个快捷动作；更多时改成菜单行。
  static const int _menuIconBarMax = 5;

  static ImageProvider? _downsampled(ImageProvider? source) {
    // ResizeImage 不能嵌套（内层断言 getTargetSize == null）：先剥掉外层所有
    // ResizeImage 再套自己的一层。
    ImageProvider? base = source;
    while (base is ResizeImage) {
      base = base.imageProvider;
    }
    if (base == null) return null;
    return ResizeImage(base, width: _aspectDecodeWidth);
  }

  bool get _hasLaunch =>
      showLaunchAction && launchLabel != null && onLaunch != null;

  bool get _quickAsHero => quickActions.length <= _heroMaxActions;

  /// 不进大色块的动作，按组（再按原顺序）排好：宫格与分组列表共用。
  List<DialogAction> get _groupedActions {
    final List<DialogAction> all = <DialogAction>[
      if (!_quickAsHero) ...quickActions,
      ...listActions,
    ];
    return <DialogAction>[
      for (final DialogActionGroup group in DialogActionGroup.values)
        ...all.where((DialogAction a) => a.group == group),
    ];
  }

  Map<DialogActionGroup, List<DialogAction>> get _sections {
    final Map<DialogActionGroup, List<DialogAction>> sections =
        <DialogActionGroup, List<DialogAction>>{};
    for (final DialogAction action in _groupedActions) {
      (sections[action.group] ??= <DialogAction>[]).add(action);
    }
    return sections;
  }

  @override
  Widget build(BuildContext context) {
    final MediaItemActionsLayout layout = MediaItemActionsHost.layoutOf(
      context,
    );
    final ImageProvider? decoded = _downsampled(coverBackdrop);
    Widget resolve(Widget Function(double? aspect) build) =>
        _CoverAspectResolver(
          image: decoded,
          builder: (BuildContext context, double? aspect) => build(aspect),
        );
    switch (layout) {
      case MediaItemActionsLayout.contextMenu:
        return resolve(
          (double? aspect) => _ContextMenuPanel(frame: this, aspect: aspect),
        );
      case MediaItemActionsLayout.sheet:
        return resolve(
          (double? aspect) => SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: _buildGridBody(context, aspect: aspect, inSheet: true),
            ),
          ),
        );
      case MediaItemActionsLayout.dialog:
        final double screenWidth = MediaQuery.sizeOf(context).width;
        final double maxWidth = screenWidth >= _wideScreenMinWidth
            ? _wideMaxWidth
            : (screenWidth >= kFushiSheetWideBreakpoint
                  ? _midMaxWidth
                  : _narrowMaxWidth);
        return FushiDialogFrame(
          maxWidth: maxWidth,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                resolve(
                  (double? aspect) => constraints.maxWidth >= _twoPaneMinWidth
                      ? _buildTwoPaneBody(
                          context,
                          aspect: aspect,
                          width: constraints.maxWidth,
                        )
                      : _buildGridBody(context, aspect: aspect),
                ),
          ),
        );
    }
  }

  // -- shared pieces -----------------------------------------------------------

  /// 封面卡：按 [aspect] 定尺寸（宽不超过 [maxWidth]、高不超过 [maxHeight]），
  /// 整幅可见不裁切。MD3 圆角 [radius] + 投影；Apple 两层柔和阴影；给了
  /// [coverMaterial] 时改走库页材质框（[ShelfCoverFrame]）。
  Widget _buildCoverCard(
    BuildContext context, {
    required double? aspect,
    required double maxWidth,
    required double maxHeight,
    double radius = 12,
  }) {
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final bool dark =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    final Color fill = apple
        ? appleColorsOf(context).secondaryFill
        : FushiDesignTokens.of(context).surfaces.overlay;
    final ShelfCoverMaterial? material = coverMaterial;
    final BorderRadius borderRadius = material == null
        ? BorderRadius.all(Radius.circular(radius))
        : shelfMaterialRadius(material);
    // 前景封面只画这一次（材质 / 旧卡共用）：外层再决定材质框还是圆角投影卡。
    final Widget front = ClipRRect(
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: cover!,
    );
    final Widget card;
    if (material != null) {
      // 材质封面：外轮廓 / 投影 / 光泽全归 [ShelfCoverFrame]，不再叠本卡的
      // 圆角与投影。宽不超过 [_compactCoverMaxWidth] 的小头像（宫格书头、右键
      // 菜单书头）走简化档：只有圆角 + 内描边 + 轻光泽。
      card = ShelfCoverMaterialScope(
        material: material,
        child: ShelfCoverFrame(
          backgroundColor: fill,
          density: maxWidth <= _compactCoverMaxWidth
              ? ShelfCoverDensity.compact
              : ShelfCoverDensity.regular,
          child: front,
        ),
      );
    } else {
      final List<BoxShadow>? shadows = eink
          ? null
          : <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: apple ? (dark ? 0.45 : 0.18) : 0.28,
                ),
                blurRadius: apple ? 24 : 14,
                spreadRadius: apple ? -4 : 0,
                offset: Offset(0, apple ? 10 : 5),
              ),
            ];
      card = DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: borderRadius,
          boxShadow: shadows,
        ),
        child: front,
      );
    }
    final double ratio = aspect ?? _defaultPortraitAspect;
    double width = maxWidth;
    double height = width / ratio;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * ratio;
    }
    return SizedBox(width: width, height: height, child: card);
  }

  TextStyle _titleStyle(BuildContext context, {required bool large}) {
    final TextTheme text = Theme.of(context).textTheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (isGlassDesign(context)) {
      return ((large ? text.titleLarge : text.titleMedium) ??
              tokens.type.pageTitle)
          .copyWith(
            color: appleColorsOf(context).label,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
            height: 1.25,
          );
    }
    return ((large ? text.titleLarge : text.titleMedium) ??
            tokens.type.pageTitle)
        .copyWith(
          color: Theme.of(context).colorScheme.onSurface,
          fontWeight: FontWeight.w600,
          height: 1.3,
        );
  }

  TextStyle _authorStyle(BuildContext context) {
    if (isGlassDesign(context)) {
      return FushiAppleMetrics.of(context).subtitleStyle(context);
    }
    final TextTheme text = Theme.of(context).textTheme;
    return (text.bodyMedium ?? FushiDesignTokens.of(context).type.listSubtitle)
        .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
  }

  /// 标题 + 作者。TODO-2490：本菜单是卡片「看全名」的兜底路径，标题不截断
  /// （外层可滚动）。
  Widget _buildTitleBlock(BuildContext context, {required bool large}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: _titleStyle(context, large: large)),
        if (author != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            author!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _authorStyle(context),
          ),
        ],
      ],
    );
  }

  Widget _buildLaunchButton(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final double height = apple ? (fushiAppleCompact(context) ? 36 : 50) : 52;
    return SizedBox(
      width: double.infinity,
      height: height,
      child: FushiFilledButton(
        onPressed: onLaunch,
        style: FilledButton.styleFrom(
          minimumSize: Size(0, height),
          textStyle: apple ? null : Theme.of(context).textTheme.titleMedium,
        ),
        child: Text(launchLabel!, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  // -- B: sheet / narrow dialog ------------------------------------------------

  Widget _buildGridBody(
    BuildContext context, {
    required double? aspect,
    bool inSheet = false,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double pad = tokens.spacing.card;
    final bool banner = aspect != null && aspect > _bannerMinAspect;
    final List<DialogAction> tiles = _groupedActions;
    final List<DialogQuickAction> hero = _quickAsHero
        ? quickActions
        : const <DialogQuickAction>[];
    int index = 0;
    return FushiEntranceScope(
      child: Padding(
        padding: EdgeInsets.fromLTRB(pad, inSheet ? 0 : pad, pad, pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiStaggeredEntrance(
              index: index++,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  if (cover != null) ...<Widget>[
                    _buildCoverCard(
                      context,
                      aspect: aspect,
                      maxWidth: banner ? 104 : 56,
                      maxHeight: 84,
                      radius: 8,
                    ),
                    SizedBox(width: tokens.spacing.rowHorizontal),
                  ],
                  Expanded(child: _buildTitleBlock(context, large: false)),
                ],
              ),
            ),
            SizedBox(height: tokens.spacing.card),
            if (_hasLaunch) ...<Widget>[
              FushiStaggeredEntrance(
                index: index++,
                child: _buildLaunchButton(context),
              ),
              SizedBox(height: tokens.spacing.gap),
            ],
            if (hero.isNotEmpty) ...<Widget>[
              FushiStaggeredEntrance(
                index: index++,
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int i = 0; i < hero.length; i++) ...<Widget>[
                        if (i > 0) SizedBox(width: tokens.spacing.gap),
                        Expanded(
                          child: _HeroActionTile(
                            action: hero[i],
                            tone: i,
                            vertical: hero.length > 2,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              SizedBox(height: tokens.spacing.gap),
            ],
            if (tiles.isNotEmpty)
              _buildTileGrid(context, tiles, firstIndex: index),
            if (dangerActions.isNotEmpty) ...<Widget>[
              SizedBox(height: tokens.spacing.card),
              Row(
                children: <Widget>[
                  for (int i = 0; i < dangerActions.length; i++) ...<Widget>[
                    if (i > 0) SizedBox(width: tokens.spacing.gap),
                    Expanded(
                      child: FushiOutlinedButton.icon(
                        onPressed: dangerActions[i].onPressed,
                        destructive: !dangerActions[i].muted,
                        icon: FushiIcon(dangerActions[i].icon, size: 18),
                        label: Text(
                          dangerActions[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTileGrid(
    BuildContext context,
    List<DialogAction> tiles, {
    required int firstIndex,
  }) {
    const int columns = 4;
    final List<Widget> rows = <Widget>[];
    for (int start = 0; start < tiles.length; start += columns) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 4));
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int c = 0; c < columns; c++)
              Expanded(
                child: start + c < tiles.length
                    ? FushiStaggeredEntrance(
                        index: firstIndex + start + c,
                        child: _ActionTile(action: tiles[start + c]),
                      )
                    : const SizedBox.shrink(),
              ),
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

  // -- D: two-pane dialog ------------------------------------------------------

  Widget _buildTwoPaneBody(
    BuildContext context, {
    required double? aspect,
    required double width,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final double screenHeight = MediaQuery.sizeOf(context).height;
    final bool banner = aspect != null && aspect > _bannerMinAspect;
    const double leftWidth = 236;
    final double pad = tokens.spacing.card;
    final List<DialogQuickAction> paneQuick = _quickAsHero
        ? quickActions
        : const <DialogQuickAction>[];
    final Map<DialogActionGroup, List<DialogAction>> sections = _sections;
    final double rightWidth = width - leftWidth;
    final int columns = rightWidth >= _twoColumnMinWidth && sections.length > 1
        ? 2
        : 1;
    final List<List<DialogActionGroup>> columnGroups = _balanceSections(
      sections,
      columns,
    );
    final Color leftColor = apple
        ? appleColorsOf(context).tertiaryFill
        : Theme.of(context).colorScheme.surfaceContainer;
    int index = 0;
    final Widget left = Padding(
      padding: EdgeInsets.all(pad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (cover != null) ...<Widget>[
            Center(
              child: _buildCoverCard(
                context,
                aspect: aspect,
                maxWidth: banner ? leftWidth - pad * 2 : 152,
                maxHeight: screenHeight * 0.34,
              ),
            ),
            SizedBox(height: tokens.spacing.card),
          ],
          _buildTitleBlock(context, large: true),
          if (_hasLaunch || paneQuick.isNotEmpty)
            SizedBox(height: tokens.spacing.card),
          if (_hasLaunch) ...<Widget>[
            _buildLaunchButton(context),
            if (paneQuick.isNotEmpty) SizedBox(height: tokens.spacing.gap),
          ],
          for (int i = 0; i < paneQuick.length; i++) ...<Widget>[
            if (i > 0) SizedBox(height: tokens.spacing.gap),
            FushiPressScale(
              child: FushiFilledButton.tonalIcon(
                onPressed: paneQuick[i].onPressed,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: FushiIcon(paneQuick[i].icon, size: 18),
                label: Text(
                  paneQuick[i].label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          if (dangerActions.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.card),
            for (final DialogDangerAction action in dangerActions)
              FushiTextButton.icon(
                onPressed: action.onPressed,
                destructive: !action.muted,
                icon: FushiIcon(action.icon, size: 18),
                label: Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ],
      ),
    );
    final Widget right = Padding(
      padding: EdgeInsets.fromLTRB(pad, pad / 2, pad / 2, pad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FushiIconButton(
              icon: FushiIcons.close,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
          Padding(
            padding: EdgeInsetsDirectional.only(end: pad / 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (int c = 0; c < columnGroups.length; c++) ...<Widget>[
                  if (c > 0) SizedBox(width: tokens.spacing.gap + 4),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (final DialogActionGroup group
                            in columnGroups[c]) ...<Widget>[
                          _SectionLabel(text: _groupLabel(group)),
                          _ActionSection(
                            actions: sections[group]!,
                            firstIndex: () {
                              final int start = index;
                              index += sections[group]!.length;
                              return start;
                            }(),
                          ),
                          SizedBox(height: tokens.spacing.gap + 4),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return FushiEntranceScope(
      child: Stack(
        children: <Widget>[
          // 左栏底色铺满整个对话框高度（右栏更高时也不断开）。
          PositionedDirectional(
            start: 0,
            top: 0,
            bottom: 0,
            width: leftWidth,
            child: ColoredBox(color: leftColor),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(width: leftWidth, child: left),
              Expanded(child: right),
            ],
          ),
        ],
      ),
    );
  }

  /// 把分节按动作数均匀分进 [columns] 列（保持分组顺序，贪心放进当前最矮的列）。
  static List<List<DialogActionGroup>> _balanceSections(
    Map<DialogActionGroup, List<DialogAction>> sections,
    int columns,
  ) {
    final List<List<DialogActionGroup>> result = <List<DialogActionGroup>>[
      for (int i = 0; i < columns; i++) <DialogActionGroup>[],
    ];
    final List<int> heights = List<int>.filled(columns, 0);
    for (final MapEntry<DialogActionGroup, List<DialogAction>> entry
        in sections.entries) {
      int target = 0;
      for (int i = 1; i < columns; i++) {
        if (heights[i] < heights[target]) target = i;
      }
      result[target].add(entry.key);
      // 分节标题按一行算。
      heights[target] += entry.value.length + 1;
    }
    return result.where((List<DialogActionGroup> c) => c.isNotEmpty).toList();
  }
}

/// 分节标题（MD3：labelLarge primary；Apple：footnote secondaryLabel）。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final TextStyle style = apple
        ? FushiAppleMetrics.of(context)
              .footnoteStyle(context)
              .copyWith(color: appleColorsOf(context).secondaryLabel)
        : (textTheme.labelLarge ?? const TextStyle()).copyWith(
            color: Theme.of(context).colorScheme.primary,
          );
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 8),
      child: Semantics(header: true, child: Text(text, style: style)),
    );
  }
}

/// 一节分组动作：MD3 分段列表（组首尾 [kSettingsSegmentOuterRadius]、组内
/// [kSettingsSegmentInnerRadius]、缝 [kSettingsSegmentGap]）；Apple 一块实色
/// 圆角面板里的菜单行。
class _ActionSection extends StatelessWidget {
  const _ActionSection({required this.actions, required this.firstIndex});

  final List<DialogAction> actions;
  final int firstIndex;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      final FushiAppleColors palette = appleColorsOf(context);
      return DecoratedBox(
        decoration: BoxDecoration(
          color: palette.secondaryGroupedBackground,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < actions.length; i++)
                FushiStaggeredEntrance(
                  index: firstIndex + i,
                  child: _AppleMenuRow(
                    icon: actions[i].icon,
                    label: actions[i].label,
                    onPressed: actions[i].onPressed,
                    selected: actions[i].selected,
                  ),
                ),
            ],
          ),
        ),
      );
    }
    const Radius outer = Radius.circular(kSettingsSegmentOuterRadius);
    const Radius inner = Radius.circular(kSettingsSegmentInnerRadius);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < actions.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: kSettingsSegmentGap),
          FushiStaggeredEntrance(
            index: firstIndex + i,
            child: _Md3SegmentRow(
              icon: actions[i].icon,
              label: actions[i].label,
              onPressed: actions[i].onPressed,
              selected: actions[i].selected,
              borderRadius: BorderRadius.vertical(
                top: i == 0 ? outer : inner,
                bottom: i == actions.length - 1 ? outer : inner,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 宫格里的一个动作（设计稿 B）：形状容器图标 + 下方最多两行标签。
///
/// MD3 Expressive：56 见方、圆角 18 的 surfaceContainerHighest 形状，悬停 /
/// 键盘聚焦 / 按下时变形成圆（secondaryContainer），开着的开关类动作常驻
/// primary 圆。Apple：52 圆形 secondaryFill 填充钮，开着时 accent。
/// 整块是一个焦点节点：Tab 可达，Enter / 手柄 A 触发。
class _ActionTile extends StatefulWidget {
  const _ActionTile({required this.action});

  final DialogAction action;

  @override
  State<_ActionTile> createState() => _ActionTileState();
}

class _ActionTileState extends State<_ActionTile> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final DialogAction action = widget.action;
    final bool apple = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool active = _hovered || _focused || _pressed;
    final double extent = apple ? 52 : 56;
    final Color background;
    final Color foreground;
    final double radius;
    if (apple) {
      final FushiAppleColors palette = appleColorsOf(context);
      background = action.selected
          ? palette.accent
          : (active ? palette.fill : palette.secondaryFill);
      foreground = action.selected ? palette.onAccent : palette.label;
      radius = extent / 2;
    } else {
      background = action.selected
          ? scheme.primary
          : (active
                ? scheme.secondaryContainer
                : scheme.surfaceContainerHighest);
      foreground = action.selected
          ? scheme.onPrimary
          : (active ? scheme.onSecondaryContainer : scheme.onSurfaceVariant);
      radius = action.selected || active ? extent / 2 : 18;
    }
    final Color labelColor = apple
        ? appleColorsOf(context).label
        : scheme.onSurface;
    final TextStyle labelStyle =
        (Theme.of(context).textTheme.labelMedium ?? const TextStyle()).copyWith(
          color: labelColor,
          fontWeight: FontWeight.w500,
          height: 1.25,
        );
    final Duration morph = fushiMotionDuration(context, FushiMotion.medium);
    final Color ring = apple ? appleColorsOf(context).accent : scheme.primary;
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            action.onPressed();
            return null;
          },
        ),
      },
      onShowHoverHighlight: (bool value) => setState(() => _hovered = value),
      onShowFocusHighlight: (bool value) => setState(() => _focused = value),
      child: Semantics(
        button: true,
        selected: action.selected ? true : null,
        label: action.label,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          onTap: action.onPressed,
          child: FushiPressScale(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AnimatedContainer(
                    duration: morph,
                    curve: FushiMotion.release,
                    width: extent,
                    height: extent,
                    decoration: BoxDecoration(
                      color: background,
                      borderRadius: BorderRadius.all(Radius.circular(radius)),
                      border: _focused
                          ? Border.all(color: ring, width: 2)
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: FushiIcon(action.icon, size: 24, color: foreground),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    action.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: labelStyle,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 抽屉里的主动作大色块（设计稿 B 顶部两块）：MD3 依次取 primaryContainer /
/// tertiaryContainer / secondaryContainer，按压变形（圆角 20 → 28）；Apple 用
/// secondaryFill 圆角 16。≤2 个时图标在左、文字在右；3 个时图标在上。
class _HeroActionTile extends StatelessWidget {
  const _HeroActionTile({
    required this.action,
    required this.tone,
    required this.vertical,
  });

  final DialogQuickAction action;
  final int tone;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background;
    final Color foreground;
    if (apple) {
      final FushiAppleColors palette = appleColorsOf(context);
      background = action.selected ? palette.accent : palette.secondaryFill;
      foreground = action.selected ? palette.onAccent : palette.label;
    } else {
      (background, foreground) = switch (tone % 3) {
        0 => (scheme.primaryContainer, scheme.onPrimaryContainer),
        1 => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
        _ => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      };
    }
    final TextStyle labelStyle =
        (Theme.of(context).textTheme.titleSmall ?? const TextStyle()).copyWith(
          color: foreground,
          height: 1.25,
        );
    final Widget icon = FushiIcon(action.icon, size: 24, color: foreground);
    final Widget label = Text(
      action.label,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: vertical ? TextAlign.center : TextAlign.start,
      style: labelStyle,
    );
    final BorderRadius radius = BorderRadius.all(
      Radius.circular(apple ? 16 : 20),
    );
    return FushiPressScale(
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: action.onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: vertical
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        icon,
                        const SizedBox(height: 6),
                        label,
                      ],
                    )
                  : Row(
                      children: <Widget>[
                        icon,
                        const SizedBox(width: 12),
                        Expanded(child: label),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// E: desktop right-click context menu
// ---------------------------------------------------------------------------

class _MediaItemContextMenuRoute<T> extends PopupRoute<T> {
  _MediaItemContextMenuRoute({
    required this.anchor,
    required this.builder,
    required this.themes,
    required this.barrierLabel,
    required this.reduceMotion,
  });

  final Offset anchor;
  final WidgetBuilder builder;
  final CapturedThemes themes;
  final bool reduceMotion;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : FushiMotion.short;

  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : FushiMotion.micro;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return themes.wrap(
      Builder(
        builder: (BuildContext context) => CustomSingleChildLayout(
          delegate: _ContextMenuLayout(
            anchor: anchor,
            padding: MediaQuery.paddingOf(context),
          ),
          child: builder(context),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final Animation<double> curved = CurvedAnimation(
      parent: animation,
      curve: FushiMotion.enter,
      reverseCurve: FushiMotion.exit,
    );
    final Animation<double> scale = Tween<double>(
      begin: 0.92,
      end: 1,
    ).animate(curved);
    // [child] 是铺满 Overlay 的整页（菜单由 [_ContextMenuLayout] 定位在其中），
    // 缩放原点必须是指针本身：菜单的某个角就贴在指针上，绕指针缩放 = 从那个角
    // 长出来。原点若取整页的 topLeft（屏幕左上角），进场时整块菜单会从屏幕左上
    // 方向朝指针滑过来，指针越靠右下滑得越远，看起来像从侧边弹出。
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: scale,
        child: child,
        builder: (BuildContext context, Widget? child) => Transform.scale(
          scale: scale.value,
          alignment: Alignment.topLeft,
          origin: anchor,
          child: child,
        ),
      ),
    );
  }
}

/// 让菜单的一个角贴在指针上（桌面右键菜单惯例）：横向默认向右展开、右侧放不下
/// 翻到左侧；纵向默认向下展开、下方放不下翻到上方。两侧都放不下时取空间大的
/// 一侧，并把菜单限高到那一侧的空间（面板自带滚动）——而不是整块夹到屏幕顶 /
/// 底，那样菜单会横跨指针、没有任何一个角在指针处。
class _ContextMenuLayout extends SingleChildLayoutDelegate {
  const _ContextMenuLayout({required this.anchor, required this.padding});

  final Offset anchor;
  final EdgeInsets padding;

  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final Size size = constraints.biggest;
    final double left = padding.left + _margin;
    final double top = padding.top + _margin;
    final double right = size.width - padding.right - _margin;
    final double bottom = size.height - padding.bottom - _margin;
    // 只给指针两侧中较大的那一侧：菜单无论怎么翻，都能完整落在那一侧。
    return BoxConstraints(
      maxWidth: math.max(0, math.max(right - anchor.dx, anchor.dx - left)),
      maxHeight: math.max(0, math.max(bottom - anchor.dy, anchor.dy - top)),
    );
  }

  /// 一维上选展开方向：正向（右 / 下）放得下就正向，否则反向放得下就反向，
  /// 都放不下取空间大的一侧（[getConstraintsForChild] 已按它限过尺寸）。
  static double _place(double anchor, double extent, double min, double max) {
    if (anchor + extent <= max) return anchor;
    if (anchor - extent >= min) return anchor - extent;
    return max - anchor >= anchor - min ? anchor : anchor - extent;
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double left = padding.left + _margin;
    final double top = padding.top + _margin;
    final double right = size.width - padding.right - _margin;
    final double bottom = size.height - padding.bottom - _margin;
    double x = _place(anchor.dx, childSize.width, left, right);
    double y = _place(anchor.dy, childSize.height, top, bottom);
    // 指针本身落在安全区外（刘海 / 边距里右键）时的兜底。
    x = x.clamp(left, math.max(left, right - childSize.width));
    y = y.clamp(top, math.max(top, bottom - childSize.height));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_ContextMenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding;
}

/// 右键菜单本体（设计稿 E）：迷你书头 → 快捷动作图标排（不多于
/// [MediaItemDialogFrame._menuIconBarMax] 个，悬停有 tooltip）→ 启动 → 整理 /
/// 内容 / 进度分段 → 「设置」子菜单 → 删除类。
///
/// MD3：surfaceContainer 面板、圆角 16、行高 40；Apple：系统实色悬浮面、
/// macOS 菜单行（[_AppleMenuRow] 桌面口径）。方向键上下移动焦点，→ 打开子菜单，
/// ← / Esc 收起子菜单，Esc 关闭菜单。
class _ContextMenuPanel extends StatelessWidget {
  const _ContextMenuPanel({required this.frame, required this.aspect});

  final MediaItemDialogFrame frame;
  final double? aspect;

  static const double _width = 288;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool iconBar =
        frame.quickActions.isNotEmpty &&
        frame.quickActions.length <= MediaItemDialogFrame._menuIconBarMax;
    final List<DialogAction> rows = <DialogAction>[
      if (!iconBar) ...frame.quickActions,
      ...frame.listActions,
    ];
    final List<DialogAction> settings = rows
        .where((DialogAction a) => a.group == DialogActionGroup.settings)
        .toList();
    final List<List<DialogAction>> segments = <List<DialogAction>>[
      for (final DialogActionGroup group in DialogActionGroup.values)
        if (group != DialogActionGroup.settings)
          rows.where((DialogAction a) => a.group == group).toList(),
    ].where((List<DialogAction> s) => s.isNotEmpty).toList();
    int index = 0;
    final List<Widget> children = <Widget>[
      FushiStaggeredEntrance(index: index++, child: _buildHeader(context)),
      if (iconBar)
        FushiStaggeredEntrance(
          index: index++,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: _MenuIconBar(actions: frame.quickActions),
          ),
        ),
      if (frame._hasLaunch)
        FushiStaggeredEntrance(
          index: index++,
          child: _ContextMenuRow(
            icon: FushiIcons.play,
            label: frame.launchLabel!,
            onPressed: frame.onLaunch!,
            emphasized: true,
          ),
        ),
      for (int s = 0; s < segments.length; s++) ...<Widget>[
        if (s > 0 || frame._hasLaunch) const _MenuDivider(),
        for (final DialogAction action in segments[s])
          FushiStaggeredEntrance(
            index: index++,
            child: _ContextMenuRow(
              icon: action.icon,
              label: action.label,
              onPressed: action.onPressed,
              selected: action.selected,
            ),
          ),
      ],
      if (settings.isNotEmpty) ...<Widget>[
        if (segments.isNotEmpty || frame._hasLaunch) const _MenuDivider(),
        FushiStaggeredEntrance(
          index: index++,
          child: _ContextSubmenuRow(
            label: _groupLabel(DialogActionGroup.settings),
            actions: settings,
          ),
        ),
      ],
      if (frame.dangerActions.isNotEmpty) ...<Widget>[
        const _MenuDivider(),
        for (final DialogDangerAction action in frame.dangerActions)
          FushiStaggeredEntrance(
            index: index++,
            child: _ContextMenuRow(
              icon: action.icon,
              label: action.label,
              onPressed: action.onPressed,
              destructive: !action.muted,
            ),
          ),
      ],
    ];
    final ShapeBorder shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(apple ? 12 : 16)),
    );
    final Widget body = Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
        SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
      },
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: FushiEntranceScope(
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
    return SizedBox(
      width: _width,
      child: apple
          ? DecoratedBox(
              decoration: fushiAppleSolidFloatingDecoration(
                context,
                shape: shape,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: SingleChildScrollView(child: body),
              ),
            )
          : Material(
              color: scheme.surfaceContainer,
              shape: shape,
              elevation: 3,
              shadowColor: Colors.black.withValues(alpha: 0.5),
              surfaceTintColor: Colors.transparent,
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(child: body),
            ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color titleColor = apple
        ? appleColorsOf(context).label
        : Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      child: Row(
        children: <Widget>[
          if (frame.cover != null) ...<Widget>[
            frame._buildCoverCard(
              context,
              aspect: aspect,
              maxWidth: 32,
              maxHeight: 46,
              radius: 4,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiTooltip(
                  message: frame.title,
                  child: Text(
                    frame.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: (textTheme.titleSmall ?? const TextStyle()).copyWith(
                      color: titleColor,
                    ),
                  ),
                ),
                if (frame.author != null)
                  Text(
                    frame.author!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (textTheme.bodySmall ?? const TextStyle()).copyWith(
                      color: frame._authorStyle(context).color,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) {
    final Color color = isGlassDesign(context)
        ? appleColorsOf(context).separator
        : Theme.of(context).colorScheme.outlineVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
      child: SizedBox(
        height: fushiHairline(context),
        child: ColoredBox(color: color),
      ),
    );
  }
}

/// 右键菜单顶部的连接式图标按钮排：首尾大圆角、中间小圆角（M3E 连接式按钮
/// 组），每个都有 tooltip（文字只进 tooltip 与语义）。
class _MenuIconBar extends StatelessWidget {
  const _MenuIconBar({required this.actions});

  final List<DialogQuickAction> actions;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = apple
        ? appleColorsOf(context).secondaryFill
        : scheme.surfaceContainerHighest;
    final Color foreground = apple
        ? appleColorsOf(context).label
        : scheme.onSurface;
    const Radius outer = Radius.circular(20);
    const Radius inner = Radius.circular(8);
    return Row(
      children: <Widget>[
        for (int i = 0; i < actions.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 2),
          Expanded(
            child: FushiTooltip(
              message: actions[i].label,
              child: FushiPressScale(
                child: Material(
                  color: actions[i].selected ? scheme.primary : background,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadiusDirectional.horizontal(
                      start: i == 0 ? outer : inner,
                      end: i == actions.length - 1 ? outer : inner,
                    ).resolve(Directionality.of(context)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: actions[i].onPressed,
                    child: Semantics(
                      button: true,
                      label: actions[i].label,
                      excludeSemantics: true,
                      child: SizedBox(
                        height: 40,
                        child: Center(
                          child: FushiIcon(
                            actions[i].icon,
                            size: 20,
                            color: actions[i].selected
                                ? scheme.onPrimary
                                : foreground,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 右键菜单的一行：MD3 行高 40、圆角 12、悬停 / 聚焦铺 secondaryContainer；
/// Apple 走 [_AppleMenuRow]（macOS 菜单口径）。
class _ContextMenuRow extends StatelessWidget {
  const _ContextMenuRow({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.trailing,
    this.selected = false,
    this.destructive = false,
    this.emphasized = false,
    this.focusNode,
    this.onHover,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Widget? trailing;
  final bool selected;
  final bool destructive;
  final bool emphasized;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onHover;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return MouseRegion(
        onEnter: (_) => onHover?.call(true),
        onExit: (_) => onHover?.call(false),
        child: _AppleMenuRow(
          icon: icon,
          label: label,
          onPressed: onPressed,
          destructive: destructive,
          selected: selected,
          trailing: trailing,
          focusNode: focusNode,
        ),
      );
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color foreground = destructive
        ? scheme.error
        : (selected ? scheme.primary : scheme.onSurface);
    final Color iconColor = destructive
        ? scheme.error
        : (selected ? scheme.primary : scheme.onSurfaceVariant);
    final TextStyle style =
        (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
          color: foreground,
          fontWeight: emphasized ? FontWeight.w600 : null,
        );
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        focusNode: focusNode,
        onHover: onHover,
        onTap: onPressed,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        hoverColor: scheme.secondaryContainer,
        focusColor: scheme.secondaryContainer,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: <Widget>[
                FushiIcon(icon, size: 20, color: iconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
                if (selected && trailing == null)
                  FushiIcon(FushiIcons.check, size: 18, color: scheme.primary),
                if (trailing != null) trailing!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「设置」子菜单行：悬停、点按、Enter 或 → 打开紧贴本行的浮出子菜单（右侧
/// 放不下时翻到左侧），焦点移进子菜单首项；← / Esc 收起并把焦点还给本行。
class _ContextSubmenuRow extends StatefulWidget {
  const _ContextSubmenuRow({required this.label, required this.actions});

  final String label;
  final List<DialogAction> actions;

  @override
  State<_ContextSubmenuRow> createState() => _ContextSubmenuRowState();
}

class _ContextSubmenuRowState extends State<_ContextSubmenuRow> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  final FocusNode _rowFocus = FocusNode(debugLabel: 'item_menu_submenu_row');
  final FocusScopeNode _menuScope = FocusScopeNode(
    debugLabel: 'item_menu_submenu',
  );
  bool _hoverRow = false;
  bool _hoverMenu = false;

  static const double _width = 232;

  @override
  void dispose() {
    _rowFocus.dispose();
    _menuScope.dispose();
    super.dispose();
  }

  void _open({bool focusFirst = false}) {
    if (!_portal.isShowing) setState(_portal.show);
    if (focusFirst) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _menuScope.requestFocus();
        _menuScope.nextFocus();
      });
    }
  }

  void _close({bool refocusRow = false}) {
    if (_portal.isShowing) setState(_portal.hide);
    if (refocusRow) _rowFocus.requestFocus();
  }

  void _syncHover() {
    // 指针从行移到子菜单要穿过两者之间的缝：延一帧再判，免得一离开行就收起。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_hoverRow || _hoverMenu) {
        _open();
      } else if (!_menuScope.hasFocus) {
        _close();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    final bool flip =
        _link.leaderSize != null &&
        (context.findRenderObject() as RenderBox?) != null &&
        () {
          final RenderBox box = context.findRenderObject()! as RenderBox;
          final double right = box.localToGlobal(Offset(box.size.width, 0)).dx;
          return right + _width > MediaQuery.sizeOf(context).width - 8;
        }();
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (BuildContext overlayContext) =>
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: flip ? Alignment.topLeft : Alignment.topRight,
            followerAnchor: flip ? Alignment.topRight : Alignment.topLeft,
            offset: Offset(flip ? -4 : 4, -6),
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: MouseRegion(
                onEnter: (_) {
                  _hoverMenu = true;
                  _syncHover();
                },
                onExit: (_) {
                  _hoverMenu = false;
                  _syncHover();
                },
                child: Shortcuts(
                  shortcuts: const <ShortcutActivator, Intent>{
                    SingleActivator(LogicalKeyboardKey.arrowDown):
                        NextFocusIntent(),
                    SingleActivator(LogicalKeyboardKey.arrowUp):
                        PreviousFocusIntent(),
                    SingleActivator(LogicalKeyboardKey.arrowLeft):
                        DismissIntent(),
                    SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      DismissIntent: CallbackAction<DismissIntent>(
                        onInvoke: (DismissIntent intent) {
                          _close(refocusRow: true);
                          return null;
                        },
                      ),
                    },
                    child: FocusScope(
                      node: _menuScope,
                      child: _buildSubmenu(overlayContext),
                    ),
                  ),
                ),
              ),
            ),
          ),
      child: CompositedTransformTarget(
        link: _link,
        child: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowRight): ActivateIntent(),
          },
          child: _ContextMenuRow(
            icon: FushiIcons.settings,
            label: widget.label,
            focusNode: _rowFocus,
            onPressed: () => _open(focusFirst: true),
            onHover: (bool hovering) {
              _hoverRow = hovering;
              _syncHover();
            },
            trailing: FushiIcon(
              FushiIcons.chevronRight,
              size: 18,
              color: isGlassDesign(context)
                  ? appleColorsOf(context).secondaryLabel
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubmenu(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ShapeBorder shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(apple ? 12 : 16)),
    );
    final Widget body = FushiEntranceScope(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < widget.actions.length; i++)
              FushiStaggeredEntrance(
                index: i,
                child: _ContextMenuRow(
                  icon: widget.actions[i].icon,
                  label: widget.actions[i].label,
                  onPressed: widget.actions[i].onPressed,
                  selected: widget.actions[i].selected,
                ),
              ),
          ],
        ),
      ),
    );
    return SizedBox(
      width: _width,
      child: apple
          ? DecoratedBox(
              decoration: fushiAppleSolidFloatingDecoration(
                context,
                shape: shape,
              ),
              child: Material(type: MaterialType.transparency, child: body),
            )
          : Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              shape: shape,
              elevation: 3,
              shadowColor: Colors.black.withValues(alpha: 0.5),
              surfaceTintColor: Colors.transparent,
              clipBehavior: Clip.antiAlias,
              child: body,
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
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final BorderRadius borderRadius;

  /// 开关类动作当前开着：图标与文字走 primary，行尾一个勾。
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Color iconColor = selected
        ? scheme.primary
        : tokens.surfaces.onVariant;
    return Material(
      color: tokens.surfaces.group,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius,
        side: eink
            ? BorderSide(color: tokens.surfaces.outline)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        overlayColor: eink ? null : fushiMd3ContentStateLayer(scheme),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: tokens.density.listMinHeight),
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
                      color: selected
                          ? scheme.primary
                          : tokens.surfaces.onSurface,
                    ),
                  ),
                ),
                if (selected)
                  FushiIcon(FushiIcons.check, size: 20, color: scheme.primary),
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
    this.selected = false,
    this.trailing,
    this.focusNode,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool destructive;

  /// 开关类动作当前开着：行尾一个勾（macOS 菜单的 checkmark 位）。
  final bool selected;

  /// 行尾附加（子菜单的 chevron）。
  final Widget? trailing;
  final FocusNode? focusNode;

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
    final Widget glyph = FushiIcon(
      widget.icon,
      size: compact ? 15 : 20,
      color: foreground,
    );
    final Widget text = Text(
      widget.label,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: labelStyle,
    );
    final Widget? check = widget.selected
        ? FushiIcon(
            FushiIcons.check,
            size: compact ? 13 : 17,
            color: foreground,
          )
        : null;
    final Widget row = Row(
      children: compact
          ? <Widget>[
              glyph,
              const SizedBox(width: 8),
              Expanded(child: text),
              if (check != null) check,
              if (widget.trailing != null) widget.trailing!,
            ]
          : <Widget>[
              Expanded(child: text),
              if (check != null) ...<Widget>[check, const SizedBox(width: 8)],
              if (widget.trailing != null) ...<Widget>[
                widget.trailing!,
                const SizedBox(width: 8),
              ],
              const SizedBox(width: 4),
              glyph,
            ],
    );
    return FocusableActionDetector(
      focusNode: widget.focusNode,
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
              borderRadius: BorderRadius.all(Radius.circular(compact ? 5 : 12)),
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
    final ImageStream stream = image.resolve(
      createLocalImageConfiguration(context),
    );
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
