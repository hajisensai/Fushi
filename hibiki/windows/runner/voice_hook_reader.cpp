#include "voice_hook_reader.h"

#include <windows.h>

#include <algorithm>
#include <map>
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

std::string WideToUtf8(const wchar_t* text, int length) {
  if (text == nullptr || length <= 0) return std::string();
  const int need = WideCharToMultiByte(CP_UTF8, 0, text, length, nullptr, 0,
                                        nullptr, nullptr);
  if (need <= 0) return std::string();
  std::string utf8(static_cast<size_t>(need), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, length, &utf8[0], need, nullptr,
                      nullptr);
  return utf8;
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
  // reserved_luna 高位由 Siglus 专属文件 hook 写：0x10000000=OVK hooks ready。
  // 这条路径直接导出压缩 Ogg，不要求已错过的 DirectSound 对象提供 PCM 格式。
  s.raw_voice_ready = (h->reserved_luna & 0x10000000u) != 0;
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

// 把一条 clip 的 PCM 从环形读出**追加**到 [out]（多段拼接用）；clip 已被环形覆盖返回 false。
// 调用方持锁。移植自 ring_probe.cpp 的 ReadClipPcm。
bool ReadClipPcmLocked(const SharedHeader* h, const uint8_t* ring,
                       const hibiki_voice_hook::VoiceClip* c,
                       std::vector<uint8_t>& out) {
  const uint32_t cap = h->ring_capacity;
  const uint32_t len = c->byte_len;
  if (len == 0 || len > cap) {
    return false;
  }
  if (h->total_written > c->total_at_write &&
      h->total_written - c->total_at_write > cap - len) {
    return false;  // 已被环形覆盖
  }
  const uint32_t off = c->ring_offset % cap;
  const size_t base = out.size();
  out.resize(base + len);
  const uint32_t first = (len <= cap - off) ? len : (cap - off);
  memcpy(out.data() + base, ring + off, first);
  if (len > first) {
    memcpy(out.data() + base + first, ring, len - first);
  }
  return true;
}

// 一条 clip 的 16-bit PCM 平均绝对幅值（能量代理）。非 16-bit 返回 -1（调用方退化）。已被环形
// 覆盖返回 0。调用方持锁。移植自 ring_probe.cpp 的 ClipEnergy16。
double ClipEnergy16Locked(const SharedHeader* h, const uint8_t* ring,
                          const hibiki_voice_hook::VoiceClip* c) {
  if (c->bits_per_sample != 16 || c->is_float) {
    return -1.0;
  }
  std::vector<uint8_t> buf;
  if (!ReadClipPcmLocked(h, ring, c, buf) || buf.size() < 2) {
    return 0.0;
  }
  const int16_t* s = reinterpret_cast<const int16_t*>(buf.data());
  const size_t n = buf.size() / 2;
  double acc = 0;
  for (size_t i = 0; i < n; i++) {
    acc += (s[i] < 0) ? -static_cast<double>(s[i]) : static_cast<double>(s[i]);
  }
  return acc / static_cast<double>(n);
}

// 收集环形里有效（seq 匹配、byte_len 合法）的语音 clip 指针（seq 升序）。调用方持锁。
std::vector<const hibiki_voice_hook::VoiceClip*> CollectValidClipsLocked(
    const SharedHeader* h) {
  std::vector<const hibiki_voice_hook::VoiceClip*> valid;
  const uint32_t cap = h->ring_capacity;
  const uint64_t clips = h->clip_write_count;
  if (cap == 0 || clips == 0) {
    return valid;
  }
  const uint32_t clip_slots = hibiki_voice_hook::kClipCount;
  const uint8_t* clip_base =
      reinterpret_cast<const uint8_t*>(h) + h->clip_region_offset;
  const uint64_t scan_from = (clips > clip_slots) ? clips - clip_slots : 0;
  for (uint64_t seq = scan_from + 1; seq <= clips; seq++) {
    const uint32_t idx = static_cast<uint32_t>((seq - 1) % clip_slots);
    const auto* c = reinterpret_cast<const hibiki_voice_hook::VoiceClip*>(
        clip_base + static_cast<size_t>(idx) *
                        sizeof(hibiki_voice_hook::VoiceClip));
    if (c->seq == seq && c->byte_len != 0 && c->byte_len <= cap) {
      valid.push_back(c);
    }
  }
  return valid;
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
  HANDLE mapping =
      OpenFileMappingW(FILE_MAP_READ | FILE_MAP_WRITE, FALSE, name.c_str());
  if (mapping == nullptr) {
    return VoiceHookStatus{};  // injector 未拉起 / pid 不符
  }
  auto* header = static_cast<SharedHeader*>(
      MapViewOfFile(mapping, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 0));
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
    line.thread_id = slot->thread_id;
    line.thread_address = slot->thread_address;
    line.thread_context = slot->thread_context;
    line.thread_context2 = slot->thread_context2;
    line.process_id = slot->process_id;
    line.source_kind = slot->source_kind;
    const uint32_t hook_name_len = (std::min)(
        slot->hook_name_len, hibiki_voice_hook::kTextHookNameChars);
    line.hook_name.assign(slot->hook_name, hook_name_len);
    const uint32_t hook_code_len = (std::min)(
        slot->hook_code_len, hibiki_voice_hook::kTextHookCodeChars);
    line.hook_code = WideToUtf8(slot->hook_code,
                                static_cast<int>(hook_code_len));
    if (slot->is_utf8) {
      line.utf8.assign(reinterpret_cast<const char*>(txt), blen);
    } else {
      const int wlen = static_cast<int>(blen / 2);
      line.utf8 = WideToUtf8(reinterpret_cast<const wchar_t*>(txt), wlen);
    }
    out.push_back(std::move(line));
  }
}

