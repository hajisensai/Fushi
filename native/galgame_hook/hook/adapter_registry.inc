// Included by dll_main.cpp after all adapter implementation units. Keeping the registry in the
// same translation unit is deliberate for P1: it permits a mechanical, zero-behaviour-change split
// before P2/P3 introduce stable cross-unit contexts and replayable events.

bool ModuleNameEquals(const wchar_t* module_name, const wchar_t* expected) {
  return module_name != nullptr && expected != nullptr &&
         _wcsicmp(module_name, expected) == 0;
}

bool ModuleNameStartsWith(const wchar_t* module_name, const wchar_t* prefix) {
  if (module_name == nullptr || prefix == nullptr) return false;
  const size_t prefix_length = wcslen(prefix);
  return _wcsnicmp(module_name, prefix, prefix_length) == 0;
}

class GenericWindowsAudioAdapter final
    : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "xaudio2_directsound"; }
  bool probe() const override { return true; }
  bool install() override {
    const bool queue_ready = InitializeXAudioCaptureQueue();
    TryHookXAudio2Create();
    TryHookDirectSoundCreate();
    installed_ = installed_ || queue_ready;
    return queue_ready;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    if (module_name == nullptr || ModuleNameEquals(module_name, L"xaudio2_9.dll") ||
        ModuleNameEquals(module_name, L"xaudio2_8.dll") ||
        ModuleNameEquals(module_name, L"dsound.dll") ||
        ModuleNameEquals(module_name, L"ole32.dll")) {
      install();
    }
  }
  void ProcessPendingEvents() { ProcessPendingXAudioCaptureJobs(); }
  void shutdown() override {
    ShutdownXAudioCaptureQueue();
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->xaudio_diagnostics};
  }

 private:
  bool installed_ = false;
};

class SiglusAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "siglus"; }
  bool probe() const override { return IsSiglusEngine(); }
  bool install() override {
    const bool audio_ready = InstallResourceAudio();
    InstallText();
    return audio_ready;
  }
  bool InstallResourceAudio() {
    audio_ready_ = TryHookSiglusOvk();
    installed_ = installed_ || audio_ready_;
    return audio_ready_;
  }
  void InstallText() {
    TryHookSiglusExactText();
    installed_ = installed_ || probe();
  }
  void ProcessPendingEvents() { ProcessSiglusVoiceTasks(); }
  bool audio_ready() const { return audio_ready_; }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio |
           fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {
    // Siglus hooks target the main executable and kernel32 file APIs; startup install + bounded
    // MinHook retry handles its protected launch window, not delayed engine modules.
  }
  void shutdown() override {
    installed_ = false;
    audio_ready_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool audio_ready_ = false;
};

class UnityIl2CppAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "unity_il2cpp"; }
  bool probe() const override {
    return GetModuleHandleW(L"UnityPlayer.dll") != nullptr &&
           GetModuleHandleW(L"GameAssembly.dll") != nullptr;
  }
  bool install() override {
    ready_ = TryHookUnityIl2CppAudio();
    installed_ = installed_ || ready_;
    return ready_;
  }
  bool ready() const { return ready_; }
  void ProcessPendingEvents() { ProcessPendingUnityAudioEvents(); }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio |
           fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    if (module_name == nullptr ||
        ModuleNameEquals(module_name, L"UnityPlayer.dll") ||
        ModuleNameEquals(module_name, L"GameAssembly.dll")) {
      install();
    }
  }
  void shutdown() override {
    installed_ = false;
    ready_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool ready_ = false;
};

class TextRenderAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "text_render"; }
  bool probe() const override { return true; }
  bool install() override {
    TryHookTextRender();
    installed_ = true;
    return true;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    if (module_name == nullptr || ModuleNameEquals(module_name, L"gdi32.dll") ||
        ModuleNameEquals(module_name, L"user32.dll")) {
      install();
    }
  }
  void shutdown() override { installed_ = false; }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
};

class KiriKiriAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "kirikiri_z"; }
  bool probe() const override {
    return !fushi_voice_hook::MatchesQlieProfile(nullptr) &&
           (GetModuleHandleW(L"wuvorbis.dll") != nullptr ||
            GetModuleHandleW(L"wuopus.dll") != nullptr);
  }
  bool install() override {
    const bool decoder_ready = InstallDecoders();
    const bool voice_ready = InstallVoiceStream();
    return decoder_ready && voice_ready;
  }
  bool InstallDecoders() {
    if (fushi_voice_hook::MatchesQlieProfile(nullptr)) return false;
    decoder_ready_ = TryHookKirikiriDecoders();
    installed_ = installed_ || decoder_ready_;
    return decoder_ready_;
  }
  bool InstallVoiceStream() {
    if (fushi_voice_hook::MatchesQlieProfile(nullptr)) return false;
    voice_ready_ = TryHookKirikiriVoiceStream();
    installed_ = installed_ || voice_ready_;
    return voice_ready_;
  }
  void ProcessPendingEvents() { ProcessKirikiriVoiceTasks(); }
  bool decoder_ready() const { return decoder_ready_; }
  bool voice_ready() const { return voice_ready_; }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio |
           fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    if (module_name == nullptr || ModuleNameEquals(module_name, L"wuvorbis.dll") ||
        ModuleNameEquals(module_name, L"wuopus.dll")) {
      install();
    }
  }
  void shutdown() override {
    StopKirikiriVoiceTasks();
    installed_ = false;
    decoder_ready_ = false;
    voice_ready_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool decoder_ready_ = false;
  bool voice_ready_ = false;
};

class RenPyAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "renpy_ffmpeg"; }
  bool probe() const override {
    uint32_t major = 0;
    return FindLoadedFfmpegModule(
               fushi_voice_hook::FfmpegModuleKind::kAvformat, &major) !=
           nullptr;
  }
  bool install() override {
    ready_ = TryHookRenpyAudio();
    installed_ = installed_ || ready_;
    return ready_;
  }
  bool ready() const { return ready_; }
  // 游戏内查词传感器与音频那半完全解耦：音频要 FFmpeg 模块才装得上，而查词只要
  // CPython 在，所以它自己按 lookup_enabled 决定装不装，不搭 install() 的车。
  void ProcessPendingEvents() {
    PollRenpyLookupInstall();
    ProcessRenpyLookupTick();
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio |
           fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    const auto ffmpeg = fushi_voice_hook::ParseFfmpegModuleName(module_name);
    if (module_name == nullptr ||
        ffmpeg.kind != fushi_voice_hook::FfmpegModuleKind::kNone ||
        fushi_voice_hook::IsMonolithicFfmpegModuleName(module_name)) {
      install();
    }
  }
  void shutdown() override {
    StopRenpyWorker();
    installed_ = false;
    ready_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool ready_ = false;
};

class TyranoAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "tyrano_nwjs"; }
  bool probe() const override {
    return InterlockedCompareExchange(&g_tyrano_asar_ready, 0, 0) != 0;
  }
  bool install() override {
    ready_ = TryHookTyranoAsarAudio();
    installed_ = installed_ || ready_;
    return ready_;
  }
  bool ready() const { return ready_; }
  void ProcessPendingEvents() { ProcessTyranoAsarTasks(); }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kResourceAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    StopTyranoAsarAudio();
    installed_ = false;
    ready_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool ready_ = false;
};

class LoopbackAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "process_loopback"; }
  bool probe() const override { return true; }
  bool install() override {
    PollPolicy();
    return installed_;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}

  // HookWorker is the single lifecycle controller. The capture worker only
  // reports process-local phase; it never acknowledges shared policy, so an
  // older generation cannot overwrite a newer request's state/applied_seq.
  void PollPolicy() {
    using fushi_voice_hook::NativeLoopbackPolicyAction;
    using fushi_voice_hook::NativeLoopbackWorkerPhase;

    const fushi_voice_hook::NativeLoopbackRequestSnapshot request =
        fushi_voice_hook::ReadNativeLoopbackRequest(g_header);
    if (!request.valid) return;  // uninitialised/tearing request is deny.

    if (thread_ != nullptr && WaitForSingleObject(thread_, 0) == WAIT_OBJECT_0) {
      DWORD exit_code = 1;
      GetExitCodeThread(thread_, &exit_code);
      const uint32_t completed_request_seq =
          static_cast<uint32_t>(InterlockedCompareExchange(
              &control_.request_seq, 0, 0));
      const bool stop_was_requested =
          InterlockedCompareExchange(&control_.stop_requested, 0, 0) != 0;
      CloseHandle(thread_);
      thread_ = nullptr;
      installed_ = false;
      InterlockedExchange(&control_.phase, kLbWorkerIdle);
      InterlockedExchange(&control_.stop_requested, 0);
      InterlockedExchange(&control_.request_seq, 0);
      if (fushi_voice_hook::NativeLoopbackWorkerFailureApplies(
              request, completed_request_seq, stop_was_requested,
              exit_code)) {
        failed_request_seq_ = request.seq;
      } else {
        failed_request_seq_ = 0;
      }
    }

    NativeLoopbackWorkerPhase phase = NativeLoopbackWorkerPhase::kAbsent;
    if (thread_ != nullptr) {
      const LONG worker_phase =
          InterlockedCompareExchange(&control_.phase, 0, 0);
      const bool generation_changed =
          static_cast<uint32_t>(InterlockedCompareExchange(
              &control_.request_seq, 0, 0)) != request.seq;
      if (generation_changed) {
        // Even allow->deny->allow entirely between two Poll calls cannot keep
        // the old capture generation alive.
        InterlockedExchange(&control_.stop_requested, 1);
      }
      const bool stopping = generation_changed ||
          InterlockedCompareExchange(&control_.stop_requested, 0, 0) != 0 ||
          worker_phase == kLbWorkerStopping || worker_phase == kLbWorkerExited;
      if (stopping) {
        phase = NativeLoopbackWorkerPhase::kStopping;
      } else if (worker_phase == kLbWorkerRunning) {
        phase = NativeLoopbackWorkerPhase::kRunning;
      } else {
        phase = NativeLoopbackWorkerPhase::kStarting;
      }
    }

    const bool failed_for_request =
        thread_ == nullptr && failed_request_seq_ == request.seq &&
        request.requested == fushi_voice_hook::kNativeLoopbackAllow;
    const NativeLoopbackPolicyAction action =
        fushi_voice_hook::DecideNativeLoopbackPolicyAction(
            request, phase, failed_for_request);
    switch (action) {
      case NativeLoopbackPolicyAction::kStartWorker:
        // Revalidate immediately before the only loopback CreateThread call.
        // The worker independently rechecks policy before COM/Initialize/Start.
        if (!fushi_voice_hook::NativeLoopbackRequestMatches(g_header,
                                                             request)) {
          return;
        }
        failed_request_seq_ = 0;
        InterlockedExchange(&control_.stop_requested, 0);
        InterlockedExchange(&control_.request_seq,
                            static_cast<LONG>(request.seq));
        InterlockedExchange(&control_.phase, kLbWorkerStarting);
        fushi_voice_hook::PublishNativeLoopbackTransientState(
            g_header, request,
            fushi_voice_hook::kNativeLoopbackStateStarting);
        thread_ =
            CreateThread(nullptr, 0, LoopbackWorker, &control_, 0, nullptr);
        installed_ = thread_ != nullptr;
        if (thread_ == nullptr) {
          InterlockedExchange(&control_.phase, kLbWorkerIdle);
          InterlockedExchange(&control_.request_seq, 0);
          failed_request_seq_ = request.seq;
          fushi_voice_hook::PublishNativeLoopbackApplied(
              g_header, request,
              fushi_voice_hook::kNativeLoopbackStateFailed);
        }
        return;
      case NativeLoopbackPolicyAction::kRequestStop:
        InterlockedExchange(&control_.stop_requested, 1);
        fushi_voice_hook::PublishNativeLoopbackTransientState(
            g_header, request,
            fushi_voice_hook::kNativeLoopbackStateStopping);
        return;
      case NativeLoopbackPolicyAction::kPublishStarting:
        fushi_voice_hook::PublishNativeLoopbackTransientState(
            g_header, request,
            fushi_voice_hook::kNativeLoopbackStateStarting);
        return;
      case NativeLoopbackPolicyAction::kPublishStopping:
        fushi_voice_hook::PublishNativeLoopbackTransientState(
            g_header, request,
            fushi_voice_hook::kNativeLoopbackStateStopping);
        return;
      case NativeLoopbackPolicyAction::kAcknowledgeStopped:
        // There is no worker HANDLE here: any previous thread has completed
        // Stop/Release/CoUninitialize and was reaped above.
        failed_request_seq_ = 0;
        fushi_voice_hook::PublishNativeLoopbackApplied(
            g_header, request,
            fushi_voice_hook::kNativeLoopbackStateStopped);
        return;
      case NativeLoopbackPolicyAction::kAcknowledgeRunning:
        fushi_voice_hook::PublishNativeLoopbackApplied(
            g_header, request,
            fushi_voice_hook::kNativeLoopbackStateRunning);
        return;
      case NativeLoopbackPolicyAction::kAcknowledgeFailed:
        fushi_voice_hook::PublishNativeLoopbackApplied(
            g_header, request,
            fushi_voice_hook::kNativeLoopbackStateFailed);
        return;
      case NativeLoopbackPolicyAction::kNone:
        return;
    }
  }

  bool transition_pending() {
    if (g_header == nullptr) return false;
    const bool request_pending = fushi_voice_hook::AtomicLoadShared32(
               &g_header->native_loopback_request_seq) !=
               fushi_voice_hook::AtomicLoadShared32(
                   &g_header->native_loopback_applied_seq);
    const LONG phase = InterlockedCompareExchange(&control_.phase, 0, 0);
    return request_pending ||
           (thread_ != nullptr && phase != kLbWorkerRunning);
  }

  void shutdown() override {
    if (thread_ != nullptr) {
      InterlockedExchange(&control_.stop_requested, 1);
      // This runs on HookWorker, outside loader lock. The context is a member
      // of this stack object, so returning before the worker exits would be a
      // use-after-free; wait for the complete COM reverse-release.
      WaitForSingleObject(thread_, INFINITE);
      CloseHandle(thread_);
      thread_ = nullptr;
    }
    InterlockedExchange(&control_.phase, kLbWorkerIdle);
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  HANDLE thread_ = nullptr;
  LoopbackWorkerControl control_;
  uint32_t failed_request_seq_ = 0;
  bool installed_ = false;
};

