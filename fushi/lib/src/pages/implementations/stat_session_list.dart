import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_session_edit_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
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
/// **整行点击 = 编辑这次会话**（改日期 / 字数，走 [showStatSessionEditDialog] →
/// `applyStudySessionEdit`），区块标题行上另有「清除全部会话」（防呆确认 →
/// [onClearAll]）：四个挂会话区块的页面（三个域 tab + 总览）用的是同一份区块，
/// 所以这两件事天然四处同形。
///
/// 编辑入口**刻意不是 trailing 上的第二颗图标按钮**：`trailing` 只有一颗按钮的
/// 48dp 宽度预算，塞第二颗会把标题挤到单行省略——正是 BUG-2417 报的那条回归
/// （守卫 `test/pages/stat_session_list_test.dart` 的「长标题排到第二行」在 400dp
/// 手机宽下当场变红，实测 448dp 才放得下两颗）。行本来就没有任何点击语义，拿它
/// 当编辑入口不与谁冲突，且焦点驱动下 Tab 到行按 Enter 即可（集成测试友好）。

/// 会话行展示名：段 title 快照 → 调用方按域换成当前显示名（书走 override 书名）。
typedef StatSessionTitleOf = String Function(StudySession session);

/// 会话行所属合集名（'<mediaType>|<entryKey>' 归属键 → 主合集名，见
/// [statCollectionName]）；不属于任何合集返回 null。
///
/// BUG-2417：段 title 快照是**条目名**，合集里就是分集名（「暗中行动」「威胁」）。
/// 单看一行认不出是哪部作品——会话流是跨媒体时间序，没有时段明细 sheet 那种
/// 合集组头兜底，所以合集名必须贴在行上。
typedef StatSessionCollectionOf = String? Function(StudySession session);

/// 编辑一次会话：调用页落 `applyStudySessionEdit(db, session, edit)` 再整页重聚合。
typedef StatSessionEditOf = Future<void> Function(
  StudySession session,
  StudySessionEdit edit,
);

/// 清除这一批会话：调用页落 `deleteStudySessions(db, sessions)` 再整页重聚合。
typedef StatSessionClearAll = Future<void> Function(
  List<StudySession> sessions,
);

/// 一行的量纲文案：时长 · 字数 · 页数 · 速度（字/时），为 0 的量纲不显示；全 0
/// 显示 0 分钟。速度只在有字数且时长够 1 分钟样本时出现（[formatStatCphOf]），
/// 用户 2026-09-12：每个会话都要能看到「每小时多少字」，排查读速异常。
String formatStatSessionMeta(StudySession s) {
  final String? cph = formatStatCphOf(s.chars, s.durationMs);
  final List<String> parts = <String>[
    if (s.durationMs > 0) formatStatTime(s.durationMs),
    if (s.chars > 0) formatStatChars(s.chars),
    if (s.pages > 0) t.stat_format_pages(n: s.pages),
    if (cph != null) cph,
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
  required StatSessionEditOf onEdit,
  required StatSessionClearAll onClearAll,
  StatSessionCollectionOf? collectionOf,
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
                    collectionOf: collectionOf,
                    onDelete: onDelete,
                    onEdit: onEdit,
                    onClearAll: onClearAll,
                  ),
                ),
                child: Text('${t.stat_sessions_show_all} (${sessions.length})'),
              ),
            // 清的是**这一页拿到的整批**会话（域 tab = 本域全部，总览 = 跨域全部），
            // 不是屏幕上截断显示的那 8 条——按钮文案与防呆勾选项复述的都是 N。
            if (sessions.isNotEmpty)
              _StatSessionsClearAllButton(
                sessions: sessions,
                onClearAll: onClearAll,
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
            collectionOf: collectionOf,
            onDelete: onDelete,
            onEdit: onEdit,
          ),
      ],
    ),
  );
}

/// 「清除全部会话」按钮：防呆确认（[confirmClearAllStatSessions]，必须先勾确认）
/// → [onClearAll]。区块标题行与 sheet 头共用同一颗，别在两处各写一遍。
class _StatSessionsClearAllButton extends StatelessWidget {
  const _StatSessionsClearAllButton({
    required this.sessions,
    required this.onClearAll,
  });

  final List<StudySession> sessions;
  final StatSessionClearAll onClearAll;

  Future<void> _confirmAndClear(BuildContext context) async {
    final bool confirmed =
        await confirmClearAllStatSessions(context, sessions.length);
    if (!confirmed) return;
    await onClearAll(sessions);
  }

  // 图标刻意**不用** `delete_sweep_outlined`：顶栏那颗「清空全部统计」已经是它，
  // 同屏两颗一样的扫帚、清的范围却差着一个数量级（会话事实 vs 整个域的全部统计），
  // 是最典型的误点来源。`playlist_remove` 读作「把这张列表清空」，范围一眼就对。
  @override
  Widget build(BuildContext context) => IconButton(
        key: const ValueKey<String>('stat-sessions-clear-all'),
        tooltip: t.stat_sessions_clear_all,
        icon: const Icon(Icons.playlist_remove, size: 20),
        onPressed: () => unawaited(_confirmAndClear(context)),
      );
}

/// 会话列表（区块与 sheet 共用）。删除：确认 → [onDelete] → 行从列表移除。
/// 编辑：弹 [showStatSessionEditDialog] → [onEdit] → 本地换成展示副本 + 通知调用方
/// 整页重聚合（重聚合才算得出最终形态：改完日期的会话要重新按 gap 归并、重新排序，
/// 甚至与相邻会话合并成一条）。
class StatSessionList extends StatefulWidget {
  const StatSessionList({
    required this.sessions,
    required this.titleOf,
    required this.onDelete,
    required this.onEdit,
    this.collectionOf,
    this.onDeleted,
    super.key,
  });

