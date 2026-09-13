import Foundation
import Network
import WebKit
#if os(iOS)
import Flutter
import UIKit
typealias ChallengePresentationRoot = UIViewController
#else
import Cocoa
import FlutterMacOS
typealias ChallengePresentationRoot = NSWindow
#endif

/// A short-lived native challenge browser. Its proxy and cookies belong only to
/// its own data store; the reader and flutter_inappwebview default store are not
/// modified. The channel returns cookies, never a persisted browsing session.
final class FushiChallengeBrowser {
  private let channel: FlutterMethodChannel
  private let presentationRoot: () -> ChallengePresentationRoot?
  private var session: ChallengeSession?

  init(binaryMessenger: FlutterBinaryMessenger,
       presentationRoot: @escaping () -> ChallengePresentationRoot?) {
    self.presentationRoot = presentationRoot
    channel = FlutterMethodChannel(
      name: "app.fushi.reader/cloudflare_proxy_browser", binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        guard let self = self else {
          result(FlutterError(code: "BROWSER_UNAVAILABLE", message: "Challenge browser is unavailable", details: nil))
          return
        }
        self.handle(call, result: result)
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "isSupported" {
      if #available(iOS 17.0, macOS 14.0, *) { result(true) }
      else { result(false) }
      return
    }
    guard call.method == "solve" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard #available(iOS 17.0, macOS 14.0, *) else {
      result(FlutterError(code: "PROXY_BROWSER_UNSUPPORTED",
        message: "An isolated proxy browser requires iOS 17 or macOS 14", details: nil))
      return
    }
    guard session == nil else {
      result(FlutterError(code: "PROXY_BROWSER_BUSY", message: "A challenge browser is already open", details: nil))
      return
    }
    guard let root = presentationRoot(),
          let arguments = call.arguments as? [String: Any],
          let input = ChallengeInput(arguments) else {
      result(FlutterError(code: "PROXY_BROWSER_ARGUMENTS", message: "Invalid challenge browser request", details: nil))
      return
    }
    let next = ChallengeSession(input: input) { [weak self] value in
      self?.session = nil
      result(value)
    }
    session = next
    next.present(from: root)
  }
}

private struct ChallengeInput {
  let url: URL
  let userAgent: String
  let proxyPort: UInt16
  let proxyUsername: String
  let proxyPassword: String
  let title: String
  let closeLabel: String
  let staleClearance: Set<String>
  let cookies: [HTTPCookie]

  init?(_ arguments: [String: Any]) {
    guard let rawURL = arguments["url"] as? String,
          let url = URL(string: rawURL), url.scheme == "https",
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
          let userAgent = arguments["userAgent"] as? String, !userAgent.isEmpty,
          let endpoint = arguments["proxyEndpoint"] as? String,
          let proxy = URLComponents(string: endpoint), proxy.scheme == "http",
          proxy.host == "127.0.0.1", let port = proxy.port,
          let proxyPort = UInt16(exactly: port), proxyPort > 0,
          let username = proxy.user, !username.isEmpty,
          let password = proxy.password, !password.isEmpty,
          proxy.path.isEmpty || proxy.path == "/",
          proxy.query == nil, proxy.fragment == nil,
          let title = arguments["title"] as? String,
          let closeLabel = arguments["closeLabel"] as? String else { return nil }
    self.url = url
    self.userAgent = userAgent
    self.proxyPort = proxyPort
    proxyUsername = username
    proxyPassword = password
    self.title = title
    self.closeLabel = closeLabel
    staleClearance = Set(arguments["staleClearance"] as? [String] ?? [])
    cookies = (arguments["cookies"] as? [[String: Any]] ?? []).compactMap { item in
      guard let name = item["name"] as? String, !name.isEmpty,
            let value = item["value"] as? String,
            let domain = item["domain"] as? String,
            Self.matches(host: host, domain: domain) else { return nil }
      var properties: [HTTPCookiePropertyKey: Any] = [
        .name: name, .value: value, .domain: domain,
        .path: item["path"] as? String ?? "/"
      ]
      if item["secure"] as? Bool == true { properties[.secure] = "TRUE" }
      if let milliseconds = item["expiresAt"] as? NSNumber {
        let expiry = Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
        guard expiry > Date() else { return nil }
        properties[.expires] = expiry
      }
      return HTTPCookie(properties: properties)
    }
  }

  static func matches(host: String, domain: String) -> Bool {
    let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let target = host.lowercased()
    return !normalized.isEmpty && (target == normalized || target.hasSuffix("." + normalized))
  }
}

private final class ChallengeSession: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
  private let input: ChallengeInput
  private let webView: WKWebView
  private let complete: (Any?) -> Void
  private var finished = false
  private var observingCookies = false
#if os(iOS)
  private var navigationController: UINavigationController?
#else
  private weak var parentWindow: NSWindow?
  private var window: NSWindow?
