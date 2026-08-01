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
void* g_last_unity_clip = nullptr;
ULONGLONG g_last_unity_clip_tick = 0;
wchar_t g_last_unity_voice_bundle[kUnityBundlePathChars] = {0};
constexpr uint32_t kUnityPendingAudioEventCount = 32;
struct PendingUnityAudioEvent {
  uint64_t seq;
  uint64_t timestamp_ms;
  void* source;
  void* clip;
};
PendingUnityAudioEvent
    g_unity_pending_audio_events[kUnityPendingAudioEventCount] = {};
volatile LONGLONG g_unity_pending_audio_write_count = 0;
volatile LONGLONG g_unity_pending_audio_read_count = 0;

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
using UnityUiTextSetText = void (*)(void*, void*, const void*);
UnityUiTextSetText g_orig_UnityUiTextSetText = nullptr;
using UnityTextMeshSetText = void (*)(void*, void*, const void*);
UnityTextMeshSetText g_orig_UnityTextMeshSetText = nullptr;
using NaninovelRevealableSetText = void (*)(void*, void*, const void*);
NaninovelRevealableSetText g_orig_NaninovelRevealableSetText = nullptr;
hibiki_voice_hook::UnityTextMeshReassembler<501>
    g_unity_text_mesh_reassembler;
bool g_unity_sasasa_text_mesh_profile = false;
bool g_unity_text_profile_initialized = false;
alignas(8) volatile uint64_t g_unity_preview_generation = 0;

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

void WriteUnityTextEvent(uint64_t thread_id, void* text_component,
                         const wchar_t* clean, int length,
                         const char* hook_name, const wchar_t* hook_code,
                         uint32_t event_kind) {
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      thread_id == 0 ||
      (event_kind == hibiki_voice_hook::kTextEventLine &&
       (clean == nullptr || length <= 0))) {
    return;
  }

  // v13：写进本组件自己那条道（游戏内 writer 用高段下标）。认领与道内占号在 g_cs 下串行，
  // 与预览槽认领同一把锁、同一套下标分区。
  hibiki_voice_hook::TextLaneWrite write;
  write.thread_id = thread_id;
  write.thread_address = reinterpret_cast<uint64_t>(text_component);
  write.thread_context = reinterpret_cast<uint64_t>(text_component);
  write.process_id = GetCurrentProcessId();
  write.source_kind = hibiki_voice_hook::kTextSourceUnityTmp;
  write.event_kind = event_kind;
  write.is_utf8 = 0;
  write.text = (clean == nullptr || length <= 0) ? nullptr : clean;
  write.byte_len = (clean == nullptr || length <= 0)
                       ? 0
                       : static_cast<uint32_t>(length) * sizeof(wchar_t);
  write.hook_name = hook_name;
  write.hook_code = hook_code;
  if (g_cs_ready) EnterCriticalSection(&g_cs);
  hibiki_voice_hook::WriteTextLaneEvent(
      g_header, hibiki_voice_hook::kNativeThreadPreviewStart,
      hibiki_voice_hook::kTextLaneCount, write);
  if (g_cs_ready) LeaveCriticalSection(&g_cs);
}

