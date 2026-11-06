// knife - Rust reimplementation of the Switch engine of "Tsukihime -A piece of
// blue glass moon-" (AuroraWright/knife). wgpu/Vulkan draws every glyph from
// its own font atlas and cpal plays decoded PCM, so neither LunaHook nor the
// generic audio layers see the script. The engine instead offers both pieces
// at clean boundaries (contract in knife_core.h):
//
//   text  - its own WebSocket text server. An in-process WinHTTP client on an
//           adapter-owned thread publishes each message into an exact lane.
//   voice - the loose `stream/<voice id>.opus` file read just before the
//           message text is sent. The shared kernel file broker
//           (siglus_adapter.inc) only copies the path into a fixed slot; the
//           text thread pairs it with the text it precedes, rewraps the
//           Nintendo Opus payload as Ogg Opus and dumps it with the committed
//           TextSlot seq, so the host pairs it by event id, not by time.
//
// The text server is knife's opt-in option (`text-websocket` in knife.ini or
// `-t HOST:PORT`); without it there is no text and the adapter says so in its
// diagnostics instead of guessing.

#include <winhttp.h>

#include "knife_core.h"
#include "knife_profile.h"

constexpr uint32_t kKnifeDiagIdentity = 1u << 0;
constexpr uint32_t kKnifeDiagWebSocketUnconfigured = 1u << 1;
constexpr uint32_t kKnifeDiagWebSocketAddressInvalid = 1u << 2;
constexpr uint32_t kKnifeDiagFileHooksReady = 1u << 3;
constexpr uint32_t kKnifeDiagConnected = 1u << 4;
constexpr uint32_t kKnifeDiagConnectFailed = 1u << 5;
constexpr uint32_t kKnifeDiagTextPublished = 1u << 6;
constexpr uint32_t kKnifeDiagVoiceObserved = 1u << 7;
constexpr uint32_t kKnifeDiagVoiceWritten = 1u << 8;
constexpr uint32_t kKnifeDiagVoiceRejected = 1u << 9;

constexpr int kKnifeVoiceSlots = 16;
constexpr size_t kKnifeVoicePathChars = 1024;
constexpr wchar_t kKnifeHookCode[] = L"ENGINE:KNIFE:text_websocket";
constexpr char kKnifeHookName[] = "knife exact";

volatile LONG g_knife_diag = 0;
volatile LONG g_knife_voice_active = 0;
volatile LONG g_knife_stop = 0;
HANDLE g_knife_thread = nullptr;
HANDLE g_knife_stop_event = nullptr;
PVOID volatile g_knife_socket = nullptr;  // HINTERNET; owner closes it once
std::wstring g_knife_ws_host;
uint16_t g_knife_ws_port = 0;

// Filled by the kernel file detour on a game thread: claim (0->1), copy the
// bounded path, publish (->2). Consumed by the text thread (2->3->0).
struct KnifeVoiceSlot {
  volatile LONG state = 0;
  uint64_t tick_ms = 0;
  wchar_t path[kKnifeVoicePathChars] = {0};
};
KnifeVoiceSlot g_knife_voice_slots[kKnifeVoiceSlots];

void KnifeDiag(uint32_t bit) {
  InterlockedOr(&g_knife_diag, static_cast<LONG>(bit));
}

// Budgeted lines in the shared %TEMP%\fushi_galhook.log: lifecycle, event ids
// and voice ids only, never the script text. Text thread only.
constexpr int kKnifeLogBudget = 400;
int g_knife_logged = 0;

