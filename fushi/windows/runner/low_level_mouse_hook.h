#ifndef RUNNER_LOW_LEVEL_MOUSE_HOOK_H_
#define RUNNER_LOW_LEVEL_MOUSE_HOOK_H_

// BUG-1048 — 进程级 WH_MOUSE_LL 承载线程。
//
// 低级鼠标钩子是**同步**钩子：系统把每一个鼠标输入事件（含高频 WM_MOUSEMOVE）投递到
// 安装钩子的那条线程的消息队列，并等它返回或超时（LowLevelHooksTimeout，默认 300ms）
// 才继续分发给前台程序。把它装在 Flutter 的 platform 线程上，等于让「全系统鼠标输入」
// 排在 Dart/Flutter 的渲染与 platform channel 之后：查词浮窗一出现，游戏里的鼠标移动
// 就跟着主线程的忙闲一卡一卡（用户实测「点击查词后鼠标移动都会变卡，不查就没事」）。
//
// 根因修复是让钩子跑在一条**只做钩子**的线程上：这里的线程除了 GetMessage 什么都不做，
// 回调只读 HWND 几何并 PostMessage（异步）回窗口线程，永远不会被 Flutter 的帧阻塞。
//
// 线程常驻（首次 Arm 时懒创建），Arm/Disarm 只是让它装/卸钩子——查词是高频操作，
// 每次都建销线程反而制造无谓的竞态窗口。
//
// BUG-1077 — 两条补强，针对「嵌套查词瞬间鼠标卡一下」：
//   ① 钩子线程跑在 TIME_CRITICAL 优先级：嵌套查词的瞬间进程内 CPU 风暴（同步 FFI
//      词典查询 + 整栈 JSON 序列化 + WebView2 COM + 窗口区域重建）会把 NORMAL
//      优先级的钩子线程抢占几十毫秒，而系统同步等它返回才分发输入——全系统鼠标
//      跟着卡一下。
//   ② Disarm 延迟真卸：嵌套/连续查词路径每次都是 Hide(Disarm) → 百毫秒 →
//      Reveal(Arm)，立卸立装 = 每次两回全局钩子表变更（又各是一次输入停顿）。
//      Disarm 先清目标（回调立即纯放行，语义等同已卸载），宽限期内无新 Arm 才
//      真正 UnhookWindowsHookEx。

#include <windows.h>

#include <cstddef>
#include <cstdint>

#include "attached_magpie_surface_geometry.h"

