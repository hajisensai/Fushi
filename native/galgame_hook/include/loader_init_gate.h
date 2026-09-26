#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook {

// 早注入的「加载器初始化门」判据（纯逻辑，可离线测试）。
//
// 背景：CREATE_SUSPENDED 创建的进程里，第一个开始执行的线程负责跑进程初始化
// （LdrpInitializeProcess：映射静态导入、跑它们的 DllMain、执行 exe 的 TLS 回调）。
// 旧早注入直接 CreateRemoteThread(LoadLibraryW)，于是**我们的注入线程**成了那个初始化
// 线程——注入日志里恒为 `kernel32 target=00000000` 就是这个事实。对普通 exe 无害；但 exe
// 带 TLS 回调时，这些回调（加壳器 / 保护壳的初始化代码最常放在这里，如 Enigma Protector）
// 跑在我们的线程上：实测《喫茶ステラと死神の蝶》汉化版（Enigma 加壳，1 个 TLS 回调）远程
// LoadLibraryW 10 秒不返回、就绪超时、游戏随即退出；同一 exe 正常启动后 --pid 附着完全
// 正常。这是 PE 结构层面的生命周期问题，与引擎、与具体游戏都无关。
//
// 门的做法：在 exe 入口点写 `EB FE`（jmp $），让主线程自己完成进程初始化并停在入口点，
// 挂起它、还原原字节后再注入。仍早于 exe 自身任何代码（CRT 静态构造、引擎启动、音频设备
// 创建），不丢早注入的能力。判据只看 PE 结构：有 TLS 回调才启用，其余 exe 行为不变。

struct PeLaunchLayout {
  bool valid = false;
  bool is_64bit = false;
  uint32_t entry_point_rva = 0;
  uint32_t tls_callback_count = 0;
  // Steam DRM（SteamStub）包壳的 exe 带 `.bind` 节、入口点落在壳里；它必须在 Steam 客户端
  // 上下文里启动（BUG-1192）。只作启动路径分型诊断，不据此改变启动方式。
  bool steam_stub = false;
};

namespace loader_init_gate_detail {

inline bool ReadU16(const uint8_t* data, size_t size, size_t off, uint16_t* out) {
  if (off > size || size - off < 2) return false;
  std::memcpy(out, data + off, 2);
  return true;
}
inline bool ReadU32(const uint8_t* data, size_t size, size_t off, uint32_t* out) {
  if (off > size || size - off < 4) return false;
  std::memcpy(out, data + off, 4);
  return true;
}
inline bool ReadU64(const uint8_t* data, size_t size, size_t off, uint64_t* out) {
  if (off > size || size - off < 8) return false;
  std::memcpy(out, data + off, 8);
  return true;
}

// 文件布局下把 RVA 换成文件偏移；落不进任何节（或只在节的虚拟尾部）返回 false。
inline bool RvaToOffset(const uint8_t* data, size_t size, size_t sections_off,
                        uint16_t section_count, uint32_t rva, size_t* out) {
  for (uint16_t i = 0; i < section_count; ++i) {
    const size_t s = sections_off + static_cast<size_t>(i) * 40;
    uint32_t vsize = 0, vaddr = 0, raw_size = 0, raw_ptr = 0;
    if (!ReadU32(data, size, s + 8, &vsize) || !ReadU32(data, size, s + 12, &vaddr) ||
        !ReadU32(data, size, s + 16, &raw_size) ||
        !ReadU32(data, size, s + 20, &raw_ptr)) {
      return false;
    }
    const uint32_t span = vsize > raw_size ? vsize : raw_size;
    if (rva >= vaddr && rva - vaddr < span) {
      const uint32_t delta = rva - vaddr;
      if (delta >= raw_size) return false;
      *out = static_cast<size_t>(raw_ptr) + delta;
      return *out < size;
    }
  }
  return false;
}

}  // namespace loader_init_gate_detail

