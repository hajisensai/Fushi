// P1 zero-behaviour-change split: included inside dll_main.cpp anonymous namespace.
// ══ C.2e Unity IL2CPP AudioClip 资源捕获 ═══════════════════════════════════════
// Unity 6 桌面播放器会在 UnityPlayer 内部直接混音并经 WASAPI 输出，不一定创建可见的
// IXAudio2 source voice。对这种游戏，XAudio2/Loopback 都不是“游戏资源音频”。IL2CPP 仍会
// 调 UnityEngine.AudioSource.Play/PlayOneShot；在这两个托管入口拿到当前 AudioClip，再通过
// AudioClip.GetData 读取该资源的解码后 float PCM，写入和其它引擎相同的 clip 环。这样每条
// VoiceClip 的 timestamp 就是实际播放调用时刻，能和 Luna 文本按时间戳一一配对。
using Il2CppDomainGet = void* (*)();
using Il2CppDomainGetAssemblies = const void** (*)(const void*, size_t*);
using Il2CppAssemblyGetImage = const void* (*)(const void*);
using Il2CppClassFromName = void* (*)(const void*, const char*, const char*);
using Il2CppClassGetMethodFromName = const void* (*)(void*, const char*, int);
using Il2CppClassGetMethods = const void* (*)(void*, void**);
using Il2CppMethodGetName = const char* (*)(const void*);
using Il2CppMethodGetParamCount = uint32_t (*)(const void*);
using Il2CppMethodGetParam = const void* (*)(const void*, uint32_t);
using Il2CppTypeGetName = char* (*)(const void*);
using Il2CppFree = void (*)(void*);
using Il2CppRuntimeInvoke = void* (*)(const void*, void*, void**, void**);
using Il2CppArrayNew = void* (*)(void*, uintptr_t);
using Il2CppObjectUnbox = void* (*)(void*);
using Il2CppGetCorlib = const void* (*)();
using Il2CppStringChars = const wchar_t* (*)(void*);
using Il2CppStringLength = int (*)(void*);
using Il2CppThreadCurrent = void* (*)();
using Il2CppThreadAttach = void* (*)(void*);
using Il2CppThreadDetach = void (*)(void*);

Il2CppRuntimeInvoke g_il2cpp_runtime_invoke = nullptr;
Il2CppArrayNew g_il2cpp_array_new = nullptr;
Il2CppObjectUnbox g_il2cpp_object_unbox = nullptr;
Il2CppStringChars g_il2cpp_string_chars = nullptr;
Il2CppStringLength g_il2cpp_string_length = nullptr;
Il2CppClassGetMethods g_il2cpp_class_get_methods = nullptr;
Il2CppMethodGetName g_il2cpp_method_get_name = nullptr;
Il2CppMethodGetParamCount g_il2cpp_method_get_param_count = nullptr;
Il2CppMethodGetParam g_il2cpp_method_get_param = nullptr;
Il2CppTypeGetName g_il2cpp_type_get_name = nullptr;
Il2CppFree g_il2cpp_free = nullptr;
// IL2CPP 线程注册入口。Unity 的 audio/mixer 线程执行 scheduled/delayed play 的内部 Helper
// 时并未注册到 GC，若在其上分配托管内存（array_new / 装箱 / GetData / get_name）Boehm GC 会
// 以 "Collecting from unknown thread" 直接 abort 杀掉游戏。捕获前用它们把当前线程临时 attach。
Il2CppDomainGet g_il2cpp_domain_get = nullptr;
Il2CppThreadCurrent g_il2cpp_thread_current = nullptr;
Il2CppThreadAttach g_il2cpp_thread_attach = nullptr;
Il2CppThreadDetach g_il2cpp_thread_detach = nullptr;
const void* g_unity_clip_get_samples = nullptr;
const void* g_unity_clip_get_channels = nullptr;
const void* g_unity_clip_get_frequency = nullptr;
const void* g_unity_clip_get_data = nullptr;
const void* g_unity_source_get_clip = nullptr;
const void* g_unity_object_get_name = nullptr;
void* g_system_single_class = nullptr;
volatile LONG g_unity_capture_busy = 0;
void* g_last_unity_clip = nullptr;
ULONGLONG g_last_unity_clip_tick = 0;
wchar_t g_last_unity_voice_bundle[kUnityBundlePathChars] = {0};

using UnityAudioSourcePlay = void (*)(void*, const void*);
using UnityAudioSourcePlayOneShot1 = void (*)(void*, void*, const void*);
using UnityAudioSourcePlayOneShot2 = void (*)(void*, void*, float,
                                               const void*);
