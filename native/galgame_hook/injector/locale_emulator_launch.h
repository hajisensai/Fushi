#pragma once

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <iterator>

namespace hibiki_voice_hook {

// Locale Emulator 2.5.0.1 passes this fixed prefix to LoaderDll!LeCreateProcess,
// followed by a uint64 registry-redirection count. Keep the layout explicit: a
// PROCESS_INFORMATION-sized buffer is not enough for LoaderDll's extended
// result, and a truncated LEB makes the target fail before its entry point.
struct LeTimeFields {
  SHORT year = 0;
  SHORT month = 0;
  SHORT day = 0;
  SHORT hour = 0;
  SHORT minute = 0;
  SHORT second = 0;
  SHORT milliseconds = 0;
  SHORT weekday = 0;
};

struct LeTimeZoneInformation {
  LONG bias = 0;
  WCHAR standard_name[32] = {};
  LeTimeFields standard_start = {};
  LONG standard_bias = 0;
  WCHAR daylight_name[32] = {};
  LeTimeFields daylight_start = {};
  LONG daylight_bias = 0;
};

struct LeEnvironmentBlock {
  ULONG ansi_code_page = 0;
  ULONG oem_code_page = 0;
  ULONG locale_id = 0;
  ULONG default_charset = 0;
  ULONG hook_ui_language_api = 0;
  WCHAR default_face_name[32] = {};
  LeTimeZoneInformation timezone = {};
  std::uint64_t registry_redirection_count = 0;
};

static_assert(sizeof(LeTimeFields) == 16,
              "Locale Emulator TIME_FIELDS ABI changed");
static_assert(offsetof(LeEnvironmentBlock, registry_redirection_count) == 256,
              "Locale Emulator LEB prefix must remain 256 bytes");
static_assert(sizeof(LeEnvironmentBlock) == 264,
              "Locale Emulator empty-registry LEB must remain 264 bytes");

inline LeEnvironmentBlock BuildJapaneseLocaleEnvironment() {
  LeEnvironmentBlock environment = {};
  environment.ansi_code_page = 932;
  environment.oem_code_page = 932;
  environment.locale_id = 0x0411;
  environment.default_charset = 128;  // SHIFTJIS_CHARSET
  environment.hook_ui_language_api = 0;
  environment.timezone.bias = -540;  // UTC = local time + bias.
  const wchar_t timezone_name[] = L"Tokyo Standard Time";
  for (std::size_t i = 0; i + 1 < std::size(environment.timezone.standard_name) &&
                          timezone_name[i] != L'\0';
       ++i) {
    environment.timezone.standard_name[i] = timezone_name[i];
    environment.timezone.daylight_name[i] = timezone_name[i];
  }
  return environment;
}

enum class LocaleThreadResumePolicy {
  kNotLocaleLaunched,
  kBeforeProcessDiscovery,
  kAfterEarlyInjection,
};

// Locale Emulator always creates the target suspended. Launch strategies that
// must observe a window or child process cannot wait on that suspended target;
// they resume immediately and retain their existing delayed-attach behavior.
// Normal launch keeps the primary thread suspended until Hibiki's early hook is
// installed, preserving the KiriKiri startup boundary.
inline LocaleThreadResumePolicy SelectLocaleThreadResumePolicy(
    bool locale_launched, bool delayed_attach, bool follow_child_processes) {
  if (!locale_launched) {
    return LocaleThreadResumePolicy::kNotLocaleLaunched;
  }
  if (delayed_attach || follow_child_processes) {
    return LocaleThreadResumePolicy::kBeforeProcessDiscovery;
  }
  return LocaleThreadResumePolicy::kAfterEarlyInjection;
}

}  // namespace hibiki_voice_hook
