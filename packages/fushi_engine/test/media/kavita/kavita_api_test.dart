import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:http/http.dart' as http;
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
