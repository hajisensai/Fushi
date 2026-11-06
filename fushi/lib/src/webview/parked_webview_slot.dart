import 'package:material_ui/material_ui.dart';

/// 把一个暂时用不上的 WebView 原样停在屏外、保持它的实例活着（BUG-3913）。
///
/// 为什么不卸载：Windows 上每新建一个 WebView，交给 Flutter 引擎的共享纹理与 WGC
/// 帧池都要按它的尺寸分配一份显存，实测这一份在实例销毁后并不全数归还（BUG-3913：
/// 进出一次歌词模式涨约 60 MB，插件侧的引用计数是平衡的，残留在引擎 / ANGLE 与 WGC
/// 系统侧）。复用同一个实例，这份显存只在第一次进入时分配一次，与残留在哪一层无关。
///
/// 用法：[child] 必须带一个 [GlobalKey]，并且与「在场」位置用的是同一个 key。在场 /
/// 停放切换发生在同一帧里时，Flutter 按 GlobalKey 把整棵子树（含 State 与原生
/// WebView）搬到新位置，而不是销毁重建。本组件必须是 [Stack] 的直接孩子（它返回
/// [Positioned]）。
///
/// 停放期间：不绘制、不参与命中测试与语义树（[Offstage]）、拿不到焦点
/// （[ExcludeFocus]）、动画暂停（[TickerMode]）。布局照常进行，并按 [size]（离开
/// 在场位置时量到的尺寸）摆放，让 WebView 停放时尺寸不变——Windows 侧不会因此
/// 重新下发尺寸、扩纹理容量。[size] 为 null（量不到）时铺满父级。
class ParkedWebViewSlot extends StatelessWidget {
  const ParkedWebViewSlot({super.key, required this.child, this.size});

  /// 带 [GlobalKey] 的 WebView 子树。
  final Widget child;

  /// 停放时的布局尺寸；null = 铺满父级 [Stack]。
  final Size? size;

  @override
  Widget build(BuildContext context) {
    final Widget parked = Offstage(
      child: ExcludeFocus(child: TickerMode(enabled: false, child: child)),
    );
    final Size? parkedSize = size;
    if (parkedSize == null) return Positioned.fill(child: parked);
    return Positioned(
      left: 0,
      top: 0,
      width: parkedSize.width,
      height: parkedSize.height,
      child: parked,
    );
  }
}
