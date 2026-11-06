import 'dart:async';

import 'package:flutter/foundation.dart';

/// 浏览器里哪些标签页的网页视频正在播放（扩展沉浸计时 study-tracker.js 的样本推来）。
///
/// 用途只有一个：视频在播时，同一标签页的「网页阅读」计时（`WebStudySession`）让位——视频
/// 时长已经由扩展沉浸计时记进统计（视频域），阅读面再走表就是同一段时间算两遍。
///
/// 样本是每秒一条的状态快照；超过 [staleAfter] 没有新的「在播」样本（页面关了、脚本没了、
/// 视频被删）就当停了，不会因为丢了「暂停」那一条而永远卡在在播。
class WebBrowserVideoActivity extends ChangeNotifier {
  WebBrowserVideoActivity({this.staleAfter = const Duration(seconds: 5)});

  final Duration staleAfter;
  final Map<String, Timer> _playing = <String, Timer>{};

  bool isPlaying(String tabId) => _playing.containsKey(tabId);

  /// 一条样本到达。
  void report(String tabId, {required bool playing}) {
    final bool was = _playing.containsKey(tabId);
    _playing.remove(tabId)?.cancel();
    if (playing) {
      _playing[tabId] = Timer(staleAfter, () {
        _playing.remove(tabId);
        notifyListeners();
      });
    }
    if (was != playing) notifyListeners();
  }

  /// 标签页关了。
  void clear(String tabId) {
    final Timer? t = _playing.remove(tabId);
    if (t == null) return;
    t.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final Timer t in _playing.values) {
      t.cancel();
    }
    _playing.clear();
    super.dispose();
  }
}
