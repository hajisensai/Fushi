// 首页「收藏句子」小组件（HomeWidgetKind.favorites）：在 MD3 / Apple 两套设计、分区卡 /
// 海报色块两种外观下，按 1×1 / 2×1 / 2×2 / 4×2 / 6×3 抓真像素；再点标题进收藏夹，
// 看是不是停在「句子」页签。数据是隔离库里现写的几条收藏句（书 + 视频，其中一条已制卡）。
//
// 跑法（在 fushi/ 下，离屏、不抢焦点）：
//   dart tool/heavy.dart -- powershell -ExecutionPolicy Bypass -File \
//     tool/run_windows_itest.ps1 integration_test/home_favorites_widget_looks_itest.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart'
    show statTodayKey;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[fav-looks]';

void _log(String message) => debugPrint('$_tag $message');

Future<void> _seed(AppModel appModel) async {
  final FushiDatabase db = appModel.database;
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: 'fav-video-frieren',
      title: '葬送のフリーレン 第7話',
      videoPath: 'C:/fixtures/frieren-07.mp4',
      language: const Value<String>('ja'),
    ),
  );
  final FavoriteSentenceRepository repo = FavoriteSentenceRepository(db);
  final DateTime now = DateTime.now();
  final String today = statTodayKey();
  final List<
    ({
      String text,
      String? word,
      String title,
      String key,
      String source,
      int minutes,
    })
  >
  rows =
      <
        ({
          String text,
          String? word,
          String title,
          String key,
          String source,
          int minutes,
        })
      >[
        (
          text: 'もう二度と会えないなんて、信じたくなかった。',
          word: '信じる',
          title: '葬送のフリーレン 第7話',
          key: 'fav-video-frieren',
          source: kFavoriteSentenceSourceVideo,
          minutes: 5,
        ),
        (
          text: '雨の匂いがすると、あの日を思い出す。',
          word: '匂い',
          title: '海辺のカフカ',
          key: 'hoshi://book/fav-kafka',
          source: kFavoriteSentenceSourceBook,
          minutes: 60,
        ),
        (
          text: '僕たちは、ずっと前から知り合いだったような気がした。',
          word: null,
          title: '海辺のカフカ',
          key: 'hoshi://book/fav-kafka',
          source: kFavoriteSentenceSourceBook,
          minutes: 180,
        ),
        (
          text: '魔法は、自由に使えばいいんだよ。',
          word: '自由',
          title: '葬送のフリーレン 第7話',
          key: 'fav-video-frieren',
          source: kFavoriteSentenceSourceVideo,
          minutes: 60 * 26,
        ),
        (
          text: '人は思い出の中で生きていくものです。',
          word: '思い出',
          title: '海辺のカフカ',
          key: 'hoshi://book/fav-kafka',
          source: kFavoriteSentenceSourceBook,
          minutes: 60 * 50,
        ),
      ];
  for (int i = 0; i < rows.length; i++) {
    final DateTime at = now.subtract(Duration(minutes: rows[i].minutes));
    await repo.add(
      FavoriteSentence(
        text: rows[i].text,
        bookTitle: rows[i].title,
        createdAt: at,
        bookKey: rows[i].key,
        sectionIndex: 0,
        normCharOffset: rows[i].source == kFavoriteSentenceSourceVideo
            ? 120000 + i * 4000
            : 40 * i,
        normCharLength: rows[i].source == kFavoriteSentenceSourceVideo
            ? 2500
            : rows[i].text.length,
        chapterLabel: rows[i].source == kFavoriteSentenceSourceBook
            ? '第3章'
            : null,
        source: rows[i].source,
        dateKey: rows[i].minutes < 60 * 12
            ? today
            : FushiDatabase.statDateKeyOf(at),
        expression: rows[i].word,
        reading: null,
      ),
    );
  }
  // 「魔法は…」已制过卡：不计入「制卡（N）」。
  await db.addMinedSentence(
    source: kFavoriteSentenceSourceVideo,
    dateKey: today,
    expression: '自由',
    sentence: '魔法は、自由に使えばいいんだよ。',
    bookKey: 'fav-video-frieren',
    positionMs: 132000,
    durationMs: 2500,
  );
}

