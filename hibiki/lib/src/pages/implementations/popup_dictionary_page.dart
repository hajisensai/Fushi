import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:hibiki/src/utils/misc/popup_channel.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki/utils.dart';

class PopupDictionaryPage extends ConsumerStatefulWidget {
  const PopupDictionaryPage({
    required this.searchTerm,
    this.searchGeneration = 0,
    this.anchorRect,
    this.subtitleWindowRect,
    this.closeInApp,
    this.autoSearchOnOpen = true,
    this.showSearchBar = true,
    super.key,
  });

  final String searchTerm;

  /// TODO-872：app 外悬浮字幕条点字传来的「被查字屏幕矩形」（逻辑像素，与本全屏查词
  /// 窗同坐标系）。非空 → 卡片贴被查字旁定位（[computeFloatingLyricPopupRect]）；为 null
  /// 即非悬浮字幕入口（系统 PROCESS_TEXT / hibiki://lookup）→ 保持原 [Alignment.topCenter]
  /// 贴顶。anchorRect 变化也纳入 [didUpdateWidget] 复用判定，让同一常驻热页连续点不同字
  /// 位置也跟着更新。
  final Rect? anchorRect;

  /// TODO-708 P1 ⑥：app 外悬浮字幕条「整条字幕窗屏幕矩形」（逻辑像素，与 [anchorRect]
  /// 同坐标系，已含状态栏平移）。非空时作为弹窗避让锚（超集，同时覆盖被查字与未点的
  /// 其它字），弹窗不遮整条字幕窗；为 null 时回退按 [anchorRect]（被查字单字）避让。
  /// 仅悬浮字幕入口带此值；其它入口（系统 PROCESS_TEXT / hibiki://lookup）恒 null。
  final Rect? subtitleWindowRect;

  /// TODO-951 症状C：app 外查词窗常驻不重建，宿主（popup_main）每次新 ProcessText
  /// 把递增的 generation 一并透传——即便是同一个词的连续查词，widget 配置也会变，
  /// [didUpdateWidget] 据此触发复用热槽的原地重查（消除 ValueKey 重建整页的闪烁）。
  final int searchGeneration;

  final VoidCallback? closeInApp;
  final bool autoSearchOnOpen;

  /// TODO-708 P3 ③：是否在卡片顶部显示搜索输入框（含搜索/关闭行）。默认 true——
  /// 系统 PROCESS_TEXT / 独立查词窗（hibiki://lookup）需要它重查任意词。悬浮字幕
  /// 「点字查词」入口（[popup_main] 构造 [anchorRect] != null 处）传 false，回到旧
  /// 「4.1」轻形态：点字直接出词卡、无搜索输入框；关闭按钮仍恒可用（独立渲染，不随
  /// 搜索栏隐藏）。源文本面板（[SourceLookupTextPanel]）不受此参数影响，保留点选重查。
  final bool showSearchBar;

  @override
  ConsumerState<PopupDictionaryPage> createState() =>
      _PopupDictionaryPageState();
}

