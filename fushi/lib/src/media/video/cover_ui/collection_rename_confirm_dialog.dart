/// 合集刮削改名确认弹窗（BUG-1310 复议口径）。
///
/// 「在线匹配封面」原先除了换封面还会**静默**把合集名改成刮到的正式名：菜单一字未
/// 提、改完无法撤销，且 `renameMediaCollection` 会给旧名写合集级同步墓碑，把其他设备
/// 上的旧名副本一并删掉。系统又分不出当前这个名字是文件夹名还是用户亲手起的，所以
/// 「问一次」是唯一防线——这里刻意不做任何「名字看着像自动生成就直接改」的启发式。
library;

import 'package:flutter/material.dart';

import 'package:fushi/utils.dart';

/// 弹「旧名 → 新名」确认框。
///
/// 返回值即 `applyCollectionScrape` 的 `confirmedTitle`：
/// - 用户点「重命名」→ [proposedName]（照原样返回，用户看到什么就写什么）；
/// - 点「保留当前名称」、点弹窗外、按返回键 → null，合集名一字不动。
///
/// 默认动作是**保留**：`barrierDismissible` 下随手点掉等价于拒绝，误触不会改名。
Future<String?> showCollectionRenameConfirmDialog({
  required BuildContext context,
  required String currentName,
  required String proposedName,
}) {
  return showAppDialog<String>(
    context: context,
    builder: (BuildContext ctx) => CollectionRenameConfirmDialog(
      currentName: currentName,
      proposedName: proposedName,
    ),
  );
}

/// 弹窗主体（导出便于 widget 测试直接构造）。
class CollectionRenameConfirmDialog extends StatelessWidget {
  const CollectionRenameConfirmDialog({
    super.key,
    required this.currentName,
    required this.proposedName,
  });

  /// 合集当前名（用户可能亲手起的，也可能是文件夹名——系统分不出来）。
  final String currentName;

  /// 刮到的条目正名。
  final String proposedName;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.video_scrape_collection_rename_title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.video_scrape_collection_rename_body,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          // 旧名和新名各占一行、都带标签：只显示新名的话用户无从判断这次改动是什么，
          // 「→ 一行连排」在长名字下会折行折成看不出边界的一团。
          Text(
            t.video_scrape_collection_rename_from(name: currentName),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            t.video_scrape_collection_rename_to(name: proposedName),
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.video_scrape_collection_rename_keep),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(proposedName),
          child: Text(t.video_scrape_collection_rename_confirm),
        ),
      ],
    );
  }
}
