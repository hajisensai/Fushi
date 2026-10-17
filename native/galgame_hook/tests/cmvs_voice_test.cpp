// CMVS per-line voice core: group-loader site proof on synthetic x64 images
// (both toolchain shapes, every missing piece, chained fragments, overflow),
// plus voice-group / member-name classification.
//
// Optional: `fushi_cmvs_voice_test <cmvs64.exe>...` maps each file as an image
// and prints the resolved sites (local measurement only; CTest passes none).
#undef NDEBUG
#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>

#include "cmvs_voice_core.h"

namespace cv = fushi_voice_hook::cmvs_voice;

namespace {

using Bytes = std::vector<uint8_t>;

void Append(Bytes* out, std::initializer_list<uint8_t> bytes) {
  out->insert(out->end(), bytes.begin(), bytes.end());
}

// The pieces a group loader carries, in the two encodings the measured
// toolchains produce.  `drop` removes one piece (1..5) for negative cases.
Bytes LoaderBody(bool second_toolchain, int drop = 0) {
  Bytes code;
  Append(&code, {0x48, 0x89, 0x5c, 0x24, 0x20, 0x55, 0x56, 0x57});
  if (drop != 1) {
    // lea r13|r14, [rcx + 0x2020]
    Append(&code, {0x4c, 0x8d, static_cast<uint8_t>(second_toolchain ? 0xb1 : 0xa9),
                   0x20, 0x20, 0x00, 0x00});
  }
  Append(&code, {0x48, 0x8b, 0xd9});  // mov rbx, rcx
  if (drop != 2) {
    // cmp byte [rcx + rbx - 1], 0x5c
    Append(&code, {0x80, 0x7c, 0x19, 0xff, 0x5c});
  }
  if (drop != 3) {
    Append(&code, {0x48, 0x8b, 0x8b, 0x00, 0x08, 0x00, 0x00});  // mov rcx, [rbx+0x800]
  }
  Append(&code, {0x48, 0x8b, 0x01});  // mov rax, [rcx]
  if (drop != 4) {
    Append(&code, {0xff, 0x50, static_cast<uint8_t>(second_toolchain ? 0x18 : 0x20)});
  }
  if (drop != 5) {
    Append(&code, {0x48, 0x81, 0xc3, 0x08, 0x08, 0x00, 0x00});  // add rbx, 0x808
  }
  Append(&code, {0x83, 0xfe, 0x04, 0x5f, 0x5e, 0x5d, 0xc3});
  return code;
}

struct Fn {
  Bytes code;
  bool chained = false;
};

// Minimal mapped PE32+ image: headers at 0, code from 0x1000, unwind infos
// and the exception directory after the code.
Bytes BuildImage(const std::vector<Fn>& functions, WORD machine = IMAGE_FILE_MACHINE_AMD64) {
  Bytes image(0x1000, 0);
  auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(image.data());
  dos->e_magic = IMAGE_DOS_SIGNATURE;
  dos->e_lfanew = 0x80;
  std::vector<cv::X64RuntimeFunction> table;
  for (const Fn& fn : functions) {
    cv::X64RuntimeFunction entry = {};
    entry.begin = static_cast<uint32_t>(image.size());
    image.insert(image.end(), fn.code.begin(), fn.code.end());
    entry.end = static_cast<uint32_t>(image.size());
    while (image.size() % 16u != 0u) image.push_back(0xcc);
    table.push_back(entry);
  }
  for (size_t i = 0; i < functions.size(); ++i) {
    table[i].unwind = static_cast<uint32_t>(image.size());
    const uint8_t flags = functions[i].chained ? cv::kUnwindFlagChainInfo : 0u;
    Append(&image, {static_cast<uint8_t>(1u | (flags << 3)), 0, 0, 0});
  }
  const size_t table_rva = image.size();
  for (const cv::X64RuntimeFunction& entry : table) {
    const auto* raw = reinterpret_cast<const uint8_t*>(&entry);
    image.insert(image.end(), raw, raw + sizeof(entry));
  }
  image.resize(image.size() + 0x100u, 0);
  auto* nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(image.data() + 0x80);
  nt->Signature = IMAGE_NT_SIGNATURE;
  nt->FileHeader.Machine = machine;
  nt->OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR64_MAGIC;
  nt->OptionalHeader.NumberOfRvaAndSizes = IMAGE_NUMBEROF_DIRECTORY_ENTRIES;
  nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION] = {
      static_cast<DWORD>(table_rva),
      static_cast<DWORD>(table.size() * sizeof(cv::X64RuntimeFunction))};
  return image;
}

