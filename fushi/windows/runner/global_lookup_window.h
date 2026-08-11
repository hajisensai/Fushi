#ifndef RUNNER_GLOBAL_LOOKUP_WINDOW_H_
#define RUNNER_GLOBAL_LOOKUP_WINDOW_H_

// TODO-617 global lookup overlay (Windows MVP).
//
// A runner-owned bare Win32 top-level window that hosts a WebView2 control to
// render the existing dictionary popup (assets/popup/popup.html). It is the
// Windows counterpart of Android's native ":popup" process: no second Flutter
// engine — the main Dart engine performs the lookup, produces the self-contained
// popupJson, and pushes it here for rendering. The overlay never activates
// (WS_EX_NOACTIVATE) so the foreground app keeps keyboard focus; gaiji images
// (image://) and audio resolution route back to the main Dart engine.
//
// See docs/specs/2026-06-25-global-lookup-webview-overlay-design.md.

#include <windows.h>
#include <wrl.h>

// The WebView2 SDK headers trip /WX (warnings-as-errors) via C4458 ('value'
// hides class member) on the runner target. Suppress around the SDK includes
// only — the warning is in Microsoft's headers, not our code.
#pragma warning(push)
#pragma warning(disable : 4458)
#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>
#include <wil/com.h>
#pragma warning(pop)

// 剪切板面板背景逐像素透明（composition 模式）：DirectComposition 视觉树承载
// WebView2 composition controller 的透明像素，配 WS_EX_NOREDIRECTIONBITMAP 真透到桌面。
#include <d3d11.h>
#include <dxgi.h>
#include <dcomp.h>

#include <array>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

// BUG-1166 — 滚轮载荷类型（fushi::MouseHookWheel）来自钩子线程的消息契约。
#include "low_level_mouse_hook.h"

class GlobalLookupWindow {
 public:
  // Resolves the bytes for a custom-scheme resource request (image://...).
  // Asynchronous on purpose: the bytes come from the main Dart engine over a
  // MethodChannel whose reply is delivered on the platform thread, so blocking
  // here would deadlock the message loop. The window hands the resolver a
  // |respond| continuation that completes the WebView2 deferral once Dart
  // replies (empty bytes -> 404).
  using MediaResolver = std::function<void(
      const std::string& url, std::function<void(std::vector<uint8_t>)> respond)>;
  // Receives raw JSON sent by popup JS via window.chrome.webview.postMessage.
  using MessageCallback = std::function<void(const std::string& json)>;
  // TODO-1153 -- receives a native bring-up error message (WebView2 environment
  // /controller create failure) so Dart can surface it via ErrorLogService.
  using ErrorCallback = std::function<void(const std::string& message)>;
  // TODO-1233 -- fired when the overlay transitions from on-screen to hidden via
  // a GENUINE dismissal (foreground hook / click-outside / JS dismiss), so Dart
  // can hang a resume-on-dismiss (video subtitle lookup BUG-072 pause/resume) or
  // reset its own reveal state. NOT fired for the programmatic reset Hide() that
  // precedes a fresh lookup (see Hide(bool)).
  using HiddenCallback = std::function<void()>;

  GlobalLookupWindow();
  ~GlobalLookupWindow();

  GlobalLookupWindow(const GlobalLookupWindow&) = delete;
  GlobalLookupWindow& operator=(const GlobalLookupWindow&) = delete;

  // Absolute folder that holds popup.html / popup.js / popup.css and the
  // injected bridge adapter (flutter_assets/assets/popup at runtime). Must be
  // set (via the channel "prepare" call) before the first ShowAt.
  void SetPopupAssetsDir(const std::wstring& dir) { popup_assets_dir_ = dir; }

  // TODO-1079 — creates the overlay window + WebView2 OFF-SCREEN and navigates
  // to host.html WITHOUT revealing it, so the first hotkey lookup hits a WARM
  // WebView2 (webview_ready_ already set) instead of racing a cold create chain
  // (environment + controller + navigation + host/popup double-iframe, commonly
  // >450ms). Idempotent: a no-op once the window exists. Mirrors the in-app
  // keepWebViewWarm hot-slot ownership for this app-external overlay window.
  // |width|/|height| size the off-screen host so its first self-measure is at a
  // sane size; the real card size is applied on the first ShowAt/Reveal.
  void PrewarmWebView(int width, int height, HWND owner);
  // TODO-1079 — whether the WebView2 has finished its initial navigation (the
  // host document + popup iframes are loaded). The ready-driven reveal fallback
  // must confirm this before revealing so a not-yet-loaded overlay never shows
  // as a blank window.
  bool IsWebViewReady() const { return webview_ready_; }

