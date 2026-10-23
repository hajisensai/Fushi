import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:fushi_engine/asr/cloud_whisper_transcription_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// 云端 Whisper 转录（反馈 fvrYPia3kW ①）：wire 形状、应答解析、静音切点与整条
/// 管线产物（单时间轴 SRT + 行数一致的 token sidecar、分片缓存续传）。
void main() {
  AiProviderConfig groq({
    AiWireProtocol protocol = AiWireProtocol.openAiCompatible,
  }) => AiProviderConfig(
    id: 'groq-1',
    presetId: 'groq',
    name: 'Groq',
    baseUrl: Uri.parse('https://api.groq.com/openai/v1'),
    apiKey: 'gsk_test',
    model: 'whisper-large-v3',
    protocol: protocol,
  );

  group('AiChatClient.transcribeAudio', () {
    test(
      'POSTs multipart verbose_json with word+segment granularity',
      () async {
        late http.Request seen;
        final AiChatClient client = AiChatClient(
          rateLimiter: AiRateLimiter(),
          client: MockClient((http.Request request) async {
            seen = request;
            return http.Response(
              jsonEncode(<String, Object?>{
                'text': 'ok',
                'segments': <Object?>[],
              }),
              200,
            );
          }),
        );
        addTearDown(client.close);
        final Map<Object?, Object?> body = await client.transcribeAudio(
          provider: groq(),
          audioBytes: <int>[1, 2, 3, 4],
          fileName: 'chunk.webm',
          contentType: 'audio/webm',
          language: 'ja',
        );
        expect(body['text'], 'ok');
        expect(
          seen.url.toString(),
          'https://api.groq.com/openai/v1/audio/transcriptions',
        );
        expect(seen.headers['authorization'], 'Bearer gsk_test');
        final String contentType = seen.headers['content-type']!;
        expect(contentType, startsWith('multipart/form-data; boundary='));
        final String raw = latin1.decode(seen.bodyBytes);
        expect(raw, contains('name="model"\r\n\r\nwhisper-large-v3\r\n'));
        expect(raw, contains('name="response_format"\r\n\r\nverbose_json\r\n'));
        expect(
          'name="timestamp_granularities[]"'.allMatches(raw).length,
          2,
          reason: 'segment and word must both be requested (array form)',
        );
        expect(raw, contains('name="language"\r\n\r\nja\r\n'));
        expect(raw, contains('filename="chunk.webm"'));
        expect(raw, contains('Content-Type: audio/webm'));
        final String boundary = contentType.split('boundary=').last;
        expect(raw.trimRight(), endsWith('--$boundary--'));
      },
    );

    test(
      'non OpenAI-compatible protocol is rejected before any request',
      () async {
        int calls = 0;
        final AiChatClient client = AiChatClient(
          rateLimiter: AiRateLimiter(),
          client: MockClient((http.Request request) async {
            calls++;
            return http.Response('{}', 200);
          }),
        );
        addTearDown(client.close);
        await expectLater(
          client.transcribeAudio(
            provider: groq(protocol: AiWireProtocol.anthropicMessages),
            audioBytes: <int>[1],
            fileName: 'a.webm',
            contentType: 'audio/webm',
          ),
          throwsA(
            isA<AiChatFailure>().having(
              (AiChatFailure f) => f.message,
              'message',
              kAiTranscriptionUnsupportedProtocol,
            ),
          ),
        );
        expect(calls, 0);
      },
    );

    test('401 surfaces as the redacted unauthorized code', () async {
      final AiChatClient client = AiChatClient(
        rateLimiter: AiRateLimiter(),
        client: MockClient(
          (http.Request request) async =>
              http.Response('{"error":"bad key"}', 401),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.transcribeAudio(
          provider: groq(),
          audioBytes: <int>[1],
          fileName: 'a.webm',
          contentType: 'audio/webm',
        ),
        throwsA(
          isA<AiChatFailure>().having(
            (AiChatFailure f) => f.message,
            'message',
            'unauthorized',
          ),
        ),
      );
    });
  });

  group('whisperVerboseJsonToSegments', () {
    test(
      'folds chunk offset, keeps punctuation from segment text, times from words',
      () {
        final List<AsrTranscribedSegment> segs = whisperVerboseJsonToSegments(
          <String, Object?>{
            'segments': <Object?>[
              <String, Object?>{
                'start': 1.0,
                'end': 3.0,
                'text': ' 今日は、いい天気。',
                'no_speech_prob': 0.01,
                'avg_logprob': -0.2,
              },
            ],
            // OpenAI / Groq 的逐词时间在顶层且不带标点。
            'words': <Object?>[
              <String, Object?>{'word': '今日', 'start': 1.0, 'end': 1.4},
              <String, Object?>{'word': 'は', 'start': 1.4, 'end': 1.6},
              <String, Object?>{'word': 'いい', 'start': 2.0, 'end': 2.3},
              <String, Object?>{'word': '天気', 'start': 2.3, 'end': 2.9},
            ],
          },
          audioFileIndex: 0,
          chunkStartMs: 600000,
          chunkEndMs: 1200000,
        );
        expect(segs, hasLength(1));
        final AsrTranscribedSegment s = segs.single;
        expect(s.startMs, 601000);
        expect(s.endMs, 603000);
        expect(s.tokens.join(), '今日は、いい天気。');
        expect(s.tokens.length, s.tokenTimesMs.length);
        // 「い」(いい) 的起点来自词时间 2.0 s，而不是线性分配。
        final int ii = s.tokens.indexOf('い');
        expect(s.tokenTimesMs[ii], 602000);
        for (int i = 1; i < s.tokenTimesMs.length; i++) {
          expect(
            s.tokenTimesMs[i],
            greaterThanOrEqualTo(s.tokenTimesMs[i - 1]),
          );
        }
      },
    );

    test('drops whisper silence hallucinations and empty segments', () {
      final List<AsrTranscribedSegment> segs = whisperVerboseJsonToSegments(
        <String, Object?>{
          'segments': <Object?>[
            <String, Object?>{
              'start': 0,
              'end': 5,
              'text': 'ご視聴ありがとうございました',
              'no_speech_prob': 0.9,
              'avg_logprob': -1.5,
            },
            <String, Object?>{'start': 5, 'end': 6, 'text': '  '},
            <String, Object?>{'start': 6, 'end': 7, 'text': 'はい'},
          ],
        },
        audioFileIndex: 0,
        chunkStartMs: 0,
      );
      expect(segs.map((AsrTranscribedSegment s) => s.tokens.join()), <String>[
        'はい',
      ]);
    });
  });

  test('quietestPointMs finds the silent stretch', () {
    // 3 s：0–1 s 响、1.4–1.8 s 静、其余响。
    final Float32List samples = Float32List(3 * kAsrSampleRate);
    for (int i = 0; i < samples.length; i++) {
      final double t = i / kAsrSampleRate;
      samples[i] = (t >= 1.4 && t < 1.8) ? 0 : 0.5;
    }
    final int? ms = quietestPointMs(samples);
    expect(ms, isNotNull);
    expect(ms!, inInclusiveRange(1400, 1800));
    expect(quietestPointMs(Float32List(100)), isNull);
  });

  group('CloudWhisperTranscriptionService', () {
    late Directory root;
    late File audio;
    setUp(() {
      root = Directory.systemTemp.createTempSync('fushi_cloud_asr_test_');
      audio = File(p.join(root.path, 'book.mp3'))
        ..writeAsBytesSync(<int>[0, 1, 2]);
    });
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test(
      'chunked upload → single-timeline SRT + matching sidecar; cache resumes',
      () async {
        // 25 s 文件、10 s 名义分片、4 s 找切点 → 三片。
        final _FakeFfmpeg ffmpeg = _FakeFfmpeg(durationSeconds: 25);
        int uploads = 0;
        AiChatClient makeClient() => AiChatClient(
          rateLimiter: AiRateLimiter(),
          client: MockClient((http.Request request) async {
            uploads++;
            // 正文含日文：按 UTF-8 字节回（http.Response 的字符串构造默认 latin1）。
            return http.Response.bytes(
              utf8.encode(
                jsonEncode(<String, Object?>{
                  'segments': <Object?>[
                    <String, Object?>{'start': 0.5, 'end': 2.0, 'text': 'はい。'},
                    <String, Object?>{'start': 3.0, 'end': 4.0, 'text': 'そうです'},
                  ],
                }),
              ),
              200,
            );
          }),
        );
        final CloudWhisperTranscriptionService service =
            CloudWhisperTranscriptionService(
              resolveProvider: () => groq(),
              ffmpeg: ffmpeg,
              clientFactory: makeClient,
              jobsRoot: () async => Directory(p.join(root.path, 'jobs')),
              chunkMs: 10000,
              cutSearchMs: 4000,
            );
        final AsrRunningTranscription running = await service.start(
          audioPaths: <String>[audio.path],
          language: AsrLanguage.japanese,
          variant: AsrEncoderVariant.int8,
          preference: AsrAccelerationPreference.auto,
        );
        final List<AsrTranscribeEvent> events = await running.run().toList();
        await running.dispose();
        final AsrTranscribeFinishedEvent done = events
            .whereType<AsrTranscribeFinishedEvent>()
            .single;
        expect(uploads, 3);
        expect(ffmpeg.encodes, 3);
        final String srt = File(done.result.srtPath).readAsStringSync();
        final List<String> cueBlocks = srt
            .trim()
            .split(RegExp(r'\n\n'))
            .where((String b) => b.trim().isNotEmpty)
            .toList();
        expect(cueBlocks, hasLength(6), reason: 'two segments per chunk');
        // 第二片的「はい。」落在第二片起点之后（单时间轴、不回到 0）。
        expect(srt, contains('はい。'));
        final File sidecar = File(
          p.join(p.dirname(done.result.srtPath), AsrJobFiles.cueTokens),
        );
        final List<AsrCueTokenTiming>? rows = parseAsrCueTokenTimings(
          sidecar.readAsStringSync(),
        );
        expect(rows, isNotNull);
        expect(rows, hasLength(cueBlocks.length));
        expect(
          await service.finishedSrtPath(<String>[
            audio.path,
          ], AsrLanguage.japanese),
          done.result.srtPath,
        );

        // 已完成的分片应答都在缓存里：删掉产物重跑一遍，不再上传。
        File(done.result.srtPath).deleteSync();
        final AsrRunningTranscription again = await service.start(
          audioPaths: <String>[audio.path],
          language: AsrLanguage.japanese,
          variant: AsrEncoderVariant.int8,
          preference: AsrAccelerationPreference.auto,
        );
        await again.run().drain<void>();
        await again.dispose();
        expect(uploads, 3, reason: 'cached chunk replies are reused');
      },
    );

    test(
      'no provider assigned → start fails with provider_not_configured',
      () async {
        final CloudWhisperTranscriptionService service =
            CloudWhisperTranscriptionService(
              resolveProvider: () => null,
              ffmpeg: _FakeFfmpeg(durationSeconds: 5),
              jobsRoot: () async => Directory(p.join(root.path, 'jobs')),
            );
        await expectLater(
          service.start(
            audioPaths: <String>[audio.path],
            language: AsrLanguage.japanese,
            variant: AsrEncoderVariant.int8,
            preference: AsrAccelerationPreference.auto,
          ),
          throwsA(
            isA<AiChatFailure>().having(
              (AiChatFailure f) => f.message,
              'message',
              'provider_not_configured',
            ),
          ),
        );
      },
    );
  });
}

/// ffprobe 回固定时长；ffmpeg 把最后一个参数（输出路径）写成一个小文件。
class _FakeFfmpeg implements FfmpegBackend {
  _FakeFfmpeg({required this.durationSeconds});

  final int durationSeconds;
  int encodes = 0;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    final String out = args.last;
    if (args.contains('libopus')) {
      encodes++;
      File(out).writeAsBytesSync(<int>[1, 2, 3]);
    } else if (args.contains('s16le')) {
      // 静音切点窗口：给 4 s 的 PCM，中间 2 s 处有一段静音。
      final ByteData data = ByteData(4 * kAsrSampleRate * 2);
      for (int i = 0; i < 4 * kAsrSampleRate; i++) {
        final double t = i / kAsrSampleRate;
        data.setInt16(i * 2, (t >= 2.0 && t < 2.5) ? 0 : 8000, Endian.little);
      }
      File(out).writeAsBytesSync(data.buffer.asUint8List());
    }
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      FfmpegRunResult(
        returnCode: 0,
        output: jsonEncode(<String, Object?>{
          'format': <String, Object?>{'duration': '$durationSeconds.000'},
        }),
      );
}
