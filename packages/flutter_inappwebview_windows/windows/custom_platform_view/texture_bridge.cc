#include "texture_bridge.h"

#include <windows.foundation.h>

#include <algorithm>
#include <atomic>
#include <cassert>
#include <iostream>
#include <mutex>
#include <utility>
#include <vector>

#include "util/direct3d11.interop.h"
#include "../utils/wgc_log.h"

namespace flutter_inappwebview_plugin
{
  const int kNumBuffers = 1;

  namespace
  {
    // BUG-209 退役帧池保活注册表（进程级，单 UI 线程访问）——「Close 后永久保活」。
    //
    // dump 决定性证据：
    //   * hibiki.exe.8952.dmp（第七修包 b1f960290）/ .99916.dmp：崩点在
    //     GraphicsCapture.dll 内部
    //       FirePresentEvent -> winrt::event::operator()（读 [framepool+0x60] 的 m_targets）
    //       -> delegate::Invoke -> TypedEventHandler::operator()+0x15: mov rax,[rcx], rcx=0，
    //     且 framepool 对象所在整页内存已释放回收。即：一个已排进 UI 线程 CoreMessaging
    //     DispatcherQueue 的 deferred FirePresentEvent，在帧池对象已被释放之后才 fire——
    //     它对帧池不持强引用（两份 dump 一致：帧池页已被回收），event::operator() 读已
    //     释放的 m_targets 野指针，遍历到 null delegate abi 指针即崩。
    //   * hibiki.exe.81504.dmp（**含第八修代际 retired-list 的包 a8ff069a7**，2026-06-12
    //     11:35 崩溃）：仍崩同一偏移 0xf0d5（TypedEventHandler::operator()+0x15, rcx=0），
    //     崩溃帧池 0x2205274af10 内存 MEM_FREE（`!vprot` 无区域）+ closed-flag [pool+129h]
    //     读到 0（越过 FirePresentEvent+0x1c 的 cmp/jne 早返回，进了 event::operator()）+
    //     崩溃栈无任何 hibiki teardown 帧（消息泵正常派发早先排队的 deferral）。
    //
    // 第八修为何不彻底：它把 Close 后的帧池 move 进注册表，但按「代」延迟释放——第 N 次
    // teardown 释放第 N-2 次的帧池，赌「两次 teardown 之间 UI 线程必跨过完整消息循环 ->
    // 老帧池在途 deferral 已派发完」。81504 dump 反证这是个会输的时机赌注：用户快速连续
    // 查词时多次 teardown 在数百毫秒内完成，而 DispatcherQueue 里该帧池的 deferred
    // FirePresentEvent 仍积压未 fire；代际逻辑提前 Release 老帧池 -> 内存 free ->
    // 在途 deferral fire 时读 free 内存（closed-flag 字节随对象消失读到野值 0，越过
    // 早返回）-> 进 event::operator() 读野 m_targets -> null delegate -> 崩。closed-flag
    // 双保险只在帧池内存有效期内成立；代际逻辑一旦 Release 帧池，双保险随内存一起消失。
    //
    // 前八修共同盲点：都在「判断/依赖在途 deferral 的时机或引用」（drain-hop 判排空、
    // 赌 deferral 强引用延后析构、代际 2 代后释放），dump 全部反证。WGC 不暴露任何
    // 「在途 deferral 已排空」的同步信号，故任何「在某个时机释放退役帧池」的方案都是赌注。
    //
    // 唯一不依赖时机判断的因果不变量：**已 Close 的退役帧池永不主动释放**。
    //   (1) Close 释放帧池全部 D3D/GPU 资源（CloseInternal -> ResetD3DResources，反汇编
    //       实证），退役帧池只剩一个小 COM 壳（几百字节），不占 GPU/服务端资源。
    //   (2) 帧池内存永久有效 -> closed-flag [pool+129h] 永久 = 1 -> 任何迟到的 deferred
    //       FirePresentEvent 在开头 cmp/jne 永久早返回 no-op，永不读 event 成员/delegate
    //       表。null-delegate UAF 在因果上不可能发生（不再有「内存被释放」的窗口）。
    // 代价：每次 WebView teardown 泄漏一个已 Close 的小帧池壳，进程退出随 OS 回收。
    // teardown 频率有界（开关书/弹窗 WebView 销毁），是有界小泄漏，换零时机赌注的根治。
    // 这是 WGC API 不提供「排空 deferral」同步原语下的必要兼容代价。
    //
    // 仅 UI 线程访问（teardown 与 FrameArrived 同线程串行），无需锁；mutex 仅防御性
    // 兜底，零竞争路径。
    class RetiredFramePoolRegistry {
    public:
      static RetiredFramePoolRegistry& Instance()
      {
        static RetiredFramePoolRegistry instance;
        return instance;
      }

