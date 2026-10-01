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
// Every site below is proven by structure: the kcBigFile::Read forwarder (its
// two null checks and the (entry, buf, len) argument order it pushes), the
// ReadEntry prologue that binds those arguments to esi/ebx/ebp and the
// archive to edi, and the plain-path block that reads the entry fields and
// calls SetFilePointer / ReadFile through their import slots.  No hash, file
// name or title is consulted; anything missing or ambiguous installs nothing.

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

// ── engine layout (proven by the ReadEntry signatures) ─────────────────────

inline constexpr size_t kArchiveHandleOffset = 0x10u;
inline constexpr size_t kEntryPositionOffset = 0x08u;
inline constexpr size_t kEntryOffsetOffset = 0x0cu;
inline constexpr size_t kEntrySizeOffset = 0x10u;
inline constexpr size_t kEntryNameOffset = 0x14u;
// Bytes of the entry name the adapter copies (the engine reserves 260).
inline constexpr size_t kEntryNameBytes = 64u;
// A voice line is kilobytes; anything larger is not assembled.
inline constexpr uint32_t kMaxMemberBytes = 16u * 1024u * 1024u;

// ── signatures ─────────────────────────────────────────────────────────────

// kcBigFile::Read(buf, len): `archive = [this+4]`, `entry = [this+8]`, each
// null-checked with an error log and `return -1`, then
// `ReadEntry(entry, buf, len)` (archive in ecx) and `ret 8`.
inline constexpr uint8_t kBigReadBytes[] = {
    0x8b, 0xc1, 0x8b, 0x48, 0x04, 0x85, 0xc9, 0x75, 0x00, 0x68, 0x00, 0x00,
    0x00, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x83, 0xc4, 0x04, 0x83, 0xc8,
    0xff, 0xc2, 0x08, 0x00, 0x8b, 0x40, 0x08, 0x85, 0xc0, 0x75, 0x00, 0x68,
    0x00, 0x00, 0x00, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x83, 0xc4, 0x04,
    0x83, 0xc8, 0xff, 0xc2, 0x08, 0x00, 0x8b, 0x54, 0x24, 0x08, 0x52, 0x8b,
    0x54, 0x24, 0x08, 0x52, 0x50, 0xe8, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x08,
    0x00};
inline constexpr size_t kBigReadWildcards[][2] = {
    {8u, 9u}, {10u, 14u}, {15u, 19u}, {34u, 35u}, {36u, 40u}, {41u, 45u},
    {66u, 70u}};
inline constexpr auto kBigReadMask =
    cs2::WildcardMask<sizeof(kBigReadBytes)>(kBigReadWildcards);
inline constexpr size_t kBigReadCall = 65u;  // `e8` of ReadEntry

// ReadEntry prologue: `sub esp,0x20; mov eax,[cookie]; xor eax,esp;
// mov [esp+0x1c],eax; push ebx; mov ebx,[esp+0x2c] (buf); push esi;
// mov esi,[esp+0x2c] (entry); push edi; push esi; mov edi,ecx (archive)`.
inline constexpr uint8_t kReadEntryPrologueBytes[] = {
    0x83, 0xec, 0x20, 0xa1, 0x00, 0x00, 0x00, 0x00, 0x33, 0xc4,
    0x89, 0x44, 0x24, 0x1c, 0x53, 0x8b, 0x5c, 0x24, 0x2c, 0x56,
    0x8b, 0x74, 0x24, 0x2c, 0x57, 0x56, 0x8b, 0xf9};
inline constexpr size_t kReadEntryPrologueWildcards[][2] = {{4u, 8u}};
inline constexpr auto kReadEntryPrologueMask =
    cs2::WildcardMask<sizeof(kReadEntryPrologueBytes)>(
        kReadEntryPrologueWildcards);

