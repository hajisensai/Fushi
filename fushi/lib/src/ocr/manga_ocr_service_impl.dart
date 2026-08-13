/// [MangaOcrService] 真实实现：模型清单/下载管理 + 后台 isolate 整卷 OCR +
/// EP 策略接线。
///
/// ## isolate 结构（设计决策）
///
/// `flutter_onnxruntime` 是 MethodChannel 插件（native 侧注册在 root engine）。
/// 整卷任务把**全部 Dart 侧重活**（图片解码、预处理像素循环、beam search 记账）
/// 放进 `Isolate.spawn` 的后台 isolate，靠
/// `BackgroundIsolateBinaryMessenger.ensureInitialized(RootIsolateToken)`
/// 让插件的 MethodChannel 调用从后台 isolate 直达 root engine 的 platform
/// 线程——ORT native 推理本就跑在 platform/native 线程，UI isolate 全程零负担。
/// 取消经 control SendPort 送进 isolate 置位 [OcrCancelToken]，页/块边界停。
///
/// ## 可测缝
///
/// - 模型目录、下载器、清单、任务 runner 全部构造注入；测试用临时目录 +
///   本地 HttpServer + 进程内 fake runner，不下载真模型、不跑真 ORT。
/// - EP 接线是纯函数组合（[resolveOcrPlatform] + [selectOcrExecutionProviders]）。
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, RootIsolateToken;
import 'package:path/path.dart' as p;

import 'package:fushi/src/ocr/manga_ocr_folder_job.dart';
import 'package:fushi/src/ocr/manga_ocr_model_downloader.dart';
import 'package:fushi/src/ocr/manga_ocr_model_fingerprint.dart' as model_fp;
import 'package:fushi/src/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi/src/ocr/manga_ocr_pipeline.dart';
import 'package:fushi/src/ocr/manga_ocr_recognizer.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/ocr/manga_ocr_tokenizer.dart';
import 'package:fushi/src/ocr/ocr_inference.dart';
import 'package:fushi/src/ocr/ocr_inference_ort.dart';
import 'package:fushi/src/ocr/text_detector.dart';

/// 纯函数：`Platform.operatingSystem` 字符串 → [OcrPlatform]。
/// 未知平台（fuchsia 等）落 linux 档（纯 CPU），不会选到不存在的 EP。
OcrPlatform resolveOcrPlatform(String operatingSystem) {
  switch (operatingSystem) {
    case 'windows':
      return OcrPlatform.windows;
    case 'macos':
      return OcrPlatform.macos;
    case 'ios':
      return OcrPlatform.ios;
    case 'android':
      return OcrPlatform.android;
    case 'linux':
    default:
      return OcrPlatform.linux;
  }
}

/// 四个模型文件的绝对路径（isolate 参数，字段全 String 可跨 isolate 发送）。
class MangaOcrModelPaths {
  const MangaOcrModelPaths({
    required this.detectorPath,
    required this.encoderPath,
    required this.decoderPath,
    required this.vocabPath,
  });

  final String detectorPath;
  final String encoderPath;
  final String decoderPath;
  final String vocabPath;
}

/// 整卷任务请求。
class MangaOcrVolumeJobRequest {
  const MangaOcrVolumeJobRequest({
    required this.imageDirPath,
    required this.modelPaths,
    this.volumeTitle,
  });

  final String imageDirPath;
  final MangaOcrModelPaths modelPaths;

  /// 展示用卷名（manga.json 结构本身无标题字段，仅透传给未来 UI/日志）。
  final String? volumeTitle;
}

/// 一次在跑的整卷任务句柄。
abstract interface class MangaOcrVolumeJob {
  /// 完成时给出 manga.json 绝对路径；取消以 [OcrCancelledException] 失败。
  Future<String> get result;

  /// 请求取消（页/块边界生效，幂等）。
  void cancel();
}

/// 整卷任务 runner 接口（生产 = isolate；测试 = 进程内 fake）。
abstract interface class MangaOcrVolumeJobRunner {
  /// [onAcceleration] 在会话建成后回报本次真正生效的执行后端与降级原因；
  /// 只回报一次（BUG-1163）。
  MangaOcrVolumeJob start(
    MangaOcrVolumeJobRequest request, {
    required void Function(int pagesDone, int pagesTotal) onProgress,
    void Function(MangaOcrAcceleration acceleration)? onAcceleration,
  });
}

