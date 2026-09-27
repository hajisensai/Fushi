#pragma once

// Unity (Mono runtime) in-game lookup: pure, unit-tested half.
//
// Scope: the per-glyph TextMesh message framework the Mono text path already
// admits structurally (unity_mono_text.h: instance `string Message.Mes(string,
// bool)` in Assembly-CSharp plus the static `Game.NewText(... string ...)`
// eight-argument factory).  That framework lays a message out as one
// GameObject per displayed UTF-16 unit: `Message.messageSprite` is a
// `List<List<GameObject>>` (one inner list per rendered line) and
// `Message.LastMes` is the plain text Mes returned — every line's units
// followed by '\n'.  `Message.FixedUpdate` places every glyph object and
// switches it active as the typing reveal reaches it.
//
// Engine facts used (Unity 2019.2 MonoBleedingEdge player, x86; measured
// 2026-09-27 with Frida on the デスマッチラブコメ！ Steam build — the sample
// only, never an identity input):
//   * Unity engine calls are Mono internal calls registered by the player
//     (`mono_lookup_internal_call` resolves them from the managed extern
//     declaration); on x86 every one is a plain cdecl C function (`ret`, no
//     stack pop).  The `_Injected` variants take `this` first and return
//     struct results through an out pointer.
//   * Screen space: `Camera.WorldToScreenPoint` of the renderer's world AABB
//     corners gives Unity screen pixels, origin bottom-left, in the same
//     pixel grid as `Screen.width/height`, which equals the window client in
//     the window's own DPI context (the player is per-monitor DPI aware: a
//     1280x720 client at 192 dpi reports Screen 1280x720; lparam (640,360)
//     reads Input.mousePosition (640,359)).
//   * Input: Unity's legacy input manager takes mouse buttons from the
//     window procedure.  Swallowing WM_LBUTTONDOWN/UP in the UnityWndClass
//     window procedure keeps Input.GetMouseButtonDown/Up(0) false for that
//     click (measured with a real SendInput click).
//   * Overlay scenes of this framework (backlog) load additively, become the
//     active scene and then deactivate the message object; while the message
//     scene is not the active scene its glyphs are not the thing on top.
//
// Nothing here consults a hash, file name or title.  Every class, method,
// field and internal call is resolved by namespace + name + full signature +
// internal-call flag; a missing or ambiguous piece installs nothing.

#include <windows.h>

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "unity_mono_text.h"

// Unity internal calls are C functions: cdecl on x86, the Win64 ABI on x64.
#if defined(_M_IX86)
#define FUSHI_UNITY_ICALL __cdecl
#else
#define FUSHI_UNITY_ICALL
#endif

namespace fushi_voice_hook::unity_mono_lookup {

// ── metadata constants ──────────────────────────────────────────────────────

inline constexpr int kMonoTypeI4 = 0x08;
inline constexpr int kMonoTypeValueType = 0x11;
inline constexpr int kMonoTypeGenericInst = 0x15;
inline constexpr int kMonoTypeI = 0x18;
inline constexpr int kMonoTypeSzArray = 0x1d;
// METHOD_IMPL_ATTRIBUTE_INTERNAL_CALL (ECMA-335 II.23.1.11).
inline constexpr uint32_t kMethodImplInternalCall = 0x1000u;
// MonoOrStereoscopicEye.Mono.
inline constexpr int32_t kMonoEye = 2;
// Upper bound for any instance field offset we accept.
inline constexpr uint32_t kMaxFieldOffset = 4096u;

// ── extra embedding API used by the lookup (on top of MonoEmbeddingApi) ─────

struct MonoLookupApi {
  void* (*class_get_field_from_name)(void* klass, const char* name) = nullptr;
  uint32_t (*field_get_offset)(void* field) = nullptr;
  void* (*field_get_type)(void* field) = nullptr;
  void* (*class_from_mono_type)(void* type) = nullptr;
  void* (*class_get_element_class)(void* klass) = nullptr;
  void* (*lookup_internal_call)(void* method) = nullptr;
  uint32_t (*method_get_flags)(void* method, uint32_t* iflags) = nullptr;
  void* (*class_get_type)(void* klass) = nullptr;
  void* (*type_get_object)(void* domain, void* type) = nullptr;
  uint32_t (*gchandle_new)(void* object, int32_t pinned) = nullptr;
  int32_t (*type_is_byref)(void* type) = nullptr;
  uintptr_t (*array_length)(void* array) = nullptr;
  char* (*array_addr_with_size)(void* array, int32_t size,
                                uintptr_t index) = nullptr;

