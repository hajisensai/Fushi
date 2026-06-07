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

  String _statTodayKey() {
    final DateTime d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

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
        unawaited(_recordMined());
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
      await TtsChannel.instance.playAudioRef(url);
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
  Future<void> _recordMined() async {
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
  /// [popupStack].
  Widget buildNestedPopupLayer({
    required int index,
    required Size screen,
    required List<DictionaryPopupEntry> popupStack,
    required void Function(String text, Rect selectionRect) onPush,
    required void Function(int index) onPop,
  }) {
    final DictionaryPopupEntry entry = popupStack[index];
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
    return Positioned(
      left: pos.left,
      top: pos.top,
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
              : () => loadMoreForEntry(entry: entry, popupStack: popupStack),
          onTextSelected: (text, localRect) {
            final Rect childRect = localRect == Rect.zero
                ? entry.selectionRect
                : localRect.shift(Offset(pos.left, pos.top));
            setState(() {
              popupStack.removeRange(index + 1, popupStack.length);
            });
            onPush(text, childRect);
          },
          onLinkClick: (query, localRect) {
            final Rect childRect = localRect == Rect.zero
                ? entry.selectionRect
                : localRect.shift(Offset(pos.left, pos.top));
            setState(() {
              popupStack.removeRange(index + 1, popupStack.length);
            });
            onPush(query, childRect);
          },
          onMineEntry: onMineEntry,
          onDuplicateCheck: checkDuplicate,
          onFavoriteEntry: onFavoriteEntry,
          onFavoriteCheck: onFavoriteCheck,
        ),
      ),
    );
  }

  /// Searches [query] and pushes a new [DictionaryPopupEntry] onto [popupStack].
  ///
  /// If [replaceStack] is true the existing stack is cleared first.
  /// If [autoRead] is true and results are found, the first entry's audio is
  /// played automatically.
  Future<void> pushNestedPopup({
    required String query,
    required Rect selectionRect,
    required List<DictionaryPopupEntry> popupStack,
    bool replaceStack = false,
    bool autoRead = false,
    bool reuseWarmSlot = false,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final Stopwatch swPush = Stopwatch()..start();
    final int maxTerms = mixinAppModel.maximumTerms;
    final DictionaryPopupEntry entry;
    if (reuseWarmSlot && popupStack.isNotEmpty && popupStack.first.isWarmSlot) {
      // BUG-094: reuse the persistent warm slot's already-loaded WebView in
      // place (reset its fields, drop nested children) instead of clearing the
      // stack + building a fresh entry — that recreated the WebView and
      // cold-loaded popup.html/JS/CSS on every lookup (the white flash).
      entry = popupStack.first
        ..searchTerm = trimmed
        ..selectionRect = fallbackSelectionRect(selectionRect)
        ..result = null
        ..allLoaded = false
        ..isSearching = true
        ..visible = true;
      setState(() {
        if (popupStack.length > 1) {
          popupStack.removeRange(1, popupStack.length);
        }
      });
    } else {
      entry = DictionaryPopupEntry(
        searchTerm: trimmed,
        selectionRect: fallbackSelectionRect(selectionRect),
      )..isSearching = true;
      setState(() {
        if (replaceStack) popupStack.clear();
        popupStack.add(entry);
      });
    }
    try {
      entry.result = await mixinAppModel.searchDictionary(
        searchTerm: trimmed,
        searchWithWildcards: true,
        overrideMaximumTerms: maxTerms,
      );
      entry.allLoaded = (entry.result?.entries.length ?? 0) < maxTerms;
      debugPrint('[dict-perf] pushNestedPopup search done in '
          '${swPush.elapsedMilliseconds}ms reuseWarm=$reuseWarmSlot '
          'entries=${entry.result?.entries.length ?? 0} "$trimmed"');
    } finally {
      if (mounted && popupStack.contains(entry)) {
        setState(() => entry.isSearching = false);
      }
    }
    if (!mounted || !popupStack.contains(entry)) return;
    final DictionarySearchResult? result = entry.result;
    if (result != null && result.entries.isNotEmpty) {
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
    required List<DictionaryPopupEntry> popupStack,
  }) async {
    if (entry.allLoaded || entry.isSearching || entry.result == null) return;
    final int current = entry.result!.entries.length;
    final int newMax = current + mixinAppModel.maximumTerms;
    setState(() => entry.isSearching = true);
    try {
      entry.result = await mixinAppModel.searchDictionary(
        searchTerm: entry.searchTerm,
        searchWithWildcards: true,
        overrideMaximumTerms: newMax,
      );
      entry.allLoaded = (entry.result?.entries.length ?? 0) < newMax;
    } finally {
      if (mounted && popupStack.contains(entry)) {
        setState(() => entry.isSearching = false);
      }
    }
  }

  /// Pops the popup at [index].
  ///
  /// When [index] is 0 the entire stack is cleared; otherwise all entries from
  /// [index] onward are removed.
  void popNestedPopupAt(int index, List<DictionaryPopupEntry> popupStack) {
    if (index < 0 || index >= popupStack.length) return;
    setState(() {
      if (index == 0) {
        popupStack.clear();
      } else {
        popupStack.removeRange(index, popupStack.length);
      }
    });
  }
}
