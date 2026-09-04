#include "window_recorder.h"

#include <windows.h>

#include <d3d11.h>
#include <dxgi.h>
#include <wincodec.h>
#include <roapi.h>
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

#include "wgc_interop.h"
#include "window_capture.h"
#include "window_recorder_ring.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace fushi {

namespace {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
namespace WGC = ABI::Windows::Graphics::Capture;
namespace WGDX = ABI::Windows::Graphics::DirectX;
namespace WGDXD3D = ABI::Windows::Graphics::DirectX::Direct3D11;
using ABI::Windows::Graphics::SizeInt32;
using wgc::CloseIfClosable;
using wgc::GetActivationFactory;
using wgc::IDxgiInterfaceAccessLocal;
using window_recorder_ring::DownscaleBgraToBgr24;
using window_recorder_ring::FitWidth;
using window_recorder_ring::FrameEntry;
using window_recorder_ring::FrameRing;
using window_recorder_ring::ResolveExportRange;
using window_recorder_ring::RingPolicy;
using window_recorder_ring::ScaledSize;
using window_recorder_ring::ShouldKeepFrame;

// 环形队列总字节上限：20 秒 × 5 fps × ~60KB/帧（640 宽 JPEG q0.8）≈ 6MB，24MB 给
// 高 fps / 大画面留足余量，同时把最坏内存钉死。
constexpr size_t kMaxRingBytes = static_cast<size_t>(24) * 1024 * 1024;
constexpr float kJpegQuality = 0.8f;
constexpr int kMaxFps = 60;
constexpr int kMaxSeconds = 120;

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) {
    return std::wstring();
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                       static_cast<int>(s.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring out(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      out.data(), size);
  return out;
}

// 紧凑 BGR24 像素 -> JPEG 字节（WIC，ImageQuality=[kJpegQuality]）。失败返回空。
std::vector<uint8_t> EncodeBgr24ToJpeg(IWICImagingFactory* factory,
                                       const uint8_t* pixels, UINT width,
                                       UINT height) {
  std::vector<uint8_t> result;
  if (factory == nullptr || pixels == nullptr || width == 0 || height == 0) {
    return result;
  }
  ComPtr<IStream> stream;
  stream.Attach(SHCreateMemStream(nullptr, 0));
  if (!stream) {
    return result;
  }
  ComPtr<IWICBitmapEncoder> encoder;
  HRESULT hr =
      factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder);
  if (SUCCEEDED(hr)) {
    hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  }
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> props;
  if (SUCCEEDED(hr)) {
    hr = encoder->CreateNewFrame(&frame, &props);
  }
  if (SUCCEEDED(hr) && props) {
    // 质量属性写失败不致命：退回编码器默认质量，帧照样出。
    PROPBAG2 option = {};
    option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT value = {};
    value.vt = VT_R4;
    value.fltVal = kJpegQuality;
    props->Write(1, &option, &value);
  }
  if (SUCCEEDED(hr)) {
    hr = frame->Initialize(props.Get());
  }
  if (SUCCEEDED(hr)) {
    hr = frame->SetSize(width, height);
  }
  WICPixelFormatGUID fmt = GUID_WICPixelFormat24bppBGR;
  if (SUCCEEDED(hr)) {
    hr = frame->SetPixelFormat(&fmt);
  }
  if (SUCCEEDED(hr) && !IsEqualGUID(fmt, GUID_WICPixelFormat24bppBGR)) {
    // 编码器不肯收 24bppBGR（理论上 JPEG 编码器原生支持），别把错格式的字节硬塞进去。
    hr = E_FAIL;
  }
  if (SUCCEEDED(hr)) {
    const UINT stride = width * 3;
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
    return result;
  }
  STATSTG stat = {};
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) {
    return result;
  }
  const ULONG size = static_cast<ULONG>(stat.cbSize.QuadPart);
  LARGE_INTEGER zero = {};
  stream->Seek(zero, STREAM_SEEK_SET, nullptr);
  result.resize(size);
  ULONG read = 0;
  if (size > 0 && FAILED(stream->Read(result.data(), size, &read))) {
    result.clear();
    return result;
  }
  result.resize(read);
  return result;
}

