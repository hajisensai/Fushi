#ifndef FUSHI_THREAD_PREVIEW_IPC_H_
#define FUSHI_THREAD_PREVIEW_IPC_H_

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook {

constexpr uint32_t kThreadPreviewCount = 64;
constexpr uint32_t kThreadPreviewTextChars = 192;
constexpr uint32_t kThreadPreviewFlagArtifact = 0x00000001u;
constexpr uint32_t kThreadPreviewSnapshotRetries = 4;
// LunaHost lives in the injector process while native adapters run inside the
// game process. They must never claim/write the same preview slot because a
// process-local CRITICAL_SECTION cannot serialize the other process.
constexpr uint32_t kLunaThreadPreviewCount = 48;
constexpr uint32_t kNativeThreadPreviewStart = kLunaThreadPreviewCount;
constexpr uint32_t kNativeThreadPreviewCount =
    kThreadPreviewCount - kNativeThreadPreviewStart;
static_assert(kNativeThreadPreviewCount > 0,
              "native text producers need reserved preview slots");

#pragma pack(push, 8)
// v12 线程预览槽。writer 必须先由进程内锁串行化，再执行：
//   seq=odd（写中）→ 写全部 payload → seq=even（已提交）→ 发布全局 generation。
// reader 对 seq 原子双读，仅接受相同的非零偶数值。Windows Interlocked 操作是全栅栏；
// 槽和 seq 均保持 8 字节对齐，因此 x86 上的 64 位 seq 也不会撕裂。
struct ThreadPreviewSlot {
  volatile uint64_t seq;
  uint64_t thread_id;       // 0=空槽；回收后允许预览表出现空洞
  uint64_t timestamp_ms;
  uint64_t line_count;
  uint64_t artifact_count;
  uint32_t byte_len;
  uint32_t event_flags;
  wchar_t text[kThreadPreviewTextChars];
};
#pragma pack(pop)

struct ThreadPreviewSnapshot {
  uint64_t seq = 0;
  uint64_t thread_id = 0;
  uint64_t timestamp_ms = 0;
  uint64_t line_count = 0;
  uint64_t artifact_count = 0;
  uint32_t byte_len = 0;
  uint32_t event_flags = 0;
  wchar_t text[kThreadPreviewTextChars] = {};
};

static_assert(offsetof(ThreadPreviewSlot, seq) == 0,
              "ThreadPreviewSlot seq must be the first field");
static_assert(alignof(ThreadPreviewSlot) >= alignof(uint64_t),
              "ThreadPreviewSlot must keep 64-bit atomic alignment");
static_assert(sizeof(ThreadPreviewSlot) % 8 == 0,
              "ThreadPreviewSlot must stay 8-aligned");

inline uint64_t AtomicLoadPreview64(const volatile uint64_t* value) {
  return static_cast<uint64_t>(InterlockedCompareExchange64(
      reinterpret_cast<volatile LONGLONG*>(
          const_cast<volatile uint64_t*>(value)),
      0, 0));
}

inline void AtomicStorePreview64(volatile uint64_t* value, uint64_t next) {
  InterlockedExchange64(reinterpret_cast<volatile LONGLONG*>(value),
                        static_cast<LONGLONG>(next));
}

inline uint64_t NextThreadPreviewGeneration(
    volatile uint64_t* process_local_generation) {
  return static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(process_local_generation)));
}

inline uint64_t ThreadPreviewWritingSequence(uint64_t generation) {
  return (generation << 1) | 1u;
}

inline uint64_t ThreadPreviewCommittedSequence(uint64_t generation) {
  return generation << 1;
}

inline void BeginThreadPreviewWrite(ThreadPreviewSlot* slot,
                                    uint64_t generation) {
  AtomicStorePreview64(&slot->seq,
                       ThreadPreviewWritingSequence(generation));
}

inline void PublishThreadPreviewWrite(ThreadPreviewSlot* slot,
                                      uint64_t generation) {
  AtomicStorePreview64(&slot->seq,
                       ThreadPreviewCommittedSequence(generation));
}

inline void PublishThreadPreviewChange(volatile uint64_t* write_count) {
  InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(write_count));
}

// 调用方持有 writer 锁。回收会产生空洞，因此必须继续扫描以优先找回已有 id。
inline ThreadPreviewSlot* FindThreadPreviewSlot(ThreadPreviewSlot* slots,
                                                uint32_t count,
                                                uint64_t thread_id) {
  ThreadPreviewSlot* first_empty = nullptr;
  for (uint32_t i = 0; i < count; ++i) {
    if (slots[i].thread_id == thread_id) return &slots[i];
    if (slots[i].thread_id == 0 && first_empty == nullptr) {
      first_empty = &slots[i];
    }
  }
  return first_empty;
}

inline void ClearThreadPreviewPayload(ThreadPreviewSlot* slot) {
  slot->thread_id = 0;
  slot->timestamp_ms = 0;
  slot->line_count = 0;
  slot->artifact_count = 0;
  slot->byte_len = 0;
  slot->event_flags = 0;
  std::memset(slot->text, 0, sizeof(slot->text));
}

inline void CopyThreadPreviewSnapshot(const ThreadPreviewSlot& slot,
                                      uint64_t sequence,
                                      ThreadPreviewSnapshot* snapshot) {
  snapshot->seq = sequence;
  snapshot->thread_id = slot.thread_id;
  snapshot->timestamp_ms = slot.timestamp_ms;
  snapshot->line_count = slot.line_count;
  snapshot->artifact_count = slot.artifact_count;
  snapshot->byte_len = slot.byte_len;
  snapshot->event_flags = slot.event_flags;
  std::memcpy(snapshot->text, slot.text, sizeof(snapshot->text));
}

inline bool ThreadPreviewSequenceIsStable(const ThreadPreviewSlot& slot,
                                          uint64_t begin_sequence) {
  const uint64_t end_sequence = AtomicLoadPreview64(&slot.seq);
  return begin_sequence != 0 && (begin_sequence & 1u) == 0 &&
         begin_sequence == end_sequence;
}

inline bool TryReadThreadPreviewSnapshot(const ThreadPreviewSlot& slot,
                                         ThreadPreviewSnapshot* snapshot) {
  if (snapshot == nullptr) return false;
  for (uint32_t attempt = 0; attempt < kThreadPreviewSnapshotRetries;
       ++attempt) {
    const uint64_t begin_sequence = AtomicLoadPreview64(&slot.seq);
    if (begin_sequence == 0 || (begin_sequence & 1u) != 0) {
      YieldProcessor();
      continue;
    }
    ThreadPreviewSnapshot candidate;
    CopyThreadPreviewSnapshot(slot, begin_sequence, &candidate);
    if (ThreadPreviewSequenceIsStable(slot, begin_sequence)) {
      *snapshot = candidate;
      return true;
    }
    YieldProcessor();
  }
  return false;
}

}  // namespace fushi_voice_hook

#endif  // FUSHI_THREAD_PREVIEW_IPC_H_
