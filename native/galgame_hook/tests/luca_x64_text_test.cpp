// Release builds must execute every assertion in this synthetic resolver test.
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

#include "../hook/adapters/luca_x64_text_core.h"

namespace luca = fushi_voice_hook::luca;

namespace {

constexpr uint32_t kSpanRva = 0x1000u;
constexpr uint32_t kVoice = 0x80u;
constexpr uint32_t kRecord = 0x140u;
constexpr uint32_t kTail = 0x190u;
constexpr uint32_t kU16 = 0x300u;
constexpr uint32_t kString = 0x400u;
constexpr uint32_t kCountRva = 0x9000u;
constexpr uint32_t kCursorField = 0x120u;

void PutU32(std::vector<uint8_t>* code, size_t at, uint32_t value) {
  assert(at + 4u <= code->size());
  std::memcpy(code->data() + at, &value, sizeof(value));
}

void PutRelative(std::vector<uint8_t>* code, size_t operand,
                  uint32_t next, uint32_t target) {
  const int64_t displacement = int64_t{target} - next;
  assert(displacement >= INT32_MIN && displacement <= INT32_MAX);
  const int32_t rel = static_cast<int32_t>(displacement);
  std::memcpy(code->data() + operand, &rel, sizeof(rel));
}

template <size_t N>
void PutShape(std::vector<uint8_t>* code, size_t at,
               const int16_t (&shape)[N]) {
  assert(at + N <= code->size());
  for (size_t i = 0u; i < N; ++i) {
    (*code)[at + i] = shape[i] >= 0 ? static_cast<uint8_t>(shape[i]) : 0x18u;
  }
}

// Synthetic instructions only: public resolver shapes with arbitrary stack
// slots, field offset and call addresses; no game bytes or dialogue payloads.
std::vector<uint8_t> MakeCode() {
  std::vector<uint8_t> code(0x800u, 0xCCu);
  PutShape(&code, kVoice, luca::kX64VoiceShape);
  PutShape(&code, kRecord, luca::kX64RecordShape);
  PutRelative(&code, kVoice + 11u, kSpanRva + kVoice + 15u,
                kSpanRva + kU16);
  PutRelative(&code, kRecord + 32u, kSpanRva + kRecord + 36u,
                kSpanRva + kString);
  const uint8_t prefix[] = {0x44, 0x8B, 0xE6, 0x39, 0x35,
      0, 0, 0, 0, 0x0F, 0x8E, 0, 0, 0, 0, 0x90, 0x90, 0x90};
  std::memcpy(code.data() + kRecord - sizeof(prefix), prefix, sizeof(prefix));
  PutRelative(&code, kRecord - 13u, kSpanRva + kRecord - 9u, kCountRva);
  const uint8_t tail[] = {0x41, 0xFF, 0xC4, 0x44, 0x3B, 0x25,
      0, 0, 0, 0, 0x0F, 0x8C, 0, 0, 0, 0};
  std::memcpy(code.data() + kTail, tail, sizeof(tail));
  PutRelative(&code, kTail + 6u, kSpanRva + kTail + 10u, kCountRva);
  PutRelative(&code, kTail + 12u, kSpanRva + kTail + 16u, kSpanRva + kRecord);
  const uint8_t cursor_load[] = {0x48, 0x8B, 0x81, 0, 0, 0, 0};
  std::memcpy(code.data() + kU16, cursor_load, sizeof(cursor_load));
  PutU32(&code, kU16 + 3u, kCursorField);
  std::memcpy(code.data() + kString, cursor_load, sizeof(cursor_load));
  PutU32(&code, kString + 3u, kCursorField);
  const uint8_t unsigned_return[] = {0x0F, 0xB7, 0xC0, 0x48, 0x83, 0xC4, 0x20};
  std::memcpy(code.data() + kU16 + 20u, unsigned_return,
              sizeof(unsigned_return));
  const uint8_t advances_two[] = {0x4C, 0x8D, 0x40, 0x02};
  const uint8_t reads_word[] = {0x0F, 0xB7, 0x00};
  const uint8_t cursor_store[] = {0x4C, 0x89, 0x81, 0, 0, 0, 0};
  std::memcpy(code.data() + kU16 + 8u, advances_two, sizeof(advances_two));
  std::memcpy(code.data() + kU16 + 12u, reads_word, sizeof(reads_word));
  std::memcpy(code.data() + kU16 + 30u, cursor_store, sizeof(cursor_store));
  PutU32(&code, kU16 + 33u, kCursorField);
  const uint8_t encoding_tags[] = {0xC6, 0x43, 0x10, 0x02,
                                  0xC6, 0x43, 0x10, 0x03};
  std::memcpy(code.data() + kString + 8u, encoding_tags, sizeof(encoding_tags));
  return code;
}

luca::MessageSiteResult Resolve(const std::vector<uint8_t>& code,
                                 luca::X64MessageSites* sites) {
  const luca::CodeSpan span{code.data(), code.size(), kSpanRva};
  return luca::ResolveX64MessageSites(&span, 1u, sites);
}

void TestResolvedFields() {
  const std::vector<uint8_t> code = MakeCode();
  luca::X64MessageSites sites;
  assert(Resolve(code, &sites) == luca::MessageSiteResult::kResolved);
  assert(sites.readers.read_u16 == kSpanRva + kU16);
  assert(sites.readers.read_string == kSpanRva + kString);
  assert(sites.readers.voice_return == kSpanRva + kVoice + 15u);
  assert(sites.readers.record_return == kSpanRva + kRecord + 36u);
  assert(sites.record_count_rva == kCountRva);
  const luca::CodeSpan span{code.data(), code.size(), kSpanRva};
  assert(luca::X64ReadersShareCursor(&span, 1u, kSpanRva + kU16,
                                     kSpanRva + kString));
  assert(luca::ResolveX64MessageSites(nullptr, 0u, &sites) ==
          luca::MessageSiteResult::kMissing);
  assert(luca::ResolveX64MessageSites(&span, 1u, nullptr) ==
          luca::MessageSiteResult::kMissing);
  const luca::CodeSpan empty{nullptr, 100u, kSpanRva};
  assert(luca::ResolveX64MessageSites(&empty, 1u, &sites) ==
          luca::MessageSiteResult::kMissing);
}

void TestMissingAndRepeated() {
  luca::X64MessageSites sites;
  for (const uint32_t missing : {kVoice, kRecord}) {
    std::vector<uint8_t> code = MakeCode();
    code[missing] = 0x90u;
    assert(Resolve(code, &sites) == luca::MessageSiteResult::kMissing);
  }
  for (const uint32_t repeated : {kVoice, kRecord}) {
    std::vector<uint8_t> code = MakeCode();
    const size_t bytes = repeated == kVoice ? sizeof(luca::kX64VoiceShape) / 2u
                                          : sizeof(luca::kX64RecordShape) / 2u;
    std::memcpy(code.data() + 0x600u, code.data() + repeated, bytes);
    assert(Resolve(code, &sites) == luca::MessageSiteResult::kAmbiguous);
  }
  // Splitting the handler across disjoint sections is not an admitted site.
  const std::vector<uint8_t> code = MakeCode();
  const luca::CodeSpan spans[] = {
      {code.data(), 0x100u, kSpanRva},
      {code.data() + 0x100u, code.size() - 0x100u, kSpanRva + 0x100u}};
  assert(luca::ResolveX64MessageSites(spans, 2u, &sites) ==
          luca::MessageSiteResult::kBadTarget);
}

void TestReadersAndCallTargets() {
  luca::X64MessageSites sites;
  for (const uint32_t operand : {kVoice + 11u, kRecord + 32u}) {
    std::vector<uint8_t> code = MakeCode();
    PutU32(&code, operand, 0x7FFFFFFFu);
    assert(Resolve(code, &sites) == luca::MessageSiteResult::kBadTarget);
  }
  std::vector<uint8_t> code = MakeCode();
  PutU32(&code, kString + 3u, kCursorField + 8u);
  assert(Resolve(code, &sites) == luca::MessageSiteResult::kBadTarget);
  for (const uint32_t cursor : {0u, 0x10001u}) {
    code = MakeCode();
    PutU32(&code, kU16 + 3u, cursor);
    PutU32(&code, kString + 3u, cursor);
    assert(Resolve(code, &sites) == luca::MessageSiteResult::kBadTarget);
  }
  code = MakeCode();
  code[kU16 + 20u] = 0x90u;
  assert(Resolve(code, &sites) == luca::MessageSiteResult::kBadTarget);
  code = MakeCode();
  PutRelative(&code, kRecord + 32u, kSpanRva + kRecord + 36u,
                kSpanRva + 0x7F0u);  // reader window truncated at section end
  assert(Resolve(code, &sites) == luca::MessageSiteResult::kBadTarget);
}

void TestLoopBounds() {
  luca::X64MessageSites sites;
  std::vector<uint8_t> code = MakeCode();
  PutRelative(&code, kTail + 6u, kSpanRva + kTail + 10u, kCountRva + 4u);
  assert(Resolve(code, &sites) == luca::MessageSiteResult::kBadTarget);
  code = MakeCode();
  PutRelative(&code, kTail + 12u, kSpanRva + kTail + 16u,
                kSpanRva + kRecord + 1u);
  assert(Resolve(code, &sites) == luca::MessageSiteResult::kBadTarget);
  for (const uint32_t at : {kRecord - 18u, kRecord - 9u, kTail, kTail + 11u}) {
    code = MakeCode();
    code[at] = 0x90u;
    assert(Resolve(code, &sites) == luca::MessageSiteResult::kBadTarget);
  }
}

void TestReaderOperandContracts() {
  luca::X64MessageSites sites;
  for (const uint32_t at : {kU16 + 8u, kU16 + 12u, kU16 + 30u,
                            kString + 8u, kString + 12u}) {
    std::vector<uint8_t> code = MakeCode();
    code[at] = 0x90u;
    assert(Resolve(code, &sites) == luca::MessageSiteResult::kBadTarget);
  }
  std::vector<uint8_t> code = MakeCode();
  code[kU16 + 11u] = 0x04u;  // advancing by four is not an unsigned-word reader
  assert(Resolve(code, &sites) == luca::MessageSiteResult::kBadTarget);
  code = MakeCode();
  PutU32(&code, kU16 + 33u, kCursorField + 8u);  // stores another VM field
  assert(Resolve(code, &sites) == luca::MessageSiteResult::kBadTarget);
  code = MakeCode();
  code[kString + 15u] = 0x02u;  // two UTF-8 tags cannot substitute for UTF-16
  assert(Resolve(code, &sites) == luca::MessageSiteResult::kBadTarget);
  // The entire encoding discriminator body must be in the section, even if
  // both tags happen to be present in its short prefix.
  code = MakeCode();
  const luca::CodeSpan short_span{code.data(), kString + 0x23Fu, kSpanRva};
  assert(luca::ResolveX64MessageSites(&short_span, 1u, &sites) ==
          luca::MessageSiteResult::kBadTarget);
}

void TestRelativeRvas() {
  int32_t relative = -100;
  uint32_t rva = 0u;
  assert(luca::X64RelativeRva(200u, reinterpret_cast<uint8_t*>(&relative), &rva));
  assert(rva == 100u);
  assert(!luca::X64RelativeRva(100u, reinterpret_cast<uint8_t*>(&relative), &rva));
  relative = 100;
  assert(!luca::X64RelativeRva(UINT32_MAX - 10u,
                              reinterpret_cast<uint8_t*>(&relative), &rva));
}

void TestRecordViews() {
  uint32_t bytes = 0u;
  assert(luca::X64RecordByteCount(0x1000u, 0x1020u, 2u, 32u, &bytes));
  assert(bytes == 32u);
  assert(luca::X64RecordByteCount(0x1000u, 0x1020u, 3u, 32u, &bytes));
  assert(bytes == 32u);
  assert(luca::X64RecordByteCount(0x1001u, 0x1004u, 2u, 3u, &bytes));
  assert(bytes == 3u);  // UTF-8 pointers need no UTF-16 alignment
  assert(luca::X64RecordByteCount(0x1000u, 0x1000u, 3u, 0u, &bytes));
  assert(bytes == 0u);  // an empty view is distinct from an invalid pointer
  assert(!luca::X64RecordByteCount(0u, 0u, 2u, 32u, &bytes));
  assert(!luca::X64RecordByteCount(0x1020u, 0x1000u, 2u, 32u, &bytes));
  assert(!luca::X64RecordByteCount(0x1000u, 0x1021u, 2u, 32u, &bytes));
  // Packed UTF-16 can begin at an odd script address; copying an even byte
  // length into the aligned slot is valid and must not reject the whole line.
  assert(luca::X64RecordByteCount(0x1001u, 0x1021u, 3u, 32u, &bytes));
  assert(bytes == 32u);
  assert(!luca::X64RecordByteCount(0x1001u, 0x1020u, 3u, 32u, &bytes));
  assert(!luca::X64RecordByteCount(0x1000u, 0x1021u, 3u, 33u, &bytes));
  assert(!luca::X64RecordByteCount(0x1000u, UINT64_MAX, 2u, UINT32_MAX, &bytes));
  assert(!luca::X64RecordByteCount(0x1000u, 0x1020u, 2u, 32u, nullptr));
  for (const uint8_t encoding : {uint8_t{0}, uint8_t{1}, uint8_t{4}, uint8_t{255}}) {
    assert(!luca::X64RecordByteCount(0x1000u, 0x1020u, encoding, 32u, &bytes));
  }
}

void TestJapaneseRecordCalibration() {
  luca::X64JapaneseRecordSelector selector;
  constexpr uint64_t kVm = 0x12340000u;
  // Chinese first, Japanese last: the selector cannot assume slot zero.
  const std::wstring three[] = {L"`角色@测试文本", L"Speaker: sample text",
                                L"`太郎@かなの合成例"};
  assert(selector.Select(three, 3u, kVm) == 2u);
  const std::wstring punctuation[] = {L"？！", L"...", L"……"};
  const std::wstring ideographs[] = {L"中文文本", L"Synthetic", L"漢字"};
  assert(selector.Select(punctuation, 3u, kVm) == 2u);
  assert(selector.Select(ideographs, 3u, kVm) == 2u);
  selector.Reset();
  assert(selector.Select(ideographs, 3u, kVm) == 3u);
  assert(selector.Select(punctuation, 3u, kVm) == 3u);
  assert(selector.Select(three, 3u, kVm) == 2u);
  // An untranslated speaker's kana in the English record is not evidence.
  const std::wstring speaker[] = {L"`カナ名@English body", L"中文文本",
                                  L"`太郎@かな本文"};
  assert(selector.Select(speaker, 3u, kVm) == 2u);
  const std::wstring named_at_speaker[] = {L"@カナ名@English body", L"@角色@中文文本",
                                           L"@太郎@かな本文"};
  assert(selector.Select(named_at_speaker, 3u, kVm) == 2u);
  const std::wstring ambiguous[] = {L"かな", L"English", L"カナ"};
  assert(selector.Select(ambiguous, 3u, kVm) == 3u);
  assert(selector.Select(ideographs, 3u, kVm) == 3u);
  assert(selector.Select(three, 3u, kVm) == 2u);
  const std::wstring moved[] = {L"かな", L"English", L"中文文本"};
  assert(selector.Select(moved, 3u, kVm) == 3u);
  assert(selector.Select(punctuation, 3u, kVm) == 3u);
  assert(selector.Select(moved, 3u, kVm) == 0u);
  assert(selector.Select(ideographs, 3u, kVm) == 0u);
  assert(selector.Select(ideographs, 3u, kVm + 8u) == 3u);
  assert(selector.Select(three, 3u, kVm + 8u) == 2u);
  const std::wstring two[] = {L"English", L"中文文本"};
  assert(selector.Select(two, 2u, kVm + 8u) == 2u);
  assert(selector.Select(ideographs, 3u, kVm + 8u) == 3u);
  const std::wstring halfwidth[] = {L"中文文本", L"ｶﾅ", L"English"};
  assert(selector.Select(halfwidth, 3u, kVm + 8u) == 1u);
  assert(selector.Select(punctuation, 3u, kVm + 8u) == 1u);
  assert(selector.Select(nullptr, 3u, kVm + 8u) == 3u);
  assert(selector.Select(punctuation, 3u, kVm + 8u) == 3u);
  assert(selector.Select(three, 3u, 0u) == 3u);
  assert(selector.Select(three, 0u, kVm) == 0u);
  assert(selector.Select(three, luca::kMaxMessageRecords + 1u, kVm) ==
          luca::kMaxMessageRecords + 1u);
}

// The count global is zero-initialised .data at launch-time injection and
// filled during boot: zero withholds the message, it does not reject sites.
void TestRecordCountIsReadLive() {
  static_assert(luca::X64AdmittedRecordCount(0u) == 0u);
  static_assert(luca::X64AdmittedRecordCount(1u) == 1u);
  static_assert(luca::X64AdmittedRecordCount(3u) == 3u);
  static_assert(luca::X64AdmittedRecordCount(luca::kMaxMessageRecords) ==
                luca::kMaxMessageRecords);
  static_assert(luca::X64AdmittedRecordCount(luca::kMaxMessageRecords + 1u) ==
                0u);
  // Resolution never depends on the count's value, only on code shape.
  std::vector<uint8_t> code = MakeCode();
  luca::CodeSpan span{code.data(), code.size(), kSpanRva};
  luca::X64MessageSites sites;
  assert(luca::ResolveX64MessageSites(&span, 1u, &sites) ==
         luca::MessageSiteResult::kResolved);
  assert(sites.record_count_rva == kCountRva);
}

}  // namespace

int main() {
  TestResolvedFields();
  TestMissingAndRepeated();
  TestReadersAndCallTargets();
  TestReaderOperandContracts();
  TestLoopBounds();
  TestRelativeRvas();
  TestRecordViews();
  TestJapaneseRecordCalibration();
  TestRecordCountIsReadLive();
  return 0;
}
