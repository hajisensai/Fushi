/// 把 `asr_core` 装配到 Hibiki 上的**唯一入口**。
///
/// ASR 的算法层抽成了独立仓库（`asr_core`，纯 Dart、零 Flutter），它不自带 ONNX
/// 后端、不知道数据根在哪、不知道出站要不要走代理。这些都做成了可替换的装配点，
/// 由宿主装上——本文件就是本仓的那份装配。
///
/// **为什么收在一个文件里**：转录服务有两个生产实例化点（转录弹层与设置页模型区）。
/// 两处各写一遍装配参数，迟早会漏掉一处，表现是「设置页能用、导入弹层不能用」这种
/// 非对称 bug。所以两处都调 [createAsrTranscriptionService]，装配参数只有这一份。
library;

import 'package:asr_core/asr_core.dart' as asr;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, RootIsolateToken;

import 'package:fushi/src/onnx/onnx_inference_ort.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/asr/fushi_asr_ffmpeg_backend.dart';
export 'package:fushi_engine/asr/fushi_asr_ffmpeg_backend.dart' show FushiAsrFfmpegBackend;

/// 在后台转录 isolate 里建 ONNX 会话工厂。
///
/// **必须是顶层函数**：它要跨 isolate 边界发送，闭包过不去。
asr.OnnxSessionFactory buildFushiOnnxFactory() =>
    OrtOnnxSessionFactory(logName: asr.kAsrLogName);

/// 后台转录 isolate 的宿主前置初始化。
///
/// 本仓的 ONNX 后端是 method channel 插件，后台 isolate 必须先挂上 binary
/// messenger 才能发方法调用——这是整条 ASR 链路上唯一的结构性 Flutter 依赖，
/// 抽包时做成了钩子。同样**必须是顶层函数**。
void fushiAsrIsolateBootstrap(Object token) {
  BackgroundIsolateBinaryMessenger.ensureInitialized(token as RootIsolateToken);
}

/// 本仓的后台 isolate 装配。
///
/// `RootIsolateToken.instance` 在纯后台 isolate 里可能为 null（例如从别的 isolate
/// 起转录）；此时不传 bootstrap，让后端自己去炸出可读的错，而不是在这里静默继续。
asr.AsrIsolateBackend fushiAsrBackend() => asr.AsrIsolateBackend(
      buildFactory: buildFushiOnnxFactory,
      bootstrap: fushiAsrIsolateBootstrap,
      bootstrapArg: RootIsolateToken.instance,
    );

/// 把 `asr_core` 的三个装配点接到本仓的实现上。
///
/// 在 `main()` 里、`runApp` 之前调用一次。**不要**放进 `AppModel.initialise()`：
/// 弹窗词典与悬浮词典是另外两个 Flutter entry point，走的是
/// `initialiseForDictionaryPopup()`，不经 `initialise()`；装配放在 main 里，
/// 哪个入口都不会漏。
///
/// 注意这三个装配点都是**根 isolate 的全局变量**，`Isolate.spawn` 出去的后台
/// 转录 isolate 一个都带不过去（Dart 全局按 isolate 隔离）。后台那边的装配走
/// [fushiAsrBackend] 经 `AsrIsolateBackend` 送过去，不是靠这里。
void installAsrHostBindings() {
  // 模型缓存与转录任务目录仍落在本应用的数据根下，与抽包前逐字一致。
  asr.asrSupportRootResolver = AppPaths.supportRootDirectory;

  // 模型下载必须经全应用统一的出站装配点（代理策略 + 局域网直连闸门 +
  // 连接超时）。装的是**工厂**不是已建好的 client：代理表要等
  // `primeAppProxy()` 跑完才准，惰性调用才拿得到 prime 之后的结果。
  asr.asrHttpClientFactory = ({Duration? connectionTimeout}) =>
      createAppHttpClient(connectionTimeout: connectionTimeout);

  // 包里默认写 stderr（CLI 场景要把字幕留给 stdout）；app 里走 debugPrint。
  asr.asrLogSink = (String message) => debugPrint(message);
}

/// 建一个装配好的转录服务。两个生产实例化点都调这里。
asr.AsrTranscriptionService createAsrTranscriptionService() =>
    asr.AsrTranscriptionService(
      backend: fushiAsrBackend(),
      pcm: asr.FfmpegAsrPcmSource(backend: const FushiAsrFfmpegBackend()),
    );


/// 本平台是否具备设备端转录能力（= 本地 ONNX Runtime 随包）。
///
/// 转录入口的显示与否由它决定（有声书导入弹层 ×2、设置页、阅读器 chrome）。
/// 抽包前这是 `AsrTranscriptionService.isSupported`，那个 static getter 现在读的是
/// 包里同名的平台闸门——两份实现逐字相同，这里再包一层只为**调用方零改动**。
bool get isAsrSupported => asr.isLocalOnnxRuntimeAvailable;
