#pragma once

// Nitroplus "N2System" (NitroplusSystem2.0: the nss/.npa script engine of
// 鬼哭街 リメイク, CHAOS;HEAD, 装甲悪鬼村正 ...) engine facts and the rules the
// adapter applies.  Pure code: no Win32, no hooks, unit-tested on synthetic
// bytes (tests/nitroplus_adapter_test.cpp).
//
// The text lane rides the engine's backlog.  Every character the message
// reveal shows is appended to the backlog by one engine routine
//
//   int __cdecl BacklogAppendChar(uint32_t code, VoiceTag* voice)
//
// (code: a CP932 character code, 0 for "voice only", 0x0a for the end of a
// shown line; a packed tate-chu-yoko pair such as "!!" = 0x00210021 is split by
// the routine itself into two calls to its own entry).  When the reveal reaches
// the glyph that starts a voice it calls the routine with code 0 and the voice
// tag, whose 64-byte name sits inline in the tag and whose file string is
// behind a pointer; the routine writes both into the backlog as a VOICE tag.
// It returns 0 when the engine does not log (its "no backlog" state, a full
// backlog) and 1 when the character was logged.
//
// The routine is identified only by its structure (ResolveBacklogAppend): the
// "no backlog" guard, the four tate-chu-yoko pair compares that all branch to
// one block that re-enters the routine twice, the backlog global and its
// write pointer, and the VOICE tag writer that reads the tag's name and file
// fields.  No hash, file name, title or string is used, and a structure that
// is not unique is refused.

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook {
namespace nitroplus {

// A PE image laid out by section (a loaded module or a synthetic test image).
struct ImageView {
  const uint8_t* bytes = nullptr;
  size_t size = 0;
  uint32_t image_base = 0;  // the preferred / loaded base the code addresses
  uint32_t code_rva = 0;    // the executable section the resolver scans
  uint32_t code_size = 0;
};

enum class Refusal : uint32_t {
  kNone = 0,
  kNoCode = 1,           // no executable section in the view
  kNoAnchor = 2,         // no pair-compare anchor
  kAnchorNotUnique = 3,  // more than one candidate routine
  kEntryShape = 4,       // the "no backlog" guard is not in front of it
  kPairSplit = 5,        // the pair compares do not share a re-entering block
  kBacklogGlobal = 6,    // no backlog global / write pointer load
  kVoiceFields = 7,      // no VOICE tag writer reading the tag fields
};

struct BacklogSites {
  bool ok = false;
  Refusal refusal = Refusal::kNone;
  uint32_t append_rva = 0;         // BacklogAppendChar entry
  uint32_t pair_split_rva = 0;     // the block that splits a packed pair
  uint32_t no_log_state_va = 0;    // the engine state the guard compares
  uint32_t no_log_state_value = 0; // ... and the value that means "no log"
  uint32_t backlog_global_va = 0;  // pointer to the backlog object
  uint8_t write_pointer_offset = 0;
  uint8_t voice_name_offset = 0;   // inline char[] in the voice tag
  uint8_t voice_file_offset = 0;   // char* in the voice tag
  uint32_t anchors_seen = 0;
};

namespace detail {

inline uint32_t ReadU32(const uint8_t* p) {
  uint32_t v = 0;
  std::memcpy(&v, p, sizeof(v));
  return v;
}

inline int32_t ReadI32(const uint8_t* p) {
  int32_t v = 0;
  std::memcpy(&v, p, sizeof(v));
  return v;
}

// push edi; mov edi,[esp+8]; cmp edi,0x00210021; je rel32
constexpr uint8_t kAnchor[] = {0x57, 0x8B, 0x7C, 0x24, 0x08, 0x81, 0xFF,
                               0x21, 0x00, 0x21, 0x00, 0x0F, 0x84};
// The four packed tate-chu-yoko pairs ("!!", "!?", "?!", "??"), each
// compared with `cmp edi, imm32; je rel32` (12 bytes) in this order.
constexpr uint32_t kPairCodes[4] = {0x00210021u, 0x0021003Fu, 0x003F0021u,
                                    0x003F003Fu};
// cmp dword ptr [abs32], imm32; jne +3; xor eax,eax; ret
constexpr size_t kGuardBytes = 15;

inline bool InCode(const ImageView& view, uint64_t rva, uint64_t length) {
  return rva >= view.code_rva &&
         rva + length <= static_cast<uint64_t>(view.code_rva) + view.code_size &&
         rva + length <= view.size;
}

}  // namespace detail

inline BacklogSites ResolveBacklogAppend(const ImageView& view) {
  using namespace detail;
  BacklogSites sites;
  if (view.bytes == nullptr || view.code_size == 0 ||
      !InCode(view, view.code_rva, 1)) {
    sites.refusal = Refusal::kNoCode;
    return sites;
  }
  uint64_t end64 = static_cast<uint64_t>(view.code_rva) + view.code_size;
  if (end64 > view.size) end64 = view.size;
  const uint32_t end = static_cast<uint32_t>(end64);
  uint32_t anchor = 0;
  for (uint32_t r = view.code_rva; r + sizeof(kAnchor) <= end; ++r) {
    if (std::memcmp(view.bytes + r, kAnchor, sizeof(kAnchor)) == 0) {
      ++sites.anchors_seen;
      anchor = r;
    }
  }
  if (sites.anchors_seen == 0) {
    sites.refusal = Refusal::kNoAnchor;
    return sites;
  }
  if (sites.anchors_seen != 1) {
    sites.refusal = Refusal::kAnchorNotUnique;
    return sites;
  }
  // The guard sits directly in front: cmp [abs],imm; jne +3; xor eax,eax; ret
  if (anchor < view.code_rva + kGuardBytes) {
    sites.refusal = Refusal::kEntryShape;
    return sites;
  }
  const uint32_t entry = anchor - static_cast<uint32_t>(kGuardBytes);
  const uint8_t* g = view.bytes + entry;
  if (g[0] != 0x81 || g[1] != 0x3D || g[10] != 0x75 || g[11] != 0x03 ||
      g[12] != 0x33 || g[13] != 0xC0 || g[14] != 0xC3) {
    sites.refusal = Refusal::kEntryShape;
    return sites;
  }
  sites.no_log_state_va = ReadU32(g + 2);
  sites.no_log_state_value = ReadU32(g + 6);

  // Four `cmp edi, pair; je split` with one shared target.
  uint32_t compare = anchor + 5;
  uint32_t split = 0;
  for (int i = 0; i < 4; ++i) {
    if (!InCode(view, compare, 12)) {
      sites.refusal = Refusal::kPairSplit;
      return sites;
    }
    const uint8_t* c = view.bytes + compare;
    if (c[0] != 0x81 || c[1] != 0xFF || ReadU32(c + 2) != kPairCodes[i] ||
        c[6] != 0x0F || c[7] != 0x84) {
      sites.refusal = Refusal::kPairSplit;
      return sites;
    }
    const int64_t target =
        static_cast<int64_t>(compare) + 12 + ReadI32(c + 8);
    if (target < 0 || target > 0xFFFFFFFFll ||
        (split != 0 && static_cast<uint32_t>(target) != split)) {
      sites.refusal = Refusal::kPairSplit;
      return sites;
    }
    split = static_cast<uint32_t>(target);
    compare += 12;
  }
  // The split block: mov eax,edi; shr eax,16; ... and two calls to the entry
  // (high half, then low half) within its first 0x30 bytes.
  if (!InCode(view, split, 0x30) || view.bytes[split] != 0x8B ||
      view.bytes[split + 1] != 0xC7 || view.bytes[split + 2] != 0xC1 ||
      view.bytes[split + 3] != 0xE8 || view.bytes[split + 4] != 0x10) {
    sites.refusal = Refusal::kPairSplit;
    return sites;
  }
  int reentries = 0;
  for (uint32_t r = split; r + 5 <= split + 0x30; ++r) {
    if (view.bytes[r] != 0xE8) continue;
    const int64_t target = static_cast<int64_t>(r) + 5 + ReadI32(view.bytes + r + 1);
    if (target == entry) {
      ++reentries;
      r += 4;
    }
  }
  if (reentries != 2) {
    sites.refusal = Refusal::kPairSplit;
    return sites;
  }
  sites.pair_split_rva = split;

  // Right after the compares: push ebp; mov ebp,[backlog]; mov eax,[ebp+W]
  const uint32_t body = compare;
  if (!InCode(view, body, 10) || view.bytes[body] != 0x55 ||
      view.bytes[body + 1] != 0x8B || view.bytes[body + 2] != 0x2D ||
      view.bytes[body + 7] != 0x8B || view.bytes[body + 8] != 0x45) {
    sites.refusal = Refusal::kBacklogGlobal;
    return sites;
  }
  sites.backlog_global_va = ReadU32(view.bytes + body + 3);
  sites.write_pointer_offset = view.bytes[body + 9];

  // The VOICE tag writer: mov ebx,[esp+0x18] (the voice argument after the
  // routine's four pushes); test ebx,ebx; je; then the tag opener
  // `mov edx,0x10`, the field separator `mov ecx,0x11`, the inline name
  // `mov al,[ebx+N]` and the file pointer `mov ecx,[ebx+F]`.
  uint32_t voice = 0;
  for (uint32_t r = body; r + 4 <= body + 0x40 && InCode(view, r, 4); ++r) {
    if (view.bytes[r] == 0x8B && view.bytes[r + 1] == 0x5C &&
        view.bytes[r + 2] == 0x24 && view.bytes[r + 3] == 0x18) {
      voice = r + 4;
      break;
    }
  }
  if (voice == 0 || !InCode(view, voice, 0x60) ||
      view.bytes[voice] != 0x85 || view.bytes[voice + 1] != 0xDB ||
      view.bytes[voice + 2] != 0x74 || view.bytes[voice + 4] != 0xBA ||
      ReadU32(view.bytes + voice + 5) != 0x10u) {
    sites.refusal = Refusal::kVoiceFields;
    return sites;
  }
  int separators = 0;
  int names = 0;
  int files = 0;
  for (uint32_t r = voice + 9; r + 5 <= voice + 0x60; ++r) {
    const uint8_t* p = view.bytes + r;
    if (p[0] == 0xB9 && ReadU32(p + 1) == 0x11u) {
      ++separators;
    } else if (p[0] == 0x8A && p[1] == 0x43 && separators == 1 && names == 0) {
      sites.voice_name_offset = p[2];
      ++names;
    } else if (p[0] == 0x8B && p[1] == 0x4B && separators == 2 && files == 0) {
      sites.voice_file_offset = p[2];
      ++files;
    }
  }
  if (separators < 2 || names != 1 || files != 1 ||
      sites.voice_name_offset >= sites.voice_file_offset) {
    sites.refusal = Refusal::kVoiceFields;
    return sites;
  }
  sites.append_rva = entry;
  sites.ok = true;
  return sites;
}

// ── line assembly ──────────────────────────────────────────────────────────

constexpr uint32_t kMaxLineCodes = 512;
constexpr uint32_t kVoiceNameBytes = 64;

struct Line {
  uint32_t count = 0;
  bool truncated = false;
  bool has_voice = false;
  char voice_name[kVoiceNameBytes] = {};
  char voice_file[kVoiceNameBytes] = {};
  uint16_t codes[kMaxLineCodes] = {};
};

// The open line of the backlog stream (game thread only).
struct Assembler {
  Line open;
};

enum class FeedResult : uint32_t {
  kNone = 0,
  kLineComplete = 1,  // `out` holds a finished line
  kLineDropped = 2,   // a line ended but was truncated (fail closed)
};

// A voice tag arrived (code 0 with a voice): it belongs to the open line.  The
// first voice of a line wins; the strings are copied bounded and terminated.
inline void NoteVoice(Assembler* a, const char* name, size_t name_len,
                      const char* file, size_t file_len) {
  Line& line = a->open;
  if (line.has_voice) return;
  line.has_voice = true;
  const size_t n = name_len < kVoiceNameBytes - 1 ? name_len : kVoiceNameBytes - 1;
  const size_t f = file_len < kVoiceNameBytes - 1 ? file_len : kVoiceNameBytes - 1;
  std::memcpy(line.voice_name, name, n);
  line.voice_name[n] = '\0';
  std::memcpy(line.voice_file, file, f);
  line.voice_file[f] = '\0';
}

// One logged character.  0x0a ends the shown line; other control codes are
// layout (the backlog's own wrap marks) and carry no text; a packed pair is
// re-entered by the engine as its two halves, so the packed call is ignored.
inline FeedResult FeedCode(Assembler* a, uint32_t code, Line* out) {
  Line& line = a->open;
  if (code > 0xFFFFu || code == 0u) return FeedResult::kNone;
  if (code == 0x0Au) {
    if (line.count == 0u) {
      // An empty line keeps a voice that arrived for the next one.
      return FeedResult::kNone;
    }
    const bool truncated = line.truncated;
    if (!truncated) std::memcpy(out, &line, sizeof(Line));
    line = Line{};
    return truncated ? FeedResult::kLineDropped : FeedResult::kLineComplete;
  }
  if (code < 0x20u) return FeedResult::kNone;
  if (line.count >= kMaxLineCodes) {
    line.truncated = true;
    return FeedResult::kNone;
  }
  line.codes[line.count++] = static_cast<uint16_t>(code);
  return FeedResult::kNone;
}

// The CP932 bytes of a line, or 0 when a code is not a CP932 character (the
// line is then not published).  `out` holds at least 2 * count bytes.
inline size_t LineToCp932(const Line& line, char* out, size_t capacity) {
  size_t length = 0;
  for (uint32_t i = 0; i < line.count; ++i) {
    const uint16_t code = line.codes[i];
    if (code <= 0xFFu) {
      const bool ascii = code >= 0x20u && code < 0x7Fu;
      const bool kana = code >= 0xA1u && code <= 0xDFu;
      if (!ascii && !kana) return 0;
      if (length + 1 > capacity) return 0;
      out[length++] = static_cast<char>(code);
      continue;
    }
    const uint8_t lead = static_cast<uint8_t>(code >> 8);
    const uint8_t trail = static_cast<uint8_t>(code & 0xFFu);
    const bool lead_ok = (lead >= 0x81u && lead <= 0x9Fu) ||
                         (lead >= 0xE0u && lead <= 0xFCu);
    const bool trail_ok = trail >= 0x40u && trail <= 0xFCu && trail != 0x7Fu;
    if (!lead_ok || !trail_ok || length + 2 > capacity) return 0;
    out[length++] = static_cast<char>(lead);
    out[length++] = static_cast<char>(trail);
  }
  return length;
}

}  // namespace nitroplus
}  // namespace fushi_voice_hook
