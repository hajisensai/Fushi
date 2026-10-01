// BUG-2746: only the proven KiriKiri relative, Z-only SysMouse format.
// Replace this lossy DI aggregate with the host's event-owned outside total;
// never try to subtract a timed budget from the original aggregate.
std::atomic<bool> g_generic_kirikiri_wheel_enabled{false};
std::atomic<bool> g_kirikiri_z_only_wheel_observed{false};
std::atomic<uint32_t> g_wheel_diagnostic_budget{64};
struct WheelConsumer {
  void* identity = nullptr;
  fushi_voice_hook::LookupWheelCursor cursor;
  uint32_t diagnostics = 0;
  LONG raw = 0, delivered = 0;
  uint64_t diagnostic_generation = 0;
  bool diagnostic_pending = false, diagnostic_ready = false;
};
WheelConsumer g_wheel_consumers[32]{};
fushi_voice_hook::LookupWheelSource* g_wheel_source = nullptr;
HANDLE g_wheel_source_mapping = nullptr, g_wheel_source_ack = nullptr;
HANDLE g_wheel_source_host = nullptr;
DWORD g_wheel_source_host_pid = 0;
SRWLOCK g_wheel_consumer_lock = SRWLOCK_INIT;
std::atomic<fushi_voice_hook::LookupWheelSource*> g_wheel_source_published{nullptr};

void GenericWheelLogLine(const wchar_t* line) {
#if defined(_M_IX86)
  HookLogLine(line);
#else
  OutputDebugStringW(line);
#endif
}
void DrainWheelDiagnostics() {
  WheelConsumer pending[32]{};
  AcquireSRWLockExclusive(&g_wheel_consumer_lock);
  for (size_t i = 0; i < 32; ++i) {
    if (g_wheel_consumers[i].diagnostic_pending) pending[i] = g_wheel_consumers[i];
    g_wheel_consumers[i].diagnostic_pending = false;
  }
  ReleaseSRWLockExclusive(&g_wheel_consumer_lock);
  for (const auto& entry : pending) if (entry.diagnostic_pending) {
    wchar_t line[160]{};
    _snwprintf_s(line, _TRUNCATE, L"dinput.wheel_source bytes=4 identity=%p raw=%ld delivered=%ld generation=%llu ready=%d",
        entry.identity, entry.raw, entry.delivered, entry.diagnostic_generation, entry.diagnostic_ready ? 1 : 0);
    GenericWheelLogLine(line);
  }
}

void ResetWheelConsumer(void* identity) {
  if (!identity) return;
  AcquireSRWLockExclusive(&g_wheel_consumer_lock);
  for (auto& entry : g_wheel_consumers)
    if (entry.identity == identity) entry = {};
  ReleaseSRWLockExclusive(&g_wheel_consumer_lock);
}
void PrepareKirikiriWheelSource() {
  DrainWheelDiagnostics();
  if (!g_generic_kirikiri_wheel_enabled.load(std::memory_order_acquire)) return;
  if (!g_kirikiri_z_only_wheel_observed.load(std::memory_order_acquire)) return;
  HWND game = FindGameMainWindow();
  if (!game) return;
  SetPropW(game, fushi_voice_hook::kLookupWheelSourceRequiredProperty,
           reinterpret_cast<HANDLE>(1));
  if (g_wheel_source) return;
  wchar_t name[128]{};
  if (!fushi_voice_hook::WheelSourceName(GetCurrentProcessId(),
                                      GetCurrentProcess(), name, 128)) return;
  HANDLE mapping = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, name);
  if (!mapping) return;
  auto* source = static_cast<fushi_voice_hook::LookupWheelSource*>(
      MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(*g_wheel_source)));
  if (!source || source->magic != fushi_voice_hook::kLookupWheelSourceMagic ||
      source->game_pid != GetCurrentProcessId()) {
    if (source) UnmapViewOfFile(source);
    CloseHandle(mapping); return;
  }
  wcscat_s(name, L"_ready");
  g_wheel_source_ack = OpenEventW(EVENT_MODIFY_STATE, FALSE, name);
  g_wheel_source_mapping = mapping;
  g_wheel_source = source;
  g_wheel_source_published.store(source, std::memory_order_release);
}

