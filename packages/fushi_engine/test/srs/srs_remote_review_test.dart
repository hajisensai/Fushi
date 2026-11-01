// 复习远程刷卡的 host 侧（docs/specs/2026-11-01-srs-remote-review-design.md §2.1）：出卡带排程预览与陈旧标记、
// 同一请求 id 重发只记一次、出卡后卡变了回 stale、host 切了配置回 profile_changed、撤销后重新出题，以及路由的
// 线格式与错误码。
import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_remote_review.dart';
import 'package:fushi_engine/srs/srs_remote_review_routes.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsReviewLog;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'apkg/srs_apkg_import_bench_test.dart' show benchApkg;
import 'apkg/srs_apkg_import_test.dart' show kFullOptions;

const String _uid = '01928c3e-0000-7000-8000-0000000a5e02';

Future<(SrsDbStore, SrsRemoteReviewService, String)> _setUp() async {
  int clock = DateTime.utc(2026, 11, 1, 12).millisecondsSinceEpoch;
  final SrsDbStore store = await openTestStore(
    profileUid: _uid,
    deviceId: 'host',
    now: () => clock += 1000,
  );
  await importAnkiPackage(
    store: store,
    bytes: benchApkg(6),
    storeMedia: (String name, Uint8List b) async => name,
    options: kFullOptions,
    zstdDecompress: (Uint8List b) => null,
  );
  final SrsRemoteReviewService service = SrsRemoteReviewService(
    readStore: () async => store,
    readMedia: (String name) async =>
        name == 'a.png' ? Uint8List.fromList(<int>[1, 2, 3]) : null,
  );
  final String deck = (await store.deckSummaries())
      .where((SrsDeckSummary d) => d.totalCards > 0)
      .first
      .deck
      .id;
  return (store, service, deck);
}

Map<String, Object?> _firstCard(Map<String, Object?> payload) =>
    ((payload['cards']! as List).first as Map).cast<String, Object?>();

