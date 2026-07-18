#include "voice_hook_reader.h"

#include <windows.h>

#include <algorithm>
#include <mutex>
#include <string>

#include "voice_hook_ipc.h"

// galgame 一键制卡 C 阶段 —— 引擎-hook 共享内存读侧实现。见 voice_hook_reader.h。
// 纯 Win32 文件映射，无 COM、无异常（runner 以 _HAS_EXCEPTIONS=0 编译，全程句柄/契约校验）。
namespace hibiki {

namespace {

using hibiki_voice_hook::kSharedMagic;
using hibiki_voice_hook::kSharedVersion;
using hibiki_voice_hook::SharedHeader;
using hibiki_voice_hook::SharedMemoryName;

struct ReaderState {
  std::mutex mutex;
  HANDLE mapping = nullptr;
  SharedHeader* header = nullptr;
  uint32_t pid = 0;
};

ReaderState& State() {
  static ReaderState state;
  return state;
}

// 从 header 填状态（不读环形缓冲）。契约不匹配返回 ok=false。调用方持锁。
VoiceHookStatus StatusFromHeaderLocked(const SharedHeader* h) {
  VoiceHookStatus s;
  if (h == nullptr || h->magic != kSharedMagic || h->version != kSharedVersion) {
    return s;  // 全零、ok=false
  }
  s.hooked = h->hooked != 0;
  s.calibrating = h->calibrating != 0;
  s.text_hooked = h->text_hooked != 0;
  s.sample_rate = static_cast<int>(h->sample_rate);
  s.channels = static_cast<int>(h->channels);
  s.bits_per_sample = static_cast<int>(h->bits_per_sample);
  s.is_float = h->is_float != 0;
  // 格式就绪（hook 已填有效格式）才算 ok；hooked 但格式全 0（还没收到语音）时 ok=false。
  s.ok = s.hooked && s.sample_rate > 0 && s.channels > 0 && s.bits_per_sample > 0;
  return s;
}

// 解除映射、清句柄。调用方持锁。
void CloseLocked(ReaderState& st) {
  if (st.header != nullptr) {
    UnmapViewOfFile(st.header);
    st.header = nullptr;
  }
  if (st.mapping != nullptr) {
    CloseHandle(st.mapping);
    st.mapping = nullptr;
  }
  st.pid = 0;
}

}  // namespace

VoiceHookReader& VoiceHookReader::Instance() {
  static VoiceHookReader instance;
  return instance;
}

VoiceHookReader::~VoiceHookReader() {
  Close();
}

VoiceHookStatus VoiceHookReader::Open(uint32_t pid) {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  if (pid == 0) {
    return VoiceHookStatus{};
  }
  // 幂等：已打开同 pid 直接回报当前状态。
  if (st.header != nullptr && st.pid == pid) {
    return StatusFromHeaderLocked(st.header);
  }
  // 打开了别的 pid：先释放。
  if (st.header != nullptr) {
    CloseLocked(st);
  }
  const std::wstring name = SharedMemoryName(static_cast<DWORD>(pid));
  HANDLE mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, name.c_str());
  if (mapping == nullptr) {
    return VoiceHookStatus{};  // injector 未拉起 / pid 不符
  }
  auto* header = static_cast<SharedHeader*>(
      MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0));
  if (header == nullptr) {
    CloseHandle(mapping);
    return VoiceHookStatus{};
  }
  // 只信任契约匹配的映射（防旧/坏映射读坏内存）。
  if (header->magic != kSharedMagic || header->version != kSharedVersion) {
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return VoiceHookStatus{};
  }
  st.mapping = mapping;
  st.header = header;
  st.pid = pid;
  return StatusFromHeaderLocked(header);
}

VoiceHookStatus VoiceHookReader::Status() {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  return StatusFromHeaderLocked(st.header);
}

VoiceHookStatus VoiceHookReader::GrabRecent(int back_ms,
                                            std::vector<uint8_t>& out) {
  out.clear();
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  const VoiceHookStatus status = StatusFromHeaderLocked(h);
  if (!status.ok || back_ms <= 0) {
    return VoiceHookStatus{};
  }
  const uint32_t block_align = h->block_align;
  const uint32_t capacity = h->ring_capacity;
  if (block_align == 0 || capacity == 0) {
    return VoiceHookStatus{};
  }
  // 快照 volatile 计数（单写单读：读到的量至多滞后一个包）。
  const uint32_t write_pos = h->write_pos;
  const uint64_t total_written = h->total_written;
  if (total_written == 0 || write_pos > capacity) {
    return VoiceHookStatus{};
  }
  const size_t filled = static_cast<size_t>(
      (std::min)(total_written, static_cast<uint64_t>(capacity)));
  const int byte_rate = status.sample_rate * static_cast<int>(block_align);
  if (byte_rate <= 0 || filled == 0) {
    return VoiceHookStatus{};
  }
  size_t want = static_cast<size_t>(byte_rate) *
                static_cast<size_t>(back_ms) / 1000;
  want = (std::min)(want, filled);
  want -= (want % block_align);
  if (want == 0) {
    return VoiceHookStatus{};
  }
  // 环形缓冲紧跟 header 之后。最近 want 字节起点 = write_pos 往回 want（回绕）。
  const uint8_t* ring =
      reinterpret_cast<const uint8_t*>(h) + sizeof(SharedHeader);
  const size_t start =
      (static_cast<size_t>(write_pos) + capacity - want) % capacity;
  out.resize(want);
  const size_t first = (std::min)(want, static_cast<size_t>(capacity) - start);
  memcpy(out.data(), ring + start, first);
  if (want > first) {
    memcpy(out.data() + first, ring, want - first);
  }
  return status;
}

