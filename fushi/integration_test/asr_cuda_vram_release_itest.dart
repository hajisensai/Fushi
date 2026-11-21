/// CUDA 转录后台 isolate 退出 / 显存不跨轮叠加 / 空闲后归还 CUDA 上下文的真机探针
/// （BUG-3997、BUG-5078）。
///
/// BUG-3997：用过一次 GPU（CUDA）转录后进程显存常驻约 4.4 GB——**报告了，未复现**
/// （实测显存在会话关闭时回落，收尾后约 180 MiB 残留是 CUDA 主上下文，不随轮次增长）。
/// 实测确认的是另一件事：每转录一次漏一个不退出的后台 isolate（上游已改为
/// `Isolate.exit` 收尾）。
///
/// BUG-5078：那约 180 MiB 显存连同约 620 MiB 私有提交其实就是 CUDA 主上下文——
/// cudart 一直 retain 它，进程不退就不还（只卸插件库什么也回不来）。插件现在在最后
/// 一个 CUDA 会话关闭、空闲 `FLUTTER_ONNXRUNTIME_CUDA_IDLE_MS` 后卸库并重置主上下文；
/// 下一个 CUDA 会话再装回来。本探针把延时设短，钉住：空闲后显存回到注册后的基线，
/// 释放之后再转录一轮照常落在 CUDA 上，并再次归还。
///
/// 本测试走生产同一条路：`AsrIsolateTranscription.spawn` + 宿主真 bootstrap
/// （挂 `BackgroundIsolateBinaryMessenger`，method channel 插件后端），CUDA 插件
/// EP 由 `registerCudaRuntime` 注册。连跑两轮转录，每轮后读 DXGI 的**本进程**
/// 显存占用（`QueryVideoMemoryInfo.CurrentUsage`），并给转录 isolate 挂退出监听，
/// 只钉两件事：
///
/// - 转录 isolate 在任务结束后真的退出；
/// - 每轮收尾后显存回到注册后的基线附近，且两轮之间不叠加。
///
/// 输入（环境变量或 dart-define，`tool/run_windows_itest.ps1` 透传父进程环境）：
///   ASR_MODEL_SEED=<含 fp32 全套文件的模型目录>
///   ASR_CUDA_RT_DIR=<CUDA 运行时包目录，含 onnxruntime_providers_cuda.dll>
///   ASR_AUDIO=<音频>（建议 ≥5 分钟真实朗读，显存池才长得起来）
///   ASR_LANG=ja|en（缺省 ja）
///   ASR_MATERIAL_MS=<素材毫秒数>（可选；≥15 分钟触发静态桶全预热）
///   ASR_FP16=0（可选；关 fp16 编码器。缺省与生产同为 fp16）
///   ASR_CANCEL_AFTER_MS=<毫秒>（可选；跑到这么久时按「制作有声书」校对的取消
///     路径请求暂停：收到 paused 即跳出事件流，再 dispose。要比转完整段短，
///     素材用 ≥1 小时的才落得到转录中途）
///   FLUTTER_ONNXRUNTIME_CUDA_IDLE_MS=<毫秒>（必填，≤ 10000；插件空闲释放的延时，
///     只能走进程环境变量）
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart' show RootIsolateToken;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart'
    show probeCuda, registerCudaRuntime;
import 'package:fushi_asr_core/asr_core.dart';
import 'package:integration_test/integration_test.dart';

String _param(String name, {String defaultValue = ''}) {
  final String fromDefine = switch (name) {
    'ASR_MODEL_SEED' => const String.fromEnvironment('ASR_MODEL_SEED'),
    'ASR_CUDA_RT_DIR' => const String.fromEnvironment('ASR_CUDA_RT_DIR'),
    'ASR_AUDIO' => const String.fromEnvironment('ASR_AUDIO'),
    'ASR_LANG' => const String.fromEnvironment('ASR_LANG'),
    'ASR_MATERIAL_MS' => const String.fromEnvironment('ASR_MATERIAL_MS'),
    'ASR_FP16' => const String.fromEnvironment('ASR_FP16'),
    'ASR_CANCEL_AFTER_MS' => const String.fromEnvironment(
      'ASR_CANCEL_AFTER_MS',
    ),
    _ => '',
  };
  if (fromDefine.isNotEmpty) return fromDefine;
  final String? fromEnv = Platform.environment[name];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return defaultValue;
}