// ── isolate 消息协议（Isolate.spawn 同代码库，可直接发送实例） ────────────

class _JobControlPortMessage {
  const _JobControlPortMessage(this.controlPort);
  final SendPort controlPort;
}

class _JobProgressMessage {
  const _JobProgressMessage(this.pagesDone, this.pagesTotal);
  final int pagesDone;
  final int pagesTotal;
}

class _JobAccelerationMessage {
  const _JobAccelerationMessage(this.acceleration);
  final MangaOcrAcceleration acceleration;
}

class _JobDoneMessage {
  const _JobDoneMessage(this.mangaJsonPath);
  final String mangaJsonPath;
}

class _JobCancelledMessage {
  const _JobCancelledMessage();
}

class _JobErrorMessage {
  const _JobErrorMessage(this.message, this.stackTrace);
  final String message;
  final String stackTrace;
}

/// isolate 收到即置位取消令牌的控制消息。
const String _kJobCancelMessage = 'cancel';

class _JobIsolateArgs {
  const _JobIsolateArgs({
    required this.events,
    required this.rootIsolateToken,
    required this.imageDirPath,
    required this.modelPaths,
  });

  final SendPort events;
  final RootIsolateToken? rootIsolateToken;
  final String imageDirPath;
  final MangaOcrModelPaths modelPaths;
}

/// isolate 入口：EP 探测/选择 → 建三个 ORT 会话 → 跑目录任务 → 回发事件。
Future<void> _volumeJobIsolateMain(_JobIsolateArgs args) async {
  final ReceivePort control = ReceivePort();
  final OcrCancelToken cancelToken = OcrCancelToken();
  control.listen((Object? message) {
    if (message == _kJobCancelMessage) {
      cancelToken.cancel();
    }
  });
  args.events.send(_JobControlPortMessage(control.sendPort));

  TextDetector? detector;
  MangaOcrRecognizer? recognizer;
  try {
    final RootIsolateToken? token = args.rootIsolateToken;
    if (token != null) {
      // 让 flutter_onnxruntime 的 MethodChannel 调用可从本后台 isolate 发出。
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }
    final OrtOcrSessionFactory factory = OrtOcrSessionFactory();
    final List<String> degradeReasons = <String>[];
    bool cudaAvailable = false;
    try {
      cudaAvailable = await factory.isCudaAvailable();
    } catch (error) {
      // BUG-1163：探测失败也是降级（有 N 卡也会退到 DirectML/CPU），
      // 必须留痕，不能 catch (_) 吞掉。
      cudaAvailable = false;
      degradeReasons.add('CUDA provider probe failed: $error');
      developer.log(
        'manga OCR CUDA provider probe failed; assuming unavailable',
        name: kOcrLogName,
        error: error,
      );
    }
    final OcrPlatform platform = resolveOcrPlatform(Platform.operatingSystem);
    final List<OcrExecutionProvider> detectionProviders =
        selectOcrExecutionProviders(
      kind: OcrModelKind.detection,
      platform: platform,
      cudaAvailable: cudaAvailable,
    );
    final List<OcrExecutionProvider> recognitionProviders =
        selectOcrExecutionProviders(
      kind: OcrModelKind.recognition,
      platform: platform,
      cudaAvailable: cudaAvailable,
    );

    OcrExecutionProvider detectionEffective = detectionProviders.first;
    OcrExecutionProvider recognitionEffective = recognitionProviders.first;
    void record(String role, OcrProviderResolution resolution) {
      if (!resolution.didFallBack) return;
      degradeReasons.add('$role: ${resolution.requested.first.name} -> '
          '${resolution.effective.name} (${resolution.fallbackReason})');
    }

    detector = TextDetector(await factory.createSession(
      args.modelPaths.detectorPath,
      providers: detectionProviders,
      onProviderResolved: (OcrProviderResolution resolution) {
        detectionEffective = resolution.effective;
        record('detector', resolution);
      },
    ));
    final OcrSession encoder = await factory.createSession(
      args.modelPaths.encoderPath,
      providers: recognitionProviders,
      onProviderResolved: (OcrProviderResolution resolution) {
        recognitionEffective = resolution.effective;
        record('recognition encoder', resolution);
      },
    );
    final OcrSession decoder = await factory.createSession(
      args.modelPaths.decoderPath,
      providers: recognitionProviders,
      onProviderResolved: (OcrProviderResolution resolution) {
        recognitionEffective = resolution.effective;
        record('recognition decoder', resolution);
      },
    );
    final MangaOcrAcceleration acceleration = MangaOcrAcceleration(
      detection: detectionEffective,
      recognition: recognitionEffective,
      degradeReasons: List<String>.unmodifiable(degradeReasons),
    );
    developer.log(
      'manga OCR volume job acceleration: $acceleration',
      name: kOcrLogName,
    );
    args.events.send(_JobAccelerationMessage(acceleration));
    final MangaOcrTokenizer tokenizer = MangaOcrTokenizer.fromVocabText(
      await File(args.modelPaths.vocabPath).readAsString(),
    );
    recognizer = MangaOcrRecognizer(
      encoderSession: encoder,
      decoderSession: decoder,
      tokenizer: tokenizer,
    );

    // 缓存目录带上本机已安装模型的内容指纹：上游换模型后旧页缓存自然失效，
    // 不会与新模型的结果混进同一卷（BUG-1173）。指纹按 (size, mtime) 记忆化，
    // 常态只做几次 stat。
    final String engineSignature =
        await model_fp.resolveLocalMangaOcrEngineSignature(
      Directory(p.dirname(args.modelPaths.detectorPath)),
    );
    final String mangaJsonPath = await runMangaOcrFolderJob(
      imageDirPath: args.imageDirPath,
      detector: detector,
      recognizer: recognizer,
      engineSignature: engineSignature,
      cancelToken: cancelToken,
      onProgress: (int done, int total) {
        args.events.send(_JobProgressMessage(done, total));
      },
    );
    args.events.send(_JobDoneMessage(mangaJsonPath));
  } on OcrCancelledException {
    args.events.send(const _JobCancelledMessage());
  } catch (e, stack) {
    args.events.send(_JobErrorMessage('$e', '$stack'));
  } finally {
    control.close();
    try {
      await detector?.close();
    } catch (_) {}
    try {
      await recognizer?.close();
    } catch (_) {}
  }
}

