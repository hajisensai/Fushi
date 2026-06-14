import 'package:flutter/material.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki/utils.dart';

Rect calcPopupPosition({
  required Rect selectionRect,
  required Size screen,
  double padding = 6.0,
  double maxWidth = 360.0,
  // 默认与单一真相源（preferences_repository.defaultPopupMaxHeight=360）对齐；
  // 两个真实调用方都显式传 appModel.popupMaxHeight，此默认仅兜底/测试用。
  double maxHeight = 360.0,
  double bottomReserve = 0.0,
  double topReserve = 0.0,

  /// 竖排（vertical-rl）时把弹窗放在当前列的左/右侧而非上/下，避免压住正在读的列。
  bool verticalWriting = false,

  /// TODO-107：竖排两侧都放不下时回退横排上下避让的最小宽度阈值。两侧可用宽度都
  /// 低于它（极窄屏 / 选区贴边把弹窗压成窄条）时，左右避让已无意义，改走横排上/下
  /// 避让把整宽留给弹窗——避免「为了不压列而把弹窗挤成一根竖条」的更差观感。
  double minPopupWidth = 200.0,

  /// TODO-107：上下避让分支若被压扁到此高度以下视为「装不下」。仅作竖排回退判据的
  /// 下界保护，避免回退横排后弹窗反而被压成一条更矮的横带——两难时不引入更差结果。
  double minPopupHeight = 120.0,
}) {
  final double reserve = bottomReserve.clamp(0, screen.height);
  final double effectiveTop = topReserve.clamp(0, screen.height);
  final double effectiveBottom = screen.height - reserve;
  final double horizontalInset = padding.clamp(0, screen.width / 2);
  final double verticalInset = padding.clamp(0, effectiveBottom / 2);
  final double availableWidth =
      (screen.width - horizontalInset * 2).clamp(0, maxWidth);
  final double availableHeight =
      (effectiveBottom - effectiveTop - verticalInset * 2).clamp(0, maxHeight);
  final double minLeft = horizontalInset;
  final double minTop = effectiveTop + verticalInset;
  final double maxBottom = effectiveBottom - verticalInset;
  final double maxRight = screen.width - horizontalInset;

  // 当 top+bottom 预留合计超过屏高时 minTop 会越过 maxBottom，使后续 clamp 上下界
  // 反转抛错；夹住 minTop 不超过 maxBottom，两分支共用。
  final double safeMinTop = minTop.clamp(0, maxBottom).toDouble();

  const double gap = 4.0;

  // 横排上/下避让：把弹窗整宽放在选区上方或下方，绝不与 selectionRect 垂直重叠
  // （BUG-098）。竖排两侧都放不下时也回退到它（TODO-107），故抽成共用闭包。
  Rect placeAboveBelow() {
    final double width = availableWidth;
    // 高度直接用 availableHeight（已按 maxHeight 与屏幕可用空间双重 clamp）。
    // 旧实现额外乘 0.5 把高度顶死在半屏，使「弹窗最大高度」设置在半屏以上失效；
    // 去掉后高度设置真正说了算，最高可拉到接近整屏（减边距）。
    double height = availableHeight;
    final double maxLeft = screen.width - width - horizontalInset;

    // BUG-098: the popup must never cover the looked-up word. Place it flush
    // against the selection (above or below) and, when neither side fits the
    // full height, pick the side with more room and shrink the popup to that
    // room — so its rect never overlaps [selectionRect]. The old
    // `top.clamp(maxTop)` pulled a too-tall "below" popup back up over the
    // selection.
    final double roomBelow = maxBottom - (selectionRect.bottom + gap);
    final double roomAbove = (selectionRect.top - gap) - safeMinTop;
    final bool below = height <= roomBelow
        ? true
        : (height <= roomAbove ? false : roomBelow >= roomAbove);

    double top;
    if (below) {
      if (height > roomBelow) height = roomBelow.clamp(0, availableHeight);
      top = selectionRect.bottom + gap;
    } else {
      if (height > roomAbove) height = roomAbove.clamp(0, availableHeight);
      top = (selectionRect.top - gap) - height;
    }
    // Final guard: keep the rect on-screen without re-introducing overlap (the
    // upper bound never drops below minTop / the chosen flush edge).
    final double maxTop = (maxBottom - height).clamp(safeMinTop, maxBottom);
    top = top.clamp(safeMinTop, maxTop);

    double left = selectionRect.left;
    left = left.clamp(minLeft, maxLeft);

    return Rect.fromLTWH(left, top, width, height);
  }

  if (verticalWriting) {
    // 竖排 vertical-rl：右→左读，右侧是已读列。优先把弹窗贴当前列右侧（盖已读、
    // 不挡左边还没读的下一列）；右侧放不下才退到左侧。竖直方向锚到选区顶端往下铺，
    // 与列并排——不与 selectionRect 水平重叠即不压当前列。
    double width = availableWidth;
    final double height = availableHeight;
    final double roomRight = maxRight - (selectionRect.right + gap);
    final double roomLeft = (selectionRect.left - gap) - minLeft;

    // TODO-107：两侧都装不下整宽弹窗、且都低于最小宽阈值时，左右避让只会把弹窗压成
    // 一根挡视线的窄竖条——回退横排上/下避让（placeAboveBelow）把整宽让给弹窗，改从
    // 竖直方向避开当前列。仅当横排回退确有可用高度（>=minPopupHeight）才回退，否则
    // 保留原竖排逻辑（极端两难时不引入更差结果）。
    final bool widthFitsAside = width <= roomRight || width <= roomLeft;
    if (!widthFitsAside &&
        roomRight < minPopupWidth &&
        roomLeft < minPopupWidth) {
      final double roomBelow = maxBottom - (selectionRect.bottom + gap);
      final double roomAbove = (selectionRect.top - gap) - safeMinTop;
      final double bestVerticalRoom =
          roomBelow > roomAbove ? roomBelow : roomAbove;
      if (bestVerticalRoom >= minPopupHeight) {
        return placeAboveBelow();
      }
    }

    final bool right = width <= roomRight
        ? true
        : (width <= roomLeft ? false : roomRight >= roomLeft);
    double left;
    if (right) {
      if (width > roomRight) width = roomRight.clamp(0, availableWidth);
      left = selectionRect.right + gap;
    } else {
      if (width > roomLeft) width = roomLeft.clamp(0, availableWidth);
      left = (selectionRect.left - gap) - width;
    }
    final double maxLeftV = (maxRight - width).clamp(minLeft, maxRight);
    left = left.clamp(minLeft, maxLeftV);

    final double maxTopV = (maxBottom - height).clamp(safeMinTop, maxBottom);
    final double top = selectionRect.top.clamp(safeMinTop, maxTopV);
    return Rect.fromLTWH(left, top, width, height);
  }

  return placeAboveBelow();
}

