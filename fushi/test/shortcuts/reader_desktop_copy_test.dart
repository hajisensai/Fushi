import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/reader_space_override.dart';

/// 桌面复制手势谓词真值表（BUG-402 Windows Ctrl+C / macOS ⌘C）。
///
/// [platform] 只取三种：`win` / `mac` / `other`（Linux 与移动端都不接管）。
bool _hit(
  LogicalKeyboardKey key,
  Set<ModifierKey> modifiers, {
  required String platform,
}) => desktopShouldHandleCopyGesture(
  key: key,
  modifiers: modifiers,
  isWindows: platform == 'win',
  isMacOS: platform == 'mac',
);

void main() {
  group('desktopShouldHandleCopyGesture · Windows (BUG-402)', () {
    test('Windows + 纯 Ctrl+C → 接管复制', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.ctrl,
        }, platform: 'win'),
        isTrue,
      );
    });

    test('Windows 但只按 C（无 Ctrl）→ 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{}, platform: 'win'),
        isFalse,
      );
    });

    test('Windows + Ctrl+Shift+C（多修饰）→ 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.ctrl,
          ModifierKey.shift,
        }, platform: 'win'),
        isFalse,
      );
    });

    test('Windows + Ctrl+其它键（非 C）→ 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyV, <ModifierKey>{
          ModifierKey.ctrl,
        }, platform: 'win'),
        isFalse,
      );
    });

    test('Windows + Meta+C（mac 风格，非 Ctrl）→ 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.meta,
        }, platform: 'win'),
        isFalse,
      );
    });
  });

  group('desktopShouldHandleCopyGesture · macOS ⌘C', () {
    test('macOS + 纯 Meta+C（⌘C）→ 接管复制', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.meta,
        }, platform: 'mac'),
        isTrue,
      );
    });

    test('macOS + Ctrl+C（不是 Mac 的复制键）→ 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.ctrl,
        }, platform: 'mac'),
        isFalse,
      );
    });

    test('macOS + Meta+Shift+C / Meta+Alt+C（多修饰）→ 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.meta,
          ModifierKey.shift,
        }, platform: 'mac'),
        isFalse,
      );
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.meta,
          ModifierKey.alt,
        }, platform: 'mac'),
        isFalse,
      );
    });

    test('macOS + 裸 C / Meta+其它键 → 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{}, platform: 'mac'),
        isFalse,
      );
      expect(
        _hit(LogicalKeyboardKey.keyV, <ModifierKey>{
          ModifierKey.meta,
        }, platform: 'mac'),
        isFalse,
      );
    });
  });

  group('desktopShouldHandleCopyGesture · 其它平台', () {
    test('Linux / 移动端：Ctrl+C 与 Meta+C 一律不接管', () {
      for (final ModifierKey mod in <ModifierKey>[
        ModifierKey.ctrl,
        ModifierKey.meta,
      ]) {
        expect(
          _hit(LogicalKeyboardKey.keyC, <ModifierKey>{mod}, platform: 'other'),
          isFalse,
          reason: '$mod+C 在非 Windows / macOS 平台不得接管',
        );
      }
    });
  });

  // BUG-4165 审查补修：复制键落在阅读器上时，按可见层叠顺序（弹窗各层 → 阅读面）
  // 找第一个有原生选区的面。每个面用一个「有选区就复制并返回 true」的假面模拟，
  // reads 记录被读过的面，用来证明下层（尤其残留旧选区的正文）不会被抢先读。
  group('copyFromTopmostSurfaceWithSelection（BUG-4165）', () {
    Future<bool> Function() surface(
      String name,
      List<String> reads, {
      required bool hasSelection,
    }) => () async {
      reads.add(name);
      return hasSelection;
    };

    test('顶层弹窗有选区：复制它，正文残留的旧选区一次都不读', () async {
      final List<String> reads = <String>[];
      final bool copied =
          await copyFromTopmostSurfaceWithSelection(<Future<bool> Function()>[
            surface('popup', reads, hasSelection: true),
            surface('body', reads, hasSelection: true),
          ]);
      expect(copied, isTrue);
      expect(reads, <String>['popup']);
    });

    test('上层都没选区：自顶向下落到第一个有选区的面', () async {
      final List<String> reads = <String>[];
      final bool copied =
          await copyFromTopmostSurfaceWithSelection(<Future<bool> Function()>[
            surface('popup2', reads, hasSelection: false),
            surface('popup1', reads, hasSelection: true),
            surface('lyrics', reads, hasSelection: true),
          ]);
      expect(copied, isTrue);
      expect(reads, <String>['popup2', 'popup1']);
    });

    test('全部为空：逐个问完、返回 false（调用方不写剪贴板）', () async {
      final List<String> reads = <String>[];
      final bool copied =
          await copyFromTopmostSurfaceWithSelection(<Future<bool> Function()>[
            surface('popup', reads, hasSelection: false),
            surface('lyrics', reads, hasSelection: false),
          ]);
      expect(copied, isFalse);
      expect(reads, <String>['popup', 'lyrics']);
    });

    test('没有任何候选面：返回 false', () async {
      expect(
        await copyFromTopmostSurfaceWithSelection(
          const <Future<bool> Function()>[],
        ),
        isFalse,
      );
    });
  });
}
