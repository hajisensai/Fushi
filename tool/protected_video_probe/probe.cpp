// 受保护视频「垫在 Flutter 下面」的独立探针（不依赖 Flutter / 引擎）。
//
// 复刻目标形态的窗口结构：
//   top（顶层窗口，相当于 runner 的 Win32Window）
//    └ view（子窗口，相当于 FLUTTERVIEW）：D3D11 + DirectComposition topmost 目标、
//      预乘 alpha 交换链 —— 与 ANGLE 的 EGL_DIRECT_COMPOSITION_ANGLE 路径同一套
//      （NativeWindow11Win32::initialize → CreateTargetForHwnd(hwnd, TRUE)）
//       └ container（子窗口）→ WebView2 窗口宿主（CreateCoreWebView2Controller，
//         硬件 PlayReady 只在这条路径可用，WebView2 #4935 / 计划 §5.2）
//
// view 画模拟的播放器 UI（上下半透明栏、半透明字幕条、移动方块），其余全透明：
// DComp topmost 内容盖在 view 的子窗口之上，透明处露出下面的 WebView。
//
// 用法：probe.exe key=value ...
//   mode=netflix|clear   netflix：打开 url（默认 Edg UA → PlayReady）；clear：本地 canvas 动画
//   url=...              netflix 模式的地址
//   profile=...          WebView2 user data folder（Netflix 要求在 %LOCALAPPDATA% 下）
//   input=none|disabled|layered   container 的输入穿透策略
//   x= y= w= h=          顶层窗口位置尺寸（物理 px）
//   seconds=N            运行时长
//   bottom=1             窗口放在 z 序最底（不盖用户窗口）；0 = 普通
//   shot=N               第 N 秒把窗口临时提到最上、截屏到 shot.png 再放回去（0 = 不截）
//   log=path             日志文件（同时写 stdout）
#include <windows.h>

#include <d3d11_1.h>
#include <dcomp.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include <wincodec.h>
#include <wrl.h>

#include <share.h>

#include <cmath>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#include "WebView2.h"
#include "WebView2EnvironmentOptions.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

std::map<std::wstring, std::wstring> g_args;
FILE* g_log = nullptr;

std::wstring Arg(const wchar_t* key, const wchar_t* fallback) {
  auto it = g_args.find(key);
  return it == g_args.end() ? fallback : it->second;
}
int ArgInt(const wchar_t* key, int fallback) {
  auto it = g_args.find(key);
  return it == g_args.end() ? fallback : _wtoi(it->second.c_str());
}

std::string Utf8(const std::wstring& w) {
  if (w.empty()) return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                              nullptr, 0, nullptr, nullptr);
  std::string s(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), s.data(),
                      n, nullptr, nullptr);
  return s;
}

void Log(const std::string& line) {
  const double t = GetTickCount64() / 1000.0;
  std::printf("[%.1f] %s\n", t, line.c_str());
  std::fflush(stdout);
  if (g_log != nullptr) {
    std::fprintf(g_log, "[%.1f] %s\n", t, line.c_str());
    std::fflush(g_log);
  }
}

void LogHr(const char* step, HRESULT hr) {
  char buf[160];
  std::snprintf(buf, sizeof(buf), "%s hr=0x%08lX", step,
                static_cast<unsigned long>(hr));
  Log(buf);
}

HWND g_top = nullptr;
HWND g_view = nullptr;
HWND g_container = nullptr;
ULONGLONG g_start = 0;
bool g_login = false;  // 登录模式：不画叠层、窗口可激活

ComPtr<ID3D11Device> g_d3d;
ComPtr<ID3D11DeviceContext1> g_ctx;
ComPtr<IDXGISwapChain1> g_swap;
ComPtr<IDCompositionDevice> g_dcomp;
ComPtr<IDCompositionTarget> g_target;
ComPtr<IDCompositionVisual> g_visual;
UINT g_w = 0;
UINT g_h = 0;

