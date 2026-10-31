import 'dart:math' as math;

/// 纹理容量（物理像素）：native 共享目标纹理与 WGC 帧池按它分配，WebView 的可见内容
/// 只占左上角 `ceil(布局尺寸 × 栅格倍率)` 那一块。
typedef TextureCapacity = ({int width, int height});

/// 扩容时的取整步长（物理像素）。吸收滚动条出现 / 消失、DPI 取整、侧栏开合这类几十
/// 像素的来回抖动：扩过一次容之后，同一档内改尺寸不重新分配任何显存。首份分配不取整
/// （见 [nextTextureCapacity]）。
const int kTextureCapacityStep = 256;

/// 已有容量放不下时的几何增长倍率。拖动窗口边框一路放大时，按 1.5 倍跳档而不是每帧
/// 贴身分配，从半屏拖到满屏只扩 2～3 次；封顶见 [nextTextureCapacity] 的显示器上限。
const double kTextureCapacityGrowth = 1.5;

/// BUG-3913：算 WebView 纹理的下一份容量。
///
/// 背景：Windows 上每换一次共享目标纹理（新尺寸 = 新 DXGI 共享句柄），Flutter 引擎
/// （`external_texture_d3d.cc` → ANGLE `eglCreatePbufferFromClientBuffer`）为旧句柄打开的
/// 资源不随 `eglDestroySurface` 归还；WGC 帧池每重建一次也留下一份缓冲。于是 WebView
/// 每改一次尺寸显存就固定上涨、永不回收（4K 200% 下歌词模式涨到 7 GB）。插件侧无法让
/// 引擎 / 系统归还，只能让「换句柄 / 重建帧池」本身变成罕见事件：容量只增不减、
/// 放得下就原样复用。
///
/// 规则：
/// - 两维都放得下（[current] ≥ [needed]）：原样返回，不重新分配；
/// - 首次（当前为 0）：**贴身**，正好是 [needed]，不取整、不放大。多数 WebView（查词
///   弹窗、歌词层、正文）一辈子不改尺寸，首份分配就是它全部的显存；取整到 256 档会让
///   每个实例白占约 18%（2576×1892 → 2816×2048），而每新建一个 WebView 那一份都会
///   被引擎 / 系统侧留下，等于把每实例的残留一起放大；
/// - 增长（任一维放不下）：两维都取 `max(needed, current × 1.5)` 再取整到
///   [kTextureCapacityStep]，但**不超过显示器尺寸**，也不低于当前容量——真在改尺寸的
///   WebView 从第一次扩容起就进入「取整 + 几何增长」，一路放大最终停在显示器尺寸上，
///   此后任何改尺寸都在容量内；内容本身大过显示器（多屏跨屏、屏外大窗口）时不设
///   上限，只取整。
///
/// 返回值任一维都 ≥ [needed]。[display] 为 0 表示拿不到显示器尺寸（无上限）。
TextureCapacity nextTextureCapacity({
  required TextureCapacity current,
  required TextureCapacity needed,
  required TextureCapacity display,
}) {
  if (needed.width <= current.width && needed.height <= current.height) {
    return current;
  }
  // 一旦要扩，两维一起按同一规则跳档：只扩放不下的那一维的话，拖动窗口对角时宽和高
  // 会在不同时刻轮流越界，扩容次数翻倍。
  return (
    width: _nextDimension(current.width, needed.width, display.width),
    height: _nextDimension(current.height, needed.height, display.height),
  );
}

int _nextDimension(int current, int needed, int display) {
  // 首份分配贴身（见 [nextTextureCapacity]）：只有扩容才取整、才几何增长。
  if (current <= 0) return needed;
  final int grown = math.max(needed, (current * kTextureCapacityGrowth).ceil());
  final int rounded = _roundUp(grown);
  final int capped = display <= 0 || needed > display
      ? rounded
      : math.max(needed, math.min(rounded, display));
  return math.max(current, capped);
}

int _roundUp(int value) =>
    ((value + kTextureCapacityStep - 1) ~/ kTextureCapacityStep) *
    kTextureCapacityStep;

/// 布局尺寸 × 栅格倍率 → 内容需要的物理像素（向上取整，保证容量盖得住整块布局）。
TextureCapacity textureCapacityNeeded(
  double logicalWidth,
  double logicalHeight,
  double scaleFactor,
) => (
  width: (logicalWidth * scaleFactor).ceil(),
  height: (logicalHeight * scaleFactor).ceil(),
);

/// [Texture] 的摆放：native 纹理容量与算它时的栅格倍率（BUG-3913）。
class TextureLayout {
  const TextureLayout({required this.capacity, required this.scaleFactor});

  final TextureCapacity capacity;
  final double scaleFactor;

  /// 纹理在布局里的逻辑宽 = 容量物理宽 / 倍率（与屏幕像素 1:1）。
  double get logicalWidth => capacity.width / scaleFactor;

  /// 纹理在布局里的逻辑高。
  double get logicalHeight => capacity.height / scaleFactor;
}
