#pragma once

#include <windows.h>

#include <cstdint>

// 「某个游戏进程当前的客户区」这一件事的**唯一实现**。
//
// 为什么要单独一个头：这份查询原本只活在 global_lookup_window.cpp 的匿名 namespace
// 里，只有 present 时刻（RevealOverProcessClient）才跑。于是 Dart 侧想在**查词开始
// 之前**知道客户区尺寸，就只能等上一次 present 的回执——本局第一次查词永远拿不到，
// 卡片上界只能退回画布口径（BUG-2066 的原始症状）。把它抽成共享原语后，reader 在
// 发 hit 的同一时刻就能把客户区量出来随 hit 一起上报，缓存和它的失效规则整个消失。
//
// 纪律：客户区是**每一刻的事实**，不是会话级常量（玩家中途全屏↔窗口化就变了），所以
// 这里只提供"现在量一次"，不提供任何缓存。
namespace fushi {
namespace game_client_extent {

struct ProcessWindowCandidate {
  uint32_t pid = 0;
  HWND hwnd = nullptr;
  uint64_t client_area = 0;
};

inline bool UsableProcessClientWindow(HWND hwnd, uint32_t pid, uint64_t* area) {
  if (hwnd == nullptr || pid == 0 || !IsWindowVisible(hwnd) ||
      GetAncestor(hwnd, GA_ROOT) != hwnd) {
    return false;
  }
  DWORD window_pid = 0;
  GetWindowThreadProcessId(hwnd, &window_pid);
  if (window_pid != pid) return false;
  RECT client = {};
  if (!GetClientRect(hwnd, &client)) return false;
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0) return false;
  if (area != nullptr) {
    *area = static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
  }
  return true;
}

inline BOOL CALLBACK FindLargestProcessWindow(HWND hwnd, LPARAM data) {
  auto* candidate = reinterpret_cast<ProcessWindowCandidate*>(data);
  if (candidate == nullptr) return FALSE;
  uint64_t area = 0;
  if (UsableProcessClientWindow(hwnd, candidate->pid, &area) &&
      area > candidate->client_area) {
    candidate->hwnd = hwnd;
    candidate->client_area = area;
  }
  return TRUE;
}

inline HWND FindProcessClientWindow(uint32_t pid) {
  if (pid == 0) return nullptr;
  // 热路优先前台 HWND：查词命中只能来自当前正在玩的窗口，也避免多窗口引擎里
  // “面积最大的隐藏工具窗”碰巧赢过真正渲染窗。失焦恢复时再退到可见客户区最大者。
  HWND foreground = GetForegroundWindow();
  if (UsableProcessClientWindow(foreground, pid, nullptr)) return foreground;
  ProcessWindowCandidate candidate;
  candidate.pid = pid;
  EnumWindows(&FindLargestProcessWindow, reinterpret_cast<LPARAM>(&candidate));
  return candidate.hwnd;
}

// 量一次 [pid] 的游戏客户区（物理像素）。量不到时两个出参写 0 并返回 false——
// 调用方据此退回画布口径，**绝不**拿 0 当尺寸继续算。
inline bool QueryGameClientExtent(uint32_t pid, int32_t* out_width,
                                  int32_t* out_height) {
  if (out_width != nullptr) *out_width = 0;
  if (out_height != nullptr) *out_height = 0;
  HWND game = FindProcessClientWindow(pid);
  if (game == nullptr) return false;
  RECT client = {};
  if (!GetClientRect(game, &client)) return false;
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0) return false;
  if (out_width != nullptr) *out_width = width;
  if (out_height != nullptr) *out_height = height;
  return true;
}

}  // namespace game_client_extent
}  // namespace fushi
