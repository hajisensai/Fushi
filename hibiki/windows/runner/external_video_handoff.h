#ifndef RUNNER_EXTERNAL_VIDEO_HANDOFF_H_
#define RUNNER_EXTERNAL_VIDEO_HANDOFF_H_

#include <windows.h>

#include <string>

namespace hibiki {

// TODO-904 P0 回归：单实例守卫（main.cpp）在检测到已有实例时只前置窗口就退出，
// 会把「用 Hibiki 打开视频」（文件关联 / 拖到 exe / CLI `hibiki.exe "%1"`）的视频
// 路径整个丢掉。这里用 WM_COPYDATA 把路径从第二实例跨进程转交给首实例的窗口过程，
// 保持「单实例」与「文件路径不丢」两个不变量同时成立（不放行第二实例，避免重新引入
// 双实例共享 WebView2 userDataFolder 锁冲突的放大器）。
//
// dwData 用一个固定 magic 区分本消息与其它 WM_COPYDATA（如系统拖放）；lpData 是
// UTF-8 字节（不含结尾 NUL，长度由 cbData 给出）。

// WM_COPYDATA 的 dwData magic：标记这是 Hibiki 外部视频路径转交消息。
inline constexpr ULONG_PTR kExternalVideoCopyDataMagic = 0x48564944;  // 'HVID'

// 第二实例调用：把 [video_path]（UTF-16）以 UTF-8 字节经 WM_COPYDATA 发给首实例
// 窗口 [target]。空路径或转换失败时不发送。返回是否真正发送了消息。
bool SendExternalVideoPath(HWND target, const std::wstring& video_path);

// 首实例窗口过程调用：从收到的 [data]（dwData 必须等于 magic）解出 UTF-8 路径字节、
// 转回 UTF-8 std::string。dwData 不匹配或为空时返回空串（调用方据此忽略本消息）。
std::string DecodeExternalVideoPath(const COPYDATASTRUCT* data);

}  // namespace hibiki

#endif  // RUNNER_EXTERNAL_VIDEO_HANDOFF_H_
