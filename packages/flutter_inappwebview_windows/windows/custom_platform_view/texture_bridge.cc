#include "texture_bridge.h"

#include <windows.foundation.h>
#include <winrt/base.h>

#include <atomic>
#include <cassert>
#include <cstdio>
#include <initializer_list>
#include <iostream>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "util/direct3d11.interop.h"
#include "../utils/wgc_log.h"

namespace flutter_inappwebview_plugin
{
  const int kNumBuffers = 1;
  const int kMaxFramesPerPump = 4;
  const int64_t kPumpInterval100ns = 166667; // ~60Hz

  struct WgcPumpCallbackState {
    std::mutex mutex;
    TextureBridge* bridge = nullptr;
    std::weak_ptr<WgcFramePoolLifetime> lifetime;
    uint64_t generation = 0;
    bool active = false;
    bool retiring = false;
    bool in_handler = false;
    bool late_noop_logged = false;
  };

  struct WgcFramePoolLifetime {
    uint64_t generation = 0;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      frame_pool;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureSession>
      capture_session;
    winrt::com_ptr<ABI::Windows::System::IDispatcherQueue> dispatcher_queue;
    winrt::com_ptr<ABI::Windows::System::IDispatcherQueueTimer> pump_timer;
    Microsoft::WRL::ComPtr<WgcPumpTickHandler> pump_tick_handler;
    EventRegistrationToken on_tick_token = {};
    std::shared_ptr<WgcPumpCallbackState> pump_state;
    ABI::Windows::Graphics::SizeInt32 size = { -1, -1 };
    bool registry_retired = false;
    bool inactive = false;
    bool retiring = false;
    bool tick_removed = false;
    bool pump_stopped = false;
    bool session_closed = false;
    bool pool_closed = false;
    bool first_frame_logged = false;
    bool noop_logged = false;

    const void* PoolForLog() const
    {
      return frame_pool.get();
    }
  };

  namespace
  {
    std::string HResultDetail(const char* label, HRESULT hr)
    {
      char buffer[64];
      std::snprintf(buffer, sizeof(buffer), "%s=0x%08lX", label,
        static_cast<unsigned long>(hr));
      return std::string(buffer);
    }

    std::string GenerationDetail(uint64_t generation)
    {
      char buffer[64];
      std::snprintf(buffer, sizeof(buffer), "generation=%llu",
        static_cast<unsigned long long>(generation));
      return std::string(buffer);
    }

    std::string PointerDetail(const char* label, const void* pointer)
    {
      char buffer[96];
      std::snprintf(buffer, sizeof(buffer), "%s=0x%llx", label,
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(pointer)));
      return std::string(buffer);
    }

    std::string BoolDetail(const char* label, bool value)
    {
      return std::string(label) + (value ? "=1" : "=0");
    }

    std::string SizeDetail(const char* label,
      ABI::Windows::Graphics::SizeInt32 size)
    {
      char buffer[96];
      std::snprintf(buffer, sizeof(buffer), "%s=%dx%d", label,
        static_cast<int>(size.Width), static_cast<int>(size.Height));
      return std::string(buffer);
    }

    std::string SizeDetail(const char* label, size_t width, size_t height)
    {
      char buffer[96];
      std::snprintf(buffer, sizeof(buffer), "%s=%zux%zu", label, width, height);
      return std::string(buffer);
    }

    std::string JoinDetails(std::initializer_list<std::string> parts)
    {
      std::string detail;
      for (const auto& part : parts) {
        if (part.empty()) {
          continue;
        }
        if (!detail.empty()) {
          detail += ' ';
        }
        detail += part;
      }
      return detail;
    }

    ABI::Windows::Graphics::SizeInt32 CaptureItemSize(
      ABI::Windows::Graphics::Capture::IGraphicsCaptureItem* capture_item)
    {
      ABI::Windows::Graphics::SizeInt32 size = { -1, -1 };
      if (capture_item) {
        capture_item->get_Size(&size);
      }
      return size;
    }

    std::string BridgeStateDetail(const TextureBridge* bridge,
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime,
      ABI::Windows::Graphics::SizeInt32 capture_item_size,
      bool is_running,
      bool needs_update)
    {
      const uint64_t generation = lifetime ? lifetime->generation : 0;
      ABI::Windows::Graphics::SizeInt32 pool_size = { -1, -1 };
      if (lifetime) {
        pool_size = lifetime->size;
      }
      return JoinDetails({
        GenerationDetail(generation),
        SizeDetail("pool_size", pool_size),
        SizeDetail("capture_item_size", capture_item_size),
        BoolDetail("running", is_running),
        BoolDetail("needs_update", needs_update),
        PointerDetail("bridge", bridge),
      });
    }

