import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/epub/book_css_repository.dart';

class BookCssEditorPage extends StatefulWidget {
  const BookCssEditorPage({super.key, required this.extractDir});

  final String extractDir;

  @override
  State<BookCssEditorPage> createState() => _BookCssEditorPageState();
}

class _BookCssEditorPageState extends State<BookCssEditorPage> {
  late BookCssRepository _repo;
  List<CssFileEntry> _entries = [];
  int _selectedIndex = 0;

  final Map<int, TextEditingController> _textControllers = {};
  final Map<int, String> _diskContent = {};

  @override
  void initState() {
    super.initState();
    _repo = BookCssRepository(widget.extractDir);
    _reload();
  }

  void _reload() {
    _entries = _repo.discoverCssFiles();
    for (final controller in _textControllers.values) {
      controller.removeListener(_onTextChanged);
      controller.dispose();
    }
    _textControllers.clear();
    _diskContent.clear();
    _selectedIndex = 0;

    for (int i = 0; i < _entries.length; i++) {
      final String content = _repo.readCss(_entries[i]);
      _diskContent[i] = content;
      final TextEditingController controller =
          TextEditingController(text: content);
      controller.addListener(_onTextChanged);
      _textControllers[i] = controller;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in _textControllers.values) {
      c.removeListener(_onTextChanged);
      c.dispose();
    }
    super.dispose();
  }

  bool _hasUnsavedChanges(int index) {
    final String? disk = _diskContent[index];
    final String? editor = _textControllers[index]?.text;
    return disk != null && editor != null && disk != editor;
  }

  void _onTextChanged() {
    setState(() {});
  }

  String _tabLabel(int index) {
    final String title = _entries[index].displayTitle;
    final bool modified =
        _entries[index].isDifferentFromOriginal() || _hasUnsavedChanges(index);
    return modified ? '* $title' : title;
  }

  bool _currentTabCanReset() {
    return _entries[_selectedIndex].hasOriginal ||
        _hasUnsavedChanges(_selectedIndex);
  }

  Future<void> _attemptSwitchTab(int newIndex) async {
    if (newIndex == _selectedIndex) return;
    if (_hasUnsavedChanges(_selectedIndex)) {
      final bool ok = await _guardUnsaved(_selectedIndex);
      if (!ok) return;
    }
    setState(() => _selectedIndex = newIndex);
  }

  Future<bool> _guardUnsaved(int index) async {
    if (!_hasUnsavedChanges(index)) return true;

    final String? result = await showDialog<String>(
      context: context,
      builder: (ctx) => BookCssConfirmationDialog<String>(
        title: t.book_css_editor_unsaved_changes,
        message: t.book_css_editor_unsaved_changes_message,
        actions: [
          BookCssDialogAction<String>(
            value: 'cancel',
            label: t.book_css_editor_cancel,
          ),
          BookCssDialogAction<String>(
            value: 'discard',
            label: t.book_css_editor_discard,
          ),
          BookCssDialogAction<String>(
            value: 'save',
            label: t.book_css_editor_save,
            filled: true,
          ),
        ],
      ),
    );

    if (result == 'save') {
      _doSave(index);
      return true;
    } else if (result == 'discard') {
      _textControllers[index]!.text = _diskContent[index]!;
      return true;
    }
    return false;
  }

  void _doSave(int index) {
    final String content = _textControllers[index]!.text;
    _repo.saveCss(_entries[index], content);
    _diskContent[index] = content;
    _entries = _repo.discoverCssFiles();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.book_css_editor_saved)),
    );
  }

  Future<void> _doResetCurrent() async {
    final int idx = _selectedIndex;
    final bool hasBackup = _entries[idx].hasOriginal;
    final bool hasEditorChanges = _hasUnsavedChanges(idx);
    if (!hasBackup && !hasEditorChanges) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => BookCssConfirmationDialog<bool>(
        title: t.book_css_editor_unsaved_changes,
        message: t.book_css_editor_confirm_reset,
        actions: [
          BookCssDialogAction<bool>(
            value: false,
            label: t.book_css_editor_cancel,
          ),
          BookCssDialogAction<bool>(
            value: true,
            label: t.book_css_editor_reset_current,
            filled: true,
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    if (hasBackup) {
      _repo.resetFile(_entries[idx]);
    }
    final String restored = _repo.readCss(_entries[idx]);
    _diskContent[idx] = restored;
    _textControllers[idx]!.text = restored;
    _entries = _repo.discoverCssFiles();
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.book_css_editor_reset_done)),
      );
    }
  }

  Future<void> _doResetAll() async {
    final bool hasAnyBackup = _entries.any((e) => e.hasOriginal);
    final bool hasAnyEditorChanges = List.generate(
      _entries.length,
      (i) => _hasUnsavedChanges(i),
    ).any((v) => v);
    if (!hasAnyBackup && !hasAnyEditorChanges) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => BookCssConfirmationDialog<bool>(
        title: t.book_css_editor_unsaved_changes,
        message: t.book_css_editor_confirm_reset_all,
        actions: [
          BookCssDialogAction<bool>(
            value: false,
            label: t.book_css_editor_cancel,
          ),
          BookCssDialogAction<bool>(
            value: true,
            label: t.book_css_editor_reset_all,
            filled: true,
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    _repo.resetAll();
    _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.book_css_editor_reset_done)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_entries.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(t.book_css_editor_title)),
        body: Center(child: Text(t.book_css_editor_no_css_files)),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, _) async {
        if (didPop) return;
        final bool canLeave = await _guardUnsaved(_selectedIndex);
        if (canLeave && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.book_css_editor_title),
          actions: [
            TextButton(
              onPressed: _doResetAll,
              child: Text(t.book_css_editor_reset_all),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: List.generate(_entries.length, (i) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(_tabLabel(i)),
                      selected: i == _selectedIndex,
                      onSelected: (_) => _attemptSwitchTab(i),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
        body: IndexedStack(
          index: _selectedIndex,
          children: List.generate(_entries.length, (i) {
            return Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextField(
                controller: _textControllers[i],
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
            );
          }),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton(
                  onPressed: _currentTabCanReset() ? _doResetCurrent : null,
                  child: Text(t.book_css_editor_reset_current),
                ),
                FilledButton(
                  onPressed: () => _doSave(_selectedIndex),
                  child: Text(t.book_css_editor_save),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
class BookCssDialogAction<T> {
  const BookCssDialogAction({
    required this.value,
    required this.label,
    this.filled = false,
  });

  final T value;
  final String label;
  final bool filled;
}

@visibleForTesting
class BookCssConfirmationDialog<T> extends StatelessWidget {
  const BookCssConfirmationDialog({
    required this.title,
    required this.message,
    required this.actions,
    super.key,
  });

  final String title;
  final String message;
  final List<BookCssDialogAction<T>> actions;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      buttonPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.titleMedium,
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: double.maxFinite,
          maxHeight: MediaQuery.of(context).size.height * 0.3,
        ),
        child: SingleChildScrollView(
          child: Text(
            message,
            style: textTheme.bodySmall,
          ),
        ),
      ),
      actions: [
        for (final action in actions)
          action.filled
              ? FilledButton(
                  onPressed: () => Navigator.pop(context, action.value),
                  child: Text(action.label),
                )
              : TextButton(
                  onPressed: () => Navigator.pop(context, action.value),
                  child: Text(action.label),
                ),
      ],
    );
  }
}
