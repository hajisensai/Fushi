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
#include "unity_mono_audio.h"

// adapter 自有诊断字（diagnostics().flags → v23 [adapters] 读数）。只增不减。
constexpr LONG kUnityMonoFlagIdentity = 0x00000001;
constexpr LONG kUnityMonoFlagRuntimeModule = 0x00000002;
constexpr LONG kUnityMonoFlagWaitingForWindow = 0x00000004;
constexpr LONG kUnityMonoFlagApiIncomplete = 0x00000008;
constexpr LONG kUnityMonoFlagRootDomain = 0x00000010;
constexpr LONG kUnityMonoFlagThreadAttachFailed = 0x00000020;
constexpr LONG kUnityMonoFlagScriptAssemblyReady = 0x00000040;
constexpr LONG kUnityMonoFlagMessageRendererSignature = 0x00000080;
// bit 8..13：对应 MonoTextHookId 的 hook 已装（kUnityMonoFlagHookInstalledShift + id）。
constexpr LONG kUnityMonoFlagHookInstalledShift = 8;
// bit 14 / 15：AudioSource 播放内部调用已挂 / Fungus WriterAudio 打字音排除已挂。
constexpr LONG kUnityMonoFlagAudioHooks = 0x00004000;
constexpr LONG kUnityMonoFlagFungusWriterAudio = 0x00008000;
// bit 16..21：对应 MonoTextHookId 的 detour 至少触发过一次（游戏线程置位）。
constexpr LONG kUnityMonoFlagDetourFiredShift = 16;
// bit 22 / 23：发布过一条语音资源事件 / 因本会话没见过 voice bundle 丢弃过播放事件。
constexpr LONG kUnityMonoFlagAudioEventPublished = 0x00400000;
constexpr LONG kUnityMonoFlagAudioNoVoiceBundle = 0x00800000;
constexpr LONG kUnityMonoFlagTextPublished = 0x01000000;
constexpr LONG kUnityMonoFlagResolveExhausted = 0x02000000;
constexpr LONG kUnityMonoFlagCompileFailed = 0x04000000;
constexpr LONG kUnityMonoFlagNoTextClasses = 0x08000000;
// 游戏内查词（unity_mono_lookup.inc）：站点解析成功并装上采样 detour / 被拒。
constexpr LONG kUnityMonoFlagLookupInstalled = 0x10000000;
constexpr LONG kUnityMonoFlagLookupRejected = 0x20000000;
// Fungus SayDialog.DoSay 整句入口解析成功（框架结构判据成立）。
constexpr LONG kUnityMonoFlagFungusSignature = 0x40000000;
static_assert(fushi_voice_hook::kMonoTextHookCount <= 6,
              "hook id bits must fit bits 8..13 / 16..21");

volatile LONG g_unity_mono_flags = 0;
// detour 读字符串用的两个导出。HookFn 之前写好，之后只读。
int (*g_unity_mono_string_length)(void*) = nullptr;
const wchar_t* (*g_unity_mono_string_chars)(void*) = nullptr;
constexpr int kUnityMonoTextMaxChars = 2000;

void MarkUnityMonoFlag(LONG flag) { InterlockedOr(&g_unity_mono_flags, flag); }

// 逐字消息框架的「角色」线程身份（理由见 unity_mono_lookup_core.h 的
// MessageRoleKey）：正文与名牌是同一个 Message 类的两个对象，脚本对每句有说话人的台词
// 先 body.Mes(text) 再 name.Mes(speaker)，共用一条道时道上的最新行永远是名字。
// 角色键 = 该对象的场景名（不透明哈希），场景重载后组件重建仍是同一条道。
// 只在 Unity 主线程上取（Object.GetName 是主线程引擎调用）。Mes 每条消息只调一次，
// 所以每次现取、不按组件指针缓存：Boehm GC 会复用已销毁对象的地址，指针缓存会把
// 新对象错认成旧角色。
fushi_voice_hook::unity_mono_lookup::IcallGetNameFn g_unity_mono_object_get_name =
    nullptr;
DWORD g_unity_mono_main_thread = 0;

