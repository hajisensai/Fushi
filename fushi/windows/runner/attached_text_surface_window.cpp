#include "attached_text_surface_window.h"

#include <bcrypt.h>
#include <d3dkmthk.h>
#include <dwmapi.h>
#include <dwrite_1.h>
#include <windowsx.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <iomanip>
#include <limits>
#include <sstream>
#include <utility>

#include "attached_layout_validation.h"
#include "attached_bitmap_bounds.h"
#include "attached_overlayability.h"
#include "attached_shield_status_policy.h"
#include "lookup_hit_validation.h"
#include "low_level_mouse_hook.h"
#include "native_glog.h"
#include "window_capture.h"
#include "voice_hook_reader.h"

namespace {

constexpr wchar_t kAttachedSurfaceClassName[] =
    L"FushiAttachedTextSurfaceWindow";
constexpr UINT_PTR kFollowTimerId = 1;
constexpr UINT kFollowTimerMs = 500;
// Shift+hover lookup poll. The runtime surface is click-through and never
// receives WM_MOUSEMOVE, so hover must sample the global cursor like the
// floating lyric window does (floating_lyric_window.cpp MaybeHoverLookup).
constexpr UINT_PTR kHoverTimerId = 2;
constexpr UINT kHoverTimerMs = 60;
// The injected shield acknowledges a handshake probe only through shared
// memory, with no wake-up channel. A re-handshake takes one admission pass to
// publish the probe and another to observe the ack, so leaving it to the 500 ms
// follow timer kept the surface hidden (no highlight, clicks not looked up)
// for up to seconds after every popup dismissal or advanced line. While a
// handshake is outstanding, re-run admission at frame cadence instead.
constexpr UINT_PTR kShieldHandshakeWatchTimerId = 3;
constexpr UINT kShieldHandshakeWatchTimerMs = 16;
// Resource bound only: a handshake still pending after this long returns to
// the follow-timer cadence (and is logged) rather than polling indefinitely.
constexpr ULONGLONG kShieldHandshakeWatchMaxMs = 5000;
constexpr UINT kSyncTargetMessage = WM_APP + 0x235;
constexpr int kMinimumBodyPixels = 8;
constexpr size_t kMaximumSourceTextUnits = 32768;
constexpr uint32_t kProbeStartMask = 1u;
constexpr uint32_t kProbeMiddleMask = 2u;
constexpr uint32_t kProbeEndMask = 4u;
constexpr uint32_t kAllProbeMask =
    kProbeStartMask | kProbeMiddleMask | kProbeEndMask;
// Stable v19 wire values from voice_hook_ipc.h. This runner deliberately keeps
// the surface header independent from the injected-hook ABI header.
constexpr uint32_t kGeometryProviderRuntimeLayout = 1u;
constexpr uint32_t kGeometryProviderEngineExactLayout = 2u;
constexpr uint32_t kGeometryProviderPositionedTextApi = 3u;
constexpr uint32_t kGeometryProviderAttachedCalibrated = 4u;
constexpr uint32_t kGeometryProviderIdAttachedCalibrated = 11u;
constexpr uint32_t kShieldStatusVerified = 0x00000001u;
constexpr uint32_t kShieldStatusFaulted = 0x00000008u;
constexpr uint32_t kShieldStatusTransactionActive = 0x00000020u;
std::atomic<uint32_t> g_shield_probe_counter{0};

bool NtSuccess(NTSTATUS status) { return status >= 0; }

std::string WideToUtf8(const std::wstring &value) {
  if (value.empty())
    return std::string();
  const int size = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0)
    return std::string();
  std::string result(static_cast<size_t>(size), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(), size,
                          nullptr, nullptr) <= 0) {
    return std::string();
  }
  return result;
}

bool ExecutablePathForPid(uint32_t pid, std::wstring *path) {
  if (path == nullptr || pid == 0)
    return false;
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr)
    return false;
  std::wstring buffer(32768, L'\0');
  DWORD length = static_cast<DWORD>(buffer.size());
  const BOOL ok =
      QueryFullProcessImageNameW(process, 0, buffer.data(), &length);
  CloseHandle(process);
  if (!ok || length == 0)
    return false;
  buffer.resize(length);
  *path = std::move(buffer);
  return true;
}

bool IsAbsoluteWindowsPath(const std::wstring &path) {
  const auto is_separator = [](wchar_t value) {
    return value == L'\\' || value == L'/';
  };
  const bool drive_absolute = path.size() >= 3 &&
                              ((path[0] >= L'A' && path[0] <= L'Z') ||
                               (path[0] >= L'a' && path[0] <= L'z')) &&
                              path[1] == L':' && is_separator(path[2]);
  const bool unc_or_extended = path.size() >= 3 && is_separator(path[0]) &&
                               is_separator(path[1]) && !is_separator(path[2]);
  return drive_absolute || unc_or_extended;
}

std::string Sha256File(const std::wstring &path) {
  HANDLE file =
      CreateFileW(path.c_str(), GENERIC_READ,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE)
    return std::string();

  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_bytes = 0;
  DWORD result_bytes = 0;
  std::vector<UCHAR> hash_object;
  std::array<UCHAR, 32> digest{};
  bool ok = NtSuccess(BCryptOpenAlgorithmProvider(
      &algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0));
  if (ok) {
    ok = NtSuccess(BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                                     reinterpret_cast<PUCHAR>(&object_bytes),
                                     sizeof(object_bytes), &result_bytes, 0));
  }
  if (ok && object_bytes > 0) {
    hash_object.resize(object_bytes);
    ok = NtSuccess(BCryptCreateHash(algorithm, &hash, hash_object.data(),
                                    object_bytes, nullptr, 0, 0));
  } else {
    ok = false;
  }

  std::vector<UCHAR> buffer(64 * 1024);
  while (ok) {
    DWORD read = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &read,
                  nullptr)) {
      ok = false;
      break;
    }
    if (read == 0)
      break;
    ok = NtSuccess(BCryptHashData(hash, buffer.data(), read, 0));
  }
  if (ok) {
    ok = NtSuccess(BCryptFinishHash(hash, digest.data(),
                                    static_cast<ULONG>(digest.size()), 0));
  }

  if (hash != nullptr)
    BCryptDestroyHash(hash);
  if (algorithm != nullptr)
    BCryptCloseAlgorithmProvider(algorithm, 0);
  CloseHandle(file);
  if (!ok)
    return std::string();

  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (UCHAR byte : digest) {
    stream << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return stream.str();
}

struct WindowSearch {
  uint32_t pid = 0;
  HWND foreground = nullptr;
  HWND best = nullptr;
  uint64_t best_score = 0;
};

BOOL CALLBACK FindTargetWindowProc(HWND hwnd, LPARAM lparam) {
  auto *search = reinterpret_cast<WindowSearch *>(lparam);
  if (search == nullptr || !IsWindow(hwnd))
    return TRUE;
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid != search->pid)
    return TRUE;
  const LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
  if ((style & WS_CHILD) != 0)
    return TRUE;
  RECT client{};
  if (!GetClientRect(hwnd, &client))
    return TRUE;
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0)
    return TRUE;
  const bool visible = IsWindowVisible(hwnd) != FALSE;
  const bool foreground = hwnd == search->foreground;
  const uint64_t area =
      static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
  const uint64_t score = area + (visible ? (uint64_t{1} << 61) : 0) +
                         (foreground ? (uint64_t{1} << 62) : 0);
  if (search->best == nullptr || score > search->best_score) {
    search->best = hwnd;
    search->best_score = score;
  }
  return TRUE;
}

HWND FindTargetWindow(uint32_t pid) {
  WindowSearch search;
  search.pid = pid;
  search.foreground = GetForegroundWindow();
  EnumWindows(FindTargetWindowProc, reinterpret_cast<LPARAM>(&search));
  return search.best;
}

HWND CanonicalSourceWindow(HWND hwnd) {
  if (hwnd == nullptr || !IsWindow(hwnd))
    return nullptr;
  const HWND source = fushi::ResolveScalingSourceWindow(hwnd);
  return source != nullptr ? source : hwnd;
}

struct PresentationSearch {
  HWND source = nullptr;
  HWND foreground = nullptr;
  HWND best = nullptr;
  uint64_t best_score = 0;
};

BOOL CALLBACK FindPresentationWindowProc(HWND hwnd, LPARAM lparam) {
  auto *search = reinterpret_cast<PresentationSearch *>(lparam);
  if (search == nullptr || hwnd == nullptr || !IsWindow(hwnd) ||
      !IsWindowVisible(hwnd)) {
    return TRUE;
  }
  if (fushi::ResolveScalingSourceWindow(hwnd) != search->source)
    return TRUE;
  RECT client{};
  if (!GetClientRect(hwnd, &client))
    return TRUE;
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0)
    return TRUE;
  const uint64_t area =
      static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
  const uint64_t score =
      area + (hwnd == search->foreground ? (uint64_t{1} << 62) : uint64_t{0});
  if (search->best == nullptr || score > search->best_score) {
    search->best = hwnd;
    search->best_score = score;
  }
  return TRUE;
}

HWND FindPresentationWindow(HWND source) {
  if (source == nullptr || !IsWindow(source))
    return nullptr;
  PresentationSearch search;
  search.source = source;
  search.foreground = GetForegroundWindow();
  EnumWindows(FindPresentationWindowProc, reinterpret_cast<LPARAM>(&search));
  return search.best;
}

bool WindowIsCloaked(HWND hwnd) {
  if (hwnd == nullptr || !IsWindow(hwnd))
    return true;
  DWORD cloaked = 0;
  return SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked,
                                         sizeof(cloaked))) &&
         cloaked != 0;
}

RECT ClientScreenRect(HWND hwnd) {
  RECT client{};
  if (!fushi::ReadPhysicalClientScreenRect(hwnd, &client))
    return RECT{};
  return client;
}

bool RectHasArea(const RECT &rect) {
  return rect.right > rect.left && rect.bottom > rect.top;
}

bool SurfaceGeometryEqual(
    const AttachedTextSurfaceWindow::SurfaceGeometry &left,
    const AttachedTextSurfaceWindow::SurfaceGeometry &right) {
  return EqualRect(&left.source_client_screen, &right.source_client_screen) &&
         EqualRect(&left.source_viewport_screen, &right.source_viewport_screen) &&
         EqualRect(&left.presentation_client_screen,
                   &right.presentation_client_screen) &&
         EqualRect(&left.destination_viewport_screen,
                   &right.destination_viewport_screen);
}

using QueryVidPnExclusiveOwnership =
    NTSTATUS(APIENTRY *)(D3DKMT_QUERYVIDPNEXCLUSIVEOWNERSHIP *);
using CheckExclusiveOwnership = BOOLEAN(APIENTRY *)();

struct D3dkmtOwnershipApi {
  QueryVidPnExclusiveOwnership query_target = nullptr;
  CheckExclusiveOwnership check_any = nullptr;
};

const D3dkmtOwnershipApi &OwnershipApi() {
  static const D3dkmtOwnershipApi api = [] {
    D3dkmtOwnershipApi loaded;
    const HMODULE gdi = GetModuleHandleW(L"gdi32.dll");
    if (gdi == nullptr)
      return loaded;
    loaded.query_target = reinterpret_cast<QueryVidPnExclusiveOwnership>(
        GetProcAddress(gdi, "D3DKMTQueryVidPnExclusiveOwnership"));
    loaded.check_any = reinterpret_cast<CheckExclusiveOwnership>(
        GetProcAddress(gdi, "D3DKMTCheckExclusiveOwnership"));
    return loaded;
  }();
  return api;
}

fushi::attached_overlayability::ExclusiveOwnership
QueryWindowExclusiveOwnership(HWND hwnd, DWORD pid) {
  using fushi::attached_overlayability::ExclusiveOwnership;
  const D3dkmtOwnershipApi &api = OwnershipApi();
  if (hwnd != nullptr && IsWindow(hwnd) && pid != 0 &&
      api.query_target != nullptr) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (process != nullptr) {
      D3DKMT_QUERYVIDPNEXCLUSIVEOWNERSHIP query{};
      query.hProcess = process;
      query.hWindow = hwnd;
      const NTSTATUS status = api.query_target(&query);
      CloseHandle(process);
      if (status >= 0) {
        if (query.OwnerType == D3DKMT_VIDPNSOURCEOWNER_EXCLUSIVE ||
            query.OwnerType == D3DKMT_VIDPNSOURCEOWNER_EXCLUSIVEGDI) {
          return ExclusiveOwnership::kExclusive;
        }
        if (query.OwnerType == D3DKMT_VIDPNSOURCEOWNER_UNOWNED ||
            query.OwnerType == D3DKMT_VIDPNSOURCEOWNER_SHARED ||
            query.OwnerType == D3DKMT_VIDPNSOURCEOWNER_EMULATED) {
          return ExclusiveOwnership::kNotExclusive;
        }
      }
    }
  }

  // The Vista-era probe is system-wide.  FALSE is still a conclusive negative
  // for this target; TRUE cannot be attributed to this HWND and is therefore
  // unknown (fail closed) rather than guessed from monitor/window geometry.
  if (api.check_any != nullptr && api.check_any() == FALSE)
    return ExclusiveOwnership::kNotExclusive;
  return ExclusiveOwnership::kUnknown;
}

fushi::attached_overlayability::ExclusiveOwnership CombineExclusiveOwnership(
    fushi::attached_overlayability::ExclusiveOwnership source,
    fushi::attached_overlayability::ExclusiveOwnership presentation) {
  using fushi::attached_overlayability::ExclusiveOwnership;
  if (source == ExclusiveOwnership::kExclusive ||
      presentation == ExclusiveOwnership::kExclusive) {
    return ExclusiveOwnership::kExclusive;
  }
  if (source == ExclusiveOwnership::kNotExclusive &&
      presentation == ExclusiveOwnership::kNotExclusive) {
    return ExclusiveOwnership::kNotExclusive;
  }
  return ExclusiveOwnership::kUnknown;
}

bool QueryWindowCloak(HWND hwnd, bool *cloaked) {
  if (cloaked == nullptr || hwnd == nullptr || !IsWindow(hwnd))
    return false;
  DWORD value = 0;
  if (FAILED(
          DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &value, sizeof(value)))) {
    return false;
  }
  *cloaked = value != 0;
  return true;
}

uint32_t PremultipliedPixel(UCHAR alpha, UCHAR red, UCHAR green, UCHAR blue) {
  const uint32_t r = (static_cast<uint32_t>(red) * alpha) / 255;
  const uint32_t g = (static_cast<uint32_t>(green) * alpha) / 255;
  const uint32_t b = (static_cast<uint32_t>(blue) * alpha) / 255;
  return (static_cast<uint32_t>(alpha) << 24) | (r << 16) | (g << 8) | b;
}

} // namespace

AttachedTextSurfaceWindow *AttachedTextSurfaceWindow::active_instance_ =
    nullptr;

AttachedTextSurfaceWindow::AttachedTextSurfaceWindow() = default;

AttachedTextSurfaceWindow::~AttachedTextSurfaceWindow() {
  DestroySurfaceWindow();
}

bool AttachedTextSurfaceWindow::IsEpochValid(const Epoch &epoch) {
  return epoch.session != 0 && epoch.surface != 0;
}

int AttachedTextSurfaceWindow::CompareEpoch(const Epoch &left,
                                            const Epoch &right) {
  if (left.session < right.session)
    return -1;
  if (left.session > right.session)
    return 1;
  if (left.surface < right.surface)
    return -1;
  if (left.surface > right.surface)
    return 1;
  return 0;
}

bool AttachedTextSurfaceWindow::IsNormalizedRectValid(
    const NormalizedRect &rect) {
  return fushi::attached_text_layout::IsNormalizedRectValid(rect);
}

AttachedTextSurfaceWindow::NormalizedRect
AttachedTextSurfaceWindow::ClampNormalizedRect(const NormalizedRect &rect) {
  NormalizedRect clamped;
  clamped.left = std::clamp(rect.left, 0.0, 1.0);
  clamped.top = std::clamp(rect.top, 0.0, 1.0);
  clamped.width = std::clamp(rect.width, 0.0, 1.0 - clamped.left);
  clamped.height = std::clamp(rect.height, 0.0, 1.0 - clamped.top);
  return clamped;
}

