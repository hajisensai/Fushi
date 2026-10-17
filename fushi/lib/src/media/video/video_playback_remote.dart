import 'dart:async';

import 'package:flutter/foundation.dart';

/// 视频播放页对外暴露的最小遥控面（桌面控制通道 `fushi_cli play ...` 用）。
///
/// 播放控制器是 `_VideoFushiPageState` 的私有字段，页面在 initState 把自己的实现
/// 登记进 [videoPlaybackRemotes]、dispose 时注销。实现只转调页内已有的执行体
/// （底栏 / 悬浮球 / 快捷键背后的同一批方法），不另写播放逻辑。
abstract interface class VideoPlaybackRemote {
  /// 当前播放状态；控制器尚未就绪（首开加载中 / 加载失败）时为 null。
  VideoPlaybackSnapshot? snapshot();

  Future<void> play();

  Future<void> pause();

  Future<void> toggle();

  /// 绝对跳转到 [positionMs]（毫秒）。
  Future<void> seekToMs(int positionMs);

  /// 相对当前位置前后跳 [deltaMs]（毫秒，负数后退）。
  Future<void> seekByMs(int deltaMs);

  /// 设置倍速（与页内倍速菜单同一入口，含持久化与夹取）。
  Future<void> setRate(double rate);

  /// 上一句字幕（无字幕时回退若干秒，与底栏「上一句」按钮同语义）。
  Future<void> previousCue();

  /// 下一句字幕（无字幕时前进若干秒，与底栏「下一句」按钮同语义）。
  Future<void> nextCue();
}

/// [VideoPlaybackRemote.snapshot] 的只读快照。
@immutable
class VideoPlaybackSnapshot {
  const VideoPlaybackSnapshot({
    required this.title,
    required this.bookUid,
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    required this.speed,
    required this.cue,
    this.volume,
    this.audioTrackId,
    this.subtitleSource,
    this.secondarySubtitleSource,
  });

  final String? title;
  final String bookUid;
  final int? positionMs;
  final int? durationMs;
  final bool playing;
  final double speed;

  /// 当前字幕句文本（无字幕 / 句间空隙为 null）。
  final String? cue;

  /// 音量 0–100（实现不提供时为 null）。
  final double? volume;

  /// 当前音轨 id（[VideoRemoteAudioTrack.id]）；未选过为 null。
  final String? audioTrackId;

  /// 当前主 / 副字幕源（持久化值：`embedded:<n>` / 外挂文件路径 / `off:` 哨兵）。
  final String? subtitleSource;
  final String? secondarySubtitleSource;
}

/// 播放页遥控面的扩展部分（桌面控制通道 `fushi_cli video ...` 用）：音量 / 音轨 /
/// 主副字幕、字幕导入与生成（整轨 OCR / 语音转录 / 重定时 / 对轴）、制卡与片段导出。
///
/// 与 [VideoPlaybackRemote] 分开声明是为了不打断既有的最小遥控实现；视频页同时实现
/// 两者，路由层按 `remote is VideoPlayerRemoteControl` 判能力。每个动作都转调页内
/// 已有执行体（设置面板 / 字幕面板 / 制卡弹窗背后的同一批方法），失败抛
/// [VideoRemoteFailure]（页内对应入口会弹的那句提示原样带回来）。
/// 播放页把自己的快捷设置宿主借给控制通道：`config set / run` 改视频项（字幕位置、
/// 着色器档位…）时，播放中就走与快捷设置面板同一组页面回调（即时应用到活播放器，
/// 同一处落盘），没有播放页时退回直接写偏好。路由层按
/// `remote is VideoQuickSettingsHostProvider` 判能力。
abstract interface class VideoQuickSettingsHostProvider {
  /// 页面当前的快捷设置宿主（`VideoQuickSettingsHost`）；页面已卸载时为 null。
  Object? quickSettingsHost();
}

abstract interface class VideoPlayerRemoteControl {
  /// 正在播放的条目身份（光盘会话时是该光盘标题的 uid）：暂存制卡队列、制卡统计
  /// 按它归属。
  String get activeBookUid;

  /// 设音量（0–100，与音量滑条同一入口：写播放器 + 持久化 + OSD）。返回生效值。
  Future<double> setVolume(double volume);

  /// 静音切换（与 M 键同一入口）。返回切换后的音量。
  Future<double> toggleMute();

  List<VideoRemoteAudioTrack> audioTracks();

