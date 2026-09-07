// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

// smash/fzmedia 适配核心的离线测试：
//   * 锚点自推导：在一份**合成**的 PE64 映像（DOS/NT 头、节表、异常目录、导出/导入表）
//     里摆好 spec 列出的指令形状，要求整条链找回来；每个多义/缺失分支都 fail-closed；
//   * 段落装配（引号平衡合并两个 run、单空格等待光标、重排幂等）；
//   * 字格换行计算、Ogg 校验、语音类别过滤、文件命名、去重窗口、MSVC 释放形状。
// 夹具不含任何游戏内容。
#include <windows.h>

#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

#include "../hook/adapters/smash_fzmedia_anchors.h"
#include "../hook/adapters/smash_fzmedia_profile.h"

namespace {

namespace sf = fushi_voice_hook::smash_fzmedia;

constexpr uint64_t kImageBase = 0x140000000ull;
constexpr uint32_t kTextRva = 0x1000u;
constexpr uint32_t kTextSize = 0x3000u;
constexpr uint32_t kRdataRva = 0x4000u;
constexpr uint32_t kRdataSize = 0x2000u;
constexpr uint32_t kPdataRva = 0x6000u;
constexpr uint32_t kPdataSize = 0x1000u;
constexpr uint32_t kImageSize = 0x7000u;

constexpr uint32_t kTdRva = 0x4100u;
constexpr uint32_t kColRva = 0x4200u;
constexpr uint32_t kChdRva = 0x4300u;
constexpr uint32_t kVtableSlotRva = 0x4400u;  // 指向 COL 的指针
constexpr uint32_t kVtableRva = kVtableSlotRva + 8u;
constexpr uint32_t kUnwindPlainRva = 0x4500u;
constexpr uint32_t kUnwindChainRva = 0x4510u;
constexpr uint32_t kExportDirRva = 0x4800u;
constexpr uint32_t kImportDirRva = 0x4C00u;

constexpr uint32_t kCtorRva = 0x1100u;
constexpr uint32_t kMeshBuildRva = 0x1200u;
constexpr uint32_t kLayoutRva = 0x1400u;
constexpr uint32_t kLayoutFragmentRva = 0x1480u;
constexpr uint32_t kDecoyFewCallsRva = 0x1800u;
constexpr uint32_t kDecoyIndexRva = 0x1900u;
constexpr uint32_t kSpareRva = 0x1A00u;

constexpr uint8_t kTextBegin = 0x48u;
constexpr uint8_t kTextEnd = 0x50u;
constexpr uint8_t kCursorX = 0x4Cu;
constexpr uint8_t kCursorY = 0x50u;
constexpr uint8_t kLinePitch = 0x38u;
constexpr uint8_t kFontPx = 0x30u;
constexpr uint8_t kScale = 0x40u;

class SyntheticImage {
 public:
  SyntheticImage() : bytes_(kImageSize, 0u) {
    auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(bytes_.data());
    dos->e_magic = IMAGE_DOS_SIGNATURE;
    dos->e_lfanew = 0x80;
    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(bytes_.data() + 0x80);
    nt->Signature = IMAGE_NT_SIGNATURE;
    nt->FileHeader.Machine = IMAGE_FILE_MACHINE_AMD64;
    nt->FileHeader.NumberOfSections = 3;
    nt->FileHeader.SizeOfOptionalHeader = sizeof(IMAGE_OPTIONAL_HEADER64);
    nt->OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR64_MAGIC;
    nt->OptionalHeader.ImageBase = kImageBase;
    nt->OptionalHeader.SectionAlignment = 0x1000u;
    nt->OptionalHeader.FileAlignment = 0x200u;
    nt->OptionalHeader.SizeOfImage = kImageSize;
    nt->OptionalHeader.SizeOfHeaders = 0x1000u;
    nt->OptionalHeader.NumberOfRvaAndSizes = IMAGE_NUMBEROF_DIRECTORY_ENTRIES;
    IMAGE_SECTION_HEADER* section = IMAGE_FIRST_SECTION(nt);
    std::memcpy(section[0].Name, ".text", 5);
    section[0].VirtualAddress = kTextRva;
    section[0].Misc.VirtualSize = kTextSize;
    section[0].SizeOfRawData = kTextSize;
    section[0].Characteristics =
        IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ | IMAGE_SCN_CNT_CODE;
    std::memcpy(section[1].Name, ".rdata", 6);
    section[1].VirtualAddress = kRdataRva;
    section[1].Misc.VirtualSize = kRdataSize;
    section[1].SizeOfRawData = kRdataSize;
    section[1].Characteristics = IMAGE_SCN_MEM_READ | IMAGE_SCN_CNT_INITIALIZED_DATA;
    std::memcpy(section[2].Name, ".pdata", 6);
    section[2].VirtualAddress = kPdataRva;
    section[2].Misc.VirtualSize = kPdataSize;
    section[2].SizeOfRawData = kPdataSize;
    section[2].Characteristics = IMAGE_SCN_MEM_READ | IMAGE_SCN_CNT_INITIALIZED_DATA;
    nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION]
        .VirtualAddress = kPdataRva;
  }

  IMAGE_NT_HEADERS64* nt() {
    return reinterpret_cast<IMAGE_NT_HEADERS64*>(bytes_.data() + 0x80);
  }
  uint8_t* at(uint32_t rva) { return bytes_.data() + rva; }
  const uint8_t* data() const { return bytes_.data(); }

