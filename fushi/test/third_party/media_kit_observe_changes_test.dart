import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:media_kit/media_kit.dart';

/// BUG-3315：media_kit 补丁 `NativePlayer.observePropertyChanges` 的真 libmpv 行为。
///
/// `observeProperty` 以 `MPV_FORMAT_NONE` 订阅，mpv 对无格式订阅恒报「已变化」；挂在
/// `MPV_EVENT_TICK` 上的属性于是每帧来一次事件，media_kit 每次还先同步
/// `mpv_get_property_string` 一次。`observePropertyChanges` 改用 `MPV_FORMAT_STRING`，
/// 由 mpv 在核心里比值，值不变就没有事件。
///
/// 用 `frame-drop-count`（TICK 通知、`vo=null` 下恒为 0）做对照：旧订阅回调次数随帧数
/// 增长，新订阅只在初值时来一次。
///
/// 需要真实 libmpv：`FUSHI_TEST_LIBMPV` 指向 libmpv-2.dll，或先构建 Windows Debug。
String? _libmpvPath() {
  final String? override = Platform.environment['FUSHI_TEST_LIBMPV'];
  final String path = override ?? 'build/windows/x64/runner/Debug/libmpv-2.dll';
  return File(path).existsSync() ? File(path).absolute.path : null;
}

/// 60 fps 的本地测试片。
Future<File> _makeClip(Directory dir) async {
  final String out = '${dir.path}${Platform.pathSeparator}tick_probe.mp4';
  final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc=size=320x240:rate=60',
    '-t',
    '6',
    '-c:v',
    'mpeg4',
    out,
  ], const Duration(seconds: 60));
  if (!r.isSuccess) throw StateError('ffmpeg failed: ${r.failureSummary}');
  return File(out);
}

Future<int> _countCallbacks(File clip, {required bool changesOnly}) async {
  final Player player = Player();
  try {
    final dynamic native = player.platform;
    await native.setProperty('vo', 'null');
    await native.setProperty('ao', 'null');
    // 没挂 VideoController 时 media_kit 把 vid 设成 no，这里要真的解视频帧才有 TICK。
    await native.setProperty('vid', 'auto');
    await native.setProperty('pause', 'no');
    int calls = 0;
    Future<void> listener(String _) async => calls++;
    if (changesOnly) {
      await native.observePropertyChanges('frame-drop-count', listener);
    } else {
      await native.observeProperty('frame-drop-count', listener);
    }
    // 直接 loadfile：本测试只关心订阅语义，不经 media_kit open 的临时播放列表。
    await native.command(<String>['loadfile', clip.absolute.path]);
    // 60 fps 测试片播 ~2 s：约 120 个 TICK。
    final Stopwatch sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 2000) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      double.tryParse('${await native.getProperty('time-pos')}') ?? 0,
      greaterThan(1.0),
      reason: '测试片必须真的在播，否则两组都是 0 次回调、对照无意义',
    );
    return calls;
  } finally {
    await player.dispose();
  }
}

void main() {
  final String? libmpv = _libmpvPath();

  test(
    'observePropertyChanges only fires when the value changes',
    () async {
      MediaKit.ensureInitialized(libmpv: libmpv);
      final Directory dir = Directory.systemTemp.createTempSync(
        'fushi_observe_changes_',
      );
      try {
        final File clip = await _makeClip(dir);
        final int flood = await _countCallbacks(clip, changesOnly: false);
        final int changes = await _countCallbacks(clip, changesOnly: true);
        // ignore: avoid_print
        print('[observe-changes] FORMAT_NONE=$flood FORMAT_STRING=$changes');
        expect(flood, greaterThan(30), reason: '对照组：无格式订阅在 TICK 属性上应每帧回调');
        expect(changes, lessThanOrEqualTo(2), reason: '值恒为 0 的属性在比值订阅下不该每帧回调');
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
    skip: libmpv == null
        ? 'Build Windows Debug or set FUSHI_TEST_LIBMPV to libmpv-2.dll'
        : null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
