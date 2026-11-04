#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_UTIL_CONTENT_TYPE_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_UTIL_CONTENT_TYPE_H_

#include <algorithm>
#include <cctype>
#include <string>

namespace flutter_inappwebview_plugin
{
  // Fushi patch (BUG-4108, see PATCHES.md "contentEncoding is the charset").
  //
  // `WebResourceResponse.contentEncoding` / `CustomSchemeResponse.contentEncoding`
  // is the response *charset* in the platform interface (Android passes it as
  // the `encoding` argument of `android.webkit.WebResourceResponse`, iOS/macOS as
  // `URLResponse.textEncodingName`). It is not the HTTP `Content-Encoding`
  // (gzip/br/...). Upstream Windows emitted it as `Content-Encoding: utf-8`, so
  // the charset never reached WebView2 and a document without `<meta charset>`
  // was decoded with the system ANSI code page (GBK on zh-CN Windows): UTF-8
  // U+2019 (bytes E2 80 99) rendered as two GBK ideographs plus U+FFFD.
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