  void Put(uint32_t rva, const void* bytes, size_t size) {
    std::memcpy(at(rva), bytes, size);
  }
  void PutU32(uint32_t rva, uint32_t value) { Put(rva, &value, sizeof(value)); }
  void PutU64(uint32_t rva, uint64_t value) { Put(rva, &value, sizeof(value)); }
  void PutStr(uint32_t rva, const char* text) {
    Put(rva, text, std::strlen(text) + 1u);
  }

  // E8 rel32 → target；返回下一条指令 rva。
  uint32_t Call(uint32_t rva, uint32_t target) {
    at(rva)[0] = 0xE8u;
    const int32_t rel = static_cast<int32_t>(target) - static_cast<int32_t>(rva + 5u);
    Put(rva + 1u, &rel, sizeof(rel));
    return rva + 5u;
  }
  uint32_t Bytes(uint32_t rva, std::initializer_list<uint8_t> list) {
    size_t i = 0u;
    for (uint8_t b : list) at(rva)[i++] = b;
    return rva + static_cast<uint32_t>(list.size());
  }

  void AddRuntimeEntry(uint32_t begin, uint32_t end, uint32_t unwind) {
    const uint32_t rva = kPdataRva + runtime_entries_ * 12u;
    PutU32(rva, begin);
    PutU32(rva + 4u, end);
    PutU32(rva + 8u, unwind);
    ++runtime_entries_;
    nt()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION].Size =
        runtime_entries_ * 12u;
  }

  // 标准布局：RTTI、ctor、网格构建（7 次调 ctor）、layoutChar（两片段，链式）、两个诱饵。
  void BuildStandard() {
    // RTTI
    PutStr(kTdRva + 16u, ".?AVGlyphComponentMesh@krkrz@app@fate@@");
    const uint32_t col[6] = {1u, 0u, 0u, kTdRva, kChdRva, kColRva};
    Put(kColRva, col, sizeof(col));
    PutU32(kChdRva, 0u);
    PutU64(kVtableSlotRva, kImageBase + kColRva);
    PutU64(kVtableRva, kImageBase + kSpareRva);  // vtable[0] → 可执行节
    PutU64(kVtableRva + 8u, kImageBase + kSpareRva);
    // unwind info：普通 / 链式（父 = layoutChar 根片段）
    Bytes(kUnwindPlainRva, {0x01, 0x00, 0x00, 0x00});
    Bytes(kUnwindChainRva, {static_cast<uint8_t>(0x01u | (sf::kUnwFlagChainInfo << 3u)),
                            0x00, 0x00, 0x00});
    PutU32(kUnwindChainRva + 4u, kLayoutRva);
    PutU32(kUnwindChainRva + 8u, kLayoutRva + 0x60u);
    PutU32(kUnwindChainRva + 12u, kUnwindPlainRva);
    // ctor: lea rax,[rip+vtable]; mov [rsi],rax; ret
    {
      uint32_t p = kCtorRva;
      at(p)[0] = 0x48u; at(p)[1] = 0x8Du; at(p)[2] = 0x05u;
      const int32_t rel =
          static_cast<int32_t>(kVtableRva) - static_cast<int32_t>(p + 7u);
      Put(p + 3u, &rel, sizeof(rel));
      p = Bytes(p + 7u, {0x48, 0x89, 0x06, 0xC3});
      AddRuntimeEntry(kCtorRva, p, kUnwindPlainRva);
    }
    // mesh build: 7 × call ctor; ret
    {
      uint32_t p = kMeshBuildRva;
      for (int i = 0; i < 7; ++i) p = Call(p, kCtorRva);
      p = Bytes(p, {0xC3});
      AddRuntimeEntry(kMeshBuildRva, p, kUnwindPlainRva);
    }
    // layoutChar 根片段
    {
      uint32_t p = kLayoutRva;
      p = Bytes(p, {0x48, 0x8B, 0x42, kTextBegin, 0x46, 0x0F, 0xB7, 0x14, 0x40});
      p = Call(p, kMeshBuildRva);
      p = Bytes(p, {0x49, 0x8B, 0x47, kTextEnd, 0x49, 0x2B, 0x47, kTextBegin,
                    0x48, 0xD1, 0xF8});
      p = Bytes(p, {0xF3, 0x0F, 0x58, 0x7F, kCursorX, 0xF3, 0x0F, 0x11, 0x7F,
                    kCursorX});
      p = Bytes(p, {0xF3, 0x0F, 0x10, 0x77, 0x3C});  // 诱饵：另一处 movss xmm6
      p = Bytes(p, {0xF3, 0x0F, 0x10, 0x77, kCursorY});
      cursor_y_hit_rva_ = p - 5u;
      p = Bytes(p, {0xF3, 0x0F, 0x10, 0x47, 0x24});  // 诱饵：movss xmm0 其它字段
      p = Bytes(p, {0xC3});
      AddRuntimeEntry(kLayoutRva, kLayoutRva + 0x60u, kUnwindPlainRva);
    }
    // layoutChar 链式片段（line_pitch / font / scale 在这里）
    {
      uint32_t p = kLayoutFragmentRva;
      p = Bytes(p, {0x66, 0x0F, 0x6E, 0x47, kLinePitch});
      p = Bytes(p, {0xF3, 0x44, 0x0F, 0x59, 0x47, kFontPx});
      p = Bytes(p, {0xF3, 0x0F, 0x10, 0x47, kScale});
      p = Bytes(p, {0xF3, 0x0F, 0x59, 0x47, kScale});
      p = Bytes(p, {0xC3});
      AddRuntimeEntry(kLayoutFragmentRva, p, kUnwindChainRva);
    }
    // 诱饵 1：只调 ctor 3 次
    {
      uint32_t p = kDecoyFewCallsRva;
      for (int i = 0; i < 3; ++i) p = Call(p, kCtorRva);
      p = Bytes(p, {0xC3});
      AddRuntimeEntry(kDecoyFewCallsRva, p, kUnwindPlainRva);
    }
    // 诱饵 2：含 text-index 模式但不调网格构建
    {
      uint32_t p = kDecoyIndexRva;
      p = Bytes(p, {0x48, 0x8B, 0x42, 0x10, 0x46, 0x0F, 0xB7, 0x14, 0x40, 0xC3});
      AddRuntimeEntry(kDecoyIndexRva, p, kUnwindPlainRva);
    }
    // 备用函数（vtable[0] 目标）
    {
      const uint32_t p = Bytes(kSpareRva, {0xC3});
      AddRuntimeEntry(kSpareRva, p, kUnwindPlainRva);
    }
  }

  void BuildExports() {
    IMAGE_EXPORT_DIRECTORY dir = {};
    dir.NumberOfFunctions = 3u;
    dir.NumberOfNames = 3u;
    dir.AddressOfFunctions = kExportDirRva + 0x100u;
    dir.AddressOfNames = kExportDirRva + 0x120u;
    dir.AddressOfNameOrdinals = kExportDirRva + 0x140u;
    Put(kExportDirRva, &dir, sizeof(dir));
    const uint32_t functions[3] = {kCtorRva, kMeshBuildRva, kLayoutRva};
    Put(dir.AddressOfFunctions, functions, sizeof(functions));
    const uint32_t names[3] = {kExportDirRva + 0x200u, kExportDirRva + 0x300u,
                               kExportDirRva + 0x380u};
    Put(dir.AddressOfNames, names, sizeof(names));
    const uint16_t ordinals[3] = {0u, 1u, 2u};
    Put(dir.AddressOfNameOrdinals, ordinals, sizeof(ordinals));
    PutStr(names[0],
           "?create@SoundManager@sound@fz@@QEAA?AV?$shared_ptr@VSoundObject@sound@fz@@@std@@AEBVSoundResourceId@23@W4SoundCategory@23@@Z");
    PutStr(names[1], "?play@SoundObject@sound@fz@@QEAAXAEBVSoundPlayInfo@23@@Z");
    PutStr(names[2], "?isReady@SoundObject@sound@fz@@QEBA_NXZ");
    nt()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress =
        kExportDirRva;
    nt()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].Size = 0x400u;
  }

  void BuildImports() {
    const uint32_t engine_name = kImportDirRva + 0x80u;
    const uint32_t crt_name = kImportDirRva + 0xC0u;
    const uint32_t engine_lookup = kImportDirRva + 0x100u;
    const uint32_t crt_lookup = kImportDirRva + 0x120u;
    const uint32_t engine_symbol = kImportDirRva + 0x140u;
    const uint32_t crt_symbol = kImportDirRva + 0x1C0u;
    const uint32_t engine_iat = kImportDirRva + 0x200u;
    const uint32_t crt_iat = kImportDirRva + 0x220u;
    PutStr(engine_name, "null-ge-win64vc14-release-dynamic.dll");
    PutStr(crt_name, "MSVCP140.dll");
    PutStr(engine_symbol + 2u,
           "?bindGameEngine_sample@@YAPEAVIGameEngine@fw@smash@@XZ");
    PutStr(crt_symbol + 2u, "??3@YAXPEAX@Z");
    PutU64(engine_lookup, engine_symbol);
    PutU64(engine_lookup + 8u, 0u);
    PutU64(crt_lookup, crt_symbol);
    PutU64(crt_lookup + 8u, 0u);
    IMAGE_IMPORT_DESCRIPTOR desc[3] = {};
    desc[0].OriginalFirstThunk = engine_lookup;
    desc[0].Name = engine_name;
    desc[0].FirstThunk = engine_iat;
    desc[1].OriginalFirstThunk = crt_lookup;
    desc[1].Name = crt_name;
    desc[1].FirstThunk = crt_iat;
    Put(kImportDirRva, desc, sizeof(desc));
    nt()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress =
        kImportDirRva;
    nt()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].Size =
        sizeof(desc);
    crt_iat_rva_ = crt_iat;
  }

  bool Open(sf::ImageView* view) const {
    return sf::OpenImageView(bytes_.data(), 0u, view);
  }

  uint32_t crt_iat_rva() const { return crt_iat_rva_; }
  uint32_t cursor_y_hit_rva() const { return cursor_y_hit_rva_; }

 private:
  std::vector<uint8_t> bytes_;
  uint32_t runtime_entries_ = 0u;
  uint32_t crt_iat_rva_ = 0u;
  uint32_t cursor_y_hit_rva_ = 0u;
};

