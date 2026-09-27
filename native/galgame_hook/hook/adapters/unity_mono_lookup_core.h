#pragma once

// Unity (Mono runtime) in-game lookup: pure, unit-tested half.
//
// Two frameworks share provider id 20 (one geometry model, one click claim):
// framework 1, the per-glyph TextMesh message framework (this section), and
// framework 2, Fungus SayDialog on a UGUI Text (the section at the end).
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
using IcallInstanceFloatFn = float(FUSHI_UNITY_ICALL*)(void* self);
using IcallInstanceArgFn = void(FUSHI_UNITY_ICALL*)(void* self, void* arg);

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

// ════════════════════════════════════════════════════════════════════════════
// Framework 2: Fungus SayDialog on a UGUI Text.
//
// Scope: the public Unity VN framework Fungus (namespace `Fungus`), whose
// SayDialog shows a line through a Writer that re-assigns the dialog's
// `storyText` (UnityEngine.UI.Text) on every revealed glyph as
//   visible part + `<color=#RRGGBB00>` rest-of-line `</color>`
// (Writer.ConcatenateString: read-ahead text is laid out but alpha 0, so the
// layout never jumps while typing).  The text path already admits the
// framework structurally (unity_mono_text.h, kFungusSayDialogDoSay).
//
// Engine facts used (Unity 2021.3 MonoBleedingEdge player, x64; measured
// 2026-09-28 with Frida on a Steam Fungus title — the sample only, never an
// identity input):
//   * SayDialog.LateUpdate runs once per frame on the main thread after the
//     Writer coroutines assigned this frame's text.
//   * UGUI Text lays out through its cached TextGenerator (`m_TextCache`).
//     `GetCharactersInternal` / `GetLinesInternal` fill the generator's own
//     `m_Characters` / `m_Lines` lists from the last layout: one UICharInfo
//     per UTF-16 unit of the *raw* string (rich-text tag units included, with
//     width 0) plus a terminator, cursorPos.x the left edge, cursorPos.y the
//     line top; UILineInfo {startCharIdx, height, topY}.  Generator space is
//     the RectTransform's local space times `pixelsPerUnit` (the canvas scale
//     factor for a dynamic font).  `m_LastString` is the exact string object
//     the last layout used; while it differs from `m_Text` the layout is one
//     frame behind and nothing is sampled.
//   * Local -> world through Transform.localToWorldMatrix; world -> Unity
//     screen pixels: identity for a Screen Space - Overlay root canvas,
//     Camera.WorldToScreenPoint of the root canvas' worldCamera for Screen
//     Space - Camera (a World Space canvas is refused).  Measured cells match
//     the rendered glyphs to the pixel.
//   * Visibility: the text's GameObject active and the Text enabled
//     (Behaviour.isActiveAndEnabled), its CanvasRenderer not culled and its
//     inherited CanvasGroup alpha and own color alpha readable (>= 0.5), the
//     glyph outside an alpha-0 `<color>` span.
//   * Input: Unity's input (the Input System package included) takes mouse
//     buttons from the window procedure: swallowing WM_LBUTTONDOWN/UP in the
//     UnityWndClass procedure keeps that click from advancing the line
//     (measured with a real SendInput click on a Fungus line).
//
// Nothing here consults a hash, file name or title; every class, method,
// field and internal call is resolved by namespace + name + full signature
// (+ internal-call flag), unique across images; any gap installs nothing.

inline constexpr int kMonoTypeObject = 0x1c;

enum class FungusIcall : uint8_t {
  kComponentGameObject = 0,
  kComponentTransform,
  kBehaviourActiveAndEnabled,
  kTransformLocalToWorld,
  kCanvasRoot,
  kCanvasRenderMode,
  kCanvasScaleFactor,
  kCanvasWorldCamera,
  kCanvasRendererInheritedAlpha,
  kCanvasRendererCull,
  kFontDynamic,
  kGeneratorCharacters,
  kGeneratorLines,
  kCameraWorldToScreen,
  kCameraTargetTexture,
  kScreenWidth,
  kScreenHeight,
  kCount,
};
inline constexpr size_t kFungusIcallCount =
    static_cast<size_t>(FungusIcall::kCount);

