import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('VideoMetadataHttpClient', () {
    test('429 honors Retry-After and then succeeds', () async {
      int requests = 0;
      final List<Duration> delays = <Duration>[];
      final VideoMetadataHttpClient transport = VideoMetadataHttpClient(
        client: MockClient((http.Request request) async {
          requests++;
          if (requests == 1) {
            return http.Response(
              'limited',
              429,
              headers: <String, String>{'retry-after': '2'},
            );
          }
          return http.Response.bytes(utf8.encode('{"ok":true}'), 200);
        }),
        sleep: (Duration duration) async => delays.add(duration),
      );

      final VideoMetadataHttpResponse response = await transport.get(
        Uri.parse('https://example.invalid/value'),
        operation: 'fixture',
      );

      expect(response.decodeJsonObject(operation: 'fixture')['ok'], isTrue);
      expect(requests, 2);
      expect(delays, <Duration>[const Duration(seconds: 2)]);
    });

    test('Retry-After cannot suspend a source task beyond the configured cap',
        () async {
      int requests = 0;
      final List<Duration> delays = <Duration>[];
      final VideoMetadataHttpClient transport = VideoMetadataHttpClient(
        client: MockClient((http.Request request) async {
          requests++;
          if (requests == 1) {
            return http.Response(
              'limited',
              429,
              headers: <String, String>{'retry-after': '3600'},
            );
          }
          return http.Response('{}', 200);
        }),
        maxRetryDelay: const Duration(seconds: 5),
        sleep: (Duration duration) async => delays.add(duration),
      );

      await transport.get(
        Uri.parse('https://example.invalid/value'),
        operation: 'fixture',
      );

      expect(delays, <Duration>[const Duration(seconds: 5)]);
    });

    test('5xx uses bounded backoff and stops after maxAttempts', () async {
      int requests = 0;
      final List<Duration> delays = <Duration>[];
      final VideoMetadataHttpClient transport = VideoMetadataHttpClient(
        client: MockClient((http.Request request) async {
          requests++;
          return http.Response('unavailable', 503);
        }),
        maxAttempts: 3,
        baseBackoff: const Duration(milliseconds: 10),
        sleep: (Duration duration) async => delays.add(duration),
      );

      await expectLater(
        transport.get(
          Uri.parse('https://example.invalid/value'),
          operation: 'fixture',
        ),
        throwsA(
          isA<VideoMetadataNetworkException>().having(
            (VideoMetadataNetworkException error) => error.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
      expect(requests, 3);
      expect(delays, <Duration>[
        const Duration(milliseconds: 10),
        const Duration(milliseconds: 20),
      ]);
    });

    test('successful response is cached without sharing decoded objects',
        () async {
      int requests = 0;
      final VideoMetadataHttpClient transport = VideoMetadataHttpClient(
        client: MockClient((http.Request request) async {
          requests++;
          return http.Response('{"items":[1]}', 200);
        }),
      );

      final VideoMetadataHttpResponse first = await transport.get(
        Uri.parse('https://example.invalid/value'),
        operation: 'fixture',
        cacheKey: 'fixture:value',
      );
      final Map<String, Object?> firstJson =
          first.decodeJsonObject(operation: 'fixture');
      (firstJson['items']! as List<Object?>).add(2);
      final VideoMetadataHttpResponse second = await transport.get(
        Uri.parse('https://example.invalid/value'),
        operation: 'fixture',
        cacheKey: 'fixture:value',
      );

      expect(requests, 1);
      expect(
        second.decodeJsonObject(operation: 'fixture')['items'],
        <Object?>[1],
      );
    });

    test('non-retryable status fails immediately', () async {
      int requests = 0;
      final VideoMetadataHttpClient transport = VideoMetadataHttpClient(
        client: MockClient((http.Request request) async {
          requests++;
          return http.Response('unauthorized', 401);
        }),
        sleep: (Duration duration) async {},
      );

      await expectLater(
        transport.get(
          Uri.parse('https://example.invalid/value?api_key=secret'),
          operation: 'fixture',
        ),
        throwsA(isA<VideoMetadataNetworkException>()),
      );
      expect(requests, 1);
    });
  });

  test('parseRetryAfter supports delta seconds and HTTP dates', () {
    final DateTime now = DateTime.utc(2015, 10, 21, 7, 27, 58);
    expect(
      parseRetryAfter('3', now: now),
      const Duration(seconds: 3),
    );
    expect(
      parseRetryAfter('Wed, 21 Oct 2015 07:28:00 GMT', now: now),
      const Duration(seconds: 2),
    );
  });
}