void TestImageViewRejectsNonPe() {
  std::vector<uint8_t> junk(0x2000u, 0u);
  sf::ImageView view;
  assert(!sf::OpenImageView(junk.data(), 0u, &view));
  assert(!sf::OpenImageView(nullptr, 0u, &view));
}

void TestAnchorDerivationSucceedsOnStandardImage() {
  SyntheticImage image;
  image.BuildStandard();
  sf::ImageView view;
  assert(image.Open(&view));
  assert(view.absolute_base == kImageBase);
  assert(view.section_count == 3u);
  assert(view.IsExecutable(kCtorRva, 4u));
  assert(!view.IsExecutable(kTdRva, 4u));
  assert(view.IsData(kTdRva, 4u));

  // 函数边界：链式片段归到根函数。
  assert(sf::FindContainingFunctionBegin(view, kLayoutRva + 5u) == kLayoutRva);
  assert(sf::FindContainingFunctionBegin(view, kLayoutFragmentRva + 3u) ==
         kLayoutRva);
  assert(sf::FindContainingFunctionBegin(view, kMeshBuildRva + 9u) ==
         kMeshBuildRva);
  assert(sf::FindContainingFunctionBegin(view, 0x1FF0u) == 0u);
  assert(sf::CountRel32CallsInFunction(view, kMeshBuildRva, kCtorRva) == 7u);
  assert(sf::CountRel32CallsInFunction(view, kDecoyFewCallsRva, kCtorRva) == 3u);
  assert(sf::CountRel32CallsInFunction(view, kLayoutRva, kMeshBuildRva) == 1u);

  const sf::TextAnchorResult result = sf::DeriveTextAnchors(view);
  assert(result.ok);
  assert(result.failed_stage == sf::TextAnchorStage::kResolved);
  const sf::TextAnchors& a = result.anchors;
  assert(a.type_descriptor_rva == kTdRva);
  assert(a.complete_object_locator_rva == kColRva);
  assert(a.vtable_rva == kVtableRva);
  assert(a.ctor_rva == kCtorRva);
  assert(a.mesh_build_rva == kMeshBuildRva);
  assert(a.mesh_build_ctor_calls == 7u);
  assert(a.layout_char_rva == kLayoutRva);
  assert(a.text_begin == kTextBegin);
  assert(a.text_end == kTextEnd);
  assert(a.cursor_x == kCursorX);
  assert(a.cursor_y == kCursorY);
  assert(a.line_pitch == kLinePitch);
  assert(a.font_px == kFontPx);
  assert(a.scale == kScale);
  assert(std::strcmp(sf::TextAnchorStageName(result.failed_stage), "resolved") == 0);
}

