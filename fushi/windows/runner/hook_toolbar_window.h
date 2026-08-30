#ifndef RUNNER_HOOK_TOOLBAR_WINDOW_H_
#define RUNNER_HOOK_TOOLBAR_WINDOW_H_

#include <windows.h>

#include <d2d1.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <commctrl.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

// BUG-951 — the galgame hook overlay's pass-through escape hatch.
//
// Why this window exists at all
// -----------------------------
// The overlay body must become *genuinely* click-through in pass-through mode:
// the user is reading captions on top of a galgame that lives in ANOTHER
// PROCESS, and clicks have to advance that game's dialogue. The only Win32
// mechanism that does this across processes is WS_EX_TRANSPARENT (returning
// HTTRANSPARENT from WM_NCHITTEST only walks same-thread windows, which is the
// original bug). WS_EX_TRANSPARENT is a WHOLE-WINDOW property — it cannot spare
// a toolbar band — so a single-window overlay has exactly two options: keep the
// user locked out of the toolbar, or flip the bit by cursor position on a timer.
// The timer variant was implemented, reviewed and reverted: a starved timer
// leaves the bit set while the user is already over the toolbar, so the click
// falls through into the game and advances dialogue / picks a branch.
//
// The structural fix is to stop asking one window to be two things. The body
// window becomes purely visual while pass-through is on, and this window — a
// separate, small, never-transparent top-level window — carries the toolbar.
// It is always clickable because it is never transparent; there is no state to
// flip, therefore no race to lose.
//
// Contract with FloatingLyricWindow
// ---------------------------------
//  * geometry is pushed in (HookToolbarLayout), never recomputed here, so the
//    two windows cannot drift apart about where the buttons are;
//  * slot -> action mapping lives in the per-profile tables below and is
//    resolved through SlotAction(), shared with the body window's
//    ControlActionAt(), so button 3 means the same thing in both;
//  * dragging the toolbar background drags the OWNER window (the body), which
//    is the only way to move the overlay while the body takes no mouse input.
//
// All methods must be called on the thread owning the message loop.

