/// 手机（Android / iOS）设备端 ASR 的内存门槛：开跑前按「这台机器此刻能腾出多少
/// 内存」判这个模型跑不跑得动，跑不动就抛 [AsrInsufficientMemoryException]（带可读
/// 原因与能跑的更小模型），而不是开跑后被系统（Android lowmemorykiller / iOS
/// jetsam）杀掉整个 app。
///
/// **为什么要有这一层**（反馈 jbTZ4GIEyU，BUG-4372）：ZTE A103ZT（约 4 GB 内存，
/// Android 12）后台转录一本 m4b，进程 malloc 30 秒内从 77 MB 涨到 1390 MB、RSS
/// 从 540 MB 涨到 1.6 GB，前台被系统按低内存杀掉，连续两次。转录链路
/// （`AsrTranscriptionService.start` → 后台 isolate 建 ORT 会话 + fbank + 批量
/// encoder）此前在任何平台都不看设备内存，手机上「能不能跑」只体现在模型说明里
/// 的一句「手机上能跑，但很慢」。
///
/// **iOS 同样要有**（反馈 EnDAyv9ouF / _4fe2p5UsT，BUG-4758）：iPhone 15（iOS 27.2，
/// 3.3.0）在视频页启动本机语音转录生成字幕，RSS 8 秒内从 528 MB 涨到 1776 MB、
/// 另两次涨到 1824 / 1901 / 1953 MB，随即被 jetsam 杀掉；视频走 mixedAudio 素材，
/// 日语落到 Parakeet 0.6B（int8 约 655 MB，按下面的估算要 2.5 GB 以上）。原先门槛
/// 只在 Android 上生效，iOS 开跑前完全不看内存（拍板台 2026-11-16 定：扩到 iOS）。
///
/// 每个平台只用它真实可读、且就是「被杀线」的那个量（见各 [DeviceMemorySnapshot]
/// 子类的 `headroomBytes`）：
///
/// - **Android**（[AndroidMemorySnapshot]）：lmkd 没有单进程额度可查，用两个量取小：
///   - 进程天花板：物理内存 × [kAndroidAsrProcessCeilingFraction] 减去本进程当前
///     RSS。lmkd 在系统整体吃紧时杀前台进程，前台 app 能稳定占住的内存远小于物理
///     内存；上面那台 4 GB 机器在 RSS ≈ 1.6 GB 时被杀，0.4 正好落在被杀线之下。
///   - 此刻可用：`/proc/meminfo` 的 `MemAvailable`（内核估的「不换出就能拿到」的
///     内存）。
/// - **iOS**（[IosJetsamMemorySnapshot]）：`os_proc_available_memory()`（iOS 13+）
///   直接回报「本进程再分配多少就撞 jetsam 额度」——额度按机型与前后台由系统定，
///   算的是 phys_footprint（含压缩内存与视频解码的 IOSurface，比 RSS 更准）。这就是
///   被杀线本身，不用再拿物理内存比例去猜。
///
/// 估算峰值见 [estimateAsrPeakMemoryBytes]。桌面端（有交换、无单进程额度）不设门槛。
///
/// 门槛不砍性能：放得下的模型照原批次、原线程数全速跑；只拦「开跑必被杀」的组合，
/// 并告诉用户哪个更小的模型放得下。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi_asr_core/asr_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart'
    show ActivityBreadcrumb;
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';

/// 转录链路与模型大小无关的工作集：PCM 块（300 s × 16 kHz）、fbank 工作线程、
/// ffmpeg 解码子进程的管道缓冲、批量 encoder 的激活与 ORT arena 的底座。
///
/// 标定：jbTZ4GIEyU 那次 ReazonSpeech int8（全套约 161 MB）转录让 RSS 净涨约
/// 1.07 GB；`161 MB × 3 + 600 MB ≈ 1.08 GB` 与实测吻合。
const int kAsrMemoryBaseWorkingSetBytes = 600 * 1024 * 1024;

/// 模型文件 → 常驻内存的倍数：ORT 建会话时权重本体 + 图优化后的副本 + 多个
/// 贪心解码会话各自持有的 decoder / joiner。
const int kAsrMemoryModelMultiplier = 3;

/// 前台 app 在 Android 上能稳定占住的内存占物理内存的比例（见文件头）。
const double kAndroidAsrProcessCeilingFraction = 0.4;

/// 一次读到的设备内存状况（字节）。各平台的「被杀线」口径不同，余量由子类按本
/// 平台的真实判据给出（[headroomBytes]），判定逻辑不认平台。
@immutable
sealed class DeviceMemorySnapshot {
  const DeviceMemorySnapshot({required this.processRssBytes});

