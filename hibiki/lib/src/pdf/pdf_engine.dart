import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// PDF 阅读器（Phase 1）的 pdfrx/PDFium 引擎初始化单一入口。
///
/// pdfrx 的引擎 API（[PdfDocument.openFile]）与 [PdfViewer] 组件在使用前都必须先
/// 调 [pdfrxFlutterInitialize]。本类把初始化收敛到一处、做幂等守卫，避免导入器与
/// 阅读器页各自重复初始化。
///
/// Windows 特有坑（Phase 0 spike 发现）：`pdfium_dart` 用
/// `DynamicLibrary.open('pdfium.dll')` **裸名**加载 PDFium。正常发布的 Windows app
/// 里 native-assets 会把 `pdfium.dll` 拷到 exe 同目录，裸名加载能命中；但保险起见，
/// 若能在 exe 同目录或构建产物目录定位到真实 DLL，就显式钉 [Pdfrx.pdfiumModulePath]，
/// 这样即便 native-assets 布置缺失（如离屏测试运行时）也不会在 worker isolate 里
/// open 失败导致首个 render 永久挂死。macOS/iOS/Android/Linux 走各自的链接方式，无需
/// 钉路径。
class PdfEngine {
  PdfEngine._();

  static bool _initialized = false;

  /// 幂等初始化 pdfrx。首次调用会（Windows 上）尝试定位并钉 `pdfium.dll`，再调
  /// [pdfrxFlutterInitialize]；后续调用直接返回。
  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    _pinPdfiumModulePathIfFound();
    await pdfrxFlutterInitialize();
    _initialized = true;
  }

  /// 仅 Windows：在 exe 同目录 / 构建产物 native_assets 目录找 `pdfium.dll`，找到就
  /// 钉到 [Pdfrx.pdfiumModulePath]（会传播到 pdfrx 的 worker isolate）。找不到则不设，
  /// 交回 pdfrx 默认的裸名加载（发布 app 由 native-assets 布置在 exe 同目录）。
  static void _pinPdfiumModulePathIfFound() {
    if (!Platform.isWindows) return;
    final String sep = Platform.pathSeparator;
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final List<String> candidates = <String>[
      '$exeDir${sep}pdfium.dll',
      '${Directory.current.path}${sep}build${sep}native_assets${sep}windows'
          '${sep}pdfium.dll',
    ];
    for (final String candidate in candidates) {
      if (File(candidate).existsSync()) {
        Pdfrx.pdfiumModulePath = candidate;
        return;
      }
    }
  }

  /// 把 [page] 栅格化成 PNG 字节（等比缩到宽 [targetWidth]，白底）。失败返回 null。
  ///
  /// 导入器取封面与「PDF → 漫画」逐页导出页图用的是同一段 PDFium 调用，差别只有
  /// 目标宽度，故收在引擎入口一处：两边各写一份，背景色/缩放/dispose 时机随时能漂。
  static Future<Uint8List?> renderPagePng(
    PdfPage page, {
    required double targetWidth,
  }) async {
    try {
      final double scale = page.width > 0 ? targetWidth / page.width : 1.0;
      final PdfImage? rendered = await page.render(
        fullWidth: page.width * scale,
        fullHeight: page.height * scale,
        backgroundColor: 0xFFFFFFFF,
      );
      if (rendered == null) return null;
      try {
        return await bgraToPng(
            rendered.pixels, rendered.width, rendered.height);
      } finally {
        rendered.dispose();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('PdfEngine.renderPagePng', e, stack);
      return null;
    }
  }

  /// 把 PDFium 输出的 BGRA8888 位图编码成 PNG 字节（纯 CPU codec，无 GPU 回读，
  /// 离屏可靠）。
  static Future<Uint8List?> bgraToPng(
    Uint8List bgra,
    int width,
    int height,
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
      return png?.buffer.asUint8List();
    } finally {
      image.dispose();
      codec.dispose();
    }
  }
}
