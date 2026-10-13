// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/utils.dart';

class FushiTextSelectionControls extends MaterialTextSelectionControls {
  FushiTextSelectionControls({
    this.stashAction,
    required this.shareAction,
    required this.allowCopy,
    required this.allowCut,
    required this.allowPaste,
    required this.allowSelectAll,
    this.searchAction,
    this.handleColor,
    this.glassDesign,
  });

  final Color? handleColor;

  /// 在构造期钉死设计系统。
  ///
  /// 框架的 [getHandleSize] / [getHandleAnchor] 没有 context，且
  /// `_SelectionHandleOverlay` 先用它们算出拖拽命中区与锚点、再调 [buildHandle]，
  /// 所以 handle 的风格不能等到 [buildHandle] 才按 context 决定——否则画出的
  /// Cupertino handle 会落在 Material 几何的命中区里。调用方在有 context 的地方传
  /// `isGlassDesign(context)`：true = Apple（Cupertino handle + Cupertino 工具条），
  /// false = MD3。为 null 时 handle 维持原平台默认，工具条仍按 [buildToolbar] 的
  /// context 走 [isGlassDesign]。
  final bool? glassDesign;

  final TextSelectionControls _platformControls = Platform.isIOS
      ? cupertinoTextSelectionControls
      : materialTextSelectionControls;

  /// handle 的几何与外观来源：Apple 一律用 iOS 的 Cupertino handle（handle 只在
  /// 触屏选区时出现，macOS / 桌面触屏同样适用），MD3 维持原平台默认。
  TextSelectionControls get _controls =>
      glassDesign == true ? cupertinoTextSelectionControls : _platformControls;

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
    BuildContext context,
    Widget Function(BuildContext) builder,
  ) => glassDesign == true
      ? _wrapWithAppleTheme(context, builder)
      : Platform.isIOS
      ? CupertinoTheme(
          data: CupertinoThemeData(primaryColor: handleColor),
          child: Builder(builder: builder),
        )
      : TextSelectionTheme(
          data: TextSelectionThemeData(selectionHandleColor: handleColor),
          child: Builder(builder: builder),
        );

  /// Apple：继承外层 Cupertino 主题，只覆盖 handle 色（未指定时跟随 Apple 强调色，
  /// 与 iOS 系统选区 handle 同色）。
  Widget _wrapWithAppleTheme(
    BuildContext context,
    Widget Function(BuildContext) builder,
  ) {
    final Color color = handleColor ?? appleColorsOf(context).accent;
    return CupertinoTheme(
      data: CupertinoTheme.of(
        context,
      ).copyWith(primaryColor: color, selectionHandleColor: color),
      child: Builder(builder: builder),
    );
  }

  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textHeight, [
    VoidCallback? onTap,
  ]) => _wrapWithThemeData(
    context,
    (context) => _controls.buildHandle(context, type, textHeight, onTap),
  );

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
    final TextSelectionPoint endTextSelectionPoint = endpoints.length > 1
        ? endpoints[1]
        : endpoints[0];
    final double midX = globalEditableRegion.left + selectionMidpoint.dx;
    final double rawAboveY =
        globalEditableRegion.top +
        startTextSelectionPoint.point.dy -
        textLineHeight -
        _kToolbarContentDistance;
    final double rawBelowY =
        globalEditableRegion.top +
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

    String selectedText() => delegate.textEditingValue.selection.textInside(
      delegate.textEditingValue.text,
    );

    return _FushiSelectionToolbar(
      glassDesign: glassDesign ?? isGlassDesign(context),
      anchorAbove: anchorAbove,
      anchorBelow: anchorBelow,
      lastSecondaryTapDownPosition: lastSecondaryTapDownPosition,
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
      handleCopy: canCopy(delegate) && allowCopy
          ? () => handleCopy(delegate)
          : null,
      handleCut: canCut(delegate) && allowCut
          ? () => handleCut(delegate)
          : null,
      handlePaste: canPaste(delegate) && allowPaste
          ? () => handlePaste(delegate)
          : null,
      handleSelectAll: canSelectAll(delegate) && allowSelectAll
          ? () => handleSelectAll(delegate)
          : null,
    );
  }
}

class _FushiSelectionToolbar extends StatefulWidget {
  const _FushiSelectionToolbar({
    required this.glassDesign,
    required this.anchorAbove,
    required this.anchorBelow,
    required this.lastSecondaryTapDownPosition,
    required this.clipboardStatus,
    required this.searchAction,
    this.stashAction,
    required this.shareAction,
    required this.handleCopy,
    required this.handleCut,
    required this.handlePaste,
    required this.handleSelectAll,
  });

  /// true = Apple（iOS 26 / macOS 26 编辑菜单），false = MD3 浮动工具条。
  final bool glassDesign;
  final Offset anchorAbove;
  final Offset anchorBelow;

  /// 桌面右键位置：macOS 的编辑菜单在指针处弹出，而不是选区上方。
  final Offset? lastSecondaryTapDownPosition;
  final ValueListenable<ClipboardStatus>? clipboardStatus;
  final VoidCallback? searchAction;
  final VoidCallback? stashAction;
  final VoidCallback shareAction;
  final VoidCallback? handleCopy;
  final VoidCallback? handleCut;
  final VoidCallback? handlePaste;
  final VoidCallback? handleSelectAll;

  @override
  State<_FushiSelectionToolbar> createState() => _FushiSelectionToolbarState();
}

