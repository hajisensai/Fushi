// Leaf/AQUAPLUS 离线站点探针。
//
// 用法：fushi_leaf_site_probe <image-file> [--mapped]
//   <image-file> 默认按**磁盘 PE 文件**读取并手工按节展开（与 adapter 的 LoadLeafPristineImage
//   同一套规则）；加 --mapped 时按**已按节对齐的运行时映像 dump**直接读取（脱壳 / 运行期解密
//   的主模块）。两者都只读字节，不执行样本里的任何东西。
//
// 输出只含结构元数据：PE 头字段、每一处推导站点的 RVA、以及推导断在哪一步。不输出样本的任何
// 字节内容（台词 / 字符串表 / 资源都不打印），因此可以把输出贴进 PR 或台账。
//
// 它跑的就是 hook 里的同一份 leaf_autoprofile 代码（DeriveLeafAnchors / ResolveLeafProfile），
// 所以离线结果与运行期结构门的结论一致；样本二进制不入库，这是跨构建正确性的唯一离线证据。
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "exact_lookup_signature.h"
#include "leaf_aquaplus_autoprofile.h"
#include "leaf_aquaplus_profile.h"

namespace {

namespace el = fushi_voice_hook::exact_lookup;
namespace ap = fushi_voice_hook::leaf_autoprofile;

bool ReadWholeFile(const wchar_t* path, std::vector<uint8_t>* out) {
  std::ifstream file(path, std::ios::binary);
  if (!file) return false;
  out->assign(std::istreambuf_iterator<char>(file),
              std::istreambuf_iterator<char>());
  return !out->empty();
}

// 磁盘 PE → 按节对齐的私有副本（不施加重定位，绝对操作数仍按首选基址编码）。
bool ExpandFileImage(const std::vector<uint8_t>& raw,
                     std::vector<uint8_t>* image) {
  if (raw.size() < sizeof(IMAGE_DOS_HEADER)) return false;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(raw.data());
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 ||
      static_cast<size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS32) >
          raw.size()) {
    return false;
  }
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS32*>(raw.data() + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
    return false;
  }
  const uint32_t image_bytes = nt->OptionalHeader.SizeOfImage;
  const uint32_t header_bytes = nt->OptionalHeader.SizeOfHeaders;
  if (image_bytes == 0u || image_bytes > 0x10000000u ||
      header_bytes > raw.size() || header_bytes > image_bytes) {
    return false;
  }
  image->assign(image_bytes, 0u);
  std::memcpy(image->data(), raw.data(), header_bytes);
  const auto* section = IMAGE_FIRST_SECTION(nt);
  for (WORD index = 0; index < nt->FileHeader.NumberOfSections;
       ++index, ++section) {
    const uint32_t va = section->VirtualAddress;
    const uint32_t raw_offset = section->PointerToRawData;
    const uint32_t raw_size = section->SizeOfRawData;
    if (raw_size == 0u) continue;
    if (va >= image_bytes || raw_size > image_bytes - va ||
        raw_offset > raw.size() || raw_size > raw.size() - raw_offset) {
      return false;
    }
    std::memcpy(image->data() + va, raw.data() + raw_offset, raw_size);
  }
  return true;
}

