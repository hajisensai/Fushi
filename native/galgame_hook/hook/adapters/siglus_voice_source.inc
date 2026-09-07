// Included after siglus_message_capture.inc; headers live at DLL file scope.
// This independent source hook never changes native text ownership.
void QueueProvedSiglusVoiceResource(uint32_t key, const wchar_t* path,
                                    uint32_t offset, uint32_t length);

#if defined(_M_IX86)
constexpr uint32_t kSiglusVoiceSourceTaskSlots = 32;
std::atomic<int> g_siglus_voice_source_state{0};
std::atomic<bool> g_siglus_voice_source_enabled{false};
fushi_voice_hook::SiglusResourceMappingProfile g_siglus_voice_source_profile;
fushi_voice_hook::SiglusVoiceSourceLayout g_siglus_voice_source_layout;
bool g_siglus_voice_source_native_ecx = false;
fushi_voice_hook::SiglusNativeResourceMappingProfile g_siglus_native_source_profile;
fushi_voice_hook::SiglusNativeVoiceSourceLayout g_siglus_native_source_layout;
fushi_voice_hook::SiglusMessageQueue<fushi_voice_hook::SiglusVoiceSourceTask,
                                   kSiglusVoiceSourceTaskSlots>
    g_siglus_voice_source_tasks;
void* g_siglus_voice_source_target = nullptr;
void* g_orig_SiglusVoiceSource = nullptr;
bool g_siglus_voice_source_created = false;
bool g_siglus_voice_source_ever_enabled = false;

// Private, payload-free diagnostic counters. They identify the first failed
// source boundary without changing hook admission or doing IO in the callback.
struct SiglusVoiceSourceObservations {
  std::atomic<uint32_t> entered{0};
  std::atomic<uint32_t> enabled{0};
  std::atomic<uint32_t> admitted_caller{0};
  std::atomic<uint32_t> captured{0};
  std::atomic<uint32_t> queued{0};
  std::atomic<uint32_t> processed{0};
  std::atomic<uint32_t> last_return{0};
};
SiglusVoiceSourceObservations g_siglus_voice_source_observations;

