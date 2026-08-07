#ifndef RUNNER_AUDIO_LOOPBACK_CAPTURE_H_
#define RUNNER_AUDIO_LOOPBACK_CAPTURE_H_

#include <windows.h>

#include <cstdint>
#include <vector>

// galgame 一键制卡（docs/specs/galgame-mining）A 阶段（仅 Windows）：WASAPI loopback
// 抓默认渲染端点的系统混音（含 BGM/SE/语音，混音后），写入 native 侧固定容量环形缓冲。
// 热键那一刻 Dart 按「最近 N 毫秒」拉一段裸 PCM 出来做波形选区 + 制卡。
//
// 纯 WASAPI + WRL ComPtr（runner 以 _HAS_EXCEPTIONS=0 编译，全程 HRESULT 校验、不抛异常）。
// 环形缓冲内存有界（容量 = byteRate * kRingSeconds），采集在专用线程，Dart 只按需拉取，
// 不做持续 IPC。
namespace fushi {

// loopback PCM 格式（GetMixFormat 得来，共享模式常见 48k 立体声 float32 或 16-bit）。
// [ok] 仅当采集已成功启动、字段有效时为 true。
struct LoopbackFormat {
  int sample_rate = 0;
  int channels = 0;
  int bits_per_sample = 0;
  bool is_float = false;
  bool ok = false;
};

// 单例：整个进程一路 loopback 采集。所有方法可从 UI 线程调用（内部与采集线程用
// 互斥/条件变量握手，COM 全部在采集线程的 MTA apartment 内完成）。绝不抛异常。
class AudioLoopbackCapture {
 public:
  static AudioLoopbackCapture& Instance();

  // 启动采集（幂等：已在跑则直接返回当前格式）。失败（无渲染端点 / WASAPI 初始化失败）
  // 返回 ok=false 的格式。
  LoopbackFormat Start();

  // 停止采集并释放环形缓冲与 COM 对象。幂等。
  void Stop();

  // 把「最近 [back_ms] 毫秒」的 PCM 拷进 [out]（按时间先后，帧对齐）。缓冲不足则返回现有
  // 全部。未启动 / 无数据时 [out] 清空、返回 ok=false 的格式。
  LoopbackFormat GrabRecent(int back_ms, std::vector<uint8_t>& out);

 private:
  AudioLoopbackCapture() = default;
  ~AudioLoopbackCapture();
  AudioLoopbackCapture(const AudioLoopbackCapture&) = delete;
  AudioLoopbackCapture& operator=(const AudioLoopbackCapture&) = delete;
};

}  // namespace fushi

#endif  // RUNNER_AUDIO_LOOPBACK_CAPTURE_H_
