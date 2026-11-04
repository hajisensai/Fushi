import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart' show appProvider;
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show focusedEditableText;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/utils/components/fushi_header_search.dart'
    show FushiHeaderSearchController;

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

  /// [event] 是否命中当前生效的 [ShortcutAction.librarySearch] 绑定（读用户
  /// 绑定、裸键在输入框里放行）。页头搜索与常驻搜索框（[FushiSearchFocusKeys]）
  /// 共用这一份判据。
  static bool matchesLibrarySearch(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    for (final InputBinding binding in _bindings(context)) {
      if (_matches(binding, event)) return true;
    }
    return false;
  }

  KeyEventResult _onKey(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final FushiHeaderSearchController? search = resolve();
    if (search == null) return KeyEventResult.ignored;
    if (matchesLibrarySearch(context, event)) {
      search.expand();
      return KeyEventResult.handled;
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

/// 常驻搜索框（不是页头里可展开的搜索）的搜索快捷键：命中
/// [ShortcutAction.librarySearch] 的绑定（默认 Ctrl+F / macOS ⌘F 与 `/`）时把焦点
/// 交给 [focusNode] 并全选 [controller] 里已有的查询。判据与
/// [FushiHeaderSearchKeys] 同一份（[FushiHeaderSearchKeys.matchesLibrarySearch]）。
///
/// 包在页面内容外面：焦点在卡片、按钮或分段上都认。[focusNode] 当前没挂在树上
/// （搜索框随列表滚出视口被回收）时放行，不吞键。
class FushiSearchFocusKeys extends StatelessWidget {
  const FushiSearchFocusKeys({
    required this.focusNode,
    required this.child,
    this.controller,
    super.key,
  });

  final FocusNode focusNode;
  final TextEditingController? controller;
  final Widget child;

  KeyEventResult _onKey(BuildContext context, KeyEvent event) {
    if (focusNode.context == null) return KeyEventResult.ignored;
    if (!FushiHeaderSearchKeys.matchesLibrarySearch(context, event)) {
      return KeyEventResult.ignored;
    }
    focusNode.requestFocus();
    final TextEditingController? controller = this.controller;
    if (controller != null) {
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
    }
    return KeyEventResult.handled;
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
