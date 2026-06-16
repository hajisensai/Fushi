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
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_bar.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/misc/hibiki_toast.dart';
import 'package:hibiki_core/hibiki_core.dart';

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
  late GlobalKey<NavigatorState> toastNavigatorKey;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_home_video_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    toastNavigatorKey = GlobalKey<NavigatorState>();
  });

  tearDown(() async {
    await db.close();
  });

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

  testWidgets('长按视频卡弹出封面背景动作面板（五项管理动作、无播放）', (WidgetTester tester) async {
    await seedTaggedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(HibikiCard).first);
    await tester.pumpAndSettle();

    // 长按只做管理动作；播放仍由卡片点击负责。
    expect(find.byType(HibikiDialogFrame), findsOneWidget);
    expect(find.text(t.tag_label), findsOneWidget);
    expect(find.text(t.video_rename), findsOneWidget);
    expect(find.text(t.srt_import_pick_cover), findsOneWidget);
    expect(find.text(t.video_import_pick_subtitle), findsOneWidget);
    expect(find.text(t.dialog_delete), findsOneWidget);
    expect(find.text(t.dialog_read), findsNothing);
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
