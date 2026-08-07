// PDF 阅读器 Phase 0 spike 验证（只打通渲染 + 文本层，不接书架/查词/进度/制卡）。
//
// 目标：
//   1. 证明 pdfrx（PDFium）能把一份真实 PDF 栅格化成页面位图（离屏落盘取证）。
//   2. 证明文本层可用：loadStructuredText() 拿到 fullText + 字符级 charRects，
//      这是后续「点选查词」的地基（每个字符一个矩形，可按点命中）。
//   3. 证明 PdfViewer 组件能在真 widget 树里挂载并触发 onViewerReady（组件路径可用）。
//
// 运行（Windows 离屏）：
//   cd hibiki
//   .\tool\run_windows_itest.ps1 integration_test\pdf_spike_render_text_itest.dart
// 或裸跑（需要一个已连接设备/桌面）：
//   flutter test integration_test\pdf_spike_render_text_itest.dart -d windows \
//     --dart-define=PDF_SPIKE_PATH=C:\Users\wrds\Downloads\QQ\prince.pdf
//
// PDF 路径来源：--dart-define=PDF_SPIKE_PATH，缺省回落到本机 spike 素材路径；
// 文件不存在时跳过（不硬失败），以免在没有该素材的机器上误红。
//
// 取证抓图故意走 PdfPage.render()（PDFium 直接栅格化成 BGRA 位图 → 落 PNG），
// 不走 PdfViewer 组件的 OffsetLayer.toImage：离屏无头环境下 GPU 纹理回读 / vsync 帧
// 可能永不完成，导致 pump / toImage 卡死。page.render() 是纯 CPU/FFI 路径，真离屏可靠。
// 组件路径只做「挂载 + onViewerReady」轻量确认，不抓图、绝不 pumpAndSettle。
// 所有 pdfrx await 都套 timeout，保证进程必定退出、stdout 必定 flush 出证据。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/startup/observe_blank_detector.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';

const String _kPdfPath = String.fromEnvironment(
  'PDF_SPIKE_PATH',
  defaultValue: r'C:\Users\wrds\Downloads\QQ\prince.pdf',
);

/// 取证目录 `<evidenceDir>/screenshots/`，与 observe_capture 同约定：
/// run_windows_itest.ps1 传 FUSHI_TEST_ROOT=<evidenceDir>/isolated-root。
Directory _screenshotDir() {
  final String? root = hibikiTestRootPath();
  Directory base;
  if (root != null && root.isNotEmpty) {
    base = Directory(root);
    final String leaf = base.path.split(Platform.pathSeparator).last;
    if (leaf.toLowerCase() == 'isolated-root') {
      base = base.parent;
    }
  } else {
    final String? runId = hibikiTestRunId();
    final String runLeaf =
        (runId != null && runId.isNotEmpty) ? runId : 'local';
    base = Directory('.codex-test/observe/$runLeaf');
  }
  final Directory dir = Directory('${base.path}/screenshots');
  dir.createSync(recursive: true);
  return dir;
}

