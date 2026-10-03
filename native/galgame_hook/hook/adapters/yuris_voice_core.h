#pragma once

// YU-RIS voice at the decoder input: pure, unit-tested half.
//
// Engine facts (x86; read from a 2011 v500 build and a 2016 v481 build):
//   * Every Ogg sound is handed to the statically linked libvorbisfile as a
//     memory stream: the engine copies a static ov_callbacks table (read /
//     seek / close / tell, four code pointers) onto the stack and calls
//     ov_open_callbacks(sound, &vf, NULL, 0, callbacks) with its own sound
//     object as the datasource.  Three call sites (open, reopen, restart)
//     share the table and the target.
//   * The table's read callback reads the object's memory stream:
//       mov ebp,[esp+0x1c]; mov edx,[ebp+POS]; mov eax,[ebp+SIZE];
//       cmp edx,eax; ... mov ecx,[ebp+DATA]
//     so the encoded Ogg handed to the decoder is DATA[0..SIZE).
//   * The sound object begins with the name the script asked for (the
//     resource path), NUL-terminated.
//
// Voice is taken here — after the engine read and unpacked the resource and
// as it hands the bytes to the decoder — never from archive reads.

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "yuris_lookup_core.h"

namespace fushi_voice_hook::yuris_voice {

namespace yl = fushi_voice_hook::yuris_lookup;

// A voice clip belongs to the first message shown within this window after
// the clip opened.
inline constexpr uint64_t kVoiceToTextWindowMs = 1500u;

// ── binding a message to its voice clip ────────────────────────────────────
//
// The script plays a line's voice and then shows the line, so a clip can only
// belong to the first message pushed after it opened.  `texts_before` is the
// number of messages the engine had pushed when the clip opened (the text
// ring's counter, read at capture), `order` the clip's open sequence (strict,
// assigned at capture) and `tick` its open time.
struct PendingClip {
  bool used = false;
  uint64_t tick = 0u;
  uint64_t order = 0u;
  uint64_t texts_before = 0u;
};

enum class ClipFate : uint8_t {
  kKeep = 0,    // opened after this message: waits for a later one
  kBind = 1,    // the voice of this message (written with its text event id)
  kOrphan = 2,  // opened before this message but not its voice: no owner
};

// Settles every pending clip that opened before message `text_order`
// (1-based text ring sequence) at `text_tick`.  At most one clip is bound: the
// last one opened within kVoiceToTextWindowMs before the message, and only
// when the message became a new published line (`new_line`).  Every other
// clip that opened before the message can no longer belong to any later
// message and loses its owner now instead of waiting for the next line: a
// rejected / unpublished / repeated message never hands its clips on.
// Returns the index of the bound clip, or `count` when none is bound.
inline size_t SettlePendingClips(const PendingClip* clips, size_t count,
                                 uint64_t text_order, uint64_t text_tick,
                                 bool new_line, ClipFate* fates) {
  if (clips == nullptr || fates == nullptr) return count;
  size_t bound = count;
  for (size_t i = 0u; i < count; ++i) {
    const PendingClip& clip = clips[i];
    if (!clip.used || clip.texts_before >= text_order) {
      fates[i] = ClipFate::kKeep;
      continue;
    }
    fates[i] = ClipFate::kOrphan;
    const bool in_window = text_tick >= clip.tick &&
                           text_tick - clip.tick <= kVoiceToTextWindowMs;
    if (new_line && in_window &&
        (bound == count || clip.order > clips[bound].order)) {
      bound = i;
    }
  }
  if (bound < count) fates[bound] = ClipFate::kBind;
  return bound;
}

struct DecoderSites {
  uint32_t ov_open = 0u;     // RVA of ov_open_callbacks
  uint32_t callbacks = 0u;   // RVA of the static ov_callbacks table
  uint32_t data = 0u;        // sound+data   -> encoded bytes
  uint32_t size = 0u;        // sound+size   -> byte count
  uint32_t position = 0u;    // sound+position (read cursor)
  uint32_t sites = 0u;       // call sites found
};

enum class DecoderResult : uint32_t {
  kResolved = 0,
  kNoCallSite = 1,
  kAmbiguous = 2,
  kReadCallbackShape = 3,
};

// The read callback's memory-stream fields.
inline bool DecodeReadCallback(const yl::ImageView& image, uint32_t read,
                               uint32_t* position, uint32_t* size,
                               uint32_t* data) {
  // push edi; push esi; push ebp; mov ebp,[esp+0x1c]
  static constexpr uint8_t kHead[] = {0x57, 0x56, 0x55, 0x8b, 0x6c, 0x24, 0x1c};
  if (!yl::InCode(image, read, 0x40u) ||
      std::memcmp(image.bytes + read, kHead, sizeof(kHead)) != 0) {
    return false;
  }
  // mov r,[ebp+POS] ; mov r2,[ebp+SIZE] ; cmp r,r2
  const uint32_t a = read + sizeof(kHead);
  if (yl::U8(image, a) != 0x8bu || (yl::U8(image, a + 1u) & 0xc7u) != 0x85u ||
      yl::U8(image, a + 6u) != 0x8bu ||
      (yl::U8(image, a + 7u) & 0xc7u) != 0x85u ||
      yl::U8(image, a + 12u) != 0x3bu) {
    return false;
  }
  const uint8_t pos_reg = static_cast<uint8_t>((yl::U8(image, a + 1u) >> 3) & 7u);
  const uint8_t size_reg =
      static_cast<uint8_t>((yl::U8(image, a + 7u) >> 3) & 7u);
  const uint8_t cmp = yl::U8(image, a + 13u);
  if ((cmp >> 6) != 3u || ((cmp >> 3) & 7u) != pos_reg ||
      (cmp & 7u) != size_reg) {
    return false;
  }
  const uint32_t pos = yl::U32(image, a + 2u);
  const uint32_t count = yl::U32(image, a + 8u);
  // The data pointer: the next `mov r,[ebp+disp32]` within the callback.
  for (uint32_t at = a + 14u; at + 6u <= read + 0x40u; ++at) {
    if (yl::U8(image, at) == 0x8bu &&
        (yl::U8(image, at + 1u) & 0xc7u) == 0x85u) {
      const uint32_t disp = yl::U32(image, at + 2u);
      if (disp == pos || disp == count) continue;
      *position = pos;
      *size = count;
      *data = disp;
      return true;
    }
  }
  return false;
}

// `lea r,[TABLE]` (8D modrm 00/reg/101) where TABLE holds four code pointers,
// followed within 0x24 bytes by the call that takes the copied table.
inline DecoderResult ResolveDecoderSites(const yl::ImageView& image,
                                         DecoderSites* out) {
  DecoderSites found;
  for (size_t r = 0u; r < image.code_count; ++r) {
    for (uint32_t at = image.code[r].begin; at + 0x30u <= image.code[r].end;
         ++at) {
      const uint8_t m = yl::U8(image, at + 1u);
      if (yl::U8(image, at) != 0x8du || (m & 0xc7u) != 0x05u) continue;
      const uint32_t table = yl::VaToRva(image, yl::U32(image, at + 2u));
      if (table == 0u || table + 16u > image.size ||
          yl::InCode(image, table, 16u)) {
        continue;
      }
      bool code = true;
      for (uint32_t k = 0u; k < 4u; ++k) {
        const uint32_t fn = yl::VaToRva(image, yl::U32(image, table + 4u * k));
        code = code && fn != 0u && yl::InCode(image, fn, 16u);
      }
      if (!code) continue;
      uint32_t target = 0u;
      for (uint32_t q = at + 6u; q + 5u <= at + 0x24u; ++q) {
        if (yl::U8(image, q) == 0xe8u && yl::Rel32Target(image, q, &target)) {
          break;
        }
      }
      if (target == 0u || !yl::InCode(image, target, 16u)) continue;
      if (found.sites != 0u &&
          (found.ov_open != target || found.callbacks != table)) {
        return DecoderResult::kAmbiguous;
      }
      found.ov_open = target;
      found.callbacks = table;
      ++found.sites;
    }
  }
  if (found.sites == 0u) return DecoderResult::kNoCallSite;
  const uint32_t read = yl::VaToRva(image, yl::U32(image, found.callbacks));
  if (!DecodeReadCallback(image, read, &found.position, &found.size,
                          &found.data)) {
    return DecoderResult::kReadCallbackShape;
  }
  if (out != nullptr) *out = found;
  return DecoderResult::kResolved;
}

// Channel count from the Vorbis identification header that opens an Ogg
// stream (first page, first packet).  0 = not a Vorbis stream.
inline uint32_t OggVorbisChannels(const uint8_t* bytes, size_t size,
                                  uint32_t* sample_rate = nullptr) {
  if (bytes == nullptr || size < 28u || std::memcmp(bytes, "OggS", 4) != 0 ||
      bytes[4] != 0u) {
    return 0u;
  }
  const size_t segments = bytes[26];
  const size_t packet = 27u + segments;
  if (size < packet + 16u || bytes[packet] != 1u ||
      std::memcmp(bytes + packet + 1u, "vorbis", 6) != 0) {
    return 0u;
  }
  uint32_t version = 0u;
  std::memcpy(&version, bytes + packet + 7u, 4u);
  if (version != 0u) return 0u;
  if (sample_rate != nullptr) std::memcpy(sample_rate, bytes + packet + 12u, 4u);
  return bytes[packet + 11u];
}

// The basename of the engine's resource name ("voice\a\b.ogg" -> "b.ogg");
// empty when the name is not a printable CP932 path ending in .ogg.
inline size_t ResourceBasename(const char* name, size_t bound, char* out,
                               size_t out_bytes) {
  if (name == nullptr || out == nullptr || out_bytes == 0u) return 0u;
  size_t length = 0u;
  while (length < bound && name[length] != '\0') {
    if (static_cast<uint8_t>(name[length]) < 0x20u) return 0u;
    ++length;
  }
  if (length == bound || length < 5u) return 0u;
  const char* ext = name + length - 4u;
  if (ext[0] != '.' || (ext[1] | 0x20) != 'o' || (ext[2] | 0x20) != 'g' ||
      (ext[3] | 0x20) != 'g') {
    return 0u;
  }
  size_t start = 0u;
  for (size_t i = 0u; i < length; ++i) {
    if (name[i] == '\\' || name[i] == '/') start = i + 1u;
  }
  const size_t bytes = length - start;
  if (bytes == 0u || bytes + 1u > out_bytes) return 0u;
  std::memcpy(out, name + start, bytes);
  out[bytes] = '\0';
  return bytes;
}

}  // namespace fushi_voice_hook::yuris_voice