struct FungusIcallSpec {
  FungusIcall id;
  const char* name_space;
  const char* class_name;
  const char* method;
  bool instance;
  int return_type;
  uint8_t param_count;
  int params[3];
  uint8_t byref_mask;
};

inline constexpr FungusIcallSpec kFungusIcallSpecs[kFungusIcallCount] = {
    {FungusIcall::kComponentGameObject, "UnityEngine", "Component",
     "get_gameObject", true, kMonoTypeClass, 0, {0, 0, 0}, 0u},
    {FungusIcall::kComponentTransform, "UnityEngine", "Component",
     "get_transform", true, kMonoTypeClass, 0, {0, 0, 0}, 0u},
    {FungusIcall::kBehaviourActiveAndEnabled, "UnityEngine", "Behaviour",
     "get_isActiveAndEnabled", true, kMonoTypeBoolean, 0, {0, 0, 0}, 0u},
    {FungusIcall::kTransformLocalToWorld, "UnityEngine", "Transform",
     "get_localToWorldMatrix_Injected", true, kMonoTypeVoid, 1,
     {kMonoTypeValueType, 0, 0}, 0x1u},
    {FungusIcall::kCanvasRoot, "UnityEngine", "Canvas", "get_rootCanvas", true,
     kMonoTypeClass, 0, {0, 0, 0}, 0u},
    {FungusIcall::kCanvasRenderMode, "UnityEngine", "Canvas", "get_renderMode",
     true, kMonoTypeValueType, 0, {0, 0, 0}, 0u},
    {FungusIcall::kCanvasScaleFactor, "UnityEngine", "Canvas",
     "get_scaleFactor", true, kMonoTypeSingle, 0, {0, 0, 0}, 0u},
    {FungusIcall::kCanvasWorldCamera, "UnityEngine", "Canvas",
     "get_worldCamera", true, kMonoTypeClass, 0, {0, 0, 0}, 0u},
    {FungusIcall::kCanvasRendererInheritedAlpha, "UnityEngine",
     "CanvasRenderer", "GetInheritedAlpha", true, kMonoTypeSingle, 0,
     {0, 0, 0}, 0u},
    {FungusIcall::kCanvasRendererCull, "UnityEngine", "CanvasRenderer",
     "get_cull", true, kMonoTypeBoolean, 0, {0, 0, 0}, 0u},
    {FungusIcall::kFontDynamic, "UnityEngine", "Font", "get_dynamic", true,
     kMonoTypeBoolean, 0, {0, 0, 0}, 0u},
    {FungusIcall::kGeneratorCharacters, "UnityEngine", "TextGenerator",
     "GetCharactersInternal", true, kMonoTypeVoid, 1,
     {kMonoTypeObject, 0, 0}, 0u},
    {FungusIcall::kGeneratorLines, "UnityEngine", "TextGenerator",
     "GetLinesInternal", true, kMonoTypeVoid, 1, {kMonoTypeObject, 0, 0}, 0u},
    {FungusIcall::kCameraWorldToScreen, "UnityEngine", "Camera",
     "WorldToScreenPoint_Injected", true, kMonoTypeVoid, 3,
     {kMonoTypeValueType, kMonoTypeValueType, kMonoTypeValueType}, 0x5u},
    {FungusIcall::kCameraTargetTexture, "UnityEngine", "Camera",
     "get_targetTexture", true, kMonoTypeClass, 0, {0, 0, 0}, 0u},
    {FungusIcall::kScreenWidth, "UnityEngine", "Screen", "get_width", false,
     kMonoTypeI4, 0, {0, 0, 0}, 0u},
    {FungusIcall::kScreenHeight, "UnityEngine", "Screen", "get_height", false,
     kMonoTypeI4, 0, {0, 0, 0}, 0u},
};