/// 生产 runner：整卷任务下放 [Isolate.spawn] 后台 isolate。
class IsolateMangaOcrVolumeJobRunner implements MangaOcrVolumeJobRunner {
  const IsolateMangaOcrVolumeJobRunner();

  @override
  MangaOcrVolumeJob start(
    MangaOcrVolumeJobRequest request, {
    required void Function(int pagesDone, int pagesTotal) onProgress,
    void Function(MangaOcrAcceleration acceleration)? onAcceleration,
  }) {
    final _IsolateVolumeJob job = _IsolateVolumeJob(onProgress, onAcceleration);
    job.spawn(request);
    return job;
  }
}

class _IsolateVolumeJob implements MangaOcrVolumeJob {
  _IsolateVolumeJob(this._onProgress, this._onAcceleration);

  final void Function(int pagesDone, int pagesTotal) _onProgress;
  final void Function(MangaOcrAcceleration acceleration)? _onAcceleration;
  final Completer<String> _completer = Completer<String>();
  final ReceivePort _events = ReceivePort();
  SendPort? _control;
  bool _cancelRequested = false;

  @override
  Future<String> get result => _completer.future;

  void spawn(MangaOcrVolumeJobRequest request) {
    _events.listen(_onMessage);
    unawaited(() async {
      try {
        await Isolate.spawn<_JobIsolateArgs>(
          _volumeJobIsolateMain,
          _JobIsolateArgs(
            events: _events.sendPort,
            rootIsolateToken: RootIsolateToken.instance,
            imageDirPath: request.imageDirPath,
            modelPaths: request.modelPaths,
          ),
          onError: _events.sendPort,
          debugName: 'manga_ocr_volume_job',
        );
      } catch (e, stack) {
        _finishError(StateError('failed to spawn OCR isolate: $e'), stack);
      }
    }());
  }