void TestAnchorDerivationFailsClosedOnDuplicateTypeDescriptor() {
  SyntheticImage image;
  image.BuildStandard();
  image.PutStr(0x4700u + 16u, ".?AVGlyphComponentMesh@krkrz@app@tsuki@@");
  sf::ImageView view;
  assert(image.Open(&view));
  const sf::TextAnchorResult result = sf::DeriveTextAnchors(view);
  assert(!result.ok);
  assert(result.failed_stage == sf::TextAnchorStage::kTypeDescriptor);
}

void TestAnchorDerivationFailsClosedOnMissingTypeDescriptor() {
  SyntheticImage image;
  image.BuildStandard();
  image.PutStr(kTdRva + 16u, ".?AVSomethingElse@krkrz@app@fate@@");
  sf::ImageView view;
  assert(image.Open(&view));
  const sf::TextAnchorResult result = sf::DeriveTextAnchors(view);
  assert(!result.ok);
  assert(result.failed_stage == sf::TextAnchorStage::kTypeDescriptor);
}

void TestAnchorDerivationFailsClosedOnAmbiguousVtable() {
  SyntheticImage image;
  image.BuildStandard();
  image.PutU64(0x4600u, kImageBase + kColRva);  // 第二个指向 COL 的槽
  sf::ImageView view;
  assert(image.Open(&view));
  const sf::TextAnchorResult result = sf::DeriveTextAnchors(view);
  assert(!result.ok);
  assert(result.failed_stage == sf::TextAnchorStage::kVtable);
}

void TestAnchorDerivationFailsClosedOnSecondMeshBuilder() {
  SyntheticImage image;
  image.BuildStandard();
  // 另一个函数也直调 ctor 5 次 → 网格构建函数多义。
  uint32_t p = 0x1B00u;
  for (int i = 0; i < 5; ++i) p = image.Call(p, kCtorRva);
  p = image.Bytes(p, {0xC3});
  image.AddRuntimeEntry(0x1B00u, p, kUnwindPlainRva);
  sf::ImageView view;
  assert(image.Open(&view));
  const sf::TextAnchorResult result = sf::DeriveTextAnchors(view);
  assert(!result.ok);
  assert(result.failed_stage == sf::TextAnchorStage::kMeshBuild);
}

void TestAnchorDerivationFailsClosedOnSecondLayoutCandidate() {
  SyntheticImage image;
  image.BuildStandard();
  // 另一个函数同时含 text-index 模式且直调网格构建 1 次。
  uint32_t p = 0x1C00u;
  p = image.Bytes(p, {0x48, 0x8B, 0x42, 0x48, 0x46, 0x0F, 0xB7, 0x14, 0x40});
  p = image.Call(p, kMeshBuildRva);
  p = image.Bytes(p, {0xC3});
  image.AddRuntimeEntry(0x1C00u, p, kUnwindPlainRva);
  sf::ImageView view;
  assert(image.Open(&view));
  const sf::TextAnchorResult result = sf::DeriveTextAnchors(view);
  assert(!result.ok);
  assert(result.failed_stage == sf::TextAnchorStage::kLayoutChar);
}

void TestAnchorDerivationFailsClosedOnCursorStoreMismatch() {
  SyntheticImage image;
  image.BuildStandard();
  // addss 与 movss 的位移不一致：把 movss [rdi+d] 的 d 改掉。
  const uint8_t bad[] = {0xF3, 0x0F, 0x58, 0x7F, kCursorX,
                         0xF3, 0x0F, 0x11, 0x7F, 0x4D};
  // 定位根片段里的 cursor 模式：index(9) + call(5) + len(11) = 25。
  image.Put(kLayoutRva + 25u, bad, sizeof(bad));
  sf::ImageView view;
  assert(image.Open(&view));
  const sf::TextAnchorResult result = sf::DeriveTextAnchors(view);
  assert(!result.ok);
  assert(result.failed_stage == sf::TextAnchorStage::kCursorOffsets);
}