using UnityAudioSourceSetClip = void (*)(void*, void*, const void*);
using UnityAudioSourcePlayScheduled = void (*)(void*, double, const void*);
using UnityAudioSourcePlayDelayed = void (*)(void*, float, const void*);
using UnityAudioSourcePlayHelper = void (*)(void*, uint64_t, const void*);
using UnityAudioSourcePlayOneShotHelper = void (*)(void*, void*, float,
                                                   const void*);
using UnityAudioSourcePlayDelayedHelper = void (*)(void*, float,
                                                   const void*);
UnityAudioSourcePlay g_orig_UnityAudioSourcePlay = nullptr;
UnityAudioSourcePlayOneShot1 g_orig_UnityAudioSourcePlayOneShot1 = nullptr;
UnityAudioSourcePlayOneShot2 g_orig_UnityAudioSourcePlayOneShot2 = nullptr;
UnityAudioSourceSetClip g_orig_UnityAudioSourceSetClip = nullptr;
UnityAudioSourcePlayScheduled g_orig_UnityAudioSourcePlayScheduled = nullptr;
UnityAudioSourcePlayDelayed g_orig_UnityAudioSourcePlayDelayed = nullptr;
UnityAudioSourcePlayHelper g_orig_UnityAudioSourcePlayHelper = nullptr;
UnityAudioSourcePlayOneShotHelper g_orig_UnityAudioSourcePlayOneShotHelper =
    nullptr;
UnityAudioSourcePlayDelayedHelper g_orig_UnityAudioSourcePlayDelayedHelper =
    nullptr;
using UnityTmpSetText = void (*)(void*, void*, const void*);
UnityTmpSetText g_orig_UnityTmpSetText = nullptr;
using UnityTmpSetText2 = void (*)(void*, void*, bool, const void*);
UnityTmpSetText2 g_orig_UnityTmpSetText2 = nullptr;
using NaninovelRevealableSetText = void (*)(void*, void*, const void*);
NaninovelRevealableSetText g_orig_NaninovelRevealableSetText = nullptr;

int InvokeUnityInt(const void* method, void* instance) {
  if (method == nullptr || instance == nullptr ||
      g_il2cpp_runtime_invoke == nullptr || g_il2cpp_object_unbox == nullptr) {
    return 0;
  }
  void* exception = nullptr;
  void* boxed = g_il2cpp_runtime_invoke(method, instance, nullptr, &exception);
  if (boxed == nullptr || exception != nullptr) return 0;
  void* value = g_il2cpp_object_unbox(boxed);
  return value == nullptr ? 0 : *static_cast<int*>(value);
}

bool InvokeUnityBool(const void* method, void* instance, void** args) {
  if (method == nullptr || instance == nullptr ||
      g_il2cpp_runtime_invoke == nullptr || g_il2cpp_object_unbox == nullptr) {
    return false;
  }
  void* exception = nullptr;
  void* boxed = g_il2cpp_runtime_invoke(method, instance, args, &exception);
  if (boxed == nullptr || exception != nullptr) return false;
  void* value = g_il2cpp_object_unbox(boxed);
  return value != nullptr && *static_cast<uint8_t*>(value) != 0;
}

bool CopyUnityClipName(void* clip, wchar_t* out, size_t out_chars) {
  if (clip == nullptr || out == nullptr || out_chars == 0 ||
      g_unity_object_get_name == nullptr || g_il2cpp_runtime_invoke == nullptr ||
      g_il2cpp_string_chars == nullptr || g_il2cpp_string_length == nullptr) {
    return false;
  }
  void* exception = nullptr;
  void* string_object = g_il2cpp_runtime_invoke(
      g_unity_object_get_name, clip, nullptr, &exception);
  if (string_object == nullptr || exception != nullptr) return false;
  const wchar_t* chars = g_il2cpp_string_chars(string_object);
  const int length = g_il2cpp_string_length(string_object);
  if (chars == nullptr || length <= 0) return false;
  const size_t copy = (static_cast<size_t>(length) < out_chars - 1)
                          ? static_cast<size_t>(length)
                          : out_chars - 1;
  memcpy(out, chars, copy * sizeof(wchar_t));
  out[copy] = 0;
  return true;
}

