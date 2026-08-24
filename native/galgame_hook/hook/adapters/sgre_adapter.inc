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

class SgreAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "sgre"; }

  bool probe() const override {
    if (!profile_probed_) {
      profile_matched_ = fushi_voice_hook::MatchesSgreProfile(nullptr);
      profile_probed_ = true;
    }
    return profile_matched_;
  }

  bool install() override {
    if (installed_) return true;
    if (!probe()) return false;
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

  void ProcessPendingEvents() {
    if (probe()) ProcessSgreLookupTick();
  }

  void onModuleLoaded(const wchar_t*) override {}

  void shutdown() override {
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
  mutable bool profile_probed_ = false;
  mutable bool profile_matched_ = false;
  bool installed_ = false;
};
