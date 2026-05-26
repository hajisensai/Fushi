// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/utils.dart';

class HibikiTextSelectionControls extends MaterialTextSelectionControls {
  HibikiTextSelectionControls({
    this.stashAction,
    required this.shareAction,
    required this.allowCopy,
    required this.allowCut,
    required this.allowPaste,
    required this.allowSelectAll,
    this.searchAction,
    this.handleColor,
  });

  final Color? handleColor;

  final TextSelectionControls _controls = Platform.isIOS
      ? cupertinoTextSelectionControls
      : materialTextSelectionControls;

  final Function(String)? searchAction;
  final Function(String) shareAction;
  final Function(String)? stashAction;

  final bool allowCopy;
  final bool allowCut;
  final bool allowPaste;
  final bool allowSelectAll;

  static const double _kToolbarContentDistanceBelow = 20;
  static const double _kToolbarContentDistance = 8;

  Widget _wrapWithThemeData(
          Widget Function(BuildContext) builder) =>
      Platform.isIOS
          ? CupertinoTheme(
              data: CupertinoThemeData(primaryColor: handleColor),
              child: Builder(builder: builder))
          : TextSelectionTheme(
              data: TextSelectionThemeData(selectionHandleColor: handleColor),
              child: Builder(builder: builder));

  @override
  Widget buildHandle(
          BuildContext context, TextSelectionHandleType type, double textHeight,
          [VoidCallback? onTap]) =>
      _wrapWithThemeData(
          (context) => _controls.buildHandle(context, type, textHeight, onTap));

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) {
    return _controls.getHandleAnchor(type, textLineHeight);
  }

  @override
  Size getHandleSize(double textLineHeight) {
    return _controls.getHandleSize(textLineHeight);
  }

  @override
  Widget buildToolbar(
    BuildContext context,
    Rect globalEditableRegion,
    double textLineHeight,
    Offset selectionMidpoint,
    List<TextSelectionPoint> endpoints,
    TextSelectionDelegate delegate,
    ValueListenable<ClipboardStatus>? clipboardStatus,
    Offset? lastSecondaryTapDownPosition,
  ) {
    final TextSelectionPoint startTextSelectionPoint = endpoints[0];
    final TextSelectionPoint endTextSelectionPoint =
        endpoints.length > 1 ? endpoints[1] : endpoints[0];
    final double midX = globalEditableRegion.left + selectionMidpoint.dx;
    final double rawAboveY = globalEditableRegion.top +
        startTextSelectionPoint.point.dy -
        textLineHeight -
        _kToolbarContentDistance;
    final double rawBelowY = globalEditableRegion.top +
        endTextSelectionPoint.point.dy +
        _kToolbarContentDistanceBelow;

    final MediaQueryData mq = MediaQuery.of(context);
    final double topPad = mq.padding.top + kToolbarHeight;
    final double bottomPad = mq.size.height - mq.padding.bottom;
    final Offset anchorAbove = Offset(
      midX.clamp(0, mq.size.width),
      rawAboveY.clamp(topPad, bottomPad),
    );
    final Offset anchorBelow = Offset(
      midX.clamp(0, mq.size.width),
      rawBelowY.clamp(topPad, bottomPad),
    );

    String selectedText() => delegate.textEditingValue.selection
        .textInside(delegate.textEditingValue.text);

    return _HibikiSelectionToolbar(
      anchorAbove: anchorAbove,
      anchorBelow: anchorBelow,
      clipboardStatus: clipboardStatus,
      searchAction: (searchAction != null)
          ? () {
              searchAction?.call(selectedText());
              delegate.hideToolbar();
            }
          : null,
      stashAction: (stashAction != null)
          ? () {
              stashAction?.call(selectedText());
              delegate.hideToolbar();
            }
          : null,
      shareAction: () {
        shareAction(selectedText());
        delegate.hideToolbar();
      },
      handleCopy:
          canCopy(delegate) && allowCopy ? () => handleCopy(delegate) : null,
      handleCut:
          canCut(delegate) && allowCut ? () => handleCut(delegate) : null,
      handlePaste:
          canPaste(delegate) && allowPaste ? () => handlePaste(delegate) : null,
      handleSelectAll: canSelectAll(delegate) && allowSelectAll
          ? () => handleSelectAll(delegate)
          : null,
    );
  }
}

