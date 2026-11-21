import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_audio_probe.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_reject_split.dart';
import 'package:fushi_engine/tts/tts_synthesis_scheduler.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

/// 反馈 d53TITyrPq 附录 A：VPTTS 对这句（恰好 86 字）固定返回 400 unsupported_text。
const String _vpttsRejected86 =
    '竜樹お兄様は、緊張でいっぱいの顔で、きょろきょろしていたけれど、そのうち'
    '思い切ったように足を踏み出し、ドレスにかかっている真珠の首飾りを手に'
    'とって、真剣な顔でにらみつけた。';

/// 按规则拒收的假引擎：每个字 100 字节 PCM（8 kHz 16 bit 单声道 → 6.25 ms），
/// 可选每段带一个覆盖全文的词边界。
class _RejectingProvider extends TtsProvider {
  _RejectingProvider(this.rejects, {this.mp3 = false, this.boundaries = false});

  final bool Function(String text) rejects;
  final bool mp3;
  final bool boundaries;
  final List<String> calls = <String>[];

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
  );

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    calls.add(text);
    if (rejects(text)) {
      throw const TtsFailure(TtsFailureCode.rejected, 'HTTP 400');
    }
    await File(outputPath).writeAsBytes(
      mp3 ? buildMp3(frames: 4) : buildWav(dataBytes: text.length * 100),
    );
    return TtsResult(
      format: mp3 ? TtsAudioFormat.mp3 : TtsAudioFormat.wav,
      boundaries: boundaries
          ? <TtsBoundary>[
              TtsBoundary(
                textOffset: 0,
                textLength: text.length,
                offsetMs: 0,
                durationMs: 10,
              ),
            ]
          : const <TtsBoundary>[],
    );
  }
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tts_reject_split_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  String out() => '${root.path}${Platform.pathSeparator}out.part';

  group('splitTtsTextForRejection', () {
    test('86 字样例在离中点最近的读点处拆开，两段都 < 86', () {
      expect(_vpttsRejected86.length, 86);
      final ({String head, String tail})? halves = splitTtsTextForRejection(
        _vpttsRejected86,
      );
      expect(halves, isNotNull);
      expect(halves!.head, endsWith('、'));
      expect(halves.head + halves.tail, _vpttsRejected86);
      expect(halves.head.length, lessThan(86));
      expect(halves.tail.length, lessThan(86));
      expect((halves.head.length - 43).abs(), lessThan(15));
    });

    test('句末标点优先于读点，闭合括号归前一段', () {
      final ({String head, String tail})? halves = splitTtsTextForRejection(
        '「今日はいい天気ですね。」と、彼女はうれしそうに笑ってこちらを見た',
      );
      expect(halves!.head, '「今日はいい天気ですね。」');
      expect(halves.tail, 'と、彼女はうれしそうに笑ってこちらを見た');
    });

    test('没有标点时在正中间硬切', () {
      const String text = 'あいうえおかきくけこさしすせそたちつてと';
      final ({String head, String tail})? halves = splitTtsTextForRejection(
        text,
      );
      expect(halves!.head, 'あいうえおかきくけこ');
      expect(halves.tail, 'さしすせそたちつてと');
    });

    test('太短 / 没有可读字符的文本不拆', () {
      expect(splitTtsTextForRejection('はい、そうです。'), isNull);
      expect(splitTtsTextForRejection('……――……――……――……――'), isNull);
    });

    test('不切开代理对', () {
      const String text = '𠮷𠮷𠮷𠮷𠮷𠮷𠮷𠮷'; // 8 个代理对 = 16 码元
      final ({String head, String tail})? halves = splitTtsTextForRejection(
        text,
      );
      expect(halves!.head + halves.tail, text);
      expect(halves.head.runes.length + halves.tail.runes.length, 8);
    });
  });

  group('ttsSynthesizeSplittingOnReject', () {
    test('不被拒时只发一次原句', () async {
      final _RejectingProvider provider = _RejectingProvider((_) => false);
      await ttsSynthesizeSplittingOnReject(
        provider,
        _vpttsRejected86,
        outputPath: out(),
        cancel: TtsCancelToken(),
      );
      expect(provider.calls, <String>[_vpttsRejected86]);
    });

    test('恰好 86 字被拒：拆成两段合成，拼回一段完整 WAV', () async {
      final _RejectingProvider provider = _RejectingProvider(
        (String t) => t.length == 86,
      );
      final TtsResult result = await ttsSynthesizeSplittingOnReject(
        provider,
        _vpttsRejected86,
        outputPath: out(),
        cancel: TtsCancelToken(),
      );
      expect(result.format, TtsAudioFormat.wav);
      expect(provider.calls, hasLength(3));
      expect(provider.calls[1] + provider.calls[2], _vpttsRejected86);
      final Uint8List bytes = await File(out()).readAsBytes();
      expect(sniffTtsAudioFormat(bytes), TtsAudioFormat.wav);
      // 86 字 × 100 字节 ÷ 16000 B/s = 537.5 ms。
      expect(probeTtsAudioDurationMs(bytes, TtsAudioFormat.wav), 538);
      // 片段临时文件都清掉了，只剩输出。
      expect(root.listSync().map((FileSystemEntity e) => e.path), <String>[
        out(),
      ]);
    });

    test('片段仍被拒时继续往下拆（两层内）', () async {
      final _RejectingProvider provider = _RejectingProvider(
        (String t) => t.length > 40,
      );
      await ttsSynthesizeSplittingOnReject(
        provider,
        _vpttsRejected86,
        outputPath: out(),
        cancel: TtsCancelToken(),
      );
      final List<String> accepted = <String>[
        for (final String c in provider.calls)
          if (c.length <= 40) c,
      ];
      expect(accepted.join(), _vpttsRejected86);
      final Uint8List bytes = await File(out()).readAsBytes();
      expect(probeTtsAudioDurationMs(bytes, TtsAudioFormat.wav), 538);
    });

    test('拆到底仍被拒：上报原句的拒收，不跳过', () async {
      final _RejectingProvider provider = _RejectingProvider((_) => true);
      await expectLater(
        ttsSynthesizeSplittingOnReject(
          provider,
          _vpttsRejected86,
          outputPath: out(),
          cancel: TtsCancelToken(),
        ),
        throwsA(
          isA<TtsFailure>()
              .having((TtsFailure f) => f.code, 'code', TtsFailureCode.rejected)
              .having((TtsFailure f) => f.detail, 'detail', 'HTTP 400'),
        ),
      );
      // 原句 + 两层（2 + 4 段里第一段一路被拒就停）——请求数有上限。
      expect(provider.calls.length, lessThanOrEqualTo(7));
    });

    test('片段是 MP3（不能无损拼接）：不再往下拆，报原句被拒', () async {
      final _RejectingProvider provider = _RejectingProvider(
        (String t) => t.length == 86,
        mp3: true,
      );
      await expectLater(
        ttsSynthesizeSplittingOnReject(
          provider,
          _vpttsRejected86,
          outputPath: out(),
          cancel: TtsCancelToken(),
        ),
        throwsA(
          isA<TtsFailure>().having(
            (TtsFailure f) => f.code,
            'code',
            TtsFailureCode.rejected,
          ),
        ),
      );
      expect(provider.calls, hasLength(2));
    });

    test('非拒收失败不拆，原样上报', () async {
      final FakeTtsProvider provider = FakeTtsProvider()
        ..failing.add(_vpttsRejected86);
      await expectLater(
        ttsSynthesizeSplittingOnReject(
          provider,
          _vpttsRejected86,
          outputPath: out(),
          cancel: TtsCancelToken(),
        ),
        throwsA(
          isA<TtsFailure>().having(
            (TtsFailure f) => f.code,
            'code',
            TtsFailureCode.serverError,
          ),
        ),
      );
      expect(provider.calls, <String>[_vpttsRejected86]);
    });

    test('词边界平移回原句坐标', () async {
      const String text = '  $_vpttsRejected86';
      final _RejectingProvider provider = _RejectingProvider(
        (String t) => t.length >= 86,
        boundaries: true,
      );
      final TtsResult result = await ttsSynthesizeSplittingOnReject(
        provider,
        text,
        outputPath: out(),
        cancel: TtsCancelToken(),
      );
      final String head = provider.calls[1];
      expect(result.boundaries, hasLength(2));
      expect(result.boundaries[0].textOffset, 2);
      expect(result.boundaries[0].offsetMs, 0);
      expect(result.boundaries[1].textOffset, 2 + head.length);
      expect(
        result.boundaries[1].offsetMs,
        (head.length * 100 * 1000 / 16000).round(),
      );
    });
  });

  test('朗读调度：被拒的一句拆开合成后照常就绪，不停下', () async {
    final TtsAudioCache cache = TtsAudioCache(
      root: Directory('${root.path}${Platform.pathSeparator}cache'),
      maxBytes: 1 << 24,
    );
    final _RejectingProvider provider = _RejectingProvider(
      (String t) => t.length == 86,
    );
    final TtsSynthesisScheduler scheduler = TtsSynthesisScheduler(
      provider: provider,
      cache: cache,
      texts: <String>['前の文です。', _vpttsRejected86],
      audioIdentity: const <String, Object?>{'v': 1},
    );
    try {
      final TtsCachedAudio audio = await scheduler.ensure(1);
      expect(audio.durationMs, 538);
      expect(scheduler.failure, isNull);
    } finally {
      await scheduler.dispose();
    }
  });
}
