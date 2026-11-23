/// Irodori 批处理 worker（设计 §5）：离线制作漫画 / 小说有声书时，用一个本机 Python
/// 进程一次加载 v4-Large 底模，按「LoRA → 参考音频组」顺序逐句合成，逐句回报。
///
/// 不走 OpenAI 兼容服务端的原因：钉的服务端请求体只有 `voice` + `caption`，不能逐句指定
/// adapter 与多段参考音频；而且逐句 HTTP、逐句重算参考音频。只在桌面端可用（v4-Large
/// 要大显存独显），其它设备播放成品。
///
/// ## 给制作流水线的 API
///
/// ```dart
/// final IrodoriBatchWorker worker = ttsServices.localIrodori.batchWorker;
/// final List<IrodoriBatchItem> items = <IrodoriBatchItem>[
///   for (final line in lines)
///     IrodoriBatchItem.forPack(
///       id: line.lineId,                       // 稳定 id（页码 + 块下标 + 片段）
///       text: line.say ?? line.text,
///       pack: resolved.pack, group: resolved.group,
///       seed: script.seed,                     // 整部作品一个种子
///       outputPath: manifest.audioPathOf(line),
///     ),
/// ];
/// final IrodoriBatchResult r = await worker.run(
///   IrodoriBatchJob(id: jobId, items: items),
///   onLine: (IrodoriBatchLineResult l) => progress(l),
///   cancel: token,
/// );
/// // r.lines[id].ok == false 的句子：按「未配音」处理（占位静音 + 记进
/// // CastVoicingLedger），整卷不失败；r.cancelled 时没回报的句子保持未合成。
/// ```
///
/// - 同一时刻只跑一个任务（显存只够一个模型实例），多次 [IrodoriBatchWorker.run] 排队；
/// - [IrodoriBatchItem.forPack] 自动套用短句规则（[irodoriManualSeconds]），调用方给了
///   `seconds` 就以调用方为准；
/// - 进程中途退出：本任务没回报的句子全部记为失败（`worker_exited`），worker 进入
///   failed，下次 [IrodoriBatchWorker.run] 重新拉起。
///
/// ## 协议（JSON Lines）
///
/// stdin 每行一个请求：`{"op":"synthesize","job":..,"items":[..]}`、
/// `{"op":"cancel","job":..}`、`{"op":"shutdown"}`。stdout 里以 [kIrodoriBatchEventPrefix]
/// 开头的行是事件（`loading` / `ready` / `line` / `job_done` / `fatal`），其余是日志。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_notifier.dart';
import 'package:fushi_engine/tts/local/irodori_batch_worker_script.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack.dart';
import 'package:fushi_engine/tts/local/local_service_process.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';

/// 一句合成请求。
class IrodoriBatchItem {
  const IrodoriBatchItem({
    required this.id,
    required this.text,
    required this.refs,
    required this.outputPath,
    this.adapterDir,
    this.seconds,
    this.seed = 0,
    this.steps = kIrodoriDefaultSteps,
    this.cfgText = kIrodoriDefaultCfgText,
    this.cfgSpeaker = kIrodoriDefaultCfgSpeaker,
    this.caption,
    this.durationScale,
  });

  /// 用声音包 [pack] 的 [group] 组合成 [text]。[seed] 为 null 用包的默认种子；
  /// [seconds] 为 null 时按短句规则（不挂 LoRA、20 字以内）给定时长，否则交给时长预测。
  factory IrodoriBatchItem.forPack({
    required String id,
    required String text,
    required IrodoriVoicePack pack,
    required IrodoriRefGroup group,
    required String outputPath,
    int? seed,
    double? seconds,
  }) => IrodoriBatchItem(
    id: id,
    text: text,
    refs: group.files,
    outputPath: outputPath,
    adapterDir: pack.adapterDir,
    seconds: seconds ?? irodoriManualSeconds(text, lora: pack.usesLora),
    seed: seed ?? pack.sampling.seed,
    steps: pack.sampling.steps,
    cfgText: pack.sampling.cfgText,
    cfgSpeaker: pack.sampling.cfgSpeaker,
  );

