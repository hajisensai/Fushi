#pragma once

// CatSystem2 per-line voice from the engine's own archive reads: pure,
// unit-tested half (site proof, member assembly, Ogg page validation, naming).
//
// Engine facts (cs2 2.6.x, x86; measured 2026-09-28 with Frida on the
// グリザイアの有閑 build — the sample only, never an identity input):
//   * A voice plays through kcWLOgg::Open("pcm_x.int/<member>.ogg").  The file
//     manager hands ov_open_callbacks a kcBigFile datasource whose Read(buf,
//     len) forwards to Archive::ReadEntry(entry, buf, len) on the archive
//     object ([this+4]) and the open entry ([this+8]).
//   * ReadEntry clamps len to size (+0x10) minus offset (+0xc), reads with
//     ReadFile on the archive handle (+0x10) at the entry's file position (+8)
//     straight into the caller's buffer and, when the archive is encrypted
//     (+0x11c), decrypts that buffer in place (8-byte blocks) before it
//     returns.  After the call the buffer holds plaintext member bytes
//     [offset, offset + n); position and offset both advanced by n, so
//     position - offset is the member's offset inside the archive.  The entry
//     keeps the requested member name at +0x14.  Nothing here decrypts: the
//     adapter copies what the engine already decrypted for its own decoder.
//   * The decoder is vorbisfile reading 8500 bytes at a time.  Opening a voice
//     reads its head, its tail and the decode-ahead fill within milliseconds
//     (the whole member for short lines); longer members then stream 8500
//     bytes per ~500 ms from the audio thread until the voice ends or the next
//     line stops it.  Every page CRC of the captured plaintext verifies.
//   * Voice archives are the pcm_*.int files; bgm.int / se.int go through the
//     same ReadEntry and are told apart by the archive the handle belongs to.
//
// The site proof (section below) reads only what the source and the calling
// convention fix, so it holds on builds that compile them differently.

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

#include "catsystem2_lookup_core.h"
#include "exact_lookup_signature.h"