// RenderMode (UnityEngine.RenderMode).
inline constexpr int32_t kRenderModeScreenSpaceOverlay = 0;
inline constexpr int32_t kRenderModeScreenSpaceCamera = 1;

// `mono_class_value_size` (element stride of UICharInfo[] / UILineInfo[]).
struct MonoValueSizeApi {
  int32_t (*class_value_size)(void* klass, uint32_t* align) = nullptr;
};

struct FungusSites {
  void* late_update = nullptr;         // MonoMethod* of SayDialog.LateUpdate
  uint32_t story_text_offset = 0u;     // SayDialog.storyText (UI.Text)
  uint32_t text_string_offset = 0u;    // Text.m_Text
  uint32_t text_cache_offset = 0u;     // Text.m_TextCache (TextGenerator)
  uint32_t font_data_offset = 0u;      // Text.m_FontData
  uint32_t font_data_font_offset = 0u; // FontData.m_Font
  uint32_t graphic_canvas_offset = 0u; // Graphic.m_Canvas
  uint32_t graphic_renderer_offset = 0u;  // Graphic.m_CanvasRenderer
  uint32_t graphic_color_alpha_offset = 0u;  // Graphic.m_Color.a
  uint32_t generator_chars_offset = 0u;  // TextGenerator.m_Characters
  uint32_t generator_lines_offset = 0u;  // TextGenerator.m_Lines
  uint32_t generator_last_offset = 0u;   // TextGenerator.m_LastString
  uint32_t char_list_items_offset = 0u;  // List<UICharInfo>._items/_size
  uint32_t char_list_size_offset = 0u;
  uint32_t line_list_items_offset = 0u;  // List<UILineInfo>._items/_size
  uint32_t line_list_size_offset = 0u;
  uint32_t char_stride = 0u;             // sizeof(UICharInfo)
  uint32_t char_cursor_offset = 0u;      // UICharInfo.cursorPos (Vector2)
  uint32_t char_width_offset = 0u;       // UICharInfo.charWidth
  uint32_t line_stride = 0u;             // sizeof(UILineInfo)
  uint32_t line_start_offset = 0u;       // UILineInfo.startCharIdx
  uint32_t line_height_offset = 0u;      // UILineInfo.height
  uint32_t line_top_offset = 0u;         // UILineInfo.topY
  uint32_t cached_ptr_offset = 0u;       // UnityEngine.Object.m_CachedPtr
  std::array<void*, kFungusIcallCount> icalls{};

  template <typename Fn>
  Fn Get(FungusIcall id) const {
    return reinterpret_cast<Fn>(icalls[static_cast<size_t>(id)]);
  }
};

enum class FungusSiteResult : uint32_t {
  kResolved = 0,
  kApiIncomplete = 1,
  kNoSayDialog = 2,       // absent or ambiguous across images
  kNoLateUpdate = 3,
  kStoryTextMissing = 4,  // SayDialog.storyText is not a UGUI Text
  kTextFieldsMissing = 5,
  kGraphicFieldsMissing = 6,
  kGeneratorFieldsMissing = 7,
  kCharLayoutMismatch = 8,
  kLineLayoutMismatch = 9,
  kObjectFieldMissing = 10,
  kIcallMissing = 11,
};

struct FungusSiteResolution {
  FungusSiteResult result = FungusSiteResult::kApiIncomplete;
  int32_t missing_icall = -1;
};

// A declared field of `klass` whose type resolves to exactly `expected`.
inline bool FieldOfClass(const MonoEmbeddingApi& api,
                         const MonoLookupApi& lookup, void* klass,
                         const char* name, int type_kind, void* expected,
                         uint32_t* offset_out, void** field_out = nullptr) {
  void* field = nullptr;
  if (!FieldOfType(api, lookup, klass, name, type_kind, &field, offset_out)) {
    return false;
  }
  if (expected != nullptr &&
      lookup.class_from_mono_type(lookup.field_get_type(field)) != expected) {
    return false;
  }
  if (field_out != nullptr) *field_out = field;
  return true;
}

