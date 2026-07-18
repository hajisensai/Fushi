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

void VoiceHookReader::Close() {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  CloseLocked(st);
}

}  // namespace hibiki
