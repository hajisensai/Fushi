#include "download_start_request.h"

namespace flutter_inappwebview_plugin
{
  DownloadStartRequest::DownloadStartRequest(const std::string& url,
    const std::optional<std::string>& userAgent,
    const std::optional<std::string>& contentDisposition,
    const std::optional<std::string>& mimeType,
    const int64_t& contentLength,
    const std::optional<std::string>& suggestedFilename,
    const std::optional<std::string>& textEncodingName)
    : url(url), userAgent(userAgent), contentDisposition(contentDisposition),
    mimeType(mimeType), contentLength(contentLength),
    suggestedFilename(suggestedFilename), textEncodingName(textEncodingName)
  {}

  flutter::EncodableMap DownloadStartRequest::toEncodableMap() const
  {
    return flutter::EncodableMap{
      {"url", url},
      {"userAgent", make_fl_value(userAgent)},
      {"contentDisposition", make_fl_value(contentDisposition)},
      {"mimeType", make_fl_value(mimeType)},
      {"contentLength", make_fl_value(contentLength)},
      {"suggestedFilename", make_fl_value(suggestedFilename)},
      {"textEncodingName", make_fl_value(textEncodingName)}
    };
  }
}
