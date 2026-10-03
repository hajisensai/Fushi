// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

// YU-RIS adapter: YPF identity (header + entries under both name-length
// tables and both offset widths), the structural site resolvers on synthetic
// x86 images (typing sites, DRAW argument ABI, mouse-button loop, layer
// placement chain, main window record, decoder input) with every fail-closed
// branch, the Ogg Vorbis channel probe, resource names, message text bounds,
// the engine line break, ruby markup, the speaker prefix, overdraw, page glyphs, suffix mapping, projection, hit
// testing and the engine-sampled click claim.  Synthetic data only: no game
// bytes, names or scripts.

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <string>
#include <vector>

#include "../hook/yuris_ypf.h"
#include "../hook/adapters/yuris_profile.h"
#include "../hook/adapters/yuris_lookup_core.h"
#include "../hook/adapters/yuris_voice_core.h"

namespace {

namespace yuris = fushi_voice_hook::yuris;
namespace yl = fushi_voice_hook::yuris_lookup;
namespace yv = fushi_voice_hook::yuris_voice;

void Put32(std::vector<uint8_t>* out, uint32_t value) {
  for (int i = 0; i < 4; ++i) out->push_back(static_cast<uint8_t>(value >> (8 * i)));
}

uint8_t EncodeLength(uint32_t length, bool swapped) {
  uint32_t stored = length;
  if (swapped) {
    for (const auto& pair : yuris::kYpfLengthSwaps) {
      if (length == pair[0]) stored = pair[1];
      if (length == pair[1]) stored = pair[0];
    }
  }
  return static_cast<uint8_t>(stored ^ 0xffu);
}

// A YPF image: header, index, members back to back (member payload is filler).
// `pad` zero bytes sit between the last entry and index_end.
std::vector<uint8_t> BuildYpf(const std::vector<std::string>& names,
                              bool swapped, uint32_t offset_bytes,
                              uint32_t pad = 0) {
  std::vector<uint8_t> index;
  size_t index_bytes = pad;
  for (const auto& name : names) index_bytes += 4 + 1 + name.size() + 10 + offset_bytes + 4;
  const uint32_t index_end = static_cast<uint32_t>(32 + index_bytes);
  uint64_t data = index_end;
  for (size_t i = 0; i < names.size(); ++i) {
    Put32(&index, 0x1000u + static_cast<uint32_t>(i));
    index.push_back(EncodeLength(static_cast<uint32_t>(names[i].size()), swapped));
    for (char c : names[i]) index.push_back(static_cast<uint8_t>(c) ^ 0xffu);
    index.push_back(6);
    index.push_back(0);
    Put32(&index, 16);
    Put32(&index, 16);
    Put32(&index, static_cast<uint32_t>(data));
    if (offset_bytes == 8) Put32(&index, 0);
    Put32(&index, 0);
    data += 16;
  }
  index.resize(index.size() + pad, 0);
  std::vector<uint8_t> out = {'Y', 'P', 'F', 0};
  Put32(&out, 500);
  Put32(&out, static_cast<uint32_t>(names.size()));
  Put32(&out, index_end);
  out.resize(32, 0);
  out.insert(out.end(), index.begin(), index.end());
  out.resize(out.size() + 16 * names.size(), 0x5a);
  return out;
}

void TestYpfIdentity() {
  // 13 and 16 are a swapped pair: the identity table misreads them.
  const std::vector<std::string> names = {"voice\\a01.ogg", "voice\\abcd.ogg",
                                          "voice\\abcdef1.ogg", "se\\x.ogg"};
  for (bool swapped : {true, false}) {
    for (uint32_t width : {4u, 8u}) {
      const std::vector<uint8_t> archive = BuildYpf(names, swapped, width);
      yuris::YpfHeader header;
      assert(yuris::ParseYpfHeader(archive.data(), archive.size(), archive.size(), &header));
      assert(header.count == 4);
      const yuris::YpfLayout layout{swapped, width};
      size_t cursor = 0;
      yuris::YpfEntry entry;
      for (const auto& name : names) {
        assert(yuris::ReadYpfEntry(archive.data() + 32, header.index_end - 32, header,
                                   layout, archive.size(), &cursor, &entry));
        assert(name == entry.name);
        assert(entry.stored_size == 16 && !entry.packed && entry.offset >= header.index_end);
      }
      assert(cursor == header.index_end - 32);
      yuris::YpfLayout resolved;
      assert(yuris::ResolveYpfLayout(archive.data(), archive.size(), header,
                                     archive.size(), &resolved) ==
             yuris::YpfIndexResult::kValid);
      assert(resolved.swapped_lengths == swapped && resolved.offset_bytes == width);
      assert(fushi_voice_hook::IsYurisArchiveHead(archive.data(), archive.size(),
                                                  archive.size()));
      // The other name-length table reads entry 1 (13 <-> 16) differently.
      const yuris::YpfLayout other{!swapped, width};
      assert(!yuris::YpfIndexParses(archive.data() + 32, header.index_end - 32,
                                    header, other, archive.size()));
      assert(!yuris::YpfLayoutsAgree(archive.data() + 32, header.index_end - 32,
                                     header, layout, other, archive.size()));
    }
  }
  {  // no length in a swapped pair: both tables pass and agree -> accepted
    const std::vector<std::string> plain = {"a.ogg", "ccc.ogg", "dddd.ogg"};  // 5, 7, 8
    const std::vector<uint8_t> archive = BuildYpf(plain, true, 4);
    yuris::YpfHeader header;
    assert(yuris::ParseYpfHeader(archive.data(), archive.size(), archive.size(), &header));
    assert(yuris::YpfIndexParses(archive.data() + 32, header.index_end - 32, header,
                                 {false, 4}, archive.size()));
    assert(yuris::YpfLayoutsAgree(archive.data() + 32, header.index_end - 32, header,
                                  {true, 4}, {false, 4}, archive.size()));
    assert(fushi_voice_hook::IsYurisArchiveHead(archive.data(), archive.size(),
                                                archive.size()));
  }
  {  // every entry is checked, not only the first four
    const std::vector<std::string> five = {"voice\\a01.ogg", "voice\\a02.ogg",
                                           "voice\\a03.ogg", "voice\\a04.ogg",
                                           "voice\\a05.ogg"};
    std::vector<uint8_t> archive = BuildYpf(five, true, 4);
    assert(fushi_voice_hook::IsYurisArchiveHead(archive.data(), archive.size(),
                                                archive.size()));
    const size_t entry = 4 + 1 + 13 + 10 + 4 + 4;
    archive[32 + 4 * entry + 4 + 1 + 13 + 1] = 7;  // entry 5: packed = 7
    assert(!fushi_voice_hook::IsYurisArchiveHead(archive.data(), archive.size(),
                                                 archive.size()));
  }
  {  // the last entry must end exactly at index_end
    const std::vector<uint8_t> padded = BuildYpf(names, true, 4, 4);
    yuris::YpfHeader header;
    assert(yuris::ParseYpfHeader(padded.data(), padded.size(), padded.size(), &header));
    assert(yuris::ResolveYpfLayout(padded.data(), padded.size(), header, padded.size(),
                                   nullptr) == yuris::YpfIndexResult::kNoLayout);
    assert(!fushi_voice_hook::IsYurisArchiveHead(padded.data(), padded.size(),
                                                 padded.size()));
    // Fewer bytes than the index: never judged.
    assert(yuris::ResolveYpfLayout(padded.data(), header.index_end - 1, header,
                                   padded.size(), nullptr) ==
           yuris::YpfIndexResult::kTruncated);
  }
  std::vector<uint8_t> magic = BuildYpf(names, true, 4);
  magic[0] = 'X';
  assert(!yuris::ParseYpfHeader(magic.data(), magic.size(), magic.size(), nullptr));
  assert(!fushi_voice_hook::IsYurisArchiveHead(magic.data(), magic.size(), magic.size()));
  std::vector<uint8_t> reserved = BuildYpf(names, true, 4);
  reserved[20] = 1;
  assert(!yuris::ParseYpfHeader(reserved.data(), reserved.size(), reserved.size(), nullptr));
  // A member past the end of the file is no archive.
  std::vector<uint8_t> cut = BuildYpf(names, true, 4);
  cut.resize(cut.size() - 1);
  assert(!fushi_voice_hook::IsYurisArchiveHead(cut.data(), cut.size(), cut.size()));
  // A 16-byte placeholder ("YPD" + spaces) is not an archive.
  const uint8_t placeholder[16] = {'Y', 'P', 'D', ' ', ' ', ' ', ' ', ' ',
                                   ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '};
  assert(!fushi_voice_hook::IsYurisArchiveHead(placeholder, 16, 16));
}

// ── synthetic x86 images ────────────────────────────────────────────────────

constexpr uint32_t kBase = 0x400000u;
constexpr uint32_t kCodeEnd = 0x6f00u;
constexpr uint32_t kTextOutSlot = 0x9000u;
constexpr uint32_t kKeyStateSlot = 0x9004u;
constexpr uint32_t kScreenToClientSlot = 0x9008u;
constexpr uint32_t kState = 0x7000u;
constexpr uint32_t kCharBuffer = 0x7100u;
constexpr uint32_t kKeyTable = 0x7200u;
constexpr uint32_t kWindowTable = 0x7500u;
constexpr uint32_t kCallbacks = 0x7600u;
constexpr uint32_t kDraw = 0x2000u;
constexpr uint32_t kRaster = 0x3000u;
constexpr uint32_t kOvOpen = 0x6600u;

struct Image {
  std::vector<uint8_t> bytes = std::vector<uint8_t>(0xa000u, 0x90u);
  void Put(uint32_t at, std::initializer_list<uint8_t> data) {
    for (uint8_t b : data) bytes[at++] = b;
  }
  void Put32At(uint32_t at, uint32_t v) {
    for (int i = 0; i < 4; ++i) bytes[at + i] = static_cast<uint8_t>(v >> (8 * i));
  }
  void Call(uint32_t at, uint32_t target) {
    bytes[at] = 0xe8;
    Put32At(at + 1, target - (at + 5));
  }
  void Nop(uint32_t at, uint32_t count) {
    for (uint32_t i = 0; i < count; ++i) bytes[at + i] = 0x90;
  }
  yl::ImageView View() const {
    yl::ImageView view;
    view.bytes = bytes.data();
    view.size = bytes.size();
    view.va_base = kBase;
    view.code[0] = {0x1000u, kCodeEnd};
    view.code_count = 1;
    return view;
  }
};

// One typing site at `at` (71 bytes): argument setup reading the message
// state (eax), `mov eax,CHARBUF; call DRAW; mov edx,[S]; add [edx+X],eax;
// add [edx+TI],2`.
void PutTypingSite(Image* image, uint32_t at, uint32_t state) {
  image->Put(at, {0x8b, 0x70, 0x64,            // mov esi,[eax+0x64]   op index
                  0x8b, 0x48, 0x38,            // mov ecx,[eax+0x38]   text
                  0x8b, 0x50, 0x60,            // mov edx,[eax+0x60]   text index
                  0x0f, 0xb6, 0x14, 0x0a,      // movzx edx,byte[edx+ecx]
                  0x88, 0x15});                // mov [CHARBUF],dl
  image->Put32At(at + 15, kBase + kCharBuffer);
  image->Put(at + 19, {0x8b, 0x50, 0x40,       // mov edx,[eax+0x40]   sizes
                       0x0f, 0xbf, 0x14, 0x72, // movsx edx,word[edx+esi*2]
                       0x89, 0x54, 0x24, 0x0c, // mov [esp+0xc],edx    size arg
                       0x8b, 0x50, 0x14,       // mov edx,[eax+0x14]   pen x
                       0x89, 0x54, 0x24, 0x20, // mov [esp+0x20],edx
                       0x8b, 0x50, 0x18,       // mov edx,[eax+0x18]   pen y
                       0x89, 0x54, 0x24, 0x24, // mov [esp+0x24],edx
                       0x89, 0x6c, 0x24, 0x2c, // mov [esp+0x2c],ebp   layer
                       0xb8});                 // mov eax,CHARBUF
  image->Put32At(at + 49, kBase + kCharBuffer);
  image->Call(at + 53, kDraw);
  image->Put(at + 58, {0x8b, 0x15});
  image->Put32At(at + 60, kBase + state);
  image->Put(at + 64, {0x01, 0x42, 0x14, 0x83, 0x42, 0x60, 0x02});
}

Image YurisImage() {
  Image image;
  image.Put(kDraw, {0x57, 0x56, 0x55, 0x53, 0x83, 0xec, 0x3c});
  image.Call(kDraw + 0x30, kRaster);
  image.Put(kRaster, {0x57, 0x56, 0x55, 0x53});
  image.Put(kRaster + 0x80, {0xff, 0x15});
  image.Put32At(kRaster + 0x82, kBase + kTextOutSlot);
  PutTypingSite(&image, 0x1100u, kState);
  PutTypingSite(&image, 0x1200u, kState);
  // push K; call [GetKeyboardState]
  image.Put(0x4000u, {0x68});
  image.Put32At(0x4001u, kBase + kKeyTable);
  image.Put(0x4005u, {0xff, 0x15});
  image.Put32At(0x4007u, kBase + kKeyStateSlot);
  // mouse-button loop
  image.Put(0x5000u, {0xbb, 0x01, 0x00, 0x00, 0x00, 0x0f, 0xb6, 0x93});
  image.Put32At(0x5008u, kBase + kKeyTable);
  image.Put(0x500cu, {0xc1, 0xfa, 0x07, 0x0f, 0xbe, 0x83});
  image.Put32At(0x5012u, kBase + 0x7300u);
  image.Put(0x5016u, {0x03, 0xc0, 0x03, 0xc0, 0x53, 0xff, 0x94, 0x90});
  image.Put32At(0x501eu, kBase + 0x7400u);
  image.Put(0x5022u, {0x59, 0x43, 0x83, 0xfb, 0x07});
  // layer chain walk (sprite +0x34, x +0x248, y +0x250, parent +0x10,
  // live +0x14)
  image.Put(0x6000u, {0x8b, 0x79, 0x34, 0x8b, 0x87, 0x48, 0x02, 0x00, 0x00,
                      0x03, 0xd0, 0x8b, 0xbf, 0x50, 0x02, 0x00, 0x00, 0x03,
                      0xf7, 0x8b, 0x49, 0x10, 0x85, 0xc9, 0x0f, 0x84, 0x00,
                      0x01, 0x00, 0x00, 0x83, 0x79, 0x14, 0x00, 0x75, 0xdc});
  // cursor mapping: mov ecx,[ebx+WT]; push edx; push [ecx+0x2a0];
  // call [ScreenToClient]; ...; cmp edx,[edi+0xc]; jge; cmp ecx,[edi+0x10]
  image.Put(0x6200u, {0x8b, 0x8b});
  image.Put32At(0x6202u, kBase + kWindowTable);
  image.Put(0x6206u, {0x52, 0xff, 0xb1, 0xa0, 0x02, 0x00, 0x00, 0xff, 0x15});
  image.Put32At(0x620fu, kBase + kScreenToClientSlot);
  image.Put(0x6230u, {0x3b, 0x57, 0x0c, 0x7d, 0x05, 0x3b, 0x4f, 0x10});
  // decoder input: read callback, table, two call sites
  image.Put(0x6400u, {0x57, 0x56, 0x55, 0x8b, 0x6c, 0x24, 0x1c, 0x8b, 0x95,
                      0x9c, 0x01, 0x00, 0x00, 0x8b, 0x85, 0xa0, 0x01, 0x00,
                      0x00, 0x3b, 0xd0, 0x7d, 0x38, 0x8b, 0x74, 0x24, 0x14,
                      0x8b, 0x4c, 0x24, 0x18, 0x0f, 0xaf, 0xf1, 0x8b, 0x8d,
                      0x60, 0x01, 0x00, 0x00});
  image.Put32At(kCallbacks, kBase + 0x6400u);
  image.Put32At(kCallbacks + 4, kBase + 0x6480u);
  image.Put32At(kCallbacks + 8, kBase + 0x64a0u);
  image.Put32At(kCallbacks + 12, kBase + 0x64c0u);
  image.Put(kOvOpen, {0x55, 0x8b, 0xec, 0x56, 0x57, 0x83, 0xec, 0x10});
  for (uint32_t site : {0x6700u, 0x6800u}) {
    image.Put(site, {0x8d, 0x15});
    image.Put32At(site + 2, kBase + kCallbacks);
    image.Call(site + 0x1c, kOvOpen);
  }
  return image;
}

void TestResolver() {
  const yl::ImportSlots imports{kTextOutSlot, kKeyStateSlot, kScreenToClientSlot};
  {
    const Image image = YurisImage();
    yl::Sites sites;
    assert(yl::ResolveSites(image.View(), imports, &sites) == yl::SiteResult::kResolved);
    assert(sites.draw == kDraw && sites.raster == kRaster);
    assert(sites.return_count == 2 && sites.returns[0] == 0x1100u + 58 &&
           sites.returns[1] == 0x1200u + 58);
    assert(sites.state_global == kState && sites.char_buffer == kCharBuffer);
    assert(sites.pen_x == 0x14 && sites.text_ptr == 0x38 && sites.text_index == 0x60);
    assert(sites.op_index == 0x64 && sites.size_array == 0x40);
    assert(sites.arg_size == 0x10 && sites.arg_x == 0x24 && sites.arg_y == 0x28 &&
           sites.arg_layer == 0x30);
    assert(sites.key_table == kKeyTable && sites.key_loop == 0x5000u);
    assert(sites.chain_sprite == 0x34 && sites.chain_parent == 0x10 &&
           sites.chain_live == 0x14 && sites.sprite_x == 0x248 && sites.sprite_y == 0x250);
    assert(sites.window_table == kWindowTable && sites.window_hwnd == 0x2a0 &&
           sites.design_w == 0x0c && sites.design_h == 0x10);
  }
  auto expect = [&imports](const Image& image, yl::SiteResult result) {
    yl::Sites sites;
    assert(yl::ResolveSites(image.View(), imports, &sites) == result);
  };
  {  // no imports
    yl::Sites sites;
    assert(yl::ResolveSites(YurisImage().View(), {}, &sites) == yl::SiteResult::kNoImports);
  }
  {  // rasteriser without TextOutA: no DRAW
    Image image = YurisImage();
    image.Nop(kRaster + 0x80, 2);
    expect(image, yl::SiteResult::kDrawMissing);
  }
  {  // a single typing site is not enough
    Image image = YurisImage();
    image.Nop(0x1200u, 72);
    expect(image, yl::SiteResult::kDrawMissing);
  }
  {  // sites disagree on the state global
    Image image = YurisImage();
    PutTypingSite(&image, 0x1200u, 0x7010u);
    expect(image, yl::SiteResult::kStateMismatch);
  }
  {  // size array not decodable
    Image image = YurisImage();
    image.Nop(0x1200u + 22, 4);
    expect(image, yl::SiteResult::kSizeArrayMissing);
  }
  {  // no text index increment anywhere
    Image image = YurisImage();
    image.Nop(0x1100u + 67, 4);
    image.Nop(0x1200u + 67, 4);
    expect(image, yl::SiteResult::kTextIndexMissing);
  }
  {  // no character-buffer load before the call
    Image image = YurisImage();
    image.Nop(0x1100u + 48, 5);
    expect(image, yl::SiteResult::kCharBufferMissing);
  }
  {  // character store unreadable: no text pointer
    Image image = YurisImage();
    image.Nop(0x1100u + 13, 2);
    image.Nop(0x1200u + 13, 2);
    expect(image, yl::SiteResult::kTextPointerMissing);
  }
  {  // the size argument is never stored: DRAW's ABI is unknown
    Image image = YurisImage();
    image.Nop(0x1100u + 26, 4);
    expect(image, yl::SiteResult::kDrawAbiMissing);
  }
  {  // two different GetKeyboardState tables
    Image image = YurisImage();
    image.Put(0x4100u, {0x68});
    image.Put32At(0x4101u, kBase + kKeyTable + 0x100u);
    image.Put(0x4105u, {0xff, 0x15});
    image.Put32At(0x4107u, kBase + kKeyStateSlot);
    expect(image, yl::SiteResult::kKeyPollMissing);
  }
  {  // mouse loop over another table
    Image image = YurisImage();
    image.Put32At(0x5008u, kBase + kKeyTable + 0x100u);
    expect(image, yl::SiteResult::kKeyLoopMissing);
  }
  {  // the chain walk does not loop back
    Image image = YurisImage();
    image.Put(0x6022u, {0x75, 0x10});
    expect(image, yl::SiteResult::kLayerChainMissing);
  }
  {  // a second chain walk: ambiguous
    Image image = YurisImage();
    const std::vector<uint8_t> walk(image.bytes.begin() + 0x6000, image.bytes.begin() + 0x6024);
    for (size_t i = 0; i < walk.size(); ++i) image.bytes[0x6100u + i] = walk[i];
    expect(image, yl::SiteResult::kLayerChainMissing);
  }
  {  // no design bounds check after the cursor mapping
    Image image = YurisImage();
    image.Nop(0x6230u, 8);
    expect(image, yl::SiteResult::kWindowMissing);
  }
  {  // a non-YU-RIS image
    expect(Image(), yl::SiteResult::kDrawMissing);
  }
}

void TestDecoderInput() {
  {
    const Image image = YurisImage();
    yv::DecoderSites sites;
    assert(yv::ResolveDecoderSites(image.View(), &sites) == yv::DecoderResult::kResolved);
    assert(sites.ov_open == kOvOpen && sites.callbacks == kCallbacks && sites.sites == 2);
    assert(sites.position == 0x19c && sites.size == 0x1a0 && sites.data == 0x160);
  }
  {  // no call site
    Image image = YurisImage();
    image.Nop(0x6700u, 2);
    image.Nop(0x6800u, 2);
    yv::DecoderSites sites;
    assert(yv::ResolveDecoderSites(image.View(), &sites) == yv::DecoderResult::kNoCallSite);
  }
  {  // two targets for the same table
    Image image = YurisImage();
    image.Call(0x6800u + 0x1c, kOvOpen + 0x20);
    yv::DecoderSites sites;
    assert(yv::ResolveDecoderSites(image.View(), &sites) == yv::DecoderResult::kAmbiguous);
  }
  {  // a read callback that is not a memory stream
    Image image = YurisImage();
    image.Put(0x6400u + 19, {0x39});  // cmp swapped
    image.Put(0x6400u + 20, {0xc2});
    yv::DecoderSites sites;
    assert(yv::ResolveDecoderSites(image.View(), &sites) ==
           yv::DecoderResult::kReadCallbackShape);
  }
}

// A minimal Ogg page carrying a Vorbis identification packet.
std::vector<uint8_t> VorbisHead(uint8_t channels, uint32_t rate) {
  std::vector<uint8_t> out = {'O', 'g', 'g', 'S', 0, 2};
  out.resize(26, 0);
  out.push_back(1);
  out.push_back(30);
  out.push_back(1);
  for (char c : std::string("vorbis")) out.push_back(static_cast<uint8_t>(c));
  Put32(&out, 0);
  out.push_back(channels);
  Put32(&out, rate);
  out.resize(out.size() + 15, 0);
  return out;
}

void TestVoiceHelpers() {
  const std::vector<uint8_t> mono = VorbisHead(1, 44100);
  const std::vector<uint8_t> stereo = VorbisHead(2, 22050);
  uint32_t rate = 0;
  assert(yv::OggVorbisChannels(mono.data(), mono.size(), &rate) == 1 && rate == 44100);
  assert(yv::OggVorbisChannels(stereo.data(), stereo.size()) == 2);
  std::vector<uint8_t> bogus = mono;
  bogus[28] = 3;
  assert(yv::OggVorbisChannels(bogus.data(), bogus.size()) == 0);
  assert(yv::OggVorbisChannels(mono.data(), 20) == 0);
  char base[64];
  assert(yv::ResourceBasename("voice\\abc\\x_01.ogg", 64, base, sizeof(base)) == 8 &&
         std::string(base) == "x_01.ogg");
  assert(yv::ResourceBasename("plain.OGG", 64, base, sizeof(base)) == 9);
  assert(yv::ResourceBasename("voice\\x.wav", 64, base, sizeof(base)) == 0);
  const char unterminated[4] = {'a', '.', 'o', 'g'};
  assert(yv::ResourceBasename(unterminated, 4, base, sizeof(base)) == 0);
  const char control[] = "a\x01.ogg";
  assert(yv::ResourceBasename(control, 64, base, sizeof(base)) == 0);
}

// ── text, page, projection, claim ───────────────────────────────────────────

void TestText() {
  const uint8_t clean[] = {0x82, 0xa0, 'a', 0x81, 0x41, 0};
  assert(yl::MessageTextLength(clean, sizeof(clean)) == 5);
  const uint8_t control[] = {0x82, 0xa0, 0x0a, 0};
  assert(yl::MessageTextLength(control, sizeof(control)) == 0);
  const uint8_t dangling[] = {'a', 0x82};
  assert(yl::MessageTextLength(dangling, sizeof(dangling)) == 0);
  const uint8_t unterminated[] = {'a', 'b', 'c'};
  assert(yl::MessageTextLength(unterminated, sizeof(unterminated)) == 0);
  // The engine line break 0xEFF0 is dropped; other undefined codes fail.
  const uint8_t two_lines[] = {0x82, 0xa0, 0xef, 0xf0, 0x82, 0xa2};
  assert(yl::DecodeMessageText(two_lines, sizeof(two_lines)) == L"\x3042\x3044");
  const uint8_t undefined[] = {0x82, 0xa0, 0xef, 0xf1};
  assert(yl::DecodeMessageText(undefined, sizeof(undefined)).empty());
  const uint8_t cut[] = {0x82, 0xa0, 0x82};
  assert(yl::DecodeMessageText(cut, sizeof(cut)).empty());
  // Ruby groups keep their base; malformed groups stay as they are.
  bool ruby = false;
  const std::wstring grouped = L"\x226a\x53f6\xff0f\x304b\x306a\x3048\x226b\x2026\x53f6";
  assert(yl::StripRubyMarkup(grouped, &ruby) == L"\x53f6\x2026\x53f6" && ruby);
  const std::wstring plain = L"\x3042\x3044";
  assert(yl::StripRubyMarkup(plain, &ruby) == plain && !ruby);
  const std::wstring open_only = L"\x226a\x53f6\xff0f\x304b";
  assert(yl::StripRubyMarkup(open_only, &ruby) == open_only && !ruby);
  const std::wstring no_base = L"\x226a\xff0f\x304b\x226b";
  assert(yl::StripRubyMarkup(no_base, &ruby) == no_base && !ruby);
  // PREFIX「line」 is only a shape candidate; plain text and bare quotes are not.
  const std::wstring spoken = L"\xff1f\xff1f\xff1f\xff0f\x53f6\x300c\x6075\x300d";
  assert(yl::SpeakerPrefixCandidate(spoken.data(), spoken.size()) == 5);
  const std::wstring quote = L"\x300c\x6075\x300d";
  assert(yl::SpeakerPrefixCandidate(quote.data(), quote.size()) == 0);
  const std::wstring narration = L"\x3042\x3044\x3046";
  assert(yl::SpeakerPrefixCandidate(narration.data(), narration.size()) == 0);
  const std::wstring unclosed = L"A\x300c\x6075";
  assert(yl::SpeakerPrefixCandidate(unclosed.data(), unclosed.size()) == 0);
  const std::wstring nested = L"A\x300d B\x300c\x6075\x300d";
  assert(yl::SpeakerPrefixCandidate(nested.data(), nested.size()) == 0);
  // The text lane never cuts a prefix: narration that ends in a quote
  // (そう言って「ありがとう」 / 彼女は小さく「うん」) has the same shape as a
  // speaker line and is published whole; so is a real NAME「…」 message.
  const std::wstring said =
      L"\x305d\x3046\x8a00\x3063\x3066\x300c\x3042\x308a\x304c\x3068\x3046\x300d";
  assert(yl::SpeakerPrefixCandidate(said.data(), said.size()) == 5);
  assert(yl::PublishedMessageText(said, &ruby) == said && !ruby);
  const std::wstring softly =
      L"\x5f7c\x5973\x306f\x5c0f\x3055\x304f\x300c\x3046\x3093\x300d";
  assert(yl::PublishedMessageText(softly, &ruby) == softly && !ruby);
  assert(yl::PublishedMessageText(spoken, &ruby) == spoken && !ruby);
  // Ruby is still reduced to its base.
  assert(yl::PublishedMessageText(grouped, &ruby) == L"\x53f6\x2026\x53f6" && ruby);
}

// One layer's glyph run (one row, 24 px cells) for the layer choice below.
std::vector<yl::LineGlyph> LayerRun(const std::wstring& text) {
  std::vector<yl::LineGlyph> glyphs;
  for (size_t i = 0; i < text.size(); ++i) {
    yl::LineGlyph glyph;
    glyph.codepoint = text[i];
    glyph.x = static_cast<int32_t>(24 * i);
    glyph.y = 0;
    glyph.w = 24;
    glyph.h = 24;
    glyphs.push_back(glyph);
  }
  return glyphs;
}

// Mirrors BuildYurisModel: how each layer fits the line, then the choice.
yl::LineLayerChoice ChooseFor(std::vector<std::vector<yl::LineGlyph>>* layers,
                              const std::wstring& line) {
  const size_t speaker = yl::SpeakerPrefixCandidate(line.data(), line.size());
  std::vector<yl::LayerFit> fits(layers->size());
  for (size_t k = 0; k < layers->size(); ++k) {
    auto& run = (*layers)[k];
    fits[k].line = yl::MapSelectedSuffix(run.data(), run.size(), line.data(),
                                         line.size()) < run.size();
    if (speaker == 0) continue;
    fits[k].quote = yl::MapSelectedSuffix(run.data(), run.size(), line.data() + speaker,
                                          line.size() - speaker) < run.size();
    fits[k].name = yl::GlyphRunIs(run.data(), run.size(), line.data(), speaker);
  }
  return yl::ChooseLineLayer(fits.data(), fits.size(), speaker);
}

void TestSpeakerLayers() {
  const std::wstring name = L"\x82b1\x5b50";               // 花子
  const std::wstring quote = L"\x300c\x3046\x3093\x300d";  // 「うん」
  const std::wstring line = name + quote;
  {  // narration drawn whole on the message layer: matched whole, offset 0
    const std::wstring said = L"\x5f7c\x5973\x306f" + quote;  // 彼女は「うん」
    std::vector<std::vector<yl::LineGlyph>> layers = {LayerRun(said)};
    const yl::LineLayerChoice choice = ChooseFor(&layers, said);
    assert(choice.layer == 0 && choice.source_offset == 0 && !choice.ambiguous);
  }
  {  // a name plate drawing exactly the prefix: the quote layer, offset 2
    std::vector<std::vector<yl::LineGlyph>> layers = {LayerRun(name), LayerRun(quote)};
    const yl::LineLayerChoice choice = ChooseFor(&layers, line);
    assert(choice.layer == 1 && choice.source_offset == name.size() && !choice.ambiguous);
    auto& run = layers[1];
    assert(yl::MapSelectedSuffix(run.data(), run.size(), line.data() + choice.source_offset,
                                 line.size() - choice.source_offset) == 0);
    assert(yl::ShiftSources(run.data(), run.size(), choice.source_offset));
    assert(run[0].source_index == 2 && run[3].source_index == 5);
    assert(!yl::ShiftSources(run.data(), run.size(), yl::kNoSource));
  }
  {  // the shape without a name plate: nothing matched, nothing cut
    std::vector<std::vector<yl::LineGlyph>> layers = {LayerRun(quote)};
    assert(ChooseFor(&layers, line).layer == SIZE_MAX);
  }
  {  // a layer that drew something else besides the prefix is no name plate
    std::vector<std::vector<yl::LineGlyph>> layers = {
        LayerRun(name + L"\x3042"), LayerRun(quote)};
    assert(ChooseFor(&layers, line).layer == SIZE_MAX);
    layers = {LayerRun(L"\x3042" + name), LayerRun(quote)};
    assert(ChooseFor(&layers, line).layer == SIZE_MAX);
  }
  {  // two layers holding the quote: ambiguous
    std::vector<std::vector<yl::LineGlyph>> layers = {LayerRun(name), LayerRun(quote),
                                                      LayerRun(quote)};
    const yl::LineLayerChoice choice = ChooseFor(&layers, line);
    assert(choice.layer == SIZE_MAX && choice.ambiguous);
  }
  {  // the whole line on one layer wins over a split
    std::vector<std::vector<yl::LineGlyph>> layers = {LayerRun(name), LayerRun(line)};
    const yl::LineLayerChoice choice = ChooseFor(&layers, line);
    assert(choice.layer == 1 && choice.source_offset == 0);
  }
  {  // the whole line on two layers: ambiguous
    std::vector<std::vector<yl::LineGlyph>> layers = {LayerRun(line), LayerRun(line)};
    assert(ChooseFor(&layers, line).ambiguous);
  }
  std::vector<yl::LineGlyph> empty;
  assert(!yl::GlyphRunIs(empty.data(), 0, name.data(), name.size()));
}

void TestVoiceBinding() {
  using yv::ClipFate;
  const uint64_t w = yv::kVoiceToTextWindowMs;
  ClipFate fates[4];
  {  // one clip opened before message 1: its voice
    const yv::PendingClip clips[4] = {{true, 1000, 1, 0}};
    assert(yv::SettlePendingClips(clips, 4, 1, 1200, true, fates) == 0);
    assert(fates[0] == ClipFate::kBind && fates[1] == ClipFate::kKeep);
  }
  {  // two clips before one message: only the last opened is its voice
    const yv::PendingClip clips[4] = {{true, 1100, 2, 0}, {true, 1000, 1, 0}};
    assert(yv::SettlePendingClips(clips, 4, 1, 1200, true, fates) == 0);
    assert(fates[0] == ClipFate::kBind && fates[1] == ClipFate::kOrphan);
  }
  {  // a message that was not published owns nothing and hands nothing on
    const yv::PendingClip clips[4] = {{true, 1000, 1, 0}, {true, 1100, 2, 0}};
    assert(yv::SettlePendingClips(clips, 4, 1, 1200, false, fates) == 4);
    assert(fates[0] == ClipFate::kOrphan && fates[1] == ClipFate::kOrphan);
  }
  {  // a clip opened after the message waits for the next one
    const yv::PendingClip clips[4] = {{true, 1000, 1, 0}, {true, 1300, 2, 1}};
    assert(yv::SettlePendingClips(clips, 4, 1, 1200, true, fates) == 0);
    assert(fates[0] == ClipFate::kBind && fates[1] == ClipFate::kKeep);
  }
  {  // a repeated line pushes no message: its clip and the next line's clip
     // both precede message 2; only the last one opened is bound
    const yv::PendingClip clips[4] = {{true, 2000, 1, 1}, {true, 2600, 2, 1}};
    assert(yv::SettlePendingClips(clips, 4, 2, 2800, true, fates) == 1);
    assert(fates[0] == ClipFate::kOrphan && fates[1] == ClipFate::kBind);
  }
  {  // outside the window: not this message's voice, and no later one's either
    const yv::PendingClip clips[4] = {{true, 1000, 1, 0}};
    assert(yv::SettlePendingClips(clips, 4, 1, 1000 + w + 1, true, fates) == 4);
    assert(fates[0] == ClipFate::kOrphan);
    assert(yv::SettlePendingClips(clips, 4, 1, 1000 + w, true, fates) == 0);
  }
  {  // a message stamped before the clip opened is not voiced by it
    const yv::PendingClip clips[4] = {{true, 1000, 1, 0}};
    assert(yv::SettlePendingClips(clips, 4, 1, 999, true, fates) == 4);
    assert(fates[0] == ClipFate::kOrphan);
  }
  {  // free slots are untouched
    const yv::PendingClip clips[4] = {};
    assert(yv::SettlePendingClips(clips, 4, 1, 1000, true, fates) == 4);
    assert(fates[0] == ClipFate::kKeep && fates[3] == ClipFate::kKeep);
    assert(yv::SettlePendingClips(nullptr, 4, 1, 1000, true, fates) == 4);
  }
}

void TestTouchUp() {
  using M = yl::LeftButtonMessage;
  bool pending = false;
  // A promoted touch press is evaluated; the caller claimed it.
  auto d = yl::DecideTouchMessage(M::kDown, true, false, &pending);
  assert(d.evaluate && !d.swallow);
  pending = true;
  d = yl::DecideTouchMessage(M::kUp, false, true, &pending);
  assert(d.swallow && !pending);
  // A claimed touch whose UP never arrives: the next press drops the stale
  // pending, so that press's own UP reaches the game.
  pending = true;
  d = yl::DecideTouchMessage(M::kDown, false, false, &pending);
  assert(!d.evaluate && !pending);
  d = yl::DecideTouchMessage(M::kUp, false, false, &pending);
  assert(!d.swallow);
  // A press while the key loop still owns the button is not evaluated.
  d = yl::DecideTouchMessage(M::kDown, true, true, &pending);
  assert(!d.evaluate);
  // Other messages change nothing.
  pending = true;
  d = yl::DecideTouchMessage(M::kOther, false, false, &pending);
  assert(!d.evaluate && !d.swallow && pending);
  assert(!yl::DecideTouchMessage(M::kUp, false, false, nullptr).swallow);
}

void TestPageAndHit() {
  // Overdraw: a shadow pass (x+1, y+1) then the face replace one cell.
  yl::Cell cells[8] = {};
  size_t count = 0;
  auto draw = [&cells, &count](int32_t x, int32_t y, uint8_t a, uint8_t b) {
    yl::Cell cell;
    cell.x = x;
    cell.y = y;
    cell.size = 24;
    cell.bytes[0] = a;
    cell.bytes[1] = b;
    cell.length = 2;
    const size_t at = yl::OverdrawTarget(cells, count, cell);
    if (at < count) {
      cells[at] = cell;
    } else {
      cells[count++] = cell;
    }
  };
  draw(1, 1, 0x82, 0xa0);
  draw(0, 0, 0x82, 0xa0);
  draw(25, 1, 0x82, 0xa2);
  draw(24, 0, 0x82, 0xa2);
  draw(49, 1, 0x82, 0xa4);
  draw(48, 0, 0x82, 0xa4);
  draw(48, 30, 0x82, 0xa4);  // same character on the next row: a new glyph
  assert(count == 4 && cells[0].x == 0 && cells[1].x == 24 && cells[2].x == 48 &&
         cells[3].y == 30);
  const uint32_t codepoints[4] = {L'\x3042', L'\x3044', L'\x3046', L'\x3046'};
  const uint16_t sources[4] = {0, 1, 2, 3};
  yl::LineGlyph glyphs[4];
  assert(yl::BuildPageGlyphs(cells, 4, codepoints, sources, 100, 500, glyphs, 4) == 4);
  assert(glyphs[0].x == 100 && glyphs[0].y == 500 && glyphs[0].w == 24 && glyphs[0].h == 24);
  assert(glyphs[3].y == 530 && glyphs[3].w == 24);  // last of its row: font size
  yl::Cell bad = cells[0];
  bad.size = 0;
  assert(yl::BuildPageGlyphs(&bad, 1, codepoints, sources, 0, 0, glyphs, 4) == 0);
  const std::wstring line = L"\x3044\x3046 \x3046";
  assert(yl::MapSelectedSuffix(glyphs, 4, line.data(), line.size()) == 1);
  assert(glyphs[0].source_index == yl::kNoSource && glyphs[1].source_index == 0 &&
         glyphs[3].source_index == 3);
  const std::wstring other = L"X";
  assert(yl::MapSelectedSuffix(glyphs, 4, other.data(), other.size()) == 4);
  // Projection 800x600 design -> 1600x1200 physical.
  yl::LineGlyph g = {L'a', 100, 500, 24, 24, 0, 1};
  yl::PixelRect rect;
  assert(yl::ProjectGlyph(g, 800, 600, 1600, 1200, &rect));
  assert(rect.x == 200 && rect.y == 1000 && rect.w == 48 && rect.h == 48);
  g.x = 790;
  assert(!yl::ProjectGlyph(g, 800, 600, 1600, 1200, &rect));
  assert(yl::ClientMatchesDesign(1600, 1200, 800, 600));
  assert(!yl::ClientMatchesDesign(1600, 1000, 800, 600));
  assert(!yl::ClientMatchesDesign(800, 600, 10, 10));
  int32_t x = 0, y = 0;
  assert(yl::ClientToDesign(200, 1000, 1600, 1200, 800, 600, &x, &y) && x == 100 && y == 500);
  assert(!yl::ClientToDesign(1600, 0, 1600, 1200, 800, 600, &x, &y));
  assert(yl::MapSelectedSuffix(glyphs, 4, line.data(), line.size()) == 1);
  size_t hit = 99;
  assert(yl::HitTestLine(glyphs, 4, 100 + 24 + 3, 503, &hit) && hit == 1);
  assert(!yl::HitTestLine(glyphs, 4, 101, 503, &hit));  // unmapped glyph 0
  assert(!yl::HitTestLine(glyphs, 4, 90, 490, &hit));
}

void TestClaim() {
  assert(yl::IsPromotedTouch(static_cast<LPARAM>(0xff515780u)));
  assert(yl::IsPromotedTouch(static_cast<LPARAM>(0xff515700u)));
  assert(!yl::IsPromotedTouch(0));
  assert(!yl::IsPromotedTouch(static_cast<LPARAM>(0xff515600u)));
  yl::ClaimState claim;
  auto d = yl::DecideLeftButton(0x80, false, &claim);
  assert(d.fresh_press && !d.mask && !d.submit);
  d = yl::DecideLeftButton(0x80, true, &claim);  // still held: not fresh
  assert(!d.fresh_press && !d.mask);
  d = yl::DecideLeftButton(0x00, false, &claim);
  assert(!d.mask);
  assert(yl::IsFreshPress(0x80, claim));
  d = yl::DecideLeftButton(0x81, true, &claim);
  assert(d.mask && d.submit);
  assert(!yl::IsFreshPress(0x80, claim));
  d = yl::DecideLeftButton(0x80, false, &claim);
  assert(d.mask && !d.submit);
  d = yl::DecideLeftButton(0x01, false, &claim);
  assert(!d.mask && !claim.owned);
}

}  // namespace

int main() {
  TestYpfIdentity();
  TestResolver();
  TestDecoderInput();
  TestVoiceHelpers();
  TestText();
  TestSpeakerLayers();
  TestVoiceBinding();
  TestTouchUp();
  TestPageAndHit();
  TestClaim();
  std::puts("yuris adapter tests passed");
  return 0;
}
