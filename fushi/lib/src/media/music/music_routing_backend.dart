/// 按曲目分派输出后端（设计 docs/specs/2026-10-31-apple-music-musickit.md §3.3）。
///
/// [MusicPlayerEngine] 只认一个 [MusicOutputBackend]；这里对它表现为单个后端，内部按
/// [MusicPlayItem] 把曲目交给声明了它的路由（[MusicBackendRoute]），其余一律交给默认链路
/// （libmpv + 交叉淡入）。同一后端内的「当前 → 下一首」照旧交给该后端自己无缝衔接；
/// 跨后端时当前后端只拿到当前曲（`next = null`），它播完后由这里在另一后端打开下一首并
/// 补发 [MusicBackendAdvanced]——跨后端**不保证无缝**。
library;

import 'dart:async';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 一类由专用后端播放的曲目。
class MusicBackendRoute {
  const MusicBackendRoute({
    required this.id,
    required this.handles,
    required this.create,
    required this.capabilities,
  });

  /// 路由名（日志 / 测试用），各路由唯一。
  final String id;

  /// 这首曲目归不归这条路由（一般按 [MusicPlayItem.path] 的 scheme 判）。
  final bool Function(MusicPlayItem item) handles;

  /// 建这条路由的后端；第一次有曲目落到它时才建，之后复用到 [MusicRoutingBackend.dispose]。
  final MusicOutputBackend Function() create;

  /// 这条路由的后端对它的曲目能做什么（静态声明，不必建后端就能问）。
  final MusicBackendCapabilities capabilities;
}

/// [item] 落到哪条路由；null = 默认链路。
MusicBackendRoute? musicBackendRouteFor(
  List<MusicBackendRoute> routes,
  MusicPlayItem item,
) {
  for (final MusicBackendRoute r in routes) {
    if (r.handles(item)) return r;
  }
  return null;
}

/// [item] 所属后端的能力：路由声明的，或默认链路的 [MusicBackendCapabilities.full]。
MusicBackendCapabilities musicBackendCapabilitiesFor(
  List<MusicBackendRoute> routes,
  MusicPlayItem item,
) =>
    musicBackendRouteFor(routes, item)?.capabilities ??
    MusicBackendCapabilities.full;

/// 默认链路的路由名。
const String kMusicDefaultBackendRoute = 'default';

class MusicRoutingBackend implements MusicOutputBackend {
  MusicRoutingBackend({
    required MusicOutputBackend Function() fallback,
    this.routes = const <MusicBackendRoute>[],
  }) : _fallback = fallback;

  final List<MusicBackendRoute> routes;
  final MusicOutputBackend Function() _fallback;

  final StreamController<MusicBackendEvent> _events =
      StreamController<MusicBackendEvent>.broadcast();

  /// 已建的子后端（按路由名），连同它的事件订阅。
  final Map<String, MusicOutputBackend> _children =
      <String, MusicOutputBackend>{};
  final Map<String, StreamSubscription<MusicBackendEvent>> _subs =
      <String, StreamSubscription<MusicBackendEvent>>{};

  MusicOutputSettings? _settings;

  /// 正在出声（持有当前曲）的路由；只转发它的事件。
  String? _active;

  /// 预排的下一首落在另一后端：当前后端播完时由这里接力打开它。
  MusicPlayItem? _crossNext;

  /// 打开代次：[openPair] / [stop] / 接力各加一，晚回来的接力发现变了就作废。
  int _gen = 0;

  /// 正在接力：旧后端已播完、新后端还在打开，这期间子后端的事件都不转发。
  bool _handingOff = false;

  bool _disposed = false;

  /// 当前活动路由名（测试用）。
  String? get activeRoute => _active;

  String _routeIdOf(MusicPlayItem item) =>
      musicBackendRouteFor(routes, item)?.id ?? kMusicDefaultBackendRoute;

  MusicOutputBackend _child(String id) {
    final MusicOutputBackend? existing = _children[id];
    if (existing != null) return existing;
    final MusicOutputBackend created = id == kMusicDefaultBackendRoute
        ? _fallback()
        : routes.firstWhere((MusicBackendRoute r) => r.id == id).create();
    _children[id] = created;
    _subs[id] = created.events.listen(
      (MusicBackendEvent e) => _onChildEvent(id, e),
    );
    final MusicOutputSettings? s = _settings;
    if (s != null) unawaited(created.applySettings(s));
    return created;
  }

