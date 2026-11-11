#pragma once

// KiriKiri KAG message text lane (KiriKiri2 and KiriKiri Z alike): the pure,
// unit-tested half.
//
// Engine facts (KAG3 system scripts, MainWindow.tjs / MessageLayer.tjs; the
// same shape survives in KAGEX's MessageLayer):
//   * Every displayed character of a scenario line reaches the CURRENT message
//     layer through the layer's script method processCh(ch).  When
//     currentWithBack is set the same character is also sent to the back page
//     layer (current.comp) -- that second call is never drawn on screen.
//   * processCh returns true when the character did not fit (page overflow);
//     in that case it was not drawn and KAG enters showPageBreakAndClear.
//   * [ruby text=...] only stores the annotation on the layer (setRuby); the
//     base character still arrives through processCh, the annotation never does.
//   * KAG waits for the reader's click at exactly three window methods:
//     showLineBreak ([l]), showPageBreak ([p]) and showPageBreakAndClear (auto
//     page break on overflow).  These are the line boundaries -- KAG's own
//     lifecycle, not a timer.
//   * A message layer is wiped by its clear() method ([er], [cm], [ct], page
//     overflow click).  Characters that were never followed by a wait (choice
//     links, system text written with [s]) are discarded there.
//
// The TJS side (kirikiri_adapter.inc, kKirikiriKagTextBootstrapScript) only
// forwards those four facts as a compact event string; all line assembly is
// here, on HookWorker, so it is testable offline.  Wire format, one record
// after another, no separators:
//
//     <op><layer id>,<payload length in UTF-16 units>:<payload>
//
//   op 'c'  processCh drew <payload> on the current layer <id>
//   op 'r'  setRuby(<payload>) on layer <id> (annotation; dropped)
//   op 'w'  KAG waits for a click while layer <id> is current (commit)
//   op 'x'  layer <id> was cleared (discard uncommitted characters)
//   op 'o'  the TJS-side event buffer overflowed and was dropped (id 0)
//
// Failure is always closed: a malformed batch, an overflow or a line longer
// than the slot capacity drops the affected text instead of publishing a
// partial line.

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "../../include/text_thread_identity.h"
#include "../../include/voice_hook_ipc.h"

namespace fushi_voice_hook::kirikiri_kag_text {

inline constexpr wchar_t kHookCode[] = L"ENGINE:KIRIKIRI:kag_message";
inline constexpr char kHookName[] = "KiriKiri KAG exact";
// Names the KAG3 message-layer text pipeline (processCh + click waits), not a
// game, RVA or hash.
inline constexpr uint64_t kComponentIdentity = 0x4B41473354585431ull;  // "KAG3TXT1"

// UTF-16 units of one committed line.  Kept well inside the lane slot so the
// published text is never truncated by the IPC writer.
inline constexpr uint32_t kMaxLineUnits = 480u;
// One processCh call draws one character (two units for a surrogate pair);
// [ch text=...] may pass a short run.  Anything longer is not a character.
inline constexpr uint32_t kMaxCharPayloadUnits = 64u;
// Message layers tracked at once (fore + back pages of numMessageLayers).
inline constexpr uint32_t kMaxLayers = 16u;
// Upper bound of one TJS event batch; the TJS side resets its buffer to a
// single overflow record before reaching it.
inline constexpr uint32_t kTjsEventBufferUnits = 3000u;
inline constexpr uint32_t kMaxBatchUnits = 4096u;
inline constexpr uint32_t kMaxLinesPerBatch = 32u;

static_assert(kMaxLineUnits * sizeof(wchar_t) + sizeof(TextSlot) <= kTextSlotBytes,
              "a committed KAG line must fit one text lane slot untruncated");
static_assert(kTjsEventBufferUnits + 64u < kMaxBatchUnits,
              "the native batch buffer must hold the largest TJS batch");

struct Line {
  uint32_t layer_id = 0;
  uint32_t units = 0;
  wchar_t text[kMaxLineUnits] = {};
};

struct LineBatch {
  uint32_t count = 0;
  Line lines[kMaxLinesPerBatch];
};

enum class BatchStatus : uint8_t {
  kOk = 0,
  kMalformed = 1,  // assembler was reset; the rest of the batch was skipped
};

inline bool IsLineWhitespace(wchar_t ch) {
  return ch == L' ' || ch == L'\t' || ch == 0x3000;
}

// Control characters never correspond to a drawn glyph.
inline bool IsControlUnit(wchar_t ch) {
  return ch < 0x20 || ch == 0x7F || (ch >= 0x80 && ch < 0xA0);
}

// Monotonic outcome counts for on-device diagnostics (never reset by Reset()).
struct AssemblerCounters {
  uint32_t chars = 0;           // drawn units accepted into a buffer
  uint32_t waits = 0;           // commit points seen
  uint32_t lines = 0;           // commit points that produced a line
  uint32_t poisoned_waits = 0;  // commit points dropped because characters were lost
  uint32_t blank_waits = 0;     // commit points with nothing (or only blanks) buffered
  uint32_t capped_waits = 0;    // lines past kMaxLinesPerBatch in one batch
  uint32_t clears = 0;
  uint32_t overflows = 0;
};

class Assembler {
 public:
  // Drops everything; buffers created afterwards start clean.
  void Reset() {
    for (Slot& slot : slots_) slot = Slot{};
    poisoned_until_boundary_ = false;
  }