void AttachedTextSurfaceWindow::AdoptNewEpoch(const Epoch &epoch,
                                              bool session_changed) {
  CancelPointerGesture();
  HideSurface();
  ResetShieldHandshake();
  shield_status_ = ShieldStatus{};
  epoch_ = epoch;
  source_text_.clear();
  source_text_utf8_.clear();
  text_generation_ = 0;
  text_layout_.Reset();
  clusters_.clear();
  layout_dirty_ = true;
  input_mode_.clear();
  surface_mode_ = "attachedOnly";
  // A new surface epoch is a new HWND/profile identity transaction even when
  // it belongs to the same game session. Re-resolve and re-fingerprint rather
  // than carrying a possibly reused HWND across the epoch fence.
  (void)session_changed;
  target_ = TargetInfo{};
  launch_exe_path_.clear();
  mode_ = Mode::kDetached;
  body_rect_ = NormalizedRect{};
  calibration_rect_ = NormalizedRect{};
  pre_calibration_rect_ = NormalizedRect{};
  pre_calibration_configured_ = false;
  surface_geometry_ = SurfaceGeometry{};
  magpie_mapping_active_ = false;
  source_body_screen_rect_ = RECT{};
  mapped_body_screen_rect_ = RECT{};
  presentation_dpi_ = 96;
  probe_start_index_ = -1;
  probe_middle_index_ = -1;
  probe_end_index_ = -1;
  calibration_probe_mask_ = 0;
  ResetObservedCalibrationProbes();
  presentation_hwnd_ = nullptr;
  fushi::attached_capture_token::Reset(&capture_token_);
  provider_status_ = GeometryProviderStatus{};
  native_provider_retire_pending_ = false;
  state_ = "detached";
  status_ = state_;
  reason_.clear();
  last_emitted_signature_.clear();
}

AttachedTextSurfaceWindow::RequestResult
AttachedTextSurfaceWindow::AcceptRequest(const Epoch &epoch,
                                         uint32_t target_pid, HWND target_hwnd,
                                         bool resolve_if_needed,
                                         std::string *error) {
  if (error != nullptr)
    error->clear();
  if (!IsEpochValid(epoch)) {
    if (error != nullptr)
      *error = "invalid_epoch";
    return RequestResult::kRejected;
  }
  const int epoch_order =
      IsEpochValid(epoch_) ? CompareEpoch(epoch, epoch_) : 1;
  if (epoch_order < 0) {
    if (error != nullptr)
      *error = "stale_epoch";
    return RequestResult::kStale;
  }
  if (epoch_order > 0) {
    const bool session_changed =
        epoch_.session == 0 || epoch.session != epoch_.session;
    AdoptNewEpoch(epoch, session_changed);
  }

  if (target_pid == 0) {
    if (error != nullptr)
      *error = "invalid_target_pid";
    return RequestResult::kRejected;
  }
  if (target_.pid != 0 && target_.pid != target_pid) {
    if (error != nullptr)
      *error = "target_identity_mismatch";
    return RequestResult::kRejected;
  }
  if (target_hwnd != nullptr && target_.hwnd != nullptr &&
      CanonicalSourceWindow(target_hwnd) != target_.hwnd) {
    if (error != nullptr)
      *error = "target_identity_mismatch";
    return RequestResult::kRejected;
  }

  if (resolve_if_needed &&
      (target_.hwnd == nullptr || !IsWindow(target_.hwnd))) {
    TargetInfo resolved;
    if (!ResolveTarget(target_pid, target_hwnd, &resolved, error)) {
      mode_ = Mode::kDetached;
      SetState("error", "targetUnavailable",
               error != nullptr ? *error : "target_unavailable");
      EmitStateIfChanged();
      return RequestResult::kRejected;
    }
    if (target_.hwnd != nullptr && resolved.hwnd != target_.hwnd) {
      HideSurface();
      ResetShieldHandshake();
      shield_status_ = ShieldStatus{};
    }
    target_ = std::move(resolved);
    RefreshPresentationWindow();
    mode_ = Mode::kTargetReady;
  }
  return RequestResult::kApplied;
}

bool AttachedTextSurfaceWindow::ResolveTarget(uint32_t target_pid,
                                              HWND requested_hwnd,
                                              TargetInfo *target,
                                              std::string *error) const {
  if (target == nullptr || target_pid == 0) {
    if (error != nullptr)
      *error = "invalid_target";
    return false;
  }
  HWND hwnd = nullptr;
  if (requested_hwnd != nullptr) {
    hwnd = CanonicalSourceWindow(requested_hwnd);
    if (hwnd == nullptr) {
      if (error != nullptr)
        *error = "target_window_not_found";
      return false;
    }
    DWORD observed_pid = 0;
    GetWindowThreadProcessId(hwnd, &observed_pid);
    if (!IsWindow(hwnd) || observed_pid != target_pid) {
      if (error != nullptr)
        *error = "target_hwnd_pid_mismatch";
      return false;
    }
  } else {
    hwnd = FindTargetWindow(target_pid);
  }
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    if (error != nullptr)
      *error = "target_window_not_found";
    return false;
  }

  const RECT client = ClientScreenRect(hwnd);
  if (!RectHasArea(client)) {
    if (error != nullptr)
      *error = "target_client_unavailable";
    return false;
  }

  std::wstring exe_path = launch_exe_path_;
  if (exe_path.empty() && !ExecutablePathForPid(target_pid, &exe_path)) {
    if (error != nullptr)
      *error = "target_exe_path_unavailable";
    return false;
  }
  const DWORD exe_attributes = GetFileAttributesW(exe_path.c_str());
  if (exe_attributes == INVALID_FILE_ATTRIBUTES ||
      (exe_attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    if (error != nullptr)
      *error = "target_exe_path_invalid";
    return false;
  }
  const std::string digest = Sha256File(exe_path);
  if (digest.size() != 64) {
    if (error != nullptr)
      *error = "target_exe_hash_unavailable";
    return false;
  }

  target->pid = target_pid;
  target->hwnd = hwnd;
  target->exe_path = WideToUtf8(exe_path);
  target->exe_sha256 = digest;
  target->reference_client.width_px = client.right - client.left;
  target->reference_client.height_px = client.bottom - client.top;
  UINT dpi = GetDpiForWindow(hwnd);
  target->reference_client.dpi = static_cast<int>(dpi == 0 ? 96 : dpi);
  return true;
}

void AttachedTextSurfaceWindow::RefreshPresentationWindow() {
  if (target_.hwnd == nullptr || !IsWindow(target_.hwnd)) {
    presentation_hwnd_ = nullptr;
    return;
  }
  if (presentation_hwnd_ != nullptr && IsWindow(presentation_hwnd_) &&
      fushi::ResolveScalingSourceWindow(presentation_hwnd_) == target_.hwnd) {
    return;
  }
  const HWND presentation = FindPresentationWindow(target_.hwnd);
  presentation_hwnd_ = presentation != nullptr ? presentation : target_.hwnd;
}

bool AttachedTextSurfaceWindow::TryRebindTarget(std::string *error) {
  if (target_.pid == 0) {
    if (error != nullptr)
      *error = "target_window_unavailable";
    return false;
  }
  TargetInfo rebound;
  if (!ResolveTarget(target_.pid, nullptr, &rebound, error))
    return false;
  if (target_.exe_sha256.empty() || rebound.exe_sha256 != target_.exe_sha256) {
    if (error != nullptr)
      *error = "target_exe_identity_changed";
    return false;
  }
  HideSurface();
  ResetShieldHandshake();
  shield_status_ = ShieldStatus{};
  target_ = std::move(rebound);
  RefreshPresentationWindow();
  layout_dirty_ = true;
  return true;
}

bool AttachedTextSurfaceWindow::RefreshTargetClient(RECT *client_screen,
                                                    ReferenceClient *reference,
                                                    std::string *error) {
  if (client_screen == nullptr || reference == nullptr) {
    if (error != nullptr)
      *error = "target_window_unavailable";
    return false;
  }
  if (target_.hwnd == nullptr || !IsWindow(target_.hwnd)) {
    if (!TryRebindTarget(error))
      return false;
  }
  DWORD pid = 0;
  GetWindowThreadProcessId(target_.hwnd, &pid);
  if (pid != target_.pid) {
    if (error != nullptr)
      *error = "target_hwnd_reused";
    return false;
  }
  RefreshPresentationWindow();
  const HWND geometry_window =
      presentation_hwnd_ != nullptr ? presentation_hwnd_ : target_.hwnd;
  if (WindowIsCloaked(target_.hwnd) || WindowIsCloaked(geometry_window)) {
    if (error != nullptr)
      *error = "target_cloaked";
    return false;
  }
  RECT client = ClientScreenRect(geometry_window);
  if (!RectHasArea(client)) {
    if (error != nullptr)
      *error = "target_client_unavailable";
    return false;
  }
  const RECT source_client = ClientScreenRect(target_.hwnd);
  if (!RectHasArea(source_client)) {
    if (error != nullptr)
      *error = "target_source_client_unavailable";
    return false;
  }
  SurfaceGeometry geometry;
  magpie_mapping_active_ = false;
  geometry.source_client_screen = source_client;
  geometry.source_viewport_screen = source_client;
  geometry.presentation_client_screen = client;
  geometry.destination_viewport_screen = client;
  // Magpie may letterbox or crop the source inside a larger presentation
  // client. Its public viewport properties are the only trustworthy mapping
  // for that case; using the whole client shifts every calibrated hit box.
  if (geometry_window != target_.hwnd &&
      fushi::ResolveScalingSourceWindow(geometry_window) == target_.hwnd) {
    fushi::MagpiePresentationMapping mapping;
    if (!fushi::ReadMagpiePresentationMapping(geometry_window, target_.hwnd,
                                              &mapping)) {
      if (error != nullptr)
        *error = "magpie_viewport_unavailable";
      return false;
    }
    geometry.source_viewport_screen = mapping.source_rect_screen;
    geometry.destination_viewport_screen = mapping.destination_rect_screen;
    if (!fushi::attached_magpie_surface_geometry::RectContainedIn(
            geometry.destination_viewport_screen,
            geometry.presentation_client_screen)) {
      if (error != nullptr)
        *error = "magpie_viewport_outside_presentation";
      return false;
    }
    if (!fushi::attached_magpie_surface_geometry::RectContainedIn(
            geometry.source_viewport_screen, geometry.source_client_screen)) {
      if (error != nullptr)
        *error = "magpie_source_viewport_invalid";
      return false;
    }
    if (!fushi::attached_magpie_surface_geometry::IsMappingValid(geometry)) {
      if (error != nullptr)
        *error = "magpie_viewport_invalid";
      return false;
    }
    magpie_mapping_active_ = true;
  }
  if (!fushi::attached_magpie_surface_geometry::IsMappingValid(geometry)) {
    if (error != nullptr)
      *error = "target_client_unavailable";
    return false;
  }
  const UINT source_dpi = GetDpiForWindow(target_.hwnd);
  const UINT presentation_dpi = GetDpiForWindow(geometry_window);
  surface_geometry_ = geometry;
  presentation_dpi_ = static_cast<int>(presentation_dpi == 0 ? 96
                                                               : presentation_dpi);
  *client_screen = geometry.destination_viewport_screen;
  reference->width_px = source_client.right - source_client.left;
  reference->height_px = source_client.bottom - source_client.top;
  reference->dpi = static_cast<int>(source_dpi == 0 ? 96 : source_dpi);
  return true;
}

bool AttachedTextSurfaceWindow::TargetIsForeground() const {
  if (target_.hwnd == nullptr)
    return false;
  const HWND foreground = GetForegroundWindow();
  if (foreground == nullptr)
    return false;
  if (foreground == target_.hwnd || IsChild(target_.hwnd, foreground) ||
      foreground == presentation_hwnd_ ||
      (presentation_hwnd_ != nullptr &&
       IsChild(presentation_hwnd_, foreground))) {
    return true;
  }
  // BUG-2140：查词卡是**本进程**为这个游戏打开的卡，它拿到焦点恰恰是「用户刚点了一个
  // 词」的结果。旧判据只认游戏 HWND 前台，于是第一次查词必然把表面挂起
  // （suspended/targetBackground）、命中区域随之清空，用户紧接着点的那一下就不再被吞
  // ——真机上表现为「第一次能查到词，之后每次点击都穿透并推进剧情」。
  // 放行范围严格限定为「带着本游戏 owner 标记的本进程查词卡」，不放宽到同 PID 任意
  // 窗口：alt-tab 到 Fushi 主窗时表面必须照旧挂起。
  if (fushi::IsLookupCardConsumingForOwner(foreground, target_.hwnd)) {
    return true;
  }
  // Same PID is not identity: launchers, settings and video/helper windows can
  // share the game process. Only the inspected source hierarchy or the
  // ResolveScalingSourceWindow-verified presentation HWND may keep the surface
  // live. Same-PID enumeration is reserved for dead-HWND rebind.
  return false;
}

AttachedTextSurfaceWindow::RequestResult
AttachedTextSurfaceWindow::InspectTarget(const Epoch &epoch,
                                         uint32_t target_pid,
                                         HWND requested_hwnd,
                                         const std::wstring &launch_exe_path,
                                         std::string *error) {
  const RequestResult accepted =
      AcceptRequest(epoch, target_pid, requested_hwnd, false, error);
  if (accepted != RequestResult::kApplied)
    return accepted;
  if (!launch_exe_path.empty() && !IsAbsoluteWindowsPath(launch_exe_path)) {
    if (error != nullptr)
      *error = "launch_exe_path_not_absolute";
    SetState("error", "targetUnavailable",
             error != nullptr ? *error : "launch_exe_path_not_absolute");
    EmitStateIfChanged(true);
    return RequestResult::kRejected;
  }
  launch_exe_path_ = launch_exe_path;
  TargetInfo resolved;
  if (!ResolveTarget(target_pid, requested_hwnd, &resolved, error)) {
    mode_ = Mode::kDetached;
    SetState("error", "targetUnavailable",
             error != nullptr ? *error : "target_unavailable");
    EmitStateIfChanged(true);
    return RequestResult::kRejected;
  }
  target_ = std::move(resolved);
  RefreshPresentationWindow();
  mode_ = Mode::kTargetReady;
  RECT client{};
  ReferenceClient reference;
  if (!RefreshTargetClient(&client, &reference, error)) {
    SetState("error", "targetUnavailable",
             error != nullptr ? *error : "target_unavailable");
    EmitStateIfChanged(true);
    return RequestResult::kRejected;
  }
  target_.reference_client = reference;
  if (mode_ == Mode::kDetached)
    mode_ = Mode::kTargetReady;
  live_reference_client_ = target_.reference_client;
  if (!EnsureWindow(error)) {
    SetState("error", "surfaceUnavailable",
             error != nullptr ? *error : "surface_unavailable");
    EmitStateIfChanged(true);
    return RequestResult::kRejected;
  }
  const ShieldHandshakeState handshake = EnsureShieldHandshake();
  RefreshGeometryProviderStatus();
  if (handshake != ShieldHandshakeState::kReady) {
    HideSurface();
    SetState("suspended", "shieldHandshakePending",
             handshake == ShieldHandshakeState::kUnavailable
                 ? "input_shield_handshake_unavailable"
                 : "input_shield_rehandshake_pending");
    EmitStateIfChanged(true);
    return RequestResult::kApplied;
  }
  SetState("targetReady", "ready");
  EmitStateIfChanged(true);
  return RequestResult::kApplied;
}