bool VoiceHookReader::SelectTextThread(uint64_t thread_id) {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  SharedHeader* h = st.header;
  if (h == nullptr || h->magic != kSharedMagic || h->version != kSharedVersion) {
    return false;
  }
  InterlockedExchange64(
      reinterpret_cast<volatile LONGLONG*>(&h->selected_text_thread_id),
      static_cast<LONGLONG>(thread_id));
  return true;
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

VoiceHookStatus VoiceHookReader::GrabUtterance(
    uint64_t ts_ms, uint64_t target_source,
    const std::vector<uint64_t>& exclude_sources, std::vector<uint8_t>& out) {
  out.clear();
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  const VoiceHookStatus status = StatusFromHeaderLocked(h);
  if (!status.ok) {
    return VoiceHookStatus{};
  }
  const std::vector<const hibiki_voice_hook::VoiceClip*> valid =
      CollectValidClipsLocked(h);
  if (valid.empty()) {
    return VoiceHookStatus{};
  }
  const uint8_t* ring =
      reinterpret_cast<const uint8_t*>(h) + sizeof(SharedHeader);

  // 选语音源：target_source 非 0 直接用（手动选轨）；否则按能量自动选（排除 exclude_sources）。
  bool filter_by_src = false;
  uint64_t sel_src = 0;
  if (target_source != 0) {
    filter_by_src = true;
    sel_src = target_source;
  } else {
    // 每源：说话前窗口 [ts-900,ts-250] 与文本时刻窗口 [ts-150,ts+450] 的平均能量。
    std::map<uint64_t, double> e_before, e_at;
    std::map<uint64_t, int> n_before, n_at;
    bool any_energy = false;
    for (const auto* c : valid) {
      bool excluded = false;
      for (const uint64_t ex : exclude_sources) {
        if (ex == c->source_ptr) {
          excluded = true;
          break;
        }
      }
      if (excluded) {
        continue;  // 用户标记的 BGM 源不参与自动选源
      }
      const double e = ClipEnergy16Locked(h, ring, c);
      if (e < 0) {
        continue;  // 非 16-bit
      }
      any_energy = true;
      const int64_t d = static_cast<int64_t>(c->timestamp_ms) -
                        static_cast<int64_t>(ts_ms);
      if (d >= -900 && d <= -250) {
        e_before[c->source_ptr] += e;
        n_before[c->source_ptr]++;
      }
      if (d >= -150 && d <= 450) {
        e_at[c->source_ptr] += e;
        n_at[c->source_ptr]++;
      }
    }
    // 语音源 = (文本时刻平均能量 - 说话前平均能量) 最大者：从静音跳到有声。
    double best_delta = -1e18;
    for (const auto& kv : e_at) {
      if (kv.second <= 0 || n_at[kv.first] == 0) {
        continue;
      }
      const double at_avg = kv.second / n_at[kv.first];
      const double bef_avg =
          (n_before.count(kv.first) && n_before[kv.first] > 0)
              ? e_before[kv.first] / n_before[kv.first]
              : 0.0;
      const double delta = at_avg - bef_avg;
      if (delta > best_delta) {
        best_delta = delta;
        sel_src = kv.first;
      }
    }
    if (any_energy) {
      if (sel_src == 0) {
        return VoiceHookStatus{};  // 有能量数据却选不出源（全被排除）——交调用方回退
      }
      filter_by_src = true;
    }
    // any_energy=false（非 16-bit）：无法能量选源，退化为拼所有源（filter_by_src 保持 false）。
  }

  // 拼接选定源在 [ts-200, ts+6000] 的段；静音判据用该源峰值能量的 8%。
  std::vector<uint8_t> pcm;
  const hibiki_voice_hook::VoiceClip* fmt = nullptr;
  double peak = 1.0;
  for (const auto* c : valid) {
    if (filter_by_src && c->source_ptr != sel_src) {
      continue;
    }
    const int64_t d = static_cast<int64_t>(c->timestamp_ms) -
                      static_cast<int64_t>(ts_ms);
    if (d < -200 || d > 6000) {
      continue;
    }
    const double e = ClipEnergy16Locked(h, ring, c);
    if (e > peak) {
      peak = e;
    }
    if (ReadClipPcmLocked(h, ring, c, pcm) && fmt == nullptr) {
      fmt = c;
    }
  }
  if (fmt == nullptr || pcm.empty()) {
    return VoiceHookStatus{};
  }
  // 去首尾静音（16-bit）：阈值 = peak*0.08，帧对齐。
  if (fmt->bits_per_sample == 16 && !fmt->is_float) {
    const int16_t thr = static_cast<int16_t>(peak * 0.08);
    const int16_t* s = reinterpret_cast<const int16_t*>(pcm.data());
    const size_t n = pcm.size() / 2;
    size_t lo = 0, hi = n;
    while (lo < n && (s[lo] < 0 ? -s[lo] : s[lo]) < thr) {
      lo++;
    }
    while (hi > lo && (s[hi - 1] < 0 ? -s[hi - 1] : s[hi - 1]) < thr) {
      hi--;
    }
    const uint32_t ch = fmt->channels ? fmt->channels : 1;
    lo -= (lo % ch);  // 帧对齐
    hi -= (hi % ch);
    if (hi > lo) {
      std::vector<uint8_t> trimmed(
          pcm.begin() + static_cast<long>(lo * 2),
          pcm.begin() + static_cast<long>(hi * 2));
      pcm.swap(trimmed);
    }
  }
  out.swap(pcm);
  VoiceHookStatus s = status;
  s.sample_rate = static_cast<int>(fmt->sample_rate);
  s.channels = static_cast<int>(fmt->channels);
  s.bits_per_sample = static_cast<int>(fmt->bits_per_sample);
  s.is_float = fmt->is_float != 0;
  return s;
}

void VoiceHookReader::ListAudioTracks(uint64_t ts_ms,
                                      std::vector<VoiceTrackInfo>& out) {
  out.clear();
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  const VoiceHookStatus status = StatusFromHeaderLocked(h);
  if (!status.ok) {
    return;
  }
  const std::vector<const hibiki_voice_hook::VoiceClip*> valid =
      CollectValidClipsLocked(h);
  if (valid.empty()) {
    return;
  }
  const uint8_t* ring =
      reinterpret_cast<const uint8_t*>(h) + sizeof(SharedHeader);
  // 按 source_ptr 聚合；order_index 按该源首次出现（valid 已按 seq 升序）分配。
  std::map<uint64_t, VoiceTrackInfo> tracks;
  std::map<uint64_t, uint64_t> sum_bytes;    // 段字节累计
  std::map<uint64_t, double> sum_energy_at;  // 文本时刻窗能量累计
  std::map<uint64_t, int> n_energy_at;       // 文本时刻窗计数
  int next_order = 0;
  for (const auto* c : valid) {
    auto it = tracks.find(c->source_ptr);
    if (it == tracks.end()) {
      VoiceTrackInfo info;
      info.source_ptr = c->source_ptr;
      info.sample_rate = static_cast<int>(c->sample_rate);
      info.channels = static_cast<int>(c->channels);
      info.bits_per_sample = static_cast<int>(c->bits_per_sample);
      info.is_float = c->is_float != 0;
      info.order_index = next_order++;
      it = tracks.emplace(c->source_ptr, info).first;
    }
    it->second.clip_count++;
    sum_bytes[c->source_ptr] += c->byte_len;
    const int64_t d =
        static_cast<int64_t>(c->timestamp_ms) - static_cast<int64_t>(ts_ms);
    if (d >= -150 && d <= 450) {
      const double e = ClipEnergy16Locked(h, ring, c);
      if (e >= 0) {
        sum_energy_at[c->source_ptr] += e;
        n_energy_at[c->source_ptr]++;
      }
    }
  }
  for (const auto& kv : tracks) {
    VoiceTrackInfo info = kv.second;
    if (info.clip_count > 0) {
      info.avg_bytes =
          sum_bytes[kv.first] / static_cast<uint64_t>(info.clip_count);
    }
    const int ne = n_energy_at.count(kv.first) ? n_energy_at[kv.first] : 0;
    info.avg_energy = (ne > 0) ? sum_energy_at[kv.first] / ne : -1.0;
    out.push_back(info);
  }
  // 按创建顺序返回（UI 稳定展示）。
  std::sort(out.begin(), out.end(),
            [](const VoiceTrackInfo& a, const VoiceTrackInfo& b) {
              return a.order_index < b.order_index;
            });
}

void VoiceHookReader::Close() {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  CloseLocked(st);
}

}  // namespace hibiki