void PrintRva(const char* name, uintptr_t rva) {
  std::printf("  %-36s 0x%06zx\n", name, static_cast<size_t>(rva));
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: fushi_leaf_site_probe <image> [--mapped]\n");
    return 2;
  }
  const bool mapped = argc >= 3 && std::wstring(argv[2]) == L"--mapped";
  std::vector<uint8_t> raw;
  if (!ReadWholeFile(argv[1], &raw)) {
    std::fprintf(stderr, "cannot read image\n");
    return 2;
  }
  std::vector<uint8_t> image_bytes;
  if (mapped) {
    image_bytes = raw;
  } else if (!ExpandFileImage(raw, &image_bytes)) {
    std::printf("verdict=reject stage=pe_expand\n");
    return 1;
  }
  el::LoadedPeImage image;
  if (!el::OpenLoadedPeImage(reinterpret_cast<HMODULE>(image_bytes.data()),
                             &image) ||
      image.machine != IMAGE_FILE_MACHINE_I386 || image.pointer_bits != 32u) {
    std::printf("verdict=reject stage=pe_open\n");
    return 1;
  }
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(image.base);
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS32*>(image.base + dos->e_lfanew);
  image.absolute_base = nt->OptionalHeader.ImageBase;
  std::printf("layout=%s image_base=0x%08x size_of_image=0x%zx sections=%zu\n",
              mapped ? "mapped" : "file",
              static_cast<unsigned>(nt->OptionalHeader.ImageBase),
              image.size, image.section_count);

  ap::LeafAnchorTrace trace;
  ap::DerivedAnchors anchors;
  const ap::LeafImageSource source = mapped
                                         ? ap::LeafImageSource::kRuntimeImage
                                         : ap::LeafImageSource::kPristineFile;
  std::printf("executable_code_looks_packed=%d\n",
              ap::LeafExecutableCodeLooksPacked(image) ? 1 : 0);
  const bool derived =
      ap::DeriveLeafAnchors(image, &anchors, &trace, source);
  std::printf("anchors: traversal=%u raster=%u poller=%u embed=%u device=%u "
              "cookie_agree=%d iat=%d embed_site_rejected=%d\n",
              trace.traversal_hits, trace.raster_hits, trace.poller_hits,
              trace.embed_hits, trace.device_hits, trace.cookie_agree ? 1 : 0,
              trace.iat_found ? 1 : 0,
              trace.embed_site_detoured_rejected ? 1 : 0);
  if (!derived) {
    std::printf("verdict=reject stage=anchors\n");
    return 1;
  }
  fushi_voice_hook::LeafAquaplusProfile profile;
  ap::LeafResolveTrace resolve_trace;
  const bool resolved =
      ap::ResolveLeafProfile(image, anchors, ap::kMeasuredLeafAnchorDeltas,
                             &profile, &resolve_trace);
  std::printf("sites:\n");
  PrintRva("stack_cookie", anchors.stack_cookie_rva);
  PrintRva("get_async_key_state_iat", anchors.get_async_key_state_iat_rva);
  PrintRva("read_file_iat", anchors.read_file_iat_rva);
  PrintRva("d3d9_device_pointer", anchors.d3d9_device_pointer_rva);
  PrintRva("text_traversal", anchors.text_traversal_rva);
  PrintRva("raster_draw", anchors.raster_draw_rva);
  PrintRva("embed_leaf_hook", anchors.embed_leaf_hook_rva);
  PrintRva("input_poller_first_return", anchors.input_poller_first_return_rva);
  if (!resolved) {
    std::printf("verdict=reject stage=return_sites failed_at=%s\n",
                ap::LeafResolveStageName(resolve_trace.failed_at));
    return 1;
  }
  PrintRva("input_poller_last_return", profile.input_poller_last_return_rva);
  PrintRva("glyph_dispatch", profile.glyph_dispatch_rva);
  PrintRva("raster_glyph_return", profile.raster_glyph_return_rva);
  PrintRva("glyph_single_return", profile.glyph_single_return_rva);
  PrintRva("glyph_double_first_return", profile.glyph_double_first_return_rva);
  PrintRva("glyph_double_second_return",
           profile.glyph_double_second_return_rva);
  PrintRva("quad_draw_return", profile.quad_draw_return_rva);
  PrintRva("alternate_quad_draw_return",
           profile.alternate_quad_draw_return_rva);
  PrintRva("voice_archive_read_return", profile.voice_archive_read_return_rva);
  if (!ap::LeafProfileSectionRolesValid(image, profile)) {
    std::printf("verdict=reject stage=section_roles\n");
    return 1;
  }
  // 与 hook 运行期走的同一个总入口复核一遍，防止探针和 hook 的判定悄悄分叉。
  fushi_voice_hook::LeafAquaplusProfile proven;
  if (!ap::ProveLeafStructure(image, source, &proven, nullptr) ||
      proven.glyph_single_return_rva != profile.glyph_single_return_rva ||
      proven.voice_archive_read_return_rva !=
          profile.voice_archive_read_return_rva) {
    std::printf("verdict=reject stage=prove_structure_mismatch\n");
    return 1;
  }
  const bool matches_measured =ap::DerivedAnchorsMatchProfile(
      anchors, fushi_voice_hook::kWhiteAlbum2LeafAquaplusProfile);
  std::printf("matches_measured_profile=%d\n", matches_measured ? 1 : 0);
  std::printf("verdict=admit\n");
  return 0;
}
