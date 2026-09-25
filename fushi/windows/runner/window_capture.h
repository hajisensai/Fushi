#ifndef RUNNER_WINDOW_CAPTURE_H_
#define RUNNER_WINDOW_CAPTURE_H_

#include <windows.h>

#include <d3d11.h>

#include <wrl/client.h>

#include <cstdint>
#include <string>
#include <vector>

// TODO-1162 外部窗口挖矿 M0（仅 Windows）：枚举可见顶层窗口 + 对选定窗口用
// Windows.Graphics.Capture 抓一帧静态截图（转 PNG）。纯 WRL/ABI 实现（runner 以
// _HAS_EXCEPTIONS=0 编译，故不用 C++/WinRT 投影类型，全程 HRESULT 校验、不抛异常）。
namespace fushi {

// 一个可捕获的外部顶层窗口：native 句柄 + UTF-8 标题 + 所属进程 PID。
struct ExternalWindow {
  HWND hwnd = nullptr;
  std::string title;  // UTF-8
  DWORD pid = 0;      // 所属进程 PID（galgame voice hook 注入目标；见 voice_hook_reader）
};

// All dimensions/origins are physical screen pixels; image dimensions describe
// the encoded PNG. Completeness is false for a whole-window fallback, clipping,
// or a target/client/DPI change while WGC was waiting for its frame.
struct WindowCaptureMetadata {
  int64_t captured_hwnd = 0;
  uint32_t captured_pid = 0;
  // The HWND/PID roles are explicit when a Magpie presentation is captured
  // as a fallback. [captured_*] always names the HWND passed to WGC; it is
  // never rewritten to look like the requested source window.
  int64_t source_hwnd = 0;
  uint32_t source_pid = 0;
  int64_t presentation_hwnd = 0;
  uint32_t presentation_pid = 0;
  bool used_presentation_capture = false;
  bool presentation_viewport_complete = false;
  int source_viewport_left_px = 0;
  int source_viewport_top_px = 0;
  int source_viewport_width_px = 0;
  int source_viewport_height_px = 0;
  int destination_viewport_left_px = 0;
  int destination_viewport_top_px = 0;
  int destination_viewport_width_px = 0;
  int destination_viewport_height_px = 0;
  int client_left_px = 0;
  int client_top_px = 0;
  int client_width_px = 0;
  int client_height_px = 0;
  // Source client geometry remains explicit when the encoded image comes from
  // a verified Magpie presentation viewport. These fields describe the
  // logical source HWND and are never inferred from the presentation output.
  int source_client_left_px = 0;
  int source_client_top_px = 0;
  int source_client_width_px = 0;
  int source_client_height_px = 0;
  int source_client_dpi = 0;
  int image_width_px = 0;
  int image_height_px = 0;
  // WGC frame facts. Zero means no WGC frame reached the texture stage (for
  // example a timeout), the result used the bounded PrintWindow fallback, or an
  // older runner did not provide the fields.
  int content_width_px = 0;
  int content_height_px = 0;
  int texture_width_px = 0;
  int texture_height_px = 0;
  double dpi = 0;
  bool client_area_complete = false;
  uint64_t captured_at_tick_ms = 0;
};

// 单帧窗口捕获结果：成功带 PNG 字节，失败带人类可读原因。
// [ok] 仅当 png 非空且 error 空时为 true。
struct WindowCaptureResult {
  std::vector<uint8_t> png;
  std::string error;
  // Bounded machine-readable reason for the last attempt. This is kept
  // separate from [error], whose wording is for the immediate caller.
  // Production call sites use literals from the capture reason vocabulary;
  // it never contains window titles, paths, or Hook text.
  std::string capture_reason;
  // BUG-1096：**成功路径**上值得记录的事实，非空即有话说，空 = 一切如预期。
  // 目前两类：① 光标合成抑制没能生效（IGraphicsCaptureSession2 缺失 / put_ 失败，
  // 以前这两处 HRESULT 都被静默丢掉，用户机器上到底有没有关掉光标完全不可证）；
  // ② 捕获目标被从 Magpie 缩放窗重定向到了真实源窗口。与 [error] 正交：有
  // diagnostics 不代表失败，[ok] 不受它影响。
  std::string diagnostics;
  WindowCaptureMetadata metadata;
  bool has_metadata = false;
  bool ok = false;
};

// Read the client rectangle in the runner's physical screen-pixel space.
// The runner is PerMonitorV2; GetWindowInfo returns rcClient as one coherent
// screen-space snapshot. This avoids the cross-DPI endpoint rounding that can
// occur when GetClientRect is followed by two ClientToScreen calls on a
// DPI-unaware source window.
bool ReadPhysicalClientScreenRect(HWND hwnd, RECT* rect);

// BUG-1096：把 Magpie（及同类缩放工具）的缩放窗口解析成它正在缩放的**源窗口**。
// Magpie 的缩放窗口上挂着窗口属性 `Magpie.SrcHWND` 指向源窗口（类名形如
// `Window_Magpie_<GUID>`，但属性名才是稳定契约，故只按属性判定）。Magpie 自己也
// 关掉了 WGC 合成光标、再按 cursorScaling 把光标**画进**缩放输出，所以抓它的窗口
// 必然得到「游戏自绘光标 + Magpie 补画的一个」= 两个指针。返回 nullptr 表示不是
// 这种窗口（或属性指向的句柄已失效），调用方保持原窗口不变。绝不抛异常。
HWND ResolveScalingSourceWindow(HWND hwnd);

// Magpie 的输出窗口在窗口属性中同时公开源 viewport 与实际输出 viewport。
// 两组 RECT 都是物理屏幕像素坐标：SrcRect 是源客户区中参与缩放的区域，
// DestRect 是输出窗口中真正绘制源图像的区域（可能小于整个输出客户区）。
// 只有在 `Magpie.SrcHWND` 明确指向 [expected_source_hwnd]，且八个坐标属性
// 都存在并构成非空矩形时才返回 true；任何属性缺失、句柄失效或退化矩形都
// fail closed，调用方不得用整个 presentation client 代替未知 viewport。
struct MagpiePresentationMapping {
  HWND presentation_hwnd = nullptr;
  HWND source_hwnd = nullptr;
  RECT source_rect_screen{};
  RECT destination_rect_screen{};
};

bool ReadMagpiePresentationMapping(HWND presentation_hwnd,
                                    HWND expected_source_hwnd,
                                    MagpiePresentationMapping* mapping);

// BUG-1854：算出把 WGC 整窗纹理（[width]×[height]）裁到窗口**客户区**的子矩形。
// 客户区由 ReadPhysicalClientScreenRect 一次读出为屏幕物理像素，再与 DWM 扩展框架
// 求差；不要把 DPI-unaware 窗口的 GetClientRect 宽高加到屏幕原点。返回 true 时 [box]
// 非空且已与纹理求交；失败返回 false，调用方回退整窗（宁可带标题栏也不丢图）。单帧
// 截图与持续录制共用。绝不抛异常。
bool ComputeClientCropBox(HWND hwnd, UINT width, UINT height, RECT* box);

// D3D11 设备（BGRA 支持），硬件失败回退 WARP；两条路都失败返回空指针。
Microsoft::WRL::ComPtr<ID3D11Device> CreateD3DDevice();

// 枚举可见、有标题、未 cloaked 的顶层窗口（排除自身 [self]，绝不截自己）。
// 按 EnumWindows 的 Z 序返回；Magpie 缩放窗按 [ResolveScalingSourceWindow] 重定向到
// 源窗口，并按 hwnd 去重（重定向后可能与单独枚举到的源窗口重合）。绝不抛异常。
std::vector<ExternalWindow> EnumerateTopLevelWindows(HWND self);

// 对 [hwnd] 抓一帧（优先 Windows.Graphics.Capture；WGC item 创建失败时允许有界
// PrintWindow 兼容路径）转 PNG 字节。
// 任何后端失败（系统不支持 / 窗口已关 / DRM 黑帧 / 超时 / D3D/WIC 失败）返回带
// 非空 error、空 png 的结果。
// BUG-1096：绑定前先过 [ResolveScalingSourceWindow]，命中 Magpie 缩放窗时改抓源窗口。
// 同步运行在**调用线程**上（自建 WinRT MTA apartment，用完即退）；调用方应放到
// 非 UI 线程调用（WGC 首帧最长约 1.5s；WGC item 失败时另有固定上限的 helper
// fallback）。绝不抛异常。
WindowCaptureResult CaptureWindowPng(HWND hwnd);

// wWinMain 调用的最早 helper 分流。返回 -1 表示普通应用启动，返回其它值表示
// 当前进程已执行 `--fushi-print-window-helper` 专用入口并可直接退出；该入口不触发
// Flutter、单实例互斥量或 WebView2 初始化。
int RunPrintWindowCaptureHelperIfRequested();

}  // namespace fushi

#endif  // RUNNER_WINDOW_CAPTURE_H_