void KnifeLog(const wchar_t* format, ...) {
  if (g_knife_logged >= kKnifeLogBudget) return;
  ++g_knife_logged;
  wchar_t line[1024] = {};
  va_list args;
  va_start(args, format);
  _vsnwprintf_s(line, _TRUNCATE, format, args);
  va_end(args);
  wchar_t path[MAX_PATH] = {};
  const DWORD length = GetTempPathW(MAX_PATH, path);
  if (length == 0 || length >= MAX_PATH - 20) return;
  wcscat_s(path, L"fushi_galhook.log");
  auto open = g_orig_CreateFileW != nullptr ? g_orig_CreateFileW : &CreateFileW;
  auto close = g_orig_CloseHandle != nullptr ? g_orig_CloseHandle : &CloseHandle;
  HANDLE file = open(path, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                     OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME now = {};
  GetLocalTime(&now);
  wchar_t stamped[1200] = {};
  _snwprintf_s(stamped, _TRUNCATE, L"%02u:%02u:%02u.%03u pid=%lu knife: %s\r\n",
               now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
               GetCurrentProcessId(), line);
  char utf8[3600] = {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, stamped, -1, utf8,
                                        sizeof(utf8), nullptr, nullptr);
  if (bytes > 1) {
    DWORD written = 0;
    WriteFile(file, utf8, static_cast<DWORD>(bytes - 1), &written, nullptr);
  }
  close(file);
}

// Shared broker hook (siglus_adapter.inc Detour_CreateFileW/A).
void RememberKnifeVoice(HANDLE, const wchar_t* path) {
  if (InterlockedCompareExchange(&g_knife_voice_active, 0, 0) == 0 ||
      !fushi_voice_hook::knife::IsVoiceStreamPath(path) ||
      wcslen(path) >= kKnifeVoicePathChars) {
    return;
  }
  const uint64_t now = GetTickCount64();
  for (KnifeVoiceSlot& slot : g_knife_voice_slots) {
    if (InterlockedCompareExchange(&slot.state, 1, 0) != 0) continue;
    slot.tick_ms = now;
    wcsncpy_s(slot.path, path, _TRUNCATE);
    MemoryBarrier();
    InterlockedExchange(&slot.state, 2);
    KnifeDiag(kKnifeDiagVoiceObserved);
    return;
  }
  // Every slot holds an unpaired voice: the text thread is gone or stalled.
  // Dropping is the bounded answer; the next text frees the stale ones.
}

uint64_t PublishKnifeText(const std::wstring& text) {
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || text.empty() ||
      text.size() * sizeof(wchar_t) > fushi_voice_hook::kTextSlotBytes) {
    return 0u;
  }
  // One message system per process: the lane identity is the server port.
  fushi_voice_hook::TextLaneWrite write;
  write.thread_id = fushi_voice_hook::NativeTextThreadIdFrom(
      g_knife_ws_port, kKnifeHookCode, kKnifeHookName);
  write.thread_address = g_knife_ws_port;
  write.thread_context = g_knife_ws_port;
  write.process_id = GetCurrentProcessId();
  write.source_kind = fushi_voice_hook::kTextSourceKnife;
  write.is_utf8 = 0;
  write.text = text.data();
  write.byte_len = static_cast<uint32_t>(text.size() * sizeof(wchar_t));
  write.hook_name = kKnifeHookName;
  write.hook_code = kKnifeHookCode;
  EnterCriticalSection(&g_text_cs);
  const uint64_t event = fushi_voice_hook::WriteTextLaneEvent(
      g_header, fushi_voice_hook::kNativeThreadPreviewStart,
      fushi_voice_hook::kTextLaneCount, write);
  LeaveCriticalSection(&g_text_cs);
  if (event == 0u) return 0u;
  // An exact producer is live: the GDI glyph fallback yields.
  g_header->luna_active = 1;
  KnifeDiag(kKnifeDiagTextPublished);
  return event;
}

// Takes the voice read for the text published now and frees every other
// ready slot read no later than it (older ones are replay / config-test
// voices; see knife_core.h). A slot read after [text_tick] belongs to the next
// line and is handed back untouched.
bool TakeKnifeVoiceForText(uint64_t text_tick, std::wstring* path,
                           uint64_t* voice_tick) {
  std::vector<uint64_t> ticks;
  std::vector<int> slots;
  for (int i = 0; i < kKnifeVoiceSlots; ++i) {
    KnifeVoiceSlot& slot = g_knife_voice_slots[i];
    if (InterlockedCompareExchange(&slot.state, 3, 2) != 2) continue;
    if (slot.tick_ms > text_tick) {
      InterlockedExchange(&slot.state, 2);
      continue;
    }
    ticks.push_back(slot.tick_ms);
    slots.push_back(i);
  }
  const int pick = fushi_voice_hook::knife::SelectVoiceForText(ticks, text_tick);
  if (pick >= 0) {
    path->assign(g_knife_voice_slots[slots[pick]].path);
    *voice_tick = ticks[static_cast<size_t>(pick)];
  }
  for (int index : slots) InterlockedExchange(&g_knife_voice_slots[index].state, 0);
  return pick >= 0;
}

