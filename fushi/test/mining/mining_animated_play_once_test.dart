import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_window_gif.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show MiningAnimatedFormat;
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

/// 反馈 ZxyIMK-C5V：GIF 制进 Anki 后无限循环，希望像视频片段一样只播一遍。
///
/// `-loop` 的口径三个 muxer 各不相同，已用 Windows 随包 ffmpeg 实测并按字节核对产物：
/// GIF `-loop -1` 不写 NETSCAPE2.0 扩展（`0` 时写、计数 0 = 无限）；WebP `-loop 1`
/// 写 ANIM 循环计数 1（`0` = 无限）；AVIF `-loop 1` 时 `elst` repeat 标志位为 0
/// （`0` 时为 1）。这里钉住参数映射与两条动图链的接线。
void main() {
  String loopValue(List<String> args) => args[args.indexOf('-loop') + 1];

  group('animatedLoopArgs', () {
    test('循环（默认）：三种格式都是 -loop 0', () {
      for (final MiningAnimatedFormat f in MiningAnimatedFormat.values) {
        expect(animatedLoopArgs(f, playOnce: false), <String>['-loop', '0']);
      }
    });

    test('只播一次：GIF 用 -1，WebP / AVIF 用 1', () {
      expect(
        animatedLoopArgs(MiningAnimatedFormat.gif, playOnce: true),
        <String>['-loop', '-1'],
      );
      expect(
        animatedLoopArgs(MiningAnimatedFormat.webp, playOnce: true),
        <String>['-loop', '1'],
      );
      expect(
        animatedLoopArgs(MiningAnimatedFormat.avif, playOnce: true),
        <String>['-loop', '1'],
      );
    });
  });

  group('视频 cue 动图', () {
    for (final MiningAnimatedFormat f in MiningAnimatedFormat.values) {
      test('${f.wireName}：playOnce 透传到 -loop，且恰好一个 -loop 紧贴输出前', () {
        List<String> build(bool once) => buildFfmpegClipAnimatedArgs(
          format: f,
          inputPath: '/v/a.mkv',
          startMs: 0,
          endMs: 2000,
          outputPath: '/tmp/o.${f.fileExtension}',
          playOnce: once,
        );
        expect(loopValue(build(false)), '0');
        expect(
          loopValue(build(true)),
          f == MiningAnimatedFormat.gif ? '-1' : '1',
        );
        final List<String> once = build(true);
        expect(once.where((String a) => a == '-loop'), hasLength(1));
        expect(once.indexOf('-loop'), once.length - 3);
      });
    }
  });

  group('galgame 窗口动图', () {
    for (final MiningAnimatedFormat f in MiningAnimatedFormat.values) {
      test('${f.wireName}：playOnce 透传到 -loop（GIF 也显式传）', () {
        List<String> build(bool once) => buildGalWindowAnimatedArgs(
          format: f,
          inputPattern: '/tmp/f_%03d.png',
          outputPath: '/tmp/o.${f.fileExtension}',
          fps: 8,
          maxWidth: 480,
          playOnce: once,
        );
        expect(loopValue(build(false)), '0');
        expect(
          loopValue(build(true)),
          f == MiningAnimatedFormat.gif ? '-1' : '1',
        );
      });
    }
  });

  test('接线：IO 层读偏好读取器，偏好仓库把读取器接到自己身上', () {
    final String clipper = File(
      '../packages/fushi_engine/lib/utils/misc/desktop_audio_clipper.dart',
    ).readAsStringSync();
    expect(
      clipper,
      contains('playOnce: playOnce ?? resolveMiningAnimatedPlayOnce()'),
      reason: 'extractClipGifViaFfmpeg 没读「动图只播放一次」偏好',
    );
    expect(
      File('lib/src/mining/galgame_window_gif.dart').readAsStringSync(),
      contains('playOnce: miningAnimatedPlayOnceReader()'),
      reason: 'galgame 动图链没读「动图只播放一次」偏好',
    );
    expect(
      File('lib/src/models/preferences_repository.dart').readAsStringSync(),
      contains('miningAnimatedPlayOnceReader = () => miningAnimatedPlayOnce;'),
    );
  });

  // 反馈 biLEesNqWb：浏览器扩展按所选（非激活）配置制卡时，「动图只播一次」取那份配置，
  // 经 zone 覆盖传到 IO 层；zone 外仍读进程级偏好读取器。
  test('zone 覆盖优先于进程级读取器，zone 外不变', () {
    final bool Function() saved = miningAnimatedPlayOnceReader;
    addTearDown(() => miningAnimatedPlayOnceReader = saved);
    miningAnimatedPlayOnceReader = () => false;
    expect(resolveMiningAnimatedPlayOnce(), isFalse);
    expect(
      runZoned(
        resolveMiningAnimatedPlayOnce,
        zoneValues: <Object, Object>{kMiningAnimatedPlayOnceZoneKey: true},
      ),
      isTrue,
    );
    miningAnimatedPlayOnceReader = () => true;
    expect(
      runZoned(
        resolveMiningAnimatedPlayOnce,
        zoneValues: <Object, Object>{kMiningAnimatedPlayOnceZoneKey: false},
      ),
      isFalse,
    );
    expect(resolveMiningAnimatedPlayOnce(), isTrue);
  });
}