void TestBodies() {
  for (bool second : {false, true}) {
    const Bytes body = LoaderBody(second);
    assert(cv::IsGroupLoaderBody(body.data(), body.size()));
    for (int drop = 1; drop <= 5; ++drop) {
      const Bytes broken = LoaderBody(second, drop);
      assert(!cv::IsGroupLoaderBody(broken.data(), broken.size()));
    }
  }
  // The cache field off another register is a loader with another signature.
  Bytes other_base = LoaderBody(false);
  for (size_t i = 0; i + 3 < other_base.size(); ++i) {
    if (other_base[i] == 0x4c && other_base[i + 1] == 0x8d) {
      other_base[i + 2] = 0xab;  // lea r13, [rbx + 0x2020]
      break;
    }
  }
  assert(!cv::IsGroupLoaderBody(other_base.data(), other_base.size()));
  // [reg - 1] form of the trailing-backslash test is accepted too.
  Bytes reg_form = LoaderBody(true, 2);
  Append(&reg_form, {0x80, 0x78, 0xff, 0x5c});  // cmp byte [rax - 1], 0x5c
  assert(cv::IsGroupLoaderBody(reg_form.data(), reg_form.size()));
}

void TestSites() {
  {
    const Bytes image = BuildImage({{LoaderBody(false)},
                                    {LoaderBody(false, 1)},
                                    {LoaderBody(true)},
                                    {LoaderBody(true), /*chained=*/true}});
    cv::Sites sites;
    assert(cv::FindGroupLoaderSites(image.data(), image.size(), &sites) ==
           cv::SiteResult::kResolved);
    assert(sites.count == 2u);
    assert(sites.rva[0] == 0x1000u);
    assert(sites.rva[1] > sites.rva[0]);
  }
  {
    const Bytes image = BuildImage({{LoaderBody(false, 3)}});
    cv::Sites sites;
    assert(cv::FindGroupLoaderSites(image.data(), image.size(), &sites) ==
           cv::SiteResult::kNoSite);
    assert(sites.count == 0u);
  }
  {
    std::vector<Fn> many(cv::kMaxSites + 1u, Fn{LoaderBody(true)});
    const Bytes image = BuildImage(many);
    cv::Sites sites;
    assert(cv::FindGroupLoaderSites(image.data(), image.size(), &sites) ==
           cv::SiteResult::kTooManySites);
    assert(sites.count == 0u);
  }
  {
    const Bytes image = BuildImage({{LoaderBody(false)}}, IMAGE_FILE_MACHINE_I386);
    cv::Sites sites;
    assert(cv::FindGroupLoaderSites(image.data(), image.size(), &sites) ==
           cv::SiteResult::kNotPe64);
  }
  {
    Bytes image = BuildImage({{LoaderBody(false)}});
    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(image.data() + 0x80);
    nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION] = {};
    cv::Sites sites;
    assert(cv::FindGroupLoaderSites(image.data(), image.size(), &sites) ==
           cv::SiteResult::kNoExceptionDirectory);
  }
}

