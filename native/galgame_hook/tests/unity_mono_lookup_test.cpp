// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

// Unity Mono 游戏内查词纯逻辑层的离线单测（不需要真 mono.dll / UnityPlayer.dll）：
//   * 站点解析：Message.FixedUpdate、messageSprite 必须是 List<List<GameObject>>
//     （两层 List`1 同一布局、元素类就是 UnityEngine.GameObject）、LastMes 是 string、
//     UnityEngine.Object.m_CachedPtr、13 个引擎内部调用按「名字 + 实例/静态 + 返回 +
//     参数类型 + by-ref + internal-call 标志」精确匹配；任何一项缺失/不唯一都拒；
//   * 可见性：激活、renderer 开、场景 = 活动场景、层在 culling mask 里；
//   * LastMes 与逐行字形数必须逐行一致才映射（负向：行数/字数/结尾不符）；
//   * Unity 屏幕（左下原点）-> 物理客户区投影、客户区像素 -> 屏幕点；
//   * 命中：相邻字格恰好相接（半开区间）、字距紧导致重叠时取水平中心更近者、平局拒；
//   * 消息级点击认领（按下与配对的抬起一起吞）；
//   * 文本道角色键：同名稳定、异名不同、空名为 0。
//   * 框架 3（裸 TextMeshProUGUI）：站点解析（每条拒绝分支）、类层级判定、TMP 字符
//     显示判定（isVisible / 打字机可见区间 / 顶点 alpha）、同文多对象的确定性选择、
//     字符四边形 本地 -> 世界 -> Unity 屏幕 -> 物理客户区 的投影与命中。
//   * 引擎绑定两种形态：经典 instance extern 与 Unity 6 `<method>_Injected`
//     static extern（首参 IntPtr self、对象返回为 GC handle）；两种都在 / 一种
//     重复都拒；injected 的 self 字段 / GC handle 读取缺失都拒；假 null 释放
//     handle；剥离掉 CanvasRenderer.GetInheritedAlpha 的构建拒绝而不是当不透明。
#include <array>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <limits>
#include <string>
#include <utility>
#include <vector>

#include "adapters/unity_mono_audio.h"
#include "adapters/unity_mono_lookup_core.h"

using namespace fushi_voice_hook;
namespace ul = fushi_voice_hook::unity_mono_lookup;
namespace ua = fushi_voice_hook::unity_mono_audio;

namespace {

struct FakeClass;

struct FakeType {
  int kind = 0;
  bool byref = false;
  FakeClass* klass = nullptr;  // class_from_mono_type
};

struct FakeField {
  std::string name;
  FakeType* type;
  uint32_t offset;
};

struct FakeMethod {
  std::string name;
  bool instance;
  FakeType* ret;
  std::vector<FakeType*> params;
  uint32_t iflags;
  int entry_tag;  // lookup_internal_call returns &entry_tag when iflags has icall
};

struct FakeClass {
  std::string ns;
  std::string name;
  std::vector<FakeMethod> methods;
  std::vector<FakeField> fields;
  FakeClass* element = nullptr;  // array classes
  FakeType self_type;
  int32_t value_size = 0;  // mono_class_value_size (value types)
  FakeClass* parent = nullptr;  // mono_class_get_parent
};

struct FakeImage {
  std::string name;
  std::vector<FakeClass*> classes;
};

std::vector<FakeImage>* g_images = nullptr;

FakeType T(int kind, bool byref = false, FakeClass* klass = nullptr) {
  FakeType t;
  t.kind = kind;
  t.byref = byref;
  t.klass = klass;
  return t;
}

void FakeForeach(void (*func)(void*, void*), void* user_data) {
  for (FakeImage& image : *g_images) func(&image, user_data);
}
void* FakeAssemblyGetImage(void* a) { return a; }
const char* FakeImageName(void* image) {
  return static_cast<FakeImage*>(image)->name.c_str();
}
void* FakeClassFromName(void* image, const char* ns, const char* name) {
  for (FakeClass* klass : static_cast<FakeImage*>(image)->classes) {
    if (klass->ns == ns && klass->name == name) return klass;
  }
  return nullptr;
}
void* FakeClassGetMethods(void* klass, void** iter) {
  auto* c = static_cast<FakeClass*>(klass);
  const size_t next = reinterpret_cast<size_t>(*iter);
  if (next >= c->methods.size()) return nullptr;
  *iter = reinterpret_cast<void*>(next + 1);
  return &c->methods[next];
}
const char* FakeMethodName(void* m) {
  return static_cast<FakeMethod*>(m)->name.c_str();
}
void* FakeSignature(void* m) { return m; }
uint32_t FakeParamCount(void* s) {
  return static_cast<uint32_t>(static_cast<FakeMethod*>(s)->params.size());
}
void* FakeGetParams(void* s, void** iter) {
  auto* m = static_cast<FakeMethod*>(s);
  const size_t next = reinterpret_cast<size_t>(*iter);
  if (next >= m->params.size()) return nullptr;
  *iter = reinterpret_cast<void*>(next + 1);
  return m->params[next];
}
void* FakeReturnType(void* s) { return static_cast<FakeMethod*>(s)->ret; }
int32_t FakeIsInstance(void* s) {
  return static_cast<FakeMethod*>(s)->instance ? 1 : 0;
}
int FakeTypeGetType(void* t) { return static_cast<FakeType*>(t)->kind; }
int g_compiled = 0;
void* FakeCompile(void*) { return &g_compiled; }
void* FakeRootDomain() { return reinterpret_cast<void*>(0xD0); }
void* FakeAttach(void*) { return reinterpret_cast<void*>(0x7); }
void FakeDetach(void*) {}
int FakeStringLength(void*) { return 0; }
const wchar_t* FakeStringChars(void*) { return nullptr; }

void* FakeFieldFromName(void* klass, const char* name) {
  for (FakeField& f : static_cast<FakeClass*>(klass)->fields) {
    if (f.name == name) return &f;
  }
  return nullptr;
}
uint32_t FakeFieldOffset(void* f) { return static_cast<FakeField*>(f)->offset; }
void* FakeFieldType(void* f) { return static_cast<FakeField*>(f)->type; }
void* FakeClassFromType(void* t) { return static_cast<FakeType*>(t)->klass; }
void* FakeElementClass(void* klass) {
  return static_cast<FakeClass*>(klass)->element;
}
void* FakeLookupIcall(void* m) {
  auto* method = static_cast<FakeMethod*>(m);
  return (method->iflags & ul::kMethodImplInternalCall) != 0u
             ? &method->entry_tag
             : nullptr;
}
uint32_t FakeMethodFlags(void* m, uint32_t* iflags) {
  *iflags = static_cast<FakeMethod*>(m)->iflags;
  return 0u;
}
void* FakeClassGetType(void* klass) {
  return &static_cast<FakeClass*>(klass)->self_type;
}
int g_type_object = 0;
void* FakeTypeGetObject(void*, void*) { return &g_type_object; }
uint32_t g_gchandles = 0;
uint32_t FakeGcHandle(void*, int32_t) { return ++g_gchandles; }
int32_t FakeIsByref(void* t) { return static_cast<FakeType*>(t)->byref ? 1 : 0; }
uintptr_t FakeArrayLength(void*) { return 0u; }
char* FakeArrayAddr(void*, int32_t, uintptr_t) { return nullptr; }

MonoEmbeddingApi Api() {
  MonoEmbeddingApi api;
  api.get_root_domain = &FakeRootDomain;
  api.thread_attach = &FakeAttach;
  api.thread_detach = &FakeDetach;
  api.assembly_foreach = &FakeForeach;
  api.assembly_get_image = &FakeAssemblyGetImage;
  api.image_get_name = &FakeImageName;
  api.class_from_name = &FakeClassFromName;
  api.class_get_methods = &FakeClassGetMethods;
  api.method_get_name = &FakeMethodName;
  api.method_signature = &FakeSignature;
  api.signature_get_param_count = &FakeParamCount;
  api.signature_get_params = &FakeGetParams;
  api.signature_get_return_type = &FakeReturnType;
  api.signature_is_instance = &FakeIsInstance;
  api.type_get_type = &FakeTypeGetType;
  api.compile_method = &FakeCompile;
  api.string_length = &FakeStringLength;
  api.string_chars = &FakeStringChars;
  return api;
}

ul::MonoLookupApi LookupApi() {
  ul::MonoLookupApi api;
  api.class_get_field_from_name = &FakeFieldFromName;
  api.field_get_offset = &FakeFieldOffset;
  api.field_get_type = &FakeFieldType;
  api.class_from_mono_type = &FakeClassFromType;
  api.class_get_element_class = &FakeElementClass;
  api.lookup_internal_call = &FakeLookupIcall;
  api.method_get_flags = &FakeMethodFlags;
  api.class_get_type = &FakeClassGetType;
  api.type_get_object = &FakeTypeGetObject;
  api.gchandle_new = &FakeGcHandle;
  api.type_is_byref = &FakeIsByref;
  api.array_length = &FakeArrayLength;
  api.array_addr_with_size = &FakeArrayAddr;
  return api;
}

// ── a Unity-2019.2-shaped fake world ────────────────────────────────────────

constexpr uint32_t kPtr = static_cast<uint32_t>(sizeof(void*));
constexpr uint32_t kItems = 2 * kPtr;
constexpr uint32_t kSize = 3 * kPtr;
constexpr uint32_t kCached = 2 * kPtr;
constexpr uint32_t kSprite = 3 * kPtr;
constexpr uint32_t kLastMes = 7 * kPtr;

struct World {
  FakeType tvoid = T(kMonoTypeVoid), tbool = T(kMonoTypeBoolean),
           ti4 = T(ul::kMonoTypeI4), tstring = T(kMonoTypeString),
           tclass = T(kMonoTypeClass), tintptr = T(ul::kMonoTypeI),
           tvalue = T(ul::kMonoTypeValueType),
           tvalue_ref = T(ul::kMonoTypeValueType, true);
  FakeClass game_object{"UnityEngine", "GameObject"};
  FakeClass unity_object{"UnityEngine", "Object"};
  FakeClass camera{"UnityEngine", "Camera"};
  FakeClass screen{"UnityEngine", "Screen"};
  FakeClass renderer{"UnityEngine", "Renderer"};
  FakeClass scene_manager{"UnityEngine.SceneManagement", "SceneManager"};
  FakeClass message{"", "Message"};
  FakeClass inner_list{"System.Collections.Generic", "List`1"};
  FakeClass outer_list{"System.Collections.Generic", "List`1"};
  FakeClass inner_array{"", "GameObject[]"};
  FakeClass outer_array{"", "List`1[]"};
  FakeType t_inner_items, t_outer_items, t_outer_list;
  std::vector<FakeImage> images;

  static FakeMethod Icall(const char* name, bool instance, FakeType* ret,
                          std::vector<FakeType*> params) {
    return {name, instance, ret, std::move(params), ul::kMethodImplInternalCall,
            0};
  }

