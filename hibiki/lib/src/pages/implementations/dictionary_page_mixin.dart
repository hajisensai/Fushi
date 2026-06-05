import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/utils.dart';

/// Shared popup entry used by all three dictionary page variants.
class NestedPopupEntry {
  NestedPopupEntry({required this.query, required this.selectionRect});
  final String query;
  final Rect selectionRect;
  DictionarySearchResult? result;
  bool isSearching = true;
  bool allLoaded = false;
  final GlobalKey<DictionaryPopupWebViewState> webViewKey =
      GlobalKey<DictionaryPopupWebViewState>();
}

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
    final result = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    switch (result) {
      case MineResult.success:
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
        HibikiToast.show(msg: t.card_export_failed);
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

  // ---------------------------------------------------------------------------
  // Popup stack management
  // ---------------------------------------------------------------------------

  /// Builds the [Positioned] popup layer widget for the entry at [index] in
  /// [popupStack].
  Widget buildNestedPopupLayer({
    required int index,
    required Size screen,
    required List<NestedPopupEntry> popupStack,
    required void Function(String text, Rect selectionRect) onPush,
    required void Function(int index) onPop,
  }) {
    final NestedPopupEntry entry = popupStack[index];
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
      child: DictionaryPopupLayer(
        result: entry.result,
        isSearching: entry.isSearching,
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
      ),
    );
  }

  /// Searches [query] and pushes a new [NestedPopupEntry] onto [popupStack].
  ///
  /// If [replaceStack] is true the existing stack is cleared first.
  /// If [autoRead] is true and results are found, the first entry's audio is
  /// played automatically.
  Future<void> pushNestedPopup({
    required String query,
    required Rect selectionRect,
    required List<NestedPopupEntry> popupStack,
    bool replaceStack = false,
    bool autoRead = false,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final entry = NestedPopupEntry(
      query: trimmed,
      selectionRect: fallbackSelectionRect(selectionRect),
    );
    final int maxTerms = mixinAppModel.maximumTerms;
    setState(() {
      if (replaceStack) popupStack.clear();
      popupStack.add(entry);
    });
    try {
      entry.result = await mixinAppModel.searchDictionary(
        searchTerm: trimmed,
        searchWithWildcards: true,
        overrideMaximumTerms: maxTerms,
      );
      entry.allLoaded = (entry.result?.entries.length ?? 0) < maxTerms;
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
    required NestedPopupEntry entry,
    required List<NestedPopupEntry> popupStack,
  }) async {
    if (entry.allLoaded || entry.isSearching || entry.result == null) return;
    final int current = entry.result!.entries.length;
    final int newMax = current + mixinAppModel.maximumTerms;
    setState(() => entry.isSearching = true);
    try {
      entry.result = await mixinAppModel.searchDictionary(
        searchTerm: entry.query,
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
  void popNestedPopupAt(int index, List<NestedPopupEntry> popupStack) {
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
