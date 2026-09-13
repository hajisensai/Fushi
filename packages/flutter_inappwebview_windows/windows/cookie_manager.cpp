#include <cctype>
#include <ctime>
#include <nlohmann/json.hpp>
#include <Shlwapi.h>
#include <winrt/base.h>
#include <wrl/event.h>

#include "cookie_manager.h"
#include "types/callbacks_complete.h"
#include "utils/flutter.h"
#include "utils/log.h"

namespace flutter_inappwebview_plugin
{
  using namespace Microsoft::WRL;

  CookieManager::CookieManager(const FlutterInappwebviewWindowsPlugin* plugin)
    : plugin(plugin), ChannelDelegate(plugin->registrar->messenger(), CookieManager::METHOD_CHANNEL_NAME_PREFIX)
  {}

  void CookieManager::HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    auto& arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto& methodName = method_call.method_name();

    auto webViewEnvironmentId = get_optional_fl_map_value<std::string>(arguments, "webViewEnvironmentId");

    auto webViewEnvironment = plugin && webViewEnvironmentId.has_value() && map_contains(plugin->webViewEnvironmentManager->webViewEnvironments, webViewEnvironmentId.value())
      ? plugin->webViewEnvironmentManager->webViewEnvironments.at(webViewEnvironmentId.value()).get() : nullptr;

    auto result_ = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
    auto callback = [this, result_, methodName, arguments](WebViewEnvironment* webViewEnvironment)
      {
        if (!webViewEnvironment) {
          result_->Error("0", "Cannot obtain the WebViewEnvironment!");
          return;
        }

        if (string_equals(methodName, "setCookie")) {
          setCookie(webViewEnvironment, arguments, [result_](const bool& created)
            {
              result_->Success(created);
            });
        }
        else if (string_equals(methodName, "getCookie")) {
          auto url = get_fl_map_value<std::string>(arguments, "url");
          auto name = get_fl_map_value<std::string>(arguments, "name");
          getCookie(webViewEnvironment, url, name, [result_](const flutter::EncodableValue& cookie)
            {
              result_->Success(cookie);
            });
        }
        else if (string_equals(methodName, "getCookies")) {
          auto url = get_fl_map_value<std::string>(arguments, "url");
          getCookies(webViewEnvironment, url, [result_](const flutter::EncodableList& cookies)
            {
              result_->Success(cookies);
            });
        }
        else if (string_equals(methodName, "deleteCookie")) {
          auto url = get_fl_map_value<std::string>(arguments, "url");
          auto name = get_fl_map_value<std::string>(arguments, "name");
          auto path = get_fl_map_value<std::string>(arguments, "path");
          auto domain = get_optional_fl_map_value<std::string>(arguments, "domain");
          deleteCookie(webViewEnvironment, url, name, path, domain, [result_](const bool& deleted)
            {
              result_->Success(deleted);
            });
        }
        else if (string_equals(methodName, "deleteCookies")) {
          auto url = get_fl_map_value<std::string>(arguments, "url");
          auto path = get_fl_map_value<std::string>(arguments, "path");
          auto domain = get_optional_fl_map_value<std::string>(arguments, "domain");
          deleteCookies(webViewEnvironment, url, path, domain, [result_](const bool& deleted)
            {
              result_->Success(deleted);
            });
        }
        else if (string_equals(methodName, "deleteAllCookies")) {
          deleteAllCookies(webViewEnvironment, [result_](const bool& deleted)
            {
              result_->Success(deleted);
            });
        }
        else {
          result_->NotImplemented();
        }
      };

