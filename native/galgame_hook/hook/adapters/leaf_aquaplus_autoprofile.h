#pragma once

// Leaf/AQUAPLUS 锚点的**自推导**。
//
// 原实现把整份 profile（25 个 RVA）钉死在单个 exe SHA-256 上：白2 换个发行版/补丁版就
// 完全不被认领。但那五处掩码签名本来就把操作数 wildcard 掉了——**签名本身是跨构建的**，
// 真正把它钉死的只是三个"期望操作数"来自硬编码 RVA。其中两个有完全通用的来源（PE 导入表、
// load config 目录），第三个（D3D9 设备指针）根本不需要期望值：从唯一命中里读出来即可。
//
// 这里只做**静态可推导**的那一层。return site / 栈帧偏移 / 顶点格式仍来自已测量 profile，
// 因此本模块单独不足以认领一个未知构建——它是那条路的第一段，且对已测量构建可当运行期自检。
//
// 所有读取都对 image.size 做边界校验：这段代码跑在玩家的游戏进程里。

#include <cstdint>
#include <cstring>

#include "exact_lookup_signature.h"
#include "leaf_aquaplus_profile.h"

namespace fushi_voice_hook {
namespace leaf_autoprofile {

struct DerivedAnchors {
  uintptr_t stack_cookie_rva = 0;
  uintptr_t get_async_key_state_iat_rva = 0;
  uintptr_t read_file_iat_rva = 0;
  uintptr_t text_traversal_rva = 0;
  uintptr_t raster_draw_rva = 0;
  uintptr_t input_poller_first_return_rva = 0;
  uintptr_t embed_leaf_hook_rva = 0;
  uintptr_t d3d9_device_pointer_rva = 0;
};

inline uintptr_t AbsoluteBaseOf(const exact_lookup::LoadedPeImage& image) {
  return image.absolute_base != 0u
             ? image.absolute_base
             : reinterpret_cast<uintptr_t>(image.base);
}

// RVA 落在映像内且从该处起至少还有 bytes 个字节可读。
inline bool RvaInImage(const exact_lookup::LoadedPeImage& image, uint64_t rva,
                       uint64_t bytes) {
  return image.base != nullptr && bytes != 0u && rva < image.size &&
         bytes <= static_cast<uint64_t>(image.size) - rva;
}

inline const uint8_t* AtRva(const exact_lookup::LoadedPeImage& image,
                            uint64_t rva, uint64_t bytes) {
  return RvaInImage(image, rva, bytes) ? image.base + rva : nullptr;
}

inline const IMAGE_NT_HEADERS32* NtHeaders32(
    const exact_lookup::LoadedPeImage& image) {
  const uint8_t* dos_bytes = AtRva(image, 0u, sizeof(IMAGE_DOS_HEADER));
  if (dos_bytes == nullptr) return nullptr;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(dos_bytes);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0) return nullptr;
  const uint8_t* nt_bytes = AtRva(image, static_cast<uint64_t>(dos->e_lfanew),
                                  sizeof(IMAGE_NT_HEADERS32));
  if (nt_bytes == nullptr) return nullptr;
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS32*>(nt_bytes);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
    return nullptr;
  }
  return nt;
}

inline bool DataDirectoryOf(const exact_lookup::LoadedPeImage& image,
                            uint32_t index, uint32_t* rva, uint32_t* size) {
  const auto* nt = NtHeaders32(image);
  if (nt == nullptr || rva == nullptr || size == nullptr) return false;
  if (index >= nt->OptionalHeader.NumberOfRvaAndSizes) return false;
  *rva = nt->OptionalHeader.DataDirectory[index].VirtualAddress;
  *size = nt->OptionalHeader.DataDirectory[index].Size;
  return *rva != 0u;
}

