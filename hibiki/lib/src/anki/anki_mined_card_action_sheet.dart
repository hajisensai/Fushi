import 'package:flutter/material.dart';
import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/utils.dart' show t, HibikiToast, ToastSeverity;

/// BUG-1040：把「一段期间内让查词弹窗让位」的执行权交回宿主页面的钩子。
///
/// 查词弹窗是**原生平台视图**（桌面 WebView2 / Android platform view），靠 airspace
/// 永远画在 Flutter 层之上——任何 `showDialog` 弹出来的东西都会被它盖住（BUG-797 已
/// 在「选择句子上下文」对话框上踩过同一个坑）。所以本文件的对话框不能自己解决层级，
/// 必须由持有弹窗层的宿主页面在对话框期间把弹窗停靠屏外。两条查词车道
/// （`BaseSourcePageState` / `DictionaryPageMixin`）各实现一份并传进来；为 null 时
/// 原样执行（无弹窗层的宿主，如纯查词页）。
typedef LookupPopupHiddenRunner = Future<T> Function<T>(
    Future<T> Function() body);

/// [LookupPopupHiddenRunner] 缺省实现：直接跑，不动任何层级。
Future<T> _runDirect<T>(Future<T> Function() body) => body();

/// TODO-1007/1008：点查词弹窗「✓」（卡已存在）时弹出操作选择 + note viewer。
/// 根因修复：旧行为点 ✓ 默默 return / 只覆写最近一张，把别处/上次会话建的同词卡挡死。
/// 现在每次点 ✓ 都显式让用户选：命中多张全部列出；每张可覆写/查看·打开；顶部恒有
/// 新增为重复卡。两后端解耦：repo 提供 findMatchingNotes/noteFields/openNoteInAnki；
/// mineNew/overwrite 复用宿主已有制卡/覆盖链路，本文件只负责 UI 选择。

/// 宿主制卡 / 覆写动作的回传：是否 AnkiConnect 成功（可进第三态）+ note id。
typedef AnkiCardMutationResult = ({bool ankiConnect, int? noteId});

/// 用户选定动作的结果（回传 popup.js 刷新 ✓/+ 态）。
@immutable
class AnkiMinedCardActionResult {
  const AnkiMinedCardActionResult({
    required this.mined,
    this.ankiConnect = false,
    this.noteId,
  });

  const AnkiMinedCardActionResult.unchanged()
      : mined = true,
        ankiConnect = false,
        noteId = null;

  final bool mined;
  final bool ankiConnect;
  final int? noteId;
}

/// 弹出操作选择并执行用户选择，返回结果。matches 由调用方先用
/// BaseAnkiRepository.findMatchingNotes 查好（命中多张全部传入）。
///
/// BUG-1040：从底部 sheet 改为**居中对话框**。这是个「必须当场做决定」的模态选择
/// （覆写哪张 / 新增重复卡 / 去 Anki 看），不是可下拉浏览的内容面板；底部 sheet 贴在
/// 屏幕下沿、在视频页还会被播放器控件与窗口边缘裁掉半截（用户附图里进度条已被切）。
/// 与同族的 [showAnkiNoteViewer] / [SentenceContextDialog] 统一走 [showAppDialog]。
Future<AnkiMinedCardActionResult> showAnkiMinedCardActionSheet({
  required BuildContext context,
  required List<MinedNoteRef> matches,
  required BaseAnkiRepository repo,
  required Future<AnkiCardMutationResult> Function() mineNew,
  required Future<AnkiCardMutationResult> Function(int noteId) overwrite,
}) async {
  final result = await showAppDialog<AnkiMinedCardActionResult>(
    context: context,
    // 制卡/覆写是有副作用的选择，误触 barrier 就丢掉整次操作——只允许显式取消。
    barrierDismissible: false,
    builder: (dialogContext) => _MinedCardActionDialog(
      matches: matches,
      repo: repo,
      mineNew: mineNew,
      overwrite: overwrite,
    ),
  );
  return result ?? const AnkiMinedCardActionResult.unchanged();
}

class _MinedCardActionDialog extends StatefulWidget {
  const _MinedCardActionDialog({
    required this.matches,
    required this.repo,
    required this.mineNew,
    required this.overwrite,
  });

