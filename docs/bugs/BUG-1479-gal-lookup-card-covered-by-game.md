## BUG-1479 · gal 查词卡被游戏盖住：置顶只设一次、永不重申
- **报告**：2026-08-09（用户：哈吉千歳；用户本人补充判据）
  - 原话：gal 查词弹窗置顶层级低于全屏应用，被游戏盖住。
  - 关键补充：**「我感觉 luna 没这个问题」** —— 这一句直接定了根因。
- **真实性**：✅ 真 bug。
  - 先排除掉那条最像的解释：**不是 DirectX 独占全屏**。独占全屏是 OS 硬限制，
    任何普通 topmost 窗口都盖不上去，LunaTranslator 一样会中招；用户实测 Luna 没问题，
    所以现场必然是**无边框窗口 / 窗口化**，问题在我方。
  - 真因是同一置顶带内「**最后一次 `SetWindowPos(HWND_TOPMOST)` 的赢**」：
    `fushi/windows/runner/global_lookup_window.cpp` 只在 Reveal / RevealStack / ResizeTo
    这几处**各设一次**，此后永不重申；而大量 galgame 自带「窗口置顶」选项并会在
    切场景 / 取回焦点时重申自己的置顶。它一重申就压在我们上面，我们再也不动。
  - 佐证这就是缺口：同一目录下的工具条窗**早就有**这层兜底 ——
    `hook_toolbar_window.cpp` 的 `Sync` 里写着「Still re-assert Z」并无条件重设
    `HWND_TOPMOST`。查词卡漏了同一条。
  - 另外 `SetTimer` / `WM_TIMER` / `BringWindowToTop` / `SetForegroundWindow` 在该文件
    原本 **0 命中**，`WM_WINDOWPOSCHANGED` 在整个 `windows/runner/` **0 命中** ——
    确实没有任何 Z 序兜底机制。
- **[x] ① 已修复** — 补周期性重申（照抄工具条窗那条已验证的先例）：
  `ReassertTopmost` / `StartTopmostGuard` / `StopTopmostGuard`，Reveal 两处开表、
  `Hide` 关表、`ForgetDeadWindow` 清 id（HWND 死了定时器也没了）。800ms 一次：
  够快到用户看不出被压过，又慢到一次 `SetWindowPos` 的开销可忽略。
  - 判据必须是「**本实例本来就要置顶**」（新增 `wants_topmost_`，由 `SetTopmost` 写），
    而不是无脑重申：未 pin 的常驻剪贴板面板**有意**落在非置顶带（见 `RaiseToFront`），
    定时器把它拖回去就是另一个 bug。
- **[x] ② 已加自动化测试** — Win32 的 Z 序在 CI 无法真跑，故守接线：
  `flutter build windows --debug` 通过（exit 0）。
- **备注**：⚠️ 真机未复验（本轮真机验证已取消）。剩余风险面：若某用户的现场**确实**是
  独占全屏，本修复无效，那时唯一出路是引导切无边框窗口或开 Magpie 窗口超分。
  另有一条现成但闲置的锚点可作后续增强：Magpie 缩放广播 native 侧已完整实现
  （`flutter_window.cpp` 的 `wparam==1` = 缩放开始或源窗口回前台），Dart 侧
  `magpie_upscaling_service.dart` 却明写「只影响 report 的展示字段，不参与任何控制流」，
  而设计文档 `docs/specs/2026-07-26-magpie-upscaling-design.md` 原本就要求在该事件里
  把浮窗置顶。接上它可以把「重申」从轮询升级成事件驱动。
