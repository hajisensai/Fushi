import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/app_model.dart' show appProvider;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show focusedEditableText;
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiSearchFieldSize, FushiShellHeaderActions;
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellActionsSlot;
import 'package:fushi/src/utils/fushi_icons.dart';

// 库页「可展开搜索的单行页头」（2026-10-14 用户定案）。
//
// 库页顶部从「页签 + 动作 / 常驻搜索框 + 工具」两行收成一行：搜索平时只是
// 页头动作里一颗恒外露的 🔍；点开后**整行**页头换成 M3E 搜索栏
// （← 返回 · 输入框 · 有内容时 ✕），下方网格按输入实时过滤，不另开结果页。
//
// - [FushiHeaderSearchController]：展开态 + 查询的真相（文本由页面持有的
//   [TextEditingController] 承载，搜索词照旧只活在本次会话、不落库）。
// - [fushiHeaderSearchButton]：页头里的 🔍（[FushiIconButton.alwaysVisible]，
//   永不收进 ⋯）。[FushiPageHeader] 收到 `search` 时自动把它排在动作首位。
// - [FushiHeaderSearchBar]：展开后占满整行的搜索栏。库页外壳的浮动工具栏行
//   （`FushiFloatingChromeBar`）与独立使用的页头行都用它替换整行。
// - [FushiHeaderSearchKeys]：快捷键 [ShortcutAction.librarySearch]（可在快捷键
//   设置里改绑，默认 Ctrl+F / macOS ⌘F 与 `/`）展开搜索；搜索展开时 Esc 先清空、
//   再收起。
//
// 收起语义：← / 第二次 Esc 是「退出搜索」，收起即清空搜索词——收起后页头上
// 看不见搜索框，留着过滤词只会让人以为库里东西少了。收起后焦点回到 🔍。

/// 库页页头搜索的展开态与查询。
class FushiHeaderSearchController extends ChangeNotifier {
  FushiHeaderSearchController({
    required this.textController,
    required this.buttonFocusId,
    required this.onQueryChanged,
    required this.hintText,
    this.fieldKey,
  });

  /// 搜索词载体（页面持有，搜索词只影响本次会话、不落库）。
  final TextEditingController textController;

  /// 页头 🔍 的焦点 id：收起后焦点回到它（多个库页同时保活，各自一个）。
  final FushiFocusId buttonFocusId;

  /// 用户确定下来的查询（IME 组字期间不出，见 [FushiSearchQueryDriver]）。
  ValueChanged<String> onQueryChanged;

  /// 输入框占位文案。
  String hintText;

  /// 挂在输入框本体上的 key（测试 / 集成测试按它定位）。
  final Key? fieldKey;

  /// 输入框的焦点（展开时自动聚焦；再按 Ctrl+F 重新落回并全选）。
  final FocusNode fieldFocusNode = FocusNode(
    debugLabel: 'fushi-header-search-field',
  );

  bool _expanded = false;

  /// 页头当前是否整行切成搜索栏。
  bool get expanded => _expanded;

  /// 有没有生效中的搜索词。
  bool get hasQuery => textController.text.isNotEmpty;

  /// 展开搜索栏（已展开时把焦点落回输入框并全选）。
  void expand() {
    if (_expanded) {
      fieldFocusNode.requestFocus();
      textController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: textController.text.length,
      );
      return;
    }
    _expanded = true;
    notifyListeners();
    // 搜索栏挂载时的 autofocus 只在焦点域里还没有焦点时生效（点 🔍 / 焦点停在
    // 卡片上时都不成立），显式落焦。notifyListeners 已排了重建帧，post-frame
    // 回调一定跑得到；此时输入框已挂载。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (_expanded) fieldFocusNode.requestFocus();
    });
  }

  /// 清空搜索词（不收起）。
  void clear() {
    if (textController.text.isEmpty) return;
    textController.clear();
    onQueryChanged('');
  }

  /// 退出搜索：清空搜索词、收起，焦点回到页头的 🔍。[context] 用来找焦点根。
  void collapse(BuildContext context) {
    if (!_expanded) return;
    clear();
    _expanded = false;
    final FushiFocusController? focus = FushiFocusRoot.maybeControllerOf(
      context,
    );
    notifyListeners();
    // 收起会重建页头（🔍 重新挂载、重新登记焦点目标），等这一帧画完再落焦。
    // notifyListeners 已让监听的页头排了重建帧，post-frame 回调一定跑得到。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      focus?.requestById(buttonFocusId);
    });
  }

  @override
  void dispose() {
    fieldFocusNode.dispose();
    super.dispose();
  }
}

/// 页头里的 🔍：恒外露（不收进 ⋯），收起时仍有搜索词则右上角亮圆点。
FushiIconButton fushiHeaderSearchButton(FushiHeaderSearchController search) {
  return FushiIconButton(
    key: const ValueKey<String>('fushi-header-search-button'),
    icon: FushiIcons.search,
    tooltip: t.search,
    focusId: search.buttonFocusId,
    alwaysVisible: true,
    badge: !search.expanded && search.hasQuery,
    onTap: search.expand,
  );
}