  bool Complete() const {
    return class_get_field_from_name != nullptr &&
           field_get_offset != nullptr && field_get_type != nullptr &&
           class_from_mono_type != nullptr &&
           class_get_element_class != nullptr &&
           lookup_internal_call != nullptr && method_get_flags != nullptr &&
           class_get_type != nullptr && type_get_object != nullptr &&
           gchandle_new != nullptr && type_is_byref != nullptr &&
           array_length != nullptr && array_addr_with_size != nullptr;
  }
};

// ── internal calls ──────────────────────────────────────────────────────────

enum class Icall : uint8_t {
  kCameraMain = 0,
  kCameraWorldToScreen,
  kCameraCullingMask,
  kCameraTargetTexture,
  kCameraOrthographic,
  kScreenWidth,
  kScreenHeight,
  kGameObjectActive,
  kGameObjectGetComponent,
  kGameObjectLayer,
  kGameObjectScene,
  kActiveScene,
  kRendererBounds,
  kRendererEnabled,
  kCount,
};
inline constexpr size_t kIcallCount = static_cast<size_t>(Icall::kCount);

struct IcallSpec {
  Icall id;
  const char* name_space;
  const char* class_name;
  const char* method;
  bool instance;
  int return_type;
  uint8_t param_count;
  int params[3];
  uint8_t byref_mask;  // bit i: parameter i is ref/out
};

// Every entry is an `extern` engine binding of UnityEngine.CoreModule
// (searched in every loaded image; the module split differs across Unity
// versions).  Signatures are matched exactly, including by-ref-ness.
inline constexpr IcallSpec kIcallSpecs[kIcallCount] = {
    {Icall::kCameraMain, "UnityEngine", "Camera", "get_main", false,
     kMonoTypeClass, 0, {0, 0, 0}, 0u},
    {Icall::kCameraWorldToScreen, "UnityEngine", "Camera",
     "WorldToScreenPoint_Injected", true, kMonoTypeVoid, 3,
     {kMonoTypeValueType, kMonoTypeValueType, kMonoTypeValueType}, 0x5u},
    {Icall::kCameraCullingMask, "UnityEngine", "Camera", "get_cullingMask",
     true, kMonoTypeI4, 0, {0, 0, 0}, 0u},
    {Icall::kCameraTargetTexture, "UnityEngine", "Camera", "get_targetTexture",
     true, kMonoTypeClass, 0, {0, 0, 0}, 0u},
    {Icall::kCameraOrthographic, "UnityEngine", "Camera", "get_orthographic",
     true, kMonoTypeBoolean, 0, {0, 0, 0}, 0u},
    {Icall::kScreenWidth, "UnityEngine", "Screen", "get_width", false,
     kMonoTypeI4, 0, {0, 0, 0}, 0u},
    {Icall::kScreenHeight, "UnityEngine", "Screen", "get_height", false,
     kMonoTypeI4, 0, {0, 0, 0}, 0u},
    {Icall::kGameObjectActive, "UnityEngine", "GameObject",
     "get_activeInHierarchy", true, kMonoTypeBoolean, 0, {0, 0, 0}, 0u},
    {Icall::kGameObjectGetComponent, "UnityEngine", "GameObject",
     "GetComponent", true, kMonoTypeClass, 1, {kMonoTypeClass, 0, 0}, 0u},
    {Icall::kGameObjectLayer, "UnityEngine", "GameObject", "get_layer", true,
     kMonoTypeI4, 0, {0, 0, 0}, 0u},
    {Icall::kGameObjectScene, "UnityEngine", "GameObject",
     "get_scene_Injected", true, kMonoTypeVoid, 1,
     {kMonoTypeValueType, 0, 0}, 0x1u},
    {Icall::kActiveScene, "UnityEngine.SceneManagement", "SceneManager",
     "GetActiveScene_Injected", false, kMonoTypeVoid, 1,
     {kMonoTypeValueType, 0, 0}, 0x1u},
    {Icall::kRendererBounds, "UnityEngine", "Renderer", "get_bounds_Injected",
     true, kMonoTypeVoid, 1, {kMonoTypeValueType, 0, 0}, 0x1u},
    {Icall::kRendererEnabled, "UnityEngine", "Renderer", "get_enabled", true,
     kMonoTypeBoolean, 0, {0, 0, 0}, 0u},
};

struct Vec3 {
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
};
struct Bounds {
  Vec3 center;
  Vec3 extents;
};
static_assert(sizeof(Vec3) == 12 && sizeof(Bounds) == 24,
              "UnityEngine.Vector3 / Bounds layout");

using IcallObjectFn = void*(FUSHI_UNITY_ICALL*)();
using IcallWorldToScreenFn = void(FUSHI_UNITY_ICALL*)(void* camera,
                                                     const Vec3* position,
                                                     int32_t eye, Vec3* out);
using IcallInstanceIntFn = int32_t(FUSHI_UNITY_ICALL*)(void* self);
using IcallInstanceObjectFn = void*(FUSHI_UNITY_ICALL*)(void* self);
using IcallStaticIntFn = int32_t(FUSHI_UNITY_ICALL*)();
using IcallInstanceBoolFn = bool(FUSHI_UNITY_ICALL*)(void* self);
using IcallGetComponentFn = void*(FUSHI_UNITY_ICALL*)(void* self, void* type);
using IcallInstanceOutFn = void(FUSHI_UNITY_ICALL*)(void* self, void* out);
using IcallStaticOutFn = void(FUSHI_UNITY_ICALL*)(void* out);

// ── resolved sites ──────────────────────────────────────────────────────────

struct Sites {
  void* fixed_update = nullptr;  // MonoMethod* of Message.FixedUpdate
  uint32_t message_sprite_offset = 0u;  // Message.messageSprite
  uint32_t last_mes_offset = 0u;        // Message.LastMes
  uint32_t list_items_offset = 0u;      // List`1._items (both levels)
  uint32_t list_size_offset = 0u;       // List`1._size (both levels)
  uint32_t cached_ptr_offset = 0u;      // UnityEngine.Object.m_CachedPtr
  void* renderer_type = nullptr;        // System.Type of UnityEngine.Renderer
  std::array<void*, kIcallCount> icalls{};

