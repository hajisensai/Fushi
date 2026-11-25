// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

// Nitroplus N2System adapter rules on synthetic bytes (no game code or text).
//
//   fushi_nitroplus_adapter_test               unit tests
//   fushi_nitroplus_adapter_test --probe <exe>  offline site probe of a PE32
//                                              file (prints only structure)

#include <cassert>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>

#include "../hook/adapters/nitroplus_profile.h"

namespace np = fushi_voice_hook::nitroplus;

namespace {

void Put32(std::vector<uint8_t>* b, uint32_t v) {
  for (int i = 0; i < 4; ++i) b->push_back(static_cast<uint8_t>(v >> (8 * i)));
}

void Set32(std::vector<uint8_t>* b, size_t at, uint32_t v) {
  for (int i = 0; i < 4; ++i) (*b)[at + i] = static_cast<uint8_t>(v >> (8 * i));
}

constexpr uint32_t kCodeRva = 0x1000;
constexpr uint32_t kStateVa = 0x0061DFF8;
constexpr uint32_t kBacklogVa = 0x006273EC;

struct Knobs {
  bool guard = true;
  bool split_all_same = true;
  int reentries = 2;
  bool voice_block = true;
  uint8_t name_offset = 0x24;
  uint8_t file_offset = 0x64;
};

// A routine laid out like the engine's backlog append (hand-assembled x86).
// Returns the entry offset inside `code`.
uint32_t EmitRoutine(std::vector<uint8_t>* code, const Knobs& k) {
  while (code->size() % 16 != 0) code->push_back(0xCC);
  const uint32_t entry = static_cast<uint32_t>(code->size());
  // cmp dword ptr [state], 0x190; jne +3; xor eax,eax; ret
  code->insert(code->end(), {0x81, 0x3D});
  Put32(code, kStateVa);
  Put32(code, 0x190);
  code->insert(code->end(), {0x75, 0x03, 0x33, k.guard ? uint8_t{0xC0} : uint8_t{0xC9}, 0xC3});
  // push edi; mov edi,[esp+8]
  code->insert(code->end(), {0x57, 0x8B, 0x7C, 0x24, 0x08});
  const uint32_t pairs[4] = {0x00210021u, 0x0021003Fu, 0x003F0021u, 0x003F003Fu};
  size_t rel_at[4] = {};
  for (int i = 0; i < 4; ++i) {
    code->insert(code->end(), {0x81, 0xFF});
    Put32(code, pairs[i]);
    code->insert(code->end(), {0x0F, 0x84});
    rel_at[i] = code->size();
    Put32(code, 0);
  }
  // push ebp; mov ebp,[backlog]; mov eax,[ebp+0x24]; push esi
  code->insert(code->end(), {0x55, 0x8B, 0x2D});
  Put32(code, kBacklogVa);
  code->insert(code->end(), {0x8B, 0x45, 0x24, 0x56, 0x53});
  if (k.voice_block) {
    // mov ebx,[esp+0x18]; test ebx,ebx; je; mov edx,0x10; mov [eax],dx
    code->insert(code->end(), {0x8B, 0x5C, 0x24, 0x18, 0x85, 0xDB, 0x74, 0x30, 0xBA});
    Put32(code, 0x10);
    code->insert(code->end(), {0x66, 0x89, 0x10, 0xB9});
    Put32(code, 0x11);
    // mov al,[ebx+name]
    code->insert(code->end(), {0x66, 0x89, 0x08, 0x8A, 0x43, k.name_offset, 0x90});
    code->insert(code->end(), {0xB9});
    Put32(code, 0x11);
    // mov ecx,[ebx+file]; mov al,[ecx]
    code->insert(code->end(), {0x66, 0x89, 0x0A, 0x8B, 0x4B, k.file_offset, 0x8A, 0x01});
  }
  code->insert(code->end(), {0x5B, 0x5E, 0x5D, 0x5F, 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3});
  for (int i = 0; i < 16; ++i) code->push_back(0xCC);
  // The split block: mov eax,edi; shr eax,16; push 0; push eax; call entry;
  // movzx ecx,di; push 0; push ecx; call entry; add esp,16; mov eax,1; pop edi; ret
  const uint32_t split = static_cast<uint32_t>(code->size());
  code->insert(code->end(), {0x8B, 0xC7, 0xC1, 0xE8, 0x10, 0x6A, 0x00, 0x50});
  for (int call = 0; call < 2; ++call) {
    if (call > 0) code->insert(code->end(), {0x0F, 0xB7, 0xCF, 0x6A, 0x00, 0x51});
    const uint32_t at = static_cast<uint32_t>(code->size());
    code->push_back(0xE8);
    const uint32_t target = call < k.reentries ? entry : split;
    Put32(code, target - (at + 5));
  }
  code->insert(code->end(), {0x83, 0xC4, 0x10, 0xB8, 0x01, 0x00, 0x00, 0x00, 0x5F, 0xC3});
  for (int i = 0; i < 4; ++i) {
    const uint32_t from = static_cast<uint32_t>(rel_at[i] + 4);
    const uint32_t target = (k.split_all_same || i != 2) ? split : split + 5;
    Set32(code, rel_at[i], target - from);
  }
  return entry;
}

np::ImageView ViewOf(const std::vector<uint8_t>& image, uint32_t code_size) {
  np::ImageView view;
  view.bytes = image.data();
  view.size = image.size();
  view.image_base = 0x400000;
  view.code_rva = kCodeRva;
  view.code_size = code_size;
  return view;
}

std::vector<uint8_t> ImageWith(const std::vector<uint8_t>& code) {
  std::vector<uint8_t> image(kCodeRva, 0);
  image.insert(image.end(), code.begin(), code.end());
  return image;
}

void TestResolvesRoutine() {
  std::vector<uint8_t> code(0x40, 0x90);
  const uint32_t entry = EmitRoutine(&code, Knobs{});
  code.resize(code.size() + 0x40, 0xCC);
  const auto image = ImageWith(code);
  const np::BacklogSites s =
      np::ResolveBacklogAppend(ViewOf(image, static_cast<uint32_t>(code.size())));
  assert(s.ok);
  assert(s.refusal == np::Refusal::kNone);
  assert(s.append_rva == kCodeRva + entry);
  assert(s.pair_split_rva > s.append_rva);
  assert(s.no_log_state_va == kStateVa);
  assert(s.no_log_state_value == 0x190);
  assert(s.backlog_global_va == kBacklogVa);
  assert(s.write_pointer_offset == 0x24);
  assert(s.voice_name_offset == 0x24);
  assert(s.voice_file_offset == 0x64);
  assert(s.anchors_seen == 1);
}

np::Refusal RefusalWith(const Knobs& knobs, int copies = 1) {
  std::vector<uint8_t> code(0x20, 0x90);
  for (int i = 0; i < copies; ++i) EmitRoutine(&code, knobs);
  code.resize(code.size() + 0x40, 0xCC);
  const auto image = ImageWith(code);
  const np::BacklogSites s =
      np::ResolveBacklogAppend(ViewOf(image, static_cast<uint32_t>(code.size())));
  assert(s.ok == (s.refusal == np::Refusal::kNone));
  return s.refusal;
}

void TestRefusals() {
  assert(RefusalWith(Knobs{}) == np::Refusal::kNone);
  // Two candidates: not unique, nothing is installed.
  assert(RefusalWith(Knobs{}, 2) == np::Refusal::kAnchorNotUnique);
  Knobs k;
  k.guard = false;
  assert(RefusalWith(k) == np::Refusal::kEntryShape);
  k = Knobs{};
  k.split_all_same = false;
  assert(RefusalWith(k) == np::Refusal::kPairSplit);
  k = Knobs{};
  k.reentries = 1;
  assert(RefusalWith(k) == np::Refusal::kPairSplit);
  k = Knobs{};
  k.voice_block = false;
  assert(RefusalWith(k) == np::Refusal::kVoiceFields);
  k = Knobs{};
  k.name_offset = 0x70;  // name after the file pointer: not the tag layout
  assert(RefusalWith(k) == np::Refusal::kVoiceFields);
  // No routine at all.
  std::vector<uint8_t> code(0x200, 0x90);
  const auto image = ImageWith(code);
  assert(np::ResolveBacklogAppend(ViewOf(image, 0x200)).refusal ==
         np::Refusal::kNoAnchor);
  np::ImageView empty;
  assert(np::ResolveBacklogAppend(empty).refusal == np::Refusal::kNoCode);
  // A code range past the mapped bytes is not read.
  assert(np::ResolveBacklogAppend(ViewOf(image, 0x10000)).refusal ==
         np::Refusal::kNoAnchor);
}

void TestPeView() {
  // A minimal PE32 image whose entry point is in an executable section.
  std::vector<uint8_t> image(0x3000, 0);
  auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(image.data());
  dos->e_magic = IMAGE_DOS_SIGNATURE;
  dos->e_lfanew = 0x80;
  auto* nt = reinterpret_cast<IMAGE_NT_HEADERS32*>(image.data() + 0x80);
  nt->Signature = IMAGE_NT_SIGNATURE;
  nt->FileHeader.Machine = IMAGE_FILE_MACHINE_I386;
  nt->FileHeader.NumberOfSections = 2;
  nt->FileHeader.SizeOfOptionalHeader = sizeof(IMAGE_OPTIONAL_HEADER32);
  nt->OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR32_MAGIC;
  nt->OptionalHeader.SizeOfImage = 0x3000;
  nt->OptionalHeader.AddressOfEntryPoint = 0x2010;
  auto* sections = reinterpret_cast<IMAGE_SECTION_HEADER*>(
      image.data() + 0x80 + sizeof(IMAGE_NT_HEADERS32));
  sections[0].VirtualAddress = 0x1000;
  sections[0].Misc.VirtualSize = 0x800;
  sections[0].Characteristics = IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_CNT_CODE;
  sections[1].VirtualAddress = 0x2000;
  sections[1].Misc.VirtualSize = 0x800;
  sections[1].Characteristics = IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_CNT_CODE;
  np::ImageView view = fushi_voice_hook::NitroplusImageView(image.data(), image.size());
  assert(view.code_rva == 0x2000 && view.code_size == 0x800);
  // x64 machine: no view.
  nt->FileHeader.Machine = IMAGE_FILE_MACHINE_AMD64;
  view = fushi_voice_hook::NitroplusImageView(image.data(), image.size());
  assert(view.bytes == nullptr);
  // Truncated mapping: no view.
  nt->FileHeader.Machine = IMAGE_FILE_MACHINE_I386;
  view = fushi_voice_hook::NitroplusImageView(image.data(), 0x100);
  assert(view.bytes == nullptr);
}

void TestAssembler() {
  np::Assembler a;
  np::Line out;
  // A shown line: voice tag first (code 0 is the tag only), then characters,
  // a packed pair (re-entered by the engine as its halves), layout controls.
  np::NoteVoice(&a, "v_0001", 6, "voice/v_0001", 12);
  assert(np::FeedCode(&a, 0, &out) == np::FeedResult::kNone);
  assert(np::FeedCode(&a, 0x8175, &out) == np::FeedResult::kNone);
  assert(np::FeedCode(&a, 0x00210021u, &out) == np::FeedResult::kNone);
  assert(np::FeedCode(&a, 0x21, &out) == np::FeedResult::kNone);
  assert(np::FeedCode(&a, 0x21, &out) == np::FeedResult::kNone);
  assert(np::FeedCode(&a, 0x0D, &out) == np::FeedResult::kNone);
  assert(np::FeedCode(&a, 0x09, &out) == np::FeedResult::kNone);
  assert(np::FeedCode(&a, 0x8176, &out) == np::FeedResult::kNone);
  // A second voice on the same line does not replace the first.
  np::NoteVoice(&a, "other", 5, "voice/other", 11);
  assert(np::FeedCode(&a, 0x0A, &out) == np::FeedResult::kLineComplete);
  assert(out.count == 4);
  assert(out.codes[0] == 0x8175 && out.codes[1] == 0x21 &&
         out.codes[2] == 0x21 && out.codes[3] == 0x8176);
  assert(out.has_voice && std::strcmp(out.voice_name, "v_0001") == 0 &&
         std::strcmp(out.voice_file, "voice/v_0001") == 0);
  char bytes[16] = {};
  assert(np::LineToCp932(out, bytes, sizeof(bytes)) == 6);
  assert(static_cast<uint8_t>(bytes[0]) == 0x81 && bytes[2] == '!');

  // The next line starts clean.  A voice before an empty line survives it.
  np::NoteVoice(&a, "v_0002", 6, "f", 1);
  assert(np::FeedCode(&a, 0x0A, &out) == np::FeedResult::kNone);
  assert(np::FeedCode(&a, 0x82A0, &out) == np::FeedResult::kNone);
  assert(np::FeedCode(&a, 0x0A, &out) == np::FeedResult::kLineComplete);
  assert(out.count == 1 && out.has_voice &&
         std::strcmp(out.voice_name, "v_0002") == 0);
  assert(np::FeedCode(&a, 0x82A0, &out) == np::FeedResult::kNone);
  assert(np::FeedCode(&a, 0x0A, &out) == np::FeedResult::kLineComplete);
  assert(!out.has_voice);

  // Long names are cut and terminated.
  char long_name[200];
  std::memset(long_name, 'n', sizeof(long_name));
  np::NoteVoice(&a, long_name, sizeof(long_name), long_name, sizeof(long_name));
  assert(std::strlen(a.open.voice_name) == np::kVoiceNameBytes - 1);
  assert(np::FeedCode(&a, 0x0A, &out) == np::FeedResult::kNone);

  // An overlong line is dropped whole (fail closed) and the next is clean.
  np::Assembler b;
  for (uint32_t i = 0; i < np::kMaxLineCodes + 3; ++i) {
    assert(np::FeedCode(&b, 0x82A0, &out) == np::FeedResult::kNone);
  }
  out.count = 7;
  assert(np::FeedCode(&b, 0x0A, &out) == np::FeedResult::kLineDropped);
  assert(out.count == 7);  // untouched
  assert(np::FeedCode(&b, 0x41, &out) == np::FeedResult::kNone);
  assert(np::FeedCode(&b, 0x0A, &out) == np::FeedResult::kLineComplete);
  assert(out.count == 1 && !out.truncated);
}

void TestCp932() {
  np::Line line;
  line.count = 3;
  line.codes[0] = 0x41;    // 'A'
  line.codes[1] = 0xB1;    // half-width kana
  line.codes[2] = 0x889F;  // kanji
  char out[8] = {};
  assert(np::LineToCp932(line, out, sizeof(out)) == 4);
  line.codes[1] = 0x80;    // not a CP932 single byte
  assert(np::LineToCp932(line, out, sizeof(out)) == 0);
  line.codes[1] = 0x41;
  line.codes[2] = 0x2041;  // not a lead byte
  assert(np::LineToCp932(line, out, sizeof(out)) == 0);
  line.codes[2] = 0x887F;  // 0x7f is never a trail byte
  assert(np::LineToCp932(line, out, sizeof(out)) == 0);
  line.codes[2] = 0x889F;
  assert(np::LineToCp932(line, out, 3) == 0);  // no room
}

// Offline probe: map a PE32 file by section and print the resolution
// (offsets and refusal only; no bytes of the file are printed).
int Probe(const char* path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) {
    std::printf("probe: cannot open\n");
    return 2;
  }
  const std::vector<uint8_t> raw((std::istreambuf_iterator<char>(file)),
                                 std::istreambuf_iterator<char>());
  if (raw.size() < sizeof(IMAGE_DOS_HEADER)) return 2;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(raw.data());
  if (dos->e_magic != IMAGE_DOS_SIGNATURE ||
      static_cast<size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS32) > raw.size()) {
    std::printf("probe: not a PE file\n");
    return 1;
  }
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS32*>(raw.data() + dos->e_lfanew);
  if (nt->FileHeader.Machine != IMAGE_FILE_MACHINE_I386 ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
    std::printf("probe: machine=0x%x not PE32 x86: refused\n", nt->FileHeader.Machine);
    return 1;
  }
  std::vector<uint8_t> image(nt->OptionalHeader.SizeOfImage, 0);
  const size_t header_bytes =
      nt->OptionalHeader.SizeOfHeaders < image.size() ? nt->OptionalHeader.SizeOfHeaders
                                                      : image.size();
  std::memcpy(image.data(), raw.data(), header_bytes < raw.size() ? header_bytes : raw.size());
  const auto* sections = reinterpret_cast<const IMAGE_SECTION_HEADER*>(
      raw.data() + dos->e_lfanew + offsetof(IMAGE_NT_HEADERS32, OptionalHeader) +
      nt->FileHeader.SizeOfOptionalHeader);
  for (uint32_t i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
    const IMAGE_SECTION_HEADER& s = sections[i];
    size_t n = s.SizeOfRawData;
    if (s.PointerToRawData + n > raw.size()) n = raw.size() - s.PointerToRawData;
    if (s.VirtualAddress + n > image.size()) n = image.size() - s.VirtualAddress;
    std::memcpy(image.data() + s.VirtualAddress, raw.data() + s.PointerToRawData, n);
  }
  np::ImageView view = fushi_voice_hook::NitroplusImageView(image.data(), image.size());
  view.image_base = nt->OptionalHeader.ImageBase;
  const np::BacklogSites s = np::ResolveBacklogAppend(view);
  std::printf(
      "probe: code_rva=0x%x code_size=0x%x anchors=%u ok=%d refusal=%u "
      "append_rva=0x%x pair_split_rva=0x%x no_log_state=0x%x/0x%x "
      "backlog_global=0x%x write_ptr=+0x%x voice_name=+0x%x voice_file=+0x%x\n",
      view.code_rva, view.code_size, s.anchors_seen, s.ok ? 1 : 0,
      static_cast<unsigned>(s.refusal), s.append_rva, s.pair_split_rva,
      s.no_log_state_va, s.no_log_state_value, s.backlog_global_va,
      s.write_pointer_offset, s.voice_name_offset, s.voice_file_offset);
  return s.ok ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 3 && std::strcmp(argv[1], "--probe") == 0) return Probe(argv[2]);
  TestResolvesRoutine();
  TestRefusals();
  TestPeView();
  TestAssembler();
  TestCp932();
  // Not the main module of this test process: never a Nitroplus game.
  assert(!fushi_voice_hook::MatchesNitroplusProfile(nullptr));
  std::printf("nitroplus adapter tests passed\n");
  return 0;
}
