#include "game_stream_webrtc_capture.h"
#include "game_stream_webrtc_capture_helpers.h"

#include <windows.h>

#include <d3d11.h>
#include <roapi.h>

#include <windows.foundation.h>
#include <windows.graphics.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.h>
#include <windows.graphics.directx.direct3d11.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <wrl/client.h>
#include <wrl/event.h>

#include "rtc_video_frame.h"
#include "wgc_interop.h"
#include "window_capture.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace flutter_webrtc_plugin {
namespace {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
namespace WGC = ABI::Windows::Graphics::Capture;
namespace WGDX = ABI::Windows::Graphics::DirectX;
namespace WGDXD3D = ABI::Windows::Graphics::DirectX::Direct3D11;
using ABI::Windows::Graphics::SizeInt32;
using fushi::ComputeClientCropBox;
using fushi::CreateD3DDevice;
using fushi::wgc::CloseIfClosable;
using fushi::wgc::GetActivationFactory;
using fushi::wgc::IDxgiInterfaceAccessLocal;
using libwebrtc::RTCVideoFrame;
using libwebrtc::RTCVideoSource;
using libwebrtc::scoped_refptr;


class FushiGameStreamCaptureImpl : public FushiGameStreamCapture {
 public:
  FushiGameStreamCaptureImpl(HWND hwnd, scoped_refptr<RTCVideoSource> source,
                             int fps, int max_width, int max_height)
      : hwnd_(hwnd),
        source_(std::move(source)),
        fps_(ClampCaptureFps(fps)),
        max_width_(ClampCaptureMaxWidth(max_width)),
        max_height_(ClampCaptureMaxHeight(max_height)) {}

  ~FushiGameStreamCaptureImpl() override { Stop(); }

  bool Start(std::string* error) {
    if (hwnd_ == nullptr || !IsWindow(hwnd_)) {
      SetError("window handle invalid");
      if (error) *error = error_;
      return false;
    }
    if (!source_) {
      SetError("video source missing");
      if (error) *error = error_;
      return false;
    }
    stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (stop_event_ == nullptr) {
      SetError("event create failed");
      if (error) *error = error_;
      return false;
    }
    {
      std::lock_guard<std::mutex> lock(init_mutex_);
      init_done_ = false;
      init_ok_ = false;
    }
    thread_ = std::thread([this] { ThreadMain(); });
    bool ok = false;
    {
      std::unique_lock<std::mutex> lock(init_mutex_);
      init_cv_.wait(lock, [this] { return init_done_; });
      ok = init_ok_;
    }
    if (!ok) {
      Stop();
      if (error) *error = error_;
      return false;
    }
    {
      std::unique_lock<std::mutex> lock(first_frame_mutex_);
      ok = first_frame_cv_.wait_for(lock, std::chrono::seconds(5),
                                    [this] { return first_frame_ready_; });
    }
    if (!ok) {
      {
        std::lock_guard<std::mutex> lock(error_mutex_);
        if (error_.empty()) {
          error_ = "first frame timeout";
        }
      }
      Stop();
      if (error) *error = error_;
      return false;
    }
    if (error) error->clear();
    return true;
  }

  void Stop() override {
    HANDLE event = stop_event_;
    if (event != nullptr) {
      SetEvent(event);
    }
    if (thread_.joinable()) {
      thread_.join();
    }
    if (stop_event_ != nullptr) {
      CloseHandle(stop_event_);
      stop_event_ = nullptr;
    }
    running_.store(false);
  }

  bool IsRunning() const override { return running_.load(); }

  int width() const override {
    std::lock_guard<std::mutex> lock(size_mutex_);
    return output_width_;
  }

  int height() const override {
    std::lock_guard<std::mutex> lock(size_mutex_);
    return output_height_;
  }

  std::string error() const override {
    std::lock_guard<std::mutex> lock(error_mutex_);
    return error_;
  }

 private:
  struct CallbackGate {
    std::mutex mutex;
    std::condition_variable drained;
    FushiGameStreamCaptureImpl* owner = nullptr;
    int in_flight = 0;
  };