  @override
  Stream<MusicBackendEvent> get events => _events.stream;

  void _emit(MusicBackendEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _onChildEvent(String id, MusicBackendEvent e) {
    if (id != _active || _handingOff) {
      // 不是正在出声的后端（被换下的旧后端停止前的尾巴）。输出降级照样要让界面知道。
      if (e is MusicBackendOutputFallback && id == _active) _emit(e);
      return;
    }
    if (e is MusicBackendCompleted && _crossNext != null) {
      unawaited(_handOff());
      return;
    }
    _emit(e);
  }

  /// 当前后端播完、下一首在另一后端：在那边打开它，成功补发 Advanced，失败按「预排的下一首
  /// 失败」上报（引擎据此推进并按失败处理）。
  Future<void> _handOff() async {
    final MusicPlayItem? item = _crossNext;
    final String? from = _active;
    if (item == null || from == null) return;
    final int gen = ++_gen;
    _crossNext = null;
    _handingOff = true;
    final String to = _routeIdOf(item);
    try {
      await _children[from]?.stop();
      if (gen != _gen) return;
      _active = to;
      await _child(to).openPair(item, null, play: true);
      if (gen != _gen) return;
      _handingOff = false;
      _emit(MusicBackendAdvanced(item.trackUid));
      _emit(const MusicBackendPlaying(true));
    } on MusicTrackOpenException catch (e) {
      if (gen != _gen) return;
      _handingOff = false;
      final MusicBackendFailed f = e.failure;
      _emit(
        MusicBackendFailed(
          f.message,
          reason: f.reason,
          device: f.device,
          trackUid: item.trackUid,
        ),
      );
    } finally {
      if (gen == _gen) _handingOff = false;
    }
  }

  @override
  Future<void> applySettings(MusicOutputSettings settings) async {
    _settings = settings;
    await Future.wait(
      _children.values.map((MusicOutputBackend c) => c.applySettings(settings)),
    );
  }

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
  }) async {
    final int gen = ++_gen;
    _handingOff = false;
    final String to = _routeIdOf(current);
    final String? from = _active;
    if (from != null && from != to) {
      _active = null;
      await _children[from]?.stop();
      if (gen != _gen) return;
    }
    _active = to;
    final bool sameNext = next == null || _routeIdOf(next) == to;
    _crossNext = sameNext ? null : next;
    await _child(to).openPair(
      current,
      sameNext ? next : null,
      play: play,
      crossfadeNext: sameNext && crossfadeNext,
    );
  }

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {
    final String? active = _active;
    if (active == null) return;
    final bool sameNext = next == null || _routeIdOf(next) == active;
    _crossNext = sameNext ? null : next;
    await _children[active]?.replaceNext(
      sameNext ? next : null,
      crossfadeNext: sameNext && crossfadeNext,
    );
  }

  MusicOutputBackend? get _activeChild =>
      _active == null ? null : _children[_active];

  @override
  Future<void> play() async => _activeChild?.play();

  @override
  Future<void> pause() async => _activeChild?.pause();

  @override
  Future<void> seek(Duration position) async => _activeChild?.seek(position);

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async =>
      _activeChild?.setAbLoop(a, b);

  @override
  Future<void> stop() async {
    _gen++;
    _handingOff = false;
    _crossNext = null;
    await _activeChild?.stop();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _gen++;
    _active = null;
    _crossNext = null;
    for (final StreamSubscription<MusicBackendEvent> s in _subs.values) {
      await s.cancel();
    }
    _subs.clear();
    final List<MusicOutputBackend> children = _children.values.toList();
    _children.clear();
    for (final MusicOutputBackend c in children) {
      await c.dispose();
    }
    await _events.close();
  }

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async =>
      _activeChild?.readSignalPath();

  /// 输出设备只对默认链路有意义（托管播放的后端由系统选设备）。
  @override
  Future<List<MusicAudioDevice>> listAudioDevices() =>
      _child(kMusicDefaultBackendRoute).listAudioDevices();
}
