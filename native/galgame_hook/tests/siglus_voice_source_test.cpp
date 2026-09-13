#undef NDEBUG
#include <windows.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include "siglus_voice_source.h"
#include "siglus_message_profile.h"
#include "siglus_resource_mapping.h"
#include "siglus_native_resource.h"
#include "siglus_native_message_profile.h"
#include "siglus_legacy_message_profile.h"
#include "siglus_legacy_resource.h"
#include "siglus_legacy_live_admission.h"
#include "siglus_image.h"

namespace {
using namespace fushi_voice_hook;
int checks = 0;
void Check(bool value) { ++checks; assert(value); }
struct Memory {
  std::map<uint32_t, uint8_t> bytes;
  bool operator()(uint32_t address, void* out, size_t length) {
    auto* destination = static_cast<uint8_t*>(out);
    for (size_t i = 0; i < length; ++i) {
      const auto found = bytes.find(address + static_cast<uint32_t>(i));
      if (found == bytes.end()) return false;
      destination[i] = found->second;
    }
    return true;
  }
  void Put(uint32_t address, const void* value, size_t length) {
    const auto* source = static_cast<const uint8_t*>(value);
    for (size_t i = 0; i < length; ++i)
      bytes[address + static_cast<uint32_t>(i)] = source[i];
  }
  void Word(uint32_t address, uint32_t value) { Put(address, &value, 4); }
};
SiglusVoiceSourceLayout Layout() {
  return {0x8000, 0x7000, 8, -0x128, -0xb8, -0x30, 4, 8, 12};
}
struct Fixture {
  Memory memory;
  SiglusVoiceSourceCall call{0x3000, 0x1800, 0x2000, 0x100, 0x40};
  Fixture() {
    memory.Word(0x1800, 0x8000);
    memory.Word(0x1804, 0x1f48);
    memory.Word(0x1808, 0x100);
    memory.Word(0x180c, 0x40);
    memory.Word(0x2008, 123456);
    memory.Word(0x1ed8, 123456);
    memory.Word(0x1fd0, 0x3000);
    memory.Word(0x3000, 0x7000);
    SetPath(L"C:\\x.ovk");
  }
  void SetPath(const wchar_t* path) {
    const uint32_t units = static_cast<uint32_t>(std::wcslen(path));
    const uint32_t empty[6] = {};
    memory.Put(0x1f48, empty, sizeof(empty));
    if (units >= 8) memory.Word(0x1f48, 0x4000);
    memory.Put(units < 8 ? 0x1f48 : 0x4000, path, (units + 1) * sizeof(wchar_t));
    memory.Word(0x1f58, units);
    memory.Word(0x1f5c, units < 8 ? 7 : units);
  }
};
void TestPureSource() {
  Fixture fixture;
  SiglusVoiceSourceTask result;
  Check(CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  Check(result.key == 123456 && result.offset == 0x100 && result.length == 0x40);
  Check(std::wcscmp(result.path, L"C:\\x.ovk") == 0);
  const uint32_t changed_words[] = {0x1800, 0x1804, 0x1808, 0x180c,
      0x2008, 0x1ed8, 0x1fd0, 0x3000};
  for (auto address : changed_words) {
    Fixture changed;
    uint32_t word = 0;
    Check(changed.memory(address, &word, 4));
    changed.memory.Word(address, word + 1);
    result.key = 99;
    Check(!CaptureSiglusVoiceSource(Layout(), changed.call, changed.memory, &result));
    Check(result.key == 99);
  }
  fixture.call.original_esi = 0;
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  fixture = Fixture(); fixture.call.original_ebx = 0;
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  fixture = Fixture(); fixture.call.caller_ebp = UINT32_MAX;
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  fixture = Fixture(); fixture.memory.Word(0x2008, UINT32_MAX);
  fixture.memory.Word(0x1ed8, UINT32_MAX);
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  fixture = Fixture(); fixture.call.original_esi = UINT32_MAX - 10;
  fixture.memory.Word(0x1808, fixture.call.original_esi);
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  fixture = Fixture(); fixture.memory.Word(0x1f58, 520);
  fixture.memory.Word(0x1f5c, 520);
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  fixture = Fixture(); fixture.memory.Word(0x1f5c, 4);
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  fixture = Fixture(); fixture.memory.Word(0x1f58, 0);
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  fixture = Fixture(); fixture.memory.bytes.erase(0x1f48);
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  fixture = Fixture(); fixture.memory.bytes[0x4000 + 8 * 2] = 'X';
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  fixture = Fixture(); fixture.memory.bytes[0x4000] = 0;
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  fixture = Fixture();
  wchar_t longest[520];
  for (int i = 0; i < 519; ++i) longest[i] = L'x';
  longest[0] = L'C'; longest[1] = L':'; longest[2] = L'\\';
  longest[519] = 0;
  fixture.memory.Word(0x1f48, 0x4000);
  fixture.memory.Word(0x1f58, 519); fixture.memory.Word(0x1f5c, 519);
  fixture.memory.Put(0x4000, longest, sizeof(longest));
  Check(CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
  Check(result.path[518] == L'x' && result.path[519] == 0);
  fixture.memory.bytes.erase(0x4000 + 400);
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
}

void TestStablePaths() {
  const wchar_t* rejected[] = {
    L"x.ovk", L".\\x.ovk", L"..\\x.ovk", L"C:x.ovk", L"C:",
    L"\\x.ovk", L"/x.ovk", L"1:\\x.ovk", L"C:\\", L"C:/",
    L"\\\\server", L"\\\\server\\", L"\\\\server\\share",
    L"\\\\server\\share\\", L"\\\\\\share\\x.ovk",
    L"\\\\server\\\\x.ovk", L"\\\\.\\share\\x.ovk",
    L"\\\\?\\C:\\x.ovk", L"\\\\server\\..\\x.ovk",
    L"\\\\server\\share\\\\x.ovk", L"//server/share/x.ovk"
  };
  for (const wchar_t* path : rejected) {
    Fixture fixture; fixture.SetPath(path);
    SiglusVoiceSourceTask result; result.key = 99;
    Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
    Check(result.key == 99);
  }
  const wchar_t* accepted[] = {L"C:\\x", L"z:/dir/x.ovk",
    L"C:\\dir name\\x.ovk", L"\\\\server\\share\\x.ovk",
    L"\\\\server\\share\\dir\\x.ovk", L"\\\\server\\share name\\x.ovk"};
  for (const wchar_t* path : accepted) {
    Fixture fixture; fixture.SetPath(path);
    SiglusVoiceSourceTask result;
    Check(CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &result));
    Check(std::wcscmp(result.path, path) == 0);
  }
}

void TestCwdChange() {
  // Real same-named synthetic files establish why a deferred relative open is
  // wrong; no game archive or resource payload is used by this regression.
  wchar_t previous[32768] = {}, temp[MAX_PATH] = {}, root[MAX_PATH] = {};
  const DWORD previous_units = GetCurrentDirectoryW(32768, previous);
  Check(previous_units > 0 && previous_units < 32768);
  Check(GetTempPathW(MAX_PATH, temp) > 0);
  Check(GetTempFileNameW(temp, L"sgv", 0, root) != 0);
  Check(DeleteFileW(root) != 0 && CreateDirectoryW(root, nullptr) != 0);
  const std::wstring a = std::wstring(root) + L"\\A";
  const std::wstring b = std::wstring(root) + L"\\B";
  Check(CreateDirectoryW(a.c_str(), nullptr) != 0);
  Check(CreateDirectoryW(b.c_str(), nullptr) != 0);
  const std::wstring a_file = a + L"\\voice.ovk", b_file = b + L"\\voice.ovk";
  const auto write_marker = [](const wchar_t* path, char value) {
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_NEW, 0, nullptr);
    Check(file != INVALID_HANDLE_VALUE);
    DWORD written = 0;
    Check(WriteFile(file, &value, 1, &written, nullptr) != 0 && written == 1);
    Check(CloseHandle(file) != 0);
  };
  const auto read_marker = [](const wchar_t* path) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, 0, nullptr);
    Check(file != INVALID_HANDLE_VALUE);
    char value = 0; DWORD count = 0;
    Check(ReadFile(file, &value, 1, &count, nullptr) != 0 && count == 1);
    Check(CloseHandle(file) != 0);
    return value;
  };
  write_marker(a_file.c_str(), 'A'); write_marker(b_file.c_str(), 'B');
  Check(SetCurrentDirectoryW(a.c_str()) != 0);
  Fixture fixture; fixture.SetPath(L"voice.ovk");
  SiglusVoiceSourceTask task;
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &task));
  Check(read_marker(L"voice.ovk") == 'A');
  fixture.SetPath(a_file.c_str());
  Check(CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &task));
  SiglusMessageQueue<SiglusVoiceSourceTask, 2> queue;
  Check(queue.TryPush(task));
  Check(SetCurrentDirectoryW(b.c_str()) != 0);
  Check(read_marker(L"voice.ovk") == 'B');
  Check(queue.TryPop(&task));
  Check(read_marker(task.path) == 'A');
  fixture.SetPath(L"voice.ovk");
  Check(!CaptureSiglusVoiceSource(Layout(), fixture.call, fixture.memory, &task));
  Check(SetCurrentDirectoryW(previous) != 0);
  Check(DeleteFileW(a_file.c_str()) != 0 && DeleteFileW(b_file.c_str()) != 0);
  Check(RemoveDirectoryW(a.c_str()) != 0 && RemoveDirectoryW(b.c_str()) != 0);
  Check(RemoveDirectoryW(root) != 0);
}

