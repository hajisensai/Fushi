/// 漫画阅读器顶栏重设计的像素证据：固定态（栏常驻、正文让位）与悬浮态（默认收起）。
///
/// 造一本两页的本地漫画直接推 [MangaFushiPage]，抓根 RenderView 帧
/// （`captureFlutterFrame`：顶栏是 Flutter 层，WebView 纹理抓不到、本就不是本跑的
/// 证明对象）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/generate_test_image.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('漫画顶栏：固定态常驻让位 / 悬浮态默认收起', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);

    final Directory bookDir =
        Directory.systemTemp.createTempSync('manga_chrome_shot_');
    const TestImageGenerator gen = TestImageGenerator();
    final Directory images = Directory(p.join(bookDir.path, 'images'))
      ..createSync();
    File(p.join(images.path, 'p001.png'))
        .writeAsBytesSync(gen.pngBytes(width: 800, height: 1200, seed: 1));
    File(p.join(images.path, 'p002.png'))
        .writeAsBytesSync(gen.pngBytes(width: 800, height: 1200, seed: 2));
    File(p.join(bookDir.path, 'manga.json')).writeAsStringSync(jsonEncode(
      <String, Object?>{
        'pages': <Map<String, Object?>>[
          for (final String name in <String>['p001.png', 'p002.png'])
            <String, Object?>{
              'url': name,
              'width': 800,
              'height': 1200,
              'blocks': <Object?>[],
            },
        ],
      },
    ));
    const String bookKey = 'chrome-shot-manga';
    await appModel.database.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: 'ゆるキャン△ 第1巻',
      epubPath: 'manga.json',
      extractDir: bookDir.path,
      chapterCount: 2,
      chaptersJson: '[]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
      format: const Value<String>('manga'),
    ));

    final bool floatingBefore = appModel.mangaChromeFloating;
    try {
      for (final bool floating in <bool>[false, true]) {
        await appModel.setMangaChromeFloating(floating);
        final NavigatorState nav = appModel.navigatorKey.currentState!;
        final BuildContext navContext = nav.context;
        if (!navContext.mounted) fail('navigator context unmounted');
        unawaited(nav.push(adaptivePageRoute<void>(
          context: navContext,
          builder: (BuildContext context) => const FushiAppUiScaleNeutralizer(
            child: MangaFushiPage(item: null, bookKey: bookKey),
          ),
        )));
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (find
              .byKey(const ValueKey<String>('manga_content_ready'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        await tester.pump(const Duration(seconds: 2));
        final String tag = floating ? 'floating' : 'pinned';
        final ObserveShot shot =
            await captureFlutterFrame(tester, '01-manga-chrome-$tag');
        expect(shot.saved, isTrue);
        final bool barPainted = find
            .byKey(const ValueKey<String>('manga_reader_top_bar'))
            .evaluate()
            .isNotEmpty;
        final Rect body = tester.getRect(
            find.byKey(const ValueKey<String>('manga_content_ready')));
        debugPrint('[manga-chrome] floating=$floating barPainted=$barPainted '
            'bodyTop=${body.top} shot=${shot.path}');
        expect(barPainted, !floating,
            reason: '固定态栏常驻；悬浮态默认收起');
        expect(body.top > 0, !floating, reason: '固定态正文让位；悬浮态全出血');
        nav.pop();
        await tester.pump(const Duration(seconds: 1));
      }
    } finally {
      await appModel.setMangaChromeFloating(floatingBefore);
      if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
    }
  });
}