  // Shows the overlay at screen coordinates (physical pixels) without stealing
  // focus. Creates the window + WebView2 lazily on first call. Returns false if
  // window creation failed.
  bool ShowAt(int x, int y, int width, int height, HWND owner);
  // Resizes to fit the rendered card (physical px); clamps to the monitor work
  // area and nudges back on-screen if the bottom/right would overflow.
  void ResizeTo(int width, int height);
  // Moves the off-screen-rendered card to the pending cursor anchor at its final
  // size and makes it visible (arming the click-outside hooks). Called once per
  // lookup after the page has self-measured, so the user never sees the
  // measure->resize jitter. Pass <=0 to keep the current size.
  void Reveal(int width, int height);
  // TODO-867 P3c E1 — reveals/resizes to the nested-stack union bounding box.
  // |dx|/|dy| offset the window from the pending cursor anchor (physical px; the
  // host bbox origin × dpr) so a left/up cascade shifts the window while the root
  // card stays pinned at the cursor; |width|/|height| are the bbox size (physical
  // px). Clamps to the monitor work area like Reveal/ResizeTo.
  void RevealStack(int dx, int dy, int width, int height,
                   double bbox_left, double bbox_top);
  // TODO-1233 -- [notify]=true (default) fires the HiddenCallback on a genuine
  // dismissal; the programmatic reset before a fresh lookup passes false so the
  // between-lookups reset does not look like a user dismissal.
  void Hide(bool notify = true);
  bool IsShowing() const;

  // Injects |popup_json| and calls window.renderPopup(). Cached until the
  // WebView2 finishes initial navigation if called too early.
  void RenderJson(const std::string& popup_json);

  // Resolves a deferred JS bridge promise. |json_value| is a JSON literal
  // (e.g. "\"file:///a.mp3\"", "true", "null") passed straight to
  // window.__fushiBridgeResolve(id, json_value). Used by the audio handlers,
  // whose real reply comes from the main Dart engine.
  void ResolveBridge(int64_t id, const std::string& json_value);

  void SetMediaResolver(MediaResolver resolver) {
    media_resolver_ = std::move(resolver);
  }
  void SetMessageCallback(MessageCallback cb) {
    message_cb_ = std::move(cb);
  }
  // TODO-1153 -- wires the native overlay-error reporter (see ReportOverlayError).
  void SetErrorCallback(ErrorCallback cb) {
    error_cb_ = std::move(cb);
  }
  // TODO-1233 -- wires the overlay-dismissed reporter (see HiddenCallback).
  void SetHiddenCallback(HiddenCallback cb) {
    hidden_cb_ = std::move(cb);
  }

  // spec 2026-07-10 clipboard panel — the persistent clipboard-panel window is
  // a SECOND GlobalLookupWindow instance. Panel differences are data, not
  // modes: it never arms the dismiss hooks (persistent semantics: click-outside
  // / foreground-switch must NOT close it), and it gets its own WebView2
  // user-data leaf so its environment options never have to match the lookup
  // overlay's (same-folder different-options fails with 0x8007139F).
  void SetArmDismissHooks(bool arm) { arm_dismiss_hooks_ = arm; }
  void SetUserDataLeaf(std::wstring leaf) { user_data_leaf_ = std::move(leaf); }
  // 真机第 4 轮 — 面板窗可被激活：不带 WS_EX_NOACTIVATE 创建，点击面板时焦点
  // 落在面板上（游戏失焦，滚轮不再穿到底下的游戏）。程序化 show/update 仍全
  // 走 SW_SHOWNOACTIVATE / SWP_NOACTIVATE，文本流更新绝不抢游戏焦点。瞬态
  // 覆盖窗保持默认 false（查词卡出现时前台键盘焦点原地不动，design §5 保证 3）。
  // 必须在首次 ShowAt/PrewarmWebView（窗口创建）前设置。
  void SetActivatable(bool activatable) { activatable_ = activatable; }
  // 面板任务栏图标 — 常驻剪贴板面板要有独立任务栏按钮（WS_EX_APPWINDOW 而非
  // WS_EX_TOOLWINDOW）：面板未置顶（图钉关）被游戏/浏览器压到底下时，点任务栏
  // 图标即可激活+拉回前台（任务栏激活自带 raise），面板永远找得回来。瞬态查词
  // 覆盖窗保持默认 false（工具窗，无任务栏项/Alt-Tab 项）。必须在窗口创建前设置。
  void SetTaskbarPresence(bool present) { taskbar_presence_ = present; }
  // 任务栏按钮 / Alt-Tab 项显示的窗口标题（Dart 侧传本地化文案）。创建前设置
  // 则用于 CreateWindowExW；窗口已存在时经 SetWindowTextW 即时生效。
  void SetWindowTitle(const std::wstring& title);