HomeWidgetLayout _layout(HomeWidgetSize favorites) {
  final List<HomeWidgetItem> items = <HomeWidgetItem>[
    HomeWidgetItem(HomeWidgetKind.favorites, favorites),
    const HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(2, 1)),
    const HomeWidgetItem(HomeWidgetKind.week, HomeWidgetSize(2, 2)),
  ];
  return HomeWidgetLayout(compact: items, wide: items);
}

Future<void> _shot(WidgetTester tester, String name) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  try {
    final RenderView view = tester.binding.renderViews.first;
    // ignore: invalid_use_of_protected_member
    final OffsetLayer? layer = view.layer as OffsetLayer?;
    if (layer == null) return;
    final ui.Image image = await layer.toImage(view.paintBounds);
    try {
      final ByteData? png = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (png == null) return;
      final String path = '${observeScreenshotDir().path}/$name.png';
      await File(path).writeAsBytes(png.buffer.asUint8List(), flush: true);
      _log('shot $path');
    } finally {
      image.dispose();
    }
  } catch (e) {
    _log('shot $name failed: $e');
  }
}

List<String> _texts(Finder root) {
  final List<String> out = <String>[];
  for (final Element e
      in find
          .descendant(of: root, matching: find.byType(RichText))
          .evaluate()) {
    final String s = (e.widget as RichText).text.toPlainText().trim();
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }
  return out;
}

Future<void> _settle(WidgetTester tester, [int frames = 10]) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('首页「收藏句子」小组件：各尺寸 × 两套设计', (WidgetTester tester) async {
    final List<String> errors = <String>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details.exceptionAsString());
      _log('FlutterError: ${details.exceptionAsString()}');
    };
    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await readyAppModel(tester);
      await _seed(appModel);

      const List<HomeWidgetSize> sizes = <HomeWidgetSize>[
        HomeWidgetSize(1, 1),
        HomeWidgetSize(2, 1),
        HomeWidgetSize(2, 2),
        HomeWidgetSize(4, 2),
        HomeWidgetSize(6, 3),
      ];
      final Finder card = find.byKey(
        const ValueKey<String>('home-favorites-panel'),
      );
      for (final (String look, String design) in <(String, String)>[
        ('material', 'material'),
        ('apple', 'glass'),
      ]) {
        await appModel.themeNotifier.setDesignSystem(design);
        await appModel.setGlassMaterial(FushiGlassMaterial.off);
        for (final (String shell, ShellContentLayout layout)
            in <(String, ShellContentLayout)>[
              ('card', ShellContentLayout.grid),
              ('poster', ShellContentLayout.collage),
            ]) {
          await appModel.setShellContentLayout(layout);
          for (final HomeWidgetSize size in sizes) {
            await appModel.setHomeWidgetLayout(_layout(size));
            HomePage.debugSelectTab?.call(HomeTab.home);
            await _settle(tester, 20);
            final String name = '$look-$shell-${size.cols}x${size.rows}';
            await _shot(tester, name);
            _log(
              '$name present=${card.evaluate().isNotEmpty} '
              'texts=${_texts(card)}',
            );
          }
        }
        // 点标题区：进收藏夹，停在「句子」页签。
        await appModel.setShellContentLayout(ShellContentLayout.grid);
        await appModel.setHomeWidgetLayout(_layout(const HomeWidgetSize(4, 2)));
        HomePage.debugSelectTab?.call(HomeTab.home);
        await _settle(tester, 20);
        final Finder open = find.byKey(
          const ValueKey<String>('home-favorites-panel-open'),
        );
        if (open.evaluate().isNotEmpty) {
          (tester.widget(open.first) as dynamic).onTap?.call();
          await _settle(tester, 20);
          await _shot(tester, '$look-collections-sentence-tab');
          appModel.navigatorKey.currentState?.pop();
          await _settle(tester, 10);
        } else {
          _log('$look: header tap target missing');
        }
      }

      await appModel.themeNotifier.setDesignSystem('auto');
      _log('errors: ${errors.length}');
      for (final String e in errors.take(10)) {
        _log('error: $e');
      }
      expect(errors, isEmpty);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
