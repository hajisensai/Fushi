/// 全 app 下载保活的汇总点（BUG-2714）。
///
/// Android 上一个进程只该挂**一个**下载保活前台服务，但下载来源有好几个（互联
/// 拉片、自动更新、漫画卷、发现页直链…），各自不知道别人在不在跑。直接共用
/// [DownloadKeepAlive] 会互相踩：谁先下完谁调 `stop()`，把别人的保活一起撤了。
///
/// 所以每个来源领一个租约（[DownloadKeepAliveHub.lease]，本身就是
/// [DownloadKeepAlive]），hub 汇总所有活跃租约再驱动唯一的底层实现：只剩一个
/// 来源时通知就是它的标题 / 进度；多个来源时标题报「N 项下载进行中」、进度按
/// 各来源已知百分比取平均（有一个不确定就整体不确定）。最后一个租约 stop 时
/// 才真正撤服务。
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';

class DownloadKeepAliveHub {
  DownloadKeepAliveHub(this._backend);

  final DownloadKeepAlive _backend;
  final Map<String, _LeaseState> _active = <String, _LeaseState>{};
  bool _backendActive = false;

  /// 取来源 [key] 的租约。同一 key 多次取到的是同一份状态（后写覆盖前写）。
  DownloadKeepAlive lease(String key) => _DownloadKeepAliveLease(this, key);

  /// 当前活跃的来源（测试 / 诊断用）。
  Iterable<String> get activeSources => _active.keys;

  Future<void> _update(String key, _LeaseState state) {
    _active[key] = state;
    return _sync();
  }

  Future<void> _stop(String key) {
    if (_active.remove(key) == null) return Future<void>.value();
    return _sync();
  }

  Future<void> _sync() {
    if (_active.isEmpty) {
      if (!_backendActive) return Future<void>.value();
      _backendActive = false;
      return _backend.stop();
    }
    _backendActive = true;
    if (_active.length == 1) {
      final _LeaseState only = _active.values.single;
      return _backend.update(
        title: only.title,
        text: only.text,
        percent: only.percent,
      );
    }
    int? percent;
    int sum = 0;
    bool allKnown = true;
    for (final _LeaseState state in _active.values) {
      final int? p = state.percent;
      if (p == null || p < 0 || p > 100) {
        allKnown = false;
        break;
      }
      sum += p;
    }
    if (allKnown) percent = sum ~/ _active.length;
    return _backend.update(
      title: t.download_keep_alive_multiple_title(count: _active.length),
      text: _active.values.map((_LeaseState s) => s.title).join(' · '),
      percent: percent,
    );
  }
}

class _LeaseState {
  const _LeaseState(this.title, this.text, this.percent);

  final String title;
  final String text;
  final int? percent;
}

class _DownloadKeepAliveLease implements DownloadKeepAlive {
  _DownloadKeepAliveLease(this._hub, this._key);

  final DownloadKeepAliveHub _hub;
  final String _key;

  @override
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  }) =>
      _hub._update(_key, _LeaseState(title, text, percent));

  @override
  Future<void> stop() => _hub._stop(_key);
}

/// app 进程唯一的 hub（Android 驱动前台服务，其余平台 no-op）。
final DownloadKeepAliveHub downloadKeepAliveHub =
    DownloadKeepAliveHub(createDownloadKeepAlive());
