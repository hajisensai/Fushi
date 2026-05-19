import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/utils/misc/popup_channel.dart';
import 'package:hibiki/utils.dart';

class PopupDictionaryPage extends ConsumerStatefulWidget {
  const PopupDictionaryPage({
    required this.searchTerm,
    this.closeInApp,
    this.autoSearchOnOpen = true,
    super.key,
  });

  final String searchTerm;
  final VoidCallback? closeInApp;
  final bool autoSearchOnOpen;

  @override
  ConsumerState<PopupDictionaryPage> createState() =>
      _PopupDictionaryPageState();
}

class _PopupDictionaryPageState extends ConsumerState<PopupDictionaryPage>
    with DictionaryPageMixin {
  final List<NestedPopupEntry> _stack = [];
  bool _isClosing = false;

  late final TextEditingController _searchController;
  final FocusNode _searchFocusNode = FocusNode();

  AppModel get appModel => ref.read(appProvider);

  @override
  AppModel get mixinAppModel => appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.searchTerm);
    if (widget.autoSearchOnOpen && appModel.isInitialised) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _pushSearch(widget.searchTerm, Rect.zero);
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _pushSearch(String query, Rect selectionRect) {
    return pushNestedPopup(
      query: query,
      selectionRect: selectionRect,
      popupStack: _stack,
      autoRead: true,
    );
  }

  void _popAt(int index) {
    if (index <= 0) return;
    popNestedPopupAt(index, _stack);
  }

  Future<void> _close() async {
    if (_isClosing) return;
    _isClosing = true;
    final VoidCallback? closeInApp = widget.closeInApp;
    if (closeInApp != null) {
      closeInApp();
      return;
    }
    await PopupChannel.instance.finishPopup();
  }

  void _onSearchSubmit(String text) {
    if (text.trim().isEmpty) return;
    _searchFocusNode.unfocus();
    setState(_stack.clear);
    _pushSearch(text.trim(), Rect.zero);
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
          child: _buildOuterContainer(),
        ),
      ),
    );
  }

  Widget _buildOuterContainer() {
    final colorScheme = Theme.of(context).colorScheme;
    final fillColor = appModel.overrideDictionaryColor ?? colorScheme.surface;
    final borderColor = colorScheme.outlineVariant.withValues(alpha: 0.5);

    return Container(
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildSearchBar(),
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
    );
  }

  Widget _buildSearchBar() {
    return PopupDictionarySearchBar(
      controller: _searchController,
      focusNode: _searchFocusNode,
      onClose: widget.closeInApp == null ? null : _close,
      onSubmit: _onSearchSubmit,
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
    if (index > 0) {
      return buildNestedPopupLayer(
        index: index,
        screen: screen,
        popupStack: _stack,
        onPush: (text, rect) => _pushSearch(text, rect),
        onPop: _popAt,
      );
    }

    // index == 0: full-size base layer (popup-specific)
    final entry = _stack[0];
    final isDark =
        (appModel.overrideDictionaryTheme ?? Theme.of(context)).brightness ==
            Brightness.dark;
    return Positioned.fill(
      child: DictionaryPopupLayer(
        result: entry.result,
        isSearching: entry.isSearching,
        webViewKey: entry.webViewKey,
        isDark: isDark,
        showBorder: false,
        overrideFillColor: Colors.transparent,
        onDismiss: _close,
        onTapOutside: _close,
        onScrolledToBottom: entry.allLoaded
            ? null
            : () => loadMoreForEntry(entry: entry, popupStack: _stack),
        onTextSelected: (text, localRect) {
          if (_stack.length > 1) {
            setState(() => _stack.removeRange(1, _stack.length));
          }
          _pushSearch(text, localRect);
        },
        onLinkClick: (query, localRect) {
          if (_stack.length > 1) {
            setState(() => _stack.removeRange(1, _stack.length));
          }
          _pushSearch(query, localRect);
        },
        onMineEntry: onMineEntry,
        onDuplicateCheck: checkDuplicate,
      ),
    );
  }
}

class PopupDictionarySearchBar extends StatelessWidget {
  const PopupDictionarySearchBar({
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    this.onClose,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmit;
  final VoidCallback? onClose;

  void _submit() {
    final String query = controller.text.trim();
    if (query.isEmpty) return;
    onSubmit(query);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textColor = colorScheme.onSurface;
    final hintColor = colorScheme.onSurfaceVariant;

    return Row(
      children: [
        if (onClose != null)
          SizedBox(
            width: 36,
            height: 36,
            child: IconButton(
              key: const ValueKey<String>('popup_dictionary_close_button'),
              icon: Icon(Icons.close, color: hintColor, size: 20),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              padding: EdgeInsets.zero,
              onPressed: onClose,
            ),
          ),
        Expanded(
          child: TextField(
            key: const ValueKey<String>('popup_dictionary_search_field'),
            controller: controller,
            focusNode: focusNode,
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
            onSubmitted: (_) => _submit(),
          ),
        ),
        SizedBox(
          width: 36,
          height: 36,
          child: IconButton(
            key: const ValueKey<String>('popup_dictionary_search_button'),
            icon: Icon(Icons.search, color: hintColor, size: 20),
            padding: EdgeInsets.zero,
            onPressed: _submit,
          ),
        ),
      ],
    );
  }
}
