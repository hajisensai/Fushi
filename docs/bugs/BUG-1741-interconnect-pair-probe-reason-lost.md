## BUG-1741 · 互联配对报错文案完全误导：三层静默吞异常 + TLS host 回落 v1 死路
- **报告**：2026-08-19（用户：）
- **真实性**：✅ 真 bug。两条根因均沿真实代码路径证实。

  **根因 A · 三层静默吞异常**（BUG-1553 只修了 v2 client 那一层，配对**前置探测**三层至今全静默）：
  1. `fushi/lib/src/sync/tls/fushi_tofu_probe.dart:46` — `on Object { return captured; }`
     吞掉 `HandshakeException`（对端根本不讲 TLS）/ `SocketException` / `TimeoutException`，全文件无
     `ErrorLogService`。
  2. `fushi/lib/src/sync/pairing/fushi_ping_client.dart:76` — `on Object { return null; }`
     把 `TlsException`（**钉扎指纹不符，安全事件**）、`SocketException`、`TimeoutException`、
     `FormatException` 与 `:57/:59/:62` 三个无区分早退（非 200 / 非 JSON / 非 fushi）压成同一个 `null`。
  3. `fushi/lib/src/sync/pairing/discovered_pairing_probe.dart:71/:74/:87` — 三个 `continue`
     再把上面压平的 `null` 压成整体 `:95 return null`，返回类型里根本没有承载 reason 的字段。

  出口文案 `fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart:299`：
  `ping == null || !isFushi || !supportsPairV2` 三合一 → `t.sync_pair_not_fushi`
  「此地址未找到 Fushi 设备」。**误导的确切形态**：host 在线、证书指纹与已钉扎的不符（真实原因是
  可能的中间人 / host 重装证书），用户被告知「这里没有设备」——与真相完全相反，排查方向从第一步就错。
  `_ensurePinnedFingerprintTrusted`（`:696`）本是为这个场景准备的告警闸，但流程在 `:299` 就 return 了，
  **永远走不到**。

  另：`interconnect.part.dart:213` 把 URL 解析失败（根本没发起连接）说成 `t.sync_connection_failed`
  「连接失败」。

  **根因 B · TLS host 回落 v1 死路**：
  - 物理根据 `fushi/lib/src/sync/lan_discovery_service.dart:28` — `String get webDavUrl => 'http://$host:$port';`
    硬编码明文 scheme。
  - TLS host 只 `bindSecure` 一个 socket（`fushi_sync_server.dart:172`），**完全不提供明文端口**。
  - mDNS TXT 的 `tls=1` 在部分平台会被 resolve 丢掉（`discovered_pairing_probe.dart:26-28` 自承）→
    `tlsEnabled=false` → 候选顺序变 `[http, https]`；https 候选一旦握手不成被根因 A 第 1 层吞掉就
    `continue`，http 候选打在 TLS-only 端口上被 reset 又被第 2 层吞掉 → 整体 `null` →
    `interconnect.part.dart:1509` 落到 `_pairLegacyV1`。
  - v1 必然失败：`:1533` 对 `device.webDavUrl`（必然 `http://`）发明文 POST → 抛 → `:1564`
    `t.sync_pair_failed`「配对失败」，真实原因一个字都没体现。
  - **附带持久化污染**：`:1527` 把错的 `http://` 地址写进候选列表，那台设备此后每次「测试连接」
    都失败，且 UI 里看不出 scheme 错了 —— 永久性坏掉。

