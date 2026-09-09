#undef NDEBUG
#include <windows.h>
#include <bcrypt.h>
#include <array>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "voice_hook_ipc.h"
#include "siglus_ovk.h"
#include "siglus_voice_binding.h"
#include "voice_resource_filename.h"

namespace {
using namespace fushi_voice_hook::siglus;
using Status = VoiceBindingStatus;
struct SiglusVoiceTask {
  uint64_t tick_ms = 0, offset = 0, text_event_id = 0, archive_revision = 0;
  uint32_t voice_key = UINT32_MAX, source_length = 0;
  bool proved_source = false, exported = false;
  wchar_t path[520] = {};
};
fushi_voice_hook::SharedHeader header{};
auto* g_header = &header;
constexpr uint32_t kDiagSiglusVoiceDumped = 0x80000000u;
bool message_installed = true, source_installed = true;
bool IsSiglusMessageTextInstalled() { return message_installed; }
bool IsSiglusMessageVoiceMappingProved() {
  return message_installed && source_installed;
}
auto g_orig_CreateFileW = &::CreateFileW;
auto g_orig_ReadFile = &::ReadFile;
auto g_orig_CloseHandle = &::CloseHandle;

bool ReadExact(HANDLE file, void* buffer, uint32_t bytes) {
  uint32_t done = 0;
  while (done < bytes) {
    DWORD part = 0;
    if (!g_orig_ReadFile(file, static_cast<uint8_t*>(buffer) + done,
                         bytes - done, &part, nullptr) || part == 0) return false;
    done += part;
  }
  return true;
}

// This fixture supplies an already safe basename. Sanitizing arbitrary game
// names is outside this test; the actual filename builder and writer run below.
std::wstring VoiceBaseName(const wchar_t* name, const uint8_t*, uint32_t) {
  assert(std::wstring(name) == L"z0101.ovk_125.ogg");
  return name;
}
enum class OutputFault { kNone, kCreate, kWrite, kShortWrite, kClose };
OutputFault output_fault = OutputFault::kNone;
uint32_t output_attempts = 0;
HANDLE WINAPI OutputCreate(LPCWSTR path, DWORD access, DWORD share,
    LPSECURITY_ATTRIBUTES security, DWORD disposition, DWORD flags,
    HANDLE template_file) {
  ++output_attempts;
  if (output_fault == OutputFault::kCreate) {
    SetLastError(ERROR_ACCESS_DENIED);
    return INVALID_HANDLE_VALUE;
  }
  return ::CreateFileW(path, access, share, security, disposition, flags, template_file);
}
BOOL WINAPI OutputWrite(HANDLE file, LPCVOID data, DWORD bytes,
                        LPDWORD written, LPOVERLAPPED overlapped) {
  if (output_fault == OutputFault::kWrite) {
    *written = 0; SetLastError(ERROR_WRITE_FAULT); return FALSE;
  }
  if (output_fault == OutputFault::kShortWrite)
    return ::WriteFile(file, data, bytes - 1, written, overlapped);
  return ::WriteFile(file, data, bytes, written, overlapped);
}
BOOL WINAPI OutputClose(HANDLE file) {
  const BOOL closed = ::CloseHandle(file);
  return output_fault == OutputFault::kClose ? FALSE : closed;
}
// Fault injection is confined to output Win32 calls. WriteVoiceOggAt itself is
// production code; source reads and binding/validation are not mocked.
#define CreateFileW OutputCreate
#define WriteFile OutputWrite
#define CloseHandle OutputClose
#include "voice_resource_writer.inc"
#undef CloseHandle
#undef WriteFile
#undef CreateFileW

void ProcessSiglusVoiceTask(SiglusVoiceTask* task);
#include "adapters/siglus_message_voice.inc"
#include "adapters/siglus_voice_export.inc"

void Put(std::vector<uint8_t>& bytes, size_t offset, uint32_t value) {
  std::memcpy(bytes.data() + offset, &value, sizeof(value));
}
std::vector<uint8_t> Ogg() {
  // A complete synthetic BOS+EOS page; this is not a decodable voice fixture.
  std::vector<uint8_t> bytes(31, 0);
  std::memcpy(bytes.data(), "OggS", 4);
  bytes[5] = 6;
  Put(bytes, 14, 77);
  bytes[26] = 1; bytes[27] = 3;
  bytes[28] = 1; bytes[29] = 2; bytes[30] = 3;
  return bytes;
}
void WriteSource(const std::wstring& path, uint32_t sample_count = 48000,
                 bool truncate_payload = false, const FILETIME* restore_time = nullptr) {
  auto payload = Ogg();
  std::vector<uint8_t> bytes(20, 0);
  Put(bytes, 0, 1); Put(bytes, 4, static_cast<uint32_t>(payload.size()));
  Put(bytes, 8, 20); Put(bytes, 12, 125); Put(bytes, 16, sample_count);
  if (!truncate_payload) bytes.insert(bytes.end(), payload.begin(), payload.end());
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
      nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  DWORD written = 0;
  assert(::WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()),
                     &written, nullptr) && written == bytes.size());
  assert(SetEndOfFile(file));
  assert(FlushFileBuffers(file));
  if (restore_time != nullptr) assert(SetFileTime(file, nullptr, nullptr, restore_time));
  assert(::CloseHandle(file));
}
BY_HANDLE_FILE_INFORMATION Identity(const std::wstring& path) {
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  BY_HANDLE_FILE_INFORMATION identity{};
  assert(GetFileInformationByHandle(file, &identity));
  assert(::CloseHandle(file));
  return identity;
}
void Reset() {
  ShutdownSiglusMessageVoice();
  header.reserved_luna = header.hook_diagnostics = 0;
  output_attempts = 0;
  output_fault = OutputFault::kNone;
  message_installed = source_installed = true;
}
bool Captured() {
  return (header.reserved_luna & kDiagSiglusVoiceDumped) != 0 ||
      (header.hook_diagnostics & fushi_voice_hook::kDiagVisualArtsOvkCaptured) != 0;
}
std::wstring ExportPath(const std::wstring& root, uint64_t tick, uint64_t seq) {
  // Literal expected shape deliberately does not call the production builder.
  return root + L"\\fushi_gal_voice\\" + std::to_wstring(tick) +
      L"_fushi_textseq" + std::to_wstring(seq) + L"_z0101.ovk_125.ogg";
}
void CheckAndRemoveOutput(const std::wstring& path) {
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  auto expected = Ogg();
  std::vector<uint8_t> actual(expected.size());
  assert(ReadExact(file, actual.data(), static_cast<uint32_t>(actual.size())));
  LARGE_INTEGER size{}; assert(GetFileSizeEx(file, &size));
  assert(size.QuadPart == static_cast<LONGLONG>(expected.size()) && actual == expected);
  assert(::CloseHandle(file));
  assert(DeleteFileW(path.c_str()));
}

