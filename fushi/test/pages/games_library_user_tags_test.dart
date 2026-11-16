import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1113「游戏没有标签」的 UI 侧守卫：游戏库页必须接上书架 / 视频页那套**共享**
/// 用户标签体系——同一个标签池、同一套 AND 筛选（筛选面板「我的标签」分组）、
/// 同一个 [TagPickerPage] 打标签入口。
///
/// 全部经真 [GamesLibraryPage] + 真 Drift 表（内存库）走，不 mock：接没接上、筛没筛
/// 中、入口通不通，由这一层钉死。
void main() {
  late GlobalKey<NavigatorState> navKey;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<(AppModel, FushiDatabase)> buildModel() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir = Directory.systemTemp.createTempSync(
      'fushi_games_user_tags_',
    );
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tmpDir,
      )
      ..wireDatabaseForTesting(db);

    await appModel.setGalgames(<GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'alpha',
        exePath: r'Z:\a\alpha.exe',
        workdir: r'Z:\a',
        addedAt: DateTime(2026, 1, 1),
      ),
      GalgameEntry(
        id: 'g2',
        name: 'beta',
        exePath: r'Z:\b\beta.exe',
        workdir: r'Z:\b',
        addedAt: DateTime(2026, 1, 2),
      ),
    ]);
    return (appModel, db);
  }

  Finder cardTitle(String title) => find.descendant(
    of: find.byType(CustomScrollView),
    matching: find.text(title),
  );

  Future<void> pumpPage(WidgetTester tester, AppModel appModel) async {
    navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((_) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const FushiFocusRoot(child: GamesLibraryPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 焦点驱动：把焦点交给 [target] 所在的控件焦点节点，再按 Enter（不点坐标）。
  Future<void> enterOn(WidgetTester tester, Finder target) async {
    final FocusNode node = Focus.of(tester.element(target));
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  /// 打开筛选面板（设计稿「游戏 · 库」：用户标签筛选并进筛选面板，不再单占一行
  /// 标签 chip）。
  Future<void> openFilterPanel(WidgetTester tester) => enterOn(
    tester,
    find
        .descendant(
          of: find.byTooltip(t.game_filter),
          matching: find.byType(FushiIcon),
        )
        .first,
  );

  Finder userTagChip(int tagId, String name) => find.descendant(
    of: find.byKey(ValueKey<String>('games_filter_user_tag_$tagId')),
    matching: find.text(name),
  );

  Future<void> closeFilterPanel(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  testWidgets('用户标签筛选并进筛选面板，chip 出自共享标签池', (WidgetTester tester) async {
    final (AppModel appModel, FushiDatabase db) = await buildModel();
    final int tagId = await db.createTag('神作', 0xFFEF5350);
    await pumpPage(tester, appModel);

    // 页面上不再有单独一行标签 chip（工具行行尾只留「管理标签」）。
    expect(
      find.descendant(
        of: find.byType(FushiTagFilterBar),
        matching: find.text('神作'),
      ),
      findsNothing,
    );

    await openFilterPanel(tester);
    expect(
      find.byKey(const ValueKey<String>('games_filter_user_tags')),
      findsOneWidget,
      reason: '筛选面板里要有「我的标签」分组（共享标签池）',
    );
    expect(userTagChip(tagId, '神作'), findsOneWidget);
  });

  testWidgets('面板里选标签只留挂了该标签的游戏，再选取消恢复全部', (WidgetTester tester) async {
    final (AppModel appModel, FushiDatabase db) = await buildModel();
    final int tagId = await db.createTag('神作', 0xFFEF5350);
    await db.addTagToGame('g1', tagId);
    await pumpPage(tester, appModel);

    expect(cardTitle('alpha'), findsOneWidget);
    expect(cardTitle('beta'), findsOneWidget);

    await openFilterPanel(tester);
    await enterOn(tester, userTagChip(tagId, '神作'));
    await closeFilterPanel(tester);

    expect(cardTitle('alpha'), findsOneWidget, reason: 'g1 挂了该标签');
    expect(cardTitle('beta'), findsNothing, reason: 'g2 没挂，必须被筛掉');

    await openFilterPanel(tester);
    await enterOn(tester, userTagChip(tagId, '神作'));
    await closeFilterPanel(tester);

    expect(cardTitle('alpha'), findsOneWidget);
    expect(cardTitle('beta'), findsOneWidget);
  });

  testWidgets('全部游戏都不挂选中标签时给「没有符合筛选」空态，而不是空库文案', (WidgetTester tester) async {
    final (AppModel appModel, FushiDatabase db) = await buildModel();
    final int tagId = await db.createTag('神作', 0xFFEF5350);
    await pumpPage(tester, appModel);

    await openFilterPanel(tester);
    await enterOn(tester, userTagChip(tagId, '神作'));
    await closeFilterPanel(tester);

    // i18n key 是 game_*（命名术语表禁用 games_ 前缀），生产代码用的也是
    // games_library_page.dart 的 t.game_empty / t.game_no_match。
    expect(find.text(t.game_no_match), findsOneWidget);
    expect(find.text(t.game_empty), findsNothing);
    // 「清除筛选」连同用户标签一起清（原 chip 行并进面板后由同一个按钮负责）。
    expect(find.text(t.game_filter_reset), findsOneWidget);
  });

  testWidgets('卡片菜单有「标签」项，点开进共享标签选择器并真写穿 DB', (WidgetTester tester) async {
    final (AppModel appModel, FushiDatabase db) = await buildModel();
    final int tagId = await db.createTag('神作', 0xFFEF5350);
    await pumpPage(tester, appModel);

    // 2026-10-25 卡盒卡定版（2abfd1327b）：封面上不再放 ⋯ 按钮，菜单走长按 /
    // 右键 / 手柄长按 A，打开的是同一份 galgameItemMenuItems。长按 g1（alpha）的卡。
    await tester.longPress(cardTitle('alpha'));
    await tester.pumpAndSettle();
    expect(find.text(t.tag_label), findsOneWidget);

    // 菜单项多于 800x600 视口能放下的行数时菜单自身可滚：先滚到该项再点。
    await tester.ensureVisible(find.text(t.tag_label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.tag_label));
    await tester.pumpAndSettle();
    expect(
      find.byType(TagPickerPanel),
      findsOneWidget,
      reason: '复用书/视频/合集那张选择器，不另做一套游戏专用的',
    );

    // 勾上标签：必须真落 galgame_tag_mappings（不是只改本地 state）。
    await tester.tap(
      find.descendant(
        of: find.byType(TagPickerPanel),
        matching: find.text('神作'),
      ),
    );
    await tester.pumpAndSettle();

    final List<BookTagRow> tags = await db.getTagsForGame('g1');
    expect(tags.map((BookTagRow t) => t.id).toList(), <int>[tagId]);
  });
}