  template <typename Fn>
  Fn Get(Icall id) const {
    return reinterpret_cast<Fn>(icalls[static_cast<size_t>(id)]);
  }
};

enum class SiteResult : uint32_t {
  kResolved = 0,
  kApiIncomplete = 1,
  kNoScriptImage = 2,
  kNoMessageClass = 3,
  kNoFixedUpdate = 4,
  kMessageFieldsMissing = 5,
  kListLayoutMismatch = 6,
  kElementNotGameObject = 7,
  kObjectFieldMissing = 8,
  kIcallMissing = 9,  // + kIcallMissingBase detail in the resolver output
  kRendererTypeMissing = 10,
};

struct SiteResolution {
  SiteResult result = SiteResult::kApiIncomplete;
  int32_t missing_icall = -1;  // Icall index when result == kIcallMissing
};

inline void* FindClassInImages(const MonoEmbeddingApi& api,
                               const MonoAssemblyList& list,
                               const char* name_space, const char* name) {
  void* found = nullptr;
  for (size_t i = 0; i < list.count; ++i) {
    void* image = api.assembly_get_image(list.assemblies[i]);
    if (image == nullptr) continue;
    void* klass = api.class_from_name(image, name_space, name);
    if (klass == nullptr) continue;
    // The same namespace-qualified engine type in two images is not a shape
    // we can reason about.
    if (found != nullptr && found != klass) return nullptr;
    found = klass;
  }
  return found;
}

inline bool ParamsByrefMatch(const MonoEmbeddingApi& api,
                             const MonoLookupApi& lookup, void* method,
                             uint8_t count, uint8_t byref_mask) {
  void* signature = api.method_signature(method);
  if (signature == nullptr) return false;
  void* iter = nullptr;
  for (uint8_t i = 0; i < count; ++i) {
    void* type = api.signature_get_params(signature, &iter);
    if (type == nullptr) return false;
    const bool byref = lookup.type_is_byref(type) != 0;
    if (byref != (((byref_mask >> i) & 1u) != 0u)) return false;
  }
  return true;
}

// Finds the single declared method matching the spec that is an internal
// call, and returns the registered C entry.
inline void* ResolveIcall(const MonoEmbeddingApi& api,
                          const MonoLookupApi& lookup,
                          const MonoAssemblyList& list, const IcallSpec& spec) {
  void* klass = FindClassInImages(api, list, spec.name_space, spec.class_name);
  if (klass == nullptr) return nullptr;
  void* match = nullptr;
  void* iter = nullptr;
  for (int guard = 0; guard < 8192; ++guard) {
    void* method = api.class_get_methods(klass, &iter);
    if (method == nullptr) break;
    const char* name = api.method_get_name(method);
    if (name == nullptr || std::strcmp(name, spec.method) != 0) continue;
    if (!MonoSignatureMatches(api, method, spec.instance, spec.return_type,
                              spec.param_count,
                              spec.param_count == 0 ? nullptr : spec.params,
                              -1) ||
        !ParamsByrefMatch(api, lookup, method, spec.param_count,
                          spec.byref_mask)) {
      continue;
    }
    uint32_t iflags = 0u;
    lookup.method_get_flags(method, &iflags);
    if ((iflags & kMethodImplInternalCall) == 0u) continue;
    if (match != nullptr) return nullptr;  // two identical externs: refuse
    match = method;
  }
  return match == nullptr ? nullptr : lookup.lookup_internal_call(match);
}

inline bool FieldOfType(const MonoEmbeddingApi& api,
                        const MonoLookupApi& lookup, void* klass,
                        const char* name, int type_kind, void** field_out,
                        uint32_t* offset_out) {
  if (klass == nullptr) return false;
  void* field = lookup.class_get_field_from_name(klass, name);
  if (field == nullptr) return false;
  void* type = lookup.field_get_type(field);
  if (type == nullptr || api.type_get_type(type) != type_kind ||
      lookup.type_is_byref(type) != 0) {
    return false;
  }
  const uint32_t offset = lookup.field_get_offset(field);
  // An instance field lives after the object header.
  if (offset < 2u * sizeof(void*) || offset >= kMaxFieldOffset) return false;
  if (field_out != nullptr) *field_out = field;
  *offset_out = offset;
  return true;
}

// List`1 layout of one closed instantiation: `_items` (T[]) and `_size`
// (int).  Returns the element class of `_items`.
inline void* ListLayout(const MonoEmbeddingApi& api,
                        const MonoLookupApi& lookup, void* list_class,
                        uint32_t* items_offset, uint32_t* size_offset) {
  void* items = nullptr;
  if (!FieldOfType(api, lookup, list_class, "_items", kMonoTypeSzArray, &items,
                   items_offset) ||
      !FieldOfType(api, lookup, list_class, "_size", kMonoTypeI4, nullptr,
                   size_offset) ||
      *items_offset == *size_offset) {
    return nullptr;
  }
  void* array_class = lookup.class_from_mono_type(lookup.field_get_type(items));
  return array_class == nullptr ? nullptr
                                : lookup.class_get_element_class(array_class);
}

// Caller must be attached to the root domain.  `script_image` is the
// Assembly-CSharp image the text path already found.
inline SiteResolution ResolveSites(const MonoEmbeddingApi& api,
                                   const MonoLookupApi& lookup, void* domain,
                                   Sites* out) {
  SiteResolution resolution;
  if (out == nullptr || !api.CompleteForResolution() || !lookup.Complete()) {
    return resolution;
  }
  *out = Sites();
  MonoAssemblyList list;
  api.assembly_foreach(&CollectMonoAssembly, &list);
  void* script_image = nullptr;
  for (size_t i = 0; i < list.count; ++i) {
    void* image = api.assembly_get_image(list.assemblies[i]);
    const char* name = image == nullptr ? nullptr : api.image_get_name(image);
    if (name != nullptr && std::strcmp(name, kUnityScriptAssemblyImage) == 0) {
      script_image = image;
      break;
    }
  }
  if (script_image == nullptr) {
    resolution.result = SiteResult::kNoScriptImage;
    return resolution;
  }
  const MonoTextHookSpec& mes =
      MonoTextHookSpecFor(MonoTextHookId::kMessageRendererMes);
  void* message = api.class_from_name(script_image, mes.name_space,
                                      mes.class_name);
  if (message == nullptr) {
    resolution.result = SiteResult::kNoMessageClass;
    return resolution;
  }
  out->fixed_update = FindMonoMethod(api, message, "FixedUpdate", true,
                                     kMonoTypeVoid, 0, nullptr);
  if (out->fixed_update == nullptr) {
    resolution.result = SiteResult::kNoFixedUpdate;
    return resolution;
  }
  void* sprite_field = nullptr;
  if (!FieldOfType(api, lookup, message, "messageSprite", kMonoTypeGenericInst,
                   &sprite_field, &out->message_sprite_offset) ||
      !FieldOfType(api, lookup, message, "LastMes", kMonoTypeString, nullptr,
                   &out->last_mes_offset)) {
    resolution.result = SiteResult::kMessageFieldsMissing;
    return resolution;
  }
  // messageSprite must be List<List<GameObject>>: both levels share one
  // List`1 layout and the inner element class is UnityEngine.GameObject.
  void* outer = lookup.class_from_mono_type(lookup.field_get_type(sprite_field));
  uint32_t inner_items = 0u, inner_size = 0u;
  void* inner = ListLayout(api, lookup, outer, &out->list_items_offset,
                           &out->list_size_offset);
  void* element = ListLayout(api, lookup, inner, &inner_items, &inner_size);
  if (inner == nullptr || element == nullptr ||
      inner_items != out->list_items_offset ||
      inner_size != out->list_size_offset) {
    resolution.result = SiteResult::kListLayoutMismatch;
    return resolution;
  }
  void* game_object = FindClassInImages(api, list, "UnityEngine", "GameObject");
  if (game_object == nullptr || element != game_object) {
    resolution.result = SiteResult::kElementNotGameObject;
    return resolution;
  }
  void* unity_object = FindClassInImages(api, list, "UnityEngine", "Object");
  if (!FieldOfType(api, lookup, unity_object, "m_CachedPtr", kMonoTypeI,
                   nullptr, &out->cached_ptr_offset)) {
    resolution.result = SiteResult::kObjectFieldMissing;
    return resolution;
  }
  for (const IcallSpec& spec : kIcallSpecs) {
    void* entry = ResolveIcall(api, lookup, list, spec);
    if (entry == nullptr) {
      resolution.result = SiteResult::kIcallMissing;
      resolution.missing_icall = static_cast<int32_t>(spec.id);
      return resolution;
    }
    out->icalls[static_cast<size_t>(spec.id)] = entry;
  }
  void* renderer = FindClassInImages(api, list, "UnityEngine", "Renderer");
  void* renderer_type =
      renderer == nullptr ? nullptr : lookup.class_get_type(renderer);
  void* type_object = renderer_type == nullptr
                          ? nullptr
                          : lookup.type_get_object(domain, renderer_type);
  // The reflection object is cached by the runtime; the handle only makes the
  // lifetime explicit (the Boehm collector never moves it).
  if (type_object == nullptr || lookup.gchandle_new(type_object, 1) == 0u) {
    resolution.result = SiteResult::kRendererTypeMissing;
    return resolution;
  }
  out->renderer_type = type_object;
  resolution.result = SiteResult::kResolved;
  return resolution;
}

// ── text lane role of a framework message object ────────────────────────────
//
// The framework draws the dialogue body and the speaker name plate with two
// objects of the same Message class, and the script calls body.Mes(text)
// then name.Mes(speaker) for every spoken line.  With one lane for both the
// lane's latest line is the speaker name (measured: `「…」` followed by the
// name at the same tick), so the body is never the selected line.  The role
// key is the object's name as the scene authored it: stable when the scene
// reloads and the component is recreated, different for body and plate.  It
// is only an opaque identity (hashed), never compared to any literal.
inline constexpr IcallSpec kObjectGetNameSpec = {
    Icall::kCount, "UnityEngine", "Object", "GetName", false, kMonoTypeString,
    1, {kMonoTypeClass, 0, 0}, 0u};
using IcallGetNameFn = void*(FUSHI_UNITY_ICALL*)(void* object);

inline void* ResolveObjectGetName(const MonoEmbeddingApi& api,
                                  const MonoLookupApi& lookup) {
  if (!api.CompleteForResolution() || lookup.lookup_internal_call == nullptr ||
      lookup.method_get_flags == nullptr || lookup.type_is_byref == nullptr) {
    return nullptr;
  }
  MonoAssemblyList list;
  api.assembly_foreach(&CollectMonoAssembly, &list);
  return ResolveIcall(api, lookup, list, kObjectGetNameSpec);
}

inline constexpr int kMaxRoleNameUnits = 64;

// 0 means "no role" (the caller keeps the plain stable lane).
inline uint64_t MessageRoleKey(const wchar_t* chars, int length) {
  if (chars == nullptr || length <= 0) return 0u;
  const int bounded = length > kMaxRoleNameUnits ? kMaxRoleNameUnits : length;
  uint64_t hash = 1469598103934665603ull ^ 0x524f4c45ull;  // "ROLE"
  for (int i = 0; i < bounded; ++i) {
    hash ^= static_cast<uint16_t>(chars[i]);
    hash *= 1099511628211ull;
  }
  return hash == 0u ? 1u : hash;
}

// ── snapshot model ──────────────────────────────────────────────────────────

inline constexpr size_t kMaxGlyphs = 256u;
inline constexpr size_t kMaxLineUnits = 512u;
inline constexpr size_t kMaxRenderedLines = 16u;
inline constexpr size_t kInstanceSlots = 4u;
inline constexpr uint16_t kNoSource = 0xffffu;

// One glyph in Unity screen pixels (origin bottom-left).
struct GlyphCell {
  float x0 = 0.0f;
  float y0 = 0.0f;
  float x1 = 0.0f;
  float y1 = 0.0f;
  uint8_t visible = 0u;
};

// A glyph is on screen iff its object is active in the hierarchy, its
// renderer is enabled, the camera renders its layer, its scene is the active
// scene (an overlay scene of the framework is not), and its projected cell is
// finite, non-empty and in front of the camera.
inline bool GlyphVisible(bool active, bool renderer_enabled, int32_t scene,
                         int32_t active_scene, int32_t layer,
                         int32_t culling_mask) {
  return active && renderer_enabled && scene != 0 && scene == active_scene &&
         layer >= 0 && layer < 32 &&
         ((static_cast<uint32_t>(culling_mask) >> layer) & 1u) != 0u;
}

// WorldToScreenPoint's z is the view depth.  An orthographic camera may use
// a negative near plane (the measured player: glyphs at depth -530 are drawn),
// so only a perspective camera requires the point in front of it.
inline bool CellFromScreenCorners(const Vec3& a, const Vec3& b,
                                  bool orthographic, GlyphCell* out) {
  if (out == nullptr || !std::isfinite(a.x) || !std::isfinite(a.y) ||
      !std::isfinite(b.x) || !std::isfinite(b.y) || !std::isfinite(a.z) ||
      !std::isfinite(b.z) || (!orthographic && (a.z <= 0.0f || b.z <= 0.0f))) {
    return false;
  }
  out->x0 = (std::min)(a.x, b.x);
  out->x1 = (std::max)(a.x, b.x);
  out->y0 = (std::min)(a.y, b.y);
  out->y1 = (std::max)(a.y, b.y);
  return out->x1 - out->x0 >= 1.0f && out->y1 - out->y0 >= 1.0f;
}

// Mes lays out every '\n'-terminated line of LastMes as one inner list with
// one object per unit.  The rendered structure must agree exactly with the
// text it claims to show; `source` receives each glyph's unit index.
inline bool MapGlyphsToText(const wchar_t* text, size_t units,
                            const uint16_t* line_glyphs, size_t lines,
                            uint16_t* source, size_t source_capacity) {
  if (text == nullptr || line_glyphs == nullptr || source == nullptr ||
      lines == 0u || units == 0u || units > kMaxLineUnits ||
      text[units - 1u] != L'\n') {
    return false;
  }
  size_t position = 0u;
  size_t glyph = 0u;
  for (size_t line = 0u; line < lines; ++line) {
    size_t end = position;
    while (end < units && text[end] != L'\n') ++end;
    if (end >= units) return false;  // fewer text lines than rendered lines
    if (end - position != line_glyphs[line]) return false;
    for (size_t unit = position; unit < end; ++unit) {
      if (glyph >= source_capacity) return false;
      source[glyph++] = static_cast<uint16_t>(unit);
    }
    position = end + 1u;
  }
  return position == units;  // no text line without a rendered line
}

// ── projection and hit testing ──────────────────────────────────────────────

struct PixelRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
};

