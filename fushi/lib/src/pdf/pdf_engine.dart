import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// Windows 上 `pdfium.dll` 不可加载时抛出。
///
/// 它取代的是「无声挂死」：见 [PdfEngine._assertPdfiumLoadable]。消息会原样进错误
/// toast，所以要写清**搜过哪里**，让用户/开发者一眼看出这是分发缺件，而不是这份
/// PDF 有问题。
class PdfiumUnavailableException implements Exception {
  const PdfiumUnavailableException({
    required this.pinnedPath,
    required this.searchedExeDir,
    required this.cause,
  });

  /// [Pdfrx.pdfiumModulePath] 的值；null 表示两个候选都没命中、走的是裸名加载。
  final String? pinnedPath;

  /// exe 所在目录——正常安装下 `pdfium.dll` 应该就在这里。
  final String searchedExeDir;

  final Object cause;

  @override
  String toString() {
    final String where =
        pinnedPath ?? 'pdfium.dll (bare name) near $searchedExeDir';
    return 'PDFium is not available: failed to load $where. The PDF engine is '
        'missing from this build, so PDF import and the PDF reader cannot run. '
        'Cause: $cause';
  }
}

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
    _assertPdfiumLoadable();
    await pdfrxFlutterInitialize();
    _initialized = true;
  }

  /// 仅 Windows：在**主 isolate** 里先把 PDFium 加载一遍，加载不了就当场抛
  /// [PdfiumUnavailableException]。
  ///
  /// 这不是防御性编程，是把一个不可诊断的形态换成可诊断的形态。pdfrx 的 worker
  /// isolate 用 `execute() => sendPort.send(callback(message))` 执行任务，**没有
  /// try/catch**：`callback` 同步抛出时 `sendPort.send` 整句不执行，主 isolate 那边
  /// `await receivePort.first` 于是永不完成——不是报错，是**永久挂起**。导入对话框的
  /// catch/finally 一条都不会触发，进度条永远停在最后一次 reportProgress，用户只能
  /// 杀进程（BUG-2419）。而且 worker 死后 `_sendPort` 仍非 null，之后每一次 PDF 操作
  /// 都照样挂死，直到重启 app。
  ///
  /// 修不了 pdfrx（上游包缺陷），所以在自己这一侧做前置判定：主 isolate 的
  /// `DynamicLibrary.open` 抛出的异常能正常冒泡，变成一条带原因的错误 toast。
  /// Windows 已加载的模块会被复用，重复 open 的代价可忽略。
  ///
  /// 只做 Windows：iOS/macOS 走 `DynamicLibrary.process()`（PDFium 由 XCFramework
  /// 静态链接），Android 由 linker 从 APK 的 native lib 目录解析，都没有这条裸名
  /// 加载路径。
  static void _assertPdfiumLoadable() {
    if (!Platform.isWindows) return;
    final String? pinned = Pdfrx.pdfiumModulePath;
    try {
      ffi.DynamicLibrary.open(pinned ?? 'pdfium.dll');
    } catch (e) {
      throw PdfiumUnavailableException(
        pinnedPath: pinned,
        searchedExeDir: File(Platform.resolvedExecutable).parent.path,
        cause: e,
      );
    }
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
