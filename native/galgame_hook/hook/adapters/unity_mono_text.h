// Unity（Mono 运行时）文本 setter 的**纯逻辑层**：方法解析表、Mono 嵌入 API 函数表、
// 托管调用约定选择、MonoString 有界读取、以及「装哪几个 hook」的决策。
//
// 这里不含任何 GetProcAddress / MinHook / 共享内存写入——全部通过注入的函数指针工作，
// 所以能用假运行时离线单测（tests/unity_mono_text_test.cpp），不需要真 mono.dll。
// 装配（取址、attach、HookFn、detour、发布）在 unity_mono_adapter.inc。
//
// 为什么走 Mono 嵌入 API 而不是 IL2CPP 那套：Mono 构建没有 GameAssembly.dll，也没有
// il2cpp_* 导出；托管方法只有被 JIT 之后才有本机代码。`mono_compile_method` 返回的就是
// 该方法的 JIT 入口（已编译过则返回缓存的同一地址），虚表槽 / 跳板最终都落到这里，
// 所以在这个入口上挂 MinHook 能截到所有调用路径。
//
// 头文件只依赖 <cstddef> / <cstdint> / <cstring>：dll_main.cpp 在匿名命名空间外先 include
// 它（#pragma once 让 adapter 里的二次 include 变成空操作）。
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

// Mono 托管代码的调用约定（mono/mini/mini-x86.c、mini-amd64.c）：
//   * x86：所有实参（含实例方法的 `this`，排在第一个）都在栈上，调用方清栈，返回值走
//     EAX——即 cdecl 形态。只有 P/Invoke 的 stdcall/thiscall 签名才由被调方弹栈，托管→托管
//     调用不会。EDX 是 IMT/RGCTX 隐藏寄存器，只有泛型共享方法 / 接口派发会读；这里挂的
//     setter 都不是泛型共享方法，detour 可以按普通 cdecl 函数写。
//   * x64（Windows）：Mono 在 TARGET_WIN32 上沿用 Win64 ABI（RCX/RDX/R8/R9 + 32 字节影子
//     空间），`this` 在 RCX。与 MSVC 默认调用约定一致。
//   * 与 IL2CPP 的关键差异：**没有尾随的 MethodInfo* 参数**。IL2CPP 的 detour 签名
//     （unity_adapter.inc）多一个 `const void* method`，照抄到 Mono 上会在 x86 把栈上的
//     下一个槽当成参数转发、在 x64 多读一个寄存器——前者破坏调用方的栈约定，不能复用。
#if defined(_M_IX86)
#define FUSHI_MONO_MANAGED_CALL __cdecl
#else
#define FUSHI_MONO_MANAGED_CALL
#endif

