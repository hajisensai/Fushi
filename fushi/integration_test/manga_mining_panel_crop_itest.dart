/// 漫画制卡「裁到所在分镜」按**页面形状**判条漫，不按阅读模式判（真机 E2E）。
///
/// 在真 `MangaFushiPage` 里、四种阅读模式下各开一次书：在普通分镜页上点一个气泡
/// （走 WebView 里真实的 OCR 命中路径），再取「高级制卡」漫画图片分区的裁切预选，
/// 普通页必须拿到分镜；条漫长条页（高宽比 > 2）必须没有分镜（退整页 / 文本外扩）。
/// 修复前 webtoon / webtoonGaps 模式下普通页也拿不到分镜。
///
/// 需要本机私有素材（版权页图与模型都不入库）：
///
///   --dart-define=PANEL_CROP_SEED=<卷目录：manga.json + images/；第 0 页是普通分镜页，
///       第 1 页是高宽比 > 2 的长条；两页都要有 OCR 块>
///   --dart-define=PANEL_MODEL_SEED=<manga_panel_detector_yolo26n_fp32.onnx 路径>
///       （省略时取 PANEL_CROP_SEED 的上级目录里的 panel_model.onnx——Windows runner 经
///       `powershell -File` 只转发得了一个 -DartDefine）
///
/// 缺素材时跳过（CI 没有这些私有文件）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_panel_model_service.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _seedDir = String.fromEnvironment('PANEL_CROP_SEED');
const String _modelSeedDefine = String.fromEnvironment('PANEL_MODEL_SEED');
final String _modelSeed = _modelSeedDefine.isNotEmpty
    ? _modelSeedDefine
    : (_seedDir.isEmpty ? '' : p.join(p.dirname(_seedDir), 'panel_model.onnx'));

final List<String> _modes = <String>[
  for (final MangaReadingMode m in MangaReadingMode.values) m.storageKey,
];

