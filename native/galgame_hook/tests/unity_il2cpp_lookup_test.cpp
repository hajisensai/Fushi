// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

// Unity IL2CPP 游戏内查词访问层的离线单测（不需要真 GameAssembly.dll）：一张形状与
// il2cpp-api-functions.h 一致的假 il2cpp_* 导出表（MethodInfo 首字段即 methodPointer、
// il2cpp_resolve_icall 按 "Ns.Class::Method" 注册表解析、值类型字段偏移含两指针对象头），
// 经 unity_il2cpp_api.h 的 shim 喂给与 Mono 共用的解析器：
//   * 导出装载：缺哪个就按名字报（有界截断），可选的数组头尺寸不计入；
//   * 门面拒绝：导出不全 / GameAssembly 映像范围未知 / 数组头尺寸不符；
//   * 框架 3（TMP）与框架 4（UI.Text）站点经门面解析出与 Mono 同一套偏移；
//     SendWillRenderCanvases 的 AOT 入口只认 GameAssembly 映像内的 methodPointer；
//   * 失败即拒：icall 未注册、同名 internal call 重载（短名分不清）、
//     internal-call 的 SendWillRenderCanvases、by-ref 不符；
//   * 签名 / 数组 shim；IL2CPP 文本道身份（与 Mono 的 `Mono:` 道不同）；
//   * TMP SetText(string) 只在 set_text/SetText(string,bool) 成对时挂，嵌套时外层不重复发布；
//   * 磁盘布局：GameAssembly.dll + `<stem>_Data\il2cpp_data\` 目录。
#include <windows.h>

#include <array>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "adapters/unity_il2cpp_api.h"

using namespace fushi_voice_hook;
namespace ul = fushi_voice_hook::unity_mono_lookup;
namespace ui = fushi_voice_hook::unity_il2cpp;

