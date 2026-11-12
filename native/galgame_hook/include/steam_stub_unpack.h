#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook {

// SteamStub 解壳门（纯逻辑，可离线测试）。
//
// 背景：Steam 客户端路径（steam://run）拉起的进程被注入器以 15 ms 轮询发现，发现时它常常
// 还在 SteamStub 壳里——入口点落在 `.bind` 节，代码段在磁盘与刚映射的内存里都是密文，壳要
// 先原地解密再跳回原入口。LunaHook 的引擎识别只在连上进程的那一刻扫一次代码段：扫到密文就
// 认不出任何引擎，退回通用 kernel32 hook，整局没有引擎台词线程。实测 KiriKiri2 的 SteamStub
// 构建在同一台机器上两次启动结果相反（早一拍注入只剩 MultiByteToWideChar 线程；晚一拍则
// EmbedKrkr2 / Krkr2wcs / KiriKiri1-4 全部装上）——是生命周期竞态，与引擎、与具体游戏无关。
//
// 判据只看 PE 结构：exe 带 `.bind` 节时，取第一个非 `.bind`、可执行且有磁盘数据的节开头一段
// 作探针；目标进程里这段字节与磁盘相同 = 仍是密文（壳没跑完），不同 = 已解密。映像被重定位
// （运行期基址 ≠ 文件 ImageBase）时加载器的重定位修补本身就会改字节，比较失去意义，判
// kUnknown，由调用方退回「等主窗口」的通用就绪门。

struct SteamStubCodeProbe {
  bool valid = false;
  uint64_t file_image_base = 0;
  uint32_t rva = 0;
  uint32_t length = 0;
  size_t file_offset = 0;
};

// 探针最多比较的字节数：密文段开头一页足以区分；不必读整个代码段。
constexpr uint32_t kSteamStubProbeMaxBytes = 4096;

namespace steam_stub_detail {

inline bool Read16(const uint8_t* data, size_t size, size_t off, uint16_t* out) {
  if (data == nullptr || off > size || size - off < 2) return false;
  std::memcpy(out, data + off, 2);
  return true;
}
inline bool Read32(const uint8_t* data, size_t size, size_t off, uint32_t* out) {
  if (data == nullptr || off > size || size - off < 4) return false;
  std::memcpy(out, data + off, 4);
  return true;
}
inline bool Read64(const uint8_t* data, size_t size, size_t off, uint64_t* out) {
  if (data == nullptr || off > size || size - off < 8) return false;
  std::memcpy(out, data + off, 8);
  return true;
}

}  // namespace steam_stub_detail

// 从 exe 文件字节（磁盘布局）选出解壳探针。没有 `.bind` 节、或找不到合格代码节 → invalid。
inline SteamStubCodeProbe SelectSteamStubCodeProbe(const uint8_t* data, size_t size) {
  using namespace steam_stub_detail;
  SteamStubCodeProbe probe;
  uint16_t mz = 0;
  uint32_t pe_off = 0, sig = 0;
  if (!Read16(data, size, 0, &mz) || mz != 0x5A4D) return probe;
  if (!Read32(data, size, 0x3C, &pe_off) || !Read32(data, size, pe_off, &sig) ||
      sig != 0x00004550) {
    return probe;
  }
  const size_t file_hdr = static_cast<size_t>(pe_off) + 4;
  uint16_t section_count = 0, opt_size = 0, magic = 0;
  if (!Read16(data, size, file_hdr + 2, &section_count) ||
      !Read16(data, size, file_hdr + 16, &opt_size)) {
    return probe;
  }
  const size_t opt = file_hdr + 20;
  if (!Read16(data, size, opt, &magic)) return probe;
  uint64_t image_base = 0;
  if (magic == 0x20B) {
    if (!Read64(data, size, opt + 24, &image_base)) return probe;
  } else if (magic == 0x10B) {
    uint32_t base32 = 0;
    if (!Read32(data, size, opt + 28, &base32)) return probe;
    image_base = base32;
  } else {
    return probe;
  }
  const size_t sections_off = opt + opt_size;
  bool has_bind = false;
  bool found = false;
  SteamStubCodeProbe candidate;
  constexpr uint32_t kScnMemExecute = 0x20000000u;
  for (uint16_t i = 0; i < section_count; ++i) {
    const size_t s = sections_off + static_cast<size_t>(i) * 40;
    uint32_t vaddr = 0, raw_size = 0, raw_ptr = 0, characteristics = 0;
    if (s > size || size - s < 40 || !Read32(data, size, s + 12, &vaddr) ||
        !Read32(data, size, s + 16, &raw_size) ||
        !Read32(data, size, s + 20, &raw_ptr) ||
        !Read32(data, size, s + 36, &characteristics)) {
      return SteamStubCodeProbe{};
    }
    if (std::memcmp(data + s, ".bind\0", 6) == 0) {
      has_bind = true;
      continue;
    }
    if (found || (characteristics & kScnMemExecute) == 0 || raw_size == 0) continue;
    const uint32_t length =
        raw_size < kSteamStubProbeMaxBytes ? raw_size : kSteamStubProbeMaxBytes;
    if (raw_ptr > size || size - raw_ptr < length) continue;
    candidate.file_image_base = image_base;
    candidate.rva = vaddr;
    candidate.length = length;
    candidate.file_offset = raw_ptr;
    found = true;
  }
  if (!has_bind || !found) return probe;
  candidate.valid = true;
  return candidate;
}

enum class SteamStubCodeState {
  // 探针段内存字节与磁盘一致：壳还没解密代码段，不能让 LunaHook 现在扫。
  kStillPacked,
  // 内存字节已与磁盘不同：壳已原地解密。
  kUnpacked,
  // 无法用字节比较判断（映像被重定位 / 探针无效 / 读不全）：退回通用就绪门。
  kUnknown,
};

inline SteamStubCodeState ClassifySteamStubCode(const SteamStubCodeProbe& probe,
                                                uint64_t runtime_image_base,
                                                const uint8_t* file_bytes,
                                                const uint8_t* memory_bytes,
                                                size_t compared) {
  if (!probe.valid || file_bytes == nullptr || memory_bytes == nullptr ||
      compared != probe.length || probe.length == 0) {
    return SteamStubCodeState::kUnknown;
  }
  if (runtime_image_base != probe.file_image_base) return SteamStubCodeState::kUnknown;
  return std::memcmp(file_bytes, memory_bytes, compared) == 0
             ? SteamStubCodeState::kStillPacked
             : SteamStubCodeState::kUnpacked;
}

}  // namespace fushi_voice_hook
