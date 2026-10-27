#ifndef RUNNER_AUDIO_LOOPBACK_CAPTURE_H_
#define RUNNER_AUDIO_LOOPBACK_CAPTURE_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

// galgame 一键制卡（docs/specs/galgame-mining）A 阶段（仅 Windows）：WASAPI loopback
// 抓默认渲染端点的系统混音（含 BGM/SE/语音，混音后），写入 native 侧固定容量环形缓冲。
// 热键那一刻 Dart 按「最近 N 毫秒」拉一段裸 PCM 出来做波形选区 + 制卡。
//
// 网页视频制卡队列（docs/specs/2026-10-27-web-mine-idle-silent-replay.md）另走**进程树**
// 模式：process loopback（AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK）只录内置档 WebView2
// 浏览器进程树的声音，不混入用户别的声音；silent 时再把该进程树的音频会话音量压到
// kSilentDuckLevel（扬声器侧被引擎判为静音），采集侧按倒数放大还原——实测会话音量是
// process loopback 之前的线性浮点增益，压到 1e-6 仍逐位还原（见设计记录）。
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

// 采集来源。默认（全空）= 默认渲染端点的系统混音（galgame 路径，行为不变）。
struct LoopbackOptions {
  // 进程树模式的目标：本进程子进程里 `--user-data-dir` 落在这个 WebView2 user data
  // folder（或其下 EBWebView）的 msedgewebview2.exe 浏览器进程。
  std::wstring user_data_folder;
  // 直接给目标进程 id（测试 / 诊断用）；非 0 时优先于 [user_data_folder]。
  DWORD target_pid = 0;
  // 进程树模式下把目标进程树的音频会话压到 kSilentDuckLevel（不从扬声器出声），
  // 采集侧放大还原。系统混音模式忽略。
  bool silent = false;

  bool process_tree() const {
    return target_pid != 0 || !user_data_folder.empty();
  }
};

// silent 模式的会话音量（-100 dB）：满幅内容也低于 16-bit 一个 LSB，实测引擎把该端点的
// loopback 包整段标 AUDCLNT_BUFFERFLAGS_SILENT；process loopback 侧浮点无损。
constexpr float kSilentDuckLevel = 1e-5f;

// Start 的失败原因（Dart 侧据此决定是降级到系统混音还是放弃自动制卡）。
enum class LoopbackError {
  kNone = 0,
  kStartFailed,       // WASAPI 初始化失败 / 无渲染端点
  kTargetNotFound,    // 进程树模式：找不到目标 WebView2 浏览器进程
  kProcessLoopbackUnsupported,  // 系统不支持 process loopback（Win10 20348 之前）
  kBusy,              // 已有另一种来源的采集在跑
};

// 单例：整个进程一路 loopback 采集。所有方法可从 UI 线程调用（内部与采集线程用
// 互斥/条件变量握手，COM 全部在采集线程的 MTA apartment 内完成）。绝不抛异常。
class AudioLoopbackCapture {
 public:
  static AudioLoopbackCapture& Instance();

  // 启动采集（幂等：同一来源已在跑则直接返回当前格式）。失败返回 ok=false 的格式，
  // [error]（可空）给出原因。
  LoopbackFormat Start(const LoopbackOptions& options = LoopbackOptions{},
                       LoopbackError* error = nullptr);

  // 停止采集并释放环形缓冲与 COM 对象；silent 模式先把压低的会话音量还原。幂等。
  void Stop();

  // 把「最近 [back_ms] 毫秒」的 PCM 拷进 [out]（按时间先后，帧对齐）。缓冲不足则返回现有
  // 全部。未启动 / 无数据时 [out] 清空、返回 ok=false 的格式。
  LoopbackFormat GrabRecent(int back_ms, std::vector<uint8_t>& out);

  // 崩溃兜底：Windows 按可执行文件持久化会话音量，上次 silent 采集没走到 Stop（进程被杀）
  // 时目标进程树的会话会一直停在 kSilentDuckLevel。把该树里音量 ≤ 阈值的会话还原到 1.0。
  // 返回还原的会话数。不需要采集在跑。
  static int RestoreDuckedSessions(const LoopbackOptions& options);

 private:
  AudioLoopbackCapture() = default;
  ~AudioLoopbackCapture();
  AudioLoopbackCapture(const AudioLoopbackCapture&) = delete;
  AudioLoopbackCapture& operator=(const AudioLoopbackCapture&) = delete;
};

}  // namespace fushi

#endif  // RUNNER_AUDIO_LOOPBACK_CAPTURE_H_
