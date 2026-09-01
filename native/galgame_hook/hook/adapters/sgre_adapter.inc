// STEINS;GATE RE:BOOT original-resource adapter. Generic XAudio capture only
// supplies a bounded worker-side submission view; all game identity, archive
// membership, XWMA reconstruction, naming and lifecycle stay in this profile.
#include "sgre_profile.h"
#include "sgre_voice_archive.h"

#include "sgre_lookup.inc"

fushi_voice_hook::SgreVoiceArchiveView g_sgre_voice_archive;

bool HandleSgreCompressedResource(
    const fushi_voice_hook::XAudioCompressedResourceSubmission& submission) {
  if (submission.source.format.encoding !=
          fushi_voice_hook::XAudioSourceEncoding::kWmaudio2 ||
      submission.payload == nullptr || submission.payload_bytes == 0 ||
      submission.packet_cumulative_bytes == nullptr ||
      submission.packet_count == 0) {
    return false;
  }
  fushi_voice_hook::SgreVoiceArchiveResourceParts archive_parts;
  if (!fushi_voice_hook::FindSgreVoiceArchiveResourceParts(
          g_sgre_voice_archive, submission.payload,
          submission.payload_bytes, submission.packet_cumulative_bytes,
          submission.packet_count, &archive_parts)) {
    return false;
  }
  std::vector<uint8_t> resource;
  if (!fushi_voice_hook::BuildXwmaResourceFromChunks(
          archive_parts.fmt, archive_parts.fmt_bytes, archive_parts.dpds,
          archive_parts.dpds_bytes, submission.payload,
          submission.payload_bytes, &resource) ||
      resource.size() > std::numeric_limits<uint32_t>::max()) {
    return false;
  }
  wchar_t storage_name[128] = {};
  swprintf_s(storage_name, L"sgre-voicebody-%llu-%p-%llu-%llu.xwma",
             static_cast<unsigned long long>(archive_parts.body_offset),
             reinterpret_cast<void*>(submission.source.source),
             static_cast<unsigned long long>(submission.source.generation),
             static_cast<unsigned long long>(
                 submission.source.queue_generation));
  const bool published = WriteVoiceOggAt(
      resource.data(), static_cast<uint32_t>(resource.size()), storage_name,
      submission.playback_timestamp_ms);
  if (published) {
    SetXAudioDiagnostic(
        fushi_voice_hook::kXAudioDiagGameResourcePublished);
  }
  return published;
}

// Family membership has two independent proofs. The optional voice archive
// admits resource audio without native anchors; the complete draw/vtable proof
// admits text and lookup without an archive. Known and unknown hashes traverse
// the same signature and object-layout validation, and each unresolved hook
// site remains inert rather than falling back to a guessed RVA.
volatile LONG g_sgre_anchor_resolution_in_progress = 0;
volatile LONG g_sgre_anchor_resolution_failures = 0;
alignas(8) volatile LONG64 g_sgre_anchor_resolution_next_retry_tick = 0;
constexpr LONG kSgreAnchorResolutionRetryLimit = 3;
constexpr ULONGLONG kSgreAnchorResolutionRetryDelayMs = 250;

