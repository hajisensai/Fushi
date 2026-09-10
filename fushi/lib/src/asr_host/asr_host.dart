/// 把 `fushi_asr_core` 装配到 Hibiki 上的**唯一入口**。
///
/// ASR 的算法层抽成了独立仓库（`fushi_asr_core`，纯 Dart、零 Flutter），它不自带 ONNX
/// 后端、不知道数据根在哪、不知道出站要不要走代理。这些都做成了可替换的装配点，
/// 由宿主装上——本文件就是本仓的那份装配。
///
/// **为什么收在一个文件里**：转录服务有两个生产实例化点（转录弹层与设置页模型区）。
/// 两处各写一遍装配参数，迟早会漏掉一处，表现是「设置页能用、导入弹层不能用」这种
/// 非对称 bug。所以两处都调 [createAsrTranscriptionService]，装配参数只有这一份。
library;

import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, RootIsolateToken;

import 'package:fushi/src/asr_host/asr_model_catalog.dart';
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
/// 做两件事，都**必须**在后台 isolate 里重做一遍（Dart 全局按 isolate 隔离）：
///
/// 1. 挂上 binary messenger：本仓的 ONNX 后端是 method channel 插件，后台 isolate
///    不挂就发不出方法调用——这是整条 ASR 链路上唯一的结构性 Flutter 依赖。
/// 2. 装模型注册表：后台那侧 `asrModelPackFor(spec.language)`
///    （`asr_transcribe_isolate.dart`）读的是**它自己**的全局注册表。不装就是内置
///    表，用户选了别的模型 / 接了自带模型时，这边会按**另一个包**的文件名、架构、
///    blank 记号去装载——而 spec 里的模型目录又是主 isolate 按正确的包算好的，
///    于是变成「目录对、元数据错」的静默错解码，不会报错只会出乱码。
///
/// 同样**必须是顶层函数**（要跨 isolate 边界发送，闭包过不去）。参数是
/// [fushiAsrBackend] 拼的 `[RootIsolateToken?, 模型目录文件路径]`——两样都是可发送值。
void fushiAsrIsolateBootstrap(Object arg) {
  final List<Object?> payload = arg as List<Object?>;
  final Object? token = payload.isEmpty ? null : payload.first;
  // 纯后台 isolate 起的转录拿不到 token（见 [fushiAsrBackend]）：不挂 messenger，
  // 让后端自己炸出可读的错，但注册表照装——它与 method channel 无关。
  if (token is RootIsolateToken) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }
  final Object? catalogPath = payload.length > 1 ? payload[1] : null;
  if (catalogPath is String && catalogPath.isNotEmpty) {
    asr.asrModelRegistry =
        buildAsrModelRegistry(readAsrModelCatalogSync(File(catalogPath)));
  }
}

/// 本仓的后台 isolate 装配。
///
/// `RootIsolateToken.instance` 在纯后台 isolate 里可能为 null（例如从别的 isolate
/// 起转录）；bootstrap 会跳过挂 messenger 那一步，让后端自己去炸出可读的错，而不是
/// 在这里静默继续。
///
/// 传过去的是目录**文件路径**而不是注册表快照：`AsrIsolateBackend` 在
/// [createAsrTranscriptionService] 时构造一次，而服务的生命周期是「弹层打开到关闭」
/// ——用户正是在这中间换模型的。快照会停在打开弹层那一刻，于是后台按**旧包**的
/// 架构 / blankToken / indexType 去装载主 isolate 按**新包**算好的目录，不报错，
/// 只出乱码。路径是常量，内容每次起 isolate 时现读，而 [saveAsrModelCatalog] 是
/// 先落盘再改本进程状态，所以盘上永远不落后于内存。
asr.AsrIsolateBackend fushiAsrBackend() => asr.AsrIsolateBackend(
      buildFactory: buildFushiOnnxFactory,
      bootstrap: fushiAsrIsolateBootstrap,
      bootstrapArg: <Object?>[
        RootIsolateToken.instance,
        _asrModelCatalogPath,
      ],
    );

/// 把 `fushi_asr_core` 的三个装配点接到本仓的实现上。
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

/// 本进程当前的模型目录（用户选择 + 自带包）。
///
/// 与 `asr.asrModelRegistry` 一起是同一件事的两面：目录是可编辑的**源**，注册表是
/// 按它组装出来的**结果**，包里所有 `asrModelPackFor()` 读的是后者。两者只在
/// [applyAsrModelCatalog] 里一起换，不允许分别赋值。
AsrModelCatalog _asrModelCatalog = AsrModelCatalog.empty;

