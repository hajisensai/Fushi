import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/stats/study_sessions.dart';
import 'package:fushi/utils.dart';

/// 统计页「会话流」（用户 2026-09-08：每个域都要会话级统计 + 能删掉误点的会话）。
///
/// 数据只有一处来源 `StatFacts.sessions`（段按 gap 归并 + 游玩会话骨架）；这里是它
/// 唯一的展示件，统计中心总览、阅读 / 视频 / 游戏三个域 tab 与「按媒体」的会话
/// sheet 都用同一个列表：一行 = 标题 · 起止时刻 · 时长 / 字数 / 页数 · 垃圾桶。
/// 删除走确认 → [onDelete]（页面里落 `deleteStudySession(db, session)` 再重聚合；
/// 那个 helper 先让段 uid 在在跑的 StudyClock 上退役，别绕过它直接调 DB 层）。
///
/// 没有点击跳转：会话是统计事实，不是媒体入口（按媒体列表 / 时段明细已有跳转）。

/// 会话行展示名：段 title 快照 → 调用方按域换成当前显示名（书走 override 书名）。
typedef StatSessionTitleOf = String Function(StudySession session);

/// 一行的量纲文案：时长 · 字数 · 页数，为 0 的量纲不显示；全 0 显示 0 分钟。
String formatStatSessionMeta(StudySession s) {
  final List<String> parts = <String>[
    if (s.durationMs > 0) formatStatTime(s.durationMs),
    if (s.chars > 0) formatStatChars(s.chars),
    if (s.pages > 0) t.stat_format_pages(n: s.pages),
  ];
  return parts.isEmpty ? formatStatTime(0) : parts.join(' · ');
}

/// 域图标（总览里三域混排时区分来源；域 tab 里也保留，形状统一）。
IconData statSessionIcon(StudySession s) => s.isVideo
    ? Icons.movie
    : s.isGame
        ? Icons.videogame_asset
        : Icons.menu_book;

/// 页面内的「最近会话」区块：标题行（右侧「全部会话」进 sheet）+ 最多 [limit] 行。
/// [sessions] 已按结束时刻倒序（`StatFacts.sessions` 的契约）。
Widget buildStatSessionSection(
  BuildContext context, {
  required List<StudySession> sessions,
  required StatSessionTitleOf titleOf,
  required Future<void> Function(StudySession session) onDelete,
  int limit = 8,
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final List<StudySession> shown =
      sessions.length <= limit ? sessions : sessions.sublist(0, limit);
  return Padding(
    padding: EdgeInsets.fromLTRB(
      tokens.spacing.card,
      tokens.spacing.card + tokens.spacing.gap,
      tokens.spacing.card,
      0,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t.stat_sessions_recent,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (sessions.length > shown.length)
              TextButton(
                onPressed: () => unawaited(
                  showStatSessionsSheet(
                    context,
                    title: t.stat_sessions_show_all,
                    sessions: sessions,
                    titleOf: titleOf,
                    onDelete: onDelete,
                  ),
                ),
                child: Text('${t.stat_sessions_show_all} (${sessions.length})'),
              ),
          ],
        ),
        if (shown.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap),
            child: Text(t.stat_sessions_empty, style: tokens.type.metadata),
          )
        else
          StatSessionList(
            sessions: shown,
            titleOf: titleOf,
            onDelete: onDelete,
          ),
      ],
    ),
  );
}

/// 会话列表（区块与 sheet 共用）。删除：确认 → [onDelete] → 行从列表移除。
class StatSessionList extends StatefulWidget {
  const StatSessionList({
    required this.sessions,
    required this.titleOf,
    required this.onDelete,
    this.onDeleted,
    super.key,
  });

  final List<StudySession> sessions;
  final StatSessionTitleOf titleOf;
  final Future<void> Function(StudySession session) onDelete;

  /// 每删掉一行后回调（sheet 用它记「删过」让调用方关 sheet 后重聚合）。
  final VoidCallback? onDeleted;

  @override
  State<StatSessionList> createState() => _StatSessionListState();
}

class _StatSessionListState extends State<StatSessionList> {
  late List<StudySession> _rows = List<StudySession>.of(widget.sessions);

  @override
  void didUpdateWidget(StatSessionList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.sessions, widget.sessions)) {
      _rows = List<StudySession>.of(widget.sessions);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final StudySession s in _rows)
          FushiListItem(
            key: ValueKey<String>(s.key),
            density: FushiListDensity.compact,
            padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 4),
            leading: Icon(
              statSessionIcon(s),
              size: 18,
              color: colors.onSurfaceVariant,
            ),
            title: Text(_titleOf(s)),
            subtitle: Text(
              '${formatStatSessionRange(s.startAt, s.endAt)} · '
              '${formatStatSessionMeta(s)}',
            ),
            trailing: IconButton(
              tooltip: t.stat_session_delete,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => unawaited(_confirmAndDelete(s)),
            ),
          ),
      ],
    );
  }

  String _titleOf(StudySession s) {
    final String title = widget.titleOf(s);
    return title.isEmpty ? s.mediaKey : title;
  }

  Future<void> _confirmAndDelete(StudySession s) async {
    final bool confirmed = await confirmDeleteStatistics(
      context,
      '${_titleOf(s)}\n${formatStatSessionRange(s.startAt, s.endAt)}',
      message: t.stat_session_delete_message,
    );
    if (!confirmed || !mounted) return;
    await widget.onDelete(s);
    if (!mounted) return;
    setState(() => _rows.remove(s));
    widget.onDeleted?.call();
  }
}

/// 全部会话 / 某媒体的会话 sheet。返回是否删过（true = 调用方重聚合）。
Future<bool> showStatSessionsSheet(
  BuildContext context, {
  required String title,
  required List<StudySession> sessions,
  required StatSessionTitleOf titleOf,
  required Future<void> Function(StudySession session) onDelete,
}) async {
  bool deleted = false;
  await adaptiveModalSheet<void>(
    context: context,
    builder: (BuildContext sheetContext) {
      final FushiDesignTokens tokens = FushiDesignTokens.of(sheetContext);
      return SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(tokens.spacing.card),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: tokens.type.sectionLabel),
              SizedBox(height: tokens.spacing.gap / 2),
              if (sessions.isEmpty)
                Text(t.stat_sessions_empty, style: tokens.type.metadata)
              else
                StatSessionList(
                  sessions: sessions,
                  titleOf: titleOf,
                  onDelete: onDelete,
                  onDeleted: () => deleted = true,
                ),
            ],
          ),
        ),
      );
    },
  );
  return deleted;
}