// 解析 exe 文件字节（磁盘布局）。只读头部与 TLS 目录，不信任任何字段：越界一律判无效。
inline PeLaunchLayout ParsePeLaunchLayout(const uint8_t* data, size_t size) {
  using namespace loader_init_gate_detail;
  PeLaunchLayout layout;
  uint16_t mz = 0;
  uint32_t pe_off = 0, sig = 0;
  if (!ReadU16(data, size, 0, &mz) || mz != 0x5A4D) return layout;
  if (!ReadU32(data, size, 0x3C, &pe_off) || !ReadU32(data, size, pe_off, &sig) ||
      sig != 0x00004550) {
    return layout;
  }
  const size_t file_hdr = static_cast<size_t>(pe_off) + 4;
  uint16_t section_count = 0, opt_size = 0, magic = 0;
  if (!ReadU16(data, size, file_hdr + 2, &section_count) ||
      !ReadU16(data, size, file_hdr + 16, &opt_size)) {
    return layout;
  }
  const size_t opt = file_hdr + 20;
  if (!ReadU16(data, size, opt, &magic)) return layout;
  if (magic != 0x10B && magic != 0x20B) return layout;
  const bool is64 = magic == 0x20B;
  uint32_t entry = 0;
  if (!ReadU32(data, size, opt + 16, &entry)) return layout;
  uint64_t image_base = 0;
  if (is64) {
    if (!ReadU64(data, size, opt + 24, &image_base)) return layout;
  } else {
    uint32_t base32 = 0;
    if (!ReadU32(data, size, opt + 28, &base32)) return layout;
    image_base = base32;
  }
  const size_t dirs = opt + (is64 ? 112 : 96);
  uint32_t dir_count = 0;
  if (!ReadU32(data, size, dirs - 4, &dir_count)) return layout;
  const size_t sections_off = opt + opt_size;

  layout.valid = true;
  layout.is_64bit = is64;
  layout.entry_point_rva = entry;
  for (uint16_t i = 0; i < section_count; ++i) {
    const size_t s = sections_off + static_cast<size_t>(i) * 40;
    if (s > size || size - s < 8) break;
    if (std::memcmp(data + s, ".bind\0", 6) == 0) layout.steam_stub = true;
  }

  constexpr uint32_t kTlsDirectoryIndex = 9;
  if (dir_count <= kTlsDirectoryIndex) return layout;
  uint32_t tls_rva = 0, tls_size = 0;
  if (!ReadU32(data, size, dirs + kTlsDirectoryIndex * 8, &tls_rva) ||
      !ReadU32(data, size, dirs + kTlsDirectoryIndex * 8 + 4, &tls_size) ||
      tls_rva == 0) {
    return layout;
  }
  size_t tls_off = 0;
  if (!RvaToOffset(data, size, sections_off, section_count, tls_rva, &tls_off)) {
    return layout;
  }
  // IMAGE_TLS_DIRECTORY.AddressOfCallBacks：32 位在 +12，64 位在 +24，均为 VA。
  uint64_t callbacks_va = 0;
  if (is64) {
    if (!ReadU64(data, size, tls_off + 24, &callbacks_va)) return layout;
  } else {
    uint32_t va32 = 0;
    if (!ReadU32(data, size, tls_off + 12, &va32)) return layout;
    callbacks_va = va32;
  }
  if (callbacks_va == 0 || callbacks_va < image_base) return layout;
  const uint64_t callbacks_rva64 = callbacks_va - image_base;
  if (callbacks_rva64 > 0xFFFFFFFFull) return layout;
  size_t cb_off = 0;
  if (!RvaToOffset(data, size, sections_off, section_count,
                   static_cast<uint32_t>(callbacks_rva64), &cb_off)) {
    // 回调数组落在只有虚拟尺寸的节里（加壳器运行期才填）：静态看不到条目，但 TLS 目录
    // 明确声明了回调数组，按「有回调」处理——宁可多过一次门，也不能让壳代码跑在注入线程上。
    layout.tls_callback_count = 1;
    return layout;
  }
  constexpr uint32_t kMaxCallbacks = 64;
  const size_t step = is64 ? 8 : 4;
  for (uint32_t i = 0; i < kMaxCallbacks; ++i) {
    uint64_t cb = 0;
    if (is64) {
      if (!ReadU64(data, size, cb_off + i * step, &cb)) break;
    } else {
      uint32_t cb32 = 0;
      if (!ReadU32(data, size, cb_off + i * step, &cb32)) break;
      cb = cb32;
    }
    if (cb == 0) break;
    ++layout.tls_callback_count;
  }
  return layout;
}

// 是否对这个 exe 启用加载器初始化门。只有「挂起创建、且之后由注入器负责恢复」的早注入
// 路径才有意义（延迟附着 / 跟随子进程 / 已提前恢复的进程早已在跑）；判据只看 PE 结构。
inline bool ShouldUseLoaderInitGate(const PeLaunchLayout& layout,
                                    bool injector_owns_suspended_primary) {
  return injector_owns_suspended_primary && layout.valid &&
         layout.entry_point_rva != 0 && layout.tls_callback_count > 0;
}

}  // namespace fushi_voice_hook