ComPtr<ICoreWebView2Environment> g_env;
ComPtr<ICoreWebView2Controller> g_controller;
ComPtr<ICoreWebView2> g_webview;

bool InitComposition() {
  RECT rc;
  GetClientRect(g_view, &rc);
  g_w = static_cast<UINT>(rc.right - rc.left);
  g_h = static_cast<UINT>(rc.bottom - rc.top);
  ComPtr<ID3D11DeviceContext> ctx;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                                 D3D11_SDK_VERSION, &g_d3d, nullptr, &ctx);
  if (FAILED(hr)) return LogHr("D3D11CreateDevice", hr), false;
  ctx.As(&g_ctx);
  ComPtr<IDXGIDevice> dxgi_device;
  g_d3d.As(&dxgi_device);
  ComPtr<IDXGIAdapter> adapter;
  dxgi_device->GetAdapter(&adapter);
  ComPtr<IDXGIFactory2> factory;
  adapter->GetParent(IID_PPV_ARGS(&factory));
  // 与 ANGLE 的 DComp 交换链同参：flip sequential、预乘 alpha（hasAlpha 时）。
  DXGI_SWAP_CHAIN_DESC1 desc = {};
  desc.Width = g_w;
  desc.Height = g_h;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.BufferCount = 2;
  desc.Scaling = DXGI_SCALING_STRETCH;
  desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
  hr = factory->CreateSwapChainForComposition(g_d3d.Get(), &desc, nullptr, &g_swap);
  if (FAILED(hr)) return LogHr("CreateSwapChainForComposition", hr), false;
  hr = DCompositionCreateDevice(dxgi_device.Get(), IID_PPV_ARGS(&g_dcomp));
  if (FAILED(hr)) return LogHr("DCompositionCreateDevice", hr), false;
  hr = g_dcomp->CreateTargetForHwnd(g_view, TRUE, &g_target);
  if (FAILED(hr)) return LogHr("CreateTargetForHwnd", hr), false;
  g_dcomp->CreateVisual(&g_visual);
  g_visual->SetContent(g_swap.Get());
  g_target->SetRoot(g_visual.Get());
  g_dcomp->Commit();
  Log("composition ready " + std::to_string(g_w) + "x" + std::to_string(g_h));
  return true;
}

void Fill(ID3D11RenderTargetView* rtv, LONG l, LONG t, LONG r, LONG b,
          float red, float green, float blue, float a) {
  // 预乘：颜色分量乘 alpha。ClearView 的 rect 只裁本次填充。
  const FLOAT c[4] = {red * a, green * a, blue * a, a};
  D3D11_RECT rect = {l, t, r, b};
  g_ctx->ClearView(rtv, c, &rect, 1);
}

void Render() {
  if (!g_swap) return;
  ComPtr<ID3D11Texture2D> back;
  g_swap->GetBuffer(0, IID_PPV_ARGS(&back));
  ComPtr<ID3D11RenderTargetView> rtv;
  g_d3d->CreateRenderTargetView(back.Get(), nullptr, &rtv);
  const LONG w = static_cast<LONG>(g_w);
  const LONG h = static_cast<LONG>(g_h);
  const FLOAT clear[4] = {0, 0, 0, 0};
  g_ctx->ClearRenderTargetView(rtv.Get(), clear);
  if (g_login) {
    g_swap->Present(1, 0);
    return;
  }
  const LONG bar = h / 12;
  Fill(rtv.Get(), 0, 0, w, bar, 0.1f, 0.1f, 0.12f, 0.65f);          // 顶栏
  Fill(rtv.Get(), 0, h - bar, w, h, 0.1f, 0.1f, 0.12f, 0.65f);      // 底栏
  Fill(rtv.Get(), w / 20, h - bar + bar / 3, w - w / 20, h - bar + bar / 3 + 6,
       1.0f, 0.3f, 0.3f, 1.0f);                                      // 进度条
  Fill(rtv.Get(), w / 4, h - bar * 3, w * 3 / 4, h - bar * 2, 1.0f, 1.0f, 1.0f,
       0.45f);                                                       // 字幕条（半透明白）
  const double s = (GetTickCount64() - g_start) / 1000.0;
  const LONG sq = bar / 2;
  const LONG x = static_cast<LONG>(std::fmod(s * 300.0, static_cast<double>(w - sq)));
  Fill(rtv.Get(), x, bar / 4, x + sq, bar / 4 + sq, 0.2f, 0.9f, 0.3f, 1.0f);  // 动方块
  g_swap->Present(1, 0);
}

