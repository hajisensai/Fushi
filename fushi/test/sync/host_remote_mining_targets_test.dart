// §4.8「保存到」在 app 当互联主机时：`POST /api/mine/targets` 列出本机真能写的地方（激活配置 + 已有复习数据的
// 配置的复习与牌组、拉到过牌组清单的 Anki），`/api/mine`、`/api/mine/forward`、`/api/duplicate` 的 `target`
// 照办；显式点名却给不了的落主机默认并报 `targetUnavailable`，只带手机自己 profile 的「主机默认」不报。
//
// 装配与 main.dart 同形：AppModel 的生产工厂 `createRemoteMiningService()` 给出互联服务，经引擎的路由处理函数
// 调用；复习是真实 srs.db + Rust 内核（SrsProfileStores 按 uid 开副本），只有平台 Anki 后端是内存替身。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi/src/srs/srs_profile_stores.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/remote_mining_target.dart';
import 'package:fushi_srs/fushi_srs.dart';

import '../helpers/fake_platform_services.dart';
import '../srs/srs_test_support.dart';

const String _uidA = '01928c3e-0000-7000-8000-00000000000a';
const String _uidB = '01928c3e-0000-7000-8000-00000000000b';
const String _uidC = '01928c3e-0000-7000-8000-00000000000c';

/// 主机本机的 Anki 后端替身：牌组清单可拨；按单卡牌组覆盖落卡（覆盖不在清单里就落默认牌组 `Mining`，
/// 与 AnkiConnect 后端 `resolveTargetDeck` 同口径）。
class _HostAnki extends BaseAnkiRepository {
  List<String> decks = const <String>['Mining', 'Core'];
  final List<String> minedPayloads = <String>[];
  int duplicateChecks = 0;

  @override
  Future<AnkiSettings> loadSettings() async => AnkiSettings(
    availableDecks: <AnkiDeck>[
      for (int i = 0; i < decks.length; i++)
        AnkiDeck(id: i + 1, name: decks[i]),
    ],
  );

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    minedPayloads.add(rawPayloadJson);
    final String? asked = MiningRequestOverrides.readFrom(
      jsonDecode(rawPayloadJson) as Map<String, dynamic>,
    )?.deckName;
    return MineOutcome.success(
      deckName: asked != null && decks.contains(asked) ? asked : 'Mining',
    );
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    duplicateChecks++;
    return false;
  }

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

/// 主机挖词目标钉死成 [target]。
class _HostAppModel extends AppModel {
  _HostAppModel(super.platformServices, this.target);

  SrsMiningTarget target;

  @override
  SrsMiningTarget get hostSrsMiningTarget => target;
}

Map<String, String> _fields(String expression, String reading) =>
    <String, String>{
      'expression': expression,
      'reading': reading,
      'glossary': '<ol><li>x</li></ol>',
      'glossaryFirst': '<ol><li>x</li></ol>',
    };

Map<String, dynamic> _mineBody(
  String expression,
  String reading, [
  RemoteMiningTarget? target,
]) => <String, dynamic>{
  'fields': _fields(expression, reading),
  'sentence': '$expression。',
  'target': ?target?.toJson(),
};

