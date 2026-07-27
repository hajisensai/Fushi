## BUG-951 · Hook 浮窗鼠标穿透 HTTRANSPARENT 跨进程不生效
- **报告**：2026-07-21（PR#295 落地审查 H2，fable5）
- **真实性**：✅ **已确定性复现（为真）**。2026-07-27 用跨进程最小 Win32 装置 +
  真实 `SendInput` 点击验证，不再是静态推测。
- **根因**：`hibiki/windows/runner/floating_lyric_window.cpp:732-751`（修前）——
  穿透仅靠 `WM_NCHITTEST` 返回 `HTTRANSPARENT`。Win32 契约中它**只在同线程窗口间
  下传**；游戏属于另一进程，所以浮窗声明“这不是我的”之后系统找不到下一个
  同线程窗口，点击**整个消失**——既不给游戏，也不给浮窗。
  旧实现在部分场景“看上去能用”，只是因为背景不透明度为 0 时体表像素 alpha=0，
  是**层窗口的逐像素命中测试**把点击放下去的，与 `HTTRANSPARENT` 无关。因此：
  用户一旦把背景不透明度调成非 0（`_backgroundColor = alpha << 24`，
  `gal_hook_text_overlay_controller.dart:336`），整个正文区吞点击；即便为 0，
  点在**不透明的文字笔画**上照样被吞。
- **复现矩阵**（每格 = 一对全新跨进程窗口 + 一次真实 `SendInput` 点击）：

  | overlay 配置 | 点正文区 | 点顶部恢复带 |
  |---|---|---|
  | alpha=0，`HTTRANSPARENT` | 游戏收到 ✅ | 游戏收到 ❌（工具条点不到）|
  | alpha=5（2%），`HTTRANSPARENT` | **两边都没收到，点击被吞 ❌** | 同左 ❌ |
  | alpha=200，`HTTRANSPARENT` | **两边都没收到，点击被吞 ❌** | 同左 ❌ |
  | alpha=200，静态 `WS_EX_TRANSPARENT` | 游戏收到 ✅ | 游戏收到 ❌（工具条点不到）|
  | `WS_EX_TRANSPARENT` + 光标在恢复带时清位 | **游戏收到 ✅** | **浮窗收到 ✅** |

  复现装置与完整日志：`C:\Users\wrds\.claude\jobs\ef81236c\tmp\bug951-repro.md`
  （装置源码 `tmp\bug951\Repro.cs`，不入库）。
- **[x] ① 已修复** —— 穿透态改用 `WS_EX_TRANSPARENT`（真跨进程，与像素 alpha 无关）。
  该位是**整窗属性**，永久开着会把顶部恢复带（那里才有退出穿透的按钮）一起穿掉，
  全屏 galgame 下等于把用户锁死；所以按光标位置动态开关：只在光标悬停在恢复带时清掉
  该位。透明窗收不到任何鼠标消息，“光标进入恢复带”只能靠轮询发现（仅在穿透开启
  期间起 16ms 定时器）。恢复带几何收成单一谓词
  `PassThroughRecoveryContainsClientY`，`WM_NCHITTEST` 与轮询共用，不会漂开。
  `HTTRANSPARENT` 降为同线程兼容兵——覆盖光标离开恢复带到该位被置上的那一个轮询
  tick，这段时间里拒接点击好过把它吞成一次用户没要的查词。
  实现：`hibiki/windows/runner/floating_lyric_window.cpp`
  （`ApplyPassThroughHitTest` / `UpdatePassThroughFromCursor` /
  `PassThroughRecoveryContainsClientY` / `SetPassThrough` / `Show` / `Hide` / `WM_TIMER`）。
  坑：`SetWindowLongPtr(GWL_EXSTYLE)` 改完必须再
  `SetWindowPos(..., SWP_FRAMECHANGED)` 提交，否则位读回已变而命中测试还用旧值。
- **[x] ② 已加自动化测试** —— 源码扫描守卫
  `hibiki/test/tools/hook_overlay_passthrough_ex_transparent_guard_test.dart`（5 条）：
  ① 穿透态真的设/清 `WS_EX_TRANSPARENT`；② 改完走 `SWP_FRAMECHANGED` 提交；
  ③ 定时器 + `WM_TIMER` 轮询成对启停；④ 退出穿透 / `Hide` 无条件把点击还给浮窗
  （最大回归风险：别把浮窗自己的交互一起穿透掉）；⑤ 恢复带几何只有一份。
  负向对照已验：对修复前源码跑为 0 通过 / 5 失败。
  旁边的 BUG-1046 守卫（`hook_overlay_hittest_alpha_floor_guard_test.dart`）仍全绿。
- **备注**：核心特性验证项。自动化层只能锁住源码接线（native C++ 跑不进 Dart 测试），
  真机验收仍需在真实 galgame 上走一遍：开穿透 → 点浮窗遮住的正文区 → 游戏推进对话；
  再把光标移到浮窗顶部 → 工具条出现且可点（能退出穿透）。