namespace hook_toolbar {

// 工具条用途。同一个浮窗类服务两种用途，两者的按钮**语义不同**，所以槽表按用途
// 分表：galgame hook 台词浮窗要试听 / 重捕 / 工作台，有声书悬浮字幕要上一句 /
// 播放暂停 / 下一句。
//
// 关键约束：SlotActive / SlotGlyph / DrawSlotIcon 一律**先取 action 字符串再分
// 支**，绝不按槽位下标 switch。两张表长度不同、同一个下标在两表里是两回事，按
// 下标分支必然在加表的那天集体错位（play 图标画到关闭键上）；按 action 分支则
// 新增一张表只需要给没见过的 action 补一个 case，已有 action 一个字都不用动。
enum class Profile {
  kGalHook,    // galgame hook 台词浮窗
  kAudiobook,  // 有声书悬浮字幕
};

// Draw / hit-test order of the galgame hook toolbar. Single source of truth:
// FloatingLyricWindow::ControlActionAt() resolves through SlotAction(), so the
// body window and the standalone toolbar can never disagree about what a slot
// does.
constexpr int kGalHookSlotCount = 9;
constexpr const char* kGalHookSlotActions[kGalHookSlotCount] = {
    "replayVoice",         // 0 replay the line's captured audio
    "recaptureVoice",      // 1 open a recapture window
    "toggleFollow",        // 2 follow / pause caption updates
    "togglePassThrough",   // 3 mouse pass-through  <- the escape hatch
    "toggleTransparency",  // 4 one-click background transparency
    "lock",                // 5 position lock
    "openWorkbench",       // 6 capture workbench
    // 7 always-on-top pin. Handled natively in DispatchControlAction (no Dart
    // round-trip), exactly like the clipboard window's 📌 — the overlay is born
    // topmost, and this is the only way to drop it behind another window
    // without closing it. Inserted ahead of the close slot so the rightmost
    // button is still 关闭 (muscle memory) and slots 0..6 keep their index.
    "topmost",
    "close",  // 8 close the overlay
};

// 有声书悬浮字幕的槽表。前三颗是播放控制（沿用旧歌词条的肌肉记忆顺序：上一句 /
// 播放暂停 / 下一句），后五颗是窗口能力键，与 hook 表同名同义——同名 action 在
// 两张表里永远是同一件事，这正是 action 驱动分支换来的性质。
//
// 没有 replayVoice / recaptureVoice / openWorkbench：那三颗是 galgame 捕获链专
// 属，对有声书是死键。也没有 toggleFollow：有声书的「跟随」就是播放本身，
// playPause 已经表达了它。
//
// **也没有 togglePassThrough / toggleTransparency**：这两个 action 不像 lock /
// topmost 那样由 DispatchControlAction 就地翻转，它们经 on_control_ 转给 Dart，
// 而有声书那一侧的处理函数（audiobook_session.dart）只有一行 debugPrint ——
// 画得出、点得到、按下去什么也不发生。galgame 那边有真实现（穿透是 hook 浮窗的
// 核心能力），有声书没有；在真接上之前，这里就不该画出来。
// 要加回来：先在 audiobook_session 接上真正的翻转，再把 action 放回本表。
constexpr int kAudiobookSlotCount = 6;
constexpr const char* kAudiobookSlotActions[kAudiobookSlotCount] = {
    "previousCue",  // 0 上一句
    "playPause",    // 1 播放 / 暂停
    "nextCue",      // 2 下一句
    "lock",         // 3 位置锁定
    "topmost",      // 4 置顶图钉（native 就地翻转）
    "close",        // 5 关闭
};

// 任一 profile 的最大槽数：窗口最小宽度等「必须容得下最宽工具条」的几何常量按它
// 取，不必随分表增删跟着改。
constexpr int kMaxSlotCount = kGalHookSlotCount > kAudiobookSlotCount
                                  ? kGalHookSlotCount
                                  : kAudiobookSlotCount;

// |profile| 的槽位数。
int SlotCount(Profile profile);
// |profile| 第 |slot| 槽的 action；越界返回 ""（空 action = 不是按钮命中）。
const char* SlotAction(Profile profile, int slot);

// Button states that change a slot's glyph or its active tint.
struct States {
  bool replaying = false;
  bool recapturing = false;
  bool playing = false;
  bool pass_through = false;
  bool locked = false;
  // Mirrors FloatingLyricWindow::topmost_ so the pin renders lit while the
  // overlay really is HWND_TOPMOST. Default true = the overlay's own default.
  bool topmost = true;
};

// Colours, mirrored from the body window's Style so both toolbars look alike.
struct Style {
  uint32_t button_text_color = 0xFFFFFFFF;
  uint32_t button_bg_color = 0x33000000;
  uint32_t active_color = 0xFFFFD54F;
  uint32_t bg_color = 0xCC000000;
};

// Where to put the toolbar, in screen / client PHYSICAL px. Computed by the
// owner from its own layout constants (see
// FloatingLyricWindow::ComputePassThroughToolbarLayout) so the floating buttons
// land exactly where the in-body toolbar used to draw them.
struct Layout {
  RECT rect = {0, 0, 0, 0};  // toolbar window rect, screen px
  // Top-left of the OWNER (body) window, screen px. The toolbar rect is offset
  // from it (the row is centred in the body and sits kControlsTopDip down), so
  // an owner drag MUST anchor on this, not on |rect| — anchoring on the toolbar
  // rect teleports the body by that offset the moment the drag starts.
  POINT owner_origin = {0, 0};
  float button_px = 0.0f;  // button edge length
  float gap_px = 0.0f;     // gap between two buttons
  float margin_px = 0.0f;  // padding between the window edge and the row
};

// Whether |slot| draws with the active (highlight) colour under |states|.
bool SlotActive(Profile profile, int slot, const States& states);
// Material Symbols Rounded codepoint for |slot| under |states|, or L"" when the
// bundled font subset has no glyph for that action — callers must fall back to
// DrawSlotIcon() for those, per slot. 打包的是 11 个码位的极小子集
// （assets/fonts/MaterialSymbolsRounded.ttf），新 action 若不在子集里，用字体画
// 出来的是豆腐块，所以「有没有字形」必须由这里如实回答，不能让调用方假定全有。
const wchar_t* SlotGlyph(Profile profile, int slot, const States& states);
// Loads the bundled subset from Flutter's packaged assets into an isolated
// DirectWrite collection. The caller owns the returned reference.
bool LoadMaterialSymbolsRoundedFontCollection(
    IDWriteFactory* factory, IDWriteFontCollection** collection);
// Draws a font-independent, optically aligned vector icon for |slot|. Keeping
// this as a missing-asset fallback keeps the pass-through escape hatch usable
// even if an incomplete development bundle omits the packaged font.
void DrawSlotIcon(ID2D1RenderTarget* target, ID2D1Factory* factory,
                  Profile profile, int slot, const States& states,
                  const D2D1_RECT_F& bounds, ID2D1Brush* brush);

// 槽位悬停提示文案（本地化，由 Dart 在 show 载荷里按 locale 下发；未下发 /
// 越界 = 空串 = 不显示）。与该 profile 的槽表同下标，单一真相：正文内工具条和
// 穿透工具条问的是同一张表，两处提示不可能各说各话。主线程专用（与整个模块
// 同一约束）。
// 提示表按 profile 分开存：两种用途的按钮不是一回事，共用一张表意味着后 show 的
// 那个浮窗会把另一个的提示文案整表覆盖掉（两个浮窗可以同时在屏上）。
void SetSlotTooltips(Profile profile, std::vector<std::wstring> tooltips);
const std::wstring& SlotTooltip(Profile profile, int slot);

// 手动追踪式 Win32 tooltip（TOOLTIPS_CLASS + TTM_TRACKACTIVATE）。
//
// 两个工具条窗都是 WS_EX_NOACTIVATE 的自绘分层窗，永远拿不到激活态，所以用
// TTS_ALWAYSTIP；又因为按钮矩形每次 Render 都随窗宽居中重算，挂不了固定矩形的
// TTF_SUBCLASS 工具，而是由宿主在 WM_MOUSEMOVE 里报「现在悬停在第几槽 + 该槽
// 屏幕坐标」，本类只负责建窗、换文案、摆位置。
class SlotTooltipHost {
 public:
  SlotTooltipHost() = default;
  ~SlotTooltipHost();

