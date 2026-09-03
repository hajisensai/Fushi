## BUG-2079 · NyaaClient.search 无超时，订阅检查可被单个慢响应挂住
- **报告**：2026-09-03（PR #1178「按每周更新点调节订阅检查节奏」的审查副产物。**不是该 PR 引入的**：逐字比对 merge-base 确认旧版 `checkNow()` 早返回路径与新版一致，这条是既有账，故只记录、不在那条 PR 里修。）
- **真实性**：✅ 真 bug（既有缺口）。`fushi/lib/src/media/torrent/nyaa_client.dart:461` `final http.Response res = await _client.get(uri);` **不带 `.timeout(...)`**，整条 `NyaaClient.search` 没有任何超时。同一域的 `fushi/lib/src/media/torrent/torznab_client.dart:407` 有 `requestTimeout = const Duration(seconds: 20)` 并在 `:451`/`:640`/`:744`/`:792` 四处真的 `.timeout(requestTimeout)` —— 两个客户端对同一类失败给出的是两套语义。
- **影响**：订阅检查是**串行 drain**（`VideoDownloadSubscriptionService._drain`），一个卡死的 Nyaa 响应会把这一轮后面所有订阅一起挂住；`http` 包的默认连接超时依赖平台（Dart `HttpClient.connectionTimeout` 默认为 null = 不超时），站点被墙 / 代理半开的 TCP 连接可以挂到操作系统级重传耗尽为止。PR #1178 把冷窗唤醒拉长到 2 小时后，一次挂死的窗口影响更长。
- **[ ] ① 未修复** — 修法与 torznab 对齐：给 `NyaaClient` 加 `requestTimeout`（默认 20 s，与 torznab 同值），在 `_client.get(uri)` 上 `.timeout(requestTimeout)`，并让 `TimeoutException` 与既有的「抛出而不是吞成空列表」语义一致（`:440` 的文档已经承诺网络故障要抛给调用方，超时属于同一类）。
- **[ ] ② 未加自动化测试** — 应在 `fushi/test/torrent/nyaa_client_test.dart` 用一个永不完成的 `MockClient` 断言 `search` 在 `requestTimeout` 后抛 `TimeoutException`（不是无限等待）。
- **备注**：只改 Nyaa 一侧，不动 torznab；两者的候选归一化与错误分类已经各自独立，不要借这条顺手合并。
