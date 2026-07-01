import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/utils/misc/lookup_audio_playback.dart';
import 'package:hibiki/src/utils/misc/lookup_auto_read_coordinator.dart';
import 'package:hibiki/utils.dart';

// 弹窗条目统一为共享的 [DictionaryPopupEntry]（见 dictionary_popup_controller.dart）；
// 旧的 NestedPopupEntry / _PopupStackItem 两份重复类型已收口为它一个。

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
    // 随界面大小放大（同 base 的 popupMaxWidth/Height）。
    return resolvePopupRect(
      selectionRect: selectionRect,
      screen: screen,
      bottomDocked: mixinAppModel.popupBottomDocked,
      maxWidth: mixinAppModel.popupMaxWidth * mixinAppModel.appUiScale,
      maxHeight: mixinAppModel.popupMaxHeight * mixinAppModel.appUiScale,
    );
  }

  /// Mines the current dictionary entry to Anki.
  ///
  /// Shows a Fluttertoast for each outcome and returns `true` on success.
  /// 把统计来源标识（[kStatSourceBook]/[kStatSourceVideo]）映射成 [AnkiMiningSource]，
  /// 用于给制出的卡片追加分类标签（书籍→`book`，视频→`video`）。未知来源返回
  /// [AnkiMiningSource.book]（保守归书籍，与默认 [dictionarySourceType] 一致）。
  AnkiMiningSource get _miningSource => dictionarySourceType == kStatSourceVideo
      ? AnkiMiningSource.video
      : AnkiMiningSource.book;

  Future<MinePopupResult> onMineEntry(Map<String, String> fields) async {
    final repo = ref.read(ankiRepositoryProvider);
    final miningContext = AnkiMiningContext(
      sentence: fields['sentence'] ?? '',
      source: _miningSource,
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
    HibikiToast.show(msg: described.message);
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
      source: _miningSource,
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
    HibikiToast.show(msg: described.message);
    if (described.success) {
      return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
    }
    return const MinePopupResult();
  }

  /// Resolves and plays the audio for [expression] / [reading] via
  /// [WordAudioResolver] + [TtsChannel].
  Future<void> autoReadWord(String expression, String reading) async {
    await LookupAutoReadCoordinator.instance.runAutomatic(
      expression: expression,
      reading: reading,
      play: () => _playAutoReadWord(expression, reading),
    );
  }

  Future<void> _playAutoReadWord(String expression, String reading) =>
      playLookupAudio(mixinAppModel, expression, reading);

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

  /// 把一次成功制卡计入统计（按 [dictionarySourceType]）。
  ///
  /// 视频页等覆写 [onMineEntry]、绕过基类成功分支的页面，在自己的成功路径上
  /// 直接调本方法记账（来源仍走各自的 [dictionarySourceType]），不必复制
  /// [addMiningCount] 的契约细节。
  @protected
  Future<void> recordMined() async {
    try {
      await mixinAppModel.database.addMiningCount(
        sourceType: dictionarySourceType,
        dateKey: _statTodayKey(),
      );
    } catch (e, st) {
      debugPrint('[hibiki-stats] addMiningCount failed: $e\n$st');
    }
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
      debugPrint('[hibiki-stats] addMinedSentence failed: $e\n$st');
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
      HibikiToast.show(msg: t.word_favorite_removed);
      return false;
    }
    await db.addFavoriteWord(
      expression: expression,
      reading: reading,
      glossary: fields['glossary'] ?? '',
      sourceType: dictionarySourceType,
      dateKey: _statTodayKey(),
    );
    HibikiToast.show(msg: t.word_favorite_added);
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
    required void Function(String text, Rect selectionRect) onPush,
    required void Function(int index) onPop,
  }) {
    final DictionaryPopupEntry entry = controller.entries[index];
    final Rect pos = _calcMixinPopupPosition(entry.selectionRect, screen);
    final bool isDark =
        (mixinAppModel.overrideDictionaryTheme ?? mixinTheme).brightness ==
            Brightness.dark;
    // BUG-135 parking + Visibility 几何收口在 [parkedPopupLayer]。
    return parkedPopupLayer(
      pos: pos,
      visible: entry.visible,
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
        // TODO-407②：平台/偏好级"滑动关闭"开关（Windows/Linux 默认 false）。
        enableSwipeToClose: ReaderHibikiSource.instance.enableSwipeToClose,
        // TODO-407①：顶层仍渲染"X 关闭"，走既有关闭汇聚点 onPop(0)
        // （清整栈，不破坏 BUG-072 续播 / 清句 / 清栈）。
        onClose: () => onPop(index),
        // TODO-485：嵌套层即便禁用滑动关闭，也有显式返回父层入口。
        onBack: null,
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
        onTextSelected: (text, localRect) {
          final Rect childRect = localRect == Rect.zero
              ? entry.selectionRect
              : popupWordScreenRect(
                  webViewKey: entry.webViewKey,
                  localRect: localRect,
                  fallback: entry.selectionRect,
                );
          setState(() => controller.truncateTo(index + 1));
          onPush(text, childRect);
        },
        onLinkClick: (query, localRect) {
          final Rect childRect = localRect == Rect.zero
              ? entry.selectionRect
              : popupWordScreenRect(
                  webViewKey: entry.webViewKey,
                  localRect: localRect,
                  fallback: entry.selectionRect,
                );
          setState(() => controller.truncateTo(index + 1));
          onPush(query, childRect);
        },
        onMineEntry: onMineEntry,
        onUpdateEntry: onUpdateEntry,
        onDuplicateCheck: checkDuplicate,
        onOverwriteTargetNoteId: findOverwriteTargetNoteId,
        onFavoriteEntry: onFavoriteEntry,
        onFavoriteCheck: onFavoriteCheck,
        // TODO-270 E：支持草稿的表面（视频覆写 [onAppendSentenceToDraft] 返回非空）
        // 才传回调 → popup 渲染「+句」累积；其余（纯查词/首页词典）传 null 不渲染。
        onAppendSentence: onAppendSentenceToDraft,
        onSetSentenceContext: onSetSentenceContextToDraft,
        onClearSentenceDraft: onClearSentenceDraftToDraft,
        headerWidget: buildPopupHeaderFor(index),
      ),
    );
  }

  /// 搜索期加载占位卡（「搜索→就绪才显示」模式）：在选中词 [rect] 处画一张与弹窗
  /// 同色的小卡 + 顶部进度条，全程不露空 WebView（与书内 base_source_page 同观感）。
  /// 宿主在 [DictionaryPopupController.isSearchingUi] 为真时渲染。
  Widget buildPopupLoadingPlaceholder({
    required Rect rect,
    required Size screen,
  }) {
    final Rect pos = _calcMixinPopupPosition(rect, screen);
    final ColorScheme cs =
        (mixinAppModel.overrideDictionaryTheme ?? mixinTheme).colorScheme;
    final Color fill = mixinAppModel.overrideDictionaryColor ?? cs.surface;
    return Positioned(
      left: pos.left,
      top: pos.top,
      width: pos.width,
      height: pos.height,
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
  Future<void> pushNestedPopup({
    required String query,
    required Rect selectionRect,
    required DictionaryPopupController controller,
    bool replaceStack = false,
    bool autoRead = false,
    bool reuseWarmSlot = false,
    bool revealWhileSearching = false,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final Stopwatch swPush = Stopwatch()..start();
    final int maxTerms = mixinAppModel.maximumTerms;
    final Rect rect = fallbackSelectionRect(selectionRect);
    final DictionaryPopupEntry entry = controller.beginTop(
      term: trimmed,
      rect: rect,
      reuseWarmSlot: reuseWarmSlot,
      replaceStack: replaceStack,
      visible: revealWhileSearching,
    );
    // 搜索期占位：搜索→就绪才显示（reveal 模式）下，宿主据此画加载占位卡。
    controller.beginSearchUi(rect);
    setState(() {});
    late final DictionarySearchResult result;
    try {
      result = await mixinAppModel.searchDictionary(
        searchTerm: trimmed,
        searchWithWildcards: true,
        overrideMaximumTerms: maxTerms,
      );
      debugPrint('[dict-perf] pushNestedPopup search done in '
          '${swPush.elapsedMilliseconds}ms reuseWarm=$reuseWarmSlot '
          'entries=${result.entries.length} "$trimmed"');
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
              entry.webViewKey.currentState?.refreshCurrentResult();
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
    if (!mounted || !controller.entries.contains(entry)) return;
    if (result.entries.isNotEmpty) {
      mixinAppModel.addToSearchHistory(
        historyKey: DictionaryMediaType.instance.uniqueKey,
        searchTerm: trimmed,
      );
      mixinAppModel.addToDictionaryHistory(result: result);
      if (autoRead && ReaderHibikiSource.instance.autoReadOnLookup) {
        final first = result.entries.first;
        if (first.word.isNotEmpty) {
          autoReadWord(first.word, first.reading);
        }
      }
    }
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
}