void TestClassification() {
  const char kPath[] = "C:\\Games\\x\\data\\pack\\voice.cpz";
  assert(cv::IsVoiceSlotPath(kPath, sizeof(kPath)));
  assert(cv::IsVoiceSlotPath("data\\pack\\VOICE2.CPZ", 64));
  assert(cv::IsVoiceSlotPath("data\\voice\\", 64));
  assert(cv::IsVoiceSlotPath("data/voice_ex/", 64));
  assert(!cv::IsVoiceSlotPath("data\\pack\\se.cpz", 64));
  assert(!cv::IsVoiceSlotPath("data\\music\\", 64));
  assert(!cv::IsVoiceSlotPath("data\\pack\\voice.ogg", 64));
  assert(!cv::IsVoiceSlotPath("data\\voicepack\\se.cpz", 64));
  assert(!cv::IsVoiceSlotPath("", 64));
  assert(!cv::IsVoiceSlotPath("voice.cpz", 9));  // unterminated within capacity

  std::vector<uint8_t> group(cv::kGroupBytes, 0);
  assert(!cv::IsVoiceGroup(group.data()));
  memcpy(group.data(), kPath, sizeof(kPath));
  assert(cv::IsVoiceGroup(group.data()));
  const char kLoose[] = "C:\\Games\\x\\data\\voice\\";
  memcpy(group.data() + cv::kSlotStride, kLoose, sizeof(kLoose));
  assert(cv::IsVoiceGroup(group.data()));
  const char kSe[] = "C:\\Games\\x\\data\\pack\\se.cpz";
  memcpy(group.data() + 2 * cv::kSlotStride, kSe, sizeof(kSe));
  assert(!cv::IsVoiceGroup(group.data()));
  std::vector<uint8_t> se_group(cv::kGroupBytes, 0);
  memcpy(se_group.data(), kSe, sizeof(kSe));
  assert(!cv::IsVoiceGroup(se_group.data()));

  assert(cv::IsVoiceMemberName("icsn101003.ogg", cv::kNameBytes));
  assert(cv::IsVoiceMemberName("ICSN101003.OGG", cv::kNameBytes));
  assert(!cv::IsVoiceMemberName(".ogg", cv::kNameBytes));
  assert(!cv::IsVoiceMemberName("icsn101003.wav", cv::kNameBytes));
  assert(!cv::IsVoiceMemberName("..\\icsn.ogg", cv::kNameBytes));
  assert(!cv::IsVoiceMemberName("a/b.ogg", cv::kNameBytes));
  assert(!cv::IsVoiceMemberName("c:x.ogg", cv::kNameBytes));
  assert(!cv::IsVoiceMemberName("ab\x01.ogg", cv::kNameBytes));

  const uint8_t ogg[] = {'O', 'g', 'g', 'S', 0, 2};
  const uint8_t riff[] = {'R', 'I', 'F', 'F', 0, 0};
  assert(cv::HasOggHead(ogg, sizeof(ogg)));
  assert(!cv::HasOggHead(riff, sizeof(riff)));
  assert(!cv::HasOggHead(ogg, 3));
}

void MeasureFile(const wchar_t* path) {
  HMODULE mapped = LoadLibraryExW(path, nullptr, LOAD_LIBRARY_AS_IMAGE_RESOURCE);
  if (mapped == nullptr) {
    wprintf(L"%ls: cannot map (%lu)\n", path, GetLastError());
    return;
  }
  // Image-resource handles carry flag bits in the low two bits.
  const auto* base = reinterpret_cast<const uint8_t*>(
      reinterpret_cast<uintptr_t>(mapped) & ~static_cast<uintptr_t>(3));
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(
      base + reinterpret_cast<const IMAGE_DOS_HEADER*>(base)->e_lfanew);
  cv::Sites sites;
  const cv::SiteResult result =
      cv::FindGroupLoaderSites(base, nt->OptionalHeader.SizeOfImage, &sites);
  wprintf(L"%ls: result=%u sites=", path, static_cast<unsigned>(result));
  for (size_t i = 0; i < sites.count; ++i) wprintf(L"+0x%x ", sites.rva[i]);
  wprintf(L"\n");
  FreeLibrary(mapped);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  TestBodies();
  TestSites();
  TestClassification();
  for (int i = 1; i < argc; ++i) MeasureFile(argv[i]);
  std::puts("cmvs voice core tests passed");
  return 0;
}
