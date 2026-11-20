/// 漫画「画质缩放」真机 E2E（`docs/specs/2026-11-20-manga-upscale-design.md` ① 默认档）：
/// 真实低清卷（带 OCR）开书，量当前页的页图 URL / 实际像素宽，抓 WebView 真像素，再在
/// 一个 OCR 块的首字上模拟点击，命中的必须是那个字（换了缩放后的图，OCR 仍在原图坐标系）。
/// 放大到 250% 后再抓一张、再点一次（画质档预放大低清源的路径）。
/// 画质档默认带文字感知 Gamma 校正（OCR 框外线性光、框内 sRGB），URL 带 `fq=g&tb=<框签名>`。
///
/// 需要本机私有素材（版权页图不入库）：
///
///   --dart-define=MANGA_VOLUME_SEED=<卷目录：manga.json（含 OCR 块）+ 页图>
///   --dart-define=MANGA_ENHANCED=1|0（画质缩放开 / 关；同一卷各跑一次对比）
///   --dart-define=MANGA_PROBE_PAGE=<页号>（默认 40）
///
/// 缺素材时跳过（CI 没有这些私有文件）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi_audio/fushi_audio.dart' show ReaderPositionRepository;
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _volumeSeed = String.fromEnvironment('MANGA_VOLUME_SEED');
const bool _enhanced =
    String.fromEnvironment('MANGA_ENHANCED', defaultValue: '1') == '1';
const int _probePage = int.fromEnvironment(
  'MANGA_PROBE_PAGE',
  defaultValue: 40,
);

