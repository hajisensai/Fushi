import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/ops/ctl_settings_body_tracking.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 媒体追踪页的控制通道条目：令牌只经 secret 参数、连接 / 建映射 / 删映射真写穿，
/// 输出不带令牌；网络全走假 Bangumi API。
class _FakeBangumiApi implements BangumiTrackingApi {
  bool rejectToken = false;
  final List<({String keyword, int subjectType})> searches =
      <({String keyword, int subjectType})>[];
  final List<int> subjectLookups = <int>[];

  @override
  Future<BangumiUser> getMe() async {
    if (rejectToken) {
      throw const BangumiApiException(statusCode: 401, message: 'unauthorized');
    }
    return const BangumiUser(username: 'alice', nickname: 'Alice');
  }

  @override
  Future<List<BangumiSubject>> searchSubjects({
    required String keyword,
    required int subjectType,
  }) async {
    searches.add((keyword: keyword, subjectType: subjectType));
    return const <BangumiSubject>[
      BangumiSubject(
        id: 42,
        type: 4,
        name: 'Remote Game',
        nameCn: '远端游戏',
        platform: 'PC',
        episodeCount: 0,
        volumeCount: 0,
      ),
    ];
  }

  @override
  Future<BangumiSubject> getSubject(int subjectId) async {
    subjectLookups.add(subjectId);
    return BangumiSubject(
      id: subjectId,
      type: 4,
      name: 'Remote Game',
      nameCn: '远端游戏',
      platform: 'PC',
      episodeCount: 0,
      volumeCount: 0,
    );
  }

  @override
  Future<List<BangumiWatchedItem>> getWatchedAnime(String username) async =>
      const <BangumiWatchedItem>[];

  @override
  Future<BangumiUserCollection?> getCollection(
    String username,
    int subjectId,
  ) async => null;

  @override
  Future<void> createCollection(
    int subjectId, {
    required Map<String, dynamic> payload,
  }) async {}

  @override
  Future<void> patchCollection(
    int subjectId, {
    required Map<String, dynamic> payload,
  }) async {}

  @override
  Future<List<BangumiEpisode>> getMainEpisodes(int subjectId) async =>
      const <BangumiEpisode>[];

  @override
  Future<void> markEpisodesDone(int subjectId, List<int> episodeIds) async {}