void _log(String msg) {
  // ignore: avoid_print
  print('[asr-cuda-vram] $msg');
}

const int _mib = 1024 * 1024;

/// 生产 bootstrap + 把本 isolate 交给测试挂退出监听。
///
/// 顶层函数（跨 isolate 发送）。参数：`[RootIsolateToken?, 目录路径, SendPort]`。
void _probeBootstrap(Object arg) {
  final List<Object?> payload = arg as List<Object?>;
  fushiAsrIsolateBootstrap(payload.sublist(0, 2));
  (payload[2]! as SendPort).send(Isolate.current);
}

OnnxSessionFactory _buildFactory() => buildFushiOnnxFactory();

/// 整卡已用显存（MiB，nvidia-smi）。只作旁证打印：含别的进程，不参与断言；
/// WDDM 下 nvidia-smi 拿不到按进程的数，DXGI 的本进程计数才是断言依据。
Future<String> _gpuUsedMiB() async {
  try {
    final ProcessResult r = await Process.run('nvidia-smi', <String>[
      '--query-gpu=memory.used',
      '--format=csv,noheader,nounits',
    ]);
    return '${r.stdout}'.trim();
  } on Object catch (error) {
    return 'n/a ($error)';
  }
}

/// 本进程私有提交（MiB）。只作旁证打印。
Future<String> _privateMiB() async {
  try {
    final ProcessResult r = await Process.run('powershell', <String>[
      '-NoProfile',
      '-Command',
      '[int]((Get-Process -Id $pid).PrivateMemorySize64 / 1MB)',
    ]);
    return '${r.stdout}'.trim();
  } on Object catch (error) {
    return 'n/a ($error)';
  }
}

/// 本进程还挂着的 CUDA 相关模块（名字 + 映像 MiB）。只作旁证打印。
Future<String> _cudaModules() async {
  try {
    final ProcessResult r = await Process.run('powershell', <String>[
      '-NoProfile',
      '-Command',
      // 本进程 pid 由 Dart 插值进去；PowerShell 里的 `$pid` 是它自己。
      '(Get-Process -Id $pid).Modules | '
          r'Where-Object { $_.ModuleName -match '
          r"'^(cu|nv|onnxruntime_providers)' } | ForEach-Object { "
          r"'{0}:{1}' -f $_.ModuleName, [int]($_.ModuleMemorySize / 1MB) }",
    ]);
    return '${r.stdout}'.trim().split(RegExp(r'\s+')).join(' ');
  } on Object catch (error) {
    return 'n/a ($error)';
  }
}

Future<int> _processVramBytes() async {
  final OrtDeviceMemoryInfo? info = await OnnxRuntime().getDeviceMemoryInfo();
  if (info == null) throw StateError('DXGI 显存查询不可用');
  return info.currentUsage;
}

