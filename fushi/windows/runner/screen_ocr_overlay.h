#ifndef RUNNER_SCREEN_OCR_OVERLAY_H_
#define RUNNER_SCREEN_OCR_OVERLAY_H_

#include <windows.h>

#include <d2d1.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "screen_ocr_logic.h"

// 桌面应用外悬浮球「截屏识字」的冻结层（Windows）。
// 契约：docs/specs/2026-09-30-desktop-system-floating-ball.md「截屏识字」。
//
// 截一整块显示器后立刻用这张截图盖满该显示器（画面「定格」），上面画识别出的行框与
// 顶部提示条。窗口 WS_POPUP + TOPMOST + TOOLWINDOW，客户区 = 显示器矩形（物理像素），
// 所以客户区坐标就是截图像素坐标。显示时取一次前台（为了收 Esc），之后点击一律不激活、
// 不改 Z 序——查词卡（HWND_TOPMOST、后到者在上）弹在它上面。
//
// 原生只负责画与收输入：左键（非关闭钮 / 提示条）→ TapCallback（截图像素），由 Dart
// 命中测试并决定是否关层；Esc / 右键 / 关闭钮 → 自己关层后 DismissCallback。
// 全部方法都在 runner 主线程（平台线程）调用。
class ScreenOcrOverlay {
 public:
  struct Style {
    std::wstring recognizing;  // 识别中的提示
    std::wstring hint;         // 识别完、没有 message 时的提示（「点文字查词」）
    std::wstring close;        // 关闭钮的悬停提示
    uint32_t primary = 0xFF6750A4;
    uint32_t surface = 0xFFFEF7FF;
    uint32_t on_surface = 0xFF1D1B20;
  };

  // 一张整块显示器的截图：32bpp BGRA（alpha 已置 255），stride = width * 4。
  struct Capture {
    HMONITOR monitor = nullptr;
    RECT screen = {};  // 显示器矩形（物理像素、虚拟桌面坐标）
    int width = 0;
    int height = 0;
    std::vector<uint8_t> bgra;
  };

  using TapCallback = std::function<void(int x, int y)>;
  using DismissCallback = std::function<void()>;

  ScreenOcrOverlay();
  ~ScreenOcrOverlay();

  ScreenOcrOverlay(const ScreenOcrOverlay&) = delete;
  ScreenOcrOverlay& operator=(const ScreenOcrOverlay&) = delete;

  void SetTapCallback(TapCallback callback) { on_tap_ = std::move(callback); }
  void SetDismissCallback(DismissCallback callback) {
    on_dismiss_ = std::move(callback);
  }

  // GDI BitBlt（CAPTUREBLT，含分层窗）截 |monitor| 整块。调用方负责先把不该入镜的
  // 窗口藏好并 DwmFlush。
  static bool CaptureMonitor(HMONITOR monitor, Capture* out);

  // 显示冻结层（已显示则先关掉旧的，不回调），提示条显示 style.recognizing。
  // 成功时 |capture| 的像素被本类接管。
  bool Show(Capture capture, const Style& style);
  // 画行框（截图像素坐标）；|message| 有值时替换提示文字，否则显示 style.hint。
  void Update(std::vector<fushi::screen_ocr::RectD> lines,
              std::optional<std::wstring> message);
  // 关层，不回调。
  void Close();
  bool IsShowing() const;
  // 正显示的那张截图（Show 之后有效，Close 后清空）。
  const Capture& capture() const { return capture_; }

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  LRESULT HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                        LPARAM lparam) noexcept;

  void EnsureWindowClass();
  bool EnsureFactories();
  bool EnsureRenderTarget();
  void DiscardRenderTarget();
  void Render();
  // 按当前提示文字量出提示条几何（提示条 / 关闭钮的命中也用它）。
  void Relayout();
  void UpdateCloseTooltip();
  void Dismiss();

  const std::wstring& BannerText() const;

  HWND hwnd_ = nullptr;
  bool class_registered_ = false;
  Capture capture_;
  Style style_;
  double scale_ = 1.0;
  bool recognized_ = false;
  std::optional<std::wstring> message_;
  std::vector<fushi::screen_ocr::RectD> lines_;
  fushi::screen_ocr::BannerLayout banner_;
  Microsoft::WRL::ComPtr<IDWriteTextLayout> banner_text_;
  bool close_hovered_ = false;
  bool tracking_leave_ = false;
  HWND tooltip_hwnd_ = nullptr;

  Microsoft::WRL::ComPtr<ID2D1Factory> d2d_factory_;
  Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_factory_;
  Microsoft::WRL::ComPtr<IDWriteTextFormat> text_format_;
  double text_format_scale_ = 0;
  Microsoft::WRL::ComPtr<ID2D1HwndRenderTarget> render_target_;
  Microsoft::WRL::ComPtr<ID2D1Bitmap> screenshot_;

  TapCallback on_tap_;
  DismissCallback on_dismiss_;
};

#endif  // RUNNER_SCREEN_OCR_OVERLAY_H_
