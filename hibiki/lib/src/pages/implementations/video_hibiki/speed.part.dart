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
  ///
  /// [rebuild]（BUG-963）：是否为倍速变化触发全页 `setState`。默认 true（菜单/键盘步进
  /// 需刷新倍速按钮标签 / 侧栏勾选）。长按临时加速的横拖热路径传 false——拖动全程由
  /// 独立的跟随徽章（[_longPressSpeedBadge] + 其 `ValueListenableBuilder`）实时渲染当前
  /// 倍速，页面无需重建；每 0.1x 步进都全页重建 ~7300 行视频页会掉帧、拖不流畅（松手
  /// [_handleVideoLongPressEnd] 走默认 rebuild 一次性把标签对账回恢复速）。`_playbackSpeed`
  /// 字段与 `_controller.setSpeed` 仍照常更新，只是省掉高频全页 `setState`。
  Future<void> _setSpeed(
    double speed, {
    bool persist = true,
    bool rebuild = true,
  }) async {
    final double clamped = speed.clamp(0.25, 4.0).toDouble();
    final bool changed = (clamped - _playbackSpeed).abs() >= 0.001;
    if (!changed && !persist) return;
    if (changed) {
      _playbackSpeed = clamped;
      if (rebuild && mounted) _rebuild(() {});
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
    // BUG-963：临时加速不触发全页重建——徽章即将成为唯一实时倍速指示，页面标签保持
    // 恒定的持久速（松手才对账），避免拖动期高频全页 setState 掉帧。
    unawaited(_setSpeed(speed, persist: false, rebuild: false));
    // TODO-1154：在长按落点上方弹出跟随指针的倍速徽章（B 站/YouTube 观感），
    // 取代钉死左上角的 _showOsd。localPosition 与 Stack 同坐标系，可直接用作 Positioned 锚点。
    _longPressSpeedBadge.value =
        (position: details.localPosition, speed: speed);
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
    // 徽章始终跟随指针移动（即使速度未越过 0.1x 步进也更新位置），保证「跟手」。
    _longPressSpeedBadge.value =
        (position: details.localPosition, speed: snapped);
    if ((snapped - _playbackSpeed).abs() < 0.001) return;
    // BUG-963：拖动热路径每 0.1x 步进都调这里；rebuild: false 省掉全页 setState，
    // 让徽章（独立 ValueListenableBuilder）跟手渲染倍速，拖动才顺滑。
    unawaited(_setSpeed(snapped, persist: false, rebuild: false));
  }

  void _handleVideoLongPressEnd(LongPressEndDetails details) {
    final double? previous = _longPressPreviousSpeed;
    _longPressPreviousSpeed = null;
    _longPressDragBaseSpeed = null;
    // 松手清空跟随徽章。
    _longPressSpeedBadge.value = null;
    if (previous == null) return;
    unawaited(_setSpeed(previous, persist: false));
  }

  Future<void> _adjustSpeed(double delta) async {
    final double next = ((_playbackSpeed + delta) * 10).round() / 10;
    await _setSpeed(next);
  }
}
