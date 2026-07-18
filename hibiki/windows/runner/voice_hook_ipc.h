#ifndef RUNNER_VOICE_HOOK_IPC_H_
#define RUNNER_VOICE_HOOK_IPC_H_

#include <windows.h>

#include <cstdint>
#include <string>

// galgame 一键制卡 C 阶段（docs/specs/galgame-mining）—— 引擎级 voice hook 共享内存契约的
// **host 端副本**。真相源是隔离组件 `native/galgame_voice_hook/include/voice_hook_ipc.h`；
// 这里只复制 hibiki.exe **读侧**需要的部分（读共享内存不是注入、不被杀软标记，故可安全进本体）。
// 契约用 magic/version 版本化，两份漂移会在运行时被 magic/version 校验拒绝——不会静默读坏内存。
namespace hibiki_voice_hook {

constexpr uint32_t kSharedMagic = 0x31485648;  // 'H''V''H''1'
constexpr uint32_t kSharedVersion = 1;

#pragma pack(push, 8)
struct SharedHeader {
  uint32_t magic;             // = kSharedMagic
  uint32_t version;           // = kSharedVersion
  uint32_t sample_rate;       // hook 首次拿到语音格式后填
  uint32_t channels;          //
  uint32_t bits_per_sample;   //
  uint32_t is_float;          // 1 = IEEE float，0 = 整型 PCM
  uint32_t ring_capacity;     // 紧随 header 的环形缓冲字节数（帧对齐）
  uint32_t block_align;       // 每帧字节 = channels * bits/8（hook 填）
  volatile uint32_t write_pos;      // 下一个写入位置（0..ring_capacity）
  volatile uint32_t hooked;         // 1 = hook DLL 已注入并安装钩子
  volatile uint32_t calibrating;    // 1 = 校准模式
  volatile uint32_t reserved;       // 对齐填充 / 将来扩展
  volatile uint64_t total_written;  // 单调累计写入字节
};
#pragma pack(pop)

static_assert(sizeof(SharedHeader) % 8 == 0, "SharedHeader must stay 8-aligned");

// 命名对象（同会话跨进程），以目标游戏 PID 区分。injector 创建、hook DLL 打开、host 只读。
inline std::wstring SharedMemoryName(DWORD target_pid) {
  return L"Local\\HibikiVoiceHook_" + std::to_wstring(target_pid);
}
inline std::wstring ReadyEventName(DWORD target_pid) {
  return L"Local\\HibikiVoiceHookReady_" + std::to_wstring(target_pid);
}

}  // namespace hibiki_voice_hook

#endif  // RUNNER_VOICE_HOOK_IPC_H_
