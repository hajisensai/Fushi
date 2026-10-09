/// BUG-2813 真机 E2E：已用本地 ONNX（v4）识别过的真实漫画卷，开书后阅读器自动排
/// 一次本地整卷任务，**只补行几何、不重新识别**；完成后在真实 WebView 里对多列竖排
/// 气泡第二、三列的首字位置模拟点击，命中的必须是那一列的字。
///
/// 需要本机私有素材（版权页图与模型都不入库）：
///
///   --dart-define=OCR_MODEL_SEED=<本地 ONNX 模型目录（ocr_models/manga）>
///   --dart-define=MANGA_VOLUME_SEED=<卷目录副本：manga.json + images/ +
///       manga_ocr_out/_pages/local-onnx-v4-…>（页图 mtime 必须与原卷一致，
///       逐页缓存按大小 + mtime 校验）
///   --dart-define=MANGA_PROBE_TEXT=<某页上一个多列气泡的整块文本>（页号按这段
///       文本在种子卷里定位：卷里有没有封面页会让写死的页号差一）
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
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart' show ReaderPositionRepository;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart'
    show kMangaOcrPipelineRevision;
import 'package:fushi_engine/ocr/manga_ocr_model_fingerprint.dart'
    show defaultMangaOcrModelsDir;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _modelSeed = String.fromEnvironment('OCR_MODEL_SEED');
const String _volumeSeed = String.fromEnvironment('MANGA_VOLUME_SEED');
const String _probeText = String.fromEnvironment(
  'MANGA_PROBE_TEXT',
  defaultValue: '母の子守唄で眠ったことは一度もなかった',
);

/// 递归复制并保留文件修改时间（逐页缓存按 mtime 校验）。
void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final FileSystemEntity entity in from.listSync(followLinks: false)) {
    final String target = p.join(to.path, p.basename(entity.path));
    if (entity is Directory) {
      _copyTree(entity, Directory(target));
    } else if (entity is File) {
      entity.copySync(target);
      File(target).setLastModifiedSync(entity.lastModifiedSync());
    }
  }
}