bool ReadKnifeVoiceFile(const std::wstring& path, std::vector<uint8_t>* out) {
  auto open = g_orig_CreateFileW != nullptr ? g_orig_CreateFileW : &CreateFileW;
  auto close = g_orig_CloseHandle != nullptr ? g_orig_CloseHandle : &CloseHandle;
  HANDLE file = open(path.c_str(), GENERIC_READ,
                     FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                     nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size = {};
  bool ok = GetFileSizeEx(file, &size) != FALSE && size.QuadPart > 0 &&
            size.QuadPart <= fushi_voice_hook::knife::kMaxVoiceFileBytes;
  if (ok) {
    out->resize(static_cast<size_t>(size.QuadPart));
    DWORD done = 0;
    ok = ReadFile(file, out->data(), static_cast<DWORD>(out->size()), &done,
                  nullptr) != FALSE &&
         done == out->size();
  }
  close(file);
  return ok;
}

void ExportKnifeVoice(const std::wstring& path, uint64_t text_tick,
                      uint64_t voice_tick, uint64_t text_event) {
  std::vector<uint8_t> nopus;
  std::vector<uint8_t> ogg;
  if (!ReadKnifeVoiceFile(path, &nopus) ||
      !fushi_voice_hook::knife::RemuxNintendoOpusToOgg(
          nopus.data(), nopus.size(), static_cast<uint32_t>(text_event), &ogg)) {
    KnifeDiag(kKnifeDiagVoiceRejected);
    KnifeLog(L"voice rejected %s bytes=%zu",
             fushi_voice_hook::knife::PathBaseName(path.c_str()), nopus.size());
    return;
  }
  const wchar_t* base = fushi_voice_hook::knife::PathBaseName(path.c_str());
  const bool written = WriteVoiceOggAt(
      ogg.data(), static_cast<uint32_t>(ogg.size()), base, text_tick,
      text_event);
  if (written) {
    KnifeDiag(kKnifeDiagVoiceWritten);
    // The bytes are the engine's own resource for this line: the host pairs per
    // line instead of staying on the loopback fallback.
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagGameResourcePublished);
  }
  KnifeLog(L"voice %s event=%llu gap_ms=%llu nopus=%zu ogg=%zu written=%d",
           base, static_cast<unsigned long long>(text_event),
           static_cast<unsigned long long>(text_tick - voice_tick),
           nopus.size(), ogg.size(), written ? 1 : 0);
}

void HandleKnifeMessage(const std::string& utf8) {
  if (utf8.empty()) return;
  const int units = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                        static_cast<int>(utf8.size()), nullptr,
                                        0);
  if (units <= 0) return;
  std::wstring text(static_cast<size_t>(units), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      text.data(), units);
  const uint64_t tick = GetTickCount64();
  std::wstring voice;
  uint64_t voice_tick = 0;
  const bool has_voice = TakeKnifeVoiceForText(tick, &voice, &voice_tick);
  const uint64_t event = PublishKnifeText(text);
  KnifeLog(L"text event=%llu units=%zu voice=%d",
           static_cast<unsigned long long>(event), text.size(),
           has_voice ? 1 : 0);
  if (has_voice && event != 0u) ExportKnifeVoice(voice, tick, voice_tick, event);
}

