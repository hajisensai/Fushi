import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/utils/misc/popup_channel.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki/utils.dart';

class PopupDictionaryPage extends ConsumerStatefulWidget {
  const PopupDictionaryPage({
    required this.searchTerm,
    this.closeInApp,
    this.autoSearchOnOpen = true,
    super.key,
  });

  final String searchTerm;
  final VoidCallback? closeInApp;
  final bool autoSearchOnOpen;

  @override
  ConsumerState<PopupDictionaryPage> createState() =>
      _PopupDictionaryPageState();
}

class _PopupDictionaryPageState extends ConsumerState<PopupDictionaryPage>
    with DictionaryPageMixin {
  final DictionaryPopupController _popup =
      DictionaryPopupController(lowMemory: false);
  bool _isClosing = false;

  late final TextEditingController _searchController;
  final FocusNode _searchFocusNode = FocusNode();

  AppModel get appModel => ref.read(appProvider);

  @override
  AppModel get mixinAppModel => appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.searchTerm);
    if (widget.autoSearchOnOpen && appModel.isInitialised) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _pushSearch(widget.searchTerm, Rect.zero);
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    // TODO-058：弹窗 controller 现持有挂起层兜底 Timer，dispose 取消防泄漏。
    _popup.dispose();
    super.dispose();
  }

  Future<void> _pushSearch(String query, Rect selectionRect) {
    return pushNestedPopup(
      query: query,
      selectionRect: selectionRect,
      controller: _popup,
      autoRead: true,
      // 独立查词窗是整窗卡片（非贴选区小浮卡），搜索期保持卡片显示、空白由
      // DictionaryPopupLayer 的加载盖板兜住——不走「搜索期隐藏 + anchored 占位卡」。
      revealWhileSearching: true,
    );
  }

  void _popAt(int index) {
    if (index <= 0) return;
    popNestedPopupAt(index, _popup);
  }

  Future<void> _close() async {
    if (_isClosing) return;
    _isClosing = true;
    final VoidCallback? closeInApp = widget.closeInApp;
    if (closeInApp != null) {
      closeInApp();
      return;
    }
    await PopupChannel.instance.finishPopup();
  }

  void _onSearchSubmit(String text) {
    if (text.trim().isEmpty) return;
    _searchFocusNode.unfocus();
    setState(_popup.clear);
    _pushSearch(text.trim(), Rect.zero);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_popup.entries.length > 1) {
          _popAt(_popup.entries.length - 1);
        } else {
          _close();
        }
      },
      child: HibikiOverlayScaffold(
        // 根因修复（BUG-054）：弹窗词典窗口经 popup_main 同样套了 HibikiAppUiScale，
        // 其 DictionaryPopupLayer→DictionaryPopupWebView 会被 FittedBox 拉糊。整页在
        // 中和器下渲染（净缩放=1），WebView 走原生密度、其上的关闭遮罩/嵌套层共用
        // 同一真实坐标系。
        body: HibikiAppUiScaleNeutralizer(
          child: _buildOuterContainer(),
        ),
      ),
    );
  }

  Widget _buildOuterContainer() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    return Stack(
      children: <Widget>[
        // 透明背景：点击卡片外部关闭弹窗（背后是触发查词的其它 app 画面）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
            child: const SizedBox.expand(),
          ),
        ),
        // 贴顶部的浮动卡片，外观对齐书内查词弹窗（圆角 + 边框 + 横滑关闭）。
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
    );
  }

  Widget _buildCard(HibikiDesignTokens tokens) {
    final Widget card = HibikiPopupSurface(
      color: appModel.overrideDictionaryColor ?? tokens.surfaces.page,
      child: Column(
        children: [
          _buildSearchBar(),
          Divider(height: 1, thickness: 1, color: tokens.surfaces.outline),
          Expanded(child: _buildStack(context)),
        ],
      ),
    );
    // 基础层（栈深 1）用整卡横滑关闭窗口；一旦下钻到嵌套层，外层横滑必须停用——
    // SwipeDismissWrapper 基于 Listener，指针移动会同时派发到所有祖先 Listener，
    // 外层若仍在，横滑嵌套层会连带平移整张卡片（BUG-051 的第二症状）。
    // 嵌套层各自持有横滑（仅返回上一层），故此处只在基础层套外层横滑。
    // TODO-407②：平台/偏好禁用滑动关闭时（Windows/Linux 默认）整卡也不挂横滑，
    // 用搜索栏的关闭按钮兜底。
    if (_popup.entries.length > 1 ||
        !ReaderHibikiSource.instance.enableSwipeToClose) {
      return card;
    }
    return SwipeDismissWrapper(
      sensitivity: ReaderHibikiSource.instance.dismissSwipeSensitivity,
      onDismiss: _close,
      child: card,
    );
  }

  Widget _buildSearchBar() {
    return PopupDictionarySearchBar(
      controller: _searchController,
      focusNode: _searchFocusNode,
      onClose: widget.closeInApp == null ? null : _close,
      onSubmit: _onSearchSubmit,
    );
  }

  Widget _buildStack(BuildContext context) {
    if (_popup.entries.isEmpty) return const SizedBox.shrink();

    return Stack(
      children: [
        for (int i = 0; i < _popup.entries.length; i++) _buildLayer(context, i),
      ],
    );
  }

  /// app 外查词窗口本身已是一张约束卡片，下钻层不再用「贴选区的小浮卡」
  /// （那是全屏阅读器内 `buildNestedPopupLayer` 的语义，套进小卡里会被压成小窗），
  /// 而是与基础层一样满卡渲染、不透明覆盖下层（BUG-051 的第一症状）。
  /// 基础层（index 0）透明、横滑交由整卡外层；嵌套层不透明、自带横滑返回上一层。
  Widget _buildLayer(BuildContext context, int index) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final DictionaryPopupEntry entry = _popup.entries[index];
    final bool isBase = index == 0;
    final bool isDark =
        (appModel.overrideDictionaryTheme ?? Theme.of(context)).brightness ==
            Brightness.dark;
    return Positioned.fill(
      child: DictionaryPopupLayer(
        result: entry.result,
        isSearching: entry.isSearching,
        webViewKey: entry.webViewKey,
        isDark: isDark,
        showBorder: false,
        swipeDismissible: !isBase,
        enableSwipeToClose: ReaderHibikiSource.instance.enableSwipeToClose,
        overrideFillColor: isBase
            ? Colors.transparent
            : (appModel.overrideDictionaryColor ?? tokens.surfaces.page),
        onDismiss: isBase ? _close : () => _popAt(index),
        onTapOutside: isBase ? _close : () => _popAt(index),
        onScrolledToBottom: entry.allLoaded
            ? null
            : () => loadMoreForEntry(entry: entry, controller: _popup),
        onTextSelected: (text, localRect) {
          if (_popup.entries.length > index + 1) {
            setState(() => _popup.truncateTo(index + 1));
          }
          _pushSearch(text, localRect);
        },
        onLinkClick: (query, localRect) {
          if (_popup.entries.length > index + 1) {
            setState(() => _popup.truncateTo(index + 1));
          }
          _pushSearch(query, localRect);
        },
        onMineEntry: onMineEntry,
        onUpdateEntry: onUpdateEntry,
        onDuplicateCheck: checkDuplicate,
      ),
    );
  }
}

class PopupDictionarySearchBar extends StatelessWidget {
  const PopupDictionarySearchBar({
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    this.onClose,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmit;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return HibikiCompactSearchRow(
      controller: controller,
      focusNode: focusNode,
      hintText: t.search,
      onSubmit: onSubmit,
      onClose: onClose,
      closeButtonKey: const ValueKey<String>('popup_dictionary_close_button'),
      fieldKey: const ValueKey<String>('popup_dictionary_search_field'),
      searchButtonKey: const ValueKey<String>('popup_dictionary_search_button'),
    );
  }
}
