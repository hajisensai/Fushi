// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "../hook/adapters/luca_lookup_core.h"
#include "../hook/adapters/luca_profile.h"
#include "../hook/adapters/luca_text_core.h"
#include "../hook/luca_pak.h"

namespace luca = fushi_voice_hook::luca;

namespace {

void PutU32(std::vector<uint8_t>* out, size_t at, uint32_t value) {
  if (out->size() < at + 4u) out->resize(at + 4u);
  std::memcpy(out->data() + at, &value, sizeof(value));
}

// A PAK with `count` members of `member_bytes` each, index at `index_start`.
std::vector<uint8_t> MakePak(uint32_t count, uint32_t id_start,
                             uint32_t index_start, uint32_t flags,
                             uint32_t member_bytes) {
  constexpr uint32_t kBlock = 0x800u;
  const uint32_t data_start =
      ((index_start + 8u * count + kBlock - 1u) / kBlock) * kBlock;
  std::vector<uint8_t> pak(data_start, 0u);
  PutU32(&pak, 0x00, data_start);
  PutU32(&pak, 0x04, count);
  PutU32(&pak, 0x08, id_start);
  PutU32(&pak, 0x0C, kBlock);
  PutU32(&pak, 0x20, flags);
  uint32_t offset = data_start;
  for (uint32_t i = 0; i < count; ++i) {
    PutU32(&pak, index_start + 8u * i, offset / kBlock);
    PutU32(&pak, index_start + 8u * i + 4u, member_bytes);
    offset += ((member_bytes + kBlock - 1u) / kBlock) * kBlock;
  }
  pak.resize(offset, 0u);
  return pak;
}

std::vector<uint8_t> MakeNamedPak(uint32_t count, uint32_t index_start) {
  std::vector<uint8_t> pak = MakePak(count, 55001u, index_start, 0u, 100u);
  const uint32_t names_start = index_start + count * 8u;
  PutU32(&pak, index_start - 4u, names_start);
  for (uint32_t i = 0u; i < count; ++i) {
    pak[names_start + i * 2u] = 'A';
    pak[names_start + i * 2u + 1u] = 0u;
  }
  PutU32(&pak, 0x24u, names_start + count * 2u);
  return pak;
}

// One complete single-page Ogg stream carrying a Vorbis identification
// header for `channels` channels.
std::vector<uint8_t> MakeOgg(uint8_t channels) {
  std::vector<uint8_t> body(30u, 0u);
  body[0] = 0x01;
  std::memcpy(body.data() + 1, "vorbis", 6);
  body[11] = channels;
  PutU32(&body, 12u, 48000u);
  std::vector<uint8_t> page = {'O', 'g', 'g', 'S', 0, 0x06};
  page.resize(27u, 0u);
  page[14] = 0x2A;  // serial
  page[26] = 1;     // one segment
  page.push_back(static_cast<uint8_t>(body.size()));
  page.insert(page.end(), body.begin(), body.end());
  return page;
}

std::vector<uint8_t> MakeOggPak(const std::vector<uint32_t>& rates,
                                uint8_t channels) {
  std::vector<uint8_t> member(luca::kOggPakMagic,
                              luca::kOggPakMagic + luca::kOggPakMagicBytes);
  member[6] = 0u;
  for (const uint32_t rate : rates) {
    const std::vector<uint8_t> ogg = MakeOgg(channels);
    const size_t at = member.size();
    PutU32(&member, at, rate);
    PutU32(&member, at + 4u, static_cast<uint32_t>(ogg.size()));
    member.insert(member.end(), ogg.begin(), ogg.end());
  }
  return member;
}

void TestPakIndex() {
  for (const uint32_t start : {0x28u, 0x2Cu}) {
    const std::vector<uint8_t> pak = MakePak(3u, 65000u, start, 0u, 100u);
    luca::PakIndex index;
    std::vector<luca::PakEntry> entries;
    assert(luca::ParsePakIndex(pak.data(), pak.size(), pak.size(), &index,
                               &entries) == luca::PakIndexResult::kValid);
    assert(index.index_start == start);
    assert(entries.size() == 3u && entries[0].offset == index.data_start);
    assert(luca::PakMemberForId(index, 65000u) == 0);
    assert(luca::PakMemberForId(index, 65002u) == 2);
    assert(luca::PakMemberForId(index, 65003u) == -1);
    assert(luca::PakMemberForId(index, 1u) == -1);
  }
  // Nonzero reserved bytes, a member outside the file and a first member
  // that is not at data_start are not Luca archives.
  std::vector<uint8_t> pak = MakePak(2u, 1u, 0x2Cu, 0u, 100u);
  std::vector<uint8_t> bad = pak;
  bad[0x14] = 1u;
  assert(luca::ParsePakIndex(bad.data(), bad.size(), bad.size(), nullptr,
                             nullptr) == luca::PakIndexResult::kBadHeader);
  assert(luca::ParsePakIndex(pak.data(), pak.size(), pak.size() - 0x900u,
                             nullptr, nullptr) != luca::PakIndexResult::kValid);
  bad = pak;
  PutU32(&bad, 0x2C, 99u);
  assert(luca::ParsePakIndex(bad.data(), bad.size(), bad.size(), nullptr,
                             nullptr) == luca::PakIndexResult::kNoLayout);
}

void TestOggPak() {
  const std::vector<uint8_t> mono = MakeOggPak({44100u, 48000u}, 1u);
  std::vector<luca::OggPakStream> streams;
  assert(luca::ParseOggPakMember(mono.data(), mono.size(), &streams));
  assert(streams.size() == 2u);
  const luca::OggPakStream* pick = luca::PickOggPakStream(streams, 0u);
  assert(pick != nullptr && pick->sample_rate == 48000u);
  assert(luca::PickOggPakStream(streams, 44100u)->sample_rate == 44100u);
  assert(luca::OggVorbisChannels(mono.data() + pick->offset, pick->length) ==
         1u);
  const std::vector<uint8_t> stereo = MakeOggPak({44100u}, 2u);
  assert(luca::ParseOggPakMember(stereo.data(), stereo.size(), &streams));
  assert(luca::OggVorbisChannels(stereo.data() + streams[0].offset,
                                 streams[0].length) == 2u);
  // Trailing bytes, a truncated stream and a wrong magic are rejected.
  std::vector<uint8_t> bad = mono;
  bad.push_back(0u);
  assert(!luca::ParseOggPakMember(bad.data(), bad.size(), &streams));
  bad = mono;
  bad.pop_back();
  assert(!luca::ParseOggPakMember(bad.data(), bad.size(), &streams));
  bad = mono;
  bad[0] = 'X';
  assert(!luca::ParseOggPakMember(bad.data(), bad.size(), &streams));
}

void TestNamedPakIndex() {
  for (const uint32_t start : {0x2Cu, 0x34u, 0x38u, 0x40u, 0x100u}) {
    const std::vector<uint8_t> pak = MakeNamedPak(3u, start);
    luca::PakIndex index;
    std::vector<luca::PakEntry> entries;
    assert(luca::ParsePakHeader(pak.data(), pak.size(), pak.size(), &index));
    assert(luca::HasNamedPakIndex(pak.data(), pak.size(), index, start));
    assert(luca::ParsePakIndex(pak.data(), pak.size(), pak.size(), &index,
                               &entries) == luca::PakIndexResult::kValid);
    assert(index.index_start == start && entries.size() == 3u);
    assert(luca::PakMemberForId(index, 55003u) == 2);
  }
  const std::vector<uint8_t> pak = MakeNamedPak(3u, 0x38u);
  for (const uint32_t field : {0x24u, 0x34u}) {
    std::vector<uint8_t> bad = pak;
    PutU32(&bad, field, 0xFFFFu);
    assert(luca::ParsePakIndex(bad.data(), bad.size(), bad.size(), nullptr,
                               nullptr) == luca::PakIndexResult::kNoLayout);
  }
  std::vector<uint8_t> bad = pak;
  bad[0x38u + 3u * 8u] = 0u;  // empty name
  assert(luca::ParsePakIndex(bad.data(), bad.size(), bad.size(), nullptr,
                             nullptr) == luca::PakIndexResult::kNoLayout);
  bad = pak;
  bad[0x38u + 3u * 8u + 5u] = 'Z';  // missing final NUL
  assert(luca::ParsePakIndex(bad.data(), bad.size(), bad.size(), nullptr,
                             nullptr) == luca::PakIndexResult::kNoLayout);
  bad = pak;
  PutU32(&bad, 0x38u + 8u, 1u);  // overlapping second member
  assert(luca::ParsePakIndex(bad.data(), bad.size(), bad.size(), nullptr,
                             nullptr) == luca::PakIndexResult::kNoLayout);
  bad = MakeNamedPak(1u, 0x38u);
  // A legacy table and a named table both pass but name different ranges.
  // Header extension must not silently override a valid legacy reading.
  PutU32(&bad, 0x28u, 1u);
  PutU32(&bad, 0x2Cu, 80u);
  assert(luca::ParsePakIndex(bad.data(), bad.size(), bad.size(), nullptr,
                             nullptr) == luca::PakIndexResult::kAmbiguousLayout);
}

void TestDirectOgg() {
  const std::vector<uint8_t> mono = MakeOgg(1u);
  luca::OggPakStream stream;
  assert(luca::ParseDirectOggMember(mono.data(), mono.size(), &stream));
  assert(stream.offset == 0u && stream.length == mono.size() &&
          stream.sample_rate == 48000u);
  const std::vector<uint8_t> stereo = MakeOgg(2u);
  assert(luca::ParseDirectOggMember(stereo.data(), stereo.size(), &stream));
  assert(luca::OggVorbisChannels(stereo.data(), stereo.size()) == 2u);
  std::vector<uint8_t> bad = mono;
  bad.push_back(0u);
  assert(!luca::ParseDirectOggMember(bad.data(), bad.size(), &stream));
  bad = mono;
  bad.pop_back();
  assert(!luca::ParseDirectOggMember(bad.data(), bad.size(), &stream));
  bad = mono;
  bad[5] = 0x02u;  // no EOS
  assert(!luca::ParseDirectOggMember(bad.data(), bad.size(), &stream));
  bad = mono;
  bad[28] = 3u;  // not a Vorbis identification packet
  assert(!luca::ParseDirectOggMember(bad.data(), bad.size(), &stream));
  bad = mono;
  PutU32(&bad, 40u, 7999u);
  assert(!luca::ParseDirectOggMember(bad.data(), bad.size(), &stream));
  const std::vector<uint8_t> container = MakeOggPak({48000u}, 1u);
  assert(!luca::ParseDirectOggMember(container.data(), container.size(), &stream));
}

// MESSAGE operand shape at `at`, readers at `u16` and `str` (all RVAs inside
// one span starting at RVA 0).
std::vector<uint8_t> MakeMessageCode(uint32_t at, uint32_t u16, uint32_t str) {
  std::vector<uint8_t> code(0x400u, 0xCCu);
  // Readers: a `ret 4` close to their entry.
  for (const uint32_t reader : {u16, str}) {
    code[reader] = 0x51;
    code[reader + 1u] = 0xC2;
    code[reader + 2u] = 0x04;
    code[reader + 3u] = 0x00;
  }
  for (size_t i = 0; i < luca::kMessageOperandShapeBytes; ++i) {
    const int16_t want = luca::kMessageOperandShape[i];
    code[at + i] = want >= 0 ? static_cast<uint8_t>(want) : 0x11u;
  }
  const int32_t rel_u16 =
      static_cast<int32_t>(u16) - static_cast<int32_t>(at + 5u);
  const int32_t rel_str = static_cast<int32_t>(str) -
                          static_cast<int32_t>(at + luca::kReadStringCallOffset + 5u);
  std::memcpy(code.data() + at + 1u, &rel_u16, 4);
  std::memcpy(code.data() + at + luca::kReadStringCallOffset + 1u, &rel_str, 4);
  return code;
}

void TestMessageSites() {
  // Readers 0x160 apart, so each reader's `ret 4` window holds only its own.
  const std::vector<uint8_t> code = MakeMessageCode(0x300u, 0x20u, 0x180u);
  luca::CodeSpan span{code.data(), code.size(), 0u};
  luca::MessageSites sites;
  assert(luca::ResolveMessageSites(&span, 1u, &sites) ==
         luca::MessageSiteResult::kResolved);
  assert(sites.read_u16 == 0x20u && sites.read_string == 0x180u);
  assert(sites.voice_return == 0x305u);
  assert(sites.record_return == 0x300u + luca::kReadStringCallOffset + 5u);
  // Two copies are ambiguous; none is missing.
  std::vector<uint8_t> twice = code;
  std::memcpy(twice.data() + 0x380u, code.data() + 0x300u,
              luca::kMessageOperandShapeBytes);
  luca::CodeSpan twice_span{twice.data(), twice.size(), 0u};
  assert(luca::ResolveMessageSites(&twice_span, 1u, &sites) ==
         luca::MessageSiteResult::kAmbiguous);
  std::vector<uint8_t> none(0x400u, 0xCCu);
  luca::CodeSpan none_span{none.data(), none.size(), 0u};
  assert(luca::ResolveMessageSites(&none_span, 1u, &sites) ==
         luca::MessageSiteResult::kMissing);
  // A reader without `ret 4` (not the VM's operand reader) is rejected.
  std::vector<uint8_t> wrong = code;
  wrong[0x21] = 0xC3;
  luca::CodeSpan wrong_span{wrong.data(), wrong.size(), 0u};
  assert(luca::ResolveMessageSites(&wrong_span, 1u, &sites) ==
         luca::MessageSiteResult::kBadTarget);
}

void TestMessageRecords() {
  luca::MessageText t = luca::DecodeMessageRecord(L"`太郎@「おはよう」");
  assert(t.role && t.speaker == L"太郎" && t.body == L"「おはよう」");
  t = luca::DecodeMessageRecord(L"@「ねえ、それは」");
  assert(t.role && t.speaker.empty() && t.body == L"「ねえ、それは」");
  t = luca::DecodeMessageRecord(L"もう片方は、$K30袴$K0姿の男。");
  assert(!t.role && t.body == L"もう片方は、袴姿の男。");
  t = luca::DecodeMessageRecord(L"`@x");  // empty speaker: narration as is
  assert(!t.role && t.body == L"`@x");
  const std::wstring records[] = {L"`花子@「そこ」", L"Hanako: \"There.\""};
  assert(luca::PickJapaneseRecord(records, 2u) == 0u);
  const std::wstring english[] = {L"Hello", L"World"};
  assert(luca::PickJapaneseRecord(english, 2u) == luca::kMessageRecordCount);

  // Newer named-at records are explicitly enabled; the default retains the
  // older unnamed-at behavior rather than altering the x86 contract.
  t = luca::DecodeMessageRecord(L"@太郎@「合成例」");
  assert(t.role && t.speaker.empty() && t.body == L"太郎@「合成例」");
  t = luca::DecodeMessageRecord(L"@太郎@「合成例」", true);
  assert(t.role && t.speaker == L"太郎" && t.body == L"「合成例」");
  t = luca::DecodeMessageRecord(L"@「名前なし」", true);
  assert(t.role && t.speaker.empty() && t.body == L"「名前なし」");
  t = luca::DecodeMessageRecord(L"@Ａ@…", true);
  assert(t.role && t.speaker == L"Ａ" && t.body == L"…");
  t = luca::DecodeMessageRecord(L"@太郎@$K30合成$K0", true);
  assert(t.role && t.speaker == L"太郎" && t.body == L"合成");
  t = luca::DecodeMessageRecord(L"`太郎@「旧形式」", true);
  assert(t.role && t.speaker == L"太郎" && t.body == L"「旧形式」");
  t = luca::DecodeMessageRecord(L"@@本文", true);
  assert(t.role && t.speaker.empty() && t.body == L"@本文");
  t = luca::DecodeMessageRecord(L"@太郎@", true);
  assert(t.role && t.speaker.empty() && t.body == L"太郎@");
  t = luca::DecodeMessageRecord(L"@悪\t名@本文", true);
  assert(t.role && t.speaker.empty() && t.body == L"悪\t名@本文");
  t = luca::DecodeMessageRecord(L"@悪`名@本文", true);
  assert(t.role && t.speaker.empty() && t.body == L"悪`名@本文");
  t = luca::DecodeMessageRecord(L"@悪\x7F名@本文", true);
  assert(t.role && t.speaker.empty() && t.body == L"悪\x7F名@本文");
  t = luca::DecodeMessageRecord(L"@", true);
  assert(!t.role && t.speaker.empty() && t.body == L"@");
  t = luca::DecodeMessageRecord(L"普通の本文$n次行", true);
  assert(!t.role && t.body == L"普通の本文$n次行");
  t = luca::DecodeMessageRecord(L"", true);
  assert(!t.role && t.body.empty());
}

std::vector<uint8_t> MakeLayoutCode(uint32_t at, bool with_fields) {
  std::vector<uint8_t> code(0x1400u, 0x90u);
  for (size_t i = 0; i < luca::kLayoutPrologueBytes; ++i) {
    const int16_t want = luca::kLayoutPrologueShape[i];
    code[at + i] = want >= 0 ? static_cast<uint8_t>(want) : 0x10u;
  }
  for (uint32_t b = 0; b < luca::kLayoutResetBlocks; ++b) {
    const size_t block =
        at + luca::kLayoutPrologueBytes + luca::kLayoutResetStride * b;
    for (size_t i = 0; i < luca::kLayoutResetBytes; ++i) {
      const int16_t want = luca::kLayoutResetShape[i];
      code[block + i] = want >= 0 ? static_cast<uint8_t>(want) : 0x02u;
    }
  }
  if (with_fields) {
    const uint8_t fields[] = {
        0x8B, 0x77, 0x28,                    // mov esi, [edi+0x28]
        0x8B, 0x97, 0x1C, 0x01, 0x00, 0x00,  // mov edx, [edi+0x11c]
        0x8B, 0x8F, 0x7C, 0x01, 0x00, 0x00,  // mov ecx, [edi+0x17c]
        0x3B, 0x47, 0x6C,                    // cmp eax, [edi+0x6c]
        0x66, 0x0F, 0x6E, 0x47, 0x4C,        // movd xmm0, [edi+0x4c]
        0x66, 0x0F, 0x6E, 0x47, 0x50,        // movd xmm0, [edi+0x50]
    };
    std::memcpy(code.data() + at + 0x300u, fields, sizeof(fields));
  }
  return code;
}

void TestLayoutSite() {
  std::vector<uint8_t> code = MakeLayoutCode(0x100u, true);
  luca::CodeSpan span{code.data(), code.size(), 0x7000u};
  uint32_t rva = 0u;
  assert(luca::ResolveLayoutSite(&span, 1u, &rva) ==
         luca::LayoutSiteResult::kResolved);
  assert(rva == 0x7100u);
  // The shape alone, without the model's fields, fails closed.
  std::vector<uint8_t> bare = MakeLayoutCode(0x100u, false);
  luca::CodeSpan bare_span{bare.data(), bare.size(), 0u};
  assert(luca::ResolveLayoutSite(&bare_span, 1u, &rva) ==
         luca::LayoutSiteResult::kFieldsMismatch);
  // Three reset blocks are not the layout routine.
  std::vector<uint8_t> short_code = code;
  short_code[0x100u + luca::kLayoutPrologueBytes +
             luca::kLayoutResetStride * 3u] = 0x90u;
  luca::CodeSpan short_span{short_code.data(), short_code.size(), 0u};
  assert(luca::ResolveLayoutSite(&short_span, 1u, &rva) ==
         luca::LayoutSiteResult::kMissing);
}

luca::Row MakeRow(int32_t offset_y, const std::wstring& text, int16_t x0) {
  luca::Row row;
  row.offset_y = offset_y;
  int16_t x = x0;
  for (const wchar_t unit : text) {
    const int16_t w = unit < 0x100 ? 15 : 30;
    row.records.push_back({static_cast<uint16_t>(unit), x, w, 30});
    x = static_cast<int16_t>(x + w);
  }
  return row;
}

void TestModel() {
  const luca::Row rows[] = {MakeRow(0, L"「…あたらし", 0),
                            MakeRow(43, L"いほんかな」", 0)};
  std::vector<luca::LineGlyph> glyphs;
  assert(luca::MapRowsToLine(rows, 2u, 190, 576, L"「…あたらしいほんかな」",
                             &glyphs));
  assert(glyphs.size() == 12u);
  assert(glyphs[0].source_index == 0u && glyphs[0].rect.x == 190 &&
         glyphs[0].rect.w == 30 && glyphs[0].rect.y == 576);
  assert(glyphs[1].rect.x == 220);
  assert(glyphs[6].source_index == 6u && glyphs[6].rect.y == 576 + 43);
  // Whitespace in the line that the engine does not lay out is skipped.
  assert(luca::MapRowsToLine(rows, 2u, 0, 0, L"「…あたらし\nいほんかな」",
                             &glyphs));
  assert(glyphs[6].source_index == 7u);
  // A different line, a missing tail or an extra glyph fail closed.
  assert(!luca::MapRowsToLine(rows, 2u, 0, 0, L"「…あたらしいほんかな」！",
                              &glyphs));
  assert(!luca::MapRowsToLine(rows, 1u, 0, 0, L"「…あたらしいほんかな」",
                              &glyphs));
  assert(!luca::MapRowsToLine(rows, 2u, 0, 0, L"「…あたらそいほんかな」",
                              &glyphs));

  // 1280x720 design shown 1:1.75 on a 2240x1260 client; pillarboxed on 4:3.
  luca::Projection p;
  assert(luca::MakeProjection(1280, 720, 2240, 1260, &p));
  luca::DesignRect r = luca::ProjectRect({190, 576, 15, 30}, p);
  assert(r.x == 333 && r.y == 1008 && r.w == 26 && r.h == 53);
  assert(luca::MakeProjection(1280, 720, 1280, 960, &p));
  assert(p.offset_x == 0.0 && p.offset_y == 120.0);
  int32_t dx = 0, dy = 0;
  assert(luca::ClientToDesign(200, 700, p, 1280, 720, &dx, &dy) &&
         dx == 200 && dy == 580);
  assert(!luca::ClientToDesign(200, 50, p, 1280, 720, &dx, &dy));

  size_t hit = 0u;
  assert(luca::MapRowsToLine(rows, 2u, 190, 576, L"「…あたらしいほんかな」",
                             &glyphs));
  assert(luca::HitTestGlyphs(glyphs.data(), glyphs.size(), 225, 590, &hit) &&
         hit == 1u);
  assert(luca::HitTestGlyphs(glyphs.data(), glyphs.size(), 200, 625, &hit) &&
         hit == 6u);
  assert(!luca::HitTestGlyphs(glyphs.data(), glyphs.size(), 100, 590, &hit));
}

void TestClaim() {
  luca::ClaimState claim;
  // An eligible fresh press is owned and masked through its release.
  auto d = luca::DecideLeftButtonSample(0x8001u, true, &claim);
  assert(d.submit && d.mask && claim.owned);
  d = luca::DecideLeftButtonSample(0x8000u, false, &claim);
  assert(!d.submit && d.mask);
  d = luca::DecideLeftButtonSample(0x0001u, false, &claim);
  assert(!d.submit && d.mask && !claim.owned);
  d = luca::DecideLeftButtonSample(0x0000u, false, &claim);
  assert(!d.submit && !d.mask);
  // An ineligible press passes through untouched.
  d = luca::DecideLeftButtonSample(0x8001u, false, &claim);
  assert(!d.submit && !d.mask && !claim.owned);
  assert(!luca::IsFreshPress(0x8000u, claim));
  d = luca::DecideLeftButtonSample(0x0000u, false, &claim);
  assert(luca::IsFreshPress(0x8000u, claim));
}

void TestSystemCnf() {
  const std::string cnf =
      "TARGET_PLATFORM\tWIN32\r\nCOMPANY\t\t\"X\"\r\nSCREEN_WIDTH\t1280\r\n"
      "SCREEN_HEIGHT\t720\r\n";
  assert(fushi_voice_hook::IsLucaSystemCnf(cnf));
  int32_t w = 0, h = 0;
  assert(fushi_voice_hook::LucaSystemCnfInt(cnf, "SCREEN_WIDTH", &w) &&
         w == 1280);
  assert(fushi_voice_hook::LucaSystemCnfInt(cnf, "SCREEN_HEIGHT", &h) &&
         h == 720);
  assert(!fushi_voice_hook::IsLucaSystemCnf("[System]\nWidth=1280\n"));
  assert(!fushi_voice_hook::IsLucaSystemCnf("XTARGET_PLATFORM\tWIN32\n"));
}

}  // namespace