void RecordUnityTmpText(void* text_component, void* string_object,
                        const char* hook_name, const wchar_t* hook_code) {
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      text_component == nullptr || string_object == nullptr ||
      g_il2cpp_string_chars == nullptr || g_il2cpp_string_length == nullptr) {
    return;
  }
  const wchar_t* chars = g_il2cpp_string_chars(string_object);
  const int source_length = g_il2cpp_string_length(string_object);
  if (chars == nullptr || source_length <= 0) return;

  // TMP 富文本标签不显示为正文；移除 <...> 后保存用户实际看到的文本。保留换行与标点，
  // 由 component 指针充当线程 id，让 UI 像 Luna 一样选择“正文 TextMeshPro 组件”。
  wchar_t clean[501] = {0};
  int length = 0;
  bool in_tag = false;
  bool has_cjk = false;
  int meaningful = 0;
  for (int i = 0; i < source_length && length < 500; ++i) {
    const wchar_t c = chars[i];
    if (c == L'<') {
      in_tag = true;
      continue;
    }
    if (in_tag) {
      if (c == L'>') in_tag = false;
      continue;
    }
    clean[length++] = c;
    if (c != L' ' && c != L'\t' && c != L'\r' && c != L'\n' && c >= 0x20) {
      ++meaningful;
      if (c >= 0x3000) has_cjk = true;
    }
  }
  if (length == 0 || meaningful == 0 || (!has_cjk && meaningful < 2)) return;

  const LONGLONG reserved = InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&g_header->text_write_count));
  const uint64_t index = static_cast<uint64_t>(reserved) - 1;
  uint8_t* slot = g_text_base +
      static_cast<size_t>(index % kTextSlotCount) * kTextSlotBytes;
  auto* text_slot = reinterpret_cast<TextSlot*>(slot);
  memset(text_slot, 0, sizeof(TextSlot));
  uint32_t byte_length = static_cast<uint32_t>(length) * sizeof(wchar_t);
  uint32_t max_bytes = kTextSlotBytes - static_cast<uint32_t>(sizeof(TextSlot));
  max_bytes -= max_bytes % sizeof(wchar_t);
  if (byte_length > max_bytes) byte_length = max_bytes;
  memcpy(slot + sizeof(TextSlot), clean, byte_length);
  text_slot->timestamp_ms = GetTickCount64();
  text_slot->byte_len = byte_length;
  text_slot->is_utf8 = 0;
  text_slot->thread_id = reinterpret_cast<uint64_t>(text_component);
  text_slot->thread_context = reinterpret_cast<uint64_t>(text_component);
  text_slot->process_id = GetCurrentProcessId();
  text_slot->source_kind = hibiki_voice_hook::kTextSourceUnityTmp;
  const size_t hook_name_capacity = sizeof(text_slot->hook_name) - 1;
  const size_t hook_name_length =
      hook_name == nullptr ? 0 : strnlen_s(hook_name, hook_name_capacity);
  text_slot->hook_name_len = static_cast<uint32_t>(hook_name_length);
  if (hook_name_length != 0) {
    memcpy(text_slot->hook_name, hook_name, hook_name_length);
  }
  const size_t hook_code_capacity =
      sizeof(text_slot->hook_code) / sizeof(wchar_t) - 1;
  const size_t hook_code_length =
      hook_code == nullptr ? 0 : wcsnlen_s(hook_code, hook_code_capacity);
  text_slot->hook_code_len = static_cast<uint32_t>(hook_code_length);
  if (hook_code_length != 0) {
    memcpy(text_slot->hook_code, hook_code,
           hook_code_length * sizeof(wchar_t));
  }
  MemoryBarrier();
  text_slot->seq = static_cast<uint64_t>(reserved);
  g_header->text_hooked = 1;
}

void RecordUnityVoiceResourceEvent(void* clip, uint64_t timestamp_ms) {
  if (g_header == nullptr || clip == nullptr) return;
  wchar_t clip_name[kUnityClipNameChars] = {0};
  if (!CopyUnityClipName(clip, clip_name, kUnityClipNameChars)) return;

  wchar_t bundle_path[kUnityBundlePathChars] = {0};
  if (g_cs_ready) {
    EnterCriticalSection(&g_cs);
    wcsncpy_s(bundle_path, g_last_unity_voice_bundle, _TRUNCATE);
    LeaveCriticalSection(&g_cs);
  }

  const uint64_t index = static_cast<uint64_t>(InterlockedExchangeAdd64(
      reinterpret_cast<volatile LONGLONG*>(
          &g_header->unity_voice_write_count),
      1));
  UnityVoiceEvent* event =
      &g_header->unity_voice_events[index % kUnityVoiceEventCount];
  event->seq = 0;
  event->timestamp_ms = timestamp_ms;
  wcsncpy_s(event->clip_name, clip_name, _TRUNCATE);
  wcsncpy_s(event->bundle_path, bundle_path, _TRUNCATE);
  MemoryBarrier();
  event->seq = index + 1;
}

