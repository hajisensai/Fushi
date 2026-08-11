## BUG-1554 · LAN 发现 startDiscovery 无幂等/无 dispose 守卫，重扫与关页竞态留下孤儿 Bonsoir browser
- **报告**：2026-08-11（TODO-2803 互联体检，沿代码路径查出）
- **真实性**：✅ 真代码缺陷（当前 UI 只在 `initState` 调一次，所以「重复扫描」那一半是潜在的；
  「关页竞态」那一半现在就能踩到）。
  - `fushi/lib/src/sync/lan_discovery_service.dart:98`（改前）——`startDiscovery()` 直接
    `_discovery = discovery; _sub = discovery.eventStream!.listen(...)`，既不检查也不取消旧的。
    重复调用会把上一台 `BonsoirDiscovery` 连同它的原生 browser 一起**覆盖丢弃**，泄漏一个
    没人停得掉的原生浏览器 + 一条仍在派发事件的订阅——正是 TODO-036 / BUG-191 那类
    「引擎拆了事件还在派发」退出崩溃的形状。同一文件里其它路径（`:185` / `:196`）都检查
    `_disposed`，唯独这里没有。
  - `fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart:1197` `_init` 的形状是
    「先 `registerDiscovery` 再 `await _startScan()`」；用户在 `startDiscovery()` 的 await 窗口里
    关掉设置页时，`dispose()` 已经跑完并 `unregisterDiscovery` 了，旧实现照样新起一个原生
    browser —— 既不在 controller 的 `_activeDiscoveries` 里、也没有 owner。
  - `interconnect.part.dart:1244`（改前）`_startScan` 每次 `_devicesSub = discovery.devices.listen(...)`
    也不取消旧订阅。
- **[x] ① 已修复** — `startDiscovery()` 改为幂等 + 全程守 `_disposed`：入口即返回、
  `_refreshLocalAddresses()` 之后复核、`initialize/start` 之后再复核一次并把抢跑起来的
  browser 停掉；已有 browser 时先 `stopDiscovery()` 再起新的。`stopDiscovery()` 里
  `_deviceStream.add` 加 `isClosed` 守卫。UI 侧 `_startScan` 先 `await _devicesSub?.cancel()`。
  新增 `@visibleForTesting bool get hasActiveBrowser`（原生 browser 在单测环境里既不抛也不
  回执，这是唯一可观测面）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/lan_discovery_service_test.dart` 新增
  `LanDiscoveryService lifecycle` 组：dispose 之后 `startDiscovery()` 必须 no-op
  （`hasActiveBrowser` 仍为 false）、`dispose` 幂等。变异实测：把三处 `_disposed` 守卫全部
  去掉后转红（`MethodChannel` 在无 binding 的单测里抛 `BindingBase.checkInstance`），
  反向替换还原。**注意**：只去掉入口那一处守卫不会红（后面那处兜住了），守卫是一组、
  要一起看。
- **备注**：发现列表目前**没有「重新扫描」按钮**（`_startScan` 只在 `initState` 调一次）。
  扫描失败（权限/防火墙）后用户只能退出页面再进——本条把幂等修好，正是加这个按钮的前置。
