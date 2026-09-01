import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:fushi/src/shortcuts/input_binding.dart'
    show domMouseButtonFromPointerButtons;
import 'package:fushi/src/utils/misc/swipe_dismiss_wrapper.dart'
    show swipeDismissThreshold;

/// BUG-1757：查词弹窗全屏 dismiss barrier 的**唯一**构造入口。
///
/// ## 为什么必须是一个原语，而不是各表面各拼一份
///
/// TODO-716/1052 给 barrier 加「水平拖过阈关一层」时，四个表面
/// （`base_source_page` = 阅读器/有声书、`video_fushi_page`、`home_dictionary_page`、
/// `texthooker_page`）各自把 `onHorizontalDragStart/Update/End` 挂在 barrier 的
/// [GestureDetector] 上，再各自持一份 [BarrierSwipeDismissTracker] + 三个转发方法。
/// 同一个手势语义散成四份、判轴完全交给手势竞技场，谁改一处都可能漂移；barrier 这种
/// 「盖住整屏、下面压着 platform view」的东西尤其不该让每个调用点自由发挥。
///
/// 本 widget 把「一层透明遮挡 + 点它关栈 + 横拖关一层 + hover/滚轮转发」收成一个
/// 带类型签名的原语，四个表面只声明**策略**（关哪一层、tap 怎么分流），不再复制接线。
///
/// ## 一个实测澄清：barrier 为什么会让下面的内容「点不动、滑不动」
///
/// 直觉上很容易归咎于手势竞技场（[HorizontalDragGestureRecognizer] 对纯纵向拖动既
/// 不 accept 也不 reject，而 `_PlatformViewGestureRecognizer` 在 accept 前会把事件
/// 全缓存）。**实测下来这不是原因**：barrier 的透明填充盒（`ColoredBox` /
/// `Container(color:)`）在 hit test 上就是**实心**的，下层 platform view 根本进不了
/// hit test 结果，也就从不参与竞技场。对照实验（`test/pages/lookup_dismiss_barrier_test.dart`）：
/// 上层只放一个**不带任何手势**的 `ColoredBox`，下层 [PlatformViewSurface] 收到 0 个
/// 指针事件；把 `ColoredBox` 去掉、只留 tap 手势，下层收到全部 14 个。
///
/// 所以「弹窗开着时正文收不到触摸」是 barrier 实心遮挡的**既有设计**（点它是要关窗，
/// 不是要穿透），不是手势接线的 bug。改这条属于产品行为变更，不要当成 bug 顺手改掉。
///
/// ## 横拖仍然走不进竞技场的 raw [Listener]
///
/// 沿用 BUG-1242 在弹窗**本体**上确立的范式（[SwipeDismissWrapper]、
/// `_BodySwipeDismissDetector`）：用 [Listener] 旁路观察轨迹 + 自主判轴，横向主导才
/// 累积位移、松手才可能关层，纵向/斜向立刻永久放弃本轮。好处是判轴规则写在代码里、
/// 可单测、可解释，而不是隐含在竞技场的 accept/reject 时序里。tap 留在
/// [GestureDetector]（[TapGestureRecognizer] 超出 touch slop 会主动 reject，与滑关
/// 天然互斥）。
class LookupDismissBarrier extends StatefulWidget {
  const LookupDismissBarrier({
    required this.onTapDismiss,
    required this.onSwipeDismiss,
    required this.swipeEnabled,
    required this.sensitivity,
    this.onPointerHover,
    this.onPointerSignal,
    this.onNonPrimaryButtonDown,
    super.key,
  });

  /// 点 barrier（= 所有弹窗矩形之外的真空白）。带全局坐标：阅读器覆写为「命中词
  /// → 换新查词」，视频页据此判「点到同句另一个字幕字符」，首页词典忽略坐标直接关栈。
  final ValueChanged<Offset> onTapDismiss;

  /// 水平拖过阈：关**一层**（逐层关，与光标 B/Esc 同语义），不是清整栈。
  final VoidCallback onSwipeDismiss;

