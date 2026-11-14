#pragma once

// Unity IL2CPP: the runtime-agnostic accessor layer under the shared Unity
// canvas-text lookup (unity_mono_lookup_core.h frameworks 3 TMP / 4 UI.Text).
//
// The lookup core resolves every class, field, value layout, managed method
// and engine binding through four accessor tables (MonoEmbeddingApi,
// MonoLookupApi, MonoValueSizeApi, MonoClassHierarchyApi).  Their shapes are
// those of the Mono embedding API, but nothing in the resolvers is Mono
// specific: they ask "class by namespace + name in an image", "field type
// kind / offset", "method name / instance-ness / parameter kinds / by-ref /
// internal-call flag", "element class of an array", "value size".  IL2CPP's
// exported reflection API (GameAssembly.dll, il2cpp-api-functions.h) answers
// exactly the same questions with the same ECMA-335 type kinds
// (IL2CPP_TYPE_* == MONO_TYPE_*), so this header fills the four tables with
// thin shims over the il2cpp_* exports.  The resolvers, the sampler, the model
// and the click claim stay one implementation for both scripting backends.
//
// Where the backends really differ, the shim says so:
//   * signatures: IL2CPP has no signature object; the "signature" handle is
//     the MethodInfo itself (il2cpp_method_get_param_count / _param /
//     _return_type / _is_instance).
//   * "compile": IL2CPP methods are AOT.  The entry is MethodInfo's first
//     field (`Il2CppMethodPointer methodPointer`, every IL2CPP generation) and
//     is accepted only inside GameAssembly.dll's mapped image (anything else
//     -- null for a stripped body, a shared generic stub elsewhere -- is no
//     entry).  IL2CPP managed instance methods take (this, args...,
//     const MethodInfo*); a static `void ()` method takes (const MethodInfo*).
//   * engine bindings: an extern [InternalCall] declaration resolves through
//     il2cpp_resolve_icall("Ns.Class::Method"), which returns the same
//     UnityPlayer C entry Mono's mono_lookup_internal_call returns, so the
//     binding function types are shared.  The short name cannot tell
//     overloads apart, so a binding whose name is declared as more than one
//     internal call on its class resolves to nothing (fail closed).  Unity 6
//     `<method>_Injected` bindings are registered the same way under their
//     own name (InternalCalls::Resolve looks the full "Ns.Class::Method(...)"
//     key up first, then the part before '('; the player registers the bare
//     "Ns.Class::Method" key), so the same short name serves both forms.
//   * value-type field offsets: IL2CPP reports them boxed-relative (after the
//     two-pointer Il2CppObject header) exactly like Mono, so the core's
//     `offset - 2 * sizeof(void*)` holds.
//   * arrays: Il2CppArray = Il2CppObject (2 pointers) + bounds + max_length,
//     then the elements (kIl2CppSizeOfArray == 4 pointers on x86 and x64);
//     il2cpp_array_object_header_size, when exported, must agree.
//   * framework 1 (Message.Mes, per-glyph TextMesh) needs System.Type objects
//     and GC handles; it is a Mono-only framework and the shims for those two
//     entries return nothing.
//
// Nothing here consults a hash, file name or title.  A missing export is
// reported by name (bounded) and installs nothing.

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

#include "text_thread_identity.h"
#include "unity_mono_lookup_core.h"
#include "unity_mono_text.h"

