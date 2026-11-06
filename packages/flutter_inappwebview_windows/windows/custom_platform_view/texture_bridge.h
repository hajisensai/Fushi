#pragma once

#include <windows.foundation.h>
#include <windows.graphics.capture.h>
#include <windows.system.h>
#include <wrl.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "graphics_context.h"
#include "../utils/wgc_pacing_probe.h"

namespace flutter_inappwebview_plugin
{
  // TODO-618 fix3: 进程级退出态总闸。
  //
  // 退出（prepareForProcessExit / 关窗）期间，先于 webViews.clear 把此闸置位；之后所有
  // TextureBridge 的 WGC 帧上报回调（frame_available_）一律短路早返回，避免在 compositor /
  // CustomPlatformView 下游对象已开始拆解时再把帧推给 Flutter 引擎，触发退出期
  // Unknown Hard Error。纯防御早返回，不改既有 teardown 顺序。
  //
  // 声明在头文件（external linkage），供 in_app_webview_manager.cpp 在 prepareForProcessExit
  // 入口调用 SetProcessExiting()；定义在 texture_bridge.cc。
  void SetProcessExiting() noexcept;
  bool IsProcessExiting() noexcept;

  using WgcDeliverHandler = ABI::Windows::System::IDispatcherQueueHandler;
  using WgcCaptureItemClosedHandler = ABI::Windows::Foundation::ITypedEventHandler<
    ABI::Windows::Graphics::Capture::GraphicsCaptureItem*, IInspectable*>;

  struct WgcPumpCallbackState;
  struct WgcFramePoolLifetime;

  typedef struct {
    size_t width;
    size_t height;
  } Size;

  // BUG-4114：取帧线程与栅格线程之间的交接箱（桥与取帧线程共同持有）。
  //
  // 取帧线程在帧到达时把 WGC 帧里的有效内容拷进 [staged]（插件设备上的私有纹理，
  // 不共享、不进引擎），然后立刻释放 WGC 帧，帧池缓冲当场还给 DWM；栅格线程的纹理
  // 回调再从 [staged] 拷进交给引擎的、句柄固定的共享纹理。两次拷贝都在插件设备的
  // 同一个立即上下文上（多线程保护已开，见 GraphicsContext），GPU 按提交顺序执行，
  // 读写不会交错。锁序：桥 mutex_ → mailbox mutex；取帧线程只拿 mailbox mutex。
  struct WgcFrameMailbox {
    std::mutex mutex;
    winrt::com_ptr<ID3D11Texture2D> staged;
    UINT staged_width = 0;
    UINT staged_height = 0;
    // staged 里有效内容的尺寸（WGC 帧 ContentSize 与帧纹理取小）。
    ABI::Windows::Graphics::SizeInt32 content = { 0, 0 };
    // 每拷好一帧 +1。平台线程据此判断「有没有没上报过的新帧」。
    uint64_t seq = 0;
    WgcPacingProbe probe;

    explicit WgcFrameMailbox(const void* owner) : probe(owner) {}
  };

  class TextureBridge {
  public:
    typedef std::function<void()> FrameAvailableCallback;
    typedef std::function<void(Size size, float capture_scale_factor,
      float device_scale_factor)>
      SurfaceSizeChangedCallback;
    typedef std::chrono::duration<double, std::milli> FrameDuration;

    TextureBridge(GraphicsContext* graphics_context,
      ABI::Windows::UI::Composition::IVisual* visual);
    virtual ~TextureBridge();

    bool Start();
    void Stop();

    // 平台线程调用；frame_available_ 只在平台线程读（DeliverFrameLocked），与写同线程。
    void SetOnFrameAvailable(FrameAvailableCallback callback)
    {
      frame_available_ = std::move(callback);
    }

    void SetOnSurfaceSizeChanged(SurfaceSizeChangedCallback callback)
    {
      const std::lock_guard<std::mutex> lock(mutex_);
      surface_size_changed_ = std::move(callback);
    }

    // Flutter 平台视图的逻辑尺寸与 DPI。GPU bridge 会原子记录换算后的目标物理
    // 像素尺寸，再用回调驱动 WebView2 surface；WGC 的尺寸通知不会反写目标尺寸。
    //
    // BUG-3913：[capacity] 是 Dart 侧算好的纹理容量（物理像素，只增不减，见
    // texture_capacity.dart）。WGC 帧池与共享目标纹理都按它分配，布局在容量内变化
    // 时既不重建帧池也不换共享句柄——两者每换一次都会在系统 / 引擎侧留下一份
    // 永不归还的显存。{0,0} = 旧协议（Dart 未给容量），退回贴身分配。
    virtual void SetOutputSize(size_t width, size_t height, float scale_factor,
      Size capacity)
    {
      if (width == 0 || height == 0 || scale_factor <= 0.0f) {
        return;
      }

      SurfaceSizeChangedCallback callback;
      {
        const std::lock_guard<std::mutex> lock(mutex_);
        if (requested_surface_size_.width == width &&
          requested_surface_size_.height == height &&
          requested_scale_factor_ == scale_factor &&
          capacity_.width == capacity.width &&
          capacity_.height == capacity.height) {
          return;
        }
        requested_surface_size_ = { width, height };
        requested_scale_factor_ = scale_factor;
        capacity_ = capacity;
        // 无着色器桥：捕获倍率恒等于设备倍率（回调里两个倍率传同一个值）。
        capture_scale_ratio_ = 1.0f;
        callback = surface_size_changed_;
      }
      if (callback) {
        callback({ width, height }, scale_factor, scale_factor);
      }
    }

