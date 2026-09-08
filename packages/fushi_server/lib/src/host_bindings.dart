/// 服务端对引擎装配点的一次性接线（与 app 的 `installEngineHostBindings()` 对偶）。
library;

import 'dart:io';

import 'package:asr_core/asr_core.dart' as asr;
import 'package:asr_onnx_ffi/asr_onnx_ffi.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_server/src/config/server_config.dart';
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
  // ffmpeg：桌面/服务端一律系统 CLI；配置文件的 ffmpeg 路径等价于 FUSHI_FFMPEG 覆盖。
  // 引擎只认环境变量与「可执行文件同目录」，这里没法改进程环境，所以配置路径走
  // 平台后端装配点：返回一个把可执行路径钉死的 CLI 后端。
  ffmpegPlatformBackendProvider = () => const CliFfmpegBackend();
  // 漫画 OCR 整卷任务的后台 isolate：FFI ONNX Runtime 工厂 + ORT 库路径引导。
  ocrSessionFactoryBuilder = buildServerOcrSessionFactory;
  ocrIsolateBootstrap = serverOcrIsolateBootstrap;
  ocrIsolateBootstrapArg = config.ortLibraryPath;
  serverOrtLibraryPath = config.ortLibraryPath;
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

/// 配置里的 ffmpeg 路径 → 进程环境覆盖的等价物：CLI 解析函数认 `FUSHI_FFMPEG`，
/// 这里在启动时把它塞进子进程环境做不到（`Platform.environment` 只读），所以
/// `serve` 命令在启动前校验路径存在并提示用户用环境变量；配置项保留给 WebUI 显示。
Future<String?> validateFfmpeg(ServerConfig config) async {
  final String? configured = config.ffmpegPath;
  if (configured != null && configured.isNotEmpty) {
    if (!await File(configured).exists()) {
      return 'ffmpeg 路径不存在: $configured';
    }
    if ((Platform.environment['FUSHI_FFMPEG'] ?? '').isEmpty) {
      return 'ffmpeg 配置项只做展示；请同时设置环境变量 FUSHI_FFMPEG=$configured';
    }
  }
  return null;
}