AttachedTextSurfaceWindow::RequestResult
AttachedTextSurfaceWindow::StartCalibration(
    const Epoch &epoch, uint32_t target_pid, HWND target_hwnd,
    const NormalizedRect *initial_rect, const ReferenceClient &reference_client,
    const Layout &layout, bool /*risk_accepted*/, const std::string &input_mode,
    std::string *error) {
  const RequestResult accepted =
      AcceptRequest(epoch, target_pid, target_hwnd, true, error);
  if (accepted != RequestResult::kApplied)
    return accepted;
  if (initial_rect != nullptr && !IsNormalizedRectValid(*initial_rect)) {
    if (error != nullptr)
      *error = "invalid_body_rect";
    return RequestResult::kRejected;
  }
  if (!fushi::attached_layout_validation::IsLayoutValid(
          layout.font_size_per_client_height,
          layout.letter_spacing_per_client_height, layout.line_height,
          layout.text_align, layout.vertical_align,
          layout.padding_per_client_height) ||
      (layout.cell_grid.has_value() &&
       !fushi::attached_text_layout::IsCellGridValid(*layout.cell_grid)) ||
      !fushi::attached_text_layout::IsPunctuationVisualBoundsListValid(
          layout) ||
      !fushi::attached_text_layout::IsCharacterAdvancesListValid(layout)) {
    if (error != nullptr)
      *error = "invalid_layout";
    return RequestResult::kRejected;
  }
  if (!input_mode.empty() && input_mode != "unsafeLeftClick") {
    if (error != nullptr)
      *error = "unsupported_input_mode";
    return RequestResult::kRejected;
  }
  if (!EnsureWindow(error))
    return RequestResult::kRejected;

  configured_reference_client_ = reference_client;
  layout_ = layout;
  if (layout_.font_family.empty())
    layout_.font_family = L"Yu Gothic";
  input_mode_ = input_mode.empty() ? "unsafeLeftClick" : input_mode;
  surface_mode_ = "attachedOnly";

  pre_calibration_configured_ = mode_ == Mode::kConfigured;
  pre_calibration_rect_ = body_rect_;
  HideSurface();
  probe_start_index_ = -1;
  probe_middle_index_ = -1;
  probe_end_index_ = -1;
  calibration_probe_mask_ = 0;
  ResetObservedCalibrationProbes();
  if (initial_rect != nullptr && IsNormalizedRectValid(*initial_rect)) {
    calibration_rect_ = *initial_rect;
  } else if (IsNormalizedRectValid(body_rect_)) {
    calibration_rect_ = body_rect_;
  } else {
    calibration_rect_ = NormalizedRect{0.08, 0.68, 0.84, 0.24};
  }
  mode_ = Mode::kCalibration;
  layout_dirty_ = true;
  SetState("calibrating", "calibrating");
  SyncToTarget();
  EmitStateIfChanged(true);
  return RequestResult::kApplied;
}

AttachedTextSurfaceWindow::RequestResult
AttachedTextSurfaceWindow::UpdateCalibration(const Epoch &epoch,
                                             uint32_t target_pid,
                                             HWND target_hwnd,
                                             const NormalizedRect &body_rect,
                                             const CalibrationProbes &probes,
                                             std::string *error) {
  const RequestResult accepted =
      AcceptRequest(epoch, target_pid, target_hwnd, true, error);
  if (accepted != RequestResult::kApplied)
    return accepted;
  if (mode_ != Mode::kCalibration) {
    if (error != nullptr)
      *error = "calibration_not_active";
    return RequestResult::kRejected;
  }
  if (!IsNormalizedRectValid(body_rect)) {
    if (error != nullptr)
      *error = "invalid_body_rect";
    return RequestResult::kRejected;
  }
  if (!ApplyCalibrationProbes(probes, error)) {
    return RequestResult::kRejected;
  }
  const bool rect_changed =
      std::abs(calibration_rect_.left - body_rect.left) > 1e-9 ||
      std::abs(calibration_rect_.top - body_rect.top) > 1e-9 ||
      std::abs(calibration_rect_.width - body_rect.width) > 1e-9 ||
      std::abs(calibration_rect_.height - body_rect.height) > 1e-9;
  if (rect_changed) {
    ResetObservedCalibrationProbes();
    layout_dirty_ = true;
  }
  calibration_rect_ = body_rect;
  SyncToTarget();
  EmitStateIfChanged(true);
  return RequestResult::kApplied;
}

AttachedTextSurfaceWindow::RequestResult
AttachedTextSurfaceWindow::CommitCalibration(const Epoch &epoch,
                                             uint32_t target_pid,
                                             HWND target_hwnd,
                                             const CalibrationProbes &probes,
                                             std::string *error) {
  const RequestResult accepted =
      AcceptRequest(epoch, target_pid, target_hwnd, true, error);
  if (accepted != RequestResult::kApplied)
    return accepted;
  if (mode_ != Mode::kCalibration ||
      !IsNormalizedRectValid(calibration_rect_)) {
    if (error != nullptr)
      *error = "invalid_calibration";
    return RequestResult::kRejected;
  }
  if (!ApplyCalibrationProbes(probes, error) ||
      !CalibrationProbesComplete(error)) {
    return RequestResult::kRejected;
  }
  body_rect_ = calibration_rect_;
  HideSurface();
  mode_ = pre_calibration_configured_ ? Mode::kConfigured : Mode::kTargetReady;
  layout_dirty_ = true;
  NotifyCalibrationCommitted();
  SyncToTarget();
  return RequestResult::kApplied;
}

bool AttachedTextSurfaceWindow::ApplyCalibrationProbes(
    const CalibrationProbes &probes, std::string *error) {
  const auto apply = [&](uint32_t bit, int64_t index, int64_t *destination) {
    if ((probes.provided_mask & bit) == 0)
      return true;
    if (index < 0)
      return false;
    *destination = index;
    if ((probes.confirmed_mask & bit) != 0) {
      calibration_probe_mask_ |= bit;
    } else {
      calibration_probe_mask_ &= ~bit;
    }
    return true;
  };
  if (!apply(kProbeStartMask, probes.start_index, &probe_start_index_) ||
      !apply(kProbeMiddleMask, probes.middle_index, &probe_middle_index_) ||
      !apply(kProbeEndMask, probes.end_index, &probe_end_index_)) {
    if (error != nullptr)
      *error = "invalid_calibration_probe";
    return false;
  }
  return true;
}

bool AttachedTextSurfaceWindow::CalibrationProbesComplete(
    std::string *error) const {
  const bool ordered = probe_start_index_ >= 0 &&
                       probe_start_index_ < probe_middle_index_ &&
                       probe_middle_index_ < probe_end_index_;
  const bool in_source =
      !source_text_.empty() &&
      static_cast<uint64_t>(probe_end_index_) < source_text_.size();
  const bool observed =
      probe_start_observed_index_ >= 0 &&
      probe_start_observed_index_ < probe_middle_observed_index_ &&
      probe_middle_observed_index_ < probe_end_observed_index_ &&
      static_cast<uint64_t>(probe_end_observed_index_) < source_text_.size();
  const bool pinned = !calibration_probe_source_.empty() &&
                      calibration_probe_source_ == source_text_ &&
                      calibration_probe_text_generation_ == text_generation_;
  const bool matches = probe_start_index_ == probe_start_observed_index_ &&
                       probe_middle_index_ == probe_middle_observed_index_ &&
                       probe_end_index_ == probe_end_observed_index_;
  if (calibration_probe_mask_ != kAllProbeMask || !ordered || !in_source ||
      !observed || !pinned || !matches) {
    if (error != nullptr)
      *error = !observed || !pinned
                   ? "calibration_probe_observation_incomplete"
                   : (!matches ? "calibration_probe_observation_mismatch"
                               : "calibration_probes_incomplete");
    return false;
  }
  return true;
}

void AttachedTextSurfaceWindow::ResetObservedCalibrationProbes() {
  probe_start_observed_index_ = -1;
  probe_middle_observed_index_ = -1;
  probe_end_observed_index_ = -1;
  calibration_probe_source_.clear();
  calibration_probe_text_generation_ = 0;
}

bool AttachedTextSurfaceWindow::RecordObservedCalibrationProbe(
    POINT client_point, std::string *error) {
  if (mode_ != Mode::kCalibration || source_text_.empty() ||
      text_generation_ <= 0 || layout_dirty_ || clusters_.empty()) {
    if (error != nullptr)
      *error = "calibration_probe_layout_unavailable";
    return false;
  }
  const int cluster_index = ClusterAt(client_point);
  if (cluster_index < 0 ||
      static_cast<size_t>(cluster_index) >= clusters_.size()) {
    if (error != nullptr)
      *error = "calibration_probe_miss";
    return false;
  }
  const int64_t observed = static_cast<int64_t>(
      clusters_[static_cast<size_t>(cluster_index)].text_position);
  if (calibration_probe_source_.empty()) {
    calibration_probe_source_ = source_text_;
    calibration_probe_text_generation_ = text_generation_;
  } else if (calibration_probe_source_ != source_text_ ||
             calibration_probe_text_generation_ != text_generation_) {
    ResetObservedCalibrationProbes();
    if (error != nullptr)
      *error = "calibration_probe_generation_changed";
    return false;
  }

  if (probe_start_observed_index_ < 0) {
    probe_start_observed_index_ = observed;
  } else if (probe_middle_observed_index_ < 0) {
    if (observed <= probe_start_observed_index_) {
      if (error != nullptr)
        *error = "calibration_probe_order_invalid";
      return false;
    }
    probe_middle_observed_index_ = observed;
  } else if (probe_end_observed_index_ < 0) {
    if (observed <= probe_middle_observed_index_) {
      if (error != nullptr)
        *error = "calibration_probe_order_invalid";
      return false;
    }
    probe_end_observed_index_ = observed;
  } else {
    if (error != nullptr)
      *error = "calibration_probes_already_observed";
    return false;
  }
  return true;
}

AttachedTextSurfaceWindow::RequestResult
AttachedTextSurfaceWindow::CancelCalibration(const Epoch &epoch,
                                             uint32_t target_pid,
                                             HWND target_hwnd,
                                             const std::string &reason,
                                             std::string *error) {
  const RequestResult accepted =
      AcceptRequest(epoch, target_pid, target_hwnd, true, error);
  if (accepted != RequestResult::kApplied)
    return accepted;
  if (mode_ != Mode::kCalibration) {
    if (error != nullptr)
      *error = "calibration_not_active";
    return RequestResult::kRejected;
  }
  body_rect_ = pre_calibration_rect_;
  HideSurface();
  mode_ = pre_calibration_configured_ ? Mode::kConfigured : Mode::kTargetReady;
  layout_dirty_ = true;
  NotifyCalibrationCancelled(reason.empty() ? "cancelled" : reason);
  SyncToTarget();
  return RequestResult::kApplied;
}

AttachedTextSurfaceWindow::RequestResult AttachedTextSurfaceWindow::Configure(
    const Epoch &epoch, uint32_t target_pid, HWND target_hwnd,
    const NormalizedRect &body_rect, const ReferenceClient &reference_client,
    const Layout &layout, bool /*risk_accepted*/, const std::string &input_mode,
    const std::string &surface_mode, std::string *error) {
  const RequestResult accepted =
      AcceptRequest(epoch, target_pid, target_hwnd, true, error);
  if (accepted != RequestResult::kApplied)
    return accepted;
  if (!IsNormalizedRectValid(body_rect)) {
    if (error != nullptr)
      *error = "invalid_body_rect";
    return RequestResult::kRejected;
  }
  if (!input_mode.empty() && input_mode != "unsafeLeftClick") {
    if (error != nullptr)
      *error = "unsupported_input_mode";
    return RequestResult::kRejected;
  }
  const std::string requested_surface_mode =
      surface_mode.empty() ? "attachedOnly" : surface_mode;
  if (requested_surface_mode != "auto" &&
      requested_surface_mode != "attachedOnly") {
    if (error != nullptr)
      *error = "unsupported_surface_mode";
    return RequestResult::kRejected;
  }
  if (!fushi::attached_layout_validation::IsLayoutValid(
          layout.font_size_per_client_height,
          layout.letter_spacing_per_client_height, layout.line_height,
          layout.text_align, layout.vertical_align,
          layout.padding_per_client_height) ||
      (layout.cell_grid.has_value() &&
       !fushi::attached_text_layout::IsCellGridValid(*layout.cell_grid)) ||
      !fushi::attached_text_layout::IsPunctuationVisualBoundsListValid(
          layout) ||
      !fushi::attached_text_layout::IsCharacterAdvancesListValid(layout)) {
    if (error != nullptr)
      *error = "invalid_layout";
    return RequestResult::kRejected;
  }

  body_rect_ = body_rect;
  configured_reference_client_ = reference_client;
  layout_ = layout;
  if (layout_.font_family.empty())
    layout_.font_family = L"Yu Gothic";
  input_mode_ = "unsafeLeftClick";
  surface_mode_ = requested_surface_mode;
  mode_ = Mode::kConfigured;
  layout_dirty_ = true;
  if (!EnsureWindow(error))
    return RequestResult::kRejected;
  const ShieldHandshakeState handshake = EnsureShieldHandshake();
  RefreshGeometryProviderStatus();
  if (handshake != ShieldHandshakeState::kReady) {
    HideSurface();
    SetState("suspended", "shieldHandshakePending",
             handshake == ShieldHandshakeState::kUnavailable
                 ? "input_shield_handshake_unavailable"
                 : "input_shield_rehandshake_pending");
    EmitStateIfChanged(true);
    return RequestResult::kApplied;
  }
  if (ShieldFaulted()) {
    HideSurface();
    SetState("error", "shieldFaulted", "input_shield_faulted");
    EmitStateIfChanged(true);
    if (error != nullptr)
      *error = "input_shield_faulted";
    return RequestResult::kRejected;
  }
  if (!ShieldPermitsLookup()) {
    HideSurface();
    SetState("suspended", "shieldHandshakePending",
             "input_shield_rehandshake_pending");
    EmitStateIfChanged(true);
    return RequestResult::kApplied;
  }
  if (surface_mode_ == "auto" && NativeProviderPreferred()) {
    // Native admission depends on the live target/presentation transport.  In
    // particular, a generic native geometry provider does not make a layered
    // popup work in exclusive fullscreen.  Keep that decision centralized in
    // SyncToTarget so Configure cannot bypass the same gate used by the health
    // timer and WinEvent path.
    SyncToTarget();
    return RequestResult::kApplied;
  }
  SetState("ready", "ready");
  SyncToTarget();
  return RequestResult::kApplied;
}

AttachedTextSurfaceWindow::RequestResult AttachedTextSurfaceWindow::UpdateText(
    const Epoch &epoch, uint32_t target_pid, HWND target_hwnd,
    const std::wstring &source_text, int64_t text_generation,
    const std::string &writing_mode, std::string *error) {
  const RequestResult accepted =
      AcceptRequest(epoch, target_pid, target_hwnd, true, error);
  if (accepted != RequestResult::kApplied)
    return accepted;
  if (text_generation <= 0) {
    if (error != nullptr)
      *error = "invalid_text_generation";
    return RequestResult::kRejected;
  }
  if (text_generation < text_generation_) {
    if (error != nullptr)
      *error = "stale_text_generation";
    return RequestResult::kStale;
  }
  if (source_text.size() > kMaximumSourceTextUnits) {
    if (error != nullptr)
      *error = "source_text_too_large";
    return RequestResult::kRejected;
  }
  const std::string mode = writing_mode.empty() ? "horizontal" : writing_mode;
  if (mode != "horizontal") {
    if (error != nullptr)
      *error = "unsupported_writing_mode";
    return RequestResult::kRejected;
  }
  // Never leave the previous sentence's region live while a replacement
  // DirectWrite layout is being built. This cancels submission for the old
  // generation; the LL layer still owns its matching physical release tail.
  const bool calibration_text_changed =
      mode_ == Mode::kCalibration &&
      (source_text_ != source_text || text_generation_ != text_generation);
  ClearInteractiveRegion();
  if (calibration_text_changed)
    ResetObservedCalibrationProbes();
  source_text_ = source_text;
  source_text_utf8_ = WideToUtf8(source_text);
  text_generation_ = text_generation;
  writing_mode_ = mode;
  layout_dirty_ = true;
  SyncToTarget();
  return RequestResult::kApplied;
}