/// 把 PDFium 输出的 BGRA8888 位图编码成 PNG 落盘并判非空白（纯 CPU codec，无 GPU 回读）。
/// 返回 (nonBlank, pngBytes, path)。
Future<(bool, int, String)> _saveBgraAsPng(
  Uint8List bgra,
  int width,
  int height,
  String name,
) async {
  final ui.ImmutableBuffer buffer =
      await ui.ImmutableBuffer.fromUint8List(bgra);
  final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.bgra8888,
  );
  final ui.Codec codec = await descriptor.instantiateCodec();
  final ui.FrameInfo frame = await codec.getNextFrame();
  final ui.Image image = frame.image;
  try {
    final ByteData? png =
        await image.toByteData(format: ui.ImageByteFormat.png);
    // 非空白判定直接用原始 BGRA（通道顺序不影响「像素是否有变化」的方差判据）。
    final bool nonBlank = rgbaLooksNonBlank(bgra);
    if (png == null) return (nonBlank, 0, '');
    final Uint8List bytes = png.buffer.asUint8List();
    final String path = '${_screenshotDir().path}/$name.png';
    await File(path).writeAsBytes(bytes, flush: true);
    return (nonBlank, bytes.length, path);
  } finally {
    image.dispose();
    codec.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pdfrx 渲染 + 文本层 charRects spike', (WidgetTester tester) async {
    // 关键（Phase 0 发现）：pdfium_dart 用 DynamicLibrary.open('pdfium.dll') 裸名加载，
    // 不吃 Flutter 的 native_assets.json FFI 解析；而 `flutter test -d windows` 运行时
    // pdfium.dll 既不在 exe 同目录、也没有 pdfium_dart 期望的 .dart_tool/native_assets.yaml，
    // 导致 worker isolate 里 open 失败 → worker 回调抛错但不回传 → 首个 compute 永久挂死。
    // 解法：显式把 Pdfrx.pdfiumModulePath 钉到真实 DLL 绝对路径（会传播到 worker isolate）。
    final String sep = Platform.pathSeparator;
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final String cwd = Directory.current.path;
    final List<String> candidates = <String>[
      '$exeDir${sep}pdfium.dll',
      '$cwd${sep}build${sep}native_assets${sep}windows${sep}pdfium.dll',
    ];
    debugPrint('[pdf-spike] resolvedExecutable=${Platform.resolvedExecutable}');
    debugPrint('[pdf-spike] cwd=$cwd');
    String? pdfiumDll;
    for (final String c in candidates) {
      final bool exists = File(c).existsSync();
      debugPrint('[pdf-spike] pdfium.dll candidate=$c exists=$exists');
      if (exists && pdfiumDll == null) pdfiumDll = c;
    }
    if (pdfiumDll != null) {
      Pdfrx.pdfiumModulePath = pdfiumDll;
      debugPrint('[pdf-spike] set Pdfrx.pdfiumModulePath=$pdfiumDll');
    }

    // 引擎 API（PdfDocument.openFile）在任何 widget 构建前使用，必须先初始化 PDFium。
    debugPrint('[pdf-spike] step: before pdfrxFlutterInitialize');
    await pdfrxFlutterInitialize().timeout(const Duration(seconds: 20));
    debugPrint('[pdf-spike] step: after pdfrxFlutterInitialize');

    final File pdfFile = File(_kPdfPath);
    if (!pdfFile.existsSync()) {
      markTestSkipped('spike PDF 不存在，跳过：$_kPdfPath');
      return;
    }

    debugPrint('[pdf-spike] step: before PdfDocument.openFile');
    final PdfDocument document = await PdfDocument.openFile(_kPdfPath)
        .timeout(const Duration(seconds: 20));
    debugPrint('[pdf-spike] step: after PdfDocument.openFile');
    expect(document.pages, isNotEmpty, reason: 'PDF 至少应有一页');
    debugPrint('[pdf-spike] pageCount=${document.pages.length}');

    // ---- 文本层可行性：扫全书选一页正文最多的页做证据（首页常是仅含页码的封面）----
    debugPrint('[pdf-spike] step: before loadStructuredText scan');
    int bestIndex = 0;
    PdfPageText? bestText;
    int bestLen = -1;
    for (int i = 0; i < document.pages.length; i++) {
      final PdfPageText t = await document.pages[i]
          .loadStructuredText()
          .timeout(const Duration(seconds: 20));
      // 逐页硬校验：charRects 与 fullText 逐字符一一对应（点选查词地基）。
      expect(t.charRects.length, t.fullText.length,
          reason: 'page ${i + 1}: charRects 必须与 fullText 逐字符对应');
      if (t.fullText.trim().length > bestLen) {
        bestLen = t.fullText.trim().length;
        bestIndex = i;
        bestText = t;
      }
    }
    debugPrint('[pdf-spike] step: after loadStructuredText scan');
    final PdfPage page = document.pages[bestIndex];
    final PdfPageText pageText = bestText!;
    final String fullText = pageText.fullText;
    final List<PdfRect> charRects = pageText.charRects;
    debugPrint('[pdf-spike] richest page=${bestIndex + 1} '
        'size=${page.width}x${page.height}');
    debugPrint('[pdf-spike] fullText.length=${fullText.length}');
    final String sample =
        fullText.length > 100 ? fullText.substring(0, 100) : fullText;
    debugPrint('[pdf-spike] fullText[0:100]=<<<$sample>>>');
    debugPrint('[pdf-spike] charRects.length=${charRects.length}');
    if (charRects.isNotEmpty) {
      debugPrint('[pdf-spike] charRects.first=${charRects.first}');
      debugPrint('[pdf-spike] charRects.last=${charRects.last}');
    }

    expect(fullText.trim(), isNotEmpty, reason: '正文页应抽到非空文本');
    expect(charRects.length, fullText.length,
        reason: 'charRects 必须与 fullText 逐字符一一对应（点选查词地基）');

    // ---- 渲染验证：PDFium 直接把这页栅格化成位图并落 PNG ----
    final double fullWidth = page.width * 2; // 2x 提高可读性
    final double fullHeight = page.height * 2;
    final PdfImage? rendered = await page
        .render(
          fullWidth: fullWidth,
          fullHeight: fullHeight,
          backgroundColor: 0xFFFFFFFF, // 不透明白底，保证非空白判据有意义
        )
        .timeout(const Duration(seconds: 30));
    expect(rendered, isNotNull, reason: 'PDFium 应能栅格化该页');
    debugPrint(
        '[pdf-spike] rendered bitmap=${rendered!.width}x${rendered.height} '
        'pixels=${rendered.pixels.length}B');

    final (bool nonBlank, int pngBytes, String path) = await _saveBgraAsPng(
      rendered.pixels,
      rendered.width,
      rendered.height,
      'pdf-spike-prince-page${bestIndex + 1}',
    ).timeout(const Duration(seconds: 30));
    rendered.dispose();
    debugPrint('[pdf-spike] screenshot nonBlank=$nonBlank '
        'pngBytes=$pngBytes path=$path');
    expect(nonBlank, isTrue, reason: '正文页应栅格化出非空白像素');
    expect(pngBytes, greaterThan(0), reason: '应写出 PNG');

    // ---- 组件路径轻量确认：PdfViewer 能挂载并触发 onViewerReady（不抓图/不 settle）----
    final Completer<void> ready = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: PdfViewer.file(
            _kPdfPath,
            params: PdfViewerParams(
              onViewerReady: (_, __) {
                if (!ready.isCompleted) ready.complete();
              },
            ),
          ),
        ),
      ),
    );
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!ready.isCompleted && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    debugPrint(
        '[pdf-spike] PdfViewer onViewerReady fired=${ready.isCompleted}');
    expect(ready.isCompleted, isTrue,
        reason: 'PdfViewer 组件应挂载并在超时前触发 onViewerReady');

    await document.dispose();
  });
}