bool ReadSiglusVoiceSourceMemory(uint32_t address, void* output, size_t bytes) {
  if (address == 0 || output == nullptr || bytes == 0 ||
      bytes > fushi_voice_hook::kSiglusVoiceSourcePathUnits * sizeof(wchar_t) ||
      bytes > UINT32_MAX - address) return false;
  __try {
    memcpy(output, reinterpret_cast<const void*>(address), bytes);
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

void __stdcall ObserveSiglusVoiceSource(uint32_t reader, uint32_t entry_esp,
                                       uint32_t caller_ebp) {
  auto& observations = g_siglus_voice_source_observations;
  observations.entered.fetch_add(1, std::memory_order_relaxed);
  if (!g_siglus_voice_source_enabled.load(std::memory_order_acquire) ||
      !g_capture_enabled || entry_esp < 36) return;
  observations.enabled.fetch_add(1, std::memory_order_relaxed);
  uint32_t return_address = 0;
  if (ReadSiglusVoiceSourceMemory(entry_esp, &return_address, 4)) {
    observations.last_return.store(return_address, std::memory_order_relaxed);
    const uint32_t admitted_return = g_siglus_voice_source_native_ecx
        ? g_siglus_native_source_layout.payload_return
        : g_siglus_voice_source_layout.payload_return;
    if (return_address == admitted_return)
      observations.admitted_caller.fetch_add(1, std::memory_order_relaxed);
  }
  fushi_voice_hook::SiglusVoiceSourceCall call;
  call.reader = reader; call.entry_esp = entry_esp; call.caller_ebp = caller_ebp;
  // These are OUR pushad slots, not guessed engine stack locals. The shared
  // naked thunk saves ESI at saved-frame+4 and EBX at +16 (entryESP-36 frame).
  if (!ReadSiglusVoiceSourceMemory(entry_esp - 32, &call.original_esi, 4) ||
      !ReadSiglusVoiceSourceMemory(entry_esp - 20, &call.original_ebx, 4)) return;
  auto read = ReadSiglusVoiceSourceMemory;
  fushi_voice_hook::SiglusVoiceSourceTask task;
  const bool captured = g_siglus_voice_source_native_ecx
      ? fushi_voice_hook::CaptureSiglusNativeVoiceSource(
            g_siglus_native_source_layout,
            {reader, entry_esp, caller_ebp, call.original_ebx}, read, &task)
      : fushi_voice_hook::CaptureSiglusVoiceSource(
            g_siglus_voice_source_layout, call, read, &task);
  if (captured) {
    observations.captured.fetch_add(1, std::memory_order_relaxed);
    if (g_siglus_voice_source_enabled.load(std::memory_order_acquire) &&
        g_siglus_voice_source_tasks.TryPush(task))
      observations.queued.fetch_add(1, std::memory_order_relaxed);
  }
}

FUSHI_SIGLUS_MESSAGE_THUNK(Detour_SiglusVoiceSource, ObserveSiglusVoiceSource,
                         g_orig_SiglusVoiceSource)

bool IsSiglusVoiceSourceInstalled() {
  return g_siglus_voice_source_state.load(std::memory_order_acquire) == 1;
}

bool DisableSiglusVoiceSourceHook() {
  if (!g_siglus_voice_source_created) return true;
  const MH_STATUS disabled = MH_DisableHook(g_siglus_voice_source_target);
  if (disabled != MH_OK && disabled != MH_ERROR_DISABLED) return false;
  // An observer already entered may still tail-jump here. Retain enabled-once
  // trampolines until the process-lifetime MinHook teardown.
  if (!g_siglus_voice_source_ever_enabled) {
    if (MH_RemoveHook(g_siglus_voice_source_target) != MH_OK) return false;
    g_siglus_voice_source_created = false;
    g_orig_SiglusVoiceSource = nullptr;
  }
  return true;
}

// Only the worker invokes installation after full profile proof. Kept separate
// so tests can inject MinHook failure statuses into the actual production path.
bool InstallSiglusVoiceSourceHook() {
  EnterCriticalSection(&g_cs);
  const MH_STATUS created = MH_CreateHook(g_siglus_voice_source_target,
      reinterpret_cast<void*>(&Detour_SiglusVoiceSource), &g_orig_SiglusVoiceSource);
  if (created == MH_OK) g_siglus_voice_source_created = true;
  bool installed = created == MH_OK && g_orig_SiglusVoiceSource != nullptr;
  if (installed) {
    const MH_STATUS enabled = MH_EnableHook(g_siglus_voice_source_target);
    if (enabled == MH_OK || enabled == MH_ERROR_ENABLED)
      g_siglus_voice_source_ever_enabled = true;
    installed = enabled == MH_OK;
  }
  if (installed) {
    g_siglus_voice_source_state.store(1, std::memory_order_release);
    g_siglus_voice_source_enabled.store(true, std::memory_order_release);
  } else {
    const bool clean = DisableSiglusVoiceSourceHook();
    g_siglus_voice_source_state.store(clean ? -1 : -2,
                                       std::memory_order_release);
  }
  LeaveCriticalSection(&g_cs);
  return installed;
}

bool ResolveLiveSiglusVoiceSource(HMODULE module, uintptr_t proved_voice_entry,
    fushi_voice_hook::SiglusResourceMappingProfile* profile) {
  __try {
    fushi_voice_hook::exact_lookup::LoadedPeImage image;
    return fushi_voice_hook::OpenSiglusLoadedImage(module, &image) &&
        fushi_voice_hook::ResolveSiglusResourceMappingProfile(
            image, proved_voice_entry, profile) &&
        // Do not take ownership of an external detour, even if a future pure
        // resolver permits it as a read-only diagnostic observation.
        image.base[profile->ogg_open_rva] == 0x55;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

bool ResolveLiveSiglusNativeVoiceSource(HMODULE module, uintptr_t proved_voice_entry,
    fushi_voice_hook::SiglusNativeResourceMappingProfile* profile) {
  __try {
    fushi_voice_hook::exact_lookup::LoadedPeImage image;
    return fushi_voice_hook::OpenSiglusLoadedImage(module, &image) &&
        fushi_voice_hook::ResolveSiglusNativeResourceMappingProfile(
            image, proved_voice_entry, profile) &&
        image.base[profile->ogg_open_rva] == 0x55;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

bool TryHookSiglusVoiceSource() {
  if (IsSiglusVoiceSourceInstalled()) return true;
  if (g_siglus_voice_source_state.load(std::memory_order_acquire) != 0 ||
      !g_cs_ready || !IsSiglusMessageTextInstalled()) return false;
  const auto* lane = ActiveSiglusLookupProfile();
  HMODULE module = GetModuleHandleW(nullptr);
  if (lane == nullptr || module == nullptr) return false;
  const uintptr_t base = reinterpret_cast<uintptr_t>(module);
  if (lane->text_feed ==
      fushi_voice_hook::SiglusLookupTextFeed::kNativeEcxTextUnion) {
    if (!g_siglus_message_native_ecx ||
        !ResolveLiveSiglusNativeVoiceSource(module,
            g_siglus_native_message_profile.voice_entry_rva,
            &g_siglus_native_source_profile)) {
      g_siglus_voice_source_state.store(-1, std::memory_order_release);
      return false;
    }
    const auto& profile = g_siglus_native_source_profile;
    g_siglus_voice_source_native_ecx = true;
    g_siglus_native_source_layout = {
        static_cast<uint32_t>(base + profile.payload_return_rva),
        static_cast<uint32_t>(base + profile.ogg_vtable_rva), profile.frame};
    g_siglus_voice_source_target = reinterpret_cast<void*>(base + profile.ogg_open_rva);
    return InstallSiglusVoiceSourceHook();
  }
  if (lane->text_feed !=
      fushi_voice_hook::SiglusLookupTextFeed::kLunaScenarioLane ||
      g_siglus_message_native_ecx) return false;
  // The message entry is already detoured. Its immutable admitted proof is the
  // source of this voice entry, never a second scan or a nearby address guess.
  if (!ResolveLiveSiglusVoiceSource(module, g_siglus_message_profile.voice_entry_rva,
                                    &g_siglus_voice_source_profile)) {
    g_siglus_voice_source_state.store(-1, std::memory_order_release);
    return false;
  }
  const auto& profile = g_siglus_voice_source_profile;
  g_siglus_voice_source_layout = {
      static_cast<uint32_t>(base + profile.payload_return_rva),
      static_cast<uint32_t>(base + profile.ogg_vtable_rva),
      profile.resource_key_frame_offset, profile.resource_key_copy_frame_displacement,
      profile.resource_path_frame_displacement, profile.resource_reader_frame_displacement,
      profile.ogg_path_argument_offset, profile.ogg_offset_argument_offset,
      profile.ogg_length_argument_offset};
  g_siglus_voice_source_target = reinterpret_cast<void*>(base + profile.ogg_open_rva);
  return InstallSiglusVoiceSourceHook();
}

void ProcessSiglusVoiceSourceTasks() {
  if (!g_capture_enabled || !g_siglus_voice_source_enabled.load(
                                std::memory_order_acquire)) return;
  fushi_voice_hook::SiglusVoiceSourceTask task;
  for (uint32_t count = 0; count < kSiglusVoiceSourceTaskSlots; ++count) {
    if (!g_siglus_voice_source_tasks.TryPop(&task)) break;
    g_siglus_voice_source_observations.processed.fetch_add(
        1, std::memory_order_relaxed);
    QueueProvedSiglusVoiceResource(task.key, task.path, task.offset, task.length);
  }
}

void ShutdownSiglusVoiceSource() {
  g_siglus_voice_source_enabled.store(false, std::memory_order_release);
  if (!g_cs_ready) return;
  EnterCriticalSection(&g_cs);
  const bool clean = DisableSiglusVoiceSourceHook();
  g_siglus_voice_source_state.store(clean ? -1 : -2, std::memory_order_release);
  LeaveCriticalSection(&g_cs);
}
#else
bool TryHookSiglusVoiceSource() { return false; }
bool IsSiglusVoiceSourceInstalled() { return false; }
void ProcessSiglusVoiceSourceTasks() {}
void ShutdownSiglusVoiceSource() {}
#endif