  final List<MinedNoteRef> matches;
  final BaseAnkiRepository repo;
  final Future<AnkiCardMutationResult> Function() mineNew;
  final Future<AnkiCardMutationResult> Function(int noteId) overwrite;

  @override
  State<_MinedCardActionDialog> createState() => _MinedCardActionDialogState();
}

class _MinedCardActionDialogState extends State<_MinedCardActionDialog> {
  bool _busy = false;

  Future<void> _runMineNew() async {
    if (_busy) return;
    setState(() => _busy = true);
    // TODO-1007 健壮性：宿主回调（repo.mineEntry/loadSettings 等网络/平台通道）
    // 可能抛错。无 try/catch 会让 _busy 永久卡 true（进度条不消、无任何反馈）。
    final AnkiCardMutationResult r;
    try {
      r = await widget.mineNew();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      HibikiToast.show(
        msg: t.anki_card_action_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(AnkiMinedCardActionResult(
      mined: true,
      ankiConnect: r.ankiConnect,
      noteId: r.noteId,
    ));
  }

  Future<void> _runOverwrite(int noteId) async {
    if (_busy) return;
    setState(() => _busy = true);
    // TODO-1007 健壮性：同 _runMineNew，宿主覆写回调抛错时复位 _busy + 反馈。
    final AnkiCardMutationResult r;
    try {
      r = await widget.overwrite(noteId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      HibikiToast.show(
        msg: t.anki_card_action_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(AnkiMinedCardActionResult(
      mined: true,
      ankiConnect: r.ankiConnect,
      noteId: r.noteId,
    ));
  }

  Future<void> _viewNote(int noteId) async {
    if (_busy) return;
    final viewerResult = await showAnkiNoteViewer(
      context: context,
      repo: widget.repo,
      noteId: noteId,
      overwrite: widget.overwrite,
    );
    if (!mounted || viewerResult == null) return;
    Navigator.of(context).pop(viewerResult);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = widget.matches;
    // 窄屏（手机）时不硬撑 420，取可用宽度的九成，避免对话框横向溢出。
    final double width = MediaQuery.sizeOf(context).width * 0.9 < 420
        ? MediaQuery.sizeOf(context).width * 0.9
        : 420;
    return AlertDialog(
      title: Text(t.anki_mined_card_title),
      content: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              matches.length > 1
                  ? t.anki_mined_multiple_matches(count: matches.length)
                  : t.anki_mined_card_subtitle,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            // AlertDialog 的 content 拿到的是**有界**高度（Dialog 已按屏幕减 inset 收口），
            // 故此处 Flexible + shrinkWrap 列表安全：命中少时按内容高，多时自身滚动。
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: matches.length,
                itemBuilder: (context, i) {
                  final note = matches[i];
                  final preview =
                      note.preview.isEmpty ? '#${note.noteId}' : note.preview;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(preview,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: t.anki_mined_action_overwrite,
                          icon: const Icon(Icons.edit_outlined),
                          onPressed:
                              _busy ? null : () => _runOverwrite(note.noteId),
                        ),
                        IconButton(
                          tooltip: t.anki_mined_action_view,
                          icon: const Icon(Icons.open_in_new),
                          onPressed:
                              _busy ? null : () => _viewNote(note.noteId),
                        ),
                      ],
                    ),
                    onTap: _busy ? null : () => _viewNote(note.noteId),
                  );
                },
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _runMineNew,
          icon: const Icon(Icons.add),
          label: Text(t.anki_mined_action_add_duplicate),
        ),
      ],
    );
  }
}

/// TODO-1007/1008：只读 note viewer——拉取已存在卡片现有字段展示，提供覆写与在 Anki
/// 中打开。不做字段内联编辑（超范围）。覆写成功时返回结果给上层收口刷新。
Future<AnkiMinedCardActionResult?> showAnkiNoteViewer({
  required BuildContext context,
  required BaseAnkiRepository repo,
  required int noteId,
  required Future<AnkiCardMutationResult> Function(int noteId) overwrite,
}) {
  return showDialog<AnkiMinedCardActionResult>(
    context: context,
    builder: (_) => _AnkiNoteViewerDialog(
      repo: repo,
      noteId: noteId,
      overwrite: overwrite,
    ),
  );
}

class _AnkiNoteViewerDialog extends StatefulWidget {
  const _AnkiNoteViewerDialog({
    required this.repo,
    required this.noteId,
    required this.overwrite,
  });

