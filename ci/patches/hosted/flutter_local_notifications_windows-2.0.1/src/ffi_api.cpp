// Hibiki patch (BUG-2838) over flutter_local_notifications_windows 2.0.1.
//
// Upstream crashed long-running processes (3.5~7 h) with an uncaught C++
// exception, HRESULT 0x800401FD CO_E_OBJNOTCONNECTED, thrown from Show() on the
// Dart main thread. Two root causes, both fixed here:
//
//  1. init() cached the ToastNotifier (a cross-process COM proxy) and the
//     ToastNotificationHistory in NativePlugin for the whole process lifetime.
//     When the notification platform service restarts or the session changes,
//     that proxy disconnects and every later call on it throws. The cached
//     state is gone: every call now obtains a fresh notifier / history.
//  2. No exported function caught C++ exceptions, so a winrt::hresult_error
//     (or std::stoi's invalid_argument on a non-numeric tag) crossed the FFI
//     boundary, where Dart cannot catch it and the runtime calls terminate().
//     Every export now converts any exception into its existing failure value.
//
// Also: tags that are not plugin-issued integers are skipped instead of
// throwing, and freeLaunchDetails releases new[]-allocated strings with
// delete[]. Guarded by fushi/test/build/windows_toast_ffi_boundary_guard_test.dart.

#include <windows.h>  // <-- This must be the first Windows header
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Data.Xml.Dom.h>

#include <cerrno>
#include <climits>
#include <cwchar>
#include <optional>
#include <vector>

#include "ffi_api.h"
#include "plugin.hpp"
#include "utils.hpp"

using winrt::Windows::Data::Xml::Dom::XmlDocument;

namespace {

/// A fresh notifier for this call. Never cache it: it is a COM proxy into the
/// notification platform and goes stale when that service restarts.
ToastNotifier notifierFor(const NativePlugin& plugin) {
  return plugin.hasIdentity ? ToastNotificationManager::CreateToastNotifier()
                            : ToastNotificationManager::CreateToastNotifier(plugin.aumid);
}

/// Parses a tag written by this plugin (the decimal notification id).
/// Anything else (empty, non-numeric, out of range) is not ours: nullopt.
std::optional<int> idFromTag(const winrt::hstring& tag) {
  if (tag.empty()) return std::nullopt;
  wchar_t* end = nullptr;
  errno = 0;
  const long value = std::wcstol(tag.c_str(), &end, 10);
  if (errno != 0 || *end != L'\0' || value < INT_MIN || value > INT_MAX) return std::nullopt;
  return static_cast<int>(value);
}

/// Copies the plugin-issued ids of [notifications] into a new[] array
/// (released by freeDetailsArray). Empty result: *size = 0 and nullptr.
template <typename Notifications>
NativeNotificationDetails* toDetailsArray(const Notifications& notifications, int* size) {
  std::vector<int> ids;
  for (const auto notification : notifications) {
    const auto id = idFromTag(notification.Tag());
    if (id.has_value()) ids.push_back(id.value());
  }
  *size = 0;
  if (ids.empty()) return nullptr;
  const auto result = new NativeNotificationDetails[ids.size()];
  for (size_t index = 0; index < ids.size(); index++) result[index].id = ids[index];
  *size = static_cast<int>(ids.size());
  return result;
}

}  // namespace

bool hasPackageIdentity() {
  try {
    if (!IsWindows8OrGreater()) return false;
    uint32_t length = 0;
    int error = GetCurrentPackageFullName(&length, nullptr);
    return error != APPMODEL_ERROR_NO_PACKAGE;
  } catch (...) {
    return false;
  }
}

NativePlugin* createPlugin() {
  try {
    return new NativePlugin();
  } catch (...) {
    return nullptr;
  }
}

void disposePlugin(NativePlugin* plugin) {
  try {
    delete plugin;
  } catch (...) {
    // void export: a C ABI has no channel back to Dart, and letting the
    // exception escape terminates the process. Dropping it is the contract.
  }
}

bool init(
  NativePlugin* plugin, char* appName, char* aumId, char* guid, char* iconPath,
  NativeNotificationCallback callback
) {
  try {
    if (plugin == nullptr) return false;
    string icon;
    if (iconPath != nullptr) icon = string(iconPath);
    const auto didRegister = plugin->registerApp(aumId, appName, guid, icon, callback);
    if (!didRegister) return false;
    plugin->hasIdentity = hasPackageIdentity();
    plugin->aumid = winrt::to_hstring(aumId);
    // Probe once so init still reports false when toasts are unavailable;
    // the notifier itself is not kept.
    notifierFor(*plugin);
    plugin->isReady = true;
    return true;
  } catch (...) {
    return false;
  }
}

