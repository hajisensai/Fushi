/// 用 Apple 系统语音转录（iOS 26 / macOS 26）顶替 ONNX 后端的那份转录服务。
///
/// **为什么是继承而不是新接口**：转录弹层与设置页吃的是具体类
/// `AsrTranscriptionService`（上游包里的类，本仓不改）。给它抽一个接口意味着改上游
/// 包 + 改弹层 880 行 + 改两处生产实例化点 + 改一整套既有测试；而那个类的对外方法
/// 全是可覆写的实例方法，包里的 widget 测试早就在继承它做 fake。所以这里走同一条
/// 路：覆写全部会被弹层调到的方法，内部一个 ONNX 符号都不碰。
///
/// **产物必须与 ONNX 后端逐字节同构**——同一个任务目录布局（`state.json` /
/// `transcript.srt` / `transcript.tokens.jsonl`），同一套序列化函数
/// （`serializeAsrCuesToSrt` / `serializeAsrCueTokens`）。下游的匹配、对齐、
/// 「这份字幕是不是转录产物」判据（`isAsrGeneratedSubtitlePath` 认的是
/// `transcript.srt` 旁边有没有 `state.json`）因此一行都不用改。
///
/// **任务 id 用自己的模型名**（[kAppleSpeechEngineId]）：换引擎就是另一个任务，
/// ONNX 转到一半的进度不会被顶掉，切回去还在——与「换模型 = 换任务」同一条规则。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_asr_core/asr_core.dart';

import 'package:fushi/src/asr_host/apple_speech_channel.dart';

/// 系统语音引擎在「模型选择」里的保留 id。
///
/// 不是一个 [AsrModelPack] 的 id：它没有文件、没有变体、不占磁盘。保留 id 落进
/// 目录的 `choices` 时，`buildAsrModelRegistry` 里 `_packById` 找不到它会**忽略这条
/// 选择**——这正是我们要的：注册表只管 ONNX 包，引擎选择由 UI 层解释。
const String kAppleSpeechEngineId = 'system-apple-speech';

class AppleSpeechTranscriptionService extends AsrTranscriptionService {
  AppleSpeechTranscriptionService({
    AppleSpeechPlatform? platform,
    Future<Directory> Function()? jobsRoot,
  })  : _platform = platform ?? MethodChannelAppleSpeech(),
        _jobsRootOverride = jobsRoot,
        super(
          // 父类构造要一个 backend，但本服务把每一个会用到它的方法都覆写了，
          // ONNX 那条路在这里结构上不可达（`buildFactory` 永远不会被调）。
          backend: const AsrIsolateBackend(buildFactory: _unusedOnnxFactory),
          // 同理：Apple 原生引擎自己做端点检测，不经本仓的 VAD 切段。父类要求
          // 显式声明素材属性（见 AsrAudioProfile），这里填一个不会被用到的值。
          audioProfile: AsrAudioProfile.cleanSpeech,
        );

  final AppleSpeechPlatform _platform;
  final Future<Directory> Function()? _jobsRootOverride;

  static OnnxSessionFactory _unusedOnnxFactory() =>
      throw StateError('Apple speech backend never builds an ONNX session');

  /// 本机能不能用（OS ≥ 26 且原生侧在）。
  Future<bool> isAvailable() => _platform.isAvailable();

  Future<Directory> _jobsRoot() async {
    final Future<Directory> Function()? override = _jobsRootOverride;
    if (override != null) return override();
    final Directory support = await asrSupportRootDirectory();
    return Directory(p.join(support.path, 'asr_jobs'));
  }

  /// 任务目录：与父类同构（文件名 + 字节数 + 模型 id 的 SHA-1），只是模型 id 换成
  /// [kAppleSpeechEngineId]。父类那份是 static、按 `asrModelPackFor` 取 id，覆写不到，
  /// 所以这里连同 [existingState] / [finishedSrtPath] 一起接管。
  @override
  Future<Directory> jobDirFor(
    List<String> audioPaths,
    AsrLanguage language,
  ) async {
    final Directory root = await _jobsRoot();
    return Directory(
      p.join(root.path, appleSpeechJobId(audioPaths, language)),
    );
  }

  /// 纯函数：由文件名、字节数与引擎 id 派生稳定 id（与父类 `jobIdFor` 同构）。
  static String appleSpeechJobId(
    List<String> audioPaths,
    AsrLanguage language,
  ) {
    final StringBuffer sb = StringBuffer();
    for (final String path in audioPaths) {
      final File f = File(path);
      final int bytes = f.existsSync() ? f.lengthSync() : 0;
      sb
        ..write(p.basename(path))
        ..write('|')
        ..write(bytes)
        ..write('\n');
    }
    sb
      ..write('model=')
      ..write(kAppleSpeechEngineId)
      ..write('@')
      ..write(language.tag)
      ..write('\n');
    return sha1.convert(utf8.encode(sb.toString())).toString();
  }

