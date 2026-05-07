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
  DictionarySearchResult? _result;
  bool _isSearching = false;
  late String _currentQuery;

  AppModel get appModel => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    _currentQuery = widget.searchTerm;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _search(_currentQuery);
    });
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;

    setState(() {
      _isSearching = true;
      _currentQuery = query;
    });

    try {
      _result = await appModel.searchDictionary(
        searchTerm: query,
        searchWithWildcards: true,
        overrideMaximumTerms: appModel.maximumTerms,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }

    if (!mounted) return;

    if (_result != null && _result!.entries.isNotEmpty) {
      appModel.addToSearchHistory(
        historyKey: DictionaryMediaType.instance.uniqueKey,
        searchTerm: query,
      );
      appModel.addToDictionaryHistory(result: _result!);
    }
  }

  Future<void> _close() async {
    await appModel.closeForPopup();
    await PopupChannel.instance.finishPopup();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final am = ref.watch(appProvider);

    Color? backgroundColor = theme.colorScheme.surface;
    if (am.overrideDictionaryColor != null) {
      final dictTheme = am.overrideDictionaryTheme ?? theme;
      if (dictTheme.brightness == Brightness.dark) {
        backgroundColor =
            JidoujishoColor.lighten(am.overrideDictionaryColor!, 0.025);
      } else {
        backgroundColor =
            JidoujishoColor.darken(am.overrideDictionaryColor!, 0.025);
      }
    }

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(theme, am),
            Expanded(child: _buildBody(am)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, AppModel am) {
    Color? headerBg = am.isDarkMode
        ? const Color.fromARGB(255, 30, 30, 30)
        : const Color.fromARGB(255, 229, 229, 229);
    if (am.overrideDictionaryColor != null) {
      final dictTheme = am.overrideDictionaryTheme ?? theme;
      if (dictTheme.brightness == Brightness.dark) {
        headerBg =
            JidoujishoColor.lighten(am.overrideDictionaryColor!, 0.05);
      } else {
        headerBg =
            JidoujishoColor.darken(am.overrideDictionaryColor!, 0.05);
      }
    }

    return Material(
      color: headerBg,
      child: SizedBox(
        height: kToolbarHeight,
        child: Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _currentQuery,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _close,
              tooltip: t.back,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppModel am) {
    if (_isSearching && _result == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_result == null || _result!.entries.isEmpty) {
      return Center(
        child: JidoujishoPlaceholderMessage(
          icon: Icons.search_off,
          message: t.no_search_results,
        ),
      );
    }

    return DictionaryPopupWebView(
      key: ValueKey(_result),
      result: _result!,
      onTextSelected: (text, _) {
        _search(text);
      },
      onLinkClick: _search,
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