namespace fushi_voice_hook::catsystem2_voice {

namespace exact = fushi_voice_hook::exact_lookup;
namespace cs2 = fushi_voice_hook::catsystem2_lookup;

// ── engine layout (proven by the ReadEntry plain path) ──────────────────────

inline constexpr size_t kArchiveHandleOffset = 0x10u;
inline constexpr size_t kEntryPositionOffset = 0x08u;
inline constexpr size_t kEntryOffsetOffset = 0x0cu;
inline constexpr size_t kEntrySizeOffset = 0x10u;
inline constexpr size_t kEntryNameOffset = 0x14u;
// Bytes of the entry name the adapter copies (the engine reserves 260).
inline constexpr size_t kEntryNameBytes = 64u;
// A voice line is kilobytes; anything larger is not assembled.
inline constexpr uint32_t kMaxMemberBytes = 16u * 1024u * 1024u;

// ── site proof ─────────────────────────────────────────────────────────────
//
// Two builds compile the same two functions differently (cs2 2.6.x for
// グリザイアの有閑; the 2016-10 MSVC 12 build for 初恋サンカイメ): other
// registers, `push [esp+8]` instead of `mov edx,[esp+8]; push edx`, `cmova`
// instead of a branch.  What both keep is what the source and the calling
// convention fix, and that is all the proof below reads:
//   * kcBigFile::Read(buf, len) is thiscall with two stack arguments.  Its two
//     null checks each end in `add esp,4; or eax,-1; ret 8` (log, return -1);
//     before the first one it loads a field at +4 (archive), between them a
//     field at +8 (entry), and after the second it pushes the entry from eax
//     and tail-calls `ReadEntry(entry, buf, len)` with `call rel32; ret 8`.
//   * ReadEntry clamps len with the entry's size (+0x10) and offset (+0xc),
//     tests the archive's encrypted flag (`cmp dword [archive+0x11c],0`),
//     calls SetFilePointer, then ReadFile, through their import slots, and on
//     failure logs the entry name it takes as `lea r,[entry+0x14]`.  The
//     clamp loads and the name lea use the same entry register.
// No hash, file name or title is consulted; anything missing or ambiguous
// installs nothing.

inline constexpr uint8_t kErrorExitBytes[] = {0x83, 0xc4, 0x04, 0x83, 0xc8,
                                              0xff, 0xc2, 0x08, 0x00};
// Distance between the two null checks' error exits (0x1a on both builds).
inline constexpr size_t kErrorExitMinGap = 0x10u;
inline constexpr size_t kErrorExitMaxGap = 0x20u;
// The archive field load sits this close before the first error exit (0x11
// on both builds).
inline constexpr size_t kArchiveLoadScanBytes = 0x18u;
// The ReadEntry tail call starts this close after the second error exit.
inline constexpr size_t kForwardCallScanBytes = 0x14u;
inline constexpr uint8_t kForwardTailBytes[] = {0xc2, 0x08, 0x00};  // ret 8

// The encrypted-flag compare lies this far into ReadEntry (0x84 on both
// builds), its ReadFile and name lea right behind it.
inline constexpr size_t kReadEntryScanBytes = 0x200u;
inline constexpr size_t kFlagCompareBytes = 7u;  // 83 /7 disp32 imm8
inline constexpr uint32_t kArchiveEncryptedOffset = 0x11cu;
// The clamp loads sit this close before the flag compare (0x10 / 0xf).
inline constexpr size_t kClampScanBytes = 0x18u;
// SetFilePointer follows the flag compare, ReadFile follows SetFilePointer,
// and the name lea follows ReadFile, each this close.
inline constexpr size_t kCallScanBytes = 0x20u;

struct VoiceImportSlots {
  uintptr_t set_file_pointer = 0u;  // IAT slot RVAs
  uintptr_t read_file = 0u;
};

struct VoiceSites {
  uintptr_t big_read = 0u;     // proof only: the forwarder's ReadEntry call
  uintptr_t read_entry = 0u;   // hook target
  uintptr_t plain_block = 0u;  // proof only: the encrypted-flag compare
};

enum class VoiceSiteResult : uint32_t {
  kResolved = 0u,
  kNotX86 = 1u,
  kImportsMissing = 2u,
  kBigReadMissing = 3u,
  kReadEntryInvalid = 4u,
  kPlainBlockMissing = 5u,
  kPlainBlockCallsInvalid = 6u,
};

// ModR/M `[base+disp8]` without a SIB byte.
inline bool IsBaseDisp8(uint8_t modrm) {
  return (modrm & 0xc0u) == 0x40u && (modrm & 0x07u) != 4u;
}

// `<opcode> modrm disp8` addressing [base+disp] starts somewhere in
// [begin, end) of `code`; `base` 8 accepts any base register.
inline bool HasBaseDisp8(const uint8_t* code, size_t begin, size_t end,
                         uint8_t opcode, uint8_t disp, uint8_t base) {
  for (size_t at = begin; at < end; ++at) {
    if (code[at] == opcode && IsBaseDisp8(code[at + 1u]) &&
        code[at + 2u] == disp &&
        (base == 8u || (code[at + 1u] & 0x07u) == base)) {
      return true;
    }
  }
  return false;
}

// The first `ff 15 <slot>` starting in [begin, end) of `code`, or `end`.
inline size_t FindImportCall(const exact::LoadedPeImage& image,
                             const uint8_t* code, size_t begin, size_t end,
                             uintptr_t slot_rva) {
  for (size_t at = begin; at < end; ++at) {
    if (code[at] == 0xffu && code[at + 1u] == 0x15u &&
        cs2::OperandNamesSlot(image, code + at + 2u, slot_rva)) {
      return at;
    }
  }
  return end;
}

// A kcBigFile::Read forwarder whose second error exit starts at `second`
// (and whose first starts at `first`) inside `code[0, size)`.  Returns the
// offset of its `call rel32`, or 0 when the shape does not hold.
inline size_t MatchForwarder(const uint8_t* code, size_t size, size_t first,
                             size_t second) {
  if (second - first < kErrorExitMinGap || second - first > kErrorExitMaxGap ||
      first < kArchiveLoadScanBytes) {
    return 0u;
  }
  const size_t tail = second + sizeof(kErrorExitBytes);
  if (!HasBaseDisp8(code, first - kArchiveLoadScanBytes, first, 0x8bu, 0x04u,
                    8u) ||
      !HasBaseDisp8(code, first + sizeof(kErrorExitBytes), second, 0x8bu,
                    0x08u, 8u) ||
      tail + kForwardCallScanBytes + 5u + sizeof(kForwardTailBytes) > size) {
    return 0u;
  }
  for (size_t at = tail + 1u; at < tail + kForwardCallScanBytes; ++at) {
    if (code[at] == 0xe8u && code[at - 1u] == 0x50u &&  // push eax (entry)
        std::memcmp(code + at + 5u, kForwardTailBytes,
                    sizeof(kForwardTailBytes)) == 0) {
      return at;
    }
  }
  return 0u;
}

// The unique forwarder's `call rel32` across the executable sections.
inline exact::UniquePatternMatch FindForwarder(
    const exact::LoadedPeImage& image) {
  exact::UniquePatternMatch result;
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto& section = image.sections[index];
    if (!exact::SectionHasRole(&section, IMAGE_SCN_MEM_EXECUTE)) continue;
    // Uniqueness is image-wide: a section that cannot be read could hide a
    // second forwarder, so it fails the proof instead of being skipped.
    if (section.bytes == nullptr || section.size == 0u ||
        !exact::IsReadableSpan(section.bytes, section.size)) {
      return {nullptr, 2u};
    }
    size_t previous = SIZE_MAX;
    for (size_t at = 0u; at + sizeof(kErrorExitBytes) <= section.size; ++at) {
      if (std::memcmp(section.bytes + at, kErrorExitBytes,
                      sizeof(kErrorExitBytes)) != 0) {
        continue;
      }
      const size_t call =
          previous == SIZE_MAX
              ? 0u
              : MatchForwarder(section.bytes, section.size, previous, at);
      previous = at;
      if (call == 0u) continue;
      if (++result.count == 1u) result.address = section.bytes + call;
    }
  }
  if (result.count != 1u) result.address = nullptr;
  return result;
}

