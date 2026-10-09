// LucaSystem (Prototype) adapter: the scenario VM's MESSAGE text lane and the
// line's own voice from the engine's indexed voice archives.
//
// Identity is structural (luca_profile.h: boot configuration + a complete
// PAK index, or the Win64 multiple-index layout). MESSAGE sites are resolved
// from executable code in the normally loaded image, with a bounded worker
// retry while that code becomes available. No executable name/hash is used.
//
// Text: the two VM operand readers are detoured, and only the calls whose
// return address belongs to the MESSAGE site are observed: ReadU16 opens a
// message (its value is the line's voice id), each ReadString adds one
// language record.  The game thread copies the records into a preallocated
// slot (bounded, guarded) and returns; the HookWorker decodes the Japanese
// record and publishes it on the exact text lane `ENGINE:LUCA:message`.
//
// Lookup: luca_lookup.inc (cText glyph records; rules in luca_lookup_core.h).
//
// Voice: the voice id names one member of exactly one indexed archive (member
// = id - id_start).  The worker reads that member from the archive file,
// validates it (luca_pak.h) and writes the Ogg stream bound to the line's text
// event, including both OGGPAK wrappers and direct Ogg Vorbis members.
// The host pairs by event identity. These are the bytes the
// engine itself plays for the line; nothing is decoded.
#include "luca_profile.h"
#include "luca_lookup_core.h"
#include "luca_x64_text_core.h"

#if defined(_M_IX86) || defined(_M_X64)

namespace luca = fushi_voice_hook::luca;

constexpr uint32_t kLucaRecordChars = 1024u;
constexpr uint32_t kLucaMessageSlots = 16u;
constexpr uint64_t kLucaSiteRetryIntervalMs = 500u;
constexpr uint64_t kLucaSiteRetryWindowMs = 120000u;
constexpr uint64_t kLucaTextDedupeMs = 500u;
constexpr uint32_t kLucaVoiceMemberBytes = 8u << 20;
constexpr uint32_t kLucaLogBudget = 256u;

// Adapter-local diagnostics (AdapterDiagnostics::flags).
constexpr uint32_t kLucaDiagIdentityMatched = 0x00000001u;
constexpr uint32_t kLucaDiagSitesResolved = 0x00000002u;
constexpr uint32_t kLucaDiagSitesRejected = 0x00000004u;
constexpr uint32_t kLucaDiagHooksReady = 0x00000008u;
constexpr uint32_t kLucaDiagMessageObserved = 0x00000010u;
constexpr uint32_t kLucaDiagTextPublished = 0x00000020u;
constexpr uint32_t kLucaDiagRecordRejected = 0x00000040u;
constexpr uint32_t kLucaDiagSlotDropped = 0x00000080u;
constexpr uint32_t kLucaDiagVoiceArchivesReady = 0x00000100u;
constexpr uint32_t kLucaDiagVoicePublished = 0x00000200u;
constexpr uint32_t kLucaDiagVoiceRejected = 0x00000400u;
constexpr uint32_t kLucaDiagVoiceArchiveMissing = 0x00000800u;

volatile LONG g_luca_diag = 0;

void NoteLucaDiag(uint32_t bit) {
  InterlockedOr(&g_luca_diag, static_cast<LONG>(bit));
}

#if defined(_M_IX86)
using LucaReaderFn = uintptr_t(__fastcall*)(void* vm, void* edx,
                                           uint32_t argument);
#else
using LucaReaderFn = uintptr_t(__fastcall*)(void* vm, uint32_t argument);
using LucaStringReaderFn = uintptr_t(__fastcall*)(void* vm, void* result,
                                                 void* argument);
#endif
using LucaLayoutFn = uintptr_t(__fastcall*)(void* text, void* edx, uint32_t a,
                                            uint32_t b);

struct LucaMessageSlot {
  volatile LONG state = 0;  // 0 free, 1 producing, 2 pending, 3 consuming
  uint64_t tick = 0u;
  uint64_t order = 0u;
  uint64_t vm_identity = 0u;
  uint32_t voice_id = 0u;
  uint32_t record_count = 0u;
  uint8_t encodings[luca::kMaxMessageRecords] = {};
  uint32_t lengths[luca::kMaxMessageRecords] = {};  // bytes, excluding NUL
  wchar_t records[luca::kMaxMessageRecords][kLucaRecordChars] = {};
};

