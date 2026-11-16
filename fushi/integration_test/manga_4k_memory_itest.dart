/// 超大页图（4K 级，3840×5400）漫画卷的真机内存走势（反馈 manga-fb-1115：导入 4K 图集后
/// 打开闪退、「反复撞缓存墙」）。
///
/// 在真 `MangaFushiPage` 里一页页按键（焦点驱动，方向键）翻完整卷，每一步读本进程
/// `/proc/self/status` 的 VmRSS / VmHWM 与 WebView 里「已取到字节的 <img>」数，日志打
/// `[mem4k]` 行；宿主同时可 `dumpsys meminfo` 对照。判据：整卷翻完后的 RSS 峰值比打开
/// 时的基线高出不超过 [_kMaxGrowthMb]——页图解码必须随翻页有界，而不是随「看过的页数」
/// 线性涨。
///
/// 页图不在测试里生成（4K JPEG 编码在设备上太慢），由宿主预先推到
/// `<外部 files 目录>/manga4k/*.jpg`：
///   python gen4k.py <dir> 40   # 3840×5400 灰度线稿 + 网点噪声，约 2.9 MB/页
///   adb push <dir>/. /sdcard/Android/data/<包名>/files/manga4k/
/// 目录缺失时测试直接跳过（这是宿主协同的取证测试，不进 CI 清单）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const int _kPageWidth = 3840;
const int _kPageHeight = 5400;

/// 整卷翻完后 RSS 相对打开基线允许的增量。Xiaomi Pad 5（1600×2560）实测：修复前
/// （原图直供 WebView）增长 516 MB、峰值 1230 MB；修复后增长 198 MB、峰值 822 MB。
const int _kMaxGrowthMb = 350;

