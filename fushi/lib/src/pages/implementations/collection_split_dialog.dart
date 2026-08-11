import 'package:flutter/material.dart';

import 'package:fushi/utils.dart';

/// 「按季拆分合集」预览弹窗（TODO-2489）：每季一节（新合集名可编辑 + 成员清单）
/// + 「保留原合集」勾选。返回 null = 取消。
///
/// BUG-1543 起成员清单**可手动调整**：勾选若干集 →「移动到」某个已有组或新建
/// 组。自动分季只是起点，不是判决——文件名千奇百怪，总有引擎认不出的形态，
/// 而用户一眼就知道哪集属于哪季。没有这个逃生口时，识别一失手整个功能就废了
/// （用户原话：「按季拆分也没办法手动拆」）。
///
/// 注意「保留原合集」的语义是**成员不动**（原合集继续作全系列入口）：数据层
/// `removeFromCollection*` 在合集清空时会自动删除该合集，「保留空壳」在数据
/// 模型上不存在；合集成员本就允许多归属，拆分只是给每季再建一个归属映射。

/// 待拆分的一个成员：稳定 id（条目 `bookUid`）+ 展示标题。
///
/// 有 id 才能做「移动」——纯标题列表挪不动东西（重名集会互相冒充）。
class CollectionSplitMember {
  const CollectionSplitMember({required this.id, required this.title});

  final String id;
  final String title;
}

class CollectionSplitPlanSection {
  const CollectionSplitPlanSection({
    required this.defaultName,
    required this.members,
    this.isSeason = true,
  });

  /// 默认新合集名（「原名 第N季」）。
  final String defaultName;

  /// 该组成员（预览展示 + 手动移动的操作对象）。
  final List<CollectionSplitMember> members;

  /// 是否「真实季」：PV·特典组为 false，不进前传/续作关系链。
  final bool isSeason;
}

/// 用户确认后的一组：新合集名 + 组内成员 id（已按组内序）。
class CollectionSplitGroupChoice {
  const CollectionSplitGroupChoice({
    required this.name,
    required this.memberIds,
    required this.isSeason,
  });

  final String name;
  final List<String> memberIds;
  final bool isSeason;
}

/// 用户确认的拆分方案：逐组（名字 + 成员）+ 是否保留原合集。
///
/// 手动移动之后组与传入 sections **不再一一对应**（可能空掉、可能新增），故这里
/// 携带完整成员归属，调用方一律按本结果落盘，不要再回头读原 sections。
class CollectionSplitChoice {
  const CollectionSplitChoice({
    required this.groups,
    required this.keepOriginal,
  });

  final List<CollectionSplitGroupChoice> groups;
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

/// 弹窗内的一组可变状态：名字控制器 + 成员（会被移动增删）+ 是否真实季。
class _SplitGroup {
  _SplitGroup({
    required this.controller,
    required this.members,
    required this.isSeason,
  });

  final TextEditingController controller;
  final List<CollectionSplitMember> members;
  final bool isSeason;
}

class _CollectionSplitDialogState extends State<CollectionSplitDialog> {
  late final List<_SplitGroup> _groups = <_SplitGroup>[
    for (final CollectionSplitPlanSection s in widget.sections)
      _SplitGroup(
        controller: TextEditingController(text: s.defaultName),
        members: List<CollectionSplitMember>.of(s.members),
        isSeason: s.isSeason,
      ),
  ];

  /// 已勾选待移动的成员 id（可跨组勾选，一次移动到同一个目标组）。
  final Set<String> _selected = <String>{};

  /// 默认保留原合集（非破坏性默认；删除是显式选择）。
  bool _keepOriginal = true;

  @override
  void dispose() {
    for (final _SplitGroup g in _groups) {
      g.controller.dispose();
    }
    super.dispose();
  }

  /// 名字校验只看**非空组**：被搬空的组确认时会被丢弃，不该因为它拦住按钮。
  bool get _namesValid => _groups
      .where((_SplitGroup g) => g.members.isNotEmpty)
      .every((_SplitGroup g) => g.controller.text.trim().isNotEmpty);

  /// 把勾选的成员移到第 [targetIndex] 组（[targetIndex] < 0 = 新建一组）。
  ///
  /// 先按**组序 + 组内序**收齐被选中的成员再统一追加到目标组尾部：跨组多选时
  /// 落点顺序稳定可预期，不受勾选先后影响。
  void _moveSelectedTo(int targetIndex) {
    if (_selected.isEmpty) return;
    final List<CollectionSplitMember> moving = <CollectionSplitMember>[
      for (final _SplitGroup g in _groups)
        for (final CollectionSplitMember m in g.members)
          if (_selected.contains(m.id)) m,
    ];
    if (moving.isEmpty) return;
    setState(() {
      for (final _SplitGroup g in _groups) {
        g.members
            .removeWhere((CollectionSplitMember m) => _selected.contains(m.id));
      }
      final _SplitGroup target = targetIndex < 0
          ? _appendNewGroup()
          : _groups[targetIndex.clamp(0, _groups.length - 1)];
      target.members.addAll(moving);
      _selected.clear();
    });
  }