AttachedTextSurfaceWindow::RequestResult
AttachedTextSurfaceWindow::UpdateStyle(const Epoch &epoch, uint32_t target_pid,
                                       HWND target_hwnd, const Layout &layout,
                                       std::string *error) {
  const RequestResult accepted =
      AcceptRequest(epoch, target_pid, target_hwnd, true, error);
  if (accepted != RequestResult::kApplied)
    return accepted;
  if (!fushi::attached_layout_validation::IsLayoutValid(
          layout.font_size_per_client_height,
          layout.letter_spacing_per_client_height, layout.line_height,
          layout.text_align, layout.vertical_align,
          layout.padding_per_client_height) ||
      (layout.cell_grid.has_value() &&
       !fushi::attached_text_layout::IsCellGridValid(*layout.cell_grid)) ||
      !fushi::attached_text_layout::IsPunctuationVisualBoundsListValid(
          layout) ||
      !fushi::attached_text_layout::IsCharacterAdvancesListValid(layout)) {
    if (error != nullptr)
      *error = "invalid_layout";
    return RequestResult::kRejected;
  }
  Layout desired = layout;
  if (desired.font_family.empty())
    desired.font_family = L"Yu Gothic";
  const auto same_double = [](double left, double right) {
    return std::abs(left - right) <= 1e-12;
  };
  const auto same_punctuation_bounds = [&](const auto &left,
                                           const auto &right) {
    if (left.size() != right.size())
      return false;
    for (size_t index = 0; index < left.size(); ++index) {
      const auto &a = left[index];
      const auto &b = right[index];
      if (a.code_point != b.code_point ||
          !same_double(a.left, b.left) || !same_double(a.top, b.top) ||
          !same_double(a.right, b.right) || !same_double(a.bottom, b.bottom)) {
        return false;
      }
    }
    return true;
  };
  const auto same_character_advances = [&](const auto &left,
                                           const auto &right) {
    if (left.size() != right.size())
      return false;
    for (size_t index = 0; index < left.size(); ++index) {
      const auto &a = left[index];
      const auto &b = right[index];
      if (a.code_point != b.code_point ||
          !same_double(a.advance_ratio, b.advance_ratio)) {
        return false;
      }
    }
    return true;
  };
  const bool layout_changed =
      desired.cell_grid != layout_.cell_grid ||
      desired.quoted_text_only != layout_.quoted_text_only ||
      !same_punctuation_bounds(desired.punctuation_visual_bounds,
                               layout_.punctuation_visual_bounds) ||
      !same_character_advances(desired.character_advances,
                               layout_.character_advances) ||
      desired.punctuation_visual_bounds_valid !=
          layout_.punctuation_visual_bounds_valid ||
      desired.character_advances_valid != layout_.character_advances_valid ||
      desired.font_family != layout_.font_family ||
      !same_double(desired.font_size_per_client_height,
                   layout_.font_size_per_client_height) ||
      !same_double(desired.letter_spacing_per_client_height,
                   layout_.letter_spacing_per_client_height) ||
      !same_double(desired.line_height, layout_.line_height) ||
      desired.text_align != layout_.text_align ||
      desired.vertical_align != layout_.vertical_align ||
      !same_double(desired.padding_per_client_height,
                   layout_.padding_per_client_height);
  if (layout_changed) {
    if (mode_ == Mode::kCalibration)
      ResetObservedCalibrationProbes();
    layout_ = std::move(desired);
    layout_dirty_ = true;
    SyncToTarget();
  }
  return RequestResult::kApplied;
}

AttachedTextSurfaceWindow::RequestResult
AttachedTextSurfaceWindow::Detach(const Epoch &epoch, uint32_t target_pid,
                                  HWND target_hwnd, std::string *error) {
  const RequestResult accepted =
      AcceptRequest(epoch, target_pid, target_hwnd, false, error);
  if (accepted != RequestResult::kApplied)
    return accepted;
  CancelPointerGesture();
  HideSurface();
  ResetShieldHandshake();
  shield_status_ = ShieldStatus{};
  mode_ = Mode::kDetached;
  source_text_.clear();
  source_text_utf8_.clear();
  text_generation_ = 0;
  clusters_.clear();
  text_layout_.Reset();
  calibration_probe_mask_ = 0;
  probe_start_index_ = -1;
  probe_middle_index_ = -1;
  probe_end_index_ = -1;
  ResetObservedCalibrationProbes();
  fushi::attached_capture_token::Reset(&capture_token_);
  SetState("detached", "detached");
  EmitStateIfChanged(true);
  return RequestResult::kApplied;
}

AttachedTextSurfaceWindow::RequestResult
AttachedTextSurfaceWindow::SuspendForCapture(
    const Epoch &epoch, uint32_t target_pid, HWND target_hwnd,
    int64_t text_generation, uint64_t capture_generation, std::string *error) {
  if (!IsEpochValid(epoch_) || !IsEpochValid(epoch) ||
      CompareEpoch(epoch, epoch_) != 0) {
    if (error != nullptr)
      *error = "stale_capture_epoch";
    return RequestResult::kStale;
  }
  const RequestResult accepted =
      AcceptRequest(epoch, target_pid, target_hwnd, false, error);
  if (accepted != RequestResult::kApplied)
    return accepted;
  if (mode_ == Mode::kDetached || capture_generation == 0 ||
      text_generation <= 0 || text_generation != text_generation_) {
    if (error != nullptr)
      *error = "invalid_capture_lease";
    return RequestResult::kRejected;
  }
  const fushi::attached_capture_token::BeginResult begin =
      fushi::attached_capture_token::Begin(
          &capture_token_, epoch_.session, epoch_.surface, capture_generation,
          text_generation_);
  if (begin == fushi::attached_capture_token::BeginResult::kBusy) {
    if (error != nullptr)
      *error = "capture_lease_busy";
    return RequestResult::kRejected;
  }
  if (begin == fushi::attached_capture_token::BeginResult::kInvalid) {
    if (error != nullptr)
      *error = "invalid_capture_lease";
    return RequestResult::kRejected;
  }
  if (begin == fushi::attached_capture_token::BeginResult::kSameToken) {
    return SUCCEEDED(DwmFlush()) ? RequestResult::kApplied
                                 : RequestResult::kRejected;
  }

  CancelPointerGesture();
  HideSurface();
  SetState("suspended", "captureSuppressed");
  EmitStateIfChanged(true);
  if (FAILED(DwmFlush())) {
    fushi::attached_capture_token::Reset(&capture_token_);
    SyncToTarget();
    if (error != nullptr)
      *error = "capture_dwm_flush_failed";
    return RequestResult::kRejected;
  }
  return RequestResult::kApplied;
}

AttachedTextSurfaceWindow::RequestResult
AttachedTextSurfaceWindow::RestoreAfterCapture(
    const Epoch &epoch, uint32_t target_pid, HWND target_hwnd,
    int64_t text_generation, uint64_t capture_generation, std::string *error) {
  if (!IsEpochValid(epoch_) || !IsEpochValid(epoch) ||
      CompareEpoch(epoch, epoch_) != 0) {
    if (error != nullptr)
      *error = "stale_capture_epoch";
    return RequestResult::kStale;
  }
  const RequestResult accepted =
      AcceptRequest(epoch, target_pid, target_hwnd, false, error);
  if (accepted != RequestResult::kApplied)
    return accepted;
  if (text_generation <= 0 ||
      !fushi::attached_capture_token::Release(
          &capture_token_, epoch_.session, epoch_.surface,
          capture_generation)) {
    if (error != nullptr)
      *error = "stale_capture_lease";
    return RequestResult::kStale;
  }

  // text_generation is the newest generation observed by Dart when it began
  // releasing the token. It is intentionally not an equality fence: a later
  // UpdateText may already have advanced text_generation_ while this request
  // was in flight. SyncToTarget always consumes that internal current value,
  // so acquisition-time geometry can never be resurrected.
  SyncToTarget();
  const HRESULT barrier = DwmFlush();
  // The exact-token lease is single-use even when the compositor cannot
  // acknowledge the restore barrier.  Re-suppressing here strands an
  // otherwise healthy catch surface forever: Dart has already released the
  // lease and cannot legally replay it.  Keep the current generation restored
  // (fail-open for lookup availability), return a rejection so mining reports
  // the ambiguous barrier, and let the normal health loop continue syncing.
  if (FAILED(barrier)) {
    if (error != nullptr)
      *error = "capture_dwm_flush_failed";
    return RequestResult::kRejected;
  }
  return RequestResult::kApplied;
}

bool AttachedTextSurfaceWindow::DesktopOverlayAvailableForTarget(
    uint32_t target_pid) {
  if (target_pid == 0 || target_pid != target_.pid ||
      mode_ == Mode::kDetached) {
    return false;
  }
  RECT client{};
  ReferenceClient reference;
  std::string error;
  if (!RefreshTargetClient(&client, &reference, &error))
    return false;
  return CurrentOverlayability().overlayable;
}

bool AttachedTextSurfaceWindow::EnsureWindow(std::string *error) {
  if (hwnd_ != nullptr && IsWindow(hwnd_))
    return true;
  HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSEXW existing{};
  existing.cbSize = sizeof(existing);
  if (!GetClassInfoExW(instance, kAttachedSurfaceClassName, &existing)) {
    WNDCLASSEXW window_class{};
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = AttachedTextSurfaceWindow::WndProc;
    window_class.hInstance = instance;
    window_class.hCursor = LoadCursorW(nullptr, IDC_HAND);
    window_class.lpszClassName = kAttachedSurfaceClassName;
    if (RegisterClassExW(&window_class) == 0 &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      if (error != nullptr)
        *error = "surface_class_registration_failed";
      return false;
    }
  }

  hwnd_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                          kAttachedSurfaceClassName, L"", WS_POPUP, 0, 0, 1, 1,
                          nullptr, nullptr, instance, this);
  if (hwnd_ == nullptr) {
    if (error != nullptr)
      *error = "surface_window_creation_failed";
    return false;
  }
  if (SetTimer(hwnd_, kFollowTimerId, kFollowTimerMs, nullptr) == 0) {
    if (error != nullptr)
      *error = "surface_follow_timer_failed";
    DestroySurfaceWindow();
    return false;
  }
  // Same lifetime as the follow timer; the tick itself gates on kConfigured +
  // clusters, so an idle surface only pays one GetAsyncKeyState per tick.
  if (SetTimer(hwnd_, kHoverTimerId, kHoverTimerMs, nullptr) == 0) {
    if (error != nullptr)
      *error = "surface_hover_timer_failed";
    DestroySurfaceWindow();
    return false;
  }
  active_instance_ = this;
  InstallWinEventHooks();
  return true;
}

void AttachedTextSurfaceWindow::DestroySurfaceWindow() {
  CancelPointerGesture();
  HideSurface();
  RemoveWinEventHooks();
  if (active_instance_ == this)
    active_instance_ = nullptr;
  hover_tracker_.Reset();
  hover_cluster_ = -1;
  if (hwnd_ != nullptr && IsWindow(hwnd_)) {
    KillTimer(hwnd_, kFollowTimerId);
    KillTimer(hwnd_, kHoverTimerId);
    StopShieldHandshakeWatchTimer();
    shield_handshake_watch_active_ = false;
    HWND old = hwnd_;
    // DestroySurfaceWindow clears the member and userdata before DestroyWindow,
    // so WM_NCDESTROY cannot recover |this| to retire the passive candidate.
    // Retire it explicitly while the concrete HWND is still known.
    fushi::RetireLowLevelAttachedGlyphRearmCandidate(old);
    hwnd_ = nullptr;
    SetWindowLongPtrW(old, GWLP_USERDATA, 0);
    DestroyWindow(old);
  }
}

void AttachedTextSurfaceWindow::InstallWinEventHooks() {
  RemoveWinEventHooks();
  constexpr DWORD flags = WINEVENT_OUTOFCONTEXT;
  foreground_event_hook_ =
      SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
                      AttachedTextSurfaceWindow::WinEventProc, 0, 0, flags);
  location_event_hook_ = SetWinEventHook(
      EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE, nullptr,
      AttachedTextSurfaceWindow::WinEventProc, 0, 0, flags);
  minimize_event_hook_ = SetWinEventHook(
      EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND, nullptr,
      AttachedTextSurfaceWindow::WinEventProc, 0, 0, flags);
}

void AttachedTextSurfaceWindow::RemoveWinEventHooks() {
  if (foreground_event_hook_ != nullptr) {
    UnhookWinEvent(foreground_event_hook_);
    foreground_event_hook_ = nullptr;
  }
  if (location_event_hook_ != nullptr) {
    UnhookWinEvent(location_event_hook_);
    location_event_hook_ = nullptr;
  }
  if (minimize_event_hook_ != nullptr) {
    UnhookWinEvent(minimize_event_hook_);
    minimize_event_hook_ = nullptr;
  }
}

void CALLBACK AttachedTextSurfaceWindow::WinEventProc(
    HWINEVENTHOOK hook, DWORD event, HWND event_hwnd, LONG object_id,
    LONG child_id, DWORD event_thread, DWORD event_time) noexcept {
  (void)hook;
  (void)child_id;
  (void)event_thread;
  (void)event_time;
  AttachedTextSurfaceWindow *self = active_instance_;
  if (self == nullptr || self->hwnd_ == nullptr || !IsWindow(self->hwnd_) ||
      event_hwnd == self->hwnd_) {
    return;
  }
  if (event == EVENT_OBJECT_LOCATIONCHANGE && object_id != OBJID_WINDOW &&
      object_id != OBJID_CLIENT) {
    return;
  }
  PostMessageW(self->hwnd_, kSyncTargetMessage, 0, 0);
}

