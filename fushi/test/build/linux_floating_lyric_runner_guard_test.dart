// 源码守卫：Linux 悬浮字幕 / 桌面歌词原生后端（linux/runner/floating_lyric_*）与
// 共用通道契约（lib/src/media/audiobook/floating_lyric_channel.dart）不漂开。
//
// C++ 在 Dart 测试里跑不起来，真机行为由 integration_test/
// linux_floating_lyric_itest.dart（Xvfb）取证；这里锁住结构性前提：
//   ① 平台判据已放开 Linux（floatingLyricBackendAvailableOn 与字体用途同拍），
//      而 runner 确实注册了这条通道——放开判据却没注册 = 入口全亮、点了 Missing
//      PluginException 静默失败；
//   ② Dart 发出的每个方法 Linux 都处理，Linux 回传的每个事件 Dart 都认；
//   ③ 工具条槽表与 Windows kAudiobookSlotActions 同序（Dart 提示表靠下标对齐）；
//   ④ 测试钩子通道只在 FUSHI_TEST_FLOATING_LYRIC 下注册（生产零暴露）；
//   ⑤ Wayland 降级是显式的：layer-shell 运行时 dlopen（不成为构建 / 运行硬依赖），
//      没有 layer-shell 时拒绝穿透并回报 Dart。
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final String dart = File(
    'lib/src/media/audiobook/floating_lyric_channel.dart',
  ).readAsStringSync();
  final String overlayBase = File(
    'lib/src/platform/floating_overlay_channel.dart',
  ).readAsStringSync();
  final String channelCc = File(
    'linux/runner/floating_lyric_channel.cc',
  ).readAsStringSync();
  final String windowCc = File(
    'linux/runner/floating_lyric_window.cc',
  ).readAsStringSync();
  final String app = File('linux/runner/my_application.cc').readAsStringSync();
  final String cmake = File('linux/runner/CMakeLists.txt').readAsStringSync();
  final String winToolbar = File(
    'windows/runner/hook_toolbar_window.h',
  ).readAsStringSync();

  test('① 判据放开 Linux，且 runner 注册了通道', () {
    expect(
      RegExp(
        r'floatingLyricBackendAvailableOn\(String operatingSystem\) =>[\s\S]*?'
        r"operatingSystem == 'linux';",
      ).hasMatch(dart),
      isTrue,
      reason: 'Linux 有原生后端，判据必须认它',
    );
    // 只匹配 `isLinux`，不写完整的 Platform 判据字面量：dist_test 按源码里的
    // 平台判据把整个套件钉到对应平台跑。
    expect(
      RegExp(r'FontTarget\.floatingLyric =>[^,]*\bisLinux\b').hasMatch(
        File('lib/src/reader/reader_settings.dart').readAsStringSync(),
      ),
      isTrue,
      reason: '悬浮字幕字体用途必须随后端同拍在 Linux 显示',
    );
    expect(channelCc, contains('"app.fushi.reader/floating_lyric"'));
    expect(app, contains('fushi_floating_lyric_new(messenger, window)'));
    expect(app, contains('fushi_floating_lyric_free'));
    expect(cmake, contains('"floating_lyric_channel.cc"'));
    expect(cmake, contains('"floating_lyric_window.cc"'));
  });

  test('② Dart → native 方法 Linux 全接，native → Dart 事件 Dart 全认', () {
    final Set<String> outgoing = <String>{
      ...RegExp(
        r"invokeMethod<\w+>\(\s*'(\w+)'",
      ).allMatches(dart).map((RegExpMatch m) => m.group(1)!),
      // FloatingOverlayChannel 的四个公共操作。
      ...RegExp(
        r"_safeInvoke<\w+>\('(\w+)'",
      ).allMatches(overlayBase).map((RegExpMatch m) => m.group(1)!),
    };
    expect(outgoing, containsAll(<String>['show', 'updateText', 'setLocked']));
    for (final String method in outgoing) {
      expect(
        channelCc,
        contains('method == "$method"'),
        reason: 'Linux runner 没处理 $method：Dart 调过去落成 notImplemented',
      );
    }

    final Set<String> handled = RegExp(
      r"case '(\w+)':",
    ).allMatches(dart).map((RegExpMatch m) => m.group(1)!).toSet();
    final Set<String> emitted = <String>{
      ...RegExp(
        r'Invoke\(self, "(\w+)"',
      ).allMatches(channelCc).map((RegExpMatch m) => m.group(1)!),
    };
    expect(
      emitted,
      containsAll(<String>[
        'lookupText',
        'lockChanged',
        'passThroughChanged',
        'windowRectChanged',
      ]),
    );
    for (final String event in emitted) {
      expect(handled, contains(event), reason: 'Dart 不认 Linux 回传的 $event');
    }
    // 点词回传的字矩形四个字段名与 Dart _wordRect 读的一致。
    for (final String key in <String>[
      'wordLeft',
      'wordTop',
      'wordWidth',
      'wordHeight',
    ]) {
      expect(channelCc, contains('"$key"'));
      expect(dart, contains("args['$key']"));
    }
  });

  test('③ 工具条槽表与 Windows kAudiobookSlotActions 同序', () {
    final Match? win = RegExp(
      r'kAudiobookSlotActions\[kAudiobookSlotCount\] = \{([\s\S]*?)\};',
    ).firstMatch(winToolbar);
    expect(win, isNotNull);
    final List<String> windowsSlots = RegExp(
      r'"(\w+)"',
    ).allMatches(win!.group(1)!).map((RegExpMatch m) => m.group(1)!).toList();
    final Match? linux = RegExp(
      r'static const std::vector<std::string> actions = \{([\s\S]*?)\};',
    ).firstMatch(windowCc);
    expect(linux, isNotNull, reason: 'Linux SlotActions 表必须存在');
    final List<String> linuxSlots = RegExp(
      r'"(\w+)"',
    ).allMatches(linux!.group(1)!).map((RegExpMatch m) => m.group(1)!).toList();
    expect(
      linuxSlots,
      windowsSlots,
      reason: 'Dart 提示表按下标对齐 native 槽表：Linux 与 Windows 必须同序同长',
    );
  });

  test('④ 测试钩子通道只在 FUSHI_TEST_FLOATING_LYRIC 下注册', () {
    expect(channelCc, contains('"FUSHI_TEST_FLOATING_LYRIC"'));
    expect(
      RegExp(
        r'if \(g_getenv\(kTestEnv\) != nullptr\) \{\s*self->test_channel =',
      ).hasMatch(channelCc),
      isTrue,
    );
  });

  test('⑤ Wayland 降级显式：layer-shell 运行时加载，无 layer-shell 拒绝穿透', () {
    expect(windowCc, contains('dlopen("libgtk-layer-shell.so.0"'));
    expect(
      RegExp(r'pkg_check_modules\([^)]*gtk-layer-shell').hasMatch(cmake),
      isFalse,
      reason: 'layer-shell 只能运行时可选，不能成为构建依赖',
    );
    expect(
      RegExp(
        r'enabled && backend_ == Backend::kWaylandToplevel\)[\s\S]{0,400}'
        r'on_pass_through_\(false\)',
      ).hasMatch(windowCc),
      isTrue,
      reason: '没有 layer-shell 的 Wayland 窗放不回原位也置不了顶，必须拒绝穿透并回报',
    );
  });
}
