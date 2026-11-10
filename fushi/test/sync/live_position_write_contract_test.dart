/// BUG-4388：互联 live 写入（书进度 / 视频位置 / 有声书位置 `PUT`）的 host 侧线上契约。
///
/// 根因：三个 `PUT` 一律回 200 空体，写没写、为什么没写都不告诉 client，也不接受
/// 「期望值」前置条件——client 只能无条件记基线、按旧快照盲写。本文件用真
/// [FushiSyncServer] + [LocalLibraryHostService] 与裸 [HttpClient] 钉住新契约：
/// 结果回执（`result` + host 写后的当前值）、前置条件不符回 409 不写库、命中前置
/// 条件时不按戳拒收、响应头 `X-Fushi-Live-Write: 1` 宣告能力。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

const String _token = 'live-write-contract-token';
const String _header = 'x-fushi-live-write';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

typedef _Resp = ({int status, String? liveHeader, String body});

int _now() => DateTime.now().millisecondsSinceEpoch;

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late String base;
  late HttpClient http;

  Future<_Resp> send(String method, String path, {Object? body}) async {
    final HttpClientRequest req = await http.openUrl(
      method,
      Uri.parse('$base$path'),
    );
    req.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('fushi:$_token'))}',
    );
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final HttpClientResponse res = await req.close();
    final String text = await utf8.decodeStream(res);
    return (
      status: res.statusCode,
      liveHeader: res.headers.value(_header),
      body: text,
    );
  }

  Map<String, Object?> jsonOf(_Resp r) =>
      (jsonDecode(r.body) as Map<String, dynamic>).cast<String, Object?>();

  setUp(() async {
    work = await Directory.systemTemp.createTemp('live_write_contract_');
    hostDb = _memDb();
    final LocalLibraryHostService libSvc = LocalLibraryHostService(
      db: hostDb,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: _token,
      allowLan: false,
      libraryService: libSvc,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await server.stop();
    await hostDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  group('video position PUT', () {
    const String id = 'vid-1';
    const String path = '/api/library/videos/$id/position';
    late int storedAt;

    Future<({int pos, int at})> stored() async => (
      pos: await hostDb.getPrefTyped<int>(
        videoRemotePositionEpisodePrefKey(id, 0),
        0,
      ),
      at: await hostDb.getPrefTyped<int>(
        videoRemotePositionEpisodeAtPrefKey(id, 0),
        0,
      ),
    );

    Future<void> seed(int pos, int at) async {
      await hostDb.setPrefTyped<int>(
        videoRemotePositionEpisodePrefKey(id, 0),
        pos,
      );
      await hostDb.setPrefTyped<int>(
        videoRemotePositionEpisodeAtPrefKey(id, 0),
        at,
      );
    }

    setUp(() async {
      final File f = File(p.join(work.path, 'v.mp4'))
        ..writeAsBytesSync(<int>[0, 1, 2, 3]);
      await hostDb.upsertVideoBook(
        VideoBooksCompanion.insert(bookUid: id, title: 'v', videoPath: f.path),
      );
      storedAt = _now() - const Duration(hours: 1).inMilliseconds;
      await seed(5000, storedAt);
    });

    test('GET announces the live-write contract header', () async {
      final _Resp r = await send('GET', path);
      expect(r.status, 200);
      expect(r.liveHeader, '1');
    });

    test(
      'newer stamp without precondition -> applied with host value',
      () async {
        final int at = _now() - 60000;
        final _Resp r = await send(
          'PUT',
          path,
          body: <String, Object?>{
            'positionMs': 7000,
            'positionUpdatedAtMs': at,
          },
        );
        expect(r.status, 200);
        expect(r.liveHeader, '1');
        final Map<String, Object?> j = jsonOf(r);
        expect(j['result'], 'applied');
        expect(j['positionMs'], 7000);
        expect(j['positionUpdatedAtMs'], at);
        expect(await stored(), (pos: 7000, at: at));
      },
    );

    test('older stamp without precondition -> stale, host unchanged', () async {
      final _Resp r = await send(
        'PUT',
        path,
        body: <String, Object?>{
          'positionMs': 1000,
          'positionUpdatedAtMs': storedAt - 3600000,
        },
      );
      expect(r.status, 200);
      final Map<String, Object?> j = jsonOf(r);
      expect(j['result'], 'stale');
      expect(j['positionMs'], 5000);
      expect(j['positionUpdatedAtMs'], storedAt);
      expect(await stored(), (pos: 5000, at: storedAt));
    });

    test('precondition mismatch -> 409 preconditionFailed, no write', () async {
      final _Resp r = await send(
        'PUT',
        path,
        body: <String, Object?>{
          'positionMs': 9000,
          'positionUpdatedAtMs': _now(),
          'expectedPositionsMs': <int>[1234],
        },
      );
      expect(r.status, 409);
      expect(r.liveHeader, '1');
      final Map<String, Object?> j = jsonOf(r);
      expect(j['result'], 'preconditionFailed');
      expect(j['positionMs'], 5000);
      expect(await stored(), (pos: 5000, at: storedAt));
    });

    test(
      'precondition hit with an older stamp -> applied at stored+1',
      () async {
        final _Resp r = await send(
          'PUT',
          path,
          body: <String, Object?>{
            'positionMs': 8000,
            'positionUpdatedAtMs': storedAt - 3600000,
            'expectedPositionsMs': <int>[4000, 5000],
          },
        );
        expect(r.status, 200);
        final Map<String, Object?> j = jsonOf(r);
        expect(j['result'], 'applied');
        expect(j['positionMs'], 8000);
        expect(j['positionUpdatedAtMs'], storedAt + 1);
        expect(await stored(), (pos: 8000, at: storedAt + 1));
      },
    );

    test('poisoned stored stamp + precondition hit + same position -> '
        'rewritten with a trusted stamp', () async {
      await seed(5000, _now() + const Duration(days: 1).inMilliseconds);
      final int at = _now();
      final _Resp r = await send(
        'PUT',
        path,
        body: <String, Object?>{
          'positionMs': 5000,
          'positionUpdatedAtMs': at,
          'expectedPositionsMs': <int>[5000],
        },
      );
      expect(r.status, 200);
      expect(jsonOf(r)['result'], 'applied');
      final ({int pos, int at}) s = await stored();
      expect(s.pos, 5000);
      expect(
        s.at,
        lessThanOrEqualTo(_now() + kSyncFutureStampToleranceMs),
        reason: '毒戳必须被改写成可信戳',
      );
    });

    test('non-int expectedPositionsMs element -> 400', () async {
      final _Resp r = await send(
        'PUT',
        path,
        body: <String, Object?>{
          'positionMs': 1,
          'positionUpdatedAtMs': _now(),
          'expectedPositionsMs': <Object?>['x'],
        },
      );
      expect(r.status, 400);
      expect(await stored(), (pos: 5000, at: storedAt));
    });
  });

  group('audiobook position PUT', () {
    const String key = 'ab-1';
    const String path = '/api/library/audiobooks/$key/position';
    late int storedAt;

    Future<({int pos, int at})> stored() async => (
      pos: await hostDb.getPrefTyped<int>(audiobookPositionPrefKey(key), 0),
      at: await hostDb.getPrefTyped<int>(audiobookPositionAtPrefKey(key), 0),
    );

    setUp(() async {
      await hostDb.upsertAudiobook(
        AudiobooksCompanion.insert(
          bookKey: key,
          alignmentFormat: 'srt',
          alignmentPath: '/tmp/$key.srt',
        ),
      );
      storedAt = _now() - const Duration(hours: 1).inMilliseconds;
      await hostDb.setPrefTyped<int>(audiobookPositionPrefKey(key), 3000);
      await hostDb.setPrefTyped<int>(audiobookPositionAtPrefKey(key), storedAt);
    });

    test('GET announces the live-write contract header', () async {
      final _Resp r = await send('GET', path);
      expect(r.status, 200);
      expect(r.liveHeader, '1');
    });

    test('newer stamp without precondition -> applied', () async {
      final int at = _now() - 60000;
      final _Resp r = await send(
        'PUT',
        path,
        body: <String, Object?>{'positionMs': 4000, 'positionUpdatedAtMs': at},
      );
      expect(r.status, 200);
      expect(r.liveHeader, '1');
      final Map<String, Object?> j = jsonOf(r);
      expect(j['result'], 'applied');
      expect(j['positionMs'], 4000);
      expect(j['positionUpdatedAtMs'], at);
      expect(await stored(), (pos: 4000, at: at));
    });

    test('older stamp without precondition -> stale', () async {
      final _Resp r = await send(
        'PUT',
        path,
        body: <String, Object?>{
          'positionMs': 100,
          'positionUpdatedAtMs': storedAt - 1,
        },
      );
      expect(r.status, 200);
      expect(jsonOf(r)['result'], 'stale');
      expect(await stored(), (pos: 3000, at: storedAt));
    });

    test('precondition mismatch -> 409, no write', () async {
      final _Resp r = await send(
        'PUT',
        path,
        body: <String, Object?>{
          'positionMs': 9000,
          'positionUpdatedAtMs': _now(),
          'expectedPositionsMs': <int>[1],
        },
      );
      expect(r.status, 409);
      expect(jsonOf(r)['result'], 'preconditionFailed');
      expect(await stored(), (pos: 3000, at: storedAt));
    });

    test(
      'precondition hit with an older stamp -> applied at stored+1',
      () async {
        final _Resp r = await send(
          'PUT',
          path,
          body: <String, Object?>{
            'positionMs': 3500,
            'positionUpdatedAtMs': storedAt - 3600000,
            'expectedPositionsMs': <int>[3000],
          },
        );
        expect(r.status, 200);
        expect(jsonOf(r)['result'], 'applied');
        expect(await stored(), (pos: 3500, at: storedAt + 1));
      },
    );
  });

  group('book progress PUT', () {
    const String key = 'book-1';
    const String path = '/api/library/books/$key/progress';
    late int storedAt;

    Future<ReaderPositionRow?> stored() async {
      final String? uid = await hostDb.resolveEpubBookUid(key);
      return uid == null ? null : hostDb.getReaderPosition(uid);
    }

    setUp(() async {
      await hostDb.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: key,
          epubPath: '/tmp/$key.epub',
          extractDir: '/tmp/$key',
          chapterCount: 1,
          chaptersJson: '["ch1"]',
          importedAt: _now(),
        ),
      );
      storedAt = _now() - const Duration(hours: 1).inMilliseconds;
      await hostDb.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value((await hostDb.resolveEpubBookUid(key))!),
          sectionIndex: const Value(2),
          normCharOffset: const Value(100),
          charOffset: const Value(-1),
          updatedAt: Value(storedAt),
        ),
      );
    });

    Map<String, Object?> progress(int section, int norm, int charOff, int at) =>
        <String, Object?>{
          'sectionIndex': section,
          'normCharOffset': norm,
          'charOffset': charOff,
          'updatedAtMs': at,
        };

    test('GET (single + batch) announces the live-write header', () async {
      final _Resp single = await send('GET', path);
      expect(single.status, 200);
      expect(single.liveHeader, '1');
      final _Resp batch = await send('GET', '/api/library/book-progress');
      expect(batch.status, 200);
      expect(batch.liveHeader, '1');
    });

    test('newer stamp without precondition -> applied', () async {
      final int at = _now() - 60000;
      final _Resp r = await send('PUT', path, body: progress(3, 5, 7, at));
      expect(r.status, 200);
      expect(r.liveHeader, '1');
      final Map<String, Object?> j = jsonOf(r);
      expect(j['result'], 'applied');
      expect(j['progress'], progress(3, 5, 7, at));
      final ReaderPositionRow row = (await stored())!;
      expect(row.sectionIndex, 3);
      expect(row.updatedAt, at);
    });

    test('older stamp without precondition -> stale', () async {
      final _Resp r = await send(
        'PUT',
        path,
        body: progress(0, 1, -1, storedAt - 1),
      );
      expect(r.status, 200);
      final Map<String, Object?> j = jsonOf(r);
      expect(j['result'], 'stale');
      expect(j['progress'], progress(2, 100, -1, storedAt));
      expect((await stored())!.sectionIndex, 2);
    });

    test('precondition mismatch -> 409, no write', () async {
      final _Resp r = await send(
        'PUT',
        path,
        body: <String, Object?>{
          ...progress(9, 9, -1, _now()),
          'expected': <Object?>[
            <String, Object?>{'sectionIndex': 1, 'normCharOffset': 1},
          ],
        },
      );
      expect(r.status, 409);
      expect(jsonOf(r)['result'], 'preconditionFailed');
      final ReaderPositionRow row = (await stored())!;
      expect((row.sectionIndex, row.updatedAt), (2, storedAt));
    });

    test(
      'precondition hit with an older stamp -> applied at stored+1',
      () async {
        final _Resp r = await send(
          'PUT',
          path,
          body: <String, Object?>{
            ...progress(4, 0, -1, storedAt - 3600000),
            'expected': <Object?>[
              <String, Object?>{'sectionIndex': 2, 'normCharOffset': 100},
            ],
          },
        );
        expect(r.status, 200);
        expect(jsonOf(r)['result'], 'applied');
        final ReaderPositionRow row = (await stored())!;
        expect((row.sectionIndex, row.updatedAt), (4, storedAt + 1));
      },
    );

    test('same position and stamp, only charOffset differs + precondition hit '
        '-> applied, host takes the precise anchor', () async {
      final _Resp r = await send(
        'PUT',
        path,
        body: <String, Object?>{
          ...progress(2, 100, 42, storedAt),
          'expected': <Object?>[
            <String, Object?>{'sectionIndex': 2, 'normCharOffset': 100},
          ],
        },
      );
      expect(r.status, 200);
      expect(jsonOf(r)['result'], 'applied');
      expect((await stored())!.charOffset, 42);
    });

    test('expected element missing a field -> 400', () async {
      final _Resp r = await send(
        'PUT',
        path,
        body: <String, Object?>{
          ...progress(9, 9, -1, _now()),
          'expected': <Object?>[
            <String, Object?>{'sectionIndex': 2},
          ],
        },
      );
      expect(r.status, 400);
      expect((await stored())!.sectionIndex, 2);
    });

    test('book not on host -> 200 missing', () async {
      final _Resp r = await send(
        'PUT',
        '/api/library/books/no-such-book/progress',
        body: progress(1, 1, -1, _now()),
      );
      expect(r.status, 200);
      expect(jsonOf(r)['result'], 'missing');
    });
  });

  group('outcome parsing', () {
    test('position outcome: unknown result / empty / non-map -> null', () {
      expect(
        LivePositionWriteOutcome.tryParse(<String, Object?>{
          'result': 'bogus',
          'positionMs': 1,
          'positionUpdatedAtMs': 2,
        }),
        isNull,
      );
      expect(LivePositionWriteOutcome.tryParse(<String, Object?>{}), isNull);
      expect(LivePositionWriteOutcome.tryParse(null), isNull);
      expect(LivePositionWriteOutcome.tryParse(<Object?>[1]), isNull);
      expect(LivePositionWriteOutcome.tryParse('applied'), isNull);
    });

    test('position outcome round-trips through toJson', () {
      const LivePositionWriteOutcome o = LivePositionWriteOutcome(
        result: LiveWriteResult.preconditionFailed,
        positionMs: 12,
        updatedAtMs: 34,
      );
      final LivePositionWriteOutcome? back = LivePositionWriteOutcome.tryParse(
        jsonDecode(jsonEncode(o.toJson())),
      );
      expect(back?.result, LiveWriteResult.preconditionFailed);
      expect((back?.positionMs, back?.updatedAtMs), (12, 34));
    });

    test(
      'book outcome: unknown result / missing progress / non-map -> null',
      () {
        expect(
          LiveBookProgressWriteOutcome.tryParse(<String, Object?>{
            'result': 'nope',
            'progress': RemoteBookProgress.empty.toJson(),
          }),
          isNull,
        );
        expect(
          LiveBookProgressWriteOutcome.tryParse(<String, Object?>{
            'result': 'applied',
          }),
          isNull,
        );
        expect(LiveBookProgressWriteOutcome.tryParse(null), isNull);
        expect(LiveBookProgressWriteOutcome.tryParse(<Object?>[]), isNull);
      },
    );
  });
}