  /// 新建一组并返回它。组名去重（`createMediaCollection` 按 (name, type) 复用，
  /// 同名会把两组悄悄并成一个合集）。
  _SplitGroup _appendNewGroup() {
    final String base = t.collection_split_new_group;
    final Set<String> taken = <String>{
      for (final _SplitGroup g in _groups) g.controller.text.trim(),
    };
    String name = base;
    for (int i = 2; taken.contains(name); i++) {
      name = '$base $i';
    }
    final _SplitGroup group = _SplitGroup(
      controller: TextEditingController(text: name),
      members: <CollectionSplitMember>[],
      isSeason: true,
    );
    _groups.add(group);
    return group;
  }

  void _toggleMember(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

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
              for (int i = 0; i < _groups.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 16),
                TextField(
                  key: ValueKey<String>('collection-split-name-$i'),
                  controller: _groups[i].controller,
                  decoration: const InputDecoration(isDense: true),
                  onChanged: (String _) => setState(() {}),
                ),
                const SizedBox(height: 6),
                _memberList(_groups[i], cs),
              ],
              const SizedBox(height: 8),
              _moveBar(cs),
              const SizedBox(height: 8),
              // 共享 MD3 行 + 裸 Checkbox 为 leading，整行 onTap 翻转——等价旧
              // CheckboxListTile 的取值/回调/标题，但走设计令牌的行高与内边距。
              FushiListItem(
                key: const ValueKey<String>('collection-split-keep-original'),
                density: FushiListDensity.compact,
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
          onPressed: !_namesValid ? null : _confirm,
          child: Text(t.collection_split_confirm),
        ),
      ],
    );
  }

  /// 组内成员清单：每行一个可勾选条目。高度封顶 + 懒构建，几百集的合集也不会
  /// 把弹窗撑爆或卡住。
  Widget _memberList(_SplitGroup group, ColorScheme cs) {
    if (group.members.isEmpty) {
      return Text(
        t.collection_empty,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: cs.onSurfaceVariant),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 150),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: group.members.length,
        itemBuilder: (BuildContext context, int index) {
          final CollectionSplitMember m = group.members[index];
          return InkWell(
            key: ValueKey<String>('collection-split-member-${m.id}'),
            onTap: () => _toggleMember(m.id),
            child: Row(
              children: <Widget>[
                Checkbox(
                  value: _selected.contains(m.id),
                  onChanged: (bool? _) => _toggleMember(m.id),
                ),
                Expanded(
                  child: Text(
                    m.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 「已选 N 集 → 移动到 …」操作条。未勾选时整条禁用（不隐藏，免得用户找不到
  /// 这个能力）。
  Widget _moveBar(ColorScheme cs) {
    final bool enabled = _selected.isNotEmpty;
    return Row(
      children: <Widget>[
        Text(
          t.collection_split_selected(n: _selected.length),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: enabled ? cs.onSurface : cs.onSurfaceVariant,
              ),
        ),
        const SizedBox(width: 12),
        PopupMenuButton<int>(
          key: const ValueKey<String>('collection-split-move-to'),
          enabled: enabled,
          onSelected: _moveSelectedTo,
          itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
            for (int i = 0; i < _groups.length; i++)
              PopupMenuItem<int>(
                value: i,
                child: Text(
                  _groups[i].controller.text.trim().isEmpty
                      ? '#${i + 1}'
                      : _groups[i].controller.text.trim(),
                ),
              ),
            const PopupMenuDivider(),
            PopupMenuItem<int>(
              value: -1,
              child: Text(t.collection_split_new_group),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(
              t.collection_split_move_to,
              style: TextStyle(
                color: enabled ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 确认：丢掉被搬空的组（空合集在数据模型上不存在），其余按当前归属返回。
  void _confirm() {
    Navigator.of(context).pop(CollectionSplitChoice(
      groups: <CollectionSplitGroupChoice>[
        for (final _SplitGroup g in _groups)
          if (g.members.isNotEmpty)
            CollectionSplitGroupChoice(
              name: g.controller.text.trim(),
              memberIds: <String>[
                for (final CollectionSplitMember m in g.members) m.id,
              ],
              isSeason: g.isSeason,
            ),
      ],
      keepOriginal: _keepOriginal,
    ));
  }
}