namespace fushi_voice_hook::unity_il2cpp {

namespace ul = fushi_voice_hook::unity_mono_lookup;

// ── exports ────────────────────────────────────────────────────────────────

// il2cpp-api-functions.h shapes (all cdecl C functions on x86).
struct Il2CppExports {
  void* (*domain_get)() = nullptr;
  const void** (*domain_get_assemblies)(const void* domain,
                                        size_t* size) = nullptr;
  void* (*thread_current)() = nullptr;
  void* (*thread_attach)(void* domain) = nullptr;
  void (*thread_detach)(void* thread) = nullptr;
  const void* (*assembly_get_image)(const void* assembly) = nullptr;
  const char* (*image_get_name)(const void* image) = nullptr;
  void* (*class_from_name)(const void* image, const char* name_space,
                           const char* name) = nullptr;
  const void* (*class_get_methods)(void* klass, void** iter) = nullptr;
  const char* (*method_get_name)(const void* method) = nullptr;
  uint32_t (*method_get_param_count)(const void* method) = nullptr;
  const void* (*method_get_param)(const void* method,
                                  uint32_t index) = nullptr;
  const void* (*method_get_return_type)(const void* method) = nullptr;
  bool (*method_is_instance)(const void* method) = nullptr;
  uint32_t (*method_get_flags)(const void* method, uint32_t* iflags) = nullptr;
  void* (*method_get_class)(const void* method) = nullptr;
  int (*type_get_type)(const void* type) = nullptr;
  bool (*type_is_byref)(const void* type) = nullptr;
  void* (*class_from_type)(const void* type) = nullptr;
  void* (*class_get_element_class)(void* klass) = nullptr;
  void* (*class_get_parent)(void* klass) = nullptr;
  const char* (*class_get_name)(void* klass) = nullptr;
  const char* (*class_get_namespace)(void* klass) = nullptr;
  int32_t (*class_value_size)(void* klass, uint32_t* align) = nullptr;
  void* (*class_get_field_from_name)(void* klass, const char* name) = nullptr;
  size_t (*field_get_offset)(void* field) = nullptr;
  const void* (*field_get_type)(void* field) = nullptr;
  void* (*object_get_class)(void* object) = nullptr;
  void* (*resolve_icall)(const char* name) = nullptr;
  uint32_t (*array_length)(void* array) = nullptr;
  int32_t (*string_length)(void* string) = nullptr;
  const wchar_t* (*string_chars)(void* string) = nullptr;
  // Optional cross-check of the array header (absent on older players).
  uint32_t (*array_object_header_size)() = nullptr;
  // Optional: GC handle access, read only by a Unity 6 (injected) engine
  // binding that returns a UnityEngine.Object (its result is the GC handle
  // the native object owns).  il2cpp-api-functions.h declares the handle
  // `Il2CppGCHandle` (void*) from 2023.1 on and uint32_t before; the
  // pointer-sized declaration passes the same register / stack slot either
  // way (a pre-2023 handle is a 32-bit value), and pre-2023 players have no
  // injected bindings to call it for.
  void* (*gchandle_get_target)(void* handle) = nullptr;
  void (*gchandle_free)(void* handle) = nullptr;
};

struct ExportSlot {
  const char* name;
  void** slot;
  bool required;
};

// Every export the canvas lookup reads, in one table (name -> slot).
inline size_t Il2CppExportSlots(Il2CppExports* e, ExportSlot* out,
                                size_t capacity) {
  const ExportSlot slots[] = {
      {"il2cpp_domain_get", reinterpret_cast<void**>(&e->domain_get), true},
      {"il2cpp_domain_get_assemblies",
       reinterpret_cast<void**>(&e->domain_get_assemblies), true},
      {"il2cpp_thread_current", reinterpret_cast<void**>(&e->thread_current),
       true},
      {"il2cpp_thread_attach", reinterpret_cast<void**>(&e->thread_attach),
       true},
      {"il2cpp_thread_detach", reinterpret_cast<void**>(&e->thread_detach),
       true},
      {"il2cpp_assembly_get_image",
       reinterpret_cast<void**>(&e->assembly_get_image), true},
      {"il2cpp_image_get_name", reinterpret_cast<void**>(&e->image_get_name),
       true},
      {"il2cpp_class_from_name", reinterpret_cast<void**>(&e->class_from_name),
       true},
      {"il2cpp_class_get_methods",
       reinterpret_cast<void**>(&e->class_get_methods), true},
      {"il2cpp_method_get_name", reinterpret_cast<void**>(&e->method_get_name),
       true},
      {"il2cpp_method_get_param_count",
       reinterpret_cast<void**>(&e->method_get_param_count), true},
      {"il2cpp_method_get_param",
       reinterpret_cast<void**>(&e->method_get_param), true},
      {"il2cpp_method_get_return_type",
       reinterpret_cast<void**>(&e->method_get_return_type), true},
      {"il2cpp_method_is_instance",
       reinterpret_cast<void**>(&e->method_is_instance), true},
      {"il2cpp_method_get_flags",
       reinterpret_cast<void**>(&e->method_get_flags), true},
      {"il2cpp_method_get_class",
       reinterpret_cast<void**>(&e->method_get_class), true},
      {"il2cpp_type_get_type", reinterpret_cast<void**>(&e->type_get_type),
       true},
      {"il2cpp_type_is_byref", reinterpret_cast<void**>(&e->type_is_byref),
       true},
      {"il2cpp_class_from_type", reinterpret_cast<void**>(&e->class_from_type),
       true},
      {"il2cpp_class_get_element_class",
       reinterpret_cast<void**>(&e->class_get_element_class), true},
      {"il2cpp_class_get_parent",
       reinterpret_cast<void**>(&e->class_get_parent), true},
      {"il2cpp_class_get_name", reinterpret_cast<void**>(&e->class_get_name),
       true},
      {"il2cpp_class_get_namespace",
       reinterpret_cast<void**>(&e->class_get_namespace), true},
      {"il2cpp_class_value_size",
       reinterpret_cast<void**>(&e->class_value_size), true},
      {"il2cpp_class_get_field_from_name",
       reinterpret_cast<void**>(&e->class_get_field_from_name), true},
      {"il2cpp_field_get_offset",
       reinterpret_cast<void**>(&e->field_get_offset), true},
      {"il2cpp_field_get_type", reinterpret_cast<void**>(&e->field_get_type),
       true},
      {"il2cpp_object_get_class",
       reinterpret_cast<void**>(&e->object_get_class), true},
      {"il2cpp_resolve_icall", reinterpret_cast<void**>(&e->resolve_icall),
       true},
      {"il2cpp_array_length", reinterpret_cast<void**>(&e->array_length),
       true},
      {"il2cpp_string_length", reinterpret_cast<void**>(&e->string_length),
       true},
      {"il2cpp_string_chars", reinterpret_cast<void**>(&e->string_chars),
       true},
      {"il2cpp_array_object_header_size",
       reinterpret_cast<void**>(&e->array_object_header_size), false},
      {"il2cpp_gchandle_get_target",
       reinterpret_cast<void**>(&e->gchandle_get_target), false},
      {"il2cpp_gchandle_free", reinterpret_cast<void**>(&e->gchandle_free),
       false},
  };
  const size_t count = sizeof(slots) / sizeof(slots[0]);
  for (size_t i = 0; out != nullptr && i < count && i < capacity; ++i) {
    out[i] = slots[i];
  }
  return count;
}

inline constexpr size_t kIl2CppExportSlotCount = 35u;
inline constexpr size_t kMissingExportsChars = 192u;

struct ExportReport {
  uint32_t required = 0u;
  uint32_t found = 0u;  // required exports found
  bool header_size_export = false;
  bool gchandle_exports = false;  // il2cpp_gchandle_get_target + _free
  // Comma-joined names of the missing required exports without the
  // `il2cpp_` prefix, truncated with "..." (never more than the buffer).
  char missing[kMissingExportsChars] = {};
  bool Complete() const { return required != 0u && found == required; }
};

// `resolve(name)` -> export address or nullptr (GetProcAddress in the hook,
// a fake table in tests).
template <typename Resolve>
ExportReport LoadIl2CppExports(Resolve resolve, Il2CppExports* out) {
  ExportReport report;
  *out = Il2CppExports();
  ExportSlot slots[kIl2CppExportSlotCount] = {};
  const size_t count = Il2CppExportSlots(out, slots, kIl2CppExportSlotCount);
  size_t used = 0u;
  bool truncated = false;
  for (size_t i = 0; i < count && i < kIl2CppExportSlotCount; ++i) {
    *slots[i].slot = resolve(slots[i].name);
    if (!slots[i].required) continue;
    ++report.required;
    if (*slots[i].slot != nullptr) {
      ++report.found;
      continue;
    }
    if (truncated) continue;
    const char* shortname = slots[i].name + std::strlen("il2cpp_");
    const size_t length = std::strlen(shortname);
    const size_t need = length + (used == 0u ? 0u : 1u);
    // Keep room for "..." and the terminator.
    if (used + need + 4u <= kMissingExportsChars) {
      if (used != 0u) report.missing[used++] = ',';
      std::memcpy(report.missing + used, shortname, length);
      used += length;
    } else {
      std::memcpy(report.missing + used, "...", 3u);
      used += 3u;
      truncated = true;
    }
  }
  report.missing[used] = 0;
  report.header_size_export = out->array_object_header_size != nullptr;
  report.gchandle_exports =
      out->gchandle_get_target != nullptr && out->gchandle_free != nullptr;
  return report;
}

// ── structural identity ────────────────────────────────────────────────────

inline bool Il2CppPathExists(const std::wstring& path, bool directory) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) return false;
  return ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) == directory;
}

