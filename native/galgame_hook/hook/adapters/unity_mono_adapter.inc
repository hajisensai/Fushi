// Unity（Mono 运行时）adapter。补的是一个**实测存在的覆盖缺口**：老 Unity（5.x 一代）
// 把引擎静态链进 exe，没有 `UnityPlayer.dll`，而仓库里 `UnityIl2CppAdapter::probe()` 与
// injector 的 `LooksLikeUnityRuntime()` 都以它为必要条件——于是这一族游戏两边都不认领。
// 真机实测（カスタムメイド3D2 CHU-B LIP）：`[adapters]` 读数里**没有** unity_il2cpp 行，
// 而 PCM 一直在流（voice_clips 981）。
//
// 全部 implemented_unverified：
//   * 身份：unity_mono_profile.h 的「Managed\Assembly-CSharp.dll + Mono 运行时（5.x 的
//     `_Data\Mono\mono.dll` 或 2017+ 的 exe 同级 `MonoBleedingEdge\EmbedRuntime\
//     mono-2.0-{bdwgc,sgen}.dll`），且同级无 GameAssembly.dll」结构判据（最后一条是与
//     unity_il2cpp 的显式互斥门）；
//   * 文本：LunaHook（真机实测 luna_active=1、text_events=7，标题画面）之外，本文件经
//     **Mono 嵌入 API** 挂与 IL2CPP 路径同一组托管 setter（TMP_Text.set_text /
//     SetText(string,bool)、UI.Text.set_text、TextMesh.set_text），以及逐字 TextMesh
//     消息框架的整条消息入口 Message.Mes（判据与理由见 unity_mono_text.h）。发布走
//     unity_adapter.inc 的 RecordUnityTextChars，与 IL2CPP 同一套富文本剥离 / 伪影门 /
//     线程身份；
//   * 音频：GenericWindowsAudioAdapter 的源 PCM（voice_clips 981，非静音）。
//
// 生命周期：身份门 → Mono 运行时模块已加载 → 进程已有可见顶层窗口（与 IL2CPP 的
// kDiagUnityHooksDeferredUntilWindow 同一理由：启动挂起期运行时尚未初始化完）→ 根域非空
// → worker 线程临时 attach → Assembly-CSharp 已在域里 → 解析 + mono_compile_method 取
// JIT 入口 → detach → HookFn。全部在 HookWorker（registry Poll）上做，游戏线程只进 detour。
// Assembly-CSharp 还没加载就等下一拍；预算耗尽记 kUnityMonoFlagResolveExhausted 后停止，
// 不无界重试。
//
// **刻意不改 injector 的自动 PC hooks**：照 Unreal 那次的同一套对照实测，本样本开与不开
// `--luna-pchooks` 的 text_events **都是 7**（同一段标题画面）。
//
// 逐句语音资源层（Unity AudioClip / .assets）明确**未做**：本样本 `unity_events=0`，既有的
// Unity 资源提取器对它没有产出；要取原始逐句字节得在真机上定位它自己的读取路径，静态阶段
// 不猜 hook 面。
//
// 已知风险（未真机验证）：detour 是直接被托管代码调用的本机帧，Mono 的异常展开不认识它。
// 原方法若抛托管异常并由 detour 之上的托管帧捕获，展开可能失败。这里挂的都是 setter /
// 消息排版入口，正常路径不抛；真机阶段需确认。
#include "unity_mono_profile.h"
#include "unity_mono_text.h"

// adapter 自有诊断字（diagnostics().flags → v23 [adapters] 读数）。只增不减。
constexpr LONG kUnityMonoFlagIdentity = 0x00000001;
constexpr LONG kUnityMonoFlagRuntimeModule = 0x00000002;
constexpr LONG kUnityMonoFlagWaitingForWindow = 0x00000004;
constexpr LONG kUnityMonoFlagApiIncomplete = 0x00000008;
constexpr LONG kUnityMonoFlagRootDomain = 0x00000010;
constexpr LONG kUnityMonoFlagThreadAttachFailed = 0x00000020;
constexpr LONG kUnityMonoFlagScriptAssemblyReady = 0x00000040;
constexpr LONG kUnityMonoFlagMessageRendererSignature = 0x00000080;
// bit 8..12：对应 MonoTextHookId 的 hook 已装（kUnityMonoFlagHookInstalledShift + id）。
constexpr LONG kUnityMonoFlagHookInstalledShift = 8;
// bit 16..20：对应 MonoTextHookId 的 detour 至少触发过一次（游戏线程置位）。
constexpr LONG kUnityMonoFlagDetourFiredShift = 16;
constexpr LONG kUnityMonoFlagTextPublished = 0x01000000;
constexpr LONG kUnityMonoFlagResolveExhausted = 0x02000000;
constexpr LONG kUnityMonoFlagCompileFailed = 0x04000000;
constexpr LONG kUnityMonoFlagNoTextClasses = 0x08000000;
static_assert(fushi_voice_hook::kMonoTextHookCount <= 8,
              "hook id bits must fit their flag byte");