#endif

  @available(iOS 17.0, macOS 14.0, *)
  init(input: ChallengeInput, complete: @escaping (Any?) -> Void) {
    self.input = input
    self.complete = complete
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: input.proxyPort)!)
    var proxy = ProxyConfiguration(httpCONNECTProxy: endpoint)
    proxy.applyCredential(username: input.proxyUsername, password: input.proxyPassword)
    proxy.allowFailover = false
    dataStore.proxyConfigurations = [proxy]
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.customUserAgent = input.userAgent
    super.init()
    webView.navigationDelegate = self
  }

  func present(from root: ChallengePresentationRoot) {
#if os(iOS)
    let controller = UIViewController()
    controller.title = input.title
    controller.view = webView
    controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: input.closeLabel, style: .plain, target: self, action: #selector(cancel))
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .formSheet
    navigationController = navigation
    var presenter = root
    while let next = presenter.presentedViewController { presenter = next }
    presenter.present(navigation, animated: true) { [weak self] in
      guard let self = self, !self.finished else { return }
      navigation.presentationController?.delegate = self
      self.load()
    }
#else
    let controller = NSViewController()
    controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    let close = NSButton(title: input.closeLabel, target: self, action: #selector(cancel))
    close.keyEquivalent = "\u{1b}"
    close.translatesAutoresizingMaskIntoConstraints = false
    webView.translatesAutoresizingMaskIntoConstraints = false
    controller.view.addSubview(close)
    controller.view.addSubview(webView)
    NSLayoutConstraint.activate([
      close.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 10),
      close.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -12),
      webView.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 10),
      webView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor)
    ])
    let panel = NSWindow(contentViewController: controller)
    panel.title = input.title
    panel.styleMask = [.titled, .closable, .resizable]
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    parentWindow = root
    window = panel
    root.beginSheet(panel) { [weak self] _ in self?.finish(nil) }
    load()
#endif
  }

  private func load() {
    let store = webView.configuration.websiteDataStore.httpCookieStore
    let seeded = DispatchGroup()
    for cookie in input.cookies {
      seeded.enter()
      store.setCookie(cookie) { seeded.leave() }
    }
    seeded.notify(queue: .main) { [weak self] in
      guard let self = self, !self.finished else { return }
      store.add(self)
      self.observingCookies = true
      self.webView.load(URLRequest(url: self.input.url))
    }
  }

  @objc private func cancel() { finish(nil) }

  private func finish(_ value: Any?) {
    guard !finished else { return }
    finished = true
    webView.stopLoading()
    webView.navigationDelegate = nil
    if observingCookies {
      webView.configuration.websiteDataStore.httpCookieStore.remove(self)
      observingCookies = false
    }
#if os(iOS)
    if let navigation = navigationController, navigation.presentingViewController != nil {
      navigation.dismiss(animated: true) { [complete = self.complete] in complete(value) }
    } else {
      complete(value)
    }
    navigationController = nil
#else
    if let panel = window {
      parentWindow?.endSheet(panel)
      panel.orderOut(nil)
      panel.delegate = nil
    }
    window = nil
    complete(value)
#endif
  }

  func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { collectCookies() }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { collectCookies() }

  private func collectCookies() {
    guard !finished else { return }
    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] all in
      guard let self = self, !self.finished, let host = self.input.url.host else { return }
      let cookies = all.filter { cookie in
        ChallengeInput.matches(host: host, domain: cookie.domain)
          && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
      }
      guard cookies.contains(where: { cookie in
        cookie.name == "cf_clearance" && !cookie.value.isEmpty
          && !self.input.staleClearance.contains(cookie.value)
      }) else { return }
      self.finish(cookies.map { cookie -> [String: Any] in
        ["name": cookie.name, "value": cookie.value, "domain": cookie.domain,
         "path": cookie.path, "secure": cookie.isSecure,
         "expiresAt": cookie.expiresDate.map { NSNumber(value: Int64($0.timeIntervalSince1970 * 1000)) as Any } ?? NSNull()]
      })
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if navigationAction.targetFrame?.isMainFrame == false,
       navigationAction.request.url?.absoluteString == "about:blank" {
      decisionHandler(.allow)
      return
    }
    guard let url = navigationAction.request.url, url.scheme == "https" else {
      decisionHandler(.cancel)
      return
    }
    // CF's challenge iframe has a different origin. Keep subframes working,
    // while the verification window cannot navigate to an unrelated main site.
    if navigationAction.targetFrame?.isMainFrame != false && url.host != input.url.host {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
               completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    let space = challenge.protectionSpace
    guard space.isProxy() else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    guard space.host == "127.0.0.1", space.port == Int(input.proxyPort),
          space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
          challenge.previousFailureCount == 0 else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(user: input.proxyUsername,
      password: input.proxyPassword, persistence: .forSession))
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    fail(error)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    fail(error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finish(FlutterError(code: "PROXY_BROWSER_TERMINATED", message: "Challenge browser stopped", details: nil))
  }

  private func fail(_ error: Error) {
    let code = (error as NSError).code
    if code == NSURLErrorCancelled { return }
    // Native errors can include the relay URI; never forward their descriptions.
    finish(FlutterError(code: "PROXY_BROWSER_LOAD_FAILED",
      message: "Challenge page could not load through the application proxy", details: code))
  }
}

#if os(iOS)
extension ChallengeSession: UIAdaptivePresentationControllerDelegate {
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(nil) }
}
#else
extension ChallengeSession: NSWindowDelegate {
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    finish(nil)
    return false
  }
}
#endif