  /// 切音轨（与设置面板「音频」分类同一入口：切轨 + 按系列 / 本集持久化）。
  Future<void> selectAudioTrack(String id);

  /// 主 / 副字幕可选轨与当前选择（本地视频首次调用会枚举内封轨，与打开设置面板
  /// 「字幕」分类同一条枚举）。
  Future<VideoRemoteSubtitleState> subtitleState();

  /// 选主字幕（[secondary] = false）或副字幕；[source] 是 [VideoRemoteSubtitleTrack.source]。
  Future<void> selectSubtitle(String source, {required bool secondary});

  /// 关闭主 / 副字幕（持久化「显式关闭」）。
  Future<void> subtitleOff({required bool secondary});

  /// 导入外部字幕文件并选为主字幕（[secondary] = true 时选为副字幕，只有远端视频的
  /// 副字幕区有「导入」）。与「导入字幕文件」同一条链路，返回选中的源。
  Future<String> importSubtitle(String path, {bool secondary = false});

  /// 图形字幕轨（PGS / VobSub / DVB）整轨 OCR 成文字字幕；[source] 是图形轨的源。
  /// [consentLlm] / [consentUpload] 是两个一次性同意（「低置信度默认交给 LLM」、
  /// Google Lens 上传）的无头答案，写入与 app 同意框相同的状态；需要回答却没给时以
  /// `consent_required` 失败，不在 app 内弹框。
  Future<VideoRemoteJob> startSubtitleOcr(
    String source, {
    bool? consentLlm,
    bool consentUpload = false,
  });

  /// 用设备端语音模型从音轨生成字幕（[retime] = false）或重定时当前字幕
  /// （[retime] = true）。[language] 为 ASR 语言标签（`ja` / `en` …），null 用上次
  /// 转录语言。
  VideoRemoteJob startTranscribe({String? language, required bool retime});

  /// 按视频内封文本字幕轨给当前外挂字幕对时间轴。证据不足需要确认、或当前档是
  /// 对齐产物（会改为「恢复原始时间轴」）时，[confirm] 为 false 则以
  /// `needs_confirmation` 失败，不改任何东西。
  VideoRemoteJob startSubtitleAlign({required bool confirm});

  /// 导出 [startMs, endMs] 片段（与片段导出同一个 ffmpeg 导出，含烧录当前字幕）。
  /// [outputPath] 为 null 时落 app 文档目录 `video_clips/`。
  VideoRemoteJob startClipExport({
    required int startMs,
    required int endMs,
    String? outputPath,
  });

  /// 用 [fields]（词典制卡字段）对当前字幕句制卡——与查词弹窗「+」同一条落卡链路
  /// （截图 / 句子音频 / 统计 / 制卡历史），锚点是当前播放位置的字幕句。
  Future<VideoRemoteMineResult> mineCurrentCue(Map<String, String> fields);

  /// 暂存队列被外部改动（CLI 写入 / 丢弃）后刷新页内角标计数。
  Future<void> refreshMineQueue();
}

/// 控制动作失败：[code] 是机器可读原因，[message] 是给人看的一句话。
class VideoRemoteFailure implements Exception {
  const VideoRemoteFailure(this.code, this.message);

  /// `no_video` / `busy` / `unsupported` / `not_found` / `failed` /
  /// `needs_confirmation` / `cancelled`。
  final String code;
  final String message;

  @override
  String toString() => 'VideoRemoteFailure($code): $message';
}

@immutable
class VideoRemoteAudioTrack {
  const VideoRemoteAudioTrack({
    required this.id,
    required this.label,
    required this.selected,
    this.language,
    this.title,
  });

  final String id;
  final String label;
  final bool selected;
  final String? language;
  final String? title;
}

/// 字幕轨的形态。
///
/// * [embedded]：容器内封文本轨；[graphic]：图形（位图）轨；[external]：外挂文件
///   （本机导入 / 同目录 / 流的外挂字幕链接）；[host]：互联 host 下发的外挂字幕；
///   [youtube]：YouTube 字幕轨。
enum VideoRemoteSubtitleKind { embedded, graphic, external, host, youtube }

@immutable
class VideoRemoteSubtitleTrack {
  const VideoRemoteSubtitleTrack({
    required this.source,
    required this.label,
    required this.kind,
    required this.primary,
    required this.secondary,
    required this.ocrAvailable,
    this.selectable = true,
    this.secondarySelectable = true,
    this.language,
    this.codec,
  });

