## BUG-3085 · 补刮被挡下的请求只靠视频页忙到闲兑现，页面未挂载或在飞闸门时丢失
- **报告**：2026-10-09（#2015 合入后的审查）
- **真实性**：✅ 真 bug，有两处：
  1. **调度器自己不兑现。** `VideoLibraryScrapeSweep` 会把批次期间被挡下的补刮请求记在 `_sweepDeferred`（`packages/fushi_engine/lib/media/video/metadata/video_library_scrape_sweep.dart:257`，修前行号）。兑现只有两个出口：
     - 本轮 `finally`（`:535`），但只在挡下它的是本调度器**自己**这一轮时才走到；
     - `refreshPendingAfterScrapeResults`（`:275`），而它只由视频页在「批次忙→闲」时调用。

     如果批次是别处发起的（手动刮削、扫描后自动刮），期间下载入库的作品就要一直等到下次进视频页。视频页没挂载时（用户在别的 tab，或者无头服务端根本没有页面）这条请求就一直拖着。
  2. **视频页闸门吞请求。** `_refreshPendingScrapeCount`（`fushi/lib/src/pages/implementations/home_video_page.dart:3743`，修前行号）遇到 `_pendingScrapeInFlight` 时直接 `return`。在飞的那次可能读的是批次结束前的旧状态，而撞上闸门的那次（包括批次忙→闲时那一次兑现）被整个丢掉，提醒条就停在旧数字上。
- **[x] ① 已修复**（`f59868a07a`）—
  1. **调度器自己兑现。**
     - 构造时监听 controller（`video_library_scrape_sweep.dart:189`）。`_onControllerChanged`（`:274`）在三个条件同时满足时发起兑现：有被挡下的请求、自己没在跑、controller 已闲。`finally`（`:579`）走同一个 `_runDeferred`。
     - `refreshPendingAfterScrapeResults`（`:323`）收回为纯只读，不再兼职兑现，否则会和监听叠出两轮。
     - 新增 `dispose()`（`:301`）断开监听。app 侧 `VideoScrapeRuntime` 在 controller 换代和 `shutdown` 时先 dispose 旧调度器（`fushi/lib/src/media/video/metadata/video_scrape_runtime.dart:137`、`:211`），服务端 `VideoScrapeHost.close`（`packages/fushi_server/lib/src/video_scrape_host.dart`）也一样。这样关停后，在途批次结束时不会再发起补刮。
  2. **视频页闸门不再吞请求。** 在飞时只置位 `_pendingScrapeRecountQueued`（`home_video_page.dart:326`、`:3748`），等在飞那次完成后合并补跑一次（`:3756`）。

  BUG-3072 的不变式没有变：只有 `sweepAndListPending`（库里条目变化的真实请求）会置位 `_sweepDeferred`。刮削结果的写入（包括补刮批次自己的）和 controller 通知本身都不会置位，所以不会出现一轮的写入触发下一轮。
- **[x] ② 已加自动化测试** —
  - `fushi/test/media/video/metadata/video_library_scrape_sweep_test.dart`：
    - 别处批次期间被挡下的请求，在批次结束时由调度器自己兑现，全程不调 `refreshPendingAfterScrapeResults`；兑现之后只读端口不再起新一轮；
    - 视频页的只读刷新与调度器兑现叠在一起，也只跑一轮；
    - `dispose` 之后，在途批次结束不再发起补刮；
    - 既有的「批次在跑时重复触发」用例改为先等调度器兑现完成。
  - `fushi/test/pages/home_video_pending_scrape_banner_test.dart`：计数重算在飞时又来一次请求，完成后会补跑，提醒条落到最新值。

  变异实测：去掉监听注册、或去掉 `_pendingScrapeRecountQueued` 的置位，对应用例都会变红。
- **备注**：