class _HibikiSelectionToolbar extends StatefulWidget {
  const _HibikiSelectionToolbar({
    required this.anchorAbove,
    required this.anchorBelow,
    required this.clipboardStatus,
    required this.searchAction,
    this.stashAction,
    required this.shareAction,
    required this.handleCopy,
    required this.handleCut,
    required this.handlePaste,
    required this.handleSelectAll,
  });

  final Offset anchorAbove;
  final Offset anchorBelow;
  final ValueListenable<ClipboardStatus>? clipboardStatus;
  final VoidCallback? searchAction;
  final VoidCallback? stashAction;
  final VoidCallback shareAction;
  final VoidCallback? handleCopy;
  final VoidCallback? handleCut;
  final VoidCallback? handlePaste;
  final VoidCallback? handleSelectAll;

  @override
  State<_HibikiSelectionToolbar> createState() =>
      _HibikiSelectionToolbarState();
}

class _HibikiSelectionToolbarState extends State<_HibikiSelectionToolbar> {
  void _onChangedClipboardStatus() {
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.clipboardStatus?.addListener(_onChangedClipboardStatus);
  }

  @override
  void didUpdateWidget(_HibikiSelectionToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.clipboardStatus != oldWidget.clipboardStatus) {
      widget.clipboardStatus?.addListener(_onChangedClipboardStatus);
      oldWidget.clipboardStatus?.removeListener(_onChangedClipboardStatus);
    }
  }

  @override
  void dispose() {
    widget.clipboardStatus?.removeListener(_onChangedClipboardStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    assert(debugCheckHasMaterialLocalizations(context), 'Must have i18n');
    final MaterialLocalizations loc = MaterialLocalizations.of(context);

    final List<_ItemData> primaryItems = <_ItemData>[
      if (widget.handleCopy != null)
        _ItemData(label: loc.copyButtonLabel, onPressed: widget.handleCopy),
      if (widget.searchAction != null)
        _ItemData(label: t.search, onPressed: widget.searchAction),
      if (widget.stashAction != null)
        _ItemData(label: t.stash, onPressed: widget.stashAction),
    ];

    final List<_ItemData> overflowItems = <_ItemData>[
      if (widget.handleSelectAll != null)
        _ItemData(
            label: loc.selectAllButtonLabel, onPressed: widget.handleSelectAll),
      _ItemData(label: t.share, onPressed: widget.shareAction),
      if (widget.handleCut != null)
        _ItemData(label: loc.cutButtonLabel, onPressed: widget.handleCut),
      if (widget.handlePaste != null &&
          widget.clipboardStatus?.value == ClipboardStatus.pasteable)
        _ItemData(label: loc.pasteButtonLabel, onPressed: widget.handlePaste),
    ];

    final int totalCount =
        primaryItems.length + (overflowItems.isNotEmpty ? 1 : 0);
    int childIndex = 0;
    return TextSelectionToolbar(
      anchorAbove: widget.anchorAbove,
      anchorBelow: widget.anchorBelow,
      toolbarBuilder: (context, child) => HibikiCard(
        padding: EdgeInsets.zero,
        child: child,
      ),
      children: [
        ...primaryItems.map((item) {
          return TextSelectionToolbarTextButton(
            padding: TextSelectionToolbarTextButton.getPadding(
                childIndex++, totalCount),
            onPressed: item.onPressed,
            child: Text(item.label),
          );
        }),
        if (overflowItems.isNotEmpty)
          HibikiOverflowMenu<int>(
            iconSize: 20,
            onSelected: (i) => overflowItems[i].onPressed?.call(),
            items: [
              for (int i = 0; i < overflowItems.length; i++)
                PopupMenuItem<int>(
                    value: i, child: Text(overflowItems[i].label)),
            ],
          ),
      ],
    );
  }
}

class _ItemData {
  const _ItemData({required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;
}