class AdapterRegistry {
 public:
  bool siglus_applicable() const { return siglus_.probe(); }

  void InstallStartupAdapters() {
    // Preserve the pre-P1 order exactly: generic audio and resource-file hooks must be ready before
    // the injector observes kDiagStartupAudioHooksReady and resumes a suspended game.
    generic_audio_.install();
    siglus_.InstallResourceAudio();
    tyrano_.install();
    bgi_ethornell_.install();
    artemis_pfs_.install();
    catsystem2_.install();
    malie_libp_.install();
    if (g_header != nullptr) {
      g_header->hook_diagnostics |= kDiagStartupAudioHooksReady;
    }
    unity_.install();
    text_render_.install();
    siglus_.InstallText();
    kirikiri_.InstallDecoders();
    kirikiri_.InstallVoiceStream();
    renpy_.install();
#include "generated/adapter_startup.inc"
  }

  // Policy is already present in the mapping before InjectDll. Exact deny
  // acknowledges stopped without creating a loopback worker or entering COM.
  void InstallFallbackAdapters() { loopback_.install(); }

  void Poll() {
    loopback_.PollPolicy();
    DispatchNewModules();
    generic_audio_.ProcessPendingEvents();
    unity_.ProcessPendingEvents();
    siglus_.ProcessPendingEvents();
    tyrano_.ProcessPendingEvents();
    bgi_ethornell_.ProcessPendingEvents();
    artemis_pfs_.ProcessPendingEvents();
    catsystem2_.ProcessPendingEvents();
    malie_libp_.ProcessPendingEvents();
    elf_ai6_.ProcessPendingEvents();
    kirikiri_.ProcessPendingEvents();
    renpy_.ProcessPendingEvents();
    // These retry budgets and ordering intentionally match the old HookWorker. onModuleLoaded is
    // the stable seam; P3 can replace this bounded poll with real module events without changing
    // individual adapter contracts.
    if (g_capture_enabled && generic_retry_ < kRetryLimit) {
      generic_audio_.onModuleLoaded(nullptr);
      if (!unity_.ready()) unity_.onModuleLoaded(nullptr);
      ++generic_retry_;
    }
    if (!siglus_.audio_ready() && g_capture_enabled &&
        siglus_retry_ < kRetryLimit) {
      siglus_.InstallResourceAudio();
      ++siglus_retry_;
    }
    if (!kirikiri_.decoder_ready() && g_capture_enabled &&
        decoder_retry_ < kRetryLimit) {
      kirikiri_.InstallDecoders();
      ++decoder_retry_;
    }
    if (!kirikiri_.voice_ready() && g_capture_enabled &&
        voice_retry_ < kRetryLimit) {
      kirikiri_.InstallVoiceStream();
      ++voice_retry_;
    }
    if (!renpy_.ready() && g_capture_enabled && renpy_retry_ < kRetryLimit) {
      renpy_.onModuleLoaded(nullptr);
      ++renpy_retry_;
    }
    if (!tyrano_.ready() && g_capture_enabled && tyrano_retry_ < kRetryLimit) {
      tyrano_.install();
      ++tyrano_retry_;
    }
  }