// The message being assembled on the VM thread, between its ReadU16 and its
// last ReadString.  Only touched under LucaRuntime::assembly_lock.
struct LucaAssembly {
  bool open = false;
  void* vm = nullptr;
  uint64_t tick = 0u;
  uint32_t voice_id = 0u;
  uint32_t count = 0u;
  uint32_t record_count = 0u;
  bool clean = true;
  uint8_t encodings[luca::kMaxMessageRecords] = {};
  uint32_t lengths[luca::kMaxMessageRecords] = {};
  wchar_t records[luca::kMaxMessageRecords][kLucaRecordChars] = {};
};

struct LucaVoiceArchive {
  std::wstring path;
  luca::PakIndex index;
  std::vector<luca::PakEntry> entries;
};

struct LucaRuntime {
  std::atomic<bool> live{false};
  bool resolved = false;
  bool hooks_installed = false;
  uint64_t first_attempt_ms = 0u;
  uint64_t last_attempt_ms = 0u;
  luca::MessageSiteResult site_result = luca::MessageSiteResult::kMissing;
  luca::MessageSites sites;
  uintptr_t image_base = 0u;
  size_t image_size = 0u;
  int32_t design_w = 0;
  int32_t design_h = 0;
  std::array<luca::CodeSpan, 96u> spans = {};
  size_t span_count = 0u;
  uintptr_t voice_return = 0u;
  uintptr_t record_return = 0u;
  uint32_t record_count = luca::kMessageRecordCount;
  const uint32_t* record_count_source = nullptr;
  SRWLOCK assembly_lock = SRWLOCK_INIT;
  LucaAssembly assembly;
  std::atomic<uint64_t> next_order{0u};
  // Worker-only.
  uint32_t logged = 0u;
  bool archives_loaded = false;
  std::vector<LucaVoiceArchive> archives;
  std::wstring last_text;
  uint64_t last_text_tick = 0u;
  uint64_t last_text_event = 0u;
#if defined(_M_X64)
  luca::X64JapaneseRecordSelector japanese_record;
#endif
};

LucaRuntime g_luca;
LucaMessageSlot g_luca_slots[kLucaMessageSlots];
LucaReaderFn g_luca_read_u16_original = nullptr;
#if defined(_M_IX86)
LucaReaderFn g_luca_read_string_original = nullptr;
#else
LucaStringReaderFn g_luca_read_string_original = nullptr;
#endif

// Worker-only, bounded diagnostics in %TEMP%\fushi_galhook.log.  Never logs
// dialogue text.
void LucaLog(const wchar_t* format, ...) {
  auto& rt = g_luca;
  if (rt.logged >= kLucaLogBudget) return;
  ++rt.logged;
  wchar_t line[1024] = {};
  va_list args;
  va_start(args, format);
  _vsnwprintf_s(line, _TRUNCATE, format, args);
  va_end(args);
  wchar_t path[MAX_PATH] = {};
  const DWORD length = GetTempPathW(MAX_PATH, path);
  if (length == 0 || length >= MAX_PATH - 20) return;
  wcscat_s(path, L"fushi_galhook.log");
  HANDLE file = g_orig_CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ,
                                   nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                                   nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME now = {};
  GetLocalTime(&now);
  wchar_t stamped[1200] = {};
  _snwprintf_s(stamped, _TRUNCATE, L"%02u:%02u:%02u.%03u pid=%lu %s\r\n",
               now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
               GetCurrentProcessId(), line);
  char utf8[2400] = {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, stamped, -1, utf8,
                                        static_cast<int>(sizeof(utf8)),
                                        nullptr, nullptr);
  DWORD written = 0;
  if (bytes > 1) WriteFile(file, utf8, static_cast<DWORD>(bytes - 1), &written,
                           nullptr);
  CloseHandle(file);
}

#if defined(_M_IX86)
#include "luca_lookup.inc"
#else
#include "luca_x64_lookup.inc"
#endif

// ── Game thread ────────────────────────────────────────────────────────────

