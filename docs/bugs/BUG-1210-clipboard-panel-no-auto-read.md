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
- **[ ] 未做真机复测（如实留空）**：剪贴板面板主要在 Windows 上用（galgame / 复制文本流），
  但本轮**没有**在真机上跑通「复制文本 → 面板查词 → 自动朗读」这条链。只有源码层守卫，
  该链路的运行时依赖是真实 WebView2 + native overlay 通道，widget 测试跑不起来。
- **审查补记**：初版把朗读调用接在 `_renderPanel` 之后却**漏了 seq 核对**——`update()` 的
  契约是「每个 await 后核对 latest-wins 序号，过期即弃」（VN 流乱序守卫），`_showPanel` /
  `raise` 两个分支后都有，唯独朗读这一处没有。后果是被后一句顶掉的旧查词仍会读出**旧词**
  （屏幕新句、耳朵旧句），而面板正是被动流的主力表面。已补核对 + 守卫。这是收口共享实现时
  典型的「把一方独有契约一起抹掉」：覆盖窗没有 latest-wins 机制，共享实现里自然也没有。
- **顺带修复的 CI 红**：`test/lookup/global_lookup_autoread_webview_guard_test.dart` 在
  develop 上已经红了（`Build Release APK` 的 `Run unit tests` 门）。根因是 BUG-1204 把
  `global_lookup_host.js` 的回报从 `[token, false]` 改成三参数 `[token, false, reason]`，
  打破了这条锚在两参数字面量上的既有守卫，而当时的定向测试没覆盖 `test/lookup/`。本 PR 把
  锚点改成前缀匹配并补断 `FrameNotLoaded`，守的意图（未加载帧必须立刻回 false，不拖满 5s
  超时）一字未改，实际比原来更严。

### 补记（2026-07-28）：第一版只修了三条路径里的一条

第一版把朗读接在了 `update()`（剪贴板流）上，并据此判定「剪贴板面板是**唯一**漏接的表面」。
那个判定是**循环论证**：当时是从 `autoRead` 符号侧去找接入点，只能看见「已经调了朗读的地方」，
天生看不见「没调的路径」。

改从**结果产生侧**穷举（`AppModel.searchDictionary(` 的全部 23 个调用点，并验证过没有旁路：
无表面绕开它直连引擎，`DictionarySearchResult` 直接构造的 3 处都不是独立表面）后发现，
同一个面板里还有两条**用户主动查词**的路径没接：

- `_lookupFromBanner`（点句中字换根）—— 用户表现为「复制进来会读、点字不读」。
- `_lookupNested`（点释义里的词再查）—— 更要命：**瞬态覆盖窗的同名路径是会读的**
  （`global_lookup_controller._lookupNested` 末尾就有 `_autoReadFirstEntry`），两个表面在
  同一个动作上行为漂开，而「两表面不得漂开」正是本条要收口的东西。

两条都已补上。`_lookupFromBanner` 与 `update()` 同款，在 `_renderPanel` 这个 await **之后**
再核对一次 latest-wins 序号才朗读（少这一句，被后一句剪贴板顶掉的旧点击会读出旧词）；
`_lookupNested` 不加序号核对，因为它自始就不参与 root 的 latest-wins（是压栈不是换根），
只给朗读单独引入一套序号语义会和既有的「压栈 + 渲染」边界不一致，与瞬态窗 nested 保持同构。

守卫补两层：`test/lookup/auto_read_surface_coverage_guard_test.dart` 按**文件**粒度要求每个
查词调用点显式声明接不接朗读（豁免必须写具体理由，占位符会红）；
`overlay_auto_read_parity_test.dart` 再按**方法**粒度要求「凡查了词的方法都得有朗读调用」——
前者抓不到同文件内删掉某一条路径的朗读，后者能（变异实测证实）。

### 仍未处理：Android 悬浮词典（待产品拍板）

`floating_dict_page._doSearch` 与 `app_model._setupFloatingDictHandlers.onSearch` 两条路径同样
不朗读。同为「搜索框手动输入」的 `home_dictionary_page` 是朗读的，故**行为并不一致**；但悬浮
词典是浮在别的 app 上层的小窗，突然出声更打扰，该不该自动朗读是产品取舍。已进守卫的豁免名单
并注明「待产品拍板」，定了再挪进 wiredSurfaces。

- **[ ] 未做真机复测（如实留空）**：本轮全部是静态代码分析 + 单测，**没有**在真机上实际
  复现「点字查词 / 嵌套查词听不到声音 → 修后能听到」。「用户实际能不能听到」未经验证。
