// Included after text_render_adapter.inc and siglus_lookup.inc in the DLL's
// anonymous namespace. Pure/profile headers must be included at file scope.

void QueueSiglusMessageVoice(uint64_t event_id, uint32_t frozen_voice_key,
                            uint64_t tick_ms);

#if defined(_M_IX86)

constexpr uint32_t kSiglusMessageMaxTextUnits = 1500;
constexpr uint32_t kSiglusMessageTaskSlots = 32;
struct SiglusMessageTextTask {
  uint64_t tick_ms = 0;
  uint32_t voice_key = UINT32_MAX;
  uint32_t text_units = 0;
  wchar_t text[kSiglusMessageMaxTextUnits + 1] = {};
};

// State is published only by HookWorker. Profiles/trampolines remain immutable
// once either detour can execute. Callbacks never touch IPC or take a lock.
std::atomic<int> g_siglus_message_install_state{0};
std::atomic<bool> g_siglus_message_capture_enabled{false};
fushi_voice_hook::SiglusMessageProfile g_siglus_message_profile;
fushi_voice_hook::SiglusMessageLayout g_siglus_message_layout;
uintptr_t g_siglus_message_scenario_rva = 0;
void* g_orig_SiglusMessageEntry = nullptr;
void* g_orig_SiglusMessageScenario = nullptr;
void* g_siglus_message_targets[2] = {};
bool g_siglus_message_created[2] = {};
bool g_siglus_message_ever_enabled[2] = {};
__declspec(thread) fushi_voice_hook::SiglusMessageTicket
    g_siglus_message_ticket = {};
fushi_voice_hook::SiglusMessageQueue<SiglusMessageTextTask,
                                   kSiglusMessageTaskSlots>
    g_siglus_message_tasks;

