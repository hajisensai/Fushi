// v19 generic bare-left-click input shield.
//
// This file is included by dll_main.cpp after exact adapters.  That order is
// deliberate: a build-pinned adapter keeps ownership of an API target it has
// already hooked; the generic layer fills the remaining public Win32,
// DirectInput and Raw Input surfaces and never chains an unknown trampoline.

#ifndef DIRECTINPUT_VERSION
#define DIRECTINPUT_VERSION 0x0800
#endif
#include <dinput.h>

using GenericGetKeyStateFn = SHORT(WINAPI *)(int);
using GenericGetKeyboardStateFn = BOOL(WINAPI *)(PBYTE);
using GenericGetRawInputDataFn = UINT(WINAPI *)(HRAWINPUT, UINT, LPVOID, PUINT,
                                                UINT);
using GenericGetRawInputBufferFn = UINT(WINAPI *)(PRAWINPUT, PUINT, UINT);
using GenericDirectInput8CreateFn = HRESULT(WINAPI *)(HINSTANCE, DWORD, REFIID,
                                                      LPVOID *, LPUNKNOWN);
using GenericDirectInputCreateFn = HRESULT(WINAPI *)(HINSTANCE, DWORD, void **,
                                                     LPUNKNOWN);
using GenericDirectInputCreateDeviceFn =
    HRESULT(STDMETHODCALLTYPE *)(void *, REFGUID, void **, LPUNKNOWN);
using GenericDirectInputReleaseFn = ULONG(STDMETHODCALLTYPE *)(void *);
using GenericDirectInputSetDataFormatFn =
    HRESULT(STDMETHODCALLTYPE *)(void *, LPCDIDATAFORMAT);
using GenericDirectInputGetDeviceStateFn = HRESULT(STDMETHODCALLTYPE *)(void *,
                                                                        DWORD,
                                                                        LPVOID);
using GenericDirectInputGetDeviceDataFn = HRESULT(STDMETHODCALLTYPE *)(
    void *, DWORD, LPDIDEVICEOBJECTDATA, LPDWORD, DWORD);

GenericGetKeyStateFn g_generic_get_key_state_original = nullptr;
GenericGetKeyStateFn g_generic_get_async_key_state_original = nullptr;
GenericGetKeyboardStateFn g_generic_get_keyboard_state_original = nullptr;
GenericGetRawInputDataFn g_generic_get_raw_input_data_original = nullptr;
GenericGetRawInputBufferFn g_generic_get_raw_input_buffer_original = nullptr;
GenericDirectInput8CreateFn g_generic_direct_input8_create_original = nullptr;
GenericDirectInputCreateFn g_generic_direct_input_create_a_original = nullptr;
GenericDirectInputCreateFn g_generic_direct_input_create_w_original = nullptr;
// DirectInputCreateEx 的签名与 DirectInput8Create 同形（带 REFIID），与 A/W 那两个不同。
GenericDirectInput8CreateFn g_generic_direct_input_create_ex_original = nullptr;

fushi_voice_hook::HookOriginalRegistry<16>
    g_generic_direct_input_create_device_originals;
fushi_voice_hook::HookOriginalRegistry<16>
    g_generic_direct_input_release_originals;
fushi_voice_hook::HookOriginalRegistry<16>
    g_generic_direct_input_set_data_format_originals;
fushi_voice_hook::HookOriginalRegistry<16>
    g_generic_direct_input_get_device_state_originals;
fushi_voice_hook::HookOriginalRegistry<16>
    g_generic_direct_input_get_device_data_originals;

constexpr uint32_t kGenericKeyCoverageGetKeyState = 0x1u;
constexpr uint32_t kGenericKeyCoverageGetAsyncKeyState = 0x2u;
constexpr uint32_t kGenericKeyCoverageGetKeyboardState = 0x4u;
constexpr uint32_t kGenericKeyCoverageAll = 0x7u;

std::atomic<uint32_t> g_generic_shield_ready_mask{0};
std::atomic<uint32_t> g_generic_shield_observed_mask{0};
std::atomic<uint32_t> g_generic_shield_fault_mask{0};
std::atomic<uint32_t> g_generic_shield_uncovered_mask{0};
std::atomic<uint32_t> g_generic_key_coverage{0};
std::atomic<uint32_t> g_generic_key_observed_coverage{0};
std::atomic<bool> g_generic_dinput8_factory_hooked{false};
std::atomic<bool> g_generic_dinput_factory_a_hooked{false};
std::atomic<bool> g_generic_dinput_factory_w_hooked{false};
std::atomic<bool> g_generic_dinput_factory_ex_hooked{false};

SRWLOCK g_generic_shield_state_lock = SRWLOCK_INIT;
fushi_voice_hook::LeftButtonShieldLatch g_generic_get_key_state_latch;
fushi_voice_hook::LeftButtonShieldLatch g_generic_get_async_key_state_latch;
fushi_voice_hook::LeftButtonShieldLatch g_generic_get_keyboard_state_latch;
fushi_voice_hook::LeftButtonShieldLatch g_generic_raw_input_data_latch;
fushi_voice_hook::LeftButtonShieldLatch g_generic_raw_input_buffer_latch;
uint32_t g_generic_prearmed_request_seq = 0;

enum class GenericDirectInputFormatState : uint8_t {
  kUnset = 0,
  kStandardMouse = 1,
  kUnknown = 2,
};

struct GenericDirectInputMouseDevice {
  void *device = nullptr;
  GenericDirectInputFormatState format = GenericDirectInputFormatState::kUnset;
  uint32_t state_bytes = 0;
  fushi_voice_hook::LeftButtonShieldLatch immediate_latch;
  fushi_voice_hook::LeftButtonShieldLatch buffered_latch;
  bool immediate_observed = false;
  bool buffered_observed = false;
};

constexpr size_t kGenericDirectInputDeviceCapacity = 32;
GenericDirectInputMouseDevice
    g_generic_direct_input_devices[kGenericDirectInputDeviceCapacity] = {};

bool GenericShieldTargetIsCurrentProcess(
    const fushi_voice_hook::LookupShieldRequestSnapshot &request) {
  if (!request.valid || request.target_hwnd == 0)
    return false;
  const HWND target =
      reinterpret_cast<HWND>(static_cast<uintptr_t>(request.target_hwnd));
  if (!IsWindow(target))
    return false;
  DWORD pid = 0;
  return GetWindowThreadProcessId(target, &pid) != 0 &&
         pid == GetCurrentProcessId();
}