  class CallbackLease {
   public:
    explicit CallbackLease(const std::weak_ptr<CallbackGate>& weak_gate) {
      gate_ = weak_gate.lock();
      if (!gate_) return;
      std::lock_guard<std::mutex> lock(gate_->mutex);
      if (gate_->owner == nullptr) {
        return;
      }
      owner_ = gate_->owner;
      ++gate_->in_flight;
    }

    CallbackLease(const CallbackLease&) = delete;
    CallbackLease& operator=(const CallbackLease&) = delete;

    ~CallbackLease() {
      if (!gate_ || owner_ == nullptr) return;
      std::lock_guard<std::mutex> lock(gate_->mutex);
      --gate_->in_flight;
      if (gate_->in_flight == 0) {
        gate_->drained.notify_all();
      }
    }

    FushiGameStreamCaptureImpl* owner() const { return owner_; }

   private:
    std::shared_ptr<CallbackGate> gate_;
    FushiGameStreamCaptureImpl* owner_ = nullptr;
  };

  void AttachCallbackGate() {
    std::lock_guard<std::mutex> lock(callback_gate_->mutex);
    callback_gate_->owner = this;
  }

  void DetachCallbackGate() {
    std::unique_lock<std::mutex> lock(callback_gate_->mutex);
    callback_gate_->owner = nullptr;
    callback_gate_->drained.wait(lock, [this] {
      return callback_gate_->in_flight == 0;
    });
  }

  void SetError(const std::string& value) {
    std::lock_guard<std::mutex> lock(error_mutex_);
    error_ = value;
  }

  void RequestStop(const std::string& reason) {
    if (!reason.empty()) SetError(reason);
    if (stop_event_ != nullptr) SetEvent(stop_event_);
  }