bool WriteWholeFile(const std::wstring& path, const std::vector<uint8_t>& bytes) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  bool ok = true;
  size_t offset = 0;
  while (ok && offset < bytes.size()) {
    const DWORD chunk = static_cast<DWORD>(
        std::min<size_t>(bytes.size() - offset, 1u << 20));
    DWORD written = 0;
    ok = WriteFile(file, bytes.data() + offset, chunk, &written, nullptr) &&
         written == chunk;
    offset += written;
  }
  CloseHandle(file);
  return ok;
}

// 进程唯一的录制状态。控制面（Start/Stop/Export）与数据面（WGC 回调）分锁：
//   control_mutex —— Start/Stop 串行、线程句柄归属；
//   frame_mutex   —— D3D 上下文 / 帧池 / WIC 只在持锁时触碰（ID3D11DeviceContext 非
//                    线程安全，FreeThreaded 帧池的回调可能来自任意线程池线程）；
//   ring_mutex    —— 环形队列，Export 只拿它。
struct RecorderState {
  std::mutex control_mutex;
  std::thread thread;
  HANDLE stop_event = nullptr;

  // Start 与录制线程的建立握手。
  std::mutex init_mutex;
  std::condition_variable init_cv;
  bool init_done = false;
  bool init_ok = false;

  std::atomic<bool> recording{false};

  mutable std::mutex error_mutex;
  std::string last_error;

  // 数据面（frame_mutex 保护）。
  std::mutex frame_mutex;
  bool teardown = false;
  HWND hwnd = nullptr;
  int fps = 5;
  int max_width = 640;
  ComPtr<ID3D11Device> d3d;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<WGDXD3D::IDirect3DDevice> device;
  ComPtr<WGC::IGraphicsCaptureItem> item;
  ComPtr<WGC::IDirect3D11CaptureFramePool> frame_pool;
  ComPtr<WGC::IGraphicsCaptureSession> session;
  ComPtr<ID3D11Texture2D> staging;
  ComPtr<IWICImagingFactory> wic;
  SizeInt32 pool_size = {};
  bool has_last = false;
  uint64_t last_kept_tick = 0;
  EventRegistrationToken frame_token = {};
  EventRegistrationToken closed_token = {};

  std::mutex ring_mutex;
  FrameRing ring;
};

RecorderState g_state;

void RecordError(const std::string& error) {
  std::lock_guard<std::mutex> lock(g_state.error_mutex);
  g_state.last_error = error;
}

void RequestStop() {
  if (g_state.stop_event != nullptr) {
    SetEvent(g_state.stop_event);
  }
}