void CaptureUnityAudioClip(void* source, void* clip) {
  if (!g_capture_enabled || clip == nullptr || g_header == nullptr ||
      g_system_single_class == nullptr || g_il2cpp_array_new == nullptr) {
    return;
  }
  const ULONGLONG now = GetTickCount64();
  // PlayOneShot(AudioClip) 的一参数包装会继续调用二参数重载；同一资源同一播放只写一次。
  if (clip == g_last_unity_clip && now - g_last_unity_clip_tick < 100) return;
  if (InterlockedCompareExchange(&g_unity_capture_busy, 1, 0) != 0) return;
  g_header->hook_diagnostics |= kDiagUnityIl2CppPlaybackObserved;
  // 本函数随后的每一个托管调用（RecordUnityVoiceResourceEvent 的 get_name、InvokeUnityInt
  // 的装箱、array_new、AudioClip.GetData）都在托管堆分配。scheduled/delayed 播放会把内部
  // Helper 派到 Unity 原生 audio 线程执行——那条线程未注册到 IL2CPP 域，直接分配会命中
  // Boehm GC 的 "Collecting from unknown thread" 崩溃。进入托管区前确保当前线程已注册。
  const hibiki_voice_hook::Il2CppThreadFns il2cpp_thread_fns{
      g_il2cpp_thread_current, g_il2cpp_thread_attach, g_il2cpp_thread_detach,
      g_il2cpp_domain_get};
  hibiki_voice_hook::Il2CppManagedThreadScope managed_thread(il2cpp_thread_fns);
  if (!managed_thread.safe()) {
    // 未注册且无法 attach：宁可放弃这次资源事件与 PCM，也不冒崩溃风险。
    g_header->hook_diagnostics |= kDiagUnityIl2CppGetDataRejected;
    InterlockedExchange(&g_unity_capture_busy, 0);
    return;
  }
  RecordUnityVoiceResourceEvent(clip, now);
  // Streaming AudioClip 的 GetData 会拒绝读取，但资源事件仍然有效。去重状态必须在这里
  // 更新，否则 Unity 6 的 public 包装与内部 Helper 会为同一次播放各触发一次解析/转码。
  g_last_unity_clip = clip;
  g_last_unity_clip_tick = now;

  const int samples = InvokeUnityInt(g_unity_clip_get_samples, clip);
  const int channels = InvokeUnityInt(g_unity_clip_get_channels, clip);
  const int frequency = InvokeUnityInt(g_unity_clip_get_frequency, clip);
  const uint64_t value_count =
      samples > 0 && channels > 0
          ? static_cast<uint64_t>(samples) * static_cast<uint64_t>(channels)
          : 0;
  const uint64_t byte_count = value_count * sizeof(float);
  // 跳过 BGM/整轨资源与异常元数据。角色单句上限取 120 秒；同时必须装得进共享音频环。
  const bool sane = frequency >= 8000 && frequency <= 192000 &&
                    channels >= 1 && channels <= 8 && samples > 0 &&
                    static_cast<uint64_t>(samples) <=
                        static_cast<uint64_t>(frequency) * 120 &&
                    byte_count > 0 && byte_count <= g_ring_capacity;
  if (sane) {
    void* array = g_il2cpp_array_new(g_system_single_class,
                                     static_cast<uintptr_t>(value_count));
    if (array != nullptr) {
      int offset_samples = 0;
      void* args[2] = {array, &offset_samples};
      if (InvokeUnityBool(g_unity_clip_get_data, clip, args)) {
        // Il2CppArray = Il2CppObject(klass,monitor) + bounds + max_length；随后即 vector。
        const auto* pcm = reinterpret_cast<const uint8_t*>(array) +
                          sizeof(void*) * 4;
        const uint32_t len = static_cast<uint32_t>(byte_count);
        const uint32_t off = RingAppendVoice(pcm, len);
        RecordVoiceClipFmt(off, len, reinterpret_cast<uint64_t>(source),
                           static_cast<uint32_t>(frequency),
                           static_cast<uint32_t>(channels), 32, 1);
        if (InterlockedCompareExchange(&g_format_set, 1, 0) == 0) {
          g_header->sample_rate = static_cast<uint32_t>(frequency);
          g_header->channels = static_cast<uint32_t>(channels);
          g_header->bits_per_sample = 32;
          g_header->is_float = 1;
          g_header->block_align = static_cast<uint32_t>(channels) * 4;
        }
        g_header->hook_diagnostics |= kDiagUnityIl2CppClipCaptured;
      } else {
        g_header->hook_diagnostics |= kDiagUnityIl2CppGetDataRejected;
      }
    }
  } else {
    g_header->hook_diagnostics |= kDiagUnityIl2CppGetDataRejected;
  }
  InterlockedExchange(&g_unity_capture_busy, 0);
}

void Detour_UnityAudioSourcePlay(void* self, const void* method) {
  void* clip = nullptr;
  if (g_il2cpp_runtime_invoke != nullptr && g_unity_source_get_clip != nullptr) {
    void* exception = nullptr;
    clip = g_il2cpp_runtime_invoke(g_unity_source_get_clip, self, nullptr,
                                   &exception);
    if (exception != nullptr) clip = nullptr;
  }
  CaptureUnityAudioClip(self, clip);
  g_orig_UnityAudioSourcePlay(self, method);
}