#if defined(_M_IX86)
bool g_capture_enabled = true, g_cs_ready = true;
CRITICAL_SECTION g_cs;
SiglusMessageProfile g_siglus_message_profile;
bool g_siglus_message_native_ecx = false;
bool g_siglus_message_legacy = false;
SiglusLegacyMessageProfile g_siglus_legacy_message_profile;
SiglusNativeMessageProfile g_siglus_native_message_profile;
bool message_installed = true;
bool IsSiglusMessageTextInstalled() { return message_installed; }
const SiglusLookupProfile* ActiveSiglusLookupProfile() { return nullptr; }
enum MH_STATUS { MH_OK, MH_ERROR_DISABLED, MH_ERROR_ENABLED, MH_ERROR_NOT_CREATED };
MH_STATUS create_status = MH_OK, enable_status = MH_OK, disable_status = MH_OK;
bool null_original = false;
int removed = 0;
MH_STATUS MH_CreateHook(void*, void*, void** original) {
  if (create_status == MH_OK && !null_original)
    *original = reinterpret_cast<void*>(0x1234);
  return create_status;
}
MH_STATUS MH_EnableHook(void*) { return enable_status; }
MH_STATUS MH_DisableHook(void*) { return disable_status; }
MH_STATUS MH_RemoveHook(void*) { ++removed; return MH_OK; }
int published = 0;
SiglusVoiceSourceTask published_task;
void QueueProvedSiglusVoiceResource(uint32_t key, const wchar_t* path,
                                    uint32_t offset, uint32_t length) {
  ++published;
  published_task.key = key; published_task.offset = offset;
  published_task.length = length;
  wcscpy_s(published_task.path, kSiglusVoiceSourcePathUnits, path);
}
#endif