    void NotifySurfaceSizeChanged(size_t width, size_t height);
    void SetFpsLimit(std::optional<int> max_fps);

    // 计划 P2：mpv 用户着色器链（.glsl 文本，按序）。空 = 直通。只有 GPU 桥实现；
    // 回 true = 全部解析成功并已启用。
    virtual bool SetShaders(const std::vector<std::string>& shader_texts) { return false; }

    // 平台线程上的帧上报（取帧线程经 DispatcherQueue 投递过来）。public 只为让投递
    // 回调（texture_bridge.cc 匿名命名空间）能调到；外部不要直接调。
    void DeliverFrameLocked(const std::shared_ptr<WgcFramePoolLifetime>& lifetime);

  protected:
    typedef WgcCaptureItemClosedHandler CaptureItemClosedHandler;

    // 栅格线程（纹理回调，持 mutex_）读最新一份已拷好的帧。返回的锁在调用方用完
    // texture 之前一直持有，取帧线程这期间不会覆写它。texture 为空 = 还没有帧。
    struct StagedFrame {
      std::unique_lock<std::mutex> lock;
      ID3D11Texture2D* texture = nullptr;
      ABI::Windows::Graphics::SizeInt32 content = { 0, 0 };
    };
    StagedFrame AcquireStagedFrame();

    bool is_running_ = false;

    const GraphicsContext* graphics_context_;
    std::mutex mutex_;
    std::optional<FrameDuration> frame_duration_ = std::nullopt;

    FrameAvailableCallback frame_available_;
    SurfaceSizeChangedCallback surface_size_changed_;
    Size requested_surface_size_ = { 0, 0 };
    float requested_scale_factor_ = 0.0f;
    // BUG-3913：纹理 / 帧池容量（物理像素），见 SetOutputSize。
    Size capacity_ = { 0, 0 };
    // 捕获倍率 / 设备倍率（0, 1]。capacity_ 是设备倍率下的物理像素（共享目标纹理按它
    // 分配），而 WGC 捕获的是 WebView2 按捕获倍率栅格化的 visual：着色器链开着时捕获
    // 倍率 = 设备倍率 / 2，捕获源只有容量的一半宽高。帧池按「容量 × 本比值」分配，
    // 不能直接拿设备倍率的容量（那是 4 倍面积的空帧池缓冲）。
    float capture_scale_ratio_ = 1.0f;
    std::atomic<bool> needs_update_ = false;
    std::shared_ptr<WgcFrameMailbox> mailbox_;
    // 平台线程上一次上报给 Flutter 的 mailbox seq。
    uint64_t delivered_seq_ = 0;
    std::optional<std::chrono::high_resolution_clock::time_point>
      last_frame_timestamp_;

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>
      capture_item_;
    Microsoft::WRL::ComPtr<CaptureItemClosedHandler>
      capture_item_closed_handler_;
    std::shared_ptr<WgcFramePoolLifetime> frame_pool_lifetime_;
    uint64_t frame_pool_generation_ = 0;

    EventRegistrationToken on_closed_token_ = {};

    void InvalidatePumpCallback(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime = nullptr);
    virtual void StopInternal();
    // BUG-4114：默认 WGC 捕获不订阅 FrameArrived，取帧在每个帧池自己的取帧线程上
    // 按合成器时钟拉。所有丢弃 / 替换帧池的路径都先失效平台线程上报状态、停并 join
    // 取帧线程，再 Close session / pool，最后退役 lifetime。
    void RetireFramePoolLocked(const char* reason);
    bool CreateAndStartFramePoolLocked();
    // 回 true = 真的退役并重建了帧池（本轮不再上报）；当前帧池放得下捕获源
    // 与容量时原样保留、回 false。
    bool RecreateFramePoolLocked();
    // BUG-3913：帧池尺寸 = 捕获源尺寸与「捕获倍率下的容量」逐维取大。
    ABI::Windows::Graphics::SizeInt32 FramePoolSizeFor(
      ABI::Windows::Graphics::SizeInt32 item_size) const;
    bool StartFrameWorkerLocked(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime);
    void StopFrameWorkerLocked(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime, const char* reason);
    // 向平台线程投递一次上报检查（尺寸变化后也用它让 needs_update_ 及时生效）。
    void PostDeliveryLocked(const std::shared_ptr<WgcFramePoolLifetime>& lifetime);
    bool ShouldDropFrame();

    // corresponds to DXGI_FORMAT_B8G8R8A8_UNORM
    static constexpr auto kPixelFormat = ABI::Windows::Graphics::DirectX::
      DirectXPixelFormat::DirectXPixelFormat_B8G8R8A8UIntNormalized;
  };
}
