import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/scraper/episode_rename.dart';
import 'package:hibiki/utils.dart';

/// 「按刮削重命名各集」确认弹窗（TODO-2491 UI）：逐行旧名 → 新名对照 + 勾选，
/// 支持全选/取消。与合集改名确认（collection_rename_confirm_dialog.dart，
/// PR#635）同风格：裸 [AlertDialog]、默认动作 = 不改（关掉/返回键零写入）。
///
/// 返回勾选的提案子集；null = 取消（一条都不改）。落库由调用方逐条
/// `updateVideoBookTitle`（与库页手动重命名同一落库口）。
Future<List<EpisodeRenameProposal>?> showEpisodeRenameConfirmDialog({
  required BuildContext context,
  required List<EpisodeRenameProposal> proposals,
}) {
  return showAppDialog<List<EpisodeRenameProposal>>(
    context: context,
    builder: (_) => EpisodeRenameConfirmDialog(proposals: proposals),
  );
}

/// 导出 widget 便于测试直接构造（与 CollectionRenameConfirmDialog 同范式）。
class EpisodeRenameConfirmDialog extends StatefulWidget {
  const EpisodeRenameConfirmDialog({required this.proposals, super.key});

  final List<EpisodeRenameProposal> proposals;

  @override
  State<EpisodeRenameConfirmDialog> createState() =>
      _EpisodeRenameConfirmDialogState();
}

class _EpisodeRenameConfirmDialogState
    extends State<EpisodeRenameConfirmDialog> {
  /// 勾选态（bookUid 集合）；默认全选——本弹窗的常见路径就是「全部确认」。
  late final Set<String> _checked = <String>{
    for (final EpisodeRenameProposal p in widget.proposals) p.bookUid,
  };

  bool get _allChecked => _checked.length == widget.proposals.length;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(t.collection_episode_rename_title),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 全选/取消行。
            CheckboxListTile(
              key: const ValueKey<String>('episode-rename-select-all'),
              value: _allChecked,
              onChanged: (bool? value) => setState(() {
                _checked.clear();
                if (value ?? false) {
                  _checked.addAll(<String>[
                    for (final EpisodeRenameProposal p in widget.proposals)
                      p.bookUid,
                  ]);
                }
              }),
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(t.backup_export_select_all),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.proposals.length,
                itemBuilder: (BuildContext context, int index) {
                  final EpisodeRenameProposal p = widget.proposals[index];
                  return CheckboxListTile(
                    key: ValueKey<String>('episode-rename-row-${p.bookUid}'),
                    value: _checked.contains(p.bookUid),
                    onChanged: (bool? value) => setState(() {
                      if (value ?? false) {
                        _checked.add(p.bookUid);
                      } else {
                        _checked.remove(p.bookUid);
                      }
                    }),
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    // 旧名 → 新名两行分列（与合集改名确认同风格）。
                    title: Text(
                      p.oldTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                    subtitle: Text(
                      p.newTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
        TextButton(
          onPressed: _checked.isEmpty
              ? null
              : () => Navigator.of(context).pop(<EpisodeRenameProposal>[
                    for (final EpisodeRenameProposal p in widget.proposals)
                      if (_checked.contains(p.bookUid)) p,
                  ]),
          child: Text(t.collection_episode_rename_apply(n: _checked.length)),
        ),
      ],
    );
  }
}