void TestAnchorDerivationFailsClosedOnTextLengthShape() {
  SyntheticImage image;
  image.BuildStandard();
  // sub 的 b 不等于 text_begin。
  image.at(kLayoutRva + 14u + 7u)[0] = 0x40u;
  sf::ImageView view;
  assert(image.Open(&view));
  const sf::TextAnchorResult result = sf::DeriveTextAnchors(view);
  assert(!result.ok);
  assert(result.failed_stage == sf::TextAnchorStage::kTextOffsets);
}

void TestAnchorDerivationRequiresChainedFragmentMembership() {
  SyntheticImage image;
  image.BuildStandard();
  // 把第二片段改成独立根函数：line_pitch/font/scale 不再属于 layoutChar。
  image.PutU32(kPdataRva + 3u * 12u + 8u, kUnwindPlainRva);
  sf::ImageView view;
  assert(image.Open(&view));
  assert(sf::FindContainingFunctionBegin(view, kLayoutFragmentRva + 3u) ==
         kLayoutFragmentRva);
  const sf::TextAnchorResult result = sf::DeriveTextAnchors(view);
  assert(!result.ok);
  assert(result.failed_stage == sf::TextAnchorStage::kCursorOffsets);
}

void TestAnchorDerivationFailsClosedOnScaleMismatch() {
  SyntheticImage image;
  image.BuildStandard();
  // mulss xmm0,[rdi+d] 的 d 与 movss xmm0,[rdi+d] 不同。
  image.at(kLayoutFragmentRva + 5u + 6u + 5u + 4u)[0] = 0x44u;
  sf::ImageView view;
  assert(image.Open(&view));
  const sf::TextAnchorResult result = sf::DeriveTextAnchors(view);
  assert(!result.ok);
  assert(result.failed_stage == sf::TextAnchorStage::kFontOffsets);
}

void TestAnchorDerivationRejectsImageWithoutExceptionDirectory() {
  SyntheticImage image;
  image.BuildStandard();
  image.nt()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION].Size = 0u;
  sf::ImageView view;
  assert(image.Open(&view));
  const sf::TextAnchorResult result = sf::DeriveTextAnchors(view);
  assert(!result.ok);
  assert(result.failed_stage == sf::TextAnchorStage::kImage);
}

void TestExportTableResolution() {
  SyntheticImage image;
  image.BuildStandard();
  image.BuildExports();
  sf::ImageView view;
  assert(image.Open(&view));
  const sf::ExportMatch create =
      sf::FindExportByPrefix(view, sf::kExportSoundManagerCreate);
  assert(create.count == 1u && create.rva == kCtorRva);
  const sf::ExportMatch play = sf::FindExportByPrefix(view, sf::kExportSoundObjectPlay);
  assert(play.count == 1u && play.rva == kMeshBuildRva);
  const sf::ExportMatch ready =
      sf::FindExportByPrefix(view, sf::kExportSoundObjectIsReady);
  assert(ready.count == 1u && ready.rva == kLayoutRva);
  assert(sf::HasExportWithPrefix(view, "?play@SoundObject"));
  assert(!sf::HasExportWithPrefix(view, sf::kExportSoundObjectConvertToRawFile));
  const sf::ExportMatch ambiguous = sf::FindExportByPrefix(view, "?");
  assert(ambiguous.count == 2u && ambiguous.rva == 0u);
  assert(sf::FindExportByPrefix(view, "").count == 0u);
  assert(sf::FindExportByPrefix(view, nullptr).count == 0u);
}

void TestImportTableResolution() {
  SyntheticImage image;
  image.BuildStandard();
  image.BuildImports();
  sf::ImageView view;
  assert(image.Open(&view));
  assert(sf::ImportsSymbolFromDll(view, sf::kGameEngineDllPrefix,
                                  sf::kGameEngineImportSubstring));
  assert(sf::ImportsSymbolFromDll(view, "NULL-GE-", sf::kGameEngineImportSubstring));
  assert(!sf::ImportsSymbolFromDll(view, "fzmedia-", sf::kGameEngineImportSubstring));
  assert(!sf::ImportsSymbolFromDll(view, sf::kGameEngineDllPrefix,
                                   "IGameEngine@fw@other@@"));
  assert(sf::FindImportThunkRva(view, nullptr, sf::kImportOperatorDelete) ==
         image.crt_iat_rva());
  assert(sf::FindImportThunkRva(view, "msvcp140", sf::kImportOperatorDelete) ==
         image.crt_iat_rva());
  assert(sf::FindImportThunkRva(view, "null-ge-", sf::kImportOperatorDelete) == 0u);
  assert(sf::FindImportThunkRva(view, nullptr, sf::kImportOperatorDeleteSized) == 0u);
}

void TestModuleNameFilter() {
  using fushi_voice_hook::MatchesSmashFzmediaProfile;
  assert(!MatchesSmashFzmediaProfile(nullptr));
  assert(MatchesSmashFzmediaProfile(L"fzmedia-win64vc14-release-dynamic.dll"));
  assert(MatchesSmashFzmediaProfile(L"NULL-GE-win64vc14-release-dynamic.dll"));
  assert(!MatchesSmashFzmediaProfile(L"nvoglv64.dll"));
  assert(!MatchesSmashFzmediaProfile(L"fzmedi.dll"));
}