bool WriteUnityThreadPreview(uint64_t thread_id, const wchar_t* clean,
                             int length, bool completed_line,
                             const char* hook_name,
                             const wchar_t* hook_code,
                             void* text_component) {
  if (!g_capture_enabled || g_header == nullptr || thread_id == 0 ||
      clean == nullptr || length <= 0 ||
      g_header->thread_preview_offset == 0) {
    return false;
  }

  if (g_cs_ready) EnterCriticalSection(&g_cs);
  auto* all_slots = reinterpret_cast<hibiki_voice_hook::ThreadPreviewSlot*>(
      reinterpret_cast<uint8_t*>(g_header) +
      g_header->thread_preview_offset);
  const uint32_t total_count =
      (std::min)(g_header->thread_preview_slot_count,
                 hibiki_voice_hook::kThreadPreviewCount);
  if (total_count <= hibiki_voice_hook::kNativeThreadPreviewStart) {
    if (g_cs_ready) LeaveCriticalSection(&g_cs);
    return false;
  }
  auto* native_slots =
      all_slots + hibiki_voice_hook::kNativeThreadPreviewStart;
  const uint32_t native_count =
      (std::min)(total_count - hibiki_voice_hook::kNativeThreadPreviewStart,
                 hibiki_voice_hook::kNativeThreadPreviewCount);
  auto* preview = hibiki_voice_hook::FindThreadPreviewSlot(
      native_slots, native_count, thread_id);
  if (preview == nullptr) {
    // Native Unity components do not have a reliable ThreadRemove callback.
    // Recycle the oldest non-selected candidate instead of permanently
    // blinding the selector after 16 historical menu/text components.
    const uint64_t selected =
        hibiki_voice_hook::SelectedTextThreadId(g_header);
    for (uint32_t i = 0; i < native_count; ++i) {
      auto* candidate = &native_slots[i];
      if (candidate->thread_id == selected) continue;
      if (preview == nullptr ||
          candidate->timestamp_ms < preview->timestamp_ms) {
        preview = candidate;
      }
    }
    if (preview == nullptr) {
      if (g_cs_ready) LeaveCriticalSection(&g_cs);
      return false;
    }
  }

  const bool discovered = preview->thread_id != thread_id;
  const uint64_t generation =
      hibiki_voice_hook::NextThreadPreviewGeneration(
          &g_unity_preview_generation);
  hibiki_voice_hook::BeginThreadPreviewWrite(preview, generation);
  if (discovered) {
    preview->line_count = 0;
    preview->artifact_count = 0;
  }
  preview->thread_id = thread_id;
  if (completed_line) preview->line_count++;
  const uint32_t max_bytes =
      hibiki_voice_hook::kThreadPreviewTextChars * sizeof(wchar_t);
  uint32_t byte_length = static_cast<uint32_t>(length) * sizeof(wchar_t);
  if (byte_length > max_bytes) byte_length = max_bytes;
  ZeroMemory(preview->text, sizeof(preview->text));
  memcpy(preview->text, clean, byte_length);
  preview->byte_len = byte_length;
  preview->event_flags = 0;
  preview->timestamp_ms = GetTickCount64();
  hibiki_voice_hook::PublishThreadPreviewWrite(preview, generation);
  hibiki_voice_hook::PublishThreadPreviewChange(
      &g_header->thread_preview_write_count);
  if (g_cs_ready) LeaveCriticalSection(&g_cs);

  if (discovered) {
    WriteUnityTextEvent(
        thread_id, text_component, nullptr, 0, hook_name, hook_code,
        hibiki_voice_hook::kTextEventThreadDiscovered);
  }
  return true;
}

void PublishUnityText(uint64_t thread_id, void* text_component,
                      const wchar_t* clean, int length, bool completed_line,
                      const char* hook_name, const wchar_t* hook_code) {
  WriteUnityThreadPreview(thread_id, clean, length, completed_line, hook_name,
                          hook_code, text_component);
  // v13：只有"这是不是一条完整行"仍然是采集期判据（半截快照进道会挤掉本组件自己的真行）。
  // "是不是选定线程"已不在采集期判断——每个组件写自己那条道，挤不到别人；选定线程由消费方
  // 使用。旧实现在这里 return，等于 Unity 上非选定组件的台词从未被采集，换组件也追不回来。
  if (!completed_line) return;
  WriteUnityTextEvent(thread_id, text_component, clean, length, hook_name,
                      hook_code, hibiki_voice_hook::kTextEventLine);
}

void RecordUnityTmpText(void* text_component, void* string_object,
                        const char* hook_name, const wchar_t* hook_code) {
  if (string_object == nullptr || g_il2cpp_string_chars == nullptr ||
      g_il2cpp_string_length == nullptr) {
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
    if (c != L' ' && c != L'\t' && c != L'\r' && c != L'\n' &&
        c != L'\u3000' && c >= 0x20) {
      ++meaningful;
      if (c >= 0x3000) has_cjk = true;
    }
  }
  if (length == 0 || meaningful == 0 || (!has_cjk && meaningful < 2)) return;
  const uint64_t thread_id = hibiki_voice_hook::NativeTextThreadIdFrom(
      reinterpret_cast<uint64_t>(text_component), hook_code, hook_name);
  PublishUnityText(thread_id, text_component, clean, length, true, hook_name,
                   hook_code);
}

