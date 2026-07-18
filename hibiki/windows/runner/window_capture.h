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
  bool ok = false;
};

// 枚举可见、有标题、未 cloaked 的顶层窗口（排除自身 [self]，绝不截自己）。
// 按 EnumWindows 的 Z 序返回。绝不抛异常。
std::vector<ExternalWindow> EnumerateTopLevelWindows(HWND self);

// 对 [hwnd] 抓一帧（Windows.Graphics.Capture）转 PNG 字节。任何失败（系统不支持 /
// 窗口已关 / DRM 黑帧 / 超时 / D3D/WIC 失败）返回带非空 error、空 png 的结果。
// 同步运行在**调用线程**上（自建 WinRT MTA apartment，用完即退）；调用方应放到
// 非 UI 线程调用（会阻塞等首帧，最长约 1.5s）。绝不抛异常。
WindowCaptureResult CaptureWindowPng(HWND hwnd);

}  // namespace hibiki

#endif  // RUNNER_WINDOW_CAPTURE_H_