void TestRejectionAndArrival(const std::wstring& source, const std::wstring& root) {
  for (int invalid = 0; invalid < 6; ++invalid) {
    Reset();
    QueueSiglusMessageVoice(1, 10100125, 5000);
    SiglusVoiceTask task;
    task.voice_key = 10100125; task.offset = 20;
    task.source_length = static_cast<uint32_t>(Ogg().size());
    task.proved_source = true;
    wcsncpy_s(task.path, source.c_str(), _TRUNCATE);
    if (invalid == 0) source_installed = false;
    if (invalid == 1) task.proved_source = false;
    if (invalid == 2) task.voice_key = 10200125;
    if (invalid == 3) task.voice_key = 10100126;
    if (invalid == 4) --task.source_length;
    if (invalid == 5) ++task.offset;
    ProcessSiglusVoiceTask(&task);
    ProcessSiglusMessageVoiceBindings();
    assert(!task.exported && !Captured() && output_attempts == 0);
  }
  for (int text_first = 0; text_first < 2; ++text_first) {
    Reset();
    if (text_first) QueueSiglusMessageVoice(7, 10100125, 5000);
    QueueProvedSiglusVoiceResource(10100125, source.c_str(), 20,
                                   static_cast<uint32_t>(Ogg().size()));
    assert(!Captured() && output_attempts == 0);  // Raw source never exports.
    if (!text_first) QueueSiglusMessageVoice(7, 10100125, 5000);
    ProcessSiglusMessageVoiceBindings();
    assert(Captured() && output_attempts == 1);
    assert((header.reserved_luna & kDiagSiglusVoiceDumped) != 0);
    assert((header.hook_diagnostics & fushi_voice_hook::kDiagVisualArtsOvkCaptured) != 0);
    CheckAndRemoveOutput(ExportPath(root, 5000, 7));
    VoiceBinding binding;
    assert(g_siglus_voice_bindings.GetBinding(7, &binding) == Status::kStaleEvent);
    // Same already captured source can serve another true text occurrence.
    QueueSiglusMessageVoice(9, 10100125, 8000);
    ProcessSiglusMessageVoiceBindings();
    CheckAndRemoveOutput(ExportPath(root, 8000, 9));
    assert(output_attempts == 2);
    QueueSiglusMessageVoice(10, UINT32_MAX, 9000);
    ProcessSiglusMessageVoiceBindings();
    assert(output_attempts == 2);  // No-voice cannot borrow the cached member.
  }
}