void* WheelDeviceIdentity(void* device) {
  using Query = HRESULT(STDMETHODCALLTYPE*)(void*, REFIID, void**);
  using Release = ULONG(STDMETHODCALLTYPE*)(void*);
  static constexpr GUID unknown{0,0,0,{0xc0,0,0,0,0,0,0,0x46}};
  void* identity = nullptr;
  __try {
    const auto query = reinterpret_cast<Query>(VtableSlot(device, 0));
    if (!query || FAILED(query(device, unknown, &identity)) || !identity) return nullptr;
    reinterpret_cast<Release>(VtableSlot(identity, 2))(identity);
  } __except(EXCEPTION_EXECUTE_HANDLER) { return nullptr; }
  return identity; // canonical IUnknown token, not a retained COM reference
}
constexpr DWORD kGenericDirectInputDevTypeMouse7 = 2u;     // DIDEVTYPE_MOUSE
constexpr DWORD kGenericDirectInputDevTypeMouse8 = 0x12u;  // DI8DEVTYPE_MOUSE
constexpr int32_t kGenericWheelOffsetUnknown = -2;
constexpr int32_t kGenericWheelOffsetNone = -1;
constexpr DWORD kGenericWheelOffsetProbeLimit = 64;  // 标准布局 ≤ 20 字节，留足余量
using GenericDirectInputGetCapabilitiesFn =
    HRESULT(STDMETHODCALLTYPE *)(void *, LPDIDEVCAPS);
using GenericDirectInputGetPropertyFn =
    HRESULT(STDMETHODCALLTYPE *)(void *, REFGUID, LPDIPROPHEADER);
using GenericDirectInputGetObjectInfoFn =
    HRESULT(STDMETHODCALLTYPE *)(void *, void *, DWORD, DWORD);

struct GenericDirectInputKind {
  void *device = nullptr;
  bool mouse = false;
  void* identity = nullptr;
  int32_t wheel_offset = kGenericWheelOffsetUnknown;
};
constexpr size_t kGenericDirectInputKindCapacity = 16;
GenericDirectInputKind
    g_generic_direct_input_kinds[kGenericDirectInputKindCapacity] = {};
size_t g_generic_direct_input_kind_next = 0;
SRWLOCK g_generic_direct_input_kind_lock = SRWLOCK_INIT;

