/// 复习页卡面手势：手势 → 动作的映射（问题面 / 答案面各一份）、持久化格式与纯函数判定
/// （点按分区、滑动判定、哪些识别器要开）。
///
/// 只放与界面无关的数据与判定，原生卡面的识别区（`SrsCardGestureRegion`）、WebView 卡面
/// 的页内脚本与复习页的分发都只消费这里：两种卡面同一套判据。设计说明见
/// `docs/specs/2026-10-31-srs-review-gestures.md`。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show immutable, mapEquals;

/// 卡面上能识别的手势。[wire] 是持久化名，冻结。
enum SrsReviewGesture {
  /// 单击卡面左三分之一的空白。
  tapLeft('tap_left'),

  /// 单击卡面中间三分之一的空白。
  tapCenter('tap_center'),

  /// 单击卡面右三分之一的空白。
  tapRight('tap_right'),

  /// 双击空白。
  doubleTap('double_tap'),

  /// 长按空白（触屏 / 触控笔）。
  longPress('long_press'),

  /// 向左滑（触屏 / 触控笔）。
  swipeLeft('swipe_left'),
  swipeRight('swipe_right'),
  swipeUp('swipe_up'),
  swipeDown('swipe_down');

  const SrsReviewGesture(this.wire);

  final String wire;

  static SrsReviewGesture? fromWire(String wire) {
    for (final SrsReviewGesture g in values) {
      if (g.wire == wire) return g;
    }
    return null;
  }

  bool get isTap => this == tapLeft || this == tapCenter || this == tapRight;

  bool get isSwipe =>
      this == swipeLeft ||
      this == swipeRight ||
      this == swipeUp ||
      this == swipeDown;
}

/// 卡的哪一面。
enum SrsReviewSide { front, back }

/// 手势能触发的动作：一律是复习页已有的操作（按钮 / 快捷键同一条实现）。[wire] 冻结。
enum SrsReviewGestureAction {
  none('none'),

  /// 显示答案（只在问题面）。
  showAnswer('show_answer'),

  /// 评分（只在答案面）。
  rateAgain('rate_again'),
  rateHard('rate_hard'),
  rateGood('rate_good'),
  rateEasy('rate_easy'),
  undo('undo'),
  replayAudio('replay_audio'),

  /// 显示 / 收起悬浮顶栏（今天「点空白」的行为）。
  toggleToolbar('toggle_toolbar'),
  editNote('edit_note'),
  bury('bury'),
  suspend('suspend'),
  flag('flag');

  const SrsReviewGestureAction(this.wire);

  final String wire;

  static SrsReviewGestureAction? fromWire(String wire) {
    for (final SrsReviewGestureAction a in values) {
      if (a.wire == wire) return a;
    }
    return null;
  }

  /// 评分值（1 重来 … 4 简单）；不是评分为 null。
  int? get rating => switch (this) {
    rateAgain => 1,
    rateHard => 2,
    rateGood => 3,
    rateEasy => 4,
    _ => null,
  };

  /// 这一面能不能绑这个动作：显示答案只在问题面，评分只在答案面。
  bool availableOn(SrsReviewSide side) => switch (this) {
    showAnswer => side == SrsReviewSide.front,
    rateAgain || rateHard || rateGood || rateEasy => side == SrsReviewSide.back,
    _ => true,
  };

  /// 「评分栏只留重来 / 良好」开着时被屏蔽的动作。
  bool hiddenBy({required bool hideHardEasy}) =>
      hideHardEasy && (this == rateHard || this == rateEasy);

  /// [side] 上可选的动作（设置页的选项顺序）。
  static List<SrsReviewGestureAction> choicesFor(SrsReviewSide side) =>
      <SrsReviewGestureAction>[
        for (final SrsReviewGestureAction a in values)
          if (a.availableOn(side)) a,
      ];
}

/// 卡面要开哪些识别器。单击（空白）恒报；其余只在绑了动作时才开：没绑双击就不为了
/// 等第二击推迟单击，没绑滑动 / 长按就不碰拖动与按住（滚动、拖选照旧）。
@immutable
class SrsCardGestureArming {
  const SrsCardGestureArming({
    this.doubleTap = false,
    this.longPress = false,
    this.swipeHorizontal = false,
    this.swipeVertical = false,
  });

  static const SrsCardGestureArming none = SrsCardGestureArming();