bool ResolveSgreAnchorsOnce() {
  if (g_sgre_anchors_resolved) return true;
  const LONG failures =
      InterlockedCompareExchange(&g_sgre_anchor_resolution_failures, 0, 0);
  if (failures != 0) {
    const ULONGLONG retry_at = static_cast<ULONGLONG>(
        InterlockedCompareExchange64(
            &g_sgre_anchor_resolution_next_retry_tick, 0, 0));
    if (GetTickCount64() < retry_at) return false;
  }
  if (InterlockedCompareExchange(&g_sgre_anchor_resolution_in_progress, 1,
                                 0) != 0) {
    return false;
  }

  bool completed = false;
  const fushi_voice_hook::SgreAnchorSet candidate =
      fushi_voice_hook::ResolveSgreRuntimeAnchors(
          &g_sgre_executable_sha256, &completed);
  if (!completed) {
    const LONG failure =
        InterlockedIncrement(&g_sgre_anchor_resolution_failures);
    if (failure < kSgreAnchorResolutionRetryLimit) {
      InterlockedExchange64(
          &g_sgre_anchor_resolution_next_retry_tick,
          static_cast<LONG64>(GetTickCount64() +
                              kSgreAnchorResolutionRetryDelayMs));
      InterlockedExchange(&g_sgre_anchor_resolution_in_progress, 0);
      return false;
    }
    // Bounded recovery is exhausted. Publish a terminal unresolved result so
    // admission stops saying "still checking" forever, but never substitute
    // a known-build RVA or otherwise guess past the failed live-image read.
    g_sgre_anchors = fushi_voice_hook::SgreAnchorSet{};
  } else {
    g_sgre_anchors = candidate;
  }
  g_sgre_anchors_resolved = true;
  SetXAudioDiagnostic2(g_sgre_anchors.complete()
                          ? fushi_voice_hook::kXAudioDiag2SgreAnchorsResolved
                          : fushi_voice_hook::kXAudioDiag2SgreAnchorsUnresolved);
  InterlockedExchange(&g_sgre_anchor_resolution_in_progress, 0);
  return true;
}

class SgreAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "sgre"; }

  bool probe() const override {
    // Retry a transient initial PE read even if the voice archive already
    // admitted audio. Otherwise the first guard-page race would permanently
    // cache "no text anchors" for this process.
    ResolveSgreAnchorsOnce();
    if (!archive_family_probed_) {
      archive_family_matched_ = fushi_voice_hook::MatchesSgreFamily();
      archive_family_probed_ = true;
    }
    // Text/lookup can prove the engine family without any on-disk voice
    // archive. The mutually corroborated draw/vtable anchors have already
    // passed the same object-layout validation used before installing the
    // hook. voice_body.bin remains an audio capability, not a text gate.
    anchor_family_matched_ =
        g_sgre_anchors_resolved &&
        g_sgre_anchors.lookup_sensor_available();
    const bool was_matched = family_matched_;
    family_matched_ = archive_family_matched_ || anchor_family_matched_;
    if (family_matched_ && !was_matched) {
      SetXAudioDiagnostic2(fushi_voice_hook::kXAudioDiag2SgreFamilyMatched);
    }
    return family_matched_;
  }

  bool lookup_sensor_available() const {
    return probe() && g_sgre_anchors_resolved &&
           g_sgre_anchors.lookup_sensor_available() &&
           !IsSgreLookupStructureFaulted() &&
           g_sgre_anchors.direct_input_shield_available() &&
           !IsSgreDirectInputStructureFaulted();
  }

  // The injector keeps a newly launched process suspended until the startup
  // ready bit is published. RawImageEx labels are commonly rasterized and
  // uploaded during the first frame, so installing this optional trace from
  // the ordinary generated-adapter block (which runs after that bit) is too
  // late: the engine can cache the label before the detour exists. Keep this
  // pre-resume hook narrow and independent from audio/lookup admission; a
  // missing optional UI anchor must never delay or fail process startup.
  void InstallPreResumeUiTrace() {
    if (!probe() || !g_sgre_anchors_resolved) return;
    if (g_sgre_anchors.ui_draw_text_available()) {
      InstallSgreUiDrawTextTrace();
    }
  }

  bool install() override {
    if (installed_) return true;
    if (!probe()) return false;
    ResolveSgreAnchorsOnce();
    // RawImageEx UI labels are rasterized once and then cached by the engine.
    // Install this optional sensor as soon as family/anchor admission succeeds;
    // waiting for the scenario TextDraw structure check can miss every label
    // created during the first scripted screen transition.
    if (g_sgre_anchors.ui_draw_text_available()) {
      InstallSgreUiDrawTextTrace();
    }
    // Device creation normally predates helper injection. Do not make audio
    // support depend on this optional input guard, but install now and retry on
    // every worker tick until the mouse slot is ready. Without a sensor no
    // card can ever appear, so the shield contract is not published either.
    if (g_sgre_anchors.lookup_sensor_available()) {
      InstallSgreDirectInputShield();
    }
    if (archive_family_matched_) {
      std::wstring archive_path;
      if (fushi_voice_hook::SgreVoiceArchivePath(&archive_path) &&
          fushi_voice_hook::OpenSgreVoiceArchive(
              archive_path.c_str(), &g_sgre_voice_archive)) {
        if (RegisterXAudioCompressedResourceHandler(
                &HandleSgreCompressedResource)) {
          audio_installed_ = true;
        } else {
          fushi_voice_hook::CloseSgreVoiceArchive(&g_sgre_voice_archive);
        }
      }
    }
    installed_ = g_sgre_anchors.lookup_sensor_available() || audio_installed_;
    return installed_;
  }

  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio;
  }

  // 家族探测放宽之后，IdentityRejected 这一档在 SGRE 上是**活路径**——这与 Leaf 相反。
  // voice archive 或完整查词锚点都能证明家族；已知和未知构建继续走同一组语义签名与
  // 对象结构证明。于是「音频家族成立、但当前 build 已改变 ABI/codegen，无法安全解析
  // 查词锚点」是可达终局：传感器不会靠等待变得可安装。摘要保留 SHA 只用于诊断和
  // 收集新兼容样本，不代表 SHA 白名单，也不参与未知版本的放行。
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    // The draw detour alone is sufficient for the normal text lane, but it is
    // not sufficient for a clickable in-game lookup sensor: until the exact
    // DirectInput device detour publishes Ready, a host click could pass
    // through to the game. Keep admission fail-closed on that distinction.
    if (g_sgre_text_draw_original != nullptr &&
        IsSgreDirectInputShieldOperational()) {
      report.state = fushi_voice_hook::kLookupAdmissionSensorInstalled;
      return report;
    }
    // 锚点还没解析过 = 还在等 install()，是真的「等门」。
    if (g_sgre_anchors_resolved &&
        (!g_sgre_anchors.lookup_sensor_available() ||
         IsSgreLookupStructureFaulted() ||
         !g_sgre_anchors.direct_input_shield_available() ||
         IsSgreDirectInputStructureFaulted())) {
      report.state = fushi_voice_hook::kLookupAdmissionIdentityRejected;
      fushi_voice_hook::FormatSha256Hex(
          g_sgre_executable_sha256.data(), g_sgre_executable_sha256.size(),
          report.executable_sha256, fushi_voice_hook::kHookModuleDigestChars);
      return report;
    }
    report.state = fushi_voice_hook::kLookupAdmissionIdentityAccepted;
    return report;
  }

  void ProcessPendingEvents() {
    if (!probe() || !g_sgre_anchors_resolved) return;
    // Retry independently from the scenario lookup sensor.  The UI renderer
    // has its own optional ABI and must not inherit TextDraw's runtime gate.
    if (g_sgre_anchors.ui_draw_text_available()) {
      InstallSgreUiDrawTextTrace();
    }
    // Required/Ready is only meaningful while a lookup card can appear, i.e.
    // while the sensor is available; the shield itself additionally needs its
    // own anchor and reports NotReady without it.
    if (g_sgre_anchors.lookup_sensor_available()) {
      // ProcessPendingEvents can be the call that observes a successful
      // bounded anchor retry after the one-shot startup install returned.
      installed_ = true;
      InstallSgreDirectInputShield();
      ProcessSgreLookupTick();
    }
  }

  void onModuleLoaded(const wchar_t*) override {}

  void shutdown() override {
    if (g_header != nullptr) {
      fushi_voice_hook::g_geometry_provider_registry.Retire(
          g_header,
          fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSgre);
    }
    ShutdownSgreDirectInputShield();
    if (audio_installed_) {
      UnregisterXAudioCompressedResourceHandler(&HandleSgreCompressedResource);
      fushi_voice_hook::CloseSgreVoiceArchive(&g_sgre_voice_archive);
      audio_installed_ = false;
    }
    installed_ = false;
  }

  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->xaudio_diagnostics};
  }

 private:
  mutable bool archive_family_probed_ = false;
  mutable bool family_matched_ = false;
  mutable bool archive_family_matched_ = false;
  mutable bool anchor_family_matched_ = false;
  bool installed_ = false;
  bool audio_installed_ = false;
};