#include "siglus_voice_source.inc"

#if defined(_M_IX86)
uint32_t fake_frame = 0, fake_reader = 0, fake_path = 0;
uint32_t fake_offset = 0x100, fake_length = 0x40;
uint32_t fake_esi = 0x100, fake_ebx = 0x40;
uint32_t expected_return = 0, original_flags = 0;
uint32_t before_esp = 0, after_esp = 0, original_esi = 0, original_ebx = 0;
uint32_t original_ecx = 0, original_ebp = 0;
uint32_t original_edi = 0, legacy_key_copy = 100000321;
__declspec(naked) void OriginalSource() {
  __asm {
    mov original_ecx, ecx
    mov original_ebp, ebp
    mov original_edi, edi
    mov original_esi, esi
    mov original_ebx, ebx
    pushfd
    pop original_flags
    ret 12
  }
}
__declspec(naked) void InvokeSource() {
  __asm {
    pushfd
    pushad
    mov before_esp, esp
    push fake_length
    push fake_offset
    push fake_path
    mov ecx, fake_reader
    mov ebp, fake_frame
    mov esi, fake_esi
    mov ebx, fake_ebx
    mov eax, offset returned
    mov expected_return, eax
    // The production caller gate is a runtime-relocated return address.
    mov g_siglus_voice_source_layout.payload_return, eax
    mov g_siglus_native_source_layout.payload_return, eax
    std
    stc
    call Detour_SiglusVoiceSource
  returned:
    cld
    mov after_esp, esp
    popad
    popfd
    ret
  }
}
void TestProductionNakedSource() {
  g_siglus_voice_source_native_ecx = false;
  uint32_t frame[128] = {};
  uint32_t reader[4] = {};
  fake_frame = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(&frame[100]));
  fake_reader = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(reader));
  fake_path = fake_frame - 0xb8;
  reader[0] = 0x7000;
  frame[102] = frame[26] = 123456;
  frame[88] = fake_reader;
  auto* text = reinterpret_cast<wchar_t*>(&frame[54]);
  wcscpy_s(text, 8, L"C:\\x");
  frame[58] = 4; frame[59] = 7;
  g_siglus_voice_source_layout = Layout();
  g_orig_SiglusVoiceSource = reinterpret_cast<void*>(&OriginalSource);
  g_siglus_voice_source_enabled.store(true);
  SiglusVoiceSourceTask task;
  SetLastError(42);
  InvokeSource();
  const DWORD last_error = GetLastError();
  Check(g_siglus_voice_source_tasks.TryPop(&task));
  Check(task.key == 123456 && task.offset == 0x100 && task.length == 0x40);
  Check(std::wcscmp(task.path, L"C:\\x") == 0);
  Check(original_ecx == fake_reader && original_ebp == fake_frame);
  Check(original_esi == fake_esi && original_ebx == fake_ebx);
  Check(before_esp == after_esp && (original_flags & 0x401) == 0x401);
  Check(last_error == 42);
  fake_esi = 0x101; InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task));
  fake_esi = 0x100; fake_ebx = 0x41; InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task));
  fake_ebx = 0x40; frame[26] = 1; InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task));
  frame[26] = 123456; frame[88] = 0; InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task));
  frame[88] = fake_reader; ++fake_path; InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task));
  --fake_path; reader[0] = 0; InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task));
  reader[0] = 0x7000;
  frame[58] = 10; frame[59] = 15; frame[54] = 1; InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task)); // SEH contains bad heap path
  wcscpy_s(text, 8, L"x.ovk"); frame[58] = 5; frame[59] = 7;
  InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task));
  wcscpy_s(text, 8, L"C:\\x"); frame[58] = 4; frame[59] = 7;
  for (uint32_t i = 0; i < kSiglusVoiceSourceTaskSlots; ++i) InvokeSource();
  InvokeSource();
  uint32_t count = 0;
  while (g_siglus_voice_source_tasks.TryPop(&task)) ++count;
  Check(count == kSiglusVoiceSourceTaskSlots);
  InvokeSource(); ProcessSiglusVoiceSourceTasks();
  Check(published == 1 && published_task.key == 123456);
  g_siglus_voice_source_enabled.store(false); InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task));
  Check(g_siglus_voice_source_tasks.TryPush(published_task));
  ProcessSiglusVoiceSourceTasks(); Check(published == 1);
  while (g_siglus_voice_source_tasks.TryPop(&task)) {}
}

