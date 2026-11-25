// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

// EntisGLS: identity, structural site resolution, message-tree text and the
// page model, on synthetic images and synthetic node trees only (no game
// bytes).  With FUSHI_ENTISGLS_SAMPLE set to an executable path the resolver
// also runs on that file (an offline site probe; never in CI).
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "../hook/adapters/entisgls_profile.h"

namespace eg = fushi_voice_hook::entisgls;

namespace {

constexpr uint32_t kImageSize = 0x8000u;
constexpr uint32_t kVaBase = 0x400000u;
constexpr uint32_t kCodeBegin = 0x1000u;
constexpr uint32_t kCodeEnd = 0x5000u;
constexpr uint32_t kDataBegin = 0x5000u;
constexpr uint32_t kExportDir = 0x6000u;

// Strings (.rdata).
constexpr uint32_t kStrAddText = 0x5000u;
constexpr uint32_t kStrAddXml = 0x5040u;
constexpr uint32_t kStrClear = 0x5080u;
constexpr uint32_t kStrRuby = 0x50c0u;
constexpr uint32_t kStrPRuby = 0x50d0u;  // "pruby": contains "ruby"
constexpr uint32_t kStrSigText = 0x5100u;
constexpr uint32_t kStrSigEmpty = 0x5140u;
constexpr uint32_t kStrAddTextDecoy = 0x5180u;  // "addMessageTextEx"

// Code.
constexpr uint32_t kRegister = 0x1f00u;
constexpr uint32_t kGetter = 0x1f10u;
constexpr uint32_t kParse = 0x1f20u;
constexpr uint32_t kCompare = 0x1f30u;
constexpr uint32_t kOtherGetter = 0x1f40u;
constexpr uint32_t kRegistrations = 0x1000u;
constexpr uint32_t kTextHandler = 0x2000u;
constexpr uint32_t kXmlHandler = 0x2100u;
constexpr uint32_t kXmlMethod = 0x2200u;
constexpr uint32_t kClearHandler = 0x2300u;
constexpr uint32_t kClear = 0x2400u;
constexpr uint32_t kAdd = 0x2500u;
constexpr uint32_t kProcess = 0x2700u;
constexpr uint32_t kOtherAdd = 0x3000u;

struct Image {
  std::vector<uint8_t> bytes = std::vector<uint8_t>(kImageSize, 0xccu);
  uint32_t at = 0u;

