/// 服务端对引擎装配点的一次性接线（与 app 的 `installEngineHostBindings()` 对偶）。
library;

import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_asr_onnx_ffi/asr_onnx_ffi.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/asr/fushi_asr_ffmpeg_backend.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/native_libs.dart';
import 'package:fushi_server/src/ocr_session_factory.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';

void installServerHostBindings({
  required ServerConfig config,
  required ServerPaths paths,
  required ServerLog log,
}) {
  engineLog = log;
  fushiDebugPrint = (String? message, {int? wrapWidth}) => log.debug(message);
  enginePaths = paths;
  // ffmpeg / ffprobe：配置文件路径装进引擎的显式覆盖（优先于 FUSHI_FFMPEG 与 PATH，
  // 语义同环境变量覆盖：不做捆绑回退、跑不起来如实抛）。必须在首个
  // resolveFfmpegBackend() 之前装——后端选择是进程级单例。
  ffmpegPathOverride = config.ffmpegPath;
  ffprobePathOverride = config.ffprobePath;
  // 漫画 OCR 整卷任务的后台 isolate：FFI ONNX Runtime 工厂 + ORT 库路径引导。
  ocrSessionFactoryBuilder = buildServerOcrSessionFactory;
  ocrIsolateBootstrap = serverOcrIsolateBootstrap;
  // ORT：配置显式路径 > bundle/lib 随包（CI 放的 CPU 版；换 CUDA 版只需替换文件或
  // 在配置里指到 GPU 版路径）> asr_onnx_ffi 自己的候选（ASR_ONNXRUNTIME_LIB / 同级 / 裸名）。
  final String? ortPath = resolveOrtLibraryPath(config);
  ocrIsolateBootstrapArg = ortPath;
  serverOrtLibraryPath = ortPath;
  // ASR（asr_core）的三个装配点：数据根 / 出站 HTTP / 日志。
  asr.asrSupportRootResolver = () async => paths.support;
  asr.asrHttpClientFactory = ({Duration? connectionTimeout}) =>
      createAppHttpClient(connectionTimeout: connectionTimeout);
  asr.asrLogSink = (String line) => log.debug(line);
}

/// 服务端 ASR 的 ONNX 工厂（顶层函数，供 isolate 后端）。
asr.OnnxSessionFactory buildServerAsrOnnxFactory() => FfiOnnxSessionFactory(
      logName: asr.kAsrLogName,
      libraryPathOverride: serverOrtLibraryPath,
    );

/// 启动前校验配置里的 ffmpeg / ffprobe 路径存在（存在性而已：能不能跑由引擎的
/// 显式覆盖分支如实报错）。返回第一条问题；都没问题返回 null。
Future<String?> validateFfmpeg(ServerConfig config) async {
  for (final (String label, String? configured) in <(String, String?)>[
    ('ffmpeg', config.ffmpegPath),
    ('ffprobe', config.ffprobePath),
  ]) {
    if (configured == null || configured.trim().isEmpty) continue;
    if (!await File(configured.trim()).exists()) {
      return '$label 路径不存在: $configured';
    }
  }
  return null;
}

/// ASR 后台 isolate 引导：把 ORT 库路径带进 isolate（顶层变量不跨 isolate）。
void serverAsrIsolateBootstrap(Object arg) {
  if (arg is String && arg.isNotEmpty) serverOrtLibraryPath = arg;
}

/// 与 app 的 `createAsrTranscriptionService()` 对偶：同一个 asr_core 服务，
/// 后端换成 FFI ORT + 引擎 ffmpeg 转接。
asr.AsrTranscriptionService createServerAsrTranscriptionService() =>
    asr.AsrTranscriptionService(
      backend: asr.AsrIsolateBackend(
        buildFactory: buildServerAsrOnnxFactory,
        bootstrap: serverAsrIsolateBootstrap,
        bootstrapArg: serverOrtLibraryPath ?? '',
      ),
      pcm: asr.FfmpegAsrPcmSource(backend: const FushiAsrFfmpegBackend()),
    );

/// 配置显式路径优先；否则 bundle 布局里找随包的 onnxruntime；都没有返回 null
/// （交给 asr_onnx_ffi 的候选链）。
String? resolveOrtLibraryPath(ServerConfig config) {
  final String? configured = config.ortLibraryPath;
  if (configured != null && configured.trim().isNotEmpty) return configured.trim();
  return locateBundledLibrary(onnxRuntimeLibraryName());
}