// The encrypted-flag compare of ReadEntry's plain path at `cmp` (offset into
// `code`, the first kReadEntryScanBytes of ReadEntry plus call headroom):
// clamp loads before it, from the same entry register the name lea uses.
inline bool MatchesPlainBlock(const exact::LoadedPeImage& image,
                              const uint8_t* code, size_t cmp,
                              const VoiceImportSlots& imports,
                              bool* calls_valid) {
  *calls_valid = false;
  const uint8_t modrm = code[cmp + 1u];
  if (code[cmp] != 0x83u || (modrm & 0xf8u) != 0xb8u || (modrm & 7u) == 4u ||
      code[cmp + 6u] != 0x00u) {
    return false;
  }
  uint32_t disp = 0u;
  std::memcpy(&disp, code + cmp + 2u, sizeof(disp));
  if (disp != kArchiveEncryptedOffset || cmp < kClampScanBytes) return false;
  uint8_t entry = 8u;
  for (uint8_t base = 0u; base < 8u && entry == 8u; ++base) {
    if (base != 4u &&
        HasBaseDisp8(code, cmp - kClampScanBytes, cmp, 0x8bu, 0x10u, base) &&
        HasBaseDisp8(code, cmp - kClampScanBytes, cmp, 0x8bu, 0x0cu, base)) {
      entry = base;
    }
  }
  if (entry == 8u) return false;
  const size_t after = cmp + kFlagCompareBytes;
  const size_t seek = FindImportCall(image, code, after, after + kCallScanBytes,
                                     imports.set_file_pointer);
  if (seek == after + kCallScanBytes) return true;
  const size_t read = FindImportCall(image, code, seek + 6u,
                                     seek + 6u + kCallScanBytes,
                                     imports.read_file);
  if (read == seek + 6u + kCallScanBytes) return true;
  *calls_valid = HasBaseDisp8(code, read + 6u, read + 6u + kCallScanBytes,
                                0x8du, 0x14u, entry);
  return true;
}