  final String id;
  final String text;

  /// 参考音频（按顺序）；空 = 无参考。
  final List<String> refs;

  /// 输出 wav 的路径（worker 先写临时文件再改名，成功才出现）。
  final String outputPath;
  final String? adapterDir;

  /// 给定时长（秒）；null = 时长预测。
  final double? seconds;
  final int seed;
  final int steps;
  final double cfgText;
  final double cfgSpeaker;

  /// Voice Design caption（这一句的情绪 / 语气指令）；null = 不带。v4 系列底模的
  /// caption 与参考音频同时生效（参考定音色，caption 定情绪 / 风格）。
  final String? caption;

  /// 预测时长的倍率（`SamplingRequest.duration_scale`，>1 更慢）；null = 1.0。只在
  /// [seconds] 为 null（走时长预测）时有意义。
  final double? durationScale;

  /// 「参考音频组」键：adapter + 参考音频。同键的句子连在一起合成。
  String get groupKey => '${adapterDir ?? ''}\u0000${refs.join('\u0000')}';

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'text': text,
    'refs': refs,
    'adapter': adapterDir,
    'seconds': seconds,
    'seed': seed,
    'steps': steps,
    'cfg_text': cfgText,
    'cfg_speaker': cfgSpeaker,
    if (caption != null) 'caption': caption,
    if (durationScale != null) 'duration_scale': durationScale,
    'out': outputPath,
  };
}

/// 一批句子。
class IrodoriBatchJob {
  const IrodoriBatchJob({required this.id, required this.items});

  final String id;
  final List<IrodoriBatchItem> items;
}

/// 合成顺序（纯函数）：挂 LoRA 的在前、同一参考音频组连在一起（adapter 只切一次、
/// 参考音频组内连续），组内保持原顺序。与参考实现的排序同一规则。
List<IrodoriBatchItem> irodoriBatchOrder(List<IrodoriBatchItem> items) {
  final LinkedHashMap<String, List<IrodoriBatchItem>> byGroup =
      LinkedHashMap<String, List<IrodoriBatchItem>>();
  for (final IrodoriBatchItem item in items) {
    byGroup.putIfAbsent(item.groupKey, () => <IrodoriBatchItem>[]).add(item);
  }
  final List<List<IrodoriBatchItem>> groups = byGroup.values.toList();
  // 稳定排序：LoRA 组在前，其余保持首次出现的顺序。
  final List<List<IrodoriBatchItem>> lora = <List<IrodoriBatchItem>>[
    for (final List<IrodoriBatchItem> g in groups)
      if (g.first.adapterDir != null) g,
  ];
  final List<List<IrodoriBatchItem>> base = <List<IrodoriBatchItem>>[
    for (final List<IrodoriBatchItem> g in groups)
      if (g.first.adapterDir == null) g,
  ];
  return <IrodoriBatchItem>[
    for (final List<IrodoriBatchItem> g in lora) ...g,
    for (final List<IrodoriBatchItem> g in base) ...g,
  ];
}

/// 合成请求行（不含换行）。
String encodeIrodoriSynthesizeRequest(IrodoriBatchJob job) => jsonEncode(
  <String, Object?>{
    'op': 'synthesize',
    'job': job.id,
    'items': <Object?>[
      for (final IrodoriBatchItem i in irodoriBatchOrder(job.items)) i.toJson(),
    ],
  },
);

String encodeIrodoriCancelRequest(String jobId) =>
    jsonEncode(<String, Object?>{'op': 'cancel', 'job': jobId});

const String kIrodoriShutdownRequest = '{"op":"shutdown"}';

/// worker 事件。
sealed class IrodoriWorkerEvent {
  const IrodoriWorkerEvent();
}

class IrodoriWorkerLoading extends IrodoriWorkerEvent {
  const IrodoriWorkerLoading(this.stage);

  /// `import` / `model`。
  final String stage;
}

