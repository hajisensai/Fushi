#ifndef RUNNER_GAME_STREAM_HOST_MUTE_H_
#define RUNNER_GAME_STREAM_HOST_MUTE_H_

#include <windows.h>

#include <condition_variable>
#include <mutex>
#include <thread>

// 游戏串流「静音主机」（仅 Windows）：串流期间把被串游戏进程树的音频会话压到
// kSilentDuckLevel，主机扬声器不出声；串流音频照常——flutter_webrtc 补丁里的
// application_loopback_capturer.cc 用 DuckedTreeProbe 看到压低值就按倒数放大还原
// （约定见 audio_duck_gain.h）。
//
// 压低在专用 MTA 线程上维持：新会话靠 IAudioSessionNotification 即时压低，另有 250 ms
// 兜底重扫（用户在混音器里把音量拖回来、进程树变化）。Stop 写回压低前的原音量。
// 绝不抛异常；所有方法在平台线程调用。
namespace fushi {

class GameStreamHostMute {
 public:
  GameStreamHostMute() = default;
  ~GameStreamHostMute();
  GameStreamHostMute(const GameStreamHostMute&) = delete;
  GameStreamHostMute& operator=(const GameStreamHostMute&) = delete;

  // 压低 [pid] 进程树的会话，直到 Stop。同一 pid 已在压低则直接返回 true；换了 pid
  // 先还原旧的。初始扫描完成后才返回（Dart 握手返回时扬声器已静音）。没有任何可用
  // 渲染端点（COM 失败）返回 false。
  bool Start(DWORD pid);

  // 还原 Start 压低的会话（写回原音量）。幂等。
  void Stop();

  // 还原 [pid] 进程树里停在压低值上的会话（上次串流时进程被杀留下的残留；Windows 按
  // 可执行文件持久化会话音量）。正在压低的不动。返回还原的会话数。
  int RestoreResidual(DWORD pid);

  DWORD pid() const { return pid_; }

 private:
  void Run(DWORD pid);

  std::thread thread_;
  HANDLE stop_event_ = nullptr;
  DWORD pid_ = 0;

  // Start 握手：工作线程完成首轮压低后置位。
  std::mutex init_mutex_;
  std::condition_variable init_cv_;
  bool init_done_ = false;
  bool init_ok_ = false;
};

}  // namespace fushi

#endif  // RUNNER_GAME_STREAM_HOST_MUTE_H_
