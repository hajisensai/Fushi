import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/anki/anki_models.dart';
import 'package:hibiki/src/anki/anki_repository.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/utils/misc/popup_channel.dart';
import 'package:hibiki/utils.dart';

class _StackEntry {
  _StackEntry({required this.query, this.result, this.isSearching = true});
  final String query;
  DictionarySearchResult? result;
  bool isSearching;
  final GlobalKey<DictionaryPopupWebViewState> webViewKey =
      GlobalKey<DictionaryPopupWebViewState>();
}

class PopupDictionaryPage extends ConsumerStatefulWidget {
  const PopupDictionaryPage({
    required this.searchTerm,
    super.key,
  });

  final String searchTerm;

  @override
  ConsumerState<PopupDictionaryPage> createState() =>
      _PopupDictionaryPageState();
}

class _PopupDictionaryPageState extends ConsumerState<PopupDictionaryPage> {
  final List<_StackEntry> _stack = [];

  AppModel get appModel => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pushSearch(widget.searchTerm);
    });
  }

  Future<void> _pushSearch(String query) async {
    if (query.trim().isEmpty) return;

    final entry = _StackEntry(query: query);
    setState(() => _stack.add(entry));

    try {
      entry.result = await appModel.searchDictionary(
        searchTerm: query,
        searchWithWildcards: true,
        overrideMaximumTerms: appModel.maximumTerms,
      );
    } finally {
      if (mounted) {
        setState(() => entry.isSearching = false);
      }
    }

    if (!mounted) return;

    if (entry.result != null && entry.result!.entries.isNotEmpty) {
      appModel.addToSearchHistory(
        historyKey: DictionaryMediaType.instance.uniqueKey,
        searchTerm: query,
      );
      appModel.addToDictionaryHistory(result: entry.result!);
    }
  }

  bool _popStack() {
    if (_stack.length <= 1) return false;
    setState(() => _stack.removeLast());
    return true;
  }

  Future<void> _close() async {
    await appModel.closeForPopup();
    await PopupChannel.instance.finishPopup();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _popStack();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: _buildStack(context),
        ),
      ),
    );
  }

  Widget _buildStack(BuildContext context) {
    if (_stack.isEmpty) {
      return const SizedBox.shrink();
    }

    const double inset = 6.0;

    return Stack(
      children: [
        for (int i = 0; i < _stack.length; i++)
          Positioned(
            left: inset * i,
            top: inset * i,
            right: inset * i,
            bottom: inset * i,
            child: _buildLayer(context, i),
          ),
      ],
    );
  }

  Widget _buildLayer(BuildContext context, int index) {
    final isDark =
        (appModel.overrideDictionaryTheme ?? Theme.of(context)).brightness ==
            Brightness.dark;
    final fillColor = isDark ? Colors.black : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.18);
    final entry = _stack[index];

    return Container(
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildEntryContent(entry, index),
    );
  }

  Widget _buildEntryContent(_StackEntry entry, int index) {
    if (entry.isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (entry.result == null || entry.result!.entries.isEmpty) {
      return Center(
        child: JidoujishoPlaceholderMessage(
          icon: Icons.search_off,
          message: t.no_search_results,
        ),
      );
    }

    return DictionaryPopupWebView(
      key: entry.webViewKey,
      result: entry.result!,
      onTextSelected: (text, _) {
        _pushSearch(text);
      },
      onLinkClick: _pushSearch,
      onMineEntry: _onMineEntry,
      onDuplicateCheck: (expression, reading) async {
        final repo = ref.read(ankiRepositoryProvider);
        return repo.isDuplicate(expression, reading);
      },
    );
  }

  Future<bool> _onMineEntry(Map<String, String> fields) async {
    final repo = ref.read(ankiRepositoryProvider);
    final miningContext = AnkiMiningContext(
      sentence: fields['sentence'] ?? '',
    );
    final result = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    switch (result) {
      case MineResult.success:
        final settings = await repo.loadSettings();
        Fluttertoast.showToast(
          msg: t.card_exported(deck: settings.selectedDeckName ?? ''),
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
        );
        return true;
      case MineResult.duplicate:
        Fluttertoast.showToast(msg: t.card_duplicate);
        return false;
      case MineResult.notConfigured:
        Fluttertoast.showToast(msg: t.card_export_not_configured);
        return false;
      case MineResult.error:
        Fluttertoast.showToast(msg: t.card_export_failed);
        return false;
    }
  }
}