class IrodoriWorkerReady extends IrodoriWorkerEvent {
  const IrodoriWorkerReady({required this.protocol, required this.device});

  final int protocol;

  /// `cuda` / `mps` / `cpu`。
  final String device;
}

class IrodoriWorkerLine extends IrodoriWorkerEvent {
  const IrodoriWorkerLine({
    required this.job,
    required this.result,
    required this.index,
    required this.total,
  });

  final String job;
  final IrodoriBatchLineResult result;

  /// 本任务里的第几句（按合成顺序，从 0 起）与总句数。
  final int index;
  final int total;
}

class IrodoriWorkerJobDone extends IrodoriWorkerEvent {
  const IrodoriWorkerJobDone({
    required this.job,
    required this.ok,
    required this.failed,
    required this.cancelled,
  });

  final String job;
  final int ok;
  final int failed;
  final bool cancelled;
}

class IrodoriWorkerFatal extends IrodoriWorkerEvent {
  const IrodoriWorkerFatal(this.error);

  final String error;
}

/// 一句的结果。
class IrodoriBatchLineResult {
  const IrodoriBatchLineResult({
    required this.id,
    required this.ok,
    this.outputPath,
    this.durationMs,
    this.error,
  });

  final String id;
  final bool ok;
  final String? outputPath;
  final int? durationMs;

  /// 失败原因（技术细节，进日志；UI 只说「未配音」）。
  final String? error;
}

/// 解析 stdout 一行；不是协议事件（日志）或事件损坏返回 null。
IrodoriWorkerEvent? parseIrodoriWorkerLine(String line) {
  if (!line.startsWith(kIrodoriBatchEventPrefix)) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(line.substring(kIrodoriBatchEventPrefix.length));
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final Map<Object?, Object?> raw = decoded;
  String? str(String key) => raw[key] is String ? raw[key] as String : null;
  int? integer(String key) => raw[key] is int ? raw[key] as int : null;
  switch (raw['event']) {
    case 'loading':
      return IrodoriWorkerLoading(str('stage') ?? '');
    case 'ready':
      final int? protocol = integer('protocol');
      if (protocol == null) return null;
      return IrodoriWorkerReady(
        protocol: protocol,
        device: str('device') ?? '',
      );
    case 'line':
      final String? job = str('job');
      final String? id = str('id');
      final Object? ok = raw['ok'];
      if (job == null || id == null || ok is! bool) return null;
      return IrodoriWorkerLine(
        job: job,
        index: integer('index') ?? 0,
        total: integer('total') ?? 0,
        result: IrodoriBatchLineResult(
          id: id,
          ok: ok,
          outputPath: ok ? str('out') : null,
          durationMs: ok ? integer('duration_ms') : null,
          error: ok ? null : (str('error') ?? 'unknown'),
        ),
      );
    case 'job_done':
      final String? job = str('job');
      if (job == null) return null;
      return IrodoriWorkerJobDone(
        job: job,
        ok: integer('ok') ?? 0,
        failed: integer('failed') ?? 0,
        cancelled: raw['cancelled'] == true,
      );
    case 'fatal':
      return IrodoriWorkerFatal(str('error') ?? 'unknown');
  }
  return null;
}

/// 一批的结果。
class IrodoriBatchResult {
  const IrodoriBatchResult({
    required this.lines,
    this.cancelled = false,
    this.failure,
  });

  /// 有回报的句子（id → 结果）。取消时没轮到的句子不在里面。
  final Map<String, IrodoriBatchLineResult> lines;
  final bool cancelled;

  /// worker 层面的失败（起不来 / 中途退出）；null = 正常跑完（个别句子仍可能失败）。
  final IrodoriBatchFailure? failure;

  Iterable<IrodoriBatchLineResult> get failedLines =>
      lines.values.where((IrodoriBatchLineResult l) => !l.ok);
}

/// worker 状态。
enum IrodoriBatchPhase { stopped, starting, ready, failed }

/// worker 层面的失败原因。
enum IrodoriBatchFailure {
  /// 没装环境 / 没下 v4-Large / 平台不支持。
  notInstalled,