  // 剪切板面板背景逐像素透明 — 仅面板实例开启：窗口用 WS_EX_NOREDIRECTIONBITMAP
  // 建、WebView2 走 composition controller + DirectComposition 视觉树，透明像素
  // 真透到桌面（背景全透 + 文字实心），取代整窗 LWA_ALPHA 的「文字一起变淡」。
  // 瞬态查词覆盖窗保持默认 false（windowed，行为一字不改）。必须在首次
  // ShowAt/PrewarmWebView（窗口 + WebView 创建）前设置。
  void SetCompositionMode(bool composition) { composition_mode_ = composition; }

  // spec §6 semi-transparency gate — asks DWM for a Win11 acrylic backdrop
  // behind the window's transparent WebView2 pixels. Returns whether the OS
  // accepted it (Win10 / pre-22H2 -> false; the panel then stays opaque and
  // Dart hides the opacity slider). Requires the window to exist (call after
  // ShowAt/PrewarmWebView). Never touches WS_EX_LAYERED (incompatible with the
  // WebView2 composition surface, see the CreateWindowExW comment).
  bool ApplySystemBackdrop();

  // spec 2026-07-10 panel pin — toggles HWND_TOPMOST without moving/resizing
  // or activating. No-op before the window exists.
  void SetTopmost(bool topmost);

  // 防截屏（剪贴板面板） — SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)：
  // 窗口对用户可见，但被排除在截图 / 录屏 / 屏幕共享捕获之外（内容不外泄）。
  // 记住 [block] 到 block_capture_，窗口重建（ForgetDeadWindow → 新 hwnd）后由
  // CreateWindowExW 之后的 ApplyBlockCapture() 自动重加。默认 false（瞬态查词
  // 覆盖窗不受影响）；面板实例的 Dart 控制器在显示时按 pref 置 true。
  void SetBlockCapture(bool block);

  // 面板抬前台 — 每次查词把已显示的面板重排到 z 序最上，绝不激活（不抢当前
  // 前台窗口的键盘焦点）。[topmost]=true（已 pin）直接 HWND_TOPMOST；false
  // 时用 TOPMOST→NOTOPMOST 弹一下，绕过前台锁把面板顶到非置顶带最上（裸
  // HWND_TOP 在别的 app 处于前台时可能被系统拒绝）。No-op before the window
  // exists.
  void RaiseToFront(bool topmost);

  // spec §6 真机修正 — WHOLE-WINDOW opacity via WS_EX_LAYERED +
  // SetLayeredWindowAttributes(LWA_ALPHA). Real-device finding: the acrylic
  // backdrop chain renders user-visibly OPAQUE through the windowed WebView2
  // child — and frosted glass was never the ask anyway; the user wants to SEE
  // the game/page beneath. LWA_ALPHA is the verified working path for WebView2
  // hosts (whole window fades, incl. text; LWA_COLORKEY is NOT supported by
  // WebView2) and works on Win10 too. [percent] clamped to 30..100; the
  // layered bit sticks once set (a layered window does not render until
  // SetLayeredWindowAttributes is called, so the call always follows).
  void SetWindowAlpha(int percent);

