/// 「合并进共享复习库」的确认框（拍板台 design-srs-shared-library 方案 a，组合阶段 5；设计 §4.3）。
///
/// 内核在两边都还在的时候算好冲突（同 guid 的笔记里字段 / 笔记类型 / 删除状态不同的，`SrsLibraryMergePlan.preview`），
/// 这里只呈现：规模摘要、冲突表（每条逐个选保留共享库还是这个库，默认共享库；「改得更晚」只是提示），确认后在框里跑
/// 合并（内核一个事务，没有逐步进度，显示不定进度条），成功关框、交回结果；失败框里报错、什么都没改。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_library_merge.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveSegmentedButton;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiLinearProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 跑合并（调用方给：经配置视图模型在配置变更锁里做）。
typedef SrsLibraryMergeRunner =
    Future<SrsMergeResult> Function(Map<String, SrsMergeChoice> resolutions);

/// 弹确认框；确认并合并成功返回结果，取消返回 null。合并失败时框里报错（[errorText] 把异常转成给人看的话）。
Future<SrsMergeResult?> showSrsLibraryMergeDialog(
  BuildContext context, {
  required SrsLibraryMergePlan plan,
  required SrsLibraryMergeRunner run,
  required String Function(Object error) errorText,
}) => showAppDialog<SrsMergeResult>(
  context: context,
  builder: (BuildContext _) =>
      SrsLibraryMergeDialog(plan: plan, run: run, errorText: errorText),
);

/// 确认框本体（测试直接挂）。
class SrsLibraryMergeDialog extends StatefulWidget {
  const SrsLibraryMergeDialog({
    required this.plan,
    required this.run,
    required this.errorText,
    super.key,
  });

  final SrsLibraryMergePlan plan;
  final SrsLibraryMergeRunner run;
  final String Function(Object error) errorText;

  @override
  State<SrsLibraryMergeDialog> createState() => _SrsLibraryMergeDialogState();
}

class _SrsLibraryMergeDialogState extends State<SrsLibraryMergeDialog> {
  /// 用户改成保留「这个库」的冲突笔记；没列的保留共享库。
  final Map<String, SrsMergeChoice> _choices = <String, SrsMergeChoice>{};
  bool _running = false;
  String? _error;

  Future<void> _merge() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final SrsMergeResult result = await widget.run(
        Map<String, SrsMergeChoice>.of(_choices),
      );
      if (mounted) Navigator.of(context).pop(result);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = widget.errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final SrsMergePreview p = widget.plan.preview;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<SrsMergeConflict> conflicts = p.conflicts;
    // 合并在跑时不让点遮罩 / 系统返回关框：内核事务照样会跑完，关了框结果与报错就没处交代了。
    return PopScope<SrsMergeResult>(
      canPop: !_running,
      child: FushiAlertDialog(
        key: const ValueKey<String>('srs_library_merge_dialog'),
        icon: const FushiIcon(Icons.merge_type),
        title: Text(t.srs_library_merge_title(name: widget.plan.profileName)),
        content: SizedBox(
          width: 560,
          child: FushiEntranceScope(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiStaggeredEntrance(
                  index: 0,
                  child: Text(
                    t.srs_library_merge_summary(
                      notes: '${p.notes}',
                      reviews: '${p.reviews}',
                      added: '${p.added}',
                      shared: '${p.shared}',
                    ),
                  ),
                ),
                SizedBox(height: tokens.spacing.gap),
                FushiStaggeredEntrance(
                  index: 1,
                  child: Text(
                    conflicts.isEmpty
                        ? t.srs_library_merge_no_conflicts
                        : t.srs_library_merge_conflicts(
                            n: '${conflicts.length}',
                          ),
                    style: text.titleSmall,
                  ),
                ),
                if (conflicts.isNotEmpty)
                  Flexible(
                    child: ListView.builder(
                      key: const ValueKey<String>(
                        'srs_library_merge_conflicts',
                      ),
                      shrinkWrap: true,
                      itemCount: conflicts.length,
                      itemBuilder: fushiStaggeredItemBuilder(
                        (BuildContext context, int i) => _ConflictTile(
                          conflict: conflicts[i],
                          choice:
                              _choices[conflicts[i].note] ??
                              SrsMergeChoice.shared,
                          enabled: !_running,
                          onChanged: (SrsMergeChoice c) => setState(() {
                            if (c == SrsMergeChoice.shared) {
                              _choices.remove(conflicts[i].note);
                            } else {
                              _choices[conflicts[i].note] = c;
                            }
                          }),
                        ),
                      ),
                    ),
                  ),
                if (_running) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  Text(t.srs_library_merge_running),
                  const SizedBox(height: 4),
                  const FushiLinearProgressIndicator(),
                ],
                if (_error case final String error) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  Text(
                    error,
                    key: const ValueKey<String>('srs_library_merge_error'),
                    style: text.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          FushiTextButton(
            key: const ValueKey<String>('srs_library_merge_cancel'),
            onPressed: _running ? null : () => Navigator.of(context).pop(),
            child: Text(t.dialog_cancel),
          ),
          FushiFilledButton(
            key: const ValueKey<String>('srs_library_merge_confirm'),
            onPressed: _running ? null : _merge,
            child: Text(t.srs_library_merge_confirm),
          ),
        ],
      ),
    );
  }
}

