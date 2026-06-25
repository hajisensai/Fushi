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
      if (!PtInRect(&rc, info->pt)) {
        self->Hide();  // Click outside the card -> dismiss.
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

bool GlobalLookupWindow::ShowAt(int x, int y, int width, int height,
                                HWND owner) {
  EnsureWindowClass();
  if (hwnd_ == nullptr) {
    // No WS_EX_LAYERED: WebView2 brings its own composition surface and does not
    // coexist with a layered window. WS_EX_NOACTIVATE keeps the foreground app's
    // keyboard focus intact when the card appears (design §5 guarantee 3).
    hwnd_ = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kClassName,
        L"Hibiki Lookup", WS_POPUP, x, y, width, height, owner, nullptr,
        GetModuleHandle(nullptr), this);
    if (hwnd_ == nullptr) {
      return false;
    }
    EnsureWebView();
  } else {
    SetWindowPos(hwnd_, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
  }
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  visible_ = true;
  // Arm the click-outside dismiss (skip our own process so interacting with the
  // card or main window does not close it).
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
  return true;
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

void GlobalLookupWindow::EnsureWebView() {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  auto options = Make<CoreWebView2EnvironmentOptions>();
  // Register image:// as a custom scheme so WebResourceRequested fires for it
  // (non file/http(s) schemes are otherwise ignored). Mirrors the fork's
  // webview_environment.cpp:69-76.
  wil::com_ptr<ICoreWebView2EnvironmentOptions4> options4;
  if (SUCCEEDED(options->QueryInterface(IID_PPV_ARGS(&options4)))) {
    auto reg = Make<CoreWebView2CustomSchemeRegistration>(L"image");
    reg->put_TreatAsSecure(TRUE);
    reg->put_HasAuthorityComponent(TRUE);
    ICoreWebView2CustomSchemeRegistration* regs[] = {reg.Get()};
    options4->SetCustomSchemeRegistrations(1, regs);
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
                        webview_->Navigate(L"https://hibiki.popup/popup.html");
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
              // Resolve the callHandler promise so popup.js await-points (mine /
              // duplicateCheck / playWordAudio) never hang. Read-only MVP: null
              // reply. The id is the integer after "__bridgeId":.
              const std::string key = "\"__bridgeId\":";
              size_t pos = body.find(key);
              if (pos != std::string::npos) {
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

  // Intercept image:// and route the bytes from the main Dart engine.
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
            if (url.rfind("image://", 0) != 0) {
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
            media_resolver_(
                url, [this, deferral, args_keep](std::vector<uint8_t> bytes) {
                  wil::com_ptr<IStream> stream = SHCreateMemStream(
                      bytes.empty() ? nullptr : bytes.data(),
                      static_cast<UINT>(bytes.size()));
                  wil::com_ptr<ICoreWebView2WebResourceResponse> resp;
                  env_->CreateWebResourceResponse(
                      stream.get(), bytes.empty() ? 404 : 200,
                      bytes.empty() ? L"Not Found" : L"OK",
                      L"Content-Type: image/png", &resp);
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

LRESULT GlobalLookupWindow::HandleMessage(UINT message, WPARAM wparam,
                                          LPARAM lparam) {
  switch (message) {
    case WM_SIZE:
      if (controller_) {
        RECT rc;
        GetClientRect(hwnd_, &rc);
        controller_->put_Bounds(rc);
      }
      return 0;
    default:
      return DefWindowProc(hwnd_, message, wparam, lparam);
  }
}