  void Seek(uint32_t rva) { at = rva; }
  void Put(std::initializer_list<uint8_t> b) {
    for (uint8_t v : b) bytes[at++] = v;
  }
  void Put32(uint32_t v) {
    std::memcpy(bytes.data() + at, &v, 4u);
    at += 4u;
  }
  void Call(uint32_t target) {
    Put({0xe8});
    Put32(target - (at + 4u));
  }
  void PushVa(uint32_t rva) {
    Put({0x68});
    Put32(kVaBase + rva);
  }
  void Wide(uint32_t rva, const wchar_t* text) {
    Seek(rva);
    for (const wchar_t* p = text;; ++p) {
      bytes[at++] = static_cast<uint8_t>(*p & 0xff);
      bytes[at++] = static_cast<uint8_t>(*p >> 8);
      if (*p == 0) break;
    }
  }
  void Ascii(uint32_t rva, const char* text) {
    std::memcpy(bytes.data() + rva, text, std::strlen(text) + 1u);
  }
  // One Rosetta registration: flags, handler, signature, return, name.
  void Registration(uint32_t handler, uint32_t sig, bool typed_return,
                    uint32_t name) {
    Put({0x6a, 0x00, 0x51});
    PushVa(handler);
    Put({0x51});
    PushVa(sig);
    if (typed_return) {
      PushVa(sig);
    } else {
      Put({0x6a, 0x00});
    }
    PushVa(name);
    Put({0x8d, 0x44, 0x24, 0x30, 0x50, 0x57, 0x8b, 0xcb});
    Call(kRegister);
  }
};

struct Options {
  bool export_sprite = true;
  bool duplicate_text_registration = false;
  bool xml_adds_elsewhere = false;
  bool clear_other_getter = false;
  bool process_ruby_compare = true;
  bool process_text_branch = true;
  bool add_reads_type = true;
};

std::vector<uint8_t> BuildImage(const Options& o) {
  Image img;
  // Headers.
  auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(img.bytes.data());
  std::memset(img.bytes.data(), 0, 0x400u);
  dos->e_magic = IMAGE_DOS_SIGNATURE;
  dos->e_lfanew = 0x80;
  auto* nt = reinterpret_cast<IMAGE_NT_HEADERS32*>(img.bytes.data() + 0x80);
  nt->Signature = IMAGE_NT_SIGNATURE;
  nt->FileHeader.Machine = IMAGE_FILE_MACHINE_I386;
  nt->FileHeader.NumberOfSections = 2;
  nt->FileHeader.SizeOfOptionalHeader = sizeof(IMAGE_OPTIONAL_HEADER32);
  nt->OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR32_MAGIC;
  nt->OptionalHeader.ImageBase = kVaBase;
  nt->OptionalHeader.SizeOfImage = kImageSize;
  nt->OptionalHeader.SizeOfHeaders = 0x400u;
  nt->OptionalHeader.NumberOfRvaAndSizes = IMAGE_NUMBEROF_DIRECTORY_ENTRIES;
  nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT] = {
      kExportDir, 0x400u};
  auto* sections = IMAGE_FIRST_SECTION(nt);
  std::memcpy(sections[0].Name, ".text", 5);
  sections[0].VirtualAddress = kCodeBegin;
  sections[0].Misc.VirtualSize = kCodeEnd - kCodeBegin;
  sections[0].SizeOfRawData = kCodeEnd - kCodeBegin;
  sections[0].Characteristics = IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ;
  std::memcpy(sections[1].Name, ".rdata", 6);
  sections[1].VirtualAddress = kDataBegin;
  sections[1].Misc.VirtualSize = kImageSize - kDataBegin;
  sections[1].SizeOfRawData = kImageSize - kDataBegin;
  sections[1].Characteristics = IMAGE_SCN_MEM_READ;
  std::memset(img.bytes.data() + kDataBegin, 0, kImageSize - kDataBegin);

  // Exports (data exports: the runtime class objects).
  std::vector<const char*> names = {eg::kExportSysCall,
                                    eg::kExportRosettaMessage};
  if (o.export_sprite) names.push_back(eg::kExportSpriteMessage);
  IMAGE_EXPORT_DIRECTORY dir = {};
  dir.NumberOfFunctions = static_cast<DWORD>(names.size());
  dir.NumberOfNames = static_cast<DWORD>(names.size());
  dir.AddressOfFunctions = kExportDir + 0x100u;
  dir.AddressOfNames = kExportDir + 0x140u;
  dir.AddressOfNameOrdinals = kExportDir + 0x180u;
  std::memcpy(img.bytes.data() + kExportDir, &dir, sizeof(dir));
  uint32_t name_at = kExportDir + 0x200u;
  for (uint32_t i = 0u; i < names.size(); ++i) {
    const uint32_t data = 0x7800u + i * 0x10u;
    std::memcpy(img.bytes.data() + dir.AddressOfFunctions + i * 4u, &data, 4u);
    std::memcpy(img.bytes.data() + dir.AddressOfNames + i * 4u, &name_at, 4u);
    const uint16_t ordinal = static_cast<uint16_t>(i);
    std::memcpy(img.bytes.data() + dir.AddressOfNameOrdinals + i * 2u,
                &ordinal, 2u);
    img.Ascii(name_at, names[i]);
    name_at += static_cast<uint32_t>(std::strlen(names[i]) + 1u);
  }

