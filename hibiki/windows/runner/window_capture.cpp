#include "window_capture.h"

#include <windows.h>

#include <dwmapi.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wincodec.h>
#include <roapi.h>
#include <winstring.h>
#include <shlwapi.h>

#include <wrl/client.h>
#include <wrl/event.h>

#include <windows.foundation.h>
#include <windows.graphics.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.h>
#include <windows.graphics.directx.direct3d11.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <atomic>
#include <cstdio>
#include <cwchar>

namespace hibiki {

namespace {

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Callback;
namespace WGC = ABI::Windows::Graphics::Capture;
namespace WGDX = ABI::Windows::Graphics::DirectX;
namespace WGDXD3D = ABI::Windows::Graphics::DirectX::Direct3D11;

// 与 Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess 同 IID，
// 本地声明避免依赖系统 interop 头在非 cppwinrt 构建下暴露它。用于从 WinRT surface
// 取回底层 ID3D11Texture2D。
struct __declspec(uuid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1"))
    IDxgiInterfaceAccessLocal : public ::IUnknown {
  virtual HRESULT __stdcall GetInterface(REFIID id, void** object) = 0;
};

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) {
    return std::string();
  }
  int size = WideCharToMultiByte(CP_UTF8, 0, w.data(),
                                 static_cast<int>(w.size()), nullptr, 0,
                                 nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()),
                      out.data(), size, nullptr, nullptr);
  return out;
}

// RoGetActivationFactory 薄封装：用类名的 WCHAR 字面量取激活工厂接口 [I]。
template <typename I>
HRESULT GetActivationFactory(const wchar_t* class_name, I** out) {
  HSTRING str = nullptr;
  HSTRING_HEADER header;
  HRESULT hr = WindowsCreateStringReference(
      class_name, static_cast<UINT32>(wcslen(class_name)), &header, &str);
  if (FAILED(hr)) {
    return hr;
  }
  return RoGetActivationFactory(str, __uuidof(I),
                                reinterpret_cast<void**>(out));
}

struct EnumContext {
  HWND self;
  std::vector<ExternalWindow>* out;
};

BOOL CALLBACK EnumProc(HWND hwnd, LPARAM lparam) {
  auto* ctx = reinterpret_cast<EnumContext*>(lparam);
  if (hwnd == ctx->self || !IsWindowVisible(hwnd)) {
    return TRUE;
  }
  // 跳过 cloaked 窗口（UWP 挂起 / 其它虚拟桌面的隐藏窗口）。
  BOOL cloaked = FALSE;
  if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked,
                                      sizeof(cloaked))) &&
      cloaked) {
    return TRUE;
  }
  // 跳过工具窗口（浮动工具条等，非用户内容窗口）。
  const LONG ex_style = GetWindowLong(hwnd, GWL_EXSTYLE);
  if (ex_style & WS_EX_TOOLWINDOW) {
    return TRUE;
  }
  const int len = GetWindowTextLengthW(hwnd);
  if (len <= 0) {
    return TRUE;
  }
  std::wstring title(static_cast<size_t>(len) + 1, L'\0');
  const int got = GetWindowTextW(hwnd, title.data(), len + 1);
  title.resize(got > 0 ? static_cast<size_t>(got) : 0);
  if (title.empty()) {
    return TRUE;
  }
  ExternalWindow w;
  w.hwnd = hwnd;
  w.title = WideToUtf8(title);
  // 所属进程 PID（供 galgame 引擎级 voice hook 注入目标；纯读，不改窗口）。
  GetWindowThreadProcessId(hwnd, &w.pid);
  ctx->out->push_back(std::move(w));
  return TRUE;
}

