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
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
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

  /// Mines the current dictionary entry to Anki.
  ///
  /// Shows a Fluttertoast for each outcome and returns `true` on success.
  Future<bool> onMineEntry(Map<String, String> fields) async {
    final repo = ref.read(ankiRepositoryProvider);
    final miningContext = AnkiMiningContext(sentence: fields['sentence'] ?? '');
    final outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    switch (outcome.result) {
      case MineResult.success:
        // 制卡成功计入统计（按来源 book/video）。失败不影响制卡结果，吞掉并记日志。
        unawaited(recordMined());
        final settings = await repo.loadSettings();
        HibikiToast.show(
          msg: t.card_exported(deck: settings.selectedDeckName ?? ''),
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
        );
        return true;
      case MineResult.duplicate:
        HibikiToast.show(msg: t.card_duplicate);
        return false;
      case MineResult.notConfigured:
        HibikiToast.show(msg: t.card_export_not_configured);
        return false;
      case MineResult.error:
        HibikiToast.show(msg: logMineFailure(outcome));
        return false;
    }
  }

  /// Resolves and plays the audio for [expression] / [reading] via
  /// [WordAudioResolver] + [TtsChannel].
  Future<void> autoReadWord(String expression, String reading) async {
    try {
      final WordAudioResolver resolver = WordAudioResolver(
        queryLocalAudio: (expression, reading) async {
          try {
            return await TtsChannel.instance
                .queryLocalAudio(expression, reading)
                .timeout(const Duration(milliseconds: 500));
          } on TimeoutException {
            return null;
          }
        },
        queryLocalAudioByDbIndex: (expression, reading, dbIndex) async {
          try {
            return await TtsChannel.instance
                .queryLocalAudio(expression, reading, dbIndex: dbIndex)
                .timeout(const Duration(milliseconds: 500));
          } on TimeoutException {
            return null;
          }
        },
        extractLocalAudio: TtsChannel.instance.extractLocalAudio,
        queryRemoteAudio: (expression, reading) =>
            mixinAppModel.lookupRemoteAudio(
          expression,
          reading,
        ),
      );
      final String? url = await resolver.resolveConfigured(
        expression: expression,
        reading: reading,
        sources: mixinAppModel.audioSourceConfigs,
      );
      if (url == null || url.isEmpty) return;
      await TtsChannel.instance.playAudioRef(
        url,
        volume: ReaderHibikiSource.instance.lookupAudioVolumeGain,
      );
    } catch (e, st) {
      debugPrint('[hibiki-autoread] error: $e\n$st');
    }
  }

  /// Checks whether a card for [expression] / [reading] already exists in Anki.
  Future<bool> checkDuplicate(String expression, String reading) async {
    final repo = ref.read(ankiRepositoryProvider);
    return repo.isDuplicate(expression, reading);
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
      return false;
    }
    await db.addFavoriteWord(
      expression: expression,
      reading: reading,
      glossary: fields['glossary'] ?? '',
      sourceType: dictionarySourceType,
      dateKey: _statTodayKey(),
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
    required void Function(String text, Rect selectionRect) onPush,
    required void Function(int index) onPop,
  }) {
    final DictionaryPopupEntry entry = controller.entries[index];
    final Rect pos = calcPopupPosition(
      selectionRect: entry.selectionRect,
      screen: screen,
      // 盒子尺寸随界面大小放大（同 base_source_page.popupMaxWidth/Height）。
      maxWidth: mixinAppModel.popupMaxWidth * mixinAppModel.appUiScale,
      maxHeight: mixinAppModel.popupMaxHeight * mixinAppModel.appUiScale,
    );
    final bool isDark =
        (mixinAppModel.overrideDictionaryTheme ?? mixinTheme).brightness ==
            Brightness.dark;
    // BUG-135: 隐藏的常驻热槽（BUG-094，`visible:false`）若停在它算出的位置
    // （seed 时 selectionRect=Rect.zero → 屏幕左上一大片），其 Android `InAppWebView`
    // 是**原生平台视图**，即使被 [Visibility] 的 `Opacity(0)+IgnorePointer` 包住也
    // 照样截获触摸——`IgnorePointer` 只挡 Flutter 命中测试，挡不住原生 view → 盖住的
    // 视频控制条（顶栏/底栏）点击全被吃掉、毫无反应（手机特有，桌面 webview 无此问题）。
    // 把隐藏热槽**移到屏幕右外侧**（仍保持真实尺寸继续冷加载预热，宿主 Stack 用
    // `Clip.none` 不裁掉它），既不盖任何控件、又保留 BUG-094 的预热。可见（真查词）时
    // 用真实 pos，行为完全不变。
    final bool parked = !entry.visible;
    final double layerLeft = parked ? screen.width + 8 : pos.left;
    final double layerTop = parked ? 0 : pos.top;
    return Positioned(
      left: layerLeft,
      top: layerTop,
      width: pos.width,
      height: pos.height,
      // Hidden warm slot (BUG-094) stays in the tree (maintainState) with its
      // WebView mounted but not painted/interactive; flips visible on lookup.
      child: Visibility(
        visible: entry.visible,
        maintainState: true,
        maintainAnimation: true,
        maintainSize: true,
        child: DictionaryPopupLayer(
          result: entry.result,
          isSearching: entry.isSearching,
          keepWebViewWarm: entry.isWarmSlot,
          webViewKey: entry.webViewKey,
          isDark: isDark,
          overrideFillColor: mixinAppModel.overrideDictionaryColor,
          onDismiss: () => onPop(index),
          onTapOutside: () => onPop(0),
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
          onDuplicateCheck: checkDuplicate,
          onFavoriteEntry: onFavoriteEntry,
          onFavoriteCheck: onFavoriteCheck,
          headerWidget: buildPopupHeaderFor(index),
        ),
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
    final Rect pos = calcPopupPosition(
      selectionRect: rect,
      screen: screen,
      maxWidth: mixinAppModel.popupMaxWidth * mixinAppModel.appUiScale,
      maxHeight: mixinAppModel.popupMaxHeight * mixinAppModel.appUiScale,
    );
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
          controller.show(entry);
        });
      }
    } finally {
      if (mounted && controller.entries.contains(entry)) {
        setState(() {
          entry.isSearching = false;
          controller.endSearchUi();
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
}
