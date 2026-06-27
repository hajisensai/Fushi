#include "global_lookup_window.h"

#include <shlwapi.h>

#include <fstream>
#include <memory>
#include <sstream>

#pragma comment(lib, "Shlwapi.lib")

using Microsoft::WRL::Callback;
using Microsoft::WRL::Make;

namespace {

constexpr wchar_t kClassName[] = L"HibikiGlobalLookupWindow";

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  int size = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                 static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                 static_cast<int>(value.size()), nullptr, 0,
                                 nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), size,
                      nullptr, nullptr);
  return result;
}

// Picks the HTTP Content-Type header for a resolved custom-scheme resource,
// mirroring the in-app dictionary_webview_media.dart logic so the app-external
// overlay serves the SAME content-type the in-app InAppWebView does:
//   - dictmedia:// (dictionary <link> stylesheets) -> text/css (matches the
//     in-app dictmedia branch which hardcodes text/css).
//   - image:// and everything else -> by file extension (png/jpg/gif/webp/svg),
//     defaulting to application/octet-stream.
// The page only references dictmedia:// for the dictionary's own <link>
// stylesheets, so text/css is the faithful type; image:// covers gaiji/<img>.
std::wstring MediaContentTypeHeader(const std::string& url) {
  const bool is_dictmedia = url.rfind("dictmedia://", 0) == 0;
  if (is_dictmedia) {
    return L"Content-Type: text/css";
  }
  // Extension is taken from the part before any '?' query.
  std::string path = url;
  size_t q = path.find('?');
  if (q != std::string::npos) {
    path = path.substr(0, q);
  }
  size_t dot = path.find_last_of('.');
  std::string ext;
  if (dot != std::string::npos) {
    ext = path.substr(dot + 1);
    for (char& c : ext) {
      c = static_cast<char>(::tolower(static_cast<unsigned char>(c)));
    }
  }
  if (ext == "png") return L"Content-Type: image/png";
  if (ext == "jpg" || ext == "jpeg") return L"Content-Type: image/jpeg";
  if (ext == "gif") return L"Content-Type: image/gif";
  if (ext == "webp") return L"Content-Type: image/webp";
  if (ext == "svg") return L"Content-Type: image/svg+xml";
  return L"Content-Type: application/octet-stream";
}

}  // namespace

GlobalLookupWindow* GlobalLookupWindow::s_hook_owner_ = nullptr;

void CALLBACK GlobalLookupWindow::ForegroundHookProc(HWINEVENTHOOK, DWORD,
                                                     HWND hwnd, LONG, LONG,
                                                     DWORD, DWORD) {
  GlobalLookupWindow* self = s_hook_owner_;
  // The user activated another window (click outside the card). Own-process
  // events are skipped via WINEVENT_SKIPOWNPROCESS, so this never fires for our
  // own overlay/main window.
  if (self != nullptr && self->IsShowing() && hwnd != self->hwnd_) {
    self->Hide();
  }
}