  /// 进程起不来。
  spawnFailed,

  /// 加载模型时报错（缺依赖、显存 / 内存不够……看日志尾）。
  loadFailed,

  /// 脚本与 app 的协议版本不一致。
  protocolMismatch,

  /// 等了 [IrodoriBatchWorker.readyTimeout] 还没加载完。
  timeout,

  /// 进程中途退出。
  exited,
}

/// worker 进程的启动参数。
class IrodoriBatchLaunch {
  const IrodoriBatchLaunch({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    this.environment = const <String, String>{},
  });

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;
}

Future<Process> _registrySpawn(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) => HelperProcessRegistry.instance.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
);

/// worker 进程托管：拉起、等模型加载完、按任务排队合成、停止。进程经
/// [HelperProcessRegistry] 启动，app 退出时统一终止。
class IrodoriBatchWorker extends EngineChangeNotifier {
  IrodoriBatchWorker({
    required Future<IrodoriBatchLaunch?> Function() launch,
    LocalServiceSpawn? spawn,
    this.readyTimeout = const Duration(minutes: 20),
    this.stopTimeout = const Duration(seconds: 10),
  }) : _launch = launch,
       _spawn = spawn ?? _registrySpawn;

  final Future<IrodoriBatchLaunch?> Function() _launch;
  final LocalServiceSpawn _spawn;

  /// 首次加载要 import torch 并读 13 GB 底模；慢盘上十几分钟也正常。
  final Duration readyTimeout;
  final Duration stopTimeout;

  IrodoriBatchPhase phase = IrodoriBatchPhase.stopped;
  IrodoriBatchFailure? failure;

  /// 加载阶段（`import` / `model`），UI 显示用。
  String? loadingStage;

  /// 模型跑在哪（`cuda` / `mps` / `cpu`）。
  String? device;

  /// 当前任务的进度。
  int done = 0;
  int total = 0;

  static const int logTailLines = 300;
  final List<String> _log = <String>[];
  List<String> get logTail => List<String>.unmodifiable(_log);

  Process? _process;
  Completer<bool>? _ready;
  _RunningJob? _job;
  Future<void> _queue = Future<void>.value();

  /// 已经 [run] 进来、还没出结果的任务数（含排队的）。
  int _pending = 0;

  /// 进行中的 [stop]（等旧进程退出、释放显存）。新的 [start] 先等它，免得新旧两个
  /// 进程同时占着显存。
  Future<void>? _stopping;

  /// 有任务在跑或在排队。排队的也算：它在 `await start()` 那一拍还没设 [_job]，
  /// 这时要是被当成空闲停掉（服务端抢显存），这批句子就会白白记成 `worker_exited`。
  bool get isBusy => _pending > 0;

  void _set(IrodoriBatchPhase next, [IrodoriBatchFailure? why]) {
    phase = next;
    failure = why;
    notifyListeners();
  }

  void _appendLog(String line) {
    _log.add(line);
    if (_log.length > logTailLines) {
      _log.removeRange(0, _log.length - logTailLines);
    }
  }

  /// 拉起并等模型加载完。已就绪直接返回 true；失败原因在 [failure]。
  Future<bool> start() {
    final Completer<bool>? pending = _ready;
    if (pending != null) return pending.future;
    if (phase == IrodoriBatchPhase.ready && _process != null) {
      return Future<bool>.value(true);
    }
    final Completer<bool> ready = Completer<bool>();
    _ready = ready;
    unawaited(_start(ready));
    return ready.future;
  }

