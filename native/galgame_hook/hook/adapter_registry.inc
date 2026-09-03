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
  void ProcessPendingEvents() {
    ProcessSiglusVoiceTasks();
    ProcessSiglusLookupTick();
  }
  bool audio_ready() const { return audio_ready_; }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio |
           fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    return SiglusLookupAdmission();
  }
  void onModuleLoaded(const wchar_t*) override {
    // Siglus hooks target the main executable and kernel32 file APIs; startup install + bounded
    // MinHook retry handles its protected launch window, not delayed engine modules.
  }
  void shutdown() override {
    ShutdownSiglusLookup();
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
  // KiriKiri 没有 exe hash 门，但有一道等价的运行期门：传感器要等 TJS exporter、引擎
  // 主线程接缝和 bootstrap 脚本三样在引擎里依次跑通（KAGEX 走 global.TextRender，经典
  // KAG3 走逐实例 drawText 补丁，BUG-2116）。因此"装上了"与"还没装上"之间不存在身份
  // 拒绝这一档——未装一律报 IdentityAccepted，表示"引擎对得上，传感器还没到位"。把它
  // 谎报成 IdentityRejected 会让用户去换游戏版本，而真正该做的是看 xaudio_diagnostics2
  // 的 kXAudioDiag2KirikiriLookup* 位卡在安装路径哪一步（BUG-2121）。
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    report.state = KirikiriLookupSensorLive()
                       ? fushi_voice_hook::kLookupAdmissionSensorInstalled
                       : fushi_voice_hook::kLookupAdmissionIdentityAccepted;
    return report;
  }
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
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderRuntimeLayout,
        fushi_voice_hook::kLookupGeometryProviderIdKirikiri);
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
  // Ren'Py 也没有 exe hash 门：装不上的原因是找不到 CPython 或解释器没初始化，
  // 那属于"引擎对得上、传感器还没到位"，不是身份被拒。
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    report.state = RenpyLookupSensorLive()
                       ? fushi_voice_hook::kLookupAdmissionSensorInstalled
                       : fushi_voice_hook::kLookupAdmissionIdentityAccepted;
    return report;
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
    ShutdownRenpyLookup();
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
    // HUNEX reuses the shared KernelBase broker installed by Siglus above.
    // Install it before startup-ready resumes the suspended game so the first
    // playback read cannot race ahead of handle tracking.
    hunex_gge_.install();
    // SGRE RawImageEx labels can be rasterized once on the very first frame
    // and then live only as cached textures. Install its optional UI trace
    // while the injector still owns the startup suspension; the generated
    // adapter block below intentionally runs after the ready bit and is too
    // late for this one-shot renderer boundary.
    sgre_.InstallPreResumeUiTrace();
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

  // 只推进 native loopback 的策略状态机，不碰任何引擎适配器。
  //
  // 为什么需要它：`install()` 只把 worker 起出来并发布 starting，真正的
  // `applied/running` 确认要等 worker `IAudioClient::Start()` 成功后的**下一轮**
  // PollPolicy 才发布。而在 HookWorker 里，下一轮 Poll 被 MH_Initialize() +
  // InstallStartupAdapters() 的重量级引擎探测挡在后面——早注入路径给这个确认的预算
  // 只有 5s，于是 allow 的 ack 经常赶不上，注入编排随之中止（BUG-2131）。
  // 暴露一个只跑策略的入口，让 dll_main 能在引擎探测**之前**把确认追平，兑现
  // 「Apply/ack native loopback policy before potentially expensive engine
  // probing」那句既有注释对 allow 的承诺（此前它只对 deny 成立）。
  void PollLoopbackPolicyOnly() { loopback_.PollPolicy(); }

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
    sgre_.ProcessPendingEvents();
    leaf_aquaplus_.ProcessPendingEvents();
    hunex_gge_.ProcessPendingEvents();
    smash_fzmedia_.ProcessPendingEvents();
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
    PublishLookupAdmissionSummary();
    PublishAdapterReportSnapshot();
  }

  // v23：把每个 adapter 的 diagnostics() 抄进共享内存（BUG-2149）。唯一写者，与下面的
  // 准入汇总同处、同纪律。
  //
  // 为什么需要：AdapterDiagnostics 以前只被契约测试读，运行期没有消费方，于是「这局
  // 到底哪个 adapter 认领了、装上没有」在真机上看不见——每加一个引擎就多一个答不出的
  // 问题，而 engine-support 的证据门恰恰要求逐门可判。
  //
  // 这里**不**沿用准入汇总那份「只算引擎身份 adapter」的过滤。那条过滤是为了不让
  // generic_audio_ / text_render_ / loopback_ 的恒真 probe() 污染「这游戏是哪个引擎」
  // 的结论；而本面回答的是另一个问题——「哪些 adapter 现在是活的」，横切能力生效与否
  // 恰恰是要看的。每行自带 id，读者不会把 `process_loopback applicable=1` 误读成引擎判定。
  //
  // 限速 1 秒：diagnostics() 内部会调 probe()，而 CMVS / AOS / Unreal 的 probe 要读盘
  // 枚举（cfg 前缀、*.aos 头、Content\Paks\*.utoc），Poll 最快 16ms 一轮。诊断面没有
  // 低延迟需求，不该为它每秒付几十次目录枚举。
  void PublishAdapterReportSnapshot() {
    if (g_header == nullptr) return;
    const ULONGLONG now = GetTickCount64();
    if (adapter_report_tick_ != 0 && now - adapter_report_tick_ < 1000) return;
    adapter_report_tick_ = now;

    fushi_voice_hook::AdapterReportSlot slots[fushi_voice_hook::kAdapterReportSlots] = {};
    size_t used = 0;
    auto consider = [&slots, &used](const fushi_voice_hook::EngineAdapter& adapter) {
      if (used >= fushi_voice_hook::kAdapterReportSlots) return;
      const fushi_voice_hook::AdapterDiagnostics diagnostics = adapter.diagnostics();
      fushi_voice_hook::AdapterReportSlot& slot = slots[used++];
      const char* id = diagnostics.id == nullptr ? "" : diagnostics.id;
      // 有界拷贝：id 由 adapter 自己给，长度不受本文件控制。
      size_t n = 0;
      while (id[n] != '\0' && n + 1 < fushi_voice_hook::kAdapterReportIdChars) {
        slot.id[n] = id[n];
        ++n;
      }
      slot.id[n] = '\0';
      slot.applicable = diagnostics.applicable ? 1u : 0u;
      slot.installed = diagnostics.installed ? 1u : 0u;
      slot.flags = diagnostics.flags;
    };
    // 手写的 8 个（含三个横切能力），随后复用**同一份生成清单**——新引擎由脚手架写进
    // adapter_admission.inc，于是自动出现在本读数里，不存在第二份会漂移的清单。
    consider(generic_audio_);
    consider(siglus_);
    consider(unity_);
    consider(text_render_);
    consider(kirikiri_);
    consider(renpy_);
    consider(tyrano_);
    consider(loopback_);
#include "generated/adapter_admission.inc"
    fushi_voice_hook::PublishAdapterReports(g_header, slots, used);
  }

  // v19：把「本会话游戏内查词能不能用」汇总成一个值发布给 host。
  //
  // 唯一写者。每个 adapter 只回答自己那份（纯查询的 lookupAdmission()），合并规则在这里
  // 一处定死：**取进展最高的那个**。理由是这些报告互不矛盾，只是各说各的 adapter——
  // Leaf 说"身份不符"和 Siglus 说"本引擎没做"可以同时为真，而用户要看的是"最有希望的
  // 那条路走到哪了"。让每个 adapter 自己往 header 里写就会互相覆盖，最后显示哪条取决于
  // Poll 里的调用顺序，那是把 UI 结论押在一个没人当契约维护的顺序上。
  void PublishLookupAdmissionSummary() {
    if (g_header == nullptr) return;
    if (!fushi_voice_hook::HasLookupRegion(g_header)) return;
    fushi_voice_hook::LookupAdmissionReport best;
    bool any_engine_claimed = false;
    auto consider = [&best,
                     &any_engine_claimed](
                        const fushi_voice_hook::EngineAdapter& adapter) {
      if (!adapter.probe()) return;
      any_engine_claimed = true;
      const fushi_voice_hook::LookupAdmissionReport report =
          adapter.lookupAdmission();
      if (report.state > best.state) best = report;
    };
    // 只有**引擎身份** adapter 参与。generic_audio_ / text_render_ / loopback_ 的
    // probe() 恒为 true（它们是横切能力，不声称"这游戏是哪个引擎"），放进来会让任何
    // 游戏在引擎探测成立之前就先被判成 EngineUnsupported——开关先灰后亮，比不显示更糟。
    consider(siglus_);
    consider(unity_);
    consider(kirikiri_);
    consider(renpy_);
    consider(tyrano_);
#include "generated/adapter_admission.inc"
    // 一个引擎 adapter 都没 probe 成立时 best 保持 Unknown：那是"还没认出这是什么游戏"，
    // 不是"不支持"。这两者必须分开，否则注入后的头几轮 Poll 会稳定误报。
    //
    // 但 Unknown 不能是**终态**：有几家（Leaf/SGRE）的 probe() 本身就是精确 exe hash 门，
    // 所以「白2 的另一个发行版」这种情形下没有任何 adapter 会认领，best 会永远停在
    // Unknown，用户界面上就是永远"正在判定"——比直接说不支持还糟，因为它不给任何出路。
    // 模块表**稳定**之后仍无人认领，才是一个确定的结论：这个游戏我们不认识，查词
    // 用不了。这里合并了"认出引擎但它没传感器"和"压根没认出引擎"——对用户来说处置
    // 相同（用不了 + 请把 exe 摘要报上来），host 文案按"不支持或未识别"表述即可。
    //
    // 判据必须是 module_settle_.settled()（连续 15 次 200ms 全量扫描无新模块，且距
    // 首次扫描已过 5 秒），**不能**是 modules_seeded_ —— 后者在注入完成的第 1 拍就
    // 成立，而 KiriKiri / Ren'Py / Unity 的 probe 全是迟到信号（前者要等第一句有声
    // 台词把 wuvorbis.dll 拉进来）。用 modules_seeded_ 等于对着一个唯一已发布查词
    // 的引擎自信地说「本引擎没做查词」，要等第一句语音才自愈。
    if (!any_engine_claimed && module_settle_.settled(GetTickCount64()) &&
        best.state == fushi_voice_hook::kLookupAdmissionUnknown) {
      best.state = fushi_voice_hook::kLookupAdmissionEngineUnsupported;
      // 上面那句"请把 exe 摘要报上来"得真给得出摘要。这一档的定义就是没有任何
      // adapter 认领，各家私有缓冲在这里全部够不着，所以读共享槽（Leaf 的 profile
      // 解析对任何 x86 游戏都会跑，顺手把它填满了）。算不出就留空串——host 要能说
      // "算不出"，而不是显示 64 个 0 让用户以为那就是他的 hash。
      // 两边都是 kHookModuleDigestChars，共享槽恒带 NUL（要么空串、要么 64 位十六进制
      // + NUL），所以整段拷贝是精确的——与 Siglus 那处同一种写法。
      std::memcpy(best.executable_sha256,
                  fushi_voice_hook::HostExecutableSha256Hex(),
                  sizeof(best.executable_sha256));
    }
    fushi_voice_hook::PublishLookupAdmission(g_header, best);
  }

  DWORD PollDelayMs() {
    if (loopback_.transition_pending()) return 10;
    if (sgre_.lookup_sensor_available() && g_header != nullptr &&
        fushi_voice_hook::HasLookupRegion(g_header) &&
        g_header->lookup_enabled != 0) {
      return 16;
    }
    if (siglus_.probe() && IsSiglusLookupProfileMatched() &&
        g_header != nullptr && fushi_voice_hook::HasLookupRegion(g_header) &&
        g_header->lookup_enabled != 0) {
      return 16;
    }
    if (leaf_aquaplus_.probe() && g_header != nullptr &&
        fushi_voice_hook::HasLookupRegion(g_header) &&
        g_header->lookup_enabled != 0) {
      return 16;
    }
    if (hunex_gge_.lookup_sensor_available() && g_header != nullptr &&
        fushi_voice_hook::HasLookupRegion(g_header) &&
        g_header->lookup_enabled != 0) {
      return 16;
    }
    if (smash_fzmedia_.lookup_sensor_available() && g_header != nullptr &&
        fushi_voice_hook::HasLookupRegion(g_header) &&
        g_header->lookup_enabled != 0) {
      return 16;
    }
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
      const size_t known_before = known_modules_.size();
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
      // 首拍必然长出一整张表，那不是「变化」、只是第一次看见——但也不能当成
      // 「没变化」去起算安静计数，否则满表落地那一刻就开始攒。首拍一律记成有新
      // 模块，安静计数从第二拍才开始。
      //
      // known_modules_ 只增不减，所以 size() 变化就是「本拍发现了新模块」的精确
      // 判据，不需要另设标志位。快照失败的早返回路径不调 OnScanCompleted ——
      // 那是「没观测到」，不是「观测到没变」。
      module_settle_.OnScanCompleted(
          !notify || known_modules_.size() != known_before, now);
    }
    CloseHandle(snapshot);
  }

  static constexpr int kRetryLimit = 150;
  ULONGLONG adapter_report_tick_ = 0;  // v23 读数限速（见 PublishAdapterReportSnapshot）
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
  // 只表示「首拍已过」（用于抑制首张全表的 onModuleLoaded 风暴），**不表示稳定**。
  bool modules_seeded_ = false;
  // 表示「模块表稳定了」。两者曾是同一个 bool，那正是准入在第 1 拍就误报的根因。
  fushi_voice_hook::ModuleTableSettle module_settle_;
  std::vector<std::wstring> known_modules_;
};
