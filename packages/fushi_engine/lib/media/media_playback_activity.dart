/// 进程里有没有正在进行的媒体播放：给「会和播放抢带宽 / 读盘的后台任务」让路用
/// （网络卷上的整文件哈希，见 `media/video/video_content_fingerprint.dart`）。
///
/// 两种会话：
///
/// - **显式会话**（[begin]）：本机视频页，从播放器控制器建好起到它销毁为止，**暂停也算**：
///   人暂停一下马上要接着看，这期间后台把带宽占满，恢复时缓冲已经被饿空。
/// - **活动窗口**（[touch]）：看不到明确起止的播放——互联 host 按 HTTP 请求给另一台设备送
///   字节 / 转码分段（请求之间、seek 之间都有空隙），以及常驻 app 的音乐 / 有声书播放器
///   暂停之后。每次活动续一个 [kMediaPlaybackLingerWindow]，窗口内没有新活动才算结束：
///   盖住分段之间的空隙，又不会因为一个常驻播放器停在暂停上就让后台任务永远等下去。
///
/// 纯 Dart，不依赖 Flutter。
library;

import 'dart:async';

import 'package:meta/meta.dart' show visibleForTesting;

/// [MediaPlaybackActivity.touch] 默认的活动窗口。HLS 分段 / 播放器 Range 请求在正常播放时
/// 远比它密，暂停超过它才放行后台任务（之后恢复播放会立刻再把它们打断）。
const Duration kMediaPlaybackLingerWindow = Duration(seconds: 60);

/// 媒体播放会话计数 + 「变忙」「变闲」两个通知。
///
/// 活动窗口只记到期时刻，不为每个窗口起计时器：只有真有人在等空闲（[whenIdle]）时才排
/// 一个计时器叫醒它。各播放入口在测试里也会开窗口，不能因此在每个测试里留下挂着的计时器。
final class MediaPlaybackActivity {
  MediaPlaybackActivity({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 进程内唯一那份（各播放入口与后台任务共用）。
  static final MediaPlaybackActivity instance = MediaPlaybackActivity();

  final DateTime Function() _now;
  int _sessions = 0;
  final Map<Object, DateTime> _windows = <Object, DateTime>{};
  Completer<void>? _idle;
  Timer? _wake;
  final Set<_Listener> _onBusy = <_Listener>{};

  /// 此刻有没有播放会话（显式会话或未到期的活动窗口）。
  bool get isActive => _sessions > 0 || _hasLiveWindow();

  bool _hasLiveWindow() {
    if (_windows.isEmpty) return false;
    final DateTime now = _now();
    _windows.removeWhere((Object _, DateTime expires) => !expires.isAfter(now));
    return _windows.isNotEmpty;
  }

  void _notifyBusy() {
    for (final _Listener l in _onBusy.toList()) {
      l.callback();
    }
  }

  /// 开一个显式会话；返回结束函数（幂等，必须调，否则后台任务一直让路）。
  void Function() begin() {
    final bool wasIdle = !isActive;
    _sessions++;
    if (wasIdle) _notifyBusy();
    bool ended = false;
    return () {
      if (ended) return;
      ended = true;
      _sessions--;
      _checkIdle();
    };
  }

  /// 以 [key] 续一个活动窗口：到期时刻推到 [window] 之后，窗口内没有再续就算结束。
  /// 同一个播放（同一个文件 / 同一条流 / 同一个播放器）用同一个 key。
  void touch(Object key, {Duration window = kMediaPlaybackLingerWindow}) {
    final bool wasIdle = !isActive;
    _windows[key] = _now().add(window);
    if (wasIdle) _notifyBusy();
    _checkIdle();
  }

  /// 没有播放会话时完成（已经空闲则立即完成）。
  Future<void> whenIdle() {
    if (!isActive) return Future<void>.value();
    final Completer<void> idle = _idle ??= Completer<void>();
    _checkIdle();
    return idle.future;
  }

  /// 有人在等空闲时：已空闲就叫醒；只剩活动窗口就排一个计时器到最晚的到期时刻再看。
  void _checkIdle() {
    _wake?.cancel();
    _wake = null;
    final Completer<void>? idle = _idle;
    if (idle == null) return;
    if (!isActive) {
      _idle = null;
      idle.complete();
      return;
    }
    if (_sessions > 0) return; // 显式会话结束时会再来看。
    final DateTime now = _now();
    final DateTime latest = _windows.values.reduce(
      (DateTime a, DateTime b) => a.isAfter(b) ? a : b,
    );
    _wake = Timer(latest.difference(now), _checkIdle);
  }

  /// 测试：清掉全部会话与窗口（进程单例在测试之间复用）。
  @visibleForTesting
  void debugReset() {
    _sessions = 0;
    _windows.clear();
    _wake?.cancel();
    _wake = null;
    final Completer<void>? idle = _idle;
    _idle = null;
    idle?.complete();
  }

  /// 从空闲变成有会话时同步调 [callback]；返回摘除函数（幂等，用完必须调）。
  void Function() onBecameActive(void Function() callback) {
    final _Listener entry = _Listener(callback);
    _onBusy.add(entry);
    return () => _onBusy.remove(entry);
  }
}

/// 常驻播放器（音乐 / 有声书）的会话：在播时持有显式会话，暂停 / 停止后改成一个活动窗口
/// （[MediaPlaybackActivity.touch]），[dispose] 时立即结束。
final class MediaPlaybackHold {
  MediaPlaybackHold({MediaPlaybackActivity? activity})
    : _activity = activity ?? MediaPlaybackActivity.instance;

  final MediaPlaybackActivity _activity;
  void Function()? _end;
  bool _disposed = false;

  /// 播放器的 playing 状态变了就调。
  void setPlaying(bool playing) {
    if (_disposed) return;
    if (playing) {
      _end ??= _activity.begin();
      return;
    }
    final void Function()? end = _end;
    if (end == null) return;
    _end = null;
    // 先续窗口再结束显式会话：中间不出现「空闲」的瞬间，后台任务不会被放行又打断。
    _activity.touch(this);
    end();
  }

  /// 播放器销毁：结束显式会话（暂停窗口照常到期）。
  void dispose() {
    _disposed = true;
    _end?.call();
    _end = null;
  }
}

final class _Listener {
  _Listener(this.callback);
  final void Function() callback;
}