  @override
  void close() {}
}

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext sc;
  late _FakeBangumiApi api;
  late MediaTrackingService service;

  List<SettingsItem> items() =>
      buildCtlTrackingBodyPages().expand((CtlBodyPage p) => p.items).toList();

  SettingsCliAction action(String name) =>
      (items().singleWhere(
                (SettingsItem i) => i.id == '$kCtlTrackingIdPrefix$name',
              )
              as SettingsActionItem)
          .cli!;

  SettingsCliList mappings() =>
      (items().singleWhere(
                (SettingsItem i) => i.id == '${kCtlTrackingIdPrefix}mappings',
              )
              as SettingsCustomItem)
          .cliList!;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_tracking_cli_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    api = _FakeBangumiApi();
    service = MediaTrackingService(
      repository: MediaTrackingRepository(db),
      preferences: prefs,
      userAgent: 'test-agent',
      apiFactory: (_) => api,
    );
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db)
      ..wireMediaTrackingServiceForTesting(service);
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'g1',
        name: 'Local Game',
        exePath: '/g/1.exe',
        workdir: '/g',
        addedAt: 0,
      ),
    );
  });

  tearDown(() async {
    service.dispose();
    await db.close();
  });

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              sc = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  testWidgets('每个动作都有无交互入口，令牌参数标记为 secret', (WidgetTester tester) async {
    await pumpContext(tester);
    for (final SettingsActionItem a
        in items().whereType<SettingsActionItem>()) {
      expect(a.cli?.run, isNotNull, reason: a.id);
    }
    expect(
      action(
        'connect',
      ).params.singleWhere((SettingsCliParam p) => p.name == 'token').secret,
      isTrue,
    );
    final Set<String> ids = items().map((SettingsItem i) => i.id).toSet();
    expect(ids.length, items().length, reason: 'id 不能重复');
  });

  testWidgets('未连接：status 如实回报、需令牌的动作在发网络请求前拒绝', (WidgetTester tester) async {
    await pumpContext(tester);
    await tester.runAsync(() async {
      final Map<String, Object?> status =
          await action('status').run!(sc, const <String, String>{})
              as Map<String, Object?>;
      expect(status['configured'], isFalse);
      expect(status['accessTokenUrl'], BangumiApiClient.accessTokenUrl);

      await expectLater(
        action('connect').run!(sc, const <String, String>{'token': '  '}),
        throwsArgumentError,
      );
      await expectLater(
        action('sync_now').run!(sc, const <String, String>{}),
        throwsStateError,
      );
      await expectLater(
        action('search').run!(sc, const <String, String>{'keyword': 'x'}),
        throwsStateError,
      );
      await expectLater(
        mappings().add!(sc, const <String, String>{
          'media_type': 'game',
          'media_key': 'g1',
          'subject_id': '42',
        }),
        throwsStateError,
      );
      expect(api.searches, isEmpty);
    });
  });

  testWidgets('connect 校验失败不落令牌；成功后令牌与账号名写穿且输出不含令牌', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    await tester.runAsync(() async {
      api.rejectToken = true;
      await expectLater(
        action('connect').run!(sc, const <String, String>{'token': 'BAD'}),
        throwsA(isA<BangumiApiException>()),
      );
      expect(service.isConfigured, isFalse);

      api.rejectToken = false;
      final Object? result = await action('connect').run!(
        sc,
        const <String, String>{'token': 'SECRET-TOKEN'},
      );
      expect(jsonEncode(result), isNot(contains('SECRET-TOKEN')));
      expect((result! as Map<String, Object?>)['account'], 'Alice');
      expect(service.accessToken, 'SECRET-TOKEN');
      expect(service.accountName, 'Alice');

      final Object? status = await action('status').run!(
        sc,
        const <String, String>{},
      );
      expect(jsonEncode(status), isNot(contains('SECRET-TOKEN')));
      expect((status! as Map<String, Object?>)['configured'], isTrue);
    });
  });

  testWidgets('search / local_targets / mappings add·ls·rm 真写穿', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    await tester.runAsync(() async {
      await service.setAccessToken('TOKEN');

      final List<Object?> found =
          await action('search').run!(sc, const <String, String>{
                'keyword': 'Remote',
                'kind': 'game',
              })
              as List<Object?>;
      expect((found.single! as Map<String, Object?>)['id'], 42);
      expect(api.searches.single.keyword, 'Remote');
      await expectLater(
        action('search').run!(sc, const <String, String>{
          'keyword': 'x',
          'kind': 'movie',
        }),
        throwsArgumentError,
      );

      final List<Object?> targets =
          await action('local_targets').run!(sc, const <String, String>{
                'query': 'local',
              })
              as List<Object?>;
      final Map<String, Object?> game = targets.single! as Map<String, Object?>;
      expect(game['media_type'], 'game');
      expect(game['key'], 'g1');
      expect(game['kinds'], <String>['game']);

      // 参数校验：类型不允许的 kind / 不存在的本地条目都在落库前拒绝。
      await expectLater(
        mappings().add!(sc, const <String, String>{
          'media_type': 'game',
          'media_key': 'g1',
          'subject_id': '42',
          'kind': 'anime',
        }),
        throwsArgumentError,
      );
      await expectLater(
        mappings().add!(sc, const <String, String>{
          'media_type': 'game',
          'media_key': 'nope',
          'subject_id': '42',
        }),
        throwsArgumentError,
      );
      await expectLater(
        mappings().add!(sc, const <String, String>{
          'media_type': 'book_chapter',
          'media_key': 'g1',
          'subject_id': '42',
        }),
        throwsArgumentError,
      );

      final Map<String, Object?> added =
          await mappings().add!(sc, const <String, String>{
                'media_type': 'game',
                'media_key': 'g1',
                'subject_id': '42',
                'progress_offset': '7',
              })
              as Map<String, Object?>;
      expect(api.subjectLookups, <int>[42], reason: '没给 subject_name 时向远端补名');
      expect(added['subject_name'], '远端游戏');
      expect(added['progress_mode'], 'status');
      expect(added['progress_offset'], 0, reason: 'status 模式偏移钉死 0');

      final List<Map<String, Object?>> rows = await mappings().list(sc);
      expect(rows, hasLength(1));
      expect(rows.single['title'], 'Local Game');
      final String id = rows.single['id']! as String;

      await expectLater(mappings().remove!(sc, '999'), throwsArgumentError);
      await mappings().remove!(sc, id);
      expect(await MediaTrackingRepository(db).listMappings(), isEmpty);
    });
  });
}
