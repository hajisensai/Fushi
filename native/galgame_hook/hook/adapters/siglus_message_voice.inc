// Single-worker resource binding for the structurally proved message feed.
// Included after siglus_message_capture.inc; never called by game callbacks.

constexpr size_t kSiglusFrozenArchiveCapacity = 1024;
constexpr size_t kSiglusPendingVoiceCapacity = 64;
struct SiglusFrozenArchive {
  bool used = false;
  bool invalid = false;
  uint32_t component = 0;
  uint64_t revision = 0;
  std::wstring path;
  BY_HANDLE_FILE_INFORMATION identity = {};
  std::array<uint8_t, 32> index_digest = {};
};
std::array<SiglusFrozenArchive, kSiglusFrozenArchiveCapacity>
    g_siglus_frozen_archives;
fushi_voice_hook::siglus::VoiceBindingCache<> g_siglus_voice_bindings;
std::array<uint64_t, kSiglusPendingVoiceCapacity> g_siglus_pending_voice_ids = {};
size_t g_siglus_pending_voice_cursor = 0;
std::array<uint8_t, fushi_voice_hook::siglus::kVoiceMemberIndexScratchBytes>
    g_siglus_member_index_scratch = {};

bool SameSiglusArchiveFile(const BY_HANDLE_FILE_INFORMATION& a,
                           const BY_HANDLE_FILE_INFORMATION& b) {
  return a.dwVolumeSerialNumber == b.dwVolumeSerialNumber &&
      a.nFileIndexHigh == b.nFileIndexHigh && a.nFileIndexLow == b.nFileIndexLow &&
      a.nFileSizeHigh == b.nFileSizeHigh && a.nFileSizeLow == b.nFileSizeLow &&
      a.ftLastWriteTime.dwHighDateTime == b.ftLastWriteTime.dwHighDateTime &&
      a.ftLastWriteTime.dwLowDateTime == b.ftLastWriteTime.dwLowDateTime;
}

bool HashSiglusMemberIndex(const uint8_t* index, size_t bytes,
                           std::array<uint8_t, 32>* digest) {
  if (index == nullptr || digest == nullptr || bytes == 0 || bytes > UINT32_MAX)
    return false;
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                  nullptr, 0) < 0) return false;
  const NTSTATUS result = BCryptHash(algorithm, nullptr, 0,
      const_cast<PUCHAR>(index), static_cast<ULONG>(bytes), digest->data(),
      static_cast<ULONG>(digest->size()));
  BCryptCloseAlgorithmProvider(algorithm, 0);
  return result >= 0;
}

// This spelling is enabled only after the profile proves the formatter and
// composite-key arithmetic. It never detects an engine from its file names.
bool ReadSiglusArchiveComponent(const wchar_t* path, uint32_t* component) {
  if (path == nullptr || component == nullptr) return false;
  const wchar_t* slash = wcsrchr(path, L'\\');
  const wchar_t* name = slash == nullptr ? path : slash + 1;
  const size_t length = wcslen(name);
  if ((length != 9 && length != 10) || name[0] != L'z' ||
      wcscmp(name + length - 4, L".ovk") != 0)
    return false;
  uint32_t value = 0;
  for (size_t i = 1; i != length - 4; ++i) {
    if (name[i] < L'0' || name[i] > L'9') return false;
    value = value * 10u + static_cast<uint32_t>(name[i] - L'0');
  }
  // %04d specifies a minimum width. Larger legal quotients use five digits.
  if ((length == 10 && value < 10000) || value > UINT32_MAX / 100000u)
    return false;
  *component = value;
  return true;
}

uint64_t ObserveSiglusMessageResource(HANDLE file, const uint8_t* index,
    size_t index_bytes, uint64_t file_bytes,
    const fushi_voice_hook::siglus::OvkEntry& entry, uint32_t expected_key) {
  if (!IsSiglusMessageVoiceMappingProved()) return 0;
  wchar_t canonical[fushi_voice_hook::siglus::kVoiceSourcePathCapacity] = {};
  const DWORD chars = GetFinalPathNameByHandleW(file, canonical,
      static_cast<DWORD>(std::size(canonical)), FILE_NAME_NORMALIZED);
  uint32_t component = 0;
  if (chars == 0 || chars >= std::size(canonical) ||
      !ReadSiglusArchiveComponent(canonical, &component) ||
      expected_key == UINT32_MAX || component != expected_key / 100000u ||
      entry.member_id != expected_key % 100000u) return 0;
  SiglusFrozenArchive* archive = nullptr;
  SiglusFrozenArchive* empty = nullptr;
  for (auto& candidate : g_siglus_frozen_archives) {
    if (candidate.used && candidate.component == component) archive = &candidate;
    if (!candidate.used && empty == nullptr) empty = &candidate;
  }
  if (archive != nullptr && archive->invalid) return 0;
  BY_HANDLE_FILE_INFORMATION identity = {};
  std::array<uint8_t, 32> digest = {};
  const bool validated = GetFileInformationByHandle(file, &identity) != FALSE &&
      fushi_voice_hook::siglus::ValidateUniqueVoiceMemberIndex(index, index_bytes,
          file_bytes, g_siglus_member_index_scratch.data(),
          g_siglus_member_index_scratch.size()) &&
      HashSiglusMemberIndex(index, index_bytes, &digest);
  if (!validated) {
    if (archive != nullptr) archive->invalid = true;
    return 0;
  }
  if (archive != nullptr) {
    if (archive->path != canonical ||
        !SameSiglusArchiveFile(archive->identity, identity) ||
        archive->index_digest != digest) {
      archive->invalid = true;
      return 0;
    }
  } else {
    if (empty == nullptr) return 0;
    archive = empty;
    archive->used = true;
    archive->component = component;
    archive->revision = static_cast<uint64_t>(archive -
        g_siglus_frozen_archives.data()) + 1;
    archive->path = canonical;
    archive->identity = identity;
    archive->index_digest = digest;
  }
  const auto status = g_siglus_voice_bindings.ObserveResource({component,
      entry.member_id, canonical, entry.offset, archive->revision});
  using Status = fushi_voice_hook::siglus::VoiceBindingStatus;
  return status == Status::kAccepted || status == Status::kDuplicate
      ? archive->revision : 0;
}

