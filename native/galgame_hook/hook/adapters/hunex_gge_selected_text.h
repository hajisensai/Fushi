#ifndef FUSHI_HUNEX_GGE_SELECTED_TEXT_H_
#define FUSHI_HUNEX_GGE_SELECTED_TEXT_H_

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "voice_hook_ipc.h"

namespace fushi_voice_hook {

// The TYPEMOON HUNEX/GGE hook publishes the renderer's raw tagged UTF-16 line
// (for example, ruby remains encoded as <rREADING>BASE</r>). Geometry capture
// must bind to that exact raw line. The Luna lane can prefetch later lines, so
// choosing the newest slot is not a valid current-line proof.
constexpr char kHunexGgeLunaEngineIdentity[] = "typemoon";
constexpr uint32_t kHunexGgeSelectedTextMaxUnits = 512;

enum class HunexGgeSelectedTextDisposition : uint32_t {
  kNoMatch = 0,
  kUseExactMatch = 1,
  kUnstable = 2,
  kInvalidRequest = 3,
  kAmbiguous = 4,
  kInvalidSelectedEvent = 5,
};

enum class HunexGgeSelectedTextFailure : uint32_t {
  kNone = 0,
  kHeaderContract = 1,
  kRequestShape = 2,
  kSelectionChanged = 3,
  kSelectedLaneChanged = 4,
  kNoSelectedLane = 5,
  kNoExactRawLine = 6,
  kMultipleExactRawLines = 7,
  kInvalidSelectedEvent = 8,
  kInvalidEventAfterMatch = 9,
  kUnstableSelectedSlot = 10,
  kMultipleSelectedLanes = 11,
};

struct HunexGgeSelectedTextRequest {
  const SharedHeader *header = nullptr;
  // Exact byte extent of the mapped view rooted at |header|. Header offsets
  // are untrusted cross-process metadata and must be proven inside this view
  // before any text-lane pointer is formed.
  uint64_t mapped_bytes = 0;
  uint32_t current_process_id = 0;
  // Snapshot beside the renderer's raw-line/window fence. The header must
  // still select this exact id when the worker reads the lane.
  uint64_t exact_selected_thread_id = 0;
  uint64_t exact_thread_address = 0;
  // Exclusive lower bound from the last semantic sentence already admitted.
  uint64_t window_after_seq = 0;
  // Inclusive upper bound sampled when the adapter captured this raw line.
  // Requiring a fixed upper fence prevents later prefetch from changing the
  // meaning of a lookup already in progress.
  uint64_t window_through_seq = 0;
  const wchar_t *exact_raw_tagged_text = nullptr;
  uint32_t exact_raw_tagged_text_units = 0;
};

struct HunexGgeSelectedTextResult {
  HunexGgeSelectedTextDisposition disposition =
      HunexGgeSelectedTextDisposition::kNoMatch;
  HunexGgeSelectedTextFailure failure = HunexGgeSelectedTextFailure::kNone;
  uint64_t matched_seq = 0;
  uint64_t timestamp_ms = 0;
  uint64_t selected_thread_id = 0;
  // Newest fully shaped selected-lane line inside the requested window,
  // regardless of whether its raw bytes matched. Callers use this only to
  // revoke a retained older geometry model; it is never sufficient to admit
  // new geometry.
  uint64_t latest_strict_selected_line_seq = 0;
  uint32_t text_units = 0;
  uint32_t stable_selected_events = 0;
  uint32_t invalid_selected_events = 0;
  wchar_t text[kHunexGgeSelectedTextMaxUnits] = {};
};

namespace hunex_gge_selected_text_detail {

constexpr uint32_t kTextPayloadCapacity =
    kTextSlotBytes - static_cast<uint32_t>(sizeof(TextSlot));

struct StableSlotSnapshot {
  uint64_t seq = 0;
  uint64_t timestamp_ms = 0;
  uint32_t byte_len = 0;
  uint32_t is_utf8 = 0;
  uint64_t thread_id = 0;
  uint64_t thread_address = 0;
  uint32_t process_id = 0;
  uint32_t source_kind = 0;
  uint32_t hook_name_len = 0;
  uint32_t event_kind = 0;
  char hook_name[kTextHookNameChars] = {};
  wchar_t text[kHunexGgeSelectedTextMaxUnits] = {};
};

inline uint64_t AtomicReadLaneField(const volatile uint64_t *value) {
  return AtomicLoadPreview64(value);
}

inline bool IsStrictUtf16(const wchar_t *text, uint32_t units) {
  if (text == nullptr || units == 0)
    return false;
  for (uint32_t index = 0; index < units; ++index) {
    const uint16_t unit = static_cast<uint16_t>(text[index]);
    if (unit == 0)
      return false;
    if (unit >= 0xD800u && unit <= 0xDBFFu) {
      if (index + 1 >= units)
        return false;
      const uint16_t trail = static_cast<uint16_t>(text[index + 1]);
      if (trail < 0xDC00u || trail > 0xDFFFu)
        return false;
      ++index;
    } else if (unit >= 0xDC00u && unit <= 0xDFFFu) {
      return false;
    }
  }
  return true;
}

inline bool HasExactTypemoonIdentity(const StableSlotSnapshot &slot) {
  constexpr uint32_t kIdentityUnits =
      static_cast<uint32_t>(sizeof(kHunexGgeLunaEngineIdentity) - 1);
  return slot.hook_name_len == kIdentityUnits &&
         std::memcmp(slot.hook_name, kHunexGgeLunaEngineIdentity,
                     kIdentityUnits) == 0 &&
         slot.hook_name[kIdentityUnits] == '\0';
}

inline bool SameRawLine(const StableSlotSnapshot &slot,
                        const HunexGgeSelectedTextRequest &request) {
  const uint32_t units = slot.byte_len / sizeof(wchar_t);
  return units == request.exact_raw_tagged_text_units &&
         std::memcmp(slot.text, request.exact_raw_tagged_text,
                     static_cast<size_t>(units) * sizeof(wchar_t)) == 0;
}

inline bool IsStrictCandidateShape(const StableSlotSnapshot &slot,
                                   const HunexGgeSelectedTextRequest &request) {
  // byte_len==the producer capacity is indistinguishable from a clamped write.
  // Reject it instead of turning a truncated prefix into lookup text.
  return slot.process_id == request.current_process_id &&
         slot.source_kind == kTextSourceLuna &&
         slot.event_kind == kTextEventLine && slot.is_utf8 == 0 &&
         slot.thread_address == request.exact_thread_address &&
         HasExactTypemoonIdentity(slot) && slot.byte_len != 0 &&
         slot.byte_len < kTextPayloadCapacity &&
         (slot.byte_len % sizeof(wchar_t)) == 0 &&
         slot.byte_len / sizeof(wchar_t) <= kHunexGgeSelectedTextMaxUnits &&
         IsStrictUtf16(slot.text, slot.byte_len / sizeof(wchar_t));
}

inline bool ReadStableSlot(const TextSlot *slot, uint64_t expected_lane_seq,
                           StableSlotSnapshot *out) {
  if (slot == nullptr || out == nullptr || expected_lane_seq == 0)
    return false;
  const uint64_t lane_before = AtomicLoadPreview64(&slot->lane_seq);
  const uint64_t seq_before = AtomicLoadPreview64(&slot->seq);
  if (lane_before != expected_lane_seq || seq_before == 0)
    return false;

  TextSlot header_copy = {};
  std::memcpy(&header_copy, slot, sizeof(header_copy));
  StableSlotSnapshot candidate = {};
  candidate.seq = header_copy.seq;
  candidate.timestamp_ms = header_copy.timestamp_ms;
  candidate.byte_len = header_copy.byte_len;
  candidate.is_utf8 = header_copy.is_utf8;
  candidate.thread_id = header_copy.thread_id;
  candidate.thread_address = header_copy.thread_address;
  candidate.process_id = header_copy.process_id;
  candidate.source_kind = header_copy.source_kind;
  candidate.hook_name_len = header_copy.hook_name_len;
  candidate.event_kind = header_copy.event_kind;
  std::memcpy(candidate.hook_name, header_copy.hook_name,
              sizeof(candidate.hook_name));

  if (candidate.byte_len != 0 && (candidate.byte_len % sizeof(wchar_t)) == 0 &&
      candidate.byte_len <= kTextPayloadCapacity &&
      candidate.byte_len <= sizeof(candidate.text)) {
    const auto *payload =
        reinterpret_cast<const uint8_t *>(slot) + sizeof(TextSlot);
    std::memcpy(candidate.text, payload, candidate.byte_len);
  }

  const uint64_t seq_after = AtomicLoadPreview64(&slot->seq);
  const uint64_t lane_after = AtomicLoadPreview64(&slot->lane_seq);
  if (lane_after != lane_before || lane_after != expected_lane_seq ||
      seq_after != seq_before || candidate.seq != seq_before ||
      header_copy.lane_seq != lane_before) {
    return false;
  }
  *out = candidate;
  return true;
}

inline bool IsRequestValid(const HunexGgeSelectedTextRequest &request) {
  return request.mapped_bytes >= sizeof(SharedHeader) &&
         request.current_process_id != 0 &&
         request.exact_selected_thread_id != 0 &&
         request.exact_thread_address != 0 &&
         request.window_through_seq > request.window_after_seq &&
         request.exact_raw_tagged_text != nullptr &&
         request.exact_raw_tagged_text_units != 0 &&
         request.exact_raw_tagged_text_units <= kHunexGgeSelectedTextMaxUnits &&
         IsStrictUtf16(request.exact_raw_tagged_text,
                       request.exact_raw_tagged_text_units);
}

inline bool HasValidHeaderContract(const SharedHeader *header,
                                   uint64_t mapped_bytes) {
  if (header == nullptr || mapped_bytes < sizeof(SharedHeader))
    return false;
  if (header->magic != kSharedMagic || header->version != kSharedVersion ||
      header->ipc_protocol_version != kStableIpcVersion ||
      header->luna_bridge_abi_version != kLunaBridgeAbiVersion ||
      header->luna_vendored_version != kLunaVendoredVersion ||
      header->text_lane_count != kTextLaneCount ||
      header->text_lane_slot_count != kTextLaneSlotCount) {
    return false;
  }
  const uint64_t region_offset = header->text_region_offset;
  const uint64_t region_bytes =
      TextRegionBytes(kTextLaneCount, kTextLaneSlotCount);
  return region_offset >= sizeof(SharedHeader) &&
         (region_offset % alignof(TextLane)) == 0 &&
         region_offset <= mapped_bytes &&
         region_bytes <= mapped_bytes - region_offset;
}

} // namespace hunex_gge_selected_text_detail

inline HunexGgeSelectedTextResult
ReadHunexGgeSelectedLunaText(const HunexGgeSelectedTextRequest &request) {
  using namespace hunex_gge_selected_text_detail;
  HunexGgeSelectedTextResult result = {};
  if (!HasValidHeaderContract(request.header, request.mapped_bytes)) {
    result.disposition = HunexGgeSelectedTextDisposition::kInvalidRequest;
    result.failure = HunexGgeSelectedTextFailure::kHeaderContract;
    return result;
  }
  if (!IsRequestValid(request)) {
    result.disposition = HunexGgeSelectedTextDisposition::kInvalidRequest;
    result.failure = HunexGgeSelectedTextFailure::kRequestShape;
    return result;
  }

  const uint64_t selected_before = SelectedTextThreadId(request.header);
  const uint64_t published_before =
      AtomicLoadPreview64(&request.header->text_write_count);
  if (selected_before != request.exact_selected_thread_id) {
    result.disposition = HunexGgeSelectedTextDisposition::kUnstable;
    result.failure = HunexGgeSelectedTextFailure::kSelectionChanged;
    return result;
  }
  if (published_before < request.window_through_seq) {
    result.disposition = HunexGgeSelectedTextDisposition::kInvalidRequest;
    result.failure = HunexGgeSelectedTextFailure::kRequestShape;
    return result;
  }
  result.selected_thread_id = selected_before;

  const TextLane *lanes = TextLanesOf(request.header);
  uint32_t selected_lane_count = 0;
  uint64_t matched_seq = 0;
  uint64_t invalid_after_match_seq = 0;
  for (uint32_t lane_index = 0; lane_index < kTextLaneCount; ++lane_index) {
    const TextLane *lane = &lanes[lane_index];
    const uint64_t lane_thread_before = AtomicReadLaneField(&lane->thread_id);
    if (lane_thread_before != selected_before)
      continue;
    ++selected_lane_count;
    const uint64_t written = AtomicLoadPreview64(&lane->write_count);
    if (written == 0)
      continue;
    const uint64_t first =
        written > kTextLaneSlotCount ? written - kTextLaneSlotCount + 1 : 1;
    for (uint64_t lane_seq = first; lane_seq <= written; ++lane_seq) {
      const auto *slot = reinterpret_cast<const TextSlot *>(
          TextLaneSlotAt(request.header, lane_index, lane_seq));
      StableSlotSnapshot snapshot = {};
      if (!ReadStableSlot(slot, lane_seq, &snapshot)) {
        // We are scanning the exact selected lane. A changing slot could be
        // the only current-line proof, so retry the whole read instead of
        // falling back to another slot.
        result.disposition = HunexGgeSelectedTextDisposition::kUnstable;
        result.failure = HunexGgeSelectedTextFailure::kUnstableSelectedSlot;
        return result;
      }
      if (snapshot.thread_id != selected_before ||
          snapshot.seq <= request.window_after_seq ||
          snapshot.seq > request.window_through_seq) {
        continue;
      }
      ++result.stable_selected_events;
      if (!IsStrictCandidateShape(snapshot, request)) {
        ++result.invalid_selected_events;
        if (snapshot.seq > invalid_after_match_seq) {
          invalid_after_match_seq = snapshot.seq;
        }
        continue;
      }
      result.latest_strict_selected_line_seq = snapshot.seq;
      if (!SameRawLine(snapshot, request))
        continue;
      if (matched_seq != 0) {
        result.disposition = HunexGgeSelectedTextDisposition::kAmbiguous;
        result.failure = HunexGgeSelectedTextFailure::kMultipleExactRawLines;
        return result;
      }
      matched_seq = snapshot.seq;
      result.matched_seq = snapshot.seq;
      result.timestamp_ms = snapshot.timestamp_ms;
      result.text_units = snapshot.byte_len / sizeof(wchar_t);
      std::memcpy(result.text, snapshot.text, snapshot.byte_len);
    }
    const uint64_t lane_thread_after = AtomicReadLaneField(&lane->thread_id);
    if (lane_thread_after != lane_thread_before) {
      result.disposition = HunexGgeSelectedTextDisposition::kUnstable;
      result.failure = HunexGgeSelectedTextFailure::kSelectedLaneChanged;
      return result;
    }
  }

  if (SelectedTextThreadId(request.header) !=
      request.exact_selected_thread_id) {
    result.disposition = HunexGgeSelectedTextDisposition::kUnstable;
    result.failure = HunexGgeSelectedTextFailure::kSelectionChanged;
    return result;
  }
  if (selected_lane_count == 0) {
    result.disposition = HunexGgeSelectedTextDisposition::kNoMatch;
    result.failure = HunexGgeSelectedTextFailure::kNoSelectedLane;
    return result;
  }
  if (selected_lane_count != 1) {
    result.disposition = HunexGgeSelectedTextDisposition::kAmbiguous;
    result.failure = HunexGgeSelectedTextFailure::kMultipleSelectedLanes;
    return result;
  }
  if (matched_seq == 0) {
    result.disposition =
        result.invalid_selected_events == 0
            ? HunexGgeSelectedTextDisposition::kNoMatch
            : HunexGgeSelectedTextDisposition::kInvalidSelectedEvent;
    result.failure = result.invalid_selected_events == 0
                         ? HunexGgeSelectedTextFailure::kNoExactRawLine
                         : HunexGgeSelectedTextFailure::kInvalidSelectedEvent;
    return result;
  }
  // Only an *unidentifiable* later selected-lane event can invalidate the
  // match. A later, fully shaped selected line is Luna prefetching ahead of
  // the renderer, which this engine does routinely; the renderer's inclusive
  // |window_through_seq| fence plus the exact raw bytes are the current-line
  // proof, so recency must never become an admission requirement. The newest
  // strict line is reported through |latest_strict_selected_line_seq| for the
  // caller's retention-revocation check only.
  if (invalid_after_match_seq > matched_seq) {
    result.disposition = HunexGgeSelectedTextDisposition::kInvalidSelectedEvent;
    result.failure = HunexGgeSelectedTextFailure::kInvalidEventAfterMatch;
    result.matched_seq = 0;
    result.timestamp_ms = 0;
    result.text_units = 0;
    std::memset(result.text, 0, sizeof(result.text));
    return result;
  }
  result.disposition = HunexGgeSelectedTextDisposition::kUseExactMatch;
  result.failure = HunexGgeSelectedTextFailure::kNone;
  return result;
}

static_assert(sizeof(wchar_t) == 2,
              "HUNEX selected Luna text is Windows UTF-16");
static_assert(hunex_gge_selected_text_detail::kTextPayloadCapacity >
                  kHunexGgeSelectedTextMaxUnits * sizeof(wchar_t),
              "selected-text snapshot must fit below the producer clamp");

} // namespace fushi_voice_hook

#endif // FUSHI_HUNEX_GGE_SELECTED_TEXT_H_
