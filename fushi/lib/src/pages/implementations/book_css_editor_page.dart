import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/epub/book_css_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi/utils.dart';

class BookCssEditorPage extends ConsumerStatefulWidget {
  const BookCssEditorPage({super.key, required this.extractDir});

  final String extractDir;

  @override
  ConsumerState<BookCssEditorPage> createState() => _BookCssEditorPageState();
}

class _BookCssEditorPageState extends ConsumerState<BookCssEditorPage>
    with FushiPagePlaceholders<BookCssEditorPage> {
  late BookCssRepository _repo;
  List<CssFileEntry> _entries = [];
  int _selectedIndex = 0;
  bool _loading = true;

  /// 该书稳定 uid（按 extractDir 反查书行取 `.uid`，v82 起 book_custom_css 键）。
  /// null = 书未入库（临时/找不到）或旧行无 uid → 只存磁盘、不同步（优雅降级）。
  String? _bookUid;

  final Map<int, TextEditingController> _textControllers = {};
  final Map<int, String> _diskContent = {};

  @override
  void initState() {
    super.initState();
    _repo = BookCssRepository(widget.extractDir);
    _resolveBookUid();
    _reload();
  }

  Future<void> _resolveBookUid() async {
    try {
      final row = await ref
          .read(appProvider)
          .database
          .getEpubBookByExtractDir(widget.extractDir);
      final String? uid = row?.uid;
      if (mounted) _bookUid = (uid == null || uid.isEmpty) ? null : uid;
    } catch (_) {
      // 反查失败：只存磁盘不同步（不影响编辑器可用）。
    }
  }

  /// 把一次 CSS 保存/重置记进 book_custom_css（LWW 时间戳载体），供跨端同步。
  /// uid 未解析（书未入库）时静默跳过——磁盘写照常，只是不参与同步。
  Future<void> _recordCss(
    CssFileEntry entry, {
    required bool reset,
    String content = '',
  }) async {
    final String? bookUid = _bookUid;
    if (bookUid == null) return;
    try {
      final db = ref.read(appProvider).database;
      final int now = DateTime.now().millisecondsSinceEpoch;
      if (reset) {
        await db.markBookCssReset(bookUid, entry.relativePath, now);
      } else {
        await db.upsertBookCss(bookUid, entry.relativePath, content, now);
      }
    } catch (_) {
      // best-effort：同步记账失败不影响磁盘保存已成功。
    }
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
    // 记进 book_custom_css（跨端同步的时间戳载体）；磁盘已写、best-effort 记账。
    unawaited(_recordCss(_entries[index], reset: false, content: content));
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
      unawaited(_recordCss(_entries[idx], reset: true));
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

    // 重置前捕获「有自定义（.original 存在）」的条目，逐条记重置墓碑（跨端传播重置）。
    final List<CssFileEntry> customized = <CssFileEntry>[
      for (final CssFileEntry e in _entries)
        if (e.hasOriginal) e
    ];
    _repo.resetAll();
    for (final CssFileEntry e in customized) {
      unawaited(_recordCss(e, reset: true));
    }
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
      return FushiToolScaffold(
        title: t.book_css_editor_title,
        body: buildLoading(),
      );
    }
    if (_entries.isEmpty) {
      return FushiToolScaffold(
        title: t.book_css_editor_title,
        body: FushiPlaceholderMessage(
          icon: Icons.code,
          message: t.book_css_editor_no_css_files,
        ),
      );
    }

    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, _) async {
        if (didPop) return;
        final bool canLeave = await _guardUnsaved(_selectedIndex);
        if (canLeave && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: FushiToolScaffold(
        title: t.book_css_editor_title,
        actions: [
          TextButton(
            onPressed: _doResetAll,
            child: Text(t.book_css_editor_reset_all),
          ),
        ],
        bottom: SizedBox(
          height: tokens.spacing.card * 2.5,
          child: HorizontalDragScrollable(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(_entries.length, (i) {
                  return Padding(
                    padding: EdgeInsets.only(right: tokens.spacing.gap),
                    child: FushiSelectableChip(
                      label: _tabLabel(i),
                      selected: i == _selectedIndex,
                      onSelected: (_) => _attemptSwitchTab(i),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
        // 全屏 push 页面在桌面会铺满整宽，与限宽弹窗（900）里的兄弟设置页
        // 不一致；把正文与底部动作栏约束到同一最大宽度并居中。TextField 用
        // expands:true 需要有界高度，故用 SizedBox(height: infinity) 保留满高。
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kFushiSettingsDialogMaxWidth,
            ),
            child: SizedBox(
              width: double.infinity,
              height: double.infinity,
              child: IndexedStack(
                index: _selectedIndex,
                children: List.generate(_entries.length, (i) {
                  return FushiEditorPanel(controller: _textControllers[i]!);
                }),
              ),
            ),
          ),
        ),
        // Scaffold 给 bottomNavigationBar 松弛高度约束：这里用 Align(heightFactor: 1)
        // 让外层高度收缩到动作栏本身（若用 Center 会纵向膨胀占满全屏、盖住上方标签栏
        // 吸走点击），再 ConstrainedBox 限宽 + SizedBox(width: infinity) 在 900 内铺满，
        // spaceBetween 才能像限宽弹窗那样把「重置/保存」推到两端。
        bottomNavigationBar: Align(
          alignment: Alignment.center,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kFushiSettingsDialogMaxWidth,
            ),
            child: SizedBox(
              width: double.infinity,
              child: SafeArea(
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
                        onPressed:
                            _currentTabCanReset() ? _doResetCurrent : null,
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.78,
      child: FushiModalSheetFrame(
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