      // 把一个已 Close 的帧池 ComPtr 移交永久保活：只 push，绝不释放。帧池内存因此
      // 永久有效 -> closed-flag 永久 = 1 -> 任何迟到 deferred FirePresentEvent 永久
      // 安全早返回。已 Close 帧池只剩小 COM 壳（GPU 资源随 Close 释放）。
      void Retire(
        winrt::com_ptr<
          ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool> pool)
      {
        if (!pool) {
          return;
        }
        const std::lock_guard<std::mutex> lock(mutex_);
        retired_.push_back(std::move(pool));
      }

    private:
      RetiredFramePoolRegistry() = default;
      std::mutex mutex_;
      std::vector<winrt::com_ptr<
        ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>>
        retired_;
    };
  }  // namespace

  struct TextureBridge::FrameArrivedCallbackState {
    std::mutex mutex;
    TextureBridge* bridge = nullptr;
    bool active = false;
  };

  TextureBridge::TextureBridge(GraphicsContext* graphics_context,
    ABI::Windows::UI::Composition::IVisual* visual)
    : graphics_context_(graphics_context)
  {
    capture_item_ =
      graphics_context_->CreateGraphicsCaptureItemFromVisual(visual);
    assert(capture_item_);

    capture_item_->add_Closed(
      Microsoft::WRL::Callback<ABI::Windows::Foundation::ITypedEventHandler<
      ABI::Windows::Graphics::Capture::GraphicsCaptureItem*,
      IInspectable*>>(
        [](ABI::Windows::Graphics::Capture::IGraphicsCaptureItem* item,
          IInspectable* args) -> HRESULT
        {
          std::cerr << "Capture item was closed." << std::endl;
          return S_OK;
        })
      .Get(),
          &on_closed_token_);
    WgcLog::Write("create-bridge", this);
  }

  TextureBridge::~TextureBridge()
  {
    WgcLog::Write("dtor", this);
    InvalidateFrameArrivedCallback();
    const std::lock_guard<std::mutex> lock(mutex_);
    StopInternal();
    if (capture_item_) {
      capture_item_->remove_Closed(on_closed_token_);
    }
  }

  bool TextureBridge::Start()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    WgcLog::Write("start", frame_pool_.get(),
      is_running_ ? "running=1" : "running=0");
    if (is_running_ || !capture_item_) {
      return false;
    }