/// TODO-108：底部固定（dock）模式下的弹窗矩形——忽略选区位置，把弹窗放成屏幕底部
/// 一条全宽面板。[screen] 是可用区域大小；[inset] 是左右及离屏底的内边距；[dockedHeight]
/// 是面板目标高度（会按可用高度 clamp）；[bottomReserve]/[topReserve] 与跟随模式同义
/// （底栏/状态栏等预留），保证 dock 面板不被这些区域遮住。纯函数，reader 与 video 两个
/// 收口点共用同一实现，保证两表面 dock 行为一致。
Rect dockedPopupRect({
  required Size screen,
  double inset = 6.0,
  double dockedHeight = 360.0,
  double bottomReserve = 0.0,
  double topReserve = 0.0,
}) {
  final double reserve = bottomReserve.clamp(0, screen.height);
  final double effectiveTop = topReserve.clamp(0, screen.height);
  final double effectiveBottom = screen.height - reserve;
  final double horizontalInset = inset.clamp(0, screen.width / 2);
  final double verticalInset =
      inset.clamp(0, (effectiveBottom).clamp(0, screen.height) / 2);
  final double width =
      (screen.width - horizontalInset * 2).clamp(0, screen.width);
  final double maxAvail = (effectiveBottom - effectiveTop - verticalInset * 2)
      .clamp(0, screen.height);
  final double height = dockedHeight.clamp(0, maxAvail);
  final double top = (effectiveBottom - verticalInset - height)
      .clamp(effectiveTop + verticalInset, effectiveBottom)
      .toDouble();
  return Rect.fromLTWH(horizontalInset, top, width, height);
}