void Detour_UnityAudioSourcePlayOneShot1(void* self, void* clip,
                                         const void* method) {
  CaptureUnityAudioClip(self, clip);
  g_orig_UnityAudioSourcePlayOneShot1(self, clip, method);
}

void Detour_UnityAudioSourcePlayOneShot2(void* self, void* clip,
                                         float volume_scale,
                                         const void* method) {
  CaptureUnityAudioClip(self, clip);
  g_orig_UnityAudioSourcePlayOneShot2(self, clip, volume_scale, method);
}

void Detour_UnityAudioSourceSetClip(void* self, void* clip,
                                    const void* method) {
  g_orig_UnityAudioSourceSetClip(self, clip, method);
  // Naninovel 的 voice player 复用 AudioSource：每句先 set_clip，随后直接走 UnityPlayer
  // 内部的 scheduled play。资源在 set_clip 返回后已绑定，适合立即读取且时间戳仍紧邻台词。
  CaptureUnityAudioClip(self, clip);
}

void Detour_UnityAudioSourcePlayScheduled(void* self, double time,
                                          const void* method) {
  void* clip = nullptr;
  if (g_il2cpp_runtime_invoke != nullptr && g_unity_source_get_clip != nullptr) {
    void* exception = nullptr;
    clip = g_il2cpp_runtime_invoke(g_unity_source_get_clip, self, nullptr,
                                   &exception);
    if (exception != nullptr) clip = nullptr;
  }
  CaptureUnityAudioClip(self, clip);
  g_orig_UnityAudioSourcePlayScheduled(self, time, method);
}

void Detour_UnityAudioSourcePlayDelayed(void* self, float delay,
                                        const void* method) {
  void* clip = nullptr;
  if (g_il2cpp_runtime_invoke != nullptr && g_unity_source_get_clip != nullptr) {
    void* exception = nullptr;
    clip = g_il2cpp_runtime_invoke(g_unity_source_get_clip, self, nullptr,
                                   &exception);
    if (exception != nullptr) clip = nullptr;
  }
  CaptureUnityAudioClip(self, clip);
  g_orig_UnityAudioSourcePlayDelayed(self, delay, method);
}

// Unity 6 的 IL2CPP 会把 AudioSource.Play/PlayOneShot 的薄托管包装内联，调用方可能
// 完全绕过上面的 public 方法入口。内部 Helper 才是所有重载最终汇合的位置；Naninovel
// 的流式 voice 正是走这条链。这里同时 hook Helper，确保角色语音也产生资源事件。
void Detour_UnityAudioSourcePlayHelper(void* source, uint64_t delay,
                                       const void* method) {
  void* clip = nullptr;
  if (g_il2cpp_runtime_invoke != nullptr && g_unity_source_get_clip != nullptr) {
    void* exception = nullptr;
    clip = g_il2cpp_runtime_invoke(g_unity_source_get_clip, source, nullptr,
                                   &exception);
    if (exception != nullptr) clip = nullptr;
  }
  CaptureUnityAudioClip(source, clip);
  g_orig_UnityAudioSourcePlayHelper(source, delay, method);
}

void Detour_UnityAudioSourcePlayOneShotHelper(void* source, void* clip,
                                              float volume_scale,
                                              const void* method) {
  CaptureUnityAudioClip(source, clip);
  g_orig_UnityAudioSourcePlayOneShotHelper(source, clip, volume_scale, method);
}

void Detour_UnityAudioSourcePlayDelayedHelper(void* source, float delay,
                                              const void* method) {
  void* clip = nullptr;
  if (g_il2cpp_runtime_invoke != nullptr && g_unity_source_get_clip != nullptr) {
    void* exception = nullptr;
    clip = g_il2cpp_runtime_invoke(g_unity_source_get_clip, source, nullptr,
                                   &exception);
    if (exception != nullptr) clip = nullptr;
  }
  CaptureUnityAudioClip(source, clip);
  g_orig_UnityAudioSourcePlayDelayedHelper(source, delay, method);
}

void Detour_UnityTmpSetText(void* self, void* text, const void* method) {
  g_orig_UnityTmpSetText(self, text, method);
  RecordUnityTmpText(self, text, "Unity TMP_Text",
                     L"TMPro.TMP_Text.set_text");
}

void Detour_UnityTmpSetText2(void* self, void* text, bool sync_input_box,
                            const void* method) {
  g_orig_UnityTmpSetText2(self, text, sync_input_box, method);
  RecordUnityTmpText(self, text, "Unity TMP_Text",
                     L"TMPro.TMP_Text.SetText(string,bool)");
}

void Detour_NaninovelRevealableSetText(void* self, void* text,
                                       const void* method) {
  g_orig_NaninovelRevealableSetText(self, text, method);
  RecordUnityTmpText(self, text, "Naninovel RevealableText",
                     L"Naninovel.UI.RevealableText.set_Text");
}

