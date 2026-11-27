## BUG-5607 · torrent-dht-test-default-timeout
- **报告**：2026-11-28（合并任务读 PR #4596 CI：`linux-server` 的 fushi_torrent FFI 测试红，run 46052485745）
- **真实性**：✅ 真 bug（测试自身）。`packages/fushi_torrent/test/detail_info_test.dart` 的 BUG-5165 用例「双端点各一个 DHT 实例时报两者之和」里 `_pollUntil(..., timeout: 60 s)` 是按「引导域名 DNS 解析失败要等解析器超时」特意放宽的上限，但用例本身没写 `timeout:`，吃 package:test 默认 30 s——解析器慢时先被框架在 30 s 判 `TimeoutException`；框架判超时后 `_pollUntil` 循环并不停，tearDown 已 `close` 掉 session，下一次 `onTick` 里 `b.sessionStatus()` 返回 null，再报一条 `Expected: not null (failed after test completion)`。与 PR 改动无关，任意改了 server 侧触发 `linux-server` 的 PR 都可能撞上。
- **[x] ① 已修复** — 用例加 `timeout: const Timeout(Duration(minutes: 2))`（与同文件其余等 DHT / 网络的用例一致，留出 60 s 轮询上限之外的建号与收尾余量）；`_pollUntil` 的轮询上限才是真正的判据。
- **[x] ② 已加自动化测试** — 本身即测试；CI `linux-server` 的 fushi_torrent FFI 步覆盖。
- **备注**：
