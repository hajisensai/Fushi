// HUNEX/GGE selected Luna lane admission is deliberately stricter than the
// shared text consumer: exact thread, process, engine identity, address and raw
// tagged line. Keep assertions alive in Release CTest builds.
#undef NDEBUG

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iterator>
#include <limits>
#include <string>
#include <vector>

#include "hunex_gge_selected_text.h"

namespace {

using fushi_voice_hook::HunexGgeSelectedTextDisposition;
using fushi_voice_hook::HunexGgeSelectedTextFailure;
using fushi_voice_hook::HunexGgeSelectedTextRequest;
using fushi_voice_hook::HunexGgeSelectedTextResult;
using fushi_voice_hook::SharedHeader;
using fushi_voice_hook::TextLane;
using fushi_voice_hook::TextLaneWrite;
using fushi_voice_hook::TextSlot;

constexpr uint32_t kProcessId = 4321;
constexpr uint64_t kSelectedThread = 0x1111222233334444ull;
constexpr uint64_t kOtherThread = 0x5555666677778888ull;
constexpr uint64_t kSharedFace = 0xABCDEF01ull;
constexpr uint64_t kStoryAddress = 0x140130020ull;
constexpr wchar_t kCurrentRaw[] = L"<rよ>読</r>む";
constexpr wchar_t kFutureRaw[] = L"未来の行";

int g_failures = 0;

void Check(bool condition, const char *message) {
  if (condition)
    return;
  ++g_failures;
  std::fprintf(stderr, "FAIL: %s\n", message);
}

struct FakeMapping {
  std::vector<uint8_t> bytes;

  FakeMapping() {
    const uint64_t text_bytes = fushi_voice_hook::TextRegionBytes(
        fushi_voice_hook::kTextLaneCount, fushi_voice_hook::kTextLaneSlotCount);
    bytes.assign(static_cast<size_t>(sizeof(SharedHeader) + text_bytes), 0);
    SharedHeader *h = header();
    h->magic = fushi_voice_hook::kSharedMagic;
    h->version = fushi_voice_hook::kSharedVersion;
    h->ipc_protocol_version = fushi_voice_hook::kStableIpcVersion;
    h->luna_bridge_abi_version = fushi_voice_hook::kLunaBridgeAbiVersion;
    h->luna_vendored_version = fushi_voice_hook::kLunaVendoredVersion;
    h->text_region_offset = static_cast<uint32_t>(sizeof(SharedHeader));
    h->text_lane_count = fushi_voice_hook::kTextLaneCount;
    h->text_lane_slot_count = fushi_voice_hook::kTextLaneSlotCount;
    h->selected_text_thread_id = kSelectedThread;
  }