  /// 持久化值（`embedded:<n>` / 外挂文件绝对路径），选轨时原样传回。
  final String source;
  final String label;
  final VideoRemoteSubtitleKind kind;

  /// 当前是否为主 / 副字幕。
  final bool primary;
  final bool secondary;

  /// 图形轨能否整轨 OCR（编码受支持且取得到整轨输入）。
  final bool ocrAvailable;

  /// 能否选为主 / 副字幕（与面板里该行是否可点一致）。
  final bool selectable;
  final bool secondarySelectable;
  final String? language;
  final String? codec;
}

@immutable
class VideoRemoteSubtitleState {
  const VideoRemoteSubtitleState({
    required this.tracks,
    required this.primarySource,
    required this.secondarySource,
    required this.remote,
    required this.asrAvailable,
    required this.alignAvailable,
    this.clipAvailable = false,
  });

  final List<VideoRemoteSubtitleTrack> tracks;
  final String? primarySource;
  final String? secondarySource;

  /// 远端（互联 / 媒体服务器 / 流）视频：轨表按远端轨类型列出（YouTube / host 外挂 /
  /// 内封 / 本机导入），对轴与片段导出不可用（面板同样没有）。
  final bool remote;

  /// 能否语音转录 / 重定时（本机 ASR 可用且取得到音轨）。
  final bool asrAvailable;

  /// 能否按内封轨对轴（有本机视频文件）。
  final bool alignAvailable;

  /// 能否导出片段（本机视频文件）。
  final bool clipAvailable;
}

/// [VideoPlayerRemoteControl.mineCurrentCue] 的结果（与弹窗收到的 MinePopupResult
/// 同口径）。
@immutable
class VideoRemoteMineResult {
  const VideoRemoteMineResult({
    required this.success,
    required this.queued,
    required this.duplicate,
    this.noteId,
    this.sentence,
  });

  /// 卡已落进 Anki（或已进待发队列，见 [queued]）。
  final bool success;

  /// 在线视频后台制卡 / 看完再制卡：请求已收下，卡稍后落地（暂存队列可查）。
  final bool queued;
  final bool duplicate;
  final int? noteId;
  final String? sentence;
}

/// 长任务种类。
enum VideoRemoteJobKind { subtitleOcr, transcribe, retime, align, clip }

enum VideoRemoteJobStatus { running, succeeded, failed, cancelled }

