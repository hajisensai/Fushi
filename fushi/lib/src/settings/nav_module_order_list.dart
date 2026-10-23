import 'dart:async';

import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 设置 → 外观 → 功能模块 里「有底栏 tab 的模块」那一块：每行一个开关，整块可
/// 拖动排序（鼠标按下即拖、触屏长按拖）。拖拽只吃指针，所以每行另有「上移 /
/// 下移」两颗可聚焦按钮（键盘 Enter / 手柄 A）和同名的无障碍自定义动作，与词典
/// 管理的音频源列表同一套。顺序写进 [ModuleId.orderPrefKey]，
/// 底栏 / 宽屏 rail / macOS 侧栏经 `homeActiveTabs` 同一真值跟着变。
///
/// 只列**本平台存在**的导航模块（[modules] 由调用方按 [ModuleId.availableOn]
/// 过滤好）；平台上不存在的模块在存储顺序里的位置原样保留（[reorderVisibleModules]）。
///
/// 末尾（或用户拖到的位置）另有一行「设置」（反馈 TqJ_xq3UlO）：可拖、可上移下移，
/// 但没有开关——设置恒在，是全部模块关光后的回退面。它的位置以
/// [ModuleVisibility.settingsSlot] 存进同一个顺序键。
class NavModuleOrderList extends StatefulWidget {
  const NavModuleOrderList({
    required this.settingsContext,
    required this.modules,
    required this.identityOf,
    required this.settingsIdentity,
    required this.onEnabledChanged,
    this.hintOf,
    super.key,
  });

  final SettingsContext settingsContext;

  /// 按当前顺序排好的、本平台存在的导航模块。
  final List<ModuleId> modules;

  /// 行标题与图标（与底栏同一真值，见 settings_schema_appearance 的
  /// `moduleNavIdentity`）。
  final ({String label, IconData icon}) Function(ModuleId module) identityOf;

  /// 「设置」行的标题与图标（与底栏设置 tab 同一真值）。
  final ({String label, IconData icon}) settingsIdentity;

  /// 开关翻转（含「至少保留一个导航模块」的拒绝逻辑，与无 tab 模块的开关共用）。
  final Future<void> Function(ModuleId module, bool enabled) onEnabledChanged;

  /// 行副标题：默认关的模块（复习）要说清打开后会多出什么；null = 无副标题。
  final String? Function(ModuleId module)? hintOf;

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

/// [reorderVisibleModules] 的导航版：[full] 是含「设置」（`null`）的完整导航顺序
/// （[ModuleVisibility.navOrder]），[visible] 是列表里显示的行（同样含 `null`）。
List<ModuleId?> reorderVisibleNavEntries({
  required List<ModuleId?> full,
  required List<ModuleId?> visible,
  required int from,
  required int to,
}) {
  final List<ModuleId?> moved = <ModuleId?>[...visible];
  moved.insert(to, moved.removeAt(from));
  final Set<ModuleId?> slots = visible.toSet();
  int next = 0;
  return <ModuleId?>[
    for (final ModuleId? id in full) slots.contains(id) ? moved[next++] : id,
  ];
}

class _NavModuleOrderListState extends State<NavModuleOrderList> {
  /// 拖拽提交后、偏好落库前的乐观顺序：FushiReorderableColumn 提交即复位成恒等
  /// 映射，父级若还按旧顺序重建，行会先弹回原位再跳到新位。
  List<ModuleId?>? _pendingOrder;

  /// 列表的行：显示的模块按导航顺序排，`null` 是「设置」那一行。
  List<ModuleId?> get _entries {
    final List<ModuleId?> order =
        _pendingOrder ??
        widget.settingsContext.appModel.moduleVisibility.navOrder;
    final Set<ModuleId> shown = widget.modules.toSet();
    final List<ModuleId?> rows = <ModuleId?>[
      for (final ModuleId? id in order)
        if (id == null || shown.contains(id)) id,
    ];
    // 显示的模块有不在导航顺序里的（调用方给的是另一份真值）：按调用方顺序补在
    // 设置之前，绝不丢行。
    for (final ModuleId id in widget.modules) {
      if (!rows.contains(id)) rows.insert(rows.indexOf(null), id);
    }
    return rows;
  }

  Future<void> _reorder(int from, int to) async {
    if (from == to) return;
    final List<ModuleId?> full = reorderVisibleNavEntries(
      full: widget.settingsContext.appModel.moduleVisibility.navOrder,
      visible: _entries,
      from: from,
      to: to,
    );
    setState(() => _pendingOrder = full);
    try {
      await widget.settingsContext.appModel.setModuleOrder(<ModuleId>[
        ...full.whereType<ModuleId>(),
      ], settingsSlot: full.indexOf(null));
    } finally {
      // 落库失败也要清掉乐观顺序：否则列表永远显示一个没存上的顺序，与底栏
      // （读的是偏好真值）对不上，之后的拖拽还会基于这份假顺序继续算。
      if (mounted) {
        setState(() => _pendingOrder = null);
        widget.settingsContext.refresh();
      }
    }
  }

