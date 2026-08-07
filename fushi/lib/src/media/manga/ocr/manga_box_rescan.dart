/// 漫画阅读页「框选识别」服务（模块化架构下的 `media/manga/ocr/` 层）。
///
/// 职责：从当前页图文件裁出用户框选的矩形 → manga-ocr 识别器（beam4）→ 文本。
/// 只需识别三件套（encoder/decoder/vocab），**不需要检测器**——框即用户给的检测
/// 结果。所以就绪判定看 [MangaOcrModelStatus.recognizerReady]，不看 detector，也
/// 不看 `isSupportedPlatform`（那是整卷任务的重活闸门）。
///
/// ## 分层
///
/// 本文件与 `media/manga/ocr/` 下的 Google Lens / 缓存恢复同层：**只做 OCR 能力**，
/// 不含 UI、不含持久化。回写落 `media/manga/manga_json_writeback.dart`，结果卡片落
/// `media/manga/reader/manga_rescan_result_sheet.dart`，页面只做编排。
///
/// ## isolate 结构
///
/// 与整卷任务（`ocr/manga_ocr_service_impl.dart`）同款纪律：图片解码、预处理像素
/// 循环、beam search 记账全部下放 `Isolate.spawn` 的**常驻**后台 isolate（页面生命
/// 周期内懒建一次、会话缓存复用），经
/// `BackgroundIsolateBinaryMessenger.ensureInitialized(RootIsolateToken)` 让
/// `flutter_onnxruntime` 的 MethodChannel 调用从后台 isolate 直达 platform 线程。
/// 请求按到达顺序串行处理（`await for` 天然串行）。
///
/// ## 可测缝
///
/// - [MangaBoxRescanRunner] 接口：生产 = [IsolateMangaBoxRescanRunner]；测试注进程
///   内 fake。
/// - isolate 路径本身可测：[IsolateMangaBoxRescanRunner] 的 `bootstrap` 参数是
///   **顶层函数**（可跨 isolate 发送），测试传返回 fake [OcrRecognizer] 的顶层工厂
///   即可全链路走真 isolate、不碰 ORT。
/// - 纯函数（裁剪 / 就绪判定）独立导出直接单测。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, RootIsolateToken;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi/src/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi/src/ocr/manga_ocr_pipeline.dart' show isVerticalBlock;
import 'package:fushi/src/ocr/manga_ocr_recognizer.dart';
import 'package:fushi/src/ocr/manga_ocr_service_impl.dart'
    show MangaOcrServiceImpl, resolveOcrPlatform;
import 'package:fushi/src/ocr/manga_ocr_tokenizer.dart';
import 'package:fushi/src/ocr/ocr_inference.dart';
import 'package:fushi/src/ocr/ocr_inference_ort.dart';
import 'package:fushi/src/ocr/ocr_types.dart';

/// 纯函数：从整页图裁出 [box] 区域（clamp 页内、不缩放、最小 1px）。
img.Image cropMangaBoxRegion(img.Image page, OcrRect box) {
  final OcrRect clamped =
      box.clamp(page.width.toDouble(), page.height.toDouble());
  final int x = clamped.left.floor().clamp(0, page.width - 1);
  final int y = clamped.top.floor().clamp(0, page.height - 1);
  final int w = (clamped.right.ceil() - x).clamp(1, page.width - x);
  final int h = (clamped.bottom.ceil() - y).clamp(1, page.height - y);
  return img.copyCrop(page, x: x, y: y, width: w, height: h);
}

/// 识别三件套的绝对路径（字段全 String，可跨 isolate 发送）。
class MangaRescanModelPaths {
  const MangaRescanModelPaths({
    required this.encoderPath,
    required this.decoderPath,
    required this.vocabPath,
  });

  final String encoderPath;
  final String decoderPath;
  final String vocabPath;
}

/// 单框识别结果。
class MangaBoxRescanResult {
  const MangaBoxRescanResult({required this.text, required this.vertical});

  /// 识别文本（可能为空——例如手写体本地模型认不出）。
  final String text;