struct LayoutReport {
  bool game_assembly = false;  // <dir>\GameAssembly.dll
  bool il2cpp_data = false;    // <dir>\<stem>_Data\il2cpp_data\ (directory)
  bool Complete() const { return game_assembly && il2cpp_data; }
};

// The player's on-disk IL2CPP layout next to the executable (`stem` is the
// executable name without extension; tests feed a temp directory).
inline LayoutReport MatchUnityIl2CppLayout(const std::wstring& directory,
                                           const std::wstring& stem) {
  LayoutReport report;
  if (directory.empty() || stem.empty()) return report;
  report.game_assembly =
      Il2CppPathExists(directory + L"\\GameAssembly.dll", false);
  report.il2cpp_data = Il2CppPathExists(
      directory + L"\\" + stem + L"_Data\\il2cpp_data", true);
  return report;
}

inline LayoutReport HostUnityIl2CppLayout() {
  wchar_t executable[MAX_PATH] = {0};
  const DWORD length = GetModuleFileNameW(nullptr, executable, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return LayoutReport();
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return LayoutReport();
  *slash = 0;
  std::wstring stem(slash + 1);
  const size_t dot = stem.find_last_of(L'.');
  if (dot != std::wstring::npos) stem.erase(dot);
  return MatchUnityIl2CppLayout(executable, stem);
}

// ── facade state (one runtime per process) ─────────────────────────────────

inline Il2CppExports g_exports;
// GameAssembly.dll mapped image [begin, end): the only place an AOT method
// entry may live.
inline uintptr_t g_code_begin = 0u;
inline uintptr_t g_code_end = 0u;
// kIl2CppSizeOfArray: Il2CppObject (klass, monitor) + bounds + max_length.
inline constexpr uint32_t kArrayHeaderBytes =
    4u * static_cast<uint32_t>(sizeof(void*));
inline constexpr size_t kIcallNameChars = 384u;

inline bool CodeRangeContains(uintptr_t address) {
  return g_code_end > g_code_begin && address >= g_code_begin &&
         address < g_code_end;
}

// MethodInfo.methodPointer (first field) when it lies in GameAssembly.dll.
inline void* ManagedEntry(const void* method) {
  if (method == nullptr) return nullptr;
  const uintptr_t entry = *reinterpret_cast<const uintptr_t*>(method);
  return CodeRangeContains(entry) ? reinterpret_cast<void*>(entry) : nullptr;
}

// "Ns.Class::Method" (namespace omitted when empty) of an extern declaration
// whose name is a single internal call on its class; otherwise false.
inline bool IcallShortName(const void* method, char* out, size_t size) {
  const Il2CppExports& e = g_exports;
  if (method == nullptr || out == nullptr || size == 0u) return false;
  void* klass = e.method_get_class(method);
  const char* method_name = e.method_get_name(method);
  const char* class_name = klass == nullptr ? nullptr : e.class_get_name(klass);
  const char* name_space =
      klass == nullptr ? nullptr : e.class_get_namespace(klass);
  if (method_name == nullptr || class_name == nullptr) return false;
  uint32_t declared = 0u;
  void* iter = nullptr;
  for (int guard = 0; guard < 8192; ++guard) {
    const void* candidate = e.class_get_methods(klass, &iter);
    if (candidate == nullptr) break;
    const char* name = e.method_get_name(candidate);
    if (name == nullptr || std::strcmp(name, method_name) != 0) continue;
    uint32_t iflags = 0u;
    e.method_get_flags(candidate, &iflags);
    if ((iflags & ul::kMethodImplInternalCall) != 0u) ++declared;
  }
  if (declared != 1u) return false;
  const int written =
      name_space != nullptr && name_space[0] != 0
          ? std::snprintf(out, size, "%s.%s::%s", name_space, class_name,
                          method_name)
          : std::snprintf(out, size, "%s::%s", class_name, method_name);
  return written > 0 && static_cast<size_t>(written) < size;
}

// ── shims: MonoEmbeddingApi ────────────────────────────────────────────────

inline void* ShimRootDomain() { return g_exports.domain_get(); }
inline void* ShimThreadAttach(void* domain) {
  return g_exports.thread_attach(domain);
}
inline void ShimThreadDetach(void* thread) { g_exports.thread_detach(thread); }
inline void ShimAssemblyForeach(void (*func)(void*, void*), void* user_data) {
  size_t count = 0u;
  const void** assemblies =
      g_exports.domain_get_assemblies(g_exports.domain_get(), &count);
  for (size_t i = 0; assemblies != nullptr && i < count; ++i) {
    func(const_cast<void*>(assemblies[i]), user_data);
  }
}
inline void* ShimAssemblyGetImage(void* assembly) {
  return const_cast<void*>(g_exports.assembly_get_image(assembly));
}
inline const char* ShimImageGetName(void* image) {
  return g_exports.image_get_name(image);
}
inline void* ShimClassFromName(void* image, const char* name_space,
                               const char* name) {
  return g_exports.class_from_name(image, name_space, name);
}
inline void* ShimClassGetMethods(void* klass, void** iter) {
  return const_cast<void*>(g_exports.class_get_methods(klass, iter));
}
inline const char* ShimMethodGetName(void* method) {
  return g_exports.method_get_name(method);
}
// The "signature" handle is the MethodInfo itself.
inline void* ShimMethodSignature(void* method) { return method; }
inline uint32_t ShimSignatureParamCount(void* method) {
  return g_exports.method_get_param_count(method);
}
inline void* ShimSignatureGetParams(void* method, void** iter) {
  const uintptr_t index = reinterpret_cast<uintptr_t>(*iter);
  if (index >= g_exports.method_get_param_count(method)) return nullptr;
  *iter = reinterpret_cast<void*>(index + 1u);
  return const_cast<void*>(
      g_exports.method_get_param(method, static_cast<uint32_t>(index)));
}
inline void* ShimSignatureReturnType(void* method) {
  return const_cast<void*>(g_exports.method_get_return_type(method));
}
inline int32_t ShimSignatureIsInstance(void* method) {
  return g_exports.method_is_instance(method) ? 1 : 0;
}
inline int ShimTypeGetType(void* type) { return g_exports.type_get_type(type); }
inline void* ShimCompileMethod(void* method) { return ManagedEntry(method); }
inline int ShimStringLength(void* string) {
  return g_exports.string_length(string);
}
inline const wchar_t* ShimStringChars(void* string) {
  return g_exports.string_chars(string);
}

// ── shims: MonoLookupApi ───────────────────────────────────────────────────

inline void* ShimFieldFromName(void* klass, const char* name) {
  return g_exports.class_get_field_from_name(klass, name);
}
inline uint32_t ShimFieldOffset(void* field) {
  const size_t offset = g_exports.field_get_offset(field);
  return offset > 0xffffffffu ? 0xffffffffu : static_cast<uint32_t>(offset);
}
inline void* ShimFieldType(void* field) {
  return const_cast<void*>(g_exports.field_get_type(field));
}
inline void* ShimClassFromType(void* type) {
  return g_exports.class_from_type(type);
}
inline void* ShimElementClass(void* klass) {
  return g_exports.class_get_element_class(klass);
}
inline void* ShimLookupInternalCall(void* method) {
  char name[kIcallNameChars] = {};
  if (!IcallShortName(method, name, sizeof(name))) return nullptr;
  return g_exports.resolve_icall(name);
}
inline uint32_t ShimMethodFlags(void* method, uint32_t* iflags) {
  return g_exports.method_get_flags(method, iflags);
}
// Framework 1 only (System.Type objects, GC handles): Mono-only.
inline void* ShimClassGetType(void*) { return nullptr; }
inline void* ShimTypeGetObject(void*, void*) { return nullptr; }
inline uint32_t ShimGcHandleNew(void*, int32_t) { return 0u; }
// Unity 6 object results (unity_mono_lookup_core.h BindingObjectResult).
inline void* ShimGcHandleGetTarget(void* handle) {
  return g_exports.gchandle_get_target(handle);
}
inline void ShimGcHandleFree(void* handle) { g_exports.gchandle_free(handle); }
inline int32_t ShimTypeIsByref(void* type) {
  return g_exports.type_is_byref(type) ? 1 : 0;
}
inline uintptr_t ShimArrayLength(void* array) {
  return static_cast<uintptr_t>(g_exports.array_length(array));
}
inline char* ShimArrayAddr(void* array, int32_t size, uintptr_t index) {
  if (array == nullptr || size <= 0) return nullptr;
  return static_cast<char*>(array) + kArrayHeaderBytes +
         static_cast<uintptr_t>(size) * index;
}

// ── tables ─────────────────────────────────────────────────────────────────

struct Facade {
  MonoEmbeddingApi api;
  ul::MonoLookupApi lookup;
  ul::MonoValueSizeApi sizes;
  ul::MonoClassHierarchyApi classes;
};

enum class FacadeResult : uint32_t {
  kReady = 0,
  kExportsMissing = 1,   // see ExportReport::missing
  kNoCodeRange = 2,      // GameAssembly.dll image range unknown
  kArrayHeader = 3,      // il2cpp_array_object_header_size disagrees
};

// Publishes `exports` and GameAssembly's image range as the process facade
// and fills the four accessor tables.  On any refusal the tables stay empty
// (every resolver then reports kApiIncomplete).
inline FacadeResult InstallFacade(const Il2CppExports& exports,
                                  const ExportReport& report,
                                  uintptr_t code_begin, uintptr_t code_end,
                                  Facade* out) {
  *out = Facade();
  if (!report.Complete()) return FacadeResult::kExportsMissing;
  if (code_end <= code_begin) return FacadeResult::kNoCodeRange;
  if (exports.array_object_header_size != nullptr &&
      exports.array_object_header_size() != kArrayHeaderBytes) {
    return FacadeResult::kArrayHeader;
  }
  g_exports = exports;
  g_code_begin = code_begin;
  g_code_end = code_end;
  MonoEmbeddingApi& api = out->api;
  api.get_root_domain = &ShimRootDomain;
  api.thread_attach = &ShimThreadAttach;
  api.thread_detach = &ShimThreadDetach;
  api.assembly_foreach = &ShimAssemblyForeach;
  api.assembly_get_image = &ShimAssemblyGetImage;
  api.image_get_name = &ShimImageGetName;
  api.class_from_name = &ShimClassFromName;
  api.class_get_methods = &ShimClassGetMethods;
  api.method_get_name = &ShimMethodGetName;
  api.method_signature = &ShimMethodSignature;
  api.signature_get_param_count = &ShimSignatureParamCount;
  api.signature_get_params = &ShimSignatureGetParams;
  api.signature_get_return_type = &ShimSignatureReturnType;
  api.signature_is_instance = &ShimSignatureIsInstance;
  api.type_get_type = &ShimTypeGetType;
  api.compile_method = &ShimCompileMethod;
  api.string_length = &ShimStringLength;
  api.string_chars = &ShimStringChars;
  ul::MonoLookupApi& lookup = out->lookup;
  lookup.class_get_field_from_name = &ShimFieldFromName;
  lookup.field_get_offset = &ShimFieldOffset;
  lookup.field_get_type = &ShimFieldType;
  lookup.class_from_mono_type = &ShimClassFromType;
  lookup.class_get_element_class = &ShimElementClass;
  lookup.lookup_internal_call = &ShimLookupInternalCall;
  lookup.method_get_flags = &ShimMethodFlags;
  lookup.class_get_type = &ShimClassGetType;
  lookup.type_get_object = &ShimTypeGetObject;
  lookup.gchandle_new = &ShimGcHandleNew;
  lookup.type_is_byref = &ShimTypeIsByref;
  lookup.array_length = &ShimArrayLength;
  lookup.array_addr_with_size = &ShimArrayAddr;
  // Both or neither: an injected object binding then fails closed
  // (IcallFailure::kGcHandleApi) instead of reading a half API.
  if (report.gchandle_exports) {
    lookup.gchandle_get_target = &ShimGcHandleGetTarget;
    lookup.gchandle_free = &ShimGcHandleFree;
  }
  out->sizes.class_value_size = exports.class_value_size;
  out->classes.class_get_parent = exports.class_get_parent;
  out->classes.object_get_class = exports.object_get_class;
  return FacadeResult::kReady;
}

// ── canvas-text lanes of the IL2CPP text path ──────────────────────────────

// One canvas-text lane: the lookup candidate bit (kUmTmpLane* /
// kUmLaneUiTextSetText in unity_mono_lookup.inc) and the hook identity the
// IL2CPP text path publishes it under (RecordUnityTmpText keys a lane by the
// component pointer + these two strings).  The detours and the lookup's
// "is the selected thread this object's own lane" test read this one table.
struct CanvasLaneSpec {
  uint8_t bit;
  const char* hook_name;
  const wchar_t* hook_code;
  // Scene-stable lane: published with identity 0 instead of the component
  // pointer (RecordUnityTextChars `stable_across_components`), so every
  // component of this setter shares one lane across scene reloads.
  bool stable = false;
};

inline constexpr CanvasLaneSpec kLaneTmpSetText = {
    1u, "Unity TMP_Text", L"TMPro.TMP_Text.set_text"};
inline constexpr CanvasLaneSpec kLaneTmpSetTextBool = {
    2u, "Unity TMP_Text", L"TMPro.TMP_Text.SetText(string,bool)"};
inline constexpr CanvasLaneSpec kLaneUiTextSetText = {
    4u, "Unity UI.Text", L"UnityEngine.UI.Text.set_text"};
inline constexpr CanvasLaneSpec kLaneTmpSetTextSingle = {
    8u, "Unity TMP_Text", L"TMPro.TMP_Text.SetText(string)"};
// Naninovel's dialogue printer (`Naninovel.UI.RevealableText.set_Text`): a
// scene-stable lane (Naninovel recreates the component on scene switches,
// BUG-1646). Its component is a UI.Text or a TextMeshProUGUI subclass
// depending on the Naninovel version, so the lookup decides the canvas kind
// from the object's class (kUmLaneClassDecided in unity_mono_lookup.inc).
inline constexpr CanvasLaneSpec kLaneNaninovelSetText = {
    16u, "Naninovel RevealableText", L"Naninovel.UI.RevealableText.set_Text",
    true};
inline constexpr CanvasLaneSpec kCanvasLanes[] = {
    kLaneTmpSetText, kLaneTmpSetTextBool, kLaneUiTextSetText,
    kLaneTmpSetTextSingle, kLaneNaninovelSetText};

inline bool CanvasLaneSelected(uint64_t object, uint8_t lane_hooks,
                               uint64_t selected) {
  if (selected == 0u || object == 0u) return false;
  for (const CanvasLaneSpec& lane : kCanvasLanes) {
    if ((lane_hooks & lane.bit) == 0u) continue;
    const uint64_t identity = lane.stable ? 0u : object;
    if (NativeTextThreadIdFrom(identity, lane.hook_code, lane.hook_name) ==
        selected) {
      return true;
    }
  }
  return false;
}

// TMP 3.2+ `SetText(string)` is its own body; TMP 1.x forwards it to
// `SetText(string, true)`.  It is hooked only next to the complete
// set_text / SetText(string,bool) pair (the same rule as the Mono text plan).
// Nesting: the outer SetText(string) publishes only when no inner
// SetText(string,bool) detour ran during the call, so a TMP 1.x line keeps
// publishing on its existing SetText(string,bool) lane (no lane identity of
// an existing IL2CPP game changes) and a TMP 3.2 line gets its own lane.
inline bool ShouldHookTmpSetTextSingle(bool pair_hooked,
                                       const void* single_method) {
  return pair_hooked && single_method != nullptr;
}

struct TmpSingleNesting {
  int depth = 0;
  bool inner_ran = false;
};

// Outer detour: Enter before calling the original, Leave after; Leave says
// whether the outer call must publish.
inline void EnterTmpSingle(TmpSingleNesting* n, bool* saved_inner) {
  *saved_inner = n->inner_ran;
  n->inner_ran = false;
  ++n->depth;
}
inline bool LeaveTmpSingle(TmpSingleNesting* n, bool saved_inner) {
  --n->depth;
  const bool publish = !n->inner_ran;
  n->inner_ran = saved_inner;
  return publish;
}
// Inner SetText(string,bool) detour: marks the enclosing outer call.
inline void NoteTmpPairInsideSingle(TmpSingleNesting* n) {
  if (n->depth > 0) n->inner_ran = true;
}

}  // namespace fushi_voice_hook::unity_il2cpp