- **[x] ① 已修复** — 提交见本分支。
  - `fushi_ping_client.dart`：新增 `FushiPingFailure{tls,timeout,unreachable,notFushi}` +
    `FushiPingOutcome` + `probeFushiPing()`（带分型与 `ErrorLogService` 留痕）；`fetchFushiPing`
    降级为丢原因的薄封装保持旧调用方零改动。TLS 判定排在最前（IOClient 让 TLS 异常原样穿透）。
  - `fushi_tofu_probe.dart`：新增 `FushiTofuFailure{notTls,unreachable,timeout}` +
    `FushiTofuOutcome`（含 `speaksTls`）+ `probeFingerprint()`；`captureFingerprint` 同样降级为薄封装。
  - `discovered_pairing_probe.dart`：新增 `DiscoveredPairingProbeOutcome`（`failure` +
    **`peerSpeaksTls`**）+ `probeDiscoveredPairingEndpointDetailed()`，按严重度
    `tls > timeout > unreachable > notFushi` 收口；`notTls` 在明文 host 上零信息量，**不参与评选**
    （否则会盖掉 http 候选带回的 `notFushi` 这种真正有用的结论）。
  - `interconnect.part.dart`：
    - `_connectToDevice`：`peerSpeaksTls || device.tlsEnabled` 时**禁止回落 v1**，直接报真实原因；
      探明 https 端点却不支持 v2 时报 `sync_pair_unavailable`；v1 改用 `probe?.baseUrl ?? device.webDavUrl`。
    - `_pairLegacyV1` 签名加 `baseUrl`，内部三处 `device.webDavUrl` 全部改用它（消除硬编码 http 污染）。
    - `_attemptManualPair`：TOFU 失败按 `notTls` 报「对端未启用 HTTPS，改用 http://」；明文地址
      `unreachable` 时回头探 TOFU，若对端讲 TLS 则报「该设备只接受 HTTPS」；`!supportsPairV2` 与
      「找不到设备」拆开；https 无指纹报 `sync_pair_tls_failed` 而非笼统的「配对失败」。
    - URL normalize 失败改报 `sync_pair_invalid_url`。
    - 新增 `_pingFailureMessage` / `_tofuFailureMessage` 到共享 `_PairingV2FlowMixin`。
  - i18n 新增 3 key（`i18n_sync.dart --add` × 17 语言 + `dart run slang`）：
    `sync_pair_invalid_url` / `sync_pair_peer_requires_https` / `sync_pair_peer_not_https`。
    已存在的 `sync_pair_tls_failed` / `sync_pair_timeout` 此前只有 `_pairV2FailureMessage` 一个消费者，
    现在探测阶段也能用上。

- **[x] ② 已加自动化测试** —
  - `fushi/test/sync/pairing/fushi_ping_client_test.dart`：新增 `probeFushiPing 失败分型` 组
    （TlsException/HandshakeException→tls、超时→timeout、SocketException→unreachable、
    非 Hibiki→notFushi 且与 unreachable 可分辨、非 200 保留状态码）+ `classifyFushiProbeFailure` 组。
    此前该文件只有 4 个 happy/null case，**零异常路径断言**。
  - `fushi/test/sync/pairing/discovered_pairing_probe_test.dart`：全部注入缝换成新契约，新增
    「失败原因 + TLS 确证」组：钉扎失败带出 tls 且 `peerSpeaksTls=true`（禁止回落 v1）、TXT 丢标志时
    https 握手成功也算确证、真·旧版明文 host 无 TLS 证据允许回落、多候选取最严重原因、成功时无 failure。
  - 三条源码守卫更新为新契约并加了新不变量：
    `interconnect_manual_pair_guard_test.dart`（必须用 `probeFushiPing`，**禁止**退回 `fetchFushiPing`）、
    `interconnect_tls_entry_guard_test.dart`（必须消费 `peerSpeaksTls` 与 `_pingFailureMessage`，
    v1 必须用 `probe?.baseUrl ?? device.webDavUrl`）、
    `interconnect_client_panel_guard_test.dart`（忙态锚点跟到新 API 名）。
  - 验证：`flutter test test/sync/ --no-pub` → 2218 passed。

- **备注**：`docs/bugs/BUG-1553-interconnect-pair-failure-reason-lost.md` 的「同源但未修」段落说的
  正是本条。本次不改 server 侧、不改 v2 client（BUG-1553 已修好那一层）。
  探测层与 UI 层的分型词汇表刻意与 `FushiPairV2Client._classifyTransportFailure` 保持同一套，
  避免第三套 reason 词汇。