  World() {
    inner_array.element = &game_object;
    outer_array.element = &inner_list;
    t_inner_items = T(ul::kMonoTypeSzArray, false, &inner_array);
    t_outer_items = T(ul::kMonoTypeSzArray, false, &outer_array);
    t_outer_list = T(ul::kMonoTypeGenericInst, false, &outer_list);
    // Offsets follow the build's object header (two pointers).
    inner_list.fields = {{"_items", &t_inner_items, kItems},
                         {"_size", &ti4, kSize}};
    outer_list.fields = {{"_items", &t_outer_items, kItems},
                         {"_size", &ti4, kSize}};
    unity_object.fields = {{"m_CachedPtr", &tintptr, kCached}};
    unity_object.methods = {
        Icall("GetName", false, &tstring, {&tclass})};
    message.fields = {{"messageSprite", &t_outer_list, kSprite},
                      {"LastMes", &tstring, kLastMes}};
    message.methods = {{"Mes", true, &tstring, {&tstring, &tbool}, 0, 0},
                       {"FixedUpdate", true, &tvoid, {}, 0, 0}};
    camera.methods = {
        Icall("get_main", false, &tclass, {}),
        Icall("WorldToScreenPoint_Injected", true, &tvoid,
              {&tvalue_ref, &tvalue, &tvalue_ref}),
        Icall("get_cullingMask", true, &ti4, {}),
        Icall("get_targetTexture", true, &tclass, {}),
        Icall("get_orthographic", true, &tbool, {})};
    screen.methods = {Icall("get_width", false, &ti4, {}),
                      Icall("get_height", false, &ti4, {})};
    // GetComponent(string) comes first: a (string) overload must not match.
    game_object.methods = {
        {"GetComponent", true, &tclass, {&tstring}, 0, 0},
        Icall("get_activeInHierarchy", true, &tbool, {}),
        Icall("GetComponent", true, &tclass, {&tclass}),
        Icall("get_layer", true, &ti4, {}),
        Icall("get_scene_Injected", true, &tvoid, {&tvalue_ref})};
    scene_manager.methods = {
        Icall("GetActiveScene_Injected", false, &tvoid, {&tvalue_ref})};
    renderer.methods = {Icall("get_bounds_Injected", true, &tvoid,
                              {&tvalue_ref}),
                        Icall("get_enabled", true, &tbool, {})};
    images = {{"UnityEngine.CoreModule",
               {&game_object, &unity_object, &camera, &screen, &renderer,
                &scene_manager}},
              {"mscorlib", {}},
              {"Assembly-CSharp", {&message}}};
    g_images = &images;
  }
};

void TestResolvesUnityShape() {
  World world;
  ul::Sites sites;
  const auto result = ul::ResolveSites(Api(), LookupApi(), nullptr, &sites);
  assert(result.result == ul::SiteResult::kResolved);
  assert(sites.fixed_update == &world.message.methods[1]);
  assert(sites.message_sprite_offset == kSprite &&
         sites.last_mes_offset == kLastMes);
  assert(sites.list_items_offset == kItems && sites.list_size_offset == kSize);
  assert(sites.cached_ptr_offset == kCached);
  assert(sites.renderer_type == &g_type_object);
  // The (Type) overload, not the (string) one.
  assert(sites.icalls[static_cast<size_t>(ul::Icall::kGameObjectGetComponent)].entry ==
         &world.game_object.methods[2].entry_tag);
  for (const auto& binding : sites.icalls) {
    assert(binding.entry != nullptr &&
           binding.form == ul::IcallForm::kClassic);
  }
  assert(ul::ResolveObjectGetName(Api(), LookupApi()) ==
         &world.unity_object.methods[0].entry_tag);
}

void ExpectFailure(World& world, ul::SiteResult expected) {
  g_images = &world.images;
  ul::Sites sites;
  const auto result = ul::ResolveSites(Api(), LookupApi(), nullptr, &sites);
  if (result.result != expected) {
    std::printf("expected %u got %u\n", static_cast<unsigned>(expected),
                static_cast<unsigned>(result.result));
  }
  assert(result.result == expected);
}

void TestFailClosedBranches() {
  {
    World w;
    w.images.pop_back();  // no Assembly-CSharp
    ExpectFailure(w, ul::SiteResult::kNoScriptImage);
  }
  {
    World w;
    w.images[2].classes.clear();
    ExpectFailure(w, ul::SiteResult::kNoMessageClass);
  }
  {
    World w;
    w.message.methods.pop_back();
    ExpectFailure(w, ul::SiteResult::kNoFixedUpdate);
  }
  {
    World w;  // FixedUpdate with a parameter is not the framework's
    w.message.methods[1].params = {&w.ti4};
    ExpectFailure(w, ul::SiteResult::kNoFixedUpdate);
  }
  {
    World w;  // LastMes must be a string
    w.message.fields[1].type = &w.ti4;
    ExpectFailure(w, ul::SiteResult::kMessageFieldsMissing);
  }
  {
    World w;  // header-overlapping offset
    w.message.fields[0].offset = 0;
    ExpectFailure(w, ul::SiteResult::kMessageFieldsMissing);
  }
  {
    World w;  // inner list with another layout
    w.inner_list.fields[1].offset = kSize + kPtr;
    ExpectFailure(w, ul::SiteResult::kListLayoutMismatch);
  }
  {
    World w;  // List<List<Transform>> is not the framework's
    FakeClass other{"UnityEngine", "Transform"};
    w.inner_array.element = &other;
    ExpectFailure(w, ul::SiteResult::kElementNotGameObject);
  }
  {
    World w;
    w.unity_object.fields.clear();
    ExpectFailure(w, ul::SiteResult::kObjectFieldMissing);
  }
  {
    World w;  // a managed (non-icall) get_main is not an engine binding
    w.camera.methods[0].iflags = 0u;
    ExpectFailure(w, ul::SiteResult::kIcallMissing);
  }
  {
    World w;  // `out` must be by-ref
    w.renderer.methods[0].params = {&w.tvalue};
    ExpectFailure(w, ul::SiteResult::kIcallMissing);
  }
  {
    World w;  // two identical engine types in two images: ambiguous
    FakeClass twin{"UnityEngine", "Camera"};
    twin.methods = w.camera.methods;
    w.images[1].classes.push_back(&twin);
    ExpectFailure(w, ul::SiteResult::kIcallMissing);
  }
  {
    World w;  // pre-2018 Unity: no *_Injected bindings
    w.renderer.methods[0].name = "INTERNAL_get_bounds";
    ExpectFailure(w, ul::SiteResult::kIcallMissing);
  }
}

void TestVisibility() {
  assert(ul::GlyphVisible(true, true, 5, 5, 0, -1));
  assert(!ul::GlyphVisible(false, true, 5, 5, 0, -1));
  assert(!ul::GlyphVisible(true, false, 5, 5, 0, -1));
  // An overlay scene became the active scene.
  assert(!ul::GlyphVisible(true, true, 5, 9, 0, -1));
  assert(!ul::GlyphVisible(true, true, 0, 0, 0, -1));
  // Layer outside the culling mask.
  assert(!ul::GlyphVisible(true, true, 5, 5, 3, ~(1 << 3)));
  assert(ul::GlyphVisible(true, true, 5, 5, 3, 1 << 3));
  assert(!ul::GlyphVisible(true, true, 5, 5, 32, -1));
  ul::GlyphCell cell;
  assert(ul::CellFromScreenCorners({266, 613.76f, 530}, {302, 664, 530},
                                   false, &cell));
  assert(cell.x0 == 266 && cell.x1 == 302 && cell.y1 == 664);
  // Behind a perspective camera; an orthographic camera with a negative near
  // plane draws it (measured: depth -530).
  assert(!ul::CellFromScreenCorners({266, 613, -1}, {302, 664, -1}, false,
                                    &cell));
  assert(ul::CellFromScreenCorners({266, 613, -530}, {302, 664, -530}, true,
                                   &cell));
  assert(!ul::CellFromScreenCorners({266, 613, 1}, {266.5f, 664, 1}, true,
                                    &cell));
  const float nan = std::nanf("");
  assert(!ul::CellFromScreenCorners({nan, 613, 1}, {302, 664, 1}, true,
                                    &cell));
}

void TestTextMapping() {
  // Two rendered lines ("ab", "cde") + "\n" terminators.
  const std::wstring text = L"ab\ncde\n";
  const uint16_t lines[] = {2, 3};
  uint16_t source[8] = {};
  assert(ul::MapGlyphsToText(text.data(), text.size(), lines, 2, source, 8));
  assert(source[0] == 0 && source[1] == 1 && source[2] == 3 &&
         source[4] == 5);
  const uint16_t wrong_count[] = {2, 2};
  assert(!ul::MapGlyphsToText(text.data(), text.size(), wrong_count, 2,
                              source, 8));
  // A text line without a rendered line, and a rendered line without text.
  const uint16_t one[] = {2};
  assert(!ul::MapGlyphsToText(text.data(), text.size(), one, 1, source, 8));
  const uint16_t three[] = {2, 3, 1};
  assert(!ul::MapGlyphsToText(text.data(), text.size(), three, 3, source, 8));
  // Text not ending with the line terminator (e.g. a stripped/cut lane line).
  const std::wstring cut = L"ab\ncde";
  assert(!ul::MapGlyphsToText(cut.data(), cut.size(), lines, 2, source, 8));
  // Capacity bound.
  assert(!ul::MapGlyphsToText(text.data(), text.size(), lines, 2, source, 4));
}

void TestProjection() {
  ul::GlyphCell cell;
  cell.x0 = 266;
  cell.y0 = 613.76f;
  cell.x1 = 302;
  cell.y1 = 664;
  ul::PixelRect rect;
  // Unity screen == physical client (per-monitor aware player).
  assert(ul::ProjectCell(cell, 1280, 720, 1280, 720, &rect));
  assert(rect.x == 266 && rect.y == 56 && rect.w == 36 && rect.h == 51);
  // A DPI-unaware player at 200%: screen 1280x720, physical 2560x1440.
  assert(ul::ProjectCell(cell, 1280, 720, 2560, 1440, &rect));
  assert(rect.x == 532 && rect.y == 112 && rect.w == 72 && rect.h == 101);
  ul::GlyphCell outside = cell;
  outside.x1 = 1281;
  assert(!ul::ProjectCell(outside, 1280, 720, 1280, 720, &rect));
  float x = 0, y = 0;
  assert(ul::ClientToScreenPoint(640, 360, 1280, 720, &x, &y));
  assert(x == 640.5f && y == 359.5f);
  assert(!ul::ClientToScreenPoint(1280, 10, 1280, 720, &x, &y));
}

void TestHitTest() {
  ul::GlyphCell cells[3];
  const float x0[] = {266, 302, 338};
  for (int i = 0; i < 3; ++i) {
    cells[i].x0 = x0[i];
    cells[i].x1 = x0[i] + 36;
    cells[i].y0 = 613.76f;
    cells[i].y1 = 664;
    cells[i].visible = 1;
  }
  uint16_t source[3] = {0, 1, 2};
  size_t hit = 9;
  // Touching cells: the shared edge belongs to the right-hand glyph.
  assert(ul::HitTestCells(cells, source, 3, 302.0f, 640, &hit) && hit == 1);
  assert(ul::HitTestCells(cells, source, 3, 301.9f, 640, &hit) && hit == 0);
  assert(!ul::HitTestCells(cells, source, 3, 374.0f, 640, &hit));
  assert(!ul::HitTestCells(cells, source, 3, 300.0f, 700, &hit));
  // Hidden (not yet revealed) glyphs are not targets.
  cells[2].visible = 0;
  assert(!ul::HitTestCells(cells, source, 3, 350, 640, &hit));
  cells[2].visible = 1;
  // Tight spacing: overlapping cells resolve to the nearer centre.
  cells[1].x0 = 296;  // overlaps glyph 0 on [296, 302); centre 314
  cells[1].x1 = 332;
  assert(ul::HitTestCells(cells, source, 3, 300.0f, 640, &hit) && hit == 1);
  assert(ul::HitTestCells(cells, source, 3, 297.0f, 640, &hit) && hit == 0);
  // Exactly between two centres: refused.
  cells[1].x0 = 290;
  cells[1].x1 = 326;  // centre 308; glyph 0 centre 284
  assert(!ul::HitTestCells(cells, source, 3, 296.0f, 640, &hit));
  // Unmapped glyph.
  source[0] = ul::kNoSource;
  assert(ul::HitTestCells(cells, source, 3, 296.0f, 640, &hit) && hit == 1);
}

void TestClaim() {
  ul::ClaimState claim;
  auto d = ul::DecideMessage(ul::kMessageLeftDown, true, &claim);
  assert(d.swallow && d.submit && claim.owned);
  d = ul::DecideMessage(ul::kMessageLeftUp, false, &claim);
  assert(d.swallow && !d.submit && !claim.owned);
  // An ineligible press and its release reach the game.
  d = ul::DecideMessage(ul::kMessageLeftDown, false, &claim);
  assert(!d.swallow && !d.submit);
  d = ul::DecideMessage(ul::kMessageLeftUp, false, &claim);
  assert(!d.swallow);
  // A lost release never makes a later press sticky.
  ul::DecideMessage(ul::kMessageLeftDouble, true, &claim);
  d = ul::DecideMessage(ul::kMessageLeftDown, false, &claim);
  assert(!d.swallow && !claim.owned);
  assert(!ul::NeedsEligibility(WM_MOUSEMOVE));
}

void TestRoleKey() {
  const wchar_t body[] = L"Message";
  const wchar_t plate[] = L"Name";
  const uint64_t a = ul::MessageRoleKey(body, 7);
  assert(a != 0u && a == ul::MessageRoleKey(body, 7));
  assert(a != ul::MessageRoleKey(plate, 4));
  assert(ul::MessageRoleKey(nullptr, 3) == 0u);
  assert(ul::MessageRoleKey(body, 0) == 0u);
}

// ── framework 2: Fungus SayDialog on a UGUI Text ────────────────────────────

int32_t FakeValueSize(void* klass, uint32_t* align) {
  if (align != nullptr) *align = 4u;
  return static_cast<FakeClass*>(klass)->value_size;
}

ul::MonoValueSizeApi SizeApi() {
  ul::MonoValueSizeApi api;
  api.class_value_size = &FakeValueSize;
  return api;
}

// Offsets as mono reports them (instance fields after a two-pointer header;
// value-type fields likewise boxed-relative).
constexpr uint32_t kHdr = 2 * kPtr;

// A Unity-2021.3 / Fungus-3.x-shaped world (measured 2026-09-28 on a real
// player: UICharInfo {Vector2 cursorPos; float charWidth} = 12 bytes,
// UILineInfo {int startCharIdx; int height; float topY; float leading} = 16).
struct FungusWorld {
  FakeType tvoid = T(kMonoTypeVoid), tbool = T(kMonoTypeBoolean),
           ti4 = T(ul::kMonoTypeI4), tr4 = T(kMonoTypeSingle),
           tstring = T(kMonoTypeString), tclass = T(kMonoTypeClass),
           tintptr = T(ul::kMonoTypeI), tvalue = T(ul::kMonoTypeValueType),
           tvalue_ref = T(ul::kMonoTypeValueType, true),
           tobject = T(ul::kMonoTypeObject);
  FakeClass say_dialog{"Fungus", "SayDialog"};
  FakeClass text{"UnityEngine.UI", "Text"};
  FakeClass graphic{"UnityEngine.UI", "Graphic"};
  FakeClass font_data{"UnityEngine.UI", "FontData"};
  FakeClass generator{"UnityEngine", "TextGenerator"};
  FakeClass font{"UnityEngine", "Font"};
  FakeClass canvas{"UnityEngine", "Canvas"};
  FakeClass renderer{"UnityEngine", "CanvasRenderer"};
  FakeClass color{"UnityEngine", "Color"};
  FakeClass char_info{"UnityEngine", "UICharInfo"};
  FakeClass line_info{"UnityEngine", "UILineInfo"};
  FakeClass char_list{"System.Collections.Generic", "List`1"};
  FakeClass line_list{"System.Collections.Generic", "List`1"};
  FakeClass char_array{"", "UICharInfo[]"};
  FakeClass line_array{"", "UILineInfo[]"};
  FakeClass unity_object{"UnityEngine", "Object"};
  FakeClass component{"UnityEngine", "Component"};
  FakeClass behaviour{"UnityEngine", "Behaviour"};
  FakeClass transform{"UnityEngine", "Transform"};
  FakeClass camera{"UnityEngine", "Camera"};
  FakeClass screen{"UnityEngine", "Screen"};
  FakeType t_text, t_generator, t_font_data, t_font, t_canvas, t_renderer,
      t_color, t_char_list, t_line_list, t_char_items, t_line_items,
      t_vector2;
  std::vector<FakeImage> images;

