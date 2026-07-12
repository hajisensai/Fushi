## BUG-749 · app外查词覆盖窗铺满工作区吞掉下一次点击
- **报告**：2026-07-12（用户：「app外查词，第二个弹窗闪一下消失，然后后面的弹窗连闪都不闪了」，build 7532）
- **真实性**：✅ 真 bug（根因 `hibiki/assets/popup/global_lookup_host.js` measureAndReport 的 origin floor 拉 min-corner + `hibiki/windows/runner/global_lookup_window.cpp:ApplyRoundedRegion` 整窗 region；回归引入 = d2c57193a TODO-1345/BUG-583 round5，2026-07-09）
- **[x] ① 已修复** — host 每次测量把 per-shell 窗口相对矩形（CSS px CSV）发 `shellRects` 给 native；native `ApplyRoundedRegion` 在 rects 非空时用 per-shell 圆角矩形并集 `SetWindowRgn`（窗口矩形不动，BUG-583 零位移保留；空隙点击物理穿透）；`Hide`/`ForgetDeadWindow` 清 rects、host `beginLookup` 重置去重键；`handleGlobalClick` gap dismiss 改立即 post（防 stale-dismiss 杀新卡）
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/global_lookup_host_test.mjs`（R1-R3：rects 内容/顺序/去重、beginLookup 重置、gap 即时 dismiss）+ `hibiki/test/lookup/global_lookup_shell_region_guard_test.dart`（7 用例源码扫描守卫，`flutter test` 绿）
- **备注**：诊断还发现用户 `clipboard_panel_pinned=false`（面板非置顶被游戏/编辑器压底 =「连闪都不闪」的另一半），属用户可自复原状态（面板右上角图钉），非代码缺陷。

### 根因

TODO-1345（BUG-583 round5，d2c57193a，2026-07-09）为消除嵌套子卡打开时父卡位移，把 reveal
bbox 的 min-corner 预拉到 Dart 计算的级联 origin floor（朝屏幕内部的 headroom）。光标在
屏幕右/下半区时 floor ≈ 工作区左上角 → **瞬态覆盖窗 reveal 时铺满几乎整个工作区**
（真机日志 `reveal(box)` 高恒 =1440 全屏高、宽 2335~2560 CSS）。

该窗是**不透明**普通窗（无 WS_EX_LAYERED——与 WebView2 组合面不兼容，见 ShowAt 注释），
`ApplyRoundedRegion` 做的是**整窗**圆角 region。于是卡片在屏时：

1. 用户点剪贴板面板里的**下一个词** → 点击落在覆盖窗上（它盖住了面板）→ WebView/hook
   判「卡外」→ 关卡 + **点击被吞**（面板没收到点击、不查词）——「第二个弹窗闪一下消失」
   =用户瞄准下个词的那次点击亲手关掉了上一张卡且查词丢失，每查一个词要点两下。
2. 用户点游戏推进文本 → 游戏激活升到非置顶面板之上（用户图钉恰为关）→ 面板沉底 →
   后续点击全落游戏 →「连闪都不闪」。

7-9 之前窗口只有卡片并集大小，卡旁点击落在窗外：LL 钩子关卡**且**点击照常到达面板
（一次点击=关旧卡+查新词）——本修复恢复该语义而不牺牲 BUG-583 零位移。

### 修复

- `global_lookup_host.js`：measureAndReport 在 overlaySize **之前** post
  `shellRects`（`l,t,w,h;…`，窗口相对 = shell − bbox min）；独立去重键
  `lastShellRectsKey`（bbox 不变但子卡落在 floor 内时也必须刷新 region）；
  beginLookup/空栈/换根时重置；`handleGlobalClick` 未命中 shell 的 gap dismiss
  改为**立即** post `dismissPopupAt [0]`（同一次物理点击此刻已穿透到底下的应用并
  可能发起新 lookup，200ms slide 延迟的 dismiss 会 post 在新卡种栈之后把它杀掉）。
- `global_lookup_window.cpp/h`：WebMessageReceived 原生拦截 `shellRects`（不转发
  Dart）；`SetShellRectsFromCsv` 解析并缓存；`ApplyRoundedRegion` rects 非空时
  per-shell `CreateRoundRectRgn` + `CombineRgn(RGN_OR)` 并集 `SetWindowRgn`，空则
  维持原整窗圆角（面板实例 panel mode 短路 measureAndReport 永不发 rects，行为
  不变）；`Hide()`/`ForgetDeadWindow()` 清缓存。窗口矩形/origin 全程不动。

### 待验证（真机）

- 面板点释义词 → 卡片弹出（视觉为卡片本身而非大片）；卡片在屏时**直接点面板里
  下一个词** → 旧卡关、新卡一次点击弹出（不再吞点击）。
- 嵌套：卡内点词出子卡，父卡不位移（BUG-583 无回归）；点子卡正常交互。
- 空隙点击落在游戏/其他应用上正常生效且卡片关闭。
- 面板先点右上角图钉恢复置顶（`clipboard_panel_pinned` 当前为 false）。
