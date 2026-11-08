import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:material_ui/material_ui.dart';

/// Builds a page's module snapshot (JSON-safe); null = nothing to show yet
/// (the panel keeps its last one).
typedef CompanionSnapshotBuilder = Map<String, Object?>? Function();

/// A main-engine page's end of the companion: owns the page's context claim
/// and publishes its module snapshot.
///
/// Snapshots are coarse and throttled: while the companion is active
/// ([CompanionContextRegistry.active]) and this page owns the context, the
/// builder runs once per [period] and the result is published only when it
/// changed (compared as JSON). [publishNow] publishes right away (after a
/// command, a page turn). While the companion is not active no timer runs
/// and nothing is built: single-screen devices pay nothing.
class CompanionPageLink {
  CompanionPageLink({
    CompanionContextRegistry? registry,
    this.period = const Duration(seconds: 1),
  }) : _registry = registry ?? companionContexts;

  final CompanionContextRegistry _registry;

  /// How often the snapshot is rebuilt while active.
  final Duration period;

  CompanionSnapshotBuilder? _build;
  Timer? _timer;
  String? _lastJson;
  bool _claimed = false;
  CompanionContextKind? _kind;
  bool _listening = false;
  bool _disposed = false;

  /// The companion is up (cheap; check it before doing companion-only work).
  bool get isActive => _registry.active.value;

  /// This page owns the companion context right now.
  bool get isCurrent => _claimed && identical(_registry.currentOwner, this);

  /// Claims (or updates) the page's context. Call again with the page's
  /// [route] once it is known (`didChangeDependencies`), and whenever the
  /// context changes (title, kind).
  void claim(
    CompanionContext context, {
    Route<Object?>? route,
    CompanionCommandHandler? onCommand,
  }) {
    if (_disposed) return;
    // A new kind drops the stored snapshot (the registry does the same).
    if (_kind != context.kind) _lastJson = null;
    _kind = context.kind;
    _claimed = true;
    _registry.claim(this, context, route: route, onCommand: onCommand);
    _ensureListening();
    _syncTimer();
  }

  /// The page closed (or stopped showing its media).
  void release() {
    if (!_claimed) return;
    _claimed = false;
    _kind = null;
    _registry.release(this);
    _lastJson = null;
    _syncTimer();
  }

  /// Starts publishing what [build] returns (replaces an earlier builder).
  void startSnapshots(CompanionSnapshotBuilder build) {
    if (_disposed) return;
    _build = build;
    _lastJson = null;
    _ensureListening();
    _syncTimer();
  }

  /// Builds and publishes now (when active and this page owns the context;
  /// skipped when nothing changed).
  void publishNow() {
    if (_disposed || !isActive || !isCurrent) return;
    final CompanionSnapshotBuilder? build = _build;
    if (build == null) return;
    final Map<String, Object?>? data = build();
    if (data == null) return;
    final String json = jsonEncode(data);
    if (json == _lastJson) return;
    _lastJson = json;
    _registry.publishSnapshot(this, data);
  }

  /// Forgets the last published snapshot, so the next build is sent even if
  /// it did not change (a new panel needs it again).
  void invalidate() => _lastJson = null;

  void _ensureListening() {
    if (_listening) return;
    _listening = true;
    _registry.active.addListener(_onActiveChanged);
  }

  void _onActiveChanged() {
    // A new panel: the registry resends the stored snapshot on "ready", but
    // the page's state may have moved on while nobody watched.
    _lastJson = null;
    _syncTimer();
  }

  void _syncTimer() {
    final bool run = !_disposed && _claimed && _build != null && isActive;
    if (run && _timer == null) {
      _timer = Timer.periodic(period, (_) => publishNow());
      publishNow();
    } else if (!run && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  void dispose() {
    if (_disposed) return;
    release();
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    if (_listening) _registry.active.removeListener(_onActiveChanged);
  }
}
