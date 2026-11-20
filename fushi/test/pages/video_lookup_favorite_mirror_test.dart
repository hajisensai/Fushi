// BUG-4912 / video-25：查词浮层收藏星标每查一个词都 `getAll()` 读出并解析全部收藏句
// （代价随收藏总量增长），而字幕条 / 跳转列表星标读内存镜像——同一个收藏状态存两份。
// 修：浮层星标改读同一份镜像（同步判定），镜像填完补刷当前句；镜像键一律 trim。
//
// 钉子（经真实页面 State + 真实 FavoriteSentenceRepository）：
// - 镜像已填时，落到一句已收藏的字幕，星标在调用返回的同一刻就是实心（不等库读）；
// - 查词早于镜像首次填充：先空心，镜像填完补刷成实心；
// - 浮层收藏一句带首尾空白的查词句后，字幕条星标立刻认得它（不必等重填）；
// - 判据纯函数：cue 键、旧 text-only 兼容、远端多集按集区分。
import 'dart:io';

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

const String _bookUid = 'missing';

AudioCue _cue(String text, int startMs) => AudioCue()
  ..bookKey = _bookUid
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = startMs + 1500;

void main() {
  group('镜像判据（纯函数）', () {
    String key(String text, int? startMs, int? ep, {bool playlist = false}) =>
        videoFavoriteCacheKey(
          text: text,
          startMs: startMs,
          episodeIndex: ep,
          isPlaylist: playlist,
        );

    test('cue 键命中；同文本别的时间点不算', () {
      final Set<String> mirror = <String>{key('你好', 1000, null)};
      expect(
        videoSentenceFavoritedInMirror(
          mirror,
          sentence: ' 你好 ',
          cueStartMs: 1000,
          episodeIndex: null,
          isPlaylist: false,
        ),
        isTrue,
      );
      expect(
        videoSentenceFavoritedInMirror(
          mirror,
          sentence: '你好',
          cueStartMs: 2000,
          episodeIndex: null,
          isPlaylist: false,
        ),
        isFalse,
      );
    });

    test('旧 text-only 条目对有 cue / 没 cue 的查词句都算', () {
      final Set<String> mirror = <String>{key('旧句', null, null)};
      for (final int? start in <int?>[null, 500]) {
        expect(
          videoSentenceFavoritedInMirror(
            mirror,
            sentence: '旧句',
            cueStartMs: start,
            episodeIndex: null,
            isPlaylist: false,
          ),
          isTrue,
        );
      }
    });

    test('没 cue 的查词句不认 cue 键条目；远端多集按集区分', () {
      final Set<String> mirror = <String>{key('一句', 1000, 2, playlist: true)};
      expect(
        videoSentenceFavoritedInMirror(
          mirror,
          sentence: '一句',
          cueStartMs: null,
          episodeIndex: 2,
          isPlaylist: true,
        ),
        isFalse,
      );
      expect(
        videoSentenceFavoritedInMirror(
          mirror,
          sentence: '一句',
          cueStartMs: 1000,
          episodeIndex: 3,
          isPlaylist: true,
        ),
        isFalse,
      );
      expect(
        videoSentenceFavoritedInMirror(
          mirror,
          sentence: '一句',
          cueStartMs: 1000,
          episodeIndex: 2,
          isPlaylist: true,
        ),
        isTrue,
      );
    });
  });

  group('镜像判据与库内匹配同一组键（#3722 c51 遗留）', () {
    FavoriteSentence legacy({int? sectionIndex}) => FavoriteSentence(
      text: '旧句 ',
      bookTitle: 'T',
      createdAt: DateTime(2026, 11, 20),
      bookKey: _bookUid,
      sectionIndex: sectionIndex,
      source: kFavoriteSentenceSourceVideo,
    );

    Set<String> mirrorOf(FavoriteSentence f, {required bool playlist}) =>
        <String>{
          videoFavoriteCacheKey(
            text: f.text.trim(),
            startMs: f.normCharOffset,
            episodeIndex: f.sectionIndex,
            isPlaylist: playlist,
          ),
        };

    test('旧 text-only 条目带了集下标：镜像认它，库内匹配也认它', () {
      for (final bool playlist in <bool>[false, true]) {
        final FavoriteSentence f = legacy(sectionIndex: 3);
        for (final int? start in <int?>[null, 500]) {
          final bool inMirror = videoSentenceFavoritedInMirror(
            mirrorOf(f, playlist: playlist),
            sentence: '旧句',
            cueStartMs: start,
            episodeIndex: 3,
            isPlaylist: playlist,
          );
          final bool matched = videoFavoriteMatchesSentence(
            f,
            sentence: '旧句',
            cueStartMs: start,
            episodeIndex: 3,
            isPlaylist: playlist,
          );
          expect(inMirror, isTrue, reason: 'playlist=$playlist start=$start');
          expect(
            matched,
            inMirror,
            reason: '星标亮着就必须删得到（playlist=$playlist start=$start）',
          );
        }
      }
    });

    test('cue 键条目：同一时间点同一集才算，与镜像一致', () {
      final FavoriteSentence f = FavoriteSentence(
        text: '一句',
        bookTitle: 'T',
        createdAt: DateTime(2026, 11, 20),
        bookKey: _bookUid,
        sectionIndex: 2,
        normCharOffset: 1000,
        source: kFavoriteSentenceSourceVideo,
      );
      for (final (int? start, int ep, bool expected) in <(int?, int, bool)>[
        (1000, 2, true),
        (1000, 3, false),
        (2000, 2, false),
        (null, 2, false),
      ]) {
        expect(
          videoFavoriteMatchesSentence(
            f,
            sentence: '一句',
            cueStartMs: start,
            episodeIndex: ep,
            isPlaylist: true,
          ),
          expected,
          reason: 'start=$start ep=$ep',
        );
        expect(
          videoSentenceFavoritedInMirror(
            mirrorOf(f, playlist: true),
            sentence: '一句',
            cueStartMs: start,
            episodeIndex: ep,
            isPlaylist: true,
          ),
          expected,
        );
      }
    });
  });

  group('页面星标读镜像', () {
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
      storeDir = Directory.systemTemp.createTempSync('fushi_video_fav_mirror');
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
      try {
        if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
      } on FileSystemException {
        // 失败态页面可能还握着句柄（Windows），留给系统临时目录回收。
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

    Future<VideoFushiTestHooks> openPage(WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(VideoFushiPage(bookUid: _bookUid, repo: VideoBookRepository(db))),
      );
      final VideoFushiTestHooks hooks =
          tester.state(find.byType(VideoFushiPage)) as VideoFushiTestHooks;
      for (int round = 0; round < 30; round++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump(const Duration(milliseconds: 20));
      }
      return hooks;
    }

    Future<void> seedFavorite(WidgetTester tester, String text, int startMs) =>
        tester.runAsync(
          () => FavoriteSentenceRepository(db).add(
            FavoriteSentence(
              text: text,
              bookTitle: 'T',
              createdAt: DateTime(2026, 11, 20),
              bookKey: _bookUid,
              normCharOffset: startMs,
              normCharLength: 1500,
              source: kFavoriteSentenceSourceVideo,
            ),
          ),
        );

    testWidgets('镜像已填：落到已收藏句时星标同步就是实心', (WidgetTester tester) async {
      await seedFavorite(tester, '収蔵済み', 4000);
      final VideoFushiTestHooks hooks = await openPage(tester);
      await tester.runAsync(hooks.debugRefreshFavoritedCueCache);

      hooks.debugSetLookupSentence('収蔵済み', _cue('収蔵済み', 4000));
      expect(
        hooks.debugCurrentSentenceFavorited,
        isTrue,
        reason: '浮层星标应读镜像同步判定，不再等一次全量库读',
      );
      hooks.debugSetLookupSentence('別の文', _cue('別の文', 9000));
      expect(hooks.debugCurrentSentenceFavorited, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('查词早于镜像首次填充：填完补刷当前句', (WidgetTester tester) async {
      final VideoFushiTestHooks hooks = await openPage(tester);
      // 失败态不走开播路径，镜像此时还是空的；之后才有人收藏（例如另一个窗口）。
      await seedFavorite(tester, '後から', 7000);
      hooks.debugSetLookupSentence('後から', _cue('後から', 7000));
      expect(hooks.debugCurrentSentenceFavorited, isFalse);

      await tester.runAsync(hooks.debugRefreshFavoritedCueCache);
      expect(
        hooks.debugCurrentSentenceFavorited,
        isTrue,
        reason: '镜像填完必须补刷浮层星标',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('浮层收藏带首尾空白的查词句，字幕条星标立刻认得', (WidgetTester tester) async {
      final VideoFushiTestHooks hooks = await openPage(tester);
      await tester.runAsync(hooks.debugRefreshFavoritedCueCache);
      final AudioCue cue = _cue('空白付き', 12000);

      hooks.debugSetLookupSentence(' 空白付き\n', cue);
      await tester.runAsync(hooks.debugToggleLookupSentenceFavorite);
      expect(hooks.debugCurrentSentenceFavorited, isTrue);
      expect(
        hooks.debugIsCueFavorited(cue),
        isTrue,
        reason: '镜像键必须 trim，否则字幕条星标要等下一次全量重填才亮',
      );

      await tester.runAsync(hooks.debugToggleLookupSentenceFavorite);
      expect(hooks.debugCurrentSentenceFavorited, isFalse);
      expect(hooks.debugIsCueFavorited(cue), isFalse);
      expect(
        await tester.runAsync(() => FavoriteSentenceRepository(db).getAll()),
        isEmpty,
        reason: '取消收藏仍走库内匹配删干净',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('镜像落后于页外收藏：点空心星标不写重复条目', (WidgetTester tester) async {
      final VideoFushiTestHooks hooks = await openPage(tester);
      // 镜像还没填（也就还没订阅变更）时页外（收藏夹页 / 同步合并）先收藏了这句。
      await seedFavorite(tester, '外部収蔵', 15000);
      final AudioCue cue = _cue('外部収蔵', 15000);
      hooks.debugSetLookupSentence('外部収蔵', cue);
      expect(hooks.debugCurrentSentenceFavorited, isFalse);

      await tester.runAsync(hooks.debugToggleLookupSentenceFavorite);
      expect(hooks.debugCurrentSentenceFavorited, isTrue);
      expect(hooks.debugIsCueFavorited(cue), isTrue);
      final List<FavoriteSentence>? all = await tester.runAsync(
        () => FavoriteSentenceRepository(db).getAll(),
      );
      expect(
        all,
        hasLength(1),
        reason: 'repo.add 只按 id 去重，按镜像空心星标直接 add 会写出第二条',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    /// 让变更流事件与随后的镜像重填（真实异步 DB 读）跑完。
    Future<void> letMirrorCatchUp(WidgetTester tester) async {
      for (int round = 0; round < 10; round++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pump();
      }
    }

    testWidgets('页外收藏 / 取消收藏：镜像自动跟上（收藏库变更流）', (WidgetTester tester) async {
      final VideoFushiTestHooks hooks = await openPage(tester);
      await tester.runAsync(hooks.debugRefreshFavoritedCueCache);
      final AudioCue cue = _cue('外から', 21000);
      hooks.debugSetLookupSentence('外から', cue);
      expect(hooks.debugCurrentSentenceFavorited, isFalse);

      await seedFavorite(tester, '外から', 21000);
      await letMirrorCatchUp(tester);
      expect(
        hooks.debugCurrentSentenceFavorited,
        isTrue,
        reason: '收藏夹页 / 同步合并改了收藏，播放页镜像要跟着重填',
      );
      expect(hooks.debugIsCueFavorited(cue), isTrue);

      await tester.runAsync(() async {
        final FavoriteSentenceRepository repo = FavoriteSentenceRepository(db);
        for (final FavoriteSentence f in await repo.getAll()) {
          await repo.removeById(f.id);
        }
      });
      await letMirrorCatchUp(tester);
      expect(hooks.debugCurrentSentenceFavorited, isFalse);
      expect(hooks.debugIsCueFavorited(cue), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('旧 text-only 条目带集下标：星标亮着，取消收藏删得到', (WidgetTester tester) async {
      await tester.runAsync(
        () => FavoriteSentenceRepository(db).add(
          FavoriteSentence(
            text: '昔の収蔵',
            bookTitle: 'T',
            createdAt: DateTime(2026, 11, 20),
            bookKey: _bookUid,
            sectionIndex: 0,
            source: kFavoriteSentenceSourceVideo,
          ),
        ),
      );
      final VideoFushiTestHooks hooks = await openPage(tester);
      await tester.runAsync(hooks.debugRefreshFavoritedCueCache);
      hooks.debugSetLookupSentence('昔の収蔵', _cue('昔の収蔵', 3000));
      expect(hooks.debugCurrentSentenceFavorited, isTrue);

      await tester.runAsync(hooks.debugToggleLookupSentenceFavorite);
      expect(hooks.debugCurrentSentenceFavorited, isFalse);
      expect(
        await tester.runAsync(() => FavoriteSentenceRepository(db).getAll()),
        isEmpty,
        reason: '库内匹配曾要求 sectionIndex 为空，这条删不到、星标下次又亮',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
