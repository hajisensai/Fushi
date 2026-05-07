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

  static const double _popupPadding = 6.0;
  static const double _popupMaxWidth = 360.0;
  static const double _popupMaxHeight = 480.0;

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

  Rect _calcPosition(Rect sel, Size screen) {
    final double width =
        (screen.width - _popupPadding * 2).clamp(0, _popupMaxWidth);
    final double height = (screen.height * 0.5).clamp(0, _popupMaxHeight);

    final double spaceBelow = screen.height - sel.bottom - _popupPadding;
    final double spaceAbove = sel.top - _popupPadding;
    final bool showBelow = spaceBelow >= height || spaceBelow >= spaceAbove;

    double top;
    if (showBelow) {
      top = sel.bottom + 4;
    } else {
      top = sel.top - 4 - height;
    }
    top = top.clamp(_popupPadding, screen.height - height - _popupPadding);

    double left = sel.left;
    left = left.clamp(_popupPadding, screen.width - width - _popupPadding);

    return Rect.fromLTWH(left, top, width, height);
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final screen =
                  Size(constraints.maxWidth, constraints.maxHeight);
              return _buildStack(context, screen);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildStack(BuildContext context, Size screen) {
    if (_stack.isEmpty) {
      return const SizedBox.shrink();
    }

    return Stack(
      children: [
        for (int i = 0; i < _stack.length; i++)
          _buildLayer(context, i, screen),
      ],
    );
  }

  Widget _buildLayer(BuildContext context, int index, Size screen) {
    final entry = _stack[index];

    final bool isFirst = index == 0;
    final Rect pos;

    if (isFirst) {
      pos = Rect.fromLTWH(0, 0, screen.width, screen.height);
    } else {
      final parentEntry = _stack[index - 1];
      final parentPos = isFirst
          ? Rect.fromLTWH(0, 0, screen.width, screen.height)
          : _getLayerPosition(index - 1, screen);
      final absRect = entry.selectionRect.shift(
          Offset(parentPos.left, parentPos.top));
      pos = _calcPosition(absRect, screen);
    }

    final isDark =
        (appModel.overrideDictionaryTheme ?? Theme.of(context)).brightness ==
            Brightness.dark;
    final fillColor = isDark ? Colors.black : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.18);

    return Positioned(
      left: pos.left,
      top: pos.top,
      width: pos.width,
      height: pos.height,
      child: Container(
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: _buildEntryContent(entry, index, screen),
      ),
    );
  }

  Rect _getLayerPosition(int index, Size screen) {
    if (index == 0) {
      return Rect.fromLTWH(0, 0, screen.width, screen.height);
    }
    final entry = _stack[index];
    final parentPos = _getLayerPosition(index - 1, screen);
    final absRect =
        entry.selectionRect.shift(Offset(parentPos.left, parentPos.top));
    return _calcPosition(absRect, screen);
  }

  Widget _buildEntryContent(_StackEntry entry, int index, Size screen) {
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
      onTextSelected: (text, localRect) {
        final layerPos = _getLayerPosition(index, screen);
        final absRect = localRect.shift(Offset(layerPos.left, layerPos.top));
        _stack.sublist(index + 1).forEach((_) {});
        if (_stack.length > index + 1) {
          setState(() {
            _stack.removeRange(index + 1, _stack.length);
          });
        }
        _pushSearch(text, localRect);
      },
      onLinkClick: (query) {
        if (_stack.length > index + 1) {
          setState(() {
            _stack.removeRange(index + 1, _stack.length);
          });
        }
        _pushSearch(query, entry.selectionRect);
      },
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