  /// 用户偏好「滑动关闭弹窗」（`enable_swipe_to_close`）。关闭时 barrier 只认 tap，
  /// 与 TODO-716 之前的桌面行为一致（never break userspace）。
  final bool swipeEnabled;

  /// 滑关灵敏度（`dismissSwipeSensitivity`）。同时决定判轴距离与过阈位移，
  /// 阈值公式与顶栏 [SwipeDismissWrapper] 共用 [swipeDismissThreshold]，不漂移。
  final double sensitivity;

  /// BUG-861：barrier 盖住正文后，宿主的 hover 入口（阅读器「按住 Shift 连续切换
  /// 查词」、视频字幕盒）只剩这里。
  final void Function(PointerHoverEvent event)? onPointerHover;

  /// 滚轮等指针信号（桌面：滚轮穿透到正文/缩放）。
  final void Function(PointerSignalEvent event)? onPointerSignal;

  /// BUG-1995：指针落在 barrier 上（＝**所有弹窗矩形之外**的真空白）按下**非主键**
  /// （中键/右键/侧键）时的落点。参数是 [PointerDownEvent.buttons] 位掩码原样。
  ///
  /// 为什么这条通道必须住在 barrier 里：barrier 是根 Overlay 里的 `Positioned.fill`，
  /// 叶子 `ColoredBox` 的命中行为是 **opaque**（见上文「实测澄清」），所以浮层可见期间
  /// **宿主页面根的 [Listener] 一个指针事件都收不到**（守卫
  /// `test/shortcuts/video_pointer_channel_reachability_test.dart`）。指针落在弹窗
  /// **矩形之内**的那半边由弹窗表面自己的桥承担（`dictionaryPopupPointerToken` /
  /// JS `mousedown` 回传）；**矩形之外**这半边此前没有任何鼠标通道 —— 症状就是
  /// 「侧键压在浮窗上能关，移开一点就关不掉」。
  ///
  /// 宿主应当用与弹窗表面**同一个** `dictionaryPopupPointerToken` 折 token、同一个
  /// `resolveDictionaryPopupInputToken` 解析，两个表面才不会各判各的。
  ///
  /// 不接（null）＝非主键在 barrier 上无任何效果，与本参数出现之前逐字一致。
  /// 主键与触摸永远不进这里（[domMouseButtonFromPointerButtons] 对它们返回 null），
  /// 故点击关窗 / 横拖关一层的既有语义零变化。
  final void Function(int buttons)? onNonPrimaryButtonDown;

  @override
  State<LookupDismissBarrier> createState() => _LookupDismissBarrierState();
}

class _LookupDismissBarrierState extends State<LookupDismissBarrier> {
  final BarrierSwipeDismissTracker _swipe = BarrierSwipeDismissTracker();

  /// 当前被跟踪的指针。第二根指针按下即放弃本轮（多指是缩放/翻页，不是滑关），
  /// 且不在其中一根抬起后把剩余指针重新解释成一次新的单指横滑。
  int? _tracked;
  final Set<int> _active = <int>{};

  bool get _swipeActive => widget.swipeEnabled;