// One WebSocket session. Returns when the server closes or the adapter stops.
void RunKnifeWebSocketSession() {
  HINTERNET session = WinHttpOpen(L"Fushi galgame hook",
                                  WINHTTP_ACCESS_TYPE_NO_PROXY,
                                  WINHTTP_NO_PROXY_NAME,
                                  WINHTTP_NO_PROXY_BYPASS, 0);
  if (session == nullptr) return;
  // Finite receive timeout for the handshake: a peer that accepts TCP but
  // never answers must not park this thread where shutdown cannot reach it.
  // The upgraded socket switches to an indefinite receive below.
  WinHttpSetTimeouts(session, 2000, 2000, 2000, 2000);
  HINTERNET connect =
      WinHttpConnect(session, g_knife_ws_host.c_str(), g_knife_ws_port, 0);
  HINTERNET request =
      connect == nullptr
          ? nullptr
          : WinHttpOpenRequest(connect, L"GET", L"/", nullptr,
                               WINHTTP_NO_REFERER,
                               WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
  HINTERNET socket = nullptr;
  if (request != nullptr &&
      WinHttpSetOption(request, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr,
                       0) &&
      WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                         WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
      WinHttpReceiveResponse(request, nullptr)) {
    DWORD status = 0;
    DWORD status_size = sizeof(status);
    if (WinHttpQueryHeaders(request,
                            WINHTTP_QUERY_STATUS_CODE |
                                WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX, &status,
                            &status_size, WINHTTP_NO_HEADER_INDEX) &&
        status == HTTP_STATUS_SWITCH_PROTOCOLS) {
      socket = WinHttpWebSocketCompleteUpgrade(request, 0);
    }
  }
  const DWORD connect_error = socket == nullptr ? GetLastError() : 0;
  if (request != nullptr) WinHttpCloseHandle(request);
  if (socket == nullptr) {
    // The server may simply not be up yet: log the first failure only.
    if ((InterlockedCompareExchange(&g_knife_diag, 0, 0) &
         static_cast<LONG>(kKnifeDiagConnectFailed)) == 0) {
      KnifeLog(L"connect %s:%u failed (%lu)", g_knife_ws_host.c_str(),
               static_cast<unsigned>(g_knife_ws_port), connect_error);
    }
    KnifeDiag(kKnifeDiagConnectFailed);
  } else {
    KnifeDiag(kKnifeDiagConnected);
    KnifeLog(L"connected %s:%u", g_knife_ws_host.c_str(),
             static_cast<unsigned>(g_knife_ws_port));
    InterlockedExchangePointer(&g_knife_socket, socket);
    // The receive blocks indefinitely; shutdown closes the socket handle
    // from the other thread, which cancels it.
    WinHttpSetTimeouts(socket, 0, 0, 0, 0);
    std::string message;
    bool oversized = false;
    std::vector<uint8_t> buffer(16 * 1024);
    while (InterlockedCompareExchange(&g_knife_stop, 0, 0) == 0) {
      DWORD read = 0;
      WINHTTP_WEB_SOCKET_BUFFER_TYPE type = WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE;
      if (WinHttpWebSocketReceive(socket, buffer.data(),
                                  static_cast<DWORD>(buffer.size()), &read,
                                  &type) != NO_ERROR) {
        break;
      }
      if (type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) break;
      if (type != WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE &&
          type != WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE) {
        message.clear();
        oversized = false;
        continue;
      }
      // A text slot holds 1024 UTF-16 units; a message past that is not a
      // line, and is dropped whole rather than published with a gap.
      if (!oversized &&
          message.size() + read <= fushi_voice_hook::kTextSlotBytes * 2) {
        message.append(reinterpret_cast<const char*>(buffer.data()), read);
      } else {
        oversized = true;
        message.clear();
      }
      if (type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE) {
        if (!oversized) HandleKnifeMessage(message);
        message.clear();
        oversized = false;
      }
    }
    // Whoever takes the handle out of the slot closes it, exactly once.
    HINTERNET owned = static_cast<HINTERNET>(
        InterlockedExchangePointer(&g_knife_socket, nullptr));
    if (owned != nullptr) WinHttpCloseHandle(owned);
  }
  if (connect != nullptr) WinHttpCloseHandle(connect);
  WinHttpCloseHandle(session);
}

DWORD WINAPI KnifeTextThread(LPVOID) {
  // The hook can be injected before knife binds its server, and the player
  // may restart the server by relaunching: wait for the server, never spin.
  while (InterlockedCompareExchange(&g_knife_stop, 0, 0) == 0) {
    RunKnifeWebSocketSession();
    if (WaitForSingleObject(g_knife_stop_event, 1000) == WAIT_OBJECT_0) break;
  }
  return 0;
}

bool StartKnifeText(const std::wstring& address) {
  if (address.empty()) {
    KnifeDiag(kKnifeDiagWebSocketUnconfigured);
    return false;
  }
  if (!fushi_voice_hook::knife::SplitHostPort(address, &g_knife_ws_host,
                                              &g_knife_ws_port)) {
    KnifeDiag(kKnifeDiagWebSocketAddressInvalid);
    return false;
  }
  if (g_knife_thread != nullptr) return true;
  InterlockedExchange(&g_knife_stop, 0);
  g_knife_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (g_knife_stop_event == nullptr) return false;
  g_knife_thread = CreateThread(nullptr, 0, KnifeTextThread, nullptr, 0, nullptr);
  return g_knife_thread != nullptr;
}

void StopKnifeText() {
  InterlockedExchange(&g_knife_voice_active, 0);
  InterlockedExchange(&g_knife_stop, 1);
  if (g_knife_stop_event != nullptr) SetEvent(g_knife_stop_event);
  HINTERNET socket = static_cast<HINTERNET>(
      InterlockedExchangePointer(&g_knife_socket, nullptr));
  if (socket != nullptr) WinHttpCloseHandle(socket);
  if (g_knife_thread != nullptr) {
    WaitForSingleObject(g_knife_thread, INFINITE);
    CloseHandle(g_knife_thread);
    g_knife_thread = nullptr;
  }
  if (g_knife_stop_event != nullptr) {
    CloseHandle(g_knife_stop_event);
    g_knife_stop_event = nullptr;
  }
  for (KnifeVoiceSlot& slot : g_knife_voice_slots) {
    InterlockedCompareExchange(&slot.state, 0, 2);
  }
}

class KnifeAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "knife"; }
  // Identity is a property of the install layout: measured once, then reused
  // (install() and the Poll-time diagnostics() may run on different threads).
  bool probe() const override {
    int state = probe_state_.load(std::memory_order_acquire);
    if (state == 0) {
      state = fushi_voice_hook::MatchesKnifeProfile(nullptr) ? 1 : 2;
      probe_state_.store(state, std::memory_order_release);
    }
    return state == 1;
  }
  bool install() override {
    if (installed_ || !probe()) return installed_;
    KnifeDiag(kKnifeDiagIdentity);
    fushi_voice_hook::knife::ResolvedLaunch launch;
    fushi_voice_hook::knife::ResolveLaunch(&launch);
    // Voices are only ever consumed by the text thread: without the text
    // server there is nothing to pair them with, so the file hooks stay off.
    const bool text = StartKnifeText(launch.text_websocket);
    if (text && TryHookSiglusOvk()) {
      KnifeDiag(kKnifeDiagFileHooksReady);
      InterlockedExchange(&g_knife_voice_active, 1);
    }
    KnifeLog(L"install assets=%s websocket=%s file_hooks=%d text_thread=%d",
             launch.assets_dir.c_str(),
             launch.text_websocket.empty() ? L"(unset)"
                                           : launch.text_websocket.c_str(),
             InterlockedCompareExchange(&g_knife_voice_active, 0, 0) != 0 ? 1
                                                                           : 0,
             text ? 1 : 0);
    installed_ = text;
    return installed_;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    StopKnifeText();
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(InterlockedCompareExchange(&g_knife_diag, 0, 0))};
  }

 private:
  mutable std::atomic<int> probe_state_{0};  // 0 unmeasured, 1 knife, 2 not
  bool installed_ = false;
};