// Unity screen pixels (bottom-left origin, `screen_w` x `screen_h`) ->
// physical client pixels (top-left origin), rounded outward; the cell must
// lie inside the screen.
inline bool ProjectCell(const GlyphCell& cell, int32_t screen_w,
                        int32_t screen_h, int32_t physical_w,
                        int32_t physical_h, PixelRect* out) {
  if (out == nullptr || screen_w <= 0 || screen_h <= 0 || physical_w <= 0 ||
      physical_h <= 0 || !(cell.x0 >= 0.0f) || !(cell.y0 >= 0.0f) ||
      !(cell.x1 <= static_cast<float>(screen_w)) ||
      !(cell.y1 <= static_cast<float>(screen_h)) || cell.x1 <= cell.x0 ||
      cell.y1 <= cell.y0) {
    return false;
  }
  const double sx = static_cast<double>(physical_w) / screen_w;
  const double sy = static_cast<double>(physical_h) / screen_h;
  const double left = cell.x0 * sx;
  const double right = cell.x1 * sx;
  const double top = (screen_h - cell.y1) * sy;
  const double bottom = (screen_h - cell.y0) * sy;
  const int32_t x0 = static_cast<int32_t>(std::floor(left));
  const int32_t y0 = static_cast<int32_t>(std::floor(top));
  const int32_t x1 = static_cast<int32_t>(std::ceil(right));
  const int32_t y1 = static_cast<int32_t>(std::ceil(bottom));
  if (x0 < 0 || y0 < 0 || x1 > physical_w || y1 > physical_h ||
      x1 - x0 < 1 || y1 - y0 < 1) {
    return false;
  }
  *out = {x0, y0, x1 - x0, y1 - y0};
  return true;
}

