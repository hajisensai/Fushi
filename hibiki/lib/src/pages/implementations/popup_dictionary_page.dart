import 'dart:async';
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
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/utils/misc/popup_channel.dart';
import 'package:hibiki/utils.dart';

class _StackEntry {
  _StackEntry({required this.query, required this.selectionRect});
  final String query;
  final Rect selectionRect;
  DictionarySearchResult? result;
  bool isSearching = true;
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
  bool _isClosing = false;

  static const double _padding = 6.0;
  static const double _maxWidth = 360.0;
  static const double _maxHeight = 480.0;

  late final TextEditingController _searchController;
  final FocusNode _searchFocusNode = FocusNode();

  AppModel get appModel => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.searchTerm);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pushSearch(widget.searchTerm, Rect.zero);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _pushSearch(String query, Rect selectionRect) async {
    if (query.trim().isEmpty) return;

    final entry = _StackEntry(query: query, selectionRect: selectionRect);
    setState(() => _stack.add(entry));

    try {
      entry.result = await appModel.searchDictionary(
        searchTerm: query,
        searchWithWildcards: true,
        overrideMaximumTerms: appModel.maximumTerms,
      );
    } finally {
      if (mounted && _stack.contains(entry)) {
        setState(() => entry.isSearching = false);
      }
    }

    if (!mounted || !_stack.contains(entry)) return;

    if (entry.result != null && entry.result!.entries.isNotEmpty) {
      appModel.addToSearchHistory(
        historyKey: DictionaryMediaType.instance.uniqueKey,
        searchTerm: query,
      );
      appModel.addToDictionaryHistory(result: entry.result!);
      if (ReaderTtuSource.instance.autoReadOnLookup) {
        final first = entry.result!.entries.first;
        await _autoReadWord(first.word, first.reading);
      }
    }
  }

  Future<void> _autoReadWord(String expression, String reading) async {
    try {
      final WordAudioResolver resolver = WordAudioResolver(
        queryLocalAudio: (String expression, String reading) async {
          try {
            return await TtsChannel.instance
                .queryLocalAudio(expression, reading)
                .timeout(const Duration(milliseconds: 500));
          } on TimeoutException {
            return null;
          }
        },
        extractLocalAudio: TtsChannel.instance.extractLocalAudio,
      );
      final String? url = await resolver.resolve(
        expression: expression,
        reading: reading,
        sources: appModel.enabledAudioSources,
      );
      if (url == null || url.isEmpty) return;

      if (url.startsWith('file://')) {
        await TtsChannel.instance.playFile(url.replaceFirst('file://', ''));
      } else if (url.startsWith('/')) {
        await TtsChannel.instance.playFile(url);
      } else if (url.startsWith('http')) {
        await TtsChannel.instance.playUrl(url);
      }
    } catch (e, st) {
      debugPrint('[hibiki-popup-audio] auto-read failed: $e\n$st');
    }
  }

  void _popAt(int index) {
    if (index <= 0) return;
    setState(() => _stack.removeRange(index, _stack.length));
  }

  Future<void> _close() async {
    if (_isClosing) return;
    _isClosing = true;
    await PopupChannel.instance.finishPopup();
  }

  void _onSearchSubmit(String text) {
    if (text.trim().isEmpty) return;
    _searchFocusNode.unfocus();
    setState(() => _stack.clear());
    _pushSearch(text.trim(), Rect.zero);
  }

  Rect _layerPosition(int index, Size screen) {
    if (index == 0) {
      return Rect.fromLTWH(0, 0, screen.width, screen.height);
    }
    final entry = _stack[index];
    final parentPos = _layerPosition(index - 1, screen);
    final absRect =
        entry.selectionRect.shift(Offset(parentPos.left, parentPos.top));
    return calcPopupPosition(
      selectionRect: absRect,
      screen: screen,
      padding: _padding,
      maxWidth: _maxWidth,
      maxHeight: _maxHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark =
        (appModel.overrideDictionaryTheme ?? Theme.of(context)).brightness ==
            Brightness.dark;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_stack.length > 1) {
          _popAt(_stack.length - 1);
        } else {
          _close();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              _buildSearchBar(isDark),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final screen =
                        Size(constraints.maxWidth, constraints.maxHeight);
                    return _buildStack(context, screen);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    final fillColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.18);
    final textColor = isDark ? Colors.white : Colors.black;
    final hintColor = isDark ? Colors.white54 : Colors.black45;

    return Container(
      margin: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              style: TextStyle(color: textColor, fontSize: 14),
              decoration: InputDecoration(
                hintText: t.search,
                hintStyle: TextStyle(color: hintColor, fontSize: 14),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: InputBorder.none,
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: _onSearchSubmit,
            ),
          ),
          SizedBox(
            width: 36,
            height: 36,
            child: IconButton(
              icon: Icon(Icons.search, color: hintColor, size: 20),
              padding: EdgeInsets.zero,
              onPressed: () => _onSearchSubmit(_searchController.text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStack(BuildContext context, Size screen) {
    if (_stack.isEmpty) return const SizedBox.shrink();

    return Stack(
      children: [
        for (int i = 0; i < _stack.length; i++) _buildLayer(context, i, screen),
      ],
    );
  }

  Widget _buildLayer(BuildContext context, int index, Size screen) {
    final entry = _stack[index];
    final pos = _layerPosition(index, screen);
    final isDark =
        (appModel.overrideDictionaryTheme ?? Theme.of(context)).brightness ==
            Brightness.dark;

    return Positioned(
      left: pos.left,
      top: pos.top,
      width: pos.width,
      height: pos.height,
      child: DictionaryPopupLayer(
        result: entry.isSearching ? null : entry.result,
        webViewKey: entry.webViewKey,
        isDark: isDark,
        onDismiss: () {
          if (index == 0) {
            _close();
          } else {
            _popAt(index);
          }
        },
        onTextSelected: (text, localRect) {
          if (_stack.length > index + 1) {
            setState(() => _stack.removeRange(index + 1, _stack.length));
          }
          final parentPos = _layerPosition(index, screen);
          final childRect = localRect == Rect.zero
              ? entry.selectionRect
              : localRect.shift(Offset(parentPos.left, parentPos.top));
          _pushSearch(text, childRect);
        },
        onLinkClick: (query, localRect) {
          if (_stack.length > index + 1) {
            setState(() => _stack.removeRange(index + 1, _stack.length));
          }
          final parentPos = _layerPosition(index, screen);
          final childRect = localRect == Rect.zero
              ? entry.selectionRect
              : localRect.shift(Offset(parentPos.left, parentPos.top));
          _pushSearch(query, childRect);
        },
        onMineEntry: _onMineEntry,
        onDuplicateCheck: (expression, reading) async {
          final repo = ref.read(ankiRepositoryProvider);
          return repo.isDuplicate(expression, reading);
        },
      ),
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