  final bool doubleTap;
  final bool longPress;
  final bool swipeHorizontal;
  final bool swipeVertical;

  bool get anySwipe => swipeHorizontal || swipeVertical;

  /// 页内脚本的门控对象（`window.__fushiSrsGestures`）。
  Map<String, Object> toJson() => <String, Object>{
    'on': true,
    'doubleTap': doubleTap,
    'longPress': longPress,
    'swipeX': swipeHorizontal,
    'swipeY': swipeVertical,
  };

  @override
  bool operator ==(Object other) =>
      other is SrsCardGestureArming &&
      other.doubleTap == doubleTap &&
      other.longPress == longPress &&
      other.swipeHorizontal == swipeHorizontal &&
      other.swipeVertical == swipeVertical;

  @override
  int get hashCode =>
      Object.hash(doubleTap, longPress, swipeHorizontal, swipeVertical);

  @override
  String toString() =>
      'SrsCardGestureArming(doubleTap: $doubleTap, longPress: $longPress, '
      'swipeX: $swipeHorizontal, swipeY: $swipeVertical)';
}

/// 两面的手势映射（偏好 `srs_review_gestures`，一个 JSON 值）。
///
/// 格式 `{"v":1,"front":{"tap_left":"toggle_toolbar",…},"back":{…}}`：
/// - 读不出 / 空串 / 不是对象 → [defaults]；
/// - 缺的手势取默认；动作名不认识或这一面不许绑（问题面评分、答案面显示答案）→ 该手势取默认；
/// - **不认识的手势名原样保留**（更新版本加的手势，旧版本改别的映射再写回时不丢）；
/// - `v` 比本版大照样按认识的字段读（向前兼容）。
@immutable
class SrsReviewGestureMap {
  SrsReviewGestureMap._(
    Map<SrsReviewGesture, SrsReviewGestureAction> front,
    Map<SrsReviewGesture, SrsReviewGestureAction> back, {
    Map<String, String> unknownFront = const <String, String>{},
    Map<String, String> unknownBack = const <String, String>{},
  }) : _front = Map<SrsReviewGesture, SrsReviewGestureAction>.unmodifiable(
         front,
       ),
       _back = Map<SrsReviewGesture, SrsReviewGestureAction>.unmodifiable(back),
       _unknownFront = Map<String, String>.unmodifiable(unknownFront),
       _unknownBack = Map<String, String>.unmodifiable(unknownBack);

  /// 当前格式版本。
  static const int version = 1;

  /// 默认映射 = 加手势系统之前的行为：两面单击空白（任一分区）都切换悬浮顶栏，其余什么都
  /// 不绑——没配置过的人行为一点不变。
  static SrsReviewGestureAction defaultActionFor(SrsReviewGesture g) => g.isTap
      ? SrsReviewGestureAction.toggleToolbar
      : SrsReviewGestureAction.none;

  static final SrsReviewGestureMap defaults = SrsReviewGestureMap._(
    <SrsReviewGesture, SrsReviewGestureAction>{
      for (final SrsReviewGesture g in SrsReviewGesture.values)
        g: defaultActionFor(g),
    },
    <SrsReviewGesture, SrsReviewGestureAction>{
      for (final SrsReviewGesture g in SrsReviewGesture.values)
        g: defaultActionFor(g),
    },
  );

  final Map<SrsReviewGesture, SrsReviewGestureAction> _front;
  final Map<SrsReviewGesture, SrsReviewGestureAction> _back;
  final Map<String, String> _unknownFront;
  final Map<String, String> _unknownBack;

  Map<SrsReviewGesture, SrsReviewGestureAction> _of(SrsReviewSide side) =>
      side == SrsReviewSide.front ? _front : _back;

  /// 存下来的绑定（不看「只留重来 / 良好」）。
  SrsReviewGestureAction actionFor(SrsReviewSide side, SrsReviewGesture g) =>
      _of(side)[g] ?? defaultActionFor(g);

  /// 这一下实际要执行的动作：「只留重来 / 良好」开着时，绑在困难 / 简单上的手势什么都不做
  /// （与评分栏一致：那两颗按钮不在，手势也不偷偷评它们）。
  SrsReviewGestureAction resolve(
    SrsReviewSide side,
    SrsReviewGesture g, {
    required bool hideHardEasy,
  }) {
    final SrsReviewGestureAction a = actionFor(side, g);
    if (!a.availableOn(side) || a.hiddenBy(hideHardEasy: hideHardEasy)) {
      return SrsReviewGestureAction.none;
    }
    return a;
  }