// Offset of a value type's field relative to the unboxed value (mono reports
// value-type field offsets including the object header).
inline bool ValueFieldOffset(const MonoEmbeddingApi& api,
                             const MonoLookupApi& lookup, void* klass,
                             const char* name, int type_kind,
                             uint32_t* offset_out) {
  uint32_t boxed = 0u;
  if (!FieldOfType(api, lookup, klass, name, type_kind, nullptr, &boxed)) {
    return false;
  }
  *offset_out = boxed - 2u * static_cast<uint32_t>(sizeof(void*));
  return true;
}

inline void* ResolveFungusIcall(const MonoEmbeddingApi& api,
                                const MonoLookupApi& lookup,
                                const MonoAssemblyList& list,
                                const FungusIcallSpec& spec) {
  const IcallSpec generic = {Icall::kCount,
                             spec.name_space,
                             spec.class_name,
                             spec.method,
                             spec.instance,
                             spec.return_type,
                             spec.param_count,
                             {spec.params[0], spec.params[1], spec.params[2]},
                             spec.byref_mask};
  return ResolveIcall(api, lookup, list, generic);
}

// Caller must be attached to the root domain.
inline FungusSiteResolution ResolveFungusSites(const MonoEmbeddingApi& api,
                                               const MonoLookupApi& lookup,
                                               const MonoValueSizeApi& sizes,
                                               FungusSites* out) {
  FungusSiteResolution resolution;
  if (out == nullptr || !api.CompleteForResolution() || !lookup.Complete() ||
      sizes.class_value_size == nullptr) {
    return resolution;
  }
  *out = FungusSites();
  MonoAssemblyList list;
  api.assembly_foreach(&CollectMonoAssembly, &list);
  const MonoTextHookSpec& say =
      MonoTextHookSpecFor(MonoTextHookId::kFungusSayDialogDoSay);
  void* dialog = FindClassInImages(api, list, say.name_space, say.class_name);
  if (dialog == nullptr) {
    resolution.result = FungusSiteResult::kNoSayDialog;
    return resolution;
  }
  out->late_update = FindMonoMethod(api, dialog, "LateUpdate", true,
                                    kMonoTypeVoid, 0, nullptr);
  if (out->late_update == nullptr) {
    resolution.result = FungusSiteResult::kNoLateUpdate;
    return resolution;
  }
  void* text = FindClassInImages(api, list, "UnityEngine.UI", "Text");
  void* graphic = FindClassInImages(api, list, "UnityEngine.UI", "Graphic");
  void* font_data = FindClassInImages(api, list, "UnityEngine.UI", "FontData");
  void* generator =
      FindClassInImages(api, list, "UnityEngine", "TextGenerator");
  void* font = FindClassInImages(api, list, "UnityEngine", "Font");
  void* canvas = FindClassInImages(api, list, "UnityEngine", "Canvas");
  void* renderer =
      FindClassInImages(api, list, "UnityEngine", "CanvasRenderer");
  void* color = FindClassInImages(api, list, "UnityEngine", "Color");
  void* char_info = FindClassInImages(api, list, "UnityEngine", "UICharInfo");
  void* line_info = FindClassInImages(api, list, "UnityEngine", "UILineInfo");
  if (text == nullptr ||
      !FieldOfClass(api, lookup, dialog, "storyText", kMonoTypeClass, text,
                    &out->story_text_offset)) {
    resolution.result = FungusSiteResult::kStoryTextMissing;
    return resolution;
  }
  if (generator == nullptr || font_data == nullptr || font == nullptr ||
      !FieldOfType(api, lookup, text, "m_Text", kMonoTypeString, nullptr,
                   &out->text_string_offset) ||
      !FieldOfClass(api, lookup, text, "m_TextCache", kMonoTypeClass,
                    generator, &out->text_cache_offset) ||
      !FieldOfClass(api, lookup, text, "m_FontData", kMonoTypeClass,
                    font_data, &out->font_data_offset) ||
      !FieldOfClass(api, lookup, font_data, "m_Font", kMonoTypeClass, font,
                    &out->font_data_font_offset)) {
    resolution.result = FungusSiteResult::kTextFieldsMissing;
    return resolution;
  }
  uint32_t color_offset = 0u, alpha_offset = 0u;
  if (graphic == nullptr || canvas == nullptr || renderer == nullptr ||
      color == nullptr ||
      !FieldOfClass(api, lookup, graphic, "m_Canvas", kMonoTypeClass, canvas,
                    &out->graphic_canvas_offset) ||
      !FieldOfClass(api, lookup, graphic, "m_CanvasRenderer", kMonoTypeClass,
                    renderer, &out->graphic_renderer_offset) ||
      !FieldOfClass(api, lookup, graphic, "m_Color", kMonoTypeValueType,
                    color, &color_offset) ||
      !ValueFieldOffset(api, lookup, color, "a", kMonoTypeSingle,
                        &alpha_offset) ||
      alpha_offset + 4u > 16u) {
    resolution.result = FungusSiteResult::kGraphicFieldsMissing;
    return resolution;
  }
  out->graphic_color_alpha_offset = color_offset + alpha_offset;
  void* chars_field = nullptr;
  void* lines_field = nullptr;
  if (!FieldOfType(api, lookup, generator, "m_LastString", kMonoTypeString,
                   nullptr, &out->generator_last_offset) ||
      !FieldOfType(api, lookup, generator, "m_Characters",
                   kMonoTypeGenericInst, &chars_field,
                   &out->generator_chars_offset) ||
      !FieldOfType(api, lookup, generator, "m_Lines", kMonoTypeGenericInst,
                   &lines_field, &out->generator_lines_offset)) {
    resolution.result = FungusSiteResult::kGeneratorFieldsMissing;
    return resolution;
  }
  // List<UICharInfo>: element class and value layout.
  void* chars_list = lookup.class_from_mono_type(lookup.field_get_type(chars_field));
  void* chars_element =
      ListLayout(api, lookup, chars_list, &out->char_list_items_offset,
                 &out->char_list_size_offset);
  uint32_t align = 0u;
  const int32_t char_size =
      char_info == nullptr ? 0 : sizes.class_value_size(char_info, &align);
  if (char_info == nullptr || chars_element != char_info || char_size <= 0 ||
      !ValueFieldOffset(api, lookup, char_info, "cursorPos",
                        kMonoTypeValueType, &out->char_cursor_offset) ||
      !ValueFieldOffset(api, lookup, char_info, "charWidth", kMonoTypeSingle,
                        &out->char_width_offset) ||
      out->char_cursor_offset + 8u > static_cast<uint32_t>(char_size) ||
      out->char_width_offset + 4u > static_cast<uint32_t>(char_size)) {
    resolution.result = FungusSiteResult::kCharLayoutMismatch;
    return resolution;
  }
  out->char_stride = static_cast<uint32_t>(char_size);
  void* lines_list = lookup.class_from_mono_type(lookup.field_get_type(lines_field));
  void* lines_element =
      ListLayout(api, lookup, lines_list, &out->line_list_items_offset,
                 &out->line_list_size_offset);
  const int32_t line_size =
      line_info == nullptr ? 0 : sizes.class_value_size(line_info, &align);
  if (line_info == nullptr || lines_element != line_info || line_size <= 0 ||
      !ValueFieldOffset(api, lookup, line_info, "startCharIdx", kMonoTypeI4,
                        &out->line_start_offset) ||
      !ValueFieldOffset(api, lookup, line_info, "height", kMonoTypeI4,
                        &out->line_height_offset) ||
      !ValueFieldOffset(api, lookup, line_info, "topY", kMonoTypeSingle,
                        &out->line_top_offset) ||
      out->line_start_offset + 4u > static_cast<uint32_t>(line_size) ||
      out->line_height_offset + 4u > static_cast<uint32_t>(line_size) ||
      out->line_top_offset + 4u > static_cast<uint32_t>(line_size)) {
    resolution.result = FungusSiteResult::kLineLayoutMismatch;
    return resolution;
  }
  out->line_stride = static_cast<uint32_t>(line_size);
  void* unity_object = FindClassInImages(api, list, "UnityEngine", "Object");
  if (!FieldOfType(api, lookup, unity_object, "m_CachedPtr", kMonoTypeI,
                   nullptr, &out->cached_ptr_offset)) {
    resolution.result = FungusSiteResult::kObjectFieldMissing;
    return resolution;
  }
  for (const FungusIcallSpec& spec : kFungusIcallSpecs) {
    void* entry = ResolveFungusIcall(api, lookup, list, spec);
    if (entry == nullptr) {
      resolution.result = FungusSiteResult::kIcallMissing;
      resolution.missing_icall = static_cast<int32_t>(spec.id);
      return resolution;
    }
    out->icalls[static_cast<size_t>(spec.id)] = entry;
  }
  resolution.result = FungusSiteResult::kResolved;
  return resolution;
}

