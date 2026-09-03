## BUG-1860 · gal 查词浮窗滚动条只是指示条：按住拖 thumb 变成拖窗
- **报告**：2026-08-25（用户：截图圈出右侧滚动条，「按住的话，变拖拽窗口了」）
- **真实性**：✅ 真 bug。根因 `fushi/windows/runner/floating_lyric_window.cpp`：
  - BUG-1095 第二阶段只把滚动条画成「指示条」（`Render` 内联算几何、画轨道 + thumb），没有任何命中逻辑；`WM_LBUTTONDOWN` 只认工具条按钮（`ControlActionAt`），其余全按「正文按压」处理（`pressed_ = true`），`WM_MOUSEMOVE` 走过 `kDragThresholdDip` 即提升为拖窗。用户看到滚动条、按住去拖，得到的是窗口跟着走。锁定态下则是「按了没反应」——两种都不是滚动。
  - 与穿透态（BUG-1859）无关：非穿透态同样拖窗；穿透态还多一层——命中带里没画到的像素是 alpha 0，按下直接透给游戏推台词。
  - 4dp 视觉细条本身也抓不住（Fitts），必须有比它宽的命中带。
- **[x] ① 已修复** —
  - 几何收成唯一真相 `ComputeScrollBar()`（`ScrollBarGeometry`：轨道 / thumb / 命中带 `kScrollBarHitWidthDip`=14dp），`Render` 绘制、`ScrollBarContains()` 命中、`BeginScrollThumbDrag()` 起拖三处同源，画哪按哪。
  - `WM_LBUTTONDOWN`：工具条按钮之后、正文按压之前判滚动条；命中即 `BeginScrollThumbDrag`（按在 thumb 外先把 thumb 中心搬到指针下，再起拖——「按 thumb」与「按轨道」是同一手势，没有第二套「翻页」行为），`SetCapture` 出窗继续跟；**不看 `locked_`**（锁的是位置不是滚动）。
  - `WM_MOUSEMOVE`：`scroll_thumb_dragging_` 分支在拖窗分支之前，按「轨道可走距离 ↔ 可滚行程」等比换算写 `SetScrollOffset`，并 return 掉不让 Shift-悬停查词在滚动条上乱出词。
  - 手势终结统一走 `CancelPointerGesture()`（`WM_LBUTTONUP` / `WM_CAPTURECHANGED` / `Hide` / `SetLocked` 一个不漏，BUG-1471 同款纪律）；`WM_MOUSELEAVE` 拖 thumb 期间不熄 hover 高亮。
  - 穿透态：`Render` 给命中带整块铺 `kHookTextMinCatchAlpha` 的不可见 catch fill（与 BUG-1853 行盒同一技法），「看得见的滚动条」与「按得到的滚动条」是同一块像素。
  - 提交见 PR（叠在 PR #1003 之上）。
- **[x] ② 已加自动化测试** — `fushi/test/build/gal_overlay_scroll_guard_test.dart` ⑥ 改断几何同源、新增 ⑨：状态与终结者、`WM_LBUTTONDOWN` 判定次序与不依赖 `locked_`、`WM_MOUSEMOVE` 分支次序与等比换算、capture、命中带常量、穿透态 catch fill。
- **[x] ③ 审查追修（2026-08-25）** —
  - 命中带不许伸进正文：轨道中心在 `width - pad/2`、命中带半宽 7dp，所以「文字边距」滑杆
    调到 `pad < 14dp`（最小 0，默认 20）时它会盖住正文最右边 `(7 - pad/2)` dp，那一列的
    点击本该是「点字查词」却变成起拖 thumb。`ComputeScrollBar()` 里把 `hit_left` 夹到
    `text_rect_.left + text_rect_.width`。
  - `MaybeHoverLookup` 的早退补上 `scroll_thumb_dragging_`：`WM_MOUSEMOVE` 里的 `return`
    只挡内联那一条路，`WM_TIMER` 轮询表拿实时光标，拖 thumb 时指针横向飘回正文上照样命中
    `CharIndexAt` → 拖到一半弹查词卡。判据写进 `MaybeHoverLookup`，两条路径同一份答案。
  - `SetLocked` 与 `lock` 动作的终结判据由 `(pressed_ || dragging_)` 补成
    `(pressed_ || dragging_ || scroll_thumb_dragging_)` —— 原文声称的「SetLocked 一个都不
    会漏」此前只对三个手势里的两个成立。
- **已知缺口（审查发现，本轮未修）**：`ComputeScrollBar()` 用
  `text_rect_.left + text_rect_.width + pad` 反推窗口宽度，但 `Render` 写的是
  `text_rect_.width = std::max(1.0f, width - pad * 2)` —— 一旦 `width < 2*pad + 1`（窗口很窄
  且 padding 拉到 80）夹取生效，反推值就偏，滚动条会画到窗外、命中带跟着错位。可行修法：把
  `Render` 算出的 `width` 存成成员，或让 `ComputeScrollBar` 自己 `GetClientRect`。
- **备注**：C++ 分层窗无法在 Dart 测试里执行，测试层是源码守卫；真机复验清单：①非穿透态按 thumb 拖→文本滚、窗不动；②按轨道空白→thumb 跳到指针下再跟手；③锁定态同样能拖；④穿透态按 thumb 旁 5px 内→仍是滚动、不推台词；⑤拖出窗外继续跟、松手后 hover 查词正常。本轮未真机复验。