  SharedHeader *header() {
    return reinterpret_cast<SharedHeader *>(bytes.data());
  }
};

struct LineOptions {
  uint64_t thread_id = kSelectedThread;
  uint64_t face_id = kSharedFace;
  uint64_t thread_address = kStoryAddress;
  uint32_t process_id = kProcessId;
  uint32_t source_kind = fushi_voice_hook::kTextSourceLuna;
  uint32_t event_kind = fushi_voice_hook::kTextEventLine;
  uint32_t is_utf8 = 0;
  const char *hook_name = fushi_voice_hook::kHunexGgeLunaEngineIdentity;
};

uint64_t WriteLine(SharedHeader *header, const std::wstring &text,
                   const LineOptions &options = {}) {
  TextLaneWrite write;
  write.thread_id = options.thread_id;
  write.face_id = options.face_id;
  write.thread_address = options.thread_address;
  write.process_id = options.process_id;
  write.source_kind = options.source_kind;
  write.event_kind = options.event_kind;
  write.is_utf8 = options.is_utf8;
  write.text = text.empty() ? nullptr : text.data();
  write.byte_len = static_cast<uint32_t>(text.size() * sizeof(wchar_t));
  write.hook_name = options.hook_name;
  write.hook_code = L"ENHQ-4C@structural:WoH.exe";
  return fushi_voice_hook::WriteTextLaneEvent(
      header, 0, fushi_voice_hook::kLunaThreadPreviewCount, write);
}

HunexGgeSelectedTextRequest RequestFor(
    SharedHeader *header, const wchar_t *raw = kCurrentRaw,
    uint32_t raw_units = static_cast<uint32_t>(std::size(kCurrentRaw) - 1)) {
  HunexGgeSelectedTextRequest request;
  request.header = header;
  request.mapped_bytes =
      sizeof(SharedHeader) +
      fushi_voice_hook::TextRegionBytes(fushi_voice_hook::kTextLaneCount,
                                        fushi_voice_hook::kTextLaneSlotCount);
  request.current_process_id = kProcessId;
  request.exact_selected_thread_id = kSelectedThread;
  request.exact_thread_address = kStoryAddress;
  request.window_after_seq = 0;
  request.window_through_seq =
      fushi_voice_hook::AtomicLoadPreview64(&header->text_write_count);
  request.exact_raw_tagged_text = raw;
  request.exact_raw_tagged_text_units = raw_units;
  return request;
}

TextSlot *SelectedSlotAt(SharedHeader *header, uint64_t lane_seq) {
  TextLane *lanes = fushi_voice_hook::TextLanesOf(header);
  for (uint32_t index = 0; index < header->text_lane_count; ++index) {
    if (lanes[index].thread_id != kSelectedThread)
      continue;
    return reinterpret_cast<TextSlot *>(
        fushi_voice_hook::TextLaneSlotAt(header, index, lane_seq));
  }
  return nullptr;
}

void TestExactRawLineWinsOverNewerPrefetch() {
  FakeMapping mapping;
  const uint64_t current_seq = WriteLine(mapping.header(), kCurrentRaw);
  const uint64_t future_seq = WriteLine(mapping.header(), kFutureRaw);
  Check(current_seq != 0 && future_seq > current_seq,
        "fixture must publish current then prefetched future line");

  const HunexGgeSelectedTextResult result =
      fushi_voice_hook::ReadHunexGgeSelectedLunaText(
          RequestFor(mapping.header()));
  Check(result.disposition == HunexGgeSelectedTextDisposition::kUseExactMatch,
        "newest prefetched slot must not replace exact current raw line");
  Check(result.matched_seq == current_seq,
        "accepted sequence must be the exact current raw line");
  Check(result.text_units == std::size(kCurrentRaw) - 1 &&
            std::memcmp(result.text, kCurrentRaw,
                        sizeof(kCurrentRaw) - sizeof(wchar_t)) == 0,
        "accepted payload must remain raw tagged UTF-16");
}

void TestNoContentMatchFailsClosed() {
  FakeMapping mapping;
  WriteLine(mapping.header(), kFutureRaw);
  const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
      RequestFor(mapping.header()));
  Check(result.disposition == HunexGgeSelectedTextDisposition::kNoMatch &&
            result.failure == HunexGgeSelectedTextFailure::kNoExactRawLine,
        "a selected Luna lane is not enough without exact raw content");
}

// BUG-2133：同一个 kNoExactRawLine 必须能被候选计数分成两种根因。
// 真机 WoH 上失败码恒为 6，但「车道里一条候选都没有」与「有候选但字节不等」的处置
// 完全相反：前者查车道选择/fence 窗口，后者查文本同源性（ruby 标记、行首全角空格、
// 换行分段）。计数器是唯一能分开它们的东西，因此必须被断言钉住。
void TestNoExactRawLineIsClassifiableByCandidateCounts() {
  // ① 选定车道里确实有一条合格候选，只是字节不等 → stable_selected_events == 1。
  {
    FakeMapping mapping;
    WriteLine(mapping.header(), kFutureRaw);
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
        RequestFor(mapping.header()));
    Check(result.failure == HunexGgeSelectedTextFailure::kNoExactRawLine &&
              result.stable_selected_events == 1u &&
              result.invalid_selected_events == 0u,
          "bytes differ: exactly one stable candidate must be counted");
  }
  // ② fence 窗口把唯一那条候选排除在外 → 计数全 0，失败码相同但根因不同。
  //    上界必须仍然可见（否则报的是 kRequestShape 而非本用例要钉的 6），所以用另一条
  //    车道的事件把全局 text_write_count 推上去——这正是真机上「延迟读窗口空转」的形状。
  {
    FakeMapping mapping;
    const uint64_t target_seq = WriteLine(mapping.header(), kFutureRaw);
    LineOptions other_lane;
    other_lane.thread_id = kSelectedThread + 1u;
    WriteLine(mapping.header(), L"別の車道の行", other_lane);
    auto request = RequestFor(mapping.header());
    request.window_after_seq = target_seq;
    request.window_through_seq =
        fushi_voice_hook::AtomicLoadPreview64(
            &mapping.header()->text_write_count);
    const auto result =
        fushi_voice_hook::ReadHunexGgeSelectedLunaText(request);
    Check(result.failure == HunexGgeSelectedTextFailure::kNoExactRawLine &&
              result.stable_selected_events == 0u &&
              result.invalid_selected_events == 0u,
          "empty fence window must report zero candidates, not a byte mismatch");
  }
  // ③ 真机形态：Luna 发布带 ruby 标记的行，renderer 交来的是已去标记的显示行。
  //    两者长度就不同，memcmp 永不相等——但候选是存在的，必须计为 stable。
  {
    FakeMapping mapping;
    WriteLine(mapping.header(), L"「あれ、鍵<rし>閉</r>まったまま？");
    const wchar_t* detagged = L"「あれ、鍵閉まったまま？";
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
        RequestFor(mapping.header(), detagged,
                   static_cast<uint32_t>(wcslen(detagged))));
    Check(result.failure == HunexGgeSelectedTextFailure::kNoExactRawLine &&
              result.stable_selected_events == 1u,
          "ruby-tagged lane vs de-tagged renderer line is a byte mismatch, "
          "not an empty lane");
  }
}