volatile LONG g_unity_mono_flags = 0;
// detour 读字符串用的两个导出。HookFn 之前写好，之后只读。
int (*g_unity_mono_string_length)(void*) = nullptr;
const wchar_t* (*g_unity_mono_string_chars)(void*) = nullptr;
constexpr int kUnityMonoTextMaxChars = 2000;

void MarkUnityMonoFlag(LONG flag) { InterlockedOr(&g_unity_mono_flags, flag); }

using UnityMonoTextSetter = void(FUSHI_MONO_MANAGED_CALL*)(void*, void*);
using UnityMonoTextSetterWithFlag = void(FUSHI_MONO_MANAGED_CALL*)(void*, void*,
                                                                    uintptr_t);
using UnityMonoMessageRendererMes = void*(FUSHI_MONO_MANAGED_CALL*)(void*, void*,
                                                                     uintptr_t);
UnityMonoTextSetter g_orig_UnityMonoTmpSetText = nullptr;
UnityMonoTextSetterWithFlag g_orig_UnityMonoTmpSetTextBool = nullptr;
UnityMonoTextSetter g_orig_UnityMonoUiTextSetText = nullptr;
UnityMonoTextSetter g_orig_UnityMonoTextMeshSetText = nullptr;
UnityMonoMessageRendererMes g_orig_UnityMonoMessageRendererMes = nullptr;

// 游戏线程上的唯一工作：经导出 accessor 取 UTF-16 视图（纯指针运算，不分配、不进 GC），
// 交给与 IL2CPP 共用的有界发布（RecordUnityTextChars 内部拷进定长 clean[501] 再写共享
// 内存道）。不 attach、不 runtime_invoke、不做 IO。
void RecordUnityMonoText(fushi_voice_hook::MonoTextHookId id, void* component,
                         void* string_object) {
  MarkUnityMonoFlag(1L << (kUnityMonoFlagDetourFiredShift +
                           static_cast<LONG>(id)));
  if (!g_capture_enabled) return;
  const fushi_voice_hook::MonoStringView view =
      fushi_voice_hook::ReadMonoStringBounded(
          string_object, g_unity_mono_string_length,
          g_unity_mono_string_chars, kUnityMonoTextMaxChars);
  if (view.length <= 0) return;
  const fushi_voice_hook::MonoTextHookSpec& spec =
      fushi_voice_hook::MonoTextHookSpecFor(id);
  if (RecordUnityTextChars(component, view.chars, view.length, spec.hook_name,
                           spec.hook_code, spec.stable_identity)) {
    MarkUnityMonoFlag(kUnityMonoFlagTextPublished);
  }
}

// Mono 托管签名：没有 IL2CPP 的尾随 MethodInfo*。bool 实参按整字转发（x86 栈槽 /
// x64 R8 原样），不在本机侧重新规范化。
void FUSHI_MONO_MANAGED_CALL Detour_UnityMonoTmpSetText(void* self,
                                                        void* text) {
  g_orig_UnityMonoTmpSetText(self, text);
  RecordUnityMonoText(fushi_voice_hook::MonoTextHookId::kTmpSetText, self,
                      text);
}

void FUSHI_MONO_MANAGED_CALL Detour_UnityMonoTmpSetTextBool(
    void* self, void* text, uintptr_t sync_text_input_box) {
  g_orig_UnityMonoTmpSetTextBool(self, text, sync_text_input_box);
  RecordUnityMonoText(fushi_voice_hook::MonoTextHookId::kTmpSetTextBool, self,
                      text);
}

void FUSHI_MONO_MANAGED_CALL Detour_UnityMonoUiTextSetText(void* self,
                                                           void* text) {
  g_orig_UnityMonoUiTextSetText(self, text);
  RecordUnityMonoText(fushi_voice_hook::MonoTextHookId::kUiTextSetText, self,
                      text);
}

void FUSHI_MONO_MANAGED_CALL Detour_UnityMonoTextMeshSetText(void* self,
                                                             void* text) {
  g_orig_UnityMonoTextMeshSetText(self, text);
  RecordUnityMonoText(fushi_voice_hook::MonoTextHookId::kTextMeshSetText, self,
                      text);
}

// 返回值是去掉排版标记后的整条消息正文；原样返回给调用方。
void* FUSHI_MONO_MANAGED_CALL Detour_UnityMonoMessageRendererMes(
    void* self, void* message, uintptr_t skip) {
  void* plain = g_orig_UnityMonoMessageRendererMes(self, message, skip);
  RecordUnityMonoText(fushi_voice_hook::MonoTextHookId::kMessageRendererMes,
                      self, plain);
  return plain;
}