void* Il2CppMethodPointer(const void* method) {
  return method == nullptr ? nullptr
                           : *reinterpret_cast<void* const*>(method);
}

bool Il2CppMethodHasParams(const void* method,
                           const char* const* expected,
                           uint32_t count) {
  if (method == nullptr || g_il2cpp_method_get_param_count == nullptr ||
      g_il2cpp_method_get_param == nullptr || g_il2cpp_type_get_name == nullptr ||
      g_il2cpp_free == nullptr ||
      g_il2cpp_method_get_param_count(method) != count) {
    return false;
  }
  for (uint32_t i = 0; i < count; ++i) {
    const void* type = g_il2cpp_method_get_param(method, i);
    char* name = type == nullptr ? nullptr : g_il2cpp_type_get_name(type);
    const bool matches = name != nullptr && strcmp(name, expected[i]) == 0;
    if (name != nullptr) g_il2cpp_free(name);
    if (!matches) return false;
  }
  return true;
}

const void* FindIl2CppMethod(void* klass, const char* method_name,
                             const char* const* expected,
                             uint32_t count) {
  if (klass == nullptr || method_name == nullptr ||
      g_il2cpp_class_get_methods == nullptr ||
      g_il2cpp_method_get_name == nullptr) {
    return nullptr;
  }
  void* iterator = nullptr;
  while (const void* method =
             g_il2cpp_class_get_methods(klass, &iterator)) {
    const char* name = g_il2cpp_method_get_name(method);
    if (name != nullptr && strcmp(name, method_name) == 0 &&
        Il2CppMethodHasParams(method, expected, count)) {
      return method;
    }
  }
  return nullptr;
}