  // ── v14 游戏内查词（KiriKiri/KAGEX）：本窗当卡片的**像素来源** ──────────────────
  //
  // 词典卡片在游戏渲染树里显示，但像素仍由本窗出：注入侧只做几何传感与位图落地，
  // 分词/查词/排版/主题/17 语言全部留在这一份既有实现里（见
  // docs/specs/2026-08-10-kirikiri-ingame-lookup-plan.md §4.1）。所以这里加的不是
  // 第二个 WebView2，而是给**已有的离屏合成实例**开两个出口：取像素、喂输入。
  //
  // [ok]=false 时其余参数无意义。[clamped]=true 表示源画面比 max_width/max_height 大、
  // 已按左上角裁剪——上层据此知道卡片被切过，而不是默默投一张残帧出去。
  //
  // 为什么是 continuation 而不是 `bool CaptureBgra(out…)` 这种同步签名：
  // `ICoreWebView2::CapturePreview` 是异步 API，它的完成回调排在**本线程**的消息队列上。
  // 想同步等它就只有两条路——阻塞等待（队列永远派发不到那个回调，直接死锁）或就地泵
  // 消息（重入 WndProc / WebView2 内部状态机）。MediaResolver 当初就是为同一个理由做成
  // 异步的，这里照抄那套纪律。
  using BgraFrameCallback = std::function<void(
      bool ok, bool clamped, const std::vector<uint8_t>& bgra, uint32_t width,
      uint32_t height, uint32_t pitch)>;

  // 把当前离屏 WebView2 的内容取成契约规定的位图格式：
  // **BGRA8 / 直通（非预乘）alpha / 自顶向下 / pitch 恒为正**
  // （真相源是 voice_hook_ipc.h 的 v14 查词区注释）。写成预乘不会报错，只会让卡片
  // 半透明边缘发暗——所以格式不由这里"看着办"，由契约钉死。
  //
  // MVP 路径：`CapturePreview`（PNG 流）+ WIC 解码成 32bppBGRA。够 P1 静态卡片
  // （一次查词一帧，编解码 ~10-20ms 落在 host 线程，不占游戏主线程）。
  // 升级路径（P2 交互式高帧率才需要）：自持
  // `IDXGIFactory2::CreateSwapChainForComposition` 作 WebView2 的
  // root visual target，然后 `ID3D11DeviceContext::CopyResource` 到 D3D11_USAGE_STAGING
  // 纹理、`Map(D3D11_MAP_READ)` 直接读回 BGRA——省掉整条 PNG 编解码，代价是要自己管
  // swap chain 生命周期与 DPI/尺寸变化。**不要**在没有实测帧率不足前先做它。
  //
  // 必须在平台线程（本窗的消息循环线程）调用；continuation 也在该线程回调。
  void CaptureBgraAsync(uint32_t max_width, uint32_t max_height,
                        BgraFrameCallback done);