  void _onMessage(Object? message) {
    if (message is _JobControlPortMessage) {
      _control = message.controlPort;
      if (_cancelRequested) {
        message.controlPort.send(_kJobCancelMessage);
      }
      return;
    }
    if (message is _JobAccelerationMessage) {
      if (!_completer.isCompleted) {
        _onAcceleration?.call(message.acceleration);
      }
      return;
    }
    if (message is _JobProgressMessage) {
      if (!_completer.isCompleted) {
        _onProgress(message.pagesDone, message.pagesTotal);
      }
      return;
    }
    if (message is _JobDoneMessage) {
      if (!_completer.isCompleted) {
        _completer.complete(message.mangaJsonPath);
      }
      _events.close();
      return;
    }
    if (message is _JobCancelledMessage) {
      _finishError(const OcrCancelledException(), StackTrace.current);
      return;
    }
    if (message is _JobErrorMessage) {
      _finishError(
        StateError('manga OCR job failed: ${message.message}'),
        StackTrace.fromString(message.stackTrace),
      );
      return;
    }
    if (message is List<Object?> && message.length == 2) {
      // Isolate.spawn onError 的未捕获错误通道（[error, stackTrace] 字符串对）。
      _finishError(
        StateError('manga OCR isolate crashed: ${message[0]}'),
        StackTrace.fromString('${message[1]}'),
      );
    }
  }

  void _finishError(Object error, StackTrace stack) {
    if (!_completer.isCompleted) {
      _completer.completeError(error, stack);
    }
    _events.close();
  }

  @override
  void cancel() {
    _cancelRequested = true;
    _control?.send(_kJobCancelMessage);
  }
}

/// [MangaOcrService] 真实实现。
class MangaOcrServiceImpl implements MangaOcrService {
  MangaOcrServiceImpl({
    Future<Directory> Function()? modelsDirProvider,
    MangaOcrModelDownloader? downloader,
    List<MangaOcrModelFile>? manifest,
    MangaOcrVolumeJobRunner? jobRunner,
    bool Function()? platformSupport,
  })  : _modelsDirProvider = modelsDirProvider ?? defaultMangaOcrModelsDir,
        _downloader = downloader ?? MangaOcrModelDownloader(),
        _manifest = manifest ?? kMangaOcrModelManifest,
        _jobRunner = jobRunner ?? const IsolateMangaOcrVolumeJobRunner(),
        _platformSupport = platformSupport ?? defaultPlatformSupport;

  final Future<Directory> Function() _modelsDirProvider;
  final MangaOcrModelDownloader _downloader;
  final List<MangaOcrModelFile> _manifest;
  final MangaOcrVolumeJobRunner _jobRunner;
  final bool Function() _platformSupport;

  /// 默认模型目录：`<appSupport>/ocr_models/manga`（经 [AppPaths] 数据根
  /// 单一入口，不硬编码平台路径）。指纹层与本类共用同一个解析函数。
  static Future<Directory> defaultMangaOcrModelsDir() =>
      model_fp.defaultMangaOcrModelsDir();

  /// 整卷本地 OCR 的平台闸门 = **桌面三端 + iOS**，且本机确有 ORT native
  /// （[isLocalOnnxRuntimeAvailable]）。
  ///
  /// macOS 是 2026-08 随 flutter_onnxruntime fork 重新接上 Apple native 后开的：
  /// 它就是桌面，和 Windows / Linux 同一档重活预算。
  ///
  /// iOS 一并开——整卷是重活，但 iPhone/iPad 上既没有外部 mokuro CLI 也没有桌面
  /// 可用，不开就等于「iOS 永远没有本地整卷 OCR」。
  ///
  /// **真机实测（2026-08-14，`integration_test/manga_ocr_volume_e2e_itest.dart`，
  /// 4 块竖排气泡的 1200×1700 页，识别逐字 100% 正确）**：
  ///
  /// | 设备 | 每页 | 构成 |
  /// |---|---|---|
  /// | macOS 26.6（M 系列） | 2.7s | 检测 148ms + 识别 4 块 |
  /// | iPhone SE 2（A13, iOS 26.6） | 13.9s | 检测 381ms + 识别 4 块 |
  ///
  /// A13 是当前最低档的在役 iPhone；识别耗时**随页内文字块数线性增长**，真实漫画
  /// 一页 10~15 块，A13 上折合约 35~50s/页。也就是说整卷在老机型上是「挂着跑几
  /// 小时」的量级——能用，但别当交互操作。新机型（A17/A18）大致快 3~4 倍。
  /// 用户不接受这个量级时，向导里的「已配对主机代跑」和 Google Lens 仍在。
  ///
  /// **Android 仍不开**：与本次改动无关，其闸门从来就不是 ORT 可用性决定的
  /// （Android native 一直正常注册），而是低端机的重活预算问题，另案评估。
  static bool defaultPlatformSupport() =>
      (Platform.isWindows ||
          Platform.isLinux ||
          Platform.isMacOS ||
          Platform.isIOS) &&
      isLocalOnnxRuntimeAvailable;

