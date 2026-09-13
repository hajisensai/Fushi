#pragma once

#include "siglus_eightarg_runtime.h"
#include "siglus_eightarg_message_capture.h"

namespace fushi_voice_hook::siglus_eightarg_owner {
namespace runtime = siglus_eightarg_runtime;
namespace message = siglus_eightarg_message;

struct Vector {
  uint32_t begin = 0, end = 0, capacity = 0;
};
inline bool Same(const Vector& a, const Vector& b) {
  return a.begin == b.begin && a.end == b.end && a.capacity == b.capacity;
}
inline bool Valid(const Vector& v, uint32_t stride, uint32_t max_count) {
  return v.begin >= 0x10000u && (v.begin & 3u) == 0 &&
      v.begin < v.end && v.end <= v.capacity &&
      (v.end - v.begin) % stride == 0 &&
      (v.capacity - v.begin) % stride == 0 &&
      (v.capacity - v.begin) / stride <= max_count;
}
inline bool Contains(const Vector& v, uint32_t address, uint32_t stride) {
  return address >= v.begin && address < v.end &&
      (address - v.begin) % stride == 0;
}
struct Path {
  uint32_t engine_owner = 0, container = 0, group = 0;
  Vector owners, glyphs;
  message::Owner body{};
  uint8_t active = 0;
  int32_t animation = 0;
};
inline bool Same(const Path& a, const Path& b) {
  return a.engine_owner == b.engine_owner && a.container == b.container &&
      a.group == b.group && Same(a.owners, b.owners) && Same(a.glyphs, b.glyphs) &&
      message::Same(a.body, b.body) && a.active == b.active && a.animation == b.animation;
}

inline bool ReadVector(runtime::Read read, void* context, uint32_t object,
                       uint32_t offset, Vector* out) {
  return runtime::Scalar(read, context, object, offset, &out->begin) &&
      runtime::Scalar(read, context, object, offset + 4, &out->end) &&
      runtime::Scalar(read, context, object, offset + 8, &out->capacity);
}

// Requires the separately admitted normal-group selector/render root proof.
// Only the script's primary group (+0x734) is accepted. The auxiliary root
// at +0x48d10 and the second group (+0xe68) are not inferred from similarity.
inline bool ReadSelectedBodyOnce(uint32_t engine_owner, const message::Owner& frozen,
                     runtime::Read read, void* context, Path* out) {
  Path p;
  if (engine_owner < 0x10000u || (engine_owner & 3u) != 0 ||
      !runtime::Scalar(read, context, engine_owner, 0x4293c, &p.container) ||
      p.container < 0x10000u || (p.container & 3u) != 0 ||
      !runtime::Add(p.container, 0x734, &p.group) ||
      !ReadVector(read, context, p.group, 0x3b8, &p.owners) ||
      !Valid(p.owners, 0x1630, 256) ||
      !Contains(p.owners, frozen.address, 0x1630)) return false;
  auto word = [&](uint32_t address, uint32_t* value) {
    return runtime::Scalar(read, context, address, 0, value);
  };
  if (!message::ReadOwner(frozen.address, word, &p.body) ||
      !message::Same(frozen, p.body)) return false;
  p.engine_owner = engine_owner;
  *out = p;
  return true;
}

// Message entry precedes Scenario constructing its glyph vector. Freeze only
// the selected normal body here; visible/input admission still needs ReadPath.
inline bool ReadSelectedBody(uint32_t engine_owner, const message::Owner& frozen,
                             runtime::Read read, void* context, Path* out) {
  if (!out) return false;
  *out = {};
  if (!read) return false;
  Path first, second;
  if (!ReadSelectedBodyOnce(engine_owner, frozen, read, context, &first) ||
      !ReadSelectedBodyOnce(engine_owner, frozen, read, context, &second) ||
      !Same(first, second)) return false;
  *out = second;
  return true;
}

inline bool ReadOnce(uint32_t engine_owner, const message::Owner& frozen,
                     runtime::Read read, void* context, Path* out) {
  Path p;
  if (!ReadSelectedBodyOnce(engine_owner, frozen, read, context, &p) ||
      !runtime::Scalar(read, context, frozen.address, 0x156, &p.active) ||
      !runtime::Scalar(read, context, frozen.address, 0x18c, &p.animation) ||
      (p.active == 0 && p.animation < 0) ||
      !ReadVector(read, context, p.body.surface, 0x118, &p.glyphs) ||
      !Valid(p.glyphs, 0x3b4, 1024)) return false;
  p.engine_owner = engine_owner;
  *out = p;
  return true;
}

inline bool ReadPath(uint32_t engine_owner, const message::Owner& frozen,
                     runtime::Read read, void* context, Path* out) {
  if (!out) return false;
  *out = {};
  if (!read) return false;
  Path first, second;
  if (!ReadOnce(engine_owner, frozen, read, context, &first) ||
      !ReadOnce(engine_owner, frozen, read, context, &second) ||
      !Same(first, second)) return false;
  *out = second;
  return true;
}

// The worker's path is paired with the committed text identity. Callers also
// revalidate the root/window snapshot; pointer reuse alone is not an occurrence.
inline bool ContainsCurrentGlyph(const Path& path, uint32_t glyph,
                                 runtime::Read read, void* context) {
  if (!Contains(path.glyphs, glyph, 0x3b4)) return false;
  Path current;
  return ReadPath(path.engine_owner, path.body, read, context, &current) &&
      Same(path, current);
}

}  // namespace fushi_voice_hook::siglus_eightarg_owner