// Resolves ReadEntry from structure alone.  Any missing or ambiguous proof
// returns a failure and leaves `sites` zeroed.
inline VoiceSiteResult ResolveVoiceSites(const exact::LoadedPeImage& image,
                                         const VoiceImportSlots& imports,
                                         VoiceSites* sites) {
  if (sites == nullptr) return VoiceSiteResult::kBigReadMissing;
  *sites = {};
  if (image.machine != IMAGE_FILE_MACHINE_I386 || image.pointer_bits != 32u) {
    return VoiceSiteResult::kNotX86;
  }
  if (imports.set_file_pointer == 0u || imports.read_file == 0u) {
    return VoiceSiteResult::kImportsMissing;
  }
  const auto big_read = FindForwarder(image);
  if (big_read.count != 1u) return VoiceSiteResult::kBigReadMissing;
  // Headroom past the scan window for the calls and lea behind its end.
  constexpr size_t kWindow = kReadEntryScanBytes + 4u * (kCallScanBytes + 6u);
  uintptr_t read_entry = 0u;
  if (!exact::DecodeRel32CallTarget(big_read.address, &read_entry) ||
      !cs2::IsExecutableImageAddress(image, read_entry, kWindow)) {
    return VoiceSiteResult::kReadEntryInvalid;
  }
  const auto* code = reinterpret_cast<const uint8_t*>(read_entry);
  size_t block = 0u;
  uint32_t blocks = 0u;
  bool block_calls_valid = false;
  for (size_t at = 0u; at < kReadEntryScanBytes; ++at) {
    bool calls_valid = false;
    if (!MatchesPlainBlock(image, code, at, imports, &calls_valid)) continue;
    block = at;
    block_calls_valid = calls_valid;
    ++blocks;
  }
  if (blocks != 1u) return VoiceSiteResult::kPlainBlockMissing;
  if (!block_calls_valid) return VoiceSiteResult::kPlainBlockCallsInvalid;
  sites->big_read = reinterpret_cast<uintptr_t>(big_read.address);
  sites->read_entry = read_entry;
  sites->plain_block = read_entry + block;
  return VoiceSiteResult::kResolved;
}

// ── entry fields observed around a ReadEntry call ──────────────────────────

// Before the call: offset <= size, position >= offset (position - offset is
// the member start), a member small enough to be a voice line.
inline bool PlausibleEntry(uint32_t position, uint32_t offset, uint32_t size) {
  return size != 0u && size <= kMaxMemberBytes && offset <= size &&
         position >= offset;
}

// Plaintext [offset, offset + done) must stay inside the member.
inline bool PlausibleRead(uint32_t offset, uint32_t size, int32_t done) {
  return done > 0 && offset <= size &&
         static_cast<uint32_t>(done) <= size - offset;
}

// ── member assembly ────────────────────────────────────────────────────────

inline constexpr uint32_t kMaxRanges = 32u;

// Disjoint, sorted, merged byte ranges of one member that have arrived.
struct RangeSet {
  struct Range {
    uint32_t begin = 0u;
    uint32_t end = 0u;
  };
  Range ranges[kMaxRanges] = {};
  uint32_t count = 0u;

  // Adds [begin, end).  Returns false (and changes nothing) when the range is
  // empty or a new disjoint range would not fit.
  bool Add(uint32_t begin, uint32_t end) {
    if (begin >= end) return false;
    uint32_t first = 0u;
    while (first < count && ranges[first].end < begin) ++first;
    uint32_t last = first;
    while (last < count && ranges[last].begin <= end) ++last;
    if (first == last) {  // disjoint: insert at `first`
      if (count == kMaxRanges) return false;
      for (uint32_t i = count; i > first; --i) ranges[i] = ranges[i - 1u];
      ranges[first] = {begin, end};
      ++count;
      return true;
    }
    Range merged = {begin < ranges[first].begin ? begin : ranges[first].begin,
                    end > ranges[last - 1u].end ? end : ranges[last - 1u].end};
    ranges[first] = merged;
    const uint32_t removed = last - first - 1u;
    for (uint32_t i = first + 1u; i + removed < count; ++i) {
      ranges[i] = ranges[i + removed];
    }
    count -= removed;
    return true;
  }

  // Bytes available contiguously from the member start.
  uint32_t Prefix() const {
    return count != 0u && ranges[0].begin == 0u ? ranges[0].end : 0u;
  }
};

