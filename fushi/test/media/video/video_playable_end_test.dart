// BUG-4327：mkv 容器时长被字幕轨拉长（MyGO S01E03：容器 24:02，音视频 23:40），
// 进度条显示还有余量、往 23:39 之后拖会直接 EOF 弹回最后一帧。修正把总时长改成音视频
// 轨 `DURATION` 统计标签的最大值；这里钉住判据（纯函数）、对 media_kit 时长状态的写入
// 与撤销，以及 VideoPlayerController 里的接线。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_playable_end.dart';
import 'package:media_kit/media_kit.dart';

/// 只用 [PlatformPlayer] 自带的 state / 流，不碰 libmpv。
class _FakePlatform extends PlatformPlayer {
  _FakePlatform() : super(configuration: const PlayerConfiguration());

  /// 模拟 NativePlayer 收到 libmpv `duration` 属性事件。
  void emitDuration(Duration d) {
    state = state.copyWith(duration: d);
    // ignore: invalid_use_of_protected_member
    durationController.add(d);
  }

  void emitPosition(Duration p) {
    state = state.copyWith(position: p);
    // ignore: invalid_use_of_protected_member
    positionController.add(p);
  }
}

/// libmpv 对 MyGO S01E03.mkv 实际给出的 `track-list`（截取音视频与一条字幕轨的关键字段）。
const String _myGoTrackList = '''
[
  {"id":1,"type":"video","image":false,"albumart":false,"external":false,
   "metadata":{"BPS":"1836861","DURATION":"00:23:39.962000000","_STATISTICS_TAGS":"BPS DURATION NUMBER_OF_FRAMES NUMBER_OF_BYTES"}},
  {"id":1,"type":"audio","image":false,"albumart":false,"external":false,
   "metadata":{"BPS":"128000","DURATION":"00:23:40.016000000"}},
  {"id":1,"type":"sub","image":false,"albumart":false,"external":false,
   "metadata":{"DURATION":"00:24:00.000000000"}}
]
''';

const Duration _container = Duration(seconds: 1442);
const Duration _playable = Duration(microseconds: 1420016000);

