#ifndef RUNNER_VOICE_HOOK_IPC_H_
#define RUNNER_VOICE_HOOK_IPC_H_

#include <windows.h>

#include <cstdint>
#include <string>

// galgame 一键制卡 C 阶段（docs/specs/galgame-mining）—— 引擎级 voice/text hook 共享内存契约的
// **host 端副本**（真相源 `native/galgame_voice_hook/include/voice_hook_ipc.h`，须同步）。
// v2：音频环形 + 文本环（hook 抓的台词行）+ 语音 clip 索引（按句切的语音片段，含时间戳供配对）。
// 读共享内存不是注入、不被杀软标记，可安全进 hibiki.exe。契约用 magic/version 版本化。
namespace hibiki_voice_hook {

constexpr uint32_t kSharedMagic = 0x31485648;  // 'H''V''H''1'
constexpr uint32_t kSharedVersion = 2;

constexpr uint32_t kTextSlotCount = 256;
constexpr uint32_t kTextSlotBytes = 1024;
constexpr uint32_t kClipCount = 128;

#pragma pack(push, 8)
struct TextSlot {
  volatile uint64_t seq;    // 写入序号（0=空；等于所在 text_write_count 快照即有效）
  uint64_t timestamp_ms;    // GetTickCount64() 写入时刻（与语音 clip 配对用）
  uint32_t byte_len;        // 文本有效字节数
  uint32_t is_utf8;         // 1=UTF-8，0=UTF-16LE
  // 紧跟文本字节。
};

struct VoiceClip {
  volatile uint64_t seq;
  uint64_t timestamp_ms;    // 该 clip 播放时刻
  uint64_t total_at_write;  // 写该 clip 尾时的 total_written（判是否已被环形覆盖）
  uint32_t ring_offset;
  uint32_t byte_len;
  uint32_t sample_rate;
  uint32_t channels;
  uint32_t bits_per_sample;
  uint32_t is_float;
  uint32_t pad;
};

struct SharedHeader {
  uint32_t magic;
  uint32_t version;
  uint32_t sample_rate;
  uint32_t channels;
  uint32_t bits_per_sample;
  uint32_t is_float;
  uint32_t ring_capacity;
  uint32_t block_align;
  volatile uint32_t write_pos;
  volatile uint32_t hooked;
  volatile uint32_t calibrating;
  volatile uint32_t text_hooked;
  volatile uint64_t total_written;
  uint32_t text_region_offset;
  uint32_t clip_region_offset;
  volatile uint64_t text_write_count;
  volatile uint64_t clip_write_count;
};
#pragma pack(pop)

static_assert(sizeof(SharedHeader) % 8 == 0, "SharedHeader must stay 8-aligned");
static_assert(sizeof(TextSlot) % 8 == 0, "TextSlot must stay 8-aligned");
static_assert(sizeof(VoiceClip) % 8 == 0, "VoiceClip must stay 8-aligned");

inline std::wstring SharedMemoryName(DWORD target_pid) {
  return L"Local\\HibikiVoiceHook_" + std::to_wstring(target_pid);
}
inline std::wstring ReadyEventName(DWORD target_pid) {
  return L"Local\\HibikiVoiceHookReady_" + std::to_wstring(target_pid);
}

}  // namespace hibiki_voice_hook

#endif  // RUNNER_VOICE_HOOK_IPC_H_
