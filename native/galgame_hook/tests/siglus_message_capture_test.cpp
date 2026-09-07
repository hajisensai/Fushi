#undef NDEBUG
#include <windows.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>
#include <thread>
#include <vector>
#include "siglus_message_capture.h"
#include "siglus_message_profile.h"
#include "siglus_native_message_profile.h"
#include "siglus_native_message_capture.h"
#include "siglus_image.h"
// Exercise the production clock write deterministically, without sleeping or
// substituting a second implementation of TextLaneEvent publication.
ULONGLONG SiglusTestCommitClock() { return 5000; }
#define GetTickCount64 SiglusTestCommitClock
#include "voice_hook_ipc.h"
#undef GetTickCount64

namespace {
using namespace fushi_voice_hook;
int checks = 0;
void Check(bool value) { ++checks; assert(value); }

struct TextMapping {
  std::vector<uint8_t> bytes;
  TextMapping() : bytes(static_cast<size_t>(sizeof(SharedHeader) +
      TextRegionBytes(kTextLaneCount, kTextLaneSlotCount)), 0) {
    auto* h = header();
    h->magic = kSharedMagic;
    h->version = kSharedVersion;
    h->text_region_offset = static_cast<uint32_t>(sizeof(SharedHeader));
    h->text_lane_count = kTextLaneCount;
    h->text_lane_slot_count = kTextLaneSlotCount;
  }
  SharedHeader* header() { return reinterpret_cast<SharedHeader*>(bytes.data()); }
};

void TestCommittedTextLaneTimestamp() {
  TextMapping mapping;
  TextLaneWrite write;
  write.thread_id = 42;
  write.text = L"X";
  write.byte_len = sizeof(wchar_t);
  uint64_t tick = UINT64_MAX;
  const uint64_t seq = WriteTextLaneEvent(mapping.header(), 0, 1, write, &tick);
  Check(seq != 0 && tick == SiglusTestCommitClock());
  const auto* slot = reinterpret_cast<const TextSlot*>(
      TextLaneSlotAt(mapping.header(), 0, 1));
  Check(slot != nullptr && slot->seq == seq && slot->timestamp_ms == tick);
  tick = UINT64_MAX;
  Check(WriteTextLaneEvent(nullptr, 0, 1, write, &tick) == 0 && tick == 0);
  tick = UINT64_MAX;
  Check(WriteTextLaneEvent(mapping.header(), 1, 1, write, &tick) == 0 && tick == 0);
  mapping.header()->text_lane_slot_count = 0;
  tick = UINT64_MAX;
  Check(WriteTextLaneEvent(mapping.header(), 0, 1, write, &tick) == 0 && tick == 0);
}

struct Memory {
  std::map<uint32_t, uint32_t> words;
  bool operator()(uint32_t address, uint32_t* out) {
    const auto found = words.find(address);
    if (found == words.end()) return false;
    *out = found->second;
    return true;
  }
};

SiglusMessageLayout Layout() {
  return {0x1f8, 0x1e0, 0x228, 0x22c, 0x1c0, 0x7001, 0x7002};
}
Memory MemoryFixture() {
  return {{{0x11f8, 42}, {0x11e0, 1}, {0x1228, 0x2000},
           {0x122c, 0x2380}, {0x3000, 0x3ffc}, {0x3004, 0x7001},
           {0x2f00, 0x7002}}};
}

void TestTicket() {
  const auto layout = Layout();
  auto memory = MemoryFixture();
  SiglusMessageTicket ticket{};
  SiglusMessageOwnerSnapshot frozen;
  Check(ArmSiglusMessageTicket(layout, 0x1000, 0x4000, memory, &ticket));
  Check(ticket.snapshot.surface == 0x21c0);
  Check(ConsumeSiglusMessageTicket(layout, 0x21c0, 0x2f00, 0x3000,
                                  memory, &ticket, &frozen));
  Check(frozen.voice_key == 42);
  Check(!ConsumeSiglusMessageTicket(layout, 0x21c0, 0x2f00, 0x3000,
                                   memory, &ticket, &frozen));
  const uint32_t addresses[] = {0x11f8, 0x11e0, 0x1228, 0x122c,
                                0x3000, 0x3004, 0x2f00};
  for (const auto address : addresses) {
    memory = MemoryFixture();
    Check(ArmSiglusMessageTicket(layout, 0x1000, 0x4000, memory, &ticket));
    ++memory.words[address];
    Check(!ConsumeSiglusMessageTicket(layout, 0x21c0, 0x2f00, 0x3000,
                                     memory, &ticket, &frozen));
    --memory.words[address];
    Check(!ConsumeSiglusMessageTicket(layout, 0x21c0, 0x2f00, 0x3000,
                                     memory, &ticket, &frozen));
  }
  memory = MemoryFixture();
  Check(ArmSiglusMessageTicket(layout, 0x1000, 0x4000, memory, &ticket));
  Check(!ConsumeSiglusMessageTicket(layout, 0x21c0, 0x3000, 0x2f00,
                                   memory, &ticket, &frozen));
  Check(ArmSiglusMessageTicket(layout, 0x1000, 0x4000, memory, &ticket));
  Check(!ConsumeSiglusMessageTicket(layout, 0x2000, 0x2f00, 0x3000,
                                   memory, &ticket, &frozen));
  Check(!ticket.armed);
  Check(ArmSiglusMessageTicket(layout, 0x1000, 0x4000, memory, &ticket));
  Check(!ArmSiglusMessageTicket(layout, UINT32_MAX - 4, 0x4000, memory, &ticket));
  Check(!ticket.armed);
  memory.words[0x11e0] = UINT32_MAX;
  Check(!ArmSiglusMessageTicket(layout, 0x1000, 0x4000, memory, &ticket));
  memory = MemoryFixture();
  memory.words[0x122c] = 0x2381;
  Check(!ArmSiglusMessageTicket(layout, 0x1000, 0x4000, memory, &ticket));
  memory = MemoryFixture();
  memory.words[0x11e0] = 2;
  Check(!ArmSiglusMessageTicket(layout, 0x1000, 0x4000, memory, &ticket));
  memory = MemoryFixture();
  memory.words[0x11f8] = UINT32_MAX; // no-voice remains a valid text occurrence
  Check(ArmSiglusMessageTicket(layout, 0x1000, 0x4000, memory, &ticket));
  Check(ConsumeSiglusMessageTicket(layout, 0x21c0, 0x2f00, 0x3000,
                                  memory, &ticket, &frozen));
  Check(frozen.voice_key == UINT32_MAX);
  // A nested outer entry replaces the ticket; the original frame cannot consume it.
  Check(ArmSiglusMessageTicket(layout, 0x1000, 0x4000, memory, &ticket));
  Check(ArmSiglusMessageTicket(layout, 0x1000, 0x5000, memory, &ticket));
  Check(!ConsumeSiglusMessageTicket(layout, 0x21c0, 0x2f00, 0x3000,
                                   memory, &ticket, &frozen));
}

void TestQueue() {
  SiglusMessageQueue<uint32_t, 4> queue;
  uint32_t value = 0;
  Check(!queue.TryPop(&value));
  for (uint32_t i = 1; i <= 4; ++i) Check(queue.TryPush(i));
  Check(!queue.TryPush(5));
  for (uint32_t i = 1; i <= 4; ++i) {
    Check(queue.TryPop(&value)); Check(value == i);
  }
  Check(!queue.TryPop(&value));
  Check(queue.TryPush(6)); Check(queue.TryPop(&value)); Check(value == 6);
  struct Payload { uint32_t id; uint32_t complement; };
  SiglusMessageQueue<Payload, 32> concurrent;
  std::atomic<uint32_t> accepted{0}, done{0};
  std::vector<std::thread> producers;
  for (uint32_t p = 0; p < 4; ++p) {
    producers.emplace_back([&, p] {
      for (uint32_t i = 0; i < 1000; ++i) {
        const uint32_t id = p * 1000 + i;
        if (concurrent.TryPush({id, ~id})) ++accepted;
      }
      ++done;
    });
  }
  bool seen[4000] = {};
  uint32_t consumed = 0;
  do {
    Payload payload{};
    while (concurrent.TryPop(&payload)) {
      Check(payload.id < 4000 && payload.complement == ~payload.id);
      Check(!seen[payload.id]); seen[payload.id] = true; ++consumed;
    }
  } while (done.load() != 4);
  for (auto& producer : producers) producer.join();
  Payload payload{};
  while (concurrent.TryPop(&payload)) {
    Check(payload.id < 4000 && payload.complement == ~payload.id);
    Check(!seen[payload.id]); seen[payload.id] = true; ++consumed;
  }
  Check(consumed == accepted.load());
}

#if defined(_M_IX86)
// Compile and exercise the production include against bounded fake publication
// and hook backends. No game is opened or modified by this executable.
SharedHeader header = {};
SharedHeader* g_header = &header;
bool g_capture_enabled = true;
bool g_text_cs_ready = true;
bool g_cs_ready = true;
bool voice_source_installed = false;
bool IsSiglusVoiceSourceInstalled() { return voice_source_installed; }
CRITICAL_SECTION g_text_cs, g_cs;
constexpr uint32_t kDiagSiglusExactTextObserved = 1;
struct SiglusTextUnionW {
  union { const wchar_t* text; wchar_t chars[8]; } storage;
  uint32_t size;
  uint32_t capacity;
};
const wchar_t* ReadSiglusText(const SiglusTextUnionW* value, uint32_t* length) {
  if (value == nullptr || value->size == 0 || value->size > 1500 ||
      value->capacity < value->size) return nullptr;
  const wchar_t* text = value->capacity < 8 ? value->storage.chars : value->storage.text;
  if (text == nullptr || text[value->size] != 0) return nullptr;
  *length = value->size;
  return text;
}
bool IsSiglusEngine() { return true; }
const SiglusLookupProfile* ActiveSiglusLookupProfile() { return nullptr; }
enum MH_STATUS { MH_OK, MH_ERROR_DISABLED, MH_ERROR_ENABLED,
                 MH_ERROR_NOT_CREATED, MH_ERROR_ALREADY_CREATED };
bool mock_disable_failure = false;
int mock_removed = 0;
int mock_created = 0, mock_enabled = 0;
int mock_null_original = -1;
MH_STATUS mock_create_status[2] = {MH_OK, MH_OK};
MH_STATUS mock_enable_status[2] = {MH_OK, MH_OK};
MH_STATUS MH_CreateHook(void*, void*, void** original) {
  const int index = mock_created++;
  assert(index < 2);
  if (mock_create_status[index] == MH_OK && mock_null_original != index)
    *original = reinterpret_cast<void*>(static_cast<uintptr_t>(0x1000 + index));
  return mock_create_status[index];
}
MH_STATUS MH_EnableHook(void*) {
  const int index = mock_enabled++;
  assert(index < 2);
  return mock_enable_status[index];
}
MH_STATUS MH_DisableHook(void*) {
  return mock_disable_failure ? MH_ERROR_NOT_CREATED : MH_OK;
}
MH_STATUS MH_RemoveHook(void*) { ++mock_removed; return MH_OK; }
uint64_t published_seq = 0, snapshot_seq = 0, queued_voice_seq = 0;
uint64_t queued_voice_tick = 0, last_writer_tick = 0;
bool use_real_lane_writer = false;
int writes = 0;
uint64_t WriteTextRingEntryLocked(const wchar_t* text, int units,
                                 uint64_t thread_id, uint64_t address,
                                 uint64_t context, uint32_t source_kind,
                                 const char* name, const wchar_t* code,
                                 uint64_t* committed_tick_ms = nullptr) {
  ++writes;
  if (committed_tick_ms != nullptr) *committed_tick_ms = 0;
  if (use_real_lane_writer) {
    TextLaneWrite write;
    write.thread_id = thread_id;
    write.thread_address = address;
    write.thread_context = context;
    write.source_kind = source_kind;
    write.text = text;
    write.byte_len = static_cast<uint32_t>(units) * sizeof(wchar_t);
    write.hook_name = name;
    write.hook_code = code;
    const uint64_t seq = WriteTextLaneEvent(g_header, kNativeThreadPreviewStart,
        kTextLaneCount, write, committed_tick_ms);
    last_writer_tick = committed_tick_ms == nullptr ? 0 : *committed_tick_ms;
    return seq;
  }
  if (published_seq != 0 && committed_tick_ms != nullptr)
    *committed_tick_ms = SiglusTestCommitClock();
  return published_seq;
}
void PublishSiglusLookupTextSnapshot(const wchar_t*, uint32_t,
                                     SiglusLookupTextIdentity identity) {
  snapshot_seq = identity.event_id;
}
void QueueSiglusMessageVoice(uint64_t event_id, uint32_t, uint64_t tick_ms) {
  queued_voice_seq = event_id;
  queued_voice_tick = tick_ms;
}
#endif
}  // namespace

