import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart'
    show srsReviewBridgeTokens;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 反馈 itlb0djDq6：SRS 复习页的按键接入快捷键注册表（[ShortcutScope.srsReview]）。
///
/// 钉住「出厂默认与改造前 `_onKey` 写死的键逐条一致」——用户不改设置时手感一个键都
/// 不变；以及 WebView 卡面持焦时键盘桥导出的 token 能覆盖这些默认键（含小键盘）。
void main() {
  FushiShortcutRegistry registryFor(TargetPlatform platform) =>
      FushiShortcutRegistry()..loadDefaults(platform);

  ShortcutAction? kb(
    FushiShortcutRegistry r,
    LogicalKeyboardKey key, [
    Set<ModifierKey> mods = const <ModifierKey>{},
  ]) => r.resolveKeyboard(key, modifiers: mods, scope: ShortcutScope.srsReview);

  /// 改造前写死的键 → 现在应解析到的动作（Ctrl 组合在桌面默认里是 Ctrl）。
  final Map<(LogicalKeyboardKey, Set<ModifierKey>), ShortcutAction>
  legacy = <(LogicalKeyboardKey, Set<ModifierKey>), ShortcutAction>{
    (LogicalKeyboardKey.space, <ModifierKey>{}):
        ShortcutAction.srsReviewPrimary,
    (LogicalKeyboardKey.enter, <ModifierKey>{}):
        ShortcutAction.srsReviewPrimary,
    (LogicalKeyboardKey.numpadEnter, <ModifierKey>{}):
        ShortcutAction.srsReviewPrimary,
    (LogicalKeyboardKey.digit1, <ModifierKey>{}): ShortcutAction.srsReviewAgain,
    (LogicalKeyboardKey.numpad1, <ModifierKey>{}):
        ShortcutAction.srsReviewAgain,
    (LogicalKeyboardKey.digit2, <ModifierKey>{}): ShortcutAction.srsReviewHard,
    (LogicalKeyboardKey.numpad2, <ModifierKey>{}): ShortcutAction.srsReviewHard,
    (LogicalKeyboardKey.digit3, <ModifierKey>{}): ShortcutAction.srsReviewGood,
    (LogicalKeyboardKey.numpad3, <ModifierKey>{}): ShortcutAction.srsReviewGood,
    (LogicalKeyboardKey.digit4, <ModifierKey>{}): ShortcutAction.srsReviewEasy,
    (LogicalKeyboardKey.numpad4, <ModifierKey>{}): ShortcutAction.srsReviewEasy,
    (LogicalKeyboardKey.keyR, <ModifierKey>{}):
        ShortcutAction.srsReviewReplayAudio,
    (LogicalKeyboardKey.keyZ, <ModifierKey>{ModifierKey.ctrl}):
        ShortcutAction.srsReviewUndo,
    (LogicalKeyboardKey.equal, <ModifierKey>{ModifierKey.ctrl}):
        ShortcutAction.srsReviewZoomIn,
    (LogicalKeyboardKey.add, <ModifierKey>{ModifierKey.ctrl}):
        ShortcutAction.srsReviewZoomIn,
    (LogicalKeyboardKey.numpadAdd, <ModifierKey>{ModifierKey.ctrl}):
        ShortcutAction.srsReviewZoomIn,
    (LogicalKeyboardKey.minus, <ModifierKey>{ModifierKey.ctrl}):
        ShortcutAction.srsReviewZoomOut,
    (LogicalKeyboardKey.numpadSubtract, <ModifierKey>{ModifierKey.ctrl}):
        ShortcutAction.srsReviewZoomOut,
    (LogicalKeyboardKey.digit0, <ModifierKey>{ModifierKey.ctrl}):
        ShortcutAction.srsReviewZoomReset,
    (LogicalKeyboardKey.numpad0, <ModifierKey>{ModifierKey.ctrl}):
        ShortcutAction.srsReviewZoomReset,
  };

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    test('$platform：出厂默认与改造前写死的键逐条一致，手柄 A = 主键', () {
      final FushiShortcutRegistry r = registryFor(platform);
      legacy.forEach((
        (LogicalKeyboardKey, Set<ModifierKey>) k,
        ShortcutAction expected,
      ) {
        expect(kb(r, k.$1, k.$2), expected, reason: '${k.$1.keyLabel} ${k.$2}');
      });
      expect(
        r.resolveGamepad(GamepadButton.a, scope: ShortcutScope.srsReview),
        ShortcutAction.srsReviewPrimary,
      );
      // Esc / Alt+← 不归本页：冒泡给 universal 的「返回上一级」。
      expect(kb(r, LogicalKeyboardKey.escape), isNull);
      expect(
        kb(r, LogicalKeyboardKey.arrowLeft, <ModifierKey>{ModifierKey.alt}),
        isNull,
      );
      expect(
        r.resolveGamepad(GamepadButton.b, scope: ShortcutScope.srsReview),
        isNull,
      );
      // 改造前带 Shift / Alt 的裸键一律放行，现在精确匹配同样不中。
      expect(
        kb(r, LogicalKeyboardKey.space, <ModifierKey>{ModifierKey.shift}),
        isNull,
      );
    });
  }

  test('macOS：⌘ 与 Ctrl 两种撤销 / 缩放都认（改造前就是「Ctrl 或 ⌘」）', () {
    final FushiShortcutRegistry r = registryFor(TargetPlatform.macOS);
    for (final ModifierKey mod in <ModifierKey>[
      ModifierKey.ctrl,
      ModifierKey.meta,
    ]) {
      expect(
        kb(r, LogicalKeyboardKey.keyZ, <ModifierKey>{mod}),
        ShortcutAction.srsReviewUndo,
      );
      expect(
        kb(r, LogicalKeyboardKey.equal, <ModifierKey>{mod}),
        ShortcutAction.srsReviewZoomIn,
      );
      expect(
        kb(r, LogicalKeyboardKey.minus, <ModifierKey>{mod}),
        ShortcutAction.srsReviewZoomOut,
      );
      expect(
        kb(r, LogicalKeyboardKey.digit0, <ModifierKey>{mod}),
        ShortcutAction.srsReviewZoomReset,
      );
    }
    expect(kb(r, LogicalKeyboardKey.space), ShortcutAction.srsReviewPrimary);
  });

  test('键盘桥导出的 token 覆盖默认键（含小键盘）与「返回上一级」，且能反解析回同一绑定', () {
    final FushiShortcutRegistry r = registryFor(TargetPlatform.windows);
    final List<String> tokens = srsReviewBridgeTokens(r);
    expect(
      tokens,
      containsAll(<String>[
        'Space',
        'Enter',
        'NumpadEnter',
        'Digit1',
        'Numpad1',
        'Numpad4',
        'KeyR',
        'Ctrl+KeyZ',
        'Ctrl+Equal',
        'Ctrl+NumpadAdd',
        'Ctrl+NumpadSubtract',
        'Ctrl+Numpad0',
        'Escape',
        'Alt+ArrowLeft',
      ]),
    );
    expect(tokens.toSet().length, tokens.length, reason: 'token 去重');
    for (final String token in tokens) {
      expect(InputBinding.fromBridgeToken(token), isNotNull, reason: token);
    }
    final InputBinding numpad = InputBinding.fromBridgeToken('Ctrl+NumpadAdd')!;
    expect(numpad.key, LogicalKeyboardKey.numpadAdd);
    expect(numpad.modifiers, <ModifierKey>{ModifierKey.ctrl});
    // 持久化格式不变：小键盘仍是 #<keyId>，桥 token 只在桥里用。
    expect(
      const InputBinding(key: LogicalKeyboardKey.numpad1).serialize(),
      startsWith('#'),
    );
  });

  test('改键后桥 token 跟着变：把「良好」改成 G，桥表有 KeyG、没有 Digit3', () {
    final FushiShortcutRegistry r = registryFor(TargetPlatform.windows)
      ..updateBinding(
        ShortcutAction.srsReviewGood,
        const ShortcutBindingSet(
          keyboardBindings: <InputBinding>[
            InputBinding(key: LogicalKeyboardKey.keyG),
          ],
        ),
      );
    final List<String> tokens = srsReviewBridgeTokens(r);
    expect(tokens, contains('KeyG'));
    expect(tokens, isNot(contains('Digit3')));
    expect(kb(r, LogicalKeyboardKey.keyG), ShortcutAction.srsReviewGood);
    expect(kb(r, LogicalKeyboardKey.digit3), isNull);
  });

  test('快捷键设置页的「SRS 复习」卡片跟着复习模块开关走', () {
    expect(moduleOfShortcutScope(ShortcutScope.srsReview), ModuleId.srs);
    expect(ShortcutScope.srsReview.channels, <ShortcutChannel>{
      ShortcutChannel.keyboard,
      ShortcutChannel.gamepad,
    });
    expect(ShortcutScope.srsReview.coactiveScopes, <ShortcutScope>[
      ShortcutScope.srsReview,
    ]);
  });
}