namespace fushi_voice_hook {

enum class MonoManagedAbi : uint8_t {
  kUnsupported = 0,
  // x86：cdecl 形态，`this` 是第一个栈参数，调用方清栈，无 MethodInfo* 尾参。
  kX86CdeclThisFirst = 1,
  // x64 Windows：Win64 ABI，`this` 在 RCX，无 MethodInfo* 尾参。
  kX64Win64 = 2,
};

// 按目标进程 PE 机器类型选调用约定；hook DLL 与游戏同架构（x86 游戏注 x86 DLL）。
constexpr MonoManagedAbi MonoManagedAbiForMachine(uint16_t pe_machine) {
  return pe_machine == 0x014c   ? MonoManagedAbi::kX86CdeclThisFirst
         : pe_machine == 0x8664 ? MonoManagedAbi::kX64Win64
                                : MonoManagedAbi::kUnsupported;
}

constexpr MonoManagedAbi MonoManagedAbiForPointerBytes(size_t pointer_bytes) {
  return pointer_bytes == 4   ? MonoManagedAbi::kX86CdeclThisFirst
         : pointer_bytes == 8 ? MonoManagedAbi::kX64Win64
                              : MonoManagedAbi::kUnsupported;
}

// 本构建产物的托管调用约定。与 FUSHI_MONO_MANAGED_CALL 必须一致。
#if defined(_M_IX86)
constexpr MonoManagedAbi kMonoManagedAbiForBuild =
    MonoManagedAbi::kX86CdeclThisFirst;
#elif defined(_M_X64) || defined(_M_AMD64)
constexpr MonoManagedAbi kMonoManagedAbiForBuild = MonoManagedAbi::kX64Win64;
#else
constexpr MonoManagedAbi kMonoManagedAbiForBuild = MonoManagedAbi::kUnsupported;
#endif
static_assert(kMonoManagedAbiForBuild == MonoManagedAbi::kUnsupported ||
                  kMonoManagedAbiForBuild ==
                      MonoManagedAbiForPointerBytes(sizeof(void*)),
              "Mono managed ABI must follow the build's pointer width");

// MonoTypeEnum 子集（与 ECMA-335 ELEMENT_TYPE_* 数值一致，mono/metadata/blob.h）。
constexpr int kMonoTypeVoid = 0x01;
constexpr int kMonoTypeBoolean = 0x02;
constexpr int kMonoTypeSingle = 0x0c;
constexpr int kMonoTypeString = 0x0e;
constexpr int kMonoTypeClass = 0x12;

enum class MonoTextHookId : uint8_t {
  kTmpSetText = 0,
  kTmpSetTextBool = 1,
  kUiTextSetText = 2,
  kTextMeshSetText = 3,
  kMessageRendererMes = 4,
  kCount = 5,
};
constexpr size_t kMonoTextHookCount = static_cast<size_t>(MonoTextHookId::kCount);

constexpr uint32_t MonoTextHookBit(MonoTextHookId id) {
  return 1u << static_cast<uint32_t>(id);
}

enum class MonoTextHookScope : uint8_t {
  // Unity 内置组件：在所有已加载程序集里找（TMP 随包名历代不同，
  // Unity.TextMeshPro / TextMeshPro-2017.x-Runtime 等，不写死程序集名）。
  kAnyAssembly = 0,
  // 脚本层框架类型：只在 Assembly-CSharp 里找——全局命名空间的短类名在别的程序集里
  // 撞名不代表同一个框架。
  kScriptAssembly = 1,
};

struct MonoTextHookSpec {
  MonoTextHookId id;
  MonoTextHookScope scope;
  const char* name_space;
  const char* class_name;
  const char* method;
  bool instance;
  int return_type;
  uint8_t param_count;
  int params[2];
  // 发布到文本道上的 hook 名 / hook code（ring_probe --dump-text-events 可见）。
  const char* hook_name;
  const wchar_t* hook_code;
  // true：线程身份不含组件指针（组件随场景重建也保持同一条可选线程）。Message.Mes
  // 另带角色键（对象场景名的哈希，unity_mono_adapter.inc 的 UnityMonoMessageRole）：
  // 正文与名牌是同类两个对象，同一条道上最新行会永远是说话人名字。
  bool stable_identity;
};

// 与 IL2CPP 路径（TryHookUnityIl2CppAudio）挂的同一组 setter，外加一条脚本层框架入口。
// 精确匹配 (名字, 实例/静态, 返回类型, 参数个数, 每个参数类型)：TMP_Text 的 SetText
// 有 (string,bool) / (string,float) / (StringBuilder) 等同参数个数的重载，只按个数找会
// 挂错重载、按错签名转发参数。
//
// kMessageRendererMes：逐字 TextMesh 渲染框架的「整条消息」入口，形如
//   class Message : MonoBehaviour { string Mes(string message, bool skip); }
// 它把整条消息拆成**每个字一个 TextMesh**（逐字 Game.NewText → TextMesh.set_text），
// 返回值是去掉标记后的纯正文（换行分隔）。只挂 TextMesh.set_text 在这种框架上得到的是
// 「每个字一条独立组件的单字行」——线程表被逐字组件冲满，没有一条可选的正文线程。
// 实测样本（静态元数据，2026-09-27）：デスマッチラブコメ！ Assembly-CSharp 的全部文本
// 渲染只有 TextMesh.set_text 一处调用点（Game.NewText / NewText_Center），Message.Mes
// 是唯一的对白入口。它只在下面 kMessageRendererCompanion 也成立时才启用（结构判据，
// 不看 exe 名 / 标题 / 哈希）。
constexpr MonoTextHookSpec kUnityMonoTextHookSpecs[kMonoTextHookCount] = {
    {MonoTextHookId::kTmpSetText, MonoTextHookScope::kAnyAssembly, "TMPro",
     "TMP_Text", "set_text", true, kMonoTypeVoid, 1,
     {kMonoTypeString, 0}, "Unity Mono TMP_Text",
     L"Mono:TMPro.TMP_Text.set_text", false},
    {MonoTextHookId::kTmpSetTextBool, MonoTextHookScope::kAnyAssembly, "TMPro",
     "TMP_Text", "SetText", true, kMonoTypeVoid, 2,
     {kMonoTypeString, kMonoTypeBoolean}, "Unity Mono TMP_Text",
     L"Mono:TMPro.TMP_Text.SetText(string,bool)", false},
    {MonoTextHookId::kUiTextSetText, MonoTextHookScope::kAnyAssembly,
     "UnityEngine.UI", "Text", "set_text", true, kMonoTypeVoid, 1,
     {kMonoTypeString, 0}, "Unity Mono UI.Text",
     L"Mono:UnityEngine.UI.Text.set_text", false},
    {MonoTextHookId::kTextMeshSetText, MonoTextHookScope::kAnyAssembly,
     "UnityEngine", "TextMesh", "set_text", true, kMonoTypeVoid, 1,
     {kMonoTypeString, 0}, "Unity Mono TextMesh",
     L"Mono:UnityEngine.TextMesh.set_text", false},
    {MonoTextHookId::kMessageRendererMes, MonoTextHookScope::kScriptAssembly,
     "", "Message", "Mes", true, kMonoTypeString, 2,
     {kMonoTypeString, kMonoTypeBoolean}, "Unity Mono Message.Mes",
     L"Mono:Message.Mes(string,bool)->string", true},
};

// Message.Mes 的结构伴随判据：同一 Assembly-CSharp 里的逐字排版工厂
//   static GameObject Game.NewText(float x, float y, int priority, string str, ...8 参)
// 第 4 个参数是 string、返回引用类型。两者同时成立才认定为「逐字 TextMesh 消息框架」；
// 单有一个叫 Message 的类和一个 Mes 方法不够。
struct MonoMethodShape {
  const char* name_space;
  const char* class_name;
  const char* method;
  bool instance;
  int return_type;
  uint8_t param_count;
  uint8_t string_param_index;
};
constexpr MonoMethodShape kMessageRendererCompanion = {
    "", "Game", "NewText", false, kMonoTypeClass, 8, 3};

inline const MonoTextHookSpec& MonoTextHookSpecFor(MonoTextHookId id) {
  return kUnityMonoTextHookSpecs[static_cast<size_t>(id)];
}

// 运行时 Assembly-CSharp 的镜像名。Unity 在初始化时一次性加载全部脚本程序集，
// 它出现就说明 Unity 内置 UI / TMP 程序集也已在域里——以此作为「可以解析了」的门。
constexpr const char* kUnityScriptAssemblyImage = "Assembly-CSharp";

// Mono 嵌入 API（mono-2.0-bdwgc.dll / mono-2.0-sgen.dll / 5.x 的 mono.dll 都导出同名
// cdecl 函数）。全部由调用方用 GetProcAddress 填入；测试里填假实现。
struct MonoEmbeddingApi {
  void* (*get_root_domain)() = nullptr;
  void* (*thread_attach)(void* domain) = nullptr;
  void (*thread_detach)(void* thread) = nullptr;
  void (*assembly_foreach)(void (*func)(void* assembly, void* user_data),
                           void* user_data) = nullptr;
  void* (*assembly_get_image)(void* assembly) = nullptr;
  const char* (*image_get_name)(void* image) = nullptr;
  void* (*class_from_name)(void* image, const char* name_space,
                           const char* name) = nullptr;
  void* (*class_get_methods)(void* klass, void** iter) = nullptr;
  const char* (*method_get_name)(void* method) = nullptr;
  void* (*method_signature)(void* method) = nullptr;
  uint32_t (*signature_get_param_count)(void* signature) = nullptr;
  void* (*signature_get_params)(void* signature, void** iter) = nullptr;
  void* (*signature_get_return_type)(void* signature) = nullptr;
  int32_t (*signature_is_instance)(void* signature) = nullptr;
  int (*type_get_type)(void* type) = nullptr;
  void* (*compile_method)(void* method) = nullptr;
  int (*string_length)(void* string) = nullptr;
  const wchar_t* (*string_chars)(void* string) = nullptr;

