#ifndef RUNNER_FLOATING_BALL_WINDOW_H_
#define RUNNER_FLOATING_BALL_WINDOW_H_

#include <windows.h>

#include <d2d1.h>
#include <dwrite.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "floating_ball_geometry.h"

// 桌面应用外悬浮球（Windows）。契约：docs/specs/2026-09-30-desktop-system-floating-ball.md。
//
// 与 Android FloatingBallService 同形：两个自有的分层顶层窗（不是 Flutter 视图、
// 不以主窗为 owner——主窗最小化时球不能跟着藏）：
//   - 球窗：固定尺寸（球 + 阴影边），只画球，永远不改大小（DPI 变化除外）；
//   - 按钮窗：点球展开时按**最终几何**一次建好、首帧按钮全透明，之后只做动画，
//     收起动画结束才销毁（BUG-2793：单窗口先变大、下一帧才挪位会整块跳一下）。
// 两窗都是 WS_EX_LAYERED | TOPMOST | TOOLWINDOW | NOACTIVATE，UpdateLayeredWindow
// 逐像素 alpha（全透明像素点击穿透），D2D 画进 DIB。点球 / 点按钮都不抢前台
// （WM_MOUSEACTIVATE → MA_NOACTIVATE），否则「应用外查词」取不到别的程序的选区。
//
// 原生只负责画、拖、吸附、动画，并把「点了哪颗、球在哪」经回调报给 Dart；
// 不执行任何查词逻辑。全部方法都在 runner 主线程（平台线程）调用。
class FloatingBallWindow {
 public:
  struct Config {
    // Dart 按墨水屏 / 系统减弱动画统一下发；旧调用缺字段时保留原动画。
    bool animate = true;
    // 只控制可见标签；labels 仍用于 tooltip 和操作名称。
    bool show_labels = true;
    // Dart 勾选的动作 id（自上而下）；open_app / close 由本类固定加在最上。
    std::vector<std::string> actions;
    // 按钮文案 / tooltip：键为动作 id + open_app / close / ball。
    std::map<std::string, std::wstring> labels;
    // 每颗按钮的图标 PNG（66×66，前景色已着好）。
    std::map<std::string, std::vector<uint8_t>> icon_images;
    // 球面 PNG。
    std::vector<uint8_t> ball_image;
    // Material 3 基线配色兜底（Dart 没下发时）。
    uint32_t surface = 0xFFFEF7FF;
    uint32_t on_surface = 0xFF1D1B20;
    uint32_t primary = 0xFF6750A4;
    // M3E 角色（Dart floatingBallNativeColors）：球本体 FAB 底色（球面 PNG 缺失
    // 时的纯色兜底）、tonal 小圆钮底色 / 图标色、描边（只有墨水屏不透明，其余
    // 全透明 = 不画环）。0 = Dart 没下发，按旧配方兜底。
    uint32_t ball_container = 0xFFEADDFF;
    uint32_t button_container = 0;
    uint32_t on_button_container = 0;
    uint32_t outline = 0;
    // 展开态球（M3E FAB menu 的关闭钮）：primary 底 + onPrimary ×（墨水屏 surface /
    // onSurface）。× 图标 PNG 在 icon_images["ball_close"]。
    uint32_t ball_open = 0xFF6750A4;
    uint32_t on_ball_open = 0xFFFFFFFF;
  };

  // |anchor| = 球在屏幕上的矩形（物理像素、左上原点）。
  using ActionCallback =
      std::function<void(const std::string& id, const RECT& anchor)>;
  // 用户点了关闭：窗口已销毁。
  using ClosedCallback = std::function<void()>;
  // 拖动松手吸附后报一次位置。
  using PositionCallback =
      std::function<void(bool dock_left, double fraction)>;

  FloatingBallWindow();
  ~FloatingBallWindow();

  FloatingBallWindow(const FloatingBallWindow&) = delete;
  FloatingBallWindow& operator=(const FloatingBallWindow&) = delete;

  void SetActionCallback(ActionCallback callback) {
    on_action_ = std::move(callback);
  }
  void SetClosedCallback(ClosedCallback callback) {
    on_closed_ = std::move(callback);
  }
  void SetPositionCallback(PositionCallback callback) {
    on_position_ = std::move(callback);
  }

  // 未运行则按 |dock_left| + |fraction| 在 |monitor_hint| 所在显示器上创建；已运行则
  // 原地更新按钮 / 配色 / 图片（不挪位置、收起菜单，忽略位置参数）。
  bool Start(const Config& config, bool dock_left, double fraction,
             HWND monitor_hint);
  // 销毁全部窗口；不触发任何回调。
  void Stop();
  bool IsRunning() const;

  // 截屏识字（spec「截屏识字」）：截图前把球、按钮列与提示藏起来——不销毁、不打断
  // 动画与停靠状态（收起动画照常在隐藏中跑完）；冻结层关掉后原样恢复。未运行时无操作。
  void HideForCapture();
  void RestoreAfterCapture();

 private:
  struct Screen {
    HMONITOR monitor = nullptr;
    fushi::floating_ball::Rect viewport;
    double scale = 1.0;
    bool tuck_left = true;
    bool tuck_right = true;
  };

  struct ProgressAnimation {
    bool active = false;
    double from = 0;
    double to = 0;
    double start_ms = 0;
    double duration_ms = 1;
  };

  struct SnapAnimation {
    bool active = false;
    double from_left = 0;
    double from_top = 0;
    double to_left = 0;
    double to_top = 0;
    double start_ms = 0;
  };

  struct CachedBitmap {
    UINT px = 0;
    Microsoft::WRL::ComPtr<ID2D1Bitmap> bitmap;
    bool failed = false;
  };

