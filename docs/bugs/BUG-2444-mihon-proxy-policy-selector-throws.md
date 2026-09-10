## BUG-2444 · 宿主代理策略故障时 ProxySelector 抛异常导致 sidecar 堆耗尽、请求挂死到超时
- **报告**：2026-09-11（用户：很多扩展打不开，要求全量测试 127 个已装 Mihon 扩展并做根本性修复。本条是全量实测过程中在桥自身发现的缺陷，不是用户直接报的症状。）
- **真实性**：✅ 真 bug。根因 `third_party/m_extension_server/overlay/server/src/main/kotlin/mextensionserver/impl/HostProxyPolicy.kt:98`（原 `select` 直接 `return proxies(lookup(uri).directive)`）。`ProxySelector.select` 是 OkHttp 不允许失败的接口，而 `lookup` 会向宿主发一次 HTTP 查询。两种抛出形态都实测到：① 宿主端点非 200 → `IOException`；② `FUSHI_MIHON_PROXY_POLICY_PORT` 缺失时 `port` 为 null，被插值成 `http://127.0.0.1:null/proxy-policy?...` → `URISyntaxException`。`configureClient` 无条件把 `HostProxyPolicy` 装成 selector，所以 `install()` 返回 false 的独立运行场景走的也是这条路，而注释承诺的是「nothing to fall back to but DIRECT」——那个回退从未实现。
- **[x] ① 已修复** — `4619e19f1e`。`select` 永不抛，两种情形各自表达成路由：无宿主端点 → `DIRECT`（sidecar 独立运行，`tool/mihon/verify_desktop_runtime.*` 冒烟脚本就是这个场景）；有端点但答不上来 → 一条 `host-proxy-policy-unavailable.invalid` 的不可解析路由，fail closed，既不静默降级直连泄漏出用户代理也不抛。`proxyAuthenticator` 里同一个 `lookup`（OkHttp 从 follow-up 循环里调）一并收口成「拿不到凭据就停在代理自己的 407」。
- **[x] ② 已加自动化测试** — `353968b313` + `4619e19f1e`，`third_party/m_extension_server/overlay/server/src/test/kotlin/mextensionserver/impl/HostProxyPolicyTest.kt` 新增 4 条：无端点走 DIRECT 且根本不查宿主、查询失败返回不可解析路由而非抛出、策略中断后同一 client 下一个请求仍能成功、代理挑战期间策略中断只是拿不到凭据。**变异实测**：把 `selectWith` 与 authenticator 两处收口分别/同时拆掉，4 条全红；修复版全绿。完整 JVM 套件 57 项 0 失败。
- **实测证据**：
  - 最小复现（`ProbeSelector`，256m 堆，okhttp + 一个会抛的 selector）：`mode=io` 1518ms OOM、`mode=uri` 2112ms OOM，对照 `mode=direct` 正常 10s 连接超时。
  - 端到端（真 APK `ja.comicdays` + 512m，与生产同堆）：**旧 jar** 策略端点 503 时该请求挂死到客户端 120s 超时、sidecar 日志出现 `OutOfMemoryError`；**修复版**同场景 11.2s 内以 `UnknownHostException: host-proxy-policy-unavailable.invalid` 明确失败、日志无 OOM。两者在策略恢复后都能正常返回 330 条。
- **边界与影响**：OOM 抛在 NanoHTTPD 的那条请求线程上，**JVM 主进程并未退出**（两次端到端实测 `aliveAtEnd` 均为 true），所以症状是「这个请求挂死到超时 + 期间堆被占满殃及并发请求」，不是「sidecar 整个崩掉」。修复不改变正常路径的选路语义（每次请求仍向宿主问一次，策略变更下一个请求生效）。
- **备注**：`third_party/m_extension_server/UPSTREAM` 的 `HostProxyPolicy.kt` 段已同步这条不变式。
