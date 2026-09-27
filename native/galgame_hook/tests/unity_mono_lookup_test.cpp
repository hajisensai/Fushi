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
             ul::FungusIcall::kBehaviourActiveAndEnabled)] ==
         &world.behaviour.methods[1].entry_tag);
  for (void* entry : sites.icalls) assert(entry != nullptr);
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
  std::printf("unity_mono_lookup_test: ok\n");
  return 0;
}
