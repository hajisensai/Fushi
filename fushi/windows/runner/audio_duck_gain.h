#ifndef RUNNER_AUDIO_DUCK_GAIN_H_
#define RUNNER_AUDIO_DUCK_GAIN_H_

#include <cstddef>

// 「只静音扬声器、录音照常」的共同约定（纯计算，无 Windows 依赖，可单测）。
//
// Windows 会话音量（ISimpleAudioVolume）是 process loopback **之前**的线性浮点增益：把目标
// 进程树的会话压到 kSilentDuckLevel，扬声器侧被引擎判为静音，而 process loopback 拿到的
// 浮点样本按倒数放大即可逐位还原（网页视频制卡 silent 模式实测，见
// docs/specs/2026-10-27-web-mine-idle-silent-replay.md）。两条路径共用：
// - 网页视频制卡队列（audio_loopback_capture.cpp，runner 内压低 + 采集还原）；
// - 游戏串流「静音主机」（game_stream_host_mute.cpp 压低，flutter_webrtc 补丁里的
//   application_loopback_capturer.cc 见到压低值就还原）。
namespace fushi {

// 压低后的会话音量（-100 dB）：满幅内容也低于 16-bit 一个 LSB，端点 loopback 整段标
// AUDCLNT_BUFFERFLAGS_SILENT；process loopback 侧浮点无损。
constexpr float kSilentDuckLevel = 1e-5f;

// 音量不高于它的会话视为「被我们压低过」：没人会手动把音量调到 -80 dB（混音器滑块最小
// 非零档是 1%）。
constexpr float kDuckedThreshold = kSilentDuckLevel * 10.0f;

// [level] 是否是压低值（含崩溃残留）。0 不算：那是用户在混音器里拉到底的本意，既不
// 「还原」成 1.0，也不当作压低状态。
constexpr bool IsDuckedVolume(float level) {
  return level > 0.0f && level <= kDuckedThreshold;
}

// 把压低的浮点样本放大回原电平。仍高于压低后可能出现的幅度的样本说明那一刻会话还没
// 压下去（压低 / 还原生效与采集侧察觉之间的毫秒级空窗），放大会削顶成噪声，按静音写。
inline void RestoreDuckedGain(float* samples, size_t count) {
  constexpr float kGain = 1.0f / kSilentDuckLevel;
  constexpr float kMaxDucked = kSilentDuckLevel * 1.5f;
  for (size_t i = 0; i < count; ++i) {
    const float s = samples[i];
    samples[i] = (s > kMaxDucked || s < -kMaxDucked) ? 0.0f : s * kGain;
  }
}

}  // namespace fushi

#endif  // RUNNER_AUDIO_DUCK_GAIN_H_
