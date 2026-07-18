#ifndef HIBIKI_VOICE_HOOK_IPC_H_
#define HIBIKI_VOICE_HOOK_IPC_H_

#include <windows.h>

#include <cstdint>
#include <string>

// galgame 一键制卡 C 阶段（docs/specs/galgame-mining）—— 引擎级 voice hook 的**进程间契约**。
//
// 部署红线：这套 injector + hook DLL 是**独立可选 helper 组件**，和 `hibiki.exe` 物理隔离、
// 分离分发（`CreateRemoteThread`/`WriteProcessMemory` 注入必被杀软启发式报毒，编进本体会污
// 染整个 app 的分发口碑）。Hibiki 主进程把 injector 当子进程拉起、通过下面这块共享内存消费
// 干净语音 PCM——被标记的注入代码只待在这个隔离组件里。
//
// 数据流（混音前的干净语音轨）：
//   game.exe 内的 hook DLL：在 XAudio2/DirectSound 把语音送进混音**之前** memcpy 进环形缓冲
//     → 只在音频回调里 memcpy + 更新 write_pos（零阻塞：写盘/编码/IPC 全部移出回调，爆音红线）
//   共享内存：header + 紧随其后的 PCM 环形缓冲
//   Hibiki host（经 injector）：读环形缓冲最近 N 毫秒 → 波形选区 → 制卡出口（复用 A 阶段流水线）
namespace hibiki_voice_hook {

// 共享内存魔数 'HVH1'（小端）与当前契约版本。跨进程读到不匹配即拒绝，防旧/坏映射。
constexpr uint32_t kSharedMagic = 0x31485648;  // 'H''V''H''1'
// v2：在 v1 音频环形之外加「文本环」(hook 抓的台词行) + 「语音 clip 索引」(按句切的语音片段)。
// 全自动制卡：文本 hook 出一句 + voice hook 出对应那条语音 clip → 按时间戳配对 → 点+一键出卡。
constexpr uint32_t kSharedVersion = 3;

// 环形缓冲保留时长（秒）。C 阶段语音轨常见 48k 立体声 float32；60s 上界 ≈ 23MB。
// 32 位游戏地址空间有限，共享内存映射进游戏进程也吃它的地址空间——故设硬上界。
constexpr uint32_t kRingSeconds = 60;
constexpr uint32_t kMaxRingBytes = 64u * 1024u * 1024u;  // ≤64MB（spec C 阶段预算）

// 文本环：最近 kTextSlotCount 条台词行，循环覆盖。每槽固定 kTextSlotBytes 字节
// （TextSlot 头 + 紧跟的文本字节，UTF-16LE 约 500 字符上界，够一句台词）。
constexpr uint32_t kTextSlotCount = 256;
constexpr uint32_t kTextSlotBytes = 1024;
// 语音 clip 索引：最近 kClipCount 条语音片段的位置记录（按 source voice / DirectSound buffer
// 的一次提交切一条；galgame 一句台词≈一条语音）。指向音频环形里的 [ring_offset, byte_len)。
constexpr uint32_t kClipCount = 128;

// 文本槽：seq==全局 text_write_count 对应值时该槽有效；文本紧跟本头之后（kTextSlotBytes-头长）。
#pragma pack(push, 8)
struct TextSlot {
  volatile uint64_t seq;    // 写入序号（0=空；等于所在 text_write_count 快照即有效）
  uint64_t timestamp_ms;    // GetTickCount64() 写入时刻（与语音 clip 配对用）
  uint32_t byte_len;        // 文本有效字节数（<= kTextSlotBytes - sizeof(TextSlot)）
  uint32_t is_utf8;         // 1=UTF-8，0=UTF-16LE
  // 紧跟文本字节。
};

// 语音 clip 记录：一段独立语音片段在音频环形里的位置 + 时刻 + 格式。host 按文本时间戳找最近
// clip，再从音频环形 [ring_offset, ring_offset+byte_len) 取 PCM（若已被环形覆盖则 total_at_write
// 与当前 total_written 差值 > ring_capacity，host 判为过期）。
struct VoiceClip {
  volatile uint64_t seq;      // 写入序号（0=空）
  uint64_t timestamp_ms;      // 该 clip 播放时刻
  uint64_t total_at_write;    // 写该 clip 尾时的 total_written（判是否已被环形覆盖）
  uint32_t ring_offset;       // 在音频环形里的起始偏移
  uint32_t byte_len;          // clip 字节数
  uint32_t sample_rate;
  uint32_t channels;
  uint32_t bits_per_sample;
  uint32_t is_float;
  uint32_t pad;               // 8 对齐
};

// 共享内存头。injector 创建并清零、填各区偏移；hook DLL 注入后填格式、持续更新计数。
// volatile 字段跨进程无锁单写单读。绝不在此放指针（跨进程地址无意义）。
// 内存布局：[SharedHeader][音频环形 ring_capacity][文本环 kTextSlotCount*kTextSlotBytes]
//           [clip 索引 kClipCount*sizeof(VoiceClip)]，各区偏移由 injector 填进 header。
struct SharedHeader {
  uint32_t magic;           // = kSharedMagic
  uint32_t version;         // = kSharedVersion
  uint32_t sample_rate;     // hook 首次拿到语音格式后填
  uint32_t channels;        //
  uint32_t bits_per_sample;  //
  uint32_t is_float;        // 1 = IEEE float，0 = 整型 PCM
  uint32_t ring_capacity;   // 紧随 header 的音频环形字节数（帧对齐，≤kMaxRingBytes）
  uint32_t block_align;     // 每帧字节 = channels * bits/8（hook 填）
  volatile uint32_t write_pos;      // 下一个写入位置（0..ring_capacity）
  volatile uint32_t hooked;         // 1 = hook DLL 已注入并安装钩子（proof-of-life）
  volatile uint32_t calibrating;    // 1 = 校准模式（识别 voice callsite 中）
  volatile uint32_t text_hooked;    // 1 = 文本 hook 已装（v2）
  volatile uint64_t total_written;  // 单调累计写入音频字节（host 判断有多少可读）
  // ── v2 区偏移（injector 填，header 起算的字节偏移）──
  uint32_t text_region_offset;      // 文本环起始
  uint32_t clip_region_offset;      // clip 索引起始
  volatile uint64_t text_write_count;  // 单调：已写文本行数（host 取 last..count 的新行）
  volatile uint64_t clip_write_count;  // 单调：已写语音 clip 数
  // LunaHook（引擎精确）出干净行后 injector 置 1；置 1 后游戏内 GDI 文本 hook 让位不再写文本，
  // 消除「LunaHook 干净行 + GDI 每字重画伪影」双写者污染。音频写入不受此标志影响。GDI 仅在
  // luna_active==0（LunaHook 未覆盖该引擎）时作兜底文本源。
  volatile uint32_t luna_active;
  uint32_t reserved_luna;  // 保持 8 对齐
};
#pragma pack(pop)

static_assert(sizeof(SharedHeader) % 8 == 0, "SharedHeader must stay 8-aligned");
static_assert(sizeof(TextSlot) % 8 == 0, "TextSlot must stay 8-aligned");
static_assert(sizeof(VoiceClip) % 8 == 0, "VoiceClip must stay 8-aligned");

// 命名对象（同会话跨进程）。以目标 PID 区分，支持同时对多个游戏进程各挂一份。
// injector 创建、hook DLL 打开：共享内存 + 「就绪」事件（DLL 装好后 SetEvent，injector 据此
// 确认注入成功并读回格式）。
inline std::wstring SharedMemoryName(DWORD target_pid) {
  return L"Local\\HibikiVoiceHook_" + std::to_wstring(target_pid);
}
inline std::wstring ReadyEventName(DWORD target_pid) {
  return L"Local\\HibikiVoiceHookReady_" + std::to_wstring(target_pid);
}

}  // namespace hibiki_voice_hook

#endif  // HIBIKI_VOICE_HOOK_IPC_H_
