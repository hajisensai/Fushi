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

  AppModel get appModel => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pushSearch(widget.searchTerm, Rect.zero);
    });
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
    }
  }

  void _popAt(int index) {
    if (index <= 0) return;
    setState(() => _stack.removeRange(index, _stack.length));
  }

  Future<void> _close() async {
    if (_isClosing) return;
    _isClosing = true;
    await appModel.closeForPopup();
    await PopupChannel.instance.finishPopup();
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final screen = Size(constraints.maxWidth, constraints.maxHeight);
              return _buildStack(context, screen);
            },
          ),
        ),
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