// 导入表里某个符号的 IAT 槽 RVA。dll 名大小写不敏感，符号名精确匹配。
inline uintptr_t DeriveImportThunkRva(const exact_lookup::LoadedPeImage& image,
                                      const char* dll, const char* symbol) {
  uint32_t dir_rva = 0u;
  uint32_t dir_size = 0u;
  if (dll == nullptr || symbol == nullptr ||
      !DataDirectoryOf(image, IMAGE_DIRECTORY_ENTRY_IMPORT, &dir_rva,
                       &dir_size)) {
    return 0u;
  }
  for (uint32_t offset = 0u;; offset += sizeof(IMAGE_IMPORT_DESCRIPTOR)) {
    const uint8_t* bytes =
        AtRva(image, static_cast<uint64_t>(dir_rva) + offset,
              sizeof(IMAGE_IMPORT_DESCRIPTOR));
    if (bytes == nullptr) return 0u;
    const auto* desc = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(bytes);
    if (desc->Name == 0u && desc->FirstThunk == 0u) return 0u;
    // 名字是 NUL 结尾串，长度未知：逐字节比较，越界即放弃。
    bool name_matches = true;
    for (uint32_t i = 0u;; ++i) {
      const uint8_t* ch = AtRva(image, static_cast<uint64_t>(desc->Name) + i, 1u);
      if (ch == nullptr) return 0u;
      const char lhs = static_cast<char>(*ch);
      const char rhs = dll[i];
      const char lower_lhs =
          (lhs >= 'A' && lhs <= 'Z') ? static_cast<char>(lhs - 'A' + 'a') : lhs;
      const char lower_rhs =
          (rhs >= 'A' && rhs <= 'Z') ? static_cast<char>(rhs - 'A' + 'a') : rhs;
      if (lower_lhs != lower_rhs) {
        name_matches = false;
        break;
      }
      if (lhs == '\0') break;
    }
    if (!name_matches) continue;

    const uint32_t lookup = desc->OriginalFirstThunk != 0u
                                ? desc->OriginalFirstThunk
                                : desc->FirstThunk;
    if (lookup == 0u || desc->FirstThunk == 0u) return 0u;
    for (uint32_t i = 0u;; ++i) {
      const uint8_t* slot_bytes =
          AtRva(image, static_cast<uint64_t>(lookup) + i * sizeof(uint32_t),
                sizeof(uint32_t));
      if (slot_bytes == nullptr) return 0u;
      uint32_t entry = 0u;
      std::memcpy(&entry, slot_bytes, sizeof(entry));
      if (entry == 0u) return 0u;
      if ((entry & IMAGE_ORDINAL_FLAG32) != 0u) continue;  // 按序号导入，无名字
      // IMAGE_IMPORT_BY_NAME：2 字节 Hint + NUL 结尾名字。
      bool symbol_matches = true;
      for (uint32_t j = 0u;; ++j) {
        const uint8_t* ch =
            AtRva(image, static_cast<uint64_t>(entry) + 2u + j, 1u);
        if (ch == nullptr) return 0u;
        if (static_cast<char>(*ch) != symbol[j]) {
          symbol_matches = false;
          break;
        }
        if (symbol[j] == '\0') break;
      }
      if (symbol_matches)
        return static_cast<uintptr_t>(desc->FirstThunk) +
               i * sizeof(uint32_t);
    }
  }
}

// /GS 栈 cookie。首选 load config 目录；老工具链可能没有该字段，此时返回 0，
// 由调用方改用"两个独立签名读出的操作数必须一致"这条更强的路（见 DeriveLeafAnchors）。
inline uintptr_t DeriveSecurityCookieRva(
    const exact_lookup::LoadedPeImage& image) {
  uint32_t dir_rva = 0u;
  uint32_t dir_size = 0u;
  if (!DataDirectoryOf(image, IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG, &dir_rva,
                       &dir_size)) {
    return 0u;
  }
  // SecurityCookie 在 IMAGE_LOAD_CONFIG_DIRECTORY32 的 0x3c 处。目录 Size 由链接器
  // 写入，老版本会短于完整结构，不能直接按结构体大小读。
  constexpr uint32_t kSecurityCookieOffset = 0x3cu;
  if (dir_size < kSecurityCookieOffset + sizeof(uint32_t)) return 0u;
  const uint8_t* bytes =
      AtRva(image, static_cast<uint64_t>(dir_rva) + kSecurityCookieOffset,
            sizeof(uint32_t));
  if (bytes == nullptr) return 0u;
  uint32_t va = 0u;
  std::memcpy(&va, bytes, sizeof(va));
  const uintptr_t absolute_base = AbsoluteBaseOf(image);
  if (va < absolute_base || va - absolute_base >= image.size) return 0u;
  return static_cast<uintptr_t>(va) - absolute_base;
}

// 定位一处唯一掩码签名，并（可选）读出其中的操作数。
inline bool LocateUniqueSignature(const exact_lookup::LoadedPeImage& image,
                                  const exact_lookup::MaskedPattern& pattern,
                                  uintptr_t* site_rva, size_t operand_offset,
                                  uint32_t* operand) {
  const auto hit =
      exact_lookup::FindUniquePatternInExecutableSections(image, pattern);
  if (hit.count != 1u || hit.address == nullptr || site_rva == nullptr)
    return false;
  const uintptr_t rva = static_cast<uintptr_t>(hit.address - image.base);
  if (operand != nullptr) {
    if (operand_offset + sizeof(uint32_t) > pattern.size ||
        !RvaInImage(image, rva + operand_offset, sizeof(uint32_t))) {
      return false;
    }
    std::memcpy(operand, hit.address + operand_offset, sizeof(*operand));
  }
  *site_rva = rva;
  return true;
}