  static FakeMethod Icall(const char* name, bool instance, FakeType* ret,
                          std::vector<FakeType*> params) {
    return {name, instance, ret, std::move(params), ul::kMethodImplInternalCall,
            0};
  }

  FungusWorld() {
    t_text = T(kMonoTypeClass, false, &text);
    t_generator = T(kMonoTypeClass, false, &generator);
    t_font_data = T(kMonoTypeClass, false, &font_data);
    t_font = T(kMonoTypeClass, false, &font);
    t_canvas = T(kMonoTypeClass, false, &canvas);
    t_renderer = T(kMonoTypeClass, false, &renderer);
    t_color = T(ul::kMonoTypeValueType, false, &color);
    t_vector2 = T(ul::kMonoTypeValueType);
    t_char_list = T(ul::kMonoTypeGenericInst, false, &char_list);
    t_line_list = T(ul::kMonoTypeGenericInst, false, &line_list);
    char_array.element = &char_info;
    line_array.element = &line_info;
    t_char_items = T(ul::kMonoTypeSzArray, false, &char_array);
    t_line_items = T(ul::kMonoTypeSzArray, false, &line_array);
    say_dialog.fields = {{"nameText", &t_text, 5 * kPtr},
                         {"storyText", &t_text, 8 * kPtr}};
    say_dialog.methods = {{"LateUpdate", true, &tvoid, {}, 0, 0}};
    text.fields = {{"m_FontData", &t_font_data, 24 * kPtr},
                   {"m_Text", &tstring, 25 * kPtr},
                   {"m_TextCache", &t_generator, 26 * kPtr}};
    graphic.fields = {{"m_CanvasRenderer", &t_renderer, 5 * kPtr},
                      {"m_Canvas", &t_canvas, 6 * kPtr},
                      {"m_Color", &t_color, 100}};
    font_data.fields = {{"m_Font", &t_font, kHdr}};
    color.fields = {{"r", &tr4, kHdr}, {"g", &tr4, kHdr + 4},
                    {"b", &tr4, kHdr + 8}, {"a", &tr4, kHdr + 12}};
    color.value_size = 16;
    generator.fields = {{"m_LastString", &tstring, 3 * kPtr},
                        {"m_Characters", &t_char_list, 18 * kPtr},
                        {"m_Lines", &t_line_list, 19 * kPtr}};
    char_list.fields = {{"_items", &t_char_items, kItems},
                        {"_size", &ti4, kSize}};
    line_list.fields = {{"_items", &t_line_items, kItems},
                        {"_size", &ti4, kSize}};
    char_info.fields = {{"cursorPos", &t_vector2, kHdr},
                        {"charWidth", &tr4, kHdr + 8}};
    char_info.value_size = 12;
    line_info.fields = {{"startCharIdx", &ti4, kHdr},
                        {"height", &ti4, kHdr + 4},
                        {"topY", &tr4, kHdr + 8},
                        {"leading", &tr4, kHdr + 12}};
    line_info.value_size = 16;
    unity_object.fields = {{"m_CachedPtr", &tintptr, 2 * kPtr}};
    component.methods = {Icall("get_gameObject", true, &tclass, {}),
                         Icall("get_transform", true, &tclass, {})};
    behaviour.methods = {Icall("get_enabled", true, &tbool, {}),
                         Icall("get_isActiveAndEnabled", true, &tbool, {})};
    transform.methods = {Icall("get_localToWorldMatrix_Injected", true, &tvoid,
                               {&tvalue_ref})};
    canvas.methods = {Icall("get_rootCanvas", true, &tclass, {}),
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
    images = {{"UnityEngine.CoreModule",
               {&unity_object, &component, &behaviour, &transform, &camera,
                &screen, &color}},
              {"UnityEngine.UIModule", {&canvas, &renderer}},
              {"UnityEngine.TextRenderingModule",
               {&generator, &font, &char_info, &line_info}},
              {"UnityEngine.UI", {&text, &graphic, &font_data}},
              {"Fungus", {&say_dialog}},
              {"Assembly-CSharp", {}}};
    g_images = &images;
  }
};

void TestFungusResolvesUguiShape() {
  FungusWorld world;
  ul::FungusSites sites;
  const auto result =
      ul::ResolveFungusSites(Api(), LookupApi(), SizeApi(), &sites);
  assert(result.result == ul::FungusSiteResult::kResolved);
  assert(sites.late_update == &world.say_dialog.methods[0]);
  assert(sites.story_text_offset == 8 * kPtr);
  assert(sites.text_class == &world.text);
  assert(sites.text_string_offset == 25 * kPtr &&
         sites.text_cache_offset == 26 * kPtr &&
         sites.font_data_offset == 24 * kPtr && sites.font_data_font_offset == kHdr);
  assert(sites.graphic_canvas_offset == 6 * kPtr &&
         sites.graphic_renderer_offset == 5 * kPtr);
  // m_Color boxed at 100, `a` 12 bytes into the value.
  assert(sites.graphic_color_alpha_offset == 112);
  assert(sites.generator_last_offset == 3 * kPtr &&
         sites.generator_chars_offset == 18 * kPtr &&
         sites.generator_lines_offset == 19 * kPtr);
  assert(sites.char_stride == 12 && sites.char_cursor_offset == 0 &&
         sites.char_width_offset == 8);
  assert(sites.line_stride == 16 && sites.line_start_offset == 0 &&
         sites.line_height_offset == 4 && sites.line_top_offset == 8);
  assert(sites.char_list_items_offset == kItems &&
         sites.line_list_size_offset == kSize);
  // Behaviour.get_isActiveAndEnabled, not get_enabled.
  assert(sites.icalls[static_cast<size_t>(
             ul::FungusIcall::kBehaviourActiveAndEnabled)].entry ==
         &world.behaviour.methods[1].entry_tag);
  for (const auto& binding : sites.icalls) {
    assert(binding.entry != nullptr &&
           binding.form == ul::IcallForm::kClassic);
  }
}

void ExpectFungusFailure(FungusWorld& world, ul::FungusSiteResult expected) {
  g_images = &world.images;
  ul::FungusSites sites;
  const auto result =
      ul::ResolveFungusSites(Api(), LookupApi(), SizeApi(), &sites);
  if (result.result != expected) {
    std::printf("fungus expected %u got %u\n", static_cast<unsigned>(expected),
                static_cast<unsigned>(result.result));
  }
  assert(result.result == expected);
}

void TestFungusFailClosedBranches() {
  {
    FungusWorld w;
    w.images[4].classes.clear();
    ExpectFungusFailure(w, ul::FungusSiteResult::kNoSayDialog);
  }
  {
    FungusWorld w;  // the framework type twice (two copies of Fungus)
    FakeClass twin{"Fungus", "SayDialog"};
    twin.fields = w.say_dialog.fields;
    twin.methods = w.say_dialog.methods;
    w.images[5].classes.push_back(&twin);
    ExpectFungusFailure(w, ul::FungusSiteResult::kNoSayDialog);
  }
  {
    FungusWorld w;  // LateUpdate with a parameter is not the framework's
    w.say_dialog.methods[0].params = {&w.tbool};
    ExpectFungusFailure(w, ul::FungusSiteResult::kNoLateUpdate);
  }
  {
    FungusWorld w;  // storyText is a TextMeshPro component: not this branch
    FakeClass tmp{"TMPro", "TextMeshProUGUI"};
    FakeType t_tmp = T(kMonoTypeClass, false, &tmp);
    w.say_dialog.fields[1].type = &t_tmp;
    ExpectFungusFailure(w, ul::FungusSiteResult::kStoryTextMissing);
  }
  {
    FungusWorld w;
    w.text.fields[1].type = &w.ti4;  // m_Text must be a string
    ExpectFungusFailure(w, ul::FungusSiteResult::kTextFieldsMissing);
  }
  {
    FungusWorld w;
    w.graphic.fields.pop_back();  // no m_Color
    ExpectFungusFailure(w, ul::FungusSiteResult::kGraphicFieldsMissing);
  }
  {
    FungusWorld w;
    w.generator.fields[0].name = "m_LastStr";
    ExpectFungusFailure(w, ul::FungusSiteResult::kGeneratorFieldsMissing);
  }
  {
    FungusWorld w;  // List<UIVertex> where List<UICharInfo> is expected
    FakeClass vertex{"UnityEngine", "UIVertex"};
    w.char_array.element = &vertex;
    ExpectFungusFailure(w, ul::FungusSiteResult::kCharLayoutMismatch);
  }
  {
    FungusWorld w;  // a UICharInfo layout the stride cannot hold
    w.char_info.value_size = 8;
    ExpectFungusFailure(w, ul::FungusSiteResult::kCharLayoutMismatch);
  }
  {
    FungusWorld w;
    w.line_info.fields[2].type = &w.ti4;  // topY must be a float
    ExpectFungusFailure(w, ul::FungusSiteResult::kLineLayoutMismatch);
  }
  {
    FungusWorld w;
    w.unity_object.fields.clear();
    ExpectFungusFailure(w, ul::FungusSiteResult::kObjectFieldMissing);
  }
  {
    FungusWorld w;  // a managed GetCharactersInternal is not the binding
    w.generator.methods[0].iflags = 0u;
    ExpectFungusFailure(w, ul::FungusSiteResult::kIcallMissing);
  }
  {
    FungusWorld w;  // `out Matrix4x4` must be by-ref
    w.transform.methods[0].params = {&w.tvalue};
    ExpectFungusFailure(w, ul::FungusSiteResult::kIcallMissing);
  }
  {
    FungusWorld w;
    ul::FungusSites sites;
    ul::MonoValueSizeApi none;
    assert(ul::ResolveFungusSites(Api(), LookupApi(), none, &sites).result ==
           ul::FungusSiteResult::kApiIncomplete);
  }
}

// Framework 4: a bare UI.Text.  The Fungus world without SayDialog, plus the
// managed Canvas.SendWillRenderCanvases the canvas texts sample after.
struct UiTextWorld : FungusWorld {
  UiTextWorld() {
    images[4].classes.clear();  // no Fungus
    canvas.methods.insert(canvas.methods.begin(),
                          {"SendWillRenderCanvases", false, &tvoid, {}, 0, 0});
    g_images = &images;
  }
};

ul::UiTextSiteResolution ResolveUiText(ul::FungusSites* sites,
                                       void** will_render) {
  return ul::ResolveUiTextSites(Api(), LookupApi(), SizeApi(), sites,
                                will_render);
}

void TestUiTextResolvesUguiShape() {
  UiTextWorld world;
  ul::FungusSites sites;
  void* will_render = nullptr;
  const auto result = ResolveUiText(&sites, &will_render);
  assert(result.result == ul::UiTextSiteResult::kResolved);
  assert(result.layout == ul::FungusSiteResult::kResolved);
  assert(will_render == &world.canvas.methods[0]);
  assert(sites.text_class == &world.text);
  // No dialog part: the object comes from the text path, not from a field.
  assert(sites.late_update == nullptr && sites.story_text_offset == 0u);
  // The shared UGUI layout reading is the one framework 2 measured.
  assert(sites.text_string_offset == 25 * kPtr &&
         sites.text_cache_offset == 26 * kPtr);
  assert(sites.graphic_canvas_offset == 6 * kPtr &&
         sites.graphic_renderer_offset == 5 * kPtr &&
         sites.graphic_color_alpha_offset == 112);
  assert(sites.char_stride == 12 && sites.line_stride == 16);
  assert(sites.cached_ptr_offset == 2 * kPtr);
  for (const auto& binding : sites.icalls) {
    assert(binding.entry != nullptr &&
           binding.form == ul::IcallForm::kClassic);
  }
  // A Fungus game resolves the same layout through its SayDialog.
  {
    FungusWorld fungus;
    ul::FungusSites fungus_sites;
    assert(ul::ResolveFungusSites(Api(), LookupApi(), SizeApi(), &fungus_sites)
               .result == ul::FungusSiteResult::kResolved);
    assert(fungus_sites.text_string_offset == sites.text_string_offset &&
           fungus_sites.char_stride == sites.char_stride);
  }
}

void ExpectUiTextFailure(UiTextWorld& world, ul::UiTextSiteResult expected,
                         ul::FungusSiteResult layout =
                             ul::FungusSiteResult::kApiIncomplete) {
  g_images = &world.images;
  ul::FungusSites sites;
  void* will_render = &sites;  // must be cleared on failure
  const auto result = ResolveUiText(&sites, &will_render);
  if (result.result != expected || result.layout != layout) {
    std::printf("uitext expected %u/%u got %u/%u\n",
                static_cast<unsigned>(expected), static_cast<unsigned>(layout),
                static_cast<unsigned>(result.result),
                static_cast<unsigned>(result.layout));
  }
  assert(result.result == expected && result.layout == layout);
  assert(will_render == nullptr);
}

void TestUiTextFailClosedBranches() {
  {
    UiTextWorld w;  // no UnityEngine.UI.Text at all
    w.images[3].classes = {&w.graphic, &w.font_data};
    ExpectUiTextFailure(w, ul::UiTextSiteResult::kNoTextClass);
  }
  {
    UiTextWorld w;  // two UnityEngine.UI.Text types: which one is unknown
    FakeClass twin{"UnityEngine.UI", "Text"};
    twin.fields = w.text.fields;
    w.images[5].classes.push_back(&twin);
    ExpectUiTextFailure(w, ul::UiTextSiteResult::kNoTextClass);
  }
  {
    UiTextWorld w;  // only the Pre* sibling: no sampling point
    w.canvas.methods[0].name = "SendPreWillRenderCanvases";
    ExpectUiTextFailure(w, ul::UiTextSiteResult::kNoWillRender);
  }
  {
    UiTextWorld w;  // an internal-call SendWillRenderCanvases has no JIT body
    w.canvas.methods[0].iflags = ul::kMethodImplInternalCall;
    ExpectUiTextFailure(w, ul::UiTextSiteResult::kNoWillRender);
  }
  {
    UiTextWorld w;  // an instance SendWillRenderCanvases is not the player's
    w.canvas.methods[0].instance = true;
    ExpectUiTextFailure(w, ul::UiTextSiteResult::kNoWillRender);
  }
  {
    UiTextWorld w;  // m_Text must be a string
    w.text.fields[1].type = &w.ti4;
    ExpectUiTextFailure(w, ul::UiTextSiteResult::kLayout,
                        ul::FungusSiteResult::kTextFieldsMissing);
  }
  {
    UiTextWorld w;  // a UICharInfo layout the stride cannot hold
    w.char_info.value_size = 8;
    ExpectUiTextFailure(w, ul::UiTextSiteResult::kLayout,
                        ul::FungusSiteResult::kCharLayoutMismatch);
  }
  {
    UiTextWorld w;  // a managed GetCharactersInternal is not the binding
    w.generator.methods[0].iflags = 0u;
    ExpectUiTextFailure(w, ul::UiTextSiteResult::kLayout,
                        ul::FungusSiteResult::kIcallMissing);
  }
  {
    UiTextWorld w;
    ul::FungusSites sites;
    void* will_render = nullptr;
    ul::MonoValueSizeApi none;
    assert(ul::ResolveUiTextSites(Api(), LookupApi(), none, &sites,
                                  &will_render)
               .result == ul::UiTextSiteResult::kApiIncomplete);
    assert(ul::ResolveUiTextSites(Api(), LookupApi(), SizeApi(), &sites,
                                  nullptr)
               .result == ul::UiTextSiteResult::kApiIncomplete);
  }
}

void TestScreenAxesUpright() {
  const ul::Vec3 o{100.0f, 200.0f, 0.0f};
  // Upright (overlay canvas, scale 1.5).
  assert(ul::ScreenAxesUpright(o, {250.0f, 200.0f, 0.0f}, {100.0f, 350.0f, 0.0f}));
  // A 1 degree tilt is within kAxisSkew (tan 1deg = 0.0175).
  assert(ul::ScreenAxesUpright(o, {200.0f, 201.7f, 0.0f}, {98.3f, 300.0f, 0.0f}));
  // A 5 degree tilt is not.
  assert(!ul::ScreenAxesUpright(o, {199.6f, 208.7f, 0.0f}, {91.3f, 299.6f, 0.0f}));
  // Rotated 90 degrees (a vertical-writing RectTransform): +x goes up.
  assert(!ul::ScreenAxesUpright(o, {100.0f, 300.0f, 0.0f}, {0.0f, 200.0f, 0.0f}));
  // Rotated -90 degrees.
  assert(!ul::ScreenAxesUpright(o, {100.0f, 100.0f, 0.0f}, {200.0f, 200.0f, 0.0f}));
  // Mirrored in x / in y.
  assert(!ul::ScreenAxesUpright(o, {0.0f, 200.0f, 0.0f}, {100.0f, 300.0f, 0.0f}));
  assert(!ul::ScreenAxesUpright(o, {200.0f, 200.0f, 0.0f}, {100.0f, 100.0f, 0.0f}));
  // Degenerate (zero scale) and non-finite projections.
  assert(!ul::ScreenAxesUpright(o, o, o));
  const float nan = std::numeric_limits<float>::quiet_NaN();
  assert(!ul::ScreenAxesUpright(o, {nan, 200.0f, 0.0f}, {100.0f, 300.0f, 0.0f}));
}

void TestMatchShownToLineIgnoresLineBreaks() {
  // Measured shape: the renderer laid out a line feed (a stripped <br>) the
  // lane text does not carry.  Synthetic units, not dialogue.
  const std::wstring line = L"\u3042\u3044\u3046\u3001\u3048\u304a";
  const std::wstring shown = L"\u3042\u3044\u3046\u3001\n\u3048\u304a";
  std::array<uint16_t, ul::kMaxLineUnits> map{};
  assert(ul::MatchShownToLine(shown.data(), shown.size(), line.data(),
                              line.size(), map.data()));
  assert(map[3] == 3u && map[4] == ul::kNoSource && map[5] == 4u &&
         map[6] == 5u);
  // The other way round (the lane kept a break the layout joined), CRLF, and
  // trailing breaks on either side.
  assert(ul::MatchShownToLine(line.data(), line.size(), shown.data(),
                              shown.size(), map.data()));
  assert(map[4] == 5u);
  const std::wstring crlf = L"\u3042\u3044\u3046\u3001\r\n\u3048\u304a\n";
  assert(ul::MatchShownToLine(crlf.data(), crlf.size(), line.data(),
                              line.size(), nullptr));
  // Any drawn unit that differs, is missing or is extra still fails.
  const std::wstring other = L"\u3042\u3044\u3046\u3002\n\u3048\u304a";
  assert(!ul::MatchShownToLine(other.data(), other.size(), line.data(),
                               line.size(), nullptr));
  const std::wstring shorter = L"\u3042\u3044\u3046\u3001\n\u3048";
  assert(!ul::MatchShownToLine(shorter.data(), shorter.size(), line.data(),
                               line.size(), nullptr));
  assert(!ul::MatchShownToLine(line.data(), line.size(), shorter.data(),
                               shorter.size(), nullptr));
  // A space is drawn content, not a break.
  const std::wstring spaced = L"\u3042\u3044\u3046\u3001 \u3048\u304a";
  assert(!ul::MatchShownToLine(spaced.data(), spaced.size(), line.data(),
                               line.size(), nullptr));
  // Only breaks on both sides is no text.
  const std::wstring breaks = L"\n\n";
  assert(!ul::MatchShownToLine(breaks.data(), breaks.size(), breaks.data(),
                               breaks.size(), nullptr));
  // Identical texts map to themselves.
  assert(ul::MatchShownToLine(line.data(), line.size(), line.data(),
                              line.size(), map.data()));
  for (size_t i = 0; i < line.size(); ++i) assert(map[i] == i);
}

void TestFirstUnitDifference() {
  using K = ul::UnitKind;
  auto kinds = [](K a, K b) {
    return 10u * static_cast<uint32_t>(a) + static_cast<uint32_t>(b);
  };
  {
    // The laid-out text has a line break where the line has none.
    const std::wstring shown = L"\u3042\u3044\n\u3046";
    const std::wstring line = L"\u3042\u3044\u3046";
    const auto d = ul::FirstUnitDifference(shown.data(), shown.size(),
                                           line.data(), line.size());
    assert(d.index == 2u && d.kinds == kinds(K::kLineBreak, K::kOther));
  }
  {
    // A prefix (typewriter text not yet complete): the shown side ended.
    const std::wstring shown = L"\u3042\u3044";
    const std::wstring line = L"\u3042\u3044 x";
    const auto d = ul::FirstUnitDifference(shown.data(), shown.size(),
                                           line.data(), line.size());
    assert(d.index == 2u && d.kinds == kinds(K::kEnd, K::kSpace));
  }
  {
    const std::wstring shown = L"a\u200b";
    const std::wstring line = L"aB";
    const auto d = ul::FirstUnitDifference(shown.data(), shown.size(),
                                           line.data(), line.size());
    assert(d.index == 1u && d.kinds == kinds(K::kControl, K::kAscii));
  }
  {
    const std::wstring same = L"\u3000x";
    const auto d = ul::FirstUnitDifference(same.data(), same.size(),
                                           same.data(), same.size());
    assert(d.index == 2u && d.kinds == kinds(K::kEnd, K::kEnd));
    assert(ul::KindOfUnit(same.data(), same.size(), 0u) == K::kSpace);
  }
}

void TestRichTextMap() {
  // The Writer's read-ahead: visible part, then the rest in an alpha-0 span.
  const std::wstring raw = L"あい<color=#FFFFFF00>う\nえ</color>";
  ul::RichTextMap map;
  assert(ul::ParseRichText(raw.data(), raw.size(), &map));
  assert(map.plain_length == 5);
  assert(std::wstring(map.plain.data(), map.plain_length) == L"あいう\nえ");
  assert(map.raw_to_plain[0] == 0 && map.raw_to_plain[1] == 1);
  assert(map.raw_to_plain[2] == ul::kRawTag);   // '<' of the open tag
  assert(map.raw_to_plain[19] == 2);            // う
  assert(map.hidden[0] == 0 && map.hidden[1] == 0);
  assert(map.hidden[19] == 1 && map.hidden[21] == 1);
  // Opaque colours, style tags and nesting.
  const std::wstring nested =
      L"<b>か</b><color=red>き<color=#00000000>く</color>け</color>";
  assert(ul::ParseRichText(nested.data(), nested.size(), &map));
  assert(std::wstring(map.plain.data(), map.plain_length) == L"かきくけ");
  const size_t ki = nested.find(L'き'), ku = nested.find(L'く'),
               ke = nested.find(L'け');
  assert(map.hidden[ki] == 0 && map.hidden[ku] == 1 && map.hidden[ke] == 0);
  // Short #RGBA form.
  const std::wstring short_form = L"<color=#FFF0>こ</color>";
  assert(ul::ParseRichText(short_form.data(), short_form.size(), &map));
  assert(map.hidden[short_form.find(L'こ')] == 1);
  assert(!ul::ColorValueIsTransparent(L"#FFFFFF", 7));
  assert(!ul::ColorValueIsTransparent(L"#FFFFFF01", 9));
  assert(ul::ColorValueIsTransparent(L"#12345600", 9));
  // An unclosed '<' makes the lane's stripping and the renderer disagree.
  const std::wstring open = L"さ<し";
  assert(!ul::ParseRichText(open.data(), open.size(), &map));
  assert(!ul::ParseRichText(nullptr, 3, &map));
}

void TestFungusGeometry() {
  // Measured layout: 24-px advance, line tops 0 / -35, height 34, pixels per
  // unit 1 (canvas scale factor), overlay canvas where world == screen.
  int32_t starts[] = {0, 19, 30};
  size_t line = 9;
  assert(ul::LineOfUnit(starts, 3, 0, &line) && line == 0);
  assert(ul::LineOfUnit(starts, 3, 18, &line) && line == 0);
  assert(ul::LineOfUnit(starts, 3, 19, &line) && line == 1);
  assert(ul::LineOfUnit(starts, 3, 31, &line) && line == 2);
  int32_t unsorted[] = {0, 19, 5};
  assert(!ul::LineOfUnit(unsorted, 3, 20, &line));
  ul::LocalCell local;
  assert(ul::GeneratorCell(24, 24, -35, 34, 1.0f, &local));
  assert(local.x0 == 24 && local.x1 == 48 && local.y1 == -35 &&
         local.y0 == -69);
  assert(ul::GeneratorCell(48, 24, 0, 34, 2.0f, &local) && local.x0 == 24 &&
         local.x1 == 36 && local.y0 == -17);
  assert(!ul::GeneratorCell(24, 0, 0, 34, 1.0f, &local));   // '\n' / tag
  assert(!ul::GeneratorCell(24, 24, 0, 0, 1.0f, &local));
  assert(!ul::GeneratorCell(24, 24, 0, 34, 0.0f, &local));
  // Local -> world (Unity column-major TRS: scale 1, translate (330, 141)).
  ul::Matrix4 m;
  m.m[0] = 1; m.m[5] = 1; m.m[10] = 1; m.m[15] = 1;
  m.m[12] = 330; m.m[13] = 141;
  const ul::Vec3 a = ul::TransformPoint(m, 24, -69);
  const ul::Vec3 b = ul::TransformPoint(m, 48, -35);
  ul::GlyphCell cell;
  assert(ul::CellFromScreenCorners(a, b, true, &cell));
  assert(cell.x0 == 354 && cell.x1 == 378 && cell.y0 == 72 && cell.y1 == 106);
  // -> client pixels (top-left origin): 720-106 = 614 .. 720-72 = 648.
  ul::PixelRect rect;
  assert(ul::ProjectCell(cell, 1280, 720, 1280, 720, &rect));
  assert(rect.x == 354 && rect.y == 614 && rect.w == 24 && rect.h == 34);
  // Sources must address drawn units in order.
  const std::wstring plain = L"あい\nう";
  const uint16_t good[] = {0, 1, 3};
  assert(ul::ValidateGlyphSources(plain.data(), plain.size(), good, 3));
  const uint16_t newline[] = {0, 2};
  assert(!ul::ValidateGlyphSources(plain.data(), plain.size(), newline, 2));
  const uint16_t backwards[] = {1, 0};
  assert(!ul::ValidateGlyphSources(plain.data(), plain.size(), backwards, 2));
  const uint16_t past[] = {4};
  assert(!ul::ValidateGlyphSources(plain.data(), plain.size(), past, 1));
  // Readability.
  assert(ul::FungusTextReadable(true, false, 1.0f, 1.0f));
  assert(!ul::FungusTextReadable(false, false, 1.0f, 1.0f));
  assert(!ul::FungusTextReadable(true, true, 1.0f, 1.0f));      // culled
  assert(!ul::FungusTextReadable(true, false, 0.3f, 1.0f));     // faded out
  assert(!ul::FungusTextReadable(true, false, 1.0f, 0.0f));     // colour a=0
}

// ── per-line voice (unity_mono_audio.h) ─────────────────────────────────────

struct AudioWorld {
  FakeType tvoid = T(kMonoTypeVoid), tclass = T(kMonoTypeClass),
           tr4 = T(kMonoTypeSingle), tu8 = T(ua::kMonoTypeU8),
           tr8 = T(ua::kMonoTypeR8), tstring = T(kMonoTypeString),
           tintptr = T(ul::kMonoTypeI);
  FakeClass source{"UnityEngine", "AudioSource"};
  FakeClass unity_object{"UnityEngine", "Object"};
  FakeClass writer_audio{"Fungus", "WriterAudio"};
  std::vector<FakeImage> images;

