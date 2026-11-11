#pragma once

// Unity (Mono runtime) in-game lookup: pure, unit-tested half.
//
// Three frameworks share provider id 20 (one geometry model, one click claim):
// framework 1, the per-glyph TextMesh message framework (this section),
// framework 2, Fungus SayDialog on a UGUI Text, and framework 3, a bare
// TextMeshPro UGUI text (TMPro.TextMeshProUGUI) whose text is the selected
// line (the last two sections).
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
#include <cstdio>
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
  // Pointer-sized GC handles (Unity 6 bindings return a UnityEngine.Object
  // as one): mono_gchandle_get_target_v2 / _free_v2 on Mono,
  // il2cpp_gchandle_get_target / _free on IL2CPP.  Optional: only a binding
  // resolved in the Unity 6 form that returns an object needs them, and that
  // binding fails closed without them (IcallFailure::kGcHandleApi).
  void* (*gchandle_get_target)(void* handle) = nullptr;
  void (*gchandle_free)(void* handle) = nullptr;

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

// ── engine binding forms ────────────────────────────────────────────────────
//
// An engine binding (an `extern` [InternalCall] of a UnityEngine module) is
// declared by Unity's bindings generator in one of two forms; both are C
// functions of the UnityPlayer, registered under the managed declaration.
//
//   classic   (Unity <= 2022)  the spec as written: an instance extern takes
//             the managed object as `this`, an object result is the managed
//             object.
//   injected  (Unity 6)        `private static extern <R'> <method>_Injected(
//             IntPtr _unity_self, <params>)`: the property / method itself is
//             managed code that passes the object's native peer as
//             `_unity_self` (UnityEngine.Object: MarshalledUnityObject.
//             MarshalNotNull(this) == m_CachedPtr; a plain native-backed class
//             such as TextGenerator: BindingsMarshaller.ConvertToNative(this)
//             == m_Ptr) and turns an IntPtr result back into the object with
//             Unmarshal.UnmarshalUnityObject<T> (the IntPtr is the GC handle
//             the native object owns; a fake-null object, instance ID 0, owns
//             none and its handle is freed by the reader).  A static extern
//             keeps its parameters; a spec whose name already ends in
//             `_Injected` keeps its name and gains `_unity_self`.
//   Sources (UnityCsReference 6000.0): Runtime/Export/Scripting/
//   BindingsHelpers.cs (Unmarshal), UnityEngineObject.bindings.cs
//   (MarshalledUnityObject); the generated wrappers themselves are in the
//   shipped UnityEngine.*Module.dll (e.g. `static extern IntPtr
//   get_transform_Injected(IntPtr _unity_self)`, `static extern void
//   WorldToScreenPoint_Injected(IntPtr _unity_self, ref Vector3,
//   MonoOrStereoscopicEye, out Vector3)`, `static extern IntPtr
//   get_main_Injected()`, `static extern void GetCharactersInternal_Injected(
//   IntPtr _unity_self, object)`).
//
// A spec resolves to exactly one declared internal call across both forms;
// none, two of one form, or one of each installs nothing.  The C function of
// either form has the same machine signature (every self / object value is
// pointer-sized); only the meaning of the self argument and of an object
// result differs, so the callers pass the form-specific self and read the
// form-specific result through the resolved IcallBinding.

enum class IcallForm : uint8_t {
  kUnresolved = 0,
  kClassic = 1,
  kInjected = 2,
};

// Where an injected instance binding's `_unity_self` comes from.
enum class IcallSelf : uint8_t {
  kUnityObject = 0,  // UnityEngine.Object.m_CachedPtr
  kNativePtr = 1,    // the declaring class' own `IntPtr m_Ptr`
};

template <typename Id>
struct EngineIcallSpec {
  Id id;
  const char* name_space;
  const char* class_name;
  const char* method;  // the classic name
  bool instance;
  int return_type;
  uint8_t param_count;
  int params[3];
  uint8_t byref_mask;  // bit i: parameter i is ref/out
  IcallSelf self = IcallSelf::kUnityObject;
};
using IcallSpec = EngineIcallSpec<Icall>;

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

// ── resolved bindings ───────────────────────────────────────────────────────

struct IcallBinding {
  void* entry = nullptr;
  IcallForm form = IcallForm::kUnresolved;
  bool instance = false;       // the classic declaration is an instance extern
  bool object_result = false;  // injected: the result is a GC handle
  uint32_t self_offset = 0u;   // injected instance: native self field offset
};

// Why a spec did not resolve (diagnostics; never dialogue).
enum class IcallFailure : uint8_t {
  kNone = 0,
  kAbsent = 1,      // no internal call of either form
  kAmbiguous = 2,   // two of one form, or one of each
  kSelfField = 3,   // injected instance: the native self field is missing
  kGcHandleApi = 4, // injected object result: no GC handle reader / instance
                    // ID field
  kNoEntry = 5,     // the runtime registered no C entry under the name
};

inline char IcallFormLetter(IcallForm form) {
  return form == IcallForm::kClassic    ? 'c'
         : form == IcallForm::kInjected ? 'i'
                                        : '-';
}
inline const char* IcallFailureName(IcallFailure failure) {
  switch (failure) {
    case IcallFailure::kNone: return "none";
    case IcallFailure::kAbsent: return "absent";
    case IcallFailure::kAmbiguous: return "ambiguous";
    case IcallFailure::kSelfField: return "self-field";
    case IcallFailure::kGcHandleApi: return "gchandle";
    case IcallFailure::kNoEntry: return "no-entry";
  }
  return "?";
}

// What the injected form needs from UnityEngine.Object and the runtime.
struct UnityObjectMarshal {
  uint32_t cached_ptr_offset = 0u;   // m_CachedPtr (always resolved)
  uint32_t instance_id_offset = 0u;  // m_InstanceID (0: not resolved)
  void* (*gchandle_get_target)(void* handle) = nullptr;
  void (*gchandle_free)(void* handle) = nullptr;
  bool CanUnmarshal() const {
    return instance_id_offset != 0u && gchandle_get_target != nullptr &&
           gchandle_free != nullptr;
  }
};