// 一帧的有界处理（持 frame_mutex）：按 fps 抽帧 → 取纹理 → staging 拷贝 → Map →
// 客户区裁剪 → box 缩小 → JPEG → 入队；最后按 ContentSize 变化重建帧池。
void HandleFrame(WGC::IDirect3D11CaptureFrame* frame) {
  SizeInt32 content = {};
  if (FAILED(frame->get_ContentSize(&content)) || content.Width <= 0 ||
      content.Height <= 0) {
    return;
  }
  const uint64_t now = GetTickCount64();
  if (ShouldKeepFrame(now, g_state.has_last, g_state.last_kept_tick,
                      g_state.fps)) {
    ComPtr<WGDXD3D::IDirect3DSurface> surface;
    ComPtr<IDxgiInterfaceAccessLocal> access;
    ComPtr<ID3D11Texture2D> texture;
    if (SUCCEEDED(frame->get_Surface(surface.GetAddressOf())) &&
        SUCCEEDED(surface.As(&access))) {
      access->GetInterface(__uuidof(ID3D11Texture2D),
                           reinterpret_cast<void**>(texture.GetAddressOf()));
    }
    if (texture) {
      D3D11_TEXTURE2D_DESC desc = {};
      texture->GetDesc(&desc);
      D3D11_TEXTURE2D_DESC staging_desc = {};
      if (g_state.staging) {
        g_state.staging->GetDesc(&staging_desc);
      }
      if (!g_state.staging || staging_desc.Width != desc.Width ||
          staging_desc.Height != desc.Height ||
          staging_desc.Format != desc.Format) {
        staging_desc = desc;
        staging_desc.Usage = D3D11_USAGE_STAGING;
        staging_desc.BindFlags = 0;
        staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        staging_desc.MiscFlags = 0;
        g_state.staging.Reset();
        g_state.d3d->CreateTexture2D(&staging_desc, nullptr,
                                     g_state.staging.GetAddressOf());
      }
      if (g_state.staging) {
        g_state.context->CopyResource(g_state.staging.Get(), texture.Get());
        D3D11_MAPPED_SUBRESOURCE mapped = {};
        if (SUCCEEDED(g_state.context->Map(g_state.staging.Get(), 0,
                                           D3D11_MAP_READ, 0, &mapped))) {
          // 窗口刚缩小时纹理仍是旧池尺寸，有效像素只有 ContentSize 那一块。
          const UINT valid_w = std::min<UINT>(
              desc.Width, static_cast<UINT>(content.Width));
          const UINT valid_h = std::min<UINT>(
              desc.Height, static_cast<UINT>(content.Height));
          RECT crop{};
          if (!ComputeClientCropBox(g_state.hwnd, valid_w, valid_h, &crop)) {
            crop.left = 0;
            crop.top = 0;
            crop.right = static_cast<LONG>(valid_w);
            crop.bottom = static_cast<LONG>(valid_h);
          }
          const uint32_t crop_w = static_cast<uint32_t>(crop.right - crop.left);
          const uint32_t crop_h = static_cast<uint32_t>(crop.bottom - crop.top);
          const ScaledSize scaled =
              FitWidth(crop_w, crop_h, static_cast<uint32_t>(g_state.max_width));
          std::vector<uint8_t> bgr = DownscaleBgraToBgr24(
              static_cast<const uint8_t*>(mapped.pData), mapped.RowPitch,
              static_cast<uint32_t>(crop.left), static_cast<uint32_t>(crop.top),
              crop_w, crop_h, scaled.width, scaled.height);
          g_state.context->Unmap(g_state.staging.Get(), 0);
          if (!bgr.empty()) {
            std::vector<uint8_t> jpeg = EncodeBgr24ToJpeg(
                g_state.wic.Get(), bgr.data(), scaled.width, scaled.height);
            if (!jpeg.empty()) {
              std::lock_guard<std::mutex> ring_lock(g_state.ring_mutex);
              g_state.ring.Push(now, std::move(jpeg));
            }
          }
        }
      }
    }
    // 无论编码成没成，这一拍算用掉了：编码失败的帧不该让下一帧立刻补位、把 fps
    // 抬到显示刷新率。
    g_state.has_last = true;
    g_state.last_kept_tick = now;
  }
  // 窗口尺寸变了：按官方样例在处理完当前帧后重建帧池（下一帧起纹理换新尺寸；
  // staging 在上面按 desc 差异自适应重建）。
  if (content.Width != g_state.pool_size.Width ||
      content.Height != g_state.pool_size.Height) {
    if (SUCCEEDED(g_state.frame_pool->Recreate(
            g_state.device.Get(),
            WGDX::DirectXPixelFormat_B8G8R8A8UIntNormalized, 2, content))) {
      g_state.pool_size = content;
    }
  }
}

