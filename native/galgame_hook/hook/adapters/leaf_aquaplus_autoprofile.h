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


// ── 第二段：return site 的解析 ────────────────────────────────────────────
//
// 这些字段（glyph 派发、各处 call 的返回点、VOICE.PAK 的同步 ReadFile 返回点）没有各自
// 的唯一签名可扫。给每个都编一套 ad-hoc 推导规则很容易猜错，而且是**静默**猜错——几何
// 会歪、语音会配不上，却没有任何一处报错。
//
// 采用的办法是：把它们表达成**相对已推导锚点的位移**，再用结构门里已有的调用形状校验逐个
// 验真。位移取自已测量构建，只当搜索起点；真正决定采信与否的永远是那几个调用形状判定。
// VN 的补丁版最常见的变化是整体地址位移而非重新 codegen，位移 + 形状校验正好覆盖这一类；
// codegen 真变了则形状校验失败，于是拒绝认领——不猜。
//
// 起点不成立时在有界窗口内搜索，且要求窗口内**唯一**满足形状判定的位置：多于一个就说明
// 判据不足以定位，同样拒绝。
constexpr uintptr_t kLeafResolveWindow = 0x40u;

struct LeafAnchorDeltas {
  intptr_t glyph_dispatch_from_traversal = -0x220;
  intptr_t raster_glyph_return_from_traversal = -0x9;
  intptr_t glyph_single_return_from_traversal = 0xCB2;
  intptr_t glyph_double_first_return_from_traversal = 0xE02;
  intptr_t glyph_double_second_return_from_traversal = 0xEC5;
  intptr_t quad_draw_return_from_raster = 0x2789;
  intptr_t alternate_quad_draw_return_from_raster = 0x13D8;
  intptr_t input_poller_last_return_from_anchor = 0x180;
  intptr_t voice_archive_read_return_from_embed_anchor = 0x7E9A;
};

inline constexpr LeafAnchorDeltas kMeasuredLeafAnchorDeltas = {};

// rel32 call 的目标 RVA。return_rva 是**调用之后**那条指令的 RVA。
inline bool DecodeRel32CallTarget(const exact_lookup::LoadedPeImage& image,
                                  uintptr_t return_rva, uintptr_t* target_rva) {
  if (target_rva == nullptr || return_rva < 5u) return false;
  const uint8_t* call = AtRva(image, return_rva - 5u, 5u);
  if (call == nullptr || call[0] != 0xe8u) return false;
  int32_t displacement = 0;
  std::memcpy(&displacement, call + 1, sizeof(displacement));
  const int64_t target =
      static_cast<int64_t>(return_rva) + static_cast<int64_t>(displacement);
  if (target < 0 || static_cast<uint64_t>(target) >= image.size) return false;
  *target_rva = static_cast<uintptr_t>(target);
  return true;
}

// 在 [candidate-window, candidate+window] 内找**唯一**满足 predicate 的 RVA。
// candidate 自身成立时直接采用（补丁版位移为零的常见情形），不再扫窗口。
template <typename Predicate>
inline bool ResolveNearCandidate(uintptr_t candidate, uintptr_t window,
                                 size_t image_size, Predicate predicate,
                                 uintptr_t* resolved) {
  if (resolved == nullptr || candidate == 0u || candidate >= image_size)
    return false;
  if (predicate(candidate)) {
    *resolved = candidate;
    return true;
  }
  uintptr_t hit = 0u;
  uint32_t hits = 0u;
  const uintptr_t low = candidate > window ? candidate - window : 1u;
  const uintptr_t high =
      candidate + window < image_size ? candidate + window : image_size - 1u;
  for (uintptr_t rva = low; rva <= high; ++rva) {
    if (!predicate(rva)) continue;
    if (++hits > 1u) return false;  // 判据不足以定位，宁可不认
    hit = rva;
  }
  if (hits != 1u) return false;
  *resolved = hit;
  return true;
}

inline uintptr_t OffsetRva(uintptr_t anchor, intptr_t delta) {
  const intptr_t value = static_cast<intptr_t>(anchor) + delta;
  return value > 0 ? static_cast<uintptr_t>(value) : 0u;
}