  final BaseAnkiRepository repo;
  final int noteId;
  final Future<AnkiCardMutationResult> Function(int noteId) overwrite;

  @override
  State<_AnkiNoteViewerDialog> createState() => _AnkiNoteViewerDialogState();
}

class _AnkiNoteViewerDialogState extends State<_AnkiNoteViewerDialog> {
  Map<String, String>? _fields;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final fields = await widget.repo.noteFields(widget.noteId);
    if (!mounted) return;
    setState(() {
      _fields = fields;
      _loading = false;
    });
  }

  Future<void> _openInAnki() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await widget.repo.openNoteInAnki(widget.noteId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      HibikiToast.show(
        msg: t.anki_note_open_failed,
        severity: ToastSeverity.error,
      );
    }
  }

  Future<void> _overwrite() async {
    if (_busy) return;
    setState(() => _busy = true);
    // TODO-1007 健壮性：note viewer 覆写同样可能抛错，复位 _busy + 反馈，不卡进度。
    final AnkiCardMutationResult r;
    try {
      r = await widget.overwrite(widget.noteId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      HibikiToast.show(
        msg: t.anki_card_action_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(AnkiMinedCardActionResult(
      mined: true,
      ankiConnect: r.ankiConnect,
      noteId: r.noteId,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fields = _fields;
    final List<MapEntry<String, String>> nonEmpty = fields == null
        ? const []
        : fields.entries.where((e) => e.value.trim().isNotEmpty).toList();
    return AlertDialog(
      title: Text(t.anki_note_viewer_title),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const SizedBox(
                height: 80, child: Center(child: CircularProgressIndicator()))
            : nonEmpty.isEmpty
                ? Text(t.anki_note_viewer_empty)
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final e in nonEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(e.key,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                            color: theme.colorScheme.primary)),
                                const SizedBox(height: 2),
                                Text(
                                  BaseAnkiRepository.previewFromFieldValue(
                                      e.value,
                                      maxLen: 4000),
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _openInAnki,
          child: Text(t.anki_note_viewer_open_in_anki),
        ),
        FilledButton(
          onPressed: _busy ? null : _overwrite,
          child: Text(t.anki_mined_action_overwrite),
        ),
      ],
    );
  }
}

/// TODO-1007/1008：点 ✓ 的宿主侧编排收口（mixin / base_source_page 两条车道共用，
/// 杜绝两份漂移）。据 [expression]/[reading] 反查 Anki 全部命中卡：
///   - 无命中（探测后被删 / 已不在）→ 直接按新卡制（[mineNew]），相当于「+」。
///   - 有命中 → 弹 [showAnkiMinedCardActionSheet] 让用户选（覆写哪张 / 新增重复卡 /
///     查看·在 Anki 中打开）。
/// 返回值映射成 popup.js 用的 (ankiConnect, noteId) 元组，由调用方包成 MinePopupResult。
///
/// BUG-1040：[runHidden] 由宿主页面传入，用来在**对话框可见期间**把查词弹窗停靠屏外
/// （原生平台视图 airspace 会盖住对话框，见 [LookupPopupHiddenRunner]）。刻意只包住
/// 对话框那一段、不包 [BaseAnkiRepository.findMatchingNotes]——反查是网络往返，Anki
/// 不可达时会一直等到超时，若连它一起藏就会出现「弹窗凭空消失好几秒又回来、期间什么
/// 都没弹」的空窗。
Future<AnkiCardMutationResult> runAnkiMinedCardAction({
  required BuildContext context,
  required BaseAnkiRepository repo,
  required String expression,
  required String reading,
  required Future<AnkiCardMutationResult> Function() mineNew,
  required Future<AnkiCardMutationResult> Function(int noteId) overwrite,
  LookupPopupHiddenRunner? runHidden,
}) async {
  final matches = await repo.findMatchingNotes(expression, reading);
  if (matches.isEmpty) {
    // 探测时显示已制卡，但现在 Anki 里查不到（被删/dupes）——直接按新卡制，
    // 等价旧的「点 ✓ 重验后已不在 → 重制」路径，但有反馈不再静默。
    return mineNew();
  }
  if (!context.mounted) {
    return const (ankiConnect: false, noteId: null);
  }
  final LookupPopupHiddenRunner hide = runHidden ?? _runDirect;
  final result = await hide<AnkiMinedCardActionResult>(
    () => showAnkiMinedCardActionSheet(
      context: context,
      matches: matches,
      repo: repo,
      mineNew: mineNew,
      overwrite: overwrite,
    ),
  );
  return (ankiConnect: result.ankiConnect, noteId: result.noteId);
}

/// TODO-1360：已制卡的词旁「在 Anki 中打开卡片」按钮的宿主侧编排（两条查词车道共用，
/// 杜绝漂移）。据 [expression]/[reading] 反查 Anki 全部命中卡，直接跳转打开：
///   - 无命中（探测显示已制卡但现在查不到 / 被删）→ toast 提示，不静默。
///   - 命中 1 张 → 直接 [BaseAnkiRepository.openNoteInAnki]（AnkiConnect guiBrowse /
///     AnkiDroid ACTION_VIEW），失败 toast。
///   - 命中多张（同词多卡）→ 弹轻量选择让用户选一张打开（单一职责，不复用覆写/新增
///     的 [showAnkiMinedCardActionSheet]）。
/// 与点 ✓ 的 [runAnkiMinedCardAction] 解耦：本编排不制卡、不覆写，只做「查找并打开」。
Future<void> openMinedCardInAnki({
  required BuildContext context,
  required BaseAnkiRepository repo,
  required String expression,
  required String reading,
  LookupPopupHiddenRunner? runHidden,
}) async {
  final matches = await repo.findMatchingNotes(expression, reading);
  if (matches.isEmpty) {
    HibikiToast.show(
      msg: t.anki_open_no_card,
      severity: ToastSeverity.error,
    );
    return;
  }
  if (matches.length == 1) {
    final ok = await repo.openNoteInAnki(matches.first.noteId);
    if (!ok) {
      HibikiToast.show(
        msg: t.anki_note_open_failed,
        severity: ToastSeverity.error,
      );
    }
    return;
  }
  if (!context.mounted) return;
  // BUG-1040：与 [runAnkiMinedCardAction] 同理——选择框也是 Flutter 层，需宿主让位。
  final LookupPopupHiddenRunner hide = runHidden ?? _runDirect;
  await hide<void>(
    () =>
        showAnkiOpenNotePicker(context: context, matches: matches, repo: repo),
  );
}

/// TODO-1360：同词命中多张卡时的轻量选择——只列预览行，点任意一张在 Anki 中打开。
/// 不带覆写/新增（那是点 ✓ 的职责），保持本入口「查找并打开」单一语义。
/// BUG-1040：与 [showAnkiMinedCardActionSheet] 同步改为居中对话框（同族模态选择，
/// 不该一个居中一个贴底沿）。
Future<void> showAnkiOpenNotePicker({
  required BuildContext context,
  required List<MinedNoteRef> matches,
  required BaseAnkiRepository repo,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (dialogContext) => _OpenNotePicker(matches: matches, repo: repo),
  );
}

class _OpenNotePicker extends StatefulWidget {
  const _OpenNotePicker({required this.matches, required this.repo});

  final List<MinedNoteRef> matches;
  final BaseAnkiRepository repo;

  @override
  State<_OpenNotePicker> createState() => _OpenNotePickerState();
}

class _OpenNotePickerState extends State<_OpenNotePicker> {
  bool _busy = false;

  Future<void> _open(int noteId) async {
    if (_busy) return;
    setState(() => _busy = true);
    // openNoteInAnki 是 best-effort（返回 bool，不抛），但保守起见仍守 _busy 复位。
    final ok = await widget.repo.openNoteInAnki(noteId);
    if (!mounted) return;
    if (!ok) {
      setState(() => _busy = false);
      HibikiToast.show(
        msg: t.anki_note_open_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = widget.matches;
    final double width = MediaQuery.sizeOf(context).width * 0.9 < 420
        ? MediaQuery.sizeOf(context).width * 0.9
        : 420;
    return AlertDialog(
      title: Text(t.anki_mined_card_title),
      content: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t.anki_mined_multiple_matches(count: matches.length),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: matches.length,
                itemBuilder: (context, i) {
                  final note = matches[i];
                  final preview =
                      note.preview.isEmpty ? '#${note.noteId}' : note.preview;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(preview,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: _busy ? null : () => _open(note.noteId),
                  );
                },
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
      ],
    );
  }
}
