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
class NavModuleOrderList extends StatefulWidget {
  const NavModuleOrderList({
    required this.settingsContext,
    required this.modules,
    required this.identityOf,
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
    try {
      await widget.settingsContext.appModel.setModuleOrder(full);
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
    if (target < 0 || target >= _modules.length) return;
    _commitReorder(index, target);
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
      onReorder: _commitReorder,
      itemBuilder: (BuildContext context, int index) {
        final ModuleId module = modules[index];
        final ({String label, IconData icon}) identity = widget.identityOf(
          module,
        );
        final bool enabled = widget.settingsContext.appModel.moduleEnabled(
          module,
        );
        final String? hint = widget.hintOf?.call(module);
        final bool canMoveUp = index > 0;
        final bool canMoveDown = index < modules.length - 1;
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
                // 拖拽把手的键盘 / 手柄等价物（手柄抓不住把手）。命中区走宽命中区
                // （MD3 48dp），不要再收窄 padding。
                FushiIconButton(
                  key: ValueKey<String>('nav-module-up-${module.name}'),
                  icon: FushiIcons.expandLess,
                  size: 18,
                  tooltip: t.move_up,
                  enabled: canMoveUp,
                  isWideTapArea: true,
                  onTap: () => _move(index, -1),
                ),
                FushiIconButton(
                  key: ValueKey<String>('nav-module-down-${module.name}'),
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
              ],
            ),
          ),
        );
      },
    );
  }
}