namespace {

struct FakeClass;

struct FakeType {
  int kind = 0;
  bool byref = false;
  FakeClass* klass = nullptr;
};

struct FakeField {
  std::string name;
  FakeType* type;
  size_t offset;
};

// MethodInfo: `methodPointer` is the first field in every IL2CPP generation.
struct FakeMethod {
  uintptr_t method_pointer = 0u;
  std::string name;
  bool instance = false;
  FakeType* ret = nullptr;
  std::vector<FakeType*> params;
  uint32_t iflags = 0u;
  FakeClass* klass = nullptr;
  int icall_tag = 0;  // the "UnityPlayer" C entry of a registered binding
};

struct FakeClass {
  std::string ns;
  std::string name;
  std::vector<FakeMethod> methods;
  std::vector<FakeField> fields;
  FakeClass* element = nullptr;
  int32_t value_size = 0;
  FakeClass* parent = nullptr;
};

struct FakeImage {
  std::string name;
  std::vector<FakeClass*> classes;
};

std::vector<FakeImage>* g_images = nullptr;
std::vector<const void*> g_assemblies;
std::map<std::string, void*> g_icalls;  // il2cpp_resolve_icall registry
uint32_t g_header_size = ui::kArrayHeaderBytes;
std::array<uint8_t, 256> g_code{};  // "GameAssembly.dll" text

FakeType T(int kind, bool byref = false, FakeClass* klass = nullptr) {
  FakeType t;
  t.kind = kind;
  t.byref = byref;
  t.klass = klass;
  return t;
}

void* FDomainGet() { return reinterpret_cast<void*>(0xD0); }
const void** FDomainAssemblies(const void*, size_t* size) {
  g_assemblies.clear();
  for (FakeImage& image : *g_images) g_assemblies.push_back(&image);
  *size = g_assemblies.size();
  return g_assemblies.data();
}
int g_attached = 0;
void* FThreadCurrent() { return nullptr; }
void* FThreadAttach(void*) {
  ++g_attached;
  return reinterpret_cast<void*>(0x7);
}
void FThreadDetach(void*) { --g_attached; }
const void* FAssemblyImage(const void* assembly) { return assembly; }
const char* FImageName(const void* image) {
  return static_cast<const FakeImage*>(image)->name.c_str();
}
void* FClassFromName(const void* image, const char* ns, const char* name) {
  for (FakeClass* klass : static_cast<const FakeImage*>(image)->classes) {
    if (klass->ns == ns && klass->name == name) return klass;
  }
  return nullptr;
}
const void* FClassGetMethods(void* klass, void** iter) {
  auto* c = static_cast<FakeClass*>(klass);
  const size_t next = reinterpret_cast<size_t>(*iter);
  if (next >= c->methods.size()) return nullptr;
  *iter = reinterpret_cast<void*>(next + 1);
  return &c->methods[next];
}
const FakeMethod* M(const void* m) { return static_cast<const FakeMethod*>(m); }
const char* FMethodName(const void* m) { return M(m)->name.c_str(); }
uint32_t FParamCount(const void* m) {
  return static_cast<uint32_t>(M(m)->params.size());
}
const void* FParam(const void* m, uint32_t index) {
  return index < M(m)->params.size() ? M(m)->params[index] : nullptr;
}
const void* FReturnType(const void* m) { return M(m)->ret; }
bool FIsInstance(const void* m) { return M(m)->instance; }
uint32_t FMethodFlags(const void* m, uint32_t* iflags) {
  if (iflags != nullptr) *iflags = M(m)->iflags;
  return 0u;
}
void* FMethodClass(const void* m) { return M(m)->klass; }
int FTypeGetType(const void* t) { return static_cast<const FakeType*>(t)->kind; }
bool FTypeIsByref(const void* t) { return static_cast<const FakeType*>(t)->byref; }
void* FClassFromType(const void* t) {
  return static_cast<const FakeType*>(t)->klass;
}
void* FElementClass(void* klass) { return static_cast<FakeClass*>(klass)->element; }
void* FClassParent(void* klass) { return static_cast<FakeClass*>(klass)->parent; }
const char* FClassName(void* klass) {
  return static_cast<FakeClass*>(klass)->name.c_str();
}
const char* FClassNamespace(void* klass) {
  return static_cast<FakeClass*>(klass)->ns.c_str();
}
int32_t FValueSize(void* klass, uint32_t* align) {
  if (align != nullptr) *align = 4u;
  return static_cast<FakeClass*>(klass)->value_size;
}
// il2cpp_class_get_field_from_name walks the parents.
void* FFieldFromName(void* klass, const char* name) {
  for (auto* c = static_cast<FakeClass*>(klass); c != nullptr; c = c->parent) {
    for (FakeField& f : c->fields) {
      if (f.name == name) return &f;
    }
  }
  return nullptr;
}
size_t FFieldOffset(void* f) { return static_cast<FakeField*>(f)->offset; }
const void* FFieldType(void* f) { return static_cast<FakeField*>(f)->type; }
struct FakeObject {
  FakeClass* klass;
};
void* FObjectClass(void* object) { return static_cast<FakeObject*>(object)->klass; }
void* FResolveIcall(const char* name) {
  const auto found = g_icalls.find(name);
  return found == g_icalls.end() ? nullptr : found->second;
}
struct FakeArray {
  void* klass;
  void* monitor;
  void* bounds;
  uintptr_t max_length;
  uint8_t data[64];
};
uint32_t FArrayLength(void* array) {
  return static_cast<uint32_t>(static_cast<FakeArray*>(array)->max_length);
}
int32_t FStringLength(void*) { return 0; }
const wchar_t* FStringChars(void*) { return nullptr; }
uint32_t FHeaderSize() { return g_header_size; }

std::map<std::string, void*> FakeExportTable() {
  return {
      {"il2cpp_domain_get", reinterpret_cast<void*>(&FDomainGet)},
      {"il2cpp_domain_get_assemblies",
       reinterpret_cast<void*>(&FDomainAssemblies)},
      {"il2cpp_thread_current", reinterpret_cast<void*>(&FThreadCurrent)},
      {"il2cpp_thread_attach", reinterpret_cast<void*>(&FThreadAttach)},
      {"il2cpp_thread_detach", reinterpret_cast<void*>(&FThreadDetach)},
      {"il2cpp_assembly_get_image", reinterpret_cast<void*>(&FAssemblyImage)},
      {"il2cpp_image_get_name", reinterpret_cast<void*>(&FImageName)},
      {"il2cpp_class_from_name", reinterpret_cast<void*>(&FClassFromName)},
      {"il2cpp_class_get_methods", reinterpret_cast<void*>(&FClassGetMethods)},
      {"il2cpp_method_get_name", reinterpret_cast<void*>(&FMethodName)},
      {"il2cpp_method_get_param_count", reinterpret_cast<void*>(&FParamCount)},
      {"il2cpp_method_get_param", reinterpret_cast<void*>(&FParam)},
      {"il2cpp_method_get_return_type", reinterpret_cast<void*>(&FReturnType)},
      {"il2cpp_method_is_instance", reinterpret_cast<void*>(&FIsInstance)},
      {"il2cpp_method_get_flags", reinterpret_cast<void*>(&FMethodFlags)},
      {"il2cpp_method_get_class", reinterpret_cast<void*>(&FMethodClass)},
      {"il2cpp_type_get_type", reinterpret_cast<void*>(&FTypeGetType)},
      {"il2cpp_type_is_byref", reinterpret_cast<void*>(&FTypeIsByref)},
      {"il2cpp_class_from_type", reinterpret_cast<void*>(&FClassFromType)},
      {"il2cpp_class_get_element_class",
       reinterpret_cast<void*>(&FElementClass)},
      {"il2cpp_class_get_parent", reinterpret_cast<void*>(&FClassParent)},
      {"il2cpp_class_get_name", reinterpret_cast<void*>(&FClassName)},
      {"il2cpp_class_get_namespace", reinterpret_cast<void*>(&FClassNamespace)},
      {"il2cpp_class_value_size", reinterpret_cast<void*>(&FValueSize)},
      {"il2cpp_class_get_field_from_name",
       reinterpret_cast<void*>(&FFieldFromName)},
      {"il2cpp_field_get_offset", reinterpret_cast<void*>(&FFieldOffset)},
      {"il2cpp_field_get_type", reinterpret_cast<void*>(&FFieldType)},
      {"il2cpp_object_get_class", reinterpret_cast<void*>(&FObjectClass)},
      {"il2cpp_resolve_icall", reinterpret_cast<void*>(&FResolveIcall)},
      {"il2cpp_array_length", reinterpret_cast<void*>(&FArrayLength)},
      {"il2cpp_string_length", reinterpret_cast<void*>(&FStringLength)},
      {"il2cpp_string_chars", reinterpret_cast<void*>(&FStringChars)},
      {"il2cpp_array_object_header_size",
       reinterpret_cast<void*>(&FHeaderSize)},
  };
}

ui::ExportReport Load(const std::map<std::string, void*>& table,
                      ui::Il2CppExports* exports) {
  return ui::LoadIl2CppExports(
      [&table](const char* name) -> void* {
        const auto found = table.find(name);
        return found == table.end() ? nullptr : found->second;
      },
      exports);
}

uintptr_t CodeBegin() { return reinterpret_cast<uintptr_t>(g_code.data()); }
uintptr_t CodeEnd() { return CodeBegin() + g_code.size(); }

// Loads the full fake table and installs the facade (asserts success).
ui::Facade InstallFake() {
  ui::Il2CppExports exports;
  const ui::ExportReport report = Load(FakeExportTable(), &exports);
  assert(report.Complete());
  ui::Facade facade;
  assert(ui::InstallFacade(exports, report, CodeBegin(), CodeEnd(), &facade) ==
         ui::FacadeResult::kReady);
  return facade;
}

// ── an IL2CPP-shaped Unity canvas world (TMP + UGUI Text) ──────────────────

constexpr uint32_t kPtr = static_cast<uint32_t>(sizeof(void*));
// Offsets as il2cpp reports them: instance and value-type fields after the
// two-pointer Il2CppObject header.
constexpr uint32_t kHdr = 2 * kPtr;
constexpr uint32_t kItems = 2 * kPtr;
constexpr uint32_t kSize = 3 * kPtr;

struct CanvasWorld {
  FakeType tvoid = T(kMonoTypeVoid), tbool = T(kMonoTypeBoolean),
           ti4 = T(ul::kMonoTypeI4), tr4 = T(kMonoTypeSingle),
           tchar = T(ul::kMonoTypeChar), tu1 = T(ul::kMonoTypeU1),
           tstring = T(kMonoTypeString), tclass = T(kMonoTypeClass),
           tintptr = T(ul::kMonoTypeI), tvalue = T(ul::kMonoTypeValueType),
           tvalue_ref = T(ul::kMonoTypeValueType, true),
           tobject = T(ul::kMonoTypeObject);
  // UnityEngine core / UI modules.
  FakeClass unity_object{"UnityEngine", "Object"};
  FakeClass component{"UnityEngine", "Component"};
  FakeClass behaviour{"UnityEngine", "Behaviour"};
  FakeClass transform{"UnityEngine", "Transform"};
  FakeClass camera{"UnityEngine", "Camera"};
  FakeClass screen{"UnityEngine", "Screen"};
  FakeClass color{"UnityEngine", "Color"};
  FakeClass color32{"UnityEngine", "Color32"};
  FakeClass vector3{"UnityEngine", "Vector3"};
  FakeClass canvas{"UnityEngine", "Canvas"};
  FakeClass renderer{"UnityEngine", "CanvasRenderer"};
  FakeClass generator{"UnityEngine", "TextGenerator"};
  FakeClass font{"UnityEngine", "Font"};
  FakeClass ui_char_info{"UnityEngine", "UICharInfo"};
  FakeClass ui_line_info{"UnityEngine", "UILineInfo"};
  FakeClass char_list{"System.Collections.Generic", "List`1"};
  FakeClass line_list{"System.Collections.Generic", "List`1"};
  FakeClass ui_char_array{"", "UICharInfo[]"};
  FakeClass ui_line_array{"", "UILineInfo[]"};
  FakeClass graphic{"UnityEngine.UI", "Graphic"};
  FakeClass maskable{"UnityEngine.UI", "MaskableGraphic"};
  FakeClass text{"UnityEngine.UI", "Text"};
  FakeClass font_data{"UnityEngine.UI", "FontData"};
  // TextMeshPro.
  FakeClass tmp_text{"TMPro", "TMP_Text"};
  FakeClass ugui{"TMPro", "TextMeshProUGUI"};
  FakeClass tmp_3d{"TMPro", "TextMeshPro"};
  FakeClass text_info{"TMPro", "TMP_TextInfo"};
  FakeClass tmp_char_info{"TMPro", "TMP_CharacterInfo"};
  FakeClass tmp_char_array{"", "TMP_CharacterInfo[]"};
  FakeType t_text_info, t_color, t_color32, t_vector3, t_canvas, t_renderer,
      t_tmp_char_items, t_generator, t_font_data, t_font, t_char_list,
      t_line_list, t_char_items, t_line_items, t_vector2;
  std::vector<FakeImage> images;

