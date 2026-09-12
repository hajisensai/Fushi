import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/media/audiobook/audiobook_play_bar.dart';
import 'package:fushi/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show readerAudiobookUsesSideSheet;
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

import '../../helpers/test_platform_services.dart';

class _FakeInAppWebViewController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppModel _testAppModel({FushiDatabase? database}) {
  final FushiDatabase db = database ??
      FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final AppModel appModel = AppModel(testPlatformServices())
    ..themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
  });
  return appModel;
}

void main() {
  for (final bool lyricsMode in <bool>[false, true]) {
    testWidgets('320 宽${lyricsMode ? '歌词' : '正文'}设置主题下可切换日间、跟随系统和夜间',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      final AppModel model = _testAppModel(database: db);
      final ReaderSettings? previousSettings = ReaderFushiSource.readerSettings;
      final VoidCallback? previousLive =
          ReaderFushiSource.onSettingsChangedLive;
      ReaderFushiSource.readerSettings = ReaderSettings(db)
        ..applyPrefsSnapshot(const <String, String>{});
      int liveChanges = 0;
      int styleChanges = 0;
      int themeChanges = 0;
      ReaderFushiSource.onSettingsChangedLive = () => liveChanges++;
      addTearDown(() {
        ReaderFushiSource.readerSettings = previousSettings;
        ReaderFushiSource.onSettingsChangedLive = previousLive;
      });

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 272,
                  child: Consumer(
                    builder: (context, ref, _) => ReaderQuickSettingsSheet(
                      controller: null,
                      toc: const [],
                      readerProgress: const (1, 3),
                      onJumpSection: (_, __) async {},
                      onExitReader: () {},
                      webViewController: _FakeInAppWebViewController(),
                      appModel: model,
                      ref: ref,
                      isFushiReader: true,
                      lyricsMode: lyricsMode,
                      presentation:
                          ReaderQuickSettingsPresentation.sideSheetAppearance,
                      onStyleChanged: () async => styleChanges++,
                      onThemeChanged: () async => themeChanges++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder brightnessRow = find.byWidgetPredicate(
        (Widget widget) =>
            widget is AdaptiveSettingsSegmentedRow<String> &&
            widget.title == t.dark_mode,
      );
      expect(brightnessRow, findsOneWidget);
      expect(tester.getTopLeft(brightnessRow).dy,
          greaterThan(tester.getTopLeft(find.text(t.reader_theme)).dy));
      for (final IconData icon in <IconData>[
        Icons.light_mode_outlined,
        Icons.brightness_auto_outlined,
        Icons.dark_mode_outlined,
      ]) {
        final Finder segment = find.descendant(
          of: brightnessRow,
          matching: find.byIcon(icon),
        );
        expect(segment.hitTestable(), findsOneWidget);
        expect(tester.getRect(segment).left, greaterThanOrEqualTo(48));
        expect(tester.getRect(segment).right, lessThanOrEqualTo(320));
      }

      for (final (String, IconData) choice in <(String, IconData)>[
        ('dark', Icons.dark_mode_outlined),
        ('light', Icons.light_mode_outlined),
        ('system', Icons.brightness_auto_outlined),
      ]) {
        final int liveBefore = liveChanges;
        final int styleBefore = styleChanges;
        final int themeBefore = themeChanges;
        await tester.tap(find.descendant(
          of: brightnessRow,
          matching: find.byIcon(choice.$2),
        ));
        await tester.pumpAndSettle();

        expect(model.themeNotifier.brightnessMode, choice.$1);
        expect(
            await db.getPref('brightness_mode'), PrefCodec.encode(choice.$1));
        expect(
          tester
              .widget<AdaptiveSettingsSegmentedRow<String>>(brightnessRow)
              .selected,
          choice.$1,
        );
        expect(ReaderFushiSource.instance.readerTheme, model.appThemeKey);
        expect(liveChanges, greaterThan(liveBefore));
        expect(styleChanges, styleBefore + 1);
        expect(themeChanges, themeBefore + 1);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('手机 320 宽设置抽屉复用布局显示内容且无溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel model = _testAppModel();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerRight,
              // 与真实路由一致，320 宽窗口保留 48px 的点外关闭区域。
              child: SizedBox(
                width: 272,
                child: Consumer(
                  builder: (context, ref, _) => ReaderQuickSettingsSheet(
                    controller: null,
                    toc: const [],
                    readerProgress: const (1, 3),
                    onJumpSection: (_, __) async {},
                    onExitReader: () {},
                    webViewController: _FakeInAppWebViewController(),
                    appModel: model,
                    ref: ref,
                    isFushiReader: true,
                    presentation:
                        ReaderQuickSettingsPresentation.sideSheetAppearance,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(t.reader_theme), findsOneWidget);
    expect(find.byType(FushiSegmentedStrip<String>), findsOneWidget);
    final Finder close = find.byKey(
      const ValueKey<String>('fushi_side_sheet_close'),
    );
    expect(tester.getRect(close).right, lessThanOrEqualTo(320));

    await tester.ensureVisible(find.text(t.settings_destination_lookup));
    await tester.tap(find.text(t.settings_destination_lookup));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(t.auto_read_on_lookup), findsOneWidget);
  });

  testWidgets('audiobook play bar keeps lyrics mode out of bottom bar',
      (tester) async {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AudiobookPlayBar(
            controller: controller,
            onOpenSettings: () {},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.lyrics), findsNothing);
    expect(find.byIcon(Icons.auto_stories), findsNothing);
  });

  testWidgets('in-book settings sheet uses adaptive settings rows',
      (tester) async {
    // 窄窗：< 640 走单列内联 + push（本用例的语义）。宽窗 master-detail 由
    // 单独的 wide 用例覆盖。
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ReaderQuickSettingsSheet(
                controller: null,
                toc: const [],
                readerProgress: const (1, 3),
                onJumpSection: (_, __) async {},
                onExitReader: () {},
                webViewController: _FakeInAppWebViewController(),
                appModel: _testAppModel(),
                ref: ref,
                isFushiReader: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AdaptiveSettingsNavigationRow), findsWidgets);
    // TODO-725（手机/窄窗折叠）：主页只剩「进度 + 分类导航行 + 动作行」。
    // TODO-802：外观分类整组删除，主页不再有「外观」导航行。
    expect(find.text(t.settings_destination_appearance), findsNothing);
    expect(find.text(t.section_layout), findsOneWidget);
    expect(find.text(t.settings_destination_reading_controls), findsOneWidget);
    expect(find.text(t.settings_destination_lookup), findsOneWidget);
    expect(find.text(t.section_navigation), findsOneWidget);
    // 主页不渲染内联「排版设置」卡标题 / 主题选择器 / 字号步进（都在 layout 子页）。
    expect(find.text(t.display_settings), findsNothing);
    expect(find.text(t.reader_theme), findsNothing);
    expect(find.byType(FushiSchemeSwatch), findsNothing);
    expect(find.text(t.reader_font_size), findsNothing);
    expect(find.byType(ListTile), findsNothing);

    await tester.ensureVisible(find.text(t.settings_destination_lookup));
    await tester.tap(find.text(t.settings_destination_lookup));
    await tester.pumpAndSettle();

    expect(find.text(t.auto_read_on_lookup), findsOneWidget);
    expect(find.text(t.pause_on_lookup), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(t.section_layout));
    await tester.tap(find.text(t.section_layout));
    await tester.pumpAndSettle();

    // TODO-802：主题选择器并入「布局与显示」子页顶部（外观组已删）。
    expect(find.text(t.reader_theme), findsOneWidget);
    expect(find.byType(FushiSchemeSwatch), findsWidgets);
    // TODO-774：字号/行高（schema 投影）也在 layout 子页。
    expect(find.text(t.reader_font_size), findsOneWidget);
    expect(find.text(t.reader_line_height), findsOneWidget);
    // TODO-725：翻页/滚动（view_mode）现归「布局与显示」组，进 layout 子页可见。
    expect(find.text(t.reader_view_mode_label), findsOneWidget);
    // Schema-projected segmented items render as AdaptiveSettingsSegmentedRow
    // with the renderer's erased <Object> type arg, not the bespoke <String>.
    expect(
      find.byType(AdaptiveSettingsSegmentedRow<Object>),
      findsWidgets,
    );
    expect(find.byType(AdaptiveSettingsStepperRow), findsWidgets);
    expect(find.byType(ListTile), findsNothing);
  });

  // BUG-2166 批：桌面 ッツ 形态把书内设置从「宽窗 master-detail」改成了左右
  // 抽屉。路由真相源是 readerAudiobookUsesSideSheet（reader_desktop_chrome.dart），它
  // 与 master-detail 外壳判宽用的是**同一对阈值** 560×440 —— 所以窗口一旦够宽
  // 就走抽屉，sheet 形态永远到不了宽窗分支（代码注释里也写明「宽窗不再有
  // master-detail」）。原来这两条测试是直接 pump ReaderQuickSettingsSheet
  // 绕过路由、硬造了一个生产里不存在的组合。
  //
  // 这里把它们换成对**新形态**的覆盖（此前 sideSheet* 在 test/ 下零覆盖），
  // 并加一条纯函数断言把路由真相源钉住。BUG-096 的「固定头 + 可滚内容」原
  // 不变式另有 master_detail_settings_sheet_test 与
  // video_player_settings_master_detail_guard_test 两处仍在守。
  test('有声书面板容器独立于各平台共用的设置抽屉', () {
    // 有声书宽窗 → 右侧侧栏；窄窗 → bottom sheet，保持手机的空间利用。
    expect(
        readerAudiobookUsesSideSheet(
            desktop: false, window: const Size(1000, 800)),
        isTrue);
    expect(
        readerAudiobookUsesSideSheet(
            desktop: false, window: const Size(420, 1600)),
        isFalse);
    // 桌面端有声书恒走侧栏。
    expect(
        readerAudiobookUsesSideSheet(desktop: true, window: const Size(420, 400)),
        isTrue);
  });

  testWidgets('桌面「设置」抽屉：三组分段同屏、无 push 返回箭头', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ReaderQuickSettingsSheet(
                controller: null,
                toc: const [],
                readerProgress: const (1, 3),
                onJumpSection: (_, __) async {},
                onExitReader: () {},
                webViewController: _FakeInAppWebViewController(),
                appModel: _testAppModel(),
                ref: ref,
                isFushiReader: true,
                presentation:
                    ReaderQuickSettingsPresentation.sideSheetAppearance,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 「设置」抽屉：顶部一条分段条把分类摊平同屏切换（导航 / 有声书不在这里，
    // 它们各有自己的 presentation），默认落在第一组「布局显示」上。
    expect(find.byType(FushiSegmentedStrip<String>), findsOneWidget);
    expect(find.text(t.section_layout), findsWidgets);
    // 导航分类被排除（它是 sideSheetNavigation 的地盘）。
    expect(find.text(t.reading_progress), findsNothing);
    // 抽屉是同屏切换、没有 push：既无返回箭头，也不该出现带 chevron 的导航行
    // （歌词模式那一行是唯一例外，它在 layout 组末尾且是「切模式」而非 push）。
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    // 默认组即 layout：主题行直接可见，不需要再点一层。
    expect(find.text(t.reader_theme), findsOneWidget);
    expect(find.byType(AdaptiveSettingsSegmentedRow<Object>), findsWidgets);
  });

  testWidgets('reader exit is deferred and only scheduled once',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    int exitCount = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ReaderQuickSettingsSheet(
                controller: null,
                toc: const [],
                readerProgress: const (1, 3),
                onJumpSection: (_, __) async {},
                onExitReader: () {
                  exitCount += 1;
                },
                webViewController: _FakeInAppWebViewController(),
                appModel: _testAppModel(),
                ref: ref,
                isFushiReader: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.ensureVisible(find.text(t.action_exit));
    final Finder exitButton = find.ancestor(
      of: find.text(t.action_exit),
      matching: find.byType(InkWell),
    );
    expect(exitButton, findsOneWidget);
    final Offset exitButtonCenter = tester.getCenter(exitButton);
    await tester.tapAt(exitButtonCenter);
    await tester.tapAt(exitButtonCenter);

    expect(exitCount, 0);

    await tester.pump();
    expect(exitCount, 1);

    await tester.pump();
    expect(exitCount, 1);
  });

  testWidgets('桌面「导航」抽屉：标题栏固定，章节内容独立滚动（BUG-096 语义）', (tester) async {
    // 原用例锁的是宽窗 master-detail 的「左父菜单不跟着右详情滚」。BUG-2166 批
    // 把那个形态删了（宽窗一律走抽屉），BUG-096 的外壳级不变式仍由
    // master_detail_settings_sheet_test / video_player_settings_master_detail
    // 两处守着。这里把同一条语义搬到新宿主：抽屉的标题栏是固定头，内容区滚动
    // 时它必须纹丝不动。
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ReaderQuickSettingsSheet(
                controller: null,
                toc: const [],
                readerProgress: const (1, 3),
                onJumpSection: (_, __) async {},
                onExitReader: () {},
                webViewController: _FakeInAppWebViewController(),
                appModel: _testAppModel(),
                ref: ref,
                isFushiReader: true,
                presentation:
                    ReaderQuickSettingsPresentation.sideSheetNavigation,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder header = find.text(t.section_navigation);
    expect(header, findsOneWidget, reason: '导航抽屉必须有固定标题栏');
    final Offset headerBefore = tester.getTopLeft(header);

    // 在内容区向上拖：内容滚动，标题栏不得跟着走。
    await tester.dragFrom(const Offset(850, 500), const Offset(0, -160));
    await tester.pump();

    expect(
      tester.getTopLeft(header),
      headerBefore,
      reason: '抽屉标题栏必须固定，不能跟随内容一块滚（BUG-096 语义）',
    );
  });

  testWidgets('in-book navigation lists avoid legacy Material tiles',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ReaderQuickSettingsSheet(
                controller: null,
                toc: const [
                  TtuTocEntry(index: 0, label: 'Opening'),
                  TtuTocEntry(index: 1, label: 'Chapter 1'),
                ],
                readerProgress: const (1, 2),
                onJumpSection: (_, __) async {},
                onExitReader: () {},
                webViewController: _FakeInAppWebViewController(),
                appModel: _testAppModel(),
                ref: ref,
                favoriteSentences: [
                  FavoriteSentence(
                    text: 'A highlighted sentence from the current book.',
                    bookTitle: 'Current Book',
                    chapterLabel: 'Chapter 1',
                    sectionIndex: 1,
                    normCharOffset: 120,
                    createdAt: DateTime(2026, 5, 25, 12),
                  ),
                ],
                onJumpToFavorite: (_) async {},
                onDeleteFavorite: (_) async {},
                isFushiReader: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.ensureVisible(find.text(t.section_navigation));
    await tester.tap(find.text(t.section_navigation));
    await tester.pumpAndSettle();

    expect(find.text('Opening'), findsOneWidget);
    expect(find.textContaining('A highlighted sentence'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byType(AdaptiveSettingsSection), findsWidgets);
  });
}