  static FakeMethod Icall(const char* name, bool instance, FakeType* ret,
                          std::vector<FakeType*> params) {
    return {name, instance, ret, std::move(params), ul::kMethodImplInternalCall,
            0};
  }
  static FakeMethod Managed(const char* name, FakeType* ret,
                            std::vector<FakeType*> params) {
    return {name, true, ret, std::move(params), 0u, 0};
  }

  AudioWorld() {
    // 2019+ player: the public methods are managed wrappers.
    source.methods = {
        Managed("Play", &tvoid, {}),
        Managed("Play", &tvoid, {&tu8}),
        Managed("PlayOneShot", &tvoid, {&tclass, &tr4}),
        Icall("PlayHelper", false, &tvoid, {&tclass, &tu8}),
        Icall("Play", true, &tvoid, {&tr8}),
        Icall("PlayOneShotHelper", false, &tvoid, {&tclass, &tclass, &tr4}),
        Icall("get_clip", true, &tclass, {})};
    unity_object.fields = {{"m_CachedPtr", &tintptr, 2 * kPtr}};
    unity_object.methods = {Icall("GetName", false, &tstring, {&tclass})};
    writer_audio.methods = {Managed("OnGlyph", &tvoid, {}),
                            Managed("OnStart", &tvoid, {&tclass}),
                            Managed("OnVoiceover", &tvoid, {&tclass})};
    images = {{"UnityEngine.CoreModule", {&unity_object}},
              {"UnityEngine.AudioModule", {&source}},
              {"Fungus", {&writer_audio}}};
    g_images = &images;
  }
};

void TestAudioSites() {
  {
    AudioWorld w;
    ua::AudioSites sites;
    assert(ua::ResolveAudioSites(Api(), LookupApi(), &sites) ==
           ua::AudioSiteResult::kResolved);
    const auto at = [&](ua::AudioIcall id) {
      return sites.icalls[static_cast<size_t>(id)];
    };
    assert(at(ua::AudioIcall::kPlayOneShotHelper) ==
           &w.source.methods[5].entry_tag);
    assert(at(ua::AudioIcall::kPlayHelper) == &w.source.methods[3].entry_tag);
    // Play(double) is the extern; the managed Play(ulong) wrapper is not.
    assert(at(ua::AudioIcall::kPlayDelayed) == &w.source.methods[4].entry_tag);
    assert(at(ua::AudioIcall::kLegacyPlay) == nullptr);
    assert(at(ua::AudioIcall::kLegacyPlayOneShot) == nullptr);
    assert(at(ua::AudioIcall::kGetClip) == &w.source.methods[6].entry_tag);
    assert(sites.get_name == &w.unity_object.methods[0].entry_tag);
    assert(sites.cached_ptr_offset == 2 * kPtr);
    assert(sites.HasWriterAudio());
    assert(sites.writer_audio[static_cast<size_t>(
               ua::WriterAudioMethod::kOnVoiceover)] ==
           &w.writer_audio.methods[2]);
  }
  {
    // Pre-2018 player: PlayOneShot / Play(ulong) are the externs themselves.
    AudioWorld w;
    w.source.methods = {
        AudioWorld::Icall("Play", true, &w.tvoid, {&w.tu8}),
        AudioWorld::Icall("PlayOneShot", true, &w.tvoid, {&w.tclass, &w.tr4}),
        AudioWorld::Icall("get_clip", true, &w.tclass, {})};
    ua::AudioSites sites;
    assert(ua::ResolveAudioSites(Api(), LookupApi(), &sites) ==
           ua::AudioSiteResult::kResolved);
    assert(sites.icalls[static_cast<size_t>(ua::AudioIcall::kLegacyPlay)] ==
           &w.source.methods[0].entry_tag);
    assert(sites.icalls[static_cast<size_t>(
               ua::AudioIcall::kLegacyPlayOneShot)] ==
           &w.source.methods[1].entry_tag);
  }
  {
    AudioWorld w;  // no playback binding at all
    w.source.methods.resize(3);
    ua::AudioSites sites;
    assert(ua::ResolveAudioSites(Api(), LookupApi(), &sites) ==
           ua::AudioSiteResult::kNoPlayback);
  }
  {
    AudioWorld w;  // PlayHelper carries no clip: needs get_clip
    w.source.methods.pop_back();
    ua::AudioSites sites;
    assert(ua::ResolveAudioSites(Api(), LookupApi(), &sites) ==
           ua::AudioSiteResult::kNoClipGetter);
  }
  {
    AudioWorld w;
    w.unity_object.fields.clear();
    ua::AudioSites sites;
    assert(ua::ResolveAudioSites(Api(), LookupApi(), &sites) ==
           ua::AudioSiteResult::kNoObjectName);
  }
  {
    // Fungus absent, or a WriterAudio without the voiceover call: playback
    // still resolves, the typing exclusion is off, nothing half-installed.
    AudioWorld w;
    w.writer_audio.methods.pop_back();
    ua::AudioSites sites;
    assert(ua::ResolveAudioSites(Api(), LookupApi(), &sites) ==
           ua::AudioSiteResult::kResolved);
    assert(!sites.HasWriterAudio());
    for (void* m : sites.writer_audio) assert(m == nullptr);
    w.images.pop_back();
    assert(ua::ResolveAudioSites(Api(), LookupApi(), &sites) ==
           ua::AudioSiteResult::kResolved);
    assert(!sites.HasWriterAudio());
  }
}

void TestAudioDecisions() {
  // Typing sounds (inside WriterAudio.OnGlyph / OnStart) are never voice.
  assert(ua::IsVoiceCandidate(0u, 0));
  assert(!ua::IsVoiceCandidate(0u, 1));
  assert(ua::IsVoiceCandidate(ua::kAudioFlagFungusVoiceover, 1));
  // Without any *voice*.bundle evidence only the framework's voiceover goes.
  assert(!ua::ShouldPublishAudioEvent(0u, false));
  assert(ua::ShouldPublishAudioEvent(0u, true));
  assert(ua::ShouldPublishAudioEvent(ua::kAudioFlagFungusVoiceover, false));
  // The same clip restarted within 100 ms is one playback.
  ua::RecentClip recent;
  assert(!ua::IsDuplicatePlayback(&recent, L"sce_0001", 1000));
  assert(ua::IsDuplicatePlayback(&recent, L"sce_0001", 1050));
  assert(!ua::IsDuplicatePlayback(&recent, L"sce_0001", 1200));
  assert(!ua::IsDuplicatePlayback(&recent, L"sce_0002", 1210));
  assert(!ua::IsDuplicatePlayback(&recent, L"sce_0001", 1220));
}


// ── framework 3: a bare TextMeshPro UGUI text ───────────────────────────────

void* FakeClassParent(void* klass) {
  return static_cast<FakeClass*>(klass)->parent;
}
struct FakeObject {
  FakeClass* klass;
};
void* FakeObjectClass(void* object) {
  return static_cast<FakeObject*>(object)->klass;
}

ul::MonoClassHierarchyApi ClassApi() {
  ul::MonoClassHierarchyApi api;
  api.class_get_parent = &FakeClassParent;
  api.object_get_class = &FakeObjectClass;
  return api;
}

// A TMP 3.0-shaped world (field names / types from the com.unity.textmeshpro
// 1.4 and 3.0 sources; offsets are arbitrary but mono-shaped: instance and
// value-type fields reported after a two-pointer header).
struct TmpWorld {
  FakeType tvoid = T(kMonoTypeVoid), tbool = T(kMonoTypeBoolean),
           ti4 = T(ul::kMonoTypeI4), tr4 = T(kMonoTypeSingle),
           tchar = T(ul::kMonoTypeChar), tu1 = T(ul::kMonoTypeU1),
           tstring = T(kMonoTypeString), tclass = T(kMonoTypeClass),
           tintptr = T(ul::kMonoTypeI), tvalue = T(ul::kMonoTypeValueType),
           tvalue_ref = T(ul::kMonoTypeValueType, true);
  FakeClass graphic{"UnityEngine.UI", "MaskableGraphic"};
  FakeClass tmp_text{"TMPro", "TMP_Text"};
  FakeClass ugui{"TMPro", "TextMeshProUGUI"};
  FakeClass tmp_3d{"TMPro", "TextMeshPro"};
  FakeClass text_info{"TMPro", "TMP_TextInfo"};
  FakeClass char_info{"TMPro", "TMP_CharacterInfo"};
  FakeClass char_array{"", "TMP_CharacterInfo[]"};
  FakeClass color{"UnityEngine", "Color"};
  FakeClass color32{"UnityEngine", "Color32"};
  FakeClass vector3{"UnityEngine", "Vector3"};
  FakeClass canvas{"UnityEngine", "Canvas"};
  FakeClass renderer{"UnityEngine", "CanvasRenderer"};
  FakeClass unity_object{"UnityEngine", "Object"};
  FakeClass component{"UnityEngine", "Component"};
  FakeClass behaviour{"UnityEngine", "Behaviour"};
  FakeClass transform{"UnityEngine", "Transform"};
  FakeClass camera{"UnityEngine", "Camera"};
  FakeClass screen{"UnityEngine", "Screen"};
  FakeType t_text_info, t_color, t_color32, t_vector3, t_canvas, t_renderer,
      t_char_items;
  std::vector<FakeImage> images;

