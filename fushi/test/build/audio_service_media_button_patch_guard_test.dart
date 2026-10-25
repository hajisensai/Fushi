import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-3777 B：audio_service Android 原生层把真实的 `KEYCODE_MEDIA_PLAY` /
/// `KEYCODE_MEDIA_PAUSE` 当成「单击」（切换）交给 Dart，蓝牙 / 车机补发的 PLAY 在
/// 播放中到达就把声音暂停。补丁在 `ci/patches/hosted/audio_service-<版本>/`，整份
/// `AudioService.java` 覆盖进 pub cache。
///
/// Java 不在任何 Dart 测试的编译面上，所以钉两件事：
/// 1. 补丁目录版本 == 根 `pubspec.lock` 解析到的版本——不等时 `ci/apply-patches.sh`
///    只打一行 WARNING 就静默跳过，修复悄悄消失（`audio_session-0.1.14` 就是这样
///    躺着的死补丁）。
/// 2. `onMediaButtonEvent` 里 PLAY → `onPlay()`、PAUSE → `onPause()`；PLAY_PAUSE /
///    HEADSETHOOK 仍走 `listener.onClick`；通知栏用的 BYPASS 键码处理不变。
void main() {
  /// 测试 cwd 恒为 `fushi/`，仓库根是它的父目录。
  final Directory repoRoot = Directory.current.parent;

  String lockedVersion(String package) {
    final String lock = File(
      '${repoRoot.path}/pubspec.lock',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final RegExpMatch? m = RegExp(
      '\n  $package:\n(?:    .*\n|      .*\n)*?    version: "([^"]+)"',
    ).firstMatch(lock);
    if (m == null) throw StateError('pubspec.lock 里找不到 $package');
    return m.group(1)!;
  }

  // late：在用例里才读 lock（声明期抛错会让整个 suite 装载失败、看不出原因）。
  late final String version = lockedVersion('audio_service');
  late final String patchRoot =
      '${repoRoot.path}/ci/patches/hosted/audio_service-$version';
  late final File java = File(
    '$patchRoot/android/src/main/java/com/ryanheise/audioservice/AudioService.java',
  );

  test('补丁目录版本与 pubspec.lock 一致（否则 apply-patches 静默跳过）', () {
    expect(
      java.existsSync(),
      isTrue,
      reason:
          'audio_service 升到 $version 后必须把补丁移植到 '
          'ci/patches/hosted/audio_service-$version/',
    );
    final List<String> stale = Directory('${repoRoot.path}/ci/patches/hosted')
        .listSync()
        .whereType<Directory>()
        .map(
          (Directory d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last,
        )
        .where(
          (String name) =>
              name.startsWith('audio_service-') &&
              name != 'audio_service-$version',
        )
        .toList();
    expect(stale, isEmpty, reason: '旧版本补丁目录不会再被应用，移植后删掉');
  });

  test(
    'PLAY / PAUSE 键码走有方向的 onPlay / onPause，只有 PLAY_PAUSE / HEADSETHOOK 是切换',
    () {
      // 注释先抹成空白（Java 与 Dart 同为 C 风格注释）：注释里出现的语句不能冒充分支实现。
      final String src = maskComments(
        java.readAsStringSync().replaceAll('\r\n', '\n'),
      );
      final int start = src.indexOf(
        'public boolean onMediaButtonEvent(Intent mediaButtonEvent)',
      );
      expect(start, isNonNegative);
      final int end = src.indexOf('private MediaButton eventToButton', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);

      /// 某个 `case X:` 之后到下一个 `break;` 之间的语句（连续 case 落空到同一组）。
      String arm(String caseLabel) {
        final int at = body.indexOf('case $caseLabel:');
        expect(at, isNonNegative, reason: '缺 case $caseLabel');
        final int brk = body.indexOf('break;', at);
        return body
            .substring(at, brk)
            .split('\n')
            .map((String l) => l.trim())
            .where((String l) => l.isNotEmpty)
            .where((String l) => !l.startsWith('case '))
            .join(' ');
      }

      expect(arm('KeyEvent.KEYCODE_MEDIA_PLAY'), 'onPlay();');
      expect(arm('KeyEvent.KEYCODE_MEDIA_PAUSE'), 'onPause();');
      expect(arm('KEYCODE_BYPASS_PLAY'), 'onPlay();');
      expect(arm('KEYCODE_BYPASS_PAUSE'), 'onPause();');
      for (final String toggle in <String>[
        'KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE',
        'KeyEvent.KEYCODE_HEADSETHOOK',
        'KeyEvent.KEYCODE_MEDIA_NEXT',
        'KeyEvent.KEYCODE_MEDIA_PREVIOUS',
      ]) {
        expect(
          arm(toggle),
          'listener.onClick(eventToButton(event));',
          reason: '$toggle 仍是单击',
        );
      }
    },
  );
}