void TestProductionNativeSource(SiglusNativeResourceFrame resource_frame) {
  alignas(8) uint32_t frame[128] = {};
  uint32_t reader[4] = {0x7000};
  fake_frame = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(&frame[100]));
  fake_reader = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(reader));
  fake_ebx = fake_frame + 8;
  fake_esi = 0xdeadbeef; // NativeEcx never interprets ESI as an offset.
  fake_path = fake_frame - 0xc8;
  fake_offset = 0x100; fake_length = 0x40;
  frame[96] = fake_ebx;
  const bool compact = resource_frame == SiglusNativeResourceFrame::kStack118;
  const uint32_t key_copy_word = compact ? 35u : 36u;
  const uint32_t reader_word = compact ? 30u : 29u;
  const uint32_t offset_word = compact ? 79u : 67u;
  const uint32_t length_word = compact ? 61u : 34u;
  frame[104] = frame[key_copy_word] = 100100297;
  frame[reader_word] = fake_reader;
  frame[offset_word] = fake_offset; frame[length_word] = fake_length;
  auto* text = reinterpret_cast<wchar_t*>(&frame[50]);
  wcscpy_s(text, 8, L"D:\\x"); frame[54] = 4; frame[55] = 7;
  g_siglus_voice_source_native_ecx = true;
  g_siglus_native_source_layout = {0, 0x7000, resource_frame};
  g_orig_SiglusVoiceSource = reinterpret_cast<void*>(&OriginalSource);
  g_siglus_voice_source_enabled.store(true);
  SiglusVoiceSourceTask task;
  auto& observations = g_siglus_voice_source_observations;
  const uint32_t entered_before = observations.entered.load();
  const uint32_t enabled_before = observations.enabled.load();
  const uint32_t admitted_before = observations.admitted_caller.load();
  const uint32_t captured_before = observations.captured.load();
  const uint32_t queued_before = observations.queued.load();
  SetLastError(43); InvokeSource();
  const DWORD last_error = GetLastError();
  Check(observations.entered.load() == entered_before + 1);
  Check(observations.enabled.load() == enabled_before + 1);
  Check(observations.admitted_caller.load() == admitted_before + 1);
  Check(observations.captured.load() == captured_before + 1);
  Check(observations.queued.load() == queued_before + 1);
  Check(observations.last_return.load() ==
        g_siglus_native_source_layout.payload_return);
  Check(g_siglus_voice_source_tasks.TryPop(&task));
  Check(task.key == 100100297 && task.offset == 0x100 && task.length == 0x40);
  Check(std::wcscmp(task.path, L"D:\\x") == 0);
  Check(original_ecx == fake_reader && original_ebp == fake_frame);
  Check(original_esi == fake_esi && original_ebx == fake_ebx);
  Check(before_esp == after_esp && (original_flags & 0x401) == 0x401);
  Check(last_error == 43);
  const uint32_t checked_words[] = {
      96, 104, key_copy_word, reader_word, offset_word, length_word};
  for (const uint32_t index : checked_words) {
    const uint32_t captured = observations.captured.load();
    ++frame[index]; InvokeSource();
    Check(!g_siglus_voice_source_tasks.TryPop(&task));
    Check(observations.captured.load() == captured);
    --frame[index];
  }
  // A valid call from one compiler frame must not enter through the other's
  // admitted layout, even though its reader ABI and original stack are equal.
  g_siglus_native_source_layout.frame = compact
      ? SiglusNativeResourceFrame::kStack120
      : SiglusNativeResourceFrame::kStack118;
  InvokeSource(); Check(!g_siglus_voice_source_tasks.TryPop(&task));
  g_siglus_native_source_layout.frame = static_cast<SiglusNativeResourceFrame>(255);
  InvokeSource(); Check(!g_siglus_voice_source_tasks.TryPop(&task));
  g_siglus_native_source_layout.frame = resource_frame;
  ++fake_ebx; InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task)); --fake_ebx;
  reader[0] = 0; InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task)); reader[0] = 0x7000;
  frame[50] = 1; frame[54] = 10; frame[55] = 15; InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task)); // actual invalid heap pointer
  wcscpy_s(text, 8, L"x.ovk"); frame[54] = 5; frame[55] = 7; InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task));
  wcscpy_s(text, 8, L"D:\\x"); frame[54] = 4; frame[55] = 7;
  const int before = published;
  const uint32_t processed = observations.processed.load();
  InvokeSource(); ProcessSiglusVoiceSourceTasks();
  Check(published == before + 1 && published_task.key == 100100297);
  Check(observations.processed.load() == processed + 1);
  g_capture_enabled = false; InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task)); g_capture_enabled = true;
  const uint32_t enabled = observations.enabled.load();
  g_siglus_voice_source_enabled.store(false); InvokeSource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task));
  Check(observations.enabled.load() == enabled);
  g_siglus_voice_source_native_ecx = false;
}

