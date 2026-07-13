/// 查词弹窗「最大宽高」的有效尺寸解析（纯函数，单元可测）。
///
/// 弹窗尺寸只有一个真值——「最大宽高」。三种形态（app 内 / app 外覆盖窗 /
/// 浏览器扩展）默认共享 app 内的 [popupMaxWidth]/[popupMaxHeight]；某个形态被
/// 用户显式「解锁独立尺寸」后，改用该形态自己的宽/高键。这里把这条决策抽成不依赖
/// 任何 Flutter/FFI 的纯函数，供 controller、app_model、Phase C/D 复用与单测。
library;

/// 一对「最大宽 × 最大高」逻辑像素值。
class LookupSize {
  const LookupSize(this.width, this.height);

  final double width;
  final double height;

  @override
  bool operator ==(Object other) =>
      other is LookupSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'LookupSize(${width}x$height)';
}

/// 解析某个查词形态（app 外覆盖窗 / 浏览器扩展）的有效最大宽高。
///
/// - [independent] 为 `true`：该形态已解锁独立尺寸，用它自己的
///   [sceneWidth]/[sceneHeight]。
/// - [independent] 为 `false`：跟随 app 内共享值 [sharedWidth]/[sharedHeight]。
///
/// app 内弹窗本身无「跟随/独立」之分，恒等于共享值，直接读 [popupMaxWidth] 即可，
/// 不必经此函数。
LookupSize effectiveLookupSize({
  required bool independent,
  required double sceneWidth,
  required double sceneHeight,
  required double sharedWidth,
  required double sharedHeight,
}) {
  if (independent) {
    return LookupSize(sceneWidth, sceneHeight);
  }
  return LookupSize(sharedWidth, sharedHeight);
}