  // 把游戏侧转发来的一条 LookupInputSlot 喂给已有的 composition controller。
  // [kind] 取 voice_hook_ipc.h 的 kLookupInput*（0=move 1=leftDown 2=leftUp
  // 3=wheel 4=leave）；.cpp 里有 static_assert 钉住这组取值，契约改了编译期就红。
  // [x]/[y] 是**卡片局部坐标**（注入侧已减去 anchor），正好等于 WebView 客户区坐标。
  // [keys] 是 MK_* 位掩码。
  //
  // 只有 composition 实例能收：windowed WebView2 没有 SendMouseInput（输入靠它自己的
  // 子 HWND），而游戏内卡片根本没有对应的子窗口。所以游戏内查词的像素源实例**必须**
  // 先 SetCompositionMode(true)；否则本方法一律返回 false 而不是假装喂进去了。
  bool InjectLookupInput(uint32_t kind, int32_t x, int32_t y, int32_t wheel,
                         uint32_t keys);

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  // Closes the overlay when the user activates another window (alt-tab away).
  static void CALLBACK ForegroundHookProc(HWINEVENTHOOK hook, DWORD event,
                                          HWND hwnd, LONG id_object,
                                          LONG id_child, DWORD thread,
                                          DWORD time);
  // BUG-1048 — 处理钩子线程投递过来的「全局点击」消息（见 low_level_mouse_hook.h）：
  // 落在窗口外 -> 关闭浮窗；落在窗口内 -> 交给 web host 自己命中测试。跑在窗口线程，
  // 钩子线程只搬坐标，不碰任何 C++ 对象。
  void HandleGlobalClick(POINT screen_pt, bool inside_window);
  // BUG-1166 — 处理钩子线程投递过来的「落在卡片上的滚轮」（钩子已把它从输入流里
  // 吞掉，见 low_level_mouse_hook.h）。这里把它还原成一条真 WM_MOUSEWHEEL 交给
  // WebView2：composition 实例经 SendMouseInput，windowed 实例投给光标压着的
  // WebView2 子窗——两条路都是各自模式下 WebView 本来就在收输入的那条路。
  void HandleGlobalWheel(POINT screen_pt, const fushi::MouseHookWheel& wheel);
  // BUG-1166 — 带 Ctrl/Alt 的滚轮的落地点。修饰键过不了「合成 WM_MOUSEWHEEL」那道
  // 边界（Chromium 读 GetKeyState，合成消息不更新键状态表），所以把修饰键当数据交给
  // host JS 合成一条带显式 flag 的 WheelEvent，交由既有的 JS 监听按**用户绑定**判定
  // （Ctrl→缩放走 popupZoomFontStep 回 Dart；Alt→换词条留在 popup.js）。
  // C++ 只做传输，不复制任何绑定语义。
  void ForwardGlobalWheelToHost(POINT screen_pt,
                                const fushi::MouseHookWheel& wheel);
  LRESULT HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
  int OffscreenX() const;
  // TODO-867 P2: round the window corners to match popup.css's card radius.
  // BUG-749: when the host has reported per-shell rects (transient cascade
  // mode), the region is the UNION of those card rects instead of the full
  // window — the TODO-1345 reserved-floor window spans ~the whole work area,
  // and an opaque full-window region both paints a giant sheet and swallows
  // every click meant for the app below (clipboard panel next-word tap).
  void ApplyRoundedRegion();
  // BUG-749 — parses the host's {handler:'shellRects', args:['l,t,w,h;…']}
  // message (window-relative CSS px) and re-applies the window region.
  void SetShellRectsFromCsv(const std::string& body);
  // TODO-867 P3c E2: forward a global click (screen physical px) into the web
  // host as host CSS px relative to the window, so the host hit-tests its shells
  // and dismisses the appropriate layer (the host owns the shell geometry truth).
  void ForwardGlobalClickToHost(int screen_x, int screen_y);
  void EnsureWindowClass();
  // Root fix: hwnd_ must be non-null IFF a LIVE window that is OURS exists.
  // External teardown (WebView2 runtime crash/update, owner destroy, any
  // DestroyWindow) left hwnd_ dangling-non-null, so ShowAt kept SetWindowPos-ing
  // a corpse instead of rebuilding -> the app-external lookup/panel window
  // "never came back without an app restart". OwnsLiveWindow() rejects a
  // destroyed handle (IsWindow) AND a handle recycled to another window
  // (GWLP_USERDATA != this); ForgetDeadWindow() drops such a handle + its dead
  // WebView2 proxies so the next ShowAt/PrewarmWebView rebuilds from scratch.
  bool OwnsLiveWindow() const;
  void ForgetDeadWindow();

  // Tear down the dismissal hooks (foreground WinEvent + low-level mouse) and
  // give up hook ownership if it is ours.
  //
  // BUG-1471: arming happens in Reveal()/RevealStack(), but disarming used to
  // live only in Hide() and the destructor. ForgetDeadWindow() — the path taken
  // when the HWND is destroyed under us — dropped every other resource and left
  // these armed, pointing at a dead HWND. The low-level mouse hook has a 1s
  // liveness re-arm timer, so that leak does not decay: it keeps a pure
  // pass-through hook alive on the chain forever. One funnel, two callers.
  void ReleaseDismissHooks();