    std::string FrameHandlerDetail(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime,
      bool in_handler,
      bool retiring,
      bool has_frame,
      bool needs_update)
    {
      const uint64_t generation = lifetime ? lifetime->generation : 0;
      return JoinDetails({
        GenerationDetail(generation),
        BoolDetail("in_handler", in_handler),
        BoolDetail("retiring", retiring),
        BoolDetail("has_frame", has_frame),
        BoolDetail("needs_update", needs_update),
      });
    }

    std::string ReasonDetail(const char* reason)
    {
      return std::string("reason=") + (reason ? reason : "unknown");
    }

    std::string RegistryCountsDetail(size_t active_count, size_t retired_count)
    {
      char buffer[96];
      std::snprintf(buffer, sizeof(buffer), "active=%zu retired=%zu",
        active_count, retired_count);
      return std::string(buffer);
    }

    class FramePoolLifetimeRegistry {
    public:
      static FramePoolLifetimeRegistry& Instance()
      {
        static FramePoolLifetimeRegistry instance;
        return instance;
      }

      void Retain(const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
      {
        if (!lifetime) {
          return;
        }
        const std::lock_guard<std::mutex> lock(mutex_);
        lifetimes_.push_back(lifetime);
        WgcLog::Write("registry-size", lifetime->PoolForLog(),
          RegistryCountsDetail(ActiveCountLocked(), RetiredCountLocked()));
      }

      void MarkRetired(const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
      {
        if (!lifetime) {
          return;
        }
        const std::lock_guard<std::mutex> lock(mutex_);
        lifetime->registry_retired = true;
        WgcLog::Write("registry-size", lifetime->PoolForLog(),
          RegistryCountsDetail(ActiveCountLocked(), RetiredCountLocked()));
      }

    private:
      FramePoolLifetimeRegistry() = default;

      size_t ActiveCountLocked() const
      {
        size_t count = 0;
        for (const auto& lifetime : lifetimes_) {
          if (lifetime && !lifetime->registry_retired) {
            ++count;
          }
        }
        return count;
      }

      size_t RetiredCountLocked() const
      {
        size_t count = 0;
        for (const auto& lifetime : lifetimes_) {
          if (lifetime && lifetime->registry_retired) {
            ++count;
          }
        }
        return count;
      }

      std::mutex mutex_;
      std::vector<std::shared_ptr<WgcFramePoolLifetime>> lifetimes_;
    };

    void FinalizeFramePoolLifetime(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime);
  }  // namespace

  TextureBridge::TextureBridge(GraphicsContext* graphics_context,
    ABI::Windows::UI::Composition::IVisual* visual)
    : graphics_context_(graphics_context)
  {
    capture_item_ =
      graphics_context_->CreateGraphicsCaptureItemFromVisual(visual);
    assert(capture_item_);

    capture_item_closed_handler_ =
      Microsoft::WRL::Callback<CaptureItemClosedHandler>(
        [](ABI::Windows::Graphics::Capture::IGraphicsCaptureItem* item,
          IInspectable* args) -> HRESULT
        {
          std::cerr << "Capture item was closed." << std::endl;
          return S_OK;
        });
    capture_item_->add_Closed(capture_item_closed_handler_.Get(),
      &on_closed_token_);
    WgcLog::Write("create-bridge", this);
  }

  TextureBridge::~TextureBridge()
  {
    WgcLog::Write("dtor-enter", this);
    InvalidatePumpCallback();
    const std::lock_guard<std::mutex> lock(mutex_);
    StopInternal();
    if (capture_item_) {
      capture_item_->remove_Closed(on_closed_token_);
    }
    capture_item_closed_handler_ = nullptr;
    WgcLog::Write("dtor-exit", this);
  }

  bool TextureBridge::Start()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    const auto lifetime = frame_pool_lifetime_;
    const auto capture_item_size = CaptureItemSize(capture_item_.get());
    const bool needs_update = needs_update_.load();
    if (is_running_) {
      WgcLog::Write("start-skip-running",
        lifetime ? lifetime->PoolForLog() : nullptr,
        BridgeStateDetail(this, lifetime, capture_item_size, is_running_,
          needs_update));
      return false;
    }
    if (!capture_item_) {
      WgcLog::Write("start-skip-noitem", nullptr,
        BridgeStateDetail(this, lifetime, capture_item_size, is_running_,
          needs_update));
      return false;
    }
    WgcLog::Write("start",
      lifetime ? lifetime->PoolForLog() : nullptr,
      BridgeStateDetail(this, lifetime, capture_item_size, is_running_,
        needs_update));

