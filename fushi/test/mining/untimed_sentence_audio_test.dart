import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/untimed_sentence_audio.dart';

/// 拍板台 lmJyeqpCaO：无字幕时间时的句子音频——区间纯函数、ffmpeg 参数、WAV 解析，
/// 以及视频页把合成锚点接进原有制卡链的源码契约。
void main() {
  group('UntimedSentenceAudioMode', () {
    test('未知 / 缺失值回退「不截取」（= 现状）', () {
      expect(
        UntimedSentenceAudioMode.fromWireName(null),
        UntimedSentenceAudioMode.off,
      );
      expect(
        UntimedSentenceAudioMode.fromWireName('bogus'),
        UntimedSentenceAudioMode.off,
      );
      for (final UntimedSentenceAudioMode m
          in UntimedSentenceAudioMode.values) {
        expect(UntimedSentenceAudioMode.fromWireName(m.wireName), m);
      }
    });

    test('窗口长度规整到 2–15 秒、按秒取整，缺省 6 秒', () {
      expect(normalizeUntimedSentenceAudioWindowMs(null), 6000);
      expect(normalizeUntimedSentenceAudioWindowMs(500), 2000);
      expect(normalizeUntimedSentenceAudioWindowMs(99999), 15000);
      expect(normalizeUntimedSentenceAudioWindowMs(7400), 7000);
    });
  });

  group('untimedFixedWindow', () {
    test('以暂停位置为准，前 2/3、后 1/3', () {
      expect(
        untimedFixedWindow(positionMs: 10000, windowMs: 6000),
        const UntimedSentenceAudioWindow(
          startMs: 6000,
          endMs: 12000,
          origin: UntimedSentenceAudioOrigin.fixedWindow,
        ),
      );
    });

    test('贴近片头 / 片尾时整体平移，长度不变', () {
      final UntimedSentenceAudioWindow head = untimedFixedWindow(
        positionMs: 1000,
        windowMs: 6000,
      );
      expect((head.startMs, head.endMs), (0, 6000));
      final UntimedSentenceAudioWindow tail = untimedFixedWindow(
        positionMs: 10500,
        windowMs: 6000,
        durationMs: 11000,
      );
      expect((tail.startMs, tail.endMs), (5000, 11000));
    });
  });

  group('untimedVoiceWindow', () {
    const List<({int startMs, int endMs})> dialogue =
        <({int startMs, int endMs})>[
          (startMs: 2000, endMs: 4000), // 别人：「じゃあ、また明日」
          (startMs: 6600, endMs: 9400), // 女主：「約束、忘れないでね」
          (startMs: 11000, endMs: 11600), // 主角：「うん」
        ];

    test('取包含暂停位置的那段人声', () {
      final UntimedSentenceAudioWindow? w = untimedVoiceWindow(
        segments: dialogue,
        positionMs: 8000,
        maxMs: 8000,
      );
      expect(w?.startMs, 6600);
      expect(w?.endMs, 9400);
      expect(w?.origin, UntimedSentenceAudioOrigin.voiceDetection);
    });

    test('暂停在停顿里取它前面最近的一段；前面没有人声 → null', () {
      final UntimedSentenceAudioWindow? gap = untimedVoiceWindow(
        segments: dialogue,
        positionMs: 10000,
        maxMs: 8000,
      );
      expect((gap?.startMs, gap?.endMs), (6600, 9400));
      expect(
        untimedVoiceWindow(segments: dialogue, positionMs: 1000, maxMs: 8000),
        isNull,
      );
      expect(
        untimedVoiceWindow(
          segments: const <({int startMs, int endMs})>[],
          positionMs: 1000,
          maxMs: 8000,
        ),
        isNull,
      );
    });

    test('超过「最长」截断：包含暂停位置的段围着暂停位置截，之前的段留末尾', () {
      const List<({int startMs, int endMs})> long =
          <({int startMs, int endMs})>[(startMs: 0, endMs: 20000)];
      final UntimedSentenceAudioWindow? inside = untimedVoiceWindow(
        segments: long,
        positionMs: 10000,
        maxMs: 3000,
      );
      expect((inside?.startMs, inside?.endMs), (8000, 11000));
      final UntimedSentenceAudioWindow? atEdge = untimedVoiceWindow(
        segments: long,
        positionMs: 19500,
        maxMs: 3000,
      );
      expect((atEdge?.startMs, atEdge?.endMs), (17000, 20000));
      final UntimedSentenceAudioWindow? before = untimedVoiceWindow(
        segments: long,
        positionMs: 25000,
        maxMs: 3000,
      );
      expect((before?.startMs, before?.endMs), (17000, 20000));
    });

    test('开头 / 结尾余量外扩但不越过相邻人声段', () {
      final UntimedSentenceAudioWindow? w = untimedVoiceWindow(
        segments: dialogue,
        positionMs: 8000,
        maxMs: 8000,
        headPadMs: 5000,
        tailPadMs: 5000,
      );
      expect((w?.startMs, w?.endMs), (4000, 11000));
      final UntimedSentenceAudioWindow? small = untimedVoiceWindow(
        segments: dialogue,
        positionMs: 8000,
        maxMs: 8000,
        headPadMs: 200,
        tailPadMs: 300,
      );
      expect((small?.startMs, small?.endMs), (6400, 9700));
    });
  });

  test('人声检测分析窗口：前后各「最长 + 1 秒」，不超过 15 秒、不越过片头片尾', () {
    expect(untimedVoiceAnalysisWindow(positionMs: 60000, maxMs: 8000), (
      startMs: 51000,
      durationMs: 18000,
    ));
    expect(untimedVoiceAnalysisWindow(positionMs: 60000, maxMs: 15000), (
      startMs: 45000,
      durationMs: 30000,
    ));
    expect(
      untimedVoiceAnalysisWindow(
        positionMs: 3000,
        maxMs: 8000,
        durationMs: 5000,
      ),
      (startMs: 0, durationMs: 5000),
    );
  });

  group('buildUntimedVoicePcmArgs', () {
    test('16 kHz 单声道 WAV、输入端 seek、裁到正在听的音轨', () {
      final List<String> args = buildUntimedVoicePcmArgs(
        source: '/v/a.mkv',
        outputPath: '/tmp/o.wav',
        startMs: 51000,
        durationMs: 18000,
        audioStreamIndex: 1,
        audioStreamCount: 2,
      );
      expect(args.indexOf('-ss'), lessThan(args.indexOf('-i')));
      expect(args, containsAllInOrder(<String>['-ss', '51.000']));
      expect(args, containsAllInOrder(<String>['-t', '18.000']));
      expect(args, containsAllInOrder(<String>['-map', '0:a:1']));
      expect(args, containsAllInOrder(<String>['-ac', '1', '-ar', '16000']));
      expect(args, containsAllInOrder(<String>['-f', 'wav', '/tmp/o.wav']));
    });

    test('音轨序号越界不加 -map（回退默认轨，与制卡裁音同一判据）', () {
      final List<String> args = buildUntimedVoicePcmArgs(
        source: '/v/a.mkv',
        outputPath: '/tmp/o.wav',
        startMs: 0,
        durationMs: 1000,
        audioStreamIndex: 3,
        audioStreamCount: 1,
      );
      expect(args, isNot(contains('-map')));
      expect(args, isNot(contains('-ss')));
    });
  });

  group('decodeWavPcm16', () {
    Uint8List wav(List<int> samples, {bool withList = false}) {
      final BytesBuilder b = BytesBuilder();
      void tag(String s) => b.add(s.codeUnits);
      void u32(int v) => b.add(
        (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
      );
      final ByteData pcm = ByteData(samples.length * 2);
      for (int i = 0; i < samples.length; i++) {
        pcm.setInt16(i * 2, samples[i], Endian.little);
      }
      tag('RIFF');
      u32(0);
      tag('WAVE');
      tag('fmt ');
      u32(16);
      b.add(Uint8List(16));
      if (withList) {
        tag('LIST');
        u32(5);
        b.add(Uint8List(6)); // 奇数长度 + 1 字节对齐
      }
      tag('data');
      u32(samples.length * 2);
      b.add(pcm.buffer.asUint8List());
      return b.toBytes();
    }

    test('按子块跳到 data 块（不假设 44 字节头）', () {
      final Float32List out = decodeWavPcm16(
        wav(<int>[0, 16384, -32768], withList: true),
      );
      expect(out, <double>[0, 0.5, -1]);
    });

    test('不是 WAV / 没有 data 块抛 FormatException', () {
      expect(
        () => decodeWavPcm16(Uint8List.fromList('nope'.codeUnits)),
        throwsFormatException,
      );
      final Uint8List noData = Uint8List.fromList(<int>[
        ...'RIFF'.codeUnits,
        0,
        0,
        0,
        0,
        ...'WAVE'.codeUnits,
      ]);
      expect(() => decodeWavPcm16(noData), throwsFormatException);
    });
  });

  group('视频页接线（源码契约）', () {
    final String page = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    final String mining = File(
      'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
    ).readAsStringSync();
    final String advanced = File(
      'lib/src/pages/implementations/video_fushi/advanced_mining.part.dart',
    ).readAsStringSync();
    final String untimed = File(
      'lib/src/pages/implementations/video_fushi/untimed_audio.part.dart',
    ).readAsStringSync();

    test('画面 OCR 查词拿不到图形字幕锚点时才走无字幕时间', () {
      expect(
        page,
        contains('anchor ?? _beginUntimedSentenceAudio(controller, sentence)'),
      );
      // 只在视频确实没有任何字幕时间时介入：有字幕流 / 有当前句一律走原行为。
      expect(
        untimed,
        contains(
          'controller.miningCues.isNotEmpty || controller.currentCue != null',
        ),
      );
      expect(untimed, contains('UntimedSentenceAudioMode.off) return null'));
    });

    test('制卡 / 覆盖 / 高级制卡都先等人声检测，猜出的区间不再加字幕余量', () {
      expect(
        RegExp(
          r'if \(_untimedSentenceAudioPending\)',
        ).allMatches(mining).length,
        2,
      );
      expect(advanced, contains('if (_untimedSentenceAudioPending)'));
      expect(advanced, contains('originNote: _untimedAudioOriginNote()'));
      expect(
        RegExp(r'untimed != null\)\s*\? mergedRange').hasMatch(mining),
        isTrue,
      );
      expect(mining, contains('? untimed.lookupPositionMs'));
    });
  });
}