  void _onPointerDown(PointerDownEvent event) {
    // BUG-1995：非主键先交给宿主按绑定分发。**纯附加**——不 return、不改下面任何一
    // 行滑关状态机，所以没接 [LookupDismissBarrier.onNonPrimaryButtonDown] 的表面
    // 行为逐字不变。主键/触摸在此恒为 null，进不来。
    if (widget.onNonPrimaryButtonDown != null &&
        domMouseButtonFromPointerButtons(event.buttons) != null) {
      widget.onNonPrimaryButtonDown!(event.buttons);
    }
    if (!_swipeActive) return;
    // 不按设备类型过滤：TODO-716 的整个目的就是「桌面对齐手机」——桌面开了滑关
    // 开关后，**鼠标**在 barrier 上横拖同样要能关一层。这与弹窗**本体**的
    // `_BodySwipeDismissDetector` 不同（本体上鼠标拖是框选正文，必须排除鼠标）；
    // barrier 是纯空白，没有可框选的内容，横拖只有关窗一种语义。
    _active.add(event.pointer);
    if (_tracked != null || _active.length != 1) {
      _tracked = null;
      _swipe.abort();
      return;
    }
    _tracked = event.pointer;
    _swipe.begin(sensitivity: widget.sensitivity);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _tracked) return;
    _swipe.update(event.delta);
  }

  void _onPointerUp(PointerUpEvent event) {
    _active.remove(event.pointer);
    if (event.pointer != _tracked) return;
    _tracked = null;
    if (_swipe.end()) widget.onSwipeDismiss();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _active.remove(event.pointer);
    if (event.pointer != _tracked) return;
    _tracked = null;
    _swipe.abort();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // 旁路观察：不参与竞技场，故不会延迟/取消下层 platform view 的手势结算。
      behavior: HitTestBehavior.translucent,
      onPointerHover: widget.onPointerHover,
      onPointerSignal: widget.onPointerSignal,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        // onTapUp（带坐标）而非 onTap：宿主要按落点分流（阅读器命中词换查词、
        // 视频点同句另一字符切换）。tap 识别器超出 slop 会主动 reject，不堵下层。
        onTapUp: (TapUpDetails d) => widget.onTapDismiss(d.globalPosition),
        child: const ColoredBox(color: Colors.transparent),
      ),
    );
  }
}

/// TODO-716/1052 + BUG-1757：barrier「水平拖过阈关一层」的纯状态追踪器。
///
/// 只被 [LookupDismissBarrier] 使用（页面不再各持一份）。除累积位移外还负责**判轴**：
/// 一旦判定本轮不是横向主导就立刻、永久放弃，绝不在轨迹后半段偏回横向时反抢——
/// 「滑到一半改主意」对用户是意外关窗，这条规则以前隐含在竞技场的 accept/reject
/// 时序里，现在是显式的、可单测的。
///
/// 灵敏度在 [begin] 时定死一次（一次手势期间不会变），[update] / [end] 不再重复
/// 接收——少一个「每次都要传对」的参数就少一处能写错的地方。
class BarrierSwipeDismissTracker {
  double _dragX = 0;
  double _dragY = 0;
  bool _tracking = false;
  bool _decided = false;
  bool _isHorizontal = false;
  double _sensitivity = 0;

  /// 判轴距离：越灵敏越早判。与 [SwipeDismissWrapper] 同公式，不漂移。
  double get _decisionDistance => 10 + (1.0 - _sensitivity) * 20;

  void begin({required double sensitivity}) {
    _sensitivity = sensitivity;
    _dragX = 0;
    _dragY = 0;
    _decided = false;
    _isHorizontal = false;
    _tracking = true;
  }

  /// 放弃本轮（多指、取消）。后续 [update] / [end] 一律无效，直到下次 [begin]。
  void abort() {
    _tracking = false;
    _decided = false;
    _isHorizontal = false;
    _dragX = 0;
    _dragY = 0;
  }

  void update(Offset delta) {
    if (!_tracking) return;
    _dragX += delta.dx;
    _dragY += delta.dy;
    if (_decided) return;
    if (_dragX.abs() <= _decisionDistance &&
        _dragY.abs() <= _decisionDistance) {
      return;
    }
    _decided = true;
    // 强横向意图才算滑关。其余轨迹固定判为下层滚动，后续即使偏回横向也不反抢
    // （与 `_BodySwipeDismissDetector` 同语义：纵向轨迹永不打扰 WebView 原生滚动）。
    _isHorizontal = _dragX.abs() > _dragY.abs() * 2.5;
    if (!_isHorizontal) _tracking = false;
  }

  /// 松手：判定为横向且过阈返回 true（调用方关一层），否则 false。无论如何都复位。
  bool end() {
    final bool passed = _tracking &&
        _decided &&
        _isHorizontal &&
        _dragX.abs() > swipeDismissThreshold(_sensitivity);
    abort();
    return passed;
  }

  /// 测试可见：当前是否已判定为横向滑关轨迹。
  @visibleForTesting
  bool get debugIsHorizontal => _decided && _isHorizontal;
}