void TestInstallation() {
  InitializeCriticalSection(&g_cs);
  const auto reset = [] {
    create_status = enable_status = disable_status = MH_OK;
    null_original = false; removed = 0;
    g_siglus_voice_source_state.store(0);
    g_siglus_voice_source_enabled.store(false);
    g_siglus_voice_source_created = g_siglus_voice_source_ever_enabled = false;
    g_orig_SiglusVoiceSource = nullptr;
    g_siglus_voice_source_target = reinterpret_cast<void*>(0x5000);
  };
  reset(); Check(!TryHookSiglusVoiceSource()); // absent admitted lane
  reset(); create_status = MH_ERROR_NOT_CREATED;
  Check(!InstallSiglusVoiceSourceHook() && removed == 0);
  Check(!IsSiglusVoiceSourceInstalled() && message_installed);
  reset(); null_original = true;
  Check(!InstallSiglusVoiceSourceHook() && removed == 1);
  reset(); enable_status = MH_ERROR_NOT_CREATED;
  Check(!InstallSiglusVoiceSourceHook() && removed == 1);
  reset(); enable_status = MH_ERROR_ENABLED; disable_status = MH_ERROR_NOT_CREATED;
  Check(!InstallSiglusVoiceSourceHook());
  Check(!IsSiglusVoiceSourceInstalled() && !g_siglus_voice_source_enabled.load());
  Check(message_installed && removed == 0 && g_orig_SiglusVoiceSource != nullptr);
  reset(); Check(InstallSiglusVoiceSourceHook());
  Check(IsSiglusVoiceSourceInstalled());
  disable_status = MH_ERROR_NOT_CREATED;
  ShutdownSiglusVoiceSource();
  Check(!IsSiglusVoiceSourceInstalled() && !g_siglus_voice_source_enabled.load());
  Check(message_installed && removed == 0);
  disable_status = MH_OK; ShutdownSiglusVoiceSource();
  Check(removed == 0 && g_orig_SiglusVoiceSource != nullptr);
  DeleteCriticalSection(&g_cs);
}