// 在录制线程上建立会话（持 frame_mutex）。失败返回原因（非空）。
std::string SetupCapture() {
  ComPtr<WGC::IGraphicsCaptureSessionStatics> session_statics;
  if (FAILED(GetActivationFactory(
          RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureSession,
          session_statics.GetAddressOf()))) {
    return "graphics capture unavailable";
  }
  boolean supported = false;
  session_statics->IsSupported(&supported);
  if (!supported) {
    return "graphics capture not supported (Windows 10 1903+ required)";
  }
  g_state.d3d = CreateD3DDevice();
  if (!g_state.d3d) {
    return "D3D11 device create failed";
  }
  g_state.d3d->GetImmediateContext(g_state.context.GetAddressOf());
  ComPtr<IDXGIDevice> dxgi;
  if (FAILED(g_state.d3d.As(&dxgi))) {
    return "IDXGIDevice query failed";
  }
  ComPtr<IInspectable> inspectable;
  if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(),
                                                  inspectable.GetAddressOf()))) {
    return "CreateDirect3D11DeviceFromDXGIDevice failed";
  }
  if (FAILED(inspectable.As(&g_state.device))) {
    return "IDirect3DDevice query failed";
  }
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&g_state.wic)))) {
    return "WIC factory create failed";
  }

  ComPtr<IGraphicsCaptureItemInterop> interop;
  if (FAILED(GetActivationFactory(
          RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureItem,
          interop.GetAddressOf()))) {
    return "capture item interop unavailable";
  }
  if (FAILED(interop->CreateForWindow(
          g_state.hwnd, __uuidof(WGC::IGraphicsCaptureItem),
          reinterpret_cast<void**>(g_state.item.GetAddressOf()))) ||
      !g_state.item) {
    return "CreateForWindow failed (window not capturable)";
  }
  SizeInt32 size = {};
  if (FAILED(g_state.item->get_Size(&size)) || size.Width <= 0 ||
      size.Height <= 0) {
    return "window has zero size";
  }
  g_state.pool_size = size;

  ComPtr<WGC::IDirect3D11CaptureFramePoolStatics2> pool_statics;
  if (FAILED(GetActivationFactory(
          RuntimeClass_Windows_Graphics_Capture_Direct3D11CaptureFramePool,
          pool_statics.GetAddressOf()))) {
    return "frame pool statics unavailable";
  }
  if (FAILED(pool_statics->CreateFreeThreaded(
          g_state.device.Get(),
          WGDX::DirectXPixelFormat_B8G8R8A8UIntNormalized, 2, size,
          g_state.frame_pool.GetAddressOf())) ||
      !g_state.frame_pool) {
    return "frame pool create failed";
  }
  if (FAILED(g_state.frame_pool->CreateCaptureSession(
          g_state.item.Get(), g_state.session.GetAddressOf()))) {
    return "capture session create failed";
  }
  // 与单帧截图同款：关掉 WGC 合成光标、去掉黄色捕获边框（两者 API 缺失时静默保持
  // 默认——录制是持续过程，单帧那套 diagnostics 在这里没有回传通道）。
  ComPtr<WGC::IGraphicsCaptureSession2> session2;
  if (SUCCEEDED(g_state.session.As(&session2)) && session2) {
    session2->put_IsCursorCaptureEnabled(false);
  }
  ComPtr<WGC::IGraphicsCaptureSession3> session3;
  if (SUCCEEDED(g_state.session.As(&session3)) && session3) {
    session3->put_IsBorderRequired(false);
  }

  // 免线程（agile）委托：FreeThreaded 帧池会在任意线程池线程回调 FrameArrived
  // （FtmBase 聚合，避免 RO_E_MUST_BE_AGILE；与 window_capture.cpp 一致）。
  // **每次回调都必须 TryGetNextFrame 把帧取走**——池子只有 2 个缓冲，不取就堵死。
  auto frame_handler = Callback<Microsoft::WRL::Implements<
      Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
      ABI::Windows::Foundation::ITypedEventHandler<
          WGC::Direct3D11CaptureFramePool*, IInspectable*>,
      Microsoft::WRL::FtmBase>>(
      [](WGC::IDirect3D11CaptureFramePool* pool, IInspectable*) -> HRESULT {
        std::lock_guard<std::mutex> lock(g_state.frame_mutex);
        if (g_state.teardown) {
          return S_OK;
        }
        ComPtr<WGC::IDirect3D11CaptureFrame> frame;
        if (FAILED(pool->TryGetNextFrame(frame.GetAddressOf())) || !frame) {
          return S_OK;
        }
        if (!IsWindow(g_state.hwnd)) {
          CloseIfClosable(frame);
          RecordError("window_closed");
          RequestStop();
          return S_OK;
        }
        HandleFrame(frame.Get());
        CloseIfClosable(frame);
        return S_OK;
      });
  if (FAILED(g_state.frame_pool->add_FrameArrived(frame_handler.Get(),
                                                  &g_state.frame_token))) {
    return "add_FrameArrived failed";
  }
  // 目标窗口销毁：item 的 Closed 事件是权威信号，发停止让录制线程确定性拆会话。
  auto closed_handler = Callback<Microsoft::WRL::Implements<
      Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
      ABI::Windows::Foundation::ITypedEventHandler<WGC::GraphicsCaptureItem*,
                                                   IInspectable*>,
      Microsoft::WRL::FtmBase>>(
      [](WGC::IGraphicsCaptureItem*, IInspectable*) -> HRESULT {
        RecordError("window_closed");
        RequestStop();
        return S_OK;
      });
  if (FAILED(g_state.item->add_Closed(closed_handler.Get(),
                                      &g_state.closed_token))) {
    g_state.frame_pool->remove_FrameArrived(g_state.frame_token);
    g_state.frame_token = {};
    return "add_Closed failed";
  }
  if (FAILED(g_state.session->StartCapture())) {
    g_state.item->remove_Closed(g_state.closed_token);
    g_state.closed_token = {};
    g_state.frame_pool->remove_FrameArrived(g_state.frame_token);
    g_state.frame_token = {};
    return "StartCapture failed";
  }
  return std::string();
}