  /// 计划：这里的「模型就绪」= 该语言的系统资产已安装。
  ///
  /// 没装时 `modelReady` 为 false，弹层照常走「下载模型」那条路，只是按下去调的是
  /// [downloadModel] → 系统的资产安装。字节数给不出来（系统不报），所以 total 用 0
  /// ——UI 那边会显示成「需要下载」但不报大小，这比编一个数字诚实。
  @override
  Future<AsrTranscribePlan> plan({
    required AsrLanguage language,
    required AsrAccelerationPreference preference,
  }) async {
    final List<String> installed = await _platform.installedLocales();
    final bool ready = _matches(installed, language.tag);
    return AsrTranscribePlan(
      language: language,
      variant: AsrEncoderVariant.int8,
      expectedProvider: OnnxExecutionProvider.cpu,
      modelStatus: AsrModelStatus(
        ready: ready,
        diskBytes: 0,
        totalBytes: 0,
        obtainedBytes: 0,
      ),
    );
  }

  /// 「下载模型」= 让系统把该语言的资产装上。装好后 [plan] 就报就绪。
  @override
  Stream<ModelDownloadEvent> downloadModel({
    required AsrLanguage language,
    required AsrEncoderVariant variant,
  }) async* {
    yield const ModelDownloadEvent(
      fileName: 'system speech assets',
      receivedBytes: 0,
      totalBytes: 0,
    );
    await _platform.prepare(language.tag);
    yield const ModelDownloadEvent(
      fileName: 'system speech assets',
      receivedBytes: 0,
      totalBytes: 0,
      done: true,
    );
  }

