// 守卫：gamepads_windows 的 GameInput.dll 必须 delay-load + 运行时探测（BUG-563）。
//
// 根因：gamepad.cpp 的 `#pragma comment(lib, "GameInput.lib")` 把 GameInput.dll
// 链成静态导入，无 GameInput.dll 的 Windows（无 Gaming Services / 老系统）上加载器
// 在进程启动时直接失败——app 根本起不来。修法是链接层 /DELAYLOAD:GameInput.dll +
// delayimp，配合 Gamepads::init() 里先 LoadLibraryW 探测再调任何 GameInput API
// （delay-load 导入在 DLL 缺失时被调用会抛 SEH 异常，探测必须在前）。
//
// 本测试是最强可落地层的源码扫描守卫（C++ 链接行为无法在 Dart 单测里直接执行）：
// 守住这两个不变式，防止将来同步上游/重构时把 delay-load 或探测悄悄丢掉。
//
// 纯 dart:io，不依赖 Flutter 运行时；从 hibiki/ 向上找仓库根。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从当前 cwd 向上找含 packages/gamepads_windows 的仓库根。
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${dir.path}/packages/gamepads_windows').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 packages/gamepads_windows 的仓库根（从 ${Directory.current.path} 向上）');
}

void main() {
  final root = _repoRoot();
  final cmake = File(
    '${root.path}/packages/gamepads_windows/windows/CMakeLists.txt',
  );
  final gamepadCpp = File(
    '${root.path}/packages/gamepads_windows/windows/gamepad.cpp',
  );

  group('gamepads_windows GameInput delay-load 不变式（BUG-563）', () {
    test('CMakeLists.txt 必须以 /DELAYLOAD:GameInput.dll 链接并链 delayimp', () {
      final content = cmake.readAsStringSync();
      expect(
        content.contains('/DELAYLOAD:GameInput.dll'),
        isTrue,
        reason: '缺 /DELAYLOAD:GameInput.dll —— GameInput.dll 会退回静态导入，'
            '无 GameInput 的 Windows 机器 app 启动即崩（BUG-563）',
      );
      expect(
        RegExp(r'target_link_libraries\([^)]*\bdelayimp\b').hasMatch(content),
        isTrue,
        reason: '缺 delayimp —— /DELAYLOAD 需要 delay-load helper 库才能链接',
      );
    });

    test('gamepad.cpp 必须在任何 GameInput 调用前 LoadLibraryW 探测 GameInput.dll', () {
      final content = gamepadCpp.readAsStringSync();
      final probeAt = content.indexOf('LoadLibraryW(L"GameInput.dll")');
      final createAt = content.indexOf('GameInputCreate(');
      expect(
        probeAt,
        greaterThanOrEqualTo(0),
        reason: '缺 LoadLibraryW(L"GameInput.dll") 运行时探测 —— delay-load 的导入'
            '在 DLL 缺失时被调用会抛 SEH 异常，必须先探测再降级（BUG-563）',
      );
      expect(
        createAt,
        greaterThanOrEqualTo(0),
        reason: '找不到 GameInputCreate 调用——文件结构变了，请同步更新本守卫',
      );
      expect(
        probeAt < createAt,
        isTrue,
        reason: 'LoadLibraryW 探测必须出现在 GameInputCreate 之前，'
            '否则首次 GameInput 调用仍可能在无 DLL 机器上抛 SEH 异常',
      );
    });

    test('gamepad.cpp 仍保留 GameInput.lib 的 pragma（delay-load 需要 import lib）',
        () {
      final content = gamepadCpp.readAsStringSync();
      expect(
        content.contains('#pragma comment(lib, "GameInput.lib")'),
        isTrue,
        reason: '删掉 pragma 会直接链接失败；delay-load 是把该 import lib 的导入'
            '改挂到 delay-load 表，不是去掉链接',
      );
    });
  });
}