  static FakeMethod Method(const char* name, bool instance, FakeType* ret,
                           std::vector<FakeType*> params,
                           uint32_t iflags = 0u) {
    FakeMethod m;
    m.name = name;
    m.instance = instance;
    m.ret = ret;
    m.params = std::move(params);
    m.iflags = iflags;
    return m;
  }
  static FakeMethod Icall(const char* name, bool instance, FakeType* ret,
                          std::vector<FakeType*> params) {
    return Method(name, instance, ret, std::move(params),
                  ul::kMethodImplInternalCall);
  }

  CanvasWorld() {
    t_text_info = T(kMonoTypeClass, false, &text_info);
    t_color = T(ul::kMonoTypeValueType, false, &color);
    t_color32 = T(ul::kMonoTypeValueType, false, &color32);
    t_vector3 = T(ul::kMonoTypeValueType, false, &vector3);
    t_vector2 = T(ul::kMonoTypeValueType);
    t_canvas = T(kMonoTypeClass, false, &canvas);
    t_renderer = T(kMonoTypeClass, false, &renderer);
    t_generator = T(kMonoTypeClass, false, &generator);
    t_font_data = T(kMonoTypeClass, false, &font_data);
    t_font = T(kMonoTypeClass, false, &font);
    t_char_list = T(ul::kMonoTypeGenericInst, false, &char_list);
    t_line_list = T(ul::kMonoTypeGenericInst, false, &line_list);
    tmp_char_array.element = &tmp_char_info;
    ui_char_array.element = &ui_char_info;
    ui_line_array.element = &ui_line_info;
    t_tmp_char_items = T(ul::kMonoTypeSzArray, false, &tmp_char_array);
    t_char_items = T(ul::kMonoTypeSzArray, false, &ui_char_array);
    t_line_items = T(ul::kMonoTypeSzArray, false, &ui_line_array);

    component.parent = &unity_object;
    behaviour.parent = &component;
    graphic.parent = &behaviour;
    maskable.parent = &graphic;
    text.parent = &maskable;
    tmp_text.parent = &maskable;
    ugui.parent = &tmp_text;
    tmp_3d.parent = &tmp_text;

    unity_object.fields = {{"m_CachedPtr", &tintptr, 2 * kPtr}};
    graphic.fields = {{"m_CanvasRenderer", &t_renderer, 5 * kPtr},
                      {"m_Canvas", &t_canvas, 6 * kPtr},
                      {"m_Color", &t_color, 100}};
    text.fields = {{"m_FontData", &t_font_data, 24 * kPtr},
                   {"m_Text", &tstring, 25 * kPtr},
                   {"m_TextCache", &t_generator, 26 * kPtr}};
    font_data.fields = {{"m_Font", &t_font, kHdr}};
    color.fields = {{"r", &tr4, kHdr}, {"g", &tr4, kHdr + 4},
                    {"b", &tr4, kHdr + 8}, {"a", &tr4, kHdr + 12}};
    color.value_size = 16;
    color32.fields = {{"rgba", &ti4, kHdr}, {"r", &tu1, kHdr},
                      {"g", &tu1, kHdr + 1}, {"b", &tu1, kHdr + 2},
                      {"a", &tu1, kHdr + 3}};
    color32.value_size = 4;
    vector3.fields = {{"x", &tr4, kHdr}, {"y", &tr4, kHdr + 4},
                      {"z", &tr4, kHdr + 8}};
    vector3.value_size = 12;
    generator.fields = {{"m_LastString", &tstring, 3 * kPtr},
                        {"m_Characters", &t_char_list, 18 * kPtr},
                        {"m_Lines", &t_line_list, 19 * kPtr}};
    char_list.fields = {{"_items", &t_char_items, kItems},
                        {"_size", &ti4, kSize}};
    line_list.fields = {{"_items", &t_line_items, kItems},
                        {"_size", &ti4, kSize}};
    ui_char_info.fields = {{"cursorPos", &t_vector2, kHdr},
                           {"charWidth", &tr4, kHdr + 8}};
    ui_char_info.value_size = 12;
    ui_line_info.fields = {{"startCharIdx", &ti4, kHdr},
                           {"height", &ti4, kHdr + 4},
                           {"topY", &tr4, kHdr + 8},
                           {"leading", &tr4, kHdr + 12}};
    ui_line_info.value_size = 16;
    tmp_text.fields = {{"m_text", &tstring, 40 * kPtr},
                       {"m_fontColor", &t_color, 300},
                       {"m_firstVisibleCharacter", &ti4, 400},
                       {"m_maxVisibleCharacters", &ti4, 404},
                       {"m_textInfo", &t_text_info, 60 * kPtr}};
    ugui.fields = {{"m_canvasRenderer", &t_renderer, 90 * kPtr},
                   {"m_canvas", &t_canvas, 91 * kPtr}};
    text_info.fields = {{"characterCount", &ti4, 3 * kPtr},
                        {"characterInfo", &t_tmp_char_items, 8 * kPtr}};
    // TMP 3.2 shape: elementType first, character at +4.
    tmp_char_info.fields = {{"elementType", &ti4, kHdr},
                            {"character", &tchar, kHdr + 4},
                            {"bottomLeft", &t_vector3, kHdr + 136},
                            {"topRight", &t_vector3, kHdr + 148},
                            {"color", &t_color32, kHdr + 188},
                            {"isVisible", &tbool, kHdr + 228}};
    tmp_char_info.value_size = 232;

    component.methods = {Icall("get_gameObject", true, &tclass, {}),
                         Icall("get_transform", true, &tclass, {})};
    behaviour.methods = {Icall("get_enabled", true, &tbool, {}),
                         Icall("get_isActiveAndEnabled", true, &tbool, {})};
    transform.methods = {Icall("get_localToWorldMatrix_Injected", true, &tvoid,
                               {&tvalue_ref})};
    canvas.methods = {
        Method("SendPreWillRenderCanvases", false, &tvoid, {}),
        Method("SendWillRenderCanvases", false, &tvoid, {}),
        Icall("get_rootCanvas", true, &tclass, {}),
        Icall("get_renderMode", true, &tvalue, {}),
        Icall("get_scaleFactor", true, &tr4, {}),
        Icall("get_worldCamera", true, &tclass, {})};
    renderer.methods = {Icall("GetInheritedAlpha", true, &tr4, {}),
                        Icall("get_cull", true, &tbool, {})};
    font.methods = {Icall("get_dynamic", true, &tbool, {})};
    generator.methods = {
        Icall("GetCharactersInternal", true, &tvoid, {&tobject}),
        Icall("GetLinesInternal", true, &tvoid, {&tobject})};
    camera.methods = {Icall("WorldToScreenPoint_Injected", true, &tvoid,
                            {&tvalue_ref, &tvalue, &tvalue_ref}),
                      Icall("get_targetTexture", true, &tclass, {})};
    screen.methods = {Icall("get_width", false, &ti4, {}),
                      Icall("get_height", false, &ti4, {})};
    // IL2CPP image names carry the .dll extension.
    images = {{"UnityEngine.CoreModule.dll",
               {&unity_object, &component, &behaviour, &transform, &camera,
                &screen, &color, &color32, &vector3}},
              {"UnityEngine.UIModule.dll", {&canvas, &renderer}},
              {"UnityEngine.TextRenderingModule.dll",
               {&generator, &font, &ui_char_info, &ui_line_info}},
              {"UnityEngine.UI.dll", {&graphic, &maskable, &text, &font_data}},
              {"Unity.TextMeshPro.dll",
               {&tmp_text, &ugui, &tmp_3d, &text_info, &tmp_char_info}},
              {"Assembly-CSharp.dll", {}}};
    Bind();
  }