// ── UGUI rich text ──────────────────────────────────────────────────────────
//
// The rendered string carries UGUI rich-text tags (Fungus emits <b> <i>
// <color> <size> and the alpha-0 read-ahead span).  The text lane strips any
// `<...>` (RecordUnityTextChars), so the same stripping defines the plain
// text here; a glyph is hidden while the innermost open <color> has alpha 0.

inline constexpr uint16_t kRawTag = 0xffffu;
inline constexpr size_t kMaxColorDepth = 16u;

inline int HexNibble(wchar_t c) {
  if (c >= L'0' && c <= L'9') return c - L'0';
  if (c >= L'a' && c <= L'f') return c - L'a' + 10;
  if (c >= L'A' && c <= L'F') return c - L'A' + 10;
  return -1;
}

// Alpha of a <color=...> value: #RRGGBBAA / #RGBA carry it, every other form
// (#RRGGBB, #RGB, a colour name) is opaque.
inline bool ColorValueIsTransparent(const wchar_t* value, size_t length) {
  if (value == nullptr || length == 0u || value[0] != L'#') return false;
  if (length == 9u) {
    return HexNibble(value[7]) == 0 && HexNibble(value[8]) == 0;
  }
  if (length == 5u) return HexNibble(value[4]) == 0;
  return false;
}