Future<void> _copyDir(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final FileSystemEntity e in from.list(recursive: true)) {
    final String rel = p.relative(e.path, from: from.path);
    if (e is Directory) {
      await Directory(p.join(to.path, rel)).create(recursive: true);
    } else if (e is File) {
      await e.copy(p.join(to.path, rel));
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '分镜裁切预选：普通页四种模式都有分镜，长条页没有',
    (WidgetTester tester) async {
      final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
      await launchFushiTestApp();
      final bool homeReady = await waitForHome(tester);
      FlutterError.onError = testErrorHandler;
      expect(homeReady, isTrue);
      final AppModel appModel = await readyAppModel(tester);

      // 模型放进（隔离的）支持目录，阅读器的 detector 工厂按正常路径加载。
      final File model = await mangaPanelModelFile();
      await model.parent.create(recursive: true);
      await File(_modelSeed).copy(model.path);
      expect(
        (await mangaPanelModelStatus()).available,
        isTrue,
        reason: 'panel model must verify after seeding',
      );

      final Map<String, Object?> manga =
          (jsonDecode(
                    await File(
                      p.join(_seedDir, MangaStorage.kMangaJsonFileName),
                    ).readAsString(),
                  )
                  as Map)
              .cast<String, Object?>();
      final List<Map<String, Object?>> pages =
          (manga['pages']! as List<Object?>)
              .map((Object? e) => (e! as Map).cast<String, Object?>())
              .toList();

      /// 某页第一个块第一行首字中心（页图像素）。
      ({double x, double y}) firstGlyph(int page) {
        final Map<String, Object?> block =
            ((pages[page]['blocks']! as List<Object?>).first! as Map)
                .cast<String, Object?>();
        final List<Object?> quad =
            (block['lines_coords']! as List<Object?>).first! as List<Object?>;
        final List<List<double>> pts = quad
            .map(
              (Object? q) => (q! as List<Object?>)
                  .map((Object? v) => (v! as num).toDouble())
                  .toList(),
            )
            .toList();
        double minOf(int i) => pts
            .map((List<double> q) => q[i])
            .reduce((double a, double b) => a < b ? a : b);
        double maxOf(int i) => pts
            .map((List<double> q) => q[i])
            .reduce((double a, double b) => a > b ? a : b);
        final String line =
            ((block['lines']! as List<Object?>).first! as String).trim();
        final bool vertical = block['vertical'] == true;
        final int n = line.characters.length;
        return vertical
            ? (
                x: (minOf(0) + maxOf(0)) / 2,
                y: minOf(1) + (maxOf(1) - minOf(1)) / n / 2,
              )
            : (
                x: minOf(0) + (maxOf(0) - minOf(0)) / n / 2,
                y: (minOf(1) + maxOf(1)) / 2,
              );
      }

      final Map<String, Map<String, Object?>> results =
          <String, Map<String, Object?>>{};
      final NavigatorState navigator = appModel.navigatorKey.currentState!;

      for (final String mode in _modes) {
        final String bookKey =
            'panel-crop-$mode-${DateTime.now().microsecondsSinceEpoch}';
        final String bookDir = await MangaStorage.bookPath(bookKey);
        await _copyDir(Directory(_seedDir), Directory(bookDir));
        await appModel.database.insertEpubBook(
          EpubBooksCompanion.insert(
            bookKey: bookKey,
            title: 'Panel crop $mode',
            epubPath: MangaStorage.kMangaJsonFileName,
            extractDir: bookDir,
            chapterCount: 1,
            chaptersJson: '[]',
            importedAt: DateTime.now().millisecondsSinceEpoch,
            format: const Value<String>('manga'),
          ),
        );
        final EpubBookRow book = (await appModel.database.getEpubBook(
          bookKey,
        ))!;
        await appModel.database
            .setMangaReaderOverride(book.uid, <String, Object?>{
              'ocrTrigger': 'manual',
              'mode': mode,
              'autoMode': false,
              'automaticBackground': false,
              'downloadAhead': false,
            });

        try {
          final BuildContext navContext = navigator.context;
          if (!navContext.mounted) fail('navigator context unmounted');
          unawaited(
            navigator.push(
              adaptivePageRoute<void>(
                context: navContext,
                builder: (BuildContext context) => FushiAppUiScaleNeutralizer(
                  child: MangaFushiPage(item: null, bookKey: bookKey),
                ),
              ),
            ),
          );
          final Finder content = find.byKey(
            const ValueKey<String>('manga_content_ready'),
          );
          for (
            int attempt = 0;
            attempt < 80 &&
                (content.evaluate().isEmpty ||
                    find.byType(MangaFushiPage).evaluate().length != 1);
            attempt++
          ) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          expect(content, findsOneWidget, reason: '$mode: reader content');
          await tester.pump(const Duration(seconds: 3));
          final dynamic reader = tester.state(find.byType(MangaFushiPage));

          Future<Map<String, Object?>> tapAndSuggest(int page) async {
            final ({double x, double y}) g = firstGlyph(page);
            Map<String, Object?> tap = <String, Object?>{};
            for (int attempt = 0; attempt < 20; attempt++) {
              final Object? raw = await reader.debugEvaluateJavascript('''
(function(){
  var page = document.querySelector('.manga-page[data-page="$page"]');
  if (!page) return JSON.stringify({error: 'page not in window'});
  var r0 = page.getBoundingClientRect();
  var py = ${g.y} / Number(page.getAttribute('data-ph')) * r0.height;
  if (r0.top + py < 0 || r0.top + py > window.innerHeight) {
    window.scrollTo(0, window.scrollY + r0.top + py - window.innerHeight / 2);
  }
  var r = page.getBoundingClientRect();
  var x = r.left + ${g.x} / Number(page.getAttribute('data-pw')) * r.width;
  var y = r.top + ${g.y} / Number(page.getAttribute('data-ph')) * r.height;
  if (r.width < 50) return JSON.stringify({error: 'not laid out'});
  var res = window.__mangaBarrierTapAt ? window.__mangaBarrierTapAt(x, y) : 'no-hook';
  var se = document.scrollingElement || document.documentElement;
  return JSON.stringify({res: res, hit: window.__mangaLastOcrHit || null, x: x, y: y, scrollH: se.scrollHeight, viewH: window.innerHeight});
})()
''');
              tap = (jsonDecode(raw! as String) as Map).cast<String, Object?>();
              if (tap['res'] == 'hit' || tap['res'] == 'same') break;
              await tester.pump(const Duration(milliseconds: 500));
            }
            debugPrint('[panel-crop] $mode page=$page tap=${jsonEncode(tap)}');
            await tester.pump(const Duration(seconds: 2));

            final AdvancedMiningSections sections = await reader
                .buildAdvancedMiningSections(matched: 'x');
            final AdvancedMiningMangaImageSection? image = sections.mangaImage;
            if (image == null) {
              return <String, Object?>{'tap': tap['res'], 'section': false};
            }
            final MangaCropSuggestions? s = await image.loadSuggestions();
            return <String, Object?>{
              'tap': tap['res'],
              'section': true,
              'modelAvailable': image.panelModelAvailable,
              'suggestionPage': s?.pageIndex,
              'panels': s?.panels.length,
              'containingPanel': s?.containingPanel?.toString(),
            };
          }

          final Map<String, Object?> normal = await tapAndSuggest(0);
          expect(
            (await captureFlutterFrame(
              tester,
              'panel-crop-$mode-normal',
            )).saved,
            isTrue,
          );
          Map<String, Object?>? strip;
          if (MangaReadingModeSemantics.fromStorageKey(mode).isContinuous) {
            strip = await tapAndSuggest(1);
            expect(
              (await captureFlutterFrame(
                tester,
                'panel-crop-$mode-strip',
              )).saved,
              isTrue,
            );
          }
          results[mode] = <String, Object?>{'normal': normal, 'strip': strip};
          debugPrint('[panel-crop] $mode ${jsonEncode(results[mode])}');
        } finally {
          navigator.popUntil((Route<dynamic> route) => route.isFirst);
          for (
            int attempt = 0;
            attempt < 40 && find.byType(MangaFushiPage).evaluate().isNotEmpty;
            attempt++
          ) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          await tester.pump(const Duration(seconds: 1));
          final Directory dir = Directory(bookDir);
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        }
      }

      debugPrint('[panel-crop] RESULTS ${jsonEncode(results)}');
      for (final String mode in _modes) {
        final Map<String, Object?> normal = (results[mode]!['normal']! as Map)
            .cast<String, Object?>();
        expect(normal['tap'], anyOf('hit', 'same'), reason: '$mode tap');
        expect(normal['suggestionPage'], 0, reason: '$mode page');
        expect(
          normal['panels'] as int? ?? 0,
          greaterThan(0),
          reason: '$mode: normal paneled page must get panel suggestions',
        );
        expect(normal['containingPanel'], isNotNull, reason: mode);
        final Object? strip = results[mode]!['strip'];
        if (strip is Map) {
          expect(strip['tap'], anyOf('hit', 'same'), reason: '$mode strip tap');
          expect(strip['suggestionPage'], 1, reason: '$mode strip page');
          expect(
            strip['panels'],
            0,
            reason: '$mode: strip page must not get panel suggestions',
          );
        }
      }
    },
    skip: _seedDir.isEmpty || !File(_modelSeed).existsSync(),
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