// The native self a binding takes for `object` (a managed object pointer):
// the object itself (classic) or its native peer field (injected; a zero
// peer -- a destroyed or never-bound object -- is no call).  `read` is a
// fault-tolerant pointer read (address, uintptr_t*) -> bool.
template <typename Read>
inline bool BindingSelf(const IcallBinding& binding, void* object, Read read,
                        void** self) {
  if (self == nullptr || object == nullptr || binding.entry == nullptr) {
    return false;
  }
  if (binding.form == IcallForm::kClassic) {
    *self = object;
    return true;
  }
  if (binding.form != IcallForm::kInjected || !binding.instance) return false;
  uintptr_t native = 0u;
  if (!read(reinterpret_cast<uintptr_t>(object) + binding.self_offset,
            &native) ||
      native == 0u) {
    return false;
  }
  *self = reinterpret_cast<void*>(native);
  return true;
}

// The managed object an object-returning binding produced: the value itself
// (classic) or the target of the returned GC handle (injected), mirroring
// Unmarshal.UnmarshalUnityObject: a fake-null target (instance ID 0) owns no
// native object, its handle is freed and the result is null.  `read_i32`:
// fault-tolerant (address, int32_t*) -> bool.
template <typename ReadI32>
inline void* BindingObjectResult(const IcallBinding& binding,
                                 const UnityObjectMarshal& marshal, void* raw,
                                 ReadI32 read_i32) {
  if (binding.form == IcallForm::kClassic) return raw;
  if (binding.form != IcallForm::kInjected || !binding.object_result ||
      raw == nullptr || !marshal.CanUnmarshal()) {
    return nullptr;
  }
  void* target = marshal.gchandle_get_target(raw);
  if (target == nullptr) return nullptr;
  int32_t instance_id = 0;
  if (!read_i32(reinterpret_cast<uintptr_t>(target) +
                    marshal.instance_id_offset,
                &instance_id)) {
    return nullptr;
  }
  if (instance_id == 0) {
    marshal.gchandle_free(raw);
    return nullptr;
  }
  return target;
}

// ── resolved sites ──────────────────────────────────────────────────────────

struct Sites {
  void* fixed_update = nullptr;  // MonoMethod* of Message.FixedUpdate
  uint32_t message_sprite_offset = 0u;  // Message.messageSprite
  uint32_t last_mes_offset = 0u;        // Message.LastMes
  uint32_t list_items_offset = 0u;      // List`1._items (both levels)
  uint32_t list_size_offset = 0u;       // List`1._size (both levels)
  uint32_t cached_ptr_offset = 0u;      // UnityEngine.Object.m_CachedPtr
  void* renderer_type = nullptr;        // System.Type of UnityEngine.Renderer
  UnityObjectMarshal marshal;
  std::array<IcallBinding, kIcallCount> icalls{};

