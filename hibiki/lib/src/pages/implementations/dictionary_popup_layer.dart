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
  final double width = availableWidth;
  // 高度直接用 availableHeight（已按 maxHeight 与屏幕可用空间双重 clamp）。
  // 旧实现额外乘 0.5 把高度顶死在半屏，使「弹窗最大高度」设置在半屏以上失效；
  // 去掉后高度设置真正说了算，最高可拉到接近整屏（减边距）。
  double height = availableHeight;

  final double minLeft = horizontalInset;
  final double maxLeft = screen.width - width - horizontalInset;
  final double minTop = effectiveTop + verticalInset;
  final double maxBottom = effectiveBottom - verticalInset;
  final double maxRight = screen.width - horizontalInset;

  const double gap = 4.0;

  if (verticalWriting) {
    // 竖排 vertical-rl：右→左读，右侧是已读列。优先把弹窗贴当前列右侧（盖已读、
    // 不挡左边还没读的下一列）；右侧放不下才退到左侧。竖直方向锚到选区顶端往下铺，
    // 与列并排——不与 selectionRect 水平重叠即不压当前列。
    double width = availableWidth;
    double height = availableHeight;
    final double roomRight = maxRight - (selectionRect.right + gap);
    final double roomLeft = (selectionRect.left - gap) - minLeft;
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

    final double maxTopV = (maxBottom - height).clamp(minTop, maxBottom);
    final double top = selectionRect.top.clamp(minTop, maxTopV);
    return Rect.fromLTWH(left, top, width, height);
  }

  // BUG-098: the popup must never cover the looked-up word. Place it flush
  // against the selection (above or below) and, when neither side fits the full
  // height, pick the side with more room and shrink the popup to that room —
  // so its rect never overlaps [selectionRect]. The old `top.clamp(maxTop)`
  // pulled a too-tall "below" popup back up over the selection.
  final double roomBelow = maxBottom - (selectionRect.bottom + gap);
  final double roomAbove = (selectionRect.top - gap) - minTop;
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
  final double maxTop = (maxBottom - height).clamp(minTop, maxBottom);
  top = top.clamp(minTop, maxTop);

  double left = selectionRect.left;
  left = left.clamp(minLeft, maxLeft);

  return Rect.fromLTWH(left, top, width, height);
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
    this.onFavoriteEntry,
    this.onFavoriteCheck,
    this.isSearching = false,
    this.keepWebViewWarm = false,
    this.onTapOutside,
    this.onScrolledToBottom,
    this.onRendered,
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
  final Future<bool> Function(Map<String, String> fields) onMineEntry;
  final Future<bool> Function(String expression, String reading)
      onDuplicateCheck;
  final Future<bool> Function(Map<String, String> fields)? onFavoriteEntry;
  final Future<bool> Function(String expression, String reading)?
      onFavoriteCheck;
  final VoidCallback? onTapOutside;
  final VoidCallback? onScrolledToBottom;
  final VoidCallback? onRendered;
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
            onDuplicateCheck: onDuplicateCheck,
            onFavoriteEntry: onFavoriteEntry,
            onFavoriteCheck: onFavoriteCheck,
            onScrolledToBottom: onScrolledToBottom,
            onRendered: onRendered,
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
