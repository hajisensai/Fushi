import 'package:flutter/material.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/src/media/sources/reader_ttu_source.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki/utils.dart';

Rect calcPopupPosition({
  required Rect selectionRect,
  required Size screen,
  double padding = 6.0,
  double maxWidth = 360.0,
  double maxHeight = 480.0,
}) {
  final double width = (screen.width - padding * 2).clamp(0, maxWidth);
  final double height = (screen.height * 0.5).clamp(0, maxHeight);

  final double spaceBelow = screen.height - selectionRect.bottom - padding;
  final double spaceAbove = selectionRect.top - padding;
  final bool showBelow = spaceBelow >= height || spaceBelow >= spaceAbove;

  double top;
  if (showBelow) {
    top = selectionRect.bottom + 4;
  } else {
    top = selectionRect.top - 4 - height;
  }
  top = top.clamp(padding, screen.height - height - padding);

  double left = selectionRect.left;
  left = left.clamp(padding, screen.width - width - padding);

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
    this.onTapOutside,
    this.headerWidget,
    this.overlayWidget,
    this.isDark = false,
    super.key,
  });

  final DictionarySearchResult? result;
  final GlobalKey<DictionaryPopupWebViewState> webViewKey;
  final VoidCallback onDismiss;
  final void Function(String text, Rect localRect) onTextSelected;
  final void Function(String query, Rect localRect) onLinkClick;
  final Future<bool> Function(Map<String, String> fields) onMineEntry;
  final Future<bool> Function(String expression, String reading)
      onDuplicateCheck;
  final VoidCallback? onTapOutside;
  final Widget? headerWidget;
  final Widget? overlayWidget;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final fillColor = isDark ? Colors.black : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.18);

    return SwipeDismissWrapper(
      sensitivity: ReaderTtuSource.instance.dismissSwipeSensitivity,
      onDismiss: onDismiss,
      child: Container(
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: _buildContent(),
      ),
    );
  }

  Widget _buildBody() {
    if (result == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (result!.entries.isEmpty) {
      return Center(
        child: JidoujishoPlaceholderMessage(
          icon: Icons.search_off,
          message: t.no_search_results,
        ),
      );
    }

    return DictionaryPopupWebView(
      key: webViewKey,
      result: result!,
      onTapOutside: onTapOutside,
      onTextSelected: onTextSelected,
      onLinkClick: onLinkClick,
      onMineEntry: onMineEntry,
      onDuplicateCheck: onDuplicateCheck,
    );
  }

  Widget _buildContent() {
    Widget body = _buildBody();
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