void TestShift() {
  luca::ShiftState shift;
  // The first sample only seeds: a Shift held (or tapped) while lookup was
  // off never replays.
  assert(!luca::ConsumeShiftSample(0x8001u, &shift));
  assert(!luca::ConsumeShiftSample(0x8000u, &shift));  // still held
  assert(!luca::ConsumeShiftSample(0x0000u, &shift));  // released
  assert(luca::ConsumeShiftSample(0x8001u, &shift));   // down edge
  assert(!luca::ConsumeShiftSample(0x8000u, &shift));  // held: once only
  assert(!luca::ConsumeShiftSample(0x0000u, &shift));
  // A tap shorter than the poll: up now, pressed-since bit set.
  assert(luca::ConsumeShiftSample(0x0001u, &shift));
  assert(!luca::ConsumeShiftSample(0x0000u, &shift));
  luca::ResetShiftState(&shift);
  assert(!luca::ConsumeShiftSample(0x0001u, &shift));  // reseeded
  assert(!luca::ConsumeShiftSample(0x0000u, &shift));
}

int main() {
  TestPakIndex();
  TestNamedPakIndex();
  TestOggPak();
  TestDirectOgg();
  TestMessageSites();
  TestMessageRecords();
  TestLayoutSite();
  TestModel();
  TestClaim();
  TestShift();
  TestSystemCnf();
  // A directory without system.cnf is not LucaSystem.
  assert(!fushi_voice_hook::MatchesLucaLayout(L"C:\\nonexistent-luca-dir"));
  return 0;
}
