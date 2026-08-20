import 'dart:convert';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 手柄全功能重设计 P1（漫画页接手柄）的映射与迁移测试，与
/// `video_gamepad_mapping_test.dart` 的 v4→v5 组同构。
void main() {
  group('manga 手柄默认映射', () {
    late FushiShortcutRegistry registry;

    setUp(() {
      registry = FushiShortcutRegistry();
      registry.loadDefaults(TargetPlatform.windows);
    });

    test('RB/dpad右 → 前进，LB/dpad左 → 后退（页序语义，方向校正在页面侧）', () {
      expect(
        registry.resolveGamepad(GamepadButton.rb, scope: ShortcutScope.manga),
        ShortcutAction.mangaPageForward,
      );
      expect(
        registry.resolveGamepad(GamepadButton.dpadRight,
            scope: ShortcutScope.manga),
        ShortcutAction.mangaPageForward,
      );
      expect(
        registry.resolveGamepad(GamepadButton.lb, scope: ShortcutScope.manga),
        ShortcutAction.mangaPageBackward,
      );
      expect(
        registry.resolveGamepad(GamepadButton.dpadLeft,
            scope: ShortcutScope.manga),
        ShortcutAction.mangaPageBackward,
      );
    });

    test('B 在 manga scope 无绑定，兜底 universal 解析成 globalBack', () {
      // 这正是「弹窗开着按手柄 B 直接退页」bug 的根因修复形态：manga scope 不占
      // B，页面解析兜底 universal 拿到 globalBack，再走与 Esc 相同的两级阶梯。
      expect(
        registry.resolveGamepad(GamepadButton.b, scope: ShortcutScope.manga),
        isNull,
      );
      expect(
        registry.resolveGamepad(GamepadButton.b,
            scope: ShortcutScope.universal),
        ShortcutAction.globalBack,
      );
    });
  });

  group('手柄动作的上下文门控（crossPageStep 语义）', () {
    test('globalBack 两级阶梯：弹窗可见先关弹窗，否则退出漫画', () {
      expect(
        MangaFushiPage.inputActionForShortcut(
          action: ShortcutAction.globalBack,
          crossPageStep: true,
          dictionaryShown: true,
          mode: MangaReadingMode.spread,
        ),
        MangaReaderInputAction.dismissDictionary,
      );
      expect(
        MangaFushiPage.inputActionForShortcut(
          action: ShortcutAction.globalBack,
          crossPageStep: true,
          dictionaryShown: false,
          mode: MangaReadingMode.spread,
        ),
        MangaReaderInputAction.backOrExit,
      );
    });

    test('手柄翻页是跨页步进：webtoon 也用锚点跳页、弹窗可见关弹窗并翻页', () {
      // 手柄没有原生滚动路径——键盘的「webtoon 让位原生滚动」「弹窗可见让位」两道
      // 门控都不适用（crossPageStep: true），否则 webtoon 模式下手柄完全翻不了页。
      for (final bool dictionaryShown in <bool>[true, false]) {
        for (final MangaReadingMode mode in MangaReadingMode.values) {
          expect(
            MangaFushiPage.inputActionForShortcut(
              action: ShortcutAction.mangaPageForward,
              crossPageStep: true,
              dictionaryShown: dictionaryShown,
              mode: mode,
            ),
            MangaReaderInputAction.next,
            reason: 'dict=$dictionaryShown mode=$mode 手柄前进必须可用',
          );
        }
      }
    });
  });

  group('schema migration v8 → v9（漫画翻页手柄默认补发）', () {
    /// v8 时代的快照：manga 动作已有键盘默认但手柄为空。
    Map<String, dynamic> v8Snapshot({
      Map<ShortcutAction, ShortcutBindingSet> overrides = const {},
    }) {
      final Map<ShortcutAction, ShortcutBindingSet> defaults =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final Map<String, dynamic> json = <String, dynamic>{
        kShortcutSchemaVersionKey: 8,
      };
      for (final MapEntry<ShortcutAction, ShortcutBindingSet> entry
          in defaults.entries) {
        final ShortcutAction action = entry.key;
        if (overrides.containsKey(action)) {
          json[action.key] = overrides[action]!.toJson();
          continue;
        }
        final List<GamepadBinding> gamepad = action.scope == ShortcutScope.manga
            ? const <GamepadBinding>[]
            : entry.value.gamepadBindings;
        json[action.key] = ShortcutBindingSet(
          keyboardBindings: entry.value.keyboardBindings,
          gamepadBindings: gamepad,
          mouseBindings: entry.value.mouseBindings,
          wheelBindings: entry.value.wheelBindings,
        ).toJson();
      }
      return json;
    }

    test('没动过键盘的老快照升级后补回手柄默认', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
      registry.loadFromJsonString(
        jsonEncode(v8Snapshot()),
        TargetPlatform.windows,
      );
      expect(
        registry.resolveGamepad(GamepadButton.rb, scope: ShortcutScope.manga),
        ShortcutAction.mangaPageForward,
      );
      expect(
        registry.resolveGamepad(GamepadButton.lb, scope: ShortcutScope.manga),
        ShortcutAction.mangaPageBackward,
      );
    });

    test('用户改过键盘的动作绝不强行恢复（不覆写用户编辑）', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
      registry.loadFromJsonString(
        jsonEncode(
          v8Snapshot(
            overrides: <ShortcutAction, ShortcutBindingSet>{
              ShortcutAction.mangaPageForward: const ShortcutBindingSet(
                keyboardBindings: <InputBinding>[
                  InputBinding(key: LogicalKeyboardKey.keyN),
                ],
              ),
            },
          ),
        ),
        TargetPlatform.windows,
      );
      expect(
        registry.resolveGamepad(GamepadButton.rb, scope: ShortcutScope.manga),
        isNull,
        reason: '改过键盘的 mangaPageForward 不得被迁移覆写',
      );
      // 没动过的兄弟动作照常补发。
      expect(
        registry.resolveGamepad(GamepadButton.lb, scope: ShortcutScope.manga),
        ShortcutAction.mangaPageBackward,
      );
    });
  });
}