  // Back-pointers, AOT entries inside the fake GameAssembly text and the
  // icall registry ("Ns.Class::Method", as Unity registers its bindings).
  // Call again after editing methods.
  void Bind() {
    g_images = &images;
    g_icalls.clear();
    size_t next = 0u;
    for (FakeImage& image : images) {
      for (FakeClass* klass : image.classes) {
        for (FakeMethod& method : klass->methods) {
          method.klass = klass;
          method.method_pointer = CodeBegin() + (next++ % g_code.size());
          if ((method.iflags & ul::kMethodImplInternalCall) != 0u) {
            const std::string name =
                (klass->ns.empty() ? "" : klass->ns + ".") + klass->name +
                "::" + method.name;
            g_icalls[name] = &method.icall_tag;
          }
        }
      }
    }
  }
};

// ── exports ────────────────────────────────────────────────────────────────

void TestExportTable() {
  ui::Il2CppExports exports;
  ui::ExportSlot slots[ui::kIl2CppExportSlotCount] = {};
  assert(ui::Il2CppExportSlots(&exports, slots, ui::kIl2CppExportSlotCount) ==
         ui::kIl2CppExportSlotCount);
  // Every slot is a distinct member, every name an il2cpp_ export.
  for (size_t i = 0; i < ui::kIl2CppExportSlotCount; ++i) {
    assert(std::strncmp(slots[i].name, "il2cpp_", 7) == 0);
    for (size_t j = 0; j < i; ++j) assert(slots[i].slot != slots[j].slot);
  }
  const ui::ExportReport full = Load(FakeExportTable(), &exports);
  assert(full.Complete() && full.required == 32u && full.found == 32u);
  assert(full.header_size_export && full.missing[0] == 0);
  // The optional header-size export never counts as missing.
  auto table = FakeExportTable();
  table.erase("il2cpp_array_object_header_size");
  const ui::ExportReport no_header = Load(table, &exports);
  assert(no_header.Complete() && !no_header.header_size_export);
  assert(exports.array_object_header_size == nullptr);
  // A stripped / renamed export is reported by name.
  table = FakeExportTable();
  table.erase("il2cpp_resolve_icall");
  table.erase("il2cpp_type_is_byref");
  const ui::ExportReport missing = Load(table, &exports);
  assert(!missing.Complete() && missing.found == 30u);
  assert(std::strcmp(missing.missing, "type_is_byref,resolve_icall") == 0);
  // Every export missing (an obfuscated GameAssembly): bounded, truncated.
  const ui::ExportReport none = Load({}, &exports);
  assert(!none.Complete() && none.found == 0u);
  const size_t length = std::strlen(none.missing);
  assert(length > 0u && length < ui::kMissingExportsChars);
  assert(std::strcmp(none.missing + length - 3, "...") == 0);
  assert(std::strncmp(none.missing, "domain_get,domain_get_assemblies,", 33) ==
         0);
}

void TestFacadeRefusals() {
  ui::Il2CppExports exports;
  ui::Facade facade;
  auto table = FakeExportTable();
  table.erase("il2cpp_class_value_size");
  ui::ExportReport report = Load(table, &exports);
  assert(ui::InstallFacade(exports, report, CodeBegin(), CodeEnd(), &facade) ==
         ui::FacadeResult::kExportsMissing);
  assert(facade.api.get_root_domain == nullptr &&
         facade.sizes.class_value_size == nullptr);
  report = Load(FakeExportTable(), &exports);
  assert(ui::InstallFacade(exports, report, 0u, 0u, &facade) ==
         ui::FacadeResult::kNoCodeRange);
  g_header_size = ui::kArrayHeaderBytes + 8u;  // not the Il2CppArray we read
  assert(ui::InstallFacade(exports, report, CodeBegin(), CodeEnd(), &facade) ==
         ui::FacadeResult::kArrayHeader);
  assert(!facade.api.CompleteForResolution());
  g_header_size = ui::kArrayHeaderBytes;
  assert(ui::InstallFacade(exports, report, CodeBegin(), CodeEnd(), &facade) ==
         ui::FacadeResult::kReady);
  assert(facade.api.CompleteForResolution() && facade.lookup.Complete() &&
         facade.classes.Complete() && facade.sizes.class_value_size != nullptr);
}

// ── shims ──────────────────────────────────────────────────────────────────

void TestSignatureAndArrayShims() {
  CanvasWorld w;
  const ui::Facade f = InstallFake();
  FakeMethod& to_screen = w.camera.methods[0];
  void* sig = f.api.method_signature(&to_screen);
  assert(f.api.signature_is_instance(sig) == 1);
  assert(f.api.signature_get_param_count(sig) == 3u);
  void* iter = nullptr;
  assert(f.api.signature_get_params(sig, &iter) == &w.tvalue_ref);
  assert(f.api.signature_get_params(sig, &iter) == &w.tvalue);
  assert(f.api.signature_get_params(sig, &iter) == &w.tvalue_ref);
  assert(f.api.signature_get_params(sig, &iter) == nullptr);
  assert(f.lookup.type_is_byref(&w.tvalue_ref) == 1 &&
         f.lookup.type_is_byref(&w.tvalue) == 0);
  assert(f.api.signature_get_return_type(sig) == &w.tvoid);
  // The resolvers' assembly walk sees every image.
  MonoAssemblyList list;
  f.api.assembly_foreach(&CollectMonoAssembly, &list);
  assert(list.count == w.images.size());
  // Il2CppArray: elements after four pointers on both architectures.
  FakeArray array{};
  array.max_length = 3u;
  assert(f.lookup.array_length(&array) == 3u);
  assert(f.lookup.array_addr_with_size(&array, 12, 0u) ==
         reinterpret_cast<char*>(&array.data[0]));
  assert(f.lookup.array_addr_with_size(&array, 12, 2u) ==
         reinterpret_cast<char*>(&array.data[24]));
  assert(f.lookup.array_addr_with_size(&array, 0, 1u) == nullptr);
  // Framework 1's System.Type / GC handle entries answer nothing.
  assert(f.lookup.class_get_type(&w.text) == nullptr &&
         f.lookup.type_get_object(nullptr, nullptr) == nullptr &&
         f.lookup.gchandle_new(&w.text, 0) == 0u);
}

void TestAotEntryAndIcall() {
  CanvasWorld w;
  const ui::Facade f = InstallFake();
  FakeMethod& will_render = w.canvas.methods[1];
  // The AOT entry is MethodInfo.methodPointer inside GameAssembly's image.
  assert(f.api.compile_method(&will_render) ==
         reinterpret_cast<void*>(will_render.method_pointer));
  will_render.method_pointer = 0u;  // a stripped body
  assert(f.api.compile_method(&will_render) == nullptr);
  will_render.method_pointer = CodeEnd();  // outside the image
  assert(f.api.compile_method(&will_render) == nullptr);
  // Internal calls resolve by "Ns.Class::Method" through il2cpp_resolve_icall.
  FakeMethod& width = w.screen.methods[0];
  assert(f.lookup.lookup_internal_call(&width) == &width.icall_tag);
  g_icalls.erase("UnityEngine.Screen::get_width");  // not registered
  assert(f.lookup.lookup_internal_call(&width) == nullptr);
}

// ── frameworks 3 / 4 through the facade ────────────────────────────────────

void TestTmpSitesThroughFacade() {
  CanvasWorld w;
  const ui::Facade f = InstallFake();
  ul::TmpSites sites;
  const auto result =
      ul::ResolveTmpSites(f.api, f.lookup, f.sizes, f.classes, &sites);
  assert(result.result == ul::TmpSiteResult::kResolved);
  assert(sites.will_render == &w.canvas.methods[1]);
  assert(f.api.compile_method(sites.will_render) ==
         reinterpret_cast<void*>(w.canvas.methods[1].method_pointer));
  assert(sites.ugui_class == &w.ugui);
  assert(sites.text_string_offset == 40 * kPtr &&
         sites.text_info_offset == 60 * kPtr);
  assert(sites.font_alpha_offset == 312);
  assert(sites.first_visible_offset == 400 && sites.max_visible_offset == 404);
  assert(sites.canvas_offset == 91 * kPtr && sites.renderer_offset == 90 * kPtr);
  assert(sites.char_stride == 232 && sites.char_character_offset == 4 &&
         sites.char_bottom_left_offset == 136 &&
         sites.char_top_right_offset == 148 &&
         sites.char_visible_offset == 228 && sites.char_alpha_offset == 191);
  assert(sites.cached_ptr_offset == 2 * kPtr);
  assert(sites.icalls[static_cast<size_t>(
             ul::TmpIcall::kBehaviourActiveAndEnabled)] ==
         &w.behaviour.methods[1].icall_tag);
  for (void* entry : sites.icalls) assert(entry != nullptr);
  // The candidate class check runs on il2cpp_object_get_class / _parent.
  FakeObject dialogue{&w.ugui};
  FakeObject world_text{&w.tmp_3d};
  assert(ul::ClassDerivesFrom(f.classes, f.classes.object_get_class(&dialogue),
                              sites.ugui_class));
  assert(!ul::ClassDerivesFrom(
      f.classes, f.classes.object_get_class(&world_text), sites.ugui_class));
  assert(g_attached == 0);  // the resolvers never attach on their own
}

void TestUiTextSitesThroughFacade() {
  CanvasWorld w;
  const ui::Facade f = InstallFake();
  ul::FungusSites sites;
  void* will_render = nullptr;
  const auto result =
      ul::ResolveUiTextSites(f.api, f.lookup, f.sizes, &sites, &will_render);
  assert(result.result == ul::UiTextSiteResult::kResolved);
  assert(will_render == &w.canvas.methods[1]);
  assert(sites.text_class == &w.text);
  assert(sites.text_string_offset == 25 * kPtr &&
         sites.text_cache_offset == 26 * kPtr &&
         sites.font_data_offset == 24 * kPtr &&
         sites.font_data_font_offset == kHdr);  // object-relative, as Mono
  assert(sites.graphic_canvas_offset == 6 * kPtr &&
         sites.graphic_renderer_offset == 5 * kPtr &&
         sites.graphic_color_alpha_offset == 112);
  assert(sites.generator_last_offset == 3 * kPtr &&
         sites.generator_chars_offset == 18 * kPtr &&
         sites.generator_lines_offset == 19 * kPtr);
  assert(sites.char_list_items_offset == kItems &&
         sites.line_list_size_offset == kSize);
  assert(sites.char_stride == 12 && sites.line_stride == 16 &&
         sites.line_top_offset == 8);
  for (void* entry : sites.icalls) assert(entry != nullptr);
}

void TestFailClosedThroughFacade() {
  {
    CanvasWorld w;  // a binding the player did not register
    const ui::Facade f = InstallFake();
    g_icalls.erase("UnityEngine.CanvasRenderer::GetInheritedAlpha");
    ul::TmpSites sites;
    const auto result =
        ul::ResolveTmpSites(f.api, f.lookup, f.sizes, f.classes, &sites);
    assert(result.result == ul::TmpSiteResult::kIcallMissing);
    assert(result.missing_icall ==
           static_cast<int32_t>(ul::TmpIcall::kCanvasRendererInheritedAlpha));
  }
  {
    CanvasWorld w;  // two internal calls share the short name: refuse
    w.screen.methods.push_back(
        CanvasWorld::Icall("get_width", true, &w.ti4, {&w.tbool}));
    w.Bind();
    const ui::Facade f = InstallFake();
    ul::TmpSites sites;
    const auto result =
        ul::ResolveTmpSites(f.api, f.lookup, f.sizes, f.classes, &sites);
    assert(result.result == ul::TmpSiteResult::kIcallMissing);
    assert(result.missing_icall ==
           static_cast<int32_t>(ul::TmpIcall::kScreenWidth));
  }
  {
    CanvasWorld w;  // an internal-call sampling point has no AOT body
    w.canvas.methods[1].iflags = ul::kMethodImplInternalCall;
    w.Bind();
    const ui::Facade f = InstallFake();
    ul::TmpSites sites;
    assert(ul::ResolveTmpSites(f.api, f.lookup, f.sizes, f.classes, &sites)
               .result == ul::TmpSiteResult::kNoWillRender);
    ul::FungusSites text_sites;
    void* will_render = nullptr;
    assert(ul::ResolveUiTextSites(f.api, f.lookup, f.sizes, &text_sites,
                                  &will_render)
               .result == ul::UiTextSiteResult::kNoWillRender);
  }
  {
    CanvasWorld w;  // `out Matrix4x4` declared by value
    w.transform.methods[0].params = {&w.tvalue};
    w.Bind();
    const ui::Facade f = InstallFake();
    ul::FungusSites sites;
    void* will_render = nullptr;
    const auto result =
        ul::ResolveUiTextSites(f.api, f.lookup, f.sizes, &sites, &will_render);
    assert(result.result == ul::UiTextSiteResult::kLayout &&
           result.layout == ul::FungusSiteResult::kIcallMissing);
    assert(will_render == nullptr);
  }
  {
    CanvasWorld w;  // an obfuscated build renamed the private TMP fields
    w.tmp_text.fields[0].name = "a";
    w.Bind();
    const ui::Facade f = InstallFake();
    ul::TmpSites sites;
    assert(ul::ResolveTmpSites(f.api, f.lookup, f.sizes, f.classes, &sites)
               .result == ul::TmpSiteResult::kTextFieldsMissing);
  }
  {
    CanvasWorld w;  // an incomplete facade resolves nothing
    ui::Facade empty;
    ul::TmpSites sites;
    assert(ul::ResolveTmpSites(empty.api, empty.lookup, empty.sizes,
                               empty.classes, &sites)
               .result == ul::TmpSiteResult::kApiIncomplete);
  }
}

// ── text path ──────────────────────────────────────────────────────────────

void TestCanvasLaneIdentity() {
  const uint64_t object = 0x12345678u;
  const uint64_t tmp_lane = NativeTextThreadIdFrom(
      object, L"TMPro.TMP_Text.set_text", "Unity TMP_Text");
  const uint64_t ui_lane = NativeTextThreadIdFrom(
      object, L"UnityEngine.UI.Text.set_text", "Unity UI.Text");
  const uint64_t single_lane = NativeTextThreadIdFrom(
      object, L"TMPro.TMP_Text.SetText(string)", "Unity TMP_Text");
  assert(ui::CanvasLaneSelected(object, ui::kLaneTmpSetText.bit, tmp_lane));
  assert(ui::CanvasLaneSelected(object, ui::kLaneUiTextSetText.bit, ui_lane));
  assert(ui::CanvasLaneSelected(object, ui::kLaneTmpSetTextSingle.bit,
                                single_lane));
  // Only lanes the object was actually written on; never another object.
  assert(!ui::CanvasLaneSelected(object, ui::kLaneTmpSetTextBool.bit, tmp_lane));
  assert(!ui::CanvasLaneSelected(object + 8u, ui::kLaneTmpSetText.bit,
                                 tmp_lane));
  assert(!ui::CanvasLaneSelected(object, 0xffu, 0u));
  // The Mono path's `Mono:` lane of the same object is a different thread.
  const auto& mono = MonoTextHookSpecFor(MonoTextHookId::kTmpSetText);
  assert(NativeTextThreadIdFrom(object, mono.hook_code, mono.hook_name) !=
         tmp_lane);
  // Lane bits are the shared runtime's candidate bits (1 / 2 / 4 / 8).
  assert(ui::kLaneTmpSetText.bit == 1u && ui::kLaneTmpSetTextBool.bit == 2u &&
         ui::kLaneUiTextSetText.bit == 4u &&
         ui::kLaneTmpSetTextSingle.bit == 8u);
}

void TestTmpSetTextSingle() {
  int marker = 0;
  assert(ui::ShouldHookTmpSetTextSingle(true, &marker));
  assert(!ui::ShouldHookTmpSetTextSingle(false, &marker));
  assert(!ui::ShouldHookTmpSetTextSingle(true, nullptr));
  ui::TmpSingleNesting n;
  bool saved = false;
  // TMP 3.2: SetText(string) is its own body -> the outer call publishes.
  ui::EnterTmpSingle(&n, &saved);
  assert(ui::LeaveTmpSingle(&n, saved) && n.depth == 0);
  // TMP 1.x: it forwards to SetText(string,true) -> that lane published.
  ui::EnterTmpSingle(&n, &saved);
  ui::NoteTmpPairInsideSingle(&n);
  assert(!ui::LeaveTmpSingle(&n, saved) && n.depth == 0 && !n.inner_ran);
  // A pair call outside any SetText(string) marks nothing.
  ui::NoteTmpPairInsideSingle(&n);
  assert(!n.inner_ran);
  // Re-entrant: an inner SetText(string) on another object does not leak
  // its verdict to the outer one.
  bool outer_saved = false, inner_saved = false;
  ui::EnterTmpSingle(&n, &outer_saved);
  ui::EnterTmpSingle(&n, &inner_saved);
  ui::NoteTmpPairInsideSingle(&n);
  assert(!ui::LeaveTmpSingle(&n, inner_saved));
  assert(ui::LeaveTmpSingle(&n, outer_saved) && n.depth == 0);
}

// ── disk layout ────────────────────────────────────────────────────────────

void TestLayout() {
  wchar_t temp[MAX_PATH] = {};
  assert(GetTempPathW(MAX_PATH, temp) > 0);
  wchar_t name[32] = {};
  std::swprintf(name, 32, L"fushi_il2cpp_%lu", GetCurrentProcessId());
  const std::wstring root = std::wstring(temp) + name;
  CreateDirectoryW(root.c_str(), nullptr);
  const std::wstring data = root + L"\\Game_Data";
  const std::wstring il2cpp = data + L"\\il2cpp_data";
  const std::wstring dll = root + L"\\GameAssembly.dll";
  assert(!ui::MatchUnityIl2CppLayout(root, L"Game").Complete());
  HANDLE file = CreateFileW(dll.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  CloseHandle(file);
  ui::LayoutReport report = ui::MatchUnityIl2CppLayout(root, L"Game");
  assert(report.game_assembly && !report.il2cpp_data && !report.Complete());
  CreateDirectoryW(data.c_str(), nullptr);
  // il2cpp_data must be a directory, not a file of that name.
  file = CreateFileW(il2cpp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                     FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  CloseHandle(file);
  assert(!ui::MatchUnityIl2CppLayout(root, L"Game").il2cpp_data);
  DeleteFileW(il2cpp.c_str());
  CreateDirectoryW(il2cpp.c_str(), nullptr);
  assert(ui::MatchUnityIl2CppLayout(root, L"Game").Complete());
  // The data directory follows the executable's own stem.
  assert(!ui::MatchUnityIl2CppLayout(root, L"Other").Complete());
  assert(!ui::MatchUnityIl2CppLayout(L"", L"Game").Complete());
  RemoveDirectoryW(il2cpp.c_str());
  RemoveDirectoryW(data.c_str());
  DeleteFileW(dll.c_str());
  RemoveDirectoryW(root.c_str());
}

}  // namespace

int main() {
  TestExportTable();
  TestFacadeRefusals();
  TestSignatureAndArrayShims();
  TestAotEntryAndIcall();
  TestTmpSitesThroughFacade();
  TestUiTextSitesThroughFacade();
  TestFailClosedThroughFacade();
  TestCanvasLaneIdentity();
  TestTmpSetTextSingle();
  TestLayout();
  std::printf("unity_il2cpp_lookup_test: OK\n");
  return 0;
}
