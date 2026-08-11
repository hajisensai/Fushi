import 'package:flutter/material.dart';
import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';
import 'package:fushi/src/sync/deletion_propagation_availability.dart';
import 'package:fushi/src/sync/sync_conflict_prompter.dart' show ConflictSource;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 通用「删除范围」确认弹窗：正文 + 「从所有设备删除」勾选框（默认不勾）。确认返回用户
/// 选的 [DeleteScope]（勾选=syncEverywhere 传播 / 不勾=keepLocalOnly 仅本机）；取消返回
/// null。供书架/视频/有声书等各删除入口共用（书架另有 ReaderHistoryDeleteDialog 变体）。
///
/// TODO-2470 死角②：传 [db] 时先查本机有没有删除传播通道（
/// [hasDeletionPropagationChannel]，纯本地零网络），没有就不渲染那个兑现不了的勾选框，
/// 改渲染一行说明。查询在 `showAppDialog` **之前**做完，弹窗自身仍是纯同步 widget、
/// 不做 IO。[db] 省略时保持旧行为（恒显示），供不便拿到 db 的入口与既有测试使用。
Future<DeleteScope?> showDeleteScopeConfirm(
  BuildContext context, {
  required String title,
  required String message,
  DeletionDisclosure? disclosure,
  FushiDatabase? db,
}) async {
  final bool canSyncEverywhere =
      db == null || await hasDeletionPropagationChannel(SyncRepository(db));
  if (!context.mounted) return null;
  return showAppDialog<DeleteScope>(
    context: context,
    builder: (_) => _DeleteScopeConfirmDialog(
      title: title,
      message: message,
      disclosure: disclosure,
      canSyncEverywhere: canSyncEverywhere,
    ),
  );
}

class _DeleteScopeConfirmDialog extends StatefulWidget {
  const _DeleteScopeConfirmDialog({
    required this.title,
    required this.message,
    this.disclosure,
    this.canSyncEverywhere = true,
  });
  final String title;
  final String message;
  final DeletionDisclosure? disclosure;

  /// false = 本机无任何删除传播通道，勾了也不可能生效 → 不渲染勾选框，恒 keepLocalOnly。
  final bool canSyncEverywhere;

  @override
  State<_DeleteScopeConfirmDialog> createState() =>
      _DeleteScopeConfirmDialogState();
}

class _DeleteScopeConfirmDialogState extends State<_DeleteScopeConfirmDialog> {
  bool _syncDelete = false;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: FushiModalSheetFrame(
        title: widget.title,
        leadingIcon: Icons.delete_outline,
        bodyPadding: EdgeInsets.fromLTRB(
            tokens.spacing.card, 0, tokens.spacing.card, tokens.spacing.gap),
        footerPadding: EdgeInsets.fromLTRB(tokens.spacing.card,
            tokens.spacing.gap, tokens.spacing.card, tokens.spacing.card),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.message, style: tokens.type.listSubtitle),
            if (widget.disclosure != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              DeletionDisclosureView(disclosure: widget.disclosure!),
            ],
            SizedBox(height: tokens.spacing.gap),
            if (widget.canSyncEverywhere)
              AdaptiveSettingsRow(
                title: t.delete_scope_sync_everywhere,
                subtitle: _syncDelete
                    ? t.delete_scope_sync_everywhere_desc
                    : t.delete_scope_keep_local_desc,
                onTap: () => setState(() => _syncDelete = !_syncDelete),
                trailing: Icon(
                  _syncDelete ? Icons.check_box : Icons.check_box_outline_blank,
                  color: _syncDelete
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              )
            else
              const DeleteScopeUnavailableNote(),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, null),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(
                  context,
                  widget.canSyncEverywhere && _syncDelete
                      ? DeleteScope.syncEverywhere
                      : DeleteScope.keepLocalOnly),
              child: Text(t.dialog_delete),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条删除候选 + 已解析的展示标题（itemKey 是 bookKey/bookUid/displayName，用户看不懂，
/// 由调用方预先解析成书名/视频名再传入）。
class DeletionCandidateView {
  const DeletionCandidateView({required this.candidate, required this.title});
  final DeletionPropagationCandidate candidate;
  final String title;
}

/// 应用用户确认的删除：逐条按 mediaType 删本地（keepLocalOnly，绝不回写墓碑）。
typedef ApplyDeletions = Future<void> Function(
    List<DeletionPropagationCandidate> confirmed);

/// 「其他设备已删除这些，本地也删？」逐条确认弹窗：候选列表 + 复选框（默认勾选），
/// 「全选 / 删除选中 / 取消」。确认返回勾选的候选列表；取消返回 null。
class DeletionPromptDialog extends StatefulWidget {
  const DeletionPromptDialog({required this.views, super.key});

  final List<DeletionCandidateView> views;

  @override
  State<DeletionPromptDialog> createState() => _DeletionPromptDialogState();
}

class _DeletionPromptDialogState extends State<DeletionPromptDialog> {
  late final Set<int> _checked;