// 确定性拆会话（录制线程）。先在锁内立 teardown 旗（保证没有回调正在用 D3D /
// 帧池，之后到来的回调直接返回），再**不持锁**做 remove/Close——WinRT 的 Close 可能
// 等在途回调返回，持锁做会和等锁的回调互相死等。
void TeardownCapture() {
  {
    std::lock_guard<std::mutex> lock(g_state.frame_mutex);
    g_state.teardown = true;
  }
  if (g_state.item && g_state.closed_token.value != 0) {
    g_state.item->remove_Closed(g_state.closed_token);
  }
  if (g_state.frame_pool && g_state.frame_token.value != 0) {
    g_state.frame_pool->remove_FrameArrived(g_state.frame_token);
  }
  CloseIfClosable(g_state.session);
  CloseIfClosable(g_state.frame_pool);
  std::lock_guard<std::mutex> lock(g_state.frame_mutex);
  g_state.closed_token = {};
  g_state.frame_token = {};
  g_state.session.Reset();
  g_state.frame_pool.Reset();
  g_state.item.Reset();
  g_state.staging.Reset();
  g_state.wic.Reset();
  g_state.device.Reset();
  g_state.context.Reset();
  g_state.d3d.Reset();
  g_state.has_last = false;
  g_state.last_kept_tick = 0;
  g_state.pool_size = {};
}

void RecorderThreadMain() {
  const HRESULT ro = RoInitialize(RO_INIT_MULTITHREADED);
  std::string error;
  if (FAILED(ro) && ro != RPC_E_CHANGED_MODE) {
    error = "RoInitialize failed";
  } else {
    std::lock_guard<std::mutex> lock(g_state.frame_mutex);
    g_state.teardown = false;
    error = SetupCapture();
  }
  if (!error.empty()) {
    RecordError(error);
    TeardownCapture();
    {
      std::lock_guard<std::mutex> lock(g_state.init_mutex);
      g_state.init_ok = false;
      g_state.init_done = true;
    }
    g_state.init_cv.notify_all();
    if (SUCCEEDED(ro)) {
      RoUninitialize();
    }
    return;
  }
  g_state.recording.store(true);
  {
    std::lock_guard<std::mutex> lock(g_state.init_mutex);
    g_state.init_ok = true;
    g_state.init_done = true;
  }
  g_state.init_cv.notify_all();

  WaitForSingleObject(g_state.stop_event, INFINITE);

  g_state.recording.store(false);
  TeardownCapture();
  {
    std::lock_guard<std::mutex> lock(g_state.ring_mutex);
    g_state.ring.Clear();
  }
  if (SUCCEEDED(ro)) {
    RoUninitialize();
  }
}

// 持 control_mutex：让录制线程停下并回收（幂等；线程已自行结束时只做 join）。
void StopLocked() {
  if (g_state.thread.joinable()) {
    RequestStop();
    g_state.thread.join();
  }
  if (g_state.stop_event != nullptr) {
    CloseHandle(g_state.stop_event);
    g_state.stop_event = nullptr;
  }
  g_state.recording.store(false);
  std::lock_guard<std::mutex> lock(g_state.ring_mutex);
  g_state.ring.Clear();
}

}  // namespace

WindowRecorder& WindowRecorder::Instance() {
  static WindowRecorder instance;
  return instance;
}

