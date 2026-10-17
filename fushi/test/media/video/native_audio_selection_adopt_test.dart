import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// 视频制卡句子音频取错音轨：用户听日语轨，卡里是容器默认的英语配音。
///
/// 根因：media_kit 的 `state.track.audio` 只随 `setAudioTrack` 更新、`open()` 时重置成
/// `auto`，而 mpv 的 `aid` 会沿用到之后加载的文件。重开后 mpv 仍放日语、
/// [VideoPlayerController.currentAudioStreamIndex] 却是 null，ffmpeg 不加 `-map`
/// 就选了默认英语轨。修复：load 后按 mpv 实际 `aid` 对齐 media_kit 选轨。
///
/// 真 libmpv 用例需要 `FUSHI_TEST_LIBMPV`（libmpv-2.dll）与 `FUSHI_TEST_FFMPEG`
/// （生成双音轨样片），缺一个就跳过；判定纯函数的用例总是跑。
String? _existing(String? path) =>
    path != null && File(path).existsSync() ? File(path).absolute.path : null;

AudioTrack _track(String id, String language) => AudioTrack(id, null, language);

void main() {
  group('adoptableNativeAudioTrack', () {
    final List<AudioTrack> tracks = <AudioTrack>[
      AudioTrack.auto(),
      AudioTrack.no(),
      _track('1', 'eng'),
      _track('2', 'jpn'),
    ];

    test('media_kit 记 auto、mpv 实际放 2 号轨时对齐到 2 号轨', () {
      final AudioTrack? track = VideoPlayerController.adoptableNativeAudioTrack(
        selectedId: 'auto',
        nativeAid: '2',
        tracks: tracks,
      );
      expect(track?.id, '2');
      expect(track?.language, 'jpn');
    });

    test('app 已显式选过轨就以 app 为准，不被 mpv 的值覆盖', () {
      expect(
        VideoPlayerController.adoptableNativeAudioTrack(
          selectedId: '1',
          nativeAid: '2',
          tracks: tracks,
        ),
        isNull,
      );
    });

    test('mpv 没有选中真实轨 / 读不到 / 不在列表里时不动', () {
      for (final String? aid in <String?>[null, '', 'no', 'auto', '7']) {
        expect(
          VideoPlayerController.adoptableNativeAudioTrack(
            selectedId: 'auto',
            nativeAid: aid,
            tracks: tracks,
          ),
          isNull,
          reason: 'aid=$aid',
        );
      }
    });
  });

  test('load 在打开媒体后接上 adoptNativeAudioSelection（接线守卫）', () {
    final String source = File(
      'lib/src/media/video/video_player_controller.dart',
    ).readAsStringSync();
    final int loadStart = source.indexOf('Future<void> load({');
    expect(loadStart, greaterThanOrEqualTo(0));
    final int call = source.indexOf(
      RegExp(r'adoptNativeAudioSelection\(\s*player,'),
      loadStart,
    );
    final int seek = source.indexOf(
      '_markMediaOpenedIfEvident(player);',
      loadStart,
    );
    expect(call, greaterThan(seek), reason: 'open 成功之后才对齐选轨');
    expect(
      source.substring(call, call + 400),
      contains('selectionSeq: () => _audioSelectionSeq'),
    );
    expect(
      RegExp(
        r'Future<void> selectAudioTrack\(AudioTrack track\) async \{[^}]*_audioSelectionSeq\+\+',
      ).hasMatch(source),
      isTrue,
      reason: '显式选轨必须推进代次，否则对齐会覆盖刚选的轨',
    );
  });

  final String? libmpv = _existing(Platform.environment['FUSHI_TEST_LIBMPV']);
  final String? ffmpeg = _existing(Platform.environment['FUSHI_TEST_FFMPEG']);
  final String? skip = libmpv == null || ffmpeg == null
      ? 'Set FUSHI_TEST_LIBMPV (libmpv-2.dll) and FUSHI_TEST_FFMPEG'
      : null;

  setUpAll(() {
    if (libmpv != null) MediaKit.ensureInitialized(libmpv: libmpv);
  });

  test(
    '重开文件后 mpv 仍放日语轨：对齐后制卡下标指向日语轨',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'adopt-aid-',
      );
      addTearDown(() => temp.delete(recursive: true));
      // 与用户的片子同形：英语是默认轨（第 1 条），日语是第 2 条。
      final String fixture = p.join(temp.path, 'dual_audio.mkv');
      final ProcessResult made = await Process.run(ffmpeg!, <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=3',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=880:duration=3',
        '-map',
        '0:a',
        '-map',
        '1:a',
        '-c:a',
        'aac',
        '-metadata:s:a:0',
        'language=eng',
        '-metadata:s:a:1',
        'language=jpn',
        '-disposition:a:0',
        'default',
        '-disposition:a:1',
        '0',
        fixture,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');

      final Player player = Player();
      addTearDown(player.dispose);
      final dynamic native = player.platform;
      await native.setProperty('vo', 'null');
      await native.setProperty('ao', 'null');

      Future<void> openFixture() async {
        await player.open(Media(fixture), play: false);
        expect(
          await VideoPlayerController.waitForRealAudioTracks(player),
          isTrue,
        );
      }

      await openFixture();
      final AudioTrack japanese = player.state.tracks.audio.firstWhere(
        (AudioTrack t) => t.language == 'jpn',
      );
      await player.setAudioTrack(japanese);

      // 换片 / 重开：media_kit 选轨回到 auto，mpv 照样放日语（前提，钉住上游行为）。
      await openFixture();
      expect(player.state.track.audio.id, 'auto');
      expect(
        (await native.getPropertyAsync('aid')).toString(),
        japanese.id,
        reason: 'mpv 沿用上一个文件选过的 aid',
      );

      int seq = 0;
      final bool adopted =
          await VideoPlayerController.adoptNativeAudioSelection(
            player,
            isCurrent: () => true,
            selectionSeq: () => seq,
          );
      expect(adopted, isTrue);
      expect(player.state.track.audio.id, japanese.id);
      // 制卡的 `-map 0:a:N`：去掉 auto/no 后日语是第 2 条 → N=1。
      final List<AudioTrack> real = player.state.tracks.audio
          .where((AudioTrack t) => t.id != 'auto' && t.id != 'no')
          .toList();
      expect(real.indexWhere((AudioTrack t) => t.id == japanese.id), 1);
      expect(
        (await native.getPropertyAsync('aid')).toString(),
        japanese.id,
        reason: '对齐写回同一个 aid，不切轨',
      );

      // 读 aid 期间有显式选轨（续播恢复 / 用户点选）：放弃对齐，不覆盖。
      await openFixture();
      final Future<bool> racing =
          VideoPlayerController.adoptNativeAudioSelection(
            player,
            isCurrent: () => true,
            selectionSeq: () => seq,
          );
      seq++;
      expect(await racing, isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
