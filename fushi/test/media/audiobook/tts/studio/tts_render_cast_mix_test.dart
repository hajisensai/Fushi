import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_encode.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_mix.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_voices.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:path/path.dart' as p;

TtsPlanSentence _s(int section, int matchStart) => TtsPlanSentence(
  section: section,
  href: 'ch$section.xhtml',
  text: 't$section:$matchStart',
  spokenText: 't$section:$matchStart',
  matchStart: matchStart,
  matchEnd: matchStart + 5,
  studyStart: 0,
  studyEnd: 0,
);

/// [rate] Hz 单声道 16-bit PCM WAV，[tone] 为方波（否则静音）。
Uint8List _wav(int ms, {int rate = 48000, bool tone = true}) {
  final int samples = rate * ms ~/ 1000;
  final ByteData b = ByteData(44 + samples * 2);
  void ascii(int at, String s) {
    for (int i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, samples * 2, Endian.little);
  if (tone) {
    for (int i = 0; i < samples; i++) {
      b.setInt16(44 + i * 2, (i ~/ 20).isEven ? 6000 : -6000, Endian.little);
    }
  }
  return b.buffer.asUint8List();
}

/// 0.6 s 静音、24 kHz 单声道、16 kbps 的 MP3（LAME，带 ID3 与 Info 帧），模拟
/// Edge 一类在线引擎的输出。由完整版 ffmpeg 生成：
/// `-f lavfi -i anullsrc=r=24000:cl=mono -t 0.6 -c:a libmp3lame -b:a 16k`。
final Uint8List _silenceMp3 = base64Decode(
  'SUQzBAAAAAAAIlRTU0UAAAAOAAADTGF2ZjYyLjEuMTAwAAAAAAAAAAAAAAD/84TAAAAAAAAA'
  'AAAASW5mbwAAAA8AAAAbAAAF0AApKSkxMTExOTk5OUJCQkpKSkpSUlJSWlpaY2NjY2tra2tz'
  'c3Nze3t7hISEhIyMjIyUlJScnJycpaWlpa2trbW1tbW9vb29xsbGxs7OztbW1tbe3t7e5+fn'
  '7+/v7/f39/f///8AAAAATGF2YzYyLjMuAAAAAAAAAAAAAAAAJAJAAAAAAAAABdA+n+8UAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAD/8yTEAAAAA0gAAAAATEFNRTMuMTAwVVVVVVVVVVVVVVVV'
  'VVVVVUxBTUUzLjEwMFX/8yTEIwAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxB'
  'TUUzLjEwMFX/8yTERgAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEw'
  'MFX/8yTEaQAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFX/8yTE'
  'jAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFX/8yTErwAAA0gA'
  'AAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFX/8yTE0gAAA0gAAAAAVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFX/8yTE3AAAA0gAAAAAVVVVVVVVVVVV'
  'VVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFX/8yTE3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVV'
  'VVVVVVVVVVVVVUxBTUUzLjEwMFX/8yTE3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
  'VVVVVUxBTUUzLjEwMFX/8yTE3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxB'
  'TUUzLjEwMFX/8yTE3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEw'
  'MFX/8yTE3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFX/8yTE'
  '3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFX/8yTE3AAAA0gA'
  'AAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFX/8yTE3AAAA0gAAAAAVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFX/8yTE3AAAA0gAAAAAVVVVVVVVVVVV'
  'VVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFX/8yTE3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVV'
  'VVVVVVVVVVVVVUxBTUUzLjEwMFX/8yTE3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
  'VVVVVUxBTUUzLjEwMFX/8yTE3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxB'
  'TUUzLjEwMFX/8yTE3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
  'VVX/8yTE3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/8yTE'
  '3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/8yTE3AAAA0gA'
  'AAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/8yTE3AAAA0gAAAAAVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/8yTE3AAAA0gAAAAAVVVVVVVVVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/8yTE3AAAA0gAAAAAVVVVVVVVVVVVVVVVVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVVVVVU=',
);

/// 解码出的 mov（pcm_s16le 单声道）里的样本。
Int16List _movPcmSamples(Uint8List bytes) {
  final ByteData d = ByteData.sublistView(bytes);
  int offset = 0;
  while (offset + 8 <= bytes.length) {
    int size = d.getUint32(offset);
    final String type = String.fromCharCodes(
      bytes.sublist(offset + 4, offset + 8),
    );
    int header = 8;
    if (size == 1) {
      size = d.getUint64(offset + 8);
      header = 16;
    }
    if (type == 'mdat') {
      final int count = (size - header) ~/ 2;
      final Int16List out = Int16List(count);
      for (int i = 0; i < count; i++) {
        out[i] = d.getInt16(offset + header + i * 2, Endian.little);
      }
      return out;
    }
    offset += size;
  }
  throw StateError('no mdat');
}

/// 5 ms 窗 RMS 从静到响的时刻（毫秒）。
List<int> _toneOnsetsMs(Int16List samples, int rate) {
  final int window = rate * 5 ~/ 1000;
  final List<int> onsets = <int>[];
  bool loud = false;
  for (int start = 0; start + window <= samples.length; start += window) {
    double sum = 0;
    for (int i = start; i < start + window; i++) {
      sum += samples[i] * samples[i];
    }
    final bool nowLoud = sum / window > 2000 * 2000;
    if (nowLoud && !loud) onsets.add(start * 1000 ~/ rate);
    loud = nowLoud;
  }
  return onsets;
}

void main() {
  group('选角 → 每句声音', () {
    final List<TtsPlanSentence> plan = <TtsPlanSentence>[
      _s(1, 0),
      _s(1, 10),
      _s(1, 20),
      _s(2, 0),
    ];

    test('台词按角色取声音；旁白 / 没分配声音的角色 / 没标注的句用默认声音', () {
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{
          ttsLineKey(1, 10): const TtsCastLine(
            speaker: 'Alice',
            source: TtsCastSource.llm,
          ),
          ttsLineKey(1, 20): const TtsCastLine(
            speaker: 'Bob',
            source: TtsCastSource.user,
          ),
          ttsLineKey(2, 0): const TtsCastLine(
            speaker: kTtsNarrator,
            source: TtsCastSource.llm,
          ),
        },
        voices: <String, String>{'Alice': 'voice_alice'},
      );
      expect(
        resolveTtsSentencePresets(
          sentences: plan,
          indices: <int>[0, 1, 2, 3],
          cast: cast,
          defaultPresetId: 'narrator',
        ),
        <int, String>{
          0: 'narrator',
          1: 'voice_alice',
          2: 'narrator',
          3: 'narrator',
        },
      );
    });

    test('旁白也能单独分配声音；只解析要求的下标', () {
      final TtsCast cast = TtsCast(
        voices: <String, String>{kTtsNarrator: 'voice_narr'},
      );
      expect(
        resolveTtsSentencePresets(
          sentences: plan,
          indices: <int>[3],
          cast: cast,
          defaultPresetId: 'default',
        ),
        <int, String>{3: 'voice_narr'},
      );
    });

    test('空选角表 = 全书默认声音', () {
      expect(
        resolveTtsSentencePresets(
          sentences: plan,
          indices: <int>[0, 1],
          cast: TtsCast(),
          defaultPresetId: 'd',
        ).values,
        everyElement('d'),
      );
    });
  });

  test('TtsRenderGate：同时持有不超过容量，释放后按先来后到放行', () async {
    final TtsRenderGate gate = TtsRenderGate(2);
    int active = 0;
    int peak = 0;
    final List<int> order = <int>[];
    Future<void> task(int id) async {
      await gate.acquire();
      active++;
      if (active > peak) peak = active;
      order.add(id);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      active--;
      gate.release();
    }

    await Future.wait(<Future<void>>[for (int i = 0; i < 6; i++) task(i)]);
    expect(peak, 2);
    expect(order, <int>[0, 1, 2, 3, 4, 5]);
  });

  group('流参数探测与混合判定', () {
    test('WAV：PCM 16-bit / float / 采样率 / 声道', () {
      expect(
        parseTtsAudioStreamInfo(_wav(10)),
        const TtsAudioStreamInfo(
          codec: 'pcm_s16le',
          sampleRate: 48000,
          channels: 1,
        ),
      );
      final Uint8List f32 = _wav(10, rate: 22050);
      ByteData.sublistView(f32)
        ..setUint16(20, 3, Endian.little)
        ..setUint16(22, 2, Endian.little)
        ..setUint16(34, 32, Endian.little);
      expect(
        parseTtsAudioStreamInfo(f32),
        const TtsAudioStreamInfo(
          codec: 'pcm_f32le',
          sampleRate: 22050,
          channels: 2,
        ),
      );
    });

    test('MP3：跳过 ID3，读第一帧（MPEG2 24 kHz 单声道）', () {
      expect(
        parseTtsAudioStreamInfo(_silenceMp3),
        const TtsAudioStreamInfo(codec: 'mp3', sampleRate: 24000, channels: 1),
      );
      // MPEG1 44.1 kHz 立体声帧头。
      expect(
        parseTtsAudioStreamInfo(
          Uint8List.fromList(<int>[0xFF, 0xFB, 0x90, 0x04, 0, 0, 0, 0]),
        ),
        const TtsAudioStreamInfo(codec: 'mp3', sampleRate: 44100, channels: 2),
      );
      expect(parseTtsAudioStreamInfo(Uint8List(16)), isNull);
    });

    const TtsAudioStreamInfo wav48 = TtsAudioStreamInfo(
      codec: 'pcm_s16le',
      sampleRate: 48000,
      channels: 1,
    );
    const TtsAudioStreamInfo mp324 = TtsAudioStreamInfo(
      codec: 'mp3',
      sampleRate: 24000,
      channels: 1,
    );

    test('全章同参数 → 直接拼；任一不同或认不出 → 需要统一', () {
      expect(ttsStreamsAreUniform(<TtsAudioStreamInfo?>[wav48, wav48]), isTrue);
      expect(ttsStreamsAreUniform(<TtsAudioStreamInfo?>[mp324, mp324]), isTrue);
      expect(
        ttsStreamsAreUniform(<TtsAudioStreamInfo?>[wav48, mp324]),
        isFalse,
      );
      expect(
        ttsStreamsAreUniform(<TtsAudioStreamInfo?>[
          wav48,
          const TtsAudioStreamInfo(
            codec: 'pcm_s16le',
            sampleRate: 24000,
            channels: 1,
          ),
        ]),
        isFalse,
      );
      expect(ttsStreamsAreUniform(<TtsAudioStreamInfo?>[wav48, null]), isFalse);
    });

    test('统一目标：16-bit PCM，最高采样率（≤48k）、最多声道（≤2）', () {
      expect(
        pickTtsUniformTarget(<TtsAudioStreamInfo?>[mp324, wav48, null]),
        wav48,
      );
      expect(
        pickTtsUniformTarget(<TtsAudioStreamInfo?>[
          const TtsAudioStreamInfo(
            codec: 'pcm_s16le',
            sampleRate: 96000,
            channels: 6,
          ),
        ]),
        const TtsAudioStreamInfo(
          codec: 'pcm_s16le',
          sampleRate: 48000,
          channels: 2,
        ),
      );
      expect(
        pickTtsUniformTarget(<TtsAudioStreamInfo?>[null]),
        const TtsAudioStreamInfo(
          codec: 'pcm_s16le',
          sampleRate: 24000,
          channels: 1,
        ),
      );
    });

    test('转码参数：PCM 装 mov（ffmpeg-min 没有 wav 封装器）', () {
      final List<String> args = buildTtsUniformTranscodeArgs(
        inputPath: 'in.audio',
        outputPath: 'out.mov',
        target: wav48,
      );
      expect(
        args,
        containsAllInOrder(<String>['-ar', '48000', '-c:a', 'pcm_s16le']),
      );
      expect(args.sublist(args.length - 3), <String>['-f', 'mov', 'out.mov']);
    });
  });

  // 真 ffmpeg 冒烟：只在显式给了 FUSHI_FFMPEG（如 third_party/ffmpeg-min）时跑。
  final String? ffmpeg = Platform.environment['FUSHI_FFMPEG'];
  test('ffmpeg 冒烟：48 kHz WAV 台词与 24 kHz MP3 混排一章，句首时刻不漂', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'tts_render_mix',
    );
    addTearDown(() => tmp.delete(recursive: true));
    Future<String> put(String name, Uint8List bytes) async {
      final File f = File(p.join(tmp.path, 'cache', '$name.audio'));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes);
      return f.path;
    }

    final String a = await put('a', _wav(1000));
    final String b = await put('b', _wav(800));
    final String c = await put('c', _wav(500));
    final String m = await put('m', _silenceMp3);
    // MP3 的缓存时长故意给偏（引擎探测按帧计会偏长）：混合章必须改用实测值。
    final List<({String key, String path, int durationMs})> sentences =
        <({String key, String path, int durationMs})>[
          (key: 'a', path: a, durationMs: 1000),
          (key: 'm', path: m, durationMs: 650),
          (key: 'b', path: b, durationMs: 800),
          (key: 'm', path: m, durationMs: 650),
          (key: 'c', path: c, durationMs: 500),
        ];
    final List<String> failures = <String>[];
    final Directory mixDir = Directory(p.join(tmp.path, 'work', 'mix'));
    final ({
      List<({String path, int durationMs})> entries,
      TtsAudioStreamInfo target,
    })
    prepared = await prepareTtsUniformEntries(
      backend: const CliFfmpegBackend(),
      sentences: sentences,
      mixDir: mixDir,
      cancel: TtsRenderCancelToken(),
      onFailure: failures.add,
    );
    final List<({String path, int durationMs})> entries = prepared.entries;
    expect(prepared.target.sampleRate, 48000);
    expect(failures, isEmpty);
    // 合规的 48 kHz WAV 原样拼，MP3 只转一次、两处复用同一个中间文件。
    expect(entries[0].path, a);
    expect(entries[2].path, b);
    expect(entries[1].path, endsWith('.mov'));
    expect(entries[3].path, entries[1].path);
    expect(mixDir.listSync(), hasLength(1));
    expect((entries[1].durationMs - 600).abs(), lessThanOrEqualTo(30));

    final String out = p.join(tmp.path, 'work', 'tts_000.m4a');
    await encodeTtsChapterAudio(
      backend: const CliFfmpegBackend(),
      entries: entries,
      outputPath: out,
      cancel: TtsRenderCancelToken(),
      onFailure: failures.add,
    );
    expect(failures, isEmpty);

    // 解码回 PCM，找每段方波的起点，与按实测时长累加的 cue 起点比。
    final String decoded = p.join(tmp.path, 'decoded.mov');
    final FfmpegRunResult result = await const CliFfmpegBackend().run(<String>[
      '-y',
      '-i',
      out,
      '-ac',
      '1',
      '-ar',
      '48000',
      '-c:a',
      'pcm_s16le',
      '-f',
      'mov',
      decoded,
    ], const Duration(seconds: 60));
    expect(result.isSuccess, isTrue, reason: result.failureSummary);
    final List<int> onsets = _toneOnsetsMs(
      _movPcmSamples(await File(decoded).readAsBytes()),
      48000,
    );
    final List<int> starts = <int>[0];
    int cursor = 0;
    for (final ({String path, int durationMs}) e in entries) {
      cursor += e.durationMs;
      starts.add(cursor);
    }
    final List<int> expectedOnsets = <int>[starts[0], starts[2], starts[4]];
    expect(onsets, hasLength(3), reason: 'onsets=$onsets');
    for (int i = 0; i < 3; i++) {
      expect(
        (onsets[i] - expectedOnsets[i]).abs(),
        lessThanOrEqualTo(25),
        reason: 'onsets=$onsets expected=$expectedOnsets',
      );
    }
    final int? total = await readMovTrackDurationMs(out);
    expect(total, isNotNull);
    expect((total! - cursor).abs(), lessThan(120));
  }, skip: ffmpeg == null || ffmpeg.isEmpty ? 'FUSHI_FFMPEG not set' : false);
}
