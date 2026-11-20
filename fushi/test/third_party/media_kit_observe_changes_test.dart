import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
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

/// 等 [condition] 成立，最多 [seconds] 秒；到点仍不成立返回 false。
Future<bool> _waitFor(bool Function() condition, {int seconds = 5}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > Duration(seconds: seconds)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return true;
}

/// [trackListJson]（`track-list` 的文本形态）里当前选中的字幕轨 id；没有选中的返回 null。
int? _selectedSubtitleId(String trackListJson) {
  for (final Object? entry in jsonDecode(trackListJson) as List<Object?>) {
    final Map<String, Object?> track = entry! as Map<String, Object?>;
    if (track['type'] == 'sub' && track['selected'] == true) {
      return track['id'] as int?;
    }
  }
  return null;
}

void main() {
  final String? libmpv = _libmpvPath();

  // 原盘导航采样只在「轨道变脏」时重读已解析轨道（VideoDiscTrackRefreshGate），脏源是
  // 比值订阅。字幕切到「无」时 `current-tracks/sub/id` 变为不可用，比值订阅对「变为
  // 不可用」不回调；`track-list` 的文本形态带每条轨的 selected，属性恒可用，所以它必须
  // 在脏源里（kVideoDiscResolvedTrackProperties）。这里用真 libmpv 钉住这两点。
  test(
    'selection going to "none" reaches a track-list observer, not current-tracks',
    () async {
      MediaKit.ensureInitialized(libmpv: libmpv);
      final Directory dir = Directory.systemTemp.createTempSync(
        'fushi_observe_track_list_',
      );
      final Player player = Player();
      try {
        final File clip = await _makeClip(dir);
        final File srt = File('${dir.path}${Platform.pathSeparator}probe.srt')
          ..writeAsStringSync('1\n00:00:00,000 --> 00:00:05,000\nprobe\n');
        final dynamic native = player.platform;
        await native.setProperty('vo', 'null');
        await native.setProperty('ao', 'null');
        await native.setProperty('vid', 'auto');
        await native.setProperty('pause', 'no');
        final List<String> trackLists = <String>[];
        final List<String> subIds = <String>[];
        await native.observePropertyChanges('track-list', (String v) async {
          trackLists.add(v);
        });
        await native.observePropertyChanges('current-tracks/sub/id', (
          String v,
        ) async {
          subIds.add(v);
        });
        await native.command(<String>['loadfile', clip.absolute.path]);
        expect(
          await _waitFor(() => trackLists.isNotEmpty),
          isTrue,
          reason: '载入后 track-list 应有一次回调',
        );
        await native.command(<String>['sub-add', srt.absolute.path, 'select']);
        expect(
          await _waitFor(
            () =>
                subIds.isNotEmpty &&
                trackLists.isNotEmpty &&
                _selectedSubtitleId(trackLists.last) != null,
          ),
          isTrue,
          reason: '选中字幕：两种订阅都该回调 (track-list=$trackLists, sub/id=$subIds)',
        );
        final int trackListCalls = trackLists.length;
        final int subIdCalls = subIds.length;

        await native.setProperty('sid', 'no');
        expect(
          await _waitFor(() => trackLists.length > trackListCalls),
          isTrue,
          reason: '字幕切到「无」：track-list 的比值订阅必须回调',
        );
        expect(_selectedSubtitleId(trackLists.last), isNull);
        // 再留一段时间给迟到的事件：current-tracks/sub/id 此时不可用，不回调。
        await Future<void>.delayed(const Duration(milliseconds: 500));
        // ignore: avoid_print
        print(
          '[observe-track-list] track-list calls=${trackLists.length} '
          'sub/id values=$subIds',
        );
        expect(
          subIds,
          hasLength(subIdCalls),
          reason:
              '比值订阅对「变为不可用」不回调——若这条开始失败，说明补丁语义变了，'
              '脏源说明要跟着改',
        );
      } finally {
        await player.dispose();
        dir.deleteSync(recursive: true);
      }
    },
    skip: libmpv == null
        ? 'Build Windows Debug or set FUSHI_TEST_LIBMPV to libmpv-2.dll'
        : null,
    timeout: const Timeout(Duration(seconds: 60)),
  );

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