  img.Wide(kStrAddText, L"addMessageText");
  img.Wide(kStrAddXml, L"addMessageXML");
  img.Wide(kStrClear, L"clearMessage");
  img.Wide(kStrRuby, L"ruby");
  img.Wide(kStrPRuby, L"pruby");
  img.Wide(kStrSigText, L"String strText");
  img.Wide(kStrSigEmpty, L"");
  img.Wide(kStrAddTextDecoy, L"addMessageTextEx");

  // Leaf functions.
  for (uint32_t leaf : {kRegister, kGetter, kParse, kCompare, kOtherGetter}) {
    img.Seek(leaf);
    img.Put({0xc3});
  }

  // Registrations: the decoy name first (a longer literal), then the three.
  img.Seek(kRegistrations);
  img.Registration(kOtherAdd, kStrSigText, false, kStrAddTextDecoy);
  img.Registration(kClearHandler, kStrSigEmpty, false, kStrClear);
  img.Registration(kTextHandler, kStrSigText, false, kStrAddText);
  img.Registration(kXmlHandler, kStrSigText, false, kStrAddXml);
  if (o.duplicate_text_registration) {
    img.Registration(kXmlHandler, kStrSigText, true, kStrAddText);
  } else {
    // The same handler registered twice is still one handler.
    img.Registration(kTextHandler, kStrSigText, true, kStrAddText);
  }

  // addMessageText handler: getter -> edi, then AddMessage(this=edi).
  img.Seek(kTextHandler);
  img.Put({0x55, 0x8b, 0xec, 0x8b, 0x55, 0x10, 0x8b, 0x4d, 0x08});
  img.Call(kGetter);
  img.Put({0x8b, 0xf8, 0x85, 0xff, 0x74, 0x0c, 0x8d, 0x44, 0x24, 0x34, 0x50,
           0x8b, 0xcf});
  img.Call(kAdd);
  img.Put({0x33, 0xc0, 0x5d, 0xc3});

  // addMessageXML handler: getter -> esi, then XmlMethod(this=esi).
  img.Seek(kXmlHandler);
  img.Put({0x55, 0x8b, 0xec, 0x8b, 0x55, 0x10, 0x8b, 0x4d, 0x08});
  img.Call(kGetter);
  img.Put({0x8b, 0xf0, 0x85, 0xf6, 0x74, 0x09, 0xff, 0x30, 0x8b, 0xce});
  img.Call(kXmlMethod);
  img.Put({0x33, 0xc0, 0x5d, 0xc3});

  // XmlMethod: mov esi,ecx; parse; AddMessage(this=esi).
  img.Seek(kXmlMethod);
  img.Put({0x55, 0x8b, 0xec, 0x56, 0x8b, 0xf1, 0x51, 0xff, 0x75, 0x08, 0x8d,
           0x4d, 0xb4});
  img.Call(kParse);
  img.Put({0x8d, 0x85, 0x54, 0xff, 0xff, 0xff, 0x50, 0x8b, 0xce});
  img.Call(o.xml_adds_elsewhere ? kOtherAdd : kAdd);
  img.Put({0x5e, 0x5d, 0xc2, 0x04, 0x00});

  // clearMessage handler: getter, mov ecx,eax; call Clear.
  img.Seek(kClearHandler);
  img.Put({0x55, 0x8b, 0xec, 0x8b, 0x55, 0x10, 0x8b, 0x4d, 0x08});
  img.Call(o.clear_other_getter ? kOtherGetter : kGetter);
  img.Put({0x85, 0xc0, 0x74, 0x07, 0x8b, 0xc8});
  img.Call(kClear);
  img.Put({0x33, 0xc0, 0x5d, 0xc3});

  img.Seek(kClear);
  img.Put({0x55, 0x8b, 0xec, 0x83, 0xe4, 0xf8, 0x5d, 0xc3});

