#undef NDEBUG
#include <windows.h>
#include <bcrypt.h>
#include <array>
#include <cassert>
#include <cstring>
#include <string>
#include "siglus_ovk.h"
#include "siglus_voice_binding.h"

namespace {
struct SiglusVoiceTask {
  uint64_t tick_ms = 0;
  uint64_t offset = 0;
  uint64_t text_event_id = 0;
  uint64_t archive_revision = 0;
  uint32_t voice_key = UINT32_MAX;
  uint32_t source_length = 0;
  bool proved_source = false;
  bool exported = false;
  wchar_t path[520] = {};
};
bool mapping_proved = false;
bool IsSiglusMessageVoiceMappingProved() { return mapping_proved; }
uint64_t last_exported_event = 0;
bool writer_succeeds = true;
// The engine worker's IO is exercised separately; this seam checks dispatch
// identity and commit/failure cleanup against the actual binding worker.
void ProcessSiglusVoiceTask(SiglusVoiceTask* task) {
  last_exported_event = task->text_event_id;
  task->exported = writer_succeeds;
}
#include "adapters/siglus_message_voice.inc"

std::array<uint32_t, 5> Index(uint32_t member = 125) {
  return {1, 8, 20, member, 166452};
}
void WriteArchive(HANDLE file, const std::array<uint32_t, 5>& index) {
  LARGE_INTEGER start = {};
  assert(SetFilePointerEx(file, start, nullptr, FILE_BEGIN));
  DWORD done = 0;
  assert(WriteFile(file, index.data(), static_cast<DWORD>(sizeof(index)),
                  &done, nullptr) && done == sizeof(index));
  const uint64_t synthetic_payload = 0;
  assert(WriteFile(file, &synthetic_payload, sizeof(synthetic_payload),
                  &done, nullptr) && done == sizeof(synthetic_payload));
  assert(SetEndOfFile(file));
  assert(FlushFileBuffers(file));
}
uint64_t Observe(HANDLE file, const std::array<uint32_t, 5>& index) {
  return ObserveSiglusMessageResource(file,
      reinterpret_cast<const uint8_t*>(index.data()), sizeof(index), 28,
      {index[1], index[2], index[3], index[4]}, 10100000u + index[3]);
}
}

int main() {
  uint32_t component = 999;
  assert(ReadSiglusArchiveComponent(L"C:\\synthetic\\z0000.ovk", &component));
  assert(component == 0);
  assert(ReadSiglusArchiveComponent(L"z0101.ovk", &component) && component == 101);
  assert(ReadSiglusArchiveComponent(L"z42949.ovk", &component) && component == 42949);
  for (const auto* invalid : {L"z101.ovk", L"z00101.ovk", L"z42950.ovk",
                              L"z0101.ovk.extra", L"z0101.owp", L"z01a1.ovk"})
    assert(!ReadSiglusArchiveComponent(invalid, &component));

  wchar_t temp[MAX_PATH] = {};
  assert(GetTempPathW(MAX_PATH, temp) != 0);
  const std::wstring directory = std::wstring(temp) + L"siglus-member-test-" +
      std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
  assert(CreateDirectoryW(directory.c_str(), nullptr));
  const std::wstring path = directory + L"\\z0101.ovk";
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  const auto index = Index();
  WriteArchive(file, index);
  assert(Observe(file, index) == 0);  // No profile: no resource-key inference.
  mapping_proved = true;
  const uint64_t revision = Observe(file, index);
  assert(revision != 0 && Observe(file, index) == revision);
  QueueSiglusMessageVoice(10, 10100125, 2);
  fushi_voice_hook::siglus::VoiceBinding binding;
  using Status = fushi_voice_hook::siglus::VoiceBindingStatus;
  assert(g_siglus_voice_bindings.GetBinding(10, &binding) == Status::kReady);
  SiglusVoiceTask task;
  task.text_event_id = 10;
  task.voice_key = 10100125;
  task.offset = 20;
  task.archive_revision = revision;
  wcsncpy_s(task.path, binding.resource.source_path.c_str(), _TRUNCATE);
  assert(ValidateSiglusMessageVoiceTask(task, revision, {8, 20, 125, 166452}));
  assert(!ValidateSiglusMessageVoiceTask(task, revision, {8, 20, 126, 166452}));
  assert(!ValidateSiglusMessageVoiceTask(task, revision + 1, {8, 20, 125, 166452}));
  ProcessSiglusMessageVoiceBindings();
  assert(last_exported_event == 10);
  assert(g_siglus_voice_bindings.GetBinding(10, &binding) == Status::kStaleEvent);
  writer_succeeds = false;
  QueueSiglusMessageVoice(11, 10100125, 50000);
  ProcessSiglusMessageVoiceBindings();
  assert(last_exported_event == 11);
  assert(g_siglus_voice_bindings.GetBinding(11, &binding) == Status::kStaleEvent);
  writer_succeeds = true;

  // A modified file invalidates the frozen archive, including previously ready
  // bindings. Metadata and digest are independent checks, never just path.
  QueueSiglusMessageVoice(12, 10100125, 100000);
  auto changed = Index(126);
  WriteArchive(file, changed);
  assert(Observe(file, changed) == 0);
  task.text_event_id = 12;
  assert(!ValidateSiglusMessageVoiceTask(task, revision, {8, 20, 125, 166452}));
  assert(Observe(file, index) == 0);  // Cannot undo a poisoned session identity.
  ShutdownSiglusMessageVoice();
  assert(Observe(file, changed) != 0);
  // Unresolved history is bounded but does not permanently exhaust the stream.
  for (uint64_t seq = 1; seq != 1000; ++seq)
    QueueSiglusMessageVoice(seq, 10100999, seq);
  assert(g_siglus_voice_bindings.GetBinding(1, &binding) == Status::kStaleEvent);
  QueueSiglusMessageVoice(1000, 10100126, 0);
  ProcessSiglusMessageVoiceBindings();
  assert(last_exported_event == 1000);
  ShutdownSiglusMessageVoice();
  assert(CloseHandle(file));
  assert(DeleteFileW(path.c_str()));
  assert(RemoveDirectoryW(directory.c_str()));
  return 0;
}