  bool CompleteForResolution() const {
    return get_root_domain != nullptr && thread_attach != nullptr &&
           thread_detach != nullptr && assembly_foreach != nullptr &&
           assembly_get_image != nullptr && image_get_name != nullptr &&
           class_from_name != nullptr && class_get_methods != nullptr &&
           method_get_name != nullptr && method_signature != nullptr &&
           signature_get_param_count != nullptr &&
           signature_get_params != nullptr &&
           signature_get_return_type != nullptr &&
           signature_is_instance != nullptr && type_get_type != nullptr &&
           compile_method != nullptr && string_length != nullptr &&
           string_chars != nullptr;
  }
};

// Mono 的托管线程注册作用域。HookWorker 是普通 Win32 线程：类型/方法枚举与
// mono_compile_method 都会进 loader 锁、可能分配，必须先 attach 到根域。作用域结束即
// detach——worker 常驻、还会持 g_cs 等锁，不能让它一直作为托管线程被 GC 停世界挂起。
// 只 detach 本作用域自己 attach 出来的句柄。
class MonoAttachedThreadScope {
 public:
  MonoAttachedThreadScope(const MonoEmbeddingApi& api, void* domain)
      : detach_(api.thread_detach) {
    if (api.thread_attach != nullptr && domain != nullptr) {
      thread_ = api.thread_attach(domain);
    }
  }
  ~MonoAttachedThreadScope() {
    if (thread_ != nullptr && detach_ != nullptr) detach_(thread_);
  }
  MonoAttachedThreadScope(const MonoAttachedThreadScope&) = delete;
  MonoAttachedThreadScope& operator=(const MonoAttachedThreadScope&) = delete;
  bool attached() const { return thread_ != nullptr; }