  /// 这一面要开哪些识别器（按实际生效的动作算）。
  SrsCardGestureArming arming(
    SrsReviewSide side, {
    required bool hideHardEasy,
  }) {
    bool bound(SrsReviewGesture g) =>
        resolve(side, g, hideHardEasy: hideHardEasy) !=
        SrsReviewGestureAction.none;
    return SrsCardGestureArming(
      doubleTap: bound(SrsReviewGesture.doubleTap),
      longPress: bound(SrsReviewGesture.longPress),
      swipeHorizontal:
          bound(SrsReviewGesture.swipeLeft) ||
          bound(SrsReviewGesture.swipeRight),
      swipeVertical:
          bound(SrsReviewGesture.swipeUp) || bound(SrsReviewGesture.swipeDown),
    );
  }

  /// 改一条绑定。这一面不许绑的动作抛 [ArgumentError]（设置页只给可选项）。
  SrsReviewGestureMap withBinding(
    SrsReviewSide side,
    SrsReviewGesture g,
    SrsReviewGestureAction action,
  ) {
    if (!action.availableOn(side)) {
      throw ArgumentError.value(action, 'action', 'not available on $side');
    }
    final Map<SrsReviewGesture, SrsReviewGestureAction> next =
        <SrsReviewGesture, SrsReviewGestureAction>{..._of(side), g: action};
    return side == SrsReviewSide.front
        ? SrsReviewGestureMap._(
            next,
            _back,
            unknownFront: _unknownFront,
            unknownBack: _unknownBack,
          )
        : SrsReviewGestureMap._(
            _front,
            next,
            unknownFront: _unknownFront,
            unknownBack: _unknownBack,
          );
  }

  /// 已知手势的绑定是否都是默认值。
  bool get isDefault {
    for (final SrsReviewSide side in SrsReviewSide.values) {
      for (final SrsReviewGesture g in SrsReviewGesture.values) {
        if (actionFor(side, g) != defaultActionFor(g)) return false;
      }
    }
    return true;
  }

  String encode() {
    Map<String, String> side(
      Map<SrsReviewGesture, SrsReviewGestureAction> known,
      Map<String, String> unknown,
    ) => <String, String>{
      ...unknown,
      for (final SrsReviewGesture g in SrsReviewGesture.values)
        g.wire: (known[g] ?? defaultActionFor(g)).wire,
    };
    return jsonEncode(<String, Object>{
      'v': version,
      'front': side(_front, _unknownFront),
      'back': side(_back, _unknownBack),
    });
  }

  static SrsReviewGestureMap decode(String raw) {
    if (raw.trim().isEmpty) return defaults;
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return defaults;
    }
    if (json is! Map<String, dynamic>) return defaults;
    ({
      Map<SrsReviewGesture, SrsReviewGestureAction> known,
      Map<String, String> unknown,
    })
    side(Object? value, SrsReviewSide s) {
      final Map<SrsReviewGesture, SrsReviewGestureAction> known =
          <SrsReviewGesture, SrsReviewGestureAction>{
            for (final SrsReviewGesture g in SrsReviewGesture.values)
              g: defaultActionFor(g),
          };
      final Map<String, String> unknown = <String, String>{};
      if (value is Map) {
        value.forEach((Object? k, Object? v) {
          if (k is! String || v is! String) return;
          final SrsReviewGesture? g = SrsReviewGesture.fromWire(k);
          if (g == null) {
            unknown[k] = v;
            return;
          }
          final SrsReviewGestureAction? a = SrsReviewGestureAction.fromWire(v);
          if (a != null && a.availableOn(s)) known[g] = a;
        });
      }
      return (known: known, unknown: unknown);
    }

