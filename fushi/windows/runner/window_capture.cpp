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

namespace fushi {

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

// BUG-1096：把一次「成功但值得记录」的事实追加进 diagnostics（多条以 "; " 相连）。
// [hr] 为 S_OK 时不附 HRESULT（纯陈述），否则附十六进制码。
void AppendDiagnostic(WindowCaptureResult* out, const char* note, HRESULT hr) {
  if (out == nullptr || note == nullptr) {
    return;
  }
  std::string line = note;
  if (hr != S_OK) {
    char hr_buf[16];
    _snprintf_s(hr_buf, sizeof(hr_buf), _TRUNCATE, "0x%08lX",
                static_cast<unsigned long>(hr));
    line += " hr=";
    line += hr_buf;
  }
  if (!out->diagnostics.empty()) {
    out->diagnostics += "; ";
  }
  out->diagnostics += line;
}

// 读窗口标题（无标题返回空串）。
std::wstring ReadWindowTitle(HWND hwnd) {
  const int len = GetWindowTextLengthW(hwnd);
  if (len <= 0) {
    return std::wstring();
  }
  std::wstring title(static_cast<size_t>(len) + 1, L'\0');
  const int got = GetWindowTextW(hwnd, title.data(), len + 1);
  title.resize(got > 0 ? static_cast<size_t>(got) : 0);
  return title;
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
  std::wstring title = ReadWindowTitle(hwnd);
  if (title.empty()) {
    return TRUE;
  }
  // BUG-1096：Magpie 缩放窗口在这里就换成它正在缩放的**源窗口**——否则用户选中的
  // 是「游戏画面 + Magpie 补画的第二个光标」那一层，PID 也是 Magpie.exe 而不是游戏
  // （voice hook 的注入目标同样会错）。拿不到属性时保持原窗口不变。
  HWND target = hwnd;
  if (const HWND source = ResolveScalingSourceWindow(hwnd)) {
    target = source;
    std::wstring source_title = ReadWindowTitle(source);
    if (!source_title.empty()) {
      title = std::move(source_title);
    }
  }
  // 重定向后可能与单独枚举到的源窗口重合（Z 序谁先到都可能），按 hwnd 去重。
  for (const ExternalWindow& existing : *ctx->out) {
    if (existing.hwnd == target) {
      return TRUE;
    }
  }
  ExternalWindow w;
  w.hwnd = target;
  w.title = WideToUtf8(title);
  // 所属进程 PID（供 galgame 引擎级 voice hook 注入目标；纯读，不改窗口）。
  GetWindowThreadProcessId(target, &w.pid);
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

// BUG-1096：Magpie 缩放窗 -> 源窗口。判定契约是**窗口属性** `Magpie.SrcHWND`
// （Magpie 在缩放窗上 SetProp 的公开标记），不是类名——类名里的 GUID 属于实现细节，
// 属性名才是跨版本稳定的那一条。属性缺失 / 指向自身 / 句柄已失效都返回 nullptr，
// 调用方原样保留传入窗口（Never break：没装 Magpie 的用户走的路径与以前逐字相同）。
HWND ResolveScalingSourceWindow(HWND hwnd) {
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    return nullptr;
  }
  const HANDLE prop = GetPropW(hwnd, L"Magpie.SrcHWND");
  if (prop == nullptr) {
    return nullptr;
  }
  HWND source = static_cast<HWND>(prop);
  if (source == hwnd || !IsWindow(source)) {
    return nullptr;
  }
  return source;
}

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
  // BUG-1096：关闭 WGC 合成光标。IGraphicsCaptureSession2 需要 Win10 build 19041+，
  // 以前 QI 的失败和 put_ 的 HRESULT **两处都被静默丢掉**——「用户机器上到底关掉了
  // 没有」是个彻底的盲区。现在两条路径都写进 diagnostics（经 channel 回到 Dart 日志），
  // 成不成立变成可证的事实，而不是靠推断。注意：游戏**自绘**的光标是画面内容本身，
  // 任何捕获 API 都剥不掉，这里只负责不再由 WGC 额外合成一个。
  ComPtr<WGC::IGraphicsCaptureSession2> session2;
  const HRESULT cursor_qi = session.As(&session2);
  if (SUCCEEDED(cursor_qi) && session2) {
    const HRESULT cursor_hr = session2->put_IsCursorCaptureEnabled(false);
    if (FAILED(cursor_hr)) {
      AppendDiagnostic(out, "put_IsCursorCaptureEnabled(false) failed",
                       cursor_hr);
    }
  } else {
    AppendDiagnostic(out,
                     "IGraphicsCaptureSession2 unavailable (needs Windows 10 "
                     "build 19041+); WGC cursor NOT suppressed",
                     SUCCEEDED(cursor_qi) ? E_POINTER : cursor_qi);
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
  // BUG-1096：捕获绑定前重定向。Dart 侧可能拿的是**上一次枚举缓存**的句柄，或者
  // Magpie 是在选窗之后才起来的，所以枚举侧重定向不够，绑定这一步必须再过一次。
  if (const HWND source = ResolveScalingSourceWindow(hwnd)) {
    AppendDiagnostic(&out,
                     "capture target redirected: Magpie scaling window -> "
                     "source window (Magpie.SrcHWND)",
                     S_OK);
    hwnd = source;
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

}  // namespace fushi
