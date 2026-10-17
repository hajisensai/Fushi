import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/misc/snapshot_audio_coverage.dart';
import 'package:test/test.dart';

/// 播放器缓冲副本「写成功了但音频缺了一大半」的判据（mkvmerge 封装的 Opus 经
/// libmpv `dump-cache` 落盘，lacing 块里除第一帧外全被 muxer 拒收）。
void main() {
  test('解码成固定规格 PCM 丢弃，只取第一条音轨的时间窗', () {
    final List<String> args = buildSnapshotAudioCoverageArgs(
      inputPath: 'snap.mkv',
      startMs: 12880,
      endMs: 15880,
    );
    expect(args.sublist(args.indexOf('-ss'), args.indexOf('-ss') + 4), <String>[
      '-ss',
      '12.880',
      '-t',
      '3.000',
    ]);
    expect(args.indexOf('-ss'), lessThan(args.indexOf('-i')));
    expect(args[args.indexOf('-map') + 1], '0:a:0');
    expect(args[args.indexOf('-c:a') + 1], 'pcm_s16le');
    expect(args[args.indexOf('-ac') + 1], '1');
    expect(args[args.indexOf('-ar') + 1], '16000');
    expect(args.sublist(args.length - 3), <String>['-f', 'null', '-']);
  });

  test('按解码出的采样量判覆盖：完整 3 秒 94KiB 过、坏副本 12KiB 不过', () {
    // 3 秒单声道 16 kHz s16 = 93.75 KiB。12 KiB 是真实坏副本的读数（约 0.38 秒）。
    expect(
      snapshotAudioCoversWindow(decodedAudioKiB: 94, windowMs: 3000),
      isTrue,
    );
    expect(
      snapshotAudioCoversWindow(decodedAudioKiB: 85, windowMs: 3000),
      isTrue,
    );
    expect(
      snapshotAudioCoversWindow(decodedAudioKiB: 12, windowMs: 3000),
      isFalse,
    );
    expect(
      snapshotAudioCoversWindow(decodedAudioKiB: 0, windowMs: 3000),
      isFalse,
    );
    expect(snapshotAudioCoversWindow(decodedAudioKiB: 0, windowMs: 0), isTrue);
  });

  test('ffmpeg 失败 / 没有统计行都判不完整（调用方回到远端抽取）', () async {
    expect(
      await cachedSnapshotAudioCoversWindow(
        snapshotPath: 'snap.mkv',
        startMs: 0,
        endMs: 3000,
        backend: _FakeBackend(
          const FfmpegRunResult(
            returnCode: 1,
            output: 'Stream map 0:a:0 matches no streams.',
          ),
        ),
      ),
      isFalse,
    );
    expect(
      await cachedSnapshotAudioCoversWindow(
        snapshotPath: 'snap.mkv',
        startMs: 0,
        endMs: 3000,
        backend: _FakeBackend(
          const FfmpegRunResult(returnCode: 0, output: 'size=N/A'),
        ),
      ),
      isFalse,
    );
    expect(
      await cachedSnapshotAudioCoversWindow(
        snapshotPath: 'snap.mkv',
        startMs: 0,
        endMs: 3000,
        backend: _FakeBackend(
          const FfmpegRunResult(
            returnCode: 0,
            output: '[out#0/null @ 0] video:0KiB audio:94KiB subtitle:0KiB',
          ),
        ),
      ),
      isTrue,
    );
  });

  group('真 ffmpeg：稀疏音频包的副本被识破', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('snap_cov'));
    tearDown(() => temp.deleteSync(recursive: true));

    final bool hasLavfi = () {
      try {
        return Process.runSync(resolveFfmpegExecutable(), <String>[
              '-hide_banner', '-f', 'lavfi', '-i', 'anullsrc', //
              '-t', '0.1', '-f', 'null', '-',
            ]).exitCode ==
            0;
      } on ProcessException {
        return false;
      }
    }();

    String makeFixture(String name, {required bool sparse}) {
      final String path = '${temp.path}/$name.mkv';
      final ProcessResult r = Process.runSync(
        resolveFfmpegExecutable(),
        <String>[
          '-hide_banner', '-y', '-f', 'lavfi', //
          '-i',
          'sine=frequency=440:sample_rate=48000:samples_per_frame=960:'
              'duration=8',
          // 每 8 帧只留 1 帧且保留原时间戳：与坏副本「每个 lacing 块只剩第一帧」同形，
          // 时间戳照样铺满整个窗（进度行 time= 仍报 3 秒）。
          if (sparse) ...<String>['-af', "aselect='not(mod(n\\,8))'"],
          '-c:a', 'aac', path,
        ],
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return path;
    }

    test('完整音轨覆盖时间窗', () async {
      expect(
        await cachedSnapshotAudioCoversWindow(
          snapshotPath: makeFixture('full', sparse: false),
          startMs: 2000,
          endMs: 5000,
        ),
        isTrue,
      );
    }, skip: hasLavfi ? false : 'ffmpeg with lavfi unavailable');

    test('稀疏音轨不覆盖时间窗', () async {
      expect(
        await cachedSnapshotAudioCoversWindow(
          snapshotPath: makeFixture('sparse', sparse: true),
          startMs: 2000,
          endMs: 5000,
        ),
        isFalse,
      );
    }, skip: hasLavfi ? false : 'ffmpeg with lavfi unavailable');
  });
}

class _FakeBackend implements FfmpegBackend {
  _FakeBackend(this.result);

  final FfmpegRunResult result;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      result;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
