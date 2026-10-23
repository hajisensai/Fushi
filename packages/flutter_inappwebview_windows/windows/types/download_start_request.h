#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_DOWNLOAD_START_REQUEST_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_DOWNLOAD_START_REQUEST_H_

#include <flutter/standard_method_codec.h>
#include <optional>
#include <string>

#include "../utils/flutter.h"

namespace flutter_inappwebview_plugin
{
  // 与 platform interface 的 DownloadStartRequest.fromMap 字段一一对应
  // （url / userAgent / contentDisposition / mimeType / contentLength /
  // suggestedFilename / textEncodingName）。contentLength 在 Dart 侧是非空 int，
  // 未知大小按 Android 约定传 -1。
  class DownloadStartRequest
  {
  public:
    const std::string url;
    const std::optional<std::string> userAgent;
    const std::optional<std::string> contentDisposition;
    const std::optional<std::string> mimeType;
    const int64_t contentLength;
    const std::optional<std::string> suggestedFilename;
    const std::optional<std::string> textEncodingName;

    DownloadStartRequest(const std::string& url,
      const std::optional<std::string>& userAgent,
      const std::optional<std::string>& contentDisposition,
      const std::optional<std::string>& mimeType,
      const int64_t& contentLength,
      const std::optional<std::string>& suggestedFilename,
      const std::optional<std::string>& textEncodingName);
    ~DownloadStartRequest() = default;

    flutter::EncodableMap toEncodableMap() const;
  };
}

#endif //FLUTTER_INAPPWEBVIEW_PLUGIN_DOWNLOAD_START_REQUEST_H_
