import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/manga/manga_spread_model.dart';
import 'package:hibiki/src/media/manga/manga_view_prefs.dart';
import 'package:hibiki/src/media/media_item.dart';
import 'package:hibiki/src/pages/implementations/manga_hibiki_page.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// 与 manga_hibiki_page_test 同款测试 AppModel（内存库 + 弹窗布局 getter）。
class _MangaTestAppModel extends AppModel {
  _MangaTestAppModel(this._db) : super(testPlatformServices());

  final HibikiDatabase _db;

  @override
  HibikiDatabase get database => _db;

  @override
  bool get lowMemoryMode => false;

  @override
  double get popupMaxWidth => 360;

  @override
  double get popupMaxHeight => 360;

  @override
  bool get popupBottomDocked => false;

  @override
  double get appUiScale => 1.0;

  // PR#474 把跨页偏好/阅读方向/缩放从运行时常量改成 AppModel 持久化偏好，
  // 这三个 getter 会走 `prefsRepo`；测试 AppModel 从不跑 initialise()，不覆写
  // 会在 `_loadBook` 里抛 null-check 并让页面卡在加载态。姊妹测试
  // manga_hibiki_page_test.dart 已补，这里当时漏了（BUG-1164）。
  // 取值与实现字段默认值一致，守卫语义与 PR#474 前等价。
  @override
  String get mangaSpreadPreference => 'auto';

  @override
  String get mangaReadingDirection => 'rtl';

  @override
  int get mangaZoomPercent => 100;

  // 观看偏好同样必须在 fake 上给出真值：AppModel 这些 getter 都走 prefsRepo，
  // 而测试里 _prefsRepo 是 null（`prefsRepo` 是 `_prefsRepo!`）。漏一个就在
  // _loadBook 里抛 _TypeError，表现为页面永远不 ready。
  @override
  int get mangaZoomSensitivity => kMangaZoomSensitivityDefault;

  @override
  String get mangaPageAnimation => MangaPageAnimation.slide.key;

  @override
  bool get mangaTapZonePaging => true;

  @override
  bool get mangaVolumeKeyPaging => false;
}

Widget _harness(AppModel appModel, String bookKey) {
  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: MangaHibikiPage(
          item: MediaItem(
            mediaIdentifier: 'hoshi://book/$bookKey',
            mediaSourceIdentifier: 'reader_manga',
            title: 'Test Manga',
            mediaTypeIdentifier: 'reader',
            position: 0,
            duration: 1,
            canDelete: false,
            canEdit: true,
          ),
          bookKey: bookKey,
        ),
      ),
    ),
  );
}

/// 四页竖版页图（100x150），无 OCR 框。
String _mangaJson() {
  return jsonEncode(<String, Object?>{
    'pages': <Map<String, Object?>>[
      for (int i = 1; i <= 4; i++)
        <String, Object?>{
          'url': 'p00$i.jpg',
          'width': 100,
          'height': 150,
          'blocks': <Object?>[],
        },
    ],
  });
}

Future<void> _pumpBook(
  WidgetTester tester,
  HibikiDatabase db,
  _MangaTestAppModel appModel,
  String bookKey,
  Directory bookDir, {
  int savedPage = 0,
}) async {
  await tester.runAsync(() async {
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: bookKey,
      epubPath: 'manga.json',
      extractDir: bookDir.path,
      chapterCount: 4,
      chaptersJson: '[]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
      format: const Value<String>('manga'),
    ));
    if (savedPage > 0) {
      await ReaderPositionRepository(db).save(
        bookKey: bookKey,
        sectionIndex: savedPage,
        normCharOffset: 0,
        charOffset: 0,
      );
    }
    await tester.pumpWidget(_harness(appModel, bookKey));
    for (int i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      if (find
          .byKey(const ValueKey<String>('manga_content_ready'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
  });
  await tester.pump();
}

Directory _bookDir() {
  final Directory dir =
      Directory.systemTemp.createTempSync('manga_double_widget_');
  File(p.join(dir.path, 'manga.json')).writeAsStringSync(_mangaJson());
  Directory(p.join(dir.path, 'images')).createSync();
  for (int i = 1; i <= 4; i++) {
    File(p.join(dir.path, 'images', 'p00$i.jpg')).writeAsBytesSync(<int>[i]);
  }
  return dir;
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('横屏视口自动双页：恢复页落进跨页并显示页码区间', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 700); // 横屏 → auto 双页
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final _MangaTestAppModel appModel = _MangaTestAppModel(db);
    final Directory bookDir = _bookDir();
    addTearDown(() {
      if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
    });

    // 预存第 3 页（0-based sectionIndex=2）：封面独占（spreadOffset=1）后
    // 配对 [0],[1,2],[3] → 跨页 1。
    await _pumpBook(tester, db, appModel, '横屏漫画', bookDir, savedPage: 2);

    expect(find.byKey(const ValueKey<String>('manga_content_ready')),
        findsOneWidget);
    expect(find.text('2-3 / 4'), findsOneWidget,
        reason: '横屏 auto 双页 + 封面独占：恢复到含第 3 页的跨页，指示区间 2-3');
    // 布局偏好菜单在 spread 模式下可见。
    expect(find.byType(PopupMenuButton<MangaSpreadPreference>), findsOneWidget);
  });

  testWidgets('竖屏视口自动单页：页码保持单页显示', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 1200); // 竖屏 → auto 单页
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final _MangaTestAppModel appModel = _MangaTestAppModel(db);
    final Directory bookDir = _bookDir();
    addTearDown(() {
      if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
    });

    await _pumpBook(tester, db, appModel, '竖屏漫画', bookDir, savedPage: 2);

    expect(find.text('3 / 4'), findsOneWidget, reason: '竖屏 auto 单页：第 3 页单页显示');
  });
}