void TestOutputFailure(const std::wstring& source, const std::wstring& root) {
  for (const auto fault : {OutputFault::kCreate, OutputFault::kWrite,
                          OutputFault::kShortWrite, OutputFault::kClose}) {
    Reset();
    QueueProvedSiglusVoiceResource(10100125, source.c_str(), 20,
                                   static_cast<uint32_t>(Ogg().size()));
    QueueSiglusMessageVoice(7, 10100125, 5000);
    output_fault = fault;
    ProcessSiglusMessageVoiceBindings();
    assert(!Captured() && output_attempts == 1);
    assert(GetFileAttributesW(ExportPath(root, 5000, 7).c_str()) == INVALID_FILE_ATTRIBUTES);
    VoiceBinding binding;
    assert(g_siglus_voice_bindings.GetBinding(7, &binding) == Status::kStaleEvent);
    output_fault = OutputFault::kNone;
    ProcessSiglusMessageVoiceBindings();
    assert(output_attempts == 1 && !Captured());  // No retry/legacy fallback.
    QueueSiglusMessageVoice(8, 10100125, 6000);
    ProcessSiglusMessageVoiceBindings();
    assert(Captured() && output_attempts == 2);
    CheckAndRemoveOutput(ExportPath(root, 6000, 8));
  }
}

void TestSourceFailureAndDigest(const std::wstring& source) {
  Reset();
  QueueProvedSiglusVoiceResource(10100125, source.c_str(), 20,
                                 static_cast<uint32_t>(Ogg().size()));
  QueueSiglusMessageVoice(6, 10100125, 4000);
  HANDLE locked = ::CreateFileW(source.c_str(), GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(locked != INVALID_HANDLE_VALUE);
  OVERLAPPED lock_range{};
  assert(LockFileEx(locked, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                    0, 4, 0, &lock_range));
  // A real byte-range lock makes the separate worker handle's ReadFile fail.
  // No source-read stub or delay is used to manufacture the failure.
  ProcessSiglusMessageVoiceBindings();
  assert(!Captured() && output_attempts == 0);
  VoiceBinding binding;
  assert(g_siglus_voice_bindings.GetBinding(6, &binding) == Status::kStaleEvent);
  assert(UnlockFileEx(locked, 0, 4, 0, &lock_range));
  assert(::CloseHandle(locked));
  Reset();
  QueueProvedSiglusVoiceResource(10100125, source.c_str(), 20,
                                 static_cast<uint32_t>(Ogg().size()));
  QueueSiglusMessageVoice(7, 10100125, 5000);
  WriteSource(source, 48000, true);  // Real truncated source, not mocked ReadFile.
  ProcessSiglusMessageVoiceBindings();
  assert(!Captured() && output_attempts == 0);
  assert(g_siglus_voice_bindings.GetBinding(7, &binding) == Status::kStaleEvent);
  WriteSource(source);
  Reset();
  QueueProvedSiglusVoiceResource(10100125, source.c_str(), 20,
                                 static_cast<uint32_t>(Ogg().size()));
  const auto before = Identity(source);
  QueueSiglusMessageVoice(7, 10100125, 5000);
  // Change only the index sample count, keep same length/file ID and restore
  // last-write time. Digest must independently reject this source revision.
  WriteSource(source, 48001, false, &before.ftLastWriteTime);
  const auto after = Identity(source);
  assert(SameSiglusArchiveFile(before, after));
  ProcessSiglusMessageVoiceBindings();
  assert(!Captured() && output_attempts == 0 && g_siglus_frozen_archives[0].invalid);
  assert(g_siglus_voice_bindings.GetBinding(7, &binding) == Status::kStaleEvent);
  WriteSource(source, 48000, false, &before.ftLastWriteTime);
  QueueSiglusMessageVoice(8, 10100125, 6000);
  ProcessSiglusMessageVoiceBindings();
  assert(!Captured() && output_attempts == 0);  // Poison survives restored bytes.
}
}  // namespace

int main() {
  wchar_t temp[MAX_PATH]{};
  assert(GetTempPathW(MAX_PATH, temp));
  const std::wstring root = std::wstring(temp) + L"siglus-export-test-" +
      std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
  assert(CreateDirectoryW(root.c_str(), nullptr));
  wchar_t original_tmp[32768]{};
  const DWORD tmp_chars = GetEnvironmentVariableW(L"TMP", original_tmp, 32768);
  assert(tmp_chars < 32768);
  // Process-local output isolation; the production writer still uses the real
  // GetTempPathW/CreateDirectoryW and never touches another session's exports.
  assert(SetEnvironmentVariableW(L"TMP", root.c_str()));
  wchar_t isolated[MAX_PATH]{};
  assert(GetTempPathW(MAX_PATH, isolated));
  assert(std::wstring(isolated) == root + L"\\");
  const std::wstring source = root + L"\\z0101.ovk";
  WriteSource(source);
  TestRejectionAndArrival(source, root);
  TestOutputFailure(source, root);
  TestSourceFailureAndDigest(source);
  ShutdownSiglusMessageVoice();
  assert(DeleteFileW(source.c_str()));
  assert(RemoveDirectoryW((root + L"\\fushi_gal_voice").c_str()));
  assert(RemoveDirectoryW(root.c_str()));
  assert(SetEnvironmentVariableW(L"TMP", tmp_chars == 0 ? nullptr : original_tmp));
  std::puts("siglus_voice_export_test: PASS");
}
