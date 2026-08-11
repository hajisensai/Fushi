## BUG-1553 · 配对失败原因被压平：限速 429 / TLS 指纹不符 / 超时全说成「配对失败」且不留日志
- **报告**：2026-08-11（TODO-2803 互联体检，沿代码路径查出）
- **真实性**：✅ 真 bug，server 侧精心设计的机器可读 reason 在 client 一端整个丢掉。
  - server：`fushi/lib/src/sync/fushi_sync_server.dart:942` `_pairRateLimited()` 返回
    `429 {"reason":"rate_limited"}`，在 `:849` / `:856` / `:871` 三处使用（PIN 爆破限速
    `FushiPinRateLimiter` 锁定该来源）。
  - client：`fushi/lib/src/sync/pairing/fushi_pair_v2_client.dart:128`（改前）只特判
    401/403，其余一律 `if (statusCode != 200) return const FushiPairV2Failure('error')`
    —— 429 连 `_reasonOf` 都不调。
  - UI：`fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart:656`（改前）
    `_pairV2FailureMessage` 无 `rate_limited` 分支 → `default` → `t.sync_pair_failed`。
  - 同一处 `catch (_) { return const FushiPairV2Failure('error'); }`（`:147` 改前）把
    `HandshakeException`（钉扎指纹不符——安全事件）、`TimeoutException`、`SocketException`
    全压成同一个 `'error'`，**且一行 `ErrorLogService` 都不写**。因为 `pair()` 不抛，
    `interconnect.part.dart:624` 那个 `catch + ErrorLogService.log('PairV2:...')` 对这些异常
    永远不会触发。
- **症状预测**：① 用户 PIN 连错几次被 host 锁 15 分钟，却只看到「配对失败」，于是反复重试
  ——每次都要对方再审批一遍、再看一遍 PIN，把「限速可恢复」体验成「配对彻底坏了」；
  ② TLS 指纹不符被降级成同一句话，用户报障时日志里查不到任何线索。
- **[x] ① 已修复** — client 侧：pair/v2 与 confirm 两处都解析 429 → `rate_limited`；
  catch 改为分型 `_classifyTransportFailure`（`TlsException` → `'tls'`，`TimeoutException`
  → `'timeout'`，其余 `'error'`）并先 `ErrorLogService.instance.log('PairV2Client:$baseUrl',…)`
  留痕。UI 侧：`_pairV2FailureMessage` 增加 `rate_limited` / `tls` / `timeout` 三个分支。
  i18n 走 `fushi/tool/i18n_sync.dart --add` 新增 `sync_pair_rate_limited` /
  `sync_pair_tls_failed` / `sync_pair_timeout`（17 语言）后 `dart run slang` 重生成。
- **[x] ② 已加自动化测试** — `fushi/test/sync/pairing/fushi_pair_v2_failure_reasons_test.dart`
  （新增）：confirm 429 / 创建会话 429 → `rate_limited`；`HandshakeException` → `tls`；
  `TimeoutException` → `timeout`；`SocketException` 仍是 `error`（不过度分型）；
  既有 401/403 语义不变。变异实测：删掉 confirm 的 429 分支、把 `e is TlsException` 改成
  `false` —— 两处各自转红，反向替换还原。
- **备注**：同源但**未修**：`fushi_ping_client.dart:76` 的 `on Object { return null; }` 与
  `tls/fushi_tofu_probe.dart:110` 同样静默，导致 TLS 失败在**手动输 IP** 那条路径上被呈现成
  「此地址未找到 Fushi 设备」（`interconnect.part.dart:254`）。