void main() {
  group('parseTrackDurationTagMicros', () {
    test('Matroska 统计标签（纳秒精度）截到微秒', () {
      expect(parseTrackDurationTagMicros('00:23:39.962000000'), 1419962000);
      expect(parseTrackDurationTagMicros('01:02:03.123456789'), 3723123456);
    });

    test('没有小数部分 / 短小数', () {
      expect(parseTrackDurationTagMicros('00:00:05'), 5000000);
      expect(parseTrackDurationTagMicros('00:00:05.5'), 5500000);
    });

    test('格式不对返回 null', () {
      expect(parseTrackDurationTagMicros(''), isNull);
      expect(parseTrackDurationTagMicros('23:39.962'), isNull);
      expect(parseTrackDurationTagMicros('00:61:00.000'), isNull);
      expect(parseTrackDurationTagMicros('abc'), isNull);
    });
  });

  group('playableEndMicrosFromTrackList', () {
    test('取音视频轨 DURATION 的最大值，字幕轨不算', () {
      expect(playableEndMicrosFromTrackList(_myGoTrackList), 1420016000);
    });

    test('任一音视频轨缺 DURATION 标签就不知道真末尾', () {
      final String json = jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'type': 'video',
          'metadata': <String, String>{'DURATION': '00:23:39.962000000'},
        },
        <String, Object?>{
          'type': 'audio',
          'metadata': <String, String>{'BPS': '128000'},
        },
      ]);
      expect(playableEndMicrosFromTrackList(json), isNull);
    });

    test('音视频轨没有 metadata 也返回 null', () {
      final String json = jsonEncode(<Map<String, Object?>>[
        <String, Object?>{'type': 'video'},
      ]);
      expect(playableEndMicrosFromTrackList(json), isNull);
    });

    test('外挂音轨与封面图不参与', () {
      final String json = jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'type': 'video',
          'metadata': <String, String>{'DURATION': '00:10:00.000000000'},
        },
        <String, Object?>{'type': 'audio', 'external': true},
        <String, Object?>{'type': 'video', 'albumart': true, 'image': true},
      ]);
      expect(playableEndMicrosFromTrackList(json), 600000000);
    });

    test('标签键大小写不敏感（ffmpeg 写的 duration）', () {
      final String json = jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'type': 'audio',
          'metadata': <String, String>{'duration': '00:00:30.000000000'},
        },
      ]);
      expect(playableEndMicrosFromTrackList(json), 30000000);
    });

    test('无音视频轨 / 非法 JSON / 非数组返回 null', () {
      expect(playableEndMicrosFromTrackList('[]'), isNull);
      expect(playableEndMicrosFromTrackList(''), isNull);
      expect(playableEndMicrosFromTrackList('{"type":"video"}'), isNull);
      expect(
        playableEndMicrosFromTrackList(
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'type': 'sub',
              'metadata': <String, String>{'DURATION': '00:24:00.000'},
            },
          ]),
        ),
        isNull,
      );
    });
  });

  group('effectivePlayableDuration', () {
    test('可达末尾早于容器时长 → 用可达末尾', () {
      expect(
        effectivePlayableDuration(reported: _container, playableEnd: _playable),
        _playable,
      );
    });

    test('可达末尾不早于容器时长 / 未知 → 原样', () {
      expect(
        effectivePlayableDuration(
          reported: _container,
          playableEnd: const Duration(seconds: 1500),
        ),
        _container,
      );
      expect(
        effectivePlayableDuration(reported: _container, playableEnd: null),
        _container,
      );
      expect(
        effectivePlayableDuration(
          reported: _container,
          playableEnd: Duration.zero,
        ),
        _container,
      );
    });

    test('容器时长未就绪（0）时不修正', () {
      expect(
        effectivePlayableDuration(
          reported: Duration.zero,
          playableEnd: _playable,
        ),
        Duration.zero,
      );
    });
  });

  test('playableEndContradictedByPosition：只有越过末尾才算推翻', () {
    expect(
      playableEndContradictedByPosition(
        position: const Duration(milliseconds: 1419920),
        playableEnd: _playable,
      ),
      isFalse,
    );
    expect(
      playableEndContradictedByPosition(
        position: _playable,
        playableEnd: _playable,
      ),
      isFalse,
    );
    expect(
      playableEndContradictedByPosition(
        position: _playable + const Duration(milliseconds: 1),
        playableEnd: _playable,
      ),
      isTrue,
    );
  });

  group('VideoPlayableEndCorrection', () {
    test('attach 把 state 与时长流改成可达末尾', () async {
      final _FakePlatform platform = _FakePlatform()..emitDuration(_container);
      final List<Duration> seen = <Duration>[];
      final StreamSubscription<Duration> sub = platform.stream.duration.listen(
        seen.add,
      );
      await pumpEventQueue();
      seen.clear();

      final VideoPlayableEndCorrection? c = VideoPlayableEndCorrection.attach(
        platform: platform,
        playableEnd: _playable,
      );
      expect(c, isNotNull);
      expect(c!.active, isTrue);
      expect(c.reportedDuration, _container);
      expect(platform.state.duration, _playable);
      await pumpEventQueue();
      expect(seen, <Duration>[_playable]);

      c.dispose();
      await sub.cancel();
    });

    test('容器时长不长于可达末尾 / 未就绪时不挂修正', () {
      final _FakePlatform platform = _FakePlatform()
        ..emitDuration(const Duration(seconds: 1400));
      expect(
        VideoPlayableEndCorrection.attach(
          platform: platform,
          playableEnd: _playable,
        ),
        isNull,
      );
      expect(platform.state.duration, const Duration(seconds: 1400));

      final _FakePlatform notReady = _FakePlatform();
      expect(
        VideoPlayableEndCorrection.attach(
          platform: notReady,
          playableEnd: _playable,
        ),
        isNull,
      );
      expect(notReady.state.duration, Duration.zero);
    });

    test('libmpv 重报容器时长时重新盖上修正', () async {
      final _FakePlatform platform = _FakePlatform()..emitDuration(_container);
      final VideoPlayableEndCorrection c = VideoPlayableEndCorrection.attach(
        platform: platform,
        playableEnd: _playable,
      )!;
      await pumpEventQueue();

      platform.emitDuration(_container);
      await pumpEventQueue();
      expect(platform.state.duration, _playable);
      expect(c.reportedDuration, _container);

      c.dispose();
    });

    test('播放位置越过修正值：撤销修正、还原容器时长', () async {
      final _FakePlatform platform = _FakePlatform()..emitDuration(_container);
      final VideoPlayableEndCorrection c = VideoPlayableEndCorrection.attach(
        platform: platform,
        playableEnd: _playable,
      )!;
      await pumpEventQueue();

      platform.emitPosition(const Duration(milliseconds: 1419920));
      await pumpEventQueue();
      expect(c.active, isTrue);
      expect(platform.state.duration, _playable);

      platform.emitPosition(_playable + const Duration(seconds: 5));
      await pumpEventQueue();
      expect(c.active, isFalse);
      expect(platform.state.duration, _container);

      // 撤销后不再改写后续时长。
      platform.emitDuration(_container);
      await pumpEventQueue();
      expect(platform.state.duration, _container);
    });

    test('dispose 后（换集）不再改写新片的时长', () async {
      final _FakePlatform platform = _FakePlatform()..emitDuration(_container);
      final VideoPlayableEndCorrection c = VideoPlayableEndCorrection.attach(
        platform: platform,
        playableEnd: _playable,
      )!;
      await pumpEventQueue();
      c.dispose();
      expect(c.active, isFalse);

      const Duration nextEpisode = Duration(seconds: 1500);
      platform.emitDuration(nextEpisode);
      await pumpEventQueue();
      expect(platform.state.duration, nextEpisode);
    });
  });

  group('VideoPlayerController 接线（源码）', () {
    final String source = File(
      'lib/src/media/video/video_player_controller.dart',
    ).readAsStringSync();

    test('duration 就绪的两条路径都触发可达末尾修正', () {
      final int start = source.indexOf(
        'void _refreshChaptersWhenDurationReady(Player player, int loadToken) {',
      );
      expect(start, isNonNegative);
      final int end = source.indexOf('\n  void ', start + 1);
      final String body = source.substring(start, end);
      expect(
        RegExp(
          r'_refreshPlayableEndForLoad\(player, loadToken\)',
        ).allMatches(body).length,
        2,
        reason: '已就绪分支与首次就绪订阅都要读 track-list 修正时长',
      );
    });

    test('换集与销毁都 dispose 修正（不盖到下一集）', () {
      expect(
        RegExp(
          r'_playableEndCorrection\?\.dispose\(\);',
        ).allMatches(source).length,
        greaterThanOrEqualTo(3),
        reason: 'load 开头、dispose、重新 attach 前各一次',
      );
    });

    test('EOF 写诊断日志（落点 / 时长 / 最近 seek 目标）', () {
      final int start = source.indexOf(
        'void _handleCompletedChanged(bool completed) {',
      );
      expect(start, isNonNegative);
      expect(
        source.substring(start, start + 200),
        contains('_logEndOfFile();'),
      );
    });
  });
}
