#include "locale_emulator_launch.h"

#include <cstddef>
#include <cwchar>
#include <iostream>

namespace {

bool Check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << message << '\n';
  }
  return condition;
}

}  // namespace

int main() {
  const auto environment =
      hibiki_voice_hook::BuildJapaneseLocaleEnvironment();
  bool ok = true;
  ok &= Check(environment.ansi_code_page == 932, "ANSI code page");
  ok &= Check(environment.oem_code_page == 932, "OEM code page");
  ok &= Check(environment.locale_id == 0x0411, "Japanese locale id");
  ok &= Check(environment.default_charset == 128, "Shift-JIS charset");
  ok &= Check(environment.hook_ui_language_api == 0, "UI language hook");
  ok &= Check(environment.timezone.bias == -540, "Tokyo timezone bias");
  ok &= Check(std::wcscmp(environment.timezone.standard_name,
                          L"Tokyo Standard Time") == 0,
              "standard timezone name");
  ok &= Check(std::wcscmp(environment.timezone.daylight_name,
                          L"Tokyo Standard Time") == 0,
              "daylight timezone name");
  ok &= Check(environment.registry_redirection_count == 0,
              "registry redirect count");
  ok &= Check(offsetof(hibiki_voice_hook::LeEnvironmentBlock,
                       registry_redirection_count) == 256,
              "Locale Emulator ABI prefix");

  using hibiki_voice_hook::LocaleThreadResumePolicy;
  using hibiki_voice_hook::SelectLocaleThreadResumePolicy;
  ok &= Check(SelectLocaleThreadResumePolicy(false, false, false) ==
                  LocaleThreadResumePolicy::kNotLocaleLaunched,
              "ordinary process is not resumed by locale policy");
  ok &= Check(SelectLocaleThreadResumePolicy(true, false, false) ==
                  LocaleThreadResumePolicy::kAfterEarlyInjection,
              "ordinary locale launch stays suspended for early injection");
  ok &= Check(SelectLocaleThreadResumePolicy(true, true, false) ==
                  LocaleThreadResumePolicy::kBeforeProcessDiscovery,
              "delayed attach resumes before window discovery");
  ok &= Check(SelectLocaleThreadResumePolicy(true, false, true) ==
                  LocaleThreadResumePolicy::kBeforeProcessDiscovery,
              "child-follow launch resumes before child discovery");
  return ok ? 0 : 1;
}
