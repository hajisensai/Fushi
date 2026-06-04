import 'package:flutter/material.dart';
import 'package:hibiki/src/epub/book_css_repository.dart';
import 'package:hibiki/utils.dart';

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
  bool _loading = true;

  final Map<int, TextEditingController> _textControllers = {};
  final Map<int, String> _diskContent = {};

  @override
  void initState() {
    super.initState();
    _repo = BookCssRepository(widget.extractDir);
    _reload();
  }

  // BUG-040: the discover-walk + per-file reads run off the UI thread via async
  // `dart:io` (see [BookCssRepository.loadSnapshots]) so opening the editor no
  // longer freezes the page-push transition. While the load is in flight the
  // page shows a progress indicator instead of synchronously blocking the UI.
  Future<void> _reload() async {
    if (mounted) setState(() => _loading = true);
    final List<CssFileSnapshot> snapshots = await _repo.loadSnapshots();
    if (!mounted) return;

    for (final controller in _textControllers.values) {
      controller.removeListener(_onTextChanged);
      controller.dispose();
    }
    _textControllers.clear();
    _diskContent.clear();
    _selectedIndex = 0;
    _entries = <CssFileEntry>[for (final s in snapshots) s.entry];

    for (int i = 0; i < snapshots.length; i++) {
      final String content = snapshots[i].content;
      _diskContent[i] = content;
      final TextEditingController controller =
          TextEditingController(text: content);
      controller.addListener(_onTextChanged);
      _textControllers[i] = controller;
    }
    setState(() => _loading = false);
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

    final String? result = await showAppDialog<String>(
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
    // BUG-040: no re-walk — saving CSS content can't change the set of .css
    // files, and the modified marker (`isDifferentFromOriginal`) reads disk
    // live, so a fresh `discoverCssFiles()` here only re-froze the UI thread.
    setState(() {});
    // _doSave is reached after an awaited unsaved-changes dialog in
    // _guardUnsaved, so the page may already be popped/disposed. Guard the
    // snackbar like _doResetCurrent/_doResetAll (HBK-AUDIT-108).
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.book_css_editor_saved)),
      );
    }
  }

  Future<void> _doResetCurrent() async {
    final int idx = _selectedIndex;
    final bool hasBackup = _entries[idx].hasOriginal;
    final bool hasEditorChanges = _hasUnsavedChanges(idx);
    if (!hasBackup && !hasEditorChanges) return;

    final bool? confirmed = await showAppDialog<bool>(
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
    final String restored = _repo.readCssSync(_entries[idx]);
    _diskContent[idx] = restored;
    _textControllers[idx]!.text = restored;
    // BUG-040: no re-walk — resetting one file's content can't change the set
    // of .css files; the modified marker recomputes from disk live.
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

    final bool? confirmed = await showAppDialog<bool>(
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
    // BUG-040: while the off-thread load is in flight, show a progress
    // indicator instead of a blank/blocked frame.
    if (_loading) {
      return HibikiToolScaffold(
        title: t.book_css_editor_title,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_entries.isEmpty) {
      return HibikiToolScaffold(
        title: t.book_css_editor_title,
        body: HibikiPlaceholderMessage(
          icon: Icons.code,
          message: t.book_css_editor_no_css_files,
        ),
      );
    }

    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, _) async {
        if (didPop) return;
        final bool canLeave = await _guardUnsaved(_selectedIndex);
        if (canLeave && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: HibikiToolScaffold(
        title: t.book_css_editor_title,
        actions: [
          TextButton(
            onPressed: _doResetAll,
            child: Text(t.book_css_editor_reset_all),
          ),
        ],
        bottom: SizedBox(
          height: tokens.spacing.card * 2.5,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(_entries.length, (i) {
                return Padding(
                  padding: EdgeInsets.only(right: tokens.spacing.gap),
                  child: HibikiSelectableChip(
                    label: _tabLabel(i),
                    selected: i == _selectedIndex,
                    onSelected: (_) => _attemptSwitchTab(i),
                  ),
                );
              }),
            ),
          ),
        ),
        body: IndexedStack(
          index: _selectedIndex,
          children: List.generate(_entries.length, (i) {
            return HibikiEditorPanel(controller: _textControllers[i]!);
          }),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.card,
              vertical: tokens.spacing.gap,
            ),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap / 2,
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.78,
      child: HibikiModalSheetFrame(
        title: title,
        leadingIcon: Icons.code_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          message,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            for (final action in actions)
              adaptiveDialogAction(
                context: context,
                isDefaultAction: action.filled,
                onPressed: () => Navigator.pop(context, action.value),
                child: Text(action.label),
              ),
          ],
        ),
      ),
    );
  }
}