void FlushUnityTextMeshLine() {
  if (g_unity_text_mesh_reassembler.empty()) return;
  constexpr char kHookName[] = "Unity TextMesh line";
  constexpr wchar_t kHookCode[] =
      L"UnityEngine.TextMesh.set_text(glyphs)";
  const uint64_t thread_id =
      hibiki_voice_hook::NativeTextThreadIdFrom(0, kHookCode, kHookName);
  PublishUnityText(thread_id, nullptr, g_unity_text_mesh_reassembler.text(),
                   g_unity_text_mesh_reassembler.length(), true, kHookName,
                   kHookCode);
  g_unity_text_mesh_reassembler.Reset();
}

void RecordUnityTextMesh(void* text_component, void* string_object) {
  if (!g_capture_enabled || g_il2cpp_string_chars == nullptr ||
      g_il2cpp_string_length == nullptr) {
    return;
  }
  if (!g_unity_sasasa_text_mesh_profile) {
    RecordUnityTmpText(text_component, string_object, "Unity TextMesh",
                       L"UnityEngine.TextMesh.set_text");
    return;
  }
  const wchar_t* chars =
      string_object == nullptr ? nullptr : g_il2cpp_string_chars(string_object);
  const int source_length =
      string_object == nullptr ? 0 : g_il2cpp_string_length(string_object);
  if (g_cs_ready) EnterCriticalSection(&g_cs);
  if (!g_capture_enabled) {
    if (g_cs_ready) LeaveCriticalSection(&g_cs);
    return;
  }
  for (int i = 0; chars != nullptr && i < source_length; ++i) {
    const wchar_t c = chars[i];
    if (g_unity_text_mesh_reassembler.ShouldTerminate(c, true)) {
      FlushUnityTextMeshLine();
      continue;
    }
    if (!g_unity_text_mesh_reassembler.Append(c)) continue;
    constexpr char kHookName[] = "Unity TextMesh line";
    constexpr wchar_t kHookCode[] =
        L"UnityEngine.TextMesh.set_text(glyphs)";
    const uint64_t thread_id =
        hibiki_voice_hook::NativeTextThreadIdFrom(0, kHookCode, kHookName);
    PublishUnityText(thread_id, nullptr,
                     g_unity_text_mesh_reassembler.text(),
                     g_unity_text_mesh_reassembler.length(), false, kHookName,
                     kHookCode);
  }
  if (source_length == 0) FlushUnityTextMeshLine();
  if (g_cs_ready) LeaveCriticalSection(&g_cs);
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

void EnqueueUnityAudioClip(void* source, void* clip) {
  const ULONGLONG now = GetTickCount64();
  // Detour 可能运行在 Unity 的 GC/音频内部临界区。这里只写固定长本地环，绝不
  // runtime_invoke/attach/分配托管对象；托管读取统一转移到 HookWorker。
  if (clip == g_last_unity_clip && now - g_last_unity_clip_tick < 100) return;
  g_last_unity_clip = clip;
  g_last_unity_clip_tick = now;
  const uint64_t index = static_cast<uint64_t>(InterlockedIncrement64(
                             &g_unity_pending_audio_write_count)) -
                         1;
  PendingUnityAudioEvent* event =
      &g_unity_pending_audio_events[index % kUnityPendingAudioEventCount];
  event->seq = 0;
  event->timestamp_ms = now;
  event->source = source;
  event->clip = clip;
  MemoryBarrier();
  InterlockedExchange64(reinterpret_cast<volatile LONGLONG*>(&event->seq),
                        static_cast<LONGLONG>(index + 1));
}

void CaptureUnityAudioClip(void* source, void* clip) {
  if (!g_capture_enabled || clip == nullptr || g_header == nullptr) return;
  g_header->hook_diagnostics |= kDiagUnityIl2CppPlaybackObserved;
  EnqueueUnityAudioClip(source, clip);
}

void ProcessUnityAudioEvent(const PendingUnityAudioEvent& event) {
  if (!g_capture_enabled || event.clip == nullptr || g_header == nullptr) return;
  // HookWorker 是普通 Win32 线程。先 attach 到 IL2CPP 域，再做 get_name/装箱/
  // array_new/GetData，避免在 Unity 播放 detour 内重入 Boehm GC。
  const hibiki_voice_hook::Il2CppThreadFns il2cpp_thread_fns{
      g_il2cpp_thread_current, g_il2cpp_thread_attach, g_il2cpp_thread_detach,
      g_il2cpp_domain_get};
  hibiki_voice_hook::Il2CppManagedThreadScope managed_thread(il2cpp_thread_fns);
  if (!managed_thread.safe()) {
    g_header->hook_diagnostics |= kDiagUnityIl2CppGetDataRejected;
    return;
  }
  RecordUnityVoiceResourceEvent(event.clip, event.timestamp_ms);

  const bool pcm_helpers_ready =
      g_system_single_class != nullptr && g_il2cpp_array_new != nullptr &&
      g_unity_clip_get_samples != nullptr &&
      g_unity_clip_get_channels != nullptr &&
      g_unity_clip_get_frequency != nullptr &&
      g_unity_clip_get_data != nullptr;
  if (!pcm_helpers_ready) {
    // 旧 Unity 可能没有暴露 GetData 或数组辅助 API。资源事件已经写入，允许
    // injector 走 bundle/resource 解码；这里只放弃托管 PCM 快路径。
    g_header->hook_diagnostics |= kDiagUnityIl2CppGetDataRejected;
    return;
  }

  const int samples = InvokeUnityInt(g_unity_clip_get_samples, event.clip);
  const int channels = InvokeUnityInt(g_unity_clip_get_channels, event.clip);
  const int frequency = InvokeUnityInt(g_unity_clip_get_frequency, event.clip);
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
      if (InvokeUnityBool(g_unity_clip_get_data, event.clip, args)) {
        // Il2CppArray = Il2CppObject(klass,monitor) + bounds + max_length；随后即 vector。
        const auto* pcm = reinterpret_cast<const uint8_t*>(array) +
                          sizeof(void*) * 4;
        const uint32_t len = static_cast<uint32_t>(byte_count);
        const uint32_t off = RingAppendVoice(pcm, len);
        RecordVoiceClipFmt(off, len,
                           reinterpret_cast<uint64_t>(event.source),
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
}

void ProcessPendingUnityAudioEvents() {
  for (uint32_t processed = 0;
       processed < kUnityPendingAudioEventCount; ++processed) {
    const uint64_t write_count = static_cast<uint64_t>(
        InterlockedCompareExchange64(&g_unity_pending_audio_write_count, 0, 0));
    uint64_t read_count = static_cast<uint64_t>(
        InterlockedCompareExchange64(&g_unity_pending_audio_read_count, 0, 0));
    if (read_count >= write_count) break;
    const uint64_t oldest =
        write_count > kUnityPendingAudioEventCount
            ? write_count - kUnityPendingAudioEventCount
            : 0;
    if (read_count < oldest) {
      read_count = oldest;
      InterlockedExchange64(&g_unity_pending_audio_read_count,
                            static_cast<LONGLONG>(read_count));
    }
    PendingUnityAudioEvent* slot =
        &g_unity_pending_audio_events[read_count %
                                      kUnityPendingAudioEventCount];
    MemoryBarrier();
    if (slot->seq != read_count + 1) break;
    const PendingUnityAudioEvent event = *slot;
    InterlockedExchange64(&g_unity_pending_audio_read_count,
                          static_cast<LONGLONG>(read_count + 1));
    ProcessUnityAudioEvent(event);
  }
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

void Detour_UnityUiTextSetText(void* self, void* text, const void* method) {
  g_orig_UnityUiTextSetText(self, text, method);
  RecordUnityTmpText(self, text, "Unity UI.Text",
                     L"UnityEngine.UI.Text.set_text");
}

void Detour_UnityTextMeshSetText(void* self, void* text,
                                 const void* method) {
  g_orig_UnityTextMeshSetText(self, text, method);
  RecordUnityTextMesh(self, text);
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

bool HasCurrentProcessTopLevelWindow() {
  struct Search {
    DWORD process_id;
    bool found;
  } search{GetCurrentProcessId(), false};
  EnumWindows(
      [](HWND window, LPARAM value) -> BOOL {
        auto* search = reinterpret_cast<Search*>(value);
        DWORD process_id = 0;
        GetWindowThreadProcessId(window, &process_id);
        if (process_id != search->process_id ||
            GetWindow(window, GW_OWNER) != nullptr ||
            !IsWindowVisible(window)) {
          return TRUE;
        }
        search->found = true;
        return FALSE;
      },
      reinterpret_cast<LPARAM>(&search));
  return search.found;
}

bool TryHookUnityIl2CppAudio() {
  if (!g_unity_text_profile_initialized) {
    wchar_t executable_path[MAX_PATH] = {0};
    const DWORD path_length =
        GetModuleFileNameW(nullptr, executable_path, MAX_PATH);
    g_unity_sasasa_text_mesh_profile =
        path_length != 0 && path_length < MAX_PATH &&
        hibiki_voice_hook::UsesSasasaLegacyTextMeshTerminator(
            executable_path);
    g_unity_text_profile_initialized = true;
  }
  const bool audio_ready =
      g_orig_UnityAudioSourcePlay != nullptr ||
      g_orig_UnityAudioSourcePlayOneShot1 != nullptr ||
      g_orig_UnityAudioSourcePlayOneShot2 != nullptr ||
      g_orig_UnityAudioSourceSetClip != nullptr ||
      g_orig_UnityAudioSourcePlayScheduled != nullptr ||
      g_orig_UnityAudioSourcePlayDelayed != nullptr ||
      g_orig_UnityAudioSourcePlayHelper != nullptr ||
      g_orig_UnityAudioSourcePlayOneShotHelper != nullptr ||
      g_orig_UnityAudioSourcePlayDelayedHelper != nullptr;
  const bool text_ready =
      (g_orig_UnityTmpSetText != nullptr &&
       g_orig_UnityTmpSetText2 != nullptr) ||
      g_orig_UnityUiTextSetText != nullptr ||
      g_orig_UnityTextMeshSetText != nullptr ||
      g_orig_NaninovelRevealableSetText != nullptr;
  if (audio_ready && text_ready) {
    return true;
  }
  HMODULE game = GetModuleHandleW(L"GameAssembly.dll");
  if (game == nullptr) return false;
  // Hibiki 的“启动并捕获”会先以 CREATE_SUSPENDED 创建游戏。旧版 IL2CPP 在播放器
  // 尚未创建窗口时连类型/方法枚举都可能进入未完成初始化的 Boehm GC；更不能在此时
  // 用 MH_EnableHook 再次枚举并挂起线程。外部窗口附加天然越过此门；启动模式则由
  // HookWorker 在窗口出现后按现有轮询节奏重试。
  if (!HasCurrentProcessTopLevelWindow()) {
    if (g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagUnityHooksDeferredUntilWindow;
    }
    return false;
  }
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
      g_il2cpp_string_chars == nullptr ||
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
  void* ui_text_class = nullptr;
  void* text_mesh_class = nullptr;
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
    if (ui_text_class == nullptr) {
      ui_text_class = class_from_name(image, "UnityEngine.UI", "Text");
    }
    if (text_mesh_class == nullptr) {
      text_mesh_class = class_from_name(image, "UnityEngine", "TextMesh");
    }
    if (naninovel_revealable_text_class == nullptr) {
      naninovel_revealable_text_class =
          class_from_name(image, "Naninovel.UI", "RevealableText");
    }
  }
  if (g_header != nullptr) {
    g_header->reserved_hook_diagnostics |=
        hibiki_voice_hook::kDiagUnityTextScanReady;
    if (source_class != nullptr && clip_class != nullptr &&
        object_class != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagUnityAudioClassFound;
    }
    if (ui_text_class != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagUnityUiTextClassFound;
    }
    if (text_mesh_class != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagUnityTextMeshClassFound;
    }
  }

  bool resource_methods_ready = false;
  bool pcm_helpers_ready = false;
  if (class_get_method != nullptr && g_il2cpp_runtime_invoke != nullptr &&
      source_class != nullptr && clip_class != nullptr &&
      object_class != nullptr) {
    g_unity_source_get_clip =
        class_get_method(source_class, "get_clip", 0);
    g_unity_object_get_name =
        class_get_method(object_class, "get_name", 0);
    resource_methods_ready =
        g_unity_source_get_clip != nullptr &&
        g_unity_object_get_name != nullptr;
    if (resource_methods_ready && g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagUnityAudioResourceMethodsFound;
    }

    const void* corlib = get_corlib == nullptr ? nullptr : get_corlib();
    g_system_single_class =
        corlib == nullptr ? nullptr
                          : class_from_name(corlib, "System", "Single");
    g_unity_clip_get_samples =
        class_get_method(clip_class, "get_samples", 0);
    g_unity_clip_get_channels =
        class_get_method(clip_class, "get_channels", 0);
    g_unity_clip_get_frequency =
        class_get_method(clip_class, "get_frequency", 0);
    g_unity_clip_get_data = class_get_method(clip_class, "GetData", 2);
    pcm_helpers_ready =
        g_system_single_class != nullptr && g_il2cpp_array_new != nullptr &&
        g_il2cpp_object_unbox != nullptr &&
        g_unity_clip_get_samples != nullptr &&
        g_unity_clip_get_channels != nullptr &&
        g_unity_clip_get_frequency != nullptr &&
        g_unity_clip_get_data != nullptr;
    if (pcm_helpers_ready && g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagUnityAudioPcmMethodsFound;
    }
  }

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
  bool ui_text_ready = false;
  if (ui_text_class != nullptr) {
    const char* text_params[] = {"System.String"};
    const void* set_text =
        FindIl2CppMethod(ui_text_class, "set_text", text_params, 1);
    if (set_text != nullptr && g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagUnityUiTextMethodFound;
    }
    ui_text_ready = HookFn(
        Il2CppMethodPointer(set_text),
        reinterpret_cast<void*>(&Detour_UnityUiTextSetText),
        reinterpret_cast<void**>(&g_orig_UnityUiTextSetText));
    if (ui_text_ready && g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagUnityUiTextHookReady;
    }
  }
  bool text_mesh_ready = false;
  if (text_mesh_class != nullptr) {
    const char* text_params[] = {"System.String"};
    const void* set_text =
        FindIl2CppMethod(text_mesh_class, "set_text", text_params, 1);
    if (set_text != nullptr && g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagUnityTextMeshMethodFound;
    }
    text_mesh_ready = HookFn(
        Il2CppMethodPointer(set_text),
        reinterpret_cast<void*>(&Detour_UnityTextMeshSetText),
        reinterpret_cast<void**>(&g_orig_UnityTextMeshSetText));
    if (text_mesh_ready && g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          hibiki_voice_hook::kDiagUnityTextMeshHookReady;
    }
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
  const bool text_hooks_ready =
      tmp_text_ready || ui_text_ready || text_mesh_ready ||
      naninovel_text_ready;
  if (tmp_text_ready && g_header != nullptr) {
    g_header->hook_diagnostics |= kDiagUnityTmpTextHooksReady;
  }
  if (naninovel_text_ready && g_header != nullptr) {
    g_header->hook_diagnostics |= kDiagUnityNaninovelTextHookReady;
  }

  // Resource observation only needs the AudioSource/AudioClip/Object classes,
  // runtime invoke, and the clip/name accessors. Keep it independent from the
  // optional AudioClip.GetData PCM fast path used by newer Unity versions.
  if (!resource_methods_ready) return false;

  bool any = audio_ready;
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
  if (g_header != nullptr &&
      (play != nullptr || one_shot_1 != nullptr ||
       one_shot_2 != nullptr || set_clip != nullptr ||
       play_scheduled != nullptr || play_delayed != nullptr ||
       play_helper != nullptr || one_shot_helper != nullptr ||
       play_delayed_helper != nullptr)) {
    g_header->reserved_hook_diagnostics |=
        hibiki_voice_hook::kDiagUnityAudioPlaybackMethodFound;
  }
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
  if (any && g_header != nullptr) {
    g_header->hook_diagnostics |= kDiagUnityIl2CppHooksReady;
    g_header->reserved_hook_diagnostics |=
        hibiki_voice_hook::kDiagUnityAudioPlaybackHookReady;
  }

  return any && text_hooks_ready;
}