  Future<void> _start(Completer<bool> ready) async {
    void finish(bool ok, [IrodoriBatchFailure? why]) {
      if (ready.isCompleted) return;
      _ready = null;
      _set(ok ? IrodoriBatchPhase.ready : IrodoriBatchPhase.failed, why);
      ready.complete(ok);
    }

    _log.clear();
    loadingStage = null;
    device = null;
    _set(IrodoriBatchPhase.starting);
    final Future<void>? stopping = _stopping;
    if (stopping != null) await stopping;
    final IrodoriBatchLaunch? spec = await _launch();
    if (spec == null || !File(spec.executable).existsSync()) {
      finish(false, IrodoriBatchFailure.notInstalled);
      return;
    }
    final Process process;
    try {
      process = await _spawn(
        spec.executable,
        spec.arguments,
        workingDirectory: spec.workingDirectory,
        environment: <String, String>{
          'PYTHONUNBUFFERED': '1',
          'PYTHONIOENCODING': 'utf-8',
          ...spec.environment,
        },
      );
    } on ProcessException catch (e) {
      _appendLog(e.message);
      finish(false, IrodoriBatchFailure.spawnFailed);
      return;
    }
    _process = process;
    // 进程退出后的写入错误只会从 done 报出来；没人接会变成未捕获异常。
    unawaited(process.stdin.done.catchError((Object _) {}));
    final Timer timer = Timer(readyTimeout, () {
      if (ready.isCompleted) return;
      _appendLog('[worker did not finish loading in $readyTimeout]');
      process.kill();
      finish(false, IrodoriBatchFailure.timeout);
    });
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((String line) {
          final IrodoriWorkerEvent? event = parseIrodoriWorkerLine(line);
          if (event == null) {
            _appendLog(line);
            return;
          }
          switch (event) {
            case IrodoriWorkerLoading(:final String stage):
              loadingStage = stage;
              notifyListeners();
            case IrodoriWorkerReady(
              :final int protocol,
              device: final String d,
            ):
              timer.cancel();
              if (protocol != kIrodoriBatchProtocol) {
                _appendLog(
                  '[worker protocol $protocol, app expects '
                  '$kIrodoriBatchProtocol]',
                );
                process.kill();
                finish(false, IrodoriBatchFailure.protocolMismatch);
                return;
              }
              device = d;
              finish(true);
            case IrodoriWorkerFatal(:final String error):
              timer.cancel();
              _appendLog('[fatal] $error');
              finish(false, IrodoriBatchFailure.loadFailed);
            case IrodoriWorkerLine():
              _job?.onLine(event);
              done = event.index + 1;
              total = event.total;
              notifyListeners();
            case IrodoriWorkerJobDone():
              _job?.onDone(event);
          }
        });
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_appendLog);
    unawaited(
      process.exitCode.then((int code) {
        timer.cancel();
        if (!identical(_process, process)) return;
        _process = null;
        _appendLog('[worker exited with code $code]');
        _job?.onExit();
        if (!ready.isCompleted) {
          finish(false, IrodoriBatchFailure.loadFailed);
        } else if (phase == IrodoriBatchPhase.ready) {
          _set(IrodoriBatchPhase.failed, IrodoriBatchFailure.exited);
        }
      }),
    );
  }

  /// 合成一批（排队，同一时刻只跑一个）。worker 没起会先拉起；起不来时返回带
  /// [IrodoriBatchResult.failure] 的空结果。每句结果经 [onLine] 实时回报。
  Future<IrodoriBatchResult> run(
    IrodoriBatchJob job, {
    void Function(IrodoriBatchLineResult line)? onLine,
    TtsCancelToken? cancel,
  }) {
    final Completer<IrodoriBatchResult> result =
        Completer<IrodoriBatchResult>();
    _pending++;
    _queue = _queue.then((_) async {
      try {
        result.complete(await _run(job, onLine: onLine, cancel: cancel));
      } on Object catch (e, st) {
        result.completeError(e, st);
      } finally {
        _pending--;
        notifyListeners();
      }
    });
    return result.future;
  }

  Future<IrodoriBatchResult> _run(
    IrodoriBatchJob job, {
    void Function(IrodoriBatchLineResult line)? onLine,
    TtsCancelToken? cancel,
  }) async {
    if (cancel?.isCancelled ?? false) {
      return const IrodoriBatchResult(
        lines: <String, IrodoriBatchLineResult>{},
        cancelled: true,
      );
    }
    if (job.items.isEmpty) {
      return const IrodoriBatchResult(
        lines: <String, IrodoriBatchLineResult>{},
      );
    }
    if (!await start()) {
      return IrodoriBatchResult(
        lines: const <String, IrodoriBatchLineResult>{},
        failure: failure ?? IrodoriBatchFailure.loadFailed,
      );
    }
    final Process? process = _process;
    if (process == null) {
      return const IrodoriBatchResult(
        lines: <String, IrodoriBatchLineResult>{},
        failure: IrodoriBatchFailure.exited,
      );
    }
    final _RunningJob running = _RunningJob(job, onLine);
    _job = running;
    done = 0;
    total = job.items.length;
    notifyListeners();
    final void Function()? unregister = cancel?.onCancel(
      () => _send(process, encodeIrodoriCancelRequest(job.id)),
    );
    if (!_send(process, encodeIrodoriSynthesizeRequest(job))) running.onExit();
    final IrodoriBatchResult r = await running.result.future;
    unregister?.call();
    _job = null;
    notifyListeners();
    return r;
  }

  /// 写一行请求。不 await flush：取消请求可能在合成请求还在 flush 时到来，而 IOSink
  /// 在 flush 期间拒绝写入；Process 的 stdin 自己会尽快把数据送出去。写失败（进程已
  /// 退出）返回 false，收尾交给退出处理。
  bool _send(Process process, String line) {
    try {
      process.stdin.writeln(line);
      return true;
    } on Object catch (e) {
      _appendLog('[failed to write to the worker: $e]');
      return false;
    }
  }

  /// 停 worker（先请它自己退出，超时再杀）。进行中的任务按 [IrodoriBatchFailure.exited]
  /// 收尾。
  Future<void> stop() async {
    final Process? process = _process;
    _set(IrodoriBatchPhase.stopped);
    if (process == null) return;
    final Future<void> stopping = _awaitExit(process);
    _stopping = stopping;
    try {
      await stopping;
    } finally {
      if (identical(_stopping, stopping)) _stopping = null;
    }
  }

  Future<void> _awaitExit(Process process) async {
    _send(process, kIrodoriShutdownRequest);
    try {
      await process.exitCode.timeout(stopTimeout);
    } on TimeoutException {
      process.kill();
      await process.exitCode;
    }
  }

  @override
  void dispose() {
    _process?.kill();
    super.dispose();
  }
}