  /// 显示期间周期性重申置顶（BUG-1479）。
  ///
  /// 症状：gal 会话里查词卡被游戏盖住。**不是**独占全屏那条 OS 硬限制——那样
  /// LunaTranslator 也会中招，而用户实测 Luna 没有这个问题。真因是同一个置顶带内
  /// 「最后一次 SetWindowPos(HWND_TOPMOST) 的赢」：大量 galgame 自带「窗口置顶」
  /// 选项且会周期性重申，而我们**只在 Reveal/Resize 设一次、此后永不重申**。
  ///
  /// 工具条窗早就有这层兜底（hook_toolbar_window.cpp 的 Sync：「Still re-assert Z」），
  /// 查词卡漏了。这里补上同一条，并且**只在本实例本来就要置顶时**才重申——
  /// 未 pin 的常驻面板有意落在非置顶带，不能被这个定时器拖回去。
  void ReassertTopmost();
  void StartTopmostGuard();
  void StopTopmostGuard();
  // 防截屏 — 把 block_capture_ 应用到当前 hwnd_（SetWindowDisplayAffinity）。
  // 每次 CreateWindowExW 之后调用一次，故窗口重建（ForgetDeadWindow / 崩溃恢复）
  // 后依然按最后一次 SetBlockCapture 的值生效。No-op before the window exists.
  void ApplyBlockCapture();
  void EnsureWebView();
  // 背景逐像素透明（composition 模式）辅助：
  // InitCompositionDevice — 建 D3D11 + DComp 设备（无需 HWND），可在建窗前探测能力；
  //   失败即 composition_active_=false，回退 windowed（面板照常工作、只是不透明）。
  // EnsureCompositionTargetVisual — 为 hwnd_ 建 DComp target + 承载 WebView 的 visual。
  bool InitCompositionDevice();
  bool EnsureCompositionTargetVisual();
  // 建窗 ex-style（含 composition 能力探测）：composition_active_ 时带
  // WS_EX_NOREDIRECTIONBITMAP。ShowAt / PrewarmWebView 共用，避免两处重复。
  DWORD OverlayCreateExStyle();
  // 背景逐像素透明（composition）无子 HWND，鼠标消息直达本窗：把它们转发给
  // composition controller（SendMouseInput），否则透明面板点不动/滚不动。windowed
  // 瞬态窗的 WebView2 子窗自动收输入，不经此路径。
  void ForwardCompositionMouse(UINT message, WPARAM wparam, LPARAM lparam);
  void RecoverDeadWebView(const std::string& replay_script);
  // TODO-1153 -- logs + reports an overlay WebView2 bring-up failure (never
  // swallows it) so the "app-external lookup shows no popup" cause is visible.
  void ReportOverlayError(const std::string& message, HRESULT hr);
  void ConfigureWebView();
  // BUG-1104 — 把「这个 HWND 当前的 DPI」推给 WebView2 控制器（BoundsMode /
  // ShouldDetectMonitorScaleChanges / RasterizationScale）。composition 与
  // windowed 两条创建路径、以及 WM_DPICHANGED 都只走这一个入口，两条路径的
  // DPI 行为因此不可能再漂开。
  void ApplyDpiScale();
  std::wstring LoadAdapterScript() const;
  // TODO-867 P3c — reads global_lookup_host.js for top-level injection.
  std::wstring LoadHostScript() const;

