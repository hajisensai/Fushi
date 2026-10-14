import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';

/// 设置 → 外观 → 功能模块 里「有底栏 tab 的模块」那一块：每行一个开关，整块可
/// 拖动排序（鼠标按下即拖、触屏长按拖）。顺序写进 [ModuleId.orderPrefKey]，
/// 底栏 / 宽屏 rail / macOS 侧栏经 `homeActiveTabs` 同一真值跟着变。
///
/// 只列**本平台存在**的导航模块（[modules] 由调用方按 [ModuleId.availableOn]
/// 过滤好）；平台上不存在的模块在存储顺序里的位置原样保留（[reorderVisibleModules]）。
class NavModuleOrderList extends StatefulWidget {
  const NavModuleOrderList({
    required this.settingsContext,
    required this.modules,
    required this.identityOf,
    required this.onEnabledChanged,
    super.key,
  });

  final SettingsContext settingsContext;

  /// 按当前顺序排好的、本平台存在的导航模块。
  final List<ModuleId> modules;

  /// 行标题与图标（与底栏同一真值，见 settings_schema_appearance 的
  /// `moduleNavIdentity`）。
  final ({String label, IconData icon}) Function(ModuleId module) identityOf;

  /// 开关翻转（含「至少保留一个导航模块」的拒绝逻辑，与无 tab 模块的开关共用）。
  final Future<void> Function(ModuleId module, bool enabled) onEnabledChanged;

  @override
  State<NavModuleOrderList> createState() => _NavModuleOrderListState();
}

/// 把 [visible]（本平台存在的那几个模块）里 `from → to` 的一次拖拽，落回覆盖
/// 全部模块的完整顺序 [full]：只重排 [visible] 占着的那些位置，其余模块（平台上
/// 不存在的、没有 tab 的）位置不动。[to] 是**最终下标**（FushiReorderableColumn
/// 语义）。
List<ModuleId> reorderVisibleModules({
  required List<ModuleId> full,
  required List<ModuleId> visible,
  required int from,
  required int to,
}) {
  final List<ModuleId> moved = <ModuleId>[...visible];
  moved.insert(to, moved.removeAt(from));
  final Set<ModuleId> slots = visible.toSet();
  int next = 0;
  return <ModuleId>[
    for (final ModuleId id in full) slots.contains(id) ? moved[next++] : id,
  ];
}

class _NavModuleOrderListState extends State<NavModuleOrderList> {
  /// 拖拽提交后、偏好落库前的乐观顺序：FushiReorderableColumn 提交即复位成恒等
  /// 映射，父级若还按旧顺序重建，行会先弹回原位再跳到新位。
  List<ModuleId>? _pendingOrder;

  List<ModuleId> get _modules {
    final List<ModuleId>? pending = _pendingOrder;
    if (pending == null) return widget.modules;
    final Set<ModuleId> shown = widget.modules.toSet();
    return <ModuleId>[
      for (final ModuleId id in pending)
        if (shown.contains(id)) id,
    ];
  }

  Future<void> _reorder(int from, int to) async {
    if (from == to) return;
    final List<ModuleId> full = reorderVisibleModules(
      full: widget.settingsContext.appModel.moduleVisibility.ordered,
      visible: _modules,
      from: from,
      to: to,
    );
    setState(() => _pendingOrder = full);
    await widget.settingsContext.appModel.setModuleOrder(full);
    if (!mounted) return;
    setState(() => _pendingOrder = null);
    widget.settingsContext.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<ModuleId> modules = _modules;
    // 自实现的 FushiReorderableColumn 而非 SDK ReorderableListView：整棵树活在
    // FushiAppUiScale 的 Transform.scale 之下，SDK 拖拽浮层不认祖先缩放会漂移
    // （BUG-044 / BUG-778，守卫 reorderable_scale_safety_guard_test）。
    return FushiReorderableColumn(
      itemCount: modules.length,
      keyForIndex: (int index) =>
          ValueKey<String>('nav-module-${modules[index].name}'),
      onReorder: (int from, int to) => unawaited(_reorder(from, to)),
      itemBuilder: (BuildContext context, int index) {
        final ModuleId module = modules[index];
        final ({String label, IconData icon}) identity = widget.identityOf(
          module,
        );
        final bool enabled = widget.settingsContext.appModel.moduleEnabled(
          module,
        );
        return FushiListItem(
          key: ValueKey<String>('nav-module-row-${module.name}'),
          leading: FushiListLeadingIcon(
            identity.icon,
            tone: enabled ? FushiCardTone.secondary : FushiCardTone.neutral,
          ),
          title: Text(
            identity.label,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
          onTap: () => unawaited(widget.onEnabledChanged(module, !enabled)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiSwitch(
                key: ValueKey<String>('nav-module-switch-${module.name}'),
                value: enabled,
                onChanged: (bool value) =>
                    unawaited(widget.onEnabledChanged(module, value)),
              ),
              const SizedBox(width: 8),
              ExcludeSemantics(
                child: FushiIcon(
                  Icons.drag_indicator,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