  // AddMessage: type / children reads, then PROCESS(node).
  img.Seek(kAdd);
  img.Put({0x55, 0x8b, 0xec, 0x6a, 0xff, 0x8b, 0xd9, 0x8b, 0x75, 0x08});
  if (o.add_reads_type) {
    img.Put({0x83, 0x7e, 0x0c, 0x00, 0x75, 0x08});
  } else {
    img.Put({0x83, 0x7e, 0x10, 0x00, 0x75, 0x08});
  }
  img.Put({0x8b, 0x46, 0x54, 0x90, 0x8b, 0x46, 0x50, 0x90});
  img.Put({0xff, 0x75, 0x08, 0x8b, 0xcb});
  img.Call(kProcess);
  img.Put({0x5d, 0xc2, 0x04, 0x00});

  // A second, unrelated add (decoy target).
  img.Seek(kOtherAdd);
  img.Put({0x55, 0x8b, 0xec, 0x5d, 0xc2, 0x04, 0x00});

  // PROCESS: type load, the "pruby" decoy compare, the "ruby" compare and
  // the text-node branch.
  img.Seek(kProcess);
  img.Put({0x55, 0x8b, 0xec, 0x53, 0x8b, 0x5d, 0x08, 0x8b, 0x43, 0x0c, 0x85,
           0xc0});
  img.PushVa(kStrPRuby);
  img.Put({0x8d, 0x4b, 0x10});
  img.Call(kCompare);
  if (o.process_ruby_compare) {
    img.PushVa(kStrRuby);
    img.Put({0x8d, 0x4b, 0x10});
    img.Call(kCompare);
  }
  img.Put({0x83, 0xf8, 0x01, 0x75, 0x02, 0x90, 0x90});
  if (o.process_text_branch) {
    img.Put({0x83, 0xf8, 0x02, 0x0f, 0x85, 0x00, 0x00, 0x00, 0x00, 0x90,
             0xff, 0x73, 0x28});
  } else {
    img.Put({0x83, 0xf8, 0x02, 0x0f, 0x85, 0x00, 0x00, 0x00, 0x00, 0x90,
             0xff, 0x73, 0x2c});
  }
  img.Put({0x5b, 0x5d, 0xc2, 0x04, 0x00});
  return img.bytes;
}

eg::SiteResult Resolve(const std::vector<uint8_t>& bytes, eg::Sites* sites) {
  eg::ImageView view;
  assert(fushi_voice_hook::EntisGlsImageView(bytes.data(), bytes.size(),
                                             &view));
  return eg::ResolveSites(view, sites);
}

void TestResolvesSyntheticImage() {
  const std::vector<uint8_t> bytes = BuildImage({});
  assert(fushi_voice_hook::IsEntisGlsImage(bytes.data(), bytes.size()));
  eg::Sites sites;
  assert(Resolve(bytes, &sites) == eg::SiteResult::kResolved);
  assert(sites.add_message == kAdd);
  assert(sites.clear_message == kClear);
  assert(sites.process == kProcess);
  assert(sites.getter == kGetter);
  assert(sites.text_handler == kTextHandler);
  assert(sites.xml_handler == kXmlHandler);
  assert(sites.clear_handler == kClearHandler);
}

void TestRefusesWithoutExports() {
  Options o;
  o.export_sprite = false;
  const std::vector<uint8_t> bytes = BuildImage(o);
  assert(!fushi_voice_hook::IsEntisGlsImage(bytes.data(), bytes.size()));
  eg::Sites sites;
  assert(Resolve(bytes, &sites) == eg::SiteResult::kNoExports);
}

void TestRefusesAmbiguousRegistration() {
  Options o;
  o.duplicate_text_registration = true;
  eg::Sites sites;
  assert(Resolve(BuildImage(o), &sites) == eg::SiteResult::kNoRegistration);
}

void TestRefusesXmlPathThatAddsElsewhere() {
  Options o;
  o.xml_adds_elsewhere = true;
  eg::Sites sites;
  assert(Resolve(BuildImage(o), &sites) == eg::SiteResult::kAddMismatch);
}

void TestRefusesGetterMismatch() {
  Options o;
  o.clear_other_getter = true;
  eg::Sites sites;
  assert(Resolve(BuildImage(o), &sites) == eg::SiteResult::kGetterMismatch);
}