LRESULT CALLBACK GlobalLookupWindow::MouseHookProc(int code, WPARAM wparam,
                                                   LPARAM lparam) {
  if (code >= 0 &&
      (wparam == WM_LBUTTONDOWN || wparam == WM_RBUTTONDOWN ||
       wparam == WM_NCLBUTTONDOWN)) {
    GlobalLookupWindow* self = s_hook_owner_;
    if (self != nullptr && self->IsShowing() && self->hwnd_ != nullptr) {
      const MSLLHOOKSTRUCT* info =
          reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam);
      RECT rc;
      GetWindowRect(self->hwnd_, &rc);
      // TODO-867 P3c C4/E2 — the window is now the whole nested-stack bounding
      // box (E1): the transparent area BETWEEN cards is inside the HWND rect, so
      // a coarse "PtInRect -> Hide" would wrongly close on a click in that gap.
      // Split the decision: a click OUTSIDE the whole window rect dismisses the
      // overlay (clicked another app); a click INSIDE the window is forwarded to
      // the web host, which owns the per-shell geometry truth and decides whether
      // to keep (hit a card) or dismiss the root (gap between cards). C++ only
      // feeds coordinates; the host hit-tests (no shell geometry duplicated here).
      if (!PtInRect(&rc, info->pt)) {
        self->Hide();  // Click outside the whole stack window -> dismiss.
      } else {
        self->ForwardGlobalClickToHost(info->pt.x, info->pt.y);
      }
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

GlobalLookupWindow::GlobalLookupWindow() = default;

GlobalLookupWindow::~GlobalLookupWindow() {
  if (foreground_hook_ != nullptr) {
    UnhookWinEvent(foreground_hook_);
    foreground_hook_ = nullptr;
  }
  if (mouse_hook_ != nullptr) {
    UnhookWindowsHookEx(mouse_hook_);
    mouse_hook_ = nullptr;
  }
  s_hook_owner_ = nullptr;
  if (controller_) {
    controller_->Close();
  }
  if (hwnd_ != nullptr) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
  if (class_registered_) {
    UnregisterClassW(kClassName, GetModuleHandle(nullptr));
  }
}

void GlobalLookupWindow::EnsureWindowClass() {
  if (class_registered_) {
    return;
  }
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = GlobalLookupWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.lpszClassName = kClassName;
  RegisterClassExW(&wc);
  class_registered_ = true;
}

int GlobalLookupWindow::OffscreenX() const {
  // Just past the right edge of the whole virtual desktop: the window is shown
  // (so WebView2 renders + the page can self-measure) but invisible to the
  // user. Avoids the flicker of sizing a *visible* window through the
  // measure->resize convergence. Reveal() moves it to the cursor once stable.
  return GetSystemMetrics(SM_XVIRTUALSCREEN) +
         GetSystemMetrics(SM_CXVIRTUALSCREEN) + 200;
}

bool GlobalLookupWindow::ShowAt(int x, int y, int width, int height,
                                HWND owner) {
  EnsureWindowClass();
  // Remember where the card should ultimately appear; Reveal() uses it.
  pending_x_ = x;
  pending_y_ = y;
  revealed_ = false;
  // Render OFF-SCREEN at the requested size. The page measures itself there and
  // Dart calls Reveal() with the final size, so the user only ever sees the
  // settled card (no width/height jitter on screen).
  const int off_x = OffscreenX();
  if (hwnd_ == nullptr) {
    // No WS_EX_LAYERED: WebView2 brings its own composition surface and does not
    // coexist with a layered window. WS_EX_NOACTIVATE keeps the foreground app's
    // keyboard focus intact when the card appears (design §5 guarantee 3).
    hwnd_ = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kClassName,
        L"Hibiki Lookup", WS_POPUP, off_x, 0, width, height, owner, nullptr,
        GetModuleHandle(nullptr), this);
    if (hwnd_ == nullptr) {
      return false;
    }
    EnsureWebView();
  } else {
    SetWindowPos(hwnd_, HWND_TOPMOST, off_x, 0, width, height, SWP_NOACTIVATE);
  }
  // Shown (so WebView2 lays out + renders) but parked off-screen and NOT yet
  // "visible_" — the click-outside hooks stay disarmed until Reveal().
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  visible_ = false;
  return true;
}

void GlobalLookupWindow::Reveal(int width, int height) {
  if (hwnd_ == nullptr) {
    return;
  }
  if (width <= 0 || height <= 0) {
    RECT rc;
    GetWindowRect(hwnd_, &rc);
    width = rc.right - rc.left;
    height = rc.bottom - rc.top;
  }
  int x = pending_x_;
  int y = pending_y_;
  // Clamp the final card to the cursor monitor's work area (same math as
  // ResizeTo) so a tall/edge-anchored card stays fully on-screen.
  POINT cursor = {pending_x_, pending_y_};
  HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfo(monitor, &mi)) {
    const int work_w = mi.rcWork.right - mi.rcWork.left;
    const int work_h = mi.rcWork.bottom - mi.rcWork.top;
    width = width < work_w ? width : work_w;
    height = height < work_h ? height : work_h;
    if (x + width > mi.rcWork.right) x = mi.rcWork.right - width;
    if (y + height > mi.rcWork.bottom) y = mi.rcWork.bottom - height;
    if (x < mi.rcWork.left) x = mi.rcWork.left;
    if (y < mi.rcWork.top) y = mi.rcWork.top;
  }
  SetWindowPos(hwnd_, HWND_TOPMOST, x, y, width, height,
               SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  revealed_ = true;
  visible_ = true;
  // Arm the click-outside dismiss only now that the card is on-screen (skip our
  // own process so interacting with the card / main window does not close it).
  s_hook_owner_ = this;
  if (foreground_hook_ == nullptr) {
    foreground_hook_ = SetWinEventHook(
        EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
        &GlobalLookupWindow::ForegroundHookProc, 0, 0,
        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
  }
  if (mouse_hook_ == nullptr) {
    mouse_hook_ = SetWindowsHookEx(WH_MOUSE_LL,
                                   &GlobalLookupWindow::MouseHookProc,
                                   GetModuleHandle(nullptr), 0);
  }
}

void GlobalLookupWindow::RevealStack(int dx, int dy, int width, int height) {
  if (hwnd_ == nullptr || width <= 0 || height <= 0) {
    return;
  }
  // The window moves to (cursor + dx, cursor + dy) and grows to the bbox size.
  // The host (global_lookup_host.js) shifted its layer by (-bbox.left, -bbox.top)
  // so the ROOT card stays pinned at the cursor while the whole cascade fits in
  // the window. Clamp to the cursor monitor work area like Reveal/ResizeTo.
  int x = pending_x_ + dx;
  int y = pending_y_ + dy;
  POINT cursor = {pending_x_, pending_y_};
  HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfo(monitor, &mi)) {
    const int work_w = mi.rcWork.right - mi.rcWork.left;
    const int work_h = mi.rcWork.bottom - mi.rcWork.top;
    width = width < work_w ? width : work_w;
    height = height < work_h ? height : work_h;
    if (x + width > mi.rcWork.right) x = mi.rcWork.right - width;
    if (y + height > mi.rcWork.bottom) y = mi.rcWork.bottom - height;
    if (x < mi.rcWork.left) x = mi.rcWork.left;
    if (y < mi.rcWork.top) y = mi.rcWork.top;
  }
  SetWindowPos(hwnd_, HWND_TOPMOST, x, y, width, height,
               SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  revealed_ = true;
  visible_ = true;
  // Arm the click-outside dismiss hooks now that the stack is on-screen (the
  // first reveal arms; later resizes are idempotent re-arms).
  s_hook_owner_ = this;
  if (foreground_hook_ == nullptr) {
    foreground_hook_ = SetWinEventHook(
        EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
        &GlobalLookupWindow::ForegroundHookProc, 0, 0,
        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
  }
  if (mouse_hook_ == nullptr) {
    mouse_hook_ = SetWindowsHookEx(WH_MOUSE_LL,
                                   &GlobalLookupWindow::MouseHookProc,
                                   GetModuleHandle(nullptr), 0);
  }
}

void GlobalLookupWindow::ResizeTo(int width, int height) {
  if (hwnd_ == nullptr || width <= 0 || height <= 0) {
    return;
  }
  RECT rc;
  GetWindowRect(hwnd_, &rc);
  int x = rc.left;
  int y = rc.top;

  HMONITOR monitor = MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfo(monitor, &mi)) {
    const int work_w = mi.rcWork.right - mi.rcWork.left;
    const int work_h = mi.rcWork.bottom - mi.rcWork.top;
    width = width < work_w ? width : work_w;
    height = height < work_h ? height : work_h;
    if (x + width > mi.rcWork.right) {
      x = mi.rcWork.right - width;
    }
    if (y + height > mi.rcWork.bottom) {
      y = mi.rcWork.bottom - height;
    }
    if (x < mi.rcWork.left) x = mi.rcWork.left;
    if (y < mi.rcWork.top) y = mi.rcWork.top;
  }
  SetWindowPos(hwnd_, HWND_TOPMOST, x, y, width, height,
               SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}

void GlobalLookupWindow::Hide() {
  visible_ = false;
  revealed_ = false;
  if (foreground_hook_ != nullptr) {
    UnhookWinEvent(foreground_hook_);
    foreground_hook_ = nullptr;
  }
  if (mouse_hook_ != nullptr) {
    UnhookWindowsHookEx(mouse_hook_);
    mouse_hook_ = nullptr;
  }
  s_hook_owner_ = nullptr;
  if (hwnd_ != nullptr) {
    ShowWindow(hwnd_, SW_HIDE);
  }
}

bool GlobalLookupWindow::IsShowing() const {
  return visible_ && hwnd_ != nullptr && IsWindowVisible(hwnd_);
}

std::wstring GlobalLookupWindow::LoadAdapterScript() const {
  if (popup_assets_dir_.empty()) {
    return std::wstring();
  }
  std::wstring path = popup_assets_dir_ + L"\\popup_bridge_adapter.js";
  std::ifstream file(path.c_str(), std::ios::binary);
  if (!file) {
    return std::wstring();
  }
  std::ostringstream ss;
  ss << file.rdbuf();
  return Utf8ToWide(ss.str());
}

// TODO-867 P3c — load the app-OUTSIDE nested-stack host script. Injected into
// the top-level WebView2 document (global_lookup_host.html) so
// window.__globalLookupHost.renderStack exists; the single-frame and nested
// lookups both render through the host iframe stack (no top-level direct
// renderPopup). Mirrors LoadAdapterScript exactly (read + UTF8->Wide).
std::wstring GlobalLookupWindow::LoadHostScript() const {
  if (popup_assets_dir_.empty()) {
    return std::wstring();
  }
  std::wstring path = popup_assets_dir_ + L"\\global_lookup_host.js";
  std::ifstream file(path.c_str(), std::ios::binary);
  if (!file) {
    return std::wstring();
  }
  std::ostringstream ss;
  ss << file.rdbuf();
  return Utf8ToWide(ss.str());
}

void GlobalLookupWindow::EnsureWebView() {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  auto options = Make<CoreWebView2EnvironmentOptions>();
  // Register image:// AND dictmedia:// as custom schemes so WebResourceRequested
  // fires for them (non file/http(s) schemes are otherwise ignored). Must mirror
  // the in-app InAppWebView which registers BOTH schemes (see
  // dictionary_webview_media.dart dictionaryMediaCustomSchemes = [image,
  // dictmedia]). image:// serves gaiji/img bytes; dictmedia:// serves the
  // dictionary's <link> stylesheets (+ their relative font/bg resources). Mirrors
  // the fork's webview_environment.cpp:69-76.
  wil::com_ptr<ICoreWebView2EnvironmentOptions4> options4;
  if (SUCCEEDED(options->QueryInterface(IID_PPV_ARGS(&options4)))) {
    auto image_reg = Make<CoreWebView2CustomSchemeRegistration>(L"image");
    image_reg->put_TreatAsSecure(TRUE);
    image_reg->put_HasAuthorityComponent(TRUE);
    auto dictmedia_reg =
        Make<CoreWebView2CustomSchemeRegistration>(L"dictmedia");
    dictmedia_reg->put_TreatAsSecure(TRUE);
    dictmedia_reg->put_HasAuthorityComponent(TRUE);
    ICoreWebView2CustomSchemeRegistration* regs[] = {image_reg.Get(),
                                                     dictmedia_reg.Get()};
    options4->SetCustomSchemeRegistrations(2, regs);
  }

  CreateCoreWebView2EnvironmentWithOptions(
      nullptr, nullptr, options.Get(),
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [this](HRESULT, ICoreWebView2Environment* env) -> HRESULT {
            env_ = env;
            env_->CreateCoreWebView2Controller(
                hwnd_,
                Callback<
                    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [this](HRESULT, ICoreWebView2Controller* ctrl) -> HRESULT {
                      if (ctrl == nullptr) {
                        return S_OK;
                      }
                      controller_ = ctrl;
                      controller_->get_CoreWebView2(&webview_);
                      controller_->put_IsVisible(TRUE);
                      // TODO-893 — paint the WebView2 composition surface
                      // TRANSPARENT (symptom 1, white-background half). The
                      // default DefaultBackgroundColor is opaque white, so the
                      // area OUTSIDE the rounded card shell (the host document
                      // has no body background of its own) shows as a hard white
                      // box — most visible once E1 enlarges the window into the
                      // cascade bounding box, where the white shows around the
                      // shell. ICoreWebView2Controller2::put_DefaultBackgroundColor
                      // with A=0 makes the surface transparent so only the shell
                      // (its theme card fill) paints. Available since WebView2
                      // 1.0.774+ (well below our SDK floor); a no-op if the
                      // interface is absent on an ancient runtime.
                      wil::com_ptr<ICoreWebView2Controller2> controller2;
                      if (SUCCEEDED(controller_->QueryInterface(
                              IID_PPV_ARGS(&controller2)))) {
                        COREWEBVIEW2_COLOR transparent = {0, 0, 0, 0};
                        controller2->put_DefaultBackgroundColor(transparent);
                      }
                      RECT rc;
                      GetClientRect(hwnd_, &rc);
                      controller_->put_Bounds(rc);
                      ConfigureWebView();

                      wil::com_ptr<ICoreWebView2_3> wv3;
                      if (webview_ &&
                          SUCCEEDED(webview_->QueryInterface(
                              IID_PPV_ARGS(&wv3))) &&
                          !popup_assets_dir_.empty()) {
                        wv3->SetVirtualHostNameToFolderMapping(
                            L"hibiki.popup", popup_assets_dir_.c_str(),
                            COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW);
                      }
                      if (webview_) {
                        webview_->Navigate(L"https://hibiki.popup/global_lookup_host.html");
                      }
                      // webview_ready_ is set in NavigationCompleted (popup.js
                      // must be loaded before renderPopup() exists).
                      return S_OK;
                    })
                    .Get());
            return S_OK;
          })
          .Get());
}

void GlobalLookupWindow::ConfigureWebView() {
  if (!webview_) {
    return;
  }

  // Inject the bridge adapter at document start so popup.js's
  // window.flutter_inappwebview.callHandler maps to chrome.webview.postMessage.
  std::wstring adapter = LoadAdapterScript();
  if (!adapter.empty()) {
    webview_->AddScriptToExecuteOnDocumentCreated(adapter.c_str(), nullptr);
  }

  // TODO-867 P3c — inject the nested-stack host AFTER the adapter (host.js does
  // not depend on the adapter, but keeping adapter-first is the stable order).
  // AddScriptToExecuteOnDocumentCreated runs on EVERY frame incl. child iframes;
  // host.js bails on sub-frames via its `window.top !== window.self` guard so it
  // only installs on the top-level host document.
  std::wstring host = LoadHostScript();
  if (!host.empty()) {
    webview_->AddScriptToExecuteOnDocumentCreated(host.c_str(), nullptr);
  }

  // Render only after popup.html (and popup.js) finished loading, otherwise
  // window.renderPopup() does not exist yet.
  webview_->add_NavigationCompleted(
      Callback<ICoreWebView2NavigationCompletedEventHandler>(
          [this](ICoreWebView2*,
                 ICoreWebView2NavigationCompletedEventArgs*) -> HRESULT {
            webview_ready_ = true;
            if (!pending_json_.empty()) {
              std::string json = pending_json_;
              pending_json_.clear();
              RenderJson(json);
            }
            return S_OK;
          })
          .Get(),
      nullptr);

  // Receive JS postMessage (callHandler bridge + dismiss/audio).
  webview_->add_WebMessageReceived(
      Callback<ICoreWebView2WebMessageReceivedEventHandler>(
          [this](ICoreWebView2*,
                 ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
            wil::unique_cotaskmem_string json;
            if (SUCCEEDED(args->get_WebMessageAsJson(&json))) {
              std::string body = WideToUtf8(json.get());
              if (message_cb_) {
                message_cb_(body);
              }
              // Resolve the callHandler promise so popup.js await-points never
              // hang. Most handlers are read-only here and get an immediate
              // null. The AUDIO handlers, however, need a real reply from the
              // main Dart engine (audio URL / play result), so they are
              // DEFERRED: native does not resolve them; Dart computes the reply
              // and calls back ResolveBridge(id, json). The id is the integer
              // after "__bridgeId":.
              const bool deferred =
                  body.find("\"resolveWordAudio\"") != std::string::npos ||
                  body.find("\"queryLocalAudio\"") != std::string::npos ||
                  body.find("\"playWordAudio\"") != std::string::npos;
              const std::string key = "\"__bridgeId\":";
              size_t pos = body.find(key);
              if (!deferred && pos != std::string::npos) {
                pos += key.size();
                size_t end = pos;
                while (end < body.size() && body[end] >= '0' &&
                       body[end] <= '9') {
                  ++end;
                }
                if (end > pos && webview_) {
                  std::string id = body.substr(pos, end - pos);
                  std::wstring script = L"window.__hibikiBridgeResolve && "
                                        L"window.__hibikiBridgeResolve(" +
                                        Utf8ToWide(id) + L", null);";
                  webview_->ExecuteScript(script.c_str(), nullptr);
                }
              }
            }
            return S_OK;
          })
          .Get(),
      nullptr);

  // Intercept image:// and dictmedia:// and route the bytes from the main
  // Dart engine (the in-app InAppWebView handles both schemes).
  webview_->AddWebResourceRequestedFilter(
      L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
  webview_->add_WebResourceRequested(
      Callback<ICoreWebView2WebResourceRequestedEventHandler>(
          [this](ICoreWebView2*,
                 ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT {
            wil::com_ptr<ICoreWebView2WebResourceRequest> req;
            args->get_Request(&req);
            wil::unique_cotaskmem_string uri;
            req->get_Uri(&uri);
            std::string url = WideToUtf8(uri.get());
            // Route BOTH custom schemes through the main Dart engine, matching
            // the in-app InAppWebView (image:// gaiji/img bytes + dictmedia://
            // dictionary stylesheets). Anything else is a popup asset served by
            // the virtual host.
            const bool is_image = url.rfind("image://", 0) == 0;
            const bool is_dictmedia = url.rfind("dictmedia://", 0) == 0;
            if (!is_image && !is_dictmedia) {
              return S_OK;  // Let the virtual host serve popup assets.
            }
            if (!media_resolver_) {
              return S_OK;
            }
            wil::com_ptr<ICoreWebView2Deferral> deferral;
            args->GetDeferral(&deferral);
            // Keep args + deferral alive until Dart replies. Both this callback
            // and the resolver's reply run on the platform thread, so building
            // the response here is safe.
            wil::com_ptr<ICoreWebView2WebResourceRequestedEventArgs> args_keep =
                args;
            // Content-Type is derived from the URL (scheme/extension) so the
            // overlay serves the SAME type the in-app InAppWebView does — CSS
            // for dictmedia://, image/* by extension for image:// (a hardcoded
            // image/png would make WebView2 reject the dictionary stylesheet).
            std::wstring content_type = MediaContentTypeHeader(url);
            media_resolver_(
                url, [this, deferral, args_keep, content_type](
                         std::vector<uint8_t> bytes) {
                  wil::com_ptr<IStream> stream = SHCreateMemStream(
                      bytes.empty() ? nullptr : bytes.data(),
                      static_cast<UINT>(bytes.size()));
                  wil::com_ptr<ICoreWebView2WebResourceResponse> resp;
                  env_->CreateWebResourceResponse(
                      stream.get(), bytes.empty() ? 404 : 200,
                      bytes.empty() ? L"Not Found" : L"OK",
                      content_type.c_str(), &resp);
                  args_keep->put_Response(resp.get());
                  deferral->Complete();
                });
            return S_OK;
          })
          .Get(),
      nullptr);
}

void GlobalLookupWindow::RenderJson(const std::string& full_script) {
  // full_script is the complete JS built in Dart (settings + lookupEntries +
  // renderPopup), mirroring dictionary_popup_webview._pushResults. Cached until
  // the page finishes loading (renderPopup must exist).
  if (!webview_ready_ || !webview_) {
    pending_json_ = full_script;
    return;
  }
  webview_->ExecuteScript(Utf8ToWide(full_script).c_str(), nullptr);
}

void GlobalLookupWindow::ResolveBridge(int64_t id,
                                       const std::string& json_value) {
  if (!webview_) {
    return;
  }
  // json_value is a ready JS string literal (Dart double-encodes it) — the
  // overlay adapter does JSON.parse on it. Splice it in verbatim.
  std::wstring script = L"window.__hibikiBridgeResolve && "
                        L"window.__hibikiBridgeResolve(" +
                        std::to_wstring(id) + L", " + Utf8ToWide(json_value) +
                        L");";
  webview_->ExecuteScript(script.c_str(), nullptr);
}

LRESULT CALLBACK GlobalLookupWindow::WndProc(HWND hwnd, UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    auto* self = static_cast<GlobalLookupWindow*>(create->lpCreateParams);
    self->hwnd_ = hwnd;
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto* self = reinterpret_cast<GlobalLookupWindow*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self != nullptr) {
    return self->HandleMessage(message, wparam, lparam);
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

// TODO-867 P2: apply a rounded-rectangle window region so the opaque WebView2
// lookup window has rounded corners that match popup.css's 10px card radius.
// Called on every WM_SIZE. The corner diameter (2 * radius) is scaled by the
// window DPI so the rounding stays a constant ~10 logical px across monitors.
void GlobalLookupWindow::ApplyRoundedRegion() {
  if (hwnd_ == nullptr) {
    return;
  }
  RECT rc;
  GetClientRect(hwnd_, &rc);
  const int width = rc.right - rc.left;
  const int height = rc.bottom - rc.top;
  if (width <= 0 || height <= 0) {
    return;
  }
  UINT dpi = GetDpiForWindow(hwnd_);
  if (dpi == 0) {
    dpi = 96;
  }
  // 10 logical px radius -> diameter = 20 logical px, scaled to physical px.
  const int diameter = MulDiv(20, static_cast<int>(dpi), 96);
  HRGN region =
      CreateRoundRectRgn(0, 0, width + 1, height + 1, diameter, diameter);
  if (region != nullptr) {
    // SetWindowRgn takes ownership of the region on success; the system frees it.
    SetWindowRgn(hwnd_, region, TRUE);
  }
}

void GlobalLookupWindow::ForwardGlobalClickToHost(int screen_x, int screen_y) {
  if (webview_ == nullptr || hwnd_ == nullptr) {
    return;
  }
  RECT rc;
  GetWindowRect(hwnd_, &rc);
  // Screen physical px -> window-local physical px -> host CSS px (÷ dpr). This
  // is the documented "WH_MOUSE_LL physical -> web CSS px" boundary; the host
  // layout math stays in CSS px throughout. Window DPI (96-based) gives dpr.
  UINT dpi = GetDpiForWindow(hwnd_);
  if (dpi == 0) {
    dpi = 96;
  }
  const double dpr = static_cast<double>(dpi) / 96.0;
  const double local_x = static_cast<double>(screen_x - rc.left) / dpr;
  const double local_y = static_cast<double>(screen_y - rc.top) / dpr;
  std::wstring script =
      L"window.__globalLookupHost && "
      L"window.__globalLookupHost.handleGlobalClick(" +
      std::to_wstring(local_x) + L", " + std::to_wstring(local_y) + L");";
  webview_->ExecuteScript(script.c_str(), nullptr);
}

LRESULT GlobalLookupWindow::HandleMessage(UINT message, WPARAM wparam,
                                          LPARAM lparam) {
  switch (message) {
    case WM_SIZE:
      if (controller_) {
        RECT rc;
        GetClientRect(hwnd_, &rc);
        controller_->put_Bounds(rc);
      }
      // TODO-867 P2: round the actual window corners to match popup.css's hoshi
      // card radius. The window is opaque (no WS_EX_LAYERED — it conflicts with
      // WebView2's composition surface, see ShowAt), so true rounded corners must
      // come from a window region, not CSS. A real drop-shadow is not achievable
      // on a non-layered topmost window — that is a platform limitation; the CSS
      // border supplies the card frame, this region supplies the rounded corners.
      ApplyRoundedRegion();
      return 0;
    default:
      return DefWindowProc(hwnd_, message, wparam, lparam);
  }
}