namespace fushi {

// 钩子命中时 PostMessage 给目标窗口的消息（WM_APP 段，进程内私有）：
//   wparam = 打包的屏幕物理坐标 ((uint32)x << 32) | (uint32)y
//   lparam = 1 表示点击真实命中目标 window region/子窗，0 表示在透明区或窗外
// 窗口线程自己决定「转发给 host / 关闭浮窗」——钩子线程不碰任何 C++ 对象。
constexpr UINT kLowLevelMouseClickMessage = WM_APP + 0x51;

// BUG-1166 — 落在目标窗口内的滚轮：钩子**吞掉**它（回调返回非 0，事件不再进入
// 输入流），改投这条消息让窗口线程自己消化。
//   wparam = 打包的屏幕物理坐标（同上）
//   lparam = 打包的滚轮载荷（见 MouseHookWheel / PackMouseHookWheel）
// 窗口线程再按「有没有按 Ctrl/Alt」分流：裸滚轮走原生子窗 PostMessage，带修饰键的
// 走 host JS 合成事件（修饰键过不了 PostMessage 那道边界，见 MouseHookWheel 注释）。
// 为什么必须吞：查词卡是 WS_EX_NOACTIVATE 的非激活窗（design §5 保证 3 — 查词
// 不许动前台程序的键盘焦点），而 WM_MOUSEWHEEL 是投给**焦点窗口**的。焦点留在
// galgame 上，滚轮就照样喂给游戏（滚出履历/推进文本）；Win10 的「悬停滚动非活动
// 窗口」只是个可关的用户选项，靠不住。只要不吞，卡片滚不滚都改不了游戏在动。
constexpr UINT kLowLevelMouseWheelMessage = WM_APP + 0x52;

// BUG-1882 — injected SGRE DirectInput shield 的按键事务已完整释放。钩子线程只
// PostMessage；真正的跨进程 property 撤销仍回到 popup/window 线程串行执行，避免
// 旧 mouse-up 与下一次 Reveal 交错时撤掉新一代发布。
constexpr UINT kLowLevelMouseShieldReleaseMessage = WM_APP + 0x53;

// Attached calibrated surface runs click-through.  The low-level hook owns
// only a bare left-button transaction whose down falls in one immutable glyph
// rectangle; all other buttons, wheel events, gaps and body-box whitespace go
// to the game unchanged.  Messages are posted after the v19 shield request is
// published, so the window thread merely adopts the transaction.
//   wparam = uint64 transaction id (high 32 bits are the hit-snapshot token)
//   lparam = packed physical screen point (same bit layout as PackMouseHookPoint)
constexpr UINT kLowLevelMouseAttachedGlyphDownMessage = WM_APP + 0x54;
constexpr UINT kLowLevelMouseAttachedGlyphUpMessage = WM_APP + 0x55;
constexpr UINT kLowLevelMouseAttachedGlyphCancelMessage = WM_APP + 0x56;
// The IPC/shield transaction became unrecoverable only after physical up. The
// worker has revoked the immutable snapshot; the surface thread must hide the
// matching generation so another down cannot overwrite a best-effort neutral
// tail before the injected side observes it.
constexpr UINT kLowLevelMouseAttachedGlyphAbortMessage = WM_APP + 0x57;
// A popup that temporarily owned the singleton hook has completed its close
// path. The attached surface uses this only to re-run its ordinary admission
// path after the full down/up and sampled-input tail are neutral.
constexpr UINT kLowLevelMouseAttachedGlyphRearmMessage = WM_APP + 0x58;

// 打包/解包屏幕坐标（x64 下 WPARAM 为 64 位；坐标可为负，故按 uint32 位模式搬运）。
WPARAM PackMouseHookPoint(int x, int y);
POINT UnpackMouseHookPoint(WPARAM wparam);

// 滚轮载荷。
//
// ⚠️ 修饰键**不能**靠 wparam 的 MK_* 位过 WebView2 这道边界（这是本 PR 复审推翻的
// 一条原始假设，别再改回去）：windowed 模式下窗口线程 PostMessage 的是一条**合成的**
// WM_MOUSEWHEEL，而 Chromium 取修饰键走 KeyStateFlagsFromNative() → GetKeyState()，
// **不读 wparam 的 MK_ 位**。GetKeyState 只随**硬件输入消息**出队才更新该线程的键
// 状态表；PostMessage 是非输入消息，加上查词卡是 WS_EX_NOACTIVATE、WebView2 的线程
// 不在前台输入队列里 —— 于是 e.ctrlKey 恒 false，PR#462 的 Ctrl+滚轮缩放会静默失效。
// 所以 ctrl / alt 改走**另一条显式携带修饰键的路**（GlobalLookupWindow::HandleGlobalWheel
// → ForwardGlobalWheelToHost → host JS 合成带显式 flag 的 WheelEvent）。
// keys 里的 MK_* 只服务**裸滚轮 / 仅 Shift** 那条原生 PostMessage 快路，不承担修饰键真值。
struct MouseHookWheel {
  int delta = 0;         // 有符号 WHEEL_DELTA 倍数
  UINT keys = 0;         // MK_* 位（仅供原生快路，非修饰键真值）
  bool horizontal = false;  // true = WM_MOUSEHWHEEL
  bool ctrl = false;        // 物理 Ctrl（GetAsyncKeyState）——分流判据
  // Alt 既没有 MK_ 位，COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS 也没有 ALT —— 结构上
  // 无法随 WM_MOUSEWHEEL 过界，只能靠这个字段单独带走。
  bool alt = false;         // 物理 Alt（VK_MENU）——分流判据
};
LPARAM PackMouseHookWheel(const MouseHookWheel& wheel);
MouseHookWheel UnpackMouseHookWheel(LPARAM lparam);

// 桌面/global 查词：装钩子并把命中事件投递给 |target|。点外只通知关闭，
// 点击仍交给原应用。重复调用只是替换目标窗口（幂等）。
void ArmLowLevelMouseHook(HWND target);

// direct galCard 专用：先在钩子线程确认 HHOOK 已安装，再把 |target| 与绑定的
// |consume_outside_owner| 游戏 HWND 一起发布。只有落在该游戏窗口/渲染子窗客户区、
// 且没落在查词窗口真实 region 上的 down/up 会被吞。返回 false 时调用方不得把
// direct popup 上屏，应走既有 fallback，避免冷启动首帧点击穿透。
bool ArmLowLevelMouseHookAndWait(HWND target, HWND consume_outside_owner);

// attached calibrated glyph surface 专用同步 Arm。与 direct galCard 共用同一条
// WH_MOUSE_LL/HHOOK 存活确认和 exact sampled-input publication，但消费范围严格限制为
// UpdateLowLevelAttachedGlyphHitRegions 发布的 immutable cluster snapshot：
// 字间、正文框空白以及游戏客户区其它位置都不吞。运行态 surface 本身 click-through，
// 这样透明命中层只拥有用户实际点中的裸左击，其余输入保持游戏原行为。
bool ArmLowLevelMouseHookForAttachedGlyph(HWND target, HWND game_owner);

// BUG-2140：上一次 attached 单例抢占失败的具体原因（五个闸门之一），失败后有效。
const char *LastAttachedGlyphArmFailure();

// BUG-2140：|candidate| 是否就是本进程为 |game_owner| 打开的那张查词卡。
bool IsLookupCardConsumingForOwner(HWND candidate, HWND game_owner);

// True only while |target| owns the singleton attached binding through the
// explicit HHOOK+v19 risk fallback.  A successful Arm is not by itself proof of
// exact sampled-input coverage; surface state uses this bit to report risky
// rather than verified/ready.
bool LowLevelAttachedGlyphUsesRiskFallback(HWND target);

// Replace the attached runtime hit geometry with one immutable screen-space
// snapshot.  Rectangles must be the exact DirectWrite cluster boxes (no body
// rect and no padding).  The returned non-zero token is embedded into every
// subsequently started transaction; the surface rejects a message if the
// token no longer matches its current text/surface generation.  Allocation
// and copying happen here on the window thread, never in WH_MOUSE_LL.
uint32_t UpdateLowLevelAttachedGlyphHitRegions(
    HWND surface, HWND game_owner, const RECT* screen_rects,
    size_t screen_rect_count, bool allow_risk,
    const attached_magpie_surface_geometry::Mapping* cursor_mapping,
    HWND cursor_presentation_hwnd);

// True while the exact immutable snapshot for |surface| and |token| is still
// published.  A callback can revoke a Magpie snapshot immediately after its
// bound presentation HWND leaves cursor-capture mode; the surface thread uses
// this bit to force a fresh publication on its next health sync.
bool LowLevelAttachedGlyphHitSnapshotIsCurrent(HWND surface, uint32_t token);

// Revoke one surface's immutable snapshot and fail-open any owned transaction.
// Safe to call repeatedly during sentence replacement, hide, detach or target
// destruction. A live physical down is marked cancelled but retained; the
// non-blocking callback records its paired up and the acknowledgement worker
// publishes/drains the v19 release asynchronously.
void ClearLowLevelAttachedGlyphHitRegions(HWND surface);

// The passive re-arm candidate intentionally outlives a transient snapshot
// clear while a popup owns the singleton. The surface retires it at WM_NCDESTROY
// so a recycled HWND can never receive a late notification.
void RetireLowLevelAttachedGlyphRearmCandidate(HWND surface);

// Finish one queued re-arm attempt.  A failed admission must not leave the
// global hook suppressing game clicks forever; the next health tick may retry
// from a clean pending state.
void CompleteLowLevelAttachedGlyphRearm(HWND surface);

inline uint32_t LowLevelAttachedGlyphSnapshotToken(
    uint64_t transaction_id) {
  return static_cast<uint32_t>(transaction_id >> 32u);
}
// BUG-2613 — 覆盖窗口左键护盾。
//
// 桌面查词卡 / hook 台词浮窗 / 穿透工具条都是 WS_EX_NOACTIVATE 的置顶窗：点它们时
// 游戏仍是前台窗口。Win32 消息型引擎（KiriKiri 等）看不到这些点击——消息投给了
// 光标下的我方窗口；但**采样型**引擎不看消息：HUNEX / Leaf 每帧 GetAsyncKeyState、
// SGRE 读 DirectInput 设备状态、其它引擎走 RawInput，物理左键一按它们就推进台词。
// 注入侧的输入盾（generic_input_shield.inc + 各 exact adapter）已能对游戏隐藏这类
// 采样，但它只认共享内存里的 v19 LookupShieldRequest，而这三种窗口从不发布请求。
//
// 这里让窗口把自己登记进一张小表；WH_MOUSE_LL 回调里裸左键 down 落在登记窗口
// （含子窗）上时，同步发布 owner=Popup、target=绑定游戏 HWND 的 down 请求，配对
// up 时发布 release。事件本身**不吞**——仍照常投给我方窗口，只是游戏的采样面看
// 不到它。发布走 TryPublish（单次 CAS + try_lock），回调里绝不等待。
//
// 游戏 HWND 由 SetOverlayClickShieldGameResolver 装的解析器在**登记时**（窗口线程）
// 解出：没有 galgame 会话时解析器返回 nullptr，登记就是空操作——有声书歌词条 /
// 剪贴板文本窗这类不在游戏之上的表面完全不受影响。重复登记同一 HWND 只是刷新
// 游戏 HWND（会话换局 / 前台窗换了都靠这条刷新），幂等。
void SetOverlayClickShieldGameResolver(HWND (*resolver)());
void RegisterOverlayClickShield(HWND overlay);
void UnregisterOverlayClickShield(HWND overlay);
// 测试/诊断：当前登记的覆盖窗口数与是否有在飞的覆盖窗口左键事务。
size_t OverlayClickShieldCountForTest();
bool OverlayClickShieldTransactionActiveForTest();

// 处理 kLowLevelMouseShieldReleaseMessage。只有 |target| 仍是本次发布的 popup、
// popup 已 Disarm 且没有按键等待 up 时才撤销；新 Reveal 已经开始时是 no-op。
void FinalizeLowLevelMouseDirectInputShield(HWND target);
// 卸钩子：目标窗口立即清空（回调纯放行）；真正的 UnhookWindowsHookEx 延迟一段
// 宽限期（见 .cpp 的 kDisarmGraceMs），期间再次 Arm 则取消卸载；若仍有已吞 down
// 等待配对 up，钩子会继续保留到释放完成。未装时是 no-op。
// Disarm when |target| still owns the singleton binding, or clean an
// uncommitted synchronous arm when no target was published. Passing the
// concrete HWND prevents one lookup-window instance from tearing down another
// instance's newer binding.
void DisarmLowLevelMouseHook(HWND target);

}  // namespace fushi

#endif  // RUNNER_LOW_LEVEL_MOUSE_HOOK_H_