 private:
  void (*detach_)(void*) = nullptr;
  void* thread_ = nullptr;
};

constexpr size_t kMonoAssemblyCapacity = 512;

struct MonoAssemblyList {
  void* assemblies[kMonoAssemblyCapacity] = {};
  size_t count = 0;
  bool truncated = false;
};

// mono_assembly_foreach 在程序集表锁下回调：这里只抄指针，解析留到锁外。
inline void CollectMonoAssembly(void* assembly, void* user_data) {
  auto* list = static_cast<MonoAssemblyList*>(user_data);
  if (list == nullptr || assembly == nullptr) return;
  if (list->count >= kMonoAssemblyCapacity) {
    list->truncated = true;
    return;
  }
  list->assemblies[list->count++] = assembly;
}

inline bool MonoTypeIs(const MonoEmbeddingApi& api, void* type, int expected) {
  return type != nullptr && api.type_get_type(type) == expected;
}

inline bool MonoSignatureMatches(const MonoEmbeddingApi& api, void* method,
                                 bool instance, int return_type,
                                 uint8_t param_count, const int* params,
                                 int string_param_index) {
  void* signature = api.method_signature(method);
  if (signature == nullptr) return false;
  if ((api.signature_is_instance(signature) != 0) != instance) return false;
  if (api.signature_get_param_count(signature) != param_count) return false;
  if (!MonoTypeIs(api, api.signature_get_return_type(signature), return_type)) {
    return false;
  }
  void* iter = nullptr;
  for (uint8_t i = 0; i < param_count; ++i) {
    void* type = api.signature_get_params(signature, &iter);
    if (type == nullptr) return false;
    if (params != nullptr && !MonoTypeIs(api, type, params[i])) return false;
    if (params == nullptr && i == string_param_index &&
        !MonoTypeIs(api, type, kMonoTypeString)) {
      return false;
    }
  }
  return true;
}

// 在 klass 上按名字 + 完整签名找方法（只看本类声明的方法，不上溯基类：
// setter 都是在声明类上定义的，基类同名方法不是我们要截的入口）。
inline void* FindMonoMethod(const MonoEmbeddingApi& api, void* klass,
                            const char* name, bool instance, int return_type,
                            uint8_t param_count, const int* params,
                            int string_param_index = -1) {
  if (klass == nullptr || name == nullptr) return nullptr;
  void* iter = nullptr;
  // 上限只防假/坏运行时死循环；真实类的方法数远低于它。
  for (int guard = 0; guard < 8192; ++guard) {
    void* method = api.class_get_methods(klass, &iter);
    if (method == nullptr) return nullptr;
    const char* method_name = api.method_get_name(method);
    if (method_name == nullptr || std::strcmp(method_name, name) != 0) continue;
    if (MonoSignatureMatches(api, method, instance, return_type, param_count,
                             params, string_param_index)) {
      return method;
    }
  }
  return nullptr;
}

struct MonoTextResolution {
  bool script_assembly_loaded = false;
  bool assemblies_truncated = false;
  size_t assembly_count = 0;
  uint32_t classes_found = 0;  // MonoTextHookBit 掩码
  bool message_renderer_companion = false;
  void* methods[kMonoTextHookCount] = {};