  // Characters were lost upstream (TJS buffer or native mailbox overflow, a
  // truncated read).  Every layer, including ones not seen yet, may be missing
  // the start of its current line: drop each until its next wait or clear.
  void Overflow() {
    ++counters_.overflows;
    for (Slot& slot : slots_) {
      if (!slot.used) continue;
      slot.units = 0;
      slot.poisoned = true;
    }
    poisoned_until_boundary_ = true;
  }

  void OnChar(uint32_t id, const wchar_t* text, uint32_t units) {
    Slot* slot = Acquire(id);
    if (slot == nullptr) return;
    if (units == 0u || units > kMaxCharPayloadUnits) {
      slot->poisoned = slot->poisoned || units != 0u;
      return;
    }
    for (uint32_t i = 0; i < units; ++i) {
      const wchar_t ch = text[i];
      if (IsControlUnit(ch)) continue;
      if (slot->units >= kMaxLineUnits) {
        slot->poisoned = true;  // longer than a slot: never publish a prefix
        return;
      }
      slot->text[slot->units++] = ch;
      ++counters_.chars;
    }
  }

  // Base text only: the annotation is not part of the displayed line.
  void OnRuby(uint32_t id, const wchar_t*, uint32_t) { Acquire(id); }

  // Commits the characters drawn since the previous boundary.  Returns true
  // and fills `out` only for a clean, non-blank line.
  bool OnWait(uint32_t id, Line* out) {
    ++counters_.waits;
    Slot* slot = Find(id);
    if (slot == nullptr) {
      ++counters_.blank_waits;
      // A layer that never drew anything in this session: nothing to commit,
      // but the boundary still clears the post-overflow poison for it.
      slot = Acquire(id);
      if (slot != nullptr) {
        slot->units = 0;
        slot->poisoned = false;
      }
      return false;
    }
    const bool publish = !slot->poisoned;
    uint32_t begin = 0;
    uint32_t end = slot->units;
    while (begin < end && IsLineWhitespace(slot->text[begin])) ++begin;
    while (end > begin && IsLineWhitespace(slot->text[end - 1])) --end;
    const bool emitted = publish && end > begin && out != nullptr;
    if (emitted) {
      ++counters_.lines;
    } else if (!publish) {
      ++counters_.poisoned_waits;
    } else if (end > begin) {
      ++counters_.capped_waits;
    } else {
      ++counters_.blank_waits;
    }
    if (emitted) {
      out->layer_id = id;
      out->units = end - begin;
      memcpy(out->text, slot->text + begin, out->units * sizeof(wchar_t));
    }
    slot->units = 0;
    slot->poisoned = false;
    return emitted;
  }

  void OnClear(uint32_t id) {
    ++counters_.clears;
    Slot* slot = Find(id);
    if (slot == nullptr) slot = Acquire(id);
    if (slot == nullptr) return;
    slot->units = 0;
    slot->poisoned = false;
  }

  const AssemblerCounters& counters() const { return counters_; }

  // Test introspection.
  uint32_t PendingUnits(uint32_t id) const {
    for (const Slot& slot : slots_) {
      if (slot.used && slot.id == id) return slot.units;
    }
    return 0u;
  }

 private:
  struct Slot {
    bool used = false;
    bool poisoned = false;
    uint32_t id = 0;
    uint64_t touched = 0;
    uint32_t units = 0;
    wchar_t text[kMaxLineUnits] = {};
  };

  Slot* Find(uint32_t id) {
    for (Slot& slot : slots_) {
      if (slot.used && slot.id == id) {
        slot.touched = ++clock_;
        return &slot;
      }
    }
    return nullptr;
  }

  Slot* Acquire(uint32_t id) {
    if (id == 0u) return nullptr;
    Slot* found = Find(id);
    if (found != nullptr) return found;
    Slot* victim = &slots_[0];
    for (Slot& slot : slots_) {
      if (!slot.used) {
        victim = &slot;
        break;
      }
      if (slot.touched < victim->touched) victim = &slot;
    }
    *victim = Slot{};
    victim->used = true;
    victim->id = id;
    victim->touched = ++clock_;
    // A layer first seen after an overflow may have lost the start of its line.
    victim->poisoned = poisoned_until_boundary_;
    return victim;
  }