void AttachedTextSurfaceWindow::SyncToTarget() {
  if (mode_ == Mode::kDetached || target_.hwnd == nullptr) {
    HideSurface();
    return;
  }
  const SurfaceGeometry previous_geometry = surface_geometry_;
  const RECT previous_source_body = source_body_screen_rect_;
  std::string error;
  RECT client{};
  ReferenceClient reference;
  if (!RefreshTargetClient(&client, &reference, &error)) {
    if (mode_ == Mode::kCalibration) {
      NotifyCalibrationCancelled("target_unavailable");
      mode_ = Mode::kTargetReady;
    }
    HideSurface();
    const bool mapping_unavailable = error.rfind("magpie_", 0) == 0;
    SetState(error == "target_cloaked" || mapping_unavailable ? "suspended"
                                                             : "error",
             error == "target_cloaked" ? "targetCloaked"
             : mapping_unavailable ? "targetMappingUnavailable"
                                   : "targetUnavailable",
             error);
    EmitStateIfChanged();
    return;
  }
  const ReferenceClient previous_reference = live_reference_client_;
  live_reference_client_ = reference;
  target_.reference_client = reference;
  RefreshShieldStatus();
  RefreshGeometryProviderStatus();
  const fushi::attached_overlayability::Evaluation overlayability =
      CurrentOverlayability();
  const bool native_provider_preferred = mode_ == Mode::kConfigured &&
                                         surface_mode_ == "auto" &&
                                         NativeProviderPreferred();
  const bool native_without_desktop_overlay =
      native_provider_preferred &&
      fushi::attached_overlayability::
          CanUseInProcessNativeWhenAttachedUnavailable(
              overlayability, NativeProviderCanPresentWithoutDesktopOverlay());
  if (capture_token_.active) {
    HideSurface();
    SetState("suspended", "captureSuppressed");
    EmitStateIfChanged();
    return;
  }
  const bool attached_surface_requires_ownership =
      mode_ == Mode::kCalibration ||
      (mode_ == Mode::kConfigured && !native_provider_preferred);
  if (attached_surface_requires_ownership && !AttachedProviderOwned()) {
    // Configure/calibration may race the injected registry's down/up/tail
    // fence. Keep the stored layout, but publish neither catch pixels nor a
    // visible calibration surface until kind=4/id=11 is authoritative.
    HideSurface();
    SetState("suspended", "geometryProviderPending",
             "attached_registry_owner_pending");
    EmitStateIfChanged();
    return;
  }
  if (!EnsureWindow(&error)) {
    HideSurface();
    SetState("error", "surfaceUnavailable", error);
    EmitStateIfChanged();
    return;
  }
  // Calibration probes consume game clicks too. They require the same
  // acknowledged shield and immutable glyph snapshot as ordinary lookup.
  const ShieldHandshakeState handshake = EnsureShieldHandshake();
  if (handshake != ShieldHandshakeState::kReady) {
    HideSurface();
    SetState("suspended", "shieldHandshakePending",
             handshake == ShieldHandshakeState::kUnavailable
                 ? "input_shield_handshake_unavailable"
                 : "input_shield_rehandshake_pending");
    EmitStateIfChanged();
    return;
  }
  if (native_provider_preferred) {
    if (!overlayability.overlayable && !native_without_desktop_overlay) {
      HideSurface();
      SetState("unavailable", "exclusiveFullscreenUnavailable",
               fushi::attached_overlayability::FailureReason(
                   overlayability.failure));
      EmitStateIfChanged();
      return;
    }
    if (!overlayability.overlayable) {
      // Revoke any previously published attached glyph boxes before waiting
      // for the current down/up tail or switching to the proved in-process
      // render-tree provider.
      HideSurface();
    }
    if (ShieldFaulted()) {
      HideSurface();
      DestroySurfaceWindow();
      SetState("error", "shieldFaulted", "input_shield_faulted");
      EmitStateIfChanged();
      return;
    }
    if (!ShieldPermitsLookup()) {
      HideSurface();
      SetState("suspended", "shieldHandshakePending",
               "input_shield_rehandshake_pending");
      EmitStateIfChanged();
      return;
    }
    if (!ShieldNeutralForProviderSwitch()) {
      native_provider_retire_pending_ = true;
      SetState("ready", "nativeProviderPendingNeutral");
      EmitStateIfChanged();
      return;
    }
    native_provider_retire_pending_ = false;
    HideSurface();
    // Keep the hidden HWND's WinEvent hooks and 500 ms timer alive.  A
    // windowed native provider can become unoverlayable after activation; the
    // next health sync must revoke activeNative unless it is the proved
    // in-process KiriKiri route.
    SetState("ready", "activeNative");
    EmitStateIfChanged(true);
    return;
  }
  native_provider_retire_pending_ = false;
  // BUG-2136：引擎层原点一次性自动求解。放在这里是因为此刻的前置条件正好齐了——
  // 目标已解析、shield 已握手、游戏还没被判成后台/最小化，画面就是可抓的。
  // 解出来一次就够（origin 是常量），失败什么都不发布，注入侧照旧退回贴合层。
  // 用户完全不需要手动框范围。
  if (target_.hwnd != nullptr && TargetIsForeground()) {
    fushi::VoiceHookReader::Instance().TrySolveAndPublishLookupLayerOrigin(
        target_.hwnd);
  }
  const HWND geometry_window =
      presentation_hwnd_ != nullptr ? presentation_hwnd_ : target_.hwnd;
  if (IsIconic(target_.hwnd) || IsIconic(geometry_window)) {
    HideSurface();
    SetState("suspended", "targetMinimized");
    EmitStateIfChanged();
    return;
  }
  if (!TargetIsForeground()) {
    HideSurface();
    SetState("suspended", "targetBackground");
    EmitStateIfChanged();
    return;
  }
  if (!overlayability.overlayable) {
    HideSurface();
    SetState(
        "unavailable", "exclusiveFullscreenUnavailable",
        fushi::attached_overlayability::FailureReason(overlayability.failure));
    EmitStateIfChanged();
    return;
  }
  if (!EnsureWindow(&error)) {
    HideSurface();
    SetState("error", "surfaceUnavailable", error);
    EmitStateIfChanged();
    return;
  }

  const bool calibration = mode_ == Mode::kCalibration;
  if ((!calibration && mode_ != Mode::kConfigured) || !ShieldPermitsLookup()) {
    HideSurface();
    SetState(ShieldFaulted()
                 ? "error"
                 : (mode_ == Mode::kTargetReady ? "targetReady" : "suspended"),
             ShieldFaulted()
                 ? "shieldFaulted"
                 : (ShieldPermitsLookup() ? "ready" : "shieldHandshakePending"),
             ShieldFaulted() ? "input_shield_faulted" : std::string());
    EmitStateIfChanged();
    return;
  }
  if (source_text_.empty()) {
    HideSurface();
    SetState("ready", "emptyText");
    EmitStateIfChanged();
    return;
  }

  const NormalizedRect &active_body =
      calibration ? calibration_rect_ : body_rect_;
  RECT source_body{};
  if (!fushi::attached_magpie_surface_geometry::ResolveSourceBodyRect(
          surface_geometry_.source_client_screen, active_body, &source_body)) {
    source_body_screen_rect_ = RECT{};
    mapped_body_screen_rect_ = RECT{};
    HideSurface();
    SetState("error", "invalidConfiguration", "body_rect_invalid");
    EmitStateIfChanged();
    return;
  }
  RECT body{};
  if (!fushi::attached_magpie_surface_geometry::ResolveVisibleBody(
          surface_geometry_, active_body, &body)) {
    source_body_screen_rect_ = source_body;
    mapped_body_screen_rect_ = RECT{};
    HideSurface();
    SetState("error", "invalidConfiguration", "body_rect_not_visible");
    EmitStateIfChanged();
    return;
  }
  if (!SurfaceGeometryEqual(previous_geometry, surface_geometry_) ||
      !EqualRect(&previous_source_body, &source_body)) {
    layout_dirty_ = true;
  }
  source_body_screen_rect_ = source_body;
  mapped_body_screen_rect_ = body;
  if (body.right - body.left < kMinimumBodyPixels ||
      body.bottom - body.top < kMinimumBodyPixels) {
    HideSurface();
    SetState("error", "invalidConfiguration", "body_rect_too_small");
    EmitStateIfChanged();
    return;
  }
  // Hard-break grids may have glyphs outside the saved body (right of it, or
  // rows below it). Keep the overlay click-through and expose only actual
  // glyph hit regions.
  const bool hard_break_grid =
      fushi::attached_text_layout::UsesHookLineBreaks(source_text_, layout_);
  const RECT surface = calibration || hard_break_grid ? client : body;
  const bool size_changed =
      surface.right - surface.left !=
          surface_screen_rect_.right - surface_screen_rect_.left ||
      surface.bottom - surface.top !=
          surface_screen_rect_.bottom - surface_screen_rect_.top ||
      reference.height_px != previous_reference.height_px ||
      reference.dpi != previous_reference.dpi;
  SetRuntimeClickThrough(true);
  PositionSurface(surface, calibration);
  if (size_changed) {
    if (calibration)
      ResetObservedCalibrationProbes();
    layout_dirty_ = true;
  }
  if (layout_dirty_ && !RebuildClusters()) {
    HideSurface();
    SetState("ready", "noGlyphClusters",
             last_cluster_failure_.empty() ? "cluster_build_failed"
                                           : last_cluster_failure_.c_str());
    EmitStateIfChanged();
    return;
  }
  if (clusters_.empty()) {
    HideSurface();
    // `layout_dirty_` 为假时这一轮根本没重建，簇为空是上一轮失败留下的。报那一轮的
    // 真实原因，否则真因会被这条泛化状态覆盖掉（BUG-2138 真机上正是如此）。
    SetState("ready", "noGlyphClusters",
             last_cluster_failure_.empty() ? "clusters_empty_after_build"
                                           : last_cluster_failure_.c_str());
    EmitStateIfChanged();
    return;
  }
  ApplyInteractiveRegion();
  std::string snapshot_publication_error;
  if (!PublishInteractiveSnapshot(&snapshot_publication_error)) {
    HideSurface();
    if (snapshot_publication_error == "geometry_provider_not_owned") {
      SetState("suspended", "geometryProviderPending",
               "attached_registry_owner_changed");
    } else if (snapshot_publication_error ==
               "magpie_cursor_capture_inactive") {
      SetState("suspended", "cursorCapturePending",
               "magpie_presentation_not_transparent");
    } else if (!snapshot_publication_error.empty()) {
      SetState("unavailable", "exclusiveFullscreenUnavailable",
               snapshot_publication_error);
    } else {
      SetState("suspended", "hitSnapshotUnavailable",
               "attached_glyph_snapshot_publish_failed");
    }
    EmitStateIfChanged();
    return;
  }
  RenderLayerBitmap(calibration);
  if (!SetVisible(true)) {
    // BUG-2140：这一路有五个互不相干的闸门，报出到底是哪条。
    const char *arm_failure = fushi::LastAttachedGlyphArmFailure();
    SetState("suspended", "mouseHookBusy",
             arm_failure == nullptr
                 ? std::string("low_level_mouse_singleton_busy_or_unavailable")
                 : std::string("low_level_mouse_arm_failed:") + arm_failure);
    EmitStateIfChanged();
    return;
  }
  const bool risky = fushi::LowLevelAttachedGlyphUsesRiskFallback(hwnd_);
  SetState(calibration ? "calibrating" : "visible",
           calibration ? "calibrating" : (risky ? "visibleRisky" : "visible"),
           risky ? "sampled_input_shield_unverified" : std::string());
  EmitStateIfChanged();
}

void AttachedTextSurfaceWindow::HideSurface() { SetVisible(false); }