void TestRefusesUnprovenNodeLayout() {
  eg::Sites sites;
  Options o;
  o.add_reads_type = false;
  assert(Resolve(BuildImage(o), &sites) == eg::SiteResult::kAddShape);
  o = Options{};
  o.process_ruby_compare = false;  // only the "pruby" literal is compared
  assert(Resolve(BuildImage(o), &sites) == eg::SiteResult::kProcessShape);
  o = Options{};
  o.process_text_branch = false;
  assert(Resolve(BuildImage(o), &sites) == eg::SiteResult::kProcessShape);
}

void TestRefusesOtherEngineImage() {
  std::vector<uint8_t> bytes = BuildImage({});
  // Same code, export table pointing at unrelated names.
  eg::ImageView view;
  assert(fushi_voice_hook::EntisGlsImageView(bytes.data(), bytes.size(),
                                             &view));
  view.export_rva = 0u;
  view.export_size = 0u;
  eg::Sites sites;
  assert(eg::ResolveSites(view, &sites) == eg::SiteResult::kNoExports);
}

// ── synthetic game memory for the message walker ───────────────────────────

struct FakeMemory {
  std::map<uintptr_t, std::vector<uint8_t>> blocks;
  uintptr_t next = 0x10000000u;

  uintptr_t Alloc(size_t size) {
    const uintptr_t at = next;
    blocks[at] = std::vector<uint8_t>(size, 0u);
    next += (size + 0xfffu) & ~static_cast<uintptr_t>(0xfffu);
    next += 0x1000u;  // a guard gap
    return at;
  }
  void Write32(uintptr_t address, uint32_t value) {
    for (auto& [base, block] : blocks) {
      if (address >= base && address + 4u <= base + block.size()) {
        std::memcpy(block.data() + (address - base), &value, 4u);
        return;
      }
    }
    assert(false && "write outside a block");
  }
  uintptr_t Wide(const std::wstring& text) {
    const uintptr_t at = Alloc((text.size() + 1u) * 2u);
    std::memcpy(blocks[at].data(), text.data(), text.size() * 2u);
    return at;
  }
  uintptr_t Node(uint32_t type) {
    const uintptr_t at = Alloc(0x5cu);
    Write32(at + eg::kNodeType, type);
    return at;
  }
  uintptr_t Text(const std::wstring& text) {
    const uintptr_t node = Node(eg::kNodeTypeText);
    Write32(node + eg::kNodeText, static_cast<uint32_t>(Wide(text)));
    Write32(node + eg::kNodeText + 4u, static_cast<uint32_t>(text.size()));
    return node;
  }
  uintptr_t Element(const std::wstring& tag,
                    const std::vector<uintptr_t>& children,
                    uint32_t type = eg::kNodeTypeElement) {
    const uintptr_t node = Node(type);
    Write32(node + eg::kNodeTag, static_cast<uint32_t>(Wide(tag)));
    Write32(node + eg::kNodeTag + 4u, static_cast<uint32_t>(tag.size()));
    if (!children.empty()) {
      const uintptr_t array = Alloc(children.size() * 4u);
      for (size_t i = 0u; i < children.size(); ++i) {
        Write32(array + i * 4u, static_cast<uint32_t>(children[i]));
      }
      Write32(node + eg::kNodeChildren, static_cast<uint32_t>(array));
    }
    Write32(node + eg::kNodeChildCount, static_cast<uint32_t>(children.size()));
    return node;
  }

  static bool Read(void* context, uintptr_t address, void* out,
                   uint32_t bytes) {
    auto* self = static_cast<FakeMemory*>(context);
    for (auto& [base, block] : self->blocks) {
      if (address >= base && address + bytes <= base + block.size()) {
        std::memcpy(out, block.data() + (address - base), bytes);
        return true;
      }
    }
    return false;
  }
};

