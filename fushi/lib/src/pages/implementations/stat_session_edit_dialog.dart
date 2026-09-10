import 'package:flutter/material.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 会话编辑弹窗（用户 2026-09-10：「里面的每个会话做成可编辑，日期和字符都能编辑」）。
///
/// 只开放**日期**与**字数**两项，理由见 [StudySessionEdit] 的文档：日期只挪日历日、
/// 保留时分秒，段「不跨本地小时边界」的不变式原样成立；时长是段的活跃时长求和，
/// 改它要么得凭空发明分摊、要么破坏 `endAt - startAt >= durationMs`。
///
/// 日期用文本框（`YYYY-MM-DD`）而不是只给日历按钮：集成测试一律焦点驱动
/// （`docs/agent/integration-testing.md`，禁坐标点击），文本框 Tab 得到、能打字；
/// 日历按钮是旁路的便利入口，不是唯一入口。
@visibleForTesting
class StatSessionEditDialog extends StatefulWidget {
  const StatSessionEditDialog({
    required this.itemTitle,
    required this.startAt,
    required this.chars,
    super.key,
  });

  /// 被编辑会话的展示名（合集名已由调用方拼进来），显示在正文首行。
  final String itemTitle;

  /// 会话原起始毫秒戳（日期字段的初值）。
  final int startAt;

  /// 会话原总字数（字数字段的初值）。
  final int chars;

  @override
  State<StatSessionEditDialog> createState() => _StatSessionEditDialogState();
}

class _StatSessionEditDialogState extends State<StatSessionEditDialog> {
  late final TextEditingController _dateController;
  late final TextEditingController _charsController;

  /// 原始日历日：保存时与输入值比对，没动过就不往 [StudySessionEdit.date] 里放
  /// （不改的项传 null，避免一次无谓的整段平移写）。
  late final DateTime _originalDay;

  @override
  void initState() {
    super.initState();
    final DateTime start = DateTime.fromMillisecondsSinceEpoch(widget.startAt);
    _originalDay = DateTime(start.year, start.month, start.day);
    _dateController = TextEditingController(
      text: FushiDatabase.statCalendarDayKeyOf(_originalDay),
    );
    _charsController = TextEditingController(text: '${widget.chars}');
  }

  @override
  void dispose() {
    _dateController.dispose();
    _charsController.dispose();
    super.dispose();
  }

  /// 输入框里的日历日；格式不合法返回 null（`YYYY-MM-DD`，严格四-二-二，
  /// 不接受 `DateTime.parse` 顺带认的 ISO 全形式——那会把「2026-09-10T00:00」
  /// 之类的东西当合法输入放过去）。
  DateTime? get _parsedDay {
    final String raw = _dateController.text.trim();
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) return null;
    final DateTime? parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    // `2026-02-31` 会被 tryParse 溢出成 3 月 3 日；回读三个分量才认。
    return FushiDatabase.statCalendarDayKeyOf(parsed) == raw ? parsed : null;
  }

  /// 输入框里的字数；非法（负数 / 非整数 / 空）返回 null。
  int? get _parsedChars {
    final int? parsed = int.tryParse(_charsController.text.trim());
    return parsed == null || parsed < 0 ? null : parsed;
  }

  bool get _canSave => _parsedDay != null && _parsedChars != null;

  void _submit() {
    final DateTime? day = _parsedDay;
    final int? chars = _parsedChars;
    if (day == null || chars == null) return;
    Navigator.pop(
      context,
      StudySessionEdit(
        date: day == _originalDay ? null : day,
        chars: chars == widget.chars ? null : chars,
      ),
    );
  }

  Future<void> _pickDate() async {
    final DateTime initial = _parsedDay ?? _originalDay;
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial,
      // 统计事实的合理范围：往前十年够覆盖任何导入的历史，往后到今天为止
      // （会话不可能发生在未来，允许选未来只会造出永远排在最前面的假行）。
      firstDate: DateTime(initial.year - 10),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dateController.text = FushiDatabase.statCalendarDayKeyOf(picked);
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool dateValid = _parsedDay != null;
    final bool charsValid = _parsedChars != null;
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: FushiModalSheetFrame(
        title: t.stat_session_edit,
        leadingIcon: Icons.edit_outlined,
        scrollable: true,
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
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(widget.itemTitle, style: tokens.type.listSubtitle),
            SizedBox(height: tokens.spacing.gap),
            FushiTextField(
              key: const ValueKey<String>('stat-session-edit-date'),
              controller: _dateController,
              labelText: t.stat_session_edit_date,
              hintText: 'YYYY-MM-DD',
              autofocus: true,
              onChanged: (_) => setState(() {}),
              suffixIcon: IconButton(
                tooltip: t.stat_session_edit_date,
                icon: const Icon(Icons.calendar_today_outlined, size: 18),
                onPressed: _pickDate,
              ),
            ),
            if (!dateValid)
              _fieldError(tokens, colors, t.stat_session_edit_date_invalid),
            SizedBox(height: tokens.spacing.gap),
            FushiTextField(
              key: const ValueKey<String>('stat-session-edit-chars'),
              controller: _charsController,
              labelText: t.stat_session_edit_chars,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            if (!charsValid)
              _fieldError(tokens, colors, t.stat_session_edit_chars_invalid),
            SizedBox(height: tokens.spacing.gap),
            Text(
              t.stat_session_edit_message,
              style: tokens.type.metadata.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: _canSave ? _submit : null,
              child: Text(t.dialog_save),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldError(
    FushiDesignTokens tokens,
    ColorScheme colors,
    String message,
  ) =>
      Padding(
        padding: EdgeInsets.only(top: tokens.spacing.gap / 3),
        child: Text(
          message,
          style: tokens.type.metadata.copyWith(color: colors.error),
        ),
      );
}

/// 弹出会话编辑框；用户点「保存」且真有改动时返回 [StudySessionEdit]，取消 /
/// 点外面关闭 / 两项都没动返回 null（调用方据此决定要不要写库 + 重聚合）。
Future<StudySessionEdit?> showStatSessionEditDialog(
  BuildContext context, {
  required String itemTitle,
  required int startAt,
  required int chars,
}) async {
  final StudySessionEdit? edit = await showAppDialog<StudySessionEdit>(
    context: context,
    builder: (BuildContext ctx) => StatSessionEditDialog(
      itemTitle: itemTitle,
      startAt: startAt,
      chars: chars,
    ),
  );
  return edit == null || edit.isEmpty ? null : edit;
}
