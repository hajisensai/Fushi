import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/gestures.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_bar.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/misc/hibiki_toast.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// HomeVideoPage 行为测试：验证「视频长按弹菜单」与「视频卡渲染共享标签」真生效
/// （而非只看源码）。AppModel 用 [AppModel.wireDatabaseForTesting] /
/// [AppModel.wireLocalAudioForTesting] 注入内存库，跳过完整 initialise。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_home_video_pp');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late HibikiDatabase db;
  late AppModel appModel;
  late Directory externalVideoDir;
  late Directory storeDir;
  late GlobalKey<NavigatorState> toastNavigatorKey;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_home_video_store');
    externalVideoDir =
        Directory.systemTemp.createTempSync('hibiki_home_video_external');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    toastNavigatorKey = GlobalKey<NavigatorState>();
  });

  tearDown(() async {
    await db.close();
    if (externalVideoDir.existsSync()) {
      externalVideoDir.deleteSync(recursive: true);
    }
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  void resetAppOwnedVideoAssetDirs() {
    for (final String name in <String>[
      VideoStorage.coversDirName,
      VideoStorage.subtitlesDirName,
    ]) {
      final Directory dir = Directory(p.join(pathProviderDir.path, name));
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
      dir.createSync(recursive: true);
    }
  }

  File writeAppOwnedAsset({
    required String dirName,
    required String fileName,
    List<int>? bytes,
    String? text,
  }) {
    final File file = File(p.join(pathProviderDir.path, dirName, fileName));
    file.parent.createSync(recursive: true);
    if (bytes != null) {
      file.writeAsBytesSync(bytes);
    } else {
      file.writeAsStringSync(text ?? 'asset');
    }
    return file;
  }

  File writeOriginalVideo(String fileName) {
    final File file = File(p.join(externalVideoDir.path, fileName));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(<int>[0, 1, 2, 3, 4, 5]);
    return file;
  }

  Directory writeEmbeddedSubtitleCache(File video) {
    final Directory dir = embeddedSubtitleCacheDir(video.path);
    dir.createSync(recursive: true);
    File(p.join(dir.path, 'sub_0.srt'))
        .writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhello');
    return dir;
  }

  Future<({File cover, Directory embeddedCache, File subtitle, File video})>
      seedVideoWithAssets({
    required String bookUid,
    required String title,
    required File cover,
    required File subtitle,
    String? videoFileName,
  }) async {
    final File video = writeOriginalVideo(
      videoFileName ?? '${bookUid.replaceAll('/', '_')}.mp4',
    );
    final Directory embeddedCache = writeEmbeddedSubtitleCache(video);
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(title),
      videoPath: Value(video.path),
      coverPath: Value(cover.path),
      subtitleSource: Value(subtitle.path),
    ));
    return (
      cover: cover,
      embeddedCache: embeddedCache,
      subtitle: subtitle,
      video: video,
    );
  }

  Future<void> waitForAsyncCleanup(
    WidgetTester tester,
    bool Function() isDone,
  ) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!isDone() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    }
    await tester.pumpAndSettle();
  }

  Future<void> seedTaggedVideo() async {
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('My Episode'),
      videoPath: Value('/abs/ep1.mp4'),
    ));
    final int tagId = await db.createTag('Anime', 0xFF2196F3);
    await db.addTagToVideoBook('video/1', tagId);
  }

  Future<int> seedVideoAndLooseTag() async {
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('My Episode'),
      videoPath: Value('/abs/ep1.mp4'),
    ));
    return db.createTag('Anime', 0xFF2196F3);
  }

  Widget buildApp({bool captureToasts = false}) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: captureToasts ? toastNavigatorKey : null,
            // HomeVideoPage 不再自带 Scaffold（与书架/词典 tab 统一，运行时挂在
            // HomePage 的外层 Scaffold 内）；测试照样在 Scaffold 内 pump，
            // HibikiPageHeader 的 HibikiIconButton(InkWell) 才有 Material 祖先。
            home: Scaffold(
              body: HomeVideoPage(repo: VideoBookRepository(db)),
            ),
          ),
        ),
      );

  Future<void> dragTopTagToVideoCard(WidgetTester tester) async {
    final Finder tagChip = find
        .descendant(
          of: find.byType(HibikiTagFilterBar),
          matching: find.widgetWithText(HibikiTagChip, 'Anime'),
        )
        .first;
    final Finder card =
        find.byKey(const ValueKey<String>('home_video_video/1'));

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(tagChip),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getCenter(card));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('视频卡渲染所挂的共享标签 chip', (WidgetTester tester) async {
    await seedTaggedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('My Episode'), findsOneWidget);
    // 标签来自共享 BookTags 池，经 video_book_tag_mappings 映射。
    // 卡片与顶部筛选条现都用同款共享 HibikiTagChip，故按卡片范围定位避免与
    // 筛选条里的同名标签冲突。
    expect(
      find.descendant(
        of: find.byType(HibikiCard),
        matching: find.widgetWithText(HibikiTagChip, 'Anime'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('长按视频卡弹出菜单（标签 / 封面 / 删除）', (WidgetTester tester) async {
    await seedTaggedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(HibikiCard).first);
    await tester.pumpAndSettle();

    // 修复前长按 == 打开播放页（无菜单）；现在应弹出三项菜单。
    expect(find.text(t.tag_label), findsOneWidget);
    expect(find.text(t.srt_import_pick_cover), findsOneWidget);
    expect(find.text(t.dialog_delete), findsOneWidget);
  });

  testWidgets('first video open prompts for Anime4K recommended shaders',
      (WidgetTester tester) async {
    await seedTaggedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('My Episode'));
    await tester.pumpAndSettle();

    expect(find.text(t.video_shader_first_use_title), findsOneWidget);
    expect(find.text(t.video_shader_first_use_body), findsOneWidget);
    expect(
      await db.getPref(PreferencesRepository.videoAnime4kPromptShownKey),
      'b:true',
    );
    expect(appModel.prefsRepo.videoAnime4kPromptShown, isTrue);
  });

  testWidgets('顶部标签可拖到视频卡并写入视频标签映射', (WidgetTester tester) async {
    final int tagId = await seedVideoAndLooseTag();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(await db.getTagsForVideoBook('video/1'), isEmpty);

    await dragTopTagToVideoCard(tester);

    final List<BookTagRow> tags = await db.getTagsForVideoBook('video/1');
    expect(tags.map((BookTagRow tag) => tag.id), contains(tagId));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('home_video_video/1')),
        matching: find.widgetWithText(HibikiTagChip, 'Anime'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('顶部标签拖到视频卡成功提示使用视频文案', (WidgetTester tester) async {
    await seedVideoAndLooseTag();
    HibikiToast.navigatorKey = toastNavigatorKey;
    await tester.pumpWidget(buildApp(captureToasts: true));
    await tester.pumpAndSettle();

    await dragTopTagToVideoCard(tester);

    expect(find.text('标签「Anime」已添加到视频。'), findsOneWidget);
    expect(find.text('标签「Anime」已添加到书籍。'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('重复拖同一标签到视频卡保持幂等，不新增重复映射', (WidgetTester tester) async {
    await seedVideoAndLooseTag();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await dragTopTagToVideoCard(tester);
    await dragTopTagToVideoCard(tester);

    final List<VideoBookTagMappingRow> mappings =
        await db.getAllVideoBookTagMappings();
    expect(mappings, hasLength(1));
    expect(mappings.single.videoBookUid, 'video/1');
  });

  // ── TODO-063 视频批量选择（标签栏旁的「选择」+ 批量打标签/删除）──────────

  /// 点标签栏旁的「批量选择」按钮进入选择态。该按钮是 [HibikiTagFilterBar] 末尾的
  /// checklist 图标按钮（tooltip = batch_select）。
  Future<void> enterSelectionMode(WidgetTester tester) async {
    final Finder selectBtn = find.descendant(
      of: find.byType(HibikiTagFilterBar),
      matching: find.byIcon(Icons.checklist_outlined),
    );
    expect(selectBtn, findsOneWidget, reason: '视频标签栏旁应有「批量选择」按钮（用户报的「视频少了选择」）');
    await tester.tap(selectBtn);
    await tester.pumpAndSettle();
  }

  testWidgets('标签栏旁的「选择」按钮存在，进入选择态后出现批量操作栏', (WidgetTester tester) async {
    await seedTaggedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 进入前没有批量操作栏（按计数文案判定）。
    expect(find.text(t.batch_selected_count(n: 0)), findsNothing);

    await enterSelectionMode(tester);

    // 进入后底部批量操作栏出现（0 选中）。
    expect(find.text(t.batch_selected_count(n: 0)), findsOneWidget);
    expect(find.text(t.batch_select_all), findsOneWidget);
    expect(find.text(t.batch_invert_selection), findsOneWidget);
  });

  testWidgets('选择态点视频卡勾选 → 批量删除真删视频书', (WidgetTester tester) async {
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('Episode One'),
      videoPath: Value('/abs/ep1.mp4'),
    ));
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/2'),
      title: Value('Episode Two'),
      videoPath: Value('/abs/ep2.mp4'),
    ));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect((await VideoBookRepository(db).listAll()).length, 2);

    await enterSelectionMode(tester);

    // 选择态下点卡片切换勾选（不再打开播放页）。
    await tester.tap(find.byKey(const ValueKey<String>('home_video_video/1')));
    await tester.pumpAndSettle();
    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget);

    // 点批量删除（垃圾桶）→ 确认对话框 → 删除。
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    // 确认对话框的「删除」按钮（AlertDialog 内）。
    await tester.tap(find.widgetWithText(TextButton, t.dialog_delete).last);
    await tester.pumpAndSettle();

    final List<VideoBookRow> remaining =
        await VideoBookRepository(db).listAll();
    expect(remaining.map((VideoBookRow b) => b.bookUid), <String>['video/2'],
        reason: 'video/1 被批量删除，video/2 保留');
  });

  testWidgets('长按菜单单删会回收本视频 app-owned 封面字幕与内嵌字幕缓存',
      (WidgetTester tester) async {
    resetAppOwnedVideoAssetDirs();
    final deleted = await seedVideoWithAssets(
      bookUid: 'video/1',
      title: 'Episode One',
      cover: writeAppOwnedAsset(
        dirName: VideoStorage.coversDirName,
        fileName: 'video_1.png',
        text: 'cover-one',
      ),
      subtitle: writeAppOwnedAsset(
        dirName: VideoStorage.subtitlesDirName,
        fileName: 'video_1.srt',
        text: '1\n00:00:00,000 --> 00:00:01,000\none',
      ),
    );
    final kept = await seedVideoWithAssets(
      bookUid: 'video/2',
      title: 'Episode Two',
      cover: writeAppOwnedAsset(
        dirName: VideoStorage.coversDirName,
        fileName: 'video_2.png',
        text: 'cover-two',
      ),
      subtitle: writeAppOwnedAsset(
        dirName: VideoStorage.subtitlesDirName,
        fileName: 'video_2.srt',
        text: '1\n00:00:00,000 --> 00:00:01,000\ntwo',
      ),
    );

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester
        .longPress(find.byKey(const ValueKey<String>('home_video_video/1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, t.dialog_delete).last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, t.dialog_delete).last);
    await tester.pumpAndSettle();
    await waitForAsyncCleanup(
      tester,
      () =>
          !deleted.cover.existsSync() &&
          !deleted.subtitle.existsSync() &&
          !deleted.embeddedCache.existsSync(),
    );

    expect(await db.getVideoBookByBookUid('video/1'), isNull);
    expect(await db.getVideoBookByBookUid('video/2'), isNotNull);
    expect(deleted.cover.existsSync(), isFalse);
    expect(deleted.subtitle.existsSync(), isFalse);
    expect(deleted.embeddedCache.existsSync(), isFalse);
    expect(deleted.video.existsSync(), isTrue,
        reason: '删除视频书不得删除用户原始 videoPath');
    expect(kept.cover.existsSync(), isTrue);
    expect(kept.subtitle.existsSync(), isTrue);
    expect(kept.embeddedCache.existsSync(), isTrue);
    expect(kept.video.existsSync(), isTrue);
  });

  testWidgets('批量删除只回收选中视频资产且保留其他视频仍引用的字幕', (WidgetTester tester) async {
    resetAppOwnedVideoAssetDirs();
    final File sharedSubtitle = writeAppOwnedAsset(
      dirName: VideoStorage.subtitlesDirName,
      fileName: 'shared.srt',
      text: '1\n00:00:00,000 --> 00:00:01,000\nshared',
    );
    final selectedOne = await seedVideoWithAssets(
      bookUid: 'video/1',
      title: 'Episode One',
      cover: writeAppOwnedAsset(
        dirName: VideoStorage.coversDirName,
        fileName: 'video_1.png',
        text: 'cover-one',
      ),
      subtitle: sharedSubtitle,
    );
    final selectedTwo = await seedVideoWithAssets(
      bookUid: 'video/2',
      title: 'Episode Two',
      cover: writeAppOwnedAsset(
        dirName: VideoStorage.coversDirName,
        fileName: 'video_2.png',
        text: 'cover-two',
      ),
      subtitle: writeAppOwnedAsset(
        dirName: VideoStorage.subtitlesDirName,
        fileName: 'video_2.srt',
        text: '1\n00:00:00,000 --> 00:00:01,000\ntwo',
      ),
    );
    final kept = await seedVideoWithAssets(
      bookUid: 'video/3',
      title: 'Episode Three',
      cover: writeAppOwnedAsset(
        dirName: VideoStorage.coversDirName,
        fileName: 'video_3.png',
        text: 'cover-three',
      ),
      subtitle: sharedSubtitle,
    );

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    await enterSelectionMode(tester);
    await tester.tap(find.byKey(const ValueKey<String>('home_video_video/1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('home_video_video/2')));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, t.dialog_delete).last);
    await tester.pumpAndSettle();
    await waitForAsyncCleanup(
      tester,
      () =>
          !selectedOne.cover.existsSync() &&
          !selectedTwo.cover.existsSync() &&
          !selectedTwo.subtitle.existsSync() &&
          !selectedOne.embeddedCache.existsSync() &&
          !selectedTwo.embeddedCache.existsSync(),
    );

    expect(await db.getVideoBookByBookUid('video/1'), isNull);
    expect(await db.getVideoBookByBookUid('video/2'), isNull);
    expect(await db.getVideoBookByBookUid('video/3'), isNotNull);
    expect(selectedOne.cover.existsSync(), isFalse);
    expect(selectedTwo.cover.existsSync(), isFalse);
    expect(selectedTwo.subtitle.existsSync(), isFalse);
    expect(selectedOne.embeddedCache.existsSync(), isFalse);
    expect(selectedTwo.embeddedCache.existsSync(), isFalse);
    expect(selectedOne.video.existsSync(), isTrue);
    expect(selectedTwo.video.existsSync(), isTrue);
    expect(sharedSubtitle.existsSync(), isTrue,
        reason: '其他视频仍引用的 app-owned 字幕不能被选中视频删除波及');
    expect(kept.cover.existsSync(), isTrue);
    expect(kept.embeddedCache.existsSync(), isTrue);
    expect(kept.video.existsSync(), isTrue);
  });

  testWidgets('选择态批量打标签 → 真写视频标签映射', (WidgetTester tester) async {
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('Episode One'),
      videoPath: Value('/abs/ep1.mp4'),
    ));
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/2'),
      title: Value('Episode Two'),
      videoPath: Value('/abs/ep2.mp4'),
    ));
    final int tagId = await db.createTag('Anime', 0xFF2196F3);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await enterSelectionMode(tester);
    await tester.tap(find.byKey(const ValueKey<String>('home_video_video/1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('home_video_video/2')));
    await tester.pumpAndSettle();
    expect(find.text(t.batch_selected_count(n: 2)), findsOneWidget);

    // 点批量打标签按钮（批量栏的 sell_outlined）→ 打开三态 picker。dialog 打开前
    // 页面上只有批量栏一个 sell_outlined（卡片标签层用 HibikiTagChip，不是该图标）。
    await tester.tap(find.byIcon(Icons.sell_outlined).last);
    await tester.pumpAndSettle();
    expect(find.text(t.batch_tag_title), findsOneWidget);

    // 把「Anime」设为「添加」（segmented 的 + 段）：在 SegmentedButton 内定位 + 图标，
    // 避开页头导入按钮（也是 Icons.add，TODO-064 起恒渲染）。
    final Finder segmentedButton = find.byWidgetPredicate(
      (Widget w) => w is SegmentedButton,
    );
    expect(segmentedButton, findsWidgets);
    await tester.tap(find.descendant(
      of: segmentedButton.first,
      matching: find.byIcon(Icons.add),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.batch_tag_apply));
    await tester.pumpAndSettle();

    expect(
      (await db.getTagsForVideoBook('video/1')).map((BookTagRow x) => x.id),
      contains(tagId),
    );
    expect(
      (await db.getTagsForVideoBook('video/2')).map((BookTagRow x) => x.id),
      contains(tagId),
    );
  });
}