    final ({
      Map<SrsReviewGesture, SrsReviewGestureAction> known,
      Map<String, String> unknown,
    })
    front = side(json['front'], SrsReviewSide.front);
    final ({
      Map<SrsReviewGesture, SrsReviewGestureAction> known,
      Map<String, String> unknown,
    })
    back = side(json['back'], SrsReviewSide.back);
    return SrsReviewGestureMap._(
      front.known,
      back.known,
      unknownFront: front.unknown,
      unknownBack: back.unknown,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SrsReviewGestureMap &&
      mapEquals(other._front, _front) &&
      mapEquals(other._back, _back) &&
      mapEquals(other._unknownFront, _unknownFront) &&
      mapEquals(other._unknownBack, _unknownBack);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(
      _front.entries.map(
        (MapEntry<SrsReviewGesture, SrsReviewGestureAction> e) =>
            Object.hash(e.key, e.value),
      ),
    ),
    Object.hashAllUnordered(
      _back.entries.map(
        (MapEntry<SrsReviewGesture, SrsReviewGestureAction> e) =>
            Object.hash(e.key, e.value),
      ),
    ),
    Object.hashAllUnordered(
      _unknownFront.entries.map(
        (MapEntry<String, String> e) => Object.hash(e.key, e.value),
      ),
    ),
    Object.hashAllUnordered(
      _unknownBack.entries.map(
        (MapEntry<String, String> e) => Object.hash(e.key, e.value),
      ),
    ),
  );
}

// ------------------------------------------------------------------ 判定（纯函数）

/// 单击分区。
enum SrsTapZone { left, center, right }

/// 卡面横向三等分：[x] 是落点，[left] / [width] 是卡面区域（同一坐标系）。
SrsTapZone srsTapZoneOf(
  double x, {
  required double left,
  required double width,
}) {
  if (width <= 0) return SrsTapZone.center;
  final double f = (x - left) / width;
  if (f < 1 / 3) return SrsTapZone.left;
  if (f >= 2 / 3) return SrsTapZone.right;
  return SrsTapZone.center;
}

SrsReviewGesture srsTapGestureOf(SrsTapZone zone) => switch (zone) {
  SrsTapZone.left => SrsReviewGesture.tapLeft,
  SrsTapZone.center => SrsReviewGesture.tapCenter,
  SrsTapZone.right => SrsReviewGesture.tapRight,
};

/// 拖过这么远（逻辑像素，沿主轴）松手即算滑动。
const double kSrsSwipeCommitDistance = 96;

/// 快速甩动：沿主轴至少这么远……
const double kSrsSwipeFlingMinDistance = 40;

/// ……且松手时沿主轴的速度（逻辑像素 / 秒）至少这么快。
const double kSrsSwipeFlingVelocity = 700;

/// 主轴位移至少是副轴的这么多倍才算这条轴上的滑动（斜着划不算）。
const double kSrsSwipeAxisDominance = 1.5;

/// 拖动途中 / 松手时：位移 [delta]（逻辑像素）与松手速度 [velocity]（逻辑像素 / 秒）
/// 算不算一次滑动、往哪边。[horizontal] / [vertical] 是这一面开着的轴。
SrsReviewGesture? srsClassifySwipe(
  Offset delta,
  Offset velocity, {
  bool horizontal = true,
  bool vertical = true,
}) {
  final double ax = delta.dx.abs();
  final double ay = delta.dy.abs();
  final bool isHorizontal = ax >= ay;
  if (isHorizontal ? !horizontal : !vertical) return null;
  final double main = isHorizontal ? ax : ay;
  final double cross = isHorizontal ? ay : ax;
  if (main < kSrsSwipeFlingMinDistance ||
      main < cross * kSrsSwipeAxisDominance) {
    return null;
  }
  final double v = isHorizontal ? velocity.dx : velocity.dy;
  final double d = isHorizontal ? delta.dx : delta.dy;
  final bool fling = v.abs() >= kSrsSwipeFlingVelocity && v.sign == d.sign;
  if (main < kSrsSwipeCommitDistance && !fling) return null;
  if (isHorizontal) {
    return d < 0 ? SrsReviewGesture.swipeLeft : SrsReviewGesture.swipeRight;
  }
  return d < 0 ? SrsReviewGesture.swipeUp : SrsReviewGesture.swipeDown;
}

