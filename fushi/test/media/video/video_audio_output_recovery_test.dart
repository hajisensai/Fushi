import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_audio_output_recovery.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// BUG-3767：播放中 Windows 音频设备失效（AUDCLNT_E_DEVICE_INVALIDATED → 重试撞上
/// AUDCLNT_E_DEVICE_IN_USE），mpv 报 `Could not open/initialize audio device -> no
/// sound.` 并取消选中音轨，视频照放、声音永久消失，只能重启 app。
///
/// 修复：[VideoAudioOutputRecovery] 按退避重选音轨直到 ao 建起来，设备列表变化时立即
/// 重试。真 libmpv 用例需要 `FUSHI_TEST_LIBMPV`（libmpv-2.dll）与 `FUSHI_TEST_FFMPEG`
/// （生成样片），缺一个就跳过；状态机与接线守卫总是跑。
const String _lostLine = 'Could not open/initialize audio device -> no sound.';

String? _existing(String? path) =>
    path != null && File(path).existsSync() ? File(path).absolute.path : null;

void main() {
  group('VideoAudioOutputRecovery 状态机', () {
    test('只认「音频设备打不开」，其它 mpv 错误不触发', () {
      fakeAsync((FakeAsync async) {
        int calls = 0;
        final VideoAudioOutputRecovery recovery = VideoAudioOutputRecovery(
          reselectAudio: () async {
            calls++;
            return VideoAudioRecoveryAttempt.recovered;
          },
        );
        recovery.onPlayerError('Could not open codec.');
        recovery.onPlayerError('Failed to create file cache.');
        async.elapse(const Duration(minutes: 1));
        expect(recovery.lost, isFalse);
        expect(calls, 0);
      });
    });

    test('丢失后按退避重试，ao 建起来即停止', () {
      fakeAsync((FakeAsync async) {
        final List<Duration> at = <Duration>[];
        int remainingFailures = 2;
        final VideoAudioOutputRecovery recovery = VideoAudioOutputRecovery(
          reselectAudio: () async {
            at.add(async.elapsed);
            if (remainingFailures-- > 0) {
              return VideoAudioRecoveryAttempt.stillLost;
            }
            return VideoAudioRecoveryAttempt.recovered;
          },
        );
        recovery.onPlayerError(_lostLine);
        expect(recovery.lost, isTrue);
        async.elapse(const Duration(minutes: 5));
        expect(at, <Duration>[
          const Duration(seconds: 1),
          const Duration(seconds: 3),
          const Duration(seconds: 7),
        ]);
        expect(recovery.lost, isFalse);
      });
    });

    test('设备一直不回来：不放弃，间隔封顶在最后一档', () {
      fakeAsync((FakeAsync async) {
        final List<Duration> at = <Duration>[];
        final VideoAudioOutputRecovery recovery = VideoAudioOutputRecovery(
          reselectAudio: () async {
            at.add(async.elapsed);
            return VideoAudioRecoveryAttempt.stillLost;
          },
        );
        recovery.onPlayerError(_lostLine);
        async.elapse(const Duration(minutes: 3));
        expect(recovery.lost, isTrue);
        final List<Duration> gaps = <Duration>[
          for (int i = 1; i < at.length; i++) at[i] - at[i - 1],
        ];
        expect(gaps.take(5), <Duration>[
          const Duration(seconds: 2),
          const Duration(seconds: 4),
          const Duration(seconds: 8),
          const Duration(seconds: 15),
          const Duration(seconds: 30),
        ]);
        expect(gaps.skip(5), everyElement(const Duration(seconds: 30)));
        expect(gaps.length, greaterThan(5));
      });
    });

    test('尝试自身失败时 mpv 再报一次丢失：不重复排期', () {
      fakeAsync((FakeAsync async) {
        int calls = 0;
        late VideoAudioOutputRecovery recovery;
        recovery = VideoAudioOutputRecovery(
          reselectAudio: () async {
            calls++;
            recovery.onPlayerError(_lostLine); // mpv 在写回 aid 时再次失败。
            return VideoAudioRecoveryAttempt.stillLost;
          },
        );
        recovery.onPlayerError(_lostLine);
        recovery.onPlayerError(_lostLine); // 同一次丢失报两行。
        async.elapse(const Duration(seconds: 3));
        expect(calls, 2, reason: '1s 一次 + 2s 后一次，没有叠加的计时器');
      });
    });

    test('设备列表变化：立即重试并重置退避', () {
      fakeAsync((FakeAsync async) {
        final List<Duration> at = <Duration>[];
        bool deviceBack = false;
        final VideoAudioOutputRecovery recovery = VideoAudioOutputRecovery(
          reselectAudio: () async {
            at.add(async.elapsed);
            return deviceBack
                ? VideoAudioRecoveryAttempt.recovered
                : VideoAudioRecoveryAttempt.stillLost;
          },
        );
        recovery.onPlayerError(_lostLine);
        async.elapse(const Duration(seconds: 20)); // 退避已拉到 15s 档。
        final int before = at.length;
        deviceBack = true;
        recovery.onAudioDevicesChanged();
        async.flushMicrotasks();
        expect(at.length, before + 1);
        expect(at.last, const Duration(seconds: 20));
        expect(recovery.lost, isFalse);
        async.elapse(const Duration(minutes: 1));
        expect(at.length, before + 1, reason: '恢复后不再尝试');
      });
    });

    test('没丢失时设备列表变化不触发任何尝试', () {
      fakeAsync((FakeAsync async) {
        int calls = 0;
        final VideoAudioOutputRecovery recovery = VideoAudioOutputRecovery(
          reselectAudio: () async {
            calls++;
            return VideoAudioRecoveryAttempt.recovered;
          },
        );
        recovery.onAudioDevicesChanged();
        async.elapse(const Duration(seconds: 5));
        expect(calls, 0);
      });
    });

    test('reset（换集 / 销毁）取消排期，在途结果作废', () {
      fakeAsync((FakeAsync async) {
        final Completer<VideoAudioRecoveryAttempt> inFlight =
            Completer<VideoAudioRecoveryAttempt>();
        int calls = 0;
        final VideoAudioOutputRecovery recovery = VideoAudioOutputRecovery(
          reselectAudio: () {
            calls++;
            return inFlight.future;
          },
        );
        recovery.onPlayerError(_lostLine);
        async.elapse(const Duration(seconds: 1));
        expect(calls, 1);
        recovery.reset();
        inFlight.complete(VideoAudioRecoveryAttempt.stillLost);
        async.elapse(const Duration(minutes: 1));
        expect(calls, 1, reason: '作废的尝试不得再排下一次');
        expect(recovery.lost, isFalse);
      });
    });

    test('abandoned（Player 换了 / 用户本来选了无音轨）就停', () {
      fakeAsync((FakeAsync async) {
        int calls = 0;
        final VideoAudioOutputRecovery recovery = VideoAudioOutputRecovery(
          reselectAudio: () async {
            calls++;
            return VideoAudioRecoveryAttempt.abandoned;
          },
        );
        recovery.onPlayerError(_lostLine);
        async.elapse(const Duration(minutes: 1));
        expect(calls, 1);
        expect(recovery.lost, isFalse);
      });
    });

    test('尝试抛异常按仍丢失处理，继续退避', () {
      fakeAsync((FakeAsync async) {
        int calls = 0;
        final VideoAudioOutputRecovery recovery = VideoAudioOutputRecovery(
          reselectAudio: () async {
            calls++;
            throw StateError('native gone');
          },
        );
        recovery.onPlayerError(_lostLine);
        async.elapse(const Duration(seconds: 3));
        expect(calls, 2);
        expect(recovery.lost, isTrue);
      });
    });
  });

  group('videoAudioRecoveryTargetAid', () {
    final List<AudioTrack> tracks = <AudioTrack>[
      AudioTrack.auto(),
      AudioTrack.no(),
      const AudioTrack('1', null, 'eng'),
      const AudioTrack('2', null, 'jpn', isDefault: true),
    ];

    test('选过具体轨：写回丢失前的那条', () {
      expect(videoAudioRecoveryTargetAid('1', tracks), '1');
    });

    test('auto 不能原样写回（播放中 aid=auto 是 no-op）：落到容器默认轨', () {
      expect(videoAudioRecoveryTargetAid('auto', tracks), '2');
    });

    test('auto 且没有默认轨：落到第一条真实轨', () {
      expect(
        videoAudioRecoveryTargetAid('auto', <AudioTrack>[
          AudioTrack.auto(),
          AudioTrack.no(),
          const AudioTrack('3', null, 'eng'),
          const AudioTrack('4', null, 'jpn'),
        ]),
        '3',
      );
    });

    test('用户选了无音轨 / 无值 / 没有真实轨：不恢复', () {
      expect(videoAudioRecoveryTargetAid('no', tracks), isNull);
      expect(videoAudioRecoveryTargetAid('', tracks), isNull);
      expect(videoAudioRecoveryTargetAid(null, tracks), isNull);
      expect(
        videoAudioRecoveryTargetAid('auto', <AudioTrack>[
          AudioTrack.auto(),
          AudioTrack.no(),
        ]),
        isNull,
      );
    });
  });

  test('控制器接线：错误流 / 设备列表 / load 重置 / 销毁都接上恢复（接线守卫）', () {
    final String source = File(
      'lib/src/media/video/video_player_controller.dart',
    ).readAsStringSync();
    final int errorSub = source.indexOf(
      '_errorSub = player.stream.error.listen',
    );
    expect(errorSub, greaterThanOrEqualTo(0));
    expect(
      source.substring(errorSub, errorSub + 700),
      contains('_audioOutputRecovery.onPlayerError(message);'),
      reason: 'mpv 错误流必须喂给恢复，否则丢失后永远静音',
    );
    expect(
      RegExp(
        r'stream\.audioDevices\.listen\([^)]*\)\s*\{[^}]*_audioOutputRecovery\.onAudioDevicesChanged\(\)',
      ).hasMatch(source),
      isTrue,
      reason: '设备列表变化（设备回来了）要立即重试',
    );
    final int load = source.indexOf('Future<void> load({');
    final int token = source.indexOf(
      'final int loadToken = ++_loadToken;',
      load,
    );
    expect(
      source.substring(token, token + 300),
      contains('_audioOutputRecovery.reset();'),
      reason: '换集重置：上一片的恢复不能写到新片',
    );
    final int dispose = source.indexOf('  void dispose() {');
    expect(
      source.indexOf('_audioOutputRecovery.dispose();', dispose),
      greaterThan(dispose),
    );
    final int release = source.indexOf(
      'Future<void> _releaseMediaHandles() async {',
    );
    final int releaseEnd = source.indexOf('await player.dispose();', release);
    expect(
      source.substring(release, releaseEnd),
      contains('_audioOutputRecovery.reset();'),
      reason: '释放句柄换 Player 时停掉恢复',
    );
  });

  final String? libmpv = _existing(Platform.environment['FUSHI_TEST_LIBMPV']);
  final String? ffmpeg = _existing(Platform.environment['FUSHI_TEST_FFMPEG']);
  final String? skip = !Platform.isWindows
      ? 'wasapi 设备失效路径只在 Windows 上复现'
      : libmpv == null || ffmpeg == null
      ? 'Set FUSHI_TEST_LIBMPV (libmpv-2.dll) and FUSHI_TEST_FFMPEG'
      : null;

  setUpAll(() {
    if (libmpv != null) MediaKit.ensureInitialized(libmpv: libmpv);
  });

  test(
    '真 libmpv：音频设备打不开后静音，设备回来后自动恢复声音',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'ao-recovery-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final String fixture = p.join(temp.path, 'av.mkv');
      final ProcessResult made = await Process.run(ffmpeg!, <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc=size=160x90:rate=24:duration=60',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=60',
        '-c:v',
        'libx264',
        '-preset',
        'ultrafast',
        '-c:a',
        'aac',
        fixture,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');

      final Player player = Player();
      addTearDown(player.dispose);
      final dynamic native = player.platform;
      await native.setProperty('vo', 'null');
      await player.setVolume(0);
      Future<String> prop(String name) async =>
          (await native.getPropertyAsync(name)).toString().trim();

      final VideoAudioOutputRecovery recovery = VideoAudioOutputRecovery(
        reselectAudio: () => VideoPlayerController.reselectAudioAfterOutputLoss(
          player,
          isCurrent: () => true,
          verifyDelay: const Duration(milliseconds: 500),
        ),
        backoff: const <Duration>[Duration(milliseconds: 300)],
      );
      addTearDown(recovery.dispose);
      final StreamSubscription<String> errors = player.stream.error.listen(
        recovery.onPlayerError,
      );
      addTearDown(errors.cancel);

      await player.open(Media(fixture));
      // 不挂 VideoController 时 media_kit 让 vid=no；没有视频轨的话音轨一失败 mpv 就
      // 整片停播，和现场（视频照放、只是没声音）不同形。
      await native.setProperty('vid', '1');
      Future<void> waitFor(bool Function() ok, String what) async {
        final DateTime deadline = DateTime.now().add(
          const Duration(seconds: 10),
        );
        while (!ok()) {
          if (DateTime.now().isAfter(deadline)) fail('timed out: $what');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      String ao = '';
      Future<void> pollAo() async => ao = await prop('current-ao');
      await waitFor(() {
        unawaited(pollAo());
        return ao.isNotEmpty;
      }, 'initial ao');

      // 设备「失效」：指向不存在的 wasapi 设备，走与现场相同的 ao 初始化失败路径。
      await native.setProperty(
        'audio-device',
        'wasapi/{00000000-dead-beef-0000-000000000000}',
      );
      await waitFor(() => recovery.lost, 'audio output lost');
      expect(await prop('aid'), 'no', reason: 'mpv 把音轨取消选中（前提，钉住上游行为）');
      expect(await prop('time-pos'), isNotEmpty, reason: '视频照放');

      // 设备不在时恢复照样失败、继续退避，不把播放打停。
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(recovery.lost, isTrue);
      expect(recovery.attempts, greaterThan(1));
      expect(await prop('current-ao'), isEmpty);

      // 设备回来：仅此一步 mpv 自己不会恢复（实测 ao-reload 也无效），靠重选音轨。
      await native.setProperty('audio-device', 'auto');
      await waitFor(() => !recovery.lost, 'audio output recovered');
      expect(await prop('current-ao'), isNotEmpty);
      expect(await prop('aid'), isNot('no'));
      expect(await prop('audio-codec-name'), 'aac');
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