Future<({int afterBytes, int peakBytes, bool isolateExited})> _round({
  required int index,
  required AsrModelStore store,
  required AsrLanguage language,
  required String audio,
}) async {
  final Directory jobDir = await Directory.systemTemp.createTemp(
    'fushi_asr_vram_$index',
  );
  final ReceivePort isolates = ReceivePort();
  final ReceivePort exits = ReceivePort();
  final Completer<void> exited = Completer<void>();
  exits.listen((_) {
    if (!exited.isCompleted) exited.complete();
  });
  isolates.listen((Object? message) {
    (message! as Isolate).addOnExitListener(exits.sendPort);
  });
  int peak = 0;
  bool isolateExited = false;
  // 串行采样：上一次查询回来才排下一次，不重叠；采样出错收进 Future，
  // 由 finally 里 await 抛出，不变成游离的未处理异步错误。
  bool stopSampling = false;
  Future<void> sampleLoop() async {
    while (!stopSampling) {
      final int now = await _processVramBytes();
      if (now > peak) peak = now;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  final Future<void> sampler = sampleLoop();
  try {
    final Stopwatch sw = Stopwatch()..start();
    final AsrIsolateTranscription running = await AsrIsolateTranscription.spawn(
      AsrIsolateJobSpec(
        storeDirPath: store.dir.path,
        pack: store.pack,
        language: language,
        variant: AsrEncoderVariant.fp32,
        useFp16Encoder: _param('ASR_FP16') != '0',
        preference: AsrAccelerationPreference.cuda,
        audioPaths: <String>[audio],
        jobDirPath: jobDir.path,
        chunkSeconds: 300,
        audioProfile: AsrAudioProfile.cleanSpeech,
        // 素材总时长：≥15 分钟时引擎全预热静态桶（生产里由服务层 ffprobe 探出来
        // 传进来），显存峰值才到整本转录的量级。
        materialMs: int.tryParse(_param('ASR_MATERIAL_MS')),
      ),
      pcm: FfmpegAsrPcmSource(),
      backend: AsrIsolateBackend(
        buildFactory: _buildFactory,
        bootstrap: _probeBootstrap,
        bootstrapArg: <Object?>[
          RootIsolateToken.instance,
          '',
          isolates.sendPort,
        ],
      ),
    );
    _log(
      'round $index loaded: ${running.encoderResolution} '
      'gpu=${await _gpuUsedMiB()} MiB',
    );
    expect(
      running.encoderResolution.effective,
      OnnxExecutionProvider.cuda,
      reason: '本探针只量 CUDA；没落到 CUDA 说明注册或环境不对',
    );
    final int? cancelAfterMs = int.tryParse(_param('ASR_CANCEL_AFTER_MS'));
    Timer? cancelTimer;
    if (cancelAfterMs != null) {
      cancelTimer = Timer(Duration(milliseconds: cancelAfterMs), () {
        _log('round $index cancel at ${sw.elapsedMilliseconds}ms');
        running.requestPause();
      });
    }
    AsrTranscribeFinishedEvent? finished;
    bool paused = false;
    try {
      await for (final AsrTranscribeEvent e in running.run()) {
        if (e is AsrTranscribeFinishedEvent) finished = e;
        // 与 tts_render_runner `_transcribe` 同形：paused 一到就跳出事件流。
        if (e is AsrTranscribePausedEvent) {
          paused = true;
          break;
        }
      }
    } finally {
      cancelTimer?.cancel();
      await running.dispose();
    }
    if (cancelAfterMs == null) {
      expect(finished, isNotNull, reason: '第 $index 轮没有正常跑完');
    }
    _log(
      'round $index ended: cues=${finished?.result.cueCount} paused=$paused '
      'wall=${sw.elapsedMilliseconds}ms private=${await _privateMiB()} MiB',
    );
    isolateExited = await exited.future
        .then((_) => true)
        .timeout(const Duration(seconds: 30), onTimeout: () => false);
    _log('round $index isolate exited=$isolateExited');
  } finally {
    stopSampling = true;
    await sampler;
    isolates.close();
    exits.close();
    await jobDir.delete(recursive: true);
  }
  final int after = await _processVramBytes();
  return (afterBytes: after, peakBytes: peak, isolateExited: isolateExited);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CUDA 转录两轮后显存回到基线、isolate 退出', (WidgetTester tester) async {
    final String seed = _param('ASR_MODEL_SEED');
    final String cudaDir = _param('ASR_CUDA_RT_DIR');
    final String audio = _param('ASR_AUDIO');
    expect(seed, isNotEmpty, reason: '需要 ASR_MODEL_SEED');
    expect(cudaDir, isNotEmpty, reason: '需要 ASR_CUDA_RT_DIR');
    expect(File(audio).existsSync(), isTrue, reason: '音频不存在：$audio');
    final AsrLanguage language =
        AsrLanguage.fromTag(_param('ASR_LANG', defaultValue: 'ja')) ??
        AsrLanguage.japanese;
    final AsrModelStore store = AsrModelStore(
      Directory(seed),
      asrModelPackFor(language),
    );
    expect(store.isReady(AsrEncoderVariant.fp32), isTrue);

    await tester.runAsync(() async {
      // 前置条件：DXGI 本进程显存查询必须可用，否则本探针什么也量不了。
      expect(
        await OnnxRuntime().getDeviceMemoryInfo(),
        isNotNull,
        reason: '前置条件不满足：DXGI 显存查询不可用（仅 Windows + DXGI 适配器）',
      );
      _log('probe=${await probeCuda()}');
      final int beforeRegister = await _processVramBytes();
      _log('private before register=${await _privateMiB()} MiB');
      _log('register=${await registerCudaRuntime(cudaDir)}');
      final int baseline = await _processVramBytes();
      _log('private after register=${await _privateMiB()} MiB');
      _log(
        'vram before register=${beforeRegister ~/ _mib} MiB '
        'baseline=${baseline ~/ _mib} MiB gpu=${await _gpuUsedMiB()} MiB',
      );

      final ({int afterBytes, int peakBytes, bool isolateExited}) first =
          await _round(
            index: 1,
            store: store,
            language: language,
            audio: audio,
          );
      _log(
        'round 1 peak=${first.peakBytes ~/ _mib} MiB '
        'after=${first.afterBytes ~/ _mib} MiB gpu=${await _gpuUsedMiB()} MiB',
      );
      final ({int afterBytes, int peakBytes, bool isolateExited}) second =
          await _round(
            index: 2,
            store: store,
            language: language,
            audio: audio,
          );
      _log(
        'round 2 peak=${second.peakBytes ~/ _mib} MiB '
        'after=${second.afterBytes ~/ _mib} MiB gpu=${await _gpuUsedMiB()} MiB',
      );
      _log('modules before idle release: ${await _cudaModules()}');

      final int idleMs =
          int.tryParse(
            Platform.environment['FLUTTER_ONNXRUNTIME_CUDA_IDLE_MS'] ?? '',
          ) ??
          -1;
      expect(
        idleMs > 0 && idleMs <= 10000,
        isTrue,
        reason: '需要 FLUTTER_ONNXRUNTIME_CUDA_IDLE_MS=1..10000（插件空闲释放延时）',
      );
      final Duration settle = Duration(milliseconds: idleMs + 5000);

      // 空闲释放：最后一个 CUDA 会话关掉、过了延时，插件自己卸库 + 重置主上下文。
      await Future<void>.delayed(settle);
      final int idle2 = await _processVramBytes();
      _log(
        'idle after round 2: vram=${idle2 ~/ _mib} MiB '
        'private=${await _privateMiB()} MiB gpu=${await _gpuUsedMiB()} MiB',
      );
      _log('modules after idle: ${await _cudaModules()}');

      // 释放之后：下一个 CUDA 会话把库装回来，照常跑在 CUDA 上，空闲后再归还。
      final ({int afterBytes, int peakBytes, bool isolateExited}) third =
          await _round(
            index: 3,
            store: store,
            language: language,
            audio: audio,
          );
      _log(
        'round 3 peak=${third.peakBytes ~/ _mib} MiB '
        'after=${third.afterBytes ~/ _mib} MiB private=${await _privateMiB()} MiB',
      );
      await Future<void>.delayed(settle);
      final int idle3 = await _processVramBytes();
      _log(
        'idle after round 3: vram=${idle3 ~/ _mib} MiB '
        'private=${await _privateMiB()} MiB gpu=${await _gpuUsedMiB()} MiB',
      );
      // 已经释放过：手动再调一次是空操作，不报错。
      final Map<String, dynamic>? again = await OnnxRuntime()
          .releaseCudaRuntime();
      _log('release again=$again');

      // 先量完再断言：任何一条红都要带着完整的显存数字。
      expect(first.isolateExited, isTrue, reason: '第 1 轮转录 isolate 没有退出');
      expect(second.isolateExited, isTrue, reason: '第 2 轮转录 isolate 没有退出');
      expect(third.isolateExited, isTrue, reason: '第 3 轮转录 isolate 没有退出');
      // 转录期间显存确实涨上去过，否则这个探针什么也没量到。
      expect(first.peakBytes - baseline, greaterThan(512 * _mib));
      expect(third.peakBytes - baseline, greaterThan(512 * _mib));
      // 会话关闭当下回到基线附近（留 256 MiB 给尚未释放的 CUDA 主上下文）。
      expect(first.afterBytes - baseline, lessThan(256 * _mib));
      expect(second.afterBytes - baseline, lessThan(256 * _mib));
      // 两轮之间不叠加。
      expect(
        (second.afterBytes - first.afterBytes).abs(),
        lessThan(128 * _mib),
      );
      // 空闲释放后回到注册前的基线（主上下文已重置；留 32 MiB 驱动零头）。
      expect(
        idle2 - baseline,
        lessThan(32 * _mib),
        reason: '空闲 ${settle.inSeconds}s 后 CUDA 主上下文没有归还',
      );
      expect(
        idle3 - baseline,
        lessThan(32 * _mib),
        reason: '释放后重新装载的那一轮，空闲后没有再次归还',
      );
      expect(again?['released'], isFalse);
      expect(again?['openCudaSessions'], 0);
    });
  }, timeout: const Timeout(Duration(minutes: 20)));
}