struct RichTextMap {
  size_t plain_length = 0u;
  // Per raw unit: plain index, or kRawTag for a unit inside a tag.
  std::array<uint16_t, kMaxLineUnits> raw_to_plain{};
  // Per raw unit: inside an alpha-0 colour span.
  std::array<uint8_t, kMaxLineUnits> hidden{};
  std::array<wchar_t, kMaxLineUnits> plain{};
};

// false: too long, or an unclosed '<' (then the lane's stripping and the
// renderer disagree about the plain text and nothing is mapped).
inline bool ParseRichText(const wchar_t* raw, size_t length, RichTextMap* map) {
  if (raw == nullptr || map == nullptr || length == 0u ||
      length > kMaxLineUnits) {
    return false;
  }
  map->plain_length = 0u;
  bool colour_hidden[kMaxColorDepth] = {};
  size_t depth = 0u;
  for (size_t i = 0u; i < length; ++i) {
    if (raw[i] == L'<') {
      size_t close = i + 1u;
      while (close < length && raw[close] != L'>') ++close;
      if (close >= length) return false;
      const wchar_t* body = raw + i + 1u;
      const size_t body_length = close - i - 1u;
      static constexpr wchar_t kOpen[] = L"color=";
      static constexpr wchar_t kClose[] = L"/color";
      if (body_length > 6u && std::wmemcmp(body, kOpen, 6u) == 0) {
        if (depth < kMaxColorDepth) {
          colour_hidden[depth] =
              ColorValueIsTransparent(body + 6u, body_length - 6u);
        }
        ++depth;
      } else if (body_length == 6u && std::wmemcmp(body, kClose, 6u) == 0) {
        if (depth > 0u) --depth;
      }
      for (size_t k = i; k <= close; ++k) {
        map->raw_to_plain[k] = kRawTag;
        map->hidden[k] = 1u;
      }
      i = close;
      continue;
    }
    const size_t top = depth == 0u ? 0u : (depth > kMaxColorDepth
                                               ? kMaxColorDepth
                                               : depth);
    map->hidden[i] = top > 0u && colour_hidden[top - 1u] ? 1u : 0u;
    map->raw_to_plain[i] = static_cast<uint16_t>(map->plain_length);
    map->plain[map->plain_length++] = raw[i];
  }
  return true;
}

