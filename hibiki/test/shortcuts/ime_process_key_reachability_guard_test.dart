import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// BUG-1427：把「`LogicalKeyboardKey.process` 在 Hibiki 出包的 5 个平台上产不出来」
/// 这条**平台事实**钉成可执行断言。
///
/// 为什么需要它：仓库里 BUG-430 / BUG-853 / BUG-936 建立了一整套「IME 激活时引擎把
/// `logicalKey` 改写成 [LogicalKeyboardKey.process]，故按 `physicalKey` 回退」的兼容层
/// （`shortcut_registry.dart` 的 resolveKeyboard 回退分支、`reader_space_override.dart`
/// 的两个 override、`caret.part.dart` / `home_page.dart` / `global_navigation.dart` 的
/// 四处 `physicalKey:` 透传）。该前提**只对 Flutter Web 成立**：`process` 是 DOM
/// `KeyboardEvent.key === 'Process'` 的产物，只在 [kWebToLogicalKey] 里有条目。
///
/// Windows 桌面端的真实机制完全不同——IME 消费掉的按键由 Win32 以
/// `WM_KEYDOWN wParam=VK_PROCESSKEY(0xE5)` 投递，Flutter 的 Windows 嵌入层
/// (`shell/platform/windows/keyboard_key_embedder_handler.cc`) 在
/// `sequence_logical_key == VK_PROCESSKEY` 时 `callback(true); return;`，**一个
/// FlutterKeyEvent 都不发**；对应的 keyup 因为 `pressingRecords_` 里没有记录，也走
/// 「The physical key has been released before ... Ignore the up event」被丢弃。
/// 即：IME 吃掉的键在 Flutter 侧**根本不存在**，既没有 down 也没有 up，更没有
/// `process`。这与 BUG-936 记录的「BUG-853 修复后真机仍失效」完全吻合。
///
/// 所以那套 `key == process` 回退是**永不触发的死代码**，任何「再补一处 process
/// 回退」的改动都不会修好任何东西。本守卫的作用是：若哪天 Flutter 真把 `process`
/// 引进某个原生平台的键表（那才是兼容层生效的前提），这里立刻转红，提醒重新评估；
/// 在那之前，它就是「别再往这个方向打补丁」的可执行注脚。
///
/// 注意本守卫**不禁止**代码里出现 `process` 比较（存量兼容层照旧、无害），它只钉
/// 「这些分支目前不可达」这条事实本身。
void main() {
  test('LogicalKeyboardKey.process 只在 Web 键表里有条目', () {
    expect(
      kWebToLogicalKey.values,
      contains(LogicalKeyboardKey.process),
      reason: 'process 是 DOM KeyboardEvent.key === "Process" 的产物；这条若不再成立，'
          '说明 Flutter 改了 IME 键的表达方式，整套回退层的前提要重新评估',
    );
  });

  test('Hibiki 出包的 5 个平台的逻辑键表都产不出 process', () {
    // Android / iOS / macOS / Windows / Linux(GTK+GLFW) 的全部 logical 映射，
    // 外加 Fuchsia（同属非 web 原生端，一并钉住）。缺哪张表会让守卫留下盲区，故
    // 逐张列全，而不是只挑 kWindowsToLogicalKey。
    final Map<String, Map<Object, LogicalKeyboardKey>> nativeMaps =
        <String, Map<Object, LogicalKeyboardKey>>{
      'kAndroidToLogicalKey': kAndroidToLogicalKey,
      'kAndroidNumPadMap': kAndroidNumPadMap,
      'kFuchsiaToLogicalKey': kFuchsiaToLogicalKey,
      'kMacOsToLogicalKey': kMacOsToLogicalKey,
      'kMacOsNumPadMap': kMacOsNumPadMap,
      'kMacOsFunctionKeyMap': kMacOsFunctionKeyMap,
      'kIosToLogicalKey': kIosToLogicalKey,
      'kIosNumPadMap': kIosNumPadMap,
      'kIosSpecialLogicalMap': kIosSpecialLogicalMap,
      'kGlfwToLogicalKey': kGlfwToLogicalKey,
      'kGlfwNumpadMap': kGlfwNumpadMap,
      'kGtkToLogicalKey': kGtkToLogicalKey,
      'kGtkNumpadMap': kGtkNumpadMap,
      'kWindowsToLogicalKey': kWindowsToLogicalKey,
      'kWindowsNumPadMap': kWindowsNumPadMap,
    };

    for (final MapEntry<String, Map<Object, LogicalKeyboardKey>> entry
        in nativeMaps.entries) {
      expect(
        entry.value.values,
        isNot(contains(LogicalKeyboardKey.process)),
        reason: '${entry.key} 出现了 process：原生端 IME 键的表达方式变了，'
            'BUG-430/853/936 的 physicalKey 回退层可能终于可达，需重新评估',
      );
    }
  });

  test('Windows 嵌入层返回的裸 VK_PROCESSKEY(0xE5) 也不等于 process', () {
    // keyboard_key_embedder_handler.cc 的 GetLogicalKey 对 VK_PROCESSKEY 返回
    // **裸 0xE5**（不加平面位），而 process 的 keyId 是 0x0010000070f。即便哪天
    // 那个早退分支被去掉、0xE5 真漏到 Dart 侧，它也不会命中任何 `== process` 判据
    // ——回退层仍然不生效。这条钉住「换个漏法也救不了」。
    expect(LogicalKeyboardKey.process.keyId, 0x0010000070f);
    expect(const LogicalKeyboardKey(0xE5), isNot(LogicalKeyboardKey.process));
  });
}