  /// 本进程当前 RSS（日志 / 反馈排查用）。
  final int processRssBytes;

  /// 此刻还能给转录腾出多少内存（可为负 = 本进程已经超过天花板）。
  int get headroomBytes;
}

/// Android：`/proc/meminfo` + `/proc/self/status` 读出的量。[availableBytes] 读不到
/// （老内核没有 `MemAvailable`）时为 null，只按天花板判。
final class AndroidMemorySnapshot extends DeviceMemorySnapshot {
  const AndroidMemorySnapshot({
    required this.totalBytes,
    required this.availableBytes,
    required super.processRssBytes,
  });

  final int totalBytes;
  final int? availableBytes;

  @override
  int get headroomBytes {
    final int ceiling =
        (totalBytes * kAndroidAsrProcessCeilingFraction).floor() -
        processRssBytes;
    final int? available = availableBytes;
    return available == null ? ceiling : math.min(ceiling, available);
  }

  @override
  String toString() =>
      'AndroidMemorySnapshot(total=$totalBytes, available=$availableBytes, '
      'rss=$processRssBytes)';
}

/// iOS：[availableBytes] 是 `os_proc_available_memory()`——本进程离 jetsam 额度
/// 还差多少（已扣掉当前 footprint），本身就是余量。
final class IosJetsamMemorySnapshot extends DeviceMemorySnapshot {
  const IosJetsamMemorySnapshot({
    required this.availableBytes,
    required super.processRssBytes,
  });

  final int availableBytes;

  @override
  int get headroomBytes => availableBytes;

  @override
  String toString() =>
      'IosJetsamMemorySnapshot(available=$availableBytes, '
      'rss=$processRssBytes)';
}

/// 纯函数：估算用 [pack] 的 [variant] 跑一次转录的进程内存净增峰值。
int estimateAsrPeakMemoryBytes(AsrModelPack pack, AsrEncoderVariant variant) =>
    pack.totalBytes(variant) * kAsrMemoryModelMultiplier +
    kAsrMemoryBaseWorkingSetBytes;

/// 纯函数：此刻还能给转录腾出多少内存（可为负 = 本进程已经超过天花板）。
int asrMemoryHeadroomBytes(DeviceMemorySnapshot memory) => memory.headroomBytes;

/// 开跑被内存门槛拦下。`toString` 就是给用户看的那句话（各入口的错误态都是
/// `'$error'` 原样显示——转录弹层、有声书自动转录队列、视频字幕），所以不用逐个
/// 入口去认这个类型。
class AsrInsufficientMemoryException implements Exception {
  const AsrInsufficientMemoryException({
    required this.modelName,
    required this.requiredBytes,
    required this.headroomBytes,
    required this.memory,
    this.suggestedModelName,
  });

  /// 被拦下的模型显示名。
  final String modelName;

  /// 估算需要的内存（[estimateAsrPeakMemoryBytes]）。
  final int requiredBytes;

  /// 此刻能腾出的内存（[asrMemoryHeadroomBytes]）。
  final int headroomBytes;

  /// 判定时读到的设备内存（日志 / 反馈排查用）。
  final DeviceMemorySnapshot memory;

  /// 同语言同素材里放得下的模型；null = 一个都放不下。
  final String? suggestedModelName;

  /// 给用户看的完整说明（当前语言）。
  String get message {
    final String head = t.asr_memory_insufficient(
      model: modelName,
      need: FushiByteFormat.bytes(requiredBytes),
      spare: FushiByteFormat.bytes(math.max(0, headroomBytes)),
    );
    final String? suggested = suggestedModelName;
    final String tail = suggested == null
        ? t.asr_memory_no_fitting_model
        : t.asr_memory_suggest_model(model: suggested);
    return '$head $tail';
  }

  @override
  String toString() => message;
}

/// 纯函数：门槛判定。放得下返回 null；放不下返回要抛的异常，
/// [alternatives]（同语言同素材可选的包，按注册表顺序）里第一个按 int8 估算
/// 放得下的作为建议。
AsrInsufficientMemoryException? asrMemoryGateVerdict({
  required AsrModelPack pack,
  required AsrEncoderVariant variant,
  required DeviceMemorySnapshot memory,
  required List<AsrModelPack> alternatives,
}) {
  final int needed = estimateAsrPeakMemoryBytes(pack, variant);
  final int headroom = asrMemoryHeadroomBytes(memory);
  if (needed <= headroom) return null;
  String? suggested;
  for (final AsrModelPack candidate in alternatives) {
    if (candidate.id == pack.id) continue;
    if (estimateAsrPeakMemoryBytes(candidate, AsrEncoderVariant.int8) <=
        headroom) {
      suggested = candidate.displayName;
      break;
    }
  }
  return AsrInsufficientMemoryException(
    modelName: pack.displayName,
    requiredBytes: needed,
    headroomBytes: headroom,
    memory: memory,
    suggestedModelName: suggested,
  );
}

