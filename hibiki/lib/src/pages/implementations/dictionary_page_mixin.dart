import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart'
    show kStatSourceBook, kStatSourceVideo;
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/anki_mined_card_action_sheet.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/pages/base_source_page.dart'
    show lookupHighlightCharCount;
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult, DictionaryPopupWebViewState;
import 'package:fushi/src/pages/implementations/sentence_context_dialog.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart';
import 'package:fushi/src/utils/misc/lookup_auto_read_coordinator.dart';
import 'package:fushi/utils.dart';

// 弹窗条目统一为共享的 [DictionaryPopupEntry]（见 dictionary_popup_controller.dart）；
// 旧的 NestedPopupEntry / _PopupStackItem 两份重复类型已收口为它一个。

/// 搜索期加载占位卡（[DictionaryPageMixin.buildPopupLoadingPlaceholder]）在宿主 Stack
/// 里的稳定身份 key。与 reader 车道 `base-source-popup-loading-placeholder` 同用途，
/// 也是 BUG-1364 行为测试定位该层的锚点。
const ValueKey<String> kLookupSearchPlaceholderKey =
    ValueKey<String>('mixin-popup-loading-placeholder');

/// Non-generic mixin that consolidates the popup stack management, Anki mining,
/// and audio auto-read logic shared across PopupDictionaryPage
/// and HomeDictionaryPage.
///
/// No `on` constraint is used so it can be applied to all three state classes
/// regardless of their different base class hierarchies.
mixin DictionaryPageMixin {
  // ---------------------------------------------------------------------------
  // Abstract members — satisfied by State / ConsumerState superclass
  // ---------------------------------------------------------------------------

  WidgetRef get ref;
  bool get mounted;
  BuildContext get context;
  void setState(VoidCallback fn);

  // ---------------------------------------------------------------------------
  // Abstract members — subclass must provide explicitly
  // ---------------------------------------------------------------------------

  /// The AppModel instance. Each page accesses it differently, so the subclass
  /// exposes it through this getter.
  AppModel get mixinAppModel;

  /// The active ThemeData. Used to determine dark/light mode for popups.
  ThemeData get mixinTheme;

  /// 收藏/制卡计入统计时的来源标识。默认 [kStatSourceBook]（书内阅读、独立查词页
  /// 都归书籍统计）；视频页覆写为 [kStatSourceVideo]，使收藏/制卡落各自统计。
  String get dictionarySourceType => kStatSourceBook;

  /// BUG-1269：本页的快捷键作用域。非空即启用「弹窗内输入交回宿主」的桥。
  ///
  /// 词典弹窗是纯原生 WebView：指针落在它上面时，键盘与鼠标事件只存在于弹窗 DOM
  /// 里，宿主的 Flutter `Focus` / `Listener` 一个都收不到。点词后弹窗恰好贴在光标旁，
  /// 所以这是常态——不装这座桥，「关掉词典」的键与鼠标键在弹窗持焦时全部落空。
  ///
  /// 与 `BaseSourcePage` 的同名钩子是同一套契约（两个宿主各建一次
  /// [DictionaryPopupLayer]，此处保持对称）。
  ShortcutScope? get dictionaryPopupInputScope => null;

  /// 弹窗可见时仍要生效的动作。token 表由注册表**当前**绑定实时导出，改键立即跟随。
  Set<ShortcutAction> get dictionaryPopupForwardedActions =>
      const <ShortcutAction>{};

  /// 当前要下发给弹窗的输入表。作用域缺席时为空表——空表**仍会**注入，用来清掉热槽
  /// WebView 上残留的旧表。
  DictionaryPopupInputSpec get dictionaryPopupInputSpec =>
      dictionaryPopupInputScope == null
          ? const DictionaryPopupInputSpec()
          : dictionaryPopupInputSpecFor(
              registry: mixinAppModel.shortcutRegistry,
              actions: dictionaryPopupForwardedActions,
            );

  /// 弹窗回传 token 的落地点。
  ///
  /// 默认 no-op：本 mixin 的关栈入口（[popNestedPopupAt]）需要调用方持有的
  /// [DictionaryPopupController]，mixin 自身拿不到，故不在这里替宿主决定怎么关。
  /// 声明了 [dictionaryPopupInputScope] 的宿主必须覆写它（视频页覆写成「只关顶层」，
  /// 与 `guardVideoShortcutsWithPopupDismiss` 同一执行体）。用
  /// [resolveDictionaryPopupInputToken] 把 token 解析成动作——那与键盘路径是同一个
  /// `resolve*`，改键对两条路径同时生效。
  void onDictionaryPopupInputToken(String token) {}

  /// 查词浮层顶部可选的 header 行（如视频「收藏当前字幕句」星标）。默认 null（书内查词
  /// 已有自己的 [BaseSourcePageState.buildPopupAudioControls]，不走 mixin；独立查词页 /
  /// 词典页无句子概念，返回 null）。视频页覆写返回顶层（[index] == 0）的句子收藏星标，
  /// 注入到 [DictionaryPopupLayer.headerWidget]——嵌套递归查词层（index > 0）不属于某条
  /// 字幕句，覆写方应只对 index == 0 返回非 null。
  Widget? buildPopupHeaderFor(int index) => null;

  /// TODO-270 E「查词窗口多句合一制卡」(乙方案·视频车道)：弹窗「+句」追加当前正查句到
  /// 本表面会话级制卡草稿，返回累积句数（含本句）。默认 null = 不支持（纯查词页 / 首页
  /// 词典页无句子概念，不渲染「+句」）。视频页覆写返回非空闭包：把当前字幕句 + 其 cue
  /// 音频/画面区间推进 [MiningSentenceDraft]，制卡时合并成一张卡。
  ///
  /// 与 reader 车道（[BaseSourcePageState.supportsSentenceDraft] +
  /// [BaseSourcePageState.onAppendSentenceToDraft]）对称：reader 走 base_source_page
  /// 的弹窗构造，视频/首页查词走本 mixin 的 [buildNestedPopupLayer]，故各自有一个收口
  /// 入口；popup.js「+句」按钮、`appendSentence` JS 处理器、`MiningSentenceDraft` 草稿
  /// 模型三者均平台无关，两条车道共用。非空时弹窗才渲染「+句」（经
  /// `window.sentenceDraftEnabled`）。
  Future<int> Function()? get onAppendSentenceToDraft => null;

  /// TODO-393「上 N 句 / 下 N 句」上下文选择（视频/首页查词车道）：弹窗选「上 N 句 /
  /// 下 N 句」把当前正查句之前/之后的字幕 cue 作上下文**整体设置**进本表面草稿（不掺
  /// 历史累积），返回上下文句总数（上 N + 下 N）。默认 null = 不支持（纯查词页无 cue
  /// 上下文）。视频页覆写返回非空闭包：用 [VideoPlayerController.cues] 在当前 cue 前后
  /// 取 N 条。与 reader 车道（[BaseSourcePageState.onSetSentenceContextToDraft]）对称。
  Future<int> Function(int prevCount, int nextCount)?
      get onSetSentenceContextToDraft => null;

  /// TODO-382「+句」可撤销（视频车道）：弹窗点「清空已加句子」清掉本表面会话级制卡
  /// 草稿，返回清空后的句数（恒 0）。默认 null = 不支持（与 [onAppendSentenceToDraft]
  /// 对称，纯查词页不渲染清空入口）。视频页覆写返回非空闭包清掉 [MiningSentenceDraft]。
  Future<int> Function()? get onClearSentenceDraftToDraft => null;

  /// Niratan「制卡前调整·选择句子上下文」（视频/首页查词车道）：弹窗打开模态时拉取当前
  /// 草稿真实上下文句 + 当前正查句 + 词偏移做预览。默认 null = 不支持（纯查词页无草稿）。
  /// 视频页覆写返回非空闭包（[buildSentenceContextPreview]）。与 reader 车道
  /// （[BaseSourcePageState.onSentenceContextPreviewFromDraft]）对称。
  Future<Map<String, Object?>> Function()?
      get onSentenceContextPreviewToDraft => null;

  /// BUG-797 / BUG-1040：有多少个「必须盖住查词弹窗」的 Flutter 对话框正开着。
  ///
  /// 查词弹窗是**原生平台视图**（桌面 WebView2 / Android platform view），靠 airspace 永远
  /// 画在 Flutter overlay 之上——任何 `showAppDialog` 弹出来的对话框都会被它盖住（用户报
  /// 「层级不对/看不见」）。这些对话框期间据此把弹窗 [parkedPopupLayer] 的 `visible` 强制
  /// 翻假 → 停靠屏外（BUG-135 停靠语义，webview 仍存活、回点制卡照常），让对话框独占屏幕。
  ///
  /// BUG-1040 从 bool 改成**计数**：制卡动作对话框里还能再叠一层 note viewer 对话框，用
  /// bool 会被内层的 `finally` 提前复位、外层对话框当场被弹窗盖住。计数天然支持嵌套。
  int _popupHidingDialogDepth = 0;

  /// 是否有「必须盖住查词弹窗」的对话框正开着（[runWithLookupPopupHidden] 期间为真）。
  ///
  /// BUG-1327：宿主页除了弹窗层本身，还会画**整屏 dismiss barrier**（点弹窗外面关栈）。
  /// 视频页把整棵浮层子树挂在**根 Overlay**（为了盖过 media_kit 全屏路由），而根 Overlay
  /// 里手动 `insert` 的 entry 永远排在 `showAppDialog` 推的路由之上——对话框看得见却点不
  /// 着：点击先被 barrier 吃掉，再被判成「点弹窗外面」直接清整栈。故 barrier 必须与
  /// [parkedPopupLayer] 的 `visible` 共用同一门控：对话框期间整棵浮层既不显示也不拦点击。
  @protected
  bool get lookupPopupHiddenByDialog => _popupHidingDialogDepth > 0;

  /// BUG-1040：在 [body] 执行期间把查词弹窗停靠屏外的统一入口（收口 setState 增减，杜绝
  /// 各调用点各写一份 try/finally 漏复位）。[body] 抛错时照常复位。
  Future<T> runWithLookupPopupHidden<T>(Future<T> Function() body) async {
    if (mounted) setState(() => _popupHidingDialogDepth++);
    try {
      return await body();
    } finally {
      if (mounted) {
        setState(() => _popupHidingDialogDepth =
            _popupHidingDialogDepth > 0 ? _popupHidingDialogDepth - 1 : 0);
      }
    }
  }

  /// BUG-763/766：视频/首页车道点某词条「调整上下文」→ 弹 **app 原生顶层对话框**
  /// （[SentenceContextDialog]，不再画在查词弹窗 WebView 内）。复用视频覆写的
  /// [onSentenceContextPreviewToDraft]/[onSetSentenceContextToDraft] 驱动预览+增减；
  /// 「确认制卡」回 [webViewKey] 那层弹窗精确点中第 [entryIndex] 个词条制卡按钮。
  Future<void> _openSentenceContextDialogForVideo({
    required GlobalKey<DictionaryPopupWebViewState> webViewKey,
    required int entryIndex,
    required String matched,
  }) async {
    final Future<Map<String, Object?>> Function()? preview =
        onSentenceContextPreviewToDraft;
    final Future<int> Function(int, int)? setter = onSetSentenceContextToDraft;
    if (preview == null || setter == null) return;
    // BUG-797：对话框期间把弹窗 WebView 停靠屏外，否则原生平台视图盖住对话框。
    await runWithLookupPopupHidden<void>(
      () => showAppDialog<void>(
        context: context,
        builder: (_) => SentenceContextDialog(
          matched: matched,
          fetchPreview: preview,
          setContext: setter,
          onConfirm: () =>
              webViewKey.currentState?.mineEntryByIndex(entryIndex),
        ),
      ),
    );
  }

  // 今日统计 dateKey 走 stat_activity 的权威实现（statTodayKey），不在此重复格式化。
  String _statTodayKey() => statTodayKey();

  // ---------------------------------------------------------------------------
  // Concrete helpers
  // ---------------------------------------------------------------------------

  /// Returns [rect] unchanged when it is non-zero, otherwise returns a tiny
  /// 1×1 rect at (12, 12) that avoids placement calculations breaking on zero.
  Rect fallbackSelectionRect(Rect rect) {
    if (rect != Rect.zero) return rect;
    return const Rect.fromLTWH(12, 12, 1, 1);
  }

  /// TODO-108：video 家族（及独立查词页 / 首页查词）查词弹窗位置计算的单一收口点——
  /// 等价于 base_source_page._calculatePopupPosition 之于 reader 家族。底部固定模式时
  /// 忽略选区位置返回屏幕底部全宽 dock 面板（[dockedPopupRect]），否则沿用原跟随逻辑
  /// （[calcPopupPosition]，尺寸随界面大小放大）。在共享 mixin 收口而非 video_hibiki_page，
  /// 一处分流即覆盖 buildNestedPopupLayer / buildPopupLoadingPlaceholder 两个调用点，且
  /// 不触碰 video 页本体。盒子尺寸口径与原两处一致（maxWidth/Height × appUiScale，padding
  /// 与 reserve 走 calcPopupPosition 默认 6/0）。
  Rect _calcMixinPopupPosition(Rect selectionRect, Size screen) {
    // 与 base_source_page._calculatePopupPosition 共用 [resolvePopupRect]。mixin
    // 家族（video/首页/texthooker）不预留 reserve、不竖排避让（全用默认），盒子尺寸
    // 随界面大小放大（同 base 的 popupMaxWidth/Height）。Phase B 拖把手时用预览态
    // [_popupResizePreview] 临时覆盖偏好实时预览（松手落库，见 [_onMixinPopupResizeEnd]）。
    final Rect anchored = resolvePopupRect(
      selectionRect: selectionRect,
      screen: screen,
      bottomDocked: mixinAppModel.popupBottomDocked,
      maxWidth: (_popupResizePreview?.width ?? mixinAppModel.popupMaxWidth) *
          mixinAppModel.appUiScale,
      maxHeight: (_popupResizePreview?.height ?? mixinAppModel.popupMaxHeight) *
          mixinAppModel.appUiScale,
    );
    // Phase B 拖拽尺寸（2026-07-15）：被拖的那张卡（选区匹配）冻结左上角，从右下生长，
    // 消除「词靠右缘时贴词定位把左缘左移」的 bug（同 base_source_page）。dock 模式不冻结。
    if (!mixinAppModel.popupBottomDocked &&
        _popupResizeAnchorTopLeft != null &&
        _popupResizeAnchorSelection == selectionRect) {
      return anchorPopupTopLeft(
        anchored: anchored,
        topLeft: _popupResizeAnchorTopLeft!,
        screen: screen,
        inset: 6.0,
      );
    }
    return anchored;
  }

  /// Phase B 尺寸拖拽的预览态（基准逻辑像素，未缩放）。非空 = 正在拖右下角把手；
  /// null = 未拖，用已落库真值。reader 家族的对应态在 [BaseSourcePageState]。
  LookupSize? _popupResizePreview;

  /// Phase B 拖拽尺寸的**冻结原点**（2026-07-15，同 base_source_page）：拖右下把手时把
  /// 弹窗左上角钉在拖拽起点、只往右下生长，持续到换词/关窗。[_popupResizeAnchorSelection]
  /// 记它属于哪张卡；[_topPopupAnchoredRect]/[_topPopupSelectionRect] 是供起手取当前左上角
  /// 的顶层卡缓存。
  Offset? _popupResizeAnchorTopLeft;
  Rect? _popupResizeAnchorSelection;
  Rect? _topPopupAnchoredRect;
  Rect? _topPopupSelectionRect;

  /// 拖把手起手：存当前偏好基准尺寸为预览起点，并冻结顶层卡当前左上角。
  void _onMixinPopupResizeStart() {
    setState(() {
      _popupResizePreview = LookupSize(
        mixinAppModel.popupMaxWidth,
        mixinAppModel.popupMaxHeight,
      );
      _popupResizeAnchorTopLeft = _topPopupAnchoredRect?.topLeft;
      _popupResizeAnchorSelection = _topPopupSelectionRect;
    });
  }

  /// 拖把手进行：盒坐标系增量位移 [deltaPx] 经 [resolveDraggedLookupSize] 折算回基准
  /// （除 appUiScale）并 clamp，驱动实时重建。
  void _onMixinPopupResizeUpdate(Offset deltaPx) {
    final LookupSize base = _popupResizePreview ??
        LookupSize(mixinAppModel.popupMaxWidth, mixinAppModel.popupMaxHeight);
    setState(() {
      _popupResizePreview = resolveDraggedLookupSize(
        currentBaseWidth: base.width,
        currentBaseHeight: base.height,
        deltaWidthPx: deltaPx.dx,
        deltaHeightPx: deltaPx.dy,
        uiScale: mixinAppModel.appUiScale,
      );
    });
  }

  /// 松手：预览尺寸一次性落偏好（`setPopupMaxWidth/Height`，与设置滑杆同源真值）后清空。
  void _onMixinPopupResizeEnd() {
    final LookupSize? committed = _popupResizePreview;
    setState(() => _popupResizePreview = null);
    if (committed != null) {
      mixinAppModel.setPopupMaxWidth(committed.width);
      mixinAppModel.setPopupMaxHeight(committed.height);
    }
  }

  /// 拖拽被竞技场中途取消：丢弃预览态回到「读真值」，不落偏好；一并撤销冻结原点（回贴词）。
  void _onMixinPopupResizeCancel() {
    if (_popupResizePreview == null) return;
    setState(() {
      _popupResizePreview = null;
      _popupResizeAnchorTopLeft = null;
      _popupResizeAnchorSelection = null;
    });
  }

  /// Mines the current dictionary entry to Anki.
  ///
  /// Shows a Fluttertoast for each outcome and returns `true` on success.
  /// 把统计来源标识（[kStatSourceBook]/[kStatSourceVideo]）映射成 [AnkiMiningSource]，
  /// 用于给制出的卡片追加分类标签（书籍→`book`，视频→`video`）。未知来源返回
  /// [AnkiMiningSource.book]（保守归书籍，与默认 [dictionarySourceType] 一致）。
  ///
  /// 可覆写（BUG-1137）：统计来源与制卡分类标签是两个维度——texthooker 页统计仍归
  /// 书籍桶，但制出的卡应打 `game` 分类标签，故覆写本 getter 而非动统计口径。
  @protected
  AnkiMiningSource get miningSource => dictionarySourceType == kStatSourceVideo
      ? AnkiMiningSource.video
      : AnkiMiningSource.book;

  Future<MinePopupResult> onMineEntry(Map<String, String> fields) async {
    final repo = ref.read(ankiRepositoryProvider);
    final miningContext = AnkiMiningContext(
      sentence: fields['sentence'] ?? '',
      source: miningSource,
    );
    // TODO-1325 #6：制卡可能要走网络（AnkiConnect）+ 下音频，先弹「制卡中…」蓝色
    // pending toast 给即时反馈；结果 toast 会顶替它。
    HibikiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    final outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    // 牌组名仅 success 需要（避免给失败分支白白 loadSettings）。
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    final described = describeMineOutcome(outcome, deckName: deckName);
    // 制卡成功计入统计（按来源 book/video）。失败不影响制卡结果，吞掉并记日志。
    if (described.record) unawaited(recordMined());
    // TODO-633: also land a mined-sentence history row. This mixin path serves
    // standalone/home lookup (no book context), so locator anchors stay null
    // (shown as non-navigable in collections, same as existing lookup-only).
    if (described.record) {
      unawaited(recordMinedSentence(fields, outcome.noteId));
    }
    // TODO-1325 #6：MD3 着色 + 图标 toast。着色状态由 describeMineOutcome 单一真相
    // 带出（added 绿 / duplicate 橙 / failed 红），此处不再本地 switch。
    HibikiToast.showMine(msg: described.message, status: described.status);
    if (described.success) {
      // TODO-270 D：带回 note id 让弹窗把刚制的这张标记为「最新可改」第三态
      // （AnkiConnect 非空，AnkiDroid 恒 null = 优雅降级进不了第三态）。
      return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
    }
    return const MinePopupResult();
  }

  /// TODO-270 D：覆盖「最新制的那张卡」（[noteId]）的字段——走 repo.updateMinedNote
  /// 按 id 真实覆盖（不删旧建新、不查重、不计入统计）。后端不支持覆盖（AnkiDroid）时
  /// repo 返回明确失败 → 这里弹 toast 提示，不崩。
  Future<MinePopupResult> onUpdateEntry(
    int noteId,
    Map<String, String> fields,
  ) async {
    final repo = ref.read(ankiRepositoryProvider);
    final miningContext = AnkiMiningContext(
      sentence: fields['sentence'] ?? '',
      source: miningSource,
    );
    // TODO-1325 #6：覆写同样先弹 pending。
    HibikiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    final outcome = await repo.updateMinedNote(
      noteId: noteId,
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    // 覆盖路径走收口的单一真相（overwrite=true → card_overwritten + 不记账）。
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    final described =
        describeMineOutcome(outcome, deckName: deckName, overwrite: true);
    // TODO-1325 #6：覆写成功也是 added（绿），失败按状态着色。状态取自单一真相。
    HibikiToast.showMine(msg: described.message, status: described.status);
    if (described.success) {
      return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
    }
    return const MinePopupResult();
  }

  /// Resolves and plays the audio for [expression] / [reading]. [popupState] is
  /// the just-rendered popup WebView (when this surface renders results in a
  /// popup): auto-read then plays through its own `<audio>` element — the unified
  /// fast path shared with the manual ♪ button and every surface. Null (e.g. an
  /// inline full-page view with no popup WebView) falls back to the Dart player.
  Future<void> autoReadWord(
    String expression,
    String reading, {
    DictionaryPopupWebViewState? popupState,
  }) async {
    await LookupAutoReadCoordinator.instance.runAutomatic(
      expression: expression,
      reading: reading,
      play: () => _playAutoReadWord(expression, reading, popupState),
    );
  }

  Future<bool> _playAutoReadWord(
    String expression,
    String reading,
    DictionaryPopupWebViewState? popupState,
  ) =>
      autoReadWordUnified(
        mixinAppModel,
        expression,
        reading,
        playInWebView: popupState?.playWordAudioUrl,
      );

  /// Checks whether a card for [expression] / [reading] already exists in Anki.
  Future<bool> checkDuplicate(String expression, String reading) async {
    final repo = ref.read(ankiRepositoryProvider);
    return repo.isDuplicate(expression, reading);
  }

  /// TODO-614：当用户把覆写范围设为「全部」（[AnkiOverwriteScope.all]）时，按与查重
  /// 同一条件反查一张可覆写的已存在 note id（多张取最近），让弹窗把更早的卡也标成
  /// 「最新可改」✓↩ 第三态、点它走 [onUpdateEntry] 按 id 覆写。范围为默认 latest 或
  /// 后端（AnkiDroid）拿不到 id 时回 null → 弹窗维持旧的两态行为（Never break userspace）。
  Future<int?> findOverwriteTargetNoteId(
    String expression,
    String reading,
  ) async {
    final repo = ref.read(ankiRepositoryProvider);
    return repo.findOverwriteTargetNoteId(expression, reading);
  }

  /// TODO-1007/1008：点 ✓（卡已存在）的编排入口（视频/首页/独立查词车道）。据当前
  /// 词条 [fields] 的 expression/reading 反查 Anki 全部命中卡，弹操作选择让用户选
  /// （覆写哪张 / 新增重复卡 / 查看·在 Anki 中打开），复用 [onMineEntry]/[onUpdateEntry]
  /// 执行，返回 [MinePopupResult] 刷新 ✓。与 reader 车道（base_source_page）对称。
  Future<MinePopupResult> onMinedCardAction(Map<String, String> fields) async {
    final repo = ref.read(ankiRepositoryProvider);
    final expression = fields['expression'] ?? '';
    final reading = fields['reading'] ?? '';
    final r = await runAnkiMinedCardAction(
      context: context,
      repo: repo,
      expression: expression,
      reading: reading,
      mineNew: () async {
        final res = await onMineEntry(fields);
        return (ankiConnect: res.ankiConnect, noteId: res.noteId);
      },
      overwrite: (noteId) async {
        final res = await onUpdateEntry(noteId, fields);
        return (ankiConnect: res.ankiConnect, noteId: res.noteId);
      },
      // BUG-1040：对话框期间停靠查词弹窗，否则原生平台视图盖住它（用户报「看不见」）。
      runHidden: runWithLookupPopupHidden,
    );
    return MinePopupResult(ankiConnect: r.ankiConnect, noteId: r.noteId);
  }

  /// TODO-1360：已制卡的词旁「在 Anki 中打开卡片」按钮的车道入口（视频/首页/独立查词，
  /// 与 reader 车道 [BaseSourcePageState.onOpenInAnkiFromPopup] 对称）。据 [expression]/
  /// [reading] 反查命中卡并直接跳转打开（单卡直开 / 多卡弹选择 / 无卡 toast）。
  Future<void> onOpenInAnki(String expression, String reading) async {
    final repo = ref.read(ankiRepositoryProvider);
    await openMinedCardInAnki(
      context: context,
      repo: repo,
      expression: expression,
      reading: reading,
      // BUG-1040：多卡选择框同样是 Flutter 层，期间停靠弹窗。
      runHidden: runWithLookupPopupHidden,
    );
  }

  /// 把一次成功制卡计入统计（按 [dictionarySourceType]）。
  ///
  /// 视频页等覆写 [onMineEntry]、绕过基类成功分支的页面，在自己的成功路径上
  /// 直接调本方法记账（来源仍走各自的 [dictionarySourceType]），不必复制
  /// [addMiningCount] 的契约细节。
  @protected
  Future<void> recordMined() async {
    final String dateKey = _statTodayKey();
    try {
      // 全局按日汇总（保留不动：备份合并 / 云同步依赖它，Never break userspace）。
      await mixinAppModel.database.addMiningCount(
        sourceType: dictionarySourceType,
        dateKey: dateKey,
      );
    } catch (e, st) {
      debugPrint('[fushi-stats] addMiningCount failed: $e\n$st');
    }
    // TODO-1204：并行写 per-book 制卡计数（视频带 bookUid+标题；无书来源 title=''）。
    final ({String? bookKey, String? title})? identity = lookupBookIdentity;
    try {
      await mixinAppModel.database.addMineCountPerBook(
        bookKey: identity?.bookKey,
        title: identity?.title ?? '',
        sourceType: dictionarySourceType,
        dateKey: dateKey,
      );
    } catch (e, st) {
      debugPrint('[fushi-stats] addMineCountPerBook failed: $e\n$st');
    }
  }

  /// TODO-1204：本次查词 / 制卡归属的书身份（[bookKey] + [title]）。视频页覆写返回
  /// (bookUid, 剧集标题)；无书来源（首页 / 独立查词窗 / 歌词）保持 null → 只进统计页
  /// 「查词」汇总，不落 per-book / per-video tile。[title] 与各统计页 tile 的 title
  /// 聚合键对齐。
  @protected
  ({String? bookKey, String? title})? get lookupBookIdentity => null;

  /// TODO-1204：[DictionaryPopupController.onLookupStarted] 注入点——每次查词
  /// （顶层 / 嵌套 / 重复查各一次）累加 [HibikiDatabase.addLookupCount]。宿主构造
  /// controller 后调 [attachLookupCounter] 接线。best-effort。
  @protected
  void recordLookup() {
    // best-effort：连同同步阶段（[mixinAppModel.database] late 字段 getter 在 DB 未
    // 初始化时会抛 LateInitializationError）一起吞掉——查词计数是旁路埋点，任何异常
    // 都不得打断弹窗查词流程。
    try {
      final ({String? bookKey, String? title})? identity = lookupBookIdentity;
      unawaited(mixinAppModel.database
          .addLookupCount(
        bookKey: identity?.bookKey,
        title: identity?.title ?? '',
        sourceType: dictionarySourceType,
        dateKey: _statTodayKey(),
      )
          .catchError((Object e, StackTrace st) {
        debugPrint('[fushi-stats] addLookupCount failed: $e\n$st');
      }));
    } catch (e, st) {
      debugPrint('[fushi-stats] addLookupCount failed (sync): $e\n$st');
    }
  }

  /// TODO-1204：把 [recordLookup] 挂到 [controller] 的查词开始回调上。各 mixin 宿主
  /// （视频 / 首页 / 独立查词窗 / texthooker / 歌词浮层）在 initState 构造 controller
  /// 后调用一次。
  @protected
  void attachLookupCounter(DictionaryPopupController controller) {
    controller.onLookupStarted = recordLookup;
  }

  /// TODO-633: land one mined-sentence history row (no book locator here —
  /// home/standalone lookup). Best-effort; failure is swallowed + logged.
  @protected
  Future<void> recordMinedSentence(
    Map<String, String> fields,
    int? noteId,
  ) async {
    try {
      await mixinAppModel.database.addMinedSentence(
        source: dictionarySourceType,
        dateKey: _statTodayKey(),
        expression: fields['expression'] ?? '',
        reading: fields['reading'] ?? '',
        glossary: fields['glossary'] ?? '',
        sentence: fields['sentence'] ?? '',
        noteId: noteId,
      );
    } catch (e, st) {
      debugPrint('[fushi-stats] addMinedSentence failed: $e\n$st');
    }
  }

  /// 切换收藏当前词条：已收藏则取消，否则收藏。返回切换后的新状态（true=已收藏）。
  /// 收藏按来源（book/video）落 DB，并计入各自统计。
  Future<bool> onFavoriteEntry(Map<String, String> fields) async {
    final String expression = fields['expression'] ?? '';
    final String reading = fields['reading'] ?? '';
    if (expression.isEmpty) return false;
    final db = mixinAppModel.database;
    final bool already = await db.isFavoriteWord(
      expression: expression,
      reading: reading,
      sourceType: dictionarySourceType,
    );
    if (already) {
      await db.removeFavoriteWord(
        expression: expression,
        reading: reading,
        sourceType: dictionarySourceType,
      );
      // TODO-956 A：与 [base_source_page] 同因——桌面 callHandler 返回值不一定回传
      // JS，弹窗 ☆→★ 变色不可靠。视频弹窗走本 mixin，DB 写成功后同样解耦弹 toast，
      // 保证 reader / 有声书 / 视频三宿主收藏反馈一致。
      HibikiToast.show(
        msg: t.word_favorite_removed,
        severity: ToastSeverity.success,
      );
      return false;
    }
    // TODO-1252：把当前书 / 视频身份（视频页覆写 lookupBookIdentity）随收藏落库，供
    // 统计页 per-book/video tile 聚合「收藏 N」；无书来源为 null / '' → 只进汇总。
    final ({String? bookKey, String? title})? favIdentity = lookupBookIdentity;
    await db.addFavoriteWord(
      expression: expression,
      reading: reading,
      glossary: fields['glossary'] ?? '',
      sourceType: dictionarySourceType,
      dateKey: _statTodayKey(),
      bookKey: favIdentity?.bookKey,
      title: favIdentity?.title ?? '',
    );
    HibikiToast.show(
      msg: t.word_favorite_added,
      severity: ToastSeverity.success,
    );
    return true;
  }

  /// 查询某词条当前是否已收藏（供弹窗按钮初始 ☆/★ 状态）。
  Future<bool> onFavoriteCheck(String expression, String reading) async {
    if (expression.isEmpty) return false;
    return mixinAppModel.database.isFavoriteWord(
      expression: expression,
      reading: reading,
      sourceType: dictionarySourceType,
    );
  }

  // ---------------------------------------------------------------------------
  // Popup stack management
  // ---------------------------------------------------------------------------

  /// Builds the [Positioned] popup layer widget for the entry at [index] in
  /// [controller].entries.
  Widget buildNestedPopupLayer({
    required int index,
    required Size screen,
    required DictionaryPopupController controller,
    required Future<int> Function(String text, Rect selectionRect) onPush,
    required void Function(int index) onPop,
  }) {
    final DictionaryPopupEntry entry = controller.entries[index];
    final Rect pos = _calcMixinPopupPosition(entry.selectionRect, screen);
    // Phase B 拖拽尺寸：缓存顶层卡当前 rect/选区，供 [_onMixinPopupResizeStart] 冻结左上角。
    if (index == controller.entries.length - 1) {
      _topPopupSelectionRect = entry.selectionRect;
      _topPopupAnchoredRect = pos;
    }
    final bool isDark =
        (mixinAppModel.overrideDictionaryTheme ?? mixinTheme).brightness ==
            Brightness.dark;
    // BUG-135 parking + Visibility 几何收口在 [parkedPopupLayer]。
    return parkedPopupLayer(
      // BUG-941：搜索占位层消失时本层会在 Stack children 中前移一位。若顶层
      // Positioned 无 key，Flutter 会按位置把「占位层的 Positioned」更新成本层、
      // 再销毁旧位置的平台 WebView；Windows 上最终只剩空白弹窗外壳。以 entry
      // 身份钉住整层，让元素真正搬位而不是拆建原生表面。
      key: ObjectKey(entry),
      pos: pos,
      // BUG-797 / BUG-1040：任何「必须盖住弹窗」的 Flutter 对话框（选择句子上下文 /
      // 已制卡动作 / 打开卡片选择）期间把弹窗停靠屏外，否则原生平台视图盖住对话框。
      visible: entry.visible && _popupHidingDialogDepth == 0,
      screen: screen,
      child: DictionaryPopupLayer(
        result: entry.result,
        isSearching: entry.isSearching,
        keepWebViewWarm: entry.isWarmSlot,
        webViewKey: entry.webViewKey,
        // TODO-869：本层有后代弹窗时注入 __hasChildPopup，点卡片本体留白才能关子窗。
        hasChildPopup: index < controller.entries.length - 1,
        isDark: isDark,
        overrideFillColor: mixinAppModel.overrideDictionaryColor,
        onDismiss: () => onPop(index),
        // BUG-1269：弹窗是原生 WebView，指针落上去后宿主收不到键盘/鼠标——把宿主
        // 声明的那些输入交回来（表由注册表当前绑定实时导出，改键立即跟随）。
        inputSpec: dictionaryPopupInputSpec,
        onHostInputToken: dictionaryPopupInputScope == null
            ? null
            : onDictionaryPopupInputToken,
        // TODO-407②：平台/偏好级"滑动关闭"开关（Windows/Linux 默认 false）。
        enableSwipeToClose: ReaderHibikiSource.instance.enableSwipeToClose,
        // TODO-407①：顶层仍渲染"X 关闭"，走既有关闭汇聚点 onPop(0)
        // （清整栈，不破坏 BUG-072 续播 / 清句 / 清栈）。
        onClose: () => onPop(index),
        // TODO-485：嵌套层即便禁用滑动关闭，也有显式返回父层入口。
        onBack: null,
        // Phase B：app 内弹窗右下角尺寸拖拽把手（video/首页/texthooker 共用此收口）。
        // 拖动 = 可视化改「最大宽高」偏好（与设置滑杆同一真值）；预览态在 mixin 级。
        showResizeGrip: true,
        onResizeStart: _onMixinPopupResizeStart,
        onResizeUpdate: _onMixinPopupResizeUpdate,
        onResizeEnd: _onMixinPopupResizeEnd,
        onResizeCancel: _onMixinPopupResizeCancel,
        // TODO-834：点**本层弹窗本体的空白区**只关该层衍生的后代层（index 更大的全部），
        // 保留本层 + 祖先。线性扁平栈里 index 即 depth，故后代 = `index+1..end`，用
        // [DictionaryPopupController.truncateTo] 精确裁。点本层无后代 = no-op 栈不变。
        // 不走 onPop（onPop(0) 是清整栈的会话级路径，仅 barrier / X 用）。
        onTapOutside: () => _dismissDescendantsOfLayer(index, controller),
        // TODO-058：该层 WebView 渲染完成 → 翻可见挂起的冷层（消除白屏一瞬）。
        // 仅当此层处于挂起态（markPendingReveal）才真翻可见并触发重建。
        onRendered: () {
          if (!mounted) return;
          if (controller.revealRendered(entry)) {
            controller.endSearchUi();
            setState(() {});
          }
          // 选词光标跟随（videoEnterCaret）：层渲染完成后交给页面钩子，视频页据此
          // 把光标 transfer 进刚显示的顶层弹窗（BaseSourcePageState 家族的
          // onDictionaryPopupRendered 同语义；mixin 家族此前没有该钩子）。
          onNestedPopupRendered(index);
        },
        // TODO-058 fail-safe：WebView 加载失败也走同一翻可见路径（不卡死）。
        onRenderError: () {
          if (!mounted) return;
          if (controller.revealRendered(entry)) {
            controller.endSearchUi();
            setState(() {});
          }
        },
        onScrolledToBottom: entry.allLoaded
            ? null
            : () => loadMoreForEntry(entry: entry, controller: controller),
        onTextSelected: (text, localRect) async {
          final Rect childRect = localRect == Rect.zero
              ? entry.selectionRect
              : popupWordScreenRect(
                  webViewKey: entry.webViewKey,
                  localRect: localRect,
                  fallback: entry.selectionRect,
                );
          setState(() => controller.truncateTo(index + 1));
          // TODO-1190: after the child search, mark the clicked word in THIS
          // (parent) card's WebView (parity with base_source_page reader family
          // — the mixin family video/首页/texthooker only truncate+onPush before,
          // so the source word was left unmarked). onPush returns the matched
          // char count (0 = no entries -> no highlight, preserving prior look).
          final int count = await onPush(text, childRect);
          if (count > 0) {
            entry.webViewKey.currentState?.highlightSelection(count);
          }
        },
        onLinkClick: (query, localRect) async {
          final Rect childRect = localRect == Rect.zero
              ? entry.selectionRect
              : popupWordScreenRect(
                  webViewKey: entry.webViewKey,
                  localRect: localRect,
                  fallback: entry.selectionRect,
                );
          setState(() => controller.truncateTo(index + 1));
          // TODO-1190: symmetric with onTextSelected — highlight the clicked
          // headword/link target in this parent card after the child search.
          final int count = await onPush(query, childRect);
          if (count > 0) {
            entry.webViewKey.currentState?.highlightSelection(count);
          }
        },
        onMineEntry: onMineEntry,
        onUpdateEntry: onUpdateEntry,
        onDuplicateCheck: checkDuplicate,
        onOverwriteTargetNoteId: findOverwriteTargetNoteId,
        onMinedCardAction: onMinedCardAction,
        onOpenInAnki: onOpenInAnki,
        onFavoriteEntry: onFavoriteEntry,
        onFavoriteCheck: onFavoriteCheck,
        // TODO-270 E：支持草稿的表面（视频覆写 [onAppendSentenceToDraft] 返回非空）
        // 才传回调 → popup 渲染「+句」累积；其余（纯查词/首页词典）传 null 不渲染。
        onAppendSentence: onAppendSentenceToDraft,
        onSetSentenceContext: onSetSentenceContextToDraft,
        onClearSentenceDraft: onClearSentenceDraftToDraft,
        onSentenceContextPreview: onSentenceContextPreviewToDraft,
        // BUG-763/766：点某词条「调整上下文」→ 弹 app 原生顶层对话框（不再画在弹窗
        // WebView 内）；确认制卡回该层 WebView 精确点中该词条制卡。
        onOpenSentenceContextModal: onSentenceContextPreviewToDraft != null
            ? (int entryIndex, String matched) =>
                _openSentenceContextDialogForVideo(
                  webViewKey: entry.webViewKey,
                  entryIndex: entryIndex,
                  matched: matched,
                )
            : null,
        headerWidget: buildPopupHeaderFor(index),
      ),
    );
  }

  /// 搜索期加载占位卡（「搜索→就绪才显示」模式）：在选中词 [rect] 处画一张与弹窗
  /// 同色的小卡 + 顶部进度条，全程不露空 WebView（与书内 base_source_page 同观感）。
  /// 宿主在 [DictionaryPopupController.isSearchingUi] 为真时渲染。
  ///
  /// BUG-1364（BUG-797/1040/1327 同族遗留）：本层此前**没接** [_popupHidingDialogDepth]。
  /// 三个走根 Overlay 的宿主（视频页 / 首页词典页 / texthooker）+ 常驻根 builder 的
  /// 悬浮歌词 host，整棵浮层子树都排在 `showAppDialog` 推的路由**之上**，所以对话框
  /// 打开期间浮层的三个组成部分必须一起让位：barrier（[shouldShowLookupDismissBarrier]）、
  /// 弹窗层（[parkedPopupLayer] 的 `visible`）都已接线，只剩这张占位卡漏了 → 对话框
  /// 期间只要再起一次**顶层**查词（[DictionaryPopupController.beginTop] 会把复用的热槽
  /// / 新目标置 `visible=false`，于是 `hasVisiblePopup` 变假、[pushNestedPopup] 进搜索
  /// 占位态），这张不透明小卡就画在对话框上面。异步触发真实存在：悬浮歌词是独立系统
  /// 窗口、texthooker / 全局查词的文本来自 app 外，都不受对话框模态遮罩约束。
  ///
  /// 与弹窗层不同，本层是**纯 Flutter widget**（无原生平台视图），故不需要
  /// [parkedPopupLayer] 的「停靠屏外」补偿——那套几何只为绕开平台视图无视 `Opacity` /
  /// `IgnorePointer` 的 airspace 行为。这里 [Visibility] 即可真正让位（不画、不吃点击），
  /// 且外层 [Positioned] 尺寸不变，宿主 Stack 的子项数与布局都不受影响。
  Widget buildPopupLoadingPlaceholder({
    required Rect rect,
    required Size screen,
  }) {
    final Rect pos = _calcMixinPopupPosition(rect, screen);
    final ColorScheme cs =
        (mixinAppModel.overrideDictionaryTheme ?? mixinTheme).colorScheme;
    final Color fill = mixinAppModel.overrideDictionaryColor ?? cs.surface;
    return Positioned(
      // 占位层的稳定 key（与弹窗层的 `ObjectKey(entry)` 配套，对齐 reader 车道的
      // `base-source-popup-loading-placeholder`）：barrier 插拔时 Stack 里的子项按 key
      // 匹配，占位层与弹窗层不会被按位置错配成对方（BUG-941 同族）。
      key: kLookupSearchPlaceholderKey,
      left: pos.left,
      top: pos.top,
      width: pos.width,
      height: pos.height,
      child: Visibility(
        // BUG-1364：与 [parkedPopupLayer] 的 `visible` 同源，纳入同一个嵌套安全计数。
        visible: _popupHidingDialogDepth == 0,
        child: HibikiPopupSurface(
          color: fill,
          child: Column(
            children: <Widget>[
              LinearProgressIndicator(
                backgroundColor: Colors.transparent,
                color: cs.primary,
                minHeight: 2.75,
              ),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      ),
    );
  }

  /// Searches [query] and opens a popup via [controller].
  ///
  /// Top-level lookups ([replaceStack] or [reuseWarmSlot]) reuse the warm slot /
  /// replace the stack; otherwise a nested child layer is pushed. The mixin
  /// All surfaces use the reader's model — **search → reveal only when results
  /// are ready** ([revealWhileSearching] `false`): the popup target stays hidden
  /// during the lookup and the host paints a lightweight loading placeholder at
  /// [DictionaryPopupController.pendingRect] (see [buildPopupLoadingPlaceholder]),
  /// so a blank/cold WebView is never shown. (Set [revealWhileSearching] `true`
  /// to keep the old reveal-during-search behaviour.) If [autoRead] is true and
  /// results are found, the first entry's audio is played automatically.
  Future<int> pushNestedPopup({
    required String query,
    required Rect selectionRect,
    required DictionaryPopupController controller,
    bool replaceStack = false,
    bool autoRead = false,
    bool reuseWarmSlot = false,
    bool revealWhileSearching = false,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return 0;
    final int maxTerms = mixinAppModel.maximumTerms;
    final Rect rect = fallbackSelectionRect(selectionRect);
    final DictionaryPopupEntry entry = controller.beginTop(
      term: trimmed,
      rect: rect,
      reuseWarmSlot: reuseWarmSlot,
      replaceStack: replaceStack,
      visible: revealWhileSearching,
      // 搜索期占位用与热槽 seed / DictionaryPopupLayer 兜底**同一个**单例：
      // 不传时 entry.result 为 null → 本帧 WebView 的 widget.result 落到
      // `result ?? kPopupSearchingPlaceholderResult` 兜底，但热槽停驻期的 seed
      // 若是另一个空结果实例，空→空的身份变化仍触发 didUpdateWidget 全量
      // renderPopup（先整卡画一遍 no-results，结果到达再画真内容——每次查词双倍
      // WebView 渲染）。单例恒等让搜索期 didUpdateWidget 天然 no-op，只在
      // fillResult 换成真结果时推一次。加载盖板仍由 isSearching 驱动，观感不变。
      initialResult: kPopupSearchingPlaceholderResult,
    );
    // 搜索期占位卡只在「顶层」查词时进入——与 reader base_source_page 的
    // `searching && !hasVisiblePopup` 门控对齐。嵌套查词时父弹窗仍可见，而三个 mixin
    // 宿主（video / 首页 / 悬浮歌词）的 Stack 里加载占位卡排在 entries **之前** =
    // 画在父弹窗**下方图层**，只从父弹窗底边露出一条，等子层 WebView 渲染完才在顶层
    // 翻出 → 用户看到「子弹窗先在底层、渲染后跳到上层」的层级翻转（BUG-715）。有可见
    // 弹窗时不进搜索占位态：父弹窗全程提供上下文，子层就绪即 markPendingReveal→
    // revealRendered 直接在顶层出现，无层级翻转（reveal 时序仍受 BUG-170 保护）。
    if (!controller.hasVisiblePopup) {
      controller.beginSearchUi(rect);
    }
    setState(() {});
    late final DictionarySearchResult result;
    try {
      result = await mixinAppModel.searchDictionary(
        searchTerm: trimmed,
        searchWithWildcards: true,
        overrideMaximumTerms: maxTerms,
      );
      if (mounted && controller.entries.contains(entry)) {
        setState(() {
          controller.fillResult(
            entry,
            result: result,
            allLoaded: result.entries.length < maxTerms,
          );
          // TODO-058 / BUG-480：真实空结果走 Flutter 占位，可立即显示；有词条/汉字卡
          // 的结果必须等当前 WebView render 信号，哪怕复用 warm slot。macOS 隐藏
          // warm slot 可能漏掉当前结果注入，直显会露出空白 WebView 壳。
          final bool needsWebViewRender =
              result.entries.isNotEmpty || result.kanjiResults.isNotEmpty;
          if (!needsWebViewRender) {
            controller.show(entry);
          } else {
            // TODO-058 fail-safe：mixin 宿主（视频/首页）不监听 controller，靠
            // setState 重建；超时强制翻可见后也要 setState（守 mounted，Timer 后触发）。
            controller.markPendingReveal(
              entry,
              onForcedReveal: () {
                controller.endSearchUi();
                if (mounted) setState(() {});
              },
            );
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted ||
                  !controller.entries.contains(entry) ||
                  !entry.revealOnRender) {
                return;
              }
              // refreshCurrentResult 已去重（同一结果不再全量重推）：返回 false
              // 表示当前结果已渲染完成、popupRendered 不会再来——立即走与
              // onRendered 相同的翻可见路径，不空等 failsafe。state 为 null 时
              // 维持等待，交给 failsafe。
              final bool renderPending =
                  entry.webViewKey.currentState?.refreshCurrentResult() ?? true;
              if (!renderPending && controller.revealRendered(entry)) {
                controller.endSearchUi();
                setState(() {});
              }
            });
          }
        });
      }
    } finally {
      if (mounted && controller.entries.contains(entry)) {
        setState(() {
          entry.isSearching = false;
          if (!entry.revealOnRender) {
            controller.endSearchUi();
          }
        });
      }
    }
    if (!mounted || !controller.entries.contains(entry)) return 0;
    if (result.entries.isNotEmpty) {
      mixinAppModel.addToSearchHistory(
        historyKey: DictionaryMediaType.instance.uniqueKey,
        searchTerm: trimmed,
      );
      mixinAppModel.addToDictionaryHistory(result: result);
      if (autoRead && ReaderHibikiSource.instance.autoReadOnLookup) {
        final first = result.entries.first;
        if (first.word.isNotEmpty) {
          autoReadWord(first.word, first.reading,
              popupState: entry.webViewKey.currentState);
        }
      }
    }
    // TODO-1190: matched char count so the caller (buildNestedPopupLayer's
    // onPush) can highlight the searched word in the PARENT card. 0 when no
    // entries matched — the caller then skips the highlight (unchanged look).
    return lookupHighlightCharCount(
      result: result,
      searchTerm: trimmed,
      language: JapaneseLanguage.instance,
    );
  }

  Future<void> loadMoreForEntry({
    required DictionaryPopupEntry entry,
    required DictionaryPopupController controller,
  }) async {
    if (entry.allLoaded || entry.isSearching || entry.result == null) return;
    final int current = entry.result!.entries.length;
    final int newMax = current + mixinAppModel.maximumTerms;
    setState(() => entry.isSearching = true);
    try {
      final DictionarySearchResult result =
          await mixinAppModel.searchDictionary(
        searchTerm: entry.searchTerm,
        searchWithWildcards: true,
        overrideMaximumTerms: newMax,
      );
      if (mounted && controller.entries.contains(entry)) {
        setState(() => controller.fillResult(
              entry,
              result: result,
              allLoaded: result.entries.length < newMax,
            ));
      }
    } finally {
      if (mounted && controller.entries.contains(entry) && entry.isSearching) {
        setState(() => entry.isSearching = false);
      }
    }
  }

  /// Pops the popup at [index] via [controller] (index 0 hides-and-keeps any
  /// warm slot / clears otherwise; deeper indices drop that layer and above).
  void popNestedPopupAt(int index, DictionaryPopupController controller) {
    if (index < 0 || index >= controller.entries.length) return;
    setState(() => controller.dismissAt(index));
  }

  /// TODO-834：关闭第 [index] 层**衍生的所有后代层**（index 更大的全部），保留本层
  /// + 祖先。线性扁平栈里 index 即 depth、无分叉，故后代 = `index+1..end`，用
  /// [DictionaryPopupController.truncateTo] 精确裁。点最顶层（无后代）= no-op 栈不变。
  /// 与基类 [BaseSourcePageState] 的同名 helper 同语义（mixin 路径不监听 controller，
  /// 故显式 setState 重建）。
  void _dismissDescendantsOfLayer(
    int index,
    DictionaryPopupController controller,
  ) {
    if (index < 0 || index >= controller.entries.length - 1) return; // 无后代
    setState(() => controller.truncateTo(index + 1));
  }

  /// 某弹窗层 WebView 渲染完成（reveal 之后）的可覆写钩子——mixin 家族版的
  /// [BaseSourcePageState.onDictionaryPopupRendered]。视频页覆写它把选词光标
  /// transfer 进刚显示的顶层弹窗（videoEnterCaret）；不覆写 = 历史行为不变。
  void onNestedPopupRendered(int index) {}
}
