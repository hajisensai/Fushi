import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';

/// TODO-1285 真机验证：分页阅读器「翻页时看到上/下页内容」（相邻页/列泄露到页边距带）。
///
/// 这个 itest 在**真实 Windows WebView2 引擎**（= Chromium/Blink，与安卓 WebView 同族）里
/// 注入 `ReaderContentStyles.css` 生成的**真实分页 CSS**，填入可识别颜色的多列内容，滚到
/// 一个非对齐（跨页）位置，然后用 `takeScreenshot()`（CDP `Page.captureScreenshot`，捕获
/// 引擎真实绘制、含 clip-path 与 html::before 覆盖条）取真像素，量页边距带里的颜色：
///   - 泄露 = 页边距带出现相邻列的内容色（红）。
///   - 干净 = 页边距带只有页背景色。
///
/// 三个变体证明修复是承重的、且引擎无关：
///   1. develop 全量修复（clip-path + html::before 覆盖条）→ 期望页边距带干净。
///   2. no-fix 对照（去掉 clip-path + 去掉 html::before）→ 期望泄露（证明探针有牙齿、
///      且证明修复正是遮住泄露的那层）。
///   3. overlay-only（clip-path:none 但保留 html::before）→ 期望干净（证明覆盖条这层
///      引擎无关的兜底单独就能遮住泄露，即使目标 WebView 的 clip-path 失效也不漏）。
///
/// 横排/竖排 × 单列/多列 共 4 种布局，各跑 3 变体。截图落盘 `<evidenceDir>` 供人工复核。
///
/// Run (PowerShell, from repo root)：
///   .\fushi\tool\run_windows_itest.ps1 integration_test\reader_page_edge_leak_verify_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 证据落盘目录：优先环境变量（runner 会给隔离 run 目录），否则用固定临时目录。
  final String evidenceDir = () {
    final String? env = Platform.environment['FUSHI_LEAK_EVIDENCE_DIR'];
    final String base = (env != null && env.trim().isNotEmpty)
        ? env.trim()
        : '${Directory.systemTemp.path}/hibiki-leak-evidence';
    final Directory d = Directory(base);
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }();

  const String contentHex = '#dc1414'; // 内容色（红），与任何常见页背景都远。
  const List<int> contentRgb = <int>[0xdc, 0x14, 0x14];

  // 每个变体对页边距带的期望：true=应泄露(内容色)、false=应干净(背景色)。
  const Map<String, bool> variantExpectLeak = <String, bool>{
    'full-fix': false,
    'no-fix-control': true,
    'overlay-only': false,
  };

  testWidgets(
      'paginated reader does NOT leak adjacent-page content into the page-edge '
      'padding band on real WebView2 (H/V x 1col/2col x fix variants)',
      (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    // 固定成分页模式；给宽页边距带（8vh/8vw）方便采样；已知字号。
    await settings.setViewMode('paginated');
    await settings.setFontSize(22);
    await settings.setMarginTop(8);
    await settings.setMarginBottom(8);
    await settings.setMarginLeft(8);
    await settings.setMarginRight(8);

    final Completer<InAppWebViewController> ready =
        Completer<InAppWebViewController>();

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: InAppWebView(
          initialData: InAppWebViewInitialData(
            data: '<!DOCTYPE html><html><head><meta charset="utf-8">'
                '</head><body></body></html>',
          ),
          onLoadStop: (InAppWebViewController controller, WebUri? url) async {
            if (!ready.isCompleted) ready.complete(controller);
          },
        ),
      ),
    ));

    for (int i = 0; i < 200 && !ready.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ready.isCompleted, isTrue,
        reason: 'WebView did not load within 20s');
    final InAppWebViewController controller = await ready.future;
    await tester.pump(const Duration(seconds: 1));

    // ---- helpers -------------------------------------------------------

    Future<Map<String, dynamic>> jsMap(String source) async {
      final Object? v = await controller.evaluateJavascript(source: source);
      if (v is Map) return v.cast<String, dynamic>();
      if (v is String && v.isNotEmpty) {
        return (jsonDecode(v) as Map).cast<String, dynamic>();
      }
      return <String, dynamic>{};
    }

    // 注入内容色的多列内容（用 createElement/textContent 构建 DOM，不用 innerHTML）。
    // 一次即可，切变体只换样式与滚动。
    Future<void> installContent() async {
      await controller.evaluateJavascript(source: '''
        (function(){
          var cs = document.getElementById('leak-content-style');
          if(!cs){cs=document.createElement('style');cs.id='leak-content-style';
            document.head.appendChild(cs);}
          cs.textContent = 'p.leakp{background:$contentHex !important;'
            + 'color:$contentHex !important;margin:0 !important;'
            + 'padding:0 !important;line-height:1.4 !important;'
            + 'break-inside:avoid !important;}';
          var body=document.body;
          while(body.firstChild){body.removeChild(body.firstChild);}
          var text='あいうえおかきくけこABCDEFGHIJ0123456789';
          for(var i=0;i<600;i++){
            var p=document.createElement('p');
            p.className='leakp';
            p.textContent=text;
            body.appendChild(p);
          }
        })();
      ''');
    }

    // 应用一份 CSS（放到 reader 样式槽），设 reader 的 CSS 变量，滚到跨页位置。
    Future<Map<String, dynamic>> applyCssAndScroll(
        String css, bool vertical) async {
      await controller.evaluateJavascript(source: '''
        (function(){
          var s=document.getElementById('fushi-reader-style');
          if(!s){s=document.createElement('style');s.id='fushi-reader-style';
            document.head.appendChild(s);}
          s.textContent = ${jsonEncode(css)};
          var de=document.documentElement.style;
          de.setProperty('--page-width', window.innerWidth+'px');
          de.setProperty('--page-height', window.innerHeight+'px');
          de.setProperty('--reader-viewport-height', window.innerHeight+'px');
          de.setProperty('--chrome-top-inset','36px');
          de.setProperty('--chrome-bottom-inset','48px');
        })();
      ''');
      // 让布局落定。
      await tester.pump(const Duration(milliseconds: 250));
      // 滚到非对齐(跨页)位置：maxScroll*0.37，保证两侧页边距带都压到相邻列。
      return jsMap('''
        (function(){
          var b=document.body;
          var vertical=$vertical;
          var total=vertical?b.scrollHeight:b.scrollWidth;
          var client=vertical?b.clientHeight:b.clientWidth;
          var maxScroll=Math.max(0,total-client);
          var pos=Math.round(maxScroll*0.37);
          if(vertical){b.scrollTop=pos;}else{b.scrollLeft=pos;}
          document.documentElement.scrollTop=0;
          document.documentElement.scrollLeft=0;
          var g=getComputedStyle(b);
          return {
            innerW: window.innerWidth, innerH: window.innerHeight,
            maxScroll: maxScroll,
            scrolled: vertical? b.scrollTop : b.scrollLeft,
            bg: g.backgroundColor,
            padTop: parseFloat(g.paddingTop)||0,
            padBottom: parseFloat(g.paddingBottom)||0,
            padLeft: parseFloat(g.paddingLeft)||0,
            padRight: parseFloat(g.paddingRight)||0,
            colCount: g.columnCount,
          };
        })();
      ''');
    }

    List<int> parseRgb(String s) {
      final RegExp re = RegExp(r'(\d+)\s*,\s*(\d+)\s*,\s*(\d+)');
      final Match? m = re.firstMatch(s);
      if (m == null) return <int>[255, 255, 255];
      return <int>[
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
      ];
    }

    double dist2(List<int> a, List<int> b) {
      final double dr = (a[0] - b[0]).toDouble();
      final double dg = (a[1] - b[1]).toDouble();
      final double dbl = (a[2] - b[2]).toDouble();
      return dr * dr + dg * dg + dbl * dbl;
    }

    // 取一条采样线上「像内容色」的像素比例（相对背景色的最近邻判定）。
    // samplesCss: list of [xCss, yCss].
    Future<double> classifyBand({
      required Uint8List png,
      required double scale,
      required List<int> bgRgb,
      required List<List<double>> samplesCss,
    }) async {
      final ui.Codec codec = await ui.instantiateImageCodec(png);
      final ui.FrameInfo fi = await codec.getNextFrame();
      final ui.Image img = fi.image;
      final ByteData? bd =
          await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) {
        img.dispose();
        return -1;
      }
      final int w = img.width;
      final int h = img.height;
      int contentCount = 0;
      int valid = 0;
      for (final List<double> s in samplesCss) {
        final int px = (s[0] * scale).round().clamp(0, w - 1);
        final int py = (s[1] * scale).round().clamp(0, h - 1);
        final int off = (py * w + px) * 4;
        final int r = bd.getUint8(off);
        final int g = bd.getUint8(off + 1);
        final int b = bd.getUint8(off + 2);
        final List<int> p = <int>[r, g, b];
        valid++;
        if (dist2(p, contentRgb) < dist2(p, bgRgb)) contentCount++;
      }
      img.dispose();
      return valid == 0 ? -1 : contentCount / valid;
    }

    await installContent();

    final StringBuffer report = StringBuffer();
    final List<String> failures = <String>[];

    // 4 布局 x 3 变体。
    final List<Map<String, dynamic>> layouts = <Map<String, dynamic>>[
      <String, dynamic>{'name': 'H1', 'wm': 'horizontal-tb', 'cols': 1},
      <String, dynamic>{'name': 'H2', 'wm': 'horizontal-tb', 'cols': 2},
      <String, dynamic>{'name': 'V1', 'wm': 'vertical-rl', 'cols': 1},
      <String, dynamic>{'name': 'V2', 'wm': 'vertical-rl', 'cols': 2},
    ];

    for (final Map<String, dynamic> layout in layouts) {
      final String wm = layout['wm'] as String;
      final int cols = layout['cols'] as int;
      final bool vertical = wm.startsWith('vertical');
      await settings.setWritingMode(wm);
      await settings.setPageColumns(cols);

      final String fullCss = ReaderContentStyles.css(settings: settings);

      // no-fix 对照：去掉 body 的 clip-path（→none）并整块删掉 html::before 覆盖条。
      String stripOverlay(String css) {
        final int idx = css.indexOf('html::before {');
        if (idx < 0) return css;
        final int close = css.indexOf('}', idx);
        if (close < 0) return css;
        return css.substring(0, idx) + css.substring(close + 1);
      }

      final String noFixCss = stripOverlay(fullCss).replaceAll(
          RegExp(r'clip-path:[^;]*!important;'), 'clip-path: none !important;');
      final String overlayOnlyCss = fullCss.replaceAll(
          RegExp(r'clip-path:[^;]*!important;'), 'clip-path: none !important;');

      final Map<String, String> variants = <String, String>{
        'full-fix': fullCss,
        'no-fix-control': noFixCss,
        'overlay-only': overlayOnlyCss,
      };

      for (final MapEntry<String, String> ve in variants.entries) {
        final String variant = ve.key;
        final Map<String, dynamic> geo =
            await applyCssAndScroll(ve.value, vertical);
        await tester.pump(const Duration(milliseconds: 250));

        final double innerW = (geo['innerW'] as num?)?.toDouble() ?? 0;
        final double innerH = (geo['innerH'] as num?)?.toDouble() ?? 0;
        final List<int> bgRgb = parseRgb((geo['bg'] as String?) ?? '');
        final double padTop = (geo['padTop'] as num?)?.toDouble() ?? 0;
        final double padBottom = (geo['padBottom'] as num?)?.toDouble() ?? 0;
        final double padLeft = (geo['padLeft'] as num?)?.toDouble() ?? 0;
        final double padRight = (geo['padRight'] as num?)?.toDouble() ?? 0;

        expect(innerW, greaterThan(300),
            reason: 'viewport too small to sample ($geo)');
        expect(innerH, greaterThan(300),
            reason: 'viewport too small to sample ($geo)');

        final Uint8List? png = await controller.takeScreenshot();
        expect(png, isNotNull,
            reason:
                'takeScreenshot returned null for $variant ${layout['name']}');
        // 落盘证据。
        final String shotPath = '$evidenceDir/${layout['name']}-$variant.png';
        File(shotPath).writeAsBytesSync(png!);

        // 由截图实际尺寸推 CSS->像素缩放。
        final ui.Codec codec = await ui.instantiateImageCodec(png);
        final ui.FrameInfo fi = await codec.getNextFrame();
        final double scale = fi.image.width / innerW;
        fi.image.dispose();

        // 内容采样（视口中心）——应为内容色，证明内容渲染出来了。
        final double centerFrac = await classifyBand(
          png: png,
          scale: scale,
          bgRgb: bgRgb,
          samplesCss: <List<double>>[
            <double>[innerW / 2, innerH / 2],
            <double>[innerW / 2 - 20, innerH / 2],
            <double>[innerW / 2 + 20, innerH / 2],
          ],
        );

        // 页边距带采样。横排看左右带、竖排看上下带（= 滚动轴两侧）。
        // 采样点取带的**外侧**中段（离视口边缘约 45% padding，避开正文内容盒边缘的
        // 抗锯齿、也避开列间 gap）。
        List<List<double>> bandSamples(bool leadingEdge) {
          final List<List<double>> out = <List<double>>[];
          if (!vertical) {
            final double pad = leadingEdge ? padLeft : padRight;
            for (int k = 0; k < 9; k++) {
              final double y = innerH * (0.15 + 0.7 * k / 8);
              final double x = leadingEdge ? pad * 0.45 : innerW - pad * 0.45;
              out.add(<double>[x, y]);
            }
          } else {
            final double pad = leadingEdge ? padTop : padBottom;
            for (int k = 0; k < 9; k++) {
              final double x = innerW * (0.15 + 0.7 * k / 8);
              final double y = leadingEdge ? pad * 0.45 : innerH - pad * 0.45;
              out.add(<double>[x, y]);
            }
          }
          return out;
        }

        final double aFrac = await classifyBand(
            png: png,
            scale: scale,
            bgRgb: bgRgb,
            samplesCss: bandSamples(true));
        final double bFrac = await classifyBand(
            png: png,
            scale: scale,
            bgRgb: bgRgb,
            samplesCss: bandSamples(false));

        final double bandMax = aFrac > bFrac ? aFrac : bFrac;
        final bool expectLeak = variantExpectLeak[variant]!;

        report.writeln('[${layout['name']} $variant] '
            'bg=$bgRgb centerContentFrac=${centerFrac.toStringAsFixed(2)} '
            'band${vertical ? '(top/bottom)' : '(left/right)'}='
            '${aFrac.toStringAsFixed(2)}/${bFrac.toStringAsFixed(2)} '
            'expectLeak=$expectLeak scrolled=${geo['scrolled']} '
            'cols=${geo['colCount']} shot=$shotPath');

        // 内容必须渲染出来（否则采样无意义）。
        if (centerFrac < 0.5) {
          failures.add('${layout['name']} $variant: content not rendered '
              '(centerContentFrac=$centerFrac) — sampling invalid');
          continue;
        }

        if (expectLeak) {
          // 对照/兜底 sanity：无修复时页边距带必须能看到内容色（>=40%），
          // 否则说明探针根本量不到泄露（假绿）。
          if (bandMax < 0.40) {
            failures.add(
                '${layout['name']} $variant: expected to DETECT a leak '
                'but bands look clean (max=$bandMax). Probe cannot see leaks — '
                'test would be a false-negative.');
          }
        } else {
          // 关键断言：真实修复下页边距带不得出现相邻页内容色（<=10%）。
          if (bandMax > 0.10) {
            failures.add('${layout['name']} $variant: ADJACENT-PAGE CONTENT '
                'LEAKS into padding band (contentFrac max=$bandMax > 0.10). '
                'shot=$shotPath');
          }
        }
      }
    }

    debugPrint('\n===== TODO-1285 page-edge leak report =====\n$report');
    debugPrint('Evidence screenshots in: $evidenceDir');

    if (failures.isNotEmpty) {
      fail('TODO-1285 leak verification FAILED:\n - ${failures.join('\n - ')}\n'
          '\nFull report:\n$report');
    }
  });
}