  @override
  Future<AsrJobState?> existingState(
    List<String> audioPaths,
    AsrLanguage language,
  ) async {
    final Directory dir = await jobDirFor(audioPaths, language);
    final File state = File(p.join(dir.path, AsrJobFiles.state));
    if (!state.existsSync()) return null;
    try {
      final Object? raw = jsonDecode(await state.readAsString());
      if (raw is! Map<String, Object?>) return null;
      final AsrJobState parsed = AsrJobState.fromJson(raw);
      // 音频集合变了（用户换了文件）→ 旧状态作废，当作没有。
      if (parsed.audioPaths.length != audioPaths.length) return null;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> finishedSrtPath(
    List<String> audioPaths,
    AsrLanguage language,
  ) async {
    final AsrJobState? state = await existingState(audioPaths, language);
    if (state == null || !state.finished) return null;
    final Directory dir = await jobDirFor(audioPaths, language);
    final File srt = File(p.join(dir.path, AsrJobFiles.srt));
    return srt.existsSync() ? srt.path : null;
  }

  @override
  Future<void> discard(List<String> audioPaths, AsrLanguage language) async {
    final Directory dir = await jobDirFor(audioPaths, language);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  @override
  Future<AsrRunningTranscription> start({
    required List<String> audioPaths,
    required AsrLanguage language,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
  }) async {
    final Directory dir = await jobDirFor(audioPaths, language);
    await dir.create(recursive: true);
    return AppleSpeechRunningTranscription(
      platform: _platform,
      audioPaths: List<String>.unmodifiable(audioPaths),
      language: language,
      jobDir: dir,
    );
  }

  /// 该语言标签是否在这组 BCP-47 标签里（按主子标签比：`ja` 命中 `ja-JP`）。
  static bool _matches(List<String> locales, String tag) {
    final String primary = _primary(tag);
    if (primary.isEmpty) return false;
    for (final String locale in locales) {
      if (_primary(locale) == primary) return true;
    }
    return false;
  }

  static String _primary(String tag) {
    final String lowered = tag.toLowerCase();
    final int dash = lowered.indexOf(RegExp(r'[-_]'));
    return dash < 0 ? lowered : lowered.substring(0, dash);
  }
}

/// 一次正在跑的系统语音转录。
///
/// 与 ONNX 那条的**行为差异必须说清**：系统 API 是「喂一个文件、等它转完」，中途
/// **没有可续跑的检查点**。产物只在**整趟跑完**之后才落盘（SRT / sidecar /
/// `state.json` 一次写齐），所以 [requestPause] 实际上是放弃**整趟**——不是「从下
/// 一个文件接着来」，重开就是从第一个文件重跑。
///
/// 即便如此也**必须发** `AsrTranscribePausedEvent`：弹层按下暂停后停在
/// `_Phase.pausing`，只认这个事件落到「已暂停」。不发它（或改发 error）会让界面
/// 卡在「正在暂停…」或报出一条 `PlatformException(CANCELLED)` 当失败。
class AppleSpeechRunningTranscription implements AsrRunningTranscription {
  AppleSpeechRunningTranscription({
    required AppleSpeechPlatform platform,
    required this.audioPaths,
    required this.language,
    required this.jobDir,
  }) : _platform = platform;

  final AppleSpeechPlatform _platform;
  final List<String> audioPaths;
  final AsrLanguage language;
  final Directory jobDir;

  bool _cancelled = false;

  @override
  OnnxProviderResolution get encoderResolution => const OnnxProviderResolution(
        requested: <OnnxExecutionProvider>[OnnxExecutionProvider.cpu],
        effective: OnnxExecutionProvider.cpu,
      );

  @override
  bool get greedyGraphAvailable => false;

  @override
  String? get greedyUnavailableReason => null;

  @override
  bool get encoderFp16 => false;

  @override
  AsrDecodeStats? get decodeStats => null;

  /// 事件流。真正的活在 [_drive] 里，**不能用 `async*`**：原生的文件内进度是从
  /// 回调里来的，而回调里 `yield` 不了。早先那版在回调里往一个没人订阅的
  /// `StreamController` 里塞进度，等于把长文件唯一会动的那个进度整份丢掉——
  /// 转一个几小时的音频，进度条要到整个文件转完才第一次动。
  ///
  /// 起跑挂在 `onListen` 上：`run()` 被调用但没人订阅时不该已经在转。
  @override
  Stream<AsrTranscribeEvent> run() {
    final StreamController<AsrTranscribeEvent> events =
        StreamController<AsrTranscribeEvent>();
    events.onListen = () => unawaited(_drive(events));
    return events.stream;
  }

  Future<void> _drive(StreamController<AsrTranscribeEvent> events) async {
    final Stopwatch clock = Stopwatch()..start();
    final List<AsrCue> cues = <AsrCue>[];
    final List<int> fileDurationsMs = <int>[];
    int offsetMs = 0;
    int currentIndex = 0;

    AsrTranscribeProgress progressAt(
      int fileIndex,
      int processedMs,
      int totalMs,
    ) =>
        AsrTranscribeProgress(
          fileIndex: fileIndex,
          filesTotal: audioPaths.length,
          processedMs: processedMs,
          totalMs: totalMs,
          speechMs: processedMs,
          segmentsDone: cues.length,
          elapsed: clock.elapsed,
        );

    void emit(AsrTranscribeEvent event) {
      if (!events.isClosed) events.add(event);
    }

    try {
      for (int index = 0; index < audioPaths.length; index++) {
        if (_cancelled) break;
        currentIndex = index;
        final int base = offsetMs;
        final AppleSpeechResult result;
        try {
          result = await _platform.transcribe(
            path: audioPaths[index],
            locale: language.tag,
            onProgress: (int processedMs, int totalMs) => emit(
              AsrTranscribeProgressEvent(
                progressAt(index, base + processedMs, base + totalMs),
              ),
            ),
          );
        } on Object {
          // 取消是我们自己发下去的，原生会以 `CANCELLED` 应答；那不是失败，
          // 不能报成错误态（见 [requestPause]）。只有**没在取消**时才是真失败。
          if (_cancelled) break;
          rethrow;
        }
        cues.addAll(
          appleSpeechCues(
            result.segments,
            fileIndex: index,
            offsetMs: offsetMs,
          ),
        );
        offsetMs += result.durationMs;
        fileDurationsMs.add(result.durationMs);
        emit(
          AsrTranscribeProgressEvent(progressAt(index, offsetMs, offsetMs)),
        );
      }

      if (_cancelled) {
        // 必须给一个终局事件：弹层按下暂停后停在 `_Phase.pausing`，收不到
        // Paused 就一直显示「正在暂停…」且没有任何按钮可按。
        emit(
          AsrTranscribePausedEvent(
            progressAt(currentIndex, offsetMs, offsetMs),
          ),
        );
        return;
      }

      // 产物与 ONNX 后端同构：同一套序列化函数、同样的文件名。
      final File srt = File(p.join(jobDir.path, AsrJobFiles.srt));
      final File tokens = File(p.join(jobDir.path, AsrJobFiles.cueTokens));
      await srt.writeAsString(serializeAsrCuesToSrt(cues), flush: true);
      await tokens.writeAsString(serializeAsrCueTokens(cues), flush: true);
      await File(p.join(jobDir.path, AsrJobFiles.state)).writeAsString(
        jsonEncode(
          AsrJobState(
            audioPaths: audioPaths,
            modelId: kAppleSpeechEngineId,
            fileDurationsMs: fileDurationsMs,
            resumeSamples: List<int>.filled(audioPaths.length, 0),
            finished: true,
          ).toJson(),
        ),
        flush: true,
      );

      emit(
        AsrTranscribeFinishedEvent(
          AsrTranscribeResult(
            srtPath: srt.path,
            segmentsPath: p.join(jobDir.path, AsrJobFiles.segments),
            cueCount: cues.length,
            segmentCount: cues.length,
            totalMs: offsetMs,
            fileDurationsMs: fileDurationsMs,
          ),
        ),
      );
    } catch (error, stack) {
      if (!events.isClosed) events.addError(error, stack);
    } finally {
      await events.close();
    }
  }

  @override
  void requestPause({bool discardPending = false}) {
    // 系统 API 没有可续跑的检查点：暂停只能是取消（见类文档）。
    _cancelled = true;
    unawaited(_platform.cancel());
  }

  @override
  Future<void> dispose() async {
    // 先立旗再取消：在跑的那次 `transcribe` 会以 `CANCELLED` 抛回来，[_drive]
    // 靠这面旗把它认成「我们要求的停」而不是转录失败。
    final bool wasRunning = !_cancelled;
    _cancelled = true;
    if (wasRunning) await _platform.cancel();
  }
}
