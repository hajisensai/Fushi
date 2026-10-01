// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

// Unity Mono 文本 setter 纯逻辑层的离线单测（不需要真 mono.dll）：
//   * 调用约定按架构选择，且与本构建一致；
//   * 方法解析表按「名字 + 实例/静态 + 返回类型 + 每个参数类型」精确匹配（TMP 的
//     SetText 有同参数个数的 (string,float) 重载排在前面）；
//   * Assembly-CSharp 未加载时不解析（等下一拍）；
//   * 逐字 TextMesh 消息框架（Message.Mes + Game.NewText 伴随判据）成立时改挂 Mes、
//     不挂 TextMesh；伴随判据缺失时不认同名 Message 类（负向）；
//   * TMP 两个入口成对才装；
//   * MonoString 只经注入的 accessor 读取并有界截断；
//   * attach 作用域配平。
#include <cassert>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <string>
#include <vector>

#include "../hook/adapters/unity_mono_text.h"

using namespace fushi_voice_hook;

namespace {

// 假类型：MonoType* 指向一个 int（MonoTypeEnum）。
int g_type_void = kMonoTypeVoid;
int g_type_bool = kMonoTypeBoolean;
int g_type_single = kMonoTypeSingle;
int g_type_string = kMonoTypeString;
int g_type_class = kMonoTypeClass;
int g_type_i4 = 0x08;

int* TypeFor(int kind) {
  switch (kind) {
    case kMonoTypeVoid: return &g_type_void;
    case kMonoTypeBoolean: return &g_type_bool;
    case kMonoTypeSingle: return &g_type_single;
    case kMonoTypeString: return &g_type_string;
    case kMonoTypeClass: return &g_type_class;
    default: return &g_type_i4;
  }
}

struct FakeMethod {
  const char* name;
  bool instance;
  int ret;
  std::vector<int> params;
  int compiled_tag;  // compile_method 返回 &compiled_tag
};

struct FakeClass {
  const char* ns;
  const char* name;
  std::vector<FakeMethod> methods;
};

struct FakeImage {
  const char* name;
  std::vector<FakeClass> classes;
};

// 程序集 == 镜像（一对一），user_data 直接是 FakeImage*。
std::vector<FakeImage>* g_images = nullptr;
int g_attach_calls = 0;
int g_detach_calls = 0;
void* g_attach_ret = nullptr;
void* g_last_detached = nullptr;
int g_compile_calls = 0;

void* FakeRootDomain() { return reinterpret_cast<void*>(0xD0); }
void* FakeAttach(void*) {
  ++g_attach_calls;
  return g_attach_ret;
}
void FakeDetach(void* thread) {
  ++g_detach_calls;
  g_last_detached = thread;
}
void FakeForeach(void (*func)(void*, void*), void* user_data) {
  for (FakeImage& image : *g_images) func(&image, user_data);
}
void* FakeAssemblyGetImage(void* assembly) { return assembly; }
const char* FakeImageName(void* image) {
  return static_cast<FakeImage*>(image)->name;
}
void* FakeClassFromName(void* image, const char* ns, const char* name) {
  for (FakeClass& klass : static_cast<FakeImage*>(image)->classes) {
    if (std::strcmp(klass.ns, ns) == 0 && std::strcmp(klass.name, name) == 0) {
      return &klass;
    }
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
const char* FakeMethodName(void* method) {
  return static_cast<FakeMethod*>(method)->name;
}
void* FakeMethodSignature(void* method) { return method; }
uint32_t FakeParamCount(void* sig) {
  return static_cast<uint32_t>(static_cast<FakeMethod*>(sig)->params.size());
}
void* FakeGetParams(void* sig, void** iter) {
  auto* m = static_cast<FakeMethod*>(sig);
  const size_t next = reinterpret_cast<size_t>(*iter);
  if (next >= m->params.size()) return nullptr;
  *iter = reinterpret_cast<void*>(next + 1);
  return TypeFor(m->params[next]);
}
void* FakeReturnType(void* sig) {
  return TypeFor(static_cast<FakeMethod*>(sig)->ret);
}
int32_t FakeIsInstance(void* sig) {
  return static_cast<FakeMethod*>(sig)->instance ? 1 : 0;
}
int FakeTypeGetType(void* type) { return *static_cast<int*>(type); }
void* FakeCompile(void* method) {
  ++g_compile_calls;
  return &static_cast<FakeMethod*>(method)->compiled_tag;
}

struct FakeString {
  int length;
  const wchar_t* chars;
};
int FakeStringLength(void* s) { return static_cast<FakeString*>(s)->length; }
const wchar_t* FakeStringChars(void* s) {
  return static_cast<FakeString*>(s)->chars;
}

MonoEmbeddingApi FakeApi() {
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
  api.method_signature = &FakeMethodSignature;
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

FakeImage UnityUiImages() {
  return {"UnityEngine.UI",
          {{"UnityEngine.UI",
            "Text",
            {{"get_text", true, kMonoTypeString, {}, 0},
             {"set_text", true, kMonoTypeVoid, {kMonoTypeString}, 0}}}}};
}

FakeImage TextRenderingImage() {
  return {"UnityEngine.TextRenderingModule",
          {{"UnityEngine",
            "TextMesh",
            {{"set_text", true, kMonoTypeVoid, {kMonoTypeString}, 0}}}}};
}

// TMP：SetText(string,float) 排在 SetText(string,bool) 之前——只按参数个数找会挂错。
FakeImage TmpImage(bool with_bool_overload) {
  FakeImage image{"Unity.TextMeshPro",
                  {{"TMPro",
                    "TMP_Text",
                    {{"set_text", true, kMonoTypeVoid, {kMonoTypeString}, 0},
                     {"SetText", true, kMonoTypeVoid,
                      {kMonoTypeString, kMonoTypeSingle}, 0}}}}};
  if (with_bool_overload) {
    image.classes[0].methods.push_back(
        {"SetText", true, kMonoTypeVoid, {kMonoTypeString, kMonoTypeBoolean},
         0});
  }
  return image;
}

// 逐字 TextMesh 消息框架的脚本程序集形状（量自静态元数据：Message.Mes(string,bool)
// -> string 实例方法；static Game.NewText(float,float,int,string,int,Rect,Color,enum)
// -> GameObject）。
FakeImage ScriptImage(bool with_message, bool with_companion) {
  FakeImage image{"Assembly-CSharp", {}};
  if (with_message) {
    image.classes.push_back(
        {"",
         "Message",
         {{"Script", true, kMonoTypeVoid,
           {kMonoTypeString, kMonoTypeString, 0x08, 0x11}, 0},
          {"Mes", true, kMonoTypeString,
           {kMonoTypeString, kMonoTypeBoolean}, 0}}});
  }
  if (with_companion) {
    image.classes.push_back(
        {"",
         "Game",
         {{"NewText", false, kMonoTypeClass,
           {kMonoTypeSingle, kMonoTypeSingle, 0x08, kMonoTypeString, 0x08,
            0x11, 0x11, 0x11},
           0}}});
  }
  return image;
}

void TestAbiSelection() {
  assert(MonoManagedAbiForMachine(0x014c) ==
         MonoManagedAbi::kX86CdeclThisFirst);
  assert(MonoManagedAbiForMachine(0x8664) == MonoManagedAbi::kX64Win64);
  assert(MonoManagedAbiForMachine(0xAA64) == MonoManagedAbi::kUnsupported);
  assert(MonoManagedAbiForPointerBytes(4) ==
         MonoManagedAbi::kX86CdeclThisFirst);
  assert(MonoManagedAbiForPointerBytes(8) == MonoManagedAbi::kX64Win64);
#if defined(_M_IX86)
  assert(kMonoManagedAbiForBuild == MonoManagedAbi::kX86CdeclThisFirst);
#else
  assert(kMonoManagedAbiForBuild == MonoManagedAbi::kX64Win64);
#endif
  // 与 IL2CPP 的根本差异：托管入口只有 (this, string, ...)，没有尾随 MethodInfo*。
  for (const MonoTextHookSpec& spec : kUnityMonoTextHookSpecs) {
    assert(spec.instance);
    assert(spec.param_count >= 1 && spec.param_count <= kMonoTextHookMaxParams);
    assert(spec.params[0] == kMonoTypeString);
  }
}

// Fungus（公开框架，独立 Fungus.dll 或源码编进 Assembly-CSharp）：
//   IEnumerator SayDialog.DoSay(string, bool×5, AudioClip, Action)
FakeImage FungusImage(const char* image_name, bool exact_signature = true) {
  FakeImage image{image_name, {}};
  std::vector<int> params = {kMonoTypeString,  kMonoTypeBoolean,
                             kMonoTypeBoolean, kMonoTypeBoolean,
                             kMonoTypeBoolean, kMonoTypeBoolean,
                             kMonoTypeClass,   kMonoTypeClass};
  if (!exact_signature) params[6] = kMonoTypeString;
  image.classes.push_back(
      {"Fungus",
       "SayDialog",
       // 同名 7 参重载排在前面：只按名字找会挂错。
       {{"DoSay", true, kMonoTypeClass,
         {kMonoTypeString, kMonoTypeBoolean, kMonoTypeBoolean,
          kMonoTypeBoolean, kMonoTypeBoolean, kMonoTypeBoolean,
          kMonoTypeClass},
         0},
        {"Say", true, kMonoTypeVoid, params, 0},
        {"DoSay", true, kMonoTypeClass, params, 0}}});
  return image;
}

void TestFungusDoSayIsResolvedExactlyAndUniquely() {
  {
    std::vector<FakeImage> images = {ScriptImage(false, false),
                                     FungusImage("Fungus"), UnityUiImages()};
    g_images = &images;
    const MonoTextResolution r = ResolveUnityMonoTextMethods(FakeApi());
    const auto* dosay = static_cast<FakeMethod*>(
        r.methods[static_cast<size_t>(MonoTextHookId::kFungusSayDialogDoSay)]);
    assert(dosay != nullptr && std::strcmp(dosay->name, "DoSay") == 0 &&
           dosay->params.size() == 8);
    assert(r.framework_ambiguous == 0);
    const uint32_t plan = PlanUnityMonoTextHooks(r);
    // 名牌与其它 UI 文本仍走 UI.Text；正文另有 DoSay 这条稳定道。
    assert(plan == (MonoTextHookBit(MonoTextHookId::kUiTextSetText) |
                    MonoTextHookBit(MonoTextHookId::kFungusSayDialogDoSay)));
    const MonoTextHookSpec& spec =
        MonoTextHookSpecFor(MonoTextHookId::kFungusSayDialogDoSay);
    assert(spec.stable_identity);
    assert(spec.scope == MonoTextHookScope::kFrameworkUnique);
  }
  {
    // 源码导入形态：Fungus 类型编进 Assembly-CSharp 本身。
    FakeImage script = FungusImage("Assembly-CSharp");
    std::vector<FakeImage> images = {script};
    g_images = &images;
    const MonoTextResolution r = ResolveUnityMonoTextMethods(FakeApi());
    assert(r.script_assembly_loaded);
    assert(PlanUnityMonoTextHooks(r) ==
           MonoTextHookBit(MonoTextHookId::kFungusSayDialogDoSay));
  }
  {
    // 负向：两个程序集各有一个 Fungus.SayDialog —— 说不清，不装。
    std::vector<FakeImage> images = {ScriptImage(false, false),
                                     FungusImage("Fungus"),
                                     FungusImage("Fungus.Other")};
    g_images = &images;
    const MonoTextResolution r = ResolveUnityMonoTextMethods(FakeApi());
    assert(r.framework_ambiguous ==
           MonoTextHookBit(MonoTextHookId::kFungusSayDialogDoSay));
    assert(PlanUnityMonoTextHooks(r) == 0);
  }
  {
    // 负向：签名不符（第 7 个参数不是引用类型）。
    std::vector<FakeImage> images = {ScriptImage(false, false),
                                     FungusImage("Fungus", false)};
    g_images = &images;
    const MonoTextResolution r = ResolveUnityMonoTextMethods(FakeApi());
    assert(r.methods[static_cast<size_t>(
               MonoTextHookId::kFungusSayDialogDoSay)] == nullptr);
    assert(PlanUnityMonoTextHooks(r) == 0);
  }
  {
    // 负向：同名 SayDialog 但不在 Fungus 命名空间。
    FakeImage other = FungusImage("Other");
    other.classes[0].ns = "";
    std::vector<FakeImage> images = {ScriptImage(false, false), other};
    g_images = &images;
    const MonoTextResolution r = ResolveUnityMonoTextMethods(FakeApi());
    assert(PlanUnityMonoTextHooks(r) == 0);
  }
}

std::wstring Strip(const wchar_t* in, int capacity = 64) {
  wchar_t out[64] = {};
  const int n = StripFungusTextTags(in, static_cast<int>(std::wcslen(in)),
                                    out, capacity);
  return std::wstring(out, static_cast<size_t>(n));
}

void TestStripFungusTextTags() {
  // 控制标记整段去掉（含参数的 {w=0.5} {voice=…} {ruby=…}），正文与换行保留。
  assert(Strip(L"{w=0.5}あ{b}い{/b}\nう{voice=sce_0001}") == L"あい\nう");
  assert(Strip(L"え{ruby=かな,2}お{wc}") == L"えお");
  // Writer.DoWords 把字面量 \n 换成换行。
  assert(Strip(L"か\\nき") == L"か\nき");
  // 没有闭合 } 的 { 原样保留；{ 与 } 跨行不算标记（Fungus 正则的 . 不跨换行）。
  assert(Strip(L"く{け") == L"く{け");
  assert(Strip(L"こ{さ\nし}") == L"こ{さ\nし}");
  // 富文本 <...> 不在这里剥（共用发布入口剥），原样保留。
  assert(Strip(L"<b>す</b>") == L"<b>す</b>");
  // 容量上限与空输入。
  assert(Strip(L"たちつてと", 3) == L"たちつ");
  wchar_t out[4] = {};
  assert(StripFungusTextTags(nullptr, 3, out, 4) == 0);
  assert(StripFungusTextTags(L"x", 0, out, 4) == 0);
}

void TestSpecTableIsIndexedById() {
  for (size_t i = 0; i < kMonoTextHookCount; ++i) {
    assert(static_cast<size_t>(kUnityMonoTextHookSpecs[i].id) == i);
    assert(kUnityMonoTextHookSpecs[i].hook_code != nullptr);
    assert(std::wcsncmp(kUnityMonoTextHookSpecs[i].hook_code, L"Mono:", 5) ==
           0);
  }
  // 只有框架消息入口在脚本程序集里找；Unity 内置组件跨程序集找。
  assert(MonoTextHookSpecFor(MonoTextHookId::kMessageRendererMes).scope ==
         MonoTextHookScope::kScriptAssembly);
  assert(MonoTextHookSpecFor(MonoTextHookId::kTextMeshSetText).scope ==
         MonoTextHookScope::kAnyAssembly);
}

void TestNotReadyUntilScriptAssemblyLoaded() {
  std::vector<FakeImage> images = {UnityUiImages(), TextRenderingImage()};
  g_images = &images;
  const MonoTextResolution r = ResolveUnityMonoTextMethods(FakeApi());
  assert(!r.script_assembly_loaded);
  assert(r.MethodsFound() == 0);
  assert(PlanUnityMonoTextHooks(r) == 0);
}

void TestIncompleteApiResolvesNothing() {
  std::vector<FakeImage> images = {ScriptImage(true, true),
                                   TextRenderingImage()};
  g_images = &images;
  MonoEmbeddingApi api = FakeApi();
  api.compile_method = nullptr;
  assert(!api.CompleteForResolution());
  const MonoTextResolution r = ResolveUnityMonoTextMethods(api);
  assert(!r.script_assembly_loaded);
  assert(r.MethodsFound() == 0);
}

void TestGenericUnityComponentsAndExactTmpOverload() {
  std::vector<FakeImage> images = {ScriptImage(false, false), UnityUiImages(),
                                   TextRenderingImage(), TmpImage(true)};
  g_images = &images;
  const MonoTextResolution r = ResolveUnityMonoTextMethods(FakeApi());
  assert(r.script_assembly_loaded);
  assert(!r.message_renderer_companion);
  void* set_text_bool = r.methods[static_cast<size_t>(
      MonoTextHookId::kTmpSetTextBool)];
  assert(set_text_bool != nullptr);
  const auto* chosen = static_cast<FakeMethod*>(set_text_bool);
  assert(chosen->params.size() == 2 &&
         chosen->params[1] == kMonoTypeBoolean);
  const uint32_t plan = PlanUnityMonoTextHooks(r);
  assert(plan == (MonoTextHookBit(MonoTextHookId::kTmpSetText) |
                  MonoTextHookBit(MonoTextHookId::kTmpSetTextBool) |
                  MonoTextHookBit(MonoTextHookId::kUiTextSetText) |
                  MonoTextHookBit(MonoTextHookId::kTextMeshSetText)));
}

void TestTmpPairMustBeComplete() {
  // 只有 (string,float) 重载：SetText(string,bool) 解析不到，TMP 两个入口都不装。
  std::vector<FakeImage> images = {ScriptImage(false, false), TmpImage(false)};
  g_images = &images;
  const MonoTextResolution r = ResolveUnityMonoTextMethods(FakeApi());
  assert(r.methods[static_cast<size_t>(MonoTextHookId::kTmpSetText)] !=
         nullptr);
  assert(r.methods[static_cast<size_t>(MonoTextHookId::kTmpSetTextBool)] ==
         nullptr);
  assert(PlanUnityMonoTextHooks(r) == 0);
}

void TestMessageRendererReplacesGlyphTextMesh() {
  std::vector<FakeImage> images = {ScriptImage(true, true),
                                   TextRenderingImage()};
  g_images = &images;
  const MonoTextResolution r = ResolveUnityMonoTextMethods(FakeApi());
  assert(r.script_assembly_loaded);
  assert(r.message_renderer_companion);
  const auto* mes = static_cast<FakeMethod*>(
      r.methods[static_cast<size_t>(MonoTextHookId::kMessageRendererMes)]);
  assert(mes != nullptr && std::strcmp(mes->name, "Mes") == 0);
  const uint32_t plan = PlanUnityMonoTextHooks(r);
  assert(plan == MonoTextHookBit(MonoTextHookId::kMessageRendererMes));
}

void TestMessageWithoutCompanionIsNotTrusted() {
  // 负向：同名 Message.Mes 但没有逐字排版工厂 → 不认，照常挂 TextMesh。
  std::vector<FakeImage> images = {ScriptImage(true, false),
                                   TextRenderingImage()};
  g_images = &images;
  const MonoTextResolution r = ResolveUnityMonoTextMethods(FakeApi());
  assert(!r.message_renderer_companion);
  assert(PlanUnityMonoTextHooks(r) ==
         MonoTextHookBit(MonoTextHookId::kTextMeshSetText));
}

void TestFrameworkTypesOnlyFromScriptAssembly() {
  // 负向：Message / Game 出现在别的程序集里不算（全局命名空间短名跨程序集撞名）。
  FakeImage other = ScriptImage(true, true);
  other.name = "SomePlugin";
  std::vector<FakeImage> images = {other, ScriptImage(false, false),
                                   TextRenderingImage()};
  g_images = &images;
  const MonoTextResolution r = ResolveUnityMonoTextMethods(FakeApi());
  assert(r.script_assembly_loaded);
  assert(!r.message_renderer_companion);
  assert(r.methods[static_cast<size_t>(MonoTextHookId::kMessageRendererMes)] ==
         nullptr);
  assert(PlanUnityMonoTextHooks(r) ==
         MonoTextHookBit(MonoTextHookId::kTextMeshSetText));
}

void TestStaticOrWrongReturnDoesNotMatch() {
  // Mes 若是 void 返回或静态方法，都不是这个框架的形状。
  FakeImage script = ScriptImage(true, true);
  script.classes[0].methods[1].ret = kMonoTypeVoid;
  std::vector<FakeImage> images = {script};
  g_images = &images;
  MonoTextResolution r = ResolveUnityMonoTextMethods(FakeApi());
  assert(r.methods[static_cast<size_t>(MonoTextHookId::kMessageRendererMes)] ==
         nullptr);
  script = ScriptImage(true, true);
  script.classes[0].methods[1].instance = false;
  images = {script};
  r = ResolveUnityMonoTextMethods(FakeApi());
  assert(r.methods[static_cast<size_t>(MonoTextHookId::kMessageRendererMes)] ==
         nullptr);
}

void TestMonoStringBoundedRead() {
  const wchar_t text[] = L"こんにちは";
  FakeString s{5, text};
  MonoStringView v =
      ReadMonoStringBounded(&s, &FakeStringLength, &FakeStringChars, 100);
  assert(v.chars == text && v.length == 5 && !v.truncated);
  v = ReadMonoStringBounded(&s, &FakeStringLength, &FakeStringChars, 3);
  assert(v.length == 3 && v.truncated);
  FakeString empty{0, text};
  v = ReadMonoStringBounded(&empty, &FakeStringLength, &FakeStringChars, 10);
  assert(v.chars == nullptr && v.length == 0);
  FakeString negative{-1, text};
  v = ReadMonoStringBounded(&negative, &FakeStringLength, &FakeStringChars, 10);
  assert(v.length == 0);
  FakeString null_chars{4, nullptr};
  v = ReadMonoStringBounded(&null_chars, &FakeStringLength, &FakeStringChars,
                            10);
  assert(v.length == 0);
  v = ReadMonoStringBounded(nullptr, &FakeStringLength, &FakeStringChars, 10);
  assert(v.length == 0);
  v = ReadMonoStringBounded(&s, nullptr, &FakeStringChars, 10);
  assert(v.length == 0);
}

void TestAttachScopeBalances() {
  const MonoEmbeddingApi api = FakeApi();
  g_attach_calls = g_detach_calls = 0;
  g_attach_ret = reinterpret_cast<void*>(0x7417);
  {
    MonoAttachedThreadScope scope(api, FakeRootDomain());
    assert(scope.attached());
    assert(g_detach_calls == 0);
  }
  assert(g_attach_calls == 1 && g_detach_calls == 1);
  assert(g_last_detached == reinterpret_cast<void*>(0x7417));

  g_attach_calls = g_detach_calls = 0;
  g_attach_ret = nullptr;
  {
    MonoAttachedThreadScope scope(api, FakeRootDomain());
    assert(!scope.attached());
  }
  assert(g_attach_calls == 1 && g_detach_calls == 0);

  g_attach_calls = 0;
  {
    MonoAttachedThreadScope scope(api, nullptr);
    assert(!scope.attached());
  }
  assert(g_attach_calls == 0);
}

}  // namespace

int main() {
  TestAbiSelection();
  TestSpecTableIsIndexedById();
  TestNotReadyUntilScriptAssemblyLoaded();
  TestIncompleteApiResolvesNothing();
  TestGenericUnityComponentsAndExactTmpOverload();
  TestTmpPairMustBeComplete();
  TestMessageRendererReplacesGlyphTextMesh();
  TestMessageWithoutCompanionIsNotTrusted();
  TestFrameworkTypesOnlyFromScriptAssembly();
  TestStaticOrWrongReturnDoesNotMatch();
  TestMonoStringBoundedRead();
  TestAttachScopeBalances();
  TestFungusDoSayIsResolvedExactlyAndUniquely();
  TestStripFungusTextTags();
  std::printf("unity_mono_text_test: ok\n");
  return 0;
}
