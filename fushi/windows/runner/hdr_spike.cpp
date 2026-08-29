#include "hdr_spike.h"

#include <d3d11.h>
#include <dcomp.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstdlib>
#include <string>

namespace fushi {

namespace {

HWND g_probe = nullptr;
HWND g_flutter_child = nullptr;
int g_variant = -1;
const wchar_t kProbeClass[] = L"FushiHdrSpikeProbe";
const COLORREF kProbeGreen = RGB(0, 255, 0);
const COLORREF kColorKey = RGB(255, 0, 255);

void Log(const char* fmt, ...) {
  char path[MAX_PATH];
  const DWORD n = GetTempPathA(MAX_PATH, path);
  if (n == 0 || n >= MAX_PATH) {
    return;
  }
  std::string file = std::string(path) + "fushi_hdr_spike.log";
  FILE* f = nullptr;
  if (fopen_s(&f, file.c_str(), "a") != 0 || f == nullptr) {
    return;
  }
  va_list args;
  va_start(args, fmt);
  vfprintf(f, fmt, args);
  va_end(args);
  fputc('\n', f);
  fclose(f);
}

LRESULT CALLBACK ProbeWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_ERASEBKGND: {
      RECT rc;
      GetClientRect(hwnd, &rc);
      HBRUSH brush = CreateSolidBrush(kProbeGreen);
      FillRect(reinterpret_cast<HDC>(wp), &rc, brush);
      DeleteObject(brush);
      return 1;
    }
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

void AddExStyle(HWND hwnd, LONG_PTR bits) {
  const LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex | bits);
}

// GLFW's GLFW_TRANSPARENT_FRAMEBUFFER recipe for Win8+: blur-behind with an
// empty region makes DWM honour the window's alpha against whatever is behind
// the window (instead of the frame material that ExtendFrame shows).
void BlurBehindEmptyRegion(HWND hwnd, const char* tag) {
  HRGN region = CreateRectRgn(0, 0, -1, -1);
  DWM_BLURBEHIND bb = {};
  bb.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
  bb.fEnable = TRUE;
  bb.hRgnBlur = region;
  const HRESULT hr = DwmEnableBlurBehindWindow(hwnd, &bb);
  DeleteObject(region);
  Log("DwmEnableBlurBehindWindow(%s, empty region) hr=0x%08lx", tag, hr);
}

// Variants 10/11: a green composition swapchain hung on the main window's own
// DirectComposition target, below (10) or above (11) the child HWNDs. This is
// the in-window alternative to a second top-level window: no z-order fight
// with other apps, and PrintWindow(PW_RENDERFULLCONTENT) can capture it even
// while another fullscreen app covers the screen.
Microsoft::WRL::ComPtr<ID3D11Device> g_d3d;
Microsoft::WRL::ComPtr<ID3D11DeviceContext> g_ctx;
Microsoft::WRL::ComPtr<IDXGISwapChain1> g_swapchain;
Microsoft::WRL::ComPtr<IDCompositionDevice> g_dcomp;
Microsoft::WRL::ComPtr<IDCompositionTarget> g_target;
Microsoft::WRL::ComPtr<IDCompositionVisual> g_visual;

void StartDCompVisual(HWND main, bool topmost) {
  using Microsoft::WRL::ComPtr;
  RECT rc;
  GetClientRect(main, &rc);
  const UINT width = static_cast<UINT>(rc.right - rc.left);
  const UINT height = static_cast<UINT>(rc.bottom - rc.top);
  HRESULT hr = D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
      &g_d3d, nullptr, &g_ctx);
  Log("D3D11CreateDevice hr=0x%08lx", hr);
  if (FAILED(hr)) return;
  ComPtr<IDXGIDevice> dxgi_device;
  g_d3d.As(&dxgi_device);
  ComPtr<IDXGIFactory2> factory;
  hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
  Log("CreateDXGIFactory1 hr=0x%08lx", hr);
  DXGI_SWAP_CHAIN_DESC1 desc = {};
  desc.Width = width;
  desc.Height = height;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.BufferCount = 2;
  desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
  desc.Scaling = DXGI_SCALING_STRETCH;
  hr = factory->CreateSwapChainForComposition(g_d3d.Get(), &desc, nullptr,
                                              &g_swapchain);
  Log("CreateSwapChainForComposition %ux%u hr=0x%08lx", width, height, hr);
  if (FAILED(hr)) return;
  ComPtr<ID3D11Texture2D> back;
  g_swapchain->GetBuffer(0, IID_PPV_ARGS(&back));
  ComPtr<ID3D11RenderTargetView> rtv;
  g_d3d->CreateRenderTargetView(back.Get(), nullptr, &rtv);
  // Blue, not green: the probe window behind the main window is green, so a
  // blue hole proves the in-window DComp visual is what shows through.
  const float blue[4] = {0.0f, 0.0f, 1.0f, 1.0f};
  g_ctx->ClearRenderTargetView(rtv.Get(), blue);
  hr = g_swapchain->Present(1, 0);
  Log("Present hr=0x%08lx", hr);
  hr = DCompositionCreateDevice(dxgi_device.Get(), IID_PPV_ARGS(&g_dcomp));
  Log("DCompositionCreateDevice hr=0x%08lx", hr);
  if (FAILED(hr)) return;
  hr = g_dcomp->CreateTargetForHwnd(main, topmost ? TRUE : FALSE, &g_target);
  Log("CreateTargetForHwnd(topmost=%d) hr=0x%08lx", topmost, hr);
  if (FAILED(hr)) return;
  g_dcomp->CreateVisual(&g_visual);
  g_visual->SetContent(g_swapchain.Get());
  g_target->SetRoot(g_visual.Get());
  hr = g_dcomp->Commit();
  Log("DComp Commit hr=0x%08lx", hr);
}

}  // namespace