// BGRA 像素缓冲 -> PNG 字节（WIC）。stride 为源每行字节数（可含行尾 padding）。
std::vector<uint8_t> EncodeBgraToPng(const uint8_t* pixels, UINT width,
                                     UINT height, UINT stride,
                                     std::string* error) {
  std::vector<uint8_t> result;
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(hr)) {
    *error = "WIC factory create failed";
    return result;
  }
  ComPtr<IStream> stream;
  stream.Attach(SHCreateMemStream(nullptr, 0));
  if (!stream) {
    *error = "memory stream alloc failed";
    return result;
  }
  ComPtr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (SUCCEEDED(hr)) {
    hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  }
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> props;
  if (SUCCEEDED(hr)) {
    hr = encoder->CreateNewFrame(&frame, &props);
  }
  if (SUCCEEDED(hr)) {
    hr = frame->Initialize(props.Get());
  }
  if (SUCCEEDED(hr)) {
    hr = frame->SetSize(width, height);
  }
  WICPixelFormatGUID fmt = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(hr)) {
    hr = frame->SetPixelFormat(&fmt);
  }
  if (SUCCEEDED(hr)) {
    const UINT buf_size = stride * height;
    hr = frame->WritePixels(height, stride, buf_size,
                            const_cast<BYTE*>(pixels));
  }
  if (SUCCEEDED(hr)) {
    hr = frame->Commit();
  }
  if (SUCCEEDED(hr)) {
    hr = encoder->Commit();
  }
  if (FAILED(hr)) {
    *error = "PNG encode failed";
    return result;
  }
  // 把内存流回读进 vector。
  STATSTG stat = {};
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) {
    *error = "stream stat failed";
    return result;
  }
  const ULONG size = static_cast<ULONG>(stat.cbSize.QuadPart);
  LARGE_INTEGER zero = {};
  stream->Seek(zero, STREAM_SEEK_SET, nullptr);
  result.resize(size);
  ULONG read = 0;
  if (size > 0 && FAILED(stream->Read(result.data(), size, &read))) {
    *error = "stream read failed";
    result.clear();
    return result;
  }
  result.resize(read);
  return result;
}

// D3D11 设备（BGRA 支持），硬件失败回退 WARP。
ComPtr<ID3D11Device> CreateD3DDevice() {
  ComPtr<ID3D11Device> device;
  const UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 flags, nullptr, 0, D3D11_SDK_VERSION,
                                 device.GetAddressOf(), nullptr, nullptr);
  if (FAILED(hr)) {
    device.Reset();
    D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, nullptr, 0,
                      D3D11_SDK_VERSION, device.GetAddressOf(), nullptr,
                      nullptr);
  }
  return device;
}

}  // namespace

std::vector<ExternalWindow> EnumerateTopLevelWindows(HWND self) {
  std::vector<ExternalWindow> out;
  EnumContext ctx{self, &out};
  EnumWindows(&EnumProc, reinterpret_cast<LPARAM>(&ctx));
  return out;
}