bool ReadSiglusMessageWord(uint32_t address, uint32_t* out) {
  if (address == 0 || out == nullptr || address > UINT32_MAX - 3) return false;
  __try {
    *out = *reinterpret_cast<const volatile uint32_t*>(address);
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

void __stdcall ObserveSiglusMessageEntry(uint32_t owner, uint32_t entry_esp,
                                        uint32_t /*outer_caller_ebp*/) {
  g_siglus_message_ticket = {};
  if (!g_siglus_message_capture_enabled.load(std::memory_order_acquire) ||
      !g_capture_enabled) return;
  auto read = ReadSiglusMessageWord;
  fushi_voice_hook::ArmSiglusMessageTicket(
      g_siglus_message_layout, owner, entry_esp, read, &g_siglus_message_ticket);
}

void __stdcall ObserveSiglusMessageScenario(uint32_t surface,
                                           uint32_t entry_esp,
                                           uint32_t wrapper_ebp) {
  if (!g_siglus_message_capture_enabled.load(std::memory_order_acquire) ||
      !g_capture_enabled) {
    g_siglus_message_ticket = {};
    return;
  }
  auto read = ReadSiglusMessageWord;
  fushi_voice_hook::SiglusMessageOwnerSnapshot frozen;
  if (!fushi_voice_hook::ConsumeSiglusMessageTicket(
          g_siglus_message_layout, surface, entry_esp, wrapper_ebp, read,
          &g_siglus_message_ticket, &frozen)) return;
  uint32_t argument_address = 0, text_union = 0;
  if (!fushi_voice_hook::SiglusMessageCheckedAddress(entry_esp, 4,
                                                   &argument_address) ||
      !read(argument_address, &text_union)) return;
  // ReadSiglusText validates the engine string union and its terminator. SEH
  // contains page lifetime changes between validation and the bounded copy.
  __try {
    uint32_t units = 0;
    const wchar_t* text = ReadSiglusText(
        reinterpret_cast<const SiglusTextUnionW*>(text_union), &units);
    if (text == nullptr || units == 0 || units > kSiglusMessageMaxTextUnits)
      return;
    SiglusMessageTextTask task;
    task.tick_ms = GetTickCount64();
    task.voice_key = frozen.voice_key;
    task.text_units = units;
    memcpy(task.text, text, units * sizeof(wchar_t));
    task.text[units] = L'\0';
    if (g_siglus_message_capture_enabled.load(std::memory_order_acquire))
      (void)g_siglus_message_tasks.TryPush(task);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    // This occurrence is already consumed; a bad string cannot pair later.
  }
}

FUSHI_SIGLUS_MESSAGE_THUNK(Detour_SiglusMessageEntry,
                         ObserveSiglusMessageEntry, g_orig_SiglusMessageEntry)
FUSHI_SIGLUS_MESSAGE_THUNK(Detour_SiglusMessageScenario,
                         ObserveSiglusMessageScenario,
                         g_orig_SiglusMessageScenario)

bool IsSiglusMessageTextInstalled() {
  return g_siglus_message_install_state.load(std::memory_order_acquire) == 1;
}

bool IsSiglusMessageTextOwnershipBlocked() {
  return g_siglus_message_install_state.load(std::memory_order_acquire) == -2;
}

bool IsSiglusMessageVoiceMappingProved() {
  return IsSiglusMessageTextInstalled() &&
         g_siglus_message_profile.voice_key_resource_mapping_proved;
}

// Never free a trampoline that a thread already inside an observer may jump to.
// Disabled previously-enabled hooks keep their trampolines until DLL-wide
// MinHook teardown. A failed disable prevents Luna ownership from being granted.
bool RollbackSiglusMessageHooks() {
  bool clean = true;
  for (size_t i = 0; i < 2; ++i) {
    if (!g_siglus_message_created[i]) continue;
    const MH_STATUS status = MH_DisableHook(g_siglus_message_targets[i]);
    if (status != MH_OK && status != MH_ERROR_DISABLED) clean = false;
  }
  if (!clean) return false;
  for (size_t i = 0; i < 2; ++i) {
    if (!g_siglus_message_created[i] || g_siglus_message_ever_enabled[i])
      continue;
    if (MH_RemoveHook(g_siglus_message_targets[i]) != MH_OK) {
      clean = false;
      continue;
    }
    g_siglus_message_created[i] = false;
    if (i == 0) g_orig_SiglusMessageEntry = nullptr;
    else g_orig_SiglusMessageScenario = nullptr;
  }
  return clean;
}

bool ResolveLiveSiglusMessage(HMODULE module,
                             const fushi_voice_hook::SiglusLookupProfile& lane,
                             fushi_voice_hook::SiglusMessageProfile* profile) {
  __try {
    fushi_voice_hook::exact_lookup::LoadedPeImage image;
    if (!fushi_voice_hook::OpenSiglusLoadedImage(module, &image) ||
        !fushi_voice_hook::ResolveSiglusMessageProfile(image, lane, profile))
      return false;
    // The pure resolver can inspect an external scenario detour for diagnosis;
    // installation must not redirect an already-owned Luna/native entry.
    return image.base[lane.exact_text_rva] == 0x55 &&
           image.base[profile->message_entry_rva] == 0x55;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

// Called only after immutable full-profile admission in TryHook below. Kept as
// a separate unit so fault-injected MinHook outcomes exercise production rollback.
bool InstallSiglusMessageHookGroup() {
  void* detours[] = {reinterpret_cast<void*>(&Detour_SiglusMessageEntry),
                    reinterpret_cast<void*>(&Detour_SiglusMessageScenario)};
  void** originals[] = {&g_orig_SiglusMessageEntry, &g_orig_SiglusMessageScenario};
  bool complete = true;
  EnterCriticalSection(&g_cs);
  for (size_t i = 0; i < 2; ++i) {
    const MH_STATUS status = MH_CreateHook(g_siglus_message_targets[i],
                                          detours[i], originals[i]);
    // Already-created is not ownership. Never borrow another hook's trampoline.
    if (status == MH_OK) g_siglus_message_created[i] = true;
    if (status != MH_OK || *originals[i] == nullptr) {
      complete = false;
      break;
    }
  }
  if (complete) {
    // Inner first; callbacks remain inert until both entries are enabled.
    for (int i = 1; i >= 0; --i) {
      const MH_STATUS status = MH_EnableHook(g_siglus_message_targets[i]);
      if (status == MH_OK || status == MH_ERROR_ENABLED)
        g_siglus_message_ever_enabled[i] = true;
      if (status != MH_OK) {
        complete = false;
        break;
      }
    }
  }
  if (complete) {
    g_siglus_message_install_state.store(1, std::memory_order_release);
    g_siglus_message_capture_enabled.store(true, std::memory_order_release);
  } else {
    const bool clean = RollbackSiglusMessageHooks();
    g_siglus_message_install_state.store(clean ? -1 : -2,
                                          std::memory_order_release);
  }
  LeaveCriticalSection(&g_cs);
  return complete;
}

bool TryHookSiglusMessageText() {
  if (IsSiglusMessageTextInstalled()) return true;
  if (g_siglus_message_install_state.load(std::memory_order_acquire) != 0 ||
      !g_cs_ready || !IsSiglusEngine()) return false;
  const auto* lane = ActiveSiglusLookupProfile();
  HMODULE module = GetModuleHandleW(nullptr);
  if (lane == nullptr || module == nullptr ||
      lane->text_feed != fushi_voice_hook::SiglusLookupTextFeed::kLunaScenarioLane)
    return false;
  if (!ResolveLiveSiglusMessage(module, *lane, &g_siglus_message_profile)) {
    g_siglus_message_install_state.store(-1, std::memory_order_release);
    return false;
  }
  const auto& profile = g_siglus_message_profile;
  const uintptr_t base = reinterpret_cast<uintptr_t>(module);
  g_siglus_message_layout = {
      profile.owner_voice_key_offset, profile.owner_surface_index_offset,
      profile.owner_surface_begin_offset, profile.owner_surface_end_offset,
      profile.surface_stride,
      static_cast<uint32_t>(base + profile.message_surface_return_rva),
      static_cast<uint32_t>(base + profile.scenario_return_rva)};
  g_siglus_message_scenario_rva = lane->exact_text_rva;
  g_siglus_message_targets[0] = reinterpret_cast<void*>(base + profile.message_entry_rva);
  g_siglus_message_targets[1] = reinterpret_cast<void*>(base + lane->exact_text_rva);
  return InstallSiglusMessageHookGroup();
}

void ProcessSiglusMessageTextTasks() {
  if (!g_siglus_message_capture_enabled.load(std::memory_order_acquire) ||
      !g_capture_enabled || !g_text_cs_ready) return;
  SiglusMessageTextTask task;
  // Bounded per worker tick even under a continuous producer.
  for (uint32_t count = 0; count < kSiglusMessageTaskSlots; ++count) {
    if (!g_siglus_message_tasks.TryPop(&task)) break;
    const uint64_t thread_id =
        (static_cast<uint64_t>(g_siglus_message_scenario_rva) << 32) ^
        g_siglus_message_profile.scenario_return_rva;
    EnterCriticalSection(&g_text_cs);
    const uint64_t event_id = WriteTextRingEntryLocked(
        task.text, static_cast<int>(task.text_units), thread_id,
        g_siglus_message_scenario_rva,
        g_siglus_message_profile.scenario_return_rva,
        fushi_voice_hook::kTextSourceSiglus, "SiglusEngine message", nullptr);
    if (event_id != 0) {
      PublishSiglusLookupTextSnapshot(task.text, task.text_units,
                                      {event_id, thread_id});
      if (g_header != nullptr) {
        g_header->luna_active = 1;
        g_header->hook_diagnostics |= kDiagSiglusExactTextObserved;
      }
    }
    LeaveCriticalSection(&g_text_cs);
    // A frozen engine field alone is not proof of archive/member identity.
    if (event_id != 0 &&
        g_siglus_message_profile.voice_key_resource_mapping_proved)
      QueueSiglusMessageVoice(event_id, task.voice_key, task.tick_ms);
  }
}

void ShutdownSiglusMessageText() {
  g_siglus_message_capture_enabled.store(false, std::memory_order_release);
  g_siglus_message_ticket = {};
  if (!g_cs_ready) return;
  EnterCriticalSection(&g_cs);
  const bool clean = RollbackSiglusMessageHooks();
  g_siglus_message_install_state.store(clean ? -1 : -2,
                                       std::memory_order_release);
  LeaveCriticalSection(&g_cs);
}

#else

bool TryHookSiglusMessageText() { return false; }
bool IsSiglusMessageTextInstalled() { return false; }
bool IsSiglusMessageTextOwnershipBlocked() { return false; }
bool IsSiglusMessageVoiceMappingProved() { return false; }
void ProcessSiglusMessageTextTasks() {}
void ShutdownSiglusMessageText() {}

#endif
