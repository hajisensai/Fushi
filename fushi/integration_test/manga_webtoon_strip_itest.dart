/// 条漫（webtoon）真机几何与滑动（BUG-3749）：在真 `MangaFushiPage` 的 WebView 里
/// 读 DOM，钉住三件事——
///
/// 1. 「条漫」模式页与页之间没有间距，即使 `showPageGaps` 是默认的开（此前每页
///    之间一条 12px 背景色横带，切片韩漫满屏黑线）；
/// 2. 页高对齐物理像素、后一页向上压前一页一个物理像素（小数页高的抗锯齿缝）；
/// 3. 恒等颜色调整不下发 CSS 滤镜。
///
/// 另有两段**宿主协同**的取证窗口（不影响判绿）：日志打出 `[strip] seam <i>` 时
/// 页交界停在视口中部，宿主可 `adb exec-out screencap` 看像素；打出
/// `[strip] swipe-ready` 后 20 秒内宿主可 `adb shell input swipe` 注入滑动，测试
/// 结束前打出每次松手后的惯性距离与帧间隔。用法：
///   flutter build apk --debug --target=integration_test/manga_webtoon_strip_itest.dart
///   （临时 applicationIdSuffix 并行安装，别覆盖用户的包）→ am start → logcat -s flutter
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const int _pageWidth = 720;
// 刻意取一个让 `视口宽 × 比例` 落在小数像素上的高度。
const int _pageHeight = 2333;
const int _pageCount = 10;

/// 白底切片：左侧一条深色竖条（证明图真的画出来），其余全白——页交界处任何
/// 横贯整宽的暗线只可能是页缝。
Uint8List _whiteSlicePng(int seed) {
  final Uint8List raw = Uint8List(_pageHeight * (1 + _pageWidth * 3));
  int o = 0;
  for (int y = 0; y < _pageHeight; y++) {
    raw[o++] = 0;
    for (int x = 0; x < _pageWidth; x++) {
      final bool mark = x >= 40 && x < 80 && (y ~/ 97 + seed).isEven;
      final int v = mark ? 30 : 255;
      raw[o++] = v;
      raw[o++] = v;
      raw[o++] = v;
    }
  }
  final BytesBuilder out = BytesBuilder()
    ..add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final List<int> body = <int>[...ascii.encode(type), ...data];
    out
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(body)
      ..add((ByteData(4)..setUint32(0, _crc32(body))).buffer.asUint8List());
  }

  final ByteData ihdr = ByteData(13)
    ..setUint32(0, _pageWidth)
    ..setUint32(4, _pageHeight)
    ..setUint8(8, 8)
    ..setUint8(9, 2);
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', zlib.encode(raw));
  chunk('IEND', const <int>[]);
  return out.toBytes();
}

