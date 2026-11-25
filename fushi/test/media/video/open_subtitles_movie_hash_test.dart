// BUG-5455：OpenSubtitles movie hash 的最高位为 1 时被拼成带负号的串，服务端回
// `400 moviehash must be 16 hex characters`，整次 OpenSubtitles 搜索作废；registry
// 也从不把来源失败写进日志，界面只剩一句不点名来源的「字幕搜索失败（HTTP 400）」。
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

/// OpenSubtitles 服务端对 `moviehash` 的校验（2026-11-25 实测：不满足时不论有没有
/// Api-Key 都回 400 `Request parameters do not make sense: moviehash must be 16 hex
/// characters`）。
final RegExp _serverMovieHashRule = RegExp(r'^[0-9a-f]{16}$');

/// 与 Dart int 表示无关的参照实现：按无符号 64 位逐字累加。
String _referenceMovieHash(Uint8List bytes) {
  const int chunk = 64 * 1024;
  final BigInt modulus = BigInt.one << 64;
  BigInt sum = BigInt.from(bytes.length);
  for (final int start in <int>[0, bytes.length - chunk]) {
    for (int offset = 0; offset < chunk; offset += 8) {
      BigInt word = BigInt.zero;
      for (int i = 7; i >= 0; i--) {
        word = (word << 8) | BigInt.from(bytes[start + offset + i]);
      }
      sum = (sum + word) % modulus;
    }
  }
  return sum.toRadixString(16).padLeft(16, '0');
}

