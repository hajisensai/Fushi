#include "window_capture.h"

#include <windows.h>

#include <d3d11.h>
#include <dwmapi.h>
#include <dxgi.h>
#include <roapi.h>
#include <shlwapi.h>
#include <wincodec.h>
#include <windows.foundation.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.graphics.directx.h>
#include <windows.graphics.h>
#include <windows.system.h>
#include <winstring.h>
#include <wrl/client.h>
#include <wrl/event.h>

#include <cstdio>
#include <cwchar>
#include <memory>
#include <utility>

namespace hibiki {
namespace {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
namespace WGC = ABI::Windows::Graphics::Capture;
namespace WGDX = ABI::Windows::Graphics::DirectX;
namespace WGDXD3D = ABI::Windows::Graphics::DirectX::Direct3D11;

struct __declspec(uuid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1"))
    IDxgiInterfaceAccessLocal : public IUnknown {
  virtual HRESULT __stdcall GetInterface(REFIID id, void** object) = 0;
};

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  const int size = WideCharToMultiByte(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0,
      nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), size,
                      nullptr, nullptr);
  return result;
}

std::string ProcessImagePath(DWORD process_id) {
  if (process_id == 0) {
    return std::string();
  }
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                               process_id);
  if (process == nullptr) {
    return std::string();
  }
  std::wstring path(32768, L'\0');
  DWORD size = static_cast<DWORD>(path.size());
  const BOOL ok = QueryFullProcessImageNameW(process, 0, path.data(), &size);
  CloseHandle(process);
  if (!ok || size == 0) {
    return std::string();
  }
  path.resize(size);
  return WideToUtf8(path);
}

template <typename Interface>
HRESULT GetActivationFactory(const wchar_t* class_name, Interface** out) {
  HSTRING string = nullptr;
  HSTRING_HEADER header = {};
  const HRESULT hr = WindowsCreateStringReference(
      class_name, static_cast<UINT32>(wcslen(class_name)), &header, &string);
  if (FAILED(hr)) {
    return hr;
  }
  return RoGetActivationFactory(string, __uuidof(Interface),
                                reinterpret_cast<void**>(out));
}

struct EnumContext {
  HWND self;
  std::vector<ExternalWindow>* output;
};

