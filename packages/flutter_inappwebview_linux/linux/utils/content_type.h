#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_UTIL_CONTENT_TYPE_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_UTIL_CONTENT_TYPE_H_

#include <algorithm>
#include <cctype>
#include <string>

namespace flutter_inappwebview_plugin
{
  // Fushi patch (BUG-4102, mirrors flutter_inappwebview_windows
  // windows/utils/content_type.h).
  //
  // `CustomSchemeResponse.contentEncoding` is the response *charset* in the
  // platform interface (Android passes it as the `encoding` argument of
  // `android.webkit.WebResourceResponse`, iOS/macOS as
  // `URLResponse.textEncodingName`), not an HTTP `Content-Encoding`.
  // `webkit_uri_scheme_request_finish` only takes a media type, and WebKit reads
  // the charset from its `; charset=` parameter; upstream passed the bare type,
  // so a document without `<meta charset>` fell back to the default charset.
  //
  // Returns the `Content-Type` header value with [charset] attached as the
  // `charset` parameter. Unchanged when the type is empty, when [charset] is
  // empty or the plugin's conventional `binary` (= "no text charset"), or when
  // the type already carries an explicit `charset=` parameter (an explicit
  // header from the app wins).
  static inline std::string contentTypeWithCharset(const std::string& contentType,
    const std::string& charset)
  {
    if (contentType.empty() || charset.empty()) {
      return contentType;
    }
    std::string lowerCharset = charset;
    std::transform(lowerCharset.begin(), lowerCharset.end(), lowerCharset.begin(),
      [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (lowerCharset == "binary") {
      return contentType;
    }
    std::string lowerType = contentType;
    std::transform(lowerType.begin(), lowerType.end(), lowerType.begin(),
      [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (lowerType.find("charset=") != std::string::npos) {
      return contentType;
    }
    return contentType + "; charset=" + charset;
  }
}

#endif // FLUTTER_INAPPWEBVIEW_PLUGIN_UTIL_CONTENT_TYPE_H_