bool AttachedTextSurfaceWindow::SetVisible(bool visible) {
  if (hwnd_ == nullptr || !IsWindow(hwnd_)) {
    surface_visible_ = false;
    mouse_hook_ready_ = false;
    return false;
  }
  if (!visible) {
    // This only clears the platform-thread mirror. The LL layer retains an
    // already swallowed physical down until its acknowledged neutral tail.
    CancelPointerGesture();
    fushi::ClearLowLevelAttachedGlyphHitRegions(hwnd_);
    hit_snapshot_token_ = 0;
    published_snapshot_game_ = nullptr;
    published_snapshot_allow_risk_ = false;
    published_snapshot_has_cursor_mapping_ = false;
    published_snapshot_cursor_presentation_ = nullptr;
    published_snapshot_cursor_mapping_ = SurfaceGeometry{};
    published_screen_rects_.clear();
    fushi::DisarmLowLevelMouseHook(hwnd_);
    mouse_hook_ready_ = false;
    ShowWindow(hwnd_, SW_HIDE);
    surface_visible_ = false;
    return true;
  }

  if (mode_ == Mode::kConfigured || mode_ == Mode::kCalibration) {
    // Revalidate singleton ownership on every 500ms health sync. A desktop or
    // global popup may have taken the process-wide HHOOK after this surface was
    // shown; attached must hide and retry later, never steal it back.
    mouse_hook_ready_ =
        fushi::ArmLowLevelMouseHookForAttachedGlyph(hwnd_, target_.hwnd);
    if (!mouse_hook_ready_) {
      CancelPointerGesture();
      fushi::ClearLowLevelAttachedGlyphHitRegions(hwnd_);
      hit_snapshot_token_ = 0;
      published_snapshot_game_ = nullptr;
      published_snapshot_allow_risk_ = false;
      published_snapshot_has_cursor_mapping_ = false;
      published_snapshot_cursor_presentation_ = nullptr;
      published_snapshot_cursor_mapping_ = SurfaceGeometry{};
      published_screen_rects_.clear();
      fushi::FinalizeLowLevelMouseDirectInputShield(hwnd_);
      ShowWindow(hwnd_, SW_HIDE);
      surface_visible_ = false;
      return false;
    }
  }
  const int width = surface_screen_rect_.right - surface_screen_rect_.left;
  const int height = surface_screen_rect_.bottom - surface_screen_rect_.top;
  SetWindowPos(hwnd_, HWND_TOPMOST, surface_screen_rect_.left,
               surface_screen_rect_.top, width, height,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  surface_visible_ = true;
  return true;
}

void AttachedTextSurfaceWindow::SetRuntimeClickThrough(bool enabled) {
  if (hwnd_ == nullptr || !IsWindow(hwnd_))
    return;
  const LONG_PTR current = GetWindowLongPtrW(hwnd_, GWL_EXSTYLE);
  const LONG_PTR desired =
      enabled ? (current | WS_EX_TRANSPARENT) : (current & ~WS_EX_TRANSPARENT);
  if (desired == current)
    return;
  SetWindowLongPtrW(hwnd_, GWL_EXSTYLE, desired);
  SetWindowPos(hwnd_, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
}

void AttachedTextSurfaceWindow::PositionSurface(const RECT &screen_rect,
                                                bool calibration) {
  const bool changed = !EqualRect(&surface_screen_rect_, &screen_rect) ||
                       ((mode_ == Mode::kCalibration) != calibration);
  if (changed) {
    // The new surface can be smaller than the old calibration surface.  Drop
    // the old hit snapshot and cluster geometry before changing the HWND
    // bounds; otherwise a resize can render old full-client boxes into the
    // new, smaller DIB before SyncToTarget rebuilds them.
    ClearInteractiveRegion();
    layout_dirty_ = true;
  }
  surface_screen_rect_ = screen_rect;
  if (hwnd_ == nullptr || !RectHasArea(screen_rect))
    return;
  SetWindowPos(hwnd_, nullptr, screen_rect.left, screen_rect.top,
               screen_rect.right - screen_rect.left,
               screen_rect.bottom - screen_rect.top,
               SWP_NOACTIVATE | SWP_NOZORDER);
}

// BUG-2138：17 个失败点原本全是裸 `return false`，对外只发一条笼统的
// `noGlyphClusters`——真机上等于「二十选一」，完全无法判断是正文没到、矩形没面积、
// 版式溢出，还是 DirectWrite 把行裁了。逐点记原因，只加量具不改任何判据。
bool AttachedTextSurfaceWindow::ClusterFailure(const char *reason) {
  last_cluster_failure_ = reason == nullptr ? "" : reason;
  return false;
}

bool AttachedTextSurfaceWindow::RebuildClusters() {
  ClearInteractiveRegion();
  layout_dirty_ = false;
  if (source_text_.empty() || !RectHasArea(surface_screen_rect_))
    return ClusterFailure("empty_text_or_no_surface_rect");
  if (dwrite_factory_ == nullptr) {
    HRESULT hr = DWriteCreateFactory(
        DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
        reinterpret_cast<IUnknown **>(dwrite_factory_.GetAddressOf()));
    if (FAILED(hr))
      return ClusterFailure("dwrite_factory_failed");
  }

  if (!RectHasArea(source_body_screen_rect_) ||
      !RectHasArea(mapped_body_screen_rect_)) {
    return ClusterFailure("mapped_body_not_visible");
  }
  // Build in source pixels with the source reference height.  Magpie can
  // enlarge the destination several times; transforming the finished boxes
  // keeps wrapping, cell advances and punctuation geometry identical to the
  // source profile instead of leaving the catch surface at source scale.
  const int source_width = source_body_screen_rect_.right -
                           source_body_screen_rect_.left;
  const int source_height = source_body_screen_rect_.bottom -
                            source_body_screen_rect_.top;
  const RECT layout_bounds{0, 0, source_width, source_height};
  const bool hard_break_grid =
      fushi::attached_text_layout::UsesHookLineBreaks(source_text_, layout_);
  const int surface_width = hard_break_grid
      ? surface_geometry_.source_client_screen.right -
            source_body_screen_rect_.left
      : source_width;
  const int surface_height =
      layout_.cell_grid.has_value() && layout_.cell_grid->explicit_line_breaks
      ? surface_geometry_.source_client_screen.bottom -
            source_body_screen_rect_.top
      : source_height;
  fushi::attached_text_layout::Result result =
      fushi::attached_text_layout::Build(
          dwrite_factory_.Get(), source_text_, layout_,
          live_reference_client_.height_px, surface_width, surface_height,
          layout_bounds);
  if (!result.ok())
    return ClusterFailure(result.reason.c_str());

  std::vector<ClusterBox> mapped_clusters;
  mapped_clusters.reserve(result.boxes.size());
  const auto map_cluster_rect = [&](const RECT &source_local,
                                    RECT *surface_local) {
    if (surface_local == nullptr || !RectHasArea(source_local))
      return false;
    RECT source_screen = source_local;
    OffsetRect(&source_screen, source_body_screen_rect_.left,
               source_body_screen_rect_.top);
    RECT mapped_screen{};
    if (!fushi::attached_magpie_surface_geometry::MapSourceRectToDestination(
            surface_geometry_, source_screen, &mapped_screen)) {
      return false;
    }
    RECT clipped_screen{};
    if (!fushi::attached_magpie_surface_geometry::ClipRectTo(
            mapped_screen, surface_screen_rect_, &clipped_screen)) {
      return false;
    }
    OffsetRect(&clipped_screen, -surface_screen_rect_.left,
               -surface_screen_rect_.top);
    if (!RectHasArea(clipped_screen))
      return false;
    *surface_local = clipped_screen;
    return true;
  };
  for (ClusterBox cluster : result.boxes) {
    RECT hit_rect{};
    RECT visual_rect{};
    if (!map_cluster_rect(cluster.hit_rect, &hit_rect) ||
        !map_cluster_rect(cluster.visual_rect, &visual_rect)) {
      continue;
    }
    cluster.hit_rect = hit_rect;
    cluster.visual_rect = visual_rect;
    mapped_clusters.push_back(std::move(cluster));
  }
  if (mapped_clusters.empty())
    return ClusterFailure("mapped_clusters_empty");
  text_layout_ = std::move(result.text_layout);
  clusters_ = std::move(mapped_clusters);
  last_cluster_failure_.clear();
  return true;
}

void AttachedTextSurfaceWindow::ClearInteractiveRegion() {
  CancelPointerGesture();
  hover_cluster_ = -1;
  if (hwnd_ != nullptr) {
    fushi::ClearLowLevelAttachedGlyphHitRegions(hwnd_);
  }
  hit_snapshot_token_ = 0;
  published_snapshot_game_ = nullptr;
  published_snapshot_allow_risk_ = false;
  published_snapshot_has_cursor_mapping_ = false;
  published_snapshot_cursor_presentation_ = nullptr;
  published_snapshot_cursor_mapping_ = SurfaceGeometry{};
  published_screen_rects_.clear();
  clusters_.clear();
  text_layout_.Reset();
  if (hwnd_ == nullptr || !IsWindow(hwnd_))
    return;
  HRGN empty = CreateRectRgn(0, 0, 0, 0);
  if (empty != nullptr && SetWindowRgn(hwnd_, empty, FALSE) == 0) {
    DeleteObject(empty);
  }
}

void AttachedTextSurfaceWindow::ApplyInteractiveRegion() {
  if (hwnd_ == nullptr || !IsWindow(hwnd_))
    return;
  const int width = surface_screen_rect_.right - surface_screen_rect_.left;
  const int height = surface_screen_rect_.bottom - surface_screen_rect_.top;
  HRGN region = CreateRectRgn(0, 0, 0, 0);
  if (region == nullptr)
    return;
  if (mode_ == Mode::kCalibration) {
    HRGN full = CreateRectRgn(0, 0, std::max(1, width), std::max(1, height));
    if (full != nullptr) {
      CombineRgn(region, region, full, RGN_OR);
      DeleteObject(full);
    }
  } else {
    for (const ClusterBox &cluster : clusters_) {
      HRGN box =
          CreateRectRgn(cluster.hit_rect.left, cluster.hit_rect.top,
                        cluster.hit_rect.right, cluster.hit_rect.bottom);
      if (box != nullptr) {
        CombineRgn(region, region, box, RGN_OR);
        DeleteObject(box);
      }
    }
  }
  if (SetWindowRgn(hwnd_, region, FALSE) == 0) {
    DeleteObject(region);
  }
}

bool AttachedTextSurfaceWindow::PublishInteractiveSnapshot(
    std::string *publication_error) {
  if (publication_error != nullptr)
    publication_error->clear();
  if (hwnd_ == nullptr || !IsWindow(hwnd_) || target_.hwnd == nullptr ||
      clusters_.empty() ||
      (mode_ != Mode::kConfigured && mode_ != Mode::kCalibration)) {
    return false;
  }
  // Re-read immediately before the low-level immutable snapshot publication.
  // The health-loop copy used by SyncToTarget is not an ownership lease.
  RefreshGeometryProviderStatus();
  if (!AttachedProviderOwned()) {
    if (publication_error != nullptr)
      *publication_error = "geometry_provider_not_owned";
    return false;
  }
  // This is deliberately inside the publication function, after layout and
  // immediately before the low-level glyph snapshot write.  The 500 ms health
  // timer alone leaves a real interval in which an exclusive transition can
  // hide the surface while its old catch boxes still swallow a game click.
  const fushi::attached_overlayability::Evaluation evaluation =
      CurrentOverlayability();
  if (!evaluation.overlayable) {
    if (publication_error != nullptr) {
      *publication_error =
          fushi::attached_overlayability::FailureReason(evaluation.failure);
    }
    return false;
  }
  const bool has_cursor_mapping = magpie_mapping_active_;
  if (has_cursor_mapping) {
    // Magpie's cursor is in source coordinates only while its presentation
    // window is transparent.  A verified viewport with a non-transparent
    // presentation is a toolbar/obscured state, so pause the attached layer
    // instead of guessing which desktop space the next click uses.
    SetLastError(ERROR_SUCCESS);
    const LONG_PTR style = GetWindowLongPtrW(presentation_hwnd_, GWL_EXSTYLE);
    if ((style == 0 && GetLastError() != ERROR_SUCCESS) ||
        (style & static_cast<LONG_PTR>(WS_EX_TRANSPARENT)) == 0) {
      if (publication_error != nullptr)
        *publication_error = "magpie_cursor_capture_inactive";
      return false;
    }
  }
  std::vector<RECT> screen_rects;
  screen_rects.reserve(clusters_.size());
  for (const ClusterBox &cluster : clusters_) {
    RECT screen = cluster.hit_rect;
    OffsetRect(&screen, surface_screen_rect_.left, surface_screen_rect_.top);
    screen_rects.push_back(screen);
  }
  const bool effective_allow_risk = EffectiveAllowRisk();
  const bool cursor_mapping_unchanged =
      published_snapshot_has_cursor_mapping_ == has_cursor_mapping &&
      (!has_cursor_mapping ||
       (published_snapshot_cursor_presentation_ == presentation_hwnd_ &&
        SurfaceGeometryEqual(published_snapshot_cursor_mapping_,
                              surface_geometry_)));
  const bool unchanged =
      hit_snapshot_token_ != 0 && published_snapshot_game_ == target_.hwnd &&
      published_snapshot_allow_risk_ == effective_allow_risk &&
      cursor_mapping_unchanged &&
      fushi::LowLevelAttachedGlyphHitSnapshotIsCurrent(hwnd_,
                                                       hit_snapshot_token_) &&
      published_screen_rects_.size() == screen_rects.size() &&
      std::equal(screen_rects.begin(), screen_rects.end(),
                 published_screen_rects_.begin(),
                 [](const RECT &left, const RECT &right) {
                   return EqualRect(&left, &right) != FALSE;
                 });
  if (unchanged)
    return true;
  if (hit_snapshot_token_ != 0) {
    CancelPointerGesture();
    fushi::ClearLowLevelAttachedGlyphHitRegions(hwnd_);
    hit_snapshot_token_ = 0;
  }
  hit_snapshot_token_ = fushi::UpdateLowLevelAttachedGlyphHitRegions(
      hwnd_, target_.hwnd, screen_rects.data(), screen_rects.size(),
      effective_allow_risk,
      has_cursor_mapping ? &surface_geometry_ : nullptr,
      has_cursor_mapping ? presentation_hwnd_ : nullptr);
  if (hit_snapshot_token_ != 0) {
    published_snapshot_game_ = target_.hwnd;
    published_snapshot_allow_risk_ = effective_allow_risk;
    published_snapshot_has_cursor_mapping_ = has_cursor_mapping;
    published_snapshot_cursor_presentation_ =
        has_cursor_mapping ? presentation_hwnd_ : nullptr;
    published_snapshot_cursor_mapping_ =
        has_cursor_mapping ? surface_geometry_ : SurfaceGeometry{};
    published_screen_rects_ = std::move(screen_rects);
  } else {
    published_snapshot_game_ = nullptr;
    published_snapshot_has_cursor_mapping_ = false;
    published_snapshot_cursor_presentation_ = nullptr;
    published_snapshot_cursor_mapping_ = SurfaceGeometry{};
    published_screen_rects_.clear();
  }
  return hit_snapshot_token_ != 0;
}

void AttachedTextSurfaceWindow::RenderLayerBitmap(bool calibration) {
  if (hwnd_ == nullptr || !IsWindow(hwnd_) ||
      !RectHasArea(surface_screen_rect_)) {
    return;
  }
  const int width = surface_screen_rect_.right - surface_screen_rect_.left;
  const int height = surface_screen_rect_.bottom - surface_screen_rect_.top;
  if (width <= 0 || height <= 0)
    return;
  const uint64_t pixels_count =
      static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
  if (pixels_count > static_cast<uint64_t>(std::numeric_limits<DWORD>::max()) /
                         sizeof(uint32_t)) {
    return;
  }

  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void *bits = nullptr;
  HDC screen_dc = GetDC(nullptr);
  HDC memory_dc = CreateCompatibleDC(screen_dc);
  HBITMAP bitmap =
      CreateDIBSection(screen_dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (screen_dc == nullptr || memory_dc == nullptr || bitmap == nullptr ||
      bits == nullptr) {
    if (bitmap != nullptr)
      DeleteObject(bitmap);
    if (memory_dc != nullptr)
      DeleteDC(memory_dc);
    if (screen_dc != nullptr)
      ReleaseDC(nullptr, screen_dc);
    return;
  }

  auto *pixels = static_cast<uint32_t *>(bits);
  std::fill_n(pixels, static_cast<size_t>(pixels_count), 0u);
  if (calibration) {
    std::fill_n(pixels, static_cast<size_t>(pixels_count), 0x01000000u);
  } else {
    // Alpha is the final pixel-level catch gate in addition to WindowRgn. Keep
    // every gap, whitespace cell and unused body pixel exactly zero-alpha.
    for (const ClusterBox &cluster : clusters_) {
      // Keep the bitmap write bounded even if a stale or malformed cluster
      // reaches this defensive rendering path.
      fushi::attached_bitmap_bounds::FillRectClippedToSurface(
          pixels, width, height, cluster.hit_rect, 0x01000000u);
    }
  }
  if (calibration && IsNormalizedRectValid(calibration_rect_)) {
    RECT selection = mapped_body_screen_rect_;
    OffsetRect(&selection, -surface_screen_rect_.left,
               -surface_screen_rect_.top);
    selection.left = std::clamp(selection.left, 0L, static_cast<LONG>(width));
    selection.top = std::clamp(selection.top, 0L, static_cast<LONG>(height));
    selection.right = std::clamp(selection.right, 0L, static_cast<LONG>(width));
    selection.bottom =
        std::clamp(selection.bottom, 0L, static_cast<LONG>(height));
    const uint32_t fill = PremultipliedPixel(18, 64, 160, 255);
    const uint32_t border = PremultipliedPixel(210, 64, 180, 255);
    const int border_width = std::max(2, presentation_dpi_ / 48);
    for (int y = selection.top; y < selection.bottom; ++y) {
      for (int x = selection.left; x < selection.right; ++x) {
        const bool edge = x < selection.left + border_width ||
                          x >= selection.right - border_width ||
                          y < selection.top + border_width ||
                          y >= selection.bottom - border_width;
        pixels[static_cast<size_t>(y) * width + x] = edge ? border : fill;
      }
    }
    // Show the observed visual rectangles inside the larger hit cells. A click
    // outside the hit boxes remains a game miss, while the visual outline lets
    // calibration distinguish the glyph from its catch area.
    // Green records the observed cluster without confusing the outer frame
    // with a click shield.
    for (const ClusterBox &cluster : clusters_) {
      const int64_t index = static_cast<int64_t>(cluster.text_position);
      const bool observed = index == probe_start_observed_index_ ||
                            index == probe_middle_observed_index_ ||
                            index == probe_end_observed_index_;
      const uint32_t outline = observed ? PremultipliedPixel(230, 64, 230, 128)
                                        : PremultipliedPixel(210, 64, 180, 255);
      const RECT box{
          std::clamp(cluster.visual_rect.left, 0L, static_cast<LONG>(width)),
          std::clamp(cluster.visual_rect.top, 0L, static_cast<LONG>(height)),
          std::clamp(cluster.visual_rect.right, 0L, static_cast<LONG>(width)),
          std::clamp(cluster.visual_rect.bottom, 0L, static_cast<LONG>(height))};
      for (LONG y = box.top; y < box.bottom; ++y) {
        for (LONG x = box.left; x < box.right; ++x) {
          if (x == box.left || x == box.right - 1 || y == box.top ||
              y == box.bottom - 1) {
            pixels[static_cast<size_t>(y) * width + x] = outline;
          }
        }
      }
    }
  }

  // Show the current text cluster under the global cursor when hover geometry
  // is available. The surface remains WS_EX_NOACTIVATE/click-through; this is
  // paint-only and never changes probe state or the input shield.
  if (hover_cluster_ >= 0 &&
      static_cast<size_t>(hover_cluster_) < clusters_.size()) {
    const RECT cluster =
        clusters_[static_cast<size_t>(hover_cluster_)].visual_rect;
    const RECT box{
        std::clamp(cluster.left, 0L, static_cast<LONG>(width)),
        std::clamp(cluster.top, 0L, static_cast<LONG>(height)),
        std::clamp(cluster.right, 0L, static_cast<LONG>(width)),
        std::clamp(cluster.bottom, 0L, static_cast<LONG>(height))};
    // Match KiriKiri's fushiLookupPaintHighlight: colorRect(0x31d7ff, 88).
    // PremultipliedPixel takes alpha first; keep this as a translucent fill
    // over the observed visual glyph bounds, without an outline.
    const uint32_t hover_fill = PremultipliedPixel(88, 49, 215, 255);
    for (LONG y = box.top; y < box.bottom; ++y) {
      for (LONG x = box.left; x < box.right; ++x) {
        pixels[static_cast<size_t>(y) * width + x] = hover_fill;
      }
    }
  }

  HGDIOBJ old_bitmap = SelectObject(memory_dc, bitmap);
  POINT destination{surface_screen_rect_.left, surface_screen_rect_.top};
  SIZE size{width, height};
  POINT source{0, 0};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(hwnd_, screen_dc, &destination, &size, memory_dc, &source,
                      0, &blend, ULW_ALPHA);
  SelectObject(memory_dc, old_bitmap);
  DeleteObject(bitmap);
  DeleteDC(memory_dc);
  ReleaseDC(nullptr, screen_dc);
}

int AttachedTextSurfaceWindow::ClusterAt(POINT client_point) const {
  for (size_t index = 0; index < clusters_.size(); ++index) {
    if (PtInRect(&clusters_[index].hit_rect, client_point)) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

bool AttachedTextSurfaceWindow::AdoptShieldTransaction(
    uint64_t external_transaction_id) {
  ReleaseShieldTransaction();
  if (external_transaction_id == 0)
    return false;
  shield_transaction_.epoch = epoch_;
  shield_transaction_.transaction_id = external_transaction_id;
  shield_transaction_.surface_hwnd = hwnd_;
  shield_transaction_.target_hwnd = target_.hwnd;
  shield_transaction_.left_active = true;
  // This transaction inherited the immutable snapshot's effective risk bit.
  // Recomputing from an unacknowledged down status would incorrectly turn a
  // previously verified path back into risky merely because a preference is
  // persisted.
  shield_transaction_.allow_risk = published_snapshot_allow_risk_;
  // The low-level hook already synchronously published this exact transaction
  // before allowing the physical down to progress. The platform-thread window
  // must only adopt it; publishing here reintroduces the sampled-input race.
  shield_transaction_active_ = true;
  RefreshShieldStatus();
  return true;
}

void AttachedTextSurfaceWindow::ReleaseShieldTransaction() {
  if (!shield_transaction_active_)
    return;
  shield_transaction_.left_active = false;
  // External LL transactions are released solely by the LL acknowledgement
  // worker after the injected side has observed down. The surface owns only a
  // local mirror and must never publish a duplicate single-slot release.
  shield_transaction_active_ = false;
  shield_transaction_ = ShieldTransaction{};
  RefreshShieldStatus();
}

void AttachedTextSurfaceWindow::RefreshShieldStatus() {
  if (read_shield_status_) {
    shield_status_ = read_shield_status_();
  } else {
    shield_status_ = ShieldStatus{};
  }
}

void AttachedTextSurfaceWindow::ResetShieldHandshake() {
  shield_handshake_epoch_ = Epoch{};
  shield_handshake_target_ = nullptr;
  shield_handshake_transaction_id_ = 0;
  shield_handshake_request_seq_ = 0;
  shield_handshake_established_ = false;
}

AttachedTextSurfaceWindow::ShieldHandshakeState
AttachedTextSurfaceWindow::EnsureShieldHandshake() {
  namespace policy = fushi::attached_shield_status_policy;
  RefreshShieldStatus();

  const auto status_identity = policy::StatusIdentity{
      shield_status_.available,      shield_status_.request_seq,
      shield_status_.applied_seq,    shield_status_.owner_kind,
      shield_status_.target_hwnd,    shield_status_.transaction_id,
      shield_status_.active_buttons, shield_status_.allow_risk,
      shield_status_.status_flags,
  };
  const auto current_epoch = policy::Epoch{epoch_.session, epoch_.surface};
  const uint64_t current_target =
      static_cast<uint64_t>(reinterpret_cast<uintptr_t>(target_.hwnd));
  const auto handshake = policy::HandshakeIdentity{
      policy::Epoch{shield_handshake_epoch_.session,
                    shield_handshake_epoch_.surface},
      static_cast<uint64_t>(
          reinterpret_cast<uintptr_t>(shield_handshake_target_)),
      shield_handshake_transaction_id_, shield_handshake_request_seq_};

  const policy::Attribution probe = policy::ClassifyHandshake(
      status_identity, handshake, current_epoch, current_target);
  if (probe == policy::Attribution::kAcknowledged) {
    shield_handshake_established_ = true;
    return ShieldHandshakeState::kReady;
  }
  if (probe == policy::Attribution::kPending)
    return ShieldHandshakeState::kPending;

  const policy::Attribution attached = policy::ClassifyAttachedAfterHandshake(
      status_identity, shield_handshake_established_, handshake, current_epoch,
      current_target);
  if (attached == policy::Attribution::kAcknowledged)
    return ShieldHandshakeState::kReady;
  if (attached == policy::Attribution::kPending)
    return ShieldHandshakeState::kPending;

  // Never overwrite a down, release tail, unacknowledged request or a status
  // whose producer is stuck claiming TransactionActive. The old HWND's LL
  // worker remains the sole owner of its tail; only a neutral acknowledgement
  // lets this new target publish a challenge.
  if (shield_transaction_active_ ||
      !policy::IsNeutralForRehandshake(status_identity)) {
    return shield_status_.available ? ShieldHandshakeState::kPending
                                    : ShieldHandshakeState::kUnavailable;
  }
  if (!publish_shield_probe_ || target_.hwnd == nullptr ||
      !IsWindow(target_.hwnd)) {
    return ShieldHandshakeState::kUnavailable;
  }

  uint32_t ordinal =
      g_shield_probe_counter.fetch_add(1, std::memory_order_relaxed) + 1u;
  if (ordinal == 0) {
    ordinal =
        g_shield_probe_counter.fetch_add(1, std::memory_order_relaxed) + 1u;
  }
  uint32_t epoch_tag = static_cast<uint32_t>(
      (epoch_.session * uint64_t{0x9e3779b1u}) ^ epoch_.surface);
  if (epoch_tag == 0)
    epoch_tag = 1;
  const uint64_t transaction_id =
      (static_cast<uint64_t>(epoch_tag) << 32) | ordinal;

  // A probe always requests the strict conclusion. Publishing allowRisk here
  // would force NormalizeLookupShieldStatusFlags to downgrade even complete
  // coverage, making a persisted preference impossible to recover to verified.
  const uint32_t request_seq =
      publish_shield_probe_(target_.hwnd, transaction_id, false);
  if (request_seq == 0)
    return ShieldHandshakeState::kUnavailable;

  shield_handshake_epoch_ = epoch_;
  shield_handshake_target_ = target_.hwnd;
  shield_handshake_transaction_id_ = transaction_id;
  shield_handshake_request_seq_ = request_seq;
  shield_handshake_established_ = false;
  shield_handshake_probe_published_at_ = GetTickCount64();
  return ShieldHandshakeState::kPending;
}

void AttachedTextSurfaceWindow::UpdateShieldHandshakeWatch() {
  // "unavailable" has no acknowledgement to wait for; only an outstanding
  // (re)handshake is worth observing at frame cadence.
  const bool pending = status_ == "shieldHandshakePending" &&
                       reason_ != "input_shield_handshake_unavailable";
  if (pending) {
    if (!shield_handshake_watch_active_) {
      shield_handshake_watch_active_ = true;
      // The probe that opens an episode is usually published by this same
      // admission pass just before SetState, so it is not cleared here.
      shield_handshake_pending_since_ = GetTickCount64();
      shield_handshake_watch_syncs_ = 0;
    }
    if (!shield_handshake_watch_timer_running_ && hwnd_ != nullptr &&
        IsWindow(hwnd_) &&
        GetTickCount64() - shield_handshake_pending_since_ <=
            kShieldHandshakeWatchMaxMs &&
        SetTimer(hwnd_, kShieldHandshakeWatchTimerId,
                 kShieldHandshakeWatchTimerMs, nullptr) != 0) {
      shield_handshake_watch_timer_running_ = true;
    }
    return;
  }
  if (!shield_handshake_watch_active_)
    return;
  StopShieldHandshakeWatchTimer();
  shield_handshake_watch_active_ = false;
  const ULONGLONG now = GetTickCount64();
  const ULONGLONG probe_at = shield_handshake_probe_published_at_;
  std::ostringstream line;
  line << "gal-shield: handshake pending ended after "
       << (now - shield_handshake_pending_since_) << "ms";
  const ULONGLONG since = shield_handshake_pending_since_;
  if (probe_at != 0 && probe_at + kShieldHandshakeWatchTimerMs >= since) {
    line << " (neutral_wait=" << (probe_at > since ? probe_at - since : 0)
         << "ms ack_wait=" << (now - probe_at) << "ms)";
  } else {
    line << " (no new probe)";
  }
  line << " syncs=" << shield_handshake_watch_syncs_ << " -> " << state_ << '/'
       << status_;
  NativeGlog(line.str());
}

void AttachedTextSurfaceWindow::StopShieldHandshakeWatchTimer() {
  if (!shield_handshake_watch_timer_running_)
    return;
  if (hwnd_ != nullptr && IsWindow(hwnd_))
    KillTimer(hwnd_, kShieldHandshakeWatchTimerId);
  shield_handshake_watch_timer_running_ = false;
}

void AttachedTextSurfaceWindow::OnShieldHandshakeWatchTimer() {
  if (!shield_handshake_watch_active_ || mode_ == Mode::kDetached ||
      target_.hwnd == nullptr) {
    // Detach/epoch changes hide the surface without a new admission state;
    // there is no handshake left to observe.
    StopShieldHandshakeWatchTimer();
    shield_handshake_watch_active_ = false;
    return;
  }
  const ULONGLONG elapsed = GetTickCount64() - shield_handshake_pending_since_;
  if (elapsed > kShieldHandshakeWatchMaxMs) {
    // Keep the episode open so its eventual end is still logged; only the
    // cadence drops back to the follow timer.
    StopShieldHandshakeWatchTimer();
    std::ostringstream line;
    line << "gal-shield: handshake still pending after " << elapsed
         << "ms; request_seq=" << shield_status_.request_seq
         << " applied_seq=" << shield_status_.applied_seq
         << " active_buttons=" << shield_status_.active_buttons
         << " transaction_active=" << shield_transaction_active_
         << " probe_published=" << (shield_handshake_probe_published_at_ != 0);
    NativeGlog(line.str());
    return;
  }
  ++shield_handshake_watch_syncs_;
  SyncToTarget();
}

bool AttachedTextSurfaceWindow::ShieldStatusBelongsToCurrentHandshake() const {
  namespace policy = fushi::attached_shield_status_policy;
  const auto status_identity = policy::StatusIdentity{
      shield_status_.available,      shield_status_.request_seq,
      shield_status_.applied_seq,    shield_status_.owner_kind,
      shield_status_.target_hwnd,    shield_status_.transaction_id,
      shield_status_.active_buttons, shield_status_.allow_risk,
      shield_status_.status_flags,
  };
  const auto current_epoch = policy::Epoch{epoch_.session, epoch_.surface};
  const uint64_t current_target =
      static_cast<uint64_t>(reinterpret_cast<uintptr_t>(target_.hwnd));
  const auto handshake = policy::HandshakeIdentity{
      policy::Epoch{shield_handshake_epoch_.session,
                    shield_handshake_epoch_.surface},
      static_cast<uint64_t>(
          reinterpret_cast<uintptr_t>(shield_handshake_target_)),
      shield_handshake_transaction_id_, shield_handshake_request_seq_};
  if (policy::ClassifyHandshake(status_identity, handshake, current_epoch,
                                current_target) ==
      policy::Attribution::kAcknowledged) {
    return true;
  }
  return policy::ClassifyAttachedAfterHandshake(
             status_identity, shield_handshake_established_, handshake,
             current_epoch,
             current_target) == policy::Attribution::kAcknowledged;
}

AttachedTextSurfaceWindow::ShieldStatus
AttachedTextSurfaceWindow::ShieldStatusForSnapshot() const {
  if (ShieldStatusBelongsToCurrentHandshake())
    return shield_status_;

  // request/applied identity remains useful diagnostics, but masks and flags
  // are payload owned by applied_seq. Suppress them until the current
  // target/epoch challenge is acknowledged so Dart cannot persist or act on a
  // fault/verified conclusion from the destroyed HWND.
  ShieldStatus safe;
  safe.available = shield_status_.available;
  safe.request_seq = shield_status_.request_seq;
  safe.applied_seq = shield_status_.applied_seq;
  safe.owner_kind = shield_status_.owner_kind;
  safe.target_hwnd = shield_status_.target_hwnd;
  safe.transaction_id = shield_status_.transaction_id;
  safe.active_buttons = shield_status_.active_buttons;
  safe.allow_risk = shield_status_.allow_risk;
  return safe;
}

bool AttachedTextSurfaceWindow::EffectiveAllowRisk() const {
  return fushi::attached_shield_status_policy::EffectiveAllowRisk(
      ShieldVerified());
}

void AttachedTextSurfaceWindow::RefreshGeometryProviderStatus() {
  if (read_geometry_provider_status_) {
    const GeometryProviderStatus sample = read_geometry_provider_status_();
    // A concurrent registry write is not an authoritative retirement. Keep
    // the last coherent metadata for this target until an actual sample or
    // session error arrives; input still checks the live registry owner.
    if (!sample.snapshot_conflicted) provider_status_ = sample;
  } else {
    provider_status_ = GeometryProviderStatus{};
  }
}

fushi::attached_overlayability::Evaluation
AttachedTextSurfaceWindow::CurrentOverlayability() const {
  using fushi::attached_overlayability::ExclusiveOwnership;
  using fushi::attached_overlayability::Facts;

  Facts facts;
  BOOL composition_enabled = FALSE;
  facts.composition_query_succeeded =
      SUCCEEDED(DwmIsCompositionEnabled(&composition_enabled));
  facts.composition_enabled = composition_enabled != FALSE;

  const HWND source = target_.hwnd;
  const HWND presentation =
      presentation_hwnd_ != nullptr ? presentation_hwnd_ : source;
  DWORD source_pid = 0;
  DWORD presentation_pid = 0;
  if (source != nullptr && IsWindow(source))
    GetWindowThreadProcessId(source, &source_pid);
  if (presentation != nullptr && IsWindow(presentation))
    GetWindowThreadProcessId(presentation, &presentation_pid);

  facts.source_window_valid = source != nullptr && IsWindow(source) &&
                              source_pid != 0 && source_pid == target_.pid;
  facts.presentation_window_valid = presentation != nullptr &&
                                    IsWindow(presentation) &&
                                    presentation_pid != 0;
  facts.presentation_matches_source =
      facts.presentation_window_valid &&
      (presentation == source ||
       fushi::ResolveScalingSourceWindow(presentation) == source);
  facts.presentation_visible =
      facts.presentation_window_valid && IsWindowVisible(presentation) != FALSE;
  facts.source_minimized =
      !facts.source_window_valid || IsIconic(source) != FALSE;
  facts.presentation_minimized =
      !facts.presentation_window_valid || IsIconic(presentation) != FALSE;
  facts.source_cloak_query_succeeded =
      facts.source_window_valid &&
      QueryWindowCloak(source, &facts.source_cloaked);
  facts.presentation_cloak_query_succeeded =
      facts.presentation_window_valid &&
      QueryWindowCloak(presentation, &facts.presentation_cloaked);
  facts.client_has_area = facts.presentation_window_valid &&
                          RectHasArea(ClientScreenRect(presentation));

  const ExclusiveOwnership source_ownership =
      QueryWindowExclusiveOwnership(source, source_pid);
  const ExclusiveOwnership presentation_ownership =
      presentation == source
          ? source_ownership
          : QueryWindowExclusiveOwnership(presentation, presentation_pid);
  facts.exclusive_ownership =
      CombineExclusiveOwnership(source_ownership, presentation_ownership);

  RECT presentation_frame{};
  facts.presentation_frame_query_succeeded =
      facts.presentation_window_valid &&
      SUCCEEDED(DwmGetWindowAttribute(presentation, DWMWA_EXTENDED_FRAME_BOUNDS,
                                      &presentation_frame,
                                      sizeof(presentation_frame)));
  facts.presentation_frame_has_area =
      facts.presentation_frame_query_succeeded &&
      RectHasArea(presentation_frame);
  return fushi::attached_overlayability::Evaluate(facts);
}

bool AttachedTextSurfaceWindow::NativeProviderCanPresentWithoutDesktopOverlay()
    const {
  return fushi::attached_overlayability::HasInProcessRenderTreePresenter(
      provider_status_.provider_kind, provider_status_.provider_id,
      provider_status_.lookup_diag);
}

bool AttachedTextSurfaceWindow::NativeProviderPreferred() const {
  if (!provider_status_.available ||
      !fushi::lookup_hit_validation::IsProviderLifecycleUsable(
          provider_status_.provider_status, provider_status_.generation,
          provider_status_.text_generation)) {
    return false;
  }
  switch (provider_status_.provider_kind) {
  case kGeometryProviderRuntimeLayout:
    return provider_status_.provider_id == 1u ||
           provider_status_.provider_id == 2u ||
           provider_status_.provider_id == 6u ||
           provider_status_.provider_id == 7u ||
           provider_status_.provider_id == 8u;
  case kGeometryProviderEngineExactLayout:
    return provider_status_.provider_id == 3u ||
           provider_status_.provider_id == 4u ||
           provider_status_.provider_id == 5u ||
           provider_status_.provider_id == 14u ||
           provider_status_.provider_id == 15u;
  case kGeometryProviderPositionedTextApi:
    return provider_status_.provider_id == 9u ||
           provider_status_.provider_id == 10u;
  default:
    return false;
  }
}

bool AttachedTextSurfaceWindow::AttachedProviderOwned() const {
  return provider_status_.available &&
         provider_status_.provider_kind ==
             kGeometryProviderAttachedCalibrated &&
         provider_status_.provider_id ==
             kGeometryProviderIdAttachedCalibrated &&
         fushi::lookup_hit_validation::IsProviderLifecycleUsable(
             provider_status_.provider_status, provider_status_.generation,
             provider_status_.text_generation);
}

bool AttachedTextSurfaceWindow::ShieldNeutralForProviderSwitch() const {
  return shield_status_.available && !shield_transaction_active_ &&
         shield_status_.active_buttons == 0 &&
         shield_status_.request_seq == shield_status_.applied_seq &&
         (shield_status_.status_flags & kShieldStatusTransactionActive) == 0;
}

bool AttachedTextSurfaceWindow::ShieldFaulted() const {
  return ShieldStatusBelongsToCurrentHandshake() &&
         (shield_status_.fault_mask != 0 ||
          (shield_status_.status_flags & kShieldStatusFaulted) != 0);
}

bool AttachedTextSurfaceWindow::ShieldVerified() const {
  return ShieldStatusBelongsToCurrentHandshake() &&
         (shield_status_.status_flags & kShieldStatusVerified) != 0 &&
         !ShieldFaulted();
}

bool AttachedTextSurfaceWindow::ShieldPermitsLookup() const {
  return fushi::attached_shield_status_policy::PermitsLookup(
      ShieldStatusBelongsToCurrentHandshake(), ShieldFaulted(), ShieldVerified());
}

void AttachedTextSurfaceWindow::OnGeometryProviderStatusChanged() {
  RefreshGeometryProviderStatus();
  if (mode_ == Mode::kConfigured || mode_ == Mode::kCalibration)
    SyncToTarget();
  else
    EmitStateIfChanged(true);
}

void AttachedTextSurfaceWindow::OnExternalWindowLifecycle(HWND output_window,
                                                           bool scaling) {
  (void)output_window;
  (void)scaling;
  if (mode_ == Mode::kDetached || hwnd_ == nullptr || !IsWindow(hwnd_)) {
    return;
  }
  // Keep all target/presentation changes on the surface window's existing
  // message path. The Magpie broadcast runs on the runner UI thread too, but
  // posting avoids re-entering SyncToTarget while WndProc is still dispatching
  // the broadcast and preserves the same lifecycle ordering as WinEvent hooks.
  PostMessageW(hwnd_, kSyncTargetMessage, 0, 0);
}

void AttachedTextSurfaceWindow::BeginPointerGesture(
    POINT client_point, uint64_t external_transaction_id) {
  CancelPointerGesture();
  const int cluster = ClusterAt(client_point);
  if (cluster < 0)
    return;
  if (!AdoptShieldTransaction(external_transaction_id))
    return;
  pointer_down_ = true;
  pointer_dragged_ = false;
  pressed_cluster_ = cluster;
  pointer_down_point_ = client_point;
  pointer_epoch_ = epoch_;
  pointer_text_generation_ = text_generation_;
}

void AttachedTextSurfaceWindow::UpdatePointerGesture(POINT client_point) {
  if (!pointer_down_ || pointer_dragged_)
    return;
  // Match the shell's configured drag rectangle (including accessibility and
  // user customisation), rather than inventing a DPI-scaled pixel constant.
  const int threshold_x = std::max(1, GetSystemMetrics(SM_CXDRAG) / 2);
  const int threshold_y = std::max(1, GetSystemMetrics(SM_CYDRAG) / 2);
  if (std::abs(client_point.x - pointer_down_point_.x) > threshold_x ||
      std::abs(client_point.y - pointer_down_point_.y) > threshold_y) {
    pointer_dragged_ = true;
  }
}

void AttachedTextSurfaceWindow::EndPointerGesture(
    POINT client_point, uint64_t external_transaction_id) {
  if (external_transaction_id == 0 || !shield_transaction_active_ ||
      shield_transaction_.transaction_id != external_transaction_id) {
    return;
  }
  if (!pointer_down_) {
    ReleaseShieldTransaction();
    return;
  }
  UpdatePointerGesture(client_point);
  const int released_cluster = ClusterAt(client_point);
  const int pressed_cluster = pressed_cluster_;
  const bool valid = !pointer_dragged_ && pressed_cluster >= 0 &&
                     pressed_cluster == released_cluster &&
                     static_cast<size_t>(pressed_cluster) < clusters_.size() &&
                     CompareEpoch(pointer_epoch_, epoch_) == 0 &&
                     pointer_text_generation_ == text_generation_;
  pointer_down_ = false;
  pointer_dragged_ = false;
  pressed_cluster_ = -1;
  if (GetCapture() == hwnd_)
    ReleaseCapture();
  ReleaseShieldTransaction();
  if (mode_ == Mode::kCalibration) {
    std::string probe_error;
    const bool observed =
        valid && RecordObservedCalibrationProbe(client_point, &probe_error);
    SetState("calibrating", "calibrating",
             observed ? "calibration_probe_observed"
                      : (valid ? probe_error : "calibration_click_rejected"));
    RenderLayerBitmap(true);
    EmitStateIfChanged(true);
    return;
  }
  if (!valid || mode_ != Mode::kConfigured || !on_lookup_)
    return;
  EmitLookupEvent(pressed_cluster, false);
}

void AttachedTextSurfaceWindow::EmitLookupEvent(int cluster_index,
                                                bool hover) {
  if (!on_lookup_ || cluster_index < 0 ||
      static_cast<size_t>(cluster_index) >= clusters_.size()) {
    return;
  }
  const ClusterBox &cluster = clusters_[static_cast<size_t>(cluster_index)];
  LookupEvent event;
  event.epoch = epoch_;
  event.target_pid = target_.pid;
  event.target_hwnd = target_.hwnd;
  event.text_generation = text_generation_;
  event.source_text = source_text_utf8_;
  event.char_index = cluster.text_position;
  event.source_length = cluster.text_length;
  event.screen_rect_px = cluster.visual_rect;
  OffsetRect(&event.screen_rect_px, surface_screen_rect_.left,
             surface_screen_rect_.top);
  event.destination_viewport_screen_px =
      surface_geometry_.destination_viewport_screen;
  // screen_rect_px is in the presentation monitor's physical pixels.  The
  // source DPI belongs to profile/layout scaling and may differ when Magpie
  // presents the output on another monitor.
  event.dpi = std::max(96, presentation_dpi_);
  event.hover = hover;
  on_lookup_(event);
}

bool AttachedTextSurfaceWindow::HoverLookupGeometryAvailable() const {
  // clusters_/surface_screen_rect_ are only trustworthy after SyncToTarget
  // reached the publication step: either the surface is on-screen, or it was
  // hidden solely because the desktop popup currently owns the WH_MOUSE_LL
  // singleton (mouseHookBusy) - geometry is still current in that case and
  // hovering another word while a card is open must keep working. Any other
  // hidden state (target cloaked/unavailable, no clusters, shield fault) has
  // stale or absent geometry and must not fire.
  if (mode_ != Mode::kConfigured || clusters_.empty() || pointer_down_ ||
      hwnd_ == nullptr || target_.hwnd == nullptr) {
    return false;
  }
  return surface_visible_ ||
         (state_ == "suspended" && status_ == "mouseHookBusy");
}

void AttachedTextSurfaceWindow::TickHoverLookup() {
  const bool eligible = HoverLookupGeometryAvailable();
  // Physical key state only: this window is WS_EX_NOACTIVATE and never owns
  // keyboard focus, so GetKeyState's per-thread table would never update.
  const bool shift_down =
      eligible && (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
  int cluster = -1;
  bool over_text = false;
  if (eligible) {
    POINT screen{};
    if (GetCursorPos(&screen)) {
      // The runtime surface is click-through, so the cursor must be over the
      // game itself (or this surface). A cursor resting on the lookup card or
      // any other window is not a hover over game text.
      const HWND under = WindowFromPoint(screen);
      over_text =
          under != nullptr &&
          (under == hwnd_ || under == target_.hwnd ||
           under == presentation_hwnd_ ||
           IsChild(target_.hwnd, under) != FALSE);
      POINT destination = screen;
      if (over_text && magpie_mapping_active_) {
        SetLastError(ERROR_SUCCESS);
        const LONG_PTR style =
            GetWindowLongPtrW(presentation_hwnd_, GWL_EXSTYLE);
        const bool cursor_captured =
            !(style == 0 && GetLastError() != ERROR_SUCCESS) &&
            (style & static_cast<LONG_PTR>(WS_EX_TRANSPARENT)) != 0;
        if (!cursor_captured ||
            !fushi::attached_magpie_surface_geometry::
                MapSourcePointToDestination(surface_geometry_, screen,
                                            &destination)) {
          over_text = false;
        }
      }
      if (over_text) {
        // WindowFromPoint above answers only whether the raw cursor is over
        // the game/presentation area.  Apply Magpie's source->destination
        // cursor transform exactly once for the glyph lookup itself.
        const POINT client{destination.x - surface_screen_rect_.left,
                           destination.y - surface_screen_rect_.top};
        cluster = ClusterAt(client);
      }
    }
  }
  const int visual_cluster = over_text ? cluster : -1;
  if (visual_cluster != hover_cluster_) {
    hover_cluster_ = visual_cluster;
    RenderLayerBitmap(mode_ == Mode::kCalibration);
  }
  if (!shift_down) {
    // The visual state above is useful without Shift, but lookup submission
    // remains explicitly Shift-gated and the tracker must forget its prior
    // cluster when Shift is released.
    hover_tracker_.Reset();
    return;
  }
  if (!hover_tracker_.Observe(shift_down, cluster, epoch_.session,
                              epoch_.surface, text_generation_)) {
    return;
  }
  // Hover never enters the v19 shield transaction: nothing is consumed, the
  // game keeps every input. The Dart side opens the same desktop popup as a
  // click hit (with the game HWND as consume-outside owner).
  EmitLookupEvent(cluster, true);
}

void AttachedTextSurfaceWindow::CancelPointerGesture() {
  pointer_down_ = false;
  pointer_dragged_ = false;
  pressed_cluster_ = -1;
  if (hwnd_ != nullptr && GetCapture() == hwnd_)
    ReleaseCapture();
  ReleaseShieldTransaction();
}

void AttachedTextSurfaceWindow::SetState(std::string state, std::string status,
                                         std::string reason) {
  state_ = std::move(state);
  status_ = std::move(status);
  reason_ = std::move(reason);
  UpdateShieldHandshakeWatch();
}

AttachedTextSurfaceWindow::Snapshot
AttachedTextSurfaceWindow::GetSnapshot() const {
  Snapshot snapshot;
  snapshot.epoch = epoch_;
  snapshot.target = target_;
  snapshot.body_rect =
      mode_ == Mode::kCalibration ? calibration_rect_ : body_rect_;
  snapshot.layout = layout_;
  snapshot.state = state_;
  snapshot.status = status_;
  snapshot.reason = reason_;
  snapshot.surface_visible = surface_visible_;
  snapshot.risk_accepted =
      fushi::attached_shield_status_policy::kRiskAlwaysAccepted;
  snapshot.text_generation = text_generation_;
  snapshot.calibration_probe_mask = calibration_probe_mask_;
  snapshot.probe_start_observed_index = probe_start_observed_index_;
  snapshot.probe_middle_observed_index = probe_middle_observed_index_;
  snapshot.probe_end_observed_index = probe_end_observed_index_;
  snapshot.provider = provider_status_;
  snapshot.shield = ShieldStatusForSnapshot();
  return snapshot;
}

void AttachedTextSurfaceWindow::EmitStateIfChanged(bool force) {
  const Snapshot snapshot = GetSnapshot();
  std::ostringstream stream;
  stream << snapshot.epoch.session << ':' << snapshot.epoch.surface << ':'
         << snapshot.target.pid << ':'
         << reinterpret_cast<uintptr_t>(snapshot.target.hwnd) << ':'
         << snapshot.state << ':' << snapshot.status << ':' << snapshot.reason
         << ':' << snapshot.surface_visible << ':'
         << snapshot.target.reference_client.width_px << 'x'
         << snapshot.target.reference_client.height_px << '@'
         << snapshot.target.reference_client.dpi << ':'
         << snapshot.text_generation << ':' << snapshot.calibration_probe_mask
         << ':' << snapshot.body_rect.left << ',' << snapshot.body_rect.top
         << ',' << snapshot.body_rect.width << ',' << snapshot.body_rect.height
         << ':' << snapshot.probe_start_observed_index << ','
         << snapshot.probe_middle_observed_index << ','
         << snapshot.probe_end_observed_index << ':'
         << snapshot.provider.provider_kind << ','
         << snapshot.provider.provider_id << ','
         << snapshot.provider.provider_status << ','
         << snapshot.provider.generation << ':' << snapshot.shield.request_seq
         << ':' << snapshot.shield.applied_seq << ':'
         << snapshot.shield.owner_kind << ':' << snapshot.shield.target_hwnd
         << ':' << snapshot.shield.transaction_id << ':'
         << snapshot.shield.active_buttons << ':' << snapshot.shield.allow_risk
         << ':' << snapshot.shield.required_mask << ':'
         << snapshot.shield.ready_mask << ':' << snapshot.shield.observed_mask
         << ':' << snapshot.shield.fault_mask << ':'
         << snapshot.shield.status_flags;
  const std::string signature = stream.str();
  if (!force && signature == last_emitted_signature_)
    return;
  last_emitted_signature_ = signature;
  if (on_state_)
    on_state_(snapshot);
}

void AttachedTextSurfaceWindow::NotifyCalibrationCommitted() {
  SetState(mode_ == Mode::kConfigured ? "ready" : "targetReady",
           "calibrationCommitted");
  if (on_calibration_committed_) {
    on_calibration_committed_(GetSnapshot());
  }
  EmitStateIfChanged(true);
}

void AttachedTextSurfaceWindow::NotifyCalibrationCancelled(
    const std::string &reason) {
  SetState(mode_ == Mode::kConfigured ? "ready" : "targetReady",
           "calibrationCancelled", reason);
  if (on_calibration_cancelled_) {
    on_calibration_cancelled_(GetSnapshot());
  }
  EmitStateIfChanged(true);
}

LRESULT CALLBACK AttachedTextSurfaceWindow::WndProc(HWND hwnd, UINT message,
                                                    WPARAM wparam,
                                                    LPARAM lparam) noexcept {
  AttachedTextSurfaceWindow *self =
      reinterpret_cast<AttachedTextSurfaceWindow *>(
          GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto *create = reinterpret_cast<const CREATESTRUCTW *>(lparam);
    self = static_cast<AttachedTextSurfaceWindow *>(create->lpCreateParams);
    if (self != nullptr) {
      self->hwnd_ = hwnd;
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
  }
  if (self != nullptr) {
    return self->HandleMessage(message, wparam, lparam);
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT AttachedTextSurfaceWindow::HandleMessage(UINT message, WPARAM wparam,
                                                 LPARAM lparam) noexcept {
  switch (message) {
  case WM_TIMER:
    if (wparam == kFollowTimerId) {
      SyncToTarget();
      return 0;
    }
    if (wparam == kHoverTimerId) {
      TickHoverLookup();
      return 0;
    }
    if (wparam == kShieldHandshakeWatchTimerId) {
      OnShieldHandshakeWatchTimer();
      return 0;
    }
    return DefWindowProcW(hwnd_, message, wparam, lparam);
  case WM_MOUSEACTIVATE:
    return MA_NOACTIVATE;
  case WM_NCHITTEST:
    return HTTRANSPARENT;
  case WM_SETCURSOR:
    SetCursor(LoadCursorW(nullptr,
                          mode_ == Mode::kCalibration ? IDC_CROSS : IDC_HAND));
    return TRUE;
  case WM_LBUTTONDOWN:
  case WM_LBUTTONUP:
  case WM_MOUSEMOVE:
    // Both modes are click-through. Only the LL glyph messages below carry
    // an already-published shield transaction. Ordinary window messages must
    // neither record a probe nor finish a different physical LL transaction.
    return 0;
  case fushi::kLowLevelMouseAttachedGlyphDownMessage: {
    const uint64_t transaction_id = static_cast<uint64_t>(wparam);
    const uint32_t snapshot_token =
        fushi::LowLevelAttachedGlyphSnapshotToken(transaction_id);
    if ((mode_ != Mode::kConfigured && mode_ != Mode::kCalibration) ||
        !surface_visible_ ||
        transaction_id == 0 || snapshot_token == 0 ||
        snapshot_token != hit_snapshot_token_) {
      return 0;
    }
    POINT point = fushi::UnpackMouseHookPoint(static_cast<WPARAM>(lparam));
    ScreenToClient(hwnd_, &point);
    BeginPointerGesture(point, transaction_id);
    return 0;
  }
  case fushi::kLowLevelMouseAttachedGlyphUpMessage: {
    const uint64_t transaction_id = static_cast<uint64_t>(wparam);
    if (transaction_id == 0 || fushi::LowLevelAttachedGlyphSnapshotToken(
                                   transaction_id) != hit_snapshot_token_) {
      return 0;
    }
    POINT point = fushi::UnpackMouseHookPoint(static_cast<WPARAM>(lparam));
    ScreenToClient(hwnd_, &point);
    EndPointerGesture(point, transaction_id);
    return 0;
  }
  case fushi::kLowLevelMouseAttachedGlyphCancelMessage: {
    const uint64_t transaction_id = static_cast<uint64_t>(wparam);
    if (shield_transaction_active_ &&
        shield_transaction_.transaction_id == transaction_id) {
      CancelPointerGesture();
    }
    return 0;
  }
  case fushi::kLowLevelMouseAttachedGlyphAbortMessage: {
    const uint64_t transaction_id = static_cast<uint64_t>(wparam);
    if (transaction_id == 0 ||
        fushi::LowLevelAttachedGlyphSnapshotToken(transaction_id) !=
            hit_snapshot_token_) {
      return 0;
    }
    // The release worker reached a terminal IPC/shield failure after physical
    // up and has already revoked this exact immutable snapshot. Hide/disarm on
    // the owning window thread; a later health sync may re-arm only after a
    // fresh coherent provider/shield handshake.
    HideSurface();
    SetState("suspended", "inputShieldUnavailable",
             "lookup_shield_transaction_aborted");
    EmitStateIfChanged(true);
    return 0;
  }
  case WM_CAPTURECHANGED:
  case WM_CANCELMODE:
    CancelPointerGesture();
    return 0;
  case fushi::kLowLevelMouseClickMessage:
    // Legacy popup notification: attached glyphs use the transaction-specific
    // down/up messages above, including calibration probes.
    return 0;
  case fushi::kLowLevelMouseShieldReleaseMessage:
    fushi::FinalizeLowLevelMouseDirectInputShield(hwnd_);
    return 0;
  case WM_PAINT: {
    PAINTSTRUCT paint{};
    BeginPaint(hwnd_, &paint);
    EndPaint(hwnd_, &paint);
    return 0;
  }
  case WM_ERASEBKGND:
    return 1;
  case WM_DPICHANGED:
  case WM_DISPLAYCHANGE:
    SyncToTarget();
    return 0;
  case kSyncTargetMessage:
    SyncToTarget();
    return 0;
  case fushi::kLowLevelMouseAttachedGlyphRearmMessage:
    // A popup released the singleton only after its full input transaction
    // became neutral. Re-run normal admission now instead of waiting for the
    // 500 ms health timer.
    SyncToTarget();
    fushi::CompleteLowLevelAttachedGlyphRearm(hwnd_);
    return 0;
  case WM_NCDESTROY:
    fushi::RetireLowLevelAttachedGlyphRearmCandidate(hwnd_);
    SetWindowLongPtrW(hwnd_, GWLP_USERDATA, 0);
    return DefWindowProcW(hwnd_, message, wparam, lparam);
  default:
    return DefWindowProcW(hwnd_, message, wparam, lparam);
  }
}