// ReadEntry plain path: `len = min(len, [esi+0x10] - [esi+0xc])`; test the
// encrypted flag `[edi+0x11c]`; `SetFilePointer([edi+0x10], [esi+8])`;
// `ReadFile([edi+0x10], ebx, ebp, ...)`; on failure log `[esi+0x14]` (the
// entry name) and `[esi+0x10]` (its size).
inline constexpr uint8_t kPlainBlockBytes[] = {
    0x8b, 0x4e, 0x10, 0x8b, 0x46, 0x0c, 0x8b, 0xd1, 0x2b, 0xd0, 0x3b, 0xea,
    0x76, 0x02, 0x8b, 0xea, 0x83, 0xbf, 0x1c, 0x01, 0x00, 0x00, 0x00, 0x89,
    0x6c, 0x24, 0x00, 0x75, 0x00, 0x8b, 0x46, 0x08, 0x8b, 0x4f, 0x10, 0x6a,
    0x00, 0x6a, 0x00, 0x50, 0x51, 0xff, 0x15, 0x00, 0x00, 0x00, 0x00, 0x8b,
    0x47, 0x10, 0x6a, 0x00, 0x8d, 0x54, 0x24, 0x00, 0x52, 0x55, 0x53, 0x50,
    0xff, 0x15, 0x00, 0x00, 0x00, 0x00, 0x85, 0xc0, 0x75, 0x00, 0x8b, 0x4e,
    0x10, 0x51, 0x8d, 0x56, 0x14, 0x52, 0x68};
inline constexpr size_t kPlainBlockWildcards[][2] = {
    {26u, 27u}, {28u, 29u}, {43u, 47u}, {55u, 56u}, {62u, 66u}, {69u, 70u}};
inline constexpr auto kPlainBlockMask =
    cs2::WildcardMask<sizeof(kPlainBlockBytes)>(kPlainBlockWildcards);
inline constexpr size_t kPlainBlockSetFilePointer = 43u;  // import operand
inline constexpr size_t kPlainBlockReadFile = 62u;        // import operand
// The plain block starts within this many bytes after the prologue (past the
// argument checks; 0x58 on the measured build).
inline constexpr size_t kPlainBlockScanBytes = 0x100u;
inline constexpr size_t kPlainBlockWindowBytes =
    kPlainBlockScanBytes + sizeof(kPlainBlockBytes);

struct VoiceImportSlots {
  uintptr_t set_file_pointer = 0u;  // IAT slot RVAs
  uintptr_t read_file = 0u;
};

struct VoiceSites {
  uintptr_t big_read = 0u;     // proof only
  uintptr_t read_entry = 0u;   // hook target
  uintptr_t plain_block = 0u;  // proof only
};

enum class VoiceSiteResult : uint32_t {
  kResolved = 0u,
  kNotX86 = 1u,
  kImportsMissing = 2u,
  kBigReadMissing = 3u,
  kReadEntryInvalid = 4u,
  kPlainBlockMissing = 5u,
  kPlainBlockImportsInvalid = 6u,
};

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
  const auto big_read = cs2::FindUnique(image, kBigReadBytes,
                                        kBigReadMask.data(),
                                        sizeof(kBigReadBytes));
  if (big_read.count != 1u) return VoiceSiteResult::kBigReadMissing;
  uintptr_t read_entry = 0u;
  if (!exact::DecodeRel32CallTarget(big_read.address + kBigReadCall,
                                    &read_entry) ||
      !cs2::IsExecutableImageAddress(image, read_entry,
                                     sizeof(kReadEntryPrologueBytes) +
                                         kPlainBlockWindowBytes) ||
      !cs2::MatchesAt(reinterpret_cast<const uint8_t*>(read_entry),
                      kReadEntryPrologueBytes, kReadEntryPrologueMask.data(),
                      sizeof(kReadEntryPrologueBytes))) {
    return VoiceSiteResult::kReadEntryInvalid;
  }
  const exact::MaskedPattern plain = {kPlainBlockBytes, kPlainBlockMask.data(),
                                      sizeof(kPlainBlockBytes)};
  const auto block = exact::FindUniqueMaskedPattern(
      reinterpret_cast<const uint8_t*>(read_entry) +
          sizeof(kReadEntryPrologueBytes),
      kPlainBlockWindowBytes, plain);
  if (block.count != 1u) return VoiceSiteResult::kPlainBlockMissing;
  if (!cs2::OperandNamesSlot(image, block.address + kPlainBlockSetFilePointer,
                             imports.set_file_pointer) ||
      !cs2::OperandNamesSlot(image, block.address + kPlainBlockReadFile,
                             imports.read_file)) {
    return VoiceSiteResult::kPlainBlockImportsInvalid;
  }
  sites->big_read = reinterpret_cast<uintptr_t>(big_read.address);
  sites->read_entry = read_entry;
  sites->plain_block = reinterpret_cast<uintptr_t>(block.address);
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