// Copies one NUL-terminated record into `out`.  A record that does not end
// within the buffer, or whose memory faults, is not a usable line.
bool CopyLucaRecord(const wchar_t* source, wchar_t* out, uint32_t* length) {
  *length = 0u;
  if (source == nullptr) return false;
  __try {
    for (uint32_t i = 0; i < kLucaRecordChars; ++i) {
      const wchar_t unit = source[i];
      out[i] = unit;
      if (unit == L'\0') {
        *length = i * sizeof(wchar_t);
        return true;
      }
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  out[0] = L'\0';
  return false;
}

// Under assembly_lock: hands the finished message to a free slot.
void SubmitLucaAssemblyLocked(LucaAssembly& assembly) {
  for (LucaMessageSlot& slot : g_luca_slots) {
    if (InterlockedCompareExchange(&slot.state, 1, 0) != 0) continue;
    slot.tick = assembly.tick;
    slot.order = g_luca.next_order.fetch_add(1u, std::memory_order_relaxed);
    slot.vm_identity = reinterpret_cast<uintptr_t>(assembly.vm);
    slot.voice_id = assembly.voice_id;
    slot.record_count = assembly.record_count;
    for (uint32_t i = 0; i < slot.record_count; ++i) {
      slot.encodings[i] = assembly.encodings[i];
      slot.lengths[i] = assembly.lengths[i];
      std::memcpy(slot.records[i], assembly.records[i],
                  size_t{assembly.lengths[i]} + sizeof(wchar_t));
    }
    InterlockedExchange(&slot.state, 2);
    return;
  }
  NoteLucaDiag(kLucaDiagSlotDropped);
}

uint32_t ReadLucaMessageRecordCount() {
  uint32_t count = g_luca.record_count;
  if (g_luca.record_count_source != nullptr) {
    __try {
      std::memcpy(&count, g_luca.record_count_source, sizeof(count));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      return 0u;
    }
  }
#if defined(_M_X64)
  return luca::X64AdmittedRecordCount(count);
#else
  return count >= 1u && count <= luca::kMaxMessageRecords ? count : 0u;
#endif
}

#if defined(_M_IX86)
uintptr_t __fastcall LucaReadU16Detour(void* vm, void* edx, uint32_t argument) {
  const uintptr_t value = g_luca_read_u16_original(vm, edx, argument);
#else
uintptr_t __fastcall LucaReadU16Detour(void* vm, uint32_t argument) {
  const uintptr_t value = g_luca_read_u16_original(vm, argument);
#endif
  auto& rt = g_luca;
  if (rt.live.load(std::memory_order_acquire) &&
      reinterpret_cast<uintptr_t>(_ReturnAddress()) == rt.voice_return) {
    AcquireSRWLockExclusive(&rt.assembly_lock);
    LucaAssembly& assembly = rt.assembly;
    assembly.record_count = ReadLucaMessageRecordCount();
    assembly.open = assembly.record_count != 0u;
    assembly.vm = vm;
    assembly.tick = GetTickCount64();
    assembly.voice_id = static_cast<uint32_t>(value & 0xFFFFu);
    assembly.count = 0u;
    assembly.clean = true;
    ReleaseSRWLockExclusive(&rt.assembly_lock);
    NoteLucaDiag(kLucaDiagMessageObserved);
  }
  return value;
}

#if defined(_M_IX86)
uintptr_t __fastcall LucaReadStringDetour(void* vm, void* edx,
                                          uint32_t argument) {
  const uintptr_t value = g_luca_read_string_original(vm, edx, argument);
#else
uintptr_t __fastcall LucaReadStringDetour(void* vm, void* result,
                                         void* argument) {
  const uintptr_t value = g_luca_read_string_original(vm, result, argument);
#endif
  auto& rt = g_luca;
  if (!rt.live.load(std::memory_order_acquire) ||
      reinterpret_cast<uintptr_t>(_ReturnAddress()) != rt.record_return) {
    return value;
  }
  AcquireSRWLockExclusive(&rt.assembly_lock);
  LucaAssembly& assembly = rt.assembly;
  if (assembly.open && assembly.vm == vm &&
      ReadLucaMessageRecordCount() != assembly.record_count) {
    assembly.open = false;
    assembly.clean = false;
    NoteLucaDiag(kLucaDiagRecordRejected);
  }
  if (assembly.open && assembly.vm == vm &&
      assembly.count < assembly.record_count) {
    const uint32_t index = assembly.count++;
#if defined(_M_IX86)
    assembly.encodings[index] = 3u;
    if (!CopyLucaRecord(reinterpret_cast<const wchar_t*>(value),
                        assembly.records[index], &assembly.lengths[index])) {
      assembly.clean = false;
    }
#else
    bool copied = false;
    __try {
      const uint8_t* view = reinterpret_cast<const uint8_t*>(value);
      uint64_t begin = 0u;
      uint64_t end = 0u;
      std::memcpy(&begin, view, sizeof(begin));
      std::memcpy(&end, view + 8u, sizeof(end));
      const uint8_t encoding = view[0x10u];
      uint32_t bytes = 0u;
      if (luca::X64RecordByteCount(begin, end, encoding,
                                  sizeof(assembly.records[index]) - 2u,
                                  &bytes)) {
        std::memcpy(assembly.records[index],
                    reinterpret_cast<const void*>(begin), bytes);
        std::memset(reinterpret_cast<uint8_t*>(assembly.records[index]) + bytes,
                    0, 2u);
        assembly.encodings[index] = encoding;
        assembly.lengths[index] = bytes;
        copied = true;
      }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
    if (!copied) assembly.clean = false;
#endif
    if (assembly.count == assembly.record_count) {
      if (assembly.clean) {
        SubmitLucaAssemblyLocked(assembly);
      } else {
        NoteLucaDiag(kLucaDiagRecordRejected);
      }
      assembly.open = false;
    }
  }
  ReleaseSRWLockExclusive(&rt.assembly_lock);
  return value;
}

// ── HookWorker ─────────────────────────────────────────────────────────────

const char* LucaSiteResultName(luca::MessageSiteResult result) {
  switch (result) {
    case luca::MessageSiteResult::kResolved: return "resolved";
    case luca::MessageSiteResult::kMissing: return "missing";
    case luca::MessageSiteResult::kAmbiguous: return "ambiguous";
    case luca::MessageSiteResult::kBadTarget: return "bad-target";
  }
  return "?";
}

// One scan of the loaded image.  `kMissing` is retried while the window lasts
// (the code may still be encrypted); every other result is final.
bool ResolveLucaSites() {
  auto& rt = g_luca;
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  if (!fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          GetModuleHandleW(nullptr), &image,
          fushi_voice_hook::exact_lookup::LoadedPeSectionExtent::kVirtualSize) ||
      image.machine !=
#if defined(_M_IX86)
          IMAGE_FILE_MACHINE_I386
#else
          IMAGE_FILE_MACHINE_AMD64
#endif
      ) {
    rt.site_result = luca::MessageSiteResult::kMissing;
    return false;
  }
  auto& spans = rt.spans;
  size_t& span_count = rt.span_count;
  span_count = 0u;
  for (size_t i = 0; i < image.section_count && span_count < spans.size();
       ++i) {
    const auto& section = image.sections[i];
    if (!fushi_voice_hook::exact_lookup::SectionHasRole(
            &section, IMAGE_SCN_MEM_EXECUTE) ||
        !fushi_voice_hook::exact_lookup::IsReadableSpan(section.bytes,
                                                        section.size)) {
      continue;
    }
    spans[span_count++] = {section.bytes, section.size, section.rva};
  }
  luca::MessageSites sites;
#if defined(_M_IX86)
  rt.site_result = luca::ResolveMessageSites(spans.data(), span_count, &sites);
#else
  luca::X64MessageSites x64;
  rt.site_result = luca::ResolveX64MessageSites(spans.data(), span_count, &x64);
  if (rt.site_result == luca::MessageSiteResult::kResolved) {
    if (x64.record_count_rva > image.size ||
        image.size - x64.record_count_rva < sizeof(uint32_t)) {
      rt.site_result = luca::MessageSiteResult::kBadTarget;
      return false;
    }
    const uint8_t* count = image.base + x64.record_count_rva;
    if (!fushi_voice_hook::exact_lookup::IsReadableSpan(count, sizeof(uint32_t))) {
      rt.site_result = luca::MessageSiteResult::kBadTarget;
      return false;
    }
    // Only the address is validated here; its value is still zero until the
    // engine finishes booting and is read per MESSAGE instead.
    rt.record_count = 0u;
    sites = x64.readers;
    rt.record_count_source = reinterpret_cast<const uint32_t*>(count);
  }
#endif
  if (rt.site_result != luca::MessageSiteResult::kResolved) return false;
  rt.sites = sites;
  rt.image_base = reinterpret_cast<uintptr_t>(image.base);
  rt.image_size = image.size;
  return true;
}

bool InstallLucaText() {
  auto& rt = g_luca;
  if (rt.hooks_installed) {
    rt.live.store(true, std::memory_order_release);
    return true;
  }
  if (rt.resolved) return false;  // a final rejection stays rejected
  const uint64_t now = GetTickCount64();
  if (rt.first_attempt_ms == 0u) rt.first_attempt_ms = now;
  if (rt.last_attempt_ms != 0u &&
      now - rt.last_attempt_ms < kLucaSiteRetryIntervalMs) {
    return false;
  }
  rt.last_attempt_ms = now;
  if (!ResolveLucaSites()) {
    const bool final_result =
        rt.site_result != luca::MessageSiteResult::kMissing ||
        now - rt.first_attempt_ms >= kLucaSiteRetryWindowMs;
    if (final_result) {
      rt.resolved = true;
      NoteLucaDiag(kLucaDiagSitesRejected);
      LucaLog(L"luca: MESSAGE site %hs after %llums",
              LucaSiteResultName(rt.site_result),
              static_cast<unsigned long long>(now - rt.first_attempt_ms));
    }
    return false;
  }
  rt.resolved = true;
  NoteLucaDiag(kLucaDiagSitesResolved);
  rt.voice_return = rt.image_base + rt.sites.voice_return;
  rt.record_return = rt.image_base + rt.sites.record_return;
  // Detours read `live` before touching any state; publish the state first.
  rt.live.store(true, std::memory_order_release);
  const bool hooked =
      HookFn(reinterpret_cast<void*>(rt.image_base + rt.sites.read_u16),
             reinterpret_cast<void*>(&LucaReadU16Detour),
             reinterpret_cast<void**>(&g_luca_read_u16_original)) &&
      HookFn(reinterpret_cast<void*>(rt.image_base + rt.sites.read_string),
             reinterpret_cast<void*>(&LucaReadStringDetour),
             reinterpret_cast<void**>(&g_luca_read_string_original));
  rt.hooks_installed = hooked;
  if (!hooked) rt.live.store(false, std::memory_order_release);
  if (hooked) {
    NoteLucaDiag(kLucaDiagHooksReady);
    if (!fushi_voice_hook::ReadLucaDesignSize(&rt.design_w, &rt.design_h)) {
      rt.design_w = rt.design_h = 0;
    }
    InstallLucaLookup(rt.spans.data(), rt.span_count);
  }
  LucaLog(L"luca: sites u16=+0x%lx str=+0x%lx voice_ret=+0x%lx "
          L"record_ret=+0x%lx hooks=%d after=%llums",
          static_cast<unsigned long>(rt.sites.read_u16),
          static_cast<unsigned long>(rt.sites.read_string),
          static_cast<unsigned long>(rt.sites.voice_return),
          static_cast<unsigned long>(rt.sites.record_return), hooked ? 1 : 0,
          static_cast<unsigned long long>(now - rt.first_attempt_ms));
  return hooked;
}

// Returns the text event the line is published under (0 = not published).
uint64_t PublishLucaTextLine(const std::wstring& text, uint64_t tick) {
  auto& rt = g_luca;
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || text.empty() ||
      text.size() * sizeof(wchar_t) > fushi_voice_hook::kTextSlotBytes) {
    return 0u;
  }
  if (text == rt.last_text && tick - rt.last_text_tick <= kLucaTextDedupeMs) {
    return 0u;
  }
  constexpr wchar_t kHookCode[] = L"ENGINE:LUCA:message";
  constexpr char kHookName[] = "LucaSystem exact";
  const uint64_t identity = rt.image_base + rt.sites.record_return;
  fushi_voice_hook::TextLaneWrite write;
  write.thread_id =
      fushi_voice_hook::NativeTextThreadIdFrom(identity, kHookCode, kHookName);
  write.thread_address = identity;
  write.thread_context = identity;
  write.process_id = GetCurrentProcessId();
  write.source_kind = fushi_voice_hook::kTextSourceLuca;
  write.is_utf8 = 0;
  write.text = text.data();
  write.byte_len = static_cast<uint32_t>(text.size() * sizeof(wchar_t));
  write.hook_name = kHookName;
  write.hook_code = kHookCode;
  EnterCriticalSection(&g_text_cs);
  const uint64_t event = fushi_voice_hook::WriteTextLaneEvent(
      g_header, fushi_voice_hook::kNativeThreadPreviewStart,
      fushi_voice_hook::kTextLaneCount, write);
  LeaveCriticalSection(&g_text_cs);
  if (event == 0u) return 0u;
  // An exact engine producer is live: the GDI glyph fallback yields.
  g_header->luna_active = 1;
  rt.last_text = text;
  rt.last_text_tick = tick;
  rt.last_text_event = event;
  NoteLucaDiag(kLucaDiagTextPublished);
  return event;
}

bool ReadLucaFileRange(const std::wstring& path, uint64_t offset,
                       uint32_t bytes, std::vector<uint8_t>* out) {
  HANDLE file = g_orig_CreateFileW(
      path.c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  out->assign(bytes, 0u);
  LARGE_INTEGER position = {};
  position.QuadPart = static_cast<LONGLONG>(offset);
  DWORD read = 0;
  const bool ok = SetFilePointerEx(file, position, nullptr, FILE_BEGIN) &&
                  ReadFile(file, out->data(), bytes, &read, nullptr) &&
                  read == bytes;
  CloseHandle(file);
  return ok;
}

// True when an OGGPAK or direct Ogg member starts with mono Vorbis.
// Reads only the member's head (the identification header is on the first
// page).
bool IsLucaMonoOggPakMember(const std::wstring& path,
                            const luca::PakEntry& entry) {
  constexpr uint32_t kHeadBytes = 512u;
  const uint32_t bytes = (std::min)(entry.length, kHeadBytes);
  std::vector<uint8_t> head;
  if (bytes <= luca::kOggPakMagicBytes + 8u ||
      !ReadLucaFileRange(path, entry.offset, bytes, &head)) {
    return false;
  }
  const size_t stream = luca::IsOggPakMember(head.data(), head.size())
                            ? luca::kOggPakMagicBytes + 8u : 0u;
  return luca::OggVorbisChannels(head.data() + stream,
                                 head.size() - stream) == 1u;
}

// The engine's line-voice archives: every files\*.pak whose index reads
// cleanly and whose first and last members start with mono Vorbis. Mono also
// includes some SE archives; only a unique MESSAGE voice ID establishes the
// resource used for a line. Loaded once, on first use.
void LoadLucaVoiceDirectory(const std::wstring& directory, size_t* scanned) {
  auto& rt = g_luca;
  WIN32_FIND_DATAW found = {};
  HANDLE search = FindFirstFileW((directory + L"\\*.pak").c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return;
  do {
    if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
    if (++(*scanned) > 64u) break;
    LucaVoiceArchive archive;
    archive.path = directory + L"\\" + found.cFileName;
    uint64_t size = 0u;
    std::vector<uint8_t> head;
    luca::PakIndex header;
    if (!fushi_voice_hook::engine_dir::FileSize(archive.path, &size) ||
        !ReadLucaFileRange(archive.path, 0u, luca::kPakHeaderBytes, &head) ||
        !luca::ParsePakHeader(head.data(), head.size(), size, &header) ||
        luca::PakIndexBytes(header) > fushi_voice_hook::kLucaProbeIndexBytes ||
        !ReadLucaFileRange(archive.path, 0u,
                           static_cast<uint32_t>(luca::PakIndexBytes(header)),
                           &head) ||
        luca::ParsePakIndex(head.data(), head.size(), size, &archive.index,
                            &archive.entries) != luca::PakIndexResult::kValid ||
        archive.entries.empty()) {
      continue;
    }
    if (!IsLucaMonoOggPakMember(archive.path, archive.entries.front()) ||
        !IsLucaMonoOggPakMember(archive.path, archive.entries.back())) {
      continue;
    }
    LucaLog(L"luca: voice archive %ls ids=%u..%u",
            found.cFileName, archive.index.id_start,
            archive.index.id_start + archive.index.count - 1u);
    rt.archives.push_back(std::move(archive));
  } while (FindNextFileW(search, &found));
  FindClose(search);
}

// A mono candidate is not classified as voice until the MESSAGE voice ID
// addresses a validated member in exactly one archive.
void LoadLucaVoiceArchives() {
  auto& rt = g_luca;
  if (rt.archives_loaded) return;
  rt.archives_loaded = true;
  std::wstring directory;
  if (!fushi_voice_hook::engine_dir::ModuleDirectory(&directory)) return;
  directory += L"\\files";
  size_t scanned = 0u;
  LoadLucaVoiceDirectory(directory, &scanned);
  WIN32_FIND_DATAW found = {};
  HANDLE search = FindFirstFileW((directory + L"\\*").c_str(), &found);
  if (search != INVALID_HANDLE_VALUE) {
    size_t directories = 0u;
    do {
      if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
          (found.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
          std::wcscmp(found.cFileName, L".") == 0 ||
          std::wcscmp(found.cFileName, L"..") == 0) continue;
      if (++directories > 32u || scanned >= 64u) break;
      LoadLucaVoiceDirectory(directory + L"\\" + found.cFileName, &scanned);
    } while (FindNextFileW(search, &found));
    FindClose(search);
  }
  if (!rt.archives.empty()) NoteLucaDiag(kLucaDiagVoiceArchivesReady);
}

void PublishLucaVoice(uint32_t voice_id, uint64_t tick, uint64_t text_event) {
  auto& rt = g_luca;
  LoadLucaVoiceArchives();
  const LucaVoiceArchive* owner = nullptr;
  int64_t member = -1;
  for (const LucaVoiceArchive& archive : rt.archives) {
    const int64_t candidate = luca::PakMemberForId(archive.index, voice_id);
    if (candidate < 0) continue;
    if (owner != nullptr) {  // two archives claim the id: neither is trusted
      NoteLucaDiag(kLucaDiagVoiceRejected);
      LucaLog(L"luca: voice id %u claimed by two archives", voice_id);
      return;
    }
    owner = &archive;
    member = candidate;
  }
  if (owner == nullptr) {
    NoteLucaDiag(kLucaDiagVoiceArchiveMissing);
    LucaLog(L"luca: voice id %u has no archive", voice_id);
    return;
  }
  const luca::PakEntry& entry = owner->entries[static_cast<size_t>(member)];
  std::vector<uint8_t> data;
  std::vector<luca::OggPakStream> streams;
  if (entry.length == 0u || entry.length > kLucaVoiceMemberBytes ||
      !ReadLucaFileRange(owner->path, entry.offset, entry.length, &data)) {
    NoteLucaDiag(kLucaDiagVoiceRejected);
    LucaLog(L"luca: voice id %u member rejected", voice_id);
    return;
  }
  if (!luca::ParseOggPakMember(data.data(), data.size(), &streams)) {
    luca::OggPakStream direct;
    if (!luca::ParseDirectOggMember(data.data(), data.size(), &direct)) {
      NoteLucaDiag(kLucaDiagVoiceRejected);
      return;
    }
    streams = {direct};
  }
  const luca::OggPakStream* stream = luca::PickOggPakStream(streams, 0u);
  if (stream == nullptr ||
      luca::OggVorbisChannels(data.data() + stream->offset, stream->length) !=
          1u) {
    NoteLucaDiag(kLucaDiagVoiceRejected);
    LucaLog(L"luca: voice id %u is not a mono line", voice_id);
    return;
  }
  wchar_t name[64] = {};
  _snwprintf_s(name, _TRUNCATE, L"luca_voice_%u.ogg", voice_id);
  if (WriteVoiceOggAt(data.data() + stream->offset, stream->length, name, tick,
                      text_event)) {
    NoteLucaDiag(kLucaDiagVoicePublished);
    // The bytes are the engine's own resource for this line, so the host can
    // pair per line instead of falling back to PCM / loopback.
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagGameResourcePublished);
  }
}

void ProcessLucaMessage(const LucaMessageSlot& slot) {
  if (slot.record_count == 0u || slot.record_count > luca::kMaxMessageRecords) return;
  std::wstring records[luca::kMaxMessageRecords];
  for (uint32_t i = 0; i < slot.record_count; ++i) {
    if (slot.encodings[i] == 3u) {
      records[i].assign(slot.records[i], slot.lengths[i] / sizeof(wchar_t));
    } else if (slot.encodings[i] == 2u && slot.lengths[i] != 0u) {
      const char* bytes = reinterpret_cast<const char*>(slot.records[i]);
      const int chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes,
                                           static_cast<int>(slot.lengths[i]), nullptr, 0);
      if (chars <= 0) return;
      records[i].resize(static_cast<size_t>(chars));
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes,
                          static_cast<int>(slot.lengths[i]), records[i].data(), chars);
    }
  }
#if defined(_M_X64)
  const uint32_t pick = g_luca.japanese_record.Select(
      records, slot.record_count, slot.vm_identity);
#else
  const uint32_t pick = luca::PickJapaneseRecord(records, slot.record_count);
#endif
  if (pick >= slot.record_count) {
    NoteLucaDiag(kLucaDiagRecordRejected);
    return;
  }
  const luca::MessageText text = luca::DecodeMessageRecord(
      records[pick],
#if defined(_M_X64)
      true
#else
      false
#endif
  );
  const uint64_t event = PublishLucaTextLine(text.body, slot.tick);
  if (event != 0u) {
    LucaLog(L"luca: MESSAGE event=%llu voice=%u record=%u/%u units=%zu",
            static_cast<unsigned long long>(event), slot.voice_id, pick,
            slot.record_count, text.body.size());
  }
  if (event != 0u && slot.voice_id != 0u) {
    PublishLucaVoice(slot.voice_id, slot.tick, event);
  }
}

// Pending slots in VM order.
void DrainLucaMessages() {
  for (;;) {
    LucaMessageSlot* next = nullptr;
    for (LucaMessageSlot& slot : g_luca_slots) {
      if (InterlockedCompareExchange(&slot.state, 2, 2) != 2) continue;
      if (next == nullptr || slot.order < next->order) next = &slot;
    }
    if (next == nullptr) return;
    if (InterlockedCompareExchange(&next->state, 3, 2) != 2) continue;
    ProcessLucaMessage(*next);
    InterlockedExchange(&next->state, 0);
  }
}

#else  // Unsupported Windows architecture.

volatile LONG g_luca_diag = 0;
bool InstallLucaText() { return false; }
void DrainLucaMessages() {}
void ProcessLucaLookupTick() {}
void ShutdownLucaLookup() {}
bool LucaLookupSensorInstalled() { return false; }
bool LucaLookupSitesRejected() { return false; }
bool FilterLucaLeftButtonSample(int16_t*, uintptr_t) { return false; }

#endif

class LucaAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "luca"; }
  // The identity is a property of the files next to the executable: measured
  // once, then reused by install() and diagnostics() (which may run on
  // different threads; two first calls racing only measure twice).
  bool probe() const override {
    int state = probe_state_.load(std::memory_order_acquire);
    if (state == 0) {
      state = fushi_voice_hook::MatchesLucaProfile(nullptr) ? 1 : 2;
      probe_state_.store(state, std::memory_order_release);
    }
    return state == 1;
  }
  bool install() override {
    if (!probe()) return false;
#if defined(_M_IX86) || defined(_M_X64)
    NoteLucaDiag(kLucaDiagIdentityMatched);
#endif
    installed_ = InstallLucaText() || installed_;
    return installed_;
  }
  // HookWorker: finish a deferred site resolution, then drain messages.
  void ProcessPendingEvents() {
    if (!installed_) {
      if (!probe()) return;
      installed_ = InstallLucaText();
      if (!installed_) return;
    }
    DrainLucaMessages();
    ProcessLucaLookupTick();
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    if (LucaLookupSensorInstalled()) {
      report.state = fushi_voice_hook::kLookupAdmissionSensorInstalled;
      return report;
    }
    if (LucaLookupSitesRejected()) {
      report.state = fushi_voice_hook::kLookupAdmissionIdentityRejected;
      strncpy_s(report.executable_sha256,
                fushi_voice_hook::HostExecutableSha256Hex(), _TRUNCATE);
      return report;
    }
    report.state = probe() ? fushi_voice_hook::kLookupAdmissionIdentityAccepted
                           : fushi_voice_hook::kLookupAdmissionEngineUnsupported;
    return report;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
#if defined(_M_IX86) || defined(_M_X64)
    g_luca.live.store(false, std::memory_order_release);
#endif
#if defined(_M_X64)
    g_luca.japanese_record.Reset();
#endif
    ShutdownLucaLookup();
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(
                InterlockedCompareExchange(&g_luca_diag, 0, 0))};
  }

 private:
  mutable std::atomic<int> probe_state_{0};  // 0 unmeasured, 1 Luca, 2 not
  bool installed_ = false;
};
