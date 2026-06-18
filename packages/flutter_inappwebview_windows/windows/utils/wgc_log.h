#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_WGC_LOG_UTIL_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_WGC_LOG_UTIL_H_

#include <windows.h>

#include <cstdint>
#include <string>

namespace flutter_inappwebview_plugin
{
  // Always-compiled structured WGC lifecycle log. Release builds need this
  // because GraphicsCapture crashes often happen before our Flutter/Dart error
  // path can observe the native lifetime state.
  class WgcLog {
  public:
    // Writes one structured line:
    // <UTC> tid=<thread> pid=<process> evt=<event> pool=<ptr> <detail>
    static void Write(const char* event, const void* pool,
      const std::string& detail = std::string());

  private:
    static const std::wstring& LogFilePath();
    static void TrimIfTooLarge(const std::wstring& path);

    static constexpr DWORD kMaxFileBytes = 512 * 1024;
  };
}

#endif  // FLUTTER_INAPPWEBVIEW_PLUGIN_WGC_LOG_UTIL_H_