  /// 竖排判定。复用整卷流水线的 [isVerticalBlock]（阈值
  /// [kVerticalAspectThreshold] = 1.25），让框选块与检测块写进 manga.json 的
  /// `vertical` 字段口径完全一致；这里另立一套阈值只会制造覆盖层渲染差异。
  final bool vertical;
}

/// 单框识别 runner 接口（生产 = 常驻 isolate；测试 = 进程内 fake）。
abstract interface class MangaBoxRescanRunner {
  /// 识别 [imagePath] 页图上的 [box]（页图像素坐标），返回文本。
  Future<String> recognize(String imagePath, OcrRect box);

  /// 关闭 isolate / 释放会话（幂等）。
  Future<void> dispose();
}

/// isolate 内识别器工厂签名。**必须是顶层/静态函数**（跨 isolate 发送）。
typedef MangaRescanRecognizerBootstrap = Future<OcrRecognizer> Function(
  MangaRescanModelPaths paths,
);

/// 生产 bootstrap：EP 探测/选择 → 建 encoder/decoder 两个 ORT 会话 + 词表。
/// 在后台 isolate 内执行（调用方是 `_rescanIsolateMain`）。
Future<OcrRecognizer> createMangaRescanRecognizer(
  MangaRescanModelPaths paths,
) async {
  final OrtOcrSessionFactory factory = OrtOcrSessionFactory();
  bool cudaAvailable = false;
  try {
    cudaAvailable = await factory.isCudaAvailable();
  } catch (_) {
    cudaAvailable = false;
  }
  final List<OcrExecutionProvider> providers = selectOcrExecutionProviders(
    kind: OcrModelKind.recognition,
    platform: resolveOcrPlatform(Platform.operatingSystem),
    cudaAvailable: cudaAvailable,
  );
  final OcrSession encoder =
      await factory.createSession(paths.encoderPath, providers: providers);
  final OcrSession decoder =
      await factory.createSession(paths.decoderPath, providers: providers);
  final MangaOcrTokenizer tokenizer = MangaOcrTokenizer.fromVocabText(
    await File(paths.vocabPath).readAsString(),
  );
  return MangaOcrRecognizer(
    encoderSession: encoder,
    decoderSession: decoder,
    tokenizer: tokenizer,
  );
}

// ── isolate 消息协议（Isolate.spawn 同代码库，直接发送实例）─────────────────

class _RescanIsolateArgs {
  const _RescanIsolateArgs({
    required this.events,
    required this.rootIsolateToken,
    required this.modelPaths,
    required this.bootstrap,
  });

  final SendPort events;
  final RootIsolateToken? rootIsolateToken;
  final MangaRescanModelPaths modelPaths;
  final MangaRescanRecognizerBootstrap bootstrap;
}

class _RescanReadyMessage {
  const _RescanReadyMessage(this.requests);
  final SendPort requests;
}

