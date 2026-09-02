#ifndef RUNNER_WINDOW_RECORDER_H_
#define RUNNER_WINDOW_RECORDER_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

// galgame 制卡「持续滚动录制游戏窗口画面」（仅 Windows）：对选定窗口开一条**持久**的
// Windows.Graphics.Capture 会话，FrameArrived 回调里按 fps 抽帧 → 裁到客户区 → 等比
// 缩小 → WIC 编码 JPEG → 推进有界环形队列（按 max_seconds 与总字节上限淘汰）。制卡
// 那一刻 Dart 按「台词出现 tick → 现在」把区间内的帧落盘成 frame_%05d.jpg 序列，
// 再由 ffmpeg 编成视频卡片。tick 一律取 GetTickCount64()，与 hook 台词事件同一时钟。
//
// 纯 WRL/ABI 实现（runner 以 _HAS_EXCEPTIONS=0 编译，全程 HRESULT 校验、不抛异常），
// WGC 建立方式与 window_capture.cpp 的单帧截图一致（共用 wgc_interop.h /
// ComputeClientCropBox / CreateD3DDevice）。
namespace fushi {

// 导出的一帧：磁盘路径（UTF-8）+ 到达 tick。
struct WindowRecordingFrame {
  std::string path;
  uint64_t tick_ms = 0;
};

// 导出结果：[frames] 按 tick 升序；[now_tick_ms] 为导出时刻的 GetTickCount64()；
// [error] 非空即失败（"not_recording" / "no_frames" / "bad_directory" /
// "write_failed"），此时 frames 为空。
struct WindowRecordingExport {
  std::vector<WindowRecordingFrame> frames;
  uint64_t now_tick_ms = 0;
  std::string error;
  bool ok() const { return error.empty(); }
};

// 单例：整个进程同时只录一个窗口。所有方法可从 UI 线程调用：
//   - Start 在专用录制线程（MTA）上建立 WGC 会话并同步等待建立结果（毫秒级）；
//   - 帧处理全部在 WGC 线程池回调线程上、且有界（一帧缩放 + JPEG 编码）；
//   - Stop 发停止信号并等录制线程把会话确定性关闭（CloseIfClosable）；
//   - Export 在调用线程同步落盘（几 MB）。
// 目标窗口销毁（item Closed / IsWindow 假）时会话自动停止，IsRecording 变 false。
// 绝不抛异常。
class WindowRecorder {
 public:
  static WindowRecorder& Instance();

  // 开始录制 [hwnd]（Magpie 缩放窗按 ResolveScalingSourceWindow 重定向到源窗口）。
  // 已在录同一窗口时幂等返回 true；录着别的窗口则先停再起。[fps] 夹到 [1,60]，
  // [max_seconds] 夹到 [1,120]，[max_width] 0 = 不缩。失败（系统不支持 WGC / 窗口
  // 不可捕获 / D3D 失败）返回 false，可用 LastError 取原因。
  bool Start(HWND hwnd, int fps, int max_seconds, int max_width);

  // 停止录制并清空环形队列。幂等。
  void Stop();

  // 会话是否仍活着（Start 成功且窗口尚未销毁）。
  bool IsRecording() const;

  // 把 tick 落在 [from_tick, to_tick] 内的帧写进 [directory_utf8]（调用方已建好；
  // 文件名 frame_%05d.jpg，按 tick 升序编号）。[to_tick] <= 0 表示「到现在」。
  WindowRecordingExport Export(int64_t from_tick, int64_t to_tick,
                               const std::string& directory_utf8);

  // 最近一次 Start 失败 / 自动停止的原因（诊断用，UTF-8），成功路径为空。
  std::string LastError() const;

 private:
  WindowRecorder() = default;
  ~WindowRecorder();
  WindowRecorder(const WindowRecorder&) = delete;
  WindowRecorder& operator=(const WindowRecorder&) = delete;
};

}  // namespace fushi

#endif  // RUNNER_WINDOW_RECORDER_H_
