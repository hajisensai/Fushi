/// 互联 host 的慢请求观测（BUG-5606）。
///
/// app 当 host 时 HTTP 服务与 UI 同一个 isolate：哪个路由在这个 isolate 上干了重活，
/// 用户只看得到「电脑界面卡了一下」。这里把两样东西记进诊断日志：
///
/// - **慢请求**：处理耗时（到交出响应头为止，不含流式响应体的传输）超过
///   [HostRequestObserver.slowThreshold]，或处理期间事件循环延迟超过
///   [HostRequestObserver.lagThreshold] 的请求——路由、状态码、耗时、事件循环最大延迟。
/// - **请求频率**：每 [HostRequestObserver.summaryInterval] 一行各路由的次数与累计耗时，
///   看对端（client 的自动同步、预取）多久打一次哪条路由。
///
/// 事件循环延迟用一个只在**有普通请求在飞时**才跑的周期计时器量（计时器实际触发
/// 时刻比预定晚多少）；空闲时不留任何计时器。请求结束那一刻再补量一次「距上次触发
/// 已经过去多久」，压在请求末尾的同步停顿也量得到。
///
/// **挂起类请求**（[isHostSuspendingRequest]：复习同步长轮询 `GET /api/srs/changes`、
/// 带 `wait` 的助手会话长轮询）按设计就要挂住几十秒等事件，墙钟耗时与本 isolate
/// 忙不忙无关：它们不按耗时判慢、不让计时器常驻（client 一直挂着长轮询，否则计时器
/// 就永远停不下来）、也不分摊别的请求处理期间量到的 loopLag——只进请求频率汇总
/// （键后标 `(hold)`，累计耗时是挂起时长，不是处理耗时）。
library;

import 'dart:async';

import 'package:shelf/shelf.dart' as shelf;

/// 慢请求 / 请求频率观测器。一台 host 一个，[middleware] 挂在 pipeline 最外层。
final class HostRequestObserver {
  HostRequestObserver({
    required void Function(String line) log,
    this.slowThreshold = const Duration(milliseconds: 1000),
    this.lagThreshold = const Duration(milliseconds: 100),
    this.summaryInterval = const Duration(minutes: 10),
    this.tick = const Duration(milliseconds: 50),
    bool Function(shelf.Request request) isSuspending = isHostSuspendingRequest,
    DateTime Function()? clock,
  }) : _log = log,
       _isSuspending = isSuspending,
       _clock = clock ?? DateTime.now;

  final void Function(String line) _log;
  final bool Function(shelf.Request request) _isSuspending;
  final DateTime Function() _clock;

  /// 处理耗时超过它的请求记一行。
  final Duration slowThreshold;

  /// 处理期间事件循环延迟超过它的请求记一行（哪怕总耗时不长）。
  final Duration lagThreshold;

  /// 请求频率汇总的周期。
  final Duration summaryInterval;

  /// 事件循环延迟计时器的周期。
  final Duration tick;

  final Set<_ActiveRequest> _active = <_ActiveRequest>{};
  final Stopwatch _sinceTick = Stopwatch();
  Timer? _timer;

  final Map<String, _RouteStats> _stats = <String, _RouteStats>{};
  DateTime? _windowStart;

  shelf.Middleware middleware() =>
      (shelf.Handler inner) => (shelf.Request request) async {
        if (_isSuspending(request)) return _observeSuspending(inner, request);
        final _ActiveRequest active = _ActiveRequest();
        _begin(active);
        int status = 500;
        try {
          final shelf.Response response = await inner(request);
          status = response.statusCode;
          return response;
        } finally {
          _end(active, request, status);
        }
      };

  /// 挂起类请求：只记频率，不碰计时器、不判慢（见库注释）。
  Future<shelf.Response> _observeSuspending(
    shelf.Handler inner,
    shelf.Request request,
  ) async {
    final Stopwatch watch = Stopwatch()..start();
    try {
      return await inner(request);
    } finally {
      _record(
        '${request.method} ${hostRequestRouteKey(request)} (hold)',
        watch.elapsed,
      );
    }
  }