const wchar_t kProbeScript[] = LR"JS(
(() => {
  const P = window.__probe = { ks: [] };
  const orig = navigator.requestMediaKeySystemAccess &&
      navigator.requestMediaKeySystemAccess.bind(navigator);
  if (!orig) return;
  navigator.requestMediaKeySystemAccess = function (k, cfgs) {
    return orig(k, cfgs).then((a) => {
      const c = a.getConfiguration();
      P.ks.push({ ok: true, k, rob: (c.videoCapabilities || []).map(
          (v) => (v.robustness || '') + '|' + v.contentType) });
      return a;
    }, (e) => { P.ks.push({ ok: false, k, e: String(e) }); throw e; });
  };
})();
)JS";

const wchar_t kPollScript[] = LR"JS(
(() => {
  // 落在标题页（/watch 被重定向或点进了标题）时跳到第一个正片链接，只跳一次。
  if (/\/title\//.test(location.pathname) && !window.__probeNav) {
    const a = document.querySelector('a[href*="/watch/"]');
    if (a) { window.__probeNav = 1; location.href = a.href; }
  }
  const vs = [...document.querySelectorAll('video')];
  const v = vs.sort((a, b) => b.videoWidth - a.videoWidth)[0];
  if (v && !v.muted) v.muted = true;
  const q = v && v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : null;
  const text = document.body ? document.body.innerText : '';
  const m = text.match(/\b[A-Z]\d{4}(?:-\d+){1,2}(?:-[0-9A-F]+)?\b/);
  return JSON.stringify({
    href: location.href.slice(0, 80), title: document.title,
    video: !!v, w: v ? v.videoWidth : 0, h: v ? v.videoHeight : 0,
    t: v ? Math.round(v.currentTime * 10) / 10 : 0, paused: v ? v.paused : null,
    rs: v ? v.readyState : 0, dec: q ? q.totalVideoFrames : 0,
    drop: q ? q.droppedVideoFrames : 0, ks: (window.__probe || {}).ks || [],
    err: m ? m[0] : null, dpr: devicePixelRatio,
  });
})()
)JS";

const wchar_t kClearPage[] = LR"HTML(<!doctype html><html><body style="margin:0;background:#000">
<canvas id=c style="width:100vw;height:100vh;display:block"></canvas><script>
const c=document.getElementById('c'),g=c.getContext('2d');
function f(t){c.width=innerWidth;c.height=innerHeight;
for(let i=0;i<8;i++){g.fillStyle=`hsl(${i*45},90%,50%)`;g.fillRect(i*c.width/8,0,c.width/8,c.height);}
g.fillStyle='#fff';g.fillRect((t/4)%c.width,c.height/2-40,80,80);requestAnimationFrame(f);}
requestAnimationFrame(f);</script></body></html>)HTML";

void ResizeWebView() {
  if (!g_controller) return;
  RECT rc;
  GetClientRect(g_container, &rc);
  g_controller->put_Bounds(rc);
}