    if (webViewEnvironment) {
      callback(webViewEnvironment);
    }
    else {
      plugin->webViewEnvironmentManager->createOrGetDefaultWebViewEnvironment([callback](WebViewEnvironment* webViewEnvironment)
        {
          callback(webViewEnvironment);
        });
    }
  }

  // CDP `Network.getCookies` 的 `expires` 是**秒**（浮点，会话 cookie 为 -1），而
  // platform-interface `Cookie.expiresDate` 是**毫秒**（`setCookie` 也按毫秒收、下面 /1000 再喂 CDP）。
  // 旧代码把秒原样当毫秒回给 Dart：getCookies → setCookie 往返后 expires 落到 1970 年 → cookie 被
  // 当场丢弃（环境间复制登录态静默失效）；读侧的 expiresAt 也小了 1000 倍。会话 cookie 回 null。
  static flutter::EncodableValue cookieExpiresDateMs(const nlohmann::json& jsonCookie)
  {
    if (!jsonCookie.contains("expires") || !jsonCookie["expires"].is_number()) {
      return make_fl_value();
    }
    const double expiresSec = jsonCookie["expires"].get<double>();
    if (expiresSec < 0) {
      return make_fl_value();
    }
    return make_fl_value(static_cast<int64_t>(expiresSec * 1000.0));
  }

  // 一条 CDP cookie 对象是否对 `url` 生效（RFC 6265 §5.4：域匹配 + 路径前缀 + Secure 只发 https）。
  //
  // 读侧**不能**用 `Network.getCookies({urls})`：它按当前 target 的 cookie 访问语义筛，会把
  // 分区（CHIPS，`Partitioned` 属性）cookie 整个筛掉——Cloudflare 现在发的 `cf_clearance`
  // 就是分区 cookie，于是站点验证页轮询永远读不到已经落库的放行 cookie（BUG-2511）。改用
  // `Storage.getCookies` 拿整个 browser context 的全量（含分区，带 `partitionKey`），再在这里
  // 按 URL 自己匹配；分区键不参与匹配——调用方要的是「这个站点名下有什么」，而不是某个
  // 顶层站点视角下浏览器会发什么。
  struct ParsedCookieUrl {
    std::string host;
    std::string path;
    bool secure = false;
  };

  static std::string toLowerAscii(std::string value)
  {
    for (auto& ch : value) {
      ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return value;
  }

  static ParsedCookieUrl parseCookieUrl(const std::string& url)
  {
    ParsedCookieUrl parsed;
    const auto schemeEnd = url.find("://");
    std::string rest = schemeEnd == std::string::npos ? url : url.substr(schemeEnd + 3);
    parsed.secure = schemeEnd != std::string::npos && toLowerAscii(url.substr(0, schemeEnd)) == "https";
    const auto pathStart = rest.find_first_of("/?#");
    std::string authority = pathStart == std::string::npos ? rest : rest.substr(0, pathStart);
    parsed.path = pathStart == std::string::npos || rest[pathStart] != '/' ? "/" : rest.substr(pathStart);
    const auto queryStart = parsed.path.find_first_of("?#");
    if (queryStart != std::string::npos) {
      parsed.path = parsed.path.substr(0, queryStart);
    }
    const auto at = authority.rfind('@');
    if (at != std::string::npos) {
      authority = authority.substr(at + 1);
    }
    const auto colon = authority.rfind(':');
    if (colon != std::string::npos && authority.find(']') == std::string::npos) {
      authority = authority.substr(0, colon);
    }
    parsed.host = toLowerAscii(authority);
    return parsed;
  }

  static bool cookieDomainMatches(const std::string& host, std::string domain)
  {
    domain = toLowerAscii(domain);
    const bool hostOnly = !domain.empty() && domain[0] != '.';
    if (!hostOnly && !domain.empty()) {
      domain = domain.substr(1);
    }
    if (domain.empty()) {
      return false;
    }
    if (host == domain) {
      return true;
    }
    if (hostOnly) {
      return false;
    }
    return host.size() > domain.size()
      && host.compare(host.size() - domain.size(), domain.size(), domain) == 0
      && host[host.size() - domain.size() - 1] == '.';
  }

  static bool cookiePathMatches(const std::string& requestPath, const std::string& cookiePath)
  {
    if (cookiePath.empty() || cookiePath == "/") {
      return true;
    }
    if (requestPath == cookiePath) {
      return true;
    }
    if (requestPath.compare(0, cookiePath.size(), cookiePath) != 0) {
      return false;
    }
    return cookiePath.back() == '/' || requestPath[cookiePath.size()] == '/';
  }

  static bool cookieMatchesUrl(const nlohmann::json& jsonCookie, const ParsedCookieUrl& url)
  {
    if (!jsonCookie.contains("domain") || !jsonCookie["domain"].is_string()) {
      return false;
    }
    if (!cookieDomainMatches(url.host, jsonCookie["domain"].get<std::string>())) {
      return false;
    }
    const std::string path = jsonCookie.contains("path") && jsonCookie["path"].is_string()
      ? jsonCookie["path"].get<std::string>() : "/";
    if (!cookiePathMatches(url.path, path)) {
      return false;
    }
    const bool secure = jsonCookie.contains("secure") && jsonCookie["secure"].is_boolean() && jsonCookie["secure"].get<bool>();
    return !secure || url.secure;
  }

  static flutter::EncodableMap cookieToEncodableMap(const nlohmann::json& jsonCookie)
  {
    return flutter::EncodableMap{
      {"name", jsonCookie["name"].get<std::string>()},
      {"value", jsonCookie["value"].get<std::string>()},
      {"domain", jsonCookie["domain"].get<std::string>()},
      {"path", jsonCookie["path"].get<std::string>()},
      {"expiresDate", cookieExpiresDateMs(jsonCookie)},
      {"isHttpOnly", jsonCookie["httpOnly"].get<bool>()},
      {"isSecure", jsonCookie["secure"].get<bool>()},
      {"isSessionOnly", jsonCookie["session"].get<bool>()},
      {"sameSite", jsonCookie.contains("sameSite") ? jsonCookie["sameSite"].get<std::string>() : make_fl_value()}
    };
  }

  // 对 `url` 生效的全部 cookie（含分区 cookie），见 [cookieMatchesUrl]。
  static void collectCookiesForUrl(WebViewEnvironment* webViewEnvironment, const std::string& url, std::function<void(std::vector<nlohmann::json>)> completionHandler)
  {
    const ParsedCookieUrl parsed = parseCookieUrl(url);
    auto hr = webViewEnvironment->getWebView()->CallDevToolsProtocolMethod(L"Storage.getCookies", L"{}", Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
      [completionHandler, parsed](HRESULT errorCode, LPCWSTR returnObjectAsJson)
      {
        std::vector<nlohmann::json> matched;
        if (succeededOrLog(errorCode)) {
          nlohmann::json json = nlohmann::json::parse(wide_to_utf8(returnObjectAsJson));
          if (json.contains("cookies") && json["cookies"].is_array()) {
            for (auto& jsonCookie : json["cookies"]) {
              if (cookieMatchesUrl(jsonCookie, parsed)) {
                matched.push_back(jsonCookie);
              }
            }
          }
        }
        completionHandler(std::move(matched));
        return S_OK;
      }
    ).Get());

    if (failedAndLog(hr)) {
      completionHandler({});
    }
  }

  void CookieManager::setCookie(WebViewEnvironment* webViewEnvironment, const flutter::EncodableMap& map, std::function<void(const bool&)> completionHandler) const
  {
    if (!plugin || !plugin->webViewEnvironmentManager) {
      if (completionHandler) {
        completionHandler(false);
      }
      return;
    }

    auto url = get_fl_map_value<std::string>(map, "url");
    auto name = get_fl_map_value<std::string>(map, "name");
    auto value = get_fl_map_value<std::string>(map, "value");
    auto path = get_fl_map_value<std::string>(map, "path");
    auto domain = get_optional_fl_map_value<std::string>(map, "domain");
    auto expiresDate = get_optional_fl_map_value<int64_t>(map, "expiresDate");
    auto maxAge = get_optional_fl_map_value<int64_t>(map, "maxAge");
    auto isSecure = get_optional_fl_map_value<bool>(map, "isSecure");
    auto isHttpOnly = get_optional_fl_map_value<bool>(map, "isHttpOnly");
    auto sameSite = get_optional_fl_map_value<std::string>(map, "sameSite");

    nlohmann::json parameters = {
      {"url", url},
      {"name", name},
      {"value", value},
      {"path", path}
    };
    if (domain.has_value()) {
      parameters["domain"] = domain.value();
    }
    if (expiresDate.has_value()) {
      parameters["expires"] = expiresDate.value() / 1000;
    }
    if (maxAge.has_value()) {
      // time(NULL) represents the current unix timestamp in seconds
      parameters["expires"] = time(NULL) + maxAge.value();
    }
    if (isSecure.has_value()) {
      parameters["secure"] = isSecure.value();
    }
    if (isHttpOnly.has_value()) {
      parameters["httpOnly"] = isHttpOnly.value();
    }
    if (sameSite.has_value()) {
      parameters["sameSite"] = sameSite.value();
    }

    auto hr = webViewEnvironment->getWebView()->CallDevToolsProtocolMethod(L"Network.setCookie", utf8_to_wide(parameters.dump()).c_str(), Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
      [completionHandler](HRESULT errorCode, LPCWSTR returnObjectAsJson)
      {
        if (completionHandler) {
          completionHandler(succeededOrLog(errorCode));
        }
        return S_OK;
      }
    ).Get());

    if (failedAndLog(hr) && completionHandler) {
      completionHandler(false);
    }
  }

  void CookieManager::getCookie(WebViewEnvironment* webViewEnvironment, const std::string& url, const std::string& name, std::function<void(const flutter::EncodableValue&)> completionHandler) const
  {
    if (!plugin || !plugin->webViewEnvironmentManager) {
      if (completionHandler) {
        completionHandler(make_fl_value());
      }
      return;
    }

    collectCookiesForUrl(webViewEnvironment, url, [completionHandler, name](std::vector<nlohmann::json> cookies)
      {
        for (auto& jsonCookie : cookies) {
          if (string_equals(name, jsonCookie["name"].get<std::string>())) {
            if (completionHandler) {
              completionHandler(cookieToEncodableMap(jsonCookie));
            }
            return;
          }
        }
        if (completionHandler) {
          completionHandler(make_fl_value());
        }
      });
  }

  void CookieManager::getCookies(WebViewEnvironment* webViewEnvironment, const std::string& url, std::function<void(const flutter::EncodableList&)> completionHandler) const
  {
    if (!plugin || !plugin->webViewEnvironmentManager) {
      if (completionHandler) {
        completionHandler({});
      }
      return;
    }

    collectCookiesForUrl(webViewEnvironment, url, [completionHandler](std::vector<nlohmann::json> matched)
      {
        std::vector<flutter::EncodableValue> cookies = {};
        for (auto& jsonCookie : matched) {
          cookies.push_back(cookieToEncodableMap(jsonCookie));
        }
        if (completionHandler) {
          completionHandler(cookies);
        }
      });
  }

  void CookieManager::deleteCookie(WebViewEnvironment* webViewEnvironment, const std::string& url, const std::string& name, const std::string& path, const std::optional<std::string>& domain, std::function<void(const bool&)> completionHandler) const
  {
    if (!plugin || !plugin->webViewEnvironmentManager) {
      if (completionHandler) {
        completionHandler(false);
      }
      return;
    }

    nlohmann::json parameters = {
      {"url", url},
      {"name", name},
      {"path", path}
    };
    if (domain.has_value()) {
      parameters["domain"] = domain.value();
    }

    auto hr = webViewEnvironment->getWebView()->CallDevToolsProtocolMethod(L"Network.deleteCookies", utf8_to_wide(parameters.dump()).c_str(), Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
      [completionHandler](HRESULT errorCode, LPCWSTR returnObjectAsJson)
      {
        if (completionHandler) {
          completionHandler(succeededOrLog(errorCode));
        }
        return S_OK;
      }
    ).Get());

    if (failedAndLog(hr) && completionHandler) {
      completionHandler(false);
    }
  }

  void CookieManager::deleteCookies(WebViewEnvironment* webViewEnvironment, const std::string& url, const std::string& path, const std::optional<std::string>& domain, std::function<void(const bool&)> completionHandler) const
  {
    if (!plugin || !plugin->webViewEnvironmentManager) {
      if (completionHandler) {
        completionHandler(false);
      }
      return;
    }

    getCookies(webViewEnvironment, url, [this, webViewEnvironment, url, path, domain, completionHandler](const flutter::EncodableList& cookies)
      {
        auto callbacksComplete = std::make_shared<CallbacksComplete<bool>>(
          [completionHandler](const std::vector<bool>& values)
          {
            if (completionHandler) {
              completionHandler(true);
            }
          });

        for (auto& cookie : cookies) {
          auto cookieMap = std::get<flutter::EncodableMap>(cookie);
          auto name = get_fl_map_value<std::string>(cookieMap, "name");
          deleteCookie(webViewEnvironment, url, name, path, domain, [callbacksComplete](const bool& deleted)
            {
              callbacksComplete->addValue(deleted);
            });
        }
      });
  }

  void CookieManager::deleteAllCookies(WebViewEnvironment* webViewEnvironment, std::function<void(const bool&)> completionHandler) const
  {
    if (!plugin || !plugin->webViewEnvironmentManager) {
      if (completionHandler) {
        completionHandler(false);
      }
      return;
    }

    auto hr = webViewEnvironment->getWebView()->CallDevToolsProtocolMethod(L"Network.clearBrowserCookies", L"{}", Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
      [completionHandler](HRESULT errorCode, LPCWSTR returnObjectAsJson)
      {
        if (completionHandler) {
          completionHandler(succeededOrLog(errorCode));
        }
        return S_OK;
      }
    ).Get());

    if (failedAndLog(hr) && completionHandler) {
      completionHandler(false);
    }
  }

  CookieManager::~CookieManager()
  {
    debugLog("dealloc CookieManager");
    plugin = nullptr;
  }
}
