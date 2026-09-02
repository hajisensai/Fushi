import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/immersion_capture_channel.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart';
import 'package:fushi/src/sync/immersion_mine_payload.dart';

ImmersionMinePayload _payload({Uint8List? shot}) => ImmersionMinePayload(
      fields: const {'expression': '走る'},
      sentence: 's',
      netflixVideoId: '81',
      clipStartMs: 1000,
      clipEndMs: 3000,
      screenshotBytes: shot,
    );

void main() {
  group('buildImmersionRequest', () {
    test(
        'capture ok with gif+audio -> uses gif cover + audio, requireAudio true',
        () {
      final req = buildImmersionRequest(
        _payload(),
        ImmersionCaptureResult(
            gifBytes: Uint8List.fromList([1]),
            audioBytes: Uint8List.fromList([2])),
        audioExpected: true,
      );
      expect(req.providedCoverName, 'netflix_clip.gif');
      expect(req.providedCoverBytes, [1]);
      expect(req.providedAudioBytes, [2]);
      expect(req.providedAudioName,
          'netflix_audio.${immersionMiningAudioExtension()}');
      expect(req.requireAudio, true);
      expect(req.mediaSource, isNull);
      expect(req.documentTitle, 'Netflix');
    });

    test(
        'capture error -> degrades to screenshot cover, no audio, requireAudio false',
        () {
      final req = buildImmersionRequest(
        _payload(shot: Uint8List.fromList([9])),
        const ImmersionCaptureResult(error: 'black frame'),
        audioExpected: false,
      );
      expect(req.providedCoverName, 'netflix_shot.jpg');
      expect(req.providedCoverBytes, [9]);
      expect(req.providedAudioBytes, isNull);
      expect(req.requireAudio, false);
    });

    test('capture ok but gif missing -> falls back to screenshot cover', () {
      final req = buildImmersionRequest(
        _payload(shot: Uint8List.fromList([7])),
        ImmersionCaptureResult(audioBytes: Uint8List.fromList([2])),
        audioExpected: true,
      );
      expect(req.providedCoverName, 'netflix_shot.jpg');
      expect(req.providedCoverBytes, [7]);
      expect(req.providedAudioBytes, [2]);
      expect(req.providedAudioName,
          'netflix_audio.${immersionMiningAudioExtension()}');
      expect(req.requireAudio, true);
    });

    // BUG-1330：封面扩展名必须跟随**实际产出格式**（ImmersionCaptureResult.animatedFormat），
    // 不是硬编码 .gif，也不是用户所选格式 —— 编码器缺失时捕获内部已降级 GIF，按所选格式
    // 拼名会写出 `.avif` 里装 GIF 字节的卡（Anki 按扩展名判 MIME → 封面显示不出来）。
    test('cover name follows the actually produced animated format', () {
      for (final MiningAnimatedFormat format in MiningAnimatedFormat.values) {
        final req = buildImmersionRequest(
          _payload(),
          ImmersionCaptureResult(
            gifBytes: Uint8List.fromList([1]),
            audioBytes: Uint8List.fromList([2]),
            animatedFormat: format,
          ),
          audioExpected: true,
        );
        expect(req.providedCoverName, 'netflix_clip.${format.fileExtension}',
            reason: '$format 的封面扩展名必须是 .${format.fileExtension}。BUG-1330。');
      }
    });

    test('animatedFormat defaults to gif (native channel wire has no format)',
        () {
      const ImmersionCaptureResult r = ImmersionCaptureResult();
      expect(r.animatedFormat, MiningAnimatedFormat.gif);
      expect(
          ImmersionCaptureResult.fromMap(const <Object?, Object?>{})
              .animatedFormat,
          MiningAnimatedFormat.gif,
          reason: 'native 后台软解实例的 wire 契约里只有 GIF 字节，不去猜格式。');
    });

    test('2A only (skip capture) -> screenshot cover, no audio', () {
      final req = buildImmersionRequest(
        _payload(shot: Uint8List.fromList([5])),
        const ImmersionCaptureResult(error: 'skip'),
        audioExpected: false,
      );
      expect(req.providedCoverBytes, [5]);
      expect(req.providedAudioBytes, isNull);
      expect(req.requireAudio, false);
    });

    // 媒体文件名的前缀是「这份字节哪来的」的来源标记（见 ImmersionMiningEngine 文件头）。
    // 扩展现在会在任意网页（bilibili.com 等）取当前解码帧走同一条 provided 字节路——
    // 那些卡再标成 netflix_* 就是把来源标记写成假的。判据取 Netflix 独有的两个字段：
    // 录制片段字节、或后台软解用的 netflixVideoId。
    test('非 Netflix 来源（网页解码帧）不得标成 netflix_*，标题也不回落 Netflix', () {
      final req = buildImmersionRequest(
        ImmersionMinePayload(
          fields: const {'expression': '正道'},
          sentence: '正道ではなく邪道',
          screenshotBytes: Uint8List.fromList([1, 2, 3]),
        ),
        const ImmersionCaptureResult(error: 'skip'),
        audioExpected: false,
      );
      expect(req.providedCoverName, 'web_shot.jpg');
      expect(req.documentTitle, 'Web',
          reason: '非 Netflix 的卡上写着 Netflix 是错的事实，不是缺省值');
      expect(req.providedCoverBytes, [1, 2, 3]);
      expect(req.requireAudio, false, reason: '截图卡本就无音频，不算失败');
    });

    test('扩展带上来的页面标题优先于任何回落', () {
      final req = buildImmersionRequest(
        ImmersionMinePayload(
          fields: const {'expression': '正道'},
          sentence: 's',
          documentTitle: 'Re:ゼロ 第四季 第13話',
          screenshotBytes: Uint8List.fromList([1]),
        ),
        const ImmersionCaptureResult(error: 'skip'),
        audioExpected: false,
      );
      expect(req.documentTitle, 'Re:ゼロ 第四季 第13話');
    });

    test('Netflix 来源（录制片段/后台软解）的来源标记与标题一字未改', () {
      // 只有 clipBytes、没有 netflixVideoId 时也必须认出是 Netflix 来源。
      final req = buildImmersionRequest(
        ImmersionMinePayload(
          fields: const {'expression': 'x'},
          sentence: 's',
          clipBytes: Uint8List.fromList([1]),
          screenshotBytes: Uint8List.fromList([2]),
        ),
        const ImmersionCaptureResult(error: 'black frame'),
        audioExpected: false,
      );
      expect(req.providedCoverName, 'netflix_shot.jpg');
      expect(req.documentTitle, 'Netflix');
    });
  });
}