void StartWebView() {
  auto options = Microsoft::WRL::Make<CoreWebView2EnvironmentOptions>();
  // 与 Fushi 4K 环境同参（不带 --disable-direct-composition），加上「被遮挡也照常
  // 解码」：探针窗口压在 z 序最底，否则 Chromium 的遮挡计算会停视频轨。
  options->put_AdditionalBrowserArguments(
      L"--autoplay-policy=no-user-gesture-required "
      L"--disable-features=CalculateNativeWinOcclusion "
      L"--disable-backgrounding-occluded-windows --disable-renderer-backgrounding");
  const std::wstring profile = Arg(L"profile", L"");
  HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, profile.empty() ? nullptr : profile.c_str(), options.Get(),
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
            if (FAILED(result)) return LogHr("environment", result), S_OK;
            g_env = env;
            ComPtr<ICoreWebView2Environment> e(env);
            LPWSTR ver = nullptr;
            e->get_BrowserVersionString(&ver);
            Log("webview2 runtime " + Utf8(ver ? ver : L"?"));
            CoTaskMemFree(ver);
            return env->CreateCoreWebView2Controller(
                g_container,
                Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [](HRESULT r, ICoreWebView2Controller* controller) -> HRESULT {
                      if (FAILED(r)) return LogHr("controller", r), S_OK;
                      g_controller = controller;
                      g_controller->get_CoreWebView2(&g_webview);
                      ResizeWebView();
                      g_webview->AddScriptToExecuteOnDocumentCreated(kProbeScript,
                                                                     nullptr);
                      if (Arg(L"mode", L"netflix") == L"clear") {
                        g_webview->NavigateToString(kClearPage);
                      } else {
                        g_webview->Navigate(
                            Arg(L"url", L"https://www.netflix.com/watch/81236554")
                                .c_str());
                      }
                      Log("navigate issued");
                      return S_OK;
                    })
                    .Get());
          })
          .Get());
  if (FAILED(hr)) LogHr("CreateCoreWebView2EnvironmentWithOptions", hr);
}

std::string ClassOf(HWND hwnd) {
  wchar_t name[128] = L"";
  GetClassNameW(hwnd, name, 128);
  return Utf8(name);
}

void ProbeHitTest() {
  RECT rc;
  GetWindowRect(g_container, &rc);
  POINT p = {(rc.left + rc.right) / 2, (rc.top + rc.bottom) / 2};
  HWND hit = WindowFromPoint(p);
  const char* who = hit == g_view ? "view" : hit == g_top ? "top"
                    : hit == g_container ? "container"
                    : GetAncestor(hit, GA_ROOT) == g_top ? "webview-child" : "foreign";
  Log(std::string("hit-test center (") + std::to_string(p.x) + "," + std::to_string(p.y) +
      ") -> " + who + " (" + ClassOf(hit) + ")");
}

void Poll() {
  if (!g_webview) return;
  g_webview->ExecuteScript(
      kPollScript, Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
                       [](HRESULT hr, LPCWSTR json) -> HRESULT {
                         if (FAILED(hr)) return LogHr("poll", hr), S_OK;
                         Log("poll " + Utf8(json ? json : L"null"));
                         return S_OK;
                       })
                       .Get());
}

bool SavePng(const wchar_t* path, HBITMAP bmp, int w, int h) {
  ComPtr<IWICImagingFactory> wic;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&wic))))
    return false;
  ComPtr<IWICBitmap> src;
  if (FAILED(wic->CreateBitmapFromHBITMAP(bmp, nullptr, WICBitmapIgnoreAlpha, &src)))
    return false;
  ComPtr<IWICStream> stream;
  wic->CreateStream(&stream);
  if (FAILED(stream->InitializeFromFilename(path, GENERIC_WRITE))) return false;
  ComPtr<IWICBitmapEncoder> enc;
  wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &enc);
  enc->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  ComPtr<IWICBitmapFrameEncode> frame;
  enc->CreateNewFrame(&frame, nullptr);
  frame->Initialize(nullptr);
  frame->SetSize(w, h);
  WICPixelFormatGUID fmt = GUID_WICPixelFormat24bppBGR;
  frame->SetPixelFormat(&fmt);
  frame->WriteSource(src.Get(), nullptr);
  frame->Commit();
  return SUCCEEDED(enc->Commit());
}