class _PopupDictionaryPageState extends ConsumerState<PopupDictionaryPage>
    with DictionaryPageMixin {
  final DictionaryPopupController _popup = DictionaryPopupController(
    lowMemory: false,
    onLookupStackDepthChanged: recordLookupStackDepth,
  );
  final GlobalKey _resultStackKey = GlobalKey();
  final Stopwatch _startupStopwatch = Stopwatch()..start();
  bool _isClosing = false;
  String _sourceLookupText = '';

  late final TextEditingController _searchController;
  final FocusNode _searchFocusNode = FocusNode();

  AppModel get appModel => ref.read(appProvider);

  @override
  AppModel get mixinAppModel => appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  double get _dictionaryHeadwordScale {
    try {
      return appModel.dictionaryFontSize / appModel.defaultDictionaryFontSize;
    } on Object {
      return 1.0;
    }
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.searchTerm);
    _sourceLookupText = widget.searchTerm.trim();
    debugPrint('[popup-perf] init search="${widget.searchTerm}"');
    // TODO-951 症状C：开页 seed 一个常驻隐藏热槽，弹窗 WebView 冷加载一次后全程复用
    // （与 reader/video/首页查词同范式），消除「每次查词重建 WebView 露白屏一瞬」。
    // appModel 未初始化时 seedWarmSlot 内部据 lowMemory 早退前先设真值；此处与首页
    // 查词一致——独立查词窗在 appModel 初始化完成（popupMain 的 initialiseForDictionaryPopup）
    // 后才有真实查词，未就绪则跳过 seed（无热槽，等价旧行为），不引入新崩溃。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _seedWarmPopup();
    });
    if (widget.autoSearchOnOpen && appModel.isInitialised) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _pushSearch(widget.searchTerm, Rect.zero, reuseWarmSlot: true);
      });
    }
  }

  /// TODO-951 症状C：seed 常驻隐藏热槽。低内存模式 [DictionaryPopupController.seedWarmSlot]
  /// 内部早退；未初始化（早帧 / 测试桩）读 lowMemoryMode 会抛，跳过 seed（无热槽，
  /// 等价旧行为）。与 home_dictionary_page._seedWarmPopup 同范式。
  void _seedWarmPopup() {
    if (!mounted || !appModel.isInitialised) return;
    _popup.lowMemory = appModel.lowMemoryMode;
    setState(() => _popup.seedWarmSlot());
  }

  @override
  void didUpdateWidget(PopupDictionaryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // TODO-951 症状C：宿主常驻本页、每次新 ProcessText 改 searchTerm/searchGeneration。
    // 复用常驻热槽原地查新词（reuseWarmSlot:true），不重建整页 → 不闪。term 与
    // generation 任一变化都重查（同词连续查词靠 generation 触发）。
    final bool changed = oldWidget.searchTerm != widget.searchTerm ||
        oldWidget.searchGeneration != widget.searchGeneration ||
        oldWidget.anchorRect != widget.anchorRect ||
        oldWidget.subtitleWindowRect != widget.subtitleWindowRect;
    if (!changed) return;
    final String trimmed = widget.searchTerm.trim();
    if (trimmed.isEmpty || !appModel.isInitialised) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pushSearch(trimmed, Rect.zero, reuseWarmSlot: true);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    // TODO-058：弹窗 controller 现持有挂起层兜底 Timer，dispose 取消防泄漏。
    _popup.dispose();
    super.dispose();
  }

  /// 顶层查词（来自宿主新词 / 搜索栏提交 / 源文本面板点选）传 [reuseWarmSlot]=true，
  /// 复用常驻热槽原地查新词（不重建 WebView）；嵌套下钻（弹窗内点词/链接）默认
  /// [reuseWarmSlot]=false，[pushNestedPopup] append 一条子层。
  Future<void> _pushSearch(
    String query,
    Rect selectionRect, {
    bool reuseWarmSlot = false,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;
    debugPrint('[popup-perf] search start "$trimmed" '
        '${_startupStopwatch.elapsedMilliseconds}ms');
    if (_searchController.text != trimmed) {
      _searchController.text = trimmed;
      _searchController.selection = TextSelection.collapsed(
        offset: trimmed.length,
      );
    }
    if (mounted) setState(() => _sourceLookupText = trimmed);
    await pushNestedPopup(
      query: trimmed,
      selectionRect: selectionRect,
      controller: _popup,
      autoRead: true,
      // TODO-951 症状C：顶层查词复用常驻热槽（已预热 WebView 原地查新词，不重建 → 不闪）。
      reuseWarmSlot: reuseWarmSlot,
      // 独立查词窗是整窗卡片（非贴选区小浮卡），搜索期保持卡片显示、空白由
      // DictionaryPopupLayer 的加载盖板兜住——不走「搜索期隐藏 + anchored 占位卡」。
      revealWhileSearching: true,
    );
    debugPrint('[popup-perf] ffi done "$trimmed" '
        '${_startupStopwatch.elapsedMilliseconds}ms');
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
    // TODO-951 症状C：保留常驻热槽（pruneToWarmSlot），别 clear 掉热 WebView；
    // 顶层重查走 reuseWarmSlot 原地复用。
    setState(_popup.pruneToWarmSlot);
    _pushSearch(text.trim(), Rect.zero, reuseWarmSlot: true);
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
        // 浮动卡片，外观对齐书内查词弹窗（圆角 + 边框 + 横滑关闭）。
        // TODO-872：带 anchorRect（悬浮字幕条点字）时贴被查字旁定位；否则保持原
        // Alignment.topCenter 贴顶（系统 PROCESS_TEXT / hibiki://lookup 等其它入口）。
        _buildPositionedCard(tokens, gap),
      ],
    );
  }

  /// TODO-872：anchorRect 为 null → 原 [Alignment.topCenter] 贴顶（**零变化**）；
  /// 非空 → 用 [computeFloatingLyricPopupRect] 算出贴被查字旁的矩形，[Positioned] 定位。
  Widget _buildPositionedCard(HibikiDesignTokens tokens, double gap) {
    final Rect? anchor = widget.anchorRect;
    if (anchor == null) {
      return Align(
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
      );
    }
    // TODO-708 P1 ⑥：避让锚优先用「整条字幕窗矩形」（超集，覆盖被查字与未点的其它字），
    // 弹窗不遮整条字幕窗；无字幕窗矩形时回退被查字单字（TODO-872 行为）。
    final Rect avoidRect = widget.subtitleWindowRect ?? anchor;
    return LayoutBuilder(
      builder: (context, constraints) {
        const double maxCardWidth = 480;
        final Size screen = Size(constraints.maxWidth, constraints.maxHeight);
        final double maxHeight = (constraints.maxHeight - gap * 2) * 0.72;
        final Rect rect = computeFloatingLyricPopupRect(
          glyphRect: avoidRect,
          screen: screen,
          maxWidth: maxCardWidth,
          maxHeight: maxHeight,
          gap: gap,
        );
        return Positioned(
          left: rect.left,
          top: rect.top,
          width: rect.width,
          height: rect.height,
          child: _buildCard(tokens),
        );
      },
    );
  }

  Widget _buildCard(HibikiDesignTokens tokens) {
    final Widget card = HibikiPopupSurface(
      color: appModel.overrideDictionaryColor ?? tokens.surfaces.page,
      child: Column(
        children: [
          // TODO-951 症状B：关闭是「结果」，滑动只是其中一种「触发行为」，二者解耦。
          // 关闭 X 渲染在 [SwipeDismissWrapper] 之外（不在其 Listener 子树内）——点 X 永远
          // 直接 [_close]（无滑出动画），不会因 X 落在可滑区里被横拖手势误判/连带播放滑动
          // 特效。横滑只裹搜索栏本体（拖它仍可滑出关闭，那是滑动这一触发行为本身的动画）。
          if (widget.showSearchBar)
            Row(
              children: <Widget>[
                _buildCloseButton(),
                Expanded(child: _buildSwipeChrome(_buildSearchBar())),
              ],
            )
          else
            // TODO-708 P3 ③：悬浮字幕点字入口无搜索输入框，关闭行只留右上关闭按钮。
            // 关闭按钮渲染在 [SwipeDismissWrapper] 之外（TODO-951 症状B：点 X 直接关、
            // 无滑出动画）；横滑只裹左侧留白区（拖它仍可滑出关闭）。
            Row(
              children: <Widget>[
                Expanded(child: _buildSwipeChrome(const SizedBox(height: 36))),
                _buildCloseButton(),
              ],
            ),
          Divider(height: 1, thickness: 1, color: tokens.surfaces.outline),
          if (_sourceLookupText.trim().isNotEmpty)
            SourceLookupTextPanel(
              text: _sourceLookupText,
              coordinateSpaceKey: _resultStackKey,
              dictionaryHeadwordScale: _dictionaryHeadwordScale,
              // 源文本面板点选 = 顶层新词，复用常驻热槽（TODO-951 症状C）。
              onLookup: (String query, Rect rect) =>
                  _pushSearch(query, rect, reuseWarmSlot: true),
            ),
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
    return card;
  }

  Widget _buildSwipeChrome(Widget child) {
    if (_popup.entries.length > 1 ||
        !ReaderHibikiSource.instance.enableSwipeToClose) {
      return child;
    }
    return SwipeDismissWrapper(
      sensitivity: ReaderHibikiSource.instance.dismissSwipeSensitivity,
      onDismiss: _close,
      child: child,
    );
  }

  Widget _buildSearchBar() {
    // onClose: null —— 关闭 X 由 [_buildCloseButton] 在 swipe wrapper 之外独立渲染
    // （TODO-951 症状B 解耦），搜索栏本身不再带 X。
    return PopupDictionarySearchBar(
      controller: _searchController,
      focusNode: _searchFocusNode,
      onClose: null,
      onSubmit: _onSearchSubmit,
    );
  }

  /// TODO-951 症状B：独立于滑动手势的关闭入口。点它直接 [_close]（无滑出动画），
  /// 渲染在 [SwipeDismissWrapper] 之外，任何平台/是否启用滑动关闭都恒可关、不耦合动画。
  Widget _buildCloseButton() {
    return _CompactPopupCloseButton(
      key: const ValueKey<String>('popup_dictionary_close_button'),
      onClose: _close,
    );
  }

  Widget _buildStack(BuildContext context) {
    if (_popup.entries.isEmpty) return const SizedBox.shrink();

    // TODO-951 症状C：常驻热槽（visible=false）也要进树保持其 WebView 预热，但要停到
    // 卡片可视区之外，避免隐藏层（Android 原生 WebView）截获触摸盖住可见层（BUG-135
    // 同范式，这里在卡片局部坐标系内停到卡片右外侧）。Clip.none 让停在外侧的层不被裁。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double cardWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 0;
        return Stack(
          key: _resultStackKey,
          clipBehavior: Clip.none,
          children: <Widget>[
            for (int i = 0; i < _popup.entries.length; i++)
              _buildLayer(context, i, cardWidth: cardWidth),
          ],
        );
      },
    );
  }

  /// app 外查词窗口本身已是一张约束卡片，下钻层不再用「贴选区的小浮卡」
  /// （那是全屏阅读器内 `buildNestedPopupLayer` 的语义，套进小卡里会被压成小窗），
  /// 而是与基础层一样满卡渲染、不透明覆盖下层（BUG-051 的第一症状）。
  /// 基础层（index 0）透明、横滑交由整卡外层；嵌套层不透明、自带横滑返回上一层。
  Widget _buildLayer(
    BuildContext context,
    int index, {
    required double cardWidth,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final DictionaryPopupEntry entry = _popup.entries[index];
    final bool isBase = index == 0;
    final bool isDark =
        (appModel.overrideDictionaryTheme ?? Theme.of(context)).brightness ==
            Brightness.dark;
    final Widget layer = DictionaryPopupLayer(
      // TODO-1065：独立查词窗（popup_main 宿主 / 悬浮字幕外部弹窗）跑在透明浮动窗里，
      // 圆角卡由 Flutter HibikiPopupSurface 画；令弹窗 WebView `<html>` 透明，消除
      // documentElement 不透明填充铺满整窗的泛白（in-app 与桌面 global-lookup 不受影响）。
      transparentDocumentBackground: true,
      result: entry.result,
      isSearching: entry.isSearching,
      // TODO-951 症状C：常驻热槽（isWarmSlot）的 WebView 全程挂载、冷加载一次后复用，
      // 消除「每次查词重建弹窗 WebView 露白屏一瞬」。与 reader/video/首页查词同口径。
      keepWebViewWarm: entry.isWarmSlot,
      webViewKey: entry.webViewKey,
      // TODO-869：本层有后代弹窗时注入 __hasChildPopup，点卡片本体留白才能关子窗。
      hasChildPopup: index < _popup.entries.length - 1,
      isDark: isDark,
      showBorder: false,
      swipeDismissible: !isBase,
      enableSwipeToClose: ReaderHibikiSource.instance.enableSwipeToClose,
      overrideFillColor: isBase
          ? Colors.transparent
          : (appModel.overrideDictionaryColor ?? tokens.surfaces.page),
      onDismiss: isBase ? _close : () => _popAt(index),
      onClose: isBase ? null : () => _popAt(index),
      onBack: null,
      onRendered: () {
        debugPrint('[popup-perf] render "${entry.searchTerm}" '
            '${_startupStopwatch.elapsedMilliseconds}ms');
        if (_popup.revealRendered(entry) && mounted) setState(() {});
      },
      // TODO-951 症状A：点**本层卡片本体的空白区**（popup.js 在 __hasChildPopup 为真时
      // 发 tapOutside，见 BUG-434）只关该层衍生的后代层（关一层），保留本层 + 祖先——
      // 不再 base 层 `_close` 整窗、nested 层 `_popAt(index)` 连本层一起关。与三个 in-app
      // 宿主的 dismissDescendantsOf(index) / truncateTo(index+1) 同语义。
      onTapOutside: () => _dismissDescendantsOf(index),
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
      onOverwriteTargetNoteId: findOverwriteTargetNoteId,
    );

    // TODO-951 症状C：可见层满卡渲染（BUG-051）；隐藏层（常驻热槽 / 挂起冷层）停到卡片
    // 右外侧继续预热，并用 IgnorePointer 兜住（Android 隐藏原生 WebView 仍可能截触摸，
    // 与 BUG-135 parkedPopupLayer 同范式，这里在卡片局部坐标系内停到外侧）。
    if (entry.visible) {
      return Positioned.fill(child: layer);
    }
    return Positioned(
      left: cardWidth + 8,
      top: 0,
      width: cardWidth > 0 ? cardWidth : null,
      bottom: 0,
      child: IgnorePointer(child: layer),
    );
  }

  /// TODO-951 症状A：关闭第 [index] 层**衍生的所有后代层**（index 更大的全部），保留
  /// 本层 + 祖先。线性扁平栈里 index 即 depth，故后代 = `index+1..end`，用
  /// [DictionaryPopupController.truncateTo] 精确裁。点最顶层（无后代）= no-op 栈不变。
  /// 与三个 in-app 宿主（base_source_page.dismissDescendantsOf /
  /// dictionary_page_mixin._dismissDescendantsOfLayer）同语义。
  void _dismissDescendantsOf(int index) {
    if (index < 0 || index >= _popup.entries.length - 1) return; // 无后代=no-op
    setState(() => _popup.truncateTo(index + 1));
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

/// TODO-951 症状B：独立于滑动手势的关闭按钮。渲染在 [SwipeDismissWrapper] 之外，
/// 点它直接调 [onClose]（无滑出动画），与 search bar 内的旧关闭按钮视觉一致（[Icons.close]
/// + 36×36 命中区 + 20 图标）。键沿用 `popup_dictionary_close_button`（桌面焦点驱动测试
/// + 既有 widget 测试都按此键定位）。
class _CompactPopupCloseButton extends StatelessWidget {
  const _CompactPopupCloseButton({
    required this.onClose,
    super.key,
  });

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return SizedBox(
      width: 36,
      height: 36,
      child: HibikiIconButton(
        icon: Icons.close,
        enabledColor: tokens.surfaces.onVariant,
        size: 20,
        tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
        padding: EdgeInsets.zero,
        onTap: onClose,
      ),
    );
  }
}