/// 卷目录里的页图和 manga.json 复制进临时目录（保留 mtime）。
void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final FileSystemEntity entity in from.listSync(followLinks: false)) {
    final String target = p.join(to.path, p.basename(entity.path));
    if (entity is Directory) {
      if (p.basename(entity.path) == 'manga_ocr_out') continue;
      _copyTree(entity, Directory(target));
    } else if (entity is File) {
      entity.copySync(target);
      File(target).setLastModifiedSync(entity.lastModifiedSync());
    }
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final Stopwatch clock = Stopwatch()..start();
  while (clock.elapsed < total) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'enhanced scaling serves resampled page bytes; OCR taps still hit',
    (WidgetTester tester) async {
      if (_volumeSeed.isEmpty) {
        debugPrint('[enhanced-scaling] MANGA_VOLUME_SEED unset: skip');
        return;
      }
      const String tag = _enhanced ? 'on' : 'off';
      final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
      await launchFushiTestApp();
      final bool homeReady = await waitForHome(tester);
      FlutterError.onError = testErrorHandler;
      expect(homeReady, isTrue);
      final AppModel appModel = await readyAppModel(tester);

      final Directory bookDir = Directory.systemTemp.createTempSync(
        'manga_enhanced_scaling_',
      );
      _copyTree(Directory(_volumeSeed), bookDir);
      final Map<String, Object?> payload =
          (jsonDecode(
                    File(p.join(bookDir.path, 'manga.json')).readAsStringSync(),
                  )
                  as Map)
              .cast<String, Object?>();
      final List<Object?> pages = payload['pages']! as List<Object?>;
      final Map<String, Object?> probe = (pages[_probePage]! as Map)
          .cast<String, Object?>();
      final double pageWidth = (probe['width']! as num).toDouble();
      // 取本页第一个带行几何、首行至少 2 个字的块。
      final Map<String, Object?> block =
          <Map<String, Object?>>[
            for (final Object? b in probe['blocks']! as List<Object?>)
              (b! as Map).cast<String, Object?>(),
          ].firstWhere((Map<String, Object?> b) {
            final List<Object?> lines = b['lines']! as List<Object?>;
            return b['lines_coords'] != null &&
                lines.isNotEmpty &&
                (lines.first! as String).trim().characters.length >= 2;
          });
      final String firstLine =
          ((block['lines']! as List<Object?>).first! as String).trim();
      final List<List<double>> polygon = <List<double>>[
        for (final Object? point
            in (block['lines_coords']! as List<Object?>).first!
                as List<Object?>)
          <double>[
            for (final Object? v in point! as List<Object?>)
              (v! as num).toDouble(),
          ],
      ];
      double minOf(int axis) => polygon
          .map((List<double> q) => q[axis])
          .reduce((double a, double b) => a < b ? a : b);
      double maxOf(int axis) => polygon
          .map((List<double> q) => q[axis])
          .reduce((double a, double b) => a > b ? a : b);
      final bool vertical = block['vertical'] == true;
      final int count = firstLine.characters.length;
      // 首字字格中心（页图像素，原图坐标系）。
      final double px = vertical
          ? (minOf(0) + maxOf(0)) / 2
          : minOf(0) + (maxOf(0) - minOf(0)) / count / 2;
      final double py = vertical
          ? minOf(1) + (maxOf(1) - minOf(1)) / count / 2
          : (minOf(1) + maxOf(1)) / 2;
      debugPrint(
        '[enhanced-scaling] enhanced=$_enhanced page=$_probePage '
        'pageWidth=$pageWidth probe="$firstLine" at ($px, $py)',
      );

      final String key =
          'enhanced-scaling-${DateTime.now().microsecondsSinceEpoch}';
      await appModel.database.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: 'Enhanced scaling fixture',
          epubPath: 'manga.json',
          extractDir: bookDir.path,
          chapterCount: pages.length,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
          format: const Value<String>('manga'),
        ),
      );
      final EpubBookRow book = (await appModel.database.getEpubBook(key))!;
      await appModel.database
          .setMangaReaderOverride(book.uid, <String, Object?>{
            'mode': 'spread',
            'autoMode': false,
            'direction': 'rtl',
            'ocrTrigger': 'manual',
            'downloadAhead': false,
            'enhancedScaling': _enhanced,
          });
      await ReaderPositionRepository(
        appModel.database,
      ).save(bookUid: book.uid, sectionIndex: _probePage, normCharOffset: 0);

      final String spreadBefore = appModel.mangaSpreadPreference;
      final bool floatingBefore = appModel.mangaChromeFloating;
      final NavigatorState navigator = appModel.navigatorKey.currentState!;
      try {
        await appModel.setMangaSpreadPreference('single');
        await appModel.setMangaChromeFloating(true);
        final BuildContext context = navigator.context;
        if (!context.mounted) fail('navigator unmounted');
        unawaited(
          navigator.push(
            adaptivePageRoute<void>(
              context: context,
              builder: (BuildContext context) => FushiAppUiScaleNeutralizer(
                child: MangaFushiPage(item: null, bookKey: key),
              ),
            ),
          ),
        );
        final Finder content = find.byKey(
          const ValueKey<String>('manga_content_ready'),
        );
        for (int i = 0; i < 160 && content.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(content, findsOneWidget);
        final dynamic reader = tester.state(find.byType(MangaFushiPage));

        Future<Map<String, Object?>> dom() async {
          final Object? raw = await reader.debugEvaluateJavascript('''
(function(){
  var page = document.querySelector('.manga-page[data-page="$_probePage"]');
  if (!page) return JSON.stringify({error: 'page not in window'});
  var im = page.querySelector('img');
  var r = page.getBoundingClientRect();
  return JSON.stringify({src: (im.getAttribute('src') || '').split('/img/').pop(),
    complete: im.complete, naturalWidth: im.naturalWidth,
    cssWidth: r.width, dpr: window.devicePixelRatio});
})()
''');
          if (raw is! String) return <String, Object?>{'js': 'not-ready'};
          return (jsonDecode(raw) as Map).cast<String, Object?>();
        }

        Future<Map<String, Object?>> settled(
          bool Function(Map<String, Object?>) ok,
        ) async {
          Map<String, Object?> state = await dom();
          for (int i = 0; i < 80 && !ok(state); i++) {
            await _pumpFor(tester, const Duration(milliseconds: 250));
            state = await dom();
          }
          return state;
        }

        Future<String> tapProbe() async {
          final Object? raw = await reader.debugEvaluateJavascript('''
(function(){
  var page = document.querySelector('.manga-page[data-page="$_probePage"]');
  var r = page.getBoundingClientRect();
  var x = r.left + $px / Number(page.getAttribute('data-pw')) * r.width;
  var y = r.top + $py / Number(page.getAttribute('data-ph')) * r.height;
  var res = window.__mangaBarrierTapAt ? window.__mangaBarrierTapAt(x, y) : 'no-hook';
  return JSON.stringify({res: res, hit: window.__mangaLastOcrHit || null});
})()
''');
          debugPrint('[enhanced-scaling] tap: $raw');
          final Map<String, Object?> result =
              (jsonDecode(raw! as String) as Map).cast<String, Object?>();
          final Object? hit = result['hit'];
          return hit is Map ? (hit['text'] as String? ?? '') : '';
        }

        Future<void> shoot(String name) async {
          final Uint8List? png = await reader.debugCaptureWebView();
          expect(png, isNotNull, reason: 'WebView capture');
          final String path =
              '${observeScreenshotDir().path}/enhanced-scaling-$tag-$name.png';
          File(path).writeAsBytesSync(png!, flush: true);
          debugPrint('[enhanced-scaling] shot $path (${png.length} bytes)');
        }

        bool loaded(Map<String, Object?> s) =>
            s['complete'] == true && ((s['naturalWidth'] as num?) ?? 0) > 0;
        final Map<String, Object?> rest = await settled(loaded);
        await _pumpFor(tester, const Duration(seconds: 2));
        debugPrint('[enhanced-scaling] rest dom=${jsonEncode(rest)}');
        expect(loaded(rest), isTrue);
        final String src = rest['src']! as String;
        expect(src, contains('fit='));
        // 画质缩放默认带文字感知 Gamma 校正（fq=g）：URL 上挂本页 OCR 文字框签名，框数 > 0。
        expect(src.contains('fq=g'), _enhanced);
        if (_enhanced) {
          expect(src, matches(RegExp(r'[?&]tb=[1-9][0-9]*-[0-9a-f]+')));
        }
        await shoot('rest');
        expect(await tapProbe(), firstLine.characters.first);

        await reader.debugEvaluateJavascript('window.__mangaSetZoom(250);');
        final Map<String, Object?> zoomed = await settled(
          (Map<String, Object?> s) =>
              loaded(s) &&
              ((s['naturalWidth'] as num?) ?? 0) >
                  ((rest['naturalWidth'] as num?) ?? 0),
        );
        await _pumpFor(tester, const Duration(seconds: 2));
        debugPrint('[enhanced-scaling] zoomed dom=${jsonEncode(zoomed)}');
        if (_enhanced) {
          // 画质档：放大后预放大的图比原图宽（低清源），至多 2 倍。
          final num natural = (zoomed['naturalWidth'] as num?) ?? 0;
          expect(natural, greaterThan(pageWidth));
          expect(natural, lessThanOrEqualTo(pageWidth * 2));
        }
        await shoot('zoom250');
        expect(await tapProbe(), firstLine.characters.first);
        expect(
          (await captureFlutterFrame(tester, 'enhanced-scaling-$tag')).saved,
          isTrue,
        );
      } finally {
        navigator.popUntil((Route<dynamic> route) => route.isFirst);
        await tester.pump(const Duration(seconds: 1));
        await appModel.setMangaSpreadPreference(spreadBefore);
        await appModel.setMangaChromeFloating(floatingBefore);
        if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
