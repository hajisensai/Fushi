import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 视频页「返回跳转前位置」胶囊的一帧布局：竖直位置、是否显示、以及算它时控制条
/// 是否可见。
///
/// qUeubxE-fM（Windows：鼠标停在胶囊边缘不动，胶囊明暗交替、上下抖、光标闪）的根因：
/// 胶囊的 top / visible 都跟着控制条可见性走，而胶囊盖在 media_kit 控制条的
/// `MouseRegion` 之上——鼠标一落到胶囊上，控制条那层就收到 onExit 立即收起 → 胶囊淡出
/// 并上移 → 鼠标又落回控制条那层 → onEnter 重新显示 → 胶囊回到鼠标下 → 再 onExit……
/// 鼠标不动也自激振荡，光标随控制条显隐一起闪。
///
/// 结构性修法：胶囊被悬停期间，它的布局冻结在悬停开始那一帧（[resolveVideoJumpPillLayout]），
/// 不再随控制条跳；悬停开始时控制条若是可见的，就把悬停算作控制条活跃（按住控制条，
/// 并把 onExit 那一下收起立刻唤回），用户看到的画面在悬停期间保持不变。
@immutable
class VideoJumpPillLayout {
  const VideoJumpPillLayout({
    required this.top,
    required this.visible,
    required this.chromeShown,
  });

  final double top;
  final bool visible;

  /// 算这一帧时控制条是否可见（悬停开始时据此决定要不要按住 / 唤回控制条）。
  final bool chromeShown;

  @override
  bool operator ==(Object other) =>
      other is VideoJumpPillLayout &&
      other.top == top &&
      other.visible == visible &&
      other.chromeShown == chromeShown;

  @override
  int get hashCode => Object.hash(top, visible, chromeShown);

  @override
  String toString() =>
      'VideoJumpPillLayout(top: $top, visible: $visible, chromeShown: $chromeShown)';
}

/// 胶囊这一帧该用的布局：悬停中且已有上一帧布局时沿用它（冻结），否则用按控制条
/// 可见性实时算出的 [live]。
VideoJumpPillLayout resolveVideoJumpPillLayout({
  required bool hovered,
  required VideoJumpPillLayout? frozen,
  required VideoJumpPillLayout live,
}) {
  if (hovered && frozen != null) return frozen;
  return live;
}

/// 胶囊自动隐藏可选秒数（设置项分段选项，0 = 不自动隐藏）。
const List<int> kVideoJumpPillAutoHideOptions = <int>[5, 10, 15, 0];

/// 胶囊自动隐藏的出厂秒数。
const int kVideoJumpPillAutoHideDefaultSeconds = 10;

/// 胶囊不悬停时这一帧是否显示：跳转后闪现窗口内或控制条可见时显示；自上次跳转 /
/// 返回 / 前进起超过自动隐藏时长（[expired]）后，控制条再出现也不画，下一次跳转再亮。
bool videoJumpPillLiveVisible({
  required bool chromeShown,
  required bool flashing,
  required bool expired,
}) => !expired && (chromeShown || flashing);

/// 胶囊悬停期间是否把控制条按住：只有悬停开始那一帧控制条本来就可见时才按（闪现态的
/// 胶囊不应把隐藏着的控制条唤出来）。
bool videoJumpPillHoverHoldsControls(VideoJumpPillLayout? atHoverStart) =>
    atHoverStart?.chromeShown ?? false;

/// 只在**子树真实命中**时算悬停的区域，并保证「进过就一定出」：子树在悬停中被卸载
/// （例如点 × 清空历史、胶囊整个消失）时也补一次 `onHoverChanged(false)`——Flutter
/// 的 [MouseRegion] 在自身被移除时不回调 onExit，按住控制条的标志会因此永远不放开。
class VideoHoverHoldRegion extends StatefulWidget {
  const VideoHoverHoldRegion({
    super.key,
    required this.onHoverChanged,
    required this.child,
  });

  final ValueChanged<bool> onHoverChanged;
  final Widget child;

  @override
  State<VideoHoverHoldRegion> createState() => _VideoHoverHoldRegionState();
}

class _VideoHoverHoldRegionState extends State<VideoHoverHoldRegion> {
  bool _hovering = false;

  void _set(bool hovering) {
    if (_hovering == hovering) return;
    _hovering = hovering;
    widget.onHoverChanged(hovering);
  }

  @override
  void dispose() {
    if (_hovering) {
      _hovering = false;
      // 卸载发生在树锁定期，回调里改 notifier 会让监听它的 builder 在锁定期 setState；
      // 推到微任务里，放开动作仍一定执行。
      final ValueChanged<bool> onHoverChanged = widget.onHoverChanged;
      scheduleMicrotask(() => onHoverChanged(false));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      hitTestBehavior: HitTestBehavior.deferToChild,
      onEnter: (PointerEnterEvent _) => _set(true),
      onExit: (PointerExitEvent _) => _set(false),
      child: widget.child,
    );
  }
}