std::wstring Collect(FakeMemory& memory, uintptr_t root,
                     eg::TextResult expected = eg::TextResult::kOk) {
  wchar_t out[eg::kMaxMessageUnits] = {};
  uint32_t length = 0u;
  const eg::TextResult result = eg::CollectMessageText(
      &FakeMemory::Read, &memory, root, out, eg::kMaxMessageUnits, &length);
  assert(result == expected);
  return std::wstring(out, length);
}

void TestPlainTextNode() {
  FakeMemory m;
  const uintptr_t node = m.Text(L"synthetic plain line");
  assert(Collect(m, node) == L"synthetic plain line");
}

void TestXmlDocumentWithRubyAndBreaks() {
  FakeMemory m;
  // <doc><font size=..>AB</font><ruby reading="..">CD</ruby>E\nF</doc>
  const uintptr_t font = m.Element(L"font", {m.Text(L"AB")});
  const uintptr_t ruby = m.Element(L"ruby", {m.Text(L"CD")});
  const uintptr_t doc = m.Element(
      L"", {font, ruby, m.Text(L"E\r\nF")}, eg::kNodeTypeDocument);
  assert(Collect(m, doc) == L"ABCDEF");
}

void TestNestedElementsAndNullChild() {
  FakeMemory m;
  const uintptr_t inner = m.Element(L"phrase", {m.Text(L"y")});
  const uintptr_t outer = m.Element(L"style", {m.Text(L"x"), 0u, inner,
                                               m.Text(L"z")});
  assert(Collect(m, outer) == L"xyz");
}

void TestFaultAndBounds() {
  FakeMemory m;
  // A text node whose string points nowhere.
  const uintptr_t bad = m.Node(eg::kNodeTypeText);
  m.Write32(bad + eg::kNodeText, 0x7f000000u);
  m.Write32(bad + eg::kNodeText + 4u, 4u);
  Collect(m, bad, eg::TextResult::kFault);
  // An unknown node type.
  Collect(m, m.Node(7u), eg::TextResult::kBadNode);
  // A negative length.
  const uintptr_t neg = m.Text(L"q");
  m.Write32(neg + eg::kNodeText + 4u, 0xffffffffu);
  Collect(m, neg, eg::TextResult::kBadNode);
  // Too long for the copy.
  std::wstring huge(eg::kMaxMessageUnits + 1u, L'a');
  Collect(m, m.Text(huge), eg::TextResult::kTooLong);
  // Too deep.
  uintptr_t chain = m.Text(L"d");
  for (uint32_t i = 0u; i <= eg::kMaxDepth; ++i) {
    chain = m.Element(L"style", {chain});
  }
  Collect(m, chain, eg::TextResult::kTooDeep);
  // A self-referencing tree stops at the node bound.
  const uintptr_t loop = m.Node(eg::kNodeTypeElement);
  const uintptr_t array = m.Alloc(4u);
  m.Write32(array, static_cast<uint32_t>(loop));
  m.Write32(loop + eg::kNodeChildren, static_cast<uint32_t>(array));
  m.Write32(loop + eg::kNodeChildCount, 1u);
  const eg::TextResult r = [&] {
    wchar_t out[eg::kMaxMessageUnits] = {};
    uint32_t length = 0u;
    return eg::CollectMessageText(&FakeMemory::Read, &m, loop, out,
                                  eg::kMaxMessageUnits, &length);
  }();
  assert(r == eg::TextResult::kTooDeep || r == eg::TextResult::kTooManyNodes);
  // Too many children.
  const uintptr_t wide_node = m.Node(eg::kNodeTypeElement);
  m.Write32(wide_node + eg::kNodeChildren, static_cast<uint32_t>(m.Alloc(4u)));
  m.Write32(wide_node + eg::kNodeChildCount, eg::kMaxChildren + 1u);
  Collect(m, wide_node, eg::TextResult::kBadNode);
  Collect(m, 0u, eg::TextResult::kBadNode);
}

// ── page model ─────────────────────────────────────────────────────────────