// 用推导出的锚点 + 形状校验解析出一份完整 profile。
// 成功返回 true，且 out 里除栈帧偏移/顶点格式外的每个 RVA 都经过形状判定。
inline bool ResolveLeafProfile(const exact_lookup::LoadedPeImage& image,
                               const DerivedAnchors& anchors,
                               const LeafAnchorDeltas& deltas,
                               LeafAquaplusProfile* out) {
  if (out == nullptr || image.base == nullptr) return false;
  const uintptr_t traversal = anchors.text_traversal_rva;
  const uintptr_t raster = anchors.raster_draw_rva;
  if (traversal == 0u || raster == 0u) return false;
  const uintptr_t poller_anchor =
      anchors.input_poller_first_return_rva >= 10u
          ? anchors.input_poller_first_return_rva - 10u
          : 0u;
  const uintptr_t embed_anchor =
      anchors.embed_leaf_hook_rva >= leaf_exact::kEmbedHookOffsetFromAnchor
          ? anchors.embed_leaf_hook_rva - leaf_exact::kEmbedHookOffsetFromAnchor
          : 0u;
  if (poller_anchor == 0u || embed_anchor == 0u) return false;

  // 单字节 glyph 返回点先定下来，glyph 派发地址由它的 rel32 目标**解码**得到，
  // 而不是再猜一个位移；随后要求另外两个返回点调用同一个目标。
  uintptr_t glyph_single = 0u;
  if (!ResolveNearCandidate(
          OffsetRva(traversal, deltas.glyph_single_return_from_traversal),
          kLeafResolveWindow, image.size,
          [&image](uintptr_t rva) {
            uintptr_t target = 0u;
            return DecodeRel32CallTarget(image, rva, &target);
          },
          &glyph_single)) {
    return false;
  }
  uintptr_t glyph_dispatch = 0u;
  if (!DecodeRel32CallTarget(image, glyph_single, &glyph_dispatch)) return false;
  if (!exact_lookup::SectionHasRole(
          exact_lookup::FindSectionForRva(image, glyph_dispatch, 1u),
          IMAGE_SCN_MEM_EXECUTE)) {
    return false;
  }

  const auto calls_dispatch = [&image, glyph_dispatch](uintptr_t rva) {
    return exact_lookup::MatchesRel32CallEndingAt(image, rva, glyph_dispatch);
  };
  uintptr_t glyph_double_first = 0u;
  uintptr_t glyph_double_second = 0u;
  if (!ResolveNearCandidate(
          OffsetRva(traversal, deltas.glyph_double_first_return_from_traversal),
          kLeafResolveWindow, image.size, calls_dispatch,
          &glyph_double_first) ||
      !ResolveNearCandidate(
          OffsetRva(traversal,
                    deltas.glyph_double_second_return_from_traversal),
          kLeafResolveWindow, image.size, calls_dispatch,
          &glyph_double_second)) {
    return false;
  }

  uintptr_t raster_glyph_return = 0u;
  if (!ResolveNearCandidate(
          OffsetRva(traversal, deltas.raster_glyph_return_from_traversal),
          kLeafResolveWindow, image.size,
          [&image, raster](uintptr_t rva) {
            return exact_lookup::MatchesRel32CallEndingAt(image, rva, raster);
          },
          &raster_glyph_return)) {
    return false;
  }

  const auto indirect_d0 = [&image](uintptr_t rva) {
    return exact_lookup::MatchesRegisterIndirectCallEndingAt(image, rva, 0xd0u);
  };
  const auto indirect_d6 = [&image](uintptr_t rva) {
    return exact_lookup::MatchesRegisterIndirectCallEndingAt(image, rva, 0xd6u);
  };
  uintptr_t quad_draw_return = 0u;
  uintptr_t alternate_quad_draw_return = 0u;
  uintptr_t poller_last_return = 0u;
  if (!ResolveNearCandidate(
          OffsetRva(raster, deltas.quad_draw_return_from_raster),
          kLeafResolveWindow, image.size, indirect_d0, &quad_draw_return) ||
      !ResolveNearCandidate(
          OffsetRva(raster, deltas.alternate_quad_draw_return_from_raster),
          kLeafResolveWindow, image.size, indirect_d0,
          &alternate_quad_draw_return) ||
      !ResolveNearCandidate(
          OffsetRva(poller_anchor,
                    deltas.input_poller_last_return_from_anchor),
          kLeafResolveWindow, image.size, indirect_d6, &poller_last_return)) {
    return false;
  }
  if (quad_draw_return == alternate_quad_draw_return) return false;

  const uintptr_t read_file_iat = anchors.read_file_iat_rva;
  uintptr_t voice_read_return = 0u;
  if (!ResolveNearCandidate(
          OffsetRva(embed_anchor,
                    deltas.voice_archive_read_return_from_embed_anchor),
          kLeafResolveWindow, image.size,
          [&image, read_file_iat](uintptr_t rva) {
            return exact_lookup::MatchesAbsoluteIndirectCallEndingAt(
                image, rva, read_file_iat);
          },
          &voice_read_return)) {
    return false;
  }

  *out = kWhiteAlbum2LeafAquaplusProfile;  // 栈帧偏移/顶点格式沿用已测量值
  out->executable_sha256 = {};  // 解析出来的 profile 不冒充已测量身份
  out->d3d9_device_pointer_rva = anchors.d3d9_device_pointer_rva;
  out->stack_cookie_rva = anchors.stack_cookie_rva;
  out->get_async_key_state_iat_rva = anchors.get_async_key_state_iat_rva;
  out->read_file_iat_rva = anchors.read_file_iat_rva;
  out->embed_leaf_hook_rva = anchors.embed_leaf_hook_rva;
  out->input_poller_first_return_rva = anchors.input_poller_first_return_rva;
  out->input_poller_last_return_rva = poller_last_return;
  out->text_traversal_rva = traversal;
  out->raster_draw_rva = raster;
  out->glyph_dispatch_rva = glyph_dispatch;
  out->raster_glyph_return_rva = raster_glyph_return;
  out->glyph_single_return_rva = glyph_single;
  out->glyph_double_first_return_rva = glyph_double_first;
  out->glyph_double_second_return_rva = glyph_double_second;
  out->quad_draw_return_rva = quad_draw_return;
  out->alternate_quad_draw_return_rva = alternate_quad_draw_return;
  out->voice_archive_read_return_rva = voice_read_return;
  return true;
}

}  // namespace leaf_autoprofile
}  // namespace fushi_voice_hook