bool isValidXml(char* xml) {
  try {
    XmlDocument doc;
    doc.LoadXml(winrt::to_hstring(xml));
    return true;
  } catch (...) {
    return false;
  }
}

bool showNotification(NativePlugin* plugin, int id, char* xml, NativeStringMap bindings) {
  try {
    if (!plugin->isReady) return false;
    XmlDocument doc;
    doc.LoadXml(winrt::to_hstring(xml));
    ToastNotification notification(doc);
    notification.Tag(winrt::to_hstring(id));
    notification.Data(dataFromMap(bindings));
    notifierFor(*plugin).Show(notification);
    return true;
  } catch (...) {
    return false;
  }
}

bool scheduleNotification(NativePlugin* plugin, int id, char* xml, int time) {
  try {
    if (!plugin->isReady) return false;
    XmlDocument doc;
    doc.LoadXml(winrt::to_hstring(xml));
    ScheduledToastNotification notification(doc, winrt::clock::from_time_t(time));
    notification.Tag(winrt::to_hstring(id));
    notifierFor(*plugin).AddToSchedule(notification);
    return true;
  } catch (...) {
    return false;
  }
}

NativeUpdateResult updateNotification(NativePlugin* plugin, int id, NativeStringMap bindings) {
  try {
    if (!plugin->isReady) return NativeUpdateResult::failed;
    const auto tag = winrt::to_hstring(id);
    const auto result = notifierFor(*plugin).Update(dataFromMap(bindings), tag);
    return (NativeUpdateResult) result;
  } catch (...) {
    return NativeUpdateResult::failed;
  }
}

void cancelAll(NativePlugin* plugin) {
  try {
    if (!plugin->isReady) return;
    const auto history = ToastNotificationManager::History();
    if (plugin->hasIdentity) {
      history.Clear();
    } else {
      history.Clear(plugin->aumid);
    }
    const auto notifier = notifierFor(*plugin);
    for (const auto notification : notifier.GetScheduledToastNotifications()) {
      notifier.RemoveFromSchedule(notification);
    }
  } catch (...) {
    // void export: a C ABI has no channel back to Dart, and letting the
    // exception escape terminates the process. Dropping it is the contract.
  }
}

void cancelNotification(NativePlugin* plugin, int id) {
  try {
    if (!plugin->isReady) return;
    const auto tag = winrt::to_hstring(id);
    if (plugin->hasIdentity) ToastNotificationManager::History().Remove(tag);
    const auto notifier = notifierFor(*plugin);
    for (const auto notification : notifier.GetScheduledToastNotifications()) {
      if (notification.Tag() == tag) {
        notifier.RemoveFromSchedule(notification);
        return;
      }
    }
  } catch (...) {
    // void export: a C ABI has no channel back to Dart, and letting the
    // exception escape terminates the process. Dropping it is the contract.
  }
}

NativeNotificationDetails* getActiveNotifications(NativePlugin* plugin, int* size) {
  // TODO: Get more details here
  try {
    *size = 0;
    if (!plugin->isReady || !plugin->hasIdentity) return nullptr;
    return toDetailsArray(ToastNotificationManager::History().GetHistory(), size);
  } catch (...) {
    *size = 0;
    return nullptr;
  }
}

NativeNotificationDetails* getPendingNotifications(NativePlugin* plugin, int* size) {
  // TODO: Get more details here
  try {
    *size = 0;
    if (!plugin->isReady) return nullptr;
    return toDetailsArray(notifierFor(*plugin).GetScheduledToastNotifications(), size);
  } catch (...) {
    *size = 0;
    return nullptr;
  }
}

void freeDetailsArray(NativeNotificationDetails* ptr) {
  try {
    delete[] ptr;
  } catch (...) {
    // void export: a C ABI has no channel back to Dart, and letting the
    // exception escape terminates the process. Dropping it is the contract.
  }
}

void freeLaunchDetails(NativeLaunchDetails details) {
  try {
    if (details.payload != nullptr) delete[] details.payload;
    for (int index = 0; index < details.data.size; index++) {
      const auto pair = details.data.entries[index];
      delete[] pair.key;
      delete[] pair.value;
    }
    if (details.data.entries != nullptr) delete[] details.data.entries;
  } catch (...) {
    // void export: a C ABI has no channel back to Dart, and letting the
    // exception escape terminates the process. Dropping it is the contract.
  }
}