int _crc32(List<int> bytes) {
  int crc = 0xFFFFFFFF;
  for (final int b in bytes) {
    crc ^= b;
    for (int k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

void main() {
  // 宿主 `adb shell input swipe` 要真的进到 WebView：默认 binding 会吞掉设备触摸。
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
          .shouldPropagateDevicePointerEvents =
      true;

  testWidgets('条漫无缝拼接、页高对齐物理像素、无恒等滤镜', (WidgetTester tester) async {
    final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
    await launchFushiTestApp();
    final bool homeReady = await waitForHome(tester);
    FlutterError.onError = testErrorHandler;
    expect(homeReady, isTrue);
    final AppModel appModel = await readyAppModel(tester);

    final String bookKey =
        'webtoon-strip-${DateTime.now().microsecondsSinceEpoch}';
    final String bookDir = await MangaStorage.bookPath(bookKey);
    final Directory images = Directory(
      p.join(bookDir, MangaStorage.kImagesDirName),
    );
    await images.create(recursive: true);
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    for (int i = 0; i < _pageCount; i++) {
      final String name = 'p${i.toString().padLeft(3, '0')}.png';
      await File(p.join(images.path, name)).writeAsBytes(_whiteSlicePng(i));
      pages.add(<String, Object?>{
        // 本地卷形态（同 manga_chrome_shot_itest）：url 相对 images 目录。
        'url': name,
        'width': _pageWidth,
        'height': _pageHeight,
        'blocks': <Object?>[],
      });
    }
    await File(
      p.join(bookDir, MangaStorage.kMangaJsonFileName),
    ).writeAsString(jsonEncode(<String, Object?>{'pages': pages}));
    await appModel.database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Webtoon strip fixture',
        epubPath: MangaStorage.kMangaJsonFileName,
        extractDir: bookDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );
    final EpubBookRow book = (await appModel.database.getEpubBook(bookKey))!;
    // showPageGaps 显式给默认的 true：「条漫」模式下它不得再生出页缝。
    await appModel.database.setMangaReaderOverride(book.uid, <String, Object?>{
      'ocrTrigger': 'manual',
      'mode': 'webtoon',
      'autoMode': false,
      'showPageGaps': true,
      'automaticBackground': false,
      'downloadAhead': false,
    });

    Future<Map<String, Object?>> js(String body) async {
      final dynamic reader = tester.state(find.byType(MangaFushiPage));
      final Object? raw = await reader.debugEvaluateJavascript(
        '(function(){$body})();',
      );
      expect(raw, isA<String>());
      return (jsonDecode(raw! as String) as Map).cast<String, Object?>();
    }

    final NavigatorState navigator = appModel.navigatorKey.currentState!;
    bool readerOpen = false;
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
      readerOpen = true;
      final Finder content = find.byKey(
        const ValueKey<String>('manga_content_ready'),
      );
      for (
        int attempt = 0;
        attempt < 80 && content.evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(content, findsOneWidget);
      await tester.pump(const Duration(seconds: 2));

      const String geometryJs = '''
        var pages = Array.prototype.slice.call(document.querySelectorAll('.manga-page'));
        var dpr = window.devicePixelRatio || 1;
        var out = {dpr: dpr, count: pages.length, gaps: [], heights: [], joins: []};
        pages.forEach(function(page, i){
          var r = page.getBoundingClientRect();
          out.gaps.push(getComputedStyle(page).marginBottom);
          out.heights.push(r.height * dpr);
          if (i > 0) {
            var prev = pages[i - 1].getBoundingClientRect();
            out.joins.push((r.top - prev.bottom) * dpr);
          }
        });
        var img = document.querySelector('.manga-source img');
        out.filter = img ? getComputedStyle(img).filter : null;
        out.mode = document.querySelector('#manga-root') ? 'ok' : 'missing';
        return JSON.stringify(out);
      ''';
      // WebView 首次排版可能还是 0 宽（宿主 resize 之后才重排）：等页高落定再量。
      Map<String, Object?> geometry = await js(geometryJs);
      for (
        int attempt = 0;
        attempt < 40 &&
            ((geometry['heights']! as List<Object?>).isEmpty ||
                ((geometry['heights']! as List<Object?>).first! as num) < 100);
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
        geometry = await js(geometryJs);
      }
      debugPrint('[strip] geometry=${jsonEncode(geometry)}');
      // 断言放到取证窗口之后：改前构建（A/B 对照）也要把截图与滑动数据跑完。
      void expectSeamless() {
        expect(geometry['count'], _pageCount);
        expect((geometry['gaps']! as List<Object?>).toSet(), <Object?>{
          '0px',
        }, reason: '「条漫」模式不得有页间距（showPageGaps=true 也一样）');
        for (final Object? h in geometry['heights']! as List<Object?>) {
          final double device = (h! as num).toDouble();
          expect(
            (device - device.roundToDouble()).abs(),
            // Chromium 布局单位是 1/64 CSS 像素，小数 DPR 下取整误差最多约 0.02。
            lessThan(0.05),
            reason: '页高必须是整数物理像素，实际 $device',
          );
        }
        for (final Object? j in geometry['joins']! as List<Object?>) {
          expect(
            (j! as num).toDouble(),
            closeTo(-1, 0.05),
            reason: '后一页必须向上压前一页一个物理像素',
          );
        }
        expect(geometry['filter'], 'none');
      }

      // 宿主取证窗口 1：页交界停在视口中部，带小数滚动偏移。
      int shot = 0;
      for (final int boundary in <int>[1, 2]) {
        for (final double frac in <double>[0, 0.37, 0.71]) {
          await js('''
            var page = document.querySelectorAll('.manga-page')[$boundary];
            window.scrollTo(0, page.offsetTop - window.innerHeight / 2 + $frac);
            return JSON.stringify({y: window.scrollY});
          ''');
          await tester.pump(const Duration(milliseconds: 600));
          debugPrint('[strip] seam ${shot++} boundary=$boundary frac=$frac');
          await tester.pump(const Duration(seconds: 3));
        }
      }

      // 宿主取证窗口 2：滑动。每次松手后的滑行距离 + 帧间隔。
      await js('''
        window.scrollTo(0, 0);
        var st = window.__stripProbe = {fling: [], frames: [], upY: null, last: null,
          counts: {pointerdown: 0, pointerup: 0, pointercancel: 0, touchstart: 0, scroll: 0}};
        ['pointerdown', 'pointerup', 'pointercancel', 'touchstart'].forEach(function(type){
          document.addEventListener(type, function(){ st.counts[type]++; }, true);
        });
        window.addEventListener('scroll', function(){ st.counts.scroll++; }, {passive: true});
        document.addEventListener('pointerdown', function(){
          if (st.upY !== null) st.fling.push(Math.abs(window.scrollY - st.upY));
          st.upY = null;
        }, true);
        document.addEventListener('pointerup', function(){ st.upY = window.scrollY; }, true);
        (function tick(t){
          if (st.last !== null) st.frames.push(t - st.last);
          st.last = t;
          requestAnimationFrame(tick);
        })(performance.now());
        return JSON.stringify({ok: true});
      ''');
      debugPrint('[strip] swipe-ready');
      await tester.pump(const Duration(seconds: 20));
      final Map<String, Object?> swipes = await js('''
        var st = window.__stripProbe;
        if (st.upY !== null) st.fling.push(Math.abs(window.scrollY - st.upY));
        var f = st.frames.slice(5).sort(function(a, b){ return a - b; });
        var q = function(x){ return f.length ? f[Math.floor((f.length - 1) * x)] : 0; };
        return JSON.stringify({fling: st.fling, counts: st.counts,
          scrollY: window.scrollY, frames: f.length,
          p50: q(.5), p95: q(.95), p99: q(.99),
          over20: f.filter(function(v){ return v > 20; }).length});
      ''');
      debugPrint('[strip] swipes=${jsonEncode(swipes)}');
      expectSeamless();
    } finally {
      if (readerOpen) {
        navigator.pop();
        await tester.pump(const Duration(seconds: 1));
      }
      await appModel.database.deleteEpubBook(bookKey);
      try {
        await Directory(bookDir).delete(recursive: true);
      } on FileSystemException {
        // 阅读器刚关，文件句柄可能还没放：隔离数据根随测试丢弃。
      }
    }
  });
}