bool TryHookUnityIl2CppAudio() {
  const bool audio_ready =
      g_orig_UnityAudioSourcePlay != nullptr ||
      g_orig_UnityAudioSourcePlayOneShot1 != nullptr ||
      g_orig_UnityAudioSourcePlayOneShot2 != nullptr ||
      g_orig_UnityAudioSourceSetClip != nullptr ||
      g_orig_UnityAudioSourcePlayScheduled != nullptr ||
      g_orig_UnityAudioSourcePlayDelayed != nullptr;
  const bool text_ready =
      (g_orig_UnityTmpSetText != nullptr &&
       g_orig_UnityTmpSetText2 != nullptr) ||
      g_orig_NaninovelRevealableSetText != nullptr;
  if (audio_ready && text_ready) {
    return true;
  }
  HMODULE game = GetModuleHandleW(L"GameAssembly.dll");
  if (game == nullptr) return false;
  const auto domain_get = reinterpret_cast<Il2CppDomainGet>(
      GetProcAddress(game, "il2cpp_domain_get"));
  const auto domain_get_assemblies = reinterpret_cast<Il2CppDomainGetAssemblies>(
      GetProcAddress(game, "il2cpp_domain_get_assemblies"));
  const auto assembly_get_image = reinterpret_cast<Il2CppAssemblyGetImage>(
      GetProcAddress(game, "il2cpp_assembly_get_image"));
  const auto class_from_name = reinterpret_cast<Il2CppClassFromName>(
      GetProcAddress(game, "il2cpp_class_from_name"));
  const auto class_get_method = reinterpret_cast<Il2CppClassGetMethodFromName>(
      GetProcAddress(game, "il2cpp_class_get_method_from_name"));
  const auto get_corlib = reinterpret_cast<Il2CppGetCorlib>(
      GetProcAddress(game, "il2cpp_get_corlib"));
  g_il2cpp_runtime_invoke = reinterpret_cast<Il2CppRuntimeInvoke>(
      GetProcAddress(game, "il2cpp_runtime_invoke"));
  g_il2cpp_array_new = reinterpret_cast<Il2CppArrayNew>(
      GetProcAddress(game, "il2cpp_array_new"));
  g_il2cpp_object_unbox = reinterpret_cast<Il2CppObjectUnbox>(
      GetProcAddress(game, "il2cpp_object_unbox"));
  g_il2cpp_string_chars = reinterpret_cast<Il2CppStringChars>(
      GetProcAddress(game, "il2cpp_string_chars"));
  g_il2cpp_string_length = reinterpret_cast<Il2CppStringLength>(
      GetProcAddress(game, "il2cpp_string_length"));
  g_il2cpp_class_get_methods = reinterpret_cast<Il2CppClassGetMethods>(
      GetProcAddress(game, "il2cpp_class_get_methods"));
  g_il2cpp_method_get_name = reinterpret_cast<Il2CppMethodGetName>(
      GetProcAddress(game, "il2cpp_method_get_name"));
  g_il2cpp_method_get_param_count =
      reinterpret_cast<Il2CppMethodGetParamCount>(
          GetProcAddress(game, "il2cpp_method_get_param_count"));
  g_il2cpp_method_get_param = reinterpret_cast<Il2CppMethodGetParam>(
      GetProcAddress(game, "il2cpp_method_get_param"));
  g_il2cpp_type_get_name = reinterpret_cast<Il2CppTypeGetName>(
      GetProcAddress(game, "il2cpp_type_get_name"));
  g_il2cpp_free = reinterpret_cast<Il2CppFree>(
      GetProcAddress(game, "il2cpp_free"));
  // 托管线程 attach 守卫用的 API。缺失不致命（文本钩子仍可装），但 CaptureUnityAudioClip
  // 无法保证线程安全时会自行放弃本次托管提取，避免在未注册线程上分配触发 GC 崩溃。
  g_il2cpp_domain_get = domain_get;
  g_il2cpp_thread_current = reinterpret_cast<Il2CppThreadCurrent>(
      GetProcAddress(game, "il2cpp_thread_current"));
  g_il2cpp_thread_attach = reinterpret_cast<Il2CppThreadAttach>(
      GetProcAddress(game, "il2cpp_thread_attach"));
  g_il2cpp_thread_detach = reinterpret_cast<Il2CppThreadDetach>(
      GetProcAddress(game, "il2cpp_thread_detach"));
  if (domain_get == nullptr || domain_get_assemblies == nullptr ||
      assembly_get_image == nullptr || class_from_name == nullptr ||
      class_get_method == nullptr || get_corlib == nullptr ||
      g_il2cpp_runtime_invoke == nullptr || g_il2cpp_array_new == nullptr ||
      g_il2cpp_object_unbox == nullptr || g_il2cpp_string_chars == nullptr ||
      g_il2cpp_string_length == nullptr ||
      g_il2cpp_class_get_methods == nullptr ||
      g_il2cpp_method_get_name == nullptr ||
      g_il2cpp_method_get_param_count == nullptr ||
      g_il2cpp_method_get_param == nullptr ||
      g_il2cpp_type_get_name == nullptr || g_il2cpp_free == nullptr) {
    return false;
  }

  void* source_class = nullptr;
  void* clip_class = nullptr;
  void* object_class = nullptr;
  void* tmp_text_class = nullptr;
  void* naninovel_revealable_text_class = nullptr;
  size_t assembly_count = 0;
  const void** assemblies = domain_get_assemblies(domain_get(), &assembly_count);
  for (size_t i = 0; i < assembly_count; ++i) {
    const void* image = assembly_get_image(assemblies[i]);
    if (image == nullptr) continue;
    if (source_class == nullptr) {
      source_class = class_from_name(image, "UnityEngine", "AudioSource");
    }
    if (clip_class == nullptr) {
      clip_class = class_from_name(image, "UnityEngine", "AudioClip");
    }
    if (object_class == nullptr) {
      object_class = class_from_name(image, "UnityEngine", "Object");
    }
    if (tmp_text_class == nullptr) {
      tmp_text_class = class_from_name(image, "TMPro", "TMP_Text");
    }
    if (naninovel_revealable_text_class == nullptr) {
      naninovel_revealable_text_class =
          class_from_name(image, "Naninovel.UI", "RevealableText");
    }
  }
  const void* corlib = get_corlib();
  g_system_single_class =
      corlib == nullptr ? nullptr
                        : class_from_name(corlib, "System", "Single");
  if (source_class == nullptr || clip_class == nullptr || object_class == nullptr ||
      g_system_single_class == nullptr) {
    return false;
  }

  g_unity_clip_get_samples =
      class_get_method(clip_class, "get_samples", 0);
  g_unity_clip_get_channels =
      class_get_method(clip_class, "get_channels", 0);
  g_unity_clip_get_frequency =
      class_get_method(clip_class, "get_frequency", 0);
  g_unity_clip_get_data = class_get_method(clip_class, "GetData", 2);
  g_unity_source_get_clip = class_get_method(source_class, "get_clip", 0);
  g_unity_object_get_name = class_get_method(object_class, "get_name", 0);
  if (g_unity_clip_get_samples == nullptr ||
      g_unity_clip_get_channels == nullptr ||
      g_unity_clip_get_frequency == nullptr ||
      g_unity_clip_get_data == nullptr || g_unity_source_get_clip == nullptr ||
      g_unity_object_get_name == nullptr) {
    return false;
  }

  bool any = false;
  const void* play = class_get_method(source_class, "Play", 0);
  const void* one_shot_1 = class_get_method(source_class, "PlayOneShot", 1);
  const void* one_shot_2 = class_get_method(source_class, "PlayOneShot", 2);
  const void* set_clip = class_get_method(source_class, "set_clip", 1);
  const void* play_scheduled =
      class_get_method(source_class, "PlayScheduled", 1);
  const void* play_delayed = class_get_method(source_class, "PlayDelayed", 1);
  const void* play_helper = class_get_method(source_class, "PlayHelper", 2);
  const void* one_shot_helper =
      class_get_method(source_class, "PlayOneShotHelper", 3);
  const void* play_delayed_helper =
      class_get_method(source_class, "PlayDelayedHelper", 2);
  any |= HookFn(Il2CppMethodPointer(play),
                reinterpret_cast<void*>(&Detour_UnityAudioSourcePlay),
                reinterpret_cast<void**>(&g_orig_UnityAudioSourcePlay));
  any |= HookFn(
      Il2CppMethodPointer(one_shot_1),
      reinterpret_cast<void*>(&Detour_UnityAudioSourcePlayOneShot1),
      reinterpret_cast<void**>(&g_orig_UnityAudioSourcePlayOneShot1));
  any |= HookFn(
      Il2CppMethodPointer(one_shot_2),
      reinterpret_cast<void*>(&Detour_UnityAudioSourcePlayOneShot2),
      reinterpret_cast<void**>(&g_orig_UnityAudioSourcePlayOneShot2));
  any |= HookFn(Il2CppMethodPointer(set_clip),
                reinterpret_cast<void*>(&Detour_UnityAudioSourceSetClip),
                reinterpret_cast<void**>(&g_orig_UnityAudioSourceSetClip));
  any |= HookFn(Il2CppMethodPointer(play_scheduled),
                reinterpret_cast<void*>(&Detour_UnityAudioSourcePlayScheduled),
                reinterpret_cast<void**>(&g_orig_UnityAudioSourcePlayScheduled));
  any |= HookFn(Il2CppMethodPointer(play_delayed),
                reinterpret_cast<void*>(&Detour_UnityAudioSourcePlayDelayed),
                reinterpret_cast<void**>(&g_orig_UnityAudioSourcePlayDelayed));
  any |= HookFn(Il2CppMethodPointer(play_helper),
                reinterpret_cast<void*>(&Detour_UnityAudioSourcePlayHelper),
                reinterpret_cast<void**>(&g_orig_UnityAudioSourcePlayHelper));
  any |= HookFn(
      Il2CppMethodPointer(one_shot_helper),
      reinterpret_cast<void*>(&Detour_UnityAudioSourcePlayOneShotHelper),
      reinterpret_cast<void**>(&g_orig_UnityAudioSourcePlayOneShotHelper));
  any |= HookFn(
      Il2CppMethodPointer(play_delayed_helper),
      reinterpret_cast<void*>(&Detour_UnityAudioSourcePlayDelayedHelper),
      reinterpret_cast<void**>(&g_orig_UnityAudioSourcePlayDelayedHelper));
  bool tmp_text_ready = false;
  if (tmp_text_class != nullptr) {
    const char* property_params[] = {"System.String"};
    const char* method_params[] = {"System.String", "System.Boolean"};
    const void* set_text = FindIl2CppMethod(
        tmp_text_class, "set_text", property_params, 1);
    const void* set_text_2 = FindIl2CppMethod(
        tmp_text_class, "SetText", method_params, 2);
    const bool property_ready = HookFn(
        Il2CppMethodPointer(set_text),
        reinterpret_cast<void*>(&Detour_UnityTmpSetText),
        reinterpret_cast<void**>(&g_orig_UnityTmpSetText));
    const bool method_ready = HookFn(
        Il2CppMethodPointer(set_text_2),
        reinterpret_cast<void*>(&Detour_UnityTmpSetText2),
        reinterpret_cast<void**>(&g_orig_UnityTmpSetText2));
    tmp_text_ready = property_ready && method_ready;
  }
  bool naninovel_text_ready = false;
  if (naninovel_revealable_text_class != nullptr) {
    const char* text_params[] = {"System.String"};
    const void* set_text = FindIl2CppMethod(
        naninovel_revealable_text_class, "set_Text", text_params, 1);
    naninovel_text_ready = HookFn(
        Il2CppMethodPointer(set_text),
        reinterpret_cast<void*>(&Detour_NaninovelRevealableSetText),
        reinterpret_cast<void**>(&g_orig_NaninovelRevealableSetText));
  }
  if (any && g_header != nullptr) {
    g_header->hook_diagnostics |= kDiagUnityIl2CppHooksReady;
  }
  if (tmp_text_ready && g_header != nullptr) {
    g_header->hook_diagnostics |= kDiagUnityTmpTextHooksReady;
  }
  if (naninovel_text_ready && g_header != nullptr) {
    g_header->hook_diagnostics |= kDiagUnityNaninovelTextHookReady;
  }
  return any && (tmp_text_ready || naninovel_text_ready);
}
