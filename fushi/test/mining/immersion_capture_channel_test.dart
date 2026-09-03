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
    // ── BUG-2080：卡面时间窗 vs 抽取意图，两层语义拆开 ──────────────────────
    //
    // 修复前这里硬编码 `clipStartMs: 0, clipEndMs: 0`，因为当时 `hasRange` 就是
    // 「窗非空」——填真值会连带打开区间抽取，而 Netflix 前台 `mediaSource == null`
    // 根本没有可裁的源。代价是 `{clip-timestamp}` 对 Netflix **结构性恒空**。
    test('Netflix：扩展上报的时间窗原样透传到 request（{clip-timestamp} 的数据源）', () {
      final req = buildImmersionRequest(
        _payload(),
        ImmersionCaptureResult(
            gifBytes: Uint8List.fromList([1]),
            audioBytes: Uint8List.fromList([2])),
        audioExpected: true,
      );
      // _payload() 带的是 1000/3000。修复前这两条恒 0。
      expect(req.clipStartMs, 1000);
      expect(req.clipEndMs, 3000);
    });

    // 这一条是**防回退**守卫：谁要是把 `hasRange` 化简回「窗非空」，它立刻红。
    // 有窗 ≠ 要裁——Netflix 前台有窗（播放器时间轴）但无源（本地零字节）。
    test('Netflix：有卡面窗，但抽取意图仍为假（无 mediaSource/audioSource 可裁）', () {
      final req = buildImmersionRequest(
        _payload(),
        ImmersionCaptureResult(
            gifBytes: Uint8List.fromList([1]),
            audioBytes: Uint8List.fromList([2])),
        audioExpected: true,
      );
      expect(req.mediaSource, isNull);
      expect(req.audioSource, isNull);
      expect(req.hasClipWindow, true, reason: '窗非空，卡面要渲染时间戳');
      expect(req.hasRange, false, reason: '没有可裁的源 ⇒ 引擎不得走区间抽取路径');
    });

    test('Netflix：payload 没带窗（null）→ 两端 0，两个判据都为假', () {
      final req = buildImmersionRequest(
        ImmersionMinePayload(
          fields: const {'expression': '走る'},
          sentence: 's',
          netflixVideoId: '81',
          screenshotBytes: Uint8List.fromList([9]),
        ),
        const ImmersionCaptureResult(error: 'black frame'),
        audioExpected: false,
      );
      expect(req.clipStartMs, 0);
      expect(req.clipEndMs, 0);
      expect(req.hasClipWindow, false);
      expect(req.hasRange, false);
    });

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
  });
}