BOOL CALLBACK EnumWindow(HWND hwnd, LPARAM lparam) {
  auto* context = reinterpret_cast<EnumContext*>(lparam);
  if (hwnd == context->self || !IsWindowVisible(hwnd)) {
    return TRUE;
  }
  BOOL cloaked = FALSE;
  if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked,
                                      sizeof(cloaked))) &&
      cloaked) {
    return TRUE;
  }
  const LONG_PTR extended_style = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  if ((extended_style & WS_EX_TOOLWINDOW) != 0) {
    return TRUE;
  }
  const int title_length = GetWindowTextLengthW(hwnd);
  if (title_length <= 0) {
    return TRUE;
  }
  std::wstring title(static_cast<size_t>(title_length) + 1, L'\0');
  const int copied = GetWindowTextW(hwnd, title.data(), title_length + 1);
  title.resize(copied > 0 ? static_cast<size_t>(copied) : 0);
  if (title.empty()) {
    return TRUE;
  }

  ExternalWindow window;
  window.hwnd = hwnd;
  GetWindowThreadProcessId(hwnd, &window.process_id);
  window.title = WideToUtf8(title);
  window.executable_path = ProcessImagePath(window.process_id);
  context->output->push_back(std::move(window));
  return TRUE;
}

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
  ComPtr<IPropertyBag2> properties;
  if (SUCCEEDED(hr)) {
    hr = encoder->CreateNewFrame(&frame, &properties);
  }
  if (SUCCEEDED(hr)) {
    hr = frame->Initialize(properties.Get());
  }
  if (SUCCEEDED(hr)) {
    hr = frame->SetSize(width, height);
  }
  WICPixelFormatGUID pixel_format = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(hr)) {
    hr = frame->SetPixelFormat(&pixel_format);
  }
  if (SUCCEEDED(hr)) {
    hr = frame->WritePixels(height, stride, stride * height,
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

  STATSTG statistics = {};
  if (FAILED(stream->Stat(&statistics, STATFLAG_NONAME))) {
    *error = "stream stat failed";
    return result;
  }
  const ULONG size = static_cast<ULONG>(statistics.cbSize.QuadPart);
  LARGE_INTEGER start = {};
  stream->Seek(start, STREAM_SEEK_SET, nullptr);
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

ComPtr<ID3D11Device> CreateD3DDevice() {
  ComPtr<ID3D11Device> device;
  const UINT flags =
      D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
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

template <typename Interface>
void CloseIfClosable(const ComPtr<Interface>& object) {
  if (!object) {
    return;
  }
  ComPtr<ABI::Windows::Foundation::IClosable> closable;
  if (SUCCEEDED(object.As(&closable))) {
    closable->Close();
  }
}

std::string HResultError(const char* operation, HRESULT hr) {
  char buffer[96] = {};
  std::snprintf(buffer, sizeof(buffer), "%s failed (0x%08lX)", operation,
                static_cast<unsigned long>(hr));
  return std::string(buffer);
}

WindowCaptureResult EncodeFramePng(ID3D11Device* d3d,
                                   WGC::IDirect3D11CaptureFrame* frame) {
  WindowCaptureResult output;
  ComPtr<WGDXD3D::IDirect3DSurface> surface;
  ComPtr<IDxgiInterfaceAccessLocal> access;
  ComPtr<ID3D11Texture2D> texture;
  if (SUCCEEDED(frame->get_Surface(surface.GetAddressOf())) &&
      SUCCEEDED(surface.As(&access))) {
    access->GetInterface(__uuidof(ID3D11Texture2D),
                         reinterpret_cast<void**>(texture.GetAddressOf()));
  }
  if (!texture) {
    output.error = "frame surface unavailable";
    return output;
  }

  D3D11_TEXTURE2D_DESC description = {};
  texture->GetDesc(&description);
  D3D11_TEXTURE2D_DESC staging_description = description;
  staging_description.Usage = D3D11_USAGE_STAGING;
  staging_description.BindFlags = 0;
  staging_description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  staging_description.MiscFlags = 0;
  ComPtr<ID3D11Texture2D> staging;
  if (FAILED(d3d->CreateTexture2D(&staging_description, nullptr,
                                  staging.GetAddressOf()))) {
    output.error = "staging texture create failed";
    return output;
  }

  ComPtr<ID3D11DeviceContext> context;
  d3d->GetImmediateContext(context.GetAddressOf());
  context->CopyResource(staging.Get(), texture.Get());
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  if (FAILED(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
    output.error = "map staging texture failed";
    return output;
  }
  output.png = EncodeBgraToPng(static_cast<const uint8_t*>(mapped.pData),
                               description.Width, description.Height,
                               mapped.RowPitch, &output.error);
  context->Unmap(staging.Get(), 0);
  output.ok = output.error.empty() && !output.png.empty();
  if (!output.ok && output.error.empty()) {
    output.error = "capture produced no pixels";
  }
  return output;
}

bool HasVisiblePixels(const uint8_t* pixels, int width, int height,
                      int stride) {
  const int step_x = width > 80 ? width / 80 : 1;
  const int step_y = height > 80 ? height / 80 : 1;
  int sampled = 0;
  int non_black = 0;
  for (int y = 0; y < height; y += step_y) {
    const uint8_t* row = pixels + static_cast<size_t>(y) * stride;
    for (int x = 0; x < width; x += step_x) {
      const uint8_t* pixel = row + static_cast<size_t>(x) * 4;
      ++sampled;
      if (pixel[0] > 5 || pixel[1] > 5 || pixel[2] > 5) {
        ++non_black;
      }
    }
  }
  return sampled > 0 && non_black * 100 > sampled;
}

bool HasVisibleClientPixels(HWND hwnd, const RECT& window_bounds,
                            const uint8_t* pixels, int bitmap_width,
                            int bitmap_height, int stride) {
  RECT client = {};
  POINT top_left = {};
  if (!GetClientRect(hwnd, &client) ||
      !ClientToScreen(hwnd, &top_left)) {
    return HasVisiblePixels(pixels, bitmap_width, bitmap_height, stride);
  }
  const int client_width = client.right - client.left;
  const int client_height = client.bottom - client.top;
  if (client_width <= 8 || client_height <= 8) {
    return HasVisiblePixels(pixels, bitmap_width, bitmap_height, stride);
  }
  const int offset_x = top_left.x - window_bounds.left;
  const int offset_y = top_left.y - window_bounds.top;
  const int left = offset_x < 0 ? 0 : offset_x;
  const int top = offset_y < 0 ? 0 : offset_y;
  const int right = offset_x + client_width > bitmap_width
                        ? bitmap_width
                        : offset_x + client_width;
  const int bottom = offset_y + client_height > bitmap_height
                         ? bitmap_height
                         : offset_y + client_height;
  if (right <= left || bottom <= top) {
    return HasVisiblePixels(pixels, bitmap_width, bitmap_height, stride);
  }
  return HasVisiblePixels(pixels + static_cast<size_t>(top) * stride +
                                       static_cast<size_t>(left) * 4,
                          right - left, bottom - top, stride);
}

WindowCaptureResult CaptureWindowGdi(HWND hwnd, bool render_window) {
  WindowCaptureResult output;
  RECT bounds = {};
  if (!GetWindowRect(hwnd, &bounds)) {
    output.error = "window bounds unavailable";
    return output;
  }
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  constexpr int64_t kMaxPixels = 100000000;
  if (width <= 0 || height <= 0 ||
      static_cast<int64_t>(width) * height > kMaxPixels) {
    output.error = "window has invalid capture size";
    return output;
  }

  HDC screen_dc = GetDC(nullptr);
  HDC memory_dc = screen_dc == nullptr ? nullptr : CreateCompatibleDC(screen_dc);
  if (screen_dc == nullptr || memory_dc == nullptr) {
    if (memory_dc != nullptr) {
      DeleteDC(memory_dc);
    }
    if (screen_dc != nullptr) {
      ReleaseDC(nullptr, screen_dc);
    }
    output.error = "GDI capture context create failed";
    return output;
  }

  BITMAPINFO bitmap_info = {};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = width;
  bitmap_info.bmiHeader.biHeight = -height;
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;
  void* bitmap_pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(screen_dc, &bitmap_info, DIB_RGB_COLORS,
                                    &bitmap_pixels, nullptr, 0);
  if (bitmap == nullptr || bitmap_pixels == nullptr) {
    if (bitmap != nullptr) {
      DeleteObject(bitmap);
    }
    DeleteDC(memory_dc);
    ReleaseDC(nullptr, screen_dc);
    output.error = "GDI capture bitmap create failed";
    return output;
  }

  HGDIOBJ old_bitmap = SelectObject(memory_dc, bitmap);
  PatBlt(memory_dc, 0, 0, width, height, BLACKNESS);
  constexpr UINT kPrintWindowRenderFullContent = 0x00000002;
  const BOOL captured = render_window
                            ? PrintWindow(hwnd, memory_dc,
                                          kPrintWindowRenderFullContent)
                            : BitBlt(memory_dc, 0, 0, width, height, screen_dc,
                                     bounds.left, bounds.top,
                                     SRCCOPY | CAPTUREBLT);
  GdiFlush();

  auto* pixels = static_cast<uint8_t*>(bitmap_pixels);
  const int stride = width * 4;
  if (captured) {
    for (int y = 0; y < height; ++y) {
      uint8_t* row = pixels + static_cast<size_t>(y) * stride;
      for (int x = 0; x < width; ++x) {
        row[static_cast<size_t>(x) * 4 + 3] = 255;
      }
    }
    if (HasVisibleClientPixels(hwnd, bounds, pixels, width, height, stride)) {
      output.png = EncodeBgraToPng(pixels, static_cast<UINT>(width),
                                   static_cast<UINT>(height),
                                   static_cast<UINT>(stride), &output.error);
      output.ok = output.error.empty() && !output.png.empty();
    } else {
      output.error = render_window ? "PrintWindow returned a black frame"
                                   : "desktop crop returned a black frame";
    }
  } else {
    output.error = render_window ? "PrintWindow failed" : "desktop crop failed";
  }

  SelectObject(memory_dc, old_bitmap);
  DeleteObject(bitmap);
  DeleteDC(memory_dc);
  ReleaseDC(nullptr, screen_dc);
  return output;
}

using DispatcherTickHandler = ABI::Windows::Foundation::ITypedEventHandler<
    ABI::Windows::System::DispatcherQueueTimer*, IInspectable*>;

class WindowCaptureOperation
    : public std::enable_shared_from_this<WindowCaptureOperation> {
 public:
  static void Start(HWND hwnd, WindowCaptureCallback callback) {
    auto operation = std::shared_ptr<WindowCaptureOperation>(
        new WindowCaptureOperation(std::move(callback)));
    operation->keep_alive_ = operation;
    operation->Begin(hwnd);
  }

 private:
  explicit WindowCaptureOperation(WindowCaptureCallback callback)
      : callback_(std::move(callback)) {}

  void Begin(HWND hwnd) {
    if (hwnd == nullptr || !IsWindow(hwnd)) {
      Fail("window handle invalid");
      return;
    }
    hwnd_ = hwnd;

    WindowCaptureResult print_window = CaptureWindowGdi(hwnd, true);
    if (print_window.ok) {
      Complete(std::move(print_window));
      return;
    }

    ComPtr<WGC::IGraphicsCaptureSessionStatics> session_statics;
    if (FAILED(GetActivationFactory(
            RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureSession,
            session_statics.GetAddressOf()))) {
      Fail("graphics capture unavailable");
      return;
    }
    boolean supported = false;
    session_statics->IsSupported(&supported);
    if (!supported) {
      Fail("graphics capture not supported (Windows 10 1903+ required)");
      return;
    }

    d3d_ = CreateD3DDevice();
    if (!d3d_) {
      Fail("D3D11 device create failed");
      return;
    }
    ComPtr<IDXGIDevice> dxgi;
    if (FAILED(d3d_.As(&dxgi))) {
      Fail("IDXGIDevice query failed");
      return;
    }
    ComPtr<IInspectable> inspectable;
    if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(
            dxgi.Get(), inspectable.GetAddressOf()))) {
      Fail("CreateDirect3D11DeviceFromDXGIDevice failed");
      return;
    }
    if (FAILED(inspectable.As(&device_))) {
      Fail("IDirect3DDevice query failed");
      return;
    }

    ComPtr<IGraphicsCaptureItemInterop> interop;
    if (FAILED(GetActivationFactory(
            RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureItem,
            interop.GetAddressOf()))) {
      Fail("capture item interop unavailable");
      return;
    }
    if (FAILED(interop->CreateForWindow(
            hwnd, __uuidof(WGC::IGraphicsCaptureItem),
            reinterpret_cast<void**>(item_.GetAddressOf()))) ||
        !item_) {
      Fail("CreateForWindow failed (window not capturable)");
      return;
    }
    ABI::Windows::Graphics::SizeInt32 size = {};
    if (FAILED(item_->get_Size(&size)) || size.Width <= 0 || size.Height <= 0) {
      Fail("window has zero size");
      return;
    }

    ComPtr<ABI::Windows::System::IDispatcherQueueStatics> queue_statics;
    if (FAILED(GetActivationFactory(RuntimeClass_Windows_System_DispatcherQueue,
                                    queue_statics.GetAddressOf())) ||
        FAILED(queue_statics->GetForCurrentThread(
            dispatcher_queue_.GetAddressOf())) ||
        !dispatcher_queue_) {
      Fail("UI dispatcher queue unavailable");
      return;
    }

    ComPtr<WGC::IDirect3D11CaptureFramePoolStatics2> pool_statics;
    if (FAILED(GetActivationFactory(
            RuntimeClass_Windows_Graphics_Capture_Direct3D11CaptureFramePool,
            pool_statics.GetAddressOf()))) {
      Fail("frame pool statics unavailable");
      return;
    }
    if (FAILED(pool_statics->CreateFreeThreaded(
            device_.Get(), WGDX::DirectXPixelFormat_B8G8R8A8UIntNormalized, 1,
            size, frame_pool_.GetAddressOf())) ||
        !frame_pool_) {
      Fail("frame pool create failed");
      return;
    }
    if (FAILED(frame_pool_->CreateCaptureSession(item_.Get(),
                                                 session_.GetAddressOf())) ||
        !session_) {
      Fail("capture session create failed");
      return;
    }

    ComPtr<WGC::IGraphicsCaptureSession2> session2;
    if (SUCCEEDED(session_.As(&session2))) {
      session2->put_IsCursorCaptureEnabled(false);
    }
    ComPtr<WGC::IGraphicsCaptureSession3> session3;
    if (SUCCEEDED(session_.As(&session3))) {
      session3->put_IsBorderRequired(false);
    }

    HRESULT hr = dispatcher_queue_->CreateTimer(timer_.GetAddressOf());
    if (FAILED(hr) || !timer_) {
      Fail(HResultError("capture timer create", hr));
      return;
    }
    ABI::Windows::Foundation::TimeSpan interval = {};
    interval.Duration = 166667;
    timer_->put_Interval(interval);
    timer_->put_IsRepeating(true);

    const std::weak_ptr<WindowCaptureOperation> weak = shared_from_this();
    tick_handler_ = Callback<Microsoft::WRL::Implements<
        Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
        DispatcherTickHandler, Microsoft::WRL::FtmBase>>(
        [weak](ABI::Windows::System::IDispatcherQueueTimer*,
               IInspectable*) -> HRESULT {
          if (const auto operation = weak.lock()) {
            operation->OnTimerTick();
          }
          return S_OK;
        });
    hr = timer_->add_Tick(tick_handler_.Get(), &tick_token_);
    if (FAILED(hr)) {
      Fail(HResultError("capture timer add tick", hr));
      return;
    }
    hr = session_->StartCapture();
    if (FAILED(hr)) {
      Fail(HResultError("StartCapture", hr));
      return;
    }

    deadline_ = GetTickCount64() + 300;
    hr = timer_->Start();
    if (FAILED(hr)) {
      Fail(HResultError("capture timer start", hr));
    }
  }

  void OnTimerTick() {
    in_tick_ = true;
    PollFrame();
    in_tick_ = false;
    if (completed_) {
      ReleaseTimerResources();
    }
  }

  void PollFrame() {
    if (completed_) {
      return;
    }
    ComPtr<WGC::IDirect3D11CaptureFrame> frame;
    const HRESULT hr = frame_pool_->TryGetNextFrame(frame.GetAddressOf());
    if (FAILED(hr)) {
      CompleteWithDesktopFallback(HResultError("TryGetNextFrame", hr));
      return;
    }
    if (frame) {
      WindowCaptureResult result = EncodeFramePng(d3d_.Get(), frame.Get());
      CloseIfClosable(frame);
      Complete(std::move(result));
      return;
    }
    if (GetTickCount64() >= deadline_) {
      CompleteWithDesktopFallback("capture timed out (no WGC frame)");
    }
  }

  void CompleteWithDesktopFallback(std::string wgc_error) {
    WindowCaptureResult desktop = CaptureWindowGdi(hwnd_, false);
    if (desktop.ok) {
      Complete(std::move(desktop));
      return;
    }
    Fail(std::move(wgc_error) + "; " + desktop.error);
  }

  void Fail(std::string error) {
    WindowCaptureResult result;
    result.error = std::move(error);
    Complete(std::move(result));
  }

  void Complete(WindowCaptureResult result) {
    if (completed_) {
      return;
    }
    completed_ = true;
    if (timer_) {
      timer_->Stop();
      if (tick_token_.value != 0) {
        timer_->remove_Tick(tick_token_);
        tick_token_ = {};
      }
    }
    if (!in_tick_) {
      ReleaseTimerResources();
    }
    CloseIfClosable(session_);
    CloseIfClosable(frame_pool_);
    session_.Reset();
    frame_pool_.Reset();
    item_.Reset();
    device_.Reset();
    dispatcher_queue_.Reset();
    d3d_.Reset();

    WindowCaptureCallback callback = std::move(callback_);
    keep_alive_.reset();
    if (callback) {
      callback(std::move(result));
    }
  }

  void ReleaseTimerResources() {
    tick_handler_.Reset();
    timer_.Reset();
  }

  WindowCaptureCallback callback_;
  std::shared_ptr<WindowCaptureOperation> keep_alive_;
  ComPtr<ID3D11Device> d3d_;
  ComPtr<WGDXD3D::IDirect3DDevice> device_;
  ComPtr<WGC::IGraphicsCaptureItem> item_;
  ComPtr<WGC::IDirect3D11CaptureFramePool> frame_pool_;
  ComPtr<WGC::IGraphicsCaptureSession> session_;
  ComPtr<ABI::Windows::System::IDispatcherQueue> dispatcher_queue_;
  ComPtr<ABI::Windows::System::IDispatcherQueueTimer> timer_;
  ComPtr<DispatcherTickHandler> tick_handler_;
  EventRegistrationToken tick_token_ = {};
  HWND hwnd_ = nullptr;
  ULONGLONG deadline_ = 0;
  bool completed_ = false;
  bool in_tick_ = false;
};

}  // namespace

std::vector<ExternalWindow> EnumerateTopLevelWindows(HWND self) {
  std::vector<ExternalWindow> result;
  EnumContext context{self, &result};
  EnumWindows(&EnumWindow, reinterpret_cast<LPARAM>(&context));
  return result;
}

void CaptureWindowPngAsync(HWND hwnd, WindowCaptureCallback callback) {
  WindowCaptureOperation::Start(hwnd, std::move(callback));
}

}  // namespace hibiki
