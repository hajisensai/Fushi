#ifndef RUNNER_VOICE_HOOK_READER_H_
#define RUNNER_VOICE_HOOK_READER_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

// galgame 一键制卡 C 阶段（docs/specs/galgame-mining）—— hibiki.exe **读侧** native。
//
// 隔离红线：注入进游戏、装 XAudio2/DirectSound hook 的代码全在独立组件
// `native/galgame_voice_hook/`（injector + hook DLL），会被杀软报毒，**绝不进 hibiki.exe**。
// 本 reader 只做一件被杀软视为无害的事：按名 [OpenFileMappingW] 打开那个组件建好的**共享内存**，
// 读环形缓冲里 hook 抓到的干净语音 PCM。它是 A 阶段 [AudioLoopbackCapture] 的引擎-hook 版对偶：
// 同样「开一路 → 需要时取最近 N 毫秒」，只是数据源从本进程 WASAPI 换成跨进程共享内存。
//
// 单读者、无锁：hook DLL 是唯一写者（单写 write_pos/total_written），host 只读，读到的量至多
// 滞后一个音频包，对「抓最近一句语音」无害（契约见 voice_hook_ipc.h）。
namespace hibiki {

// 从共享内存 header 读出的语音格式 + 状态。[ok] 仅当映射有效、契约匹配、hook 已填格式时为 true。
struct VoiceHookStatus {
  int sample_rate = 0;
  int channels = 0;
  int bits_per_sample = 0;
  bool is_float = false;
  bool hooked = false;       // hook DLL 是否已注入并安装钩子（proof-of-life）
  bool calibrating = false;  // 是否处于校准模式（识别 voice callsite 中）
  bool text_hooked = false;  // 文本 hook 是否已装（v2）
  bool ok = false;           // 映射有效且格式已就绪（音频格式已填）
};

// 一条 hook 抓到的台词行（v2 文本环）。
struct VoiceHookText {
  uint64_t seq = 0;           // 单调序号
  uint64_t timestamp_ms = 0;  // hook 写入时刻（GetTickCount64）
  std::string utf8;           // UTF-8 文本
};

// 单例：整个进程一路引擎-hook 读取。所有方法可从 UI 线程调用，绝不抛异常（全 HRESULT/句柄校验）。
class VoiceHookReader {
 public:
  static VoiceHookReader& Instance();

  // 按目标游戏 [pid] 打开 injector 建好的共享内存并校验契约（幂等：已打开同 pid 直接返回状态）。
  // 打开成功但 hook 尚未填格式时 ok=false、hooked 可能仍为 false（调用方轮询等 hooked/ok）。
  // 共享内存不存在（injector 未拉起 / pid 不符）返回 ok=false 全零状态。
  VoiceHookStatus Open(uint32_t pid);

  // 读当前 header 状态（格式/hooked/calibrating）。未打开返回 ok=false。
  VoiceHookStatus Status();

  // 把「最近 [back_ms] 毫秒」的语音 PCM 拷进 [out]（帧对齐，环形回绕处理）。缓冲不足则返回现有
  // 全部。未打开 / hook 未就绪 / 无数据时 [out] 清空、返回 ok=false。
  VoiceHookStatus GrabRecent(int back_ms, std::vector<uint8_t>& out);

  // 当前文本行总数（text_write_count）；未打开返回 0。Dart 侧记住 last，取 (last, count] 的新行。
  uint64_t TextWriteCount();

  // 取序号在 (from_seq, text_write_count] 区间的文本行（供 Dart 喂 texthooker）。最多回最近
  // kTextSlotCount 条（更旧的已被覆盖）。未打开 / 无新行时 [out] 空。
  void PollText(uint64_t from_seq, std::vector<VoiceHookText>& out);

  // **按句取语音**：找时间戳与 [ts_ms] 最近（且差 <= [tolerance_ms]）的语音 clip，把它那段 PCM
  // 从音频环形拷进 [out]（clip 已被环形覆盖则跳过）。找不到则 [out] 空、返回 ok=false。
  // 这是「该句的语音」自动选取——替代手动波形选区。
  VoiceHookStatus GrabClipNear(uint64_t ts_ms, uint64_t tolerance_ms,
                               std::vector<uint8_t>& out);

  // 解除映射、释放句柄。幂等。不杀 injector 子进程（那由 Dart 侧管理）。
  void Close();

 private:
  VoiceHookReader() = default;
  ~VoiceHookReader();
  VoiceHookReader(const VoiceHookReader&) = delete;
  VoiceHookReader& operator=(const VoiceHookReader&) = delete;
};

}  // namespace hibiki

#endif  // RUNNER_VOICE_HOOK_READER_H_