  void _begin(_ActiveRequest active) {
    _active.add(active);
    if (_timer != null) return;
    _sinceTick
      ..reset()
      ..start();
    _timer = Timer.periodic(tick, (Timer _) => _onTick());
  }

  void _onTick() {
    final Duration lag = _currentLag();
    _sinceTick
      ..reset()
      ..start();
    for (final _ActiveRequest r in _active) {
      if (lag > r.maxLag) r.maxLag = lag;
    }
  }

  /// 距上次计时器触发已过去的时间比周期多出的部分（即事件循环迟到了多久）。
  Duration _currentLag() {
    final Duration over = _sinceTick.elapsed - tick;
    return over.isNegative ? Duration.zero : over;
  }

  void _end(_ActiveRequest active, shelf.Request request, int status) {
    final Duration tail = _currentLag();
    if (tail > active.maxLag) active.maxLag = tail;
    _active.remove(active);
    if (_active.isEmpty) {
      _timer?.cancel();
      _timer = null;
      _sinceTick.stop();
    }
    final Duration elapsed = active.watch.elapsed;
    final String route = hostRequestRouteKey(request);
    if (elapsed >= slowThreshold || active.maxLag >= lagThreshold) {
      _log(
        'slow ${request.method} $route status=$status '
        '${elapsed.inMilliseconds}ms loopLag=${active.maxLag.inMilliseconds}ms',
      );
    }
    _record('${request.method} $route', elapsed);
  }

  void _record(String key, Duration elapsed) {
    final DateTime now = _clock();
    final DateTime start = _windowStart ??= now;
    (_stats[key] ??= _RouteStats()).add(elapsed);
    if (now.difference(start) < summaryInterval) return;
    final List<MapEntry<String, _RouteStats>> rows = _stats.entries.toList()
      ..sort(
        (MapEntry<String, _RouteStats> a, MapEntry<String, _RouteStats> b) =>
            b.value.count.compareTo(a.value.count),
      );
    final int minutes = now.difference(start).inMinutes;
    _log(
      'requests in last ${minutes}min: ${<String>[for (final MapEntry<String, _RouteStats> e in rows.take(20)) '${e.key} x${e.value.count} ${e.value.total.inMilliseconds}ms'].join(', ')}',
    );
    _stats.clear();
    _windowStart = now;
  }

  /// 仅供测试：当前是否挂着事件循环延迟计时器。
  bool get debugTimerActive => _timer != null;
}

final class _ActiveRequest {
  final Stopwatch watch = Stopwatch()..start();
  Duration maxLag = Duration.zero;
}

final class _RouteStats {
  int count = 0;
  Duration total = Duration.zero;

  void add(Duration elapsed) {
    count++;
    total += elapsed;
  }
}

/// 按设计会挂起等事件的请求（长轮询）：墙钟耗时不代表本 isolate 在干活。
///
/// - `GET /api/srs/changes`：复习同步「有新段」通知，令牌没变就挂到
///   `kSrsChangeWait`（25 s）；
/// - `GET /api/assistant/sessions/<id>?wait=N`（N > 0）：助手会话视图长轮询。
bool isHostSuspendingRequest(shelf.Request request) {
  if (request.method != 'GET') return false;
  final List<String> segments = request.url.pathSegments;
  if (segments.length < 3 || segments[0] != 'api') return false;
  if (segments.length == 3 &&
      segments[1] == 'srs' &&
      segments[2] == 'changes') {
    return true;
  }
  if (segments.length == 4 &&
      segments[1] == 'assistant' &&
      segments[2] == 'sessions') {
    return (int.tryParse(request.url.queryParameters['wait'] ?? '') ?? 0) > 0;
  }
  return false;
}

/// 日志里的路由键：`/api/...` 取前三段（`/api/library/books/<书名>/...` →
/// `/api/library/books/*`，书名 / id 不进日志、也不把同一路由拆成几千行），其余
/// （WebDAV 文件树）一律 `/(dav)`。
String hostRequestRouteKey(shelf.Request request) {
  final List<String> segments = request.url.pathSegments;
  if (segments.isEmpty || segments.first != 'api') return '/(dav)';
  final Iterable<String> head = segments.take(3);
  return '/${head.join('/')}${segments.length > 3 ? '/*' : ''}';
}
