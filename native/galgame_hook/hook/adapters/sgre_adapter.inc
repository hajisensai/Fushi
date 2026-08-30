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

// Family membership is the probe; the executable hash only selects measured
// anchors. Unknown builds are attempted (signature resolution), and each hook
// site stays inert for whatever anchor did not resolve. The archive-membership
// audio proof needs no anchor at all, so it works for every family build.
void ResolveSgreAnchorsOnce() {
  if (g_sgre_anchors_resolved) return;
  g_sgre_anchors =
      fushi_voice_hook::ResolveSgreRuntimeAnchors(&g_sgre_executable_sha256);
  g_sgre_anchors_resolved = true;
  SetXAudioDiagnostic2(fushi_voice_hook::kXAudioDiag2SgreFamilyMatched);
  SetXAudioDiagnostic2(g_sgre_anchors.complete()
                          ? fushi_voice_hook::kXAudioDiag2SgreAnchorsResolved
                          : fushi_voice_hook::kXAudioDiag2SgreAnchorsUnresolved);
}

class SgreAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "sgre"; }

  bool probe() const override {
    if (!family_probed_) {
      family_matched_ = fushi_voice_hook::MatchesSgreFamily();
      family_probed_ = true;
    }
    return family_matched_;
  }

  bool lookup_sensor_available() const {
    return probe() && g_sgre_anchors_resolved &&
           g_sgre_anchors.lookup_sensor_available();
  }

  bool install() override {
    if (installed_) return true;
    if (!probe()) return false;
    ResolveSgreAnchorsOnce();
    // Device creation normally predates helper injection. Do not make audio
    // support depend on this optional input guard, but install now and retry on
    // every worker tick until the mouse slot is ready. Without a sensor no
    // card can ever appear, so the shield contract is not published either.
    if (g_sgre_anchors.lookup_sensor_available()) {
      InstallSgreDirectInputShield();
    }
    std::wstring archive_path;
    if (!fushi_voice_hook::SgreVoiceArchivePath(&archive_path) ||
        !fushi_voice_hook::OpenSgreVoiceArchive(
            archive_path.c_str(), &g_sgre_voice_archive)) {
      return false;
    }
    if (!RegisterXAudioCompressedResourceHandler(
            &HandleSgreCompressedResource)) {
      fushi_voice_hook::CloseSgreVoiceArchive(&g_sgre_voice_archive);
      return false;
    }
    installed_ = true;
    return true;
  }

  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio;
  }

  // 家族探测放宽之后，IdentityRejected 这一档在 SGRE 上是**活路径**——这与 Leaf 相反，
  // 别照着 Leaf 那条注释理解。Leaf 的 probe() 就是它的 hash 门，身份不符时根本不会被
  // registry 问话；而 SGRE 的 probe() 现在只问家族（exe 旁边有没有 voice_body.bin），
  // 精确 hash 只用来挑量好的锚点。于是「是这个游戏、但这个 build 的查词锚点连签名
  // 扫描都没解出来」成了可达状态，而它是**终局**：传感器永远装不上，再等也没有用。
  //
  // 协议对这一档的定义正是「引擎有传感器，但当前 exe 不在该传感器的精确白名单里
  // （hash-pinned fail closed），此时 lookup_executable_sha256 必须已填」。报成
  // IdentityAccepted 会把终局说成「还在等门」，用户会一直等；摘要留空还会让他连版本
  // 都报不出来——那正是这一档存在的理由。
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    if (g_sgre_text_draw_original != nullptr) {
      report.state = fushi_voice_hook::kLookupAdmissionSensorInstalled;
      return report;
    }
    // 锚点还没解析过 = 还在等 install()，是真的「等门」。
    if (g_sgre_anchors_resolved && !g_sgre_anchors.lookup_sensor_available()) {
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
    // Required/Ready is only meaningful while a lookup card can appear, i.e.
    // while the sensor is available; the shield itself additionally needs its
    // own anchor and reports NotReady without it.
    if (g_sgre_anchors.lookup_sensor_available()) {
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
    if (!installed_) return;
    UnregisterXAudioCompressedResourceHandler(&HandleSgreCompressedResource);
    fushi_voice_hook::CloseSgreVoiceArchive(&g_sgre_voice_archive);
    installed_ = false;
  }

  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->xaudio_diagnostics};
  }

 private:
  mutable bool family_probed_ = false;
  mutable bool family_matched_ = false;
  bool installed_ = false;
};
