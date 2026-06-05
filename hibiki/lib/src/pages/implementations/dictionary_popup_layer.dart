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
  double maxHeight = 480.0,
  double bottomReserve = 0.0,
  double topReserve = 0.0,
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
  final double height = availableHeight;

  final double minLeft = horizontalInset;
  final double maxLeft = screen.width - width - horizontalInset;
  final double minTop = effectiveTop + verticalInset;
  final double maxTop = effectiveBottom - height - verticalInset;

  final double spaceBelow =
      effectiveBottom - selectionRect.bottom - verticalInset;
  final double spaceAbove = selectionRect.top - effectiveTop - verticalInset;
  final bool showBelow = spaceBelow >= height || spaceBelow >= spaceAbove;

  double top;
  if (showBelow) {
    top = selectionRect.bottom + 4;
  } else {
    top = selectionRect.top - 4 - height;
  }
  top = top.clamp(minTop, maxTop);

  double left = selectionRect.left;
  left = left.clamp(minLeft, maxLeft);

  return Rect.fromLTWH(left, top, width, height);
}

class DictionaryPopupLayer extends StatelessWidget {
  const DictionaryPopupLayer({
    required this.result,
    required this.webViewKey,
    required this.onDismiss,
    required this.onTextSelected,
    required this.onLinkClick,
    required this.onMineEntry,
    required this.onDuplicateCheck,
    this.isSearching = false,
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
  final GlobalKey<DictionaryPopupWebViewState> webViewKey;
  final VoidCallback onDismiss;
  final void Function(String text, Rect localRect) onTextSelected;
  final void Function(String query, Rect localRect) onLinkClick;
  final Future<bool> Function(Map<String, String> fields) onMineEntry;
  final Future<bool> Function(String expression, String reading)
      onDuplicateCheck;
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
      child: _buildContent(context),
    );

    if (!swipeDismissible) return content;

    return SwipeDismissWrapper(
      sensitivity: ReaderHibikiSource.instance.dismissSwipeSensitivity,
      onDismiss: onDismiss,
      child: content,
    );
  }

  Widget _buildBody(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    if (result != null && result!.entries.isNotEmpty) {
      return Stack(
        children: [
          DictionaryPopupWebView(
            key: webViewKey,
            result: result!,
            onTapOutside: onTapOutside,
            onTextSelected: onTextSelected,
            onLinkClick: onLinkClick,
            onMineEntry: onMineEntry,
            onDuplicateCheck: onDuplicateCheck,
            onScrolledToBottom: onScrolledToBottom,
            onRendered: onRendered,
          ),
          if (isSearching)
            Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: adaptiveIndicator(context: context, strokeWidth: 2.5),
              ),
            ),
        ],
      );
    }

    if (isSearching) {
      return Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: adaptiveIndicator(context: context, strokeWidth: 2.5),
        ),
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

  Widget _buildContent(BuildContext context) {
    Widget body = _buildBody(context);
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
