import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show KeyDownEvent, KeyEvent;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/lookup/lookup_ime_binding.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/sync_progress_banner.dart';
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/overlay_entry_lifecycle.dart';
import 'package:fushi/src/utils/components/fushi_deferred_loading.dart';
import 'package:fushi/utils.dart';

/// 测试可见的查词状态探针：让 widget 行为测试直接断言「查词后 _isSearching 已复位」
/// 与「_loadMore 不再被永久阻塞」，从而钉住 [TODO-555] 的回归不变量
/// （searchDictionary 抛异常时不得卡住转圈 / 加载更多）。
@visibleForTesting
abstract class HomeDictionarySearchDebug {
  /// 当前是否处于查词中（true 时 query body 显示转圈、_loadMore 被阻塞）。
  bool get debugIsSearching;

  /// 触发一次「加载更多」（等价于滚动到底），返回派发的 future（被卡死时为
  /// 已完成 future，调用本身被 _isSearching 守卫吞掉）。
  Future<void> debugLoadMore();

  /// 直接发起一次查词（等价于在搜索框提交 [term]），返回内部派发的 future
  /// 以便测试 await 失败路径，避免依赖 UI 文本输入的异步链。[writeHistory] 默认
  /// false 以隔离历史写入 / autoRead 等副作用，只验证查词状态机。
  Future<void> debugSearch(String term, {bool writeHistory});

  /// 直接走 HomeDictionaryPage 的生产 `_pushNestedPopup` 路径打开 app 内查词浮层。
  Future<int> debugOpenPopup(String term);

  /// 走同一条生产路径在当前栈顶之上再压一层**嵌套**浮层（不复用常驻热槽，与用户在
  /// 弹窗里点词的路径一致）。BUG-2039 ③ 的停驻 realm 接管只在这条路径上发生。
  Future<int> debugOpenNestedPopup(String term);

  /// 当前顶层浮层的 WebView State 身份（用于断言「再嵌套接管的是同一个 WebView」）。
  Object? get debugTopPopupWebViewState;

  /// 当前可见栈深度与停驻 realm 数。
  ({int depth, int parkedRealms}) get debugPopupStackShape;

  /// 当前顶层浮层按 DOM 测量得到的自适应总高；尚未测量/无层时为 null。
  double? get debugTopPopupAutoFitHeight;

  /// 在当前顶层浮层 WebView 内执行验收脚本（测试功能按钮与 DOM 状态）。
  Future<dynamic> debugEvaluateTopPopup(String source);

  /// 关闭整条浮层栈，等价于用户从顶层关闭。
  void debugClosePopup();
}

/// 「把用户送进搜索框」的一次请求。承载面（[HomeDictionaryPage]）不保活——切走即
/// 销毁、切回冷建，所以请求必须是**可挂起、由页面消费掉**的值，而不是一次性的
/// 通知脉冲：底栏点「查词」时页面还没挂载，脉冲发出去无人接。与桌面取词的
/// [DesktopLookupService.pendingRequest] 同范式。
///
/// [intent] 是这条请求的**意图**，不是调用方的旗标堆叠（见 [DictionaryFocusIntent]）。
@immutable
class DictionaryFocusRequest {
  const DictionaryFocusRequest(this.intent);

  final DictionaryFocusIntent intent;
}

/// 「把用户送进搜索框」时对已有查询的处置——一个调用来源一种意图，别再往上堆 bool。
enum DictionaryFocusIntent {
  /// 只聚焦，不动已有文本：热键「聚焦搜索框」= 「我要编辑当前查询」。
  keepQuery,

  /// 先清空搜索框与查询结果再聚焦：用户从导航（底栏 / 侧栏 rail）点进查词 =
  /// 「我要查个新词」，键盘随焦点弹起。
  clearQuery,

  /// 聚焦并**全选**已有文本：app 外热键「置顶主窗并打开查词页」。用户按它多半是要查
  /// 新词——直接打字就替换；但也可能只是切回来看上次的结果（尤其配合「查词页按 Esc
  /// 最小化」来回切），什么都不打就原样保留。浏览器地址栏 Ctrl+L 的模型。
  selectQuery,
}

/// 搜索区建议面板最多列几条最近搜索（MD3 chip）。
const int _kRecentSearchLimit = 8;

/// Apple 建议面板是 inset grouped 行，比 chip 占高，只列这么多条。
const int _kRecentSearchAppleRows = 5;

/// MD3 Expressive 结果卡圆角（extra-large 形状档）。
const double _kResultCardRadiusMd3 = 28;

/// The body content for the Dictionary tab in the main menu.
class HomeDictionaryPage extends BaseTabPage {
  const HomeDictionaryPage({
    super.key,
    this.focusSignal,
    this.showBackButton = false,
    this.initialQuery,
  });

  /// 待消费的聚焦请求（见 [DictionaryFocusRequest]）。本页消费后置回 null，故同一
  /// 请求不会被重复执行，下一次点击也总是 null→request 的真实变化。
  final ValueNotifier<DictionaryFocusRequest?>? focusSignal;

  /// 挂载后立即当作用户输入查一次的文本（不写查词历史）。新手引导用它把练习句子
  /// 直接喂进本页：源文本条显示整句，用户在真实查词面板里点词。与在搜索框里粘贴
  /// 这句话走**同一条** [_search] 路径，不另开入口。
  final String? initialQuery;

  /// 本页作为**独立路由**承载时（查词 tab 被「功能模块」隐藏，热键/桌面取词仍要有
  /// 落地面，见 HomePage 的 `_revealDictionary`）在页头左侧显示返回箭头。作为 tab
  /// 内容时恒 false —— 切 tab 不产生路由栈，画一个返回箭头没有可返回的目标。
  final bool showBackButton;

  @override
  BaseTabPageState<HomeDictionaryPage> createState() =>
      _HomeDictionaryPageState();
}