void TestVoicePayloadValidation() {
  const uint8_t ogg[] = {'O', 'g', 'g', 'S', 0, 2, 0, 0};
  assert(sf::ValidateOggPayload(ogg, sizeof(ogg)));
  assert(!sf::ValidateOggPayload(ogg, 3u));
  assert(!sf::ValidateOggPayload(nullptr, 8u));
  assert(!sf::ValidateOggPayload(ogg, sf::kVoiceSlotBytes + 1u));
  const uint8_t fcd[] = {'F', 'C', 'D', 0, 0, 1, 0, 0};
  assert(!sf::ValidateOggPayload(fcd, sizeof(fcd)));
  assert(sf::IsVoiceCategory(5));
  assert(!sf::IsVoiceCategory(1));
  assert(!sf::IsVoiceCategory(4));
  assert(!sf::IsVoiceCategory(6));
}

void TestVoiceStorageName() {
  wchar_t out[64] = {};
  assert(sf::BuildVoiceStorageName("sav0613_shi_0010.fcd", out, 64u));
  assert(std::wcscmp(out, L"sav0613_shi_0010.ogg") == 0);
  assert(sf::BuildVoiceStorageName("voice/sav0613_ise_0020.FCD", out, 64u));
  assert(std::wcscmp(out, L"sav0613_ise_0020.ogg") == 0);
  assert(sf::BuildVoiceStorageName("bare", out, 64u));
  assert(std::wcscmp(out, L"bare.ogg") == 0);
  assert(sf::BuildVoiceStorageName("we:ird\xE3\x81\x82.fcd", out, 64u));
  assert(std::wcscmp(out, L"we_ird___.ogg") == 0);
  assert(!sf::BuildVoiceStorageName(".fcd", out, 64u));
  assert(!sf::BuildVoiceStorageName("", out, 64u));
  assert(!sf::BuildVoiceStorageName(nullptr, out, 64u));
  assert(!sf::BuildVoiceStorageName("sav0613_shi_0010.fcd", out, 8u));
}

void TestMsvcStdStringLocate() {
  uint8_t repr[32] = {};
  std::memcpy(repr, "sav0613.fcd", 11u);
  uint64_t size = 11u;
  uint64_t capacity = 15u;
  std::memcpy(repr + 16u, &size, 8u);
  std::memcpy(repr + 24u, &capacity, 8u);
  const char* data = nullptr;
  size_t len = 0u;
  assert(sf::LocateMsvcStdString(repr, &data, &len));
  assert(data == reinterpret_cast<const char*>(repr) && len == 11u);

  const char heap[] = "voice/sav0613_shi_0010_long_name.fcd";
  const uint64_t pointer = reinterpret_cast<uintptr_t>(heap);
  std::memcpy(repr, &pointer, 8u);
  size = sizeof(heap) - 1u;
  capacity = 47u;
  std::memcpy(repr + 16u, &size, 8u);
  std::memcpy(repr + 24u, &capacity, 8u);
  assert(sf::LocateMsvcStdString(repr, &data, &len));
  assert(data == heap && len == sizeof(heap) - 1u);

  size = 100u;  // size > capacity → 结构不可信
  std::memcpy(repr + 16u, &size, 8u);
  assert(!sf::LocateMsvcStdString(repr, &data, &len));
}

void TestMsvcVectorDeallocationShape() {
  // 小块：直接释放 begin。
  assert(sf::ResolveMsvcVectorDeallocationPointer(0x1000u, 512u, 0u) == 0x1000u);
  // 大块：容器指针在 begin 前 16..47 字节。
  assert(sf::ResolveMsvcVectorDeallocationPointer(0x10020u, 8192u, 0x10000u) ==
         0x10000u);
  assert(sf::ResolveMsvcVectorDeallocationPointer(0x10010u, 8192u, 0x10000u) ==
         0x10000u);
  assert(sf::ResolveMsvcVectorDeallocationPointer(0x1002Fu, 8192u, 0x10000u) ==
         0x10000u);
  // 形状不对 → 0（泄漏而不是破坏堆）。
  assert(sf::ResolveMsvcVectorDeallocationPointer(0x10008u, 8192u, 0x10000u) == 0u);
  assert(sf::ResolveMsvcVectorDeallocationPointer(0x10040u, 8192u, 0x10000u) == 0u);
  assert(sf::ResolveMsvcVectorDeallocationPointer(0x10020u, 8192u, 0u) == 0u);
  assert(sf::ResolveMsvcVectorDeallocationPointer(0x10020u, 8192u, 0x20000u) == 0u);
  assert(sf::ResolveMsvcVectorDeallocationPointer(0u, 8192u, 0u) == 0u);
}

void TestDedupeWindows() {
  assert(sf::WithinDedupeWindow(1000u, 1500u, sf::kTextDedupeWindowMs));
  assert(sf::WithinDedupeWindow(1000u, 2000u, sf::kTextDedupeWindowMs));
  assert(!sf::WithinDedupeWindow(1000u, 2001u, sf::kTextDedupeWindowMs));
  assert(!sf::WithinDedupeWindow(0u, 500u, sf::kTextDedupeWindowMs));
  assert(!sf::WithinDedupeWindow(2000u, 1000u, sf::kTextDedupeWindowMs));
  assert(sf::WithinDedupeWindow(5000u, 7000u, sf::kVoiceDedupeWindowMs));
  assert(!sf::WithinDedupeWindow(5000u, 7001u, sf::kVoiceDedupeWindowMs));
  assert(sf::SameVoiceId("a.fcd", "a.fcd"));
  assert(!sf::SameVoiceId("a.fcd", "b.fcd"));
  assert(!sf::SameVoiceId(nullptr, "b.fcd"));
  assert(sf::SameText(L"ab", 2u, L"ab", 2u));
  assert(!sf::SameText(L"ab", 2u, L"ac", 2u));
  assert(!sf::SameText(L"ab", 2u, L"ab", 1u));
  assert(sf::PartialPublishDue(1000u, 3500u));
  assert(!sf::PartialPublishDue(1000u, 3499u));
  assert(!sf::PartialPublishDue(0u, 9999u));
}