Map<String, Object?> _readJson(File file) =>
    (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();

List<Map<String, Object?>> _pages(Map<String, Object?> payload) =>
    <Map<String, Object?>>[
      for (final Object? page in payload['pages']! as List<Object?>)
        (page! as Map).cast<String, Object?>(),
    ];

String _blockText(Map<String, Object?> block) =>
    (block['lines']! as List<Object?>).cast<String>().join();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'local v4 volume: reader re-lays out lines only, taps hit their column',
    (WidgetTester tester) async {
      if (_modelSeed.isEmpty || _volumeSeed.isEmpty) {
        debugPrint(
          '[tap-geometry] OCR_MODEL_SEED / MANGA_VOLUME_SEED unset: skip',
        );
        return;
      }
      final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
      await launchFushiTestApp();
      final bool homeReady = await waitForHome(tester);
      FlutterError.onError = testErrorHandler;
      expect(homeReady, isTrue);
      final AppModel appModel = await readyAppModel(tester);

      // 模型装进隔离数据根的默认模型目录（与生产同一个解析入口）。
      final Directory models = await defaultMangaOcrModelsDir();
      models.createSync(recursive: true);
      for (final FileSystemEntity entity in Directory(_modelSeed).listSync()) {
        if (entity is! File) continue;
        final File target = File(p.join(models.path, p.basename(entity.path)));
        if (!target.existsSync()) entity.copySync(target.path);
      }

      final Directory bookDir = Directory.systemTemp.createTempSync(
        'manga_tap_geometry_',
      );
      _copyTree(Directory(_volumeSeed), bookDir);
      final File mangaJson = File(p.join(bookDir.path, 'manga.json'));
      final Map<String, Object?> before = _readJson(mangaJson);
      final String beforeSignature =
          ((before['ocr']! as Map)['engine_signature']) as String;
      debugPrint('[tap-geometry] seed signature=$beforeSignature');
      expect(beforeSignature, startsWith('local-onnx-v4-'));
      final List<Map<String, Object?>> beforePages = _pages(before);
      final int probePage = beforePages.indexWhere(
        (Map<String, Object?> page) => (page['blocks']! as List<Object?>).any(
          (Object? block) =>
              _blockText((block! as Map).cast<String, Object?>()) == _probeText,
        ),
      );
      if (probePage < 0) fail('probe text not in the seed volume: $_probeText');
      debugPrint('[tap-geometry] probe page=$probePage');

      final String key =
          'tap-geometry-${DateTime.now().microsecondsSinceEpoch}';
      await appModel.database.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: 'Tap geometry fixture',
          epubPath: 'manga.json',
          extractDir: bookDir.path,
          chapterCount: beforePages.length,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
          format: const Value<String>('manga'),
        ),
      );
      final EpubBookRow book = await (appModel.database.select(
        appModel.database.epubBooks,
      )..where((table) => table.bookKey.equals(key))).getSingle();
      await appModel.database.setMangaReaderOverride(
        book.uid,
        <String, Object?>{
          'mode': 'spread',
          'autoMode': false,
          'direction': 'rtl',
          // 手动模式：已识别卷的行几何升级不看触发方式，这里顺带钉住这一点。
          'ocrTrigger': 'manual',
        },
      );
      await ReaderPositionRepository(
        appModel.database,
      ).save(bookUid: book.uid, sectionIndex: probePage, normCharOffset: 0);

      final String engineBefore = appModel.mangaOcrEnginePreference;
      final String spreadBefore = appModel.mangaSpreadPreference;
      final bool floatingBefore = appModel.mangaChromeFloating;
      final NavigatorState navigator = appModel.navigatorKey.currentState!;
      try {
        await appModel.setMangaOcrEnginePreference('local_onnx');
        await appModel.setMangaSpreadPreference('single');
        await appModel.setMangaChromeFloating(false);
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

        // 没有任何用户动作：开书即排本地任务，逐页只补几何，manga.json 换成 v5。
        final Stopwatch clock = Stopwatch()..start();
        Map<String, Object?>? after;
        for (int attempt = 0; attempt < 1200 && after == null; attempt++) {
          await tester.pump(const Duration(milliseconds: 500));
          final Map<String, Object?> current = _readJson(mangaJson);
          final String signature =
              ((current['ocr']! as Map)['engine_signature']) as String;
          if (signature.startsWith('local-onnx-$kMangaOcrPipelineRevision')) {
            after = current;
          }
        }
        expect(
          after,
          isNotNull,
          reason: 'relayout job must rewrite manga.json',
        );
        debugPrint(
          '[tap-geometry] relayout finished in ${clock.elapsed.inSeconds}s '
          'signature=${(after!['ocr']! as Map)['engine_signature']}',
        );

        // 文字一个都不许变（只补几何）；统计拿到行几何的块。
        final List<Map<String, Object?>> afterPages = _pages(after);
        expect(afterPages, hasLength(beforePages.length));
        int blocks = 0;
        int withGeometry = 0;
        for (int page = 0; page < afterPages.length; page++) {
          final List<Object?> a = afterPages[page]['blocks']! as List<Object?>;
          final List<Object?> b = beforePages[page]['blocks']! as List<Object?>;
          expect(
            <String>[
              for (final Object? block in a)
                _blockText((block! as Map).cast<String, Object?>()),
            ],
            <String>[
              for (final Object? block in b)
                _blockText((block! as Map).cast<String, Object?>()),
            ],
            reason: 'page $page text must be unchanged',
          );
          for (final Object? block in a) {
            blocks++;
            if ((block! as Map)['lines_coords'] != null) withGeometry++;
          }
        }
        debugPrint('[tap-geometry] blocks=$blocks withGeometry=$withGeometry');
        expect(withGeometry, greaterThan(blocks * 0.9));

        final Map<String, Object?> target =
            <Map<String, Object?>>[
              for (final Object? block
                  in afterPages[probePage]['blocks']! as List<Object?>)
                (block! as Map).cast<String, Object?>(),
            ].firstWhere(
              (Map<String, Object?> block) => _blockText(block) == _probeText,
            );
        final List<String> lines = (target['lines']! as List<Object?>)
            .cast<String>();
        final List<Object?> coords = target['lines_coords']! as List<Object?>;
        debugPrint('[tap-geometry] target lines=$lines');
        expect(lines.length, greaterThanOrEqualTo(2));
        expect(coords, hasLength(lines.length));

        // 等热替换把新几何挂进 WebView（完成后逐页 __mangaReplaceOcr）。
        await tester.pump(const Duration(seconds: 3));
        final dynamic reader = tester.state(find.byType(MangaFushiPage));
        final List<String> hits = <String>[];
        for (int line = 1; line < lines.length; line++) {
          final List<List<double>> polygon = <List<double>>[
            for (final Object? point in coords[line]! as List<Object?>)
              <double>[
                for (final Object? v in point! as List<Object?>)
                  (v! as num).toDouble(),
              ],
          ];
          final double left = polygon
              .map((List<double> q) => q[0])
              .reduce((double a, double b) => a < b ? a : b);
          final double right = polygon
              .map((List<double> q) => q[0])
              .reduce((double a, double b) => a > b ? a : b);
          final double top = polygon
              .map((List<double> q) => q[1])
              .reduce((double a, double b) => a < b ? a : b);
          final double bottom = polygon
              .map((List<double> q) => q[1])
              .reduce((double a, double b) => a > b ? a : b);
          final int count = lines[line].trim().characters.length;
          // 这一列第一个字格的中心（页图像素）。
          final double px = (left + right) / 2;
          final double py = top + (bottom - top) / count / 2;
          final Object? raw = await reader.debugEvaluateJavascript('''
(function(){
  var page = document.querySelector('.manga-page[data-page="$probePage"]');
  if (!page) return JSON.stringify({error: 'page not in window'});
  var r = page.getBoundingClientRect();
  var x = r.left + $px / Number(page.getAttribute('data-pw')) * r.width;
  var y = r.top + $py / Number(page.getAttribute('data-ph')) * r.height;
  var res = window.__mangaBarrierTapAt ? window.__mangaBarrierTapAt(x, y) : 'no-hook';
  return JSON.stringify({res: res, hit: window.__mangaLastOcrHit || null, x: x, y: y});
})()
''');
          debugPrint('[tap-geometry] line $line probe: $raw');
          final Map<String, Object?> result =
              (jsonDecode(raw! as String) as Map).cast<String, Object?>();
          expect(result['res'], anyOf('hit', 'same'));
          final String hit = ((result['hit']! as Map)['text']) as String? ?? '';
          hits.add(hit);
          expect(
            hit,
            lines[line].trim().characters.first,
            reason: 'tap on column ${line + 1} must hit its first character',
          );
        }
        debugPrint('[tap-geometry] hits=$hits');
        expect(
          (await captureFlutterFrame(tester, 'manga-tap-geometry-done')).saved,
          isTrue,
        );
      } finally {
        navigator.popUntil((Route<dynamic> route) => route.isFirst);
        await tester.pump(const Duration(seconds: 1));
        await appModel.setMangaOcrEnginePreference(engineBefore);
        await appModel.setMangaSpreadPreference(spreadBefore);
        await appModel.setMangaChromeFloating(floatingBefore);
        if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