void TestSameFaceSiblingNeverFallsBack() {
  FakeMapping mapping;
  WriteLine(mapping.header(), kFutureRaw);
  LineOptions sibling;
  sibling.thread_id = kOtherThread;
  sibling.face_id = kSharedFace;
  WriteLine(mapping.header(), kCurrentRaw, sibling);

  const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
      RequestFor(mapping.header()));
  Check(result.disposition == HunexGgeSelectedTextDisposition::kNoMatch,
        "same face exact text on another thread must never be admitted");
}

void TestProcessSourceIdentityAndAddressAreExact() {
  struct InvalidCase {
    LineOptions options;
    const char *message;
  };
  std::vector<InvalidCase> cases;
  {
    LineOptions value;
    value.process_id = kProcessId + 1;
    cases.push_back({value, "foreign process id must be rejected"});
  }
  {
    LineOptions value;
    value.source_kind = fushi_voice_hook::kTextSourceGdi;
    cases.push_back({value, "non-Luna source must be rejected"});
  }
  {
    LineOptions value;
    value.hook_name = "TYPEMOON";
    cases.push_back(
        {value, "engine identity is case-sensitive exact typemoon"});
  }
  {
    LineOptions value;
    value.hook_name = "typemoon-extra";
    cases.push_back({value, "engine identity must reject typemoon prefixes"});
  }
  {
    LineOptions value;
    value.thread_address = kStoryAddress + 1;
    cases.push_back({value, "structural story address must match exactly"});
  }
  {
    LineOptions value;
    value.event_kind = fushi_voice_hook::kTextEventThreadDiscovered;
    cases.push_back({value, "thread discovery is not a line"});
  }

  for (const InvalidCase &invalid : cases) {
    FakeMapping mapping;
    WriteLine(mapping.header(), kCurrentRaw, invalid.options);
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
        RequestFor(mapping.header()));
    Check(result.disposition ==
              HunexGgeSelectedTextDisposition::kInvalidSelectedEvent,
          invalid.message);
  }
}

void TestTruncatedAndMalformedPayloadsAreRejected() {
  {
    FakeMapping mapping;
    const uint32_t payload_units =
        fushi_voice_hook::hunex_gge_selected_text_detail::kTextPayloadCapacity /
        sizeof(wchar_t);
    WriteLine(mapping.header(), std::wstring(payload_units + 32, L'x'));
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
        RequestFor(mapping.header()));
    Check(result.disposition ==
              HunexGgeSelectedTextDisposition::kInvalidSelectedEvent,
          "producer-clamped text slot must be rejected as truncated");
  }
  {
    FakeMapping mapping;
    WriteLine(mapping.header(), kCurrentRaw);
    TextSlot *slot = SelectedSlotAt(mapping.header(), 1);
    Check(slot != nullptr, "malformed UTF-16 fixture must find selected slot");
    if (slot != nullptr) {
      auto *payload = reinterpret_cast<wchar_t *>(
          reinterpret_cast<uint8_t *>(slot) + sizeof(TextSlot));
      payload[0] = static_cast<wchar_t>(0xD800);
    }
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
        RequestFor(mapping.header()));
    Check(result.disposition ==
              HunexGgeSelectedTextDisposition::kInvalidSelectedEvent,
          "unpaired UTF-16 surrogate must be rejected");
  }
  {
    FakeMapping mapping;
    WriteLine(mapping.header(), kCurrentRaw);
    TextSlot *slot = SelectedSlotAt(mapping.header(), 1);
    Check(slot != nullptr, "odd oversized fixture must find selected slot");
    if (slot != nullptr) {
      slot->byte_len =
          fushi_voice_hook::kHunexGgeSelectedTextMaxUnits * sizeof(wchar_t) + 1;
    }
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
        RequestFor(mapping.header()));
    Check(result.disposition ==
              HunexGgeSelectedTextDisposition::kInvalidSelectedEvent,
          "odd payload larger than the fixed snapshot must be rejected");
  }
  for (const uint32_t odd_bytes : {1u, 1023u}) {
    FakeMapping mapping;
    WriteLine(mapping.header(), kCurrentRaw);
    TextSlot *slot = SelectedSlotAt(mapping.header(), 1);
    Check(slot != nullptr, "odd payload fixture must find selected slot");
    if (slot != nullptr)
      slot->byte_len = odd_bytes;
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
        RequestFor(mapping.header()));
    Check(result.disposition ==
              HunexGgeSelectedTextDisposition::kInvalidSelectedEvent,
          "every odd byte length must fail before payload copy");
  }
  {
    FakeMapping mapping;
    const std::wstring boundary(fushi_voice_hook::kHunexGgeSelectedTextMaxUnits,
                                L'x');
    WriteLine(mapping.header(), boundary);
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
        RequestFor(mapping.header(), boundary.data(),
                   static_cast<uint32_t>(boundary.size())));
    Check(result.disposition ==
                  HunexGgeSelectedTextDisposition::kUseExactMatch &&
              result.text_units == boundary.size(),
          "the complete 1024-byte snapshot boundary must remain admissible");
  }
}

