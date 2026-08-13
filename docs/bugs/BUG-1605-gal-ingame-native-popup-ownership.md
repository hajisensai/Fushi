## BUG-1605 · 游戏内查词离屏卡被钳回桌面导致重复弹窗
- **报告**：2026-08-12（用户：）
- **真实性**：✅ 真 bug（用户截图已显示 Hibiki 查词窗与游戏内卡片同时出现，代码路径与现象一致）

### 根因

游戏内查词本来就把现有 Fushi popup 路由到专用 `galCard` WebView2 窗口：窗口在屏幕外完成布局，
runner 抓取 BGRA 后再投进游戏 Layer。这个复用方向本身没有要求桌面显示第二份卡。

真正的错误在 `fushi/windows/runner/global_lookup_window.cpp` 的普通 `ResizeTo`：它会把当前窗口矩形
钳进最近显示器的工作区。`galCard` 虽由 `ShowAt` 停在 `OffscreenX()`，但随后收到 popup 自测量产生的
`resize` / `reveal` / `revealStack` 时仍调用 `ResizeTo`，于是被从屏外强行挪回桌面右侧。游戏内 Layer
继续显示它的截图，用户便同时看到一张桌面白卡和一张游戏内卡。

### 修复

- 为 `GlobalLookupWindow` 增加 `ResizeOffscreen` / `ResizeStackOffscreen`：它们只按最终物理尺寸
  和嵌套卡偏移调整窗口，并始终停在 `OffscreenX()`，同时保持
  `visible_ / revealed_ = false`。
- `target == galCard` 时，`resize`、`reveal`、`revealStack` 三条消息全部走离屏调整；普通桌面 popup
  仍走原有 `ResizeTo` / `Reveal` / `RevealStack`。
- 游戏内路径继续复用唯一一套 `GlobalLookupController` + popup.html 渲染和 v14 BGRA 回投；调用
  `lookupText(..., showSentenceBanner:false)` 只隐藏顶部整句横幅，完整句子仍保留为制卡上下文，词条、
  主题、发音、制卡与嵌套查词不分叉。
- `galCard` 安装与普通 popup 相同的 JS message / hidden callback；卡内发音、制卡、嵌套查词与主动
  关闭仍回到同一 Dart 控制器。窗口用独立 `offscreen_active_` 记录离屏生命周期，隐藏时不会因为
  `visible_ == false` 漏掉回调。
- 每次桌面或 galCard 查词都绑定不可变的 `source / routeEpoch / lookupEpoch`；Dart、WebView host 与
  两个原生窗口只接受当前代际，旧测量、定时器、bridge 回包和 hidden/reveal 回调会被丢弃。
  关闭游戏内查词时先在原路由静默隐藏离屏 surface，再作废该路由，不再依赖全局可变 target，
  因而迟到的 `reveal` 没有机会逃逸成第二张桌面卡。
- submit 与 hover 分开定序，异步查词使用 latest-wins 代数；游戏线程即时绘制选词高亮，迟到位图不得
  覆盖更新的点击或重新打开已由 Esc 收起的卡。

- **[x] ① 已修复** — 见本文件所在提交；主路位于
  `fushi/lib/src/lookup/gal_ingame_lookup_controller.dart`、
  `fushi/windows/runner/flutter_window.cpp`、
  `fushi/windows/runner/global_lookup_window.{h,cpp}`。
- **[x] ② 已加自动化测试** —
  `fushi/test/lookup/gal_ingame_lookup_contract_test.dart`（galCard 路由、无句子横幅、位图投递与输入）、
  `native/galgame_hook/tests/lookup_ipc_contract_test.cpp` 与
  `native/galgame_hook/tests/lookup_session_replay_test.cpp`（submit/hover/present/dismiss 时序）、
  `native/galgame_hook/tests/kirikiri_lookup_source_guard_test.py`（坐标与消息层身份守卫）。
- **备注**：按用户要求本轮不运行自动化测试；bug 索引与支持矩阵生成器已同步。支持状态保持
  `implemented_unverified`，直到最新 v14 位图构建在真实游戏同一会话中通过视觉与诊断门。