inline bool DeriveLeafAnchors(const exact_lookup::LoadedPeImage& image,
                              DerivedAnchors* out) {
  if (out == nullptr) return false;
  *out = {};
  const uintptr_t absolute_base = AbsoluteBaseOf(image);

  uintptr_t traversal_rva = 0u;
  uint32_t traversal_cookie = 0u;
  uintptr_t raster_rva = 0u;
  uint32_t raster_cookie = 0u;
  if (!LocateUniqueSignature(image, leaf_exact::kTextTraversalEntryPattern,
                             &traversal_rva,
                             leaf_exact::kTextTraversalCookieOperandOffset,
                             &traversal_cookie) ||
      !LocateUniqueSignature(image, leaf_exact::kRasterDrawEntryPattern,
                             &raster_rva,
                             leaf_exact::kRasterDrawCookieOperandOffset,
                             &raster_cookie)) {
    return false;
  }
  // 两处**互相独立**的签名必须读出同一个 cookie。这既是 cookie 的来源，也是"这份二进制
  // 确实是这套引擎"的交叉校验——不一致就说明识别不可信，宁可不认领。
  if (traversal_cookie != raster_cookie) return false;
  if (traversal_cookie < absolute_base ||
      traversal_cookie - absolute_base >= image.size) {
    return false;
  }
  const uintptr_t cookie_rva =
      static_cast<uintptr_t>(traversal_cookie) - absolute_base;
  const uintptr_t load_config_cookie = DeriveSecurityCookieRva(image);
  if (load_config_cookie != 0u && load_config_cookie != cookie_rva) return false;

  const uintptr_t key_state_iat =
      DeriveImportThunkRva(image, "user32.dll", "GetAsyncKeyState");
  const uintptr_t read_file_iat =
      DeriveImportThunkRva(image, "kernel32.dll", "ReadFile");
  if (key_state_iat == 0u || read_file_iat == 0u) return false;

  uintptr_t poller_anchor = 0u;
  uint32_t poller_operand = 0u;
  if (!LocateUniqueSignature(image, leaf_exact::kInputPollerEntryPattern,
                             &poller_anchor,
                             leaf_exact::kInputPollerIatOperandOffset,
                             &poller_operand)) {
    return false;
  }
  // 输入轮询签名里的操作数必须正好是导入表推出的那个 IAT 槽。
  if (poller_operand != absolute_base + key_state_iat) return false;

  uintptr_t embed_anchor = 0u;
  if (!LocateUniqueSignature(image, leaf_exact::kEmbedLoopAnchorPattern,
                             &embed_anchor, 0u, nullptr)) {
    return false;
  }

  uintptr_t device_site = 0u;
  uint32_t device_operand = 0u;
  if (!LocateUniqueSignature(image, leaf_exact::kD3dDeviceAccessPattern,
                             &device_site,
                             leaf_exact::kD3dDevicePointerOperandOffset,
                             &device_operand)) {
    return false;
  }
  if (device_operand < absolute_base ||
      device_operand - absolute_base >= image.size) {
    return false;
  }

  out->stack_cookie_rva = cookie_rva;
  out->get_async_key_state_iat_rva = key_state_iat;
  out->read_file_iat_rva = read_file_iat;
  out->text_traversal_rva = traversal_rva;
  out->raster_draw_rva = raster_rva;
  out->input_poller_first_return_rva = poller_anchor + 10u;
  out->embed_leaf_hook_rva =
      embed_anchor + leaf_exact::kEmbedHookOffsetFromAnchor;
  out->d3d9_device_pointer_rva =
      static_cast<uintptr_t>(device_operand) - absolute_base;
  return true;
}

// 推导结果与已测量 profile 是否一致。已测量构建上这必须恒真——它是自推导路径的
// 运行期自检，也是把 profile 从"钉死在一个哈希"迁走之前唯一能拿到的正确性证据。
inline bool DerivedAnchorsMatchProfile(const DerivedAnchors& derived,
                                       const LeafAquaplusProfile& profile) {
  return derived.stack_cookie_rva == profile.stack_cookie_rva &&
         derived.get_async_key_state_iat_rva ==
             profile.get_async_key_state_iat_rva &&
         derived.read_file_iat_rva == profile.read_file_iat_rva &&
         derived.text_traversal_rva == profile.text_traversal_rva &&
         derived.raster_draw_rva == profile.raster_draw_rva &&
         derived.input_poller_first_return_rva ==
             profile.input_poller_first_return_rva &&
         derived.embed_leaf_hook_rva == profile.embed_leaf_hook_rva &&
         derived.d3d9_device_pointer_rva == profile.d3d9_device_pointer_rva;
}

}  // namespace leaf_autoprofile
}  // namespace fushi_voice_hook