  SlotTooltipHost(const SlotTooltipHost&) = delete;
  SlotTooltipHost& operator=(const SlotTooltipHost&) = delete;

  // 在屏幕物理坐标 (|screen_x|, |screen_y|) 为 |slot| 显示提示。slot 未变则
  // no-op（提示钉在初次进入处，不随抖动跳）；slot < 0 或该槽文案为空则隐藏。
  void Update(HWND owner, Profile profile, int slot, int screen_x,
              int screen_y);
  void Hide();

 private:
  bool EnsureWindow(HWND owner);

  HWND hwnd_ = nullptr;
  int active_slot_ = -1;
  // TOOLINFOW::lpszText 是裸指针，comctl32 在整个提示生命周期内都会回读它。
  // 绝不能指向 SetSlotTooltips 那张共享表的内部缓冲：整表 move 赋值时旧串析构，
  // tool_ 就握着悬垂指针。本类自持一份，lpszText 只指向自己的成员。
  std::wstring current_text_;
  TOOLINFOW tool_ = {};
};

}  // namespace hook_toolbar

class HookToolbarWindow {
 public:
  // Reports a toolbar button press. The string is one of the current
  // profile's slot actions and is dispatched through exactly the same
  // owner-side handler as a press on the in-body toolbar.
  using ActionCallback = std::function<void(const std::string& action)>;
  // Requested new top-left for the OWNER window (screen physical px) while the
  // user drags the toolbar background. The owner clamps it to the work area and
  // moves both windows; this window never moves itself.
  using DragCallback = std::function<void(int owner_x, int owner_y)>;
  // The drag finished — the owner persists the new bounds.
  using DragEndCallback = std::function<void()>;