WindowRecorder::~WindowRecorder() { Stop(); }

bool WindowRecorder::Start(HWND hwnd, int fps, int max_seconds,
                           int max_width) {
  std::lock_guard<std::mutex> control(g_state.control_mutex);
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    RecordError("window handle invalid");
    return false;
  }
  // BUG-1096：Magpie 缩放窗 -> 源窗口（与单帧截图同一条重定向）。
  if (const HWND source = ResolveScalingSourceWindow(hwnd)) {
    hwnd = source;
  }
  fps = std::max(1, std::min(kMaxFps, fps));
  max_seconds = std::max(1, std::min(kMaxSeconds, max_seconds));
  max_width = std::max(0, max_width);
  if (g_state.recording.load() && g_state.thread.joinable()) {
    bool same = false;
    {
      std::lock_guard<std::mutex> lock(g_state.frame_mutex);
      same = g_state.hwnd == hwnd && g_state.fps == fps &&
             g_state.max_width == max_width &&
             g_state.ring.policy().max_seconds == max_seconds;
    }
    if (same) {
      return true;
    }
  }
  StopLocked();

  {
    std::lock_guard<std::mutex> lock(g_state.frame_mutex);
    g_state.hwnd = hwnd;
    g_state.fps = fps;
    g_state.max_width = max_width;
  }
  {
    RingPolicy policy;
    policy.max_seconds = max_seconds;
    policy.max_bytes = kMaxRingBytes;
    std::lock_guard<std::mutex> lock(g_state.ring_mutex);
    g_state.ring = FrameRing(policy);
  }
  RecordError(std::string());
  g_state.stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (g_state.stop_event == nullptr) {
    RecordError("event create failed");
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(g_state.init_mutex);
    g_state.init_done = false;
    g_state.init_ok = false;
  }
  g_state.thread = std::thread(RecorderThreadMain);
  bool ok = false;
  {
    std::unique_lock<std::mutex> lock(g_state.init_mutex);
    g_state.init_cv.wait(lock, [] { return g_state.init_done; });
    ok = g_state.init_ok;
  }
  if (!ok) {
    StopLocked();
  }
  return ok;
}

void WindowRecorder::Stop() {
  std::lock_guard<std::mutex> control(g_state.control_mutex);
  StopLocked();
}

bool WindowRecorder::IsRecording() const { return g_state.recording.load(); }

std::string WindowRecorder::LastError() const {
  std::lock_guard<std::mutex> lock(g_state.error_mutex);
  return g_state.last_error;
}

WindowRecordingExport WindowRecorder::Export(int64_t from_tick,
                                             int64_t to_tick,
                                             const std::string& directory_utf8) {
  WindowRecordingExport out;
  out.now_tick_ms = GetTickCount64();
  if (!g_state.recording.load()) {
    out.error = "not_recording";
    return out;
  }
  const std::wstring dir = Utf8ToWide(directory_utf8);
  const DWORD attrs = dir.empty() ? INVALID_FILE_ATTRIBUTES
                                  : GetFileAttributesW(dir.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
    out.error = "bad_directory";
    return out;
  }
  const auto range = ResolveExportRange(from_tick, to_tick, out.now_tick_ms);
  std::vector<FrameEntry> frames;
  if (range.valid) {
    std::lock_guard<std::mutex> lock(g_state.ring_mutex);
    frames = g_state.ring.Select(range.from, range.to);
  }
  if (frames.empty()) {
    out.error = "no_frames";
    return out;
  }
  std::string prefix = directory_utf8;
  if (prefix.back() != '\\' && prefix.back() != '/') {
    prefix += '\\';
  }
  int index = 0;
  for (const FrameEntry& f : frames) {
    char name[32];
    _snprintf_s(name, sizeof(name), _TRUNCATE, "frame_%05d.jpg", index++);
    const std::string path = prefix + name;
    if (!WriteWholeFile(Utf8ToWide(path), f.jpeg)) {
      out.frames.clear();
      out.error = "write_failed";
      return out;
    }
    WindowRecordingFrame exported;
    exported.path = path;
    exported.tick_ms = f.tick_ms;
    out.frames.push_back(std::move(exported));
  }
  return out;
}

}  // namespace fushi
