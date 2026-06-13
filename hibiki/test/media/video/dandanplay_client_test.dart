import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_danmaku_source.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  group('DandanplayClient', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hibiki_dandanplay_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('computes MD5 from the first 16MiB only', () async {
      final File file = File(p.join(tempDir.path, 'video.mkv'));
      file.writeAsBytesSync(<int>[1, 2, 3, 4]);

      final String hash = await dandanplayFileHash(file);

      expect(hash, '08d6c05a21512a79a1dfeb9d2a8f262f');
    });

    test('exact match posts hash metadata then fetches related comments',
        () async {
      final File file = File(p.join(tempDir.path, 'Episode 01.mkv'));
      file.writeAsBytesSync(<int>[1, 2, 3, 4]);
      final List<http.Request> requests = <http.Request>[];
      final DandanplayClient client = DandanplayClient(
        httpClient: MockClient((http.Request request) async {
          requests.add(request);
          if (request.url.path == '/api/v2/match') {
            final Map<String, dynamic> body =
                jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['fileName'], 'Episode 01');
            expect(body['fileHash'], '08d6c05a21512a79a1dfeb9d2a8f262f');
            expect(body['fileSize'], 4);
            return http.Response(
              jsonEncode(<String, dynamic>{
                'success': true,
                'isMatched': true,
                'matches': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'episodeId': 42,
                    'animeTitle': 'Demo',
                    'episodeTitle': '01',
                    'shift': 1.5,
                  },
                ],
              }),
              200,
            );
          }
          expect(request.url.path, '/api/v2/comment/42');
          expect(request.url.queryParameters['withRelated'], 'true');
          return http.Response(
            jsonEncode(<String, dynamic>{
              'count': 1,
              'comments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'p': '2.00,1,16777215,100',
                  'm': 'online',
                },
              ],
            }),
            200,
          );
        }),
      );

      final DandanplayFetchResult result =
          await client.fetchBestDanmakuForFile(file);

      expect(result.status, DandanplayFetchStatus.hit);
      expect(result.match?.episodeId, 42);
      expect(result.items, hasLength(1));
      expect(result.items.single.text, 'online');
      expect(result.items.single.startMs, 3500,
          reason: 'match.shift delays fetched comments by seconds');
      expect(requests, hasLength(2));
    });

    test('multiple fuzzy matches degrade to needsSelection without fetching',
        () async {
      final File file = File(p.join(tempDir.path, 'Episode 02.mkv'));
      file.writeAsBytesSync(<int>[1]);
      int commentFetches = 0;
      final DandanplayClient client = DandanplayClient(
        httpClient: MockClient((http.Request request) async {
          if (request.url.path.startsWith('/api/v2/comment')) {
            commentFetches++;
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'success': true,
              'isMatched': false,
              'matches': <Map<String, dynamic>>[
                <String, dynamic>{'episodeId': 1, 'animeTitle': 'A'},
                <String, dynamic>{'episodeId': 2, 'animeTitle': 'B'},
              ],
            }),
            200,
          );
        }),
      );

      final DandanplayFetchResult result =
          await client.fetchBestDanmakuForFile(file);

      expect(result.status, DandanplayFetchStatus.needsSelection);
      expect(result.matches, hasLength(2));
      expect(result.items, isEmpty);
      expect(commentFetches, 0);
    });

    test('no match and network failure degrade gracefully', () async {
      final File file = File(p.join(tempDir.path, 'Episode 03.mkv'));
      file.writeAsBytesSync(<int>[1]);
      final DandanplayClient noMatchClient = DandanplayClient(
        httpClient: MockClient((_) async => http.Response(
              jsonEncode(<String, dynamic>{
                'success': true,
                'isMatched': false,
                'matches': <Map<String, dynamic>>[],
              }),
              200,
            )),
      );
      final DandanplayFetchResult noMatch =
          await noMatchClient.fetchBestDanmakuForFile(file);
      expect(noMatch.status, DandanplayFetchStatus.noMatch);
      expect(noMatch.items, isEmpty);

      final DandanplayClient failureClient = DandanplayClient(
        httpClient: MockClient((_) async => throw const SocketException('x')),
      );
      final DandanplayFetchResult failure =
          await failureClient.fetchBestDanmakuForFile(file);
      expect(failure.status, DandanplayFetchStatus.networkError);
      expect(failure.items, isEmpty);
    });

    test('comment fetch timeout degrades gracefully', () async {
      final File file = File(p.join(tempDir.path, 'Episode 04.mkv'));
      file.writeAsBytesSync(<int>[1, 2, 3, 4]);
      final DandanplayClient client = DandanplayClient(
        timeout: const Duration(milliseconds: 1),
        httpClient: MockClient((http.Request request) async {
          if (request.url.path == '/api/v2/match') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'success': true,
                'isMatched': true,
                'matches': <Map<String, dynamic>>[
                  <String, dynamic>{'episodeId': 42},
                ],
              }),
              200,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response(
            jsonEncode(<String, dynamic>{'comments': <dynamic>[]}),
            200,
          );
        }),
      );

      final DandanplayFetchResult result =
          await client.fetchBestDanmakuForFile(file);

      expect(result.status, DandanplayFetchStatus.networkError);
      expect(result.items, isEmpty);
    });

    test('comment parser is real Dandanplay JSON parser, not a mocked core',
        () {
      final List<VideoDanmakuItem> items = dandanplayCommentsToDanmaku(
        <Map<String, dynamic>>[
          <String, dynamic>{'p': '1.00,5,255,100', 'm': 'top'},
        ],
        shiftMs: -500,
      );

      expect(items.single.startMs, 500);
      expect(items.single.mode, VideoDanmakuMode.top);
      expect(items.single.colorArgb, 0xFF0000FF);
    });
  });
}