  static FakeMethod Icall(const char* name, bool instance, FakeType* ret,
                          std::vector<FakeType*> params) {
    return {name, instance, ret, std::move(params), ul::kMethodImplInternalCall,
            0};
  }

  TmpWorld() {
    t_text_info = T(kMonoTypeClass, false, &text_info);
    t_color = T(ul::kMonoTypeValueType, false, &color);
    t_color32 = T(ul::kMonoTypeValueType, false, &color32);
    t_vector3 = T(ul::kMonoTypeValueType, false, &vector3);
    t_canvas = T(kMonoTypeClass, false, &canvas);
    t_renderer = T(kMonoTypeClass, false, &renderer);
    char_array.element = &char_info;
    t_char_items = T(ul::kMonoTypeSzArray, false, &char_array);
    tmp_text.parent = &graphic;
    ugui.parent = &tmp_text;
    tmp_3d.parent = &tmp_text;
    tmp_text.fields = {{"m_text", &tstring, 40 * kPtr},
                       {"m_fontColor", &t_color, 300},
                       {"m_firstVisibleCharacter", &ti4, 400},
                       {"m_maxVisibleCharacters", &ti4, 404},
                       {"m_textInfo", &t_text_info, 60 * kPtr}};
    ugui.fields = {{"m_canvasRenderer", &t_renderer, 90 * kPtr},
                   {"m_canvas", &t_canvas, 91 * kPtr}};
    text_info.fields = {{"characterCount", &ti4, 3 * kPtr},
                        {"characterInfo", &t_char_items, 8 * kPtr}};
    // TMP_CharacterInfo: character @0, bottomLeft @136, topRight @148,
    // color @188, isVisible @228, stride 232 (the stride and every offset
    // come from mono at run time, never from these numbers).
    char_info.fields = {{"character", &tchar, kHdr},
                        {"index", &ti4, kHdr + 4},
                        {"bottomLeft", &t_vector3, kHdr + 136},
                        {"topRight", &t_vector3, kHdr + 148},
                        {"color", &t_color32, kHdr + 188},
                        {"isVisible", &tbool, kHdr + 228}};
    char_info.value_size = 232;
    color.fields = {{"r", &tr4, kHdr}, {"g", &tr4, kHdr + 4},
                    {"b", &tr4, kHdr + 8}, {"a", &tr4, kHdr + 12}};
    color.value_size = 16;
    // Unity 2018+: explicit layout with an overlapping `rgba` int.
    color32.fields = {{"rgba", &ti4, kHdr}, {"r", &tu1, kHdr},
                      {"g", &tu1, kHdr + 1}, {"b", &tu1, kHdr + 2},
                      {"a", &tu1, kHdr + 3}};
    color32.value_size = 4;
    vector3.fields = {{"x", &tr4, kHdr}, {"y", &tr4, kHdr + 4},
                      {"z", &tr4, kHdr + 8}};
    vector3.value_size = 12;
    unity_object.fields = {{"m_CachedPtr", &tintptr, 2 * kPtr}};
    component.methods = {Icall("get_transform", true, &tclass, {})};
    behaviour.methods = {Icall("get_enabled", true, &tbool, {}),
                         Icall("get_isActiveAndEnabled", true, &tbool, {})};
    transform.methods = {Icall("get_localToWorldMatrix_Injected", true, &tvoid,
                               {&tvalue_ref})};
    canvas.methods = {
        {"SendPreWillRenderCanvases", false, &tvoid, {}, 0, 0},
        {"SendWillRenderCanvases", false, &tvoid, {}, 0, 0},
        Icall("get_rootCanvas", true, &tclass, {}),
        Icall("get_renderMode", true, &tvalue, {}),
        Icall("get_worldCamera", true, &tclass, {})};
    renderer.methods = {Icall("GetInheritedAlpha", true, &tr4, {}),
                        Icall("get_cull", true, &tbool, {})};
    camera.methods = {Icall("WorldToScreenPoint_Injected", true, &tvoid,
                            {&tvalue_ref, &tvalue, &tvalue_ref}),
                      Icall("get_targetTexture", true, &tclass, {})};
    screen.methods = {Icall("get_width", false, &ti4, {}),
                      Icall("get_height", false, &ti4, {})};
    images = {{"UnityEngine.CoreModule",
               {&unity_object, &component, &behaviour, &transform, &camera,
                &screen, &color, &color32, &vector3}},
              {"UnityEngine.UIModule", {&canvas, &renderer}},
              {"UnityEngine.UI", {&graphic}},
              {"Unity.TextMeshPro",
               {&tmp_text, &ugui, &tmp_3d, &text_info, &char_info}},
              {"Assembly-CSharp", {}}};
    g_images = &images;
  }
};

ul::TmpSiteResolution ResolveTmp(ul::TmpSites* sites) {
  return ul::ResolveTmpSites(Api(), LookupApi(), SizeApi(), ClassApi(), sites);
}

void TestTmpResolvesUguiShape() {
  TmpWorld world;
  ul::TmpSites sites;
  const auto result = ResolveTmp(&sites);
  assert(result.result == ul::TmpSiteResult::kResolved);
  // The managed SendWillRenderCanvases, not its Pre* sibling.
  assert(sites.will_render == &world.canvas.methods[1]);
  assert(sites.ugui_class == &world.ugui);
  assert(sites.text_string_offset == 40 * kPtr &&
         sites.text_info_offset == 60 * kPtr);
  assert(sites.font_alpha_offset == 312);  // m_fontColor @300 + a @12
  assert(sites.first_visible_offset == 400 && sites.max_visible_offset == 404);
  assert(sites.canvas_offset == 91 * kPtr &&
         sites.renderer_offset == 90 * kPtr);
  assert(sites.info_count_offset == 3 * kPtr &&
         sites.info_chars_offset == 8 * kPtr);
  assert(sites.char_stride == 232 && sites.char_character_offset == 0 &&
         sites.char_bottom_left_offset == 136 &&
         sites.char_top_right_offset == 148 &&
         sites.char_visible_offset == 228);
  assert(sites.char_alpha_offset == 191);  // color @188 + a @3
  assert(sites.cached_ptr_offset == 2 * kPtr);
  // Behaviour.get_isActiveAndEnabled, not get_enabled.
  assert(sites.icalls[static_cast<size_t>(
             ul::TmpIcall::kBehaviourActiveAndEnabled)].entry ==
         &world.behaviour.methods[1].entry_tag);
  for (const auto& binding : sites.icalls) {
    assert(binding.entry != nullptr &&
           binding.form == ul::IcallForm::kClassic);
  }
}

void ExpectTmpFailure(TmpWorld& world, ul::TmpSiteResult expected) {
  g_images = &world.images;
  ul::TmpSites sites;
  const auto result = ResolveTmp(&sites);
  if (result.result != expected) {
    std::printf("tmp expected %u got %u\n", static_cast<unsigned>(expected),
                static_cast<unsigned>(result.result));
  }
  assert(result.result == expected);
}

void TestTmpFailClosedBranches() {
  {
    TmpWorld w;  // no TextMeshProUGUI (3D TextMeshPro only)
    w.images[3].classes = {&w.tmp_text, &w.tmp_3d, &w.text_info, &w.char_info};
    ExpectTmpFailure(w, ul::TmpSiteResult::kNoTmpClasses);
  }
  {
    TmpWorld w;  // a TextMeshProUGUI that is not a TMP_Text
    w.ugui.parent = &w.graphic;
    ExpectTmpFailure(w, ul::TmpSiteResult::kNoTmpClasses);
  }
  {
    TmpWorld w;  // TMP_Text in two images (two TMP copies): ambiguous
    FakeClass twin{"TMPro", "TMP_Text"};
    w.images[4].classes.push_back(&twin);
    ExpectTmpFailure(w, ul::TmpSiteResult::kNoTmpClasses);
  }
  {
    TmpWorld w;
    w.canvas.methods.erase(w.canvas.methods.begin() + 1);
    ExpectTmpFailure(w, ul::TmpSiteResult::kNoWillRender);
  }
  {
    TmpWorld w;  // an internal call has no managed body to detour
    w.canvas.methods[1].iflags = ul::kMethodImplInternalCall;
    ExpectTmpFailure(w, ul::TmpSiteResult::kNoWillRender);
  }
  {
    TmpWorld w;  // an instance method of the same name is not the hook
    w.canvas.methods[1].instance = true;
    ExpectTmpFailure(w, ul::TmpSiteResult::kNoWillRender);
  }
  {
    TmpWorld w;
    w.tmp_text.fields[0].type = &w.ti4;  // m_text must be a string
    ExpectTmpFailure(w, ul::TmpSiteResult::kTextFieldsMissing);
  }
  {
    TmpWorld w;  // m_textInfo typed as another class
    FakeType other = T(kMonoTypeClass, false, &w.char_info);
    w.tmp_text.fields[4].type = &other;
    ExpectTmpFailure(w, ul::TmpSiteResult::kTextFieldsMissing);
  }
  {
    TmpWorld w;  // m_fontColor as Color32 is not the Color the colour uses
    w.tmp_text.fields[1].type = &w.t_color32;
    ExpectTmpFailure(w, ul::TmpSiteResult::kTextFieldsMissing);
  }
  {
    TmpWorld w;
    w.tmp_text.fields[3].name = "m_maxVisibleWords";
    ExpectTmpFailure(w, ul::TmpSiteResult::kTextFieldsMissing);
  }
  {
    TmpWorld w;  // m_canvas declared nowhere on TextMeshProUGUI
    w.ugui.fields.pop_back();
    ExpectTmpFailure(w, ul::TmpSiteResult::kUguiFieldsMissing);
  }
  {
    TmpWorld w;  // m_canvasRenderer typed Canvas
    w.ugui.fields[0].type = &w.t_canvas;
    ExpectTmpFailure(w, ul::TmpSiteResult::kUguiFieldsMissing);
  }
  {
    TmpWorld w;
    w.text_info.fields[0].type = &w.tr4;  // characterCount must be an int
    ExpectTmpFailure(w, ul::TmpSiteResult::kTextInfoMissing);
  }
  {
    TmpWorld w;  // characterInfo[] of another element type
    FakeClass vertex{"TMPro", "TMP_Vertex"};
    w.char_array.element = &vertex;
    ExpectTmpFailure(w, ul::TmpSiteResult::kTextInfoMissing);
  }
  {
    TmpWorld w;  // a stride that cannot hold isVisible
    w.char_info.value_size = 200;
    ExpectTmpFailure(w, ul::TmpSiteResult::kCharLayoutMismatch);
  }
  {
    TmpWorld w;  // Vector3 not 12 bytes
    w.vector3.value_size = 16;
    ExpectTmpFailure(w, ul::TmpSiteResult::kCharLayoutMismatch);
  }
  {
    TmpWorld w;  // bottomLeft typed as Color
    w.char_info.fields[2].type = &w.t_color;
    ExpectTmpFailure(w, ul::TmpSiteResult::kCharLayoutMismatch);
  }
  {
    TmpWorld w;  // character as int (a UTF-32 build) is not this layout
    w.char_info.fields[0].type = &w.ti4;
    ExpectTmpFailure(w, ul::TmpSiteResult::kCharLayoutMismatch);
  }
  {
    TmpWorld w;  // Color32 without a byte `a`
    w.color32.fields.pop_back();
    ExpectTmpFailure(w, ul::TmpSiteResult::kCharLayoutMismatch);
  }
  {
    TmpWorld w;
    w.unity_object.fields.clear();
    ExpectTmpFailure(w, ul::TmpSiteResult::kObjectFieldMissing);
  }
  {
    TmpWorld w;  // `out Matrix4x4` must be by-ref
    w.transform.methods[0].params = {&w.tvalue};
    ExpectTmpFailure(w, ul::TmpSiteResult::kIcallMissing);
  }
  {
    TmpWorld w;  // a managed GetInheritedAlpha is not the binding
    w.renderer.methods[0].iflags = 0u;
    ul::TmpSites sites;
    const auto result = ResolveTmp(&sites);
    assert(result.result == ul::TmpSiteResult::kIcallMissing);
    assert(result.missing_icall ==
           static_cast<int32_t>(ul::TmpIcall::kCanvasRendererInheritedAlpha));
  }
  {
    TmpWorld w;  // pre-2018 player: no _Injected world-to-screen binding
    w.camera.methods[0].name = "INTERNAL_CALL_WorldToScreenPoint";
    ExpectTmpFailure(w, ul::TmpSiteResult::kIcallMissing);
  }
  {
    TmpWorld w;
    ul::TmpSites sites;
    ul::MonoClassHierarchyApi none;
    assert(ul::ResolveTmpSites(Api(), LookupApi(), SizeApi(), none, &sites)
               .result == ul::TmpSiteResult::kApiIncomplete);
    ul::MonoValueSizeApi no_sizes;
    assert(ul::ResolveTmpSites(Api(), LookupApi(), no_sizes, ClassApi(),
                               &sites)
               .result == ul::TmpSiteResult::kApiIncomplete);
  }
}

void TestTmpHierarchy() {
  TmpWorld w;
  const ul::MonoClassHierarchyApi classes = ClassApi();
  FakeClass derived{"Game", "DialogueText"};  // a game's own subclass
  derived.parent = &w.ugui;
  assert(ul::ClassDerivesFrom(classes, &w.ugui, &w.ugui));
  assert(ul::ClassDerivesFrom(classes, &derived, &w.ugui));
  assert(ul::ClassDerivesFrom(classes, &w.ugui, &w.tmp_text));
  // A 3D TextMeshPro shares TMP_Text but not TextMeshProUGUI's offsets.
  assert(!ul::ClassDerivesFrom(classes, &w.tmp_3d, &w.ugui));
  assert(!ul::ClassDerivesFrom(classes, nullptr, &w.ugui));
  assert(!ul::ClassDerivesFrom(classes, &w.ugui, nullptr));
  // A malformed (cyclic) parent chain terminates and is not a match.
  FakeClass a{"X", "A"}, b{"X", "B"};
  a.parent = &b;
  b.parent = &a;
  assert(!ul::ClassDerivesFrom(classes, &a, &w.ugui));
  FakeObject object{&derived};
  assert(classes.object_get_class(&object) == &derived);
}

void TestTmpCharacterShown() {
  // Revealed, opaque, inside the default range.
  assert(ul::TmpCharacterShown(true, 0, 0, 99999, 255));
  // TMP's own isVisible false (whitespace, cut by maxVisibleLines / page).
  assert(!ul::TmpCharacterShown(false, 0, 0, 99999, 255));
  // Typewriter: maxVisibleCharacters 3 shows 0..2.
  assert(ul::TmpCharacterShown(true, 2, 0, 3, 255));
  assert(!ul::TmpCharacterShown(true, 3, 0, 3, 255));
  assert(!ul::TmpCharacterShown(true, 0, 0, 0, 255));
  // firstVisibleCharacter.
  assert(!ul::TmpCharacterShown(true, 1, 2, 99999, 255));
  assert(ul::TmpCharacterShown(true, 2, 2, 99999, 255));
  assert(!ul::TmpCharacterShown(true, 0, -1, 99999, 255));
  // An <alpha=#00> span / a fade below half.
  assert(!ul::TmpCharacterShown(true, 0, 0, 99999, 0));
  assert(!ul::TmpCharacterShown(true, 0, 0, 99999, 127));
  assert(ul::TmpCharacterShown(true, 0, 0, 99999, 128));
}

void TestTmpChooseMatch() {
  size_t chosen = 99;
  // One readable match.
  ul::TmpMatch one[] = {{true, false}};
  assert(ul::ChooseTmpMatch(one, 1, &chosen) == ul::TmpChoice::kChosen &&
         chosen == 0);
  // Body + an inactive / alpha-0 shadow copy: the readable one.
  ul::TmpMatch shadow_hidden[] = {{false, true}, {true, false}};
  assert(ul::ChooseTmpMatch(shadow_hidden, 2, &chosen) ==
             ul::TmpChoice::kChosen &&
         chosen == 1);
  // Both readable (a drawn shadow): the one whose lane the host selected.
  ul::TmpMatch both[] = {{true, false}, {true, true}};
  assert(ul::ChooseTmpMatch(both, 2, &chosen) == ul::TmpChoice::kChosen &&
         chosen == 1);
  // Both readable, neither / both selected: fail closed.
  ul::TmpMatch neither[] = {{true, false}, {true, false}};
  assert(ul::ChooseTmpMatch(neither, 2, &chosen) == ul::TmpChoice::kAmbiguous);
  ul::TmpMatch twice[] = {{true, true}, {true, true}};
  assert(ul::ChooseTmpMatch(twice, 2, &chosen) == ul::TmpChoice::kAmbiguous);
  // Nothing readable.
  ul::TmpMatch none[] = {{false, false}, {false, true}};
  assert(ul::ChooseTmpMatch(none, 2, &chosen) ==
         ul::TmpChoice::kNoneReadable);
  assert(ul::ChooseTmpMatch(nullptr, 0, &chosen) ==
         ul::TmpChoice::kNoneReadable);
  // Slot order does not decide: the selected lane wins wherever it sits.
  ul::TmpMatch reversed[] = {{true, true}, {true, false}};
  assert(ul::ChooseTmpMatch(reversed, 2, &chosen) == ul::TmpChoice::kChosen &&
         chosen == 0);
}

void TestTmpGeometry() {
  // A TMP UGUI text on a Screen Space - Overlay canvas: localToWorld scales
  // by 1.5 and translates to (200, 160); characterInfo quads are local.
  ul::Matrix4 m;
  m.m[0] = 1.5f; m.m[5] = 1.5f; m.m[10] = 1.0f; m.m[15] = 1.0f;
  m.m[12] = 200.0f; m.m[13] = 160.0f;
  // Character 1: bottomLeft (32, -40), topRight (64, -4).
  const ul::Vec3 a = ul::TransformPoint(m, 32.0f, -40.0f);
  const ul::Vec3 b = ul::TransformPoint(m, 64.0f, -4.0f);
  ul::GlyphCell cell;
  assert(ul::CellFromScreenCorners(a, b, true, &cell));
  assert(cell.x0 == 248 && cell.x1 == 296 && cell.y0 == 100 && cell.y1 == 154);
  // Unity screen 1280x720 -> physical client 2560x1440 (192 dpi):
  // x 496..592, y (720-154)*2 = 1132 .. (720-100)*2 = 1240.
  ul::PixelRect rect;
  assert(ul::ProjectCell(cell, 1280, 720, 2560, 1440, &rect));
  assert(rect.x == 496 && rect.y == 1132 && rect.w == 96 && rect.h == 108);
  // A quad hanging off the screen bottom is refused, not clipped.
  const ul::Vec3 low = ul::TransformPoint(m, 32.0f, -200.0f);
  ul::GlyphCell off;
  assert(ul::CellFromScreenCorners(low, b, true, &off));
  assert(!ul::ProjectCell(off, 1280, 720, 2560, 1440, &rect));
  // A degenerate quad yields no cell.
  assert(!ul::CellFromScreenCorners(a, a, true, &off));
  // Glyph sources: the characterInfo index, skipping line feeds.
  const std::wstring shown = L"あい\nう";
  const uint16_t sources[] = {0, 1, 3};
  assert(ul::ValidateGlyphSources(shown.data(), shown.size(), sources, 3));
  const uint16_t line_feed[] = {0, 2};
  assert(!ul::ValidateGlyphSources(shown.data(), shown.size(), line_feed, 2));
  // Hit test on the projected cells (they touch at x = 248).
  ul::GlyphCell cells[2];
  assert(ul::CellFromScreenCorners(ul::TransformPoint(m, 0.0f, -40.0f),
                                   ul::TransformPoint(m, 32.0f, -4.0f), true,
                                   &cells[0]));
  cells[1] = cell;
  cells[0].visible = 1u;
  cells[1].visible = 1u;
  const uint16_t hit_sources[] = {0, 1};
  size_t hit = 9;
  assert(ul::HitTestCells(cells, hit_sources, 2, 250.0f, 120.0f, &hit) &&
         hit == 1);
  assert(ul::HitTestCells(cells, hit_sources, 2, 210.0f, 120.0f, &hit) &&
         hit == 0);
  assert(!ul::HitTestCells(cells, hit_sources, 2, 300.0f, 120.0f, &hit));
}

// ── Unity 6 engine binding forms ────────────────────────────────────────────
//
// Unity 6's bindings generator turns every engine member that needs
// marshalling into managed code over `private static extern <R'>
// <method>_Injected(IntPtr _unity_self, <params>)` (an object result as
// IntPtr = the GC handle); a static member without marshalling keeps its
// classic extern (Screen.get_width).  ToUnity6 rewrites a fake class the same
// way and leaves the managed wrapper under the classic name.

bool EndsWith(const std::string& s, const char* suffix) {
  const size_t n = std::strlen(suffix);
  return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

void ToUnity6(FakeClass& klass, FakeType* intptr) {
  std::vector<FakeMethod> wrappers;
  for (FakeMethod& m : klass.methods) {
    if ((m.iflags & ul::kMethodImplInternalCall) == 0u) continue;
    const bool object_result = m.ret->kind == kMonoTypeClass;
    if (!m.instance && !object_result) continue;  // no marshalling: unchanged
    FakeMethod wrapper = m;
    wrapper.iflags = 0u;  // the managed property / method body
    if (!EndsWith(m.name, "_Injected")) {
      wrappers.push_back(wrapper);
      m.name += "_Injected";
    }
    if (m.instance) m.params.insert(m.params.begin(), intptr);
    m.instance = false;
    if (object_result) m.ret = intptr;
  }
  klass.methods.insert(klass.methods.end(), wrappers.begin(), wrappers.end());
}

void* FakeGcTarget(void* handle) {
  // A fake GC handle is the address of a slot holding the target.
  return handle == nullptr ? nullptr : *static_cast<void**>(handle);
}
std::vector<void*> g_freed_handles;
void FakeGcFree(void* handle) { g_freed_handles.push_back(handle); }

ul::MonoLookupApi Unity6LookupApi() {
  ul::MonoLookupApi api = LookupApi();
  api.gchandle_get_target = &FakeGcTarget;
  api.gchandle_free = &FakeGcFree;
  return api;
}

constexpr uint32_t kInstanceId = 3 * kPtr;
constexpr uint32_t kGeneratorPtr = 2 * kPtr;

void Unity6Tmp(TmpWorld& w) {
  w.unity_object.fields.push_back({"m_InstanceID", &w.ti4, kInstanceId});
  for (FakeClass* klass : {&w.component, &w.behaviour, &w.transform,
                           &w.canvas, &w.renderer, &w.camera, &w.screen}) {
    ToUnity6(*klass, &w.tintptr);
  }
}

void Unity6Fungus(FungusWorld& w) {
  w.unity_object.fields.push_back({"m_InstanceID", &w.ti4, kInstanceId});
  w.generator.fields.push_back({"m_Ptr", &w.tintptr, kGeneratorPtr});
  for (FakeClass* klass :
       {&w.component, &w.behaviour, &w.transform, &w.canvas, &w.renderer,
        &w.font, &w.generator, &w.camera, &w.screen}) {
    ToUnity6(*klass, &w.tintptr);
  }
}

void Unity6Message(World& w) {
  w.unity_object.fields.push_back({"m_InstanceID", &w.ti4, kInstanceId});
  for (FakeClass* klass : {&w.game_object, &w.camera, &w.screen, &w.renderer,
                           &w.scene_manager}) {
    ToUnity6(*klass, &w.tintptr);
  }
}

const FakeMethod* FindFake(const FakeClass& klass, const char* name) {
  for (const FakeMethod& m : klass.methods) {
    if (m.name == name && (m.iflags & ul::kMethodImplInternalCall) != 0u) {
      return &m;
    }
  }
  return nullptr;
}

void TestInjectedShape() {
  char name[ul::kInjectedNameChars] = {};
  ul::IcallShape shape;
  // get_transform: name gains the suffix, static, IntPtr self, IntPtr result.
  assert(ul::InjectedShape(ul::kTmpIcallSpecs[0], name, sizeof(name), &shape));
  assert(std::strcmp(shape.method, "get_transform_Injected") == 0);
  assert(!shape.instance && shape.return_type == ul::kMonoTypeI &&
         shape.param_count == 1 && shape.params[0] == ul::kMonoTypeI &&
         shape.byref_mask == 0u);
  // WorldToScreenPoint_Injected keeps its name; ref / out bits shift past
  // the self parameter: (IntPtr, ref Vector3, eye, out Vector3).
  const auto& to_screen = ul::kTmpIcallSpecs[static_cast<size_t>(
      ul::TmpIcall::kCameraWorldToScreen)];
  assert(ul::InjectedShape(to_screen, name, sizeof(name), &shape));
  assert(std::strcmp(shape.method, "WorldToScreenPoint_Injected") == 0);
  assert(shape.param_count == 4 && shape.params[0] == ul::kMonoTypeI &&
         shape.params[1] == ul::kMonoTypeValueType &&
         shape.byref_mask == 0xau && shape.return_type == kMonoTypeVoid);
  // Camera.get_main: static, no self, object result as IntPtr.
  assert(ul::InjectedShape(ul::kIcallSpecs[0], name, sizeof(name), &shape));
  assert(std::strcmp(shape.method, "get_main_Injected") == 0 &&
         shape.param_count == 0 && shape.return_type == ul::kMonoTypeI);
  // SceneManager.GetActiveScene_Injected(out Scene) is the same in both
  // generations: no second form to look for.
  const auto& active = ul::kIcallSpecs[static_cast<size_t>(
      ul::Icall::kActiveScene)];
  assert(!ul::InjectedShape(active, name, sizeof(name), &shape));
}

void TestTmpResolvesUnity6Shape() {
  TmpWorld world;
  Unity6Tmp(world);
  ul::TmpSites sites;
  const auto result = ul::ResolveTmpSites(Api(), Unity6LookupApi(), SizeApi(),
                                          ClassApi(), &sites);
  assert(result.result == ul::TmpSiteResult::kResolved);
  char forms[ul::kTmpIcallCount + 1u] = {};
  ul::IcallFormString(sites.icalls, forms, sizeof(forms));
  // Every instance binding injected; Screen.width / height stay classic.
  assert(std::strcmp(forms, "iiiiiiiiiicc") == 0);
  const auto& transform =
      sites.icalls[static_cast<size_t>(ul::TmpIcall::kComponentTransform)];
  assert(transform.entry ==
         &FindFake(world.component, "get_transform_Injected")->entry_tag);
  assert(transform.instance && transform.object_result &&
         transform.self_offset == 2 * kPtr);
  const auto& alpha = sites.icalls[static_cast<size_t>(
      ul::TmpIcall::kCanvasRendererInheritedAlpha)];
  assert(alpha.form == ul::IcallForm::kInjected && !alpha.object_result);
  assert(sites.marshal.instance_id_offset == kInstanceId &&
         sites.marshal.CanUnmarshal());
}

void TestUnity6FailClosed() {
  {
    TmpWorld w;  // no pointer-sized GC handle reader: object results refused
    Unity6Tmp(w);
    ul::TmpSites sites;
    const auto result =
        ul::ResolveTmpSites(Api(), LookupApi(), SizeApi(), ClassApi(), &sites);
    assert(result.result == ul::TmpSiteResult::kIcallMissing);
    assert(result.missing_icall ==
           static_cast<int32_t>(ul::TmpIcall::kComponentTransform));
    assert(result.icall_failure == ul::IcallFailure::kGcHandleApi);
  }
  {
    TmpWorld w;  // no m_InstanceID: a fake-null result cannot be told apart
    Unity6Tmp(w);
    w.unity_object.fields.pop_back();
    ul::TmpSites sites;
    const auto result = ul::ResolveTmpSites(Api(), Unity6LookupApi(),
                                            SizeApi(), ClassApi(), &sites);
    assert(result.icall_failure == ul::IcallFailure::kGcHandleApi);
  }
  {
    TmpWorld w;  // the classic extern and the injected one side by side
    Unity6Tmp(w);
    w.component.methods.push_back(
        TmpWorld::Icall("get_transform", true, &w.tclass, {}));
    ul::TmpSites sites;
    const auto result = ul::ResolveTmpSites(Api(), Unity6LookupApi(),
                                            SizeApi(), ClassApi(), &sites);
    assert(result.result == ul::TmpSiteResult::kIcallMissing);
    assert(result.missing_icall ==
           static_cast<int32_t>(ul::TmpIcall::kComponentTransform));
    assert(result.icall_failure == ul::IcallFailure::kAmbiguous);
  }
  {
    TmpWorld w;  // an injected binding that is not an internal call
    Unity6Tmp(w);
    for (FakeMethod& m : w.behaviour.methods) {
      if (m.name == "get_isActiveAndEnabled_Injected") m.iflags = 0u;
    }
    ul::TmpSites sites;
    const auto result = ul::ResolveTmpSites(Api(), Unity6LookupApi(),
                                            SizeApi(), ClassApi(), &sites);
    assert(result.missing_icall ==
           static_cast<int32_t>(ul::TmpIcall::kBehaviourActiveAndEnabled));
    assert(result.icall_failure == ul::IcallFailure::kAbsent);
  }
  {
    TmpWorld w;  // injected self must be IntPtr, not the object
    Unity6Tmp(w);
    for (FakeMethod& m : w.renderer.methods) {
      if (m.name == "get_cull_Injected") m.params[0] = &w.tclass;
    }
    ul::TmpSites sites;
    const auto result = ul::ResolveTmpSites(Api(), Unity6LookupApi(),
                                            SizeApi(), ClassApi(), &sites);
    assert(result.missing_icall ==
           static_cast<int32_t>(ul::TmpIcall::kCanvasRendererCull));
    assert(result.icall_failure == ul::IcallFailure::kAbsent);
  }
  {
    FungusWorld w;  // TextGenerator's injected self is its own m_Ptr
    Unity6Fungus(w);
    w.generator.fields.pop_back();
    ul::FungusSites sites;
    const auto result =
        ul::ResolveFungusSites(Api(), Unity6LookupApi(), SizeApi(), &sites);
    assert(result.result == ul::FungusSiteResult::kIcallMissing);
    assert(result.missing_icall ==
           static_cast<int32_t>(ul::FungusIcall::kGeneratorCharacters));
    assert(result.icall_failure == ul::IcallFailure::kSelfField);
  }
}

void TestFungusResolvesUnity6Shape() {
  FungusWorld world;
  Unity6Fungus(world);
  ul::FungusSites sites;
  const auto result =
      ul::ResolveFungusSites(Api(), Unity6LookupApi(), SizeApi(), &sites);
  assert(result.result == ul::FungusSiteResult::kResolved);
  char forms[ul::kFungusIcallCount + 1u] = {};
  ul::IcallFormString(sites.icalls, forms, sizeof(forms));
  assert(std::strcmp(forms, "iiiiiiiiiiiiiiicc") == 0);
  const auto& chars = sites.icalls[static_cast<size_t>(
      ul::FungusIcall::kGeneratorCharacters)];
  assert(chars.self_offset == kGeneratorPtr && !chars.object_result);
  const auto& game_object = sites.icalls[static_cast<size_t>(
      ul::FungusIcall::kComponentGameObject)];
  assert(game_object.self_offset == 2 * kPtr && game_object.object_result);
}

void TestMessageResolvesUnity6Shape() {
  World world;
  Unity6Message(world);
  ul::Sites sites;
  const auto result =
      ul::ResolveSites(Api(), Unity6LookupApi(), nullptr, &sites);
  assert(result.result == ul::SiteResult::kResolved);
  char forms[ul::kIcallCount + 1u] = {};
  ul::IcallFormString(sites.icalls, forms, sizeof(forms));
  // get_main injected (static object result), Screen classic, the static
  // GetActiveScene_Injected(out Scene) the same in both generations.
  assert(std::strcmp(forms, "iiiiicciiiicii") == 0);
  const auto& main =
      sites.icalls[static_cast<size_t>(ul::Icall::kCameraMain)];
  assert(!main.instance && main.object_result);
  // GetComponent_Injected(IntPtr, Type): the Type argument stays an object.
  assert(sites.icalls[static_cast<size_t>(ul::Icall::kGameObjectGetComponent)]
             .entry == &FindFake(world.game_object, "GetComponent_Injected")
                            ->entry_tag);
}

// Fault-tolerant reads over plain memory (the runtime uses SEH reads).
bool ReadPtr(uintptr_t address, uintptr_t* out) {
  std::memcpy(out, reinterpret_cast<const void*>(address), sizeof(*out));
  return true;
}
bool ReadI32(uintptr_t address, int32_t* out) {
  std::memcpy(out, reinterpret_cast<const void*>(address), sizeof(*out));
  return true;
}

void TestBindingMarshalling() {
  alignas(8) unsigned char object[8 * sizeof(void*)] = {};
  void* const native_peer = reinterpret_cast<void*>(0x5150);
  std::memcpy(object + 2 * kPtr, &native_peer, sizeof(void*));
  int entry = 0;
  ul::IcallBinding classic;
  classic.entry = &entry;
  classic.form = ul::IcallForm::kClassic;
  classic.instance = true;
  ul::IcallBinding injected = classic;
  injected.form = ul::IcallForm::kInjected;
  injected.self_offset = 2 * kPtr;
  injected.object_result = true;
  void* self = nullptr;
  assert(ul::BindingSelf(classic, object, &ReadPtr, &self) && self == object);
  assert(ul::BindingSelf(injected, object, &ReadPtr, &self) &&
         self == native_peer);
  // A zero native peer (destroyed / never bound) is no call.
  alignas(8) unsigned char unbound[8 * sizeof(void*)] = {};
  assert(!ul::BindingSelf(injected, unbound, &ReadPtr, &self));
  assert(!ul::BindingSelf(injected, nullptr, &ReadPtr, &self));
  ul::IcallBinding unresolved;
  assert(!ul::BindingSelf(unresolved, object, &ReadPtr, &self));

  ul::UnityObjectMarshal marshal;
  marshal.cached_ptr_offset = 2 * kPtr;
  marshal.instance_id_offset = kInstanceId;
  marshal.gchandle_get_target = &FakeGcTarget;
  marshal.gchandle_free = &FakeGcFree;
  // A live result: the handle's target, the handle left to its native owner.
  alignas(8) unsigned char target[8 * sizeof(void*)] = {};
  const int32_t live_id = 4242;
  std::memcpy(target + kInstanceId, &live_id, sizeof(live_id));
  void* slot = target;
  g_freed_handles.clear();
  assert(ul::BindingObjectResult(injected, marshal, &slot, &ReadI32) ==
         target);
  assert(g_freed_handles.empty());
  // Classic: the value is the object.
  assert(ul::BindingObjectResult(classic, marshal, target, &ReadI32) ==
         target);
  // Null handle, null target.
  assert(ul::BindingObjectResult(injected, marshal, nullptr, &ReadI32) ==
         nullptr);
  void* empty_slot = nullptr;
  assert(ul::BindingObjectResult(injected, marshal, &empty_slot, &ReadI32) ==
         nullptr);
  // Fake null (instance ID 0): its handle is freed, the result is null.
  alignas(8) unsigned char fake_null[8 * sizeof(void*)] = {};
  void* fake_slot = fake_null;
  assert(ul::BindingObjectResult(injected, marshal, &fake_slot, &ReadI32) ==
         nullptr);
  assert(g_freed_handles.size() == 1u && g_freed_handles[0] == &fake_slot);
  // No reader: never dereference the handle as an object.
  ul::UnityObjectMarshal no_reader = marshal;
  no_reader.gchandle_get_target = nullptr;
  assert(ul::BindingObjectResult(injected, no_reader, &slot, &ReadI32) ==
         nullptr);
}

// Unity 2021.3 Mono player with managed code stripping (measured 2026-11-12:
// UnityEngine.UIModule.dll has CanvasRenderer.GetColor / GetColor_Injected /
// get_cull but neither GetInheritedAlpha nor the managed GetAlpha): the
// inherited CanvasGroup alpha is unreadable, so both canvas kinds refuse
// instead of treating every glyph as opaque.
void TestStrippedInheritedAlphaFailsClosed() {
  {
    TmpWorld w;
    w.renderer.methods = {
        TmpWorld::Icall("GetColor_Injected", true, &w.tvoid, {&w.tvalue_ref}),
        TmpWorld::Icall("get_cull", true, &w.tbool, {})};
    ul::TmpSites sites;
    const auto result = ResolveTmp(&sites);
    assert(result.result == ul::TmpSiteResult::kIcallMissing);
    assert(result.missing_icall ==
           static_cast<int32_t>(ul::TmpIcall::kCanvasRendererInheritedAlpha));
    assert(result.icall_failure == ul::IcallFailure::kAbsent);
    char forms[ul::kTmpIcallCount + 1u] = {};
    ul::IcallFormString(sites.icalls, forms, sizeof(forms));
    assert(std::strcmp(forms, "cccccc------") == 0);
  }
  {
    FungusWorld w;
    w.renderer.methods = {
        FungusWorld::Icall("GetColor_Injected", true, &w.tvoid,
                           {&w.tvalue_ref}),
        FungusWorld::Icall("get_cull", true, &w.tbool, {})};
    ul::FungusSites sites;
    void* will_render = nullptr;
    // The UI.Text canvas kind reads the same UGUI layout bindings.
    const auto result = ul::ResolveFungusSites(Api(), LookupApi(), SizeApi(),
                                               &sites);
    (void)will_render;
    assert(result.result == ul::FungusSiteResult::kIcallMissing);
    assert(result.missing_icall ==
           static_cast<int32_t>(
               ul::FungusIcall::kCanvasRendererInheritedAlpha));
    assert(result.icall_failure == ul::IcallFailure::kAbsent);
  }
}

}  // namespace

int main() {
  TestResolvesUnityShape();
  TestFailClosedBranches();
  TestVisibility();
  TestTextMapping();
  TestProjection();
  TestHitTest();
  TestClaim();
  TestRoleKey();
  TestFungusResolvesUguiShape();
  TestFungusFailClosedBranches();
  TestRichTextMap();
  TestFungusGeometry();
  TestAudioSites();
  TestAudioDecisions();
  TestTmpResolvesUguiShape();
  TestTmpFailClosedBranches();
  TestTmpHierarchy();
  TestTmpCharacterShown();
  TestTmpChooseMatch();
  TestTmpGeometry();
  TestUiTextResolvesUguiShape();
  TestUiTextFailClosedBranches();
  TestScreenAxesUpright();
  TestFirstUnitDifference();
  TestMatchShownToLineIgnoresLineBreaks();
  std::printf("unity_mono_lookup_test: ok\n");
  return 0;
}