    // BUG-209 第十修（扩展保活到 Start 重入路径）：CustomPlatformView::HandleMethodCall
    // 的 setSize 每次都调 texture_bridge_->Start()（custom_platform_view.cc:323），不止
    // 首帧。is_running_ 守卫只挡「已成功 StartCapture 后的重入」；但若上一轮 Start 在
    // CreateCaptureSession 失败（:179-183 return，不设 is_running_）或 StartCapture 失败
    // （:190 return，不设 is_running_）后早返回，frame_pool_ 已被赋值且已 add_FrameArrived
    // 注册了句柄，is_running_ 仍为 false。下一次 setSize -> Start 越过 is_running_ 守卫，
    // 直接在 :147 用新池**覆盖** frame_pool_ ComPtr——旧池最后强引用归零、内存 free，
    // 但旧池仍挂着已注册的 FrameArrived，其在途 deferred FirePresentEvent 在旧池 free 后
    // 才 fire -> 读 free 内存的 event 成员 -> null delegate -> 同一 0xf0d5 崩点。第九修的
    // 永久保活只覆盖 StopInternal，这条 Start 覆盖路径是它漏掉的池销毁路径之一（dump
    // 81504 的崩溃池 MEM_FREE 且不在 retired-list，正是非 StopInternal 路径释放的池）。
    // 修：覆盖前用与 StopInternal 同一个 RetireFramePoolLocked 不变量先 Close + 退役保活，
    // 绝不让任何挂着在途 deferral 的旧池被裸覆盖释放。
    RetireFramePoolLocked();

