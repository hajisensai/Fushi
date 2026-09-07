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

import 'package:fushi/src/media/video/ffmpeg_backend.dart' as host_ffmpeg;
import 'package:fushi/src/onnx/onnx_inference_ort.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/net/app_http.dart';

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

/// 把 `asr_core` 的 ffmpeg 后端接口转接到本仓的 [host_ffmpeg.FfmpegBackend]。
///
/// **五端一律注入，不用包自带的裸 CLI 后端**。包里那份只有 `Process.start`，
/// 用它会丢掉三样只在特定情境才炸的东西：
/// - `HelperProcessRegistry`：退出前杀掉 ffmpeg 子进程（BUG-1708，不杀会在安装
///   更新时锁住安装目录）；
/// - `FUSHI_FFMPEG` / `FUSHI_FFPROBE` 覆盖：集成测试 runner 依赖它；
/// - 捆绑 ffmpeg 损坏时回退系统 PATH 的启发式（BUG-275 / BUG-283）。
///
/// 移动端更直接：Android / iOS 没有 ffmpeg CLI，必须走进程内的 ffmpeg-kit。
///
/// 两侧的 `FfmpegRunResult` 是同源拷贝，但**类型不同**，所以要逐字段转。本仓那份
/// 多出的 `attemptedExecutables` / `fallbackReason` 只进 `failureSummary`，
/// 包里读不到——所以这里把它们拼进 `output` 会破坏 ffprobe 的 JSON 解析，
/// 千万别那么做；丢弃是对的。
class FushiAsrFfmpegBackend implements asr.FfmpegBackend {
  const FushiAsrFfmpegBackend();

  /// 每次取用时解析，不在构造时固化。
  ///
  /// 本仓的 `resolveFfmpegBackend()` 有进程级缓存，而
  /// `setFfmpegBackendForTesting()` 会把它换掉——构造时固化会让测试替换失效。
  host_ffmpeg.FfmpegBackend get _backend => host_ffmpeg.resolveFfmpegBackend();

  @override
  Future<asr.FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      _convert(await _backend.run(args, timeout));

  @override
  Future<asr.FfmpegRunResult> runProbe(
    List<String> args,
    Duration timeout,
  ) async =>
      _convert(await _backend.runProbe(args, timeout));

  /// 逐字段转，不做任何解释。
  ///
  /// 三条契约必须原样穿过去，错一条都很难发现：
  /// - `run` 的 `output` 是 **stderr**、`runProbe` 的是 **stdout**（前者用来认
  ///   「没有 s16le muxer」，后者是 ffprobe 的 JSON）；颠倒了会变成「能转录但
  ///   每次都慢一档」；
  /// - 超时是 `returnCode == null`，**不是**抛 `TimeoutException`；
  /// - 可执行文件缺失是抛 `ProcessException`，**不是**返回失败结果。
  ///   后两条本方法不碰（异常直接穿透、null 原样带过），这里只是把这条纪律写下来。
  static asr.FfmpegRunResult _convert(host_ffmpeg.FfmpegRunResult r) =>
      asr.FfmpegRunResult(
        returnCode: r.returnCode,
        output: r.output,
        executable: r.executable,
        attemptedExecutables: r.attemptedExecutables,
        fallbackReason: r.fallbackReason,
      );
}

/// 本平台是否具备设备端转录能力（= 本地 ONNX Runtime 随包）。
///
/// 转录入口的显示与否由它决定（有声书导入弹层 ×2、设置页、阅读器 chrome）。
/// 抽包前这是 `AsrTranscriptionService.isSupported`，那个 static getter 现在读的是
/// 包里同名的平台闸门——两份实现逐字相同，这里再包一层只为**调用方零改动**。
bool get isAsrSupported => asr.isLocalOnnxRuntimeAvailable;