void TestGlyphCellComputation() {
  // 普通字：从 x0 走到 x1。
  sf::GlyphCell cell = sf::ComputeGlyphCell(100.0f, 200.0f, 147.52f, 200.0f, 44.0f,
                                            1.0f, L'あ');
  assert(cell.x == 100.0f && cell.y == 200.0f && cell.h == 44.0f && cell.inked);
  assert(cell.w > 47.5f && cell.w < 47.6f);
  // 自动换行：x1 < x0，该字占新行 [0, x1)。
  cell = sf::ComputeGlyphCell(1800.0f, 200.0f, 47.52f, 273.0f, 44.0f, 1.0f, L'い');
  assert(cell.x == 0.0f && cell.y == 273.0f && cell.h == 44.0f);
  assert(cell.w > 47.5f && cell.w < 47.6f);
  // scale 生效；空格无墨。
  cell = sf::ComputeGlyphCell(0.0f, 0.0f, 20.0f, 0.0f, 44.0f, 0.5f, L' ');
  assert(cell.h == 22.0f && !cell.inked);
  cell = sf::ComputeGlyphCell(0.0f, 0.0f, 20.0f, 0.0f, 44.0f, 0.0f, 0x3000);
  assert(cell.h == 44.0f && !cell.inked);
}

void TestParagraphAssemblerMergesQuoteBalancedRuns() {
  sf::ParagraphAssembler assembler;
  int layer_a = 0;
  // spec 的实测样例：先 「…。 再续行 …」，同一段落。
  const wchar_t first[] = L"「ふん。なんとなくで授業を休まれては、教師は商売あがったりだ。";
  const wchar_t second[] = L"で。何故お山なんぞを拝んでおったのかと訊いているのだが」";
  const uint32_t first_units = static_cast<uint32_t>(std::wcslen(first));
  const uint32_t second_units = static_cast<uint32_t>(std::wcslen(second));

  assert(assembler.BeginRun(&layer_a, first, first_units, 10000u, 44.0f, 73.0f));
  assert(assembler.line.unit_count == first_units);
  assert(assembler.line.first_tick_ms == 10000u);
  for (uint32_t i = 0u; i < first_units; ++i) {
    assembler.AppendCell(i, sf::ComputeGlyphCell(i * 47.52f, 0.0f,
                                                 (i + 1) * 47.52f, 0.0f, 44.0f,
                                                 1.0f, first[i]));
  }
  assert(assembler.EndRun(10500u));
  assert(!assembler.line.complete);  // 「 未闭合
  assert(assembler.post_seq == 1u);

  // 单空格等待光标：忽略，不影响段落状态。
  assert(!assembler.BeginRun(&layer_a, L" ", 1u, 10600u, 44.0f, 73.0f));
  assert(!assembler.run_active);
  assert(!assembler.EndRun(10601u));

  // 1080ms 后的续行：拼接，不加分隔，first_tick 保持。
  assert(assembler.BeginRun(&layer_a, second, second_units, 11580u, 44.0f, 73.0f));
  assert(assembler.line.unit_count == first_units + second_units);
  assert(assembler.line.first_tick_ms == 10000u);
  assert(std::memcmp(assembler.line.text, first, first_units * sizeof(wchar_t)) == 0);
  assert(std::memcmp(assembler.line.text + first_units, second,
                     second_units * sizeof(wchar_t)) == 0);
  for (uint32_t i = 0u; i < second_units; ++i) {
    assembler.AppendCell(i, sf::ComputeGlyphCell(i * 47.52f, 73.0f,
                                                 (i + 1) * 47.52f, 73.0f, 44.0f,
                                                 1.0f, second[i]));
  }
  assert(assembler.EndRun(12000u));
  assert(assembler.line.complete);
  assert(assembler.post_seq == 2u);
  // 续行的字格索引 = 段落内下标，并保持第一 run 的字格。
  assert(assembler.line.cells[0].x == 0.0f && assembler.line.cells[0].y == 0.0f);
  assert(assembler.line.cells[first_units].y == 73.0f);
  assert(assembler.line.cells[first_units + 1].x > 47.0f);
  assert(assembler.line.cells[first_units].inked);

  // 段落已 complete：下一个 run 是新段落。
  const wchar_t third[] = L"新しい段落。";
  const uint32_t third_units = static_cast<uint32_t>(std::wcslen(third));
  assert(assembler.BeginRun(&layer_a, third, third_units, 12100u, 44.0f, 73.0f));
  assert(assembler.line.unit_count == third_units);
  assert(assembler.line.first_tick_ms == 12100u);
  assert(assembler.EndRun(12200u));
  assert(assembler.line.complete);  // 无引号 = 平衡
}