// Reproduce the independently proved FPO call scope on the real test stack.
// The production thunk must preserve EBP as a length, and recover saved EDI.
__declspec(naked) void InvokeLegacySource() {
  __asm {
    pushfd
    pushad
    mov before_esp, esp
    sub esp, 140h
    lea eax, [esp-10h]
    mov dword ptr [eax+130h], 7001h
    mov dword ptr [eax+134h], 100000321
    mov edx, legacy_key_copy
    mov [eax+20h], edx
    mov dword ptr [eax+48h], 321
    mov ecx, fake_reader
    mov [eax+40h], ecx
    mov dword ptr [eax+0c8h], 0
    mov dword ptr [eax+0cch], 003a0043h
    mov dword ptr [eax+0d0h], 0078005ch
    mov dword ptr [eax+0d4h], 0
    mov dword ptr [eax+0d8h], 0
    mov dword ptr [eax+0dch], 4
    mov dword ptr [eax+0e0h], 7
    lea edx, [eax+0c8h]
    push 40h
    push 100h
    push edx
    mov edi, 100h
    mov ebp, 40h
    mov esi, 0deadbeefh
    mov ebx, 0cafebabeh
    mov eax, offset returned
    mov g_siglus_legacy_source_layout.payload_return, eax
    std
    stc
    call Detour_SiglusVoiceSource
  returned:
    cld
    add esp, 140h
    mov after_esp, esp
    popad
    popfd
    ret
  }
}

void TestProductionLegacySource() {
  uint32_t reader[4] = {0x7000};
  fake_reader = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(reader));
  g_siglus_voice_source_legacy = true;
  g_siglus_voice_source_native_ecx = false;
  g_siglus_legacy_source_layout = {0, 0x7001, 0x7000};
  g_orig_SiglusVoiceSource = reinterpret_cast<void*>(&OriginalSource);
  g_siglus_voice_source_enabled.store(true);
  SiglusVoiceSourceTask task;
  while (g_siglus_voice_source_tasks.TryPop(&task)) {}
  SetLastError(44); InvokeLegacySource();
  const DWORD last_error = GetLastError();
  Check(g_siglus_voice_source_tasks.TryPop(&task));
  Check(task.key == 100000321 && task.offset == 0x100 && task.length == 0x40);
  Check(std::wcscmp(task.path, L"C:\\x") == 0);
  Check(original_ecx == fake_reader && original_edi == 0x100 && original_ebp == 0x40);
  Check(original_esi == 0xdeadbeef && original_ebx == 0xcafebabe);
  Check(before_esp == after_esp && (original_flags & 0x401) == 0x401);
  Check(last_error == 44);
  ++legacy_key_copy; InvokeLegacySource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task)); --legacy_key_copy;
  reader[0] = 0; InvokeLegacySource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task)); reader[0] = 0x7000;
  const int before = published;
  InvokeLegacySource(); ProcessSiglusVoiceSourceTasks();
  Check(published == before + 1 && published_task.key == 100000321);
  g_siglus_voice_source_enabled.store(false); InvokeLegacySource();
  Check(!g_siglus_voice_source_tasks.TryPop(&task));
  g_siglus_voice_source_legacy = false;
}
#endif
}  // namespace

int main() {
  TestPureSource();
  TestStablePaths(); TestCwdChange();
#if defined(_M_IX86)
  TestProductionNakedSource();
  TestProductionNativeSource(SiglusNativeResourceFrame::kStack120);
  TestProductionNativeSource(SiglusNativeResourceFrame::kStack118);
  TestProductionLegacySource();
  TestInstallation();
#else
  Check(!TryHookSiglusVoiceSource()); Check(!IsSiglusVoiceSourceInstalled());
  ProcessSiglusVoiceSourceTasks(); ShutdownSiglusVoiceSource();
#endif
  std::printf("siglus_voice_source_test: PASS (%d checks)\n", checks);
  return 0;
}