void TestOldEventsAndUpperFenceCannotFallback() {
  {
    FakeMapping mapping;
    const uint64_t old_match = WriteLine(mapping.header(), kCurrentRaw);
    WriteLine(mapping.header(), kFutureRaw);
    auto request = RequestFor(mapping.header());
    request.window_after_seq = old_match;
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(request);
    Check(result.disposition == HunexGgeSelectedTextDisposition::kNoMatch,
          "an exact but already-consumed event must not be reused");
  }
  {
    FakeMapping mapping;
    const uint64_t upper = WriteLine(mapping.header(), kFutureRaw);
    WriteLine(mapping.header(), kCurrentRaw);
    auto request = RequestFor(mapping.header());
    request.window_through_seq = upper;
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(request);
    Check(result.disposition == HunexGgeSelectedTextDisposition::kNoMatch,
          "an exact event published after the captured window must not match");
  }
}

void TestInvalidNewerEventPreventsOldMatchFallback() {
  FakeMapping mapping;
  WriteLine(mapping.header(), kCurrentRaw);
  LineOptions invalid;
  invalid.process_id = kProcessId + 1;
  WriteLine(mapping.header(), kFutureRaw, invalid);
  const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
      RequestFor(mapping.header()));
  Check(result.disposition ==
                HunexGgeSelectedTextDisposition::kInvalidSelectedEvent &&
            result.matched_seq == 0,
        "newer invalid selected event must not fall back to an old match");
}

void TestDuplicateExactMatchesAreAmbiguous() {
  FakeMapping mapping;
  WriteLine(mapping.header(), kCurrentRaw);
  WriteLine(mapping.header(), kCurrentRaw);
  const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
      RequestFor(mapping.header()));
  Check(result.disposition == HunexGgeSelectedTextDisposition::kAmbiguous &&
            result.failure ==
                HunexGgeSelectedTextFailure::kMultipleExactRawLines,
        "two exact events in one unconsumed window must fail closed");
}

void TestIncompleteSlotAndSelectionMismatchAreRejected() {
  {
    FakeMapping mapping;
    WriteLine(mapping.header(), kCurrentRaw);
    TextSlot *slot = SelectedSlotAt(mapping.header(), 1);
    Check(slot != nullptr, "incomplete slot fixture must find selected slot");
    if (slot != nullptr) {
      fushi_voice_hook::AtomicStorePreview64(&slot->lane_seq, 0);
    }
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
        RequestFor(mapping.header()));
    Check(result.disposition == HunexGgeSelectedTextDisposition::kUnstable &&
              result.failure ==
                  HunexGgeSelectedTextFailure::kUnstableSelectedSlot,
          "slot without the committed lane seqlock must be retried");
  }
  {
    FakeMapping mapping;
    WriteLine(mapping.header(), kCurrentRaw);
    mapping.header()->selected_text_thread_id = kOtherThread;
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(
        RequestFor(mapping.header()));
    Check(result.disposition == HunexGgeSelectedTextDisposition::kUnstable &&
              result.failure == HunexGgeSelectedTextFailure::kSelectionChanged,
          "exact content on a previously selected thread must not survive a "
          "selection change");
  }
}

