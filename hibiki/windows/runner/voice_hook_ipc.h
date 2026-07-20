#ifndef RUNNER_VOICE_HOOK_IPC_H_
#define RUNNER_VOICE_HOOK_IPC_H_

#include <windows.h>

#include <cstdint>
#include <string>

// galgame 一键制卡 C 阶段（docs/specs/galgame-mining）—— 引擎级 voice/text hook 共享内存契约的
// **host 端副本**（真相源 `native/galgame_voice_hook/include/voice_hook_ipc.h`，须同步）。
// v2：音频环形 + 文本环（hook 抓的台词行）+ 语音 clip 索引（按句切的语音片段，含时间戳供配对）。
// v6：clip 索引之后追加 loopback 混音环 + 时间戳↔环位置标记表（无引擎专属纯人声 hook 时的兜底）。
// 读共享内存不是注入、不被杀软标记，可安全进 hibiki.exe。契约用 magic/version 版本化。
namespace hibiki_voice_hook {

constexpr uint32_t kSharedMagic = 0x31485648;  // 'H''V''H''1'
constexpr uint32_t kSharedVersion = 10;

constexpr uint32_t kTextSlotCount = 256;
constexpr uint32_t kTextSlotBytes = 2048;
constexpr uint32_t kTextHookNameChars = 64;
constexpr uint32_t kTextHookCodeChars = 128;
constexpr uint32_t kTextSourceUnknown = 0;
constexpr uint32_t kTextSourceGdi = 1;
constexpr uint32_t kTextSourceLuna = 2;
constexpr uint32_t kTextEventLine = 0;
constexpr uint32_t kTextEventThreadDiscovered = 1;
constexpr uint32_t kTextSourceUnityTmp = 3;
constexpr uint32_t kTextSourceSiglus = 4;
constexpr uint32_t kClipCount = 1024;
constexpr uint32_t kDiagStartupAudioHooksReady = 0x00000001u;
constexpr uint32_t kDiagUnityIl2CppHooksReady = 0x00000002u;
constexpr uint32_t kDiagUnityIl2CppClipCaptured = 0x00000004u;
constexpr uint32_t kDiagUnityIl2CppPlaybackObserved = 0x00000008u;
constexpr uint32_t kDiagUnityIl2CppGetDataRejected = 0x00000010u;
constexpr uint32_t kDiagUnityResourceExtractorReady = 0x00000020u;
constexpr uint32_t kDiagUnityResourceExtracted = 0x00000040u;
constexpr uint32_t kDiagUnityResourceExtractFailed = 0x00000080u;
constexpr uint32_t kDiagUnityTmpTextHooksReady = 0x00000100u;
constexpr uint32_t kDiagUnityNaninovelTextHookReady = 0x00000200u;
constexpr uint32_t kDiagLunaHostReady = 0x00000400u;
constexpr uint32_t kDiagLunaConnected = 0x00000800u;
constexpr uint32_t kDiagLunaOutputObserved = 0x00001000u;
constexpr uint32_t kDiagLunaInjectFailed = 0x00002000u;
constexpr uint32_t kDiagSiglusExactTextHookReady = 0x00004000u;
constexpr uint32_t kDiagSiglusExactTextObserved = 0x00008000u;
constexpr uint32_t kDiagKirikiriVoiceStreamHookReady = 0x00020000u;
constexpr uint32_t kDiagKirikiriVoiceStreamDumped = 0x00080000u;
constexpr uint32_t kDiagSiglusOvkHooksReady = 0x10000000u;

inline constexpr bool HasReadyGameResourceAudio(uint32_t reserved_luna,
                                                uint32_t hook_diagnostics) {
  const uint32_t unity_required = kDiagUnityIl2CppHooksReady |
                                  kDiagUnityResourceExtractorReady;
  const bool unity_ready =
      (hook_diagnostics & unity_required) == unity_required;
  return (reserved_luna & kDiagKirikiriVoiceStreamHookReady) != 0 ||
         (reserved_luna & kDiagSiglusOvkHooksReady) != 0 || unity_ready;
}
constexpr uint32_t kUnityVoiceEventCount = 16;
constexpr uint32_t kUnityClipNameChars = 128;
constexpr uint32_t kUnityBundlePathChars = 520;
constexpr uint32_t kLoopbackSeconds = 60;
constexpr uint32_t kMaxLoopbackBytes = 16u * 1024u * 1024u;
constexpr uint32_t kLoopbackMarkerCount = 512;

#pragma pack(push, 8)
struct TextSlot {
  volatile uint64_t seq;    // 写入序号（0=空；等于所在 text_write_count 快照即有效）
  uint64_t timestamp_ms;    // GetTickCount64() 写入时刻（与语音 clip 配对用）
  uint32_t byte_len;        // 文本有效字节数
  uint32_t is_utf8;         // 1=UTF-8，0=UTF-16LE
  uint64_t thread_id;       // 会话内稳定 Hook 线程 id（0=不可区分）
  uint64_t thread_address;
  uint64_t thread_context;
  uint64_t thread_context2;
  uint32_t process_id;
  uint32_t source_kind;
  uint32_t hook_name_len;
  uint32_t hook_code_len;
  uint32_t event_kind;
  uint32_t event_flags;
  char hook_name[kTextHookNameChars];
  wchar_t hook_code[kTextHookCodeChars];
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
  uint64_t source_ptr;  // source voice / DS buffer 指针：区分语音源 vs BGM 源，合成整句语音用
};

struct UnityVoiceEvent {
  volatile uint64_t seq;
  uint64_t timestamp_ms;
  wchar_t clip_name[kUnityClipNameChars];
  wchar_t bundle_path[kUnityBundlePathChars];
};

// loopback 时间戳↔环位置标记（真相源 native 头，须同步）。单写者，seq 作半写完成标记。
struct LoopbackMarker {
  volatile uint64_t seq;    // 写入序号（0=空；== loopback_marker_count 快照即有效），**最后**写
  uint64_t tick_ms;         // GetTickCount64() 记录时刻
  uint64_t total_written;   // 该时刻的 loopback_total_written（单调）
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
  volatile uint64_t selected_text_thread_id;  // 0=自动；非0=用户选择的 TextSlot::thread_id
  volatile uint32_t luna_active;  // LunaHook 出干净行后 =1，游戏内 GDI 文本 hook 让位（见 native 头注释）
  uint32_t reserved_luna;         // 32 位引擎诊断位（已满，loopback 另立字段）
  volatile uint32_t hook_diagnostics;
  uint32_t reserved_hook_diagnostics;
  volatile uint64_t unity_voice_write_count;
  UnityVoiceEvent unity_voice_events[kUnityVoiceEventCount];
  // ── v6 loopback 区（injector 填偏移/容量，hook 侧 loopback 线程填格式/计数）──
  uint32_t loopback_ring_offset;
  uint32_t loopback_ring_capacity;
  uint32_t loopback_marker_offset;
  uint32_t loopback_marker_slot_count;
  uint32_t loopback_sample_rate;
  uint32_t loopback_channels;
  uint32_t loopback_bits_per_sample;
  uint32_t loopback_block_align;
  volatile uint32_t loopback_write_pos;
  uint32_t loopback_diag;
  volatile uint64_t loopback_total_written;
  volatile uint64_t loopback_marker_count;
};
#pragma pack(pop)

static_assert(sizeof(SharedHeader) % 8 == 0, "SharedHeader must stay 8-aligned");
static_assert(sizeof(TextSlot) % 8 == 0, "TextSlot must stay 8-aligned");
static_assert(sizeof(VoiceClip) % 8 == 0, "VoiceClip must stay 8-aligned");
static_assert(sizeof(UnityVoiceEvent) % 8 == 0,
              "UnityVoiceEvent must stay 8-aligned");
static_assert(sizeof(LoopbackMarker) % 8 == 0, "LoopbackMarker must stay 8-aligned");

inline std::wstring SharedMemoryName(DWORD target_pid) {
  return L"Local\\HibikiVoiceHook_" + std::to_wstring(target_pid);
}
inline std::wstring ReadyEventName(DWORD target_pid) {
  return L"Local\\HibikiVoiceHookReady_" + std::to_wstring(target_pid);
}

}  // namespace hibiki_voice_hook

#endif  // RUNNER_VOICE_HOOK_IPC_H_
