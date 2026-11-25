import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

import '../../helpers/source_guard.dart';

/// 反馈 FhspOXxPl_：漫画阅读器「添加当前页为书签」快捷键。
///
/// MangaFushiPage 过重，无法在纯 widget test 拉起完整链路（同
/// `manga_study_clock_inputs_test` 纪律）：默认键表 / 注册表解析 / 解析层纯函数 /
/// 命令键桥 token 与生成的 JS 按行为测，页面接线按源码守卫钉。
void main() {
  final String src = maskComments(
    File(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n'),
  );

  group('默认绑定：键盘 B，手柄留空', () {
    test('manga scope，五平台键盘默认 B、无手柄默认', () {
      expect(ShortcutAction.mangaToggleBookmark.scope, ShortcutScope.manga);
      for (final TargetPlatform platform in const <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
          platform,
        )[ShortcutAction.mangaToggleBookmark]!;
        expect(
          set.keyboardBindings,
          contains(const InputBinding(key: LogicalKeyboardKey.keyB)),
          reason: '$platform',
        );
        expect(set.gamepadBindings, isEmpty, reason: '$platform');
      }
    });

    test('manga co-active 组内没有别的动作默认占 B，注册表解析到本动作', () {
      final Map<ShortcutAction, ShortcutBindingSet> defaults =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final String token = const InputBinding(
        key: LogicalKeyboardKey.keyB,
      ).serialize();
      for (final ShortcutScope scope in ShortcutScope.manga.coactiveScopes) {
        for (final ShortcutAction action in ShortcutAction.actionsForScope(
          scope,
        )) {
          if (action == ShortcutAction.mangaToggleBookmark) continue;
          expect(
            defaults[action]!.keyboardBindings.map(
              (InputBinding b) => b.serialize(),
            ),
            isNot(contains(token)),
            reason: '${action.key} 也默认绑 B，会遮蔽 manga_toggle_bookmark',
          );
        }
      }
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.keyB,
          modifiers: const <ModifierKey>{},
          scope: ShortcutScope.manga,
        ),
        ShortcutAction.mangaToggleBookmark,
      );
    });
  });

  test('解析层：不吃两道翻页门控（查词弹窗开着 / webtoon 下照样能加书签）', () {
    for (final bool dictionaryShown in <bool>[false, true]) {
      for (final MangaReadingMode mode in MangaReadingMode.values) {
        for (final bool crossPageStep in <bool>[false, true]) {
          expect(
            MangaFushiPage.inputActionForShortcut(
              action: ShortcutAction.mangaToggleBookmark,
              crossPageStep: crossPageStep,
              dictionaryShown: dictionaryShown,
              mode: mode,
            ),
            MangaReaderInputAction.toggleBookmark,
            reason: 'dict=$dictionaryShown mode=$mode cross=$crossPageStep',
          );
        }
      }
    }
  });

  group('命令键桥：WebView 持焦时也收得到，键表按当前绑定生成', () {
    test('默认绑定下含 B / M / I / P 的 bridge token', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      final List<String> tokens = MangaFushiPage.commandKeyBridgeTokens(
        registry,
      );
      expect(tokens, containsAll(<String>['KeyB', 'KeyM', 'KeyI', 'KeyP']));
    });

    test('改键后 token 表跟着变（设置里改的键 WebView 持焦时也生效）', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows)
        ..updateBinding(
          ShortcutAction.mangaToggleBookmark,
          const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              InputBinding(
                key: LogicalKeyboardKey.keyK,
                modifiers: <ModifierKey>{ModifierKey.ctrl},
              ),
            ],
          ),
        );
      final List<String> tokens = MangaFushiPage.commandKeyBridgeTokens(
        registry,
      );
      expect(tokens, contains('Ctrl+KeyK'));
      expect(tokens, isNot(contains('KeyB')));
      // 桥回传的 token 能被同一套反解析吃回去，并解析到本动作。
      final InputBinding? back = InputBinding.fromBridgeToken('Ctrl+KeyK');
      expect(back, isNotNull);
      expect(
        registry.resolveKeyboard(
          back!.key,
          modifiers: back.modifiers,
          scope: ShortcutScope.manga,
        ),
        ShortcutAction.mangaToggleBookmark,
      );
    });

    test('与翻页桥 / 平移桥重叠的 token 剔除（否则一次按键执行两遍）', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows)
        ..updateBinding(
          ShortcutAction.mangaToggleBookmark,
          const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              InputBinding(key: LogicalKeyboardKey.arrowLeft),
              InputBinding(
                key: LogicalKeyboardKey.arrowUp,
                modifiers: <ModifierKey>{ModifierKey.ctrl},
              ),
            ],
          ),
        );
      final List<String> tokens = MangaFushiPage.commandKeyBridgeTokens(
        registry,
      );
      expect(tokens, isNot(contains('ArrowLeft')));
      expect(tokens, isNot(contains('Ctrl+ArrowUp')));
      expect(MangaFushiPage.navigationKeyBridgeScript, contains("'ArrowLeft'"));
      expect(MangaFushiPage.panKeyBridgeScript, contains("'Ctrl+ArrowUp'"));
    });

    test('生成的脚本：独立 handler、带 token、按住不连发、独占', () {
      final String script = MangaFushiPage.commandKeyBridgeScript(<String>[
        'KeyB',
      ]);
      expect(script, contains('__fushiKeyBridgeInstalled_onMangaCommandKey'));
      expect(script, contains("callHandler('onMangaCommandKey'"));
      expect(script, contains("'KeyB'"));
      expect(script, contains('if (e.repeat) return;'));
      expect(script, contains('e.stopImmediatePropagation();'));
    });
  });

  group('页面接线（源码守卫）', () {
    test('执行体与书签面板「当前页」一行同一入口', () {
      final String exec = methodBody(src, '  void _executeReaderInputAction(');
      final RegExpMatch? block = RegExp(
        r'if \(action == MangaReaderInputAction\.toggleBookmark\) \{[\s\S]*?return;',
      ).firstMatch(exec);
      expect(block, isNotNull);
      expect(
        block!.group(0),
        contains('_toggleBookmarkHere(_bookmarkOnScreen())'),
      );
    });

    test('命令键桥注册了 handler、换窗时按注册表注入，回调汇进同一解析入口', () {
      expect(
        RegExp(
          r"handlerName: 'onMangaCommandKey',\s*callback: \(List<dynamic> args\) \{"
          r'[\s\S]*?_handleNativeNavigationKey\(args\[0\] as String\);',
        ).hasMatch(src),
        isTrue,
      );
      expect(
        RegExp(
          r'MangaFushiPage\.commandKeyBridgeScript\(\s*'
          r'MangaFushiPage\.commandKeyBridgeTokens\(appModel\.shortcutRegistry\),',
        ).hasMatch(src),
        isTrue,
      );
    });

    test('桥 token 用 fromBridgeToken 反解析（认小键盘 DOM code）', () {
      final String handler = methodBody(
        src,
        '  bool _handleNativeNavigationKey(',
      );
      expect(handler, contains('InputBinding.fromBridgeToken(key)'));
    });
  });
}
