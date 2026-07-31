import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/jimaku_batch_dialog.dart';
import 'package:hibiki/src/platform/platform_providers.dart';
import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/test_platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late VideoBookRepository repo;
  late Directory tempDir;
  late AppModel appModel;
  late PlatformServices platformServices;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    tempDir =
        await Directory.systemTemp.createTemp('jimaku_batch_dialog_state_');
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    platformServices = testPlatformServices();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
        prefsRepo: prefs,
        databaseDirectory: tempDir,
      );
    await appModel.setJimakuApiKey('test-key');
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<VideoBookRow> seedMember() async {
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value<String>('video/show-01'),
      title: Value<String>('Show - 01'),
      videoPath: Value<String>('C:/video/Show - 01.mkv'),
    ));
    return (await repo.getByBookUid('video/show-01'))!;
  }

  Future<MediaCollectionRow> seedCollection({int? anilistId}) async {
    final int id = await db.createMediaCollection(
      'Show',
      collectionType: 'collection',
    );
    if (anilistId != null) {
      await db.setMediaCollectionAnilistId(id, anilistId);
    }
    return (await db.getMediaCollectionById(id))!;
  }

  Widget wrap({
    required MediaCollectionRow collection,
    required VideoBookRow member,
    required JimakuBatchHttpClientFactory factory,
  }) {
    return ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(platformServices),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: JimakuBatchDialog(
              database: db,
              collection: collection,
              members: <VideoBookRow>[member],
              httpClientFactory: factory,
            ),
          ),
        ),
      ),
    );
  }

  Finder downloadButton() =>
      find.widgetWithText(FilledButton, t.video_jimaku_batch_download);

  testWidgets('inventory client 创建失败转 failed，下载保持禁用',
      (WidgetTester tester) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection(anilistId: 21);
    int factoryCalls = 0;

    Future<http.Client> factory() async {
      factoryCalls++;
      if (factoryCalls == 1) {
        return MockClient(
          (http.Request request) async =>
              http.Response('[{"id":7,"name":"Source"}]', 200),
        );
      }
      throw StateError('client factory unavailable');
    }

    await tester.pumpWidget(
      wrap(collection: collection, member: member, factory: factory),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.video_jimaku_source_failed), findsWidgets);
    expect(tester.widget<FilledButton>(downloadButton()).onPressed, isNull);
  });

  testWidgets('inventory loading 时禁用；成功且非空后才开放下载', (WidgetTester tester) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection(anilistId: 21);
    final Completer<http.Response> inventoryResponse =
        Completer<http.Response>();

    Future<http.Client> factory() async {
      return MockClient((http.Request request) async {
        if (request.url.path.endsWith('/entries/search')) {
          return http.Response('[{"id":7,"name":"Source"}]', 200);
        }
        if (request.url.path.endsWith('/entries/7/files')) {
          return inventoryResponse.future;
        }
        return http.Response('not found', 404);
      });
    }

    await tester.pumpWidget(
      wrap(collection: collection, member: member, factory: factory),
    );
    for (int i = 0;
        i < 20 && find.text(t.video_jimaku_source_loading).evaluate().isEmpty;
        i++) {
      await tester.pump();
    }

    expect(find.text(t.video_jimaku_source_loading), findsWidgets);
    expect(tester.widget<FilledButton>(downloadButton()).onPressed, isNull);

    inventoryResponse.complete(http.Response(
      jsonEncode(<Map<String, String>>[
        <String, String>{
          'name': 'Show - 01.ja.srt',
          'url': 'https://x/show-01.ja.srt',
        },
      ]),
      200,
    ));
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(downloadButton()).onPressed, isNotNull);
  });

  testWidgets('快速切系列时迟到旧响应不覆盖新条目，DB 也保留最新系列', (WidgetTester tester) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection();
    final Completer<http.Response> staleBResponse = Completer<http.Response>();
    final Completer<void> staleBStarted = Completer<void>();
    int seriesACalls = 0;

    Future<http.Client> factory() async {
      return MockClient((http.Request request) async {
        if (request.url.host == 'graphql.anilist.co') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <String, Object?>{
                'Page': <String, Object?>{
                  'media': <Object?>[
                    <String, Object?>{
                      'id': 1,
                      'title': <String, Object?>{'romaji': 'Series A'},
                    },
                    <String, Object?>{
                      'id': 2,
                      'title': <String, Object?>{'romaji': 'Series B'},
                    },
                  ],
                },
              },
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/entries/search')) {
          final String? id = request.url.queryParameters['anilist_id'];
          if (id == '2') {
            if (!staleBStarted.isCompleted) staleBStarted.complete();
            return staleBResponse.future;
          }
          if (id == '1') {
            seriesACalls++;
            return http.Response(
              seriesACalls == 1
                  ? '[{"id":101,"name":"A initial"}]'
                  : '[{"id":111,"name":"A latest"}]',
              200,
            );
          }
        }
        if (request.url.path.endsWith('/files')) {
          return http.Response('[]', 200);
        }
        return http.Response('not found', 404);
      });
    }

    await tester.pumpWidget(
      wrap(collection: collection, member: member, factory: factory),
    );
    await tester.tap(find.text(t.video_jimaku_find_sources));
    await tester.pumpAndSettle();
    expect(find.text('A initial'), findsOneWidget);

    final Finder seriesBChip = find.widgetWithText(ChoiceChip, 'Series B');
    await tester.ensureVisible(seriesBChip);
    await tester.tap(seriesBChip);
    for (int i = 0; i < 20 && !staleBStarted.isCompleted; i++) {
      await tester.pump();
    }
    expect(staleBStarted.isCompleted, isTrue);

    final Finder seriesAChip = find.widgetWithText(ChoiceChip, 'Series A');
    await tester.ensureVisible(seriesAChip);
    await tester.tap(seriesAChip);
    await tester.pumpAndSettle();
    expect(find.text('A latest'), findsOneWidget);

    staleBResponse.complete(
      http.Response('[{"id":202,"name":"B stale"}]', 200),
    );
    await tester.pumpAndSettle();

    expect(find.text('A latest'), findsOneWidget);
    expect(find.text('B stale'), findsNothing);
    expect(
      (await db.getMediaCollectionById(collection.id))!.anilistId,
      1,
    );
  });
}
