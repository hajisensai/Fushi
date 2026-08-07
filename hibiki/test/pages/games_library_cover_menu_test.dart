import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart'
    show MediaItemDialogFrame;
import 'package:fushi/utils.dart';

import '../helpers/test_platform_services.dart';

/// 游戏卡封面入口守卫：视频/合集早就能自定义封面，游戏库过去只有「重命名 / 移除」，
/// `GalgameEntry.coverPath` 字段无人写 → 每张卡永远是默认手柄图标。
///
/// 本测试钉住两条：
/// 1. 卡片溢出菜单与长按/右键菜单**都**含「设置封面」「自动获取封面」（两处菜单
///    共用同一份 `_menuItems`，任一处漏项都会红）；
/// 2. 有 coverPath 且文件真实存在时，卡片渲染的是 [Image]（封面），而不是占位图标。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<AppModel> buildModel(List<GalgameEntry> games) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_game_cover_menu_');
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir)
      // v54：游戏库真相源是 Drift 表，仓储绑 AppModel.database，测试必须注入。
      ..wireDatabaseForTesting(db);
    await appModel.setGalgames(games);
    return appModel;
  }

  Future<void> pumpPage(WidgetTester tester, AppModel appModel) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    HibikiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((_) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const HibikiFocusRoot(child: GamesLibraryPage()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 卡片菜单应含的全部项，**按三库页统一次序**（重命名 → 封面类 → 刮削 →
  /// 加入合集 → 标签 → 删除；游戏特有的详情/状态保持最前）。与
  /// `_GameCard._menuItems` 单一真相源对账：漏项或乱序本表即断言失败。
  /// 'remove' 在长按对话框落危险区，但文案仍必须在场。
  ///
  /// 「窗口超分 · <当前档>」是 Windows-only（galgame hook 与 Magpie 都只做 Windows），
  /// 所以两个分支都要断言：Windows 上必须在场，非 Windows 上必须不在场——后者正是
  /// Linux CI 会跑到的分支，它守的是「平台门没被顺手删掉」。
  List<String> menuLabels() => <String>[
        t.game_view_detail,
        t.game_play_status,
        t.game_rename,
        t.game_set_cover,
        t.game_auto_cover,
        t.game_scrape,
        t.add_to_collection,
        t.tag_label,
        if (Platform.isWindows) '${t.game_upscaling} · ${t.game_upscaling_off}',
        t.game_remove,
      ];

  testWidgets('溢出菜单项齐全（含设置封面 / 自动获取封面 / 加入合集）', (WidgetTester tester) async {
    final AppModel appModel = await buildModel(<GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'テスト',
        exePath: r'Z:\missing\game.exe',
        workdir: r'Z:\missing',
        addedAt: DateTime(2026),
      ),
    ]);
    await pumpPage(tester, appModel);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    for (final String label in menuLabels()) {
      expect(find.text(label), findsOneWidget, reason: '溢出菜单缺「$label」');
    }

    // 次序也要钉住（统一约定：重命名 → 封面类 → 刮削 → 加入合集 → 标签 → 删除）。
    final List<String> shown = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .map((PopupMenuItem<String> item) => (item.child! as Text).data!)
        .toList();
    expect(shown, menuLabels(), reason: '溢出菜单次序偏离三库页统一约定');
  });

  testWidgets('长按菜单走 MediaItemDialogFrame 且与溢出菜单项一致',
      (WidgetTester tester) async {
    final AppModel appModel = await buildModel(<GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'テスト',
        exePath: r'Z:\missing\game.exe',
        workdir: r'Z:\missing',
        addedAt: DateTime(2026),
      ),
    ]);
    await pumpPage(tester, appModel);

    await tester.longPress(find.text('テスト', skipOffstage: false).first);
    await tester.pumpAndSettle();

    // 与书/视频卡同款对话框骨架（不再是手搓 SimpleDialog）。
    expect(find.byType(MediaItemDialogFrame), findsOneWidget);
    for (final String label in menuLabels()) {
      expect(
        find.descendant(
          of: find.byType(MediaItemDialogFrame),
          matching: find.text(label),
        ),
        findsOneWidget,
        reason: '长按菜单缺「$label」（须与溢出菜单同源同项）',
      );
    }
  });

  testWidgets('有封面文件时卡片渲染封面图而非占位图标', (WidgetTester tester) async {
    final Directory dir =
        Directory.systemTemp.createTempSync('hibiki_game_cover_render_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    // 1×1 PNG：只需要文件真实存在且能被 Image.file 拿到。
    final File cover = File('${dir.path}${Platform.pathSeparator}g1.png')
      ..writeAsBytesSync(_onePixelPng);

    final AppModel appModel = await buildModel(<GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'テスト',
        exePath: r'Z:\missing\game.exe',
        workdir: r'Z:\missing',
        coverPath: cover.path,
        addedAt: DateTime(2026),
      ),
    ]);
    await pumpPage(tester, appModel);

    // 封面统一走 ShelfFileCover（BUG-959：resizedFileImage 降采样 + FadeInImage），
    // 底层 provider 是 ResizeImage 包 FileImage——两层都断言，防退回裸 Image.file。
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is FadeInImage &&
            w.image is ResizeImage &&
            (w.image as ResizeImage).imageProvider is FileImage,
      ),
      findsOneWidget,
      reason: 'coverPath 指向的文件存在时必须经降采样封面加载器渲染封面图',
    );
  });
}

/// 最小合法 PNG（1×1，透明）。
final List<int> _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