// Client pixel (window DPI context, == Unity screen grid) -> Unity screen
// point at the pixel centre.
inline bool ClientToScreenPoint(int32_t x, int32_t y, int32_t screen_w,
                                int32_t screen_h, float* out_x, float* out_y) {
  if (out_x == nullptr || out_y == nullptr || x < 0 || y < 0 ||
      x >= screen_w || y >= screen_h) {
    return false;
  }
  *out_x = static_cast<float>(x) + 0.5f;
  *out_y = static_cast<float>(screen_h - y) - 0.5f;
  return true;
}

// The glyph whose half-open cell contains the point.  Neighbouring TextMesh
// cells touch exactly (advance = bounds width); tight spacing can make them
// overlap, and then the glyph whose horizontal centre is nearer wins.  A tie
// is a miss.
inline bool HitTestCells(const GlyphCell* cells, const uint16_t* source,
                         size_t count, float x, float y, size_t* hit) {
  if (cells == nullptr || source == nullptr || hit == nullptr) return false;
  size_t best = count;
  float best_distance = 0.0f;
  bool tie = false;
  for (size_t index = 0u; index < count; ++index) {
    const GlyphCell& cell = cells[index];
    if (!cell.visible || source[index] == kNoSource) continue;
    if (x < cell.x0 || x >= cell.x1 || y < cell.y0 || y >= cell.y1) continue;
    const float distance = std::fabs(x - 0.5f * (cell.x0 + cell.x1));
    if (best == count || distance < best_distance) {
      best = index;
      best_distance = distance;
      tie = false;
    } else if (distance == best_distance) {
      tie = true;
    }
  }
  if (best == count || tie) return false;
  *hit = best;
  return true;
}

