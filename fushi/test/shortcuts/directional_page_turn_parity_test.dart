import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/directional_page_turn.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/manga_arrow_override.dart';
import 'package:fushi/src/shortcuts/reader_space_override.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 反馈 uz_2m0E_Eu：「书籍的方向键左右翻页和漫画的翻页不太一样」。
///
/// 小说与漫画的左右翻页方向现在走同一个原语 [resolveDirectionalPageTurn]。这里用
/// 真实默认键位表（五个平台）把按键事件 → 注册表 → 方向校正整条链路跑一遍，锁定
/// 「同一个物理键、同一种阅读方向，两种书翻向同一侧」，键盘与手柄 D-pad 都算。
void main() {
  const List<TargetPlatform> platforms = <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ];

  KeyDownEvent keyDown(LogicalKeyboardKey key) => KeyDownEvent(
    physicalKey: const PhysicalKeyboardKey(0),
    logicalKey: key,
    timeStamp: Duration.zero,
  );

  /// 把方向收成 'forward' / 'backward' / null，便于小说与漫画两套动作比较。
  String? direction(ShortcutAction? action) => switch (action) {
    ShortcutAction.readerPageForward ||
    ShortcutAction.mangaPageForward => 'forward',
    ShortcutAction.readerPageBackward ||
    ShortcutAction.mangaPageBackward => 'backward',
    _ => null,
  };

  /// 小说键盘路径（caret.part `_resolveReaderKeyboardShortcut` 的翻页部分）。
  ShortcutAction? novelKey(
    FushiShortcutRegistry registry,
    KeyEvent event, {
    required bool rtl,
  }) {
    final ShortcutAction? bound =
        registry.resolveKeyboard(
          event.logicalKey,
          modifiers: const <ModifierKey>{},
          scope: ShortcutScope.reader,
        ) ??
        registry.resolveKeyboard(
          event.logicalKey,
          modifiers: const <ModifierKey>{},
          scope: ShortcutScope.audiobook,
        );
    return resolveReaderArrowPageTurn(
          key: event.logicalKey,
          modifiers: const <ModifierKey>{},
          rtl: rtl,
          boundAction: bound,
        ) ??
        bound;
  }

  /// 漫画键盘路径（manga_fushi_page `_resolveMangaKeyAction` 的翻页部分）。
  ShortcutAction? mangaKey(
    FushiShortcutRegistry registry,
    KeyEvent event, {
    required bool rtl,
  }) {
    final ShortcutAction? bound = registry.resolveKeyboard(
      event.logicalKey,
      modifiers: const <ModifierKey>{},
      scope: ShortcutScope.manga,
    );
    return resolveMangaArrowPageTurn(
          key: event.logicalKey,
          modifiers: const <ModifierKey>{},
          rtl: rtl,
          boundAction: bound,
        ) ??
        bound;
  }

  ShortcutAction? novelPad(
    FushiShortcutRegistry registry,
    GamepadButton button, {
    required bool rtl,
  }) {
    final ShortcutAction? bound =
        registry.resolveGamepad(button, scope: ShortcutScope.reader) ??
        registry.resolveGamepad(button, scope: ShortcutScope.audiobook);
    return resolveReaderDpadPageTurn(
          button: button,
          rtl: rtl,
          boundAction: bound,
        ) ??
        bound;
  }

  ShortcutAction? mangaPad(
    FushiShortcutRegistry registry,
    GamepadButton button, {
    required bool rtl,
  }) {
    final ShortcutAction? bound = registry.resolveGamepad(
      button,
      scope: ShortcutScope.manga,
    );
    return resolveMangaDpadPageTurn(
          button: button,
          rtl: rtl,
          boundAction: bound,
        ) ??
        bound;
  }

  for (final TargetPlatform platform in platforms) {
    group('默认键位 $platform：小说与漫画左右翻页同向', () {
      late FushiShortcutRegistry registry;
      setUp(() => registry = FushiShortcutRegistry()..loadDefaults(platform));

      for (final bool rtl in <bool>[true, false]) {
        final String layout = rtl ? '从右往左（竖排 / rtl 跨页）' : '从左往右';
        test('$layout：键盘 ← →', () {
          for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
            LogicalKeyboardKey.arrowLeft,
            LogicalKeyboardKey.arrowRight,
          ]) {
            final KeyEvent event = keyDown(key);
            final String? novel = direction(
              novelKey(registry, event, rtl: rtl),
            );
            final String? manga = direction(
              mangaKey(registry, event, rtl: rtl),
            );
            final bool isLeft = key == LogicalKeyboardKey.arrowLeft;
            final String expected = (isLeft == rtl) ? 'forward' : 'backward';
            expect(novel, expected, reason: '小说 ${key.keyLabel}');
            expect(manga, expected, reason: '漫画 ${key.keyLabel}');
          }
        });

        test('$layout：手柄 D-pad 左右', () {
          for (final GamepadButton button in <GamepadButton>[
            GamepadButton.dpadLeft,
            GamepadButton.dpadRight,
          ]) {
            final String? novel = direction(
              novelPad(registry, button, rtl: rtl),
            );
            final String? manga = direction(
              mangaPad(registry, button, rtl: rtl),
            );
            final bool isLeft = button == GamepadButton.dpadLeft;
            final String expected = (isLeft == rtl) ? 'forward' : 'backward';
            expect(novel, expected, reason: '小说 ${button.label}');
            expect(manga, expected, reason: '漫画 ${button.label}');
          }
        });
      }
    });
  }

  group('改绑成相反方向：两种书都尊重用户绑定', () {
    test('ltr 书里把右键改绑成「上一页」→ 小说与漫画都翻上一页', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      for (final (ShortcutAction forward, ShortcutAction backward)
          in <(ShortcutAction, ShortcutAction)>[
            (
              ShortcutAction.readerPageForward,
              ShortcutAction.readerPageBackward,
            ),
            (ShortcutAction.mangaPageForward, ShortcutAction.mangaPageBackward),
          ]) {
        final ShortcutBindingSet fwd = registry.bindingsFor(forward);
        final ShortcutBindingSet back = registry.bindingsFor(backward);
        registry
          ..updateBinding(
            forward,
            fwd.copyWith(
              keyboardBindings: fwd.keyboardBindings
                  .where(
                    (InputBinding b) => b.key != LogicalKeyboardKey.arrowRight,
                  )
                  .toList(),
            ),
          )
          ..updateBinding(
            backward,
            back.copyWith(
              keyboardBindings: <InputBinding>[
                ...back.keyboardBindings,
                const InputBinding(key: LogicalKeyboardKey.arrowRight),
              ],
            ),
          );
      }
      final KeyEvent right = keyDown(LogicalKeyboardKey.arrowRight);
      expect(direction(novelKey(registry, right, rtl: false)), 'backward');
      expect(
        direction(mangaKey(registry, right, rtl: false)),
        'backward',
        reason: '此前漫画按跨页方向把用户的「上一页」改回「下一页」',
      );
    });
  });

  group('原语', () {
    test('rtl ^ reverse 决定左侧是否前进；只接管出厂绑定', () {
      ShortcutAction? turn(
        DirectionalPageTurnSide side, {
        required bool rtl,
        bool reverse = false,
        ShortcutAction? bound,
      }) => resolveDirectionalPageTurn(
        side: side,
        boundAction:
            bound ??
            (side == DirectionalPageTurnSide.left
                ? ShortcutAction.readerPageBackward
                : ShortcutAction.readerPageForward),
        forward: ShortcutAction.readerPageForward,
        backward: ShortcutAction.readerPageBackward,
        rtl: rtl,
        reverse: reverse,
      );

      expect(
        turn(DirectionalPageTurnSide.left, rtl: true),
        ShortcutAction.readerPageForward,
      );
      expect(
        turn(DirectionalPageTurnSide.left, rtl: true, reverse: true),
        ShortcutAction.readerPageBackward,
      );
      expect(
        turn(DirectionalPageTurnSide.right, rtl: false),
        ShortcutAction.readerPageForward,
      );
      expect(
        turn(
          DirectionalPageTurnSide.right,
          rtl: false,
          bound: ShortcutAction.readerPageBackward,
        ),
        isNull,
      );
      expect(
        resolveDirectionalPageTurn(
          side: null,
          boundAction: ShortcutAction.readerPageForward,
          forward: ShortcutAction.readerPageForward,
          backward: ShortcutAction.readerPageBackward,
          rtl: true,
        ),
        isNull,
      );
    });
  });

  test('源码守卫：小说手柄入口经过 D-pad 方向校正，两个阅读器不再各写方向判据', () {
    final String caret = File(
      'lib/src/pages/implementations/reader_fushi/caret.part.dart',
    ).readAsStringSync();
    final int padEntry = caret.indexOf('bool _handleGamepadButton(');
    expect(padEntry, isNonNegative);
    final int nextMember = caret.indexOf(
      'bool _handleGamepadLongPress(',
      padEntry,
    );
    expect(
      caret.substring(padEntry, nextMember),
      contains('resolveReaderDpadPageTurn('),
    );
    for (final String path in <String>[
      'lib/src/shortcuts/reader_space_override.dart',
      'lib/src/shortcuts/manga_arrow_override.dart',
    ]) {
      final String source = File(path).readAsStringSync();
      expect(
        source,
        isNot(contains('bool leftIsForward')),
        reason: '$path 不得再自写左右方向判据，统一走 resolveDirectionalPageTurn',
      );
    }
  });
}
