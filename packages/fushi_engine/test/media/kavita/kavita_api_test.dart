import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

const String _key = 'SECRET-API-KEY';

http.Response _json(Object body, {int status = 200, Map<String, String>? h}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: <String, String>{'content-type': 'application/json', ...?h},
    );

KavitaApi _api(MockClientHandler handler) => KavitaApi(
  serverUrl: 'http://kavita.test:5000',
  apiKey: _key,
  client: MockClient(handler),
);

Map<String, Object?> _auth(String token) => <String, Object?>{
  'token': token,
  'refreshToken': 'r',
  'apiKey': _key,
};

void main() {
  group('models', () {
    test('series-detail flattens volumes/chapters/specials and dedupes', () {
      final KavitaSeriesDetail d = KavitaSeriesDetail.fromJson(
        <String, Object?>{
          'volumes': <Object?>[
            <String, Object?>{
              'id': 10,
              'chapters': <Object?>[
                <String, Object?>{'id': 1, 'sortOrder': 2, 'pages': 5},
                <String, Object?>{'id': 2, 'sortOrder': 1, 'pages': 5},
              ],
            },
          ],
          'chapters': <Object?>[
            <String, Object?>{'id': 2, 'sortOrder': 1},
          ],
          'specials': <Object?>[
            <String, Object?>{'id': 43011, 'sortOrder': 100, 'isSpecial': true},
          ],
          'storylineChapters': <Object?>[],
          'unknownFutureField': 'ignored',
        },
      );
      final List<KavitaChapter> all = d.allChapters;
      expect(all.map((KavitaChapter c) => c.id), <int>[2, 1, 43011]);
      expect(all.first.volumeId, 10); // 缺 volumeId 取所属 volume
      expect(all.last.isSpecial, isTrue);
    });

    test('series json tolerates missing and wrong-typed fields', () {
      final KavitaSeries s = KavitaSeries.fromJson(<String, Object?>{
        'id': '477',
        'name': 'x',
        'format': 3,
        'pages': 'oops',
      });
      expect(s.id, 477);
      expect(s.isEpub, isTrue);
      expect(s.pages, 0);
      expect(s.displayName, 'x');
    });

    test('kavita UTC timestamps without zone are read as UTC', () {
      final DateTime? t = parseKavitaUtc('2026-10-26T08:00:00.5');
      expect(t, isNotNull);
      expect(t!.isUtc, isTrue);
      expect(t.hour, 8);
      expect(parseKavitaUtc('2026-10-26T08:00:00Z')!.hour, 8);
      expect(parseKavitaUtc(null), isNull);
    });

    test('progress request body omits lastModifiedUtc, includes scroll id', () {
      final KavitaProgress p = KavitaProgress(
        volumeId: 1,
        chapterId: 2,
        pageNum: 3,
        seriesId: 4,
        libraryId: 5,
        bookScrollId: 'a/b',
        lastModifiedUtc: DateTime.utc(2026),
      );
      final Map<String, Object?> body = p.toRequestJson();
      expect(body.containsKey('lastModifiedUtc'), isFalse);
      expect(body['bookScrollId'], 'a/b');
    });

    test('epub detected by seriesFormat, not library type', () {
      final KavitaChapterInfo i = KavitaChapterInfo.fromJson(<String, Object?>{
        'seriesFormat': 3,
        'libraryType': 0,
        'pages': 12,
      });
      expect(i.isEpub, isTrue);
    });
  });

  group('url building', () {
    test('normalizeServerUrl adds scheme and trims slash', () {
      expect(
        KavitaApi.normalizeServerUrl('192.168.0.246:5501/'),
        'http://192.168.0.246:5501',
      );
      expect(KavitaApi.normalizeServerUrl('HTTPS://a.b'), 'https://a.b');
    });

    test('page and cover urls carry apiKey; exception text does not', () {
      final KavitaApi api = _api((_) async => _json(<String, Object?>{}));
      final String url = api.pageImageUrl(9, 3);
      expect(url, contains('chapterId=9'));
      expect(url, contains('page=3'));
      expect(url, contains('apiKey=$_key'));
      expect(api.seriesCoverUrl(1), contains('apiKey=$_key'));
      expect(
        const KavitaApiException(401, '/api/Reader/image').toString(),
        isNot(contains(_key)),
      );
    });
  });

  group('auth', () {
    test('authenticate posts apiKey and pluginName, stores jwt', () async {
      final List<http.Request> seen = <http.Request>[];
      final KavitaApi api = _api((http.Request r) async {
        seen.add(r);
        if (r.url.path == '/api/Plugin/authenticate') {
          return _json(_auth('jwt1'));
        }
        return _json(<Object?>[]);
      });
      await api.authenticate();
      expect(seen.single.method, 'POST');
      expect(seen.single.url.queryParameters['apiKey'], _key);
      expect(seen.single.url.queryParameters['pluginName'], 'Fushi');
      await api.getLibraries();
      expect(seen.last.headers['Authorization'], 'Bearer jwt1');
    });

    test('401 triggers one re-auth and a replay', () async {
      int libCalls = 0;
      int authCalls = 0;
      final KavitaApi api = _api((http.Request r) async {
        if (r.url.path == '/api/Plugin/authenticate') {
          authCalls++;
          return _json(_auth('jwt$authCalls'));
        }
        libCalls++;
        if (r.headers['Authorization'] == 'Bearer jwt1') {
          return http.Response('', 401);
        }
        return _json(<Object?>[
          <String, Object?>{'id': 1, 'name': 'Manga', 'type': 0},
        ]);
      });
      final List<KavitaLibrary> libs = await api.getLibraries();
      expect(libs.single.name, 'Manga');
      expect(authCalls, 2); // 初次 + 401 后重鉴权
      expect(libCalls, 2);
    });

    test('second 401 after re-auth surfaces as exception', () async {
      final KavitaApi api = _api((http.Request r) async {
        if (r.url.path == '/api/Plugin/authenticate') {
          return _json(_auth('jwt'));
        }
        return http.Response('', 401);
      });
      expect(
        api.getLibraries(),
        throwsA(
          isA<KavitaApiException>().having(
            (KavitaApiException e) => e.isUnauthorized,
            'isUnauthorized',
            isTrue,
          ),
        ),
      );
    });

    test(
      'bad key on authenticate throws 401 without leaking the key',
      () async {
        final KavitaApi api = _api((_) async => http.Response('no', 401));
        try {
          await api.authenticate();
          fail('expected throw');
        } on KavitaApiException catch (e) {
          expect(e.statusCode, 401);
          expect(e.toString(), isNot(contains(_key)));
        }
      },
    );
  });

  group('browse', () {
    test(
      'series page reads Pagination header and sends library filter',
      () async {
        Map<String, Object?>? body;
        Map<String, String>? query;
        final KavitaApi api = _api((http.Request r) async {
          if (r.url.path == '/api/Plugin/authenticate') {
            return _json(_auth('jwt'));
          }
          body = jsonDecode(r.body) as Map<String, Object?>;
          query = r.url.queryParameters;
          return _json(
            <Object?>[
              <String, Object?>{'id': 477, 'name': '化物語', 'format': 3},
            ],
            h: <String, String>{
              'pagination': jsonEncode(<String, Object?>{
                'currentPage': 1,
                'itemsPerPage': 50,
                'totalItems': 60,
                'totalPages': 2,
              }),
            },
          );
        });
        final KavitaSeriesPage page = await api.getSeriesPage(libraryId: 5);
        expect(query!['PageNumber'], '1');
        expect(query!['PageSize'], '50');
        final List<Object?> statements = body!['statements'] as List<Object?>;
        expect((statements.single as Map)['value'], '5');
        expect(page.items.single.isEpub, isTrue);
        expect(page.totalItems, 60);
        expect(page.hasMore, isTrue);
      },
    );

    test('missing/garbled Pagination header degrades to single page', () async {
      final KavitaApi api = _api((http.Request r) async {
        if (r.url.path == '/api/Plugin/authenticate') {
          return _json(_auth('jwt'));
        }
        return _json(
          <Object?>[],
          h: <String, String>{'pagination': '{not json'},
        );
      });
      final KavitaSeriesPage page = await api.getSeriesPage();
      expect(page.hasMore, isFalse);
      expect(page.items, isEmpty);
    });
  });

  group('progress', () {
    test('saveProgress posts the DTO', () async {
      Map<String, Object?>? body;
      String? path;
      final KavitaApi api = _api((http.Request r) async {
        if (r.url.path == '/api/Plugin/authenticate') {
          return _json(_auth('jwt'));
        }
        path = r.url.path;
        body = jsonDecode(r.body) as Map<String, Object?>;
        return http.Response('', 200);
      });
      await api.saveProgress(
        const KavitaProgress(
          volumeId: 1,
          chapterId: 2,
          pageNum: 7,
          seriesId: 3,
          libraryId: 4,
        ),
      );
      expect(path, '/api/Reader/progress');
      expect(body!['pageNum'], 7);
      expect(body!.containsKey('bookScrollId'), isFalse);
    });

    test('getProgress parses server timestamp', () async {
      final KavitaApi api = _api((http.Request r) async {
        if (r.url.path == '/api/Plugin/authenticate') {
          return _json(_auth('jwt'));
        }
        return _json(<String, Object?>{
          'chapterId': 2,
          'pageNum': 9,
          'lastModifiedUtc': '2026-10-26T08:00:00',
        });
      });
      final KavitaProgress p = await api.getProgress(2);
      expect(p.pageNum, 9);
      expect(p.lastModifiedUtc, DateTime.utc(2026, 10, 26, 8));
    });
  });

  group('page image / cover bytes', () {
    const Duration stall = Duration(milliseconds: 150);

    KavitaApi streamingApi(
      Future<http.StreamedResponse> Function(http.BaseRequest request) handler,
    ) => KavitaApi(
      serverUrl: 'http://kavita.test:5000',
      apiKey: _key,
      imageStallTimeout: stall,
      client: MockClient.streaming(
        (http.BaseRequest request, http.ByteStream body) => handler(request),
      ),
    );

    Future<void> abortOf(http.BaseRequest request) =>
        (request as http.Abortable).abortTrigger!;

    test('reads the body across chunks; request is abortable', () async {
      late http.BaseRequest seen;
      final KavitaApi api = streamingApi((http.BaseRequest request) async {
        seen = request;
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[
            <int>[1, 2, 3],
            <int>[4, 5],
          ]),
          200,
        );
      });
      final Uint8List bytes = await api.fetchPageBytes(9, 3);
      expect(bytes, <int>[1, 2, 3, 4, 5]);
      expect(seen.url.path, '/api/Reader/image');
      expect(seen.url.queryParameters['chapterId'], '9');
      expect(seen.url.queryParameters['page'], '3');
      expect(seen, isA<http.Abortable>());
      bool aborted = false;
      unawaited(abortOf(seen).then((_) => aborted = true));
      await Future<void>.delayed(Duration.zero);
      expect(aborted, isFalse, reason: 'a finished request is not aborted');
    });

    test('a slow body that keeps moving outlives the stall budget', () async {
      // 整体耗时是停顿预算的 4 倍，但块间从不超过预算：旧的整请求超时会判失败。
      final KavitaApi api = streamingApi((http.BaseRequest request) async {
        Stream<List<int>> body() async* {
          for (int i = 0; i < 6; i++) {
            await Future<void>.delayed(stall * (2 / 3));
            yield <int>[i];
          }
        }

        return http.StreamedResponse(body(), 200);
      });
      final Stopwatch clock = Stopwatch()..start();
      expect(await api.fetchSeriesCoverBytes(1), <int>[0, 1, 2, 3, 4, 5]);
      expect(clock.elapsed, greaterThan(stall * 3));
    });

    test('a stalled body times out and aborts the request', () async {
      final Completer<void> aborted = Completer<void>();
      final StreamController<List<int>> body = StreamController<List<int>>();
      bool cancelled = false;
      body.onCancel = () => cancelled = true;
      final KavitaApi api = streamingApi((http.BaseRequest request) async {
        unawaited(abortOf(request).then((_) => aborted.complete()));
        body.add(<int>[1, 2, 3]);
        return http.StreamedResponse(body.stream, 200);
      });
      await expectLater(
        api.fetchPageBytes(1, 0),
        throwsA(isA<TimeoutException>()),
      );
      await aborted.future.timeout(const Duration(seconds: 5));
      expect(cancelled, isTrue, reason: 'response stream is released');
    });

    test('stalled response headers time out and abort the request', () async {
      final Completer<void> aborted = Completer<void>();
      final Completer<http.StreamedResponse> never =
          Completer<http.StreamedResponse>();
      final KavitaApi api = streamingApi((http.BaseRequest request) {
        unawaited(abortOf(request).then((_) => aborted.complete()));
        return never.future;
      });
      await expectLater(
        api.fetchSeriesCoverBytes(1),
        throwsA(isA<TimeoutException>()),
      );
      await aborted.future.timeout(const Duration(seconds: 5));
    });

    test('non-2xx surfaces as KavitaApiException without the query', () async {
      final KavitaApi api = streamingApi(
        (http.BaseRequest request) async =>
            http.StreamedResponse(const Stream<List<int>>.empty(), 404),
      );
      await expectLater(
        api.fetchPageBytes(1, 0),
        throwsA(
          isA<KavitaApiException>()
              .having((KavitaApiException e) => e.isNotFound, 'notFound', true)
              .having(
                (KavitaApiException e) => '$e',
                'text',
                isNot(contains(_key)),
              ),
        ),
      );
    });

    test('transport failure is typed and redacts the api key', () async {
      final KavitaApi api = streamingApi((http.BaseRequest request) async {
        throw http.ClientException('connection refused', request.url);
      });
      await expectLater(
        api.fetchPageBytes(1, 0),
        throwsA(
          isA<KavitaTransportException>().having(
            (KavitaTransportException e) => '$e',
            'text',
            allOf(contains('connection refused'), isNot(contains(_key))),
          ),
        ),
      );
    });
  });

  // 上一组用 MockClient，只能证明「触发了 abort」。真 `IOClient` 的 abort 在「已有
  // 响应、还没人 listen」时不碰底层响应，所以连接有没有真的放掉只能在真 socket 上看：
  // 假服务器是一个裸 ServerSocket，断言的是**服务器侧**看到对端关了连接。
  group('page image / cover bytes over a real socket', () {
    // 只有两条「卡住」用例要等它到点；给足 1 秒，进程里第一次建连的冷启动不会
    // 被误判成超时。其余用例用生产默认值（不该触发）。
    const Duration stall = Duration(seconds: 1);
    const Duration closeWithin = Duration(seconds: 10);

    late ServerSocket server;
    late http.Client client;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      // 裸 IOClient：不走应用代理出口，回环请求不受本机代理配置影响。空闲连接
      // 1 秒就关（默认 15 秒）：放回连接池的连接很快在服务器侧表现为「被关掉」，
      // 而一条响应没人读的连接永远不会变成空闲，也就永远不关。
      client = IOClient(HttpClient()..idleTimeout = const Duration(seconds: 1));
    });
    tearDown(() async {
      client.close();
      await server.close();
    });

    KavitaApi api({Duration stallTimeout = KavitaApi.kImageStallTimeout}) =>
        KavitaApi(
          serverUrl: 'http://127.0.0.1:${server.port}',
          apiKey: _key,
          imageStallTimeout: stallTimeout,
          client: client,
        );

    /// 接下一条连接：读完请求头后原样写出 [reply]（null = 一个字节都不答），之后
    /// 一直不关。返回的 future 在对端关掉这条连接（FIN 或 RST）时完成。
    Future<void> serveOnce(String? reply) {
      final Completer<void> peerClosed = Completer<void>();
      void closed() {
        if (!peerClosed.isCompleted) peerClosed.complete();
      }

      unawaited(
        server.first.then((Socket socket) {
          final BytesBuilder received = BytesBuilder();
          bool replied = false;
          socket.listen(
            (Uint8List data) {
              received.add(data);
              if (replied) return;
              if (!latin1.decode(received.toBytes()).contains('\r\n\r\n')) {
                return;
              }
              replied = true;
              if (reply != null) socket.add(latin1.encode(reply));
            },
            onError: (Object _) => closed(),
            onDone: () {
              closed();
              socket.destroy();
            },
          );
        }),
      );
      return peerClosed.future;
    }

    test('non-2xx with an error body releases the connection', () async {
      const String body = '{"error":"cover not found"}';
      final Future<void> peerClosed = serveOnce(
        'HTTP/1.1 404 Not Found\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${body.length}\r\n'
        '\r\n'
        '$body',
      );
      final KavitaApi kavita = api();
      await expectLater(
        kavita.fetchSeriesCoverBytes(7),
        throwsA(
          isA<KavitaApiException>().having(
            (KavitaApiException e) => e.isNotFound,
            'notFound',
            true,
          ),
        ),
      );
      // 错误体已到齐：取消后连接回池，空闲到点即关。没人读也没人取消的话它一直
      // 算「在用」，永远不关（撤掉修复，这里等到超时）。
      await peerClosed.timeout(closeWithin);
      expect(
        kavita.answerCount,
        1,
        reason: 'a 404 is still the server talking',
      );
    });

    test(
      'non-2xx with an unfinished error body closes the connection',
      () async {
        final Future<void> peerClosed = serveOnce(
          'HTTP/1.1 500 Internal Server Error\r\n'
          'Content-Type: text/plain\r\n'
          'Content-Length: 100000\r\n'
          '\r\n'
          'only-the-first-bytes',
        );
        await expectLater(
          api().fetchPageBytes(1, 0),
          throwsA(isA<KavitaApiException>()),
        );
        await peerClosed.timeout(closeWithin);
      },
    );

    test(
      'stalled response headers time out and close the connection',
      () async {
        final Future<void> peerClosed = serveOnce(null);
        final KavitaApi kavita = api(stallTimeout: stall);
        await expectLater(
          kavita.fetchPageBytes(1, 0),
          throwsA(isA<TimeoutException>()),
        );
        await peerClosed.timeout(closeWithin);
        expect(kavita.answerCount, 0);
      },
    );

    test('a stalled body times out and closes the connection', () async {
      final Future<void> peerClosed = serveOnce(
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: image/png\r\n'
        'Content-Length: 100000\r\n'
        '\r\n'
        'only-the-first-bytes',
      );
      await expectLater(
        api(stallTimeout: stall).fetchPageBytes(1, 0),
        throwsA(isA<TimeoutException>()),
      );
      await peerClosed.timeout(closeWithin);
    });

    test('a complete image is returned and the connection is kept', () async {
      const String body = 'PNGDATA';
      final Future<void> peerClosed = serveOnce(
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: image/png\r\n'
        'Content-Length: ${body.length}\r\n'
        '\r\n'
        '$body',
      );
      bool closed = false;
      unawaited(peerClosed.then((_) => closed = true));
      expect(await api().fetchPageBytes(1, 0), latin1.encode(body));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(closed, isFalse, reason: 'success keeps the connection pooled');
    });
  });

  group('answer accounting', () {
    test(
      'any status from the server counts, gateway 502/503/504 do not',
      () async {
        int status = 200;
        final KavitaApi api = _api((http.Request r) async {
          if (r.url.path == '/api/Plugin/authenticate') {
            return _json(_auth('jwt'));
          }
          return _json(<String, Object?>{}, status: status);
        });
        expect(api.answerCount, 0);
        expect(api.lastAnswerLatency, isNull);
        await api.getProgress(1); // authenticate + get-progress
        expect(api.answerCount, 2);
        expect(api.lastAnswerLatency, isNotNull);

        status = 500;
        await expectLater(
          api.getProgress(1),
          throwsA(isA<KavitaApiException>()),
        );
        expect(api.answerCount, 3);

        for (final int gateway in <int>[502, 503, 504]) {
          status = gateway;
          await expectLater(
            api.getProgress(1),
            throwsA(
              isA<KavitaApiException>().having(
                (KavitaApiException e) => e.isGatewayUnavailable,
                'gateway',
                true,
              ),
            ),
          );
        }
        expect(
          api.answerCount,
          3,
          reason: 'the proxy answered, Kavita did not',
        );
      },
    );

    test('a transport failure does not count', () async {
      final KavitaApi api = _api((http.Request r) async {
        throw http.ClientException('connection refused', r.url);
      });
      await expectLater(
        api.getLibraries(),
        throwsA(isA<KavitaTransportException>()),
      );
      expect(api.answerCount, 0);
    });
  });

  group('download', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('kavita_dl_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('streams to file, reports progress, parses RFC5987 name', () async {
      final List<int> payload = List<int>.generate(5000, (int i) => i % 251);
      final KavitaApi api = _api((http.Request r) async {
        if (r.url.path == '/api/Plugin/authenticate') {
          return _json(_auth('jwt'));
        }
        return http.Response.bytes(
          payload,
          200,
          headers: <String, String>{
            'content-type': 'application/epub+zip',
            'content-disposition':
                "attachment; filename*=UTF-8''%E5%8C%96%E7%89%A9%E8%AA%9E.epub",
          },
        );
      });
      final File dest = File('${tmp.path}/a.epub');
      int last = 0;
      final KavitaDownloadResult res = await api.downloadChapter(
        43011,
        dest,
        onProgress: (int got, int? total) => last = got,
      );
      expect(await dest.readAsBytes(), payload);
      expect(File('${dest.path}.part').existsSync(), isFalse);
      expect(res.fileName, '化物語.epub');
      expect(res.contentType, 'application/epub+zip');
      expect(last, payload.length);
    });

    test('cancelled download leaves no .part and no destination', () async {
      final KavitaApi api = _api((http.Request r) async {
        if (r.url.path == '/api/Plugin/authenticate') {
          return _json(_auth('jwt'));
        }
        return http.Response.bytes(List<int>.filled(10, 1), 200);
      });
      final File dest = File('${tmp.path}/b.cbz');
      final KavitaCancelToken token = KavitaCancelToken()..cancel();
      await expectLater(
        api.downloadChapter(1, dest, token: token),
        throwsA(isA<KavitaDownloadCancelled>()),
      );
      expect(dest.existsSync(), isFalse);
      expect(File('${dest.path}.part').existsSync(), isFalse);
    });

    test('http error surfaces and writes nothing', () async {
      final KavitaApi api = _api((http.Request r) async {
        if (r.url.path == '/api/Plugin/authenticate') {
          return _json(_auth('jwt'));
        }
        return http.Response('', 403);
      });
      final File dest = File('${tmp.path}/c.cbz');
      await expectLater(
        api.downloadChapter(1, dest),
        throwsA(
          isA<KavitaApiException>().having(
            (KavitaApiException e) => e.isForbidden,
            'isForbidden',
            isTrue,
          ),
        ),
      );
      expect(dest.existsSync(), isFalse);
    });

    test('content-disposition plain filename fallback', () {
      expect(
        KavitaApi.parseContentDispositionFileName(
          'attachment; filename="ch 1.cbz"',
        ),
        'ch 1.cbz',
      );
      expect(KavitaApi.parseContentDispositionFileName(null), isNull);
    });
  });
}