struct UnityMonoDetourBinding {
  fushi_voice_hook::MonoTextHookId id;
  void* detour;
  void** original;
};

const UnityMonoDetourBinding kUnityMonoDetours[] = {
    {fushi_voice_hook::MonoTextHookId::kTmpSetText,
     reinterpret_cast<void*>(&Detour_UnityMonoTmpSetText),
     reinterpret_cast<void**>(&g_orig_UnityMonoTmpSetText)},
    {fushi_voice_hook::MonoTextHookId::kTmpSetTextBool,
     reinterpret_cast<void*>(&Detour_UnityMonoTmpSetTextBool),
     reinterpret_cast<void**>(&g_orig_UnityMonoTmpSetTextBool)},
    {fushi_voice_hook::MonoTextHookId::kUiTextSetText,
     reinterpret_cast<void*>(&Detour_UnityMonoUiTextSetText),
     reinterpret_cast<void**>(&g_orig_UnityMonoUiTextSetText)},
    {fushi_voice_hook::MonoTextHookId::kTextMeshSetText,
     reinterpret_cast<void*>(&Detour_UnityMonoTextMeshSetText),
     reinterpret_cast<void**>(&g_orig_UnityMonoTextMeshSetText)},
    {fushi_voice_hook::MonoTextHookId::kMessageRendererMes,
     reinterpret_cast<void*>(&Detour_UnityMonoMessageRendererMes),
     reinterpret_cast<void**>(&g_orig_UnityMonoMessageRendererMes)},
};
static_assert(sizeof(kUnityMonoDetours) / sizeof(kUnityMonoDetours[0]) ==
                  fushi_voice_hook::kMonoTextHookCount,
              "every Mono text hook id needs exactly one detour binding");

HMODULE FindLoadedUnityMonoRuntime() {
  // 与 unity_mono_profile.h 的两代布局一一对应：5.x 的 mono.dll、2017+ 的
  // mono-2.0-bdwgc.dll / mono-2.0-sgen.dll。身份门已在磁盘上确认是 Mono 构建。
  for (const wchar_t* name :
       {L"mono-2.0-bdwgc.dll", L"mono-2.0-sgen.dll", L"mono.dll"}) {
    HMODULE module = GetModuleHandleW(name);
    if (module != nullptr) return module;
  }
  return nullptr;
}

template <typename Fn>
void LoadMonoExport(HMODULE runtime, const char* name, Fn* out) {
  *out = reinterpret_cast<Fn>(GetProcAddress(runtime, name));
}

fushi_voice_hook::MonoEmbeddingApi LoadUnityMonoEmbeddingApi(HMODULE runtime) {
  fushi_voice_hook::MonoEmbeddingApi api;
  LoadMonoExport(runtime, "mono_get_root_domain", &api.get_root_domain);
  LoadMonoExport(runtime, "mono_thread_attach", &api.thread_attach);
  LoadMonoExport(runtime, "mono_thread_detach", &api.thread_detach);
  LoadMonoExport(runtime, "mono_assembly_foreach", &api.assembly_foreach);
  LoadMonoExport(runtime, "mono_assembly_get_image", &api.assembly_get_image);
  LoadMonoExport(runtime, "mono_image_get_name", &api.image_get_name);
  LoadMonoExport(runtime, "mono_class_from_name", &api.class_from_name);
  LoadMonoExport(runtime, "mono_class_get_methods", &api.class_get_methods);
  LoadMonoExport(runtime, "mono_method_get_name", &api.method_get_name);
  LoadMonoExport(runtime, "mono_method_signature", &api.method_signature);
  LoadMonoExport(runtime, "mono_signature_get_param_count",
                 &api.signature_get_param_count);
  LoadMonoExport(runtime, "mono_signature_get_params",
                 &api.signature_get_params);
  LoadMonoExport(runtime, "mono_signature_get_return_type",
                 &api.signature_get_return_type);
  LoadMonoExport(runtime, "mono_signature_is_instance",
                 &api.signature_is_instance);
  LoadMonoExport(runtime, "mono_type_get_type", &api.type_get_type);
  LoadMonoExport(runtime, "mono_compile_method", &api.compile_method);
  LoadMonoExport(runtime, "mono_string_length", &api.string_length);
  LoadMonoExport(runtime, "mono_string_chars", &api.string_chars);
  return api;
}

class UnityMonoAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "unity_mono"; }
  bool probe() const override {
    return fushi_voice_hook::MatchesUnityMonoProfile(nullptr);
  }
  // installed_ 表示「身份成立、共享文本/PCM 路径对此进程生效」；托管文本 hook 另由
  // text_done_ / 诊断字表达，它要等运行时与脚本程序集就绪，不在启动挂起期做。
  bool install() override {
    installed_ = probe();
    if (installed_) MarkUnityMonoFlag(kUnityMonoFlagIdentity);
    return installed_;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    // 身份来自磁盘布局，启动时一次判定即可；模块通知只作重试接缝。
    if (!installed_ && module_name == nullptr) install();
  }
  // registry Poll 调用（HookWorker）。
  void ProcessPendingEvents() { TryInstallManagedTextHooks(); }
  void shutdown() override { installed_ = false; }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(
                InterlockedCompareExchange(&g_unity_mono_flags, 0, 0))};
  }

 private:
  // 运行时模块出现后最多尝试这么多拍（每拍间隔 >= kAttemptSpacingMs）：Unity 在播放器
  // 初始化时一次性加载全部脚本程序集，正常几秒内就绪；2 分钟还没有就不再 attach。
  static constexpr int kMaxResolveAttempts = 240;
  static constexpr ULONGLONG kAttemptSpacingMs = 500;

  void TryInstallManagedTextHooks() {
    if (text_done_ || !g_capture_enabled) return;
    // 身份门在任何托管调用之前：非 Mono 构建的进程里即便碰巧有个叫 mono.dll 的模块，
    // 也不 attach、不解析。
    if (!installed_) return;
    const ULONGLONG now = GetTickCount64();
    if (last_attempt_ms_ != 0 && now - last_attempt_ms_ < kAttemptSpacingMs) {
      return;
    }
    last_attempt_ms_ = now;

    HMODULE runtime = FindLoadedUnityMonoRuntime();
    if (runtime == nullptr) return;
    MarkUnityMonoFlag(kUnityMonoFlagRuntimeModule);
    if (!HasCurrentProcessTopLevelWindow()) {
      MarkUnityMonoFlag(kUnityMonoFlagWaitingForWindow);
      return;
    }
    if (++attempts_ > kMaxResolveAttempts) {
      MarkUnityMonoFlag(kUnityMonoFlagResolveExhausted);
      text_done_ = true;
      return;
    }
    const fushi_voice_hook::MonoEmbeddingApi api =
        LoadUnityMonoEmbeddingApi(runtime);
    if (!api.CompleteForResolution()) {
      MarkUnityMonoFlag(kUnityMonoFlagApiIncomplete);
      text_done_ = true;
      return;
    }
    void* domain = api.get_root_domain();
    if (domain == nullptr) return;
    MarkUnityMonoFlag(kUnityMonoFlagRootDomain);

    void* code[fushi_voice_hook::kMonoTextHookCount] = {};
    uint32_t plan = 0;
    {
      fushi_voice_hook::MonoAttachedThreadScope managed_thread(api, domain);
      if (!managed_thread.attached()) {
        MarkUnityMonoFlag(kUnityMonoFlagThreadAttachFailed);
        return;
      }
      const fushi_voice_hook::MonoTextResolution resolution =
          fushi_voice_hook::ResolveUnityMonoTextMethods(api);
      if (!resolution.script_assembly_loaded) return;  // 下一拍再看
      MarkUnityMonoFlag(kUnityMonoFlagScriptAssemblyReady);
      if (resolution.message_renderer_companion) {
        MarkUnityMonoFlag(kUnityMonoFlagMessageRendererSignature);
      }
      plan = fushi_voice_hook::PlanUnityMonoTextHooks(resolution);
      for (size_t i = 0; i < fushi_voice_hook::kMonoTextHookCount; ++i) {
        if ((plan & (1u << i)) == 0) continue;
        code[i] = api.compile_method(resolution.methods[i]);
        if (code[i] == nullptr) MarkUnityMonoFlag(kUnityMonoFlagCompileFailed);
      }
    }
    // 解析只做一次：脚本程序集已就绪，之后不会再出现新的 Unity 文本组件类型。
    text_done_ = true;
    if (plan == 0) {
      MarkUnityMonoFlag(kUnityMonoFlagNoTextClasses);
      return;
    }
    // accessor 必须在第一个 hook 生效前就位；detour 只读它们。
    g_unity_mono_string_length = api.string_length;
    g_unity_mono_string_chars = api.string_chars;
    MemoryBarrier();
    // 已 detach 之后才 HookFn：MH_EnableHook 会挂起全部线程，不在托管线程身份下做。
    for (const UnityMonoDetourBinding& binding : kUnityMonoDetours) {
      const size_t index = static_cast<size_t>(binding.id);
      if (code[index] == nullptr) continue;
      if (HookFn(code[index], binding.detour, binding.original)) {
        MarkUnityMonoFlag(1L << (kUnityMonoFlagHookInstalledShift +
                                 static_cast<LONG>(index)));
      }
    }
  }

  bool installed_ = false;
  bool text_done_ = false;
  int attempts_ = 0;
  ULONGLONG last_attempt_ms_ = 0;
};
