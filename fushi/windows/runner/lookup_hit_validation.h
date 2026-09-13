#ifndef RUNNER_LOOKUP_HIT_VALIDATION_H_
#define RUNNER_LOOKUP_HIT_VALIDATION_H_

#include <cstddef>
#include <cstdint>
#include <string>

namespace fushi::lookup_hit_validation {

inline bool DecodeUtf8Strict(const uint8_t *bytes, size_t byte_count,
                             std::u16string *decoded) {
  if (bytes == nullptr || decoded == nullptr || byte_count == 0)
    return false;
  decoded->clear();
  decoded->reserve(byte_count);
  size_t offset = 0;
  while (offset < byte_count) {
    const uint8_t first = bytes[offset];
    uint32_t scalar = 0;
    size_t units = 0;
    if (first <= 0x7fu) {
      scalar = first;
      units = 1;
    } else if (first >= 0xc2u && first <= 0xdfu) {
      scalar = first & 0x1fu;
      units = 2;
    } else if (first >= 0xe0u && first <= 0xefu) {
      scalar = first & 0x0fu;
      units = 3;
    } else if (first >= 0xf0u && first <= 0xf4u) {
      scalar = first & 0x07u;
      units = 4;
    } else {
      return false;
    }
    if (units > byte_count - offset)
      return false;
    for (size_t index = 1; index < units; ++index) {
      const uint8_t continuation = bytes[offset + index];
      if ((continuation & 0xc0u) != 0x80u)
        return false;
      scalar = (scalar << 6u) | (continuation & 0x3fu);
    }
    if ((units == 3 && first == 0xe0u && bytes[offset + 1] < 0xa0u) ||
        (units == 3 && first == 0xedu && bytes[offset + 1] >= 0xa0u) ||
        (units == 4 && first == 0xf0u && bytes[offset + 1] < 0x90u) ||
        (units == 4 && first == 0xf4u && bytes[offset + 1] >= 0x90u) ||
        scalar > 0x10ffffu || (scalar >= 0xd800u && scalar <= 0xdfffu)) {
      return false;
    }
    if (scalar <= 0xffffu) {
      decoded->push_back(static_cast<char16_t>(scalar));
    } else {
      scalar -= 0x10000u;
      decoded->push_back(static_cast<char16_t>(0xd800u + (scalar >> 10u)));
      decoded->push_back(static_cast<char16_t>(0xdc00u + (scalar & 0x3ffu)));
    }
    offset += units;
  }
  return !decoded->empty();
}

inline bool IsLowSurrogate(char16_t unit) {
  return unit >= 0xdc00u && unit <= 0xdfffu;
}

inline bool IsUtf16ScalarBoundary(const std::u16string &text, size_t index) {
  return index <= text.size() &&
         (index == text.size() || !IsLowSurrogate(text[index]));
}

inline bool ValidateUtf8SourceSpan(const uint8_t *bytes, size_t byte_count,
                                   uint32_t char_count, uint32_t char_index,
                                   uint32_t source_length) {
  std::u16string decoded;
  if (!DecodeUtf8Strict(bytes, byte_count, &decoded) ||
      decoded.size() != char_count || source_length == 0 ||
      char_index >= char_count || source_length > char_count - char_index) {
    return false;
  }
  const size_t end = static_cast<size_t>(char_index) + source_length;
  return IsUtf16ScalarBoundary(decoded, char_index) &&
         IsUtf16ScalarBoundary(decoded, end);
}

inline bool IsProductionProviderPair(uint32_t kind, uint32_t id) {
  switch (kind) {
  case 1u: // runtime layout
    return id == 1u || id == 2u || id == 6u || id == 7u || id == 8u;
  case 2u: // build-pinned exact engine layout
    return id == 3u || id == 4u || id == 5u || id == 14u || id == 15u;
  case 3u: // positioned GDI/DirectWrite
    return id == 9u || id == 10u;
  default:
    return false;
  }
}

inline bool IsProviderLifecycleUsable(uint32_t status, uint64_t generation,
                                      uint64_t text_generation) {
  // OfferReady intentionally precedes the first hit and therefore has no
  // geometry generation yet. Active, in contrast, must identify one complete
  // text+geometry publication.
  return status == 1u ||
         (status == 2u && generation != 0 && text_generation != 0);
}

inline bool IsCoordinateSpaceValid(uint32_t coordinate_space) {
  return coordinate_space >= 1u && coordinate_space <= 4u;
}

inline bool IsGeometryRectSane(int32_t glyph_x, int32_t glyph_y,
                               int32_t glyph_w, int32_t glyph_h, int32_t view_w,
                               int32_t view_h) {
  if (glyph_x < 0 || glyph_y < 0 || glyph_w <= 0 || glyph_h <= 0 ||
      view_w <= 0 || view_h <= 0) {
    return false;
  }
  return static_cast<int64_t>(glyph_x) + glyph_w <= view_w &&
         static_cast<int64_t>(glyph_y) + glyph_h <= view_h;
}

} // namespace fushi::lookup_hit_validation

#endif // RUNNER_LOOKUP_HIT_VALIDATION_H_