void TestParagraphAssemblerSplitsOnTimeoutAndLayerChange() {
  sf::ParagraphAssembler assembler;
  int layer_a = 0;
  int layer_b = 0;
  const wchar_t open[] = L"「未閉合";
  const uint32_t open_units = static_cast<uint32_t>(std::wcslen(open));
  assert(assembler.BeginRun(&layer_a, open, open_units, 1000u, 44.0f, 73.0f));
  assert(assembler.EndRun(1200u));
  assert(!assembler.line.complete);

  // 超过续行窗口（>2500ms）→ 新段落。
  const wchar_t late[] = L"遅い」";
  const uint32_t late_units = static_cast<uint32_t>(std::wcslen(late));
  assert(assembler.BeginRun(&layer_a, late, late_units, 1200u + 2501u, 44.0f, 73.0f));
  assert(assembler.line.unit_count == late_units);
  assert(assembler.line.first_tick_ms == 3701u);
  assert(assembler.EndRun(3800u));
  assert(assembler.line.complete);  // 多出的 」 被钳住为 0

  // 未闭合但 layer 变了 → 新段落。
  assert(assembler.BeginRun(&layer_a, open, open_units, 4000u, 44.0f, 73.0f));
  assert(assembler.EndRun(4100u));
  const wchar_t other[] = L"別レイヤ";
  const uint32_t other_units = static_cast<uint32_t>(std::wcslen(other));
  assert(assembler.BeginRun(&layer_b, other, other_units, 4200u, 44.0f, 73.0f));
  assert(assembler.line.unit_count == other_units);
  assert(assembler.layer == &layer_b);
}

void TestParagraphAssemblerRelayoutIsIdempotent() {
  sf::ParagraphAssembler assembler;
  int layer = 0;
  const wchar_t text[] = L"「同じ";
  const uint32_t units = static_cast<uint32_t>(std::wcslen(text));
  assert(assembler.BeginRun(&layer, text, units, 1000u, 44.0f, 73.0f));
  assert(!assembler.last_begin_relayout);
  assembler.AppendCell(0u, sf::ComputeGlyphCell(0.0f, 0.0f, 47.0f, 0.0f, 44.0f, 1.0f, text[0]));
  assert(assembler.EndRun(1100u));
  assert(!assembler.line.complete);
  // 同 layer 同文本再次从 index 0 开始：视为重排，不拼接。
  assert(assembler.BeginRun(&layer, text, units, 1300u, 44.0f, 73.0f));
  assert(assembler.last_begin_relayout);
  assert(assembler.line.unit_count == units);
  assert(assembler.line.cells[0].w == 0.0f);  // 字格被清空等待重填
  assembler.AppendCell(0u, sf::ComputeGlyphCell(10.0f, 0.0f, 57.0f, 0.0f, 44.0f, 1.0f, text[0]));
  assert(assembler.line.cells[0].x == 10.0f);
  assert(assembler.EndRun(1400u));
  assert(assembler.post_seq == 2u);
}

void TestParagraphAssemblerBoundsAndIgnoredCalls() {
  sf::ParagraphAssembler assembler;
  int layer = 0;
  // 没有 BeginRun 的 AppendCell / EndRun 被忽略。
  assembler.AppendCell(0u, sf::GlyphCell{1.0f, 1.0f, 1.0f, 1.0f, 1u});
  assert(assembler.line.unit_count == 0u);
  assert(!assembler.EndRun(100u));
  assert(!assembler.BeginRun(&layer, nullptr, 3u, 100u, 44.0f, 73.0f));
  assert(!assembler.BeginRun(&layer, L"x", 0u, 100u, 44.0f, 73.0f));
  // 超长 run 被钳到 kMaxRunUnits；越界 AppendCell 被忽略。
  std::vector<wchar_t> huge(sf::kMaxRunUnits + 100u, L'あ');
  assert(assembler.BeginRun(&layer, huge.data(), static_cast<uint32_t>(huge.size()),
                            200u, 44.0f, 73.0f));
  assert(assembler.line.unit_count == sf::kMaxRunUnits);
  assembler.AppendCell(sf::kMaxRunUnits + 5u, sf::GlyphCell{1.0f, 1.0f, 1.0f, 1.0f, 1u});
  assert(assembler.EndRun(300u));
  assert(assembler.line.complete);
  // 段落满后的续行被截断，不越界。
  assembler.line.complete = false;
  assert(assembler.BeginRun(&layer, L"「続き", 3u, 400u, 44.0f, 73.0f));
  assert(assembler.line.unit_count == sf::kMaxRunUnits);
}

}  // namespace

int main() {
  TestImageViewRejectsNonPe();
  TestAnchorDerivationSucceedsOnStandardImage();
  TestAnchorDerivationFailsClosedOnDuplicateTypeDescriptor();
  TestAnchorDerivationFailsClosedOnMissingTypeDescriptor();
  TestAnchorDerivationFailsClosedOnAmbiguousVtable();
  TestAnchorDerivationFailsClosedOnSecondMeshBuilder();
  TestAnchorDerivationFailsClosedOnSecondLayoutCandidate();
  TestAnchorDerivationFailsClosedOnCursorStoreMismatch();
  TestAnchorDerivationFailsClosedOnTextLengthShape();
  TestAnchorDerivationRequiresChainedFragmentMembership();
  TestAnchorDerivationFailsClosedOnScaleMismatch();
  TestAnchorDerivationRejectsImageWithoutExceptionDirectory();
  TestExportTableResolution();
  TestImportTableResolution();
  TestModuleNameFilter();
  TestVoicePayloadValidation();
  TestVoiceStorageName();
  TestMsvcStdStringLocate();
  TestMsvcVectorDeallocationShape();
  TestDedupeWindows();
  TestGlyphCellComputation();
  TestParagraphAssemblerMergesQuoteBalancedRuns();
  TestParagraphAssemblerSplitsOnTimeoutAndLayerChange();
  TestParagraphAssemblerRelayoutIsIdempotent();
  TestParagraphAssemblerBoundsAndIgnoredCalls();
  return 0;
}