int HdrSpike::Variant() {
  if (g_variant >= 0) {
    return g_variant;
  }
  char buf[8] = {0};
  const DWORD n = GetEnvironmentVariableA("FUSHI_HDR_SPIKE", buf, sizeof(buf));
  g_variant = (n > 0 && n < sizeof(buf)) ? atoi(buf) : 0;
  return g_variant;
}

void HdrSpike::Start(HWND main, HWND flutter_child) {
  const int variant = Variant();
  if (variant == 0 || g_probe != nullptr) {
    return;
  }
  g_flutter_child = flutter_child;
  Log("--- spike start variant=%d main=%p child=%p", variant, main,
      flutter_child);

  WNDCLASSW wc = {};
  wc.lpfnWndProc = ProbeWndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kProbeClass;
  wc.hbrBackground = CreateSolidBrush(kProbeGreen);
  RegisterClassW(&wc);

  g_probe = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, kProbeClass,
                            L"fushi hdr spike probe", WS_POPUP, 0, 0, 10, 10,
                            nullptr, nullptr, wc.hInstance, nullptr);
  Log("probe hwnd=%p err=%lu", g_probe, GetLastError());

  switch (variant) {
    case 1:
    case 2:
    case 3: {
      const MARGINS margins = {-1, -1, -1, -1};
      const HRESULT hr = DwmExtendFrameIntoClientArea(main, &margins);
      Log("DwmExtendFrameIntoClientArea(main) hr=0x%08lx", hr);
      if (variant >= 2) {
        AddExStyle(main, WS_EX_LAYERED);
        const BOOL ok = SetLayeredWindowAttributes(main, 0, 255, LWA_ALPHA);
        Log("main WS_EX_LAYERED + LWA_ALPHA(255) ok=%d err=%lu", ok,
            GetLastError());
      }
      if (variant >= 3 && flutter_child != nullptr) {
        AddExStyle(flutter_child, WS_EX_LAYERED);
        const BOOL ok =
            SetLayeredWindowAttributes(flutter_child, 0, 255, LWA_ALPHA);
        Log("child WS_EX_LAYERED + LWA_ALPHA(255) ok=%d err=%lu", ok,
            GetLastError());
      }
      break;
    }
    case 4: {
      AddExStyle(main, WS_EX_LAYERED);
      const BOOL ok =
          SetLayeredWindowAttributes(main, kColorKey, 0, LWA_COLORKEY);
      Log("main WS_EX_LAYERED + LWA_COLORKEY(magenta) ok=%d err=%lu", ok,
          GetLastError());
      break;
    }
    case 5: {
      if (flutter_child != nullptr) {
        AddExStyle(flutter_child, WS_EX_LAYERED);
        const BOOL ok = SetLayeredWindowAttributes(flutter_child, kColorKey, 0,
                                                   LWA_COLORKEY);
        Log("child WS_EX_LAYERED + LWA_COLORKEY(magenta) ok=%d err=%lu", ok,
            GetLastError());
      }
      break;
    }
    case 6:
      BlurBehindEmptyRegion(main, "main");
      break;
    case 7: {
      const MARGINS margins = {-1, -1, -1, -1};
      const HRESULT hr = DwmExtendFrameIntoClientArea(main, &margins);
      Log("DwmExtendFrameIntoClientArea(main) hr=0x%08lx", hr);
      BlurBehindEmptyRegion(main, "main");
      break;
    }
    case 8:
      BlurBehindEmptyRegion(main, "main");
      if (flutter_child != nullptr) {
        BlurBehindEmptyRegion(flutter_child, "child");
      }
      break;
    case 9:
      // Self-check: probe goes ABOVE the main window (see Sync) so the
      // screenshot proves the probe itself paints green.
      Log("variant 9: probe topmost self-check");
      break;
    case 10:
      StartDCompVisual(main, /*topmost=*/false);
      break;
    case 11:
      StartDCompVisual(main, /*topmost=*/true);
      break;
    case 12:
      // 10 + blur-behind empty region, in case DWM needs the alpha hint.
      BlurBehindEmptyRegion(main, "main");
      StartDCompVisual(main, /*topmost=*/false);
      break;
    case 13: {
      // ExtendFrame (proven to make DWM honour the child's alpha) + DComp
      // visual below the children.
      const MARGINS margins = {-1, -1, -1, -1};
      const HRESULT hr = DwmExtendFrameIntoClientArea(main, &margins);
      Log("DwmExtendFrameIntoClientArea(main) hr=0x%08lx", hr);
      StartDCompVisual(main, /*topmost=*/false);
      break;
    }
    case 14: {
      const MARGINS margins = {-1, -1, -1, -1};
      const HRESULT hr = DwmExtendFrameIntoClientArea(main, &margins);
      Log("DwmExtendFrameIntoClientArea(main) hr=0x%08lx", hr);
      BlurBehindEmptyRegion(main, "main");
      StartDCompVisual(main, /*topmost=*/false);
      break;
    }
    case 15:
      // Main window created with WS_EX_NOREDIRECTIONBITMAP (win32_window.cpp).
      Log("variant 15: NOREDIRECTIONBITMAP ex=0x%lx",
          static_cast<long>(GetWindowLongPtrW(main, GWL_EXSTYLE)));
      StartDCompVisual(main, /*topmost=*/false);
      break;
    case 16: {
      Log("variant 16: NOREDIRECTIONBITMAP ex=0x%lx",
          static_cast<long>(GetWindowLongPtrW(main, GWL_EXSTYLE)));
      const MARGINS margins = {-1, -1, -1, -1};
      const HRESULT hr = DwmExtendFrameIntoClientArea(main, &margins);
      Log("DwmExtendFrameIntoClientArea(main) hr=0x%08lx", hr);
      StartDCompVisual(main, /*topmost=*/false);
      break;
    }
    default:
      Log("unknown variant %d: probe window only", variant);
      break;
  }
  // Frame-change the affected windows so the new ex-styles take effect.
  SetWindowPos(main, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
  // FUSHI_HDR_SPIKE_TOPMOST="x,y,w,h": park the main window there, TOPMOST,
  // from inside the process (cross-process HWND_TOPMOST was observed to be
  // dropped while the user's fullscreen browser owned the screen).
  char place[64] = {0};
  if (GetEnvironmentVariableA("FUSHI_HDR_SPIKE_TOPMOST", place,
                              sizeof(place)) > 0) {
    int x = 0, y = 0, w = 0, h = 0;
    if (sscanf_s(place, "%d,%d,%d,%d", &x, &y, &w, &h) == 4) {
      if (GetEnvironmentVariableA("FUSHI_HDR_SPIKE_POPUP", nullptr, 0) > 0) {
        // Is HWND_TOPMOST refused because of the overlapped/caption style?
        const LONG_PTR style = GetWindowLongPtrW(main, GWL_STYLE);
        SetWindowLongPtrW(main, GWL_STYLE,
                          (style & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
        SetWindowPos(main, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                         SWP_FRAMECHANGED);
        Log("main style -> WS_POPUP (was 0x%lx)", static_cast<long>(style));
      }
      // Borrow the foreground thread's input state for the duration of the
      // z-order change only (no focus/foreground change is made).
      DWORD fg_thread = 0;
      const HWND fg = GetForegroundWindow();
      if (fg != nullptr) {
        fg_thread = GetWindowThreadProcessId(fg, nullptr);
      }
      const DWORD self_thread = GetCurrentThreadId();
      const BOOL attached =
          fg_thread != 0 && fg_thread != self_thread &&
          AttachThreadInput(fg_thread, self_thread, TRUE);
      BOOL ok = SetWindowPos(main, HWND_TOPMOST, x, y, w, h,
                             SWP_NOACTIVATE | SWP_SHOWWINDOW);
      Log("main HWND_TOPMOST at (%d,%d,%d,%d) attached=%d ok=%d err=%lu "
          "topmost=%d",
          x, y, w, h, attached, ok, GetLastError(),
          (GetWindowLongPtrW(main, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0);
      if (attached) {
        AttachThreadInput(fg_thread, self_thread, FALSE);
      }
      // HWND_TOPMOST is refused for the main window (background process); the
      // probe accepts it. Ride the probe: make it topmost, then insert the
      // main window right after it (== into the topmost band).
      ok = SetWindowPos(g_probe, HWND_TOPMOST, x, y, w, h,
                        SWP_NOACTIVATE | SWP_SHOWWINDOW);
      Log("probe HWND_TOPMOST ok=%d topmost=%d", ok,
          (GetWindowLongPtrW(g_probe, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0);
      ok = SetWindowPos(main, g_probe, x, y, w, h,
                        SWP_NOACTIVATE | SWP_SHOWWINDOW);
      Log("main after probe ok=%d err=%lu topmost=%d", ok, GetLastError(),
          (GetWindowLongPtrW(main, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0);
    }
  }
  Sync(main);
}

void HdrSpike::Sync(HWND main) {
  if (g_probe == nullptr || main == nullptr) {
    return;
  }
  if (IsIconic(main) || !IsWindowVisible(main)) {
    ShowWindow(g_probe, SW_HIDE);
    return;
  }
  RECT rc;
  if (!GetClientRect(main, &rc)) {
    return;
  }
  POINT origin = {rc.left, rc.top};
  ClientToScreen(main, &origin);
  const int width = rc.right - rc.left;
  const int height = rc.bottom - rc.top;
  // hWndInsertAfter = main puts the probe immediately BELOW the main window.
  // Variant 9 puts it on top instead, to prove the probe paints at all.
  const HWND insert_after = (Variant() == 9) ? HWND_TOPMOST : main;
  SetWindowPos(g_probe, insert_after, origin.x, origin.y, width, height,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void HdrSpike::TraceWindowPos(HWND main, UINT message, const WINDOWPOS* pos) {
  if (pos == nullptr) {
    return;
  }
  Log("%s insertAfter=%p x=%d y=%d cx=%d cy=%d flags=0x%x ex=0x%lx",
      message == WM_WINDOWPOSCHANGING ? "POSCHANGING" : "POSCHANGED ",
      pos->hwndInsertAfter, pos->x, pos->y, pos->cx, pos->cy, pos->flags,
      static_cast<long>(GetWindowLongPtrW(main, GWL_EXSTYLE)));
}

void HdrSpike::Stop() {
  if (g_probe != nullptr) {
    DestroyWindow(g_probe);
    g_probe = nullptr;
  }
}

}  // namespace fushi