// ── Ogg page validation ────────────────────────────────────────────────────

inline uint32_t OggCrcUpdate(uint32_t crc, uint8_t byte) {
  crc ^= static_cast<uint32_t>(byte) << 24;
  for (int bit = 0; bit < 8; ++bit) {
    crc = (crc & 0x80000000u) != 0u ? (crc << 1) ^ 0x04c11db7u : crc << 1;
  }
  return crc;
}

inline uint32_t ReadLe32(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

// CRC of one whole page with its checksum field (bytes 22..25) taken as zero.
inline uint32_t OggPageCrc(const uint8_t* page, uint32_t bytes) {
  uint32_t crc = 0u;
  for (uint32_t i = 0u; i < bytes; ++i) {
    crc = OggCrcUpdate(crc, i >= 22u && i < 26u ? 0u : page[i]);
  }
  return crc;
}

struct OggScan {
  uint32_t valid_bytes = 0u;  // end of the last complete, CRC-valid page
  uint32_t pages = 0u;
  uint64_t last_granule = 0u;  // of the last valid page with a position
  bool vorbis = false;         // first page is a BOS Vorbis identification
  bool eos = false;            // the scan ended on an EOS page
};

// Walks complete pages from the start of `data` and stops at the first page
// that is incomplete, not an Ogg page, of another stream or fails its CRC.
inline OggScan ScanOggPages(const uint8_t* data, uint32_t bytes) {
  OggScan scan;
  if (data == nullptr) return scan;
  uint32_t at = 0u;
  uint32_t serial = 0u;
  while (bytes - at >= 27u && std::memcmp(data + at, "OggS", 4) == 0 &&
         data[at + 4u] == 0u) {
    const uint32_t segments = data[at + 26u];
    if (bytes - at < 27u + segments) break;
    uint32_t payload = 0u;
    for (uint32_t i = 0u; i < segments; ++i) payload += data[at + 27u + i];
    const uint32_t page_bytes = 27u + segments + payload;
    if (bytes - at < page_bytes) break;
    const uint32_t page_serial = ReadLe32(data + at + 14u);
    if (scan.pages == 0u) {
      serial = page_serial;
      const uint8_t* packet = data + at + 27u + segments;
      scan.vorbis = (data[at + 5u] & 0x02u) != 0u && payload >= 7u &&
                    std::memcmp(packet, "\x01vorbis", 7) == 0;
    } else if (page_serial != serial) {
      break;
    }
    if (OggPageCrc(data + at, page_bytes) != ReadLe32(data + at + 22u)) break;
    const uint64_t granule =
        static_cast<uint64_t>(ReadLe32(data + at + 6u)) |
        (static_cast<uint64_t>(ReadLe32(data + at + 10u)) << 32);
    if (granule != 0u && granule != UINT64_MAX) scan.last_granule = granule;
    at += page_bytes;
    ++scan.pages;
    scan.valid_bytes = at;
    if ((data[at - page_bytes + 5u] & 0x04u) != 0u) {
      scan.eos = true;
      break;
    }
  }
  return scan;
}

enum class MemberVerdict : uint32_t {
  kWait = 0u,
  kPublishComplete = 1u,
  kPublishPartial = 2u,
  kReject = 3u,
};

struct MemberDecision {
  MemberVerdict verdict = MemberVerdict::kWait;
  uint32_t bytes = 0u;
};

// A fully read member publishes its Vorbis stream as soon as every page
// verifies.  A member the engine stopped reading (the next line cut the voice)
// publishes the verified page prefix it did decode, if that holds audio past
// the Vorbis headers; otherwise nothing.  A member whose plaintext does not
// verify (not Ogg/Vorbis, or a corrupt page) is rejected.
inline MemberDecision DecideMember(const uint8_t* data, uint32_t size,
                                   const RangeSet& have, bool abandoned) {
  const uint32_t prefix = have.Prefix();
  if (data == nullptr || size == 0u) return {MemberVerdict::kReject, 0u};
  if (prefix >= size) {
    const OggScan scan = ScanOggPages(data, size);
    if (scan.vorbis && scan.last_granule != 0u &&
        (scan.valid_bytes == size || scan.eos)) {
      return {MemberVerdict::kPublishComplete, scan.valid_bytes};
    }
    return {MemberVerdict::kReject, 0u};
  }
  if (!abandoned) return {MemberVerdict::kWait, 0u};
  const OggScan scan = ScanOggPages(data, prefix);
  if (scan.vorbis && scan.last_granule != 0u) {
    return {MemberVerdict::kPublishPartial, scan.valid_bytes};
  }
  return {MemberVerdict::kReject, 0u};
}

// ── which selected line a voice belongs to ─────────────────────────────────
//
// A message's voice starts right after the window clears the page for it
// (measured 7–17 ms after ClearPage).  Where that message's line lands on the
// selected text thread depends on what the Luna hook observes:
//   * EmbedCS2 sits on the script string command, which runs when the script
//     processes the message — before the page is cleared, so the line precedes
//     the voice (measured 50–80 ms);
//   * render-time hooks (the CatSystem2 rasteriser lane, glyph APIs) publish
//     the line once its glyphs were drawn, after the voice started (measured
//     0.4–1.1 s); the newest line before the voice is the previous page's.
// The rule keys on Luna's engine hook identity only (like the EmbedCS2 repeat
// filter in luna_text_selector.h), never on the executable or text content.
enum class LineOrder : uint32_t {
  kPrecedesVoice = 0u,
  kFollowsVoice = 1u,
};

inline LineOrder SelectedLineOrder(const char* hook_name) {
  return hook_name != nullptr && std::strcmp(hook_name, "EmbedCS2") == 0
             ? LineOrder::kPrecedesVoice
             : LineOrder::kFollowsVoice;
}

// ── how long a settled member stays the same playback ──────────────────────
//
// After a member is published (or rejected) its key stays, so the same
// playback's later reads add nothing.  Time cannot bound that playback: the
// 2.6 build tops a playing voice up every 0.5–1 s, but the 2016 build reads a
// whole member when the line starts and reads its first ~90 % again ~5 s later
// with no click in between (measured: E_00_01_004 41609 bytes read whole, then
// 38123 bytes 5.06 s later; E_00_01_005 likewise 5.56 s later).  A 2 s window
// released the key in that gap and published the second pass as a new
// utterance that paired with the next line.
//
// The structural boundary is the next message's voice: a key ends once
// another member has been published after it.  A rejected (non-voice) member
// never ends a playback; it only records the generation it settled in.  The
// same member read again with no other voice in between — a replay of the
// line that is already on screen — stays the same playback.
inline bool SettledMemberKeyEnded(uint64_t settled_generation,
                                  uint64_t publish_generation) {
  return publish_generation > settled_generation;
}

// A binding further away than the host's resource pairing window
// (kGalVoiceResourcePairingWindowMs) could never pair.
inline constexpr uint64_t kTextBindingWindowMs = 1500u;

// ── published name ─────────────────────────────────────────────────────────

// `<archive>_<member>`, e.g. `pcm_e.int_SAC_001.ogg`; a truncated member is
// `<archive>_<member stem>.partial.ogg`.  Path separators and characters a
// file name cannot hold become '_', so the writer never cuts the name short.
inline std::wstring BuildVoiceStorageName(const wchar_t* archive,
                                          const wchar_t* member,
                                          bool partial) {
  std::wstring name = archive != nullptr && archive[0] != 0
                          ? std::wstring(archive)
                          : std::wstring(L"pcm");
  name += L"_";
  std::wstring leaf = member != nullptr && member[0] != 0
                          ? std::wstring(member)
                          : std::wstring(L"voice.ogg");
  const size_t dot = leaf.rfind(L'.');
  if (dot == std::wstring::npos || dot == 0u) leaf += L".ogg";
  if (partial) {
    const size_t ext = leaf.rfind(L'.');
    leaf.insert(ext, L".partial");
  }
  name += leaf;
  for (wchar_t& c : name) {
    if (c == L'\\' || c == L'/' || c == L':' || c == L'*' || c == L'?' ||
        c == L'"' || c == L'<' || c == L'>' || c == L'|' || c < 0x20) {
      c = L'_';
    }
  }
  return name;
}

}  // namespace fushi_voice_hook::catsystem2_voice