bool QueryGenericDirectInputIsMouse(void *device) {
  DIDEVCAPS caps{};
  caps.dwSize = sizeof(caps);
  __try {
    const auto get_caps = reinterpret_cast<GenericDirectInputGetCapabilitiesFn>(
        VtableSlot(device, 3));
    if (get_caps == nullptr || FAILED(get_caps(device, &caps)))
      return false;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  const DWORD type = GET_DIDEVICE_TYPE(caps.dwDevType);
  if (type != kGenericDirectInputDevTypeMouse7 &&
      type != kGenericDirectInputDevTypeMouse8) return false;
  alignas(8) uint8_t info[sizeof(DIDEVICEINSTANCEW)]{};
  constexpr DWORD sizes[] = {sizeof(DIDEVICEINSTANCEW), sizeof(DIDEVICEINSTANCEA),
      sizeof(DIDEVICEINSTANCE_DX3W), sizeof(DIDEVICEINSTANCE_DX3A)};
  static constexpr GUID sys{0x6f1d2b60u,0xd5a0u,0x11cfu,
      {0xbfu,0xc7u,0x44u,0x45u,0x53u,0x54u,0,0}};
  using GetInfo = HRESULT(STDMETHODCALLTYPE*)(void*, void*);
  __try {
    const auto get = reinterpret_cast<GetInfo>(VtableSlot(device, 15));
    if (!get) return false;
    for (DWORD size : sizes) {
      memcpy(info, &size, sizeof(size));
      if (SUCCEEDED(get(device, info))) {
        GUID instance{}; memcpy(&instance, info + sizeof(DWORD), sizeof(instance));
        return InlineIsEqualGUID(instance, sys) != FALSE;
      }
    }
  } __except(EXCEPTION_EXECUTE_HANDLER) {}
  return false;
}

enum class WheelAxisMode { kUnknown, kRelative, kAbsolute };
WheelAxisMode GenericDirectInputRelativeMode(void *device) {
  // 绝对轴模式下 Z 是累计值：清零会在光标进出浮窗时制造两次大跳变。只处理默认的
  // 相对模式；无法确认模式时保留原数据。
  DIPROPDWORD mode{};
  mode.diph.dwSize = sizeof(mode);
  mode.diph.dwHeaderSize = sizeof(mode.diph);
  mode.diph.dwObj = 0;
  mode.diph.dwHow = DIPH_DEVICE;
  __try {
    const auto get_property = reinterpret_cast<GenericDirectInputGetPropertyFn>(
        VtableSlot(device, 5));
    if (get_property && SUCCEEDED(get_property(device, DIPROP_AXISMODE, &mode.diph)))
      return mode.dwData == DIPROPAXISMODE_REL ? WheelAxisMode::kRelative :
          (mode.dwData == DIPROPAXISMODE_ABS ? WheelAxisMode::kAbsolute : WheelAxisMode::kUnknown);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  return WheelAxisMode::kUnknown;
}

// 当前数据格式里 |offset| 处的对象是不是 Z 轴。A/W 设备的 DIDEVICEOBJECTINSTANCE
// 大小不同、又不知道是哪一种，按候选 dwSize 逐个试到成功为止；guidType 在两者里都紧跟
// dwSize，读法一致。
bool GenericDirectInputOffsetIsZAxis(void *device, DWORD offset) {
  static constexpr GUID kZAxis = {
      0xa36d02e2u,
      0xc9f3u,
      0x11cfu,
      {0xbfu, 0xc7u, 0x44u, 0x45u, 0x53u, 0x54u, 0x00u, 0x00u}};
  static constexpr DWORD kInstanceSizes[] = {
      sizeof(DIDEVICEOBJECTINSTANCEW), sizeof(DIDEVICEOBJECTINSTANCEA),
      sizeof(DIDEVICEOBJECTINSTANCE_DX3W), sizeof(DIDEVICEOBJECTINSTANCE_DX3A)};
  alignas(8) uint8_t buffer[sizeof(DIDEVICEOBJECTINSTANCEW)] = {};
  __try {
    const auto get_object = reinterpret_cast<GenericDirectInputGetObjectInfoFn>(
        VtableSlot(device, 14));
    if (get_object == nullptr)
      return false;
    for (const DWORD size : kInstanceSizes) {
      memset(buffer, 0, sizeof(buffer));
      memcpy(buffer, &size, sizeof(size));
      const HRESULT hr = get_object(device, buffer, offset, DIPH_BYOFFSET);
      if (hr == DIERR_INVALIDPARAM)
        continue;  // dwSize 不是这台设备认的那一种，换下一个
      if (FAILED(hr))
        return false;  // 这个偏移上没有对象
      GUID type{};
      memcpy(&type, buffer + sizeof(DWORD), sizeof(type));
      return InlineIsEqualGUID(type, kZAxis) != FALSE;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  return false;
}

GenericDirectInputKind *FindGenericDirectInputKindLocked(void *device) {
  for (auto &kind : g_generic_direct_input_kinds) {
    if (kind.device == device)
      return &kind;
  }
  return nullptr;
}

GenericDirectInputKind *AdoptGenericDirectInputKindLocked(void *device) {
  if (auto *existing = FindGenericDirectInputKindLocked(device))
    return existing;
  for (auto &kind : g_generic_direct_input_kinds) {
    if (kind.device == nullptr) {
      ResetWheelConsumer(kind.identity);
      kind = GenericDirectInputKind{};
      kind.device = device;
      return &kind;
    }
  }
  // 满了按轮转覆盖：否则此后每格滚轮都要重新查询设备。
  auto &slot = g_generic_direct_input_kinds[g_generic_direct_input_kind_next];
  g_generic_direct_input_kind_next =
      (g_generic_direct_input_kind_next + 1) % kGenericDirectInputKindCapacity;
  ResetWheelConsumer(slot.identity);
  slot = GenericDirectInputKind{};
  slot.device = device;
  return &slot;
}

bool GenericDirectInputDeviceIsMouse(void *device) {
  if (device == nullptr)
    return false;
  AcquireSRWLockShared(&g_generic_direct_input_kind_lock);
  const auto *cached = FindGenericDirectInputKindLocked(device);
  if (cached != nullptr) {
    const bool mouse = cached->mouse;
    ReleaseSRWLockShared(&g_generic_direct_input_kind_lock);
    return mouse;
  }
  ReleaseSRWLockShared(&g_generic_direct_input_kind_lock);
  const bool mouse = QueryGenericDirectInputIsMouse(device);
  AcquireSRWLockExclusive(&g_generic_direct_input_kind_lock);
  AdoptGenericDirectInputKindLocked(device)->mouse = mouse;
  ReleaseSRWLockExclusive(&g_generic_direct_input_kind_lock);
  return mouse;
}

// 当前格式里 Z 轴的偏移；没有则 -1。|candidates| 是本次调用里可能的偏移（即时状态按
// 4 字节步长覆盖返回的大小；缓冲事件用事件里实际出现的 dwOfs），只在第一次查询时用。
int32_t GenericDirectInputWheelOffset(void *device, const DWORD *candidates,
                                      size_t candidate_count, bool complete_format) {
  AcquireSRWLockShared(&g_generic_direct_input_kind_lock);
  const auto *cached = FindGenericDirectInputKindLocked(device);
  const int32_t known = cached != nullptr ? cached->wheel_offset
                                          : kGenericWheelOffsetUnknown;
  ReleaseSRWLockShared(&g_generic_direct_input_kind_lock);
  if (known != kGenericWheelOffsetUnknown)
    return known;
  int32_t found = kGenericWheelOffsetNone;
  for (size_t i = 0; i < candidate_count; ++i) {
    if (candidates[i] < kGenericWheelOffsetProbeLimit &&
        GenericDirectInputOffsetIsZAxis(device, candidates[i])) {
      found = static_cast<int32_t>(candidates[i]);
      break;
    }
  }
  // 只有即时状态那条路覆盖了完整格式，才能把「没找到」记成定论；缓冲事件只看到了
  // 部分偏移，没找到时不缓存，留给下一次。
  AcquireSRWLockExclusive(&g_generic_direct_input_kind_lock);
  auto *kind = AdoptGenericDirectInputKindLocked(device);
  const bool settled = found != kGenericWheelOffsetNone || complete_format;
  if (settled)
    kind->wheel_offset = found;
  ReleaseSRWLockExclusive(&g_generic_direct_input_kind_lock);
  return found;
}

void ForgetGenericDirectInputKind(void *device) {
  AcquireSRWLockExclusive(&g_generic_direct_input_kind_lock);
  for (auto &kind : g_generic_direct_input_kinds) {
    if (kind.device == device) {
      ResetWheelConsumer(kind.identity);
      kind = GenericDirectInputKind{};
    }
  }
  ReleaseSRWLockExclusive(&g_generic_direct_input_kind_lock);
}


void StripHostOverlayWheelFromMouseState(void* device, DWORD bytes, LPVOID state) {
  if (!state || bytes != sizeof(LONG) ||
      !g_generic_kirikiri_wheel_enabled.load(std::memory_order_acquire) ||
      !GenericDirectInputDeviceIsMouse(device)) return;
  const DWORD candidate = 0;
  if (GenericDirectInputWheelOffset(device, &candidate, 1, true) != 0) return;
  void* identity = WheelDeviceIdentity(device);
  if (!identity) return;
  AcquireSRWLockExclusive(&g_generic_direct_input_kind_lock);
  AdoptGenericDirectInputKindLocked(device)->identity = identity;
  ReleaseSRWLockExclusive(&g_generic_direct_input_kind_lock);
  const auto mode = GenericDirectInputRelativeMode(device);
  if (mode != WheelAxisMode::kRelative) {
    ResetWheelConsumer(identity);
    if (mode == WheelAxisMode::kUnknown && g_wheel_source_published.load()) {
      LONG neutral = 0; memcpy(state, &neutral, sizeof(neutral));
    }
    return;
  }
  if (!g_kirikiri_z_only_wheel_observed.load(std::memory_order_acquire)) {
    // Mark the requirement at first proven real poll, before a popup can
    // mistake the worker's next tick for a non-DirectInput wheel engine.
    HWND game = FindGameMainWindow();
    if (game) SetPropW(game, fushi_voice_hook::kLookupWheelSourceRequiredProperty,
                      reinterpret_cast<HANDLE>(1));
    g_kirikiri_z_only_wheel_observed.store(true, std::memory_order_release);
  }
  auto* source = g_wheel_source_published.load(std::memory_order_acquire);
  if (!source) return; // No admitted popup can reveal before source ack.
  DWORD foreground_pid = 0;
  GetWindowThreadProcessId(GetForegroundWindow(), &foreground_pid);
  if (foreground_pid != GetCurrentProcessId()) {
    ResetWheelConsumer(identity);
    LONG neutral = 0; memcpy(state, &neutral, sizeof(neutral));
    return;
  }
  auto snapshot = fushi_voice_hook::ReadWheelSource(source);
  // A crashed host cannot leave a ready mapping producing permanent silence.
  // The original DI buffer is still drained on every call. Producer loss stays
  // neutral until reconnection; raw zero does not prove an LL event settled.
  AcquireSRWLockExclusive(&g_wheel_consumer_lock);
  const DWORD host_pid = fushi_voice_hook::LoadWheelWord(&source->host_pid);
  if (host_pid != g_wheel_source_host_pid) {
    if (g_wheel_source_host) CloseHandle(g_wheel_source_host);
    g_wheel_source_host_pid = host_pid;
    g_wheel_source_host = OpenProcess(SYNCHRONIZE, FALSE, host_pid);
  }
  if (source && (!g_wheel_source_host ||
      WaitForSingleObject(g_wheel_source_host, 0) != WAIT_TIMEOUT)) snapshot.ready = false;
  WheelConsumer* consumer = nullptr;
  for (auto& entry : g_wheel_consumers)
    if (entry.identity == identity) { consumer = &entry; break; }
  if (!consumer) for (auto& entry : g_wheel_consumers)
    if (!entry.identity) { entry.identity = identity; consumer = &entry; break; }
  LONG raw = 0; memcpy(&raw, state, sizeof(raw));
  const LONG filtered = consumer ?
      fushi_voice_hook::ConsumeOutsideWheel(snapshot, raw, &consumer->cursor) : 0;
  memcpy(state, &filtered, sizeof(filtered));
  if (source && snapshot.coherent && snapshot.ready && consumer && consumer->cursor.bound) {
    fushi_voice_hook::StoreWheelTotal(&source->consumer_generation, snapshot.generation);
    fushi_voice_hook::StoreWheelWord(&source->consumer_ready, 1);
    if (g_wheel_source_ack) SetEvent(g_wheel_source_ack);
  }
  bool log = consumer && consumer->diagnostics < 16 &&
      (raw != 0 || filtered != 0 || consumer->diagnostics == 0);
  if (log) {
    uint32_t remaining = g_wheel_diagnostic_budget.load(std::memory_order_relaxed);
    while (remaining != 0 && !g_wheel_diagnostic_budget.compare_exchange_weak(
        remaining, remaining - 1, std::memory_order_relaxed)) {}
    log = remaining != 0;
  }
  if (log) {
    ++consumer->diagnostics;
    consumer->raw = raw; consumer->delivered = filtered;
    consumer->diagnostic_generation = snapshot.generation;
    consumer->diagnostic_ready = snapshot.ready;
    consumer->diagnostic_pending = true;
  }
  ReleaseSRWLockExclusive(&g_wheel_consumer_lock);
}