/// 纯函数：从 `/proc/meminfo`（或 `/proc/self/status`）文本里取某个 kB 字段的
/// 字节数。
int? parseProcMeminfoBytes(String content, String field) {
  final RegExp pattern = RegExp(
    '^${RegExp.escape(field)}:\\s+(\\d+)\\s*kB',
    multiLine: true,
  );
  final Match? m = pattern.firstMatch(content);
  final int? kb = m == null ? null : int.tryParse(m.group(1)!);
  return kb == null ? null : kb * 1024;
}

/// 纯函数：从 `/proc/self/status` 文本里取 `VmRSS`（字节）。
int? parseProcStatusRssBytes(String content) =>
    parseProcMeminfoBytes(content, 'VmRSS');

/// 读本机内存状况：Android 读 `/proc`，iOS 问 jetsam 额度；桌面端返回 null =
/// 不设门槛（有交换、没有单进程额度，跑大模型只会慢不会被杀）。
DeviceMemorySnapshot? readDeviceMemorySnapshot() => deviceMemorySnapshotFor(
  isAndroid: Platform.isAndroid,
  isIOS: Platform.isIOS,
  android: readAndroidMemorySnapshot,
  ios: readIosMemorySnapshot,
);

/// [readDeviceMemorySnapshot] 的平台分派（平台与各平台读取可注入，host 上能测
/// 「iOS 走 jetsam 额度、桌面不设门槛」）。
@visibleForTesting
DeviceMemorySnapshot? deviceMemorySnapshotFor({
  required bool isAndroid,
  required bool isIOS,
  required DeviceMemorySnapshot? Function() android,
  required DeviceMemorySnapshot? Function() ios,
}) {
  if (isAndroid) return android();
  if (isIOS) return ios();
  return null;
}

/// Android 的 [readDeviceMemorySnapshot]。
///
/// `/proc/meminfo` 与 `/proc/self/status` 对 app 进程恒可读；真读不到（文件系统
/// 异常、字段缺失）时同样返回 null 并打日志——没有数据就没法判，照旧开跑而不是
/// 凭空拦人，但原因留在日志里。
AndroidMemorySnapshot? readAndroidMemorySnapshot() {
  if (!Platform.isAndroid) return null;
  try {
    final String meminfo = File('/proc/meminfo').readAsStringSync();
    final String status = File('/proc/self/status').readAsStringSync();
    final int? total = parseProcMeminfoBytes(meminfo, 'MemTotal');
    final int? rss = parseProcStatusRssBytes(status);
    if (total == null || rss == null) {
      debugPrint(
        '[Fushi] ASR memory gate: MemTotal/VmRSS missing; gate skipped',
      );
      return null;
    }
    return AndroidMemorySnapshot(
      totalBytes: total,
      availableBytes: parseProcMeminfoBytes(meminfo, 'MemAvailable'),
      processRssBytes: rss,
    );
  } on FileSystemException catch (error) {
    debugPrint('[Fushi] ASR memory gate: cannot read /proc ($error)');
    return null;
  }
}

typedef _OsProcAvailableMemoryNative = Size Function();
typedef _OsProcAvailableMemoryDart = int Function();

_OsProcAvailableMemoryDart? _osProcAvailableMemory;
bool _osProcAvailableMemoryResolved = false;

/// libSystem 的 `size_t os_proc_available_memory(void)`（`<os/proc.h>`，iOS 13+），
/// 在进程符号表里，经 `DynamicLibrary.process()` 直接取，不需要原生桥。
_OsProcAvailableMemoryDart? _resolveOsProcAvailableMemory() {
  if (_osProcAvailableMemoryResolved) return _osProcAvailableMemory;
  _osProcAvailableMemoryResolved = true;
  try {
    _osProcAvailableMemory = DynamicLibrary.process()
        .lookupFunction<
          _OsProcAvailableMemoryNative,
          _OsProcAvailableMemoryDart
        >('os_proc_available_memory');
  } on ArgumentError catch (error) {
    debugPrint(
      '[Fushi] ASR memory gate: os_proc_available_memory unavailable '
      '($error); gate skipped',
    );
    _osProcAvailableMemory = null;
  }
  return _osProcAvailableMemory;
}