    RetireFramePoolLocked("start");

    if (!CreateAndStartFramePoolLocked()) {
      is_running_ = false;
      return false;
    }
    return true;
  }

  bool TextureBridge::CreateAndStartFramePoolLocked()
  {
    ABI::Windows::Graphics::SizeInt32 size;
    capture_item_->get_Size(&size);
    auto lifetime = std::make_shared<WgcFramePoolLifetime>();
    lifetime->generation = ++frame_pool_generation_;
    lifetime->size = size;
    lifetime->dispatcher_queue =
      graphics_context_->GetDispatcherQueueForCurrentThread();

    lifetime->frame_pool = graphics_context_->CreateCaptureFramePool(
      graphics_context_->device(),
      static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(
        kPixelFormat),
      kNumBuffers, size);
    assert(lifetime->frame_pool);

    WgcLog::Write("create-pool", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));
    FramePoolLifetimeRegistry::Instance().Retain(lifetime);
    WgcLog::Write("active-retain", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));

    frame_pool_lifetime_ = lifetime;

    if (FAILED(lifetime->frame_pool->CreateCaptureSession(capture_item_.get(),
      lifetime->capture_session.put()))) {
      std::cerr << "Creating capture session failed." << std::endl;
      WgcLog::Write("createSession-fail", lifetime->PoolForLog(),
        GenerationDetail(lifetime->generation));
      RetireFramePoolLocked("createSession-fail");
      return false;
    }

    const bool started = SUCCEEDED(lifetime->capture_session->StartCapture());
    if (!started) {
      WgcLog::Write("startCapture-fail", lifetime->PoolForLog(),
        GenerationDetail(lifetime->generation));
      RetireFramePoolLocked("startCapture-fail");
      return false;
    }

    is_running_ = true;
    if (!StartPumpLocked(lifetime)) {
      RetireFramePoolLocked("pump-start-fail");
      is_running_ = false;
      return false;
    }
    return true;
  }

  void TextureBridge::RecreateFramePoolLocked()
  {
    ABI::Windows::Graphics::SizeInt32 current_size = { 0, 0 };
    const auto lifetime = frame_pool_lifetime_;
    if (capture_item_ && SUCCEEDED(capture_item_->get_Size(&current_size)) &&
      lifetime && lifetime->frame_pool &&
      current_size.Width == lifetime->size.Width &&
      current_size.Height == lifetime->size.Height) {
      WgcLog::Write("recreate-skip-samesize", lifetime->PoolForLog(),
        JoinDetails({
          GenerationDetail(lifetime->generation),
          SizeDetail("current_size", current_size),
          SizeDetail("lifetime_size", lifetime->size),
        }));
      return;
    }

    WgcLog::Write("recreate", lifetime ? lifetime->PoolForLog() : nullptr,
      lifetime ? JoinDetails({
        GenerationDetail(lifetime->generation),
        SizeDetail("lifetime_size", lifetime->size),
      }) : std::string());

    RetireFramePoolLocked("recreate");
    if (!CreateAndStartFramePoolLocked()) {
      is_running_ = false;
    }
  }

  bool TextureBridge::StartPumpLocked(
    const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
  {
    if (!lifetime || !lifetime->dispatcher_queue) {
      WgcLog::Write("pump-start-fail",
        lifetime ? lifetime->PoolForLog() : nullptr,
        lifetime ? "dispatcher_queue=0" : "lifetime=0");
      return false;
    }

    HRESULT timer_hr =
      lifetime->dispatcher_queue->CreateTimer(lifetime->pump_timer.put());
    if (FAILED(timer_hr) || !lifetime->pump_timer) {
      WgcLog::Write("pump-start-fail", lifetime->PoolForLog(),
        HResultDetail("hr", timer_hr));
      return false;
    }

    ABI::Windows::Foundation::TimeSpan interval = {};
    interval.Duration = kPumpInterval100ns;
    lifetime->pump_timer->put_Interval(interval);
    lifetime->pump_timer->put_IsRepeating(true);

    auto pump_state = std::make_shared<WgcPumpCallbackState>();
    {
      const std::lock_guard<std::mutex> state_lock(pump_state->mutex);
      pump_state->bridge = this;
      pump_state->lifetime = lifetime;
      pump_state->generation = lifetime->generation;
      pump_state->active = true;
    }
    lifetime->pump_state = pump_state;

    // DispatcherQueueTimer is MarshalingBehavior=Agile, so add_Tick rejects
    // any non-agile delegate with RO_E_MUST_BE_AGILE (0x8000001C). A plain
    // Microsoft::WRL::Callback<PumpTickHandler>(...) produces a non-agile
    // delegate (it only implements the typed-event interface), which made the
    // whole timer pump fail to start (pump-start-fail -> RetireFramePoolLocked
    // -> the WebView texture stayed empty: blank reader, empty lookup popup).
    // Aggregate FtmBase so the delegate is free-threaded (agile) and add_Tick
    // accepts it. The old FrameArrived event accepted a non-agile delegate;
    // the timer Tick event does not (the registration APIs are asymmetric).
    lifetime->pump_tick_handler = Microsoft::WRL::Callback<
      Microsoft::WRL::Implements<
        Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
        PumpTickHandler, Microsoft::WRL::FtmBase>>(
      [pump_state](ABI::Windows::System::IDispatcherQueueTimer* timer,
        IInspectable* args) -> HRESULT
      {
        TextureBridge* bridge = nullptr;
        std::shared_ptr<WgcFramePoolLifetime> lifetime;
        bool log_late_noop = false;
        uint64_t noop_generation = 0;
        bool noop_active = false;
        bool noop_retiring = false;
        bool noop_in_handler = false;
        const void* noop_bridge = nullptr;
        {
          const std::lock_guard<std::mutex> state_lock(pump_state->mutex);
          lifetime = pump_state->lifetime.lock();
          if (pump_state->active && !pump_state->retiring &&
            pump_state->bridge && lifetime) {
            pump_state->in_handler = true;
            bridge = pump_state->bridge;
          }
          else if (!pump_state->late_noop_logged) {
            pump_state->late_noop_logged = true;
            log_late_noop = true;
            noop_generation = pump_state->generation;
            noop_active = pump_state->active;
            noop_retiring = pump_state->retiring;
            noop_in_handler = pump_state->in_handler;
            noop_bridge = pump_state->bridge;
          }
        }
        if (log_late_noop) {
          WgcLog::Write("pump-late-noop",
            lifetime ? lifetime->PoolForLog() : nullptr,
            JoinDetails({
              GenerationDetail(noop_generation),
              BoolDetail("active", noop_active),
              BoolDetail("in_handler", noop_in_handler),
              BoolDetail("retiring", noop_retiring),
              BoolDetail("has_frame", false),
              PointerDetail("bridge", noop_bridge),
            }));
        }
        if (bridge && lifetime) {
          bridge->PumpFrameLocked(lifetime);
        }
        {
          const std::lock_guard<std::mutex> state_lock(pump_state->mutex);
          pump_state->in_handler = false;
        }
        return S_OK;
      });

    HRESULT tick_hr = lifetime->pump_timer->add_Tick(
      lifetime->pump_tick_handler.Get(), &lifetime->on_tick_token);
    if (FAILED(tick_hr)) {
      WgcLog::Write("pump-start-fail", lifetime->PoolForLog(),
        HResultDetail("add_tick_hr", tick_hr));
      lifetime->pump_tick_handler = nullptr;
      lifetime->pump_state = nullptr;
      lifetime->pump_timer = nullptr;
      return false;
    }

    HRESULT start_hr = lifetime->pump_timer->Start();
    if (FAILED(start_hr)) {
      WgcLog::Write("pump-start-fail", lifetime->PoolForLog(),
        HResultDetail("start_hr", start_hr));
      lifetime->pump_timer->remove_Tick(lifetime->on_tick_token);
      lifetime->on_tick_token = {};
      lifetime->pump_tick_handler = nullptr;
      lifetime->pump_state = nullptr;
      lifetime->pump_timer = nullptr;
      return false;
    }

    WgcLog::Write("pump-start", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));
    return true;
  }

  void TextureBridge::StopPumpLocked(
    const std::shared_ptr<WgcFramePoolLifetime>& lifetime,
    const char* reason)
  {
    if (!lifetime) {
      return;
    }

    WgcLog::Write("pump-stop-start", lifetime->PoolForLog(),
      JoinDetails({ GenerationDetail(lifetime->generation), ReasonDetail(reason) }));
    InvalidatePumpCallback(lifetime);

    if (lifetime->pump_timer) {
      HRESULT stop_hr = lifetime->pump_timer->Stop();
      lifetime->pump_stopped = SUCCEEDED(stop_hr);
      if (SUCCEEDED(stop_hr)) {
        WgcLog::Write("pump-stop-timer-done", lifetime->PoolForLog(),
          HResultDetail("hr", stop_hr));
      }
      else {
        WgcLog::Write("pump-stop-timer-fail", lifetime->PoolForLog(),
          HResultDetail("hr", stop_hr));
      }
    }

    if (lifetime->pump_timer && lifetime->on_tick_token.value != 0) {
      HRESULT remove_hr =
        lifetime->pump_timer->remove_Tick(lifetime->on_tick_token);
      lifetime->tick_removed = SUCCEEDED(remove_hr);
      if (SUCCEEDED(remove_hr)) {
        WgcLog::Write("pump-remove-tick-done", lifetime->PoolForLog(),
          HResultDetail("hr", remove_hr));
      }
      else {
        WgcLog::Write("pump-remove-tick-fail", lifetime->PoolForLog(),
          HResultDetail("hr", remove_hr));
      }
      if (SUCCEEDED(remove_hr)) {
        lifetime->on_tick_token = {};
      }
    }
    else if (lifetime->on_tick_token.value == 0) {
      WgcLog::Write("pump-remove-tick-skipped", lifetime->PoolForLog(),
        "token=0");
    }
    else {
      WgcLog::Write("pump-remove-tick-fail", lifetime->PoolForLog(),
        "timer=0");
    }

    lifetime->pump_tick_handler = nullptr;
    lifetime->pump_state = nullptr;
    lifetime->pump_timer = nullptr;
    WgcLog::Write("pump-stop-done", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));
  }

  void TextureBridge::Stop()
  {
    InvalidatePumpCallback();
    const std::lock_guard<std::mutex> lock(mutex_);
    StopInternal();
  }

  void TextureBridge::InvalidatePumpCallback(
    const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
  {
    auto target = lifetime ? lifetime : frame_pool_lifetime_;
    if (!target || !target->pump_state) {
      return;
    }
    auto pump_state = target->pump_state;
    const std::lock_guard<std::mutex> state_lock(pump_state->mutex);
    pump_state->active = false;
    pump_state->retiring = true;
    pump_state->bridge = nullptr;
    pump_state->generation = 0;
    target->inactive = true;
    target->retiring = true;
  }

  void TextureBridge::StopInternal()
  {
    auto lifetime = frame_pool_lifetime_;
    WgcLog::Write("stop", lifetime ? lifetime->PoolForLog() : nullptr);
    is_running_ = false;
    RetireFramePoolLocked("stop");
  }

  void TextureBridge::RetireFramePoolLocked(const char* reason)
  {
    auto lifetime = frame_pool_lifetime_;
    if (!lifetime) {
      return;
    }

    WgcLog::Write("retire", lifetime->PoolForLog(), ReasonDetail(reason));
    StopPumpLocked(lifetime, reason);
    WgcLog::Write("state-inactive", lifetime->PoolForLog(),
      GenerationDetail(lifetime->generation));
    frame_pool_lifetime_ = nullptr;
    FinalizeFramePoolLifetime(lifetime);
  }

  namespace
  {
    void FinalizeFramePoolLifetime(
      const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
    {
      if (!lifetime || lifetime->registry_retired) {
        return;
      }

      const void* pool_for_log = lifetime->PoolForLog();

      if (lifetime->capture_session) {
        WgcLog::Write("session-close-start", pool_for_log,
          GenerationDetail(lifetime->generation));
        auto session_closable =
          lifetime->capture_session.try_as<ABI::Windows::Foundation::IClosable>();
        if (session_closable) {
          const HRESULT close_hr = session_closable->Close();
          WgcLog::Write(SUCCEEDED(close_hr) ? "session-close-done"
            : "session-close-fail", pool_for_log, HResultDetail("hr", close_hr));
          lifetime->session_closed = SUCCEEDED(close_hr);
        }
        else {
          WgcLog::Write("session-close-done", pool_for_log, "closable=0");
          lifetime->session_closed = true;
        }
        lifetime->capture_session = nullptr;
      }

      if (lifetime->frame_pool) {
        WgcLog::Write("pool-close-start", pool_for_log,
          GenerationDetail(lifetime->generation));
        auto pool_closable =
          lifetime->frame_pool.try_as<ABI::Windows::Foundation::IClosable>();
        if (pool_closable) {
          const HRESULT close_hr = pool_closable->Close();
          WgcLog::Write(SUCCEEDED(close_hr) ? "pool-close-done"
            : "pool-close-fail", pool_for_log, HResultDetail("hr", close_hr));
          lifetime->pool_closed = SUCCEEDED(close_hr);
        }
        else {
          WgcLog::Write("pool-close-done", pool_for_log, "closable=0");
          lifetime->pool_closed = true;
        }
      }

      WgcLog::Write("retire-register-start", pool_for_log,
        GenerationDetail(lifetime->generation));
      FramePoolLifetimeRegistry::Instance().MarkRetired(lifetime);
      WgcLog::Write("retire-register-done", pool_for_log,
        GenerationDetail(lifetime->generation));
    }
  }  // namespace

  void TextureBridge::PumpFrameLocked(
    const std::shared_ptr<WgcFramePoolLifetime>& lifetime)
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (!is_running_ || !lifetime || lifetime != frame_pool_lifetime_ ||
      lifetime->generation != frame_pool_generation_ || lifetime->retiring ||
      !lifetime->frame_pool) {
      if (lifetime && !lifetime->noop_logged) {
        lifetime->noop_logged = true;
        WgcLog::Write("frame-noop", lifetime->PoolForLog(),
          FrameHandlerDetail(lifetime, false, lifetime->retiring, false,
            needs_update_.load()));
      }
      return;
    }

    if (needs_update_) {
      WgcLog::Write("frame-needs-update", lifetime->PoolForLog(),
        FrameHandlerDetail(lifetime, true, lifetime->retiring, false, true));
      needs_update_ = false;
      RecreateFramePoolLocked();
      return;
    }

    bool has_frame = false;
    for (int i = 0; i < kMaxFramesPerPump; ++i) {
      winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame>
        frame;
      auto hr = lifetime->frame_pool->TryGetNextFrame(frame.put());
      if (FAILED(hr)) {
        WgcLog::Write("frame-getfail", lifetime->PoolForLog(),
          JoinDetails({
            HResultDetail("hr", hr),
            FrameHandlerDetail(lifetime, true, lifetime->retiring, false,
              needs_update_.load()),
          }));
        break;
      }
      if (!frame) {
        break;
      }

      winrt::com_ptr<
        ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface>
        frame_surface;
      if (SUCCEEDED(frame->get_Surface(frame_surface.put()))) {
        last_frame_ =
          TryGetDXGIInterfaceFromObject<ID3D11Texture2D>(frame_surface);
        if (!ShouldDropFrame()) {
          has_frame = true;
        }
      }
    }

    if (has_frame && !lifetime->first_frame_logged) {
      lifetime->first_frame_logged = true;
      WgcLog::Write("frame-first-success", lifetime->PoolForLog(),
        FrameHandlerDetail(lifetime, true, lifetime->retiring, has_frame,
          needs_update_.load()));
    }

    if (has_frame && frame_available_) {
      frame_available_();
    }
  }

  bool TextureBridge::ShouldDropFrame()
  {
    if (!frame_duration_.has_value()) {
      return false;
    }
    auto now = std::chrono::high_resolution_clock::now();

    bool should_drop_frame = false;
    if (last_frame_timestamp_.has_value()) {
      auto diff = std::chrono::duration_cast<std::chrono::milliseconds>(
        now - last_frame_timestamp_.value());
      should_drop_frame = diff < frame_duration_.value();
    }

    if (!should_drop_frame) {
      last_frame_timestamp_ = now;
    }
    return should_drop_frame;
  }

  void TextureBridge::NotifySurfaceSizeChanged(size_t width, size_t height)
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    const bool before = needs_update_.load();
    needs_update_ = true;
    const auto lifetime = frame_pool_lifetime_;
    WgcLog::Write("surface-size-changed",
      lifetime ? lifetime->PoolForLog() : nullptr,
      JoinDetails({
        lifetime ? GenerationDetail(lifetime->generation) : GenerationDetail(0),
        SizeDetail("new_size", width, height),
        lifetime ? SizeDetail("pool_size", lifetime->size) : std::string(),
        BoolDetail("needs_update_before", before),
        BoolDetail("needs_update_after", true),
        PointerDetail("bridge", this),
      }));
  }

  void TextureBridge::SetFpsLimit(std::optional<int> max_fps)
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    auto value = max_fps.value_or(0);
    if (value != 0) {
      frame_duration_ = FrameDuration(1000.0 / value);
    }
    else {
      frame_duration_.reset();
      last_frame_timestamp_.reset();
    }
  }
}