  /// 拖拽与按钮共用的提交入口。回调签名是同步的，落库失败交给
  /// [FlutterError.reportError]（进全局错误日志），而不是变成无人接的 Future 错误。
  void _commitReorder(int from, int to) {
    unawaited(
      _reorder(from, to).catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'settings',
            context: ErrorDescription('while saving the navigation tab order'),
          ),
        );
      }),
    );
  }

  /// 键盘 / 手柄 / 读屏的重排入口：把第 [index] 行与相邻行对调。
  void _move(int index, int delta) {
    final int target = index + delta;
    if (target < 0 || target >= _entries.length) return;
    _commitReorder(index, target);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<ModuleId?> modules = _entries;
    // 自实现的 FushiReorderableColumn 而非 SDK ReorderableListView：整棵树活在
    // FushiAppUiScale 的 Transform.scale 之下，SDK 拖拽浮层不认祖先缩放会漂移
    // （BUG-044 / BUG-778，守卫 reorderable_scale_safety_guard_test）。
    return FushiReorderableColumn(
      itemCount: modules.length,
      keyForIndex: (int index) =>
          ValueKey<String>('nav-module-${modules[index]?.name ?? 'settings'}'),
      onReorder: _commitReorder,
      itemBuilder: (BuildContext context, int index) {
        final ModuleId? entry = modules[index];
        final bool canMoveUp = index > 0;
        final bool canMoveDown = index < modules.length - 1;
        if (entry == null) {
          return _buildSettingsRow(
            context,
            index: index,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
          );
        }
        final ModuleId module = entry;
        final ({String label, IconData icon}) identity = widget.identityOf(
          module,
        );
        final bool enabled = widget.settingsContext.appModel.moduleEnabled(
          module,
        );
        final String? hint = widget.hintOf?.call(module);
        return Semantics(
          key: ValueKey<String>('nav-module-semantics-${module.name}'),
          customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
            if (canMoveUp)
              CustomSemanticsAction(label: t.move_up): () => _move(index, -1),
            if (canMoveDown)
              CustomSemanticsAction(label: t.move_down): () => _move(index, 1),
          },
          child: FushiListItem(
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
            subtitle: hint == null ? null : Text(hint),
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
                ..._moveControls(
                  name: module.name,
                  index: index,
                  canMoveUp: canMoveUp,
                  canMoveDown: canMoveDown,
                  scheme: scheme,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 拖拽把手的键盘 / 手柄等价物（手柄抓不住把手）。命中区走宽命中区
  /// （MD3 48dp），不要再收窄 padding。
  List<Widget> _moveControls({
    required String name,
    required int index,
    required bool canMoveUp,
    required bool canMoveDown,
    required ColorScheme scheme,
  }) => <Widget>[
    FushiIconButton(
      key: ValueKey<String>('nav-module-up-$name'),
      icon: FushiIcons.expandLess,
      size: 18,
      tooltip: t.move_up,
      enabled: canMoveUp,
      isWideTapArea: true,
      onTap: () => _move(index, -1),
    ),
    FushiIconButton(
      key: ValueKey<String>('nav-module-down-$name'),
      icon: FushiIcons.expandMore,
      size: 18,
      tooltip: t.move_down,
      enabled: canMoveDown,
      isWideTapArea: true,
      onTap: () => _move(index, 1),
    ),
    ExcludeSemantics(
      child: FushiIcon(
        FushiIcons.dragIndicator,
        color: scheme.onSurfaceVariant,
      ),
    ),
  ];

  /// 「设置」行：与模块行同一套拖拽 / 上移下移 / 读屏动作，但没有开关——设置恒在。
  Widget _buildSettingsRow(
    BuildContext context, {
    required int index,
    required bool canMoveUp,
    required bool canMoveDown,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final ({String label, IconData icon}) identity = widget.settingsIdentity;
    return Semantics(
      key: const ValueKey<String>('nav-module-semantics-settings'),
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        if (canMoveUp)
          CustomSemanticsAction(label: t.move_up): () => _move(index, -1),
        if (canMoveDown)
          CustomSemanticsAction(label: t.move_down): () => _move(index, 1),
      },
      child: FushiListItem(
        key: const ValueKey<String>('nav-module-row-settings'),
        leading: FushiListLeadingIcon(
          identity.icon,
          tone: FushiCardTone.secondary,
        ),
        title: Text(
          identity.label,
          style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurface),
        ),
        subtitle: Text(t.settings_module_nav_settings_always_on),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ..._moveControls(
              name: 'settings',
              index: index,
              canMoveUp: canMoveUp,
              canMoveDown: canMoveDown,
              scheme: scheme,
            ),
          ],
        ),
      ),
    );
  }
}
