import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';
import 'package:hibiki/utils.dart';

/// 桌面剪贴板查词 overlay：订阅 [DesktopLookupService.pendingText]，
/// 剪贴板文本进来即**自动查词**，用与正式查词窗一致的 [DictionaryPopupLayer]
/// （popup.js / DictionaryPopupWebView）渲染，顶部带可编辑搜索框可改查。
///
/// 挂在首页根 Stack 顶层。平时（pendingText==null）build 返回 [SizedBox.shrink]，
/// 不占布局、不影响任何 tab（尤其视频）；只有剪贴板触发时才浮在最上层。
class DesktopLookupOverlay extends ConsumerStatefulWidget {
  const DesktopLookupOverlay({super.key});
  @override
  ConsumerState<DesktopLookupOverlay> createState() =>
      _DesktopLookupOverlayState();
}

class _DesktopLookupOverlayState extends ConsumerState<DesktopLookupOverlay>
    with DictionaryPageMixin {
  final List<DictionaryPopupEntry> _stack = <DictionaryPopupEntry>[];
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  /// 已对哪一段剪贴板文本触发过自动查词，避免重复 build 时反复重查。
  String? _searchedText;

  @override
  AppModel get mixinAppModel => ref.read(appProvider);
  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  void initState() {
    super.initState();
    DesktopLookupService.instance.addListener(_onPending);
  }

  @override
  void dispose() {
    DesktopLookupService.instance.removeListener(_onPending);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onPending() {
    if (mounted) setState(() {});
  }

  void _close() {
    setState(() {
      _stack.clear();
      _searchedText = null;
    });
    DesktopLookupService.instance.clearPending();
  }

  Future<void> _pushSearch(String query, Rect selectionRect) {
    return pushNestedPopup(
      query: query,
      selectionRect: selectionRect,
      popupStack: _stack,
      autoRead: true,
    );
  }

  void _popAt(int index) {
    if (index <= 0) return;
    popNestedPopupAt(index, _stack);
  }

  void _onSearchSubmit(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _searchFocusNode.unfocus();
    setState(_stack.clear);
    _pushSearch(trimmed, Rect.zero);
  }

  /// 新剪贴板文本到达后初始化搜索框并自动查词（每段文本只触发一次）。
  void _maybeAutoSearch(String text) {
    if (_searchedText == text) return;
    _searchedText = text;
    _searchController.text = text;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!mixinAppModel.isInitialised) return;
      setState(_stack.clear);
      _pushSearch(text, Rect.zero);
    });
  }

  @override
  Widget build(BuildContext context) {
    final String? text = DesktopLookupService.instance.pendingText;
    // 平时完全不占布局、不参与任何 tab 的渲染。
    if (text == null) return const SizedBox.shrink();
    _maybeAutoSearch(text);

    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    // 整块在中和器下渲染（净缩放=1），与正式查词窗一致：WebView 走原生密度，
    // 关闭遮罩 / 嵌套层共用同一真实坐标系。
    return HibikiAppUiScaleNeutralizer(
      child: Stack(
        children: <Widget>[
          // 透明背景：点卡片外部关闭。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const SizedBox.expand(),
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: LayoutBuilder(
              builder: (context, constraints) {
                const double maxCardWidth = 480;
                final double available = constraints.maxWidth - gap * 2;
                final double width =
                    available < maxCardWidth ? available : maxCardWidth;
                final double height = (constraints.maxHeight - gap * 2) * 0.72;
                return Padding(
                  padding: EdgeInsets.all(gap),
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: _buildCard(tokens),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(HibikiDesignTokens tokens) {
    return HibikiPopupSurface(
      color: mixinAppModel.overrideDictionaryColor ?? tokens.surfaces.page,
      child: Column(
        children: <Widget>[
          PopupDictionarySearchBar(
            controller: _searchController,
            focusNode: _searchFocusNode,
            onClose: _close,
            onSubmit: _onSearchSubmit,
          ),
          Divider(height: 1, thickness: 1, color: tokens.surfaces.outline),
          Expanded(child: _buildStack(tokens)),
        ],
      ),
    );
  }

  Widget _buildStack(HibikiDesignTokens tokens) {
    if (_stack.isEmpty) return const SizedBox.shrink();
    return Stack(
      children: <Widget>[
        for (int i = 0; i < _stack.length; i++) _buildLayer(i, tokens),
      ],
    );
  }

  /// app 外查词窗口本身已是一张约束卡片：每层满卡渲染、不透明覆盖下层
  /// （对齐 popup_dictionary_page 的下钻语义，而非全屏阅读器贴选区小浮卡）。
  Widget _buildLayer(int index, HibikiDesignTokens tokens) {
    final DictionaryPopupEntry entry = _stack[index];
    final bool isBase = index == 0;
    final bool isDark =
        (mixinAppModel.overrideDictionaryTheme ?? Theme.of(context))
                .brightness ==
            Brightness.dark;
    return Positioned.fill(
      child: DictionaryPopupLayer(
        result: entry.result,
        isSearching: entry.isSearching,
        webViewKey: entry.webViewKey,
        isDark: isDark,
        showBorder: false,
        swipeDismissible: !isBase,
        overrideFillColor: isBase
            ? Colors.transparent
            : (mixinAppModel.overrideDictionaryColor ?? tokens.surfaces.page),
        onDismiss: isBase ? _close : () => _popAt(index),
        onTapOutside: isBase ? _close : () => _popAt(index),
        onScrolledToBottom: entry.allLoaded
            ? null
            : () => loadMoreForEntry(entry: entry, popupStack: _stack),
        onTextSelected: (text, localRect) {
          if (_stack.length > index + 1) {
            setState(() => _stack.removeRange(index + 1, _stack.length));
          }
          _pushSearch(text, localRect);
        },
        onLinkClick: (query, localRect) {
          if (_stack.length > index + 1) {
            setState(() => _stack.removeRange(index + 1, _stack.length));
          }
          _pushSearch(query, localRect);
        },
        onMineEntry: onMineEntry,
        onDuplicateCheck: checkDuplicate,
        onFavoriteEntry: onFavoriteEntry,
        onFavoriteCheck: onFavoriteCheck,
      ),
    );
  }
}
