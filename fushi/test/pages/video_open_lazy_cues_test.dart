// video-20：本地单视频开播时，DB 缓存 cue（整表读）在两种情况下读了就丢——
// 字幕显式关闭、外挂文本档重解析成功。改成惰性：只有真要用它（重解析为空的回退 =
// BUG-1848 语义、内嵌轨判定、兜底链入口）时才读。
//
// 钉子（经真实 `_loadSingle` 路径，数 [VideoBookRepository.loadCues] 的调用次数）：
// - 字幕显式关闭：不读；
// - 外挂档重解析出 cue：不读；
// - 外挂档重解析为空（档案坏了）：仍读一次，回退语义保留。
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
import 'package:fushi_audio/fushi_audio.dart';
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

/// 数 `loadCues` 调用（DB 缓存 cue 的整表读）。
class _CountingRepository extends VideoBookRepository {
  _CountingRepository(super.db);

  int loadCuesCalls = 0;

  @override
  Future<List<AudioCue>> loadCues(String bookUid) {
    loadCuesCalls++;
    return super.loadCues(bookUid);
  }
}

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
    storeDir = Directory.systemTemp.createTempSync('fushi_video_lazy_cues');
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

  Future<void> drive(WidgetTester tester, bool Function() done) async {
    for (int round = 0; round < 30 && !done(); round++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 20));
  }

  /// 落一本带 DB 缓存 cue 的单视频，字幕源指向 [subtitleSource]，开页并推到
  /// 载入落定（控制器在测试环境里建不起来 → 失败态；cue 阶段早已走完）。
  Future<_CountingRepository> openWith(
    WidgetTester tester, {
    required String? subtitleSource,
  }) async {
    final String videoPath = p.join(storeDir.path, 'movie.mkv');
    File(videoPath).writeAsBytesSync(<int>[0, 1, 2, 3]);
    await tester.runAsync(() async {
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: const Value<String>('video/lazy'),
          title: const Value<String>('Lazy'),
          videoPath: Value<String>(videoPath),
          subtitleSource: Value<String?>(subtitleSource),
        ),
      );
      await VideoBookRepository(db).saveCues(
        bookUid: 'video/lazy',
        cues: <AudioCue>[
          AudioCue()
            ..bookKey = 'video/lazy'
            ..chapterHref = ''
            ..sentenceIndex = 0
            ..textFragmentId = ''
            ..text = 'cached'
            ..startMs = 0
            ..endMs = 1000
            ..audioFileIndex = 0,
        ],
      );
    });
    final _CountingRepository repo = _CountingRepository(db);
    await tester.pumpWidget(
      wrap(VideoFushiPage(bookUid: 'video/lazy', repo: repo)),
    );
    final VideoFushiTestHooks hooks =
        tester.state(find.byType(VideoFushiPage)) as VideoFushiTestHooks;
    await drive(tester, () => hooks.debugLoadFailed);
    expect(
      hooks.debugLoadFailed || hooks.debugHasPendingController,
      isTrue,
      reason: '载入应已越过 cue 阶段',
    );
    return repo;
  }

  testWidgets('字幕显式关闭：不读 DB 缓存 cue', (WidgetTester tester) async {
    final _CountingRepository repo = await openWith(
      tester,
      subtitleSource: SubtitleSource.offSentinel,
    );
    expect(repo.loadCuesCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('外挂档重解析出 cue：不读 DB 缓存 cue', (WidgetTester tester) async {
    final String srt = p.join(storeDir.path, 'movie.srt');
    File(srt).writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n');
    final _CountingRepository repo = await openWith(
      tester,
      subtitleSource: srt,
    );
    expect(repo.loadCuesCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('外挂档重解析为空：回退读一次 DB 缓存 cue（BUG-1848）', (
    WidgetTester tester,
  ) async {
    final String srt = p.join(storeDir.path, 'movie.srt');
    File(srt).writeAsStringSync('');
    final _CountingRepository repo = await openWith(
      tester,
      subtitleSource: srt,
    );
    expect(repo.loadCuesCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
