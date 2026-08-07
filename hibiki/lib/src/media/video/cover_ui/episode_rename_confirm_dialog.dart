import 'package:flutter/material.dart';

import 'package:fushi/src/media/video/scraper/episode_rename.dart';
import 'package:fushi/utils.dart';

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

  void _setAllChecked(bool checked) {
    setState(() {
      _checked.clear();
      if (checked) {
        _checked.addAll(<String>[
          for (final EpisodeRenameProposal p in widget.proposals) p.bookUid,
        ]);
      }
    });
  }

  void _setChecked(String bookUid, bool checked) {
    setState(() {
      if (checked) {
        _checked.add(bookUid);
      } else {
        _checked.remove(bookUid);
      }
    });
  }

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
            // 全选/取消行：共享 MD3 行 + 裸 [Checkbox] 为 leading，整行 onTap
            // 翻转——等价旧 CheckboxListTile 的取值/回调/标题，走设计令牌行高。
            HibikiListItem(
              key: const ValueKey<String>('episode-rename-select-all'),
              density: HibikiListDensity.compact,
              onTap: () => _setAllChecked(!_allChecked),
              leading: Checkbox(
                value: _allChecked,
                onChanged: (bool? value) => _setAllChecked(value ?? false),
              ),
              title: Text(t.backup_export_select_all),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.proposals.length,
                itemBuilder: (BuildContext context, int index) {
                  final EpisodeRenameProposal p = widget.proposals[index];
                  final bool checked = _checked.contains(p.bookUid);
                  return HibikiListItem(
                    key: ValueKey<String>('episode-rename-row-${p.bookUid}'),
                    density: HibikiListDensity.compact,
                    onTap: () => _setChecked(p.bookUid, !checked),
                    leading: Checkbox(
                      value: checked,
                      onChanged: (bool? value) =>
                          _setChecked(p.bookUid, value ?? false),
                    ),
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
