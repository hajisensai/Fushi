import 'package:flutter/gestures.dart';

/// 收掉「按下了却再也收不到抬起」的指针（2026-10-25 用户：Windows 上底栏相机
/// 模式条拖得快就卡在半路、之后切不了模块）。
///
/// Windows 桌面上鼠标拖得快、在窗口外松开时，引擎可能只把后续的无按键移动
/// （hover）送进来，却没有那一次 `PointerUpEvent`。手势识别器于是一直以为那个
/// 指针还按着：横向拖动识别器既不结束、也不接受新的拖动（新按下只被当成同一
/// 次多指拖动的第二根手指），挂在它上面的底栏就停在半路、点 / 拖都没反应。
///
/// 这里挂一条全局指针路由，按设备记住「当前按着的指针」；同一设备随后出现
///
/// - hover 事件（只有没按键时才有，说明抬起已经发生过、只是没送到），或
/// - 另一个指针的按下（同一只鼠标不可能同时按着两个指针），
///
/// 就对那个旧指针补发一次 [GestureBinding.cancelPointer]。识别器按正常的取消
/// 路径收尾（拖动走 onEnd / onCancel），所有手势一起受益，不用每个控件各写一套
/// 兜底。触摸每根手指是不同的设备号，多指操作不会被误判。
void installStalePointerGuard() {
  if (_installed) return;
  _installed = true;
  GestureBinding.instance.pointerRouter.addGlobalRoute(_routeStalePointers);
}

bool _installed = false;

/// 设备号 → 该设备当前按着的指针号。
final Map<int, int> _downPointerByDevice = <int, int>{};

void _routeStalePointers(PointerEvent event) {
  if (event is PointerDownEvent) {
    final int? stale = _downPointerByDevice[event.device];
    if (stale != null && stale != event.pointer) {
      GestureBinding.instance.cancelPointer(stale);
    }
    _downPointerByDevice[event.device] = event.pointer;
  } else if (event is PointerUpEvent || event is PointerCancelEvent) {
    if (_downPointerByDevice[event.device] == event.pointer) {
      _downPointerByDevice.remove(event.device);
    }
  } else if (event is PointerHoverEvent) {
    final int? stale = _downPointerByDevice.remove(event.device);
    if (stale != null) GestureBinding.instance.cancelPointer(stale);
  }
}