  @override
  void initState() {
    super.initState();
    // 默认全选：同步删除是用户在源设备的明确意图，接收端默认跟随，用户可逐条取消保留。
    _checked = <int>{for (int i = 0; i < widget.views.length; i++) i};
  }

  void _toggle(int i) => setState(() {
        if (!_checked.remove(i)) _checked.add(i);
      });

  void _selectAll() => setState(() {
        if (_checked.length == widget.views.length) {
          _checked.clear();
        } else {
          _checked
            ..clear()
            ..addAll(<int>[for (int i = 0; i < widget.views.length; i++) i]);
        }
      });

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 460,
      maxHeightFactor: 0.8,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.delete_prompt_title,
        leadingIcon: Icons.delete_sweep_outlined,
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
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              child: Text(t.delete_prompt_message,
                  style: tokens.type.listSubtitle),
            ),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.44,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.views.length,
                  itemBuilder: (_, int i) {
                    final DeletionCandidateView v = widget.views[i];
                    return AdaptiveSettingsRow(
                      title: v.title,
                      onTap: () => _toggle(i),
                      trailing: Icon(
                        _checked.contains(i)
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                        color: _checked.contains(i)
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: _selectAll,
              child: Text(t.delete_prompt_select_all),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, null),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(
                context,
                <DeletionPropagationCandidate>[
                  for (final int i in _checked) widget.views[i].candidate,
                ],
              ),
              child: Text(t.delete_prompt_delete_selected),
            ),
          ],
        ),
      ),
    );
  }
}

/// 决定「删除确认框是否/此刻弹」+ 会话级防骚扰，经全局 navigatorKey 弹出并应用用户
/// 确认的删除，随后推进删除墓碑消费基线（已复核到 highWaterMs，压制已看过的、放行更新
/// 的删除）。范式仿 [SyncConflictPrompter]：纯内存单飞 + 随会话失效。
class DeletionPromptPrompter {
  bool dialogOpen = false;
  final Set<String> _snoozed = <String>{};

  static String _fp(DeletionPropagationCandidate c) =>
      '${c.mediaType}|${c.itemKey}';

  bool shouldPrompt({
    required List<DeletionCandidateView> views,
    required ConflictSource source,
    required bool inBook,
  }) {
    if (views.isEmpty) return false;
    if (dialogOpen) return false;
    if (source == ConflictSource.background) return false;
    if (source == ConflictSource.auto) {
      if (inBook) return false;
      final bool allSnoozed = views.every(
          (DeletionCandidateView v) => _snoozed.contains(_fp(v.candidate)));
      if (allSnoozed) return false;
    }
    return true;
  }

  void _markDismissed(List<DeletionCandidateView> views) {
    for (final DeletionCandidateView v in views) {
      _snoozed.add(_fp(v.candidate));
    }
  }

  /// 按 [shouldPrompt] 决策弹出确认框。用户确认（返回非 null 选择）→ [applyDeletions]
  /// 删本地 + **逐通道**推进基线到 [highWaterMsByScope]（本轮各通道已复核的最大删除
  /// 时刻）；取消（null）→ 本会话静默这批候选、不推进基线（下次会话再提醒）。
  ///
  /// BUG-1579：基线按通道分槽，故这里收的是「槽位 → 时刻」而不是一个标量。用一条
  /// 通道的时刻去推另一条通道的基线，会让后者还没复核过的删除被永久压制。
  Future<void> present({
    required GlobalKey<NavigatorState> navigatorKey,
    required FushiDatabase db,
    required List<DeletionCandidateView> views,
    required Map<String, int> highWaterMsByScope,
    required ApplyDeletions applyDeletions,
    required ConflictSource source,
    required bool inBook,
  }) async {
    if (!shouldPrompt(views: views, source: source, inBook: inBook)) return;
    final BuildContext? ctx = navigatorKey.currentContext;
    if (ctx == null) return; // navigatorKey 未 attach，null 安全。
    dialogOpen = true;
    try {
      final List<DeletionPropagationCandidate>? confirmed =
          await showAppDialog<List<DeletionPropagationCandidate>>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => DeletionPromptDialog(views: views),
      );
      if (confirmed == null) {
        // 取消 = 稍后再提醒：本会话静默，基线不动。
        _markDismissed(views);
        return;
      }
      if (confirmed.isNotEmpty) await applyDeletions(confirmed);
      // 用户已复核这批（无论删了几条）→ 逐通道推进基线，压制已看过的删除，放行更新的。
      final SyncRepository repo = SyncRepository(db);
      for (final MapEntry<String, int> e in highWaterMsByScope.entries) {
        if (e.value <= 0) continue;
        await repo.setDeletionTombstonesBaselineMs(
            SyncChannelScope.byId(e.key), e.value);
      }
    } finally {
      dialogOpen = false;
    }
  }
}