// ── message-thread click claim ─────────────────────────────────────────────

inline constexpr uint32_t kMessageLeftDown = WM_LBUTTONDOWN;
inline constexpr uint32_t kMessageLeftUp = WM_LBUTTONUP;
inline constexpr uint32_t kMessageLeftDouble = WM_LBUTTONDBLCLK;

struct ClaimState {
  bool owned = false;
};

struct ClaimDecision {
  bool evaluate = false;
  bool swallow = false;
  bool submit = false;
};

inline bool NeedsEligibility(uint32_t message) {
  return message == kMessageLeftDown || message == kMessageLeftDouble;
}

// A claimed press owns the button until its release; both edges are
// swallowed so Unity's input manager never records the click.
inline ClaimDecision DecideMessage(uint32_t message, bool eligible,
                                   ClaimState* claim) {
  ClaimDecision decision;
  if (claim == nullptr) return decision;
  if (NeedsEligibility(message)) {
    decision.evaluate = true;
    claim->owned = eligible;
    decision.swallow = eligible;
    decision.submit = eligible;
  } else if (message == kMessageLeftUp && claim->owned) {
    claim->owned = false;
    decision.swallow = true;
  }
  return decision;
}

// ── content fingerprint (game thread) ───────────────────────────────────────

inline uint64_t Fingerprint(uint64_t hash, const void* data, size_t bytes) {
  const auto* p = static_cast<const uint8_t*>(data);
  for (size_t i = 0; i < bytes; ++i) {
    hash ^= p[i];
    hash *= 1099511628211ull;
  }
  return hash;
}
inline constexpr uint64_t kFingerprintSeed = 1469598103934665603ull;

}  // namespace fushi_voice_hook::unity_mono_lookup
