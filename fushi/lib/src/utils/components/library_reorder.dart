import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 库页 / 合集页的「排序模式」入口（书架、漫画库、视频库、游戏库与合集详情页
/// 共用一套逻辑）。
///
/// 长按卡片一律到时即弹条目菜单（与库页卡片 `InkWell.onLongPress` 同一时机），
/// 不再兼任拿起拖拽；触屏要重排，从条目菜单里的「排序」进入排序模式，再按住
/// 卡片拖动（[FushiReorderableGrid.reordering]），底部 [LibraryReorderBar] 的
/// 「完成」退出。鼠标照旧按住即拖。
///
/// 页面 State 混入本 mixin；`showMediaItemActions` 弹菜单时经
/// [libraryReorderEntryOf] 从调用方 context（页面 State 自身或其后代）找到入口，
/// 带进菜单路由（[LibraryReorderScope]），`MediaItemDialogFrame` 据此在动作清单里
/// 补一项「排序」——所有条目菜单（书 / 漫画 / 字幕书 / 视频 / 游戏 / 合集卡 /
/// 远端占位）都只经这一处接线，不必逐个菜单加动作。
mixin LibraryReorderHost<T extends StatefulWidget> on State<T> {
  /// 进入本页排序模式；null = 此刻不提供（多选中、没有可排的网格等）。
  VoidCallback? get libraryReorderEntry;
}

/// 从 [context] 找排序入口：同步派发期间 [runWithLibraryReorder] 设置的入口
/// 优先（合集详情页把成员菜单交给库页的菜单构建时，库页 context 上的入口指的是
/// 库页，不是合集），其次菜单路由里的 [LibraryReorderScope]，最后是 context 所在
/// 的 [LibraryReorderHost] 页面（State 自身的 context 也算；该页所在路由不在最上层
/// 时不提供）。
VoidCallback? libraryReorderEntryOf(BuildContext context) {
  final VoidCallback? active = _activeLibraryReorder;
  if (active != null) return active;
  final LibraryReorderScope? scope = context
      .getInheritedWidgetOfExactType<LibraryReorderScope>();
  if (scope != null) return scope.onStartReorder;
  final LibraryReorderHost? host =
      context is StatefulElement && context.state is LibraryReorderHost
      ? context.state as LibraryReorderHost
      : context.findAncestorStateOfType<LibraryReorderHost>();
  if (host == null) return null;
  // 页面被别的路由盖住（如合集详情页压在库页上、键盘长按经库页的菜单构建弹出）
  // 时，「排序」不能指向底下看不见的库页。
  if (!(ModalRoute.of(host.context)?.isCurrent ?? true)) return null;
  return host.libraryReorderEntry;
}

/// 菜单路由里携带的排序入口（路由不在页面子树下，读不到页面 State）。
/// [onStartReorder] 为 null 表示已补过 / 不提供，挡住外层入口。
class LibraryReorderScope extends InheritedWidget {
  const LibraryReorderScope({
    required this.onStartReorder,
    required super.child,
    super.key,
  });

  final VoidCallback? onStartReorder;

  @override
  bool updateShouldNotify(LibraryReorderScope oldWidget) =>
      oldWidget.onStartReorder != onStartReorder;
}

VoidCallback? _activeLibraryReorder;

/// 在 [body] 同步执行期间把 [onStartReorder] 作为条目菜单的排序入口（压过
/// context 上的 [LibraryReorderScope]；可嵌套）。与 `runWithContextMenuAnchor`
/// 同一约定：菜单函数要在第一个 await 之前弹出。
void runWithLibraryReorder(VoidCallback onStartReorder, VoidCallback body) {
  final VoidCallback? previous = _activeLibraryReorder;
  _activeLibraryReorder = onStartReorder;
  try {
    body();
  } finally {
    _activeLibraryReorder = previous;
  }
}

/// 库页 / 合集页「排序模式」的底部浮动栏：提示「拖动卡片调整顺序」+「完成」。
///
/// 本组件只是那颗胶囊；放进页面 [Stack] 用 [LibraryReorderBar.overlay]（底边居中 +
/// [FushiChromeReveal] 进出），放进 Column 底部的由页面套与多选批量栏同一个
/// `FushiSpringReveal`。
class LibraryReorderBar extends StatelessWidget {
  const LibraryReorderBar({required this.onDone, super.key});

  final VoidCallback onDone;

  /// 叠在页面 [Stack] 上的形态：底边居中，[visible] 翻转时弹簧进出。
  static Widget overlay({
    required BuildContext context,
    required bool visible,
    required VoidCallback onDone,
  }) => Positioned(
    left: 0,
    right: 0,
    bottom: FushiDesignTokens.of(context).spacing.card,
    child: FushiChromeReveal(
      visible: visible,
      from: AxisDirection.down,
      child: Center(child: LibraryReorderBar(onDone: onDone)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ({
      Color container,
      Color foreground,
      Color selectedContainer,
      Color selectedForeground,
    })
    palette = fushiFloatingToolbarPalette(context);
    return FushiFloatingPill(
      key: const ValueKey<String>('library_reorder_bar'),
      color: palette.container,
      padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 6, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(
            FushiIcons.dragIndicator,
            size: 20,
            color: palette.foreground,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              t.library_reorder_hint,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(color: palette.foreground),
            ),
          ),
          const SizedBox(width: 12),
          FushiFilledButton(
            key: const ValueKey<String>('library_reorder_done'),
            onPressed: onDone,
            child: Text(t.library_reorder_done),
          ),
        ],
      ),
    );
  }
}