void Add(eg::PageModel* model, uintptr_t sprite, const std::wstring& text,
         uint64_t tick) {
  eg::OnAdd(model, sprite, text.data(), text.size(), tick);
}

void TestUnitPublishedAfterQuietTick() {
  eg::PageModel model;
  Add(&model, 0x100u, L"first ", 1u);
  Add(&model, 0x100u, L"half", 1u);  // same script step
  assert(eg::OnTick(&model, 1u).empty());
  assert(eg::OnTick(&model, 2u).empty() == false);
  // Nothing new: nothing published again.
  assert(eg::OnTick(&model, 3u).empty());
}

void TestClickUnitsOnOnePage() {
  eg::PageModel model;
  Add(&model, 0x100u, L"unit one", 1u);
  std::vector<eg::Publication> p = eg::OnTick(&model, 3u);
  assert(p.size() == 1u && p[0].text == L"unit one");
  const uint64_t page = p[0].page_seq;
  // The next click unit is appended to the same page: only it goes out.
  Add(&model, 0x100u, L"\x3000unit two", 10u);
  assert(eg::OnTick(&model, 10u).empty());
  p = eg::OnTick(&model, 11u);
  assert(p.size() == 1u && p[0].text == L"unit two" && p[0].page_seq == page);
}

void TestClearStartsNewPage() {
  eg::PageModel model;
  Add(&model, 0x100u, L"page one", 1u);
  const std::vector<eg::Publication> first = eg::OnTick(&model, 3u);
  assert(first.size() == 1u);
  eg::OnClear(&model, 0x100u, 5u);
  Add(&model, 0x100u, L"page one", 5u);  // same text, new page
  const std::vector<eg::Publication> second = eg::OnTick(&model, 7u);
  assert(second.size() == 1u && second[0].text == L"page one" &&
         second[0].page_seq != first[0].page_seq);
}

void TestUnitWipedWithinStepIsDropped() {
  eg::PageModel model;
  Add(&model, 0x100u, L"skipped", 1u);
  eg::OnClear(&model, 0x100u, 1u);
  assert(eg::OnTick(&model, 3u).empty());
}

void TestSpritesAreIndependent() {
  eg::PageModel model;
  Add(&model, 0x100u, L"body", 1u);
  Add(&model, 0x200u, L"other", 4u);
  std::vector<eg::Publication> p = eg::OnTick(&model, 3u);
  assert(p.size() == 1u && p[0].sprite == 0x100u);
  p = eg::OnTick(&model, 6u);
  assert(p.size() == 1u && p[0].sprite == 0x200u && p[0].text == L"other");
  // Blank units publish nothing.
  Add(&model, 0x100u, L" \x3000 ", 7u);
  assert(eg::OnTick(&model, 9u).empty());
}

void TestNeverClearedPageIsBounded() {
  eg::PageModel model;
  const std::wstring chunk(eg::kMaxMessageUnits, L'a');
  for (uint64_t i = 0u; i < 10u; ++i) {
    Add(&model, 0x100u, chunk, i * 3u);
    eg::OnTick(&model, i * 3u + 2u);
  }
  for (const eg::PageState& s : model.sprites) {
    assert(s.page.size() <= 4u * eg::kMaxMessageUnits);
  }
}

// ── offline site probe on a real executable (manual) ───────────────────────

