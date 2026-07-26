#ifndef RUNNER_WINDOW_CAPTURE_H_
#define RUNNER_WINDOW_CAPTURE_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

// TODO-1162 外部窗口挖矿 M0（仅 Windows）：枚举可见顶层窗口 + 对选定窗口用
// Windows.Graphics.Capture 抓一帧静态截图（转 PNG）。纯 WRL/ABI 实现（runner 以
// _HAS_EXCEPTIONS=0 编译，故不用 C++/WinRT 投影类型，全程 HRESULT 校验、不抛异常）。
namespace hibiki {

// 一个可捕获的外部顶层窗口：native 句柄 + UTF-8 标题 + 所属进程 PID。
struct ExternalWindow {
  HWND hwnd = nullptr;
  std::string title;  // UTF-8
  DWORD pid = 0;      // 所属进程 PID（galgame voice hook 注入目标；见 voice_hook_reader）
};

// 单帧窗口捕获结果：成功带 PNG 字节，失败带人类可读原因。
// [ok] 仅当 png 非空且 error 空时为 true。
struct WindowCaptureResult {
  std::vector<uint8_t> png;
  std::string error;
  // BUG-1096：**成功路径**上值得记录的事实，非空即有话说，空 = 一切如预期。
  // 目前两类：① 光标合成抑制没能生效（IGraphicsCaptureSession2 缺失 / put_ 失败，
  // 以前这两处 HRESULT 都被静默丢掉，用户机器上到底有没有关掉光标完全不可证）；
  // ② 捕获目标被从 Magpie 缩放窗重定向到了真实源窗口。与 [error] 正交：有
  // diagnostics 不代表失败，[ok] 不受它影响。
  std::string diagnostics;
  bool ok = false;
};

// BUG-1096：把 Magpie（及同类缩放工具）的缩放窗口解析成它正在缩放的**源窗口**。
// Magpie 的缩放窗口上挂着窗口属性 `Magpie.SrcHWND` 指向源窗口（类名形如
// `Window_Magpie_<GUID>`，但属性名才是稳定契约，故只按属性判定）。Magpie 自己也
// 关掉了 WGC 合成光标、再按 cursorScaling 把光标**画进**缩放输出，所以抓它的窗口
// 必然得到「游戏自绘光标 + Magpie 补画的一个」= 两个指针。返回 nullptr 表示不是
// 这种窗口（或属性指向的句柄已失效），调用方保持原窗口不变。绝不抛异常。
HWND ResolveScalingSourceWindow(HWND hwnd);

// 枚举可见、有标题、未 cloaked 的顶层窗口（排除自身 [self]，绝不截自己）。
// 按 EnumWindows 的 Z 序返回；Magpie 缩放窗按 [ResolveScalingSourceWindow] 重定向到
// 源窗口，并按 hwnd 去重（重定向后可能与单独枚举到的源窗口重合）。绝不抛异常。
std::vector<ExternalWindow> EnumerateTopLevelWindows(HWND self);

// 对 [hwnd] 抓一帧（Windows.Graphics.Capture）转 PNG 字节。任何失败（系统不支持 /
// 窗口已关 / DRM 黑帧 / 超时 / D3D/WIC 失败）返回带非空 error、空 png 的结果。
// BUG-1096：绑定前先过 [ResolveScalingSourceWindow]，命中 Magpie 缩放窗时改抓源窗口。
// 同步运行在**调用线程**上（自建 WinRT MTA apartment，用完即退）；调用方应放到
// 非 UI 线程调用（会阻塞等首帧，最长约 1.5s）。绝不抛异常。
WindowCaptureResult CaptureWindowPng(HWND hwnd);

}  // namespace hibiki

#endif  // RUNNER_WINDOW_CAPTURE_H_