/// Maps a word rect reported in the popup WebView's own coordinate space
/// ([localRect] — CSS px == the WebView's logical px, origin at the WebView's
/// top-left) to absolute screen coordinates, using the WebView's *live*
/// rendered geometry via [webViewKey].
///
/// BUG-129: a nested lookup must place the child popup against the word the user
/// actually selected inside the parent popup. The parent popup's `Positioned`
/// rect is NOT the WebView's origin — the WebView sits below the popup header
/// (the index-0 audio/favorite controls, ~48px tall) and inside the popup
/// surface border, and may be scaled by ancestor transforms (appUiScale).
/// Reconstructing the rect as `localRect.shift(positioned.topLeft)` ignores all
/// of that, placing the child popup ~header-height above the real word so it
/// covers the very word being looked up. Asking the rendered WebView's
/// [RenderBox] where its corners map (`localToGlobal`) walks the real transform
/// chain, accounting for the header offset, border inset, and any scale in one
/// shot. Falls back to [fallback] only when the render box is unavailable
/// (should not happen at selection time — the parent popup is on-screen).
Rect popupWordScreenRect({
  required GlobalKey webViewKey,
  required Rect localRect,
  required Rect fallback,
}) {
  final RenderObject? obj = webViewKey.currentContext?.findRenderObject();
  if (obj is RenderBox && obj.attached && obj.hasSize) {
    final Offset topLeft = obj.localToGlobal(localRect.topLeft);
    final Offset bottomRight = obj.localToGlobal(localRect.bottomRight);
    return Rect.fromPoints(topLeft, bottomRight);
  }
  return fallback;
}

/// Shared empty result used to mount the popup WebView during the search phase
/// (BUG-080), so popup.html + JS + CSS cold-load in parallel with the FFI
/// lookup instead of serially after it. A single instance keeps the WebView's
/// `didUpdateWidget` from re-pushing between search-state rebuilds (it only
/// re-pushes when the result identity changes to the real result).
final DictionarySearchResult kPopupSearchingPlaceholderResult =
    DictionarySearchResult(searchTerm: '');

class DictionaryPopupLayer extends StatelessWidget {
  const DictionaryPopupLayer({
    required this.result,
    required this.webViewKey,
    required this.onDismiss,
    required this.onTextSelected,
    required this.onLinkClick,
    required this.onMineEntry,
    required this.onDuplicateCheck,
    this.onUpdateEntry,
    this.onFavoriteEntry,
    this.onFavoriteCheck,
    this.onAppendSentence,
    this.isSearching = false,
    this.keepWebViewWarm = false,
    this.onTapOutside,
    this.onScrolledToBottom,
    this.onRendered,
    this.onRenderError,
    this.headerWidget,
    this.overlayWidget,
    this.isDark = false,
    this.overrideFillColor,
    this.showBorder = true,
    this.swipeDismissible = true,
    super.key,
  });

  final DictionarySearchResult? result;
  final bool isSearching;

  /// When true, the popup's [DictionaryPopupWebView] is mounted (and stays
  /// mounted) even with no results and not searching — so the WebView cold-loads
  /// popup.html + JS + CSS ONCE while idle/hidden and is then reused warm for
  /// every later lookup. Used by the persistent warm slot in
  /// [BaseSourcePageState] (BUG-092) to kill the per-lookup white flash on the
  /// reader/video/audiobook surfaces.
  final bool keepWebViewWarm;
  final GlobalKey<DictionaryPopupWebViewState> webViewKey;
  final VoidCallback onDismiss;
  final void Function(String text, Rect localRect) onTextSelected;
  final void Function(String query, Rect localRect) onLinkClick;
  final Future<MinePopupResult> Function(Map<String, String> fields)
      onMineEntry;

  /// TODO-270 D：覆盖「最新制的那张卡」（[noteId] + 新字段）。null 时弹窗不进
  /// 「最新可改」第三态，点 ✓ 仍走旧的查重/再制流程（向后兼容）。
  final Future<MinePopupResult> Function(
      int noteId, Map<String, String> fields)? onUpdateEntry;
  final Future<bool> Function(String expression, String reading)
      onDuplicateCheck;
  final Future<bool> Function(Map<String, String> fields)? onFavoriteEntry;
  final Future<bool> Function(String expression, String reading)?
      onFavoriteCheck;

  /// TODO-270 F/G「查词窗口多句合一制卡」(乙方案)：弹窗「+句」追加当前句到宿主草稿，
  /// 返回累积句数。null 时弹窗不渲染「+句」按钮（纯查词页 / 视频 E 未接入前向后兼容）。
  final Future<int> Function()? onAppendSentence;
  final VoidCallback? onTapOutside;
  final VoidCallback? onScrolledToBottom;
  final VoidCallback? onRendered;