  uint32_t MethodsFound() const {
    uint32_t mask = 0;
    for (size_t i = 0; i < kMonoTextHookCount; ++i) {
      if (methods[i] != nullptr) {
        mask |= MonoTextHookBit(static_cast<MonoTextHookId>(i));
      }
    }
    return mask;
  }
};

// 调用方须已在 MonoAttachedThreadScope 内。Assembly-CSharp 未加载时只报告
// script_assembly_loaded=false，由调用方稍后重试。
inline MonoTextResolution ResolveUnityMonoTextMethods(
    const MonoEmbeddingApi& api) {
  MonoTextResolution result;
  if (!api.CompleteForResolution()) return result;
  MonoAssemblyList list;
  api.assembly_foreach(&CollectMonoAssembly, &list);
  result.assembly_count = list.count;
  result.assemblies_truncated = list.truncated;

  void* script_image = nullptr;
  for (size_t i = 0; i < list.count; ++i) {
    void* image = api.assembly_get_image(list.assemblies[i]);
    const char* name = image == nullptr ? nullptr : api.image_get_name(image);
    if (name != nullptr && std::strcmp(name, kUnityScriptAssemblyImage) == 0) {
      script_image = image;
      break;
    }
  }
  result.script_assembly_loaded = script_image != nullptr;
  if (!result.script_assembly_loaded) return result;

  for (const MonoTextHookSpec& spec : kUnityMonoTextHookSpecs) {
    void* klass = nullptr;
    if (spec.scope == MonoTextHookScope::kScriptAssembly) {
      klass = api.class_from_name(script_image, spec.name_space,
                                  spec.class_name);
    } else {
      for (size_t i = 0; i < list.count && klass == nullptr; ++i) {
        void* image = api.assembly_get_image(list.assemblies[i]);
        if (image == nullptr) continue;
        klass = api.class_from_name(image, spec.name_space, spec.class_name);
      }
    }
    if (klass == nullptr) continue;
    result.classes_found |= MonoTextHookBit(spec.id);
    result.methods[static_cast<size_t>(spec.id)] =
        FindMonoMethod(api, klass, spec.method, spec.instance,
                       spec.return_type, spec.param_count, spec.params);
  }

  const MonoMethodShape& companion = kMessageRendererCompanion;
  void* companion_class = api.class_from_name(
      script_image, companion.name_space, companion.class_name);
  result.message_renderer_companion =
      FindMonoMethod(api, companion_class, companion.method,
                     companion.instance, companion.return_type,
                     companion.param_count, nullptr,
                     companion.string_param_index) != nullptr;
  return result;
}

// 决定真正要装的 hook 集合（MonoTextHookBit 掩码）。
//   * TMP 的两个入口是一对：只装得上一个时两个都不装（与 IL2CPP 路径的
//     tmp_text_ready = property && method 同一口径），避免只截到一半调用。
//   * 逐字 TextMesh 消息框架成立（Mes 方法 + Game.NewText 伴随判据）时，整条消息从
//     Message.Mes 的返回值取，**不再挂 TextMesh.set_text**：那条在这类框架上只产出
//     逐字单字组件，会把线程表冲满。
//   * Mes 方法在但伴随判据不成立：不认这个 Message 类（可能只是同名的别家类）。
inline uint32_t PlanUnityMonoTextHooks(const MonoTextResolution& resolution) {
  const uint32_t found = resolution.MethodsFound();
  uint32_t plan = found;
  const uint32_t tmp_pair = MonoTextHookBit(MonoTextHookId::kTmpSetText) |
                            MonoTextHookBit(MonoTextHookId::kTmpSetTextBool);
  if ((plan & tmp_pair) != tmp_pair) plan &= ~tmp_pair;
  const uint32_t mes = MonoTextHookBit(MonoTextHookId::kMessageRendererMes);
  if ((plan & mes) != 0 && resolution.message_renderer_companion) {
    plan &= ~MonoTextHookBit(MonoTextHookId::kTextMeshSetText);
  } else {
    plan &= ~mes;
  }
  return plan;
}

// MonoString 的有界视图。字符布局只经导出的 mono_string_chars / mono_string_length
// 取得，不硬编码对象头偏移（5.x mono.dll 与 MonoBleedingEdge 的对象头不同）。
struct MonoStringView {
  const wchar_t* chars = nullptr;
  int length = 0;
  bool truncated = false;
};

inline MonoStringView ReadMonoStringBounded(
    void* string, int (*string_length)(void*),
    const wchar_t* (*string_chars)(void*), int max_chars) {
  MonoStringView view;
  if (string == nullptr || string_length == nullptr ||
      string_chars == nullptr || max_chars <= 0) {
    return view;
  }
  const int length = string_length(string);
  if (length <= 0) return view;
  const wchar_t* chars = string_chars(string);
  if (chars == nullptr) return view;
  view.chars = chars;
  view.length = length > max_chars ? max_chars : length;
  view.truncated = length > max_chars;
  return view;
}

}  // namespace fushi_voice_hook
