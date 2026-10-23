import 'dart:math' as math;
import 'dart:ui' show Offset;

/// 手机触控板（视频遥控）上一次完整手势的判别结果。
enum VideoRemotePadGesture {
  /// 单指轻点。
  tap,

  /// 单指双击（只在 [VideoRemotePadGestureTracker.doubleTapEnabled] 时判）。
  doubleTap,

  /// 单指按住不动。
  longPress,

  /// 单指快滑（手指朝该方向移动）。
  flickLeft,
  flickRight,
  flickUp,
  flickDown,

  /// 拖动中每走过一格发一次（只在 [VideoRemotePadGestureTracker.stepping] 时判，
  /// 取代快滑）。
  stepLeft,
  stepRight,
  stepUp,
  stepDown,

  /// 双指同时轻点。
  twoFingerTap,
}

/// 触控板手势判别（纯逻辑，时间由调用方喂入，便于测试）。
///
/// 整块屏幕都是操作区、不看手机也能用：判据只看位移与时长，不看落点。
///
/// * 轻点：位移 < [slop]、按下不到 [longPressAfter]。
/// * 双击（[doubleTapEnabled]）：两次轻点间隔 ≤ [doubleTapWindow] 且落点相近。此时
///   单击要等窗口过去才确认（由 [tick] 发出），不开双击则抬手即发。
/// * 长按：按住 ≥ [longPressAfter] 且没走出 [slop]（由 [tick] 发出，抬手不再判点击）。
/// * 快滑：抬手时主轴位移 ≥ [flickDistance]，且主轴分量占优（≥ 次轴的 1.5 倍）。
/// * 步进（[stepping]）：拖动中主轴每累计 [stepDistance] 发一格；方向在起拖时按主轴
///   锁定，之后反向拖回也按同一轴计（来回拖 = 前后挪）。
/// * 双指轻点：第二指在第一指按下 [twoFingerWindow] 内落下、两指都没走出 [slop]、
///   全部抬起时距第一指按下不超过 [twoFingerWindow] 的两倍。双指期间不发单指手势。
class VideoRemotePadGestureTracker {
  VideoRemotePadGestureTracker({
    this.doubleTapEnabled = true,
    this.stepping = false,
    this.slop = 18,
    this.flickDistance = 48,
    this.stepDistance = 28,
    this.longPressAfter = const Duration(milliseconds: 500),
    this.doubleTapWindow = const Duration(milliseconds: 280),
    this.twoFingerWindow = const Duration(milliseconds: 250),
  });

  bool doubleTapEnabled;
  bool stepping;
  final double slop;
  final double flickDistance;
  final double stepDistance;
  final Duration longPressAfter;
  final Duration doubleTapWindow;
  final Duration twoFingerWindow;

  final Map<int, _Pointer> _pointers = <int, _Pointer>{};

  /// 本轮（从第一指按下到全部抬起）是否已成为双指手势。
  bool _multi = false;
  Duration? _firstDownAt;

  /// 本轮是否已经发过长按 / 步进（抬手不再判点击或快滑）。
  bool _consumed = false;

  /// 步进锁定的轴（true = 横向）；null = 还没走出 slop。
  bool? _stepHorizontal;
  double _stepCarry = 0;

  /// 等双击窗口确认的上一次单击（抬手时刻与落点）。
  Duration? _pendingTapAt;
  Offset? _pendingTapPosition;

  /// 是否有手指按着或单击在等确认（调用方据此决定要不要继续喂 [tick]）。
  bool get busy => _pointers.isNotEmpty || _pendingTapAt != null;

  List<VideoRemotePadGesture> down(int pointer, Offset position, Duration at) {
    if (_pointers.isEmpty) {
      _multi = false;
      _consumed = false;
      _stepHorizontal = null;
      _stepCarry = 0;
      _firstDownAt = at;
    } else {
      final Duration first = _firstDownAt ?? at;
      if (at - first <= twoFingerWindow && !_consumed) {
        _multi = true;
      } else {
        // 晚到的第二指：这一轮作废，什么都不发。
        _multi = true;
        _consumed = true;
      }
    }
    _pointers[pointer] = _Pointer(position, at);
    return const <VideoRemotePadGesture>[];
  }