bool ValidateSiglusMessageVoiceTask(const SiglusVoiceTask& task,
    uint64_t revision, const fushi_voice_hook::siglus::OvkEntry& entry) {
  using namespace fushi_voice_hook::siglus;
  if (task.text_event_id == 0 || revision == 0 ||
      revision != task.archive_revision ||
      entry.member_id != task.voice_key % kVoiceMemberRadix) return false;
  const size_t archive_index = static_cast<size_t>(revision - 1);
  if (archive_index >= g_siglus_frozen_archives.size()) return false;
  const auto& archive = g_siglus_frozen_archives[archive_index];
  VoiceBinding binding;
  return archive.used && !archive.invalid &&
      archive.component == task.voice_key / kVoiceMemberRadix &&
      g_siglus_voice_bindings.GetBinding(task.text_event_id, &binding) ==
          VoiceBindingStatus::kReady &&
      binding.text.voice_key == task.voice_key &&
      binding.resource.archive_revision == revision &&
      binding.resource.source_offset == task.offset &&
      binding.resource.source_path == task.path;
}

void QueueSiglusMessageVoice(uint64_t event_id, uint32_t voice_key,
                             uint64_t tick_ms) {
  if (!IsSiglusMessageVoiceMappingProved() || event_id == 0 ||
      voice_key == fushi_voice_hook::siglus::kNoVoiceKey) return;
  // Bound unresolved history by events, never by elapsed time. Dropped old
  // identities cannot resurrect because the cache retains a sequence watermark.
  uint64_t& displaced = g_siglus_pending_voice_ids[g_siglus_pending_voice_cursor];
  if (displaced != 0) g_siglus_voice_bindings.DiscardEvent(displaced);
  displaced = event_id;
  g_siglus_pending_voice_cursor = (g_siglus_pending_voice_cursor + 1) %
      g_siglus_pending_voice_ids.size();
  g_siglus_voice_bindings.ObserveText({event_id, voice_key, tick_ms});
}

void ProcessSiglusMessageVoiceBindings() {
  if (!IsSiglusMessageVoiceMappingProved()) return;
  using namespace fushi_voice_hook::siglus;
  for (size_t i = 0; i != kSiglusPendingVoiceCapacity; ++i) {
    VoiceBinding binding;
    if (g_siglus_voice_bindings.NextBinding(&binding) != VoiceBindingStatus::kReady)
      break;
    SiglusVoiceTask task;
    task.tick_ms = binding.text.text_tick;
    task.text_event_id = binding.text.event_id;
    task.voice_key = binding.text.voice_key;
    task.offset = binding.resource.source_offset;
    task.archive_revision = binding.resource.archive_revision;
    wcsncpy_s(task.path, binding.resource.source_path.c_str(), _TRUNCATE);
    ProcessSiglusVoiceTask(&task);
    if (task.exported) g_siglus_voice_bindings.ConsumeEvent(task.text_event_id);
    else g_siglus_voice_bindings.DiscardEvent(task.text_event_id);
  }
}

// The source observer drains its bounded queue on this worker. Its key/path/
// offset/length all belong to one admitted engine OggOpen invocation.
void QueueProvedSiglusVoiceResource(uint32_t key, const wchar_t* path,
                                     uint32_t offset, uint32_t length) {
  if (!IsSiglusMessageVoiceMappingProved() || path == nullptr ||
      key == UINT32_MAX || length == 0 ||
      wcslen(path) >= fushi_voice_hook::siglus::kVoiceSourcePathCapacity) return;
  SiglusVoiceTask task;
  task.voice_key = key;
  task.offset = offset;
  task.source_length = length;
  task.proved_source = true;
  wcsncpy_s(task.path, path, _TRUNCATE);
  ProcessSiglusVoiceTask(&task);
}

void ShutdownSiglusMessageVoice() {
  g_siglus_voice_bindings.Reset();
  for (auto& archive : g_siglus_frozen_archives) archive = {};
  g_siglus_pending_voice_ids.fill(0);
  g_siglus_pending_voice_cursor = 0;
}
