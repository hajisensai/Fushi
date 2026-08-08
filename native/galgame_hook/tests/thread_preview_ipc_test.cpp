#include <array>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#include "thread_preview_ipc.h"

namespace {

using fushi_voice_hook::ThreadPreviewSlot;
using fushi_voice_hook::ThreadPreviewSnapshot;

struct PreviewTable {
  volatile uint64_t write_count = 0;
  volatile uint64_t generation = 0;
  std::array<ThreadPreviewSlot, fushi_voice_hook::kThreadPreviewCount> slots{};
  std::mutex writer_mutex;
};

void WritePattern(PreviewTable* table, uint64_t thread_id) {
  std::lock_guard<std::mutex> lock(table->writer_mutex);
  ThreadPreviewSlot* slot = fushi_voice_hook::FindThreadPreviewSlot(
      table->slots.data(), static_cast<uint32_t>(table->slots.size()),
      thread_id);
  if (slot == nullptr) return;
  const uint64_t generation =
      fushi_voice_hook::NextThreadPreviewGeneration(&table->generation);
  fushi_voice_hook::BeginThreadPreviewWrite(slot, generation);
  slot->thread_id = thread_id;
  slot->timestamp_ms = generation * 3;
  slot->line_count = generation;
  slot->artifact_count = generation ^ 0x55aa55aaull;
  slot->byte_len = 128 * sizeof(wchar_t);
  slot->event_flags = static_cast<uint32_t>(generation & 1u);
  const wchar_t pattern = static_cast<wchar_t>(L'A' + (generation % 23));
  for (uint32_t i = 0; i < 128; ++i) slot->text[i] = pattern;
  fushi_voice_hook::PublishThreadPreviewWrite(slot, generation);
  fushi_voice_hook::PublishThreadPreviewChange(&table->write_count);
}

void RemovePreview(PreviewTable* table, uint64_t thread_id) {
  std::lock_guard<std::mutex> lock(table->writer_mutex);
  for (ThreadPreviewSlot& slot : table->slots) {
    if (slot.thread_id != thread_id) continue;
    const uint64_t generation =
        fushi_voice_hook::NextThreadPreviewGeneration(&table->generation);
    fushi_voice_hook::BeginThreadPreviewWrite(&slot, generation);
    fushi_voice_hook::ClearThreadPreviewPayload(&slot);
    fushi_voice_hook::PublishThreadPreviewWrite(&slot, generation);
    fushi_voice_hook::PublishThreadPreviewChange(&table->write_count);
    return;
  }
}

bool SnapshotMatchesOneGeneration(const ThreadPreviewSnapshot& snapshot) {
  if (snapshot.thread_id == 0) return true;
  if ((snapshot.seq & 1u) != 0) return false;
  const uint64_t generation = snapshot.seq >> 1;
  if (snapshot.timestamp_ms != generation * 3 ||
      snapshot.line_count != generation ||
      snapshot.artifact_count != (generation ^ 0x55aa55aaull) ||
      snapshot.byte_len != 128 * sizeof(wchar_t) ||
      snapshot.event_flags != static_cast<uint32_t>(generation & 1u)) {
    return false;
  }
  const wchar_t pattern = static_cast<wchar_t>(L'A' + (generation % 23));
  for (uint32_t i = 0; i < 128; ++i) {
    if (snapshot.text[i] != pattern) return false;
  }
  return true;
}

}  // namespace

int main() {
  if (fushi_voice_hook::kLunaThreadPreviewCount +
          fushi_voice_hook::kNativeThreadPreviewCount !=
      fushi_voice_hook::kThreadPreviewCount) {
    return 10;
  }
  PreviewTable partitioned;
  ThreadPreviewSlot* luna_slot = fushi_voice_hook::FindThreadPreviewSlot(
      partitioned.slots.data(), fushi_voice_hook::kLunaThreadPreviewCount, 1);
  ThreadPreviewSlot* native_slot = fushi_voice_hook::FindThreadPreviewSlot(
      partitioned.slots.data() + fushi_voice_hook::kNativeThreadPreviewStart,
      fushi_voice_hook::kNativeThreadPreviewCount, 2);
  if (luna_slot != &partitioned.slots.front() ||
      native_slot !=
          &partitioned.slots[fushi_voice_hook::kNativeThreadPreviewStart]) {
    return 11;
  }

  PreviewTable table;

  // 回收后允许空洞：已有 id 必须优先命中，新的第 65 条线程必须复用被释放的槽。
  for (uint64_t id = 1; id <= fushi_voice_hook::kThreadPreviewCount; ++id) {
    WritePattern(&table, id);
  }
  if (fushi_voice_hook::FindThreadPreviewSlot(
          table.slots.data(), static_cast<uint32_t>(table.slots.size()),
          1000) != nullptr) {
    return 1;
  }
  ThreadPreviewSlot* released = &table.slots[16];
  RemovePreview(&table, 17);
  if (fushi_voice_hook::FindThreadPreviewSlot(
          table.slots.data(), static_cast<uint32_t>(table.slots.size()),
          1000) != released) {
    return 2;
  }
  WritePattern(&table, 1000);
  ThreadPreviewSnapshot reused;
  if (!fushi_voice_hook::TryReadThreadPreviewSnapshot(*released, &reused) ||
      reused.thread_id != 1000 || !SnapshotMatchesOneGeneration(reused)) {
    return 3;
  }

  // reader 若拿着旧 begin，期间发生覆盖，末读必须拒绝旧 seq，不能把新 payload 当旧快照。
  const uint64_t old_sequence =
      fushi_voice_hook::AtomicLoadPreview64(&released->seq);
  WritePattern(&table, 1000);
  ThreadPreviewSnapshot mixed_candidate;
  fushi_voice_hook::CopyThreadPreviewSnapshot(
      *released, old_sequence, &mixed_candidate);
  if (fushi_voice_hook::ThreadPreviewSequenceIsStable(*released,
                                                       old_sequence)) {
    return 4;
  }

  // 多 writer + remove/reuse + lock-free reader 压测。生产 writer 同样由一把锁串行，
  // reader 只靠跨进程可用的 odd/even seq 验证快照。
  PreviewTable stress;
  std::atomic<int> writers_done{0};
  std::atomic<bool> failed{false};
  std::vector<std::thread> writers;
  for (uint64_t thread_id = 1; thread_id <= 4; ++thread_id) {
    writers.emplace_back([&stress, &writers_done, thread_id]() {
      for (int i = 0; i < 200000; ++i) WritePattern(&stress, thread_id);
      writers_done.fetch_add(1, std::memory_order_release);
    });
  }
  std::thread recycler([&stress, &writers_done]() {
    while (writers_done.load(std::memory_order_acquire) != 4) {
      RemovePreview(&stress, 3);
      WritePattern(&stress, 3);
    }
  });
  std::thread reader([&stress, &writers_done, &failed]() {
    do {
      for (const ThreadPreviewSlot& slot : stress.slots) {
        ThreadPreviewSnapshot snapshot;
        if (fushi_voice_hook::TryReadThreadPreviewSnapshot(slot, &snapshot) &&
            !SnapshotMatchesOneGeneration(snapshot)) {
          failed.store(true, std::memory_order_release);
          return;
        }
      }
    } while (writers_done.load(std::memory_order_acquire) != 4);
  });

  for (std::thread& writer : writers) writer.join();
  recycler.join();
  reader.join();
  return failed.load(std::memory_order_acquire) ? 5 : 0;
}
