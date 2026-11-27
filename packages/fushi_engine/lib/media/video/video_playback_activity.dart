/// 进程里有没有打开着的视频播放会话：给「会和播放抢带宽 / 读盘的后台任务」让路用
/// （网络卷上的整文件哈希，见 `video_content_fingerprint.dart`）。
///
/// 会话从播放器控制器建好起、到它销毁为止都算，**暂停也算**：人暂停一下马上要接着看，
/// 这期间后台把带宽占满，恢复播放时缓冲已经被饿空。
///
/// 纯 Dart，不依赖 Flutter；app 侧的播放器控制器在构造时 [begin]、销毁时调返回的结束函数。
library;

import 'dart:async';

/// 视频播放会话计数 + 「变忙」「变闲」两个通知。
final class VideoPlaybackActivity {
  VideoPlaybackActivity();

  /// 进程内唯一那份（播放器与后台任务共用）。
  static final VideoPlaybackActivity instance = VideoPlaybackActivity();

  int _sessions = 0;
  Completer<void>? _idle;
  final Set<_Listener> _onBusy = <_Listener>{};

  /// 此刻有没有打开着的播放会话。
  bool get isActive => _sessions > 0;

  /// 开一个播放会话；返回结束函数（幂等，必须调，否则后台任务一直让路）。
  void Function() begin() {
    final bool wasIdle = _sessions == 0;
    _sessions++;
    if (wasIdle) {
      for (final _Listener l in _onBusy.toList()) {
        l.callback();
      }
    }
    bool ended = false;
    return () {
      if (ended) return;
      ended = true;
      _sessions--;
      if (_sessions == 0) {
        final Completer<void>? idle = _idle;
        _idle = null;
        idle?.complete();
      }
    };
  }

  /// 没有播放会话时完成（已经空闲则立即完成）。
  Future<void> whenIdle() {
    if (_sessions == 0) return Future<void>.value();
    return (_idle ??= Completer<void>()).future;
  }

  /// 从空闲变成有会话时同步调 [callback]；返回摘除函数（幂等，用完必须调）。
  void Function() onBecameActive(void Function() callback) {
    final _Listener entry = _Listener(callback);
    _onBusy.add(entry);
    return () => _onBusy.remove(entry);
  }
}

final class _Listener {
  _Listener(this.callback);
  final void Function() callback;
}
