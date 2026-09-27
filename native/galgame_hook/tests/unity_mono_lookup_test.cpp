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
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <string>
#include <utility>
#include <vector>

#include "adapters/unity_mono_lookup_core.h"

using namespace fushi_voice_hook;
namespace ul = fushi_voice_hook::unity_mono_lookup;

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
  assert(sites.icalls[static_cast<size_t>(ul::Icall::kGameObjectGetComponent)] ==
         &world.game_object.methods[2].entry_tag);
  for (void* entry : sites.icalls) assert(entry != nullptr);
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
  std::printf("unity_mono_lookup_test: ok\n");
  return 0;
}