/// 互联对端的一次 POST（与 fushi_sync_server_mine_test 同一鉴权形状）。
Future<(int, Map<String, dynamic>?)> _post(
  int port,
  String path,
  Object body,
) async {
  final HttpClient c = HttpClient();
  try {
    final HttpClientRequest r = await c.post('127.0.0.1', port, path);
    r.headers.set(
      'authorization',
      'Basic ${base64Encode(utf8.encode('hibiki:tok'))}',
    );
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode(body));
    final HttpClientResponse resp = await r.close();
    final String text = await resp.transform(utf8.decoder).join();
    return (
      resp.statusCode,
      resp.statusCode == 200 ? jsonDecode(text) as Map<String, dynamic> : null,
    );
  } finally {
    c.close(force: true);
  }
}

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SrsStorage storage;
  late SrsProfileStores stores;
  late _HostAnki anki;
  late _HostAppModel app;
  late int revisionBumps;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_host_save_to_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 句柄滞后：临时目录留给系统清理。
      }
    });
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // A 最早建 = 激活配置（没有 active_profile_id 偏好时的兜底）。C 从没用过复习。
    for (final (String name, String uid) in <(String, String)>[
      ('Japanese', _uidA),
      ('Chinese', _uidB),
      ('Korean', _uidC),
    ]) {
      await db.insertProfile(
        ProfilesCompanion.insert(
          name: name,
          uid: Value<String?>(uid),
          createdAt: 0,
          updatedAt: 0,
        ),
      );
    }
    storage = await openSrsTestStorage();
    stores = SrsProfileStores(
      SrsProfileStoresDeps(
        storage: () async => storage,
        deviceId: () async => 'host',
        supportRoot: () async => tmp,
        engine: () => const SrsTestEngine(),
      ),
    );
    await stores.activate(
      _uidA,
      () => SrsDbStore.open(
        db: storage.db,
        core: storage.core,
        profileUid: _uidA,
        deviceId: 'host',
        engine: const SrsTestEngine(),
      ),
    );
    // B 有复习数据（同步来过 / 制过卡）：一个牌组。
    final SrsDbStore storeB = (await stores.minerFor(
      profileUid: _uidB,
      destination: const SrsMiningDestination(),
      fallbackRolloverHour: () => 4,
    ))!.store;
    await storeB.createDeck('Grammar');

    anki = _HostAnki();
    app = _HostAppModel(
      fakePlatformServices(createAnkiRepository: () => anki),
      SrsMiningTarget.anki,
    );
    app.wireDatabaseForTesting(db);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    app.wireLocalAudioForTesting(
      prefsRepo: prefs,
      databaseDirectory: Directory('${tmp.path}/db')..createSync(),
    );
    await app.setModuleEnabled(ModuleId.srs, true);
    app.srsProfileStoresReader = () => stores;
    revisionBumps = 0;
    app.srsCardsAddedNotifier = () => revisionBumps++;
    // 主机默认那条链（main.dart 里读 hostMiningAnkiRepositoryProvider）：目标是复习时套激活配置的复习。
    app.hostMiningRepositoryReader = () => app.target == SrsMiningTarget.srs
        ? SrsMiningAnkiRepository(
            inner: anki,
            miner: () => stores.minerFor(
              profileUid: _uidA,
              destination: const SrsMiningDestination(),
              fallbackRolloverHour: () => 4,
            ),
          )
        : anki;
  });

  Future<bool> hasTerm(String uid, String expression, String reading) async {
    final SrsDbStore store = (await stores.minerFor(
      profileUid: uid,
      destination: const SrsMiningDestination(),
      fallbackRolloverHour: () => 4,
    ))!.store;
    return (await store.lookupTermStatus(<SrsTermQuery>[
      SrsTermQuery(expression, reading),
    ])).isNotEmpty;
  }

  FushiRemoteMiningService service() => app.createRemoteMiningService();

  group('POST /api/mine/targets', () {
    test('互联服务实现了「保存到」（路由据此挂 /api/mine/targets）', () {
      expect(service(), isA<FushiRemoteMiningTargetService>());
    });

    test('列出激活配置与已有复习的配置（含牌组），从没用过复习的配置不列、也不因列表建出副本；Anki 列牌组', () async {
      final Map<String, Object?> json =
          await (service() as FushiRemoteMiningTargetService).miningTargets();

      expect(json['default'], <String, Object?>{'kind': kRemoteMiningKindAnki});
      final List<Map<String, Object?>> review =
          (json['review']! as List<Object?>).cast<Map<String, Object?>>();
      expect(review.map((Map<String, Object?> p) => p['profile']), <String>[
        _uidA,
        _uidB,
      ]);
      expect(review[0]['name'], 'Japanese');
      expect(review[1]['name'], 'Chinese');
      expect(review[1]['decks'], contains('Grammar'));
      expect(
        await stores.hasReviewData(_uidC),
        isFalse,
        reason: '列「保存到」不得给没用过复习的配置建复习',
      );
      expect(json['anki'], <String, Object?>{
        'decks': <String>['Mining', 'Core'],
      });
    });

    test('主机默认是复习：default 带激活配置与它的制卡牌组', () async {
      app.target = SrsMiningTarget.srs;
      final Map<String, Object?> json =
          await (service() as FushiRemoteMiningTargetService).miningTargets();
      final Map<String, Object?> def = json['default']! as Map<String, Object?>;
      expect(def['kind'], kRemoteMiningKindReview);
      expect(def['profile'], _uidA);
      expect(def['deck'], isNotNull);
    });

    test('Anki 没拉到过牌组：不列 Anki', () async {
      anki.decks = const <String>[];
      final Map<String, Object?> json =
          await (service() as FushiRemoteMiningTargetService).miningTargets();
      expect(json.containsKey('anki'), isFalse);
    });

    test('复习模块关着：不列复习', () async {
      await app.setModuleEnabled(ModuleId.srs, false);
      final Map<String, Object?> json =
          await (service() as FushiRemoteMiningTargetService).miningTargets();
      expect(json['review'], isEmpty);
      expect(json['default'], <String, Object?>{'kind': kRemoteMiningKindAnki});
    });
  });

  group('/api/mine 带 target', () {
    test('显式复习 + 非激活配置 + 牌组：卡进那份复习的那个牌组，不写 Anki', () async {
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _mineBody(
          '猫',
          'ねこ',
          const RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: _uidB,
            deck: 'Grammar',
          ),
        ),
        mining: service(),
      );

      expect(out['result'], MineResult.success.name);
      expect(out['landed'], <String, Object?>{
        'kind': kRemoteMiningKindReview,
        'profile': _uidB,
        'deck': 'Grammar',
      });
      expect(out.containsKey('targetUnavailable'), isFalse);
      expect(anki.minedPayloads, isEmpty);
      expect(await hasTerm(_uidB, '猫', 'ねこ'), isTrue);
      expect(await hasTerm(_uidA, '猫', 'ねこ'), isFalse);
    });

    test('主机默认是 Anki、手机点名激活配置的复习：落激活配置复习并刷新牌组计数', () async {
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _mineBody(
          '犬',
          'いぬ',
          const RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: _uidA,
          ),
        ),
        mining: service(),
      );

      expect(out['result'], MineResult.success.name);
      expect((out['landed'] as Map<String, Object?>)['profile'], _uidA);
      expect(anki.minedPayloads, isEmpty);
      expect(await hasTerm(_uidA, '犬', 'いぬ'), isTrue);
      expect(revisionBumps, 1);
    });

    test('显式 Anki 牌组：牌组写进单卡覆盖，landed 带它', () async {
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _mineBody(
          '鳥',
          'とり',
          const RemoteMiningTarget(kind: kRemoteMiningKindAnki, deck: 'Core'),
        ),
        mining: service(),
      );

      expect(out['landed'], <String, Object?>{
        'kind': kRemoteMiningKindAnki,
        'deck': 'Core',
      });
      expect(out.containsKey('targetUnavailable'), isFalse);
      expect(anki.minedPayloads, hasLength(1));
      expect(
        MiningRequestOverrides.readFrom(
          jsonDecode(anki.minedPayloads.single) as Map<String, dynamic>,
        )?.deckName,
        'Core',
      );
    });

    test('点名的 Anki 牌组主机没有：整个退回主机默认（不写那个牌组覆盖）并报 targetUnavailable', () async {
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _mineBody(
          '魚',
          'さかな',
          const RemoteMiningTarget(kind: kRemoteMiningKindAnki, deck: 'Gone'),
        ),
        mining: service(),
      );

      expect(out['result'], MineResult.success.name);
      expect((out['landed'] as Map<String, Object?>)['deck'], 'Mining');
      expect(out['targetUnavailable'], isTrue);
      expect(
        MiningRequestOverrides.readFrom(
          jsonDecode(anki.minedPayloads.single) as Map<String, dynamic>,
        )?.deckName,
        isNull,
      );
    });

    test(
      '点名的复习牌组被删（主机默认是 Anki）：卡进主机默认 Anki、不进那份 profile，报 targetUnavailable；查重同一落点',
      () async {
        const RemoteMiningTarget gone = RemoteMiningTarget(
          kind: kRemoteMiningKindReview,
          profile: _uidB,
          deck: 'Deleted deck',
        );
        final Map<String, dynamic> out = await buildRemoteMineResponse(
          _mineBody('鯨', 'くじら', gone),
          mining: service(),
        );

        expect(out['result'], MineResult.success.name);
        expect(out['targetUnavailable'], isTrue);
        expect(out['landed'], <String, Object?>{
          'kind': kRemoteMiningKindAnki,
          'deck': 'Mining',
        });
        expect(anki.minedPayloads, hasLength(1));
        expect(await hasTerm(_uidB, '鯨', 'くじら'), isFalse);

        final int before = anki.duplicateChecks;
        await buildRemoteDuplicateResponse(<String, dynamic>{
          'expression': '鯨',
          'reading': 'くじら',
          'target': gone.toJson(),
        }, mining: service());
        expect(anki.duplicateChecks, before + 1, reason: '查重查的是主机默认（Anki）');
      },
    );

    test('点名的复习牌组被删（主机默认是复习）：卡进激活配置复习，不进点名 profile；查重看得见', () async {
      app.target = SrsMiningTarget.srs;
      const RemoteMiningTarget gone = RemoteMiningTarget(
        kind: kRemoteMiningKindReview,
        profile: _uidB,
        deck: 'Deleted deck',
      );
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _mineBody('蛍', 'ほたる', gone),
        mining: service(),
      );

      expect(out['result'], MineResult.success.name, reason: '$out');
      expect(out['targetUnavailable'], isTrue);
      expect((out['landed'] as Map<String, Object?>)['profile'], _uidA);
      expect(await hasTerm(_uidA, '蛍', 'ほたる'), isTrue);
      expect(await hasTerm(_uidB, '蛍', 'ほたる'), isFalse);
      expect(anki.minedPayloads, isEmpty);
      expect(
        (await buildRemoteDuplicateResponse(<String, dynamic>{
          'expression': '蛍',
          'reading': 'ほたる',
          'target': gone.toJson(),
        }, mining: service()))['duplicate'],
        isTrue,
      );
    });

    test('点名的配置主机没有：整个退回主机默认（这里是 Anki）并报 targetUnavailable', () async {
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _mineBody(
          '馬',
          'うま',
          const RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: _uidC,
            deck: 'Grammar',
          ),
        ),
        mining: service(),
      );

      // 拍板 2026-11-08：不保留所点的复习类别，落主机默认。
      expect(out['targetUnavailable'], isTrue);
      expect(
        (out['landed'] as Map<String, Object?>)['kind'],
        kRemoteMiningKindAnki,
      );
      expect(anki.minedPayloads, hasLength(1));
      expect(await hasTerm(_uidA, '馬', 'うま'), isFalse);
      expect(await hasTerm(_uidB, '馬', 'うま'), isFalse);
    });

    test('复习模块关着时点名复习：退到 Anki 并报 targetUnavailable', () async {
      await app.setModuleEnabled(ModuleId.srs, false);
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _mineBody(
          '牛',
          'うし',
          const RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: _uidB,
          ),
        ),
        mining: service(),
      );

      expect(out['targetUnavailable'], isTrue);
      expect(
        (out['landed'] as Map<String, Object?>)['kind'],
        kRemoteMiningKindAnki,
      );
      expect(anki.minedPayloads, hasLength(1));
    });

    test('「主机默认」（只带手机自己的 profile，主机没有那份）：落主机默认，不报退回', () async {
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _mineBody(
          '羊',
          'ひつじ',
          const RemoteMiningTarget(profile: 'phone-only-profile'),
        ),
        mining: service(),
      );

      expect(out['result'], MineResult.success.name);
      expect(out['landed'], <String, Object?>{
        'kind': kRemoteMiningKindAnki,
        'deck': 'Mining',
      });
      expect(out.containsKey('targetUnavailable'), isFalse);
      expect(anki.minedPayloads, hasLength(1));
    });

    test('主机默认是复习、手机带自己的 profile（主机也有）：落那份配置的复习', () async {
      app.target = SrsMiningTarget.srs;
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _mineBody('桜', 'さくら', const RemoteMiningTarget(profile: _uidB)),
        mining: service(),
      );

      expect(out['result'], MineResult.success.name);
      expect((out['landed'] as Map<String, Object?>)['profile'], _uidB);
      expect(out.containsKey('targetUnavailable'), isFalse);
      expect(await hasTerm(_uidB, '桜', 'さくら'), isTrue);
    });

    test('不带 target（老客户端 / 浏览器扩展）：走主机默认那条链，回包不带 landed', () async {
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _mineBody('月', 'つき'),
        mining: service(),
      );

      expect(out['result'], MineResult.success.name);
      expect(out.containsKey('landed'), isFalse);
      expect(out.containsKey('targetUnavailable'), isFalse);
      expect(anki.minedPayloads, hasLength(1));
    });
  });

  test('/api/mine/forward 带 target：转发来的卡进点名的复习', () async {
    final Map<String, dynamic> out = await buildForwardedMineResponse(
      <String, dynamic>{
        ...ForwardedMinePayload(
          rawPayloadJson: jsonEncode(_fields('星', 'ほし')),
          sentence: '星が見える。',
          documentTitle: 'Night',
          coverBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
          coverExt: 'png',
        ).toJson(),
        'target': const RemoteMiningTarget(
          kind: kRemoteMiningKindReview,
          profile: _uidB,
        ).toJson(),
      },
      mining: service(),
    );

    expect(out['result'], MineResult.success.name, reason: '$out');
    expect((out['landed'] as Map<String, Object?>)['profile'], _uidB);
    expect(anki.minedPayloads, isEmpty);
    expect(await hasTerm(_uidB, '星', 'ほし'), isTrue);
  });

  test('/api/duplicate 按 target 判：点名的复习里有就是重复，Anki / 别的配置另算', () async {
    final FushiRemoteMiningService svc = service();
    await buildRemoteMineResponse(
      _mineBody(
        '空',
        'そら',
        const RemoteMiningTarget(kind: kRemoteMiningKindReview, profile: _uidB),
      ),
      mining: svc,
    );

    Future<Object?> dup(RemoteMiningTarget? target) async =>
        (await buildRemoteDuplicateResponse(<String, dynamic>{
          'expression': '空',
          'reading': 'そら',
          'target': ?target?.toJson(),
        }, mining: svc))['duplicate'];

    expect(
      await dup(
        const RemoteMiningTarget(kind: kRemoteMiningKindReview, profile: _uidB),
      ),
      isTrue,
    );
    expect(
      await dup(
        const RemoteMiningTarget(kind: kRemoteMiningKindReview, profile: _uidA),
      ),
      isFalse,
    );
    final int before = anki.duplicateChecks;
    expect(
      await dup(const RemoteMiningTarget(kind: kRemoteMiningKindAnki)),
      isFalse,
    );
    expect(anki.duplicateChecks, before + 1, reason: 'Anki 目标问本机 Anki');
    expect(await dup(null), isFalse, reason: '不带 target：主机默认（Anki）');
  });

  test(
    '经真实互联服务（FushiSyncServer，与桌面 host 同一个类）：/api/mine/targets 回清单，/api/mine 照 target 落卡',
    () async {
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: Directory('${tmp.path}/sync').path,
        port: 0,
        token: 'tok',
        miningService: service(),
      );
      await server.start();
      addTearDown(server.stop);

      final (int code, Map<String, dynamic>? targets) = await _post(
        server.port,
        '/api/mine/targets',
        <String, Object?>{},
      );
      expect(code, 200);
      expect(
        (targets!['review'] as List<dynamic>).map(
          (dynamic p) => (p as Map<String, dynamic>)['profile'],
        ),
        <String>[_uidA, _uidB],
      );
      expect((targets['anki'] as Map<String, dynamic>)['decks'], <String>[
        'Mining',
        'Core',
      ]);

      final (int mineCode, Map<String, dynamic>? mined) = await _post(
        server.port,
        '/api/mine',
        _mineBody(
          '光',
          'ひかり',
          const RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: _uidB,
            deck: 'Grammar',
          ),
        ),
      );
      expect(mineCode, 200);
      expect(mined!['result'], MineResult.success.name);
      expect(mined['landed'], <String, dynamic>{
        'kind': kRemoteMiningKindReview,
        'profile': _uidB,
        'deck': 'Grammar',
      });
      expect(await hasTerm(_uidB, '光', 'ひかり'), isTrue);
    },
  );
}