  HWND hwnd_ = nullptr;
  HWINEVENTHOOK foreground_hook_ = nullptr;
  // BUG-1048 — 本实例是否已让钩子线程装上 WH_MOUSE_LL（钩子本身不再由本线程持有）。
  // 仍是**每实例**标志：常驻剪贴板面板从不 arm，它的 Hide() 也就不会卸掉瞬态查词
  // 覆盖窗的点击外关闭。
  bool mouse_hook_armed_ = false;
  static GlobalLookupWindow* s_hook_owner_;
  bool visible_ = false;
  bool revealed_ = false;
  int pending_x_ = 0;
  int pending_y_ = 0;
  bool webview_ready_ = false;
  // TODO-1268 (BUG-693): a dead-surface rebuild is in flight; renders
  // cache into pending_json_ until NavigationCompleted re-arms
  // webview_ready_.
  bool recovering_ = false;
  // Phase C（弹窗尺寸精细化 2026-07-13）— 用户正拖右下角 grip 调整窗口尺寸（在
  // WM_ENTERSIZEMOVE..WM_EXITSIZEMOVE 之间为 true）。瞬态覆盖窗平时按 shell 卡矩形
  // 裁剪窗口区域（BUG-749 gap click-through），裁剪区不随窗口增大 → 拖拽看不到窗口
  // 变大；resize 期间 ApplyRoundedRegion 改用整窗区域，让窗口可见地随拖拽增长，结束
  // 复原 shell 裁剪。面板实例 shell_rects_css_ 为空，此标志对它无副作用。
  bool resizing_ = false;
  // Phase C（2026-07-14）— 拖拽起始（WM_ENTERSIZEMOVE 那刻）的窗口物理尺寸。瞬态覆盖
  // 窗恒比可见卡片大一截（reserve-to-edge 级联余量），故 WM_EXITSIZEMOVE 回报「起始+结束」
  // 两个尺寸，Dart 用二者之差（恒定余量抵消）折算 overlay 增量——绝对窗口尺寸会把余量算
  // 进去导致尺寸暴涨/卡片甩边（乱跳）。0 = 未在拖拽。
  int resize_start_w_ = 0;
  int resize_start_h_ = 0;
  // spec 2026-07-10 — panel-instance data knobs (defaults == the historical
  // lookup-overlay behaviour, so the first instance is byte-for-byte unchanged).
  bool arm_dismiss_hooks_ = true;
  bool activatable_ = false;

  /// 本实例显示时是否应处于置顶带。瞬态查词卡恒真；常驻面板跟随图钉。
  bool wants_topmost_ = true;

  /// 置顶重申定时器 id（0 = 未起）。见 [ReassertTopmost]。
  UINT_PTR topmost_guard_timer_ = 0;
  bool taskbar_presence_ = false;
  // 防截屏当前请求值（真相源是 Dart pref；窗口重建后 ApplyBlockCapture 用它重加）。
  // 默认 false：只有面板实例的控制器会按 pref 置 true，瞬态覆盖窗恒不受影响。
  bool block_capture_ = false;
  // 背景逐像素透明模式（仅面板实例）：composition controller + DirectComposition。
  // 默认 false=windowed（瞬态窗与历史行为一字不改）。见 SetCompositionMode。
  bool composition_mode_ = false;
  // composition_mode_ 请求下 DComp 设备真的建起来了才为 true：任何 D3D11/DComp/
  // composition controller 创建失败都回退 composition_active_=false（windowed），
  // 面板永不因透明改造而黑屏/崩溃（graceful degrade，只是不透明）。窗口样式、
  // controller 分支、WM_SIZE 都以 composition_active_（而非 _mode_）为准。
  bool composition_active_ = false;
  std::wstring window_title_ = L"Fushi Lookup";
  std::wstring user_data_leaf_ = L"GlobalLookupWebView2";
  std::wstring popup_assets_dir_;
  std::string pending_json_;
  // BUG-749 — host-reported shell rects (window-relative CSS px, one
  // {l,t,w,h} per card). Non-empty only on the transient cascade instance
  // (the panel host short-circuits measureAndReport and never posts them).
  // Cleared on Hide()/ForgetDeadWindow() so a fresh lookup re-posts.
  std::vector<std::array<double, 4>> shell_rects_css_;

  wil::com_ptr<ICoreWebView2Environment> env_;
  wil::com_ptr<ICoreWebView2Controller> controller_;
  wil::com_ptr<ICoreWebView2> webview_;

  // 背景逐像素透明（composition 模式）COM 对象。composition_active_ 时才创建。
  wil::com_ptr<ID3D11Device> d3d_device_;
  wil::com_ptr<IDCompositionDevice> dcomp_device_;
  wil::com_ptr<IDCompositionTarget> dcomp_target_;
  wil::com_ptr<IDCompositionVisual> dcomp_visual_;
  wil::com_ptr<ICoreWebView2CompositionController> composition_controller_;
  // composition 模式下 WebView2 请求的光标（add_CursorChanged 回调更新）；
  // WM_SETCURSOR 据此 SetCursor，让 hover 链接/文本时光标形状正确。
  HCURSOR composition_cursor_ = nullptr;

  MediaResolver media_resolver_;
  MessageCallback message_cb_;
  ErrorCallback error_cb_;
  HiddenCallback hidden_cb_;
};

#endif  // RUNNER_GLOBAL_LOOKUP_WINDOW_H_
