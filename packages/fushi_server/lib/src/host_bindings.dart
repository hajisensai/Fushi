/// 服务端对引擎装配点的一次性接线（与 app 的 `installEngineHostBindings()` 对偶）。
///
/// TODO(srs-ankiconnect): 服务端还没有 SRS 装配（没有「当前 profile」的 SrsDbStore），所以
/// AnkiConnect v6 兼容层（`fushi_engine/srs/ankiconnect/`）目前只在 app 的 Fushi API 上挂。
/// 服务端接 SRS 后，用配置里指定的 SRS profile 构造 `SrsAnkiConnectHandler`，经
/// `SrsAnkiConnectEndpoint.handle` 挂到 Fushi API 根路径（鉴权由端点自己做，不经中间件）。
library;

import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_asr_onnx_ffi/asr_onnx_ffi.dart';
import 'package:fushi_audio/fushi_audio_core.dart' show AudiobookStorage;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/asr/fushi_asr_ffmpeg_backend.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/audio/flac_encoder.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/native_libs.dart';
import 'package:fushi_server/src/ocr_session_factory.dart';
import 'package:fushi_server/src/server_gpu_budget.dart';
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
  // 有声书持久目录 `<documents>/audiobooks/<hash>/`（与库服务的 audioDatabaseRoot 同根）。
  // 不装的话代下载的有声书在对齐落盘时抛 StateError（`AudiobookStorage` 的单一解析点）。
  AudiobookStorage.documentsRootResolver = () async => paths.documents;
  // ffmpeg / ffprobe：配置文件路径装进引擎的显式覆盖（优先于 FUSHI_FFMPEG 与 PATH，
  // 语义同环境变量覆盖：不做捆绑回退、跑不起来如实抛）。必须在首个
  // resolveFfmpegBackend() 之前装——后端选择是进程级单例。
  ffmpegPathOverride = config.ffmpegPath;
  ffprobePathOverride = config.ffprobePath;
  // AIFF 有声书落盘转 FLAC（Android 播放器不认 AIFF）。
  installAudiobookFlacTranscoder();
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
///
/// 外包一层 [ServerGpuBudgetOnnxFactory]：FFI 后端查不到显存预算，不补的话带显存
/// 门槛的包（日语视频 Parakeet）有 N 卡也只会规划成 CPU int8（见 server_gpu_budget.dart）。
asr.OnnxSessionFactory buildServerAsrOnnxFactory() =>
    ServerGpuBudgetOnnxFactory(
      FfiOnnxSessionFactory(
        logName: asr.kAsrLogName,
        libraryPathOverride: serverOrtLibraryPath,
      ),
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
///
/// [audioProfile] 由调用方按素材给：有声书 / 纯音频是干净朗读（默认，能量门限
/// 够用且免掉每 32 ms 一次 ONNX 前向），视频是 `mixedAudio`（Parakeet + 滑窗）。
/// 缺省值与 app 那边一致——同一份算法在两端跑出不同行为比慢一点糟得多。
asr.AsrTranscriptionService createServerAsrTranscriptionService({
  asr.AsrAudioProfile audioProfile = asr.AsrAudioProfile.cleanSpeech,
}) => asr.AsrTranscriptionService(
  audioProfile: audioProfile,
  backend: asr.AsrIsolateBackend(
    buildFactory: buildServerAsrOnnxFactory,
    bootstrap: serverAsrIsolateBootstrap,
    bootstrapArg: serverOrtLibraryPath ?? '',
  ),
  pcm: asr.FfmpegAsrPcmSource(backend: const FushiAsrFfmpegBackend()),
);

/// 视频字幕管线挑识别器的服务端装配（与 app 的 `resolveAppVideoSubtitleRecognizer`
/// 对偶）：ASR 服务工厂是 [createServerAsrTranscriptionService]，子进程走引擎默认的
/// `HelperProcessRegistry`。[mossCliPath] / [mossModelPath] 指向本机已有的
/// audio.cpp CLI 与 GGUF 时跳过下载目录（`subgen --moss-cli/--moss-model`）。
Future<VideoSubtitleRecognizerChoice> resolveServerVideoSubtitleRecognizer({
  required VideoSubtitleSegmenterMode mode,
  MossBackendPreference mossBackend = MossBackendPreference.auto,
  asr.AsrAccelerationPreference preference = asr.AsrAccelerationPreference.auto,
  String? mossCliPath,
  String? mossModelPath,
}) => resolveVideoSubtitleRecognizer(
  mode: mode,
  mossBackend: mossBackend,
  serviceFactory: (asr.AsrAudioProfile profile) =>
      createServerAsrTranscriptionService(audioProfile: profile),
  preference: preference,
  mossCliPath: mossCliPath,
  mossModelPath: mossModelPath,
);

/// 配置显式路径优先；否则 bundle 布局里找随包的 onnxruntime；都没有返回 null
/// （交给 asr_onnx_ffi 的候选链）。
String? resolveOrtLibraryPath(ServerConfig config) {
  final String? configured = config.ortLibraryPath;
  if (configured != null && configured.trim().isNotEmpty) {
    return configured.trim();
  }
  return locateBundledLibrary(onnxRuntimeLibraryName());
}
