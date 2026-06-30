import 'package:flutter/material.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

import 'package:hibiki/utils.dart' show t, HibikiToast;

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
Future<AnkiMinedCardActionResult> showAnkiMinedCardActionSheet({
  required BuildContext context,
  required List<MinedNoteRef> matches,
  required BaseAnkiRepository repo,
  required Future<AnkiCardMutationResult> Function() mineNew,
  required Future<AnkiCardMutationResult> Function(int noteId) overwrite,
}) async {
  final result = await showModalBottomSheet<AnkiMinedCardActionResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _MinedCardActionSheet(
      matches: matches,
      repo: repo,
      mineNew: mineNew,
      overwrite: overwrite,
    ),
  );
  return result ?? const AnkiMinedCardActionResult.unchanged();
}

class _MinedCardActionSheet extends StatefulWidget {
  const _MinedCardActionSheet({
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
  State<_MinedCardActionSheet> createState() => _MinedCardActionSheetState();
}

class _MinedCardActionSheetState extends State<_MinedCardActionSheet> {
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
      HibikiToast.show(msg: t.anki_card_action_failed);
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
      HibikiToast.show(msg: t.anki_card_action_failed);
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
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Text(t.anki_mined_card_title,
                style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              matches.length > 1
                  ? t.anki_mined_multiple_matches(count: matches.length)
                  : t.anki_mined_card_subtitle,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: matches.length,
              itemBuilder: (context, i) {
                final note = matches[i];
                final preview =
                    note.preview.isEmpty ? '#${note.noteId}' : note.preview;
                return ListTile(
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
                        onPressed: _busy ? null : () => _viewNote(note.noteId),
                      ),
                    ],
                  ),
                  onTap: _busy ? null : () => _viewNote(note.noteId),
                );
              },
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.add),
            title: Text(t.anki_mined_action_add_duplicate),
            enabled: !_busy,
            onTap: _busy ? null : _runMineNew,
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
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
      HibikiToast.show(msg: t.anki_note_open_failed);
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
      HibikiToast.show(msg: t.anki_card_action_failed);
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
Future<AnkiCardMutationResult> runAnkiMinedCardAction({
  required BuildContext context,
  required BaseAnkiRepository repo,
  required String expression,
  required String reading,
  required Future<AnkiCardMutationResult> Function() mineNew,
  required Future<AnkiCardMutationResult> Function(int noteId) overwrite,
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
  final result = await showAnkiMinedCardActionSheet(
    context: context,
    matches: matches,
    repo: repo,
    mineNew: mineNew,
    overwrite: overwrite,
  );
  return (ankiConnect: result.ankiConnect, noteId: result.noteId);
}
