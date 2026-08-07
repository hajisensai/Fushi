import 'package:flutter/material.dart';

import 'package:fushi/utils.dart';

/// 「按季拆分合集」预览弹窗（TODO-2489）：每季一节（新合集名可编辑 + 成员清单）
/// + 「保留原合集」勾选。返回 null = 取消。
///
/// 注意「保留原合集」的语义是**成员不动**（原合集继续作全系列入口）：数据层
/// `removeFromCollection*` 在合集清空时会自动删除该合集，「保留空壳」在数据
/// 模型上不存在；合集成员本就允许多归属，拆分只是给每季再建一个归属映射。
class CollectionSplitPlanSection {
  const CollectionSplitPlanSection({
    required this.defaultName,
    required this.memberTitles,
  });

  /// 默认新合集名（「原名 第N季」）。
  final String defaultName;

  /// 该季成员标题（预览展示用）。
  final List<String> memberTitles;
}

/// 用户确认的拆分方案：逐季新合集名（与传入 sections 同序）+ 是否保留原合集。
class CollectionSplitChoice {
  const CollectionSplitChoice({
    required this.names,
    required this.keepOriginal,
  });

  final List<String> names;
  final bool keepOriginal;
}

Future<CollectionSplitChoice?> showCollectionSplitDialog({
  required BuildContext context,
  required List<CollectionSplitPlanSection> sections,
}) {
  return showAppDialog<CollectionSplitChoice>(
    context: context,
    builder: (_) => CollectionSplitDialog(sections: sections),
  );
}

/// 导出 widget 便于测试直接构造。
class CollectionSplitDialog extends StatefulWidget {
  const CollectionSplitDialog({required this.sections, super.key});

  final List<CollectionSplitPlanSection> sections;

  @override
  State<CollectionSplitDialog> createState() => _CollectionSplitDialogState();
}

class _CollectionSplitDialogState extends State<CollectionSplitDialog> {
  late final List<TextEditingController> _nameCtrls = <TextEditingController>[
    for (final CollectionSplitPlanSection s in widget.sections)
      TextEditingController(text: s.defaultName),
  ];

  /// 默认保留原合集（非破坏性默认；删除是显式选择）。
  bool _keepOriginal = true;

  @override
  void dispose() {
    for (final TextEditingController ctrl in _nameCtrls) {
      ctrl.dispose();
    }
    super.dispose();
  }

  bool get _namesValid => _nameCtrls
      .every((TextEditingController ctrl) => ctrl.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(t.collection_split_by_season),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (int i = 0; i < widget.sections.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 16),
                TextField(
                  key: ValueKey<String>('collection-split-name-$i'),
                  controller: _nameCtrls[i],
                  decoration: const InputDecoration(isDense: true),
                  onChanged: (String _) => setState(() {}),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.sections[i].memberTitles.join(' · '),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  // 成员清单是次要说明文本：走 MD3 文本角色（bodySmall 随
                  // textScale 缩放），不再钉死 12px。
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 8),
              // 共享 MD3 行 + 裸 Checkbox 为 leading，整行 onTap 翻转——等价旧
              // CheckboxListTile 的取值/回调/标题，但走设计令牌的行高与内边距。
              HibikiListItem(
                key: const ValueKey<String>('collection-split-keep-original'),
                density: HibikiListDensity.compact,
                padding: EdgeInsets.zero,
                onTap: () => setState(() => _keepOriginal = !_keepOriginal),
                leading: Checkbox(
                  value: _keepOriginal,
                  onChanged: (bool? value) =>
                      setState(() => _keepOriginal = value ?? true),
                ),
                title: Text(t.collection_split_keep_original),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
        TextButton(
          onPressed: !_namesValid
              ? null
              : () => Navigator.of(context).pop(CollectionSplitChoice(
                    names: <String>[
                      for (final TextEditingController ctrl in _nameCtrls)
                        ctrl.text.trim(),
                    ],
                    keepOriginal: _keepOriginal,
                  )),
          child: Text(t.collection_split_confirm),
        ),
      ],
    );
  }
}