/// CLI 发起的一个视频页长任务（字幕 OCR / 转录 / 重定时 / 对轴 / 片段导出）：
/// 进度、取消与最终结论。由视频页实现创建并推进；进程级 [videoRemoteJobs] 保留
/// 最近的任务，页面关掉后结论仍可查。
class VideoRemoteJob extends ChangeNotifier {
  VideoRemoteJob({
    required this.kind,
    required this.bookUid,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       startedAt = (now ?? DateTime.now)();

  final VideoRemoteJobKind kind;
  final String bookUid;
  final DateTime startedAt;
  final DateTime Function() _now;

  /// 进程内短 id（`vj1`…），登记进 [videoRemoteJobs] 时分配。
  String id = '';

  VideoRemoteJobStatus _status = VideoRemoteJobStatus.running;
  String _phase = 'starting';
  double? _fraction;
  String? _detail;
  String? _error;
  String? _errorCode;
  DateTime? _finishedAt;
  Map<String, Object?> _result = const <String, Object?>{};
  final List<String> _messages = <String>[];
  void Function()? _onCancel;
  bool _cancelRequested = false;
  final Completer<void> _done = Completer<void>();

  VideoRemoteJobStatus get status => _status;
  bool get isRunning => _status == VideoRemoteJobStatus.running;
  String get phase => _phase;
  double? get fraction => _fraction;
  String? get detail => _detail;
  String? get error => _error;
  String? get errorCode => _errorCode;
  DateTime? get finishedAt => _finishedAt;
  Map<String, Object?> get result => _result;
  bool get cancelRequested => _cancelRequested;

  /// 任务期间页面弹出的提示（OSD），按出现顺序。
  List<String> get messages => List<String>.unmodifiable(_messages);

  /// 任务结束（成功 / 失败 / 取消）时完成；不带错误。
  Future<void> get done => _done.future;

  /// 登记取消执行体（页内对应任务的取消入口）。
  set onCancel(void Function()? value) => _onCancel = value;

  /// 是否支持取消（已登记取消执行体）。
  bool get cancellable => _onCancel != null;

  void update({String? phase, double? fraction, String? detail}) {
    if (!isRunning) return;
    if (phase != null) _phase = phase;
    _fraction = fraction?.clamp(0.0, 1.0).toDouble();
    if (detail != null) _detail = detail;
    notifyListeners();
  }

  void addMessage(String message) {
    if (message.isEmpty) return;
    _messages.add(message);
    if (_messages.length > 20) _messages.removeAt(0);
  }

  /// 请求取消；任务不可取消或已结束返回 false。
  bool cancel() {
    final void Function()? onCancel = _onCancel;
    if (!isRunning || onCancel == null) return false;
    _cancelRequested = true;
    onCancel();
    notifyListeners();
    return true;
  }

  void succeed([Map<String, Object?> result = const <String, Object?>{}]) =>
      _finish(VideoRemoteJobStatus.succeeded, result: result);

  void fail(String code, String message) => _finish(
    code == 'cancelled'
        ? VideoRemoteJobStatus.cancelled
        : VideoRemoteJobStatus.failed,
    errorCode: code,
    error: message,
  );

  void _finish(
    VideoRemoteJobStatus status, {
    Map<String, Object?> result = const <String, Object?>{},
    String? errorCode,
    String? error,
  }) {
    if (!isRunning) return;
    _status = status;
    _result = Map<String, Object?>.unmodifiable(result);
    _errorCode = errorCode;
    _error = error;
    _finishedAt = _now();
    _phase = status.name;
    _onCancel = null;
    if (!_done.isCompleted) _done.complete();
    notifyListeners();
  }
}

/// 视频页长任务登记表（进程级）：按 id 取回，保留最近 [capacity] 个。
class VideoRemoteJobRegistry {
  VideoRemoteJobRegistry({this.capacity = 20});

  final int capacity;
  final List<VideoRemoteJob> _jobs = <VideoRemoteJob>[];
  int _next = 0;

  /// 登记并分配 id。
  VideoRemoteJob register(VideoRemoteJob job) {
    job.id = 'vj${++_next}';
    _jobs.add(job);
    while (_jobs.length > capacity) {
      final int finished = _jobs.indexWhere((VideoRemoteJob j) => !j.isRunning);
      if (finished < 0) break;
      _jobs.removeAt(finished);
    }
    return job;
  }

  VideoRemoteJob? operator [](String id) {
    final String key = id.trim();
    for (final VideoRemoteJob job in _jobs) {
      if (job.id == key) return job;
    }
    return null;
  }

  /// 正在跑的同类任务（同一视频页同类任务不并发）。
  VideoRemoteJob? running(VideoRemoteJobKind kind) {
    for (final VideoRemoteJob job in _jobs) {
      if (job.kind == kind && job.isRunning) return job;
    }
    return null;
  }

  /// 最近的任务，新的在前。
  List<VideoRemoteJob> get recent => _jobs.reversed.toList(growable: false);
}

/// 进程级唯一登记点。
final VideoRemoteJobRegistry videoRemoteJobs = VideoRemoteJobRegistry();

/// 视频播放页遥控登记表：按登记顺序成栈，[current] 恒为最后登记、仍存活的那页
/// （叠加打开多个视频页时以最上层为准）；[unregister] 只移除传入的那一个。
class VideoPlaybackRemoteRegistry {
  final List<VideoPlaybackRemote> _stack = <VideoPlaybackRemote>[];

  /// 当前可遥控的视频页；没有视频页时为 null。
  final ValueNotifier<VideoPlaybackRemote?> current =
      ValueNotifier<VideoPlaybackRemote?>(null);

  /// 登记 [remote] 到栈顶；已登记过的重复调用是 no-op（不改变栈序）。
  void register(VideoPlaybackRemote remote) {
    if (_stack.contains(remote)) return;
    _stack.add(remote);
    current.value = remote;
  }

  /// 注销 [remote]（未登记时 no-op）；栈顶随之回落到下一个仍登记的页面。
  void unregister(VideoPlaybackRemote remote) {
    if (!_stack.remove(remote)) return;
    current.value = _stack.isEmpty ? null : _stack.last;
  }

  @visibleForTesting
  int get debugLength => _stack.length;
}

/// 进程级唯一登记点。
final VideoPlaybackRemoteRegistry videoPlaybackRemotes =
    VideoPlaybackRemoteRegistry();
