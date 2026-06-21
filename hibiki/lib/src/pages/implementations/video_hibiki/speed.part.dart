// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch12).
part of '../video_hibiki_page.dart';

/// Playback-speed domain methods extracted via part-of (TODO-590 batch12);
/// shared private scope. Behaviour-preserving: bodies are verbatim except the
/// lone `if (mounted) setState(() {});` rebuild inside [_setSpeed] is routed
/// through the main shell's `_rebuild(...)` forwarder (the established part
/// paradigm — an extension cannot call the @protected `State.setState`
/// directly). Everything else is moved character-for-character; the one static
/// reference [VideoHibikiPage.longPressDragSpeedFor] is already fully qualified
/// via the public widget class, so no extra qualification was needed (unlike
/// batch11's host-class statics).
///
/// Covers the optimistic speed setter ([_setSpeed]) + its trailing-debounce
/// persistence pair ([_queuePersistVideoSpeed] / [_flushPersistedVideoSpeed]),
/// and the long-press temporary-speed gesture trio ([_handleVideoLongPressStart]
/// / [_handleVideoLongPressMoveUpdate] / [_handleVideoLongPressEnd]) plus the
/// keyboard step adjuster ([_adjustSpeed]).
///
/// The instance fields (`_playbackSpeed`, `_pendingSpeedPersist`,
/// `_speedPersistDebounce`, `_longPressPreviousSpeed`, `_longPressDragBaseSpeed`),
/// the `_speedPrefKey` getter, `_asbConfig`, the controller (`_controller`), the
/// preferences repo (`appModel.prefsRepo`) and `_showOsd` all stay in the main
/// shell; the extension reads/calls instance members through the shared private
/// scope. The speed menu / side panel / popover UI ([_showSpeedMenu],
/// [_speedMenuPresets], [_buildSpeedSidePanel]) intentionally stays in the main
/// shell — those are interleaved with side-panel/popover concerns, not part of
/// this self-contained core block.
extension _VideoSpeed on _VideoHibikiPageState {
  /// 设置播放倍速：先乐观刷新 UI，再下发 controller；只有持久化走 trailing debounce。
  Future<void> _setSpeed(double speed, {bool persist = true}) async {
    final double clamped = speed.clamp(0.25, 4.0).toDouble();
    final bool changed = (clamped - _playbackSpeed).abs() >= 0.001;
    if (!changed && !persist) return;
    if (changed) {
      _playbackSpeed = clamped;
      if (mounted) _rebuild(() {});
      await _controller?.setSpeed(clamped);
    }
    if (persist) {
      _queuePersistVideoSpeed(clamped);
    }
  }

  void _queuePersistVideoSpeed(double speed) {
    _pendingSpeedPersist = speed.clamp(0.25, 4.0).toDouble();
    _speedPersistDebounce?.cancel();
    _speedPersistDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_flushPersistedVideoSpeed());
    });
  }

  Future<void> _flushPersistedVideoSpeed() async {
    final double? pending = _pendingSpeedPersist;
    if (pending == null) return;
    _speedPersistDebounce?.cancel();
    _speedPersistDebounce = null;
    _pendingSpeedPersist = null;
    await appModel.prefsRepo.setPref(_speedPrefKey, pending);
  }

  void _handleVideoLongPressStart(LongPressStartDetails details) {
    if (_longPressPreviousSpeed != null) return;
    _longPressPreviousSpeed = _playbackSpeed;
    final double speed = _asbConfig.longPressSpeed;
    // 长按拖动以固定加速速为基准（TODO-338）：拖动位移在此基础上连续加减。
    _longPressDragBaseSpeed = speed;
    unawaited(_setSpeed(speed, persist: false));
    _showOsd('${speed.toStringAsFixed(1)}x', icon: Icons.speed);
  }

  /// 长按后横向拖动连续调速（TODO-338）：向右拖加速、向左减速，以长按固定加速速
  /// [_longPressDragBaseSpeed] 为基准，按 [_kLongPressDragSpeedPerPixel] 线性映射横向
  /// 位移，clamp 到 [_kLongPressDragMinSpeed]..[_kLongPressDragMaxSpeed]，松手恢复原速
  /// （[_handleVideoLongPressEnd]）。位移用相对长按起点的 [localOffsetFromOrigin]。
  void _handleVideoLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    final double? base = _longPressDragBaseSpeed;
    if (base == null) return;
    // 0.1x 步进（避免每像素抖动；_setSpeed 内另有 0.001 去重）。
    final double snapped = VideoHibikiPage.longPressDragSpeedFor(
      base,
      details.localOffsetFromOrigin.dx,
    );
    if ((snapped - _playbackSpeed).abs() < 0.001) return;
    unawaited(_setSpeed(snapped, persist: false));
    _showOsd('${snapped.toStringAsFixed(1)}x', icon: Icons.speed);
  }

  void _handleVideoLongPressEnd(LongPressEndDetails details) {
    final double? previous = _longPressPreviousSpeed;
    _longPressPreviousSpeed = null;
    _longPressDragBaseSpeed = null;
    if (previous == null) return;
    unawaited(_setSpeed(previous, persist: false));
  }

  Future<void> _adjustSpeed(double delta) async {
    final double next = ((_playbackSpeed + delta) * 10).round() / 10;
    await _setSpeed(next);
  }
}
