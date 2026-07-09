import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// TODO-1314（B5）：audio-only DASH 流「range 分片下载物化 -> 本地裁」的守卫。
class _FakeRepo implements BaseAnkiRepository {
  AnkiMiningContext? minedContext;

  @override
  Future<MineOutcome> mineEntry(
      {required String rawPayloadJson,
      required AnkiMiningContext context}) async {
    minedContext = context;
    return const MineOutcome.success(noteId: 1);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<String?> _okFrame(
        {required String inputPath,
        required String outputPath,
        double atSeconds = 10.0,
        FfmpegFailureReporter? onFailure}) async =>
    outputPath;
Future<String?> _okGif(
        {required String inputPath,
        required int startMs,
        required int endMs,
        required String outputPath,
        int fps = 8,
        int width = 320,
        FfmpegFailureReporter? onFailure}) async =>
    outputPath;

void main() {
  group('buildGoogleVideoRangeUrl', () {
    test('appends range query param preserving existing params', () {
      final String url = buildGoogleVideoRangeUrl(
          'https://r1.googlevideo.com/videoplayback?itag=251&expire=999',
          0,
          4194303);
      final Uri u = Uri.parse(url);
      expect(u.queryParameters['itag'], '251');
      expect(u.queryParameters['expire'], '999');
      expect(u.queryParameters['range'], '0-4194303');
    });

    test('overwrites an existing range param (idempotent per chunk)', () {
      final String url =
          buildGoogleVideoRangeUrl('https://g/v?range=0-10&x=1', 20, 39);
      final Uri u = Uri.parse(url);
      expect(u.queryParameters['range'], '20-39');
      expect(u.queryParameters['x'], '1');
    });
  });

  group('materializeRemoteAudioViaRangeDownload', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('yt_audio_range_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('assembles sequential range chunks into one local file', () async {
      final List<int> whole = List<int>.generate(20, (int i) => i);
      final MockClient client = MockClient((http.Request req) async {
        final List<String> parts = req.url.queryParameters['range']!.split('-');
        final int start = int.parse(parts[0]);
        final int end = int.parse(parts[1]);
        if (start >= whole.length) return http.Response.bytes(<int>[], 416);
        final int stop = (end + 1) > whole.length ? whole.length : (end + 1);
        return http.Response.bytes(whole.sublist(start, stop), 200);
      });
      final String out = '${tmp.path}/audio.dat';
      final String? result = await materializeRemoteAudioViaRangeDownload(
        audioUrl: 'https://r1.googlevideo.com/videoplayback?itag=251',
        outputPath: out,
        httpClient: client,
        chunkBytes: 8,
      );
      expect(result, out);
      expect(File(out).readAsBytesSync(), Uint8List.fromList(whole));
    });

    test('first chunk non-2xx -> null and no partial file', () async {
      final MockClient client =
          MockClient((http.Request req) async => http.Response('no', 403));
      final String out = '${tmp.path}/audio.dat';
      final String? result = await materializeRemoteAudioViaRangeDownload(
        audioUrl: 'https://g/v?itag=251',
        outputPath: out,
        httpClient: client,
        chunkBytes: 8,
      );
      expect(result, isNull);
      expect(File(out).existsSync(), isFalse);
    });

    test('non-http input returns null without touching client', () async {
      bool hit = false;
      final MockClient client = MockClient((http.Request req) async {
        hit = true;
        return http.Response.bytes(<int>[1], 200);
      });
      final String? result = await materializeRemoteAudioViaRangeDownload(
        audioUrl: '/local/file.m4a',
        outputPath: '${tmp.path}/audio.dat',
        httpClient: client,
      );
      expect(result, isNull);
      expect(hit, isFalse);
    });

    test('exact-multiple stream stops on 416 (no infinite loop)', () async {
      final List<int> whole = List<int>.generate(8, (int i) => i + 1);
      int calls = 0;
      final MockClient client = MockClient((http.Request req) async {
        calls++;
        final int start =
            int.parse(req.url.queryParameters['range']!.split('-')[0]);
        if (start >= whole.length) return http.Response.bytes(<int>[], 416);
        return http.Response.bytes(whole, 200);
      });
      final String out = '${tmp.path}/audio.dat';
      final String? result = await materializeRemoteAudioViaRangeDownload(
        audioUrl: 'https://g/v?itag=140',
        outputPath: out,
        httpClient: client,
        chunkBytes: 8,
      );
      expect(result, out);
      expect(File(out).readAsBytesSync(), Uint8List.fromList(whole));
      expect(calls, 2);
    });
  });

  group('ImmersionMiningEngine audio routing (TODO-1314 B5)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('immersion_b5_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('muxed source (audioSource null) does NOT materialize', () async {
      bool materialized = false;
      String? audioInput;
      Future<String?> capAudio(
          {required String inputPath,
          required int startMs,
          required int endMs,
          required String outputPath,
          int? audioStreamIndex,
          int? audioStreamCount,
          FfmpegFailureReporter? onFailure,
          int audioChannels = 1,
          String audioBitrate = '64k'}) async {
        audioInput = inputPath;
        return outputPath;
      }

      final engine = ImmersionMiningEngine(
        gifExtractor: _okGif,
        audioExtractor: capAudio,
        frameExtractor: _okFrame,
        audioMaterializer: (
            {required String audioUrl,
            required String outputPath,
            FfmpegFailureReporter? onFailure}) async {
          materialized = true;
          return '${tmp.path}/should_not_be_used';
        },
      );
      await engine.mine(
          const ImmersionMiningRequest(
              fields: {'expression': 'x'},
              mediaSource: 'https://muxed.example/v',
              clipStartMs: 0,
              clipEndMs: 2000,
              sentence: 's'),
          compression: MiningMediaCompression.compressed,
          tempDir: tmp.path,
          repo: _FakeRepo());
      expect(materialized, isFalse);
      expect(audioInput, 'https://muxed.example/v');
    });

    test('materialize failure falls back to cutting the URL directly',
        () async {
      String? audioInput;
      Future<String?> capAudio(
          {required String inputPath,
          required int startMs,
          required int endMs,
          required String outputPath,
          int? audioStreamIndex,
          int? audioStreamCount,
          FfmpegFailureReporter? onFailure,
          int audioChannels = 1,
          String audioBitrate = '64k'}) async {
        audioInput = inputPath;
        return outputPath;
      }

      final engine = ImmersionMiningEngine(
        gifExtractor: _okGif,
        audioExtractor: capAudio,
        frameExtractor: _okFrame,
        audioMaterializer: (
                {required String audioUrl,
                required String outputPath,
                FfmpegFailureReporter? onFailure}) async =>
            null,
      );
      await engine.mine(
          const ImmersionMiningRequest(
              fields: {'expression': 'x'},
              mediaSource: 'https://video-only.example/v',
              audioSource: 'https://audio-only.example/a',
              clipStartMs: 0,
              clipEndMs: 2000,
              sentence: 's'),
          compression: MiningMediaCompression.compressed,
          tempDir: tmp.path,
          repo: _FakeRepo());
      expect(audioInput, 'https://audio-only.example/a');
    });
  });
}