/// 冲突表的一条：两边的差异 + 选保留哪一边。
class _ConflictTile extends StatelessWidget {
  const _ConflictTile({
    required this.conflict,
    required this.choice,
    required this.enabled,
    required this.onChanged,
  });

  final SrsMergeConflict conflict;
  final SrsMergeChoice choice;
  final bool enabled;
  final ValueChanged<SrsMergeChoice> onChanged;

  String _or(String v) => v.trim().isEmpty ? t.srs_library_merge_empty : v;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final SrsMergeConflict c = conflict;
    final String title = _or(
      c.shared.sortField.isNotEmpty ? c.shared.sortField : c.merged.sortField,
    );
    final List<(String, String, String)> rows = <(String, String, String)>[
      if (c.noteTypeDiffers)
        (
          t.srs_library_merge_note_type,
          c.shared.noteTypeName ?? c.shared.noteType,
          c.merged.noteTypeName ?? c.merged.noteType,
        ),
      if (c.deletedDiffers)
        (
          t.srs_library_merge_deleted,
          c.shared.deleted ? t.srs_library_merge_deleted : '—',
          c.merged.deleted ? t.srs_library_merge_deleted : '—',
        ),
      for (final SrsMergeFieldDiff f in c.fields)
        (f.name ?? f.field, _or(f.shared), _or(f.merged)),
    ];
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.gap),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaces.card,
          borderRadius: FushiBorderRadius.card,
        ),
        child: Padding(
          padding: EdgeInsets.all(tokens.spacing.card),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: text.titleSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              for (final (String label, String shared, String merged) in rows)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(label, style: text.labelMedium),
                      Text(
                        t.srs_library_merge_side_value(
                          side: t.srs_library_merge_keep_shared,
                          value: shared,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        t.srs_library_merge_side_value(
                          side: t.srs_library_merge_keep_merged,
                          value: merged,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              SizedBox(height: tokens.spacing.gap / 2),
              IgnorePointer(
                ignoring: !enabled,
                child: adaptiveSegmentedButton<SrsMergeChoice>(
                  context: context,
                  segments: <ButtonSegment<SrsMergeChoice>>[
                    ButtonSegment<SrsMergeChoice>(
                      value: SrsMergeChoice.shared,
                      label: Text(
                        c.mergedIsNewer
                            ? t.srs_library_merge_keep_shared
                            : t.srs_library_merge_side_newer(
                                side: t.srs_library_merge_keep_shared,
                              ),
                      ),
                    ),
                    ButtonSegment<SrsMergeChoice>(
                      value: SrsMergeChoice.merged,
                      label: Text(
                        c.mergedIsNewer
                            ? t.srs_library_merge_side_newer(
                                side: t.srs_library_merge_keep_merged,
                              )
                            : t.srs_library_merge_keep_merged,
                      ),
                    ),
                  ],
                  selected: <SrsMergeChoice>{choice},
                  onSelectionChanged: (Set<SrsMergeChoice> next) {
                    if (next.isNotEmpty) onChanged(next.first);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