class _FushiSelectionToolbarState extends State<_FushiSelectionToolbar> {
  void _onChangedClipboardStatus() {
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.clipboardStatus?.addListener(_onChangedClipboardStatus);
  }

  @override
  void didUpdateWidget(_FushiSelectionToolbar oldWidget) {
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

  /// 菜单项的唯一来源：主项（复制 / 查词 / 暂存）+ 次项（全选 / 分享 / 剪切 /
  /// 粘贴）。两套设计系统共用同一份顺序与回调，只换呈现。
  _MenuItems _items({
    required String copyLabel,
    required String cutLabel,
    required String pasteLabel,
    required String selectAllLabel,
  }) {
    final List<_ItemData> primaryItems = <_ItemData>[
      if (widget.handleCopy != null)
        _ItemData(label: copyLabel, onPressed: widget.handleCopy),
      if (widget.searchAction != null)
        _ItemData(label: t.search, onPressed: widget.searchAction),
      if (widget.stashAction != null)
        _ItemData(label: t.stash, onPressed: widget.stashAction),
    ];

    final List<_ItemData> overflowItems = <_ItemData>[
      if (widget.handleSelectAll != null)
        _ItemData(label: selectAllLabel, onPressed: widget.handleSelectAll),
      _ItemData(label: t.share, onPressed: widget.shareAction),
      if (widget.handleCut != null)
        _ItemData(label: cutLabel, onPressed: widget.handleCut),
      if (widget.handlePaste != null &&
          widget.clipboardStatus?.value == ClipboardStatus.pasteable)
        _ItemData(label: pasteLabel, onPressed: widget.handlePaste),
    ];
    return _MenuItems(primary: primaryItems, overflow: overflowItems);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.glassDesign) return _buildApple(context);
    return _buildMaterial(context);
  }

  /// Apple：iOS 26 编辑菜单是一条平铺的文字按钮胶囊（放不下时由
  /// [CupertinoTextSelectionToolbar] 自己分页加箭头，没有「⋯」溢出）；
  /// macOS 26（及 Apple 设计下的其它桌面）是指针处弹出的纵向上下文菜单。
  /// 按压反馈用 Cupertino 的按压高亮，不画 Material 水波纹。
  Widget _buildApple(BuildContext context) {
    final CupertinoLocalizations loc = CupertinoLocalizations.of(context);
    final _MenuItems items = _items(
      copyLabel: loc.copyButtonLabel,
      cutLabel: loc.cutButtonLabel,
      pasteLabel: loc.pasteButtonLabel,
      selectAllLabel: loc.selectAllButtonLabel,
    );
    final List<_ItemData> all = <_ItemData>[
      ...items.primary,
      ...items.overflow,
    ];

    switch (Theme.of(context).platform) {
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return CupertinoDesktopTextSelectionToolbar(
          anchor: widget.lastSecondaryTapDownPosition ?? widget.anchorAbove,
          children: <Widget>[
            for (final _ItemData item in all)
              CupertinoDesktopTextSelectionToolbarButton.text(
                onPressed: item.onPressed,
                text: item.label,
              ),
          ],
        );
      case TargetPlatform.iOS:
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        return CupertinoTextSelectionToolbar(
          anchorAbove: widget.anchorAbove,
          anchorBelow: widget.anchorBelow,
          children: <Widget>[
            for (final _ItemData item in all)
              CupertinoTextSelectionToolbarButton.text(
                onPressed: item.onPressed,
                text: item.label,
              ),
          ],
        );
    }
  }

  Widget _buildMaterial(BuildContext context) {
    assert(debugCheckHasMaterialLocalizations(context), 'Must have i18n');
    final MaterialLocalizations loc = MaterialLocalizations.of(context);

    final _MenuItems items = _items(
      copyLabel: loc.copyButtonLabel,
      cutLabel: loc.cutButtonLabel,
      pasteLabel: loc.pasteButtonLabel,
      selectAllLabel: loc.selectAllButtonLabel,
    );
    final List<_ItemData> primaryItems = items.primary;
    final List<_ItemData> overflowItems = items.overflow;

    final int totalCount =
        primaryItems.length + (overflowItems.isNotEmpty ? 1 : 0);
    int childIndex = 0;
    return TextSelectionToolbar(
      anchorAbove: widget.anchorAbove,
      anchorBelow: widget.anchorBelow,
      // 选区工具条是浮在内容上的控件层：MD3 = M3E 浮动工具条（浮层面全胶囊，
      // 与 floating toolbar 同一形状语言）。Apple 走 [_buildApple]。
      toolbarBuilder: (context, child) => FushiPopupSurface(
        borderRadius: const BorderRadius.all(Radius.circular(22)),
        child: child,
      ),
      children: [
        ...primaryItems.map((item) {
          return TextSelectionToolbarTextButton(
            padding: TextSelectionToolbarTextButton.getPadding(
              childIndex++,
              totalCount,
            ),
            onPressed: item.onPressed,
            child: Text(item.label),
          );
        }),
        if (overflowItems.isNotEmpty)
          FushiOverflowMenu<int>(
            iconSize: 20,
            onSelected: (i) => overflowItems[i].onPressed?.call(),
            items: [
              for (int i = 0; i < overflowItems.length; i++)
                FushiPopupMenuItem<int>(
                  label: overflowItems[i].label,
                  value: i,
                ),
            ],
          ),
      ],
    );
  }
}

class _MenuItems {
  const _MenuItems({required this.primary, required this.overflow});
  final List<_ItemData> primary;
  final List<_ItemData> overflow;
}

class _ItemData {
  const _ItemData({required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;
}