class _RescanRequestMessage {
  const _RescanRequestMessage({
    required this.id,
    required this.imagePath,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final int id;
  final String imagePath;
  final double left;
  final double top;
  final double right;
  final double bottom;
}

class _RescanReplyMessage {
  const _RescanReplyMessage(this.id, this.text);
  final int id;
  final String text;
}

class _RescanErrorMessage {
  const _RescanErrorMessage(this.id, this.message, this.stackTrace);
  final int id;
  final String message;
  final String stackTrace;
}

/// isolate 收到即退出循环、释放识别器的控制消息。
const String _kRescanDisposeMessage = 'dispose';

/// isolate 入口：懒建识别器（首个请求时经 bootstrap），此后会话常驻复用；
/// 请求经 `await for` 串行处理，直到 dispose。
Future<void> _rescanIsolateMain(_RescanIsolateArgs args) async {
  final ReceivePort requests = ReceivePort();
  final RootIsolateToken? token = args.rootIsolateToken;
  if (token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }
  args.events.send(_RescanReadyMessage(requests.sendPort));

  OcrRecognizer? recognizer;
  await for (final Object? message in requests) {
    if (message == _kRescanDisposeMessage) {
      break;
    }
    if (message is! _RescanRequestMessage) {
      continue;
    }
    try {
      recognizer ??= await args.bootstrap(args.modelPaths);
      final Uint8List bytes = await File(message.imagePath).readAsBytes();
      final img.Image? page = img.decodeImage(bytes);
      if (page == null) {
        throw StateError('failed to decode image: ${message.imagePath}');
      }
      final String text = await recognizer.recognize(
        page,
        OcrRect(
          left: message.left,
          top: message.top,
          right: message.right,
          bottom: message.bottom,
        ),
      );
      args.events.send(_RescanReplyMessage(message.id, text));
    } catch (e, stack) {
      args.events.send(_RescanErrorMessage(message.id, '$e', '$stack'));
    }
  }
  requests.close();
  final OcrRecognizer? rec = recognizer;
  if (rec is MangaOcrRecognizer) {
    try {
      await rec.close();
    } catch (_) {}
  }
}

/// 生产 runner：常驻后台 isolate，懒 spawn + 会话缓存复用。
class IsolateMangaBoxRescanRunner implements MangaBoxRescanRunner {
  IsolateMangaBoxRescanRunner({
    required this.modelPaths,
    this.bootstrap = createMangaRescanRecognizer,
  });

  final MangaRescanModelPaths modelPaths;

  /// 必须是顶层/静态函数（跨 isolate 发送）；测试注 fake 工厂走真 isolate 路径。
  final MangaRescanRecognizerBootstrap bootstrap;

  final ReceivePort _events = ReceivePort();
  final Map<int, Completer<String>> _pending = <int, Completer<String>>{};
  Completer<SendPort>? _requestsPort;
  int _nextId = 0;
  bool _disposed = false;

  Future<SendPort> _ensureStarted() {
    final Completer<SendPort>? existing = _requestsPort;
    if (existing != null) {
      return existing.future;
    }
    final Completer<SendPort> completer = Completer<SendPort>();
    _requestsPort = completer;
    _events.listen(_onMessage);
    unawaited(() async {
      try {
        await Isolate.spawn<_RescanIsolateArgs>(
          _rescanIsolateMain,
          _RescanIsolateArgs(
            events: _events.sendPort,
            rootIsolateToken: RootIsolateToken.instance,
            modelPaths: modelPaths,
            bootstrap: bootstrap,
          ),
          onError: _events.sendPort,
          debugName: 'manga_box_rescan',
        );
      } catch (e, stack) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('failed to spawn rescan isolate: $e'),
            stack,
          );
        }
      }
    }());
    return completer.future;
  }

  void _onMessage(Object? message) {
    if (message is _RescanReadyMessage) {
      final Completer<SendPort>? completer = _requestsPort;
      if (completer != null && !completer.isCompleted) {
        completer.complete(message.requests);
      }
      return;
    }
    if (message is _RescanReplyMessage) {
      _pending.remove(message.id)?.complete(message.text);
      return;
    }
    if (message is _RescanErrorMessage) {
      _pending.remove(message.id)?.completeError(
            StateError('manga box rescan failed: ${message.message}'),
            StackTrace.fromString(message.stackTrace),
          );
      return;
    }
    if (message is List<Object?> && message.length == 2) {
      // Isolate.spawn onError 通道（[error, stackTrace] 字符串对）：isolate 已死，
      // 全部在飞请求失败。
      final StateError error =
          StateError('manga box rescan isolate crashed: ${message[0]}');
      final StackTrace stack = StackTrace.fromString('${message[1]}');
      for (final Completer<String> pending
          in List<Completer<String>>.of(_pending.values)) {
        pending.completeError(error, stack);
      }
      _pending.clear();
    }
  }

  @override
  Future<String> recognize(String imagePath, OcrRect box) async {
    if (_disposed) {
      throw StateError('rescan runner already disposed');
    }
    final SendPort requests = await _ensureStarted();
    final int id = _nextId++;
    final Completer<String> completer = Completer<String>();
    _pending[id] = completer;
    requests.send(_RescanRequestMessage(
      id: id,
      imagePath: imagePath,
      left: box.left,
      top: box.top,
      right: box.right,
      bottom: box.bottom,
    ));
    return completer.future;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final Completer<SendPort>? started = _requestsPort;
    if (started != null && started.isCompleted) {
      try {
        (await started.future).send(_kRescanDisposeMessage);
      } catch (_) {}
    }
    _events.close();
    final StateError error = StateError('rescan runner disposed');
    for (final Completer<String> pending
        in List<Completer<String>>.of(_pending.values)) {
      pending.completeError(error, StackTrace.current);
    }
    _pending.clear();
  }
}