  Slot slots_[kMaxLayers];
  AssemblerCounters counters_;
  uint64_t clock_ = 0;
  bool poisoned_until_boundary_ = false;
};

namespace detail {

inline bool ParseDecimal(const wchar_t* text, uint32_t length, uint32_t* pos,
                         wchar_t terminator, uint32_t* value) {
  uint32_t i = *pos;
  uint64_t acc = 0;
  const uint32_t start = i;
  while (i < length && text[i] >= L'0' && text[i] <= L'9') {
    acc = acc * 10u + static_cast<uint32_t>(text[i] - L'0');
    if (acc > 0xFFFFFFu) return false;
    ++i;
  }
  if (i == start || i >= length || text[i] != terminator) return false;
  *value = static_cast<uint32_t>(acc);
  *pos = i + 1u;
  return true;
}

}  // namespace detail

// Feeds one TJS event batch into the assembler; committed lines are appended
// to `out` (lines past kMaxLinesPerBatch are dropped, never truncated).
inline BatchStatus ApplyBatch(Assembler* assembler, const wchar_t* batch,
                              uint32_t length, LineBatch* out) {
  uint32_t pos = 0;
  while (pos < length) {
    const wchar_t op = batch[pos++];
    uint32_t id = 0;
    uint32_t units = 0;
    if (!detail::ParseDecimal(batch, length, &pos, L',', &id) ||
        !detail::ParseDecimal(batch, length, &pos, L':', &units) ||
        units > length - pos) {
      assembler->Overflow();
      return BatchStatus::kMalformed;
    }
    const wchar_t* payload = batch + pos;
    pos += units;
    switch (op) {
      case L'c':
        assembler->OnChar(id, payload, units);
        break;
      case L'r':
        assembler->OnRuby(id, payload, units);
        break;
      case L'w': {
        if (out != nullptr && out->count < kMaxLinesPerBatch) {
          if (assembler->OnWait(id, &out->lines[out->count])) ++out->count;
        } else {
          assembler->OnWait(id, nullptr);
        }
        break;
      }
      case L'x':
        assembler->OnClear(id);
        break;
      case L'o':
        assembler->Overflow();
        break;
      default:
        assembler->Overflow();
        return BatchStatus::kMalformed;
    }
  }
  return BatchStatus::kOk;
}

// Text-lane admission.  The lane exists only where the KiriKiri adapter holds
// a TJS function exporter -- the plugin ABI handed to us by the engine itself
// (TVPGetFunctionExporter export, a plugin's V2Link, or a linked plugin that
// answered a real query).  Lookup readiness is deliberately not an input:
// the lane must run whether or not the in-game lookup sensor ever installs.
inline bool LaneWanted(bool stopping, bool capture_enabled, bool has_exporter,
                       bool has_shared_header) {
  return !stopping && capture_enabled && has_exporter && has_shared_header;
}

// The TJS diagnostics string ("pc=1,cur=1,...") is engine-produced data; it
// is logged only when it has exactly the shape our script builds.
constexpr uint32_t kMaxStatsUnits = 256;

inline bool IsLoggableStats(const wchar_t* text, uint32_t units) {
  if (text == nullptr || units == 0u || units >= kMaxStatsUnits) return false;
  for (uint32_t i = 0; i < units; ++i) {
    const wchar_t ch = text[i];
    const bool ok = (ch >= L'a' && ch <= L'z') || (ch >= L'0' && ch <= L'9') ||
                    ch == L'=' || ch == L',' || ch == L'-';
    if (!ok) return false;
  }
  return true;
}

inline uint64_t LaneThreadId() {
  return NativeTextThreadIdFrom(kComponentIdentity, kHookCode, kHookName);
}

inline TextLaneWrite MakeLaneWrite(const Line& line, uint32_t process_id) {
  TextLaneWrite write;
  write.thread_id = LaneThreadId();
  write.thread_address = kComponentIdentity;
  write.thread_context = kComponentIdentity;
  write.process_id = process_id;
  write.source_kind = kTextSourceKirikiri;
  write.event_kind = kTextEventLine;
  write.is_utf8 = 0;
  write.text = line.text;
  write.byte_len = line.units * static_cast<uint32_t>(sizeof(wchar_t));
  write.hook_name = kHookName;
  write.hook_code = kHookCode;
  return write;
}

}  // namespace fushi_voice_hook::kirikiri_kag_text