  DWORD PollDelayMs() {
    if (loopback_.transition_pending()) return 10;
    return siglus_.probe() && !siglus_.audio_ready() ? 1 : 200;
  }

  void Shutdown() {
    loopback_.shutdown();
    renpy_.shutdown();
    tyrano_.shutdown();
    kirikiri_.shutdown();
    siglus_.shutdown();
    text_render_.shutdown();
    unity_.shutdown();
    generic_audio_.shutdown();
#include "generated/adapter_shutdown.inc"
  }

 private:
  void DispatchNewModules() {
    const ULONGLONG now = GetTickCount64();
    if (now < next_module_scan_ms_) return;
    next_module_scan_ms_ = now + 200;

    HANDLE snapshot = CreateToolhelp32Snapshot(
        TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, GetCurrentProcessId());
    if (snapshot == INVALID_HANDLE_VALUE) return;
    MODULEENTRY32W entry = {};
    entry.dwSize = sizeof(entry);
    if (Module32FirstW(snapshot, &entry)) {
      const bool notify = modules_seeded_;
      do {
        bool known = false;
        for (const std::wstring& module : known_modules_) {
          if (_wcsicmp(module.c_str(), entry.szModule) == 0) {
            known = true;
            break;
          }
        }
        if (known) continue;
        known_modules_.emplace_back(entry.szModule);
        if (!notify) continue;
        // The notification is dispatched on HookWorker, never under loader lock. Adapters keep
        // their own module filtering/idempotence, while the registry owns observation globally.
        generic_audio_.onModuleLoaded(entry.szModule);
        siglus_.onModuleLoaded(entry.szModule);
        unity_.onModuleLoaded(entry.szModule);
        text_render_.onModuleLoaded(entry.szModule);
        kirikiri_.onModuleLoaded(entry.szModule);
        renpy_.onModuleLoaded(entry.szModule);
        loopback_.onModuleLoaded(entry.szModule);
#include "generated/adapter_module.inc"
      } while (Module32NextW(snapshot, &entry));
      modules_seeded_ = true;
    }
    CloseHandle(snapshot);
  }

  static constexpr int kRetryLimit = 150;
  GenericWindowsAudioAdapter generic_audio_;
  SiglusAdapter siglus_;
  UnityIl2CppAdapter unity_;
  TextRenderAdapter text_render_;
  KiriKiriAdapter kirikiri_;
  RenPyAdapter renpy_;
  TyranoAdapter tyrano_;
  LoopbackAdapter loopback_;
#include "generated/adapter_fields.inc"
  int generic_retry_ = 0;
  int siglus_retry_ = 0;
  int decoder_retry_ = 0;
  int voice_retry_ = 0;
  int renpy_retry_ = 0;
  int tyrano_retry_ = 0;
  ULONGLONG next_module_scan_ms_ = 0;
  bool modules_seeded_ = false;
  std::vector<std::wstring> known_modules_;
};
