// BUG-5464：本地合集里上一集选的字幕，下一集（换集 pushReplacement / 从库里开另一集）
// 不继承——统一合集 Phase 3 后每集是独立 VideoBooks 行，`_loadSingle` 只看本行自己的
// `subtitleSource`，旧的跨集继承（`crossEpisode: true`）没有调用方。
//
// 钉子（经真实开页路径 `_init → collectionPlaybackSnapshot → _loadSingle → _applyLoad`，
// 读 [VideoFushiTestHooks.debugLastLoadSubtitle]；控制器在测试环境建不起来 → 失败态，
// 字幕判定早已走完）：
// - 兄弟集选了同名 sidecar：本集按后缀挑自己的同名字幕（压过按语言的默认探测）；
// - 兄弟集关了字幕：本集关着起播，不退 sidecar 探测；
// - 兄弟集下载 / 导入的单集字幕档：不搬到本集（BUG-165），照常默认探测；
// - 本集自己有选择：自己的优先；
// - 沿用只管本次加载，不写回本集行。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
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

const String _srt = '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n';

void main() {
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
    storeDir = Directory.systemTemp.createTempSync('fushi_sub_inherit');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = _TestAppModel(platformServices, db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
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

  String video(String uid) => p.join(storeDir.path, 'Show - $uid.mkv');
  String sidecar(String uid, String suffix) =>
      p.join(storeDir.path, 'Show - $uid$suffix');

  /// 落 ep1 / ep2 两集 + 一个播放列表合集，各集的字幕选择与播放时刻由参数给；
  /// [files] 是要写出的字幕档（路径 → 内容）。返回合集 id。
  Future<int> seedSeries(
    WidgetTester tester, {
    String? ep1Subtitle,
    int? ep1PlayedAt,
    String? ep2Subtitle,
    Map<String, String> files = const <String, String>{},
  }) async {
    late int id;
    await tester.runAsync(() async {
      id = await db.createMediaCollection('Series', collectionType: 'playlist');
      for (final MapEntry<String, String> f in files.entries) {
        File(f.key)
          ..createSync(recursive: true)
          ..writeAsStringSync(f.value);
      }
      for (final String uid in <String>['ep1', 'ep2']) {
        File(video(uid)).writeAsBytesSync(<int>[0, 1, 2, 3]);
        await db.upsertVideoBook(
          VideoBooksCompanion(
            bookUid: Value<String>(uid),
            title: Value<String>(uid),
            videoPath: Value<String>(video(uid)),
            subtitleSource: Value<String?>(
              uid == 'ep1' ? ep1Subtitle : ep2Subtitle,
            ),
            lastPlayedAt: Value<int?>(uid == 'ep1' ? ep1PlayedAt : null),
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

  /// 以合集里的一集打开 ep2，推到载入落定，返回交给播放器的字幕判定。
  Future<({String? source, int cueCount})> openEp2(
    WidgetTester tester,
    int collectionId,
  ) async {
    await tester.pumpWidget(
      wrap(
        VideoFushiPage(
          bookUid: 'ep2',
          repo: VideoBookRepository(db),
          playlistCollectionId: collectionId,
        ),
      ),
    );
    final VideoFushiTestHooks hooks =
        tester.state(find.byType(VideoFushiPage)) as VideoFushiTestHooks;
    for (int round = 0; round < 40 && !hooks.debugLoadFailed; round++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 20));
    }
    final ({String? source, int cueCount})? loaded =
        hooks.debugLastLoadSubtitle;
    expect(loaded, isNotNull, reason: '载入应已越过字幕判定（_applyLoad 入口）');
    await tester.pumpWidget(const SizedBox.shrink());
    return loaded!;
  }

  Future<String?> ep2RowSubtitle(WidgetTester tester) async {
    String? source;
    await tester.runAsync(() async {
      source = (await db.getVideoBookByBookUid('ep2'))?.subtitleSource;
    });
    return source;
  }

  testWidgets('兄弟集选了 .de.srt：本集挑自己的 .de.srt（不是按语言默认的那份），且不写回本行', (
    WidgetTester tester,
  ) async {
    final int id = await seedSeries(
      tester,
      ep1Subtitle: sidecar('ep1', '.de.srt'),
      ep1PlayedAt: 1000,
      files: <String, String>{
        sidecar('ep1', '.de.srt'): _srt,
        sidecar('ep2', '.ja.srt'): _srt,
        sidecar('ep2', '.en.srt'): _srt,
        sidecar('ep2', '.de.srt'): _srt,
      },
    );
    final ({String? source, int cueCount}) loaded = await openEp2(tester, id);
    expect(loaded.source, sidecar('ep2', '.de.srt'));
    expect(loaded.cueCount, greaterThan(0));
    expect(await ep2RowSubtitle(tester), isNull, reason: '沿用只管本次加载');
  });

  testWidgets('兄弟集关了字幕：本集关着起播，不退 sidecar 探测', (WidgetTester tester) async {
    final int id = await seedSeries(
      tester,
      ep1Subtitle: SubtitleSource.offSentinel,
      ep1PlayedAt: 1000,
      files: <String, String>{sidecar('ep2', '.ja.srt'): _srt},
    );
    final ({String? source, int cueCount}) loaded = await openEp2(tester, id);
    expect(loaded.source, SubtitleSource.offSentinel);
    expect(loaded.cueCount, 0);
    expect(await ep2RowSubtitle(tester), isNull);
  });

  testWidgets('BUG-165：兄弟集下载的单集字幕档不搬到本集，照常默认探测', (WidgetTester tester) async {
    final String downloaded = p.join(
      storeDir.path,
      'documents',
      'video_subtitles',
      'Show - ep1.de.srt',
    );
    final int id = await seedSeries(
      tester,
      ep1Subtitle: downloaded,
      ep1PlayedAt: 1000,
      files: <String, String>{downloaded: _srt},
    );
    final ({String? source, int cueCount}) loaded = await openEp2(tester, id);
    expect(loaded.source, isNot(downloaded));
    expect(loaded.cueCount, 0, reason: 'ep2 自己没有任何字幕');
  });

  testWidgets('本集自己有选择：自己的优先于兄弟集的', (WidgetTester tester) async {
    final int id = await seedSeries(
      tester,
      ep1Subtitle: sidecar('ep1', '.de.srt'),
      ep1PlayedAt: 1000,
      ep2Subtitle: sidecar('ep2', '.en.srt'),
      files: <String, String>{
        sidecar('ep1', '.de.srt'): _srt,
        sidecar('ep2', '.en.srt'): _srt,
        sidecar('ep2', '.de.srt'): _srt,
      },
    );
    final ({String? source, int cueCount}) loaded = await openEp2(tester, id);
    expect(loaded.source, sidecar('ep2', '.en.srt'));
    expect(loaded.cueCount, greaterThan(0));
  });

  testWidgets('兄弟集的选择没有播放时刻：不沿用（无从判断新旧）', (WidgetTester tester) async {
    final int id = await seedSeries(
      tester,
      ep1Subtitle: SubtitleSource.offSentinel,
      files: <String, String>{sidecar('ep2', '.ja.srt'): _srt},
    );
    final ({String? source, int cueCount}) loaded = await openEp2(tester, id);
    expect(loaded.source, isNot(SubtitleSource.offSentinel));
  });
}