  static LRESULT CALLBACK BallWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) noexcept;
  static LRESULT CALLBACK MenuWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) noexcept;
  LRESULT HandleBallMessage(HWND hwnd, UINT message, WPARAM wparam,
                            LPARAM lparam) noexcept;
  LRESULT HandleMenuMessage(HWND hwnd, UINT message, WPARAM wparam,
                            LPARAM lparam) noexcept;

  void EnsureWindowClasses();
  bool EnsureDeviceResources();
  void DiscardDeviceResources();

  // 按钮自上而下：close、open_app、然后 Dart 的动作。
  std::vector<std::string> ButtonIds() const;
  std::wstring LabelFor(const std::string& id) const;

  Screen ScreenFor(HMONITOR monitor, double probe_y) const;
  fushi::floating_ball::Geometry GeometryFor(const Screen& screen,
                                             bool dock_left,
                                             double fraction) const;
  // 当前停靠边 + 比例在 monitor_ 上的几何（会顺手校正失效的 monitor_ 与 scale_）。
  fushi::floating_ball::Geometry CurrentGeometry();

  // 球窗边长（px）与球径（px）按 scale_。
  int BallWindowSize() const;
  double BallPx() const;

  void SetExpanded(bool expand);
  void AnimateProgress(double target, int full_ms);
  void CollapseImmediately();
  void CancelAnimations();
  void SetProgress(double t);
  void EnsureAnimationTimer();
  void OnAnimationTick();

  void EnsureMenuWindow();
  void DestroyMenuWindow();
  // 按钮窗坐标系里、当前进度下第 |index| 颗的圆心与半径；opacity 为 0 时不可点。
  bool ButtonCircle(int index, double* cx, double* cy, double* radius,
                    double* opacity) const;
  int ButtonAt(double x, double y) const;
  // 单列且横向放得下时为每颗按钮排好标签胶囊（DirectWrite 布局 + 宽度）；否则清空。
  void PrepareMenuLabels(const fushi::floating_ball::Geometry& g);
  // 当前进度下第 |index| 颗的标签胶囊（按钮窗坐标）；没有标签返回 false。
  bool LabelRect(int index, D2D1_RECT_F* rect, double* opacity) const;
  void RunButton(int index);
  void UpdateTooltip(int index);
  void HideTooltip();

  void BeginDrag();
  void DragTo(POINT cursor);
  void EndDrag();

  // 显示器配置 / 工作区 / DPI 变化：视口或 DPI 真的变了才收起并重摆。
  void OnDisplayEnvironmentChanged(bool force);

  RECT BallScreenRect() const;
  void RenderBall();
  void RenderMenu();
  // 画进 DIB 再 UpdateLayeredWindow 推到 |hwnd|（位置 = (x, y)，尺寸 = w×h）。
  template <typename DrawFn>
  bool RenderLayered(HWND hwnd, int x, int y, int w, int h, BYTE alpha,
                     DrawFn draw);
  void DrawSoftShadow(float cx, float cy, float radius, float blur,
                      float alpha);

  ID2D1Bitmap* BitmapFor(const std::string& key,
                         const std::vector<uint8_t>& png, UINT px,
                         bool crop_square);
  void ClearBitmapCache();

  Config config_;
  bool dock_left_ = false;
  double fraction_ = 1.0 / 3.0;
  HMONITOR monitor_ = nullptr;
  double scale_ = 1.0;
  RECT last_work_ = {};
  UINT last_dpi_ = 0;

  HWND ball_hwnd_ = nullptr;
  // HideForCapture 生效中：新建的按钮窗也保持隐藏，直到 RestoreAfterCapture。
  bool hidden_for_capture_ = false;
  HWND menu_hwnd_ = nullptr;
  bool classes_registered_ = false;

  // 球左上角（屏幕物理 px）。
  double ball_left_ = 0;
  double ball_top_ = 0;

  double progress_ = 0;
  bool expand_target_ = false;
  ProgressAnimation progress_anim_;
  SnapAnimation snap_anim_;
  bool timer_running_ = false;

  // 球上的指针手势。
  bool pressing_ball_ = false;
  bool dragging_ = false;
  POINT down_point_ = {};
  double drag_start_left_ = 0;
  double drag_start_top_ = 0;

  // 按钮窗（最终几何，按钮窗坐标系）。
  POINT menu_origin_ = {};
  SIZE menu_size_ = {};
  std::vector<std::string> menu_ids_;
  std::vector<fushi::floating_ball::Offset> menu_centers_;
  double menu_ball_cx_ = 0;
  double menu_ball_cy_ = 0;
  double menu_scale_ = 1.0;
  int hovered_ = -1;
  int pressed_ = -1;
  bool tracking_leave_ = false;

  HWND tooltip_hwnd_ = nullptr;
  int tooltip_index_ = -1;
  std::wstring tooltip_text_;

  Microsoft::WRL::ComPtr<ID2D1Factory> d2d_factory_;
  Microsoft::WRL::ComPtr<ID2D1DCRenderTarget> render_target_;
  Microsoft::WRL::ComPtr<IWICImagingFactory> wic_factory_;
  Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_factory_;
  Microsoft::WRL::ComPtr<IDWriteTextFormat> label_format_;
  double label_format_scale_ = 0;
  // 与 menu_ids_ 一一对应；空 = 本次展开不显示标签。
  std::vector<Microsoft::WRL::ComPtr<IDWriteTextLayout>> menu_label_layouts_;
  std::vector<double> menu_label_widths_;
  std::map<std::string, CachedBitmap> bitmaps_;

  ActionCallback on_action_;
  ClosedCallback on_closed_;
  PositionCallback on_position_;
};

#endif  // RUNNER_FLOATING_BALL_WINDOW_H_