uint64_t VoiceHookReader::TextWriteCount() {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  if (h == nullptr || h->magic != kSharedMagic ||
      h->version != kSharedVersion) {
    return 0;
  }
  return h->text_write_count;
}

void VoiceHookReader::PollText(uint64_t from_seq,
                               std::vector<VoiceHookText>& out) {
  out.clear();
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  if (h == nullptr || h->magic != kSharedMagic ||
      h->version != kSharedVersion) {
    return;
  }
  const uint64_t count = h->text_write_count;
  if (count <= from_seq) {
    return;
  }
  const uint32_t slots = hibiki_voice_hook::kTextSlotCount;
  const uint32_t slot_bytes = hibiki_voice_hook::kTextSlotBytes;
  const uint8_t* base =
      reinterpret_cast<const uint8_t*>(h) + h->text_region_offset;
  // 只取最近 slots 条（更旧的已被覆盖）。
  uint64_t start = from_seq;
  if (count > slots && start < count - slots) {
    start = count - slots;
  }
  for (uint64_t seq = start + 1; seq <= count; seq++) {
    const uint32_t idx = static_cast<uint32_t>((seq - 1) % slots);
    const auto* slot = reinterpret_cast<const hibiki_voice_hook::TextSlot*>(
        base + static_cast<size_t>(idx) * slot_bytes);
    if (slot->seq != seq) {
      continue;  // 已被后来的行覆盖
    }
    uint32_t blen = slot->byte_len;
    const uint32_t maxb =
        slot_bytes - static_cast<uint32_t>(sizeof(hibiki_voice_hook::TextSlot));
    if (blen > maxb) {
      blen = maxb;
    }
    const uint8_t* txt =
        reinterpret_cast<const uint8_t*>(slot) + sizeof(hibiki_voice_hook::TextSlot);
    VoiceHookText line;
    line.seq = seq;
    line.timestamp_ms = slot->timestamp_ms;
    if (slot->is_utf8) {
      line.utf8.assign(reinterpret_cast<const char*>(txt), blen);
    } else {
      const int wlen = static_cast<int>(blen / 2);
      if (wlen > 0) {
        const wchar_t* w = reinterpret_cast<const wchar_t*>(txt);
        const int need = WideCharToMultiByte(CP_UTF8, 0, w, wlen, nullptr, 0,
                                              nullptr, nullptr);
        if (need > 0) {
          line.utf8.resize(static_cast<size_t>(need));
          WideCharToMultiByte(CP_UTF8, 0, w, wlen, &line.utf8[0], need, nullptr,
                              nullptr);
        }
      }
    }
    out.push_back(std::move(line));
  }
}

VoiceHookStatus VoiceHookReader::GrabClipNear(uint64_t ts_ms,
                                              uint64_t tolerance_ms,
                                              std::vector<uint8_t>& out) {
  out.clear();
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  const VoiceHookStatus status = StatusFromHeaderLocked(h);
  if (!status.ok) {
    return VoiceHookStatus{};
  }
  const uint32_t cap = h->ring_capacity;
  const uint64_t clips = h->clip_write_count;
  if (cap == 0 || clips == 0) {
    return VoiceHookStatus{};
  }
  const uint32_t clip_slots = hibiki_voice_hook::kClipCount;
  const uint8_t* clip_base =
      reinterpret_cast<const uint8_t*>(h) + h->clip_region_offset;
  const uint64_t total = h->total_written;
  const uint64_t scan_from = (clips > clip_slots) ? clips - clip_slots : 0;
  const hibiki_voice_hook::VoiceClip* best = nullptr;
  uint64_t best_diff = tolerance_ms + 1;
  for (uint64_t seq = scan_from + 1; seq <= clips; seq++) {
    const uint32_t idx = static_cast<uint32_t>((seq - 1) % clip_slots);
    const auto* c = reinterpret_cast<const hibiki_voice_hook::VoiceClip*>(
        clip_base + static_cast<size_t>(idx) * sizeof(hibiki_voice_hook::VoiceClip));
    if (c->seq != seq || c->byte_len == 0 || c->byte_len > cap) {
      continue;
    }
    // 已被环形覆盖（写该 clip 之后又写了几乎一整圈）则跳过。
    if (total > c->total_at_write && total - c->total_at_write > cap - c->byte_len) {
      continue;
    }
    const uint64_t diff = (c->timestamp_ms > ts_ms) ? (c->timestamp_ms - ts_ms)
                                                    : (ts_ms - c->timestamp_ms);
    if (diff < best_diff) {
      best_diff = diff;
      best = c;
    }
  }
  if (best == nullptr) {
    return VoiceHookStatus{};
  }
  const uint8_t* ring = reinterpret_cast<const uint8_t*>(h) + sizeof(SharedHeader);
  const uint32_t off = best->ring_offset % cap;
  const uint32_t len = best->byte_len;
  out.resize(len);
  const uint32_t first = (len <= cap - off) ? len : (cap - off);
  memcpy(out.data(), ring + off, first);
  if (len > first) {
    memcpy(out.data() + first, ring, len - first);
  }
  VoiceHookStatus s = status;
  s.sample_rate = static_cast<int>(best->sample_rate);
  s.channels = static_cast<int>(best->channels);
  s.bits_per_sample = static_cast<int>(best->bits_per_sample);
  s.is_float = best->is_float != 0;
  return s;
}

void VoiceHookReader::Close() {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  CloseLocked(st);
}

}  // namespace hibiki