({int rssMb, int hwmMb}) _procMemory() {
  int rss = -1;
  int hwm = -1;
  for (final String line in File('/proc/self/status').readAsLinesSync()) {
    final List<String> parts = line.split(RegExp(r'\s+'));
    if (line.startsWith('VmRSS:')) rss = int.parse(parts[1]) >> 10;
    if (line.startsWith('VmHWM:')) hwm = int.parse(parts[1]) >> 10;
  }
  return (rssMb: rss, hwmMb: hwm);
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final DateTime end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('4K 页图漫画卷翻完整卷内存有界', (WidgetTester tester) async {
    final Directory? ext = await getExternalStorageDirectory();
    final Directory source = Directory(p.join(ext?.path ?? '', 'manga4k'));
    final List<File> jpgs = source.existsSync()
        ? (source
              .listSync()
              .whereType<File>()
              .where((File f) => f.path.toLowerCase().endsWith('.jpg'))
              .toList()
            ..sort((File a, File b) => a.path.compareTo(b.path)))
        : <File>[];
    if (jpgs.isEmpty) {
      markTestSkipped('no 4K fixture pushed to ${source.path}');
      return;
    }

    final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
    await launchFushiTestApp();
    final bool homeReady = await waitForHome(tester);
    FlutterError.onError = testErrorHandler;
    expect(homeReady, isTrue);
    final AppModel appModel = await readyAppModel(tester);

    final String bookKey = 'manga-4k-${DateTime.now().microsecondsSinceEpoch}';
    final String bookDir = await MangaStorage.bookPath(bookKey);
    final Directory images = Directory(
      p.join(bookDir, MangaStorage.kImagesDirName),
    );
    await images.create(recursive: true);
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    for (final File jpg in jpgs) {
      final String name = p.basename(jpg.path);
      await jpg.copy(p.join(images.path, name));
      pages.add(<String, Object?>{
        'url': name,
        'width': _kPageWidth,
        'height': _kPageHeight,
        'blocks': <Object?>[],
      });
    }
    await File(
      p.join(bookDir, MangaStorage.kMangaJsonFileName),
    ).writeAsString(jsonEncode(<String, Object?>{'pages': pages}));
    await appModel.database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: '4K memory fixture',
        epubPath: MangaStorage.kMangaJsonFileName,
        extractDir: bookDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );
    final EpubBookRow book = (await appModel.database.getEpubBook(bookKey))!;
    // OCR 走手动：本测试只量页图渲染链路的内存，不让整卷识别混进来。
    await appModel.database.setMangaReaderOverride(book.uid, <String, Object?>{
      'ocrTrigger': 'manual',
      'direction': 'ltr',
      'mode': 'spread',
      'autoMode': false,
      'downloadAhead': false,
      'skipRead': false,
    });

    Future<Map<String, Object?>> domStats() async {
      final dynamic reader = tester.state(find.byType(MangaFushiPage));
      final Object? raw = await reader.debugEvaluateJavascript('''
        (function(){
          var imgs = Array.prototype.slice.call(document.querySelectorAll('.manga-page img'));
          var loaded = 0, withSrc = 0, fitted = 0;
          imgs.forEach(function(im){
            var src = im.getAttribute('src') || '';
            if (src) withSrc++;
            if (src.indexOf('fit=') >= 0) fitted++;
            if (im.complete && im.naturalWidth > 0) loaded++;
          });
          var hit = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
          var page = hit && hit.closest ? hit.closest('.manga-page') : null;
          var cur = page ? page.querySelector('img') : null;
          return JSON.stringify({imgs: imgs.length, withSrc: withSrc, loaded: loaded,
            fitted: fitted,
            page: page ? Number(page.getAttribute('data-page')) : null,
            naturalWidth: cur ? cur.naturalWidth : null,
            src: cur ? (cur.getAttribute('src') || '').split('/img/').pop() : null});
        })();
      ''');
      if (raw is! String) return <String, Object?>{'js': 'not-ready'};
      return (jsonDecode(raw) as Map).cast<String, Object?>();
    }

    final NavigatorState navigator = appModel.navigatorKey.currentState!;
    bool readerOpen = false;
    try {
      final BuildContext navContext = navigator.context;
      if (!navContext.mounted) fail('navigator context unmounted');
      final ({int rssMb, int hwmMb}) before = _procMemory();
      debugPrint(
        '[mem4k] before-open rss=${before.rssMb}MB hwm=${before.hwmMb}MB '
        'pages=${jpgs.length}',
      );
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
      readerOpen = true;
      final Finder content = find.byKey(
        const ValueKey<String>('manga_content_ready'),
      );
      for (int i = 0; i < 120 && content.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(content, findsOneWidget);
      await _pumpFor(tester, const Duration(seconds: 4));
      final ({int rssMb, int hwmMb}) opened = _procMemory();
      final Map<String, Object?> openedDom = await domStats();
      debugPrint(
        '[mem4k] opened rss=${opened.rssMb}MB hwm=${opened.hwmMb}MB '
        'dom=${jsonEncode(openedDom)}',
      );
      // 当前页取的是按显示尺寸降采样的图，不是 3840 宽的原图。
      expect(openedDom['src'], contains('fit='));
      expect((openedDom['naturalWidth'] as num?) ?? 0, greaterThan(0));
      expect((openedDom['naturalWidth'] as num?) ?? 0, lessThan(_kPageWidth));
      debugPrint('[mem4k] shot-rest');
      await _pumpFor(tester, const Duration(seconds: 4));

      int peak = opened.rssMb;
      for (int step = 1; step < jpgs.length; step++) {
        await tester.sendKeyEvent(
          LogicalKeyboardKey.arrowRight,
          platform: 'android',
          physicalKey: PhysicalKeyboardKey.arrowRight,
        );
        await _pumpFor(tester, const Duration(milliseconds: 1500));
        final ({int rssMb, int hwmMb}) m = _procMemory();
        if (m.rssMb > peak) peak = m.rssMb;
        debugPrint(
          '[mem4k] step=$step '
          'rss=${m.rssMb}MB hwm=${m.hwmMb}MB dom=${jsonEncode(await domStats())}',
        );
      }
      // 放大：屏上页换更高的取图档（清晰度不随降采样下降），邻页不跟着换。
      final dynamic reader = tester.state(find.byType(MangaFushiPage));
      final num restWidth = (await domStats())['naturalWidth'] as num? ?? 0;
      await reader.debugEvaluateJavascript('window.__mangaSetZoom(250);');
      Map<String, Object?> zoomed = await domStats();
      for (
        int i = 0;
        i < 40 && ((zoomed['naturalWidth'] as num?) ?? 0) <= restWidth;
        i++
      ) {
        await _pumpFor(tester, const Duration(milliseconds: 250));
        zoomed = await domStats();
      }
      debugPrint('[mem4k] zoomed dom=${jsonEncode(zoomed)}');
      expect(
        (zoomed['naturalWidth'] as num?) ?? 0,
        greaterThan(restWidth),
        reason: '放大后屏上页要换高一档的图',
      );
      debugPrint('[mem4k] shot-zoom');
      await _pumpFor(tester, const Duration(seconds: 4));
      await reader.debugEvaluateJavascript('window.__mangaSetZoom(100);');
      await _pumpFor(tester, const Duration(seconds: 3));
      final ({int rssMb, int hwmMb}) end = _procMemory();
      debugPrint(
        '[mem4k] done rss=${end.rssMb}MB hwm=${end.hwmMb}MB '
        'peakSampled=${peak}MB growth=${peak - opened.rssMb}MB',
      );
      expect(
        peak - opened.rssMb,
        lessThan(_kMaxGrowthMb),
        reason: '4K 卷翻完 RSS 增长 ${peak - opened.rssMb}MB',
      );
    } finally {
      if (readerOpen) {
        navigator.pop();
        await _pumpFor(tester, const Duration(seconds: 1));
      }
    }
  });
}