/// 目录文件的绝对路径，解析一次记下来。
///
/// 后台 isolate 的引导要用它（同步读），而数据根解析是异步的、那侧也没装解析器
/// ——所以在主 isolate 这边解析好，路径本身当可发送值带过去。空串 = 还没
/// [loadAsrModelCatalog] 过（弹窗词典等不经 `main()` 的 entry point），此时两侧
/// 都用内置表，仍然一致。
String _asrModelCatalogPath = '';

AsrModelCatalog get asrModelCatalog => _asrModelCatalog;

/// 把一份目录装进本进程：组装注册表 + 记住目录。不落盘（落盘见
/// [saveAsrModelCatalog]），因为启动时读回来的那次不需要再写一遍。
void applyAsrModelCatalog(AsrModelCatalog catalog) {
  _asrModelCatalog = catalog;
  asr.asrModelRegistry = buildAsrModelRegistry(catalog);
}

/// 启动时读回用户的模型目录并装上。
///
/// 在 [installAsrHostBindings] **之后**调用：它要读数据根，而数据根的解析器正是
/// 前者装的。读不出来（文件损坏 / 配错）不能拦住启动——ASR 只是一个功能，整个 app
/// 不该为它起不来；退回内置表并把原因打进日志。
Future<void> loadAsrModelCatalog() async {
  try {
    _asrModelCatalogPath = (await asrModelCatalogFile()).path;
    applyAsrModelCatalog(await readAsrModelCatalog());
  } catch (error) {
    applyAsrModelCatalog(AsrModelCatalog.empty);
    debugPrint('[Fushi] ASR model catalog load failed: $error');
  }
}

/// 改动目录：先落盘再装进本进程。
///
/// 顺序是刻意的——写盘失败时本进程状态保持不变，用户看到的仍是上一份选择，而不是
/// 「界面上换了、下次启动又变回去」这种只有重启才发现的假成功。
Future<void> saveAsrModelCatalog(AsrModelCatalog catalog) async {
  await writeAsrModelCatalog(catalog);
  applyAsrModelCatalog(catalog);
}

/// 建一个装配好的转录服务。两个生产实例化点都调这里。
///
/// [alignGeneratedSubtitles] **默认关**。声学调轴是转录之后**再跑一遍**字符级
/// CTC 模型、把每个 token 的时间重新按声学定位；它是精修不是必需——转录本身
/// 已经产出完整 SRT（时间来自 VAD 段边界与 RNN-T 发射时刻）。
///
/// 打开它要付两笔账：日语包是 transducer 架构，调轴得另下 Omnilingual 1B
/// （int8 约 985 MB），而识别模型才约 150 MB；整段音频还要多跑一遍推理。
///
/// 要重新打开，在调用点传 true 即可。上游已修掉「词表缺字直接抛异常炸掉整趟
/// 转录」与「调轴模型缺失就不让转录」，再打开是安全的，但那 985 MB 与那一倍
/// 推理时间仍旧要付。
asr.AsrTranscriptionService createAsrTranscriptionService({
  bool alignGeneratedSubtitles = false,
}) =>
    asr.AsrTranscriptionService(
      alignGeneratedSubtitles: alignGeneratedSubtitles,
      // 有声书是干净朗读：语音与静默能量差 30 dB 以上、双模态可分，能量门限
      // 够用且免掉每 32 ms 一次 ONNX 前向。混音素材（动画/影视/带 BGM 的音源）
      // 必须换 mixedAudio，见 AsrAudioProfile。
      audioProfile: asr.AsrAudioProfile.cleanSpeech,
      backend: fushiAsrBackend(),
      pcm: asr.FfmpegAsrPcmSource(backend: const FushiAsrFfmpegBackend()),
      openStore: openAsrModelStore,
    );

/// 打开某语言当前模型包的磁盘目录。
///
/// 内置包走包里的默认（`<数据根>/asr_models/<id>`）；**手动接入的本地包用用户
/// 自己那个文件夹**。这一处注入同时决定了四条路径看的是哪个目录：就绪判定
/// （`plan`）、下载（`downloadModel`）、进程内装载，以及后台 isolate 的
/// `spec.storeDirPath`——包里这四处都从 `openStore` 取 store。
///
/// 不注入的话本地模型恒判未就绪：包里的 `AsrModelStore` 只按 `pack.id` 拼目录、
/// 只在那个目录里 stat 文件名，`AsrModelFile.url` 要到下载时才读——于是弹层会
/// 提示「需要下载」，点下去再拿 `file:` URL 去发 HTTP 请求。
Future<asr.AsrModelStore> openAsrModelStore(asr.AsrLanguage language) async {
  final asr.AsrModelPack pack = asr.asrModelPackFor(language);
  final Directory? local = localAsrModelDirectory(pack);
  if (local != null) return asr.AsrModelStore(local, pack);
  return asr.AsrModelStore.open(language);
}

/// 把 `fushi_asr_core` 的 ffmpeg 后端接口转接到本仓的 [host_ffmpeg.FfmpegBackend]。
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