/// 拖动途中的视觉反馈：按主轴锁定的位移、朝哪个滑动手势、离「松手即触发」还差多少
/// （0..1，到 1 = 现在松手就算）。位移太小、斜着划时为 null。
({SrsReviewGesture gesture, Offset offset, double progress})? srsSwipePreview(
  Offset delta, {
  bool horizontal = true,
  bool vertical = true,
}) {
  final double ax = delta.dx.abs();
  final double ay = delta.dy.abs();
  final bool isHorizontal = ax >= ay;
  if (isHorizontal ? !horizontal : !vertical) return null;
  final double main = isHorizontal ? ax : ay;
  final double cross = isHorizontal ? ay : ax;
  if (main < 1 || main < cross * kSrsSwipeAxisDominance) return null;
  final double d = isHorizontal ? delta.dx : delta.dy;
  final SrsReviewGesture gesture = isHorizontal
      ? (d < 0 ? SrsReviewGesture.swipeLeft : SrsReviewGesture.swipeRight)
      : (d < 0 ? SrsReviewGesture.swipeUp : SrsReviewGesture.swipeDown);
  return (
    gesture: gesture,
    offset: isHorizontal ? Offset(d, 0) : Offset(0, d),
    progress: math.min(1, main / kSrsSwipeCommitDistance),
  );
}

// ------------------------------------------------------------------ 卡面 → 复习页

/// 卡面回报的一次手势事件（原生识别区与 WebView 页内脚本同一种）。
enum SrsCardGestureKind {
  /// 单击空白（[SrsCardGestureEvent.position] 是落点）。
  tap,

  /// 双击空白。
  doubleTap,

  /// 长按空白。
  longPress,

  /// 滑动途中（[SrsCardGestureEvent.delta] 是从按下起的累计位移）：只用于视觉反馈。
  drag,

  /// 松手（[SrsCardGestureEvent.delta] / [SrsCardGestureEvent.velocity]）：由复习页判定
  /// 是否算滑动（[srsClassifySwipe]）。
  release,

  /// 拖动作废（开始滚动 / 拖选 / 指针取消）：撤掉视觉反馈，不触发。
  cancel,
}

@immutable
class SrsCardGestureEvent {
  const SrsCardGestureEvent(
    this.kind, {
    this.position = Offset.zero,
    this.delta = Offset.zero,
    this.velocity = Offset.zero,
  });

  final SrsCardGestureKind kind;

  /// 全局坐标（逻辑像素）。
  final Offset position;

  /// 逻辑像素。
  final Offset delta;

  /// 逻辑像素 / 秒。
  final Offset velocity;

  @override
  bool operator ==(Object other) =>
      other is SrsCardGestureEvent &&
      other.kind == kind &&
      other.position == position &&
      other.delta == delta &&
      other.velocity == velocity;

  @override
  int get hashCode => Object.hash(kind, position, delta, velocity);

  @override
  String toString() =>
      'SrsCardGestureEvent($kind, position: $position, delta: $delta, '
      'velocity: $velocity)';
}

/// WebView 页内脚本 → Dart 的手势回传名（载荷是 JSON 串，见 [srsCardGestureFromPage]）。
const String kSrsGestureHandler = 'onSrsGesture';

/// 解析页内脚本回传的手势：`{t, x, y, dx, dy, vx, vy, vw, vh}`，坐标是页面 CSS 像素
/// （视口 `vw × vh`）。按平台视图的实际尺寸换成逻辑像素，落点经 [toGlobal] 换成全局坐标。
/// 载荷不合法返回 null。
SrsCardGestureEvent? srsCardGestureFromPage(
  Object? raw, {
  required double viewWidth,
  required double viewHeight,
  required Offset Function(Offset local) toGlobal,
}) {
  if (raw is! String) return null;
  final Object? json;
  try {
    json = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (json is! Map<String, dynamic>) return null;
  final Map<String, dynamic> map = json;
  final SrsCardGestureKind? kind = switch (map['t']) {
    'tap' => SrsCardGestureKind.tap,
    'doubleTap' => SrsCardGestureKind.doubleTap,
    'longPress' => SrsCardGestureKind.longPress,
    'drag' => SrsCardGestureKind.drag,
    'release' => SrsCardGestureKind.release,
    'cancel' => SrsCardGestureKind.cancel,
    _ => null,
  };
  if (kind == null) return null;
  double n(String key) {
    final Object? v = map[key];
    return v is num && v.isFinite ? v.toDouble() : 0;
  }

  final double vw = n('vw');
  final double vh = n('vh');
  final double sx = vw > 0 && viewWidth > 0 ? viewWidth / vw : 1;
  final double sy = vh > 0 && viewHeight > 0 ? viewHeight / vh : 1;
  return SrsCardGestureEvent(
    kind,
    position: toGlobal(Offset(n('x') * sx, n('y') * sy)),
    delta: Offset(n('dx') * sx, n('dy') * sy),
    velocity: Offset(n('vx') * sx, n('vy') * sy),
  );
}