uint64_t UnityMonoMessageRole(void* component) {
  if (component == nullptr || g_unity_mono_object_get_name == nullptr ||
      g_unity_mono_main_thread == 0 ||
      GetCurrentThreadId() != g_unity_mono_main_thread) {
    return 0;
  }
  const fushi_voice_hook::MonoStringView name =
      fushi_voice_hook::ReadMonoStringBounded(
          g_unity_mono_object_get_name(component), g_unity_mono_string_length,
          g_unity_mono_string_chars,
          fushi_voice_hook::unity_mono_lookup::kMaxRoleNameUnits);
  return fushi_voice_hook::unity_mono_lookup::MessageRoleKey(name.chars,
                                                             name.length);
}

// Fungus：SayDialog 的故事文本组件（UI.Text）在打字时每显示一个字就被整串重设一次
// （可见部分 + alpha 0 的剩余部分），它在 UI.Text 道上只会把同一句整句重复发几十次；
// 正文已由 DoSay 那条稳定道发布，所以这个组件自己的 UI.Text 事件让位。
// 偏移来自查词站点解析（SayDialog.storyText），HookFn 之前写好；0 = 未知，不让位。
uint32_t g_um_fungus_story_offset = 0;
constexpr size_t kUmFungusStoryTexts = 4;
std::atomic<uintptr_t> g_um_fungus_story_texts[kUmFungusStoryTexts] = {};
std::atomic<uint32_t> g_um_fungus_story_next{0u};

bool UnityMonoIsFungusStoryText(void* component) {
  const uintptr_t value = reinterpret_cast<uintptr_t>(component);
  if (value == 0u) return false;
  for (const auto& slot : g_um_fungus_story_texts) {
    if (slot.load(std::memory_order_acquire) == value) return true;
  }
  return false;
}

// DoSay 在该 SayDialog 自己的方法里运行，对象必然存活：字段直接读。
void RememberUnityMonoFungusStoryText(void* dialog) {
  if (dialog == nullptr || g_um_fungus_story_offset == 0) return;
  const uintptr_t story = *reinterpret_cast<const uintptr_t*>(
      reinterpret_cast<const char*>(dialog) + g_um_fungus_story_offset);
  if (story == 0u || UnityMonoIsFungusStoryText(reinterpret_cast<void*>(story))) {
    return;
  }
  const uint32_t slot =
      g_um_fungus_story_next.fetch_add(1u, std::memory_order_relaxed) %
      kUmFungusStoryTexts;
  g_um_fungus_story_texts[slot].store(story, std::memory_order_release);
}

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
// IEnumerator SayDialog.DoSay(string, bool×5, AudioClip, Action)：bool 按整字转发。
using UnityMonoFungusDoSay = void*(FUSHI_MONO_MANAGED_CALL*)(
    void*, void*, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, void*,
    void*);
UnityMonoFungusDoSay g_orig_UnityMonoFungusDoSay = nullptr;