namespace {
#include "siglus_message_capture.inc"

#if defined(_M_IX86)
uint32_t observed_owner = 0, observed_esp = 0, observed_ebp = 0;
uint32_t registers[8] = {}, observed_flags = 0, expected_esp = 0;
uint32_t baseline_esp = 0, returned_esp = 0;
__declspec(align(16)) uint32_t xmm_seed[4] = {1, 2, 3, 4};
__declspec(align(16)) uint32_t xmm_after[4] = {};
void __stdcall ProbeObserver(uint32_t owner, uint32_t esp, uint32_t ebp) {
  observed_owner = owner; observed_esp = esp; observed_ebp = ebp;
  SetLastError(99);
  __asm { pxor xmm0, xmm0 }
  __asm { xor eax, eax }
  __asm { xor ecx, ecx }
  __asm { xor edx, edx }
}
__declspec(naked) void RecordRegisters() {
  __asm {
    mov registers[0], eax
    mov registers[4], ecx
    mov registers[8], edx
    mov registers[12], ebx
    mov registers[16], esp
    mov registers[20], ebp
    mov registers[24], esi
    mov registers[28], edi
    pushfd
    pop observed_flags
    movdqu xmm_after, xmm0
    ret
  }
}
__declspec(naked) void OuterTail() {
  __asm { call RecordRegisters }
  __asm { ret }
}
__declspec(naked) void InnerTail() {
  __asm { call RecordRegisters }
  __asm { ret 8 }
}
void* outer_original = reinterpret_cast<void*>(&OuterTail);
void* inner_original = reinterpret_cast<void*>(&InnerTail);
FUSHI_SIGLUS_MESSAGE_THUNK(OuterProbe, ProbeObserver, outer_original)
FUSHI_SIGLUS_MESSAGE_THUNK(InnerProbe, ProbeObserver, inner_original)
void* probe_entry = nullptr;
bool probe_caller_cleanup = false;
__declspec(naked) void RunProbe() {
  __asm {
    pushfd
    pushad
    mov baseline_esp, esp
    push 2222h
    push 1111h
    lea eax, [esp - 4]
    mov expected_esp, eax
    movdqu xmm0, xmm_seed
    mov eax, 101h
    mov ecx, 202h
    mov edx, 303h
    mov ebx, 404h
    mov ebp, 606h
    mov esi, 707h
    mov edi, 808h
    std
    stc
    call dword ptr [probe_entry]
    cld
    cmp byte ptr [probe_caller_cleanup], 0
    je clean
    add esp, 8
  clean:
    mov returned_esp, esp
    popad
    popfd
    ret
  }
}
void TestNakedAbi() {
  for (int inner = 0; inner < 2; ++inner) {
    probe_entry = inner ? reinterpret_cast<void*>(&InnerProbe)
                        : reinterpret_cast<void*>(&OuterProbe);
    probe_caller_cleanup = !inner;
    SetLastError(77);
    RunProbe();
    const DWORD last_error = GetLastError();
    Check(observed_owner == 0x202 && observed_ebp == 0x606);
    Check(observed_esp == expected_esp);
    Check(registers[0] == 0x101 && registers[1] == 0x202 &&
          registers[2] == 0x303 && registers[3] == 0x404 &&
          registers[5] == 0x606 && registers[6] == 0x707 && registers[7] == 0x808);
    Check(registers[4] + 4 == expected_esp); // RecordRegisters' own call frame
    Check((observed_flags & 0x401) == 0x401); // carry and direction survive
    Check(std::memcmp(xmm_seed, xmm_after, sizeof(xmm_seed)) == 0);
    Check(last_error == 77);
    Check(returned_esp == baseline_esp); // caller ret vs callee ret8
  }
}

void TestProductionWorkerAndRollback() {
  InitializeCriticalSection(&g_text_cs);
  InitializeCriticalSection(&g_cs);
  SiglusMessageTextTask task;
  task.text_units = 1; task.text[0] = L'X'; task.voice_key = 42;
  g_siglus_message_capture_enabled.store(true);
  g_siglus_message_install_state.store(1);
  Check(IsSiglusMessageTextInstalled());
  Check(!IsSiglusMessageVoiceMappingProved());
  published_seq = 123;
  Check(g_siglus_message_tasks.TryPush(task));
  ProcessSiglusMessageTextTasks();
  Check(writes == 1 && snapshot_seq == 123 && queued_voice_seq == 0);
  g_siglus_message_profile.voice_key_resource_mapping_proved = true;
  Check(!IsSiglusMessageVoiceMappingProved());  // Static profile is insufficient.
  published_seq = 124;
  Check(g_siglus_message_tasks.TryPush(task));
  ProcessSiglusMessageTextTasks();
  Check(snapshot_seq == 124 && queued_voice_seq == 0);
  voice_source_installed = true;
  Check(IsSiglusMessageVoiceMappingProved());
  published_seq = 125;
  Check(g_siglus_message_tasks.TryPush(task));
  ProcessSiglusMessageTextTasks();
  Check(snapshot_seq == 125 && queued_voice_seq == 125);
  published_seq = 0;
  Check(g_siglus_message_tasks.TryPush(task));
  ProcessSiglusMessageTextTasks();
  Check(snapshot_seq == 125 && queued_voice_seq == 125);
  g_siglus_message_capture_enabled.store(false);
  Check(g_siglus_message_tasks.TryPush(task));
  const int before = writes;
  ProcessSiglusMessageTextTasks(); Check(writes == before);
  g_siglus_message_created[0] = g_siglus_message_created[1] = true;
  g_siglus_message_ever_enabled[0] = true;
  mock_disable_failure = true;
  Check(!RollbackSiglusMessageHooks()); Check(mock_removed == 0);
  ShutdownSiglusMessageText();
  Check(IsSiglusMessageTextOwnershipBlocked());
  Check(!IsSiglusMessageTextInstalled());
  Check(!IsSiglusMessageVoiceMappingProved());
  Check(!TryHookSiglusMessageText());
  mock_disable_failure = false;
  Check(RollbackSiglusMessageHooks()); Check(mock_removed == 1);
  Check(g_siglus_message_created[0] && !g_siglus_message_created[1]);
  DeleteCriticalSection(&g_text_cs); DeleteCriticalSection(&g_cs);
}

void TestDelayedWorkerUsesCommittedTimestamp() {
  InitializeCriticalSection(&g_text_cs);
  TextMapping mapping;
  g_header = mapping.header();
  use_real_lane_writer = true;
  g_siglus_message_capture_enabled.store(true);
  g_siglus_message_install_state.store(1);
  voice_source_installed = true;
  g_siglus_message_profile.voice_key_resource_mapping_proved = true;
  g_siglus_message_scenario_rva = 0x1000;
  g_siglus_message_profile.scenario_return_rva = 0x2000;
  SiglusMessageTextTask task;
  while (g_siglus_message_tasks.TryPop(&task)) {}
  task = {};
  task.text_units = 1; task.text[0] = L'X'; task.voice_key = 42;
  task.tick_ms = 1;  // Callback predates the deterministic commit by >1500 ms.
  queued_voice_seq = queued_voice_tick = 0;
  Check(g_siglus_message_tasks.TryPush(task));
  ProcessSiglusMessageTextTasks();
  const auto* slot = reinterpret_cast<const TextSlot*>(
      TextLaneSlotAt(g_header, kNativeThreadPreviewStart, 1));
  Check(slot != nullptr && slot->seq == 1);
  Check(slot->timestamp_ms - task.tick_ms > 1500);
  Check(queued_voice_seq == slot->seq && snapshot_seq == slot->seq);
  Check(queued_voice_tick == slot->timestamp_ms && last_writer_tick == slot->timestamp_ms);
  // Actual production publication failure, not a fabricated zero-seq return.
  g_header->text_lane_slot_count = 0;
  last_writer_tick = UINT64_MAX;
  Check(g_siglus_message_tasks.TryPush(task));
  ProcessSiglusMessageTextTasks();
  Check(last_writer_tick == 0);
  Check(queued_voice_seq == 1 && queued_voice_tick == SiglusTestCommitClock());
  Check(snapshot_seq == 1);
  g_siglus_message_capture_enabled.store(false);
  use_real_lane_writer = false;
  g_header = &header;
  DeleteCriticalSection(&g_text_cs);
}

void TestProductionObservers() {
  // Synthetic stack/object bytes exercise the actual SEH readers and production
  // observers, not a second implementation of their argument extraction.
  uint32_t owner[160] = {};
  uint32_t surfaces[224] = {};
  uint32_t frames[128] = {};
  SiglusTextUnionW text{};
  text.size = 2; text.capacity = 7;
  text.storage.chars[0] = L'A'; text.storage.chars[1] = L'B';
  const auto address = [](const void* value) {
    return static_cast<uint32_t>(reinterpret_cast<uintptr_t>(value));
  };
  const uint32_t entry = address(&frames[100]);
  const uint32_t wrapper = address(&frames[60]);
  const uint32_t inner = address(&frames[40]);
  owner[0x1f8 / 4] = 321;
  owner[0x1e0 / 4] = 1;
  owner[0x228 / 4] = address(surfaces);
  owner[0x22c / 4] = address(surfaces) + sizeof(surfaces);
  frames[60] = entry - 4; frames[61] = 0x7001;
  frames[40] = 0x7002; frames[41] = address(&text);
  const uint32_t surface = address(surfaces) + 0x1c0;
  g_siglus_message_layout = Layout();
  g_siglus_message_capture_enabled.store(true);
  SiglusMessageTextTask task;
  while (g_siglus_message_tasks.TryPop(&task)) {}
  ObserveSiglusMessageEntry(address(owner), entry, 0);
  Check(g_siglus_message_ticket.armed);
  std::thread unrelated([&] {
    ObserveSiglusMessageScenario(surface, inner, wrapper);
  });
  unrelated.join();
  Check(!g_siglus_message_tasks.TryPop(&task));
  ObserveSiglusMessageScenario(surface, inner, wrapper);
  Check(g_siglus_message_tasks.TryPop(&task));
  Check(task.voice_key == 321 && task.text_units == 2 && task.text[1] == L'B');
  ObserveSiglusMessageScenario(surface, inner, wrapper);
  Check(!g_siglus_message_tasks.TryPop(&task));
  ObserveSiglusMessageEntry(address(owner), entry, 0);
  frames[40] = 0;
  ObserveSiglusMessageScenario(surface, inner, wrapper);
  frames[40] = 0x7002;
  ObserveSiglusMessageScenario(surface, inner, wrapper);
  Check(!g_siglus_message_tasks.TryPop(&task));
  ObserveSiglusMessageEntry(address(owner), entry, 0);
  frames[41] = 1; // invalid text union page: no exception escapes or stale ticket
  ObserveSiglusMessageScenario(surface, inner, wrapper);
  frames[41] = address(&text);
  Check(!g_siglus_message_ticket.armed && !g_siglus_message_tasks.TryPop(&task));
  ObserveSiglusMessageEntry(1, entry, 0);
  Check(!g_siglus_message_ticket.armed);
  for (int repeat = 0; repeat < 2; ++repeat) {
    ObserveSiglusMessageEntry(address(owner), entry, 0);
    ObserveSiglusMessageScenario(surface, inner, wrapper);
    Check(g_siglus_message_tasks.TryPop(&task)); // repeated text is a new occurrence
  }
  for (uint32_t i = 0; i < kSiglusMessageTaskSlots; ++i)
    Check(g_siglus_message_tasks.TryPush(task));
  ObserveSiglusMessageEntry(address(owner), entry, 0);
  ObserveSiglusMessageScenario(surface, inner, wrapper);
  Check(!g_siglus_message_ticket.armed);
  uint32_t remaining = 0;
  while (g_siglus_message_tasks.TryPop(&task)) ++remaining;
  Check(remaining == kSiglusMessageTaskSlots);
  ObserveSiglusMessageEntry(address(owner), entry, 0);
  g_siglus_message_capture_enabled.store(false);
  ObserveSiglusMessageScenario(surface, inner, wrapper);
  Check(!g_siglus_message_ticket.armed && !g_siglus_message_tasks.TryPop(&task));
}

void TestNativeProductionObservers() {
  uint32_t owner[160] = {};
  uint32_t surfaces[224] = {};
  __declspec(align(8)) uint32_t frames[256] = {};
  const auto address = [](const void* value) {
    return static_cast<uint32_t>(reinterpret_cast<uintptr_t>(value));
  };
  const uint32_t outer = address(&frames[180]);
  const uint32_t ebp = (outer - 12) & ~7u;
  const uint32_t inner = ebp - 0x60;
  auto* text = reinterpret_cast<SiglusTextUnionW*>(outer + 12);
  text->size = 2; text->capacity = 7;
  text->storage.chars[0] = L'A'; text->storage.chars[1] = L'B';
  owner[0x1f8 / 4] = 321;
  owner[0x1e0 / 4] = 0;
  owner[0x228 / 4] = address(surfaces);
  owner[0x22c / 4] = address(surfaces) + sizeof(surfaces);
  *reinterpret_cast<uint32_t*>(outer) = 0x8000;
  *reinterpret_cast<uint32_t*>(ebp + 4) = 0x8000;
  *reinterpret_cast<uint32_t*>(ebp - 0x10) = outer - 4;
  *reinterpret_cast<uint32_t*>(inner) = 0x7003;
  g_siglus_native_message_layout = {Layout(), 0x7003};
  SiglusNativeMessageSavedRegisters entry{};
  entry.saved_esp = outer - 4; entry.ecx = address(owner);
  SiglusNativeMessageSavedRegisters call{};
  call.saved_esp = inner - 4; call.ebx = outer - 4;
  call.ecx = outer + 12; call.edi = address(owner); call.ebp = ebp;
  g_siglus_message_capture_enabled.store(true);
  g_capture_enabled = true;
  SiglusMessageTextTask task;
  while (g_siglus_message_tasks.TryPop(&task)) {}
  ObserveSiglusNativeMessageEntry(&entry);
  std::thread unrelated([&] { ObserveSiglusNativeMessageText(&call); });
  unrelated.join();
  Check(!g_siglus_message_tasks.TryPop(&task));
  ObserveSiglusNativeMessageText(&call);
  Check(g_siglus_message_tasks.TryPop(&task));
  Check(task.voice_key == 321 && task.text_units == 2 && task.text[1] == L'B');
  ObserveSiglusNativeMessageText(&call);
  Check(!g_siglus_message_tasks.TryPop(&task));
  // A new silent fragment reusing the exact stack is still a new occurrence.
  owner[0x1f8 / 4] = UINT32_MAX;
  for (int fragment = 0; fragment < 2; ++fragment) {
    ObserveSiglusNativeMessageEntry(&entry);
    ObserveSiglusNativeMessageText(&call);
    Check(g_siglus_message_tasks.TryPop(&task));
    Check(task.voice_key == UINT32_MAX && task.text_units == 2);
  }
  ObserveSiglusNativeMessageEntry(&entry);
  call.edi = 0;
  ObserveSiglusNativeMessageText(&call);
  call.edi = address(owner);
  ObserveSiglusNativeMessageText(&call);
  Check(!g_siglus_native_message_ticket.armed &&
        !g_siglus_message_tasks.TryPop(&task));
  ObserveSiglusNativeMessageEntry(&entry);
  text->capacity = 8; text->storage.text = reinterpret_cast<const wchar_t*>(1);
  ObserveSiglusNativeMessageText(&call);
  Check(!g_siglus_native_message_ticket.armed &&
        !g_siglus_message_tasks.TryPop(&task));
  ObserveSiglusNativeMessageEntry(&entry);
  g_siglus_message_capture_enabled.store(false);
  ObserveSiglusNativeMessageText(&call);
  Check(!g_siglus_native_message_ticket.armed &&
        !g_siglus_message_tasks.TryPop(&task));
}

void TestInstallationFailures() {
  InitializeCriticalSection(&g_cs);
  const auto reset = [] {
    mock_created = mock_enabled = mock_removed = 0;
    mock_null_original = -1; mock_disable_failure = false;
    g_siglus_message_capture_enabled.store(false);
    g_siglus_message_install_state.store(0);
    g_siglus_message_native_ecx = false;
    g_orig_SiglusMessageEntry = g_orig_SiglusMessageScenario = nullptr;
    for (int i = 0; i < 2; ++i) {
      mock_create_status[i] = mock_enable_status[i] = MH_OK;
      g_siglus_message_created[i] = g_siglus_message_ever_enabled[i] = false;
      g_siglus_message_targets[i] = reinterpret_cast<void*>(static_cast<uintptr_t>(0x5000 + i));
    }
  };
  for (int failure = 0; failure < 2; ++failure) {
    reset(); mock_create_status[failure] = MH_ERROR_NOT_CREATED;
    Check(!InstallSiglusMessageHookGroup());
    Check(!IsSiglusMessageTextInstalled() && !IsSiglusMessageTextOwnershipBlocked());
    Check(mock_removed == failure && mock_enabled == 0);
  }
  reset(); mock_null_original = 1;
  Check(!InstallSiglusMessageHookGroup());
  Check(mock_removed == 2 && mock_enabled == 0);
  for (int failure = 0; failure < 2; ++failure) {
    reset(); mock_enable_status[failure] = MH_ERROR_NOT_CREATED;
    Check(!InstallSiglusMessageHookGroup());
    Check(!g_siglus_message_capture_enabled.load());
    Check(mock_removed == (failure == 0 ? 2 : 1));
    if (failure == 1) Check(g_orig_SiglusMessageScenario != nullptr);
  }
  reset(); mock_enable_status[1] = MH_ERROR_NOT_CREATED;
  mock_disable_failure = true;
  Check(!InstallSiglusMessageHookGroup());
  Check(IsSiglusMessageTextOwnershipBlocked() && !IsSiglusMessageTextInstalled());
  Check(mock_removed == 0 && g_orig_SiglusMessageScenario != nullptr);
  // Native fallback uses the same MinHook registry. A disabled but retained
  // inner record must not be handed to the plain HookFn path for re-enabling.
  reset(); g_siglus_message_native_ecx = true;
  mock_enable_status[1] = MH_ERROR_NOT_CREATED;
  Check(!InstallSiglusMessageHookGroup());
  Check(IsSiglusMessageTextOwnershipBlocked());
  Check(g_siglus_message_created[1] && g_orig_SiglusMessageScenario != nullptr);
  Check(!g_siglus_message_capture_enabled.load());
  // A pre-existing inner record belongs to another owner. Even though this
  // group never created it, the fallback must not re-enable or borrow it.
  reset(); g_siglus_message_native_ecx = true;
  mock_create_status[1] = MH_ERROR_ALREADY_CREATED;
  Check(!InstallSiglusMessageHookGroup());
  Check(IsSiglusMessageTextOwnershipBlocked());
  Check(!g_siglus_message_created[1] && mock_enabled == 0);
  reset();
  Check(InstallSiglusMessageHookGroup());
  Check(IsSiglusMessageTextInstalled() && g_siglus_message_capture_enabled.load());
  Check(mock_created == 2 && mock_enabled == 2 && mock_removed == 0);
  ShutdownSiglusMessageText();
  Check(!IsSiglusMessageTextInstalled() && !IsSiglusMessageTextOwnershipBlocked());
  Check(mock_removed == 0 && g_orig_SiglusMessageEntry != nullptr &&
        g_orig_SiglusMessageScenario != nullptr);
  DeleteCriticalSection(&g_cs);
}
#endif
}  // namespace

int main() {
  TestTicket(); TestQueue(); TestCommittedTextLaneTimestamp();
#if defined(_M_IX86)
  TestNakedAbi(); TestProductionObservers(); TestProductionWorkerAndRollback();
  TestDelayedWorkerUsesCommittedTimestamp();
  TestNativeProductionObservers();
  TestInstallationFailures();
#else
  Check(!TryHookSiglusMessageText());
  Check(!IsSiglusMessageTextInstalled());
  Check(!IsSiglusMessageVoiceMappingProved());
  Check(!IsSiglusMessageTextOwnershipBlocked());
  ProcessSiglusMessageTextTasks(); ShutdownSiglusMessageText();
#endif
  std::printf("siglus_message_capture_test: PASS (%d checks)\n", checks);
  return 0;
}