bool LoadByRva(const char* path, std::vector<uint8_t>* image) {
  FILE* file = nullptr;
  if (fopen_s(&file, path, "rb") != 0 || file == nullptr) return false;
  std::vector<uint8_t> raw;
  uint8_t buffer[65536];
  size_t got = 0u;
  while ((got = fread(buffer, 1u, sizeof(buffer), file)) != 0u) {
    raw.insert(raw.end(), buffer, buffer + got);
  }
  fclose(file);
  if (raw.size() < 0x400u) return false;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(raw.data());
  if (dos->e_magic != IMAGE_DOS_SIGNATURE ||
      static_cast<size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS32) >
          raw.size()) {
    return false;
  }
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS32*>(raw.data() + dos->e_lfanew);
  if (nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC) return false;
  image->assign(nt->OptionalHeader.SizeOfImage, 0u);
  std::memcpy(image->data(), raw.data(),
              (std::min)(static_cast<size_t>(nt->OptionalHeader.SizeOfHeaders),
                         raw.size()));
  const auto* sections = IMAGE_FIRST_SECTION(nt);
  for (uint32_t i = 0u; i < nt->FileHeader.NumberOfSections; ++i) {
    const auto& s = sections[i];
    const size_t bytes = (std::min)(
        static_cast<size_t>(s.SizeOfRawData),
        s.Misc.VirtualSize != 0u ? static_cast<size_t>(s.Misc.VirtualSize)
                                 : static_cast<size_t>(s.SizeOfRawData));
    if (s.VirtualAddress + bytes > image->size() ||
        s.PointerToRawData + bytes > raw.size()) {
      return false;
    }
    std::memcpy(image->data() + s.VirtualAddress,
                raw.data() + s.PointerToRawData, bytes);
  }
  return true;
}

int ProbeSamples() {
  char* list = nullptr;
  size_t list_len = 0u;
  if (_dupenv_s(&list, &list_len, "FUSHI_ENTISGLS_SAMPLE") != 0 ||
      list == nullptr) {
    return 0;
  }
  int failures = 0;
  std::string paths(list);
  free(list);
  size_t start = 0u;
  while (start <= paths.size()) {
    const size_t end = paths.find(';', start);
    const std::string path =
        paths.substr(start, end == std::string::npos ? std::string::npos
                                                     : end - start);
    start = end == std::string::npos ? paths.size() + 1u : end + 1u;
    if (path.empty()) continue;
    std::vector<uint8_t> image;
    if (!LoadByRva(path.c_str(), &image)) {
      std::printf("probe %s: not a PE32 image\n", path.c_str());
      continue;
    }
    eg::ImageView view;
    const bool pe =
        fushi_voice_hook::EntisGlsImageView(image.data(), image.size(), &view);
    const bool identity = pe && eg::HasEntisExports(view);
    eg::Sites sites;
    const eg::SiteResult result =
        pe ? eg::ResolveSites(view, &sites) : eg::SiteResult::kNoExports;
    std::printf(
        "probe %s: identity=%d result=%u add=+0x%x clear=+0x%x "
        "process=+0x%x getter=+0x%x handlers text=+0x%x xml=+0x%x "
        "clear=+0x%x\n",
        path.c_str(), identity ? 1 : 0, static_cast<unsigned>(result),
        sites.add_message, sites.clear_message, sites.process, sites.getter,
        sites.text_handler, sites.xml_handler, sites.clear_handler);
    // Identity and resolution must agree: an EntisGLS image that does not
    // resolve, or a resolved non-EntisGLS image, is a failure to look at.
    if (identity != (result == eg::SiteResult::kResolved)) ++failures;
  }
  return failures;
}

}  // namespace

int main() {
  TestResolvesSyntheticImage();
  TestRefusesWithoutExports();
  TestRefusesAmbiguousRegistration();
  TestRefusesXmlPathThatAddsElsewhere();
  TestRefusesGetterMismatch();
  TestRefusesUnprovenNodeLayout();
  TestRefusesOtherEngineImage();
  TestPlainTextNode();
  TestXmlDocumentWithRubyAndBreaks();
  TestNestedElementsAndNullChild();
  TestFaultAndBounds();
  TestUnitPublishedAfterQuietTick();
  TestClickUnitsOnOnePage();
  TestClearStartsNewPage();
  TestUnitWipedWithinStepIsDropped();
  TestSpritesAreIndependent();
  TestNeverClearedPageIsBounded();
  const int probe_failures = ProbeSamples();
  if (probe_failures != 0) {
    std::printf("entisgls site probe: %d mismatch(es)\n", probe_failures);
    return 1;
  }
  std::printf("entisgls adapter tests passed\n");
  return 0;
}
