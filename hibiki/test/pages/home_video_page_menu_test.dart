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
}
