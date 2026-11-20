// BUG-4910 / video-s2-2：倍速记忆本地每集一份（`video_speed_<bookUid>`），远端原地
// 换集沿用当前倍速——同一个系列两边行为不一致。统一合集 Phase 3 之后每集是独立
// VideoBooks 行，本地合集换集读的是下一集自己的键（多半回到 1.0）。
//
// 修：照音量记忆（`video_volume_pref.dart`）加系列键，合集里读写系列键，读时系列键
// 缺省回退本集旧键（旧键冻结不改）。
//
// 钉子：
// - 键函数：合集里写系列键、单视频写本条目键；读顺序系列键优先、回退本集键；
// - 经真实开页路径：合集里的一集读到系列倍速；系列键缺省时回退本集旧值；单视频
//   不受同号合集的系列键影响。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_speed_pref.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

class _TestAppModel extends AppModel {
  _TestAppModel(PlatformServices platformServices, this._db)
    : super(platformServices);

  final FushiDatabase _db;

  @override
  double get appUiScale => 1.0;

  @override
  FushiDatabase get database => _db;
}

void main() {
  group('倍速键（纯函数）', () {
    test('合集里写系列键，单视频写本条目键（旧键名冻结）', () {
      expect(
        videoSpeedWriteKey(bookUid: 'ep2', collectionId: 7),
        'video_speed_collection_7',
      );
      expect(
        videoSpeedWriteKey(bookUid: 'ep1', collectionId: 7),
        videoSpeedWriteKey(bookUid: 'ep2', collectionId: 7),
      );
      expect(videoSpeedWriteKey(bookUid: 'solo'), 'video_speed_solo');
    });

    test('读顺序：系列键优先，回退本集旧键；单视频只读本条目键', () {
      expect(videoSpeedReadKeys(bookUid: 'ep2', collectionId: 7), <String>[
        'video_speed_collection_7',
        'video_speed_ep2',
      ]);
      expect(videoSpeedReadKeys(bookUid: 'solo'), <String>['video_speed_solo']);
    });
  });

  group('开页读倍速', () {
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.ensureInitialized();

    late FushiDatabase db;
    late PreferencesRepository prefs;
    late Directory storeDir;
    late PlatformServices platformServices;
    late FakeAnkiRepository ankiRepository;
    late AppModel appModel;

    setUpAll(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => Directory.systemTemp.path,
      );
    });

    tearDownAll(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
    });

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      storeDir = Directory.systemTemp.createTempSync('fushi_video_speed');
      platformServices = testPlatformServices();
      ankiRepository = FakeAnkiRepository();
      appModel = _TestAppModel(platformServices, db)
        ..wireLocalAudioForTesting(
          prefsRepo: prefs,
          databaseDirectory: storeDir,
        );
    });

    tearDown(() async {
      await db.close();
      // 失败态的页面可能还握着假视频文件的句柄（Windows 上删不掉）：临时目录清理
      // 失败不影响断言，留给系统临时目录回收。
      try {
        if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
      } on FileSystemException {
        // 见上。
      }
    });

    Widget wrap(Widget page) => ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(platformServices),
        ankiRepositoryProvider.overrideWithValue(ankiRepository),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(child: MaterialApp(home: page)),
    );

    /// 落两集 + 一个播放列表合集，返回合集 id。
    Future<int> seedSeries(WidgetTester tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.createMediaCollection(
          'Series',
          collectionType: 'playlist',
        );
        for (final String uid in <String>['ep1', 'ep2']) {
          final String path = p.join(storeDir.path, '$uid.mkv');
          File(path).writeAsBytesSync(<int>[0, 1, 2, 3]);
          await db.upsertVideoBook(
            VideoBooksCompanion(
              bookUid: Value<String>(uid),
              title: Value<String>(uid),
              videoPath: Value<String>(path),
            ),
          );
          await db.upsertCollectionItemAt(
            id,
            MediaKind.video.dbValue,
            uid,
            uid == 'ep1' ? 0 : 1,
          );
        }
      });
      return id;
    }

    Future<double> openSpeed(
      WidgetTester tester, {
      required String bookUid,
      int? collectionId,
      double? setTo,
    }) async {
      await tester.pumpWidget(
        wrap(
          VideoFushiPage(
            bookUid: bookUid,
            repo: VideoBookRepository(db),
            playlistCollectionId: collectionId,
          ),
        ),
      );
      final VideoFushiTestHooks hooks =
          tester.state(find.byType(VideoFushiPage)) as VideoFushiTestHooks;
      for (int round = 0; round < 30 && !hooks.debugLoadFailed; round++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(hooks.debugLoadFailed, isTrue, reason: '载入应已越过读偏好阶段');
      final double speed = hooks.debugPlaybackSpeed;
      if (setTo != null) {
        await tester.runAsync(() => hooks.debugSetPlaybackSpeed(setTo));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      return speed;
    }

    testWidgets('合集里一集改倍速写系列键，换到另一集沿用', (WidgetTester tester) async {
      final int id = await seedSeries(tester);
      await openSpeed(tester, bookUid: 'ep1', collectionId: id, setTo: 1.75);
      expect(prefs.getPref(videoSeriesSpeedPrefKey(id)), 1.75);
      expect(
        prefs.getPref(videoSpeedPrefKey('ep1')),
        isNull,
        reason: '合集里改倍速只写系列键，不再写本集键',
      );
      // 上一页的 ProviderScope 卸载时连带 dispose 了 appModel（及其 prefs）：从同一个
      // DB 重新载入偏好、换一只新的 appModel 再开另一集——系列键得真落了盘。
      await tester.runAsync(() async {
        prefs = PreferencesRepository(db);
        await prefs.loadFromDb();
      });
      appModel = _TestAppModel(platformServices, db)
        ..wireLocalAudioForTesting(
          prefsRepo: prefs,
          databaseDirectory: storeDir,
        );
      expect(await openSpeed(tester, bookUid: 'ep2', collectionId: id), 1.75);
    });

    testWidgets('合集里的一集读系列倍速（本集没存过也跟随系列）', (WidgetTester tester) async {
      final int id = await seedSeries(tester);
      await tester.runAsync(
        () => prefs.setPref(videoSeriesSpeedPrefKey(id), 1.5),
      );
      expect(await openSpeed(tester, bookUid: 'ep2', collectionId: id), 1.5);
    });

    testWidgets('系列键缺省：回退本集旧键（兼容迁移前已存的值）', (WidgetTester tester) async {
      final int id = await seedSeries(tester);
      await tester.runAsync(() => prefs.setPref(videoSpeedPrefKey('ep2'), 2.0));
      expect(await openSpeed(tester, bookUid: 'ep2', collectionId: id), 2.0);
    });

    testWidgets('单视频只读本条目键，不受系列键影响', (WidgetTester tester) async {
      final int id = await seedSeries(tester);
      await tester.runAsync(() async {
        await prefs.setPref(videoSeriesSpeedPrefKey(id), 1.5);
        await prefs.setPref(videoSpeedPrefKey('ep1'), 1.25);
      });
      expect(await openSpeed(tester, bookUid: 'ep1'), 1.25);
    });
  });
}