  const IcallBinding& Binding(Icall id) const {
    return icalls[static_cast<size_t>(id)];
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
  IcallFailure icall_failure = IcallFailure::kNone;
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

// One binding signature to look for on a class.
struct IcallShape {
  const char* method = nullptr;
  bool instance = false;
  int return_type = 0;
  uint8_t param_count = 0u;
  int params[4] = {};
  uint8_t byref_mask = 0u;
};

struct IcallMatch {
  void* method = nullptr;  // the single match (count == 1)
  uint32_t count = 0u;     // declared internal calls of this shape (capped 2)
};

// The internal calls `klass` declares with exactly this shape: name, static /
// instance, return and parameter kinds, by-ref-ness, internal-call flag.
inline IcallMatch MatchIcallDeclarations(const MonoEmbeddingApi& api,
                                         const MonoLookupApi& lookup,
                                         void* klass, const IcallShape& shape) {
  IcallMatch match;
  if (klass == nullptr || shape.method == nullptr) return match;
  void* iter = nullptr;
  for (int guard = 0; guard < 8192; ++guard) {
    void* method = api.class_get_methods(klass, &iter);
    if (method == nullptr) break;
    const char* name = api.method_get_name(method);
    if (name == nullptr || std::strcmp(name, shape.method) != 0) continue;
    if (!MonoSignatureMatches(api, method, shape.instance, shape.return_type,
                              shape.param_count,
                              shape.param_count == 0 ? nullptr : shape.params,
                              -1) ||
        !ParamsByrefMatch(api, lookup, method, shape.param_count,
                          shape.byref_mask)) {
      continue;
    }
    uint32_t iflags = 0u;
    lookup.method_get_flags(method, &iflags);
    if ((iflags & kMethodImplInternalCall) == 0u) continue;
    match.method = method;
    if (++match.count >= 2u) return match;
  }
  return match;
}

template <typename Id>
inline IcallShape ClassicShape(const EngineIcallSpec<Id>& spec) {
  IcallShape shape;
  shape.method = spec.method;
  shape.instance = spec.instance;
  shape.return_type = spec.return_type;
  shape.param_count = spec.param_count;
  for (uint8_t i = 0; i < spec.param_count && i < 3u; ++i) {
    shape.params[i] = spec.params[i];
  }
  shape.byref_mask = spec.byref_mask;
  return shape;
}

inline constexpr char kInjectedSuffix[] = "_Injected";
inline constexpr size_t kInjectedNameChars = 128u;

inline bool EndsWithInjected(const char* name) {
  const size_t length = std::strlen(name);
  const size_t suffix = sizeof(kInjectedSuffix) - 1u;
  return length >= suffix &&
         std::strcmp(name + length - suffix, kInjectedSuffix) == 0;
}

// The Unity 6 form of a spec: `<method>_Injected` (unchanged when the classic
// name already carries the suffix), static, `IntPtr _unity_self` prepended to
// an instance binding's parameters (by-ref bits shift with them), an object
// result as IntPtr.  `name` receives the injected name.  false when the
// injected form is the classic one (a static binding without an object
// result whose name already ends in `_Injected`) or the name does not fit.
template <typename Id>
inline bool InjectedShape(const EngineIcallSpec<Id>& spec, char* name,
                          size_t name_size, IcallShape* out) {
  if (spec.method == nullptr || name == nullptr || out == nullptr ||
      spec.param_count > 3u) {
    return false;
  }
  const bool suffixed = EndsWithInjected(spec.method);
  const int written =
      suffixed ? std::snprintf(name, name_size, "%s", spec.method)
               : std::snprintf(name, name_size, "%s%s", spec.method,
                               kInjectedSuffix);
  if (written <= 0 || static_cast<size_t>(written) >= name_size) return false;
  const int result = spec.return_type == kMonoTypeClass ? kMonoTypeI
                                                        : spec.return_type;
  if (!spec.instance && suffixed && result == spec.return_type) return false;
  *out = IcallShape();
  out->method = name;
  out->instance = false;
  out->return_type = result;
  const uint8_t self = spec.instance ? 1u : 0u;
  if (spec.instance) out->params[0] = kMonoTypeI;
  for (uint8_t i = 0; i < spec.param_count; ++i) {
    out->params[i + self] = spec.params[i];
  }
  out->param_count = static_cast<uint8_t>(spec.param_count + self);
  out->byref_mask = static_cast<uint8_t>(spec.byref_mask << self);
  return true;
}

// Resolves `spec` in whichever form the player declares (see "engine binding
// forms").  `marshal` carries UnityEngine.Object.m_CachedPtr (+ m_InstanceID
// and the GC handle reader, needed only by an injected object result).
template <typename Id>
inline IcallBinding ResolveIcallBinding(const MonoEmbeddingApi& api,
                                        const MonoLookupApi& lookup,
                                        const MonoAssemblyList& list,
                                        const EngineIcallSpec<Id>& spec,
                                        const UnityObjectMarshal& marshal,
                                        IcallFailure* failure) {
  IcallBinding binding;
  IcallFailure why = IcallFailure::kAbsent;
  void* klass = FindClassInImages(api, list, spec.name_space, spec.class_name);
  const IcallMatch classic =
      MatchIcallDeclarations(api, lookup, klass, ClassicShape(spec));
  char injected_name[kInjectedNameChars] = {};
  IcallShape injected_shape;
  const IcallMatch injected =
      InjectedShape(spec, injected_name, sizeof(injected_name),
                    &injected_shape)
          ? MatchIcallDeclarations(api, lookup, klass, injected_shape)
          : IcallMatch();
  const uint32_t total = classic.count + injected.count;
  if (total > 1u) why = IcallFailure::kAmbiguous;
  if (total == 1u) {
    const bool is_injected = injected.count == 1u;
    binding.form = is_injected ? IcallForm::kInjected : IcallForm::kClassic;
    binding.instance = spec.instance;
    binding.object_result =
        is_injected && spec.return_type == kMonoTypeClass;
    why = IcallFailure::kNone;
    if (is_injected && spec.instance) {
      if (spec.self == IcallSelf::kUnityObject) {
        binding.self_offset = marshal.cached_ptr_offset;
      } else {
        void* field = lookup.class_get_field_from_name(klass, "m_Ptr");
        void* type = field == nullptr ? nullptr : lookup.field_get_type(field);
        const uint32_t offset =
            field == nullptr ? 0u : lookup.field_get_offset(field);
        if (type != nullptr && api.type_get_type(type) == kMonoTypeI &&
            lookup.type_is_byref(type) == 0 &&
            offset >= 2u * sizeof(void*) && offset < kMaxFieldOffset) {
          binding.self_offset = offset;
        }
      }
      if (binding.self_offset == 0u) why = IcallFailure::kSelfField;
    }
    if (why == IcallFailure::kNone && binding.object_result &&
        !marshal.CanUnmarshal()) {
      why = IcallFailure::kGcHandleApi;
    }
    if (why == IcallFailure::kNone) {
      binding.entry = lookup.lookup_internal_call(
          is_injected ? injected.method : classic.method);
      if (binding.entry == nullptr) why = IcallFailure::kNoEntry;
    }
  }
  if (why != IcallFailure::kNone) binding = IcallBinding();
  if (failure != nullptr) *failure = why;
  return binding;
}

// Classic-form-only resolution (the audio detours and Object.GetName read
// their arguments / result as managed objects; their Unity 6 forms hand
// native peers and a native string span, a different contract, so there
// they stay unresolved and fail closed).
inline void* ResolveIcall(const MonoEmbeddingApi& api,
                          const MonoLookupApi& lookup,
                          const MonoAssemblyList& list, const IcallSpec& spec) {
  void* klass = FindClassInImages(api, list, spec.name_space, spec.class_name);
  if (klass == nullptr) return nullptr;
  const IcallMatch match =
      MatchIcallDeclarations(api, lookup, klass, ClassicShape(spec));
  // Two identical externs: refuse.
  return match.count != 1u ? nullptr
                           : lookup.lookup_internal_call(match.method);
}

// UnityEngine.Object's marshalling fields: m_CachedPtr (required) and
// m_InstanceID (int; only the injected object-result path reads it).
inline bool ResolveUnityObjectMarshal(const MonoEmbeddingApi& api,
                                      const MonoLookupApi& lookup,
                                      const MonoAssemblyList& list,
                                      UnityObjectMarshal* out);

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

inline bool ResolveUnityObjectMarshal(const MonoEmbeddingApi& api,
                                      const MonoLookupApi& lookup,
                                      const MonoAssemblyList& list,
                                      UnityObjectMarshal* out) {
  *out = UnityObjectMarshal();
  void* unity_object = FindClassInImages(api, list, "UnityEngine", "Object");
  if (!FieldOfType(api, lookup, unity_object, "m_CachedPtr", kMonoTypeI,
                   nullptr, &out->cached_ptr_offset)) {
    return false;
  }
  uint32_t instance_id = 0u;
  if (FieldOfType(api, lookup, unity_object, "m_InstanceID", kMonoTypeI4,
                  nullptr, &instance_id) &&
      instance_id != out->cached_ptr_offset) {
    out->instance_id_offset = instance_id;
  }
  out->gchandle_get_target = lookup.gchandle_get_target;
  out->gchandle_free = lookup.gchandle_free;
  return true;
}

// Resolves a whole binding table in order; stops at the first spec that does
// not resolve (its index and why go to `missing` / `failure`).
template <typename Id, size_t N>
inline bool ResolveIcallTable(const MonoEmbeddingApi& api,
                              const MonoLookupApi& lookup,
                              const MonoAssemblyList& list,
                              const EngineIcallSpec<Id> (&specs)[N],
                              const UnityObjectMarshal& marshal,
                              std::array<IcallBinding, N>* out,
                              int32_t* missing, IcallFailure* failure) {
  for (const EngineIcallSpec<Id>& spec : specs) {
    IcallFailure why = IcallFailure::kNone;
    const IcallBinding binding =
        ResolveIcallBinding(api, lookup, list, spec, marshal, &why);
    if (binding.entry == nullptr) {
      *missing = static_cast<int32_t>(spec.id);
      *failure = why;
      return false;
    }
    (*out)[static_cast<size_t>(spec.id)] = binding;
  }
  return true;
}

// Bounded diagnostic of a binding table: one letter per spec in table order
// (c classic, i injected, - not resolved / not reached).
template <size_t N>
inline void IcallFormString(const std::array<IcallBinding, N>& bindings,
                            char* out, size_t size) {
  if (out == nullptr || size == 0u) return;
  size_t i = 0u;
  for (; i < N && i + 1u < size; ++i) out[i] = IcallFormLetter(bindings[i].form);
  out[i] = 0;
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
  if (!ResolveUnityObjectMarshal(api, lookup, list, &out->marshal)) {
    resolution.result = SiteResult::kObjectFieldMissing;
    return resolution;
  }
  out->cached_ptr_offset = out->marshal.cached_ptr_offset;
  if (!ResolveIcallTable(api, lookup, list, kIcallSpecs, out->marshal,
                         &out->icalls, &resolution.missing_icall,
                         &resolution.icall_failure)) {
    resolution.result = SiteResult::kIcallMissing;
    return resolution;
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

// One glyph per laid-out unit of the longest line we accept (an NVL page).
inline constexpr size_t kMaxGlyphs = 512u;
inline constexpr size_t kMaxLineUnits = 512u;
inline constexpr size_t kMaxRenderedLines = 16u;
// Framework 3 samples every recently written TMP text object (dialogue body,
// its shadow copy, name plates, menus), so the slot table is wider than one
// framework instance per role.
inline constexpr size_t kInstanceSlots = 8u;
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

using FungusIcallSpec = EngineIcallSpec<FungusIcall>;

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
     {kMonoTypeObject, 0, 0}, 0u, IcallSelf::kNativePtr},
    {FungusIcall::kGeneratorLines, "UnityEngine", "TextGenerator",
     "GetLinesInternal", true, kMonoTypeVoid, 1, {kMonoTypeObject, 0, 0}, 0u,
     IcallSelf::kNativePtr},
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
  void* text_class = nullptr;            // MonoClass* UnityEngine.UI.Text
  UnityObjectMarshal marshal;
  std::array<IcallBinding, kFungusIcallCount> icalls{};

  const IcallBinding& Binding(FungusIcall id) const {
    return icalls[static_cast<size_t>(id)];
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
  IcallFailure icall_failure = IcallFailure::kNone;
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

// The UGUI Text layout sites shared by framework 2 (Fungus story Text) and
// framework 4 (any UI.Text): Text / Graphic / FontData / TextGenerator
// fields, UICharInfo / UILineInfo value layouts and the internal calls.
// `text` is the resolved UnityEngine.UI.Text class.
inline FungusSiteResolution ResolveUguiTextLayout(const MonoEmbeddingApi& api,
                                                  const MonoLookupApi& lookup,
                                                  const MonoValueSizeApi& sizes,
                                                  const MonoAssemblyList& list,
                                                  void* text,
                                                  FungusSites* out) {
  FungusSiteResolution resolution;
  out->text_class = text;
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
  if (text == nullptr || generator == nullptr || font_data == nullptr || font == nullptr ||
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
  if (!ResolveUnityObjectMarshal(api, lookup, list, &out->marshal)) {
    resolution.result = FungusSiteResult::kObjectFieldMissing;
    return resolution;
  }
  out->cached_ptr_offset = out->marshal.cached_ptr_offset;
  if (!ResolveIcallTable(api, lookup, list, kFungusIcallSpecs, out->marshal,
                         &out->icalls, &resolution.missing_icall,
                         &resolution.icall_failure)) {
    resolution.result = FungusSiteResult::kIcallMissing;
    return resolution;
  }
  resolution.result = FungusSiteResult::kResolved;
  return resolution;
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
  if (text == nullptr ||
      !FieldOfClass(api, lookup, dialog, "storyText", kMonoTypeClass, text,
                    &out->story_text_offset)) {
    resolution.result = FungusSiteResult::kStoryTextMissing;
    return resolution;
  }
  return ResolveUguiTextLayout(api, lookup, sizes, list, text, out);
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

// Canvas texts are modelled as upright, unmirrored, horizontal layout: the
// text's local +x must reach the screen as +x and local +y as +y (Unity
// screen space, origin bottom-left), each within kAxisSkew of the other axis.
// `origin`, `x_end`, `y_end`: screen points of local (0,0), (d,0), (0,d).  A
// rotated (vertical-writing via a 90 degree RectTransform), mirrored or
// skewed text fails closed: the axis-aligned cell model would hit the wrong
// glyph.  The decision is in screen space, so a Screen Space - Camera canvas
// under a rotated camera (canvas faces the camera) still passes.
inline constexpr float kAxisSkew = 0.02f;

// The identity of a shown text and the selected line, line breaks aside.
// A line break is never drawn (no sampler emits a glyph for LF / CR), and the
// two sides need not agree on it: the text lane strips every `<...>` tag, so
// a `<br>` the renderer lays out as a line feed is absent from the line
// (measured 2026-11-11 on a TMP build: shown 28 units with LF at index 20,
// the selected line the same 27 units without it); a script may also break a
// line the lane joined.  Every other unit must be equal, in order, with
// nothing left on either side.  `shown_to_line` (optional, `shown_units`
// entries) receives each shown unit's index in `line`, kNoSource for a line
// break, so glyph sources keep addressing the line the host reads.
inline bool IsLineBreakUnit(wchar_t c) { return c == L'\n' || c == L'\r'; }
inline bool MatchShownToLine(const wchar_t* shown, size_t shown_units,
                             const wchar_t* line, size_t line_units,
                             uint16_t* shown_to_line) {
  if (shown == nullptr || line == nullptr || shown_units > kMaxLineUnits ||
      line_units > kMaxLineUnits) {
    return false;
  }
  size_t j = 0u;
  bool drawn = false;
  for (size_t i = 0u; i < shown_units; ++i) {
    if (IsLineBreakUnit(shown[i])) {
      if (shown_to_line != nullptr) shown_to_line[i] = kNoSource;
      continue;
    }
    while (j < line_units && IsLineBreakUnit(line[j])) ++j;
    if (j >= line_units || line[j] != shown[i]) return false;
    if (shown_to_line != nullptr) shown_to_line[i] = static_cast<uint16_t>(j);
    drawn = true;
    ++j;
  }
  while (j < line_units && IsLineBreakUnit(line[j])) ++j;
  return drawn && j == line_units;
}

// Step-2 diagnostic of a canvas text whose laid-out units differ from the
// selected line: index of the first differing unit and the coarse kinds of
// the two units there (never the units themselves -- no dialogue in logs).
enum class UnitKind : uint32_t {
  kEnd = 0,        // the sequence ended
  kLineBreak = 1,  // LF, CR
  kSpace = 2,      // space, tab, U+3000
  kAscii = 3,      // other printable ASCII
  kControl = 4,    // other C0 / C1 / format controls (incl. U+200B..U+200F)
  kOther = 5,      // everything else (kana, kanji, punctuation, ...)
};
inline UnitKind KindOfUnit(const wchar_t* units, size_t count, size_t index) {
  if (units == nullptr || index >= count) return UnitKind::kEnd;
  const wchar_t c = units[index];
  if (c == L'\n' || c == L'\r') return UnitKind::kLineBreak;
  if (c == L' ' || c == L'\t' || c == 0x3000) return UnitKind::kSpace;
  if (c > 0x20 && c < 0x7f) return UnitKind::kAscii;
  if (c < 0x20 || (c >= 0x7f && c < 0xa0) || (c >= 0x200b && c <= 0x200f) ||
      c == 0xfeff) {
    return UnitKind::kControl;
  }
  return UnitKind::kOther;
}
struct UnitDifference {
  size_t index = 0u;   // first differing index (== shorter length: a prefix)
  uint32_t kinds = 0u;  // 10 * kind(a[index]) + kind(b[index])
};
inline UnitDifference FirstUnitDifference(const wchar_t* a, size_t a_count,
                                          const wchar_t* b, size_t b_count) {
  UnitDifference diff;
  const size_t shorter = (std::min)(a_count, b_count);
  while (diff.index < shorter && a[diff.index] == b[diff.index]) ++diff.index;
  diff.kinds =
      10u * static_cast<uint32_t>(KindOfUnit(a, a_count, diff.index)) +
      static_cast<uint32_t>(KindOfUnit(b, b_count, diff.index));
  return diff;
}
inline bool ScreenAxesUpright(const Vec3& origin, const Vec3& x_end,
                              const Vec3& y_end) {
  const float xx = x_end.x - origin.x, xy = x_end.y - origin.y;
  const float yx = y_end.x - origin.x, yy = y_end.y - origin.y;
  if (!std::isfinite(xx) || !std::isfinite(xy) || !std::isfinite(yx) ||
      !std::isfinite(yy)) {
    return false;
  }
  return xx > 0.0f && yy > 0.0f && std::fabs(xy) <= kAxisSkew * xx &&
         std::fabs(yx) <= kAxisSkew * yy;
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

// ════════════════════════════════════════════════════════════════════════════
// Framework 3: a bare TextMeshPro UGUI text (TMPro.TextMeshProUGUI).
//
// Scope: Unity Mono games whose dialogue is an ordinary TMP_Text written
// through `TMP_Text.set_text` / `SetText(string, bool)` (the text path's
// kTmpSetText pair) with no script-level message framework the text path
// recognises (no Message.Mes, no Fungus).  Nothing tells which TMP object is
// the dialogue; the selected text lane does: the dialogue object is the one
// whose laid-out text equals the host-selected line.
//
// Engine facts used (TextMeshPro 1.4 / 3.0 sources, com.unity.textmeshpro;
// not measured on a running player):
//   * TMP_Text fields `m_text` (string), `m_textInfo` (TMP_TextInfo),
//     `m_fontColor` (Color; the `color` property, not Graphic.m_Color),
//     `m_firstVisibleCharacter` / `m_maxVisibleCharacters` (int).
//     TextMeshProUGUI's own private `m_canvas` (Canvas) and
//     `m_canvasRenderer` (CanvasRenderer), set in Awake / OnEnable.
//   * TMP_TextInfo.characterCount (int) + characterInfo (TMP_CharacterInfo[],
//     a value-type array; stride from mono_class_value_size).  One entry per
//     parsed character (rich-text tags produce none; spaces and line feeds
//     produce an entry with isVisible false).  `character` (char),
//     `bottomLeft` / `topRight` (Vector3, the RectTransform's local space:
//     exactly what TMP_TextUtilities.FindIntersectingCharacter transforms with
//     rectTransform.TransformPoint), `isVisible` (false for whitespace and for
//     characters cut by maxVisibleCharacters / maxVisibleLines / page mode),
//     `color` (Color32 vertex colour; an `<alpha=#00>` span is alpha 0).
//   * TextMeshProUGUI lays out in its Rebuild, run from the canvas update
//     registry inside Canvas.willRenderCanvases; after the managed
//     `static void Canvas.SendWillRenderCanvases()` returns, every dirty TMP
//     UGUI text of the frame carries the layout of its current text.
//   * Local -> world -> Unity screen pixels exactly as framework 2 (overlay:
//     world == screen; Screen Space - Camera: worldCamera.WorldToScreenPoint;
//     World Space refused).
//
// Nothing here consults a hash, file name or title.  Every class, field,
// method and internal call is resolved by namespace + name + type (+ full
// signature and internal-call flag), unique across images; any gap installs
// nothing.

inline constexpr int kMonoTypeChar = 0x03;
inline constexpr int kMonoTypeU1 = 0x05;

enum class TmpIcall : uint8_t {
  kComponentTransform = 0,
  kBehaviourActiveAndEnabled,
  kTransformLocalToWorld,
  kCanvasRoot,
  kCanvasRenderMode,
  kCanvasWorldCamera,
  kCanvasRendererInheritedAlpha,
  kCanvasRendererCull,
  kCameraWorldToScreen,
  kCameraTargetTexture,
  kScreenWidth,
  kScreenHeight,
  kCount,
};
inline constexpr size_t kTmpIcallCount = static_cast<size_t>(TmpIcall::kCount);

using TmpIcallSpec = EngineIcallSpec<TmpIcall>;

inline constexpr TmpIcallSpec kTmpIcallSpecs[kTmpIcallCount] = {
    {TmpIcall::kComponentTransform, "UnityEngine", "Component",
     "get_transform", true, kMonoTypeClass, 0, {0, 0, 0}, 0u},
    {TmpIcall::kBehaviourActiveAndEnabled, "UnityEngine", "Behaviour",
     "get_isActiveAndEnabled", true, kMonoTypeBoolean, 0, {0, 0, 0}, 0u},
    {TmpIcall::kTransformLocalToWorld, "UnityEngine", "Transform",
     "get_localToWorldMatrix_Injected", true, kMonoTypeVoid, 1,
     {kMonoTypeValueType, 0, 0}, 0x1u},
    {TmpIcall::kCanvasRoot, "UnityEngine", "Canvas", "get_rootCanvas", true,
     kMonoTypeClass, 0, {0, 0, 0}, 0u},
    {TmpIcall::kCanvasRenderMode, "UnityEngine", "Canvas", "get_renderMode",
     true, kMonoTypeValueType, 0, {0, 0, 0}, 0u},
    {TmpIcall::kCanvasWorldCamera, "UnityEngine", "Canvas", "get_worldCamera",
     true, kMonoTypeClass, 0, {0, 0, 0}, 0u},
    {TmpIcall::kCanvasRendererInheritedAlpha, "UnityEngine", "CanvasRenderer",
     "GetInheritedAlpha", true, kMonoTypeSingle, 0, {0, 0, 0}, 0u},
    {TmpIcall::kCanvasRendererCull, "UnityEngine", "CanvasRenderer",
     "get_cull", true, kMonoTypeBoolean, 0, {0, 0, 0}, 0u},
    {TmpIcall::kCameraWorldToScreen, "UnityEngine", "Camera",
     "WorldToScreenPoint_Injected", true, kMonoTypeVoid, 3,
     {kMonoTypeValueType, kMonoTypeValueType, kMonoTypeValueType}, 0x5u},
    {TmpIcall::kCameraTargetTexture, "UnityEngine", "Camera",
     "get_targetTexture", true, kMonoTypeClass, 0, {0, 0, 0}, 0u},
    {TmpIcall::kScreenWidth, "UnityEngine", "Screen", "get_width", false,
     kMonoTypeI4, 0, {0, 0, 0}, 0u},
    {TmpIcall::kScreenHeight, "UnityEngine", "Screen", "get_height", false,
     kMonoTypeI4, 0, {0, 0, 0}, 0u},
};

// Class hierarchy accessors (pure metadata reads: mono_class_get_parent,
// mono_object_get_class).  The sampler only trusts TextMeshProUGUI field
// offsets on an object whose class chain reaches TextMeshProUGUI.
struct MonoClassHierarchyApi {
  void* (*class_get_parent)(void* klass) = nullptr;
  void* (*object_get_class)(void* object) = nullptr;
  bool Complete() const {
    return class_get_parent != nullptr && object_get_class != nullptr;
  }
};

inline constexpr int kMaxClassDepth = 32;

// true iff `klass` is `ancestor` or derives from it (bounded walk).
inline bool ClassDerivesFrom(const MonoClassHierarchyApi& classes, void* klass,
                             void* ancestor) {
  if (classes.class_get_parent == nullptr || ancestor == nullptr) return false;
  for (int depth = 0; klass != nullptr && depth < kMaxClassDepth; ++depth) {
    if (klass == ancestor) return true;
    klass = classes.class_get_parent(klass);
  }
  return false;
}

struct TmpSites {
  void* will_render = nullptr;   // MonoMethod* Canvas.SendWillRenderCanvases
  void* ugui_class = nullptr;    // MonoClass* TMPro.TextMeshProUGUI
  uint32_t text_string_offset = 0u;       // TMP_Text.m_text
  uint32_t text_info_offset = 0u;         // TMP_Text.m_textInfo
  uint32_t font_alpha_offset = 0u;        // TMP_Text.m_fontColor.a
  uint32_t first_visible_offset = 0u;     // TMP_Text.m_firstVisibleCharacter
  uint32_t max_visible_offset = 0u;       // TMP_Text.m_maxVisibleCharacters
  uint32_t canvas_offset = 0u;            // TextMeshProUGUI.m_canvas
  uint32_t renderer_offset = 0u;          // TextMeshProUGUI.m_canvasRenderer
  uint32_t info_count_offset = 0u;        // TMP_TextInfo.characterCount
  uint32_t info_chars_offset = 0u;        // TMP_TextInfo.characterInfo
  uint32_t char_stride = 0u;              // sizeof(TMP_CharacterInfo)
  uint32_t char_character_offset = 0u;    // .character (char)
  uint32_t char_bottom_left_offset = 0u;  // .bottomLeft (Vector3)
  uint32_t char_top_right_offset = 0u;    // .topRight (Vector3)
  uint32_t char_visible_offset = 0u;      // .isVisible (bool)
  uint32_t char_alpha_offset = 0u;        // .color.a (Color32 byte)
  uint32_t cached_ptr_offset = 0u;        // UnityEngine.Object.m_CachedPtr
  UnityObjectMarshal marshal;
  std::array<IcallBinding, kTmpIcallCount> icalls{};

  const IcallBinding& Binding(TmpIcall id) const {
    return icalls[static_cast<size_t>(id)];
  }
};

enum class TmpSiteResult : uint32_t {
  kResolved = 0,
  kApiIncomplete = 1,
  kNoTmpClasses = 2,       // TMP_Text / TextMeshProUGUI absent, ambiguous or
                           // not one hierarchy
  kNoWillRender = 3,       // Canvas.SendWillRenderCanvases not managed static
  kTextFieldsMissing = 4,  // TMP_Text fields
  kUguiFieldsMissing = 5,  // TextMeshProUGUI m_canvas / m_canvasRenderer
  kTextInfoMissing = 6,    // TMP_TextInfo characterCount / characterInfo
  kCharLayoutMismatch = 7, // TMP_CharacterInfo layout
  kObjectFieldMissing = 8,
  kIcallMissing = 9,
};

struct TmpSiteResolution {
  TmpSiteResult result = TmpSiteResult::kApiIncomplete;
  int32_t missing_icall = -1;
  IcallFailure icall_failure = IcallFailure::kNone;
};

// A value-type field of `klass` whose type is exactly `expected`; the offset
// is relative to the unboxed value.
inline bool ValueFieldOfClass(const MonoEmbeddingApi& api,
                              const MonoLookupApi& lookup, void* klass,
                              const char* name, void* expected,
                              uint32_t* offset_out) {
  uint32_t boxed = 0u;
  if (!FieldOfClass(api, lookup, klass, name, kMonoTypeValueType, expected,
                    &boxed)) {
    return false;
  }
  *offset_out = boxed - 2u * static_cast<uint32_t>(sizeof(void*));
  return true;
}

// `static void Canvas.SendWillRenderCanvases()`: a managed body the native
// player invokes every frame (an internal call there would have no JIT entry
// to detour).  Both canvas-text frameworks (3 TMP, 4 UI.Text) sample after it:
// the canvas update it raises rebuilds every dirty UGUI graphic.
inline void* ResolveWillRenderCanvases(const MonoEmbeddingApi& api,
                                       const MonoLookupApi& lookup,
                                       const MonoAssemblyList& list) {
  void* canvas = FindClassInImages(api, list, "UnityEngine", "Canvas");
  void* will_render =
      canvas == nullptr ? nullptr
                        : FindMonoMethod(api, canvas, "SendWillRenderCanvases",
                                         false, kMonoTypeVoid, 0, nullptr);
  if (will_render == nullptr) return nullptr;
  uint32_t iflags = 0u;
  lookup.method_get_flags(will_render, &iflags);
  return (iflags & kMethodImplInternalCall) != 0u ? nullptr : will_render;
}

// Caller must be attached to the root domain.
inline TmpSiteResolution ResolveTmpSites(const MonoEmbeddingApi& api,
                                         const MonoLookupApi& lookup,
                                         const MonoValueSizeApi& sizes,
                                         const MonoClassHierarchyApi& classes,
                                         TmpSites* out) {
  TmpSiteResolution resolution;
  if (out == nullptr || !api.CompleteForResolution() || !lookup.Complete() ||
      sizes.class_value_size == nullptr || !classes.Complete()) {
    return resolution;
  }
  *out = TmpSites();
  MonoAssemblyList list;
  api.assembly_foreach(&CollectMonoAssembly, &list);
  const MonoTextHookSpec& setter =
      MonoTextHookSpecFor(MonoTextHookId::kTmpSetText);
  void* tmp_text =
      FindClassInImages(api, list, setter.name_space, setter.class_name);
  void* ugui = FindClassInImages(api, list, setter.name_space,
                                 "TextMeshProUGUI");
  if (tmp_text == nullptr || ugui == nullptr || ugui == tmp_text ||
      !ClassDerivesFrom(classes, ugui, tmp_text)) {
    resolution.result = TmpSiteResult::kNoTmpClasses;
    return resolution;
  }
  out->ugui_class = ugui;
  void* will_render = ResolveWillRenderCanvases(api, lookup, list);
  if (will_render == nullptr) {
    resolution.result = TmpSiteResult::kNoWillRender;
    return resolution;
  }
  out->will_render = will_render;
  void* text_info = FindClassInImages(api, list, setter.name_space,
                                      "TMP_TextInfo");
  void* char_info = FindClassInImages(api, list, setter.name_space,
                                      "TMP_CharacterInfo");
  void* color = FindClassInImages(api, list, "UnityEngine", "Color");
  uint32_t color_offset = 0u, alpha_offset = 0u;
  if (text_info == nullptr || color == nullptr ||
      !FieldOfType(api, lookup, tmp_text, "m_text", kMonoTypeString, nullptr,
                   &out->text_string_offset) ||
      !FieldOfClass(api, lookup, tmp_text, "m_textInfo", kMonoTypeClass,
                    text_info, &out->text_info_offset) ||
      !FieldOfClass(api, lookup, tmp_text, "m_fontColor", kMonoTypeValueType,
                    color, &color_offset) ||
      !ValueFieldOffset(api, lookup, color, "a", kMonoTypeSingle,
                        &alpha_offset) ||
      alpha_offset + 4u > 16u ||
      !FieldOfType(api, lookup, tmp_text, "m_firstVisibleCharacter",
                   kMonoTypeI4, nullptr, &out->first_visible_offset) ||
      !FieldOfType(api, lookup, tmp_text, "m_maxVisibleCharacters",
                   kMonoTypeI4, nullptr, &out->max_visible_offset)) {
    resolution.result = TmpSiteResult::kTextFieldsMissing;
    return resolution;
  }
  out->font_alpha_offset = color_offset + alpha_offset;
  void* canvas = FindClassInImages(api, list, "UnityEngine", "Canvas");
  void* renderer =
      FindClassInImages(api, list, "UnityEngine", "CanvasRenderer");
  if (canvas == nullptr || renderer == nullptr ||
      !FieldOfClass(api, lookup, ugui, "m_canvas", kMonoTypeClass, canvas,
                    &out->canvas_offset) ||
      !FieldOfClass(api, lookup, ugui, "m_canvasRenderer", kMonoTypeClass,
                    renderer, &out->renderer_offset)) {
    resolution.result = TmpSiteResult::kUguiFieldsMissing;
    return resolution;
  }
  void* chars_field = nullptr;
  void* chars_array = nullptr;
  if (char_info == nullptr ||
      !FieldOfType(api, lookup, text_info, "characterCount", kMonoTypeI4,
                   nullptr, &out->info_count_offset) ||
      !FieldOfType(api, lookup, text_info, "characterInfo", kMonoTypeSzArray,
                   &chars_field, &out->info_chars_offset) ||
      out->info_count_offset == out->info_chars_offset ||
      (chars_array = lookup.class_from_mono_type(
           lookup.field_get_type(chars_field))) == nullptr ||
      lookup.class_get_element_class(chars_array) != char_info) {
    resolution.result = TmpSiteResult::kTextInfoMissing;
    return resolution;
  }
  void* vector3 = FindClassInImages(api, list, "UnityEngine", "Vector3");
  void* color32 = FindClassInImages(api, list, "UnityEngine", "Color32");
  uint32_t align = 0u;
  const int32_t stride = sizes.class_value_size(char_info, &align);
  const int32_t vector3_size =
      vector3 == nullptr ? 0 : sizes.class_value_size(vector3, &align);
  uint32_t color32_offset = 0u, color32_alpha = 0u;
  if (stride <= 0 || vector3_size != static_cast<int32_t>(sizeof(Vec3)) ||
      color32 == nullptr ||
      !ValueFieldOffset(api, lookup, char_info, "character", kMonoTypeChar,
                        &out->char_character_offset) ||
      !ValueFieldOfClass(api, lookup, char_info, "bottomLeft", vector3,
                         &out->char_bottom_left_offset) ||
      !ValueFieldOfClass(api, lookup, char_info, "topRight", vector3,
                         &out->char_top_right_offset) ||
      !ValueFieldOffset(api, lookup, char_info, "isVisible", kMonoTypeBoolean,
                        &out->char_visible_offset) ||
      !ValueFieldOfClass(api, lookup, char_info, "color", color32,
                         &color32_offset) ||
      !ValueFieldOffset(api, lookup, color32, "a", kMonoTypeU1,
                        &color32_alpha) ||
      color32_alpha >= 4u) {
    resolution.result = TmpSiteResult::kCharLayoutMismatch;
    return resolution;
  }
  out->char_alpha_offset = color32_offset + color32_alpha;
  const uint32_t limit = static_cast<uint32_t>(stride);
  if (out->char_character_offset + 2u > limit ||
      out->char_bottom_left_offset + sizeof(Vec3) > limit ||
      out->char_top_right_offset + sizeof(Vec3) > limit ||
      out->char_visible_offset + 1u > limit ||
      out->char_alpha_offset + 1u > limit) {
    resolution.result = TmpSiteResult::kCharLayoutMismatch;
    return resolution;
  }
  out->char_stride = limit;
  if (!ResolveUnityObjectMarshal(api, lookup, list, &out->marshal)) {
    resolution.result = TmpSiteResult::kObjectFieldMissing;
    return resolution;
  }
  out->cached_ptr_offset = out->marshal.cached_ptr_offset;
  if (!ResolveIcallTable(api, lookup, list, kTmpIcallSpecs, out->marshal,
                         &out->icalls, &resolution.missing_icall,
                         &resolution.icall_failure)) {
    resolution.result = TmpSiteResult::kIcallMissing;
    return resolution;
  }
  resolution.result = TmpSiteResult::kResolved;
  return resolution;
}

// One TMP character is drawn iff TMP itself marked it visible, it lies inside
// [firstVisibleCharacter, maxVisibleCharacters) (the typewriter reveal) and
// its vertex alpha is readable (an `<alpha=#00>` span is not).
inline constexpr uint8_t kMinReadableVertexAlpha = 128u;

inline bool TmpCharacterShown(bool is_visible, size_t index,
                              int32_t first_visible, int32_t max_visible,
                              uint8_t vertex_alpha) {
  return is_visible && first_visible >= 0 &&
         index >= static_cast<size_t>(first_visible) && max_visible > 0 &&
         index < static_cast<size_t>(max_visible) &&
         vertex_alpha >= kMinReadableVertexAlpha;
}

// Several TMP objects can show the selected line at once (a shadow / outline
// copy drawn as a second text object, measured as two lanes with identical
// text).  `readable` is a clean sample with at least one shown glyph;
// `selected_lane` is the object whose own lane is the host-selected thread.
struct TmpMatch {
  bool readable = false;
  bool selected_lane = false;
};

enum class TmpChoice : uint8_t {
  kChosen = 0,
  kNoneReadable = 1,
  kAmbiguous = 2,
};

// Deterministic: the single readable match; among several readable matches
// the single one whose lane the host selected; anything else fails closed.
inline TmpChoice ChooseTmpMatch(const TmpMatch* matches, size_t count,
                                size_t* chosen) {
  if (matches == nullptr || chosen == nullptr) return TmpChoice::kNoneReadable;
  size_t readable = 0u, readable_index = 0u;
  size_t selected = 0u, selected_index = 0u;
  for (size_t i = 0u; i < count; ++i) {
    if (!matches[i].readable) continue;
    ++readable;
    readable_index = i;
    if (matches[i].selected_lane) {
      ++selected;
      selected_index = i;
    }
  }
  if (readable == 0u) return TmpChoice::kNoneReadable;
  if (readable == 1u) {
    *chosen = readable_index;
    return TmpChoice::kChosen;
  }
  if (selected == 1u) {
    *chosen = selected_index;
    return TmpChoice::kChosen;
  }
  return TmpChoice::kAmbiguous;
}

// ════════════════════════════════════════════════════════════════════════════
// Framework 4: a bare UGUI Text (UnityEngine.UI.Text) whose text is the
// selected line.
//
// Same canvas-text mechanism as framework 3 (the text path's
// `UI.Text.set_text` detour remembers the object, the main thread samples it
// after Canvas.SendWillRenderCanvases, the selected line picks the object,
// duplicates resolve through ChooseTmpMatch), with framework 2's UGUI layout
// reading: the Text's cached TextGenerator laid out exactly `m_Text`
// (m_LastString), one UICharInfo per raw unit + terminator, cells
// [cursor.x, +charWidth] x [lineTop - height, lineTop] / pixelsPerUnit
// through localToWorld and the root canvas.  Scope measured as missing on a
// real player (2026-11-11): an x64 Mono NVL whose story text is only ever a
// UI.Text (no TMP object renders), so framework 3 alone never had a sample.

enum class UiTextSiteResult : uint32_t {
  kResolved = 0,
  kApiIncomplete = 1,
  kNoTextClass = 2,    // UnityEngine.UI.Text absent or ambiguous
  kNoWillRender = 3,
  kLayout = 4,         // a shared UGUI layout site (see `layout`)
};

struct UiTextSiteResolution {
  UiTextSiteResult result = UiTextSiteResult::kApiIncomplete;
  FungusSiteResult layout = FungusSiteResult::kApiIncomplete;
  int32_t missing_icall = -1;
  IcallFailure icall_failure = IcallFailure::kNone;
};

// Caller must be attached to the root domain.  `out` receives the UGUI Text
// layout sites (FungusSites without the SayDialog part), `will_render_out`
// the managed SendWillRenderCanvases.
inline UiTextSiteResolution ResolveUiTextSites(const MonoEmbeddingApi& api,
                                               const MonoLookupApi& lookup,
                                               const MonoValueSizeApi& sizes,
                                               FungusSites* out,
                                               void** will_render_out) {
  UiTextSiteResolution resolution;
  if (out == nullptr || will_render_out == nullptr ||
      !api.CompleteForResolution() || !lookup.Complete() ||
      sizes.class_value_size == nullptr) {
    return resolution;
  }
  *out = FungusSites();
  *will_render_out = nullptr;
  MonoAssemblyList list;
  api.assembly_foreach(&CollectMonoAssembly, &list);
  const MonoTextHookSpec& setter =
      MonoTextHookSpecFor(MonoTextHookId::kUiTextSetText);
  void* text =
      FindClassInImages(api, list, setter.name_space, setter.class_name);
  if (text == nullptr) {
    resolution.result = UiTextSiteResult::kNoTextClass;
    return resolution;
  }
  void* will_render = ResolveWillRenderCanvases(api, lookup, list);
  if (will_render == nullptr) {
    resolution.result = UiTextSiteResult::kNoWillRender;
    return resolution;
  }
  const FungusSiteResolution layout =
      ResolveUguiTextLayout(api, lookup, sizes, list, text, out);
  resolution.layout = layout.result;
  resolution.missing_icall = layout.missing_icall;
  resolution.icall_failure = layout.icall_failure;
  if (layout.result != FungusSiteResult::kResolved) {
    resolution.result = UiTextSiteResult::kLayout;
    return resolution;
  }
  *will_render_out = will_render;
  resolution.result = UiTextSiteResult::kResolved;
  return resolution;
}

}  // namespace fushi_voice_hook::unity_mono_lookup
