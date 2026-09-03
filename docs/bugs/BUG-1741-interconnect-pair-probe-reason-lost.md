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
  「此地址未找到 Fushi 设备」。**误导的确切形态**：host 明明在线，只是超时 / 只讲 https / 本次证书
  校验没过，用户一律被告知「这里没有设备」——与真相完全相反，排查方向从第一步就错。

  **勘误（PR#912 审查）**：本段最初写的「钉扎指纹不符被压成 null，`_ensurePinnedFingerprintTrusted`
  （`:696`）永远走不到」是**错的**，别再据此推理。配对流程传给 `probeFushiPing` 的 `pinnedFingerprint`
  **永远是本次刚 TOFU 捕获的那张**（`_attemptManualPair` 与 `probeDiscoveredPairingEndpointDetailed`
  都是先 capture 再 pin 着 ping），它跟「库里已钉扎的旧指纹」根本不在同一次比较里。旧指纹的比对发生在
  `_runPairingV2` 的第一行 `_ensurePinnedFingerprintTrusted`（BUG-1557 就是为此把它提到握手之前），
  不符会弹 `_confirmFingerprintRetrust` 告警窗，从未被吞。探测层的 `FushiPingFailure.tls` 指的是
  **本次握手/证书校验**没过（host 两次连接出示了不同证书、或中间有人应答），不是「与已钉扎指纹不符」。

  另：`interconnect.part.dart:213` 把 URL 解析失败（根本没发起连接）说成 `t.sync_connection_failed`
  「连接失败」。

  **根因 B · TLS host 回落 v1 死路**：
  - 物理根据 `fushi/lib/src/sync/lan_discovery_service.dart:32` — `webDavUrl` 的 scheme 只跟 mDNS TXT
    的 `tlsEnabled` 走。**勘误（PR#912 审查）**：本条最初写的「硬编码 `http://`」在 5 个月前的 BUG-1693
    （`7e34a350a1`）就已经改成 `'${tlsEnabled ? 'https' : 'http'}://$host:$port'`，早已不成立。真实的
    残留缺口是它**唯一的依据是 TXT**：resolve 丢 TXT 在部分平台真实存在 → `tlsEnabled=false` →
    webDavUrl 退回 `http://`，对着一台只 `bindSecure` 的 host 发明文 POST。所以「改用探测实测出来的
    `probe?.baseUrl`」这个修法是对的，只是原先给的理由说错了地方。
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

- **PR#912 审查收尾**（同分支追加，五条）：
  1. **新文案不再说谎**：`_pingFailureMessage` 加 `{required bool addressSaved}`（无默认值，漏传是编译
     错误）。手动 IP 路径在 `_addOrEditUrl` 里探测**之前**就 `_persistUrls()`，`sync_pair_not_fushi`
     的「已保存该地址」成立；发现列表的 `_connectToDevice` 在 `probe == null && (peerSpeaksTls ||
     tlsEnabled)` 分支直接 return、一个字不写库，改用新 key `sync_pair_not_fushi_discovered`
     （en/zh 都去掉「已保存」）。
  2. **`TimeoutException` 分支曾是死代码**：`SecureSocket.connect(timeout:)` 超时抛的是
     `SocketException: Connection timed out`，被归成 `unreachable` → UI 说「连接失败」而不是「未在时限
     内应答」。改为 `connect` 不再传 `timeout:`、外包一层 `.timeout(timeout)`（单一计时源），并对超时后
     才 resolve 出来的 socket 挂 `unawaited(... destroy())` 兜底（`.timeout` 不取消底层 connect）。
     `_classify` 提升为顶层 `classifyFushiTofuFailure`，与 `classifyFushiProbeFailure` 同形、可测。
  3. **删掉三个丢原因的薄封装**：`FushiTofuProbe.captureFingerprint` / `fetchFushiPing` /
     `probeDiscoveredPairingEndpoint` 生产侧零调用方，只为旧测试续命。测试迁到 `*Detailed` /
     `probeFingerprint` / `probeFushiPing`，同时删掉 `interconnect_manual_pair_guard_test.dart` 里
     「不许退回 fetchFushiPing」那条守卫——入口都没了，守卫查调用点本身就是「错误入口还开着」的证据。
  4. **探测失败改走 `logDiagnostic`**：明文 host 的 https 候选**每次配对**都必然抛一次
     `HandshakeException`，是多候选 failover 的预期路径。原先的 `ErrorLogService.instance.log` 把它计进
     用户可见错误计数并持久化落盘（`error_log_service.dart:406` 的文档逐字点名了这个场景）。
  5. **两处事实错误**：见上面根因 A 尾与根因 B 首条的两段「勘误」。
  - 追加测试：`fushi/test/sync/tls/pr912_fushi_tofu_probe_test.dart`（分型纯函数 5 例 + 真 socket 三例：
    只 accept 不讲 TLS → `timeout`、空端口 → `unreachable`、回非 TLS 字节 → `notTls` 且只进
    `diagnosticEntries` 不进 `entries` + 三条源码不变式）、
    `fushi/test/sync/pr912_pair_not_fushi_message_test.dart`（两个 key 的「已保存」文案差异本身）；
    `interconnect_tls_entry_guard_test.dart` 新钉 `addressSaved: false`（并禁 `true`）。

- **备注**：`docs/bugs/BUG-1553-interconnect-pair-failure-reason-lost.md` 的「同源但未修」段落说的
  正是本条。本次不改 server 侧、不改 v2 client（BUG-1553 已修好那一层）。
  探测层与 UI 层的分型词汇表刻意与 `FushiPairV2Client._classifyTransportFailure` 保持同一套，
  避免第三套 reason 词汇。