class _RunningJob {
  _RunningJob(this.job, this.onLineCallback);

  final IrodoriBatchJob job;
  final void Function(IrodoriBatchLineResult line)? onLineCallback;
  final Map<String, IrodoriBatchLineResult> lines =
      <String, IrodoriBatchLineResult>{};
  final Completer<IrodoriBatchResult> result = Completer<IrodoriBatchResult>();

  void onLine(IrodoriWorkerLine event) {
    if (event.job != job.id || result.isCompleted) return;
    lines[event.result.id] = event.result;
    onLineCallback?.call(event.result);
  }

  void onDone(IrodoriWorkerJobDone event) {
    if (event.job != job.id || result.isCompleted) return;
    result.complete(
      IrodoriBatchResult(
        lines: Map<String, IrodoriBatchLineResult>.unmodifiable(lines),
        cancelled: event.cancelled,
      ),
    );
  }

  /// 进程退出：没回报的句子全部记失败（不悄悄当成没这句）。
  void onExit() {
    if (result.isCompleted) return;
    for (final IrodoriBatchItem item in job.items) {
      if (lines.containsKey(item.id)) continue;
      final IrodoriBatchLineResult failed = IrodoriBatchLineResult(
        id: item.id,
        ok: false,
        error: 'worker_exited',
      );
      lines[item.id] = failed;
      onLineCallback?.call(failed);
    }
    result.complete(
      IrodoriBatchResult(
        lines: Map<String, IrodoriBatchLineResult>.unmodifiable(lines),
        failure: IrodoriBatchFailure.exited,
      ),
    );
  }
}