  final List<StudySession> sessions;
  final StatSessionTitleOf titleOf;
  final Future<void> Function(StudySession session) onDelete;

  /// 保存一次会话编辑（日期 / 字数）。
  final StatSessionEditOf onEdit;

  /// 行的合集名解析器；不传（或返回 null）的行只显示条目名。
  final StatSessionCollectionOf? collectionOf;

  /// 每删掉一行 / 改完一行后回调（sheet 用它记「动过」让调用方关 sheet 后重聚合）。
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
            // BUG-2417：媒体名常年比一行宽（长篇番剧标题、带副标题的书名），
            // 单行 ellipsis 只看得到开头几个字。本区块的父容器（页面 sliver /
            // sheet 的 Column）高度自由，放到 2 行不会撑破谁。
            titleMaxLines: 2,
            title: _buildTitle(context, s),
            subtitle: Text(
              '${formatStatSessionRange(s.startAt, s.endAt)} · '
              '${formatStatSessionMeta(s)}',
            ),
            // 整行 = 编辑入口（见文件头：trailing 放不下第二颗按钮）。
            onTap: () => unawaited(_edit(s)),
            trailing: IconButton(
              tooltip: t.stat_session_delete,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => unawaited(_confirmAndDelete(s)),
            ),
          ),
      ],
    );
  }

  /// 行标题：命中合集时在条目名上方挂合集小标签（与「按书 / 按视频」tile
  /// 同一 [buildStatCollectionLabel] 视觉），未命中只有条目名。
  Widget _buildTitle(BuildContext context, StudySession s) {
    final String? collection = _collectionOf(s);
    final Text title = Text(_titleOf(s));
    if (collection == null) return title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        buildStatCollectionLabel(context, collection),
        title,
      ],
    );
  }

  String _titleOf(StudySession s) {
    final String title = widget.titleOf(s);
    return title.isEmpty ? s.mediaKey : title;
  }

  /// 合集名，空串按「无合集」处理（解析器可能给出空名合集）。
  String? _collectionOf(StudySession s) {
    final String? name = widget.collectionOf?.call(s);
    return name == null || name.isEmpty ? null : name;
  }

  /// 确认框是纯文本单行，合集名走 ' - ' 前缀（[collectionQualifiedTitle] 同口径）。
  String _confirmName(StudySession s) {
    final String? collection = _collectionOf(s);
    final String title = _titleOf(s);
    return collection == null ? title : '$collection - $title';
  }

  /// 改一行：弹编辑框 → 写库 → 通知调用方整页重聚合。
  ///
  /// 本地那行同时换成 [StudySession.withEdit] 的展示副本：区块里这一步会被随后
  /// 重聚合传下来的新列表覆盖（[didUpdateWidget]），无所谓；在 sheet 里它是**唯一**
  /// 会动的东西——sheet 拿的是打开那一刻的快照，页面在底下重聚合不会让 sheet 跟着
  /// 变，不就地换用户改完看到的还是旧值。真相仍以重聚合为准（改完日期的会话可能
  /// 与相邻会话合并成一条，副本算不出来），关掉 sheet 之后看到的才是最终形态。
  Future<void> _edit(StudySession s) async {
    final StudySessionEdit? edit = await showStatSessionEditDialog(
      context,
      itemTitle: _confirmName(s),
      startAt: s.startAt,
      chars: s.chars,
    );
    if (edit == null || !mounted) return;
    await widget.onEdit(s, edit);
    if (!mounted) return;
    final int at = _rows.indexOf(s);
    if (at >= 0) setState(() => _rows[at] = s.withEdit(edit));
    widget.onDeleted?.call();
  }

  Future<void> _confirmAndDelete(StudySession s) async {
    final bool confirmed = await confirmDeleteStatistics(
      context,
      '${_confirmName(s)}\n${formatStatSessionRange(s.startAt, s.endAt)}',
      message: t.stat_session_delete_message,
    );
    if (!confirmed || !mounted) return;
    await widget.onDelete(s);
    if (!mounted) return;
    setState(() => _rows.remove(s));
    widget.onDeleted?.call();
  }
}

/// 全部会话 / 某媒体的会话 sheet。返回是否动过（删 / 改，true = 调用方重聚合）。
///
/// 与页面内区块用的是同一个 [StatSessionList]，所以「每条都能改、能删、能一次清光」
/// 在这里和在区块里逐字节同形——用户 2026-09-10「所有会话都要可编辑」指的正是
/// 「全部会话」这一屏也算数。
Future<bool> showStatSessionsSheet(
  BuildContext context, {
  required String title,
  required List<StudySession> sessions,
  required StatSessionTitleOf titleOf,
  required Future<void> Function(StudySession session) onDelete,
  required StatSessionEditOf onEdit,
  required StatSessionClearAll onClearAll,
  StatSessionCollectionOf? collectionOf,
}) async {
  bool touched = false;
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
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(title, style: tokens.type.sectionLabel),
                  ),
                  if (sessions.isNotEmpty)
                    _StatSessionsClearAllButton(
                      sessions: sessions,
                      onClearAll: (List<StudySession> batch) async {
                        touched = true;
                        await onClearAll(batch);
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                    ),
                ],
              ),
              SizedBox(height: tokens.spacing.gap / 2),
              if (sessions.isEmpty)
                Text(t.stat_sessions_empty, style: tokens.type.metadata)
              else
                StatSessionList(
                  sessions: sessions,
                  titleOf: titleOf,
                  collectionOf: collectionOf,
                  onDelete: onDelete,
                  onEdit: onEdit,
                  onDeleted: () => touched = true,
                ),
            ],
          ),
        ),
      );
    },
  );
  return touched;
}