void Screenshot() {
  // 屏幕 DC 截的是 DWM 合成后的桌面：DComp 层与子窗口都在里面（受保护视频是黑的）。
  SetWindowPos(g_top, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  for (int i = 0; i < 6; ++i) {
    Render();
    DwmFlush();
  }
  RECT rc;
  GetWindowRect(g_view, &rc);
  const int w = rc.right - rc.left;
  const int h = rc.bottom - rc.top;
  HDC screen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen);
  HBITMAP bmp = CreateCompatibleBitmap(screen, w, h);
  HGDIOBJ old = SelectObject(mem, bmp);
  BitBlt(mem, 0, 0, w, h, screen, rc.left, rc.top, SRCCOPY | CAPTUREBLT);
  SelectObject(mem, old);
  const std::wstring path = Arg(L"shotpath", L"shot.png");
  Log(std::string("screenshot ") + (SavePng(path.c_str(), bmp, w, h) ? "ok " : "FAILED ") +
      Utf8(path));
  DeleteObject(bmp);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);
  if (!ArgInt(L"topmost", 0)) {
    SetWindowPos(g_top, ArgInt(L"bottom", 1) ? HWND_BOTTOM : HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
}

LRESULT CALLBACK TopProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_TIMER:
      if (wp == 1) {
        Render();
      } else if (wp == 2) {
        const ULONGLONG elapsed = (GetTickCount64() - g_start) / 1000;
        Poll();
        ProbeHitTest();
        static bool shot_done = false;
        const int shot = ArgInt(L"shot", 0);
        if (shot > 0 && !shot_done && elapsed >= static_cast<ULONGLONG>(shot)) {
          shot_done = true;
          Screenshot();
        }
        if (elapsed >= static_cast<ULONGLONG>(ArgInt(L"seconds", 60))) {
          DestroyWindow(hwnd);
        }
      }
      return 0;
    case WM_MOUSEACTIVATE:
      if (g_login) break;
      return MA_NOACTIVATE;
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT CALLBACK ViewProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_LBUTTONDOWN) {
    Log("view got WM_LBUTTONDOWN");
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  for (int i = 1; i < argc; ++i) {
    std::wstring a = argv[i];
    const size_t eq = a.find(L'=');
    if (eq != std::wstring::npos) g_args[a.substr(0, eq)] = a.substr(eq + 1);
  }
  const std::wstring log_path = Arg(L"log", L"");
  if (!log_path.empty()) g_log = _wfsopen(log_path.c_str(), L"w", _SH_DENYNO);
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  g_start = GetTickCount64();

  HINSTANCE inst = GetModuleHandleW(nullptr);
  WNDCLASSW top_class = {};
  top_class.lpfnWndProc = TopProc;
  top_class.hInstance = inst;
  top_class.lpszClassName = L"ProbeTop";
  top_class.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  RegisterClassW(&top_class);
  WNDCLASSW view_class = {};
  view_class.lpfnWndProc = ViewProc;
  view_class.hInstance = inst;
  view_class.lpszClassName = L"ProbeView";
  RegisterClassW(&view_class);
  WNDCLASSW container_class = {};
  container_class.lpfnWndProc = DefWindowProcW;
  container_class.hInstance = inst;
  container_class.lpszClassName = L"ProbeContainer";
  RegisterClassW(&container_class);

  const int x = ArgInt(L"x", 0);
  const int y = ArgInt(L"y", 0);
  const int w = ArgInt(L"w", 1280);
  const int h = ArgInt(L"h", 720);
  // login=1：普通可激活的带框窗口，WebView 直接收输入，给用户登录用。
  // activate=1：无框全屏探针，但抢到前台（用户允许时），保证真的在最上面。
  const bool login = ArgInt(L"login", 0) != 0;
  const bool activate = login || ArgInt(L"activate", 0) != 0;
  g_login = login;
  g_top = CreateWindowExW(activate ? 0 : WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, L"ProbeTop",
                          login ? L"Fushi probe - log in to Netflix, then close this window"
                                : L"protected video probe",
                          login ? WS_OVERLAPPEDWINDOW : WS_POPUP, x, y, w, h, nullptr,
                          nullptr, inst, nullptr);
  if (login) {
    RECT rc;
    GetClientRect(g_top, &rc);
    g_args[L"seconds"] = Arg(L"seconds", L"1800");
    g_args[L"input"] = L"none";
    // view / container 跟随客户区，其余同探针。
    g_args[L"_cw"] = std::to_wstring(rc.right);
    g_args[L"_ch"] = std::to_wstring(rc.bottom);
  }
  const int cw = ArgInt(L"_cw", w);
  const int ch = ArgInt(L"_ch", h);
  g_view = CreateWindowExW(0, L"ProbeView", L"", WS_CHILD | WS_VISIBLE, 0, 0, cw, ch,
                           g_top, nullptr, inst, nullptr);
  const std::wstring input = Arg(L"input", L"none");
  DWORD container_ex = 0;
  if (input == L"layered") container_ex = WS_EX_LAYERED | WS_EX_TRANSPARENT;
  g_container = CreateWindowExW(container_ex, L"ProbeContainer", L"",
                                WS_CHILD | WS_VISIBLE, 0, 0, cw, ch, g_view, nullptr,
                                inst, nullptr);
  if (input == L"layered") {
    SetLayeredWindowAttributes(g_container, 0, 255, LWA_ALPHA);
  } else if (input == L"disabled") {
    EnableWindow(g_container, FALSE);
  }
  Log("input strategy " + Utf8(input));

  // 父进程以 STARTF_USESHOWWINDOW 起本进程时第一次 ShowWindow 用的是它给的值。
  ShowWindow(g_top, SW_SHOWNOACTIVATE);
  ShowWindow(g_top, SW_SHOWNOACTIVATE);
  if (g_container == nullptr) {
    Log("container creation failed err=" + std::to_string(GetLastError()));
    return 3;
  }
  if (activate) {
    // 前台锁：借当前前台线程的输入状态把本窗口切到前台（仅在用户允许时用）。
    const HWND fg = GetForegroundWindow();
    const DWORD fg_thread = GetWindowThreadProcessId(fg, nullptr);
    const DWORD me = GetCurrentThreadId();
    if (fg_thread != 0 && fg_thread != me) AttachThreadInput(fg_thread, me, TRUE);
    BringWindowToTop(g_top);
    const BOOL ok = SetForegroundWindow(g_top);
    if (fg_thread != 0 && fg_thread != me) AttachThreadInput(fg_thread, me, FALSE);
    Log("foreground ok=" + std::to_string(ok) +
        " is_fg=" + std::to_string(GetForegroundWindow() == g_top));
  }
  if (ArgInt(L"topmost", 0)) {
    const BOOL ok = SetWindowPos(g_top, HWND_TOPMOST, 0, 0, 0, 0,
                                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    Log("set topmost ok=" + std::to_string(ok) + " err=" + std::to_string(GetLastError()) +
        " exstyle=" + std::to_string(GetWindowLongW(g_top, GWL_EXSTYLE)));
  } else if (ArgInt(L"bottom", 1)) {
    SetWindowPos(g_top, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
  {
    RECT wr;
    GetWindowRect(g_top, &wr);
    DWORD cloaked = 0;
    DwmGetWindowAttribute(g_top, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
    Log("cloaked " + std::to_string(cloaked));
    Log("screen " + std::to_string(GetSystemMetrics(SM_CXSCREEN)) + "x" +
        std::to_string(GetSystemMetrics(SM_CYSCREEN)) + " dpi " +
        std::to_string(GetDpiForWindow(g_top)) + " top rect " + std::to_string(wr.left) +
        "," + std::to_string(wr.top) + " " + std::to_string(wr.right - wr.left) + "x" +
        std::to_string(wr.bottom - wr.top) + " visible " +
        std::to_string(IsWindowVisible(g_top)));
  }
  if (!InitComposition()) return 2;
  StartWebView();
  SetTimer(g_top, 1, 16, nullptr);
  SetTimer(g_top, 2, 2000, nullptr);

  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  if (g_controller) g_controller->Close();
  Log("exit");
  if (g_log != nullptr) std::fclose(g_log);
  return 0;
}