namespace {

// 关闭实现 IClosable 的 WinRT 对象（frame / session / framePool），确定性拆除
// （不赌析构时序；与本仓 WGC 生命周期纪律一致）。
template <typename T>
void CloseIfClosable(const ComPtr<T>& obj) {
  if (!obj) {
    return;
  }
  ComPtr<ABI::Windows::Foundation::IClosable> closable;
  if (SUCCEEDED(obj.As(&closable))) {
    closable->Close();
  }
}

// 单帧捕获核心（假定调用线程已 RoInitialize）。任何失败写 out->error 并返回。
void CaptureCore(HWND hwnd, WindowCaptureResult* out) {
  ComPtr<WGC::IGraphicsCaptureSessionStatics> session_statics;
  if (FAILED(GetActivationFactory(
          RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureSession,
          session_statics.GetAddressOf()))) {
    out->error = "graphics capture unavailable";
    return;
  }
  boolean supported = false;
  session_statics->IsSupported(&supported);
  if (!supported) {
    out->error = "graphics capture not supported (Windows 10 1903+ required)";
    return;
  }

  ComPtr<ID3D11Device> d3d = CreateD3DDevice();
  if (!d3d) {
    out->error = "D3D11 device create failed";
    return;
  }
  ComPtr<IDXGIDevice> dxgi;
  if (FAILED(d3d.As(&dxgi))) {
    out->error = "IDXGIDevice query failed";
    return;
  }
  ComPtr<IInspectable> inspectable;
  if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(),
                                                  inspectable.GetAddressOf()))) {
    out->error = "CreateDirect3D11DeviceFromDXGIDevice failed";
    return;
  }
  ComPtr<WGDXD3D::IDirect3DDevice> device;
  if (FAILED(inspectable.As(&device))) {
    out->error = "IDirect3DDevice query failed";
    return;
  }

  ComPtr<IGraphicsCaptureItemInterop> interop;
  if (FAILED(GetActivationFactory(
          RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureItem,
          interop.GetAddressOf()))) {
    out->error = "capture item interop unavailable";
    return;
  }
  ComPtr<WGC::IGraphicsCaptureItem> item;
  if (FAILED(interop->CreateForWindow(
          hwnd, __uuidof(WGC::IGraphicsCaptureItem),
          reinterpret_cast<void**>(item.GetAddressOf()))) ||
      !item) {
    out->error = "CreateForWindow failed (window not capturable)";
    return;
  }
  ABI::Windows::Graphics::SizeInt32 size = {};
  if (FAILED(item->get_Size(&size)) || size.Width <= 0 || size.Height <= 0) {
    out->error = "window has zero size";
    return;
  }

  ComPtr<WGC::IDirect3D11CaptureFramePoolStatics2> pool_statics;
  if (FAILED(GetActivationFactory(
          RuntimeClass_Windows_Graphics_Capture_Direct3D11CaptureFramePool,
          pool_statics.GetAddressOf()))) {
    out->error = "frame pool statics unavailable";
    return;
  }
  ComPtr<WGC::IDirect3D11CaptureFramePool> frame_pool;
  if (FAILED(pool_statics->CreateFreeThreaded(
          device.Get(), WGDX::DirectXPixelFormat_B8G8R8A8UIntNormalized, 2,
          size, frame_pool.GetAddressOf())) ||
      !frame_pool) {
    out->error = "frame pool create failed";
    return;
  }
  ComPtr<WGC::IGraphicsCaptureSession> session;
  if (FAILED(frame_pool->CreateCaptureSession(item.Get(),
                                              session.GetAddressOf()))) {
    out->error = "capture session create failed";
    return;
  }
  // 尽力关闭鼠标捕获与黄框（旧系统无对应接口时静默跳过，不影响捕获）。
  ComPtr<WGC::IGraphicsCaptureSession2> session2;
  if (SUCCEEDED(session.As(&session2))) {
    session2->put_IsCursorCaptureEnabled(false);
  }
  ComPtr<WGC::IGraphicsCaptureSession3> session3;
  if (SUCCEEDED(session.As(&session3))) {
    session3->put_IsBorderRequired(false);
  }

  std::atomic<bool> grabbed{false};
  ComPtr<WGC::IDirect3D11CaptureFrame> frame;
  HANDLE frame_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (frame_event == nullptr) {
    out->error = "event create failed";
    return;
  }
  // 免线程（agile）委托：FreeThreaded 帧池会在任意线程池线程回调 FrameArrived。
  // 聚合 FtmBase 让委托 agile，避免非 agile 委托被 add_FrameArrived 拒绝
  // （RO_E_MUST_BE_AGILE，见 texture_bridge.cc 对 timer 委托的同款处理）。
  auto handler = Callback<Microsoft::WRL::Implements<
      Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
      ABI::Windows::Foundation::ITypedEventHandler<
          WGC::Direct3D11CaptureFramePool*, IInspectable*>,
      Microsoft::WRL::FtmBase>>(
      [&grabbed, &frame, frame_event](WGC::IDirect3D11CaptureFramePool* pool,
                                      IInspectable*) -> HRESULT {
        bool expected = false;
        if (grabbed.compare_exchange_strong(expected, true)) {
          pool->TryGetNextFrame(frame.GetAddressOf());
          SetEvent(frame_event);
        }
        return S_OK;
      });
  EventRegistrationToken token = {};
  if (FAILED(frame_pool->add_FrameArrived(handler.Get(), &token))) {
    CloseHandle(frame_event);
    out->error = "add_FrameArrived failed";
    return;
  }
  if (FAILED(session->StartCapture())) {
    frame_pool->remove_FrameArrived(token);
    CloseHandle(frame_event);
    out->error = "StartCapture failed";
    return;
  }

  const DWORD wait = WaitForSingleObject(frame_event, 1500);
  frame_pool->remove_FrameArrived(token);
  CloseHandle(frame_event);

  if (wait != WAIT_OBJECT_0 || !frame) {
    CloseIfClosable(session);
    CloseIfClosable(frame_pool);
    out->error =
        "capture timed out (no frame; DRM-protected windows yield no frame)";
    return;
  }

  ComPtr<WGDXD3D::IDirect3DSurface> surface;
  ComPtr<IDxgiInterfaceAccessLocal> access;
  ComPtr<ID3D11Texture2D> texture;
  if (SUCCEEDED(frame->get_Surface(surface.GetAddressOf())) &&
      SUCCEEDED(surface.As(&access))) {
    access->GetInterface(__uuidof(ID3D11Texture2D),
                         reinterpret_cast<void**>(texture.GetAddressOf()));
  }
  if (!texture) {
    CloseIfClosable(frame);
    CloseIfClosable(session);
    CloseIfClosable(frame_pool);
    out->error = "frame surface unavailable";
    return;
  }

  D3D11_TEXTURE2D_DESC desc = {};
  texture->GetDesc(&desc);
  D3D11_TEXTURE2D_DESC staging_desc = desc;
  staging_desc.Usage = D3D11_USAGE_STAGING;
  staging_desc.BindFlags = 0;
  staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  staging_desc.MiscFlags = 0;
  ComPtr<ID3D11Texture2D> staging;
  if (FAILED(d3d->CreateTexture2D(&staging_desc, nullptr,
                                  staging.GetAddressOf()))) {
    CloseIfClosable(frame);
    CloseIfClosable(session);
    CloseIfClosable(frame_pool);
    out->error = "staging texture create failed";
    return;
  }
  ComPtr<ID3D11DeviceContext> context;
  d3d->GetImmediateContext(context.GetAddressOf());
  context->CopyResource(staging.Get(), texture.Get());
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  if (SUCCEEDED(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
    out->png = EncodeBgraToPng(static_cast<const uint8_t*>(mapped.pData),
                               desc.Width, desc.Height, mapped.RowPitch,
                               &out->error);
    context->Unmap(staging.Get(), 0);
  } else {
    out->error = "map staging texture failed";
  }

  CloseIfClosable(frame);
  CloseIfClosable(session);
  CloseIfClosable(frame_pool);
  out->ok = out->error.empty() && !out->png.empty();
  if (!out->ok && out->error.empty()) {
    out->error = "capture produced no pixels";
  }
}

}  // namespace

WindowCaptureResult CaptureWindowPng(HWND hwnd) {
  WindowCaptureResult out;
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    out.error = "window handle invalid";
    return out;
  }
  const HRESULT ro = RoInitialize(RO_INIT_MULTITHREADED);
  // RPC_E_CHANGED_MODE = 本线程已按其它套间初始化；照常用、但不由我们反初始化。
  if (FAILED(ro) && ro != RPC_E_CHANGED_MODE) {
    out.error = "RoInitialize failed";
    return out;
  }
  CaptureCore(hwnd, &out);
  if (SUCCEEDED(ro)) {
    RoUninitialize();
  }
  return out;
}

}  // namespace hibiki
