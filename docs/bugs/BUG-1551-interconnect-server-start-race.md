## BUG-1551 · 互联服务开关竞态：并发 start 抢同一端口、catch 清掉别人的句柄，host 在跑却显示已停止且关不掉
- **报告**：2026-08-11（TODO-2803 互联体检，沿代码路径查出）
- **真实性**：✅ 真 bug，两条独立竞态共用一个根因——`_server` 是唯一共享句柄，却没有
  「启动中」这个状态。
  - `fushi/lib/src/sync/fushi_server_controller.dart:218`（改前）——`start()` 开头
    `if (isRunning) return`，而 `isRunning` 看的是 `_server`，`_server` 直到
    `await server.start()` 真绑上端口才赋值（`:285`）。在那之前还隔着读端口/口令、
    首次生成 RSA 自签证书（秒级）、取设备名、`migrateLegacySyncRootDirectory()` 等好几个
    await。
  - **竞态 A（双实例抢端口）**：`fushi/lib/src/models/app_model.dart:2415` 启动时
    `unawaited(startIfEnabled())`；用户此时进设置页，
    `fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart:914` 又调一次
    `startIfEnabled()`（或直接拨开关 `:1014`）。两条路径都看到 `isRunning == false`，各起一个
    `FushiSyncServer` 绑同一端口。先到者绑上并写 `_server`；后到者拿
    `SyncServerPortInUseException`，而 catch 里（`:294` / `:301` 改前）**无条件**
    `_server = null` —— 把别人刚绑成功的句柄抹掉。净效果：host 实际在监听、mDNS 还在广播，
    UI 显示「已停止」，`stop()` 也停不掉（句柄丢了），端口被自己占死到进程退出，再点开启
    永远「端口被占用」。
  - **竞态 B（关了又自己开回来）**：`:325` 的 `stop()` 只处理当前 `_server`。「拨开→立刻
    拨关」时 stop 看到 `_server == null` 空转并写 `serverEnabled=false`，随后在飞的 start
    落地绑上端口并把意图改写回 `true`（`:286`）。开关显示关闭、host 却在跑并对外广播，
    下次启动还自动开。
  - 附带：`:301` 的 catch-all 也罩着 `_startBroadcast`——广播失败时 socket 已绑上，直接丢句柄
    就是泄漏一个停不掉的监听端口。
- **[x] ① 已修复** — 把「同一时刻只允许一次启动编排」变成状态机的一部分：新增在飞
  future 字段 `_starting`，`start()` 改成薄壳（已在跑直接返回；有在飞就并到同一个 future 上），
  真正的编排下沉为 `_start()`；两个 catch 改成只清**自己那台**（`identical(_server, server)`），
  且 catch-all 分支先 `await server.stop()` 再报错，不泄漏已绑端口；`stop()` 开头先 await
  在飞的 start 再拆卸，让「拨开→拨关」的最终落点一定是「已停 + serverEnabled=false」。
- **[x] ② 已加自动化测试** — 未加。控制器需要真 DB + 六个服务工厂 + 真绑端口才能构造，
  单测层拿不到有意义的判别器（伪造的 server 工厂无法复现「两个真实例抢同一端口」），
  强行造壳只会锁住实现细节而非行为。**待补**：`fushi/tool/run_windows_itest.ps1` 离屏
  集成测试里连点开关 + 查 `netstat` 端口占用与 `isRunning` 一致性，是唯一能真验的层。
  在此之前本条按 `implemented_unverified` 对待。
- **备注**：同源但**未修**：`_regenerateToken` / `_setTlsEnabled` 丢弃 `restart()` 的 outcome
  （`interconnect.part.dart:946` / `:956`），换 token 或开 TLS 若绑定失败会静默把 host 打没；
  `interconnect.part.dart:914` 丢弃 `startIfEnabled()` 的 outcome，开启失败时 UI 静默停在
  「已开启」。