    if (!CreateAndStartFramePoolLocked()) {
      return false;
    }
    is_running_ = true;
    return true;
  }

  bool TextureBridge::CreateAndStartFramePoolLocked()
  {
    // BUG-209：帧池的创建 + FrameArrived 挂载 + CaptureSession 建立 + StartCapture 收敛进
    // 单一 helper（调用方持 mutex_），供首帧 Start() 与 resize 时的 RecreateFramePoolLocked()
    // 共用——两条路径用完全相同的 WGC 线程模型 / delegate 注册，resize 不再走 Recreate。
    // 进入前 frame_pool_ 必为空（调用方已 RetireFramePoolLocked 退役旧池）。
    ABI::Windows::Graphics::SizeInt32 size;
    capture_item_->get_Size(&size);

    // BUG-163/BUG-209: 帧池必须用 CreateCaptureFramePool（UI 线程 DispatcherQueue
    // 派发，渲染管线线程模型与多年稳定版一致）。FreeThreaded 帧池（第四修）已实证
    // 在 Release 构建下纹理不更新（书籍文字全空，2026-06-10 用户验证 v1 无字 /
    // v2 revert 有字），禁止回潮。teardown 崩溃改由 RetireFramePoolLocked 的「Close 帧池 +
    // 退役帧池永久保活」解决（见上方 RetiredFramePoolRegistry）。
    frame_pool_ = graphics_context_->CreateCaptureFramePool(
      graphics_context_->device(),
      static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(
        kPixelFormat),
      kNumBuffers, size);
    assert(frame_pool_);

    auto callback_state = std::make_shared<FrameArrivedCallbackState>();
    {
      const std::lock_guard<std::mutex> state_lock(callback_state->mutex);
      callback_state->bridge = this;
      callback_state->active = true;
    }
    frame_arrived_state_ = callback_state;

    frame_arrived_handler_ = Microsoft::WRL::Callback<FrameArrivedHandler>(
        [callback_state](ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool*
          pool,
          IInspectable* args) -> HRESULT
        {
          const std::lock_guard<std::mutex> state_lock(callback_state->mutex);
          // teardown 后迟到 fire 的 deferred FirePresentEvent：active 已被
          // InvalidateFrameArrivedCallback 置 false，安全 no-op 返回，不触碰
          // 已失效的 bridge（revoke 前后窗口内万一 fire 的兜底防线）。
          if (callback_state->active && callback_state->bridge) {
            callback_state->bridge->OnFrameArrived();
          }
          return S_OK;
        });
    frame_pool_->add_FrameArrived(frame_arrived_handler_.Get(),
      &on_frame_arrived_token_);
    // 新池已 add_FrameArrived（自此挂在途 deferral 风险）——记录其指针，供崩溃
    // 取证对照「崩溃帧池指针」是否能在本日志找到对应的 retire 退役行。
    WgcLog::Write("create-pool", frame_pool_.get());

    if (FAILED(frame_pool_->CreateCaptureSession(capture_item_.get(),
      capture_session_.put()))) {
      std::cerr << "Creating capture session failed." << std::endl;
      // 静默早返回点（不设 is_running_，frame_pool_ 已赋值且已 add_FrameArrived）：
      // 记录可观测，下一次 Start() 入口的 RetireFramePoolLocked 会退役保活此残留池。
      WgcLog::Write("createSession-fail", frame_pool_.get());
      return false;
    }

    const bool started = SUCCEEDED(capture_session_->StartCapture());
    if (!started) {
      WgcLog::Write("startCapture-fail", frame_pool_.get());
    }
    return started;
  }

  void TextureBridge::RecreateFramePoolLocked()
  {
    WgcLog::Write("recreate", frame_pool_.get());
    // BUG-209 第十修（resize 路径替换 frame_pool_->Recreate）：调用方（OnFrameArrived）
    // 持 mutex_。原 Recreate 复用同一帧池只换 back buffer，但会拆掉旧池内部 present 基建，
    // 其在途 deferral 仍指向被拆状态 -> UAF。改为：退役保活旧池（Close + 永久保活）+
    // 建全新池。旧 CaptureSession 绑在旧池上，随旧池退役一并 Close 重建（见下）。
    RetireFramePoolLocked();

    if (capture_session_) {
      auto session_closable =
        capture_session_.try_as<ABI::Windows::Foundation::IClosable>();
      if (session_closable) {
        session_closable->Close();
      }
      capture_session_ = nullptr;
    }

    // 建新池并 StartCapture。失败则保持 frame_pool_ 为空（已退役旧池），下一次 setSize ->
    // Start() 会再尝试；与旧 Recreate 失败时同样不致崩（OnFrameArrived 开头读 frame_pool_
    // 前已无新帧投递）。注意：CreateAndStartFramePoolLocked 内部若 CreateCaptureSession
    // 失败会留下 frame_pool_ 非空但未启动——由下一次 Start() 入口的 RetireFramePoolLocked
    // 兜底退役保活，不裸释放。
    CreateAndStartFramePoolLocked();
  }

  void TextureBridge::Stop()
  {
    InvalidateFrameArrivedCallback();
    const std::lock_guard<std::mutex> lock(mutex_);
    StopInternal();
  }

  void TextureBridge::InvalidateFrameArrivedCallback()
  {
    auto callback_state = frame_arrived_state_;
    if (!callback_state) {
      return;
    }
    const std::lock_guard<std::mutex> state_lock(callback_state->mutex);
    callback_state->active = false;
    callback_state->bridge = nullptr;
  }

  void TextureBridge::StopInternal()
  {
    WgcLog::Write("stop", frame_pool_.get());
    is_running_ = false;

    // BUG-209（Close + 退役帧池永久保活）：dump 决定性根因——已排进 UI 线程
    // CoreMessaging DispatcherQueue 的 deferred FirePresentEvent 不持帧池强引用，
    // 在帧池被释放后才 fire；GraphicsCapture.dll 内部 event::operator() 读已释放的
    // 帧池 event 成员（[framepool+0x60] 的 m_targets）-> 野 delegate 数组 -> null
    // TypedEventHandler -> c0000005（崩在我们 lambda 之前，前七修的 callback_state/
    // ComPtr-release/drain-hop 防线全部够不着；第八修代际释放也被 81504 dump 反证，
    // 见上方 RetiredFramePoolRegistry 注释）。
    //
    // 根因修复用两层因果不变量，按以下顺序拆除：
    //   1) Close session：同步停止产生新帧。
    //   2) remove_FrameArrived(token)：同步从 WGC 内部 event delegate 表摘掉我们这一
    //      项（帧池仍存活，只动有效表，不留野指针）。返回后 WGC 不再向本 token 投递
    //      新的 FirePresentEvent。
    //   3) Close 帧池（IClosable）：同步设置帧池 closed-flag。此后任何已排队但未派发
    //      的 deferred FirePresentEvent，在其开头 cmp byte ptr [pool+129h],0 -> jne
    //      早返回 no-op，绝不读 event 成员/delegate 表（dump 反汇编实证此检查在 event
    //      fire 之前）。
    //   4) 把帧池 ComPtr move 进进程级退役注册表**永久保活**，绝不主动释放。帧池内存
    //      因此永久有效 -> closed-flag 永久 = 1 -> 任何迟到的在途 deferral 永久安全
    //      早返回（不再有第八修代际释放制造的「内存已 free」窗口）。
    //
    // 因果不变量：已 Close 的帧池内存永不释放 -> closed-flag 永久有效 -> 真要 fire 的
    // 在途事件因 closed-flag 而 no-op，永不读 event 成员。null-delegate UAF 在因果上
    // 不可能发生。代价是每次 teardown 常驻一个已 Close 小 COM 壳（WGC 服务端/GPU 资源
    // 随 Close 释放），有界小泄漏，进程退出随 OS 回收。
    if (capture_session_) {
      auto session_closable =
        capture_session_.try_as<ABI::Windows::Foundation::IClosable>();
      if (session_closable) {
        session_closable->Close();
      }
      capture_session_ = nullptr;
    }

    // BUG-209：帧池的「断源 -> Close 设 closed-flag -> 永久保活」三步收敛进单一
    // RetireFramePoolLocked，让 StopInternal / Start 重入 / OnFrameArrived resize 三条
    // 会丢弃或替换帧池的路径走完全相同的不变量，消除「某条路径裸释放挂着在途 deferral
    // 的帧池」的窗口（第九修只在 StopInternal 走这套，漏了另两条）。
    RetireFramePoolLocked();

    // 释放我们持有的 FrameArrived delegate ComPtr。frame_arrived_state_ 保留
    // （active 已被 InvalidateFrameArrivedCallback 置 false）。
    frame_arrived_handler_ = nullptr;
  }

  void TextureBridge::RetireFramePoolLocked()
  {
    // BUG-209 第十修（统一帧池退役不变量，覆盖所有丢弃/替换帧池的路径）：
    //
    // 此函数把「当前 frame_pool_」按 dump 实证的根因不变量退役保活，调用方持 mutex_：
    //   StopInternal()        —— WebView teardown（清栈式销毁）。
    //   Start()               —— setSize 重入时覆盖旧池前（第九修漏的路径，dump 81504
    //                            的 MEM_FREE 崩溃池正是从这里裸释放）。
    //   OnFrameArrived() 的    —— surface resize 不再 Recreate 复用同一池（Recreate 会
    //   needs_update_ 分支         拆掉旧池内部 present 基建，但其在途 deferred
    //                            FirePresentEvent 仍指向被拆的内部状态），改为退役旧池 +
    //                            建全新池，让旧池内存 + closed-flag 永久存活。
    //
    // 步骤（顺序即因果防线，与第九修 StopInternal 完全一致）：
    //   1) remove_FrameArrived(token)：同步从 WGC 内部 event delegate 表摘掉本项（帧池
    //      仍存活，只动有效表，不留野指针）。返回后 WGC 不再向本 token 投递新事件。
    //   2) Close 帧池（IClosable）：同步设 closed-flag [pool+129h]=1。此后任何已排队未派发
    //      的 deferred FirePresentEvent 在其开头 cmp/jne 早返回 no-op，绝不读 event 成员。
    //   3) 帧池 ComPtr move 进进程级退役注册表**永久保活**，绝不主动释放 -> 帧池内存永久
    //      有效 -> closed-flag 永久 = 1 -> 任何迟到 deferral 永久安全早返回。
    //
    // 因果不变量：任何曾经 add_FrameArrived 的帧池，从此一律退役保活、永不裸释放，故
    // null-delegate UAF（GraphicsCapture!TypedEventHandler::operator()+0x15, rcx=0）在
    // 因果上不可能发生。代价是每次退役常驻一个已 Close 小 COM 壳（GPU/服务端资源随 Close
    // 释放），有界小泄漏，进程退出随 OS 回收。
    if (!frame_pool_) {
      return;
    }
    WgcLog::Write("retire", frame_pool_.get());

    if (on_frame_arrived_token_.value != 0) {
      // 同步 revoke：返回后 WGC 不再向本 token 投递新 FirePresentEvent。
      // 帧池此刻仍存活，移除只动有效 delegate 表，不产生野指针。
      frame_pool_->remove_FrameArrived(on_frame_arrived_token_);
      on_frame_arrived_token_ = {};
    }

    // 同步设 closed-flag：在途/迟到的 deferred FirePresentEvent 据此早返回 no-op，
    // 不再读帧池 event 成员（崩点的前置防线）。
    auto pool_closable =
      frame_pool_.try_as<ABI::Windows::Foundation::IClosable>();
    if (pool_closable) {
      pool_closable->Close();
    }
    // 帧池强引用移交退役注册表永久保活（不在此释放，注册表也绝不主动释放），让其
    // 内存永久有效，使 closed-flag 永久 = 1，任何迟到 deferral 永久安全早返回。
    RetiredFramePoolRegistry::Instance().Retire(std::move(frame_pool_));
    frame_pool_ = nullptr;
  }

  void TextureBridge::OnFrameArrived()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (!is_running_) {
      return;
    }

    bool has_frame = false;

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame>
      frame;
    auto hr = frame_pool_->TryGetNextFrame(frame.put());
    if (FAILED(hr)) {
      // 仅失败时写（成功路径每帧 fire，禁止每帧刷盘）：取帧失败可能预示帧池
      // 状态异常，是观测帧池生命周期的低噪声信号。
      WgcLog::Write("frame-getfail", frame_pool_.get());
    }
    if (SUCCEEDED(hr) && frame) {
      winrt::com_ptr<
        ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface>
        frame_surface;

      if (SUCCEEDED(frame->get_Surface(frame_surface.put()))) {
        last_frame_ =
          TryGetDXGIInterfaceFromObject<ID3D11Texture2D>(frame_surface);
        has_frame = !ShouldDropFrame();
      }
    }

    if (needs_update_) {
      // BUG-209 第十修（覆盖 resize 这条之前漏的帧池替换路径）：原先用帧池的 Recreate
      // 方法在 surface resize 时复用同一帧池 COM 对象、只换内部 back buffer。问题是
      // Recreate 会同步拆掉旧池的内部 present 基建（旧的 swap-chain / present 子对象），
      // 而此前已排进 UI 线程 CoreMessaging 队列、尚未 fire 的 deferred FirePresentEvent
      // 仍指向被拆的旧内部状态——它之后 fire 时读已释放的 event 成员 -> null delegate ->
      // 同一 0xf0d5 崩点。该方法不走第九修的 Close + 退役保活，是 dump 81504 之外另一条
      // 「帧池（内部状态）被释放而在途 deferral 仍在途」的窗口。
      //
      // 改为：把旧帧池整体退役保活（remove_FrameArrived 断源 + Close 设 closed-flag +
      // 移交退役注册表永久保活，与 StopInternal/Start 同一 RetireFramePoolLocked 不变量），
      // 再建一个全新的帧池并重新挂 FrameArrived / 新建 CaptureSession。旧池内存 +
      // closed-flag 永久存活，其任何迟到 deferral 永久安全早返回；新池干净无在途 deferral。
      // 代价同退役保活：每次 resize 常驻一个已 Close 小 COM 壳（resize 频率有界）。
      needs_update_ = false;
      RecreateFramePoolLocked();
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

  void TextureBridge::NotifySurfaceSizeChanged()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    needs_update_ = true;
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
