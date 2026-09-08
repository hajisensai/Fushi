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
#include "siglus_legacy_message_profile.h"
#include "siglus_legacy_message_capture.h"
#include "siglus_legacy_resource.h"
#include "siglus_legacy_live_admission.h"
#include "siglus_eight_arg_glyph.h"
#include "siglus_eightarg_message_capture.h"
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
LegacyGlyphSites g_siglus_legacy_glyph_sites;
struct { SiglusEightArgGlyphSites glyph; } g_siglus_eightarg_sites;
bool IsEightArgSiglusLookup(const SiglusLookupProfile& profile) {
  return profile.glyph_abi == SiglusGlyphLayoutAbi::kEcxEightArguments;
}
uint64_t eightarg_epoch = 0, observed_epoch = 0, bound_epoch = 0;
int begin_calls = 0, observed_calls = 0, sync_calls = 0, bind_calls = 0;
bool bind_allowed = true;
siglus_eightarg_message::Owner observed_body{}, bound_body{};
SiglusLookupTextIdentity bound_identity{};
uint64_t BeginSiglusEightArgOccurrence() {
  ++begin_calls;
  SetLastError(99);
  __asm { pxor xmm0, xmm0 }
  return ++eightarg_epoch;
}
void QueueSiglusEightArgObservedBody(uint64_t epoch,
    const siglus_eightarg_message::Owner& owner) {
  ++observed_calls; observed_epoch = epoch; observed_body = owner;
  SetLastError(98);
  __asm { pxor xmm0, xmm0 }
}
void SyncSiglusEightArgOccurrence() { ++sync_calls; }
bool BindSiglusEightArgText(uint64_t epoch,
    const siglus_eightarg_message::Owner& owner, SiglusLookupTextIdentity identity) {
  ++bind_calls;
  if (!bind_allowed || epoch != eightarg_epoch) return false;
  bound_epoch = epoch; bound_body = owner; bound_identity = identity;
  return true;
}
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
void* mock_detours[2] = {};
MH_STATUS MH_CreateHook(void*, void* detour, void** original) {
  const int index = mock_created++;
  assert(index < 2);
  mock_detours[index] = detour;
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
    g_siglus_message_legacy = false;
    g_siglus_message_eightarg = false;
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
  reset(); g_siglus_message_legacy = true;
  mock_enable_status[1] = MH_ERROR_NOT_CREATED;
  Check(!InstallSiglusMessageHookGroup());
  Check(IsSiglusMessageTextOwnershipBlocked());
  Check(g_siglus_message_created[1] && g_orig_SiglusMessageScenario != nullptr);
  reset(); g_siglus_message_legacy = true;
  mock_create_status[1] = MH_ERROR_ALREADY_CREATED;
  Check(!InstallSiglusMessageHookGroup());
  Check(IsSiglusMessageTextOwnershipBlocked());
  Check(!g_siglus_message_created[1] && mock_enabled == 0);
  reset(); g_siglus_message_eightarg = true;
  mock_enable_status[1] = MH_ERROR_NOT_CREATED;
  Check(!InstallSiglusMessageHookGroup());
  Check(IsSiglusMessageTextOwnershipBlocked());
  Check(g_siglus_message_created[1] && g_orig_SiglusMessageScenario != nullptr);
  reset(); g_siglus_message_eightarg = true;
  mock_create_status[1] = MH_ERROR_ALREADY_CREATED;
  Check(!InstallSiglusMessageHookGroup());
  Check(IsSiglusMessageTextOwnershipBlocked());
  Check(!g_siglus_message_created[1] && mock_enabled == 0);
  reset(); g_siglus_message_eightarg = true;
  Check(InstallSiglusMessageHookGroup());
  Check(mock_detours[0] == reinterpret_cast<void*>(&Detour_SiglusEightArgMessageEntry));
  Check(mock_detours[1] == reinterpret_cast<void*>(&Detour_SiglusEightArgMessageScenario));
  Check(IsSiglusMessageTextInstalled() && g_siglus_message_capture_enabled.load());
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

void TestLegacyProductionObservers() {
  uint32_t owner[80] = {}, script[112] = {}, frames[128] = {};
  const auto address = [](const void* p) {
    return static_cast<uint32_t>(reinterpret_cast<uintptr_t>(p));
  };
  uint32_t script_slot = address(script);
  const uint32_t outer = address(&frames[80]), inner = outer - 0x68;
  auto* text = reinterpret_cast<SiglusTextUnionW*>(outer + 8);
  text->size = 2; text->capacity = 7;
  text->storage.chars[0] = L'A'; text->storage.chars[1] = L'B';
  frames[80] = 0x8000;
  *reinterpret_cast<uint32_t*>(inner) = 0x7004;
  script[0x19c / 4] = 100000321;
  script[0x1a0 / 4] = script[0x1a4 / 4] = 1;
  owner[0x120 / 4] = 100000123; // Previous message, deliberately different.
  owner[0x124 / 4] = 1;
  g_siglus_legacy_message_layout = {address(&script_slot), 0x7004, 1500};
  SiglusNativeMessageSavedRegisters entry{}, call{};
  entry.saved_esp = outer - 4; entry.ecx = address(owner);
  call.saved_esp = inner - 4; call.ecx = outer + 4; call.edi = address(owner);
  g_siglus_message_capture_enabled.store(true);
  g_capture_enabled = true;
  SiglusMessageTextTask task;
  while (g_siglus_message_tasks.TryPop(&task)) {}
  ObserveSiglusLegacyMessageEntry(&entry);
  Check(g_siglus_legacy_message_ticket.armed);
  std::thread unrelated([&] { ObserveSiglusLegacyMessageText(&call); });
  unrelated.join();
  Check(!g_siglus_message_tasks.TryPop(&task));
  ObserveSiglusLegacyMessageText(&call);
  Check(g_siglus_message_tasks.TryPop(&task));
  Check(task.voice_key == 100000321 && task.text_units == 2 &&
        std::wcscmp(task.text, L"AB") == 0);
  ObserveSiglusLegacyMessageText(&call);
  Check(!g_siglus_message_tasks.TryPop(&task));
  // Silence and repeats still publish text, without inheriting the old key.
  script[0x19c / 4] = script[0x1a0 / 4] = UINT32_MAX;
  for (int i = 0; i < 2; ++i) {
    ObserveSiglusLegacyMessageEntry(&entry);
    ObserveSiglusLegacyMessageText(&call);
    Check(g_siglus_message_tasks.TryPop(&task));
    Check(task.voice_key == UINT32_MAX);
  }
  ObserveSiglusLegacyMessageEntry(&entry);
  script[0x19c / 4] = 100000322;
  ObserveSiglusLegacyMessageText(&call);
  Check(!g_siglus_legacy_message_ticket.armed &&
        !g_siglus_message_tasks.TryPop(&task));
  // A valid descriptor but bad payload is consumed without escaping SEH.
  text->capacity = 15;
  text->storage.text = reinterpret_cast<const wchar_t*>(0x1000);
  ObserveSiglusLegacyMessageEntry(&entry);
  ObserveSiglusLegacyMessageText(&call);
  Check(!g_siglus_legacy_message_ticket.armed &&
        !g_siglus_message_tasks.TryPop(&task));
  g_siglus_message_capture_enabled.store(false);
}

uint32_t eight_owner = 0, eight_surface = 0, eight_outer_return = 0;
uint32_t eight_inner_return = 0, eight_before = 0, eight_after = 0;
uint32_t eight_entry_ecx = 0, eight_entry_edx = 0, eight_inner_ecx = 0;
uint32_t eight_entry_flags = 0, eight_inner_flags = 0;
uint32_t eight_entry_error = 0, eight_inner_error = 0;
uint32_t eight_observed_before_original = 0, eight_result = 0;
__declspec(align(16)) uint32_t eight_entry_xmm[4] = {}, eight_inner_xmm[4] = {};

void TestEightArgLiveEntryAdmission() {
  // Use the real loaded-PE opener and production live gate. Synthetic bytes
  // are only read; this allocation is never executable and never called.
  auto* bytes = static_cast<uint8_t*>(VirtualAlloc(nullptr, 0x3000,
      MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
  Check(bytes != nullptr);
  auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(bytes);
  dos->e_magic = IMAGE_DOS_SIGNATURE; dos->e_lfanew = 0x80;
  auto* nt = reinterpret_cast<IMAGE_NT_HEADERS32*>(bytes + 0x80);
  nt->Signature = IMAGE_NT_SIGNATURE;
  nt->FileHeader.Machine = IMAGE_FILE_MACHINE_I386;
  nt->FileHeader.NumberOfSections = 1;
  nt->FileHeader.SizeOfOptionalHeader = sizeof(IMAGE_OPTIONAL_HEADER32);
  nt->OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR32_MAGIC;
  nt->OptionalHeader.SizeOfImage = 0x3000;
  auto* section = IMAGE_FIRST_SECTION(nt);
  section->VirtualAddress = 0x1000; section->Misc.VirtualSize = 0x2000;
  section->Characteristics = IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE;
  SiglusEightArgGlyphSites sites;
  sites.message_entry_rva = 0x1100; sites.scenario_entry_rva = 0x1500;
  sites.message_caller_return_rva = 0x1800;
  sites.message_scenario_return_rva = 0x1900;
  const auto& message = siglus_eight_arg_glyph::kMessage;
  const auto& scenario = siglus_eight_arg_glyph::kScenarioEntry;
  std::memcpy(bytes + sites.message_entry_rva, message.bytes.data(), message.bytes.size());
  std::memcpy(bytes + sites.scenario_entry_rva, scenario.bytes.data(), scenario.bytes.size());
  const auto module = reinterpret_cast<HMODULE>(bytes);
  Check(ResolveLiveSiglusEightArgMessage(module, sites));
  for (const auto entry : {sites.message_entry_rva, sites.scenario_entry_rva}) {
    bytes[entry] = 0xe9;
    Check(!ResolveLiveSiglusEightArgMessage(module, sites));
    bytes[entry] = 0x55;
    bytes[entry + 2] ^= 1;
    Check(!ResolveLiveSiglusEightArgMessage(module, sites));
    bytes[entry + 2] ^= 1;
  }
  for (auto member : {&SiglusEightArgGlyphSites::message_entry_rva,
                     &SiglusEightArgGlyphSites::scenario_entry_rva,
                     &SiglusEightArgGlyphSites::message_caller_return_rva,
                     &SiglusEightArgGlyphSites::message_scenario_return_rva}) {
    for (uintptr_t invalid : {uintptr_t{0}, uintptr_t{0x400}, UINTPTR_MAX}) {
      auto wrong = sites; wrong.*member = invalid;
      Check(!ResolveLiveSiglusEightArgMessage(module, wrong));
    }
  }
  section->Characteristics = IMAGE_SCN_MEM_READ;
  Check(!ResolveLiveSiglusEightArgMessage(module, sites));
  Check(VirtualFree(bytes, 0, MEM_RELEASE) != FALSE);
}
__declspec(naked) void EightScenarioOriginal() {
  __asm {
    mov eight_inner_ecx, ecx
    pushfd
    pop eight_inner_flags
    movdqu eight_inner_xmm, xmm0
    mov eax, fs:[34h]
    mov eight_inner_error, eax
    mov eax, observed_calls
    mov eight_observed_before_original, eax
    mov al, 0a5h
    ret 8
  }
}
__declspec(naked) void EightMessageOriginal() {
  __asm {
    mov eight_entry_ecx, ecx
    mov eight_entry_edx, edx
    pushfd
    pop eight_entry_flags
    movdqu eight_entry_xmm, xmm0
    mov eax, fs:[34h]
    mov eight_entry_error, eax
    push ebp
    mov ebp, esp
    sub esp, 40h
    lea eax, inner_return
    mov eight_inner_return, eax
    lea eax, [ebp - 30h]
    push eax
    lea eax, [ebp + 10h]
    push eax
    mov ecx, eight_surface
    movdqu xmm0, xmm_seed
    std
    stc
    call Detour_SiglusEightArgMessageScenario
  inner_return:
    movzx eax, al
    mov eight_result, eax
    cld
    mov esp, ebp
    pop ebp
    ret
  }
}
__declspec(naked) void RunEightArgProduction() {
  __asm {
    pushfd
    pushad
    mov eight_before, esp
    sub esp, 20h
    mov dword ptr [esp], 1111h
    mov dword ptr [esp + 4], 2222h
    mov dword ptr [esp + 8], 00420041h
    mov dword ptr [esp + 0ch], 0
    mov dword ptr [esp + 10h], 0
    mov dword ptr [esp + 14h], 0
    mov dword ptr [esp + 18h], 2
    mov dword ptr [esp + 1ch], 7
    lea eax, outer_return
    mov eight_outer_return, eax
    mov ecx, eight_owner
    mov edx, 9876h
    movdqu xmm0, xmm_seed
    std
    stc
    call Detour_SiglusEightArgMessageEntry
  outer_return:
    cld
    add esp, 20h
    mov eight_after, esp
    popad
    popfd
    ret
  }
}

void TestEightArgProduction() {
  uint32_t owner[112] = {}, surfaces[146] = {}, frames[128] = {};
  const auto address = [](const void* p) {
    return static_cast<uint32_t>(reinterpret_cast<uintptr_t>(p));
  };
  eight_owner = address(owner); eight_surface = address(surfaces) + 0x124;
  owner[0x160 / 4] = 1; owner[0x1a8 / 4] = address(surfaces);
  owner[0x1ac / 4] = address(surfaces) + sizeof(surfaces);
  g_orig_SiglusMessageEntry = reinterpret_cast<void*>(&EightMessageOriginal);
  g_orig_SiglusMessageScenario = reinterpret_cast<void*>(&EightScenarioOriginal);
  g_siglus_message_capture_enabled.store(false);
  RunEightArgProduction(); // Discover labels without arming a ticket.
  g_siglus_eightarg_message_layout = {eight_outer_return, eight_inner_return};
  g_siglus_message_capture_enabled.store(true); g_capture_enabled = true;
  SiglusMessageTextTask task;
  while (g_siglus_message_tasks.TryPop(&task)) {}
  const int before_observed = observed_calls;
  SetLastError(77);
  RunEightArgProduction();
  Check(GetLastError() == 77 && eight_entry_error == 77 && eight_inner_error == 77);
  Check(eight_entry_ecx == eight_owner && eight_entry_edx == 0x9876);
  Check(eight_inner_ecx == eight_surface && eight_before == eight_after);
  Check((eight_entry_flags & 0x401) == 0x401 && (eight_inner_flags & 0x401) == 0x401);
  Check(std::memcmp(eight_entry_xmm, xmm_seed, sizeof(xmm_seed)) == 0);
  Check(std::memcmp(eight_inner_xmm, xmm_seed, sizeof(xmm_seed)) == 0);
  Check(eight_result == 0xa5 &&
        eight_observed_before_original == static_cast<uint32_t>(before_observed + 1));
  Check(g_siglus_message_tasks.TryPop(&task));
  Check(task.eightarg_epoch == eightarg_epoch && task.voice_key == UINT32_MAX);
  Check(task.eightarg_owner.address == eight_owner &&
        task.eightarg_owner.surface == eight_surface && std::wcscmp(task.text, L"AB") == 0);
  Check(!g_siglus_eightarg_message_ticket.armed && g_siglus_eightarg_message_epoch == 0);

  const uint32_t outer = address(&frames[80]), inner = address(&frames[40]);
  frames[80] = 0x7000; frames[40] = 0x8000; frames[41] = outer + 12;
  auto* text = reinterpret_cast<SiglusTextUnionW*>(outer + 12);
  text->size = 2; text->capacity = 7;
  text->storage.chars[0] = L'A'; text->storage.chars[1] = L'B';
  g_siglus_eightarg_message_layout = {0x7000, 0x8000};
  const auto arm = [&] { ObserveSiglusEightArgMessageEntry(eight_owner, outer, 0); };
  const auto consume = [&] { ObserveSiglusEightArgMessageScenario(eight_surface, inner, outer - 4); };
  arm();
  std::thread unrelated([&] { consume(); }); unrelated.join();
  Check(!g_siglus_message_tasks.TryPop(&task));
  consume(); Check(g_siglus_message_tasks.TryPop(&task));
  consume(); Check(!g_siglus_message_tasks.TryPop(&task));
  const uint64_t epoch = eightarg_epoch;
  arm(); frames[80] = 0; arm(); frames[80] = 0x7000;
  consume(); Check(!g_siglus_message_tasks.TryPop(&task));
  Check(eightarg_epoch == epoch + 1); // Unknown outer caller never starts an occurrence.
  ObserveSiglusEightArgMessageEntry(1, outer, 0);
  Check(eightarg_epoch == epoch + 2 && !g_siglus_eightarg_message_ticket.armed);
  arm(); text->capacity = 15; text->storage.text = reinterpret_cast<const wchar_t*>(1);
  consume(); Check(!g_siglus_message_tasks.TryPop(&task));
  Check(!g_siglus_eightarg_message_ticket.armed && eightarg_epoch == epoch + 3);
  *text = {}; text->size = 1; text->capacity = 7; text->storage.chars[0] = L'X';
  for (uint32_t i = 0; i < kSiglusMessageTaskSlots; ++i)
    Check(g_siglus_message_tasks.TryPush(task));
  arm(); consume();
  Check(eightarg_epoch == epoch + 4 && !g_siglus_eightarg_message_ticket.armed);
  uint32_t queued = 0;
  while (g_siglus_message_tasks.TryPop(&task)) ++queued;
  Check(queued == kSiglusMessageTaskSlots);

  InitializeCriticalSection(&g_text_cs);
  g_siglus_message_eightarg = true;
  voice_source_installed = true;
  g_siglus_message_install_state.store(1);
  g_siglus_message_profile.voice_key_resource_mapping_proved = true;
  Check(!IsSiglusMessageVoiceMappingProved());
  arm(); consume();
  published_seq = 801; snapshot_seq = queued_voice_seq = 0;
  ProcessSiglusMessageTextTasks();
  Check(snapshot_seq == 801 && bound_identity.event_id == 801);
  Check(bound_epoch == eightarg_epoch && bound_body.surface == eight_surface);
  Check(queued_voice_seq == 0);
  arm(); consume(); arm(); // Older queued occurrence may be history, never current.
  published_seq = 802; ProcessSiglusMessageTextTasks();
  Check(snapshot_seq == 801 && queued_voice_seq == 0);
  consume(); bind_allowed = false; ProcessSiglusMessageTextTasks();
  Check(snapshot_seq == 801); bind_allowed = true;
  arm(); consume(); published_seq = 0;
  const int binds = bind_calls;
  ProcessSiglusMessageTextTasks(); Check(bind_calls == binds);
  const int syncs = sync_calls;
  g_capture_enabled = false;
  ProcessSiglusMessageTextTasks(); Check(sync_calls == syncs + 1);
  g_capture_enabled = true;
  g_siglus_message_eightarg = false;
  DeleteCriticalSection(&g_text_cs);
}
#endif
}  // namespace

int main() {
  TestTicket(); TestQueue(); TestCommittedTextLaneTimestamp();
#if defined(_M_IX86)
  TestNakedAbi(); TestProductionObservers(); TestProductionWorkerAndRollback();
  TestDelayedWorkerUsesCommittedTimestamp();
  TestNativeProductionObservers();
  TestLegacyProductionObservers();
  TestInstallationFailures();
  TestEightArgProduction();
  TestEightArgLiveEntryAdmission();
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