  HookToolbarWindow();
  ~HookToolbarWindow();

  HookToolbarWindow(const HookToolbarWindow&) = delete;
  HookToolbarWindow& operator=(const HookToolbarWindow&) = delete;

  void SetActionCallback(ActionCallback callback) {
    on_action_ = std::move(callback);
  }
  void SetDragCallback(DragCallback callback) { on_drag_ = std::move(callback); }
  void SetDragEndCallback(DragEndCallback callback) {
    on_drag_end_ = std::move(callback);
  }

  // Creates (if needed), positions and shows the toolbar. Returns false when
  // the OS window could not be created — the caller MUST then refuse to make
  // the body click-through, otherwise the user is locked out with no way back.
  //
  // |profile| 决定这条工具条画哪张槽表。它随每次 Show / Sync 推进来（而不是构造时
  // 定死）：owner 是哪种用途只有 owner 知道，工具条窗自己不该猜。
  bool Show(hook_toolbar::Profile profile, const hook_toolbar::Layout& layout,
            const hook_toolbar::Style& style,
            const hook_toolbar::States& states);
  void Hide();
  bool IsShowing() const;

  // Idempotent re-sync of geometry / colours / states. No-op (not even a
  // repaint) when nothing changed, so the owner can call it from every render
  // without turning caption updates into toolbar redraws.
  void Sync(hook_toolbar::Profile profile, const hook_toolbar::Layout& layout,
            const hook_toolbar::Style& style,
            const hook_toolbar::States& states);

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  LRESULT HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) noexcept;

  void EnsureWindowClass();
  bool EnsureDeviceResources();
  void Render();
  // Slot under the client point, or -1.
  int SlotAt(float x, float y) const;

  HWND hwnd_ = nullptr;
  bool class_registered_ = false;
  bool visible_ = false;
  bool hovered_ = false;
  int hovered_slot_ = -1;
  bool tracking_mouse_leave_ = false;

  // 槽位悬停提示（文案来自 hook_toolbar::SlotTooltip 共享表）。
  hook_toolbar::SlotTooltipHost tooltip_;

  // Owner-drag state. |dragging_| only becomes true once the press travelled
  // past the threshold, so a still press on the background is not a 1px drag.
  bool pressed_ = false;
  bool dragging_ = false;

  // BUG-1471: same one-transaction rule as FloatingLyricWindow -- WM_LBUTTONUP
  // is not the only terminator, the system revokes capture whenever the
  // foreground window changes underneath this WS_EX_NOACTIVATE window.
  void CancelPointerGesture();
  POINT press_origin_ = {0, 0};   // screen point where the press began
  POINT owner_drag_anchor_ = {0, 0};  // cursor offset inside the OWNER rect

  hook_toolbar::Layout layout_;
  hook_toolbar::Style style_;
  hook_toolbar::States states_;
  // 当前槽表用途。由 Show / Sync 推入，绘制与命中都问它，两者不可能各画各的。
  hook_toolbar::Profile profile_ = hook_toolbar::Profile::kGalHook;
  bool has_layout_ = false;

  Microsoft::WRL::ComPtr<ID2D1Factory> d2d_factory_;
  Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_factory_;
  Microsoft::WRL::ComPtr<IDWriteFontCollection> icon_font_collection_;
  Microsoft::WRL::ComPtr<ID2D1DCRenderTarget> render_target_;

  ActionCallback on_action_;
  DragCallback on_drag_;
  DragEndCallback on_drag_end_;
};

#endif  // RUNNER_HOOK_TOOLBAR_WINDOW_H_