/// 纯函数：把 `os_proc_available_memory()` 的返回值折成快照。系统对没有 jetsam
/// 额度的进程（模拟器、Mac 上跑的 iOS app）回 0——那不是「一点内存都没有」而是
/// 「没有额度可言」，返回 null = 不设门槛，免得把所有转录都拦掉。
IosJetsamMemorySnapshot? iosJetsamMemorySnapshotFrom({
  required int availableBytes,
  required int processRssBytes,
}) {
  if (availableBytes <= 0) return null;
  return IosJetsamMemorySnapshot(
    availableBytes: availableBytes,
    processRssBytes: processRssBytes,
  );
}

/// iOS 的 [readDeviceMemorySnapshot]。取不到符号或系统回 0 时返回 null 并打日志
/// （与 Android 读不到 `/proc` 同一口径：没数据不凭空拦人）。
IosJetsamMemorySnapshot? readIosMemorySnapshot() {
  if (!Platform.isIOS) return null;
  final _OsProcAvailableMemoryDart? probe = _resolveOsProcAvailableMemory();
  if (probe == null) return null;
  final IosJetsamMemorySnapshot? snapshot = iosJetsamMemorySnapshotFrom(
    availableBytes: probe(),
    processRssBytes: ProcessInfo.currentRss,
  );
  if (snapshot == null) {
    debugPrint(
      '[Fushi] ASR memory gate: os_proc_available_memory returned 0 '
      '(no jetsam limit); gate skipped',
    );
  }
  return snapshot;
}

/// 活动面包屑名：转录跑着时进程被杀，下次启动的崩溃报告会带上「死在转录里、用的
/// 哪个模型、开跑时余量多少」（反馈 _4fe2p5UsT：原报告只看得出在生成字幕，看不出
/// 模型）。
const String kAsrTranscribeActivity = 'asr_transcribe';

/// 纯函数：面包屑 / 日志里那行开跑诊断。
String asrTranscribeDiagnostic({
  required AsrModelPack pack,
  required AsrEncoderVariant variant,
  required AsrAudioProfile profile,
  required DeviceMemorySnapshot? memory,
}) {
  final StringBuffer out = StringBuffer()
    ..write('model=${pack.id} variant=${variant.name} profile=${profile.name} ')
    ..write('need=${estimateAsrPeakMemoryBytes(pack, variant) >> 20}MB');
  if (memory == null) {
    out.write(' headroom=unknown');
  } else {
    out
      ..write(' headroom=${memory.headroomBytes >> 20}MB')
      ..write(' rss=${memory.processRssBytes >> 20}MB');
  }
  return out.toString();
}

/// 转录活动面包屑：同一时刻可能有多路转录（有声书自动转录队列 + 视频字幕）。
/// 按路记诊断行，面包屑内容始终是**仍在跑的各路**拼起来的（一路结束就用剩下的
/// 重写），最后一路结束才清——否则后开先结束的那路会把它的模型名留在面包屑里，
/// 进程死在另一路时诊断指错模型。写 / 清可注入（测试不碰诊断目录）。
class AsrTranscribeBreadcrumb {
  AsrTranscribeBreadcrumb({
    void Function(String detail)? mark,
    void Function()? clear,
  }) : _mark =
           mark ??
           ((String detail) =>
               ActivityBreadcrumb.mark(kAsrTranscribeActivity, detail)),
       _clear =
           clear ?? (() => ActivityBreadcrumb.clear(kAsrTranscribeActivity));

  /// 生产共用的那一份（计数必须进程内唯一）。
  static final AsrTranscribeBreadcrumb shared = AsrTranscribeBreadcrumb();

  final void Function(String detail) _mark;
  final void Function() _clear;

  /// 仍在跑的各路：路号 → 诊断行（按开跑先后）。
  final Map<int, String> _active = <int, String>{};
  int _nextRun = 0;

  /// 多路并发时各路诊断行之间的分隔。
  static const String separator = ' || ';

  void _write() => _mark(_active.values.join(separator));

  /// 一路转录开始；返回只生效一次的结束回调。
  void Function() begin(String detail) {
    final int run = _nextRun++;
    _active[run] = detail;
    _write();
    bool ended = false;
    return () {
      if (ended) return;
      ended = true;
      _active.remove(run);
      if (_active.isEmpty) {
        _clear();
      } else {
        _write();
      }
    };
  }
}

/// 给运行中的转录挂上「结束即清面包屑」：事件流结束（完成 / 暂停 / 出错 / 取消
/// 订阅）或 dispose，先到者调 [end]。其余成员原样转发。
@visibleForTesting
AsrRunningTranscription asrTranscriptionEndingBreadcrumb(
  AsrRunningTranscription running,
  void Function() end,
) => _BreadcrumbedTranscription(running, end);

