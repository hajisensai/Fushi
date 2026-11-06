import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/tts_read_along.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_retry.dart';
import 'package:fushi_engine/tts/tts_synthesis_scheduler.dart';
import 'package:fushi_engine/tts/tts_types.dart';

/// 用户报告「微软、谷歌语音朗读经常会断」：任一句（含后台预取、播放器预读的下一句）
/// 合成失败都立刻暂停正在读的句子。现在只有播放器停在失败句上才暂停 + 提示。

Uint8List _wav() {
  const int dataBytes = 3200;
  final ByteData b = ByteData(44 + dataBytes);
  void ascii(int at, String s) {
    for (int i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, 16000, Endian.little);
  b.setUint32(28, 32000, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  return b.buffer.asUint8List();
}

class _Provider extends TtsProvider {
  final Set<String> failing = <String>{};

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: true,
    needsCredential: false,
  );

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    if (failing.contains(text)) {
      throw const TtsFailure(TtsFailureCode.network, 'reset');
    }
    await File(outputPath).writeAsBytes(_wav());
    return const TtsResult(format: TtsAudioFormat.wav);
  }
}

void main() {
  group('TtsFailureReportGate', () {
    test('reports only when the player sits on the failed sentence, once', () {
      final TtsFailureReportGate gate = TtsFailureReportGate();
      expect(gate.shouldReport(failedIndex: null, currentIndex: 0), isFalse);
      // 播放器预读的下一句失败：当前句照常读完。
      expect(gate.shouldReport(failedIndex: 1, currentIndex: 0), isFalse);
      // 播到失败句：暂停并提示一次。
      expect(gate.shouldReport(failedIndex: 1, currentIndex: 1), isTrue);
      expect(gate.shouldReport(failedIndex: 1, currentIndex: 1), isFalse);
      // 用户重试后同一句再失败：重新提示。
      gate.reset();
      expect(gate.shouldReport(failedIndex: 1, currentIndex: 1), isTrue);
    });

    test('a cleared failure re-arms the gate', () {
      final TtsFailureReportGate gate = TtsFailureReportGate();
      expect(gate.shouldReport(failedIndex: 2, currentIndex: 2), isTrue);
      expect(gate.shouldReport(failedIndex: null, currentIndex: 2), isFalse);
      expect(gate.shouldReport(failedIndex: 2, currentIndex: 2), isTrue);
    });
  });

  group('with the real scheduler', () {
    late Directory root;
    late TtsSynthesisScheduler scheduler;
    late _Provider provider;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('tts_gate_test_');
      provider = _Provider();
      scheduler = TtsSynthesisScheduler(
        provider: provider,
        cache: TtsAudioCache(root: root),
        texts: const <String>['t0', 't1', 't2', 't3', 't4'],
        audioIdentity: const <String, Object?>{'p': 'gate'},
        lookahead: 3,
        retryPolicy: TtsRetryPolicy.none,
      );
    });

    tearDown(() async {
      await scheduler.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<void> until(bool Function() condition) async {
      final Stopwatch sw = Stopwatch()..start();
      while (!condition()) {
        if (sw.elapsed > const Duration(seconds: 5)) {
          fail('condition not met');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test(
      'background prefetch failure: no report while reading sentence 0',
      () async {
        provider.failing.add('t2');
        final List<TtsSegmentFailed> failures = <TtsSegmentFailed>[];
        scheduler.events.listen((TtsSegmentEvent e) {
          if (e is TtsSegmentFailed) failures.add(e);
        });
        final TtsFailureReportGate gate = TtsFailureReportGate();
        scheduler.setCursor(0);
        await scheduler.ensure(0);
        await until(() => failures.isNotEmpty);
        expect(failures.single.blocking, isFalse);
        expect(
          gate.shouldReport(
            failedIndex: scheduler.failedIndex,
            currentIndex: 0,
          ),
          isFalse,
          reason: '预取失败不打断正在读的句子',
        );
      },
    );

    test('player preloading the next sentence that fails: report only after '
        'moving onto it', () async {
      provider.failing.add('t1');
      final TtsFailureReportGate gate = TtsFailureReportGate();
      scheduler.setCursor(0);
      await scheduler.ensure(0);
      // just_audio 预读下一句 → 登记为播放器要的句子 → 失败即调度停在它上面。
      unawaited(scheduler.ensure(1).then((_) {}, onError: (Object _) {}));
      await until(() => scheduler.failure != null);
      expect(scheduler.failedIndex, 1);
      expect(
        gate.shouldReport(failedIndex: scheduler.failedIndex, currentIndex: 0),
        isFalse,
      );
      expect(
        gate.shouldReport(failedIndex: scheduler.failedIndex, currentIndex: 1),
        isTrue,
      );
    });
  });
}
