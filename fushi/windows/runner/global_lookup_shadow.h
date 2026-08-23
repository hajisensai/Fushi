#ifndef RUNNER_GLOBAL_LOOKUP_SHADOW_H_
#define RUNNER_GLOBAL_LOOKUP_SHADOW_H_

#include <windows.h>

#include <array>
#include <vector>

// 查词弹窗投影窗（2026-08-23，对齐 Niratan 弹窗观感）。
//
// 背景：查词浮窗/剪贴板面板是 windowed WebView2 宿主 —— 不能带 WS_EX_LAYERED
// （与 WebView2 合成面互斥，见 global_lookup_window.cpp ShowAt 注释），圆角只能
// 靠 SetWindowRgn 硬裁，而带 region 的窗口拿不到 DWM 系统投影。Niratan 的弹窗
// 是 WinUI3 context-menu presenter，投影是系统白送的；我们这边等价物只能自绘。
//
// 方案：每个 GlobalLookupWindow 配一个伴随的 layered 投影窗（本类）。
// - WS_EX_LAYERED + UpdateLayeredWindow 逐像素 alpha 画柔和投影（黑色双瓣：
//   贴边 ambient + 下偏 key，近似 Win11 flyout 阴影）；
// - WS_EX_TRANSPARENT + WS_EX_NOACTIVATE：投影环绝不吃鼠标点击、绝不参与激活
//   —— 这正是选「伴随窗」而不是「region 扩边 + CSS 画影」的原因（后者的影子
//   环会吞掉本应穿透到底下应用的点击，等于把 BUG-749 修过的问题再引回来）；
// - Z 序钉在锚窗正下方（SetWindowPos insertAfter=anchor），锚窗每次
//   WM_WINDOWPOSCHANGED（移动/缩放/显隐/置顶重申）由 GlobalLookupWindow::
//   SyncShadow 单漏斗重新同步；
// - 级联多卡：按 shellRects（BUG-749 已有的卡矩形真相源）逐卡画影，卡间空隙
//   照常穿透——视觉上等价「每卡一窗各自带影」，但不拆单 WebView 架构；
// - 卡矩形内部 alpha 一律打 0（punch-out）：面板可开整窗 LWA_ALPHA 半透明，
//   不打洞的话黑影会从半透明卡片底下透出来把内容压暗。
//
// 贴边 ambient 瓣在 d→0 处 alpha 最高，紧贴 GDI region 裁出的锯齿边缘形成
// 深色渐变过渡，顺带显著弱化 region 圆角无抗锯齿的观感（真 AA 需要逐像素
// 透明合成，而 composition 路线有真机「透明像素合成成黑」前科，见
// flutter_window.cpp RegisterClipboardPanelChannel 注释——修好 DComp 黑底前
// 不走那条路）。
class LookupShadowWindow {
 public:
  LookupShadowWindow() = default;
  ~LookupShadowWindow();

  LookupShadowWindow(const LookupShadowWindow&) = delete;
  LookupShadowWindow& operator=(const LookupShadowWindow&) = delete;

  // 把投影窗同步到 [anchor] 当前几何/可见性/Z 序之下。
  // [show]=false 或 anchor 无效 → 隐藏（窗口保留复用）。
  // [cards_css]：锚窗内各卡矩形（窗口相对 CSS px，即 shellRects 原样）；空 =
  // 整窗一张卡（面板 / 拖拽期兜底）。[radius_css]：卡圆角（CSS px，与
  // ApplyRoundedRegion 的 10px 同源）。
  // [defer_repaint]=true（模态 resize 循环中）：几何变了但不重画——每帧重画会
  // 拖慢拖拽；此时直接隐藏，WM_EXITSIZEMOVE 后的下一次 Sync 恢复。纯移动
  // （尺寸/卡矩形不变）永远走免重画的快路径，面板拖动全程影随窗走。
  void Sync(HWND anchor, bool show,
            const std::vector<std::array<double, 4>>& cards_css,
            int radius_css, bool defer_repaint);

  // 立即隐藏（锚窗 Hide/ForgetDeadWindow 用；窗口保留复用）。
  void Hide();

  // 防截屏与锚窗联动：面板开 WDA_EXCLUDEFROMCAPTURE 时投影也必须排除，否则
  // 录屏里会出现一圈"凭空的影子"泄露卡片轮廓。
  void SetBlockCapture(bool block);

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  void EnsureWindow();
  // 重画投影位图并经 UpdateLayeredWindow 提交（同时落位置+尺寸+内容）。
  // [cards_px]：投影窗本地物理 px 卡矩形；[radius_px] 物理 px 圆角。
  bool Paint(int x, int y, int width, int height,
             const std::vector<std::array<double, 4>>& cards_px, int radius_px,
             double dpr);

  HWND hwnd_ = nullptr;
  bool block_capture_ = false;
  // 上次成功提交的几何指纹——纯移动免重画的判据。
  int last_w_ = 0;
  int last_h_ = 0;
  int last_radius_px_ = 0;
  std::vector<std::array<double, 4>> last_cards_px_;
};

#endif  // RUNNER_GLOBAL_LOOKUP_SHADOW_H_