/// 框选识别服务：模型路径解析 + runner 生命周期（页面生命周期内懒建一次）。
class MangaBoxRescanService {
  MangaBoxRescanService({
    Future<Directory> Function()? modelsDirProvider,
    List<MangaOcrModelFile>? manifest,
    MangaBoxRescanRunner Function(MangaRescanModelPaths paths)? runnerFactory,
  })  : _modelsDirProvider =
            modelsDirProvider ?? MangaOcrServiceImpl.defaultMangaOcrModelsDir,
        _manifest = manifest ?? kMangaOcrModelManifest,
        _runnerFactory = runnerFactory ??
            ((MangaRescanModelPaths paths) =>
                IsolateMangaBoxRescanRunner(modelPaths: paths));

  final Future<Directory> Function() _modelsDirProvider;
  final List<MangaOcrModelFile> _manifest;
  final MangaBoxRescanRunner Function(MangaRescanModelPaths paths)
      _runnerFactory;

  MangaBoxRescanRunner? _runner;
  bool _disposed = false;

  /// 本平台是否内置本地 OCR native（Apple 已随 flutter_onnxruntime gate 出，见
  /// `ocr_inference_ort.dart` 的 [isLocalOnnxRuntimeAvailable]）。调用方在尝试识别
  /// 前判定，以便给出「本平台暂不支持」而不是抛异常。
  bool get isLocalRescanSupported => isLocalOnnxRuntimeAvailable;

  /// 识别三件套是否就绪（**不看检测器**——单框不需要它）。
  Future<bool> isRecognizerReady() async {
    final Directory dir = await _modelsDirProvider();
    for (final MangaOcrModelFile model in _manifest) {
      if (model.role != MangaOcrModelRole.recognizer) continue;
      if (!isMangaOcrModelFileReady(File(p.join(dir.path, model.fileName)))) {
        return false;
      }
    }
    return true;
  }

  Future<MangaRescanModelPaths> _resolveModelPaths() async {
    final Directory dir = await _modelsDirProvider();
    String pathOf(String suffix) {
      final MangaOcrModelFile model = _manifest.firstWhere(
        (MangaOcrModelFile m) =>
            m.role == MangaOcrModelRole.recognizer &&
            m.fileName.endsWith(suffix),
        orElse: () => throw StateError(
          'manifest missing recognizer file with suffix $suffix',
        ),
      );
      return p.join(dir.path, model.fileName);
    }

    return MangaRescanModelPaths(
      encoderPath: pathOf('encoder_model.onnx'),
      decoderPath: pathOf('decoder_model.onnx'),
      vocabPath: pathOf('vocab.txt'),
    );
  }

  /// 识别 [imagePath] 页图上的 [box]（页图像素坐标）。runner 懒建并缓存复用。
  Future<MangaBoxRescanResult> rescan({
    required String imagePath,
    required OcrRect box,
  }) async {
    if (_disposed) {
      throw StateError('rescan service already disposed');
    }
    if (!isLocalRescanSupported) {
      throw StateError('local manga OCR (onnxruntime) is not available on '
          '${Platform.operatingSystem}');
    }
    if (!await isRecognizerReady()) {
      throw StateError('manga OCR recognizer models are not downloaded');
    }
    _runner ??= _runnerFactory(await _resolveModelPaths());
    final String text = await _runner!.recognize(imagePath, box);
    return MangaBoxRescanResult(text: text, vertical: isVerticalBlock(box));
  }

  Future<void> dispose() async {
    _disposed = true;
    final MangaBoxRescanRunner? runner = _runner;
    _runner = null;
    if (runner != null) {
      await runner.dispose();
    }
  }
}