// ── generator space -> Unity screen ─────────────────────────────────────────

struct Matrix4 {
  float m[16] = {};  // column-major (UnityEngine.Matrix4x4 layout)
};
static_assert(sizeof(Matrix4) == 64, "UnityEngine.Matrix4x4 layout");

inline Vec3 TransformPoint(const Matrix4& matrix, float x, float y) {
  const float* m = matrix.m;
  return {m[0] * x + m[4] * y + m[12], m[1] * x + m[5] * y + m[13],
          m[2] * x + m[6] * y + m[14]};
}

// The UILineInfo containing raw unit `index` (lines are sorted by start).
inline bool LineOfUnit(const int32_t* line_starts, size_t lines, size_t index,
                       size_t* line) {
  if (line_starts == nullptr || line == nullptr || lines == 0u ||
      line_starts[0] > static_cast<int32_t>(index)) {
    return false;
  }
  size_t found = 0u;
  for (size_t k = 1u; k < lines; ++k) {
    if (line_starts[k] < line_starts[k - 1u]) return false;
    if (line_starts[k] <= static_cast<int32_t>(index)) found = k;
  }
  *line = found;
  return true;
}

// One glyph's cell in generator space: [cursor.x, cursor.x + width] x
// [top - height, top].  Converted to local by dividing by pixels-per-unit.
struct LocalCell {
  float x0 = 0.0f, y0 = 0.0f, x1 = 0.0f, y1 = 0.0f;
};

inline bool GeneratorCell(float cursor_x, float width, float line_top,
                          int32_t line_height, float pixels_per_unit,
                          LocalCell* out) {
  if (out == nullptr || !(width > 0.0f) || line_height <= 0 ||
      !(pixels_per_unit > 0.0f) || !std::isfinite(cursor_x) ||
      !std::isfinite(width) || !std::isfinite(line_top) ||
      !std::isfinite(pixels_per_unit)) {
    return false;
  }
  out->x0 = cursor_x / pixels_per_unit;
  out->x1 = (cursor_x + width) / pixels_per_unit;
  out->y1 = line_top / pixels_per_unit;
  out->y0 = (line_top - static_cast<float>(line_height)) / pixels_per_unit;
  return true;
}

// The Fungus sampler records each glyph's index into the plain text; the
// indices must address drawn (non line-break) units in strictly increasing
// order, or the snapshot is not a layout of that text.
inline bool ValidateGlyphSources(const wchar_t* text, size_t units,
                                 const uint16_t* sources, size_t count) {
  if (text == nullptr || sources == nullptr || units == 0u ||
      units > kMaxLineUnits || count > kMaxGlyphs) {
    return false;
  }
  for (size_t i = 0u; i < count; ++i) {
    if (sources[i] >= units || text[sources[i]] == L'\n' ||
        (i > 0u && sources[i] <= sources[i - 1u])) {
      return false;
    }
  }
  return true;
}

inline constexpr float kMinReadableAlpha = 0.5f;

inline bool FungusTextReadable(bool active_and_enabled, bool culled,
                               float inherited_alpha, float color_alpha) {
  return active_and_enabled && !culled && inherited_alpha >= kMinReadableAlpha &&
         color_alpha >= kMinReadableAlpha;
}

}  // namespace fushi_voice_hook::unity_mono_lookup
