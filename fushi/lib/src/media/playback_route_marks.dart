import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:fushi/src/stats/study_cover_tracker.dart';

/// 「播放页」路由登记：视频 / 播放页（`VideoFushiPage`、`WebVideoFushiPage`）把自己所在
/// 的路由登记进来，别的页面据此判断自己是不是被**播放页**盖住了（不是任意整页路由）。
///
/// 由页面自己登记而不是在推路由处打标记：打开播放页的入口有几十处，各入口记得打标记
/// 迟早漏一个；页面 `didChangeDependencies` 里登记只写一次。
///
/// 起因 BUG-4015：浏览器开着 Netflix 首页时从别处打开视频，浏览页被视频页盖住，首页
/// 预告片照样自动播。浏览页只在被播放页盖住时让网页停下（盖上设置页、标签网格等不停）。
class PlaybackRouteMarks extends ChangeNotifier {
  final Set<Route<dynamic>> _routes = <Route<dynamic>>{};

  /// [route] 是不是登记过的播放页路由。
  bool isPlayback(Route<dynamic> route) => _routes.contains(route);

  void mark(Route<dynamic> route) {
    if (_routes.add(route)) notifyListeners();
  }

  void unmark(Route<dynamic> route) {
    if (_routes.remove(route)) notifyListeners();
  }
}

/// 全局唯一实例：播放页登记、浏览页订阅都用它。
final PlaybackRouteMarks playbackRouteMarks = PlaybackRouteMarks();

/// 播放页用的登记小帮手：在 `didChangeDependencies` 里 [attach] `ModalRoute.of(context)`，
/// `dispose` 时 [dispose]。
class PlaybackRouteMark {
  PlaybackRouteMark({PlaybackRouteMarks? marks})
    : _marks = marks ?? playbackRouteMarks;

  final PlaybackRouteMarks _marks;
  Route<dynamic>? _route;

  void attach(Route<dynamic>? route) {
    if (identical(route, _route)) return;
    final Route<dynamic>? previous = _route;
    _route = route;
    if (previous != null) _marks.unmark(previous);
    if (route != null) _marks.mark(route);
  }

  void dispose() => attach(null);
}

/// 「我（[attach] 的路由）之上压着播放页」的订阅：根 Navigator 栈取自
/// [StudyCoverTracker]（根栈的唯一镜像），播放页取自 [PlaybackRouteMarks]。
///
/// 播放页的路由先入栈（`didPush`）、页面建好才登记，两边任一变化都重算：推上去当帧
/// 判不到、登记那一刻补上；出栈（`didPop`）当帧就判为露出，不等页面拆完。
///
/// 回调可能在 Navigator 刷新历史或页面 build 期间同步触发，里面**不许** `setState`。
class PlaybackCoverWatch {
  PlaybackCoverWatch({
    required this.onChanged,
    StudyCoverTracker? tracker,
    PlaybackRouteMarks? marks,
  }) : _tracker = tracker ?? studyCoverTracker,
       _marks = marks ?? playbackRouteMarks {
    _tracker.addListener(_handle);
    _marks.addListener(_handle);
  }

  final StudyCoverTracker _tracker;
  final PlaybackRouteMarks _marks;
  final VoidCallback onChanged;
  Route<dynamic>? _route;
  bool _covered = false;

  /// 当前是否被播放页盖住（上一次通知时的结论）。
  bool get covered => _covered;

  /// 在 `didChangeDependencies` 里用 `ModalRoute.of(context)` 喂进来。
  void attach(Route<dynamic>? route) {
    if (identical(route, _route)) return;
    _route = route;
    _handle();
  }

  void dispose() {
    _tracker.removeListener(_handle);
    _marks.removeListener(_handle);
  }

  void _handle() {
    final bool next = _tracker.routesAbove(_route).any(_marks.isPlayback);
    if (next == _covered) return;
    _covered = next;
    onChanged();
  }
}