// 游戏线程上的唯一工作：经导出 accessor 取 UTF-16 视图（纯指针运算，不分配、不进 GC），
// 交给与 IL2CPP 共用的有界发布（RecordUnityTextChars 内部拷进定长 clean[501] 再写共享
// 内存道）。不 attach、不 runtime_invoke、不做 IO。
void RecordUnityMonoText(fushi_voice_hook::MonoTextHookId id, void* component,
                         void* string_object) {
  MarkUnityMonoFlag(1L << (kUnityMonoFlagDetourFiredShift +
                           static_cast<LONG>(id)));
  if (!g_capture_enabled) return;
  if (id == fushi_voice_hook::MonoTextHookId::kUiTextSetText &&
      UnityMonoIsFungusStoryText(component)) {
    return;
  }
  const fushi_voice_hook::MonoStringView view =
      fushi_voice_hook::ReadMonoStringBounded(
          string_object, g_unity_mono_string_length,
          g_unity_mono_string_chars, kUnityMonoTextMaxChars);
  if (view.length <= 0) return;
  const fushi_voice_hook::MonoTextHookSpec& spec =
      fushi_voice_hook::MonoTextHookSpecFor(id);
  const wchar_t* chars = view.chars;
  int length = view.length;
  // Fungus 整句：去掉框架自己的 {...} 控制标记（富文本 <...> 由共用发布入口剥）。
  wchar_t fungus_clean[kUnityMonoTextMaxChars] = {0};
  if (id == fushi_voice_hook::MonoTextHookId::kFungusSayDialogDoSay) {
    length = fushi_voice_hook::StripFungusTextTags(
        view.chars, view.length, fungus_clean, kUnityMonoTextMaxChars);
    chars = fungus_clean;
    if (length <= 0) return;
  }
  const uint64_t role =
      id == fushi_voice_hook::MonoTextHookId::kMessageRendererMes
          ? UnityMonoMessageRole(component)
          : 0;
  if (RecordUnityTextChars(component, chars, length, spec.hook_name,
                           spec.hook_code, spec.stable_identity, role)) {
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

// Fungus 整句入口：迭代器原样返回；text 参数就是当前显示语言的整句。
void* FUSHI_MONO_MANAGED_CALL Detour_UnityMonoFungusDoSay(
    void* self, void* text, uintptr_t clear_previous, uintptr_t wait_for_input,
    uintptr_t fade_when_done, uintptr_t stop_voiceover, uintptr_t wait_for_vo,
    void* voice_over_clip, void* on_complete) {
  void* routine = g_orig_UnityMonoFungusDoSay(
      self, text, clear_previous, wait_for_input, fade_when_done,
      stop_voiceover, wait_for_vo, voice_over_clip, on_complete);
  RememberUnityMonoFungusStoryText(self);
  RecordUnityMonoText(fushi_voice_hook::MonoTextHookId::kFungusSayDialogDoSay,
                      self, text);
  return routine;
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
    {fushi_voice_hook::MonoTextHookId::kFungusSayDialogDoSay,
     reinterpret_cast<void*>(&Detour_UnityMonoFungusDoSay),
     reinterpret_cast<void**>(&g_orig_UnityMonoFungusDoSay)},
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

// 游戏内查词（逐字消息框架的字形几何 + UnityWndClass 窗口过程点击认领）在
// unity_mono_lookup.inc，结构判据与纯逻辑在 unity_mono_lookup_core.h（由 dll_main.cpp
// 在顶层引入）。
#include "unity_mono_lookup.inc"

// ── 逐句语音：AudioSource 播放内部调用 → Unity 资源语音事件 ─────────────────────
// 判据与实测见 unity_mono_audio.h。游戏线程（Unity 主线程）上的 detour 只做：身份/线程
// 门、Fungus 打字音排除、经 Object.GetName 引擎调用取 clip 名并**有界拷贝**进固定长环；
// voice bundle 判定、去重、写共享环事件与日志全在 HookWorker（ProcessUnityMonoAudioEvents）。
namespace umono_audio = fushi_voice_hook::unity_mono_audio;
static_assert(umono_audio::kClipNameUnits == kUnityClipNameChars,
              "Mono audio event names must fit the shared UnityVoiceEvent");

umono_audio::AudioSites g_um_audio;
using UmAudioPlayOneShotFn = void(FUSHI_UNITY_ICALL*)(void*, void*, float);
using UmAudioPlayUlongFn = void(FUSHI_UNITY_ICALL*)(void*, uint64_t);
using UmAudioPlayDoubleFn = void(FUSHI_UNITY_ICALL*)(void*, double);
using UmAudioGetClipFn = void*(FUSHI_UNITY_ICALL*)(void*);
UmAudioPlayOneShotFn g_orig_UmAudioPlayOneShotHelper = nullptr;
UmAudioPlayUlongFn g_orig_UmAudioPlayHelper = nullptr;
UmAudioPlayDoubleFn g_orig_UmAudioPlayDelayed = nullptr;
UmAudioPlayOneShotFn g_orig_UmAudioLegacyPlayOneShot = nullptr;
UmAudioPlayUlongFn g_orig_UmAudioLegacyPlay = nullptr;
using UmWriterAudioNoArgFn = void(FUSHI_MONO_MANAGED_CALL*)(void*);
using UmWriterAudioClipFn = void(FUSHI_MONO_MANAGED_CALL*)(void*, void*);
UmWriterAudioNoArgFn g_orig_UmWriterAudioOnGlyph = nullptr;
UmWriterAudioClipFn g_orig_UmWriterAudioOnStart = nullptr;
UmWriterAudioClipFn g_orig_UmWriterAudioOnVoiceover = nullptr;
// 主线程独占：正处在 Fungus WriterAudio 打字音回调里的层数。
int g_um_writer_audio_depth = 0;
umono_audio::PendingAudioEvent
    g_um_audio_events[umono_audio::kPendingAudioEvents] = {};
volatile LONGLONG g_um_audio_write_count = 0;
LONGLONG g_um_audio_read_count = 0;  // HookWorker only
std::atomic<bool> g_um_audio_live{false};

void RecordUnityMonoAudio(void* source, void* clip, uint32_t flags) {
  if (!g_um_audio_live.load(std::memory_order_acquire) || !g_capture_enabled ||
      g_unity_mono_main_thread == 0 ||
      GetCurrentThreadId() != g_unity_mono_main_thread ||
      !umono_audio::IsVoiceCandidate(flags, g_um_writer_audio_depth)) {
    return;
  }
  if (clip == nullptr && source != nullptr &&
      UmAlive(reinterpret_cast<uintptr_t>(source),
              g_um_audio.cached_ptr_offset)) {
    const auto get_clip = reinterpret_cast<UmAudioGetClipFn>(
        g_um_audio.icalls[static_cast<size_t>(umono_audio::AudioIcall::kGetClip)]);
    if (get_clip != nullptr) clip = get_clip(source);
  }
  if (!UmAlive(reinterpret_cast<uintptr_t>(clip),
               g_um_audio.cached_ptr_offset)) {
    return;
  }
  const auto get_name =
      reinterpret_cast<umono_lookup::IcallGetNameFn>(g_um_audio.get_name);
  const fushi_voice_hook::MonoStringView name =
      fushi_voice_hook::ReadMonoStringBounded(
          get_name(clip), g_unity_mono_string_length,
          g_unity_mono_string_chars,
          static_cast<int>(umono_audio::kClipNameUnits) - 1);
  if (name.length <= 0) return;
  const uint64_t index = static_cast<uint64_t>(
                             InterlockedIncrement64(&g_um_audio_write_count)) -
                         1u;
  umono_audio::PendingAudioEvent& event =
      g_um_audio_events[index % umono_audio::kPendingAudioEvents];
  InterlockedExchange64(reinterpret_cast<volatile LONGLONG*>(&event.seq), 0);
  event.timestamp_ms = GetTickCount64();
  event.flags = flags;
  std::memcpy(event.name, name.chars,
              static_cast<size_t>(name.length) * sizeof(wchar_t));
  event.name[name.length] = 0;
  MemoryBarrier();
  InterlockedExchange64(reinterpret_cast<volatile LONGLONG*>(&event.seq),
                        static_cast<LONGLONG>(index + 1u));
}

// 引擎内部调用（C 函数，x86 cdecl / x64 Win64）：先记录再转发，detour 不持锁，原函数
// 抛托管异常时 Mono 按 LMF 直接回到托管调用方，不经过本帧的收尾。
void FUSHI_UNITY_ICALL Detour_UmAudioPlayOneShotHelper(void* source, void* clip,
                                                       float volume) {
  RecordUnityMonoAudio(source, clip, 0u);
  g_orig_UmAudioPlayOneShotHelper(source, clip, volume);
}
void FUSHI_UNITY_ICALL Detour_UmAudioPlayHelper(void* source, uint64_t delay) {
  RecordUnityMonoAudio(source, nullptr, 0u);
  g_orig_UmAudioPlayHelper(source, delay);
}
void FUSHI_UNITY_ICALL Detour_UmAudioPlayDelayed(void* source, double delay) {
  RecordUnityMonoAudio(source, nullptr, 0u);
  g_orig_UmAudioPlayDelayed(source, delay);
}
void FUSHI_UNITY_ICALL Detour_UmAudioLegacyPlayOneShot(void* source,
                                                       void* clip,
                                                       float volume) {
  RecordUnityMonoAudio(source, clip, 0u);
  g_orig_UmAudioLegacyPlayOneShot(source, clip, volume);
}
void FUSHI_UNITY_ICALL Detour_UmAudioLegacyPlay(void* source, uint64_t delay) {
  RecordUnityMonoAudio(source, nullptr, 0u);
  g_orig_UmAudioLegacyPlay(source, delay);
}

// Fungus WriterAudio（托管，主线程）：打字音回调期间的播放不是语音；OnVoiceover 的
// clip 是框架明说的这一句语音。层数只在主线程上动。
void FUSHI_MONO_MANAGED_CALL Detour_UmWriterAudioOnGlyph(void* self) {
  const bool main = GetCurrentThreadId() == g_unity_mono_main_thread;
  if (main) ++g_um_writer_audio_depth;
  g_orig_UmWriterAudioOnGlyph(self);
  if (main && g_um_writer_audio_depth > 0) --g_um_writer_audio_depth;
}
void FUSHI_MONO_MANAGED_CALL Detour_UmWriterAudioOnStart(void* self,
                                                         void* clip) {
  const bool main = GetCurrentThreadId() == g_unity_mono_main_thread;
  if (main) ++g_um_writer_audio_depth;
  g_orig_UmWriterAudioOnStart(self, clip);
  if (main && g_um_writer_audio_depth > 0) --g_um_writer_audio_depth;
}
void FUSHI_MONO_MANAGED_CALL Detour_UmWriterAudioOnVoiceover(void* self,
                                                             void* clip) {
  RecordUnityMonoAudio(nullptr, clip, umono_audio::kAudioFlagFungusVoiceover);
  const bool main = GetCurrentThreadId() == g_unity_mono_main_thread;
  if (main) ++g_um_writer_audio_depth;
  g_orig_UmWriterAudioOnVoiceover(self, clip);
  if (main && g_um_writer_audio_depth > 0) --g_um_writer_audio_depth;
}

struct UmAudioDetourBinding {
  umono_audio::AudioIcall id;
  void* detour;
  void** original;
};
const UmAudioDetourBinding kUmAudioDetours[] = {
    {umono_audio::AudioIcall::kPlayOneShotHelper,
     reinterpret_cast<void*>(&Detour_UmAudioPlayOneShotHelper),
     reinterpret_cast<void**>(&g_orig_UmAudioPlayOneShotHelper)},
    {umono_audio::AudioIcall::kPlayHelper,
     reinterpret_cast<void*>(&Detour_UmAudioPlayHelper),
     reinterpret_cast<void**>(&g_orig_UmAudioPlayHelper)},
    {umono_audio::AudioIcall::kPlayDelayed,
     reinterpret_cast<void*>(&Detour_UmAudioPlayDelayed),
     reinterpret_cast<void**>(&g_orig_UmAudioPlayDelayed)},
    {umono_audio::AudioIcall::kLegacyPlayOneShot,
     reinterpret_cast<void*>(&Detour_UmAudioLegacyPlayOneShot),
     reinterpret_cast<void**>(&g_orig_UmAudioLegacyPlayOneShot)},
    {umono_audio::AudioIcall::kLegacyPlay,
     reinterpret_cast<void*>(&Detour_UmAudioLegacyPlay),
     reinterpret_cast<void**>(&g_orig_UmAudioLegacyPlay)},
};

struct UmWriterAudioBinding {
  umono_audio::WriterAudioMethod id;
  void* detour;
  void** original;
};
const UmWriterAudioBinding kUmWriterAudioDetours[] = {
    {umono_audio::WriterAudioMethod::kOnGlyph,
     reinterpret_cast<void*>(&Detour_UmWriterAudioOnGlyph),
     reinterpret_cast<void**>(&g_orig_UmWriterAudioOnGlyph)},
    {umono_audio::WriterAudioMethod::kOnStart,
     reinterpret_cast<void*>(&Detour_UmWriterAudioOnStart),
     reinterpret_cast<void**>(&g_orig_UmWriterAudioOnStart)},
    {umono_audio::WriterAudioMethod::kOnVoiceover,
     reinterpret_cast<void*>(&Detour_UmWriterAudioOnVoiceover),
     reinterpret_cast<void**>(&g_orig_UmWriterAudioOnVoiceover)},
};

// HookWorker：抽取主线程入的播放事件 → 去重 → 有 voice bundle（或框架明说的
// voiceover）才发布资源事件；并在证据成立时宣布「Unity 资源语音链就绪」。
void ProcessUnityMonoAudioEvents() {
  if (!g_um_audio_live.load(std::memory_order_acquire) || g_header == nullptr) {
    return;
  }
  static umono_audio::RecentClip recent;
  static bool logged_no_bundle = false;
  static uint32_t logged_events = 0;
  wchar_t bundle[kUnityBundlePathChars] = {0};
  CopyLastUnityVoiceBundle(bundle, kUnityBundlePathChars);
  const bool bundle_known = bundle[0] != 0;
  // 资源语音就绪：播放入口已挂，且本会话要么见过 voice bundle，要么有框架的
  // voiceover 信号。只装了播放 hook 而没有任何语音资源证据时不宣布（宿主会因此切到
  // 资源模式而永远等不到文件）。
  if (bundle_known || g_um_audio.HasWriterAudio()) {
    g_header->reserved_hook_diagnostics |=
        fushi_voice_hook::kDiagUnityAudioPlaybackHookReady;
  }
  for (uint32_t processed = 0; processed < umono_audio::kPendingAudioEvents;
       ++processed) {
    const LONGLONG written = InterlockedCompareExchange64(
        &g_um_audio_write_count, 0, 0);
    if (g_um_audio_read_count >= written) break;
    const LONGLONG oldest =
        written > static_cast<LONGLONG>(umono_audio::kPendingAudioEvents)
            ? written - static_cast<LONGLONG>(umono_audio::kPendingAudioEvents)
            : 0;
    if (g_um_audio_read_count < oldest) g_um_audio_read_count = oldest;
    umono_audio::PendingAudioEvent& slot =
        g_um_audio_events[static_cast<uint64_t>(g_um_audio_read_count) %
                          umono_audio::kPendingAudioEvents];
    const LONGLONG expected = g_um_audio_read_count + 1;
    if (InterlockedCompareExchange64(
            reinterpret_cast<volatile LONGLONG*>(&slot.seq), 0, 0) !=
        expected) {
      break;  // producer still filling this slot
    }
    MemoryBarrier();
    umono_audio::PendingAudioEvent event = slot;
    MemoryBarrier();
    if (InterlockedCompareExchange64(
            reinterpret_cast<volatile LONGLONG*>(&slot.seq), 0, 0) !=
        expected) {
      break;
    }
    ++g_um_audio_read_count;
    event.name[umono_audio::kClipNameUnits - 1u] = 0;
    if (umono_audio::IsDuplicatePlayback(&recent, event.name,
                                         event.timestamp_ms)) {
      continue;
    }
    if (!umono_audio::ShouldPublishAudioEvent(event.flags, bundle_known)) {
      MarkUnityMonoFlag(kUnityMonoFlagAudioNoVoiceBundle);
      if (!logged_no_bundle) {
        logged_no_bundle = true;
        UmLookupLog(L"unity-mono-audio: gate=no-voice-bundle (playback seen, no "
                    L"*voice*.bundle opened this session; not published)");
      }
      continue;
    }
    PublishUnityVoiceEvent(event.name, bundle, event.timestamp_ms);
    MarkUnityMonoFlag(kUnityMonoFlagAudioEventPublished);
    if (logged_events < 32u) {
      ++logged_events;
      UmLookupLog(L"unity-mono-audio: event ts=%llu clip=%s voiceover=%d "
                  L"bundle=%s",
                  static_cast<unsigned long long>(event.timestamp_ms),
                  event.name,
                  (event.flags & umono_audio::kAudioFlagFungusVoiceover) != 0u
                      ? 1
                      : 0,
                  bundle_known ? L"voice" : L"(data-dir)");
    }
  }
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
    // 语音资源判据要「本会话打开过的 *voice*.bundle」：共用的文件 API 钩子记下它
    // （RememberUnityVoiceBundle）。Unity 在播放器初始化时就加载 Addressables 包，
    // 所以随身份一起在启动挂起期装上，晚于第一个包就永远看不见。
    if (installed_ && !file_hooks_) file_hooks_ = TryHookSiglusOvk();
    // shutdown 之后再 install：FixedUpdate detour 仍挂着，只需恢复采样。
    if (installed_ && text_done_ && lookup_framework_) {
      ReinstallUnityMonoLookup();
    }
    return installed_;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kPcmAudio |
           fushi_voice_hook::AdapterCapability::kResourceAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    // 身份来自磁盘布局，启动时一次判定即可；模块通知只作重试接缝。
    if (!installed_ && module_name == nullptr) install();
  }
  // registry Poll 调用（HookWorker）。
  void ProcessPendingEvents() {
    TryInstallManagedTextHooks();
    ProcessUnityMonoLookupTick();
    ProcessUnityMonoAudioEvents();
  }
  void shutdown() override {
    ShutdownUnityMonoLookup();
    installed_ = false;
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    if (UnityMonoLookupSensorInstalled()) {
      report.state = fushi_voice_hook::kLookupAdmissionSensorInstalled;
      return report;
    }
    // 站点解析过且被拒：本 exe 的终态，给 host 摘要让它去报告。
    if (UnityMonoLookupSitesRejected()) {
      report.state = fushi_voice_hook::kLookupAdmissionIdentityRejected;
      strncpy_s(report.executable_sha256,
                fushi_voice_hook::HostExecutableSha256Hex(), _TRUNCATE);
      return report;
    }
    // 托管解析已结束但脚本程序集里没有逐字消息框架：查词只覆盖这一框架。
    if (text_done_ && !lookup_framework_) {
      report.state = fushi_voice_hook::kLookupAdmissionEngineUnsupported;
      return report;
    }
    report.state = fushi_voice_hook::kLookupAdmissionIdentityAccepted;
    return report;
  }
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
    void* lookup_code = nullptr;
    void* get_name = nullptr;
    umono_audio::AudioSites audio;
    umono_audio::AudioSiteResult audio_result =
        umono_audio::AudioSiteResult::kApiIncomplete;
    void* writer_audio_code[umono_audio::kWriterAudioMethodCount] = {};
    bool fungus_framework = false;
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
      // 查词覆盖两个框架（同一个 provider id 20）：逐字消息框架
      // （PlanUnityMonoTextHooks 认定了 Mes + 伴随判据）优先；否则 Fungus 的
      // SayDialog.DoSay 在计划里即走 Fungus 分支。角色身份的 Object.GetName 与
      // 查词站点都在同一个 attach 作用域里取。
      const bool message_framework =
          (plan & fushi_voice_hook::MonoTextHookBit(
                      fushi_voice_hook::MonoTextHookId::kMessageRendererMes)) !=
          0;
      fungus_framework =
          !message_framework &&
          (plan & fushi_voice_hook::MonoTextHookBit(
                      fushi_voice_hook::MonoTextHookId::kFungusSayDialogDoSay)) !=
              0;
      if (fungus_framework) MarkUnityMonoFlag(kUnityMonoFlagFungusSignature);
      lookup_framework_ = message_framework || fungus_framework;
      if (message_framework) {
        get_name = fushi_voice_hook::unity_mono_lookup::ResolveObjectGetName(
            api, LoadUnityMonoLookupApi(runtime));
        lookup_code = ResolveUnityMonoLookup(api, runtime, domain);
      } else if (fungus_framework) {
        lookup_code = ResolveUnityMonoFungusLookup(api, runtime);
      }
      // 逐句语音（所有 Unity Mono 构建）：AudioSource 播放内部调用 + 可选的 Fungus
      // WriterAudio 回调，同一个 attach 作用域里解析 / 编译。
      audio_result = umono_audio::ResolveAudioSites(
          api, LoadUnityMonoLookupApi(runtime), &audio);
      if (audio_result == umono_audio::AudioSiteResult::kResolved &&
          audio.HasWriterAudio()) {
        for (size_t i = 0; i < umono_audio::kWriterAudioMethodCount; ++i) {
          writer_audio_code[i] = api.compile_method(audio.writer_audio[i]);
        }
      }
    }
    // 解析只做一次：脚本程序集已就绪，之后不会再出现新的 Unity 文本组件类型。
    text_done_ = true;
    if (plan == 0) MarkUnityMonoFlag(kUnityMonoFlagNoTextClasses);
    // accessor 必须在第一个 hook 生效前就位；detour 只读它们。
    g_unity_mono_string_length = api.string_length;
    g_unity_mono_string_chars = api.string_chars;
    const bool audio_ready =
        audio_result == umono_audio::AudioSiteResult::kResolved;
    if (lookup_framework_ || audio_ready) {
      const HWND unity_window = FindUmGameWindow();
      g_unity_mono_main_thread =
          unity_window == nullptr
              ? 0
              : GetWindowThreadProcessId(unity_window, nullptr);
    }
    if (lookup_framework_ && !fungus_framework) {
      g_unity_mono_object_get_name =
          reinterpret_cast<fushi_voice_hook::unity_mono_lookup::IcallGetNameFn>(
              get_name);
    }
    if (fungus_framework && lookup_code != nullptr) {
      g_um_fungus_story_offset = g_um_lookup.fungus.story_text_offset;
    }
    if (audio_ready) g_um_audio = audio;
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
    if (lookup_framework_) {
      MarkUnityMonoFlag(InstallUnityMonoLookupHooks(lookup_code)
                            ? kUnityMonoFlagLookupInstalled
                            : kUnityMonoFlagLookupRejected);
    }
    InstallUnityMonoAudioHooks(audio_ready, audio_result, writer_audio_code);
  }

  // 播放入口与 Fungus WriterAudio：打字音排除必须先于播放入口生效（否则第一拍的
  // 打字音会漏成语音候选），全部在 detach 之后装。
  void InstallUnityMonoAudioHooks(
      bool ready, umono_audio::AudioSiteResult result,
      void* const (&writer_audio_code)[umono_audio::kWriterAudioMethodCount]) {
    if (!ready || g_unity_mono_main_thread == 0) {
      UmLookupLog(L"unity-mono-audio: gate=sites-unresolved result=%u main=%lu",
                  static_cast<unsigned>(result), g_unity_mono_main_thread);
      return;
    }
    bool writer_hooked = g_um_audio.HasWriterAudio();
    for (const UmWriterAudioBinding& binding : kUmWriterAudioDetours) {
      void* target = writer_audio_code[static_cast<size_t>(binding.id)];
      if (target == nullptr ||
          !HookFn(target, binding.detour, binding.original)) {
        writer_hooked = false;
      }
    }
    if (g_um_audio.HasWriterAudio() && !writer_hooked) {
      // 排除不完整就不装播放入口：宁可没有语音，也不把打字音发成语音候选。
      UmLookupLog(L"unity-mono-audio: gate=writer-audio-hook-failed");
      return;
    }
    if (writer_hooked) MarkUnityMonoFlag(kUnityMonoFlagFungusWriterAudio);
    g_um_audio_live.store(true, std::memory_order_release);
    int hooked = 0;
    for (const UmAudioDetourBinding& binding : kUmAudioDetours) {
      void* target = g_um_audio.icalls[static_cast<size_t>(binding.id)];
      if (target != nullptr && HookFn(target, binding.detour, binding.original)) {
        ++hooked;
      }
    }
    if (hooked > 0) MarkUnityMonoFlag(kUnityMonoFlagAudioHooks);
    UmLookupLog(L"unity-mono-audio: hooks playback=%d writer_audio=%d "
                L"cached=+%u main=%lu",
                hooked, writer_hooked ? 1 : 0, g_um_audio.cached_ptr_offset,
                g_unity_mono_main_thread);
  }

  bool installed_ = false;
  bool file_hooks_ = false;
  bool text_done_ = false;
  bool lookup_framework_ = false;
  int attempts_ = 0;
  ULONGLONG last_attempt_ms_ = 0;
};
