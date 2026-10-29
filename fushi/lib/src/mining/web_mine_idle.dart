import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// 网页视频制卡队列「空闲自动制卡」的判定与调度（设计见
/// `docs/specs/2026-10-27-web-mine-idle-silent-replay.md`）。
///
/// 「空闲」= 网页播放页开着、用户已暂停（本页没在播）、队列非空，且**整台机器**连续
/// [kWebMineIdleThreshold] 没有键鼠 / 触控输入（`GetLastInputInfo`，与锁屏 / 屏保同一个
/// 判据——用户切到别的程序打字也算「在用电脑」，不会被抢）。重放静音进行（process
/// loopback + 会话压低，见 `audio_loopback_capture.h`），用户一有输入就让位：当前这句
/// 录完即停，剩下的留在队列里等下一次空闲。

/// 判定「用户离开了」的系统级无输入时长。
const Duration kWebMineIdleThreshold = Duration(minutes: 2);

/// 空闲自动制卡页（交接页 / 后台制卡页）从打开到开跑的截止：站点加载 + 画面就绪通常
/// 十几秒；到点没开跑（加载失败、停在登录 / 选人页）就整轮放弃，不让页面无人值守地挂着。
const Duration kWebMineAutoStartTimeout = Duration(seconds: 60);

final class _LastInputInfo extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int dwTime;
}

typedef _GetLastInputInfoNative = Int32 Function(Pointer<_LastInputInfo>);
typedef _GetLastInputInfoDart = int Function(Pointer<_LastInputInfo>);
typedef _GetTickCountNative = Uint32 Function();
typedef _GetTickCountDart = int Function();

/// 走裸 FFI 而不是 `package:win32`（本仓只是传递依赖，与 `galgame_play_tracker.dart` 同理）。
/// 一次空闲判定两个 Win32 调用，微秒级，不跨 isolate。
final _GetLastInputInfoDart? _getLastInputInfo = Platform.isWindows
    ? DynamicLibrary.open(
        'user32.dll',
      ).lookupFunction<_GetLastInputInfoNative, _GetLastInputInfoDart>(
        'GetLastInputInfo',
      )
    : null;
final _GetTickCountDart? _getTickCount = Platform.isWindows
    ? DynamicLibrary.open(
        'kernel32.dll',
      ).lookupFunction<_GetTickCountNative, _GetTickCountDart>('GetTickCount')
    : null;

/// 距整台机器最后一次用户输入多久。非 Windows / 调用失败回 null（= 判不了空闲，
/// 调度器永不自动开跑）。
Duration? systemInputIdleDuration() {
  final _GetLastInputInfoDart? getLastInput = _getLastInputInfo;
  final _GetTickCountDart? getTick = _getTickCount;
  if (getLastInput == null || getTick == null) return null;
  final Pointer<_LastInputInfo> info = calloc<_LastInputInfo>();
  try {
    info.ref.cbSize = sizeOf<_LastInputInfo>();
    if (getLastInput(info) == 0) return null;
    return webMineInputIdleFromTicks(
      now: getTick(),
      lastInput: info.ref.dwTime,
    );
  } finally {
    calloc.free(info);
  }
}

/// 两个 32 位毫秒计数之差（`GetTickCount` 49.7 天回绕一次，按无符号差算）。
@visibleForTesting
Duration webMineInputIdleFromTicks({
  required int now,
  required int lastInput,
}) => Duration(milliseconds: (now - lastInput) & 0xFFFFFFFF);

/// 空闲自动制卡调度：低频轮询系统空闲时长，满足条件就 [onIdle] 开跑；跑的期间高频
/// 轮询，空闲时长**变短**（= 来了一次输入）就 [onUserActive] 让位。页面跑完 / 停下后
/// 调 [runFinished]，之后要重新攒满 [threshold] 才会再开跑。
///
/// 纯编排、无 UI：[inputIdle] / [createTimer] 可注入，测试里用假时钟推进。
class WebMineIdleScheduler {
  WebMineIdleScheduler({
    required this.canStart,
    required this.onIdle,
    required this.onUserActive,
    Duration? Function()? inputIdle,
    this.threshold = kWebMineIdleThreshold,
    this.idlePoll = const Duration(seconds: 5),
    this.activePoll = const Duration(milliseconds: 500),
    this.pageLevel = true,
    Timer Function(Duration d, void Function() f)? createTimer,
  }) : _inputIdle = inputIdle ?? systemInputIdleDuration,
       _createTimer = createTimer ?? Timer.new;

  /// 本进程里静音录音起不来过（系统不支持 process loopback / 找不到 WebView2 进程）。
  /// 进程级：窗口宿主档的空闲交接每次都要重开页面，按页记会在用户离开期间反复换页重试。
  static bool silentCaptureUnavailable = false;

  /// 已 [start] 未 [dispose] 的**页面级**调度器数（网页播放页开着）：那一页自己负责
  /// 空闲制卡，后台调度（[pageLevel] = false）此时不另开一页叠在它上面。
  static int livePageSchedulers = 0;

  /// 挂在播放页上（true）还是 app 级后台（false，见 `web_mine_background.dart`）。
  final bool pageLevel;
  bool _counted = false;

  /// 页面侧的其余条件（队列非空、没在播、没在跑、静音录音可用……）。
  final bool Function() canStart;
  final void Function() onIdle;
  final void Function() onUserActive;
  final Duration threshold;
  final Duration idlePoll;
  final Duration activePoll;

  final Duration? Function() _inputIdle;
  final Timer Function(Duration d, void Function() f) _createTimer;

  Timer? _timer;
  bool _running = false;
  bool _yielded = false;
  bool _disposed = false;
  Duration _lastIdle = Duration.zero;

  /// 当前是否有一轮由本调度器触发的自动制卡在跑。
  bool get running => _running;

  void start() {
    if (_disposed || _timer != null) return;
    if (pageLevel && !_counted) {
      _counted = true;
      livePageSchedulers++;
    }
    _schedule(idlePoll);
  }

  /// 一轮不是本调度器起的、而是交接过来的（窗口宿主档空闲 → 换内置档的新页面）：从现在
  /// 起按「在跑」盯输入。交接途中空闲时长已经回落到阈值以下 = 用户在交接期间回来了，
  /// 立即 [onUserActive]。
  void adoptRun() {
    if (_disposed) return;
    _running = true;
    _yielded = false;
    final Duration? idle = _inputIdle();
    _lastIdle = idle ?? Duration.zero;
    _timer?.cancel();
    _schedule(activePoll);
    if (idle != null && idle < threshold) {
      _yielded = true;
      onUserActive();
    }
  }

  /// 页面结束了一轮（跑完 / 用户让位后停下 / 中途失败）。
  void runFinished() {
    _running = false;
    _yielded = false;
    if (_disposed) return;
    _timer?.cancel();
    _schedule(idlePoll);
  }

  void dispose() {
    if (_counted) {
      _counted = false;
      livePageSchedulers--;
    }
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  void _schedule(Duration d) {
    _timer = _createTimer(d, () {
      _timer = null;
      tick();
      if (!_disposed && _timer == null) {
        _schedule(_running ? activePoll : idlePoll);
      }
    });
  }

  @visibleForTesting
  void tick() {
    if (_disposed) return;
    final Duration? idle = _inputIdle();
    if (idle == null) return;
    if (_running) {
      if (!_yielded && idle < _lastIdle) {
        _yielded = true;
        onUserActive();
      }
      _lastIdle = idle;
      return;
    }
    if (idle >= threshold && canStart()) {
      _running = true;
      _yielded = false;
      _lastIdle = idle;
      onIdle();
    }
  }
}