void main() {
  test('next 给下一张与预取，卡带排程预览与陈旧标记', () async {
    final (_, SrsRemoteReviewService service, String deck) = await _setUp();
    final Map<String, Object?> decks = await service.decks();
    expect(decks['profile'], _uid);
    expect((decks['decks']! as List), isNotEmpty);

    final Map<String, Object?> next = await service.next(
      profile: _uid,
      deck: deck,
    );
    final List<Object?> cards = next['cards']! as List;
    expect(cards, hasLength(2));
    final Map<String, Object?> card = _firstCard(next);
    expect(card['plan'], hasLength(4));
    expect(card['question'], isA<String>());
    expect(card.containsKey('base'), isTrue);
    final Map<Object?, Object?> counts = next['counts']! as Map;
    expect(
      (counts['new']! as int) +
          (counts['learn']! as int) +
          (counts['review']! as int),
      greaterThan(0),
    );
  });

  test('同一请求 id 重发只记一条日志，回包相同', () async {
    final (SrsDbStore store, SrsRemoteReviewService service, String deck) =
        await _setUp();
    final Map<String, Object?> card = _firstCard(
      await service.next(profile: _uid, deck: deck),
    );
    final String id = card['id']! as String;
    final int before = (await store.history(id)).all.length;
    Future<Map<String, Object?>> send() => service.answer(
      profile: _uid,
      request: 'req-1',
      deck: deck,
      card: id,
      base: card['base'] as String?,
      rating: 3,
      durationMs: 999999,
    );
    // 并发重发与事后重发都只落一次。
    final List<Map<String, Object?>> first = await Future.wait(
      <Future<Map<String, Object?>>>[send(), send()],
    );
    final Map<String, Object?> again = await send();
    expect(first[0]['logId'], first[1]['logId']);
    expect(again['logId'], first[0]['logId']);
    final List<SrsReviewLog> logs = (await store.history(id)).all;
    expect(logs, hasLength(before + 1));
    expect(
      logs
          .singleWhere((SrsReviewLog l) => l.id == first[0]['logId'])
          .durationMs,
      kSrsMaxAnswerDurationMs,
    );
  });

  test('出卡后卡被复习过：作答回 stale，不记日志', () async {
    final (SrsDbStore store, SrsRemoteReviewService service, String deck) =
        await _setUp();
    final Map<String, Object?> card = _firstCard(
      await service.next(profile: _uid, deck: deck),
    );
    final String id = card['id']! as String;
    // host 自己（或别的设备同步来）先复习了这张。
    await store.answer(id, 4);
    final int before = (await store.history(id)).all.length;
    await expectLater(
      service.answer(
        profile: _uid,
        request: 'req-stale',
        deck: deck,
        card: id,
        base: card['base'] as String?,
        rating: 1,
        durationMs: 1000,
      ),
      throwsA(
        isA<SrsRemoteReviewError>().having(
          (SrsRemoteReviewError e) => e.code,
          'code',
          SrsRemoteReviewError.stale,
        ),
      ),
    );
    expect((await store.history(id)).all, hasLength(before));
  });

  test('host 换了配置：回 profile_changed', () async {
    final (_, SrsRemoteReviewService service, String deck) = await _setUp();
    await expectLater(
      service.next(profile: 'another-profile', deck: deck),
      throwsA(
        isA<SrsRemoteReviewError>().having(
          (SrsRemoteReviewError e) => e.code,
          'code',
          SrsRemoteReviewError.profileChanged,
        ),
      ),
    );
  });

  test('撤销本会话的评分后带回这张卡；再撤一次 ok=false', () async {
    final (SrsDbStore store, SrsRemoteReviewService service, String deck) =
        await _setUp();
    final Map<String, Object?> card = _firstCard(
      await service.next(profile: _uid, deck: deck),
    );
    final String id = card['id']! as String;
    final int reps = (await store.cardRow(id))!.reps;
    final Map<String, Object?> answered = await service.answer(
      profile: _uid,
      request: 'req-undo',
      deck: deck,
      card: id,
      base: card['base'] as String?,
      rating: 3,
      durationMs: 1000,
    );
    final Map<String, Object?> undone = await service.undo(
      profile: _uid,
      card: id,
      log: answered['logId']! as String,
    );
    expect(undone['ok'], isTrue);
    expect(((undone['card']! as Map)['id']), id);
    final Map<String, Object?> twice = await service.undo(
      profile: _uid,
      card: id,
      log: answered['logId']! as String,
    );
    expect(twice['ok'], isFalse);
    expect((await store.cardRow(id))!.reps, reps);
  });

  group('路由', () {
    Future<shelf.Response> call(
      SrsRemoteReviewService service,
      String method,
      String op, [
      Object? body,
    ]) => handleSrsRemoteReviewRequest(
      service,
      shelf.Request(
        method,
        Uri.parse('http://host$kSrsRemoteReviewPathPrefix$op'),
        body: body == null ? null : jsonEncode(body),
      ),
      method,
      '$kSrsRemoteReviewPathPrefix$op',
    );

    test('JSON 往返与错误码', () async {
      final (_, SrsRemoteReviewService service, String deck) = await _setUp();
      final shelf.Response next = await call(service, 'POST', 'next', {
        'profile': _uid,
        'deck': deck,
      });
      expect(next.statusCode, 200);
      final Map<String, Object?> json =
          jsonDecode(await next.readAsString()) as Map<String, Object?>;
      expect(json['cards'], hasLength(2));

      final shelf.Response missing = await call(service, 'POST', 'answer', {
        'deck': deck,
      });
      expect(missing.statusCode, 400);
      expect(jsonDecode(await missing.readAsString()), {
        'error': SrsRemoteReviewError.badRequest,
      });

      final shelf.Response changed = await call(service, 'POST', 'decks', {});
      expect(changed.statusCode, 200);

      final shelf.Response wrong = await call(service, 'POST', 'next', {
        'profile': 'x',
        'deck': deck,
      });
      expect(wrong.statusCode, 409);
      expect(jsonDecode(await wrong.readAsString()), {
        'error': SrsRemoteReviewError.profileChanged,
      });

      expect((await call(service, 'GET', 'next')).statusCode, 405);
      final shelf.Response media = await call(service, 'GET', 'media/a.png');
      expect(media.statusCode, 200);
      expect(media.headers['content-type'], 'image/png');
      expect((await call(service, 'GET', 'media/b.png')).statusCode, 404);
    });

    test('复习模块不可用：503 unavailable', () async {
      final SrsRemoteReviewService off = SrsRemoteReviewService(
        readStore: () async => null,
        readMedia: (String _) async => null,
      );
      final shelf.Response r = await call(off, 'POST', 'decks', {});
      expect(r.statusCode, 503);
      expect(jsonDecode(await r.readAsString()), {
        'error': SrsRemoteReviewError.unavailable,
      });
    });
  });
}