  @override
  bool get isSupportedPlatform => _platformSupport();

  @override
  Future<MangaOcrModelStatus> modelStatus() async {
    final Directory dir = await _modelsDirProvider();
    bool detectorReady = true;
    bool recognizerReady = true;
    int downloadedBytes = 0;
    int totalBytes = 0;
    for (final MangaOcrModelFile model in _manifest) {
      totalBytes += model.expectedBytes;
      final File file = File(p.join(dir.path, model.fileName));
      if (isMangaOcrModelFileReady(file)) {
        downloadedBytes += file.lengthSync();
      } else if (model.role == MangaOcrModelRole.detector) {
        detectorReady = false;
      } else {
        recognizerReady = false;
      }
    }
    return MangaOcrModelStatus(
      detectorReady: detectorReady,
      recognizerReady: recognizerReady,
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
    );
  }

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() async* {
    final Directory dir = await _modelsDirProvider();
    yield* _downloader.downloadAll(files: _manifest, targetDir: dir);
  }

  @override
  Future<void> deleteModels() async {
    final Directory dir = await _modelsDirProvider();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<MangaOcrModelPaths> _resolveModelPaths() async {
    final Directory dir = await _modelsDirProvider();
    String pathOf(MangaOcrModelRole role, String suffix) {
      final MangaOcrModelFile model = _manifest.firstWhere(
        (MangaOcrModelFile m) => m.role == role && m.fileName.endsWith(suffix),
        orElse: () =>
            throw StateError('manifest missing $role file with suffix $suffix'),
      );
      return p.join(dir.path, model.fileName);
    }

    return MangaOcrModelPaths(
      detectorPath: pathOf(MangaOcrModelRole.detector, '.onnx'),
      encoderPath: pathOf(MangaOcrModelRole.recognizer, 'encoder_model.onnx'),
      decoderPath: pathOf(MangaOcrModelRole.recognizer, 'decoder_model.onnx'),
      vocabPath: pathOf(MangaOcrModelRole.recognizer, 'vocab.txt'),
    );
  }

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) {
    final StreamController<MangaOcrVolumeEvent> controller =
        StreamController<MangaOcrVolumeEvent>();
    MangaOcrVolumeJob? job;
    bool cancelled = false;
    int lastTotal = 0;
    MangaOcrAcceleration? acceleration;

    controller.onListen = () {
      unawaited(() async {
        try {
          if (!isSupportedPlatform) {
            throw StateError(
                'manga OCR is not supported on ${Platform.operatingSystem}');
          }
          final MangaOcrModelStatus status = await modelStatus();
          if (!status.allReady) {
            throw StateError('manga OCR models are not downloaded');
          }
          final MangaOcrModelPaths modelPaths = await _resolveModelPaths();
          if (cancelled) {
            // 订阅在模型检查期间已被取消：任务根本不启动。
            return;
          }
          job = _jobRunner.start(
            MangaOcrVolumeJobRequest(
              imageDirPath: imageDirPath,
              modelPaths: modelPaths,
              volumeTitle: volumeTitle,
            ),
            onProgress: (int done, int total) {
              lastTotal = total;
              if (!controller.isClosed) {
                controller.add(
                  MangaOcrVolumeEvent.page(
                    pagesDone: done,
                    pagesTotal: total,
                    acceleration: acceleration,
                  ),
                );
              }
            },
            onAcceleration: (MangaOcrAcceleration resolved) {
              acceleration = resolved;
            },
          );
          final String mangaJsonPath = await job!.result;
          if (!controller.isClosed) {
            controller.add(MangaOcrVolumeEvent.finished(
              pagesTotal: lastTotal,
              mangaJsonPath: mangaJsonPath,
              acceleration: acceleration,
            ));
          }
        } on OcrCancelledException {
          // 取消订阅即请求中止：静默收流，不当错误。
        } catch (e, stack) {
          if (!controller.isClosed) {
            controller.addError(e, stack);
          }
        } finally {
          if (!controller.isClosed) {
            await controller.close();
          }
        }
      }());
    };
    controller.onCancel = () {
      cancelled = true;
      job?.cancel();
    };
    return controller.stream;
  }
}