class _BreadcrumbedTranscription implements AsrRunningTranscription {
  _BreadcrumbedTranscription(this._inner, this._end);

  final AsrRunningTranscription _inner;
  final void Function() _end;

  @override
  OnnxProviderResolution get encoderResolution => _inner.encoderResolution;

  @override
  bool get greedyGraphAvailable => _inner.greedyGraphAvailable;

  @override
  String? get greedyUnavailableReason => _inner.greedyUnavailableReason;

  @override
  bool get encoderFp16 => _inner.encoderFp16;

  @override
  AsrDecodeStats? get decodeStats => _inner.decodeStats;

  @override
  Stream<AsrTranscribeEvent> run() async* {
    try {
      yield* _inner.run();
    } finally {
      _end();
    }
  }

  @override
  void requestPause({bool discardPending = false}) =>
      _inner.requestPause(discardPending: discardPending);

  @override
  Future<void> dispose() async {
    try {
      await _inner.dispose();
    } finally {
      _end();
    }
  }
}

/// 带内存门槛的转录服务：`start` 之前先过 [asrMemoryGateVerdict]。
///
/// 门槛放在 `start` 上而不是各个入口：转录弹层、有声书自动转录队列、视频字幕、
/// 控制通道、TTS 回校全都经 `createAsrTranscriptionService` 拿到这个服务、再调
/// `start`，一处拦住所有入口，不会出现「弹层拦了、后台队列照样被杀」。
class MemoryGatedAsrTranscriptionService extends AsrTranscriptionService {
  MemoryGatedAsrTranscriptionService({
    required super.backend,
    required super.audioProfile,
    super.loader,
    super.pcm,
    super.openStore,
    super.jobsRoot,
    DeviceMemorySnapshot? Function() memoryProbe = readDeviceMemorySnapshot,
    AsrTranscribeBreadcrumb? breadcrumb,
  }) : _memoryProbe = memoryProbe,
       _breadcrumb = breadcrumb ?? AsrTranscribeBreadcrumb.shared;

  final DeviceMemorySnapshot? Function() _memoryProbe;
  final AsrTranscribeBreadcrumb _breadcrumb;

  /// 当前用的内存探针（生产默认 [readDeviceMemorySnapshot]）。
  @visibleForTesting
  DeviceMemorySnapshot? Function() get memoryProbe => _memoryProbe;

  /// 按当前注册表判这门语言在本素材上用 [variant] 跑不跑得动；跑不动抛
  /// [AsrInsufficientMemoryException]。放得下时返回开跑诊断行（模型 / 余量），
  /// 供日志与活动面包屑用。
  String ensureMemoryFor(AsrLanguage language, AsrEncoderVariant variant) {
    final AsrModelPack pack = asrModelPackFor(language, profile: audioProfile);
    final DeviceMemorySnapshot? memory = _memoryProbe();
    final String diagnostic = asrTranscribeDiagnostic(
      pack: pack,
      variant: variant,
      profile: audioProfile,
      memory: memory,
    );
    if (memory == null) return diagnostic;
    final AsrInsufficientMemoryException? failure = asrMemoryGateVerdict(
      pack: pack,
      variant: variant,
      memory: memory,
      alternatives: <AsrModelPack>[
        for (final AsrModelPack candidate in asrModelRegistry.packs)
          if (candidate.languages.contains(language) &&
              candidate.servesProfile(audioProfile))
            candidate,
      ],
    );
    if (failure == null) return diagnostic;
    debugPrint(
      '[Fushi] ASR memory gate refused ${pack.id}: need '
      '${failure.requiredBytes}, headroom ${failure.headroomBytes}, $memory',
    );
    throw failure;
  }

  @override
  Future<AsrRunningTranscription> start({
    required List<String> audioPaths,
    required AsrLanguage language,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
    List<AsrSegmentSpan>? segments,
  }) async {
    final String diagnostic = ensureMemoryFor(language, variant);
    debugPrint('[Fushi] ASR start $diagnostic');
    // 面包屑在建会话 / 起 isolate 之前写下：jetsam 恰恰在装载模型那几秒杀进程。
    final void Function() end = _breadcrumb.begin(diagnostic);
    try {
      final AsrRunningTranscription running = await super.start(
        audioPaths: audioPaths,
        language: language,
        variant: variant,
        preference: preference,
        segments: segments,
      );
      return asrTranscriptionEndingBreadcrumb(running, end);
    } catch (_) {
      end();
      rethrow;
    }
  }
}