  List<VideoRemotePadGesture> move(int pointer, Offset position, Duration at) {
    final _Pointer? p = _pointers[pointer];
    if (p == null) return const <VideoRemotePadGesture>[];
    final Offset previous = p.last;
    p.last = position;
    if ((position - p.origin).distance > slop) p.moved = true;
    if (_multi || !stepping || _consumed && _stepHorizontal == null) {
      return const <VideoRemotePadGesture>[];
    }
    final Offset total = position - p.origin;
    if (_stepHorizontal == null) {
      if (total.distance <= slop) return const <VideoRemotePadGesture>[];
      _stepHorizontal = total.dx.abs() >= total.dy.abs();
      _consumed = true;
      // 起拖时已经走过的部分（扣掉 slop）计入第一格。
      _stepCarry = _stepHorizontal! ? total.dx : total.dy;
      _stepCarry -= _stepCarry.sign * slop;
    } else {
      final Offset delta = position - previous;
      _stepCarry += _stepHorizontal! ? delta.dx : delta.dy;
    }
    final List<VideoRemotePadGesture> steps = <VideoRemotePadGesture>[];
    while (_stepCarry.abs() >= stepDistance) {
      final bool forward = _stepCarry > 0;
      steps.add(
        _stepHorizontal!
            ? (forward
                  ? VideoRemotePadGesture.stepRight
                  : VideoRemotePadGesture.stepLeft)
            : (forward
                  ? VideoRemotePadGesture.stepDown
                  : VideoRemotePadGesture.stepUp),
      );
      _stepCarry -= forward ? stepDistance : -stepDistance;
    }
    return steps;
  }

  List<VideoRemotePadGesture> up(int pointer, Duration at) {
    final _Pointer? p = _pointers.remove(pointer);
    if (p == null) return const <VideoRemotePadGesture>[];
    if (_multi) {
      if (_pointers.isNotEmpty) {
        if (p.moved) _consumed = true;
        return const <VideoRemotePadGesture>[];
      }
      final bool tap =
          !_consumed &&
          !p.moved &&
          at - (_firstDownAt ?? at) <= twoFingerWindow * 2;
      _consumed = true;
      return tap
          ? const <VideoRemotePadGesture>[VideoRemotePadGesture.twoFingerTap]
          : const <VideoRemotePadGesture>[];
    }
    if (_consumed) return const <VideoRemotePadGesture>[];
    final Offset travel = p.last - p.origin;
    if (!p.moved) {
      if (at - p.downAt >= longPressAfter)
        return const <VideoRemotePadGesture>[];
      return _tap(p.origin, at);
    }
    if (stepping) return const <VideoRemotePadGesture>[];
    final double ax = travel.dx.abs();
    final double ay = travel.dy.abs();
    final double major = math.max(ax, ay);
    final double minor = math.min(ax, ay);
    if (major < flickDistance || major < minor * 1.5) {
      return const <VideoRemotePadGesture>[];
    }
    if (ax >= ay) {
      return <VideoRemotePadGesture>[
        travel.dx < 0
            ? VideoRemotePadGesture.flickLeft
            : VideoRemotePadGesture.flickRight,
      ];
    }
    return <VideoRemotePadGesture>[
      travel.dy < 0
          ? VideoRemotePadGesture.flickUp
          : VideoRemotePadGesture.flickDown,
    ];
  }

  /// 指针被系统取消（来电、手势被系统抢走）：这一轮作废。
  void cancel(int pointer) {
    _pointers.remove(pointer);
    _consumed = true;
  }

  /// 时间推进：发出到期的长按、过了双击窗口的单击。
  List<VideoRemotePadGesture> tick(Duration now) {
    final List<VideoRemotePadGesture> out = <VideoRemotePadGesture>[];
    final Duration? pending = _pendingTapAt;
    if (pending != null && now - pending > doubleTapWindow) {
      _pendingTapAt = null;
      _pendingTapPosition = null;
      out.add(VideoRemotePadGesture.tap);
    }
    if (_pointers.length == 1 && !_multi && !_consumed) {
      final _Pointer p = _pointers.values.single;
      if (!p.moved && now - p.downAt >= longPressAfter) {
        _consumed = true;
        out.add(VideoRemotePadGesture.longPress);
      }
    }
    return out;
  }

  List<VideoRemotePadGesture> _tap(Offset position, Duration at) {
    if (!doubleTapEnabled) {
      return const <VideoRemotePadGesture>[VideoRemotePadGesture.tap];
    }
    final Duration? pending = _pendingTapAt;
    final Offset? pendingPosition = _pendingTapPosition;
    if (pending != null &&
        pendingPosition != null &&
        at - pending <= doubleTapWindow &&
        (position - pendingPosition).distance <= slop * 3) {
      _pendingTapAt = null;
      _pendingTapPosition = null;
      return const <VideoRemotePadGesture>[VideoRemotePadGesture.doubleTap];
    }
    final List<VideoRemotePadGesture> out = <VideoRemotePadGesture>[
      // 前一个单击已过窗口还没被 tick 收走：先把它发掉。
      if (pending != null) VideoRemotePadGesture.tap,
    ];
    _pendingTapAt = at;
    _pendingTapPosition = position;
    return out;
  }

  /// 换模式（进出选词）时丢掉在途状态，避免旧模式的单击在新模式里落地。
  void reset() {
    _pointers.clear();
    _pendingTapAt = null;
    _pendingTapPosition = null;
    _multi = false;
    _consumed = false;
    _stepHorizontal = null;
    _stepCarry = 0;
  }
}

class _Pointer {
  _Pointer(this.origin, this.downAt) : last = origin;
  final Offset origin;
  final Duration downAt;
  Offset last;
  bool moved = false;
}
