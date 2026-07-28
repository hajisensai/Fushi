## BUG-1210 · 剪贴板面板查词不自动朗读而浮窗会开关却是全局的
- **报告**：2026-07-28（用户：「我查词了，但是没读音，点音频按钮才有正常吗」）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/lookup/clipboard_panel_controller.dart`
  的 `update()`（改前 L219-253）：查词成功后 `_seedRootFrame` → `_renderPanel` → glog
  「panel: updated」，**整条路径没有任何自动朗读调用**。
  全仓 `autoReadWordUnified` / `LookupAutoReadCoordinator.runAutomatic` 的接入点只有三处
  ——`global_lookup_controller.dart`（app 外瞬态查词覆盖窗）、`base_source_page.dart`
  （app 内媒体页）、`dictionary_page_mixin.dart`（app 内词典页）。剪贴板面板是**唯一
  漏接的查词表面**，而它正是 galgame / 复制文本流的主力表面。
  用户偏好 `src:reader_ttu:auto_read_on_lookup` 实测为 `b:true`（`preferences` 与
  `profile_settings` 两处一致），即开关是开着的——同一个全局开关在一个表面生效、在另一
  个完全无效，用户表现为「面板查词不读，必须手动点 ♪」。
  用户机器日志佐证：07-28 全天 52 次 `panel: updated`、**0 次 autoread**；而 07-27 用
  瞬态浮窗那次（`lookup:` / `hotkey:` 路径）autoread 正常触发 token=1..6。
- **[x] ① 已修复** — 自动朗读收口成共享 `hibiki/lib/src/lookup/overlay_auto_read.dart`
  （`OverlayAutoRead`），app 外两个表面共用一份实现，各自注入自己的渲染通道与就绪门控、
  token 表独立。这与 `overlay_bridge_handlers.dart` 的九根 deferred 桥同一条红线：两个
  表面的行为不得漂开，**绝不复制**。
  `global_lookup_controller` 改为委托该实现（原私有实现整段移出）；
  `clipboard_panel_controller` 新增两处接线：① `update()` 渲染完成后
  `_autoRead.autoReadFirstEntry(model, result)`（放在渲染之后——播放脚本走同一 render
  通道，必须排在整栈渲染脚本之后，否则会被 last-wins 顶掉）；② `_onJsMessage` 接
  `maybeHandleWordAudioPlayed`——**这一步不可省**，否则 Completer 永远等不到回报，每次
  自动发音都要空耗满 5s 超时才回落 Dart 播放器。
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/overlay_auto_read_parity_test.dart`：
  面板必须调 `autoReadFirstEntry`、必须接住播放回报、两个表面必须共用同一实现（断言各自
  不再私有维护 `_pendingWordAudioPlays` / 自拼 `buildPlayWordAudioScript`）、共享实现须
  保留既有播放契约（统一快路径 + 去重协调器 + 就绪门控 + 开关门控）。
  受契约变更影响的既有守卫同步更新（守的意图一字未改，只是实现搬了家）：
  `global_lookup_m1a_guard_test.dart` 改为分扫「接线 + 共享实现」；
  `global_lookup_autoread_webview_guard_test.dart` 的 `[token, false]` 锚点改为前缀匹配
  （BUG-1204 后回报多带了第三个 reason 参数）。
  全量 `flutter analyze` 干净；test/lookup 584 + mining/build/utils 1750 用例全绿。
- **备注**：这条与用户最初报的「单词音频响应巨慢」是同一症状的真正来源之一——不是某段
  代码慢，而是**面板压根不自动读**，用户得自己点 ♪ 再等一下，主观上就是「响应巨慢」。
  这也解释了为什么此前实测每一段（本地库 0.3ms / Dart 解析 3ms / 桥 9ms）都是毫秒级却
  找不到慢的环节。BUG-1204 的首播失败（`token=1 ok=false`）是另一条独立线索，仍待用户
  复现后从日志读到确切 DOMException 名字再定案。