class _HomeDictionaryPageState extends BaseTabPageState<HomeDictionaryPage>
    with DictionaryPageMixin
    implements HomeDictionarySearchDebug {
  @override
  AppModel get mixinAppModel => appModel;

  @override
  ThemeData get mixinTheme => theme;

  @override
  MediaType get mediaType => DictionaryMediaType.instance;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  /// 语言取 [appModelNoUpdate] 而**不是** `appModel`：后者在 mounted 时是
  /// `ref.watch`（`base_page.dart`），而 [LookupImeBinding.attach] 在 `initState`
  /// 里**同步**调一次 `languageOf()`——在 build 之外建立 InheritedWidget 依赖会被
  /// Flutter 当场抛（debug 下点进查词 tab 直接红屏）。这里也本来就不该 watch：
  /// 输入法语言变了只需下次同步时读到新值，不需要整页重建。
  late final LookupImeBinding _imeBinding = LookupImeBinding(
    languageOf: () => appModelNoUpdate.effectiveLookupImeLanguage,
  );

  DictionarySearchResult? _result;
  final DictionaryPopupController _popup = DictionaryPopupController(
    lowMemory: false,
    onLookupStackDepthChanged: recordLookupStackDepth,
  );
  final GlobalKey _resultStackKey = GlobalKey();

  /// 结果区 [DictionaryPopupWebView] 的 key——顶层查词把 WebView 局部 localRect 经它的
  /// render box `localToGlobal` 映成屏幕坐标（[popupWordScreenRect]），与提到根 Overlay
  /// 后的弹窗坐标系（真实屏幕空间）统一（TODO-617）。
  final GlobalKey<DictionaryPopupWebViewState> _resultWebViewKey =
      GlobalKey<DictionaryPopupWebViewState>();

  /// TODO-617：查词弹窗栈渲染在**根 Overlay**（全窗，跳出结果子区域 / DesktopContentLayout
  /// 的限宽 + padding + 默认 hardEdge 裁剪），与 video 同范式。非空时 [_syncPopupOverlay]
  /// 据当前栈插入 / 刷新 / 摘除。
  OverlayEntry? _popupOverlayEntry;

  /// 切 tab 销毁本页时的根 Overlay 兜底（照搬 video BUG-121）：本 State deactivate 后根
  /// Overlay 仍可能同帧重建 [_buildPopupOverlay] → 读已失效 State 的 appModel/Theme 红屏；
  /// 置位后 builder 一律空渲染。
  bool _overlayInert = false;

  bool _isSearching = false;
  String _lastQuery = '';
  bool _allLoaded = false;
  Timer? _debounceTimer;
  String _sourceLookupText = '';
  int _searchGeneration = 0;

  /// 源文本条上「这次查的是哪几个字」的 Yomitan 式扫描高亮。
  ///
  /// 查词是「从被点的字到串尾」的整段后缀交给引擎最长匹配（BUG-1478），所以查询串
  /// 本身看不出命中了多长；不标出来，用户在「と言いつつ」上点第一个字，根本无从
  /// 判断结果是「と言い」还是「と」。跨度长度只能等引擎回报，故本页持有它。
  ///
  /// 迟到回报由 [_searchGeneration] 一并挡住：高亮现在与下方结果同源于一次主查词，
  /// 结果被判过期，长度也就到不了这里，不再需要第二个发号器（那正是它被摘掉的原因）。
  SourceLookupHighlight? _sourceHighlight;

  bool _historyWritten = false;

  /// 搜索区（搜索栏 + 其下的「最近搜索」面板）是否持有焦点。决定 SearchView 式
  /// 展开（最近搜索面板）与 Apple 下大标题折叠。按**整个搜索区**而不是只按输入框
  /// 判：手柄 / Tab 从输入框走到面板里的建议上时面板不能收起，否则焦点所在的那一项
  /// 当场被摘掉。
  bool _searchRegionFocused = false;

  /// 搜索区的身份：宽窄布局切换（拖窗跨断点）时搜索区换了父节点，用 GlobalKey 让
  /// 输入框连同焦点 / 组字状态一起搬过去，而不是重建成一个失焦的新输入框。
  final GlobalKey _searchRegionKey =
      GlobalKey(debugLabel: 'home-dictionary-search-region');

  /// 仅测试可见：最近一次派发的查词 future（[debugSearch] 返回它以便
  /// await 失败路径）。生产路径仍 fire-and-forget，不改变行为。
  Future<void>? _lastDispatchedSearch;

  @override
  void initState() {
    super.initState();
    appModelNoUpdate.dictionarySearchAgainNotifier.addListener(_searchAgain);
    // TODO-1204：接线查词计数（每次查词 +1 → lookup_mining_counters）。
    attachLookupCounter(_popup);
    appModelNoUpdate.dictionaryEntriesNotifier
        .addListener(_onDictionaryEntriesChanged);
    _searchFocusNode.addListener(_onFocusChanged);
    _imeBinding.attach(focusNode: _searchFocusNode);
    widget.focusSignal?.addListener(_consumeFocusRequest);
    DesktopLookupService.instance.addListener(_onDesktopLookupPending);
    // TODO-376：挂载即消费一次挂载前已排入的 pending。桌面悬浮字幕点词 / 深链在切到
    // 本 tab *之前* 就把待查词排进 pendingText 并 notify，那次 notify 发生在本页
    // addListener 之前收不到。故挂载即排一次后帧消费已存在的 pending（有 pending 才
    // 消费，无 pending 则 no-op，不会乱消费）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onDesktopLookupPending();
    });
    // 同理，导航点进本 tab 的聚焦请求也排在本页挂载**之前**（本页不保活，点击那
    // 一刻它还不存在），挂载即消费一次已排入的 pending。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _consumeFocusRequest();
    });
    // 新手引导的练习句子：挂载后当作用户输入查一次（不写历史），源文本条随即显示
    // 整句供点词。
    final String? initialQuery = widget.initialQuery;
    if (initialQuery != null && initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search(initialQuery, writeHistory: false);
      });
    }
    // TODO-931: 首页查词原本每次 lookup 走 replaceStack 销毁+冷建弹窗 WebView，连点会让某次
    // WebView 析构撞上上一个 WebView 仍在途的 WebResourceRequested 拦截 deferral → Windows
    // inappwebview fork 里 use-after-free 崩溃。与 reader（base_source_page）/ video 一致，
    // 开页 seed 一个常驻隐藏热槽：弹窗 WebView 冷加载一次后全程复用，消除「每次查词销毁+重建
    // WebView」的高频 create/destroy。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _seedWarmPopup();
    });
  }

  /// TODO-931：开页 seed 一个常驻隐藏热槽，使查词弹窗 WebView 冷加载一次后全程复用
  /// （消除连点时反复 create/destroy WebView 触发的 Windows UAF 崩溃）。低内存模式不保留
  /// 热槽（[DictionaryPopupController.seedWarmSlot] 据 lowMemory 早退）。热槽隐藏在栈中，
  /// 真实挂载到根 Overlay 由 [_syncPopupOverlay] 在结果区渲染后完成（彼时才有可 lookup 的
  /// 词条 WebView）。
  void _seedWarmPopup() {
    if (!mounted) return;
    // 生产里 HomeDictionaryPage 只在 LoadingPage→HomePage（isInitialised=true）之后才挂载，
    // 故 seed 时 AppModel 必已初始化；未初始化（早帧 / widget 测试桩）则 prefsRepo 为 null，
    // 读 lowMemoryMode / popupBottomDocked 会抛，此刻也没有真实查词，直接跳过 seed（无热槽，
    // 等价旧行为），不引入新崩溃。与 video `_seedWarmPopup` 的「成功路径必已初始化」同范式。
    if (!appModel.isInitialised) return;
    _popup.lowMemory = appModel.lowMemoryMode;
    setState(() => _popup.seedWarmSlot());
  }

  /// 消费一条待处理的聚焦请求（挂载后 / 在场时收到通知都走这里）。
  void _consumeFocusRequest() {
    final ValueNotifier<DictionaryFocusRequest?>? signal = widget.focusSignal;
    final DictionaryFocusRequest? request = signal?.value;
    if (signal == null || request == null) return;
    // 被全屏路由（阅读器 / 播放器）压在底下的 tab 承载不消费：同一个 focusSignal
    // 此刻还有另一个消费者——HomePage 为「被遮住」推的独立查词路由（同一个
    // HomeDictionaryPage、同一条信号）。底下这份先监听、先抢走请求，往看不见的
    // 搜索框上 requestFocus 等于把请求吞掉，用户看到的是最上层那页没有焦点。留给
    // 真正可见的那份消费。
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    signal.value = null;
    // 与 [_onDesktopLookupPending] 同一条纪律：不在帧中（idle，或已经在后帧回调里
    // ——挂载即消费那条路就是从 initState 的后帧回调进来的）直接执行，只有 build /
    // layout 进行中才排后帧。addPostFrameCallback **不调度帧**——「已经在查词页上
    // 再按热键」这条路没有任何 setState，排进去的回调要等到别的东西凑巧触发一帧
    // 才跑，焦点请求就这样悬空。
    final SchedulerPhase phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      _applyFocusRequest(request);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _applyFocusRequest(request);
      });
    }
  }

  void _applyFocusRequest(DictionaryFocusRequest request) {
    if (!mounted) return;
    switch (request.intent) {
      case DictionaryFocusIntent.clearQuery:
        // _clearSearch 自带 requestFocus——清空与聚焦是同一个动作，别拆成两步。
        _clearSearch();
      case DictionaryFocusIntent.selectQuery:
        // 先选区后聚焦：EditableText 拿到焦点时只会把**无效**选区重置到文末，
        // 合法的全选原样保留。
        _controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _controller.text.length,
        );
        _focusSearchField();
      case DictionaryFocusIntent.keepQuery:
        _focusSearchField();
    }
  }

  /// 把用户送进搜索框并确保软键盘弹起（BUG-2687）。
  ///
  /// 光 `requestFocus` 不够：搜索框**已经有焦点**时它是空操作，而移动端焦点在、
  /// 键盘不在是常态——提交后收了键盘（BUG-2686）、系统返回键收了键盘，焦点都还
  /// 留在框里。此时已在查词页再点「查词」，框清空了键盘却不弹。
  /// [EditableTextState.requestKeyboard] 正是「点一下输入框」的语义：没焦点就
  /// 聚焦，有焦点就向输入法再要一次键盘。
  void _focusSearchField() {
    if (!_searchFocusNode.canRequestFocus) return;
    final EditableTextState? editable = _searchFocusNode.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (editable != null && editable.mounted) {
      editable.requestKeyboard();
    } else {
      _searchFocusNode.requestFocus();
    }
  }

  void _onDesktopLookupPending() {
    final DesktopLookupRequest? request =
        DesktopLookupService.instance.pendingRequest;
    if (request == null) return;
    DesktopLookupService.instance.clearPending();
    _sourceLookupText = request.text;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      _runDesktopLookup(request);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runDesktopLookup(request);
      });
    }
  }

  void _runDesktopLookup(DesktopLookupRequest request) {
    if (!mounted) return;
    // 显式查词（深链 / 浏览器扩展 / 悬浮字幕点词）：把主窗唤到前台。
    unawaited(DesktopLookupService.instance.bringPendingLookupToFront());
    // force——显式查词意图，即便与上次同词也要重查，页面不叠加「同词不重查」去重。
    _search(request.text, autoRead: false, force: true);
  }

  void _onFocusChanged() {
    if (!_searchFocusNode.hasFocus) {
      _commitHistory();
    }
  }

  void _commitHistory() {
    if (_historyWritten) return;
    final trimmed = _controller.text.trim();
    if (trimmed.isEmpty || _result == null || _result!.entries.isEmpty) return;
    _historyWritten = true;
    appModel.addToSearchHistory(
      historyKey: mediaType.uniqueKey,
      searchTerm: trimmed,
    );
    appModel.addToDictionaryHistory(result: _result!);
  }

  void _onDictionaryEntriesChanged() {
    if (!mounted) return;
    final model = appModelNoUpdate;
    if (!model.isMediaOpen &&
        DictionaryMediaType.instance ==
            model.mediaTypes.values.toList()[model.currentHomeTabIndex]) {
      setState(() {});
    }
  }

  // ── 「返回上一级」最小化主窗（用户请求，Flow Launcher 式用法）────────────
  //
  // app 外热键把主窗置顶到本页 → 查完按「返回上一级」（默认 Esc）→ 主窗最小化、OS 把
  // 前台交还给之前的程序，全程不碰鼠标。偏好默认关；开了之后它**优先于**本页
  // PopScope 的「关弹窗 → 清查询」阶梯——用户要的是一键收窗，走完阶梯要按三下，
  // 而查询与结果原样留着，下次热键回来搜索框全选、直接打字就替换。
  //
  // 执行体只有这一份，两条输入通道汇进来：
  //   · Flutter 持焦（搜索框 / 历史列表）：本页 [_handleLookupPageKey]，挂在整页
  //     子树上，比 HomePage / app 根的 globalBack 更近，先到先认领；
  //   · 弹窗持焦（用户点过结果卡片，焦点在根 Overlay 的 WebView 子树里，按键**永远
  //     到不了**本页与 HomePage 的 Focus，BUG-1347）：既有的弹窗输入桥
  //     [dictionaryPopupInputScope] → [onDictionaryPopupInputToken]。
  // 两边都解析注册表里的 [ShortcutAction.globalBack]，不硬编码 Esc——改键跟着走。
  // 落地在本页而不是 HomePage：tab 承载与独立路由承载（查词模块关掉时）都是同一个
  // HomeDictionaryPage，放这里两种承载天然一致。

  /// 偏好开着且当前平台真有「最小化」这回事。
  bool get _escapeMinimizesWindow =>
      DesktopLookupService.isDesktop &&
      appModel.lookupPageEscapeMinimizesWindow;

  /// 最小化主窗；返回是否真的发出（非桌面 / 插件缺席返回 false，按键不认领）。
  Future<bool> _minimizeWindowFromLookupPage() =>
      DesktopLookupService.instance.minimizeMainWindow();

  KeyEventResult _handleLookupPageKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!_escapeMinimizesWindow) return KeyEventResult.ignored;
    // TODO-847 同款：IME 组字时 logicalKey 被改写成 process，传 physicalKey 让注册
    // 表走物理键回退；搜索框正在组字（focusedEditableText != null）时传 null 关闭回
    // 退——那一下 Esc 是在取消组字，不是要收窗。
    final ShortcutAction? action = appModel.shortcutRegistry.resolveKeyboard(
      event.logicalKey,
      modifiers: activeModifierKeys(),
      scope: ShortcutScope.universal,
      physicalKey: focusedEditableText() == null ? event.physicalKey : null,
    );
    if (action != ShortcutAction.globalBack) return KeyEventResult.ignored;
    unawaited(_minimizeWindowFromLookupPage());
    return KeyEventResult.handled;
  }

  /// 弹窗持焦时把「返回上一级」交回本页（偏好关着时不装桥：空表 = 弹窗那边什么都
  /// 不拦，Esc 照旧沿根 Overlay 冒到 app 根，行为与改动前逐字相同）。
  @override
  ShortcutScope? get dictionaryPopupInputScope =>
      _escapeMinimizesWindow ? ShortcutScope.home : null;

  @override
  Set<ShortcutAction> get dictionaryPopupForwardedActions =>
      _escapeMinimizesWindow
          ? const <ShortcutAction>{ShortcutAction.globalBack}
          : const <ShortcutAction>{};

  @override
  bool onDictionaryPopupInputToken(String token) {
    // home scope 未命中时函数内部回落 universal（「返回上一级」就在那里）。
    final ShortcutAction? action = resolveDictionaryPopupInputToken(
      registry: appModel.shortcutRegistry,
      token: token,
      scope: ShortcutScope.home,
    );
    if (action != ShortcutAction.globalBack) return false;
    if (!_escapeMinimizesWindow) return false;
    unawaited(_minimizeWindowFromLookupPage());
    return true;
  }

  @override
  void dispose() {
    widget.focusSignal?.removeListener(_consumeFocusRequest);
    DesktopLookupService.instance.removeListener(_onDesktopLookupPending);
    _searchFocusNode.removeListener(_onFocusChanged);
    _imeBinding.detach();
    appModelNoUpdate.dictionarySearchAgainNotifier.removeListener(_searchAgain);
    appModelNoUpdate.dictionaryEntriesNotifier
        .removeListener(_onDictionaryEntriesChanged);
    _commitHistory();
    _debounceTimer?.cancel();
    _searchFocusNode.dispose();
    _controller.dispose();
    // TODO-617：先摘根 Overlay 浮层 entry 再 clear 栈——entry 一旦移除就不会再被根
    // Overlay 重建 [_buildPopupOverlay]，杜绝销毁期用失效 State 重建浮层（照搬 video）。
    final OverlayEntry? entry = _popupOverlayEntry;
    if (entry != null) {
      removeAndDisposeOwnedOverlayEntry(entry);
      _popupOverlayEntry = null;
    }
    // TODO-058：弹窗 controller 现持有挂起层兜底 Timer，dispose 取消防泄漏。
    _popup.dispose();
    super.dispose();
  }

  /// TODO-617：切 tab 销毁本页的根 Overlay 兜底（BUG-121 同范式）。本 State deactivate
  /// 当帧根 Overlay 仍可能重建 entry → 读失效 State 红屏；置位让 builder 空渲染。
  @override
  void deactivate() {
    _overlayInert = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    // GlobalKey 重挂等重新激活：恢复正常渲染，下次 build 的 _syncPopupOverlay 重建浮层。
    _overlayInert = false;
  }

  bool get _hasActiveQuery => _controller.text.isNotEmpty;

  void _clearSearch() {
    _resetQuery();
    _focusSearchField();
  }

  /// 清掉查询串、结果与扫描状态（不碰焦点）。[_clearSearch] 清完把用户送回
  /// 搜索框；Apple 搜索栏的「取消」（[_cancelSearch]）清完交出焦点。
  void _resetQuery() {
    _searchGeneration++;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _controller.clear();
    // TODO-931：保留常驻热槽（pruneToWarmSlot），别 clear 掉热 WebView。
    _popup.pruneToWarmSlot();
    _result = null;
    _isSearching = false;
    _lastQuery = '';
    _allLoaded = false;
    _sourceLookupText = '';
    _sourceHighlight = null;
    _historyWritten = false;
    setState(() {});
  }

  void _clearSearchFromResultPull() {
    // TODO-931：常驻热槽使 entries 永不空，可见性判据改用 hasVisiblePopup（隐藏热槽不算）。
    if (_popup.hasVisiblePopup || _popup.isSearchingUi) return;
    _clearSearch();
  }

  /// Apple 搜索栏的「取消」：清空查询、收起键盘并交出焦点，大标题随之展开回来
  /// （iOS 搜索控制器的取消语义）。
  void _cancelSearch() {
    if (_hasActiveQuery) _resetQuery();
    _searchFocusNode.unfocus();
    if (_searchRegionFocused) setState(() => _searchRegionFocused = false);
  }

  /// 词典页下拉 = **手动同步**（云备份 + 互联两条通道）。
  ///
  /// 与书架 / 视频页不同，词典页没有「远端词典列表」这种视图——词典资源是被**同步进
  /// 来的**（同步流程的 dictionaries 阶段，互联通道走 listRemoteDictionaries）。所以这里
  /// 下拉只有同步一件事，跑完 setState 重读 `appModel.dictionaries` /
  /// `dictionaryHistory`（本页不走 Riverpod，数据直读 AppModel），让同步落地的新词典
  /// 和新查词历史立刻显示。
  ///
  /// 只挂在历史列表 / 空态上，**不挂查询结果屏**：那一屏的下拉早已被「清空查询」占用
  /// （[_clearSearchFromResultPull]，手势的真实来源是结果 WebView 内的 JS），再叠一层
  /// 刷新就是两个手势抢同一个下拉。
  Future<void> _pullToRefreshDictionary() async {
    await runManualSyncWithFeedback(
      context: context,
      appModel: appModel,
      // 绝大多数用户没配云同步，每次下拉都弹「同步不可用」是纯噪音；已有同步在飞时
      // 用户下拉，数据照样会更新，不必打断。冲突/错误提示仍然照给。
      announceNotConfigured: false,
      announceBusy: false,
    );
    if (!mounted) return;
    setState(() {});
  }

  // ── build ──────────────────────────────────────────────────────────

  /// 宽屏主从（左栏搜索 + 历史、右栏结果）的判据：与 [DesktopContentLayout] 同一
  /// 断点（expanded，≥ 840），按**真实**宽度判档（BUG-401：界面缩放下逻辑宽被放大）。
  bool _isWideLayout(double logicalWidth) =>
      windowSizeClassReal(logicalWidth, FushiAppUiScale.of(context)) ==
          WindowSizeClass.expanded;

  /// Apple（iOS）搜索中折叠大标题：搜索区持焦或已有查询时收起，把高度让给建议与
  /// 结果（UISearchController 搜索态隐藏导航栏大标题的同款）。只在窄屏——桌面 /
  /// 平板的大标题不挤占结果区。独立路由不折叠：它的返回键在页头里，是 iOS 上唯一的
  /// 出口（见 [build] 注释）。
  bool _collapsesLargeTitle(BuildContext context) =>
      isGlassDesign(context) &&
      !widget.showBackButton &&
      MediaQuery.sizeOf(context).width < 600 &&
      (_searchRegionFocused || _hasActiveQuery);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // TODO-931：常驻热槽永远占着 entries[0]，返回判据改用 hasVisiblePopup（隐藏热槽不拦返回）。
      canPop: !_hasActiveQuery && !_popup.hasVisiblePopup,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_popup.hasVisiblePopup) {
          _popNestedPopupAt(_popup.lastVisibleIndex);
        } else if (_hasActiveQuery) {
          _clearSearch();
        }
      },
      // 「返回上一级」最小化主窗（见 [_handleLookupPageKey]）：挂在整页子树上、
      // 只拦不抢焦点（canRequestFocus: false + skipTraversal），偏好关着时恒 ignored。
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _handleLookupPageKey,
        child: FushiFileDropTarget(
          debugLabel: 'home-dictionary',
          onDrop: _handleDictionaryHomeDrop,
          // BUG-1658：页头必须在 DesktopContentLayout 外——dictionary 档的 16/24px
          // 侧向留白只属于查词正文（文字流贴边可读性差），叠到页头上会让本页大标题
          // 相对书架/视频/游戏等库页整体右移（用户实报「每个页面的页头宽度不一样」）。
          child: Column(
            children: [
              // Cupertino 档由外层导航栏顶替页头，但独立路由（查词模块被关掉时
              // 走的 `_StandaloneDictionaryRoute`）是个裸 Scaffold，页头里的返回键
              // 是它唯一的可见出口——iOS 没有系统返回键，`canPop` 又在有查询词时
              // 关掉侧滑，藏掉页头就等于把用户锁在查词页里。
              if (!isCupertinoPlatform(context) || widget.showBackButton)
                _buildCollapsibleHeader(
                  collapsed: _collapsesLargeTitle(context),
                  child: _buildPageHeader(),
                ),
              Expanded(
                child: DesktopContentLayout(
                  kind: DesktopContentKind.dictionary,
                  child: _buildContentLayout(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 正文区：宽屏主从、窄屏单栏（搜索区 + 同步进度 + 历史 / 结果）。
  Widget _buildContentLayout() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        if (_isWideLayout(box.maxWidth)) {
          return _buildWideLayout(box.maxWidth);
        }
        return Column(
          children: [
            _buildSearchRegion(),
            // 下拉同步可能跑几十秒，光一个转圈看不出进展；没同步在飞时零高度。
            const SyncProgressBanner(),
            Expanded(child: _buildBody()),
          ],
        );
      },
    );
  }

  /// 大标题的折叠壳。结构恒定（ClipRect → AnimatedAlign → AnimatedOpacity →
  /// ExcludeFocus → 页头），只换系数：按状态增删这几层会让页头整棵重挂。折叠后
  /// 页头退出焦点遍历——高度为 0 的按钮不能还是 Tab / 手柄的落点。时长走
  /// [fushiMotionDuration]，墨水屏 / 减弱动态效果下瞬间到位。
  Widget _buildCollapsibleHeader({
    required bool collapsed,
    required Widget child,
  }) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return ClipRect(
      child: AnimatedAlign(
        alignment: Alignment.bottomCenter,
        heightFactor: collapsed ? 0 : 1,
        duration: duration,
        curve: collapsed ? FushiMotion.exit : FushiMotion.enter,
        child: AnimatedOpacity(
          opacity: collapsed ? 0 : 1,
          duration: duration,
          curve: FushiMotion.standard,
          child: ExcludeFocus(excluding: collapsed, child: child),
        ),
      ),
    );
  }

  /// 宽屏主从：左栏 = 搜索区 + 查词历史，右栏 = 结果卡。两栏同时在场，查过的词
  /// 随手点回右栏，不必先清空搜索框退回历史屏（窄屏单栏仍是「历史 ⇄ 结果」切换）。
  Widget _buildWideLayout(double width) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: supportingPaneWidthForLayout(width),
          child: Column(
            children: <Widget>[
              _buildSearchRegion(),
              const SyncProgressBanner(),
              Expanded(
                child: FushiRefreshIndicator(
                  onRefresh: _pullToRefreshDictionary,
                  child: _buildHistoryOrPlaceholder(),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _hasActiveQuery ? _buildQueryBody() : _buildIdleResultPane(),
        ),
      ],
    );
  }

  /// 宽屏右栏的空态：还没有查询时一张同形的结果卡，里面提示输入要查的词。
  Widget _buildIdleResultPane() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiStaggeredEntrance(
      key: const ValueKey<String>('home_dictionary_state_idle'),
      index: 0,
      child: FushiCard(
        margin: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          0,
          tokens.spacing.page,
          tokens.spacing.page,
        ),
        padding: EdgeInsets.zero,
        borderRadius: _resultCardRadius(),
        pressScale: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: isGlassDesign(context)
                ? CupertinoIcons.search
                : Icons.manage_search,
            message: t.floating_ball_lookup_hint,
          ),
        ),
      ),
    );
  }

  void _handleDictionaryHomeDrop(List<String> paths, Offset globalPosition) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    final List<String> importPaths = classifyDroppedFilesForDictionary(paths);
    debugPrint(
      '[fushi-drop] [home-dictionary] importPaths=${importPaths.length} '
      'paths=${paths.length} global=$globalPosition',
    );
    if (importPaths.isEmpty) {
      debugPrint('[fushi-drop] [home-dictionary] intent=unsupportedSurface');
      FushiToast.show(
        msg: t.drag_drop_unsupported_on_dictionary,
        severity: ToastSeverity.error,
      );
      return;
    }
    unawaited(appModel.showDictionaryMenu(initialImportPaths: importPaths));
  }

  Widget _buildPageHeader() {
    return FushiPageHeader(
      title: t.nav_lookup,
      leading: widget.showBackButton
          ? FushiIconButton(
              key: const ValueKey<String>('home-dictionary-route-back'),
              tooltip: t.back,
              icon: Icons.arrow_back,
              onTap: () => Navigator.of(context).maybePop(),
            )
          : null,
      actions: <Widget>[
        // Apple：词典管理（导入 / 排序 / 启用）放在大标题的页头动作里——iOS 搜索栏
        // 右侧只留「取消」。MD3 把它放在搜索栏尾部的 tonal 圆钮（见搜索区）。
        if (isGlassDesign(context))
          FushiIconButton(
            key: const ValueKey<String>('home-dictionary-manage'),
            tooltip: t.dictionaries,
            icon: CupertinoIcons.book,
            onTap: appModel.showDictionaryMenu,
          ),
        // 收藏夹入口：查词页里收藏的词 / 句（含视频、有声书来源）在这里集中看、
        // 批量制卡。此前只能从书架 / 视频库进收藏夹，查词页没有入口。
        FushiIconButton(
          key: const ValueKey<String>('home-dictionary-collections'),
          tooltip: t.collections,
          icon: Icons.collections_bookmark_outlined,
          onTap: _openCollections,
        ),
        FushiIconButton(
          tooltip: t.clear_dictionary_title,
          icon: Icons.delete_sweep_outlined,
          onTap: _showDeleteDictionaryHistoryPrompt,
        ),
      ],
    );
  }

  void _openCollections() {
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => const CollectionsPage(),
      ),
    );
  }

  /// 搜索区 = 搜索栏 + 其下的「最近搜索」面板（SearchView 式：搜索区持焦且框为空
  /// 时展开）。整块是一个 [TextFieldTapRegion]：触屏点建议 / 「取消」不算点在输入
  /// 框外，输入框不会先失焦把面板收掉、吞掉这一下点击。
  Widget _buildSearchRegion() {
    return KeyedSubtree(
      key: _searchRegionKey,
      child: TextFieldTapRegion(
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (bool focused) {
            if (!mounted || focused == _searchRegionFocused) return;
            setState(() => _searchRegionFocused = focused);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildSearchHeader(),
              _buildRecentSearchesPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchHeader() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool glass = isGlassDesign(context);
    final double horizontalPadding =
        isCupertinoPlatform(context) ? tokens.spacing.gap : tokens.spacing.page;
    // Apple 搜索栏的「取消」：搜索中（持焦或已有查询）才滑出，点了退出搜索。
    final bool showCancel = glass && (_searchRegionFocused || _hasActiveQuery);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        0,
        horizontalPadding,
        tokens.spacing.gap,
      ),
      // Let the MD3 SearchBar own its height instead of forcing kToolbarHeight.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: FushiSearchField(
              fieldKey: const ValueKey<String>('home_dictionary_search_field'),
              clearButtonKey: const ValueKey<String>(
                'home_dictionary_search_clear_button',
              ),
              controller: _controller,
              focusNode: _searchFocusNode,
              hintText: t.search_ellipsis,
              onChanged: _onQueryChanged,
              onClear: _clearSearch,
              onSubmitted: _search,
              // 页面顶部的独立搜索栏：MD3 是 56 高的 M3 SearchBar；Apple 仍是
              // 36 的 iOS 搜索胶囊（large 在 Apple 下不拉伸）。
              size: FushiSearchFieldSize.large,
              // MD3：SearchBar 尾部一枚 tonal 圆钮直达词典管理（导入 / 排序 /
              // 启用），收进搜索栏的 trailing 槽（48 触控区，按钮本体 40）。
              // 墨水屏不铺 tonal 底。Apple 下没有这枚钮（与原来一致）。
              trailing: glass
                  ? const <Widget>[]
                  : <Widget>[
                      FushiIconButton(
                        key: const ValueKey<String>(
                          'home_dictionary_manage_button',
                        ),
                        tooltip: t.dictionaries,
                        icon: Icons.library_books_outlined,
                        backgroundColor: isEinkTheme(context)
                            ? null
                            : Theme.of(context).colorScheme.secondaryContainer,
                        enabledColor: isEinkTheme(context)
                            ? null
                            : Theme.of(
                                context,
                              ).colorScheme.onSecondaryContainer,
                        constraints: const BoxConstraints.tightFor(
                          width: 40,
                          height: 40,
                        ),
                        onTap: appModel.showDictionaryMenu,
                      ),
                    ],
            ),
          ),
          // 结构恒定：AnimatedSize 一直在，只换里面是「取消」还是零尺寸。
          AnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            alignment: AlignmentDirectional.centerStart,
            child: showCancel
                ? Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: tokens.spacing.gap,
                    ),
                    child: FushiTextButton(
                      key: const ValueKey<String>(
                        'home_dictionary_search_cancel',
                      ),
                      onPressed: _cancelSearch,
                      child: Text(t.dialog_cancel),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          if (isCupertinoPlatform(context))
            FushiIconButton(
              tooltip: t.clear_dictionary_title,
              icon: Icons.delete_sweep_outlined,
              onTap: _showDeleteDictionaryHistoryPrompt,
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_hasActiveQuery) {
      // 查询结果屏不包 RefreshIndicator：那儿的下拉是「清空查询」
      // （[_clearSearchFromResultPull]），两个手势不能抢同一个下拉。
      return _buildQueryBody();
    }
    return FushiRefreshIndicator(
      onRefresh: _pullToRefreshDictionary,
      child: _buildHistoryOrPlaceholder(),
    );
  }

  Widget _buildHistoryOrPlaceholder() => appModel.dictionaryHistory.isEmpty
      ? _buildPlaceholder()
      : _buildDictionaryHistory();

  /// 查询屏三态（结果 / 查询中 / 无结果）。每态一个 key：状态切换时新内容淡入
  /// 上移（[FushiStaggeredEntrance] 的单项用法——没有进场窗口祖先，挂载即播一次，
  /// 墨水屏 / 减弱动态效果下瞬间出现），同一态内换了一份结果不重播。
  ///
  /// 不用 AnimatedSwitcher 交叉淡化：它让旧子树多活一个过渡周期，而结果屏持有结果
  /// WebView 与 Stack 的 GlobalKey——旧结果屏还没退场就又切回结果屏（清空后立刻点
  /// 回一条历史）会出现两份同 key 子树。
  ///
  /// 「无结果」只在查询真的结束且为空时出现（[resolveQueryBodyState]）：查询在途、或
  /// 输入已变而新查询还在去抖窗口里（手里的空结果属于上一个输入）都算加载中——旧实现
  /// 在去抖窗口与「结果因输入已变被丢弃」两处会先闪一下「未找到」再跳成结果。加载指示
  /// 器走 [FushiDeferredLoading]：150ms 后才露出、露出后至少停 300ms 再淡出。
  Widget _buildQueryBody() {
    final QueryBodyState state = resolveQueryBodyState(
      hasResults: _result != null && _result!.entries.isNotEmpty,
      searching: _isSearching,
      queryPending: _debounceTimer?.isActive ?? false,
    );
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _buildQueryStateBody(state),
        FushiDeferredLoading(
          active: state == QueryBodyState.loading,
          background: Theme.of(context).scaffoldBackgroundColor,
        ),
      ],
    );
  }

  Widget _buildQueryStateBody(QueryBodyState state) {
    if (state == QueryBodyState.results) {
      return FushiStaggeredEntrance(
        key: const ValueKey<String>('home_dictionary_state_results'),
        index: 0,
        child: _buildSearchResultBody(),
      );
    }
    if (state == QueryBodyState.loading) {
      return const SizedBox.shrink(
        key: ValueKey<String>('home_dictionary_state_searching'),
      );
    }
    return FushiStaggeredEntrance(
      key: const ValueKey<String>('home_dictionary_state_empty'),
      index: 0,
      child: Center(
        child: FushiPlaceholderMessage(
          icon: Icons.search_off,
          message: t.no_search_results,
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final noDictionaries = appModel.dictionaries.isEmpty;
    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FushiPlaceholderMessage(
          icon: mediaType.outlinedIcon,
          message: noDictionaries
              ? t.dictionaries_menu_empty
              : t.info_empty_home_tab,
        ),
        if (noDictionaries) ...[
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          FushiFilledButton.icon(
            icon: const FushiIcon(Icons.auto_stories_outlined, size: 18),
            label: Text(t.dialog_import_dictionary),
            onPressed: appModel.showDictionaryMenu,
          ),
        ],
      ],
    );
    // 空态也要能下拉同步——RefreshIndicator 需要一个真实 Scrollable 后代，裸 Center
    // 没有滚动就吃不到下拉手势。撑到 minHeight = 视口高度既保住原来的垂直居中，又让
    // AlwaysScrollableScrollPhysics 在内容不满一屏时仍然响应下拉。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          // 空态挂载即淡入（无进场窗口祖先 → 单项进场只播一次）。
          child: Center(
            child: FushiStaggeredEntrance(index: 0, child: content),
          ),
        ),
      ),
    );
  }

  // ── recent searches (SearchView suggestions) ───────────────────────

  /// 最近搜索（新的在前），给搜索区的建议面板用。AppModel 未初始化（早帧 / 只桩了
  /// 部分接口的 widget 测试）时没有历史仓库可读，按「没有最近搜索」处理。
  List<String> _recentSearches() {
    if (!appModel.isInitialised) return const <String>[];
    return appModel
        .getSearchHistory(historyKey: mediaType.uniqueKey)
        .reversed
        .where((String term) => term.trim().isNotEmpty)
        .take(_kRecentSearchLimit)
        .toList(growable: false);
  }

  /// 正在被左滑的那条最近搜索（Apple）：滑动时给它垫上分组底色，让滑开露出的
  /// 删除红底只在行尾，不透过透明的行内容铺满整行。
  String? _swipingRecentSearch;

  void _searchRecent(String term) {
    // 建议面板随即收起（框里有字了），先把焦点交回输入框，手柄 / Tab 不落空。
    if (!_searchFocusNode.hasFocus && _searchFocusNode.canRequestFocus) {
      _searchFocusNode.requestFocus();
    }
    _search(term);
  }

  void _removeRecentSearch(String term) {
    // 仓库先同步删缓存再异步落库，这一帧重建时被滑走的那行已经不在列表里。
    unawaited(
      appModel.removeFromSearchHistory(
        historyKey: mediaType.uniqueKey,
        searchTerm: term,
      ),
    );
    setState(() {
      if (_swipingRecentSearch == term) _swipingRecentSearch = null;
    });
  }

  void _clearRecentSearches() {
    appModel.clearSearchHistory(historyKey: mediaType.uniqueKey);
    if (!_searchFocusNode.hasFocus && _searchFocusNode.canRequestFocus) {
      _searchFocusNode.requestFocus();
    }
    setState(() {});
  }

  /// SearchView 式建议面板：搜索区持焦且框为空时在搜索栏下展开最近搜索。监听
  /// 输入框本身（关了自动搜索时打字不经 setState），一敲字就收起。
  Widget _buildRecentSearchesPanel() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (BuildContext context, TextEditingValue value, Widget? _) {
        final List<String> recents = _searchRegionFocused && value.text.isEmpty
            ? _recentSearches()
            : const <String>[];
        // 结构恒定：AnimatedSize 一直在，展开 / 收起只换里面的内容。每次展开
        // 新挂一个进场窗口，建议逐项错峰进场。
        return AnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.enter,
          alignment: Alignment.topCenter,
          child: recents.isEmpty
              ? const SizedBox(width: double.infinity)
              : FushiEntranceScope(child: _buildRecentSearches(recents)),
        );
      },
    );
  }

  Widget _buildRecentSearches(List<String> recents) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool glass = isGlassDesign(context);
    final Widget title = _buildSectionTitle(
      t.lookup_recent_searches,
      trailing: FushiTextButton(
        key: const ValueKey<String>('home_dictionary_recent_clear'),
        onPressed: _clearRecentSearches,
        child: Text(t.clear),
      ),
    );
    if (!glass) {
      // MD3：建议 chip（全胶囊、tonal 面），点即查、× 删一条。
      return Padding(
        padding: EdgeInsets.only(bottom: tokens.spacing.gap),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            title,
            Padding(
              padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              child: Wrap(
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: <Widget>[
                  for (int i = 0; i < recents.length; i++)
                    FushiStaggeredEntrance(
                      key: ValueKey<String>(
                        'home_dictionary_recent_${recents[i]}',
                      ),
                      index: i,
                      child: FushiPressScale(
                        child: FushiTagChip(
                          label: recents[i].replaceAll('\n', ' '),
                          tone: FushiTagChipTone.surface,
                          onTap: () => _searchRecent(recents[i]),
                          onDeleted: () => _removeRecentSearch(recents[i]),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    // Apple：inset grouped 最近搜索——时钟图标 + 词，左滑删除一条，标题行「清除」
    // 清空全部（键盘 / 手柄删除走它）。
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final List<String> rows =
        recents.take(_kRecentSearchAppleRows).toList(growable: false);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          title,
          for (int i = 0; i < rows.length; i++)
            FushiStaggeredEntrance(
              key: ValueKey<String>('home_dictionary_recent_${rows[i]}'),
              index: i,
              child: FushiGroupedListItem(
                index: i,
                count: rows.length,
                margin: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
                // 分隔线从文字起点开始（行首 18 号时钟 + 12 间距之后）。
                separatorIndent: metrics.rowHorizontal + 30,
                onTap: () => _searchRecent(rows[i]),
                child: Dismissible(
                  key: ValueKey<String>('home_dictionary_recent_swipe_${rows[i]}'),
                  direction: DismissDirection.endToStart,
                  onUpdate: (DismissUpdateDetails details) {
                    final String? swiping =
                        details.progress > 0 ? rows[i] : null;
                    if (swiping == _swipingRecentSearch) return;
                    setState(() => _swipingRecentSearch = swiping);
                  },
                  onDismissed: (_) => _removeRecentSearch(rows[i]),
                  // 统一滑动操作底（Apple 系统红 / MD3 errorContainer）；外层分段
                  // 卡已按组内位置裁圆角，这里不再另给圆角。
                  background: const FushiSwipeActionBackground(
                    icon: CupertinoIcons.delete,
                    destructive: true,
                    borderRadius: BorderRadius.zero,
                  ),
                  // 结构恒定：底色层一直在，只在被左滑时才不透明。
                  child: ColoredBox(
                    color: _swipingRecentSearch == rows[i]
                        ? apple.secondaryGroupedBackground
                        : Colors.transparent,
                    child: FushiListItem(
                      minHeight: 44,
                      leading: FushiIcon(
                        CupertinoIcons.clock,
                        size: 18,
                        color: apple.secondaryLabel,
                      ),
                      title: Text(rows[i].replaceAll('\n', ' ')),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 分组外标题（「最近搜索」「查词历史」）：MD3 = sectionLabel，Apple = 13 号
  /// semibold secondaryLabel 并缩进到行文字起点。[trailing] 放标题行尾的动作。
  Widget _buildSectionTitle(String text, {Widget? trailing}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool glass = isGlassDesign(context);
    final double inset = glass
        ? FushiAppleMetrics.of(context).rowHorizontal
        : tokens.spacing.gap / 2;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page + inset,
        tokens.spacing.gap / 2,
        tokens.spacing.page,
        tokens.spacing.gap / 2,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: glass
                  ? settingsAppleSectionTitleStyle(context)
                  : tokens.type.sectionLabel,
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  // ── dictionary history list ────────────────────────────────────────

  Widget _buildDictionaryHistory() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 空结果条目本来就画成 SizedBox.shrink，这里直接滤掉：Apple 分组要按可见
    // 行判首尾（圆角 / 分隔线），不能被看不见的空行打断。
    final historyResults = appModel.dictionaryHistory.reversed
        .where((r) => r.entries.isNotEmpty)
        .toList();
    if (historyResults.isEmpty) {
      return _buildPlaceholder();
    }
    final bool glass = isGlassDesign(context);
    final int count = historyResults.length;
    // 进场窗口：历史屏每次挂载（首开 / 清空查询退回 / 宽窄切换）首屏行错峰淡入，
    // 滚动带出来的行瞬间出现。
    return FushiEntranceScope(
      child: ListView.builder(
        padding: EdgeInsets.only(
          top: tokens.spacing.gap / 2,
          bottom: tokens.spacing.page,
        ),
        // 历史只有一两条、撑不满一屏时，默认 physics 不可滚 → 下拉同步吃不到手势。
        physics: const AlwaysScrollableScrollPhysics(),
        controller: DictionaryMediaType.instance.scrollController,
        // 第 0 项是分组标题「查词历史」，其后才是历史行。
        itemCount: count + 1,
        itemBuilder: fushiStaggeredItemBuilder((
          BuildContext context,
          int index,
        ) {
          if (index == 0) return _buildSectionTitle(t.lookup_history_title);
          final int row = index - 1;
          final result = historyResults[row];
          final searchTerm = result.searchTerm.trim();
          final first = result.entries.first;
          final word = first.word;
          final reading = first.reading;
          final hasWordInfo = word.isNotEmpty && word != searchTerm;
          final hasReading =
              reading.isNotEmpty && reading != word && reading != searchTerm;
          final dictCount =
              result.entries.map((e) => e.dictionaryName).toSet().length;
          // 整段历史读作一个分组，而不是一摞各自独立的圆角卡（与词典管理页的
          // 词典列表同口径）：MD3 分段分组 / Apple inset grouped，见共享外壳
          // [FushiGroupedListItem]。宽屏主从下当前右栏显示的那条标为选中。
          return FushiGroupedListItem(
            index: row,
            count: count,
            margin: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            selected: _hasActiveQuery && _lastQuery == searchTerm,
            onTap: () {
              _controller.text = searchTerm;
              _controller.selection =
                  TextSelection.collapsed(offset: searchTerm.length);
              _showCachedResult(result);
            },
            child: FushiListItem(
              title: Text(searchTerm.replaceAll('\n', ' ')),
              subtitle: hasWordInfo || hasReading
                  ? Text([
                      if (hasWordInfo) word,
                      if (hasReading) reading,
                    ].join('  '))
                  : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 命中词典数：中性小徽标（MD3 tonal / Apple 灰阶填充），不再是
                  // 裸数字贴着箭头。
                  FushiTag(
                    text: '$dictCount',
                    tone: FushiTagTone.neutral,
                    dense: true,
                  ),
                  SizedBox(width: tokens.spacing.gap / 2),
                  glass
                      ? const FushiAppleChevron()
                      : const FushiIcon(Icons.chevron_right, size: 20),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  // ── search logic ───────────────────────────────────────────────────

  void _onQueryChanged(String query) {
    _debounceTimer?.cancel();
    _historyWritten = false;
    if (query.isEmpty) {
      _clearSearch();
      return;
    }
    if (!appModel.autoSearchEnabled) return;
    final int delay = appModel.searchDebounceDelay;
    if (delay <= 0) {
      if (mounted) _search(query, writeHistory: false);
    } else {
      _debounceTimer = Timer(Duration(milliseconds: delay), () {
        if (!mounted) return;
        _search(query, writeHistory: false);
        // 计时器已不再 active：_search 走缓存 / 同查询早退时不会自己 setState，这里
        // 补一帧，结果区才会从「加载中」落到真实状态。
        setState(() {});
      });
      // 去抖窗口内结果区要按「加载中」画（[resolveQueryBodyState]），不是旧结果的空态。
      if (mounted) setState(() {});
    }
  }

  void _searchAgain() {
    _lastQuery = '';
    _search(_controller.text);
  }

  void _showCachedResult(DictionarySearchResult cached) {
    setState(() {
      _result = cached;
      _isSearching = false;
      // Non-empty cache always allows one scroll-to-bottom probe;
      // _loadMore will set _allLoaded if nothing new comes back.
      _allLoaded = cached.entries.isEmpty;
      _lastQuery = cached.searchTerm.trim();
      // 源文本条同步换成这条历史的查询串。此前这里只换 _result 和搜索框，不动
      // _sourceLookupText——历史列表只在查询框为空时可见，而清空输入框并不经
      // _clearSearch，于是点开一条历史后源文本条上留的可能是上一次桌面取词的整句
      // 旧文本。那在没有高亮时只是「有点怪」，加了扫描高亮就会变成「框在一段跟结果
      // 毫无关系的文字上」：命中长度以本条 cached 为准，坐标系却是别人的串。
      _sourceLookupText = _lastQuery;
      // 缓存结果同样带 bestLength，扫描高亮按同一条换算落到句首命中段——否则从
      // 历史点回一条旧查询，原文条上会是一片没有任何标记的裸文本。
      _applyScanHighlight(
        SourceLookupScan(query: _lastQuery, charIndex: 0),
        cached,
      );
      // TODO-931：保留常驻热槽。
      _popup.pruneToWarmSlot();
    });
  }

  void _search(
    String query, {
    int? overrideMaximumTerms,
    bool writeHistory = true,
    bool? autoRead,
    // BUG-1025：跳过「与上次查询相同即不重查」守卫。剪贴板/热键/显式查词经
    // DesktopLookupService 排队时已做过时间窗去重判定（同词超窗口 = 用户显式重查），
    // 页面这层若再叠加一次永久内容去重，用户第二次复制同一个词依旧查不了。
    bool force = false,
    // 源文本条点字发起的「扫描查词」（Yomitan 式）：查询串是被点字起的后缀，但
    // 条上的整句、搜索框里的整句都**不动**——变的只是下方的结果和条上的高亮跨度。
    // 非空即表示本次查词由该锚点发起，同时充当高亮的坐标锚。
    SourceLookupScan? scanAnchor,
  }) {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;
    // 「接管搜索框与源文本条」的顶层查词：只有既不是「加载更多」、也不是扫描查词
    // 的那一类。加载更多只是把同一个查询串的词头上限调大；扫描查词则要把整句留在
    // 条上和搜索框里，被点的字只是句中的一段。
    final bool replaceSourceLookupText =
        overrideMaximumTerms == null && scanAnchor == null;
    // 朗读与写历史解耦：旧实现把朗读写在 writeHistory 分支里，等于拿「要不要记
    // 历史」代答「要不要读」。输入框防抖查词（writeHistory=false）确实不该读，但
    // 扫描查词要读、又不该把用户点过的每个字都灌进历史，两者不能再共用一个开关。
    final bool autoReadResult = writeHistory || scanAnchor != null;

    if (!force && _lastQuery == trimmed && overrideMaximumTerms == null) {
      if (_sourceLookupText != trimmed && mounted) {
        setState(() {
          _sourceLookupText = trimmed;
          // 源文本换了就得重定位扫描高亮：这条早退路径不重查（结果沿用 _result），
          // 但高亮的坐标系是源文本条，换了串不重算就会框在错的位置上。
          final DictionarySearchResult? current = _result;
          if (current == null) {
            _sourceHighlight = null;
          } else {
            _applyScanHighlight(
              SourceLookupScan(query: trimmed, charIndex: 0),
              current,
            );
          }
        });
      }
      if (writeHistory &&
          !_historyWritten &&
          _result != null &&
          _result!.entries.isNotEmpty) {
        _historyWritten = true;
        appModel.addToSearchHistory(
          historyKey: mediaType.uniqueKey,
          searchTerm: trimmed,
        );
        appModel.addToDictionaryHistory(result: _result!);
      }
      return;
    }
    _lastQuery = trimmed;
    overrideMaximumTerms ??= appModel.maximumTerms;

    // 只有接管搜索框的顶层查词才把输入框同步成查询串。扫描查词的查询串是句中后缀，
    // 同步过去会把用户眼前的整句换成半截；「加载更多」的查询串与框内本就一致，这条
    // 守卫对它是恒真的空操作。
    if (replaceSourceLookupText && _controller.text != trimmed) {
      _controller.text = trimmed;
      _controller.selection = TextSelection.collapsed(offset: trimmed.length);
    }

    if (mounted) {
      final int searchGeneration = ++_searchGeneration;
      setState(() {
        _isSearching = true;
        if (replaceSourceLookupText) _sourceLookupText = trimmed;
        // TODO-931：保留常驻热槽。
        _popup.pruneToWarmSlot();
      });
      final Future<void> dispatched = _searchWithGeneration(
        trimmed: trimmed,
        overrideMaximumTerms: overrideMaximumTerms,
        writeHistory: writeHistory,
        autoRead: autoRead,
        autoReadResult: autoReadResult,
        searchGeneration: searchGeneration,
        // 派发那一刻搜索框里是什么，结果落地时就得还是什么，否则这次结果已被用户
        // 改写的输入作废。此前这里直接拿 `trimmed` 与输入框比——对「查询串恒等于
        // 输入框」的老路径成立，对扫描查词（框里是整句、查询串是后缀）恒不成立，
        // 结果会被自己的守卫全部丢掉。
        inputTextAtDispatch: _controller.text,
        // 「加载更多」（overrideMaximumTerms 非空）不换源文本，也就不该动扫描高亮：
        // 它只是把同一个查询串的词头上限调大，命中段没变，而用户此刻的高亮可能已经
        // 是他点出来的某个词，重设会把它弹回句首。扫描查词则按被点字的下标重定位。
        // 这里不能再判 `overrideMaximumTerms == null`：它上面已被 `??=` 补过默认值，
        // 那个判空恒假，主查词会一路拿到 null 锚点、高亮再也不落。用入口处算好的
        // 标志，它记的正是「本次是不是接管搜索框与源文本条的顶层查词」。
        highlightAnchor: scanAnchor ??
            (replaceSourceLookupText
                ? SourceLookupScan(query: trimmed, charIndex: 0)
                : null),
      );
      _lastDispatchedSearch = dispatched;
      unawaited(dispatched);
    } else if (replaceSourceLookupText) {
      _sourceLookupText = trimmed;
    }
  }

  Future<void> _searchWithGeneration({
    required String trimmed,
    required int overrideMaximumTerms,
    required bool writeHistory,
    required bool? autoRead,
    required int searchGeneration,
    required bool autoReadResult,
    required String inputTextAtDispatch,
    required SourceLookupScan? highlightAnchor,
  }) async {
    // 用 try/finally 守卫整条失败路径：searchDictionary 走远程网络查询 +
    // fushidicts C++ FFI，任一环节抛异常都不能让 _isSearching 永久为 true
    // （否则 _buildQueryBody 永久转圈、_loadMore 永久阻塞）。finally 始终复位，
    // 但只对仍是当前 generation 的请求 setState，避免污染已被新请求覆盖的状态。
    try {
      final DictionarySearchResult result = await appModel.searchDictionary(
        searchTerm: trimmed,
        searchWithWildcards: true,
        overrideMaximumTerms: overrideMaximumTerms,
      );
      if (!mounted ||
          searchGeneration != _searchGeneration ||
          _controller.text != inputTextAtDispatch) {
        return;
      }

      _result = result;
      _allLoaded = !result.truncated;
      if (highlightAnchor != null) _applyScanHighlight(highlightAnchor, result);

      if (writeHistory) {
        _historyWritten = true;
        appModel.addToSearchHistory(
          historyKey: mediaType.uniqueKey,
          searchTerm: trimmed,
        );
        if (result.entries.isNotEmpty) {
          appModel.addToDictionaryHistory(result: result);
        }
      }
      if (autoReadResult && result.entries.isNotEmpty) {
        // autoRead 覆盖：null 沿用全局 autoReadOnLookup（正常输入查词不变），
        // 桌面剪贴板/热键路径显式传 false 抑制朗读。
        final bool shouldAutoRead =
            autoRead ?? ReaderFushiSource.instance.autoReadOnLookup;
        if (shouldAutoRead) {
          final entry = result.entries.first;
          if (entry.word.isNotEmpty) {
            autoReadWord(entry.word, entry.reading,
                popupState: _resultWebViewKey.currentState);
          }
        }
      }
    } finally {
      // 仅当本请求仍是最新 generation 时复位（保留过期守卫，避免对已被新请求
      // 覆盖的状态 setState）。异常 / 正常 / 命中 stale 守卫的 return 都会执行此处。
      if (mounted && searchGeneration == _searchGeneration) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  void _loadMore() {
    if (_isSearching || _allLoaded || _result == null) return;
    // BUG-1478：按词头递增（见 base_source_page 同处注释）。
    final int current = _result!.headwordCount;
    // 「更多」要更多的是**眼下这份结果**的查询串。扫描查词之后它是句中的一段后缀，
    // 而搜索框里仍是整句——照旧拿 `_controller.text` 去加载更多，会把结果整个换成
    // 另一个词的，用户只是滚到底就看见结果被掉包。
    final String activeQuery =
        _lastQuery.isNotEmpty ? _lastQuery : _controller.text;
    _lastQuery = '';
    _search(
      activeQuery,
      overrideMaximumTerms: current + appModel.maximumTerms,
      writeHistory: false,
    );
  }

  @override
  bool get debugIsSearching => _isSearching;

  @override
  Future<void> debugLoadMore() {
    _lastDispatchedSearch = null;
    _loadMore();
    return _lastDispatchedSearch ?? Future<void>.value();
  }

  @override
  Future<void> debugSearch(String term, {bool writeHistory = false}) {
    _lastDispatchedSearch = null;
    _search(term, writeHistory: writeHistory);
    return _lastDispatchedSearch ?? Future<void>.value();
  }

  @override
  Future<int> debugOpenPopup(String term) => _pushNestedPopup(
        term,
        const Rect.fromLTWH(180, 180, 24, 24),
        reuseWarmSlot: true,
      );

  @override
  Future<int> debugOpenNestedPopup(String term) => _pushNestedPopup(
        term,
        const Rect.fromLTWH(220, 220, 24, 24),
        reuseWarmSlot: false,
      );

  @override
  Object? get debugTopPopupWebViewState {
    final int index = _popup.lastVisibleIndex;
    return index < 0 ? null : _popup.entries[index].webViewKey.currentState;
  }

  @override
  ({int depth, int parkedRealms}) get debugPopupStackShape => (
        depth: _popup.lastVisibleIndex + 1,
        parkedRealms: _popup.parkedRealms.length,
      );

  @override
  double? get debugTopPopupAutoFitHeight {
    final int index = _popup.lastVisibleIndex;
    return index < 0 ? null : _popup.entries[index].autoFitHeight;
  }

  @override
  Future<dynamic> debugEvaluateTopPopup(String source) async {
    final int index = _popup.lastVisibleIndex;
    if (index < 0) return null;
    return _popup.entries[index].webViewKey.currentState?.debugEval(source);
  }

  @override
  void debugClosePopup() {
    final int index = _popup.lastVisibleIndex;
    if (index >= 0) _popNestedPopupAt(index);
  }

  // ── search results with nested popups ──────────────────────────────

  Widget _buildSearchResultBody() {
    // TODO-617：每次 build 后把查词弹窗栈同步到根 Overlay（栈非空插入 / 刷新，栈空摘除）。
    // 弹窗 push/pop 都走 setState → 重 build → 本同步，使根 Overlay 总反映当前栈。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPopupOverlay());
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool hasSourceText = _sourceLookupText.trim().isNotEmpty;
    // 结果区是一张内容卡（MD3 surfaceContainerLow / 28 圆角；Apple 实色二级分组底 /
    // inset grouped 圆角）：源文本条是卡头，结果 WebView 是卡身。WebView 文档背景
    // 透明（popup.css `html.fushi-glass-host`），词条直接落在卡面上。卡片不裁剪
    // （Clip.none）——给平台视图加圆角裁剪在 Android 混合合成下有额外合成开销；
    // 卡身的内边距把滚动中的正文挡在圆角之内。
    return FushiCard(
      margin: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        0,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      padding: EdgeInsets.zero,
      borderRadius: _resultCardRadius(),
      pressScale: false,
      clipBehavior: Clip.none,
      child: Column(
        children: [
          if (hasSourceText) ...<Widget>[
            Padding(
              padding: EdgeInsets.only(top: tokens.spacing.gap),
              child: SourceLookupTextPanel(
                text: _sourceLookupText,
                dictionaryHeadwordScale: appModel.dictionaryFontSize /
                    appModel.defaultDictionaryFontSize,
                highlight: _sourceHighlight,
                // 点字换的是下方那份结果（Yomitan 式扫描），不再压一张浮在字上的查词卡，
                // 所以本条不再需要回报任何弹窗坐标系的 rect——rect 与 globalCoordinates
                // 都随之退场。结果卡内部选词 / 点链才继续走弹窗栈（见下方 WebView）。
                onLookup: (String query, Rect _, int charIndex) =>
                    _lookupFromSourceStrip(query, charIndex),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              child: const FushiDivider(),
            ),
          ],
          // 根因修复（BUG-054）：结果区 WebView 仍整块在中和器下渲染（净缩放=1），否则被全局
          // 「界面大小」FittedBox 拉糊。源文本条是普通 app UI，留在中和器外继续吃界面大小。
          // TODO-617：嵌套弹窗栈不再挂在此页内 Stack（会被结果子区域 / DesktopContentLayout
          // 限宽 + padding + 默认 hardEdge 裁住），改由 [_buildPopupOverlay] 渲染在根 Overlay。
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.gap / 2,
                hasSourceText ? tokens.spacing.gap / 2 : tokens.spacing.gap,
                tokens.spacing.gap / 2,
                tokens.spacing.gap,
              ),
              child: FushiAppUiScaleNeutralizer(
                child: Stack(
                  key: _resultStackKey,
                  children: [
                    const SizedBox.shrink(
                      key: ValueKey<String>('home_dictionary_result_evidence'),
                    ),
                    DictionaryPopupWebView(
                      key: _resultWebViewKey,
                      result: _result!,
                      // TODO-617：顶层查词把 WebView 局部 localRect 经结果 WebView 的 render box
                      // localToGlobal 映成屏幕坐标（popupWordScreenRect），与根 Overlay 弹窗同系。
                      // localRect==Zero 时直传 Zero，由 mixin fallbackSelectionRect 兜底。
                      onTextSelected: (text, localRect) {
                        _pushNestedPopup(
                          text,
                          _resultWordScreenRect(localRect),
                          reuseWarmSlot: true,
                        );
                      },
                      onLinkClick: (query, localRect) {
                        _pushNestedPopup(
                          query,
                          _resultWordScreenRect(localRect),
                          reuseWarmSlot: true,
                        );
                      },
                      onMineEntry: onMineEntry,
                      onUpdateEntry: onUpdateEntry,
                      onDuplicateCheck: checkDuplicate,
                      onOverwriteTargetNoteId: findOverwriteTargetNoteId,
                      onScrolledToBottom: _allLoaded ? null : _loadMore,
                      onTopPullReleased: _clearSearchFromResultPull,
                      // TODO-1152：结果区 WebView 填满 [Expanded]（全高固定大区域）。
                      // Windows 上 WebView2 内容在 put_Bounds 撑高后 render 完即 idle 无
                      // damage，宿主 WGC 帧池采不到新暴露下半区（下半屏黑）。渲染完补一次
                      // 表面重绘 nudge 逼出完整视口帧。嵌套弹窗内容自适应、无此问题，不开。
                      nudgeSurfaceOnRender: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 结果卡（及宽屏右栏空态卡）的圆角：MD3 Expressive 大面板 28；Apple 走 inset
  /// grouped 分组圆角（iOS ≈ 24 / 桌面 12），与同屏历史分组同形。
  BorderRadius _resultCardRadius() => isGlassDesign(context)
      ? fushiCardBorderRadius(context)
      : const BorderRadius.all(Radius.circular(_kResultCardRadiusMd3));

  /// TODO-617：把结果区 WebView 报的局部 [localRect]（CSS px，原点=WebView 左上）映成屏幕
  /// 坐标，供提到根 Overlay 的弹窗按真实屏幕空间定位。Zero（无 rect 的 textSelected）直传
  /// Zero 让 mixin 兜底。
  Rect _resultWordScreenRect(Rect localRect) {
    if (localRect == Rect.zero) return Rect.zero;
    return popupWordScreenRect(
      webViewKey: _resultWebViewKey,
      localRect: localRect,
      fallback: localRect,
    );
  }

  /// TODO-617：把查词弹窗栈同步到根 Overlay（与 video [_syncPopupOverlay] 同范式）。栈非空
  /// 且未插入则插入、栈空则摘除、否则 markNeedsBuild 刷新。在 [_buildSearchResultBody] 的
  /// post-frame 调，使根 Overlay 总反映当前栈。
  void _syncPopupOverlay() {
    if (!mounted) return;
    if (_popup.entries.isEmpty) {
      final OverlayEntry? entry = _popupOverlayEntry;
      if (entry != null) {
        removeAndDisposeOwnedOverlayEntry(entry);
        _popupOverlayEntry = null;
      }
      return;
    }
    if (_popupOverlayEntry != null) {
      _popupOverlayEntry!.markNeedsBuild();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(builder: _buildPopupOverlay);
    _popupOverlayEntry = entry;
    overlay.insert(entry);
  }

  /// TODO-617：根 Overlay 里的查词弹窗栈内容——透明 dismiss 遮罩 + 搜索期加载占位卡 + 各层
  /// [DictionaryPopupLayer]。根 Overlay 在 [FushiAppUiScale] 的 FittedBox 之内（缩放后的
  /// 小画布），WebView 在此栅格化再拉大会字糊（BUG-051）；[FushiAppUiScaleNeutralizer] 把
  /// 整棵子树中和回真实视口、净缩放=1（清晰），其坐标系即真实屏幕空间，与顶层 / 嵌套选区的
  /// localToGlobal 屏幕 rect 同系，定位自洽。`Clip.none` 让飘出窗的弹窗 / 屏外热槽不被裁
  /// （BUG-135）。`screen` = 中和后内层 LayoutBuilder 约束 = 整窗。
  Widget _buildPopupOverlay(BuildContext overlayContext) {
    // 切 tab 销毁本页当帧根 Overlay 仍会重建本 entry——彼时读失效 State 的 appModel/Theme
    // 会红屏（BUG-121）。State 失效 / 销毁期标志置位则空渲染兜底；Theme 用 entry 自己的
    // overlayContext（与本 entry 同寿命）而非更短命的 State context。
    if (!mounted || _overlayInert) return const SizedBox.shrink();
    // BUG-2953：浮层自带导航层，弹窗里唤出的菜单画在浮层之上（见 LookupOverlayNavigator）。
    return LookupOverlayNavigator(
     child: FushiAppUiScaleNeutralizer(
      child: Theme(
        data: appModel.overrideDictionaryTheme ?? Theme.of(overlayContext),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            if (!mounted || _overlayInert) return const SizedBox.shrink();
            final Size screen =
                Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              // BUG-135：隐藏热槽停到屏幕右外侧（buildNestedPopupLayer），Clip.none 让它在
              // 屏外照常预热又不被裁；飘出窗的弹窗同理不裁。
              clipBehavior: Clip.none,
              children: <Widget>[
                // BUG-1327：对话框期间连 barrier 一起撤——浮层子树挂在根 Overlay，排在
                // showAppDialog 推的路由之上，全屏 barrier 会把落在对话框上的点击吃掉并
                // 判成「点弹窗外面」关栈。判据收口在 [shouldShowLookupDismissBarrier]。
                if (shouldShowLookupDismissBarrier(
                  hasVisiblePopup: _hasVisiblePopup,
                  isSearching: _popup.isSearchingUi,
                  hiddenByDialog: lookupPopupHiddenByDialog,
                ))
                  Positioned.fill(
                    // BUG-1757：barrier 收口成唯一原语 [LookupDismissBarrier]，
                    // 横拖走它内部不入竞技场的 Listener 旁路 + 可单测的判轴。
                    child: LookupDismissBarrier(
                      // 本表面不按落点分流，点真空白一律关栈根层。
                      onTapDismiss: (_) => _popNestedPopupAt(0),
                      // TODO-1052：水平拖过阈关一层（逐层关）。
                      onSwipeDismiss: _dismissTopNestedPopup,
                      swipeEnabled:
                          ReaderFushiSource.instance.enableSwipeToClose,
                      // BUG-2770：触摸半边未设置时所有平台默认开。
                      touchSwipeEnabled:
                          ReaderFushiSource.instance.enableTouchSwipeToClose,
                      sensitivity:
                          ReaderFushiSource.instance.dismissSwipeSensitivity,
                      // 弹窗可见时 barrier 吃掉全部指针，页面根收不到——「浮窗矩形
                      // 之外」按鼠标非主键这半边只能在这里接（见钩子文档）。
                      onNonPrimaryButtonDown: onDismissBarrierNonPrimaryButton,
                    ),
                  ),
                // 搜索期加载占位卡（搜索→就绪才显示，与书内同观感）。
                if (_popup.isSearchingUi && _popup.pendingRect != null)
                  buildPopupLoadingPlaceholder(
                    rect: _popup.pendingRect!,
                    screen: screen,
                  ),
                for (int i = 0; i < _popup.entries.length; i++)
                  _buildNestedPopupLayer(i, screen),
                ...buildParkedRealmLayers(screen: screen, controller: _popup),
              ],
            );
          },
        ),
      ),
     ),
    );
  }

  /// 源文本条点字（或 Shift 悬停）：把**下方那份查词结果**换成从该字起的最长匹配，
  /// 并把 Yomitan 式扫描高亮落到真正被匹配的那几个字上。
  ///
  /// 此前这里压的是一张浮在被点字上的查词卡（`_pushNestedPopup`）。那让同一次查词
  /// 裂成两个可见面：条上的高亮挪了、卡片盖在条下面另起一套结果，而页面本体那份
  /// 结果还停在上一个词上；再点一个字又是一张卡。Yomitan 的扫描没有这一层——挪的
  /// 始终是同一份结果。所以这里改走主查词管线（[_search]），条上的整句与搜索框里的
  /// 整句都留着不动，变的只有下方结果和高亮跨度。
  ///
  /// 分两拍：先立刻框住被点的那个字（点下去就有反馈，不用干等查词往返），引擎回报
  /// 匹配长度后再由 [_applyScanHighlight] 扩成整词；中途用户又点了别的字，迟到的那
  /// 次回报会被 `_searchGeneration` 挡在门外。
  void _lookupFromSourceStrip(String query, int charIndex) {
    final SourceLookupScan scan = SourceLookupScan.fromSuffix(
      suffix: query,
      charIndex: charIndex,
    );
    if (scan.query.isEmpty) return;
    setState(() {
      _sourceHighlight = SourceLookupHighlight(
        start: scan.charIndex,
        length: 1,
      );
    });
    _search(
      scan.query,
      // 点同一个字两次仍要重查：与桌面取词同理（BUG-1025），显式手势不该被「与上次
      // 查询相同即不重查」的内容去重吞掉。
      force: true,
      // 用户点过的每个字都灌进查词历史会把历史刷成噪声；朗读由 scanAnchor 单独开
      // （见 [_search] 里的 autoReadResult）。
      writeHistory: false,
      scanAnchor: scan,
    );
  }

  /// 把一次查词的引擎命中长度落成源文本条上的扫描高亮。
  ///
  /// 引擎的候选串**全部是查询串的前缀**（`scan_candidates` 只从串首锚定、由长到短
  /// 地截），所以命中段的起点恒为查询串的串首；[SourceLookupScan.charIndex] 给出那个
  /// 串首落在条上的位置——主查词（搜索框提交 / 桌面取词 / 深链 / 点回历史）是条首
  /// 0，源文本条点字是被点的那个字。两者是同一个换算的两种锚。
  void _applyScanHighlight(
    SourceLookupScan anchor,
    DictionarySearchResult result,
  ) {
    _sourceHighlight = resolveSourceLookupHighlight(
      query: anchor.query,
      tappedGraphemeIndex: anchor.charIndex,
      matchedUnits: lookupHighlightCharCount(
        result: result,
        searchTerm: anchor.query,
        language: JapaneseLanguage.instance,
      ),
      leadingStripUnits: appModel.lookupLeadingStripUnits(anchor.query),
    );
  }

  Future<int> _pushNestedPopup(
    String query,
    Rect selectionRect, {
    bool reuseWarmSlot = false,
  }) {
    return pushNestedPopup(
      query: query,
      selectionRect: selectionRect,
      controller: _popup,
      reuseWarmSlot: reuseWarmSlot,
      autoRead: true,
    );
  }

  /// TODO-931：是否有任何**可见**弹窗层（常驻隐藏热槽不算）。
  bool get _hasVisiblePopup => _popup.hasVisiblePopup;

  /// TODO-1052：查词浮层 barrier 上「水平拖过阈关一层」。判轴/累积/阈值全部收在
  /// [LookupDismissBarrier] 内（BUG-1757：横拖不进手势竞技场）。过阈关一层（逐层
  /// 关，非清整栈；清整栈仍是点真空白的 tap）。
  void _dismissTopNestedPopup() {
    _popNestedPopupAt(_popup.lastVisibleIndex);
  }

  void _popNestedPopupAt(int index) {
    popNestedPopupAt(index, _popup);
  }

  Widget _buildNestedPopupLayer(int index, Size screen) {
    return buildNestedPopupLayer(
      index: index,
      screen: screen,
      controller: _popup,
      onPush: (text, rect) => _pushNestedPopup(text, rect),
      onPop: _popNestedPopupAt,
    );
  }

  // ── dialogs ────────────────────────────────────────────────────────

  void _showDeleteDictionaryHistoryPrompt() async {
    await showAppDialog(
      context: context,
      builder: (context) => HomeDictionaryClearHistoryDialog(
        onConfirm: () async {
          Navigator.pop(context);
          await appModel.clearDictionaryHistory();
          if (mounted) setState(() {});
        },
      ),
    );
  }
}

@visibleForTesting
class HomeDictionaryClearHistoryDialog extends StatelessWidget {
  const HomeDictionaryClearHistoryDialog({
    required this.onConfirm,
    super.key,
  });

  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      child: FushiModalSheetFrame(
        title: t.clear_dictionary_title,
        leadingIcon: Icons.delete_sweep_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          t.clear_dictionary_description,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              child: Text(t.dialog_cancel),
              onPressed: () => Navigator.pop(context),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              child: Text(t.dialog_clear),
              onPressed: onConfirm,
            ),
          ],
        ),
      ),
    );
  }
}