/// 库页外壳动作槽里当前可见那份页头的搜索（没有 / 不支持搜索时为 null）。
FushiHeaderSearchController? fushiVisibleHeaderSearch(
  FushiShellActionsSlot slot,
) {
  final Widget? actions = slot.actions;
  return actions is FushiShellHeaderActions ? actions.search : null;
}

bool _isComposing(TextEditingController controller) {
  final TextRange range = controller.value.composing;
  return range.isValid && !range.isCollapsed;
}

/// 展开后占满整行的搜索栏：M3E search bar（MD3 56 高填充胶囊 / Apple 搜索
/// 胶囊），← 退出搜索、有内容时 ✕ 清空，挂载即聚焦输入框。
///
/// Esc：有内容先清空；空框再按收起（与 ← 同一条 [FushiHeaderSearchController.collapse]）。
/// 焦点在 ← / ✕ 上时同样认。IME 组字中的 Esc 归输入法。
class FushiHeaderSearchBar extends StatelessWidget {
  const FushiHeaderSearchBar({required this.controller, super.key});

  final FushiHeaderSearchController controller;

  KeyEventResult _onKey(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (_isComposing(controller.textController)) return KeyEventResult.ignored;
    if (controller.hasQuery) {
      controller.clear();
    } else {
      controller.collapse(context);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (FocusNode _, KeyEvent event) => _onKey(context, event),
      child: FocusTraversalGroup(
        child: FushiSearchBar(
          key: const ValueKey<String>('fushi-header-search-bar'),
          fieldKey: controller.fieldKey,
          controller: controller.textController,
          focusNode: controller.fieldFocusNode,
          hintText: controller.hintText,
          size: FushiSearchFieldSize.large,
          autofocus: true,
          onBack: () => controller.collapse(context),
          // 有内容的 Esc 由搜索栏自己清空；空框的 Esc 放行到上面那层收起。
          escapeBehavior: FushiSearchEscapeBehavior.clear,
          onQueryChanged: (String query) => controller.onQueryChanged(query),
        ),
      ),
    );
  }
}

/// 库页搜索快捷键：命中 [ShortcutAction.librarySearch] 的绑定（用户在快捷键设置
/// 里改过就按改过的，默认 Ctrl+F / macOS ⌘F 与 `/`）时展开 [resolve] 给出的
/// 搜索；搜索展开、焦点在页面其它地方时 Esc 先清空、再收起。
///
/// 包在库页外壳（页签 + 内容）外面：焦点在页签、动作或网格卡片上都认。
/// [resolve] 返回 null（当前视图没有搜索）时全部放行。它挂在首页键事件节点之下，
/// 所以库页里同一个键先归库页搜索；库页之外首页照常解析（homeFocusSearch 等）。
/// 不带 Ctrl / Alt / Meta 的绑定（如 `/`）在焦点停在输入框里时放行给输入框。
class FushiHeaderSearchKeys extends StatelessWidget {
  const FushiHeaderSearchKeys({
    required this.resolve,
    required this.child,
    super.key,
  });

  final FushiHeaderSearchController? Function() resolve;
  final Widget child;

  /// 当前生效的 librarySearch 绑定：有 ProviderScope 且注册表已装载时读用户
  /// 绑定；否则（没挂 ProviderScope 的组件测试、启动早期）回落平台默认。
  static List<InputBinding> _bindings(BuildContext context) {
    final bool hasScope =
        context
            .getElementForInheritedWidgetOfExactType<
              UncontrolledProviderScope
            >() !=
        null;
    if (hasScope) {
      final registry = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider).shortcutRegistry;
      if (registry.isLoaded) {
        return registry
            .bindingsFor(ShortcutAction.librarySearch)
            .keyboardBindings;
      }
    }
    return ShortcutDefaults.forPlatform(
          defaultTargetPlatform,
        )[ShortcutAction.librarySearch]?.keyboardBindings ??
        const <InputBinding>[];
  }

  static bool _matches(InputBinding binding, KeyEvent event) {
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool bare =
        !binding.modifiers.contains(ModifierKey.ctrl) &&
        !binding.modifiers.contains(ModifierKey.alt) &&
        !binding.modifiers.contains(ModifierKey.meta);
    // 裸键（`/` 之类）在输入框里是要打进去的字符。
    if (bare && focusedEditableText() != null) return false;
    if (binding.toActivator(includeRepeats: false).accepts(event, keyboard)) {
      return true;
    }
    // 非 US 布局上 `/` 要按 Shift（德语 Shift+7）：逻辑键与修饰键都对不上，
    // 按产出的字符认（与改造前写死的判据一致）。
    return binding.key == LogicalKeyboardKey.slash &&
        binding.modifiers.isEmpty &&
        event.character == '/' &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed;
  }

  KeyEventResult _onKey(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final FushiHeaderSearchController? search = resolve();
    if (search == null) return KeyEventResult.ignored;
    for (final InputBinding binding in _bindings(context)) {
      if (_matches(binding, event)) {
        search.expand();
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        search.expanded &&
        focusedEditableText() == null) {
      if (search.hasQuery) {
        search.clear();
      } else {
        search.collapse(context);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (FocusNode _, KeyEvent event) => _onKey(context, event),
      child: child,
    );
  }
}
