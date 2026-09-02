#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

// 游戏内查词卡「直连覆盖窗」路径的画布→客户区几何映射（纯函数，单元可测）。
//
// hook 报上来的 anchor 与 view 都在**游戏画布（KiriKiri primaryLayer）像素**域，
// 而覆盖窗是屏幕空间的真实 HWND，卡片尺寸是 WebView 的**物理像素**。引擎把画布等比
// 缩放进客户区并居中，所以两域之间只差一个 scale 和一对信箱边。
//
// 纪律：**只映射位置，不缩放卡片**。
//   * 卡片保持自身物理像素 —— 这既是它清晰的原因（不经画布重采样），也让它与台词
//     浮窗处在同一尺度，否则同一份查词在两个入口下大小不一致。
//   * 缩放 HWND 等于改 Chromium 视口，会让卡片重排；直连路径原先被锁死在 1:1 正是
//     顾虑这一点。这里不缩放卡片，该顾虑因此不成立。
//
// 1:1（scale==1、信箱边为 0）时**本文件三个映射函数**的结果与旧的硬编码路径逐像素
// 相同：scale 恒为 1、LetterboxOffset 恒为 0、ClampDirectCardOrigin 的夹取区间与旧的
// 客户区夹取一致。
//
// 但**整条直连路径**在 1:1 下的落点已经变了，因为 [GlyphAnchoredCardOrigin] 在字形
// 有效时无条件接管定位，不再沿用 Dart 按画布尺寸算好的 anchor：
//
//   | 轴 | 旧（Dart computeFrameRect 的 anchor 原样映射） | 新（GlyphAnchoredCardOrigin） |
//   |----|--------------------------------------------|------------------------------|
//   | 水平 | 卡片**左边缘**对齐字形左边（rawX = selX + w/2） | 卡片**中心**对齐字形中心 |
//   | 垂直 | 优先**下方**，间隙 popupPadding=4，并按 screenBorderPadding=6 夹取 | 优先**上方**，**零间隙**；上方放不下才翻到下方 |
//
// 这是**有意**的策略变更：卡片保持自身物理像素后，它相对字形的正确位置只能在屏幕空间
// 重排（按画布 anchor 乘 scale 会让卡片离命中的字 (scale-1)x卡片高）。代价是改动前
// 唯一能走直连的那批 1:1 用户会看到位置变化——563 宽的卡片配 24 宽的字形，水平方向
// 约 270px。字形无效（glyph_w/h == 0）时才退回旧的 anchor 映射，那条路径在 1:1 下确实
// 与旧行为逐像素相同。
namespace fushi {
namespace gal_direct_card_geometry {

// 画布→客户区的等比缩放系数。取两轴较小者以匹配引擎的「等比缩放 + 居中」。
// view 任一轴为 0 时返回 0（调用方须据此拒绝直连，不得当作 1 继续）。
inline double CanvasToClientScale(int client_width, int client_height,
                                  uint32_t view_width, uint32_t view_height) {
  if (client_width <= 0 || client_height <= 0 || view_width == 0 ||
      view_height == 0) {
    return 0.0;
  }
  return (std::min)(static_cast<double>(client_width) / view_width,
                    static_cast<double>(client_height) / view_height);
}

// 单轴的信箱边（画布内容在客户区中的起始偏移）。
inline double LetterboxOffset(int client_extent, uint32_t view_extent,
                              double scale) {
  return (static_cast<double>(client_extent) - view_extent * scale) * 0.5;
}

// 把映射后的卡片原点夹回客户区内。
//
// 为什么必须夹：Dart 的夹取发生在**画布**坐标系（工作区取 view 尺寸），当
// scale < 1（客户区比画布小，例如窗口被缩小）时，画布内合法的原点映射回屏幕会越过
// 客户区右/下边，卡片就会跑到游戏画面外。卡片比客户区还大时以 0 兜底，宁可左上对齐
// 也不给出负坐标。
inline int ClampDirectCardOrigin(double local, int card_extent,
                                 int client_extent) {
  const double max_origin =
      static_cast<double>(client_extent) - static_cast<double>(card_extent);
  double clamped = local;
  if (clamped > max_origin) clamped = max_origin;
  if (clamped < 0.0) clamped = 0.0;
  return static_cast<int>(std::lround(clamped));
}

// 卡片相对字形的贴附原点（客户区局部坐标，未夹取）。
//
// 卡片保持自身物理像素，所以贴附必须以字形的**屏幕**矩形为基准重排，而不能沿用 Dart
// 按画布尺寸算好的 anchor。策略：水平居中于字形，优先贴在字形正上方（零间隙）；
// 上方放不下才翻到下方。两侧都放不下时仍返回上方值，由调用方的夹取兜底。
//
// **这不是旧行为的等价重写**，1:1 下也一样：旧路径水平是左边缘对齐字形左边、垂直优先
// 下方且带 4px 间隙。差异与理由见文件头的对照表。
struct CardOrigin {
  double left;
  double top;
};

inline CardOrigin GlyphAnchoredCardOrigin(double glyph_left, double glyph_top,
                                          double glyph_width,
                                          double glyph_height, int card_width,
                                          int card_height) {
  const double left =
      glyph_left + glyph_width * 0.5 - static_cast<double>(card_width) * 0.5;
  const double above = glyph_top - static_cast<double>(card_height);
  const double below = glyph_top + glyph_height;
  return CardOrigin{left, above >= 0.0 ? above : below};
}

}  // namespace gal_direct_card_geometry
}  // namespace fushi