  /// TODO-058 fail-safe：弹窗 WebView 主框架加载失败时触发，宿主据此立即翻可见
  /// 挂起的冷层（加载失败也显示，不卡死）。
  final VoidCallback? onRenderError;
  final Widget? headerWidget;
  final Widget? overlayWidget;
  final bool isDark;
  final Color? overrideFillColor;
  final bool showBorder;
  final bool swipeDismissible;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fillColor = overrideFillColor ?? colorScheme.surface;

    final Widget content = HibikiPopupSurface(
      color: fillColor,
      showBorder: showBorder,
      clipBehavior: showBorder ? Clip.antiAlias : Clip.none,
      child: _buildContent(context, fillColor),
    );

    if (!swipeDismissible) return content;

    return SwipeDismissWrapper(
      sensitivity: ReaderHibikiSource.instance.dismissSwipeSensitivity,
      onDismiss: onDismiss,
      child: content,
    );
  }

  Widget _buildBody(BuildContext context, Color fillColor) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    final bool hasEntries = result != null && result!.entries.isNotEmpty;

    // BUG-080: mount the WebView as soon as the lookup starts (while still
    // searching, before results arrive) so popup.html + JS + CSS cold-load in
    // PARALLEL with the synchronous FFI lookup instead of serially after it.
    // The WebView is transparent (settings) and popup.css body background
    // defaults to `transparent` until results push theme vars, so the empty
    // preload simply shows the themed popup surface behind the spinner — no
    // flash. Real results are pushed via the WebView's didUpdateWidget when
    // they arrive. A finished search with no results falls through to the
    // placeholder below (no WebView kept).
    //
    // [keepWebViewWarm] additionally keeps the WebView mounted while idle (no
    // results, not searching) so a persistent hidden slot can pre-warm it on
    // open and reuse it warm for every lookup (BUG-092).
    if (hasEntries || isSearching || keepWebViewWarm) {
      return Stack(
        children: [
          DictionaryPopupWebView(
            key: webViewKey,
            result: result ?? kPopupSearchingPlaceholderResult,
            onTapOutside: onTapOutside,
            onTextSelected: onTextSelected,
            onLinkClick: onLinkClick,
            onMineEntry: onMineEntry,
            onUpdateEntry: onUpdateEntry,
            onDuplicateCheck: onDuplicateCheck,
            onFavoriteEntry: onFavoriteEntry,
            onFavoriteCheck: onFavoriteCheck,
            onAppendSentence: onAppendSentence,
            onScrolledToBottom: onScrolledToBottom,
            onRendered: onRendered,
            onRenderError: onRenderError,
          ),
          // 搜索期且还没有词条时，用一层不透明主题色盖板（带进度条）盖住 WebView。
          // 视频（mixin reuseWarmSlot）会在结果就绪前就把热槽设为可见，此刻 WebView
          // 是空载——Windows 的 inappwebview fork 不完全尊重 transparentBackground，
          // 会露出白底（用户报「白屏等一会才出字」）。盖板把这段空白替换成与弹窗同色的
          // 加载态，待词条到达即撤掉露出已渲染内容。书内查词结果就绪后才可见
          // （那时 hasEntries=true 不触发）、分页 load-more 有词条也不触发，故只对
          // 视频这条「可见+搜索中+无词条」路径生效，四个表面共用同一组件、观感一致。
          if (isSearching && !hasEntries)
            Positioned.fill(
              child: ColoredBox(
                color: fillColor,
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      backgroundColor: Colors.transparent,
                      color: Theme.of(context).colorScheme.primary,
                      minHeight: 2.75,
                    ),
                    const Expanded(child: SizedBox.shrink()),
                  ],
                ),
              ),
            ),
        ],
      );
    }

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(tokens.spacing.gap),
        child: HibikiPlaceholderMessage(
          icon: Icons.search_off,
          message: t.no_search_results,
          iconSize: 20,
          messageStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, Color fillColor) {
    Widget body = _buildBody(context, fillColor);
    if (overlayWidget != null) {
      body = Stack(
        children: [
          body,
          Positioned.fill(child: overlayWidget!),
        ],
      );
    }

    if (headerWidget != null) {
      return Column(
        children: [
          headerWidget!,
          Expanded(child: body),
        ],
      );
    }

    return body;
  }
}
