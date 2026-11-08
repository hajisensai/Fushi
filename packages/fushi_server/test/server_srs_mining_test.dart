// 互联制卡落到服务端复习库（docs/specs/2026-11-05-server-srs-design.md §4.8）：没配 Anki 时默认进复习；手机可在
// 请求里挑 profile 与牌组，回包说实际落到了哪；服务端没有所选的就退回默认并如实说；查重按卡要去的地方判。
import 'dart:io';

import 'package:fushi_core/fushi_core.dart' show SrsNoteCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/remote_mining_host.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String kJa = '01928c3e-0000-7000-8000-00000000a0a0';
const String kZh = '01928c3e-0000-7000-8000-00000000b0b0';

void main() {
  late Directory tmp;
  late ServerSrs srs;
  late ServerRemoteMiningService mining;
  ServerSrsConfig config = const ServerSrsConfig();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_srs_mine_');
    config = const ServerSrsConfig(profiles: <String>[kJa, kZh]);
    srs = ServerSrs(
      support: Directory(p.join(tmp.path, 'support'))..createSync(),
      syncData: Directory(p.join(tmp.path, 'interconnect'))..createSync(),
      deviceId: 'server-device',
      hostId: 'host',
      config: () => config,
      engine: () => null,
    );
    await srs.start();
    await srs.syncNow();
    // 没带 fushi-anki-sync：只有复习。
    mining = ServerRemoteMiningService(srs: srs, srsConfig: () => config);
  });

  tearDown(() async {
    await srs.stop();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  Future<Map<String, dynamic>> mine(
    String expression, {
    Map<String, Object?>? target,
  }) => buildRemoteMineResponse(<String, dynamic>{
    'fields': <String, Object?>{
      'expression': expression,
      'reading': '',
      'glossary': 'meaning of $expression',
    },
    'sentence': '$expression。',
    'target': ?target,
  }, mining: mining);

  Future<bool> duplicate(
    String expression, {
    Map<String, Object?>? target,
  }) async =>
      (await buildRemoteDuplicateResponse(<String, dynamic>{
            'expression': expression,
            'target': ?target,
          }, mining: mining))['duplicate']
          as bool;

  Future<int> notes(String uid) => srs.storeFor(uid)!.userNoteCount();

  Future<String?> deckOfOnlyNote(String uid) async {
    final SrsDbStore store = srs.storeFor(uid)!;
    final List<SrsNoteCacheRow> rows = await (store.db.select(
      store.db.srsNotesCache,
    )..where((n) => n.profileUid.equals(uid))).get();
    final List<String> cardDecks = <String>[
      for (final SrsNoteCacheRow r in rows)
        for (final c in await store.cardsOfNote(r.id)) c.deckId,
    ];
    if (cardDecks.isEmpty) return null;
    return (await store.deckTree()).fullName(cardDecks.first);
  }

  test('没配 Anki：默认进默认 profile 的复习库，回包说落到了哪；之后查重为真', () async {
    expect(await duplicate('食べる'), isFalse);
    final Map<String, dynamic> r = await mine('食べる');
    expect(r['result'], 'success', reason: '$r');
    expect((r['landed'] as Map)['kind'], 'review');
    expect((r['landed'] as Map)['profile'], kJa);
    expect(await notes(kJa), 1);
    expect(await notes(kZh), 0);
    expect(await duplicate('食べる'), isTrue);
  });

  test('手机挑了中文那份的某个牌组：卡落在那里；查重也按那份判', () async {
    final SrsDbStore zh = srs.storeFor(kZh)!;
    await zh.createDeck('Mining');
    final Map<String, dynamic> r = await mine(
      '吃饭',
      target: <String, Object?>{
        'kind': 'review',
        'profile': kZh,
        'deck': 'Mining',
      },
    );
    expect(r['result'], 'success', reason: '$r');
    expect(r['landed'], <String, Object?>{
      'kind': 'review',
      'profile': kZh,
      'deck': 'Mining',
    });
    expect(await deckOfOnlyNote(kZh), 'Mining');
    expect(await notes(kJa), 0);
    expect(
      await duplicate('吃饭', target: <String, Object?>{'profile': kZh}),
      isTrue,
    );
    expect(
      await duplicate('吃饭', target: <String, Object?>{'profile': kJa}),
      isFalse,
      reason: '日语那份里没有',
    );
  });

  test('服务端没有所选的 profile / 牌组：退回默认并如实说；所选 Anki 不可用时退到复习', () async {
    final Map<String, dynamic> unknown = await mine(
      '飲む',
      target: <String, Object?>{
        'profile': '01928c3e-0000-7000-8000-00000000dead',
        'deck': 'Nope',
      },
    );
    expect(unknown['result'], 'success');
    expect((unknown['landed'] as Map)['profile'], kJa);
    expect(unknown['targetUnavailable'], isTrue, reason: '点名了牌组 = 显式选择，退回要如实说');
    expect(await notes(kJa), 1);

    // 只带手机自己的 profile uid（= 主机默认）：服务端没有那份就落默认 profile，不算退回。
    final Map<String, dynamic> own = await mine(
      '書く',
      target: <String, Object?>{
        'profile': '01928c3e-0000-7000-8000-00000000beef',
      },
    );
    expect((own['landed'] as Map)['profile'], kJa);
    expect(own.containsKey('targetUnavailable'), isFalse);

    final Map<String, dynamic> anki = await mine(
      '走る',
      target: <String, Object?>{'kind': 'anki'},
    );
    expect(anki['result'], 'success');
    expect((anki['landed'] as Map)['kind'], 'review');
    expect(anki['targetUnavailable'], isTrue);
  });

  test(
    'mining_decks 按牌组全名生效；手机点名的牌组主机没有 → 整个退回服务端默认并报 targetUnavailable',
    () async {
      final SrsDbStore ja = srs.storeFor(kJa)!;
      await ja.createDeck('Configured');
      config = ServerSrsConfig(
        profiles: const <String>[kJa, kZh],
        miningDecks: const <String, String>{kJa: 'Configured'},
      );
      final Map<String, dynamic> r = await mine('泳ぐ');
      expect(r['result'], 'success', reason: '$r');
      expect((r['landed'] as Map)['deck'], 'Configured');
      expect(await deckOfOnlyNote(kJa), 'Configured');
      expect((await mining.miningTargets())['default'], <String, Object?>{
        'kind': 'review',
        'profile': kJa,
        'deck': 'Configured',
      });

      final Map<String, dynamic> gone = await mine(
        '歌う',
        target: <String, Object?>{
          'kind': 'review',
          'profile': kJa,
          'deck': 'Deleted deck',
        },
      );
      expect(gone['result'], 'success');
      expect(gone['targetUnavailable'], isTrue, reason: '$gone');
      expect(gone['landed'], <String, Object?>{
        'kind': 'review',
        'profile': kJa,
        'deck': 'Configured',
      });

      // 点名别的 profile 里一个已删的牌组：不落那份 profile 的默认牌组，整个退回服务端默认（日语、Configured）。
      final int zhBefore = await notes(kZh);
      final Map<String, dynamic> goneZh = await mine(
        '跑',
        target: <String, Object?>{
          'kind': 'review',
          'profile': kZh,
          'deck': 'Deleted deck',
        },
      );
      expect(goneZh['result'], 'success', reason: '$goneZh');
      expect(goneZh['targetUnavailable'], isTrue);
      expect(goneZh['landed'], <String, Object?>{
        'kind': 'review',
        'profile': kJa,
        'deck': 'Configured',
      });
      expect(await notes(kZh), zhBefore, reason: '卡不该进点名 profile 的默认牌组');
      // 查重同一口径：查的是服务端默认（日语）那一份。
      expect(
        await duplicate(
          '跑',
          target: <String, Object?>{
            'kind': 'review',
            'profile': kZh,
            'deck': 'Deleted deck',
          },
        ),
        isTrue,
      );
    },
  );

  test('/api/mine/targets 列出服务提供的 profile 与牌组；没有 Anki 时不带 anki', () async {
    await srs.storeFor(kZh)!.createDeck('Mining');
    final Map<String, Object?> t = await mining.miningTargets();
    expect(t['default'], <String, Object?>{'kind': 'review', 'profile': kJa});
    final List<Object?> review = t['review']! as List<Object?>;
    expect(review.map((Object? e) => (e! as Map)['profile']), <String>[
      kJa,
      kZh,
    ]);
    expect((review.last! as Map)['decks'], contains('Mining'));
    expect(t.containsKey('anki'), isFalse);

    // 复习关了、也没有 Anki：制卡回 notConfigured，查重为假。
    config = const ServerSrsConfig();
    await srs.applyConfig();
    expect((await mine('見る'))['result'], 'notConfigured');
    expect(await duplicate('食べる'), isFalse);
  });
}