  std::string SetupCaptureLocked() {
    ComPtr<WGC::IGraphicsCaptureSessionStatics> session_statics;
    if (FAILED(GetActivationFactory(
            RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureSession,
            session_statics.GetAddressOf()))) {
      return "graphics capture unavailable";
    }
    boolean supported = false;
    session_statics->IsSupported(&supported);
    if (!supported) return "graphics capture not supported";

    d3d_ = CreateD3DDevice();
    if (!d3d_) return "D3D11 device create failed";
    d3d_->GetImmediateContext(context_.GetAddressOf());
    ComPtr<IDXGIDevice> dxgi;
    if (FAILED(d3d_.As(&dxgi))) return "IDXGIDevice query failed";
    ComPtr<IInspectable> inspectable;
    if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(),
                                                    inspectable.GetAddressOf()))) {
      return "CreateDirect3D11DeviceFromDXGIDevice failed";
    }
    if (FAILED(inspectable.As(&device_))) return "IDirect3DDevice query failed";

    ComPtr<IGraphicsCaptureItemInterop> interop;
    if (FAILED(GetActivationFactory(
            RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureItem,
            interop.GetAddressOf()))) {
      return "capture item interop unavailable";
    }
    if (FAILED(interop->CreateForWindow(
            hwnd_, __uuidof(WGC::IGraphicsCaptureItem),
            reinterpret_cast<void**>(item_.GetAddressOf()))) ||
        !item_) {
      return "CreateForWindow failed";
    }
    SizeInt32 size = {};
    if (FAILED(item_->get_Size(&size)) || size.Width <= 0 || size.Height <= 0) {
      return "window has zero size";
    }
    pool_size_ = size;

    ComPtr<WGC::IDirect3D11CaptureFramePoolStatics2> pool_statics;
    if (FAILED(GetActivationFactory(
            RuntimeClass_Windows_Graphics_Capture_Direct3D11CaptureFramePool,
            pool_statics.GetAddressOf()))) {
      return "frame pool statics unavailable";
    }
    if (FAILED(pool_statics->CreateFreeThreaded(
            device_.Get(), WGDX::DirectXPixelFormat_B8G8R8A8UIntNormalized, 2,
            size, frame_pool_.GetAddressOf())) ||
        !frame_pool_) {
      return "frame pool create failed";
    }
    if (FAILED(frame_pool_->CreateCaptureSession(item_.Get(),
                                                 session_.GetAddressOf()))) {
      return "capture session create failed";
    }
    ComPtr<WGC::IGraphicsCaptureSession2> session2;
    if (SUCCEEDED(session_.As(&session2)) && session2) {
      session2->put_IsCursorCaptureEnabled(false);
    }
    ComPtr<WGC::IGraphicsCaptureSession3> session3;
    if (SUCCEEDED(session_.As(&session3)) && session3) {
      session3->put_IsBorderRequired(false);
    }

    const std::weak_ptr<CallbackGate> weak_gate = callback_gate_;
    auto frame_handler = Callback<Microsoft::WRL::Implements<
        Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
        ABI::Windows::Foundation::ITypedEventHandler<
            WGC::Direct3D11CaptureFramePool*, IInspectable*>,
        Microsoft::WRL::FtmBase>>(
        [weak_gate](WGC::IDirect3D11CaptureFramePool* pool,
                    IInspectable*) -> HRESULT {
          CallbackLease lease(weak_gate);
          if (lease.owner() == nullptr) return S_OK;
          return lease.owner()->OnFrameArrived(pool);
        });
    if (FAILED(frame_pool_->add_FrameArrived(frame_handler.Get(),
                                            &frame_token_))) {
      return "add_FrameArrived failed";
    }

    auto closed_handler = Callback<Microsoft::WRL::Implements<
        Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
        ABI::Windows::Foundation::ITypedEventHandler<WGC::GraphicsCaptureItem*,
                                                     IInspectable*>,
        Microsoft::WRL::FtmBase>>(
        [weak_gate](WGC::IGraphicsCaptureItem*, IInspectable*) -> HRESULT {
          CallbackLease lease(weak_gate);
          if (lease.owner() != nullptr) lease.owner()->RequestStop("window_closed");
          return S_OK;
        });
    if (FAILED(item_->add_Closed(closed_handler.Get(), &closed_token_))) {
      return "add_Closed failed";
    }
    if (FAILED(session_->StartCapture())) {
      return "StartCapture failed";
    }
    return std::string();
  }

  HRESULT OnFrameArrived(WGC::IDirect3D11CaptureFramePool* pool) {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    if (teardown_) return S_OK;
    ComPtr<WGC::IDirect3D11CaptureFrame> frame;
    if (FAILED(pool->TryGetNextFrame(frame.GetAddressOf())) || !frame) {
      return S_OK;
    }
    if (!IsWindow(hwnd_)) {
      CloseIfClosable(frame);
      RequestStop("window_closed");
      return S_OK;
    }
    HandleFrameLocked(frame.Get());
    CloseIfClosable(frame);
    return S_OK;
  }

  void TeardownCapture() {
    {
      std::lock_guard<std::mutex> lock(frame_mutex_);
      teardown_ = true;
    }
    DetachCallbackGate();
    if (item_ && closed_token_.value != 0) {
      item_->remove_Closed(closed_token_);
    }
    if (frame_pool_ && frame_token_.value != 0) {
      frame_pool_->remove_FrameArrived(frame_token_);
    }
    CloseIfClosable(session_);
    CloseIfClosable(frame_pool_);
    std::lock_guard<std::mutex> lock(frame_mutex_);
    closed_token_ = {};
    frame_token_ = {};
    session_.Reset();
    frame_pool_.Reset();
    item_.Reset();
    staging_.Reset();
    device_.Reset();
    context_.Reset();
    d3d_.Reset();
    pool_size_ = {};
    has_last_ = false;
    last_frame_time_ = std::chrono::steady_clock::time_point{};
  }

  bool ShouldKeep(std::chrono::steady_clock::time_point now) {
    const auto interval = std::chrono::microseconds(
        (1000000LL + static_cast<long long>(fps_) - 1) /
        static_cast<long long>(fps_));
    if (!has_last_ || now - last_frame_time_ >= interval) {
      has_last_ = true;
      last_frame_time_ = now;
      return true;
    }
    return false;
  }

  void HandleFrameLocked(WGC::IDirect3D11CaptureFrame* frame) {
    SizeInt32 content = {};
    if (FAILED(frame->get_ContentSize(&content)) || content.Width <= 0 ||
        content.Height <= 0) {
      return;
    }
    const auto now = std::chrono::steady_clock::now();
    if (!ShouldKeep(now)) {
      RecreatePoolIfNeeded(content);
      return;
    }

    ComPtr<WGDXD3D::IDirect3DSurface> surface;
    ComPtr<IDxgiInterfaceAccessLocal> access;
    ComPtr<ID3D11Texture2D> texture;
    if (FAILED(frame->get_Surface(surface.GetAddressOf())) ||
        FAILED(surface.As(&access)) ||
        FAILED(access->GetInterface(__uuidof(ID3D11Texture2D),
                                    reinterpret_cast<void**>(
                                        texture.GetAddressOf()))) ||
        !texture) {
      RecreatePoolIfNeeded(content);
      return;
    }
    D3D11_TEXTURE2D_DESC desc = {};
    texture->GetDesc(&desc);
    D3D11_TEXTURE2D_DESC staging_desc = {};
    if (staging_) staging_->GetDesc(&staging_desc);
    if (!staging_ || staging_desc.Width != desc.Width ||
        staging_desc.Height != desc.Height || staging_desc.Format != desc.Format) {
      staging_desc = desc;
      staging_desc.Usage = D3D11_USAGE_STAGING;
      staging_desc.BindFlags = 0;
      staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      staging_desc.MiscFlags = 0;
      staging_.Reset();
      d3d_->CreateTexture2D(&staging_desc, nullptr, staging_.GetAddressOf());
    }
    if (!staging_) {
      RecreatePoolIfNeeded(content);
      return;
    }
    context_->CopyResource(staging_.Get(), texture.Get());
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    if (FAILED(context_->Map(staging_.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
      RecreatePoolIfNeeded(content);
      return;
    }

    const UINT valid_w = std::min<UINT>(desc.Width, static_cast<UINT>(content.Width));
    const UINT valid_h = std::min<UINT>(desc.Height, static_cast<UINT>(content.Height));
    RECT crop{};
    if (!ComputeClientCropBox(hwnd_, valid_w, valid_h, &crop)) {
      context_->Unmap(staging_.Get(), 0);
      RequestStop("client_area_unavailable");
      RecreatePoolIfNeeded(content);
      return;
    }
    const uint32_t crop_w = static_cast<uint32_t>(crop.right - crop.left);
    const uint32_t crop_h = static_cast<uint32_t>(crop.bottom - crop.top);
    const OutputSize out =
        FitInsideEven(crop_w, crop_h, max_width_, max_height_);
    std::vector<uint8_t> y;
    std::vector<uint8_t> u;
    std::vector<uint8_t> v;
    const bool converted = out.width > 0 && out.height > 0 &&
        ConvertBgraToI420(static_cast<const uint8_t*>(mapped.pData),
                          mapped.RowPitch, static_cast<uint32_t>(crop.left),
                          static_cast<uint32_t>(crop.top), crop_w, crop_h,
                          out.width, out.height, &y, &u, &v);
    context_->Unmap(staging_.Get(), 0);

    if (converted && source_) {
      scoped_refptr<RTCVideoFrame> video_frame = RTCVideoFrame::Create(
          static_cast<int>(out.width), static_cast<int>(out.height), y.data(),
          static_cast<int>(out.width), u.data(), static_cast<int>(out.width / 2),
          v.data(), static_cast<int>(out.width / 2));
      if (video_frame) {
        {
          std::lock_guard<std::mutex> lock(size_mutex_);
          output_width_ = static_cast<int>(out.width);
          output_height_ = static_cast<int>(out.height);
        }
        source_->OnCapturedFrame(video_frame);
        {
          std::lock_guard<std::mutex> lock(first_frame_mutex_);
          first_frame_ready_ = true;
        }
        first_frame_cv_.notify_all();
      }
    }
    RecreatePoolIfNeeded(content);
  }

  void RecreatePoolIfNeeded(const SizeInt32& content) {
    if (frame_pool_ && device_ &&
        (content.Width != pool_size_.Width || content.Height != pool_size_.Height)) {
      if (SUCCEEDED(frame_pool_->Recreate(
              device_.Get(), WGDX::DirectXPixelFormat_B8G8R8A8UIntNormalized,
              2, content))) {
        pool_size_ = content;
      }
    }
  }

  void ThreadMain() {
    const HRESULT ro = RoInitialize(RO_INIT_MULTITHREADED);
    std::string error;
    if (FAILED(ro) && ro != RPC_E_CHANGED_MODE) {
      error = "RoInitialize failed";
    } else {
      std::lock_guard<std::mutex> lock(frame_mutex_);
      teardown_ = false;
      AttachCallbackGate();
      error = SetupCaptureLocked();
    }
    if (!error.empty()) {
      SetError(error);
      TeardownCapture();
      {
        std::lock_guard<std::mutex> lock(init_mutex_);
        init_ok_ = false;
        init_done_ = true;
      }
      init_cv_.notify_all();
      if (SUCCEEDED(ro)) RoUninitialize();
      return;
    }
    running_.store(true);
    {
      std::lock_guard<std::mutex> lock(init_mutex_);
      init_ok_ = true;
      init_done_ = true;
    }
    init_cv_.notify_all();

    WaitForSingleObject(stop_event_, INFINITE);
    running_.store(false);
    TeardownCapture();
    if (SUCCEEDED(ro)) RoUninitialize();
  }

  HWND hwnd_ = nullptr;
  scoped_refptr<RTCVideoSource> source_;
  int fps_ = 60;
  uint32_t max_width_ = kCaptureDefaultMaxWidth;
  uint32_t max_height_ = kCaptureDefaultMaxHeight;
  HANDLE stop_event_ = nullptr;
  std::thread thread_;
  std::atomic<bool> running_{false};

  mutable std::mutex error_mutex_;
  std::string error_;
  mutable std::mutex size_mutex_;
  int output_width_ = 0;
  int output_height_ = 0;
  std::mutex init_mutex_;
  std::condition_variable init_cv_;
  bool init_done_ = false;
  bool init_ok_ = false;
  std::mutex first_frame_mutex_;
  std::condition_variable first_frame_cv_;
  bool first_frame_ready_ = false;

  std::shared_ptr<CallbackGate> callback_gate_ = std::make_shared<CallbackGate>();
  std::mutex frame_mutex_;
  bool teardown_ = false;
  ComPtr<ID3D11Device> d3d_;
  ComPtr<ID3D11DeviceContext> context_;
  ComPtr<WGDXD3D::IDirect3DDevice> device_;
  ComPtr<WGC::IGraphicsCaptureItem> item_;
  ComPtr<WGC::IDirect3D11CaptureFramePool> frame_pool_;
  ComPtr<WGC::IGraphicsCaptureSession> session_;
  ComPtr<ID3D11Texture2D> staging_;
  SizeInt32 pool_size_ = {};
  EventRegistrationToken frame_token_ = {};
  EventRegistrationToken closed_token_ = {};
  bool has_last_ = false;
  std::chrono::steady_clock::time_point last_frame_time_{};
};

}  // namespace

std::shared_ptr<FushiGameStreamCapture> StartFushiGameStreamCapture(
    HWND hwnd, scoped_refptr<RTCVideoSource> source, int fps, int max_width,
    int max_height, std::string* error) {
  auto capture = std::make_shared<FushiGameStreamCaptureImpl>(
      hwnd, source, fps, max_width, max_height);
  if (!capture->Start(error)) {
    return nullptr;
  }
  return capture;
}

}  // namespace flutter_webrtc_plugin