void TestRequestAndHeaderMustBeSane() {
  FakeMapping mapping;
  WriteLine(mapping.header(), kCurrentRaw);
  {
    auto request = RequestFor(mapping.header());
    request.current_process_id = 0;
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(request);
    Check(result.disposition ==
              HunexGgeSelectedTextDisposition::kInvalidRequest,
          "zero current process is not an admission request");
  }
  {
    auto request = RequestFor(mapping.header());
    request.mapped_bytes = sizeof(SharedHeader) - 1;
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(request);
    Check(result.disposition ==
                  HunexGgeSelectedTextDisposition::kInvalidRequest &&
              result.failure == HunexGgeSelectedTextFailure::kHeaderContract,
          "a view shorter than SharedHeader must fail before header reads");
  }
  {
    auto request = RequestFor(mapping.header());
    mapping.header()->text_region_offset = std::numeric_limits<uint32_t>::max();
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(request);
    Check(result.disposition ==
                  HunexGgeSelectedTextDisposition::kInvalidRequest &&
              result.failure == HunexGgeSelectedTextFailure::kHeaderContract,
          "an overflowing text-region offset must fail before pointer math");
  }
  {
    FakeMapping overlap_mapping;
    WriteLine(overlap_mapping.header(), kCurrentRaw);
    auto request = RequestFor(overlap_mapping.header());
    overlap_mapping.header()->text_region_offset =
        static_cast<uint32_t>(sizeof(SharedHeader) - alignof(TextLane));
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(request);
    Check(result.disposition ==
                  HunexGgeSelectedTextDisposition::kInvalidRequest &&
              result.failure == HunexGgeSelectedTextFailure::kHeaderContract,
          "a text region overlapping SharedHeader must be rejected");
  }
  {
    FakeMapping short_mapping;
    WriteLine(short_mapping.header(), kCurrentRaw);
    auto request = RequestFor(short_mapping.header());
    request.mapped_bytes = short_mapping.header()->text_region_offset +
                           fushi_voice_hook::TextRegionBytes(
                               fushi_voice_hook::kTextLaneCount,
                               fushi_voice_hook::kTextLaneSlotCount) -
                           1;
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(request);
    Check(result.disposition ==
                  HunexGgeSelectedTextDisposition::kInvalidRequest &&
              result.failure == HunexGgeSelectedTextFailure::kHeaderContract,
          "a mapping truncated inside the text region must be rejected");
  }
  {
    FakeMapping misaligned_mapping;
    WriteLine(misaligned_mapping.header(), kCurrentRaw);
    auto request = RequestFor(misaligned_mapping.header());
    misaligned_mapping.header()->text_region_offset += 1;
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(request);
    Check(result.disposition ==
                  HunexGgeSelectedTextDisposition::kInvalidRequest &&
              result.failure == HunexGgeSelectedTextFailure::kHeaderContract,
          "a misaligned text-region offset must be rejected");
  }
  {
    FakeMapping version_mapping;
    WriteLine(version_mapping.header(), kCurrentRaw);
    auto request = RequestFor(version_mapping.header());
    version_mapping.header()->version += 1;
    const auto result = fushi_voice_hook::ReadHunexGgeSelectedLunaText(request);
    Check(result.disposition ==
                  HunexGgeSelectedTextDisposition::kInvalidRequest &&
              result.failure == HunexGgeSelectedTextFailure::kHeaderContract,
          "wrong IPC version must fail before reading text lanes");
  }
}

} // namespace

int main() {
  TestExactRawLineWinsOverNewerPrefetch();
  TestNoContentMatchFailsClosed();
  TestNoExactRawLineIsClassifiableByCandidateCounts();
  TestSameFaceSiblingNeverFallsBack();
  TestProcessSourceIdentityAndAddressAreExact();
  TestTruncatedAndMalformedPayloadsAreRejected();
  TestOldEventsAndUpperFenceCannotFallback();
  TestInvalidNewerEventPreventsOldMatchFallback();
  TestDuplicateExactMatchesAreAmbiguous();
  TestIncompleteSlotAndSelectionMismatchAreRejected();
  TestRequestAndHeaderMustBeSane();
  if (g_failures != 0) {
    std::fprintf(stderr, "hunex selected-text test failures: %d\n", g_failures);
    return 1;
  }
  std::printf("hunex selected-text test ok\n");
  return 0;
}