bool GenericShieldRequestActiveForSurface(
    const fushi_voice_hook::LookupShieldRequestSnapshot &request,
    uint32_t /*surface*/) {
  // A writer-held request is intentionally unreadable and therefore fails
  // open here. Generic public-API coverage is always Partial (or a stricter
  // KnownUncovered/Faulted conclusion), never Verified; this micro-window is
  // part of the explicit risk acceptance rather than a reason to pre-arm an
  // unknown set of sampled APIs and risk a tail that can never drain.
  if (!request.valid ||
      (request.active_buttons & fushi_voice_hook::kLookupShieldButtonLeft) ==
          0 ||
      g_header == nullptr || g_header->lookup_enabled == 0) {
    return false;
  }
  if (!GenericShieldTargetIsCurrentProcess(request)) {
    // HWND lifetime is request-local. The coordinator publishes a fault for
    // this request and abandons its hidden tails, but must not poison the
    // process-wide hook-install fault mask seen by a replacement HWND.
    return false; // invalid target is a stability fault: fail open
  }
  return true;
}

void MarkGenericShieldObserved(uint32_t surface) {
  g_generic_shield_observed_mask.fetch_or(surface, std::memory_order_relaxed);
}

bool IsHookTargetTrackedByThisDll(void *target) {
  if (target == nullptr || !g_cs_ready)
    return false;
  bool tracked = false;
  EnterCriticalSection(&g_cs);
  for (int i = 0; i < g_hooked_count; ++i) {
    if (g_hooked_fns[i] == target) {
      tracked = true;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
  return tracked;
}

SHORT WINAPI Detour_GenericGetKeyState(int virtual_key) {
  const GenericGetKeyStateFn original = g_generic_get_key_state_original;
  if (original == nullptr)
    return 0;
  SHORT state = original(virtual_key);
  if (virtual_key != VK_LBUTTON)
    return state;
  MarkGenericShieldObserved(fushi_voice_hook::kLookupShieldSurfaceKeyState);
  g_generic_key_observed_coverage.fetch_or(kGenericKeyCoverageGetKeyState,
                                           std::memory_order_relaxed);
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  const bool active = GenericShieldRequestActiveForSurface(
      request, fushi_voice_hook::kLookupShieldSurfaceKeyState);
  AcquireSRWLockExclusive(&g_generic_shield_state_lock);
  fushi_voice_hook::FilterSampledLeftButtonState(
      active, false, reinterpret_cast<int16_t *>(&state),
      &g_generic_get_key_state_latch);
  ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
  return state;
}

SHORT WINAPI Detour_GenericGetAsyncKeyState(int virtual_key) {
  const GenericGetKeyStateFn original = g_generic_get_async_key_state_original;
  if (original == nullptr)
    return 0;
  SHORT state = original(virtual_key);
  if (virtual_key != VK_LBUTTON)
    return state;
  MarkGenericShieldObserved(fushi_voice_hook::kLookupShieldSurfaceKeyState);
  g_generic_key_observed_coverage.fetch_or(kGenericKeyCoverageGetAsyncKeyState,
                                           std::memory_order_relaxed);
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  const bool active = GenericShieldRequestActiveForSurface(
      request, fushi_voice_hook::kLookupShieldSurfaceKeyState);
  AcquireSRWLockExclusive(&g_generic_shield_state_lock);
  fushi_voice_hook::FilterSampledLeftButtonState(
      active, true, reinterpret_cast<int16_t *>(&state),
      &g_generic_get_async_key_state_latch);
  ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
  return state;
}

BOOL WINAPI Detour_GenericGetKeyboardState(PBYTE keys) {
  const GenericGetKeyboardStateFn original =
      g_generic_get_keyboard_state_original;
  if (original == nullptr)
    return FALSE;
  const BOOL result = original(keys);
  MarkGenericShieldObserved(fushi_voice_hook::kLookupShieldSurfaceKeyState);
  g_generic_key_observed_coverage.fetch_or(kGenericKeyCoverageGetKeyboardState,
                                           std::memory_order_relaxed);
  if (result == FALSE || keys == nullptr)
    return result;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  const bool active = GenericShieldRequestActiveForSurface(
      request, fushi_voice_hook::kLookupShieldSurfaceKeyState);
  AcquireSRWLockExclusive(&g_generic_shield_state_lock);
  fushi_voice_hook::FilterKeyboardStateLeftButton(
      active, keys, 256u, &g_generic_get_keyboard_state_latch);
  ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
  return result;
}

bool ValidateRawInputBuffer(PRAWINPUT data, UINT count, UINT buffer_bytes) {
  if (data == nullptr)
    return count == 0;
  const uint8_t *begin = reinterpret_cast<const uint8_t *>(data);
  const uint8_t *current = begin;
  const uint8_t *end = begin + buffer_bytes;
  __try {
    for (UINT i = 0; i < count; ++i) {
      if (current + sizeof(RAWINPUTHEADER) > end)
        return false;
      const auto *raw = reinterpret_cast<const RAWINPUT *>(current);
      if (raw->header.dwSize < sizeof(RAWINPUTHEADER) ||
          current + raw->header.dwSize > end) {
        return false;
      }
      if (raw->header.dwType == RIM_TYPEMOUSE &&
          raw->header.dwSize <
              offsetof(RAWINPUT, data.mouse) + sizeof(RAWMOUSE)) {
        return false;
      }
      constexpr size_t kRawInputAlignment = sizeof(uint64_t);
      const size_t aligned_size =
          (static_cast<size_t>(raw->header.dwSize) + kRawInputAlignment - 1u) &
          ~(kRawInputAlignment - 1u);
      const uint8_t *next = current + aligned_size;
      if (next <= current || next > end)
        return i + 1 == count;
      current = next;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return true;
}

UINT WINAPI Detour_GenericGetRawInputData(HRAWINPUT raw_handle, UINT command,
                                          LPVOID data, PUINT size,
                                          UINT header_size) {
  const GenericGetRawInputDataFn original =
      g_generic_get_raw_input_data_original;
  if (original == nullptr)
    return static_cast<UINT>(-1);
  const UINT result = original(raw_handle, command, data, size, header_size);
  if (result == static_cast<UINT>(-1) || command != RID_INPUT ||
      data == nullptr || result < sizeof(RAWINPUTHEADER)) {
    return result;
  }
  auto *raw = static_cast<PRAWINPUT>(data);
  __try {
    if (raw->header.dwType != RIM_TYPEMOUSE ||
        raw->header.dwSize <
            offsetof(RAWINPUT, data.mouse) + sizeof(RAWMOUSE) ||
        result < offsetof(RAWINPUT, data.mouse) + sizeof(RAWMOUSE)) {
      return result;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    g_generic_shield_fault_mask.fetch_or(
        fushi_voice_hook::kLookupShieldSurfaceRawInputData,
        std::memory_order_relaxed);
    return result;
  }
  MarkGenericShieldObserved(fushi_voice_hook::kLookupShieldSurfaceRawInputData);
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  const bool active = GenericShieldRequestActiveForSurface(
      request, fushi_voice_hook::kLookupShieldSurfaceRawInputData);
  AcquireSRWLockExclusive(&g_generic_shield_state_lock);
  fushi_voice_hook::FilterRawInputLeftButtonFlags(
      active, &raw->data.mouse.usButtonFlags, &g_generic_raw_input_data_latch);
  ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
  return result;
}

UINT WINAPI Detour_GenericGetRawInputBuffer(PRAWINPUT data, PUINT size,
                                            UINT header_size) {
  const GenericGetRawInputBufferFn original =
      g_generic_get_raw_input_buffer_original;
  if (original == nullptr)
    return static_cast<UINT>(-1);
  const UINT input_bytes = size == nullptr ? 0u : *size;
  const UINT result = original(data, size, header_size);
  if (result == static_cast<UINT>(-1) || data == nullptr)
    return result;
  if (!ValidateRawInputBuffer(data, result, input_bytes)) {
    g_generic_shield_fault_mask.fetch_or(
        fushi_voice_hook::kLookupShieldSurfaceRawInputBuffer,
        std::memory_order_relaxed);
    return result; // two-pass validation means the caller buffer is untouched
  }
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  const bool active = GenericShieldRequestActiveForSurface(
      request, fushi_voice_hook::kLookupShieldSurfaceRawInputBuffer);
  AcquireSRWLockExclusive(&g_generic_shield_state_lock);
  PRAWINPUT current = data;
  bool mouse_observed = false;
  for (UINT i = 0; i < result; ++i) {
    if (current->header.dwType == RIM_TYPEMOUSE) {
      mouse_observed = true;
      fushi_voice_hook::FilterRawInputLeftButtonFlags(
          active, &current->data.mouse.usButtonFlags,
          &g_generic_raw_input_buffer_latch);
    }
    constexpr size_t kRawInputAlignment = sizeof(uint64_t);
    const size_t aligned_size = (static_cast<size_t>(current->header.dwSize) +
                                 kRawInputAlignment - 1u) &
                                ~(kRawInputAlignment - 1u);
    current = reinterpret_cast<PRAWINPUT>(reinterpret_cast<uint8_t *>(current) +
                                          aligned_size);
  }
  if (result == 0) {
    fushi_voice_hook::ObserveLeftButtonNeutralTail(
        active, &g_generic_raw_input_buffer_latch);
  }
  ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
  if (mouse_observed) {
    MarkGenericShieldObserved(
        fushi_voice_hook::kLookupShieldSurfaceRawInputBuffer);
  }
  return result;
}

GenericDirectInputMouseDevice *
FindGenericDirectInputDeviceLocked(void *device) {
  for (auto &record : g_generic_direct_input_devices) {
    if (record.device == device)
      return &record;
  }
  return nullptr;
}

bool RegisterGenericDirectInputDevice(void *device) {
  if (device == nullptr)
    return false;
  AcquireSRWLockExclusive(&g_generic_shield_state_lock);
  if (FindGenericDirectInputDeviceLocked(device) != nullptr) {
    ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
    return true;
  }
  for (auto &record : g_generic_direct_input_devices) {
    if (record.device != nullptr)
      continue;
    record = GenericDirectInputMouseDevice{};
    record.device = device;
    ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
    return true;
  }
  ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
  g_generic_shield_uncovered_mask.fetch_or(
      fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate |
          fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered,
      std::memory_order_relaxed);
  return false;
}

bool IsStandardDirectInputMouseFormat(LPCDIDATAFORMAT format,
                                      uint32_t *state_bytes) {
  if (state_bytes != nullptr)
    *state_bytes = 0;
  if (format == nullptr || state_bytes == nullptr)
    return false;
  __try {
    if (format->dwSize != sizeof(DIDATAFORMAT) ||
        format->dwObjSize != sizeof(DIOBJECTDATAFORMAT) ||
        format->rgodf == nullptr ||
        (format->dwDataSize != 16u && format->dwDataSize != 20u)) {
      return false;
    }
    const uint32_t button_count = format->dwDataSize == 16u ? 4u : 8u;
    if (format->dwNumObjs != 3u + button_count)
      return false;
    bool offsets[20] = {};
    for (DWORD i = 0; i < format->dwNumObjs; ++i) {
      const DWORD offset = format->rgodf[i].dwOfs;
      if (offset >= format->dwDataSize || offsets[offset])
        return false;
      offsets[offset] = true;
    }
    if (!offsets[0] || !offsets[4] || !offsets[8])
      return false;
    for (uint32_t i = 0; i < button_count; ++i) {
      if (!offsets[12u + i])
        return false;
    }
    *state_bytes = format->dwDataSize;
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

HRESULT STDMETHODCALLTYPE
Detour_GenericDirectInputSetDataFormat(void *device, LPCDIDATAFORMAT format) {
  const auto original =
      OriginalHookForVtableSlot<GenericDirectInputSetDataFormatFn>(
          device, 11, g_generic_direct_input_set_data_format_originals);
  if (original == nullptr)
    return DIERR_GENERIC;
  const HRESULT result = original(device, format);
  if (FAILED(result))
    return result;
  uint32_t state_bytes = 0;
  const bool standard = IsStandardDirectInputMouseFormat(format, &state_bytes);
  AcquireSRWLockExclusive(&g_generic_shield_state_lock);
  auto *record = FindGenericDirectInputDeviceLocked(device);
  if (record != nullptr) {
    record->format = standard ? GenericDirectInputFormatState::kStandardMouse
                              : GenericDirectInputFormatState::kUnknown;
    record->state_bytes = standard ? state_bytes : 0;
  }
  ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
  if (!standard) {
    g_generic_shield_uncovered_mask.fetch_or(
        fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate |
            fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered,
        std::memory_order_relaxed);
  }
  return result;
}

HRESULT STDMETHODCALLTYPE Detour_GenericDirectInputGetDeviceState(
    void *device, DWORD bytes, LPVOID state) {
  const auto original =
      OriginalHookForVtableSlot<GenericDirectInputGetDeviceStateFn>(
          device, 9, g_generic_direct_input_get_device_state_originals);
  if (original == nullptr)
    return DIERR_GENERIC;
  const HRESULT result = original(device, bytes, state);
  if (FAILED(result) || state == nullptr)
    return result;
  MarkGenericShieldObserved(
      fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate);
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  const bool active = GenericShieldRequestActiveForSurface(
      request, fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate);
  AcquireSRWLockExclusive(&g_generic_shield_state_lock);
  auto *record = FindGenericDirectInputDeviceLocked(device);
  if (record == nullptr ||
      record->format != GenericDirectInputFormatState::kStandardMouse ||
      record->state_bytes != bytes) {
    ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
    g_generic_shield_uncovered_mask.fetch_or(
        fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate,
        std::memory_order_relaxed);
    return result;
  }
  record->immediate_observed = true;
  __try {
    fushi_voice_hook::FilterDirectInputImmediateLeftButton(
        active, static_cast<uint8_t *>(state), bytes, &record->immediate_latch);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    g_generic_shield_fault_mask.fetch_or(
        fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate,
        std::memory_order_relaxed);
  }
  ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
  return result;
}

HRESULT STDMETHODCALLTYPE Detour_GenericDirectInputGetDeviceData(
    void *device, DWORD object_bytes, LPDIDEVICEOBJECTDATA events,
    LPDWORD event_count, DWORD flags) {
  const auto original =
      OriginalHookForVtableSlot<GenericDirectInputGetDeviceDataFn>(
          device, 10, g_generic_direct_input_get_device_data_originals);
  if (original == nullptr)
    return DIERR_GENERIC;
  const HRESULT result =
      original(device, object_bytes, events, event_count, flags);
  if ((FAILED(result) && result != DI_BUFFEROVERFLOW) ||
      event_count == nullptr || events == nullptr) {
    return result;
  }
  MarkGenericShieldObserved(
      fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered);
  if (object_bytes < sizeof(DWORD) * 2u) {
    g_generic_shield_uncovered_mask.fetch_or(
        fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered,
        std::memory_order_relaxed);
    return result;
  }
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  const bool active = GenericShieldRequestActiveForSurface(
      request, fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered);
  AcquireSRWLockExclusive(&g_generic_shield_state_lock);
  auto *record = FindGenericDirectInputDeviceLocked(device);
  if (record == nullptr ||
      record->format != GenericDirectInputFormatState::kStandardMouse) {
    ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
    g_generic_shield_uncovered_mask.fetch_or(
        fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered,
        std::memory_order_relaxed);
    return result;
  }
  record->buffered_observed = true;
  const bool peek = (flags & DIGDD_PEEK) != 0;
  __try {
    const size_t count = static_cast<size_t>(*event_count);
    size_t write = 0;
    auto *base = reinterpret_cast<uint8_t *>(events);
    for (size_t read = 0; read < count; ++read) {
      auto *source = base + read * object_bytes;
      DWORD offset = 0;
      DWORD data = 0;
      memcpy(&offset, source, sizeof(offset));
      memcpy(&data, source + sizeof(DWORD), sizeof(data));
      const bool left = offset == DIMOFS_BUTTON0;
      const bool down = left && (data & 0x80u) != 0;
      if (active && left)
        record->buffered_latch.owned = true;
      const bool suppress = left && (active || record->buffered_latch.owned);
      if (suppress) {
        if (!down && record->buffered_latch.owned) {
          record->buffered_latch.release_seen = true;
        }
        continue;
      }
      if (write != read) {
        memmove(base + write * object_bytes, source, object_bytes);
      }
      ++write;
      if (!peek && !left) {
        fushi_voice_hook::ObserveLeftButtonNeutralTail(active,
                                                       &record->buffered_latch);
      }
    }
    *event_count = static_cast<DWORD>(write);
    if (!peek && count == 0) {
      fushi_voice_hook::ObserveLeftButtonNeutralTail(active,
                                                     &record->buffered_latch);
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    g_generic_shield_fault_mask.fetch_or(
        fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered,
        std::memory_order_relaxed);
  }
  ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
  return result;
}

ULONG STDMETHODCALLTYPE Detour_GenericDirectInputRelease(void *device) {
  const auto original = OriginalHookForVtableSlot<GenericDirectInputReleaseFn>(
      device, 2, g_generic_direct_input_release_originals);
  if (original == nullptr)
    return 0;
  const ULONG refs = original(device);
  if (refs == 0) {
    AcquireSRWLockExclusive(&g_generic_shield_state_lock);
    auto *record = FindGenericDirectInputDeviceLocked(device);
    if (record != nullptr)
      *record = GenericDirectInputMouseDevice{};
    ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
  }
  return refs;
}

bool HookGenericDirectInputMouseDevice(void *device) {
  if (!RegisterGenericDirectInputDevice(device))
    return false;
  const bool release_ready = HookFnWithOriginalRegistry(
      VtableSlot(device, 2),
      reinterpret_cast<void *>(&Detour_GenericDirectInputRelease),
      &g_generic_direct_input_release_originals);
  const bool state_ready = HookFnWithOriginalRegistry(
      VtableSlot(device, 9),
      reinterpret_cast<void *>(&Detour_GenericDirectInputGetDeviceState),
      &g_generic_direct_input_get_device_state_originals);
  const bool data_ready = HookFnWithOriginalRegistry(
      VtableSlot(device, 10),
      reinterpret_cast<void *>(&Detour_GenericDirectInputGetDeviceData),
      &g_generic_direct_input_get_device_data_originals);
  const bool format_ready = HookFnWithOriginalRegistry(
      VtableSlot(device, 11),
      reinterpret_cast<void *>(&Detour_GenericDirectInputSetDataFormat),
      &g_generic_direct_input_set_data_format_originals);
  if (!release_ready || !state_ready || !data_ready || !format_ready) {
    g_generic_shield_uncovered_mask.fetch_or(
        fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate |
            fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered,
        std::memory_order_relaxed);
    return false;
  }
  g_generic_shield_ready_mask.fetch_or(
      fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate |
          fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered,
      std::memory_order_relaxed);
  return true;
}

bool IsSystemMouseGuid(REFGUID guid) {
  // GUID_SysMouse = 6F1D2B60-D5A0-11CF-BFC7-444553540000.  Compare the
  // literal wire value to avoid a dxguid.lib dependency in the injected DLL.
  static constexpr GUID kSystemMouse = {
      0x6f1d2b60u,
      0xd5a0u,
      0x11cfu,
      {0xbfu, 0xc7u, 0x44u, 0x45u, 0x53u, 0x54u, 0x00u, 0x00u}};
  return InlineIsEqualGUID(guid, kSystemMouse) != FALSE;
}

HRESULT STDMETHODCALLTYPE Detour_GenericDirectInputCreateDevice(
    void *direct_input, REFGUID guid, void **out_device, LPUNKNOWN outer) {
  const auto original =
      OriginalHookForVtableSlot<GenericDirectInputCreateDeviceFn>(
          direct_input, 3, g_generic_direct_input_create_device_originals);
  if (original == nullptr)
    return DIERR_GENERIC;
  const HRESULT result = original(direct_input, guid, out_device, outer);
  if (SUCCEEDED(result) && out_device != nullptr && *out_device != nullptr &&
      IsSystemMouseGuid(guid)) {
    HookGenericDirectInputMouseDevice(*out_device);
  }
  return result;
}

bool HookGenericDirectInputInterface(void *direct_input) {
  if (direct_input == nullptr)
    return false;
  if (HookFnWithOriginalRegistry(
          VtableSlot(direct_input, 3),
          reinterpret_cast<void *>(&Detour_GenericDirectInputCreateDevice),
          &g_generic_direct_input_create_device_originals)) {
    return true;
  }
  g_generic_shield_uncovered_mask.fetch_or(
      fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate |
          fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered,
      std::memory_order_relaxed);
  return false;
}

HRESULT WINAPI Detour_GenericDirectInput8Create(HINSTANCE instance,
                                                DWORD version, REFIID iid,
                                                LPVOID *out, LPUNKNOWN outer) {
  const auto original = g_generic_direct_input8_create_original;
  if (original == nullptr)
    return DIERR_GENERIC;
  const HRESULT result = original(instance, version, iid, out, outer);
  if (SUCCEEDED(result) && out != nullptr && *out != nullptr) {
    HookGenericDirectInputInterface(*out);
  }
  return result;
}

HRESULT WINAPI Detour_GenericDirectInputCreateA(HINSTANCE instance,
                                                DWORD version, void **out,
                                                LPUNKNOWN outer) {
  const auto original = g_generic_direct_input_create_a_original;
  if (original == nullptr)
    return DIERR_GENERIC;
  const HRESULT result = original(instance, version, out, outer);
  if (SUCCEEDED(result) && out != nullptr && *out != nullptr) {
    HookGenericDirectInputInterface(*out);
  }
  return result;
}

HRESULT WINAPI Detour_GenericDirectInputCreateW(HINSTANCE instance,
                                                DWORD version, void **out,
                                                LPUNKNOWN outer) {
  const auto original = g_generic_direct_input_create_w_original;
  if (original == nullptr)
    return DIERR_GENERIC;
  const HRESULT result = original(instance, version, out, outer);
  if (SUCCEEDED(result) && out != nullptr && *out != nullptr) {
    HookGenericDirectInputInterface(*out);
  }
  return result;
}

// dinput.dll 的第三个工厂入口。DirectInputCreateA/W 在 dinput.dll 内部只是它的包装，
// 所以只钩 A/W 时，直接调 DirectInputCreateEx 的游戏会完全绕过遮罩层——设备建出来了、
// 我们一无所知，左键照样穿到游戏里推进对话。真机 フタマタ恋愛 Ver1.00 就加载了
// dinput.dll 而 ready 的 DirectInput 两位始终不亮（BUG-2154 的附带发现）。
// 签名与 DirectInput8Create 同形（带 REFIID），不是 A/W 那个四参数形状。
HRESULT WINAPI Detour_GenericDirectInputCreateEx(HINSTANCE instance,
                                                 DWORD version, REFIID iid,
                                                 LPVOID *out,
                                                 LPUNKNOWN outer) {
  const auto original = g_generic_direct_input_create_ex_original;
  if (original == nullptr)
    return DIERR_GENERIC;
  const HRESULT result = original(instance, version, iid, out, outer);
  if (SUCCEEDED(result) && out != nullptr && *out != nullptr) {
    HookGenericDirectInputInterface(*out);
  }
  return result;
}

bool HookGenericExport(void *target, void *detour, void **original,
                       uint32_t surface) {
  if (target == nullptr)
    return false;
  if (IsHookTargetTrackedByThisDll(target))
    return false;
  if (!HookFn(target, detour, original) || original == nullptr) {
    g_generic_shield_fault_mask.fetch_or(surface, std::memory_order_relaxed);
    return false;
  }
  return true;
}

void TryInstallGenericKeyAndRawInputShield() {
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (user32 == nullptr)
    return;
  // Exact profiles may defer their sampled-input detour until lookup is
  // enabled or a device appears. Reserve those shared USER32 exports even
  // before HookFn has tracked them; taking the target here would make the later
  // exact install receive no trampoline and silently destroy its build-pinned
  // shield/gesture logic.
  //
  // 这三个判断**不能是函数内 static**。static 局部只求值一次，而本函数的第一次调用
  // 就在 dll_main 里 MH_Initialize() 成功的那一刻——注入窗口最深处，正是 exact 身份
  // 最可能还没量出来的时候。那一次若返回 false，预留就永久为 false：通用护盾把
  // GetAsyncKeyState 抢走，之后身份重试成功、exact 侧再来装也拿不到 trampoline
  // （HookFn 已被占），BUG-2074 场景下「点击穿透」这一半根本没修好。
  // 身份判定自带 O(1) 缓存，逐拍重问不贵。
  //
  // 而且「未定」必须按**预留**处置，不能按「不是这个引擎」处置：抢占共享 USER32 导出
  // 是不可逆的，而不预留最多只是晚一拍装上通用护盾（本函数每个 Poll 拍都会重来）。
  // 代价不对称时，站在可逆的那一边。
  const bool reserve_get_key_state =
      IsSiglusLookupProfileMatched() || IsSiglusLookupIdentityUndecided();
  const bool hunex_exact_owner = IsHunexGgeProfileMatched();
  const bool reserve_get_async_key_state =
      IsLeafAquaplusProfileMatched() || IsLeafAquaplusIdentityUndecided() ||
      hunex_exact_owner;
  uint32_t coverage = g_generic_key_coverage.load(std::memory_order_relaxed);

  void *get_key_state =
      reinterpret_cast<void *>(GetProcAddress(user32, "GetKeyState"));
  if ((coverage & kGenericKeyCoverageGetKeyState) == 0) {
    if (IsHookTargetTrackedByThisDll(get_key_state)) {
      // Exact Siglus owns this target. Its Window-property contract is folded
      // into EnginePrivate status below; do not ask HookFn for a null duplicate
      // trampoline.
      coverage |= kGenericKeyCoverageGetKeyState;
    } else if (!reserve_get_key_state &&
               HookGenericExport(
                   get_key_state,
                   reinterpret_cast<void *>(&Detour_GenericGetKeyState),
                   reinterpret_cast<void **>(&g_generic_get_key_state_original),
                   fushi_voice_hook::kLookupShieldSurfaceKeyState)) {
      coverage |= kGenericKeyCoverageGetKeyState;
    }
  }

  void *get_async_key_state =
      reinterpret_cast<void *>(GetProcAddress(user32, "GetAsyncKeyState"));
  if ((coverage & kGenericKeyCoverageGetAsyncKeyState) == 0) {
    if (IsHookTargetTrackedByThisDll(get_async_key_state)) {
      // Leaf and HUNEX exact adapters own this target. Their distinct sampled
      // Window-property contracts are folded into EnginePrivate below.
      coverage |= kGenericKeyCoverageGetAsyncKeyState;
    } else if (!reserve_get_async_key_state &&
               HookGenericExport(
                   get_async_key_state,
                   reinterpret_cast<void *>(&Detour_GenericGetAsyncKeyState),
                   reinterpret_cast<void **>(
                       &g_generic_get_async_key_state_original),
                   fushi_voice_hook::kLookupShieldSurfaceKeyState)) {
      coverage |= kGenericKeyCoverageGetAsyncKeyState;
    }
  }

  void *get_keyboard_state =
      reinterpret_cast<void *>(GetProcAddress(user32, "GetKeyboardState"));
  if ((coverage & kGenericKeyCoverageGetKeyboardState) == 0 &&
      HookGenericExport(
          get_keyboard_state,
          reinterpret_cast<void *>(&Detour_GenericGetKeyboardState),
          reinterpret_cast<void **>(&g_generic_get_keyboard_state_original),
          fushi_voice_hook::kLookupShieldSurfaceKeyState)) {
    coverage |= kGenericKeyCoverageGetKeyboardState;
  }
  g_generic_key_coverage.store(coverage, std::memory_order_relaxed);
  if (fushi_voice_hook::IsCompleteGenericKeyStateCoverage(
          coverage, kGenericKeyCoverageAll, false)) {
    g_generic_shield_ready_mask.fetch_or(
        fushi_voice_hook::kLookupShieldSurfaceKeyState,
        std::memory_order_relaxed);
  }

  if (g_generic_get_raw_input_data_original == nullptr) {
    HookGenericExport(
        reinterpret_cast<void *>(GetProcAddress(user32, "GetRawInputData")),
        reinterpret_cast<void *>(&Detour_GenericGetRawInputData),
        reinterpret_cast<void **>(&g_generic_get_raw_input_data_original),
        fushi_voice_hook::kLookupShieldSurfaceRawInputData);
    if (g_generic_get_raw_input_data_original != nullptr) {
      g_generic_shield_ready_mask.fetch_or(
          fushi_voice_hook::kLookupShieldSurfaceRawInputData,
          std::memory_order_relaxed);
    }
  }
  if (g_generic_get_raw_input_buffer_original == nullptr) {
    HookGenericExport(
        reinterpret_cast<void *>(GetProcAddress(user32, "GetRawInputBuffer")),
        reinterpret_cast<void *>(&Detour_GenericGetRawInputBuffer),
        reinterpret_cast<void **>(&g_generic_get_raw_input_buffer_original),
        fushi_voice_hook::kLookupShieldSurfaceRawInputBuffer);
    if (g_generic_get_raw_input_buffer_original != nullptr) {
      g_generic_shield_ready_mask.fetch_or(
          fushi_voice_hook::kLookupShieldSurfaceRawInputBuffer,
          std::memory_order_relaxed);
    }
  }
}

bool ExactSgreOwnsDirectInput() {
  static const bool exact = fushi_voice_hook::MatchesSgreFamily();
  return exact;
}

void TryInstallGenericDirectInputFactories() {
  if (ExactSgreOwnsDirectInput())
    return;
  HMODULE dinput8 = GetModuleHandleW(L"dinput8.dll");
  if (dinput8 != nullptr &&
      !g_generic_dinput8_factory_hooked.load(std::memory_order_relaxed)) {
    const bool ready = HookGenericExport(
        reinterpret_cast<void *>(GetProcAddress(dinput8, "DirectInput8Create")),
        reinterpret_cast<void *>(&Detour_GenericDirectInput8Create),
        reinterpret_cast<void **>(&g_generic_direct_input8_create_original),
        fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate |
            fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered);
    g_generic_dinput8_factory_hooked.store(ready, std::memory_order_relaxed);
  }
  HMODULE dinput = GetModuleHandleW(L"dinput.dll");
  if (dinput == nullptr)
    return;
  if (!g_generic_dinput_factory_a_hooked.load(std::memory_order_relaxed)) {
    const bool ready = HookGenericExport(
        reinterpret_cast<void *>(GetProcAddress(dinput, "DirectInputCreateA")),
        reinterpret_cast<void *>(&Detour_GenericDirectInputCreateA),
        reinterpret_cast<void **>(&g_generic_direct_input_create_a_original),
        fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate |
            fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered);
    g_generic_dinput_factory_a_hooked.store(ready, std::memory_order_relaxed);
  }
  if (!g_generic_dinput_factory_w_hooked.load(std::memory_order_relaxed)) {
    const bool ready = HookGenericExport(
        reinterpret_cast<void *>(GetProcAddress(dinput, "DirectInputCreateW")),
        reinterpret_cast<void *>(&Detour_GenericDirectInputCreateW),
        reinterpret_cast<void **>(&g_generic_direct_input_create_w_original),
        fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate |
            fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered);
    g_generic_dinput_factory_w_hooked.store(ready, std::memory_order_relaxed);
  }
  if (!g_generic_dinput_factory_ex_hooked.load(std::memory_order_relaxed)) {
    // A/W 在 dinput.dll 内部只是 Ex 的包装，但游戏可以直接 GetProcAddress("DirectInputCreateEx")
    // 绕过它们。不钩这一个，遮罩层就有一条静默的漏路。
    const bool ready = HookGenericExport(
        reinterpret_cast<void *>(GetProcAddress(dinput, "DirectInputCreateEx")),
        reinterpret_cast<void *>(&Detour_GenericDirectInputCreateEx),
        reinterpret_cast<void **>(&g_generic_direct_input_create_ex_original),
        fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate |
            fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered);
    g_generic_dinput_factory_ex_hooked.store(ready, std::memory_order_relaxed);
  }
}

void TryInstallGenericLookupInputShield() {
  TryInstallGenericKeyAndRawInputShield();
  TryInstallGenericDirectInputFactories();
}

void PreArmGenericShieldForRequest(uint32_t request_seq,
                                   uint32_t ready_required_mask) {
  if (request_seq == 0)
    return;
  AcquireSRWLockExclusive(&g_generic_shield_state_lock);
  if (g_generic_prearmed_request_seq == request_seq) {
    ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
    return;
  }
  if ((ready_required_mask & fushi_voice_hook::kLookupShieldSurfaceKeyState) !=
      0) {
    const uint32_t observed =
        g_generic_key_observed_coverage.load(std::memory_order_relaxed);
    if ((observed & kGenericKeyCoverageGetKeyState) != 0) {
      fushi_voice_hook::PreArmLeftButtonShieldLatch(
          &g_generic_get_key_state_latch);
    }
    if ((observed & kGenericKeyCoverageGetAsyncKeyState) != 0) {
      fushi_voice_hook::PreArmLeftButtonShieldLatch(
          &g_generic_get_async_key_state_latch);
    }
    if ((observed & kGenericKeyCoverageGetKeyboardState) != 0) {
      fushi_voice_hook::PreArmLeftButtonShieldLatch(
          &g_generic_get_keyboard_state_latch);
    }
  }
  if ((ready_required_mask &
       fushi_voice_hook::kLookupShieldSurfaceRawInputData) != 0) {
    fushi_voice_hook::PreArmLeftButtonShieldLatch(
        &g_generic_raw_input_data_latch);
  }
  if ((ready_required_mask &
       fushi_voice_hook::kLookupShieldSurfaceRawInputBuffer) != 0) {
    fushi_voice_hook::PreArmLeftButtonShieldLatch(
        &g_generic_raw_input_buffer_latch);
  }
  for (auto &record : g_generic_direct_input_devices) {
    if (record.device == nullptr)
      continue;
    if (record.immediate_observed &&
        (ready_required_mask &
         fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate) != 0) {
      fushi_voice_hook::PreArmLeftButtonShieldLatch(&record.immediate_latch);
    }
    if (record.buffered_observed &&
        (ready_required_mask &
         fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered) != 0) {
      fushi_voice_hook::PreArmLeftButtonShieldLatch(&record.buffered_latch);
    }
  }
  g_generic_prearmed_request_seq = request_seq;
  ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
}

uint32_t GenericShieldPendingMask() {
  uint32_t pending = 0;
  AcquireSRWLockShared(&g_generic_shield_state_lock);
  if (g_generic_get_key_state_latch.owned ||
      g_generic_get_async_key_state_latch.owned ||
      g_generic_get_keyboard_state_latch.owned) {
    pending |= fushi_voice_hook::kLookupShieldSurfaceKeyState;
  }
  if (g_generic_raw_input_data_latch.owned) {
    pending |= fushi_voice_hook::kLookupShieldSurfaceRawInputData;
  }
  if (g_generic_raw_input_buffer_latch.owned) {
    pending |= fushi_voice_hook::kLookupShieldSurfaceRawInputBuffer;
  }
  for (const auto &record : g_generic_direct_input_devices) {
    if (record.device == nullptr)
      continue;
    if (record.immediate_latch.owned) {
      pending |= fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate;
    }
    if (record.buffered_latch.owned) {
      pending |= fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered;
    }
  }
  ReleaseSRWLockShared(&g_generic_shield_state_lock);
  return pending;
}

// BUG-2140：宿主发布中性请求后，放弃所有**从未被真实采样坐实**的推测 latch。
// 它们等的那条「释放 + 中性尾」可能永远不会到（该输入面这一局不再被游戏采样），
// 而 release_waiting 会因此把 applied_seq 永久扣在 request_seq-1，宿主的
// IsNeutralForRehandshake 恒假、attached 表面首次查词后再也武装不起来。
// 只放弃推测的；被真实按下坐实过的 latch 一律保留，不变式不放宽。
void AbandonSpeculativeGenericShieldLatches(bool request_active) {
  if (request_active) return;
  AcquireSRWLockExclusive(&g_generic_shield_state_lock);
  fushi_voice_hook::AbandonSpeculativeLeftButtonLatch(
      request_active, &g_generic_get_key_state_latch);
  fushi_voice_hook::AbandonSpeculativeLeftButtonLatch(
      request_active, &g_generic_get_async_key_state_latch);
  fushi_voice_hook::AbandonSpeculativeLeftButtonLatch(
      request_active, &g_generic_get_keyboard_state_latch);
  fushi_voice_hook::AbandonSpeculativeLeftButtonLatch(
      request_active, &g_generic_raw_input_data_latch);
  fushi_voice_hook::AbandonSpeculativeLeftButtonLatch(
      request_active, &g_generic_raw_input_buffer_latch);
  for (auto &record : g_generic_direct_input_devices) {
    fushi_voice_hook::AbandonSpeculativeLeftButtonLatch(
        request_active, &record.immediate_latch);
    fushi_voice_hook::AbandonSpeculativeLeftButtonLatch(
        request_active, &record.buffered_latch);
  }
  ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
}

void AbandonGenericShieldLatchesForInvalidTarget() {
  AcquireSRWLockExclusive(&g_generic_shield_state_lock);
  g_generic_get_key_state_latch = {};
  g_generic_get_async_key_state_latch = {};
  g_generic_get_keyboard_state_latch = {};
  g_generic_raw_input_data_latch = {};
  g_generic_raw_input_buffer_latch = {};
  for (auto &record : g_generic_direct_input_devices) {
    record.immediate_latch = {};
    record.buffered_latch = {};
  }
  ReleaseSRWLockExclusive(&g_generic_shield_state_lock);
}

struct ExactSampledShieldState {
  uint32_t declared = 0;
  uint32_t ready = 0;
  // Surfaces beyond EnginePrivate that the declared exact contract physically
  // owns (e.g. Win32 messages for a window-procedure subclass).  Required
  // whenever declared; ready only when the contract's Ready property is set.
  uint32_t extra_required_surfaces = 0;
  uint32_t extra_ready_surfaces = 0;
  bool pending_publication = false;
};

ExactSampledShieldState ReadExactSampledShieldState(HWND game) {
  ExactSampledShieldState out;
  if (game == nullptr || !IsWindow(game))
    return out;
  struct Contract {
    const wchar_t *required;
    uintptr_t required_value;
    const wchar_t *ready;
    uintptr_t ready_value;
    const wchar_t *window;
    uint32_t extra_surfaces;
  };
  const Contract contracts[] = {
      {fushi_voice_hook::kSgreDirectInputShieldRequiredProperty,
       fushi_voice_hook::kSgreDirectInputShieldRequiredValue,
       fushi_voice_hook::kSgreDirectInputShieldReadyProperty,
       fushi_voice_hook::kSgreDirectInputShieldReadyValue,
       fushi_voice_hook::kSgreDirectInputShieldWindowProperty, 0u},
      {fushi_voice_hook::kSiglusSampledInputShieldRequiredProperty,
       fushi_voice_hook::kSiglusSampledInputShieldRequiredValue,
       fushi_voice_hook::kSiglusSampledInputShieldReadyProperty,
       fushi_voice_hook::kSiglusSampledInputShieldReadyValue,
       fushi_voice_hook::kSiglusSampledInputShieldWindowProperty, 0u},
      {fushi_voice_hook::kLeafAquaplusSampledInputShieldRequiredProperty,
       fushi_voice_hook::kLeafAquaplusSampledInputShieldRequiredValue,
       fushi_voice_hook::kLeafAquaplusSampledInputShieldReadyProperty,
       fushi_voice_hook::kLeafAquaplusSampledInputShieldReadyValue,
       fushi_voice_hook::kLeafAquaplusSampledInputShieldWindowProperty, 0u},
      {fushi_voice_hook::kHunexGgeSampledInputShieldRequiredProperty,
       fushi_voice_hook::kHunexGgeSampledInputShieldRequiredValue,
       fushi_voice_hook::kHunexGgeSampledInputShieldReadyProperty,
       fushi_voice_hook::kHunexGgeSampledInputShieldReadyValue,
       fushi_voice_hook::kHunexGgeSampledInputShieldWindowProperty, 0u},
      // smash/fzmedia consumes clicks in a GWLP_WNDPROC subclass: the Win32
      // message surface is owned by the injected runtime, not by the host's
      // low-level hook, so it is required (and ready with the subclass).
      {fushi_voice_hook::kSmashFzmediaSampledInputShieldRequiredProperty,
       fushi_voice_hook::kSmashFzmediaSampledInputShieldRequiredValue,
       fushi_voice_hook::kSmashFzmediaSampledInputShieldReadyProperty,
       fushi_voice_hook::kSmashFzmediaSampledInputShieldReadyValue,
       fushi_voice_hook::kSmashFzmediaSampledInputShieldWindowProperty,
       fushi_voice_hook::kLookupShieldSurfaceWin32Messages},
  };
  for (const auto &contract : contracts) {
    if (reinterpret_cast<uintptr_t>(GetPropW(game, contract.required)) !=
        contract.required_value) {
      continue;
    }
    ++out.declared;
    out.extra_required_surfaces |= contract.extra_surfaces;
    if (reinterpret_cast<uintptr_t>(GetPropW(game, contract.ready)) ==
        contract.ready_value) {
      ++out.ready;
      out.extra_ready_surfaces |= contract.extra_surfaces;
    }
    if (GetPropW(game, contract.window) != nullptr) {
      out.pending_publication = true;
    }
  }
  return out;
}

void PublishGenericShieldStatusPayloadOnly(
    const fushi_voice_hook::LookupShieldRequestSnapshot &request,
    const fushi_voice_hook::LookupShieldStatusPublication &publication) {
  if (g_header == nullptr ||
      !fushi_voice_hook::LookupShieldRequestMatches(g_header, request)) {
    return;
  }
  fushi_voice_hook::AtomicStoreShared32(&g_header->lookup_shield_required_mask,
                                        publication.required_mask);
  fushi_voice_hook::AtomicStoreShared32(&g_header->lookup_shield_ready_mask,
                                        publication.ready_mask);
  fushi_voice_hook::AtomicStoreShared32(&g_header->lookup_shield_observed_mask,
                                        publication.observed_mask);
  fushi_voice_hook::AtomicStoreShared32(&g_header->lookup_shield_fault_mask,
                                        publication.fault_mask);
  fushi_voice_hook::AtomicStoreShared32(
      &g_header->lookup_shield_status_flags,
      fushi_voice_hook::NormalizeLookupShieldStatusFlags(request, publication));
}

void ProcessGenericLookupInputShield() {
  if (g_header == nullptr)
    return;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  if (!request.valid)
    return;

  fushi_voice_hook::LookupShieldStatusPublication status;
  status.required_mask = fushi_voice_hook::kLookupShieldSurfaceKeyState |
                         fushi_voice_hook::kLookupShieldSurfaceRawInputData |
                         fushi_voice_hook::kLookupShieldSurfaceRawInputBuffer;
  status.ready_mask =
      g_generic_shield_ready_mask.load(std::memory_order_relaxed);
  status.observed_mask =
      g_generic_shield_observed_mask.load(std::memory_order_relaxed);
  status.fault_mask =
      g_generic_shield_fault_mask.load(std::memory_order_relaxed);

  const HWND game =
      reinterpret_cast<HWND>(static_cast<uintptr_t>(request.target_hwnd));
  const bool target_valid = GenericShieldTargetIsCurrentProcess(request);
  if (!target_valid) {
    // The window is gone or no longer belongs to this process.  No future
    // poll is guaranteed, so keeping a hidden down latch would permanently
    // stall release/provider switching.  Drop every latch and acknowledge the
    // faulted release: this is the required fail-open stability path.
    AbandonGenericShieldLatchesForInvalidTarget();
  }

  // Host only publishes AttachedGlyph after the synchronous HHOOK arm has
  // succeeded. These two bits describe that host-owned portion; other owners
  // do not get to infer it.
  if (request.owner_kind == fushi_voice_hook::kLookupShieldOwnerAttachedGlyph) {
    status.required_mask |=
        fushi_voice_hook::kLookupShieldSurfaceWin32Messages |
        fushi_voice_hook::kLookupShieldSurfaceLowLevelMouse;
    if (target_valid) {
      status.ready_mask |= fushi_voice_hook::kLookupShieldSurfaceWin32Messages |
                           fushi_voice_hook::kLookupShieldSurfaceLowLevelMouse;
    }
  }

  const ExactSampledShieldState exact =
      ReadExactSampledShieldState(target_valid ? game : nullptr);
  if (exact.declared != 0) {
    status.required_mask |= fushi_voice_hook::kLookupShieldSurfaceEnginePrivate |
                            exact.extra_required_surfaces;
    if (exact.declared == 1 && exact.ready == 1) {
      status.ready_mask |= fushi_voice_hook::kLookupShieldSurfaceEnginePrivate |
                           fushi_voice_hook::kLookupShieldSurfaceKeyState |
                           exact.extra_ready_surfaces;
    } else if (exact.declared > 1) {
      status.fault_mask |= fushi_voice_hook::kLookupShieldSurfaceEnginePrivate;
    }
  }

  const bool dinput_loaded = GetModuleHandleW(L"dinput.dll") != nullptr ||
                             GetModuleHandleW(L"dinput8.dll") != nullptr;
  if (dinput_loaded && exact.declared == 0) {
    status.required_mask |=
        fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate |
        fushi_voice_hook::kLookupShieldSurfaceDirectInputBuffered;
  }
  status.fault_mask = fushi_voice_hook::TargetScopedGenericShieldFaultMask(
      status.fault_mask, status.required_mask, target_valid);

  const uint32_t uncovered =
      g_generic_shield_uncovered_mask.load(std::memory_order_relaxed) &
      status.required_mask;
  switch (fushi_voice_hook::ClassifyGenericShieldCoverage(
      status.fault_mask, uncovered, status.ready_mask)) {
  case fushi_voice_hook::GenericShieldCoverageConclusion::kFaulted:
    status.status_flags = fushi_voice_hook::kLookupShieldStatusFaulted;
    break;
  case fushi_voice_hook::GenericShieldCoverageConclusion::kKnownUncovered:
    status.status_flags = fushi_voice_hook::kLookupShieldStatusKnownUncovered;
    break;
  case fushi_voice_hook::GenericShieldCoverageConclusion::kPartial:
    // Public API hooks alone are not executable-specific verification. Keep
    // generic coverage partial until the per-build 1,000-transaction evidence
    // gate is recorded; allow_risk is orthogonal and normalized by the helper.
    status.status_flags = fushi_voice_hook::kLookupShieldStatusPartial;
    break;
  case fushi_voice_hook::GenericShieldCoverageConclusion::kUnknown:
    break;
  }

  // applied_seq is the host's permission to publish release. Pre-own each
  // required+ready surface already observed in this game before that ack, so a
  // queued fast click stays hidden without deadlocking on unused API variants.
  if (target_valid && status.fault_mask == 0 &&
      (request.active_buttons & fushi_voice_hook::kLookupShieldButtonLeft) !=
          0) {
    PreArmGenericShieldForRequest(
        request.seq,
        fushi_voice_hook::PreArmEligibleShieldMask(
            status.required_mask, status.ready_mask, status.observed_mask));
  }

  // BUG-2140：先把「推测上锁、从未被真实采样坐实」的 latch 放掉，再算 pending。
  // 否则一次预武装就能把 applied_seq 永久扣住。
  AbandonSpeculativeGenericShieldLatches(request.active_buttons != 0);
  const uint32_t pending = GenericShieldPendingMask();
  const bool release_waiting = request.active_buttons == 0 &&
                               (pending != 0 || exact.pending_publication);
  if (release_waiting) {
    PublishGenericShieldStatusPayloadOnly(request, status);
    return; // applied_seq must not cross a hidden down/up/tail
  }
  fushi_voice_hook::PublishLookupShieldStatus(g_header, request, status);
}

void ShutdownGenericLookupInputShield() {
  if (g_header == nullptr)
    return;
  fushi_voice_hook::AtomicStoreShared32(&g_header->lookup_shield_ready_mask, 0);
  fushi_voice_hook::AtomicStoreShared32(
      &g_header->lookup_shield_status_flags,
      fushi_voice_hook::kLookupShieldStatusFaulted);
}
