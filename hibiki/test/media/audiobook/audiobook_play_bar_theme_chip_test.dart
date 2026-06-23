import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';
import 'package:hibiki/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../../helpers/test_platform_services.dart';

class _FakeInAppWebViewController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppModel _testAppModel() {
  final HibikiDatabase db = HibikiDatabase.forTesting(
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
                onJumpSection: (_) async {},
                onBookmark: () async {},
                onExitReader: () {},
                webViewController: _FakeInAppWebViewController(),
                appModel: _testAppModel(),
                ref: ref,
                isHibikiReader: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AdaptiveSettingsNavigationRow), findsWidgets);
    // TODO-725（手机/窄窗折叠）：主页只剩「进度 + 分类导航行 + 动作行」。外观也
    // 降级成导航行（默认折叠），不再内联平铺。
    expect(find.text(t.settings_destination_appearance), findsOneWidget);
    expect(find.text(t.section_layout), findsOneWidget);
    expect(find.text(t.settings_destination_reading_controls), findsOneWidget);
    expect(find.text(t.settings_destination_lookup), findsOneWidget);
    expect(find.text(t.section_navigation), findsOneWidget);
    // 外观不再内联：主页不渲染内联「排版设置」卡标题 / 主题选择器 / 字号步进。
    expect(find.text(t.display_settings), findsNothing);
    expect(find.text(t.ttu_theme), findsNothing);
    expect(find.byType(HibikiSchemeSwatch), findsNothing);
    expect(find.text(t.ttu_font_size), findsNothing);
    expect(find.byType(ListTile), findsNothing);

    // 点进「外观」子页：主题选择器 + 字号/行高（schema 投影）此时才出现。
    await tester.ensureVisible(find.text(t.settings_destination_appearance));
    await tester.tap(find.text(t.settings_destination_appearance));
    await tester.pumpAndSettle();
    expect(find.text(t.ttu_theme), findsOneWidget);
    expect(find.byType(HibikiSchemeSwatch), findsWidgets);
    expect(find.text(t.ttu_font_size), findsOneWidget);
    expect(find.text(t.ttu_line_height), findsOneWidget);
    expect(find.byType(AdaptiveSettingsStepperRow), findsWidgets);
    expect(find.byType(ListTile), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
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

    // TODO-725：翻页/滚动（view_mode）现归「布局与显示」组，进 layout 子页可见。
    expect(find.text(t.ttu_view_mode_label), findsOneWidget);
    // Schema-projected segmented items render as AdaptiveSettingsSegmentedRow
    // with the renderer's erased <Object> type arg, not the bespoke <String>.
    expect(
      find.byType(AdaptiveSettingsSegmentedRow<Object>),
      findsWidgets,
    );
    expect(find.byType(AdaptiveSettingsStepperRow), findsWidgets);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('in-book settings shows master-detail on wide windows',
      (tester) async {
    // 宽窗：>= 640 走左父菜单 + 右详情同屏（master-detail）。
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
                onJumpSection: (_) async {},
                onBookmark: () async {},
                onExitReader: () {},
                webViewController: _FakeInAppWebViewController(),
                appModel: _testAppModel(),
                ref: ref,
                isHibikiReader: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // TODO-725：左 pane 列出全部分类（导航置首，默认选中「导航/location」）。
    // 右 pane 默认显示 location 详情顶部并入的阅读进度，外观主题行此时**不**出现
    // （它在点开「外观」分类后才渲染）。
    expect(find.text(t.settings_destination_appearance), findsOneWidget);
    expect(find.text(t.section_navigation), findsOneWidget);
    expect(find.text(t.section_layout), findsOneWidget);
    expect(find.text(t.reading_progress), findsOneWidget);
    expect(find.text(t.ttu_theme), findsNothing);
    // master-detail 无 push：无返回箭头；左 pane 不再用带 chevron 的导航行。
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.byType(AdaptiveSettingsNavigationRow), findsNothing);

    // 选「外观」→ 右 pane 切到外观详情（主题行出现），仍无返回箭头。
    await tester.tap(find.text(t.settings_destination_appearance));
    await tester.pumpAndSettle();
    expect(find.text(t.ttu_theme), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    // 选「布局」→ 右 pane 切到布局详情（schema 投影的分段行），仍无返回箭头。
    await tester.tap(find.text(t.section_layout));
    await tester.pumpAndSettle();
    expect(find.byType(AdaptiveSettingsSegmentedRow<Object>), findsWidgets);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  testWidgets(
      'wide in-book settings keeps the left pane fixed while the right scrolls '
      '(BUG-096)', (tester) async {
    // 用户报：宽窗书内设置「整个页面一块滚动、左边不固定」。根因=frame 外层
    // SingleChildScrollView 给 master-detail 无界高度 → 左右一块滚。回归锁：让右
    // 详情（布局，行多）溢出可滚，拖右 pane 时左父菜单必须纹丝不动。
    //
    // 高度取 760（够 reader 左父菜单放下 → 进 master-detail）：左父菜单更高
    // （进度+5分类+动作），太矮（如旧的 380）会触发「左栏溢出回退 push」的新
    // 行为而非分栏（push 回退本身另有 video 用例覆盖）。
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
                onJumpSection: (_) async {},
                onBookmark: () async {},
                onExitReader: () {},
                webViewController: _FakeInAppWebViewController(),
                appModel: _testAppModel(),
                ref: ref,
                isHibikiReader: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 选「布局」让右 pane 内容变长（必然超过 380 高 → 可独立滚动）。
    await tester.tap(find.text(t.section_layout));
    await tester.pumpAndSettle();

    // 左父菜单里的「外观」分类项作为锚点：只出现在左 pane（右 pane 现是布局）。
    final Finder leftAnchor = find.text(t.settings_destination_appearance);
    expect(leftAnchor, findsOneWidget);
    final Offset leftBefore = tester.getTopLeft(leftAnchor);

    // 在右 pane 区域（x=850，远在左 pane 之外）向上拖：修好后只滚右 pane，
    // 左父菜单不动；若回归成「一块滚」，这一拖会带着左锚点一起上移。
    await tester.dragFrom(const Offset(850, 250), const Offset(0, -160));
    await tester.pump();

    final Offset leftAfter = tester.getTopLeft(leftAnchor);
    expect(
      leftAfter,
      leftBefore,
      reason: '左父菜单必须固定，不能跟随右详情滚动（BUG-096：整页一块滚）',
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
                onJumpSection: (_) async {},
                onBookmark: () async {},
                onExitReader: () {},
                webViewController: _FakeInAppWebViewController(),
                appModel: _testAppModel(),
                ref: ref,
                bookmarks: [
                  Bookmark(
                    sectionIndex: 1,
                    normCharOffset: 120,
                    label: 'Saved page',
                    createdAt: DateTime(2026, 5, 25, 12),
                  ),
                ],
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
                onJumpToBookmark: (_) async {},
                onDeleteBookmark: (_) async {},
                onJumpToFavorite: (_) async {},
                onDeleteFavorite: (_) async {},
                isHibikiReader: true,
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
    expect(find.text('Saved page'), findsOneWidget);
    expect(find.textContaining('A highlighted sentence'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byType(AdaptiveSettingsSection), findsWidgets);
  });
}
