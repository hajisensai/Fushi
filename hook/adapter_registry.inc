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
    : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "xaudio2_directsound"; }
  bool probe() const override { return true; }
  bool install() override {
    TryHookXAudio2Create();
    TryHookDirectSoundCreate();
    installed_ = true;
    return true;
  }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    if (module_name == nullptr || ModuleNameEquals(module_name, L"xaudio2_9.dll") ||
        ModuleNameEquals(module_name, L"xaudio2_8.dll") ||
        ModuleNameEquals(module_name, L"dsound.dll") ||
        ModuleNameEquals(module_name, L"ole32.dll")) {
      install();
    }
  }
  void shutdown() override { installed_ = false; }
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
};

class SiglusAdapter final : public hibiki_voice_hook::EngineAdapter {
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
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText |
           hibiki_voice_hook::AdapterCapability::kResourceAudio |
           hibiki_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {
    // Siglus hooks target the main executable and kernel32 file APIs; startup install + bounded
    // MinHook retry handles its protected launch window, not delayed engine modules.
  }
  void shutdown() override {
    installed_ = false;
    audio_ready_ = false;
  }
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool audio_ready_ = false;
};

class UnityIl2CppAdapter final : public hibiki_voice_hook::EngineAdapter {
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
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText |
           hibiki_voice_hook::AdapterCapability::kResourceAudio |
           hibiki_voice_hook::AdapterCapability::kPcmAudio;
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
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool ready_ = false;
};

class TextRenderAdapter final : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "text_render"; }
  bool probe() const override { return true; }
  bool install() override {
    TryHookTextRender();
    installed_ = true;
    return true;
  }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    if (module_name == nullptr || ModuleNameEquals(module_name, L"gdi32.dll") ||
        ModuleNameEquals(module_name, L"user32.dll")) {
      install();
    }
  }
  void shutdown() override { installed_ = false; }
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
};

class KiriKiriAdapter final : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "kirikiri_z"; }
  bool probe() const override {
    return GetModuleHandleW(L"wuvorbis.dll") != nullptr ||
           GetModuleHandleW(L"wuopus.dll") != nullptr;
  }
  bool install() override {
    const bool decoder_ready = InstallDecoders();
    const bool voice_ready = InstallVoiceStream();
    return decoder_ready && voice_ready;
  }
  bool InstallDecoders() {
    decoder_ready_ = TryHookKirikiriDecoders();
    installed_ = installed_ || decoder_ready_;
    return decoder_ready_;
  }
  bool InstallVoiceStream() {
    voice_ready_ = TryHookKirikiriVoiceStream();
    installed_ = installed_ || voice_ready_;
    return voice_ready_;
  }
  bool decoder_ready() const { return decoder_ready_; }
  bool voice_ready() const { return voice_ready_; }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText |
           hibiki_voice_hook::AdapterCapability::kResourceAudio |
           hibiki_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    if (module_name == nullptr || ModuleNameEquals(module_name, L"wuvorbis.dll") ||
        ModuleNameEquals(module_name, L"wuopus.dll")) {
      install();
    }
  }
  void shutdown() override {
    installed_ = false;
    decoder_ready_ = false;
    voice_ready_ = false;
  }
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool decoder_ready_ = false;
  bool voice_ready_ = false;
};

class RenPyAdapter final : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "renpy_ffmpeg"; }
  bool probe() const override {
    uint32_t major = 0;
    return FindLoadedFfmpegModule(
               hibiki_voice_hook::FfmpegModuleKind::kAvformat, &major) !=
           nullptr;
  }
  bool install() override {
    ready_ = TryHookRenpyAudio();
    installed_ = installed_ || ready_;
    return ready_;
  }
  bool ready() const { return ready_; }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText |
           hibiki_voice_hook::AdapterCapability::kResourceAudio |
           hibiki_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    const auto ffmpeg = hibiki_voice_hook::ParseFfmpegModuleName(module_name);
    if (module_name == nullptr ||
        ffmpeg.kind != hibiki_voice_hook::FfmpegModuleKind::kNone ||
        hibiki_voice_hook::IsMonolithicFfmpegModuleName(module_name)) {
      install();
    }
  }
  void shutdown() override {
    StopRenpyWorker();
    installed_ = false;
    ready_ = false;
  }
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool ready_ = false;
};

class TyranoAdapter final : public hibiki_voice_hook::EngineAdapter {
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
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kResourceAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    StopTyranoAsarAudio();
    installed_ = false;
    ready_ = false;
  }
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool ready_ = false;
};

class LoopbackAdapter final : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "process_loopback"; }
  bool probe() const override { return true; }
  bool install() override {
    if (g_lb_thread == nullptr) {
      g_lb_thread =
          CreateThread(nullptr, 0, LoopbackWorker, nullptr, 0, nullptr);
    }
    installed_ = g_lb_thread != nullptr;
    return installed_;
  }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    if (g_lb_thread != nullptr) {
      WaitForSingleObject(g_lb_thread, 2000);
      CloseHandle(g_lb_thread);
      g_lb_thread = nullptr;
    }
    installed_ = false;
  }
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
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

  void InstallFallbackAdapters() { loopback_.install(); }

  void Poll() {
    DispatchNewModules();
    siglus_.ProcessPendingEvents();
    tyrano_.ProcessPendingEvents();
    bgi_ethornell_.ProcessPendingEvents();
    artemis_pfs_.ProcessPendingEvents();
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

  DWORD PollDelayMs() const {
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