void main() {
  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('os_movie_hash_test_');
  });
  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<File> writeVideo(Uint8List bytes) async {
    final File file = File('${tempDir.path}${Platform.pathSeparator}v.mkv');
    await file.writeAsBytes(bytes);
    return file;
  }

  group('formatOpenSubtitlesMovieHash', () {
    test('最高位为 1 时按无符号拼，不带负号', () {
      expect(formatOpenSubtitlesMovieHash(-1), 'ffffffffffffffff');
      expect(
        formatOpenSubtitlesMovieHash(-0x7fffffffffffffff - 1),
        '8000000000000000',
      );
      expect(
        formatOpenSubtitlesMovieHash(-0x0123456789abcdef),
        'fedcba9876543211',
      );
    });

    test('小值补足 16 位', () {
      expect(formatOpenSubtitlesMovieHash(0), '0000000000000000');
      expect(formatOpenSubtitlesMovieHash(0x20000), '0000000000020000');
      expect(
        formatOpenSubtitlesMovieHash(0x0123456789abcdef),
        '0123456789abcdef',
      );
    });
  });

  group('computeOpenSubtitlesMovieHash', () {
    test('累加结果最高位为 1 的文件得到 16 位十六进制（旧实现是 -7fff…）', () async {
      final Uint8List bytes = Uint8List(128 * 1024);
      // 首块第一个 little-endian uint64 = 0x8000000000000000。
      bytes[7] = 0x80;
      final File file = await writeVideo(bytes);

      final String? hash = await computeOpenSubtitlesMovieHash(file.path);

      expect(hash, '8000000000020000');
      expect(hash, matches(_serverMovieHashRule));
      expect(hash, _referenceMovieHash(bytes));
    });

    test('全 0xff 内容（每个字都是 2^64-1）与参照实现一致', () async {
      final Uint8List bytes = Uint8List(200 * 1024)
        ..fillRange(0, 200 * 1024, 0xff);
      final File file = await writeVideo(bytes);

      final String? hash = await computeOpenSubtitlesMovieHash(file.path);

      expect(hash, matches(_serverMovieHashRule));
      expect(hash, _referenceMovieHash(bytes));
    });

    test('伪随机内容与参照实现逐位一致', () async {
      final Uint8List bytes = Uint8List(300 * 1024 + 5);
      int state = 0x12345678;
      for (int i = 0; i < bytes.length; i++) {
        state = (state * 1103515245 + 12345) & 0x7fffffff;
        bytes[i] = state >> 16 & 0xff;
      }
      final File file = await writeVideo(bytes);

      final String? hash = await computeOpenSubtitlesMovieHash(file.path);

      expect(hash, matches(_serverMovieHashRule));
      expect(hash, _referenceMovieHash(bytes));
    });
  });

  test('hash 档真实请求通过服务端校验，不再以 400 作废整次搜索', () async {
    final Uint8List bytes = Uint8List(128 * 1024);
    bytes[7] = 0x80;
    final File file = await writeVideo(bytes);
    final String? hash = await computeOpenSubtitlesMovieHash(file.path);
    final List<String?> sentHashes = <String?>[];
    final OpenSubtitlesClient client = OpenSubtitlesClient(
      config: OpenSubtitlesConfig(
        apiKey: 'api-secret',
        baseUrl: Uri.parse('http://localhost/api/v1'),
      ),
      client: MockClient((http.Request request) async {
        final String? sent = request.url.queryParameters['moviehash'];
        sentHashes.add(sent);
        if (sent != null && !_serverMovieHashRule.hasMatch(sent)) {
          return http.Response(
            'Request parameters do not make sense: '
            'moviehash must be 16 hex characters',
            400,
          );
        }
        return http.Response('{"data":[]}', 200);
      }),
      closesClient: false,
    );

    final ProviderBatchResult<VideoSubtitleCandidate> result = await client
        .search(
          VideoSubtitleSearchRequest(
            query: '凶乱令嬢ニア・リストン',
            episode: 8,
            fingerprint: LocalVideoFingerprint(
              fileSize: bytes.length,
              openSubtitlesMovieHash: hash,
            ),
          ),
        );

    expect(result.failures, isEmpty);
    expect(sentHashes.first, '8000000000020000');
    expect(sentHashes, hasLength(2), reason: 'hash 档零命中后照常落到标题档');
  });

  group('VideoSubtitleRegistry 失败诊断', () {
    late EngineLogSink originalSink;
    late _CapturingSink sink;
    setUp(() {
      originalSink = engineLog;
      sink = _CapturingSink();
      engineLog = sink;
    });
    tearDown(() {
      engineLog = originalSink;
    });

    test('来源失败逐条进诊断日志，带来源与状态码', () async {
      final VideoSubtitleRegistry registry =
          VideoSubtitleRegistry(<VideoSubtitleProvider>[
            _FakeProvider(
              'jimaku',
              ProviderBatchResult<VideoSubtitleCandidate>.success(
                const <VideoSubtitleCandidate>[],
              ),
            ),
            _FakeProvider(
              'opensubtitles',
              ProviderBatchResult<VideoSubtitleCandidate>.failure(
                const ExternalProviderFailure(
                  providerId: 'opensubtitles',
                  operation: 'search',
                  kind: ExternalProviderFailureKind.unavailable,
                  message: 'OpenSubtitles returned HTTP 400',
                  statusCode: 400,
                ),
              ),
            ),
            _FakeProvider.throwing('subdl', StateError('boom')),
          ]);

      final ProviderBatchResult<VideoSubtitleCandidate> result = await registry
          .search(VideoSubtitleSearchRequest(query: 'x'));

      expect(result.failures, hasLength(2));
      expect(
        sink.diagnostics.map((({String source, String info}) e) => e.source),
        everyElement('VideoSubtitleRegistry.search'),
      );
      final List<String> infos = <String>[
        for (final ({String source, String info}) e in sink.diagnostics) e.info,
      ];
      expect(infos, hasLength(2));
      expect(
        infos,
        contains(
          allOf(contains('provider=opensubtitles'), contains('status=400')),
        ),
      );
      expect(infos, contains(contains('provider=subdl')));
      expect(infos, isNot(contains(contains('provider=jimaku'))));
    });

    test('全部成功时不写日志', () async {
      final VideoSubtitleRegistry registry =
          VideoSubtitleRegistry(<VideoSubtitleProvider>[
            _FakeProvider(
              'jimaku',
              ProviderBatchResult<VideoSubtitleCandidate>.success(
                const <VideoSubtitleCandidate>[],
              ),
            ),
          ]);

      await registry.search(VideoSubtitleSearchRequest(query: 'x'));

      expect(sink.diagnostics, isEmpty);
    });
  });
}

class _CapturingSink implements EngineLogSink {
  final List<({String source, String info})> diagnostics =
      <({String source, String info})>[];

  @override
  void log(String source, Object error, [StackTrace? stack]) {}

  @override
  void logDiagnostic(String source, Object info) {
    diagnostics.add((source: source, info: info.toString()));
  }

  @override
  void logFatal(String source, Object error, [StackTrace? stack]) {}
}

class _FakeProvider implements VideoSubtitleProvider {
  _FakeProvider(this.id, ProviderBatchResult<VideoSubtitleCandidate> result)
    : _result = result,
      _error = null;

  _FakeProvider.throwing(this.id, Error error) : _result = null, _error = error;

  @override
  final String id;
  final ProviderBatchResult<VideoSubtitleCandidate>? _result;
  final Error? _error;

  @override
  int get priority => 0;

  @override
  bool get allowsFreeProbeDownload => false;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    final Error? error = _error;
    if (error != null) throw error;
    return _result!;
  }

  @override
  Future<VideoSubtitleDownload> download(VideoSubtitleCandidate candidate) =>
      throw UnimplementedError();

  @override
  void close() {}
}
